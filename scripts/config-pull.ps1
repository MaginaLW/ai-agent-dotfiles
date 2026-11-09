#requires -Version 7.0
<#
.SYNOPSIS
    Deploy repo-managed config (PullItems in manifests/whitelist.psd1) into the live
    home directories. Dry-run unless -Apply is given.

.DESCRIPTION
    Plans an add (absent in home) or update (content differs; repo wins) for every
    managed file. Claude writes to ~/.claude and Codex to ~/.codex.
    Directories are copied file-by-file and never pruned:
    home-only files stay untouched. ExcludedItems and CommonExcludedItems are skipped.

    Claude settings.json is merged object-by-object so home-only fields survive; repo
    arrays replace the corresponding home array. Codex AGENTS.md uses one marked managed
    block and leaves content outside it untouched.

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
    One or more of Claude, Codex. Defaults to both.

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
    [ValidateSet('Claude', 'Codex')]
    [string[]] $Platform = @('Claude', 'Codex'),
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [switch] $SkipSecretScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'config-common.ps1')
. (Join-Path $PSScriptRoot 'repo-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

function Get-ConfigPullPlan {
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($target in (Get-ConfigTargets -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -ItemKeys 'PullItems')) {
        foreach ($item in $target.Items) {
            $repoItem = Join-Path $target.RepoRoot $item
            $homeItem = Join-Path $target.HomeRoot $item
            if (-not (Test-Path -LiteralPath $repoItem)) { continue }
            if ($target.Name -eq 'Claude' -and $item -eq 'settings.json') {
                if (-not (Test-Path -LiteralPath $repoItem -PathType Leaf)) { throw 'Claude/settings.json source is not a file.' }
                if (Test-Path -LiteralPath $homeItem -PathType Container) { throw 'Claude/settings.json destination is a directory.' }
                if (-not (Test-Path -LiteralPath $homeItem -PathType Leaf)) {
                    $plan.Add(@{ Src = $repoItem; Dst = $homeItem; Rel = 'Claude/settings.json'; Action = 'add'; Mode = 'copy' })
                    continue
                }
                $merge = Get-ClaudeSettingsMergeResult -RepoPath $repoItem -HomePath $homeItem
                if ($merge.Changed) {
                    $plan.Add(@{ Src = $repoItem; Dst = $homeItem; Rel = 'Claude/settings.json'; Action = 'update'; Mode = 'content'; Content = $merge.Content })
                }
                continue
            }
            if ($target.Name -eq 'Codex' -and $item -eq 'AGENTS.md') {
                if (-not (Test-Path -LiteralPath $repoItem -PathType Leaf)) { throw 'Codex/AGENTS.md source is not a file.' }
                if (Test-Path -LiteralPath $homeItem -PathType Container) { throw 'Codex/AGENTS.md destination is a directory.' }
                $homeExists = Test-Path -LiteralPath $homeItem -PathType Leaf
                $homeText = if ($homeExists) { [IO.File]::ReadAllText($homeItem) } else { '' }
                $block = Get-CodexAgentsManagedBlockResult -RepoText ([IO.File]::ReadAllText($repoItem)) -HomeText $homeText -HomeExists $homeExists
                if ($block.Changed) {
                    $action = if ($homeExists) { 'update' } else { 'add' }
                    $plan.Add(@{ Src = $repoItem; Dst = $homeItem; Rel = 'Codex/AGENTS.md'; Action = $action; Mode = 'content'; Content = $block.Content })
                }
                continue
            }
            $ops = Get-PlannedCopies `
                -SrcItem $repoItem `
                -DstItem $homeItem `
                -ItemLabel "$($target.Name)/$item" `
                -Excluded $target.Excluded
            foreach ($op in $ops) { $op.Mode = 'copy'; $plan.Add($op) }
        }
    }
    return , $plan.ToArray()
}

$plan = Get-ConfigPullPlan

Write-Host "config-pull (repo -> $HomeRoot)  scope: $($Platform -join ', ')" -ForegroundColor Cyan
if (@($plan | Where-Object { $_.Rel -eq 'Claude/settings.json' }).Count -gt 0) {
    Write-Host 'Claude/settings.json will be merged; home-only fields are preserved.' -ForegroundColor Yellow
}
if (@($plan | Where-Object { $_.Rel -eq 'Codex/AGENTS.md' }).Count -gt 0) {
    Write-Host 'Only the managed block in Codex/AGENTS.md will be updated; content outside it is preserved.' -ForegroundColor Yellow
}
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
        Invoke-ConfigPlanWrite -Plan @($op) -Progress
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
