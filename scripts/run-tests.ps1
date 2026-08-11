#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [switch] $All,
    [Parameter(Mandatory)] [string] $JsonSummaryPath,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $All) { throw 'Specify -All. Suite inclusion lists are not supported.' }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'test-runner-common.ps1')
$testsRoot = Join-Path $RepoRoot 'tests'
$timeouts = Join-Path $testsRoot 'test-timeouts.psd1'
$suites = Get-RootTestSuitePaths -TestsRoot $testsRoot
$summary = Invoke-TestSuiteCollection -SuitePaths $suites -SuiteRoot $testsRoot -TimeoutConfigPath $timeouts -JsonSummaryPath $JsonSummaryPath
Write-Host ("Test summary: {0}; discovered={1}; passed={2}; failed={3}; timed-out={4}" -f $summary.Result, $summary.Counts.Discovered, $summary.Counts.Passed, $summary.Counts.Failed, $summary.Counts.TimedOut)
if ($summary.Result -ne 'PASS') { exit 1 }
