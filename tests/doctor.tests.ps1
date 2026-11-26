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
    if ($output -notmatch 'Deploy blockers: 1' -or $output -notmatch 'Inspect both roots and decide' -or $output -notmatch 'Doctor result: PASS with warnings') { throw 'doctor did not distinguish a deployment blocker while preserving the warning/exit contract' }
    if ($output -match 'Zcode live root') { throw 'doctor still probed retired Zcode live root' }
    $coreScripts = @(
        'agent-dotfiles.ps1', 'antigravity-plugins.ps1', 'mcp-sync.ps1',
        'config-status.ps1', 'config-pull.ps1', 'config-push.ps1',
        'deploy.ps1', 'deploy-skills.ps1', 'build-skills.ps1', 'dashboard.ps1', 'scan-secrets.ps1'
    )
    foreach ($s in $coreScripts) {
        if ($output -notmatch [regex]::Escape("scripts\$s exists")) {
            throw "doctor did not check scripts/$s"
        }
    }
    foreach ($p in @('dashboard\server.py', 'dashboard\index.html')) {
        if ($output -notmatch [regex]::Escape("$p exists")) {
            throw "doctor did not check $p"
        }
    }
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

    $retiredHome = Join-Path $work 'retired-home'
    [System.IO.Directory]::CreateDirectory((Join-Path $retiredHome '.zcode/skills')) | Out-Null
    $retiredOutput = & pwsh -NoProfile -File $doctor -RepoRoot $RepoRoot -HomeRoot $retiredHome -SkipSecretsScan 2>&1 | Out-String; $retiredCode=$LASTEXITCODE
    if ($retiredOutput -match 'Claude live root|Zcode live root') { throw 'doctor probed a retired platform' }
    if ($retiredCode -ne 0) { throw "doctor failed on retired home: $retiredOutput" }
    if ($retiredOutput -notmatch 'Deploy blockers: none detected by these checks' -or $retiredOutput -match 'deployment cannot proceed') { throw 'ordinary warnings were incorrectly reported as deployment blockers' }

    $cleanRepo = Join-Path $work 'clean-repo'
    New-Item -ItemType Directory -Path $cleanRepo -Force | Out-Null
    & git -C $cleanRepo init -q
    & git -C $cleanRepo config user.email "test@example.com"
    & git -C $cleanRepo config user.name "Test"

    foreach ($dir in 'docs', 'scripts', 'skills-source', 'status/active', 'tools/gitleaks', 'dashboard') {
        New-Item -ItemType Directory -Path (Join-Path $cleanRepo $dir) -Force | Out-Null
    }
    foreach ($file in 'AGENTS.md', 'STATUS.md') {
        [System.IO.File]::WriteAllText((Join-Path $cleanRepo $file), "# $file`n", [System.Text.UTF8Encoding]::new($false))
    }
    [System.IO.File]::WriteAllText((Join-Path $cleanRepo 'dashboard/server.py'), "# stub`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $cleanRepo 'dashboard/index.html'), "<!doctype html>`n", [System.Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $doctor -Destination (Join-Path $cleanRepo 'scripts/doctor.ps1')
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/repo-common.ps1') -Destination (Join-Path $cleanRepo 'scripts/repo-common.ps1')

    $dummyScripts = @(
        'agent-dotfiles.ps1', 'antigravity-plugins.ps1', 'mcp-sync.ps1',
        'config-status.ps1', 'config-pull.ps1', 'config-push.ps1',
        'deploy.ps1', 'deploy-skills.ps1', 'build-skills.ps1', 'dashboard.ps1'
    )
    foreach ($s in $dummyScripts) {
        [System.IO.File]::WriteAllText((Join-Path $cleanRepo "scripts/$s"), "# $s`n", [System.Text.UTF8Encoding]::new($false))
    }
    [System.IO.File]::WriteAllText((Join-Path $cleanRepo 'scripts/scan-secrets.ps1'), "exit 0`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $cleanRepo 'scripts/pinned-tool.ps1'), "function Get-PinnedToolExecutable { [pscustomobject]@{ Lock = [pscustomobject]@{ Version = '1.0' } } }`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $cleanRepo 'tools/gitleaks/gitleaks.lock.json'), "{}`n", [System.Text.UTF8Encoding]::new($false))

    & git -C $cleanRepo config core.autocrlf false
    & git -C $cleanRepo add .
    & git -C $cleanRepo commit -q -m "initial commit"

    $cleanHome = Join-Path $work 'clean-home'
    New-Item -ItemType Directory -Path (Join-Path $cleanHome '.codex/skills') -Force | Out-Null

    $cleanOutput = & pwsh -NoProfile -File (Join-Path $cleanRepo 'scripts/doctor.ps1') -RepoRoot $cleanRepo -HomeRoot $cleanHome 2>&1 | Out-String; $cleanCode=$LASTEXITCODE
    if ($cleanCode -ne 0) { throw "clean fixture doctor failed with exit code $($cleanCode): $cleanOutput" }
    if ($cleanOutput -notmatch 'Doctor result: PASS\r?\n?$') { throw "clean fixture did not report Doctor result: PASS: $cleanOutput" }
    if ($cleanOutput -match 'Doctor result: PASS with warnings') { throw "clean fixture unexpectedly reported warnings: $cleanOutput" }
    if ($cleanOutput -notmatch 'WARN=0') { throw "clean fixture had WARN count > 0: $cleanOutput" }

    Remove-Item -LiteralPath (Join-Path $cleanRepo 'scripts/mcp-sync.ps1') -Force
    $missingOutput = & pwsh -NoProfile -File (Join-Path $cleanRepo 'scripts/doctor.ps1') -RepoRoot $cleanRepo -HomeRoot $cleanHome -SkipSecretsScan 2>&1 | Out-String; $missingCode=$LASTEXITCODE
    if ($missingCode -ne 1) { throw "missing script did not exit 1 (got $($missingCode)): $missingOutput" }
    if ($missingOutput -notmatch '\[FAIL\] scripts\\mcp-sync\.ps1 is missing\.') { throw "missing script FAIL line missing: $missingOutput" }
    if ($missingOutput -notmatch 'Doctor result: FAIL') { throw "missing script did not report Doctor result: FAIL: $missingOutput" }

    Write-Host 'doctor tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
