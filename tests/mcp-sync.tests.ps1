#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$suiteRepo = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $suiteRepo 'scripts/mcp-sync.ps1')

$suiteWork = Join-Path $suiteRepo ('tmp/tests/mcp-sync/' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($suiteWork) | Out-Null
$script:McpTestAssertions = 0

function Assert-McpTest {
    param([bool] $Condition, [string] $Message)
    Assert-TestCondition -Condition $Condition -Message $Message
    $script:McpTestAssertions++
}

function Assert-McpThrows {
    param([scriptblock] $Operation, [string] $Pattern, [string] $Message)
    $failure = $null
    try { $null = & $Operation } catch { $failure = $_.Exception.Message }
    Assert-McpTest ($null -ne $failure -and $failure -match $Pattern) "$Message (got: $failure)"
}

# Stub secret scan and codex CLI for isolated fixture runs (real Invoke-McpCodexCommand
# is never invoked against live home).
$script:McpTestScanCalls = 0
$script:McpTestFailScan = $false
function Invoke-SecretScanGate {
    param([string] $RepoRoot)
    $script:McpTestScanCalls++
    if ($script:McpTestFailScan) { throw 'fixture secret scan failed' }
}

$script:McpTestCodexAvailable = $true
$script:McpTestCodexEntries = @()
$script:McpTestCodexCalls = [System.Collections.Generic.List[string]]::new()
$script:McpTestCodexFailOn = ''

function Invoke-McpCodexCommand {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $HomeRoot
    )
    $joined = $Arguments -join ' '
    $script:McpTestCodexCalls.Add($joined)
    if (-not $script:McpTestCodexAvailable) {
        return @{ Available = $false; Code = -1; Out = ''; Error = 'codex CLI not found' }
    }
    if ($joined -ceq '--version') {
        return @{ Available = $true; Code = 0; Out = 'codex-cli 0.0.0-fixture'; Error = '' }
    }
    if ($joined -ceq 'mcp list --json') {
        if ($script:McpTestCodexFailOn -ceq 'list') {
            return @{ Available = $true; Code = 1; Out = ''; Error = 'fixture list failure' }
        }
        $json = ConvertTo-Json -InputObject @($script:McpTestCodexEntries) -Depth 20 -Compress
        return @{ Available = $true; Code = 0; Out = $json; Error = '' }
    }
    if ($Arguments.Count -ge 3 -and $Arguments[0] -ceq 'mcp' -and $Arguments[1] -ceq 'remove') {
        if ($script:McpTestCodexFailOn -ceq 'remove') {
            return @{ Available = $true; Code = 1; Out = ''; Error = 'fixture remove failure' }
        }
        $targetName = $Arguments[2]
        $script:McpTestCodexEntries = @($script:McpTestCodexEntries | Where-Object { $_.name -cne $targetName })
        return @{ Available = $true; Code = 0; Out = "removed $targetName"; Error = '' }
    }
    if ($Arguments.Count -ge 4 -and $Arguments[0] -ceq 'mcp' -and $Arguments[1] -ceq 'add') {
        if ($script:McpTestCodexFailOn -ceq 'add') {
            return @{ Available = $true; Code = 1; Out = ''; Error = 'fixture add failure' }
        }
        $targetName = $Arguments[2]
        $envObj = @{}
        $cmdTokens = [System.Collections.Generic.List[string]]::new()
        $afterDash = $false
        $urlVal = $null
        $bearerVar = $null
        for ($i = 3; $i -lt $Arguments.Count; $i++) {
            if ($afterDash) {
                $cmdTokens.Add($Arguments[$i])
                continue
            }
            if ($Arguments[$i] -ceq '--') { $afterDash = $true; continue }
            if ($Arguments[$i] -ceq '--env' -and $i + 1 -lt $Arguments.Count) {
                $kv = $Arguments[++$i] -split '=', 2
                $envObj[$kv[0]] = $kv[1]
                continue
            }
            if ($Arguments[$i] -ceq '--url' -and $i + 1 -lt $Arguments.Count) {
                $urlVal = $Arguments[++$i]
                continue
            }
            if ($Arguments[$i] -ceq '--bearer-token-env-var' -and $i + 1 -lt $Arguments.Count) {
                $bearerVar = $Arguments[++$i]
                continue
            }
        }
        if ($urlVal) {
            $script:McpTestCodexEntries += @{
                name      = $targetName
                enabled   = $true
                transport = @{ type = 'streamable_http'; url = $urlVal; bearer_token_env_var = $bearerVar }
            }
        }
        else {
            $script:McpTestCodexEntries += @{
                name      = $targetName
                enabled   = $true
                transport = @{
                    type     = 'stdio'
                    command  = $cmdTokens[0]
                    args     = @($cmdTokens | Select-Object -Skip 1)
                    env      = $(if ($envObj.Count -gt 0) { $envObj } else { $null })
                    env_vars = @()
                    cwd      = $null
                }
            }
        }
        $codexConfig = Join-Path $HomeRoot '.codex/config.toml'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $codexConfig)) | Out-Null
        if (-not (Test-Path -LiteralPath $codexConfig)) {
            [IO.File]::WriteAllText($codexConfig, "# personal codex config`nmodel = `"gpt-5`"`n")
        }
        return @{ Available = $true; Code = 0; Out = "added $targetName"; Error = '' }
    }
    throw "Unexpected codex CLI invocation in fixture: $joined"
}

