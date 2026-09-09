#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-live-recovery-$([Guid]::NewGuid().ToString('N'))"
. (Join-Path $RepoRoot 'scripts/live-transaction-common.ps1')
. (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')

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

function Write-TextFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
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


    Write-Host '[live mutation engine: retirement sequence]'
    $engineWork = Join-Path $work 'engine'
    $liveClaude = Join-Path $engineWork 'live/claude/skills'
    $liveCodex = Join-Path $engineWork 'live/codex/skills'
    $stagingClaude = Join-Path $engineWork 'staging/claude'
    $stagingCodex = Join-Path $engineWork 'staging/codex'
    $stagingReasonix = Join-Path $engineWork 'staging/reasonix'
    $liveReasonix = Join-Path $engineWork 'live/reasonix/skills'
    $backupRootEngine = Join-Path $engineWork 'backups'
    foreach ($dir in @(
        (Join-Path $liveClaude 'kept-claude'),
        (Join-Path $liveCodex 'retired-codex'), (Join-Path $liveClaude 'second-add'),
        $liveReasonix, $stagingClaude, $stagingCodex, $stagingReasonix, $backupRootEngine
    )) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Write-TextFile -Path (Join-Path $liveClaude 'kept-claude/SKILL.md') -Content 'kept-old'
    Write-TextFile -Path (Join-Path $liveClaude 'second-add/SKILL.md') -Content 'second-live'
    Write-TextFile -Path (Join-Path $liveCodex 'retired-codex/SKILL.md') -Content 'retired-old'
    $sourceTree = Join-Path $engineWork 'source/claude/skills'
    New-Item -ItemType Directory -Force -Path (Join-Path $sourceTree 'kept-claude'), (Join-Path $sourceTree 'added-claude') | Out-Null
    Write-TextFile -Path (Join-Path $sourceTree 'kept-claude/SKILL.md') -Content 'kept-new'
    Write-TextFile -Path (Join-Path $sourceTree 'added-claude/SKILL.md') -Content 'added-new'
    $keptOldHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveClaude 'kept-claude')).TreeHash
    $keptNewHash = (Get-SafeTreeSnapshot -Root (Join-Path $sourceTree 'kept-claude')).TreeHash
    $addedNewHash = (Get-SafeTreeSnapshot -Root (Join-Path $sourceTree 'added-claude')).TreeHash
    $retiredOldHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveCodex 'retired-codex')).TreeHash

    $engineTransactionId = [Guid]::NewGuid().ToString()
    $engineReceiptId = [Guid]::NewGuid().ToString()
    $engineHeader = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-journal-header'
        TransactionId = $engineTransactionId
        OperationKind = 'retirement'
        TransactionMode = 'receipt-backed'
        OriginalDocumentHash = ('1' * 64)
        OriginalPlanHash = ('2' * 64)
        HomeAuthorityKey = ('a' * 64)
        OriginRepoId = ('3' * 64)
        GitCommonDirHash = ('4' * 64)
        CanonicalLockKey = ('5' * 64)
        ReceiptIntent = [ordered]@{
            Id = $engineReceiptId
            Path = (Join-Path $backupRootEngine $engineReceiptId)
        }
        Targets = @()
    }
    $engineReceiptIntent = [ordered]@{
        TransactionId = $engineTransactionId
        ReceiptId = $engineReceiptId
        ReceiptPath = (Join-Path $backupRootEngine $engineReceiptId)
    }
    $engineDir = Join-Path $engineWork 'live-transactions' $engineTransactionId
    New-SealedLiveJournalHeader -Document $engineHeader -TransactionDirectory $engineDir | Out-Null

    # The receipt snapshots the pre-change managed targets exactly as the
    # transaction targets bind them.
    $receiptPlatforms = @(
        [ordered]@{
            Platform = 'Claude'
            LiveRoot = $liveClaude
            Targets = @(
                [ordered]@{ Name = 'kept-claude'; LivePath = (Join-Path $liveClaude 'kept-claude'); PlannedTreeHash = $keptOldHash },
                [ordered]@{ Name = 'added-claude'; LivePath = (Join-Path $liveClaude 'added-claude'); PlannedTreeHash = $null }
            )
        },
        [ordered]@{
            Platform = 'Codex'
            LiveRoot = $liveCodex
            Targets = @(
                [ordered]@{ Name = 'retired-codex'; LivePath = (Join-Path $liveCodex 'retired-codex'); PlannedTreeHash = $retiredOldHash }
            )
        },
        [ordered]@{
            Platform = 'Reasonix'
            LiveRoot = $liveReasonix
            Targets = @()
        }
    )
    $engineReceiptSplat = @{
        ReservationIntent = $engineReceiptIntent
        SourceOperationKind = 'retirement'
        PlanHash = ('1' * 64)
        DocumentHash = ('2' * 64)
        ExecutionContextHash = ('3' * 64)
        ControlBaseHash = ('4' * 64)
        FilesystemCapabilityHash = ('5' * 64)
        HomeAuthorityKey = ('a' * 64)
        BackupRoot = $backupRootEngine
        Platforms = $receiptPlatforms
        ForbiddenRoots = @()
    }
    $engineReceipt = Invoke-SealedManagedBackupReceipt @engineReceiptSplat

    $engineActions = @(
        [ordered]@{ Platform = 'Claude'; Action = 'update'; Name = 'kept-claude'; SourceHash = $keptNewHash; LiveHash = $keptOldHash },
        [ordered]@{ Platform = 'Claude'; Action = 'add'; Name = 'added-claude'; SourceHash = $addedNewHash; LiveHash = $null },
        [ordered]@{ Platform = 'Codex'; Action = 'prune'; Name = 'retired-codex'; SourceHash = $null; LiveHash = $retiredOldHash }
    )
    $engineContexts = @(
        [ordered]@{ Platform = 'Claude'; LiveRoot = $liveClaude; DeepestExistingParentPath = $liveClaude; MissingRemainder = @(); StagingRoot = $stagingClaude },
        [ordered]@{ Platform = 'Codex'; LiveRoot = $liveCodex; DeepestExistingParentPath = $liveCodex; MissingRemainder = @(); StagingRoot = $stagingCodex },
        [ordered]@{ Platform = 'Reasonix'; LiveRoot = $liveReasonix; DeepestExistingParentPath = $liveReasonix; MissingRemainder = @(); StagingRoot = $stagingReasonix }
    )
    $engineTargets = New-SealedLiveTransactionTargetPlan -BackupRoot $backupRootEngine -ReceiptIntent $engineHeader['ReceiptIntent'] -Platforms $receiptPlatforms -Actions $engineActions -LiveRootContexts $engineContexts
    Assert (@($engineTargets).Count -eq 3) 'the target plan binds exactly three mutation targets'
    New-Item -ItemType Directory -Force -Path (Join-Path $engineWork 'source/codex/skills') | Out-Null
    $engineSourceRoots = [ordered]@{ Claude = $sourceTree; Codex = (Join-Path $engineWork 'source/codex/skills') }
    $mutationResult = Invoke-SealedLiveTransactionMutation -TransactionDirectory $engineDir -Header $engineHeader -Receipt $engineReceipt -Targets $engineTargets -SourceRootsByPlatform $engineSourceRoots

    Assert ((Get-Content -Raw -LiteralPath (Join-Path $liveClaude 'kept-claude/SKILL.md')) -eq 'kept-new') 'the update target installs the new bytes'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $liveClaude 'added-claude/SKILL.md')) -eq 'added-new') 'the add target installs the staged copy'
    Assert (-not (Test-Path -LiteralPath (Join-Path $liveCodex 'retired-codex'))) 'the prune target is removed from live'
    Assert (Test-Path -LiteralPath (Join-Path $stagingCodex 'swap/retired-codex/SKILL.md')) 'the pruned old copy is preserved in swap-old'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $stagingClaude 'swap/kept-claude/SKILL.md')) -eq 'kept-old') 'the update old copy is preserved in swap-old'
    Assert (-not (Test-Path -LiteralPath (Join-Path $stagingClaude 'staged/added-claude'))) 'the installed add target leaves no staged copy'
    $engineChain = Get-SealedLiveJournalChain -TransactionDirectory $engineDir
    $phases = @($engineChain.Records | ForEach-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] })
    Assert (@($phases | Where-Object { $_ -ceq 'RECEIPT_COMPLETE' }).Count -eq 1) 'the engine publishes exactly one RECEIPT_COMPLETE record'
    Assert (@($phases | Where-Object { $_ -ceq 'NEW_INSTALLED' }).Count -eq 3) 'the engine publishes three NEW_INSTALLED records'
    Assert (@($phases | Where-Object { $_ -ceq 'POSTCONDITIONS_OK' }).Count -eq 1) 'the engine publishes the aggregate POSTCONDITIONS_OK record'
    $null = Test-SealedLiveJournalChain -Header $engineChain.Header -Records $engineChain.Records -Result $null
    Assert $true 'the engine journal chain validates end to end'

    Write-Host '[live mutation engine: failure restoration]'
    $restoreTransactionId = [Guid]::NewGuid().ToString()
    $restoreReceiptId = [Guid]::NewGuid().ToString()
    $restoreHeader = [ordered]@{}
    foreach ($k in @($engineHeader.Keys)) { $restoreHeader[$k] = $engineHeader[$k] }
    $restoreHeader['TransactionId'] = $restoreTransactionId
    $restoreHeader['ReceiptIntent'] = [ordered]@{
        Id = $restoreReceiptId
        Path = (Join-Path $backupRootEngine $restoreReceiptId)
    }
    $restoreIntent = [ordered]@{
        TransactionId = $restoreTransactionId
        ReceiptId = $restoreReceiptId
        ReceiptPath = (Join-Path $backupRootEngine $restoreReceiptId)
    }
    $restoreDir = Join-Path $engineWork 'live-transactions' $restoreTransactionId
    New-SealedLiveJournalHeader -Document $restoreHeader -TransactionDirectory $restoreDir | Out-Null
    $restorePlatforms = @(
        [ordered]@{
            Platform = 'Claude'
            LiveRoot = $liveClaude
            Targets = @(
                [ordered]@{ Name = 'kept-claude'; LivePath = (Join-Path $liveClaude 'kept-claude'); PlannedTreeHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveClaude 'kept-claude')).TreeHash },
                [ordered]@{ Name = 'second-add'; LivePath = (Join-Path $liveClaude 'second-add'); PlannedTreeHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveClaude 'second-add')).TreeHash }
            )
        },
        [ordered]@{ Platform = 'Codex'; LiveRoot = $liveCodex; Targets = @() },
        [ordered]@{ Platform = 'Reasonix'; LiveRoot = $liveReasonix; Targets = @() }
    )
    $restoreReceiptSplat = @{
        ReservationIntent = $restoreIntent
        SourceOperationKind = 'retirement'
        PlanHash = ('1' * 64)
        DocumentHash = ('2' * 64)
        ExecutionContextHash = ('3' * 64)
        ControlBaseHash = ('4' * 64)
        FilesystemCapabilityHash = ('5' * 64)
        HomeAuthorityKey = ('a' * 64)
        BackupRoot = $backupRootEngine
        Platforms = $restorePlatforms
        ForbiddenRoots = @()
    }
    $restoreReceipt = Invoke-SealedManagedBackupReceipt @restoreReceiptSplat
    $restoreStagingClaude = Join-Path $engineWork 'staging/claude2'
    $restoreStagingCodex = Join-Path $engineWork 'staging/codex2'
    New-Item -ItemType Directory -Force -Path $restoreStagingClaude, $restoreStagingCodex, (Join-Path $engineWork 'source/claude2/skills/kept-claude'), (Join-Path $engineWork 'source/claude2/skills/second-add') | Out-Null
    Write-TextFile -Path (Join-Path $engineWork 'source/claude2/skills/kept-claude/SKILL.md') -Content 'kept-v3'
    Write-TextFile -Path (Join-Path $engineWork 'source/claude2/skills/second-add/SKILL.md') -Content 'second-new'
    $keptCurrentHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveClaude 'kept-claude')).TreeHash
    $restoreActions = @(
        [ordered]@{ Platform = 'Claude'; Action = 'update'; Name = 'kept-claude'; SourceHash = (Get-SafeTreeSnapshot -Root (Join-Path $engineWork 'source/claude2/skills/kept-claude')).TreeHash; LiveHash = $keptCurrentHash },
        [ordered]@{ Platform = 'Claude'; Action = 'add'; Name = 'second-add'; SourceHash = ('9' * 64); LiveHash = $null }
    )
    $restoreTargets = New-SealedLiveTransactionTargetPlan -BackupRoot $backupRootEngine -ReceiptIntent $restoreHeader['ReceiptIntent'] -Platforms $receiptPlatforms -Actions $restoreActions -LiveRootContexts @(
        [ordered]@{ Platform = 'Claude'; LiveRoot = $liveClaude; DeepestExistingParentPath = $liveClaude; MissingRemainder = @(); StagingRoot = $restoreStagingClaude },
        [ordered]@{ Platform = 'Codex'; LiveRoot = $liveCodex; DeepestExistingParentPath = $liveCodex; MissingRemainder = @(); StagingRoot = $restoreStagingCodex },
        [ordered]@{ Platform = 'Reasonix'; LiveRoot = $liveReasonix; DeepestExistingParentPath = $liveReasonix; MissingRemainder = @(); StagingRoot = (Join-Path $engineWork 'staging/reasonix2') }
    )
    $engineSourceRoots2 = [ordered]@{ Claude = (Join-Path $engineWork 'source/claude2/skills'); Codex = (Join-Path $engineWork 'source/codex/skills') }
    $driftThrew = $false
    $driftError = $null
    try {
        Invoke-SealedLiveTransactionMutation -TransactionDirectory $restoreDir -Header $restoreHeader -Receipt $restoreReceipt -Targets $restoreTargets -SourceRootsByPlatform $engineSourceRoots2
    }
    catch {
        $driftThrew = $true
        $driftError = $_
    }
    Assert $driftThrew 'a drifted second target fails the sequence after the first target installed'
    Assert ($driftError.Exception.Message -match 'live-transaction-hash-mismatch') 'the drift failure carries the hash-mismatch token'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $liveClaude 'kept-claude/SKILL.md')) -eq 'kept-new') 'the failed update target restores the old content into live'
    Assert (Test-Path -LiteralPath (Join-Path $restoreStagingClaude 'staged/kept-claude/SKILL.md')) 'the installed new copy returns to staging as recovery material'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $liveClaude 'second-add/SKILL.md')) -eq 'second-live') 'the drifted second target stays untouched in live'
    $restoreChain = Get-SealedLiveJournalChain -TransactionDirectory $restoreDir
    $restorePhases = @($restoreChain.Records | ForEach-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] })
    Assert (@($restorePhases | Where-Object { $_ -ceq 'NEW_INSTALLED' }).Count -eq 1) 'only the first target reached NEW_INSTALLED before the drift failure'
    Assert (@($restorePhases | Where-Object { $_ -ceq 'COMPLETE' }).Count -eq 0) 'the failed sequence publishes no terminal record'

    Write-Host 'live recovery tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
