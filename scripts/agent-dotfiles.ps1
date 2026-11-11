#requires -Version 7.0
<#
.SYNOPSIS
    Provides a single command entry point for repository maintenance scripts.

.DESCRIPTION
    Dispatches a supported subcommand to the existing repository script in a
    separate PowerShell process. Arguments after the subcommand are passed
    through unchanged and are not echoed by the wrapper.

.PARAMETER Command
    One of: help, doctor, build, scan, sync, config, profile, skills, or env.

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 doctor -SkipSecretsScan

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 sync -DryRun

.EXAMPLE
    pwsh -File scripts/agent-dotfiles.ps1 env deploy work -DryRun

.NOTES
    sync and env deploy run scripts/deploy.ps1 (skills plus managed config) and
    require exactly one explicit mode: -DryRun or -Apply. Apply is never selected
    or added by default.
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

function Write-Usage([string] $Group) {
    if ($Group) {
        Write-Host "Usage: pwsh -File scripts/agent-dotfiles.ps1 $Group <action> [arguments]"
        switch ($Group) {
            config {
                Write-Host 'status: read-only comparison of repository and home configuration.'
                Write-Host 'pull: repository -> home; Apply backs up overwritten files and preserves local-only settings.'
                Write-Host 'push: home -> repository capture; this is not git push. Review the captured diff before committing.'
                Write-Host 'Examples: config status; config pull -DryRun; config push -DryRun'
                Write-Host 'Options: -Platform Claude|Codex (default Codex), -RepoRoot <path>, -HomeRoot <path>.'
            }
            env {
                Write-Host 'list: read-only environment selections and last recorded Apply environment; it does not verify live contents.'
                Write-Host 'deploy <name>: skills plus managed home config. Switching to a smaller selection may prune previously managed skills.'
                Write-Host 'Examples: env list; env deploy work -DryRun'
                Write-Host 'List options: -StateRoot <path>; -JsonPath <file> writes a report.'
                Write-Host 'Deploy options: -Environment is supplied by <name>; -Retire <skill>, -HomeRoot <path>, -StateRoot <path>.'
            }
            profile {
                Write-Host 'status: read-only project profile status. build: generates rebuildable project output.'
                Write-Host 'apply: writes allowlisted files inside the target project; never writes home config or live skills.'
                Write-Host 'Examples: profile status -ProjectRoot <project>; profile build -ProjectRoot <project>; profile apply -ProjectRoot <project> -DryRun'
                Write-Host 'Options: -ProjectRoot <path>, -RepoRoot <path>; status also supports -Json.'
            }
            skills {
                Write-Host 'promote: imports a reviewed skill into skills-source, then builds and scans on Apply; it does not deploy live skills.'
                Write-Host 'Example: skills promote -Path <dir> -Name <name> -Type shared -DryRun'
                Write-Host 'Options: -Type shared|claude-only|codex-only; -Replace replaces a source skill of the same type with a backup.'
            }
        }
        Write-Host 'deploy, pull/push, apply and promote require exactly one mode: -DryRun or -Apply. Review the dry run before authorized Apply.'
        return
    }
    Write-Host 'Usage: pwsh -File scripts/agent-dotfiles.ps1 <command> [arguments]'
    Write-Host 'Commands: help, doctor, build, scan, sync, config, profile, skills, env'
    Write-Host 'Sync runs deploy.ps1 (skills plus config) and requires exactly one explicit mode: -DryRun or -Apply.'
    Write-Host 'Run sync in dry-run mode first: scripts/agent-dotfiles.ps1 sync -DryRun'
    Write-Host 'Config actions: status, pull, push. Profile actions: status, build, apply.'
    Write-Host 'Skills actions: promote -Path <dir> -Name <name> -Type <type> [-Replace] -DryRun|-Apply.'
    Write-Host 'Env actions: list [-RepoRoot <path>] [-StateRoot <path>] [-JsonPath <file>], deploy <name> -DryRun|-Apply.'
    Write-Host 'sync, env deploy, config pull/push, profile apply, and skills promote require exactly one explicit mode: -DryRun or -Apply.'
    Write-Host 'build generates output; env list -JsonPath writes a report without a mode.'
    Write-Host 'Group help: help config (or config help); also env, profile and skills.'
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
    # Every target is dry-run by default and exposes no -DryRun switch;
    # consume the unified CLI spelling here.
    return @($Arguments | Where-Object { $_ -isnot [string] -or $_ -ine '-DryRun' })
}

