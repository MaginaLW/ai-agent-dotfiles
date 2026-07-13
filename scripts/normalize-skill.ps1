#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [string] $InputSkillPath,
    [Parameter(Mandatory)] [string] $OutputSkillPath,
    [Parameter(Mandatory)] [ValidateSet('shared', 'claude-only', 'codex-only', 'openclaw-only')] [string] $TargetType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'skills-common.ps1')

$RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
$InputSkillPath = (Resolve-Path -LiteralPath $InputSkillPath).Path
$result = Normalize-SkillDirectory -RepoRoot $RepoRoot -InputSkillPath $InputSkillPath -OutputSkillPath $OutputSkillPath -TargetType $TargetType
$result | ConvertTo-Json -Depth 10
if ($result.Status -eq 'quarantine') {
    exit 2
}
