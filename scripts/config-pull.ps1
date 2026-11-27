#requires -Version 7.0
<#
.SYNOPSIS
    Deploy repo-managed config (PullItems in manifests/whitelist.psd1) into the live
    home directories. Dry-run unless -Apply is given.

.DESCRIPTION
    Plans an add (absent in home) or update (content differs; repo wins) for every
    managed file. Codex writes to ~/.codex and Antigravity writes to ~/.gemini/config.
    Directories are copied file-by-file and never pruned:
    home-only files stay untouched. ExcludedItems and CommonExcludedItems are skipped.

    Each platform's AGENTS.md uses one marked managed block and preserves content outside it.

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
    One or more of Codex, Antigravity. Defaults to Codex.

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
    [string[]] $Platform = @('Codex'),
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [switch] $SkipSecretScan,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Json -and $Apply) {
    throw '-Json cannot be combined with -Apply.'
}

. (Join-Path $PSScriptRoot 'config-common.ps1')
. (Join-Path $PSScriptRoot 'repo-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Platform = Resolve-ConfigPlatforms -Values $Platform
$BackupRoot = Resolve-ConfigBackupRoot -RepoRoot $RepoRoot -BackupRoot $BackupRoot

function Get-ConfigPullPlan {
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($target in (Get-ConfigTargets -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -ItemKeys 'PullItems')) {
        foreach ($item in $target.Items) {
            $repoItem = Join-Path $target.RepoRoot $item
            $homeItem = Join-Path $target.HomeRoot $item
            if (-not (Test-Path -LiteralPath $repoItem)) { continue }
            $blockSpec = Get-ManagedAgentsBlockSpec -Platform $target.Name -Item $item
            if ($null -ne $blockSpec) {
                if (-not (Test-Path -LiteralPath $repoItem -PathType Leaf)) { throw "$($blockSpec.Label) source is not a file." }
                if (Test-Path -LiteralPath $homeItem -PathType Container) { throw "$($blockSpec.Label) destination is a directory." }
                $homeExists = Test-Path -LiteralPath $homeItem -PathType Leaf
                if (-not $homeExists -and $null -ne (Get-Item -LiteralPath $homeItem -Force -ErrorAction SilentlyContinue)) {
                    throw "$($blockSpec.Label) destination is not a readable file."
                }
                $srcHash = Get-FileHashHex $repoItem
                $dstHash = if ($homeExists) { Get-FileHashHex $homeItem } else { $null }
                $homeText = if ($homeExists) { [IO.File]::ReadAllText($homeItem) } else { '' }
                $block = Get-ManagedAgentsBlockResult -RepoText ([IO.File]::ReadAllText($repoItem)) -HomeText $homeText -HomeExists $homeExists -BlockId $blockSpec.BlockId -Label $blockSpec.Label
                if ($block.Changed) {
                    $action = if ($homeExists) { 'update' } else { 'add' }
                    $plan.Add(@{
                        Src               = $repoItem
                        Dst               = $homeItem
                        Rel               = $blockSpec.Label
                        Action            = $action
                        Mode              = 'content'
                        Content           = $block.Content
                        OriginalText      = $homeText
                        ExpectedSrcHash   = $srcHash
                        ExpectedDstExists = $homeExists
                        ExpectedDstHash   = $dstHash
                    })
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

if ($Json) {
    $summary = [ordered]@{
        add    = @($plan | Where-Object { $_.Action -eq 'add' }).Count
        update = @($plan | Where-Object { $_.Action -eq 'update' }).Count
    }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($op in $plan) {
        $items.Add([ordered]@{
            Rel              = [string] $op.Rel
            Action           = [string] $op.Action
            Mode             = [string] $op.Mode
            ManagedBlockOnly = ($op.Mode -eq 'content')
        })
    }
    $report = [ordered]@{
        SchemaVersion = 1
        Mode          = 'dry-run'
        Platforms     = @($Platform)
        Summary       = $summary
        Items         = $items.ToArray()
    }
    ConvertTo-Json -InputObject $report -Depth 10
    return
}

Write-Host "config-pull (repo -> $HomeRoot)  scope: $($Platform -join ', ')" -ForegroundColor Cyan
foreach ($managedLabel in @('Codex/AGENTS.md', 'Antigravity/AGENTS.md')) {
    if (@($plan | Where-Object { $_.Rel -eq $managedLabel }).Count -gt 0) {
        Write-Host "Only the managed block in $managedLabel will be updated; content outside it is preserved." -ForegroundColor Yellow
    }
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

foreach ($op in $plan) {
    Assert-ConfigPullOpUnchanged -Op $op
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
        Assert-ConfigPullOpUnchanged -Op $op
        if ($op.Mode -eq 'copy' -and $op.Action -eq 'update') {
            # A copy can change the destination before throwing.
            $attempted.Add($op)
            Invoke-ConfigPlanWrite -Plan @($op) -Progress
            continue
        }

        # CreateNew claims a planned add atomically. For a managed update, hold
        # the same handle while comparing and writing so an editor cannot race the check.
        $mode = [IO.FileMode]::Open
        if ($op.Action -eq 'add') {
            $parent = Split-Path -Parent $op.Dst
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            $mode = [IO.FileMode]::CreateNew
        }
        $stream = [IO.File]::Open($op.Dst, $mode, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try {
            if ($mode -eq [IO.FileMode]::Open) {
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 1024, $true)
                try { $current = $reader.ReadToEnd() } finally { $reader.Dispose() }
                if (-not [string]::Equals($current, $op.OriginalText, [StringComparison]::Ordinal)) {
                    throw "$($op.Rel) changed since planning. Run config pull again to review it."
                }
            }
            $attempted.Add($op)
            if ($op.Mode -eq 'content') {
                $bytes = [Text.Encoding]::UTF8.GetBytes($op.Content)
                $stream.Position = 0
                $stream.Write($bytes)
                $stream.SetLength($bytes.Length)
            }
            else {
                $source = [IO.File]::OpenRead($op.Src)
                try { $source.CopyTo($stream) } finally { $source.Dispose() }
            }
        }
        finally { $stream.Dispose() }
        Write-Host ('  {0,-7} {1}' -f $op.Action, $op.Rel) -ForegroundColor Green
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
