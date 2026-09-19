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

function Get-WorkflowJobBlock {
    # Returns the YAML text of one top-level job block (2-space indent under jobs:),
    # used instead of a YAML parser because the runner contract only needs literal
    # scalar lines (timeout-minutes, the runner shard arguments) from fixed job names.
    param([Parameter(Mandatory)] [string] $WorkflowText, [Parameter(Mandatory)] [string] $JobName)
    $header = [regex]::Match($WorkflowText, "(?m)^  " + [regex]::Escape($JobName) + ":\s*$")
    if (-not $header.Success) { throw "FAIL: workflow job '$JobName' is missing" }
    $start = $header.Index + $header.Length
    $nextJob = [regex]::Match($WorkflowText.Substring($start), "(?m)^  [A-Za-z0-9_-]+:\s*$")
    $length = if ($nextJob.Success) { $nextJob.Index } else { $WorkflowText.Length - $start }
    return $WorkflowText.Substring($start, $length)
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
    Assert ([int] $passSummary.RequiredJobTimeoutSeconds -eq $expectedPassRequired) 'unsharded RequiredJobTimeoutSeconds keeps the setup + suite budgets + margin formula'
    Assert (-not (@($passSummary.PSObject.Properties.Name) -ccontains 'ShardCount')) 'unsharded summary carries no shard fields'

    Write-Host '[shard summary fields]'
    $shardedSummary = Invoke-TestSuiteCollection `
        -SuitePaths @((Join-Path $fixtureRoot 'pass.tests.ps1')) `
        -SuiteRoot $fixtureRoot `
        -TimeoutConfigPath $timeouts `
        -JsonSummaryPath (Join-Path $work 'sharded.json') `
        -ShardCount 3 `
        -ShardIndex 2
    Assert ($shardedSummary.Result -eq 'PASS') 'sharded fixture run produces PASS'
    Assert ([int] $shardedSummary.ShardCount -eq 3 -and [int] $shardedSummary.ShardIndex -eq 2) 'sharded summary records the requested shard binding'
    Assert ([int] $shardedSummary.RequiredJobTimeoutSeconds -eq [int] $passSummary.RequiredJobTimeoutSeconds) 'sharded summary keeps the same required-seconds formula over its own suite set'
    $outOfRangeThrew = $false
    $outOfRangeSummaryPath = Join-Path $work 'sharded-out-of-range.json'
    try {
        $null = Invoke-TestSuiteCollection `
            -SuitePaths @((Join-Path $fixtureRoot 'pass.tests.ps1')) `
            -SuiteRoot $fixtureRoot `
            -TimeoutConfigPath $timeouts `
            -JsonSummaryPath $outOfRangeSummaryPath `
            -ShardCount 3 `
            -ShardIndex 4
    }
    catch {
        $outOfRangeThrew = $true
    }
    Assert $outOfRangeThrew 'collection rejects an out-of-range shard index instead of running suites'
    Assert (-not (Test-Path -LiteralPath $outOfRangeSummaryPath)) 'rejected shard input produces no test-run summary'

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
    Assert ($timeoutSummary.Counts.TreeKillFailed -eq 0) 'timeout terminates the process tree'
    foreach ($name in @('parent', 'child', 'grandchild')) {
        $pidPath = Join-Path $stateRoot "$name.pid"
        Assert ((Test-Path -LiteralPath $pidPath -PathType Leaf)) "$name PID was observed"
        $processId = [int](Get-Content -Raw -LiteralPath $pidPath)
        Start-Sleep -Milliseconds 150
        Assert ($null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "$name process is no longer alive"
    }

    Write-Host '[bounded native process failures]'
    $outputStateRoot = Join-Path $work 'output-cap-state'
    $outputSummaryPath = Join-Path $work 'output-cap-summary.json'
    New-Item -ItemType Directory -Path $outputStateRoot | Out-Null
    $outputSummary = Invoke-TestSuiteCollection `
        -SuitePaths @((Join-Path $fixtureRoot 'output-cap.tests.ps1')) `
        -SuiteRoot $fixtureRoot `
        -TimeoutConfigPath $timeouts `
        -JsonSummaryPath $outputSummaryPath `
        -Environment @{ AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT = $outputStateRoot }

    $pipeStateRoot = Join-Path $work 'pipe-holder-state'
    $pipeSummaryPath = Join-Path $work 'pipe-holder-summary.json'
    New-Item -ItemType Directory -Path $pipeStateRoot | Out-Null
    $pipeClock = [Diagnostics.Stopwatch]::StartNew()
    $pipeSummary = Invoke-TestSuiteCollection `
        -SuitePaths @((Join-Path $fixtureRoot 'pipe-holder.tests.ps1')) `
        -SuiteRoot $fixtureRoot `
        -TimeoutConfigPath $timeouts `
        -JsonSummaryPath $pipeSummaryPath `
        -Environment @{ AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT = $pipeStateRoot }
    $pipeClock.Stop()

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

    Assert ($outputSummary.Result -eq 'FAIL') 'output-cap failure fails the suite collection closed'
    Assert ($outputSummary.Counts.Failed -eq 1 -and $outputSummary.Counts.Completed -eq 1 -and $outputSummary.Counts.TimedOut -eq 0) 'output-cap failure is one completed non-timeout failure'
    Assert ($outputSummary.Suites[0].State -eq 'failed' -and $outputSummary.Suites[0].Completed -and -not $outputSummary.Suites[0].TimedOut) 'output-cap record uses failed/completed semantics'
    Assert ($outputSummary.Suites[0].TreeKilled -and -not $outputSummary.Suites[0].TreeKillFailed) 'output-cap record proves successful job termination'
    Assert ($outputSummary.Suites[0].Stderr -ceq 'test-runner-suite-process-failed') 'output-cap record uses the stable process-failure token'
    $outputPidPath = Join-Path $outputStateRoot 'output-cap.pid'
    Assert ((Test-Path -LiteralPath $outputPidPath -PathType Leaf)) 'output-cap suite PID was observed'
    $outputPid = [int](Get-Content -Raw -LiteralPath $outputPidPath)
    Assert ($null -eq (Get-Process -Id $outputPid -ErrorAction SilentlyContinue)) 'output-cap suite process is no longer alive'

    Assert ($pipeClock.ElapsedMilliseconds -lt 15000) 'runner returns within a bounded interval when a descendant keeps redirected output open'
    Assert ($pipeSummary.Result -eq 'FAIL') 'undrained inherited pipe fails the suite collection closed'
    $pipeParentPidPath = Join-Path $pipeStateRoot 'pipe-holder-parent.pid'
    $pipeHolderPidPath = Join-Path $pipeStateRoot 'pipe-holder-child.pid'
    Assert ((Test-Path -LiteralPath $pipeParentPidPath -PathType Leaf)) 'pipe-holder suite root PID was observed'
    Assert ((Test-Path -LiteralPath $pipeHolderPidPath -PathType Leaf)) 'pipe-holder descendant PID was observed'
    $pipeParentPid = [int](Get-Content -Raw -LiteralPath $pipeParentPidPath)
    $pipeHolderPid = [int](Get-Content -Raw -LiteralPath $pipeHolderPidPath)
    Assert ($null -eq (Get-Process -Id $pipeParentPid -ErrorAction SilentlyContinue)) 'pipe-holder suite root exited before runner completion'
    Assert ($null -eq (Get-Process -Id $pipeHolderPid -ErrorAction SilentlyContinue)) 'runner reaps the descendant that inherited the suite output pipe'
    Assert ($pipeSummary.Counts.Failed -eq 1 -and $pipeSummary.Counts.Completed -eq 1 -and $pipeSummary.Counts.TimedOut -eq 0) 'undrained inherited pipe is one completed non-timeout failure'
    Assert ($pipeSummary.Suites[0].State -eq 'failed' -and $pipeSummary.Suites[0].Completed -and -not $pipeSummary.Suites[0].TimedOut) 'undrained inherited pipe uses failed/completed semantics'
    Assert ($pipeSummary.Suites[0].TreeKilled -and -not $pipeSummary.Suites[0].TreeKillFailed) 'pipe-holder record proves successful job termination'
    Assert ($pipeSummary.Suites[0].Stderr -ceq 'test-runner-suite-process-failed') 'undrained inherited pipe records the stable process-failure token without parsing exception text'

    Assert $invalidEnvironmentThrew 'invalid pre-launch environment input throws instead of fabricating a suite record'
    Assert (-not (Test-Path -LiteralPath $invalidEnvironmentSummaryPath)) 'invalid pre-launch environment input produces no test-run summary'

    Write-Host '[repository discovery and proven suite budget]'
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

    Write-Host '[static shard partition and per-shard workflow bound]'
    # Owner decision 2026-09-19: the proven suite budget does not fit one hosted-runner
    # job (360-minute ceiling), so CI runs the partition in tests/test-shards.psd1 as
    # three parallel jobs. Each shard job's timeout must stay strictly above that
    # shard's budget + SetupAndNonSuiteBudgetSeconds + MarginSeconds and below the
    # platform ceiling; the partition union must equal discovery exactly once.
    $discoveredIds = @($repoSuites | ForEach-Object { Get-TestSuiteId -SuitePath $_ -SuiteRoot $repoTestsRoot })
    $shardConfigPath = Join-Path $repoTestsRoot 'test-shards.psd1'
    $partition = Get-TestShardPartition -ShardCount 3 -ShardConfigPath $shardConfigPath -DiscoveredSuiteIds $discoveredIds
    Assert (@($partition.Keys).Count -eq 3) 'shard partition defines exactly three shards'
    $unionIds = @(@($partition.Values) | ForEach-Object { $_ } | Sort-Object -Unique)
    Assert (@(Compare-Object $unionIds $discoveredIds).Count -eq 0) 'shard union equals the discovered suite set exactly once'
    $workflowText = (Get-Content -Raw -LiteralPath (Join-Path $RepoRoot '.github/workflows/validate.yml')) -replace "`r`n", "`n"
    $gatesBlock = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'validate-gates'
    Assert ($gatesBlock -cmatch [regex]::Escape('-SkipGates unified-test-runner')) 'gates job excludes the unified-test-runner gate that the shard jobs now carry'
    $shardBudgetTotal = 0
    for ($number = 1; $number -le 3; $number++) {
        $jobName = "validate-tests-$number"
        $jobBlock = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName $jobName
        $shardArguments = [regex]::Match($jobBlock, "-ShardCount\s+3\s+-ShardIndex\s+$number(?!\d)")
        Assert $shardArguments.Success "$jobName invokes the runner with -ShardCount 3 -ShardIndex $number"
        $timeoutMatch = [regex]::Match($jobBlock, '(?m)^\s*timeout-minutes:\s*(\d+)\s*$')
        if (-not $timeoutMatch.Success) { throw "FAIL: $jobName timeout-minutes is missing" }
        $timeoutSeconds = [int] $timeoutMatch.Groups[1].Value * 60
        $shardBudget = 0
        foreach ($suiteId in @($partition[[string] $number])) {
            $shardBudget += Get-SuiteTimeoutSeconds -Configuration $configuration -SuiteId $suiteId
        }
        $shardBudgetTotal += $shardBudget
        $shardRequiredSeconds = [int]$configuration.SetupAndNonSuiteBudgetSeconds + $shardBudget + [int]$configuration.MarginSeconds
        Assert ($timeoutSeconds -gt $shardRequiredSeconds) "$jobName timeout ($timeoutSeconds s) is strictly above shard $number required seconds ($shardRequiredSeconds s)"
        Assert ($timeoutSeconds -lt 21600) "$jobName timeout is below the 360-minute hosted-runner job ceiling"
    }
    Assert ($shardBudgetTotal -eq $timeoutTotal) 'the three shard budgets sum to the unsharded proven suite budget'

    Write-Host '[runner shard parameter validation]'
    $runnerScriptPath = Join-Path $RepoRoot 'scripts/run-tests.ps1'
    $rejectedSummaryPath = Join-Path $work 'rejected-shard-summary.json'
    $invalidShardCases = @(
        @{ Label = 'shard count without shard index'; Arguments = @('-ShardCount', '3') },
        @{ Label = 'shard index without shard count'; Arguments = @('-ShardIndex', '2') },
        @{ Label = 'zero shard count with an index'; Arguments = @('-ShardCount', '0', '-ShardIndex', '1') },
        @{ Label = 'shard index zero'; Arguments = @('-ShardCount', '3', '-ShardIndex', '0') },
        @{ Label = 'shard index above shard count'; Arguments = @('-ShardCount', '3', '-ShardIndex', '4') }
    )
    foreach ($case in $invalidShardCases) {
        $caseArguments = @($case.Arguments)
        # The rejected child writes its throw to stderr by design; keep those expected
        # error records from interacting with the suite's Stop error preference.
        $savedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & pwsh -NoProfile -File $runnerScriptPath -All -JsonSummaryPath $rejectedSummaryPath @caseArguments 2>&1
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        Assert ($LASTEXITCODE -ne 0) "runner rejects $($case.Label)"
        Assert (-not (Test-Path -LiteralPath $rejectedSummaryPath)) "rejected $($case.Label) produces no test-run summary"
    }

    Write-Host 'test runner tests: PASS'
}
finally {
    [Environment]::SetEnvironmentVariable($inheritedName, $savedInherited, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable($overrideName, $savedOverride, [EnvironmentVariableTarget]::Process)
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
