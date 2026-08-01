#requires -Version 7.0
<#
.SYNOPSIS
    Shared read-only helpers for harness environment definition scripts.

.DESCRIPTION
    This file is intended to be dot-sourced. Beyond dot-sourcing
    scripts/harness-profile-common.ps1, it defines helper functions only:
    no param block, no writes, no command execution.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'harness-profile-common.ps1')
. (Join-Path $PSScriptRoot 'mcp-common.ps1')

function Get-HarnessEnvRoot {
    [CmdletBinding()]
    param([string] $RepoRoot)

    return Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) 'harness-source/envs'
}

function Get-HarnessEnvDefinitionFiles {
    [CmdletBinding()]
    param([string] $RepoRoot)

    $envRoot = Get-HarnessEnvRoot -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $envRoot -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $envRoot -File -Filter '*.psd1' | Sort-Object Name)
}

function Read-HarnessEnvDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $data = Import-HarnessDataFile -Path $Path -Kind 'env definition' -RequiredKeys @('SchemaVersion', 'Name', 'Profile', 'Skills')
    Test-HarnessKnownKeys -Data $data -Kind 'env definition' -Path $Path -AllowedKeys @(
        'SchemaVersion', 'Name', 'Description', 'Profile', 'Skills', 'McpTemplates'
    )

    $expectedName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if (-not [string]::Equals([string] $data.Name, $expectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Env definition Name '$($data.Name)' does not match its filename '$expectedName': $Path"
    }
    if (-not ($data.Skills -is [hashtable])) {
        throw "Env definition Skills must be a hashtable: $Path"
    }
    Test-HarnessKnownKeys -Data $data.Skills -Kind 'env definition Skills' -Path $Path -AllowedKeys @('Claude', 'Codex')

    if ($data.ContainsKey('McpTemplates')) {
        foreach ($templateId in @($data.McpTemplates)) {
            Test-McpSafeId -Value ([string]$templateId) -Label 'McpTemplates entry'
        }
    }

    return $data
}

function Resolve-HarnessEnvDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [hashtable] $Definition
    )

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $envName = [string] $Definition.Name

    $profileName = [string] $Definition.Profile
    $profilePath = Join-Path $repo "harness-source/profiles/$profileName.psd1"
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw "Env '$envName' references unknown Profile '$profileName': expected $profilePath"
    }
    try {
        # Resolve-HarnessProfileExtends resolves a profile's Extends list, so wrap
        # the env's named profile as a synthetic Extends entry to reuse it as-is.
        $resolvedProfiles = @(Resolve-HarnessProfileExtends -Profile @{ Extends = @($profileName) } -RepoRoot $repo)
    }
    catch {
        throw "Env '$envName' Profile '$profileName' failed to resolve: $($_.Exception.Message)"
    }

    $skills = if ($Definition.ContainsKey('Skills') -and $Definition.Skills -is [hashtable]) { $Definition.Skills } else { @{} }
    $manifests = @{
        Claude = Join-Path $repo 'manifests/managed-skills.claude.txt'
        Codex  = Join-Path $repo 'manifests/managed-skills.codex.txt'
    }
    foreach ($platform in @('Claude', 'Codex')) {
        if (-not $skills.ContainsKey($platform)) { continue }
        $manifestPath = $manifests[$platform]
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Env '$envName' cannot validate $platform skills; missing manifest: $manifestPath"
        }
        # Case-insensitive on purpose: sync.ps1 matches managed names with an
        # OrdinalIgnoreCase set, and env membership must not be stricter.
        $managed = @(Get-Content -LiteralPath $manifestPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        foreach ($skill in @($skills[$platform])) {
            if ([string] $skill -notin $managed) {
                throw "Env '$envName' references unmanaged $platform skill '$skill'."
            }
        }
    }

    $mcpTemplates = @(Get-HarnessEnvMcpTemplates -RepoRoot $repo -Definition $Definition)

    return [pscustomobject] @{
        Name             = $envName
        Profile          = $profileName
        ResolvedProfiles = $resolvedProfiles
        Definition       = $Definition
        McpTemplates     = $mcpTemplates
    }
}

