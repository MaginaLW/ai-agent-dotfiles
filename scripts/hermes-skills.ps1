#requires -Version 7.0
<#
.SYNOPSIS
    Inspects and deploys reviewed shared skills to Hermes under %LOCALAPPDATA%\hermes\skills\ai-agent-dotfiles.

.DESCRIPTION
    Status and Deploy -DryRun are read-only and never create or modify live home or state directories.
    Deploy -Apply checks Hermes home guards, detects same-tier sibling local skill collisions,
    runs the repository secret scan (unless -SkipSecretScan), backs up update/prune targets,
    swaps each skill directory atomically via sibling .deploying-<name> staging (excluding
    CREATION-LOG.md), updates deployed-skills.json atomically, and verifies post-Apply convergence.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Deploy')]
    [string] $Action = 'Status',
    [switch] $Apply,
    [switch] $DryRun,
    [string[]] $Retire = @(),
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $HomeRoot = [Environment]::GetFolderPath('UserProfile'),
    [string] $StateRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-agent-dotfiles.deploy\hermes'),
    [switch] $SkipSecretScan,
    [string] $JsonPath,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'repo-common.ps1')
. (Join-Path $PSScriptRoot 'skills-common.ps1')

$script:HermesSkillsLiveRootLabel = '%LOCALAPPDATA%/hermes/skills/ai-agent-dotfiles'
$script:HermesSkillsCategory = 'ai-agent-dotfiles'
$script:HermesSkillsSkippedSiblings = @('ai-agent-dotfiles', '.hub', '.locks', '.archive', '.curator_backups', '.git')

function Get-HermesSkillsManifest {
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $manifestPath = Join-Path $RepoRoot 'harness-source\hermes\skills.psd1'
    Assert-PlainPathNoReparse -Path $manifestPath -AllowMissing
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Hermes skills manifest not found: $manifestPath"
    }

    $data = Import-PowerShellDataFile -LiteralPath $manifestPath
    if ($data -isnot [hashtable]) {
        throw 'Hermes skills manifest must be a hashtable.'
    }
    $keys = @($data.Keys | Sort-Object -CaseSensitive) -join ','
    if ($keys -cne 'Category,SchemaVersion,Skills') {
        throw 'Hermes skills manifest must declare exact keys Category, SchemaVersion, Skills.'
    }
    if (($data['SchemaVersion'] -isnot [int] -and $data['SchemaVersion'] -isnot [long]) -or $data['SchemaVersion'] -ne 1) {
        throw 'Hermes skills manifest must declare SchemaVersion = 1.'
    }
    if ($data['Category'] -isnot [string] -or $data['Category'] -cne $script:HermesSkillsCategory) {
        throw "Hermes skills manifest must declare Category = '$($script:HermesSkillsCategory)'."
    }
    if ($data['Skills'] -isnot [array] -or @($data['Skills']).Count -lt 1) {
        throw 'Hermes skills manifest must declare a non-empty Skills array.'
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $skills = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($data['Skills'])) {
        if (-not (Test-DeploySkillName $entry)) {
            throw "Invalid skill name in Hermes manifest: '$entry'"
        }
        if (-not $seen.Add($entry)) {
            throw "Duplicate skill name in Hermes manifest: '$entry'"
        }
        $sourceDir = Join-Path $RepoRoot ("skills-source\shared\$entry")
        Assert-PlainPathNoReparse -Path $sourceDir -AllowMissing
        if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
            throw "Selected Hermes skill source directory is missing: $entry"
        }
        Assert-SkillTreeNoReparsePoint -Root $sourceDir
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDir 'SKILL.md') -PathType Leaf)) {
            throw "Selected Hermes skill is missing SKILL.md: $entry"
        }
        $skills.Add($entry)
    }

    return [pscustomobject]@{
        SchemaVersion = 1
        Category      = $script:HermesSkillsCategory
        Skills        = $skills.ToArray()
    }
}

function Resolve-HermesSkillsRetireList {
    param(
        [AllowEmptyCollection()] [string[]] $Retire = @(),
        [Parameter(Mandatory)] [string[]] $SelectedSkills
    )

    $retireList = [System.Collections.Generic.List[string]]::new()
    $retireSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rawRetire in @($Retire)) {
        foreach ($token in ([string]$rawRetire -split ',')) {
            $trimmed = $token.Trim()
            if ([string]::IsNullOrEmpty($trimmed)) {
                throw "invalid skill name for Retire: '$rawRetire'"
            }
            if (-not (Test-DeploySkillName $trimmed)) {
                throw "invalid skill name for Retire: '$trimmed'"
            }
            if ($retireSeen.Add($trimmed)) {
                $retireList.Add($trimmed)
            }
        }
    }
    foreach ($name in $retireList) {
        if ($name -in $SelectedSkills) {
            throw "retire-selected-skill: -Retire names '$name', which is still selected in the Hermes manifest."
        }
    }
    return $retireList.ToArray()
}

