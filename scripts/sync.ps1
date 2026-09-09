#requires -Version 7.0
<#
.SYNOPSIS
    Schema 3 semantic sync-plan producer for the live Claude / Codex / Reasonix
    skill directories. Safe by default (dry-run); only mutates with -Apply.

.DESCRIPTION
    The public dry-run surface produces exactly two OperationKind branches of
    the sync-plan schema 3 document:

      * pristine initial  (no -RetireManifestPath): requires no shared authority
        state on the injected control base and absent live skill roots, then
        materializes the named `full` environment and writes a create-new plan.
      * explicit retirement (-RetireManifestPath): reads the seeded schema 3
        authority state, verifies every target is a stale unknown live skill
        outside the reviewed postset, and writes a create-new plan.

    Both producers run only inside the isolated internal sandbox: the capability
    must be present and the host must inject AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT,
    AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT, and AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE.
    Without them the dry-run fails closed with zero plan bytes and never reads
    USERPROFILE or an unprefixed INTERNAL_* variable. The content-aware producer
    returns with Task 5's environment route.

    -Apply keeps the tracked interlock as the first gate, then recomputes the
    reviewed document through the five-step validation (document integrity,
    current plan hash, bound materialization currency, selection context, and
    DocumentHash consumption) before the mandatory backup. The pristine-initial
    live-mutation host is not wired yet and fails closed; retirement executes
    its reviewed prune actions one skill directory at a time.

    Hard safety rules:
      * Never whole-dir mirror (no robocopy /MIR) against a live skills root.
      * Never touch Codex's platform-managed .system directory.
      * -Apply always runs build + secret scan + a backup before any change.

.PARAMETER Apply
    Actually perform the reviewed plan. Without it the script is a pure dry-run.

.PARAMETER DryRun
    Explicitly select dry-run mode. Equivalent to omitting -Apply; cannot be
    combined with -Apply.

.PARAMETER SkipBuild
    Skip running scripts/build-skills.ps1 first (use the existing generated output).

.PARAMETER SkipSecretScan
    Skip running scripts/scan-secrets.ps1. Not recommended; default is to scan.

.PARAMETER BackupRoot
    Declared for CLI compatibility only. Explicitly bound values are rejected;
    the backup root is host-injected through
    AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT.

.PARAMETER HomeRoot
    Declared for CLI compatibility only. Explicitly bound values are rejected;
    the home root is host-injected through AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT.

.PARAMETER ReasonixLiveSkillsPath
    Optional override for the Reasonix live skills target directory.

.PARAMETER PlanPath
    Required create-new path of the schema 3 sync plan. DryRun writes it;
    Apply never overwrites, refreshes, or deletes it.

.PARAMETER RetireManifestPath
    Optional path to a one-shot JSON retirement manifest. Its exact bytes and
    per-platform names are bound into the plan's PlanHash, so the same
    unchanged file must be supplied again on -Apply. It never grants authority
    over .system or a skill that is still present in generated output or the
    current managed manifests.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $DryRun,
    [switch] $SkipBuild,
    [switch] $SkipSecretScan,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $ReasonixLiveSkillsPath,
    [string] $PlanPath,
    [string] $RetireManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')
. (Join-Path $PSScriptRoot 'live-plan-common.ps1')
. (Join-Path $PSScriptRoot 'harness-env-common.ps1')
. (Join-Path $PSScriptRoot 'target-context-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'root-claims-registry-common.ps1')
. (Join-Path $PSScriptRoot 'live-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'backup-receipt-common.ps1')

$script:LiveSyncHostResolutionRequired = 'live-plan-host-resolution-required'
$script:LiveSyncAuthorityPresent = 'live-plan-authority-present'
$script:LiveSyncAuthorityMissing = 'live-plan-authority-missing'
$script:LiveSyncSelectionMismatch = 'live-plan-selection-mismatch'
$script:LiveSyncPathCollision = 'live-plan-path-collision'
$script:LiveSyncRetirementManifestRequired = 'live-plan-retirement-manifest-required'
$script:LiveSyncRetirementSelectionConflict = 'retirement-selection-conflict'
$script:LiveSyncSystemMarkerDrift = 'live-plan-system-marker-drift'
$script:LiveSyncUnsupportedApplyKind = 'live-plan-apply-kind-unsupported'
$script:LiveSyncPlanHashMismatch = 'live-plan-hash-mismatch'
$script:LiveSyncPlatformRank = @{ Claude = 0; Codex = 1; Reasonix = 2 }

if ($Apply -and $DryRun) { throw 'Specify -DryRun or -Apply, not both.' }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$reportHelper = Join-Path $PSScriptRoot 'report-common.ps1'
if (Test-Path -LiteralPath $reportHelper) {
    . $reportHelper
}
else {
    Write-Warning "Report helper missing: $reportHelper"
}
$CodexSystemDirName = '.system'

# ---------------------------------------------------------------------------
# Host-injected sandbox roots
# ---------------------------------------------------------------------------

function Resolve-LiveSyncInternalRoots {
    # Only a genuine sandbox capability with all three prefixed locators may
    # resolve the live surface. Anything else fails closed without reading
    # USERPROFILE or an unprefixed INTERNAL_* variable.
    if (-not (Test-LiveSafetySandboxCapability)) { throw $script:LiveSyncHostResolutionRequired }
    $homeRoot = $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT
    $backupRoot = $env:AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT
    $controlBase = $env:AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE
    foreach ($value in @($homeRoot, $backupRoot, $controlBase)) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw $script:LiveSyncHostResolutionRequired }
    }
    return [pscustomobject][ordered]@{
        HomeRoot = [System.IO.Path]::GetFullPath($homeRoot)
        BackupRoot = [System.IO.Path]::GetFullPath($backupRoot)
        ControlBase = [System.IO.Path]::GetFullPath($controlBase)
    }
}

function Get-LiveSyncHomeAuthorityKey {
    param([Parameter(Mandatory)] [string] $HomeRootLocationKey)

    $tokenSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/home-authority/v1'
        TokenSid = $tokenSid
        HomeRootLocationKey = $HomeRootLocationKey
    })
}

function Get-LiveSyncApprovedToolchainHash {
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $validatorLock = Get-PinnedToolLock -Path (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json')
    $scannerLock = Get-PinnedToolLock -Path (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json')
    return Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/plan-approved-toolchain/v1'
        ValidatorLock = $validatorLock
        ScannerLock = $scannerLock
    })
}

function New-LiveSyncAuthorityContext {
    # Resolve the full home-authority context from the sandbox-injected home
    # and fail closed unless its derived control/backup locators equal the
    # injected roots; the receipt-backed host revalidates both anyway.
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
    # Known-folder resolution requires the standard profile layout to exist.
    foreach ($folder in @([string] $identity.RoamingAppDataRoot, [string] $identity.LocalAppDataRoot)) {
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    }
    $context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity -ForbiddenRoots @($ControlBase, $BackupRoot)
    $derivedControl = [System.IO.Path]::GetFullPath([string] $context.ControlBase)
    $derivedBackup = [System.IO.Path]::GetFullPath([string] $context.BackupRoot)
    if ($derivedControl -cne [System.IO.Path]::GetFullPath($ControlBase) -or
        $derivedBackup -cne [System.IO.Path]::GetFullPath($BackupRoot)) {
        throw $script:LiveSyncHostResolutionRequired
    }
    return $context
}

# ---------------------------------------------------------------------------
# Live surface probing
# ---------------------------------------------------------------------------

function Get-ClaudeLiveSkillsPath {
    return (Join-Path $HomeRoot '.claude\skills')
}

function Get-CodexLiveSkillsPath {
    # Probe ~/.codex/skills first, then ~/.agents/skills; do not assume the latter.
    $codex = Join-Path $HomeRoot '.codex\skills'
    $agents = Join-Path $HomeRoot '.agents\skills'
    if (Test-Path -LiteralPath $codex) { return $codex }
    if (Test-Path -LiteralPath $agents) { return $agents }
    return $codex  # conventional default; created on -Apply if needed
}

function Get-ReasonixLiveSkillsPath {
    if ($ReasonixLiveSkillsPath) {
        if (Test-Path -LiteralPath $ReasonixLiveSkillsPath) {
            return (Resolve-Path -LiteralPath $ReasonixLiveSkillsPath).Path
        }
        return [System.IO.Path]::GetFullPath($ReasonixLiveSkillsPath)
    }
    return (Join-Path $HomeRoot 'AppData\Roaming\reasonix\skills')
}

