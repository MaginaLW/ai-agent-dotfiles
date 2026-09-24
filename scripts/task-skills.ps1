#requires -Version 7.0
<##
.SYNOPSIS
    Plan-bound management of the repository-shared task skill overlay.

.DESCRIPTION
    A task overlay is a small, tracked `.agent-harness/task-skills.psd1` file.
    This CLI is a reviewed plan producer plus a plan consumer; it never copies
    or removes a live skill directory directly and it never generates a plan for
    an -Apply.

    `ensure-skill`, `sync`, and `close` are always invoked with exactly one
    explicit mode:

    * `-DryRun -PlanPath <new-external-plan.json>` runs the mandatory gates -
    the three-platform Claude/Codex/Reasonix baseline admission (the shared
    authority state plus the materialization lock; a missing or legacy schema 2
    baseline is a migration-required or manual-review-required refusal,
    never an empty addition-only
    overlay), the create-new environment materialization and its frozen schema 3
    lock, the repository/controller/claims binding, and the full plan semantics.
    It then writes ONE external create-new `OperationKind=task-overlay` plan
    plus the exact candidate overlay artifact next to it. The plan carries the
    current/candidate overlay hashes, the materialization and lock it binds, the
    planned live actions, the authority binding, and whether removals/prunes
    require manual review.

    * `-Apply -PlanPath <the-same-plan.json>` consumes only that exact existing
    plan. The production interlock is the first gate; then the plan path rules,
    the document integrity, the kind/generator, the materialization currency,
    the requested base environment, the controller identity, the tracked
    overlay pre-state, the document-hash consumption gate, the canonical
    setup/authority gates, the per-platform capability probes, and finally the
    shared live transaction host, which journals the tracked overlay file as a
    planned atomic file target together with the live/state changes.

    The legacy `-Automatic` switch and the `-SkipBuild`/`-SkipSecretScan` public
    skip gates are refused: no preview or apply may be routed or shortened by
    them, and Git hooks only ever emit non-consumable previews plus an explicit
    external DryRun command.

.PARAMETER Action
    status | ensure-skill | sync | close.

.PARAMETER SkillName
    The skill to add for `ensure-skill` (must be managed and generated).

.PARAMETER Platform
    The platform the `ensure-skill` addition targets.

.PARAMETER BaseEnv
    The environment whose overlay is managed (bare identifier).

.PARAMETER DryRun
    Produce and write the external plan. Never mutates a live skill, the
    authority state, or the tracked overlay.

.PARAMETER Apply
    Consume the exact existing plan at -PlanPath.

.PARAMETER PlanPath
    External plan path (outside the worktree, Git internals, live roots, and
    safety roots). Required in both modes.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory for live paths. Either all of -HomeRoot/-ControlBase/
    -BackupRoot are supplied together or none are, in which case the approved
    internal sandbox host injects all three.

.PARAMETER ControlBase
    The private authority control base holding `homes/<key>`. See -HomeRoot.

.PARAMETER BackupRoot
    The receipt/backup root. See -HomeRoot.

.OUTPUTS
    Human-readable status, gate, plan, and transaction output. Exit 0 on
    success, non-zero on any gate failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'ensure-skill', 'sync', 'close')]
    [string] $Action,

    [Parameter(Position = 1)]
    [string] $SkillName,

    [ValidateSet('Claude', 'Codex', 'Reasonix')]
    [string] $Platform = 'Codex',

    [string] $BaseEnv = 'work',
    [switch] $Apply,
    [switch] $DryRun,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $PlanPath,
    [string] $HomeRoot,
    [string] $ControlBase,
    [string] $BackupRoot,
    [string] $TaskOverlayPath,
    # Legacy spellings only: they select nothing and are refused after the
    # interlock, so no caller can shorten or reroute a reviewed task operation.
    [switch] $Automatic,
    [switch] $SkipBuild,
    [switch] $SkipSecretScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$script:TaskGeneratorName = 'scripts/task-skills.ps1'
$script:TaskPlanPathRequired = ('task-overlay-' + 'plan-path-required')
$script:TaskSkipSwitchForbidden = ('task-overlay-' + 'skip-switch-forbidden')
$script:TaskAutomaticRemoved = ('task-overlay-' + 'automatic-removed')
$script:TaskOverlayPathUnsupported = ('task-overlay-' + 'path-unsupported')
$script:TaskBaselineMigrationRequired = ('task-overlay-' + 'baseline-migration-required')
$script:TaskBaselineManualReviewRequired = ('task-overlay-' + 'baseline-manual-review-required')
$script:TaskLockBaselineIncomplete = ('task-overlay-' + 'lock-baseline-incomplete')
$script:TaskOverlayFileMissing = ('task-overlay-' + 'file-missing')
$script:TaskPlanKindMismatch = ('task-overlay-' + 'plan-kind-mismatch')
$script:TaskOverlayCurrentMismatch = ('task-overlay-' + 'current-mismatch')
$script:TaskOverlayCandidateMismatch = ('task-overlay-' + 'candidate-mismatch')
$script:TaskControllerMismatch = ('task-overlay-' + 'controller-mismatch')
$script:TaskMaterializationInvalid = ('task-overlay-' + 'materialization-invalid')
$script:TaskPlatforms = @('Claude', 'Codex', 'Reasonix')

. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')

# The production interlock is the first gate of every -Apply: outside the
# approved internal sandbox it refuses with the policy token before any gate,
# traversal, plan consumption, or host composition.
if ($Apply) {
    $interlockPaths = @($RepoRoot, $HomeRoot, $ControlBase, $BackupRoot, $PlanPath, $TaskOverlayPath)
    if (Test-LiveSafetySandboxCapability) {
        foreach ($variableName in @('AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT', 'AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT', 'AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE')) {
            $value = [System.Environment]::GetEnvironmentVariable($variableName)
            if (-not [string]::IsNullOrWhiteSpace($value)) { $interlockPaths += $value }
        }
    }
    $interlockPaths = @($interlockPaths) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } | ForEach-Object { [System.IO.Path]::GetFullPath([string] $_) }
    Assert-LiveSafetyMutationAllowed -Operation "task-$Action" -Paths @($interlockPaths)
}

. (Join-Path $PSScriptRoot 'harness-env-common.ps1')
. (Join-Path $PSScriptRoot 'live-plan-common.ps1')
. (Join-Path $PSScriptRoot 'live-plan-evidence-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'harness-authority-status-common.ps1')
. (Join-Path $PSScriptRoot 'home-authority-common.ps1')
. (Join-Path $PSScriptRoot 'root-claims-registry-common.ps1')
. (Join-Path $PSScriptRoot 'live-transaction-common.ps1')

function Sort-TaskSkillNames {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Values)

    [string[]] $sorted = @($Values | ForEach-Object { [string] $_ })
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return @($sorted)
}

function Quote-TaskPsd1String {
    param([Parameter(Mandatory)] [string] $Value)
    return "'$(($Value -replace "'", "''"))'"
}

