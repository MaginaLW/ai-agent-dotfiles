#requires -Version 7.0
<#
.SYNOPSIS
    Inspects and projects managed MCP server definitions from harness-source/mcp/servers.psd1
    to Antigravity, Codex, and Hermes.

.DESCRIPTION
    Status and Deploy -DryRun are read-only and never create or modify live home files.
    Deploy -Apply requires a clean secret scan, backs up any existing target files before
    mutating, projects only declared server entries (preserving all unmanaged servers and
    personal configuration), and runs a post-Apply readback check.

    Antigravity writes per-entry into ~/.gemini/config/mcp_config.json (mcpServers.<name>).
    Codex projects per-entry exclusively via the official `codex mcp` CLI.
    Hermes surgically updates per-entry in %LOCALAPPDATA%/hermes/config.yaml (mcp_servers.<name>).
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Deploy')]
    [string] $Action = 'Status',
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $HomeRoot = [Environment]::GetFolderPath('UserProfile'),
    [string[]] $Platform = @('Antigravity', 'Codex', 'Hermes'),
    [string[]] $Server = @(),
    [string] $BackupRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ai-agent-dotfiles-backups'),
    [string] $JsonPath,
    [switch] $Json,
    [switch] $DryRun,
    [switch] $Apply,
    [switch] $SkipSecretScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'repo-common.ps1')
. (Join-Path $PSScriptRoot 'config-common.ps1')

function Assert-McpSafeValue {
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [string] $Context
    )
    if ($Value -match '[\r\n]') {
        throw "MCP registry value for $Context must not contain line breaks."
    }
    if (($Value -match $script:DriveAbsolutePathPattern) -or ($Value -match $script:UncPathPattern)) {
        throw "MCP registry value for $Context must not contain a machine-private drive or UNC path."
    }
    if ($Value -match '(?:sk-ant-[A-Za-z0-9_-]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z-_]{35}|gh[opusr]_[A-Za-z0-9_]{36}|github_pat_[A-Za-z0-9_]{22,}|xox[bpars]-[A-Za-z0-9-]{10,}|-----BEGIN ((?:RSA|OPENSSH|EC|ENCRYPTED|PKCS8) )?PRIVATE KEY-----|Bearer\s+[A-Za-z0-9._-]{20,})') {
        throw "MCP registry value for $Context appears to contain a literal secret."
    }
}

function Resolve-McpPlatforms {
    param([string[]] $Values)
    $canonical = @{
        antigravity = 'Antigravity'
        codex       = 'Codex'
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
                throw "Unsupported MCP platform '$trimmed'. Expected Antigravity, Codex, or Hermes."
            }
            $name = $canonical[$key]
            if ($seen.Add($name)) { $selected.Add($name) }
        }
    }
    if ($selected.Count -eq 0) {
        throw 'At least one MCP platform must be specified.'
    }
    return , $selected.ToArray()
}

function Resolve-McpServerFilter {
    param(
        [string[]] $Values,
        [Parameter(Mandatory)] [object[]] $DeclaredServers
    )
    $declaredNames = @($DeclaredServers | ForEach-Object { $_.Name })
    $selected = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($raw in @($Values)) {
        foreach ($token in ([string]$raw -split ',')) {
            $trimmed = $token.Trim()
            if ([string]::IsNullOrEmpty($trimmed)) { continue }
            if ($trimmed -cnotmatch '^[a-z0-9][a-z0-9_-]*$') {
                throw "Invalid MCP server name filter '$trimmed'."
            }
            if ($trimmed -cnotin $declaredNames) {
                throw "Unknown managed MCP server: $trimmed"
            }
            if ($seen.Add($trimmed)) { $selected.Add($trimmed) }
        }
    }
    return , $selected.ToArray()
}

function Read-McpServerRegistry {
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $registryPath = Join-Path $RepoRoot 'harness-source/mcp/servers.psd1'
    Assert-PlainPathNoReparse -Path $registryPath -AllowMissing -MessagePrefix 'MCP target path cannot contain reparse points'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        throw "Missing managed MCP registry: $registryPath"
    }
    $data = Import-PowerShellDataFile -LiteralPath $registryPath
    if ($data -isnot [hashtable]) {
        throw 'MCP registry must evaluate to a hashtable.'
    }
    $topKeys = @($data.Keys | Sort-Object -CaseSensitive) -join ','
    if ($topKeys -cne 'SchemaVersion,Servers' -or $data.SchemaVersion -ne 1) {
        throw 'Unsupported MCP registry schema (expected SchemaVersion = 1 and Servers).'
    }
    if ($null -eq $data.Servers) {
        throw 'MCP registry Servers must be an array.'
    }
    $allowedServerKeys = @('Name', 'Transport', 'Enabled', 'EnabledPolicy', 'Platforms', 'Command', 'Args', 'Env', 'Url', 'BearerTokenEnvVar', 'Headers')
    $validPlatforms = @('Antigravity', 'Codex', 'Hermes')
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $servers = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @($data.Servers)) {
        if ($entry -isnot [hashtable]) {
            throw 'Each MCP server entry must be a hashtable.'
        }
        foreach ($key in $entry.Keys) {
            if ($key -cnotin $allowedServerKeys) {
                throw "Unsupported MCP server key '$key'."
            }
        }
        foreach ($required in @('Name', 'Transport', 'Enabled', 'Platforms')) {
            if (-not $entry.ContainsKey($required)) {
                throw "MCP server entry is missing required key '$required'."
            }
        }
        $name = $entry.Name
        if ($name -isnot [string] -or $name -cnotmatch '^[a-z0-9][a-z0-9_-]*$') {
            throw "Invalid MCP server name '$name'."
        }
        if (-not $seenNames.Add($name)) {
            throw "Duplicate MCP server name '$name'."
        }
        $transport = $entry.Transport
        if ($transport -isnot [string] -or $transport -cnotin @('stdio', 'streamable-http')) {
            throw "Unsupported MCP transport '$transport' for server '$name'."
        }
        if ($entry.Enabled -isnot [bool]) {
            throw "MCP server '$name' Enabled must be a boolean."
        }
        $enabledPolicy = 'enforce'
        if ($entry.ContainsKey('EnabledPolicy')) {
            if ($entry.EnabledPolicy -isnot [string] -or $entry.EnabledPolicy -cnotin @('enforce', 'preserve-disabled')) {
                throw "MCP server '$name' EnabledPolicy must be 'enforce' or 'preserve-disabled'."
            }
            $enabledPolicy = $entry.EnabledPolicy
        }
        $platforms = @($entry.Platforms)
        if ($platforms.Count -eq 0) {
            throw "MCP server '$name' must specify at least one platform."
        }
        $seenPlatforms = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($p in $platforms) {
            if ($p -isnot [string] -or $p -cnotin $validPlatforms -or (-not $seenPlatforms.Add($p))) {
                throw "MCP server '$name' has invalid or duplicate platform '$p'."
            }
        }

        $normalized = [ordered]@{
            Name          = $name
            Transport     = $transport
            Enabled       = [bool]$entry.Enabled
            EnabledPolicy = $enabledPolicy
            Platforms     = @($platforms)
        }

        if ($transport -ceq 'stdio') {
            foreach ($forbidden in @('Url', 'BearerTokenEnvVar', 'Headers')) {
                if ($entry.ContainsKey($forbidden)) {
                    throw "Stdio MCP server '$name' cannot declare '$forbidden'."
                }
            }
            if (-not $entry.ContainsKey('Command') -or $entry.Command -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Command) -or $entry.Command -match '\s') {
                throw "Stdio MCP server '$name' requires a non-empty Command without whitespace."
            }
            Assert-McpSafeValue -Value $entry.Command -Context "$name.Command"
            $normalized.Command = $entry.Command

            $argsList = [System.Collections.Generic.List[string]]::new()
            if ($entry.ContainsKey('Args')) {
                if ($entry.Args -is [string] -or $null -eq $entry.Args) {
                    throw "Stdio MCP server '$name' Args must be an array of strings."
                }
                foreach ($arg in @($entry.Args)) {
                    if ($arg -isnot [string]) {
                        throw "Stdio MCP server '$name' Args entries must be strings."
                    }
                    Assert-McpSafeValue -Value $arg -Context "$name.Args"
                    $argsList.Add($arg)
                }
            }
            $normalized.Args = $argsList.ToArray()

            $envMap = [ordered]@{}
            if ($entry.ContainsKey('Env')) {
                if ($entry.Env -isnot [hashtable]) {
                    throw "Stdio MCP server '$name' Env must be a hashtable."
                }
                foreach ($envKey in @($entry.Env.Keys | Sort-Object -CaseSensitive)) {
                    if ($envKey -isnot [string] -or $envKey -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                        throw "Stdio MCP server '$name' has invalid Env key '$envKey'."
                    }
                    $envVal = $entry.Env[$envKey]
                    if ($envVal -isnot [string]) {
                        throw "Stdio MCP server '$name' Env['$envKey'] must be a string."
                    }
                    Assert-McpSafeValue -Value $envVal -Context "$name.Env.$envKey"
                    if ($envKey -match '(?i)(api_?key|token|secret|password|passwd|credential)' -and $envVal -cnotmatch '^\$\{[A-Za-z_][A-Za-z0-9_]*\}$') {
                        throw "Stdio MCP server '$name' Env['$envKey'] must use a `${ENV_VAR}` placeholder rather than a literal credential."
                    }
                    $envMap[$envKey] = $envVal
                }
            }
            $normalized.Env = $envMap
        }
        else {
            foreach ($forbidden in @('Command', 'Args', 'Env')) {
                if ($entry.ContainsKey($forbidden)) {
                    throw "HTTP MCP server '$name' cannot declare '$forbidden'."
                }
            }
            if (-not $entry.ContainsKey('Url') -or $entry.Url -isnot [string] -or $entry.Url -cnotmatch '^https?://[^\s]+$' -or $entry.Url -match '://[^/@\s]+:[^/@\s]+@') {
                throw "HTTP MCP server '$name' requires a clean http(s) Url without embedded credentials."
            }
            Assert-McpSafeValue -Value $entry.Url -Context "$name.Url"
            $normalized.Url = $entry.Url

            if ($entry.ContainsKey('BearerTokenEnvVar')) {
                if ($entry.BearerTokenEnvVar -isnot [string] -or $entry.BearerTokenEnvVar -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                    throw "HTTP MCP server '$name' BearerTokenEnvVar must be a valid environment variable name."
                }
                $normalized.BearerTokenEnvVar = $entry.BearerTokenEnvVar
            }

            $headersMap = [ordered]@{}
            if ($entry.ContainsKey('Headers')) {
                if ($entry.Headers -isnot [hashtable]) {
                    throw "HTTP MCP server '$name' Headers must be a hashtable."
                }
                foreach ($headerKey in @($entry.Headers.Keys | Sort-Object -CaseSensitive)) {
                    if ($headerKey -isnot [string] -or [string]::IsNullOrWhiteSpace($headerKey)) {
                        throw "HTTP MCP server '$name' has an invalid header name."
                    }
                    $headerVal = $entry.Headers[$headerKey]
                    if ($headerVal -isnot [string]) {
                        throw "HTTP MCP server '$name' header '$headerKey' must be a string."
                    }
                    Assert-McpSafeValue -Value $headerVal -Context "$name.Headers.$headerKey"
                    $headersMap[$headerKey] = $headerVal
                }
            }
            $normalized.Headers = $headersMap
        }

        $servers.Add([pscustomobject]$normalized)
    }

    return [pscustomobject]@{
        Path    = $registryPath
        Servers = $servers.ToArray()
    }
}

function Invoke-McpCodexCommand {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $HomeRoot
    )
    $cmd = @(Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($cmd.Count -eq 0) {
        return @{ Available = $false; Code = -1; Out = ''; Error = 'codex CLI not found on PATH.' }
    }
    $target = $cmd[0]
    $codexHome = Join-Path $HomeRoot '.codex'
    $filePath = $null
    $procArgs = [System.Collections.Generic.List[string]]::new()
    if ($target.CommandType -eq 'ExternalScript') {
        $filePath = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
        $procArgs.Add('-NoProfile')
        $procArgs.Add('-File')
        $procArgs.Add($target.Source)
        foreach ($arg in $Arguments) { $procArgs.Add($arg) }
    }
    elseif ($target.Source -match '\.(cmd|bat)$') {
        $filePath = 'cmd.exe'
        $procArgs.Add('/d')
        $procArgs.Add('/c')
        $procArgs.Add($target.Source)
        foreach ($arg in $Arguments) { $procArgs.Add($arg) }
    }
    else {
        $filePath = $target.Source
        foreach ($arg in $Arguments) { $procArgs.Add($arg) }
    }
    $res = Invoke-BoundedProcess -FilePath $filePath -Arguments $procArgs.ToArray() -Environment @{ CODEX_HOME = $codexHome } -TimeoutSeconds 120 -TimeoutMessage 'codex mcp command timed out after 120 seconds.' -CloseStdIn
    return @{
        Available = $true
        Code      = $res.ExitCode
        Out       = $res.StdOut
        Error     = $res.StdErr
    }
}

function ConvertTo-McpOrderedObject {
    param([Parameter(Mandatory)] [System.Text.Json.JsonElement] $Element)
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $obj = [ordered]@{}
            foreach ($prop in $Element.EnumerateObject()) {
                $obj[$prop.Name] = ConvertTo-McpOrderedObject -Element $prop.Value
            }
            return $obj
        }
        'Array' {
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $items.Add((ConvertTo-McpOrderedObject -Element $item))
            }
            return , $items.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            $longVal = [long]0
            if ($Element.TryGetInt64([ref]$longVal)) { return $longVal }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { return $Element.GetRawText() }
    }
}

