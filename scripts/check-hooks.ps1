#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
$claudeSettings = Join-Path $RepoRoot 'claude/settings.json'
$codexConfig = Join-Path $RepoRoot 'codex/config.toml'

Write-Host 'Hook inspection only. No hooks will be activated.'

if (Test-Path -LiteralPath $claudeSettings) {
    try {
        $settings = Get-Content -LiteralPath $claudeSettings -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties.Name -contains 'hooks') {
            Write-Host 'Claude hooks found in claude/settings.json:'
            $settings.hooks | ConvertTo-Json -Depth 20
        }
        else {
            Write-Host 'Claude hooks: none found.'
        }
    }
    catch {
        Write-Host "WARN: Could not parse claude/settings.json: $($_.Exception.Message)"
    }
}
else {
    Write-Host 'Claude hooks: claude/settings.json not present.'
}

if (Test-Path -LiteralPath $codexConfig) {
    $hookLines = Select-String -LiteralPath $codexConfig -Pattern '^\s*\[.*hooks?.*\]|\bhooks?\b|after_agent_turn|before_agent_turn' -CaseSensitive:$false
    if ($hookLines) {
        Write-Host 'Codex hook-like lines found in codex/config.toml:'
        $hookLines | ForEach-Object {
            Write-Host "$($_.LineNumber): $($_.Line)"
        }
    }
    else {
        Write-Host 'Codex hooks: none found.'
    }
}
else {
    Write-Host 'Codex hooks: codex/config.toml not present.'
}

$policy = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'scripts/live-safety-policy.psd1')
Write-Host "Live safety protocol: version $($policy.ProtocolVersion), release state $($policy.ReleaseState)."
. (Join-Path $PSScriptRoot 'approved-runner-common.ps1')
$runnerContext = Get-RunnerStorageContext -RepoRoot $RepoRoot
$hooksDir = ((& git -C $RepoRoot rev-parse --path-format=absolute --git-path hooks) | Select-Object -First 1).Trim()
$expectedGitHooks = @('post-merge', 'post-checkout', 'post-rewrite')
if (Test-Path -LiteralPath $runnerContext.ApprovedStatePath -PathType Leaf) {
    try {
        $runnerState = Get-ApprovedRunnerState -RepoRoot $RepoRoot
        Write-Host "Approved runner hash: $($runnerState.ToolchainPolicyHash)"
    }
    catch { Write-Host 'runner-review-required: approved runner state is invalid.' }
}
else {
    Write-Host 'runner-review-required: approved runner state is missing.'
}
Write-Host "Pending preview namespace: $($runnerContext.PendingEventsRoot)"

foreach ($hookName in $expectedGitHooks) {
    $hookPath = Join-Path $hooksDir $hookName
    if (-not (Test-Path -LiteralPath $hookPath)) {
        Write-Host "Git hook ${hookName}: not installed."
        continue
    }

    $content = Get-Content -LiteralPath $hookPath -Raw
    if ($content -match 'scripts/auto-sync-after-git\.ps1') {
        Write-Host "Git hook ${hookName}: runner-review-required (executes checkout code)."
    }
    elseif ($content -match 'approved-hook-entry\.ps1') {
        Write-Host "Git hook ${hookName}: installed -> approved preview-only runner."
    }
    else {
        Write-Host "Git hook ${hookName}: installed but not recognized."
    }
}
