#requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for config-status, config-pull and config-push. Dot-source only.

.NOTES
    Keep exactly one definition of each helper in the repository: the syntax gate's
    unknown-parameter pass skips names defined in more than one script.
#>

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'repo-common.ps1')

function Resolve-ConfigBackupRoot {
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $BackupRoot)

    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        throw 'BackupRoot must be outside the repository.'
    }

    function ConvertTo-ConfigLocalPath([string] $RawPath, [string] $ErrorPrefix) {
        $provider = $null
        $drive = $null
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RawPath, [ref]$provider, [ref]$drive)
        if ($null -eq $provider -or $provider.Name -cne 'FileSystem') {
            throw "$ErrorPrefix (non-filesystem path)."
        }
        $normalized = $resolved.Replace('/', '\')
        if ($normalized.StartsWith('\\')) {
            throw "$ErrorPrefix (UNC and Win32 device paths are not supported)."
        }
        return [IO.Path]::GetFullPath($normalized)
    }

    # Resolve existing junctions and symlinks even if the backup directory is new.
    function Get-ConfigDirectoryTarget([IO.DirectoryInfo] $Directory, [int] $LinksLeft = 63) {
        if ($null -eq $Directory.Parent) { return $Directory.FullName }
        $parent = Get-ConfigDirectoryTarget $Directory.Parent $LinksLeft
        $item = [IO.DirectoryInfo]::new([IO.Path]::Combine($parent, $Directory.Name))
        if ($null -ne $item.LinkTarget) {
            if ($LinksLeft -eq 0) { throw 'Too many links in config directory path.' }
            $target = $item.ResolveLinkTarget($false)
            if ($null -eq $target) {
                throw 'BackupRoot must be outside the repository (unresolvable reparse point).'
            }
            $targetPath = $target.FullName.Replace('/', '\')
            if ($targetPath -match '^\\\\\?\\([A-Za-z]:\\.*)$') {
                $targetPath = $Matches[1]
            }
            elseif ($targetPath.StartsWith('\\')) {
                throw 'BackupRoot must be outside the repository (UNC and Win32 device targets are not supported).'
            }
            return Get-ConfigDirectoryTarget ([IO.DirectoryInfo]::new($targetPath)) ($LinksLeft - 1)
        }
        if ($item.Exists -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'BackupRoot must be outside the repository (unresolvable reparse point).'
        }
        return $item.FullName
    }

    $backupPath = ConvertTo-ConfigLocalPath $BackupRoot 'BackupRoot must be outside the repository'
    $repoPath = ConvertTo-ConfigLocalPath $RepoRoot 'RepoRoot must be a local filesystem path'
    $backup = Get-ConfigDirectoryTarget ([IO.DirectoryInfo]::new($backupPath))
    $repo = Get-ConfigDirectoryTarget ([IO.DirectoryInfo]::new($repoPath))
    $relative = [IO.Path]::GetRelativePath($repo, $backup)
    if (-not [IO.Path]::IsPathRooted($relative) -and $relative -ne '..' -and
        -not $relative.StartsWith('..' + [IO.Path]::DirectorySeparatorChar)) {
        throw 'BackupRoot must be outside the repository.'
    }
    return $backup
}

