#requires -Version 7.0
<#
.SYNOPSIS
    Self-contained regression tests for the config-sync scripts
    (config-status.ps1, config-pull.ps1, config-push.ps1).

.DESCRIPTION
    No Pester dependency. Runs each real script against isolated repo/home
    trees in a checkout sibling and asserts behavior, with emphasis on the two
    config-push gates (secret scan + machine-private path scan) and the
    never-prune / dry-run-default posture.

    Exit code 0 = all passed, 1 = one or more failures.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$statusScript = Join-Path $RepoRoot 'scripts/config-status.ps1'
$pullScript = Join-Path $RepoRoot 'scripts/config-pull.ps1'
$pushScript = Join-Path $RepoRoot 'scripts/config-push.ps1'

$script:pass = 0
$script:fail = 0
function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

$work = Join-Path (Split-Path -Parent $RepoRoot) ".ai-agent-dotfiles-config-sync-$([Guid]::NewGuid().ToString('N'))"
function Remove-Work {
    if (($work -like '*.ai-agent-dotfiles-config-sync-*') -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
Remove-Work
New-Item -ItemType Directory -Path $work -Force | Out-Null

function New-TempRepo {
    param([Parameter(Mandatory)] [string] $Name)
    $tr = Join-Path $work $Name
    New-Item -ItemType Directory -Path (Join-Path $tr 'manifests') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tr 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tr 'claude') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'manifests/whitelist.psd1') -Destination (Join-Path $tr 'manifests') -Force
    foreach ($name in @(
        'scan-secrets.ps1'
        'canonical-preflight-common.ps1'
        'json-artifact-common.ps1'
        'semantic-json.ps1'
        'scan-input-common.ps1'
        'safe-tree-walker.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts/$name") -Destination (Join-Path $tr 'scripts') -Force
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
    # Run a config script; return @{ Out; Code }.
    param([Parameter(Mandatory)] [string] $Script, [string[]] $ScriptArgs = @())
    $out = & pwsh -NoProfile -File $Script @ScriptArgs 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $Content -NoNewline
}

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

# ===========================================================================
Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
if ($script:fail -eq 0) {
    Remove-Work
    exit 0
}
Write-Host "Workspace kept for inspection: $work" -ForegroundColor Yellow
exit 1
