#requires -Version 7.0
[CmdletBinding()]
param([string] $CacheRoot, [switch] $VerifyOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
$result = Install-PinnedTool -LockPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/gitleaks/gitleaks.lock.json') -CacheRoot $CacheRoot -VerifyOnly:$VerifyOnly
Write-Host "Pinned gitleaks ready: $($result.Paths.Executable) [$($result.VersionOutput)]"
