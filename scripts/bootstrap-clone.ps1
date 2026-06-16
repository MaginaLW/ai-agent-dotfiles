#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch] $InstallPreCommit,
    [switch] $SkipInitialSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

function Invoke-RepoScript {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $Arguments = @()
    )

    $script = Join-Path $RepoRoot "scripts/$Name"
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Missing script: $script"
    }

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $script @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
}

Write-Host '=== bootstrap-clone.ps1 ==='
Write-Host "Repo            : $RepoRoot"
Write-Host "Install hooks   : YES (post-merge, post-checkout, post-rewrite)"
Write-Host "Initial sync    : $(if ($SkipInitialSync) { 'SKIPPED' } else { 'YES (sync.ps1 -Apply via auto-sync runner)' })"

$applyHookArgs = @('-RepoRoot', $RepoRoot, '-Force')
if ($InstallPreCommit) {
    $applyHookArgs += '-InstallPreCommit'
}
Invoke-RepoScript -Name 'apply-hooks.ps1' -Arguments $applyHookArgs
Invoke-RepoScript -Name 'check-hooks.ps1' -Arguments @('-RepoRoot', $RepoRoot)

if (-not $SkipInitialSync) {
    Invoke-RepoScript -Name 'auto-sync-after-git.ps1' -Arguments @('-RepoRoot', $RepoRoot, '-Force')
}

Write-Host 'Bootstrap complete.'
