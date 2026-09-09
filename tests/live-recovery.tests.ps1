#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-live-recovery-$([Guid]::NewGuid().ToString('N'))"
. (Join-Path $RepoRoot 'scripts/live-transaction-common.ps1')

$script:pass = 0

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:pass++
    Write-Host "  PASS  $Message"
}

function Assert-ThrowsToken {
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [string] $Message
    )
    $threw = $false
    $actual = ''
    try { & $Action }
    catch {
        $threw = $true
        $actual = [string] $_.Exception.Message
    }
    if (-not $threw) { throw "FAIL: $Message (did not throw)" }
    if ($actual.IndexOf($Token, [System.StringComparison]::Ordinal) -lt 0) {
        throw "FAIL: $Message (unexpected: $actual)"
    }
    $script:pass++
    Write-Host "  PASS  $Message"
}

function New-TestHeader {
    param([Parameter(Mandatory)] [string] $TransactionId)
    return [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-journal-header'
        TransactionId = $TransactionId
        OperationKind = 'retirement'
        TransactionMode = 'receipt-backed'
        OriginalDocumentHash = ('1' * 64)
        OriginalPlanHash = ('2' * 64)
        HomeAuthorityKey = ('a' * 64)
        OriginRepoId = ('3' * 64)
        GitCommonDirHash = ('4' * 64)
        CanonicalLockKey = ('5' * 64)
        ReceiptIntent = [ordered]@{
            Id = $TransactionId
            Path = (Join-Path $work 'backups' $TransactionId)
        }
        Targets = @()
    }
}

