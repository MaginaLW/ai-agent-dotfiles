#requires -Version 7.0
<#
.SYNOPSIS
    Shared read-only helpers for project harness profile status/build/apply scripts.

.DESCRIPTION
    This file is intended to be dot-sourced. It defines helper functions only:
    no param block, no writes, no command execution, and no work at import time.
#>

function Resolve-HarnessRepoRoot {
    [CmdletBinding()]
    param([string] $RepoRoot)

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Join-Path $PSScriptRoot '..'
    }
    return (Resolve-Path -LiteralPath $RepoRoot).Path
}

function Resolve-HarnessProjectRoot {
    [CmdletBinding()]
    param([string] $ProjectRoot = (Get-Location).Path)

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        throw 'ProjectRoot must not be empty.'
    }
    return (Resolve-Path -LiteralPath $ProjectRoot).Path
}

function Import-HarnessDataFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Kind,
        [int] $SchemaVersion = 1,
        [string[]] $RequiredKeys = @()
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing $Kind data file: $Path"
    }

    $data = Import-PowerShellDataFile -LiteralPath $Path
    if (-not ($data -is [hashtable])) {
        throw "$Kind data file must import as a hashtable: $Path"
    }
    if (-not $data.ContainsKey('SchemaVersion')) {
        throw "$Kind data file is missing SchemaVersion: $Path"
    }
    if ([int] $data.SchemaVersion -ne $SchemaVersion) {
        throw "$Kind data file has unsupported SchemaVersion $($data.SchemaVersion): $Path"
    }
    foreach ($key in $RequiredKeys) {
        if (-not $data.ContainsKey($key)) {
            throw "$Kind data file is missing required key '$key': $Path"
        }
    }

    return $data
}

function Test-HarnessKnownKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Data,
        [Parameter(Mandatory)] [string[]] $AllowedKeys,
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [string] $Path
    )

    foreach ($key in $Data.Keys) {
        if ($key -notin $AllowedKeys) {
            throw "$Kind data file contains unknown key '$key': $Path"
        }
    }
}

function Get-HarnessProjectProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $root = Resolve-HarnessProjectRoot -ProjectRoot $ProjectRoot
    $path = Join-Path $root '.agent-harness/profile.psd1'
    $profile = Import-HarnessDataFile -Path $path -Kind 'project profile' -RequiredKeys @('SchemaVersion', 'Name', 'TargetPlatforms')
    Test-HarnessKnownKeys -Data $profile -Kind 'project profile' -Path $path -AllowedKeys @(
        'SchemaVersion', 'Name', 'TargetPlatforms', 'Extends', 'Components', 'Future',
        'RequiredEnv'
    )

    return [pscustomobject] @{
        Path        = $path
        ProjectRoot = $root
        Data        = $profile
    }
}

function Resolve-HarnessProfileExtends {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Profile,
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    $profilesRoot = Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) 'harness-source/profiles'
    $resolved = [System.Collections.Generic.List[object]]::new()
    $visiting = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Resolve-OneHarnessProfile {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [System.Collections.Generic.List[object]] $Resolved,
            [System.Collections.Generic.HashSet[string]] $Visiting,
            [System.Collections.Generic.HashSet[string]] $Visited,
            [Parameter(Mandatory)] [string] $ProfilesRoot
        )

        $safeName = Normalize-HarnessCandidatePath -Candidate $Name -AllowedRoot $ProfilesRoot -LeafOnly
        $profilePath = Join-Path $ProfilesRoot "$safeName.psd1"
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
            throw "Profile '$Name' was not found under harness-source/profiles."
        }
        if ($Visited.Contains($safeName)) { return }
        if (-not $Visiting.Add($safeName)) {
            throw "Profile Extends contains a cycle at '$safeName'."
        }

        $data = Import-HarnessDataFile -Path $profilePath -Kind 'library profile' -RequiredKeys @('SchemaVersion', 'Name', 'TargetPlatforms')
        Test-HarnessKnownKeys -Data $data -Kind 'library profile' -Path $profilePath -AllowedKeys @(
            'SchemaVersion', 'Name', 'TargetPlatforms', 'Extends', 'Components', 'Future'
        )
        foreach ($parent in @($data.Extends)) {
            Resolve-OneHarnessProfile -Name $parent -Resolved $Resolved -Visiting $Visiting -Visited $Visited -ProfilesRoot $ProfilesRoot
        }

        [void] $Visiting.Remove($safeName)
        [void] $Visited.Add($safeName)
        $Resolved.Add([pscustomobject] @{ Name = $safeName; Path = $profilePath; Data = $data })
    }

    foreach ($name in @($Profile.Extends)) {
        Resolve-OneHarnessProfile -Name $name -Resolved $resolved -Visiting $visiting -Visited $visited -ProfilesRoot $profilesRoot
    }
    return @($resolved)
}

function Get-HarnessComponentDirectories {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $componentsRoot = Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) 'harness-source/components'
    if (-not (Test-Path -LiteralPath $componentsRoot -PathType Container)) {
        throw "Missing harness components root: $componentsRoot"
    }

    Get-ChildItem -LiteralPath $componentsRoot -Directory -Recurse -Force |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'component.psd1') -PathType Leaf } |
        Sort-Object FullName
}

