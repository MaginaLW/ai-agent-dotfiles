#requires -Version 7.0
<#
.SYNOPSIS
    Deploy one skills environment and the managed home config in one run.

.DESCRIPTION
    Runs scripts/deploy-skills.ps1 and then scripts/config-pull.ps1. Without -Apply
    both stages are dry runs. With -Apply both stages perform their reviewed writes;
    the two stages are not atomic, so a config failure leaves completed skill changes
    in place and reports that boundary.

    Use deploy-skills.ps1 or config-pull.ps1 directly when only one stage is intended.
#>
[CmdletBinding()]
param(
    [string] $Environment = 'work',
    [switch] $Apply,
    [string[]] $Retire = @(),
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [string] $StateRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-agent-dotfiles.deploy'),
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [switch] $SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$pwshCommands = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
if ($pwshCommands.Count -eq 0) { throw 'PowerShell 7 executable (pwsh) is not available on PATH.' }
$pwshPath = $pwshCommands[0].Source

function Invoke-DeployStage {
    param([string] $Name, [string] $ScriptName, [string[]] $Arguments)
    Write-Host "=== $Name ===" -ForegroundColor Cyan
    & $pwshPath -NoProfile -File (Join-Path $PSScriptRoot $ScriptName) @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}

$skillArgs = @('-Environment', $Environment, '-RepoRoot', $RepoRoot, '-HomeRoot', $HomeRoot, '-StateRoot', $StateRoot)
if ($Apply) { $skillArgs += '-Apply' }
if ($Retire.Count -gt 0) { $skillArgs += '-Retire'; $skillArgs += $Retire }
if ($SkipBuild) { $skillArgs += '-SkipBuild' }
Invoke-DeployStage -Name 'skills' -ScriptName 'deploy-skills.ps1' -Arguments $skillArgs

$configArgs = @('-RepoRoot', $RepoRoot, '-HomeRoot', $HomeRoot, '-BackupRoot', $BackupRoot)
if ($Apply) { $configArgs += '-Apply' }
try {
    Invoke-DeployStage -Name 'config' -ScriptName 'config-pull.ps1' -Arguments $configArgs
}
catch {
    throw "Skills stage completed; config stage failed. $($_.Exception.Message)"
}
