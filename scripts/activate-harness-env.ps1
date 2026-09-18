#requires -Version 7.0
<#
.SYNOPSIS
    Plan-bound activation of one harness environment on an existing shared
    authority: the dry-run writes one external `OperationKind=environment`
    sync plan, and -Apply consumes exactly that plan through the Phase 2 live
    transaction host.

.DESCRIPTION
    Activation is a reviewed plan producer plus a plan consumer, never an
    internally generated mutation.

    `-DryRun` (the default when -Apply is absent) runs the mandatory gate chain
    (build-skills unless -SkipBuild, secret scan unless -SkipSecretScan,
    build-harness-env, and the frozen schema 3 lock validation), materializes
    the named environment into a create-new
    `<plan-stem>.materialization` directory next to the plan, revalidates that
    materialization (all three platform source roots, the v3 build sidecar, and
    the lock against the repository), reads the existing shared authority
    (claims plus state), refuses claim-identity drift, and then writes ONE
    external schema 3 plan whose OperationKind is `environment`, whose
    Generator is this script, whose AuthorityStateIntent.RootClaimsHash is the
    exact live claims bytes hash, and whose EnvironmentMaterializationRoot
    binds the exact MaterializationHash it used. A path collision fails closed;
    a partial plan is never written.

    `-Apply -PlanPath` consumes only that exact existing plan. The production
    interlock is the first gate; then the plan path/private-artifact rules, the
    document integrity, the operation kind, the materialization currency, the
    requested name, the controller identity, the document-hash consumption
    gate, the canonical setup and authority-prefix gates, the per-platform
    staging roots with probed capability hashes, and finally the Phase 2
    receipt-backed host. Apply never builds, scans, or rewrites the plan; the
    -SkipBuild/-SkipSecretScan switches and any live-root selector are refused.

    The activation publishes only the shared authority state
    (`<ControlBase>/homes/<key>/current-env.json`); the repo-local legacy
    `state/current-env.json` is left byte-identical as legacy evidence. The
    optional -JsonPath summary carries hashes, names, the mode, and the exact
    receipt reference returned by the host - never file contents.

.PARAMETER Name
    Env name (bare identifier, matches harness-source/envs/<Name>.psd1).

.PARAMETER Apply
    Consume the exact existing plan at -PlanPath. Without it the script is a
    pure plan-producing dry-run.

.PARAMETER DryRun
    Explicitly select dry-run mode. Equivalent to omitting -Apply; cannot be
    combined with -Apply.

.PARAMETER PlanPath
    Required in both modes: the external create-new plan path. DryRun writes
    it; Apply never overwrites, refreshes, or deletes it.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory for live paths. Either all of -HomeRoot/-ControlBase/
    -BackupRoot are supplied together or none are, in which case the approved
    internal sandbox host injects all three. There is no machine default.

.PARAMETER ControlBase
    The private authority control base holding `homes/<key>`. See -HomeRoot.

.PARAMETER BackupRoot
    The receipt/backup root. See -HomeRoot.

.PARAMETER SkipBuild
    DryRun only: skip scripts/build-skills.ps1 (use existing generated output).

.PARAMETER SkipSecretScan
    DryRun only: skip scripts/scan-secrets.ps1. Not recommended; refused on
    -Apply.

.PARAMETER JsonPath
    Optional machine-readable activation summary path.

.PARAMETER TaskOverlayPath
    Optional task skill overlay path. Defaults to
    .agent-harness/task-skills.psd1 under the repository. Both invocations must
    pass the same path: the materialization lock binds the overlay hash it was
    built with.

.PARAMETER ReasonixLiveSkillsPath
    Declared for CLI compatibility only. Activation selects its live roots
    exclusively from the immutable root claims; an explicit root-transition
    request is rejected.

.OUTPUTS
    Streams the gate-chain, plan, and transaction output. Exit 0 on success,
    non-zero on any gate failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name,
    [switch] $Apply,
    [switch] $DryRun,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $PlanPath,
    [string] $HomeRoot,
    [string] $ControlBase,
    [string] $BackupRoot,
    [switch] $SkipBuild,
    [switch] $SkipSecretScan,
    [string] $JsonPath,
    [string] $TaskOverlayPath,
    [string] $ReasonixLiveSkillsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$script:ActivationPlanPathRequired = 'activation-plan-path-required'
$script:ActivationSkipSwitchForbidden = 'activation-skip-switch-forbidden'
$script:ActivationRootSelectionForbidden = 'activation-root-selection-forbidden'
$script:ActivationRootSelectionIncomplete = 'activation-root-selection-incomplete'
$script:ActivationPlanKindMismatch = 'activation-plan-kind-mismatch'
$script:ActivationControllerMismatch = 'activation-controller-mismatch'
$script:ActivationMaterializationInvalid = 'activation-materialization-invalid'
$script:ActivationGeneratorName = 'scripts/activate-harness-env.ps1'

