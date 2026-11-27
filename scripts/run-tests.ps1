#requires -Version 7.0
<#
.SYNOPSIS
    Runs tests/*.tests.ps1 suites in individual pwsh processes.

.DESCRIPTION
    Each suite gets the budget that tests/test-timeouts.psd1 names for it; a suite
    without a budget, or a budget without a suite, stops the run before anything
    starts. Suites are scheduled in descending budget order across an active
    process pool up to -MaxParallel (or 1 when -Suite is specified). Output is
    buffered per suite and printed contiguously on completion. On timeout the
    suite's whole process tree is killed. Exits 1 when any suite fails or times out.
    When -Suite is specified, validates the entire test-timeouts.psd1 table against
    disk, then executes only the selected suite.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER Suite
    Optional suite name to run (e.g. 'deploy' or 'deploy.tests.ps1').
    When omitted, all suites are run.

.PARAMETER MaxParallel
    Maximum number of suite processes to run concurrently (1..32). Defaults to
    min(4, ProcessorCount). Forced to 1 when -Suite is specified.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $Suite,
    [ValidateRange(1, 32)]
    [int] $MaxParallel = [Math]::Min(4, [Math]::Max(1, [Environment]::ProcessorCount))
)

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
foreach ($suiteFile in $suites) {
    $budgets[$suiteFile.Name] = [int] $budgets[$suiteFile.Name]
    if ($budgets[$suiteFile.Name] -le 0) { throw "Budget for $($suiteFile.Name) must be positive." }
}

if ($PSBoundParameters.ContainsKey('Suite')) {
    if ([string]::IsNullOrWhiteSpace($Suite)) {
        throw 'Suite parameter cannot be empty or whitespace.'
    }
    $targetName = (Split-Path -Leaf $Suite).Trim()
    if ($targetName -notmatch '\.tests\.ps1$') {
        if ($targetName -match '\.tests$') {
            $targetName = "$targetName.ps1"
        }
        elseif ($targetName -match '\.ps1$') {
            $targetName = ($targetName -replace '\.ps1$', '.tests.ps1')
        }
        else {
            $targetName = "$targetName.tests.ps1"
        }
    }
    $matched = @($suites | Where-Object { $_.Name -ieq $targetName })
    if ($matched.Count -eq 0) {
        throw "Suite '$Suite' (resolved as '$targetName') was not found in $testsRoot."
    }
    $suites = $matched
}

function Start-TestSuiteSlot {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo] $SuiteFile,
        [Parameter(Mandatory)] [int] $Timeout,
        [Parameter(Mandatory)] [string] $PwshPath,
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    $slot = [pscustomobject]@{
        SuiteFile     = $SuiteFile
        Timeout       = $Timeout
        Workspace     = $null
        Process       = $null
        StdoutTask    = $null
        StderrTask    = $null
        Clock         = [System.Diagnostics.Stopwatch]::StartNew()
        Problem       = $null
        ProblemKind   = ''
        TimedOut      = $false
        OutputDrained = $false
        StartupFailed = $false
    }
    try {
        if ($SuiteFile.Name -eq 'config-sync.tests.ps1') {
            $slot.Workspace = New-ConfigSyncTestWork -RepoRoot $RepoRoot
        }
        $info = [System.Diagnostics.ProcessStartInfo]::new($PwshPath)
        foreach ($argument in @('-NoProfile', '-File', $SuiteFile.FullName)) { $info.ArgumentList.Add($argument) }
        if ($slot.Workspace) {
            foreach ($argument in @('-WorkRoot', $slot.Workspace.Root, '-WorkspaceRunId', $slot.Workspace.RunId)) {
                $info.ArgumentList.Add($argument)
            }
        }
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $slot.Process = $process
        $process.StandardInput.Close()
        $slot.StdoutTask = $process.StandardOutput.ReadToEndAsync()
        $slot.StderrTask = $process.StandardError.ReadToEndAsync()
    }
    catch {
        $slot.Problem = 'runner failure: ' + $_.Exception.GetType().Name
        $slot.ProblemKind = 'RunnerFailure'
        $slot.StartupFailed = $true
    }
    return $slot
}

function Complete-TestSuiteSlot {
    param(
        [Parameter(Mandatory)] $Slot,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Failures
    )

    $suiteName = $Slot.SuiteFile.Name
    $process = $Slot.Process
    $stdoutText = ''
    $stderrText = ''
    try {
        if ($Slot.StartupFailed -and $process -and -not $process.HasExited) {
            try { $process.Kill($true); $null = $process.WaitForExit(5000) } catch {}
        }
        if ($process -and $Slot.StdoutTask -and $Slot.StderrTask) {
            # A descendant that keeps the inherited pipes open must not hang the runner.
            if ([System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]] @($Slot.StdoutTask, $Slot.StderrTask), 5000)) {
                $Slot.OutputDrained = $true
                $stdoutText = $Slot.StdoutTask.Result
                $stderrText = $Slot.StderrTask.Result
            }
            elseif (-not $Slot.Problem) {
                $Slot.Problem = 'output was not drained'
                $Slot.ProblemKind = 'OutputNotDrained'
            }
        }
        if (-not $Slot.Problem -and $process -and $process.ExitCode -ne 0) {
            $Slot.Problem = "exit code $($process.ExitCode)"
            $Slot.ProblemKind = 'ChildExitFailed'
        }
    }
    catch {
        if (-not $Slot.Problem) {
            $Slot.Problem = 'runner failure: ' + $_.Exception.GetType().Name
            $Slot.ProblemKind = 'RunnerFailure'
        }
    }
    finally {
        $terminal = ($null -eq $process) -or $process.HasExited
        $childExit = if ($process -and $terminal) { $process.ExitCode } else { $null }
        if (-not $terminal -and -not $Slot.ProblemKind) { $Slot.ProblemKind = 'ProcessNotTerminal' }
        if ($Slot.Workspace -and (Test-Path -LiteralPath $Slot.Workspace.Root)) {
            if (-not $Slot.Problem) {
                $Slot.Problem = 'workspace was not finalized'
                $Slot.ProblemKind = 'WorkspaceNotFinalized'
            }
            $outcome = if ($Slot.TimedOut) { 'TimedOut' } else { 'Unknown' }
            try {
                # Only the synchronous suite can finalize its payload. Parent exit or drained
                # pipes cannot exclude a detached writer when the child skipped finalization.
                Complete-ConfigSyncTestWork -RepoRoot $RepoRoot -WorkRoot $Slot.Workspace.Root -RunId $Slot.Workspace.RunId `
                    -Outcome $outcome -ParentTerminal $terminal -OutputDrained $Slot.OutputDrained `
                    -ExitCode $childExit -ProblemKind $Slot.ProblemKind -ReceiptRole Runner
            }
            catch { $Slot.Problem = 'workspace finalization failed: ' + $_.Exception.GetType().Name }
        }
        if ($process) { $process.Dispose() }
    }

    $Slot.Clock.Stop()
    $seconds = '{0:n1}s' -f $Slot.Clock.Elapsed.TotalSeconds
    Write-Host "=== $suiteName ==="
    foreach ($text in @($stdoutText, $stderrText)) {
        if ($text) { Write-Host $text.TrimEnd() }
    }
    if ($Slot.Problem) {
        $Failures.Add("$suiteName`: $($Slot.Problem)")
        Write-Host "--- $suiteName FAIL: $($Slot.Problem) ($seconds)" -ForegroundColor Red
    }
    else {
        Write-Host "--- $suiteName PASS ($seconds)"
    }
}

$pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
$failures = [System.Collections.Generic.List[string]]::new()
$effectiveMaxParallel = if ($PSBoundParameters.ContainsKey('Suite')) { 1 } else { [Math]::Min($MaxParallel, [Math]::Max(1, $suites.Count)) }
$pending = [System.Collections.Generic.Queue[System.IO.FileInfo]]::new()
foreach ($suiteFile in @($suites | Sort-Object @{ Expression = { $budgets[$_.Name] }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false })) {
    $pending.Enqueue($suiteFile)
}
$active = [System.Collections.Generic.List[object]]::new()
try {
    while ($pending.Count -gt 0 -or $active.Count -gt 0) {
        while ($active.Count -lt $effectiveMaxParallel -and $pending.Count -gt 0) {
            $suiteFile = $pending.Dequeue()
            $slot = Start-TestSuiteSlot -SuiteFile $suiteFile -Timeout $budgets[$suiteFile.Name] -PwshPath $pwsh -RepoRoot $RepoRoot
            if ($slot.StartupFailed) {
                Complete-TestSuiteSlot -Slot $slot -RepoRoot $RepoRoot -Failures $failures
            }
            else {
                $active.Add($slot)
            }
        }
        $completedAny = $false
        for ($i = $active.Count - 1; $i -ge 0; $i--) {
            $slot = $active[$i]
            $exited = $slot.Process.HasExited
            if (-not $exited -and $slot.Clock.Elapsed.TotalMilliseconds -ge ($slot.Timeout * 1000)) {
                $slot.TimedOut = $true
                $slot.ProblemKind = 'TimedOut'
                $slot.Problem = "timed out after $($slot.Timeout) s"
                try { $slot.Process.Kill($true) } catch { $slot.Problem += ' (process tree kill failed)' }
                if (-not $slot.Process.WaitForExit(5000)) { $slot.Problem += ' (process did not exit)' }
                $exited = $true
            }
            if ($exited) {
                $active.RemoveAt($i)
                Complete-TestSuiteSlot -Slot $slot -RepoRoot $RepoRoot -Failures $failures
                $completedAny = $true
            }
        }
        if ($active.Count -gt 0 -and (-not $completedAny -or $pending.Count -eq 0)) {
            Start-Sleep -Milliseconds 50
        }
    }
}
finally {
    foreach ($slot in @($active)) {
        if ($slot.Process -and -not $slot.Process.HasExited) {
            $slot.Problem = 'runner aborted'
            $slot.ProblemKind = 'RunnerFailure'
            try { $slot.Process.Kill($true); $null = $slot.Process.WaitForExit(5000) } catch {}
        }
        Complete-TestSuiteSlot -Slot $slot -RepoRoot $RepoRoot -Failures $failures
    }
}

$result = if ($failures.Count) { 'FAIL' } else { 'PASS' }
Write-Host ('Test summary: {0}; suites={1}; failed={2}' -f $result, $suites.Count, $failures.Count)
foreach ($failure in $failures) { Write-Host "  $failure" }
if ($failures.Count) { exit 1 }
