#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-doctor-$([Guid]::NewGuid().ToString('N'))"
$fakeHome = Join-Path $work 'home'
$systemRoot = Join-Path $fakeHome '.codex/skills/.system'
$jsonPath = Join-Path $work 'doctor.json'
[System.IO.Directory]::CreateDirectory($systemRoot) | Out-Null
$child = Join-Path $systemRoot '.codex-system-skills.marker'
[System.IO.File]::WriteAllText($child, 'do-not-open', [System.Text.UTF8Encoding]::new($false))
$beforeHash = (Get-FileHash -LiteralPath $child -Algorithm SHA256).Hash

try {
    $lock = [System.IO.File]::Open($child,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::None)
    try { $output = & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts/doctor.ps1') -RepoRoot $RepoRoot -HomeRoot $fakeHome -SkipSecretsScan -JsonPath $jsonPath 2>&1 | Out-String; $code=$LASTEXITCODE }
    finally { $lock.Dispose() }
    if ($code -ne 0) { throw "doctor failed: $output" }
    if ($output -notmatch 'root entry detected with no content traversal') { throw 'doctor did not report the no-follow .system root marker' }
    if ($output -match 'platform marker is missing|marker is present') { throw 'doctor still inspected a .system child marker' }
    if ((Get-FileHash -LiteralPath $child -Algorithm SHA256).Hash -ne $beforeHash) { throw 'doctor changed the protected .system child' }
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { throw 'doctor JSON summary was not written' }
    $report = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
    if ([int]$report.SchemaVersion -ne 1 -or $report.Result -notin @('PASS','WARN','FAIL')) { throw 'doctor JSON summary shape is invalid' }
    if ($report.Counts.Fail -ne 0 -or -not $report.SecretsScanSkipped) { throw 'doctor JSON summary has unexpected gate state' }
    if ($output -notmatch 'safety-protocol-upgrade-required' -or $output -notmatch 'runner-review-required|Approved runner hash') { throw 'doctor omitted safety/runner diagnostics' }

    $reparseHome = Join-Path $work 'reparse-home'
    $outside = Join-Path $work 'outside-system'
    [System.IO.Directory]::CreateDirectory((Join-Path $reparseHome '.codex/skills')) | Out-Null
    [System.IO.Directory]::CreateDirectory($outside) | Out-Null
    $outsideChild = Join-Path $outside 'sentinel.txt'; [System.IO.File]::WriteAllText($outsideChild,'outside',[System.Text.UTF8Encoding]::new($false))
    $outsideBefore = (Get-FileHash -LiteralPath $outsideChild -Algorithm SHA256).Hash
    New-Item -ItemType Junction -Path (Join-Path $reparseHome '.codex/skills/.system') -Target $outside | Out-Null
    $outsideLock = [System.IO.File]::Open($outsideChild,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::None)
    try { $reparseOutput = & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts/doctor.ps1') -RepoRoot $RepoRoot -HomeRoot $reparseHome -SkipSecretsScan 2>&1 | Out-String; $reparseCode=$LASTEXITCODE }
    finally { $outsideLock.Dispose() }
    if ($reparseCode -ne 0 -or $reparseOutput -notmatch 'root entry is a reparse point') { throw 'doctor did not classify a .system reparse root without traversal' }
    if ((Get-FileHash -LiteralPath $outsideChild -Algorithm SHA256).Hash -ne $outsideBefore) { throw 'outside sentinel changed' }

    $currentGuides = @('AGENTS.md','CLAUDE.md','README.md','docs/README.md','docs/ONBOARD_NEW_MACHINE.md','docs/RESTORE.md','docs/MERGE_POLICY.md','STATUS.md')
    foreach ($relative in $currentGuides) {
        $text = [System.IO.File]::ReadAllText((Join-Path $RepoRoot $relative))
        if ($text -notmatch 'Reasonix') { throw "current guide omits Reasonix managed scope: $relative" }
        if ($text -match '(?is)hook.{0,80}(sync\.ps1\s+-Apply|automatic.{0,20}Apply)|bootstrap.{0,80}(immediate|default).{0,30}(live sync|Apply)') { throw "current guide advertises automatic live Apply: $relative" }
        foreach ($line in @($text -split "`r?`n" | Where-Object { $_ -match 'SkipInitialSync' })) {
            if ($line -notmatch '(alias|deprecated|弃用|警告别名)') { throw "deprecated SkipInitialSync is not described only as an alias: $relative" }
        }
    }
    Write-Host 'doctor tests: PASS'
}
finally { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } }
