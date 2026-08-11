#requires -Version 7.0
<#
.SYNOPSIS
    Manifest-scoped sync of generated skill output into the live Claude / Codex /
    Reasonix skill directories. Safe by default (dry-run); only mutates with -Apply.

.DESCRIPTION
    Source of truth is the build output: claude/skills, codex/skills, and
    reasonix/skills. For each platform the script computes add / update / prune
    plans scoped to per-platform repo-managed skill manifests and operates ONE
    skill directory at a time.

    Hard safety rules:
      * Never whole-dir mirror (no robocopy /MIR) against a live skills root.
      * Never touch Codex's platform-managed .system directory.
      * Prune only removes skill dirs whose name is in the platform's managed-skills
        manifest, or is explicitly authorized by a reviewed one-shot retirement
        manifest, AND is no longer present in the generated output. Other unknown
        live dirs are reported only.
      * -Apply always runs build + secret scan + a backup first; all must pass.

.PARAMETER Apply
    Actually perform the sync. Without it the script is a pure dry-run.

.PARAMETER DryRun
    Explicitly select dry-run mode. This is equivalent to omitting -Apply and cannot
    be combined with -Apply.

.PARAMETER SkipBuild
    Skip running scripts/build-skills.ps1 first (use the existing generated output).

.PARAMETER SkipSecretScan
    Skip running scripts/scan-secrets.ps1. Not recommended; default is to scan.

.PARAMETER BackupRoot
    Passed to scripts/backup.ps1 when -Apply creates the mandatory pre-change backup.

.PARAMETER HomeRoot
    Home directory used to resolve live skill paths. Defaults to $env:USERPROFILE.

.PARAMETER ReasonixLiveSkillsPath
    Optional override for the Reasonix live skills target directory.

.PARAMETER PlanPath
    Optional path for a machine-readable dry-run plan. When supplied on -DryRun,
    the plan and its SHA-256 fingerprint are written to this path. When supplied
    on -Apply, the current plan must match the saved fingerprint before any live
    changes are made.

