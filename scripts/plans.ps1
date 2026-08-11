#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position=0, Mandatory)] [ValidateSet('list','prune')] [string] $Action,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string[]] $ArtifactPath = @(),
    [string] $PlanPath,
    [switch] $DryRun,
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'approved-runner-common.ps1')

$context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
if ($Action -eq 'list') {
    if ($DryRun -or $Apply -or $ArtifactPath.Count -gt 0 -or $PlanPath) { throw 'plans list accepts no mutation or selection parameters.' }
    foreach ($root in @($context.PendingEventsRoot,$context.PendingPreviewsRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $root -File | Sort-Object FullName | ForEach-Object { Write-Host $_.FullName }
    }
    return
}

if ($DryRun -eq $Apply) { throw 'plans prune requires exactly one of -DryRun or -Apply.' }
if ([string]::IsNullOrWhiteSpace($PlanPath)) { throw 'plans prune requires -PlanPath.' }
if ($DryRun) {
    if ($ArtifactPath.Count -eq 0) { throw 'plans prune -DryRun requires one or more exact -ArtifactPath values.' }
    New-PendingPrunePlan -RepoRoot $RepoRoot -ArtifactPaths $ArtifactPath -PlanPath $PlanPath | Out-Null
    Write-Host "Pending prune plan written for review: $PlanPath"
    return
}
if ($ArtifactPath.Count -ne 0) { throw 'plans prune -Apply consumes only the saved plan; do not repeat selection parameters.' }
$moved = @(Invoke-PendingPrunePlan -RepoRoot $RepoRoot -PlanPath $PlanPath)
Write-Host "Retired pending artifacts: $($moved.Count)"
