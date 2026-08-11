#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/test-runner-common.ps1')

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

$fixtureRoot = Join-Path $PSScriptRoot 'fixtures/test-runner'
$timeouts = Join-Path $fixtureRoot 'timeouts.psd1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-test-runner-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null

try {
    Write-Host '[pass and failure records]'
    $passSummaryPath = Join-Path $work 'pass.json'
    $passSummary = Invoke-TestSuiteCollection -SuitePaths @((Join-Path $fixtureRoot 'pass.tests.ps1')) -SuiteRoot $fixtureRoot -TimeoutConfigPath $timeouts -JsonSummaryPath $passSummaryPath
    Assert ($passSummary.Result -eq 'PASS') 'passing fixture produces PASS'
    Assert ($passSummary.Counts.Discovered -eq 1 -and $passSummary.Counts.Completed -eq 1 -and $passSummary.Counts.Passed -eq 1) 'passing fixture is discovered, completed, and passed exactly once'
    Assert ((Test-Path -LiteralPath $passSummaryPath -PathType Leaf)) 'summary is written create-new'

    $failureSummary = Invoke-TestSuiteCollection -SuitePaths @((Join-Path $fixtureRoot 'fail.tests.ps1')) -SuiteRoot $fixtureRoot -TimeoutConfigPath $timeouts -JsonSummaryPath (Join-Path $work 'failure.json')
    Assert ($failureSummary.Result -eq 'FAIL' -and $failureSummary.Counts.Failed -eq 1) 'non-zero fixture is recorded as one failure'
    Assert ($failureSummary.Suites[0].ExitCode -eq 7) 'non-zero exit code is retained'

    Write-Host '[duplicate and missing suites]'
    $passPath = Join-Path $fixtureRoot 'pass.tests.ps1'
    $duplicateSummary = Invoke-TestSuiteCollection -SuitePaths @($passPath, $passPath) -SuiteRoot $fixtureRoot -TimeoutConfigPath $timeouts -JsonSummaryPath (Join-Path $work 'duplicate.json')
    Assert ($duplicateSummary.Result -eq 'FAIL' -and $duplicateSummary.Counts.Duplicate -eq 1) 'duplicate SuiteId fails closed before duplicate execution'

    $missingSummary = Invoke-TestSuiteCollection -SuitePaths @((Join-Path $fixtureRoot 'missing.tests.ps1')) -SuiteRoot $fixtureRoot -TimeoutConfigPath $timeouts -JsonSummaryPath (Join-Path $work 'missing.json')
    Assert ($missingSummary.Result -eq 'FAIL' -and $missingSummary.Counts.Missing -eq 1) 'missing suite is recorded and fails closed'

    Write-Host '[timeout process tree]'
    $stateRoot = Join-Path $work 'process-tree-state'
    $timeoutSummary = Invoke-TestSuiteCollection -SuitePaths @((Join-Path $fixtureRoot 'timeout-parent.tests.ps1')) -SuiteRoot $fixtureRoot -TimeoutConfigPath $timeouts -JsonSummaryPath (Join-Path $work 'timeout.json') -Environment @{ AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT = $stateRoot }
    Assert ($timeoutSummary.Result -eq 'FAIL' -and $timeoutSummary.Counts.TimedOut -eq 1) 'timeout is recorded as failure'
    Assert ($timeoutSummary.Counts.TreeKillFailed -eq 0) 'timeout terminates the process tree'
    foreach ($name in @('parent', 'child', 'grandchild')) {
        $pidPath = Join-Path $stateRoot "$name.pid"
        Assert ((Test-Path -LiteralPath $pidPath -PathType Leaf)) "$name PID was observed"
        $processId = [int](Get-Content -Raw -LiteralPath $pidPath)
        Start-Sleep -Milliseconds 150
        Assert ($null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "$name process is no longer alive"
    }

    Write-Host '[repository discovery and CI timeout bound]'
    $repoTestsRoot = Join-Path $RepoRoot 'tests'
    $repoTimeoutPath = Join-Path $repoTestsRoot 'test-timeouts.psd1'
    $repoSuites = Get-RootTestSuitePaths -TestsRoot $repoTestsRoot
    $expectedSuites = @(Get-ChildItem -LiteralPath $repoTestsRoot -File -Filter '*.tests.ps1' | Sort-Object Name | ForEach-Object FullName)
    Assert ($repoSuites.Count -eq $expectedSuites.Count) 'root-suite discovery exactly matches the dynamic filesystem snapshot'
    Assert (@(Compare-Object $repoSuites $expectedSuites).Count -eq 0) 'root-suite discovery is stable and complete'
    $configuration = Get-TestRunnerConfiguration -Path $repoTimeoutPath
    $timeoutTotal = 0
    foreach ($suite in $repoSuites) {
        $suiteId = Get-TestSuiteId -SuitePath $suite -SuiteRoot $repoTestsRoot
        $timeoutTotal += Get-SuiteTimeoutSeconds -Configuration $configuration -SuiteId $suiteId
    }
    $requiredSeconds = [int]$configuration.SetupAndNonSuiteBudgetSeconds + $timeoutTotal + [int]$configuration.MarginSeconds
    $workflowText = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot '.github/workflows/validate.yml')
    if ($workflowText -notmatch '(?m)^\s*timeout-minutes:\s*(\d+)\s*$') { throw 'FAIL: workflow timeout-minutes is missing' }
    $workflowSeconds = [int]$matches[1] * 60
    Assert ($workflowSeconds -gt $requiredSeconds) 'workflow timeout is strictly greater than the proven suite budget'

    Write-Host 'test runner tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
