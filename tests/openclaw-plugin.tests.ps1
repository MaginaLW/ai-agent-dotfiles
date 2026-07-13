#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$scriptPath = Join-Path $RepoRoot 'scripts/sync-openclaw-plugins.ps1'
$work = Join-Path $RepoRoot 'tmp/openclaw-plugin-tests'

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $fakeRepo = Join-Path $work 'repo'
    $fakeHome = Join-Path $work 'home'
    Set-File -Path (Join-Path $fakeRepo 'openclaw/plugins/managed-plugins.json') -Content @'
{
  "version": 1,
  "plugins": [
    { "id": "managed-plugin", "source": "@example/managed", "enabled": true, "allowUninstall": true }
  ]
}
'@
    Set-File -Path (Join-Path $fakeHome '.openclaw/plugins/installs.json') -Content @'
{
  "plugins": [
    { "id": "unknown-plugin", "source": "@example/unknown", "enabled": true, "origin": "global" }
  ]
}
'@

    $output = & pwsh -NoProfile -File $scriptPath -RepoRoot $fakeRepo -HomeRoot $fakeHome -DryRun 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "plugin dry-run failed: $output" }
    if ($output -notmatch 'would install.*managed-plugin') { throw 'managed missing plugin was not planned for install' }
    if ($output -notmatch 'unknown plugins.*unknown-plugin') { throw 'unknown live plugin was not reported' }
    if ($output -match 'installs\.json.*modified|writing installs') { throw 'dry-run appears to mutate plugin state' }
    Write-Host 'openclaw plugin tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
