#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner = Join-Path $RepoRoot 'scripts/run-tests.ps1'
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures/test-runner'
$workspaceHelper = Join-Path $RepoRoot 'scripts/config-sync-test-workspace.ps1'
. $workspaceHelper

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

# Builds a throwaway repo whose tests/ holds the named fixture suites (plus the
# timeout helpers) and the given budgets, runs run-tests.ps1 on it, and returns
# the exit code and combined output.
function Invoke-Runner {
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [hashtable] $Budgets,
        [string[]] $Suites = @(),
        [hashtable] $InlineSuites = @{}
    )

    $caseTests = Join-Path $work "$Label/tests"
    New-Item -ItemType Directory -Path $caseTests -Force | Out-Null
    foreach ($name in @($Suites) + @('timeout-child.ps1', 'timeout-grandchild.ps1')) {
        Copy-Item -LiteralPath (Join-Path $fixtureRoot $name) -Destination $caseTests
    }
    foreach ($name in $InlineSuites.Keys) {
        Set-Content -LiteralPath (Join-Path $caseTests $name) -Value $InlineSuites[$name]
    }
    if ($InlineSuites.ContainsKey('config-sync.tests.ps1')) {
        $caseScripts = Join-Path $work "$Label/scripts"
        New-Item -ItemType Directory -Path $caseScripts | Out-Null
        Copy-Item -LiteralPath $workspaceHelper -Destination $caseScripts
    }
    $entries = @($Budgets.Keys | ForEach-Object { "        '$_' = $($Budgets[$_])" })
    Set-Content -LiteralPath (Join-Path $caseTests 'test-timeouts.psd1') -Value (@('@{', '    Suites = @{') + $entries + @('    }', '}'))
    $output = & pwsh -NoProfile -File $runner -RepoRoot (Join-Path $work $Label) 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $output; Repo = (Join-Path $work $Label) }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-test-runner-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
$stateVariable = 'AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT'
$savedState = [Environment]::GetEnvironmentVariable($stateVariable)
$detachedWriters = [Collections.Generic.List[object]]::new()
$timeoutTreeTerminal = $true

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
    $total = ($repoBudgets.Values | Measure-Object -Sum).Sum
    # The 35-minute CI job also runs the other validation gates; keep 7 minutes for them.
    Assert ($total -le 1680) "suite budgets fit the 35-minute CI job (total $total s)"

    Write-Host '[config-sync workspace ownership and receipts]'
    $configSetup = @'
param([string] $WorkRoot, [string] $WorkspaceRunId)
$ErrorActionPreference = 'Stop'
$caseRepo = Split-Path -Parent $PSScriptRoot
. (Join-Path $caseRepo 'scripts/config-sync-test-workspace.ps1')
$owned = Assert-ConfigSyncTestWork -RepoRoot $caseRepo -WorkRoot $WorkRoot -RunId $WorkspaceRunId
[IO.File]::WriteAllText((Join-Path $caseRepo 'observed-work-root.txt'), $owned)
[IO.File]::WriteAllText((Join-Path $owned 'payload.txt'), 'synthetic fixture payload')
'@
    $configSuccess = $configSetup + @'

