#requires -Version 7.0
<#
.SYNOPSIS
    Reviewed environment rollback entry: select one complete environment
    activation receipt and derive a reviewed rollback plan from it.

.DESCRIPTION
    Only -ReceiptPath selects a rollback. The legacy RunId/BackupPath selection
    and the legacy whole-tree rollback implementation are removed; a plan is
    derived by -DryRun and applied by -Apply with the same reviewed plan file.

    Resolution order is final: the sandbox-injected authority (the same surface
    sync and live recovery use) with its complete bootstrap prefix, then the
    external-artifact preflight for the receipt path, then the receipt slot
    state and its source operation kind, then the external-artifact preflight
    for the plan and report paths, and then — under the origin canonical ->
    worktree overlay -> global lock order — the Task 7 Step 1 source-graph
    evidence (receipt integrity, backup snapshot trees, authority preimages,
    the linked source transaction's committed chain and receipt binding) and
    the current state/claims/overlay/live surface, plus the origin identity
    overlay-lock identity, the source transaction probe and every binding
    revalidated under the locks. DryRun derives the schema-1
    environment-rollback plan and publishes it create-new only after the
    registered rollback-plan schema and the reviewed semantics accept its
    exact bytes; Apply validates the reviewed plan (schema and semantics) and
    then runs it as a new receipt-backed transaction. Every disagreement
    fails closed with its reviewed token. A source transaction that held the
    worktree overlay lock is rollback-able only from that exact worktree
    identity.
#>
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter(Mandatory, ParameterSetName = 'DryRun')]
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [string] $ReceiptPath,
    [Parameter(Mandatory, ParameterSetName = 'DryRun')] [switch] $DryRun,
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [switch] $Apply,
    [Parameter(Mandatory, ParameterSetName = 'DryRun')]
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [string] $PlanPath,
    [Parameter(ParameterSetName = 'DryRun')]
    [Parameter(ParameterSetName = 'Apply')] [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(ParameterSetName = 'DryRun')]
    [Parameter(ParameterSetName = 'Apply')] [string] $JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'home-authority-common.ps1')
. (Join-Path $PSScriptRoot 'live-plan-common.ps1')
. (Join-Path $PSScriptRoot 'live-plan-evidence-common.ps1')
. (Join-Path $PSScriptRoot 'target-context-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'backup-receipt-common.ps1')
. (Join-Path $PSScriptRoot 'live-transaction-common.ps1')

$script:RollbackHostResolutionRequired = 'live-plan-host-resolution-required'
$script:RollbackAuthorityMissing = 'live-plan-authority-missing'
$script:RollbackReceiptMissing = 'rollback-receipt-missing'
$script:RollbackReceiptIncomplete = 'rollback-receipt-not-complete'
$script:RollbackReceiptTampered = 'rollback-receipt-tampered'
$script:RollbackSourceKindUnsupported = 'rollback-source-kind-unsupported'
$script:RollbackHomeAuthorityMismatch = 'rollback-home-authority-mismatch'
$script:RollbackOriginMismatch = 'rollback-origin-mismatch'
$script:RollbackBackupDrift = 'rollback-backup-drift'
$script:RollbackPreimageMissing = 'rollback-preimage-missing'
$script:RollbackPreimageTampered = 'rollback-preimage-tampered'
$script:RollbackClaimsDrift = 'rollback-claims-drift'
$script:RollbackSourceTransactionMissing = 'rollback-source-transaction-missing'
$script:RollbackSourceTransactionTampered = 'rollback-source-transaction-tampered'
$script:RollbackSourceTransactionUnfinished = 'rollback-source-transaction-unfinished'
$script:RollbackSourceOutcomeUnsupported = 'rollback-source-outcome-unsupported'
$script:RollbackSourceReceiptMismatch = 'rollback-source-receipt-mismatch'
$script:RollbackStateDrift = 'rollback-state-drift'
$script:RollbackOverlayDrift = 'rollback-overlay-drift'
$script:RollbackLiveRootDrift = 'rollback-live-root-drift'
$script:RollbackPlanMissing = 'rollback-plan-missing'
$script:RollbackPlanMismatch = 'rollback-plan-mismatch'
$script:RollbackPlanPathCollision = 'live-recovery-plan-path-collision'

function Resolve-RollbackInternalRoots {
    # Thin wrapper: the shared production resolver owns sandbox-vs-identity
    # selection; this producer only pins its failure token.
    [CmdletBinding()]
    param()

    return (Resolve-LiveSafetyHostAuthority -FailureToken $script:RollbackHostResolutionRequired)
}

function New-RollbackAuthorityContext {
    # The derived home-authority context must land exactly on the injected
    # control and backup locators, exactly like sync and live recovery.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $ControlBase,
        [Parameter(Mandatory)] [string] $BackupRoot
    )

    $identity = [pscustomobject][ordered]@{
        ResolverVersion = $script:HomeAuthorityResolverVersion
        TokenSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ProfileRoot = $HomeRoot
        RoamingAppDataRoot = (Join-Path $HomeRoot 'AppData\Roaming')
        LocalAppDataRoot = (Join-Path $HomeRoot 'AppData\Local')
    }
    foreach ($folder in @([string] $identity.RoamingAppDataRoot, [string] $identity.LocalAppDataRoot)) {
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    }
    $context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity -ForbiddenRoots @($ControlBase, $BackupRoot)
    if ([System.IO.Path]::GetFullPath([string] $context.ControlBase) -cne [System.IO.Path]::GetFullPath($ControlBase) -or
        [System.IO.Path]::GetFullPath([string] $context.BackupRoot) -cne [System.IO.Path]::GetFullPath($BackupRoot)) {
        throw $script:RollbackHostResolutionRequired
    }
    return $context
}