if ($Apply -and $DryRun) {
    Write-Error 'Specify -DryRun or -Apply, not both.' -ErrorAction Continue
    exit 1
}

. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')

# The production interlock is the first gate of every -Apply: outside the
# approved internal sandbox it refuses with the policy token before any
# traversal, plan consumption, or host composition.
if ($Apply) {
    $interlockPaths = @($RepoRoot, $HomeRoot, $ControlBase, $BackupRoot, $PlanPath, $JsonPath, $TaskOverlayPath)
    if (Test-LiveSafetySandboxCapability) {
        # The reviewed build/plan/summary locators are checked against the
        # sandbox root; the injected live roots are resolved below.
        foreach ($variableName in @('AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT', 'AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT', 'AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE')) {
            $value = [System.Environment]::GetEnvironmentVariable($variableName)
            if (-not [string]::IsNullOrWhiteSpace($value)) { $interlockPaths += $value }
        }
    }
    $interlockPaths = @($interlockPaths) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } | ForEach-Object { [System.IO.Path]::GetFullPath([string] $_) }
    Assert-LiveSafetyMutationAllowed -Operation 'environment-activate' -Paths @($interlockPaths)
}

if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    throw "$($script:ActivationPlanPathRequired): run -DryRun -PlanPath <external-plan.json> first, review the plan, then rerun -Apply with the same -PlanPath."
}
if ($Apply -and ($SkipBuild -or $SkipSecretScan)) {
    throw "$($script:ActivationSkipSwitchForbidden): -Apply consumes the reviewed plan as-is and never rebuilds or rescans; -SkipBuild/-SkipSecretScan are -DryRun only."
}
if (-not [string]::IsNullOrWhiteSpace($ReasonixLiveSkillsPath)) {
    throw "$($script:ActivationRootSelectionForbidden): activation selects its live roots from the immutable root claims only."
}

. (Join-Path $PSScriptRoot 'live-plan-common.ps1')
. (Join-Path $PSScriptRoot 'live-plan-evidence-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'harness-authority-status-common.ps1')
. (Join-Path $PSScriptRoot 'home-authority-common.ps1')
. (Join-Path $PSScriptRoot 'root-claims-registry-common.ps1')
. (Join-Path $PSScriptRoot 'live-transaction-common.ps1')

function Initialize-ActivationContext {
    # Either the caller supplies the complete root trio or the approved
    # internal sandbox host injects all three; a partial selection is refused
    # instead of silently mixing a caller root with an injected one.
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $supplied = @(@($HomeRoot, $ControlBase, $BackupRoot) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
    $resolvedContext = $null
    if ($supplied.Count -eq 3) {
        $homeFull = [System.IO.Path]::GetFullPath($HomeRoot)
        $controlFull = [System.IO.Path]::GetFullPath($ControlBase)
        $backupFull = [System.IO.Path]::GetFullPath($BackupRoot)
    }
    elseif ($supplied.Count -eq 0) {
        $internalRoots = Resolve-LiveSyncInternalRoots
        $homeFull = [System.IO.Path]::GetFullPath([string] $internalRoots.HomeRoot)
        $controlFull = [System.IO.Path]::GetFullPath([string] $internalRoots.ControlBase)
        $backupFull = [System.IO.Path]::GetFullPath([string] $internalRoots.BackupRoot)
        # The identity branch already carries the full context; only the
        # sandbox branch may re-wrap the injected home (the builder mkdirs).
        if ([string] $internalRoots.ResolutionSource -cne 'sandbox') {
            $resolvedContext = [object] $internalRoots.AuthorityContext
        }
    }
    else {
        throw "$($script:ActivationRootSelectionIncomplete): supply -HomeRoot, -ControlBase, and -BackupRoot together, or none so the approved sandbox host injects them."
    }

    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot)
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $repoPrefix = $repoFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($homeFull.Equals($repoFull, $comparison) -or $homeFull.StartsWith($repoPrefix, $comparison)) {
        throw "HomeRoot must not be the repository or live inside it: $homeFull"
    }

    $identity = [pscustomobject][ordered]@{
        ResolverVersion = $script:HomeAuthorityResolverVersion
        TokenSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ProfileRoot = $homeFull
        RoamingAppDataRoot = (Join-Path $homeFull 'AppData\Roaming')
        LocalAppDataRoot = (Join-Path $homeFull 'AppData\Local')
    }
    $authorityContext = if ($null -ne $resolvedContext) { $resolvedContext } else { New-LiveSyncAuthorityContext -HomeRoot $homeFull -ControlBase $controlFull -BackupRoot $backupFull }
    return [pscustomobject]@{ HomeRoot = $homeFull; Identity = $identity; Context = $authorityContext }
}

function Invoke-ActivationGateScript {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [string[]] $Arguments = @()
    )
    $script = Join-Path $PSScriptRoot $ScriptName
    & pwsh -NoProfile -File $script @Arguments | Out-Host
    return $LASTEXITCODE
}