function ConvertTo-TaskSkillOverlayText {
    param([Parameter(Mandatory)] [hashtable] $Data)

    $claude = @(Sort-TaskSkillNames -Values @($Data.Skills.Claude))
    $codex = @(Sort-TaskSkillNames -Values @($Data.Skills.Codex))
    $reasonix = @(Sort-TaskSkillNames -Values @($Data.Skills.Reasonix))
    $claudeText = if ($claude.Count -eq 0) { '@()' } else { '@(' + (($claude | ForEach-Object { Quote-TaskPsd1String -Value $_ }) -join ', ') + ')' }
    $codexText = if ($codex.Count -eq 0) { '@()' } else { '@(' + (($codex | ForEach-Object { Quote-TaskPsd1String -Value $_ }) -join ', ') + ')' }
    $reasonixText = if ($reasonix.Count -eq 0) { '@()' } else { '@(' + (($reasonix | ForEach-Object { Quote-TaskPsd1String -Value $_ }) -join ', ') + ')' }
    return @"
@{
    SchemaVersion = 1
    BaseEnv = $(Quote-TaskPsd1String -Value ([string] $Data.BaseEnv))
    Skills = @{
        Claude = $claudeText
        Codex = $codexText
        Reasonix = $reasonixText
    }
}
"@
}

function New-TaskOverlayData {
    param(
        [Parameter(Mandatory)] [string] $BaseEnvName,
        [AllowEmptyCollection()] [object[]] $ClaudeSkills = @(),
        [AllowEmptyCollection()] [object[]] $CodexSkills = @(),
        [AllowEmptyCollection()] [object[]] $ReasonixSkills = @()
    )

    return @{
        SchemaVersion = 1
        BaseEnv = $BaseEnvName
        Skills = @{
            Claude = @(Sort-TaskSkillNames -Values $ClaudeSkills)
            Codex = @(Sort-TaskSkillNames -Values $CodexSkills)
            Reasonix = @(Sort-TaskSkillNames -Values $ReasonixSkills)
        }
    }
}

# ---------------------------------------------------------------------------
# Context: repository, tracked overlay, base definition, authority roots
# ---------------------------------------------------------------------------

function Get-TaskOverlayPath {
    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path $repo '.agent-harness') 'task-skills.psd1'))
}

function Initialize-TaskAuthorityRoots {
    # Either the caller supplies the complete root trio or the approved internal
    # sandbox host injects all three; a partial selection is refused instead of
    # silently mixing a caller root with an injected one. Unlike activation the
    # task CLI always resolves the roots: the baseline admission gates read the
    # shared authority state even in a preview.
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
        throw ('task-overlay-' + 'root-selection-incomplete: supply -HomeRoot, -ControlBase, and -BackupRoot together, or none so the approved sandbox host injects them.')
    }

    $repoFull = [System.IO.Path]::GetFullPath($repo)
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

function Get-TaskContext {
    $definitionPath = Join-Path (Get-HarnessEnvRoot -RepoRoot $repo) "$BaseEnv.psd1"
    if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
        throw "Unknown base environment '$BaseEnv': expected definition at $definitionPath"
    }
    $definition = Read-HarnessEnvDefinition -Path $definitionPath
    $overlay = Read-HarnessTaskSkillOverlay -RepoRoot $repo -Path (Get-TaskOverlayPath)
    if ($overlay.Present -and -not [string]::Equals($overlay.BaseEnv, $BaseEnv, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Task overlay targets '$($overlay.BaseEnv)', but this task command targets '$BaseEnv'. Close or replace the overlay before continuing."
    }
    if (-not $overlay.Present) { throw ($script:TaskOverlayFileMissing + ": the tracked overlay is absent; restore it from Git before continuing: $(Get-TaskOverlayPath)") }
    $effectiveDefinition = Merge-HarnessTaskSkillOverlay -Definition $definition -Overlay $overlay
    $null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $effectiveDefinition
    return [pscustomobject]@{
        Definition = $definition
        EffectiveDefinition = $effectiveDefinition
        Overlay = $overlay
        OverlayPath = Get-TaskOverlayPath
        DefinitionPath = $definitionPath
    }
}

function Get-TaskManagedSkillSet {
    param([Parameter(Mandatory)] [ValidateSet('Claude', 'Codex', 'Reasonix')] [string] $TargetPlatform)

    $manifestPath = Join-Path $repo "manifests/managed-skills.$($TargetPlatform.ToLowerInvariant()).txt"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing managed $TargetPlatform skill manifest: $manifestPath"
    }
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        $name = ([string] $line).Trim()
        if ($name) { [void] $set.Add($name) }
    }
    return $set
}

function Assert-TaskSkillAvailable {
    param(
        [Parameter(Mandatory)] [ValidateSet('Claude', 'Codex', 'Reasonix')] [string] $TargetPlatform,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Name -ieq '.system') {
        throw "Skill name must be a safe bare identifier: $Name"
    }
    $managed = Get-TaskManagedSkillSet -TargetPlatform $TargetPlatform
    if (-not $managed.Contains($Name)) {
        throw "Skill '$Name' is not managed for $TargetPlatform. Only manifest/source skills may be added."
    }
    $sourceHash = Get-HarnessSkillSourceHash -RepoRoot $repo -Platform $TargetPlatform -Name $Name
    if ($null -eq $sourceHash) {
        throw "Skill '$Name' has no repository source for $TargetPlatform. Quarantined/import-only content cannot be added."
    }
    $generatedRoot = switch ($TargetPlatform) {
        'Claude' { 'claude/skills' }
        'Codex' { 'codex/skills' }
        'Reasonix' { 'reasonix/skills' }
    }
    $generatedPath = Join-Path $repo "$generatedRoot/$Name"
    if (-not (Test-Path -LiteralPath $generatedPath -PathType Container)) {
        throw "Skill '$Name' has no generated output at $generatedPath. Run scripts/build-skills.ps1 first."
    }
}

# ---------------------------------------------------------------------------
# Three-platform baseline admission (Phase 3 Task 7 step 2)
# ---------------------------------------------------------------------------

function Get-TaskOverlayStateDocument {
    # Reads the shared authority state bytes for the baseline admission without
    # inventing an artifact: the exact bytes hash and the raw document are
    # returned, and a legacy schema 2 document is reported as LEGACY instead of
    # being treated as an empty baseline.
    param([Parameter(Mandatory)] $AuthorityContext)

    $statePath = [string] (Get-LiveTransactionStatePaths -ControlBase ([string] $AuthorityContext.ControlBase) -HomeAuthorityKey ([string] $AuthorityContext.HomeAuthorityKey))['StatePath']
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'MISSING'; Path = $statePath; Hash = $null; Document = $null }
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($statePath)
        $document = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($bytes))
    }
    catch {
        return [pscustomobject]@{ Status = 'INCOMPLETE'; Path = $statePath; Hash = $null; Document = $null }
    }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($document -isnot [System.Collections.IDictionary]) {
        return [pscustomobject]@{ Status = 'INCOMPLETE'; Path = $statePath; Hash = $hash; Document = $null }
    }
    if ([string] $document['SchemaVersion'] -ceq '2') {
        return [pscustomobject]@{ Status = 'LEGACY'; Path = $statePath; Hash = $hash; Document = $document }
    }
    $triple = $document['TaskOverlaySkills']
    if ($triple -isnot [System.Collections.IDictionary] -and $triple -isnot [System.Array]) {
        return [pscustomobject]@{ Status = 'INCOMPLETE'; Path = $statePath; Hash = $hash; Document = $document }
    }
    foreach ($platform in $script:TaskPlatforms) {
        if (-not (Get-TaskOverlayPlatformBaseline -Triple $triple -Platform $platform).Present) {
            return [pscustomobject]@{ Status = 'INCOMPLETE'; Path = $statePath; Hash = $hash; Document = $document }
        }
    }
    return [pscustomobject]@{ Status = 'COMPLETE'; Path = $statePath; Hash = $hash; Document = $document }
}

