#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = $PSScriptRoot,
    [switch] $InstallPreCommit,
    [switch] $SkipInitialPlan,
    [switch] $SkipInitialSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'This script requires PowerShell 7 or newer. Run it with pwsh.' }
if ($SkipInitialSync) { Write-Warning '-SkipInitialSync is deprecated; use -SkipInitialPlan.'; $SkipInitialPlan = $true }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$script = Join-Path $RepoRoot 'scripts/bootstrap-clone.ps1'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Missing bootstrap script: $script" }
$arguments = @('-RepoRoot',$RepoRoot)
if ($InstallPreCommit) { $arguments += '-InstallPreCommit' }
if ($SkipInitialPlan) { $arguments += '-SkipInitialPlan' }
& pwsh -NoProfile -ExecutionPolicy Bypass -File $script @arguments
exit $LASTEXITCODE
