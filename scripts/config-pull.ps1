#requires -Version 7.0
<#
.SYNOPSIS
    Deploy repo-managed harness config into the live home directories
    (repo -> ~/.claude, ~/.codex). Phase 2 of config-sync. Safe by default
    (dry-run); only mutates with -Apply.

.DESCRIPTION
    Source of truth for what is managed is manifests/whitelist.psd1 (PullItems per
    platform). For each managed item the script copies repo content into the live
    home location, computing an add / update plan:

        add      item (or file within it) exists in repo, absent in home
        update   exists in both, content differs -> repo wins
        (no-op)  identical -> skipped

    Hard safety rules (mirror sync.ps1's posture):
      * Never whole-dir mirror. Directories are copied file-by-file.
      * Never prune. Home-only files are left untouched and only reported.
      * -Apply runs a secret scan first and backs up every home file it is about
        to overwrite before writing. Both must pass.
      * The Codex platform .system dir is skills-only and never a config item, so
        it is structurally out of scope here.

    Scope defaults to Claude and Codex.

    There is no push (home -> repo) here; capture is a later phase.

.PARAMETER Apply
    Actually perform the copy. Without it the script is a pure dry-run.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory root for resolving live config paths. Defaults to $env:USERPROFILE.

.PARAMETER Platform
    One or more of Claude, Codex. Defaults to Claude, Codex.

.PARAMETER BackupRoot
    Root for the pre-overwrite backup created by -Apply. Defaults to
    $env:USERPROFILE\.ai-agent-dotfiles-backups. Must be outside the repository.

.PARAMETER SkipSecretScan
    Skip running scripts/scan-secrets.ps1 before -Apply. Not recommended.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [ValidateSet('Claude', 'Codex', 'Reasonix')]
    [string[]] $Platform = @('Claude', 'Codex'),
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [switch] $SkipSecretScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$whitelistPath = Join-Path $RepoRoot 'manifests/whitelist.psd1'
if (-not (Test-Path -LiteralPath $whitelistPath)) {
    throw "Missing manifest: $whitelistPath"
}
$whitelist = Import-PowerShellDataFile -LiteralPath $whitelistPath
$commonExcluded = @($whitelist.CommonExcludedItems)

# ---------------------------------------------------------------------------
# Helpers (kept self-contained, matching the repo's per-script style)
# ---------------------------------------------------------------------------

function Test-Excluded {
    param(
        [Parameter(Mandatory)] [string] $RelativePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Patterns
    )
    $rel = $RelativePath -replace '\\', '/'
    foreach ($pattern in $Patterns) {
        $pat = $pattern -replace '\\', '/'
        if ($rel -like $pat) { return $true }
        if ($rel -like "$pat/*") { return $true }
        foreach ($segment in ($rel -split '/')) {
            if ($segment -like $pat) { return $true }
        }
    }
    return $false
}

function Get-FileHashHex {
    param([Parameter(Mandatory)] [string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-PlannedCopies {
    # Returns a list of @{ Src; Dst; Rel; Action } for one managed item.
    param(
        [Parameter(Mandatory)] [string] $RepoItem,
        [Parameter(Mandatory)] [string] $HomeItem,
        [Parameter(Mandatory)] [string] $ItemLabel,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
    )
    $ops = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $RepoItem)) { return $ops }   # nothing in repo to deploy

    if (Test-Path -LiteralPath $RepoItem -PathType Leaf) {
        $action = if (-not (Test-Path -LiteralPath $HomeItem)) { 'add' }
        elseif ((Get-FileHashHex $RepoItem) -ne (Get-FileHashHex $HomeItem)) { 'update' }
        else { 'noop' }
        if ($action -ne 'noop') {
            $ops.Add(@{ Src = $RepoItem; Dst = $HomeItem; Rel = $ItemLabel; Action = $action })
        }
        return $ops
    }

    # directory: copy file-by-file, never prune
    $repoFull = (Resolve-Path -LiteralPath $RepoItem).Path
    $files = Get-ChildItem -LiteralPath $repoFull -File -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        $rel = $file.FullName.Substring($repoFull.Length).TrimStart('\', '/')
        if (Test-Excluded -RelativePath $rel -Patterns $Excluded) { continue }
        $dst = Join-Path $HomeItem $rel
        $action = if (-not (Test-Path -LiteralPath $dst)) { 'add' }
        elseif ((Get-FileHashHex $file.FullName) -ne (Get-FileHashHex $dst)) { 'update' }
        else { 'noop' }
        if ($action -ne 'noop') {
            $ops.Add(@{ Src = $file.FullName; Dst = $dst; Rel = "$ItemLabel/$($rel -replace '\\','/')"; Action = $action })
        }
    }
    return $ops
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

$plan = [System.Collections.Generic.List[object]]::new()
foreach ($name in $Platform) {
    $cfg = $whitelist.$name
    if (-not $cfg) { continue }
    $repoRootP = Join-Path $RepoRoot $cfg.RepoRelativeRoot
    $homeRootP = Join-Path $HomeRoot $cfg.HomeRelativeRoot
    $excluded = @($cfg.ExcludedItems) + $commonExcluded
    foreach ($item in (@($cfg.PullItems) | Select-Object -Unique)) {
        $ops = Get-PlannedCopies `
            -RepoItem (Join-Path $repoRootP $item) `
            -HomeItem (Join-Path $homeRootP $item) `
            -ItemLabel "$name/$item" `
            -Excluded $excluded
        foreach ($op in $ops) { $plan.Add($op) }
    }
}

Write-Host "config-pull (repo -> $HomeRoot)  scope: $($Platform -join ', ')" -ForegroundColor Cyan
if ($plan.Count -eq 0) {
    Write-Host 'Nothing to deploy: all managed config already in sync.' -ForegroundColor DarkGray
    Write-Host ('Mode: ' + ($(if ($Apply) { 'APPLY (no changes needed)' } else { 'dry-run' })))
    return
}

foreach ($op in $plan) {
    $color = if ($op.Action -eq 'add') { 'Green' } else { 'Yellow' }
    Write-Host ('  {0,-7} {1}' -f $op.Action, $op.Rel) -ForegroundColor $color
}
$grouped = $plan | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ("Plan: " + ($grouped -join '  '))

if (-not $Apply) {
    Write-Host 'Dry-run only. Re-run with -Apply to deploy.' -ForegroundColor DarkGray
    return
}

# ---------------------------------------------------------------------------
# Apply: secret scan gate -> backup overwritten files -> copy (no prune)
# ---------------------------------------------------------------------------

if (-not $SkipSecretScan) {
    Write-Host 'Running secret scan before apply...' -ForegroundColor Cyan
    $scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scan -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Secret scan failed (exit $LASTEXITCODE). Aborting apply; no files written."
    }
}

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$backupDir = Join-Path $BackupRoot "config-backup-$stamp"
$overwrites = @($plan | Where-Object { $_.Action -eq 'update' })
if ($overwrites.Count -gt 0) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    foreach ($op in $overwrites) {
        $rel = $op.Dst.Substring($HomeRoot.Length).TrimStart('\', '/')
        $bak = Join-Path $backupDir $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $bak) -Force | Out-Null
        Copy-Item -LiteralPath $op.Dst -Destination $bak -Force
    }
    Write-Host "Backed up $($overwrites.Count) file(s) to $backupDir" -ForegroundColor Cyan
}

foreach ($op in $plan) {
    $parent = Split-Path -Parent $op.Dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $op.Src -Destination $op.Dst -Force
    Write-Host ('  {0,-7} {1}' -f $op.Action, $op.Rel) -ForegroundColor Green
}
Write-Host "Applied $($plan.Count) change(s). Home-only files were left untouched (no prune)." -ForegroundColor Cyan
