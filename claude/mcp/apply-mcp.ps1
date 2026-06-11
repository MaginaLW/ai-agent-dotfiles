#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string] $HomeRoot,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
Write-Host "apply-mcp.ps1 placeholder loaded for RepoRoot: $RepoRoot"
Write-Host "DryRun: $DryRun; HomeRoot: $HomeRoot"
throw 'MCP application is intentionally disabled in phase 1/2. This script never overwrites ~/.claude.json.'