function Get-TaskOverlayPlatformBaseline {
    # The state artifact stores the baseline as the frozen platformSkills triple
    # (one {Platform,Skills} row per platform), the materialized lock stores it
    # as a three-key map. Both reviewed spellings are accepted; anything else is
    # a missing baseline, never an empty one.
    param($Triple, [Parameter(Mandatory)] [string] $Platform)

    $absent = [pscustomobject]@{ Present = $false; Values = @() }
    if ($null -eq $Triple) { return $absent }
    # The materialized lock carries the baseline as a three-key map, the state
    # artifact as the frozen {Platform,Skills} triple; both reviewed spellings
    # are accepted and anything else is a missing baseline, never an empty one.
    if ($Triple -is [System.Collections.IDictionary]) {
        if (-not $Triple.Contains($Platform)) { return $absent }
        return [pscustomobject]@{ Present = $true; Values = @($Triple[$Platform]) }
    }
    $direct = $Triple.PSObject.Properties[$Platform]
    if ($null -ne $direct) {
        # The strict semantic reader collapses an empty JSON array to $null:
        # a present but empty baseline is an empty list, never a missing row.
        $directValues = $direct.Value
        if ($null -eq $directValues) { $directValues = @() }
        return [pscustomobject]@{ Present = $true; Values = @($directValues) }
    }
    foreach ($row in @($Triple)) {
        if ($row -is [System.Collections.IDictionary]) {
            if (-not $row.Contains('Platform') -or [string] $row['Platform'] -cne $Platform) { continue }
            if (-not $row.Contains('Skills')) { return $absent }
            return [pscustomobject]@{ Present = $true; Values = @($row['Skills']) }
        }
        $rowProperties = @($row.PSObject.Properties | ForEach-Object { [string] $_.Name })
        if ($rowProperties -cnotcontains 'Platform' -or [string] $row.Platform -cne $Platform) { continue }
        if ($rowProperties -cnotcontains 'Skills') { return $absent }
        $rowSkills = $row.Skills
        if ($null -eq $rowSkills) { $rowSkills = @() }
        return [pscustomobject]@{ Present = $true; Values = @($rowSkills) }
    }
    return $absent
}

function Get-TaskOverlayBaselineMaps {
    # The committed per-platform overlay baseline of the shared authority state.
    # Every one of Claude/Codex/Reasonix must be present; a legacy schema 2 state
    # (which lacks the Reasonix baseline) is a migration, and a shared state
    # without the complete triple is a manual review - never an addition-only
    # overlay over an empty baseline.
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)

    $maps = [ordered]@{}
    foreach ($platform in $script:TaskPlatforms) {
        $values = @((Get-TaskOverlayPlatformBaseline -Triple $Document['TaskOverlaySkills'] -Platform $platform).Values)
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($value in $values) { [void] $set.Add([string] $value) }
        $maps[$platform] = $set
    }
    return $maps
}

function Assert-TaskOverlayThreePlatformBaseline {
    # The mandatory admission gate: the shared authority state must carry the
    # complete three-platform baseline, and the legacy repo-local schema 2
    # evidence must not be the only baseline this machine has.
    param([Parameter(Mandatory)] $AuthorityContext)

    $legacy = Read-LegacyHarnessEnvState -RepoRoot $repo
    $state = Get-TaskOverlayStateDocument -AuthorityContext $AuthorityContext
    if ([string] $state.Status -ceq 'LEGACY') {
        throw ($script:TaskBaselineMigrationRequired + ": the repo-local legacy schema 2 state is not a task baseline; run the reviewed migrate transition before changing the task overlay.")
    }
    if ([string] $state.Status -ne 'COMPLETE') {
        $legacyNote = if ([string] $legacy.Status -cne 'MISSING') { "; legacy evidence is $($legacy.Status)" } else { '' }
        throw ($script:TaskBaselineManualReviewRequired + ": the shared authority has no complete three-platform task baseline ($($state.Status)$legacyNote); every platform baseline must be present before a task overlay change.")
    }
    $pair = Read-HomeAuthorityState -ControlBase ([string] $AuthorityContext.ControlBase) -HomeAuthorityKey ([string] $AuthorityContext.HomeAuthorityKey) -RepoRoot $repo
    if ([string] $pair.PairStatus -cne 'VALID') {
        throw ($script:TaskBaselineManualReviewRequired + ": the authority state/claims pair is $($pair.PairStatus).")
    }
    return Get-TaskOverlayBaselineMaps -Document ([System.Collections.IDictionary] $state.Document)
}

function Assert-TaskLockBaseline {
    # The materialization lock is the second half of the three-platform baseline
    # requirement: the lock the plan binds must carry the Claude/Codex/Reasonix
    # task-overlay baseline rows too.
    param([Parameter(Mandatory)] $Lock)

    $triple = Get-HarnessJsonProperty -Object $Lock -Name 'TaskOverlaySkills'
    if ($null -eq $triple) { throw ($script:TaskLockBaselineIncomplete + ': the materialized lock carries no task-overlay baseline.') }
    foreach ($platform in $script:TaskPlatforms) {
        if (-not (Get-TaskOverlayPlatformBaseline -Triple $triple -Platform $platform).Present) {
            throw ($script:TaskLockBaselineIncomplete + ": the materialized lock has no $platform task-overlay baseline.")
        }
    }
    return (Get-TaskOverlayBaselineMaps -Document ([ordered]@{ TaskOverlaySkills = $triple }))
}

# ---------------------------------------------------------------------------
# Overlay candidates and planned actions
# ---------------------------------------------------------------------------

