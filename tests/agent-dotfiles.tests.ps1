#requires -Version 7.0
<#!
.SYNOPSIS
    Smoke tests for the unified agent-dotfiles dispatcher.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entry = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('agent-dotfiles-cli-tests-' + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
# Fixture repo for the deploy routes: environments that select no skills, so a
# dry run needs no generated output and never touches a real home.
$fixtureRepo = Join-Path $work 'repo'
New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'harness-source/envs') -Force | Out-Null
foreach ($envName in @('work', 'test')) {
    Set-Content -LiteralPath (Join-Path $fixtureRepo "harness-source/envs/$envName.psd1") -Encoding utf8 -Value "@{ Name = '$envName'; Description = 'fixture'; Skills = @{ Claude = @(); Codex = @(); Reasonix = @() } }"
}
$deployArgs = @('-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', (Join-Path $work 'state'), '-SkipBuild')

$pass = 0
$fail = 0
function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Message" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}
function Invoke-Entry {
    param([string[]] $Arguments)
    $out = & pwsh -NoProfile -File $entry @Arguments 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

Write-Host 'unified CLI: env and config/profile routing'
$result = Invoke-Entry -Arguments @('env', 'list', '-RepoRoot', $RepoRoot)
Assert ($result.Code -eq 0 -and $result.Out -match 'Harness environments') 'env list routes through the dispatcher'
$listJsonPath = Join-Path $fakeHome 'env-list.json'
$result = Invoke-Entry -Arguments @('env', 'list', '-RepoRoot', $RepoRoot, '-JsonPath', $listJsonPath)
$listJson = $null
try { $listJson = Get-Content -Raw -LiteralPath $listJsonPath | ConvertFrom-Json } catch { $listJson = $null }
Assert ($result.Code -eq 0 -and $null -ne $listJson -and $listJson.PSObject.Properties.Name -contains 'Environments') 'env list writes machine-readable JSON'

$result = Invoke-Entry -Arguments @('config', 'status', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome, '-Json')
$configJson = $null
try { $configJson = $result.Out | ConvertFrom-Json } catch { $configJson = $null }
Assert ($result.Code -eq 0 -and $null -ne $configJson) 'config status JSON is not polluted by dispatcher text'
Assert ($result.Out -notmatch 'Invoking script|Command result') 'JSON stdout excludes dispatcher banners'

$result = Invoke-Entry -Arguments @('profile', 'status', '-RepoRoot', $RepoRoot, '-ProjectRoot', $RepoRoot, '-Json')
$profileJson = $null
try { $profileJson = $result.Out | ConvertFrom-Json } catch { $profileJson = $null }
Assert ($result.Code -eq 0 -and $null -ne $profileJson) 'profile status routes and emits JSON'

$result = Invoke-Entry -Arguments @('config', 'pull', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome, '-DryRun')
Assert ($result.Code -eq 0) 'config pull routes through the explicit dry-run gate'

Write-Host 'unified CLI: deploy routes'
$result = Invoke-Entry -Arguments (@('sync', '-DryRun') + $deployArgs)
Assert ($result.Code -eq 0 -and $result.Out -match "Dry run for environment 'work'" -and $result.Out -match 'deploy-skills\.ps1') 'sync -DryRun routes to deploy-skills with the -DryRun spelling consumed'
$result = Invoke-Entry -Arguments (@('env', 'deploy', 'test', '-DryRun') + $deployArgs)
Assert ($result.Code -eq 0 -and $result.Out -match "Dry run for environment 'test'") 'env deploy <name> -DryRun routes to deploy-skills -Environment <name>'
$result = Invoke-Entry -Arguments @('env', 'deploy', '-DryRun')
Assert ($result.Code -eq 1 -and $result.Out -match 'requires an environment name') 'env deploy without a name fails with guidance'
Assert (-not (Test-Path -LiteralPath (Join-Path $work 'state'))) 'deploy dry runs write no state'
foreach ($removed in @(@('env', 'activate', 'work'), @('env', 'status'), @('canonical', 'status'), @('live', 'recover'), @('backup'), @('plans'))) {
    $result = Invoke-Entry -Arguments $removed
    Assert ($result.Code -eq 1 -and $result.Out -match 'Unsupported') "removed route is rejected: $($removed -join ' ')"
}

Write-Host 'unified CLI: apply gates'
foreach ($commandArgs in @(
    @('config', 'pull', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome),
    @('config', 'push', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome),
    @('profile', 'apply', '-RepoRoot', $RepoRoot, '-ProjectRoot', $RepoRoot),
    @('sync'),
    @('env', 'deploy', 'work')
)) {
    $result = Invoke-Entry -Arguments $commandArgs
    Assert ($result.Code -eq 1 -and $result.Out -match 'explicit -DryRun or -Apply') "rejects implicit apply: $($commandArgs -join ' ')"
}
$result = Invoke-Entry -Arguments @('sync', '-DryRun', '-Apply')
Assert ($result.Code -eq 1 -and $result.Out -match 'only one mode') 'sync rejects both modes'

foreach ($commandArgs in @(
    @('skills', 'normalize'),
    @('skills', 'promote'),
    @('skills', 'merge'),
    @('merge')
)) {
    $result = Invoke-Entry -Arguments $commandArgs
    Assert ($result.Code -eq 1 -and $result.Out -match 'explicit -DryRun or -Apply') "rejects implicit skill mutation: $($commandArgs -join ' ')"
}

$dispatcherText = Get-Content -Raw -LiteralPath $entry
$mergeAdapterCount = ([regex]::Matches($dispatcherText, "merge\s*=\s*'auto-merge-skills\.ps1'")).Count
Assert ($mergeAdapterCount -eq 2) 'top-level merge and skills merge aliases route to the same fixed merge adapter'

Write-Host ''
Write-Host ("agent-dotfiles CLI tests: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
exit 0