function Test-McpObjectJsonEqual {
    param(
        [Parameter(Mandatory)] [object] $Left,
        [Parameter(Mandatory)] [object] $Right
    )
    $leftJson = ConvertTo-Json -InputObject $Left -Depth 20 -Compress
    $rightJson = ConvertTo-Json -InputObject $Right -Depth 20 -Compress
    $leftDoc = $null
    $rightDoc = $null
    try {
        $leftDoc = [System.Text.Json.JsonDocument]::Parse($leftJson)
        $rightDoc = [System.Text.Json.JsonDocument]::Parse($rightJson)
        return Test-JsonEqual $leftDoc.RootElement $rightDoc.RootElement
    }
    finally {
        if ($null -ne $leftDoc) { $leftDoc.Dispose() }
        if ($null -ne $rightDoc) { $rightDoc.Dispose() }
    }
}

function Get-McpObjectFieldDiffs {
    param(
        [AllowNull()] [object] $Before,
        [Parameter(Mandatory)] [object] $After
    )
    $beforeJson = if ($null -eq $Before) { '{}' } else { ConvertTo-Json -InputObject $Before -Depth 20 -Compress }
    $afterJson = ConvertTo-Json -InputObject $After -Depth 20 -Compress
    $beforeDoc = $null
    $afterDoc = $null
    try {
        $beforeDoc = [System.Text.Json.JsonDocument]::Parse($beforeJson)
        $afterDoc = [System.Text.Json.JsonDocument]::Parse($afterJson)
        $diffs = @(Get-JsonFieldDifferences $afterDoc.RootElement $beforeDoc.RootElement '')
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($d in $diffs) {
            $prefix = switch ($d.Kind) {
                'repo-only' { '+' }
                'home-only' { '-' }
                default { '~' }
            }
            $lines.Add("$prefix $($d.Path)")
        }
        return , $lines.ToArray()
    }
    finally {
        if ($null -ne $beforeDoc) { $beforeDoc.Dispose() }
        if ($null -ne $afterDoc) { $afterDoc.Dispose() }
    }
}

function Read-McpJsonConfigState {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string[]] $ContainerPath
    )
    try {
        Assert-PlainPathNoReparse -Path $Path -AllowMissing -MessagePrefix 'MCP target path cannot contain reparse points'
    }
    catch {
        return [pscustomobject]@{
            Path       = $Path
            Exists     = $false
            Valid      = $false
            Reason     = 'reparse-point-blocked'
            RawText    = $null
            Entries    = [ordered]@{}
        }
    }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        return [pscustomobject]@{
            Path       = $Path
            Exists     = $true
            Valid      = $false
            Reason     = 'target-is-directory'
            RawText    = $null
            Entries    = [ordered]@{}
        }
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Path       = $Path
            Exists     = $false
            Valid      = $true
            Reason     = $null
            RawText    = '{}'
            Entries    = [ordered]@{}
        }
    }

    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            Path       = $Path
            Exists     = $true
            Valid      = $true
            Reason     = $null
            RawText    = '{}'
            Entries    = [ordered]@{}
        }
    }

    $doc = $null
    try {
        $doc = [System.Text.Json.JsonDocument]::Parse($raw)
        if ($doc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            return [pscustomobject]@{ Path = $Path; Exists = $true; Valid = $false; Reason = 'non-object-json'; RawText = $null; Entries = [ordered]@{} }
        }
        Assert-JsonUniqueObjectKeys $doc.RootElement

        $cursor = $doc.RootElement
        foreach ($segment in $ContainerPath) {
            $next = [System.Text.Json.JsonElement]::new()
            if (-not $cursor.TryGetProperty($segment, [ref]$next)) {
                return [pscustomobject]@{
                    Path    = $Path
                    Exists  = $true
                    Valid   = $true
                    Reason  = $null
                    RawText = $raw
                    Entries = [ordered]@{}
                }
            }
            if ($next.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                return [pscustomobject]@{
                    Path    = $Path
                    Exists  = $true
                    Valid   = $false
                    Reason  = "invalid-$segment-container"
                    RawText = $null
                    Entries = [ordered]@{}
                }
            }
            $cursor = $next
        }

        $entries = [ordered]@{}
        foreach ($prop in $cursor.EnumerateObject()) {
            $entries[$prop.Name] = ConvertTo-McpOrderedObject -Element $prop.Value
        }
        return [pscustomobject]@{
            Path    = $Path
            Exists  = $true
            Valid   = $true
            Reason  = $null
            RawText = $raw
            Entries = $entries
        }
    }
    catch {
        return [pscustomobject]@{
            Path    = $Path
            Exists  = $true
            Valid   = $false
            Reason  = 'invalid-json-or-duplicate-key'
            RawText = $null
            Entries = [ordered]@{}
        }
    }
    finally {
        if ($null -ne $doc) { $doc.Dispose() }
    }
}

function Get-McpExpectedJsonPayload {
    param(
        [Parameter(Mandatory)] [object] $Server,
        [Parameter(Mandatory)] [ValidateSet('Antigravity')] [string] $PlatformName
    )
    if ($Server.Transport -ceq 'stdio') {
        $payload = [ordered]@{
            command = [string]$Server.Command
            args    = [string[]]@($Server.Args | ForEach-Object { [string]$_ })
        }
        if ($Server.Env.Count -gt 0) {
            $envCopy = [ordered]@{}
            foreach ($k in $Server.Env.Keys) { $envCopy[$k] = $Server.Env[$k] }
            $payload['env'] = $envCopy
        }
        return [pscustomobject]@{ Supported = $true; Reason = $null; Payload = $payload }
    }
    else {
        $payload = [ordered]@{ url = [string]$Server.Url }
        $headers = [ordered]@{}
        foreach ($k in $Server.Headers.Keys) { $headers[$k] = $Server.Headers[$k] }
        if ($Server.PSObject.Properties['BearerTokenEnvVar'] -and (-not $headers.Contains('Authorization'))) {
            $headers['Authorization'] = ('Bearer ${' + $Server.BearerTokenEnvVar + '}')
        }
        if ($headers.Count -gt 0) { $payload['headers'] = $headers }
        return [pscustomobject]@{ Supported = $true; Reason = $null; Payload = $payload }
    }
}

function Get-McpExpectedCodexSpec {
    param([Parameter(Mandatory)] [object] $Server)
    if ($Server.Transport -ceq 'stdio') {
        foreach ($k in $Server.Env.Keys) {
            if ($Server.Env[$k] -match '\$\{[A-Za-z_][A-Za-z0-9_]*\}') {
                return [pscustomobject]@{ Supported = $false; Reason = 'codex-env-template-unsupported'; Canonical = $null; AddArgs = $null }
            }
        }
        $envObj = [ordered]@{}
        foreach ($k in $Server.Env.Keys) { $envObj[$k] = $Server.Env[$k] }
        $canonical = [ordered]@{
            enabled = $true
            type    = 'stdio'
            command = [string]$Server.Command
            args    = [string[]]@($Server.Args | ForEach-Object { [string]$_ })
            env     = $envObj
        }
        $cliArgs = [System.Collections.Generic.List[string]]::new()
        $cliArgs.Add('mcp')
        $cliArgs.Add('add')
        $cliArgs.Add($Server.Name)
        foreach ($k in $Server.Env.Keys) {
            $cliArgs.Add('--env')
            $cliArgs.Add("$k=$($Server.Env[$k])")
        }
        $cliArgs.Add('--')
        $cliArgs.Add($Server.Command)
        foreach ($a in $Server.Args) { $cliArgs.Add($a) }
        return [pscustomobject]@{ Supported = $true; Reason = $null; Canonical = $canonical; AddArgs = $cliArgs.ToArray() }
    }

    if ($Server.Headers.Count -gt 0) {
        return [pscustomobject]@{ Supported = $false; Reason = 'codex-http-headers-unsupported'; Canonical = $null; AddArgs = $null }
    }
    $httpCanonical = [ordered]@{
        enabled = $true
        type    = 'streamable_http'
        url     = [string]$Server.Url
    }
    $httpArgs = [System.Collections.Generic.List[string]]::new()
    $httpArgs.Add('mcp')
    $httpArgs.Add('add')
    $httpArgs.Add($Server.Name)
    $httpArgs.Add('--url')
    $httpArgs.Add($Server.Url)
    if ($Server.PSObject.Properties['BearerTokenEnvVar']) {
        $httpCanonical['bearer_token_env_var'] = [string]$Server.BearerTokenEnvVar
        $httpArgs.Add('--bearer-token-env-var')
        $httpArgs.Add($Server.BearerTokenEnvVar)
    }
    return [pscustomobject]@{ Supported = $true; Reason = $null; Canonical = $httpCanonical; AddArgs = $httpArgs.ToArray() }
}

function ConvertFrom-McpCodexLiveEntry {
    param([Parameter(Mandatory)] [hashtable] $Entry)
    $transport = $Entry['transport']
    if ($transport -isnot [hashtable] -or (-not $transport.ContainsKey('type'))) { return $null }
    $type = [string]$transport['type']
    if ($type -ceq 'stdio') {
        $envObj = [ordered]@{}
        if ($transport.ContainsKey('env') -and $transport['env'] -is [hashtable]) {
            foreach ($k in @($transport['env'].Keys | Sort-Object -CaseSensitive)) {
                $envObj[$k] = [string]$transport['env'][$k]
            }
        }
        $argsList = [System.Collections.Generic.List[string]]::new()
        if ($transport.ContainsKey('args') -and $null -ne $transport['args']) {
            foreach ($a in @($transport['args'])) {
                if ($null -ne $a) { $argsList.Add([string]$a) }
            }
        }
        $out = [ordered]@{
            enabled = [bool]$Entry['enabled']
            type    = 'stdio'
            command = [string]$transport['command']
            args    = $argsList.ToArray()
            env     = $envObj
        }
        if ($transport.ContainsKey('cwd') -and $null -ne $transport['cwd']) {
            $out['cwd'] = [string]$transport['cwd']
        }
        if ($transport.ContainsKey('env_vars') -and $null -ne $transport['env_vars'] -and @($transport['env_vars']).Count -gt 0) {
            $out['env_vars'] = @($transport['env_vars'] | ForEach-Object { [string]$_ })
        }
        return $out
    }
    if ($type -ceq 'streamable_http') {
        $out = [ordered]@{
            enabled = [bool]$Entry['enabled']
            type    = 'streamable_http'
            url     = [string]$transport['url']
        }
        if ($transport.ContainsKey('bearer_token_env_var') -and $null -ne $transport['bearer_token_env_var']) {
            $out['bearer_token_env_var'] = [string]$transport['bearer_token_env_var']
        }
        return $out
    }
    return [ordered]@{ enabled = [bool]$Entry['enabled']; type = $type }
}

function Get-McpCodexInventory {
    param([Parameter(Mandatory)] [string] $HomeRoot)
    $codexDir = Join-Path $HomeRoot '.codex'
    $codexConfig = Join-Path $codexDir 'config.toml'
    try {
        Assert-PlainPathNoReparse -Path $codexConfig -AllowMissing -MessagePrefix 'MCP target path cannot contain reparse points'
    }
    catch {
        return [pscustomobject]@{ Available = $false; Valid = $false; Reason = 'reparse-point-blocked'; Entries = @() }
    }
    if (Test-Path -LiteralPath $codexDir -PathType Leaf) {
        return [pscustomobject]@{ Available = $false; Valid = $false; Reason = 'codex-dir-not-directory'; Entries = @() }
    }
    if (Test-Path -LiteralPath $codexConfig -PathType Container) {
        return [pscustomobject]@{ Available = $false; Valid = $false; Reason = 'target-is-directory'; Entries = @() }
    }
    if (-not (Test-Path -LiteralPath $codexDir -PathType Container)) {
        $probe = Invoke-McpCodexCommand -Arguments @('--version') -HomeRoot $HomeRoot
        if (-not $probe.Available) {
            return [pscustomobject]@{ Available = $false; Valid = $false; Reason = 'codex-cli-unavailable'; Entries = @() }
        }
        if ($probe.Code -ne 0) {
            return [pscustomobject]@{ Available = $false; Valid = $false; Reason = 'codex-cli-probe-failed'; Entries = @() }
        }
        return [pscustomobject]@{ Available = $true; Valid = $true; Reason = $null; Entries = @() }
    }

    $listing = Invoke-McpCodexCommand -Arguments @('mcp', 'list', '--json') -HomeRoot $HomeRoot
    if (-not $listing.Available) {
        return [pscustomobject]@{ Available = $false; Valid = $false; Reason = 'codex-cli-unavailable'; Entries = @() }
    }
    if ($listing.Code -ne 0) {
        return [pscustomobject]@{ Available = $false; Valid = $false; Reason = 'codex-mcp-list-failed'; Entries = @() }
    }
    try {
        $parsed = ConvertFrom-Json -InputObject $listing.Out -AsHashtable -NoEnumerate
        if ($parsed -isnot [array]) {
            return [pscustomobject]@{ Available = $true; Valid = $false; Reason = 'invalid-codex-mcp-json'; Entries = @() }
        }
        foreach ($item in $parsed) {
            if ($item -isnot [hashtable] -or (-not $item.ContainsKey('name')) -or $item['name'] -isnot [string] -or (-not $item.ContainsKey('enabled')) -or $item['enabled'] -isnot [bool] -or (-not $item.ContainsKey('transport'))) {
                return [pscustomobject]@{ Available = $true; Valid = $false; Reason = 'invalid-codex-mcp-entry'; Entries = @() }
            }
        }
        return [pscustomobject]@{ Available = $true; Valid = $true; Reason = $null; Entries = @($parsed) }
    }
    catch {
        return [pscustomobject]@{ Available = $true; Valid = $false; Reason = 'invalid-codex-mcp-json'; Entries = @() }
    }
}

