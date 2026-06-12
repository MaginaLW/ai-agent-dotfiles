#requires -Version 7.0
<#
.SYNOPSIS
    Manifest-scoped sync of generated skill output into the live Claude / Codex
    skill directories. Safe by default (dry-run); only mutates with -Apply.

.DESCRIPTION
    Source of truth is the build output: claude/skills and codex/skills. For each
    platform the script computes add / update / prune plans scoped to repo-managed
    skills (manifests/managed-skills.txt) and operates ONE skill directory at a time.

    Hard safety rules:
      * Never whole-dir mirror (no robocopy /MIR) against a live skills root.
      * Never touch Codex's platform-managed .system directory.
      * Prune only removes skill dirs whose name is in managed-skills.txt AND no
        longer present in the generated output. Unknown live dirs are reported only.
      * -Apply always runs build + secret scan + a backup first; all must pass.

.PARAMETER Apply
    Actually perform the sync. Without it the script is a pure dry-run.

.PARAMETER SkipBuild
    Skip running scripts/build-skills.ps1 first (use the existing generated output).

.PARAMETER SkipSecretScan
    Skip running scripts/scan-secrets.ps1. Not recommended; default is to scan.

.PARAMETER BackupRoot
    Passed to scripts/backup.ps1 when -Apply creates the mandatory pre-change backup.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $SkipBuild,
    [switch] $SkipSecretScan,
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$CodexSystemDirName = '.system'

# ---------------------------------------------------------------------------
# Path probing
# ---------------------------------------------------------------------------

function Get-ClaudeLiveSkillsPath {
    return (Join-Path $env:USERPROFILE '.claude\skills')
}

function Get-CodexLiveSkillsPath {
    # Probe ~/.codex/skills first, then ~/.agents/skills; do not assume the latter.
    $codex = Join-Path $env:USERPROFILE '.codex\skills'
    $agents = Join-Path $env:USERPROFILE '.agents\skills'
    if (Test-Path -LiteralPath $codex) { return $codex }
    if (Test-Path -LiteralPath $agents) { return $agents }
    return $codex  # conventional default; created on -Apply if needed
}

# ---------------------------------------------------------------------------
# Centralized, audited destructive operations
# ---------------------------------------------------------------------------

function Assert-SafeLiveSkillTarget {
    # A target must be a direct child of $LiveRoot, must not be the root itself,
    # and must never be (or live under) Codex's .system directory.
    param(
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($LiveRoot).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar

    if (-not $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside live root: $pathFull"
    }
    $leaf = Split-Path -Leaf $pathFull
    if ($leaf -eq $CodexSystemDirName) {
        throw "Refusing to operate on Codex platform dir: $pathFull"
    }
    if ($pathFull -like "*$([System.IO.Path]::DirectorySeparatorChar)$CodexSystemDirName$([System.IO.Path]::DirectorySeparatorChar)*") {
        throw "Refusing to operate inside Codex .system: $pathFull"
    }
    # The target must be exactly one level under the root (a skill directory).
    $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $pathFull)).TrimEnd('\', '/')
    if ($parent -ne $rootFull) {
        throw "Refusing: target is not a direct skill dir under the live root: $pathFull"
    }
}

function Sync-OneSkillDir {
    # Make a single live skill dir exactly match its generated source dir.
    param(
        [Parameter(Mandatory)] [string] $SourceSkillDir,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $Name
    )

    $dest = Join-Path $LiveRoot $Name
    Assert-SafeLiveSkillTarget -LiveRoot $LiveRoot -Path $dest
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $LiveRoot | Out-Null
    Copy-Item -LiteralPath $SourceSkillDir -Destination $dest -Recurse
}

function Remove-OneSkillDir {
    # Remove a single stale repo-managed skill dir from a live root.
    param(
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $Name
    )

    $dest = Join-Path $LiveRoot $Name
    Assert-SafeLiveSkillTarget -LiveRoot $LiveRoot -Path $dest
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
}

# ---------------------------------------------------------------------------
# Plan computation
# ---------------------------------------------------------------------------

function Get-DirNames {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Directory -Force | ForEach-Object Name)
}

function Get-SyncPlan {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [System.Collections.Generic.HashSet[string]] $ManagedNames
    )

    $sourceNames = @(Get-DirNames -Path $SourceRoot)
    $liveNamesAll = @(Get-DirNames -Path $LiveRoot)

    $systemPreserved = $false
    $liveNames = foreach ($n in $liveNamesAll) {
        if ($Platform -eq 'codex' -and $n -eq $CodexSystemDirName) { $systemPreserved = $true; continue }
        $n
    }
    $liveNames = @($liveNames)

    $toAdd = @($sourceNames | Where-Object { $_ -notin $liveNames } | Sort-Object)
    $toUpdate = @($sourceNames | Where-Object { $_ -in $liveNames } | Sort-Object)
    # Prune: in live, NOT in source, but IS repo-managed (in manifest).
    $toPrune = @($liveNames | Where-Object { $_ -notin $sourceNames -and $ManagedNames.Contains($_) } | Sort-Object)
    # Unknown: in live, NOT in source, NOT repo-managed -> report only, never delete.
    $unknown = @($liveNames | Where-Object { $_ -notin $sourceNames -and -not $ManagedNames.Contains($_) } | Sort-Object)

    return [pscustomobject] @{
        Platform = $Platform
        SourceRoot = $SourceRoot
        LiveRoot = $LiveRoot
        SourceCount = $sourceNames.Count
        Add = $toAdd
        Update = $toUpdate
        Prune = $toPrune
        Unknown = $unknown
        SystemPreserved = $systemPreserved
    }
}