function Assert-RollbackAuthorityComplete {
    # Rollback never bootstraps the authority prefix; an incomplete prefix
    # fails closed before anything under the control base is interpreted.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $AuthorityContext)

    $complete = $false
    try {
        $status = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $AuthorityContext
        $complete = ([string] $status.Status -ceq 'COMPLETE' -and [long] $status.CompletePrefixLength -eq 7)
    }
    catch {
        if ([string] $_.Exception.Message -ceq 'operation-lock-busy') { throw }
        $complete = $false
    }
    if (-not $complete) { throw $script:RollbackAuthorityMissing }
}

function Test-RollbackReceiptPathEqual {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Left, [Parameter(Mandatory)] [string] $Right)
    return [System.IO.Path]::GetFullPath($Left).Equals([System.IO.Path]::GetFullPath($Right), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RollbackSourceEvidence {
    # Task 7 Step 1: fail-closed evidence for the selected source graph. The
    # receipt document, its complete marker, its managed snapshot trees, and
    # its authority preimages must be exactly the reviewed producer's bytes,
    # and the linked source transaction must be a finished, untampered,
    # committed environment transaction that binds this exact receipt and the
    # reviewed source plan. Every disagreement throws its own reviewed token;
    # the returned evidence carries the parsed preimage and terminal state
    # for the current-surface eligibility comparison.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ReceiptDocument,
        [Parameter(Mandatory)] [string] $ReceiptPath,
        [Parameter(Mandatory)] $AuthorityContext
    )

    foreach ($field in @(
        'SchemaVersion', 'ArtifactKind', 'SourceTransactionId', 'ReceiptId', 'ReceiptPath',
        'SourceOperationKind', 'PlanHash', 'DocumentHash', 'ExecutionContextHash',
        'ControlBaseHash', 'FilesystemCapabilityHash', 'HomeAuthorityKey', 'ReceiptIntent',
        'ReceiptHash', 'ManagedSnapshots', 'UnknownMarkers', 'SystemMarker',
        'AuthorityStatePreimage', 'RootClaimsPreimage', 'CreatedAtUtc'
    )) {
        if (-not $ReceiptDocument.Contains($field)) {
            throw ($script:RollbackReceiptIncomplete + ' (missing ' + $field + ')')
        }
    }
    try { Test-BackupReceiptSemantics -Document $ReceiptDocument }
    catch { throw ($script:RollbackReceiptTampered + ' (receipt document)') }
    if (-not (Test-RollbackReceiptPathEqual -Left ([string] $ReceiptDocument['ReceiptPath']) -Right $ReceiptPath)) {
        throw ($script:RollbackReceiptTampered + ' (receipt path)')
    }

    $markerCapture = Read-CanonicalHeldRegularFileCapture -Path (Join-Path $ReceiptPath '_meta/COMPLETE')
    $markerText = [System.Text.UTF8Encoding]::new($false, $true).GetString([byte[]] $markerCapture.Bytes)
    if ($markerText -cne [string] $ReceiptDocument['ReceiptHash']) {
        throw ($script:RollbackReceiptTampered + ' (complete marker)')
    }

    if ([string] $ReceiptDocument['HomeAuthorityKey'] -cne [string] $AuthorityContext.HomeAuthorityKey) {
        throw ($script:RollbackHomeAuthorityMismatch + ' (receipt=' + [string] $ReceiptDocument['HomeAuthorityKey'] + ')')
    }

    # The backup snapshots are the restore source: every recorded tree hash
    # must still reproduce from the exact snapshot bytes under the receipt.
    foreach ($row in @([object[]] $ReceiptDocument['ManagedSnapshots'])) {
        $platform = [string] $row['Platform']
        $platformDir = Join-Path (Join-Path $ReceiptPath 'snapshot') $platform.ToLowerInvariant()
        $rootSnapshot = Get-SafeTreeSnapshot -Root $platformDir
        if ([string] $rootSnapshot.TreeHash -cne [string] $row['RootHash']) {
            throw ($script:RollbackBackupDrift + ' (' + $platform + ' snapshot root)')
        }
        foreach ($target in @([object[]] $row['Targets'])) {
            $targetDir = Join-Path $platformDir ([string] $target['Name'])
            if ([string] $target['Status'] -ceq 'COPIED') {
                $targetSnapshot = Get-SafeTreeSnapshot -Root $targetDir
                if ([string] $targetSnapshot.TreeHash -cne [string] $target['SnapshotTreeHash']) {
                    throw ($script:RollbackBackupDrift + ' (' + $platform + '/' + [string] $target['Name'] + ')')
                }
            }
            elseif (Test-Path -LiteralPath $targetDir) {
                throw ($script:RollbackBackupDrift + ' (' + $platform + '/' + [string] $target['Name'] + ' present)')
            }
        }
    }

    # The preimages are the rollback destination: both copies must exist with
    # exactly the recorded bytes.
    $preimageBytes = @{}
    foreach ($entry in @(
        @{ Name = 'AuthorityStatePreimage'; Leaf = 'current-env.json' },
        @{ Name = 'RootClaimsPreimage'; Leaf = 'root-claims.json' }
    )) {
        $record = $ReceiptDocument[$entry.Name]
        if ([string] $record['Status'] -cne 'COPIED') {
            throw ($script:RollbackPreimageMissing + ' (' + $entry.Name + ')')
        }
        $copyPath = Join-Path (Join-Path $ReceiptPath 'authority-preimage') $entry.Leaf
        $capture = Read-CanonicalHeldRegularFileCapture -Path $copyPath
        if ([string] $capture.Sha256 -cne [string] $record['Hash'] -or [long] $capture.Length -ne [long] $record['Length']) {
            throw ($script:RollbackPreimageTampered + ' (' + $entry.Name + ')')
        }
        $preimageBytes[$entry.Name] = [byte[]] $capture.Bytes
    }

    # Root claims are immutable: the current bytes must still be the exact
    # preimage the receipt captured.
    $claimsCapture = Read-CanonicalHeldRegularFileCapture -Path ([string] $AuthorityContext.RootClaimsPath) -AllowMissing
    if ($null -eq $claimsCapture -or [string] $claimsCapture.Sha256 -cne [string] $ReceiptDocument['RootClaimsPreimage']['Hash']) {
        throw ($script:RollbackClaimsDrift + ' (current root claims)')
    }

    # The linked source transaction must exist, validate end to end, and be
    # terminally committed.
    $transactionId = [string] $ReceiptDocument['SourceTransactionId']
    $transactionDirectory = Join-Path ([string] $AuthorityContext.LiveTransactionsRoot) $transactionId
    if (-not (Test-Path -LiteralPath $transactionDirectory -PathType Container)) {
        throw $script:RollbackSourceTransactionMissing
    }
    $chain = Get-SealedLiveJournalChain -TransactionDirectory $transactionDirectory
    if (@($chain.UnknownNames).Count -gt 0) {
        throw ($script:RollbackSourceTransactionTampered + ' (unknown entries)')
    }
    try {
        $null = Test-SealedLiveJournalChain -Header $chain.Header -Records $chain.Records -Result $chain.Result -ResultFileHash $chain.ResultFileHash
    }
    catch {
        throw ($script:RollbackSourceTransactionTampered + ' (journal chain)')
    }
    $terminalRecords = @(@($chain.Records) | Where-Object {
        [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'COMPLETE'
    })
    if ($null -eq $chain.Result -or @($terminalRecords).Count -eq 0) {
        throw $script:RollbackSourceTransactionUnfinished
    }
    $terminalData = [System.Collections.IDictionary] ([System.Collections.IDictionary] $terminalRecords[0]['Document'])['Data']
    $terminalOutcome = [string] $terminalData['Outcome']
    if ($terminalOutcome -cne 'committed') {
        throw ($script:RollbackSourceOutcomeUnsupported + ' (outcome=' + $terminalOutcome + ')')
    }

    # Receipt binding: the header and the committed result must reference this
    # exact receipt and the reviewed source plan.
    $header = $chain.Header
    $headerBindings = [ordered]@{
        'operation-kind'   = ([string] $header['OperationKind']) -ceq 'environment'
        'home-authority'   = ([string] $header['HomeAuthorityKey']) -ceq [string] $ReceiptDocument['HomeAuthorityKey']
        'receipt-id'       = ([string] $header['ReceiptIntent']['Id']) -ceq [string] $ReceiptDocument['ReceiptId']
        'receipt-path'     = (Test-RollbackReceiptPathEqual -Left ([string] $header['ReceiptIntent']['Path']) -Right ([string] $ReceiptDocument['ReceiptPath']))
        'plan-hash'        = ([string] $header['OriginalPlanHash']) -ceq [string] $ReceiptDocument['PlanHash']
        'document-hash'    = ([string] $header['OriginalDocumentHash']) -ceq [string] $ReceiptDocument['DocumentHash']
    }
    $receiptCompleteRecords = @(@($chain.Records) | Where-Object {
        [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'RECEIPT_COMPLETE'
    })
    if (@($receiptCompleteRecords).Count -eq 1) {
        $ref = [System.Collections.IDictionary] ([System.Collections.IDictionary] $receiptCompleteRecords[0]['Document'])['Data']['ReceiptRef']
        $headerBindings['receipt-ref-id'] = ([string] $ref['Id']) -ceq [string] $ReceiptDocument['ReceiptId']
        $headerBindings['receipt-ref-path'] = (Test-RollbackReceiptPathEqual -Left ([string] $ref['Path']) -Right ([string] $ReceiptDocument['ReceiptPath']))
        $headerBindings['receipt-ref-hash'] = ([string] $ref['Hash']) -ceq [string] $ReceiptDocument['ReceiptHash']
    }
    else {
        $headerBindings['receipt-ref-count'] = $false
    }
    $result = $chain.Result
    $headerBindings['result-transaction'] = ([string] $result['TransactionId']) -ceq $transactionId
    $headerBindings['result-kind'] = ([string] $result['OperationKind']) -ceq 'environment'
    $headerBindings['result-receipt-hash'] = ([string] $result['ReceiptHash']) -ceq [string] $ReceiptDocument['ReceiptHash']
    foreach ($bindingName in @($headerBindings.Keys)) {
        if (-not [bool] $headerBindings[$bindingName]) {
            throw ($script:RollbackSourceReceiptMismatch + ' (' + $bindingName + ')')
        }
    }

    return [pscustomobject][ordered]@{
        ReceiptDocument = $ReceiptDocument
        ReceiptPath = $ReceiptPath
        TransactionId = $transactionId
        TransactionDirectory = $transactionDirectory
        Header = $header
        Result = $result
        TerminalOutcome = $terminalOutcome
        AuthorityStatePreimageBytes = $preimageBytes['AuthorityStatePreimage']
        RootClaimsPreimageBytes = $preimageBytes['RootClaimsPreimage']
    }
}

function Assert-RollbackSourceEligible {
    # Task 7 Step 1: the current authority surface must still be exactly the
    # source transaction's terminal poststate. The current claims bytes, the
    # current state bytes, the tracked overlay baseline, and every platform
    # live root must equal the evidence the committed transaction left
    # behind; any later generation or live drift makes the receipt ineligible.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Evidence,
        [Parameter(Mandatory)] $AuthorityContext
    )

    $receiptDocument = [System.Collections.IDictionary] $Evidence.ReceiptDocument

    $stateCapture = Read-CanonicalHeldRegularFileCapture -Path ([string] $AuthorityContext.CurrentEnvStatePath) -AllowMissing
    if ($null -eq $stateCapture) {
        throw ($script:RollbackStateDrift + ' (state absent)')
    }
    $currentState = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([byte[]] $stateCapture.Bytes))
    if ([string] $stateCapture.Sha256 -cne [string] $Evidence.Result['StateHash']) {
        throw ($script:RollbackStateDrift + ' (state hash)')
    }

    $preimageState = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([byte[]] $Evidence.AuthorityStatePreimageBytes))
    if ([string] $preimageState['TaskOverlayHash'] -cne [string] $currentState['TaskOverlayHash']) {
        throw ($script:RollbackOverlayDrift + ' (overlay hash)')
    }
    $preimageOverlaySkills = Get-SemanticJsonHash -InputObject @([object[]] $preimageState['TaskOverlaySkills'])
    $currentOverlaySkills = Get-SemanticJsonHash -InputObject @([object[]] $currentState['TaskOverlaySkills'])
    if ($preimageOverlaySkills -cne $currentOverlaySkills) {
        throw ($script:RollbackOverlayDrift + ' (overlay skills)')
    }

    $snapshotRootsByPlatform = @{}
    foreach ($row in @([object[]] $receiptDocument['ManagedSnapshots'])) {
        $snapshotRootsByPlatform[[string] $row['Platform']] = [string] $row['LiveRoot']
    }
    foreach ($identityRow in @([object[]] $currentState['FinalResolvedIdentities'])) {
        $platform = [string] $identityRow['Platform']
        $resolvedPath = [string] $identityRow['ResolvedPath']
        $snapshotRoot = [string] $snapshotRootsByPlatform[$platform]
        if ([string]::IsNullOrEmpty($snapshotRoot) -or -not (Test-RollbackReceiptPathEqual -Left $snapshotRoot -Right $resolvedPath)) {
            throw ($script:RollbackLiveRootDrift + ' (' + $platform + ' root)')
        }
        $info = $null
        try { $info = [AiAgentDotfiles.NoFollowFile]::Inspect($resolvedPath) }
        catch { $info = $null }
        if ($null -eq $info -or [bool] $info.IsReparsePoint -or [string] $info.Identity -cne [string] $identityRow['DirectoryIdentity']) {
            throw ($script:RollbackLiveRootDrift + ' (' + $platform + ' identity)')
        }
    }

    return $currentState
}