function Get-HermesSkillsStateRecord {
    param([Parameter(Mandatory)] [string] $StateRoot)

    $statePath = Join-Path $StateRoot 'deployed-skills.json'
    Assert-PlainPathNoReparse -Path $StateRoot -AllowMissing
    Assert-PlainPathNoReparse -Path $statePath -AllowMissing

    if (Test-Path -LiteralPath $StateRoot -PathType Leaf) {
        throw "state-root-not-directory: choose a directory for -StateRoot."
    }
    if (Test-Path -LiteralPath $statePath -PathType Container) {
        throw "state-path-is-directory: expected a deployment state file."
    }
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [pscustomobject]@{
            StatePath = $statePath
            Exists    = $false
            Skills    = @()
        }
    }

    try {
        $raw = Get-Content -Raw -LiteralPath $statePath -ErrorAction Stop
    }
    catch {
        throw "deploy-state-read-error: cannot read Hermes deployment state file."
    }
    try {
        $state = ConvertFrom-Json -InputObject $raw -AsHashtable -NoEnumerate -ErrorAction Stop
    }
    catch {
        throw "deploy-state-invalid-json: invalid JSON in Hermes deployment state file."
    }

    if ($state -isnot [System.Collections.IDictionary]) {
        throw 'deploy-state-invalid-state: state file must be a JSON object.'
    }
    $keys = @($state.Keys | Sort-Object -CaseSensitive) -join ','
    if ($keys -cne 'Category,SchemaVersion,Skills') {
        throw 'deploy-state-invalid-state: state file must contain exact keys Category, SchemaVersion, Skills.'
    }
    if (($state['SchemaVersion'] -isnot [int] -and $state['SchemaVersion'] -isnot [long]) -or $state['SchemaVersion'] -ne 1) {
        throw 'deploy-state-invalid-state: state file SchemaVersion must be 1.'
    }
    if ($state['Category'] -isnot [string] -or $state['Category'] -cne $script:HermesSkillsCategory) {
        throw "deploy-state-invalid-state: state file Category must be '$($script:HermesSkillsCategory)'."
    }
    if ($state['Skills'] -isnot [array]) {
        throw 'deploy-state-invalid-state: state file Skills must be an array.'
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $skills = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($state['Skills'])) {
        if (-not (Test-DeploySkillName $name)) {
            throw "deploy-state-invalid-state: invalid skill name '$name' in state file."
        }
        if (-not $seen.Add($name)) {
            throw "deploy-state-invalid-state: duplicate skill name '$name' in state file."
        }
        $skills.Add($name)
    }

    return [pscustomobject]@{
        StatePath = $statePath
        Exists    = $true
        Skills    = $skills.ToArray()
    }
}

function Get-HermesSkillsTreeState {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $ExcludeRuntime
    )

    Assert-PlainPathNoReparse -Path $Path -AllowMissing
    $files = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Hash = $null; Files = $files }
    }

    $rows = @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "reparse-point-refused: $($_.FullName)"
        }
        if ($_.PSIsContainer) { return }
        if ($ExcludeRuntime -and ($_.Name -ieq 'CREATION-LOG.md')) { return }
        $relativePath = [IO.Path]::GetRelativePath($Path, $_.FullName).Replace('\', '/')
        $fileHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        $files.Add($relativePath, $fileHash)
        $relativePath + ':' + $fileHash
    })
    return [pscustomobject]@{ Hash = ($rows -join "`n"); Files = $files }
}

function Get-HermesSkillsSkillMdName {
    param(
        [Parameter(Mandatory)] [string] $SkillMdPath,
        [Parameter(Mandatory)] [string] $FallbackName
    )

    $raw = [IO.File]::ReadAllText($SkillMdPath)
    $lines = $raw -split "\r?\n"
    if ($lines.Count -ge 3 -and $lines[0].TrimStart([char]0xFEFF).Trim() -ceq '---') {
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $trimmedLine = $line.Trim()
            if ($trimmedLine -ceq '---' -or $trimmedLine -ceq '...') { break }
            if ($line -cmatch '^name\s*:\s*(.*)$') {
                $val = $Matches[1].Trim()
                if ($val -match '^"([^"]*)"(?:\s*#.*)?$' -or $val -match "^'([^']*)'(?:\s*#.*)?$") {
                    $parsed = $Matches[1].Trim()
                    if (-not [string]::IsNullOrWhiteSpace($parsed)) { return $parsed }
                }
                else {
                    $parsed = ($val -replace '\s+#.*$', '').Trim()
                    if (-not [string]::IsNullOrWhiteSpace($parsed)) { return $parsed }
                }
            }
        }
    }
    return $FallbackName
}

