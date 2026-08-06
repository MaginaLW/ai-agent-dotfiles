#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [string] $InputSkillPath,
    [Parameter(Mandatory)] [ValidateSet('shared', 'claude-only', 'codex-only', 'reasonix-only')] [string] $TargetType,
    [switch] $Apply,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'skills-common.ps1')

$RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
$InputSkillPath = (Resolve-Path -LiteralPath $InputSkillPath).Path
$name = Get-SkillName -SkillPath $InputSkillPath
$target = Join-RepoPath -RepoRoot $RepoRoot -RelativePath "skills-source/$TargetType/$name"
if ($DryRun -or -not $Apply) {
    Write-Host "DRY-RUN: would promote $InputSkillPath -> $target"
    return
}

$existing = @()
foreach ($type in @('shared', 'claude-only', 'codex-only', 'reasonix-only')) {
    $existingPath = Join-RepoPath -RepoRoot $RepoRoot -RelativePath "skills-source/$type/$name"
    if (Test-Path -LiteralPath (Join-Path $existingPath 'SKILL.md')) {
        $existing += $existingPath
    }
}
if ($existing.Count -gt 0) {
    [pscustomobject] [ordered] @{
        Status = 'canonical-retained'
        Reason = 'existing-canonical'
        Name = $name
        ExistingCanonical = @($existing | ForEach-Object { Get-PortableSkillPath -RepoRoot $RepoRoot -Path $_ })
    } | ConvertTo-Json -Depth 10
    exit 3
}

$result = Normalize-SkillDirectory -RepoRoot $RepoRoot -InputSkillPath $InputSkillPath -OutputSkillPath $target -TargetType $TargetType
$result | ConvertTo-Json -Depth 10
if ($result.Status -eq 'quarantine') {
    exit 2
}
