#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/safety-sandbox.ps1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-automation-safety-$([Guid]::NewGuid().ToString('N'))"
$fakeRepo = Join-Path $work 'repo'
$fakeHome = Join-Path $work 'home'
$backupRoot = Join-Path $work 'backups'
$sandboxRoot = Join-Path $work 'sandbox'
New-Item -ItemType Directory -Path $fakeRepo, $sandboxRoot, (Join-Path $fakeHome '.codex/skills/.system') -Force | Out-Null
$systemSentinel = Join-Path $fakeHome '.codex/skills/.system/locked-sentinel.txt'
[System.IO.File]::WriteAllText($systemSentinel, 'do-not-open', [System.Text.UTF8Encoding]::new($false))
$beforeHash = (Get-FileHash -LiteralPath $systemSentinel -Algorithm SHA256).Hash

try {
    $cases = @(
        @{ Name='sync apply'; Script='sync.ps1'; Args=@('-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-SkipBuild','-SkipSecretScan') },
        @{ Name='retirement sync apply'; Script='sync.ps1'; Args=@('-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-SkipBuild','-SkipSecretScan','-RetireManifestPath',(Join-Path $work 'retire.json')) },
        @{ Name='environment activate apply'; Script='activate-harness-env.ps1'; Args=@('-Name','missing','-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-SkipBuild','-SkipSecretScan') },
        @{ Name='task ensure apply'; Script='task-skills.ps1'; Args=@('-Action','ensure-skill','missing','-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-SkipBuild','-SkipSecretScan') },
        @{ Name='task sync automatic apply'; Script='task-skills.ps1'; Args=@('-Action','sync','-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-Automatic','-SkipBuild','-SkipSecretScan') },
        @{ Name='task close apply'; Script='task-skills.ps1'; Args=@('-Action','close','-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-SkipBuild','-SkipSecretScan') },
        @{ Name='environment rollback apply'; Script='rollback-harness-env.ps1'; Args=@('-BackupPath',(Join-Path $work 'missing-backup'),'-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-PlanPath',(Join-Path $work 'plan.json'),'-Apply') }
    )
    foreach ($case in $cases) {
        $result = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot "scripts/$($case.Script)") -Arguments $case.Args
        Assert-TestCondition ($result.Code -ne 0 -and $result.Out -match 'safety-protocol-upgrade-required') "$($case.Name) is interlocked before production work"
    }

    $lock = [System.IO.File]::Open($systemSentinel, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $result = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/backup.ps1') -Arguments @('-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot)
    }
    finally { $lock.Dispose() }
    Assert-TestCondition ($result.Code -ne 0 -and $result.Out -match 'safety-protocol-upgrade-required') 'standalone backup is interlocked before protected .system traversal'
    Assert-TestCondition (-not (Test-Path -LiteralPath $backupRoot)) 'interlocked calls create no backup root'
    Assert-TestCondition ((Get-FileHash -LiteralPath $systemSentinel -Algorithm SHA256).Hash -eq $beforeHash) 'protected .system sentinel remains byte-identical'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'state'))) 'interlocked calls create no state path'

    $escaped = Invoke-SafetySandboxScript -SandboxRoot $sandboxRoot -ScriptPath (Join-Path $RepoRoot 'scripts/sync.ps1') -Arguments @(
        '-RepoRoot', $fakeRepo,
        '-HomeRoot', $fakeHome,
        '-BackupRoot', $backupRoot,
        '-Apply',
        '-SkipBuild',
        '-SkipSecretScan'
    )
    Assert-TestCondition ($escaped.Code -ne 0 -and $escaped.Out -match 'safety-protocol-upgrade-required') 'internal capability refuses mutation paths outside its sandbox'
    Assert-TestCondition (-not (Test-Path -LiteralPath $backupRoot)) 'rejected internal capability creates no backup root'
    Write-Host 'automation safety tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
