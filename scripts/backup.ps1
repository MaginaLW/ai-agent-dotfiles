#requires -Version 7.0
<#
.SYNOPSIS
    Back up the live Claude, Codex, and Reasonix skill directories to a
    timestamped folder outside the repository.

.DESCRIPTION
    Creates <BackupRoot>\sync-backup-YYYYMMDD-HHMMSS\ containing claude-skills\,
    codex-skills\ (a FULL copy including Codex's platform-managed .system), and
    reasonix-skills\.
    Missing live directories are recorded with a .MISSING.txt marker rather than
    failing. Uses robocopy /E (never /MIR) into a fresh folder.

.PARAMETER HomeRoot
    Home directory root for resolving live paths. Defaults to $env:USERPROFILE.
    Override for tests (e.g. tests/fixtures/fake-home).

.PARAMETER BackupRoot
    Root directory for backups. Defaults to $env:USERPROFILE\.ai-agent-dotfiles-backups.
    Must be outside the repository.

.PARAMETER ReasonixLiveSkillsPath
    Optional override for the Reasonix live skills directory. Sync passes its
    resolved override here so the mandatory backup covers the exact deployment
    target.

.PARAMETER DryRun
    Print what would be backed up without copying anything or creating folders.

.OUTPUTS
    On a real (non-dry-run) backup, prints a machine-readable line:
        BACKUP_DIR=<full path>
#>
[CmdletBinding()]
param(
    [string] $HomeRoot = $env:USERPROFILE,
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $ReasonixLiveSkillsPath,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')
if (-not $DryRun) {
    Assert-LiveSafetyMutationAllowed -Operation 'standalone-backup' -Paths @($RepoRoot, $HomeRoot, $BackupRoot, $ReasonixLiveSkillsPath)
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-CodexLiveSkillsPath {
    # Probe order: ~/.codex/skills, then ~/.agents/skills. If neither exists,
    # report ~/.codex/skills as the conventional path (without creating it).
    $codex = Join-Path $HomeRoot '.codex\skills'
    $agents = Join-Path $HomeRoot '.agents\skills'
    if (Test-Path -LiteralPath $codex) { return $codex }
    if (Test-Path -LiteralPath $agents) { return $agents }
    return $codex
}

function Get-DirStats {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject] @{ Exists = $false; SkillDirs = 0; Files = 0 }
    }
    $skillDirs = @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue)
    return [pscustomobject] @{
        Exists = $true
        SkillDirs = $skillDirs.Count
        Files = $files.Count
    }
}

function Invoke-RobocopyTree {
    # Full (non-mirror) copy of a directory tree into a fresh destination.
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination
    )

    & robocopy $Source $Destination /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
    $code = $LASTEXITCODE
    # robocopy: exit codes < 8 indicate success (0 = no change, 1 = copied, etc.)
    if ($code -ge 8) {
        throw "robocopy failed copying '$Source' -> '$Destination' (exit $code)."
    }
    return $code
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

$claudeLive = Join-Path $HomeRoot '.claude\skills'
$codexLive = Get-CodexLiveSkillsPath
$codexSystemMarker = Join-Path $codexLive '.system\.codex-system-skills.marker'

$claudeStats = Get-DirStats -Path $claudeLive
$codexStats = Get-DirStats -Path $codexLive
$codexSystemMarkerExists = Test-Path -LiteralPath $codexSystemMarker

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $BackupRoot "sync-backup-$timestamp"
$claudeBackup = Join-Path $backupDir 'claude-skills'
$codexBackup = Join-Path $backupDir 'codex-skills'

# Reasonix live skills
$reasonixSkillsLive = if ($ReasonixLiveSkillsPath) {
    if (Test-Path -LiteralPath $ReasonixLiveSkillsPath) {
        (Resolve-Path -LiteralPath $ReasonixLiveSkillsPath).Path
    }
    else {
        [System.IO.Path]::GetFullPath($ReasonixLiveSkillsPath)
    }
}
else {
    Join-Path $HomeRoot 'AppData\Roaming\reasonix\skills'
}
$reasonixSkillsStats = Get-DirStats -Path $reasonixSkillsLive
$reasonixSkillsBackup = Join-Path $backupDir 'reasonix-skills'

Write-Host '=== backup.ps1 ==='
Write-Host "Mode            : $(if ($DryRun) { 'DRY-RUN (no changes)' } else { 'APPLY' })"
Write-Host "Machine         : $env:COMPUTERNAME"
Write-Host "Backup root     : $BackupRoot"
Write-Host "Backup dir      : $backupDir"
Write-Host "Claude live     : $claudeLive (exists=$($claudeStats.Exists), skillDirs=$($claudeStats.SkillDirs), files=$($claudeStats.Files))"
Write-Host "Codex live      : $codexLive (exists=$($codexStats.Exists), skillDirs=$($codexStats.SkillDirs), files=$($codexStats.Files))"
Write-Host "Codex .system   : marker exists=$codexSystemMarkerExists (included in full backup)"

