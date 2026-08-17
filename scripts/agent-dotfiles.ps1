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
    One of: doctor, build, scan, backup, sync, canonical, config, profile,
    skills, inventory, analyze, merge, plans, or env.

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 doctor -SkipSecretsScan

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 sync -DryRun

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 env list

.NOTES
    The sync subcommand requires exactly one explicit mode: -DryRun or -Apply.
    Apply is never selected or added by default.
    The env subcommand requires a sub-action: list, status, build, activate, rollback, or task.
    The env task sub-action requires a task action: status, ensure-skill, sync, or close.
    The env activate sub-action requires exactly one explicit mode: -DryRun or
    -Apply, mirroring sync. Rollback follows the same gate and also requires a
    reviewed -PlanPath when applying.
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
    Write-Host 'Commands: doctor, build, scan, backup, sync, canonical, config, profile, skills, inventory, analyze, merge, plans, env'
    Write-Host 'Sync requires exactly one explicit mode: -DryRun or -Apply.'
    Write-Host 'Run sync in dry-run mode first: scripts/agent-dotfiles.ps1 sync -DryRun'
    Write-Host 'Config actions: status, pull, push. Profile actions: status, build, apply.'
    Write-Host 'Skills actions: inventory, analyze, dedupe, merge, normalize, promote.'
    Write-Host 'Canonical actions: status, setup, recover status|abandon|rollback|finalize.'
    Write-Host 'Env actions: list, status, build, activate, rollback, task.'
    Write-Host 'Env task actions: status, ensure-skill, sync, close.'
    Write-Host 'Mutating actions require exactly one explicit mode: -DryRun or -Apply.'
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
    plans = 'plans.ps1'
}

$envCommandMap = @{
    list     = 'list-harness-env.ps1'
    status   = 'status-harness-env.ps1'
    build    = 'build-harness-env.ps1'
    activate = 'activate-harness-env.ps1'
    rollback = 'rollback-harness-env.ps1'
}
$envTaskActions = @('status', 'ensure-skill', 'sync', 'close')

$configCommandMap = @{
    status = 'config-status.ps1'
    pull   = 'config-pull.ps1'
    push   = 'config-push.ps1'
}

$profileCommandMap = @{
    status = 'status-harness-profile.ps1'
    build  = 'build-harness-profile.ps1'
    apply  = 'apply-harness-profile.ps1'
}

$skillsCommandMap = @{
    inventory = 'inventory-skills.ps1'
    analyze   = 'analyze-skills.ps1'
    dedupe    = 'dedupe-skills.ps1'
    merge     = 'auto-merge-skills.ps1'
    normalize = 'normalize-skill.ps1'
    promote   = 'promote-skill.ps1'
}

$canonicalCommandMap = @{
    status = 'setup-canonical-transaction.ps1'
    setup  = 'setup-canonical-transaction.ps1'
    recover = 'recover-canonical-transaction.ps1'
}

$normalizedCommand = $Command.ToLowerInvariant()
if ($normalizedCommand -notin @('env', 'config', 'profile', 'skills', 'canonical') -and -not $commandMap.ContainsKey($normalizedCommand)) {
    Write-Error "Unsupported command: $Command" -ErrorAction Continue
    Write-Usage
    exit 1
}

