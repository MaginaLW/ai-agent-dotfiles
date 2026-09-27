#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$checkScript = Join-Path $RepoRoot 'scripts/check-guide-examples.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$fixtureRoots = [System.Collections.Generic.List[string]]::new()
$fixtureOutputs = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw $Message }
    Write-Host "  PASS  $Message"
}

function New-FixtureRepo {
    param([Parameter(Mandatory)] [hashtable] $Files)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-guide-examples-$([Guid]::NewGuid().ToString('N'))"
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    foreach ($relative in @($Files.Keys)) {
        $full = [System.IO.Path]::GetFullPath((Join-Path $root ([string]$relative)))
        $parent = [System.IO.Path]::GetDirectoryName($full)
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        [System.IO.File]::WriteAllText($full, [string]$Files[$relative], $utf8)
    }
    return (Resolve-Path -LiteralPath $root).Path
}

function Invoke-GuideCheck {
    param([Parameter(Mandatory)] [string] $TargetRoot, [string[]] $Guides)
    $pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
    $outputPath = Join-Path ([System.IO.Path]::GetTempPath()) "guide-examples-check-$([Guid]::NewGuid().ToString('N')).json"
    $fixtureOutputs.Add($outputPath)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $TargetRoot
    $arguments = @('-NoProfile', '-File', $checkScript, '-RepoRoot', $TargetRoot, '-OutputPath', $outputPath)
    if ($Guides) {
        # pwsh -File drops extra tokens after a [string[]] parameter, so the suite
        # passes the guide list as the one comma-separated token the checker documents.
        $arguments += @('-Guides', (@($Guides) -join ','))
    }
    foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Unable to start the guide-check child process.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            try { $process.Kill($true) } catch { }
            $null = $process.WaitForExit(5000)
            throw 'guide-check child process exceeded 120 seconds.'
        }
        $json = $null
        if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
            $json = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = [string]$stdoutTask.GetAwaiter().GetResult() + [string]$stderrTask.GetAwaiter().GetResult()
            Json = $json
        }
    }
    finally { $process.Dispose() }
}

