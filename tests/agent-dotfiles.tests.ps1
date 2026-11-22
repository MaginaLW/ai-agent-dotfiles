#requires -Version 7.0
<#!
.SYNOPSIS
    Smoke tests for the unified agent-dotfiles dispatcher.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

$entry = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'
$work = Join-Path $RepoRoot ('tmp/tests/agent-dotfiles/' + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $work 'home'
New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
# Fixture repo for the deploy routes: environments that select no skills, so a
# dry run needs no generated output and never touches a real home.
$fixtureRepo = Join-Path $work 'repo'
New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'harness-source/envs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'manifests') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoRoot 'manifests/whitelist.psd1') -Destination (Join-Path $fixtureRepo 'manifests/whitelist.psd1') -Force
foreach ($envName in @('work', 'test')) {
    Set-Content -LiteralPath (Join-Path $fixtureRepo "harness-source/envs/$envName.psd1") -Encoding utf8 -Value "@{ Name = '$envName'; Description = 'fixture'; Skills = @{ Codex = @() } }"
}
$deployArgs = @('-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', (Join-Path $work 'state'), '-SkipBuild')

$pass = 0
$fail = 0
function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Message" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}
function Invoke-Entry {
    param([string[]] $Arguments)
    Invoke-TestProcess -ScriptPath $entry -Arguments $Arguments
}

# Parser-only cases can call the dispatcher in the test host. Keep native -File coverage
# for representative spellings and use real child processes for successful forwarding.
function Invoke-ParserCase {
    param([string[]] $Arguments, [string] $ScriptPath = $entry, [switch] $Native)
    if ($Native) { return Invoke-TestProcess -ScriptPath $ScriptPath -Arguments $Arguments }
    $output = @(& $ScriptPath @Arguments *>&1)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($output -join "`n") }
}

Write-Host 'unified CLI: env and config/profile routing'
$result = Invoke-Entry -Arguments @('help')
Assert ($result.Code -eq 0 -and $result.Out -match 'Usage:' -and $result.Out -match 'Commands: help') 'help displays usage and exits successfully'
Assert ($result.Out -match 'sync, env deploy, antigravity deploy, mcp deploy, config pull/push, profile apply, and skills promote require exactly one explicit mode' -and $result.Out -match 'build generates output; env list -JsonPath writes a report without a mode') 'help distinguishes mode-gated actions from other writes'
foreach ($group in @('config', 'env', 'profile', 'skills', 'antigravity', 'mcp')) {
    foreach ($helpArgs in @(@('help', $group), @($group, 'help'))) {
        # One grouping keeps the native -File boundary; the rest are pure usage echoes.
        $result = Invoke-ParserCase -Arguments $helpArgs -Native:(($helpArgs -join ' ') -eq 'help config')
        Assert ($result.Code -eq 0 -and $result.Out -match "agent-dotfiles.ps1 $group <action>" -and $result.Out -notmatch 'Invoking script') "group help returns without executing a child: $($helpArgs -join ' ')"
        if ($group -eq 'config') {
            Assert ($result.Out -match 'repository -> home' -and $result.Out -match 'home -> repository' -and $result.Out -match 'not git push') 'config help explains directions and distinguishes capture from Git publication'
        }
        if ($group -eq 'antigravity') {
            Assert ($result.Out -match '-ExternalPlugin' -and $result.Out -notmatch 'two-skill') 'antigravity help documents -ExternalPlugin and avoids stale two-skill wording'
        }
    }
}
foreach ($helpArgs in @(@('help', 'status'), @('status', 'help'))) {
    $result = Invoke-ParserCase -Arguments $helpArgs -Native:(($helpArgs -join ' ') -eq 'status help')
    Assert ($result.Code -eq 0 -and $result.Out -match 'agent-dotfiles.ps1 status' -and $result.Out -match 'strictly read-only' -and $result.Out -notmatch 'Invoking script') "status help returns usage: $($helpArgs -join ' ')"
}
foreach ($helpArgs in @(@('help', 'unknown'), @('config', 'help', 'extra'))) {
    $result = Invoke-ParserCase -Arguments $helpArgs
    Assert ($result.Code -eq 1 -and $result.Out -match 'Unsupported') 'invalid help requests remain errors'
}
$result = Invoke-ParserCase -Arguments @()
Assert ($result.Code -eq 1 -and $result.Out -match 'A command is required') 'missing command remains an error'
$result = Invoke-Entry -Arguments @('env', 'list', '-RepoRoot', $RepoRoot, '-StateRoot', (Join-Path $work 'missing-state'))
Assert ($result.Code -eq 0 -and $result.Out -match 'Harness environments') 'env list routes through the dispatcher'
$listJsonPath = Join-Path $fakeHome 'env-list.json'
$result = Invoke-Entry -Arguments @('env', 'list', '-RepoRoot', $RepoRoot, '-StateRoot', (Join-Path $work 'missing-state'), '-JsonPath', $listJsonPath)
$listJson = $null
try { $listJson = Get-Content -Raw -LiteralPath $listJsonPath | ConvertFrom-Json } catch { $listJson = $null }
Assert ($result.Code -eq 0 -and $null -ne $listJson -and $listJson.PSObject.Properties.Name -contains 'Environments') 'env list writes machine-readable JSON'