function Assert-RollbackOriginMatch {
    # The rollback is derived by the origin repository: the source journal
    # header must bind the calling clone's canonical identity, so a wrong
    # clone can never derive (or execute) a rollback it does not own.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $HeaderMap,
        [Parameter(Mandatory)] $GitContext,
        [Parameter(Mandatory)] [string] $RepoId,
        [Parameter(Mandatory)] [string] $CanonicalLockKey
    )

    if ([string] $HeaderMap['OriginRepoId'] -cne $RepoId) {
        throw ($script:RollbackOriginMismatch + ' (repo identity)')
    }
    if ([string] $HeaderMap['GitCommonDirHash'] -cne [string] $GitContext.GitCommonDirHash) {
        throw ($script:RollbackOriginMismatch + ' (git common dir)')
    }
    if ([string] $HeaderMap['CanonicalLockKey'] -cne $CanonicalLockKey) {
        throw ($script:RollbackOriginMismatch + ' (canonical lock key)')
    }
}

function Resolve-RollbackOverlayLockIdentity {
    # The reviewed order is origin canonical -> origin worktree overlay ->
    # global. A source header that binds an overlay lock is only rollback-able
    # from the exact worktree identity that held it: a linked worktree (or any
    # other repository) derives a different overlay lock path and fails closed
    # as an origin mismatch instead of silently skipping the second lock. A
    # header that binds none needs no overlay lock.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $HeaderMap,
        [Parameter(Mandatory)] $GitContext
    )

    if (-not (Test-LiveTransactionMapHasName -Map $HeaderMap -Name 'WorktreeOverlayLockKey') -or
        $null -eq $HeaderMap['WorktreeOverlayLockKey']) {
        return $null
    }
    $overlayLockPath = Get-WorktreeOverlayLockPath -GitContext $GitContext
    $overlayLockKey = Get-WorktreeOverlayLockKey -LockPath $overlayLockPath
    if ([string] $HeaderMap['WorktreeOverlayLockKey'] -cne $overlayLockKey) {
        throw ($script:RollbackOriginMismatch + ' (overlay lock)')
    }
    return [ordered]@{ Path = $overlayLockPath; Key = $overlayLockKey }
}