function Write-ActivationSummary {
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'DRY-RUN')] [string] $Result,
        [AllowNull()] [string] $BackupReference,
        [AllowNull()] [object] $LockResult,
        [AllowNull()] [object] $PlanDocument,
        [AllowNull()] [object] $HostResult,
        [AllowNull()] [string] $PlanFullPath
    )

    if ([string]::IsNullOrWhiteSpace($JsonPath)) { return }
    $parent = Split-Path -Parent $JsonPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [string[]] $lockReasons = @()
    if ($null -ne $LockResult) {
        $lockReasons = [string[]] @($LockResult.Reasons)
    }
    $planHash = $null
    $documentHash = $null
    $materializationHash = $null
    if ($null -ne $PlanDocument) {
        $planHash = [string] $PlanDocument['PlanHash']
        $documentHash = [string] $PlanDocument['DocumentHash']
        $planPayload = [System.Collections.IDictionary] $PlanDocument['PlanPayload']
        if ($planPayload.Contains('EnvironmentMaterializationRoot')) {
            $materializationHash = [string] (([System.Collections.IDictionary] $planPayload['EnvironmentMaterializationRoot'])['MaterializationHash'])
        }
    }
    $journalDir = $null
    $transactionId = $null
    $receiptId = $null
    $receiptPath = $null
    $receiptHash = $null
    $stateHash = $null
    $resultHash = $null
    if ($null -ne $HostResult) {
        $transactionId = [string] $HostResult.TransactionId
        $receiptId = [string] $HostResult.ReceiptId
        $receiptPath = [string] $HostResult.ReceiptPath
        $receiptHash = [string] $HostResult.ReceiptHash
        $stateHash = [string] $HostResult.StateHash
        $resultHash = [string] $HostResult.ResultHash
        $journalDir = [string] $HostResult.JournalDir
    }
    $document = [ordered]@{
        SchemaVersion = 2
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Name = $Name
        Mode = if ($Apply) { 'apply' } else { 'dry-run' }
        Result = $Result
        PlanPath = $PlanFullPath
        PlanHash = $planHash
        DocumentHash = $documentHash
        MaterializationHash = $materializationHash
        LockValidity = if ($null -eq $LockResult) { 'not-checked' } elseif ($LockResult.Valid) { 'valid' } else { 'invalid' }
        LockHash = if ($null -eq $LockResult) { $null } else { $LockResult.LockHash }
        TaskOverlayHash = if ($null -eq $LockResult -or $null -eq $LockResult.Lock) { $null } else { $LockResult.Lock.TaskOverlayHash }
        LockReasons = $lockReasons
        BackupReference = $BackupReference
        TransactionId = $transactionId
        ReceiptId = $receiptId
        ReceiptPath = $receiptPath
        ReceiptHash = $receiptHash
        StateHash = $stateHash
        ResultHash = $resultHash
        JournalDir = $journalDir
    }
    [System.IO.File]::WriteAllText($JsonPath, (ConvertTo-Json -InputObject $document -Depth 15) + "`n", [System.Text.UTF8Encoding]::new($false))
}

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$null = Get-HarnessEnvStagingRoot -RepoRoot $repo -Name $Name
$definitionPath = Join-Path (Get-HarnessEnvRoot -RepoRoot $repo) "$Name.psd1"
if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
    Write-Error "Unknown env '$Name': expected definition at $definitionPath" -ErrorAction Continue
    exit 1
}
$definition = Read-HarnessEnvDefinition -Path $definitionPath
$taskOverlay = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $repo -BaseEnvName $Name -Path $TaskOverlayPath
$effectiveDefinition = Merge-HarnessTaskSkillOverlay -Definition $definition -Overlay $taskOverlay
$null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $effectiveDefinition
$taskOverlayPathFull = $taskOverlay.Path

$modeLabel = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
Write-Host "Harness env activate ($modeLabel): $Name"
Write-Host "  Repo : $repo"
Write-Host "  Plan : $([System.IO.Path]::GetFullPath($PlanPath))"