function Split-McpYamlLines {
    param([AllowEmptyString()] [string] $RawText)
    $lines = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($RawText)) {
        return $lines.ToArray()
    }
    $i = 0
    $len = $RawText.Length
    while ($i -lt $len) {
        $start = $i
        while ($i -lt $len -and $RawText[$i] -ne [char]"`r" -and $RawText[$i] -ne [char]"`n") {
            $i++
        }
        $content = $RawText.Substring($start, $i - $start)
        $eol = ''
        if ($i -lt $len) {
            if ($RawText[$i] -eq [char]"`r" -and ($i + 1) -lt $len -and $RawText[$i + 1] -eq [char]"`n") {
                $eol = "`r`n"
                $i += 2
            }
            else {
                $eol = [string]$RawText[$i]
                $i += 1
            }
        }
        $lines.Add([pscustomobject]@{
            Index   = $lines.Count
            Content = $content
            Eol     = $eol
        })
    }
    return $lines.ToArray()
}

function Get-McpYamlLineIndent {
    param([AllowEmptyString()] [string] $Line)
    $count = 0
    while ($count -lt $Line.Length) {
        $ch = $Line[$count]
        if ($ch -eq [char]' ') {
            $count++
            continue
        }
        if ($ch -eq [char]"`t") {
            throw 'Tab indentation is not allowed in YAML.'
        }
        break
    }
    return $count
}

function Split-McpYamlComment {
    param([AllowEmptyString()] [string] $Text)
    $inSingle = $false
    $inDouble = $false
    $len = $Text.Length
    for ($i = 0; $i -lt $len; $i++) {
        $ch = $Text[$i]
        if ($inSingle) {
            if ($ch -eq [char]"'") {
                if (($i + 1) -lt $len -and $Text[$i + 1] -eq [char]"'") {
                    $i++
                }
                else {
                    $inSingle = $false
                }
            }
            continue
        }
        if ($inDouble) {
            if ($ch -eq [char]'\') {
                $i++
            }
            elseif ($ch -eq [char]'"') {
                $inDouble = $false
            }
            continue
        }
        if ($ch -eq [char]"'") {
            $inSingle = $true
        }
        elseif ($ch -eq [char]'"') {
            $inDouble = $true
        }
        elseif ($ch -eq [char]'#' -and ($i -eq 0 -or $Text[$i - 1] -eq [char]' ' -or $Text[$i - 1] -eq [char]"`t")) {
            return [pscustomobject]@{
                Code          = $Text.Substring(0, $i)
                Comment       = $Text.Substring($i)
                UnclosedQuote = $false
            }
        }
    }
    return [pscustomobject]@{
        Code          = $Text
        Comment       = ''
        UnclosedQuote = ($inSingle -or $inDouble)
    }
}

function ConvertFrom-McpYamlScalar {
    param([AllowEmptyString()] [string] $Raw)
    $trimmed = $Raw.Trim()
    if ($trimmed.Length -eq 0) {
        return $null
    }
    if ($trimmed.StartsWith('"')) {
        if ($trimmed.Length -lt 2) {
            throw 'Unterminated YAML double-quoted scalar.'
        }
        $sb = [System.Text.StringBuilder]::new()
        $closed = $false
        $i = 1
        while ($i -lt $trimmed.Length) {
            $ch = $trimmed[$i]
            if ($ch -eq [char]'"') {
                $closed = $true
                $i++
                break
            }
            if ($ch -eq [char]'\') {
                $i++
                if ($i -ge $trimmed.Length) {
                    throw 'Trailing backslash in YAML double-quoted scalar.'
                }
                $esc = $trimmed[$i]
                switch ($esc) {
                    '"'  { [void]$sb.Append('"') }
                    '\'  { [void]$sb.Append('\') }
                    '/'  { [void]$sb.Append('/') }
                    'n'  { [void]$sb.Append("`n") }
                    'r'  { [void]$sb.Append("`r") }
                    't'  { [void]$sb.Append("`t") }
                    '0'  { [void]$sb.Append([char]0) }
                    'a'  { [void]$sb.Append([char]7) }
                    'b'  { [void]$sb.Append([char]8) }
                    'e'  { [void]$sb.Append([char]27) }
                    'f'  { [void]$sb.Append([char]12) }
                    'v'  { [void]$sb.Append([char]11) }
                    ' '  { [void]$sb.Append(' ') }
                    'x' {
                        if ($i + 2 -ge $trimmed.Length) { throw 'Invalid \x escape in YAML scalar.' }
                        $hex = $trimmed.Substring($i + 1, 2)
                        [void]$sb.Append([char][Convert]::ToInt32($hex, 16))
                        $i += 2
                    }
                    'u' {
                        if ($i + 4 -ge $trimmed.Length) { throw 'Invalid \u escape in YAML scalar.' }
                        $hex = $trimmed.Substring($i + 1, 4)
                        [void]$sb.Append([char][Convert]::ToInt32($hex, 16))
                        $i += 4
                    }
                    'U' {
                        if ($i + 8 -ge $trimmed.Length) { throw 'Invalid \U escape in YAML scalar.' }
                        $hex = $trimmed.Substring($i + 1, 8)
                        [void]$sb.Append([char]::ConvertFromUtf32([Convert]::ToInt32($hex, 16)))
                        $i += 8
                    }
                    default { throw "Unsupported YAML escape '\$esc'." }
                }
                $i++
                continue
            }
            [void]$sb.Append($ch)
            $i++
        }
        if (-not $closed -or $i -ne $trimmed.Length) {
            throw 'Invalid YAML double-quoted scalar.'
        }
        return $sb.ToString()
    }
    if ($trimmed.StartsWith("'")) {
        if ($trimmed.Length -lt 2) {
            throw 'Unterminated YAML single-quoted scalar.'
        }
        $sb = [System.Text.StringBuilder]::new()
        $closed = $false
        $i = 1
        while ($i -lt $trimmed.Length) {
            $ch = $trimmed[$i]
            if ($ch -eq [char]"'") {
                if (($i + 1) -lt $trimmed.Length -and $trimmed[$i + 1] -eq [char]"'") {
                    [void]$sb.Append("'")
                    $i += 2
                    continue
                }
                $closed = $true
                $i++
                break
            }
            [void]$sb.Append($ch)
            $i++
        }
        if (-not $closed -or $i -ne $trimmed.Length) {
            throw 'Invalid YAML single-quoted scalar.'
        }
        return $sb.ToString()
    }
    if ($trimmed -ceq '~' -or $trimmed -cmatch '^(?:null|Null|NULL)$') {
        return $null
    }
    if ($trimmed -cmatch '^(?:true|True|TRUE|yes|Yes|YES|on|On|ON)$') {
        return $true
    }
    if ($trimmed -cmatch '^(?:false|False|FALSE|no|No|NO|off|Off|OFF)$') {
        return $false
    }
    if ($trimmed -cmatch '^-?[0-9]+$') {
        $longVal = [long]0
        if ([long]::TryParse($trimmed, [ref]$longVal)) {
            return $longVal
        }
    }
    if ($trimmed -cmatch '^-?[0-9]+\.[0-9]+$') {
        $dblVal = [double]0
        if ([double]::TryParse($trimmed, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dblVal)) {
            return $dblVal
        }
    }
    return [string]$trimmed
}

function Find-McpYamlKeyValueSplit {
    param([Parameter(Mandatory)] [string] $Text)
    $inSingle = $false
    $inDouble = $false
    $justClosedQuote = $false
    $len = $Text.Length
    for ($i = 0; $i -lt $len; $i++) {
        $ch = $Text[$i]
        if ($inSingle) {
            if ($ch -eq [char]"'") {
                if (($i + 1) -lt $len -and $Text[$i + 1] -eq [char]"'") {
                    $i++
                }
                else {
                    $inSingle = $false
                    $justClosedQuote = $true
                }
            }
            continue
        }
        if ($inDouble) {
            if ($ch -eq [char]'\') {
                $i++
            }
            elseif ($ch -eq [char]'"') {
                $inDouble = $false
                $justClosedQuote = $true
            }
            continue
        }
        if ($ch -eq [char]"'") {
            $inSingle = $true
            $justClosedQuote = $false
            continue
        }
        if ($ch -eq [char]'"') {
            $inDouble = $true
            $justClosedQuote = $false
            continue
        }
        if ($ch -eq [char]':') {
            $atEnd = ($i + 1 -eq $len)
            $nextWs = (-not $atEnd) -and ($Text[$i + 1] -eq [char]' ' -or $Text[$i + 1] -eq [char]"`t")
            if ($atEnd -or $nextWs -or $justClosedQuote) {
                $keyRaw = $Text.Substring(0, $i).Trim()
                if ([string]::IsNullOrEmpty($keyRaw)) {
                    throw 'Empty YAML mapping key.'
                }
                if ((-not $keyRaw.StartsWith('"')) -and (-not $keyRaw.StartsWith("'")) -and $keyRaw -match '[\[\]\{\},]') {
                    throw 'Invalid characters in unquoted YAML key.'
                }
                $key = [string](ConvertFrom-McpYamlScalar -Raw $keyRaw)
                if ([string]::IsNullOrEmpty($key)) {
                    throw 'YAML mapping key cannot be null or empty.'
                }
                return [pscustomobject]@{
                    Found    = $true
                    Key      = $key
                    ValueRaw = $Text.Substring($i + 1)
                }
            }
        }
        if ($ch -ne [char]' ' -and $ch -ne [char]"`t") {
            $justClosedQuote = $false
        }
    }
    return [pscustomobject]@{
        Found    = $false
        Key      = $null
        ValueRaw = $null
    }
}

function Read-McpYamlFlowText {
    param(
        [Parameter(Mandatory)] [object[]] $Lines,
        [Parameter(Mandatory)] [int] $StartLineIndex,
        [Parameter(Mandatory)] [string] $InitialText
    )
    $sb = [System.Text.StringBuilder]::new()
    $inSingle = $false
    $inDouble = $false
    $depth = 0
    $lineIdx = $StartLineIndex
    $fragment = $InitialText.TrimStart()
    $openChar = $fragment[0]
    $closeChar = if ($openChar -eq [char]'[') { [char]']' } else { [char]'}' }

    while ($true) {
        if ($lineIdx -gt $StartLineIndex) {
            $null = Get-McpYamlLineIndent -Line $Lines[$lineIdx].Content
            $fragment = $Lines[$lineIdx].Content
        }
        $len = $fragment.Length
        for ($i = 0; $i -lt $len; $i++) {
            $ch = $fragment[$i]
            if ($inSingle) {
                [void]$sb.Append($ch)
                if ($ch -eq [char]"'") {
                    if (($i + 1) -lt $len -and $fragment[$i + 1] -eq [char]"'") {
                        [void]$sb.Append("'")
                        $i++
                    }
                    else {
                        $inSingle = $false
                    }
                }
                continue
            }
            if ($inDouble) {
                [void]$sb.Append($ch)
                if ($ch -eq [char]'\') {
                    if (($i + 1) -lt $len) {
                        $i++
                        [void]$sb.Append($fragment[$i])
                    }
                }
                elseif ($ch -eq [char]'"') {
                    $inDouble = $false
                }
                continue
            }
            if ($ch -eq [char]"'") {
                $inSingle = $true
                [void]$sb.Append($ch)
                continue
            }
            if ($ch -eq [char]'"') {
                $inDouble = $true
                [void]$sb.Append($ch)
                continue
            }
            if ($ch -eq [char]'#' -and ($i -eq 0 -or $fragment[$i - 1] -eq [char]' ' -or $fragment[$i - 1] -eq [char]"`t")) {
                break
            }
            [void]$sb.Append($ch)
            if ($ch -eq $openChar) {
                $depth++
            }
            elseif ($ch -eq $closeChar) {
                $depth--
                if ($depth -eq 0) {
                    $tail = $fragment.Substring($i + 1)
                    $tailSplit = Split-McpYamlComment -Text $tail
                    if (-not [string]::IsNullOrWhiteSpace($tailSplit.Code)) {
                        throw 'Unexpected trailing content after YAML flow collection.'
                    }
                    return [pscustomobject]@{
                        FlowText      = $sb.ToString()
                        LastLineIndex = $lineIdx
                        NextIndex     = ($lineIdx + 1)
                    }
                }
            }
        }
        [void]$sb.Append(' ')
        $lineIdx++
        if ($lineIdx -ge $Lines.Count) {
            throw 'Unterminated YAML flow collection.'
        }
    }
}

function Split-McpYamlFlowItems {
    param([AllowEmptyString()] [string] $InnerText)
    $items = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($InnerText)) {
        return $items.ToArray()
    }
    $inSingle = $false
    $inDouble = $false
    $bracketDepth = 0
    $braceDepth = 0
    $start = 0
    $len = $InnerText.Length
    for ($i = 0; $i -lt $len; $i++) {
        $ch = $InnerText[$i]
        if ($inSingle) {
            if ($ch -eq [char]"'") {
                if (($i + 1) -lt $len -and $InnerText[$i + 1] -eq [char]"'") {
                    $i++
                }
                else {
                    $inSingle = $false
                }
            }
            continue
        }
        if ($inDouble) {
            if ($ch -eq [char]'\') {
                $i++
            }
            elseif ($ch -eq [char]'"') {
                $inDouble = $false
            }
            continue
        }
        if ($ch -eq [char]"'") { $inSingle = $true; continue }
        if ($ch -eq [char]'"') { $inDouble = $true; continue }
        if ($ch -eq [char]'[') { $bracketDepth++; continue }
        if ($ch -eq [char]']') { $bracketDepth--; continue }
        if ($ch -eq [char]'{') { $braceDepth++; continue }
        if ($ch -eq [char]'}') { $braceDepth--; continue }
        if ($ch -eq [char]',' -and $bracketDepth -eq 0 -and $braceDepth -eq 0) {
            $token = $InnerText.Substring($start, $i - $start).Trim()
            if ([string]::IsNullOrEmpty($token)) {
                throw 'Empty element in YAML flow collection.'
            }
            $items.Add($token)
            $start = $i + 1
        }
    }
    if ($inSingle -or $inDouble -or $bracketDepth -ne 0 -or $braceDepth -ne 0) {
        throw 'Malformed YAML flow collection.'
    }
    $last = $InnerText.Substring($start).Trim()
    if ([string]::IsNullOrEmpty($last)) {
        throw 'Trailing comma or empty element in YAML flow collection.'
    }
    $items.Add($last)
    return $items.ToArray()
}