function Resolve-ConfigPlatforms {
    param(
        [Alias('PlatformInput')]
        [string[]] $Values
    )
    $canonical = @{
        codex       = 'Codex'
        antigravity = 'Antigravity'
        hermes      = 'Hermes'
    }
    $selected = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($raw in @($Values)) {
        foreach ($token in ([string]$raw -split ',')) {
            $trimmed = $token.Trim()
            if ([string]::IsNullOrEmpty($trimmed)) { continue }
            $key = $trimmed.ToLowerInvariant()
            if (-not $canonical.ContainsKey($key)) {
                throw "Unsupported config platform '$trimmed'. Expected Codex, Antigravity, or Hermes."
            }
            $name = $canonical[$key]
            if ($seen.Add($name)) { $selected.Add($name) }
        }
    }
    if ($selected.Count -eq 0 -and @($Values).Count -gt 0) {
        throw "Config -Platform requires at least one platform name. Expected Codex, Antigravity, or Hermes."
    }
    return @($selected)
}

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
        if (-not $whitelist.ContainsKey($name)) { continue }
        $cfg = $whitelist[$name]
        if ($cfg -isnot [hashtable]) { continue }
        $items = @(foreach ($key in $ItemKeys) {
            if ($cfg.ContainsKey($key)) { @($cfg[$key]) }
        }) | Select-Object -Unique
        [pscustomobject] @{
            Name     = $name
            RepoRoot = Join-Path $RepoRoot $cfg.RepoRelativeRoot
            HomeRoot = Join-Path $HomeRoot $cfg.HomeRelativeRoot
            Excluded = @($cfg.ExcludedItems) + @($whitelist.CommonExcludedItems)
            Items    = @($items)
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

$script:ManagedAgentsBlocks = @{
    Codex = @{
        Item    = 'AGENTS.md'
        BlockId = 'codex/AGENTS.md'
        Label   = 'Codex/AGENTS.md'
    }
    Antigravity = @{
        Item    = 'AGENTS.md'
        BlockId = 'antigravity/AGENTS.md'
        Label   = 'Antigravity/AGENTS.md'
    }
    Hermes = @{
        Item    = 'SOUL.md'
        BlockId = 'hermes/SOUL.md'
        Label   = 'Hermes/SOUL.md'
    }
}

function Get-ManagedAgentsBlockSpec {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Item
    )
    if (-not $script:ManagedAgentsBlocks.ContainsKey($Platform)) { return $null }
    $spec = $script:ManagedAgentsBlocks[$Platform]
    if ($spec.Item -cne $Item) { return $null }
    return $spec
}