Complete-ConfigSyncTestWork -RepoRoot $caseRepo -WorkRoot $owned -RunId $WorkspaceRunId -Outcome Passed -RemovePayload
exit 0
'@
    $siblingsBefore = @(Get-ChildItem -LiteralPath $work -Directory | Where-Object Name -like '.ai-agent-dotfiles-config-sync-*' | ForEach-Object Name)
    $r = Invoke-Runner 'config-success' @{ 'config-sync.tests.ps1' = 30 } -InlineSuites @{ 'config-sync.tests.ps1' = $configSuccess }
    $observed = Get-Content -LiteralPath (Join-Path $r.Repo 'observed-work-root.txt') -Raw
    Assert ($r.Code -eq 0 -and (Split-Path -Parent $observed) -eq [IO.Path]::GetFullPath((Join-Path $r.Repo 'tmp/tests/config-sync'))) 'config-sync creates its owned root in project tmp and closes success'
    $siblingsAfter = @(Get-ChildItem -LiteralPath $work -Directory | Where-Object Name -like '.ai-agent-dotfiles-config-sync-*' | ForEach-Object Name)
    Assert (($siblingsBefore -join "`n") -eq ($siblingsAfter -join "`n") -and -not (Test-Path -LiteralPath $observed)) 'config-sync success creates no checkout sibling residue'

    $ioRepo = Join-Path $work 'receipt-refusal'
    New-Item -ItemType Directory -Path $ioRepo | Out-Null
    $owned = New-ConfigSyncTestWork -RepoRoot $ioRepo
    $payload = Join-Path $owned.Root 'payload.txt'
    $sentinel = Join-Path $ioRepo 'adjacent-sentinel.txt'
    [IO.File]::WriteAllText($payload, 'unique synthetic diagnostic')
    [IO.File]::WriteAllText($sentinel, 'protected synthetic sentinel')
    $payloadHash = (Get-FileHash -LiteralPath $payload).Hash
    $sentinelHash = (Get-FileHash -LiteralPath $sentinel).Hash
    $receiptDir = Join-Path $ioRepo 'tmp/tests/config-sync/receipts'
    New-Item -ItemType Directory -Path $receiptDir | Out-Null
    $blockedReceipt = Join-Path $receiptDir "$($owned.RunId).json"
    [IO.File]::WriteAllText($blockedReceipt, 'prior receipt must not be overwritten')
    $receiptHash = (Get-FileHash -LiteralPath $blockedReceipt).Hash
    $lock = [IO.FileStream]::new($blockedReceipt, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $refused = $false
    try { Complete-ConfigSyncTestWork -RepoRoot $ioRepo -WorkRoot $owned.Root -RunId $owned.RunId -Outcome Failed -RemovePayload }
    catch { $refused = $true }
    finally { $lock.Dispose() }
    Assert ($refused -and (Get-FileHash -LiteralPath $payload).Hash -eq $payloadHash) 'a refused receipt write preserves its owned diagnostic payload'
    Assert ((Get-FileHash -LiteralPath $sentinel).Hash -eq $sentinelHash -and (Get-FileHash -LiteralPath $blockedReceipt).Hash -eq $receiptHash) 'receipt IO refusal preserves adjacent sentinel and prior receipt bytes'

    $configExit7 = $configSetup + @'

$writer = Join-Path $PSScriptRoot 'timeout-grandchild.ps1'
[IO.File]::WriteAllText((Join-Path $caseRepo 'detached-launch.pending'), 'owned fixture launch may have started')
$arguments = '-NoProfile -File "{0}" -StateRoot "{1}"' -f $writer, $owned
$info = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1 -ExpandProperty Source))
$info.Arguments = $arguments
$info.UseShellExecute = $true
$info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$child = [Diagnostics.Process]::Start($info)
@{ pid=$child.Id;started_utc=$child.StartTime.ToUniversalTime().ToString('o') } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $caseRepo 'detached-writer.json')
exit 7
'@
    $r = Invoke-Runner 'config-exit7' @{ 'config-sync.tests.ps1' = 30 } -InlineSuites @{ 'config-sync.tests.ps1' = $configExit7 }
    $identity = Get-Content -LiteralPath (Join-Path $r.Repo 'detached-writer.json') -Raw | ConvertFrom-Json
    $detachedWriters.Add($identity)
    $ownedPath = Get-Content -LiteralPath (Join-Path $r.Repo 'observed-work-root.txt') -Raw
    Assert (Test-Path -LiteralPath (Join-Path $ownedPath 'payload.txt')) 'a suite without child finalization preserves its owned payload'
    $live = Get-Process -Id ([int]$identity.pid) -ErrorAction SilentlyContinue
    Assert ($null -ne $live -and $live.StartTime.ToUniversalTime() -eq ([DateTime]$identity.started_utc).ToUniversalTime()) 'the exit7 fixture leaves its known detached writer alive'
    $receipt = Get-ChildItem -LiteralPath (Join-Path $r.Repo 'tmp/tests/config-sync/receipts') -File | Select-Object -First 1
    $diagnostic = Get-Content -LiteralPath $receipt.FullName -Raw | ConvertFrom-Json
    Assert ($r.Code -eq 1 -and $diagnostic.exit_code -eq 7 -and $diagnostic.problem_kind -eq 'ChildExitFailed' -and $diagnostic.problem_summary.Length -le 160) 'the parent saves the real exit7 reason without child finalization'
    Assert ($diagnostic.parent_terminal -and $diagnostic.output_drained -and $diagnostic.outcome -eq 'Unknown' -and $diagnostic.cleanup_required -and -not $diagnostic.cleanup_requested) 'parent exit and drained pipes retain UNKNOWN writer lifetime'
    Assert (Test-Path -LiteralPath (Join-Path $ownedPath 'payload.txt')) 'UNKNOWN lifetime preserves the exact owned payload'

    $configUnfinalized = $configSetup + "`nexit 0`n"
    $r = Invoke-Runner 'config-unfinalized' @{ 'config-sync.tests.ps1' = 30 } -InlineSuites @{ 'config-sync.tests.ps1' = $configUnfinalized }
    $ownedPath = Get-Content -LiteralPath (Join-Path $r.Repo 'observed-work-root.txt') -Raw
    $receipt = Get-ChildItem -LiteralPath (Join-Path $r.Repo 'tmp/tests/config-sync/receipts') -File | Select-Object -First 1
    $diagnostic = Get-Content -LiteralPath $receipt.FullName -Raw | ConvertFrom-Json
    Assert ($r.Code -eq 1 -and $diagnostic.exit_code -eq 0 -and $diagnostic.problem_kind -eq 'WorkspaceNotFinalized' -and $diagnostic.outcome -eq 'Unknown') 'exit0 without child finalization cannot become a successful run'
    Assert (Test-Path -LiteralPath (Join-Path $ownedPath 'payload.txt')) 'unfinalized exit0 retains its exact payload'

    $configTimeout = $configSetup + "`nStart-Sleep -Seconds 20`n"
    $r = Invoke-Runner 'config-timeout' @{ 'config-sync.tests.ps1' = 2 } -InlineSuites @{ 'config-sync.tests.ps1' = $configTimeout }
    $ownedPath = Get-Content -LiteralPath (Join-Path $r.Repo 'observed-work-root.txt') -Raw
    $receipt = Get-ChildItem -LiteralPath (Join-Path $r.Repo 'tmp/tests/config-sync/receipts') -File | Select-Object -First 1
    $diagnostic = Get-Content -LiteralPath $receipt.FullName -Raw | ConvertFrom-Json
    Assert ($r.Code -eq 1 -and $diagnostic.outcome -eq 'TimedOut' -and $diagnostic.problem_kind -eq 'TimedOut' -and $diagnostic.cleanup_required -and -not $diagnostic.cleanup_requested) 'timeout records its exact retained root without assuming every writer stopped'
    Assert (Test-Path -LiteralPath (Join-Path $ownedPath 'payload.txt')) 'timeout preserves the owned payload for terminal-state review'

    Write-Host '[timeout kills the process tree]'
    $stateRoot = Join-Path $work 'process-tree-state'
    [Environment]::SetEnvironmentVariable($stateVariable, $stateRoot)
    $timeoutTreeTerminal = $false
    $r = Invoke-Runner 'timeout' @{ 'timeout-parent.tests.ps1' = 8 } @('timeout-parent.tests.ps1')
    Assert ($r.Code -eq 1 -and $r.Out -match 'timeout-parent\.tests\.ps1: timed out after 8 s' -and $r.Out -notmatch 'kill failed|did not exit') 'a suite over budget is killed and reported'
    foreach ($name in @('parent', 'child', 'grandchild')) {
        $pidPath = Join-Path $stateRoot "$name.pid"
        Assert ((Test-Path -LiteralPath $pidPath -PathType Leaf)) "$name process started"
        $processId = [int](Get-Content -Raw -LiteralPath $pidPath)
        Start-Sleep -Milliseconds 150
        Assert ($null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "$name process is no longer alive"
    }
    $timeoutTreeTerminal = $true

    Write-Host 'test runner tests: PASS'
}
finally {
    [Environment]::SetEnvironmentVariable($stateVariable, $savedState)
    $allTerminal = $timeoutTreeTerminal
    $pendingLaunch = Join-Path $work 'config-exit7/detached-launch.pending'
    if (Test-Path -LiteralPath $pendingLaunch) {
        try {
            $identityPath = Join-Path $work 'config-exit7/detached-writer.json'
            $savedIdentity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
            if ([int]$savedIdentity.pid -le 0 -or [string]::IsNullOrWhiteSpace($savedIdentity.started_utc)) { throw 'Invalid owned writer identity.' }
            $created = ([DateTime]$savedIdentity.started_utc).ToUniversalTime()
            if (@($detachedWriters | Where-Object { $_.pid -eq $savedIdentity.pid -and ([DateTime]$_.started_utc).ToUniversalTime() -eq $created }).Count -eq 0) {
                $detachedWriters.Add($savedIdentity)
            }
        }
        catch { $allTerminal = $false }
    }
    foreach ($identity in $detachedWriters) {
        $live = Get-Process -Id ([int]$identity.pid) -ErrorAction SilentlyContinue
        if ($live -and $live.StartTime.ToUniversalTime() -eq ([DateTime]$identity.started_utc).ToUniversalTime()) {
            try { $live.Kill(); if (-not $live.WaitForExit(5000)) { $allTerminal = $false } }
            catch { $allTerminal = $false }
        }
    }
    if ($allTerminal -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
    elseif (-not $allTerminal) { throw "Fixture root preserved because its owned writer is not terminal: $work" }
}
