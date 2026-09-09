#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'safe-tree-walker.ps1')
. (Join-Path $PSScriptRoot 'transaction-journal-common.ps1')
. (Join-Path $PSScriptRoot 'shared-authority-state-common.ps1')

# The canonical journal module's publication primitives (held parent handles,
# pending temp, flush, atomic rename, schema validation before rename) are
# generic and are reused unmodified for the live journal; the live artifacts,
# phases, and semantics below are live-owned.

$script:LiveTransactionIntentMismatch = 'live-transaction-intent-mismatch'
$script:LiveTransactionSchemaUnsupported = 'live-transaction-schema-unsupported'
$script:LiveTransactionHashMismatch = 'live-transaction-hash-mismatch'
$script:LiveTransactionAlreadyTerminal = 'live-transaction-already-terminal'
$script:LiveTransactionPublishFailed = 'live-transaction-publish-failed'
$script:LiveTransactionResultExists = 'live-transaction-result-already-exists'
$script:LiveTransactionChainInvalid = 'manual-recovery-required'

$script:LiveTransactionOperations = @(
    'initial', 'environment', 'task-overlay', 'migrate', 'adopt', 'repair-adopt',
    'controller-transition', 'retirement', 'environment-rollback'
)
$script:LiveTransactionPlatforms = @('Claude', 'Codex', 'Reasonix')
$script:LiveTransactionHashPattern = '^[0-9a-f]{64}$'
$script:LiveTransactionUuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
$script:LiveTransactionIdentityPattern = '^[0-9a-f]{8}:[0-9a-f]{16}$'
$script:LiveTransactionSchemaRoot = (Resolve-Path (Join-Path $PSScriptRoot '../schemas')).Path

function Assert-LiveTransactionHashSpelling {
    param($Value, [Parameter(Mandatory)] [string] $Failure)
    if ($Value -isnot [string] -or [string] $Value -cnotmatch $script:LiveTransactionHashPattern) { throw $Failure }
}

function Test-LiveTransactionMapHasName {
    param($Map, [Parameter(Mandatory)] [string] $Name)
    return ($null -ne $Map -and $Map -is [System.Collections.IDictionary] -and $Map.Contains($Name))
}

function Get-LiveTransactionObservedStateKeySet {
    # The exact key set of a header MISSING|PRESENT state object: PRESENT
    # states bind Hash and Identity but not the record-level Type.
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $State)
    if ([string] $State['State'] -ceq 'MISSING') { return @('State') }
    return @('State', 'Hash', 'Identity')
}

# ---------------------------------------------------------------------------
# Header semantics
# ---------------------------------------------------------------------------