function New-EnvironmentRollbackPlanDocument {
    # Derives the schema-1 environment-rollback plan from the verified source
    # evidence under the held origin lock order. The rollback's own receipt
    # and journal refs are regenerated at Apply; the plan binds the source
    # receipt identity, the origin keys, the preimage semantics as the
    # RollbackStateIntent (generation advanced past the current state), and
    # one restore row per receipt snapshot target with the observed current
    # state and the exact snapshot bytes as the candidate.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Evidence,
        [Parameter(Mandatory)] [string] $RepoId,
        [Parameter(Mandatory)] [string] $CanonicalLockKey,
        [Parameter(Mandatory)] $GitContext,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $CurrentState
    )

    $receiptDocument = [System.Collections.IDictionary] $Evidence.ReceiptDocument
    $preimageState = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([byte[]] $Evidence.AuthorityStatePreimageBytes))

    $intent = [ordered]@{}
    foreach ($name in @(
        'SchemaVersion', 'ArtifactKind', 'HomeAuthorityKey', 'RootClaimsHash', 'SelectionKind',
        'EnvironmentName', 'EnvironmentLockHash', 'TaskOverlayHash', 'TaskOverlaySkills',
        'ManifestHashes', 'FinalManagedHashes', 'ControllerRepoFingerprint', 'ApprovedToolchainHash'
    )) {
        $intent[$name] = $preimageState[$name]
    }
    $intent['AuthorityGeneration'] = [long] $CurrentState['AuthorityGeneration'] + 1
    $intent['LastOperationKind'] = 'environment-rollback'

    $targets = [System.Collections.Generic.List[object]]::new()
    $order = 0L
    foreach ($row in @([object[]] $receiptDocument['ManagedSnapshots'])) {
        $platform = [string] $row['Platform']
        $platformDir = Join-Path (Join-Path ([string] $Evidence.ReceiptPath) 'snapshot') $platform.ToLowerInvariant()
        foreach ($target in @([object[]] $row['Targets'])) {
            $name = [string] $target['Name']
            # The receipt's snapshot rows bind the target name, snapshot tree
            # hash, and pre-change identity; the live path is the platform's
            # recorded root (verified equal to the current root by the
            # eligibility gates) joined with the safe bare name.
            $livePath = Join-Path ([string] $row['LiveRoot']) $name
            $restored = $null
            if ([string] $target['Status'] -ceq 'COPIED') {
                $restored = [ordered]@{
                    State = 'PRESENT'
                    Type = 'Directory'
                    Hash = [string] $target['SnapshotTreeHash']
                    Identity = [string] $target['LiveIdentity']
                }
            }
            else {
                $restored = [ordered]@{ State = 'MISSING' }
            }
            $info = $null
            try { $info = [AiAgentDotfiles.NoFollowFile]::Inspect($livePath) }
            catch { $info = $null }
            if ($null -ne $info -and (-not [bool] $info.IsDirectory -or [bool] $info.IsReparsePoint)) {
                throw ($script:RollbackLiveRootDrift + ' (' + $platform + '/' + $name + ' not a directory)')
            }
            $current = if ($null -ne $info) {
                [ordered]@{
                    State = 'PRESENT'
                    Type = 'Directory'
                    Hash = (Get-SafeTreeSnapshot -Root $livePath).TreeHash
                    Identity = [string] $info.Identity
                }
            }
            else {
                [ordered]@{ State = 'MISSING' }
            }
            $targets.Add([ordered]@{
                TargetId = (Get-SemanticJsonHash -InputObject ([ordered]@{ Kind = 'skill'; Platform = $platform; Name = $name }))
                Order = $order
                TargetKind = 'skill'
                Role = 'live-target'
                Platform = $platform
                Name = $name
                TargetPath = $livePath
                PreimagePath = $(if ([string] $target['Status'] -ceq 'COPIED') { Join-Path $platformDir $name } else { $null })
                SwapOldPath = $null
                StagedPath = $null
                LiveIdentity = $(if ($null -ne $info) { [string] $info.Identity } else { $null })
                ReceiptSnapshotRef = $(if ([string] $target['Status'] -ceq 'COPIED') {
                        [ordered]@{ Platform = $platform; Name = $name }
                    } else { $null })
                Current = $current
                Candidate = $restored
                TargetContextHash = (Get-SemanticJsonHash -InputObject ([ordered]@{ Path = $livePath; Old = $current; New = $restored }))
            })
            $order++
        }
    }

    $payload = [ordered]@{
        SchemaVersion = 1
        PlanKind = 'environment-rollback'
        TransactionMode = 'receipt-backed'
        HomeAuthorityKey = [string] $receiptDocument['HomeAuthorityKey']
        OriginRepoId = $RepoId
        GitCommonDirHash = [string] $GitContext.GitCommonDirHash
        CanonicalLockKey = $CanonicalLockKey
        SourceTransactionId = [string] $receiptDocument['SourceTransactionId']
        SourceOperationKind = 'environment'
        OriginalPlanHash = [string] $receiptDocument['PlanHash']
        OriginalDocumentHash = [string] $receiptDocument['DocumentHash']
        ReceiptIntent = [ordered]@{
            Id = [string] $receiptDocument['ReceiptId']
            Path = [string] $receiptDocument['ReceiptPath']
        }
        ReceiptId = [string] $receiptDocument['ReceiptId']
        ReceiptHash = [string] $receiptDocument['ReceiptHash']
        RootClaimsHash = [string] $receiptDocument['RootClaimsPreimage']['Hash']
        Targets = @($targets)
        RollbackStateIntent = $intent
    }
    $document = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'rollback-plan'
        Metadata = [ordered]@{
            CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
            Generator = 'scripts/rollback-harness-env.ps1'
            RepositoryCommit = [string] $GitContext.RepositoryCommit
        }
        PlanPayload = $payload
    }
    $document['PlanHash'] = Get-PlanHash -PlanPayload $payload
    $document['DocumentHash'] = Get-DocumentHash -Document $document
    return $document
}

