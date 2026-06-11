#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
Write-Host "backup.ps1 placeholder loaded for RepoRoot: $RepoRoot"
Write-Host "DryRun: $DryRun; HomeRoot: $HomeRoot"
throw 'Real backup is intentionally disabled in phase 1/2. No HOME files were read or copied.'