function Write-PlanReport {
    param([Parameter(Mandatory)] [object] $Plan)

    Write-Host ""
    Write-Host "[$($Plan.Platform)]"
    Write-Host "  source : $($Plan.SourceRoot) ($($Plan.SourceCount) skills)"
    Write-Host "  live   : $($Plan.LiveRoot)"
    Write-Host "  would add    ($($Plan.Add.Count))    : $([string]::Join(', ', $Plan.Add))"
    Write-Host "  would update ($($Plan.Update.Count)) : $([string]::Join(', ', $Plan.Update))"
    Write-Host "  would prune  ($($Plan.Prune.Count))  : $([string]::Join(', ', $Plan.Prune))   (repo-managed & removed from output)"
    Write-Host "  unknown dirs ($($Plan.Unknown.Count)) (ignored, never deleted): $([string]::Join(', ', $Plan.Unknown))"
    if ($Plan.Platform -eq 'codex') {
        Write-Host "  .system: $(if ($Plan.SystemPreserved) { 'present -> PRESERVED (untouched)' } else { 'not present' })"
    }
}

# ---------------------------------------------------------------------------
# Child-process helpers (build / scan / backup)
# ---------------------------------------------------------------------------

function Invoke-ChildScript {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [string[]] $Arguments = @()
    )
    $script = Join-Path $PSScriptRoot $ScriptName
    # Stream child output straight to the host so only the exit code is returned.
    & pwsh -NoProfile -File $script @Arguments | Out-Host
    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$claudeSource = Join-Path $RepoRoot 'claude\skills'
$codexSource = Join-Path $RepoRoot 'codex\skills'
$claudeLive = Get-ClaudeLiveSkillsPath
$codexLive = Get-CodexLiveSkillsPath
$manifestPath = Join-Path $RepoRoot 'manifests\managed-skills.txt'

Write-Host '=== sync.ps1 ==='
Write-Host "Mode            : $(if ($Apply) { 'APPLY' } else { 'DRY-RUN (no changes)' })"
Write-Host "Repo            : $RepoRoot"
Write-Host "Claude source   : $claudeSource"
Write-Host "Codex source    : $codexSource"
Write-Host "Claude live     : $claudeLive"
Write-Host "Codex live      : $codexLive"
Write-Host "Manifest        : $manifestPath"

# --- build ---
if ($SkipBuild) {
    Write-Host 'Build           : SKIPPED (-SkipBuild)'
} else {
    Write-Host 'Build           : running build-skills.ps1 ...'
    $code = Invoke-ChildScript -ScriptName 'build-skills.ps1'
    if ($code -ne 0) { Write-Host "ERROR: build-skills.ps1 failed (exit $code)."; exit 1 }
    Write-Host 'Build           : OK'
}

# --- secret scan ---
if ($SkipSecretScan) {
    Write-Host 'Secret scan     : SKIPPED (-SkipSecretScan)'
} else {
    Write-Host 'Secret scan     : running scan-secrets.ps1 ...'
    $code = Invoke-ChildScript -ScriptName 'scan-secrets.ps1'
    if ($code -ne 0) { Write-Host "ERROR: scan-secrets.ps1 failed (exit $code)."; exit 1 }
    Write-Host 'Secret scan     : OK'
}

if (-not (Test-Path -LiteralPath $claudeSource) -or -not (Test-Path -LiteralPath $codexSource)) {
    Write-Host 'ERROR: generated output missing. Run build-skills.ps1 (do not pass -SkipBuild).'
    exit 1
}

# --- managed-skills manifest ---
$managedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $manifestPath) {
    foreach ($line in [System.IO.File]::ReadAllLines($manifestPath)) {
        $t = $line.Trim()
        if ($t) { [void] $managedNames.Add($t) }
    }
}
Write-Host "Managed skills  : $($managedNames.Count) (from manifest)"

# --- plans ---
$claudePlan = Get-SyncPlan -Platform 'claude' -SourceRoot $claudeSource -LiveRoot $claudeLive -ManagedNames $managedNames
$codexPlan = Get-SyncPlan -Platform 'codex' -SourceRoot $codexSource -LiveRoot $codexLive -ManagedNames $managedNames

Write-Host ''
Write-Host '----- PLAN -----'
Write-Host "Backup before apply: $(if ($Apply) { "YES (mandatory) under $BackupRoot" } else { 'n/a (dry-run)' })"
Write-PlanReport -Plan $claudePlan
Write-PlanReport -Plan $codexPlan