function Assert-RollbackPlanInvocationMatch {
    # Apply-side validation: the reviewed plan at -PlanPath must be the
    # environment-rollback plan for exactly this invocation's receipt and
    # authority; anything else is rejected before any transition work.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $PlanDocument,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ReceiptDocument,
        [Parameter(Mandatory)] [string] $HomeAuthorityKey
    )

    $payload = [System.Collections.IDictionary] $PlanDocument['PlanPayload']
    $bindings = [ordered]@{
        'plan kind'         = ([string] $payload['PlanKind']) -ceq 'environment-rollback'
        'home authority'    = ([string] $payload['HomeAuthorityKey']) -ceq $HomeAuthorityKey
        'receipt id'        = ([string] $payload['ReceiptId']) -ceq [string] $ReceiptDocument['ReceiptId']
        'receipt hash'      = ([string] $payload['ReceiptHash']) -ceq [string] $ReceiptDocument['ReceiptHash']
        'source transaction' = ([string] $payload['SourceTransactionId']) -ceq [string] $ReceiptDocument['SourceTransactionId']
        'original plan hash' = ([string] $payload['OriginalPlanHash']) -ceq [string] $ReceiptDocument['PlanHash']
        'original document hash' = ([string] $payload['OriginalDocumentHash']) -ceq [string] $ReceiptDocument['DocumentHash']
    }
    foreach ($name in @($bindings.Keys)) {
        if (-not [bool] $bindings[$name]) {
            throw ($script:RollbackPlanMismatch + ' (' + $name + ')')
        }
    }
}

