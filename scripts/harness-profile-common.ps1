#requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the status/build/apply-harness-profile.ps1 scripts.

.DESCRIPTION
    Dot-source only. Defines the component-kind contract and helper functions;
    it performs no writes and does no work at import time.
#>

# Profile buckets that may list component ids, in the order their ids are selected.
$script:HarnessBuckets = @('Rules', 'Prompts', 'Commands', 'Agents', 'ClaudeSettings', 'CodexAgents')
$script:HarnessPlatforms = @('Claude', 'Codex')
# Kind -> output Mode, allowed project-relative targets (a trailing '/' allows files below that
# directory) and the output keys allowed besides Target and Mode.
$script:HarnessKinds = @{
    Rule           = @{ Mode = 'ManagedBlock'; Allowed = @('AGENTS.md', 'CLAUDE.md'); Extra = @('BlockId') }
    Prompt         = @{ Mode = 'GeneratedOnly'; Allowed = @('.agent-harness/generated/'); Extra = @() }
    Command        = @{ Mode = 'DirectoryFiles'; Allowed = @('.claude/commands/'); Extra = @('Source') }
    ClaudeAgent    = @{ Mode = 'DirectoryFiles'; Allowed = @('.claude/agents/'); Extra = @('Source') }
    CodexPrompt    = @{ Mode = 'DirectoryFiles'; Allowed = @('.codex/prompts/'); Extra = @('Source') }
    CodexAgent     = @{ Mode = 'DirectoryFiles'; Allowed = @('.codex/agents/'); Extra = @('Source') }
    ClaudeSettings = @{ Mode = 'StructuredMerge'; Allowed = @('.claude/settings.json'); Extra = @('MergeStrategy') }
}
$script:HarnessDrivePattern = '(?<![A-Za-z])[A-Za-z]:[\\/]'
$script:HarnessUncPattern = '\\\\[A-Za-z0-9?.$_-]'

function Import-HarnessData {
    param([string] $Path, [string] $Kind, [string[]] $Required, [string[]] $Allowed)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Kind data file: $Path" }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    if (-not $data.ContainsKey('SchemaVersion')) { throw "$Kind data file is missing SchemaVersion: $Path" }
    if ([int] $data.SchemaVersion -ne 1) { throw "$Kind data file has unsupported SchemaVersion $($data.SchemaVersion): $Path" }
    foreach ($key in $Required) {
        if (-not $data.ContainsKey($key)) { throw "$Kind data file is missing required key '$key': $Path" }
    }
    foreach ($key in $data.Keys) {
        if ($key -notin $Allowed) { throw "$Kind data file contains unknown key '$key': $Path" }
    }
    if ($data.ContainsKey('Components')) {
        if (-not ($data.Components -is [hashtable])) { throw "$Kind Components must be a hashtable: $Path" }
        foreach ($key in $data.Components.Keys) {
            if ($key -notin $script:HarnessBuckets) { throw "$Kind Components data file contains unknown key '$key': $Path" }
        }
    }
    return $data
}

function Select-HarnessStableUnique {
    param([AllowNull()] [object[]] $Values)

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        $key = if ($value -is [string]) { $value } else { $value | ConvertTo-Json -Depth 20 -Compress }
        if ($seen.Add($key)) { $result.Add($value) }
    }
    return @($result)
}

function Test-HarnessPrivatePathText {
    param([AllowNull()] [string] $Text)
    return (-not [string]::IsNullOrWhiteSpace($Text)) -and
        (($Text -match $script:HarnessDrivePattern) -or ($Text -match ('^' + $script:HarnessUncPattern)))
}

function Assert-HarnessNoPrivatePaths {
    param([AllowEmptyCollection()] [string[]] $Paths)

    $binary = @('.png', '.jpg', '.jpeg', '.gif', '.pdf', '.zip', '.7z', '.exe', '.dll', '.sqlite', '.db')
    $findings = foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if ([System.IO.Path]::GetExtension($path).ToLowerInvariant() -in $binary) { continue }
        $line = 0
        foreach ($text in [System.IO.File]::ReadLines($path)) {
            $line++
            if ($text -match $script:HarnessDrivePattern) { "${path}:$line Drive-absolute path" }
            if ($text -match $script:HarnessUncPattern) { "${path}:$line UNC path" }
        }
    }
    if (@($findings).Count -gt 0) { throw "Machine-private path scan failed: $(@($findings) -join '; ')" }
}

