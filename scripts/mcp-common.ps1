#requires -Version 7.0
<#
.SYNOPSIS
    Read-only validation and plan helpers for Claude MCP templates.
#>
Set-StrictMode -Version Latest

function Resolve-McpRepoRoot {
    param([string] $RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '..' }
    return (Resolve-Path -LiteralPath $RepoRoot).Path
}

function Get-McpTemplateRoot {
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $root = Join-Path (Resolve-McpRepoRoot -RepoRoot $RepoRoot) 'harness-source/components/mcp-templates'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Missing MCP template root: $root" }
    return $root
}

function Test-McpSafeId {
    param([Parameter(Mandatory)] [string] $Value, [Parameter(Mandatory)] [string] $Label)
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "$Label must be a bare identifier: $Value" }
}

function Test-McpSafeText {
    param([AllowNull()] [string] $Value, [Parameter(Mandatory)] [string] $Label)
    if ($null -eq $Value) { return }
    if ($Value -match '(?i)(?:^|[\s=])(?:sk-[A-Za-z0-9]|gh[pousr]_[A-Za-z0-9]|xox[baprs]-|AKIA[A-Z0-9]{12,}|Bearer\s+|token\s*=|secret\s*=|password\s*=)') {
        throw "$Label contains a credential-like literal. Use an environment placeholder."
    }
    if ($Value -match '(?<![A-Za-z])[A-Za-z]:[\\/]') { throw "$Label contains a machine-private path." }
    if ($Value -match '^\\\\') { throw "$Label contains a UNC path." }
    if ($Value -match '(?i)(?:^|[\\/])\.\.(?:[\\/]|$)') { throw "$Label contains a path escape." }
}

function Get-McpTemplate {
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $TemplateId)

    Test-McpSafeId -Value $TemplateId -Label 'TemplateId'
    $root = Get-McpTemplateRoot -RepoRoot $RepoRoot
    $dir = Join-Path $root $TemplateId
    $path = Join-Path $dir 'template.psd1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Unknown MCP template '$TemplateId': $path" }

    $data = Import-PowerShellDataFile -LiteralPath $path
    if (-not ($data -is [hashtable])) { throw "MCP template must import as a hashtable: $path" }
    $allowed = @('SchemaVersion', 'Id', 'Description', 'Command', 'Args', 'RequiredEnv', 'Env', 'Scope')
    foreach ($key in $data.Keys) { if ($key -notin $allowed) { throw "MCP template contains unknown key '$key': $path" } }
    foreach ($key in @('SchemaVersion', 'Id', 'Command', 'Args', 'RequiredEnv', 'Env')) {
        if (-not $data.ContainsKey($key)) { throw "MCP template is missing '$key': $path" }
    }
    if ([int]$data.SchemaVersion -ne 1) { throw "Unsupported MCP template SchemaVersion: $path" }
    if ([string]$data.Id -ne $TemplateId) { throw "MCP template Id does not match directory: $path" }
    if ([string]$data.Scope -and [string]$data.Scope -ne 'user') { throw "Only user MCP scope is supported: $path" }
    if ([string]$data.Command -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "MCP command must be a safe executable name: $path" }
    Test-McpSafeText -Value ([string]$data.Description) -Label 'Description'

    $args = @($data.Args | ForEach-Object { [string] $_ })
    foreach ($arg in $args) {
        if ([string]::IsNullOrWhiteSpace($arg)) { throw "MCP Args cannot contain empty values: $path" }
        Test-McpSafeText -Value $arg -Label 'Args'
        if ($arg -match '^[~/]' -or $arg -match '^[A-Za-z]:[\\/]' -or $arg -match '^\\\\' -or $arg -match '^[a-z][a-z0-9+.-]*://') {
            throw "MCP Args cannot contain absolute paths or URLs: $path"
        }
    }

    $required = @($data.RequiredEnv | ForEach-Object { [string] $_ })
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $required) {
        if ($name -notmatch '^[A-Z_][A-Z0-9_]*$' -or -not $seen.Add($name)) { throw "Invalid or duplicate RequiredEnv '$name': $path" }
    }
    if (-not ($data.Env -is [hashtable])) { throw "MCP Env must be a hashtable: $path" }
    foreach ($key in $data.Env.Keys) {
        $name = [string]$key
        if ($name -notin $required) { throw "MCP Env key '$name' is not declared in RequiredEnv: $path" }
        $placeholder = [string]$data.Env[$key]
        if ($placeholder -ne "`${$name}") { throw "MCP Env '$name' must use the exact `${$name} placeholder: $path" }
    }
    foreach ($name in $required) {
        if (-not $data.Env.ContainsKey($name)) { throw "MCP RequiredEnv '$name' has no placeholder mapping: $path" }
    }

    return [pscustomobject]@{
        Id = $TemplateId
        Path = $path
        Directory = $dir
        Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Description = [string]$data.Description
        Command = [string]$data.Command
        Args = $args
        RequiredEnv = $required
        Env = $data.Env
        Scope = 'user'
    }
}

function Get-McpValueHash {
    param([AllowNull()] [string] $Value)
    if ($null -eq $Value) { return $null }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-McpEnvState {
    param([Parameter(Mandatory)] $Template)
    $states = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($Template.RequiredEnv)) {
        $value = [Environment]::GetEnvironmentVariable($name)
        $present = -not [string]::IsNullOrEmpty($value)
        $states[$name] = [ordered]@{ Present = $present; Hash = if ($present) { Get-McpValueHash -Value $value } else { $null } }
        if (-not $present) { $missing.Add($name) }
    }
    return [pscustomobject]@{ States = $states; Missing = @($missing) }
}

function ConvertTo-McpPlanHash {
    param([Parameter(Mandatory)] $Plan)
    $copy = [ordered]@{}
    foreach ($property in $Plan.PSObject.Properties) {
        if ($property.Name -ne 'PlanHash') { $copy[$property.Name] = $property.Value }
    }
    $json = $copy | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Write-McpJson {
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)] [string] $Path)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, (($Object | ConvertTo-Json -Depth 30) + "`n"), [System.Text.UTF8Encoding]::new($false))
}
