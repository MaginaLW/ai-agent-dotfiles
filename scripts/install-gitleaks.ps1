#requires -Version 7.0
[CmdletBinding()]
param([string] $CacheRoot, [switch] $VerifyOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pinned-tool.ps1')
$result = Install-PinnedTool -LockPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/gitleaks/gitleaks.lock.json') -CacheRoot $CacheRoot -VerifyOnly:$VerifyOnly
Write-Host "Pinned gitleaks ready: $($result.Executable) [$($result.VersionOutput)]"