# Validates a project-relative path string and returns it with '/' separators. Rejecting
# rooted, drive, URL and '..' forms keeps every joined path inside its root.
function Test-HarnessRelativePath {
    param([string] $Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) { throw 'Path candidate must not be empty.' }
    if ($Candidate -match '^[a-z][a-z0-9+.-]*://') { throw "URL references are not allowed: $Candidate" }
    if ($Candidate -match '^[~/]') { throw "Home-rooted or slash-rooted paths are not allowed: $Candidate" }
    if ([System.IO.Path]::IsPathFullyQualified($Candidate) -or $Candidate.StartsWith('\\')) {
        throw "Absolute or UNC paths are not allowed: $Candidate"
    }
    if (Test-HarnessPrivatePathText -Text $Candidate) { throw "Machine-private path reference is not allowed: $Candidate" }
    $relative = $Candidate -replace '\\', '/'
    foreach ($part in ($relative -split '/')) {
        if ($part -eq '..') { throw "Path escapes are not allowed: $Candidate" }
        if ($part -eq '.' -or [string]::IsNullOrWhiteSpace($part)) { throw "Ambiguous path segments are not allowed: $Candidate" }
    }
    return $relative
}

function Get-HarnessRelativePath {
    param([string] $Root, [string] $Path)
    return ([System.IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/')
}

function Get-HarnessFileHash {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Add-HarnessLibraryProfile {
    param([string] $Name, [string] $ProfilesRoot, $Resolved, $Visiting)

    if ($Name -notmatch '^[\w-]+$') { throw "Only a profile id is allowed here, not a path: $Name" }
    $path = Join-Path $ProfilesRoot "$Name.psd1"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Profile '$Name' was not found under harness-source/profiles." }
    if (@($Resolved | Where-Object Name -EQ $Name).Count -gt 0) { return }
    if (-not $Visiting.Add($Name)) { throw "Profile Extends contains a cycle at '$Name'." }
    $data = Import-HarnessData -Path $path -Kind 'library profile' -Required @('Name', 'TargetPlatforms') -Allowed @(
        'SchemaVersion', 'Name', 'TargetPlatforms', 'Extends', 'Components', 'Future')
    foreach ($parent in @($data['Extends'] | Where-Object { $_ })) {
        Add-HarnessLibraryProfile -Name $parent -ProfilesRoot $ProfilesRoot -Resolved $Resolved -Visiting $Visiting
    }
    [void] $Visiting.Remove($Name)
    $Resolved.Add([pscustomobject] @{ Name = $Name; Path = $path; Data = $data })
}

function Get-HarnessComponentSource {
    param($Component, $Output)

    $name = if ($Output.ContainsKey('Source') -and -not [string]::IsNullOrWhiteSpace([string] $Output.Source)) { [string] $Output.Source } else { 'content.md' }
    if ($name -match '[\\/]' -or $name -in @('.', '..')) {
        throw "Component '$($Component.Id)' DirectoryFiles Source must be a single relative file name: $name"
    }
    $path = Join-Path $Component.Directory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Component '$($Component.Id)' is missing $name." }
    return $path
}

function Test-HarnessComponent {
    param($Component, [string] $ProjectRoot)

    $id = $Component.Id
    $contract = $script:HarnessKinds[$Component.Kind]
    if ($null -eq $contract) { throw "Unsupported harness component Kind '$($Component.Kind)'." }
    if (-not $Component.Data.ContainsKey('Outputs')) { throw "Component '$id' is missing Outputs." }
    $outputs = @($Component.Data.Outputs)
    if ($outputs.Count -eq 0) { throw "Component '$id' must declare at least one output." }
    $required = @{ Rule = 'content.md'; Prompt = 'content.md'; ClaudeSettings = 'settings.json' }[$Component.Kind]
    if ($required -and -not (Test-Path -LiteralPath (Join-Path $Component.Directory $required) -PathType Leaf)) {
        throw "Component '$id' is missing required $required."
    }
    if ($Component.Kind -eq 'ClaudeSettings') {
        try { $null = Get-Content -Raw -LiteralPath (Join-Path $Component.Directory 'settings.json') | ConvertFrom-Json }
        catch { throw "Component '$id' settings.json is not valid JSON: $($_.Exception.Message)" }
    }
    foreach ($platform in @($Component.Data.TargetPlatforms)) {
        if ($platform -notin $script:HarnessPlatforms) { throw "Target platform validation failed: $id declares unsupported TargetPlatform '$platform'." }
    }

    foreach ($output in $outputs) {
        if (-not ($output -is [System.Collections.IDictionary])) { throw "Component '$id' has an output that is not a hashtable." }
        foreach ($key in $output.Keys) {
            if ($key -notin (@('Target', 'Mode') + $contract.Extra)) { throw "Component '$id' Kind '$($Component.Kind)' has unsupported output key '$key'." }
        }
        if ([string]::IsNullOrWhiteSpace([string] $output['Target'])) { throw "Component '$id' has an output without Target." }
        if ([string] $output['Mode'] -ne $contract.Mode) { throw "Component '$id' Kind '$($Component.Kind)' requires Mode '$($contract.Mode)'." }
        if ($output.ContainsKey('MergeStrategy') -and [string] $output.MergeStrategy -ne 'JsonObject') {
            throw "Component '$id' StructuredMerge requires MergeStrategy 'JsonObject'."
        }
        $relative = Test-HarnessRelativePath -Candidate ([string] $output.Target)
        $allowed = @($contract.Allowed | Where-Object {
                if ($_.EndsWith('/')) { $relative.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) } else { $relative -ieq $_ } })
        if ($allowed.Count -eq 0) { throw "Target path is outside the $($Component.Kind) allowlist ($($contract.Allowed -join ', ')): $($output.Target)" }
        if ($contract.Mode -eq 'DirectoryFiles') { $null = Get-HarnessComponentSource -Component $Component -Output $output }

        [pscustomobject] @{
            ComponentId = $id
            Mode        = $output.Mode
            Target      = $relative
            FullPath    = Join-Path $ProjectRoot ($relative -replace '/', '\')
            Output      = $output
        }
    }
}

function New-HarnessProfilePlan {
    param([string] $RepoRoot, [string] $ProjectRoot, [string] $Mode)

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '..' }
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { throw 'ProjectRoot must not be empty.' }
    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $project = (Resolve-Path -LiteralPath $ProjectRoot).Path

    $profilePath = Join-Path $project '.agent-harness/profile.psd1'
    $projectProfile = Import-HarnessData -Path $profilePath -Kind 'project profile' -Required @('Name', 'TargetPlatforms') -Allowed @(
        'SchemaVersion', 'Name', 'TargetPlatforms', 'Extends', 'Components', 'Future', 'RequiredEnv')
    $resolved = [System.Collections.Generic.List[object]]::new()
    $visiting = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($projectProfile['Extends'] | Where-Object { $_ })) {
        Add-HarnessLibraryProfile -Name $name -ProfilesRoot (Join-Path $repo 'harness-source/profiles') -Resolved $resolved -Visiting $visiting
    }

    # Library profiles apply parent-first, the project profile last; lists are unioned in that order.
    $layers = @($resolved | ForEach-Object Data) + @($projectProfile)
    $platforms = @(Select-HarnessStableUnique -Values @($layers | ForEach-Object { $_.TargetPlatforms }))
    foreach ($platform in $platforms) {
        if ($platform -notin $script:HarnessPlatforms) { throw "Unsupported TargetPlatform '$platform'. Valid values: $($script:HarnessPlatforms -join ', ')" }
    }
    $componentIds = @(Select-HarnessStableUnique -Values @(foreach ($bucket in $script:HarnessBuckets) {
                foreach ($layer in $layers) {
                    if ($layer['Components'] -is [hashtable]) { @($layer['Components'][$bucket]) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string] $_ } }
                }
            }))

    $componentsRoot = Join-Path $repo 'harness-source/components'
    if (-not (Test-Path -LiteralPath $componentsRoot -PathType Container)) { throw "Missing harness components root: $componentsRoot" }
    $all = @(Get-ChildItem -LiteralPath $componentsRoot -Directory -Recurse -Force |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'component.psd1') -PathType Leaf } |
            Sort-Object FullName | ForEach-Object {
                $path = Join-Path $_.FullName 'component.psd1'
                $data = Import-HarnessData -Path $path -Kind 'component' -Required @('Id', 'Kind', 'TargetPlatforms') -Allowed @(
                    'SchemaVersion', 'Id', 'Kind', 'TargetPlatforms', 'Requires', 'Conflicts', 'Outputs', 'Future')
                [pscustomobject] @{ Id = [string] $data.Id; Kind = [string] $data.Kind; Directory = $_.FullName; Path = $path; Data = $data }
            })
    $dupes = @($all | Group-Object Id | Where-Object Count -GT 1 | ForEach-Object { "$($_.Name) ($($_.Count))" })
    if ($dupes.Count -gt 0) { throw "Duplicate harness component Id(s): $($dupes -join ', ')" }
    $index = @{}
    foreach ($component in $all) { $index[$component.Id] = $component }
    $selected = @(foreach ($id in $componentIds) {
            if (-not $index.ContainsKey($id)) { throw "Profile references unknown component '$id'." }
            $index[$id]
        })

    $targets = @(foreach ($component in $selected) { Test-HarnessComponent -Component $component -ProjectRoot $project })
    foreach ($component in $selected) {
        if (@($platforms | Where-Object { $_ -in @($component.Data.TargetPlatforms) }).Count -eq 0) {
            throw "Target platform validation failed: $($component.Id) does not support any selected target platform."
        }
        foreach ($required in @($component.Data['Requires'] | Where-Object { $_ })) {
            if ($required -notin $componentIds) { throw "Component validation failed: $($component.Id) requires '$required'." }
        }
        foreach ($conflict in @($component.Data['Conflicts'] | Where-Object { $_ })) {
            if ($conflict -in $componentIds) { throw "Component validation failed: $($component.Id) conflicts with '$conflict'." }
        }
    }

    $sources = [System.Collections.Generic.List[object]]::new()
    $sources.Add([pscustomobject] @{ Kind = 'ProjectProfile'; Path = $profilePath; Hash = Get-HarnessFileHash -Path $profilePath })
    foreach ($libraryProfile in $resolved) {
        $sources.Add([pscustomobject] @{ Kind = 'LibraryProfile'; Name = $libraryProfile.Name; Path = $libraryProfile.Path; Hash = Get-HarnessFileHash -Path $libraryProfile.Path })
    }
    foreach ($component in $selected) {
        foreach ($file in Get-ChildItem -LiteralPath $component.Directory -File -Recurse -Force | Sort-Object FullName) {
            $sources.Add([pscustomobject] @{ Kind = 'Component'; ComponentId = $component.Id; Path = $file.FullName; Hash = Get-HarnessFileHash -Path $file.FullName })
        }
    }

    return [pscustomobject] @{
        Mode             = $Mode
        RepoRoot         = $repo
        ProjectRoot      = $project
        ProfilePath      = $profilePath
        ResolvedProfiles = @($resolved)
        TargetPlatforms  = $platforms
        ComponentIds     = $componentIds
        Components       = $selected
        Targets          = $targets
        SourceFiles      = @($sources)
    }
}

