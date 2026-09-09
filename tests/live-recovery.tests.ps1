#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-live-recovery-$([Guid]::NewGuid().ToString('N'))"
$internalHost = Join-Path $RepoRoot 'scripts/internal/live-transaction-host.ps1'
$liveTransactionHost = Join-Path $PSScriptRoot 'helpers/live-transaction-host.ps1'
. (Join-Path $RepoRoot 'scripts/live-transaction-common.ps1')
. (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')
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

    Write-Host 'live recovery tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
