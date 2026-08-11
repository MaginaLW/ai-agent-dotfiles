#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot,
    [switch] $DryRun,
    [switch] $InstallPreCommit,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ($HomeRoot) {
    Write-Host "HomeRoot is accepted for compatibility but not used by Git hook installation: $HomeRoot"
}

if ($DryRun) {
    Write-Host 'DryRun requested. Hooks that would be installed: post-merge, post-checkout, post-rewrite.'
    if ($InstallPreCommit) {
        Write-Host 'DryRun requested. Optional hook that would be installed: pre-commit.'
    }
    return
}

$setupScript = Join-Path $PSScriptRoot 'setup.ps1'
$arguments = @('-RepoRoot', $RepoRoot, '-ApproveRunner', '-InstallAutoSync')
if ($InstallPreCommit) {
    $arguments += '-InstallPreCommit'
}
if ($Force) { Write-Warning '-Force is retained for compatibility; explicit -ApproveRunner is the approval boundary.' }

& pwsh -NoProfile -ExecutionPolicy Bypass -File $setupScript @arguments
exit $LASTEXITCODE