function New-McpFixture {
    param([string] $Name, [string] $ServersPsd1Content)
    $root = Join-Path $suiteWork $Name
    $repo = Join-Path $root 'repo'
    $homeDir = Join-Path $root 'home'
    $backupDir = Join-Path $root 'backups'
    [IO.Directory]::CreateDirectory((Join-Path $repo 'harness-source/mcp')) | Out-Null
    [IO.Directory]::CreateDirectory($homeDir) | Out-Null
    if ($ServersPsd1Content) {
        Set-TestFile -Path (Join-Path $repo 'harness-source/mcp/servers.psd1') -Content $ServersPsd1Content
    }
    else {
        Copy-Item -LiteralPath (Join-Path $suiteRepo 'harness-source/mcp/servers.psd1') -Destination (Join-Path $repo 'harness-source/mcp/servers.psd1') -Force
    }
    $script:McpTestScanCalls = 0
    $script:McpTestFailScan = $false
    $script:McpTestCodexAvailable = $true
    $script:McpTestCodexEntries = @()
    $script:McpTestCodexCalls.Clear()
    $script:McpTestCodexFailOn = ''
    return [pscustomobject]@{
        Root   = $root
        Repo   = $repo
        Home   = $homeDir
        Backup = $backupDir
    }
}

try {
    Write-Host 'mcp-sync: registry validation and safety rules'
    $realRegistry = Read-McpServerRegistry -RepoRoot $suiteRepo
    Assert-McpTest ($realRegistry.Servers.Count -eq 1 -and $realRegistry.Servers[0].Name -ceq 'blender') 'real servers.psd1 validates and declares blender'
    Assert-McpTest ($realRegistry.Servers[0].Command -ceq 'uvx' -and (($realRegistry.Servers[0].Args -join ' ') -ceq 'mcp-for-blender')) 'blender declares uvx mcp-for-blender'

    $badPrivatePath = 'C:' + '\private\blender.exe'
    $badPathFix = New-McpFixture -Name 'bad-path' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'x'; Transport = 'stdio'; Command = '$badPrivatePath'; Args = @(); Env = @{}; Enabled = `$true; Platforms = @('Codex') }) }"
    Assert-McpThrows { Read-McpServerRegistry -RepoRoot $badPathFix.Repo } 'drive or UNC path' 'rejects drive-letter paths in servers.psd1'

    $badSecret = 'sk-' + ('a' * 24)
    $badSecretFix = New-McpFixture -Name 'bad-secret' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'x'; Transport = 'stdio'; Command = 'uvx'; Args = @('pkg'); Env = @{ API_KEY = '$badSecret' }; Enabled = `$true; Platforms = @('Antigravity') }) }"
    Assert-McpThrows { Read-McpServerRegistry -RepoRoot $badSecretFix.Repo } 'literal secret|placeholder' 'rejects literal secret values in Env'

    $badGoogleKey = 'AI' + 'za' + ('SyA1B2C3D4E5' * 3).Substring(0, 35)
    $badGoogleFix = New-McpFixture -Name 'bad-google-key' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'x'; Transport = 'stdio'; Command = 'uvx'; Args = @('pkg'); Env = @{ API_KEY = '$badGoogleKey' }; Enabled = `$true; Platforms = @('Antigravity') }) }"
    Assert-McpThrows { Read-McpServerRegistry -RepoRoot $badGoogleFix.Repo } 'literal secret' 'rejects literal Google API key in Env'

    foreach ($label in @('PRIVATE KEY', 'ENCRYPTED PRIVATE KEY', 'PKCS8 PRIVATE KEY')) {
        $header = '-----' + "BEGIN $label-----"
        $badKey = New-McpFixture -Name ('bad-' + $label.Replace(' ', '-')) -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'x'; Transport = 'stdio'; Command = 'uvx'; Args = @('pkg'); Env = @{ KEY_HEADER = '$header' }; Enabled = `$true; Platforms = @('Antigravity') }) }"
        Assert-McpThrows { Read-McpServerRegistry -RepoRoot $badKey.Repo } 'literal secret' "rejects $label in Env"
    }

    $badGho = 'gh' + 'o_' + ('a1B2' * 9)
    $badGhoFix = New-McpFixture -Name 'bad-gho' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'x'; Transport = 'stdio'; Command = 'uvx'; Args = @('pkg'); Env = @{ TOKEN = '$badGho' }; Enabled = `$true; Platforms = @('Antigravity') }) }"
    Assert-McpThrows { Read-McpServerRegistry -RepoRoot $badGhoFix.Repo } 'literal secret' 'rejects literal GitHub OAuth token in Env'

    $badKeyFix = New-McpFixture -Name 'bad-key' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'x'; Transport = 'stdio'; Command = 'uvx'; Args = @('pkg'); environment = @{}; Enabled = `$true; Platforms = @('Codex') }) }"
    Assert-McpThrows { Read-McpServerRegistry -RepoRoot $badKeyFix.Repo } "Unsupported MCP server key 'environment'" 'rejects legacy environment key'

    $retiredPlatFix = New-McpFixture -Name 'retired-platform' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'x'; Transport = 'stdio'; Command = 'uvx'; Args = @('pkg'); Env = @{}; Enabled = `$true; Platforms = @('ZCode') }) }"
    Assert-McpThrows { Read-McpServerRegistry -RepoRoot $retiredPlatFix.Repo } 'invalid or duplicate platform' 'rejects retired ZCode platform in servers.psd1'

    $deadTimeoutFix = New-McpFixture -Name 'dead-timeout' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'x'; Transport = 'stdio'; Command = 'uvx'; Args = @('pkg'); TimeoutMs = 1000; Enabled = `$true; Platforms = @('Codex') }) }"
    Assert-McpThrows { Read-McpServerRegistry -RepoRoot $deadTimeoutFix.Repo } "Unsupported MCP server key 'TimeoutMs'" 'rejects removed TimeoutMs key in servers.psd1'

    Write-Host 'mcp-sync: clean empty home status/dry-run and full Apply across Antigravity and Codex'
    $f1 = New-McpFixture -Name 'full-apply'
    $status1 = Get-McpPlan -RepoRoot $f1.Repo -HomeRoot $f1.Home
    Assert-McpTest ($status1.Summary.add -eq 2 -and $status1.Summary.blocked -eq 0) 'empty home plans add for Antigravity and Codex'
    Assert-McpTest (-not (Test-Path (Join-Path $f1.Home '.gemini')) -and -not (Test-Path (Join-Path $f1.Home '.codex')) -and -not (Test-Path (Join-Path $f1.Home '.zcode'))) 'Status does not create live directories'

    $dry1 = Invoke-McpDeploy -RepoRoot $f1.Repo -HomeRoot $f1.Home -BackupRoot $f1.Backup
    Assert-McpTest ($dry1.Summary.add -eq 2 -and $script:McpTestScanCalls -eq 0) 'Deploy without -Apply runs dry-run without secret scan or writes'
    Assert-McpTest (-not (Test-Path (Join-Path $f1.Home '.gemini')) -and -not (Test-Path (Join-Path $f1.Home '.codex')) -and -not (Test-Path (Join-Path $f1.Home '.zcode'))) 'Dry-run writes no live files'

    # Populate unmanaged servers and personal settings on both active platforms before Apply.
    Set-TestFile -Path (Join-Path $f1.Home '.gemini/config/mcp_config.json') -Content '{"theme":"dark","mcpServers":{"custom_ag":{"command":"node","args":["a.js"]}}}'
    Set-TestFile -Path (Join-Path $f1.Home '.codex/config.toml') -Content "# user codex config`nmodel = `"gpt-5`"`n[mcp_servers.custom_cx]`ncommand = `"node`"`n"
    $script:McpTestCodexEntries = @(
        @{
            name      = 'custom_cx'
            enabled   = $true
            transport = @{ type = 'stdio'; command = 'node'; args = @(); env = $null; env_vars = @(); cwd = $null }
        }
    )

    $apply1 = Invoke-McpDeploy -RepoRoot $f1.Repo -HomeRoot $f1.Home -BackupRoot $f1.Backup -DoApply
    Assert-McpTest ($script:McpTestScanCalls -eq 1 -and $apply1.Summary.unchanged -eq 2 -and $apply1.Summary.add -eq 0 -and $apply1.Summary.update -eq 0) 'Apply runs secret scan and converges Antigravity and Codex to unchanged'
    Assert-McpTest ($apply1.Contains('BackupDir') -and (Test-Path -LiteralPath (Join-Path $apply1.BackupDir '.gemini/config/mcp_config.json')) -and (Test-Path -LiteralPath (Join-Path $apply1.BackupDir '.codex/config.toml'))) 'pre-Apply backups captured for all modified files'

    $agJson = Get-Content -Raw -LiteralPath (Join-Path $f1.Home '.gemini/config/mcp_config.json') | ConvertFrom-Json -AsHashtable
    Assert-McpTest ($agJson.theme -ceq 'dark' -and $agJson.mcpServers.ContainsKey('custom_ag') -and $agJson.mcpServers.blender.command -ceq 'uvx' -and $agJson.mcpServers.blender.env.BLENDER_PORT -ceq '9800') 'Antigravity merge preserves personal keys and unmanaged servers'

    $cxList = @($script:McpTestCodexEntries | Where-Object { $_.name -ceq 'blender' })
    $cxCustom = @($script:McpTestCodexEntries | Where-Object { $_.name -ceq 'custom_cx' })
    Assert-McpTest ($cxList.Count -eq 1 -and $cxCustom.Count -eq 1 -and ($script:McpTestCodexCalls -contains 'mcp add blender --env BLENDER_PORT=9800 -- uvx mcp-for-blender')) 'Codex uses official mcp add CLI and preserves unmanaged servers'
    Assert-McpTest ((Get-Content -Raw -LiteralPath (Join-Path $f1.Home '.codex/config.toml')) -match 'model = "gpt-5"') 'Codex config.toml personal settings remain untouched'

    Write-Host 'mcp-sync: drift detection, update, and 0-byte mcp_config.json'
    # Drift Antigravity and Codex entries
    Set-TestFile -Path (Join-Path $f1.Home '.gemini/config/mcp_config.json') -Content ''
    $script:McpTestCodexEntries = @(
        @{ name = 'custom_cx'; enabled = $true; transport = @{ type = 'stdio'; command = 'node'; args = @(); env = $null; env_vars = @(); cwd = $null } },
        @{ name = 'blender'; enabled = $true; transport = @{ type = 'stdio'; command = 'uvx'; args = @('old-pkg'); env = $null; env_vars = @(); cwd = $null } }
    )
    $driftPlan = Get-McpPlan -RepoRoot $f1.Repo -HomeRoot $f1.Home
    $agItem = @($driftPlan.Items | Where-Object { $_.Platform -ceq 'Antigravity' })[0]
    $cxItem = @($driftPlan.Items | Where-Object { $_.Platform -ceq 'Codex' })[0]
    Assert-McpTest ($agItem.Action -ceq 'add' -and $cxItem.Action -ceq 'update') 'handles 0-byte mcp_config.json as add and detects drifted Codex as update'

    $script:McpTestCodexCalls.Clear()
    $apply2 = Invoke-McpDeploy -RepoRoot $f1.Repo -HomeRoot $f1.Home -BackupRoot $f1.Backup -DoApply
    Assert-McpTest ($apply2.Summary.unchanged -eq 2 -and ($script:McpTestCodexCalls -contains 'mcp remove blender') -and ($script:McpTestCodexCalls -contains 'mcp add blender --env BLENDER_PORT=9800 -- uvx mcp-for-blender')) 'update removes then re-adds Codex entry and converges all targets'

    Write-Host 'mcp-sync: fail-closed boundaries (scan failure, invalid JSON, Codex template/unavailable/failure)'
    $f2 = New-McpFixture -Name 'fail-closed'
    $script:McpTestFailScan = $true
    Assert-McpThrows { Invoke-McpDeploy -RepoRoot $f2.Repo -HomeRoot $f2.Home -BackupRoot $f2.Backup -DoApply } 'Secret scan failed' 'aborts Apply on secret scan failure without writes'
    Assert-McpTest (-not (Test-Path (Join-Path $f2.Home '.gemini')) -and -not (Test-Path (Join-Path $f2.Home '.codex'))) 'secret scan failure writes nothing'

    $f3 = New-McpFixture -Name 'bad-json'
    Set-TestFile -Path (Join-Path $f3.Home '.gemini/config/mcp_config.json') -Content '{invalid'
    $script:McpTestCodexAvailable = $false
    $badStatus = Get-McpPlan -RepoRoot $f3.Repo -HomeRoot $f3.Home
    Assert-McpTest ($badStatus.Summary.blocked -eq 2) 'invalid JSON and unavailable codex CLI each report blocked'
    Assert-McpThrows { Invoke-McpDeploy -RepoRoot $f3.Repo -HomeRoot $f3.Home -BackupRoot $f3.Backup -DoApply } 'MCP deployment blocked' 'Apply refuses when any selected target is blocked'

    # Codex ${VAR} template rejection while Antigravity accepts it
    $tplValue = '$' + '{MEDIA_TOKEN}'
    $tplFix = New-McpFixture -Name 'codex-template' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'media'; Transport = 'stdio'; Command = 'uvx'; Args = @('media-mcp'); Env = @{ MEDIA_TOKEN = '$tplValue' }; Enabled = `$true; Platforms = @('Antigravity', 'Codex') }) }"
    $tplPlan = Get-McpPlan -RepoRoot $tplFix.Repo -HomeRoot $tplFix.Home
    $tplAg = @($tplPlan.Items | Where-Object { $_.Platform -ceq 'Antigravity' })[0]
    $tplCx = @($tplPlan.Items | Where-Object { $_.Platform -ceq 'Codex' })[0]
    Assert-McpTest ($tplAg.Action -ceq 'add' -and $tplCx.Action -ceq 'blocked' -and $tplCx.Reason -ceq 'codex-env-template-unsupported') 'Codex blocks ${...} env templates while Antigravity accepts them'

    # Codex CLI failure preserves pre-Apply backup and stops chain
    $f4 = New-McpFixture -Name 'codex-fail'
    Set-TestFile -Path (Join-Path $f4.Home '.codex/config.toml') -Content "# pre-apply`n"
    $script:McpTestCodexEntries = @()
    $script:McpTestCodexFailOn = 'add'
    Assert-McpThrows { Invoke-McpDeploy -RepoRoot $f4.Repo -HomeRoot $f4.Home -Platform Codex -BackupRoot $f4.Backup -DoApply } 'Pre-Apply backups preserved at' 'Codex CLI failure preserves pre-Apply backup and stops'
    $codexBaks = @(Get-ChildItem -LiteralPath $f4.Backup -Recurse -File -Filter 'config.toml')
    Assert-McpTest ($codexBaks.Count -eq 1 -and (Get-Content -Raw -LiteralPath $codexBaks[0].FullName) -eq "# pre-apply`n") 'Codex pre-Apply config.toml backup matches original content'

    Write-Host 'mcp-sync: subprocess CLI mode (-Json and -JsonPath)'
    $f5 = New-McpFixture -Name 'subprocess'
    $subJsonPath = Join-Path $f5.Root 'report.json'
    $subProc = Invoke-TestProcess -ScriptPath (Join-Path $suiteRepo 'scripts/mcp-sync.ps1') -Arguments @('-Action', 'Status', '-RepoRoot', $f5.Repo, '-HomeRoot', $f5.Home, '-Platform', 'Antigravity', '-Json', '-JsonPath', $subJsonPath)
    $parsedStdout = $null
    try { $parsedStdout = $subProc.Out | ConvertFrom-Json } catch { $parsedStdout = $null }
    Assert-McpTest ($subProc.Code -eq 0 -and $null -ne $parsedStdout -and $parsedStdout.Summary.add -eq 1 -and (Test-Path -LiteralPath $subJsonPath)) 'subprocess Status -Json emits clean JSON and writes -JsonPath'

    Write-Host 'mcp-sync: diagnostic redaction, Changes array type, and quiet -Apply -Json'
    $redactPsd1 = @'
