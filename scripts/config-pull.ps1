#requires -Version 7.0
<#
.SYNOPSIS
    Deploy repo-managed config (PullItems in manifests/whitelist.psd1) into the live
    home directories. Dry-run unless -Apply is given.

.DESCRIPTION
    Plans an add (absent in home) or update (content differs; repo wins) for every
    managed file. Claude writes to ~/.claude, Codex to ~/.codex and Reasonix to
    %APPDATA%\reasonix. Directories are copied file-by-file and never pruned:
    home-only files stay untouched. ExcludedItems and CommonExcludedItems are skipped.

    -Apply runs the secret scan first, then backs up every home file it overwrites to
    <BackupRoot>\config-backup-<timestamp>\ before copying.

.PARAMETER Apply
    Perform the copy. Without it the script only prints the plan.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory. Defaults to $env:USERPROFILE.

.PARAMETER Platform
    One or more of Claude, Codex, Reasonix. Defaults to Claude, Codex.

.PARAMETER BackupRoot
    Root for the pre-overwrite backup. Defaults to
    $env:USERPROFILE\.ai-agent-dotfiles-backups. Must be outside the repository.

.PARAMETER SkipSecretScan
    Skip scripts/scan-secrets.ps1 before -Apply. Not recommended.
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

. (Join-Path $PSScriptRoot 'config-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$plan = [System.Collections.Generic.List[object]]::new()
foreach ($target in (Get-ConfigTargets -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -ItemKeys 'PullItems')) {
    foreach ($item in $target.Items) {
        $ops = Get-PlannedCopies `
            -SrcItem (Join-Path $target.RepoRoot $item) `
            -DstItem (Join-Path $target.HomeRoot $item) `
            -ItemLabel "$($target.Name)/$item" `
            -Excluded $target.Excluded
        foreach ($op in $ops) { $plan.Add($op) }
    }
}

Write-Host "config-pull (repo -> $HomeRoot)  scope: $($Platform -join ', ')" -ForegroundColor Cyan
if ($plan.Count -eq 0) {
    Write-Host 'Nothing to deploy: all managed config already in sync.' -ForegroundColor DarkGray
    Write-Host ('Mode: ' + ($(if ($Apply) { 'APPLY (no changes needed)' } else { 'dry-run' })))
    return
}

Write-CopyPlan -Plan $plan
$grouped = $plan | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ("Plan: " + ($grouped -join '  '))

if (-not $Apply) {
    Write-Host 'Dry-run only. Re-run with -Apply to deploy.' -ForegroundColor DarkGray
    return
}

# Apply: secret scan gate -> back up overwritten home files -> copy (no prune).
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
