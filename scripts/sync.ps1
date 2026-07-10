#requires -Version 7.0
<#
.SYNOPSIS
    Manifest-scoped sync of generated skill output into the live Claude / Codex /
    OpenClaw skill directories. Safe by default (dry-run); only mutates with -Apply.

.DESCRIPTION
    Source of truth is the build output: claude/skills, codex/skills, and
    openclaw/skills. For each platform the script computes add / update / prune
    plans scoped to per-platform repo-managed skill manifests and operates ONE
    skill directory at a time.

    Hard safety rules:
      * Never whole-dir mirror (no robocopy /MIR) against a live skills root.
      * Never touch Codex's platform-managed .system directory.
      * Prune only removes skill dirs whose name is in the platform's managed-skills
        manifest AND no longer present in the generated output. Unknown live dirs
        are reported only.
      * -Apply always runs build + secret scan + a backup first; all must pass.
      * For OpenClaw skill updates, any live .clawhub directories are preserved
        unless the generated source already includes them.

.PARAMETER Apply
    Actually perform the sync. Without it the script is a pure dry-run.

.PARAMETER DryRun
    Explicitly select dry-run mode. This is equivalent to omitting -Apply and cannot
    be combined with -Apply.

.PARAMETER SkipBuild
    Skip running scripts/build-skills.ps1 first (use the existing generated output).

.PARAMETER SkipSecretScan
    Skip running scripts/scan-secrets.ps1. Not recommended; default is to scan.

.PARAMETER BackupRoot
    Passed to scripts/backup.ps1 when -Apply creates the mandatory pre-change backup.

.PARAMETER HomeRoot
    Home directory used to resolve live skill paths. Defaults to $env:USERPROFILE.

.PARAMETER OpenClawLiveSkillsPath
    Optional override for the OpenClaw live skills target directory.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $DryRun,
    [switch] $SkipBuild,
    [switch] $SkipSecretScan,
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [string] $OpenClawLiveSkillsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$reportHelper = Join-Path $PSScriptRoot 'report-common.ps1'
if (Test-Path -LiteralPath $reportHelper) {
    . $reportHelper
}
else {
    Write-Warning "Report helper missing: $reportHelper"
}
$HomeRoot = if (Test-Path -LiteralPath $HomeRoot) {
    (Resolve-Path -LiteralPath $HomeRoot).Path
} else {
    [System.IO.Path]::GetFullPath($HomeRoot)
}
$CodexSystemDirName = '.system'

# ---------------------------------------------------------------------------
# Path probing
# ---------------------------------------------------------------------------

function Get-ClaudeLiveSkillsPath {
    return (Join-Path $HomeRoot '.claude\skills')
}

function Get-CodexLiveSkillsPath {
    # Probe ~/.codex/skills first, then ~/.agents/skills; do not assume the latter.
    $codex = Join-Path $HomeRoot '.codex\skills'
    $agents = Join-Path $HomeRoot '.agents\skills'
    if (Test-Path -LiteralPath $codex) { return $codex }
    if (Test-Path -LiteralPath $agents) { return $agents }
    return $codex  # conventional default; created on -Apply if needed
}