@{ SchemaVersion = 1; Servers = @(
    @{ Name = 'local'; Platforms = @('Antigravity', 'Codex'); Enabled = $true; Transport = 'stdio'; Command = 'fixture'; Env = @{ MODE = 'declared-env-val' } }
    @{ Name = 'remote'; Platforms = @('Antigravity'); Enabled = $true; Transport = 'streamable-http'; Url = 'https://example.invalid/mcp'; Headers = @{ 'X-Fixture' = 'declared-hdr-val' } }
    @{ Name = 'matching'; Platforms = @('Antigravity', 'Codex'); Enabled = $true; Transport = 'stdio'; Command = 'fixture' }
) }
'@
    $f6 = New-McpFixture -Name 'redact-drift' -ServersPsd1Content $redactPsd1
    Set-TestFile -Path (Join-Path $f6.Home '.gemini/config/mcp_config.json') -Content '{"mcpServers":{"local":{"command":"fixture","args":[],"env":{"MODE":"live-ag-env-val"}},"remote":{"url":"https://example.invalid/mcp","headers":{"X-Fixture":"live-ag-hdr-val"}},"matching":{"command":"fixture","args":[]}}}'
    Set-TestFile -Path (Join-Path $f6.Home '.codex/config.toml') -Content "# fixture codex config`n"
    $script:McpTestCodexAvailable = $true
    $script:McpTestCodexFailOn = ''
    $script:McpTestCodexEntries = @(
        @{ name = 'local'; enabled = $true; transport = @{ type = 'stdio'; command = 'fixture'; args = @(); env = @{ MODE = 'live-cx-env-val' }; env_vars = @(); cwd = $null } },
        @{ name = 'matching'; enabled = $true; transport = @{ type = 'stdio'; command = 'fixture'; args = @(); env = $null; env_vars = @(); cwd = $null } }
    )
    $directPlan = Get-McpPlan -RepoRoot $f6.Repo -HomeRoot $f6.Home -Platform @('Antigravity', 'Codex')
    $directJson = ConvertTo-Json -InputObject $directPlan -Depth 20
    Assert-McpTest (@($directPlan.Items | Where-Object { $_.Contains('Before') }).Count -eq 0) 'Get-McpPlan omits dead Before property on all items'
    Assert-McpTest ($directJson -notmatch 'live-ag-env-val|live-ag-hdr-val|live-cx-env-val') 'Get-McpPlan never retains live env or header values across platforms'
    Assert-McpTest ($directPlan.Summary.update -eq 3 -and $directPlan.Summary.unchanged -eq 2) 'Get-McpPlan classifies drifted entries as update and matching entries as unchanged'

    # Fallback Changes branches must remain arrays rather than scalar strings.
    Set-TestFile -Path (Join-Path $f6.Home '.gemini/config/mcp_config.json') -Content '{"mcpServers":{"local":"not-an-object","remote":{"url":"https://example.invalid/mcp","headers":{"X-Fixture":"live-ag-hdr-val"}},"matching":{"command":"fixture","args":[]}}}'
    $script:McpTestCodexEntries = @(
        @{ name = 'local'; enabled = $true; transport = @{} }
    )
    $fallbackPlan = Get-McpPlan -RepoRoot $f6.Repo -HomeRoot $f6.Home -Platform @('Antigravity', 'Codex') -Server @('local')
    foreach ($fbItem in $fallbackPlan.Items) {
        Assert-McpTest ($fbItem.Changes -is [array] -and $fbItem.Changes.Count -eq 1) "fallback Changes on $($fbItem.Platform) remains a single-element array"
    }
    $fallbackJson = ConvertTo-Json -InputObject $fallbackPlan -Depth 20 -Compress
    Assert-McpTest ($fallbackJson -match '"Changes":\["~ / \(type-changed\)"\]' -and $fallbackJson -match '"Changes":\["~ /transport"\]') 'fallback Changes serialize as JSON arrays on Antigravity and Codex'

    # Subprocess Status -Json/-JsonPath, agent-dotfiles status -Json, and Deploy -Apply -Json (with secret scan enabled and fake codex CLI on PATH).
    Set-TestFile -Path (Join-Path $f6.Home '.gemini/config/mcp_config.json') -Content '{"mcpServers":{"local":{"command":"fixture","args":[],"env":{"MODE":"live-ag-env-val"}},"remote":{"url":"https://example.invalid/mcp","headers":{"X-Fixture":"live-ag-hdr-val"}},"matching":{"command":"fixture","args":[]}}}'
    Set-TestFile -Path (Join-Path $f6.Repo 'scripts/scan-secrets.ps1') -Content "param([string] `$RepoRoot)`nWrite-Output 'Secret scan: PASS (fixture banner)'`nexit 0`n"
    $codexStatePath = Join-Path $f6.Home '.codex/fake-codex-mcp.json'
    Set-TestFile -Path $codexStatePath -Content '[{"name":"local","enabled":true,"transport":{"type":"stdio","command":"fixture","args":[],"env":{"MODE":"live-cx-env-val"},"env_vars":[],"cwd":null}},{"name":"matching","enabled":true,"transport":{"type":"stdio","command":"fixture","args":[],"env":null,"env_vars":[],"cwd":null}}]'
    $fakeBin = Join-Path $f6.Root 'bin'
    Set-TestFile -Path (Join-Path $fakeBin 'codex.ps1') -Content @'
