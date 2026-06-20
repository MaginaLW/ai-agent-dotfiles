#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
$reportHelper = Join-Path $PSScriptRoot 'report-common.ps1'
if (Test-Path -LiteralPath $reportHelper) {
    . $reportHelper
}
else {
    Write-Warning "Report helper missing: $reportHelper"
}

function Write-BuildRunReport {
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'WARN', 'FAIL')] [string] $Result,
        [Parameter(Mandatory)] [string] $NextAction,
        [string[]] $Conflicts = @(),
        [string[]] $ClaudeSkills = @(),
        [string[]] $CodexSkills = @(),
        [string[]] $OpenClawSkills = @()
    )

    if (-not (Get-Command Write-RunReport -ErrorAction SilentlyContinue)) {
        return
    }

    $summary = [ordered] @{
        Added = 'Not available (build recreates output without a previous snapshot)'
        Modified = 'Not available (build recreates output without a previous snapshot)'
        Removed = 'Not available (build recreates output without a previous snapshot)'
        Skipped = 'Not available'
        Conflicts = $Conflicts.Count
        Quarantined = 'Not available'
        'Unknown live skills' = 'Not applicable'
        '.system status' = 'preserved by exclusion; build does not manage .system'
        'Secrets scan result' = 'Not run by build-skills.ps1'
    }
    $details = [ordered] @{
        'Claude generated skill set' = @($ClaudeSkills | Sort-Object)
        'Codex generated skill set' = @($CodexSkills | Sort-Object)
        'OpenClaw generated skill set' = @($OpenClawSkills | Sort-Object)
        'Conflicts' = @($Conflicts | Sort-Object)
        'Removed items' = @('Not available; generated roots are recreated and no previous snapshot is compared.')
        '.system' = @('PRESERVED: .system is not a build source or generated skill.')
    }

    try {
        $reportPath = Write-RunReport -RepoRoot $RepoRoot -ReportKind 'build' -ScriptName 'scripts/build-skills.ps1' -Mode 'build' -Summary $summary -Details $details -Result $Result -NextAction $NextAction
        Write-Host "Build report: $reportPath"
    }
    catch {
        Write-Warning "Build completed its original flow, but report creation failed: $($_.Exception.Message)"
    }
}

function Join-RepoPath {
    param(
        [Parameter(Mandatory)] [string] $RelativePath
    )

    return Join-Path $RepoRoot $RelativePath
}

function Assert-UnderRepo {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $fullRepo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $fullRepo + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to touch path outside RepoRoot: $fullPath"
    }
}

function Get-SkillDirectories {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $Path -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md')
    })
}

# Repo-internal provenance/bookkeeping files that live in skills-source/ but must NOT
# ship into the generated runtime skill bundles (claude/skills, codex/skills).
$script:RuntimeExcludePatterns = @('MERGE_NOTES.md', 'CREATION-LOG.md', '*.magina-laptop.*')

function Copy-SkillDirectory {
    param(
        [Parameter(Mandatory)] [System.IO.DirectoryInfo] $Source,
        [Parameter(Mandatory)] [string] $DestinationRoot
    )

    $destination = Join-Path $DestinationRoot $Source.Name
    Assert-UnderRepo -Path $destination
    Copy-Item -LiteralPath $Source.FullName -Destination $destination -Recurse

    # Strip bookkeeping files from the generated copy only; skills-source/ keeps them.
    foreach ($pattern in $script:RuntimeExcludePatterns) {
        Get-ChildItem -LiteralPath $destination -Recurse -Force -File -Filter $pattern |
            ForEach-Object {
                Assert-UnderRepo -Path $_.FullName
                Remove-Item -LiteralPath $_.FullName -Force
            }
    }
}

function Write-ManifestFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string[]] $Names
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $sorted = @($Names | Sort-Object -Unique)
    $content = if ($sorted.Count -gt 0) {
        ($sorted -join "`n") + "`n"
    }
    else {
        ''
    }
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}

# ── Source roots ──────────────────────────────────────────────
$sharedSource       = Join-RepoPath 'skills-source/shared'
$claudeOnlySource   = Join-RepoPath 'skills-source/claude-only'
$codexOnlySource    = Join-RepoPath 'skills-source/codex-only'
$openclawOnlySource = Join-RepoPath 'skills-source/openclaw-only'

# ── Generated target roots ────────────────────────────────────
$claudeTarget   = Join-RepoPath 'claude/skills'
$codexTarget    = Join-RepoPath 'codex/skills'
$openclawTarget = Join-RepoPath 'openclaw/skills'

# ── Read skill directories from each source ───────────────────
$sharedSkills       = Get-SkillDirectories -Path $sharedSource
$claudeOnlySkills   = Get-SkillDirectories -Path $claudeOnlySource
$codexOnlySkills    = Get-SkillDirectories -Path $codexOnlySource
$openclawOnlySkills = Get-SkillDirectories -Path $openclawOnlySource

$sharedNames       = @($sharedSkills | ForEach-Object Name)
$claudeOnlyNames   = @($claudeOnlySkills | ForEach-Object Name)
$codexOnlyNames    = @($codexOnlySkills | ForEach-Object Name)
$openclawOnlyNames = @($openclawOnlySkills | ForEach-Object Name)

# ── Conflict checks ───────────────────────────────────────────