function Test-LiveJournalHeaderSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)

    $mismatch = $script:LiveTransactionIntentMismatch
    if ([string] $Document.ArtifactKind -cne 'live-journal-header' -or [long] $Document.SchemaVersion -ne 1) {
        throw $script:LiveTransactionSchemaUnsupported
    }
    $receiptBacked = [string] $Document.TransactionMode -ceq 'receipt-backed'
    if ($receiptBacked) {
        if (-not (Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptIntent')) { throw $mismatch }
        $intent = $Document['ReceiptIntent']
        $leaf = [System.IO.Path]::GetFileName([string] $intent['Path'])
        if ($leaf -cne [string] $intent['Id']) { throw $mismatch }
        if (Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptRef') { throw $mismatch }
    }
    else {
        if (-not (Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptRef') -or [string] $Document['ReceiptRef'] -cne 'NO_LIVE_MUTATION') {
            throw $mismatch
        }
        if (Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptIntent') { throw $mismatch }
    }

    $orders = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($target in @([object[]] $Document['Targets'])) {
        $order = [long] $target['Order']
        if (-not $orders.Add($order)) { throw $mismatch }
        $kind = [string] $target['TargetKind']
        $role = [string] $target['Role']
        if (($kind -ceq 'skill') -ne ($role -ceq 'live-target')) { throw $mismatch }
        if (($kind -ceq 'state') -ne ($role -ceq 'state')) { throw $mismatch }
        if (($kind -ceq 'parent-directory') -ne ($role -ceq 'parent')) { throw $mismatch }
        if ($receiptBacked -eq $false -and (Test-LiveTransactionMapHasName -Map $target -Name 'ReceiptSnapshotRef') -and $null -ne $target['ReceiptSnapshotRef']) {
            throw $mismatch
        }
        foreach ($stateName in @('Current', 'Candidate')) {
            $state = $target[$stateName]
            $expectedKeys = Get-LiveTransactionObservedStateKeySet -State ([System.Collections.IDictionary] $state)
            $actualKeys = @([string[]] ([System.Collections.IDictionary] $state).Keys | Sort-Object { [string] $_ })
            if (($actualKeys -join "`0") -cne (($expectedKeys | Sort-Object { [string] $_ }) -join "`0")) { throw $mismatch }
        }
    }
}

# ---------------------------------------------------------------------------
# Record semantics: per-phase required/forbidden data keys
# ---------------------------------------------------------------------------

$script:LiveRecordPhaseContracts = @{
    'DIR_CREATE_INTENT'         = @{ Required = @('TargetId', 'TargetKind', 'TargetPath') }
    'DIR_CREATED'               = @{ Required = @('TargetId', 'TargetKind', 'TargetPath', 'CreatedIdentity') }
    'RECEIPT_COMPLETE'          = @{ Required = @('ReceiptRef') }
    'PREPARED'                  = @{ Required = @('TargetId', 'TargetKind', 'TargetPath', 'StagedPath', 'StagedState') }
    'MOVE_OLD_INTENT'           = @{ Required = @('TargetId', 'TargetKind', 'TargetPath', 'SwapOldPath', 'TargetState', 'SwapOldState') }
    'OLD_MOVED'                 = @{ Required = @('TargetId', 'TargetKind', 'TargetPath', 'SwapOldPath', 'TargetState', 'SwapOldState') }
    'MOVE_NEW_INTENT'           = @{ Required = @('TargetId', 'TargetKind', 'TargetPath', 'SwapOldPath', 'StagedPath', 'TargetState', 'SwapOldState', 'StagedState') }
    'NEW_INSTALLED'             = @{ Required = @('TargetId', 'TargetKind', 'TargetPath', 'SwapOldPath', 'StagedPath', 'TargetState', 'SwapOldState', 'StagedState') }
    'CLAIMS_PUBLISHED'          = @{ Required = @('ClaimsHash') }
    'STATE_PREIMAGE_COMPLETE'   = @{ Required = @('PreStatePhaseHash', 'StateHash') }
    'FILE_PREPARED'             = @{ Required = @('TargetKind', 'TargetPath', 'StagedPath', 'StagedState') }
    'FILE_REPLACE_INTENT'       = @{ Required = @('TargetKind', 'TargetPath', 'TargetState') }
    'FILE_REPLACED'             = @{ Required = @('TargetKind', 'TargetPath', 'TargetState') }
    'STATE_PUBLISHED'           = @{ Required = @('StateHash') }
    'POSTCONDITIONS_OK'         = @{ Required = @('PostconditionsHash') }
    'RECOVERY_ACTION_INTENT'    = @{ Required = @('PlanKind', 'DocumentHash', 'PriorHeadHash', 'ExpectedTerminalProjectionHash', 'ExpectedOutcome', 'Action') }
    'RECOVERY_ACTION_APPLIED'   = @{ Required = @('Action') }
    'COMPLETE'                  = @{ Required = @('ResultHash', 'OriginalDocumentHash', 'Outcome', 'ClosingKind', 'ClosingDocumentHash') }
}

$script:LiveRecordRecoveryOnlyKeys = @('PlanKind', 'DocumentHash', 'PriorHeadHash', 'ExpectedTerminalProjectionHash', 'ExpectedOutcome', 'Action', 'RestorationHash')
$script:LiveRecordClosingKeys = @('ResultHash', 'OriginalDocumentHash', 'Outcome', 'ClosingKind', 'ClosingDocumentHash', 'ClosingPlanKind')

function Test-LiveJournalRecordSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)

    $phase = [string] $Document.Phase
    if (-not $script:LiveRecordPhaseContracts.ContainsKey($phase)) { throw $script:LiveTransactionSchemaUnsupported }
    $data = [System.Collections.IDictionary] $Document['Data']

    foreach ($name in ([string[]] $script:LiveRecordPhaseContracts[$phase].Required)) {
        if (-not (Test-LiveTransactionMapHasName -Map $data -Name $name)) { throw $script:LiveTransactionIntentMismatch }
    }
    foreach ($name in ([string[]] $script:LiveRecordClosingKeys)) {
        if (-not $script:LiveRecordPhaseContracts[$phase].Required.Contains($name) -and (Test-LiveTransactionMapHasName -Map $data -Name $name)) {
            throw $script:LiveTransactionIntentMismatch
        }
    }
    if ($phase -cnotin @('RECOVERY_ACTION_INTENT', 'RECOVERY_ACTION_APPLIED', 'COMPLETE')) {
        foreach ($name in $script:LiveRecordRecoveryOnlyKeys) {
            if (Test-LiveTransactionMapHasName -Map $data -Name $name) { throw $script:LiveTransactionIntentMismatch }
        }
    }
    if ($phase -ceq 'RECOVERY_ACTION_APPLIED' -and (Test-LiveTransactionMapHasName -Map $data -Name 'PlanKind')) {
        throw $script:LiveTransactionIntentMismatch
    }
    if ($phase -ceq 'COMPLETE') {
        $kind = [string] $data['ClosingKind']
        if ($kind -ceq 'original') {
            if (Test-LiveTransactionMapHasName -Map $data -Name 'ClosingPlanKind') { throw $script:LiveTransactionIntentMismatch }
            if (-not (Test-LiveTransactionMapHasName -Map $data -Name 'ClosingDocumentHash') -or
                [string] $data['ClosingDocumentHash'] -cne [string] $data['OriginalDocumentHash']) {
                throw $script:LiveTransactionIntentMismatch
            }
        }
        elseif ($kind -ceq 'recovery') {
            if (-not (Test-LiveTransactionMapHasName -Map $data -Name 'ClosingPlanKind') -or
                -not (Test-LiveTransactionMapHasName -Map $data -Name 'ClosingDocumentHash')) {
                throw $script:LiveTransactionIntentMismatch
            }
        }
        else { throw $script:LiveTransactionIntentMismatch }
    }
}

# ---------------------------------------------------------------------------
# Result semantics
# ---------------------------------------------------------------------------

function Test-LiveOperationResultSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)

    $mismatch = $script:LiveTransactionIntentMismatch
    $scope = [string] $Document['ResultScope']
    if ($scope -ceq 'command') {
        # Command scope: exact CommandKind responses only; the schema carries
        # the field exclusions, the optional TransactionId is a lifecycle
        # reference (no-transaction / unfinished / terminal reference).
        return
    }

    $receiptBacked = Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptRef'
    if ($receiptBacked) {
        $ref = [System.Collections.IDictionary] $Document['ReceiptRef']
        $state = [string] $ref['State']
        if ($state -ceq 'COMPLETE') {
            Assert-LiveTransactionHashSpelling -Value $ref['Hash'] -Failure $mismatch
            if (-not (Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptHash') -or
                [string] $Document['ReceiptHash'] -cne [string] $ref['Hash']) { throw $mismatch }
        }
        else {
            if ($null -ne $ref['Hash']) { throw $mismatch }
            if (Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptHash') { throw $mismatch }
        }
    }
    else {
        if (Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptHash') { throw $mismatch }
    }

    $outcome = [string] $Document['Outcome']
    if ($outcome -ceq 'committed') {
        if (-not (Test-LiveTransactionMapHasName -Map $Document -Name 'StateHash')) { throw $mismatch }
        if ($receiptBacked -and (-not (Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptRef') -or
            [string] (([System.Collections.IDictionary] $Document['ReceiptRef'])['State']) -cne 'COMPLETE')) { throw $mismatch }
    }
    elseif ($outcome -ceq 'abandoned') {
        if ($receiptBacked -and (Test-LiveTransactionMapHasName -Map $Document -Name 'ReceiptHash')) { throw $mismatch }
    }
    elseif ($outcome -ceq 'rolled-back' -or $outcome -ceq 'failed-restored') {
        if (-not (Test-LiveTransactionMapHasName -Map $Document -Name 'RestorationHash')) { throw $mismatch }
        # StateHash null is the MISSING-state sentinel: first-authority
        # failures before state install have no state to hash.
        if (Test-LiveTransactionMapHasName -Map $Document -Name 'StateHash') {
            Assert-LiveTransactionHashSpelling -Value $Document['StateHash'] -Failure $mismatch
        }
    }
    else { throw $mismatch }
}



# ---------------------------------------------------------------------------
# Live target plan (roadmap Task 4 step 1)
# ---------------------------------------------------------------------------

function New-SealedLiveTransactionTargetPlan {
    # Builds the ordered live target records for a reviewed plan: MISSING
    # parent-directory components parent-first (deepest-existing-parent
    # identity bound), then one target per mutation action (add/update/prune;
    # no-op rows are postcondition-only and never mutation targets). Unknown
    # live directories and Codex .system are never targets.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BackupRoot,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ReceiptIntent,
        [Parameter(Mandatory)] [object[]] $Platforms,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Actions,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $LiveRootContexts
    )

    $mismatch = $script:LiveTransactionIntentMismatch
    $receiptPath = [System.IO.Path]::GetFullPath([string] $ReceiptIntent['Path'])
    $contextsByPlatform = [ordered]@{}
    foreach ($context in @($LiveRootContexts)) {
        $platform = [string] $context['Platform']
        if ($contextsByPlatform.Contains($platform)) { throw $mismatch }
        $contextsByPlatform[$platform] = $context
    }

    $mutationByPlatform = [ordered]@{}
    foreach ($platform in $script:LiveTransactionPlatforms) { $mutationByPlatform[$platform] = [System.Collections.Generic.List[object]]::new() }
    foreach ($action in @($Actions)) {
        $platform = [string] $action['Platform']
        if (-not $mutationByPlatform.Contains($platform)) { throw $mismatch }
        $verb = [string] $action['Action']
        if ($verb -cnotin @('add', 'update', 'prune')) { continue }
        $mutationByPlatform[$platform].Add($action)
    }

    $targets = [System.Collections.Generic.List[object]]::new()
    $order = 0L
    foreach ($platform in $script:LiveTransactionPlatforms) {
        $context = $contextsByPlatform[$platform]
        if ($null -eq $context) { throw $mismatch }
        $liveRoot = [System.IO.Path]::GetFullPath([string] $context['LiveRoot'])
        $missing = @([string[]] $context['MissingRemainder'])
        $cursor = [System.IO.Path]::GetFullPath([string] $context['DeepestExistingParentPath'])
        foreach ($segment in $missing) {
            $cursor = Join-Path $cursor $segment
            $targets.Add([ordered]@{
                TargetId = (Get-SemanticJsonHash -InputObject ([ordered]@{ Kind = 'parent-directory'; Path = $cursor }))
                Order = $order
                TargetKind = 'parent-directory'
                Role = 'parent'
                Platform = $platform
                Name = [string] $segment
                TargetPath = $cursor
                PreimagePath = $null
                SwapOldPath = (Join-Path (Join-Path ([string] $context['StagingRoot']) 'swap') $segment)
                StagedPath = $null
                LiveIdentity = $null
                ReceiptSnapshotRef = $null
                Current = [ordered]@{ State = 'MISSING' }
                Candidate = [ordered]@{ State = 'MISSING' }
                TargetContextHash = (Get-SemanticJsonHash -InputObject ([ordered]@{ Path = $cursor; Segment = $segment }))
            })
            $order++
        }
        $stagingRoot = [System.IO.Path]::GetFullPath([string] $context['StagingRoot'])
        foreach ($action in @($mutationByPlatform[$platform])) {
            $verb = [string] $action['Action']
            $name = [string] $action['Name']
            $livePath = Join-Path $liveRoot $name
            $stagedPath = Join-Path (Join-Path $stagingRoot 'staged') $name
            $swapOldPath = Join-Path (Join-Path $stagingRoot 'swap') $name
            $preimagePath = Join-Path (Join-Path (Join-Path $receiptPath 'snapshot') ([string] $platform).ToLowerInvariant()) $name
            if ($verb -ceq 'add') {
                $current = [ordered]@{ State = 'MISSING' }
                $candidate = [ordered]@{ State = 'PRESENT'; Hash = [string] $action['SourceHash']; Identity = $null }
                $liveIdentity = $null
            }
            elseif ($verb -ceq 'update') {
                if ($null -eq $action['LiveHash']) { throw $mismatch }
                $current = [ordered]@{ State = 'PRESENT'; Hash = [string] $action['LiveHash']; Identity = $null }
                $candidate = [ordered]@{ State = 'PRESENT'; Hash = [string] $action['SourceHash']; Identity = $null }
                $liveIdentity = $null
            }
            else {
                if ($null -eq $action['LiveHash']) { throw $mismatch }
                $current = [ordered]@{ State = 'PRESENT'; Hash = [string] $action['LiveHash']; Identity = $null }
                $candidate = [ordered]@{ State = 'MISSING' }
                $liveIdentity = $null
            }
            $targets.Add([ordered]@{
                TargetId = (Get-SemanticJsonHash -InputObject ([ordered]@{ Kind = 'skill'; Platform = $platform; Name = $name }))
                Order = $order
                TargetKind = 'skill'
                Role = 'live-target'
                Platform = $platform
                Name = $name
                TargetPath = $livePath
                PreimagePath = $preimagePath
                SwapOldPath = $swapOldPath
                StagedPath = $stagedPath
                LiveIdentity = $liveIdentity
                ReceiptSnapshotRef = [ordered]@{ Platform = $platform; Name = $name }
                Current = $current
                Candidate = $candidate
                TargetContextHash = (Get-SemanticJsonHash -InputObject ([ordered]@{ Path = $livePath; Old = $current; New = $candidate }))
            })
            $order++
        }
    }
    return @($targets)
}


# ---------------------------------------------------------------------------
# Same-volume staging (roadmap Task 4 step 2)
# ---------------------------------------------------------------------------

function Assert-SealedLiveMutationStagingRoot {
    # Each LiveMutationStagingRoot must sit on the same volume as its live
    # target, be a working-tree-external sibling location, and stay disjoint
    # from the forbidden roots (source/live/backup/control/canonical recovery).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StagingRoot,
        [Parameter(Mandatory)] [string] $LiveTargetVolumeRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ForbiddenRoots,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $WorkingTreeRoots
    )

    $invalid = $script:LiveTransactionIntentMismatch
    try {
        $root = [System.IO.Path]::GetFullPath($StagingRoot)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'missing' }
        Assert-NoReparseExistingChain -Path $root
        $volume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($root)
        if ([string] $volume.DriveType -cne 'Fixed' -or [string] $volume.FileSystemType -cne 'NTFS') { throw 'filesystem' }
        $rootVolume = [System.IO.Path]::GetPathRoot($root).TrimEnd([char]92).ToLowerInvariant()
        $liveVolume = [System.IO.Path]::GetPathRoot($LiveTargetVolumeRoot).TrimEnd([char]92).ToLowerInvariant()
        if ($rootVolume -cne $liveVolume) { throw 'cross-volume' }
        foreach ($forbidden in @($ForbiddenRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $forbiddenFull = [System.IO.Path]::GetFullPath($forbidden).TrimEnd([char]92, [char]47)
            $rootTrimmed = $root.TrimEnd([char]92, [char]47)
            if ($rootTrimmed -ieq $forbiddenFull -or
                $rootTrimmed.StartsWith($forbiddenFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                $forbiddenFull.StartsWith($rootTrimmed + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'overlap'
            }
        }
        foreach ($key in @($WorkingTreeRoots.Keys)) {
            $treeRoot = [System.IO.Path]::GetFullPath([string] $WorkingTreeRoots[$key]).TrimEnd([char]92, [char]47)
            if (-not [string]::IsNullOrWhiteSpace($treeRoot)) {
                $rootTrimmed = $root.TrimEnd([char]92, [char]47)
                if ($rootTrimmed.StartsWith($treeRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw 'inside working tree'
                }
            }
        }
        return $root
    }
    catch {
        throw $invalid
    }
}

function Invoke-SealedLiveMutationStageTarget {
    # Copies the NEW bytes into StagedPath with SafeTreeWalker (create-new),
    # requires swap-old MISSING and the immutable receipt preimage complete,
    # and verifies the staged tree hash against the candidate before PREPARED.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Target,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Receipt,
        [Parameter(Mandatory)] [string] $SourceRoot
    )

    $invalid = $script:LiveTransactionIntentMismatch
    $stagedPath = [string] $Target['StagedPath']
    $swapOldPath = [string] $Target['SwapOldPath']
    if (Test-Path -LiteralPath $swapOldPath) { throw $invalid }
    if ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $Receipt['ReceiptPath'])) -cne 'COMPLETE') {
        throw 'live-transaction-receipt-not-complete'
    }
    $candidate = [System.Collections.IDictionary] $Target['Candidate']
    if ($null -eq $stagedPath -or [string] $stagedPath -ceq '' -or [string] $candidate['State'] -ceq 'MISSING') {
        # A MISSING candidate (prune) stages nothing; PREPARED records the
        # empty tuple.
        return [ordered]@{ StagedState = [ordered]@{ State = 'MISSING' } }
    }
    if (Test-Path -LiteralPath $stagedPath) { throw $invalid }
    $candidateHash = [string] $candidate['Hash']
    if ($candidateHash -ceq '') { throw $invalid }
    $current = [System.Collections.IDictionary] $Target['Current']
    if ([string] $current['State'] -ceq 'PRESENT') {
        # Update/prune targets verify the immutable receipt snapshot preimage;
        # add targets have no preimage (rollback removes them outright).
        $snapshotTarget = Join-Path ([string] $Receipt['ReceiptPath']) (Join-Path 'snapshot' (([string] $Target['Platform']).ToLowerInvariant()))
        $snapshotTarget = Join-Path $snapshotTarget ([string] $Target['Name'])
        if ([string] (Get-SafeTreeSnapshot -Root $snapshotTarget).TreeHash -cne [string] $current['Hash']) {
            throw $script:LiveTransactionHashMismatch
        }
    }
    $parent = Split-Path -Parent $stagedPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $copy = Copy-SafeTree -SourceRoot $SourceRoot -DestinationRoot $stagedPath
    if ([string] $copy.DestinationTreeHash -cne $candidateHash) { throw $script:LiveTransactionHashMismatch }
    return [ordered]@{
        StagedState = [ordered]@{ State = 'PRESENT'; Type = 'Directory'; Hash = $candidateHash; Identity = [string] ((Get-TargetMetadataContext -Path $stagedPath).Ancestors[-1].Identity) }
    }
}

# ---------------------------------------------------------------------------
# Same-volume rename primitives with tuple verification
# ---------------------------------------------------------------------------

function Get-LiveTransactionObservedDirectory {
    param([Parameter(Mandatory)] [string] $Path, [string] $ExpectedHash = '')
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [ordered]@{ State = 'MISSING' }
    }
    $treeHash = (Get-SafeTreeSnapshot -Root $Path).TreeHash
    if ($ExpectedHash -ne '' -and $treeHash -cne $ExpectedHash) { throw $script:LiveTransactionHashMismatch }
    $identity = [string] ((Get-TargetMetadataContext -Path $Path).Ancestors[-1].Identity)
    return [ordered]@{ State = 'PRESENT'; Type = 'Directory'; Hash = $treeHash; Identity = $identity }
}

function Move-SealedLiveTargetToSwapOld {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Target)

    $targetPath = [string] $Target['TargetPath']
    $swapOldPath = [string] $Target['SwapOldPath']
    $current = [System.Collections.IDictionary] $Target['Current']
    if ([string] $current['State'] -ceq 'MISSING') {
        if (Test-Path -LiteralPath $targetPath) { throw $script:LiveTransactionHashMismatch }
        return [ordered]@{
            TargetState = [ordered]@{ State = 'MISSING' }
            SwapOldState = [ordered]@{ State = 'MISSING' }
        }
    }
    if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) { throw $script:LiveTransactionHashMismatch }
    if (Test-Path -LiteralPath $swapOldPath) { throw $script:LiveTransactionHashMismatch }
    $targetHash = [string] $current['Hash']
    $before = Get-LiveTransactionObservedDirectory -Path $targetPath -ExpectedHash $targetHash
    if ($before.State -cne 'PRESENT') { throw $script:LiveTransactionHashMismatch }
    $swapParent = Split-Path -Parent $swapOldPath
    if (-not (Test-Path -LiteralPath $swapParent -PathType Container)) { New-Item -ItemType Directory -Force -Path $swapParent | Out-Null }
    [System.IO.Directory]::Move($targetPath, $swapOldPath)
    $targetAfter = Get-LiveTransactionObservedDirectory -Path $targetPath -ExpectedHash ''
    if ($targetAfter.State -cne 'MISSING') { throw $script:LiveTransactionHashMismatch }
    $swapAfter = Get-LiveTransactionObservedDirectory -Path $swapOldPath -ExpectedHash $targetHash
    if ($swapAfter.State -cne 'PRESENT') { throw $script:LiveTransactionHashMismatch }
    return [ordered]@{
        TargetState = $targetAfter
        SwapOldState = $swapAfter
    }
}