function Get-HarnessEnvMcpTemplates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [hashtable] $Definition
    )

    $ids = if ($Definition.ContainsKey('McpTemplates')) { @($Definition.McpTemplates | ForEach-Object { [string] $_ }) } else { @() }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $result.Add((Get-McpTemplate -RepoRoot $RepoRoot -TemplateId $id))
    }
    return @($result)
}

function Get-HarnessEnvStagingRoot {
    [CmdletBinding()]
    param(
        [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Env name must be a bare identifier, not a path: $Name"
    }
    return Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) "envs/$Name"
}

function Get-HarnessEnvStatePath {
    [CmdletBinding()]
    param([string] $RepoRoot)

    return Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) 'state/current-env.json'
}

function Read-HarnessEnvState {
    [CmdletBinding()]
    param([string] $RepoRoot)

    $path = Get-HarnessEnvStatePath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    }
    catch {
        throw "Corrupt env state file: $path ($($_.Exception.Message))"
    }
    if ($null -eq $state -or $state.PSObject.Properties.Name -notcontains 'Name') {
        throw "Env state file is missing required key 'Name': $path"
    }
    return $state
}

function Get-HarnessEnvDefinitionHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    return Get-HarnessFileHash -Path $Path
}

function Get-HarnessTextSha256 {
    [CmdletBinding()]
    param([AllowNull()] [string] $Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text ?? '')
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-HarnessTreeHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string[]] $ExcludeDirectoryNames = @()
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }

    $root = (Resolve-Path -LiteralPath $Path).Path
    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName)) {
        $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName) -replace '\\', '/'
        if (@($ExcludeDirectoryNames).Count -gt 0 -and
            (($relative -split '/') | Where-Object { $_ -in $ExcludeDirectoryNames }).Count -gt 0) {
            continue
        }
        $rows.Add("$relative|$($file.Length)|$(Get-HarnessFileHash -Path $file.FullName)")
    }
    return Get-HarnessTextSha256 -Text (($rows.ToArray() -join "`n") + "`n")
}

function Get-HarnessRepositoryCommit {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { return $null }

    $output = & $git.Source -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $commit = ([string] ($output | Select-Object -First 1)).Trim()
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') { return $null }
    return $commit.ToLowerInvariant()
}

function Get-HarnessManifestHashes {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    return [ordered]@{
        Claude = Get-HarnessFileHash -Path (Join-Path $repo 'manifests/managed-skills.claude.txt')
        Codex = Get-HarnessFileHash -Path (Join-Path $repo 'manifests/managed-skills.codex.txt')
        OpenClaw = Get-HarnessFileHash -Path (Join-Path $repo 'manifests/managed-skills.openclaw.txt')
    }
}

function Get-HarnessManagedPluginDeclarationHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    return Get-HarnessFileHash -Path (Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) 'openclaw/plugins/managed-plugins.json')
}

function Get-HarnessSkillSourceHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [ValidateSet('Claude', 'Codex', 'OpenClaw')] [string] $Platform,
        [Parameter(Mandatory)] [string] $Name
    )

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $platformOnly = switch ($Platform) {
        'Claude' { 'claude-only' }
        'Codex' { 'codex-only' }
        'OpenClaw' { 'openclaw-only' }
    }
    $candidatePaths = @(
        (Join-Path $repo "skills-source/shared/$Name"),
        (Join-Path $repo "skills-source/$platformOnly/$Name")
    )
    $candidates = @($candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($candidates.Count -gt 1) {
        throw "Skill '$Name' exists in both shared and $platformOnly source roots. Resolve the source conflict before building an environment."
    }
    if ($candidates.Count -eq 0) { return $null }
    return Get-HarnessTreeHash -Path $candidates[0]
}

function Get-HarnessSkillSourceEvidenceStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    if ((Test-Path -LiteralPath (Join-Path $repo 'skills-source') -PathType Container)) {
        return 'available'
    }
    return 'not-collected'
}

function Get-HarnessProfileSourceHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $profiles = Join-Path $repo 'harness-source/profiles'
    $components = Join-Path $repo 'harness-source/components'
    if (-not (Test-Path -LiteralPath $profiles -PathType Container) -and
        -not (Test-Path -LiteralPath $components -PathType Container)) {
        return $null
    }
    $text = "profiles=$(Get-HarnessTreeHash -Path $profiles)`ncomponents=$(Get-HarnessTreeHash -Path $components)`n"
    return Get-HarnessTextSha256 -Text $text
}

function Get-HarnessEnvLockPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StagingPath)

    return Join-Path $StagingPath 'env.lock.json'
}

function Read-HarnessEnvLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StagingPath)

    $path = Get-HarnessEnvLockPath -StagingPath $StagingPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing environment lock: $path"
    }
    try {
        $lock = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    }
    catch {
        throw "Corrupt environment lock: $path ($($_.Exception.Message))"
    }
    foreach ($required in @('SchemaVersion', 'Name', 'DefinitionHash', 'RepositoryCommit', 'ManifestHashes', 'SkillSourceEvidence', 'SkillSourceHashes', 'StagedSkillTreeHashes', 'ProfileSourceHash', 'ProfileOutputHash', 'ManagedPluginDeclaration', 'BuiltFiles')) {
        if ($null -eq $lock -or $lock.PSObject.Properties.Name -notcontains $required) {
            throw "Environment lock is missing required key '$required': $path"
        }
    }
    if ([int] $lock.SchemaVersion -ne 2) {
        throw "Unsupported environment lock schema $($lock.SchemaVersion): $path"
    }
    return $lock
}