function Find-HermesSkillsSiblingCollisions {
    param([Parameter(Mandatory)] [string] $SkillsParent)

    $collisions = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $SkillsParent -PathType Container)) {
        return [pscustomobject]@{ Blocked = $false; Reason = $null; Collisions = $collisions }
    }

    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($topEntry in @(Get-ChildItem -LiteralPath $SkillsParent -Force | Sort-Object FullName)) {
        if ($topEntry.Name -in $script:HermesSkillsSkippedSiblings) { continue }
        if ($topEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            return [pscustomobject]@{ Blocked = $true; Reason = 'reparse-point-refused'; Collisions = $collisions }
        }
        if ($topEntry.PSIsContainer) {
            $queue.Enqueue($topEntry.FullName)
        }
    }

    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        foreach ($entry in @(Get-ChildItem -LiteralPath $dir -Force | Sort-Object FullName)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                return [pscustomobject]@{ Blocked = $true; Reason = 'reparse-point-refused'; Collisions = $collisions }
            }
            if ($entry.PSIsContainer) {
                $queue.Enqueue($entry.FullName)
            }
            elseif ($entry.Name -ieq 'SKILL.md') {
                $fallbackName = Split-Path -Leaf $dir
                $skillName = Get-HermesSkillsSkillMdName -SkillMdPath $entry.FullName -FallbackName $fallbackName
                $relPath = [IO.Path]::GetRelativePath($SkillsParent, $entry.FullName).Replace('\', '/')
                if (-not $collisions.ContainsKey($skillName)) {
                    $collisions.Add($skillName, $relPath)
                }
            }
        }
    }

    return [pscustomobject]@{ Blocked = $false; Reason = $null; Collisions = $collisions }
}