function Get-HarnessComponents {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in Get-HarnessComponentDirectories -RepoRoot $RepoRoot) {
        $path = Join-Path $dir.FullName 'component.psd1'
        $data = Import-HarnessDataFile -Path $path -Kind 'component' -RequiredKeys @('SchemaVersion', 'Id', 'Kind', 'TargetPlatforms')
        Test-HarnessKnownKeys -Data $data -Kind 'component' -Path $path -AllowedKeys @(
            'SchemaVersion', 'Id', 'Kind', 'TargetPlatforms', 'Requires', 'Conflicts', 'Outputs', 'Future'
        )
        $items.Add([pscustomobject] @{
                Id        = [string] $data.Id
                Kind      = [string] $data.Kind
                Directory = $dir.FullName
                Path      = $path
                Data      = $data
            })
    }
    return @($items)
}

function Test-HarnessUniqueComponentIds {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Components)

    $dupes = @($Components | Group-Object Id | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count -gt 0) {
        $detail = $dupes | ForEach-Object { "$($_.Name) ($($_.Count))" }
        throw "Duplicate harness component Id(s): $($detail -join ', ')"
    }
    return $true
}

function Test-HarnessRequiresAndConflicts {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $SelectedComponents,
        [Parameter(Mandatory)] [hashtable] $ComponentIndex
    )

    $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($component in $SelectedComponents) {
        [void] $selected.Add([string] $component.Id)
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($component in $SelectedComponents) {
        foreach ($required in @($component.Data.Requires)) {
            if (-not $ComponentIndex.ContainsKey($required)) {
                $errors.Add("$($component.Id) requires unknown component '$required'.")
            }
            elseif (-not $selected.Contains($required)) {
                $errors.Add("$($component.Id) requires '$required'.")
            }
        }
        foreach ($conflict in @($component.Data.Conflicts)) {
            if ($selected.Contains($conflict)) {
                $errors.Add("$($component.Id) conflicts with '$conflict'.")
            }
        }
    }
    if ($errors.Count -gt 0) {
        throw "Component dependency/conflict validation failed: $($errors -join ' ')"
    }
    return $true
}

function Test-HarnessTargetPlatforms {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $TargetPlatforms,
        [AllowEmptyCollection()] [object[]] $SelectedComponents,
        [switch] $RequireEveryComponentOnEveryPlatform
    )

    $valid = @('Claude', 'Codex')
    foreach ($platform in @($TargetPlatforms)) {
        if ($platform -notin $valid) {
            throw "Unsupported TargetPlatform '$platform'. Valid values: $($valid -join ', ')"
        }
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($component in $SelectedComponents) {
        $supported = @($component.Data.TargetPlatforms)
        foreach ($platform in $supported) {
            if ($platform -notin $valid) {
                $errors.Add("$($component.Id) declares unsupported TargetPlatform '$platform'.")
            }
        }
        $overlap = @($TargetPlatforms | Where-Object { $_ -in $supported })
        if ($overlap.Count -eq 0) {
            $errors.Add("$($component.Id) does not support any selected target platform.")
        }
        if (-not $RequireEveryComponentOnEveryPlatform) { continue }
        foreach ($platform in @($TargetPlatforms)) {
            if ($platform -notin $supported) {
                $errors.Add("$($component.Id) does not support $platform.")
            }
        }
    }
    if ($errors.Count -gt 0) {
        throw "Target platform validation failed: $($errors -join ' ')"
    }
    return $true
}

function Select-HarnessStableUnique {
    [CmdletBinding()]
    param([AllowNull()] [object[]] $Values)

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        $key = if ($value -is [string]) { $value } else { ($value | ConvertTo-Json -Depth 20 -Compress) }
        if ($seen.Add($key)) {
            $result.Add($value)
        }
    }
    return @($result)
}

function Merge-HarnessProfileObject {
    [CmdletBinding()]
    param(
        [AllowNull()] $Base,
        [AllowNull()] $Overlay
    )

    if ($null -eq $Base) { return $Overlay }
    if ($null -eq $Overlay) { return $Base }

    if ($Base -is [hashtable] -and $Overlay -is [hashtable]) {
        $merged = @{}
        foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }
        foreach ($key in $Overlay.Keys) {
            if ($merged.ContainsKey($key)) {
                $merged[$key] = Merge-HarnessProfileObject -Base $merged[$key] -Overlay $Overlay[$key]
            }
            else {
                $merged[$key] = $Overlay[$key]
            }
        }
        return $merged
    }

    if (($Base -is [array]) -or ($Overlay -is [array])) {
        return Select-HarnessStableUnique -Values (@($Base) + @($Overlay))
    }

    return $Overlay
}

function Merge-HarnessProfiles {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $ResolvedProfiles,
        [Parameter(Mandatory)] [hashtable] $ProjectProfile
    )

    $merged = @{}
    foreach ($profile in $ResolvedProfiles) {
        $merged = Merge-HarnessProfileObject -Base $merged -Overlay $profile.Data
    }
    return Merge-HarnessProfileObject -Base $merged -Overlay $ProjectProfile
}