function Get-HarnessJsonProperty {
    [CmdletBinding()]
    param(
        [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $null }
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-HarnessLockMapKeys {
    [CmdletBinding()]
    param([AllowNull()] [object] $Map)

    if ($null -eq $Map) { return @() }
    return @($Map.PSObject.Properties.Name | Sort-Object)
}

function Test-HarnessEnvLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $DefinitionPath,
        [Parameter(Mandatory)] [string] $StagingPath
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $lock = $null
    $lockPath = Get-HarnessEnvLockPath -StagingPath $StagingPath
    try {
        $lock = Read-HarnessEnvLock -StagingPath $StagingPath
    }
    catch {
        $reasons.Add($_.Exception.Message)
        return [pscustomobject]@{
            Valid = $false
            Reasons = @($reasons)
            Lock = $null
            LockHash = $null
        }
    }

    $definition = $null
    try { $definition = Read-HarnessEnvDefinition -Path $DefinitionPath }
    catch { $reasons.Add($_.Exception.Message) }
    if ($null -ne $definition) {
        if ([string] $lock.Name -ne [string] $definition.Name) { $reasons.Add('lock environment name does not match definition') }
        $definitionHash = Get-HarnessEnvDefinitionHash -Path $DefinitionPath
        if ([string] $lock.DefinitionHash -ne $definitionHash) { $reasons.Add('environment definition changed since build') }
    }

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $currentCommit = Get-HarnessRepositoryCommit -RepoRoot $repo
    if ($null -ne $lock.RepositoryCommit -and $null -ne $currentCommit -and [string] $lock.RepositoryCommit -ne $currentCommit) {
        $reasons.Add('repository commit changed since build')
    }

    $manifestHashes = Get-HarnessManifestHashes -RepoRoot $repo
    foreach ($platform in @('Claude', 'Codex', 'OpenClaw')) {
        $saved = [string] (Get-HarnessJsonProperty -Object $lock.ManifestHashes -Name $platform)
        $current = [string] (Get-HarnessJsonProperty -Object $manifestHashes -Name $platform)
        if ($saved -ne $current) { $reasons.Add("$platform managed-skills manifest changed since build") }
    }

    $sourceEvidence = [string] $lock.SkillSourceEvidence
    if ($sourceEvidence -eq 'available') {
        foreach ($platform in @('Claude', 'Codex')) {
            $platformManifest = Join-Path $StagingPath ("manifest.{0}.txt" -f $platform.ToLowerInvariant())
            $names = if (Test-Path -LiteralPath $platformManifest -PathType Leaf) {
                @(Get-Content -LiteralPath $platformManifest | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            } else { @() }
            foreach ($name in $names) {
                $saved = [string] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $lock.SkillSourceHashes -Name $platform) -Name $name)
                $current = Get-HarnessSkillSourceHash -RepoRoot $repo -Platform $platform -Name $name
                if ($saved -ne [string] $current) { $reasons.Add("$platform skill source '$name' changed since build") }
            }
        }
    }

    $profileSourceHash = Get-HarnessProfileSourceHash -RepoRoot $repo
    if ($null -ne $lock.ProfileSourceHash -and $null -ne $profileSourceHash -and [string] $lock.ProfileSourceHash -ne $profileSourceHash) {
        $reasons.Add('harness profile/component source changed since build')
    }

    foreach ($platform in @('Claude', 'Codex')) {
        $stagedRoot = Join-Path $StagingPath "$($platform.ToLowerInvariant())/skills"
        $names = if (Test-Path -LiteralPath (Join-Path $StagingPath "manifest.$($platform.ToLowerInvariant()).txt") -PathType Leaf) {
            @(Get-Content -LiteralPath (Join-Path $StagingPath "manifest.$($platform.ToLowerInvariant()).txt") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } else { @() }
        foreach ($name in $names) {
            $saved = [string] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $lock.StagedSkillTreeHashes -Name $platform) -Name $name)
            $current = Get-HarnessTreeHash -Path (Join-Path $stagedRoot $name)
            if ($saved -ne [string] $current) { $reasons.Add("staged $platform skill '$name' changed or is missing") }
        }
    }
    $profileOutputHash = Get-HarnessTreeHash -Path (Join-Path $StagingPath 'profile')
    if ([string] $lock.ProfileOutputHash -ne [string] $profileOutputHash) { $reasons.Add('staged profile output changed or is missing') }

    $savedFiles = @($lock.BuiltFiles.PSObject.Properties.Name | Sort-Object)
    # sync.ps1 writes run reports under a staging repo during activation. Those
    # reports are runtime evidence, not build artifacts covered by env.lock.json.
    $currentFiles = @(Get-ChildItem -LiteralPath $StagingPath -File -Recurse -Force |
        Where-Object { $_.FullName -ne $lockPath } |
        ForEach-Object { [System.IO.Path]::GetRelativePath($StagingPath, $_.FullName) -replace '\\', '/' } |
        Where-Object { -not $_.StartsWith('reports/', [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object)
    if ((ConvertTo-Json $savedFiles -Compress) -ne (ConvertTo-Json $currentFiles -Compress)) {
        $reasons.Add('staging file set differs from env.lock.json')
    }
    foreach ($relative in $currentFiles) {
        $savedHash = [string] (Get-HarnessJsonProperty -Object $lock.BuiltFiles -Name $relative)
        $currentHash = Get-HarnessFileHash -Path (Join-Path $StagingPath ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar))
        if ($savedHash -ne [string] $currentHash) { $reasons.Add("staged file changed: $relative") }
    }

    [pscustomobject]@{
        Valid = ($reasons.Count -eq 0)
        Reasons = @($reasons)
        Lock = $lock
        LockHash = Get-HarnessFileHash -Path $lockPath
    }
}