function Test-HermesSkillsHomeGuard {
    param([Parameter(Mandatory)] [string] $HomeRoot)

    $hermesRoot = Join-Path $HomeRoot 'AppData\Local\hermes'
    $skillsParent = Join-Path $hermesRoot 'skills'
    $liveRoot = Join-Path $skillsParent $script:HermesSkillsCategory

    $hermesHomeEnv = [Environment]::GetEnvironmentVariable('HERMES_HOME')
    if (-not [string]::IsNullOrEmpty($hermesHomeEnv)) {
        $isDefault = $false
        try {
            $expectedDefault = [IO.Path]::GetFullPath($hermesRoot).TrimEnd('\', '/')
            $actualEnv = [IO.Path]::GetFullPath($hermesHomeEnv).TrimEnd('\', '/')
            $isDefault = ($actualEnv -ieq $expectedDefault)
        }
        catch {
            $isDefault = $false
        }
        if (-not $isDefault) {
            return [pscustomobject]@{
                State        = 'blocked'
                Reason       = 'hermes-home-override-unsupported'
                HermesRoot   = $hermesRoot
                SkillsParent = $skillsParent
                LiveRoot     = $liveRoot
            }
        }
    }

    $suffixEnv = [Environment]::GetEnvironmentVariable('HERMES_DATA_DIR_SUFFIX')
    if (-not [string]::IsNullOrEmpty($suffixEnv)) {
        return [pscustomobject]@{
            State        = 'blocked'
            Reason       = 'hermes-data-dir-suffix-unsupported'
            HermesRoot   = $hermesRoot
            SkillsParent = $skillsParent
            LiveRoot     = $liveRoot
        }
    }

    try {
        Assert-PlainPathNoReparse -Path $hermesRoot -AllowMissing
    }
    catch {
        return [pscustomobject]@{
            State        = 'blocked'
            Reason       = 'reparse-point-refused'
            HermesRoot   = $hermesRoot
            SkillsParent = $skillsParent
            LiveRoot     = $liveRoot
        }
    }

    if (-not (Test-Path -LiteralPath $hermesRoot)) {
        return [pscustomobject]@{
            State        = 'not-installed'
            Reason       = 'hermes-home-missing'
            HermesRoot   = $hermesRoot
            SkillsParent = $skillsParent
            LiveRoot     = $liveRoot
        }
    }

    if (-not (Get-Item -LiteralPath $hermesRoot -Force).PSIsContainer) {
        return [pscustomobject]@{
            State        = 'blocked'
            Reason       = 'hermes-home-not-directory'
            HermesRoot   = $hermesRoot
            SkillsParent = $skillsParent
            LiveRoot     = $liveRoot
        }
    }

    $activeProfilePath = Join-Path $hermesRoot 'active_profile'
    if (Test-Path -LiteralPath $activeProfilePath) {
        try {
            Assert-PlainPathNoReparse -Path $activeProfilePath
        }
        catch {
            return [pscustomobject]@{
                State        = 'blocked'
                Reason       = 'hermes-active-profile-reparse'
                HermesRoot   = $hermesRoot
                SkillsParent = $skillsParent
                LiveRoot     = $liveRoot
            }
        }
        if ((Get-Item -LiteralPath $activeProfilePath -Force).PSIsContainer) {
            return [pscustomobject]@{
                State        = 'blocked'
                Reason       = 'hermes-active-profile-invalid'
                HermesRoot   = $hermesRoot
                SkillsParent = $skillsParent
                LiveRoot     = $liveRoot
            }
        }
        $profileText = $null
        try {
            $profileText = Get-Content -Raw -LiteralPath $activeProfilePath -ErrorAction Stop
        }
        catch {
            $profileText = $null
        }
        if ($null -eq $profileText -or ($profileText.Trim() -cne 'default')) {
            return [pscustomobject]@{
                State        = 'blocked'
                Reason       = 'hermes-non-default-active-profile'
                HermesRoot   = $hermesRoot
                SkillsParent = $skillsParent
                LiveRoot     = $liveRoot
            }
        }
    }

    try {
        Assert-PlainPathNoReparse -Path $skillsParent -AllowMissing
    }
    catch {
        return [pscustomobject]@{
            State        = 'blocked'
            Reason       = 'reparse-point-refused'
            HermesRoot   = $hermesRoot
            SkillsParent = $skillsParent
            LiveRoot     = $liveRoot
        }
    }
    if ((Test-Path -LiteralPath $skillsParent) -and -not (Get-Item -LiteralPath $skillsParent -Force).PSIsContainer) {
        return [pscustomobject]@{
            State        = 'blocked'
            Reason       = 'hermes-skills-dir-not-directory'
            HermesRoot   = $hermesRoot
            SkillsParent = $skillsParent
            LiveRoot     = $liveRoot
        }
    }

    try {
        Assert-PlainPathNoReparse -Path $liveRoot -AllowMissing
    }
    catch {
        return [pscustomobject]@{
            State        = 'blocked'
            Reason       = 'reparse-point-refused'
            HermesRoot   = $hermesRoot
            SkillsParent = $skillsParent
            LiveRoot     = $liveRoot
        }
    }
    if ((Test-Path -LiteralPath $liveRoot) -and -not (Get-Item -LiteralPath $liveRoot -Force).PSIsContainer) {
        return [pscustomobject]@{
            State        = 'blocked'
            Reason       = 'hermes-category-dir-not-directory'
            HermesRoot   = $hermesRoot
            SkillsParent = $skillsParent
            LiveRoot     = $liveRoot
        }
    }

    return [pscustomobject]@{
        State        = 'checked'
        Reason       = $null
        HermesRoot   = $hermesRoot
        SkillsParent = $skillsParent
        LiveRoot     = $liveRoot
    }
}

function Get-HermesSkillsFileChanges {
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.Dictionary[string, string]] $SourceFiles,
        [Parameter(Mandatory)] [System.Collections.Generic.Dictionary[string, string]] $TargetFiles
    )

    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @($SourceFiles.Keys | Sort-Object -CaseSensitive)) {
        if (-not $TargetFiles.ContainsKey($path)) {
            $changes.Add([ordered]@{ Action = 'add'; Path = $path })
        }
        elseif ($SourceFiles[$path] -cne $TargetFiles[$path]) {
            $changes.Add([ordered]@{ Action = 'change'; Path = $path })
        }
    }
    foreach ($path in @($TargetFiles.Keys | Sort-Object -CaseSensitive)) {
        if (-not $SourceFiles.ContainsKey($path)) {
            $changes.Add([ordered]@{ Action = 'remove'; Path = $path })
        }
    }
    return $changes.ToArray()
}