$repoFull = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoRoot).Path)
if ($Apply) {
    # Apply stays behind the Phase 0 production interlock: the reviewed
    # transition must not reach a mutation path before policy is released.
    Assert-LiveSafetyMutationAllowed -Operation 'environment-rollback' -Paths @($repoFull, $ReceiptPath, $PlanPath, $JsonPath)
}

$internalRoots = Resolve-RollbackInternalRoots
# Only the sandbox branch may re-wrap the injected home: the builder mkdirs
# under it, while the identity branch already carries the full context.
$authorityContext = if ([string] $internalRoots.ResolutionSource -ceq 'sandbox') {
    New-RollbackAuthorityContext -HomeRoot ([string] $internalRoots.HomeRoot) -ControlBase ([string] $internalRoots.ControlBase) -BackupRoot ([string] $internalRoots.BackupRoot)
} else {
    [object] $internalRoots.AuthorityContext
}
Assert-RollbackAuthorityComplete -AuthorityContext $authorityContext

$receiptResolution = Resolve-PrivateArtifactPath -Path ([System.IO.Path]::GetFullPath($ReceiptPath)) -Role ExternalUserArtifact -RepoRoot $repoFull -AllowMissingLeaf
$receiptFull = [string] $receiptResolution.FullPath
if (-not (Test-Path -LiteralPath $receiptFull -PathType Container)) { throw $script:RollbackReceiptMissing }

