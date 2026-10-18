#requires -Version 7.0
<#
.SYNOPSIS
    Self-contained regression tests for the config-sync scripts
    (config-status.ps1, config-pull.ps1, config-push.ps1).

.DESCRIPTION
    No Pester dependency. Runs each real script against isolated repo/home
    trees under the ignored project tmp/tests/config-sync area and asserts behavior, with emphasis on the two
    config-push gates (secret scan + machine-private path scan) and the
    never-prune / dry-run-default posture.

    Exit code 0 = all passed, 1 = one or more failures.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $WorkRoot = '',
    [string] $WorkspaceRunId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$statusScript = Join-Path $RepoRoot 'scripts/config-status.ps1'
$pullScript = Join-Path $RepoRoot 'scripts/config-pull.ps1'
$pushScript = Join-Path $RepoRoot 'scripts/config-push.ps1'

$script:pass = 0
$script:fail = 0
$script:failureMessages = [Collections.Generic.List[string]]::new()
function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    }
    else {
        $script:fail++
        $script:failureMessages.Add($Message)
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

. (Join-Path $RepoRoot 'scripts/config-sync-test-workspace.ps1')
if ($WorkRoot -or $WorkspaceRunId) {
    if (-not $WorkRoot -or -not $WorkspaceRunId) { throw 'WorkRoot and WorkspaceRunId must be provided together.' }
    $work = Assert-ConfigSyncTestWork -RepoRoot $RepoRoot -WorkRoot $WorkRoot -RunId $WorkspaceRunId
}
else {
    $workspace = New-ConfigSyncTestWork -RepoRoot $RepoRoot
    $work = $workspace.Root
    $WorkspaceRunId = $workspace.RunId
}

function New-TempRepo {
    param([Parameter(Mandatory)] [string] $Name)
    $tr = Join-Path $work $Name
    New-Item -ItemType Directory -Path (Join-Path $tr 'manifests') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tr 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tr 'claude') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'manifests/whitelist.psd1') -Destination (Join-Path $tr 'manifests') -Force
    foreach ($name in @(
        'scan-secrets.ps1'
        'pinned-tool.ps1'
        'repo-common.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts/$name") -Destination (Join-Path $tr "scripts/$name") -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $tr 'tools/gitleaks') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json') -Destination (Join-Path $tr 'tools/gitleaks/gitleaks.lock.json') -Force
    $gitleaks = Join-Path $RepoRoot '.gitleaks.toml'
    if (Test-Path -LiteralPath $gitleaks) { Copy-Item -LiteralPath $gitleaks -Destination $tr -Force }
    & git -C $tr init --quiet
    if ($LASTEXITCODE -ne 0) { throw "Unable to initialize config-sync fixture repository: $tr" }
    return $tr
}

function Invoke-Script {
    # Run a config script through the shared helper.
    param([Parameter(Mandatory)] [string] $Script, [string[]] $ScriptArgs = @())
    Invoke-TestProcess -ScriptPath $Script -Arguments $ScriptArgs
}

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    Set-TestFile -Path $Path -Content $Content
}