if ($Apply) {
    # -----------------------------------------------------------------------
    # Apply: consume the exact existing plan.
    # -----------------------------------------------------------------------

    $planFull = [System.IO.Path]::GetFullPath($PlanPath)
    if (-not (Test-Path -LiteralPath $planFull -PathType Leaf)) {
        throw "activation-plan-not-found: $planFull. Run -DryRun -PlanPath <external-plan.json> first."
    }
    $null = Resolve-PrivateArtifactPath -Path $planFull -Role ExternalUserArtifact -RepoRoot $repo

    $saved = Read-LiveSyncPlan -Path $planFull
    Assert-LiveSyncPlanDocumentIntegrity -Document ([System.Collections.IDictionary] $saved)
    $savedPayload = [System.Collections.IDictionary] $saved['PlanPayload']
    $savedKind = [string] $savedPayload['OperationKind']
    if ($savedKind -cne 'environment') { throw $script:ActivationPlanKindMismatch }
    if ([string] $savedPayload['Generator'] -cne $script:ActivationGeneratorName) { throw $script:ActivationPlanKindMismatch }

    # Materialization currency: the bound create-new materialization must still
    # carry the exact bytes it carried when the plan was produced.
    $materializationRoot = [System.Collections.IDictionary] $savedPayload['EnvironmentMaterializationRoot']
    $materializationFull = [System.IO.Path]::GetFullPath([string] $materializationRoot['Path'])
    $null = Assert-LiveSyncPlanCurrent -Document ([System.Collections.IDictionary] $saved) -MaterializationDirectory $materializationFull
    # ... and the lock must still describe the current repository: definition,
    # task overlay, manifests, skill sources, and staged trees. The materialized
    # source roots are revalidated for all three platforms, including a platform
    # whose managed-skill subset is empty.
    $null = Assert-HarnessEnvMaterializedSourceRoots -StagingPath $materializationFull
    # The bound materialization must still be the frozen v3 shape: the reviewed
    # sidecar reader enforces schema 3 semantics and the three materialized
    # roots, so an older or reshaped build is refused at the consumer too.
    $null = Read-HarnessEnvBuild -StagingPath $materializationFull
    $null = Read-HarnessEnvLock -StagingPath $materializationFull
    $materializationLock = Test-HarnessEnvLock -RepoRoot $repo -DefinitionPath $definitionPath -StagingPath $materializationFull -TaskOverlayPath $taskOverlayPathFull
    if (-not $materializationLock.Valid) {
        throw ("$($script:ActivationMaterializationInvalid): {0}" -f (@($materializationLock.Reasons) -join '; '))
    }

    $null = Assert-LiveSyncPlanSelectionContext -Document ([System.Collections.IDictionary] $saved) -ExpectedOperationKind 'environment' -ExpectedEnvironmentName $Name

    # The reviewing controller must still be this repository: a plan produced
    # by another clone routes to takeover, never to an ordinary activation.
    $currentController = Get-CanonicalControllerIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $repo)
    if ([string] $savedPayload['ControllerRepoFingerprint'] -cne $currentController) { throw $script:ActivationControllerMismatch }

    # A plan kind that never carries a prune action is re-checked before the
    # mutation, not after it: an activation only adds or updates managed
    # skills, and a substituted plan must not delete one first.
    foreach ($action in @([object[]] $savedPayload['OrderedActions'])) {
        if ([string] $action['Action'] -ceq 'prune') {
            throw ("activation-plan-prune-forbidden: {0}/{1}" -f [string] $action['Platform'], [string] $action['Name'])
        }
    }

    Write-Host 'Plan binding    : verified'
    Write-Host "Plan hash       : $([string] $saved['PlanHash'])"
    Write-Host "Document hash   : $([string] $saved['DocumentHash'])"
    Write-PlanSummary -Payload $savedPayload

    # Resolve the reviewed roots only now: the interlock and every static plan
    # gate above already ran.
    $activationContext = Initialize-ActivationContext -RepoRoot $repo
    $homeFull = [string] $activationContext.HomeRoot
    $authorityContext = $activationContext.Context
    $controlBaseFull = [System.IO.Path]::GetFullPath([string] $authorityContext.ControlBase)
    $backupRootFull = [System.IO.Path]::GetFullPath([string] $authorityContext.BackupRoot)
    Write-Host "Home root       : $homeFull"
    Write-Host "Control base    : $controlBaseFull"

    # Two reviewed preconditions own the ground this activation needs. The
    # canonical repo setup establishes the private prefix together with the
    # canonical lock/claim, so activation never bootstraps a second time and
    # fails closed with the canonical status token instead.
    $canonicalStatus = Get-CanonicalSetupStatus -RepoRoot $repo
    if ([string] $canonicalStatus -cne 'canonical-ready') { throw [string] $canonicalStatus }
    $bootstrapStatus = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $authorityContext
    if ([string] $bootstrapStatus.Status -cne 'COMPLETE') { throw $script:LiveSyncAuthorityMissing }

    # One plan may mutate once: the reviewed document hash of every terminal
    # transaction in this authority's namespace is consumed evidence, so a
    # replayed activation plan is refused here, before any staging work.
    $terminalDocuments = Get-SealedLiveTransactionTerminalDocumentHashes -TransactionsRoot ([string] $authorityContext.LiveTransactionsRoot)
    Assert-LiveSyncPlanDocumentHashNotConsumed -Document ([System.Collections.IDictionary] $saved) -TerminalEvidence $terminalDocuments

    # Per-platform same-volume staging roots (also the mutation-preflight probe
    # roots) and the probed capability hashes the receipt and the state
    # postimage bind, mirroring the reviewed sync composition.
    $stagingBase = Join-Path $homeFull '.ai-agent-dotfiles-staging'
    $stagingRootsByPlatform = [ordered]@{}
    $sourceRootsByPlatform = [ordered]@{}
    $liveRootsByPlatform = [ordered]@{}
    $capabilityHashesByPlatform = [ordered]@{}
    foreach ($slot in @([object[]] $savedPayload['Platforms'])) {
        $platform = [string] $slot['Platform']
        if ($platform -cnotin @('Claude', 'Codex', 'Reasonix')) { throw $script:LivePlanSelectionMismatch }
        $liveRoot = [System.IO.Path]::GetFullPath([string] $slot['LiveRoot'])
        $liveRootsByPlatform[$platform] = $liveRoot
        $stagingRootPath = Join-Path $stagingBase $platform
        New-Item -ItemType Directory -Force -Path $stagingRootPath | Out-Null
        $stagingRootsByPlatform[$platform] = [System.IO.Path]::GetFullPath($stagingRootPath)
        $preflight = Resolve-TargetContext -Path $liveRoot -Mode MutationPreflight -ProbeRoot $stagingRootPath -HomeRoot $homeFull -ForbiddenRoots @($controlBaseFull, $backupRootFull)
        if ([string] $preflight.FilesystemCapabilityStatus -cne 'SUPPORTED' -or
            ([string] $preflight.FilesystemCapabilityHash) -cnotmatch '\A[0-9a-f]{64}\z') {
            throw $script:LiveSyncUnsupportedApplyKind
        }
        $capabilityHashesByPlatform[$platform] = [string] $preflight.FilesystemCapabilityHash
        $sourceRootsByPlatform[$platform] = [System.IO.Path]::GetFullPath([string] $slot['SourceRoot'])
    }

    Write-Host ''
    Write-Host 'Running the receipt-backed live transaction host ...'
    # The approved toolchain root is the repository carrying the reviewed
    # scripts and schemas, not the activation target repository.
    $toolchainRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $hostResult = Invoke-SealedLiveTransactionHost -Plan ([System.Collections.IDictionary] $saved) -RepoRoot $repo -ControlBase $controlBaseFull -BackupRoot $backupRootFull -StagingRootsByPlatform $stagingRootsByPlatform -SourceRootsByPlatform $sourceRootsByPlatform -FinalCapabilityHashesByPlatform $capabilityHashesByPlatform -AuthorityContext $authorityContext -WorkingTreeRoots ([ordered]@{ RepoRoot = $repo; ToolchainRoot = $toolchainRoot }) -ToolchainRoot $toolchainRoot
    Write-Host "Transaction id  : $([string] $hostResult.TransactionId)"
    Write-Host "Receipt id      : $([string] $hostResult.ReceiptId)"
    Write-Host "Receipt path    : $([string] $hostResult.ReceiptPath)"
    Write-Host "Receipt hash    : $([string] $hostResult.ReceiptHash)"
    Write-Host "State hash      : $([string] $hostResult.StateHash)"
    Write-Host "Result hash     : $([string] $hostResult.ResultHash)"
    Write-Host "Journal         : $([string] $hostResult.JournalDir)"

    # Post-apply verification: every planned managed target reaches its
    # reviewed end state and the Codex .system marker is preserved. An
    # activation plan never carries a prune action; one would mean the plan
    # kind was substituted.
    $verificationFailed = $false
    foreach ($action in @([object[]] $savedPayload['OrderedActions'])) {
        if ([string] $action['Action'] -ceq 'prune') {
            Write-Host "ERROR: activation plan carries an unsupported prune action: $($action['Platform'])/$($action['Name'])"
            $verificationFailed = $true
            continue
        }
        $target = Join-Path ([string] $liveRootsByPlatform[[string] $action['Platform']]) ([string] $action['Name'])
        if (-not (Test-Path -LiteralPath $target)) {
            Write-Host "ERROR: planned target missing after apply: $target"
            $verificationFailed = $true
        }
    }
    $systemMarkerPath = Join-Path (Join-Path ([string] $liveRootsByPlatform['Codex']) '.system') '.codex-system-skills.marker'
    $systemOk = Test-Path -LiteralPath $systemMarkerPath -PathType Leaf
    Write-Host ".system marker preserved: $systemOk"
    if ($verificationFailed) {
        throw 'activation-postcondition-failed: inspect the live transaction journal and receipt.'
    }

    Write-ActivationSummary -Result 'PASS' -BackupReference ([string] $hostResult.ReceiptPath) -LockResult $materializationLock -PlanDocument ([System.Collections.IDictionary] $saved) -HostResult $hostResult -PlanFullPath $planFull
    Write-Host ''
    Write-Host 'APPLY complete through the receipt-backed host.'
    exit 0
}