function Get-ConfigHermesRootState {
    param([Parameter(Mandatory)] [string] $HomeRoot)

    $defaultPath = Join-Path $HomeRoot 'AppData\Local\hermes'
    if (-not [string]::IsNullOrWhiteSpace($env:HERMES_DATA_DIR_SUFFIX)) {
        return [pscustomobject]@{
            Path      = $defaultPath
            Installed = $false
            Blocked   = $true
            Reason    = 'hermes-home-override-unsupported'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:HERMES_HOME)) {
        $matchesDefault = $false
        try {
            $provider = $null
            $drive = $null
            $resolvedDefault = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($defaultPath, [ref]$provider, [ref]$drive)
            $defaultProvider = $provider
            $provider = $null
            $drive = $null
            $resolvedOverride = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:HERMES_HOME, [ref]$provider, [ref]$drive)
            if ($null -ne $defaultProvider -and $defaultProvider.Name -ceq 'FileSystem' -and
                $null -ne $provider -and $provider.Name -ceq 'FileSystem' -and
                [IO.Path]::IsPathRooted($env:HERMES_HOME)) {
                $normalizedDefault = [IO.Path]::GetFullPath($resolvedDefault).TrimEnd('\', '/')
                $normalizedOverride = [IO.Path]::GetFullPath($resolvedOverride).TrimEnd('\', '/')
                if ($normalizedOverride -ieq $normalizedDefault) {
                    $matchesDefault = $true
                }
            }
        }
        catch {
            $matchesDefault = $false
        }
        if (-not $matchesDefault) {
            return [pscustomobject]@{
                Path      = $defaultPath
                Installed = $false
                Blocked   = $true
                Reason    = 'hermes-home-override-unsupported'
            }
        }
    }

    try {
        Assert-PlainPathNoReparse -Path $defaultPath -AllowMissing
    }
    catch {
        return [pscustomobject]@{
            Path      = $defaultPath
            Installed = $false
            Blocked   = $true
            Reason    = 'reparse-point-blocked'
        }
    }

    if (Test-Path -LiteralPath $defaultPath -PathType Leaf) {
        return [pscustomobject]@{
            Path      = $defaultPath
            Installed = $false
            Blocked   = $true
            Reason    = 'hermes-root-not-directory'
        }
    }
    if (-not (Test-Path -LiteralPath $defaultPath -PathType Container)) {
        return [pscustomobject]@{
            Path      = $defaultPath
            Installed = $false
            Blocked   = $false
            Reason    = 'hermes-not-installed'
        }
    }

    $activeProfilePath = Join-Path $defaultPath 'active_profile'
    try {
        Assert-PlainPathNoReparse -Path $activeProfilePath -AllowMissing
    }
    catch {
        return [pscustomobject]@{
            Path      = $defaultPath
            Installed = $false
            Blocked   = $true
            Reason    = 'reparse-point-blocked'
        }
    }

    if (Test-Path -LiteralPath $activeProfilePath -PathType Container) {
        return [pscustomobject]@{
            Path      = $defaultPath
            Installed = $false
            Blocked   = $true
            Reason    = 'hermes-active-profile-invalid'
        }
    }
    if (Test-Path -LiteralPath $activeProfilePath -PathType Leaf) {
        try {
            $profileName = ([IO.File]::ReadAllText($activeProfilePath)).Trim()
        }
        catch {
            return [pscustomobject]@{
                Path      = $defaultPath
                Installed = $false
                Blocked   = $true
                Reason    = 'hermes-active-profile-invalid'
            }
        }
        if ((-not [string]::IsNullOrEmpty($profileName)) -and ($profileName -ine 'default')) {
            return [pscustomobject]@{
                Path      = $defaultPath
                Installed = $false
                Blocked   = $true
                Reason    = 'hermes-non-default-profile-unsupported'
            }
        }
    }

    return [pscustomobject]@{
        Path      = $defaultPath
        Installed = $true
        Blocked   = $false
        Reason    = $null
    }
}

function Get-JsonObjectMap {
    param([System.Text.Json.JsonElement] $Element)
    $map = [System.Collections.Generic.Dictionary[string, System.Text.Json.JsonElement]]::new([StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
        if ($map.ContainsKey($property.Name)) { throw 'duplicate JSON object key' }
        $map.Add($property.Name, $property.Value)
    }
    return ,$map
}

function Assert-JsonUniqueObjectKeys {
    param([System.Text.Json.JsonElement] $Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $map = Get-JsonObjectMap $Element
        foreach ($value in $map.Values) { Assert-JsonUniqueObjectKeys $value }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($value in $Element.EnumerateArray()) { Assert-JsonUniqueObjectKeys $value }
    }
}

function Test-JsonEqual {
    param([System.Text.Json.JsonElement] $Left, [System.Text.Json.JsonElement] $Right)
    if ($Left.ValueKind -ne $Right.ValueKind) { return $false }
    switch ($Left.ValueKind.ToString()) {
        'Object' {
            $leftMap = Get-JsonObjectMap $Left
            $rightMap = Get-JsonObjectMap $Right
            if ($leftMap.Count -ne $rightMap.Count) { return $false }
            foreach ($key in $leftMap.Keys) {
                if (-not $rightMap.ContainsKey($key) -or -not (Test-JsonEqual $leftMap[$key] $rightMap[$key])) { return $false }
            }
            return $true
        }
        'Array' {
            if ($Left.GetArrayLength() -ne $Right.GetArrayLength()) { return $false }
            for ($i = 0; $i -lt $Left.GetArrayLength(); $i++) {
                if (-not (Test-JsonEqual $Left[$i] $Right[$i])) { return $false }
            }
            return $true
        }
        'String' { return $Left.GetString() -ceq $Right.GetString() }
        default { return $Left.GetRawText() -ceq $Right.GetRawText() }
    }
}

function Get-JsonFieldDifferences {
    param([System.Text.Json.JsonElement] $RepoJson, [System.Text.Json.JsonElement] $HomeJson, [string] $Path)
    $repoFields = Get-JsonObjectMap $RepoJson
    $homeFields = Get-JsonObjectMap $HomeJson
    $allKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $repoFields.Keys) { [void] $allKeys.Add($key) }
    foreach ($key in $homeFields.Keys) { [void] $allKeys.Add($key) }
    $keys = [string[]] @($allKeys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($key in $keys) {
        # JSON Pointer escaping keeps keys containing '/' or '~' unambiguous.
        $field = $Path + '/' + $key.Replace('~', '~0').Replace('/', '~1')
        if (-not $repoFields.ContainsKey($key)) { [pscustomobject]@{ Kind = 'home-only'; Path = $field }; continue }
        if (-not $homeFields.ContainsKey($key)) { [pscustomobject]@{ Kind = 'repo-only'; Path = $field }; continue }
        $repoValue = $repoFields[$key]
        $homeValue = $homeFields[$key]
        if ($repoValue.ValueKind -ne $homeValue.ValueKind) { [pscustomobject]@{ Kind = 'type-changed'; Path = $field } }
        elseif ($repoValue.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            Get-JsonFieldDifferences $repoValue $homeValue $field
        }
        elseif (-not (Test-JsonEqual $repoValue $homeValue)) { [pscustomobject]@{ Kind = 'changed'; Path = $field } }
    }
}

function Find-ManagedAgentsBlock {
    param([string] $Text, [string] $BlockId, [string] $Label)
    $markers = [regex]::Matches($Text, '(?i)<!--\s*(?:BEGIN|END) AI-AGENT-DOTFILES:')
    if ($markers.Count -eq 0) { return $null }
    $pattern = '(?is)<!--\s*BEGIN AI-AGENT-DOTFILES:\s*(?<id>[^\s<>]+)\s*-->(?<content>.*?)<!--\s*END AI-AGENT-DOTFILES:\s*\k<id>\s*-->'
    $blocks = [regex]::Matches($Text, $pattern)
    # Every marker must belong to one complete block, including neighboring blocks.
    if ($markers.Count -ne 2 * $blocks.Count) { throw "invalid $Label managed block boundaries" }
    $selected = @($blocks | Where-Object { $_.Groups['id'].Value -ieq $BlockId })
    if ($selected.Count -eq 0) { throw "$Label has markers but no matching managed block" }
    if ($selected.Count -gt 1) { throw "multiple $Label managed blocks found" }
    return $selected[0]
}

function Get-ManagedAgentsBlockText {
    param(
        [Parameter(Mandatory)] [string] $RepoText,
        [string] $BlockId = 'codex/AGENTS.md'
    )
    $body = $RepoText.TrimEnd("`r", "`n")
    return "<!-- BEGIN AI-AGENT-DOTFILES: $BlockId -->`n$body`n<!-- END AI-AGENT-DOTFILES: $BlockId -->"
}

function Get-ManagedAgentsBlockResult {
    # The repo owns one marked block. Existing content outside that block is preserved.
    # A legacy home file without markers is migrated only when it already equals the repo
    # content; otherwise the caller must add the block manually so no personal section is
    # silently absorbed into the managed region.
    param(
        [Parameter(Mandatory)] [string] $RepoText,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $HomeText,
        [Parameter(Mandatory)] [bool] $HomeExists,
        [string] $BlockId = 'codex/AGENTS.md',
        [string] $Label = 'Codex/AGENTS.md'
    )
    if ($RepoText -match '<!--\s*(?:BEGIN|END) AI-AGENT-DOTFILES:') {
        throw "repository $Label must not contain config-sync managed markers"
    }
    $blockText = Get-ManagedAgentsBlockText -RepoText $RepoText -BlockId $BlockId
    $content = if ($HomeExists) { $HomeText } else { '' }
    $block = Find-ManagedAgentsBlock -Text $content -BlockId $BlockId -Label $Label
    if ($null -ne $block) {
        $updated = $content.Remove($block.Index, $block.Length).Insert($block.Index, $blockText)
        return [pscustomobject] @{ HasBlock = $true; Changed = ($updated -cne $content); Content = $updated }
    }
    if (-not $HomeExists) {
        return [pscustomobject] @{ HasBlock = $false; Changed = $true; Content = ($blockText + "`n") }
    }
    if ($HomeText.TrimEnd("`r", "`n") -cne $RepoText.TrimEnd("`r", "`n")) {
        throw "$Label has no AI-AGENT-DOTFILES managed block; add one manually before pulling"
    }
    return [pscustomobject] @{ HasBlock = $false; Changed = $true; Content = ($blockText + "`n") }
}

function Get-ManagedAgentsContent {
    # Return the managed block body for config-push, or $null when the home file has no block.
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $HomeText,
        [string] $BlockId = 'codex/AGENTS.md',
        [string] $Label = 'Codex/AGENTS.md'
    )
    $block = Find-ManagedAgentsBlock -Text $HomeText -BlockId $BlockId -Label $Label
    if ($null -eq $block) { return $null }
    $inner = $block.Groups['content'].Value
    $inner = $inner -replace '^\r?\n', ''
    return ($inner.TrimEnd("`r", "`n") + "`n")
}

function Get-ConfigFiles {
    # Every non-excluded file under a directory, as FullName plus Rel (relative to
    # the directory, native separators).
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
    )
    $rootFull = (Resolve-Path -LiteralPath $Root).Path
    foreach ($file in (Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force)) {
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
    Assert-PlainPathNoReparse -Path $SrcItem -AllowMissing -MessagePrefix "$ItemLabel source contains a reparse point"
    Assert-PlainPathNoReparse -Path $DstItem -AllowMissing -MessagePrefix "$ItemLabel destination contains a reparse point"
    if (-not (Test-Path -LiteralPath $SrcItem)) { return $ops }   # nothing to plan

    $files = if (Test-Path -LiteralPath $SrcItem -PathType Leaf) {
        [pscustomobject] @{ FullName = $SrcItem; Rel = '' }
    }
    else {
        Get-ConfigFiles -Root $SrcItem -Excluded $Excluded
    }

    # Single files and directories share the same comparison; never prune.
    foreach ($file in $files) {
        $dst = if ($file.Rel) { Join-Path $DstItem $file.Rel } else { $DstItem }
        $rel = if ($file.Rel) { "$ItemLabel/$($file.Rel -replace '\\','/')" } else { $ItemLabel }
        Assert-PlainPathNoReparse -Path $file.FullName -MessagePrefix "$rel source contains a reparse point"
        Assert-PlainPathNoReparse -Path $dst -AllowMissing -MessagePrefix "$rel destination contains a reparse point"
        if (Test-Path -LiteralPath $dst -PathType Container) { throw "$rel destination is a directory." }
        $dstExists = Test-Path -LiteralPath $dst -PathType Leaf
        if (-not $dstExists -and $null -ne (Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue)) {
            throw "$rel destination is not a readable file."
        }
        $srcHash = Get-FileHashHex $file.FullName
        $dstHash = if ($dstExists) { Get-FileHashHex $dst } else { $null }
        $action = if (-not $dstExists) { 'add' }
        elseif ($srcHash -cne $dstHash) { 'update' }
        else { 'noop' }
        if ($action -ne 'noop') {
            $ops.Add(@{
                Src               = $file.FullName
                Dst               = $dst
                Rel               = $rel
                Action            = $action
                ExpectedSrcHash   = $srcHash
                ExpectedDstExists = $dstExists
                ExpectedDstHash   = $dstHash
            })
        }
    }
    return $ops
}

function Assert-ConfigPullOpUnchanged {
    param([Parameter(Mandatory)] [hashtable] $Op)

    Assert-PlainPathNoReparse -Path $Op.Src -AllowMissing -MessagePrefix "$($Op.Rel) source contains a reparse point"
    if (-not (Test-Path -LiteralPath $Op.Src -PathType Leaf)) {
        throw "$($Op.Rel) source changed since planning. Run config pull again to review it."
    }
    if ($Op.ContainsKey('ExpectedSrcHash') -and $null -ne $Op.ExpectedSrcHash) {
        if ((Get-FileHashHex $Op.Src) -cne $Op.ExpectedSrcHash) {
            throw "$($Op.Rel) source changed since planning. Run config pull again to review it."
        }
    }
    Assert-PlainPathNoReparse -Path $Op.Dst -AllowMissing -MessagePrefix "$($Op.Rel) destination contains a reparse point"
    $existing = Get-Item -LiteralPath $Op.Dst -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing -and ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$($Op.Rel) destination is a reparse point; refusing to write."
    }
    if ($Op.Action -eq 'add') {
        if ($null -ne $existing) {
            throw "$($Op.Rel) changed since planning (destination already exists). Run config pull again to review it."
        }
        return
    }
    if ($null -eq $existing -or $existing.PSIsContainer) {
        throw "$($Op.Rel) changed since planning. Run config pull again to review it."
    }
    if ($Op.ContainsKey('ExpectedDstHash') -and $null -ne $Op.ExpectedDstHash) {
        if ((Get-FileHashHex $Op.Dst) -cne $Op.ExpectedDstHash) {
            throw "$($Op.Rel) changed since planning. Run config pull again to review it."
        }
    }
}

function Write-CopyPlan {
    # One line per planned copy: adds in green, updates in yellow.
    param([Parameter(Mandatory)] [object[]] $Plan)
    foreach ($op in $Plan) {
        $color = if ($op.Action -eq 'add') { 'Green' } else { 'Yellow' }
        Write-Host ('  {0,-7} {1}' -f $op.Action, $op.Rel) -ForegroundColor $color
    }
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

function Invoke-ConfigPlanWrite {
    # Applies every planned copy or generated content, creating destination parents as needed.
    # -Progress prints one green line per file, the way config-pull reports during apply.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plan,
        [switch] $Progress
    )
    foreach ($op in $Plan) {
        $parent = Split-Path -Parent $op.Dst
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if ($op.ContainsKey('Mode') -and $op.Mode -eq 'content') {
            [IO.File]::WriteAllText($op.Dst, [string] $op.Content, [Text.UTF8Encoding]::new($false))
        }
        else {
            Copy-Item -LiteralPath $op.Src -Destination $op.Dst -Force
        }
        if ($Progress) { Write-Host ('  {0,-7} {1}' -f $op.Action, $op.Rel) -ForegroundColor Green }
    }
}