function Move-SealedLiveTargetToInstalled {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Target)

    $targetPath = [string] $Target['TargetPath']
    $swapOldPath = [string] $Target['SwapOldPath']
    $stagedPath = [string] $Target['StagedPath']
    $candidate = [System.Collections.IDictionary] $Target['Candidate']
    if ([string] $candidate['State'] -ceq 'MISSING') {
        # Prune target: after OLD_MOVED the target is already missing; verify
        # and record the no-op install tuple.
        if (Test-Path -LiteralPath $targetPath) { throw $script:LiveTransactionHashMismatch }
        $swapState = Get-LiveTransactionObservedDirectory -Path $swapOldPath -ExpectedHash ([string] $Target['Current']['Hash'])
        return [ordered]@{
            TargetState = [ordered]@{ State = 'MISSING' }
            SwapOldState = $swapState
            StagedState = [ordered]@{ State = 'MISSING' }
        }
    }
    if (-not (Test-Path -LiteralPath $stagedPath -PathType Container)) { throw $script:LiveTransactionHashMismatch }
    if (Test-Path -LiteralPath $targetPath) { throw $script:LiveTransactionHashMismatch }
    $candidateHash = [string] $candidate['Hash']
    [System.IO.Directory]::Move($stagedPath, $targetPath)
    $targetAfter = Get-LiveTransactionObservedDirectory -Path $targetPath -ExpectedHash $candidateHash
    if ($targetAfter.State -cne 'PRESENT') { throw $script:LiveTransactionHashMismatch }
    $stagedAfter = Get-LiveTransactionObservedDirectory -Path $stagedPath -ExpectedHash ''
    if ($stagedAfter.State -cne 'MISSING') { throw $script:LiveTransactionHashMismatch }
    $swapAfter = Get-LiveTransactionObservedDirectory -Path $swapOldPath -ExpectedHash ([string] $Target['Current']['Hash'])
    return [ordered]@{
        TargetState = $targetAfter
        SwapOldState = $swapAfter
        StagedState = $stagedAfter
    }
}



# ---------------------------------------------------------------------------
# Generic authority state target (roadmap Task 4 step 5)
# ---------------------------------------------------------------------------

function Get-LiveTransactionStatePaths {
    # The canonical state locator under the control base: claims are immutable
    # create-new after first authority; the state file is replaced atomically.
    param(
        [Parameter(Mandatory)] [string] $ControlBase,
        [Parameter(Mandatory)] [string] $HomeAuthorityKey
    )

    $authorityDir = Join-Path (Join-Path ([System.IO.Path]::GetFullPath($ControlBase)) 'homes') $HomeAuthorityKey
    return [ordered]@{
        AuthorityDirectory = $authorityDir
        ClaimsPath = (Join-Path $authorityDir 'root-claims.json')
        StatePath = (Join-Path $authorityDir 'current-env.json')
    }
}

function Invoke-SealedLiveTransactionAuthorityState {
    # Processes the authority state target after live targets install: proves
    # or creates the immutable claims, derives and validates the complete
    # state postimage with the trusted serializer, journals the state file
    # records (recovery copy bound as the preimage), and installs the state
    # atomically (create-new rename for first authority, same-directory temp
    # replace for existing). Returns the postimage and binding hashes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TransactionDirectory,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Header,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Receipt,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $AuthorityStateIntent,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $TargetContextIntent,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $FinalCapabilityHashesByPlatform,
        [Parameter(Mandatory)] [string] $ControlBase,
        [Parameter(Mandatory)] [string] $StateRecoveryDirectory,
        [Parameter(Mandatory)] [ref] $ClaimsCreatedRef,
        [Parameter(Mandatory)] [ref] $StateInstalledRef
    )

    $paths = Get-LiveTransactionStatePaths -ControlBase $ControlBase -HomeAuthorityKey ([string] $Header['HomeAuthorityKey'])
    $claimsPath = [string] $paths['ClaimsPath']
    $statePath = [string] $paths['StatePath']
    $claimsExisted = Test-Path -LiteralPath $claimsPath -PathType Leaf

    if ($claimsExisted) {
        # Existing authority: prove the immutable claims are unchanged.
        $claimsBytes = [System.IO.File]::ReadAllBytes($claimsPath)
        $claimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($claimsBytes)).ToLowerInvariant()
        if ([string] $Header['RootClaimsHash'] -cne $claimsHash) { throw $script:LiveTransactionHashMismatch }
    }
    else {
        # First authority: create the proposed claims create-new from RESERVED.
        $proposedBytes = [byte[]] $AuthorityStateIntent['__ProposedRootClaimsBytes']
        if ($proposedBytes.Count -eq 0) { throw $script:LiveTransactionIntentMismatch }
        $claimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($proposedBytes)).ToLowerInvariant()
        if ([string] $Header['RootClaimsHash'] -cne $claimsHash) { throw $script:LiveTransactionHashMismatch }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $claimsPath) | Out-Null
        $stream = [System.IO.File]::Open($claimsPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($proposedBytes, 0, $proposedBytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'CLAIMS_PUBLISHED' -Data ([ordered]@{
            ClaimsHash = $claimsHash
        }) | Out-Null
        $ClaimsCreatedRef.Value = $true
    }

    # Derive the final identities from the installed live roots and the
    # reviewed TargetContextIntent, then build and validate the postimage.
    $finalIdentities = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @([object[]] $TargetContextIntent['Rows'])) {
        $platform = [string] $row['Platform']
        $resolvedPath = [string] $row['RequestedPath']
        $context = Get-TargetMetadataContext -Path $resolvedPath
        if ([string] $context.TargetStatus -cne 'EXISTS') { throw $script:LiveTransactionHashMismatch }
        $identity = [string] $context.Ancestors[-1].Identity
        $capabilityHash = [string] $FinalCapabilityHashesByPlatform[$platform]
        if ($capabilityHash -cnotmatch $script:LiveTransactionHashPattern) { throw $script:LiveTransactionIntentMismatch }
        $finalIdentities.Add([ordered]@{
            Platform = $platform
            LocationKey = [string] $row['LocationKey']
            ResolvedPath = $resolvedPath
            VolumeId = [string] $row['VolumeId']
            DirectoryIdentity = $identity
            FilesystemCapabilityHash = $capabilityHash
        })
    }
    $preStatePhaseHash = Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] ((Get-SealedLiveJournalChain -TransactionDirectory $TransactionDirectory).Records[-1]['Document']))
    $runtimeRefs = [ordered]@{
        JournalId = [string] $Header['TransactionId']
        PreStatePhaseHash = $preStatePhaseHash
        ReceiptId = [string] $Receipt['ReceiptId']
        ReceiptHash = [string] $Receipt['ReceiptHash']
    }
    $intentForPostimage = [ordered]@{}
    foreach ($key in @($AuthorityStateIntent.Keys)) {
        if ([string] $key -ceq '__ProposedRootClaimsBytes') { continue }
        $intentForPostimage[[string] $key] = $AuthorityStateIntent[$key]
    }
    $postimage = New-AuthorityStatePostimage -AuthorityStateIntent $intentForPostimage -TargetContextIntent $TargetContextIntent -FinalResolvedIdentities @($finalIdentities) -RuntimeRefs $runtimeRefs
    $stateBytes = ConvertTo-SemanticJsonBytes -InputObject $postimage
    $stateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stateBytes)).ToLowerInvariant()

    # Recovery copy of the old state as the preimage record.
    $stateExisted = Test-Path -LiteralPath $statePath -PathType Leaf
    if ($stateExisted) {
        New-Item -ItemType Directory -Force -Path $StateRecoveryDirectory | Out-Null
        $recoveryCopy = Join-Path $StateRecoveryDirectory 'current-env.preimage.json'
        $oldBytes = [System.IO.File]::ReadAllBytes($statePath)
        $stream = [System.IO.File]::Open($recoveryCopy, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($oldBytes, 0, $oldBytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        # The state target is a regular file; the containment walker is
        # directory-only, so the observed state binds Inspect identity.
        $oldObserved = [ordered]@{
            State = 'PRESENT'
            Type = 'File'
            Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($oldBytes)).ToLowerInvariant()
            Identity = [string] ([AiAgentDotfiles.NoFollowFile]::Inspect($statePath)).Identity
        }
    }
    else {
        $recoveryCopy = $null
        $oldObserved = [ordered]@{ State = 'MISSING' }
    }
    Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'FILE_PREPARED' -Data ([ordered]@{
        TargetKind = 'state'
        TargetPath = $statePath
        StagedPath = $recoveryCopy
        StagedState = $oldObserved
    }) | Out-Null

    Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'FILE_REPLACE_INTENT' -Data ([ordered]@{
        TargetKind = 'state'
        TargetPath = $statePath
        TargetState = $oldObserved
    }) | Out-Null

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statePath) | Out-Null
    $tempPath = Join-Path (Split-Path -Parent $statePath) ("current-env." + [Guid]::NewGuid().ToString('N') + ".tmp")
    $stream = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($stateBytes, 0, $stateBytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    if ($stateExisted) {
        [System.IO.File]::Move($tempPath, $statePath, $true)
    }
    else {
        [System.IO.File]::Move($tempPath, $statePath)
    }
    $StateInstalledRef.Value = $true
    $newObserved = [ordered]@{
        State = 'PRESENT'
        Type = 'File'
        Hash = $stateHash
        Identity = [string] ([AiAgentDotfiles.NoFollowFile]::Inspect($statePath)).Identity
    }
    Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'FILE_REPLACED' -Data ([ordered]@{
        TargetKind = 'state'
        TargetPath = $statePath
        TargetState = $newObserved
    }) | Out-Null
    Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'STATE_PUBLISHED' -Data ([ordered]@{
        StateHash = $stateHash
    }) | Out-Null

    return [ordered]@{
        StateHash = $stateHash
        ClaimsHash = $claimsHash
        ClaimsCreated = (-not $claimsExisted)
        Postimage = $postimage
    }
}

