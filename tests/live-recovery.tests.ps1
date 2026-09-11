#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-live-recovery-$([Guid]::NewGuid().ToString('N'))"
$dispatchWork = $null
$internalHost = Join-Path $RepoRoot 'scripts/internal/live-transaction-host.ps1'
$liveTransactionHost = Join-Path $PSScriptRoot 'helpers/live-transaction-host.ps1'
. (Join-Path $RepoRoot 'scripts/live-transaction-common.ps1')
. (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/failpoint-controller.ps1')

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
    $null = Test-SealedLiveJournalChain -Header $chainAfter.Header -Records $chainAfter.Records -Result $chainAfter.Result -ResultFileHash $chainAfter.ResultFileHash
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
    $null = Test-SealedLiveJournalChain -Header $chainPending.Header -Records $chainPending.Records -Result $chainPending.Result -ResultFileHash $chainPending.ResultFileHash
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



    Write-Host '[live mutation engine: state context helpers]'
    function New-EngineTargetContextIntent {
        param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Platforms)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($platformRow in @($Platforms)) {
            $platform = [string] $platformRow.Platform
            $liveRoot = [string] $platformRow.LiveRoot
            $context = Get-TargetMetadataContext -Path $liveRoot
            $identity = [string] $context.Ancestors[-1].Identity
            $rows.Add([ordered]@{
                Platform = $platform
                LocationKey = [string] $context.LocationKey
                RequestedPath = [string] $context.RequestedPath
                InitialState = 'EXISTS'
                VolumeId = [string] $context.VolumeId
                DeepestExistingParentPath = [string] $context.RequestedPath
                DeepestExistingParentIdentity = $identity
                MissingRemainder = @()
                InitialDirectoryIdentity = $identity
                ExpectedPostState = 'EXISTS'
            })
        }
        return [ordered]@{
            HomeAuthorityKey = ('a' * 64)
            Rows = @($rows)
        }
    }

    function New-EngineAuthorityStateIntent {
        param(
            [Parameter(Mandatory)] [string] $ClaimsHash,
            [Parameter(Mandatory)] [string] $PlanHash,
            [Parameter(Mandatory)] [string] $DocumentHash
        )
        return [ordered]@{
            SchemaVersion = 3
            ArtifactKind = 'current-env-state'
            HomeAuthorityKey = ('a' * 64)
            AuthorityGeneration = 1
            RootClaimsHash = $ClaimsHash
            SelectionKind = 'environment'
            EnvironmentName = 'work'
            EnvironmentLockHash = ('6' * 64)
            TaskOverlayHash = ('7' * 64)
            TaskOverlaySkills = @(
                [ordered]@{ Platform = 'Claude'; Skills = @() },
                [ordered]@{ Platform = 'Codex'; Skills = @() },
                [ordered]@{ Platform = 'Reasonix'; Skills = @() }
            )
            ManifestHashes = @(
                [ordered]@{ Platform = 'Claude'; Hash = ('b' * 64) },
                [ordered]@{ Platform = 'Codex'; Hash = ('c' * 64) },
                [ordered]@{ Platform = 'Reasonix'; Hash = ('d' * 64) }
            )
            FinalManagedHashes = @(
                [ordered]@{ Platform = 'Claude'; Hash = ('1' * 64) },
                [ordered]@{ Platform = 'Codex'; Hash = ('2' * 64) },
                [ordered]@{ Platform = 'Reasonix'; Hash = ('3' * 64) }
            )
            ControllerRepoFingerprint = ('5' * 64)
            ApprovedToolchainHash = ('4' * 64)
            PlanHash = $PlanHash
            DocumentHash = $DocumentHash
            LastOperationKind = 'retirement'
        }
    }

    function New-EngineControllerAuthorityStateIntent {
        param(
            [Parameter(Mandatory)] [string] $ClaimsHash,
            [Parameter(Mandatory)] [string] $PlanHash,
            [Parameter(Mandatory)] [string] $DocumentHash
        )
        $intent = New-EngineAuthorityStateIntent -ClaimsHash $ClaimsHash -PlanHash $PlanHash -DocumentHash $DocumentHash
        $intent['LastOperationKind'] = 'controller-transition'
        $intent['ReceiptRef'] = 'NO_LIVE_MUTATION'
        $intent['AuthorityGeneration'] = 2
        $intent['ControllerRepoFingerprint'] = ('e' * 64)
        $intent['ApprovedToolchainHash'] = ('f' * 64)
        return $intent
    }

    function Sync-EngineIntentIdentities {
        param([Parameter(Mandatory)] [System.Collections.IDictionary] $TargetContextIntent)
        foreach ($row in @([object[]] $TargetContextIntent['Rows'])) {
            $identity = [string] ([AiAgentDotfiles.NoFollowFile]::Inspect([string] $row['RequestedPath'])).Identity
            $row['InitialDirectoryIdentity'] = $identity
            $row['DeepestExistingParentIdentity'] = $identity
        }
        return $TargetContextIntent
    }

    function New-EnginePreviousStateDocument {
        param(
            [Parameter(Mandatory)] [System.Collections.IDictionary] $TargetContextIntent,
            [Parameter(Mandatory)] [string] $ClaimsHash,
            [Parameter(Mandatory)] [System.Collections.IDictionary] $CapabilityHashes
        )
        $identities = [System.Collections.Generic.List[object]]::new()
        foreach ($row in @([object[]] $TargetContextIntent['Rows'])) {
            $platform = [string] $row['Platform']
            $identities.Add([ordered]@{
                Platform = $platform
                LocationKey = [string] $row['LocationKey']
                ResolvedPath = [string] $row['RequestedPath']
                VolumeId = [string] $row['VolumeId']
                DirectoryIdentity = [string] $row['InitialDirectoryIdentity']
                FilesystemCapabilityHash = [string] $CapabilityHashes[$platform]
            })
        }
        $identityRows = @($identities)
        $state = [ordered]@{
            SchemaVersion = 3
            ArtifactKind = 'current-env-state'
            HomeAuthorityKey = ('a' * 64)
            AuthorityGeneration = 1
            RootClaimsHash = $ClaimsHash
            SelectionKind = 'environment'
            EnvironmentName = 'work'
            EnvironmentLockHash = ('6' * 64)
            TaskOverlayHash = ('7' * 64)
            TaskOverlaySkills = @(
                [ordered]@{ Platform = 'Claude'; Skills = @() },
                [ordered]@{ Platform = 'Codex'; Skills = @() },
                [ordered]@{ Platform = 'Reasonix'; Skills = @() }
            )
            ManifestHashes = @(
                [ordered]@{ Platform = 'Claude'; Hash = ('b' * 64) },
                [ordered]@{ Platform = 'Codex'; Hash = ('c' * 64) },
                [ordered]@{ Platform = 'Reasonix'; Hash = ('d' * 64) }
            )
            FinalManagedHashes = @(
                [ordered]@{ Platform = 'Claude'; Hash = ('1' * 64) },
                [ordered]@{ Platform = 'Codex'; Hash = ('2' * 64) },
                [ordered]@{ Platform = 'Reasonix'; Hash = ('3' * 64) }
            )
            ControllerRepoFingerprint = ('5' * 64)
            ApprovedToolchainHash = ('4' * 64)
            PlanHash = ('1' * 64)
            DocumentHash = ('2' * 64)
            LastOperationKind = 'retirement'
            ReceiptId = [Guid]::NewGuid().ToString()
            ReceiptHash = ('e' * 64)
            JournalId = [Guid]::NewGuid().ToString()
            PreStatePhaseHash = ('0' * 64)
            FinalResolvedIdentities = $identityRows
            FinalTargetContextHash = (Get-SemanticJsonHash -InputObject @($identityRows))
        }
        Test-CurrentEnvStateSemantics -Document $state
        return $state
    }

    function Get-LiveJournalLastPhase {
        param([Parameter(Mandatory)] [string] $TransactionDirectory)
        $chain = Get-SealedLiveJournalChain -TransactionDirectory $TransactionDirectory
        if (@($chain.Records).Count -eq 0) { return $null }
        return [string] ([System.Collections.IDictionary] $chain.Records[-1]['Document'])['Phase']
    }

    function Get-LiveJournalCompletedFromChain {
        param([Parameter(Mandatory)] $Chain)
        $completed = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($Chain.Records)) {
            $document = [System.Collections.IDictionary] $entry['Document']
            $phase = [string] $document['Phase']
            $data = [System.Collections.IDictionary] $document['Data']
            if ($phase -ceq 'DIR_CREATED') {
                $completed.Add([ordered]@{
                    TargetId = [string] $data['TargetId']
                    Phase = $phase
                    CreatedIdentity = [string] $data['CreatedIdentity']
                })
            }
            elseif ($phase -ceq 'OLD_MOVED' -or $phase -ceq 'NEW_INSTALLED') {
                $completed.Add([ordered]@{
                    TargetId = [string] $data['TargetId']
                    Phase = $phase
                })
            }
        }
        return @($completed)
    }

    function Get-FileByteHash {
        param([Parameter(Mandatory)] [string] $Path)
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }

    Write-Host '[live mutation engine: retirement sequence]'
    $engineWork = Join-Path $work 'engine'
    $liveClaude = Join-Path $engineWork 'live/claude/skills'
    $liveCodex = Join-Path $engineWork 'live/codex/skills'
    $liveReasonix = Join-Path $engineWork 'live/reasonix/skills'
    $stagingClaude = Join-Path $engineWork 'staging/claude'
    $stagingCodex = Join-Path $engineWork 'staging/codex'
    $stagingReasonix = Join-Path $engineWork 'staging/reasonix'
    $backupRootEngine = Join-Path $engineWork 'backups'
    foreach ($dir in @(
        (Join-Path $liveClaude 'kept-claude'),
        (Join-Path $liveCodex 'retired-codex'), (Join-Path $liveClaude 'second-add'),
        $liveReasonix, $stagingClaude, $stagingCodex, $stagingReasonix, $backupRootEngine
    )) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Write-TextFile -Path (Join-Path $liveClaude 'kept-claude/SKILL.md') -Content 'kept-old'
    Write-TextFile -Path (Join-Path $liveCodex 'retired-codex/SKILL.md') -Content 'retired-old'
    Write-TextFile -Path (Join-Path $liveClaude 'second-add/SKILL.md') -Content 'second-live'
    $sourceTree = Join-Path $engineWork 'source/claude/skills'
    New-Item -ItemType Directory -Force -Path (Join-Path $sourceTree 'kept-claude'), (Join-Path $sourceTree 'added-claude') | Out-Null
    Write-TextFile -Path (Join-Path $sourceTree 'kept-claude/SKILL.md') -Content 'kept-new'
    Write-TextFile -Path (Join-Path $sourceTree 'added-claude/SKILL.md') -Content 'added-new'
    $engineControlBase = Join-Path $engineWork 'control'
    $engineAuthorityKey = ('a' * 64)
    $engineClaimsBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{"artifact":"root-claims","fixture":"engine"}')
    $engineClaimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($engineClaimsBytes)).ToLowerInvariant()
    $engineCapabilityHashes = [ordered]@{ Claude = ('9' * 64); Codex = ('8' * 64); Reasonix = ('7' * 64) }
    $authorityDir = Join-Path (Join-Path $engineControlBase 'homes') $engineAuthorityKey
    New-Item -ItemType Directory -Force -Path $authorityDir | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $authorityDir 'root-claims.json'), $engineClaimsBytes)
    [System.IO.File]::WriteAllText((Join-Path $authorityDir 'current-env.json'), '{"artifact":"current-env-state","fixture":"pre-existing"}', [System.Text.UTF8Encoding]::new($false))

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
        HomeAuthorityKey = $engineAuthorityKey
        OriginRepoId = ('3' * 64)
        GitCommonDirHash = ('4' * 64)
        CanonicalLockKey = ('5' * 64)
        RootClaimsHash = $engineClaimsHash
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

    $receiptPlatforms = @(
        [ordered]@{
            Platform = 'Claude'
            LiveRoot = $liveClaude
            Targets = @(
                [ordered]@{ Name = 'kept-claude'; LivePath = (Join-Path $liveClaude 'kept-claude'); PlannedTreeHash = $keptOldHash }
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
        HomeAuthorityKey = $engineAuthorityKey
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
    $engineSourceRoots = [ordered]@{ Claude = $sourceTree; Codex = (Join-Path $engineWork 'source/codex/skills'); Reasonix = (Join-Path $engineWork 'live/reasonix/skills') }
    $engineTargetContext = New-EngineTargetContextIntent -Platforms $receiptPlatforms
    $mutationResult = Invoke-SealedLiveTransactionMutation -TransactionDirectory $engineDir -Header $engineHeader -Receipt $engineReceipt -Targets $engineTargets -SourceRootsByPlatform $engineSourceRoots -AuthorityStateIntent (New-EngineAuthorityStateIntent -ClaimsHash $engineClaimsHash -PlanHash ('1' * 64) -DocumentHash ('2' * 64)) -TargetContextIntent $engineTargetContext -FinalCapabilityHashesByPlatform $engineCapabilityHashes -ControlBase $engineControlBase -StateRecoveryDirectory (Join-Path $stagingClaude 'state-recovery')

    Assert ((Get-Content -Raw -LiteralPath (Join-Path $liveClaude 'kept-claude/SKILL.md')) -eq 'kept-new') 'the update target installs the new bytes'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $liveClaude 'added-claude/SKILL.md')) -eq 'added-new') 'the add target installs the staged copy'
    Assert (-not (Test-Path -LiteralPath (Join-Path $liveCodex 'retired-codex'))) 'the prune target is removed from live'
    Assert (Test-Path -LiteralPath (Join-Path $stagingCodex 'swap/retired-codex/SKILL.md')) 'the pruned old copy is preserved in swap-old'
    Assert (-not (Test-Path -LiteralPath (Join-Path $stagingClaude 'staged/added-claude'))) 'the installed add target leaves no staged copy'
    $engineChain = Get-SealedLiveJournalChain -TransactionDirectory $engineDir
    $phases = @($engineChain.Records | ForEach-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] })
    Assert (@($phases | Where-Object { $_ -ceq 'RECEIPT_COMPLETE' }).Count -eq 1) 'the engine publishes exactly one RECEIPT_COMPLETE record'
    Assert (@($phases | Where-Object { $_ -ceq 'NEW_INSTALLED' }).Count -eq 3) 'the engine publishes three NEW_INSTALLED records'
    Assert (@($phases | Where-Object { $_ -ceq 'STATE_PUBLISHED' }).Count -eq 1) 'the engine publishes the authority state record'
    Assert (@($phases | Where-Object { $_ -ceq 'POSTCONDITIONS_OK' }).Count -eq 1) 'the engine publishes the aggregate POSTCONDITIONS_OK record'
    Assert (@($phases | Where-Object { $_ -ceq 'COMPLETE' }).Count -eq 1) 'the engine publishes the terminal record'
    Assert ($null -ne $engineChain.Result -and [string] $engineChain.Result.Outcome -ceq 'committed') 'the engine publishes the committed fixed result'
    $null = Test-SealedLiveJournalChain -Header $engineChain.Header -Records $engineChain.Records -Result $engineChain.Result -ResultFileHash $engineChain.ResultFileHash
    Assert $true 'the engine journal chain validates end to end'
    $installedStateBytes = [System.IO.File]::ReadAllBytes((Join-Path $authorityDir 'current-env.json'))
    $installedStateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($installedStateBytes)).ToLowerInvariant()
    Assert ($installedStateHash -ceq [string] $mutationResult.StateHash) 'the installed state bytes match the returned StateHash'
    Assert (Test-Path -LiteralPath (Join-Path $stagingClaude 'state-recovery/current-env.preimage.json')) 'the old state recovery copy is retained'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $authorityDir 'root-claims.json')) -notmatch 'placeholder-changed') 'the immutable claims file is untouched by existing-authority transactions'

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
        HomeAuthorityKey = $engineAuthorityKey
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
        [ordered]@{ Platform = 'Claude'; Action = 'update'; Name = 'second-add'; SourceHash = ('9' * 64); LiveHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveClaude 'second-add')).TreeHash }
    )
    $restoreTargets = New-SealedLiveTransactionTargetPlan -BackupRoot $backupRootEngine -ReceiptIntent $restoreHeader['ReceiptIntent'] -Platforms $restorePlatforms -Actions $restoreActions -LiveRootContexts @(
        [ordered]@{ Platform = 'Claude'; LiveRoot = $liveClaude; DeepestExistingParentPath = $liveClaude; MissingRemainder = @(); StagingRoot = $restoreStagingClaude },
        [ordered]@{ Platform = 'Codex'; LiveRoot = $liveCodex; DeepestExistingParentPath = $liveCodex; MissingRemainder = @(); StagingRoot = $restoreStagingCodex },
        [ordered]@{ Platform = 'Reasonix'; LiveRoot = $liveReasonix; DeepestExistingParentPath = $liveReasonix; MissingRemainder = @(); StagingRoot = (Join-Path $engineWork 'staging/reasonix2') }
    )
    $engineSourceRoots2 = [ordered]@{ Claude = (Join-Path $engineWork 'source/claude2/skills'); Codex = (Join-Path $engineWork 'source/codex/skills'); Reasonix = $liveReasonix }
    $driftThrew = $false
    $driftError = $null
    try {
        Invoke-SealedLiveTransactionMutation -TransactionDirectory $restoreDir -Header $restoreHeader -Receipt $restoreReceipt -Targets $restoreTargets -SourceRootsByPlatform $engineSourceRoots2 -AuthorityStateIntent (New-EngineAuthorityStateIntent -ClaimsHash $engineClaimsHash -PlanHash ('1' * 64) -DocumentHash ('2' * 64)) -TargetContextIntent $engineTargetContext -FinalCapabilityHashesByPlatform $engineCapabilityHashes -ControlBase $engineControlBase -StateRecoveryDirectory (Join-Path $restoreStagingClaude 'state-recovery')
    }
    catch {
        $driftThrew = $true
        $driftError = $_
    }
    Assert $driftThrew 'a drifted second target fails the sequence after the first target installed'
    Assert ($driftError.Exception.Message -match 'apply-failed-but-restored') 'the drift failure publishes failed-restored and exits apply-failed-but-restored'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $liveClaude 'kept-claude/SKILL.md')) -eq 'kept-new') 'the failed update target restores the old content into live'
    Assert (Test-Path -LiteralPath (Join-Path $restoreStagingClaude 'staged/kept-claude/SKILL.md')) 'the installed new copy returns to staging as recovery material'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $liveClaude 'second-add/SKILL.md')) -eq 'second-live') 'the drifted second target stays untouched in live'
    $restoreChain = Get-SealedLiveJournalChain -TransactionDirectory $restoreDir
    $restorePhases = @($restoreChain.Records | ForEach-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] })
    Assert (@($restorePhases | Where-Object { $_ -ceq 'NEW_INSTALLED' }).Count -eq 1) 'only the first target reached NEW_INSTALLED before the drift failure'
    Assert (@($restorePhases | Where-Object { $_ -ceq 'COMPLETE' }).Count -eq 1) 'the verified restoration publishes the terminal record'
    Assert ($null -ne $restoreChain.Result -and [string] $restoreChain.Result.Outcome -ceq 'failed-restored') 'the verified restoration publishes the failed-restored fixed result'
    $restoreStateBytes = [System.IO.File]::ReadAllBytes((Join-Path $authorityDir 'current-env.json'))
    $restoreStateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($restoreStateBytes)).ToLowerInvariant()
    Assert ([string] $restoreChain.Result.StateHash -ceq $restoreStateHash) 'the failed-restored result binds the unchanged old state hash'
    Assert (Test-Path -LiteralPath (Join-Path $authorityDir 'root-claims.json')) 'existing claims are retained by failed-restored classification'

    Write-Host '[live mutation engine: state-only controller-transition]'
    $stateOnlyWork = Join-Path $work 'state-only'
    $stateOnlyLiveClaude = Join-Path $stateOnlyWork 'live/claude/skills'
    $stateOnlyLiveCodex = Join-Path $stateOnlyWork 'live/codex/skills'
    $stateOnlyLiveReasonix = Join-Path $stateOnlyWork 'live/reasonix/skills'
    foreach ($dir in @($stateOnlyLiveClaude, $stateOnlyLiveCodex, $stateOnlyLiveReasonix)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Write-TextFile -Path (Join-Path $stateOnlyLiveClaude 'kept-claude/SKILL.md') -Content 'state-only-claude'
    Write-TextFile -Path (Join-Path $stateOnlyLiveCodex 'kept-codex/SKILL.md') -Content 'state-only-codex'
    Write-TextFile -Path (Join-Path $stateOnlyLiveReasonix 'kept-reasonix/SKILL.md') -Content 'state-only-reasonix'
    $stateOnlyControlBase = Join-Path $stateOnlyWork 'control'
    $stateOnlyAuthorityDir = Join-Path (Join-Path $stateOnlyControlBase 'homes') $engineAuthorityKey
    New-Item -ItemType Directory -Force -Path $stateOnlyAuthorityDir | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $stateOnlyAuthorityDir 'root-claims.json'), $engineClaimsBytes)
    $stateOnlyPlatforms = @(
        [ordered]@{ Platform = 'Claude'; LiveRoot = $stateOnlyLiveClaude },
        [ordered]@{ Platform = 'Codex'; LiveRoot = $stateOnlyLiveCodex },
        [ordered]@{ Platform = 'Reasonix'; LiveRoot = $stateOnlyLiveReasonix }
    )
    $stateOnlyTargetContext = Sync-EngineIntentIdentities -TargetContextIntent (New-EngineTargetContextIntent -Platforms $stateOnlyPlatforms)
    $previousState = New-EnginePreviousStateDocument -TargetContextIntent $stateOnlyTargetContext -ClaimsHash $engineClaimsHash -CapabilityHashes $engineCapabilityHashes
    $previousStateBytes = ConvertTo-SemanticJsonBytes -InputObject $previousState
    $stateOnlyStatePath = Join-Path $stateOnlyAuthorityDir 'current-env.json'
    [System.IO.File]::WriteAllBytes($stateOnlyStatePath, $previousStateBytes)
    $previousStateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($previousStateBytes)).ToLowerInvariant()
    $stateOnlyTransactionId = [Guid]::NewGuid().ToString()
    $stateOnlyHeader = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-journal-header'
        TransactionId = $stateOnlyTransactionId
        OperationKind = 'controller-transition'
        TransactionMode = 'state-only'
        OriginalDocumentHash = ('1' * 64)
        OriginalPlanHash = ('2' * 64)
        HomeAuthorityKey = $engineAuthorityKey
        OriginRepoId = ('3' * 64)
        GitCommonDirHash = ('4' * 64)
        CanonicalLockKey = ('5' * 64)
        RootClaimsHash = $engineClaimsHash
        ReceiptRef = 'NO_LIVE_MUTATION'
        Targets = @()
    }
    $stateOnlyDir = Join-Path $stateOnlyWork 'live-transactions' $stateOnlyTransactionId
    New-SealedLiveJournalHeader -Document $stateOnlyHeader -TransactionDirectory $stateOnlyDir | Out-Null
    $stateOnlyRecovery = Join-Path $stateOnlyWork 'state-recovery'
    $stateOnlyIntent = New-EngineControllerAuthorityStateIntent -ClaimsHash $engineClaimsHash -PlanHash ('a' * 64) -DocumentHash ('b' * 64)
    $stateOnlyResult = Invoke-SealedLiveTransactionStateOnly -TransactionDirectory $stateOnlyDir -Header $stateOnlyHeader -AuthorityStateIntent $stateOnlyIntent -TargetContextIntent $stateOnlyTargetContext -FinalCapabilityHashesByPlatform $engineCapabilityHashes -ControlBase $stateOnlyControlBase -StateRecoveryDirectory $stateOnlyRecovery
    $stateOnlyChain = Get-SealedLiveJournalChain -TransactionDirectory $stateOnlyDir
    $stateOnlyPhases = @($stateOnlyChain.Records | ForEach-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] })
    Assert ($stateOnlyPhases[0] -ceq 'STATE_PREIMAGE_COMPLETE') 'state-only publishes STATE_PREIMAGE_COMPLETE first'
    Assert (@($stateOnlyPhases | Where-Object { $_ -ceq 'FILE_REPLACED' }).Count -eq 1) 'state-only publishes FILE_REPLACED'
    Assert (@($stateOnlyPhases | Where-Object { $_ -ceq 'STATE_PUBLISHED' }).Count -eq 1) 'state-only publishes STATE_PUBLISHED'
    Assert (@($stateOnlyPhases | Where-Object { $_ -ceq 'COMPLETE' }).Count -eq 1) 'state-only publishes COMPLETE'
    Assert ($null -ne $stateOnlyChain.Result -and [string] $stateOnlyChain.Result.Outcome -ceq 'committed') 'state-only publishes the committed result'
    Assert (-not (Test-LiveTransactionMapHasName -Map $stateOnlyChain.Result -Name 'ReceiptRef')) 'state-only committed result omits ReceiptRef'
    Assert (-not (Test-LiveTransactionMapHasName -Map $stateOnlyChain.Result -Name 'ReceiptHash')) 'state-only committed result omits ReceiptHash'
    $null = Test-SealedLiveJournalChain -Header $stateOnlyChain.Header -Records $stateOnlyChain.Records -Result $stateOnlyChain.Result -ResultFileHash $stateOnlyChain.ResultFileHash
    Assert $true 'the state-only journal chain validates end to end'
    $installedStateOnlyHash = Get-FileByteHash -Path $stateOnlyStatePath
    Assert ($installedStateOnlyHash -ceq [string] $stateOnlyResult.StateHash) 'state-only installed bytes match the returned StateHash'
    Assert ($installedStateOnlyHash -cne $previousStateHash) 'state-only replaces the previous state bytes'
    $installedStateOnly = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($stateOnlyStatePath, [System.Text.UTF8Encoding]::new($false, $true)))
    Assert ([string] $installedStateOnly.LastOperationKind -ceq 'controller-transition') 'state-only postimage LastOperationKind is controller-transition'
    Assert ([string] $installedStateOnly.ReceiptRef -ceq 'NO_LIVE_MUTATION') 'state-only postimage ReceiptRef is NO_LIVE_MUTATION'
    Assert ([long] $installedStateOnly.AuthorityGeneration -eq 2) 'state-only postimage updates AuthorityGeneration'
    Assert ([string] $installedStateOnly.ControllerRepoFingerprint -ceq ('e' * 64)) 'state-only postimage updates ControllerRepoFingerprint'
    Assert ([string] $installedStateOnly.EnvironmentName -ceq 'work') 'state-only postimage preserves EnvironmentName'
    Assert (Test-Path -LiteralPath (Join-Path $stateOnlyRecovery 'current-env.preimage.json')) 'state-only retains the immutable preimage'
    Assert ((Get-FileByteHash -Path (Join-Path $stateOnlyRecovery 'current-env.preimage.json')) -ceq $previousStateHash) 'state-only preimage bytes match the previous state'
    Assert ((Get-FileByteHash -Path (Join-Path $stateOnlyAuthorityDir 'root-claims.json')) -ceq $engineClaimsHash) 'state-only leaves immutable claims unchanged'

    Write-Host '[live mutation engine: state-only entry rejection]'
    $rejectDir = Join-Path $stateOnlyWork 'live-transactions' ([Guid]::NewGuid().ToString())
    $rejectHeader = [ordered]@{}
    foreach ($k in @($stateOnlyHeader.Keys)) { $rejectHeader[$k] = $stateOnlyHeader[$k] }
    $rejectHeader['TransactionId'] = [Guid]::NewGuid().ToString()
    New-SealedLiveJournalHeader -Document $rejectHeader -TransactionDirectory $rejectDir | Out-Null
    $null = Add-SealedLiveJournalRecord -TransactionDirectory $rejectDir -Phase 'STATE_PREIMAGE_COMPLETE' -Data ([ordered]@{
        PreStatePhaseHash = ('1' * 64)
        StateHash = ('2' * 64)
    })
    Assert-ThrowsToken {
        Invoke-SealedLiveTransactionStateOnly -TransactionDirectory $rejectDir -Header $rejectHeader -AuthorityStateIntent $stateOnlyIntent -TargetContextIntent $stateOnlyTargetContext -FinalCapabilityHashesByPlatform $engineCapabilityHashes -ControlBase $stateOnlyControlBase -StateRecoveryDirectory (Join-Path $stateOnlyWork 'reject-recovery')
    } 'manual-recovery-required' 'state-only rejects a chain that already has records'
    Assert-ThrowsToken {
        Invoke-SealedLiveTransactionStateOnly -TransactionDirectory $stateOnlyDir -Header $stateOnlyHeader -AuthorityStateIntent $stateOnlyIntent -TargetContextIntent $stateOnlyTargetContext -FinalCapabilityHashesByPlatform $engineCapabilityHashes -ControlBase $stateOnlyControlBase -StateRecoveryDirectory (Join-Path $stateOnlyWork 'reject-complete-recovery')
    } 'manual-recovery-required' 'state-only rejects a completed transaction on re-entry'
    $missingStateDir = Join-Path $stateOnlyWork 'live-transactions' ([Guid]::NewGuid().ToString())
    $missingStateHeader = [ordered]@{}
    foreach ($k in @($stateOnlyHeader.Keys)) { $missingStateHeader[$k] = $stateOnlyHeader[$k] }
    $missingStateHeader['TransactionId'] = [Guid]::NewGuid().ToString()
    New-SealedLiveJournalHeader -Document $missingStateHeader -TransactionDirectory $missingStateDir | Out-Null
    $missingControl = Join-Path $stateOnlyWork 'missing-state-control'
    $missingAuthority = Join-Path (Join-Path $missingControl 'homes') $engineAuthorityKey
    New-Item -ItemType Directory -Force -Path $missingAuthority | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $missingAuthority 'root-claims.json'), $engineClaimsBytes)
    Assert-ThrowsToken {
        Invoke-SealedLiveTransactionStateOnly -TransactionDirectory $missingStateDir -Header $missingStateHeader -AuthorityStateIntent $stateOnlyIntent -TargetContextIntent $stateOnlyTargetContext -FinalCapabilityHashesByPlatform $engineCapabilityHashes -ControlBase $missingControl -StateRecoveryDirectory (Join-Path $stateOnlyWork 'missing-state-recovery')
    } 'live-transaction-intent-mismatch' 'state-only rejects a missing current-env state file'
    $driftClaimsDir = Join-Path $stateOnlyWork 'live-transactions' ([Guid]::NewGuid().ToString())
    $driftClaimsHeader = [ordered]@{}
    foreach ($k in @($stateOnlyHeader.Keys)) { $driftClaimsHeader[$k] = $stateOnlyHeader[$k] }
    $driftClaimsHeader['TransactionId'] = [Guid]::NewGuid().ToString()
    New-SealedLiveJournalHeader -Document $driftClaimsHeader -TransactionDirectory $driftClaimsDir | Out-Null
    $driftControl = Join-Path $stateOnlyWork 'drift-claims-control'
    $driftAuthority = Join-Path (Join-Path $driftControl 'homes') $engineAuthorityKey
    New-Item -ItemType Directory -Force -Path $driftAuthority | Out-Null
    $driftClaimsLiteral = '{"artifact":"root-claims","fixture":"drifted"}'
    [System.IO.File]::WriteAllBytes((Join-Path $driftAuthority 'root-claims.json'), [System.Text.UTF8Encoding]::new($false).GetBytes($driftClaimsLiteral))
    [System.IO.File]::WriteAllBytes((Join-Path $driftAuthority 'current-env.json'), $previousStateBytes)
    Assert-ThrowsToken {
        Invoke-SealedLiveTransactionStateOnly -TransactionDirectory $driftClaimsDir -Header $driftClaimsHeader -AuthorityStateIntent $stateOnlyIntent -TargetContextIntent $stateOnlyTargetContext -FinalCapabilityHashesByPlatform $engineCapabilityHashes -ControlBase $driftControl -StateRecoveryDirectory (Join-Path $stateOnlyWork 'drift-claims-recovery')
    } 'live-transaction-hash-mismatch' 'state-only rejects drifted immutable claims bytes'
    $modeRejectDir = Join-Path $stateOnlyWork 'live-transactions' ([Guid]::NewGuid().ToString())
    $modeRejectHeader = [ordered]@{}
    foreach ($k in @($stateOnlyHeader.Keys)) { $modeRejectHeader[$k] = $stateOnlyHeader[$k] }
    $modeRejectHeader['TransactionId'] = [Guid]::NewGuid().ToString()
    New-SealedLiveJournalHeader -Document $modeRejectHeader -TransactionDirectory $modeRejectDir | Out-Null
    Assert-ThrowsToken {
        Invoke-SealedLiveTransactionMutation -TransactionDirectory $modeRejectDir -Header $modeRejectHeader -Receipt ([ordered]@{ ReceiptId = [Guid]::NewGuid().ToString(); ReceiptPath = (Join-Path $stateOnlyWork 'unused'); ReceiptHash = ('9' * 64) }) -Targets @() -SourceRootsByPlatform ([ordered]@{ Claude = $stateOnlyLiveClaude; Codex = $stateOnlyLiveCodex; Reasonix = $stateOnlyLiveReasonix }) -AuthorityStateIntent $stateOnlyIntent -TargetContextIntent $stateOnlyTargetContext -FinalCapabilityHashesByPlatform $engineCapabilityHashes -ControlBase $stateOnlyControlBase -StateRecoveryDirectory (Join-Path $stateOnlyWork 'mode-reject-recovery')
    } 'live-transaction-intent-mismatch' 'receipt-backed engine rejects a state-only header'

    Write-Host '[live mutation engine: kill matrix]'
    $sandboxedLiveHost = Join-Path $work 'live-transaction-host.ps1'
    Copy-Item -LiteralPath $liveTransactionHost -Destination $sandboxedLiveHost -Force

    function New-KillReceiptBackedFixture {
        param([Parameter(Mandatory)] [string] $Label)
        $root = Join-Path $work "kill-receipt-$Label"
        $liveClaude = Join-Path $root 'live/claude/skills'
        $liveCodex = Join-Path $root 'live/codex/skills'
        $liveReasonix = Join-Path $root 'live/reasonix/skills'
        $stagingClaude = Join-Path $root 'staging/claude'
        $stagingCodex = Join-Path $root 'staging/codex'
        $stagingReasonix = Join-Path $root 'staging/reasonix'
        $backupRoot = Join-Path $root 'backups'
        $sourceClaude = Join-Path $root 'source/claude/skills'
        foreach ($dir in @(
            (Join-Path $liveClaude 'kept-claude'),
            (Join-Path $liveCodex 'retired-codex'),
            $liveReasonix, $stagingClaude, $stagingCodex, $stagingReasonix, $backupRoot,
            (Join-Path $sourceClaude 'kept-claude')
        )) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Write-TextFile -Path (Join-Path $liveClaude 'kept-claude/SKILL.md') -Content 'kill-kept-old'
        Write-TextFile -Path (Join-Path $liveCodex 'retired-codex/SKILL.md') -Content 'kill-retired-old'
        Write-TextFile -Path (Join-Path $sourceClaude 'kept-claude/SKILL.md') -Content 'kill-kept-new'
        $controlBase = Join-Path $root 'control'
        $authorityDir = Join-Path (Join-Path $controlBase 'homes') $engineAuthorityKey
        New-Item -ItemType Directory -Force -Path $authorityDir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $authorityDir 'root-claims.json'), $engineClaimsBytes)
        $dummyState = '{"artifact":"current-env-state","fixture":"kill-receipt"}'
        [System.IO.File]::WriteAllText((Join-Path $authorityDir 'current-env.json'), $dummyState, [System.Text.UTF8Encoding]::new($false))
        $keptOldHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveClaude 'kept-claude')).TreeHash
        $keptNewHash = (Get-SafeTreeSnapshot -Root (Join-Path $sourceClaude 'kept-claude')).TreeHash
        $retiredOldHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveCodex 'retired-codex')).TreeHash
        $transactionId = [Guid]::NewGuid().ToString()
        $receiptId = [Guid]::NewGuid().ToString()
        $header = [ordered]@{
            SchemaVersion = 1
            ArtifactKind = 'live-journal-header'
            TransactionId = $transactionId
            OperationKind = 'retirement'
            TransactionMode = 'receipt-backed'
            OriginalDocumentHash = ('1' * 64)
            OriginalPlanHash = ('2' * 64)
            HomeAuthorityKey = $engineAuthorityKey
            OriginRepoId = ('3' * 64)
            GitCommonDirHash = ('4' * 64)
            CanonicalLockKey = ('5' * 64)
            RootClaimsHash = $engineClaimsHash
            ReceiptIntent = [ordered]@{
                Id = $receiptId
                Path = (Join-Path $backupRoot $receiptId)
            }
            Targets = @()
        }
        $receiptIntent = [ordered]@{
            TransactionId = $transactionId
            ReceiptId = $receiptId
            ReceiptPath = (Join-Path $backupRoot $receiptId)
        }
        $transactionDir = Join-Path $root 'live-transactions' $transactionId
        New-SealedLiveJournalHeader -Document $header -TransactionDirectory $transactionDir | Out-Null
        $receiptPlatforms = @(
            [ordered]@{
                Platform = 'Claude'
                LiveRoot = $liveClaude
                Targets = @(
                    [ordered]@{ Name = 'kept-claude'; LivePath = (Join-Path $liveClaude 'kept-claude'); PlannedTreeHash = $keptOldHash }
                )
            },
            [ordered]@{
                Platform = 'Codex'
                LiveRoot = $liveCodex
                Targets = @(
                    [ordered]@{ Name = 'retired-codex'; LivePath = (Join-Path $liveCodex 'retired-codex'); PlannedTreeHash = $retiredOldHash }
                )
            },
            [ordered]@{ Platform = 'Reasonix'; LiveRoot = $liveReasonix; Targets = @() }
        )
        $receipt = Invoke-SealedManagedBackupReceipt -ReservationIntent $receiptIntent -SourceOperationKind 'retirement' -PlanHash ('1' * 64) -DocumentHash ('2' * 64) -ExecutionContextHash ('3' * 64) -ControlBaseHash ('4' * 64) -FilesystemCapabilityHash ('5' * 64) -HomeAuthorityKey $engineAuthorityKey -BackupRoot $backupRoot -Platforms $receiptPlatforms -ForbiddenRoots @()
        $actions = @(
            [ordered]@{ Platform = 'Claude'; Action = 'update'; Name = 'kept-claude'; SourceHash = $keptNewHash; LiveHash = $keptOldHash },
            [ordered]@{ Platform = 'Codex'; Action = 'prune'; Name = 'retired-codex'; SourceHash = $null; LiveHash = $retiredOldHash }
        )
        $contexts = @(
            [ordered]@{ Platform = 'Claude'; LiveRoot = $liveClaude; DeepestExistingParentPath = $liveClaude; MissingRemainder = @(); StagingRoot = $stagingClaude },
            [ordered]@{ Platform = 'Codex'; LiveRoot = $liveCodex; DeepestExistingParentPath = $liveCodex; MissingRemainder = @(); StagingRoot = $stagingCodex },
            [ordered]@{ Platform = 'Reasonix'; LiveRoot = $liveReasonix; DeepestExistingParentPath = $liveReasonix; MissingRemainder = @(); StagingRoot = $stagingReasonix }
        )
        $planned = New-SealedLiveTransactionTargetPlan -BackupRoot $backupRoot -ReceiptIntent $header['ReceiptIntent'] -Platforms $receiptPlatforms -Actions $actions -LiveRootContexts $contexts
        $parentPath = Join-Path $root 'created-parent'
        $parentTarget = [ordered]@{
            TargetId = (Get-SemanticJsonHash -InputObject ([ordered]@{ Kind = 'parent-directory'; Path = $parentPath }))
            Order = 0L
            TargetKind = 'parent-directory'
            Role = 'parent'
            Platform = 'Claude'
            Name = 'created-parent'
            TargetPath = $parentPath
            PreimagePath = $null
            SwapOldPath = (Join-Path $root 'staging/parent-swap')
            StagedPath = $null
            LiveIdentity = $null
            ReceiptSnapshotRef = $null
            Current = [ordered]@{ State = 'MISSING' }
            Candidate = [ordered]@{ State = 'MISSING' }
            TargetContextHash = (Get-SemanticJsonHash -InputObject ([ordered]@{ Path = $parentPath; Segment = 'created-parent' }))
        }
        $targets = @($parentTarget) + @($planned)
        $targetContext = Sync-EngineIntentIdentities -TargetContextIntent (New-EngineTargetContextIntent -Platforms $receiptPlatforms)
        $sourceRoots = [ordered]@{
            Claude = $sourceClaude
            Codex = (Join-Path $root 'source/codex/skills')
            Reasonix = $liveReasonix
        }
        New-Item -ItemType Directory -Force -Path $sourceRoots['Codex'] | Out-Null
        $producerArgs = [ordered]@{
            TransactionDirectory = $transactionDir
            Header = $header
            Receipt = [ordered]@{
                ReceiptId = [string] $receipt.ReceiptId
                ReceiptPath = [string] $receipt.ReceiptPath
                ReceiptHash = [string] $receipt.ReceiptHash
            }
            Targets = $targets
            SourceRootsByPlatform = $sourceRoots
            AuthorityStateIntent = (New-EngineAuthorityStateIntent -ClaimsHash $engineClaimsHash -PlanHash ('1' * 64) -DocumentHash ('2' * 64))
            TargetContextIntent = $targetContext
            FinalCapabilityHashesByPlatform = $engineCapabilityHashes
            ControlBase = $controlBase
            StateRecoveryDirectory = (Join-Path $stagingClaude 'state-recovery')
        }
        return [ordered]@{
            ProducerArgs = $producerArgs
            ParentPath = $parentPath
            KeptLivePath = (Join-Path $liveClaude 'kept-claude')
            KeptSwapPath = (Join-Path $stagingClaude 'swap/kept-claude')
            KeptStagedPath = (Join-Path $stagingClaude 'staged/kept-claude')
            KeptOldHash = $keptOldHash
            KeptNewHash = $keptNewHash
            StatePath = (Join-Path $authorityDir 'current-env.json')
            PreviousStateHash = (Get-FileByteHash -Path (Join-Path $authorityDir 'current-env.json'))
            Targets = $targets
        }
    }

    function New-KillStateOnlyFixture {
        param([Parameter(Mandatory)] [string] $Label)
        $root = Join-Path $work "kill-state-$Label"
        $liveClaude = Join-Path $root 'live/claude/skills'
        $liveCodex = Join-Path $root 'live/codex/skills'
        $liveReasonix = Join-Path $root 'live/reasonix/skills'
        foreach ($dir in @($liveClaude, $liveCodex, $liveReasonix)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Write-TextFile -Path (Join-Path $liveClaude 'kept-claude/SKILL.md') -Content 'kill-state-claude'
        Write-TextFile -Path (Join-Path $liveCodex 'kept-codex/SKILL.md') -Content 'kill-state-codex'
        Write-TextFile -Path (Join-Path $liveReasonix 'kept-reasonix/SKILL.md') -Content 'kill-state-reasonix'
        $controlBase = Join-Path $root 'control'
        $authorityDir = Join-Path (Join-Path $controlBase 'homes') $engineAuthorityKey
        New-Item -ItemType Directory -Force -Path $authorityDir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $authorityDir 'root-claims.json'), $engineClaimsBytes)
        $platforms = @(
            [ordered]@{ Platform = 'Claude'; LiveRoot = $liveClaude },
            [ordered]@{ Platform = 'Codex'; LiveRoot = $liveCodex },
            [ordered]@{ Platform = 'Reasonix'; LiveRoot = $liveReasonix }
        )
        $targetContext = Sync-EngineIntentIdentities -TargetContextIntent (New-EngineTargetContextIntent -Platforms $platforms)
        $previous = New-EnginePreviousStateDocument -TargetContextIntent $targetContext -ClaimsHash $engineClaimsHash -CapabilityHashes $engineCapabilityHashes
        $previousBytes = ConvertTo-SemanticJsonBytes -InputObject $previous
        $statePath = Join-Path $authorityDir 'current-env.json'
        [System.IO.File]::WriteAllBytes($statePath, $previousBytes)
        $transactionId = [Guid]::NewGuid().ToString()
        $header = [ordered]@{
            SchemaVersion = 1
            ArtifactKind = 'live-journal-header'
            TransactionId = $transactionId
            OperationKind = 'controller-transition'
            TransactionMode = 'state-only'
            OriginalDocumentHash = ('1' * 64)
            OriginalPlanHash = ('2' * 64)
            HomeAuthorityKey = $engineAuthorityKey
            OriginRepoId = ('3' * 64)
            GitCommonDirHash = ('4' * 64)
            CanonicalLockKey = ('5' * 64)
            RootClaimsHash = $engineClaimsHash
            ReceiptRef = 'NO_LIVE_MUTATION'
            Targets = @()
        }
        $transactionDir = Join-Path $root 'live-transactions' $transactionId
        New-SealedLiveJournalHeader -Document $header -TransactionDirectory $transactionDir | Out-Null
        $recovery = Join-Path $root 'state-recovery'
        $producerArgs = [ordered]@{
            TransactionDirectory = $transactionDir
            Header = $header
            AuthorityStateIntent = (New-EngineControllerAuthorityStateIntent -ClaimsHash $engineClaimsHash -PlanHash ('a' * 64) -DocumentHash ('b' * 64))
            TargetContextIntent = $targetContext
            FinalCapabilityHashesByPlatform = $engineCapabilityHashes
            ControlBase = $controlBase
            StateRecoveryDirectory = $recovery
        }
        return [ordered]@{
            ProducerArgs = $producerArgs
            StatePath = $statePath
            PreviousStateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($previousBytes)).ToLowerInvariant()
            RecoveryCopy = (Join-Path $recovery 'current-env.preimage.json')
        }
    }

    function Invoke-KilledLiveTransactionHost {
        param(
            [Parameter(Mandatory)] [ValidateSet('produce', 'state-only')] [string] $Mode,
            [Parameter(Mandatory)] [System.Collections.IDictionary] $ProducerArgs,
            [Parameter(Mandatory)] [string] $Checkpoint
        )
        $controller = New-FailpointController
        $suffix = [Guid]::NewGuid().ToString('N')
        $outFile = Join-Path $work "kill-out-$Checkpoint-$suffix.txt"
        $errFile = Join-Path $work "kill-err-$Checkpoint-$suffix.txt"
        $child = $null
        try {
            $failpointsJson = ConvertTo-Json -InputObject @([ordered]@{ Checkpoint = $Checkpoint; PipeName = $controller.Name }) -Compress
            $producerJson = ConvertTo-Json -InputObject $ProducerArgs -Depth 30 -Compress
            $hostArguments = @('-Mode', $Mode, '-ProducerArgsJson', $producerJson, '-FailpointsJson', $failpointsJson, '-RepoRoot', $RepoRoot)
            $hostArgumentsEncoded = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $hostArguments -Compress)))
            $child = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $internalHost, '-SandboxRoot', $work, '-ScriptPath', $sandboxedLiveHost, '-ArgumentsBase64', $hostArgumentsEncoded) -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            Wait-FailpointController -Controller $controller -ExpectedCheckpoint $Checkpoint -TimeoutSeconds 90
            Stop-FailpointProcessTree -Process $child
            Wait-Process -Id $child.Id -Timeout 30 -ErrorAction SilentlyContinue
        }
        catch {
            $errText = ''
            if (Test-Path -LiteralPath $errFile) { $errText = [System.IO.File]::ReadAllText($errFile) }
            if ($null -ne $child -and -not $child.HasExited) {
                Stop-FailpointProcessTree -Process $child
                Wait-Process -Id $child.Id -Timeout 30 -ErrorAction SilentlyContinue
            }
            throw "FAIL: kill window '$Checkpoint': $($_.Exception.Message)`n$errText"
        }
        finally {
            Close-FailpointController -Controller $controller
        }
    }

    foreach ($window in @(
        @{ Checkpoint = 'RECEIPT_COMPLETE' },
        @{ Checkpoint = 'PREPARED' },
        @{ Checkpoint = 'OLD_MOVED' },
        @{ Checkpoint = 'NEW_INSTALLED' },
        @{ Checkpoint = 'STATE_PUBLISHED' }
    )) {
        $fixture = New-KillReceiptBackedFixture -Label $window.Checkpoint
        Invoke-KilledLiveTransactionHost -Mode produce -ProducerArgs $fixture.ProducerArgs -Checkpoint $window.Checkpoint
        $killedDir = [string] $fixture.ProducerArgs['TransactionDirectory']
        $killedChain = Get-SealedLiveJournalChain -TransactionDirectory $killedDir
        Assert (@($killedChain.UnknownNames).Count -eq 0) "kill at $($window.Checkpoint) leaves no unknown journal entries"
        Assert ($null -eq $killedChain.Result) "kill at $($window.Checkpoint) publishes no result"
        Assert ((Get-LiveJournalLastPhase -TransactionDirectory $killedDir) -ceq $window.Checkpoint) "kill at $($window.Checkpoint) stops on that phase"
        if ($window.Checkpoint -ceq 'PREPARED') {
            Assert (Test-Path -LiteralPath $fixture.KeptStagedPath -PathType Container) 'PREPARED kill leaves the staged update tree'
            Assert ((Get-SafeTreeSnapshot -Root $fixture.KeptLivePath).TreeHash -ceq [string] $fixture.KeptOldHash) 'PREPARED kill leaves live at the old hash'
            Assert (Test-Path -LiteralPath $fixture.ParentPath -PathType Container) 'PREPARED kill has created the parent directory'
        }
        if ($window.Checkpoint -ceq 'OLD_MOVED') {
            Assert (-not (Test-Path -LiteralPath $fixture.KeptLivePath)) 'OLD_MOVED kill removes the live update target'
            Assert (Test-Path -LiteralPath $fixture.KeptSwapPath -PathType Container) 'OLD_MOVED kill stores the old tree in swap-old'
            Assert ((Get-SafeTreeSnapshot -Root $fixture.KeptSwapPath).TreeHash -ceq [string] $fixture.KeptOldHash) 'OLD_MOVED kill swap-old matches the old hash'
        }
        if ($window.Checkpoint -ceq 'NEW_INSTALLED') {
            Assert ((Get-SafeTreeSnapshot -Root $fixture.KeptLivePath).TreeHash -ceq [string] $fixture.KeptNewHash) 'NEW_INSTALLED kill installs the new tree'
            Assert (-not (Test-Path -LiteralPath $fixture.KeptStagedPath)) 'NEW_INSTALLED kill leaves no staged copy'
        }
        if ($window.Checkpoint -ceq 'STATE_PUBLISHED') {
            $publishedHash = Get-FileByteHash -Path $fixture.StatePath
            $stateRecord = @($killedChain.Records | Where-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'STATE_PUBLISHED' })[-1]
            Assert ($publishedHash -ceq [string] ([System.Collections.IDictionary] ([System.Collections.IDictionary] $stateRecord['Document'])['Data'])['StateHash']) 'STATE_PUBLISHED kill binds the new state bytes'
            Assert ($publishedHash -cne [string] $fixture.PreviousStateHash) 'STATE_PUBLISHED kill has replaced the dummy previous state'
        }
        $rerunArgs = $fixture.ProducerArgs
        Assert-ThrowsToken {
            Invoke-SealedLiveTransactionMutation -TransactionDirectory ([string] $rerunArgs['TransactionDirectory']) -Header ([System.Collections.IDictionary] $rerunArgs['Header']) -Receipt ([System.Collections.IDictionary] $rerunArgs['Receipt']) -Targets @([object[]] $rerunArgs['Targets']) -SourceRootsByPlatform ([System.Collections.IDictionary] $rerunArgs['SourceRootsByPlatform']) -AuthorityStateIntent ([System.Collections.IDictionary] $rerunArgs['AuthorityStateIntent']) -TargetContextIntent ([System.Collections.IDictionary] $rerunArgs['TargetContextIntent']) -FinalCapabilityHashesByPlatform ([System.Collections.IDictionary] $rerunArgs['FinalCapabilityHashesByPlatform']) -ControlBase ([string] $rerunArgs['ControlBase']) -StateRecoveryDirectory ([string] $rerunArgs['StateRecoveryDirectory'])
        } 'manual-recovery-required' "re-running the receipt-backed engine after $($window.Checkpoint) kill fails closed"
        if ($window.Checkpoint -ceq 'PREPARED') {
            Write-TextFile -Path (Join-Path $fixture.ParentPath 'raced.txt') -Content 'external-race'
            $completed = Get-LiveJournalCompletedFromChain -Chain $killedChain
            Assert-ThrowsToken {
                Restore-SealedLiveMutationTargets -Targets @([object[]] $fixture.Targets) -Completed $completed
            } 'live-transaction-hash-mismatch' 'an external file in a created parent fails closed for manual recovery'
        }
    }

    foreach ($window in @(
        @{ Checkpoint = 'STATE_PREIMAGE_COMPLETE' },
        @{ Checkpoint = 'FILE_REPLACED' }
    )) {
        $fixture = New-KillStateOnlyFixture -Label $window.Checkpoint
        Invoke-KilledLiveTransactionHost -Mode state-only -ProducerArgs $fixture.ProducerArgs -Checkpoint $window.Checkpoint
        $killedDir = [string] $fixture.ProducerArgs['TransactionDirectory']
        $killedChain = Get-SealedLiveJournalChain -TransactionDirectory $killedDir
        Assert (@($killedChain.UnknownNames).Count -eq 0) "state-only kill at $($window.Checkpoint) leaves no unknown journal entries"
        Assert ($null -eq $killedChain.Result) "state-only kill at $($window.Checkpoint) publishes no result"
        Assert ((Get-LiveJournalLastPhase -TransactionDirectory $killedDir) -ceq $window.Checkpoint) "state-only kill at $($window.Checkpoint) stops on that phase"
        if ($window.Checkpoint -ceq 'STATE_PREIMAGE_COMPLETE') {
            Assert ((Get-FileByteHash -Path $fixture.StatePath) -ceq [string] $fixture.PreviousStateHash) 'STATE_PREIMAGE_COMPLETE kill leaves the previous state bytes'
            Assert (Test-Path -LiteralPath $fixture.RecoveryCopy -PathType Leaf) 'STATE_PREIMAGE_COMPLETE kill retains the preimage'
            Assert ((Get-FileByteHash -Path $fixture.RecoveryCopy) -ceq [string] $fixture.PreviousStateHash) 'STATE_PREIMAGE_COMPLETE preimage matches the previous state'
        }
        if ($window.Checkpoint -ceq 'FILE_REPLACED') {
            $replacedHash = Get-FileByteHash -Path $fixture.StatePath
            $replacedRecord = @($killedChain.Records | Where-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'FILE_REPLACED' })[-1]
            $replacedState = [System.Collections.IDictionary] ([System.Collections.IDictionary] ([System.Collections.IDictionary] $replacedRecord['Document'])['Data'])['TargetState']
            Assert ($replacedHash -ceq [string] $replacedState['Hash']) 'FILE_REPLACED kill installs the new state bytes'
            Assert ($replacedHash -cne [string] $fixture.PreviousStateHash) 'FILE_REPLACED kill no longer has the previous state bytes'
        }
        $rerunArgs = $fixture.ProducerArgs
        Assert-ThrowsToken {
            Invoke-SealedLiveTransactionStateOnly -TransactionDirectory ([string] $rerunArgs['TransactionDirectory']) -Header ([System.Collections.IDictionary] $rerunArgs['Header']) -AuthorityStateIntent ([System.Collections.IDictionary] $rerunArgs['AuthorityStateIntent']) -TargetContextIntent ([System.Collections.IDictionary] $rerunArgs['TargetContextIntent']) -FinalCapabilityHashesByPlatform ([System.Collections.IDictionary] $rerunArgs['FinalCapabilityHashesByPlatform']) -ControlBase ([string] $rerunArgs['ControlBase']) -StateRecoveryDirectory ([string] $rerunArgs['StateRecoveryDirectory'])
        } 'manual-recovery-required' "re-running the state-only engine after $($window.Checkpoint) kill fails closed"
    }

    Write-Host '[live transaction host]'
    . (Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1')
    . (Join-Path $RepoRoot 'tests/helpers/home-authority-test-host.ps1')

    function Write-HostCreateNewFile {
        param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [byte[]] $Bytes)
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($Path), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
    }

    function Write-HostSemanticDocument {
        param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
        $bytes = [byte[]] (ConvertTo-SemanticJsonBytes -InputObject $Document)
        Write-HostCreateNewFile -Path $Path -Bytes $bytes
        return $bytes
    }

    function Set-HostDirectoryCurrentUserOnly {
        param([Parameter(Mandatory)] [string] $Path)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true, $false)
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
        [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($Path)), $security)
    }

    function Get-HostLiveRootPath {
        param($Context, [Parameter(Mandatory)] [string] $Platform)
        foreach ($liveTarget in @($Context.LiveTargets)) {
            if ([string] $liveTarget.Platform -ceq $Platform) {
                return [string] $liveTarget.TargetContext.RequestedPath
            }
        }
        throw "host fixture missing live root for $Platform"
    }

    function New-HostTargetContextIntent {
        param($Context)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($liveTarget in @($Context.LiveTargets)) {
            $path = [string] $liveTarget.TargetContext.RequestedPath
            $meta = Get-TargetMetadataContext -Path $path
            $exists = [string] $meta.TargetStatus -ceq 'EXISTS'
            $identity = $null
            if ($exists) { $identity = [string] $meta.Ancestors[-1].Identity }
            $rows.Add([ordered]@{
                Platform = [string] $liveTarget.Platform
                LocationKey = [string] $meta.LocationKey
                RequestedPath = [string] $meta.RequestedPath
                InitialState = $(if ($exists) { 'EXISTS' } else { 'ABSENT' })
                VolumeId = [string] $meta.VolumeId
                DeepestExistingParentPath = [string] $meta.DeepestExistingParentPath
                DeepestExistingParentIdentity = [string] $meta.DeepestExistingParentIdentity
                MissingRemainder = @($meta.MissingRemainder)
                InitialDirectoryIdentity = $identity
                ExpectedPostState = 'EXISTS'
            })
        }
        return [ordered]@{
            HomeAuthorityKey = [string] $Context.HomeAuthorityKey
            Rows = $rows.ToArray()
        }
    }

    function New-HostPlatformSlot {
        param(
            [Parameter(Mandatory)] [string] $Platform,
            [Parameter(Mandatory)] [string] $SourceRoot,
            [Parameter(Mandatory)] [string] $LiveRoot
        )
        $sourceMeta = Get-TargetMetadataContext -Path $SourceRoot
        $liveMeta = Get-TargetMetadataContext -Path $LiveRoot
        $sourceExists = [string] $sourceMeta.TargetStatus -ceq 'EXISTS'
        $liveExists = [string] $liveMeta.TargetStatus -ceq 'EXISTS'
        return [ordered]@{
            Platform = $Platform
            SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
            LiveRoot = [System.IO.Path]::GetFullPath($LiveRoot)
            SourceRootExists = $sourceExists
            LiveRootExists = $liveExists
            SourcePreIdentity = [ordered]@{
                TargetStatus = [string] $sourceMeta.TargetStatus
                LocationKey = [string] $sourceMeta.LocationKey
                VolumeId = [string] $sourceMeta.VolumeId
                DirectoryIdentity = $(if ($sourceExists) { [string] $sourceMeta.Ancestors[-1].Identity } else { $null })
            }
            LivePreIdentity = [ordered]@{
                TargetStatus = [string] $liveMeta.TargetStatus
                LocationKey = [string] $liveMeta.LocationKey
                VolumeId = [string] $liveMeta.VolumeId
                DirectoryIdentity = $(if ($liveExists) { [string] $liveMeta.Ancestors[-1].Identity } else { $null })
            }
            ManifestHash = 'missing'
            SourceTreeHash = $(if ($sourceExists) { [string] (Get-SafeTreeSnapshot -Root $SourceRoot).TreeHash } else { $null })
            LiveTreeHash = $(if ($liveExists) { [string] (Get-SafeTreeSnapshot -Root $LiveRoot).TreeHash } else { $null })
            ManagedNames = @()
        }
    }

    function New-HostAuthorityIntent {
        param($Context, [Parameter(Mandatory)] [string] $ClaimsHash, [Parameter(Mandatory)] [string] $OperationKind)
        return [ordered]@{
            SchemaVersion = 3
            ArtifactKind = 'current-env-state'
            HomeAuthorityKey = [string] $Context.HomeAuthorityKey
            AuthorityGeneration = 1
            RootClaimsHash = $ClaimsHash
            SelectionKind = 'environment'
            EnvironmentName = 'work'
            EnvironmentLockHash = ('6' * 64)
            TaskOverlayHash = ('7' * 64)
            TaskOverlaySkills = @(
                [ordered]@{ Platform = 'Claude'; Skills = @() },
                [ordered]@{ Platform = 'Codex'; Skills = @() },
                [ordered]@{ Platform = 'Reasonix'; Skills = @() }
            )
            ManifestHashes = @(
                [ordered]@{ Platform = 'Claude'; Hash = ('b' * 64) },
                [ordered]@{ Platform = 'Codex'; Hash = ('c' * 64) },
                [ordered]@{ Platform = 'Reasonix'; Hash = ('d' * 64) }
            )
            FinalManagedHashes = @(
                [ordered]@{ Platform = 'Claude'; Hash = ('1' * 64) },
                [ordered]@{ Platform = 'Codex'; Hash = ('2' * 64) },
                [ordered]@{ Platform = 'Reasonix'; Hash = ('3' * 64) }
            )
            ControllerRepoFingerprint = ('5' * 64)
            ApprovedToolchainHash = ('4' * 64)
            LastOperationKind = $OperationKind
        }
    }

    function New-HostPlanDocument {
        param(
            [Parameter(Mandatory)] $Fixture,
            [Parameter(Mandatory)] [string] $OperationKind,
            [Parameter(Mandatory)] [string] $ClaimsHash,
            [AllowEmptyCollection()] [object[]] $Actions = @()
        )
        $context = $Fixture.Context
        $controlMeta = Get-TargetMetadataContext -Path ([string] $context.ControlBase)
        $payload = [ordered]@{
            OperationKind = $OperationKind
            Generator = 'scripts/sync.ps1'
            RepositoryCommit = ('1' * 40)
            RepoRoot = [string] $Fixture.Canonical.RepoRoot
            ApprovedToolchainHash = ('4' * 64)
            ControllerRepoFingerprint = ('5' * 64)
            ControlBaseIntent = [ordered]@{
                TargetStatus = 'EXISTS'
                RequestedPath = [string] $context.ControlBase
                LocationKey = [string] $controlMeta.LocationKey
                VolumeId = [string] $controlMeta.VolumeId
                DirectoryIdentity = [string] $controlMeta.Ancestors[-1].Identity
                FilesystemCapability = [ordered]@{ Status = 'UNPROBED' }
            }
            Platforms = @(
                (New-HostPlatformSlot -Platform 'Claude' -SourceRoot ([string] $Fixture.Source['Claude']) -LiveRoot (Get-HostLiveRootPath -Context $context -Platform 'Claude')),
                (New-HostPlatformSlot -Platform 'Codex' -SourceRoot ([string] $Fixture.Source['Codex']) -LiveRoot (Get-HostLiveRootPath -Context $context -Platform 'Codex')),
                (New-HostPlatformSlot -Platform 'Reasonix' -SourceRoot ([string] $Fixture.Source['Reasonix']) -LiveRoot (Get-HostLiveRootPath -Context $context -Platform 'Reasonix'))
            )
            OrderedActions = @($Actions)
            UnknownMarkers = @()
            SystemMarker = [ordered]@{ Platform = 'Codex'; Name = '.system'; Present = $false; Identity = $null; Hash = $null }
            TargetContextIntent = (New-HostTargetContextIntent -Context $context)
            AuthorityStateIntent = (New-HostAuthorityIntent -Context $context -ClaimsHash $ClaimsHash -OperationKind $OperationKind)
        }
        if ($OperationKind -ceq 'initial') {
            $payload['EnvironmentName'] = 'full'
            $payload['RootClaimsHash'] = $ClaimsHash
        }
        if ($OperationKind -ceq 'retirement') {
            $payload['RetirementManifest'] = [ordered]@{
                Path = (Join-Path ([string] $Fixture.Root) 'retire.json')
                Hash = ('e' * 64)
            }
        }
        $document = [ordered]@{
            SchemaVersion = 3
            ArtifactKind = 'sync-plan'
            Metadata = [ordered]@{ GeneratedAtUtc = '2026-09-09T00:00:00Z' }
            PlanPayload = $payload
            PlanHash = ('0' * 64)
            DocumentHash = ('0' * 64)
        }
        $document['PlanHash'] = Get-PlanHash -PlanPayload $payload
        $document['DocumentHash'] = Get-DocumentHash -Document $document
        return $document
    }

    function New-HostRootClaims {
        param($Context)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($liveTarget in @($Context.LiveTargets)) {
            $path = [string] $liveTarget.TargetContext.RequestedPath
            $meta = Get-TargetMetadataContext -Path $path
            $exists = [string] $meta.TargetStatus -ceq 'EXISTS'
            $identity = $null
            if ($exists) { $identity = [string] $meta.Ancestors[-1].Identity }
            $rows.Add([ordered]@{
                Platform = [string] $liveTarget.Platform
                LocationKey = [string] $meta.LocationKey
                RequestedPath = [string] $meta.RequestedPath
                InitialState = $(if ($exists) { 'EXISTS' } else { 'ABSENT' })
                VolumeId = [string] $meta.VolumeId
                DeepestExistingParentPath = [string] $meta.DeepestExistingParentPath
                DeepestExistingParentIdentity = [string] $meta.DeepestExistingParentIdentity
                MissingRemainder = @($meta.MissingRemainder)
                InitialDirectoryIdentity = $identity
                ExpectedPostState = 'EXISTS'
            })
        }
        return [ordered]@{
            SchemaVersion = 1
            ArtifactKind = 'root-claims'
            HomeAuthorityKey = [string] $Context.HomeAuthorityKey
            TokenSid = [string] $Context.TokenSid
            ResolverVersion = 'windows-token-sid-known-folder-v1'
            HomeRootLocationKey = [string] $Context.HomeRootLocationKey
            LiveRootClaims = $rows.ToArray()
        }
    }

    function New-HostPreviousStateDocument {
        param(
            [Parameter(Mandatory)] $Context,
            [Parameter(Mandatory)] [string] $ClaimsHash,
            [Parameter(Mandatory)] [System.Collections.IDictionary] $Capability
        )
        $identities = [System.Collections.Generic.List[object]]::new()
        foreach ($liveTarget in @($Context.LiveTargets)) {
            $path = [string] $liveTarget.TargetContext.RequestedPath
            $meta = Get-TargetMetadataContext -Path $path
            if ([string] $meta.TargetStatus -cne 'EXISTS') {
                throw "host previous-state live root missing for $($liveTarget.Platform)"
            }
            $identities.Add([ordered]@{
                Platform = [string] $liveTarget.Platform
                LocationKey = [string] $meta.LocationKey
                ResolvedPath = [string] $meta.RequestedPath
                VolumeId = [string] $meta.VolumeId
                DirectoryIdentity = [string] $meta.Ancestors[-1].Identity
                FilesystemCapabilityHash = [string] $Capability[[string] $liveTarget.Platform]
            })
        }
        $identityRows = @($identities)
        $state = [ordered]@{
            SchemaVersion = 3
            ArtifactKind = 'current-env-state'
            HomeAuthorityKey = [string] $Context.HomeAuthorityKey
            AuthorityGeneration = 1
            RootClaimsHash = $ClaimsHash
            SelectionKind = 'environment'
            EnvironmentName = 'full'
            EnvironmentLockHash = ('6' * 64)
            TaskOverlayHash = ('7' * 64)
            TaskOverlaySkills = @(
                [ordered]@{ Platform = 'Claude'; Skills = @() },
                [ordered]@{ Platform = 'Codex'; Skills = @() },
                [ordered]@{ Platform = 'Reasonix'; Skills = @() }
            )
            ManifestHashes = @(
                [ordered]@{ Platform = 'Claude'; Hash = ('b' * 64) },
                [ordered]@{ Platform = 'Codex'; Hash = ('c' * 64) },
                [ordered]@{ Platform = 'Reasonix'; Hash = ('d' * 64) }
            )
            FinalManagedHashes = @(
                [ordered]@{ Platform = 'Claude'; Hash = ('1' * 64) },
                [ordered]@{ Platform = 'Codex'; Hash = ('2' * 64) },
                [ordered]@{ Platform = 'Reasonix'; Hash = ('3' * 64) }
            )
            ControllerRepoFingerprint = ('5' * 64)
            ApprovedToolchainHash = ('4' * 64)
            PlanHash = ('1' * 64)
            DocumentHash = ('2' * 64)
            LastOperationKind = 'initial'
            ReceiptId = [Guid]::NewGuid().ToString()
            ReceiptHash = ('e' * 64)
            JournalId = [Guid]::NewGuid().ToString()
            PreStatePhaseHash = ('0' * 64)
            FinalResolvedIdentities = $identityRows
            FinalTargetContextHash = (Get-SemanticJsonHash -InputObject @($identityRows))
        }
        Test-CurrentEnvStateSemantics -Document $state
        return $state
    }

    function Invoke-HostTransaction {
        param($Fixture, [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan)
        return Invoke-SealedLiveTransactionHost -Plan $Plan -RepoRoot ([string] $Fixture.Canonical.RepoRoot) -ControlBase ([string] $Fixture.Context.ControlBase) -BackupRoot ([string] $Fixture.Context.BackupRoot) -StagingRootsByPlatform $Fixture.Staging -SourceRootsByPlatform $Fixture.Source -FinalCapabilityHashesByPlatform $Fixture.Capability -AuthorityContext $Fixture.Context -WorkingTreeRoots $Fixture.WorkingTreeRoots -ToolchainRoot $RepoRoot
    }

    $hostRoot = Join-Path $work 'host'
    New-Item -ItemType Directory -Force -Path $hostRoot | Out-Null
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $profile = Join-Path $hostRoot 'profile'
    $roaming = Join-Path $hostRoot 'roaming'
    $local = Join-Path $hostRoot 'local'
    foreach ($dir in @($profile, $roaming, $local)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $hostContext = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local
    $hostIntent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $hostContext -FilesystemCapabilityHash ('a' * 64)
    $hostBootstrapLock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $hostContext -Intent $hostIntent
    try { Assert ($null -ne $hostBootstrapLock) 'host sandbox bootstrap returns the held global lock' }
    finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $hostBootstrapLock }

    $canonicalRepo = Join-Path $hostRoot 'repo'
    $canonicalProbe = Join-Path $hostRoot 'probe'
    $canonicalRecoveryParent = Join-Path $hostRoot 'recovery-parent'
    foreach ($dir in @($canonicalRepo, $canonicalProbe, $canonicalRecoveryParent)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-HostDirectoryCurrentUserOnly -Path $canonicalRecoveryParent
    [System.IO.File]::WriteAllText((Join-Path $canonicalRepo 'fixture.txt'), 'host canonical fixture', [System.Text.UTF8Encoding]::new($false))
    & git init --quiet $canonicalRepo
    if ($LASTEXITCODE -ne 0) { throw 'host canonical fixture git init failed' }
    & git -C $canonicalRepo add fixture.txt
    if ($LASTEXITCODE -ne 0) { throw 'host canonical fixture git add failed' }
    & git -C $canonicalRepo -c 'user.name=Host Fixture' -c 'user.email=host-fixture@example.invalid' commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'host canonical fixture git commit failed' }
    $canonicalRecovery = Join-Path $canonicalRecoveryParent 'recovery'
    $canonicalPayload = New-CanonicalSetupPlanPayload -RepoRoot $canonicalRepo -CanonicalRecoveryRoot $canonicalRecovery -ControlBase ([string] $hostContext.ControlBase) -BackupRoot ([string] $hostContext.BackupRoot) -ProbeRoot $canonicalProbe -ToolchainRoot $RepoRoot
    New-Item -ItemType Directory -Force -Path $canonicalRecovery | Out-Null
    Set-HostDirectoryCurrentUserOnly -Path $canonicalRecovery
    $canonicalGit = Get-CanonicalGitContext -RepoRoot $canonicalRepo
    $canonicalPaths = Get-CanonicalTransactionContractPaths -GitContext $canonicalGit
    $canonicalState = New-CanonicalFinalSetupState -PlanPayload $canonicalPayload -RepoRoot $canonicalRepo
    $canonicalLock = Enter-CanonicalRepoLock -LockPath ([string] $canonicalPaths.LockPath) -AllowCreate
    try { $null = Write-HostSemanticDocument -Path ([string] $canonicalPaths.SetupStatePath) -Document $canonicalState }
    finally { Exit-CanonicalRepoLock -LockHandle $canonicalLock }

    $sourceClaude = Join-Path $hostRoot 'source/claude/skills'
    $sourceCodex = Join-Path $hostRoot 'source/codex/skills'
    $sourceReasonix = Join-Path $hostRoot 'source/reasonix/skills'
    $stagingClaude = Join-Path $hostRoot 'staging/claude'
    $stagingCodex = Join-Path $hostRoot 'staging/codex'
    $stagingReasonix = Join-Path $hostRoot 'staging/reasonix'
    foreach ($dir in @($sourceClaude, $sourceCodex, $sourceReasonix, $stagingClaude, $stagingCodex, $stagingReasonix)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $hostFixture = [pscustomobject][ordered]@{
        Root = $hostRoot
        Context = $hostContext
        Canonical = [pscustomobject][ordered]@{
            RepoRoot = $canonicalRepo
            RepoId = [string] $canonicalPayload.ExpectedRootClaim.RepoId
            LockPath = [string] $canonicalPaths.LockPath
        }
        Staging = [ordered]@{ Claude = $stagingClaude; Codex = $stagingCodex; Reasonix = $stagingReasonix }
        Source = [ordered]@{ Claude = $sourceClaude; Codex = $sourceCodex; Reasonix = $sourceReasonix }
        Capability = [ordered]@{ Claude = ('9' * 64); Codex = ('8' * 64); Reasonix = ('7' * 64) }
        WorkingTreeRoots = [ordered]@{ FixtureRepo = $canonicalRepo; ToolchainRoot = $RepoRoot }
    }

    $claudeLive = Get-HostLiveRootPath -Context $hostContext -Platform 'Claude'
    $codexLive = Get-HostLiveRootPath -Context $hostContext -Platform 'Codex'
    $reasonixLive = Get-HostLiveRootPath -Context $hostContext -Platform 'Reasonix'
    foreach ($dir in @($claudeLive, $codexLive, $reasonixLive)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Write-TextFile -Path (Join-Path $claudeLive 'retired-skill/SKILL.md') -Content 'retire-me'
    $initialPlan = New-HostPlanDocument -Fixture $hostFixture -OperationKind 'initial' -ClaimsHash ('c' * 64)
    Assert-ThrowsToken { Invoke-HostTransaction -Fixture $hostFixture -Plan $initialPlan } 'live-transaction-not-pristine' 'initial host refuses a non-empty live root before any write'
    Assert ((@(Get-ChildItem -LiteralPath ([string] $hostContext.LiveTransactionsRoot) -Force -ErrorAction SilentlyContinue)).Count -eq 0) 'initial not-pristine leaves the journal root empty'
    Assert (-not (Test-Path -LiteralPath ([string] $hostContext.RootClaimsPath))) 'initial not-pristine does not create claims'

    $retirementMissingPlan = New-HostPlanDocument -Fixture $hostFixture -OperationKind 'retirement' -ClaimsHash ('c' * 64)
    Assert-ThrowsToken { Invoke-HostTransaction -Fixture $hostFixture -Plan $retirementMissingPlan } 'live-transaction-authority-required' 'retirement host refuses a missing claims file before any write'
    Assert ((@(Get-ChildItem -LiteralPath ([string] $hostContext.LiveTransactionsRoot) -Force -ErrorAction SilentlyContinue)).Count -eq 0) 'retirement authority-required leaves the journal root empty'

    $hostClaims = New-HostRootClaims -Context $hostContext
    [System.IO.Directory]::CreateDirectory([string] $hostContext.AuthorityRoot) | Out-Null
    $hostClaimsBytes = Write-HostSemanticDocument -Path ([string] $hostContext.RootClaimsPath) -Document $hostClaims
    $hostClaimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($hostClaimsBytes)).ToLowerInvariant()
    $hostPreviousState = New-HostPreviousStateDocument -Context $hostContext -ClaimsHash $hostClaimsHash -Capability $hostFixture.Capability
    $null = Write-HostSemanticDocument -Path ([string] $hostContext.CurrentEnvStatePath) -Document $hostPreviousState
    $retiredHash = (Get-SafeTreeSnapshot -Root (Join-Path $claudeLive 'retired-skill')).TreeHash
    $retirementActions = @(
        [ordered]@{
            Order = 0
            Platform = 'Claude'
            Action = 'prune'
            Name = 'retired-skill'
            SourceHash = $null
            LiveHash = $retiredHash
            Authority = 'explicit-retirement'
        }
    )
    $retirementPlan = New-HostPlanDocument -Fixture $hostFixture -OperationKind 'retirement' -ClaimsHash $hostClaimsHash -Actions $retirementActions

    $journalBeforeBusy = @(Get-ChildItem -LiteralPath ([string] $hostContext.LiveTransactionsRoot) -Force -ErrorAction SilentlyContinue)
    $heldForBusy = Enter-CanonicalRepoLock -LockPath ([string] $canonicalPaths.LockPath)
    try {
        Assert-ThrowsToken { Invoke-HostTransaction -Fixture $hostFixture -Plan $retirementPlan } 'operation-lock-busy' 'a second host loses the live lock with operation-lock-busy'
        $journalAfterBusy = @(Get-ChildItem -LiteralPath ([string] $hostContext.LiveTransactionsRoot) -Force -ErrorAction SilentlyContinue)
        Assert ($journalAfterBusy.Count -eq $journalBeforeBusy.Count) 'a lock-busy second host publishes no journal namespace'
        Assert (Test-Path -LiteralPath (Join-Path $claudeLive 'retired-skill/SKILL.md')) 'a lock-busy second host does not mutate live targets'
    }
    finally { Exit-CanonicalRepoLock -LockHandle $heldForBusy }

    $reacquired = Enter-CanonicalRepoLock -LockPath ([string] $canonicalPaths.LockPath)
    try {
        Assert ($null -ne $reacquired) 'the live lock can be acquired again after the holder releases'
    }
    finally { Exit-CanonicalRepoLock -LockHandle $reacquired }

    $hostResult = Invoke-HostTransaction -Fixture $hostFixture -Plan $retirementPlan
    Assert ([string] $hostResult.TransactionId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') 'the host returns a UUIDv4 TransactionId'
    Assert ([string] $hostResult.ReceiptId -cne [string] $hostResult.TransactionId) 'the host binds a distinct ReceiptId'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $hostResult.ReceiptPath)) -ceq 'COMPLETE') 'the host receipt slot is COMPLETE'
    Assert (-not (Test-Path -LiteralPath (Join-Path $claudeLive 'retired-skill'))) 'the retirement host prunes the live skill'
    Assert (Test-Path -LiteralPath (Join-Path $stagingClaude 'swap/retired-skill/SKILL.md')) 'the pruned live copy is preserved in swap-old'
    $hostChain = Get-SealedLiveJournalChain -TransactionDirectory ([string] $hostResult.JournalDir)
    $hostPhases = @($hostChain.Records | ForEach-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] })
    Assert (@($hostPhases | Where-Object { $_ -ceq 'RECEIPT_COMPLETE' }).Count -eq 1) 'the host journal contains RECEIPT_COMPLETE'
    Assert (@($hostPhases | Where-Object { $_ -ceq 'NEW_INSTALLED' }).Count -eq 1) 'the host journal contains NEW_INSTALLED'
    Assert (@($hostPhases | Where-Object { $_ -ceq 'STATE_PUBLISHED' }).Count -eq 1) 'the host journal contains STATE_PUBLISHED'
    Assert (@($hostPhases | Where-Object { $_ -ceq 'POSTCONDITIONS_OK' }).Count -eq 1) 'the host journal contains POSTCONDITIONS_OK'
    Assert (@($hostPhases | Where-Object { $_ -ceq 'COMPLETE' }).Count -eq 1) 'the host journal contains the terminal COMPLETE record'
    Assert ($null -ne $hostChain.Result -and [string] $hostChain.Result.Outcome -ceq 'committed') 'the host publishes a committed result'
    $null = Test-SealedLiveJournalChain -Header $hostChain.Header -Records $hostChain.Records -Result $hostChain.Result -ResultFileHash $hostChain.ResultFileHash
    Assert $true 'the host journal chain validates end to end'
    $installedHostStateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes([string] $hostContext.CurrentEnvStatePath))).ToLowerInvariant()
    Assert ($installedHostStateHash -ceq [string] $hostResult.StateHash) 'the installed state hash matches the host result'
    Assert ((Get-FileByteHash -Path ([string] $hostContext.RootClaimsPath)) -ceq $hostClaimsHash) 'retirement leaves the immutable claims bytes unchanged'
    Assert ([string] $hostResult.PostconditionsHash -cne '') 'the host returns a PostconditionsHash'
    Assert ([string] $hostResult.ResultHash -ceq [string] $hostChain.ResultFileHash) 'the host ResultHash matches the published result file'

    $afterSuccess = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $hostContext
    try {
        Assert ($null -ne $afterSuccess) 'the host releases the live lock before returning'
    }
    finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $afterSuccess }

    Write-Host '[recovery status locator]'
    $recoverScript = Join-Path $RepoRoot 'scripts/recover-live-transaction.ps1'
    # Over the finished host transactions the locator reports clean.
    $result = & pwsh -NoProfile -File $recoverScript -Status -ControlBase ([string] $hostContext.ControlBase) 2>&1
    Assert ($LASTEXITCODE -eq 0 -and ($result | Out-String) -match 'Recovery scan: clean') 'the locator reports clean over finished transactions'

    function New-RecoveryFixtureJournal {
        param([string] $ControlRoot, [string] $Name, [string[]] $Phases, [switch] $NoResult, [string] $ExtraFile, [switch] $DropOrigin)
        $dir = Join-Path (Join-Path $ControlRoot 'live-transactions') $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $header = [ordered]@{
            SchemaVersion = 1
            ArtifactKind = 'live-journal-header'
            TransactionId = $Name
            OriginRepoId = ('1' * 64)
            GitCommonDirHash = ('2' * 64)
            CanonicalLockKey = ('3' * 64)
            HomeAuthorityKey = ('4' * 64)
            ReceiptIntent = [ordered]@{ Id = [Guid]::NewGuid().ToString(); Path = (Join-Path $ControlRoot 'absent-receipt') }
        }
        if ($DropOrigin) { $header.Remove('OriginRepoId') }
        [IO.File]::WriteAllText((Join-Path $dir 'header.json'), ((ConvertTo-Json -InputObject $header -Depth 6) + "`n"), [System.Text.UTF8Encoding]::new($false))
        $sequence = 1
        foreach ($phase in $Phases) {
            $record = [ordered]@{ SchemaVersion = 1; Phase = $phase; Data = [ordered]@{} }
            [IO.File]::WriteAllText((Join-Path $dir ('{0:d6}.json' -f $sequence)), ((ConvertTo-Json -InputObject $record -Depth 6) + "`n"), [System.Text.UTF8Encoding]::new($false))
            $sequence++
        }
        if (-not $NoResult) {
            $resultDocument = [ordered]@{ SchemaVersion = 1; ArtifactKind = 'live-operation-result'; Outcome = 'committed' }
            [IO.File]::WriteAllText((Join-Path $dir 'result.json'), ((ConvertTo-Json -InputObject $resultDocument -Depth 6) + "`n"), [System.Text.UTF8Encoding]::new($false))
        }
        if ($ExtraFile) { [IO.File]::WriteAllText((Join-Path $dir $ExtraFile), 'extra', [System.Text.UTF8Encoding]::new($false)) }
    }

    $locatorRoot = Join-Path $work 'recover-locator'
    function Invoke-Locator {
        param([string] $FixtureName, [string] $JsonPath)
        $locatorControl = Join-Path $locatorRoot $FixtureName
        New-Item -ItemType Directory -Force -Path (Join-Path $locatorControl 'live-transactions') | Out-Null
        $locatorArguments = @('-Status', '-ControlBase', $locatorControl)
        if (-not [string]::IsNullOrWhiteSpace($JsonPath)) { $locatorArguments += @('-JsonPath', $JsonPath) }
        $lines = & pwsh -NoProfile -File $recoverScript @locatorArguments 2>&1
        return @{ Out = ($lines | Out-String); Code = $LASTEXITCODE }
    }

    # abandon-eligible: only pre-primitive phases and no result.
    New-RecoveryFixtureJournal -ControlRoot (Join-Path $locatorRoot 'abandon') -Name ('a' * 8 + '-1111-4111-8111-111111111111') -Phases @('RESERVED', 'RECEIPT_COMPLETE') -NoResult
    $scan = Invoke-Locator -FixtureName 'abandon'
    Assert ($scan.Code -eq 0 -and $scan.Out -match 'Recovery scan: abandon-eligible' -and $scan.Out -match 'abandon-eligible \(outcome=, receipt=') 'the locator classifies a receipt-only journal as abandon-eligible'

    # rollback-required: a target primitive was applied before the state.
    New-RecoveryFixtureJournal -ControlRoot (Join-Path $locatorRoot 'rollback') -Name ('b' * 8 + '-1111-4111-8111-222222222222') -Phases @('RESERVED', 'RECEIPT_COMPLETE', 'NEW_INSTALLED') -NoResult
    $scan = Invoke-Locator -FixtureName 'rollback'
    Assert ($scan.Code -eq 0 -and $scan.Out -match 'Recovery scan: rollback-required') 'the locator classifies an applied-primitive journal as rollback-required'

    # finalize-eligible: result published but the terminal record is missing.
    New-RecoveryFixtureJournal -ControlRoot (Join-Path $locatorRoot 'finalize') -Name ('c' * 8 + '-1111-4111-8111-333333333333') -Phases @('RESERVED', 'RECEIPT_COMPLETE', 'STATE_PUBLISHED', 'POSTCONDITIONS_OK')
    $scan = Invoke-Locator -FixtureName 'finalize'
    Assert ($scan.Code -eq 0 -and $scan.Out -match 'Recovery scan: finalize-eligible') 'the locator classifies a result-without-terminal journal as finalize-eligible'

    # manual-recovery-required: unknown namespace entries fail closed.
    New-RecoveryFixtureJournal -ControlRoot (Join-Path $locatorRoot 'manual-unknown') -Name ('d' * 8 + '-1111-4111-8111-444444444444') -Phases @('RESERVED') -NoResult -ExtraFile 'unexpected.bin'
    $scan = Invoke-Locator -FixtureName 'manual-unknown'
    Assert ($scan.Code -eq 0 -and $scan.Out -match 'Recovery scan: manual-recovery-required' -and $scan.Out -match 'unknown namespace entries') 'unknown namespace entries fail closed as manual'

    # manual-recovery-required: a header without an origin binding.
    New-RecoveryFixtureJournal -ControlRoot (Join-Path $locatorRoot 'manual-origin') -Name ('e' * 8 + '-1111-4111-8111-555555555555') -Phases @('RESERVED') -NoResult -DropOrigin
    $scan = Invoke-Locator -FixtureName 'manual-origin'
    Assert ($scan.Code -eq 0 -and $scan.Out -match 'header field OriginRepoId missing') 'a header without an origin binding fails closed as manual'

    # known _pending temps are neither records nor unknown entries.
    New-RecoveryFixtureJournal -ControlRoot (Join-Path $locatorRoot 'pending') -Name ('f' * 8 + '-1111-4111-8111-666666666666') -Phases @('RESERVED') -NoResult
    New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path (Join-Path $locatorRoot 'pending') 'live-transactions') (('f' * 8 + '-1111-4111-8111-666666666666') + '\_pending')) | Out-Null
    $scan = Invoke-Locator -FixtureName 'pending'
    Assert ($scan.Code -eq 0 -and $scan.Out -match 'Recovery scan: abandon-eligible' -and $scan.Out -notmatch 'unknown namespace entries') 'known pending temps do not fail the classification'

    # the JSON report is create-new and carries the statuses.
    $locatorJson = Join-Path $work 'recover-status.json'
    $scan = Invoke-Locator -FixtureName 'report' -JsonPath $locatorJson
    Assert ($scan.Code -eq 0 -and (Test-Path -LiteralPath $locatorJson)) 'the locator writes the machine-readable report'
    $secondScan = Invoke-Locator -JsonPath $locatorJson
    Assert ($secondScan.Code -ne 0 -and $secondScan.Out -match 'already exists') 'the locator refuses to overwrite its report'

    Write-Host '[rollback-plan contract]'
    $fixturesRoot = Join-Path $RepoRoot 'tests/fixtures/artifacts'
    $rollbackSchemaPath = Join-Path $RepoRoot 'schemas/rollback-plan.schema.json'
    $syncSchemaPath = Join-Path $RepoRoot 'schemas/sync-plan.schema.json'

    # The positive document passes both schema validation and the semantic layer.
    $positivePath = Join-Path $fixturesRoot 'rollback-plan.valid.json'
    $positiveOk = $true
    try {
        $null = Invoke-FixedJsonSchemaValidation -SchemaPath $rollbackSchemaPath -InstancePath $positivePath
        $positiveDoc = ConvertFrom-SemanticJson -Json (Get-Content -Raw -LiteralPath $positivePath)
        Test-RollbackPlanSemantics -Document $positiveDoc
    }
    catch { $positiveOk = $false }
    Assert $positiveOk 'the positive rollback-plan passes schema and semantic validation'

    # Every semantic-layer negative is rejected with its reviewed token.
    $semanticNegatives = @(
        @{ Name = 'plan-hash-tamper'; Failure = 'rollback-plan-hash-mismatch' }
        @{ Name = 'document-hash-tamper'; Failure = 'rollback-plan-hash-mismatch' }
        @{ Name = 'plan-action-mismatch'; Failure = 'rollback-plan-kind-mismatch' }
        @{ Name = 'closing-plan-kind-mismatch'; Failure = 'rollback-plan-projection-mismatch' }
        @{ Name = 'projection-outcome-mismatch'; Failure = 'rollback-plan-projection-mismatch' }
        @{ Name = 'operation-kind-substitution'; Failure = 'rollback-plan-kind-mismatch' }
        @{ Name = 'chain-order-break'; Failure = 'rollback-plan-chain-invalid' }
        @{ Name = 'complete-chain-present'; Failure = 'rollback-plan-chain-invalid' }
        @{ Name = 'journal-head-mismatch'; Failure = 'rollback-plan-chain-invalid' }
        @{ Name = 'claims-binding-missing'; Failure = 'rollback-plan-binding-missing' }
        @{ Name = 'duplicate-consumed-hash'; Failure = 'rollback-plan-binding-missing' }
    )
    foreach ($negative in $semanticNegatives) {
        $path = Join-Path $fixturesRoot ('rollback-plan.' + $negative.Name + '.invalid.json')
        $document = ConvertFrom-SemanticJson -Json (Get-Content -Raw -LiteralPath $path)
        Assert-ThrowsToken { Test-RollbackPlanSemantics -Document $document } $negative.Failure "semantic negative '$($negative.Name)' is rejected with its reviewed token"
    }

    # Every schema-layer negative is rejected before the semantic layer runs.
    $schemaNegatives = @(
        'unknown-property', 'finalize-partial-receipt', 'environment-rollback-missing-receipt',
        'state-only-receipt-crossing', 'state-only-missing-preimage'
    )
    foreach ($name in $schemaNegatives) {
        $path = Join-Path $fixturesRoot ('rollback-plan.' + $name + '.invalid.json')
        $rejected = $false
        try { $null = Invoke-FixedJsonSchemaValidation -SchemaPath $rollbackSchemaPath -InstancePath $path }
        catch { $rejected = $true }
        Assert $rejected "schema negative '$name' is rejected by the rollback-plan schema"
    }

    # The schema-3 sync-plan contract rejects every rollback/recovery PlanKind.
    $syncKindFixtures = @(
        @{ Kind = 'environment-rollback'; Name = 'sync-plan.environment-rollback-kind.invalid.json' }
        @{ Kind = 'live-recover-abandon'; Name = 'sync-plan.live-recover-abandon-kind.invalid.json' }
        @{ Kind = 'live-recover-rollback'; Name = 'sync-plan.live-recover-rollback-kind.invalid.json' }
        @{ Kind = 'live-recover-finalize'; Name = 'sync-plan.live-recover-kind.invalid.json' }
    )
    foreach ($fixture in $syncKindFixtures) {
        $path = Join-Path $fixturesRoot $fixture.Name
        $rejected = $false
        try { $null = Invoke-FixedJsonSchemaValidation -SchemaPath $syncSchemaPath -InstancePath $path }
        catch { $rejected = $true }
        Assert $rejected "sync-plan schema rejects OperationKind '$($fixture.Kind)'"
    }

    Write-Host '[live recover dispatch surface]'
    $cliScript = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'
    $recoveryScript = Join-Path $RepoRoot 'scripts/recover-live-transaction.ps1'
    $dispatchTx = 'a0b1c2d3-0001-4000-8000-000000000001'

    function Invoke-CliArguments {
        param([Parameter(Mandatory)] [string] $ScriptPath, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Arguments)
        $output = @(& pwsh -NoProfile -File $ScriptPath @Arguments 2>&1)
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($output -join "`n") }
    }

    # Wrapper gates: every case below exits before any target process spawns,
    # so they are safe to run outside the sandbox.
    $r = Invoke-CliArguments -ScriptPath $cliScript -Arguments @('live')
    Assert ($r.Code -ne 0 -and $r.Out -match 'requires a sub-action') 'live requires a sub-action'
    $r = Invoke-CliArguments -ScriptPath $cliScript -Arguments @('live', 'recover')
    Assert ($r.Code -ne 0 -and $r.Out -match 'live recover requires status, abandon, rollback, or finalize') 'live recover requires a recovery action'
    $r = Invoke-CliArguments -ScriptPath $cliScript -Arguments @('live', 'recover', 'bogus')
    Assert ($r.Code -ne 0 -and $r.Out -match 'Unsupported live recover action') 'an unsupported live recover action is rejected'
    $r = Invoke-CliArguments -ScriptPath $cliScript -Arguments @('live', 'recover', 'abandon', '-TransactionId', $dispatchTx, '-PlanPath', (Join-Path $work 'gated-plan.json'))
    Assert ($r.Code -ne 0 -and $r.Out -match 'requires an explicit -DryRun or -Apply') 'a live recover action requires an explicit mode'
    $r = Invoke-CliArguments -ScriptPath $cliScript -Arguments @('live', 'recover', 'abandon', '-DryRun', '-Apply', '-TransactionId', $dispatchTx, '-PlanPath', (Join-Path $work 'gated-plan.json'))
    Assert ($r.Code -ne 0 -and $r.Out -match 'accepts only one mode') 'a live recover action accepts only one mode'

    # Sandbox dispatch: the injected authority gate precedes everything.
    . (Join-Path $PSScriptRoot 'helpers/safety-sandbox.ps1')
    $dispatchWork = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-live-dispatch-$([Guid]::NewGuid().ToString('N'))"
    $dispatchHome = Join-Path $dispatchWork 'home'
    New-Item -ItemType Directory -Force -Path $dispatchHome | Out-Null
    function Invoke-RecoveryDispatch {
        param([AllowEmptyCollection()] [string[]] $Arguments)
        return Invoke-SafetySandboxScript -SandboxRoot $dispatchWork -ScriptPath $recoveryScript -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
    }

    $r = Invoke-RecoveryDispatch -Arguments @('-Status')
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-plan-authority-missing') 'the status route fails closed without a complete authority'
    $stubPlan = Join-Path $dispatchWork 'stub-plan.json'
    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'abandon', '-TransactionId', $dispatchTx, '-DryRun', '-PlanPath', $stubPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-plan-authority-missing') 'the dispatch route fails closed without a complete authority'
    Assert (-not (Test-Path -LiteralPath $stubPlan)) 'the authority gate writes no plan file'

    # Bootstrap the sandbox authority in its own process, mirroring the sync
    # parity fixture (the sealed route capture is process-global).
    $dispatchSetup = Join-Path $dispatchWork 'setup-authority.ps1'
    @'
