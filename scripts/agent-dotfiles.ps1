#requires -Version 7.0
<#
.SYNOPSIS
    Provides a single command entry point for repository maintenance scripts.

.DESCRIPTION
    Dispatches a supported subcommand to the existing repository script in a
    separate PowerShell process. Arguments after the subcommand are passed
    through unchanged and are not echoed by the wrapper.

.PARAMETER Command
    One of: doctor, build, scan, sync, config, profile, skills, inventory,
    analyze, merge, or env.

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 doctor -SkipSecretsScan

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 sync -DryRun

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 env deploy work -DryRun

.NOTES
    sync and env deploy run scripts/deploy-skills.ps1 and require exactly one
    explicit mode: -DryRun or -Apply. Apply is never selected or added by default.
    env list prints the environments defined in harness-source/envs/.
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
    Write-Host 'Commands: doctor, build, scan, sync, config, profile, skills, inventory, analyze, merge, env'
    Write-Host 'Sync runs deploy-skills.ps1 and requires exactly one explicit mode: -DryRun or -Apply.'
    Write-Host 'Run sync in dry-run mode first: scripts/agent-dotfiles.ps1 sync -DryRun'
    Write-Host 'Config actions: status, pull, push. Profile actions: status, build, apply.'
    Write-Host 'Skills actions: inventory, analyze, dedupe, merge, normalize, promote.'
    Write-Host 'Env actions: list [-RepoRoot <path>] [-JsonPath <file>], deploy <name> -DryRun|-Apply.'
    Write-Host 'Mutating actions require exactly one explicit mode: -DryRun or -Apply.'
}

function Assert-ExplicitMode([object[]] $Arguments, [string] $Label) {
    $hasDryRun = @($Arguments | Where-Object { $_ -is [string] -and $_ -ieq '-DryRun' }).Count -gt 0
    $hasApply = @($Arguments | Where-Object { $_ -is [string] -and $_ -ieq '-Apply' }).Count -gt 0
    if (-not $hasDryRun -and -not $hasApply) {
        Write-Error "The $Label command requires an explicit -DryRun or -Apply mode. Run -DryRun first." -ErrorAction Continue
        exit 1
    }
    if ($hasDryRun -and $hasApply) {
        Write-Error "The $Label command accepts only one mode. Specify -DryRun or -Apply, not both." -ErrorAction Continue
        exit 1
    }
}

function Remove-DryRunSwitch([object[]] $Arguments) {
    # Some targets are dry-run by default and expose no -DryRun switch;
    # consume the unified CLI spelling here.
    return @($Arguments | Where-Object { $_ -isnot [string] -or $_ -ine '-DryRun' })
}

function Write-EnvironmentList([object[]] $Arguments) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $jsonPath = $null
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $name = [string] $Arguments[$i]
        if ($name -ieq '-RepoRoot' -and $i + 1 -lt $Arguments.Count) { $repoRoot = [string] $Arguments[++$i]; continue }
        if ($name -ieq '-JsonPath' -and $i + 1 -lt $Arguments.Count) { $jsonPath = [string] $Arguments[++$i]; continue }
        Write-Error "Unsupported env list argument: $name" -ErrorAction Continue
        exit 1
    }
    $environments = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'harness-source\envs') -Filter '*.psd1' -File | Sort-Object Name | ForEach-Object {
        $data = Import-PowerShellDataFile -LiteralPath $_.FullName
        [ordered]@{ Name = $_.BaseName; Description = [string] $data['Description'] }
    })
    Write-Host 'Harness environments:'
    foreach ($environment in $environments) { Write-Host ("  {0}  {1}" -f $environment.Name, $environment.Description) }
    if ($jsonPath) {
        $json = [ordered]@{ Environments = $environments } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($jsonPath), $json + "`n", [Text.UTF8Encoding]::new($false))
    }
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
    sync   = 'deploy-skills.ps1'
    inventory = 'inventory-skills.ps1'
    analyze = 'analyze-skills.ps1'
    merge = 'auto-merge-skills.ps1'
}