function Get-PlatformLiveRoot {
    param([Parameter(Mandatory)] [ValidateSet('Claude', 'Codex', 'Reasonix')] [string] $Platform)
    switch ($Platform) {
        'Claude' { return (Get-ClaudeLiveSkillsPath) }
        'Codex' { return (Get-CodexLiveSkillsPath) }
        'Reasonix' { return (Get-ReasonixLiveSkillsPath) }
    }
}

function Get-LiveSyncTargetContext {
    param([Parameter(Mandatory)] [string] $Path)

    $metadata = Get-TargetMetadataContext -Path ([System.IO.Path]::GetFullPath($Path))
    $identity = $null
    if ([string] $metadata.TargetStatus -ceq 'EXISTS') {
        $identity = [string] $metadata.Ancestors[-1].Identity
    }
    return [pscustomobject][ordered]@{
        LocationKey = [string] $metadata.LocationKey
        RequestedPath = [string] $metadata.RequestedPath
        TargetStatus = [string] $metadata.TargetStatus
        VolumeId = [string] $metadata.VolumeId
        DeepestExistingParentPath = [System.IO.Path]::GetFullPath([string] $metadata.DeepestExistingParentPath)
        DeepestExistingParentIdentity = [string] $metadata.DeepestExistingParentIdentity
        MissingRemainder = @([string[]] $metadata.MissingRemainder)
        DirectoryIdentity = $identity
    }
}

function New-LiveSyncRootClaimRow {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [ValidateSet('ABSENT', 'EXISTS')] [string] $InitialState
    )

    return [ordered]@{
        Platform = $Platform
        LocationKey = [string] $Context.LocationKey
        RequestedPath = [string] $Context.RequestedPath
        InitialState = $InitialState
        VolumeId = [string] $Context.VolumeId
        DeepestExistingParentPath = [string] $Context.DeepestExistingParentPath
        DeepestExistingParentIdentity = [string] $Context.DeepestExistingParentIdentity
        MissingRemainder = @([string[]] $Context.MissingRemainder)
        InitialDirectoryIdentity = $(if ($InitialState -ceq 'EXISTS') { [string] $Context.DirectoryIdentity } else { $null })
        ExpectedPostState = 'EXISTS'
    }
}

function Get-LiveSyncLiveTreeHash {
    # Hash the live root while skipping the Codex .system subtree entirely:
    # platform-managed .system contents are never traversed.
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $LiveRoot
    )

    if (-not (Test-Path -LiteralPath $LiveRoot -PathType Container)) { return $null }
    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $LiveRoot -File -Recurse -Force)) {
        $relative = [System.IO.Path]::GetRelativePath($LiveRoot, $file.FullName) -replace '\\', '/'
        if ($Platform -ieq 'codex' -and ($relative -ieq $CodexSystemDirName -or $relative.StartsWith("$CodexSystemDirName/", [System.StringComparison]::OrdinalIgnoreCase))) { continue }
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $rows.Add("$relative|$($file.Length)|$hash")
    }
    return Get-StringSha256 -Text ((@($rows | Sort-Object) -join "`n") + "`n")
}

function Get-LiveSyncSystemMarker {
    param([Parameter(Mandatory)] [string] $CodexLiveRoot)

    $systemDir = Join-Path $CodexLiveRoot $CodexSystemDirName
    if (-not (Test-Path -LiteralPath $systemDir -PathType Container)) {
        return [ordered]@{ Platform = 'Codex'; Name = $CodexSystemDirName; Present = $false; Identity = $null; Hash = $null }
    }
    $markerPath = Join-Path $systemDir '.codex-system-skills.marker'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw $script:LiveSyncSystemMarkerDrift
    }
    $info = [AiAgentDotfiles.NoFollowFile]::Inspect($systemDir)
    if ([bool] $info.IsReparsePoint) { throw $script:LiveSyncSystemMarkerDrift }
    $markerBytes = [System.IO.File]::ReadAllBytes($markerPath)
    return [ordered]@{
        Platform = 'Codex'
        Name = $CodexSystemDirName
        Present = $true
        Identity = [string] $info.Identity
        Hash = (Get-BytesSha256 -Bytes ([byte[]] $markerBytes))
    }
}

function New-LiveSyncPlatformSlot {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $ManagedNames,
        [Parameter(Mandatory)] [string] $ManifestHash
    )

    $sourceContext = Get-LiveSyncTargetContext -Path $SourceRoot
    if ([string] $sourceContext.TargetStatus -cne 'EXISTS') { throw $script:LiveSyncSelectionMismatch }
    $liveContext = Get-LiveSyncTargetContext -Path $LiveRoot
    return [ordered]@{
        Platform = $Platform
        SourceRoot = [string] $sourceContext.RequestedPath
        LiveRoot = [string] $liveContext.RequestedPath
        SourceRootExists = $true
        LiveRootExists = ([string] $liveContext.TargetStatus -ceq 'EXISTS')
        SourcePreIdentity = [ordered]@{
            TargetStatus = 'EXISTS'
            LocationKey = [string] $sourceContext.LocationKey
            VolumeId = [string] $sourceContext.VolumeId
            DirectoryIdentity = [string] $sourceContext.DirectoryIdentity
        }
        LivePreIdentity = [ordered]@{
            TargetStatus = [string] $liveContext.TargetStatus
            LocationKey = [string] $liveContext.LocationKey
            VolumeId = [string] $liveContext.VolumeId
            DirectoryIdentity = $liveContext.DirectoryIdentity
        }
        ManifestHash = $ManifestHash
        SourceTreeHash = (Get-SkillTreeHash -Path $SourceRoot)
        LiveTreeHash = (Get-LiveSyncLiveTreeHash -Platform $Platform -LiveRoot $LiveRoot)
        ManagedNames = @([string[]] ($ManagedNames | Sort-Object))
    }
}

function New-LiveSyncControlBaseIntent {
    param([Parameter(Mandatory)] $Context)

    return [ordered]@{
        TargetStatus = [string] $Context.TargetStatus
        RequestedPath = [string] $Context.RequestedPath
        LocationKey = [string] $Context.LocationKey
        VolumeId = [string] $Context.VolumeId
        DirectoryIdentity = $Context.DirectoryIdentity
        FilesystemCapability = [ordered]@{ Status = 'UNPROBED' }
    }
}

# ---------------------------------------------------------------------------
# Environment materialization evidence
# ---------------------------------------------------------------------------

function Get-LiveSyncMaterializationPath {
    param([Parameter(Mandatory)] [string] $PlanPath)

    $planFull = [System.IO.Path]::GetFullPath($PlanPath)
    $parent = Split-Path -Parent $planFull
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($planFull)
    return (Join-Path $parent ($stem + '.materialization'))
}

function Get-LiveSyncPlatformTriple {
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Map,
        [Parameter(Mandatory)] [ValidateSet('Skills', 'Hash')] [string] $Kind
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $value = Get-HarnessJsonProperty -Object $Map -Name $platform
        if ($Kind -ceq 'Skills') {
            $rows.Add([ordered]@{ Platform = $platform; Skills = @([string[]] @($value)) })
        }
        else {
            $rows.Add([ordered]@{ Platform = $platform; Hash = ([string] $value).ToLowerInvariant() })
        }
    }
    return @($rows)
}

function Get-LiveSyncTaskOverlayHash {
    param(
        [AllowNull()] [string] $OverlayHash,
        [Parameter(Mandatory)] [object[]] $TaskOverlaySkillsRows
    )

    if (-not [string]::IsNullOrEmpty($OverlayHash)) { return ([string] $OverlayHash).ToLowerInvariant() }
    # An absent task overlay file yields a deterministic absent-overlay binding.
    return Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/plan-absent-task-overlay/v1'
        TaskOverlaySkills = $TaskOverlaySkillsRows
    })
}