# 1. Platform-only vs shared
$claudeConflicts   = @($claudeOnlyNames | Where-Object { $_ -in $sharedNames })
$codexConflicts    = @($codexOnlyNames  | Where-Object { $_ -in $sharedNames })
$openclawConflicts = @($openclawOnlyNames | Where-Object { $_ -in $sharedNames })

$sharedConflicts = @($claudeConflicts + $codexConflicts + $openclawConflicts | Sort-Object -Unique)
if ($sharedConflicts.Count -gt 0) {
    Write-Host 'ERROR: Skill name conflict between shared and platform-only sources.'
    $sharedConflicts | ForEach-Object { Write-Host "Conflict: $_ (in shared and platform-only)" }
    Write-BuildRunReport -Result 'FAIL' -NextAction 'Resolve shared/platform-only name conflicts, then rerun the build.' -Conflicts $sharedConflicts
    exit 1
}

# 2. Same skill in more than one platform-only source
$platformOnlyAll = @{}
foreach ($n in $claudeOnlyNames)   { if (-not $platformOnlyAll.ContainsKey($n)) { $platformOnlyAll[$n] = @() }; $platformOnlyAll[$n] += 'claude-only' }
foreach ($n in $codexOnlyNames)    { if (-not $platformOnlyAll.ContainsKey($n)) { $platformOnlyAll[$n] = @() }; $platformOnlyAll[$n] += 'codex-only' }
foreach ($n in $openclawOnlyNames) { if (-not $platformOnlyAll.ContainsKey($n)) { $platformOnlyAll[$n] = @() }; $platformOnlyAll[$n] += 'openclaw-only' }

$crossPlatformConflicts = @($platformOnlyAll.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
if ($crossPlatformConflicts.Count -gt 0) {
    Write-Host 'ERROR: Skill name appears in more than one platform-only source.'
    $crossPlatformConflicts | ForEach-Object { Write-Host "Conflict: $($_.Key) in [$($_.Value -join ', ')]" }
    $conflictNames = @($crossPlatformConflicts | ForEach-Object Key | Sort-Object)
    Write-BuildRunReport -Result 'FAIL' -NextAction 'Resolve cross-platform-only name conflicts, then rerun the build.' -Conflicts $conflictNames
    exit 1
}

# ── Compute platform-specific name sets ───────────────────────
$claudeSet   = @($sharedNames + $claudeOnlyNames   | Sort-Object -Unique)
$codexSet    = @($sharedNames + $codexOnlyNames    | Sort-Object -Unique)
$openclawSet = @($sharedNames + $openclawOnlyNames | Sort-Object -Unique)
$unionSet    = @($claudeSet + $codexSet + $openclawSet | Sort-Object -Unique)

# ── Recreate target directories ───────────────────────────────
foreach ($target in @($claudeTarget, $codexTarget, $openclawTarget)) {
    Assert-UnderRepo -Path $target
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
}

# ── Copy shared skills to all targets ─────────────────────────
foreach ($skill in $sharedSkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $claudeTarget
    Copy-SkillDirectory -Source $skill -DestinationRoot $codexTarget
    Copy-SkillDirectory -Source $skill -DestinationRoot $openclawTarget
}

# ── Copy platform-only skills ─────────────────────────────────
foreach ($skill in $claudeOnlySkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $claudeTarget
}

foreach ($skill in $codexOnlySkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $codexTarget
}

foreach ($skill in $openclawOnlySkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $openclawTarget
}

# ── Write per-platform manifests + union ──────────────────────
$manifestBase = Join-RepoPath 'manifests'

Write-ManifestFile -Path (Join-Path $manifestBase 'managed-skills.claude.txt')   -Names $claudeSet
Write-ManifestFile -Path (Join-Path $manifestBase 'managed-skills.codex.txt')    -Names $codexSet
Write-ManifestFile -Path (Join-Path $manifestBase 'managed-skills.openclaw.txt') -Names $openclawSet
Write-ManifestFile -Path (Join-Path $manifestBase 'managed-skills.txt')          -Names $unionSet

# ── Output counts ─────────────────────────────────────────────
$builtClaudeSkills   = @(Get-SkillDirectories -Path $claudeTarget)
$builtCodexSkills    = @(Get-SkillDirectories -Path $codexTarget)
$builtOpenclawSkills = @(Get-SkillDirectories -Path $openclawTarget)

Write-Host "Built Claude skills: $($builtClaudeSkills.Count)"
Write-Host "Built Codex skills: $($builtCodexSkills.Count)"
Write-Host "Built OpenClaw skills: $($builtOpenclawSkills.Count)"
Write-Host "Updated manifests:"
Write-Host "  $manifestBase\managed-skills.claude.txt"
Write-Host "  $manifestBase\managed-skills.codex.txt"
Write-Host "  $manifestBase\managed-skills.openclaw.txt"
Write-Host "  $manifestBase\managed-skills.txt"

Write-BuildRunReport -Result 'PASS' -NextAction 'Run scripts/scan-secrets.ps1, then review scripts/sync.ps1 in dry-run mode.' `
    -ClaudeSkills @($builtClaudeSkills | ForEach-Object Name) `
    -CodexSkills @($builtCodexSkills | ForEach-Object Name) `
    -OpenClawSkills @($builtOpenClawSkills | ForEach-Object Name)