function Test-HarnessMachinePrivatePathText {
    [CmdletBinding()]
    param([AllowNull()] [string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '(?<![A-Za-z])[A-Za-z]:[\\/]') { return $true }
    if ($Text -match '^\\\\[A-Za-z0-9?.$_-]') { return $true }
    return $false
}

function Find-HarnessMachinePrivatePaths {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Paths)

    $binaryExt = @('.png', '.jpg', '.jpeg', '.gif', '.pdf', '.zip', '.7z', '.exe', '.dll', '.sqlite', '.db')
    $patterns = @(
        @{ Name = 'Drive-absolute path'; Regex = '(?<![A-Za-z])[A-Za-z]:[\\/]' },
        @{ Name = 'UNC path'; Regex = '\\\\[A-Za-z0-9?.$_-]' }
    )
    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if ([System.IO.Path]::GetExtension($path).ToLowerInvariant() -in $binaryExt) { continue }

        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadLines($path)) {
            $lineNumber++
            foreach ($pattern in $patterns) {
                if ($line -match $pattern.Regex) {
                    $findings.Add([pscustomobject] @{ File = $path; Line = $lineNumber; Pattern = $pattern.Name })
                }
            }
        }
    }
    return @($findings)
}

function Normalize-HarnessCandidatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Candidate,
        [Parameter(Mandatory)] [string] $AllowedRoot,
        [switch] $LeafOnly,
        [switch] $AllowMissingLeaf
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        throw 'Path candidate must not be empty.'
    }
    if ($Candidate -match '^[a-z][a-z0-9+.-]*://') {
        throw "URL references are not allowed: $Candidate"
    }
    if ($Candidate -match '^[~/]') {
        throw "Home-rooted or slash-rooted paths are not allowed: $Candidate"
    }
    if ([System.IO.Path]::IsPathFullyQualified($Candidate) -or $Candidate.StartsWith('\\')) {
        throw "Absolute or UNC paths are not allowed: $Candidate"
    }
    if (Test-HarnessMachinePrivatePathText -Text $Candidate) {
        throw "Machine-private path reference is not allowed: $Candidate"
    }

    $candidateParts = $Candidate -replace '\\', '/'
    foreach ($part in ($candidateParts -split '/')) {
        if ($part -eq '..') {
            throw "Path escapes are not allowed: $Candidate"
        }
        if ($part -eq '.' -or [string]::IsNullOrWhiteSpace($part)) {
            throw "Ambiguous path segments are not allowed: $Candidate"
        }
    }
    if ($LeafOnly -and ($candidateParts -match '/')) {
        throw "Only a profile or component id is allowed here, not a path: $Candidate"
    }

    $root = (Resolve-Path -LiteralPath $AllowedRoot).Path
    $combined = Join-Path $root $Candidate
    $resolved = if (Test-Path -LiteralPath $combined) {
        (Resolve-Path -LiteralPath $combined).Path
    }
    elseif ($AllowMissingLeaf) {
        $missing = [System.Collections.Generic.List[string]]::new()
        $cursor = $combined
        while (-not (Test-Path -LiteralPath $cursor)) {
            $leaf = Split-Path -Leaf $cursor
            if ([string]::IsNullOrWhiteSpace($leaf)) {
                throw "Unable to resolve a safe existing parent for path: $Candidate"
            }
            $missing.Insert(0, $leaf)
            $next = Split-Path -Parent $cursor
            if ([string]::IsNullOrWhiteSpace($next) -or $next -eq $cursor) {
                throw "Unable to resolve a safe existing parent for path: $Candidate"
            }
            $cursor = $next
        }
        $resolvedCursor = (Resolve-Path -LiteralPath $cursor).Path
        foreach ($part in $missing) {
            $resolvedCursor = Join-Path $resolvedCursor $part
        }
        $resolvedCursor
    }
    else {
        $combined
    }

    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if (-not ($resolved.Equals($root, $comparison) -or $resolved.StartsWith($root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, $comparison))) {
        throw "Resolved path is outside the allowed root. Candidate: $Candidate Root: $root"
    }

    if ($LeafOnly) {
        return [System.IO.Path]::GetFileNameWithoutExtension($resolved)
    }
    return $resolved
}

function Resolve-HarnessTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [string[]] $AllowedTargets = @(
            'AGENTS.md',
            'CLAUDE.md',
            '.claude/settings.json',
            '.claude/commands/',
            '.claude/agents/',
            '.codex/prompts/',
            '.agent-harness/generated/'
        )
    )

    $resolved = Normalize-HarnessCandidatePath -Candidate $Target -AllowedRoot $ProjectRoot -AllowMissingLeaf
    $root = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $relative = [System.IO.Path]::GetRelativePath($root, $resolved) -replace '\\', '/'
    $allowed = $false
    foreach ($entry in $AllowedTargets) {
        $allow = $entry -replace '\\', '/'
        if ($allow.EndsWith('/')) {
            if ($relative.StartsWith($allow, [System.StringComparison]::OrdinalIgnoreCase)) {
                $allowed = $true
                break
            }
        }
        elseif ($relative.Equals($allow, [System.StringComparison]::OrdinalIgnoreCase)) {
            $allowed = $true
            break
        }
    }
    if (-not $allowed) {
        throw "Target path is outside the first-version harness allowlist: $Target"
    }

    return [pscustomobject] @{ RelativePath = $relative; FullPath = $resolved }
}