function ConvertFrom-McpYamlFlowNode {
    param([Parameter(Mandatory)] [string] $Token)
    $trimmed = $Token.Trim()
    if ($trimmed.StartsWith('[')) {
        return , @(ConvertFrom-McpYamlFlowSequence -Text $trimmed)
    }
    if ($trimmed.StartsWith('{')) {
        return (ConvertFrom-McpYamlFlowMapping -Text $trimmed)
    }
    return (ConvertFrom-McpYamlScalar -Raw $trimmed)
}

function ConvertFrom-McpYamlFlowSequence {
    param([Parameter(Mandatory)] [string] $Text)
    $trimmed = $Text.Trim()
    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        throw 'Invalid YAML flow sequence.'
    }
    $inner = $trimmed.Substring(1, $trimmed.Length - 2)
    $tokens = @(Split-McpYamlFlowItems -InnerText $inner)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($tok in $tokens) {
        $result.Add((ConvertFrom-McpYamlFlowNode -Token $tok))
    }
    return $result.ToArray()
}

function ConvertFrom-McpYamlFlowMapping {
    param([Parameter(Mandatory)] [string] $Text)
    $trimmed = $Text.Trim()
    if (-not ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}'))) {
        throw 'Invalid YAML flow mapping.'
    }
    $inner = $trimmed.Substring(1, $trimmed.Length - 2)
    $tokens = @(Split-McpYamlFlowItems -InnerText $inner)
    $map = [ordered]@{}
    foreach ($tok in $tokens) {
        $kv = Find-McpYamlKeyValueSplit -Text $tok
        if (-not $kv.Found) {
            throw 'Expected key: value inside YAML flow mapping.'
        }
        if ($map.Contains($kv.Key)) {
            throw "Duplicate YAML key '$($kv.Key)' in flow mapping."
        }
        $valTrimmed = $kv.ValueRaw.Trim()
        $map[$kv.Key] = if ($valTrimmed -eq '') { $null } else { ConvertFrom-McpYamlFlowNode -Token $valTrimmed }
    }
    return $map
}

function Read-McpYamlBlockScalar {
    param(
        [Parameter(Mandatory)] [object[]] $Lines,
        [Parameter(Mandatory)] [int] $HeaderLineIndex,
        [Parameter(Mandatory)] [string] $HeaderValue,
        [Parameter(Mandatory)] [int] $ParentIndent
    )
    $trimmed = $HeaderValue.Trim()
    if ($trimmed -cnotmatch '^(\||>)([+-]?)([1-9]?)([+-]?)$') {
        throw "Invalid YAML block scalar header '$trimmed'."
    }
    $style = $Matches[1]
    $chomp1 = $Matches[2]
    $digit = $Matches[3]
    $chomp2 = $Matches[4]
    if ($chomp1 -and $chomp2) {
        throw "Invalid YAML block scalar chomping '$trimmed'."
    }
    $chomp = if ($chomp1) { $chomp1 } elseif ($chomp2) { $chomp2 } else { '' }
    $explicitIndent = if ($digit) { [int]$digit } else { 0 }

    $contentIndent = -1
    $collected = [System.Collections.Generic.List[string]]::new()
    $lastContentLine = $HeaderLineIndex
    $j = $HeaderLineIndex + 1

    while ($j -lt $Lines.Count) {
        $rawLine = $Lines[$j].Content
        $spaceCount = 0
        while ($spaceCount -lt $rawLine.Length -and $rawLine[$spaceCount] -eq [char]' ') {
            $spaceCount++
        }
        $isBlank = ([string]::IsNullOrWhiteSpace($rawLine))
        if ($isBlank) {
            if ($rawLine.Contains("`t") -and ($contentIndent -eq -1 -or $spaceCount -lt $contentIndent)) {
                throw 'Tab indentation is not allowed in YAML.'
            }
            $collected.Add('')
            $j++
            continue
        }
        if ($spaceCount -lt $rawLine.Length -and $rawLine[$spaceCount] -eq [char]"`t") {
            if ($contentIndent -eq -1 -or $spaceCount -lt $contentIndent) {
                throw 'Tab indentation is not allowed in YAML.'
            }
        }
        if ($spaceCount -le $ParentIndent) {
            break
        }
        if ($contentIndent -eq -1) {
            $contentIndent = if ($explicitIndent -gt 0) { $ParentIndent + $explicitIndent } else { $spaceCount }
            if ($spaceCount -lt $contentIndent) {
                throw 'Invalid YAML block scalar indentation.'
            }
        }
        elseif ($spaceCount -lt $contentIndent) {
            throw 'Invalid YAML block scalar indentation.'
        }
        $collected.Add($rawLine.Substring($contentIndent))
        $lastContentLine = $j
        $j++
    }

    if ($lastContentLine -eq $HeaderLineIndex) {
        return [pscustomobject]@{
            Value         = ''
            LastLineIndex = $HeaderLineIndex
            NextIndex     = $j
        }
    }

    $nonBlankEnd = $collected.Count - 1
    while ($nonBlankEnd -ge 0 -and $collected[$nonBlankEnd] -eq '' -and $nonBlankEnd -ge ($lastContentLine - $HeaderLineIndex)) {
        $nonBlankEnd--
    }
    $bodyLines = if ($chomp -eq '+') {
        @($collected)
    }
    else {
        $endIdx = $lastContentLine - $HeaderLineIndex - 1
        if ($endIdx -ge 0) { @($collected[0..$endIdx]) } else { @() }
    }
    $joined = if ($style -eq '|') {
        $bodyLines -join "`n"
    }
    else {
        ($bodyLines -join ' ').TrimEnd()
    }
    if ($chomp -eq '' -and $joined.Length -gt 0) {
        $joined += "`n"
    }
    return [pscustomobject]@{
        Value         = $joined
        LastLineIndex = $lastContentLine
        NextIndex     = $j
    }
}

function Find-McpYamlNextContentLine {
    param(
        [Parameter(Mandatory)] [object[]] $Lines,
        [Parameter(Mandatory)] [int] $StartIndex
    )
    $i = $StartIndex
    while ($i -lt $Lines.Count) {
        $line = $Lines[$i].Content
        $indent = Get-McpYamlLineIndent -Line $line
        if ($indent -ge $line.Length) {
            $i++
            continue
        }
        if ($line[$indent] -eq [char]'#') {
            $i++
            continue
        }
        return $i
    }
    return $Lines.Count
}

