#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$work = Join-Path $RepoRoot 'tmp/doctor-tests'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $jsonPath = Join-Path $work 'doctor.json'
    $output = & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts/doctor.ps1') -RepoRoot $RepoRoot -SkipSecretsScan -JsonPath $jsonPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "doctor failed: $output" }
    if ($output -match 'top-level generated') { throw 'doctor emitted the obsolete top-level generated warning' }
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { throw 'doctor JSON summary was not written' }
    $report = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
    if ([int]$report.SchemaVersion -ne 1 -or $report.Result -notin @('PASS','WARN','FAIL')) { throw 'doctor JSON summary shape is invalid' }
    if ($report.Counts.Fail -ne 0 -or -not $report.SecretsScanSkipped) { throw 'doctor JSON summary has unexpected gate state' }
    Write-Host 'doctor tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