function New-LiveSyncMaterializationEvidence {
    # DryRun-only create-new materialization. The destination is never
    # recursively deleted and Invoke-HarnessEnvMaterialization is the only
    # skills/lock/sidecar writer.
    param(
        [Parameter(Mandatory)] [string] $MaterializationPath,
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    if (Test-Path -LiteralPath $MaterializationPath) { throw $script:LiveSyncPathCollision }
    $materialization = Invoke-HarnessEnvMaterialization -Name 'full' -Destination $MaterializationPath -RepoRoot $RepoRoot
    return (Get-LiveSyncBoundMaterializationEvidence -MaterializationPath ([string] $materialization.Destination) -RepoRoot $RepoRoot)
}

function Get-LiveSyncBoundMaterializationEvidence {
    param(
        [Parameter(Mandatory)] [string] $MaterializationPath,
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    $root = [System.IO.Path]::GetFullPath($MaterializationPath)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw $script:LiveSyncPlanHashMismatch }
    $context = Get-LiveSyncTargetContext -Path $root
    if ([string] $context.TargetStatus -cne 'EXISTS') { throw $script:LiveSyncPlanHashMismatch }
    $buildPath = Get-HarnessEnvBuildPath -StagingPath $root
    $lockPath = Get-HarnessEnvLockPath -StagingPath $root
    foreach ($evidencePath in @($buildPath, $lockPath)) {
        $null = Resolve-PrivateArtifactPath -Path $evidencePath -Role EvidenceInputPath -RepoRoot $RepoRoot -EvidenceRoots @($root)
    }
    $build = Read-HarnessEnvBuild -StagingPath $root
    $lock = Read-HarnessEnvLock -StagingPath $root
    $buildBytes = [System.IO.File]::ReadAllBytes($buildPath)
    $lockBytes = [System.IO.File]::ReadAllBytes($lockPath)
    return [ordered]@{
        Path = $root
        Identity = [string] $context.DirectoryIdentity
        EnvBuildPath = [System.IO.Path]::GetFullPath($buildPath)
        EnvBuildHash = (Get-BytesSha256 -Bytes $buildBytes)
        EnvLockPath = [System.IO.Path]::GetFullPath($lockPath)
        EnvLockHash = (Get-BytesSha256 -Bytes $lockBytes)
        MaterializationHash = [string] (Get-HarnessJsonProperty -Object $build -Name 'MaterializationHash')
        Build = $build
        Lock = $lock
    }
}

# ---------------------------------------------------------------------------
# Retirement evidence
# ---------------------------------------------------------------------------

function Get-RetirementStalenessEvidence {
    # Extends the reviewed staleness walk with the generated-output and
    # current-manifest absence rows the schema 3 retirement manifest binds.
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string[]] $CanonicalRoots,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $ManagedNames,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $RetiredNames
    )

    $canonicalRows = [System.Collections.Generic.List[string]]::new()
    $generatedRows = [System.Collections.Generic.List[string]]::new()
    $manifestRows = [System.Collections.Generic.List[string]]::new()
    $sourceNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(Get-DirNames -Path $SourceRoot)) { [void] $sourceNames.Add($name) }
    foreach ($canonicalRoot in @($CanonicalRoots | Sort-Object -Unique)) {
        $canonicalRows.Add("$Platform|root|$([System.IO.Path]::GetFullPath($canonicalRoot))")
    }
    foreach ($name in $RetiredNames) {
        if ($sourceNames.Contains($name)) {
            throw "Retirement manifest cannot authorize active $Platform source skill '$name'."
        }
        $generatedRows.Add("$Platform|$name|$([System.IO.Path]::GetFullPath($SourceRoot))|absent")
        foreach ($canonicalRoot in @($CanonicalRoots | Sort-Object -Unique)) {
            $canonicalPath = Join-Path $canonicalRoot $name
            $canonicalState = if (Test-Path -LiteralPath $canonicalPath -PathType Container) { 'directory' }
                elseif (Test-Path -LiteralPath $canonicalPath -PathType Leaf) { 'file' }
                else { 'missing' }
            $canonicalRows.Add("$Platform|$name|$([System.IO.Path]::GetFullPath($canonicalPath))|$canonicalState")
            if ($canonicalState -ne 'missing') {
                throw "Retirement manifest cannot authorize canonical $Platform skill '$name'."
            }
        }
        if ($ManagedNames.Contains($name)) {
            throw "Retirement manifest cannot authorize current $Platform managed skill '$name'."
        }
        $manifestRows.Add("$Platform|$name|current-managed-manifest|absent")

        $target = Join-Path $LiveRoot $name
        Assert-SafeLiveSkillTarget -LiveRoot $LiveRoot -Path $target
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "Retirement manifest $Platform skill '$name' must identify an existing unknown live skill directory."
        }
        $targetItem = Get-Item -LiteralPath $target -Force
        if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Retirement manifest must not authorize a reparse-point skill directory: $Platform/$name"
        }
    }

    return [pscustomobject][ordered]@{
        CanonicalAbsenceHash = Get-StringSha256 -Text ((@($canonicalRows | Sort-Object) -join "`n") + "`n")
        GeneratedAbsenceHash = Get-StringSha256 -Text ((@($generatedRows | Sort-Object) -join "`n") + "`n")
        CurrentManifestAbsenceHash = Get-StringSha256 -Text ((@($manifestRows | Sort-Object) -join "`n") + "`n")
    }
}

function New-LiveSyncRetirementManifestEvidence {
    param(
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter(Mandatory)] [string] $ManifestHash,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $RetiredNames,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $StalenessEvidence,
        [Parameter(Mandatory)] [object[]] $PostsetSkillsRows,
        [Parameter(Mandatory)] [string] $PostsetEnvironmentName,
        [Parameter(Mandatory)] [string] $PostsetEnvironmentLockHash,
        [Parameter(Mandatory)] [string] $PostsetTaskOverlayHash,
        [Parameter(Mandatory)] [object[]] $PostsetManifestHashes
    )

    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $postsetRow = @($PostsetSkillsRows | Where-Object { [string] $_.Platform -ceq $platform })[0]
        $postsetSkills = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($skill in @($postsetRow.Skills)) { [void] $postsetSkills.Add([string] $skill) }
        foreach ($name in ([string[]] $RetiredNames[$platform])) {
            if ($postsetSkills.Contains($name)) { throw $script:LiveSyncRetirementSelectionConflict }
        }
    }

    $safeNames = [System.Collections.Generic.List[object]]::new()
    $targetTreeHashRows = [System.Collections.Generic.List[object]]::new()
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $platformNames = [System.Collections.Generic.List[string]]::new()
        $treeRows = [System.Collections.Generic.List[object]]::new()
        foreach ($name in (([string[]] $RetiredNames[$platform]) | Sort-Object)) {
            $platformNames.Add($name)
            $treeRows.Add([ordered]@{ Name = $name; Hash = (Get-SkillTreeHash -Path (Join-Path (Get-PlatformLiveRoot -Platform $platform) $name)) })
        }
        $safeNames.Add([ordered]@{ Platform = $platform; Names = @($platformNames) })
        $targetTreeHashRows.Add([ordered]@{
            Platform = $platform
            Hash = (Get-SemanticJsonHash -InputObject @($treeRows))
        })
    }

    return [ordered]@{
        Path = [System.IO.Path]::GetFullPath($ManifestPath)
        Hash = $ManifestHash
        SafeNames = @($safeNames)
        CanonicalAbsenceHash = (Get-SemanticJsonHash -InputObject ([ordered]@{
            Domain = 'ai-agent-dotfiles/plan-retirement-absence/v1'
            Kind = 'canonical'
            Claude = [string] $StalenessEvidence['Claude'].CanonicalAbsenceHash
            Codex = [string] $StalenessEvidence['Codex'].CanonicalAbsenceHash
            Reasonix = [string] $StalenessEvidence['Reasonix'].CanonicalAbsenceHash
        }))
        GeneratedAbsenceHash = (Get-SemanticJsonHash -InputObject ([ordered]@{
            Domain = 'ai-agent-dotfiles/plan-retirement-absence/v1'
            Kind = 'generated'
            Claude = [string] $StalenessEvidence['Claude'].GeneratedAbsenceHash
            Codex = [string] $StalenessEvidence['Codex'].GeneratedAbsenceHash
            Reasonix = [string] $StalenessEvidence['Reasonix'].GeneratedAbsenceHash
        }))
        CurrentManifestAbsenceHash = (Get-SemanticJsonHash -InputObject ([ordered]@{
            Domain = 'ai-agent-dotfiles/plan-retirement-absence/v1'
            Kind = 'current-managed-manifest'
            Claude = [string] $StalenessEvidence['Claude'].CurrentManifestAbsenceHash
            Codex = [string] $StalenessEvidence['Codex'].CurrentManifestAbsenceHash
            Reasonix = [string] $StalenessEvidence['Reasonix'].CurrentManifestAbsenceHash
        }))
        TargetTreeHashes = @($targetTreeHashRows)
        Postset = [ordered]@{
            EnvironmentName = $PostsetEnvironmentName
            EnvironmentLockHash = $PostsetEnvironmentLockHash
            TaskOverlayHash = $PostsetTaskOverlayHash
            TaskOverlaySkills = $PostsetSkillsRows
            ManifestHashes = $PostsetManifestHashes
        }
    }
}