$groupCommandMaps = @{
    config = @{
        status = 'config-status.ps1'
        pull   = 'config-pull.ps1'
        push   = 'config-push.ps1'
    }
    profile = @{
        status = 'status-harness-profile.ps1'
        build  = 'build-harness-profile.ps1'
        apply  = 'apply-harness-profile.ps1'
    }
    skills = @{
        inventory = 'inventory-skills.ps1'
        analyze   = 'analyze-skills.ps1'
        dedupe    = 'dedupe-skills.ps1'
        merge     = 'auto-merge-skills.ps1'
        normalize = 'normalize-skill.ps1'
        promote   = 'promote-skill.ps1'
    }
    env = @{
        list   = $null
        deploy = 'deploy-skills.ps1'
    }
}

$normalizedCommand = $Command.ToLowerInvariant()
if (-not $groupCommandMaps.ContainsKey($normalizedCommand) -and -not $commandMap.ContainsKey($normalizedCommand)) {
    Write-Error "Unsupported command: $Command" -ErrorAction Continue
    Write-Usage
    exit 1
}

$forwardedArguments = @($RemainingArguments | Where-Object { $null -ne $_ })
$groupAction = $null
if ($groupCommandMaps.ContainsKey($normalizedCommand)) {
    if ($forwardedArguments.Count -eq 0) {
        Write-Error "The $normalizedCommand command requires a sub-action." -ErrorAction Continue
        Write-Usage
        exit 1
    }
    $groupAction = ([string] $forwardedArguments[0]).ToLowerInvariant()
    $actionMap = $groupCommandMaps[$normalizedCommand]
    if (-not $actionMap.ContainsKey($groupAction)) {
        Write-Error "Unsupported $normalizedCommand sub-action: $($forwardedArguments[0])" -ErrorAction Continue
        Write-Usage
        exit 1
    }
    $targetScriptName = $actionMap[$groupAction]
    $forwardedArguments = @($forwardedArguments | Select-Object -Skip 1)

    if ($normalizedCommand -eq 'env' -and $groupAction -eq 'list') {
        Write-EnvironmentList $forwardedArguments
        exit 0
    }
    if ($normalizedCommand -eq 'env' -and $groupAction -eq 'deploy') {
        if ($forwardedArguments.Count -eq 0 -or ([string] $forwardedArguments[0]).StartsWith('-')) {
            Write-Error 'The env deploy command requires an environment name, for example: env deploy work -DryRun' -ErrorAction Continue
            exit 1
        }
        $forwardedArguments = @('-Environment', [string] $forwardedArguments[0]) + @($forwardedArguments | Select-Object -Skip 1)
    }

    $requiresExplicitMode = (($normalizedCommand -eq 'env' -and $groupAction -eq 'deploy') -or
        ($normalizedCommand -eq 'config' -and $groupAction -in @('pull', 'push')) -or
        ($normalizedCommand -eq 'profile' -and $groupAction -eq 'apply') -or
        ($normalizedCommand -eq 'skills' -and $groupAction -in @('merge', 'normalize', 'promote')))
    if ($requiresExplicitMode) {
        Assert-ExplicitMode $forwardedArguments "$normalizedCommand $groupAction"
        if ($normalizedCommand -in @('config', 'profile', 'env')) { $forwardedArguments = Remove-DryRunSwitch $forwardedArguments }
    }
}
else {
    $targetScriptName = $commandMap[$normalizedCommand]
    if ($normalizedCommand -in @('sync', 'merge')) { Assert-ExplicitMode $forwardedArguments $normalizedCommand }
    if ($normalizedCommand -eq 'sync') { $forwardedArguments = Remove-DryRunSwitch $forwardedArguments }
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

$jsonStdout = @($forwardedArguments | Where-Object { $_ -is [string] -and $_ -ieq '-Json' }).Count -gt 0
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