function ConvertTo-HarnessPlainObject {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $result = [ordered] @{}
        $pairs = if ($Value -is [System.Collections.IDictionary]) { $Value.GetEnumerator() } else { $Value.PSObject.Properties }
        foreach ($pair in $pairs) {
            $key = if ($Value -is [System.Collections.IDictionary]) { [string] $pair.Key } else { $pair.Name }
            $result[$key] = ConvertTo-HarnessPlainObject -Value $pair.Value
        }
        return $result
    }
    if ($Value -is [array]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-HarnessPlainObject -Value $item)) }
        return , $items.ToArray()
    }
    return $Value
}

function Merge-HarnessJsonObject {
    param([AllowNull()] $Base, [AllowNull()] $Overlay)

    if ($null -eq $Base) { return $Overlay }
    if ($null -eq $Overlay) { return $Base }
    if ($Base -is [System.Collections.IDictionary] -and $Overlay -is [System.Collections.IDictionary]) {
        $merged = [ordered] @{}
        foreach ($key in $Base.Keys) { $merged[[string] $key] = $Base[$key] }
        foreach ($key in $Overlay.Keys) {
            # Assign directly in each branch: an if-expression would unroll array values.
            if ($merged.Contains($key)) { $merged[[string] $key] = Merge-HarnessJsonObject -Base $merged[$key] -Overlay $Overlay[$key] }
            else { $merged[[string] $key] = $Overlay[$key] }
        }
        return $merged
    }
    if (($Base -is [array]) -or ($Overlay -is [array])) { return , @(Select-HarnessStableUnique -Values (@($Base) + @($Overlay))) }
    return $Overlay
}

