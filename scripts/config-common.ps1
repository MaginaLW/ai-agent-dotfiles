#requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the config-sync CLIs (config-status, config-push, config-pull).

.DESCRIPTION
    This file is intended to be dot-sourced by all three config-sync entry
    scripts. Every helper here must keep exactly one definition in the
    repository: the PowerShell syntax gate's unknown-parameter pass skips
    names that are defined in more than one script, so a local copy in an
    entry script would silently drop call-site parameter checking for that
    name.
#>

Set-StrictMode -Version Latest

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