# ---------------------------------------------------------------------------
# Semantic plan producer
# ---------------------------------------------------------------------------

function New-LiveSyncPlanDocument {
    # Pure producer over the current repository, live, and authority context.
    # DryRun passes -Materialize to create the environment materialization;
    # Apply binds the already-existing materialization and never creates one.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('initial', 'retirement')] [string] $OperationKind,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $ControlBase,
        [AllowNull()] [string] $RetirementManifestPath,
        [Parameter(Mandatory)] [string] $PlanPath,
        [switch] $Materialize
    )

    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $git = Get-CanonicalGitContext -RepoRoot $repo
    $controllerFingerprint = Get-CanonicalRepoIdentity -GitContext $git
    $toolchainHash = Get-LiveSyncApprovedToolchainHash -RepoRoot $repo

    $homeContext = Get-LiveSyncTargetContext -Path ([System.IO.Path]::GetFullPath($HomeRoot))
    $homeAuthorityKey = Get-LiveSyncHomeAuthorityKey -HomeRootLocationKey ([string] $homeContext.LocationKey)
    $liveContexts = [ordered]@{}
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $liveContexts[$platform] = Get-LiveSyncTargetContext -Path (Get-PlatformLiveRoot -Platform $platform)
    }

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

    $controlContext = Get-LiveSyncTargetContext -Path $ControlBase

    if ($OperationKind -ceq 'initial') {
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            if ([string] $liveContexts[$platform].TargetStatus -cne 'MISSING') {
                throw $script:LiveSyncSelectionMismatch
            }
        }
        # Pristine initial requires an unoccupied control base. Any existing
        # control base content fails closed as authority-present.
        if ([string] $controlContext.TargetStatus -cne 'MISSING') { throw $script:LiveSyncAuthorityPresent }

        $materializationPath = Get-LiveSyncMaterializationPath -PlanPath $PlanPath
        if ($Materialize) {
            $materialization = New-LiveSyncMaterializationEvidence -MaterializationPath $materializationPath -RepoRoot $repo
        }
        else {
            $materialization = Get-LiveSyncBoundMaterializationEvidence -MaterializationPath $materializationPath -RepoRoot $repo
        }
        $build = [System.Collections.IDictionary] $materialization['Build']

        $claims = [System.Collections.Generic.List[object]]::new()
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $claims.Add((New-LiveSyncRootClaimRow -Platform $platform -Context $liveContexts[$platform] -InitialState 'ABSENT'))
        }
        # RootClaimsHash binds the exact bytes of the complete root-claims
        # document that the apply publishes; the engine verifies and the
        # retirement flow re-reads those bytes unchanged.
        $claimsDocument = [ordered]@{
            SchemaVersion = 1
            ArtifactKind = 'root-claims'
            HomeAuthorityKey = $homeAuthorityKey
            TokenSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            ResolverVersion = $script:HomeAuthorityResolverVersion
            HomeRootLocationKey = [string] $homeContext.LocationKey
            LiveRootClaims = @($claims)
        }
        $claimsBytes = [byte[]] (ConvertTo-SemanticJsonBytes -InputObject $claimsDocument)
        $claimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($claimsBytes)).ToLowerInvariant()

        $overlaySkillsRows = Get-LiveSyncPlatformTriple -Map (Get-HarnessJsonProperty -Object $build -Name 'TaskOverlaySkills') -Kind 'Skills'
        $intent = [ordered]@{
            SchemaVersion = 3
            ArtifactKind = 'current-env-state'
            HomeAuthorityKey = $homeAuthorityKey
            AuthorityGeneration = 1
            RootClaimsHash = $claimsHash
            SelectionKind = 'environment'
            EnvironmentName = 'full'
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
            LastOperationKind = 'initial'
        }

        $orderedActions = [System.Collections.Generic.List[object]]::new()
        $order = 0L
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $stagedHashes = [System.Collections.IDictionary] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $build -Name 'StagedSkillTreeHashes') -Name $platform)
            $stagedSourceBase = Join-Path ([string] $materialization['Path']) ("$(([string] $platform).ToLowerInvariant())/skills")
            foreach ($name in (@([string[]] $stagedHashes.Keys) | Sort-Object { [string] $_ })) {
                # The engine verifies staged copies with the sealed safe-tree
                # hash family, so the reviewed action binds that family rather
                # than the build-side harness tree hash.
                $sourceHash = [string] (Get-SafeTreeSnapshot -Root (Join-Path $stagedSourceBase $name)).TreeHash
                if ($sourceHash -cnotmatch '\A[0-9a-f]{64}\z') { throw $script:LiveSyncUnsupportedApplyKind }
                $orderedActions.Add([ordered]@{
                    Order = $order
                    Platform = $platform
                    Action = 'add'
                    Name = $name
                    SourceHash = $sourceHash
                    LiveHash = $null
                })
                $order++
            }
        }

        $slots = [System.Collections.Generic.List[object]]::new()
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $slots.Add((New-LiveSyncPlatformSlot -Platform $platform -SourceRoot (Join-Path ([string] $materialization['Path']) ("$(([string] $platform).ToLowerInvariant())/skills")) -LiveRoot (Get-PlatformLiveRoot -Platform $platform) -ManagedNames $managedNames[$platform] -ManifestHash $manifestHashes[$platform]))
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

        $payload = [ordered]@{
            OperationKind = 'initial'
            Generator = 'scripts/sync.ps1'
            RepositoryCommit = [string] $git.RepositoryCommit
            RepoRoot = $repo
            ApprovedToolchainHash = $toolchainHash
            ControllerRepoFingerprint = $controllerFingerprint
            ControlBaseIntent = (New-LiveSyncControlBaseIntent -Context $controlContext)
            Platforms = @($slots)
            OrderedActions = @($orderedActions)
            UnknownMarkers = @()
            SystemMarker = [ordered]@{ Platform = 'Codex'; Name = $CodexSystemDirName; Present = $false; Identity = $null; Hash = $null }
            TargetContextIntent = [ordered]@{ HomeAuthorityKey = $homeAuthorityKey; Rows = @($claims) }
            AuthorityStateIntent = $intent
            EnvironmentName = 'full'
            EnvironmentMaterializationRoot = $materializationRoot
            ProposedRootClaims = $claimsDocument
            RootClaimsHash = $claimsHash
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($RetirementManifestPath)) { throw $script:LiveSyncRetirementManifestRequired }
        $manifest = Read-ExplicitRetirementManifest -Path $RetirementManifestPath
        $canonicalAuthorityRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        Assert-RetirementManifestIsExternal -ManifestPath $manifest.Path -ProtectedRoots @($canonicalAuthorityRoot, $repo, (Get-ClaudeLiveSkillsPath), (Get-CodexLiveSkillsPath), (Get-ReasonixLiveSkillsPath))
        $manifestEvidence = Resolve-PrivateArtifactPath -Path $manifest.Path -Role ExternalUserArtifact -RepoRoot $repo
        if ([string] $manifest.Hash -cne (Get-BytesSha256 -Bytes ([System.IO.File]::ReadAllBytes($manifestEvidence.FullPath)))) {
            throw $script:LiveSyncPlanHashMismatch
        }

        $retirementNames = [ordered]@{
            Claude = $manifest.Claude
            Codex = $manifest.Codex
            Reasonix = $manifest.Reasonix
        }

        $staleness = [ordered]@{}
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $staleness[$platform] = Get-RetirementStalenessEvidence -Platform $platform -SourceRoot (Join-Path $repo "$(([string] $platform).ToLowerInvariant())\skills") -LiveRoot (Get-PlatformLiveRoot -Platform $platform) -CanonicalRoots @(
                (Join-Path $repo 'skills-source\shared'), (Join-Path $repo "skills-source\$(([string] $platform).ToLowerInvariant())-only"),
                (Join-Path $canonicalAuthorityRoot 'skills-source\shared'), (Join-Path $canonicalAuthorityRoot "skills-source\$(([string] $platform).ToLowerInvariant())-only")
            ) -ManagedNames $managedNames[$platform] -RetiredNames $retirementNames[$platform]
        }

        # Retirement reads the seeded schema 3 authority state at the canonical
        # locator under the injected control base; it never invokes a writer.
        if ([string] $controlContext.TargetStatus -cne 'EXISTS') { throw $script:LiveSyncAuthorityMissing }
        $stateLocator = Join-Path (Join-Path $ControlBase 'homes') (Join-Path $homeAuthorityKey 'current-env.json')
        if (-not (Test-Path -LiteralPath $stateLocator -PathType Leaf)) { throw $script:LiveSyncAuthorityMissing }
        $stateCapture = Read-ExactJsonArtifactCapture -Path $stateLocator -Role EvidenceInputPath -RepoRoot $repo -EvidenceRoots @([System.IO.Path]::GetFullPath($ControlBase))
        $state = [System.Collections.IDictionary] $stateCapture.Document
        Assert-AuthoritySchemaBytes -ArtifactKind 'current-env-state' -InstanceBytes ([byte[]] $stateCapture.Bytes)
        Test-CurrentEnvStateSemantics -Document $state
        if ([string] $state['HomeAuthorityKey'] -cne $homeAuthorityKey) { throw $script:LiveSyncSelectionMismatch }

        $postsetSkillsRows = [System.Collections.Generic.List[object]]::new()
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $stateSkills = @()
            foreach ($row in @([object[]] $state['TaskOverlaySkills'])) {
                if ([string] $row['Platform'] -ceq $platform) { $stateSkills = @([string[]] @($row['Skills'])) }
            }
            $postsetSkillsRows.Add([ordered]@{ Platform = $platform; Skills = $stateSkills })
        }

        $manifestDocument = New-LiveSyncRetirementManifestEvidence -ManifestPath $manifestEvidence.FullPath -ManifestHash ([string] $manifest.Hash) -RetiredNames $retirementNames -StalenessEvidence $staleness -PostsetSkillsRows @($postsetSkillsRows) -PostsetEnvironmentName ([string] $state['EnvironmentName']) -PostsetEnvironmentLockHash ([string] $state['EnvironmentLockHash']) -PostsetTaskOverlayHash ([string] $state['TaskOverlayHash']) -PostsetManifestHashes @([object[]] $state['ManifestHashes'])

        $intent = [ordered]@{
            SchemaVersion = 3
            ArtifactKind = 'current-env-state'
            HomeAuthorityKey = [string] $state['HomeAuthorityKey']
            AuthorityGeneration = [long] $state['AuthorityGeneration']
            RootClaimsHash = [string] $state['RootClaimsHash']
            SelectionKind = [string] $state['SelectionKind']
            EnvironmentName = [string] $state['EnvironmentName']
            EnvironmentLockHash = [string] $state['EnvironmentLockHash']
            TaskOverlayHash = [string] $state['TaskOverlayHash']
            TaskOverlaySkills = @($postsetSkillsRows)
            ManifestHashes = @([object[]] $state['ManifestHashes'])
            FinalManagedHashes = @([object[]] $state['FinalManagedHashes'])
            ControllerRepoFingerprint = [string] $state['ControllerRepoFingerprint']
            ApprovedToolchainHash = [string] $state['ApprovedToolchainHash']
            LastOperationKind = 'retirement'
        }

        $orderedActions = [System.Collections.Generic.List[object]]::new()
        $order = 0L
        foreach ($platform in (@('Claude', 'Codex', 'Reasonix') | Sort-Object { $script:LiveSyncPlatformRank[[string] $_] })) {
            foreach ($name in (([string[]] $retirementNames[$platform]) | Sort-Object)) {
                $orderedActions.Add([ordered]@{
                    Order = $order
                    Platform = $platform
                    Action = 'prune'
                    Name = $name
                    SourceHash = $null
                    # The receipt snapshot verifies the preimage with the sealed
                    # safe-tree hash family.
                    LiveHash = [string] (Get-SafeTreeSnapshot -Root (Join-Path (Get-PlatformLiveRoot -Platform $platform) $name)).TreeHash
                    Authority = 'explicit-retirement'
                })
                $order++
            }
        }

        $unknownMarkers = [System.Collections.Generic.List[object]]::new()
        foreach ($platform in (@('Claude', 'Codex', 'Reasonix') | Sort-Object { $script:LiveSyncPlatformRank[[string] $_] })) {
            if ([string] $liveContexts[$platform].TargetStatus -cne 'EXISTS') {
                throw $script:LiveSyncSelectionMismatch
            }
            $liveRoot = Get-PlatformLiveRoot -Platform $platform
            $sourceRoot = Join-Path $repo "$(([string] $platform).ToLowerInvariant())\skills"
            $sourceNames = @(Get-DirNames -Path $sourceRoot)
            foreach ($child in (@(Get-DirNames -Path $liveRoot) | Sort-Object)) {
                if ($platform -ieq 'codex' -and [string] $child -ieq $CodexSystemDirName) { continue }
                if ([string] $child -cnotin $sourceNames -and -not $managedNames[$platform].Contains([string] $child) -and -not $retirementNames[$platform].Contains([string] $child)) {
                    $childContext = Get-LiveSyncTargetContext -Path (Join-Path $liveRoot $child)
                    $unknownMarkers.Add([ordered]@{
                        Platform = $platform
                        Name = [string] $child
                        LiveHash = (Get-SkillTreeHash -Path (Join-Path $liveRoot $child))
                        Managed = $false
                        Identity = [string] $childContext.DirectoryIdentity
                    })
                }
            }
        }

        $claims = [System.Collections.Generic.List[object]]::new()
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $claims.Add((New-LiveSyncRootClaimRow -Platform $platform -Context $liveContexts[$platform] -InitialState 'EXISTS'))
        }

        $slots = [System.Collections.Generic.List[object]]::new()
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $slots.Add((New-LiveSyncPlatformSlot -Platform $platform -SourceRoot (Join-Path $repo "$(([string] $platform).ToLowerInvariant())\skills") -LiveRoot (Get-PlatformLiveRoot -Platform $platform) -ManagedNames $managedNames[$platform] -ManifestHash $manifestHashes[$platform]))
        }

        $payload = [ordered]@{
            OperationKind = 'retirement'
            Generator = 'scripts/sync.ps1'
            RepositoryCommit = [string] $git.RepositoryCommit
            RepoRoot = $repo
            ApprovedToolchainHash = $toolchainHash
            ControllerRepoFingerprint = $controllerFingerprint
            ControlBaseIntent = (New-LiveSyncControlBaseIntent -Context $controlContext)
            Platforms = @($slots)
            OrderedActions = @($orderedActions)
            UnknownMarkers = @($unknownMarkers)
            SystemMarker = (Get-LiveSyncSystemMarker -CodexLiveRoot (Get-PlatformLiveRoot -Platform 'Codex'))
            TargetContextIntent = [ordered]@{ HomeAuthorityKey = $homeAuthorityKey; Rows = @($claims) }
            AuthorityStateIntent = $intent
            EnvironmentName = [string] $state['EnvironmentName']
            RetirementManifest = $manifestDocument
        }
    }

    $document = [ordered]@{
        SchemaVersion = 3
        ArtifactKind = 'sync-plan'
        Metadata = [ordered]@{ GeneratedAtUtc = [DateTime]::UtcNow.ToString('o') }
        PlanPayload = $payload
    }
    $document['PlanHash'] = Get-PlanHash -PlanPayload $payload
    $document['DocumentHash'] = Get-DocumentHash -Document $document
    return $document
}

