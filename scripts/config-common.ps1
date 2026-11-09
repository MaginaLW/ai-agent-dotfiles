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

$script:CodexAgentsBlockId = 'codex/AGENTS.md'

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

function Merge-JsonNodeObject {
    param(
        [Parameter(Mandatory)] [System.Text.Json.Nodes.JsonObject] $Target,
        [Parameter(Mandatory)] [System.Text.Json.Nodes.JsonObject] $Overlay
    )
    foreach ($property in @($Overlay)) {
        $key = [string] $property.Key
        $overlayValue = $property.Value
        if ($Target.ContainsKey($key) -and
            $Target[$key] -is [System.Text.Json.Nodes.JsonObject] -and
            $overlayValue -is [System.Text.Json.Nodes.JsonObject]) {
            Merge-JsonNodeObject -Target $Target[$key] -Overlay $overlayValue
        }
        elseif ($null -eq $overlayValue) {
            $Target[$key] = $null
        }
        else {
            $Target[$key] = $overlayValue.DeepClone()
        }
    }
}

function Get-ClaudeSettingsMergeResult {
    # Merge repo-managed object keys into the live settings object. Home-only keys survive;
    # arrays are replaced as a whole, matching the field comparison's array semantics.
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $HomePath
    )
    $repoText = [IO.File]::ReadAllText($RepoPath)
    $homeText = [IO.File]::ReadAllText($HomePath)
    $repoDoc = $null
    $homeDoc = $null
    $mergedDoc = $null
    try {
        $repoDoc = [System.Text.Json.JsonDocument]::Parse($repoText)
        $homeDoc = [System.Text.Json.JsonDocument]::Parse($homeText)
        if ($repoDoc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or
            $homeDoc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'both JSON roots must be objects'
        }
        Assert-JsonUniqueObjectKeys $repoDoc.RootElement
        Assert-JsonUniqueObjectKeys $homeDoc.RootElement
        $repoNode = [System.Text.Json.Nodes.JsonNode]::Parse($repoText).AsObject()
        $homeNode = [System.Text.Json.Nodes.JsonNode]::Parse($homeText).AsObject()
        Merge-JsonNodeObject -Target $homeNode -Overlay $repoNode
        $options = [System.Text.Json.JsonSerializerOptions]::new()
        $options.WriteIndented = $true
        $content = $homeNode.ToJsonString($options) + "`n"
        $mergedDoc = [System.Text.Json.JsonDocument]::Parse($content)
        $changed = -not (Test-JsonEqual $mergedDoc.RootElement $homeDoc.RootElement)
        $fields = @(Get-JsonFieldDifferences $repoDoc.RootElement $homeDoc.RootElement '')
        [pscustomobject] @{
            Changed            = $changed
            Content            = $content
            HomeOnlyFieldCount = @($fields | Where-Object { $_.Kind -eq 'home-only' }).Count
        }
    }
    finally {
        if ($null -ne $repoDoc) { $repoDoc.Dispose() }
        if ($null -ne $homeDoc) { $homeDoc.Dispose() }
        if ($null -ne $mergedDoc) { $mergedDoc.Dispose() }
    }
}

function Get-CodexAgentsBlockPattern {
    $id = [regex]::Escape($script:CodexAgentsBlockId)
    return "(?s)<!--\s*BEGIN AI-AGENT-DOTFILES:\s*$id\s*-->.*?<!--\s*END AI-AGENT-DOTFILES:\s*$id\s*-->"
}

function Get-CodexAgentsBlockText {
    param([Parameter(Mandatory)] [string] $RepoText)
    $body = $RepoText.TrimEnd("`r", "`n")
    return "<!-- BEGIN AI-AGENT-DOTFILES: $($script:CodexAgentsBlockId) -->`n$body`n<!-- END AI-AGENT-DOTFILES: $($script:CodexAgentsBlockId) -->"
}

function Get-CodexAgentsManagedBlockResult {
    # The repo owns one marked block. Existing content outside that block is preserved.
    # A legacy home file without markers is migrated only when it already equals the repo
    # content; otherwise the caller must add the block manually so no personal section is
    # silently absorbed into the managed region.
    param(
        [Parameter(Mandatory)] [string] $RepoText,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $HomeText,
        [Parameter(Mandatory)] [bool] $HomeExists
    )
    if ($RepoText -match '<!--\s*(?:BEGIN|END) AI-AGENT-DOTFILES:') {
        throw 'repository Codex/AGENTS.md must not contain config-sync managed markers'
    }
    $blockText = Get-CodexAgentsBlockText -RepoText $RepoText
    $content = if ($HomeExists) { $HomeText } else { '' }
    $pattern = Get-CodexAgentsBlockPattern
    $matches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($matches.Count -gt 1) { throw 'multiple Codex/AGENTS.md managed blocks found' }
    if ($matches.Count -eq 1) {
        $updated = [regex]::Replace($content, $pattern,
            [System.Text.RegularExpressions.MatchEvaluator] { param($match) $blockText },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        return [pscustomobject] @{ HasBlock = $true; Changed = ($updated -cne $content); Content = $updated }
    }
    if (-not $HomeExists) {
        return [pscustomobject] @{ HasBlock = $false; Changed = $true; Content = ($blockText + "`n") }
    }
    if ($HomeText.TrimEnd("`r", "`n") -cne $RepoText.TrimEnd("`r", "`n")) {
        throw 'Codex/AGENTS.md has no AI-AGENT-DOTFILES managed block; add one manually before pulling'
    }
    return [pscustomobject] @{ HasBlock = $false; Changed = $true; Content = ($blockText + "`n") }
}

function Get-CodexAgentsManagedContent {
    # Return the managed block body for config-push, or $null when the home file has no block.
    param([Parameter(Mandatory)] [string] $HomeText)
    $id = [regex]::Escape($script:CodexAgentsBlockId)
    $pattern = "(?s)<!--\s*BEGIN AI-AGENT-DOTFILES:\s*$id\s*-->(?<content>.*?)<!--\s*END AI-AGENT-DOTFILES:\s*$id\s*-->"
    $matches = [regex]::Matches($HomeText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -gt 1) { throw 'multiple Codex/AGENTS.md managed blocks found' }
    $inner = $matches[0].Groups['content'].Value
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
        $action = if (-not (Test-Path -LiteralPath $dst)) { 'add' }
        elseif ((Get-FileHashHex $file.FullName) -ne (Get-FileHashHex $dst)) { 'update' }
        else { 'noop' }
        if ($action -ne 'noop') {
            $ops.Add(@{ Src = $file.FullName; Dst = $dst; Rel = $rel; Action = $action })
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
        if ($op.Mode -eq 'content') {
            [IO.File]::WriteAllText($op.Dst, [string] $op.Content, [Text.UTF8Encoding]::new($false))
        }
        else {
            Copy-Item -LiteralPath $op.Src -Destination $op.Dst -Force
        }
        if ($Progress) { Write-Host ('  {0,-7} {1}' -f $op.Action, $op.Rel) -ForegroundColor Green }
    }
}