# ---------------------------------------------------------------------------
# Fixed record sequence engine (roadmap Task 4 steps 3-4, receipt-backed)
# ---------------------------------------------------------------------------

function Invoke-SealedLiveTransactionMutation {
    # Runs the receipt-backed fixed record sequence over pre-resolved targets:
    # RECEIPT_COMPLETE, parent-first no-overwrite directory creation with
    # captured identities, per-target staging/PREPARED, the destructive
    # recheck, the same-volume OLD/NEW rename ladder with disk tuple
    # verification, and the aggregate POSTCONDITIONS_OK record. A caught
    # failure before the state commit boundary restores completed targets in
    # reverse and rethrows; the journal keeps every durable record.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TransactionDirectory,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Header,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Receipt,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Targets,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $SourceRootsByPlatform,
        [AllowNull()] [System.Collections.IDictionary] $AuthorityStateIntent,
        [AllowNull()] [System.Collections.IDictionary] $TargetContextIntent,
        [AllowNull()] [System.Collections.IDictionary] $FinalCapabilityHashesByPlatform,
        [AllowNull()] [string] $ControlBase,
        [AllowNull()] [string] $StateRecoveryDirectory
    )

    $chain = Get-SealedLiveJournalChain -TransactionDirectory $TransactionDirectory
    if ($null -eq $chain.Header -or $chain.UnknownNames.Count -gt 0 -or $null -ne $chain.Result) {
        throw $script:LiveTransactionChainInvalid
    }
    if ([string] $chain.Header.TransactionId -cne [string] $Header.TransactionId) {
        throw $script:LiveTransactionIntentMismatch
    }
    if ([string] $Header['TransactionMode'] -cne 'receipt-backed') {
        # The state-only branch is a separate engine seam (Task 4 slice D).
        throw $script:LiveTransactionIntentMismatch
    }
    if ($null -eq $AuthorityStateIntent -or $null -eq $TargetContextIntent -or
        $null -eq $FinalCapabilityHashesByPlatform -or [string]::IsNullOrWhiteSpace($ControlBase) -or
        [string]::IsNullOrWhiteSpace($StateRecoveryDirectory)) {
        throw $script:LiveTransactionIntentMismatch
    }
    if ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $Receipt['ReceiptPath'])) -cne 'COMPLETE') {
        throw 'live-transaction-receipt-not-complete'
    }

    Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'RECEIPT_COMPLETE' -Data ([ordered]@{
        ReceiptRef = [ordered]@{
            Id = [string] $Receipt['ReceiptId']
            Path = [string] $Receipt['ReceiptPath']
            Hash = [string] $Receipt['ReceiptHash']
        }
    }) | Out-Null

    $completed = [System.Collections.Generic.List[object]]::new()
    $claimsCreatedRef = [ref] $false
    $stateInstalledRef = [ref] $false
    try {
        foreach ($target in @($Targets)) {
            $kind = [string] $target['TargetKind']
            if ($kind -ceq 'parent-directory') {
                $targetPath = [string] $target['TargetPath']
                $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'DIR_CREATE_INTENT' -Data ([ordered]@{
                    TargetId = [string] $target['TargetId']
                    TargetKind = $kind
                    TargetPath = $targetPath
                }) | Out-Null
                if (Test-Path -LiteralPath $targetPath) { throw $script:LiveTransactionHashMismatch }
                $null = New-Item -ItemType Directory -Path $targetPath -ErrorAction Stop
                $createdIdentity = [string] ((Get-TargetMetadataContext -Path $targetPath).Ancestors[-1].Identity)
                $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'DIR_CREATED' -Data ([ordered]@{
                    TargetId = [string] $target['TargetId']
                    TargetKind = $kind
                    TargetPath = $targetPath
                    CreatedIdentity = $createdIdentity
                }) | Out-Null
                $completed.Add([ordered]@{ TargetId = [string] $target['TargetId']; Phase = 'DIR_CREATED'; CreatedIdentity = $createdIdentity })
                continue
            }

            $platform = [string] $target['Platform']
            $targetSource = Join-Path ([string] $SourceRootsByPlatform[$platform]) ([string] $target['Name'])
            $staged = Invoke-SealedLiveMutationStageTarget -Target $target -Receipt $Receipt -SourceRoot $targetSource
            $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'PREPARED' -Data ([ordered]@{
                TargetId = [string] $target['TargetId']
                TargetKind = $kind
                TargetPath = [string] $target['TargetPath']
                StagedPath = [string] $target['StagedPath']
                StagedState = $staged['StagedState']
            }) | Out-Null

            # Destructive recheck: the live target must still match the
            # reviewed OLD state immediately before the swap.
            $current = [System.Collections.IDictionary] $target['Current']
            $observedCurrent = Get-LiveTransactionObservedDirectory -Path ([string] $target['TargetPath']) -ExpectedHash ([string] $current['Hash'])
            if ([string] $current['State'] -ceq 'PRESENT' -and $observedCurrent.State -cne 'PRESENT') {
                throw $script:LiveTransactionHashMismatch
            }
            if ([string] $current['State'] -ceq 'MISSING' -and $observedCurrent.State -cne 'MISSING') {
                throw $script:LiveTransactionHashMismatch
            }

            $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'MOVE_OLD_INTENT' -Data ([ordered]@{
                TargetId = [string] $target['TargetId']
                TargetKind = $kind
                TargetPath = [string] $target['TargetPath']
                SwapOldPath = [string] $target['SwapOldPath']
                TargetState = $observedCurrent
                SwapOldState = [ordered]@{ State = 'MISSING' }
            }) | Out-Null
            $movedOld = Move-SealedLiveTargetToSwapOld -Target $target
            $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'OLD_MOVED' -Data ([ordered]@{
                TargetId = [string] $target['TargetId']
                TargetKind = $kind
                TargetPath = [string] $target['TargetPath']
                SwapOldPath = [string] $target['SwapOldPath']
                TargetState = $movedOld['TargetState']
                SwapOldState = $movedOld['SwapOldState']
            }) | Out-Null
            $completed.Add([ordered]@{ TargetId = [string] $target['TargetId']; Phase = 'OLD_MOVED' })

            $stagedObserved = Get-LiveTransactionObservedDirectory -Path ([string] $target['StagedPath']) -ExpectedHash ([string] ([System.Collections.IDictionary] $target['Candidate'])['Hash'])
            $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'MOVE_NEW_INTENT' -Data ([ordered]@{
                TargetId = [string] $target['TargetId']
                TargetKind = $kind
                TargetPath = [string] $target['TargetPath']
                SwapOldPath = [string] $target['SwapOldPath']
                StagedPath = [string] $target['StagedPath']
                TargetState = $movedOld['TargetState']
                SwapOldState = $movedOld['SwapOldState']
                StagedState = $stagedObserved
            }) | Out-Null
            $installed = Move-SealedLiveTargetToInstalled -Target $target
            $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'NEW_INSTALLED' -Data ([ordered]@{
                TargetId = [string] $target['TargetId']
                TargetKind = $kind
                TargetPath = [string] $target['TargetPath']
                SwapOldPath = [string] $target['SwapOldPath']
                StagedPath = [string] $target['StagedPath']
                TargetState = $installed['TargetState']
                SwapOldState = $installed['SwapOldState']
                StagedState = $installed['StagedState']
            }) | Out-Null
            $completed.Add([ordered]@{ TargetId = [string] $target['TargetId']; Phase = 'NEW_INSTALLED' })
        }

        $stateOutcome = Invoke-SealedLiveTransactionAuthorityState -TransactionDirectory $TransactionDirectory -Header $Header -Receipt $Receipt -AuthorityStateIntent $AuthorityStateIntent -TargetContextIntent $TargetContextIntent -FinalCapabilityHashesByPlatform $FinalCapabilityHashesByPlatform -ControlBase $ControlBase -StateRecoveryDirectory $StateRecoveryDirectory -ClaimsCreatedRef $claimsCreatedRef -StateInstalledRef $stateInstalledRef

        $tuples = [System.Collections.Generic.List[object]]::new()
        foreach ($target in @($Targets)) {
            $tuples.Add([ordered]@{
                TargetId = [string] $target['TargetId']
                Final = (Get-LiveTransactionObservedDirectory -Path ([string] $target['TargetPath']) -ExpectedHash ([string] ([System.Collections.IDictionary] $target['Candidate'])['Hash']))
            })
        }
        $postconditionsData = [ordered]@{
            PostconditionsHash = (Get-SemanticJsonHash -InputObject @($tuples))
        }
        if ($null -ne $stateOutcome) { $postconditionsData['StateHash'] = [string] $stateOutcome['StateHash'] }
        $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'POSTCONDITIONS_OK' -Data $postconditionsData | Out-Null
        $headHash = Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] ((Get-SealedLiveJournalChain -TransactionDirectory $TransactionDirectory).Records[-1]['Document']))
        $committedResult = [ordered]@{
            SchemaVersion = 1
            ArtifactKind = 'live-operation-result'
            ResultScope = 'transaction'
            TransactionId = [string] $Header['TransactionId']
            OperationKind = [string] $Header['OperationKind']
            OriginalDocumentHash = [string] $Header['OriginalDocumentHash']
            ResultBaseHeadHash = $headHash
            Outcome = 'committed'
            ReceiptRef = [ordered]@{
                Id = [string] $Receipt['ReceiptId']
                Path = [string] $Receipt['ReceiptPath']
                State = 'COMPLETE'
                Hash = [string] $Receipt['ReceiptHash']
            }
            ReceiptHash = [string] $Receipt['ReceiptHash']
            StateHash = [string] $stateOutcome['StateHash']
        }
        $null = Publish-SealedLiveTransactionResult -TransactionDirectory $TransactionDirectory -Document $committedResult
        $resultFileHash = (Get-FileHash -LiteralPath (Join-Path ([System.IO.Path]::GetFullPath($TransactionDirectory)) 'result.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'COMPLETE' -Data ([ordered]@{
            ResultHash = $resultFileHash
            OriginalDocumentHash = [string] $Header['OriginalDocumentHash']
            Outcome = 'committed'
            ClosingKind = 'original'
            ClosingDocumentHash = [string] $Header['OriginalDocumentHash']
        }) | Out-Null
        return [pscustomobject][ordered]@{
            Completed = @($completed)
            PostconditionsHash = [string] $postconditionsData['PostconditionsHash']
            StateHash = [string] $stateOutcome['StateHash']
            ResultHash = $resultFileHash
        }
    }
    catch {
        # Failure classification: before the state commit boundary a caught
        # failure restores completed live/claims targets in reverse; verified
        # full restoration publishes the failed-restored fixed result and the
        # terminal record, then exits non-zero. Once the reviewed state
        # postimage is installed, live/state are never rewritten — evidence is
        # retained for reviewed finalize and the transaction stays unfinished.
        if ($stateInstalledRef.Value) {
            # The reviewed state postimage is installed; live/state are never
            # rewritten after the commit boundary — evidence is retained for
            # reviewed finalize and the transaction stays unfinished.
            throw 'live-transaction-recovery-required'
        }
        $statePaths = Get-LiveTransactionStatePaths -ControlBase $ControlBase -HomeAuthorityKey ([string] $Header['HomeAuthorityKey'])
        $claimsCreated = $claimsCreatedRef.Value
        $null = Restore-SealedLiveMutationTargets -Targets $Targets -Completed @($completed)
        if ($claimsCreated) {
            $claimsPath = [string] $statePaths['ClaimsPath']
            $claimsContext = Get-TargetMetadataContext -Path $claimsPath
            if ([string] $claimsContext.TargetStatus -ceq 'EXISTS') {
                $claimsIdentity = [string] $claimsContext.Ancestors[-1].Identity
                $claimsInfo = [AiAgentDotfiles.NoFollowFile]::Inspect($claimsPath)
                if ($claimsIdentity -cne [string] $claimsInfo.Identity) { throw $script:LiveTransactionHashMismatch }
                $claimsChildren = @(Get-ChildItem -LiteralPath $claimsPath -Force)
                if ($claimsChildren.Count -ne 0) { throw $script:LiveTransactionHashMismatch }
                Remove-Item -LiteralPath $claimsPath -Force
            }
        }
        $restorationVerified = $true
        $restorationRows = [System.Collections.Generic.List[object]]::new()
        foreach ($target in @($Targets)) {
            $current = [System.Collections.IDictionary] $target['Current']
            $observed = Get-LiveTransactionObservedDirectory -Path ([string] $target['TargetPath']) -ExpectedHash ([string] $current['Hash'])
            if ([string] $current['State'] -ceq 'PRESENT' -and $observed.State -cne 'PRESENT') { $restorationVerified = $false }
            if ([string] $current['State'] -ceq 'MISSING' -and $observed.State -cne 'MISSING') { $restorationVerified = $false }
            $restorationRows.Add([ordered]@{ TargetId = [string] $target['TargetId']; Restored = $observed })
        }
        if (-not $restorationVerified) {
            throw 'live-transaction-recovery-required'
        }
        $restorationHash = Get-SemanticJsonHash -InputObject @($restorationRows)
        $oldStateHash = $null
        $oldStatePath = [string] $statePaths['StatePath']
        if (Test-Path -LiteralPath $oldStatePath -PathType Leaf) {
            $oldStateBytes = [System.IO.File]::ReadAllBytes($oldStatePath)
            $oldStateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($oldStateBytes)).ToLowerInvariant()
        }
        $headHash = Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] ((Get-SealedLiveJournalChain -TransactionDirectory $TransactionDirectory).Records[-1]['Document']))
        $failedResult = [ordered]@{
            SchemaVersion = 1
            ArtifactKind = 'live-operation-result'
            ResultScope = 'transaction'
            TransactionId = [string] $Header['TransactionId']
            OperationKind = [string] $Header['OperationKind']
            OriginalDocumentHash = [string] $Header['OriginalDocumentHash']
            ResultBaseHeadHash = $headHash
            Outcome = 'failed-restored'
            RestorationHash = $restorationHash
        }
        if ($null -ne $oldStateHash) { $failedResult['StateHash'] = $oldStateHash }
        $null = Publish-SealedLiveTransactionResult -TransactionDirectory $TransactionDirectory -Document $failedResult
        $resultFileHash = (Get-FileHash -LiteralPath (Join-Path ([System.IO.Path]::GetFullPath($TransactionDirectory)) 'result.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        $null = Add-SealedLiveJournalRecord -TransactionDirectory $TransactionDirectory -Phase 'COMPLETE' -Data ([ordered]@{
            ResultHash = $resultFileHash
            OriginalDocumentHash = [string] $Header['OriginalDocumentHash']
            Outcome = 'failed-restored'
            ClosingKind = 'original'
            ClosingDocumentHash = [string] $Header['OriginalDocumentHash']
        }) | Out-Null
        $wrapped = [System.InvalidOperationException]::new('apply-failed-but-restored')
        $wrapped.Data['OriginalFailure'] = [string] $_.Exception.Message
        $wrapped.Data['OriginalFailureLine'] = [int] $_.InvocationInfo.ScriptLineNumber
        throw $wrapped
    }
}