function Get-TaskOverlayCandidateData {
    # The candidate overlay document for one action. `close` writes the empty
    # overlay document for the base environment (the tracked file stays in Git
    # as an explicit, reviewable removal of every addition) and never deletes
    # the file, so the file target machine always has exact candidate bytes.
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Tracked,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Definition
    )

    $claude = @([string[]] @($Tracked['Claude']))
    $codex = @([string[]] @($Tracked['Codex']))
    $reasonix = @([string[]] @($Tracked['Reasonix']))
    switch ($Action) {
        'ensure-skill' {
            if ([string]::IsNullOrWhiteSpace($SkillName)) {
                throw 'ensure-skill requires a skill name: env task ensure-skill <name> -Platform Codex -DryRun'
            }
            Assert-TaskSkillAvailable -TargetPlatform $Platform -Name $SkillName
            $baseNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($name in @($Definition.Skills[$Platform])) { [void] $baseNames.Add([string] $name) }
            if ($baseNames.Contains($SkillName)) { throw "Skill '$SkillName' is already part of base environment '$BaseEnv'; no overlay change is needed." }
            if ($Platform -eq 'Claude') { if ($claude -ccontains $SkillName) { throw "Skill '$SkillName' is already present in the task overlay." }; $claude += $SkillName }
            elseif ($Platform -eq 'Codex') { if ($codex -ccontains $SkillName) { throw "Skill '$SkillName' is already present in the task overlay." }; $codex += $SkillName }
            else { if ($reasonix -ccontains $SkillName) { throw "Skill '$SkillName' is already present in the task overlay." }; $reasonix += $SkillName }
        }
        'sync' { }
        'close' { $claude = @(); $codex = @(); $reasonix = @() }
        default { throw "Unsupported task action: $Action" }
    }
    return New-TaskOverlayData -BaseEnvName $BaseEnv -ClaudeSkills $claude -CodexSkills $codex -ReasonixSkills $reasonix
}

function Get-TaskOverlayRemovalMap {
    # The committed baseline names that the candidate drops: these are the live
    # additions a reviewed plan would prune, so every one of them flips the
    # plan's removal-review flag. The maps are never treated as empty when the
    # baseline is missing - the admission gate refuses that state.
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $BaselineMaps, [Parameter(Mandatory)] [hashtable] $Candidate)

    $removed = [ordered]@{}
    foreach ($platform in $script:TaskPlatforms) {
        $set = [System.Collections.Generic.List[string]]::new()
        $candidateNames = [System.Collections.Generic.HashSet[string]]::new([string[]] @([string[]] @($Candidate.Skills[$platform])), [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($BaselineMaps[$platform])) {
            if (-not $candidateNames.Contains([string] $name)) { $set.Add([string] $name) }
        }
        $removed[$platform] = @($set | Sort-Object)
    }
    return $removed
}

