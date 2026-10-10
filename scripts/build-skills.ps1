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

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$skillsHelper = Join-Path $PSScriptRoot 'skills-common.ps1'
. $skillsHelper

function Assert-DisjointBuildRoots {
    param([Parameter(Mandatory)][string[]]$Roots)
    for ($i = 0; $i -lt $Roots.Count; $i++) {
        for ($j = $i + 1; $j -lt $Roots.Count; $j++) {
            if ((Test-SameOrDescendant -Path $Roots[$i] -Root $Roots[$j]) -or (Test-SameOrDescendant -Path $Roots[$j] -Root $Roots[$i])) {
                throw "Build roots overlap: $($Roots[$i]) and $($Roots[$j])"
            }
        }
    }
}

$SourceRoot = Join-Path $RepoRoot 'skills-source'
$ClaudeOutputRoot = Join-Path $RepoRoot 'claude/skills'
$CodexOutputRoot = Join-Path $RepoRoot 'codex/skills'
$ReasonixOutputRoot = Join-Path $RepoRoot 'reasonix/skills'
$ManifestOutputRoot = Join-Path $RepoRoot 'manifests'
Assert-DisjointBuildRoots -Roots @($SourceRoot,$ClaudeOutputRoot,$CodexOutputRoot,$ReasonixOutputRoot,$ManifestOutputRoot)

$script:RuntimeExcludePatterns = @('CREATION-LOG.md')
function Copy-SkillDirectory {
    param([Parameter(Mandatory)] [System.IO.DirectoryInfo] $Source, [Parameter(Mandatory)] [string] $DestinationRoot)
    $destination = Join-Path $DestinationRoot $Source.Name
    Copy-SkillTree -SourceRoot $Source.FullName -DestinationRoot $destination
    foreach ($file in @(Get-ChildItem -LiteralPath $destination -File -Recurse -Force)) {
        $leaf = $file.Name
        if (@($script:RuntimeExcludePatterns | Where-Object { $leaf -like $_ }).Count -gt 0) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
}

function Write-ManifestFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Names)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
    $sorted = @($Names | Sort-Object -Unique)
    $content = if ($sorted.Count -gt 0) { ($sorted -join "`n") + "`n" } else { '' }
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}

# Get-SkillDirectories excludes .system: .system is not a build source or generated skill.
$sharedSource = Join-Path $SourceRoot 'shared'
$claudeOnlySource = Join-Path $SourceRoot 'claude-only'
$codexOnlySource = Join-Path $SourceRoot 'codex-only'
$reasonixOnlySource = Join-Path $SourceRoot 'reasonix-only'
$sharedSkills = Get-SkillDirectories -RootPath $sharedSource
$claudeOnlySkills = Get-SkillDirectories -RootPath $claudeOnlySource
$codexOnlySkills = Get-SkillDirectories -RootPath $codexOnlySource
$reasonixOnlySkills = Get-SkillDirectories -RootPath $reasonixOnlySource
$sharedNames = @($sharedSkills | ForEach-Object Name)
$claudeOnlyNames = @($claudeOnlySkills | ForEach-Object Name)
$codexOnlyNames = @($codexOnlySkills | ForEach-Object Name)
$reasonixOnlyNames = @($reasonixOnlySkills | ForEach-Object Name)

$sharedConflicts = @(
    @($claudeOnlyNames | Where-Object { $_ -in $sharedNames }) +
    @($codexOnlyNames | Where-Object { $_ -in $sharedNames }) +
    @($reasonixOnlyNames | Where-Object { $_ -in $sharedNames }) |
        Sort-Object -Unique
)
if ($sharedConflicts.Count -gt 0) {
    Write-Host 'ERROR: Skill name conflict between shared and platform-only sources.'
    $sharedConflicts | ForEach-Object { Write-Host "Conflict: $_ (in shared and platform-only)" }
    exit 1
}

$platformOnlyAll = @{}
foreach ($n in $claudeOnlyNames) { if (-not $platformOnlyAll.ContainsKey($n)) { $platformOnlyAll[$n]=@() }; $platformOnlyAll[$n]+='claude-only' }
foreach ($n in $codexOnlyNames) { if (-not $platformOnlyAll.ContainsKey($n)) { $platformOnlyAll[$n]=@() }; $platformOnlyAll[$n]+='codex-only' }
foreach ($n in $reasonixOnlyNames) { if (-not $platformOnlyAll.ContainsKey($n)) { $platformOnlyAll[$n]=@() }; $platformOnlyAll[$n]+='reasonix-only' }
$crossPlatformConflicts = @($platformOnlyAll.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
if ($crossPlatformConflicts.Count -gt 0) {
    Write-Host 'ERROR: Skill name appears in more than one platform-only source.'
    $crossPlatformConflicts | ForEach-Object { Write-Host "Conflict: $($_.Key) in [$($_.Value -join ', ')]" }
    exit 1
}

$claudeSet = @($sharedNames + $claudeOnlyNames | Sort-Object -Unique)
$codexSet = @($sharedNames + $codexOnlyNames | Sort-Object -Unique)
$reasonixSet = @($sharedNames + $reasonixOnlyNames | Sort-Object -Unique)

foreach ($target in @($ClaudeOutputRoot,$CodexOutputRoot,$ReasonixOutputRoot)) {
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    [System.IO.Directory]::CreateDirectory($target) | Out-Null
}
if (-not (Test-Path -LiteralPath $ManifestOutputRoot)) { [System.IO.Directory]::CreateDirectory($ManifestOutputRoot) | Out-Null }

foreach ($skill in $sharedSkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $ClaudeOutputRoot
    Copy-SkillDirectory -Source $skill -DestinationRoot $CodexOutputRoot
    Copy-SkillDirectory -Source $skill -DestinationRoot $ReasonixOutputRoot
}
foreach ($skill in $claudeOnlySkills) { Copy-SkillDirectory -Source $skill -DestinationRoot $ClaudeOutputRoot }
foreach ($skill in $codexOnlySkills) { Copy-SkillDirectory -Source $skill -DestinationRoot $CodexOutputRoot }
foreach ($skill in $reasonixOnlySkills) { Copy-SkillDirectory -Source $skill -DestinationRoot $ReasonixOutputRoot }

Write-ManifestFile -Path (Join-Path $ManifestOutputRoot 'managed-skills.claude.txt') -Names $claudeSet
Write-ManifestFile -Path (Join-Path $ManifestOutputRoot 'managed-skills.codex.txt') -Names $codexSet
Write-ManifestFile -Path (Join-Path $ManifestOutputRoot 'managed-skills.reasonix.txt') -Names $reasonixSet
$builtClaudeSkills = @(Get-SkillDirectories -RootPath $ClaudeOutputRoot)
$builtCodexSkills = @(Get-SkillDirectories -RootPath $CodexOutputRoot)
$builtReasonixSkills = @(Get-SkillDirectories -RootPath $ReasonixOutputRoot)
Write-Host "Built Claude skills: $($builtClaudeSkills.Count)"
Write-Host "Built Codex skills: $($builtCodexSkills.Count)"
Write-Host "Built Reasonix skills: $($builtReasonixSkills.Count)"
Write-Host "Updated manifests: $ManifestOutputRoot"
