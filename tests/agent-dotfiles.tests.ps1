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
$fakeHome = Join-Path $RepoRoot 'tmp/agent-dotfiles-cli-tests-home'
if (Test-Path -LiteralPath $fakeHome) { Remove-Item -LiteralPath $fakeHome -Recurse -Force }
New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null

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

Write-Host 'unified CLI: apply gates'
foreach ($commandArgs in @(
    @('config', 'pull', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome),
    @('config', 'push', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome),
    @('profile', 'apply', '-RepoRoot', $RepoRoot, '-ProjectRoot', $RepoRoot),
    @('env', 'activate', 'work'),
    @('env', 'rollback', '-RunId', 'missing'),
    @('mcp', '-TemplateId', 'github')
)) {
    $result = Invoke-Entry -Arguments $commandArgs
    Assert ($result.Code -eq 1 -and $result.Out -match 'explicit -DryRun or -Apply') "rejects implicit apply: $($commandArgs[0]) $($commandArgs[1])"
}

Write-Host ''
Write-Host ("agent-dotfiles CLI tests: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
Remove-Item -LiteralPath $fakeHome -Recurse -Force -ErrorAction SilentlyContinue
exit 0
