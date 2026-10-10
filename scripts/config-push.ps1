#requires -Version 7.0
<#
.SYNOPSIS
    Capture live home config (PushItems in manifests/whitelist.psd1) into the repo.
    Dry-run unless -Apply is given; never commits.

.DESCRIPTION
    Plans an add (absent in the repo) or update (content differs; home wins) for every
    managed file. Claude is read from ~/.claude, Codex from ~/.codex and Reasonix from
    %APPDATA%\reasonix, and written under claude/, codex/ and reasonix/ in the repo.
    Directories are copied file-by-file and never pruned: repo-only files stay
    untouched. ExcludedItems and CommonExcludedItems are never captured.

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
    One or more of Claude, Codex, Reasonix. Defaults to Claude, Codex.

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
    [ValidateSet('Claude', 'Codex', 'Reasonix')]
    [string[]] $Platform = @('Claude', 'Codex'),
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [switch] $SkipSecretScan,
    [switch] $SkipPathScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'config-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

function Find-MachinePrivatePaths {
    # Scan only the just-captured files (not the whole tree, which legitimately
    # references repo-local example paths) for machine-private absolute paths the
    # token-only secret scan does not catch. The drive-letter pattern uses a
    # negative lookbehind so URL schemes like https:// are not mistaken for "s:/".
    param([Parameter(Mandatory)] [System.Collections.IEnumerable] $Operations)
    $patterns = @(
        @{ Name = 'Drive-absolute path'; Regex = '(?<![A-Za-z])[A-Za-z]:[\\/]' },
        @{ Name = 'UNC path'; Regex = '\\\\[A-Za-z0-9?.$_-]' }
    )
    $binaryExt = @('.png', '.jpg', '.jpeg', '.gif', '.pdf', '.zip', '.7z', '.exe', '.dll', '.sqlite', '.db')
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($op in $Operations) {
        if (-not (Test-Path -LiteralPath $op.Dst -PathType Leaf)) { continue }
        if ([System.IO.Path]::GetExtension($op.Dst).ToLowerInvariant() -in $binaryExt) { continue }
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

$plan = [System.Collections.Generic.List[object]]::new()
foreach ($target in (Get-ConfigTargets -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -ItemKeys 'PushItems')) {
    foreach ($item in $target.Items) {
        $ops = Get-PlannedCopies `
            -SrcItem (Join-Path $target.HomeRoot $item) `
            -DstItem (Join-Path $target.RepoRoot $item) `
            -ItemLabel "$($target.Name)/$item" `
            -Excluded $target.Excluded
        foreach ($op in $ops) { $plan.Add($op) }
    }
}

Write-Host "config-push (home $HomeRoot -> repo)  scope: $($Platform -join ', ')" -ForegroundColor Cyan
if ($plan.Count -eq 0) {
    Write-Host 'Nothing to capture: repo already matches the managed home config.' -ForegroundColor DarkGray
    Write-Host ('Mode: ' + ($(if ($Apply) { 'APPLY (no changes needed)' } else { 'dry-run' })))
    return
}

Write-CopyPlan -Plan $plan
$grouped = $plan | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ("Plan: " + ($grouped -join '  '))

if (-not $Apply) {
    Write-Host 'Dry-run only. Re-run with -Apply to capture (secret scan gates the result).' -ForegroundColor DarkGray
    return
}

# Apply: stage originals -> write -> secret scan -> path scan -> keep or revert.
# The stage dir is created lazily so pure-add runs leave no empty backup folder.
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
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
    foreach ($op in $plan) {
        $parent = Split-Path -Parent $op.Dst
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $op.Src -Destination $op.Dst -Force
    }
}
catch {
    Restore-Plan -Operations $plan
    throw "Write failed; reverted all captured files. $($_.Exception.Message)"
}

if (-not $SkipSecretScan) {
    Write-Host 'Running secret scan over the captured tree...' -ForegroundColor Cyan
    $scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scan -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        Restore-Plan -Operations $plan
        throw 'Secret scan reported a blocking finding. Reverted all captured files; nothing secret-bearing was kept.'
    }
}

if (-not $SkipPathScan) {
    Write-Host 'Scanning captured files for machine-private paths...' -ForegroundColor Cyan
    $pathFindings = @(Find-MachinePrivatePaths -Operations $plan)
    if ($pathFindings.Count -gt 0) {
        Write-Host 'ERROR: machine-private absolute path(s) found in captured config:' -ForegroundColor Red
        $pathFindings | Format-Table -AutoSize | Out-String | Write-Host
        Restore-Plan -Operations $plan
        throw 'Captured config contains machine-private paths. Reverted all captured files. Review the source, or re-run with -SkipPathScan if the paths are intentional.'
    }
}

Write-CopyPlan -Plan $plan
Write-Host "Captured $($plan.Count) file(s) into the repo (UNCOMMITTED). Review with 'git diff' before committing." -ForegroundColor Cyan
Write-Host 'Repo-only files were left untouched (no prune).' -ForegroundColor DarkGray