function Read-McpYamlSequence {
    param(
        [Parameter(Mandatory)] [object[]] $Lines,
        [Parameter(Mandatory)] [int] $StartIndex,
        [Parameter(Mandatory)] [int] $ExpectedIndent
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $lastLine = $StartIndex - 1
    $i = $StartIndex
    while ($i -lt $Lines.Count) {
        $i = Find-McpYamlNextContentLine -Lines $Lines -StartIndex $i
        if ($i -ge $Lines.Count) { break }
        $indent = Get-McpYamlLineIndent -Line $Lines[$i].Content
        if ($indent -lt $ExpectedIndent) { break }
        if ($indent -gt $ExpectedIndent) {
            throw 'Unexpected indentation in YAML sequence.'
        }
        $body = $Lines[$i].Content.Substring($indent)
        if ($body -cnotmatch '^-(?:\s|$)') {
            break
        }
        $afterDash = if ($body.Length -gt 1) { $body.Substring(1) } else { '' }
        $split = Split-McpYamlComment -Text $afterDash
        if ($split.UnclosedQuote) {
            throw 'Unterminated quote in YAML sequence item.'
        }
        $valRes = Read-McpYamlValue -Lines $Lines -InlineText $split.Code -LineIndex $i -ParentIndent $ExpectedIndent
        $items.Add($valRes.Value)
        $lastLine = $valRes.LastLineIndex
        $i = $valRes.NextIndex
    }
    return [pscustomobject]@{
        Value         = $items.ToArray()
        LastLineIndex = $lastLine
        NextIndex     = $i
    }
}

function Read-McpYamlMapping {
    param(
        [Parameter(Mandatory)] [object[]] $Lines,
        [Parameter(Mandatory)] [int] $StartIndex,
        [Parameter(Mandatory)] [int] $ExpectedIndent
    )
    $map = [ordered]@{}
    $lastLine = $StartIndex - 1
    $i = $StartIndex
    while ($i -lt $Lines.Count) {
        $i = Find-McpYamlNextContentLine -Lines $Lines -StartIndex $i
        if ($i -ge $Lines.Count) { break }
        $indent = Get-McpYamlLineIndent -Line $Lines[$i].Content
        if ($indent -lt $ExpectedIndent) { break }
        if ($indent -gt $ExpectedIndent) {
            throw 'Unexpected indentation in YAML mapping.'
        }
        $body = $Lines[$i].Content.Substring($indent)
        if ($body -cmatch '^-(?:\s|$)') {
            throw 'Unexpected YAML sequence item inside mapping.'
        }
        $split = Split-McpYamlComment -Text $body
        if ($split.UnclosedQuote) {
            throw 'Unterminated quote in YAML mapping entry.'
        }
        $kv = Find-McpYamlKeyValueSplit -Text $split.Code
        if (-not $kv.Found) {
            throw 'Expected key: value in YAML mapping.'
        }
        if ($map.Contains($kv.Key)) {
            throw "Duplicate YAML key '$($kv.Key)'."
        }
        $valRes = Read-McpYamlValue -Lines $Lines -InlineText $kv.ValueRaw -LineIndex $i -ParentIndent $ExpectedIndent
        $map[$kv.Key] = $valRes.Value
        $lastLine = $valRes.LastLineIndex
        $i = $valRes.NextIndex
    }
    return [pscustomobject]@{
        Value         = $map
        LastLineIndex = $lastLine
        NextIndex     = $i
    }
}

function Read-McpYamlValue {
    param(
        [Parameter(Mandatory)] [object[]] $Lines,
        [AllowEmptyString()] [string] $InlineText,
        [Parameter(Mandatory)] [int] $LineIndex,
        [Parameter(Mandatory)] [int] $ParentIndent
    )
    $trimmed = $InlineText.Trim()
    if ($trimmed -cmatch '^(\||>)') {
        return (Read-McpYamlBlockScalar -Lines $Lines -HeaderLineIndex $LineIndex -HeaderValue $trimmed -ParentIndent $ParentIndent)
    }
    if ($trimmed.StartsWith('[')) {
        $flowRes = Read-McpYamlFlowText -Lines $Lines -StartLineIndex $LineIndex -InitialText $trimmed
        return [pscustomobject]@{
            Value         = @(ConvertFrom-McpYamlFlowSequence -Text $flowRes.FlowText)
            LastLineIndex = $flowRes.LastLineIndex
            NextIndex     = $flowRes.NextIndex
        }
    }
    if ($trimmed.StartsWith('{')) {
        $flowRes = Read-McpYamlFlowText -Lines $Lines -StartLineIndex $LineIndex -InitialText $trimmed
        return [pscustomobject]@{
            Value         = (ConvertFrom-McpYamlFlowMapping -Text $flowRes.FlowText)
            LastLineIndex = $flowRes.LastLineIndex
            NextIndex     = $flowRes.NextIndex
        }
    }
    if ($trimmed -ne '') {
        return [pscustomobject]@{
            Value         = (ConvertFrom-McpYamlScalar -Raw $trimmed)
            LastLineIndex = $LineIndex
            NextIndex     = ($LineIndex + 1)
        }
    }

    $nextIdx = Find-McpYamlNextContentLine -Lines $Lines -StartIndex ($LineIndex + 1)
    if ($nextIdx -ge $Lines.Count) {
        return [pscustomobject]@{ Value = $null; LastLineIndex = $LineIndex; NextIndex = $nextIdx }
    }
    $nextIndent = Get-McpYamlLineIndent -Line $Lines[$nextIdx].Content
    if ($nextIndent -lt $ParentIndent) {
        return [pscustomobject]@{ Value = $null; LastLineIndex = $LineIndex; NextIndex = $nextIdx }
    }
    $nextBody = $Lines[$nextIdx].Content.Substring($nextIndent)
    if ($nextIndent -eq $ParentIndent) {
        if ($nextBody -cmatch '^-(?:\s|$)') {
            return (Read-McpYamlSequence -Lines $Lines -StartIndex $nextIdx -ExpectedIndent $nextIndent)
        }
        return [pscustomobject]@{ Value = $null; LastLineIndex = $LineIndex; NextIndex = $nextIdx }
    }
    if ($nextBody -cmatch '^-(?:\s|$)') {
        return (Read-McpYamlSequence -Lines $Lines -StartIndex $nextIdx -ExpectedIndent $nextIndent)
    }
    return (Read-McpYamlMapping -Lines $Lines -StartIndex $nextIdx -ExpectedIndent $nextIndent)
}

function Skip-McpYamlSubtree {
    param(
        [Parameter(Mandatory)] [object[]] $Lines,
        [Parameter(Mandatory)] [int] $StartIndex,
        [AllowEmptyString()] [string] $InlineText
    )
    $trimmed = $InlineText.Trim()
    if ($trimmed -cmatch '^(\||>)') {
        $blk = Read-McpYamlBlockScalar -Lines $Lines -HeaderLineIndex ($StartIndex - 1) -HeaderValue $trimmed -ParentIndent 0
        return $blk.NextIndex
    }
    if ($trimmed.StartsWith('[') -or $trimmed.StartsWith('{')) {
        $flow = Read-McpYamlFlowText -Lines $Lines -StartLineIndex ($StartIndex - 1) -InitialText $trimmed
        return $flow.NextIndex
    }
    $i = $StartIndex
    while ($i -lt $Lines.Count) {
        $i = Find-McpYamlNextContentLine -Lines $Lines -StartIndex $i
        if ($i -ge $Lines.Count) { break }
        $indent = Get-McpYamlLineIndent -Line $Lines[$i].Content
        $body = $Lines[$i].Content.Substring($indent)
        if ($indent -eq 0 -and ($body -cnotmatch '^-(?:\s|$)')) {
            break
        }
        $split = Split-McpYamlComment -Text $body
        if ($split.UnclosedQuote) {
            throw 'Unterminated quote in YAML document.'
        }
        $kv = Find-McpYamlKeyValueSplit -Text $split.Code
        if ($kv.Found) {
            $valTrimmed = $kv.ValueRaw.Trim()
            if ($valTrimmed -cmatch '^(\||>)') {
                $blk = Read-McpYamlBlockScalar -Lines $Lines -HeaderLineIndex $i -HeaderValue $valTrimmed -ParentIndent $indent
                $i = $blk.NextIndex
                continue
            }
            if ($valTrimmed.StartsWith('[') -or $valTrimmed.StartsWith('{')) {
                $flow = Read-McpYamlFlowText -Lines $Lines -StartLineIndex $i -InitialText $valTrimmed
                $i = $flow.NextIndex
                continue
            }
        }
        elseif ($body -cmatch '^-(?:\s|$)') {
            $afterDash = if ($body.Length -gt 1) { $body.Substring(1).Trim() } else { '' }
            if ($afterDash -cmatch '^(\||>)') {
                $blk = Read-McpYamlBlockScalar -Lines $Lines -HeaderLineIndex $i -HeaderValue $afterDash -ParentIndent $indent
                $i = $blk.NextIndex
                continue
            }
        }
        $i++
    }
    return $i
}

function Read-McpHermesConfigState {
    param([Parameter(Mandatory)] [string] $HomeRoot)

    $hermesDir = Join-Path $HomeRoot 'AppData\Local\hermes'
    $configPath = Join-Path $hermesDir 'config.yaml'

    $newBlockedState = {
        param([string] $Reason, [bool] $Exists = $false)
        return [pscustomobject]@{
            Dir                = $hermesDir
            Path               = $configPath
            Exists             = $Exists
            Installed          = $true
            Valid              = $false
            Reason             = $Reason
            NewLine            = "`n"
            RawText            = $null
            Lines              = @()
            HasMcpServers      = $false
            McpHeaderLineIndex = -1
            McpBlockEndIndex   = -1
            McpEmptyInline     = $false
            ServerIndent       = 2
            Entries            = [ordered]@{}
            EntrySpans         = @{}
        }
    }

    if (-not [string]::IsNullOrEmpty($env:HERMES_DATA_DIR_SUFFIX)) {
        return (& $newBlockedState 'hermes-home-override-unsupported' $false)
    }
    if (-not [string]::IsNullOrEmpty($env:HERMES_HOME)) {
        $normOverride = $null
        $normDefault = $null
        try {
            $normDefault = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($hermesDir))
            $normOverride = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($env:HERMES_HOME))
        }
        catch {
            $normOverride = $null
        }
        if ($null -eq $normOverride -or ($normOverride -ine $normDefault)) {
            return (& $newBlockedState 'hermes-home-override-unsupported' $false)
        }
    }

    try {
        Assert-PlainPathNoReparse -Path $configPath -AllowMissing -MessagePrefix 'MCP target path cannot contain reparse points'
    }
    catch {
        return (& $newBlockedState 'reparse-point-blocked' $false)
    }

    if (Test-Path -LiteralPath $hermesDir -PathType Leaf) {
        return (& $newBlockedState 'hermes-dir-not-directory' $false)
    }
    if (-not (Test-Path -LiteralPath $hermesDir -PathType Container)) {
        return [pscustomobject]@{
            Dir                = $hermesDir
            Path               = $configPath
            Exists             = $false
            Installed          = $false
            Valid              = $true
            Reason             = 'hermes-not-installed'
            NewLine            = "`n"
            RawText            = ''
            Lines              = @()
            HasMcpServers      = $false
            McpHeaderLineIndex = -1
            McpBlockEndIndex   = -1
            McpEmptyInline     = $false
            ServerIndent       = 2
            Entries            = [ordered]@{}
            EntrySpans         = @{}
        }
    }

    $activeProfilePath = Join-Path $hermesDir 'active_profile'
    try {
        Assert-PlainPathNoReparse -Path $activeProfilePath -AllowMissing -MessagePrefix 'MCP target path cannot contain reparse points'
    }
    catch {
        return (& $newBlockedState 'reparse-point-blocked' $false)
    }
    if (Test-Path -LiteralPath $activeProfilePath -PathType Container) {
        return (& $newBlockedState 'hermes-active-profile-invalid' $false)
    }
    if (Test-Path -LiteralPath $activeProfilePath -PathType Leaf) {
        $profileName = ([IO.File]::ReadAllText($activeProfilePath)).Trim()
        if (-not [string]::IsNullOrEmpty($profileName) -and $profileName -ine 'default') {
            return (& $newBlockedState 'hermes-non-default-profile-unsupported' $false)
        }
    }

    if (Test-Path -LiteralPath $configPath -PathType Container) {
        return (& $newBlockedState 'target-is-directory' $true)
    }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return [pscustomobject]@{
            Dir                = $hermesDir
            Path               = $configPath
            Exists             = $false
            Installed          = $true
            Valid              = $true
            Reason             = $null
            NewLine            = "`n"
            RawText            = ''
            Lines              = @()
            HasMcpServers      = $false
            McpHeaderLineIndex = -1
            McpBlockEndIndex   = -1
            McpEmptyInline     = $false
            ServerIndent       = 2
            Entries            = [ordered]@{}
            EntrySpans         = @{}
        }
    }

    $raw = [IO.File]::ReadAllText($configPath)
    $newLine = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @(Split-McpYamlLines -RawText $raw)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            Dir                = $hermesDir
            Path               = $configPath
            Exists             = $true
            Installed          = $true
            Valid              = $true
            Reason             = $null
            NewLine            = $newLine
            RawText            = $raw
            Lines              = $lines
            HasMcpServers      = $false
            McpHeaderLineIndex = -1
            McpBlockEndIndex   = -1
            McpEmptyInline     = $false
            ServerIndent       = 2
            Entries            = [ordered]@{}
            EntrySpans         = @{}
        }
    }

    try {
        $seenTopContent = $false
        $hasMcpServers = $false
        $mcpHeaderLineIndex = -1
        $mcpBlockEndIndex = -1
        $mcpEmptyInline = $false
        $serverIndent = 2
        $entries = [ordered]@{}
        $entrySpans = @{}
        $i = 0

        while ($i -lt $lines.Count) {
            $i = Find-McpYamlNextContentLine -Lines $lines -StartIndex $i
            if ($i -ge $lines.Count) { break }
            $indent = Get-McpYamlLineIndent -Line $lines[$i].Content
            if ($indent -ne 0) {
                throw 'Unexpected top-level indentation in YAML.'
            }
            $body = $lines[$i].Content
            $split = Split-McpYamlComment -Text $body
            if ($split.UnclosedQuote) {
                throw 'Unterminated quote in YAML.'
            }
            $trimmedCode = $split.Code.Trim()
            if ($trimmedCode -ceq '---') {
                if ($seenTopContent) {
                    throw 'Multi-document YAML is not supported.'
                }
                $i++
                continue
            }
            if ($trimmedCode -ceq '...') {
                $afterEnd = Find-McpYamlNextContentLine -Lines $lines -StartIndex ($i + 1)
                if ($afterEnd -lt $lines.Count) {
                    throw 'Trailing content after YAML document end marker is not supported.'
                }
                break
            }
            $seenTopContent = $true
            if ($trimmedCode -cmatch '^-(?:\s|$)') {
                throw 'Expected top-level YAML mapping.'
            }
            $kv = Find-McpYamlKeyValueSplit -Text $split.Code
            if (-not $kv.Found) {
                throw 'Expected top-level key: value in YAML.'
            }

            if ($kv.Key -ceq 'mcp_servers') {
                if ($hasMcpServers) {
                    throw 'Duplicate top-level mcp_servers key.'
                }
                $hasMcpServers = $true
                $mcpHeaderLineIndex = $i
                $mcpBlockEndIndex = $i
                $valTrimmed = $kv.ValueRaw.Trim()
                if ($valTrimmed -cmatch '^(\||>)' -or $valTrimmed.StartsWith('[')) {
                    throw 'mcp_servers must be a YAML mapping.'
                }
                if ($valTrimmed.StartsWith('{')) {
                    $flowRes = Read-McpYamlFlowText -Lines $lines -StartLineIndex $i -InitialText $valTrimmed
                    $flowMap = ConvertFrom-McpYamlFlowMapping -Text $flowRes.FlowText
                    if ($flowMap.Count -gt 0) {
                        throw 'Non-empty inline flow mapping on top-level mcp_servers is not supported.'
                    }
                    $mcpEmptyInline = $true
                    $i = $flowRes.NextIndex
                    $nextAfterFlow = Find-McpYamlNextContentLine -Lines $lines -StartIndex $i
                    if ($nextAfterFlow -lt $lines.Count -and (Get-McpYamlLineIndent -Line $lines[$nextAfterFlow].Content) -gt 0) {
                        throw 'Unexpected indented children under inline mcp_servers: {}.'
                    }
                    continue
                }
                if ($valTrimmed -ne '') {
                    throw 'mcp_servers must be a YAML mapping, not a scalar.'
                }

                $detectedIndent = -1
                $j = $i + 1
                while ($j -lt $lines.Count) {
                    $j = Find-McpYamlNextContentLine -Lines $lines -StartIndex $j
                    if ($j -ge $lines.Count) { break }
                    $srvIndent = Get-McpYamlLineIndent -Line $lines[$j].Content
                    $srvBody = $lines[$j].Content.Substring($srvIndent)
                    if ($srvIndent -eq 0) {
                        if ($srvBody -cmatch '^-(?:\s|$)') {
                            throw 'mcp_servers must be a YAML mapping, not a sequence.'
                        }
                        break
                    }
                    if ($detectedIndent -eq -1) {
                        if ($srvBody -cmatch '^-(?:\s|$)') {
                            throw 'mcp_servers must be a YAML mapping, not a sequence.'
                        }
                        $detectedIndent = $srvIndent
                        $serverIndent = $srvIndent
                    }
                    elseif ($srvIndent -ne $detectedIndent) {
                        throw 'Inconsistent server indentation under mcp_servers.'
                    }
                    if ($srvBody -cmatch '^-(?:\s|$)') {
                        throw 'Unexpected sequence item under mcp_servers.'
                    }
                    $srvSplit = Split-McpYamlComment -Text $srvBody
                    if ($srvSplit.UnclosedQuote) {
                        throw 'Unterminated quote in mcp_servers entry.'
                    }
                    $srvKv = Find-McpYamlKeyValueSplit -Text $srvSplit.Code
                    if (-not $srvKv.Found) {
                        throw 'Expected server_name: mapping under mcp_servers.'
                    }
                    $srvName = $srvKv.Key
                    if ($entries.Contains($srvName)) {
                        throw "Duplicate server '$srvName' under mcp_servers."
                    }
                    $srvStart = $j
                    $srvValRes = Read-McpYamlValue -Lines $lines -InlineText $srvKv.ValueRaw -LineIndex $j -ParentIndent $detectedIndent
                    $srvVal = $srvValRes.Value
                    if ($null -eq $srvVal) {
                        $srvVal = [ordered]@{}
                    }
                    $entries[$srvName] = $srvVal
                    $entrySpans[$srvName] = [pscustomobject]@{
                        StartIndex = $srvStart
                        EndIndex   = $srvValRes.LastLineIndex
                    }
                    $mcpBlockEndIndex = $srvValRes.LastLineIndex
                    $j = $srvValRes.NextIndex
                }
                $i = $j
                continue
            }

            $i = Skip-McpYamlSubtree -Lines $lines -StartIndex ($i + 1) -InlineText $kv.ValueRaw
        }

        return [pscustomobject]@{
            Dir                = $hermesDir
            Path               = $configPath
            Exists             = $true
            Installed          = $true
            Valid              = $true
            Reason             = $null
            NewLine            = $newLine
            RawText            = $raw
            Lines              = $lines
            HasMcpServers      = $hasMcpServers
            McpHeaderLineIndex = $mcpHeaderLineIndex
            McpBlockEndIndex   = $mcpBlockEndIndex
            McpEmptyInline     = $mcpEmptyInline
            ServerIndent       = $serverIndent
            Entries            = $entries
            EntrySpans         = $entrySpans
        }
    }
    catch {
        return (& $newBlockedState 'invalid-yaml-or-duplicate-key' $true)
    }
}

function Get-McpExpectedHermesPayload {
    param([Parameter(Mandatory)] [object] $Server)
    if ($Server.Transport -ceq 'stdio') {
        $payload = [ordered]@{
            command = [string]$Server.Command
            args    = [string[]]@($Server.Args | ForEach-Object { [string]$_ })
        }
        if ($Server.Env.Count -gt 0) {
            $envCopy = [ordered]@{}
            foreach ($k in $Server.Env.Keys) { $envCopy[$k] = $Server.Env[$k] }
            $payload['env'] = $envCopy
        }
        $payload['enabled'] = [bool]$Server.Enabled
        return [pscustomobject]@{ Supported = $true; Reason = $null; Payload = $payload }
    }
    else {
        $payload = [ordered]@{ url = [string]$Server.Url }
        $headers = [ordered]@{}
        foreach ($k in $Server.Headers.Keys) { $headers[$k] = $Server.Headers[$k] }
        if ($Server.PSObject.Properties['BearerTokenEnvVar'] -and (-not $headers.Contains('Authorization'))) {
            $headers['Authorization'] = ('Bearer ${' + $Server.BearerTokenEnvVar + '}')
        }
        if ($headers.Count -gt 0) { $payload['headers'] = $headers }
        $payload['enabled'] = [bool]$Server.Enabled
        return [pscustomobject]@{ Supported = $true; Reason = $null; Payload = $payload }
    }
}