.PARAMETER RetireManifestPath
    Optional path to a one-shot JSON retirement manifest. This is the explicit
    deletion authority for reviewed skills that were removed from both generated
    output and the current managed manifests. Its exact bytes and per-platform
    names are bound into the dry-run plan fingerprint, so the same unchanged file
    must be supplied again on -Apply. It never grants authority over .system or a
    skill that is still present in generated output/current manifests.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $DryRun,
    [switch] $SkipBuild,
    [switch] $SkipSecretScan,
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
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
if ($Apply -and $DryRun) { throw 'Specify -DryRun or -Apply, not both.' }
if ($Apply) {
    Assert-LiveSafetyMutationAllowed -Operation $(if ($RetireManifestPath) { 'retirement-sync' } else { 'sync' }) -Paths @(
        $RepoRoot, $HomeRoot, $BackupRoot, $ReasonixLiveSkillsPath, $PlanPath, $RetireManifestPath
    )
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$reportHelper = Join-Path $PSScriptRoot 'report-common.ps1'
if (Test-Path -LiteralPath $reportHelper) {
    . $reportHelper
}
else {
    Write-Warning "Report helper missing: $reportHelper"
}
$HomeRoot = if (Test-Path -LiteralPath $HomeRoot) {
    (Resolve-Path -LiteralPath $HomeRoot).Path
} else {
    [System.IO.Path]::GetFullPath($HomeRoot)
}
$CodexSystemDirName = '.system'

# ---------------------------------------------------------------------------
# Path probing
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

function Sync-OneSkillDir-Transactional {
    # Build a replacement beside the live target, verify its content, then
    # replace the target with a same-volume move. The old target remains in a
    # rollback name until the replacement succeeds.
    param(
        [Parameter(Mandatory)] [string] $SourceSkillDir,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $Name
    )

    $dest = Join-Path $LiveRoot $Name
    Assert-SafeLiveSkillTarget -LiveRoot $LiveRoot -Path $dest
    New-Item -ItemType Directory -Force -Path $LiveRoot | Out-Null

    $runId = [Guid]::NewGuid().ToString('N')
    $stageRoot = Join-Path $LiveRoot ".ai-agent-dotfiles-staging-$runId"
    $rollback = Join-Path $LiveRoot ".ai-agent-dotfiles-rollback-$runId"
    $stageSkill = Join-Path $stageRoot $Name
    $movedOldTarget = $false
    $movedStageIntoPlace = $false
    try {
        New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
        Copy-Item -LiteralPath $SourceSkillDir -Destination $stageRoot -Recurse -Force

        $expectedHash = Get-SkillTreeHash -Path $SourceSkillDir
        $actualHash = Get-SkillTreeHash -Path $stageSkill
        if ($expectedHash -ne $actualHash) {
            throw "Staging verification failed for $Name. Expected=$expectedHash Actual=$actualHash"
        }

        if (Test-Path -LiteralPath $dest -PathType Container) {
            Move-Item -LiteralPath $dest -Destination $rollback
            $movedOldTarget = $true
        }
        Move-Item -LiteralPath $stageSkill -Destination $dest
        $movedStageIntoPlace = $true

        if ($movedOldTarget -and (Test-Path -LiteralPath $rollback)) {
            Remove-Item -LiteralPath $rollback -Recurse -Force
        }
    }
    catch {
        try {
            if ($movedStageIntoPlace -and (Test-Path -LiteralPath $dest)) {
                Remove-Item -LiteralPath $dest -Recurse -Force
            }
            if ($movedOldTarget -and (Test-Path -LiteralPath $rollback) -and -not (Test-Path -LiteralPath $dest)) {
                Move-Item -LiteralPath $rollback -Destination $dest
            }
        }
        catch {
            throw "Transactional sync failed for $Name and rollback also failed. Rollback path: $rollback. Original error: $($_.Exception.Message)"
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $rollback) {
            Remove-Item -LiteralPath $rollback -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Sync-OneSkillDir {
    param(
        [Parameter(Mandatory)] [string] $SourceSkillDir,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $Name
    )

    Sync-OneSkillDir-Transactional -SourceSkillDir $SourceSkillDir -LiveRoot $LiveRoot -Name $Name
}

function Remove-OneSkillDir {
    # Remove a single stale repo-managed skill dir from a live root.
    param(
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [string] $ExpectedHash
    )

    $dest = Join-Path $LiveRoot $Name
    Assert-SafeLiveSkillTarget -LiveRoot $LiveRoot -Path $dest
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) {
        if ($ExpectedHash) {
            throw "Refusing to prune missing or non-directory skill '$Name'. Reviewed=$ExpectedHash"
        }
        return
    }

    $rollback = Join-Path $LiveRoot ".ai-agent-dotfiles-prune-$([Guid]::NewGuid().ToString('N'))"
    try {
        Move-Item -LiteralPath $dest -Destination $rollback
        if ($ExpectedHash) {
            $movedHash = Get-SkillTreeHash -Path $rollback
            if ($movedHash -ne $ExpectedHash) {
                throw "Refusing to prune changed skill '$Name'. Reviewed=$ExpectedHash Current=$movedHash"
            }
        }
        Remove-Item -LiteralPath $rollback -Recurse -Force
    }
    catch {
        if ((Test-Path -LiteralPath $rollback) -and -not (Test-Path -LiteralPath $dest)) {
            Move-Item -LiteralPath $rollback -Destination $dest -ErrorAction SilentlyContinue
        }
        throw
    }
}

# ---------------------------------------------------------------------------
# Plan computation
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

function Assert-RetirementNamesAreStale {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string[]] $CanonicalRoots,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $ManagedNames,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $RetiredNames
    )

    $evidenceRows = [System.Collections.Generic.List[string]]::new()
    $sourceNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(Get-DirNames -Path $SourceRoot)) { [void] $sourceNames.Add($name) }
    foreach ($canonicalRoot in @($CanonicalRoots | Sort-Object -Unique)) {
        $evidenceRows.Add("$Platform|root|$([System.IO.Path]::GetFullPath($canonicalRoot))")
    }
    foreach ($name in $RetiredNames) {
        if ($sourceNames.Contains($name)) {
            throw "Retirement manifest cannot authorize active $Platform source skill '$name'."
        }
        foreach ($canonicalRoot in @($CanonicalRoots | Sort-Object -Unique)) {
            $canonicalPath = Join-Path $canonicalRoot $name
            $canonicalState = if (Test-Path -LiteralPath $canonicalPath -PathType Container) { 'directory' }
                elseif (Test-Path -LiteralPath $canonicalPath -PathType Leaf) { 'file' }
                else { 'missing' }
            $evidenceRows.Add("$Platform|$name|$([System.IO.Path]::GetFullPath($canonicalPath))|$canonicalState")
            if ($canonicalState -ne 'missing') {
                throw "Retirement manifest cannot authorize canonical $Platform skill '$name'."
            }
        }
        if ($ManagedNames.Contains($name)) {
            throw "Retirement manifest cannot authorize current $Platform managed skill '$name'."
        }

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

    return Get-StringSha256 -Text ((@($evidenceRows | Sort-Object) -join "`n") + "`n")
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

function Get-PlanFingerprintInput {
    param([Parameter(Mandatory)] [object[]] $Plans)

    return @($Plans | ForEach-Object {
        [ordered]@{
            Platform = $_.Platform
            SourceRoot = [System.IO.Path]::GetFullPath($_.SourceRoot)
            LiveRoot = [System.IO.Path]::GetFullPath($_.LiveRoot)
            SourceCount = $_.SourceCount
            SourceRootExists = [bool] $_.SourceRootExists
            LiveRootExists = [bool] $_.LiveRootExists
            ManifestHash = $_.ManifestHash
            ManagedNames = @($_.ManagedNames | Sort-Object)
            CanonicalAuthorityRoot = $_.CanonicalAuthorityRoot
            CanonicalRetirementEvidenceHash = $_.CanonicalRetirementEvidenceHash
            RetirementManifestPath = $_.RetirementManifestPath
            RetirementManifestHash = $_.RetirementManifestHash
            RetiredNames = @($_.RetiredNames | Sort-Object)
            Add = @($_.Add | Sort-Object)
            AddEntries = @($_.AddEntries | Sort-Object Name | ForEach-Object {
                [ordered]@{ Name = $_.Name; SourceHash = $_.SourceHash; LiveHash = $_.LiveHash }
            })
            Update = @($_.UpdateEntries | Sort-Object Name | ForEach-Object {
                [ordered]@{ Name = $_.Name; SourceHash = $_.SourceHash; LiveHash = $_.LiveHash }
            })
            NoOp = @($_.NoOpEntries | Sort-Object Name | ForEach-Object {
                [ordered]@{ Name = $_.Name; SourceHash = $_.SourceHash; LiveHash = $_.LiveHash }
            })
            Prune = @($_.Prune | Sort-Object)
            PruneEntries = @($_.PruneEntries | Sort-Object Name | ForEach-Object {
                [ordered]@{ Name = $_.Name; SourceHash = $_.SourceHash; LiveHash = $_.LiveHash; Managed = [bool] $_.Managed; Authority = $_.Authority }
            })
            Unknown = @($_.Unknown | Sort-Object)
            UnknownEntries = @($_.UnknownEntries | Sort-Object Name | ForEach-Object {
                [ordered]@{ Name = $_.Name; LiveHash = $_.LiveHash; Managed = [bool] $_.Managed }
            })
            SystemPreserved = [bool] $_.SystemPreserved
        }
    })
}

function Get-PlansHash {
    param([Parameter(Mandatory)] [object[]] $Plans)

    $json = ConvertTo-Json -InputObject (Get-PlanFingerprintInput -Plans $Plans) -Depth 20 -Compress
    return Get-StringSha256 -Text $json
}

function Get-SavedPlansHash {
    param([Parameter(Mandatory)] [object[]] $Plans)

    $json = ConvertTo-Json -InputObject @($Plans) -Depth 20 -Compress
    return Get-StringSha256 -Text $json
}

function Write-SyncPlanFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $Plans,
        [Parameter(Mandatory)] [string] $PlanHash
    )

    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $document = [ordered]@{
        SchemaVersion = 2
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        PlanHash = $PlanHash
        Plans = Get-PlanFingerprintInput -Plans $Plans
    }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 30) + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host "Sync plan       : $Path"
    Write-Host "Plan hash       : $PlanHash"
}

