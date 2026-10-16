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
    <BackupRoot>\config-backup-<timestamp>\ before copying. A caught copy failure
    triggers best-effort rollback of attempted writes, then rethrows the original
    error. Failed restores warn and leave the backup available for manual recovery;
    forced process termination cannot run rollback.

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

. (Join-Path $PSScriptRoot 'config-common.ps1')
. (Join-Path $PSScriptRoot 'repo-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$plan = Get-ConfigSyncPlan -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -Direction Pull

Write-Host "config-pull (repo -> $HomeRoot)  scope: $($Platform -join ', ')" -ForegroundColor Cyan
if (-not (Show-ConfigSyncPlan -Plan $plan -EmptyMessage 'Nothing to deploy: all managed config already in sync.' -DryRunMessage 'Dry-run only. Re-run with -Apply to deploy.' -Apply:$Apply)) { return }

# Apply: secret scan gate -> back up overwritten home files -> copy (no prune).
if (-not $SkipSecretScan) {
    Write-Host 'Running secret scan before apply...' -ForegroundColor Cyan
    try { Invoke-SecretScanGate -RepoRoot $RepoRoot }
    catch {
        $detail = $_.Exception.Message
        $exit = if ($detail -match 'exit code (\d+)') { $Matches[1] } else { $null }
        if ($exit) { throw "Secret scan failed (exit $exit). Aborting apply; no files written." }
        throw "Secret scan failed. Aborting apply; no files written. ($detail)"
    }
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
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

$attempted = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($op in $plan) {
        # Include the failing item: a copy can change a destination before throwing.
        $attempted.Add($op)
        Invoke-ConfigPlanCopy -Plan @($op) -Progress
    }
}
catch {
    $copyError = $_
    Write-Warning "Config pull failed. Attempting best-effort rollback for $($attempted.Count) attempted file(s)."
    if ($overwrites.Count -gt 0) { Write-Warning "Original files are backed up in $backupDir" }
    for ($i = $attempted.Count - 1; $i -ge 0; $i--) {
        $op = $attempted[$i]
        try {
            if ($op.Action -eq 'update') {
                $rel = $op.Dst.Substring($HomeRoot.Length).TrimStart('\', '/')
                Copy-Item -LiteralPath (Join-Path $backupDir $rel) -Destination $op.Dst -Force
            }
            elseif (Test-Path -LiteralPath $op.Dst -PathType Leaf) {
                Remove-Item -LiteralPath $op.Dst -Force
            }
        }
        catch { Write-Warning "Rollback could not restore $($op.Dst): $($_.Exception.Message)" }
    }
    throw $copyError
}
Write-Host "Applied $($plan.Count) change(s). Home-only files were left untouched (no prune)." -ForegroundColor Cyan