function Get-HarnessFileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-HarnessRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Path
    )

    return ([System.IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/')
}

function Get-HarnessComponentContentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Component,
        [Parameter(Mandatory)] [string] $FileName
    )

    $path = Join-Path $Component.Directory $FileName
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return $path
    }
    return $null
}

function Get-HarnessOutputContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Kind)

    switch ($Kind) {
        'Rule' {
            return [pscustomobject] @{
                Kind = 'Rule'; Mode = 'ManagedBlock'; AllowedTargets = @('AGENTS.md', 'CLAUDE.md')
                RequiredFiles = @('content.md'); OutputKeys = @('Target', 'Mode', 'BlockId')
            }
        }
        'Prompt' {
            return [pscustomobject] @{
                Kind = 'Prompt'; Mode = 'GeneratedOnly'; AllowedTargets = @('.agent-harness/generated/')
                RequiredFiles = @('content.md'); OutputKeys = @('Target', 'Mode')
            }
        }
        'Command' {
            return [pscustomobject] @{
                Kind = 'Command'; Mode = 'DirectoryFiles'; AllowedTargets = @('.claude/commands/')
                RequiredFiles = @(); OutputKeys = @('Target', 'Mode', 'Source')
            }
        }
        'ClaudeAgent' {
            return [pscustomobject] @{
                Kind = 'ClaudeAgent'; Mode = 'DirectoryFiles'; AllowedTargets = @('.claude/agents/')
                RequiredFiles = @(); OutputKeys = @('Target', 'Mode', 'Source')
            }
        }
        'CodexPrompt' {
            return [pscustomobject] @{
                Kind = 'CodexPrompt'; Mode = 'DirectoryFiles'; AllowedTargets = @('.codex/prompts/')
                RequiredFiles = @(); OutputKeys = @('Target', 'Mode', 'Source')
            }
        }
        'CodexAgent' {
            return [pscustomobject] @{
                Kind = 'CodexAgent'; Mode = 'DirectoryFiles'; AllowedTargets = @('.codex/agents/')
                RequiredFiles = @(); OutputKeys = @('Target', 'Mode', 'Source')
            }
        }
        'ClaudeSettings' {
            return [pscustomobject] @{
                Kind = 'ClaudeSettings'; Mode = 'StructuredMerge'; AllowedTargets = @('.claude/settings.json')
                RequiredFiles = @('settings.json'); OutputKeys = @('Target', 'Mode', 'MergeStrategy')
            }
        }
        default {
            throw "Unsupported harness component Kind '$Kind'."
        }
    }
}

function Test-HarnessComponentOutputContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Component,
        [Parameter(Mandatory)] [string] $ProjectRoot
    )

    $kind = [string] $Component.Kind
    $contract = Get-HarnessOutputContract -Kind $kind
    $data = $Component.Data
    if (-not $data.ContainsKey('Outputs')) {
        throw "Component '$($Component.Id)' is missing Outputs."
    }
    $outputs = @($data.Outputs)
    if ($outputs.Count -eq 0) {
        throw "Component '$($Component.Id)' must declare at least one output."
    }

    foreach ($fileName in @($contract.RequiredFiles)) {
        $requiredPath = Join-Path $Component.Directory $fileName
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Component '$($Component.Id)' is missing required $fileName."
        }
    }

    foreach ($output in $outputs) {
        if (-not ($output -is [System.Collections.IDictionary])) {
            throw "Component '$($Component.Id)' has an output that is not a hashtable."
        }
        foreach ($key in @($output.Keys)) {
            if ($key -notin $contract.OutputKeys) {
                throw "Component '$($Component.Id)' Kind '$kind' has unsupported output key '$key'."
            }
        }
        if (-not $output.ContainsKey('Target') -or [string]::IsNullOrWhiteSpace([string] $output.Target)) {
            throw "Component '$($Component.Id)' has an output without Target."
        }
        if (-not $output.ContainsKey('Mode') -or [string] $output.Mode -ne $contract.Mode) {
            throw "Component '$($Component.Id)' Kind '$kind' requires Mode '$($contract.Mode)'."
        }
        $targetInfo = Resolve-HarnessTargetPath -Target ([string] $output.Target) -ProjectRoot $ProjectRoot -AllowedTargets $contract.AllowedTargets
        if ($contract.Mode -eq 'DirectoryFiles' -and [System.IO.Path]::GetFileName($targetInfo.RelativePath) -in @('', '.', '..')) {
            throw "Component '$($Component.Id)' DirectoryFiles target must be a file: $($output.Target)"
        }

        if ($kind -in @('Command', 'ClaudeAgent', 'CodexPrompt', 'CodexAgent')) {
            $source = if ($output.ContainsKey('Source') -and -not [string]::IsNullOrWhiteSpace([string] $output.Source)) { [string] $output.Source } else { 'content.md' }
            if ($source -match '[\\/]' -or $source -in @('.', '..') -or [System.IO.Path]::IsPathFullyQualified($source)) {
                throw "Component '$($Component.Id)' DirectoryFiles Source must be a single relative file name: $source"
            }
            $sourcePath = Join-Path $Component.Directory $source
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Component '$($Component.Id)' is missing DirectoryFiles source '$source'."
            }
        }
        if ($kind -eq 'ClaudeSettings') {
            if ($output.ContainsKey('MergeStrategy') -and [string] $output.MergeStrategy -ne 'JsonObject') {
                throw "Component '$($Component.Id)' StructuredMerge requires MergeStrategy 'JsonObject'."
            }
            $settingsPath = Join-Path $Component.Directory 'settings.json'
            try {
                $settings = ConvertTo-HarnessPlainObject -Value (Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json)
            }
            catch {
                throw "Component '$($Component.Id)' settings.json is not valid JSON: $($_.Exception.Message)"
            }
        }
    }
    return $true
}