function New-TaskOverlayPlanPayload {
    # Builds the reviewed task-overlay plan payload from current evidence only:
    # the materialized lock the candidate was built with, the current tracked
    # overlay bytes, the fresh live observations, and the authority binding.
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Materialization,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $BaselineMaps,
        [Parameter(Mandatory)] [hashtable] $Candidate,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Removed,
        [Parameter(Mandatory)] [string] $CurrentOverlayHash,
        [Parameter(Mandatory)] [string] $CandidateHash,
        [Parameter(Mandatory)] $Git,
        [Parameter(Mandatory)] [string] $ControllerFingerprint,
        [Parameter(Mandatory)] [string] $ToolchainHash,
        [Parameter(Mandatory)] $AuthorityContext,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $StateDocument,
        [Parameter(Mandatory)] [string] $ClaimsHash
    )

    $liveRootsByPlatform = [ordered]@{}
    $observedRows = [System.Collections.Generic.List[object]]::new()
    $claimsDocument = [System.Collections.IDictionary] $null
    $pair = Read-HomeAuthorityState -ControlBase ([string] $AuthorityContext.ControlBase) -HomeAuthorityKey ([string] $AuthorityContext.HomeAuthorityKey) -RepoRoot $repo
    $claimsDocument = [System.Collections.IDictionary] $pair.ClaimsDocument
    foreach ($claimRow in @([object[]] $claimsDocument['LiveRootClaims'])) {
        $liveRootsByPlatform[[string] $claimRow['Platform']] = [string] $claimRow['RequestedPath']
    }
    foreach ($platform in $script:TaskPlatforms) {
        if (-not $liveRootsByPlatform.Contains($platform)) { throw $script:LivePlanSelectionMismatch }
        $liveContext = Get-LiveSyncTargetContext -Path ([System.IO.Path]::GetFullPath([string] $liveRootsByPlatform[$platform]))
        if ([string] $liveContext.TargetStatus -cne 'EXISTS') { throw $script:LivePlanSelectionMismatch }
        $observedRows.Add((New-LiveSyncRootClaimRow -Platform $platform -Context $liveContext -InitialState 'EXISTS'))
    }
    $claimRows = @([object[]] $claimsDocument['LiveRootClaims'])
    for ($index = 0; $index -lt 3; $index++) {
        $claimRow = $claimRows[$index]
        # A claim binds only the roots that already existed when it was
        # published; a root created afterwards has no recorded identity to
        # drift from. Activation and authority status read the same claim.
        if ([string] $claimRow['InitialState'] -cne 'EXISTS') { continue }
        $observedRow = $observedRows[$index]
        if ([string] $observedRow.RequestedPath -cne [string] $claimRow['RequestedPath'] -or
            [string] $observedRow.InitialDirectoryIdentity -cne [string] $claimRow['InitialDirectoryIdentity']) {
            throw 'authority-claim-identity-drift'
        }
    }

    $managedNames = [ordered]@{}
    $manifestHashes = [ordered]@{}
    foreach ($platform in $script:TaskPlatforms) {
        $key = $platform.ToLowerInvariant()
        $managedNames[$platform] = Read-ManagedNames -Path (Join-Path $repo "manifests/managed-skills.$key.txt")
        $manifestHashes[$platform] = Get-PathSha256 -Path (Join-Path $repo "manifests/managed-skills.$key.txt")
    }

    $build = [System.Collections.IDictionary] $Materialization['Build']
    $orderedActions = [System.Collections.Generic.List[object]]::new()
    $slots = [System.Collections.Generic.List[object]]::new()
    $unknownMarkers = [System.Collections.Generic.List[object]]::new()
    $plannedTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($platform in $script:TaskPlatforms) {
        $key = $platform.ToLowerInvariant()
        $stagedHashes = [System.Collections.IDictionary] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $build -Name 'StagedSkillTreeHashes') -Name $platform)
        $stagedSourceBase = Join-Path ([string] $Materialization['Path']) "$key/skills"
        $liveRoot = [string] $liveRootsByPlatform[$platform]
        foreach ($skillName in (@([string[]] $stagedHashes.Keys) | Sort-Object { [string] $_ })) {
            $sourceHash = [string] (Get-SafeTreeSnapshot -Root (Join-Path $stagedSourceBase $skillName)).TreeHash
            if ($sourceHash -cnotmatch '\A[0-9a-f]{64}\z') { throw $script:LiveSyncUnsupportedApplyKind }
            $liveSkillPath = Join-Path $liveRoot $skillName
            $liveHash = $null
            $verb = 'add'
            if (Test-Path -LiteralPath $liveSkillPath -PathType Container) {
                $liveHash = [string] (Get-SafeTreeSnapshot -Root $liveSkillPath).TreeHash
                $verb = 'update'
            }
            $orderedActions.Add([ordered]@{
                Order = [long] $orderedActions.Count
                Platform = $platform
                Action = $verb
                Name = $skillName
                SourceHash = $sourceHash
                LiveHash = $liveHash
            })
            $null = $plannedTargets.Add("$platform/$skillName")
        }
        # The committed baseline names the candidate drops are planned prunes:
        # the live directory must still exist and be managed, and the plan marks
        # them for manual review.
        foreach ($removedName in @([string[]] $Removed[$platform])) {
            if ($plannedTargets.Contains("$platform/$removedName")) { continue }
            $liveSkillPath = Join-Path $liveRoot $removedName
            if (-not (Test-Path -LiteralPath $liveSkillPath -PathType Container)) { continue }
            if (-not $managedNames[$platform].Contains($removedName)) { throw "Removed overlay skill '$removedName' is not managed for $platform." }
            $orderedActions.Add([ordered]@{
                Order = [long] $orderedActions.Count
                Platform = $platform
                Action = 'prune'
                Name = $removedName
                SourceHash = $null
                LiveHash = [string] (Get-SafeTreeSnapshot -Root $liveSkillPath).TreeHash
                Authority = 'managed-manifest'
            })
        }
        $slots.Add((New-LiveSyncPlatformSlot -Platform $platform -SourceRoot $stagedSourceBase -LiveRoot $liveRoot -ManagedNames $managedNames[$platform] -ManifestHash $manifestHashes[$platform]))
        foreach ($marker in @(Get-LiveSyncUnknownMarkers -Platform $platform -LiveRoot $liveRoot -ManagedNames $managedNames[$platform])) {
            $unknownMarkers.Add($marker)
        }
    }
    # The plan semantics require one deterministic order: platform rank, then
    # ordinal name.
    $rank = @{ Claude = 0; Codex = 1; Reasonix = 2 }
    $sortedActions = @($orderedActions | Sort-Object -Property @{ Expression = { $rank[[string] $_.Platform] } }, @{ Expression = { [string] $_.Name } })
    for ($index = 0; $index -lt $sortedActions.Count; $index++) {
        $sortedActions[$index]['Order'] = [long] $index
    }

    $overlaySkillsRows = Get-LiveSyncPlatformTriple -Map (Get-HarnessJsonProperty -Object $build -Name 'TaskOverlaySkills') -Kind 'Skills'
    $intent = [ordered]@{
        SchemaVersion = 3
        ArtifactKind = 'current-env-state'
        HomeAuthorityKey = [string] $AuthorityContext.HomeAuthorityKey
        AuthorityGeneration = ([long] $StateDocument['AuthorityGeneration'] + 1)
        RootClaimsHash = $ClaimsHash
        SelectionKind = 'environment'
        EnvironmentName = $BaseEnv
        EnvironmentLockHash = [string] $Materialization['EnvLockHash']
        TaskOverlayHash = (Get-LiveSyncTaskOverlayHash -OverlayHash ([string] (Get-HarnessJsonProperty -Object $build -Name 'TaskOverlayHash')) -TaskOverlaySkillsRows $overlaySkillsRows)
        TaskOverlaySkills = $overlaySkillsRows
        ManifestHashes = (Get-LiveSyncPlatformTriple -Map (Get-HarnessJsonProperty -Object $build -Name 'ManifestHashes') -Kind 'Hash')
        FinalManagedHashes = @(
            foreach ($platform in $script:TaskPlatforms) {
                [ordered]@{
                    Platform = $platform
                    Hash = [string] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $build -Name 'MaterializedRoots') -Name $platform) -Name 'TreeHash')
                }
            }
        )
        ControllerRepoFingerprint = $ControllerFingerprint
        ApprovedToolchainHash = $ToolchainHash
        LastOperationKind = 'task-overlay'
    }

    $removalReview = $false
    foreach ($platform in $script:TaskPlatforms) {
        if (@([string[]] $Removed[$platform]).Count -gt 0) { $removalReview = $true }
    }
    if ($Action -ceq 'close') { $removalReview = $true }

    $materializationRoot = [ordered]@{
        Path = [string] $Materialization['Path']
        Identity = [string] $Materialization['Identity']
        EnvBuildPath = [string] $Materialization['EnvBuildPath']
        EnvBuildHash = [string] $Materialization['EnvBuildHash']
        EnvLockPath = [string] $Materialization['EnvLockPath']
        EnvLockHash = [string] $Materialization['EnvLockHash']
        MaterializationHash = [string] $Materialization['MaterializationHash']
    }

    return [ordered]@{
        OperationKind = 'task-overlay'
        Generator = $script:TaskGeneratorName
        RepositoryCommit = [string] $Git.RepositoryCommit
        RepoRoot = $repo
        ApprovedToolchainHash = $ToolchainHash
        ControllerRepoFingerprint = $ControllerFingerprint
        ControlBaseIntent = (New-LiveSyncControlBaseIntent -Context (Get-LiveSyncTargetContext -Path ([System.IO.Path]::GetFullPath([string] $AuthorityContext.ControlBase))))
        Platforms = @($slots)
        OrderedActions = @($sortedActions)
        UnknownMarkers = @($unknownMarkers)
        SystemMarker = (Get-LiveSyncSystemMarker -CodexLiveRoot ([string] $liveRootsByPlatform['Codex']))
        TargetContextIntent = [ordered]@{ HomeAuthorityKey = [string] $AuthorityContext.HomeAuthorityKey; Rows = @($observedRows) }
        AuthorityStateIntent = $intent
        EnvironmentName = $BaseEnv
        EnvironmentMaterializationRoot = $materializationRoot
        TaskOverlayEvidence = [ordered]@{
            CurrentHash = $CurrentOverlayHash
            CandidateHash = $CandidateHash
            CandidatePath = $overlayPath
            Action = $Action
            RemovalReview = $removalReview
        }
    }
}

function Write-TaskOverlayPlan {
    # Writes the candidate artifact first, then the plan: the plan is the commit
    # point of the reviewed pair and is never written when the candidate failed.
    param(
        [Parameter(Mandatory)] [string] $PlanFull,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Payload,
        [Parameter(Mandatory)] [string] $CandidateText
    )

    if (Test-Path -LiteralPath $PlanFull) { throw $script:LivePlanPathCollision }
    $null = Resolve-PrivateArtifactPath -Path $PlanFull -Role ExternalUserArtifact -RepoRoot $repo -AllowMissingLeaf
    $candidatePath = Get-TaskOverlayCandidateArtifactPath -PlanFull $PlanFull
    if (Test-Path -LiteralPath $candidatePath) { throw $script:LivePlanPathCollision }
    $null = Resolve-PrivateArtifactPath -Path $candidatePath -Role ExternalUserArtifact -RepoRoot $repo -AllowMissingLeaf
    $parent = Split-Path -Parent $candidatePath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllBytes($candidatePath, ([System.Text.UTF8Encoding]::new($false)).GetBytes($CandidateText))

    $document = [ordered]@{
        SchemaVersion = 3
        ArtifactKind = 'sync-plan'
        Metadata = [ordered]@{ GeneratedAtUtc = [DateTime]::UtcNow.ToString('o') }
        PlanPayload = $Payload
    }
    $document['PlanHash'] = Get-PlanHash -PlanPayload $Payload
    $document['DocumentHash'] = Get-DocumentHash -Document $document
    Assert-LiveSyncPlanDocumentIntegrity -Document $document
    Write-LiveSyncPlan -Path $PlanFull -Document $document
    return $document
}