#requires -Version 7.0
param([string] $AuthorityRepo)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $AuthorityRepo 'scripts/json-artifact-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/root-claims-registry-common.ps1')
$injectedHome = $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT
foreach ($folder in @((Join-Path $injectedHome 'AppData\Roaming'), (Join-Path $injectedHome 'AppData\Local'))) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
}
$identity = [pscustomobject][ordered]@{
    ResolverVersion = 'windows-token-sid-known-folder-v1'
    TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    ProfileRoot = $injectedHome
    RoamingAppDataRoot = (Join-Path $injectedHome 'AppData\Roaming')
    LocalAppDataRoot = (Join-Path $injectedHome 'AppData\Local')
}
$context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity
$intent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $context -FilesystemCapabilityHash ('a' * 64)
$lock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $context -Intent $intent
try { if ($null -eq $lock) { throw 'bootstrap returned no lock' } }
finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
Write-Host 'dispatch sandbox authority bootstrap complete'
'@ | Set-Content -LiteralPath $dispatchSetup -Encoding UTF8
    $r = Invoke-SafetySandboxScript -SandboxRoot $dispatchWork -ScriptPath $dispatchSetup -Arguments @('-AuthorityRepo', $RepoRoot) -AuthorityRepoRoot $RepoRoot
    if ($r.Code -ne 0) { Write-Host '----- dispatch setup output -----'; Write-Host $r.Out }
    Assert ($r.Code -eq 0) 'the dispatch sandbox authority bootstrap succeeds'

    $r = Invoke-RecoveryDispatch -Arguments @('-Status')
    Assert ($r.Code -eq 0 -and $r.Out -match 'Recovery scan: clean') 'the status route resolves the injected authority and reports clean'
    $r = Invoke-SafetySandboxScript -SandboxRoot $dispatchWork -ScriptPath $cliScript -Arguments @('live', 'recover', 'status') -AuthorityRepoRoot $RepoRoot
    Assert ($r.Code -eq 0 -and $r.Out -match 'Recovery scan: clean') 'the CLI live recover status route reports through the injected authority'

    # Task 6 Step 3 dispatcher: with the authority bootstrapped, DryRun
    # derives the reviewed plan under the origin lock order and Apply
    # validates a reviewed plan fail-closed before the execution stub.
    . (Join-Path $RepoRoot 'scripts/home-authority-common.ps1')
    . (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
    $dispatchRepo = Join-Path $dispatchWork 'repo'
    New-Item -ItemType Directory -Force -Path $dispatchRepo | Out-Null
    & git -C $dispatchRepo init --quiet
    & git -C $dispatchRepo -c user.name='dispatch fixture' -c user.email='dispatch-fixture@ai-agent-dotfiles.invalid' commit --allow-empty --quiet -m 'dispatch fixture'
    if ($LASTEXITCODE -ne 0) { throw 'dispatch fixture repo commit failed' }
    $dispatchGit = Get-CanonicalGitContext -RepoRoot $dispatchRepo
    $dispatchPaths = Get-CanonicalTransactionContractPaths -GitContext $dispatchGit
    $dispatchRepoId = Get-CanonicalRepoIdentity -GitContext $dispatchGit
    $dispatchLockKey = Get-SemanticJsonHash -InputObject ([ordered]@{ Path = [string] $dispatchPaths.LockPath })
    $derivedControl = Join-Path $dispatchHome 'AppData\Local\ai-agent-dotfiles\control'
    $derivedBackups = Join-Path $dispatchHome 'AppData\Local\ai-agent-dotfiles\backups'
    $dispatchAuthorityKey = Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/home-authority/v1'
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        HomeRootLocationKey = (ConvertTo-HomeAuthorityLocationKey -Path $dispatchHome)
    })

    $dispatchTxId = [Guid]::NewGuid().ToString()
    $dispatchReceiptId = [Guid]::NewGuid().ToString()
    $txDir = Join-Path (Join-Path $derivedControl 'live-transactions') $dispatchTxId
    $dispatchHeader = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-journal-header'
        TransactionId = $dispatchTxId
        OperationKind = 'environment'
        TransactionMode = 'receipt-backed'
        OriginalDocumentHash = ('1' * 64)
        OriginalPlanHash = ('2' * 64)
        HomeAuthorityKey = $dispatchAuthorityKey
        OriginRepoId = $dispatchRepoId
        GitCommonDirHash = $dispatchGit.GitCommonDirHash
        CanonicalLockKey = $dispatchLockKey
        ReceiptIntent = [ordered]@{ Id = $dispatchReceiptId; Path = (Join-Path $derivedBackups $dispatchReceiptId) }
        Targets = @()
    }
    New-SealedLiveJournalHeader -Document $dispatchHeader -TransactionDirectory $txDir | Out-Null
    Add-SealedLiveJournalRecord -TransactionDirectory $txDir -Phase 'RECEIPT_COMPLETE' -Data ([ordered]@{
        ReceiptRef = [ordered]@{ Id = $dispatchReceiptId; Path = (Join-Path $derivedBackups $dispatchReceiptId); Hash = ('8' * 64) }
    }) | Out-Null

    $abandonPlan = Join-Path $dispatchWork 'plans' 'abandon-plan.json'
    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'abandon', '-TransactionId', $dispatchTxId, '-DryRun', '-PlanPath', $abandonPlan, '-RepoRoot', $dispatchRepo)
    if ($r.Code -ne 0) { Write-Host '----- abandon dry-run output -----'; Write-Host $r.Out }
    Assert ($r.Code -eq 0 -and $r.Out -match 'live recovery plan created') 'the abandon dry-run derives the reviewed plan under the origin locks'
    Assert (Test-Path -LiteralPath $abandonPlan) 'the abandon plan file exists'
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $rollbackSchemaPath -InstancePath $abandonPlan
    $planDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($abandonPlan, [System.Text.UTF8Encoding]::new($false, $true)))
    Test-RollbackPlanSemantics -Document $planDocument
    $planPayload = [System.Collections.IDictionary] $planDocument['PlanPayload']
    Assert ([string] $planPayload['PlanKind'] -ceq 'live-recover-abandon') 'the plan passes schema and semantics and binds the abandon kind'
    Assert ([string] $planPayload['TransactionId'] -ceq $dispatchTxId) 'the plan binds the transaction id'
    Assert ([string] $planPayload['ReceiptState'] -ceq 'MISSING') 'the plan binds the declared missing receipt state'
    Assert ([string] $planPayload['ExpectedOutcome'] -ceq 'abandoned') 'the plan binds the abandoned outcome'

    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'abandon', '-TransactionId', $dispatchTxId, '-DryRun', '-PlanPath', $abandonPlan, '-RepoRoot', $dispatchRepo)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-recovery-plan-path-collision') 'the second dry-run refuses to overwrite its plan'
    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'finalize', '-TransactionId', $dispatchTxId, '-DryRun', '-PlanPath', (Join-Path $dispatchWork 'finalize-plan.json'), '-RepoRoot', $dispatchRepo)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-recovery-action-mismatch') 'a finalize request on an abandon-eligible journal fails closed'
    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'abandon', '-TransactionId', $dispatchTxId, '-Apply', '-PlanPath', $abandonPlan, '-RepoRoot', $dispatchRepo)
    if ($r.Code -ne 0) { Write-Host '----- abandon apply output -----'; Write-Host $r.Out }
    Assert ($r.Code -eq 0 -and $r.Out -match 'live recovery applied: abandon') 'the abandon apply executes the reviewed transition'
    $abandonedChain = Get-SealedLiveJournalChain -TransactionDirectory $txDir
    $abandonedPhases = @($abandonedChain.Records | ForEach-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] })
    Assert (@($abandonedPhases | Where-Object { $_ -ceq 'RECOVERY_ACTION_INTENT' }).Count -eq 1 -and @($abandonedPhases | Where-Object { $_ -ceq 'RECOVERY_ACTION_APPLIED' }).Count -eq 1 -and $abandonedPhases[-1] -ceq 'COMPLETE') 'the abandoned journal carries intent, applied, and the terminal record'
    $terminalData = [System.Collections.IDictionary] ([System.Collections.IDictionary] $abandonedChain.Records[-1]['Document'])['Data']
    Assert ([string] $terminalData['ClosingKind'] -ceq 'recovery' -and [string] $terminalData['ClosingPlanKind'] -ceq 'live-recover-abandon' -and [string] $terminalData['ClosingDocumentHash'] -ceq [string] $planDocument['DocumentHash']) 'the terminal record closes with the recovery plan binding'
    Assert ($null -ne $abandonedChain.Result -and [string] ([System.Collections.IDictionary] $abandonedChain.Result)['Outcome'] -ceq 'abandoned') 'the abandoned result is published'
    $r = Invoke-RecoveryDispatch -Arguments @('-Status', '-ControlBase', $derivedControl)
    Assert ($r.Code -eq 0 -and $r.Out -match 'Recovery scan: clean') 'the locator reports clean after the abandon recovery'
    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'abandon', '-TransactionId', $dispatchTxId, '-Apply', '-PlanPath', $abandonPlan, '-RepoRoot', $dispatchRepo)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-recovery-transaction-finished') 'a second recovery of a finished transaction fails closed'
    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'abandon', '-TransactionId', 'd4e5f6a7-0004-4000-b000-000000000004', '-DryRun', '-PlanPath', (Join-Path $dispatchWork 'unknown-plan.json'), '-RepoRoot', $dispatchRepo)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-recovery-transaction-unknown') 'an unknown transaction id fails closed'

    $wrongRepo = Join-Path $dispatchWork 'wrong-clone'
    New-Item -ItemType Directory -Force -Path $wrongRepo | Out-Null
    & git -C $wrongRepo init --quiet
    & git -C $wrongRepo -c user.name='wrong clone' -c user.email='wrong-clone@ai-agent-dotfiles.invalid' commit --allow-empty --quiet -m 'wrong clone'
    if ($LASTEXITCODE -ne 0) { throw 'wrong clone fixture failed' }
    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'abandon', '-TransactionId', $dispatchTxId, '-DryRun', '-PlanPath', (Join-Path $dispatchWork 'wrong-plan.json'), '-RepoRoot', $wrongRepo)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live journal origin identity mismatch') 'a wrong clone cannot substitute its own repository lock'

    # State-only finalize: a controller-transition journal with a published
    # committed result and no terminal record is finalize-eligible.
    $finalizeTxId = [Guid]::NewGuid().ToString()
    $finalizeDir = Join-Path (Join-Path $derivedControl 'live-transactions') $finalizeTxId
    $finalizeHeader = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-journal-header'
        TransactionId = $finalizeTxId
        OperationKind = 'controller-transition'
        TransactionMode = 'state-only'
        OriginalDocumentHash = ('3' * 64)
        OriginalPlanHash = ('4' * 64)
        HomeAuthorityKey = $dispatchAuthorityKey
        OriginRepoId = $dispatchRepoId
        GitCommonDirHash = $dispatchGit.GitCommonDirHash
        CanonicalLockKey = $dispatchLockKey
        ReceiptRef = 'NO_LIVE_MUTATION'
        Targets = @()
    }
    New-SealedLiveJournalHeader -Document $finalizeHeader -TransactionDirectory $finalizeDir | Out-Null
    Add-SealedLiveJournalRecord -TransactionDirectory $finalizeDir -Phase 'STATE_PREIMAGE_COMPLETE' -Data ([ordered]@{ PreStatePhaseHash = ('0' * 64); StateHash = ('9' * 64) }) | Out-Null
    $finalizeChain = Get-SealedLiveJournalChain -TransactionDirectory $finalizeDir
    $finalizeHead = Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] @($finalizeChain.Records)[-1]['Document'])
    $finalizeResult = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-operation-result'
        ResultScope = 'transaction'
        TransactionId = $finalizeTxId
        OperationKind = 'controller-transition'
        OriginalDocumentHash = ('3' * 64)
        ResultBaseHeadHash = $finalizeHead
        Outcome = 'committed'
        StateHash = ('a' * 64)
    }
    $null = Publish-SealedLiveTransactionResult -TransactionDirectory $finalizeDir -Document $finalizeResult

    $finalizePlan = Join-Path $dispatchWork 'plans' 'finalize-plan.json'
    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'finalize', '-TransactionId', $finalizeTxId, '-DryRun', '-PlanPath', $finalizePlan, '-RepoRoot', $dispatchRepo)
    if ($r.Code -ne 0) { Write-Host '----- finalize dry-run output -----'; Write-Host $r.Out }
    Assert ($r.Code -eq 0 -and $r.Out -match 'live recovery plan created') 'the state-only finalize dry-run derives the reviewed plan'
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $rollbackSchemaPath -InstancePath $finalizePlan
    $finalizePlanDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($finalizePlan, [System.Text.UTF8Encoding]::new($false, $true)))
    Test-RollbackPlanSemantics -Document $finalizePlanDocument
    $finalizePayload = [System.Collections.IDictionary] $finalizePlanDocument['PlanPayload']
    Assert ([string] $finalizePayload['TransactionMode'] -ceq 'state-only' -and [string] $finalizePayload['ExpectedOutcome'] -ceq 'committed') 'the finalize plan binds state-only mode and the preserved committed outcome'
    $r = Invoke-RecoveryDispatch -Arguments @('-Action', 'finalize', '-TransactionId', $finalizeTxId, '-Apply', '-PlanPath', $finalizePlan, '-RepoRoot', $dispatchRepo)
    if ($r.Code -ne 0) { Write-Host '----- finalize apply output -----'; Write-Host $r.Out }
    Assert ($r.Code -eq 0 -and $r.Out -match 'live recovery applied: finalize .*\(outcome=committed\)') 'the finalize apply preserves the existing committed outcome'
    $finalizedChain = Get-SealedLiveJournalChain -TransactionDirectory $finalizeDir
    Assert ($null -ne $finalizedChain.Result -and [string] ([System.Collections.IDictionary] $finalizedChain.Records[-1]['Document'])['Data']['ResultHash'] -ceq [string] $finalizedChain.ResultFileHash) 'the finalize terminal binds the reused result file hash'
    $r = Invoke-RecoveryDispatch -Arguments @('-Status', '-ControlBase', $derivedControl)
    Assert ($r.Code -eq 0 -and $r.Out -match 'Recovery scan: clean') 'the locator reports clean after both recoveries'

    Write-Host 'live recovery tests: PASS'
}
finally {
    if ($null -ne $dispatchWork -and (Test-Path -LiteralPath $dispatchWork)) {
        Remove-Item -LiteralPath $dispatchWork -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
