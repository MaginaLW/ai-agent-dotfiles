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

function Get-ConfigSyncPlan {
    # The shared pull/push plan: PullItems repo -> home, PushItems home -> repo.
    # Returns an object[] of @{ Src; Dst; Rel; Action } operations.
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string[]] $Platform,
        [Parameter(Mandatory)] [ValidateSet('Pull', 'Push')] [string] $Direction
    )
    $itemKey = if ($Direction -eq 'Pull') { 'PullItems' } else { 'PushItems' }
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($target in (Get-ConfigTargets -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -ItemKeys $itemKey)) {
        foreach ($item in $target.Items) {
            $srcRoot = if ($Direction -eq 'Pull') { $target.RepoRoot } else { $target.HomeRoot }
            $dstRoot = if ($Direction -eq 'Pull') { $target.HomeRoot } else { $target.RepoRoot }
            $ops = Get-PlannedCopies `
                -SrcItem (Join-Path $srcRoot $item) `
                -DstItem (Join-Path $dstRoot $item) `
                -ItemLabel "$($target.Name)/$item" `
                -Excluded $target.Excluded
            foreach ($op in $ops) { $plan.Add($op) }
        }
    }
    return , $plan.ToArray()
}

function Show-ConfigSyncPlan {
    # Prints the empty-plan or dry-run message, or the plan and its summary. Returns $true
    # when an apply should continue, $false when the script should stop after printing.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plan,
        [Parameter(Mandatory)] [string] $EmptyMessage,
        [Parameter(Mandatory)] [string] $DryRunMessage,
        [switch] $Apply
    )
    if ($Plan.Count -eq 0) {
        Write-Host $EmptyMessage -ForegroundColor DarkGray
        Write-Host ('Mode: ' + ($(if ($Apply) { 'APPLY (no changes needed)' } else { 'dry-run' })))
        return $false
    }
    Write-CopyPlan -Plan $Plan
    $grouped = $Plan | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host ("Plan: " + ($grouped -join '  '))
    if (-not $Apply) {
        Write-Host $DryRunMessage -ForegroundColor DarkGray
        return $false
    }
    return $true
}

function Invoke-ConfigPlanCopy {
    # Applies every planned copy, creating destination parents as needed. -Progress prints
    # one green line per file, the way config-pull reports during apply.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plan,
        [switch] $Progress
    )
    foreach ($op in $Plan) {
        $parent = Split-Path -Parent $op.Dst
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $op.Src -Destination $op.Dst -Force
        if ($Progress) { Write-Host ('  {0,-7} {1}' -f $op.Action, $op.Rel) -ForegroundColor Green }
    }
}