function Get-OpenClawLiveSkillsPath {
    if ($OpenClawLiveSkillsPath) { return $OpenClawLiveSkillsPath }
    return (Join-Path $HomeRoot '.openclaw\skills')
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

function Sync-OneSkillDir-WithClawhubPreservation {
    # Same as Sync-OneSkillDir but preserves any live .clawhub dirs that
    # the generated source does not include (OpenClaw-specific).
    param(
        [Parameter(Mandatory)] [string] $SourceSkillDir,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $Name
    )

    $dest = Join-Path $LiveRoot $Name
    Assert-SafeLiveSkillTarget -LiveRoot $LiveRoot -Path $dest
    $destFull = [System.IO.Path]::GetFullPath($dest)

    # Preserve any .clawhub dirs from the live skill before deletion.
    $preservedClawhubDirs = @()
    if (Test-Path -LiteralPath $dest) {
        $clawhubDirs = @(Get-ChildItem -LiteralPath $dest -Directory -Recurse -Depth 4 -Filter '.clawhub' -ErrorAction SilentlyContinue)
        foreach ($dir in $clawhubDirs) {
            $relativePath = $dir.FullName.Substring($destFull.Length).TrimStart('\', '/')
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "clawhub-preserve-$([System.Guid]::NewGuid())"
            $tempTarget = Join-Path $tempDir $relativePath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tempTarget) | Out-Null
            Copy-Item -LiteralPath $dir.FullName -Destination $tempTarget -Recurse -Force
            $preservedClawhubDirs += [pscustomobject]@{ TempDir = $tempDir; RelativePath = $relativePath }
        }
        Remove-Item -LiteralPath $dest -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $LiveRoot | Out-Null
    Copy-Item -LiteralPath $SourceSkillDir -Destination $dest -Recurse

    # Restore preserved .clawhub dirs if source does not already include them.
    foreach ($p in $preservedClawhubDirs) {
        $restoreTarget = Join-Path $dest $p.RelativePath
        if (-not (Test-Path -LiteralPath $restoreTarget)) {
            $source = Join-Path $p.TempDir $p.RelativePath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $restoreTarget) | Out-Null
            Copy-Item -LiteralPath $source -Destination $restoreTarget -Recurse -Force
        }
        Remove-Item -LiteralPath $p.TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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

function Read-ManagedNames {
    param([Parameter(Mandatory)] [string] $Path)
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            $t = $line.Trim()
            if ($t) { [void] $names.Add($t) }
        }
    }
    # Comma keeps the HashSet intact: a bare return enumerates it, and an EMPTY
    # set would unroll to automation-null, breaking .Count under StrictMode.
    return , $names
}

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
        # AllowEmptyCollection: an env staging tree may legitimately manage zero
        # skills for a platform (empty manifest -> plan no actions for it).
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $ManagedNames
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

function Write-SyncRunReport {
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'WARN', 'FAIL')] [string] $Result,
        [Parameter(Mandatory)] [string] $NextAction,
        [object[]] $Plans = @(),
        [string] $BuildResult = 'Not run',
        [string] $SecretsScanResult = 'Not run',
        [AllowNull()] [System.Collections.IDictionary] $AppliedCounts,
        [string] $SystemStatus = 'Not available'
    )

    if (-not (Get-Command Write-RunReport -ErrorAction SilentlyContinue)) {
        return
    }

    $planAdded = 0
    $planModified = 0
    $planRemoved = 0
    $planUnknown = 0
    $addedDetails = [System.Collections.Generic.List[string]]::new()
    $modifiedDetails = [System.Collections.Generic.List[string]]::new()
    $removedDetails = [System.Collections.Generic.List[string]]::new()
    $unknownDetails = [System.Collections.Generic.List[string]]::new()
    foreach ($plan in @($Plans)) {
        $planAdded += @($plan.Add).Count
        $planModified += @($plan.Update).Count
        $planRemoved += @($plan.Prune).Count
        $planUnknown += @($plan.Unknown).Count
        foreach ($name in @($plan.Add)) { $addedDetails.Add("ADD: $($plan.Platform)/$name") }
        foreach ($name in @($plan.Update)) { $modifiedDetails.Add("MODIFY: $($plan.Platform)/$name") }
        foreach ($name in @($plan.Prune)) { $removedDetails.Add("REMOVE: $($plan.Platform)/$name") }
        foreach ($name in @($plan.Unknown)) { $unknownDetails.Add("SKIPPED UNKNOWN (preserved): $($plan.Platform)/$name") }
    }

    $addedValue = if (@($Plans).Count -gt 0) { $planAdded } else { 'Not available' }
    $modifiedValue = if (@($Plans).Count -gt 0) { $planModified } else { 'Not available' }
    $removedValue = if (@($Plans).Count -gt 0) { $planRemoved } else { 'Not available' }
    if ($Apply -and $null -ne $AppliedCounts) {
        $addedValue = [int] $AppliedCounts.ClaudeAdded + [int] $AppliedCounts.CodexAdded + [int] $AppliedCounts.OpenClawAdded
        $modifiedValue = [int] $AppliedCounts.ClaudeUpdated + [int] $AppliedCounts.CodexUpdated + [int] $AppliedCounts.OpenClawUpdated
        $removedValue = [int] $AppliedCounts.ClaudePruned + [int] $AppliedCounts.CodexPruned + [int] $AppliedCounts.OpenClawPruned
    }

    if ($SystemStatus -eq 'Not available') {
        $codexPlanForReport = @($Plans | Where-Object Platform -eq 'codex' | Select-Object -First 1)
        if ($codexPlanForReport.Count -gt 0) {
            $SystemStatus = if ($codexPlanForReport[0].SystemPreserved) { 'PRESERVED' } else { 'Not present' }
        }
    }

    $mode = if ($Apply) { 'apply' } else { 'dry-run' }
    $removalSection = if (-not $Apply) { 'Removed items (planned)' }
        elseif ($Result -eq 'PASS' -or $Result -eq 'WARN') { 'Removed items (applied or attempted)' }
        else { 'Removed items (planned; inspect result before assuming application)' }

    $summary = [ordered] @{
        Added = $addedValue
        Modified = $modifiedValue
        Removed = $removedValue
        Skipped = if (@($Plans).Count -gt 0) { $planUnknown } else { 'Not available' }
        Conflicts = 'Not available'
        Quarantined = 'Not available'
        'Unknown live skills' = if (@($Plans).Count -gt 0) { $planUnknown } else { 'Not available' }
        '.system status' = $SystemStatus
        'Secrets scan result' = $SecretsScanResult
        'Build result' = $BuildResult
    }
    $details = [ordered] @{
        'Added items' = @($addedDetails)
        'Modified items' = @($modifiedDetails)
        $removalSection = @($removedDetails)
        'Skipped and unknown live skills' = @($unknownDetails)
        '.system' = @("${SystemStatus}: preserved-required; sync report never contains .system contents.")
    }

    try {
        $reportPath = Write-RunReport -RepoRoot $RepoRoot -ReportKind 'sync' -ScriptName 'scripts/sync.ps1' -Mode $mode -Summary $summary -Details $details -Result $Result -NextAction $NextAction
        Write-Host "Sync report: $reportPath"
    }
    catch {
        Write-Warning "Sync completed its original flow, but report creation failed: $($_.Exception.Message)"
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

$buildRunResult = 'Not run'
$secretsScanRunResult = 'Not run'
$syncPlans = @()

if ($Apply -and $DryRun) {
    Write-Host 'ERROR: -Apply and -DryRun cannot be used together.'
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Choose exactly one mode: -DryRun or -Apply.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 1
}

$claudeSource = Join-Path $RepoRoot 'claude\skills'
$codexSource = Join-Path $RepoRoot 'codex\skills'
$openclawSource = Join-Path $RepoRoot 'openclaw\skills'
$claudeLive = Get-ClaudeLiveSkillsPath
$codexLive = Get-CodexLiveSkillsPath
$openclawLive = Get-OpenClawLiveSkillsPath

Write-Host '=== sync.ps1 ==='
Write-Host "Mode            : $(if ($Apply) { 'APPLY' } else { 'DRY-RUN (no changes)' })"
Write-Host "Repo            : $RepoRoot"
Write-Host "Claude source   : $claudeSource"
Write-Host "Codex source    : $codexSource"
Write-Host "OpenClaw source : $openclawSource"
Write-Host "Claude live     : $claudeLive"
Write-Host "Codex live      : $codexLive"
Write-Host "OpenClaw live   : $openclawLive"

# --- build ---
if ($SkipBuild) {
    Write-Host 'Build           : SKIPPED (-SkipBuild)'
    $buildRunResult = 'SKIPPED (-SkipBuild)'
} else {
    Write-Host 'Build           : running build-skills.ps1 ...'
    $code = Invoke-ChildScript -ScriptName 'build-skills.ps1'
    if ($code -ne 0) {
        $buildRunResult = "FAIL (exit $code)"
        Write-Host "ERROR: build-skills.ps1 failed (exit $code)."
        Write-SyncRunReport -Result 'FAIL' -NextAction 'Resolve the build failure, then rerun sync in dry-run mode.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
        exit 1
    }
    $buildRunResult = 'PASS'
    Write-Host 'Build           : OK'
}

# --- secret scan ---
if ($SkipSecretScan) {
    Write-Host 'Secret scan     : SKIPPED (-SkipSecretScan)'
    $secretsScanRunResult = 'SKIPPED (-SkipSecretScan)'
} else {
    Write-Host 'Secret scan     : running scan-secrets.ps1 ...'
    $code = Invoke-ChildScript -ScriptName 'scan-secrets.ps1'
    if ($code -ne 0) {
        $secretsScanRunResult = "FAIL (exit $code)"
        Write-Host "ERROR: scan-secrets.ps1 failed (exit $code)."
        Write-SyncRunReport -Result 'FAIL' -NextAction 'Remove or resolve the blocking secret finding, then rerun sync in dry-run mode.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
        exit 1
    }
    $secretsScanRunResult = 'PASS'
    Write-Host 'Secret scan     : OK'
}

if (-not (Test-Path -LiteralPath $claudeSource) -or -not (Test-Path -LiteralPath $codexSource) -or -not (Test-Path -LiteralPath $openclawSource)) {
    Write-Host 'ERROR: generated output missing. Run build-skills.ps1 (do not pass -SkipBuild).'
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Restore generated output by running build-skills.ps1, then rerun sync in dry-run mode.' -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 1
}

# --- managed-skills manifests (per-platform) ---
$claudeManagedNames = Read-ManagedNames -Path (Join-Path $RepoRoot 'manifests\managed-skills.claude.txt')
$codexManagedNames = Read-ManagedNames -Path (Join-Path $RepoRoot 'manifests\managed-skills.codex.txt')
$openclawManagedNames = Read-ManagedNames -Path (Join-Path $RepoRoot 'manifests\managed-skills.openclaw.txt')
Write-Host "Managed skills  : Claude=$($claudeManagedNames.Count)  Codex=$($codexManagedNames.Count)  OpenClaw=$($openclawManagedNames.Count)"

# --- plans ---
$claudePlan = Get-SyncPlan -Platform 'claude' -SourceRoot $claudeSource -LiveRoot $claudeLive -ManagedNames $claudeManagedNames
$codexPlan = Get-SyncPlan -Platform 'codex' -SourceRoot $codexSource -LiveRoot $codexLive -ManagedNames $codexManagedNames
$openclawPlan = Get-SyncPlan -Platform 'openclaw' -SourceRoot $openclawSource -LiveRoot $openclawLive -ManagedNames $openclawManagedNames
$syncPlans = @($claudePlan, $codexPlan, $openclawPlan)

Write-Host ''
Write-Host '----- PLAN -----'
Write-Host "Backup before apply: $(if ($Apply) { "YES (mandatory) under $BackupRoot" } else { 'n/a (dry-run)' })"
Write-PlanReport -Plan $claudePlan
Write-PlanReport -Plan $codexPlan
Write-PlanReport -Plan $openclawPlan

$totalChanges = $claudePlan.Add.Count + $claudePlan.Update.Count + $claudePlan.Prune.Count +
                $codexPlan.Add.Count + $codexPlan.Update.Count + $codexPlan.Prune.Count +
                $openclawPlan.Add.Count + $openclawPlan.Update.Count + $openclawPlan.Prune.Count

Write-Host ''
Write-Host '----- SUMMARY -----'
Write-Host "Claude   : +$($claudePlan.Add.Count) ~$($claudePlan.Update.Count) -$($claudePlan.Prune.Count)  (unknown ignored: $($claudePlan.Unknown.Count))"
Write-Host "Codex    : +$($codexPlan.Add.Count) ~$($codexPlan.Update.Count) -$($codexPlan.Prune.Count)  (unknown ignored: $($codexPlan.Unknown.Count); .system preserved: $($codexPlan.SystemPreserved))"
Write-Host "OpenClaw : +$($openclawPlan.Add.Count) ~$($openclawPlan.Update.Count) -$($openclawPlan.Prune.Count)  (unknown ignored: $($openclawPlan.Unknown.Count))"

# --- Plugin sync (dry-run) ---
$pluginSyncScript = Join-Path $PSScriptRoot 'sync-openclaw-plugins.ps1'
if (Test-Path -LiteralPath $pluginSyncScript) {
    $managedPluginsPath = Join-Path $RepoRoot 'openclaw\plugins\managed-plugins.json'
    if (Test-Path -LiteralPath $managedPluginsPath) {
        Write-Host ''
        Write-Host '----- PLUGIN SYNC (dry-run) -----'
        $pluginCode = Invoke-ChildScript -ScriptName 'sync-openclaw-plugins.ps1' -Arguments @('-RepoRoot', $RepoRoot, '-HomeRoot', $HomeRoot)
        if ($pluginCode -ne 0) {
            Write-Host "ERROR: sync-openclaw-plugins.ps1 dry-run failed (exit $pluginCode)."
            Write-SyncRunReport -Result 'FAIL' -NextAction 'Resolve the OpenClaw plugin dry-run failure, then rerun sync in dry-run mode.' -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
            exit $pluginCode
        }
    }
}

if (-not $Apply) {
    Write-Host ''
    Write-Host 'DRY-RUN complete. No live files were changed. Re-run with -Apply to execute.'
    $dryRunWarnings = $claudePlan.Prune.Count + $codexPlan.Prune.Count + $openclawPlan.Prune.Count +
                      $claudePlan.Unknown.Count + $codexPlan.Unknown.Count + $openclawPlan.Unknown.Count
    $dryRunResult = if ($dryRunWarnings -gt 0) { 'WARN' } else { 'PASS' }
    $dryRunNext = if ($dryRunWarnings -gt 0) {
        'Review every planned removal and unknown live skill; rerun dry-run after resolving unexpected items.'
    }
    else {
        'Review the report; use -Apply only when the plan is expected and a backup will be created.'
    }
    Write-SyncRunReport -Result $dryRunResult -NextAction $dryRunNext -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult
    exit 0
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '----- APPLY -----'

# 1) Mandatory backup first.
Write-Host 'Creating mandatory pre-change backup ...'
$backupOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'backup.ps1') -BackupRoot $BackupRoot -RepoRoot $RepoRoot -HomeRoot $HomeRoot 2>&1
$backupCode = $LASTEXITCODE
$backupOut | ForEach-Object { Write-Host "  [backup] $_" }
if ($backupCode -ne 0) {
    Write-Host "ERROR: backup failed (exit $backupCode). Aborting before any change."
    $zeroApplied = [ordered] @{ ClaudeAdded = 0; ClaudeUpdated = 0; ClaudePruned = 0; CodexAdded = 0; CodexUpdated = 0; CodexPruned = 0; OpenClawAdded = 0; OpenClawUpdated = 0; OpenClawPruned = 0 }
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Resolve the backup failure before any sync Apply.' -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult -AppliedCounts $zeroApplied
    exit 1
}
$backupLine = $backupOut | Where-Object { $_ -is [string] -and $_ -match '^BACKUP_DIR=' } | Select-Object -Last 1
$backupDir = if ($backupLine) { ($backupLine -replace '^BACKUP_DIR=', '').Trim() } else { '<unknown>' }
Write-Host "Backup path     : $backupDir"

# 2) Apply per-platform, one skill dir at a time.
$applied = [ordered] @{ ClaudeAdded = 0; ClaudeUpdated = 0; ClaudePruned = 0; CodexAdded = 0; CodexUpdated = 0; CodexPruned = 0; OpenClawAdded = 0; OpenClawUpdated = 0; OpenClawPruned = 0 }

foreach ($plan in @($claudePlan, $codexPlan, $openclawPlan)) {
    New-Item -ItemType Directory -Force -Path $plan.LiveRoot | Out-Null
    foreach ($name in $plan.Add) {
        Sync-OneSkillDir -SourceSkillDir (Join-Path $plan.SourceRoot $name) -LiveRoot $plan.LiveRoot -Name $name
        if ($plan.Platform -eq 'claude') { $applied.ClaudeAdded++ }
        elseif ($plan.Platform -eq 'openclaw') { $applied.OpenClawAdded++ }
        else { $applied.CodexAdded++ }
    }
    foreach ($name in $plan.Update) {
        if ($plan.Platform -eq 'openclaw') {
            Sync-OneSkillDir-WithClawhubPreservation -SourceSkillDir (Join-Path $plan.SourceRoot $name) -LiveRoot $plan.LiveRoot -Name $name
            $applied.OpenClawUpdated++
        } else {
            Sync-OneSkillDir -SourceSkillDir (Join-Path $plan.SourceRoot $name) -LiveRoot $plan.LiveRoot -Name $name
            if ($plan.Platform -eq 'claude') { $applied.ClaudeUpdated++ } else { $applied.CodexUpdated++ }
        }
    }
    foreach ($name in $plan.Prune) {
        Remove-OneSkillDir -LiveRoot $plan.LiveRoot -Name $name
        if ($plan.Platform -eq 'claude') { $applied.ClaudePruned++ }
        elseif ($plan.Platform -eq 'openclaw') { $applied.OpenClawPruned++ }
        else { $applied.CodexPruned++ }
    }
}

Write-Host ''
Write-Host "Claude   applied: +$($applied.ClaudeAdded) ~$($applied.ClaudeUpdated) -$($applied.ClaudePruned)"
Write-Host "Codex    applied: +$($applied.CodexAdded) ~$($applied.CodexUpdated) -$($applied.CodexPruned)"
Write-Host "OpenClaw applied: +$($applied.OpenClawAdded) ~$($applied.OpenClawUpdated) -$($applied.OpenClawPruned)"

# 3) Verification.
$codexMarker = Join-Path $codexLive '.system\.codex-system-skills.marker'
$systemOk = Test-Path -LiteralPath $codexMarker
Write-Host ".system marker preserved: $systemOk"

function Test-Parity {
    param([string] $SourceRoot, [string] $LiveRoot, [bool] $ExcludeSystem, [System.Collections.Generic.HashSet[string]] $ManagedNames)
    $src = @(Get-DirNames -Path $SourceRoot | Sort-Object)
    $live = @(Get-DirNames -Path $LiveRoot | Where-Object { -not ($ExcludeSystem -and $_ -eq $CodexSystemDirName) } | Sort-Object)
    # Filter whenever a managed set is provided — including an EMPTY set, where
    # the managed portion of live is trivially in sync (unknown dirs are
    # ignored-never-deleted and must not fail parity).
    if ($null -ne $ManagedNames) {
        $live = @($live | Where-Object { $ManagedNames.Contains($_) })
    }
    return (-not (Compare-Object $src $live))
}

# Parity is scoped to each platform's managed set (matching OpenClaw): unknown
# live dirs are ignored-never-deleted by contract, so they must not fail the
# post-apply check either.
$claudeParity = Test-Parity -SourceRoot $claudeSource -LiveRoot $claudeLive -ExcludeSystem $false -ManagedNames $claudeManagedNames
$codexParity = Test-Parity -SourceRoot $codexSource -LiveRoot $codexLive -ExcludeSystem $true -ManagedNames $codexManagedNames
$openclawParity = Test-Parity -SourceRoot $openclawSource -LiveRoot $openclawLive -ExcludeSystem $false -ManagedNames $openclawManagedNames
Write-Host "Claude   live-vs-repo: $(if ($claudeParity) { 'OK' } else { 'MISMATCH' })"
Write-Host "Codex    live-vs-repo: $(if ($codexParity) { 'OK (excl .system)' } else { 'MISMATCH' })"
Write-Host "OpenClaw live-vs-repo: $(if ($openclawParity) { 'OK (managed only)' } else { 'MISMATCH' })"

if (-not $systemOk -and (Get-DirNames -Path $codexLive) -contains $CodexSystemDirName) {
    Write-Host 'WARNING: .system dir present but marker missing — investigate.'
}
$systemReportStatus = if ((Get-DirNames -Path $codexLive) -contains $CodexSystemDirName) {
    if ($systemOk) { 'PRESERVED (marker present)' } else { 'PRESERVED-REQUIRED (marker missing)' }
}
else {
    'Not present'
}
if (-not $claudeParity -or -not $codexParity -or -not $openclawParity) {
    Write-Host "ERROR: post-apply parity check failed. Backup is at: $backupDir"
    Write-SyncRunReport -Result 'FAIL' -NextAction 'Inspect parity mismatches and recover from the existing backup if necessary.' -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult -AppliedCounts $applied -SystemStatus $systemReportStatus
    exit 1
}

# --- Plugin sync (apply) ---
$pluginSyncScript = Join-Path $PSScriptRoot 'sync-openclaw-plugins.ps1'
if (Test-Path -LiteralPath $pluginSyncScript) {
    $managedPluginsPath = Join-Path $RepoRoot 'openclaw\plugins\managed-plugins.json'
    if (Test-Path -LiteralPath $managedPluginsPath) {
        $defaultHomeRoot = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
        $currentHomeRoot = [System.IO.Path]::GetFullPath($HomeRoot).TrimEnd('\', '/')
        if ($currentHomeRoot -ne $defaultHomeRoot) {
            Write-Host ''
            Write-Host "Plugin sync apply skipped for custom HomeRoot: $HomeRoot"
            Write-Host 'Plugin lifecycle commands target the real OpenClaw CLI profile; use the default HomeRoot for live plugin apply.'
        } else {
            Write-Host ''
            Write-Host '----- PLUGIN SYNC (apply) -----'
            $pluginResult = & pwsh -NoProfile -File $pluginSyncScript -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Apply 2>&1
            $pluginCode = $LASTEXITCODE
            $pluginResult | ForEach-Object { Write-Host $_ }
            if ($pluginCode -ne 0) {
                Write-Host "ERROR: sync-openclaw-plugins.ps1 -Apply failed (exit $pluginCode). Backup: $backupDir"
                Write-SyncRunReport -Result 'FAIL' -NextAction 'Inspect the OpenClaw plugin failure; managed skill sync already ran, so review current state before retrying.' -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult -AppliedCounts $applied -SystemStatus $systemReportStatus
                exit $pluginCode
            }
        }
    }
}

Write-Host ''
Write-Host "APPLY complete. Backup: $backupDir"
$applyUnknown = $claudePlan.Unknown.Count + $codexPlan.Unknown.Count + $openclawPlan.Unknown.Count
$applyReportResult = if ($applyUnknown -gt 0 -or $systemReportStatus -like '*marker missing*') { 'WARN' } else { 'PASS' }
$applyNextAction = if ($applyReportResult -eq 'WARN') {
    'Review preserved unknown skills and .system status, then run the secret scan and git status.'
}
else {
    'Run scripts/scan-secrets.ps1 and git status, then record the verified machine state.'
}
Write-SyncRunReport -Result $applyReportResult -NextAction $applyNextAction -Plans $syncPlans -BuildResult $buildRunResult -SecretsScanResult $secretsScanRunResult -AppliedCounts $applied -SystemStatus $systemReportStatus
exit 0
