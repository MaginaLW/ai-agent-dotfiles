#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TemplateId,
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..\..'),
    [string] $HomeRoot = $env:USERPROFILE,
    [string] $ClaudeCommand = 'claude',
    [string] $PlanPath,
    [string] $JsonPath,
    [switch] $DryRun,
    [switch] $Apply,
    [switch] $Remove,
    [string] $BackupRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'This script requires PowerShell 7 or newer. Run it with pwsh.' }
. (Join-Path $PSScriptRoot '..\..\scripts\mcp-common.ps1')

if ($DryRun -eq $Apply) { throw 'Specify exactly one of -DryRun or -Apply.' }
if ([string]::IsNullOrWhiteSpace($PlanPath)) { throw '-PlanPath is required for both dry-run and apply.' }
if ([string]::IsNullOrWhiteSpace($HomeRoot)) { throw 'HomeRoot must not be empty.' }
$repo = Resolve-McpRepoRoot -RepoRoot $RepoRoot
$repoFull = [System.IO.Path]::GetFullPath($repo)
$homeFull = [System.IO.Path]::GetFullPath($HomeRoot)
if ($homeFull.Equals($repoFull, [System.StringComparison]::OrdinalIgnoreCase) -or
    $homeFull.StartsWith($repoFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'HomeRoot must be outside the repository; MCP evidence must remain repo-external.'
}
$template = Get-McpTemplate -RepoRoot $repo -TemplateId $TemplateId
$envState = Get-McpEnvState -Template $template

function Invoke-McpCli {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $command = Get-Command $ClaudeCommand -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw "Claude CLI was not found: $ClaudeCommand" }
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& $command.Source @Arguments 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previousErrorAction }
    return [pscustomobject]@{ Code = $code; Output = @($output | ForEach-Object { [string]$_ }) }
}

function Get-McpServerState {
    $probe = Invoke-McpCli -Arguments @('mcp', 'get', $template.Id, '--scope', $template.Scope, '--json')
    $text = ($probe.Output -join "`n")
    $hash = Get-McpValueHash -Value $text
    if ($probe.Code -eq 0) { return [pscustomobject]@{ Exists = $true; Hash = $hash; Raw = $text } }
    if ($text -match '(?i)not found|does not exist|unknown server|no such') { return [pscustomobject]@{ Exists = $false; Hash = $null; Raw = $null } }
    throw "Claude CLI MCP state probe failed with exit code $($probe.Code)."
}

$server = Get-McpServerState
$action = if ($Remove) { if ($server.Exists) { 'remove' } else { 'noop' } } elseif ($server.Exists) { 'update' } else { 'add' }
$plan = [ordered]@{
    SchemaVersion = 1
    PlanKind = 'mcp-operation'
    TemplateId = $template.Id
    TemplateHash = $template.Hash
    Action = $action
    Scope = $template.Scope
    Command = $template.Command
    Args = @($template.Args)
    EnvironmentVariables = @($template.RequiredEnv)
    EnvironmentState = $envState.States
    MissingEnvironmentVariables = @($envState.Missing)
    CurrentServerExists = [bool]$server.Exists
    CurrentServerHash = $server.Hash
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
}
$plan['PlanHash'] = ConvertTo-McpPlanHash -Plan ([pscustomobject]$plan)

if ($DryRun) {
    Write-McpJson -Object ([pscustomobject]$plan) -Path $PlanPath
    $summary = [ordered]@{ SchemaVersion = 1; Result = 'DRY-RUN'; TemplateId = $template.Id; Action = $action; PlanHash = $plan.PlanHash; MissingEnvironmentVariables = @($envState.Missing) }
    Write-Output "MCP dry-run: template=$($template.Id) action=$action planHash=$($plan.PlanHash)"
    if ($envState.Missing.Count -gt 0) { Write-Output "Missing environment variables: $($envState.Missing -join ', ')" }
    if ($JsonPath) { Write-McpJson -Object ([pscustomobject]$summary) -Path $JsonPath }
    exit 0
}

$saved = if (Test-Path -LiteralPath $PlanPath -PathType Leaf) { Get-Content -Raw -LiteralPath $PlanPath | ConvertFrom-Json } else { $null }
if ($null -eq $saved -or [string]$saved.PlanHash -ne (ConvertTo-McpPlanHash -Plan $saved)) { throw 'MCP plan hash is invalid or the plan has drifted. Re-run dry-run.' }
foreach ($property in @('TemplateId', 'TemplateHash', 'Action', 'CurrentServerExists', 'CurrentServerHash')) {
    if ([string]$saved.$property -ne [string]$plan[$property]) { throw "MCP plan drift detected in $property. Re-run dry-run." }
}
if ((ConvertTo-Json $saved.EnvironmentState -Depth 10 -Compress) -ne (ConvertTo-Json $plan.EnvironmentState -Depth 10 -Compress)) {
    throw 'MCP plan drift detected in environment variable presence/hash state. Re-run dry-run.'
}
if ($saved.Action -eq 'noop') { Write-Output "MCP already absent: $($template.Id)"; exit 0 }
if (@($envState.Missing).Count -gt 0 -and $saved.Action -ne 'remove') { throw "Required environment variables are missing: $($envState.Missing -join ', ')" }

