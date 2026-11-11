#requires -Version 7.0
<#
.SYNOPSIS
    Capture live home config (PushItems in manifests/whitelist.psd1) into the repo.
    Dry-run unless -Apply is given; never commits.

.DESCRIPTION
    Plans an add (absent in the repo) or update (content differs; home wins) for every
    managed file. Claude is read from ~/.claude and Codex from ~/.codex, and written
    under claude/ and codex/ in the repo.
    Directories are copied file-by-file and never pruned: repo-only files stay
    untouched. ExcludedItems and CommonExcludedItems are never captured.

    When Codex AGENTS.md contains the config-sync managed block, only that block's
    content is captured; personal content outside the block stays local.

    -Apply stages every repo file it overwrites to
    <BackupRoot>\config-push-stage-<timestamp>\, writes the capture, then runs two
    gates: scripts/scan-secrets.ps1 over the repo, and a scan of the captured files
    for drive-letter and UNC paths. If a write or a gate fails, every captured file is
    reverted (updates restored, adds deleted) and the script exits non-zero. On
    success the capture is left uncommitted for review with git diff.

.PARAMETER Apply
    Perform the capture. Without it the script only prints the plan.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory. Defaults to $env:USERPROFILE.

.PARAMETER Platform
    One or more of Claude, Codex. Defaults to Codex; Claude requires an explicit opt-in.

.PARAMETER BackupRoot
    Root for the revert stage. Defaults to $env:USERPROFILE\.ai-agent-dotfiles-backups.
    Must be outside the repository so the secret scan never inspects the originals.

.PARAMETER SkipSecretScan
    Skip the secret scan after writing. Not recommended; it defeats the gate.

.PARAMETER SkipPathScan
    Skip the machine-private path scan. Use only when a captured absolute path is
    intentional.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [ValidateSet('Claude', 'Codex')]
    [string[]] $Platform = @('Codex'),
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [switch] $SkipSecretScan,
    [switch] $SkipPathScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'config-common.ps1')
. (Join-Path $PSScriptRoot 'repo-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

function Find-MachinePrivatePaths {
    # Scan only the just-captured files (not the whole tree, which legitimately
    # references repo-local example paths) for machine-private absolute paths the
    # token-only secret scan does not catch. The drive-letter pattern uses a
    # negative lookbehind so URL schemes like https:// are not mistaken for "s:/".
    param([Parameter(Mandatory)] [System.Collections.IEnumerable] $Operations)
    $patterns = @(
        @{ Name = 'Drive-absolute path'; Regex = $script:DriveAbsolutePathPattern },
        @{ Name = 'UNC path'; Regex = $script:UncPathPattern }
    )
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($op in $Operations) {
        if (-not (Test-Path -LiteralPath $op.Dst -PathType Leaf)) { continue }
        if (Test-IsBinaryExtension -Path $op.Dst) { continue }
        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadLines($op.Dst)) {
            $lineNumber++
            foreach ($pattern in $patterns) {
                if ($line -match $pattern.Regex) {
                    $findings.Add([pscustomobject] @{ File = $op.Rel; Line = $lineNumber; Pattern = $pattern.Name })
                }
            }
        }
    }
    return $findings
}

function Restore-Plan {
    param([Parameter(Mandatory)] [System.Collections.IEnumerable] $Operations)
    foreach ($op in $Operations) {
        if ($op.Existed) {
            Copy-Item -LiteralPath $op.Stage -Destination $op.Dst -Force
        }
        elseif (Test-Path -LiteralPath $op.Dst) {
            Remove-Item -LiteralPath $op.Dst -Force
        }
    }
}

