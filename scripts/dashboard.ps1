#requires -Version 7.0
<#
.SYNOPSIS
    Launches or reuses the local Chinese web monitoring console.

.DESCRIPTION
    Verifies that Python and the dashboard server/UI assets exist, then starts
    or reuses dashboard/server.py bound to loopback 127.0.0.1.

.PARAMETER RepoRoot
    Repository root directory. Defaults to the parent of scripts/.

.PARAMETER Port
    Optional TCP port to listen on (0 selects an ephemeral free port).

.PARAMETER NoBrowser
    Do not open the system browser automatically.

.PARAMETER Check
    Verify repository and UI files, emit JSON status, and exit.

.PARAMETER Offline
    Skip GitHub CLI queries and return offline responses.

.PARAMETER HomeRoot
    Optional home directory override forwarded for isolated testing.

.PARAMETER StateRoot
    Optional deployment state directory override forwarded for isolated testing.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    [ValidateRange(0, 65535)]
    [int] $Port = 0,

    [switch] $NoBrowser,
    [switch] $Check,
    [switch] $Offline,
    [string] $HomeRoot,
    [string] $StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$pythonCommands = @(Get-Command python -CommandType Application -ErrorAction SilentlyContinue)
if ($pythonCommands.Count -eq 0) {
    Write-Error 'Python executable (python) is not available on PATH.' -ErrorAction Continue
    exit 1
}
$pythonPath = $pythonCommands[0].Source

$serverScript = Join-Path $RepoRoot 'dashboard\server.py'
$indexHtml = Join-Path $RepoRoot 'dashboard\index.html'
if (-not (Test-Path -LiteralPath $serverScript -PathType Leaf)) {
    Write-Error "Dashboard server script is missing: $serverScript" -ErrorAction Continue
    exit 1
}
if (-not (Test-Path -LiteralPath $indexHtml -PathType Leaf)) {
    Write-Error "Dashboard UI page is missing: $indexHtml" -ErrorAction Continue
    exit 1
}

$pythonArgs = [System.Collections.Generic.List[string]]::new()
$pythonArgs.Add('-B')
$pythonArgs.Add($serverScript)
$pythonArgs.Add('--repo-root')
$pythonArgs.Add($RepoRoot)
$pythonArgs.Add('--reuse')

if ($Port -gt 0) {
    $pythonArgs.Add('--port')
    $pythonArgs.Add([string]$Port)
}
if ((-not $NoBrowser) -and (-not $Check)) {
    $pythonArgs.Add('--open')
}
if ($Check) {
    $pythonArgs.Add('--check')
}
if ($Offline) {
    $pythonArgs.Add('--offline')
}
if (-not [string]::IsNullOrWhiteSpace($HomeRoot)) {
    $pythonArgs.Add('--home-root')
    $pythonArgs.Add($HomeRoot)
}
if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
    $pythonArgs.Add('--state-root')
    $pythonArgs.Add($StateRoot)
}

& $pythonPath @pythonArgs
exit $LASTEXITCODE