$backupRootResolved = if ($BackupRoot) { $BackupRoot } else { Join-Path $HomeRoot '.ai-agent-dotfiles-mcp-backups' }
$backupRootResolved = [System.IO.Path]::GetFullPath($backupRootResolved)
if ($backupRootResolved.Equals($repoFull, [System.StringComparison]::OrdinalIgnoreCase) -or
    $backupRootResolved.StartsWith($repoFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'BackupRoot must remain outside the repository.'
}
$backupDir = Join-Path $backupRootResolved ("mcp-{0}-{1}" -f $template.Id, (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff'))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$backupMeta = [ordered]@{
    SchemaVersion = 1
    TemplateId = $template.Id
    Action = $saved.Action
    BeforeExists = [bool]$server.Exists
    BeforeHash = $server.Hash
    Note = 'Raw CLI state is kept only in this repo-external backup for human recovery; it is never printed or included in the plan/report.'
}
if ($server.Exists) { [System.IO.File]::WriteAllText((Join-Path $backupDir 'before-cli-state.txt'), $server.Raw, [System.Text.UTF8Encoding]::new($false)) }
Write-McpJson -Object $backupMeta -Path (Join-Path $backupDir 'operation.json')

$stage = 'started'
try {
    if ($saved.Action -eq 'remove') {
        $result = Invoke-McpCli -Arguments @('mcp', 'remove', $template.Id, '--scope', $template.Scope)
        if ($result.Code -ne 0) { throw "Claude CLI MCP remove failed with exit code $($result.Code)." }
        $stage = 'removed'
    }
    elseif ($saved.Action -eq 'update') {
        $removeResult = Invoke-McpCli -Arguments @('mcp', 'remove', $template.Id, '--scope', $template.Scope)
        if ($removeResult.Code -ne 0) { throw "Claude CLI MCP update pre-remove failed with exit code $($removeResult.Code)." }
        $stage = 'removed-for-update'
        $addArgs = @('mcp', 'add', '--scope', $template.Scope, '--transport', 'stdio')
        foreach ($name in @($template.RequiredEnv)) { $addArgs += @('--env', "$name=$([Environment]::GetEnvironmentVariable($name))") }
        $addArgs += @($template.Id, '--', $template.Command) + @($template.Args)
        $addResult = Invoke-McpCli -Arguments $addArgs
        if ($addResult.Code -ne 0) { throw "Claude CLI MCP update add failed with exit code $($addResult.Code)." }
        $stage = 'updated'
    }
    else {
        $addArgs = @('mcp', 'add', '--scope', $template.Scope, '--transport', 'stdio')
        foreach ($name in @($template.RequiredEnv)) { $addArgs += @('--env', "$name=$([Environment]::GetEnvironmentVariable($name))") }
        $addArgs += @($template.Id, '--', $template.Command) + @($template.Args)
        $addResult = Invoke-McpCli -Arguments $addArgs
        if ($addResult.Code -ne 0) { throw "Claude CLI MCP add failed with exit code $($addResult.Code)." }
        $stage = 'added'
    }
}
catch {
    Write-McpJson -Object ([ordered]@{ SchemaVersion = 1; TemplateId = $template.Id; Action = $saved.Action; Stage = $stage; Result = 'PARTIAL_OR_FAILED'; BeforeHash = $server.Hash; RecoveryEvidence = 'before-cli-state.txt'; Error = $_.Exception.Message }) -Path (Join-Path $backupDir 'failure.json')
    throw
}

Write-McpJson -Object ([ordered]@{ SchemaVersion = 1; TemplateId = $template.Id; Action = $saved.Action; Stage = $stage; Result = 'PASS'; BeforeHash = $server.Hash }) -Path (Join-Path $backupDir 'result.json')
Write-Output "MCP apply complete: template=$($template.Id) action=$($saved.Action) backup=$([System.IO.Path]::GetFileName($backupDir))"
if ($JsonPath) { Write-McpJson -Object ([ordered]@{ SchemaVersion = 1; Result = 'PASS'; TemplateId = $template.Id; Action = $saved.Action; BackupReference = [System.IO.Path]::GetFileName($backupDir) }) -Path $JsonPath }