function ConvertFrom-McpHermesLiveEntry {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Entry)
    $out = [ordered]@{}
    if ($Entry.Contains('command')) {
        $out['command'] = $Entry['command']
    }
    if ($Entry.Contains('args')) {
        if ($Entry['args'] -is [array]) {
            $out['args'] = @($Entry['args'])
        }
        else {
            $out['args'] = $Entry['args']
        }
    }
    if ($Entry.Contains('env')) {
        $envVal = $Entry['env']
        if ($envVal -is [System.Collections.IDictionary]) {
            if ($envVal.Count -gt 0) {
                $envCopy = [ordered]@{}
                foreach ($k in $envVal.Keys) { $envCopy[$k] = $envVal[$k] }
                $out['env'] = $envCopy
            }
        }
        elseif ($null -ne $envVal) {
            $out['env'] = $envVal
        }
    }
    if ($Entry.Contains('url')) {
        $out['url'] = $Entry['url']
    }
    if ($Entry.Contains('headers')) {
        $hdrVal = $Entry['headers']
        if ($hdrVal -is [System.Collections.IDictionary]) {
            if ($hdrVal.Count -gt 0) {
                $hdrCopy = [ordered]@{}
                foreach ($k in $hdrVal.Keys) { $hdrCopy[$k] = $hdrVal[$k] }
                $out['headers'] = $hdrCopy
            }
        }
        elseif ($null -ne $hdrVal) {
            $out['headers'] = $hdrVal
        }
    }

    $hasNonBoolEnabled = $Entry.Contains('enabled') -and ($Entry['enabled'] -isnot [bool])
    if ($hasNonBoolEnabled) {
        $out['enabled'] = $Entry['enabled']
    }
    else {
        $rawEnabled = if ($Entry.Contains('enabled')) { $Entry['enabled'] } else { $null }
        $rawDisabled = if ($Entry.Contains('disabled')) { $Entry['disabled'] } else { $null }
        $out['enabled'] = ($rawEnabled -ne $false) -and ($rawDisabled -ne $true)
    }

    $knownKeys = @('command', 'args', 'env', 'url', 'headers', 'enabled', 'disabled')
    foreach ($k in $Entry.Keys) {
        if ($k -cnotin $knownKeys) {
            $out[$k] = $Entry[$k]
        }
    }
    return $out
}

