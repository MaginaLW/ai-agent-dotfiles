#requires -Version 7.0
<#
.SYNOPSIS
    Read-only drift report for repo-managed agent harness config (Claude / Codex /
    OpenClaw). Phase 1 of config-sync: it NEVER writes to the repo or to home.

.DESCRIPTION
    Source of truth for what counts as managed config is manifests/whitelist.psd1
    (PushItems / PullItems per platform). For each managed item this script compares
    the repo copy against the live home copy and reports one of:

        in-sync     both present and identical
        differs     both present, content differs (drift)
        repo-only   present in repo, absent in home  (a pull would deploy it)
        home-only   present in home, absent in repo  (a push would capture it)
        absent      present in neither (nothing to do)

    Per-platform ExcludedItems and the shared CommonExcludedItems from whitelist.psd1
    are skipped while walking directories, so credentials, sessions, caches, history,
    and other machine-private/runtime files are never inspected or reported.

    This is a pure dry-run inspector. There is no -Apply. Deployment (pull) and
    capture (push) are later phases and live in separate, gated scripts.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory root for resolving live config paths. Defaults to $env:USERPROFILE.
    Override for tests (e.g. tests/fixtures/fake-home).

.PARAMETER Platform
    Optional filter: one or more of Claude, Codex, OpenClaw. Defaults to all three.

.PARAMETER Json
    Emit the per-item results as JSON instead of the human-readable table.

.OUTPUTS
    Human-readable table plus a summary line, or a JSON array with -Json.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [ValidateSet('Claude', 'Codex', 'OpenClaw')]
    [string[]] $Platform,
    [switch] $Json
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
# Helpers
# ---------------------------------------------------------------------------

function Test-Excluded {
    # True if a repo/home-relative path matches any exclusion pattern, either as the
    # whole path, as a path prefix, or as any single path segment. Patterns may be
    # exact names ('projects'), globs ('history*', '*.local.json'), or nested paths
    # ('plugins/repos').
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

function Get-ItemKind {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    if (Test-Path -LiteralPath $Path -PathType Container) { return 'dir' }
    return 'file'
}

function Get-FileHashHex {
    param([Parameter(Mandatory)] [string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-DirFileMap {
    # Map of excluded-filtered relative-path -> SHA256 for every file under $Root.
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
    )
    $map = @{}
    $rootFull = (Resolve-Path -LiteralPath $Root).Path
    $files = Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        $rel = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/')
        if (Test-Excluded -RelativePath $rel -Patterns $Excluded) { continue }
        $map[($rel -replace '\\', '/')] = Get-FileHashHex -Path $file.FullName
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

    # directory compare
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$platformsToScan = if ($Platform) { $Platform } else { @('Claude', 'Codex', 'OpenClaw') }
$results = [System.Collections.Generic.List[object]]::new()

foreach ($name in $platformsToScan) {
    $cfg = $whitelist.$name
    if (-not $cfg) { continue }

    $repoRootP = Join-Path $RepoRoot $cfg.RepoRelativeRoot
    $homeRootP = Join-Path $HomeRoot $cfg.HomeRelativeRoot
    $excluded = @($cfg.ExcludedItems) + $commonExcluded
    $items = @($cfg.PushItems) + @($cfg.PullItems) | Select-Object -Unique

    foreach ($item in $items) {
        $cmp = Compare-ConfigItem `
            -RepoPath (Join-Path $repoRootP $item) `
            -HomePath (Join-Path $homeRootP $item) `
            -Excluded $excluded
        if ($cmp.Status -eq 'absent') { continue }
        $results.Add([pscustomobject] @{
                Platform = $name
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
Write-Host 'Read-only inspection. Pull/push are later, gated phases.' -ForegroundColor DarkGray
