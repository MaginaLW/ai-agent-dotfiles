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

    $badKeyFix = New-McpFixture -Name 'bad-key' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'x'; Transport = 'stdio'; Command = 'uvx'; Args = @('pkg'); environment = @{}; Enabled = `$true; Platforms = @('ZCode') }) }"
    Assert-McpThrows { Read-McpServerRegistry -RepoRoot $badKeyFix.Repo } "Unsupported MCP server key 'environment'" 'rejects legacy environment key'

    Write-Host 'mcp-sync: clean empty home status/dry-run and full Apply across all 3 platforms'
    $f1 = New-McpFixture -Name 'full-apply'
    $status1 = Get-McpPlan -RepoRoot $f1.Repo -HomeRoot $f1.Home
    Assert-McpTest ($status1.Summary.add -eq 3 -and $status1.Summary.blocked -eq 0) 'empty home plans add for Antigravity, Codex, and ZCode'
    Assert-McpTest (-not (Test-Path (Join-Path $f1.Home '.gemini')) -and -not (Test-Path (Join-Path $f1.Home '.codex')) -and -not (Test-Path (Join-Path $f1.Home '.zcode'))) 'Status does not create live directories'

    $dry1 = Invoke-McpDeploy -RepoRoot $f1.Repo -HomeRoot $f1.Home -BackupRoot $f1.Backup
    Assert-McpTest ($dry1.Summary.add -eq 3 -and $script:McpTestScanCalls -eq 0) 'Deploy without -Apply runs dry-run without secret scan or writes'
    Assert-McpTest (-not (Test-Path (Join-Path $f1.Home '.gemini')) -and -not (Test-Path (Join-Path $f1.Home '.codex')) -and -not (Test-Path (Join-Path $f1.Home '.zcode'))) 'Dry-run writes no live files'

    # Populate unmanaged servers and personal settings on all 3 platforms before Apply.
    Set-TestFile -Path (Join-Path $f1.Home '.gemini/config/mcp_config.json') -Content '{"theme":"dark","mcpServers":{"custom_ag":{"command":"node","args":["a.js"]}}}'
    Set-TestFile -Path (Join-Path $f1.Home '.zcode/cli/config.json') -Content '{"model":"glm-5","provider":{"id":"p1"},"plugins":{"enabled":["zcode-guide"]},"mcp":{"otherFlag":true,"servers":{"custom_zc":{"type":"stdio","command":"npx","args":["tool"],"enabled":true}}}}'
    Set-TestFile -Path (Join-Path $f1.Home '.codex/config.toml') -Content "# user codex config`nmodel = `"gpt-5`"`n[mcp_servers.custom_cx]`ncommand = `"node`"`n"
    $script:McpTestCodexEntries = @(
        @{
            name      = 'custom_cx'
            enabled   = $true
            transport = @{ type = 'stdio'; command = 'node'; args = @(); env = $null; env_vars = @(); cwd = $null }
        }
    )

    $apply1 = Invoke-McpDeploy -RepoRoot $f1.Repo -HomeRoot $f1.Home -BackupRoot $f1.Backup -DoApply
    Assert-McpTest ($script:McpTestScanCalls -eq 1 -and $apply1.Summary.unchanged -eq 3 -and $apply1.Summary.add -eq 0 -and $apply1.Summary.update -eq 0) 'Apply runs secret scan and converges all 3 platforms to unchanged'
    Assert-McpTest ($apply1.Contains('BackupDir') -and (Test-Path -LiteralPath (Join-Path $apply1.BackupDir '.gemini/config/mcp_config.json')) -and (Test-Path -LiteralPath (Join-Path $apply1.BackupDir '.zcode/cli/config.json')) -and (Test-Path -LiteralPath (Join-Path $apply1.BackupDir '.codex/config.toml'))) 'pre-Apply backups captured for all modified files'

    $agJson = Get-Content -Raw -LiteralPath (Join-Path $f1.Home '.gemini/config/mcp_config.json') | ConvertFrom-Json -AsHashtable
    Assert-McpTest ($agJson.theme -ceq 'dark' -and $agJson.mcpServers.ContainsKey('custom_ag') -and $agJson.mcpServers.blender.command -ceq 'uvx') 'Antigravity merge preserves personal keys and unmanaged servers'

    $zcJson = Get-Content -Raw -LiteralPath (Join-Path $f1.Home '.zcode/cli/config.json') | ConvertFrom-Json -AsHashtable
    Assert-McpTest ($zcJson.model -ceq 'glm-5' -and $zcJson.provider.id -ceq 'p1' -and $zcJson.mcp.otherFlag -eq $true -and $zcJson.mcp.servers.ContainsKey('custom_zc') -and $zcJson.mcp.servers.blender.type -ceq 'stdio' -and $zcJson.mcp.servers.blender.enabled -eq $true -and (-not $zcJson.mcp.servers.blender.ContainsKey('environment'))) 'ZCode merge preserves model/provider/plugins/unmanaged servers and writes strict stdio schema'

    $cxList = @($script:McpTestCodexEntries | Where-Object { $_.name -ceq 'blender' })
    $cxCustom = @($script:McpTestCodexEntries | Where-Object { $_.name -ceq 'custom_cx' })
    Assert-McpTest ($cxList.Count -eq 1 -and $cxCustom.Count -eq 1 -and ($script:McpTestCodexCalls -contains 'mcp add blender -- uvx mcp-for-blender')) 'Codex uses official mcp add CLI and preserves unmanaged servers'
    Assert-McpTest ((Get-Content -Raw -LiteralPath (Join-Path $f1.Home '.codex/config.toml')) -match 'model = "gpt-5"') 'Codex config.toml personal settings remain untouched'

    Write-Host 'mcp-sync: drift detection, update, and 0-byte mcp_config.json'
    # Drift Antigravity and ZCode and Codex entries
    Set-TestFile -Path (Join-Path $f1.Home '.gemini/config/mcp_config.json') -Content ''
    Set-TestFile -Path (Join-Path $f1.Home '.zcode/cli/config.json') -Content '{"model":"glm-5","mcp":{"servers":{"blender":{"type":"stdio","command":"uvx","args":["old-pkg"],"enabled":true}}}}'
    $script:McpTestCodexEntries = @(
        @{ name = 'custom_cx'; enabled = $true; transport = @{ type = 'stdio'; command = 'node'; args = @(); env = $null; env_vars = @(); cwd = $null } },
        @{ name = 'blender'; enabled = $true; transport = @{ type = 'stdio'; command = 'uvx'; args = @('old-pkg'); env = $null; env_vars = @(); cwd = $null } }
    )
    $driftPlan = Get-McpPlan -RepoRoot $f1.Repo -HomeRoot $f1.Home
    $agItem = @($driftPlan.Items | Where-Object { $_.Platform -ceq 'Antigravity' })[0]
    $zcItem = @($driftPlan.Items | Where-Object { $_.Platform -ceq 'ZCode' })[0]
    $cxItem = @($driftPlan.Items | Where-Object { $_.Platform -ceq 'Codex' })[0]
    Assert-McpTest ($agItem.Action -ceq 'add' -and $zcItem.Action -ceq 'update' -and $cxItem.Action -ceq 'update') 'handles 0-byte mcp_config.json as add and detects drifted ZCode/Codex as update'

    $script:McpTestCodexCalls.Clear()
    $apply2 = Invoke-McpDeploy -RepoRoot $f1.Repo -HomeRoot $f1.Home -BackupRoot $f1.Backup -DoApply
    Assert-McpTest ($apply2.Summary.unchanged -eq 3 -and ($script:McpTestCodexCalls -contains 'mcp remove blender') -and ($script:McpTestCodexCalls -contains 'mcp add blender -- uvx mcp-for-blender')) 'update removes then re-adds Codex entry and converges all targets'

    Write-Host 'mcp-sync: fail-closed boundaries (scan failure, invalid JSON, ZCode template, Codex unavailable/failure)'
    $f2 = New-McpFixture -Name 'fail-closed'
    $script:McpTestFailScan = $true
    Assert-McpThrows { Invoke-McpDeploy -RepoRoot $f2.Repo -HomeRoot $f2.Home -BackupRoot $f2.Backup -DoApply } 'Secret scan failed' 'aborts Apply on secret scan failure without writes'
    Assert-McpTest (-not (Test-Path (Join-Path $f2.Home '.gemini')) -and -not (Test-Path (Join-Path $f2.Home '.zcode'))) 'secret scan failure writes nothing'

    $f3 = New-McpFixture -Name 'bad-json'
    Set-TestFile -Path (Join-Path $f3.Home '.gemini/config/mcp_config.json') -Content '{invalid'
    Set-TestFile -Path (Join-Path $f3.Home '.zcode/cli/config.json') -Content '{"mcp":"not-an-object"}'
    $script:McpTestCodexAvailable = $false
    $badStatus = Get-McpPlan -RepoRoot $f3.Repo -HomeRoot $f3.Home
    Assert-McpTest ($badStatus.Summary.blocked -eq 3) 'invalid JSON, non-object container, and unavailable codex CLI each report blocked'
    Assert-McpThrows { Invoke-McpDeploy -RepoRoot $f3.Repo -HomeRoot $f3.Home -BackupRoot $f3.Backup -DoApply } 'MCP deployment blocked' 'Apply refuses when any selected target is blocked'

    # ZCode ${VAR} template rejection
    $tplValue = '$' + '{MEDIA_TOKEN}'
    $tplFix = New-McpFixture -Name 'zcode-template' -ServersPsd1Content "@{ SchemaVersion = 1; Servers = @(@{ Name = 'media'; Transport = 'stdio'; Command = 'uvx'; Args = @('media-mcp'); Env = @{ MEDIA_TOKEN = '$tplValue' }; Enabled = `$true; Platforms = @('Antigravity', 'ZCode') }) }"
    $tplPlan = Get-McpPlan -RepoRoot $tplFix.Repo -HomeRoot $tplFix.Home
    $tplAg = @($tplPlan.Items | Where-Object { $_.Platform -ceq 'Antigravity' })[0]
    $tplZc = @($tplPlan.Items | Where-Object { $_.Platform -ceq 'ZCode' })[0]
    Assert-McpTest ($tplAg.Action -ceq 'add' -and $tplZc.Action -ceq 'blocked' -and $tplZc.Reason -ceq 'zcode-env-template-unsupported') 'ZCode blocks ${...} env templates while Antigravity accepts them'

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
    $subProc = Invoke-TestProcess -ScriptPath (Join-Path $suiteRepo 'scripts/mcp-sync.ps1') -Arguments @('-Action', 'Status', '-RepoRoot', $f5.Repo, '-HomeRoot', $f5.Home, '-Platform', 'Antigravity,ZCode', '-Json', '-JsonPath', $subJsonPath)
    $parsedStdout = $null
    try { $parsedStdout = $subProc.Out | ConvertFrom-Json } catch { $parsedStdout = $null }
    Assert-McpTest ($subProc.Code -eq 0 -and $null -ne $parsedStdout -and $parsedStdout.Summary.add -eq 2 -and (Test-Path -LiteralPath $subJsonPath)) 'subprocess Status -Json emits clean JSON and writes -JsonPath'

    Write-Host "mcp-sync tests: PASS ($script:McpTestAssertions assertions)"
}
finally {
    if (Test-Path -LiteralPath $suiteWork) {
        Remove-Item -LiteralPath $suiteWork -Recurse -Force -ErrorAction SilentlyContinue
    }
}