# ---------------------------------------------------------------------------
# DryRun: mandatory gates, reviewed materialization, one external plan
# ---------------------------------------------------------------------------

$activationContext = Initialize-ActivationContext -RepoRoot $repo
$homeFull = [string] $activationContext.HomeRoot
$authorityContext = $activationContext.Context
$controlBaseFull = [System.IO.Path]::GetFullPath([string] $authorityContext.ControlBase)
$backupRootFull = [System.IO.Path]::GetFullPath([string] $authorityContext.BackupRoot)
Write-Host "  Home : $homeFull"

if (-not $SkipBuild) {
    Write-Host ''
    Write-Host 'Gate 1/4: build-skills'
    $code = Invoke-ActivationGateScript -ScriptName 'build-skills.ps1' -Arguments @('-RepoRoot', $repo)
    if ($code -ne 0) {
        Write-Error "build-skills.ps1 failed (exit $code). Activation aborted." -ErrorAction Continue
        exit $code
    }
}
else {
    Write-Host 'Gate 1/4: build-skills skipped (-SkipBuild)'
}

if (-not $SkipSecretScan) {
    Write-Host ''
    Write-Host 'Gate 2/4: secret scan'
    $code = Invoke-ActivationGateScript -ScriptName 'scan-secrets.ps1' -Arguments @('-RepoRoot', $repo)
    if ($code -ne 0) {
        Write-Error "scan-secrets.ps1 failed (exit $code). Activation aborted." -ErrorAction Continue
        exit $code
    }
}
else {
    Write-Host 'Gate 2/4: secret scan skipped (-SkipSecretScan)'
}

