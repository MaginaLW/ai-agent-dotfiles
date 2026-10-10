#requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for config-status, config-pull and config-push. Dot-source only.

.NOTES
    Keep exactly one definition of each helper in the repository: the syntax gate's
    unknown-parameter pass skips names defined in more than one script.
#>

Set-StrictMode -Version Latest

function Get-ConfigTargets {
    # Loads manifests/whitelist.psd1 and returns one entry per selected platform it
    # defines: Name, RepoRoot, HomeRoot, Excluded (platform + common) and the unique
    # items listed under the given whitelist keys (PushItems and/or PullItems).
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string[]] $Platform,
        [Parameter(Mandatory)] [string[]] $ItemKeys
    )
    $whitelistPath = Join-Path $RepoRoot 'manifests/whitelist.psd1'
    if (-not (Test-Path -LiteralPath $whitelistPath)) {
        throw "Missing manifest: $whitelistPath"
    }
    $whitelist = Import-PowerShellDataFile -LiteralPath $whitelistPath
    foreach ($name in $Platform) {
        $cfg = $whitelist.$name
        if (-not $cfg) { continue }
        [pscustomobject] @{
            Name     = $name
            RepoRoot = Join-Path $RepoRoot $cfg.RepoRelativeRoot
            HomeRoot = Join-Path $HomeRoot $cfg.HomeRelativeRoot
            Excluded = @($cfg.ExcludedItems) + @($whitelist.CommonExcludedItems)
            Items    = @(@(foreach ($key in $ItemKeys) { @($cfg.$key) }) | Select-Object -Unique)
        }
    }
}

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

function Get-FileHashHex {
    param([Parameter(Mandatory)] [string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-ConfigFiles {
    # Every non-excluded file under a directory, as FullName plus Rel (relative to
    # the directory, native separators).
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
    )
    $rootFull = (Resolve-Path -LiteralPath $Root).Path
    foreach ($file in (Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $rel = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/')
        if (Test-Excluded -RelativePath $rel -Patterns $Excluded) { continue }
        [pscustomobject] @{ FullName = $file.FullName; Rel = $rel }
    }
}

function Get-PlannedCopies {
    # Returns a list of @{ Src; Dst; Rel; Action } for one managed item, from
    # the source item (home or repo) to the destination item (repo or home).
    param(
        [Parameter(Mandatory)] [string] $SrcItem,
        [Parameter(Mandatory)] [string] $DstItem,
        [Parameter(Mandatory)] [string] $ItemLabel,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
    )
    $ops = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $SrcItem)) { return $ops }   # nothing to plan

    if (Test-Path -LiteralPath $SrcItem -PathType Leaf) {
        $action = if (-not (Test-Path -LiteralPath $DstItem)) { 'add' }
        elseif ((Get-FileHashHex $SrcItem) -ne (Get-FileHashHex $DstItem)) { 'update' }
        else { 'noop' }
        if ($action -ne 'noop') {
            $ops.Add(@{ Src = $SrcItem; Dst = $DstItem; Rel = $ItemLabel; Action = $action })
        }
        return $ops
    }

    # directory: copy file-by-file, never prune
    foreach ($file in (Get-ConfigFiles -Root $SrcItem -Excluded $Excluded)) {
        $dst = Join-Path $DstItem $file.Rel
        $action = if (-not (Test-Path -LiteralPath $dst)) { 'add' }
        elseif ((Get-FileHashHex $file.FullName) -ne (Get-FileHashHex $dst)) { 'update' }
        else { 'noop' }
        if ($action -ne 'noop') {
            $ops.Add(@{ Src = $file.FullName; Dst = $dst; Rel = "$ItemLabel/$($file.Rel -replace '\\','/')"; Action = $action })
        }
    }
    return $ops
}

function Write-CopyPlan {
    # One line per planned copy: adds in green, updates in yellow.
    param([Parameter(Mandatory)] [object[]] $Plan)
    foreach ($op in $Plan) {
        $color = if ($op.Action -eq 'add') { 'Green' } else { 'Yellow' }
        Write-Host ('  {0,-7} {1}' -f $op.Action, $op.Rel) -ForegroundColor $color
    }
}