function ConvertTo-HarnessPlainObject {
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered] @{}
        foreach ($key in $Value.Keys) {
            $result[[string] $key] = ConvertTo-HarnessPlainObject -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered] @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-HarnessPlainObject -Value $property.Value
        }
        return $result
    }
    if ($Value -is [array]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((ConvertTo-HarnessPlainObject -Value $item))
        }
        return ,$items.ToArray()
    }
    return $Value
}

function Merge-HarnessJsonObject {
    [CmdletBinding()]
    param(
        [AllowNull()] $Base,
        [AllowNull()] $Overlay
    )

    if ($null -eq $Base) { return $Overlay }
    if ($null -eq $Overlay) { return $Base }

    if ($Base -is [System.Collections.IDictionary] -and $Overlay -is [System.Collections.IDictionary]) {
        $merged = [ordered] @{}
        foreach ($key in $Base.Keys) {
            $merged[[string] $key] = $Base[$key]
        }
        foreach ($key in $Overlay.Keys) {
            if ($merged.Contains($key)) {
                $merged[[string] $key] = Merge-HarnessJsonObject -Base $merged[$key] -Overlay $Overlay[$key]
            }
            else {
                $merged[[string] $key] = $Overlay[$key]
            }
        }
        return $merged
    }

    if (($Base -is [array]) -or ($Overlay -is [array])) {
        $items = @(Select-HarnessStableUnique -Values (@($Base) + @($Overlay)))
        return ,$items
    }

    return $Overlay
}

function Write-HarnessJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Path
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $json = $InputObject | ConvertTo-Json -Depth 50
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Write-HarnessTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [AllowNull()] [string] $Content
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Set-Content -LiteralPath $Path -Value ($Content ?? '') -Encoding UTF8
}

function Resolve-HarnessGeneratedDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $project = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $generated = Normalize-HarnessCandidatePath -Candidate '.agent-harness/generated' -AllowedRoot $project -AllowMissingLeaf
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if (-not $generated.StartsWith($project.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw "Generated directory must resolve inside ProjectRoot: $generated"
    }
    return $generated
}

function Assert-HarnessGeneratedOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $GeneratedRoot
    )

    $root = (Resolve-Path -LiteralPath $GeneratedRoot).Path
    $resolved = if (Test-Path -LiteralPath $Path) {
        (Resolve-Path -LiteralPath $Path).Path
    }
    else {
        Normalize-HarnessCandidatePath -Candidate (Get-HarnessRelativePath -Root $root -Path $Path) -AllowedRoot $root -AllowMissingLeaf
    }
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if (-not ($resolved.Equals($root, $comparison) -or $resolved.StartsWith($root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, $comparison))) {
        throw "Build output path is outside generated directory: $Path"
    }
}

function Invoke-HarnessSecretScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    if (-not (Test-Path -LiteralPath $scan -PathType Leaf)) {
        throw "Missing secret scan script: $scan"
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scan -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        throw "scripts/scan-secrets.ps1 failed with exit code $LASTEXITCODE."
    }
}

function Assert-NoHarnessMachinePrivatePaths {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Paths)

    $findings = @(Find-HarnessMachinePrivatePaths -Paths $Paths)
    if ($findings.Count -eq 0) { return }

    $details = $findings | ForEach-Object { "$($_.File):$($_.Line) $($_.Pattern)" }
    throw "Machine-private path scan failed: $($details -join '; ')"
}

function Get-HarnessText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Get-HarnessManagedBlockText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BlockId,
        [AllowNull()] [string] $Content
    )

    $body = ($Content ?? '').TrimEnd()
    return "<!-- BEGIN AGENT-HARNESS: $BlockId -->`n$body`n<!-- END AGENT-HARNESS: $BlockId -->"
}