$slotState = Get-SealedBackupReceiptSlotState -ReceiptPath $receiptFull
if ($slotState -cne 'COMPLETE') { throw ($script:RollbackReceiptIncomplete + ' (slot is ' + $slotState + ')') }

$sessionReceiptDocumentPath = Join-Path $receiptFull '_meta/receipt.json'
if (-not (Test-Path -LiteralPath $sessionReceiptDocumentPath -PathType Leaf)) {
    throw ($script:RollbackReceiptIncomplete + ' (no receipt document)')
}
$receiptDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($sessionReceiptDocumentPath, [System.Text.UTF8Encoding]::new($false, $true)))
if (-not $receiptDocument.Contains('SourceOperationKind')) { throw $script:RollbackSourceKindUnsupported }
if ([string] $receiptDocument['SourceOperationKind'] -cne 'environment') {
    # Only an environment activation receipt may start a later ordinary
    # rollback; every other producer kind is limited to its own transaction's
    # crash recovery.
    throw ($script:RollbackSourceKindUnsupported + ' (source=' + [string] $receiptDocument['SourceOperationKind'] + ')')
}

$planResolution = Resolve-PrivateArtifactPath -Path ([System.IO.Path]::GetFullPath($PlanPath)) -Role ExternalUserArtifact -RepoRoot $repoFull -AllowMissingLeaf:$DryRun
$planFull = [string] $planResolution.FullPath
if ($DryRun -and (Test-Path -LiteralPath $planFull)) { throw $script:RollbackPlanPathCollision }
if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
    $null = Resolve-PrivateArtifactPath -Path ([System.IO.Path]::GetFullPath($JsonPath)) -Role ExternalUserArtifact -RepoRoot $repoFull -AllowMissingLeaf
}

# Task 7 Step 2: the calling repository is the origin candidate. Under the
# reviewed origin canonical -> worktree overlay -> global lock order, the
# source-graph evidence and the current-surface eligibility are revalidated,
# and DryRun derives and writes the schema-1 environment-rollback plan while
# Apply validates the reviewed plan fail-closed. The transition itself
# arrives with the remaining Task 7 slices.
$gitContext = Get-CanonicalGitContext -RepoRoot $repoFull
$contractPaths = Get-CanonicalTransactionContractPaths -GitContext $gitContext
$repoId = Get-CanonicalRepoIdentity -GitContext $gitContext
$canonicalLockKey = Get-SemanticJsonHash -InputObject ([ordered]@{ Path = [string] $contractPaths.LockPath })

if ($Apply -and -not (Test-Path -LiteralPath $planFull -PathType Leaf)) { throw $script:RollbackPlanMissing }

# The source transaction's header is probed read-only before the lock order
# starts, exactly like the reviewed recovery dispatcher: the worktree overlay
# lock identity it binds decides the second lock, and every binding is
# revalidated under the held locks before any action.
$sourceTransactionId = [string] $receiptDocument['SourceTransactionId']
if ([string]::IsNullOrWhiteSpace($sourceTransactionId)) { throw $script:RollbackSourceKindUnsupported }
$sourceTransactionDirectory = Join-Path ([string] $authorityContext.LiveTransactionsRoot) $sourceTransactionId
# A receipt that names no readable source namespace is owned by the under-lock
# evidence checks (which report the missing/tampered/unfinished tokens), so the
# probe only inspects a namespace that actually exists.
$overlayIdentity = $null
if (Test-Path -LiteralPath $sourceTransactionDirectory -PathType Container) {
    $probeChain = Get-SealedLiveJournalChain -TransactionDirectory $sourceTransactionDirectory
    $probeHeader = [System.Collections.IDictionary] $probeChain.Header
    if ($null -ne $probeHeader) {
        $overlayIdentity = Resolve-RollbackOverlayLockIdentity -HeaderMap $probeHeader -GitContext $gitContext
    }
}

