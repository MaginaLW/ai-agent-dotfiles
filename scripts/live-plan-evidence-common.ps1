#requires -Version 7.0
<#
.SYNOPSIS
    Shared plan-evidence helpers for the live-safety plan producers.

.DESCRIPTION
    This file is intended to be dot-sourced. It carries the producer-side helper
    family that both `scripts/sync.ps1` and `scripts/authority-harness-env.ps1`
    need: host-injected root resolution, the HomeAuthority key and approved
    toolchain hash, target contexts and root-claim rows, platform slots, the
    task-overlay/manifest binding, the create-new environment materialization
    evidence, the audited live-target guard, and the byte/tree hash helpers.
    Every helper is read-only except the create-new materialization that
    `Invoke-HarnessEnvMaterialization` owns; nothing here takes a lock or
    mutates live state.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'harness-env-common.ps1')
. (Join-Path $PSScriptRoot 'target-context-common.ps1')
. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')

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
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $Name = 'full'
    )

    if (Test-Path -LiteralPath $MaterializationPath) { throw $script:LiveSyncPathCollision }
    $materialization = Invoke-HarnessEnvMaterialization -Name $Name -Destination $MaterializationPath -RepoRoot $RepoRoot
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
# Centralized, audited destructive operations
# ---------------------------------------------------------------------------

function Get-LiveSyncUnknownMarkers {
    # Every live directory that is not a managed skill and not the Codex
    # platform directory is recorded as an unknown marker so the plan and the
    # apply-side postconditions can prove it was preserved untouched.
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $ManagedNames
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $LiveRoot -PathType Container)) { return @($rows) }
    foreach ($directory in @(Get-ChildItem -LiteralPath $LiveRoot -Directory -Force | Sort-Object Name)) {
        if ($directory.Name -ceq $CodexSystemDirName) { continue }
        if ($ManagedNames.Contains($directory.Name)) { continue }
        $marker = Get-NoFollowRootEntryMarker -Path $directory.FullName
        $treeHash = Get-SkillTreeHash -Path $directory.FullName
        $rows.Add([ordered]@{
            Platform = $Platform
            Name = [string] $directory.Name
            LiveHash = $treeHash
            Managed = $false
            Identity = [string] $marker.Identity
        })
    }
    return @($rows)
}

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