# ---------------------------------------------------------------------------
# Reverse restoration (pre-commit-boundary failure path)
# ---------------------------------------------------------------------------

function Restore-SealedLiveMutationTargets {
    # Restores completed targets in reverse order: installed-new targets move
    # back to staged, moved-old targets move back from swap-old; created
    # parent directories are removed child-first only while the captured
    # identity is unchanged and the directory is empty. Drift stops the
    # restoration and surfaces for manual recovery.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Targets,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Completed
    )

    $restored = [System.Collections.Generic.List[string]]::new()
    for ($index = $Completed.Count - 1; $index -ge 0; $index--) {
        $entry = [System.Collections.IDictionary] $Completed[$index]
        $targetId = [string] $entry['TargetId']
        $target = $null
        foreach ($candidate in @($Targets)) {
            if ([string] $candidate['TargetId'] -ceq $targetId) { $target = $candidate; break }
        }
        if ($null -eq $target) { throw $script:LiveTransactionIntentMismatch }
        $phase = [string] $entry['Phase']
        $targetPath = [string] $target['TargetPath']
        $stagedPath = [string] $target['StagedPath']
        $swapOldPath = [string] $target['SwapOldPath']
        if ($phase -ceq 'NEW_INSTALLED') {
            $candidate = [System.Collections.IDictionary] $target['Candidate']
            if ([string] $candidate['State'] -ceq 'MISSING') {
                if (Test-Path -LiteralPath $targetPath) { throw $script:LiveTransactionHashMismatch }
            }
            elseif (Test-Path -LiteralPath $targetPath -PathType Container) {
                [System.IO.Directory]::Move($targetPath, $stagedPath)
                if (Test-Path -LiteralPath $targetPath) { throw $script:LiveTransactionHashMismatch }
            }
            $restored.Add("$targetId/NEW_INSTALLED")
        }
        elseif ($phase -ceq 'OLD_MOVED') {
            $current = [System.Collections.IDictionary] $target['Current']
            if ([string] $current['State'] -ceq 'PRESENT') {
                if (-not (Test-Path -LiteralPath $swapOldPath -PathType Container)) { throw $script:LiveTransactionHashMismatch }
                if (Test-Path -LiteralPath $targetPath) { throw $script:LiveTransactionHashMismatch }
                [System.IO.Directory]::Move($swapOldPath, $targetPath)
            }
            $restored.Add("$targetId/OLD_MOVED")
        }
        elseif ($phase -ceq 'DIR_CREATED') {
            $context = Get-TargetMetadataContext -Path $targetPath
            if ([string] $context.TargetStatus -ceq 'EXISTS') {
                $identity = [string] $context.Ancestors[-1].Identity
                if ($identity -cne [string] $entry['CreatedIdentity']) { throw $script:LiveTransactionHashMismatch }
                $children = @(Get-ChildItem -LiteralPath $targetPath -Force)
                if ($children.Count -ne 0) { throw $script:LiveTransactionHashMismatch }
                Remove-Item -LiteralPath $targetPath -Force
            }
            $restored.Add("$targetId/DIR_CREATED")
        }
    }
    return @($restored)
}

