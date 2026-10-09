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
$inheritedName = 'AI_AGENT_DOTFILES_RUNNER_INHERITED'
$overrideName = 'AI_AGENT_DOTFILES_RUNNER_OVERRIDE'
$savedInherited = [Environment]::GetEnvironmentVariable($inheritedName, [EnvironmentVariableTarget]::Process)
$savedOverride = [Environment]::GetEnvironmentVariable($overrideName, [EnvironmentVariableTarget]::Process)
[Environment]::SetEnvironmentVariable($inheritedName, 'inherited-value', [EnvironmentVariableTarget]::Process)
[Environment]::SetEnvironmentVariable($overrideName, 'parent-value', [EnvironmentVariableTarget]::Process)

try {
    Write-Host '[pass and failure records]'
    $passSummaryPath = Join-Path $work 'pass.json'
    $passSummary = Invoke-TestSuiteCollection `
        -SuitePaths @((Join-Path $fixtureRoot 'pass.tests.ps1')) `
        -SuiteRoot $fixtureRoot `
        -TimeoutConfigPath $timeouts `
        -JsonSummaryPath $passSummaryPath `
        -Environment @{ $overrideName = 'child-value' }
    Assert ($passSummary.Result -eq 'PASS') 'passing fixture produces PASS'
    Assert ($passSummary.Counts.Discovered -eq 1 -and $passSummary.Counts.Completed -eq 1 -and $passSummary.Counts.Passed -eq 1) 'passing fixture is discovered, completed, and passed exactly once'
    Assert ((Test-Path -LiteralPath $passSummaryPath -PathType Leaf)) 'summary is written create-new'
    $passOutputLines = @(([string] $passSummary.Suites[0].Stdout) -split "`r?`n")
    Assert ($passOutputLines -ccontains 'fixture-inherited=inherited-value') 'suite inherits the parent process environment'
    Assert ($passOutputLines -ccontains 'fixture-override=child-value') 'suite receives the requested environment overlay'
    Assert ($passOutputLines -ccontains "fixture-working-directory=$((Get-Location).Path)") 'suite inherits the runner working directory'
    Assert ([Environment]::GetEnvironmentVariable($overrideName, [EnvironmentVariableTarget]::Process) -ceq 'parent-value') 'runner restores an overlaid parent environment value'
    $expectedPassRequired = [int] $passSummary.SetupAndNonSuiteBudgetSeconds + [int] $passSummary.Suites[0].TimeoutSeconds + [int] $passSummary.MarginSeconds
    Assert ([int] $passSummary.RequiredJobTimeoutSeconds -eq $expectedPassRequired) 'RequiredJobTimeoutSeconds keeps the setup + suite budgets + margin formula'
    $passJson = Get-Content -Raw -LiteralPath $passSummaryPath | ConvertFrom-Json
    Assert ([int] $passJson.SchemaVersion -eq 1 -and $passJson.ReportKind -ceq 'test-run' -and $passJson.Result -ceq 'PASS') 'summary JSON records SchemaVersion, ReportKind and Result'
    Assert ($passJson.Suites[0].SuiteId -ceq 'pass.tests.ps1' -and $passJson.Suites[0].State -ceq 'passed' -and [int] $passJson.Suites[0].ExitCode -eq 0) 'summary JSON records suite id, state and exit code'
    Assert ($passJson.DiscoveryHash -cmatch '^[0-9a-f]{64}$') 'summary JSON records the discovery hash'
    $existingThrew = $false
    try { $null = Invoke-TestSuiteCollection -SuitePaths @((Join-Path $fixtureRoot 'pass.tests.ps1')) -SuiteRoot $fixtureRoot -TimeoutConfigPath $timeouts -JsonSummaryPath $passSummaryPath }
    catch { $existingThrew = $true }
    Assert $existingThrew 'an existing summary path is refused instead of overwritten'

    $failureSummary = Invoke-TestSuiteCollection -SuitePaths @((Join-Path $fixtureRoot 'fail.tests.ps1')) -SuiteRoot $fixtureRoot -TimeoutConfigPath $timeouts -JsonSummaryPath (Join-Path $work 'failure.json')
    Assert ($failureSummary.Result -eq 'FAIL' -and $failureSummary.Counts.Failed -eq 1) 'non-zero fixture is recorded as one failure'
    Assert ($failureSummary.Suites[0].ExitCode -eq 7) 'non-zero exit code is retained'
    Assert ($failureSummary.Suites[0].Stdout -ceq 'fixture failure stdout') 'non-zero fixture stdout is retained'
    Assert ($failureSummary.Suites[0].Stderr -ceq 'fixture failure stderr') 'non-zero fixture stderr is retained'

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
    Assert ($timeoutSummary.Counts.TreeKillFailed -eq 0 -and $timeoutSummary.Suites[0].TreeKilled) 'timeout terminates the process tree'
    Assert ($timeoutSummary.Suites[0].State -ceq 'timed-out' -and -not $timeoutSummary.Suites[0].Completed -and $timeoutSummary.Suites[0].ExitCode -eq -1) 'timeout record uses timed-out semantics'
    Assert ($timeoutSummary.Suites[0].Stderr -ceq 'test-runner-suite-timeout') 'timeout record uses the stable timeout token'
    foreach ($name in @('parent', 'child', 'grandchild')) {
        $pidPath = Join-Path $stateRoot "$name.pid"
        Assert ((Test-Path -LiteralPath $pidPath -PathType Leaf)) "$name PID was observed"
        $processId = [int](Get-Content -Raw -LiteralPath $pidPath)
        Start-Sleep -Milliseconds 150
        Assert ($null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "$name process is no longer alive"
    }

    Write-Host '[invalid environment input]'
    $invalidEnvironmentSummaryPath = Join-Path $work 'invalid-environment-summary.json'
    $invalidEnvironmentThrew = $false
    try {
        $null = Invoke-TestSuiteCollection `
            -SuitePaths @((Join-Path $fixtureRoot 'pass.tests.ps1')) `
            -SuiteRoot $fixtureRoot `
            -TimeoutConfigPath $timeouts `
            -JsonSummaryPath $invalidEnvironmentSummaryPath `
            -Environment @{ 'invalid=name' = 'value' }
    }
    catch {
        $invalidEnvironmentThrew = $true
    }

    Assert $invalidEnvironmentThrew 'invalid pre-launch environment input throws instead of fabricating a suite record'
    Assert (-not (Test-Path -LiteralPath $invalidEnvironmentSummaryPath)) 'invalid pre-launch environment input produces no test-run summary'

    Write-Host '[repository discovery]'
    $repoTestsRoot = Join-Path $RepoRoot 'tests'
    $repoTimeoutPath = Join-Path $repoTestsRoot 'test-timeouts.psd1'
    $repoSuites = Get-RootTestSuitePaths -TestsRoot $repoTestsRoot
    $expectedSuites = @(Get-ChildItem -LiteralPath $repoTestsRoot -File -Filter '*.tests.ps1' | Sort-Object Name | ForEach-Object FullName)
    Assert ($repoSuites.Count -eq $expectedSuites.Count) 'root-suite discovery exactly matches the dynamic filesystem snapshot'
    Assert (@(Compare-Object $repoSuites $expectedSuites).Count -eq 0) 'root-suite discovery is stable and complete'
    $configuration = Get-TestRunnerConfiguration -Path $repoTimeoutPath
    $allPositive = $true
    foreach ($suite in $repoSuites) {
        $suiteId = Get-TestSuiteId -SuitePath $suite -SuiteRoot $repoTestsRoot
        if ((Get-SuiteTimeoutSeconds -Configuration $configuration -SuiteId $suiteId) -le 0) { $allPositive = $false }
    }
    Assert $allPositive 'every discovered repository suite resolves a positive timeout'

    Write-Host '[run-tests.ps1 exit codes]'
    $runnerScriptPath = Join-Path $RepoRoot 'scripts/run-tests.ps1'
    foreach ($case in @(
        @{ Label = 'passing'; Suite = 'pass.tests.ps1'; ExpectedExit = 0; ExpectedResult = 'PASS' },
        @{ Label = 'failing'; Suite = 'fail.tests.ps1'; ExpectedExit = 1; ExpectedResult = 'FAIL' }
    )) {
        $caseRoot = Join-Path $work "runner-$($case.Label)"
        $caseTests = Join-Path $caseRoot 'tests'
        New-Item -ItemType Directory -Path $caseTests -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixtureRoot $case.Suite) -Destination $caseTests
        Copy-Item -LiteralPath $timeouts -Destination (Join-Path $caseTests 'test-timeouts.psd1')
        $caseSummaryPath = Join-Path $work "runner-$($case.Label).json"
        $null = & pwsh -NoProfile -File $runnerScriptPath -All -JsonSummaryPath $caseSummaryPath -RepoRoot $caseRoot 2>&1
        Assert ($LASTEXITCODE -eq $case.ExpectedExit) "run-tests.ps1 exits $($case.ExpectedExit) for a $($case.Label) suite"
        $caseSummary = Get-Content -Raw -LiteralPath $caseSummaryPath | ConvertFrom-Json
        Assert ($caseSummary.Result -ceq $case.ExpectedResult -and [int] $caseSummary.Counts.Discovered -eq 1) "run-tests.ps1 writes a $($case.ExpectedResult) summary for a $($case.Label) suite"
    }

    Write-Host 'test runner tests: PASS'
}
finally {
    [Environment]::SetEnvironmentVariable($inheritedName, $savedInherited, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable($overrideName, $savedOverride, [EnvironmentVariableTarget]::Process)
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
