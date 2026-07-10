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

    $mcpTemplates = if ($Definition.ContainsKey('McpTemplates')) { @($Definition.McpTemplates) } else { @() }
    foreach ($templateId in $mcpTemplates) {
        $templateDir = Join-Path $repo "harness-source/components/mcp-templates/$templateId"
        if (-not (Test-Path -LiteralPath $templateDir -PathType Container)) {
            throw "Env '$envName' references unknown McpTemplate '$templateId': expected $templateDir"
        }
    }

    return [pscustomobject] @{
        Name             = $envName
        Profile          = $profileName
        ResolvedProfiles = $resolvedProfiles
        Definition       = $Definition
    }
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