function New-InstalledRecordData {
    return [ordered]@{
        TargetId = ('6' * 64)
        TargetKind = 'skill'
        TargetPath = (Join-Path $work 'live/claude/skills/kept-claude')
        SwapOldPath = (Join-Path $work 'staging/claude/swap/kept-claude')
        StagedPath = (Join-Path $work 'staging/claude/staged/kept-claude')
        TargetState = [ordered]@{ State = 'PRESENT'; Type = 'Directory'; Hash = ('7' * 64); Identity = 'a1b2c3d4:0000000000000b03' }
        SwapOldState = [ordered]@{ State = 'PRESENT'; Type = 'Directory'; Hash = ('8' * 64); Identity = 'a1b2c3d4:0000000000000b01' }
        StagedState = [ordered]@{ State = 'MISSING' }
    }
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'backups') | Out-Null

    Write-Host '[header publication]'
    $transactionId = [Guid]::NewGuid().ToString()
    $header = New-TestHeader -TransactionId $transactionId
    $transactionDir = Join-Path $work 'live-transactions' $transactionId
    $publication = New-SealedLiveJournalHeader -Document $header -TransactionDirectory $transactionDir
    Assert (Test-Path -LiteralPath (Join-Path $transactionDir 'header.json') -PathType Leaf) 'the header publishes as header.json'
    Assert ((Get-ChildItem -LiteralPath $transactionDir -Force | ForEach-Object Name | Sort-Object) -join ',' -ceq '_pending,header.json') 'the new namespace inventory is exactly _pending and header.json'
    $stored = ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText((Join-Path $transactionDir 'header.json'), [Text.UTF8Encoding]::new($false, $true)))
    Assert ([string] $stored.TransactionId -ceq $transactionId) 'the stored header round-trips'
    Assert-ThrowsToken { New-SealedLiveJournalHeader -Document (New-TestHeader -TransactionId ([Guid]::NewGuid().ToString())) -TransactionDirectory (Join-Path $work 'live-transactions' $transactionId) } 'live-transaction-already-terminal' 'a second header on an existing namespace fails create-new'

    Write-Host '[record publication]'
    Add-SealedLiveJournalRecord -TransactionDirectory $transactionDir -Phase 'RECEIPT_COMPLETE' -Data ([ordered]@{
        ReceiptRef = [ordered]@{ Id = $transactionId; Path = (Join-Path $work 'backups' $transactionId); Hash = ('9' * 64) }
    }) | Out-Null
    $splatData = New-InstalledRecordData
    Add-SealedLiveJournalRecord -TransactionDirectory $transactionDir -Phase 'MOVE_OLD_INTENT' -Data ([ordered]@{
        TargetId = ('6' * 64)
        TargetKind = 'skill'
        TargetPath = (Join-Path $work 'live/claude/skills/kept-claude')
        SwapOldPath = (Join-Path $work 'staging/claude/swap/kept-claude')
        TargetState = [ordered]@{ State = 'PRESENT'; Type = 'Directory'; Hash = ('7' * 64); Identity = 'a1b2c3d4:0000000000000b01' }
        SwapOldState = [ordered]@{ State = 'MISSING' }
    }) | Out-Null
    Add-SealedLiveJournalRecord -TransactionDirectory $transactionDir -Phase 'OLD_MOVED' -Data $splatData | Out-Null
    $chain = Get-SealedLiveJournalChain -TransactionDirectory $transactionDir
    Assert (@($chain.Records).Count -eq 3) 'three records are enumerated in order'
    $first = [System.Collections.IDictionary] $chain.Records[0]['Document']
    $secondRecord = [System.Collections.IDictionary] $chain.Records[1]['Document']
    Assert ([long] $secondRecord['Sequence'] -eq 2 -and [string] $secondRecord['PreviousHash'] -ceq (Get-SemanticJsonHash -InputObject $first)) 'the second record links to the first record hash'
    Assert ($null -eq $chain.Result -and $chain.UnknownNames.Count -eq 0) 'the open chain has no result and no unknown entries'

    Assert-ThrowsToken { Add-SealedLiveJournalRecord -TransactionDirectory $transactionDir -Phase 'RECOVERY_ACTION_APPLIED' -Data ([ordered]@{ Action = 'rollback' }) } 'manual-recovery-required' 'a recovery record without a preceding intent fails the chain'
    Assert-ThrowsToken {
        Add-SealedLiveJournalRecord -TransactionDirectory $transactionDir -Phase 'COMPLETE' -Data ([ordered]@{
            ResultHash = ('f' * 64)
            OriginalDocumentHash = ('1' * 64)
            Outcome = 'committed'
            ClosingKind = 'recovery'
        })
    } 'live-transaction-intent-mismatch' 'a COMPLETE record with recovery closing but no plan kind fails the closing oneOf'
    Assert-ThrowsToken {
        Add-SealedLiveJournalRecord -TransactionDirectory $transactionDir -Phase 'POSTCONDITIONS_OK' -Data ([ordered]@{
            PostconditionsHash = ('b' * 64)
            PlanKind = 'live-recover-rollback'
        })
    } 'live-transaction-intent-mismatch' 'a non-recovery record carrying recovery-only keys fails the phase contract'

    Write-Host '[result publication]'
    $headHash = Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] $chain.Records[-1]['Document'])
    $driftedResult = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-operation-result'
        ResultScope = 'transaction'
        TransactionId = $transactionId
        OperationKind = 'retirement'
        OriginalDocumentHash = ('1' * 64)
        ResultBaseHeadHash = ('f' * 64)
        Outcome = 'committed'
        ReceiptRef = [ordered]@{ Id = $transactionId; Path = (Join-Path $work 'backups' $transactionId); State = 'COMPLETE'; Hash = ('9' * 64) }
        ReceiptHash = ('9' * 64)
        StateHash = ('c' * 64)
    }
    Assert-ThrowsToken { Publish-SealedLiveTransactionResult -TransactionDirectory $transactionDir -Document $driftedResult } 'manual-recovery-required' 'a result bound to a head outside the chain fails closed'
    $result = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-operation-result'
        ResultScope = 'transaction'
        TransactionId = $transactionId
        OperationKind = 'retirement'
        OriginalDocumentHash = ('1' * 64)
        ResultBaseHeadHash = $headHash
        Outcome = 'committed'
        ReceiptRef = [ordered]@{ Id = $transactionId; Path = (Join-Path $work 'backups' $transactionId); State = 'COMPLETE'; Hash = ('9' * 64) }
        ReceiptHash = ('9' * 64)
        StateHash = ('c' * 64)
    }
    Publish-SealedLiveTransactionResult -TransactionDirectory $transactionDir -Document $result | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $transactionDir 'result.json') -PathType Leaf) 'the fixed result publishes as result.json'
    Assert-ThrowsToken { Publish-SealedLiveTransactionResult -TransactionDirectory $transactionDir -Document $result } 'live-transaction-result-already-exists' 'a second fixed result is rejected'
    $resultFileHash = (Get-FileHash -LiteralPath (Join-Path $transactionDir 'result.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $closedData = [ordered]@{
        ResultHash = $resultFileHash
        OriginalDocumentHash = ('1' * 64)
        Outcome = 'committed'
        ClosingKind = 'original'
        ClosingDocumentHash = ('1' * 64)
    }
    Add-SealedLiveJournalRecord -TransactionDirectory $transactionDir -Phase 'COMPLETE' -Data $closedData | Out-Null
    Assert-ThrowsToken { Publish-SealedLiveTransactionResult -TransactionDirectory $transactionDir -Document $result } 'live-transaction-result-already-exists' 'publishing a result after the terminal record stays rejected'

    Write-Host '[chain validator]'
    $chainAfter = Get-SealedLiveJournalChain -TransactionDirectory $transactionDir
    $null = Test-SealedLiveJournalChain -Header $chainAfter.Header -Records $chainAfter.Records -Result $chainAfter.Result
    Assert $true 'the complete chain with an original closing validates'
    $broken = @(@($chainAfter.Records[0..1]) + @($chainAfter.Records[0]))
    Assert-ThrowsToken { Test-SealedLiveJournalChain -Header $chainAfter.Header -Records $broken -Result $null } 'manual-recovery-required' 'a duplicate sequence fails the chain'
    $gap = @(@($chainAfter.Records[0]) + @($chainAfter.Records[2]))
    Assert-ThrowsToken { Test-SealedLiveJournalChain -Header $chainAfter.Header -Records $gap -Result $null } 'manual-recovery-required' 'a record gap fails the chain'
    $pendingDir = Join-Path $transactionDir '_pending'
    New-Item -ItemType Directory -Force -Path $pendingDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $pendingDir 'record-000004-deadbeef.tmp'), 'partial', [System.Text.UTF8Encoding]::new($false))
    $chainPending = Get-SealedLiveJournalChain -TransactionDirectory $transactionDir
    Assert ($chainPending.UnknownNames.Count -eq 0) 'a known _pending temp stays outside the chain namespace'
    $null = Test-SealedLiveJournalChain -Header $chainPending.Header -Records $chainPending.Records -Result $chainPending.Result
    Assert $true 'a pending temp does not disturb the closed chain validation'

    Write-Host '[result semantic matrix]'
    $stateOnly = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-operation-result'
        ResultScope = 'transaction'
        TransactionId = $transactionId
        OperationKind = 'controller-transition'
        OriginalDocumentHash = ('1' * 64)
        ResultBaseHeadHash = $headHash
        Outcome = 'committed'
        StateHash = ('c' * 64)
    }
    Test-LiveOperationResultSemantics -Document $stateOnly
    Assert $true 'a state-only committed result without receipt fields passes'
    $stateOnlyWithReceipt = [ordered]@{}
    foreach ($k in @($stateOnly.Keys)) { $stateOnlyWithReceipt[$k] = $stateOnly[$k] }
    $stateOnlyWithReceipt['ReceiptRef'] = [ordered]@{ Id = $transactionId; Path = (Join-Path $work 'backups' $transactionId); State = 'COMPLETE'; Hash = ('9' * 64) }
    Assert-ThrowsToken { Test-LiveOperationResultSemantics -Document $stateOnlyWithReceipt } 'live-transaction-intent-mismatch' 'a state-only result carrying a receipt fails closed'
    $rollbackMissingRestoration = [ordered]@{}
    foreach ($k in @($result.Keys)) { $rollbackMissingRestoration[$k] = $result[$k] }
    $rollbackMissingRestoration['Outcome'] = 'rolled-back'
    Assert-ThrowsToken { Test-LiveOperationResultSemantics -Document $rollbackMissingRestoration } 'live-transaction-intent-mismatch' 'a rolled-back result without restoration proof fails closed'

    Write-Host 'live recovery tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
