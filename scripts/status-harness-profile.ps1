#requires -Version 7.0
<#
.SYNOPSIS
    Read-only status and drift report for a project's harness profile.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
    [string] $ProjectRoot = (Get-Location).Path,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-profile-common.ps1')

$plan = New-HarnessProfilePlan -RepoRoot $RepoRoot -ProjectRoot $ProjectRoot -Mode Status
$summary = [pscustomobject] @{
    Mode             = $plan.Mode
    RepoRoot         = $plan.RepoRoot
    ProjectRoot      = $plan.ProjectRoot
    ProfilePath      = $plan.ProfilePath
    ResolvedProfiles = @($plan.ResolvedProfiles | ForEach-Object { [pscustomobject] @{ Name = $_.Name; Path = $_.Path } })
    TargetPlatforms  = @($plan.TargetPlatforms)
    ComponentIds     = @($plan.ComponentIds)
    Components       = @($plan.Components | ForEach-Object {
            [pscustomobject] @{ Id = $_.Id; Kind = $_.Kind; TargetPlatforms = @($_.Data.TargetPlatforms); Path = $_.Path }
        })
    Targets          = @(Get-HarnessApplyChanges -Plan $plan | ForEach-Object {
            [pscustomobject] @{ Target = $_.Target; FullPath = $_.FullPath; Mode = $_.Mode; Action = $_.Action; Reason = $_.Reason }
        })
    SourceCount      = @($plan.SourceFiles).Count
    Sources          = @($plan.SourceFiles)
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 20
    return
}

function Write-HarnessStatusSection([string] $Title, [object[]] $Lines) {
    Write-Output "${Title}:"
    if (@($Lines).Count -eq 0) { Write-Output '  (none)' }
    foreach ($line in $Lines) { Write-Output "  - $line" }
}

Write-Output 'Harness profile status'
Write-Output "Profile path: $($summary.ProfilePath)"
Write-Output "Project root: $($summary.ProjectRoot)"
Write-Output "Repo root: $($summary.RepoRoot)"
Write-Output "Target platforms: $($summary.TargetPlatforms -join ', ')"
Write-Output "Source count: $($summary.SourceCount)"
Write-Output ''
Write-HarnessStatusSection 'Resolved profiles' @($summary.ResolvedProfiles | ForEach-Object { "$($_.Name): $($_.Path)" })
Write-Output ''
Write-HarnessStatusSection 'Components' @($summary.Components | ForEach-Object { "$($_.Id) [$($_.Kind)] platforms=$($_.TargetPlatforms -join ', ')" })
Write-Output ''
Write-HarnessStatusSection 'Targets' @($summary.Targets | ForEach-Object {
        $suffix = if ($_.Reason) { " ($($_.Reason))" } else { '' }
        "$($_.Target) mode=$($_.Mode) action=$($_.Action)$suffix"
    })