function Write-EnvironmentList([object[]] $Arguments) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-agent-dotfiles.deploy'
    $jsonPath = $null
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $name = [string] $Arguments[$i]
        if ($name -ieq '-RepoRoot' -and $i + 1 -lt $Arguments.Count) { $repoRoot = [string] $Arguments[++$i]; continue }
        if ($name -ieq '-StateRoot' -and $i + 1 -lt $Arguments.Count) { $stateRoot = [string] $Arguments[++$i]; continue }
        if ($name -ieq '-JsonPath' -and $i + 1 -lt $Arguments.Count) { $jsonPath = [string] $Arguments[++$i]; continue }
        Write-Error "Unsupported env list argument: $name" -ErrorAction Continue
        exit 1
    }
    $environments = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'harness-source\envs') -Filter '*.psd1' -File | Sort-Object Name | ForEach-Object {
        $data = Import-PowerShellDataFile -LiteralPath $_.FullName
        [pscustomobject]@{ Name = $_.BaseName; Description = [string] $data['Description']; Skills = $data['Skills'] }
    })
    Write-Host 'Harness environments:'
    foreach ($environment in $environments) {
        Write-Host ("  {0}  {1}" -f $environment.Name, $environment.Description)
        foreach ($platform in 'Claude', 'Codex', 'Zcode') {
            if ($environment.Skills -isnot [hashtable] -or -not $environment.Skills.ContainsKey($platform)) {
                Write-Host "    ${platform}: unavailable (invalid selection)"
                continue
            }
            $skills = @($environment.Skills[$platform] | Where-Object { $_ })
            $names = if ($skills.Count) { $skills -join ', ' } else { '(none)' }
            Write-Host ("    {0}: {1} [{2}]" -f $platform, $skills.Count, $names)
        }
    }
    $recordedEnvironment = $null
    $stateReason = 'missing-state'
    $statePath = Join-Path $stateRoot 'deployed-skills.json'
    try {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $stateReason = 'read-error'
            $stateText = Get-Content -Raw -LiteralPath $statePath -ErrorAction Stop
            $stateReason = 'invalid-json'
            $state = ConvertFrom-Json -InputObject $stateText -AsHashtable -ErrorAction Stop
            $stateReason = 'invalid-state'
            $validState = $state -is [System.Collections.IDictionary]
            if ($validState) {
                foreach ($platform in 'Claude', 'Codex', 'Zcode') {
                    if ($state[$platform] -isnot [array] -or @($state[$platform] | Where-Object { $_ -isnot [string] }).Count -gt 0) { $validState = $false }
                }
            }
            if ($validState) {
                if ($null -eq $state['Environment'] -or ($state['Environment'] -is [string] -and [string]::IsNullOrWhiteSpace($state['Environment']))) {
                    $stateReason = 'missing-environment'
                }
                elseif ($state['Environment'] -is [string] -and $state['Environment'] -notmatch '[\r\n]') {
                    $recordedEnvironment = $state['Environment']
                    $stateReason = $null
                }
            }
        }
    }
    catch { $recordedEnvironment = $null }
    if ($null -eq $recordedEnvironment) { $recordedEnvironment = 'unavailable' }
    Write-Host "Last recorded successful Apply environment: $recordedEnvironment (record only; live contents may differ)."
    if ($stateReason) {
        Write-Host "Record unavailable reason: $stateReason. Inspect the local deploy record; use the deployment dry run to check live contents."
    }
    if ($jsonPath) {
        $jsonEnvironments = @($environments | ForEach-Object { [ordered]@{ Name = $_.Name; Description = $_.Description } })
        $json = [ordered]@{ Environments = $jsonEnvironments } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($jsonPath), $json + "`n", [Text.UTF8Encoding]::new($false))
    }
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-Error 'A command is required.' -ErrorAction Continue
    Write-Usage
    exit 1
}

if ($Command -ieq 'help') {
    $topics = @($RemainingArguments | Where-Object { $null -ne $_ })
    if ($topics.Count -eq 0) { Write-Usage; exit 0 }
    if ($topics.Count -ne 1 -or $topics[0] -notin @('config', 'env', 'profile', 'skills')) {
        Write-Error 'Unsupported help topic. Use help config, help env, help profile or help skills.' -ErrorAction Continue
        exit 1
    }
    Write-Usage ([string] $topics[0]).ToLowerInvariant()
    exit 0
}

$commandMap = @{
    doctor = 'doctor.ps1'
    build  = 'build-skills.ps1'
    scan   = 'scan-secrets.ps1'
    sync   = 'deploy.ps1'
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
        promote = 'promote-skill.ps1'
    }
    env = @{
        list   = $null
        deploy = 'deploy.ps1'
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
    if ($groupAction -eq 'help' -and $forwardedArguments.Count -eq 1) {
        Write-Usage $normalizedCommand
        exit 0
    }
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
        ($normalizedCommand -eq 'skills' -and $groupAction -eq 'promote'))
    if ($requiresExplicitMode) {
        Assert-ExplicitMode $forwardedArguments "$normalizedCommand $groupAction"
        $forwardedArguments = Remove-DryRunSwitch $forwardedArguments
    }
}
else {
    $targetScriptName = $commandMap[$normalizedCommand]
    if ($normalizedCommand -eq 'sync') {
        Assert-ExplicitMode $forwardedArguments $normalizedCommand
        $forwardedArguments = Remove-DryRunSwitch $forwardedArguments
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
