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

    # Newer OpenClaw versions report an absolute install path from `plugins list`
    # while `plugins info` exposes the canonical package name. The canonical
    # package should prevent a false source-mismatch update plan.
    $canonicalCli = Join-Path $work 'canonical-openclaw.ps1'
    Set-File -Path $canonicalCli -Content @"
param([Parameter(ValueFromRemainingArguments = `$true)][string[]] `$CliArguments)
if (`$CliArguments -contains 'list') {
    @'
{"plugins":[{"id":"managed-plugin","source":"C:\\temp\\managed-plugin\\dist\\index.js","enabled":true,"origin":"global","version":"1.2.3"}]}
'@ | Write-Output
    exit 0
}
if (`$CliArguments -contains 'info') {
    @'
{"plugin":{"id":"managed-plugin","version":"1.2.3","source":"C:\\temp\\managed-plugin\\dist\\index.js","enabled":true},"install":{"source":"npm","spec":"@example/managed@1.2.3","installPath":"C:\\temp\\managed-plugin","version":"1.2.3","resolvedName":"@example/managed","resolvedVersion":"1.2.3"}}
'@ | Write-Output
    exit 0
}
throw 'unexpected fake OpenClaw command'
"@
    $canonicalHome = Join-Path $work 'canonical-home'
    New-Item -ItemType Directory -Force -Path $canonicalHome | Out-Null
    $canonicalOutput = & pwsh -NoProfile -File $scriptPath -RepoRoot $fakeRepo -HomeRoot $canonicalHome -OpenClawCommand $canonicalCli -CliProbeTimeoutSeconds 2 -DryRun 2>&1 | Out-String
    $canonicalCode = $LASTEXITCODE
    if ($canonicalCode -ne 0) { throw "canonical source probe dry-run failed: $canonicalOutput" }
    if ($canonicalOutput -match 'would update.*managed-plugin' -or $canonicalOutput -match 'would install.*managed-plugin') {
        throw "absolute list source was not canonicalized by plugins info: $canonicalOutput"
    }
    if ($canonicalOutput -notmatch 'no changes needed') { throw "canonical source probe did not converge: $canonicalOutput" }

    # A hung CLI probe must time out and fall back to the sanitized installs.json
    # path instead of blocking the whole dry-run indefinitely.
    $hungCli = Join-Path $work 'hung-openclaw.ps1'
    Set-File -Path $hungCli -Content @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $CliArguments)
while ($true) { Start-Sleep -Milliseconds 200 }
'@
    $installsPath = Join-Path $fakeHome '.openclaw/plugins/installs.json'
    $installsHash = (Get-FileHash -LiteralPath $installsPath -Algorithm SHA256).Hash
    $elapsed = Measure-Command {
        $timeoutOutput = & pwsh -NoProfile -File $scriptPath -RepoRoot $fakeRepo -HomeRoot $fakeHome -OpenClawCommand $hungCli -CliProbeTimeoutSeconds 2 -DryRun 2>&1 | Out-String
        $timeoutCode = $LASTEXITCODE
    }
    if ($timeoutCode -ne 0) { throw "hung CLI fallback dry-run failed: $timeoutOutput" }
    if ($timeoutOutput -notmatch '(?i)timed out') { throw "hung CLI probe did not report a timeout: $timeoutOutput" }
    if ($timeoutOutput -notmatch 'would install.*managed-plugin') { throw 'hung CLI probe did not fall back to installs.json' }
    if ($timeoutOutput -notmatch 'unknown plugins.*unknown-plugin') { throw 'hung CLI fallback did not preserve unknown live plugin evidence' }
    if ($elapsed.TotalSeconds -ge 8) { throw "hung CLI probe exceeded bounded runtime: $($elapsed.TotalSeconds) seconds" }
    if ((Get-FileHash -LiteralPath $installsPath -Algorithm SHA256).Hash -ne $installsHash) { throw 'hung CLI dry-run modified installs.json' }

    # Newer OpenClaw versions may keep plugin enablement in openclaw.json while
    # installs.json is absent. Use that sanitized config surface for dry-run.
    $configFallbackHome = Join-Path $work 'config-fallback-home'
    Copy-Item -LiteralPath $fakeHome -Destination $configFallbackHome -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $configFallbackHome '.openclaw/plugins/installs.json') -Force
    Set-File -Path (Join-Path $configFallbackHome '.openclaw/openclaw.json') -Content @'
{
  "plugins": {
    "entries": {
      "managed-plugin": { "enabled": false },
      "unknown-plugin": { "enabled": true }
    }
  }
}
'@
    $configOutput = & pwsh -NoProfile -File $scriptPath -RepoRoot $fakeRepo -HomeRoot $configFallbackHome -OpenClawCommand $hungCli -CliProbeTimeoutSeconds 1 -DryRun 2>&1 | Out-String
    $configCode = $LASTEXITCODE
    if ($configCode -ne 0) { throw "config fallback dry-run failed: $configOutput" }
    if ($configOutput -notmatch 'would enable.*managed-plugin') { throw "openclaw.json fallback did not preserve enablement drift: $configOutput" }
    if ($configOutput -notmatch 'unknown plugins.*unknown-plugin') { throw "openclaw.json fallback did not preserve unknown plugin evidence: $configOutput" }

    # A malformed installs.json must not be treated as an empty live state.
    # The sanitized config fallback may still provide enablement evidence.
    $malformedStateHome = Join-Path $work 'malformed-state-home'
    Copy-Item -LiteralPath $fakeHome -Destination $malformedStateHome -Recurse -Force
    Set-File -Path (Join-Path $malformedStateHome '.openclaw/plugins/installs.json') -Content '{ not-json'
    Set-File -Path (Join-Path $malformedStateHome '.openclaw/openclaw.json') -Content @'
{
  "plugins": {
    "entries": {
      "managed-plugin": { "enabled": false },
      "unknown-plugin": { "enabled": true }
    }
  }
}
'@
    $malformedOutput = & pwsh -NoProfile -File $scriptPath -RepoRoot $fakeRepo -HomeRoot $malformedStateHome -OpenClawCommand $hungCli -CliProbeTimeoutSeconds 1 -DryRun 2>&1 | Out-String
    $malformedCode = $LASTEXITCODE
    if ($malformedCode -ne 0) { throw "malformed installs fallback dry-run failed: $malformedOutput" }
    if ($malformedOutput -notmatch 'would enable.*managed-plugin' -or $malformedOutput -match 'would install.*managed-plugin') {
        throw "malformed installs.json was treated as empty live state: $malformedOutput"
    }

    # If both the CLI and the fallback state are unavailable, fail closed rather
    # than treating live state as empty and planning plugin installs.
    $missingStateHome = Join-Path $work 'missing-state-home'
    Copy-Item -LiteralPath $fakeHome -Destination $missingStateHome -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $missingStateHome '.openclaw/plugins/installs.json') -Force
    $missingOutput = & pwsh -NoProfile -File $scriptPath -RepoRoot $fakeRepo -HomeRoot $missingStateHome -OpenClawCommand $hungCli -CliProbeTimeoutSeconds 1 -DryRun 2>&1 | Out-String
    $missingCode = $LASTEXITCODE
    if ($missingCode -eq 0 -or $missingOutput -notmatch '(?i)live plugin state is unavailable') { throw "missing plugin state did not fail closed: $missingOutput" }
    Write-Host 'openclaw plugin tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