# ---------------------------------------------------------------------------
# Centralized, audited destructive operations
# ---------------------------------------------------------------------------

function Assert-SafeLiveSkillTarget {
    # A target must be a direct child of $LiveRoot, must not be the root itself,
    # and must never be (or live under) Codex's .system directory.
    param(
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($LiveRoot).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar

    if (-not $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside live root: $pathFull"
    }
    $leaf = Split-Path -Leaf $pathFull
    if ($leaf -eq $CodexSystemDirName) {
        throw "Refusing to operate on Codex platform dir: $pathFull"
    }
    if ($pathFull -like "*$([System.IO.Path]::DirectorySeparatorChar)$CodexSystemDirName$([System.IO.Path]::DirectorySeparatorChar)*") {
        throw "Refusing to operate inside Codex .system: $pathFull"
    }
    # The target must be exactly one level under the root (a skill directory).
    $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $pathFull)).TrimEnd('\', '/')
    if ($parent -ne $rootFull) {
        throw "Refusing: target is not a direct skill dir under the live root: $pathFull"
    }
}

# ---------------------------------------------------------------------------
# Plan computation helpers
# ---------------------------------------------------------------------------

function New-CaseInsensitiveNameSet {
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    return , $set
}

function Read-ManagedNames {
    param([Parameter(Mandatory)] [string] $Path)
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            $t = $line.Trim()
            if ($t) { [void] $names.Add($t) }
        }
    }
    # Comma keeps the HashSet intact: a bare return enumerates it, and an EMPTY
    # set would unroll to automation-null, breaking .Count under StrictMode.
    return , $names
}