function Get-HermesSkillsPlan {
    param(
        [Parameter(Mandatory)] [string] $ActionName,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $StateRoot,
        [AllowEmptyCollection()] [string[]] $Retire = @()
    )

    $manifest = Get-HermesSkillsManifest -RepoRoot $RepoRoot
    $selected = @($manifest.Skills)
    $resolvedRetire = @(Resolve-HermesSkillsRetireList -Retire $Retire -SelectedSkills $selected)
    $stateRecord = Get-HermesSkillsStateRecord -StateRoot $StateRoot
    $recordedSkills = @($stateRecord.Skills)

    $summary = [ordered]@{
        install   = 0
        update    = 0
        unchanged = 0
        prune     = 0
        unknown   = 0
        blocked   = 0
    }

    $guard = Test-HermesSkillsHomeGuard -HomeRoot $HomeRoot
    if ($guard.State -cne 'checked') {
        return [pscustomobject]@{
            SchemaVersion       = 1
            Action              = $ActionName
            State               = $guard.State
            Reason              = $guard.Reason
            Category            = $script:HermesSkillsCategory
            LiveRoot            = $script:HermesSkillsLiveRootLabel
            LiveRootPath        = $guard.LiveRoot
            StatePath           = $stateRecord.StatePath
            RecordedSkills      = $recordedSkills
            Summary             = $summary
            Items               = @()
            UnrecordedUpdates   = @()
            InterruptedRemnants = @()
        }
    }

    $collisionProbe = Find-HermesSkillsSiblingCollisions -SkillsParent $guard.SkillsParent
    if ($collisionProbe.Blocked) {
        return [pscustomobject]@{
            SchemaVersion       = 1
            Action              = $ActionName
            State               = 'blocked'
            Reason              = $collisionProbe.Reason
            Category            = $script:HermesSkillsCategory
            LiveRoot            = $script:HermesSkillsLiveRootLabel
            LiveRootPath        = $guard.LiveRoot
            StatePath           = $stateRecord.StatePath
            RecordedSkills      = $recordedSkills
            Summary             = $summary
            Items               = @()
            UnrecordedUpdates   = @()
            InterruptedRemnants = @()
        }
    }

    $liveRoot = $guard.LiveRoot
    $liveDirNames = if (Test-Path -LiteralPath $liveRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $liveRoot -Directory -Force | ForEach-Object Name)
    }
    else {
        @()
    }
    $interruptedRemnants = @($liveDirNames | Where-Object { $_.StartsWith('.deploying-', [System.StringComparison]::Ordinal) } | Sort-Object)

    $items = [System.Collections.Generic.List[object]]::new()
    $unrecordedUpdates = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $selected) {
        $sourceDir = Join-Path $RepoRoot ("skills-source\shared\$name")
        $targetDir = Join-Path $liveRoot $name
        $recorded = [bool]($name -in $recordedSkills)

        if ($collisionProbe.Collisions.ContainsKey($name)) {
            $relCollision = $collisionProbe.Collisions[$name]
            $items.Add([pscustomobject]@{
                Name            = $name
                Action          = 'blocked'
                Reason          = "hermes-local-skill-collision:$relCollision"
                RecordedInState = $recorded
                FileChanges     = @()
                Source          = $sourceDir
                Target          = $targetDir
            })
            continue
        }

        if (Test-Path -LiteralPath $targetDir) {
            $targetItem = Get-Item -LiteralPath $targetDir -Force
            if ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $items.Add([pscustomobject]@{
                    Name            = $name
                    Action          = 'blocked'
                    Reason          = 'reparse-point-refused'
                    RecordedInState = $recorded
                    FileChanges     = @()
                    Source          = $sourceDir
                    Target          = $targetDir
                })
                continue
            }
            if (-not $targetItem.PSIsContainer) {
                $items.Add([pscustomobject]@{
                    Name            = $name
                    Action          = 'blocked'
                    Reason          = 'live-skill-target-not-directory'
                    RecordedInState = $recorded
                    FileChanges     = @()
                    Source          = $sourceDir
                    Target          = $targetDir
                })
                continue
            }
        }

        $sourceState = Get-HermesSkillsTreeState -Path $sourceDir -ExcludeRuntime
        $targetState = $null
        try {
            $targetState = Get-HermesSkillsTreeState -Path $targetDir
        }
        catch {
            $items.Add([pscustomobject]@{
                Name            = $name
                Action          = 'blocked'
                Reason          = 'reparse-point-refused'
                RecordedInState = $recorded
                FileChanges     = @()
                Source          = $sourceDir
                Target          = $targetDir
            })
            continue
        }

        $itemAction = if ($name -notin $liveDirNames) { 'install' }
            elseif ($sourceState.Hash -ceq $targetState.Hash) { 'unchanged' }
            else { 'update' }

        $fileChanges = if ($itemAction -in @('install', 'update')) {
            @(Get-HermesSkillsFileChanges -SourceFiles $sourceState.Files -TargetFiles $targetState.Files)
        }
        else {
            @()
        }

        if ($itemAction -ceq 'update' -and -not $recorded) {
            $unrecordedUpdates.Add($name)
        }

        $items.Add([pscustomobject]@{
            Name            = $name
            Action          = $itemAction
            Reason          = $null
            RecordedInState = $recorded
            FileChanges     = $fileChanges
            Source          = $sourceDir
            Target          = $targetDir
        })
    }

    $prunable = @($recordedSkills) + @($resolvedRetire)
    $handledUnselected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($name in $liveDirNames) {
        if ($name -in $selected -or $name.StartsWith('.deploying-', [System.StringComparison]::Ordinal)) { continue }
        $null = $handledUnselected.Add($name)
        $targetDir = Join-Path $liveRoot $name
        $recorded = [bool]($name -in $recordedSkills)

        if ($name -in $prunable) {
            $reparseBlocked = $false
            try {
                Assert-TreeNoReparse -Root $targetDir
            }
            catch {
                $reparseBlocked = $true
            }
            if ($reparseBlocked) {
                $items.Add([pscustomobject]@{
                    Name            = $name
                    Action          = 'blocked'
                    Reason          = 'reparse-point-refused'
                    RecordedInState = $recorded
                    FileChanges     = @()
                    Source          = $null
                    Target          = $targetDir
                })
            }
            else {
                $pruneReason = if ($name -in $resolvedRetire) { 'explicit -Retire' } else { 'previously managed; not selected in manifest' }
                $items.Add([pscustomobject]@{
                    Name            = $name
                    Action          = 'prune'
                    Reason          = $pruneReason
                    RecordedInState = $recorded
                    FileChanges     = @()
                    Source          = $null
                    Target          = $targetDir
                })
            }
        }
        else {
            $items.Add([pscustomobject]@{
                Name            = $name
                Action          = 'unknown'
                Reason          = 'unmanaged live directory; preserved'
                RecordedInState = $false
                FileChanges     = @()
                Source          = $null
                Target          = $targetDir
            })
        }
    }

    foreach ($retireName in $resolvedRetire) {
        if ($handledUnselected.Contains($retireName)) { continue }
        $targetDir = Join-Path $liveRoot $retireName
        if (Test-Path -LiteralPath $targetDir) {
            $itemObj = Get-Item -LiteralPath $targetDir -Force
            $reason = if ($itemObj.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'reparse-point-refused' } else { 'live-skill-target-not-directory' }
            $items.Add([pscustomobject]@{
                Name            = $retireName
                Action          = 'blocked'
                Reason          = $reason
                RecordedInState = [bool]($retireName -in $recordedSkills)
                FileChanges     = @()
                Source          = $null
                Target          = $targetDir
            })
        }
    }

    $sortedItems = @($items | Sort-Object Action, Name)
    foreach ($item in $sortedItems) {
        if ($summary.Contains($item.Action)) {
            $summary[$item.Action]++
        }
    }

    return [pscustomobject]@{
        SchemaVersion       = 1
        Action              = $ActionName
        State               = 'checked'
        Reason              = $null
        Category            = $script:HermesSkillsCategory
        LiveRoot            = $script:HermesSkillsLiveRootLabel
        LiveRootPath        = $liveRoot
        StatePath           = $stateRecord.StatePath
        RecordedSkills      = $recordedSkills
        Summary             = $summary
        Items               = $sortedItems
        UnrecordedUpdates   = @($unrecordedUpdates | Sort-Object)
        InterruptedRemnants = $interruptedRemnants
    }
}

