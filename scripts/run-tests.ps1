#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [switch] $All,
    [Parameter(Mandatory)] [string] $JsonSummaryPath,
    [int] $ShardCount = 0,
    [int] $ShardIndex = 0,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $All) { throw 'Specify -All. Suite inclusion lists are not supported.' }
$shardRequested = ($ShardCount -ne 0) -or ($ShardIndex -ne 0)
if ($shardRequested -and ($ShardCount -le 0 -or $ShardIndex -le 0)) {
    throw 'test-runner-shard-parameters-incomplete: specify both -ShardCount and -ShardIndex, or neither.'
}
if ($shardRequested -and $ShardIndex -gt $ShardCount) {
    throw "test-runner-shard-index-out-of-range: -ShardIndex must be between 1 and -ShardCount ($ShardCount)."
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'test-runner-common.ps1')
$testsRoot = Join-Path $RepoRoot 'tests'
$timeouts = Join-Path $testsRoot 'test-timeouts.psd1'
# @() keeps $suites an array even when exactly one suite is discovered: the shard
# selection below indexes $suites by position, and a single-element array returned
# by Get-RootTestSuitePaths would otherwise unroll to a scalar string whose [0]
# is its first character.
$suites = @(Get-RootTestSuitePaths -TestsRoot $testsRoot)
$collectionArguments = @{
    SuitePaths = $suites
    SuiteRoot = $testsRoot
    TimeoutConfigPath = $timeouts
    JsonSummaryPath = $JsonSummaryPath
}
if ($shardRequested) {
    # CI shard mode: intersect the discovered suite list with shard k of the static,
    # tracked partition in tests/test-shards.psd1. The partition helper fails closed
    # unless its union covers the discovered set exactly once, so a suite added to
    # tests/ without a partition entry cannot run silently or be dropped silently.
    $discoveredIds = @($suites | ForEach-Object { Get-TestSuiteId -SuitePath $_ -SuiteRoot $testsRoot })
    $partition = Get-TestShardPartition -ShardCount $ShardCount -ShardConfigPath (Join-Path $testsRoot 'test-shards.psd1') -DiscoveredSuiteIds $discoveredIds
    $suitePathById = @{}
    for ($index = 0; $index -lt $discoveredIds.Count; $index++) { $suitePathById[$discoveredIds[$index]] = $suites[$index] }
    $collectionArguments['SuitePaths'] = @(@($partition[[string] $ShardIndex]) | ForEach-Object { $suitePathById[$_] })
    $collectionArguments['ShardCount'] = $ShardCount
    $collectionArguments['ShardIndex'] = $ShardIndex
}
$summary = Invoke-TestSuiteCollection @collectionArguments
$summaryLine = 'Test summary: {0}; discovered={1}; passed={2}; failed={3}; timed-out={4}' -f $summary.Result, $summary.Counts.Discovered, $summary.Counts.Passed, $summary.Counts.Failed, $summary.Counts.TimedOut
if ($shardRequested) { $summaryLine += "; shard=$ShardIndex/$ShardCount" }
Write-Host $summaryLine
if ($summary.Result -ne 'PASS') { exit 1 }
