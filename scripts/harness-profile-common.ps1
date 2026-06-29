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
        'SchemaVersion', 'Name', 'TargetPlatforms', 'Extends', 'Components', 'Future'
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

    $valid = @('Claude', 'Codex', 'OpenClaw')
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

    $targetPlatforms = @($mergedProfile.TargetPlatforms)
    [void] (Test-HarnessTargetPlatforms -TargetPlatforms $targetPlatforms -SelectedComponents $selected.ToArray())
    [void] (Test-HarnessRequiresAndConflicts -SelectedComponents $selected.ToArray() -ComponentIndex $componentIndex)

    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($component in $selected) {
        foreach ($output in @($component.Data.Outputs)) {
            if (-not $output.Target) {
                throw "Component '$($component.Id)' has an output without Target."
            }
            $target = Resolve-HarnessTargetPath -Target $output.Target -ProjectRoot $project
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
