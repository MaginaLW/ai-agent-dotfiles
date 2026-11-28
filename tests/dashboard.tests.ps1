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
    Write-Host 'dashboard: python unit tests'
    $pythonCommands = @(Get-Command python -CommandType Application -ErrorAction Stop)
    $pythonPath = $pythonCommands[0].Source
    Push-Location -LiteralPath $RepoRoot
    try {
        & $pythonPath -B -m unittest tests/dashboard_server_test.py -v
        Assert-TestCondition ($LASTEXITCODE -eq 0) 'tests/dashboard_server_test.py passes under unittest'
    }
    finally {
        Pop-Location
    }

    Write-Host 'dashboard: entry scripts and launcher'
    $cmdPath = Join-Path $RepoRoot 'start-dashboard.cmd'
    Assert-TestCondition (Test-Path -LiteralPath $cmdPath -PathType Leaf) 'start-dashboard.cmd exists at repository root'
    $cmdBytes = [IO.File]::ReadAllBytes($cmdPath)
    $nonAsciiBytes = @($cmdBytes | Where-Object { $_ -gt 127 })
    Assert-TestCondition ($nonAsciiBytes.Count -eq 0) 'start-dashboard.cmd contains pure ASCII bytes'
    $cmdText = [Text.Encoding]::ASCII.GetString($cmdBytes)
    Assert-TestCondition ($cmdText.Contains("`r`n") -and (-not ($cmdText -replace "`r`n", '').Contains("`n"))) 'start-dashboard.cmd uses CRLF line endings'
    Assert-TestCondition ($cmdText.Contains('scripts\dashboard.ps1') -and $cmdText.Contains('where pwsh')) 'start-dashboard.cmd checks pwsh and invokes scripts\dashboard.ps1'

    $cmdInfo = [System.Diagnostics.ProcessStartInfo]::new('cmd.exe')
    foreach ($arg in @('/d', '/c', $cmdPath, '-Check', '-RepoRoot', $RepoRoot)) { $cmdInfo.ArgumentList.Add($arg) }
    $cmdInfo.WorkingDirectory = $RepoRoot
    $cmdInfo.Environment['DASHBOARD_NO_PAUSE'] = '1'
    $cmdInfo.UseShellExecute = $false
    $cmdInfo.RedirectStandardInput = $true
    $cmdInfo.RedirectStandardOutput = $true
    $cmdInfo.RedirectStandardError = $true
    $cmdProc = [System.Diagnostics.Process]::Start($cmdInfo)
    $cmdProc.StandardInput.Close()
    $cmdOutTask = $cmdProc.StandardOutput.ReadToEndAsync()
    $cmdErrTask = $cmdProc.StandardError.ReadToEndAsync()
    $cmdExited = $cmdProc.WaitForExit(15000)
    if (-not $cmdExited) {
        $cmdProc.Kill($true)
        $cmdProc.WaitForExit(2000) | Out-Null
    }
    $cmdOut = $cmdOutTask.GetAwaiter().GetResult()
    $cmdErr = $cmdErrTask.GetAwaiter().GetResult()
    $cmdCheckJson = $null
    try { $cmdCheckJson = $cmdOut | ConvertFrom-Json } catch { $cmdCheckJson = $null }
    Assert-TestCondition ($cmdExited -and $cmdProc.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($cmdErr) -and $null -ne $cmdCheckJson -and $cmdCheckJson.ok -eq $true) 'cmd.exe executes start-dashboard.cmd -Check cleanly with valid JSON'
    $cmdProc.Dispose()

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
    New-Item -ItemType Directory -Path $fixtureRepo, $fakeHome, $fakeState -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'dashboard') -Destination $fixtureRepo -Recurse -Force
    Get-ChildItem -LiteralPath (Join-Path $fixtureRepo 'dashboard') -Directory -Recurse -Filter '__pycache__' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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

    $cssResponse = Invoke-WebRequest -Uri "$baseUrl/static/app.css" -Method Get -TimeoutSec 5
    Assert-TestCondition ($cssResponse.StatusCode -eq 200 -and $cssResponse.Headers['Content-Type'] -match 'text/css' -and $cssResponse.Headers['X-Content-Type-Options'] -eq 'nosniff' -and $cssResponse.Headers['Cache-Control'] -eq 'no-store' -and $cssResponse.Content -match ':root') 'GET /static/app.css returns CSS with security headers'

    $jsResponse = Invoke-WebRequest -Uri "$baseUrl/static/app.js" -Method Get -TimeoutSec 5
    Assert-TestCondition ($jsResponse.StatusCode -eq 200 -and $jsResponse.Headers['Content-Type'] -match 'javascript' -and $jsResponse.Headers['X-Content-Type-Options'] -eq 'nosniff' -and $jsResponse.Headers['Cache-Control'] -eq 'no-store' -and $jsResponse.Content -match 'csrfToken') 'GET /static/app.js returns JS with security headers'

    $rawTraversalStatus = & $pythonPath -B -c "import http.client; c=http.client.HTTPConnection('127.0.0.1', $($serverInfo.port), timeout=5); c.request('GET', '/static/../server.py'); r=c.getresponse(); print(r.status); c.close()"
    Assert-TestCondition ($LASTEXITCODE -eq 0 -and ([string]$rawTraversalStatus).Trim() -eq '404') 'GET /static/../server.py is rejected with HTTP 404'

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