$canonicalLock = Enter-CanonicalRepoLock -LockPath ([string] $contractPaths.LockPath) -AllowCreate
$canonicalWitness = $null
$overlayLock = $null
$globalLock = $null
try {
    try {
        $canonicalWitness = Open-CanonicalHeldNamespaceWitness -RepoRoot $repoFull -CanonicalLockHandle $canonicalLock
    }
    catch {
        # A repository without its canonical setup window still dispatches
        # under the canonical and global locks, exactly like live recovery.
        if ([string] $_.Exception.Message -cin @('canonical-setup-required', 'canonical-recovery-required')) {
            $canonicalWitness = $null
        }
        else { throw }
    }
    try {
        if ($null -ne $overlayIdentity) {
            $overlayLock = Enter-WorktreeOverlayLock -LockPath ([string] $overlayIdentity.Path) -CanonicalLockHandle $canonicalLock -AllowCreate
        }
        $globalLock = if ($null -ne $canonicalWitness) {
            Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $authorityContext -RequiredCanonicalWitness $canonicalWitness
        }
        else {
            Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $authorityContext
        }
        try {
            $evidence = Get-RollbackSourceEvidence -ReceiptDocument $receiptDocument -ReceiptPath $receiptFull -AuthorityContext $authorityContext
            Assert-RollbackOriginMatch -HeaderMap $evidence.Header -GitContext $gitContext -RepoId $repoId -CanonicalLockKey $canonicalLockKey
            $currentState = Assert-RollbackSourceEligible -Evidence $evidence -AuthorityContext $authorityContext
            $lockedOverlayIdentity = Resolve-RollbackOverlayLockIdentity -HeaderMap $evidence.Header -GitContext $gitContext
            if (($null -eq $lockedOverlayIdentity) -ne ($null -eq $overlayIdentity)) {
                throw ($script:RollbackOriginMismatch + ' (overlay lock)')
            }
            if ($null -ne $lockedOverlayIdentity -and [string] $lockedOverlayIdentity.Key -cne [string] $overlayIdentity.Key) {
                throw ($script:RollbackOriginMismatch + ' (overlay lock)')
            }

            if ($DryRun) {
                $document = New-EnvironmentRollbackPlanDocument -Evidence $evidence -RepoId $repoId -CanonicalLockKey $canonicalLockKey -GitContext $gitContext -CurrentState $currentState
                # The derivation self-checks against the reviewed semantic
                # layer, and the schema-validating publish then fails closed
                # before any byte reaches the plan path.
                Test-RollbackPlanSemantics -Document $document
                Publish-ValidatedLiveArtifactJson -Document $document -Path $planFull -ArtifactKind 'rollback-plan' -JsonDepth 64 -CollisionFailure $script:RollbackPlanPathCollision
                Write-Host "environment rollback plan created: $($evidence.TransactionId)"
                Write-Host "PlanHash: $($document['PlanHash'])"
                exit 0
            }

            # Apply validates the reviewed plan against this exact invocation
            # and then runs it as a NEW receipt-backed transaction under the
            # held origin canonical -> worktree overlay -> global lock order.
            $planDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($planFull, [System.Text.UTF8Encoding]::new($false, $true)))
            $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $PSScriptRoot '../schemas/rollback-plan.schema.json') -InstancePath $planFull
            Test-RollbackPlanSemantics -Document $planDocument
            Assert-RollbackPlanInvocationMatch -PlanDocument $planDocument -ReceiptDocument $receiptDocument -HomeAuthorityKey ([string] $authorityContext.HomeAuthorityKey)
            $statePaths = Get-LiveTransactionStatePaths -ControlBase ([string] $authorityContext.ControlBase) -HomeAuthorityKey ([string] $authorityContext.HomeAuthorityKey)
            $rollbackOutcome = Invoke-SealedEnvironmentRollbackTransaction -PlanDocument $planDocument -SourceReceiptDocument $receiptDocument -SourceReceiptPath $receiptFull -ControlBase ([string] $authorityContext.ControlBase) -BackupRoot ([string] $authorityContext.BackupRoot) -HomeRoot ([string] $authorityContext.HomeRoot) -ClaimsPath ([string] $statePaths['ClaimsPath']) -StatePath ([string] $statePaths['StatePath']) -LiveTransactionsRoot ([string] $authorityContext.LiveTransactionsRoot) -GitContext $gitContext -RepoId $repoId -CanonicalLockKey $canonicalLockKey
            Write-Host "environment rollback applied: $([string] $rollbackOutcome.TransactionId)"
            Write-Host "State hash: $([string] $rollbackOutcome.StateHash)"
            Write-Host "Result hash: $([string] $rollbackOutcome.ResultHash)"
            exit 0
        }
        finally {
            if ($null -ne $globalLock) { Exit-HomeAuthorityGlobalLiveLock -LockHandle $globalLock }
            if ($null -ne $overlayLock) { Exit-WorktreeOverlayLock -LockHandle $overlayLock }
        }
    }
    finally {
        if ($null -ne $canonicalWitness) { Close-CanonicalHeldNamespaceWitness -Witness $canonicalWitness }
    }
}
finally {
    Exit-CanonicalRepoLock -LockHandle $canonicalLock
}
