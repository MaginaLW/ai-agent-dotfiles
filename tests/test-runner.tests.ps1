#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner = Join-Path $RepoRoot 'scripts/run-tests.ps1'
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures/test-runner'

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

# Builds a throwaway repo whose tests/ holds the named fixture suites (plus the
# timeout helpers) and the given budgets, runs run-tests.ps1 on it, and returns
# the exit code and combined output.
function Invoke-Runner {
    param([Parameter(Mandatory)] [string] $Label, [Parameter(Mandatory)] [hashtable] $Budgets, [string[]] $Suites = @())

    $caseTests = Join-Path $work "$Label/tests"
    New-Item -ItemType Directory -Path $caseTests -Force | Out-Null
    foreach ($name in @($Suites) + @('timeout-child.ps1', 'timeout-grandchild.ps1')) {
        Copy-Item -LiteralPath (Join-Path $fixtureRoot $name) -Destination $caseTests
    }
    $entries = @($Budgets.Keys | ForEach-Object { "        '$_' = $($Budgets[$_])" })
    Set-Content -LiteralPath (Join-Path $caseTests 'test-timeouts.psd1') -Value (@('@{', '    Suites = @{') + $entries + @('    }', '}'))
    $output = & pwsh -NoProfile -File $runner -RepoRoot (Join-Path $work $Label) 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $output }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-test-runner-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
$stateVariable = 'AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT'
$savedState = [Environment]::GetEnvironmentVariable($stateVariable)

try {
    Write-Host '[pass and failure]'
    $r = Invoke-Runner 'pass' @{ 'pass.tests.ps1' = 30 } @('pass.tests.ps1')
    Assert ($r.Code -eq 0) 'a passing suite exits 0'
    Assert ($r.Out -match 'fixture pass stdout' -and $r.Out -match 'Test summary: PASS; suites=1; failed=0') 'suite output and the PASS summary are printed'

    $r = Invoke-Runner 'fail' @{ 'pass.tests.ps1' = 30; 'fail.tests.ps1' = 30 } @('pass.tests.ps1', 'fail.tests.ps1')
    Assert ($r.Code -eq 1) 'a failing suite makes the run exit 1'
    Assert ($r.Out -match 'fixture failure stdout' -and $r.Out -match 'fixture failure stderr') 'a failing suite keeps its stdout and stderr'
    Assert ($r.Out -match 'fail\.tests\.ps1: exit code 7' -and $r.Out -match 'suites=2; failed=1') 'the summary names the failing suite and its exit code'

    Write-Host '[budgets]'
    $r = Invoke-Runner 'unbudgeted' @{ 'pass.tests.ps1' = 30 } @('pass.tests.ps1', 'fail.tests.ps1')
    Assert ($r.Code -ne 0 -and $r.Out -match 'Missing: fail\.tests\.ps1' -and $r.Out -notmatch 'fixture pass stdout') 'a suite without a budget stops the run before any suite starts'
    $r = Invoke-Runner 'stale' @{ 'pass.tests.ps1' = 30; 'gone.tests.ps1' = 30 } @('pass.tests.ps1')
    Assert ($r.Code -ne 0 -and $r.Out -match 'unknown: gone\.tests\.ps1') 'a budget without a suite stops the run'

    $repoBudgets = (Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'tests/test-timeouts.psd1')).Suites
    $repoSuites = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.tests.ps1' | ForEach-Object Name)
    Assert (@(Compare-Object @($repoBudgets.Keys) $repoSuites).Count -eq 0) 'every repository suite has exactly one budget'
    $total = ($repoBudgets.Values | Measure-Object -Sum).Sum
    # The 45-minute CI job also runs the other validation gates; keep 7 minutes for them.
    Assert ($total -le 2280) "suite budgets fit the 45-minute CI job (total $total s)"

    Write-Host '[timeout kills the process tree]'
    $stateRoot = Join-Path $work 'process-tree-state'
    [Environment]::SetEnvironmentVariable($stateVariable, $stateRoot)
    $r = Invoke-Runner 'timeout' @{ 'timeout-parent.tests.ps1' = 8 } @('timeout-parent.tests.ps1')
    Assert ($r.Code -eq 1 -and $r.Out -match 'timeout-parent\.tests\.ps1: timed out after 8 s' -and $r.Out -notmatch 'kill failed|did not exit') 'a suite over budget is killed and reported'
    foreach ($name in @('parent', 'child', 'grandchild')) {
        $pidPath = Join-Path $stateRoot "$name.pid"
        Assert ((Test-Path -LiteralPath $pidPath -PathType Leaf)) "$name process started"
        $processId = [int](Get-Content -Raw -LiteralPath $pidPath)
        Start-Sleep -Milliseconds 150
        Assert ($null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "$name process is no longer alive"
    }

    Write-Host 'test runner tests: PASS'
}
finally {
    [Environment]::SetEnvironmentVariable($stateVariable, $savedState)
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