Write-Host ''
Write-Host 'Gate 3/4: rebuild env staging'
$code = Invoke-ActivationGateScript -ScriptName 'build-harness-env.ps1' -Arguments @('-Name', $Name, '-RepoRoot', $repo, '-TaskOverlayPath', $taskOverlayPathFull)
if ($code -ne 0) {
    Write-Error "build-harness-env.ps1 failed (exit $code). Activation aborted." -ErrorAction Continue
    exit $code
}
$staging = Get-HarnessEnvStagingRoot -RepoRoot $repo -Name $Name

$lockResult = Test-HarnessEnvLock -RepoRoot $repo -DefinitionPath $definitionPath -StagingPath $staging -TaskOverlayPath $taskOverlayPathFull
if (-not $lockResult.Valid) {
    Write-ActivationSummary -Result 'FAIL' -BackupReference $null -LockResult $lockResult
    Write-Error ("Environment lock is not valid; rebuild before activation: {0}" -f (@($lockResult.Reasons) -join '; ')) -ErrorAction Continue
    exit 1
}
Write-Host "Environment lock: valid ($($lockResult.LockHash))"

# Gate 4: the reviewed plan. The create-new materialization is the only
# artifact the plan binds as its source; the plan itself is written exactly
# once, after every gate and after the document passes its own integrity gate.
Write-Host ''
Write-Host 'Gate 4/4: reviewed environment plan'
$planFull = [System.IO.Path]::GetFullPath($PlanPath)
if (Test-Path -LiteralPath $planFull) { throw $script:LivePlanPathCollision }
$null = Resolve-PrivateArtifactPath -Path $planFull -Role ExternalUserArtifact -RepoRoot $repo -AllowMissingLeaf

$materializationPath = Get-LiveSyncMaterializationPath -PlanPath $planFull
$materialization = New-LiveSyncMaterializationEvidence -MaterializationPath $materializationPath -RepoRoot $repo -Name $Name -TaskOverlayPath $taskOverlayPathFull
$null = Assert-HarnessEnvMaterializedSourceRoots -StagingPath $materializationPath
$materializationLock = Test-HarnessEnvLock -RepoRoot $repo -DefinitionPath $definitionPath -StagingPath $materializationPath -TaskOverlayPath $taskOverlayPathFull
if (-not $materializationLock.Valid) {
    Write-ActivationSummary -Result 'FAIL' -BackupReference $null -LockResult $materializationLock
    throw ("$($script:ActivationMaterializationInvalid): {0}" -f (@($materializationLock.Reasons) -join '; '))
}

# Activation runs on a machine that already has a valid shared authority with
# the current controller: the reviewed read-only route must be exactly
# `activate`, so recovery, repairs, takeover, migration, and adoption are never
# reachable through this producer.
$assessment = Get-HarnessEnvAuthorityAssessment -RepoRoot $repo -Identity $activationContext.Identity
if ([string] $assessment.Route -cne 'activate') {
    throw ("live-plan-selection-mismatch: the read-only authority assessment routes to '$([string] $assessment.Route)', not 'activate'.")
}
$authorityState = Read-HomeAuthorityState -ControlBase $controlBaseFull -HomeAuthorityKey ([string] $authorityContext.HomeAuthorityKey) -RepoRoot $repo
if ([string] $authorityState.PairStatus -cne 'VALID') { throw $script:LiveSyncAuthorityMissing }
$claimsDocument = [System.Collections.IDictionary] $authorityState.ClaimsDocument
$claimsHash = [string] $authorityState.ClaimsBytesHash
if ([string] $claimsHash -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]] $authorityState.ClaimsBytes)).ToLowerInvariant()) {
    throw $script:LiveSyncPlanHashMismatch
}