function Assert-SyncPlanFileMatches {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $CurrentPlanHash
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Plan file does not exist: $Path. Run sync in dry-run mode with -PlanPath first."
    }
    try {
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        throw "Plan file is not valid JSON: $Path ($($_.Exception.Message))"
    }
    if ([int] $saved.SchemaVersion -ne 2) {
        throw "Unsupported sync plan schema: $($saved.SchemaVersion)"
    }
    $savedPlansHash = Get-SavedPlansHash -Plans @($saved.Plans)
    if ([string] $saved.PlanHash -ne $savedPlansHash) {
        throw "Sync plan self-check failed. Saved contents do not match PlanHash=$($saved.PlanHash). Rerun dry-run and review a fresh plan."
    }
    if ([string] $saved.PlanHash -ne $CurrentPlanHash) {
        throw "Sync plan drift detected. Saved=$($saved.PlanHash) Current=$CurrentPlanHash. Rerun dry-run and review the new plan."
    }
    Write-Host "Plan binding    : verified ($CurrentPlanHash)"
}

function Get-SyncPlan {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $LiveRoot,
        # AllowEmptyCollection: an env staging tree may legitimately manage zero
        # skills for a platform (empty manifest -> plan no actions for it).
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $ManagedNames,
        [Parameter(Mandatory)] [string] $ManifestHash,
        [Parameter(Mandatory)] [string] $CanonicalAuthorityRoot,
        [Parameter(Mandatory)] [string] $CanonicalRetirementEvidenceHash,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $RetiredNames,
        [AllowNull()] [string] $RetirementManifestPath,
        [AllowNull()] [string] $RetirementManifestHash
    )

    $sourceRootExists = Test-Path -LiteralPath $SourceRoot -PathType Container
    $liveRootExists = Test-Path -LiteralPath $LiveRoot -PathType Container
    $sourceNames = @(Get-DirNames -Path $SourceRoot)
    $liveNamesAll = @(Get-DirNames -Path $LiveRoot)

    $systemPreserved = $false
    $liveNames = foreach ($n in $liveNamesAll) {
        if ($Platform -eq 'codex' -and $n -eq $CodexSystemDirName) { $systemPreserved = $true; continue }
        $n
    }
    $liveNames = @($liveNames)

    $sourceHashes = @{}
    foreach ($name in $sourceNames) {
        $sourceHashes[$name] = Get-SkillTreeHash -Path (Join-Path $SourceRoot $name)
    }

    $liveHashes = @{}
    foreach ($name in @($sourceNames | Where-Object { $_ -in $liveNames })) {
        $liveHashes[$name] = Get-SkillTreeHash -Path (Join-Path $LiveRoot $name)
    }

    $toAdd = @($sourceNames | Where-Object { $_ -notin $liveNames } | Sort-Object)
    $toUpdate = @($sourceNames | Where-Object {
        $_ -in $liveNames -and $sourceHashes[$_] -ne $liveHashes[$_]
    } | Sort-Object)
    $toNoOp = @($sourceNames | Where-Object {
        $_ -in $liveNames -and $sourceHashes[$_] -eq $liveHashes[$_]
    } | Sort-Object)
    # Prune: in live, NOT in source, and authorized either by the current managed
    # manifest or by the explicit one-shot retirement manifest.
    $toPrune = @($liveNames | Where-Object {
        $_ -notin $sourceNames -and ($ManagedNames.Contains($_) -or $RetiredNames.Contains($_))
    } | Sort-Object)
    # Unknown: in live, NOT in source, and covered by neither authority -> report
    # only, never delete.
    $unknown = @($liveNames | Where-Object {
        $_ -notin $sourceNames -and -not $ManagedNames.Contains($_) -and -not $RetiredNames.Contains($_)
    } | Sort-Object)

    return [pscustomobject] @{
        Platform = $Platform
        SourceRoot = $SourceRoot
        LiveRoot = $LiveRoot
        SourceRootExists = $sourceRootExists
        LiveRootExists = $liveRootExists
        ManifestHash = $ManifestHash
        ManagedNames = @($ManagedNames | Sort-Object)
        CanonicalAuthorityRoot = [System.IO.Path]::GetFullPath($CanonicalAuthorityRoot)
        CanonicalRetirementEvidenceHash = $CanonicalRetirementEvidenceHash
        RetirementManifestPath = $RetirementManifestPath
        RetirementManifestHash = $RetirementManifestHash
        RetiredNames = @($RetiredNames | Sort-Object)
        SourceCount = $sourceNames.Count
        Add = $toAdd
        AddEntries = @($toAdd | ForEach-Object {
            [pscustomobject]@{ Name = $_; SourceHash = $sourceHashes[$_]; LiveHash = $null }
        })
        Update = $toUpdate
        NoOp = $toNoOp
        UpdateEntries = @($toUpdate | ForEach-Object {
            [pscustomobject]@{ Name = $_; SourceHash = $sourceHashes[$_]; LiveHash = $liveHashes[$_] }
        })
        NoOpEntries = @($toNoOp | ForEach-Object {
            [pscustomobject]@{ Name = $_; SourceHash = $sourceHashes[$_]; LiveHash = $liveHashes[$_] }
        })
        Prune = $toPrune
        PruneEntries = @($toPrune | ForEach-Object {
            $isManaged = $ManagedNames.Contains($_)
            [pscustomobject]@{
                Name = $_
                SourceHash = $null
                LiveHash = Get-SkillTreeHash -Path (Join-Path $LiveRoot $_)
                Managed = $isManaged
                Authority = if ($isManaged) { 'managed-manifest' } else { 'explicit-retirement' }
            }
        })
        Unknown = $unknown
        UnknownEntries = @($unknown | ForEach-Object {
            [pscustomobject]@{ Name = $_; LiveHash = Get-SkillTreeHash -Path (Join-Path $LiveRoot $_); Managed = $false }
        })
        SystemPreserved = $systemPreserved
    }
}