$ErrorActionPreference = 'Stop'
$joined = $args -join ' '
if ($joined -ceq '--version') {
    Write-Output 'codex-cli 0.0.0-fixture'
    exit 0
}
$stateFile = Join-Path $env:CODEX_HOME 'fake-codex-mcp.json'
$entries = if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
    @(Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json -AsHashtable -NoEnumerate)
} else { @() }
if ($joined -ceq 'mcp list --json') {
    Write-Output (ConvertTo-Json -InputObject @($entries) -Depth 20 -Compress)
    exit 0
}
if ($args.Count -ge 3 -and $args[0] -ceq 'mcp' -and $args[1] -ceq 'remove') {
    $targetName = [string]$args[2]
    $entries = @($entries | Where-Object { $_['name'] -cne $targetName })
    [IO.File]::WriteAllText($stateFile, (ConvertTo-Json -InputObject @($entries) -Depth 20 -Compress))
    Write-Output "removed $targetName"
    exit 0
}
if ($args.Count -ge 4 -and $args[0] -ceq 'mcp' -and $args[1] -ceq 'add') {
    $targetName = [string]$args[2]
    $envObj = @{}
    $cmdTokens = [System.Collections.Generic.List[string]]::new()
    $afterDash = $false
    for ($i = 3; $i -lt $args.Count; $i++) {
        $tok = [string]$args[$i]
        if ($afterDash) { $cmdTokens.Add($tok); continue }
        if ($tok -ceq '--') { $afterDash = $true; continue }
        if ($tok -ceq '--env' -and $i + 1 -lt $args.Count) {
            $kv = ([string]$args[++$i]) -split '=', 2
            $envObj[$kv[0]] = $kv[1]
            continue
        }
    }
    $entries += @{
        name      = $targetName
        enabled   = $true
        transport = @{
            type     = 'stdio'
            command  = $cmdTokens[0]
            args     = @($cmdTokens | Select-Object -Skip 1)
            env      = $(if ($envObj.Count -gt 0) { $envObj } else { $null })
            env_vars = @()
            cwd      = $null
        }
    }
    [IO.File]::WriteAllText($stateFile, (ConvertTo-Json -InputObject @($entries) -Depth 20 -Compress))
    Write-Output "added $targetName"
    exit 0
}
throw "Unexpected fake codex args: $joined"
'@
    $savedPath = $env:PATH
    $env:PATH = "$fakeBin$([IO.Path]::PathSeparator)$savedPath"
    try {
        $redactPath = Join-Path $f6.Root 'redact-status.json'
        $stProc = Invoke-TestProcess -ScriptPath (Join-Path $suiteRepo 'scripts/mcp-sync.ps1') -Arguments @('-Action', 'Status', '-RepoRoot', $f6.Repo, '-HomeRoot', $f6.Home, '-Platform', 'Antigravity,Codex', '-Json', '-JsonPath', $redactPath)
        Assert-McpTest ($stProc.Code -eq 0) 'subprocess Status -Json succeeds on drifted Antigravity and Codex entries'

        $adProc = Invoke-TestProcess -ScriptPath (Join-Path $suiteRepo 'scripts/agent-dotfiles.ps1') -Arguments @('status', '-RepoRoot', $f6.Repo, '-HomeRoot', $f6.Home, '-StateRoot', (Join-Path $f6.Root 'state'), '-Json')
        # This fixture supplies the MCP registry only. Other status queries report missing inputs.
        $overview = $adProc.Out | ConvertFrom-Json
        Assert-McpTest ($adProc.Code -eq 1 -and $overview.Environment.Error -and $overview.Antigravity.Error -and $overview.Summary.Mcp.update -eq 3) 'unified status reports unavailable sections while preserving the MCP drift summary'

        foreach ($payload in @($stProc.Out, [IO.File]::ReadAllText($redactPath), $adProc.Out)) {
            Assert-McpTest ($payload -notmatch 'live-ag-env-val|live-ag-hdr-val|live-cx-env-val|declared-env-val|declared-hdr-val') 'Status JSON output omits both live and declared env/header values'
            $parsed = $payload | ConvertFrom-Json
            if ($parsed.PSObject.Properties['Mcp']) { $parsed = $parsed.Mcp }
            Assert-McpTest (@($parsed.Items | Where-Object { $_.PSObject.Properties['Before'] }).Count -eq 0) 'Status JSON omits Before on all items'
            $agLocal = @($parsed.Items | Where-Object { $_.Platform -ceq 'Antigravity' -and $_.Server -ceq 'local' })[0]
            $cxLocal = @($parsed.Items | Where-Object { $_.Platform -ceq 'Codex' -and $_.Server -ceq 'local' })[0]
            $agRemote = @($parsed.Items | Where-Object { $_.Platform -ceq 'Antigravity' -and $_.Server -ceq 'remote' })[0]
            $agMatch = @($parsed.Items | Where-Object { $_.Platform -ceq 'Antigravity' -and $_.Server -ceq 'matching' })[0]
            $cxMatch = @($parsed.Items | Where-Object { $_.Platform -ceq 'Codex' -and $_.Server -ceq 'matching' })[0]
            Assert-McpTest ($agLocal.Action -ceq 'update' -and $agLocal.Changes -is [array] -and ($agLocal.Changes -contains '~ /env/MODE')) 'Antigravity Status JSON preserves drifted env field path as array'
            Assert-McpTest ($cxLocal.Action -ceq 'update' -and $cxLocal.Changes -is [array] -and ($cxLocal.Changes -contains '~ /env/MODE')) 'Codex Status JSON preserves drifted env field path as array'
            Assert-McpTest ($agRemote.Action -ceq 'update' -and $agRemote.Changes -is [array] -and ($agRemote.Changes -contains '~ /headers/X-Fixture')) 'Antigravity remote Status JSON preserves drifted header field path as array'
            Assert-McpTest ($agMatch.Action -ceq 'unchanged' -and $cxMatch.Action -ceq 'unchanged' -and $parsed.Summary.update -eq 3 -and $parsed.Summary.unchanged -eq 2) 'Status JSON classifies drifted and matching entries across Antigravity and Codex'
        }

        $applyProc = Invoke-TestProcess -ScriptPath (Join-Path $suiteRepo 'scripts/mcp-sync.ps1') -Arguments @('-Action', 'Deploy', '-Apply', '-RepoRoot', $f6.Repo, '-HomeRoot', $f6.Home, '-Platform', 'Antigravity,Codex', '-BackupRoot', $f6.Backup, '-Json')
        $parsedApply = $null
        try { $parsedApply = $applyProc.Out | ConvertFrom-Json } catch { $parsedApply = $null }
        Assert-McpTest ($applyProc.Code -eq 0 -and $null -ne $parsedApply -and $applyProc.Out -notmatch 'Secret scan: PASS' -and $applyProc.Out -notmatch 'live-ag-env-val|live-ag-hdr-val|live-cx-env-val|declared-env-val|declared-hdr-val') 'Deploy -Apply -Json suppresses secret-scan stdout banner and emits clean redacted JSON'
        Assert-McpTest ($parsedApply.Summary.unchanged -eq 5 -and $parsedApply.Summary.update -eq 0) 'Deploy -Apply -Json converges all drifted entries'
    }
    finally {
        $env:PATH = $savedPath
    }

    Write-Host 'mcp-sync: regression tests (BackupRoot, null args/env_vars, file .codex, drift, backup note, ancestor reparse)'
    $fReg = New-McpFixture -Name 'regressions'
    Assert-McpThrows { Invoke-McpDeploy -RepoRoot $fReg.Repo -HomeRoot $fReg.Home -BackupRoot (Join-Path $fReg.Repo 'in-repo-backups') -DoApply } 'BackupRoot must be outside' 'Apply rejects in-repo BackupRoot'
    $juncTarget = Join-Path $fReg.Root 'junc-target'
    [IO.Directory]::CreateDirectory($juncTarget) | Out-Null
    $juncBackup = Join-Path $fReg.Root 'junc-backup'
    New-Item -ItemType Junction -Path $juncBackup -Target $juncTarget | Out-Null
    Assert-McpThrows { Invoke-McpDeploy -RepoRoot $fReg.Repo -HomeRoot $fReg.Home -BackupRoot $juncBackup -DoApply } 'reparse' 'Apply rejects junction BackupRoot'

    $nullConverted = ConvertFrom-McpCodexLiveEntry -Entry @{
        name = 'blender'; enabled = $true
        transport = @{ type = 'stdio'; command = 'uvx'; args = $null; env = $null; env_vars = $null }
    }
    Assert-McpTest ($nullConverted.args.Count -eq 0 -and (-not $nullConverted.Contains('env_vars'))) 'ConvertFrom-McpCodexLiveEntry handles null args and env_vars cleanly'

    $fCodexFile = New-McpFixture -Name 'codex-file'
    Set-TestFile -Path (Join-Path $fCodexFile.Home '.codex') -Content 'not a directory'
    $codexFilePlan = Get-McpPlan -RepoRoot $fCodexFile.Repo -HomeRoot $fCodexFile.Home -Platform @('Codex')
    Assert-McpTest ($codexFilePlan.Summary.blocked -eq 1 -and $codexFilePlan.Items[0].Reason -ceq 'codex-dir-not-directory') 'Get-McpCodexInventory blocks when .codex is a regular file'

    $fNoBakFail = New-McpFixture -Name 'codex-fail-no-backup'
    $script:McpTestCodexEntries = @()
    $script:McpTestCodexFailOn = 'add'
    $noBakErr = ''
    try { $null = Invoke-McpDeploy -RepoRoot $fNoBakFail.Repo -HomeRoot $fNoBakFail.Home -Platform Codex -BackupRoot $fNoBakFail.Backup -DoApply }
    catch { $noBakErr = $_.Exception.Message }
    Assert-McpTest ($noBakErr -match 'codex mcp add' -and $noBakErr -notmatch 'Pre-Apply backups preserved at') 'Codex CLI failure without prior files does not claim nonexistent backup dir'

    $fDrift = New-McpFixture -Name 'preapply-drift'
    $savedGateFn = ${function:Invoke-SecretScanGate}
    try {
        function Invoke-SecretScanGate {
            param([string] $RepoRoot)
            Set-TestFile -Path (Join-Path $fDrift.Repo 'harness-source/mcp/servers.psd1') -Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'blender'; Platforms = @('Antigravity'); Enabled = `$true; Transport = 'stdio'; Command = 'uvx'; Args = @('changed-mid-scan'); Env = @{ BLENDER_PORT = '9800' } }) }"
        }
        Assert-McpThrows { Invoke-McpDeploy -RepoRoot $fDrift.Repo -HomeRoot $fDrift.Home -Platform Antigravity -BackupRoot $fDrift.Backup -DoApply } 'drifted during pre-Apply validation' 'Invoke-McpDeploy fails closed when pending plan drifts during pre-Apply scan'
        Assert-McpTest (-not (Test-Path (Join-Path $fDrift.Home '.gemini/config/mcp_config.json'))) 'drifted pre-Apply abort writes no target file'
    }
    finally {
        Set-Item -Path 'function:Invoke-SecretScanGate' -Value $savedGateFn
    }

    $fAgJunc = New-McpFixture -Name 'ag-ancestor-junc'
    New-Item -ItemType Junction -Path (Join-Path $fAgJunc.Home '.gemini') -Target $juncTarget | Out-Null
    $agJuncPlan = Get-McpPlan -RepoRoot $fAgJunc.Repo -HomeRoot $fAgJunc.Home -Platform Antigravity
    Assert-McpTest ($agJuncPlan.Summary.blocked -eq 1 -and $agJuncPlan.Items[0].Reason -ceq 'reparse-point-blocked') 'Antigravity status blocks when ancestor .gemini is a junction'

    Write-Host "mcp-sync tests: PASS ($script:McpTestAssertions assertions)"
}
finally {
    if (Test-Path -LiteralPath $suiteWork) {
        Get-ChildItem -LiteralPath $suiteWork -Recurse -Force -Attributes ReparsePoint | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $suiteWork -Recurse -Force -ErrorAction SilentlyContinue
    }
}