function Get-TaskOverlayCandidateArtifactPath {
    param([Parameter(Mandatory)] [string] $PlanFull)

    $parent = Split-Path -Parent $PlanFull
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($PlanFull)
    return [System.IO.Path]::GetFullPath((Join-Path $parent ($stem + '.candidate.psd1')))
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

function Invoke-TaskStatus {
    $context = Get-TaskContext
    $overlay = $context.Overlay
    Write-Output 'Task skill status'
    Write-Output "  base environment: $BaseEnv"
    Write-Output "  overlay path: $($overlay.Path)"
    Write-Output "  overlay state: present"
    Write-Output "  overlay hash: $($overlay.Hash)"
    Write-Output "  Claude additions: $(if (@($overlay.Skills.Claude).Count) { (@($overlay.Skills.Claude) -join ', ') } else { '(none)' })"
    Write-Output "  Codex additions: $(if (@($overlay.Skills.Codex).Count) { (@($overlay.Skills.Codex) -join ', ') } else { '(none)' })"
    Write-Output "  Reasonix additions: $(if (@($overlay.Skills.Reasonix).Count) { (@($overlay.Skills.Reasonix) -join ', ') } else { '(none)' })"
    Write-Output "  effective Claude skills: $(@($context.EffectiveDefinition.Skills.Claude) -join ', ')"
    Write-Output "  effective Codex skills: $(@($context.EffectiveDefinition.Skills.Codex) -join ', ')"
    Write-Output "  effective Reasonix skills: $(@($context.EffectiveDefinition.Skills.Reasonix) -join ', ')"

    # The status route is read-only: it reports the baseline admission route
    # without writing or repairing anything.
    $legacy = Read-LegacyHarnessEnvState -RepoRoot $repo
    Write-Output "  legacy schema 2 evidence: $(if ($legacy.Status -ceq 'MISSING') { 'absent' } else { $legacy.Status })"
    $internalRoots = $null
    $baseline = 'unresolved'
    try {
        $roots = Initialize-TaskAuthorityRoots
        $state = Get-TaskOverlayStateDocument -AuthorityContext $roots.Context
        $baseline = [string] $state.Status
        if ([string] $state.Status -ceq 'COMPLETE') {
            $maps = Get-TaskOverlayBaselineMaps -Document ([System.Collections.IDictionary] $state.Document)
            foreach ($platform in $script:TaskPlatforms) {
                Write-Output "  committed $platform baseline: $(if (@($maps[$platform]).Count) { (@($maps[$platform] | Sort-Object) -join ', ') } else { '(none)' })"
            }
            $stateHash = if ([string] $state.Document['TaskOverlayHash']) { [string] $state.Document['TaskOverlayHash'] } else { '' }
            Write-Output "  live attestation: $(if ($stateHash -eq [string] $overlay.Hash) { 'task overlay matches activation' } else { 'task overlay differs from activation' })"
        }
    }
    catch {
        $baseline = "unresolved ($($_.Exception.Message))"
    }
    Write-Output "  three-platform baseline: $baseline"
}

# ---------------------------------------------------------------------------
# Producer: DryRun
# ---------------------------------------------------------------------------

function Invoke-TaskOverlayDryRun {
    if ([string]::IsNullOrWhiteSpace($PlanPath)) { throw ($script:TaskPlanPathRequired + ': run -DryRun -PlanPath <new-external-plan.json> first.') }
    $planFull = [System.IO.Path]::GetFullPath($PlanPath)
    if (Test-Path -LiteralPath $planFull) { throw $script:LivePlanPathCollision }
    $context = Get-TaskContext
    $roots = Initialize-TaskAuthorityRoots
    Write-Host "Task overlay dry-run ($Action): $BaseEnv"
    Write-Host "  Repo : $repo"
    Write-Host "  Plan : $planFull"
    Write-Host "  Home : $($roots.HomeRoot)"

    Write-Host ''
    Write-Host 'Gate 1/4: three-platform baseline admission'
    $baselineMaps = Assert-TaskOverlayThreePlatformBaseline -AuthorityContext $roots.Context
    Write-Host '  Claude/Codex/Reasonix task baselines: present'

    Write-Host ''
    Write-Host 'Gate 2/4: reviewed environment materialization'
    $materializationPath = Get-LiveSyncMaterializationPath -PlanPath $planFull
    $candidateData = Get-TaskOverlayCandidateData -Tracked $context.Overlay.Skills -Definition $context.Definition
    $candidateText = ConvertTo-TaskSkillOverlayText -Data $candidateData
    $candidateHash = Get-StringSha256 -Text $candidateText
    $currentOverlayHash = ([string] (Get-HarnessFileHash -Path $context.OverlayPath)).ToLowerInvariant()
    # The candidate content is materialized through a disposable create-new
    # overlay file so the frozen lock binds exactly the bytes the plan carries.
    $candidateStageParent = Join-Path ([string] $roots.HomeRoot) '.ai-agent-dotfiles-staging'
    New-Item -ItemType Directory -Force -Path $candidateStageParent | Out-Null
    $candidateStagePath = Join-Path $candidateStageParent "candidate-overlay-$([Guid]::NewGuid().ToString('N')).psd1"
    [System.IO.File]::WriteAllText($candidateStagePath, $candidateText, [System.Text.UTF8Encoding]::new($false))
    try {
        $materialization = New-LiveSyncMaterializationEvidence -MaterializationPath $materializationPath -RepoRoot $repo -Name $BaseEnv -TaskOverlayPath $candidateStagePath
        $null = Assert-HarnessEnvMaterializedSourceRoots -StagingPath $materializationPath
        $materializationLock = Test-HarnessEnvLock -RepoRoot $repo -DefinitionPath $context.DefinitionPath -StagingPath $materializationPath -TaskOverlayPath $candidateStagePath
    }
    finally {
        if (Test-Path -LiteralPath $candidateStagePath) { Remove-Item -LiteralPath $candidateStagePath -Force }
    }
    if (-not $materializationLock.Valid) {
        throw ("$($script:TaskMaterializationInvalid): {0}" -f (@($materializationLock.Reasons) -join '; '))
    }
    # The materialization lock records the overlay file hash it was built with.
    # The candidate artifact hash is the same bytes, so the lock binds the plan.
    if (([string] $materializationLock.Lock.TaskOverlayHash).ToLowerInvariant() -cne $candidateHash) {
        throw ("$($script:TaskMaterializationInvalid): the materialized lock does not bind the candidate overlay bytes.")
    }
    $null = Assert-TaskLockBaseline -Lock $materializationLock.Lock

    Write-Host ''
    Write-Host 'Gate 3/4: authority, controller, and claims binding'
    $assessment = Get-HarnessEnvAuthorityAssessment -RepoRoot $repo -Identity $roots.Identity
    if ([string] $assessment.Route -cne 'activate') {
        throw ("live-plan-selection-mismatch: the read-only authority assessment routes to '$([string] $assessment.Route)', not 'activate'.")
    }
    $pair = Read-HomeAuthorityState -ControlBase ([string] $roots.Context.ControlBase) -HomeAuthorityKey ([string] $roots.Context.HomeAuthorityKey) -RepoRoot $repo
    if ([string] $pair.PairStatus -cne 'VALID') { throw $script:LiveSyncAuthorityMissing }
    $claimsHash = [string] $pair.ClaimsBytesHash
    if ([string] $claimsHash -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]] $pair.ClaimsBytes)).ToLowerInvariant()) {
        throw $script:LiveSyncPlanHashMismatch
    }
    $stateDocument = [System.Collections.IDictionary] (Get-TaskOverlayStateDocument -AuthorityContext $roots.Context).Document
    if ($null -eq $stateDocument) { throw $script:TaskBaselineManualReviewRequired }
    $git = Get-CanonicalGitContext -RepoRoot $repo
    $controllerFingerprint = Get-CanonicalControllerIdentity -GitContext $git
    if ([string] $pair.StateDocument['ControllerRepoFingerprint'] -cne $controllerFingerprint -and
        [string] $stateDocument['ControllerRepoFingerprint'] -cne $controllerFingerprint) {
        throw $script:TaskControllerMismatch
    }
    $toolchainHash = Get-LiveSyncApprovedToolchainHash -RepoRoot $repo

    Write-Host ''
    Write-Host 'Gate 4/4: reviewed task-overlay plan'
    $removed = Get-TaskOverlayRemovalMap -BaselineMaps $baselineMaps -Candidate $candidateData
    $payload = New-TaskOverlayPlanPayload -Materialization $materialization -BaselineMaps $baselineMaps -Candidate $candidateData -Removed $removed -CurrentOverlayHash $currentOverlayHash -CandidateHash $candidateHash -Git $git -ControllerFingerprint $controllerFingerprint -ToolchainHash $toolchainHash -AuthorityContext $roots.Context -StateDocument $stateDocument -ClaimsHash $claimsHash
    $document = Write-TaskOverlayPlan -PlanFull $planFull -Payload $payload -CandidateText $candidateText
    Write-PlanSummary -Payload $payload
    $overlayPath = $context.OverlayPath
    Write-Host "Overlay file    : $overlayPath"
    Write-Host "Overlay current : $currentOverlayHash"
    Write-Host "Overlay candidate: $candidateHash"
    Write-Host "Candidate artifact: $(Get-TaskOverlayCandidateArtifactPath -PlanFull $planFull)"
    Write-Host "Removal review  : $(if ([bool] $payload['TaskOverlayEvidence'].RemovalReview) { 'required (removals/prunes are listed in the plan)' } else { 'not required' })"
    Write-Host "Plan hash       : $([string] $document['PlanHash'])"
    Write-Host "Document hash   : $([string] $document['DocumentHash'])"
    Write-Host ''
    Write-Host 'DRY-RUN complete. No live file, no tracked overlay, and no authority state were changed. Review the schema 3 plan, then rerun with -Apply -PlanPath <the same path>.'
}