function Write-PlanReport {
    param([Parameter(Mandatory)] [object] $Plan)

    Write-Host ""
    Write-Host "[$($Plan.Platform)]"
    Write-Host "  source : $($Plan.SourceRoot) ($($Plan.SourceCount) skills)"
    Write-Host "  live   : $($Plan.LiveRoot)"
    Write-Host "  would add    ($($Plan.Add.Count))    : $([string]::Join(', ', $Plan.Add))"
    Write-Host "  would update ($($Plan.Update.Count)) : $([string]::Join(', ', $Plan.Update))"
    Write-Host "  no-op        ($($Plan.NoOp.Count)) : $([string]::Join(', ', $Plan.NoOp))"
    Write-Host "  would prune  ($($Plan.Prune.Count))  : $([string]::Join(', ', $Plan.Prune))"
    $retiredPrune = @($Plan.PruneEntries | Where-Object Authority -eq 'explicit-retirement' | ForEach-Object Name)
    if ($retiredPrune.Count -gt 0) {
        Write-Host "  retirement-authorized ($($retiredPrune.Count)): $([string]::Join(', ', $retiredPrune))"
    }
    Write-Host "  unknown dirs ($($Plan.Unknown.Count)) (ignored, never deleted): $([string]::Join(', ', $Plan.Unknown))"
    if ($Plan.Platform -eq 'codex') {
        Write-Host "  .system: $(if ($Plan.SystemPreserved) { 'present -> PRESERVED (untouched)' } else { 'not present' })"
    }
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

function Write-SyncJournal {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $PlanHash,
        [Parameter(Mandatory)] [string] $Status,
        [AllowNull()] [string] $BackupDir,
        [AllowNull()] [object[]] $Completed = @(),
        [AllowNull()] [string] $Failure
    )

    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $document = [ordered]@{
        SchemaVersion = 1
        RunId = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        PlanHash = $PlanHash
        Status = $Status
        BackupDir = $BackupDir
        Completed = @($Completed | ForEach-Object {
            [ordered]@{
                Platform = $_.Platform
                Name = $_.Name
                Action = $_.Action
                Authority = if ($_.PSObject.Properties.Name -contains 'Authority') { $_.Authority } else { $null }
            }
        })
        Failure = if ($Failure) { $Failure } else { $null }
    }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 20) + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Restore-CompletedManagedSkills {
    param(
        [Parameter(Mandatory)] [object[]] $Completed,
        [Parameter(Mandatory)] [string] $BackupDir,
        [Parameter(Mandatory)] [object[]] $Plans
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    for ($i = $Completed.Count - 1; $i -ge 0; $i--) {
        $entry = $Completed[$i]
        $plan = @($Plans | Where-Object Platform -eq $entry.Platform | Select-Object -First 1)
        if ($plan.Count -eq 0) { $errors.Add("Missing plan for $($entry.Platform)/$($entry.Name)"); continue }

        $backupRootName = switch ($entry.Platform) {
            'claude' { 'claude-skills' }
            'codex' { 'codex-skills' }
            'reasonix' { 'reasonix-skills' }
            default { $null }
        }
        if (-not $backupRootName) { $errors.Add("Unknown platform $($entry.Platform)"); continue }

        $backupSkill = Join-Path (Join-Path $BackupDir $backupRootName) $entry.Name
        try {
            if (Test-Path -LiteralPath $backupSkill -PathType Container) {
                Sync-OneSkillDir-Transactional -SourceSkillDir $backupSkill -LiveRoot $plan[0].LiveRoot -Name $entry.Name
            }
            else {
                Remove-OneSkillDir -LiveRoot $plan[0].LiveRoot -Name $entry.Name
            }
        }
        catch {
            $errors.Add("$($entry.Platform)/$($entry.Name): $($_.Exception.Message)")
        }
    }

    if ($errors.Count -gt 0) {
        throw "Managed-skill rollback failed: $($errors -join '; ')"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$buildRunResult = 'Not run'
$secretsScanRunResult = 'Not run'
$syncPlans = @()

if ($Apply -and $DryRun) {
    Write-Host 'ERROR: -Apply and -DryRun cannot be used together.'
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Choose exactly one mode: -DryRun or -Apply.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 1
}

if ($Apply -and [string]::IsNullOrWhiteSpace($PlanPath)) {
    Write-Host 'ERROR: -Apply requires a reviewed -PlanPath generated by a prior -DryRun.'
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Run sync with -DryRun -PlanPath <external-plan.json>, review it, then rerun -Apply with the same -PlanPath.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 1
}

$claudeSource = Join-Path $RepoRoot 'claude\skills'
$codexSource = Join-Path $RepoRoot 'codex\skills'
$reasonixSource = Join-Path $RepoRoot 'reasonix\skills'
$claudeLive = Get-ClaudeLiveSkillsPath
$codexLive = Get-CodexLiveSkillsPath
$reasonixLive = Get-ReasonixLiveSkillsPath

Write-Host '=== sync.ps1 ==='
Write-Host "Mode            : $(if ($Apply) { 'APPLY' } else { 'DRY-RUN (no changes)' })"
Write-Host "Repo            : $RepoRoot"
Write-Host "Claude source   : $claudeSource"
Write-Host "Codex source    : $codexSource"
Write-Host "Reasonix source  : $reasonixSource"
Write-Host "Claude live     : $claudeLive"
Write-Host "Codex live      : $codexLive"
Write-Host "Reasonix live    : $reasonixLive"

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

if (-not (Test-Path -LiteralPath $claudeSource) -or -not (Test-Path -LiteralPath $codexSource) -or -not (Test-Path -LiteralPath $reasonixSource)) {
    Write-Host 'ERROR: generated output missing. Run build-skills.ps1 (do not pass -SkipBuild).'
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Restore generated output by running build-skills.ps1, then rerun sync in dry-run mode.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 1
}

# --- managed-skills manifests (per-platform) ---
$claudeManagedNames = Read-ManagedNames -Path (Join-Path $RepoRoot 'manifests\managed-skills.claude.txt')
$codexManagedNames = Read-ManagedNames -Path (Join-Path $RepoRoot 'manifests\managed-skills.codex.txt')
$reasonixManagedNames = Read-ManagedNames -Path (Join-Path $RepoRoot 'manifests\managed-skills.reasonix.txt')
$claudeManifestHash = Get-PathSha256 -Path (Join-Path $RepoRoot 'manifests\managed-skills.claude.txt')
$codexManifestHash = Get-PathSha256 -Path (Join-Path $RepoRoot 'manifests\managed-skills.codex.txt')
$reasonixManifestHash = Get-PathSha256 -Path (Join-Path $RepoRoot 'manifests\managed-skills.reasonix.txt')
Write-Host "Managed skills  : Claude=$($claudeManagedNames.Count)  Codex=$($codexManagedNames.Count)  Reasonix=$($reasonixManagedNames.Count)"

# --- optional explicit one-shot retirement authority ---
$canonicalAuthorityRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$retirement = Read-ExplicitRetirementManifest -Path $RetireManifestPath
if ($retirement.Path) {
    Assert-RetirementManifestIsExternal -ManifestPath $retirement.Path -ProtectedRoots @($canonicalAuthorityRoot, $RepoRoot, $claudeLive, $codexLive, $reasonixLive)
    if ($PlanPath) {
        $planPathFull = [System.IO.Path]::GetFullPath($PlanPath)
        if ($planPathFull -eq $retirement.Path) {
            throw 'Retirement manifest path and sync plan path must be different files.'
        }
    }
    $repoSharedCanonical = Join-Path $RepoRoot 'skills-source\shared'
    $authoritySharedCanonical = Join-Path $canonicalAuthorityRoot 'skills-source\shared'
    $claudeCanonicalEvidenceHash = Assert-RetirementNamesAreStale -Platform 'Claude' -SourceRoot $claudeSource -LiveRoot $claudeLive -CanonicalRoots @($repoSharedCanonical, (Join-Path $RepoRoot 'skills-source\claude-only'), $authoritySharedCanonical, (Join-Path $canonicalAuthorityRoot 'skills-source\claude-only')) -ManagedNames $claudeManagedNames -RetiredNames $retirement.Claude
    $codexCanonicalEvidenceHash = Assert-RetirementNamesAreStale -Platform 'Codex' -SourceRoot $codexSource -LiveRoot $codexLive -CanonicalRoots @($repoSharedCanonical, (Join-Path $RepoRoot 'skills-source\codex-only'), $authoritySharedCanonical, (Join-Path $canonicalAuthorityRoot 'skills-source\codex-only')) -ManagedNames $codexManagedNames -RetiredNames $retirement.Codex
    $reasonixCanonicalEvidenceHash = Assert-RetirementNamesAreStale -Platform 'Reasonix' -SourceRoot $reasonixSource -LiveRoot $reasonixLive -CanonicalRoots @($repoSharedCanonical, (Join-Path $RepoRoot 'skills-source\reasonix-only'), $authoritySharedCanonical, (Join-Path $canonicalAuthorityRoot 'skills-source\reasonix-only')) -ManagedNames $reasonixManagedNames -RetiredNames $retirement.Reasonix
    Write-Host "Retire manifest : $($retirement.Path)"
    Write-Host "Retire hash     : $($retirement.Hash)"
    Write-Host "Retired names   : Claude=$($retirement.Claude.Count)  Codex=$($retirement.Codex.Count)  Reasonix=$($retirement.Reasonix.Count)"
}
else {
    $claudeCanonicalEvidenceHash = Get-StringSha256 -Text "Claude|no-explicit-retirement`n"
    $codexCanonicalEvidenceHash = Get-StringSha256 -Text "Codex|no-explicit-retirement`n"
    $reasonixCanonicalEvidenceHash = Get-StringSha256 -Text "Reasonix|no-explicit-retirement`n"
    Write-Host 'Retire manifest : none (unknown live skills remain preserved)'
}

# --- plans ---
$claudePlan = Get-SyncPlan -Platform 'claude' -SourceRoot $claudeSource -LiveRoot $claudeLive -ManagedNames $claudeManagedNames -ManifestHash $claudeManifestHash -CanonicalAuthorityRoot $canonicalAuthorityRoot -CanonicalRetirementEvidenceHash $claudeCanonicalEvidenceHash -RetiredNames $retirement.Claude -RetirementManifestPath $retirement.Path -RetirementManifestHash $retirement.Hash
$codexPlan = Get-SyncPlan -Platform 'codex' -SourceRoot $codexSource -LiveRoot $codexLive -ManagedNames $codexManagedNames -ManifestHash $codexManifestHash -CanonicalAuthorityRoot $canonicalAuthorityRoot -CanonicalRetirementEvidenceHash $codexCanonicalEvidenceHash -RetiredNames $retirement.Codex -RetirementManifestPath $retirement.Path -RetirementManifestHash $retirement.Hash
$reasonixPlan = Get-SyncPlan -Platform 'reasonix' -SourceRoot $reasonixSource -LiveRoot $reasonixLive -ManagedNames $reasonixManagedNames -ManifestHash $reasonixManifestHash -CanonicalAuthorityRoot $canonicalAuthorityRoot -CanonicalRetirementEvidenceHash $reasonixCanonicalEvidenceHash -RetiredNames $retirement.Reasonix -RetirementManifestPath $retirement.Path -RetirementManifestHash $retirement.Hash
$syncPlans = @($claudePlan, $codexPlan, $reasonixPlan)
foreach ($plan in $syncPlans) {
    $explicitPruneNames = New-CaseInsensitiveNameSet
    foreach ($entry in @($plan.PruneEntries | Where-Object Authority -eq 'explicit-retirement')) {
        [void] $explicitPruneNames.Add($entry.Name)
    }
    if ($explicitPruneNames.Count -ne $plan.RetiredNames.Count) {
        throw "Retirement target set changed while planning $($plan.Platform); rerun dry-run."
    }
    foreach ($retiredName in $plan.RetiredNames) {
        if (-not $explicitPruneNames.Contains($retiredName)) {
            throw "Retirement target '$($plan.Platform)/$retiredName' was not planned exactly; rerun dry-run."
        }
    }
}
$planHash = Get-PlansHash -Plans $syncPlans

Write-Host ''
Write-Host '----- PLAN -----'
Write-Host "Backup before apply: $(if ($Apply) { "YES (mandatory) under $BackupRoot" } else { 'n/a (dry-run)' })"
Write-PlanReport -Plan $claudePlan
Write-PlanReport -Plan $codexPlan
Write-PlanReport -Plan $reasonixPlan
Write-Host "Plan hash       : $planHash"

if (-not $Apply -and $PlanPath) {
    Write-SyncPlanFile -Path $PlanPath -Plans $syncPlans -PlanHash $planHash
}
elseif ($Apply -and $PlanPath) {
    Assert-SyncPlanFileMatches -Path $PlanPath -CurrentPlanHash $planHash
}

$totalChanges = $claudePlan.Add.Count + $claudePlan.Update.Count + $claudePlan.Prune.Count +
                $codexPlan.Add.Count + $codexPlan.Update.Count + $codexPlan.Prune.Count +
                $reasonixPlan.Add.Count + $reasonixPlan.Update.Count + $reasonixPlan.Prune.Count

Write-Host ''
Write-Host '----- SUMMARY -----'
Write-Host "Claude   : +$($claudePlan.Add.Count) ~$($claudePlan.Update.Count) =$($claudePlan.NoOp.Count) -$($claudePlan.Prune.Count)  (unknown ignored: $($claudePlan.Unknown.Count))"
Write-Host "Codex    : +$($codexPlan.Add.Count) ~$($codexPlan.Update.Count) =$($codexPlan.NoOp.Count) -$($codexPlan.Prune.Count)  (unknown ignored: $($codexPlan.Unknown.Count); .system preserved: $($codexPlan.SystemPreserved))"
Write-Host "Reasonix  : +$($reasonixPlan.Add.Count) ~$($reasonixPlan.Update.Count) =$($reasonixPlan.NoOp.Count) -$($reasonixPlan.Prune.Count)  (unknown ignored: $($reasonixPlan.Unknown.Count))"

if (-not $Apply) {
    Write-Host ''
    Write-Host 'DRY-RUN complete. No live files were changed. Re-run with -Apply to execute.'
    $dryRunWarnings = $claudePlan.Prune.Count + $codexPlan.Prune.Count + $reasonixPlan.Prune.Count +
                      $claudePlan.Unknown.Count + $codexPlan.Unknown.Count + $reasonixPlan.Unknown.Count
    $dryRunResult = if ($dryRunWarnings -gt 0) { 'WARN' } else { 'PASS' }
    $dryRunNext = if ($dryRunWarnings -gt 0) {
        'Review every planned removal and unknown live skill; rerun dry-run after resolving unexpected items.'
    }
    else {
        'Review the report; use -Apply only when the plan is expected and a backup will be created.'
    }
    Write-SyncRunReport -Result $dryRunResult -NextAction $dryRunNext -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 0
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '----- APPLY -----'

# 1) Mandatory backup first.
Write-Host 'Creating mandatory pre-change backup ...'
$backupArguments = @('-BackupRoot', $BackupRoot, '-RepoRoot', $RepoRoot, '-HomeRoot', $HomeRoot)
if ($ReasonixLiveSkillsPath) {
    $backupArguments += @('-ReasonixLiveSkillsPath', $reasonixLive)
}
$backupOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'backup.ps1') @backupArguments 2>&1
$backupCode = $LASTEXITCODE
$backupOut | ForEach-Object { Write-Host "  [backup] $_" }
if ($backupCode -ne 0) {
    Write-Host "ERROR: backup failed (exit $backupCode). Aborting before any change."
    $zeroApplied = [ordered] @{ ClaudeAdded = 0; ClaudeUpdated = 0; ClaudePruned = 0; CodexAdded = 0; CodexUpdated = 0; CodexPruned = 0; ReasonixAdded = 0; ReasonixUpdated = 0; ReasonixPruned = 0 }
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Resolve the backup failure before any sync Apply.' -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult -AppliedCounts $zeroApplied
    exit 1
}
$backupLine = $backupOut | Where-Object { $_ -is [string] -and $_ -match '^BACKUP_DIR=' } | Select-Object -Last 1
$backupDir = if ($backupLine) { ($backupLine -replace '^BACKUP_DIR=', '').Trim() } else { '<unknown>' }
Write-Host "Backup path     : $backupDir"
$journalPath = if ($backupDir -and $backupDir -ne '<unknown>') { Join-Path $backupDir 'sync-journal.json' } else { $null }
$completedOperations = [System.Collections.Generic.List[object]]::new()
if ($journalPath) {
    Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'backup-complete' -BackupDir $backupDir
    Write-Host "Journal path    : $journalPath"
}

# 2) Apply per-platform, one skill dir at a time.
$applied = [ordered] @{ ClaudeAdded = 0; ClaudeUpdated = 0; ClaudePruned = 0; CodexAdded = 0; CodexUpdated = 0; CodexPruned = 0; ReasonixAdded = 0; ReasonixUpdated = 0; ReasonixPruned = 0 }

try {
    foreach ($plan in @($claudePlan, $codexPlan, $reasonixPlan)) {
        New-Item -ItemType Directory -Force -Path $plan.LiveRoot | Out-Null
        foreach ($name in $plan.Add) {
            Sync-OneSkillDir -SourceSkillDir (Join-Path $plan.SourceRoot $name) -LiveRoot $plan.LiveRoot -Name $name
            if ($plan.Platform -eq 'claude') { $applied.ClaudeAdded++ }
            elseif ($plan.Platform -eq 'reasonix') { $applied.ReasonixAdded++ }
            else { $applied.CodexAdded++ }
            $completedOperations.Add([pscustomobject]@{ Platform = $plan.Platform; Name = $name; Action = 'add' })
            if ($journalPath) { Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'applying' -BackupDir $backupDir -Completed @($completedOperations) }
        }
        foreach ($name in $plan.Update) {
            Sync-OneSkillDir -SourceSkillDir (Join-Path $plan.SourceRoot $name) -LiveRoot $plan.LiveRoot -Name $name
            if ($plan.Platform -eq 'claude') { $applied.ClaudeUpdated++ }
            elseif ($plan.Platform -eq 'reasonix') { $applied.ReasonixUpdated++ }
            else { $applied.CodexUpdated++ }
            $completedOperations.Add([pscustomobject]@{ Platform = $plan.Platform; Name = $name; Action = 'update' })
            if ($journalPath) { Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'applying' -BackupDir $backupDir -Completed @($completedOperations) }
        }
        foreach ($entry in $plan.PruneEntries) {
            $name = $entry.Name
            Remove-OneSkillDir -LiveRoot $plan.LiveRoot -Name $name -ExpectedHash $entry.LiveHash
            if ($plan.Platform -eq 'claude') { $applied.ClaudePruned++ }
            elseif ($plan.Platform -eq 'reasonix') { $applied.ReasonixPruned++ }
            else { $applied.CodexPruned++ }
            $completedOperations.Add([pscustomobject]@{ Platform = $plan.Platform; Name = $name; Action = 'prune'; Authority = $entry.Authority })
            if ($journalPath) { Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'applying' -BackupDir $backupDir -Completed @($completedOperations) }
        }
    }
}
catch {
    $failure = $_.Exception.Message
    if ($journalPath) {
        Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'failed-before-rollback' -BackupDir $backupDir -Completed @($completedOperations) -Failure $failure
    }
    try {
        if ($completedOperations.Count -gt 0) {
            Restore-CompletedManagedSkills -Completed @($completedOperations) -BackupDir $backupDir -Plans $syncPlans
        }
        if ($journalPath) {
            Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'rolled-back' -BackupDir $backupDir -Completed @($completedOperations) -Failure $failure
        }
        Write-Host "ERROR: apply failed and managed-skill changes were rolled back. Backup: $backupDir"
    }
    catch {
        $rollbackFailure = $_.Exception.Message
        if ($journalPath) {
            Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'rollback-failed' -BackupDir $backupDir -Completed @($completedOperations) -Failure "$failure Rollback: $rollbackFailure"
        }
        Write-Host "ERROR: apply failed and rollback failed. Backup: $backupDir"
        Write-Host "Rollback error: $rollbackFailure"
    }
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Inspect the sync journal and backup before retrying.' -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult -AppliedCounts $applied
    exit 1
}

if ($journalPath) {
    Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'skills-applied' -BackupDir $backupDir -Completed @($completedOperations)
}

Write-Host ''
Write-Host "Claude   applied: +$($applied.ClaudeAdded) ~$($applied.ClaudeUpdated) -$($applied.ClaudePruned)"
Write-Host "Codex    applied: +$($applied.CodexAdded) ~$($applied.CodexUpdated) -$($applied.CodexPruned)"
Write-Host "Reasonix  applied: +$($applied.ReasonixAdded) ~$($applied.ReasonixUpdated) -$($applied.ReasonixPruned)"

# 3) Verification.
$codexMarker = Join-Path $codexLive '.system\.codex-system-skills.marker'
$systemOk = Test-Path -LiteralPath $codexMarker
Write-Host ".system marker preserved: $systemOk"

function Test-Parity {
    param([string] $SourceRoot, [string] $LiveRoot, [bool] $ExcludeSystem, [System.Collections.Generic.HashSet[string]] $ManagedNames)
    $src = @(Get-DirNames -Path $SourceRoot | Sort-Object)
    $live = @(Get-DirNames -Path $LiveRoot | Where-Object { -not ($ExcludeSystem -and $_ -eq $CodexSystemDirName) } | Sort-Object)
    # Filter whenever a managed set is provided — including an EMPTY set, where
    # the managed portion of live is trivially in sync (unknown dirs are
    # ignored-never-deleted and must not fail parity).
    if ($null -ne $ManagedNames) {
        $live = @($live | Where-Object { $ManagedNames.Contains($_) })
    }
    return (-not (Compare-Object $src $live))
}

# Parity is scoped to each platform's managed set: unknown
# live dirs are ignored-never-deleted by contract, so they must not fail the
# post-apply check either.
$claudeParity = Test-Parity -SourceRoot $claudeSource -LiveRoot $claudeLive -ExcludeSystem $false -ManagedNames $claudeManagedNames
$codexParity = Test-Parity -SourceRoot $codexSource -LiveRoot $codexLive -ExcludeSystem $true -ManagedNames $codexManagedNames
$reasonixParity = Test-Parity -SourceRoot $reasonixSource -LiveRoot $reasonixLive -ExcludeSystem $false -ManagedNames $reasonixManagedNames
Write-Host "Claude   live-vs-repo: $(if ($claudeParity) { 'OK' } else { 'MISMATCH' })"
Write-Host "Codex    live-vs-repo: $(if ($codexParity) { 'OK (excl .system)' } else { 'MISMATCH' })"
Write-Host "Reasonix  live-vs-repo: $(if ($reasonixParity) { 'OK (managed only)' } else { 'MISMATCH' })"

if (-not $systemOk -and (Get-DirNames -Path $codexLive) -contains $CodexSystemDirName) {
    Write-Host 'WARNING: .system dir present but marker missing — investigate.'
}
$systemReportStatus = if ((Get-DirNames -Path $codexLive) -contains $CodexSystemDirName) {
    if ($systemOk) { 'PRESERVED (marker present)' } else { 'PRESERVED-REQUIRED (marker missing)' }
}
else {
    'Not present'
}
if (-not $claudeParity -or -not $codexParity -or -not $reasonixParity) {
    Write-Host "ERROR: post-apply parity check failed. Backup is at: $backupDir"
    if ($journalPath) {
        Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'parity-failed' -BackupDir $backupDir -Completed @($completedOperations) -Failure 'Post-apply parity check failed.'
    }
    $parityRollbackFailed = $false
    try {
        if ($completedOperations.Count -gt 0) {
            Restore-CompletedManagedSkills -Completed @($completedOperations) -BackupDir $backupDir -Plans $syncPlans
        }
        if ($journalPath) {
            Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'rolled-back' -BackupDir $backupDir -Completed @($completedOperations) -Failure 'Post-apply parity check failed.'
        }
        Write-Host 'Managed-skill changes were rolled back after parity failure.'
    }
    catch {
        $parityRollbackFailed = $true
        $rollbackFailure = $_.Exception.Message
        if ($journalPath) {
            Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'rollback-failed' -BackupDir $backupDir -Completed @($completedOperations) -Failure "Post-apply parity failed. Rollback: $rollbackFailure"
        }
        Write-Host "ERROR: parity rollback failed: $rollbackFailure"
    }
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Inspect parity mismatches and recover from the existing backup if necessary.' -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult -AppliedCounts $applied -SystemStatus $systemReportStatus
    exit 1
}

if ($journalPath) {
    Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'skills-verified' -BackupDir $backupDir -Completed @($completedOperations)
}

Write-Host ''
Write-Host "APPLY complete. Backup: $backupDir"
if ($journalPath) {
    Write-SyncJournal -Path $journalPath -PlanHash $planHash -Status 'complete' -BackupDir $backupDir -Completed @($completedOperations)
}
$applyUnknown = $claudePlan.Unknown.Count + $codexPlan.Unknown.Count + $reasonixPlan.Unknown.Count
$applyReportResult = if ($applyUnknown -gt 0 -or $systemReportStatus -like '*marker missing*') { 'WARN' } else { 'PASS' }
$applyNextAction = if ($applyReportResult -eq 'WARN') {
    'Review preserved unknown skills and .system status, then run the secret scan and git status.'
}
else {
    'Run scripts/scan-secrets.ps1 and git status, then record the verified machine state.'
}
Write-SyncRunReport -Result $applyReportResult -NextAction $applyNextAction -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult -AppliedCounts $applied -SystemStatus $systemReportStatus
exit 0
