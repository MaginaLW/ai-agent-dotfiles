#requires -Version 7.0
<#
.SYNOPSIS
    Isolated integration and CLI tests for the local monitoring dashboard.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

$work = Join-Path $RepoRoot ('tmp/tests/dashboard/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$serverProcess = $null
$serverStdoutTask = $null
$serverStderrTask = $null

try {
    Write-Host 'dashboard: entry scripts and launcher'
    $cmdPath = Join-Path $RepoRoot 'start-dashboard.cmd'
    Assert-TestCondition (Test-Path -LiteralPath $cmdPath -PathType Leaf) 'start-dashboard.cmd exists at repository root'
    $cmdText = [IO.File]::ReadAllText($cmdPath)
    Assert-TestCondition ($cmdText.Contains('scripts\dashboard.ps1') -and $cmdText.Contains('where pwsh')) 'start-dashboard.cmd checks pwsh and invokes scripts\dashboard.ps1'

    $dashboardScript = Join-Path $RepoRoot 'scripts/dashboard.ps1'
    $cliScript = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'

    $helpRes = Invoke-TestProcess -ScriptPath $cliScript -Arguments @('help', 'dashboard')
    Assert-TestCondition ($helpRes.Code -eq 0 -and $helpRes.Out -match 'agent-dotfiles\.ps1 dashboard' -and $helpRes.Out -notmatch 'Invoking script') 'help dashboard outputs usage without running child'

    $helpRes2 = Invoke-TestProcess -ScriptPath $cliScript -Arguments @('dashboard', 'help')
    Assert-TestCondition ($helpRes2.Code -eq 0 -and $helpRes2.Out -match 'agent-dotfiles\.ps1 dashboard' -and $helpRes2.Out -notmatch 'Invoking script') 'dashboard help outputs usage without running child'

    $checkRes = Invoke-TestProcess -ScriptPath $dashboardScript -Arguments @('-Check', '-RepoRoot', $RepoRoot)
    Assert-TestCondition ($checkRes.Code -eq 0) 'scripts/dashboard.ps1 -Check exits 0'
    $checkJson = $null
    try { $checkJson = $checkRes.Out | ConvertFrom-Json } catch { $checkJson = $null }
    Assert-TestCondition ($null -ne $checkJson -and $checkJson.ok -eq $true) 'scripts/dashboard.ps1 -Check emits valid JSON with ok=true'

    $cliCheckRes = Invoke-TestProcess -ScriptPath $cliScript -Arguments @('dashboard', '-Check', '-RepoRoot', $RepoRoot)
    Assert-TestCondition ($cliCheckRes.Code -eq 0 -and $cliCheckRes.Out -notmatch 'Invoking script|Command result') 'agent-dotfiles.ps1 dashboard -Check exits 0 without wrapper banners'
    $cliCheckJson = $null
    try { $cliCheckJson = $cliCheckRes.Out | ConvertFrom-Json } catch { $cliCheckJson = $null }
    Assert-TestCondition ($null -ne $cliCheckJson -and $cliCheckJson.ok -eq $true) 'agent-dotfiles.ps1 dashboard -Check emits valid JSON with ok=true'

    Write-Host 'dashboard: isolated live server HTTP checks'
    $fixtureRepo = Join-Path $work 'repo'
    $fakeHome = Join-Path $work 'home'
    $fakeState = Join-Path $work 'state'
    New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'dashboard'), $fakeHome, $fakeState -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'dashboard/server.py') -Destination (Join-Path $fixtureRepo 'dashboard/server.py') -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'dashboard/index.html') -Destination (Join-Path $fixtureRepo 'dashboard/index.html') -Force
    Set-TestFile -Path (Join-Path $fixtureRepo 'README.md') -Content "# Fixture Repo`n"
    Set-TestFile -Path (Join-Path $fixtureRepo 'STATUS.md') -Content "# Project Status`n`nLast updated: 2026-11-25.`n`n## Open items`n`n- **Sample item.** Fixture summary.`n"

    $gitCommands = @(
        @('init'),
        @('config', 'user.email', 'fixture@example.invalid'),
        @('config', 'user.name', 'Fixture User'),
        @('add', '.'),
        @('commit', '-m', 'Initial fixture commit')
    )
    foreach ($gitArgs in $gitCommands) {
        $gitOut = & git -C $fixtureRepo @gitArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git $($gitArgs -join ' ') failed: $($gitOut -join "`n")"
        }
    }

    $pythonCommands = @(Get-Command python -CommandType Application -ErrorAction Stop)
    $pythonPath = $pythonCommands[0].Source
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($pythonPath)
    foreach ($arg in @(
        '-B',
        (Join-Path $fixtureRepo 'dashboard/server.py'),
        '--repo-root', $fixtureRepo,
        '--port', '0',
        '--offline',
        '--home-root', $fakeHome,
        '--state-root', $fakeState
    )) {
        $startInfo.ArgumentList.Add($arg)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $serverProcess = [System.Diagnostics.Process]::Start($startInfo)
    $serverProcess.StandardInput.Close()
    $serverStdoutTask = $serverProcess.StandardOutput.ReadToEndAsync()
    $serverStderrTask = $serverProcess.StandardError.ReadToEndAsync()

    $serverJsonPath = Join-Path $fixtureRepo 'tmp/dashboard/server.json'
    $serverInfo = $null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if ($serverProcess.HasExited) {
            $outText = $serverStdoutTask.GetAwaiter().GetResult()
            $errText = $serverStderrTask.GetAwaiter().GetResult()
            throw "Dashboard server exited prematurely ($($serverProcess.ExitCode)): $outText`n$errText"
        }
        if (Test-Path -LiteralPath $serverJsonPath -PathType Leaf) {
            try {
                $candidate = Get-Content -Raw -LiteralPath $serverJsonPath | ConvertFrom-Json
                if ($candidate -and $candidate.port -and $candidate.url) {
                    $serverInfo = $candidate
                    break
                }
            }
            catch {
                # Retry while server finishes writing or initializing.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    Assert-TestCondition ($null -ne $serverInfo) 'isolated dashboard server writes tmp/dashboard/server.json'

    $baseUrl = ([string]$serverInfo.url).TrimEnd('/')
    $rootResponse = Invoke-WebRequest -Uri "$baseUrl/" -Method Get -TimeoutSec 5
    Assert-TestCondition ($rootResponse.StatusCode -eq 200 -and $rootResponse.Content -match 'ai-agent-dotfiles' -and (-not $rootResponse.Content.Contains('__DASHBOARD_TOKEN__'))) 'GET / returns HTML with injected session token'

    $health = Invoke-RestMethod -Uri "$baseUrl/api/health" -Method Get -TimeoutSec 5
    Assert-TestCondition ($health.ok -eq $true -and [int]$health.port -eq [int]$serverInfo.port) 'GET /api/health returns ok and matching port'

    $overview = Invoke-RestMethod -Uri "$baseUrl/api/overview" -Method Get -TimeoutSec 5
    Assert-TestCondition ($null -ne $overview.repo -and $null -ne $overview.skills_catalog -and $null -ne $overview.attention) 'GET /api/overview returns repo, skills_catalog, and attention'

    $github = Invoke-RestMethod -Uri "$baseUrl/api/github" -Method Get -TimeoutSec 5
    Assert-TestCondition ($github.offline -eq $true -and $github.available -eq $false) 'GET /api/github returns graceful offline payload under --offline'

    $postNoToken = Invoke-WebRequest -Uri "$baseUrl/api/actions/run" -Method Post -ContentType 'application/json' -Body '{"action":"doctor"}' -SkipHttpErrorCheck -TimeoutSec 5
    Assert-TestCondition ($postNoToken.StatusCode -eq 403) 'POST /api/actions/run without X-Dashboard-Token is rejected with HTTP 403'

    $reuseRes = Invoke-TestProcess -ScriptPath $dashboardScript -Arguments @('-RepoRoot', $fixtureRepo, '-NoBrowser', '-Offline', '-HomeRoot', $fakeHome, '-StateRoot', $fakeState)
    Assert-TestCondition ($reuseRes.Code -eq 0) 'scripts/dashboard.ps1 --reuse exits 0 against running server'
    $reuseJson = $null
    try { $reuseJson = $reuseRes.Out | ConvertFrom-Json } catch { $reuseJson = $null }
    Assert-TestCondition ($null -ne $reuseJson -and $reuseJson.reused -eq $true -and [int]$reuseJson.port -eq [int]$serverInfo.port) 'scripts/dashboard.ps1 reuses healthy running server for the same repo_root'

    Write-Host 'dashboard tests: PASS'
}
finally {
    if ($null -ne $serverProcess) {
        try {
            if (-not $serverProcess.HasExited) {
                $serverProcess.Kill($true)
                $null = $serverProcess.WaitForExit(5000)
            }
        }
        catch {
            # Best-effort cleanup of test server process.
        }
        finally {
            $serverProcess.Dispose()
        }
    }
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
