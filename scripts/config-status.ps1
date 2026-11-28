#requires -Version 7.0
<#
.SYNOPSIS
    Read-only drift report between the repo copy and the live home copy of the
    config items managed by manifests/whitelist.psd1. Never writes anything.

.DESCRIPTION
    Each managed item (PushItems and PullItems) is reported as in-sync, differs,
    repo-only (a pull would deploy it) or home-only (a push would capture it).
    Items absent on both sides are omitted. ExcludedItems and CommonExcludedItems
    are skipped inside directories.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory. Defaults to $env:USERPROFILE.

.PARAMETER Platform
    One or more of Codex, Antigravity, Hermes. Defaults to Codex.

.PARAMETER Json
    Emit the results as a JSON array instead of the table.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [string[]] $Platform = @('Codex'),
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'config-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Platform = Resolve-ConfigPlatforms -Values $Platform

function Get-ItemKind {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    if (Test-Path -LiteralPath $Path -PathType Container) { return 'dir' }
    return 'file'
}

function Get-DirFileMap {
    # Map of relative path ('/' separators) -> SHA256 for every non-excluded file under $Root.
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
    )
    $map = @{}
    foreach ($file in (Get-ConfigFiles -Root $Root -Excluded $Excluded)) {
        $map[($file.Rel -replace '\\', '/')] = Get-FileHashHex -Path $file.FullName
    }
    return $map
}

function Compare-ConfigItem {
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $HomePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Item
    )
    $repoKind = Get-ItemKind -Path $RepoPath
    $homeKind = Get-ItemKind -Path $HomePath

    if ($repoKind -eq 'absent' -and $homeKind -eq 'absent') {
        return [pscustomobject] @{ Status = 'absent'; Detail = '' }
    }
    if ($homeKind -eq 'absent') {
        return [pscustomobject] @{ Status = 'repo-only'; Detail = 'would deploy on pull' }
    }
    if ($repoKind -eq 'absent') {
        if (Get-ManagedAgentsBlockSpec -Platform $Platform -Item $Item) {
            return [pscustomobject] @{ Status = 'home-only'; Detail = 'capture requires a valid managed block' }
        }
        return [pscustomobject] @{ Status = 'home-only'; Detail = 'untracked; would capture on push' }
    }
    if ($repoKind -ne $homeKind) {
        return [pscustomobject] @{ Status = 'differs'; Detail = "type mismatch ($repoKind vs $homeKind)" }
    }

    if ($repoKind -eq 'file') {
        $blockSpec = Get-ManagedAgentsBlockSpec -Platform $Platform -Item $Item
        if ($null -ne $blockSpec) {
            try {
                $block = Get-ManagedAgentsBlockResult -RepoText ([IO.File]::ReadAllText($RepoPath)) -HomeText ([IO.File]::ReadAllText($HomePath)) -HomeExists $true -BlockId $blockSpec.BlockId -Label $blockSpec.Label
                if ($block.Changed) {
                    $detail = if ($block.HasBlock) { 'managed block differs' } else { 'managed block missing; pull would add it' }
                    return [pscustomobject] @{ Status = 'differs'; Detail = $detail }
                }
                return [pscustomobject] @{ Status = 'in-sync'; Detail = 'managed block' }
            }
            catch { return [pscustomobject] @{ Status = 'differs'; Detail = 'managed block missing or invalid' } }
        }
        if ((Get-FileHashHex -Path $RepoPath) -eq (Get-FileHashHex -Path $HomePath)) {
            return [pscustomobject] @{ Status = 'in-sync'; Detail = '' }
        }
        return [pscustomobject] @{ Status = 'differs'; Detail = 'content differs' }
    }

    $repoMap = Get-DirFileMap -Root $RepoPath -Excluded $Excluded
    $homeMap = Get-DirFileMap -Root $HomePath -Excluded $Excluded
    $onlyRepo = @($repoMap.Keys | Where-Object { -not $homeMap.ContainsKey($_) })
    $onlyHome = @($homeMap.Keys | Where-Object { -not $repoMap.ContainsKey($_) })
    $changed = @($repoMap.Keys | Where-Object { $homeMap.ContainsKey($_) -and $homeMap[$_] -ne $repoMap[$_] })
    if ($onlyRepo.Count -eq 0 -and $onlyHome.Count -eq 0 -and $changed.Count -eq 0) {
        return [pscustomobject] @{ Status = 'in-sync'; Detail = "$($repoMap.Count) files" }
    }
    $bits = @()
    if ($changed.Count) { $bits += "$($changed.Count) changed" }
    if ($onlyRepo.Count) { $bits += "$($onlyRepo.Count) repo-only" }
    if ($onlyHome.Count) { $bits += "$($onlyHome.Count) home-only" }
    return [pscustomobject] @{ Status = 'differs'; Detail = ($bits -join ', ') }
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($target in (Get-ConfigTargets -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -ItemKeys 'PushItems', 'PullItems')) {
    if ($target.Name -ceq 'Hermes') {
        $hermesState = Get-ConfigHermesRootState -HomeRoot $HomeRoot
        if ($hermesState.Blocked) {
            foreach ($item in $target.Items) {
                $results.Add([pscustomobject] @{
                        Platform = $target.Name
                        Item     = $item
                        Status   = 'blocked'
                        Detail   = $hermesState.Reason
                    })
            }
            continue
        }
        if (-not $hermesState.Installed) {
            foreach ($item in $target.Items) {
                $results.Add([pscustomobject] @{
                        Platform = $target.Name
                        Item     = $item
                        Status   = 'not-installed'
                        Detail   = 'Hermes default home not found'
                    })
            }
            continue
        }
    }
    foreach ($item in $target.Items) {
        $cmp = Compare-ConfigItem `
            -RepoPath (Join-Path $target.RepoRoot $item) `
            -HomePath (Join-Path $target.HomeRoot $item) `
            -Excluded $target.Excluded `
            -Platform $target.Name `
            -Item $item
        if ($cmp.Status -eq 'absent') { continue }
        $results.Add([pscustomobject] @{
                Platform = $target.Name
                Item     = $item
                Status   = $cmp.Status
                Detail   = $cmp.Detail
            })
    }
}

if ($Json) {
    ConvertTo-Json -InputObject $results.ToArray() -Depth 5
    return
}

Write-Host "Config drift (repo <-> $HomeRoot) - read-only, no changes made." -ForegroundColor Cyan
Write-Host ''
if ($results.Count -eq 0) {
    Write-Host 'No managed config items present on either side.'
}
else {
    $colorFor = @{
        'in-sync'       = 'DarkGray'
        'differs'       = 'Yellow'
        'repo-only'     = 'Green'
        'home-only'     = 'Magenta'
        'not-installed' = 'DarkGray'
        'blocked'       = 'Red'
    }
    foreach ($row in $results) {
        $label = '{0,-9} {1,-9} {2}' -f $row.Platform, $row.Status, $row.Item
        if ($row.Detail) { $label += "  ($($row.Detail))" }
        $color = if ($colorFor.ContainsKey($row.Status)) { $colorFor[$row.Status] } else { 'White' }
        Write-Host $label -ForegroundColor $color
    }
}

Write-Host ''
$summary = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ("Summary: " + ($summary -join '  ')) -ForegroundColor Cyan
Write-Host 'Read-only inspection. Use config-pull or config-push (dry-run unless -Apply) to sync.' -ForegroundColor DarkGray