Write-Host "Reasonix live   : $reasonixSkillsLive (exists=$($reasonixSkillsStats.Exists), skillDirs=$($reasonixSkillsStats.SkillDirs), files=$($reasonixSkillsStats.Files))"

# ---------------------------------------------------------------------------
# Refuse to write a backup inside the repository
# ---------------------------------------------------------------------------

$repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
$backupFull = [System.IO.Path]::GetFullPath($backupDir)
if ($backupFull.StartsWith($repoFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "ERROR: Backup directory is inside the repository ($backupFull). Choose a -BackupRoot outside the repo."
    exit 1
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY-RUN plan:'
    if ($claudeStats.Exists) {
        Write-Host "  would copy  $claudeLive  ->  $claudeBackup"
    } else {
        Write-Host "  would mark  $claudeLive MISSING (claude-skills.MISSING.txt)"
    }
    if ($codexStats.Exists) {
        Write-Host "  would copy  $codexLive  ->  $codexBackup   (including .system)"
    } else {
        Write-Host "  would mark  $codexLive MISSING (codex-skills.MISSING.txt)"
    }
    if ($reasonixSkillsStats.Exists) {
        Write-Host "  would copy  $reasonixSkillsLive  ->  $reasonixSkillsBackup"
    } else {
        Write-Host "  would mark  $reasonixSkillsLive MISSING (reasonix-skills.MISSING.txt)"
    }
    Write-Host "  would write $backupDir\backup-manifest.json"
    Write-Host ''
    Write-Host 'No files were copied (dry-run).'
    exit 0
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

if ($claudeStats.Exists) {
    Invoke-RobocopyTree -Source $claudeLive -Destination $claudeBackup | Out-Null
    Write-Host "Backed up Claude skills -> $claudeBackup"
} else {
    $marker = Join-Path $backupDir 'claude-skills.MISSING.txt'
    Set-Content -LiteralPath $marker -Value "$claudeLive did not exist at backup time ($timestamp)." -NoNewline
    Write-Host "Claude live skills dir MISSING (recorded)."
}

if ($codexStats.Exists) {
    Invoke-RobocopyTree -Source $codexLive -Destination $codexBackup | Out-Null
    Write-Host "Backed up Codex skills -> $codexBackup (including .system)"
} else {
    $marker = Join-Path $backupDir 'codex-skills.MISSING.txt'
    Set-Content -LiteralPath $marker -Value "$codexLive did not exist at backup time ($timestamp)." -NoNewline
    Write-Host "Codex live skills dir MISSING (recorded)."
}

if ($reasonixSkillsStats.Exists) {
    Invoke-RobocopyTree -Source $reasonixSkillsLive -Destination $reasonixSkillsBackup | Out-Null
    Write-Host "Backed up Reasonix skills -> $reasonixSkillsBackup"
} else {
    $marker = Join-Path $backupDir 'reasonix-skills.MISSING.txt'
    Set-Content -LiteralPath $marker -Value "$reasonixSkillsLive did not exist at backup time ($timestamp)." -NoNewline
    Write-Host "Reasonix live skills dir MISSING (recorded)."
}

$manifest = [ordered] @{
    timestamp = (Get-Date).ToString('o')
    machine_name = $env:COMPUTERNAME
    repo_path = $RepoRoot
    source_live_paths = [ordered] @{
        claude = $claudeLive
        codex = $codexLive
        reasonix = $reasonixSkillsLive
    }
    backup_target_paths = [ordered] @{
        claude = $claudeBackup
        codex = $codexBackup
        reasonix = $reasonixSkillsBackup
    }
    claude_dir_existed = $claudeStats.Exists
    codex_dir_existed = $codexStats.Exists
    codex_system_marker_existed = $codexSystemMarkerExists
    counts = [ordered] @{
        claude_skill_dirs = $claudeStats.SkillDirs
        claude_files = $claudeStats.Files
        codex_skill_dirs = $codexStats.SkillDirs
        codex_files = $codexStats.Files
        reasonix_skill_dirs = $reasonixSkillsStats.SkillDirs
        reasonix_files = $reasonixSkillsStats.Files
    }
    dry_run = $false
}

$manifestPath = Join-Path $backupDir 'backup-manifest.json'
$json = ($manifest | ConvertTo-Json -Depth 8)
[System.IO.File]::WriteAllText($manifestPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote manifest -> $manifestPath"

Write-Host ''
Write-Host "Backup complete: $backupDir"
# Machine-readable line for callers (e.g. sync.ps1).
Write-Host "BACKUP_DIR=$backupDir"
exit 0