function Get-HarnessPlanComponent {
    param($Plan, $Target)
    return @($Plan.Components | Where-Object Id -EQ $Target.ComponentId)[0]
}

# Merges the settings.json of every component in $Targets over $Base (an ordered dictionary).
function Merge-HarnessSettings {
    param($Plan, $Base, [object[]] $Targets)

    $merged = $Base
    foreach ($target in $Targets) {
        $path = Join-Path (Get-HarnessPlanComponent -Plan $Plan -Target $target).Directory 'settings.json'
        $merged = Merge-HarnessJsonObject -Base $merged -Overlay (ConvertTo-HarnessPlainObject -Value (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json))
    }
    return $merged
}

function Get-HarnessManagedBlocks {
    param($Plan, [object[]] $Targets)

    foreach ($target in $Targets) {
        $content = Get-Content -Raw -LiteralPath (Join-Path (Get-HarnessPlanComponent -Plan $Plan -Target $target).Directory 'content.md')
        $blockId = if ($target.Output['BlockId']) { [string] $target.Output['BlockId'] } else { [string] $target.ComponentId }
        [pscustomobject] @{
            Id   = $blockId
            Text = "<!-- BEGIN AGENT-HARNESS: $blockId -->`n$(($content ?? '').TrimEnd())`n<!-- END AGENT-HARNESS: $blockId -->"
        }
    }
}