function ConvertTo-McpYamlDoubleQuotedString {
    param([AllowEmptyString()] [string] $Value)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        switch ($code) {
            0x5C { [void]$sb.Append('\\') }
            0x22 { [void]$sb.Append('\"') }
            0x00 { [void]$sb.Append('\0') }
            0x07 { [void]$sb.Append('\a') }
            0x08 { [void]$sb.Append('\b') }
            0x09 { [void]$sb.Append('\t') }
            0x0A { [void]$sb.Append('\n') }
            0x0B { [void]$sb.Append('\v') }
            0x0C { [void]$sb.Append('\f') }
            0x0D { [void]$sb.Append('\r') }
            default {
                if ($code -lt 0x20 -or $code -eq 0x7F) {
                    [void]$sb.Append(('\u{0:x4}' -f $code))
                }
                else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-McpYamlKey {
    param([Parameter(Mandatory)] [string] $Key)
    if ($Key -cmatch '^[A-Za-z_][A-Za-z0-9_-]*$' -and $Key -cnotmatch '^(?i:true|false|yes|no|on|off|y|n|null)$') {
        return $Key
    }
    return (ConvertTo-McpYamlDoubleQuotedString -Value $Key)
}

function Format-McpHermesServerYamlLines {
    param(
        [Parameter(Mandatory)] [string] $ServerName,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Payload,
        [Parameter(Mandatory)] [int] $ServerIndent,
        [Parameter(Mandatory)] [string] $Eol
    )
    $sPad = ' ' * $ServerIndent
    $pPad = ' ' * ($ServerIndent + 2)
    $iPad = ' ' * ($ServerIndent + 4)
    $rendered = [System.Collections.Generic.List[object]]::new()

    $addLine = {
        param([string] $Text)
        $rendered.Add([pscustomobject]@{ Index = -1; Content = $Text; Eol = $Eol })
    }

    & $addLine ($sPad + (ConvertTo-McpYamlKey -Key $ServerName) + ':')
    if ($Payload.Contains('command')) {
        & $addLine ($pPad + 'command: ' + (ConvertTo-McpYamlDoubleQuotedString -Value ([string]$Payload['command'])))
        $argsArr = @($Payload['args'])
        if ($argsArr.Count -eq 0) {
            & $addLine ($pPad + 'args: []')
        }
        else {
            & $addLine ($pPad + 'args:')
            foreach ($arg in $argsArr) {
                & $addLine ($iPad + '- ' + (ConvertTo-McpYamlDoubleQuotedString -Value ([string]$arg)))
            }
        }
        if ($Payload.Contains('env') -and $null -ne $Payload['env'] -and $Payload['env'].Count -gt 0) {
            & $addLine ($pPad + 'env:')
            foreach ($k in $Payload['env'].Keys) {
                & $addLine ($iPad + (ConvertTo-McpYamlKey -Key ([string]$k)) + ': ' + (ConvertTo-McpYamlDoubleQuotedString -Value ([string]$Payload['env'][$k])))
            }
        }
    }
    else {
        & $addLine ($pPad + 'url: ' + (ConvertTo-McpYamlDoubleQuotedString -Value ([string]$Payload['url'])))
        if ($Payload.Contains('headers') -and $null -ne $Payload['headers'] -and $Payload['headers'].Count -gt 0) {
            & $addLine ($pPad + 'headers:')
            foreach ($k in $Payload['headers'].Keys) {
                & $addLine ($iPad + (ConvertTo-McpYamlKey -Key ([string]$k)) + ': ' + (ConvertTo-McpYamlDoubleQuotedString -Value ([string]$Payload['headers'][$k])))
            }
        }
    }
    $enabledLiteral = if ($Payload.Contains('enabled') -and ($Payload['enabled'] -eq $false)) { 'false' } else { 'true' }
    & $addLine ($pPad + "enabled: $enabledLiteral")
    return $rendered.ToArray()
}

function Set-McpHermesYamlEntries {
    param(
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $PlatformItems
    )
    $state = Read-McpHermesConfigState -HomeRoot $HomeRoot
    if (-not $state.Valid) {
        throw "Cannot update Hermes config.yaml ($($state.Reason))."
    }
    if (-not $state.Installed) {
        throw 'Cannot update Hermes config.yaml (hermes-not-installed).'
    }
    Assert-PlainPathNoReparse -Path $Path -AllowMissing -MessagePrefix 'MCP target path cannot contain reparse points'

    $eol = $state.NewLine
    $lineList = [System.Collections.Generic.List[object]]::new()
    foreach ($l in @($state.Lines)) {
        $lineList.Add([pscustomobject]@{ Index = $l.Index; Content = $l.Content; Eol = $l.Eol })
    }

    if ((-not $state.HasMcpServers) -or $state.McpEmptyInline) {
        $serverIndent = 2
        if ($state.McpEmptyInline) {
            $hdrIdx = $state.McpHeaderLineIndex
            $hdrSplit = Split-McpYamlComment -Text $lineList[$hdrIdx].Content
            $hdrCommentSuffix = if ($hdrSplit.Comment) { ' ' + $hdrSplit.Comment } else { '' }
            $hdrEol = if ($lineList[$hdrIdx].Eol) { $lineList[$hdrIdx].Eol } else { $eol }
            $lineList[$hdrIdx] = [pscustomobject]@{ Index = $hdrIdx; Content = ("mcp_servers:$hdrCommentSuffix"); Eol = $hdrEol }
            $insertOffset = $hdrIdx + 1
            foreach ($item in $PlatformItems) {
                $rendered = @(Format-McpHermesServerYamlLines -ServerName $item.Server -Payload $item.After -ServerIndent $serverIndent -Eol $eol)
                foreach ($r in $rendered) {
                    $lineList.Insert($insertOffset, $r)
                    $insertOffset++
                }
            }
        }
        else {
            if ($lineList.Count -gt 0 -and $lineList[$lineList.Count - 1].Eol -eq '') {
                $lineList[$lineList.Count - 1] = [pscustomobject]@{
                    Index   = $lineList[$lineList.Count - 1].Index
                    Content = $lineList[$lineList.Count - 1].Content
                    Eol     = $eol
                }
            }
            $lineList.Add([pscustomobject]@{ Index = -1; Content = 'mcp_servers:'; Eol = $eol })
            foreach ($item in $PlatformItems) {
                $rendered = @(Format-McpHermesServerYamlLines -ServerName $item.Server -Payload $item.After -ServerIndent $serverIndent -Eol $eol)
                foreach ($r in $rendered) {
                    $lineList.Add($r)
                }
            }
        }
    }
    else {
        $serverIndent = $state.ServerIndent
        $insertAfterIndex = $state.McpBlockEndIndex
        $updates = [System.Collections.Generic.List[object]]::new()
        $adds = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $PlatformItems) {
            if ($state.EntrySpans.ContainsKey($item.Server)) {
                $span = $state.EntrySpans[$item.Server]
                $updates.Add([pscustomobject]@{ Item = $item; StartIndex = $span.StartIndex; EndIndex = $span.EndIndex })
            }
            else {
                $adds.Add($item)
            }
        }
        foreach ($upd in @($updates | Sort-Object -Property StartIndex -Descending)) {
            $oldCount = $upd.EndIndex - $upd.StartIndex + 1
            $rendered = @(Format-McpHermesServerYamlLines -ServerName $upd.Item.Server -Payload $upd.Item.After -ServerIndent $serverIndent -Eol $eol)
            $lineList.RemoveRange($upd.StartIndex, $oldCount)
            for ($k = 0; $k -lt $rendered.Count; $k++) {
                $lineList.Insert($upd.StartIndex + $k, $rendered[$k])
            }
            if ($upd.EndIndex -le $insertAfterIndex) {
                $insertAfterIndex += ($rendered.Count - $oldCount)
            }
        }
        if ($adds.Count -gt 0) {
            if ($insertAfterIndex -ge 0 -and $lineList[$insertAfterIndex].Eol -eq '') {
                $lineList[$insertAfterIndex] = [pscustomobject]@{
                    Index   = $lineList[$insertAfterIndex].Index
                    Content = $lineList[$insertAfterIndex].Content
                    Eol     = $eol
                }
            }
            $insertPos = $insertAfterIndex + 1
            foreach ($addItem in $adds) {
                $rendered = @(Format-McpHermesServerYamlLines -ServerName $addItem.Server -Payload $addItem.After -ServerIndent $serverIndent -Eol $eol)
                foreach ($r in $rendered) {
                    $lineList.Insert($insertPos, $r)
                    $insertPos++
                }
            }
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    foreach ($l in $lineList) {
        [void]$sb.Append($l.Content)
        [void]$sb.Append($l.Eol)
    }
    $parent = Split-Path -Parent $Path
    if ($parent -and (-not (Test-Path -LiteralPath $parent))) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.UTF8Encoding]::new($false))
}

function Get-McpPlan {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [string[]] $Platform = @('Antigravity', 'Codex', 'Hermes'),
        [string[]] $Server = @()
    )
    $resolvedPlatforms = Resolve-McpPlatforms -Values $Platform
    $registry = Read-McpServerRegistry -RepoRoot $RepoRoot
    $serverFilter = Resolve-McpServerFilter -Values $Server -DeclaredServers $registry.Servers
    $selectedServers = if ($serverFilter.Count -gt 0) {
        @($registry.Servers | Where-Object { $_.Name -cin $serverFilter })
    }
    else {
        @($registry.Servers)
    }

    $antigravityPath = Join-Path $HomeRoot '.gemini/config/mcp_config.json'
    $codexPath = Join-Path $HomeRoot '.codex/config.toml'

    $agState = if ('Antigravity' -cin $resolvedPlatforms) { Read-McpJsonConfigState -Path $antigravityPath -ContainerPath @('mcpServers') } else { $null }
    $cxState = if ('Codex' -cin $resolvedPlatforms) { Get-McpCodexInventory -HomeRoot $HomeRoot } else { $null }
    $hmState = if ('Hermes' -cin $resolvedPlatforms) { Read-McpHermesConfigState -HomeRoot $HomeRoot } else { $null }

    $managedNamesForPlatform = @{}
    foreach ($pName in $resolvedPlatforms) {
        $managedNamesForPlatform[$pName] = @($registry.Servers | Where-Object { $pName -cin $_.Platforms } | ForEach-Object { $_.Name })
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($srv in $selectedServers) {
        foreach ($pName in $resolvedPlatforms) {
            if ($pName -cnotin $srv.Platforms) { continue }

            if ($pName -ceq 'Antigravity') {
                $targetState = $agState
                $unmanagedCount = @($targetState.Entries.Keys | Where-Object { $_ -cnotin $managedNamesForPlatform[$pName] }).Count
                $expected = Get-McpExpectedJsonPayload -Server $srv -PlatformName $pName
                $targetLabel = "~/.gemini/config/mcp_config.json#mcpServers.$($srv.Name)"

                if (-not $targetState.Valid) {
                    $items.Add([ordered]@{
                        Platform       = $pName
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'blocked'
                        State          = 'blocked'
                        Reason         = $targetState.Reason
                        After          = $expected.Payload
                        Changes        = @()
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                    continue
                }
                if (-not $srv.Enabled) {
                    $items.Add([ordered]@{
                        Platform       = $pName
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'blocked'
                        State          = 'blocked'
                        Reason         = 'server-disabled-in-manifest'
                        After          = $expected.Payload
                        Changes        = @()
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                    continue
                }
                if (-not $expected.Supported) {
                    $items.Add([ordered]@{
                        Platform       = $pName
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'blocked'
                        State          = 'blocked'
                        Reason         = $expected.Reason
                        After          = $null
                        Changes        = @()
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                    continue
                }

                $hasEntry = $targetState.Entries.Contains($srv.Name)
                $before = if ($hasEntry) { $targetState.Entries[$srv.Name] } else { $null }
                if (-not $hasEntry) {
                    $items.Add([ordered]@{
                        Platform       = $pName
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'add'
                        State          = 'missing'
                        Reason         = 'missing-managed-entry'
                        After          = $expected.Payload
                        Changes        = (Get-McpObjectFieldDiffs -Before $null -After $expected.Payload)
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                }
                elseif (($null -ne $before) -and ($before -is [System.Collections.IDictionary]) -and (Test-McpObjectJsonEqual -Left $before -Right $expected.Payload)) {
                    $items.Add([ordered]@{
                        Platform       = $pName
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'unchanged'
                        State          = 'unchanged'
                        Reason         = 'managed-entry-match'
                        After          = $expected.Payload
                        Changes        = @()
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                }
                else {
                    $items.Add([ordered]@{
                        Platform       = $pName
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'update'
                        State          = 'different'
                        Reason         = 'managed-entry-differs'
                        After          = $expected.Payload
                        Changes        = @($(if ($before -is [System.Collections.IDictionary]) { Get-McpObjectFieldDiffs -Before $before -After $expected.Payload } else { @('~ / (type-changed)') }))
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                }
                continue
            }

            if ($pName -ceq 'Hermes') {
                $targetState = $hmState
                $unmanagedCount = if ($targetState.Valid -and $targetState.Installed) {
                    @($targetState.Entries.Keys | Where-Object { $_ -cnotin $managedNamesForPlatform['Hermes'] }).Count
                }
                else { 0 }
                $expected = Get-McpExpectedHermesPayload -Server $srv
                $targetLabel = "%LOCALAPPDATA%/hermes/config.yaml#mcp_servers.$($srv.Name)"

                if (-not $targetState.Valid) {
                    $items.Add([ordered]@{
                        Platform       = 'Hermes'
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'blocked'
                        State          = 'blocked'
                        Reason         = $targetState.Reason
                        After          = $expected.Payload
                        Changes        = @()
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                    continue
                }
                if (-not $targetState.Installed) {
                    $items.Add([ordered]@{
                        Platform       = 'Hermes'
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'not-installed'
                        State          = 'not-installed'
                        Reason         = 'hermes-not-installed'
                        After          = $expected.Payload
                        Changes        = @()
                        UnmanagedCount = 0
                        NativeAction   = $null
                    })
                    continue
                }
                if (-not $srv.Enabled) {
                    $items.Add([ordered]@{
                        Platform       = 'Hermes'
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'blocked'
                        State          = 'blocked'
                        Reason         = 'server-disabled-in-manifest'
                        After          = $expected.Payload
                        Changes        = @()
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                    continue
                }

                $hasEntry = $targetState.Entries.Contains($srv.Name)
                $beforeRaw = if ($hasEntry) { $targetState.Entries[$srv.Name] } else { $null }
                if (-not $hasEntry) {
                    $items.Add([ordered]@{
                        Platform       = 'Hermes'
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'add'
                        State          = 'missing'
                        Reason         = 'missing-managed-entry'
                        After          = $expected.Payload
                        Changes        = (Get-McpObjectFieldDiffs -Before $null -After $expected.Payload)
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                }
                elseif ($beforeRaw -isnot [System.Collections.IDictionary]) {
                    $items.Add([ordered]@{
                        Platform       = 'Hermes'
                        Server         = $srv.Name
                        Target         = $targetLabel
                        TargetPath     = $targetState.Path
                        Action         = 'update'
                        State          = 'different'
                        Reason         = 'managed-entry-differs'
                        After          = $expected.Payload
                        Changes        = @('~ / (type-changed)')
                        UnmanagedCount = $unmanagedCount
                        NativeAction   = $null
                    })
                }
                else {
                    $beforeHermes = ConvertFrom-McpHermesLiveEntry -Entry $beforeRaw
                    $isValidEnabledBool = ($beforeHermes['enabled'] -is [bool])
                    $liveEnabled = if ($isValidEnabledBool) { [bool]$beforeHermes['enabled'] } else { $true }
                    $preserveLocalDisabled = $srv.Enabled -and ($srv.EnabledPolicy -ceq 'preserve-disabled') -and $isValidEnabledBool -and (-not $liveEnabled)
                    $compareBefore = $beforeHermes
                    $compareExpected = $expected.Payload
                    $effectiveAfter = $expected.Payload
                    if ($preserveLocalDisabled) {
                        $compareBefore = [ordered]@{}
                        foreach ($k in $beforeHermes.Keys) {
                            if ($k -cne 'enabled') { $compareBefore[$k] = $beforeHermes[$k] }
                        }
                        $compareExpected = [ordered]@{}
                        foreach ($k in $expected.Payload.Keys) {
                            if ($k -cne 'enabled') { $compareExpected[$k] = $expected.Payload[$k] }
                        }
                        $effectiveAfter = [ordered]@{}
                        foreach ($k in $expected.Payload.Keys) {
                            $effectiveAfter[$k] = $expected.Payload[$k]
                        }
                        $effectiveAfter['enabled'] = $false
                    }
                    if (Test-McpObjectJsonEqual -Left $compareBefore -Right $compareExpected) {
                        $matchReason = if ($preserveLocalDisabled) { 'managed-entry-match-local-disabled' } else { 'managed-entry-match' }
                        $items.Add([ordered]@{
                            Platform       = 'Hermes'
                            Server         = $srv.Name
                            Target         = $targetLabel
                            TargetPath     = $targetState.Path
                            Action         = 'unchanged'
                            State          = 'unchanged'
                            Reason         = $matchReason
                            After          = $effectiveAfter
                            Changes        = @()
                            UnmanagedCount = $unmanagedCount
                            NativeAction   = $null
                        })
                    }
                    else {
                        $items.Add([ordered]@{
                            Platform       = 'Hermes'
                            Server         = $srv.Name
                            Target         = $targetLabel
                            TargetPath     = $targetState.Path
                            Action         = 'update'
                            State          = 'different'
                            Reason         = 'managed-entry-differs'
                            After          = $effectiveAfter
                            Changes        = (Get-McpObjectFieldDiffs -Before $compareBefore -After $compareExpected)
                            UnmanagedCount = $unmanagedCount
                            NativeAction   = $null
                        })
                    }
                }
                continue
            }

            # Codex via official `codex mcp` CLI
            $codexSpec = Get-McpExpectedCodexSpec -Server $srv
            $codexUnmanaged = @($cxState.Entries | Where-Object { $_.name -cnotin $managedNamesForPlatform['Codex'] }).Count
            $codexLabel = "codex mcp:$($srv.Name)"

            if (-not $cxState.Valid) {
                $items.Add([ordered]@{
                    Platform       = 'Codex'
                    Server         = $srv.Name
                    Target         = $codexLabel
                    TargetPath     = $codexPath
                    Action         = 'blocked'
                    State          = 'blocked'
                    Reason         = $cxState.Reason
                    After          = $codexSpec.Canonical
                    Changes        = @()
                    UnmanagedCount = $codexUnmanaged
                    NativeAction   = $null
                })
                continue
            }
            if (-not $srv.Enabled) {
                $items.Add([ordered]@{
                    Platform       = 'Codex'
                    Server         = $srv.Name
                    Target         = $codexLabel
                    TargetPath     = $codexPath
                    Action         = 'blocked'
                    State          = 'blocked'
                    Reason         = 'server-disabled-in-manifest'
                    After          = $codexSpec.Canonical
                    Changes        = @()
                    UnmanagedCount = $codexUnmanaged
                    NativeAction   = $null
                })
                continue
            }
            if (-not $codexSpec.Supported) {
                $items.Add([ordered]@{
                    Platform       = 'Codex'
                    Server         = $srv.Name
                    Target         = $codexLabel
                    TargetPath     = $codexPath
                    Action         = 'blocked'
                    State          = 'blocked'
                    Reason         = $codexSpec.Reason
                    After          = $null
                    Changes        = @()
                    UnmanagedCount = $codexUnmanaged
                    NativeAction   = $null
                })
                continue
            }

            $matches = @($cxState.Entries | Where-Object { $_.name -ceq $srv.Name })
            if ($matches.Count -gt 1) {
                $items.Add([ordered]@{
                    Platform       = 'Codex'
                    Server         = $srv.Name
                    Target         = $codexLabel
                    TargetPath     = $codexPath
                    Action         = 'blocked'
                    State          = 'blocked'
                    Reason         = 'ambiguous-codex-entry'
                    After          = $codexSpec.Canonical
                    Changes        = @()
                    UnmanagedCount = $codexUnmanaged
                    NativeAction   = $null
                })
            }
            elseif ($matches.Count -eq 0) {
                $items.Add([ordered]@{
                    Platform       = 'Codex'
                    Server         = $srv.Name
                    Target         = $codexLabel
                    TargetPath     = $codexPath
                    Action         = 'add'
                    State          = 'missing'
                    Reason         = 'missing-managed-entry'
                    After          = $codexSpec.Canonical
                    Changes        = (Get-McpObjectFieldDiffs -Before $null -After $codexSpec.Canonical)
                    UnmanagedCount = $codexUnmanaged
                    NativeAction   = @($codexSpec.AddArgs)
                })
            }
            else {
                $beforeCodex = ConvertFrom-McpCodexLiveEntry -Entry $matches[0]
                $preserveLocalDisabled = $srv.Enabled -and ($srv.EnabledPolicy -ceq 'preserve-disabled') -and ($null -ne $beforeCodex) -and ($beforeCodex['enabled'] -eq $false)
                $compareBefore = $beforeCodex
                $compareExpected = $codexSpec.Canonical
                if ($preserveLocalDisabled) {
                    $compareBefore = [ordered]@{}
                    foreach ($k in $beforeCodex.Keys) {
                        if ($k -cne 'enabled') { $compareBefore[$k] = $beforeCodex[$k] }
                    }
                    $compareExpected = [ordered]@{}
                    foreach ($k in $codexSpec.Canonical.Keys) {
                        if ($k -cne 'enabled') { $compareExpected[$k] = $codexSpec.Canonical[$k] }
                    }
                }
                if (($null -ne $compareBefore) -and (Test-McpObjectJsonEqual -Left $compareBefore -Right $compareExpected)) {
                    $matchReason = if ($preserveLocalDisabled) { 'managed-entry-match-local-disabled' } else { 'managed-entry-match' }
                    $items.Add([ordered]@{
                        Platform       = 'Codex'
                        Server         = $srv.Name
                        Target         = $codexLabel
                        TargetPath     = $codexPath
                        Action         = 'unchanged'
                        State          = 'unchanged'
                        Reason         = $matchReason
                        After          = $codexSpec.Canonical
                        Changes        = @()
                        UnmanagedCount = $codexUnmanaged
                        NativeAction   = $null
                    })
                }
                else {
                    $items.Add([ordered]@{
                        Platform       = 'Codex'
                        Server         = $srv.Name
                        Target         = $codexLabel
                        TargetPath     = $codexPath
                        Action         = 'update'
                        State          = 'different'
                        Reason         = 'managed-entry-differs'
                        After          = $codexSpec.Canonical
                        Changes        = @($(if ($null -ne $compareBefore) { Get-McpObjectFieldDiffs -Before $compareBefore -After $compareExpected } else { @('~ /transport') }))
                        UnmanagedCount = $codexUnmanaged
                        NativeAction   = @($codexSpec.AddArgs)
                    })
                }
            }
        }
    }

    $counts = [ordered]@{ add = 0; update = 0; unchanged = 0; blocked = 0; 'not-installed' = 0 }
    foreach ($item in $items) {
        $counts[$item.Action]++
    }

    return [ordered]@{
        SchemaVersion = 1
        RegistryPath  = $registry.Path
        Platforms     = $resolvedPlatforms
        Servers       = @($selectedServers | ForEach-Object { $_.Name })
        Summary       = $counts
        Items         = $items.ToArray()
    }
}

function Set-McpJsonEntries {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string[]] $ContainerPath,
        [Parameter(Mandatory)] [object[]] $PlatformItems
    )
    $raw = if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::ReadAllText($Path) } else { '' }
    [System.Text.Json.Nodes.JsonObject] $rootNode = $null
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $rootNode = [System.Text.Json.Nodes.JsonObject]::new()
    }
    else {
        $rootNode = [System.Text.Json.Nodes.JsonNode]::Parse($raw).AsObject()
    }

    [System.Text.Json.Nodes.JsonObject] $cursor = $rootNode
    foreach ($segment in $ContainerPath) {
        if (-not $cursor.ContainsKey($segment)) {
            $cursor[$segment] = [System.Text.Json.Nodes.JsonObject]::new()
        }
        elseif ($cursor[$segment] -isnot [System.Text.Json.Nodes.JsonObject]) {
            throw "Target JSON container '$segment' is not an object."
        }
        $cursor = $cursor[$segment].AsObject()
    }

    foreach ($item in $PlatformItems) {
        $entryJson = ConvertTo-Json -InputObject $item.After -Depth 20
        $cursor[$item.Server] = [System.Text.Json.Nodes.JsonNode]::Parse($entryJson)
    }

    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $true
    $content = $rootNode.ToJsonString($options) + "`n"
    $parent = Split-Path -Parent $Path
    if ($parent -and (-not (Test-Path -LiteralPath $parent))) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::WriteAllText($Path, $content, [Text.UTF8Encoding]::new($false))
}

function Test-McpPendingPlanMatches {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Expected,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Actual
    )
    if ($Expected.Count -ne $Actual.Count) { return $false }
    $expectedByKey = @{}
    foreach ($item in $Expected) {
        $expectedByKey["$($item.Platform)`0$($item.Server)"] = $item
    }
    foreach ($freshItem in $Actual) {
        $key = "$($freshItem.Platform)`0$($freshItem.Server)"
        if (-not $expectedByKey.ContainsKey($key)) { return $false }
        $oldItem = $expectedByKey[$key]
        if ($oldItem.Action -cne $freshItem.Action) { return $false }
        if ($oldItem.TargetPath -cne $freshItem.TargetPath) { return $false }
        if ($oldItem.UnmanagedCount -ne $freshItem.UnmanagedCount) { return $false }
        $oldAction = if ($null -eq $oldItem.NativeAction) { '' } else { @($oldItem.NativeAction) -join "`0" }
        $newAction = if ($null -eq $freshItem.NativeAction) { '' } else { @($freshItem.NativeAction) -join "`0" }
        if ($oldAction -cne $newAction) { return $false }
        if (-not (Test-McpObjectJsonEqual -Left $oldItem.After -Right $freshItem.After)) { return $false }
    }
    return $true
}

function Invoke-McpDeploy {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [string[]] $Platform = @('Antigravity', 'Codex', 'Hermes'),
        [string[]] $Server = @(),
        [Parameter(Mandatory)] [string] $BackupRoot,
        [switch] $DoApply,
        [switch] $SkipSecretScan,
        [switch] $Quiet
    )
    $plan = Get-McpPlan -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -Server $Server
    if (-not $DoApply) {
        return $plan
    }

    $resolvedBackupRoot = Resolve-ConfigBackupRoot -RepoRoot $RepoRoot -BackupRoot $BackupRoot
    Assert-PlainPathNoReparse -Path $BackupRoot -AllowMissing -MessagePrefix 'MCP backup root cannot contain reparse points'
    Assert-PlainPathNoReparse -Path $resolvedBackupRoot -AllowMissing -MessagePrefix 'MCP backup root cannot contain reparse points'
    $BackupRoot = $resolvedBackupRoot

    $blocked = @($plan.Items | Where-Object { $_.Action -ceq 'blocked' })
    if ($blocked.Count -gt 0) {
        $reasons = @($blocked | ForEach-Object { "$($_.Platform)/$($_.Server):$($_.Reason)" }) -join ', '
        throw "MCP deployment blocked ($reasons). Resolve blocked items before -Apply."
    }

    $resolvedPlatforms = @($plan.Platforms)
    $notInstalledHermes = @($plan.Items | Where-Object { $_.Platform -ceq 'Hermes' -and $_.Action -ceq 'not-installed' })
    if ($resolvedPlatforms.Count -eq 1 -and $resolvedPlatforms[0] -ceq 'Hermes' -and $notInstalledHermes.Count -gt 0) {
        throw 'MCP deployment blocked (Hermes not installed at default home).'
    }

    $pending = @($plan.Items | Where-Object { $_.Action -cin @('add', 'update') })
    if ($pending.Count -eq 0) {
        return $plan
    }

    if (-not $SkipSecretScan) {
        try {
            if ($Quiet) {
                Invoke-SecretScanGate -RepoRoot $RepoRoot | Out-Null
            }
            else {
                Invoke-SecretScanGate -RepoRoot $RepoRoot | Out-Host
            }
        }
        catch {
            $detail = $_.Exception.Message
            throw "Secret scan failed. Aborting MCP apply; no targets written. ($detail)"
        }
    }

    # Re-read plan after scan gate to avoid applying stale assumptions.
    $freshPlan = Get-McpPlan -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -Server $Server
    $freshBlocked = @($freshPlan.Items | Where-Object { $_.Action -ceq 'blocked' })
    if ($freshBlocked.Count -gt 0) {
        throw 'MCP state became blocked during pre-Apply validation.'
    }
    $freshNotInstalledHermes = @($freshPlan.Items | Where-Object { $_.Platform -ceq 'Hermes' -and $_.Action -ceq 'not-installed' })
    if ($resolvedPlatforms.Count -eq 1 -and $resolvedPlatforms[0] -ceq 'Hermes' -and $freshNotInstalledHermes.Count -gt 0) {
        throw 'MCP deployment blocked (Hermes not installed at default home).'
    }
    $freshPending = @($freshPlan.Items | Where-Object { $_.Action -cin @('add', 'update') })
    if (-not (Test-McpPendingPlanMatches -Expected $pending -Actual $freshPending)) {
        throw 'MCP plan drifted during pre-Apply validation; re-run -DryRun to review before -Apply.'
    }
    $pending = $freshPending

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $backupDir = Join-Path $BackupRoot "mcp-backup-$stamp"
    $backedUpFiles = [ordered]@{}
    $fileTargets = [System.Collections.Generic.List[object]]::new()

    foreach ($pName in @('Antigravity', 'Hermes')) {
        $pItems = @($pending | Where-Object { $_.Platform -ceq $pName })
        if ($pItems.Count -eq 0) { continue }
        $path = $pItems[0].TargetPath
        Assert-PlainPathNoReparse -Path $path -AllowMissing -MessagePrefix 'MCP target path cannot contain reparse points'
        $existed = Test-Path -LiteralPath $path -PathType Leaf
        $backupFile = $null
        if ($existed) {
            $rel = $path.Substring($HomeRoot.Length).TrimStart('\', '/')
            $backupFile = Join-Path $backupDir $rel
            [IO.Directory]::CreateDirectory((Split-Path -Parent $backupFile)) | Out-Null
            Copy-Item -LiteralPath $path -Destination $backupFile -Force
            $backedUpFiles[$path] = $backupFile
        }
        $fileTargets.Add([pscustomobject]@{
            Platform      = $pName
            Kind          = $(if ($pName -ceq 'Hermes') { 'Yaml' } else { 'Json' })
            Path          = $path
            ContainerPath = @('mcpServers')
            Items         = $pItems
            Existed       = $existed
            BackupFile    = $backupFile
        })
    }

    $codexItems = @($pending | Where-Object { $_.Platform -ceq 'Codex' })
    if ($codexItems.Count -gt 0) {
        $codexConfigPath = $codexItems[0].TargetPath
        Assert-PlainPathNoReparse -Path $codexConfigPath -AllowMissing -MessagePrefix 'MCP target path cannot contain reparse points'
        if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
            $rel = $codexConfigPath.Substring($HomeRoot.Length).TrimStart('\', '/')
            $backupFile = Join-Path $backupDir $rel
            [IO.Directory]::CreateDirectory((Split-Path -Parent $backupFile)) | Out-Null
            Copy-Item -LiteralPath $codexConfigPath -Destination $backupFile -Force
            $backedUpFiles[$codexConfigPath] = $backupFile
        }
    }

    $attemptedFiles = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($target in $fileTargets) {
            $attemptedFiles.Add($target)
            if ($target.Kind -ceq 'Yaml') {
                Set-McpHermesYamlEntries -HomeRoot $HomeRoot -Path $target.Path -PlatformItems $target.Items
            }
            else {
                Set-McpJsonEntries -Path $target.Path -ContainerPath $target.ContainerPath -PlatformItems $target.Items
            }
        }
    }
    catch {
        $writeError = $_
        for ($i = $attemptedFiles.Count - 1; $i -ge 0; $i--) {
            $target = $attemptedFiles[$i]
            try {
                if ($target.Existed -and $target.BackupFile) {
                    Copy-Item -LiteralPath $target.BackupFile -Destination $target.Path -Force
                }
                elseif ((-not $target.Existed) -and (Test-Path -LiteralPath $target.Path -PathType Leaf)) {
                    Remove-Item -LiteralPath $target.Path -Force
                }
            }
            catch { Write-Warning "MCP rollback could not restore $($target.Path): $($_.Exception.Message)" }
        }
        if ($backedUpFiles.Count -gt 0) {
            Write-Warning "MCP file projection failed; pre-Apply backups preserved at $backupDir"
        }
        throw $writeError
    }

    $codexBackupNote = if ($backedUpFiles.Count -gt 0) { ". Pre-Apply backups preserved at $backupDir" } else { '' }
    $readbackBackupNote = if ($backedUpFiles.Count -gt 0) { " Backups: $backupDir" } else { '' }
    if ($codexItems.Count -gt 0) {
        $codexDir = Join-Path $HomeRoot '.codex'
        if (-not (Test-Path -LiteralPath $codexDir -PathType Container)) {
            [IO.Directory]::CreateDirectory($codexDir) | Out-Null
        }
        foreach ($item in $codexItems) {
            if ($item.Action -ceq 'update') {
                $rm = Invoke-McpCodexCommand -Arguments @('mcp', 'remove', $item.Server) -HomeRoot $HomeRoot
                if (-not $rm.Available -or $rm.Code -ne 0) {
                    throw "codex mcp remove '$($item.Server)' failed (exit $($rm.Code)): $($rm.Error)$codexBackupNote"
                }
            }
            $add = Invoke-McpCodexCommand -Arguments $item.NativeAction -HomeRoot $HomeRoot
            if (-not $add.Available -or $add.Code -ne 0) {
                throw "codex mcp add '$($item.Server)' failed (exit $($add.Code)): $($add.Error)$codexBackupNote"
            }
        }
    }

    # Post-Apply readback verification.
    $readback = Get-McpPlan -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -Server $Server
    foreach ($applied in $pending) {
        $verified = @($readback.Items | Where-Object { $_.Platform -ceq $applied.Platform -and $_.Server -ceq $applied.Server })
        if ($verified.Count -ne 1 -or $verified[0].Action -cne 'unchanged') {
            $detail = if ($verified.Count -eq 1) { "$($verified[0].Action)/$($verified[0].Reason)" } else { 'missing' }
            throw "Post-Apply MCP readback did not converge to unchanged for $($applied.Platform)/$($applied.Server) ($detail).$readbackBackupNote"
        }
        if ($verified[0].UnmanagedCount -lt $applied.UnmanagedCount) {
            throw "Post-Apply MCP readback detected reduced unmanaged count for $($applied.Platform).$readbackBackupNote"
        }
    }

    if ($backedUpFiles.Count -gt 0) {
        $readback['BackupDir'] = $backupDir
    }
    return $readback
}

function Write-McpJsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Value
    )
    Assert-PlainPathNoReparse -Path $Path -AllowMissing -MessagePrefix 'MCP target path cannot contain reparse points'
    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
}

function Write-McpPlanReport {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] [string] $ModeLabel
    )
    Write-Host "mcp-sync ($ModeLabel)  platforms: $($Report.Platforms -join ', ')  servers: $($Report.Servers -join ', ')" -ForegroundColor Cyan
    foreach ($item in $Report.Items) {
        $color = switch ($item.Action) {
            'add' { 'Green' }
            'update' { 'Yellow' }
            'blocked' { 'Red' }
            'not-installed' { 'DarkGray' }
            default { 'DarkGray' }
        }
        Write-Host ("  [{0,-11}] {1,-16} {2,-13} ({3})  unmanaged-preserved={4}" -f $item.Platform, $item.Server, $item.Action, $item.Reason, $item.UnmanagedCount) -ForegroundColor $color
        foreach ($diff in @($item.Changes)) {
            Write-Host "      $diff" -ForegroundColor DarkGray
        }
    }
    $s = $Report.Summary
    $notInstalledCount = if ($s.Contains('not-installed')) { [int]$s['not-installed'] } else { 0 }
    if ($notInstalledCount -gt 0) {
        Write-Host ("Plan: add={0} update={1} unchanged={2} blocked={3} not-installed={4}" -f $s.add, $s.update, $s.unchanged, $s.blocked, $notInstalledCount)
    }
    else {
        Write-Host ("Plan: add={0} update={1} unchanged={2} blocked={3}" -f $s.add, $s.update, $s.unchanged, $s.blocked)
    }
    if ($Report.Contains('BackupDir') -and $Report.BackupDir) {
        Write-Host "Backup: $($Report.BackupDir)" -ForegroundColor Cyan
    }
    Write-Host "Mode: $ModeLabel"
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Apply -and $DryRun) {
    throw 'Specify -DryRun or -Apply, not both.'
}
if ($Apply -and $Action -ne 'Deploy') {
    throw '-Apply is supported only for Deploy.'
}
if ($DryRun -and $PSBoundParameters.ContainsKey('Action') -and $Action -eq 'Status') {
    throw '-DryRun is supported only for Deploy.'
}
if ($DryRun) {
    $Action = 'Deploy'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($HomeRoot)) {
    throw 'HomeRoot could not be determined.'
}

$report = if ($Action -eq 'Status') {
    Get-McpPlan -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -Server $Server
}
else {
    Invoke-McpDeploy -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -Server $Server -BackupRoot $BackupRoot -DoApply:$Apply -SkipSecretScan:$SkipSecretScan -Quiet:$Json
}

if ($Json -or $JsonPath) {
    # Project diagnostics only after deployment has finished using its full plan.
    $report.Items = @(foreach ($item in $report.Items) {
        [pscustomobject]$item | Select-Object Platform, Server, Target, TargetPath, Action, State, Reason, Changes, UnmanagedCount
    })
}

if ($JsonPath) {
    Write-McpJsonFile -Path ([IO.Path]::GetFullPath($JsonPath)) -Value $report
}

if ($Json) {
    ConvertTo-Json -InputObject $report -Depth 20
}
else {
    $modeLabel = if ($Action -eq 'Status') { 'status' } elseif ($Apply) { 'APPLY' } else { 'dry-run' }
    Write-McpPlanReport -Report $report -ModeLabel $modeLabel
}
