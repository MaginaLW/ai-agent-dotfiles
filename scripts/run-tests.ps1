#requires -Version 7.0
<#
.SYNOPSIS
    Runs every tests/*.tests.ps1 suite in its own pwsh process.

.DESCRIPTION
    Each suite gets the budget that tests/test-timeouts.psd1 names for it; a suite
    without a budget, or a budget without a suite, stops the run before anything
    starts. On timeout the suite's whole process tree is killed. Exits 1 when any
    suite fails or times out.
#>
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'config-sync-test-workspace.ps1')
$testsRoot = Join-Path $RepoRoot 'tests'
$budgets = (Import-PowerShellDataFile -LiteralPath (Join-Path $testsRoot 'test-timeouts.psd1')).Suites
$suites = @(Get-ChildItem -LiteralPath $testsRoot -File -Filter '*.tests.ps1' | Sort-Object Name)
$names = @($suites | ForEach-Object Name)
$unbudgeted = @($names | Where-Object { -not $budgets.ContainsKey($_) })
$unknown = @($budgets.Keys | Where-Object { $_ -notin $names })
if ($unbudgeted.Count -or $unknown.Count) {
    throw "tests/test-timeouts.psd1 must give each suite exactly one budget. Missing: $($unbudgeted -join ', '); unknown: $($unknown -join ', ')"
}
foreach ($suite in $suites) {
    $budgets[$suite.Name] = [int] $budgets[$suite.Name]
    if ($budgets[$suite.Name] -le 0) { throw "Budget for $($suite.Name) must be positive." }
}

$pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($suite in $suites) {
    $timeout = $budgets[$suite.Name]
    Write-Host "=== $($suite.Name) ==="
    $info = [System.Diagnostics.ProcessStartInfo]::new($pwsh)
    $workspace = $null
    if ($suite.Name -eq 'config-sync.tests.ps1') { $workspace = New-ConfigSyncTestWork -RepoRoot $RepoRoot }
    foreach ($argument in @('-NoProfile', '-File', $suite.FullName)) { $info.ArgumentList.Add($argument) }
    if ($workspace) {
        foreach ($argument in @('-WorkRoot', $workspace.Root, '-WorkspaceRunId', $workspace.RunId)) { $info.ArgumentList.Add($argument) }
    }
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $process = $null
    $problem = $null
    $problemKind = ''
    $timedOut = $false
    $outputDrained = $false
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($timeout * 1000)) {
            $timedOut = $true
            $problemKind = 'TimedOut'
            $problem = "timed out after $timeout s"
            try { $process.Kill($true) } catch { $problem += ' (process tree kill failed)' }
            if (-not $process.WaitForExit(5000)) { $problem += ' (process did not exit)' }
        }
        # A descendant that keeps the inherited pipes open must not hang the runner.
        if ([System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]] @($stdout, $stderr), 5000)) {
            $outputDrained = $true
            foreach ($text in @($stdout.Result, $stderr.Result)) { if ($text) { Write-Host $text.TrimEnd() } }
        }
        elseif (-not $problem) { $problem = 'output was not drained'; $problemKind = 'OutputNotDrained' }
        if (-not $problem -and $process.ExitCode -ne 0) { $problem = "exit code $($process.ExitCode)"; $problemKind = 'ChildExitFailed' }
    }
    catch { $problem = 'runner failure: ' + $_.Exception.GetType().Name; $problemKind = 'RunnerFailure' }
    finally {
        $terminal = ($null -eq $process) -or $process.HasExited
        $childExit = if ($process -and $terminal) { $process.ExitCode } else { $null }
        if (-not $terminal -and -not $problemKind) { $problemKind = 'ProcessNotTerminal' }
        if ($workspace -and (Test-Path -LiteralPath $workspace.Root)) {
            if (-not $problem) {
                $problem = 'workspace was not finalized'
                $problemKind = 'WorkspaceNotFinalized'
            }
            $outcome = if ($timedOut) { 'TimedOut' } else { 'Unknown' }
            try {
                # Only the synchronous suite can finalize its payload. Parent exit or drained
                # pipes cannot exclude a detached writer when the child skipped finalization.
                Complete-ConfigSyncTestWork -RepoRoot $RepoRoot -WorkRoot $workspace.Root -RunId $workspace.RunId `
                    -Outcome $outcome -ParentTerminal $terminal -OutputDrained $outputDrained `
                    -ExitCode $childExit -ProblemKind $problemKind -ReceiptRole Runner
            }
            catch { $problem = 'workspace finalization failed: ' + $_.Exception.GetType().Name }
        }
        if ($process) { $process.Dispose() }
    }
    $seconds = '{0:n1}s' -f $clock.Elapsed.TotalSeconds
    if ($problem) {
        $failures.Add("$($suite.Name): $problem")
        Write-Host "--- $($suite.Name) FAIL: $problem ($seconds)" -ForegroundColor Red
    }
    else {
        Write-Host "--- $($suite.Name) PASS ($seconds)"
    }
}

$result = if ($failures.Count) { 'FAIL' } else { 'PASS' }
Write-Host ('Test summary: {0}; suites={1}; failed={2}' -f $result, $suites.Count, $failures.Count)
foreach ($failure in $failures) { Write-Host "  $failure" }
if ($failures.Count) { exit 1 }