$totalChanges = $claudePlan.Add.Count + $claudePlan.Update.Count + $claudePlan.Prune.Count +
                $codexPlan.Add.Count + $codexPlan.Update.Count + $codexPlan.Prune.Count

Write-Host ''
Write-Host '----- SUMMARY -----'
Write-Host "Claude: +$($claudePlan.Add.Count) ~$($claudePlan.Update.Count) -$($claudePlan.Prune.Count)  (unknown ignored: $($claudePlan.Unknown.Count))"
Write-Host "Codex : +$($codexPlan.Add.Count) ~$($codexPlan.Update.Count) -$($codexPlan.Prune.Count)  (unknown ignored: $($codexPlan.Unknown.Count); .system preserved: $($codexPlan.SystemPreserved))"

if (-not $Apply) {
    Write-Host ''
    Write-Host 'DRY-RUN complete. No live files were changed. Re-run with -Apply to execute.'
    exit 0
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '----- APPLY -----'

# 1) Mandatory backup first.
Write-Host 'Creating mandatory pre-change backup ...'
$backupOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'backup.ps1') -BackupRoot $BackupRoot -RepoRoot $RepoRoot 2>&1
$backupCode = $LASTEXITCODE
$backupOut | ForEach-Object { Write-Host "  [backup] $_" }
if ($backupCode -ne 0) { Write-Host "ERROR: backup failed (exit $backupCode). Aborting before any change."; exit 1 }
$backupLine = $backupOut | Where-Object { $_ -is [string] -and $_ -match '^BACKUP_DIR=' } | Select-Object -Last 1
$backupDir = if ($backupLine) { ($backupLine -replace '^BACKUP_DIR=', '').Trim() } else { '<unknown>' }
Write-Host "Backup path     : $backupDir"

# 2) Apply per-platform, one skill dir at a time.
$applied = [ordered] @{ ClaudeAdded = 0; ClaudeUpdated = 0; ClaudePruned = 0; CodexAdded = 0; CodexUpdated = 0; CodexPruned = 0 }

foreach ($plan in @($claudePlan, $codexPlan)) {
    New-Item -ItemType Directory -Force -Path $plan.LiveRoot | Out-Null
    foreach ($name in $plan.Add) {
        Sync-OneSkillDir -SourceSkillDir (Join-Path $plan.SourceRoot $name) -LiveRoot $plan.LiveRoot -Name $name
        if ($plan.Platform -eq 'claude') { $applied.ClaudeAdded++ } else { $applied.CodexAdded++ }
    }
    foreach ($name in $plan.Update) {
        Sync-OneSkillDir -SourceSkillDir (Join-Path $plan.SourceRoot $name) -LiveRoot $plan.LiveRoot -Name $name
        if ($plan.Platform -eq 'claude') { $applied.ClaudeUpdated++ } else { $applied.CodexUpdated++ }
    }
    foreach ($name in $plan.Prune) {
        Remove-OneSkillDir -LiveRoot $plan.LiveRoot -Name $name
        if ($plan.Platform -eq 'claude') { $applied.ClaudePruned++ } else { $applied.CodexPruned++ }
    }
}

Write-Host ''
Write-Host "Claude applied: +$($applied.ClaudeAdded) ~$($applied.ClaudeUpdated) -$($applied.ClaudePruned)"
Write-Host "Codex  applied: +$($applied.CodexAdded) ~$($applied.CodexUpdated) -$($applied.CodexPruned)"

# 3) Verification.
$codexMarker = Join-Path $codexLive '.system\.codex-system-skills.marker'
$systemOk = Test-Path -LiteralPath $codexMarker
Write-Host ".system marker preserved: $systemOk"

function Test-Parity {
    param([string] $SourceRoot, [string] $LiveRoot, [bool] $ExcludeSystem)
    $src = @(Get-DirNames -Path $SourceRoot | Sort-Object)
    $live = @(Get-DirNames -Path $LiveRoot | Where-Object { -not ($ExcludeSystem -and $_ -eq $CodexSystemDirName) } | Sort-Object)
    return -not (Compare-Object $src $live)
}

$claudeParity = Test-Parity -SourceRoot $claudeSource -LiveRoot $claudeLive -ExcludeSystem $false
$codexParity = Test-Parity -SourceRoot $codexSource -LiveRoot $codexLive -ExcludeSystem $true
Write-Host "Claude live-vs-repo: $(if ($claudeParity) { 'OK' } else { 'MISMATCH' })"
Write-Host "Codex  live-vs-repo: $(if ($codexParity) { 'OK (excl .system)' } else { 'MISMATCH' })"

if (-not $systemOk -and (Get-DirNames -Path $codexLive) -contains $CodexSystemDirName) {
    Write-Host 'WARNING: .system dir present but marker missing — investigate.'
}
if (-not $claudeParity -or -not $codexParity) {
    Write-Host "ERROR: post-apply parity check failed. Backup is at: $backupDir"
    exit 1
}

Write-Host ''
Write-Host "APPLY complete. Backup: $backupDir"
exit 0