function Get-HarnessJsonDenyList {
    [CmdletBinding()]
    param([AllowNull()] $Settings)

    if ($null -eq $Settings -or -not ($Settings -is [System.Collections.IDictionary])) { return @() }
    if (-not $Settings.Contains('permissions')) { return @() }
    $permissions = $Settings['permissions']
    if ($null -eq $permissions -or -not ($permissions -is [System.Collections.IDictionary])) { return @() }
    if (-not $permissions.Contains('deny')) { return @() }
    return @($permissions['deny'] | ForEach-Object { [string] $_ })
}

function Assert-HarnessDenyNotRemoved {
    [CmdletBinding()]
    param(
        [AllowNull()] $Before,
        [AllowNull()] $After,
        [Parameter(Mandatory)] [string] $Target
    )

    $afterSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in @(Get-HarnessJsonDenyList -Settings $After)) {
        [void] $afterSet.Add($entry)
    }
    foreach ($entry in @(Get-HarnessJsonDenyList -Settings $Before)) {
        if (-not $afterSet.Contains($entry)) {
            throw "StructuredMerge would remove permissions.deny entry '$entry' from $Target."
        }
    }
}

function ConvertTo-HarnessJsonText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $InputObject)

    return (($InputObject | ConvertTo-Json -Depth 50) + "`n")
}

function New-HarnessManagedBlockChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Targets,
        [Parameter(Mandatory)] [object[]] $Components,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $FullPath
    )

    if ($Target -notin @('AGENTS.md', 'CLAUDE.md')) {
        throw "ManagedBlock apply is only supported for AGENTS.md and CLAUDE.md in the first version: $Target"
    }

    $existing = Get-HarnessText -Path $FullPath
    $exists = $null -ne $existing
    $content = if ($exists) { $existing } else { '' }
    $blocks = [System.Collections.Generic.List[string]]::new()
    $changedExistingBlock = $false
    $missingBlocks = [System.Collections.Generic.List[string]]::new()

    foreach ($planTarget in $Targets) {
        $component = $Components | Where-Object { $_.Id -eq $planTarget.ComponentId } | Select-Object -First 1
        if (-not $component) {
            throw "Unable to find component '$($planTarget.ComponentId)' for $Target."
        }
        $contentPath = Get-HarnessComponentContentPath -Component $component -FileName 'content.md'
        $componentContent = if ($contentPath) { Get-Content -Raw -LiteralPath $contentPath } else { '' }
        $blockId = if ($planTarget.Output.BlockId) { [string] $planTarget.Output.BlockId } else { [string] $planTarget.ComponentId }
        $blockText = Get-HarnessManagedBlockText -BlockId $blockId -Content $componentContent

        if (-not $exists) {
            $blocks.Add($blockText)
            continue
        }

        $pattern = '(?s)<!--\s*BEGIN AGENT-HARNESS:\s*' + [regex]::Escape($blockId) + '\s*-->.*?<!--\s*END AGENT-HARNESS:\s*' + [regex]::Escape($blockId) + '\s*-->'
        if ([regex]::IsMatch($content, $pattern)) {
            $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $blockText }, 1)
            $changedExistingBlock = $true
        }
        else {
            $missingBlocks.Add($blockId)
        }
    }

    if (-not $exists) {
        $content = (($blocks.ToArray() -join "`n`n") + "`n")
    }
    elseif (-not $changedExistingBlock) {
        return [pscustomobject] @{
            Target = $Target; FullPath = $FullPath; Mode = 'ManagedBlock'; Action = 'skip'
            Content = $null; Reason = 'existing file has no matching managed block marker'
        }
    }

    if ($exists -and $content -eq $existing) {
        $action = 'noop'
    }
    else {
        $action = if ($exists) { 'update' } else { 'add' }
    }
    $reason = if ($missingBlocks.Count -gt 0) { "missing block(s) skipped: $($missingBlocks -join ', ')" } else { $null }
    return [pscustomobject] @{
        Target = $Target; FullPath = $FullPath; Mode = 'ManagedBlock'; Action = $action
        Content = $content; Reason = $reason
    }
}

function New-HarnessStructuredMergeChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Targets,
        [Parameter(Mandatory)] [object[]] $Components,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $FullPath
    )

    if ($Target -notin @('.claude/settings.json')) {
        throw "StructuredMerge apply target is not allowlisted: $Target"
    }

    $exists = Test-Path -LiteralPath $FullPath -PathType Leaf
    $existingText = if ($exists) { Get-Content -Raw -LiteralPath $FullPath } else { $null }
    $existingObject = if ($exists) {
        ConvertTo-HarnessPlainObject -Value ($existingText | ConvertFrom-Json)
    }
    else {
        [ordered] @{}
    }
    $merged = $existingObject

    foreach ($planTarget in $Targets) {
        $component = $Components | Where-Object { $_.Id -eq $planTarget.ComponentId } | Select-Object -First 1
        if (-not $component) {
            throw "Unable to find component '$($planTarget.ComponentId)' for $Target."
        }
        $settingsPath = Get-HarnessComponentContentPath -Component $component -FileName 'settings.json'
        if (-not $settingsPath) {
            throw "StructuredMerge component '$($component.Id)' is missing settings.json."
        }
        $overlay = ConvertTo-HarnessPlainObject -Value (Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json)
        $merged = Merge-HarnessJsonObject -Base $merged -Overlay $overlay
    }

    Assert-HarnessDenyNotRemoved -Before $existingObject -After $merged -Target $Target
    $newText = ConvertTo-HarnessJsonText -InputObject $merged
    $action = if (-not $exists) { 'add' } elseif ($newText -ne $existingText) { 'update' } else { 'noop' }

    return [pscustomobject] @{
        Target = $Target; FullPath = $FullPath; Mode = 'StructuredMerge'; Action = $action
        Content = $newText; Reason = $null
    }
}