function ConvertTo-HermesSkillsReport {
    param([Parameter(Mandatory)] [object] $Plan)

    $projectedItems = @(foreach ($item in @($Plan.Items)) {
        $changes = @(foreach ($change in @($item.FileChanges)) {
            [ordered]@{
                Action = [string] $change.Action
                Path   = [string] $change.Path
            }
        })
        [ordered]@{
            Name            = [string] $item.Name
            Action          = [string] $item.Action
            Reason          = $item.Reason
            RecordedInState = [bool] $item.RecordedInState
            FileChanges     = $changes
        }
    })

    return [ordered]@{
        SchemaVersion       = 1
        Action              = [string] $Plan.Action
        State               = [string] $Plan.State
        Reason              = $Plan.Reason
        Category            = [string] $Plan.Category
        LiveRoot            = [string] $Plan.LiveRoot
        Summary             = $Plan.Summary
        Items               = $projectedItems
        UnrecordedUpdates   = @($Plan.UnrecordedUpdates)
        InterruptedRemnants = @($Plan.InterruptedRemnants)
    }
}

function Write-HermesSkillsJsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Value
    )

    Assert-PlainPathNoReparse -Path $Path -AllowMissing
    $parent = Split-Path -Parent $Path
    if ($parent) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
}

function Write-HermesSkillsConsoleReport {
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $ModeLabel
    )

    Write-Host "Hermes live root: $($Plan.LiveRoot) (State=$($Plan.State))"
    if ($Plan.Reason) {
        Write-Host "Reason: $($Plan.Reason)"
    }
    if (@($Plan.Items).Count -gt 0) {
        $Plan.Items | Select-Object Name, Action, Reason | Format-Table Name, Action, Reason -AutoSize | Out-String | Write-Host
    }
    $s = $Plan.Summary
    Write-Host ("Plan summary: install={0}  update={1}  unchanged={2}  prune={3}  unknown={4}  blocked={5}" -f $s.install, $s.update, $s.unchanged, $s.prune, $s.unknown, $s.blocked)
    foreach ($item in @($Plan.Items | Where-Object { $_.Action -in @('install', 'update') })) {
        Write-Host "File changes for $($item.Name):"
        foreach ($change in @($item.FileChanges)) {
            Write-Host ('  {0,-7} {1}' -f $change.Action, $change.Path)
        }
    }
    if (@($Plan.UnrecordedUpdates).Count -gt 0) {
        foreach ($u in @($Plan.UnrecordedUpdates)) {
            Write-Host "Update not recorded in deploy state: $u. Existing content will be backed up and overwritten; ownership is unknown."
        }
    }
    if (@($Plan.InterruptedRemnants).Count -gt 0) {
        Write-Host 'Possible interrupted deployment remnants (inspect before applying):'
        foreach ($remnant in @($Plan.InterruptedRemnants)) {
            Write-Host "  $remnant"
        }
    }
    Write-Host "Mode: $ModeLabel"
}

