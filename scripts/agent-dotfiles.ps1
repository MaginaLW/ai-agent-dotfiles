#requires -Version 7.0
<#
.SYNOPSIS
    Provides a single command entry point for repository maintenance scripts.

.DESCRIPTION
    Dispatches a supported subcommand to the existing repository script in a
    separate PowerShell process. This wrapper does not implement build, scan,
    backup, or sync behavior itself. Arguments after the subcommand are passed
    through unchanged and are not echoed by the wrapper.

.PARAMETER Command
    One of: doctor, build, scan, backup, sync, inventory, analyze, merge,
    plugin, or env.

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 doctor -SkipSecretsScan

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 sync -DryRun

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 env list

.NOTES
    The sync subcommand requires exactly one explicit mode: -DryRun or -Apply.
    Apply is never selected or added by default.
    The env subcommand requires a sub-action: list, status, build, or activate.
    The env activate sub-action requires exactly one explicit mode: -DryRun or
    -Apply, mirroring sync.
#>
param(
    [Parameter(Position = 0)]
    [string] $Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [object[]] $RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Usage {
    Write-Host 'Usage: pwsh -File scripts/agent-dotfiles.ps1 <command> [arguments]'
    Write-Host 'Commands: doctor, build, scan, backup, sync, inventory, analyze, merge, plugin, env'
    Write-Host 'Sync requires exactly one explicit mode: -DryRun or -Apply.'
    Write-Host 'Run sync in dry-run mode first: scripts/agent-dotfiles.ps1 sync -DryRun'
    Write-Host 'Env requires a sub-action (list, status, build, activate): scripts/agent-dotfiles.ps1 env list'
    Write-Host 'Env activate requires exactly one explicit mode: -DryRun or -Apply.'
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-Error 'A command is required.' -ErrorAction Continue
    Write-Usage
    exit 1
}

$commandMap = @{
    doctor = 'doctor.ps1'
    build  = 'build-skills.ps1'
    scan   = 'scan-secrets.ps1'
    backup = 'backup.ps1'
    sync   = 'sync.ps1'
    inventory = 'inventory-skills.ps1'
    analyze = 'analyze-skills.ps1'
    merge = 'auto-merge-skills.ps1'
    plugin = 'sync-openclaw-plugins.ps1'
}

$envCommandMap = @{
    list     = 'list-harness-env.ps1'
    status   = 'status-harness-env.ps1'
    build    = 'build-harness-env.ps1'
    activate = 'activate-harness-env.ps1'
}

$normalizedCommand = $Command.ToLowerInvariant()
if ($normalizedCommand -ne 'env' -and -not $commandMap.ContainsKey($normalizedCommand)) {
    Write-Error "Unsupported command: $Command" -ErrorAction Continue
    Write-Usage
    exit 1
}

$forwardedArguments = @($RemainingArguments)
if ($normalizedCommand -eq 'env') {
    if ($forwardedArguments.Count -eq 0 -or $null -eq $forwardedArguments[0]) {
        Write-Error 'The env command requires a sub-action: list, status, build, or activate.' -ErrorAction Continue
        Write-Usage
        exit 1
    }

    $envAction = ([string]$forwardedArguments[0]).ToLowerInvariant()
    if (-not $envCommandMap.ContainsKey($envAction)) {
        Write-Error "Unsupported env sub-action: $($forwardedArguments[0])" -ErrorAction Continue
        Write-Usage
        exit 1
    }

    $targetScriptName = $envCommandMap[$envAction]
    $forwardedArguments = @($forwardedArguments | Select-Object -Skip 1)

    if ($envAction -eq 'activate') {
        $hasDryRun = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-DryRun' }).Count -gt 0
        $hasApply = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-Apply' }).Count -gt 0

        if (-not $hasDryRun -and -not $hasApply) {
            Write-Error 'The env activate command requires an explicit -DryRun or -Apply mode. Run -DryRun first.' -ErrorAction Continue
            exit 1
        }
        if ($hasDryRun -and $hasApply) {
            Write-Error 'The env activate command accepts only one mode. Specify -DryRun or -Apply, not both.' -ErrorAction Continue
            exit 1
        }
    }
}
else {
    $targetScriptName = $commandMap[$normalizedCommand]
}

if ($normalizedCommand -eq 'sync') {
    $hasDryRun = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-DryRun' }).Count -gt 0
    $hasApply = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-Apply' }).Count -gt 0

    if (-not $hasDryRun -and -not $hasApply) {
        Write-Error 'The sync command requires an explicit -DryRun or -Apply mode. Run -DryRun first.' -ErrorAction Continue
        exit 1
    }
    if ($hasDryRun -and $hasApply) {
        Write-Error 'The sync command accepts only one mode. Specify -DryRun or -Apply, not both.' -ErrorAction Continue
        exit 1
    }
}

$targetScript = Join-Path $PSScriptRoot $targetScriptName
if (-not (Test-Path -LiteralPath $targetScript -PathType Leaf)) {
    Write-Error "Target script is missing: $targetScript" -ErrorAction Continue
    exit 1
}

$pwshCommands = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
if ($pwshCommands.Count -eq 0) {
    Write-Error 'PowerShell 7 executable (pwsh) is not available on PATH.' -ErrorAction Continue
    exit 1
}
$pwshPath = $pwshCommands[0].Source

Write-Host "Invoking script: $targetScript"
& $pwshPath -NoProfile -File $targetScript @forwardedArguments
$childExitCode = $LASTEXITCODE

if ($childExitCode -eq 0) {
    Write-Host "Command result: PASS (exit $childExitCode)"
}
else {
    Write-Host "Command result: FAIL (exit $childExitCode)" -ForegroundColor Red
}

exit $childExitCode