function Read-ExplicitRetirementManifest {
    param([AllowNull()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            Path = $null
            Hash = $null
            Claude = New-CaseInsensitiveNameSet
            Codex = New-CaseInsensitiveNameSet
            Reasonix = New-CaseInsensitiveNameSet
        }
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Retirement manifest does not exist: $Path"
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    if ($bytes.Length -gt 65536) {
        throw "Retirement manifest is unexpectedly large (>64 KiB): $resolvedPath"
    }

    try {
        $json = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch {
        throw "Retirement manifest must be valid UTF-8: $resolvedPath ($($_.Exception.Message))"
    }

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($json)
    }
    catch {
        throw "Retirement manifest is not valid JSON: $resolvedPath ($($_.Exception.Message))"
    }

    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'Retirement manifest root must be a JSON object.'
        }

        $requiredProperties = @('SchemaVersion', 'Claude', 'Codex', 'Reasonix')
        $allowedProperties = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($required in $requiredProperties) { [void] $allowedProperties.Add($required) }
        $seenProperties = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $properties = @($root.EnumerateObject())
        foreach ($property in $properties) {
            if (-not $allowedProperties.Contains($property.Name)) {
                throw "Retirement manifest contains unsupported property '$($property.Name)'."
            }
            if (-not $seenProperties.Add($property.Name)) {
                throw "Retirement manifest contains duplicate property '$($property.Name)'."
            }
        }
        foreach ($required in $requiredProperties) {
            if (-not $seenProperties.Contains($required)) {
                throw "Retirement manifest is missing required property '$required'."
            }
        }

        $schemaVersion = 0
        $schemaElement = $root.GetProperty('SchemaVersion')
        if ($schemaElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
            -not $schemaElement.TryGetInt32([ref] $schemaVersion) -or
            $schemaVersion -ne 1) {
            throw 'Retirement manifest SchemaVersion must be the integer 1.'
        }

        $sets = [ordered]@{}
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $set = New-CaseInsensitiveNameSet
            $platformElement = $root.GetProperty($platform)
            if ($platformElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
                throw "Retirement manifest property '$platform' must be an array."
            }
            foreach ($item in $platformElement.EnumerateArray()) {
                if ($item.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                    throw "Retirement manifest property '$platform' may contain only strings."
                }
                $name = $item.GetString()
                if ($name -ieq $CodexSystemDirName) {
                    throw 'Retirement manifest must never contain Codex .system.'
                }
                if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128 -or
                    $name -cnotmatch '^[a-z0-9](?:[a-z0-9_-]*[a-z0-9])?$') {
                    throw "Retirement manifest $platform skill name must be a lowercase safe bare identifier: '$name'."
                }
                if (-not $set.Add($name)) {
                    throw "Retirement manifest contains duplicate $platform skill '$name'."
                }
            }
            $sets[$platform] = $set
        }

        $retirementCount = $sets.Claude.Count + $sets.Codex.Count + $sets.Reasonix.Count
        if ($retirementCount -eq 0) {
            throw 'Retirement manifest must authorize at least one skill name.'
        }

        return [pscustomobject]@{
            Path = $resolvedPath
            Hash = Get-BytesSha256 -Bytes $bytes
            Claude = $sets.Claude
            Codex = $sets.Codex
            Reasonix = $sets.Reasonix
        }
    }
    finally {
        $document.Dispose()
    }
}

function Assert-RetirementManifestIsExternal {
    param(
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter(Mandatory)] [string[]] $ProtectedRoots
    )

    $manifestFull = [System.IO.Path]::GetFullPath($ManifestPath)
    foreach ($root in $ProtectedRoots) {
        $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
        if ($manifestFull -eq $rootFull -or $manifestFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Retirement manifest must be external to the repository and live skill roots: $manifestFull"
        }
    }
}

function Get-DirNames {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Directory -Force | ForEach-Object Name)
}

function Get-StringSha256 {
    param([Parameter(Mandatory)] [string] $Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-PathSha256 {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'missing'
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SkillTreeHash {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }

    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force)) {
        $relative = [System.IO.Path]::GetRelativePath($Path, $file.FullName) -replace '\\', '/'
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $rows.Add("$relative|$($file.Length)|$hash")
    }

    return Get-StringSha256 -Text ((@($rows | Sort-Object) -join "`n") + "`n")
}

function Write-PlanSummary {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Payload)

    $kind = [string] $Payload['OperationKind']
    Write-Host "Operation kind  : $kind"
    Write-Host "Environment     : $(if ($Payload.Contains('EnvironmentName')) { [string] $Payload['EnvironmentName'] } else { '<unchanged>' })"
    $counts = @{}
    foreach ($action in @([object[]] $Payload['OrderedActions'])) {
        $verb = [string] $action['Action']
        if (-not $counts.ContainsKey($verb)) { $counts[$verb] = 0 }
        $counts[$verb] = $counts[$verb] + 1
    }
    foreach ($verb in @('add', 'update', 'no-op', 'prune')) {
        $count = if ($counts.ContainsKey($verb)) { $counts[$verb] } else { 0 }
        Write-Host "  would $verb ($count)"
    }
    $unknownTotal = @([object[]] $Payload['UnknownMarkers']).Count
    Write-Host "  unknown dirs ($unknownTotal) (ignored, never deleted)"
    if ([string] $kind -ceq 'retirement') {
        $retired = [System.Collections.Generic.List[string]]::new()
        foreach ($action in @([object[]] $Payload['OrderedActions'])) {
            if ([string] $action['Action'] -ceq 'prune') { $retired.Add("$($action['Platform'])/$($action['Name'])") }
        }
        Write-Host "  retirement-authorized targets: $([string]::Join(', ', $retired))"
    }
}

# ---------------------------------------------------------------------------
# Child-process helpers (build / scan / backup)
# ---------------------------------------------------------------------------

function Invoke-ChildScript {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [string[]] $Arguments = @()
    )
    $script = Join-Path $PSScriptRoot $ScriptName
    # Stream child output straight to the host so only the exit code is returned.
    & pwsh -NoProfile -File $script @Arguments | Out-Host
    return $LASTEXITCODE
}

