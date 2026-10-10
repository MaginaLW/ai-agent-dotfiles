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
    Home directory. Defaults to $env:USERPROFILE. Claude is read from .claude,
    Codex from .codex and Reasonix from AppData\Roaming\reasonix.

.PARAMETER Platform
    One or more of Claude, Codex, Reasonix. Defaults to all three.

.PARAMETER Json
    Emit the results as a JSON array instead of the table.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [ValidateSet('Claude', 'Codex', 'Reasonix')]
    [string[]] $Platform,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'config-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $Platform) { $Platform = @('Claude', 'Codex', 'Reasonix') }

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
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
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
        return [pscustomobject] @{ Status = 'home-only'; Detail = 'untracked; would capture on push' }
    }
    if ($repoKind -ne $homeKind) {
        return [pscustomobject] @{ Status = 'differs'; Detail = "type mismatch ($repoKind vs $homeKind)" }
    }

    if ($repoKind -eq 'file') {
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
    foreach ($item in $target.Items) {
        $cmp = Compare-ConfigItem `
            -RepoPath (Join-Path $target.RepoRoot $item) `
            -HomePath (Join-Path $target.HomeRoot $item) `
            -Excluded $target.Excluded
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
    $results | ConvertTo-Json -Depth 5
    return
}

Write-Host "Config drift (repo <-> $HomeRoot) - read-only, no changes made." -ForegroundColor Cyan
Write-Host ''
if ($results.Count -eq 0) {
    Write-Host 'No managed config items present on either side.'
}
else {
    $colorFor = @{
        'in-sync'   = 'DarkGray'
        'differs'   = 'Yellow'
        'repo-only' = 'Green'
        'home-only' = 'Magenta'
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