Write-Host 'unified CLI: environment selections and recorded deployment'
$listRepo = Join-Path $work 'list-repo'
$listEnvDir = Join-Path $listRepo 'harness-source/envs'
$listState = Join-Path $work 'list-state'
New-Item -ItemType Directory -Path $listEnvDir, $listState -Force | Out-Null
Set-Content -LiteralPath (Join-Path $listEnvDir 'sample.psd1') -Encoding utf8 -Value "@{ Description = 'sample'; Skills = @{ Codex = @('gamma') } }"
$listArgs = @('env', 'list', '-RepoRoot', $listRepo, '-StateRoot', $listState)
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Code -eq 0 -and $result.Out -notmatch 'Claude:|Zcode:' -and $result.Out -match 'Codex: 1 \[gamma\]') 'environment selections show only the supported platforms and counts'
Assert ($result.Out -match 'Last recorded successful Apply environment: unavailable \(record only; live contents may differ\)' -and -not (Test-Path (Join-Path $listState 'deployed-skills.json'))) 'missing deployment state is unavailable and not created'
Assert ($result.Out -match 'Record unavailable reason: missing-state') 'missing deploy record has a distinct explanation'
$listStatePath = Join-Path $listState 'deployed-skills.json'
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{invalid'
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Code -eq 0 -and $result.Out -match 'environment: unavailable' -and $result.Out -match 'Codex: 1') 'malformed state leaves environment list available'
Assert ($result.Out -match 'Record unavailable reason: invalid-json' -and $result.Out -notmatch '\{invalid') 'invalid JSON reports only a fixed reason, not its content'
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{"Codex":[]}'
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Code -eq 0 -and $result.Out -match 'environment: unavailable') 'state without an environment is unavailable'
Assert ($result.Out -match 'Record unavailable reason: missing-environment') 'missing environment is distinct from a malformed record'
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{"Environment":"sample","Codex":"alpha"}'
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Code -eq 0 -and $result.Out -match 'environment: unavailable') 'structurally invalid state is unavailable'
Assert ($result.Out -match 'Record unavailable reason: invalid-state') 'invalid selection structure is explained'
foreach ($badState in @('[]', '{"Environment":123,"Codex":[]}', '{"Environment":"sample\nprivate-value","Codex":[]}')) {
    Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value $badState
    $result = Invoke-Entry -Arguments $listArgs
    Assert ($result.Code -eq 0 -and $result.Out -match 'Record unavailable reason: invalid-state' -and $result.Out -notmatch 'private-value') 'invalid roots and unsafe environment values are not printed'
}
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{"Environment":" ","Codex":[]}'
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Out -match 'Record unavailable reason: missing-environment') 'blank environment has a missing-environment explanation'
$stateLock = [IO.File]::Open($listStatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try { $result = Invoke-Entry -Arguments $listArgs }
finally { $stateLock.Dispose() }
Assert ($result.Code -eq 0 -and $result.Out -match 'Record unavailable reason: read-error') 'unreadable record does not hide the available environments'
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{invalid'
$result = Invoke-Entry -Arguments $listArgs
Assert ($result.Code -eq 0 -and $result.Out -match 'Record unavailable reason: invalid-json') 'invalid JSON keeps its fixed reason after the shared-reader switch'
$fileStateRoot = Join-Path $work 'file-state-root'
Set-TestFile -Path $fileStateRoot -Content 'not a directory'
$result = Invoke-Entry -Arguments @('env', 'list', '-RepoRoot', $listRepo, '-StateRoot', $fileStateRoot)
Assert ($result.Code -eq 0 -and $result.Out -match 'Record unavailable reason: state-root-not-directory') 'a file-shaped StateRoot gets its accurate fixed reason'
Assert ($result.Out -notmatch [regex]::Escape($fileStateRoot)) 'env list never prints the private StateRoot path'
$dirStateRoot = Join-Path $work 'dir-state-root'
New-Item -ItemType Directory -Path (Join-Path $dirStateRoot 'deployed-skills.json') -Force | Out-Null
$result = Invoke-Entry -Arguments @('env', 'list', '-RepoRoot', $listRepo, '-StateRoot', $dirStateRoot)
Assert ($result.Code -eq 0 -and $result.Out -match 'Record unavailable reason: state-path-is-directory') 'a directory-shaped state file gets its accurate fixed reason'
Assert ($result.Out -notmatch [regex]::Escape($dirStateRoot)) 'env list never prints the private state file path'
Set-Content -LiteralPath $listStatePath -Encoding utf8 -Value '{"Environment":"sample","Claude":["alpha"],"Zcode":["beta"],"Codex":[]}'
$stateHash = (Get-FileHash -LiteralPath $listStatePath).Hash
$fixtureJsonPath = Join-Path $work 'fixture-environments.json'
$result = Invoke-Entry -Arguments ($listArgs + @('-JsonPath', $fixtureJsonPath))
$fixtureJson = Get-Content -Raw -LiteralPath $fixtureJsonPath | ConvertFrom-Json
$entryFields = @($fixtureJson.Environments[0].PSObject.Properties.Name | Sort-Object) -join ','
Assert ($result.Code -eq 0 -and $result.Out -match 'environment: sample \(record only; live contents may differ\)') 'valid state is identified as a record, not verified live contents'
Assert ($result.Out -notmatch 'Record unavailable reason:') 'valid records have no error explanation'
Assert ($fixtureJson.Environments.Count -eq 1 -and $fixtureJson.Environments[0].Name -eq 'sample' -and $entryFields -eq 'Description,Name') 'environment report retains its existing JSON shape'
Assert ((Get-FileHash -LiteralPath $listStatePath).Hash -eq $stateHash -and @(Get-ChildItem -LiteralPath $fakeHome -Force).Count -eq 1) 'listing preserves deploy state and live fixture home'

$result = Invoke-Entry -Arguments @('config', 'status', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome, '-Json')
$configJson = $null
try { $configJson = $result.Out | ConvertFrom-Json } catch { $configJson = $null }
Assert ($result.Code -eq 0 -and $null -ne $configJson) 'config status JSON is not polluted by dispatcher text'
Assert ($result.Out -notmatch 'Invoking script|Command result') 'JSON stdout excludes dispatcher banners'

$result = Invoke-Entry -Arguments @('config', 'status', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome, '-Platform', 'Codex,Antigravity', '-Json')
Assert ($result.Code -eq 0) 'config status routes comma-separated platforms'

$result = Invoke-Entry -Arguments @('config', 'status', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome, '-Platform', 'Codex', '-Platform', 'Antigravity', '-Json')
Assert ($result.Code -eq 0) 'config status routes repeated -Platform arguments without parameter binding error'

$result = Invoke-Entry -Arguments @('config', 'status', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome, '-Platform', 'Invalid', '-Json')
Assert ($result.Code -ne 0) 'config status rejects invalid platform'

$result = Invoke-Entry -Arguments @('profile', 'status', '-RepoRoot', $RepoRoot, '-ProjectRoot', $RepoRoot, '-Json')
$profileJson = $null
try { $profileJson = $result.Out | ConvertFrom-Json } catch { $profileJson = $null }
Assert ($result.Code -eq 0 -and $null -ne $profileJson) 'profile status routes and emits JSON'

$result = Invoke-Entry -Arguments @('config', 'pull', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome, '-DryRun')
Assert ($result.Code -eq 0) 'config pull routes through the explicit dry-run gate'

# Keep the original single-platform command lines while isolating their default home and backup root.
$savedUserProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = Join-Path ([IO.Path]::GetTempPath()) ('config-route-home-' + [guid]::NewGuid().ToString('N'))
    foreach ($route in @(@('push', 'Antigravity'), @('pull', 'Antigravity'), @('pull', 'Codex'))) {
        $result = Invoke-Entry -Arguments @('config', $route[0], '-Platform', $route[1], '-DryRun')
        Assert ($result.Code -eq 0 -and $result.Out -notmatch '找不到接受自变量|positional parameter|positional argument') "config $($route[0]) forwards a single $($route[1]) platform without character splatting"
    }
}
finally { $env:USERPROFILE = $savedUserProfile }

Write-Host 'unified CLI: deploy routes'
$result = Invoke-Entry -Arguments (@('sync', '-DryRun') + $deployArgs)
Assert ($result.Code -eq 0 -and $result.Out -match "Dry run for environment 'work'" -and $result.Out -match '=== skills ===' -and $result.Out -match '=== config ===') 'sync -DryRun routes to the combined deploy entry point with the -DryRun spelling consumed'
$result = Invoke-Entry -Arguments (@('env', 'deploy', 'test', '-DryRun') + $deployArgs)
Assert ($result.Code -eq 0 -and $result.Out -match "Dry run for environment 'test'" -and $result.Out -match '=== config ===') 'env deploy <name> -DryRun routes to the combined deploy entry point with -Environment <name>'
$result = Invoke-ParserCase -Arguments @('env', 'deploy', '-DryRun')
Assert ($result.Code -eq 1 -and $result.Out -match 'requires an environment name') 'env deploy without a name fails with guidance'
Assert (-not (Test-Path -LiteralPath (Join-Path $work 'state'))) 'deploy dry runs write no state'
foreach ($removed in @(@('env', 'activate', 'work'), @('env', 'status'), @('canonical', 'status'), @('live', 'recover'), @('backup'), @('plans'))) {
    $result = Invoke-ParserCase -Arguments $removed
    Assert ($result.Code -eq 1 -and $result.Out -match 'Unsupported') "removed route is rejected: $($removed -join ' ')"
}

Write-Host 'unified CLI: Antigravity routes and mode boundaries'
# Isolated dispatcher and strict stub: no native command or live root is used.
$pluginScripts = Join-Path $work 'plugin-router/scripts'
New-Item -ItemType Directory -Path $pluginScripts -Force | Out-Null
$pluginEntry = Join-Path $pluginScripts 'agent-dotfiles.ps1'
Copy-Item -LiteralPath $entry -Destination $pluginEntry
# The dispatcher now shares the deploy-state reader from repo-common.ps1; keep the
# isolated fixture self-contained so no real repository script is used.
Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/repo-common.ps1') -Destination $pluginScripts -Force
Set-TestFile -Path (Join-Path $pluginScripts 'config-pull.ps1') -Content 'param([switch] $Apply) Write-Output "child apply=$([bool]$Apply)"'
foreach ($case in @(@('-DryRun', 'False'), @('-Apply', 'True'))) {
    $result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('config', 'pull', $case[0])
    Assert ($result.Code -eq 0 -and $result.Out -match "child apply=$($case[1])") "config pull forwards $($case[0]) to the child"
}
$result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('config', 'pull', '-DryRun', '-Apply:$true')
Assert ($result.Code -ne 0 -and $result.Out -notmatch 'child apply=') 'a conflicting switch cannot activate the child during a preview'
Set-TestFile -Path (Join-Path $pluginScripts 'antigravity-plugins.ps1') -Content (@(
    '[CmdletBinding()]',
    'param([ValidateSet("Build","Status","Deploy")][string] $Action, [string] $RepoRoot, [string] $JsonPath, [string[]] $ExternalPlugin = @(), [switch] $Apply)',
    '[pscustomobject]@{ Action=$Action; RepoRoot=$RepoRoot; JsonPath=$JsonPath; ExternalPlugin=@($ExternalPlugin); Apply=[bool]$Apply } | ConvertTo-Json -Compress'
) -join "`n")
foreach ($action in @('build', 'status', 'deploy')) {
    $routeArgs = @('antigravity', $action, '-RepoRoot', $fixtureRepo, '-JsonPath', (Join-Path $work 'plugin-report.json'))
    if ($action -eq 'deploy') { $routeArgs += '-DryRun' }
    $result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments $routeArgs
    $payload = $null
    try { $payload = ($result.Out -split "`n" | Where-Object { $_.StartsWith('{') }) | ConvertFrom-Json } catch { $payload = $null }
    Assert ($result.Code -eq 0 -and $null -ne $payload -and $payload.Action -eq $action -and $payload.RepoRoot -eq $fixtureRepo -and $payload.JsonPath -eq (Join-Path $work 'plugin-report.json') -and -not $payload.Apply) "antigravity $action forwards Action and paths without a mutation switch"
}
$result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('antigravity', 'deploy', '-Apply')
Assert ($result.Code -eq 0 -and $result.Out -match '"Apply":true') 'antigravity deploy forwards explicit Apply only to its plugin entry'
$result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('antigravity', 'deploy', '-ExternalPlugin', 'unity', '-DryRun')
Assert ($result.Code -eq 0 -and $result.Out -match '"ExternalPlugin":\["unity"\]' -and $result.Out -match '"Apply":false') 'antigravity deploy forwards ExternalPlugin without Apply'
foreach ($badExt in @(@('status', '-ExternalPlugin', 'unity'), @('deploy', '-DryRun', '-ExternalPlugin'), @('deploy', '-DryRun', '-ExternalPlugin', 'bad,name'))) {
    $result = Invoke-ParserCase -ScriptPath $pluginEntry -Arguments (@('antigravity') + $badExt)
    Assert ($result.Code -eq 1 -and $result.Out -notmatch 'Invoking script') "antigravity rejects invalid ExternalPlugin route: $($badExt -join ' ')"
}
foreach ($action in @('build', 'status')) {
    foreach ($mode in @('-Apply', '-DryRun')) {
        $result = Invoke-ParserCase -ScriptPath $pluginEntry -Arguments @('antigravity', $action, $mode)
        Assert ($result.Code -eq 1 -and $result.Out -match 'accepts no' -and $result.Out -notmatch 'Invoking script') "antigravity $action rejects $mode before dispatch"
    }
}
foreach ($modes in @(@('-Apply', '-DryRun'), @('-Apply', '-Apply'), @('-DryRun', '-DryRun'))) {
    $useNative = ($modes -join ' ') -eq '-Apply -DryRun'
    $result = Invoke-ParserCase -ScriptPath $pluginEntry -Arguments (@('antigravity', 'deploy') + $modes) -Native:$useNative
    Assert ($result.Code -eq 1 -and $result.Out -match 'only one mode' -and $result.Out -notmatch 'Invoking script') 'antigravity deploy rejects multiple mode switches'
}
$result = Invoke-ParserCase -ScriptPath $pluginEntry -Arguments @('antigravity', 'deploy')
Assert ($result.Code -eq 1 -and $result.Out -match 'explicit -DryRun or -Apply' -and $result.Out -notmatch 'Invoking script') 'antigravity deploy rejects implicit mode'
foreach ($action in @('build', 'status', 'deploy')) {
    foreach ($badArgument in @('-Appl', '-App', '-Apply:$true', '-Apply:true', '-DryRun:$false', '-Repo', '-Json', 'extra-position')) {
        $routeArgs = @('antigravity', $action)
        if ($action -eq 'deploy') { $routeArgs += '-DryRun' }
        # The abbreviated name and the colon spelling keep the native -File boundary; the
        # alternate and positional spellings are rejected by the same parser branch.
        $useNative = $badArgument -in @('-Appl', '-Apply:$true')
        $result = Invoke-ParserCase -ScriptPath $pluginEntry -Arguments ($routeArgs + $badArgument) -Native:$useNative
        Assert ($result.Code -eq 1 -and $result.Out -match 'Unsupported antigravity argument|accepts no|only one mode' -and $result.Out -notmatch 'Invoking script') "antigravity $action rejects abbreviated, alternate or positional input: $badArgument"
    }
    $routeArgs = @('antigravity', $action, '-RepoRoot', '-Apply', '-JsonPath', '-DryRun')
    if ($action -eq 'deploy') { $routeArgs += '-DryRun' }
    $result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments $routeArgs
    $payload = $null
    try { $payload = ($result.Out -split "`n" | Where-Object { $_.StartsWith('{') }) | ConvertFrom-Json } catch { $payload = $null }
    Assert ($result.Code -eq 0 -and $null -ne $payload -and $payload.RepoRoot -eq '-Apply' -and $payload.JsonPath -eq '-DryRun' -and -not $payload.Apply) "antigravity $action preserves literal mode strings as path values without activation"
}
# -File may split colon boolean syntax before the script sees it; a lone
# alternate mode must also fail, not just conflict with an explicit dry run.
foreach ($mode in @('-Apply:$true', '-Apply:$false', '-Apply:true', '-DryRun:$false')) {
    $result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('antigravity', 'deploy', $mode)
    Assert ($result.Code -eq 1 -and $result.Out -match 'Unsupported antigravity argument' -and $result.Out -notmatch 'Invoking script') 'antigravity rejects a lone alternate mode spelling before dispatch'
}
foreach ($badArguments in @(
    @('-DryRun', '-RepoRoot'),
    @('-DryRun', '-JsonPath'),
    @('-DryRun', '-RepoRoot', '-JsonPath', 'report.json'),
    @('-DryRun', '-RepoRoot', 'one', '-RepoRoot', 'two'),
    @('-DryRun', '-JsonPath', 'one', '-JsonPath', 'two'),
    @('-RepoRoot', '-DryRun'),
    @('-JsonPath', '-Apply')
)) {
    $useNative = ($badArguments -join ' ') -eq '-DryRun -RepoRoot one -RepoRoot two'
    $result = Invoke-ParserCase -ScriptPath $pluginEntry -Arguments (@('antigravity', 'deploy') + $badArguments) -Native:$useNative
    Assert ($result.Code -eq 1 -and $result.Out -notmatch 'Invoking script') 'antigravity rejects missing path values, duplicate path options or value-only modes before dispatch'
}
$result = Invoke-ParserCase -ScriptPath $pluginEntry -Arguments @('antigravity', 'update', '-Apply')
Assert ($result.Code -eq 1 -and $result.Out -match 'Unsupported' -and $result.Out -notmatch 'Invoking script') 'antigravity exposes no unverified update route'

Write-Host 'unified CLI: MCP routes and mode boundaries'
Set-TestFile -Path (Join-Path $pluginScripts 'mcp-sync.ps1') -Content (@(
    '[CmdletBinding()]',
    'param([ValidateSet("Status","Deploy")][string] $Action = "Status", [string] $RepoRoot, [string] $HomeRoot, [string[]] $Platform = @(), [string[]] $Server = @(), [string] $BackupRoot, [string] $JsonPath, [switch] $Json, [switch] $Apply, [switch] $SkipSecretScan)',
    '[pscustomobject]@{ Action=$Action; RepoRoot=$RepoRoot; HomeRoot=$HomeRoot; Platform=@($Platform); Server=@($Server); BackupRoot=$BackupRoot; JsonPath=$JsonPath; Json=[bool]$Json; Apply=[bool]$Apply; SkipSecretScan=[bool]$SkipSecretScan } | ConvertTo-Json -Compress'
) -join "`n")
$result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('mcp', 'status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-Platform', 'Antigravity,Codex', '-Server', 'blender', '-Json')
$mcpPayload = $null
try { $mcpPayload = $result.Out | ConvertFrom-Json } catch { $mcpPayload = $null }
Assert ($result.Code -eq 0 -and $null -ne $mcpPayload -and $mcpPayload.Action -eq 'status' -and ($mcpPayload.Platform -join ',') -eq 'Antigravity,Codex' -and ($mcpPayload.Server -join ',') -eq 'blender' -and $mcpPayload.Json -and (-not $mcpPayload.Apply) -and $result.Out -notmatch 'Invoking script|Command result') 'mcp status -Json forwards filtered arguments without banners or mutation'

$result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('mcp', 'deploy', '-DryRun', '-Platform', 'Codex', '-Platform', 'Antigravity')
Assert ($result.Code -eq 0 -and $result.Out -match '"Action":"deploy"' -and $result.Out -match '"Apply":false' -and $result.Out -match '"Codex,Antigravity"') 'mcp deploy -DryRun forwards without Apply'

$result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('mcp', 'deploy', '-Apply', '-SkipSecretScan')
Assert ($result.Code -eq 0 -and $result.Out -match '"Apply":true' -and $result.Out -match '"SkipSecretScan":true') 'mcp deploy forwards explicit Apply only when requested'

foreach ($badMcp in @(
    @('status', '-DryRun'),
    @('status', '-Apply'),
    @('status', '-BackupRoot', $work),
    @('status', '-SkipSecretScan'),
    @('deploy'),
    @('deploy', '-DryRun', '-Apply'),
    @('deploy', '-Apply:$true'),
    @('deploy', '-DryRun', '-Platform', 'Invalid'),
    @('deploy', '-DryRun', '-Server', 'Bad Name'),
    @('deploy', '-DryRun', '-Repo'),
    @('deploy', '-DryRun', 'extra-pos')
)) {
    $useNative = ($badMcp -join ' ') -eq 'deploy -Apply:$true'
    $result = Invoke-ParserCase -ScriptPath $pluginEntry -Arguments (@('mcp') + $badMcp) -Native:$useNative
    Assert ($result.Code -eq 1 -and $result.Out -notmatch 'Invoking script') "mcp rejects invalid route arguments before dispatch: $($badMcp -join ' ')"
}

$result = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('mcp', 'deploy', '-RepoRoot', '-Apply', '-HomeRoot', '-DryRun', '-DryRun')
$mcpLiteral = $null
try { $mcpLiteral = ($result.Out -split "`n" | Where-Object { $_.StartsWith('{') }) | ConvertFrom-Json } catch { $mcpLiteral = $null }
Assert ($result.Code -eq 0 -and $null -ne $mcpLiteral -and $mcpLiteral.RepoRoot -eq '-Apply' -and $mcpLiteral.HomeRoot -eq '-DryRun' -and (-not $mcpLiteral.Apply)) 'mcp deploy preserves literal mode strings as path values without activation'

Write-Host 'unified CLI: top-level status command and aggregation'
foreach ($badStatus in @(
    @('-DryRun'),
    @('-Apply'),
    @('-DryRun:$true'),
    @('-Apply:true'),
    @('-DryRun', '-Apply'),
    @('-Unknown'),
    @('-RepoRoot'),
    @('-HomeRoot'),
    @('-StateRoot'),
    @('-Json', '-Json'),
    @('extra-positional')
)) {
    $useNative = ($badStatus -join ' ') -eq '-DryRun:$true'
    $result = Invoke-ParserCase -Arguments (@('status') + $badStatus) -Native:$useNative
    Assert ($result.Code -eq 1 -and ($result.Out -match 'accepts no -DryRun or -Apply mode|Unsupported status argument|Missing path value|Duplicate status argument') -and $result.Out -notmatch 'Invoking script') "status rejects invalid argument: $($badStatus -join ' ')"
}

$statusOut = Invoke-Entry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', (Join-Path $work 'missing-state'))
Assert ($statusOut.Code -ne 0 -and $statusOut.Out -match 'Error querying Antigravity plugins' -and $statusOut.Out -match 'Error querying MCP projections') 'status prints the partial report when fixture registries are missing'
Assert ($statusOut.Out -match '=== Unified Status ===') 'status output contains header'
Assert ($statusOut.Out -match '\[Environment\]' -and $statusOut.Out -match 'Available environments:') 'status output contains Environment section'
Assert ($statusOut.Out -match '\[Config Status\]') 'status output contains Config Status section'
Assert ($statusOut.Out -match '\[Antigravity Plugins\]') 'status output contains Antigravity Plugins section'
Assert ($statusOut.Out -match '\[MCP Projections\]') 'status output contains MCP Projections section'
Assert ($statusOut.Out -notmatch 'Invoking script|Command result') 'status human-readable emits no wrapper invocation banners'

Set-TestFile -Path (Join-Path $fixtureRepo 'harness-source/mcp/servers.psd1') -Content @'
@{ SchemaVersion = 1; Servers = @(
    @{ Name = 'local'; Platforms = @('Antigravity'); Enabled = $true; Transport = 'stdio'; Command = 'fixture'; Env = @{ MODE = 'declared-mode' } }
    @{ Name = 'remote'; Platforms = @('Antigravity'); Enabled = $true; Transport = 'streamable-http'; Url = 'https://example.invalid/mcp'; Headers = @{ 'X-Fixture' = 'declared-header' } }
    @{ Name = 'matching'; Platforms = @('Antigravity'); Enabled = $true; Transport = 'stdio'; Command = 'fixture' }
) }
'@
Set-TestFile -Path (Join-Path $fakeHome '.gemini/config/mcp_config.json') -Content @'
{"mcpServers":{
    "local":{"command":"fixture","args":[],"env":{"MODE":"private-fixture-mode"}},
    "remote":{"url":"https://example.invalid/mcp","headers":{"X-Fixture":"private-fixture-header"}},
    "matching":{"command":"fixture","args":[]}
}}
'@
$reportPath = Join-Path $work 'mcp-report.json'
# This fixture declares only Antigravity servers. Block the unused Codex target before any native probe.
New-Item -ItemType Directory -Path (Join-Path $fakeHome '.codex/config.toml') -Force | Out-Null
$mcpResult = Invoke-Entry -Arguments @('mcp', 'status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-Platform', 'Antigravity', '-Json', '-JsonPath', $reportPath)
Assert ($mcpResult.Code -eq 0) 'mcp status emits stdout and file diagnostics for drifted entries'

$jsonResult = Invoke-Entry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', (Join-Path $work 'missing-state'), '-Json')
Assert ($jsonResult.Code -ne 0) 'status JSON signals the unavailable Antigravity plugin query'
Assert ($jsonResult.Out -notmatch 'Invoking script|Command result') 'status -Json emits zero wrapper banners'
$parsedStatus = $null
try { $parsedStatus = ConvertFrom-Json -InputObject $jsonResult.Out } catch { $parsedStatus = $null }
Assert ($null -ne $parsedStatus) 'status -Json produces valid parseable JSON'
Assert ($parsedStatus.SchemaVersion -eq 1) 'status JSON contains SchemaVersion = 1'
Assert ($null -ne $parsedStatus.Environment -and $parsedStatus.Environment.Available -contains 'work') 'status JSON contains Environment section'
Assert ($null -ne $parsedStatus.Config -and ($parsedStatus.Config -is [array] -or $null -ne $parsedStatus.Config.Error)) 'status JSON contains Config section'
Assert ($parsedStatus.Antigravity.Error -and $parsedStatus.Summary.Antigravity -eq 'error') 'status JSON identifies the failed plugin query'
Assert ($null -ne $parsedStatus.Mcp) 'status JSON contains Mcp section'
Assert ($null -ne $parsedStatus.Summary -and $null -ne $parsedStatus.Summary.Environment -and $null -ne $parsedStatus.Summary.Config -and $null -ne $parsedStatus.Summary.Antigravity -and $null -ne $parsedStatus.Summary.Mcp) 'status JSON contains Summary section with all 4 subsystems'

foreach ($output in @($mcpResult.Out, [IO.File]::ReadAllText($reportPath), $jsonResult.Out)) {
    Assert ($output -notmatch 'private-fixture-mode|private-fixture-header|declared-mode|declared-header') 'entire JSON output omits live and declared MCP values'
    $report = $output | ConvertFrom-Json
    if ($report.PSObject.Properties['Mcp']) { $report = $report.Mcp }
    $local = $report.Items | Where-Object Server -eq 'local'
    $remote = $report.Items | Where-Object Server -eq 'remote'
    $matching = $report.Items | Where-Object Server -eq 'matching'
    Assert ($local.Platform -eq 'Antigravity' -and $local.Action -eq 'update' -and $local.Changes -contains '~ /env/MODE') 'MCP report identifies the environment field that drifted'
    Assert ($remote.Platform -eq 'Antigravity' -and $remote.Action -eq 'update' -and $remote.Changes -contains '~ /headers/X-Fixture') 'MCP report identifies the header field that drifted'
    Assert ($matching.Action -eq 'unchanged' -and $report.Summary.unchanged -eq 1 -and $report.Summary.update -eq 2) 'MCP report distinguishes matching and drifted entries'
}

# Mock stub aggregation tests in isolated pluginScripts
Set-TestFile -Path (Join-Path $pluginScripts 'config-status.ps1') -Content (@(
    '[CmdletBinding()]',
    'param([string] $RepoRoot, [string] $HomeRoot, [string[]] $Platform, [switch] $Json)',
    '@(',
    '  [pscustomobject]@{ Platform="Codex"; Item="AGENTS.md"; Status="in-sync"; Detail="mock-block" },',
    '  [pscustomobject]@{ Platform="Antigravity"; Item="AGENTS.md"; Status="differs"; Detail="mock-block" }',
    ') | ConvertTo-Json -Depth 5'
) -join "`n")

Set-TestFile -Path (Join-Path $pluginScripts 'antigravity-plugins.ps1') -Content (@(
    '[CmdletBinding()]',
    'param([ValidateSet("Build","Status","Deploy")][string] $Action, [string] $RepoRoot, [string] $StateRoot, [string] $JsonPath, [string[]] $ExternalPlugin = @(), [switch] $Apply)',
    'if ($Action -eq "Status") {',
    '  [pscustomobject]@{',
    '    SchemaVersion = 1;',
    '    Action = "update";',
    '    Reason = "version-upgrade";',
    '    ApplyRequirement = "build-with-current-agy-before-apply";',
    '    NextStep = "Build with the current agy before Apply. Run antigravity build, then repeat antigravity deploy -DryRun.";',
    '    Name = "ai-agent-dotfiles";',
    '    Version = "0.4.0";',
    '    ExternalExpectations = @(',
    '      [pscustomobject]@{ Name = "unity"; Action = "unchanged"; Reason = "mock-external" }',
    '    )',
    '  } | ConvertTo-Json -Depth 5',
    '  return',
    '}',
    '[pscustomobject]@{ Action=$Action; RepoRoot=$RepoRoot; JsonPath=$JsonPath; ExternalPlugin=@($ExternalPlugin); Apply=[bool]$Apply } | ConvertTo-Json -Compress'
) -join "`n")

Set-TestFile -Path (Join-Path $pluginScripts 'mcp-sync.ps1') -Content (@(
    '[CmdletBinding()]',
    'param([ValidateSet("Status","Deploy")][string] $Action = "Status", [string] $RepoRoot, [string] $HomeRoot, [string[]] $Platform = @(), [string[]] $Server = @(), [string] $BackupRoot, [string] $JsonPath, [switch] $Json, [switch] $Apply, [switch] $SkipSecretScan)',
    'if ($Action -eq "Status") {',
    '  [pscustomobject]@{',
    '    SchemaVersion = 1;',
    '    Platforms = @("Antigravity", "Codex");',
    '    Servers = @("blender");',
    '    Summary = [pscustomobject]@{ add = 0; update = 1; unchanged = 1; blocked = 0 };',
    '    Items = @(',
    '      [pscustomobject]@{ Platform="Antigravity"; Server="blender"; Action="update"; Reason="mock-diff" },',
    '      [pscustomobject]@{ Platform="Codex"; Server="blender"; Action="unchanged"; Reason="mock-match" }',
    '    )',
    '  } | ConvertTo-Json -Depth 5',
    '  return',
    '}',
    '[pscustomobject]@{ Action=$Action; RepoRoot=$RepoRoot; HomeRoot=$HomeRoot; Platform=@($Platform); Server=@($Server); BackupRoot=$BackupRoot; JsonPath=$JsonPath; Json=[bool]$Json; Apply=[bool]$Apply; SkipSecretScan=[bool]$SkipSecretScan } | ConvertTo-Json -Compress'
) -join "`n")

Copy-Item -LiteralPath $entry -Destination $pluginEntry -Force

$mockResult = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', (Join-Path $work 'missing-state'), '-Json')
Assert ($mockResult.Code -eq 0 -and $mockResult.Out -notmatch 'Invoking script|Command result') 'mock stub status -Json exits 0 without banners'
$mockJson = $null
try { $mockJson = ConvertFrom-Json -InputObject $mockResult.Out } catch { $mockJson = $null }
Assert ($null -ne $mockJson) 'mock stub status produces valid JSON'
Assert ($mockJson.Config.Count -eq 2) 'mock stub config items merged correctly'
Assert ($mockJson.Antigravity.Name -eq 'ai-agent-dotfiles') 'mock stub Antigravity report merged correctly'
Assert ($mockJson.Mcp.Summary.update -eq 1) 'mock stub MCP summary merged correctly'
Assert ($mockJson.Summary.Config.'in-sync' -eq 1 -and $mockJson.Summary.Config.differs -eq 1) 'mock stub Config summary counted correctly'
Assert ($mockJson.Summary.Antigravity -eq 'update' -and $mockJson.Antigravity.ApplyRequirement -eq 'build-with-current-agy-before-apply') 'mock stub Antigravity summary and build requirement matched'
Assert ($mockJson.Summary.Mcp.update -eq 1 -and $mockJson.Summary.Mcp.unchanged -eq 1) 'mock stub Mcp summary matched'

$mockHuman = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', (Join-Path $work 'missing-state'))
Assert ($mockHuman.Code -eq 0) 'mock stub human-readable status exits 0'
Assert ($mockHuman.Out -match '=== Unified Status ===') 'mock stub human-readable contains header'
Assert ($mockHuman.Out -match 'mock-block') 'mock stub human-readable contains config detail'
Assert ($mockHuman.Out -match 'version-upgrade') 'mock stub human-readable contains antigravity plugin reason'
Assert ($mockHuman.Out -match 'build with the current agy before Apply.*antigravity build.*deploy -DryRun') 'status renders actionable current-agy build guidance'
Assert ($mockHuman.Out -match 'External: unity\s+action=unchanged') 'status displays a single external plugin'
Assert ($mockHuman.Out -match 'mock-diff') 'mock stub human-readable contains mcp projection reason'

Set-TestFile -Path (Join-Path $pluginScripts 'antigravity-plugins.ps1') -Content ((Get-Content -LiteralPath (Join-Path $pluginScripts 'antigravity-plugins.ps1') -Raw) -replace 'ApplyRequirement = "build-with-current-agy-before-apply"', 'ApplyRequirement = "none"')
$readyHuman = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', (Join-Path $work 'missing-state'))
Assert ($readyHuman.Code -eq 0 -and $readyHuman.Out -match 'ready for reviewed Apply; no rebuild is required') 'status renders a ready update without rebuild guidance'
Assert ($readyHuman.Out -notmatch 'build with the current agy') 'ready update does not tell the operator to rebuild'

Write-Host 'unified CLI: status deploy-state ownership failures'
# With every other section healthy, an actually unreadable or invalid deploy record must
# make the aggregate nonzero while a merely absent or legacy record stays normal.
$statusStateRoot = Join-Path $work 'status-state'
New-Item -ItemType Directory -Path $statusStateRoot -Force | Out-Null
$statusStatePath = Join-Path $statusStateRoot 'deployed-skills.json'
Set-Content -LiteralPath $statusStatePath -Encoding utf8 -Value '{"Environment":"work","Codex":"alpha"}'
$scalarStatus = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', $statusStateRoot, '-Json')
$scalarJson = $null
try { $scalarJson = ConvertFrom-Json -InputObject $scalarStatus.Out } catch { $scalarJson = $null }
Assert ($scalarStatus.Code -ne 0 -and $null -ne $scalarJson -and $scalarJson.Environment.Reason -eq 'invalid-state' -and $scalarJson.Environment.Failed) 'scalar Codex ownership fails the aggregate status'
Assert ($scalarJson.Summary.Config.'in-sync' -eq 1 -and $scalarJson.Summary.Antigravity -eq $mockJson.Summary.Antigravity -and $scalarJson.Summary.Mcp.update -eq 1) 'the state failure preserves the other sections'
$scalarHuman = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', $statusStateRoot)
Assert ($scalarHuman.Code -ne 0 -and $scalarHuman.Out -match 'Deploy state read failed: invalid-state') 'human status explains the fixed failure reason'
Assert ($scalarHuman.Out -match 'mock-block' -and $scalarHuman.Out -match 'mock-diff') 'human status keeps the other sections visible'
foreach ($badState in @('{invalid', '{"Environment":"work"}', '{"Environment":"work","Codex":["alpha",5]}')) {
    Set-Content -LiteralPath $statusStatePath -Encoding utf8 -Value $badState
    $badStatus = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', $statusStateRoot, '-Json')
    $badJson = $null
    try { $badJson = ConvertFrom-Json -InputObject $badStatus.Out } catch { $badJson = $null }
    $expectedReason = if ($badState -eq '{invalid') { 'invalid-json' } else { 'invalid-state' }
    Assert ($badStatus.Code -ne 0 -and $badJson.Environment.Reason -eq $expectedReason) "shape failure reports its fixed reason: $expectedReason"
}
Set-Content -LiteralPath $statusStatePath -Encoding utf8 -Value '{"Codex":["alpha"]}'
$legacyStatus = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', $statusStateRoot, '-Json')
$legacyJson = $null
try { $legacyJson = ConvertFrom-Json -InputObject $legacyStatus.Out } catch { $legacyJson = $null }
Assert ($legacyStatus.Code -eq 0 -and $legacyJson.Environment.Reason -eq 'missing-environment' -and -not $legacyJson.Environment.Failed) 'legacy valid Codex array without Environment remains normal'
$fileRootStatus = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', $fileStateRoot, '-Json')
$fileRootJson = $null
try { $fileRootJson = ConvertFrom-Json -InputObject $fileRootStatus.Out } catch { $fileRootJson = $null }
Assert ($fileRootStatus.Code -ne 0 -and $fileRootJson.Environment.Reason -eq 'state-root-not-directory' -and $fileRootJson.Environment.Failed) 'file-shaped StateRoot fails status with its fixed reason'
$dirRootStatus = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', $dirStateRoot, '-Json')
$dirRootJson = $null
try { $dirRootJson = ConvertFrom-Json -InputObject $dirRootStatus.Out } catch { $dirRootJson = $null }
Assert ($dirRootStatus.Code -ne 0 -and $dirRootJson.Environment.Reason -eq 'state-path-is-directory' -and $dirRootJson.Environment.Failed) 'directory-shaped state file fails status with its fixed reason'
Assert ($fileRootStatus.Out -notmatch [regex]::Escape($fileStateRoot) -and $dirRootStatus.Out -notmatch [regex]::Escape($dirStateRoot)) 'status reports no private state paths'

$badRootArgs = @('status', '-RepoRoot', (Join-Path $work 'missing-repo'), '-HomeRoot', $fakeHome, '-StateRoot', (Join-Path $work 'missing-state'), '-Json')
$badRoot = Invoke-Entry -Arguments $badRootArgs
$failed = $badRoot.Out | ConvertFrom-Json
Assert ($badRoot.Code -ne 0 -and $failed.Environment.Error -and $failed.Config.Error -and $failed.Antigravity.Error -and $failed.Mcp.Error) 'bad RepoRoot returns nonzero and a parseable report of each unavailable section'
Assert ($null -eq $failed.Summary.Config -and $null -eq $failed.Summary.Mcp) 'unavailable counts are distinct from a successful empty inventory'

Set-TestFile -Path (Join-Path $pluginScripts 'config-status.ps1') -Content "Write-Output 'invalid child JSON'"
$partial = Invoke-TestProcess -ScriptPath $pluginEntry -Arguments @('status', '-RepoRoot', $fixtureRepo, '-HomeRoot', $fakeHome, '-StateRoot', (Join-Path $work 'missing-state'), '-Json')
$damaged = $partial.Out | ConvertFrom-Json
Assert ($partial.Code -ne 0 -and $damaged.Config.Error -and $null -eq $damaged.Summary.Config -and $damaged.Summary.Mcp.update -eq 1) 'malformed child output preserves other summaries and returns nonzero'

Write-Host 'unified CLI: apply gates'
foreach ($commandArgs in @(
    @('config', 'pull', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome),
    @('config', 'push', '-RepoRoot', $RepoRoot, '-HomeRoot', $fakeHome),
    @('profile', 'apply', '-RepoRoot', $RepoRoot, '-ProjectRoot', $RepoRoot),
    @('sync'),
    @('env', 'deploy', 'work')
)) {
    $useNative = ($commandArgs -join ' ') -eq 'sync'
    $result = Invoke-ParserCase -Arguments $commandArgs -Native:$useNative
    Assert ($result.Code -eq 1 -and $result.Out -match 'explicit -DryRun or -Apply') "rejects implicit apply: $($commandArgs -join ' ')"
}
$result = Invoke-ParserCase -Arguments @('sync', '-DryRun', '-Apply')
Assert ($result.Code -eq 1 -and $result.Out -match 'only one mode') 'sync rejects both modes'

$result = Invoke-Entry -Arguments @('skills', 'promote')
Assert ($result.Code -eq 1 -and $result.Out -match 'explicit -DryRun or -Apply') 'rejects implicit skill promotion'
foreach ($commandArgs in @(@('merge'), @('inventory'), @('analyze'), @('skills', 'merge'), @('skills', 'normalize'))) {
    $useNative = ($commandArgs -join ' ') -eq 'skills merge'
    $result = Invoke-ParserCase -Arguments $commandArgs -Native:$useNative
    Assert ($result.Code -eq 1 -and $result.Out -match 'Unsupported') "removed skills route is unsupported: $($commandArgs -join ' ')"
}

Write-Host ''
Write-Host ("agent-dotfiles CLI tests: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) {
    Write-Host "Workspace kept for inspection: $work" -ForegroundColor Yellow
    exit 1
}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
exit 0