# The immutable claim is the only live-root selector: the defaults and any
# caller switch are never consulted once an authority exists. The target rows
# are fresh live observations, never the claim document's own rows.
$liveRootsByPlatform = [ordered]@{}
foreach ($claimRow in @([object[]] $claimsDocument['LiveRootClaims'])) {
    $liveRootsByPlatform[[string] $claimRow['Platform']] = [string] $claimRow['RequestedPath']
}
$observedRows = [System.Collections.Generic.List[object]]::new()
foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
    if (-not $liveRootsByPlatform.Contains($platform)) { throw $script:LivePlanSelectionMismatch }
    $liveContext = Get-LiveSyncTargetContext -Path ([System.IO.Path]::GetFullPath([string] $liveRootsByPlatform[$platform]))
    $initialState = if ([string] $liveContext.TargetStatus -ceq 'EXISTS') { 'EXISTS' } else { 'ABSENT' }
    $observedRows.Add((New-LiveSyncRootClaimRow -Platform $platform -Context $liveContext -InitialState $initialState))
}
$claimRows = @([object[]] $claimsDocument['LiveRootClaims'])
if ($claimRows.Count -ne 3) { throw $script:LivePlanSelectionMismatch }
for ($index = 0; $index -lt $claimRows.Count; $index++) {
    $claimRow = $claimRows[$index]
    if ([string] $claimRow['InitialState'] -cne 'EXISTS') { continue }
    $observedRow = $observedRows[$index]
    if ([string] $observedRow.Platform -cne [string] $claimRow['Platform'] -or
        [string] $observedRow.InitialState -cne 'EXISTS' -or
        [string] $observedRow.RequestedPath -cne [string] $claimRow['RequestedPath'] -or
        [string] $observedRow.InitialDirectoryIdentity -cne [string] $claimRow['InitialDirectoryIdentity']) {
        throw 'authority-claim-identity-drift'
    }
}

$git = Get-CanonicalGitContext -RepoRoot $repo
$controllerFingerprint = Get-CanonicalControllerIdentity -GitContext $git
$toolchainHash = Get-LiveSyncApprovedToolchainHash -RepoRoot $repo
$controlContext = Get-LiveSyncTargetContext -Path $controlBaseFull
$build = [System.Collections.IDictionary] $materialization['Build']

$managedNames = [ordered]@{
    Claude = (Read-ManagedNames -Path (Join-Path $repo 'manifests\managed-skills.claude.txt'))
    Codex = (Read-ManagedNames -Path (Join-Path $repo 'manifests\managed-skills.codex.txt'))
    Reasonix = (Read-ManagedNames -Path (Join-Path $repo 'manifests\managed-skills.reasonix.txt'))
}
$manifestHashes = [ordered]@{
    Claude = (Get-PathSha256 -Path (Join-Path $repo 'manifests\managed-skills.claude.txt'))
    Codex = (Get-PathSha256 -Path (Join-Path $repo 'manifests\managed-skills.codex.txt'))
    Reasonix = (Get-PathSha256 -Path (Join-Path $repo 'manifests\managed-skills.reasonix.txt'))
}

$orderedActions = [System.Collections.Generic.List[object]]::new()
$slots = [System.Collections.Generic.List[object]]::new()
$unknownMarkers = [System.Collections.Generic.List[object]]::new()
$order = 0L
foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
    $key = $platform.ToLowerInvariant()
    $stagedHashes = [System.Collections.IDictionary] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $build -Name 'StagedSkillTreeHashes') -Name $platform)
    $stagedSourceBase = Join-Path ([string] $materialization['Path']) "$key/skills"
    foreach ($skillName in (@([string[]] $stagedHashes.Keys) | Sort-Object { [string] $_ })) {
        $sourceHash = [string] (Get-SafeTreeSnapshot -Root (Join-Path $stagedSourceBase $skillName)).TreeHash
        if ($sourceHash -cnotmatch '\A[0-9a-f]{64}\z') { throw $script:LiveSyncUnsupportedApplyKind }
        # The observed live pre-state is part of the reviewed action: an
        # existing managed target binds its current tree hash and is updated,
        # an absent one binds null and is added.
        $liveSkillPath = Join-Path ([string] $liveRootsByPlatform[$platform]) $skillName
        $liveHash = $null
        $verb = 'add'
        if (Test-Path -LiteralPath $liveSkillPath -PathType Container) {
            $liveHash = [string] (Get-SafeTreeSnapshot -Root $liveSkillPath).TreeHash
            if ($liveHash -cnotmatch '\A[0-9a-f]{64}\z') { throw $script:LiveSyncUnsupportedApplyKind }
            $verb = 'update'
        }
        $orderedActions.Add([ordered]@{
            Order = $order
            Platform = $platform
            Action = $verb
            Name = $skillName
            SourceHash = $sourceHash
            LiveHash = $liveHash
        })
        $order++
    }
    $slots.Add((New-LiveSyncPlatformSlot -Platform $platform -SourceRoot $stagedSourceBase -LiveRoot ([string] $liveRootsByPlatform[$platform]) -ManagedNames $managedNames[$platform] -ManifestHash $manifestHashes[$platform]))
    foreach ($marker in @(Get-LiveSyncUnknownMarkers -Platform $platform -LiveRoot ([string] $liveRootsByPlatform[$platform]) -ManagedNames $managedNames[$platform])) {
        $unknownMarkers.Add($marker)
    }
}

