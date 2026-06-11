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

function Copy-SkillDirectory {
    param(
        [Parameter(Mandatory)] [System.IO.DirectoryInfo] $Source,
        [Parameter(Mandatory)] [string] $DestinationRoot
    )

    $destination = Join-Path $DestinationRoot $Source.Name
    Assert-UnderRepo -Path $destination
    Copy-Item -LiteralPath $Source.FullName -Destination $destination -Recurse
}

$sharedSource = Join-RepoPath 'skills-source/shared'
$claudeOnlySource = Join-RepoPath 'skills-source/claude-only'
$codexOnlySource = Join-RepoPath 'skills-source/codex-only'
$claudeTarget = Join-RepoPath 'claude/skills'
$codexTarget = Join-RepoPath 'codex/skills'
$manifestPath = Join-RepoPath 'manifests/managed-skills.txt'

$sharedSkills = Get-SkillDirectories -Path $sharedSource
$claudeOnlySkills = Get-SkillDirectories -Path $claudeOnlySource
$codexOnlySkills = Get-SkillDirectories -Path $codexOnlySource

$sharedNames = @($sharedSkills | ForEach-Object Name)
$claudeConflicts = @($claudeOnlySkills | Where-Object { $_.Name -in $sharedNames } | ForEach-Object Name)
$codexConflicts = @($codexOnlySkills | Where-Object { $_.Name -in $sharedNames } | ForEach-Object Name)
$conflicts = @($claudeConflicts + $codexConflicts | Sort-Object -Unique)

if ($conflicts.Count -gt 0) {
    Write-Host 'ERROR: Skill name conflict between shared and platform-only sources.'
    $conflicts | ForEach-Object { Write-Host "Conflict: $_" }
    exit 1
}

foreach ($target in @($claudeTarget, $codexTarget)) {
    Assert-UnderRepo -Path $target
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
}

foreach ($skill in $sharedSkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $claudeTarget
    Copy-SkillDirectory -Source $skill -DestinationRoot $codexTarget
}

foreach ($skill in $claudeOnlySkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $claudeTarget
}

foreach ($skill in $codexOnlySkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $codexTarget
}

$managedSkills = @($sharedNames + ($claudeOnlySkills | ForEach-Object Name) + ($codexOnlySkills | ForEach-Object Name) | Sort-Object -Unique)
$manifestContent = if ($managedSkills.Count -gt 0) {
    ($managedSkills -join "`n") + "`n"
}
else {
    ''
}
[System.IO.File]::WriteAllText($manifestPath, $manifestContent, [System.Text.UTF8Encoding]::new($false))

$builtClaudeSkills = @(Get-SkillDirectories -Path $claudeTarget)
$builtCodexSkills = @(Get-SkillDirectories -Path $codexTarget)
Write-Host "Built Claude skills: $($builtClaudeSkills.Count)"
Write-Host "Built Codex skills: $($builtCodexSkills.Count)"
Write-Host "Updated manifest: $manifestPath"
