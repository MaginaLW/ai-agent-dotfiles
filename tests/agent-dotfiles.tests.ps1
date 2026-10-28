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
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

$entry = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('agent-dotfiles-cli-tests-' + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
# Fixture repo for the deploy routes: environments that select no skills, so a
# dry run needs no generated output and never touches a real home.
$fixtureRepo = Join-Path $work 'repo'
New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'harness-source/envs') -Force | Out-Null
foreach ($envName in @('work', 'test')) {
    Set-Content -LiteralPath (Join-Path $fixtureRepo "harness-source/envs/$envName.psd1") -Encoding utf8 -Value "@{ Name = '$envName'; Description = 'fixture'; Skills = @{ Claude = @(); Codex = @(); Zcode = @() } }"
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
    Invoke-TestProcess -ScriptPath $entry -Arguments $Arguments
}

Write-Host 'unified CLI: env and config/profile routing'
$result = Invoke-Entry -Arguments @('help')
Assert ($result.Code -eq 0 -and $result.Out -match 'Usage:' -and $result.Out -match 'Commands: help') 'help displays usage and exits successfully'
Assert ($result.Out -match 'sync, env deploy, config pull/push, profile apply, and skills promote require exactly one explicit mode' -and $result.Out -match 'build generates output; env list -JsonPath writes a report without a mode') 'help distinguishes mode-gated actions from other writes'
$result = Invoke-Entry -Arguments @()
Assert ($result.Code -eq 1 -and $result.Out -match 'A command is required') 'missing command remains an error'
$result = Invoke-Entry -Arguments @('env', 'list', '-RepoRoot', $RepoRoot, '-StateRoot', (Join-Path $work 'missing-state'))
Assert ($result.Code -eq 0 -and $result.Out -match 'Harness environments') 'env list routes through the dispatcher'
$listJsonPath = Join-Path $fakeHome 'env-list.json'
$result = Invoke-Entry -Arguments @('env', 'list', '-RepoRoot', $RepoRoot, '-StateRoot', (Join-Path $work 'missing-state'), '-JsonPath', $listJsonPath)
$listJson = $null
try { $listJson = Get-Content -Raw -LiteralPath $listJsonPath | ConvertFrom-Json } catch { $listJson = $null }
Assert ($result.Code -eq 0 -and $null -ne $listJson -and $listJson.PSObject.Properties.Name -contains 'Environments') 'env list writes machine-readable JSON'

Write-Host 'unified CLI: environment selections and recorded deployment'
$listRepo = Join-Path $work 'list-repo'
$listEnvDir = Join-Path $listRepo 'harness-source/envs'
$listState = Join-Path $work 'list-state'
New-Item -ItemType Directory -Path $listEnvDir, $listState -Force | Out-Null
Set-Content -LiteralPath (Join-Path $listEnvDir 'sample.psd1') -Encoding utf8 -Value "@{ Description = 'sample'; Skills = @{ Claude = @('alpha', 'beta'); Codex = @('gamma'); Zcode = @() } }"
$listArgs = @('env', 'list', '-RepoRoot', $listRepo, '-StateRoot', $listState)
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Code -eq 0 -and $result.Out -match 'Claude: 2 \[alpha, beta\]' -and $result.Out -match 'Codex: 1 \[gamma\]' -and $result.Out -match 'Zcode: 0 \[\(none\)\]') 'environment selections show platform names and counts'
Assert ($result.Out -match 'Last recorded successful Apply environment: unavailable \(record only; live contents may differ\)' -and -not (Test-Path (Join-Path $listState 'deployed-skills.json'))) 'missing deployment state is unavailable and not created'
$listStatePath = Join-Path $listState 'deployed-skills.json'
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{invalid'
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Code -eq 0 -and $result.Out -match 'environment: unavailable' -and $result.Out -match 'Claude: 2') 'malformed state leaves environment list available'
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{"Claude":[],"Codex":[],"Zcode":[]}'
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Code -eq 0 -and $result.Out -match 'environment: unavailable') 'state without an environment is unavailable'
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{"Environment":"sample","Claude":"alpha","Codex":[],"Zcode":[]}'
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Code -eq 0 -and $result.Out -match 'environment: unavailable') 'structurally invalid state is unavailable'
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{"Environment":"sample","Claude":["alpha"],"Codex":[],"Zcode":[]}'
$stateHash = (Get-FileHash -LiteralPath $listStatePath).Hash
$fixtureJsonPath = Join-Path $work 'fixture-environments.json'
$result = Invoke-Entry -Arguments ($listArgs + @('-JsonPath', $fixtureJsonPath))
$fixtureJson = Get-Content -Raw -LiteralPath $fixtureJsonPath | ConvertFrom-Json
$entryFields = @($fixtureJson.Environments[0].PSObject.Properties.Name | Sort-Object) -join ','
Assert ($result.Code -eq 0 -and $result.Out -match 'environment: sample \(record only; live contents may differ\)') 'valid state is identified as a record, not verified live contents'
Assert ($fixtureJson.Environments.Count -eq 1 -and $fixtureJson.Environments[0].Name -eq 'sample' -and $entryFields -eq 'Description,Name') 'environment report retains its existing JSON shape'
Assert ((Get-FileHash -LiteralPath $listStatePath).Hash -eq $stateHash -and @(Get-ChildItem -LiteralPath $fakeHome -Force).Count -eq 1) 'listing preserves deploy state and live fixture home'

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

$result = Invoke-Entry -Arguments @('skills', 'promote')
Assert ($result.Code -eq 1 -and $result.Out -match 'explicit -DryRun or -Apply') 'rejects implicit skill promotion'
foreach ($commandArgs in @(@('merge'), @('inventory'), @('analyze'), @('skills', 'merge'), @('skills', 'normalize'))) {
    $result = Invoke-Entry -Arguments $commandArgs
    Assert ($result.Code -eq 1 -and $result.Out -match 'Unsupported') "removed skills route is unsupported: $($commandArgs -join ' ')"
}

Write-Host ''
Write-Host ("agent-dotfiles CLI tests: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) {
    Write-Host "Workspace kept for inspection: $work" -ForegroundColor Yellow
    exit 1
}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
exit 0
