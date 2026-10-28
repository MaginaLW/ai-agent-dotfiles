#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
$bash = Join-Path $gitRoot 'bin/bash.exe'
if (-not $node -or -not (Test-Path -LiteralPath $bash)) {
    Write-Host 'brainstorm helper tests: SKIP (Node.js and Git Bash are required)'
    exit 0
}
$env:BRAINSTORM_TEST_BASH = $bash
& $node.Source --test (Join-Path $RepoRoot 'tests/brainstorm-helper.test.cjs')
if ($LASTEXITCODE -ne 0) { throw "Brainstorm helper tests failed: $LASTEXITCODE" }
