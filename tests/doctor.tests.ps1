#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$doctor = Join-Path $RepoRoot 'scripts/doctor.ps1'

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-doctor-$([Guid]::NewGuid().ToString('N'))"
$fakeHome = Join-Path $work 'home'
$systemRoot = Join-Path $fakeHome '.codex/skills/.system'
[System.IO.Directory]::CreateDirectory($systemRoot) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $fakeHome '.agents/skills')) | Out-Null
$child = Join-Path $systemRoot '.codex-system-skills.marker'
[System.IO.File]::WriteAllText($child, 'do-not-open', [System.Text.UTF8Encoding]::new($false))
$beforeHash = (Get-FileHash -LiteralPath $child -Algorithm SHA256).Hash

try {
    # An exclusive lock on the .system child makes any attempt to open it fail the run.
    $lock = [System.IO.File]::Open($child,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::None)
    try { $output = & pwsh -NoProfile -File $doctor -RepoRoot $RepoRoot -HomeRoot $fakeHome -SkipSecretsScan 2>&1 | Out-String; $code=$LASTEXITCODE }
    finally { $lock.Dispose() }
    if ($code -ne 0) { throw "doctor failed: $output" }
    if ($output -notmatch 'root entry detected with no content traversal') { throw 'doctor did not report the no-follow .system root marker' }
    if ((Get-FileHash -LiteralPath $child -Algorithm SHA256).Hash -ne $beforeHash) { throw 'doctor changed the protected .system child' }
    if ($output -notmatch 'Codex live root is ambiguous') { throw 'doctor did not flag both Codex roots as ambiguous' }
    if ($output -notmatch 'scripts\\deploy-skills\.ps1 exists') { throw 'doctor did not check scripts/deploy-skills.ps1' }
    if ($output -notmatch 'Secrets scan skipped') { throw 'doctor did not record the skipped secret scan' }
    if ($output -match 'status\\archived|Live safety protocol|runner-review-required|Approved runner hash') { throw 'doctor still reports retired engine diagnostics' }

    $reparseHome = Join-Path $work 'reparse-home'
    $outside = Join-Path $work 'outside-system'
    [System.IO.Directory]::CreateDirectory((Join-Path $reparseHome '.codex/skills')) | Out-Null
    [System.IO.Directory]::CreateDirectory($outside) | Out-Null
    $outsideChild = Join-Path $outside 'sentinel.txt'; [System.IO.File]::WriteAllText($outsideChild,'outside',[System.Text.UTF8Encoding]::new($false))
    $outsideBefore = (Get-FileHash -LiteralPath $outsideChild -Algorithm SHA256).Hash
    New-Item -ItemType Junction -Path (Join-Path $reparseHome '.codex/skills/.system') -Target $outside | Out-Null
    $outsideLock = [System.IO.File]::Open($outsideChild,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::None)
    try { $reparseOutput = & pwsh -NoProfile -File $doctor -RepoRoot $RepoRoot -HomeRoot $reparseHome -SkipSecretsScan 2>&1 | Out-String; $reparseCode=$LASTEXITCODE }
    finally { $outsideLock.Dispose() }
    if ($reparseCode -ne 0 -or $reparseOutput -notmatch 'root entry is a reparse point') { throw 'doctor did not classify a .system reparse root without traversal' }
    if ($reparseOutput -notmatch 'Codex live root: ~/\.codex/skills\.') { throw 'doctor did not report the preferred Codex root' }
    if ((Get-FileHash -LiteralPath $outsideChild -Algorithm SHA256).Hash -ne $outsideBefore) { throw 'outside sentinel changed' }

    Write-Host 'doctor tests: PASS'
}
finally { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } }
