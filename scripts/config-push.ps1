#requires -Version 7.0
<#
.SYNOPSIS
    Capture live home harness config back into the repo source (home -> repo).
    Phase 3 of config-sync. Safe by default (dry-run); only mutates with -Apply,
    and never keeps a captured file that trips the secret scan.

.DESCRIPTION
    Source of truth for what is managed is manifests/whitelist.psd1 (PushItems per
    platform). For each managed item the script copies live home content into the
    repo, computing an add / update plan:

        add      item (or file within it) exists in home, absent in repo
        update   exists in both, content differs -> home wins
        (no-op)  identical -> skipped

    This is the secret-sensitive direction (home config can contain tokens), so the
    secret scan is a hard gate that runs AFTER the files land in the working tree
    (scan-secrets.ps1 scans the whole tree, including untracked files):

      * Before writing, each repo file that already exists is staged to BackupRoot
        so it can be restored.
      * After writing, scripts/scan-secrets.ps1 runs over the repo. If it reports a
        blocking secret, every captured file is REVERTED (updates restored from the
        stage, adds deleted) and the script aborts non-zero. Nothing secret-bearing
        is left in the tree.
      * The captured files are then scanned for machine-private absolute paths
        (drive-letter and UNC paths) that the secret scan does not catch. Any hit
        reverts everything the same way. Use -SkipPathScan if such a path is
        intentional.
      * On success the captured files are left UNCOMMITTED for human review; this
        script never commits.

    Hard safety rules (mirror sync.ps1's posture):
      * Never whole-dir mirror; directories are copied file-by-file.
      * Never prune; repo-only files are left untouched and only reported.
      * Per-platform ExcludedItems + CommonExcludedItems are skipped, so credentials,
        sessions, caches, history and other machine-private files are never captured.

    Scope defaults to Claude and Codex. OpenClaw is excluded by default (its plugin
    desired-state is owned by sync-openclaw-plugins.ps1); pass -Platform OpenClaw to
    include its managed-plugins.json deliberately.

.PARAMETER Apply
    Actually perform the capture. Without it the script is a pure dry-run.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory root for resolving live config paths. Defaults to $env:USERPROFILE.

.PARAMETER Platform
    One or more of Claude, Codex, OpenClaw. Defaults to Claude, Codex.

.PARAMETER BackupRoot
    Root for the revert stage created by -Apply. Defaults to
    $env:USERPROFILE\.ai-agent-dotfiles-backups. Must be outside the repository so the
    secret scan never inspects the staged originals.

.PARAMETER SkipSecretScan
    Skip the secret scan after writing. NOT recommended; defeats the gate.

.PARAMETER SkipPathScan
    Skip the machine-private path scan. Use only when a captured absolute path is
    intentional (e.g. a deliberately portable path).
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [ValidateSet('Claude', 'Codex', 'OpenClaw')]
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

function Get-PlannedCopies {
    # Returns a list of @{ Src; Dst; Rel; Action } capturing Src (home) into Dst (repo).
    param(
        [Parameter(Mandatory)] [string] $SrcItem,
        [Parameter(Mandatory)] [string] $DstItem,
        [Parameter(Mandatory)] [string] $ItemLabel,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
    )
    $ops = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $SrcItem)) { return $ops }   # nothing in home to capture

    if (Test-Path -LiteralPath $SrcItem -PathType Leaf) {
        $action = if (-not (Test-Path -LiteralPath $DstItem)) { 'add' }
        elseif ((Get-FileHashHex $SrcItem) -ne (Get-FileHashHex $DstItem)) { 'update' }
        else { 'noop' }
        if ($action -ne 'noop') {
            $ops.Add(@{ Src = $SrcItem; Dst = $DstItem; Rel = $ItemLabel; Action = $action })
        }
        return $ops
    }

    $srcFull = (Resolve-Path -LiteralPath $SrcItem).Path
    $files = Get-ChildItem -LiteralPath $srcFull -File -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        $rel = $file.FullName.Substring($srcFull.Length).TrimStart('\', '/')
        if (Test-Excluded -RelativePath $rel -Patterns $Excluded) { continue }
        $dst = Join-Path $DstItem $rel
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
    foreach ($item in (@($cfg.PushItems) | Select-Object -Unique)) {
        $ops = Get-PlannedCopies `
            -SrcItem (Join-Path $homeRootP $item) `
            -DstItem (Join-Path $repoRootP $item) `
            -ItemLabel "$name/$item" `
            -Excluded $excluded
        foreach ($op in $ops) { $plan.Add($op) }
    }
}

Write-Host "config-push (home $HomeRoot -> repo)  scope: $($Platform -join ', ')" -ForegroundColor Cyan
if ($plan.Count -eq 0) {
    Write-Host 'Nothing to capture: repo already matches the managed home config.' -ForegroundColor DarkGray
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
    Write-Host 'Dry-run only. Re-run with -Apply to capture (secret scan gates the result).' -ForegroundColor DarkGray
    return
}

# ---------------------------------------------------------------------------
# Apply: stage originals -> write -> secret scan -> keep or revert
# ---------------------------------------------------------------------------

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$stageDir = Join-Path $BackupRoot "config-push-stage-$stamp"

# Stage every existing repo file we are about to overwrite, and record adds.
# The stage dir is created lazily so pure-add runs leave no empty backup folder.
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
    $pathFindings = Find-MachinePrivatePaths -Operations $plan
    if ($pathFindings.Count -gt 0) {
        Write-Host 'ERROR: machine-private absolute path(s) found in captured config:' -ForegroundColor Red
        $pathFindings | Format-Table -AutoSize | Out-String | Write-Host
        Restore-Plan -Operations $plan
        throw 'Captured config contains machine-private paths. Reverted all captured files. Review the source, or re-run with -SkipPathScan if the paths are intentional.'
    }
}

foreach ($op in $plan) {
    $color = if ($op.Action -eq 'add') { 'Green' } else { 'Yellow' }
    Write-Host ('  {0,-7} {1}' -f $op.Action, $op.Rel) -ForegroundColor $color
}
Write-Host "Captured $($plan.Count) file(s) into the repo (UNCOMMITTED). Review with 'git diff' before committing." -ForegroundColor Cyan
Write-Host 'Repo-only files were left untouched (no prune).' -ForegroundColor DarkGray
