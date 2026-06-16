#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = $PSScriptRoot,
    [switch] $InstallPreCommit,
    [switch] $SkipInitialSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$bootstrapScript = Join-Path $RepoRoot 'scripts/bootstrap-clone.ps1'
if (-not (Test-Path -LiteralPath $bootstrapScript)) {
    throw "Missing bootstrap script: $bootstrapScript"
}

$arguments = @('-RepoRoot', $RepoRoot)
if ($InstallPreCommit) {
    $arguments += '-InstallPreCommit'
}
if ($SkipInitialSync) {
    $arguments += '-SkipInitialSync'
}

& pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrapScript @arguments
exit $LASTEXITCODE