# ---------------------------------------------------------------------------
# Journal publication (mirrors the canonical held-chain mechanics)
# ---------------------------------------------------------------------------

function New-SealedLiveJournalHeader {
    # Creates the transaction namespace create-new with its _pending child and
    # publishes the schema-valid header as header.json (pending temp, flush,
    # atomic rename); the new namespace inventory is exactly _pending/header.json.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $TransactionDirectory
    )

    Test-LiveJournalHeaderSemantics -Document $Document
    $directory = [System.IO.Path]::GetFullPath($TransactionDirectory)
    $parent = Split-Path -Parent $directory
    $namespaceHandles = $null
    $pendingHandle = $null
    $publication = $null
    try {
        $namespaceHandles = Open-CanonicalDirectoryContainmentChain -Path $parent -CreateMissing
        try {
            $namespaceHandle = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($namespaceHandles[$namespaceHandles.Count - 1], [System.IO.Path]::GetFileName($directory))
        }
        catch {
            throw $script:LiveTransactionAlreadyTerminal
        }
        $namespaceHandles.Add($namespaceHandle)
        $pendingHandle = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($namespaceHandle, '_pending')
        $publication = Publish-CanonicalHeldJson -Document $Document -FinalParent $namespaceHandle -FinalPath (Join-Path $directory 'header.json') -PendingParent $pendingHandle -PendingPath (Join-Path $directory '_pending') -PendingName ("header-{0}.tmp" -f [Guid]::NewGuid().ToString('N')) -SchemaPath (Join-Path $script:LiveTransactionSchemaRoot 'live-journal-header.schema.json')
        $names = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($namespaceHandle) | Sort-Object)
        if (($names -join "`0") -cne "_pending`0header.json") { throw $script:LiveTransactionPublishFailed }
        return $publication
    }
    finally {
        if ($publication -and $publication.HeldHandle) { $publication.HeldHandle.Dispose() }
        if ($pendingHandle) { $pendingHandle.Dispose() }
        if ($namespaceHandles) { Close-SafeDirectoryContainmentChain -Handles $namespaceHandles }
    }
}

function Get-SealedLiveJournalChain {
    # Zero-write enumeration of the transaction namespace: header, numbered
    # published records, the zero-or-one result.json, and unknown entries.
    param([Parameter(Mandatory)] [string] $TransactionDirectory)

    $directory = [System.IO.Path]::GetFullPath($TransactionDirectory)
    $names = @(Get-ChildItem -LiteralPath $directory -Force | ForEach-Object Name)
    $header = $null
    $records = [System.Collections.Generic.List[object]]::new()
    $result = $null
    $resultFileHash = $null
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($name in ($names | Sort-Object)) {
        if ($name -ceq 'header.json') {
            $header = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path $directory 'header.json'), [System.Text.UTF8Encoding]::new($false, $true)))
            continue
        }
        if ($name -ceq 'result.json') {
            $result = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path $directory 'result.json'), [System.Text.UTF8Encoding]::new($false, $true)))
            $resultFileHash = (Get-FileHash -LiteralPath (Join-Path $directory 'result.json') -Algorithm SHA256).Hash.ToLowerInvariant()
            continue
        }
        if ($name -ceq '_pending') { continue }
        if ($name -cmatch '^([0-9]{6})\.json$') {
            $records.Add([ordered]@{
                Sequence = [long] $Matches[1]
                Document = (ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path $directory $name), [System.Text.UTF8Encoding]::new($false, $true))))
                Name = $name
            })
            continue
        }
        $unknown.Add($name)
    }
    return [pscustomobject][ordered]@{
        Directory = $directory
        Header = $header
        Records = @($records)
        Result = $result
        ResultFileHash = $resultFileHash
        UnknownNames = @($unknown)
    }
}