$forwardedArguments = @($RemainingArguments)
if ($normalizedCommand -in @('env', 'config', 'profile', 'skills', 'canonical')) {
    if ($forwardedArguments.Count -eq 0 -or $null -eq $forwardedArguments[0]) {
        Write-Error "The $normalizedCommand command requires a sub-action." -ErrorAction Continue
        Write-Usage
        exit 1
    }

    $groupAction = ([string]$forwardedArguments[0]).ToLowerInvariant()
    $isEnvTask = $normalizedCommand -eq 'env' -and $groupAction -eq 'task'
    if ($isEnvTask) {
        if ($forwardedArguments.Count -lt 2 -or $null -eq $forwardedArguments[1]) {
            Write-Error 'The env task command requires a task action: status, ensure-skill, sync, or close.' -ErrorAction Continue
            Write-Usage
            exit 1
        }
        $taskAction = ([string] $forwardedArguments[1]).ToLowerInvariant()
        if ($taskAction -notin $envTaskActions) {
            Write-Error "Unsupported env task action: $($forwardedArguments[1])" -ErrorAction Continue
            Write-Usage
            exit 1
        }
        $targetScriptName = 'task-skills.ps1'
        $forwardedArguments = @('-Action', $taskAction) + @($forwardedArguments | Select-Object -Skip 2)
    }
    else {
        $actionMap = switch ($normalizedCommand) {
            'env' { $envCommandMap }
            'config' { $configCommandMap }
            'profile' { $profileCommandMap }
            'skills' { $skillsCommandMap }
            'canonical' { $canonicalCommandMap }
        }
        if (-not $actionMap.ContainsKey($groupAction)) {
            Write-Error "Unsupported $normalizedCommand sub-action: $($forwardedArguments[0])" -ErrorAction Continue
            Write-Usage
            exit 1
        }

        $targetScriptName = $actionMap[$groupAction]
        $forwardedArguments = @($forwardedArguments | Select-Object -Skip 1)
        if($normalizedCommand -eq 'canonical' -and $groupAction -eq 'status'){$forwardedArguments=@('-Status')+@($forwardedArguments)}
        if($normalizedCommand -eq 'canonical' -and $groupAction -eq 'recover'){
            if($forwardedArguments.Count -eq 0){Write-Error 'canonical recover requires status, abandon, rollback, or finalize.' -ErrorAction Continue;exit 1}
            $recoverAction=([string]$forwardedArguments[0]).ToLowerInvariant()
            if($recoverAction -notin @('status','abandon','rollback','finalize')){Write-Error "Unsupported canonical recover action: $recoverAction" -ErrorAction Continue;exit 1}
            $forwardedArguments=@($forwardedArguments|Select-Object -Skip 1)
            if($recoverAction -eq 'status'){$forwardedArguments=@('-Status')+@($forwardedArguments)}else{$forwardedArguments=@('-Action',$recoverAction)+@($forwardedArguments)}
        }
    }

    $requiresExplicitMode = (($normalizedCommand -eq 'env' -and $groupAction -in @('activate', 'rollback')) -or
        ($isEnvTask -and $taskAction -in @('ensure-skill', 'sync', 'close')) -or
        ($normalizedCommand -eq 'config' -and $groupAction -in @('pull', 'push')) -or
        ($normalizedCommand -eq 'profile' -and $groupAction -eq 'apply') -or
        ($normalizedCommand -eq 'canonical' -and ($groupAction -eq 'setup' -or ($groupAction -eq 'recover' -and $recoverAction -ne 'status'))) -or
        ($normalizedCommand -eq 'skills' -and $groupAction -in @('merge', 'normalize', 'promote')))
    if ($requiresExplicitMode) {
        $hasDryRun = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-DryRun' }).Count -gt 0
        $hasApply = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-Apply' }).Count -gt 0

        if (-not $hasDryRun -and -not $hasApply) {
            Write-Error "The $normalizedCommand $groupAction command requires an explicit -DryRun or -Apply mode. Run -DryRun first." -ErrorAction Continue
            exit 1
        }
        if ($hasDryRun -and $hasApply) {
            Write-Error "The $normalizedCommand $groupAction command accepts only one mode. Specify -DryRun or -Apply, not both." -ErrorAction Continue
            exit 1
        }
        # config/profile scripts are dry-run by default but intentionally do
        # not expose a -DryRun switch; consume the unified CLI spelling here.
        if ($hasDryRun -and $normalizedCommand -in @('config', 'profile')) {
            $forwardedArguments = @($forwardedArguments | Where-Object { $_ -isnot [string] -or $_ -ine '-DryRun' })
        }
    }
}
else {
    $targetScriptName = $commandMap[$normalizedCommand]
    # Platform-specific inventory is now handled by the common inventory script.
}

if ($normalizedCommand -eq 'sync') {
    $hasDryRun = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-DryRun' }).Count -gt 0
    $hasApply = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-Apply' }).Count -gt 0

    if (-not $hasDryRun -and -not $hasApply) {
        Write-Error "The $normalizedCommand command requires an explicit -DryRun or -Apply mode. Run -DryRun first." -ErrorAction Continue
        exit 1
    }
    if ($hasDryRun -and $hasApply) {
        Write-Error "The $normalizedCommand command accepts only one mode. Specify -DryRun or -Apply, not both." -ErrorAction Continue
        exit 1
    }
}

if ($normalizedCommand -eq 'merge') {
    $hasDryRun = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-DryRun' }).Count -gt 0
    $hasApply = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-Apply' }).Count -gt 0
    if (-not $hasDryRun -and -not $hasApply) {
        Write-Error 'The merge command requires an explicit -DryRun or -Apply mode. Run -DryRun first.' -ErrorAction Continue
        exit 1
    }
    if ($hasDryRun -and $hasApply) {
        Write-Error 'The merge command accepts only one mode. Specify -DryRun or -Apply, not both.' -ErrorAction Continue
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

$canonicalMachineStdout = (
    $normalizedCommand -in @('canonical', 'merge') -or
    ($normalizedCommand -eq 'skills' -and $groupAction -in @('merge', 'normalize', 'promote'))
)
$jsonStdout = $canonicalMachineStdout -or @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-Json' }).Count -gt 0
if (-not $jsonStdout) {
    Write-Host "Invoking script: $targetScript"
}
& $pwshPath -NoProfile -File $targetScript @forwardedArguments
$childExitCode = $LASTEXITCODE

if (-not $jsonStdout) {
    if ($childExitCode -eq 0) {
        Write-Host "Command result: PASS (exit $childExitCode)"
    }
    else {
        Write-Host "Command result: FAIL (exit $childExitCode)" -ForegroundColor Red
    }
}

exit $childExitCode