try {
    Write-Host '[valid guide: parameter check, placeholder normalization, bare-name resolution]'
    $validRoot = New-FixtureRepo -Files @{
        'GUIDE.md' = @(
            '```powershell'
            "pwsh -NoProfile -File scripts/target.ps1 -Value '<plan>'"
            '```'
            '```powershell'
            'helper.ps1 -Name x'
            '```'
        ) -join "`n"
        'scripts/target.ps1' = 'param([string] $Value)' + "`n"
        'tests/helpers/helper.ps1' = 'param([string] $Name)' + "`n"
    }
    $valid = Invoke-GuideCheck -TargetRoot $validRoot -Guides @('GUIDE.md')
    Assert-True ($valid.ExitCode -eq 0) "valid guide exits 0 (got $($valid.ExitCode))"
    Assert-True ($null -ne $valid.Json -and $valid.Json.Result -eq 'PASS') 'valid guide summary is PASS'
    Assert-True ($valid.Json.Totals.Blocks -eq 2) "valid guide counts 2 blocks (got $($valid.Json.Totals.Blocks))"
    Assert-True ($valid.Json.Totals.Invocations -eq 2) "valid guide counts 2 script invocations (got $($valid.Json.Totals.Invocations))"
    Assert-True ($valid.Json.Totals.Placeholders -eq 1) "placeholder span is counted (got $($valid.Json.Totals.Placeholders))"
    Assert-True (@($valid.Json.Guides)[0].State -eq 'checked') 'present guide is reported checked'
    Assert-True ($valid.Json.Head -eq 'unavailable') 'non-git fixture reports Head unavailable instead of failing'

    Write-Host '[parse error in a fenced block]'
    $parseRoot = New-FixtureRepo -Files @{
        'GUIDE.md' = @('```powershell', 'if ( missing {', '```') -join "`n"
    }
    $parse = Invoke-GuideCheck -TargetRoot $parseRoot -Guides @('GUIDE.md')
    Assert-True ($parse.ExitCode -eq 1) "parse error exits 1 (got $($parse.ExitCode))"
    Assert-True ($parse.Output -match 'parse error') 'parse error is reported'
    Assert-True ($parse.Json.Result -eq 'FAIL') 'parse error summary is FAIL'

    Write-Host '[reference to a script that does not exist]'
    $missingScriptRoot = New-FixtureRepo -Files @{
        'GUIDE.md' = @('```powershell', 'pwsh -NoProfile -File scripts/absent.ps1', '```') -join "`n"
    }
    $missingScript = Invoke-GuideCheck -TargetRoot $missingScriptRoot -Guides @('GUIDE.md')
    Assert-True ($missingScript.ExitCode -eq 1) "missing script reference exits 1 (got $($missingScript.ExitCode))"
    Assert-True ($missingScript.Output -match 'referenced script not found: scripts/absent\.ps1') 'missing script reference is reported with the token'

    Write-Host '[parameter the target does not declare]'
    $unknownParamRoot = New-FixtureRepo -Files @{
        'GUIDE.md' = @('```powershell', 'pwsh -NoProfile -File scripts/real.ps1 -Unknown 1', '```') -join "`n"
        'scripts/real.ps1' = 'param([string] $Known)' + "`n"
    }
    $unknownParam = Invoke-GuideCheck -TargetRoot $unknownParamRoot -Guides @('GUIDE.md')
    Assert-True ($unknownParam.ExitCode -eq 1) "undeclared parameter exits 1 (got $($unknownParam.ExitCode))"
    Assert-True ($unknownParam.Output -match 'real\.ps1 has no parameter -Unknown') 'undeclared parameter is reported against the target'

    Write-Host '[target script that does not parse]'
    $brokenTargetRoot = New-FixtureRepo -Files @{
        'GUIDE.md' = @('```powershell', 'pwsh -NoProfile -File scripts/broken.ps1 -Value 1', '```') -join "`n"
        'scripts/broken.ps1' = 'param(' + "`n"
    }
    $brokenTarget = Invoke-GuideCheck -TargetRoot $brokenTargetRoot -Guides @('GUIDE.md')
    Assert-True ($brokenTarget.ExitCode -eq 1) "unparseable target exits 1 (got $($brokenTarget.ExitCode))"
    Assert-True ($brokenTarget.Output -match 'target script does not parse') 'unparseable target is reported'

    Write-Host '[dispatcher invocation is counted, not parameter-validated]'
    $dispatcherRoot = New-FixtureRepo -Files @{
        'GUIDE.md' = @('```powershell', 'pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env task status', '```') -join "`n"
        'scripts/agent-dotfiles.ps1' = 'param()' + "`n"
    }
    $dispatcher = Invoke-GuideCheck -TargetRoot $dispatcherRoot -Guides @('GUIDE.md')
    Assert-True ($dispatcher.ExitCode -eq 0) "dispatcher invocation exits 0 (got $($dispatcher.ExitCode))"
    Assert-True ($dispatcher.Json.Totals.Invocations -eq 1) 'dispatcher invocation is counted as an invocation'
    Assert-True ($dispatcher.Json.Totals.DispatcherInvocations -eq 1) 'dispatcher invocation is counted in DispatcherInvocations'
    Assert-True ($dispatcher.Json.Totals.Errors -eq 0) 'dispatcher parameters are not validated against the dispatcher surface'

    Write-Host '[target without a param block declares zero parameters]'
    $noParamsRoot = New-FixtureRepo -Files @{
        'GUIDE.md' = @('```powershell', 'pwsh -NoProfile -File scripts/noparams.ps1', '```') -join "`n"
        'scripts/noparams.ps1' = 'Write-Host hi' + "`n"
    }
    $noParams = Invoke-GuideCheck -TargetRoot $noParamsRoot -Guides @('GUIDE.md')
    Assert-True ($noParams.ExitCode -eq 0) "param-block-less target exits 0 (got $($noParams.ExitCode))"
    Assert-True ($noParams.Json.Totals.Errors -eq 0) 'param-block-less target is not misread as a parse failure'
    Assert-True ($noParams.Json.Totals.Invocations -eq 1) 'param-block-less target still counts as an invocation'

    Write-Host '[absent guide row is reported missing without failing]'
    $absentGuideRoot = New-FixtureRepo -Files @{
        'GUIDE.md' = @('```powershell', 'pwsh -NoProfile -File scripts/target.ps1', '```') -join "`n"
        'scripts/target.ps1' = 'param()' + "`n"
    }
    $absentGuide = Invoke-GuideCheck -TargetRoot $absentGuideRoot -Guides @('GUIDE.md', 'ABSENT.md')
    Assert-True ($absentGuide.ExitCode -eq 0) "absent guide keeps exit 0 (got $($absentGuide.ExitCode))"
    $absentRows = @($absentGuide.Json.Guides)
    Assert-True ($absentRows.Count -eq 2) "both requested guides get a row (got $($absentRows.Count))"
    Assert-True (($absentRows | Where-Object { $_.Guide -eq 'ABSENT.md' }).State -eq 'missing') 'absent guide row is reported missing'
    Assert-True (($absentRows | Where-Object { $_.Guide -eq 'GUIDE.md' }).State -eq 'checked') 'present guide in a mixed request is checked'

    Write-Host '[repository as-is]'
    $repoRun = Invoke-GuideCheck -TargetRoot $RepoRoot
    Assert-True ($repoRun.ExitCode -eq 0) "worktree guide check exits 0 (got $($repoRun.ExitCode))"
    Assert-True ($repoRun.Json.Result -eq 'PASS') 'worktree guide check summary is PASS'
    Assert-True ($repoRun.Json.ArtifactKind -eq 'guide-example-static-check') 'summary carries the artifact kind'
    Assert-True ($repoRun.Json.Head -match '^[0-9a-f]{40,64}$') 'worktree summary pins the git head'
    $repoRows = @($repoRun.Json.Guides)
    Assert-True ($repoRows.Count -eq 7) "all seven default guides are checked (got $($repoRows.Count))"
    Assert-True (@($repoRows | Where-Object { $_.State -eq 'checked' }).Count -eq $repoRows.Count) 'no default guide row is missing'
    Assert-True (@($repoRows | Where-Object { [int]$_.Blocks -gt 0 }).Count -eq $repoRows.Count) 'every default guide has PowerShell blocks'
    Assert-True ($repoRun.Json.Totals.Errors -eq 0) "worktree summary totals zero errors (got $($repoRun.Json.Totals.Errors))"
    $repoErrorRows = @($repoRows | Where-Object { @($_.Errors).Count -gt 0 })
    Assert-True ($repoErrorRows.Count -eq 0) "no default guide has errors (got $($repoErrorRows.Count) rows)"

    Write-Host 'guide examples tests: PASS'
}
finally {
    foreach ($root in @($fixtureRoots)) {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    foreach ($output in @($fixtureOutputs)) {
        if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
    }
}
