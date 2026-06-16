#requires -Version 7.0
<#
.SYNOPSIS
    Back up the live Claude, Codex, and OpenClaw skill directories to a timestamped
    folder outside the repository.

.DESCRIPTION
    Creates <BackupRoot>\sync-backup-YYYYMMDD-HHMMSS\ containing claude-skills\,
    codex-skills\ (a FULL copy including Codex's platform-managed .system),
    openclaw-skills\, openclaw-workspace-skills\, and openclaw-plugins-installs.json.
    Missing live directories are recorded with a .MISSING.txt marker rather than
    failing. Uses robocopy /E (never /MIR) into a fresh folder.

.PARAMETER HomeRoot
    Home directory root for resolving live paths. Defaults to $env:USERPROFILE.
    Override for tests (e.g. tests/fixtures/fake-home).

.PARAMETER BackupRoot
    Root directory for backups. Defaults to $env:USERPROFILE\.ai-agent-dotfiles-backups.
    Must be outside the repository.

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
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
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

# OpenClaw live paths
$openclawSkillsLive = Join-Path $HomeRoot '.openclaw\skills'
$openclawWorkspaceSkillsLive = Join-Path $HomeRoot '.openclaw\workspace\skills'
$openclawPluginsLive = Join-Path $HomeRoot '.openclaw\plugins\installs.json'

$openclawSkillsStats = Get-DirStats -Path $openclawSkillsLive
$openclawWorkspaceSkillsStats = Get-DirStats -Path $openclawWorkspaceSkillsLive
$openclawPluginsExists = Test-Path -LiteralPath $openclawPluginsLive -PathType Leaf

$openclawSkillsBackup = Join-Path $backupDir 'openclaw-skills'
$openclawWorkspaceSkillsBackup = Join-Path $backupDir 'openclaw-workspace-skills'
$openclawPluginsBackup = Join-Path $backupDir 'openclaw-plugins-installs.json'

Write-Host '=== backup.ps1 ==='
Write-Host "Mode            : $(if ($DryRun) { 'DRY-RUN (no changes)' } else { 'APPLY' })"
Write-Host "Machine         : $env:COMPUTERNAME"
Write-Host "Backup root     : $BackupRoot"
Write-Host "Backup dir      : $backupDir"
Write-Host "Claude live     : $claudeLive (exists=$($claudeStats.Exists), skillDirs=$($claudeStats.SkillDirs), files=$($claudeStats.Files))"
Write-Host "Codex live      : $codexLive (exists=$($codexStats.Exists), skillDirs=$($codexStats.SkillDirs), files=$($codexStats.Files))"
Write-Host "Codex .system   : marker exists=$codexSystemMarkerExists (included in full backup)"
Write-Host "OpenClaw skills : $openclawSkillsLive (exists=$($openclawSkillsStats.Exists), skillDirs=$($openclawSkillsStats.SkillDirs), files=$($openclawSkillsStats.Files))"
Write-Host "OpenClaw wkspc  : $openclawWorkspaceSkillsLive (exists=$($openclawWorkspaceSkillsStats.Exists), skillDirs=$($openclawWorkspaceSkillsStats.SkillDirs), files=$($openclawWorkspaceSkillsStats.Files))"
Write-Host "OpenClaw plugins: $openclawPluginsLive (exists=$openclawPluginsExists)"

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
    if ($openclawSkillsStats.Exists) {
        Write-Host "  would copy  $openclawSkillsLive  ->  $openclawSkillsBackup"
    } else {
        Write-Host "  would mark  $openclawSkillsLive MISSING (openclaw-skills.MISSING.txt)"
    }
    if ($openclawWorkspaceSkillsStats.Exists) {
        Write-Host "  would copy  $openclawWorkspaceSkillsLive  ->  $openclawWorkspaceSkillsBackup"
    } else {
        Write-Host "  would mark  $openclawWorkspaceSkillsLive MISSING (openclaw-workspace-skills.MISSING.txt)"
    }
    if ($openclawPluginsExists) {
        Write-Host "  would copy  $openclawPluginsLive  ->  $openclawPluginsBackup"
    } else {
        Write-Host "  would mark  $openclawPluginsLive MISSING (openclaw-plugins-installs.json.MISSING.txt)"
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

if ($openclawSkillsStats.Exists) {
    Invoke-RobocopyTree -Source $openclawSkillsLive -Destination $openclawSkillsBackup | Out-Null
    Write-Host "Backed up OpenClaw skills -> $openclawSkillsBackup"
} else {
    $marker = Join-Path $backupDir 'openclaw-skills.MISSING.txt'
    Set-Content -LiteralPath $marker -Value "$openclawSkillsLive did not exist at backup time ($timestamp)." -NoNewline
    Write-Host "OpenClaw live skills dir MISSING (recorded)."
}

if ($openclawWorkspaceSkillsStats.Exists) {
    Invoke-RobocopyTree -Source $openclawWorkspaceSkillsLive -Destination $openclawWorkspaceSkillsBackup | Out-Null
    Write-Host "Backed up OpenClaw workspace skills -> $openclawWorkspaceSkillsBackup"
} else {
    $marker = Join-Path $backupDir 'openclaw-workspace-skills.MISSING.txt'
    Set-Content -LiteralPath $marker -Value "$openclawWorkspaceSkillsLive did not exist at backup time ($timestamp)." -NoNewline
    Write-Host "OpenClaw workspace skills dir MISSING (recorded)."
}

if ($openclawPluginsExists) {
    Copy-Item -LiteralPath $openclawPluginsLive -Destination $openclawPluginsBackup -Force
    Write-Host "Backed up OpenClaw plugin install state -> $openclawPluginsBackup"
} else {
    $marker = Join-Path $backupDir 'openclaw-plugins-installs.json.MISSING.txt'
    Set-Content -LiteralPath $marker -Value "$openclawPluginsLive did not exist at backup time ($timestamp)." -NoNewline
    Write-Host "OpenClaw plugin install state MISSING (recorded)."
}

$manifest = [ordered] @{
    timestamp = (Get-Date).ToString('o')
    machine_name = $env:COMPUTERNAME
    repo_path = $RepoRoot
    source_live_paths = [ordered] @{
        claude = $claudeLive
        codex = $codexLive
        openclaw_skills = $openclawSkillsLive
        openclaw_workspace_skills = $openclawWorkspaceSkillsLive
        openclaw_plugins = $openclawPluginsLive
    }
    backup_target_paths = [ordered] @{
        claude = $claudeBackup
        codex = $codexBackup
        openclaw_skills = $openclawSkillsBackup
        openclaw_workspace_skills = $openclawWorkspaceSkillsBackup
        openclaw_plugins = $openclawPluginsBackup
    }
    claude_dir_existed = $claudeStats.Exists
    codex_dir_existed = $codexStats.Exists
    codex_system_marker_existed = $codexSystemMarkerExists
    openclaw_skills_dir_existed = $openclawSkillsStats.Exists
    openclaw_workspace_skills_dir_existed = $openclawWorkspaceSkillsStats.Exists
    openclaw_plugins_state_existed = $openclawPluginsExists
    counts = [ordered] @{
        claude_skill_dirs = $claudeStats.SkillDirs
        claude_files = $claudeStats.Files
        codex_skill_dirs = $codexStats.SkillDirs
        codex_files = $codexStats.Files
        openclaw_skills_skill_dirs = $openclawSkillsStats.SkillDirs
        openclaw_skills_files = $openclawSkillsStats.Files
        openclaw_workspace_skills_skill_dirs = $openclawWorkspaceSkillsStats.SkillDirs
        openclaw_workspace_skills_files = $openclawWorkspaceSkillsStats.Files
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
