#requires -Version 7.0
<#
.SYNOPSIS
    Inspects and projects managed MCP server definitions from harness-source/mcp/servers.psd1
    to Antigravity and Codex.

.DESCRIPTION
    Status and Deploy -DryRun are read-only and never create or modify live home files.
    Deploy -Apply requires a clean secret scan, backs up any existing target files before
    mutating, projects only declared server entries (preserving all unmanaged servers and
    personal configuration), and runs a post-Apply readback check.

    Antigravity writes per-entry into ~/.gemini/config/mcp_config.json (mcpServers.<name>).
    Codex projects per-entry exclusively via the official `codex mcp` CLI.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Deploy')]
    [string] $Action = 'Status',
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $HomeRoot = [Environment]::GetFolderPath('UserProfile'),
    [string[]] $Platform = @('Antigravity', 'Codex'),
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
    }
    $selected = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($raw in @($Values)) {
        foreach ($token in ([string]$raw -split ',')) {
            $trimmed = $token.Trim()
            if ([string]::IsNullOrEmpty($trimmed)) { continue }
            $key = $trimmed.ToLowerInvariant()
            if (-not $canonical.ContainsKey($key)) {
                throw "Unsupported MCP platform '$trimmed'. Expected Antigravity or Codex."
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
    $validPlatforms = @('Antigravity', 'Codex')
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

function Get-McpPlan {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [string[]] $Platform = @('Antigravity', 'Codex'),
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

    $counts = [ordered]@{ add = 0; update = 0; unchanged = 0; blocked = 0 }
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
        [string[]] $Platform = @('Antigravity', 'Codex'),
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
    $freshPending = @($freshPlan.Items | Where-Object { $_.Action -cin @('add', 'update') })
    if (-not (Test-McpPendingPlanMatches -Expected $pending -Actual $freshPending)) {
        throw 'MCP plan drifted during pre-Apply validation; re-run -DryRun to review before -Apply.'
    }
    $pending = $freshPending

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $backupDir = Join-Path $BackupRoot "mcp-backup-$stamp"
    $backedUpFiles = [ordered]@{}
    $jsonFileTargets = [System.Collections.Generic.List[object]]::new()

    foreach ($pName in @('Antigravity')) {
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
        $jsonFileTargets.Add([pscustomobject]@{
            Platform      = $pName
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

    $attemptedJson = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($target in $jsonFileTargets) {
            $attemptedJson.Add($target)
            Set-McpJsonEntries -Path $target.Path -ContainerPath $target.ContainerPath -PlatformItems $target.Items
        }
    }
    catch {
        $writeError = $_
        for ($i = $attemptedJson.Count - 1; $i -ge 0; $i--) {
            $target = $attemptedJson[$i]
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
            Write-Warning "MCP JSON projection failed; pre-Apply backups preserved at $backupDir"
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
            default { 'DarkGray' }
        }
        Write-Host ("  [{0,-11}] {1,-16} {2,-9} ({3})  unmanaged-preserved={4}" -f $item.Platform, $item.Server, $item.Action, $item.Reason, $item.UnmanagedCount) -ForegroundColor $color
        foreach ($diff in @($item.Changes)) {
            Write-Host "      $diff" -ForegroundColor DarkGray
        }
    }
    $s = $Report.Summary
    Write-Host ("Plan: add={0} update={1} unchanged={2} blocked={3}" -f $s.add, $s.update, $s.unchanged, $s.blocked)
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