function Write-SyncRunReport {
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'WARN', 'FAIL')] [string] $Result,
        [Parameter(Mandatory)] [string] $NextAction,
        [object[]] $Plans = @(),
        [string] $BuildResult = 'Not run',
        [string] $SecretsScanResult = 'Not run',
        [AllowNull()] [System.Collections.IDictionary] $AppliedCounts,
        [string] $SystemStatus = 'Not available'
    )

    if (-not (Get-Command Write-RunReport -ErrorAction SilentlyContinue)) {
        return
    }

    $planAdded = 0
    $planModified = 0
    $planRemoved = 0
    $planUnknown = 0
    $planNoOp = 0
    $addedDetails = [System.Collections.Generic.List[string]]::new()
    $modifiedDetails = [System.Collections.Generic.List[string]]::new()
    $removedDetails = [System.Collections.Generic.List[string]]::new()
    $unknownDetails = [System.Collections.Generic.List[string]]::new()
    $noOpDetails = [System.Collections.Generic.List[string]]::new()
    foreach ($plan in @($Plans)) {
        $planAdded += @($plan.Add).Count
        $planModified += @($plan.Update).Count
        $planRemoved += @($plan.Prune).Count
        $planUnknown += @($plan.Unknown).Count
        $planNoOp += @($plan.NoOp).Count
        foreach ($name in @($plan.Add)) { $addedDetails.Add("ADD: $($plan.Platform)/$name") }
        foreach ($name in @($plan.Update)) { $modifiedDetails.Add("MODIFY: $($plan.Platform)/$name") }
        foreach ($entry in @($plan.PruneEntries)) { $removedDetails.Add("REMOVE [$($entry.Authority)]: $($plan.Platform)/$($entry.Name)") }
        foreach ($name in @($plan.Unknown)) { $unknownDetails.Add("SKIPPED UNKNOWN (preserved): $($plan.Platform)/$name") }
        foreach ($name in @($plan.NoOp)) { $noOpDetails.Add("NO-OP: $($plan.Platform)/$name") }
    }

    $addedValue = if (@($Plans).Count -gt 0) { $planAdded } else { 'Not available' }
    $modifiedValue = if (@($Plans).Count -gt 0) { $planModified } else { 'Not available' }
    $removedValue = if (@($Plans).Count -gt 0) { $planRemoved } else { 'Not available' }
    if ($Apply -and $null -ne $AppliedCounts) {
        $addedValue = [int] $AppliedCounts.ClaudeAdded + [int] $AppliedCounts.CodexAdded + [int] $AppliedCounts.ReasonixAdded
        $modifiedValue = [int] $AppliedCounts.ClaudeUpdated + [int] $AppliedCounts.CodexUpdated + [int] $AppliedCounts.ReasonixUpdated
        $removedValue = [int] $AppliedCounts.ClaudePruned + [int] $AppliedCounts.CodexPruned + [int] $AppliedCounts.ReasonixPruned
    }

    if ($SystemStatus -eq 'Not available') {
        $codexPlanForReport = @($Plans | Where-Object Platform -eq 'codex' | Select-Object -First 1)
        if ($codexPlanForReport.Count -gt 0) {
            $SystemStatus = if ($codexPlanForReport[0].SystemPreserved) { 'PRESERVED' } else { 'Not present' }
        }
    }

    $mode = if ($Apply) { 'apply' } else { 'dry-run' }
    $removalSection = if (-not $Apply) { 'Removed items (planned)' }
        elseif ($Result -eq 'PASS' -or $Result -eq 'WARN') { 'Removed items (applied or attempted)' }
        else { 'Removed items (planned; inspect result before assuming application)' }

    $summary = [ordered] @{
        Added = $addedValue
        Modified = $modifiedValue
        Removed = $removedValue
        Skipped = if (@($Plans).Count -gt 0) { $planUnknown } else { 'Not available' }
        'Unchanged managed skills' = if (@($Plans).Count -gt 0) { $planNoOp } else { 'Not available' }
        Conflicts = 'Not available'
        Quarantined = 'Not available'
        'Unknown live skills' = if (@($Plans).Count -gt 0) { $planUnknown } else { 'Not available' }
        '.system status' = $SystemStatus
        'Secrets scan result' = $SecretsScanResult
        'Build result' = $BuildResult
    }
    $details = [ordered] @{
        'Added items' = @($addedDetails)
        'Modified items' = @($modifiedDetails)
        $removalSection = @($removedDetails)
        'Skipped and unknown live skills' = @($unknownDetails)
        'Unchanged items' = @($noOpDetails)
        '.system' = @("${SystemStatus}: preserved-required; sync report never contains .system contents.")
    }

    try {
        $reportPath = Write-RunReport -RepoRoot $RepoRoot -ReportKind 'sync' -ScriptName 'scripts/sync.ps1' -Mode $mode -Summary $summary -Details $details -Result $Result -NextAction $NextAction
        Write-Host "Sync report: $reportPath"
    }
    catch {
        Write-Warning "Sync completed its original flow, but report creation failed: $($_.Exception.Message)"
    }
}
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$buildRunResult = 'Not run'
$secretsScanRunResult = 'Not run'


$injectedPaths = @()
if ((Test-LiveSafetySandboxCapability)) {
    foreach ($name in @('AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT', 'AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT', 'AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE')) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $injectedPaths += ([System.IO.Path]::GetFullPath($value)) }
    }
    foreach ($value in @($PlanPath, $RetireManifestPath, $ReasonixLiveSkillsPath)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) { $injectedPaths += ([System.IO.Path]::GetFullPath($value)) }
    }
}

# The tracked interlock is the first gate of every -Apply, before the reviewed
# plan requirement and the build/scan gates.
if ($Apply) {
    $interlockPaths = @($RepoRoot, $ReasonixLiveSkillsPath, $PlanPath, $RetireManifestPath)
    $interlockPaths = @($interlockPaths) + $injectedPaths
    Assert-LiveSafetyMutationAllowed -Operation $(if ($RetireManifestPath) { 'retirement-sync' } else { 'sync' }) -Paths $interlockPaths
}

if ($Apply -and [string]::IsNullOrWhiteSpace($PlanPath)) {
    Write-Host 'ERROR: -Apply requires a reviewed -PlanPath generated by a prior -DryRun.'
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Run sync with -DryRun -PlanPath <external-plan.json>, review it, then rerun -Apply with the same -PlanPath.'
    exit 1
}

$internalRoots = Resolve-LiveSyncInternalRoots
$HomeRoot = $internalRoots.HomeRoot
$BackupRoot = $internalRoots.BackupRoot
$ControlBase = $internalRoots.ControlBase
$authorityContext = New-LiveSyncAuthorityContext -HomeRoot $HomeRoot -ControlBase $ControlBase -BackupRoot $BackupRoot

Write-Host '=== sync.ps1 (schema 3 semantic plan) ==='
Write-Host "Mode            : $(if ($Apply) { 'APPLY' } else { 'DRY-RUN (no live changes)' })"
Write-Host "Repo            : $RepoRoot"
Write-Host "Home root       : $HomeRoot"
Write-Host "Backup root     : $BackupRoot"
Write-Host "Control base    : $ControlBase"

# --- build ---
if ($SkipBuild) {
    Write-Host 'Build           : SKIPPED (-SkipBuild)'
    $buildRunResult = 'SKIPPED (-SkipBuild)'
} else {
    Write-Host 'Build           : running build-skills.ps1 ...'
    $code = Invoke-ChildScript -ScriptName 'build-skills.ps1'
    if ($code -ne 0) {
        $buildRunResult = "FAIL (exit $code)"
        Write-Host "ERROR: build-skills.ps1 failed (exit $code)."
        Write-SyncRunReport -Result 'FAIL' -NextAction 'Resolve the build failure, then rerun sync in dry-run mode.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
        exit 1
    }
    $buildRunResult = 'PASS'
    Write-Host 'Build           : OK'
}

# --- secret scan ---
if ($SkipSecretScan) {
    Write-Host 'Secret scan     : SKIPPED (-SkipSecretScan)'
    $secretsScanRunResult = 'SKIPPED (-SkipSecretScan)'
} else {
    Write-Host 'Secret scan     : running scan-secrets.ps1 ...'
    $code = Invoke-ChildScript -ScriptName 'scan-secrets.ps1'
    if ($code -ne 0) {
        $secretsScanRunResult = "FAIL (exit $code)"
        Write-Host "ERROR: scan-secrets.ps1 failed (exit $code)."
        Write-SyncRunReport -Result 'FAIL' -NextAction 'Remove or resolve the blocking secret finding, then rerun sync in dry-run mode.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
        exit 1
    }
    $secretsScanRunResult = 'PASS'
    Write-Host 'Secret scan     : OK'
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'claude\skills')) -or
    -not (Test-Path -LiteralPath (Join-Path $RepoRoot 'codex\skills')) -or
    -not (Test-Path -LiteralPath (Join-Path $RepoRoot 'reasonix\skills'))) {
    Write-Host 'ERROR: generated output missing. Run build-skills.ps1 (do not pass -SkipBuild).'
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Restore generated output by running build-skills.ps1, then rerun sync in dry-run mode.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 1
}

$syncPlans = @()