function Get-HarnessJsonDenyList {
    param([AllowNull()] $Settings)

    if (-not ($Settings -is [System.Collections.IDictionary]) -or -not $Settings.Contains('permissions')) { return @() }
    $permissions = $Settings['permissions']
    if (-not ($permissions -is [System.Collections.IDictionary]) -or -not $permissions.Contains('deny')) { return @() }
    return @($permissions['deny'] | ForEach-Object { [string] $_ })
}

# Plans one change per apply target. A ManagedBlock target only replaces existing
# <!-- BEGIN/END AGENT-HARNESS: id --> blocks; an existing file without any marker is skipped.
function Get-HarnessApplyChanges {
    param($Plan)

    function New-HarnessChange([string] $Target, [string] $FullPath, [string] $Mode, [string] $Action, $Content, $Reason) {
        [pscustomobject] @{ Target = $Target; FullPath = $FullPath; Mode = $Mode; Action = $Action; Content = $Content; Reason = $Reason }
    }

    foreach ($group in @($Plan.Targets | Where-Object Mode -EQ 'ManagedBlock' | Group-Object Target)) {
        $fullPath = $group.Group[0].FullPath
        $blocks = @(Get-HarnessManagedBlocks -Plan $Plan -Targets @($group.Group))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            New-HarnessChange $group.Name $fullPath 'ManagedBlock' 'add' ((@($blocks.Text) -join "`n`n") + "`n") $null
            continue
        }
        $existing = [System.IO.File]::ReadAllText($fullPath)
        $content = $existing
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($block in $blocks) {
            $id = [regex]::Escape($block.Id)
            $pattern = "(?s)<!--\s*BEGIN AGENT-HARNESS:\s*$id\s*-->.*?<!--\s*END AGENT-HARNESS:\s*$id\s*-->"
            if ([regex]::IsMatch($content, $pattern)) {
                # Every occurrence of the block is replaced (ignoring case), as before the rewrite.
                $text = $block.Text
                $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $text },
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
            else { $missing.Add($block.Id) }
        }
        if ($missing.Count -eq $blocks.Count) {
            New-HarnessChange $group.Name $fullPath 'ManagedBlock' 'skip' $null 'existing file has no matching managed block marker'
            continue
        }
        $reason = if ($missing.Count -gt 0) { "missing block(s) skipped: $($missing -join ', ')" } else { $null }
        New-HarnessChange $group.Name $fullPath 'ManagedBlock' $(if ($content -ceq $existing) { 'noop' } else { 'update' }) $content $reason
    }

    foreach ($group in @($Plan.Targets | Where-Object Mode -EQ 'StructuredMerge' | Group-Object Target)) {
        $fullPath = $group.Group[0].FullPath
        $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
        $existingText = if ($exists) { Get-Content -Raw -LiteralPath $fullPath } else { $null }
        $existing = if ($exists) { ConvertTo-HarnessPlainObject -Value ($existingText | ConvertFrom-Json) } else { [ordered] @{} }
        $merged = Merge-HarnessSettings -Plan $Plan -Base $existing -Targets @($group.Group)
        $kept = @(Get-HarnessJsonDenyList -Settings $merged)
        foreach ($entry in @(Get-HarnessJsonDenyList -Settings $existing)) {
            if ($entry -cnotin $kept) { throw "StructuredMerge would remove permissions.deny entry '$entry' from $($group.Name)." }
        }
        $newText = ($merged | ConvertTo-Json -Depth 50) + "`n"
        $action = if (-not $exists) { 'add' } elseif ($newText -cne $existingText) { 'update' } else { 'noop' }
        New-HarnessChange $group.Name $fullPath 'StructuredMerge' $action $newText $null
    }

    foreach ($target in @($Plan.Targets | Where-Object Mode -EQ 'DirectoryFiles')) {
        $content = Get-Content -Raw -LiteralPath (Get-HarnessComponentSource -Component (Get-HarnessPlanComponent -Plan $Plan -Target $target) -Output $target.Output)
        $exists = Test-Path -LiteralPath $target.FullPath -PathType Leaf
        $action = if (-not $exists) { 'add' } elseif ($content -cne [System.IO.File]::ReadAllText($target.FullPath)) { 'update' } else { 'noop' }
        New-HarnessChange $target.Target $target.FullPath 'DirectoryFiles' $action $content $null
    }

    foreach ($target in @($Plan.Targets | Where-Object Mode -EQ 'GeneratedOnly')) {
        New-HarnessChange $target.Target $target.FullPath 'GeneratedOnly' 'skip' $null 'generated-only target is produced by build-harness-profile.ps1'
    }
}

function Invoke-HarnessSecretScan {
    param([string] $RepoRoot)

    $scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    if (-not (Test-Path -LiteralPath $scan -PathType Leaf)) { throw "Missing secret scan script: $scan" }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scan -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "scripts/scan-secrets.ps1 failed with exit code $LASTEXITCODE." }
}

function Assert-HarnessOutsideHome {
    param([AllowEmptyCollection()] [string[]] $Paths)

    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE) -or -not (Test-Path -LiteralPath $env:USERPROFILE)) { return }
    $homeRoot = (Resolve-Path -LiteralPath $env:USERPROFILE).Path.TrimEnd('\', '/')
    foreach ($path in @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $resolved = if (Test-Path -LiteralPath $path) { (Resolve-Path -LiteralPath $path).Path } else { $path }
        if ($resolved -ieq $homeRoot -or $resolved.StartsWith($homeRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to write inside the home directory: $resolved"
        }
    }
}