$materializationRoot = [ordered]@{
    Path = [string] $materialization['Path']
    Identity = [string] $materialization['Identity']
    EnvBuildPath = [string] $materialization['EnvBuildPath']
    EnvBuildHash = [string] $materialization['EnvBuildHash']
    EnvLockPath = [string] $materialization['EnvLockPath']
    EnvLockHash = [string] $materialization['EnvLockHash']
    MaterializationHash = [string] $materialization['MaterializationHash']
}

$overlaySkillsRows = Get-LiveSyncPlatformTriple -Map (Get-HarnessJsonProperty -Object $build -Name 'TaskOverlaySkills') -Kind 'Skills'
$intent = [ordered]@{
    SchemaVersion = 3
    ArtifactKind = 'current-env-state'
    HomeAuthorityKey = [string] $authorityContext.HomeAuthorityKey
    AuthorityGeneration = ([long] $authorityState.StateDocument['AuthorityGeneration'] + 1)
    RootClaimsHash = $claimsHash
    SelectionKind = 'environment'
    EnvironmentName = $Name
    EnvironmentLockHash = [string] $materialization['EnvLockHash']
    TaskOverlayHash = (Get-LiveSyncTaskOverlayHash -OverlayHash ([string] (Get-HarnessJsonProperty -Object $build -Name 'TaskOverlayHash')) -TaskOverlaySkillsRows $overlaySkillsRows)
    TaskOverlaySkills = $overlaySkillsRows
    ManifestHashes = (Get-LiveSyncPlatformTriple -Map (Get-HarnessJsonProperty -Object $build -Name 'ManifestHashes') -Kind 'Hash')
    FinalManagedHashes = @(
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            [ordered]@{
                Platform = $platform
                Hash = [string] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $build -Name 'MaterializedRoots') -Name $platform) -Name 'TreeHash')
            }
        }
    )
    ControllerRepoFingerprint = $controllerFingerprint
    ApprovedToolchainHash = $toolchainHash
    LastOperationKind = 'environment'
}

$payload = [ordered]@{
    OperationKind = 'environment'
    Generator = $script:ActivationGeneratorName
    RepositoryCommit = [string] $git.RepositoryCommit
    RepoRoot = $repo
    ApprovedToolchainHash = $toolchainHash
    ControllerRepoFingerprint = $controllerFingerprint
    ControlBaseIntent = (New-LiveSyncControlBaseIntent -Context $controlContext)
    Platforms = @($slots)
    OrderedActions = @($orderedActions)
    UnknownMarkers = @($unknownMarkers)
    SystemMarker = (Get-LiveSyncSystemMarker -CodexLiveRoot ([string] $liveRootsByPlatform['Codex']))
    TargetContextIntent = [ordered]@{ HomeAuthorityKey = [string] $authorityContext.HomeAuthorityKey; Rows = @($observedRows) }
    AuthorityStateIntent = $intent
    EnvironmentName = $Name
    EnvironmentMaterializationRoot = $materializationRoot
}

$document = [ordered]@{
    SchemaVersion = 3
    ArtifactKind = 'sync-plan'
    Metadata = [ordered]@{ GeneratedAtUtc = [DateTime]::UtcNow.ToString('o') }
    PlanPayload = $payload
}
$document['PlanHash'] = Get-PlanHash -PlanPayload $payload
$document['DocumentHash'] = Get-DocumentHash -Document $document
Assert-LiveSyncPlanDocumentIntegrity -Document $document

Write-LiveSyncPlan -Path $planFull -Document $document
Write-PlanSummary -Payload $payload
Write-Host "Plan path       : $planFull"
Write-Host "Materialization : $materializationPath"
Write-Host "Plan hash       : $([string] $document['PlanHash'])"
Write-Host "Document hash   : $([string] $document['DocumentHash'])"
Write-Host ''
Write-Host 'DRY-RUN complete. No live file and no authority state were changed. Review the schema 3 plan, then rerun with -Apply -PlanPath <the same path>.'
Write-ActivationSummary -Result 'DRY-RUN' -BackupReference $null -LockResult $materializationLock -PlanDocument ([System.Collections.IDictionary] $document) -PlanFullPath $planFull
exit 0