if (-not $Apply) {
    if ([string]::IsNullOrWhiteSpace($PlanPath)) {
        Write-Host 'ERROR: -DryRun requires a create-new -PlanPath for the schema 3 semantic plan.'
        Write-SyncRunReport -Result 'FAIL' -NextAction 'Run sync with -DryRun -PlanPath <external-plan.json> inside the internal sandbox.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
        exit 1
    }
    $planFull = [System.IO.Path]::GetFullPath($PlanPath)
    if (Test-Path -LiteralPath $planFull) { throw $script:LiveSyncPathCollision }
    $null = Resolve-PrivateArtifactPath -Path $planFull -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf

    Write-Host ''
    $operationKind = if ($RetireManifestPath) { 'retirement' } else { 'initial' }
    Write-Host "Producer        : $operationKind"
    $document = New-LiveSyncPlanDocument -OperationKind $operationKind -RepoRoot $RepoRoot -HomeRoot $HomeRoot -ControlBase $ControlBase -RetirementManifestPath $RetireManifestPath -PlanPath $planFull -Materialize
    Write-LiveSyncPlan -Path $planFull -Document $document
    Write-Host "Plan path       : $planFull"
    Write-Host "Plan hash       : $([string] $document['PlanHash'])"
    Write-Host "Document hash   : $([string] $document['DocumentHash'])"
    Write-PlanSummary -Payload ([System.Collections.IDictionary] $document['PlanPayload'])

    Write-Host ''
    Write-Host 'DRY-RUN complete. No live files were changed. Review the schema 3 plan, then rerun with -Apply.'
    Write-SyncRunReport -Result 'PASS' -NextAction 'Review the schema 3 plan; use -Apply only when the plan is expected and a backup will be created.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 0
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '----- APPLY -----'

$planFull = [System.IO.Path]::GetFullPath($PlanPath)
if (-not (Test-Path -LiteralPath $planFull -PathType Leaf)) {
    Write-Host "ERROR: plan file does not exist: $planFull. Run sync in dry-run mode with -PlanPath first."
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Run sync with -DryRun -PlanPath <external-plan.json>, review it, then rerun -Apply with the same -PlanPath.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 1
}
$null = Resolve-PrivateArtifactPath -Path $planFull -Role ExternalUserArtifact -RepoRoot $RepoRoot

$saved = Read-LiveSyncPlan -Path $planFull
$savedPayload = [System.Collections.IDictionary] $saved['PlanPayload']
$savedKind = [string] $savedPayload['OperationKind']
if ($savedKind -cnotin @('initial', 'retirement')) { throw $script:LiveSyncUnsupportedApplyKind }
if ($savedKind -ceq 'retirement' -and [string]::IsNullOrWhiteSpace($RetireManifestPath)) {
    throw $script:LiveSyncRetirementManifestRequired
}

# Retirement plans are recomputed and hash-compared against the machine.
# Initial plans cannot be: the reviewed pristine plan is produced before the
# authority prefix exists and the apply bootstraps it, so the control-base
# intent legitimately changes between planning and apply. Initial staleness
# is guarded instead by the materialization integrity check below plus the
# host's under-lock authority and live-rows revalidation.
if ($savedKind -ceq 'retirement') {
    $current = New-LiveSyncPlanDocument -OperationKind $savedKind -RepoRoot $RepoRoot -HomeRoot $HomeRoot -ControlBase $ControlBase -RetirementManifestPath $RetireManifestPath -PlanPath $planFull
    if ((Get-PlanHash -PlanPayload ([System.Collections.IDictionary] $current['PlanPayload'])) -cne [string] $saved['PlanHash']) {
        throw $script:LiveSyncPlanHashMismatch
    }
}

Assert-LiveSyncPlanDocumentIntegrity -Document ([System.Collections.IDictionary] $saved)
if ($savedPayload.Contains('EnvironmentMaterializationRoot')) {
    $null = Assert-LiveSyncPlanCurrent -Document ([System.Collections.IDictionary] $saved) -MaterializationDirectory ([string] (([System.Collections.IDictionary] $savedPayload['EnvironmentMaterializationRoot'])['Path']))
}
$expectedEnvironmentName = [string] $savedPayload['EnvironmentName']
$null = Assert-LiveSyncPlanSelectionContext -Document ([System.Collections.IDictionary] $saved) -ExpectedOperationKind $savedKind -ExpectedEnvironmentName $expectedEnvironmentName
$null = Assert-LiveSyncPlanDocumentHashNotConsumed -Document ([System.Collections.IDictionary] $saved) -TerminalEvidence $null
Write-Host 'Plan binding    : verified'
Write-Host "Plan hash       : $([string] $saved['PlanHash'])"
Write-Host "Document hash   : $([string] $saved['DocumentHash'])"
Write-PlanSummary -Payload $savedPayload

# ---------------------------------------------------------------------------
# Receipt-backed host Apply (both operation kinds route identically)
# ---------------------------------------------------------------------------

# The authority prefix must already exist (it is bootstrapped by the env
# activation flow together with the canonical setup): sync never bootstraps
# and refuses MISSING or PARTIAL prefixes fail-closed before any mutation.
$bootstrapStatus = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $authorityContext
if ([string] $bootstrapStatus.Status -cne 'COMPLETE') { throw $script:LiveSyncAuthorityMissing }

# Per-platform same-volume staging roots (also the mutation-preflight probe
# roots) and the probed filesystem capability hashes bound into the receipt
# and the state postimage. The staging base sits directly under the home root:
# same volume as every live target, outside the private root base whose
# immediate children the fixed envelope pins to backups/ and control/.
$stagingBase = Join-Path $HomeRoot '.ai-agent-dotfiles-staging'
$stagingRootsByPlatform = [ordered]@{}
$capabilityHashesByPlatform = [ordered]@{}
foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
    $liveRoot = Get-PlatformLiveRoot -Platform $platform
    $stagingRootPath = Join-Path $stagingBase $platform
    New-Item -ItemType Directory -Force -Path $stagingRootPath | Out-Null
    $stagingRootsByPlatform[$platform] = [System.IO.Path]::GetFullPath($stagingRootPath)
    $preflight = Resolve-TargetContext -Path $liveRoot -Mode MutationPreflight -ProbeRoot $stagingRootPath -HomeRoot $HomeRoot -ForbiddenRoots @($ControlBase, $BackupRoot)
    if ([string] $preflight.FilesystemCapabilityStatus -cne 'SUPPORTED' -or
        [string] $preflight.FilesystemCapabilityHash -cnotmatch $script:LiveTransactionHashPattern) {
        throw $script:LiveSyncUnsupportedApplyKind
    }
    $capabilityHashesByPlatform[$platform] = [string] $preflight.FilesystemCapabilityHash
}

$sourceRootsByPlatform = [ordered]@{}
$liveRootsByPlatform = [ordered]@{}
foreach ($slot in @([object[]] $savedPayload['Platforms'])) {
    $sourceRootsByPlatform[[string] $slot['Platform']] = [System.IO.Path]::GetFullPath([string] $slot['SourceRoot'])
    $liveRootsByPlatform[[string] $slot['Platform']] = [System.IO.Path]::GetFullPath([string] $slot['LiveRoot'])
}

Write-Host 'Running the receipt-backed live transaction host ...'
# The approved toolchain root is the controller repository carrying the
# contract schemas, not the sync target repository.
$toolchainRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hostResult = Invoke-SealedLiveTransactionHost -Plan ([System.Collections.IDictionary] $saved) -RepoRoot $RepoRoot -ControlBase $ControlBase -BackupRoot $BackupRoot -StagingRootsByPlatform $stagingRootsByPlatform -SourceRootsByPlatform $sourceRootsByPlatform -FinalCapabilityHashesByPlatform $capabilityHashesByPlatform -AuthorityContext $authorityContext -WorkingTreeRoots ([ordered]@{ RepoRoot = $RepoRoot; ToolchainRoot = $toolchainRoot }) -ToolchainRoot $toolchainRoot
Write-Host "Transaction id  : $([string] $hostResult.TransactionId)"
Write-Host "Receipt path    : $([string] $hostResult.ReceiptPath)"
Write-Host "State hash      : $([string] $hostResult.StateHash)"

# Post-apply verification: every planned action reaches its reviewed end
# state and the Codex .system marker is preserved.
$verificationFailed = $false
foreach ($action in @([object[]] $savedPayload['OrderedActions'])) {
    $target = Join-Path ([string] $liveRootsByPlatform[[string] $action['Platform']]) ([string] $action['Name'])
    $exists = Test-Path -LiteralPath $target
    if (([string] $action['Action'] -ceq 'prune') -and $exists) {
        Write-Host "ERROR: reviewed retirement target still present: $target"
        $verificationFailed = $true
    }
    if (([string] $action['Action'] -cne 'prune') -and -not $exists) {
        Write-Host "ERROR: planned target missing after apply: $target"
        $verificationFailed = $true
    }
}
$systemOk = Test-Path -LiteralPath (Join-Path (Join-Path ([string] $liveRootsByPlatform['Codex']) $CodexSystemDirName) '.codex-system-skills.marker')
Write-Host ".system marker preserved: $systemOk"
if ($verificationFailed) {
    Write-Host 'ERROR: post-apply verification failed; inspect the transaction journal and receipt.'
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Inspect the live transaction journal and receipt before retrying.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 1
}

Write-Host ''
Write-Host 'APPLY complete through the receipt-backed host.'
exit 0
