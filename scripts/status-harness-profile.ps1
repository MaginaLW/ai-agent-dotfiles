#requires -Version 7.0
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

$resolvedProfiles = @(
    $plan.ResolvedProfiles | ForEach-Object {
        [pscustomobject] @{
            Name = $_.Name
            Path = $_.Path
        }
    }
)
$components = @(
    $plan.Components | ForEach-Object {
        [pscustomobject] @{
            Id              = $_.Id
            Kind            = $_.Kind
            TargetPlatforms = @($_.Data.TargetPlatforms)
            Path            = $_.Path
        }
    }
)
$targets = @(
    $plan.Targets | ForEach-Object {
        [pscustomobject] @{
            ComponentId = $_.ComponentId
            Target      = $_.Target
            FullPath    = $_.FullPath
            Mode        = $_.Mode
            Action      = $_.Action
        }
    }
)

$summary = [pscustomobject] @{
    Mode             = $plan.Mode
    RepoRoot         = $plan.RepoRoot
    ProjectRoot      = $plan.ProjectRoot
    ProfilePath      = $plan.ProfilePath
    ResolvedProfiles = $resolvedProfiles
    TargetPlatforms  = @($plan.TargetPlatforms)
    ComponentIds     = @($plan.ComponentIds)
    Components       = $components
    Targets          = $targets
    SourceCount      = @($plan.SourceFiles).Count
    Sources          = @($plan.SourceFiles)
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 20
    return
}

Write-Output 'Harness profile status'
Write-Output "Profile path: $($summary.ProfilePath)"
Write-Output "Project root: $($summary.ProjectRoot)"
Write-Output "Repo root: $($summary.RepoRoot)"
Write-Output "Target platforms: $(@($summary.TargetPlatforms) -join ', ')"
Write-Output "Source count: $($summary.SourceCount)"
Write-Output ''

Write-Output 'Resolved profiles:'
if ($summary.ResolvedProfiles.Count -eq 0) {
    Write-Output '  (none)'
}
else {
    foreach ($profile in $summary.ResolvedProfiles) {
        Write-Output "  - $($profile.Name): $($profile.Path)"
    }
}
Write-Output ''

Write-Output 'Components:'
if ($summary.Components.Count -eq 0) {
    Write-Output '  (none)'
}
else {
    foreach ($component in $summary.Components) {
        Write-Output "  - $($component.Id) [$($component.Kind)] platforms=$(@($component.TargetPlatforms) -join ', ')"
    }
}
Write-Output ''

Write-Output 'Targets:'
if ($summary.Targets.Count -eq 0) {
    Write-Output '  (none)'
}
else {
    foreach ($target in $summary.Targets) {
        Write-Output "  - $($target.Target) component=$($target.ComponentId) mode=$($target.Mode) action=$($target.Action)"
    }
}