# ---------------------------------------------------------------------------
# Consumer: Apply
# ---------------------------------------------------------------------------

function Invoke-TaskOverlayApply {
    if ([string]::IsNullOrWhiteSpace($PlanPath)) { throw ($script:TaskPlanPathRequired + ': -Apply consumes the exact plan a preview wrote; this CLI never generates one.') }
    $planFull = [System.IO.Path]::GetFullPath($PlanPath)
    if (-not (Test-Path -LiteralPath $planFull -PathType Leaf)) {
        throw (('task-overlay-plan' + '-not-found: ') + "$planFull. Run -DryRun -PlanPath <external-plan.json> first.")
    }
    $null = Resolve-PrivateArtifactPath -Path $planFull -Role ExternalUserArtifact -RepoRoot $repo
    $saved = Read-LiveSyncPlan -Path $planFull
    Assert-LiveSyncPlanDocumentIntegrity -Document ([System.Collections.IDictionary] $saved)
    $savedPayload = [System.Collections.IDictionary] $saved['PlanPayload']
    if ([string] $savedPayload['OperationKind'] -cne 'task-overlay' -or [string] $savedPayload['Generator'] -cne $script:TaskGeneratorName) {
        throw $script:TaskPlanKindMismatch
    }

    $materializationRoot = [System.Collections.IDictionary] $savedPayload['EnvironmentMaterializationRoot']
    $materializationFull = [System.IO.Path]::GetFullPath([string] $materializationRoot['Path'])
    $null = Assert-LiveSyncPlanCurrent -Document ([System.Collections.IDictionary] $saved) -MaterializationDirectory $materializationFull
    $null = Assert-HarnessEnvMaterializedSourceRoots -StagingPath $materializationFull
    $null = Read-HarnessEnvBuild -StagingPath $materializationFull
    $null = Read-HarnessEnvLock -StagingPath $materializationFull
    $null = Assert-LiveSyncPlanSelectionContext -Document ([System.Collections.IDictionary] $saved) -ExpectedOperationKind 'task-overlay' -ExpectedEnvironmentName $BaseEnv

    $currentController = Get-CanonicalControllerIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $repo)
    if ([string] $savedPayload['ControllerRepoFingerprint'] -cne $currentController) { throw $script:TaskControllerMismatch }

    $roots = Initialize-TaskAuthorityRoots
    $homeFull = [string] $roots.HomeRoot
    $authorityContext = $roots.Context
    $controlBaseFull = [System.IO.Path]::GetFullPath([string] $authorityContext.ControlBase)
    $backupRootFull = [System.IO.Path]::GetFullPath([string] $authorityContext.BackupRoot)

    $canonicalStatus = Get-CanonicalSetupStatus -RepoRoot $repo
    if ([string] $canonicalStatus -cne 'canonical-ready') { throw [string] $canonicalStatus }
    $bootstrapStatus = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $authorityContext
    if ([string] $bootstrapStatus.Status -cne 'COMPLETE') { throw $script:LiveSyncAuthorityMissing }

    $terminalDocuments = Get-SealedLiveTransactionTerminalDocumentHashes -TransactionsRoot ([string] $authorityContext.LiveTransactionsRoot)
    Assert-LiveSyncPlanDocumentHashNotConsumed -Document ([System.Collections.IDictionary] $saved) -TerminalEvidence $terminalDocuments

    # The reviewed overlay pre-state and candidate artifact are checked only
    # after the consumption gate: a plan may mutate once, and a replayed plan
    # must be refused as consumed rather than restated as a pre-state drift.
    $overlayPath = Get-TaskOverlayPath
    $evidence = [System.Collections.IDictionary] $savedPayload['TaskOverlayEvidence']
    if ([System.IO.Path]::GetFullPath([string] $evidence['CandidatePath']) -cne $overlayPath) { throw $script:TaskPlanKindMismatch }
    $current = Get-SealedLiveObservableFileState -Path $overlayPath
    if ([string] $current['State'] -cne 'PRESENT' -or [string] $current['Hash'] -cne [string] $evidence['CurrentHash']) {
        throw ($script:TaskOverlayCurrentMismatch + ": the tracked overlay is not the file the plan reviewed: $overlayPath")
    }
    $candidateArtifact = Get-TaskOverlayCandidateArtifactPath -PlanFull $planFull
    # The path-safety resolution bounds the artifact location, while the
    # missing-leaf case is owned by the reviewed candidate check below so the
    # refusal names the exact contract instead of a generic missing path.
    $null = Resolve-PrivateArtifactPath -Path $candidateArtifact -Role ExternalUserArtifact -RepoRoot $repo -AllowMissingLeaf
    if (-not (Test-Path -LiteralPath $candidateArtifact -PathType Leaf)) { throw ($script:TaskOverlayCandidateMismatch + ": the candidate artifact next to the plan is missing: $candidateArtifact") }
    $candidateBytes = [System.IO.File]::ReadAllBytes($candidateArtifact)
    $candidateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($candidateBytes)).ToLowerInvariant()
    if ($candidateHash -cne [string] $evidence['CandidateHash']) { throw $script:TaskOverlayCandidateMismatch }


    $stagingBase = Join-Path $homeFull '.ai-agent-dotfiles-staging'
    $stagingRootsByPlatform = [ordered]@{}
    $sourceRootsByPlatform = [ordered]@{}
    $liveRootsByPlatform = [ordered]@{}
    $capabilityHashesByPlatform = [ordered]@{}
    foreach ($slot in @([object[]] $savedPayload['Platforms'])) {
        $platform = [string] $slot['Platform']
        if ($platform -cnotin $script:TaskPlatforms) { throw $script:LivePlanSelectionMismatch }
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

    Write-Host 'Running the receipt-backed live transaction host ...'
    $toolchainRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $hostResult = Invoke-SealedLiveTransactionHost -Plan ([System.Collections.IDictionary] $saved) -RepoRoot $repo -ControlBase $controlBaseFull -BackupRoot $backupRootFull -StagingRootsByPlatform $stagingRootsByPlatform -SourceRootsByPlatform $sourceRootsByPlatform -FinalCapabilityHashesByPlatform $capabilityHashesByPlatform -AuthorityContext $authorityContext -WorkingTreeRoots ([ordered]@{ RepoRoot = $repo; ToolchainRoot = $toolchainRoot }) -ToolchainRoot $toolchainRoot -OverlayTarget ([ordered]@{
        TargetPath = $overlayPath
        CandidateSourcePath = $candidateArtifact
        CandidateHash = $candidateHash
        CurrentHash = [string] $evidence['CurrentHash']
    })
    Write-Host "Transaction id  : $([string] $hostResult.TransactionId)"
    Write-Host "Receipt id      : $([string] $hostResult.ReceiptId)"
    Write-Host "Receipt path    : $([string] $hostResult.ReceiptPath)"
    Write-Host "State hash      : $([string] $hostResult.StateHash)"
    Write-Host "Journal         : $([string] $hostResult.JournalDir)"

    # Postconditions: the tracked overlay carries the reviewed candidate bytes,
    # every planned live target exists, and the Codex .system state still
    # matches the reviewed plan.
    $verificationFailed = $false
    $finalOverlay = Get-SealedLiveObservableFileState -Path $overlayPath
    if ([string] $finalOverlay['Hash'] -cne $candidateHash) {
        Write-Host "ERROR: the tracked overlay does not carry the reviewed candidate bytes: $overlayPath"
        $verificationFailed = $true
    }
    foreach ($action in @([object[]] $savedPayload['OrderedActions'])) {
        if ([string] $action['Action'] -ceq 'prune') { continue }
        $target = Join-Path ([string] $liveRootsByPlatform[[string] $action['Platform']]) ([string] $action['Name'])
        if (-not (Test-Path -LiteralPath $target)) {
            Write-Host "ERROR: planned target missing after apply: $target"
            $verificationFailed = $true
        }
    }
    # The plan recorded the platform-managed .system state; re-derive it with
    # the same reader instead of demanding a marker that a machine without
    # Codex never had.
    $recordedSystemMarker = [System.Collections.IDictionary] $savedPayload['SystemMarker']
    $observedSystemMarker = Get-LiveSyncSystemMarker -CodexLiveRoot ([string] $liveRootsByPlatform['Codex'])
    $systemOk = ([bool] $recordedSystemMarker['Present']) -eq ([bool] $observedSystemMarker['Present']) -and
        [string] $recordedSystemMarker['Identity'] -ceq [string] $observedSystemMarker['Identity'] -and
        [string] $recordedSystemMarker['Hash'] -ceq [string] $observedSystemMarker['Hash']
    Write-Host ".system marker preserved: $systemOk"
    if (-not $systemOk) {
        # The platform-managed root is outside repository ownership: any
        # difference from the reviewed plan is a postcondition failure, never
        # a warning.
        Write-Host 'ERROR: the Codex .system state changed during apply'
        $verificationFailed = $true
    }
    if ($verificationFailed) { throw ('task-overlay-' + 'postcondition-failed: inspect the live transaction journal and receipt.') }

    Write-Host "Task overlay applied: $Action. Commit $overlayPath to share it with other computers."
}