function Invoke-HermesSkillsDeploy {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $StateRoot,
        [AllowEmptyCollection()] [string[]] $Retire = @(),
        [switch] $DoApply,
        [switch] $SkipSecretScan,
        [switch] $Quiet
    )

    $plan = Get-HermesSkillsPlan -ActionName 'Deploy' -RepoRoot $RepoRoot -HomeRoot $HomeRoot -StateRoot $StateRoot -Retire $Retire
    if (-not $DoApply) {
        return $plan
    }

    if ($plan.State -cne 'checked') {
        throw "Hermes skills deployment refused (State=$($plan.State)): $($plan.Reason)"
    }
    if ($plan.Summary.blocked -gt 0) {
        $blockedList = @($plan.Items | Where-Object { $_.Action -ceq 'blocked' } | ForEach-Object { "$($_.Name):$($_.Reason)" }) -join ', '
        throw "Hermes skills deployment refused; blocked item(s): $blockedList"
    }

    $pending = @($plan.Items | Where-Object { $_.Action -cin @('install', 'update', 'prune') })
    if ($pending.Count -eq 0) {
        return $plan
    }

    if (-not $SkipSecretScan) {
        if ($Quiet) {
            Invoke-SecretScanGate -RepoRoot $RepoRoot | Out-Null
        }
        else {
            Invoke-SecretScanGate -RepoRoot $RepoRoot | Out-Host
        }
    }

    $liveRoot = $plan.LiveRootPath
    $statePath = $plan.StatePath
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $backupRoot = Join-Path $StateRoot "skill-backups\$stamp"

    Assert-PlainPathNoReparse -Path $backupRoot -AllowMissing
    Assert-PlainPathNoReparse -Path $statePath -AllowMissing
    Assert-PlainPathNoReparse -Path $liveRoot -AllowMissing

    try {
        New-Item -ItemType Directory -Path $liveRoot -Force | Out-Null
        foreach ($step in $pending) {
            if ($step.Action -ne 'install') {
                Assert-TreeNoReparse -Root $step.Target
                $backup = Join-Path $backupRoot ("Hermes\$($step.Name)")
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                Copy-Item -LiteralPath $step.Target -Destination $backup -Recurse -Force
            }

            $staging = Join-Path $liveRoot (".deploying-$($step.Name)")
            $retired = Join-Path $liveRoot (".deploying-old-$($step.Name)")
            if (Test-Path -LiteralPath $staging) {
                Assert-TreeNoReparse -Root $staging
                $stagingBackup = Join-Path $backupRoot ("interrupted-staging\Hermes\$($step.Name)")
                New-Item -ItemType Directory -Path (Split-Path -Parent $stagingBackup) -Force | Out-Null
                Copy-Item -LiteralPath $staging -Destination $stagingBackup -Recurse -Force
            }
            if (Test-Path -LiteralPath $retired) {
                Assert-TreeNoReparse -Root $retired
                $retiredBackup = Join-Path $backupRoot ("interrupted\Hermes\$($step.Name)")
                New-Item -ItemType Directory -Path (Split-Path -Parent $retiredBackup) -Force | Out-Null
                Copy-Item -LiteralPath $retired -Destination $retiredBackup -Recurse -Force
            }
            foreach ($leftover in @($staging, $retired)) {
                if (Test-Path -LiteralPath $leftover) {
                    Assert-TreeNoReparse -Root $leftover
                    Remove-Item -LiteralPath $leftover -Recurse -Force
                }
            }

            if ($step.Action -ne 'prune') {
                Copy-SkillTree -SourceRoot $step.Source -DestinationRoot $staging
                foreach ($excludedFile in @(Get-ChildItem -LiteralPath $staging -File -Recurse -Force | Where-Object { $_.Name -ieq 'CREATION-LOG.md' })) {
                    Remove-Item -LiteralPath $excludedFile.FullName -Force
                }
            }
            if (Test-Path -LiteralPath $step.Target) {
                Rename-Item -LiteralPath $step.Target -NewName (Split-Path -Leaf $retired)
            }
            if ($step.Action -ne 'prune') {
                Rename-Item -LiteralPath $staging -NewName $step.Name
            }
            if (Test-Path -LiteralPath $retired) {
                Remove-Item -LiteralPath $retired -Recurse -Force
            }
        }

        $ownedSkills = @($plan.Items | Where-Object {
            $_.Action -cin @('install', 'update') -or ($_.Action -ceq 'unchanged' -and $_.RecordedInState)
        } | ForEach-Object Name | Sort-Object -Unique)

        $statePayload = [ordered]@{
            SchemaVersion = 1
            Category      = $script:HermesSkillsCategory
            Skills        = @($ownedSkills)
        }

        $tempStatePath = Join-Path $StateRoot ('deployed-skills.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $ownsTempState = $false
        try {
            New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
            $tempStream = [IO.File]::Open($tempStatePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $ownsTempState = $true
            $tempStream.Dispose()
            [IO.File]::WriteAllText($tempStatePath, (ConvertTo-Json -InputObject $statePayload -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($statePath)) {
                [IO.File]::Replace($tempStatePath, $statePath, [NullString]::Value)
            }
            else {
                [IO.File]::Move($tempStatePath, $statePath)
            }
            $ownsTempState = $false
        }
        catch {
            Write-Warning 'Hermes deployment state update failed. Live changes may already have occurred; inspect live directories and backups before retrying.'
            throw
        }
        finally {
            if ($ownsTempState -and (Test-Path -LiteralPath $tempStatePath)) {
                try { Remove-Item -LiteralPath $tempStatePath -Force -ErrorAction Stop }
                catch { Write-Warning "Could not remove temporary state file: $tempStatePath" }
            }
        }
    }
    catch {
        if (Test-Path -LiteralPath $backupRoot) {
            Write-Warning "Hermes apply failed; backups created so far: $backupRoot"
        }
        throw
    }

    $readback = Get-HermesSkillsPlan -ActionName 'Deploy' -RepoRoot $RepoRoot -HomeRoot $HomeRoot -StateRoot $StateRoot -Retire $Retire
    if ($readback.State -cne 'checked') {
        throw "Post-Apply readback verification failed (State=$($readback.State)): $($readback.Reason)"
    }
    $manifest = Get-HermesSkillsManifest -RepoRoot $RepoRoot
    foreach ($skillName in $manifest.Skills) {
        $match = @($readback.Items | Where-Object { $_.Name -ceq $skillName })
        if ($match.Count -ne 1 -or $match[0].Action -cne 'unchanged') {
            throw "Post-Apply readback verification failed: selected skill '$skillName' did not converge to unchanged."
        }
    }
    return $readback
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Apply -and $DryRun) {
    throw 'Specify -DryRun or -Apply, not both.'
}
if ($Apply -and $Json) {
    throw '-Json cannot be combined with -Apply.'
}

$explicitStatus = $PSBoundParameters.ContainsKey('Action') -and ($Action -ceq 'Status')
if ($explicitStatus) {
    if ($Apply) { throw '-Apply is supported only for Deploy.' }
    if (@($Retire).Count -gt 0) { throw '-Retire is supported only for Deploy.' }
    if ($SkipSecretScan) { throw '-SkipSecretScan is supported only for Deploy.' }
    if ($DryRun) { throw '-DryRun is supported only for Deploy.' }
}
if ($DryRun -or $Apply -or (@($Retire).Count -gt 0) -or $SkipSecretScan) {
    $Action = 'Deploy'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($HomeRoot)) {
    throw 'HomeRoot could not be determined.'
}
if ([string]::IsNullOrWhiteSpace($StateRoot)) {
    throw 'StateRoot could not be determined.'
}

$planResult = if ($Action -ceq 'Status') {
    Get-HermesSkillsPlan -ActionName 'Status' -RepoRoot $RepoRoot -HomeRoot $HomeRoot -StateRoot $StateRoot
}
else {
    Invoke-HermesSkillsDeploy -RepoRoot $RepoRoot -HomeRoot $HomeRoot -StateRoot $StateRoot -Retire $Retire -DoApply:$Apply -SkipSecretScan:$SkipSecretScan -Quiet:$Json
}

$report = ConvertTo-HermesSkillsReport -Plan $planResult
if ($JsonPath) {
    Write-HermesSkillsJsonFile -Path ([IO.Path]::GetFullPath($JsonPath)) -Value $report
}

if ($Json) {
    ConvertTo-Json -InputObject $report -Depth 10
}
else {
    $modeLabel = if ($Action -ceq 'Status') { 'status' } elseif ($Apply) { 'APPLY' } else { 'dry-run' }
    Write-HermesSkillsConsoleReport -Plan $planResult -ModeLabel $modeLabel
}
