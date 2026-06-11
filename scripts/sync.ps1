#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('push', 'pull')]
    [string] $Mode,

    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot,

    [Alias('dry-run')]
    [switch] $DryRun,

    [switch] $Prune
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
Write-Host "sync.ps1 placeholder loaded for RepoRoot: $RepoRoot"
Write-Host "Mode: $Mode; DryRun: $DryRun; Prune: $Prune; HomeRoot: $HomeRoot"
throw 'Real sync is intentionally disabled in phase 1/2. No files were copied to or from HOME.'