try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { throw 'RepoRoot is required.' }
    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $overlayPath = Get-TaskOverlayPath
    if (-not [string]::IsNullOrWhiteSpace($TaskOverlayPath) -and
        [System.IO.Path]::GetFullPath($TaskOverlayPath) -cne $overlayPath) {
        throw ($script:TaskOverlayPathUnsupported + ": the only task-overlay target is the tracked $overlayPath.")
    }

    if ($Action -eq 'status') {
        if ($Apply -or $DryRun -or $Automatic -or $SkipBuild -or $SkipSecretScan) {
            throw 'env task status is read-only and does not accept -DryRun, -Apply, -Automatic, or a skip switch.'
        }
        Invoke-TaskStatus
        exit 0
    }

    if ($Automatic) { throw ($script:TaskAutomaticRemoved + ': automatic task apply was removed; Git hooks may only emit non-consumable previews plus an explicit external DryRun command.') }
    if ($SkipBuild -or $SkipSecretScan) { throw ($script:TaskSkipSwitchForbidden + ': task previews and applies carry no public skip gates.') }
    $hasMode = $(if ($DryRun) { 1 } else { 0 }) + $(if ($Apply) { 1 } else { 0 })
    if ($hasMode -ne 1) {
        throw "env task $Action requires exactly one explicit -DryRun or -Apply mode."
    }

    switch ($Action) {
        'ensure-skill' { }
        'sync' { }
        'close' { }
    }
    if ($Apply) { Invoke-TaskOverlayApply; exit 0 }
    Invoke-TaskOverlayDryRun
    exit 0
}
catch {
    Write-Error ([string] $_.Exception.Message) -ErrorAction Continue
    exit 1
}
