#requires -Version 7.0
<#
.SYNOPSIS
    Plans (default) or, with -Apply, writes a project's allowlisted harness targets.
    Existing files are backed up under .agent-harness/backups/ before they are overwritten.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $ProjectRoot = (Get-Location).Path,
    [string] $BackupRoot = (Join-Path $ProjectRoot '.agent-harness/backups')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-profile-common.ps1')

$plan = New-HarnessProfilePlan -RepoRoot $RepoRoot -ProjectRoot $ProjectRoot -Mode Apply
$repo = $plan.RepoRoot
$project = $plan.ProjectRoot
Assert-HarnessNoPrivatePaths -Paths @($plan.SourceFiles | ForEach-Object Path)

$changes = @(Get-HarnessApplyChanges -Plan $plan)
$writeChanges = @($changes | Where-Object Action -In @('add', 'update'))
Assert-HarnessOutsideHome -Paths @($writeChanges | ForEach-Object FullPath)
foreach ($change in $writeChanges) {
    if (Test-HarnessPrivatePathText -Text $change.Content) { throw "Machine-private path scan failed for planned target: $($change.Target)" }
}

Write-Output 'Harness profile apply'
Write-Output "Project root: $project"
Write-Output "Repo root: $repo"
Write-Output "Mode: $(if ($Apply) { 'APPLY' } else { 'dry-run' })"
Write-Output ''
Write-Output 'Plan:'
if ($changes.Count -eq 0) { Write-Output '  (no targets)' }
foreach ($change in $changes) {
    $suffix = if ($change.Reason) { " ($($change.Reason))" } else { '' }
    Write-Output ('  {0,-7} {1} mode={2}{3}' -f $change.Action, $change.Target, $change.Mode, $suffix)
}
if ($writeChanges.Count -eq 0) {
    Write-Output ''
    Write-Output 'Nothing to apply.'
    return
}
if (-not $Apply) {
    Write-Output ''
    Write-Output 'Dry-run only. Re-run with -Apply to write project-local targets.'
    return
}

Invoke-HarnessSecretScan -RepoRoot $repo

# A relative -BackupRoot starting with .agent-harness/backups is project-relative; any other
# relative value is resolved from the current directory. It must end up under the project's
# .agent-harness/backups.
$backupBase = if ([System.IO.Path]::IsPathFullyQualified($BackupRoot)) { $BackupRoot }
elseif (($BackupRoot -replace '\\', '/').StartsWith('.agent-harness/backups', [System.StringComparison]::OrdinalIgnoreCase)) { Join-Path $project $BackupRoot }
else { Join-Path (Get-Location).Path $BackupRoot }
$backupRootResolved = [System.IO.Path]::GetFullPath($backupBase)
$backupRelative = Get-HarnessRelativePath -Root $project -Path $backupRootResolved
if (-not ($backupRelative -ieq '.agent-harness/backups' -or $backupRelative.StartsWith('.agent-harness/backups/', [System.StringComparison]::OrdinalIgnoreCase))) {
    throw 'BackupRoot must resolve under .agent-harness/backups inside the project root.'
}
Assert-HarnessOutsideHome -Paths @($backupRootResolved)
$backupDir = Join-Path $backupRootResolved "apply-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$entries = @(foreach ($change in $writeChanges) {
        $backupPath = $null
        $hash = $null
        if (Test-Path -LiteralPath $change.FullPath -PathType Leaf) {
            $backupPath = Join-Path $backupDir ((Get-HarnessRelativePath -Root $project -Path $change.FullPath) -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
            Copy-Item -LiteralPath $change.FullPath -Destination $backupPath -Force
            $hash = Get-HarnessFileHash -Path $change.FullPath
        }
        [ordered] @{
            originalPath = $change.FullPath
            backupPath   = $backupPath
            action       = $change.Action
            hash         = $hash
            timestamp    = (Get-Date).ToUniversalTime().ToString('o')
        }
    })
$manifestPath = Join-Path $backupDir 'manifest.json'
[ordered] @{
    projectRoot = $project
    profilePath = $plan.ProfilePath
    createdAt   = (Get-Date).ToUniversalTime().ToString('o')
    entries     = $entries
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$applied = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($change in $writeChanges) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $change.FullPath) -Force | Out-Null
        Set-Content -LiteralPath $change.FullPath -Value $change.Content -Encoding UTF8 -NoNewline
        $applied.Add($change)
        Write-Output ('  {0,-7} {1}' -f $change.Action, $change.Target)
    }
}
catch {
    Write-Warning "Apply failed. Attempting best-effort rollback for $($applied.Count) changed file(s)."
    foreach ($change in @($applied | Sort-Object Target -Descending)) {
        $entry = @($entries | Where-Object { $_.originalPath -eq $change.FullPath })[0]
        try {
            if ($entry.backupPath) { Copy-Item -LiteralPath $entry.backupPath -Destination $change.FullPath -Force }
            elseif (Test-Path -LiteralPath $change.FullPath -PathType Leaf) { Remove-Item -LiteralPath $change.FullPath -Force }
        }
        catch { Write-Warning "Rollback could not restore $($change.FullPath): $($_.Exception.Message)" }
    }
    throw
}

Write-Output ''
Write-Output "Applied $($writeChanges.Count) change(s)."
Write-Output "Backup manifest: $manifestPath"
