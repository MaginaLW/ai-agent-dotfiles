#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$CodexOutputRoot = Join-Path $RepoRoot 'codex/skills'
$ManifestOutputRoot = Join-Path $RepoRoot 'manifests'
Assert-DisjointBuildRoots -Roots @($SourceRoot,$CodexOutputRoot,$ManifestOutputRoot)

$script:RuntimeExcludePatterns = @('CREATION-LOG.md')
function Copy-SkillDirectory {
    param(
        [Parameter(Mandatory)] [System.IO.DirectoryInfo] $Source,
        [Parameter(Mandatory)] [string] $DestinationRoot
    )
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
$codexOnlySource = Join-Path $SourceRoot 'codex-only'
$sharedSkills = Get-SkillDirectories -RootPath $sharedSource
$codexOnlySkills = Get-SkillDirectories -RootPath $codexOnlySource
$sharedNames = @($sharedSkills | ForEach-Object Name)
$codexOnlyNames = @($codexOnlySkills | ForEach-Object Name)

$sharedConflicts = @(
    @($codexOnlyNames | Where-Object { $_ -in $sharedNames }) |
        Sort-Object -Unique
)
if ($sharedConflicts.Count -gt 0) {
    [Console]::Error.WriteLine('ERROR: Skill name conflict between shared and platform-only sources.')
    $sharedConflicts | ForEach-Object { [Console]::Error.WriteLine("Conflict: $_ (in shared and platform-only)") }
    exit 1
}

$codexSet = @($sharedNames + $codexOnlyNames | Sort-Object -Unique)
if (Test-Path -LiteralPath $CodexOutputRoot) {
    Assert-SkillTreeNoReparsePoint -Root $CodexOutputRoot
    Remove-Item -LiteralPath $CodexOutputRoot -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($CodexOutputRoot) | Out-Null
if (-not (Test-Path -LiteralPath $ManifestOutputRoot)) { [System.IO.Directory]::CreateDirectory($ManifestOutputRoot) | Out-Null }

foreach ($skill in $sharedSkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $CodexOutputRoot
}
foreach ($skill in $codexOnlySkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $CodexOutputRoot
}

Write-ManifestFile -Path (Join-Path $ManifestOutputRoot 'managed-skills.codex.txt') -Names $codexSet
$builtCodexSkills = @(Get-SkillDirectories -RootPath $CodexOutputRoot)
Write-Host "Built Codex skills: $($builtCodexSkills.Count)"
Write-Host "Updated manifests: $ManifestOutputRoot"