function Test-SealedLiveJournalChain {
    # Chain validation: dense sequences from 1, hash links, header binding,
    # per-record phase semantics, recovery intents preceding recovery records,
    # zero-or-one result bound to a valid ancestor head, and the terminal
    # COMPLETE record last with the strict closing oneOf. The result file hash
    # binds the terminal record to the exact published result bytes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Header,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Records,
        [AllowNull()] [System.Collections.IDictionary] $Result,
        [AllowNull()] [string] $ResultFileHash
    )

    $invalid = $script:LiveTransactionChainInvalid
    if ([string] $Header.TransactionId -cne [string] $Header.TransactionId) { throw $invalid }
    foreach ($record in @($Records)) {
        if ([string] ([System.Collections.IDictionary] $record['Document'])['TransactionId'] -cne [string] $Header.TransactionId) { throw $invalid }
    }
    for ($index = 0; $index -lt @($Records).Count; $index++) {
        $entry = [System.Collections.IDictionary] $Records[$index]
        if ([long] $entry['Sequence'] -ne [long] ($index + 1)) { throw $invalid }
        $document = [System.Collections.IDictionary] $entry['Document']
        Test-LiveJournalRecordSemantics -Document $document
        $expectedPrevious = if ($index -eq 0) { Get-SealedLiveJournalHeaderHash -Header $Header } else {
            Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] $Records[$index - 1]['Document'])
        }
        if ([string] $document['PreviousHash'] -cne $expectedPrevious) { throw $invalid }
        if ([string] $document['Phase'] -ceq 'RECOVERY_ACTION_INTENT') { continue }
        if ([string] $document['Phase'] -ceq 'RECOVERY_ACTION_APPLIED') {
            $intents = @(@($Records) | Where-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'RECOVERY_ACTION_INTENT' })
            if ($intents.Count -eq 0) { throw $invalid }
        }
    }
    $terminalEntries = @(@($Records) | Where-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'COMPLETE' })
    if ($terminalEntries.Count -gt 1) { throw $invalid }
    if ($terminalEntries.Count -eq 1) {
        $terminalIndex = [long] ([System.Collections.IDictionary] $terminalEntries[0])['Sequence'] - 1
        if ($terminalIndex -ne @($Records).Count - 1) { throw $invalid }
        if ($null -eq $Result) { throw $invalid }
        if ([string] ([System.Collections.IDictionary] $terminalEntries[0]['Document'])['Data']['ResultHash'] -cne [string] $ResultFileHash) { throw $invalid }
    }
    if ($null -ne $Result) {
        if (@($Records).Count -eq 0) { throw $invalid }
        $heads = @(@($Records) | ForEach-Object { Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] $_['Document']) })
        if ([string] $Result['ResultBaseHeadHash'] -cnotin $heads) { throw $invalid }
        if ([string] $Result['TransactionId'] -cne [string] $Header.TransactionId -or
            [string] $Result['OriginalDocumentHash'] -cne [string] $Header.OriginalDocumentHash) { throw $invalid }
        Test-LiveOperationResultSemantics -Document $Result
    }
}

function Get-SealedLiveJournalHeaderHash {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Header)
    return Get-SemanticJsonHash -InputObject $Header
}

function Add-SealedLiveJournalRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TransactionDirectory,
        [Parameter(Mandatory)] [ValidateSet(
            'DIR_CREATE_INTENT', 'DIR_CREATED', 'RECEIPT_COMPLETE', 'PREPARED',
            'MOVE_OLD_INTENT', 'OLD_MOVED', 'MOVE_NEW_INTENT', 'NEW_INSTALLED',
            'CLAIMS_PUBLISHED', 'STATE_PREIMAGE_COMPLETE', 'FILE_PREPARED',
            'FILE_REPLACE_INTENT', 'FILE_REPLACED', 'STATE_PUBLISHED',
            'POSTCONDITIONS_OK', 'RECOVERY_ACTION_INTENT', 'RECOVERY_ACTION_APPLIED', 'COMPLETE'
        )] [string] $Phase,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Data
    )

    $chain = Get-SealedLiveJournalChain -TransactionDirectory $TransactionDirectory
    if ($null -eq $chain.Header) { throw $script:LiveTransactionChainInvalid }
    if ($chain.UnknownNames.Count -gt 0) { throw $script:LiveTransactionChainInvalid }
    $terminalPresent = @(@($chain.Records) | Where-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'COMPLETE' }).Count -gt 0
    if ($terminalPresent) { throw $script:LiveTransactionAlreadyTerminal }
    # The closing COMPLETE record is the only artifact that may follow the
    # published fixed result (result bytes first, terminal record last).
    if ($null -ne $chain.Result -and $Phase -cne 'COMPLETE') { throw $script:LiveTransactionAlreadyTerminal }
    $sequence = [long] (@($chain.Records).Count + 1)
    $record = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-journal-record'
        TransactionId = [string] $chain.Header.TransactionId
        Sequence = $sequence
        PreviousHash = if (@($chain.Records).Count -eq 0) { Get-SealedLiveJournalHeaderHash -Header $chain.Header } else {
            Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] $chain.Records[-1]['Document'])
        }
        Phase = $Phase
        Data = $Data
    }
    Test-LiveJournalRecordSemantics -Document $record
    $candidateRecords = @(@($chain.Records) + @([ordered]@{ Sequence = $sequence; Document = $record; Name = ('{0:d6}.json' -f $sequence) }))
    $null = Test-SealedLiveJournalChain -Header $chain.Header -Records $candidateRecords -Result $chain.Result -ResultFileHash $chain.ResultFileHash

    $handles = Open-CanonicalDirectoryContainmentChain -Path ([System.IO.Path]::GetFullPath($TransactionDirectory))
    $pendingHandle = [AiAgentDotfiles.NoFollowFile]::TryHoldChildDirectory($handles[$handles.Count - 1], '_pending')
    if ($null -eq $pendingHandle) { throw $script:LiveTransactionChainInvalid }
    try {
        $publication = Publish-CanonicalHeldJson -Document $record -FinalParent $handles[$handles.Count - 1] -FinalPath (Join-Path $TransactionDirectory ('{0:d6}.json' -f $sequence)) -PendingParent $pendingHandle -PendingPath (Join-Path $TransactionDirectory '_pending') -PendingName ("record-{0:d6}-{1}.tmp" -f $sequence, [Guid]::NewGuid().ToString('N')) -SchemaPath (Join-Path $script:LiveTransactionSchemaRoot 'live-journal-record.schema.json')
        # The record bytes are durably published; release the held handle so the
        # next chain read does not collide with it.
        $publication.HeldHandle.Dispose()
        return [pscustomobject][ordered]@{
            Path = [string] $publication.Path
            Hash = [string] $publication.Hash
        }
    }
    finally {
        $pendingHandle.Dispose()
        Close-SafeDirectoryContainmentChain -Handles $handles
    }
}

function Publish-SealedLiveTransactionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TransactionDirectory,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document
    )

    Test-LiveOperationResultSemantics -Document $Document
    $chain = Get-SealedLiveJournalChain -TransactionDirectory $TransactionDirectory
    if ($null -eq $chain.Header) { throw $script:LiveTransactionChainInvalid }
    if ($chain.UnknownNames.Count -gt 0) { throw $script:LiveTransactionChainInvalid }
    if ($null -ne $chain.Result) { throw $script:LiveTransactionResultExists }
    if (@($chain.Records).Count -eq 0) { throw $script:LiveTransactionChainInvalid }
    $null = Test-SealedLiveJournalChain -Header $chain.Header -Records $chain.Records -Result $Document -ResultFileHash $chain.ResultFileHash
    $heads = @(@($chain.Records) | ForEach-Object { Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] $_['Document']) })
    if ([string] $Document['ResultBaseHeadHash'] -cnotin $heads) { throw $script:LiveTransactionChainInvalid }

    $handles = Open-CanonicalDirectoryContainmentChain -Path ([System.IO.Path]::GetFullPath($TransactionDirectory))
    $pendingHandle = [AiAgentDotfiles.NoFollowFile]::TryHoldChildDirectory($handles[$handles.Count - 1], '_pending')
    if ($null -eq $pendingHandle) { throw $script:LiveTransactionChainInvalid }
    try {
        $publication = Publish-CanonicalHeldJson -Document $Document -FinalParent $handles[$handles.Count - 1] -FinalPath (Join-Path $TransactionDirectory 'result.json') -PendingParent $pendingHandle -PendingPath (Join-Path $TransactionDirectory '_pending') -PendingName ("result-{0}.tmp" -f [Guid]::NewGuid().ToString('N')) -SchemaPath (Join-Path $script:LiveTransactionSchemaRoot 'live-operation-result.schema.json')
        $publication.HeldHandle.Dispose()
        return [pscustomobject][ordered]@{
            Path = [string] $publication.Path
            Hash = [string] $publication.Hash
        }
    }
    finally {
        $pendingHandle.Dispose()
        Close-SafeDirectoryContainmentChain -Handles $handles
    }
}