function New-HarnessDirectoryFileChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [object[]] $Components
    )

    $component = $Components | Where-Object { $_.Id -eq $Target.ComponentId } | Select-Object -First 1
    if (-not $component) {
        throw "Unable to find component '$($Target.ComponentId)' for $($Target.Target)."
    }
    $sourceName = if (($Target.Output.PSObject.Properties.Name -contains 'Source') -and $Target.Output.Source) {
        [string] $Target.Output.Source
    }
    else {
        'content.md'
    }
    $contentPath = Get-HarnessComponentContentPath -Component $component -FileName $sourceName
    if (-not $contentPath) {
        throw "DirectoryFiles component '$($component.Id)' is missing $sourceName."
    }

    $exists = Test-Path -LiteralPath $Target.FullPath -PathType Leaf
    $content = Get-Content -Raw -LiteralPath $contentPath
    $existing = if ($exists) { Get-HarnessText -Path $Target.FullPath } else { $null }
    $action = if (-not $exists) { 'add' } elseif ($content -ne $existing) { 'update' } else { 'noop' }
    return [pscustomobject] @{
        Target = $Target.Target; FullPath = $Target.FullPath; Mode = 'DirectoryFiles'; Action = $action
        Content = $content; Reason = $null
    }
}

function New-HarnessApplyChangePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan)

    $changes = [System.Collections.Generic.List[object]]::new()

    foreach ($group in @($Plan.Targets | Where-Object { $_.Mode -eq 'ManagedBlock' } | Group-Object Target)) {
        $first = @($group.Group)[0]
        $changes.Add((New-HarnessManagedBlockChange -Targets @($group.Group) -Components $Plan.Components -Target $group.Name -FullPath $first.FullPath))
    }

    foreach ($group in @($Plan.Targets | Where-Object { $_.Mode -eq 'StructuredMerge' } | Group-Object Target)) {
        $first = @($group.Group)[0]
        $changes.Add((New-HarnessStructuredMergeChange -Targets @($group.Group) -Components $Plan.Components -Target $group.Name -FullPath $first.FullPath))
    }

    foreach ($target in @($Plan.Targets | Where-Object { $_.Mode -eq 'DirectoryFiles' })) {
        $changes.Add((New-HarnessDirectoryFileChange -Target $target -Components $Plan.Components))
    }

    foreach ($target in @($Plan.Targets | Where-Object { $_.Mode -eq 'GeneratedOnly' })) {
        $changes.Add([pscustomobject] @{
                Target = $target.Target; FullPath = $target.FullPath; Mode = 'GeneratedOnly'; Action = 'skip'
                Content = $null; Reason = 'generated-only target is produced by build-harness-profile.ps1'
            })
    }

    return @($changes)
}

function Assert-NoHarnessHomeTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Paths)

    $homeRootPath = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($homeRootPath) -or -not (Test-Path -LiteralPath $homeRootPath)) { return }
    $resolvedHome = (Resolve-Path -LiteralPath $homeRootPath).Path
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $resolved = if (Test-Path -LiteralPath $path) {
            (Resolve-Path -LiteralPath $path).Path
        }
        else {
            $path
        }
        if ($resolved.Equals($resolvedHome, $comparison) -or $resolved.StartsWith($resolvedHome.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw "Refusing to write inside the home directory: $resolved"
        }
    }
}

function Resolve-HarnessBackupRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BackupRoot,
        [Parameter(Mandatory)] [string] $ProjectRoot
    )

    $project = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $candidate = if ([System.IO.Path]::IsPathFullyQualified($BackupRoot)) {
        $BackupRoot
    }
    elseif (($BackupRoot -replace '\\', '/').StartsWith('.agent-harness/backups', [System.StringComparison]::OrdinalIgnoreCase)) {
        Join-Path $project $BackupRoot
    }
    else {
        Join-Path (Get-Location).Path $BackupRoot
    }
    $backup = Normalize-HarnessCandidatePath -Candidate (Get-HarnessRelativePath -Root $project -Path $candidate) -AllowedRoot $project -AllowMissingLeaf
    $relative = Get-HarnessRelativePath -Root $project -Path $backup
    if (-not $relative.StartsWith('.agent-harness/backups/', [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $relative.Equals('.agent-harness/backups', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'BackupRoot must resolve under .agent-harness/backups inside the project root.'
    }
    return $backup
}

function Assert-NoHarnessMachinePrivateText {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Changes)

    foreach ($change in $Changes) {
        if ($change.Action -in @('add', 'update') -and (Test-HarnessMachinePrivatePathText -Text $change.Content)) {
            throw "Machine-private path scan failed for planned target: $($change.Target)"
        }
    }
}

function Get-HarnessProfileComponentIds {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Profile)

    $ids = [System.Collections.Generic.List[string]]::new()
    if (-not $Profile.ContainsKey('Components') -or $null -eq $Profile.Components) {
        return @()
    }
    foreach ($bucket in @('Rules', 'Prompts', 'Commands', 'Agents', 'ClaudeSettings', 'CodexAgents', 'McpTemplates')) {
        foreach ($id in @($Profile.Components[$bucket])) {
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $ids.Add([string] $id)
            }
        }
    }
    return Select-HarnessStableUnique -Values $ids.ToArray()
}