$outcome = 'Failed'
$exceptionType = ''
$failureScript = ''
$failureLine = 0
try {
    # ===========================================================================
    Write-Host "`n[config-status]" -ForegroundColor Cyan
    # ===========================================================================
    $tr = New-TempRepo -Name 'status-repo'
    $th = Join-Path $work 'status-home'
    Set-File -Path (Join-Path $tr 'claude/CLAUDE.md') -Content 'same'
    Set-File -Path (Join-Path $th '.claude/CLAUDE.md') -Content 'same'
    Set-File -Path (Join-Path $th '.claude/settings.json') -Content '{"a":1}'    # home-only
    $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-Json')
    $rows = $r.Out | ConvertFrom-Json
    $byItem = @{}; foreach ($row in $rows) { $byItem[$row.Item] = $row.Status }
    Assert ($byItem['CLAUDE.md'] -eq 'in-sync') "status: identical file -> in-sync"
    Assert ($byItem['settings.json'] -eq 'home-only') "status: home-only file -> home-only"

    Set-File -Path (Join-Path $th '.claude/CLAUDE.md') -Content 'changed'
    $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-Json')
    $rows = $r.Out | ConvertFrom-Json
    $claudeRow = $rows | Where-Object { $_.Item -eq 'CLAUDE.md' }
    Assert ($claudeRow.Status -eq 'differs') "status: differing file -> differs"

    # ===========================================================================
    Write-Host "`n[config-pull]" -ForegroundColor Cyan
    # ===========================================================================
    $tr = New-TempRepo -Name 'pull-repo'
    $th = Join-Path $work 'pull-home'
    $bk = Join-Path $work 'pull-backup'
    Set-File -Path (Join-Path $tr 'claude/CLAUDE.md') -Content 'deploy-me'

    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude')
    Assert ($r.Out -match 'add\s+Claude/CLAUDE.md') "pull: dry-run plans add"
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.claude/CLAUDE.md'))) "pull: dry-run writes nothing"

    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply')
    $deployed = Join-Path $th '.claude/CLAUDE.md'
    Assert ((Test-Path -LiteralPath $deployed) -and ((Get-Content -Raw -LiteralPath $deployed).TrimEnd("`r","`n") -eq 'deploy-me')) "pull: apply deploys file"

    Set-File -Path (Join-Path $th '.claude/keep-me.txt') -Content 'home-only'    # not a managed item
    Set-Content -LiteralPath $deployed -Value 'stale' -NoNewline
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply')
    Assert ((Get-Content -Raw -LiteralPath $deployed).TrimEnd("`r","`n") -eq 'deploy-me') "pull: update overwrites stale home copy"
    $bakFile = Get-ChildItem -Recurse -File -LiteralPath $bk -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'CLAUDE.md' } | Select-Object -First 1
    Assert ($null -ne $bakFile -and (Get-Content -Raw -LiteralPath $bakFile.FullName) -eq 'stale') "pull: overwritten home file is backed up"
    Assert (Test-Path -LiteralPath (Join-Path $th '.claude/keep-me.txt')) "pull: home-only file survives (no prune)"

    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude')
    Assert ($r.Out -match 'Nothing to deploy') "pull: idempotent dry-run is a no-op"

    # The scan must stop both adds and updates before even creating a backup.
    $tr = New-TempRepo -Name 'pull-secret-repo'
    $th = Join-Path $work 'pull-secret-home'
    $bk = Join-Path $work 'pull-secret-backup'
    $fakeToken = 'sk-' + 'ant-' + ('FAKE' * 5) + '000000'
    Set-File -Path (Join-Path $tr 'claude/CLAUDE.md') -Content ('unsafe ' + $fakeToken)
    Set-File -Path (Join-Path $tr 'claude/settings.json') -Content '{"new":true}'
    $original = Join-Path $th '.claude/CLAUDE.md'
    Set-File -Path $original -Content 'keep original bytes'
    $beforeHash = (Get-FileHash -LiteralPath $original).Hash
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -ne 0 -and $r.Out -match 'Secret scan failed') 'pull: planted source secret fails closed'
    Assert ((Get-FileHash -LiteralPath $original).Hash -eq $beforeHash) 'pull: failed scan preserves the existing home file'
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.claude/settings.json'))) 'pull: failed scan writes no add'
    Assert (-not (Test-Path -LiteralPath $bk)) 'pull: failed scan creates no backup'

    # Restore bytes and remove new files; empty parent directories may remain.
    # The later commands parent is a file, so Copy-Item fails after an add and update.
    $tr = New-TempRepo -Name 'pull-rollback-repo'
    $th = Join-Path $work 'pull-rollback-home'
    $bk = Join-Path $work 'pull-rollback-backup'
    Set-File -Path (Join-Path $tr 'claude/settings.json') -Content '{"new":true}'
    Set-File -Path (Join-Path $tr 'claude/CLAUDE.md') -Content 'updated bytes'
    Set-File -Path (Join-Path $tr 'claude/commands/fail.md') -Content 'later write'
    $original = Join-Path $th '.claude/CLAUDE.md'
    Set-File -Path $original -Content 'original bytes'
    Set-File -Path (Join-Path $th '.claude/commands') -Content 'parent is a file'
    $beforeHash = (Get-FileHash -LiteralPath $original).Hash
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -ne 0 -and $r.Out -match 'best-effort rollback') 'pull: later copy failure reports attempted recovery'
    Assert ($r.Out -match 'Could not find a part of the path') 'pull: original copy error remains visible'
    Assert ((Get-FileHash -LiteralPath $original).Hash -eq $beforeHash) 'pull: rollback restores an earlier update byte-for-byte'
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.claude/settings.json'))) 'pull: rollback removes an earlier add'
    $bakFile = @(Get-ChildItem -LiteralPath $bk -Filter 'CLAUDE.md' -File -Recurse)
    Assert ($bakFile.Count -eq 1 -and (Get-FileHash -LiteralPath $bakFile[0].FullName).Hash -eq $beforeHash) 'pull: original backup survives rollback'

    # A pure-add plan has no mirrored backup directory to restore from.
    $tr = New-TempRepo -Name 'pull-add-rollback-repo'
    $th = Join-Path $work 'pull-add-rollback-home'
    $bk = Join-Path $work 'pull-add-rollback-backup'
    Set-File -Path (Join-Path $tr 'claude/settings.json') -Content '{}'
    Set-File -Path (Join-Path $tr 'claude/commands/fail.md') -Content 'later write'
    Set-File -Path (Join-Path $th '.claude/commands') -Content 'parent is a file'
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -ne 0 -and $r.Out -match 'best-effort rollback') 'pull: pure-add failure reports recovery without a backup'
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.claude/settings.json'))) 'pull: pure-add rollback removes an earlier add'
    Assert (-not (Test-Path -LiteralPath $bk)) 'pull: pure-add rollback does not invent a backup directory'

    # Backups precede the guarded copy: a failed backup must leave home untouched.
    $tr = New-TempRepo -Name 'pull-backup-failure-repo'
    $th = Join-Path $work 'pull-backup-failure-home'
    $bk = Join-Path $work 'pull-blocked-backup'
    Set-File -Path (Join-Path $tr 'claude/settings.json') -Content '{"new":true}'
    Set-File -Path (Join-Path $th '.claude/settings.json') -Content '{"original":true}'
    Set-File -Path (Join-Path $tr 'claude/CLAUDE.md') -Content 'new file'
    Set-File -Path $bk -Content 'backup parent is a file'
    $original = Join-Path $th '.claude/settings.json'
    $beforeHash = (Get-FileHash -LiteralPath $original).Hash
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -ne 0 -and $r.Out -notmatch 'best-effort rollback') 'pull: backup failure does not run rollback'
    Assert ((Get-FileHash -LiteralPath $original).Hash -eq $beforeHash) 'pull: backup failure preserves existing home bytes'
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.claude/CLAUDE.md'))) 'pull: backup failure writes no add'

    # Read sharing permits planning and backup, but prevents both copy and restore.
    # A failed restore of the current item must not stop recovery of earlier writes.
    $tr = New-TempRepo -Name 'pull-restore-warning-repo'
    $th = Join-Path $work 'pull-restore-warning-home'
    $bk = Join-Path $work 'pull-restore-warning-backup'
    Set-File -Path (Join-Path $tr 'claude/settings.json') -Content '{"new":true}'
    Set-File -Path (Join-Path $th '.claude/settings.json') -Content '{"original":true}'
    Set-File -Path (Join-Path $tr 'claude/CLAUDE.md') -Content 'updated bytes'
    $locked = Join-Path $th '.claude/CLAUDE.md'
    Set-File -Path $locked -Content 'locked original'
    $original = Join-Path $th '.claude/settings.json'
    $beforeHash = (Get-FileHash -LiteralPath $original).Hash
    $handle = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply')
    }
    finally { $handle.Dispose() }
    Assert ($r.Code -ne 0 -and $r.Out -match 'Rollback could not restore') 'pull: restore failure warns and still exits non-zero'
    Assert ($r.Out -match 'Copy-Item' -and $r.Out -match 'Original files are backed up') 'pull: restore failure retains the original copy error and backup location'
    Assert ((Get-FileHash -LiteralPath $original).Hash -eq $beforeHash) 'pull: another restore continues after one restore fails'

    # ===========================================================================
    Write-Host "`n[config-push]" -ForegroundColor Cyan
    # ===========================================================================
    $tr = New-TempRepo -Name 'push-repo'
    $th = Join-Path $work 'push-home'
    $bk = Join-Path $work 'push-backup'
    $captured = Join-Path $tr 'claude/settings.json'
    Set-File -Path (Join-Path $tr 'claude/keep.txt') -Content 'repo-only'         # must survive (no prune)

    # clean capture passes both gates
    Set-File -Path (Join-Path $th '.claude/settings.json') -Content '{"theme":"auto","ok":true}'
    $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -eq 0 -and (Test-Path -LiteralPath $captured)) "push: clean config captured (passes both gates)"
    Assert (Test-Path -LiteralPath (Join-Path $tr 'claude/keep.txt')) "push: repo-only file survives (no prune)"

    # secret gate blocks + reverts (planted fake Anthropic token).
    # Assembled at runtime so the token literal never appears in this file's source
    # (otherwise scan-secrets would block committing the test itself).
    $fakeToken = 'sk-' + 'ant-' + ('FAKE' * 5) + '000000'
    Set-File -Path (Join-Path $th '.claude/settings.json') -Content ('{"k":"' + $fakeToken + '"}')
    $beforeHash = (Get-FileHash -LiteralPath $captured).Hash
    $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -ne 0) "push: secret gate exits non-zero"
    Assert ($r.Out -match 'exit code 1' -and $r.Out -match 'Reverted') 'push: scan failure reports its exit code and completed revert'
    Assert ((Get-FileHash -LiteralPath $captured).Hash -eq $beforeHash) "push: secret gate reverts the capture (no token kept)"

    # path gate blocks + reverts (planted machine-private path); secret scan skipped to isolate it
    Set-File -Path (Join-Path $th '.claude/settings.json') -Content '{"p":"C:\Users\admin\foo"}'
    $beforeHash = (Get-FileHash -LiteralPath $captured).Hash
    $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
    Assert ($r.Code -ne 0 -and $r.Out -match 'machine-private') "push: path gate exits non-zero"
    Assert ((Get-FileHash -LiteralPath $captured).Hash -eq $beforeHash) "push: path gate reverts the capture"

    # -SkipPathScan bypass keeps the path-bearing capture
    $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Claude', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan', '-SkipPathScan')
    Assert ($r.Code -eq 0 -and ((Get-Content -Raw -LiteralPath $captured) -match 'C:\\Users')) "push: -SkipPathScan bypasses the path gate"

    if ($script:fail -eq 0) { $outcome = 'Passed' }
}
catch {
    $exceptionType = $_.Exception.GetType().Name
    $failureScript = [IO.Path]::GetFileName($_.InvocationInfo.ScriptName)
    $failureLine = $_.InvocationInfo.ScriptLineNumber
    Write-Host ('Fixture failure: ' + $exceptionType) -ForegroundColor Red
}
finally {
    # The fixture calls only synchronous children. A forced timeout skips this block;
    # its owning parent records the exact workspace without assuming descendants stopped.
    Complete-ConfigSyncTestWork -RepoRoot $RepoRoot -WorkRoot $work -RunId $WorkspaceRunId `
        -Outcome $outcome -FailureMessages $script:failureMessages.ToArray() -ExceptionType $exceptionType `
        -FailureScript $failureScript -FailureLine $failureLine -RemovePayload
}
Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
if ($outcome -eq 'Passed') { exit 0 }
Write-Host ('Failure summary: ' + (Join-Path $RepoRoot "tmp/tests/config-sync/receipts/$WorkspaceRunId.json")) -ForegroundColor Yellow
exit 1