function Get-ConfigPushPlan {
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($target in (Get-ConfigTargets -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -ItemKeys 'PushItems')) {
        foreach ($item in $target.Items) {
            $homeItem = Join-Path $target.HomeRoot $item
            $repoItem = Join-Path $target.RepoRoot $item
            if (-not (Test-Path -LiteralPath $homeItem)) { continue }
            if ($target.Name -eq 'Codex' -and $item -eq 'AGENTS.md') {
                if (-not (Test-Path -LiteralPath $homeItem -PathType Leaf)) { throw 'Codex/AGENTS.md source is not a file.' }
                if (Test-Path -LiteralPath $repoItem -PathType Container) { throw 'Codex/AGENTS.md destination is a directory.' }
                $content = Get-CodexAgentsManagedContent -HomeText ([IO.File]::ReadAllText($homeItem))
                if ($null -ne $content) {
                    $exists = Test-Path -LiteralPath $repoItem -PathType Leaf
                    $same = $exists -and ([IO.File]::ReadAllText($repoItem) -ceq $content)
                    if (-not $same) {
                        $action = if ($exists) { 'update' } else { 'add' }
                        $plan.Add(@{ Src = $homeItem; Dst = $repoItem; Rel = 'Codex/AGENTS.md'; Action = $action; Mode = 'content'; Content = $content })
                    }
                    continue
                }
            }
            $ops = Get-PlannedCopies `
                -SrcItem $homeItem `
                -DstItem $repoItem `
                -ItemLabel "$($target.Name)/$item" `
                -Excluded $target.Excluded
            foreach ($op in $ops) { $op.Mode = 'copy'; $plan.Add($op) }
        }
    }
    return , $plan.ToArray()
}

$plan = Get-ConfigPushPlan

Write-Host "config-push (home $HomeRoot -> repo)  scope: $($Platform -join ', ')" -ForegroundColor Cyan
if (-not (Show-ConfigSyncPlan -Plan $plan -EmptyMessage 'Nothing to capture: repo already matches the managed home config.' -DryRunMessage 'Dry-run only. Re-run with -Apply to capture (secret scan gates the result).' -Apply:$Apply)) { return }

# Apply: stage originals -> write -> secret scan -> path scan -> keep or revert.
# The stage dir is created lazily so pure-add runs leave no empty backup folder.
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
$stageDir = Join-Path $BackupRoot "config-push-stage-$stamp"
$index = 0
foreach ($op in $plan) {
    $op.Existed = Test-Path -LiteralPath $op.Dst
    if ($op.Existed) {
        if (-not (Test-Path -LiteralPath $stageDir)) {
            New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
        }
        $op.Stage = Join-Path $stageDir ("{0:D4}.bak" -f $index)
        Copy-Item -LiteralPath $op.Dst -Destination $op.Stage -Force
    }
    $index++
}

try {
    Invoke-ConfigPlanWrite -Plan $plan
}
catch {
    Restore-Plan -Operations $plan
    throw "Write failed; reverted all captured files. $($_.Exception.Message)"
}

if (-not $SkipSecretScan) {
    Write-Host 'Running secret scan over the captured tree...' -ForegroundColor Cyan
    try { Invoke-SecretScanGate -RepoRoot $RepoRoot }
    catch {
        $detail = $_.Exception.Message
        Restore-Plan -Operations $plan
        throw "Secret scan failed. Reverted all captured files. $detail"
    }
}

if (-not $SkipPathScan) {
    Write-Host 'Scanning captured files for machine-private paths...' -ForegroundColor Cyan
    $pathFindings = @(Find-MachinePrivatePaths -Operations $plan)
    if ($pathFindings.Count -gt 0) {
        [Console]::Error.WriteLine('ERROR: machine-private absolute path(s) found in captured config:')
        $pathFindings | Format-Table -AutoSize | Out-String | Write-Host
        Restore-Plan -Operations $plan
        throw 'Captured config contains machine-private paths. Reverted all captured files. Review the source, or re-run with -SkipPathScan if the paths are intentional.'
    }
}

Write-CopyPlan -Plan $plan
Write-Host "Captured $($plan.Count) file(s) into the repo (UNCOMMITTED). Review with 'git diff' before committing." -ForegroundColor Cyan
Write-Host 'Repo-only files were left untouched (no prune).' -ForegroundColor DarkGray