function New-HarnessProfilePlan {
    [CmdletBinding()]
    param(
        [string] $RepoRoot,
        [string] $ProjectRoot = (Get-Location).Path,
        [ValidateSet('Status', 'Build', 'Apply')]
        [string] $Mode = 'Status'
    )

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $project = Resolve-HarnessProjectRoot -ProjectRoot $ProjectRoot
    $projectProfile = Get-HarnessProjectProfile -ProjectRoot $project
    $resolvedProfiles = @(Resolve-HarnessProfileExtends -Profile $projectProfile.Data -RepoRoot $repo)
    $mergedProfile = Merge-HarnessProfiles -ResolvedProfiles $resolvedProfiles -ProjectProfile $projectProfile.Data

    $components = @(Get-HarnessComponents -RepoRoot $repo)
    [void] (Test-HarnessUniqueComponentIds -Components $components)
    $componentIndex = @{}
    foreach ($component in $components) {
        $componentIndex[$component.Id] = $component
    }

    $componentIds = @(Get-HarnessProfileComponentIds -Profile $mergedProfile)
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $componentIds) {
        $safeId = Normalize-HarnessCandidatePath -Candidate $id -AllowedRoot (Join-Path $repo 'harness-source/components') -LeafOnly
        if (-not $componentIndex.ContainsKey($safeId)) {
            throw "Profile references unknown component '$id'."
        }
        $selected.Add($componentIndex[$safeId])
    }

    foreach ($component in $selected) {
        [void] (Test-HarnessComponentOutputContract -Component $component -ProjectRoot $project)
    }

    $targetPlatforms = @($mergedProfile.TargetPlatforms)
    [void] (Test-HarnessTargetPlatforms -TargetPlatforms $targetPlatforms -SelectedComponents $selected.ToArray())
    [void] (Test-HarnessRequiresAndConflicts -SelectedComponents $selected.ToArray() -ComponentIndex $componentIndex)

    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($component in $selected) {
        foreach ($output in @($component.Data.Outputs)) {
            if (-not $output.Target) {
                throw "Component '$($component.Id)' has an output without Target."
            }
            $contract = Get-HarnessOutputContract -Kind $component.Kind
            $target = Resolve-HarnessTargetPath -Target $output.Target -ProjectRoot $project -AllowedTargets $contract.AllowedTargets
            $targets.Add([pscustomobject] @{
                    ComponentId  = $component.Id
                    Mode         = $output.Mode
                    Target       = $target.RelativePath
                    FullPath     = $target.FullPath
                    CurrentHash  = Get-HarnessFileHash -Path $target.FullPath
                    PlannedHash  = $null
                    Action       = if (Test-Path -LiteralPath $target.FullPath) { 'inspect' } else { 'add' }
                    Output       = $output
                })
        }
    }

    $sourceFiles = [System.Collections.Generic.List[object]]::new()
    $sourceFiles.Add([pscustomobject] @{ Kind = 'ProjectProfile'; Path = $projectProfile.Path; Hash = Get-HarnessFileHash -Path $projectProfile.Path })
    foreach ($profile in $resolvedProfiles) {
        $sourceFiles.Add([pscustomobject] @{ Kind = 'LibraryProfile'; Name = $profile.Name; Path = $profile.Path; Hash = Get-HarnessFileHash -Path $profile.Path })
    }
    foreach ($component in $selected) {
        $files = Get-ChildItem -LiteralPath $component.Directory -File -Recurse -Force | Sort-Object FullName
        foreach ($file in $files) {
            $sourceFiles.Add([pscustomobject] @{ Kind = 'Component'; ComponentId = $component.Id; Path = $file.FullName; Hash = Get-HarnessFileHash -Path $file.FullName })
        }
    }

    return [pscustomobject] @{
        Mode             = $Mode
        RepoRoot         = $repo
        ProjectRoot      = $project
        ProfilePath      = $projectProfile.Path
        ResolvedProfiles = @($resolvedProfiles)
        Profile          = $mergedProfile
        TargetPlatforms  = $targetPlatforms
        ComponentIds     = $componentIds
        Components       = @($selected)
        Targets          = @($targets)
        SourceFiles      = @($sourceFiles)
    }
}
