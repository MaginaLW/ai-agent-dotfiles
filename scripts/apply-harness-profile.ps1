#requires -Version 7.0
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $ProjectRoot = (Get-Location).Path,
    [string] $BackupRoot = (Join-Path $ProjectRoot '.agent-harness/backups')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'harness-profile-common.ps1')

$plan = New-HarnessProfilePlan -RepoRoot $RepoRoot -ProjectRoot $ProjectRoot -Mode Apply
$repo = $plan.RepoRoot
$project = $plan.ProjectRoot

$sourcePathFindings = @(Find-HarnessMachinePrivatePaths -Paths @($plan.SourceFiles | ForEach-Object { $_.Path }))
if ($sourcePathFindings.Count -gt 0) {
    $details = $sourcePathFindings | ForEach-Object { "$($_.File):$($_.Line) $($_.Pattern)" }
    throw "Machine-private path scan failed: $($details -join '; ')"
}

$changes = @(New-HarnessApplyChangePlan -Plan $plan)

$writeChanges = @($changes | Where-Object { $_.Action -in @('add', 'update') })
Assert-NoHarnessHomeTarget -Paths @($writeChanges | ForEach-Object { $_.FullPath })
Assert-NoHarnessMachinePrivateText -Changes $writeChanges

Write-Output 'Harness profile apply'
Write-Output "Project root: $project"
Write-Output "Repo root: $repo"
Write-Output "Mode: $(if ($Apply) { 'APPLY' } else { 'dry-run' })"
Write-Output ''
Write-Output 'Plan:'
if ($changes.Count -eq 0) {
    Write-Output '  (no targets)'
}
else {
    foreach ($change in $changes) {
        $suffix = if ($change.Reason) { " ($($change.Reason))" } else { '' }
        Write-Output ('  {0,-7} {1} mode={2}{3}' -f $change.Action, $change.Target, $change.Mode, $suffix)
    }
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

$backupRootResolved = Resolve-HarnessBackupRoot -BackupRoot $BackupRoot -ProjectRoot $project
Assert-NoHarnessHomeTarget -Paths @($backupRootResolved)
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$backupDir = Join-Path $backupRootResolved "apply-$stamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$manifestEntries = [System.Collections.Generic.List[object]]::new()
foreach ($change in $writeChanges) {
    $exists = Test-Path -LiteralPath $change.FullPath -PathType Leaf
    $backupPath = $null
    $hash = $null
    if ($exists) {
        $relative = Get-HarnessRelativePath -Root $project -Path $change.FullPath
        $backupPath = Join-Path $backupDir ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Copy-Item -LiteralPath $change.FullPath -Destination $backupPath -Force
        $hash = Get-HarnessFileHash -Path $change.FullPath
    }
    $manifestEntries.Add([ordered] @{
            originalPath = $change.FullPath
            backupPath   = $backupPath
            action       = $change.Action
            hash         = $hash
            timestamp    = (Get-Date).ToUniversalTime().ToString('o')
        })
}

$manifest = [ordered] @{
    projectRoot = $project
    profilePath = $plan.ProfilePath
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    entries = @($manifestEntries)
}
$manifestPath = Join-Path $backupDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$applied = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($change in $writeChanges) {
        $parent = Split-Path -Parent $change.FullPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Set-Content -LiteralPath $change.FullPath -Value $change.Content -Encoding UTF8 -NoNewline
        $applied.Add($change)
        Write-Output ('  {0,-7} {1}' -f $change.Action, $change.Target)
    }
}
catch {
    Write-Warning "Apply failed. Attempting best-effort rollback for $($applied.Count) changed file(s)."
    foreach ($change in @($applied | Sort-Object Target -Descending)) {
        $entry = $manifestEntries | Where-Object { $_.originalPath -eq $change.FullPath } | Select-Object -First 1
        try {
            if ($entry.backupPath) {
                Copy-Item -LiteralPath $entry.backupPath -Destination $entry.originalPath -Force
            }
            elseif (Test-Path -LiteralPath $change.FullPath -PathType Leaf) {
                Remove-Item -LiteralPath $change.FullPath -Force
            }
        }
        catch {
            Write-Warning "Rollback could not restore $($change.FullPath): $($_.Exception.Message)"
        }
    }
    throw
}

Write-Output ''
Write-Output "Applied $($writeChanges.Count) change(s)."
Write-Output "Backup manifest: $manifestPath"
