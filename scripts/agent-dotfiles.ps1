#requires -Version 7.0
<#
.SYNOPSIS
    Provides a single command entry point for repository maintenance scripts.

.DESCRIPTION
    Dispatches a supported subcommand to the existing repository script in a
    separate PowerShell process. Arguments after the subcommand are passed
    through unchanged and are not echoed by the wrapper.

.PARAMETER Command
    One of: help, doctor, build, scan, sync, config, profile, skills, env, antigravity, hermes, mcp, status, or dashboard.

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
. (Join-Path $PSScriptRoot 'repo-common.ps1')

function Write-Usage([string] $Group) {
    if ($Group) {
        if ($Group -eq 'status') {
            Write-Host 'Usage: pwsh -File scripts/agent-dotfiles.ps1 status [-Json] [-RepoRoot <path>] [-HomeRoot <path>] [-StateRoot <path>]'
            Write-Host 'status: read-only overview aggregating env list, config status, antigravity status, hermes status, and mcp status.'
            Write-Host 'Examples: status; status -Json'
            Write-Host 'Options: -Json, -RepoRoot <path>, -HomeRoot <path>, -StateRoot <path>.'
            Write-Host 'The status command is strictly read-only and accepts no -DryRun or -Apply mode.'
            return
        }
        if ($Group -eq 'dashboard') {
            Write-Host 'Usage: pwsh -File scripts/agent-dotfiles.ps1 dashboard [-Port <port>] [-NoBrowser] [-Check] [-Offline] [-RepoRoot <path>] [-HomeRoot <path>] [-StateRoot <path>]'
            Write-Host 'dashboard: launches or reuses the local Chinese web monitoring console bound to 127.0.0.1.'
            Write-Host 'Examples: dashboard; dashboard -NoBrowser; dashboard -Port 8765 -Offline; dashboard -Check'
            Write-Host 'Options: -Port <port>, -NoBrowser, -Check, -Offline, -RepoRoot <path>, -HomeRoot <path>, -StateRoot <path>.'
            Write-Host 'Mutating sync actions inside the console always require a DryRun preview and explicit confirmation before Apply.'
            return
        }
        Write-Host "Usage: pwsh -File scripts/agent-dotfiles.ps1 $Group <action> [arguments]"
        switch ($Group) {
            antigravity {
                Write-Host 'build: generates the reviewed plugin package from harness-source/antigravity/plugins.psd1; no live installation.'
                Write-Host 'status: reads candidate and native plugin state without building or repairing.'
                Write-Host 'deploy: previews by default; authorized Apply installs through the official agy plugin command.'
                Write-Host 'Examples: antigravity build; antigravity status; antigravity deploy -DryRun'
                Write-Host 'Options: -RepoRoot <path>, -JsonPath <file>; deploy also accepts -ExternalPlugin <name> and requires -DryRun or -Apply.'
                Write-Host 'Default deploy leaves external plugins untouched; missing marketplace entries require explicit -ExternalPlugin <name>. Unsupported update and rollback remain blocked.'
            }
            config {
                Write-Host 'status: read-only comparison of repository and home configuration.'
                Write-Host 'pull: repository -> home; Apply backs up overwritten files and preserves local-only settings.'
                Write-Host 'push: home -> repository capture; this is not git push. Review the captured diff before committing.'
                Write-Host 'Examples: config status; config pull -DryRun; config push -DryRun'
                Write-Host 'Options: -Platform Codex|Antigravity|Hermes (default Codex), -RepoRoot <path>, -HomeRoot <path>.'
            }
            hermes {
                Write-Host 'status: read-only inspection of Hermes managed shared skills under %LOCALAPPDATA%/hermes/skills/ai-agent-dotfiles.'
                Write-Host 'deploy: previews by default; authorized Apply deploys selected shared skills and prunes only previously managed or -Retire skills.'
                Write-Host 'Examples: hermes status; hermes deploy -DryRun; hermes deploy -Apply'
                Write-Host 'Options: -RepoRoot <path>, -HomeRoot <path>, -StateRoot <path>, -JsonPath <file>, -Json; deploy also accepts -Retire <skill>, -SkipSecretScan, and requires -DryRun or -Apply.'
                Write-Host 'Hermes deploy is separate from sync and env deploy; only deploy accepts -DryRun, -Apply, -Retire, or -SkipSecretScan.'
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
                Write-Host 'Options: -Type shared|codex-only; -Replace replaces a source skill of the same type with a backup.'
            }
            mcp {
                Write-Host 'status: read-only inspection of Antigravity, Codex, and Hermes managed MCP projections.'
                Write-Host 'deploy: previews per-entry projection with -DryRun; authorized -Apply merges Antigravity/Hermes config and runs codex mcp CLI.'
                Write-Host 'Examples: mcp status; mcp deploy -DryRun; mcp deploy -Platform Codex,Antigravity,Hermes -DryRun'
                Write-Host 'Options: -Platform Antigravity|Codex|Hermes, -Server <name>, -RepoRoot <path>, -HomeRoot <path>, -BackupRoot <path>, -JsonPath <file>, -Json, -SkipSecretScan.'
                Write-Host 'Only deploy accepts -DryRun, -Apply, -BackupRoot, or -SkipSecretScan.'
            }
        }
        Write-Host 'deploy, pull/push, apply and promote require exactly one mode: -DryRun or -Apply. Review the dry run before authorized Apply.'
        return
    }
    Write-Host 'Usage: pwsh -File scripts/agent-dotfiles.ps1 <command> [arguments]'
    Write-Host 'Commands: help, doctor, build, scan, sync, config, profile, skills, env, antigravity, hermes, mcp, status, dashboard'
    Write-Host 'Status actions: status [-Json] aggregates env list, config status, antigravity status, hermes status, and mcp status.'
    Write-Host 'Dashboard actions: dashboard [-Port <port>] [-NoBrowser] [-Check] [-Offline] launches the local Chinese web monitoring console.'
    Write-Host 'Antigravity actions: build, status, deploy -DryRun|-Apply; separate from sync and env deploy.'
    Write-Host 'Hermes actions: status, deploy -DryRun|-Apply; separate from sync and env deploy.'
    Write-Host 'MCP actions: status, deploy -DryRun|-Apply; separate from sync and requires -DryRun or -Apply.'
    Write-Host 'Sync runs deploy.ps1 (skills plus config) and requires exactly one explicit mode: -DryRun or -Apply.'
    Write-Host 'Run sync in dry-run mode first: scripts/agent-dotfiles.ps1 sync -DryRun'
    Write-Host 'Config actions: status, pull, push. Profile actions: status, build, apply.'
    Write-Host 'Skills actions: promote -Path <dir> -Name <name> -Type <type> [-Replace] -DryRun|-Apply.'
    Write-Host 'Env actions: list [-RepoRoot <path>] [-StateRoot <path>] [-JsonPath <file>], deploy <name> -DryRun|-Apply.'
    Write-Host 'sync, env deploy, antigravity deploy, hermes deploy, mcp deploy, config pull/push, profile apply, and skills promote require exactly one explicit mode: -DryRun or -Apply.'
    Write-Host 'build generates output; env list -JsonPath writes a report without a mode.'
    Write-Host 'Group help: help config (or config help); also status, dashboard, env, profile, skills, antigravity, hermes and mcp.'
}

function ConvertTo-ExplicitModeArguments([object[]] $Arguments, [string] $Label) {
    $modes = @($Arguments | Where-Object { $_ -in @('-DryRun', '-Apply') })
    if ($modes.Count -eq 0) {
        Write-Error "The $Label command requires an explicit -DryRun or -Apply mode. Run -DryRun first." -ErrorAction Continue
        exit 1
    }
    if ($modes.Count -gt 1) {
        Write-Error "The $Label command accepts only one mode. Specify -DryRun or -Apply, not both." -ErrorAction Continue
        exit 1
    }
    # Bind Apply explicitly so another spelling cannot override the reviewed mode.
    $childMode = if ($modes[0] -eq '-Apply') { '-Apply' } else { '-Apply:$false' }
    return ,(@($childMode) + @($Arguments | Where-Object { $_ -notin @('-DryRun', '-Apply') }))
}

function Get-EnvironmentStatusReport {
    param(
        [string] $RepoRoot,
        [string] $StateRoot
    )
    $environments = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'harness-source\envs') -Filter '*.psd1' -File -ErrorAction Stop | Sort-Object Name | ForEach-Object {
        $data = Import-PowerShellDataFile -LiteralPath $_.FullName
        [pscustomobject]@{ Name = $_.BaseName; Description = [string] $data['Description']; Skills = $data['Skills'] }
    })
    # The single shared deploy-state reader keeps status, env list and deployment on one
    # ownership-shape contract; its reasons are fixed and free of private values.
    $stateRecord = Get-DeploySkillsStateRecord -StateRoot $StateRoot
    $recordedEnvironment = $stateRecord.RecordedEnvironment
    if ($null -eq $recordedEnvironment) { $recordedEnvironment = 'unavailable' }
    return [pscustomobject]@{
        Recorded     = $recordedEnvironment
        StateReason  = $stateRecord.Reason
        Failed       = $null -eq $stateRecord.Ownership
        Available    = @($environments | ForEach-Object { $_.Name })
        Environments = $environments
    }
}

function Write-EnvironmentList([object[]] $Arguments) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-agent-dotfiles.deploy'
    $jsonPath = $null
    $seenParameters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $valueFlags = @('-RepoRoot', '-StateRoot', '-JsonPath')
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $name = [string] $Arguments[$i]
        if ($name -in $valueFlags) {
            if (-not $seenParameters.Add($name)) {
                Write-Error "Duplicate env list argument: $name" -ErrorAction Continue
                exit 1
            }
            if ($i + 1 -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace([string] $Arguments[$i + 1]) -or ([string] $Arguments[$i + 1]) -in $valueFlags -or ([string] $Arguments[$i + 1]).StartsWith('-')) {
                Write-Error "Missing path value for $name." -ErrorAction Continue
                exit 1
            }
            $val = [string] $Arguments[++$i]
            switch ($name.ToLowerInvariant()) {
                '-reporoot'  { $repoRoot = $val }
                '-stateroot' { $stateRoot = $val }
                '-jsonpath'  { $jsonPath = $val }
            }
            continue
        }
        Write-Error "Unsupported env list argument: $name" -ErrorAction Continue
        exit 1
    }
    $report = Get-EnvironmentStatusReport -RepoRoot $repoRoot -StateRoot $stateRoot
    Write-Host 'Harness environments:'
    foreach ($environment in $report.Environments) {
        Write-Host ("  {0}  {1}" -f $environment.Name, $environment.Description)
        foreach ($platform in @('Codex')) {
            if ($environment.Skills -isnot [hashtable] -or -not $environment.Skills.ContainsKey($platform)) {
                Write-Host "    ${platform}: unavailable (invalid selection)"
                continue
            }
            $skills = @($environment.Skills[$platform] | Where-Object { $_ })
            $names = if ($skills.Count) { $skills -join ', ' } else { '(none)' }
            Write-Host ("    {0}: {1} [{2}]" -f $platform, $skills.Count, $names)
        }
    }
    Write-Host ("Last recorded successful Apply environment: {0} (record only; live contents may differ)." -f $report.Recorded)
    if ($report.StateReason) {
        Write-Host ("Record unavailable reason: {0}. Inspect the local deploy record; use the deployment dry run to check live contents." -f $report.StateReason)
    }
    if ($jsonPath) {
        Assert-PlainPathNoReparse -Path $jsonPath -AllowMissing
        $provider = $null
        $drive = $null
        $fullJsonPath = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($jsonPath, [ref]$provider, [ref]$drive))
        $jsonParent = Split-Path -Parent $fullJsonPath
        if ($jsonParent -and -not (Test-Path -LiteralPath $jsonParent)) {
            [IO.Directory]::CreateDirectory($jsonParent) | Out-Null
        }
        $jsonEnvironments = @($report.Environments | ForEach-Object { [ordered]@{ Name = $_.Name; Description = $_.Description } })
        $json = [ordered]@{ Environments = $jsonEnvironments } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($fullJsonPath, $json + "`n", [Text.UTF8Encoding]::new($false))
    }
}

function Get-SafeProperty {
    param(
        [object] $Target,
        [string] $Name
    )
    if ($null -eq $Target) { return $null }
    if ($Target -is [System.Collections.IDictionary]) {
        if ($Target.Contains($Name)) { return ,$Target[$Name] }
        return $null
    }
    if ($Target -is [pscustomobject] -or ($null -ne $Target.PSObject -and $null -ne $Target.PSObject.Properties)) {
        $prop = $Target.PSObject.Properties[$Name]
        if ($null -ne $prop) { return ,$prop.Value }
    }
    return $null
}

function Convert-ChildJson {
    param([object] $RawOutput)
    $text = if ($RawOutput -is [array]) { $RawOutput -join "`n" } else { [string] $RawOutput }
    $trimmed = $text.Trim()
    try {
        return ,(ConvertFrom-Json -InputObject $trimmed -NoEnumerate -ErrorAction Stop)
    }
    catch {
        $lines = @($trimmed -split "\r?\n")
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $lineTrimmed = $lines[$i].TrimStart()
            if (-not ($lineTrimmed.StartsWith('{') -or $lineTrimmed.StartsWith('['))) { continue }
            $candidate = ($lines[$i..($lines.Count - 1)] -join "`n").Trim()
            try {
                return ,(ConvertFrom-Json -InputObject $candidate -NoEnumerate -ErrorAction Stop)
            }
            catch {
                $closingChar = if ($lineTrimmed.StartsWith('{')) { [char]'}' } else { [char]']' }
                $lastBracket = $candidate.LastIndexOf($closingChar)
                if ($lastBracket -gt 0) {
                    $sliced = $candidate.Substring(0, $lastBracket + 1)
                    try {
                        return ,(ConvertFrom-Json -InputObject $sliced -NoEnumerate -ErrorAction Stop)
                    } catch { }
                }
            }
        }
        return [ordered]@{ Error = 'Failed to parse JSON output'; Raw = $trimmed }
    }
}

function Invoke-StatusChildProcesses {
    param(
        [Parameter(Mandatory)] [string] $PwshPath,
        [Parameter(Mandatory)] [object[]] $Specs,
        [int] $TimeoutSeconds = 120
    )

    $results = @{}
    $running = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($spec in $Specs) {
            if (-not (Test-Path -LiteralPath $spec.ScriptPath -PathType Leaf)) {
                $results[$spec.Key] = @{ Exists = $false; ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false }
                continue
            }
            $info = [System.Diagnostics.ProcessStartInfo]::new($PwshPath)
            $info.ArgumentList.Add('-NoProfile')
            $info.ArgumentList.Add('-File')
            $info.ArgumentList.Add([string] $spec.ScriptPath)
            foreach ($arg in @($spec.Arguments)) {
                $info.ArgumentList.Add([string] $arg)
            }
            $info.UseShellExecute = $false
            $info.RedirectStandardInput = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true

            $proc = [System.Diagnostics.Process]::Start($info)
            if ($null -eq $proc) {
                $results[$spec.Key] = @{ Exists = $true; ExitCode = -1; StdOut = ''; StdErr = "Failed to start $($spec.ScriptPath)"; TimedOut = $false }
                continue
            }
            $proc.StandardInput.Close()
            $running.Add([pscustomobject]@{
                Key        = $spec.Key
                Process    = $proc
                StdOutTask = $proc.StandardOutput.ReadToEndAsync()
                StdErrTask = $proc.StandardError.ReadToEndAsync()
            })
        }

        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        foreach ($job in $running) {
            $remainingMs = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $exited = $job.Process.WaitForExit($remainingMs)
            if (-not $exited) {
                try { $job.Process.Kill($true) } catch { }
                $null = $job.Process.WaitForExit(5000)
                $outText = if ($job.StdOutTask.Wait(2000)) { $job.StdOutTask.GetAwaiter().GetResult() } else { '' }
                $errText = if ($job.StdErrTask.Wait(2000)) { $job.StdErrTask.GetAwaiter().GetResult() } else { '' }
                $results[$job.Key] = @{ Exists = $true; ExitCode = -1; StdOut = $outText; StdErr = $errText; TimedOut = $true }
            }
            else {
                $job.Process.WaitForExit()
                $results[$job.Key] = @{
                    Exists   = $true
                    ExitCode = $job.Process.ExitCode
                    StdOut   = $job.StdOutTask.GetAwaiter().GetResult()
                    StdErr   = $job.StdErrTask.GetAwaiter().GetResult()
                    TimedOut = $false
                }
            }
        }
    }
    finally {
        foreach ($job in $running) {
            if ($null -ne $job.Process) { $job.Process.Dispose() }
        }
    }
    return $results
}

function Invoke-UnifiedStatus {
    param([object[]] $Arguments)
    $isJson = $false
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $homeRoot = [Environment]::GetFolderPath('UserProfile')
    $stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-agent-dotfiles.deploy'
    $seenParameters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = [string] $Arguments[$i]
        if ($arg -match '(?i)^-(DryRun|Apply)') {
            Write-Error 'The status command is read-only and accepts no -DryRun or -Apply mode.' -ErrorAction Continue
            exit 1
        }
        if ($arg -ieq '-Json') {
            if (-not $seenParameters.Add('-Json')) {
                Write-Error "Duplicate status argument: $arg" -ErrorAction Continue
                exit 1
            }
            $isJson = $true
            continue
        }
        if ($arg -in @('-RepoRoot', '-HomeRoot', '-StateRoot')) {
            if (-not $seenParameters.Add($arg)) {
                Write-Error "Duplicate status argument: $arg" -ErrorAction Continue
                exit 1
            }
            if ($i + 1 -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace([string] $Arguments[$i + 1]) -or ([string] $Arguments[$i + 1]).StartsWith('-')) {
                Write-Error "Missing path value for $arg." -ErrorAction Continue
                exit 1
            }
            $val = [string] $Arguments[++$i]
            switch ($arg.ToLowerInvariant()) {
                '-reporoot'  { $repoRoot = $val }
                '-homeroot'  { $homeRoot = $val }
                '-stateroot' { $stateRoot = $val }
            }
            continue
        }
        Write-Error "Unsupported status argument: $arg" -ErrorAction Continue
        exit 1
    }

    $pwshCommands = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
    if ($pwshCommands.Count -eq 0) {
        Write-Error 'PowerShell 7 executable (pwsh) is not available on PATH.' -ErrorAction Continue
        exit 1
    }
    $pwshPath = $pwshCommands[0].Source

    # 1. Environment status
    $envError = $null
    try { $envReport = Get-EnvironmentStatusReport -RepoRoot $repoRoot -StateRoot $stateRoot }
    catch {
        $envError = 'Could not read the environment definitions under harness-source/envs. Check -RepoRoot.'
        $envReport = [ordered]@{ Recorded = 'unavailable'; StateReason = 'catalog-unavailable'; Available = @(); Environments = @(); Failed = $true }
    }

    # Determine Codex Live Skills eligibility before spawning parallel status children
    $deploySkillsScript = Join-Path $PSScriptRoot 'deploy-skills.ps1'
    $skillsPreState = 'eligible'
    if ($envReport.Recorded -eq 'unavailable' -or (-not (Test-Path -LiteralPath $deploySkillsScript -PathType Leaf))) {
        $skillsPreState = 'unavailable'
    }
    else {
        $selectedEnvObj = @($envReport.Environments | Where-Object { $_.Name -eq $envReport.Recorded }) | Select-Object -First 1
        if ($null -eq $selectedEnvObj -or $selectedEnvObj.Skills -isnot [hashtable] -or (-not $selectedEnvObj.Skills.ContainsKey('Codex'))) {
            $skillsPreState = 'unavailable'
        }
        else {
            $codexSkillsDir = Join-Path $repoRoot 'codex\skills'
            if (-not (Test-Path -LiteralPath $codexSkillsDir -PathType Container)) {
                $skillsPreState = 'build-required'
            }
            else {
                foreach ($skillName in @($selectedEnvObj.Skills['Codex'] | Where-Object { $_ })) {
                    if (-not (Test-Path -LiteralPath (Join-Path $codexSkillsDir $skillName) -PathType Container)) {
                        $skillsPreState = 'build-required'
                        break
                    }
                }
            }
        }
    }

    # Build child specs and run them concurrently
    $childSpecs = [System.Collections.Generic.List[object]]::new()

    $configStatusScript = Join-Path $PSScriptRoot 'config-status.ps1'
    $configArgs = @('-Platform', 'Codex,Antigravity,Hermes', '-Json')
    if ($repoRoot) { $configArgs += @('-RepoRoot', $repoRoot) }
    if ($seenParameters.Contains('-HomeRoot')) { $configArgs += @('-HomeRoot', $homeRoot) }
    $childSpecs.Add([pscustomobject]@{ Key = 'Config'; ScriptPath = $configStatusScript; Arguments = $configArgs })

    $agScript = Join-Path $PSScriptRoot 'antigravity-plugins.ps1'
    $agArgs = @('-Action', 'Status')
    if ($repoRoot) { $agArgs += @('-RepoRoot', $repoRoot) }
    if ($seenParameters.Contains('-StateRoot') -and (Test-Path -LiteralPath $agScript -PathType Leaf)) {
        $agCommand = Get-Command $agScript -ErrorAction SilentlyContinue
        if ($null -ne $agCommand -and $agCommand.Parameters.ContainsKey('StateRoot')) {
            $agArgs += @('-StateRoot', (Join-Path $stateRoot 'antigravity'))
        }
    }
    $childSpecs.Add([pscustomobject]@{ Key = 'Antigravity'; ScriptPath = $agScript; Arguments = $agArgs })

    $hermesScript = Join-Path $PSScriptRoot 'hermes-skills.ps1'
    $hermesArgs = @('-Action', 'Status', '-Json')
    if ($repoRoot) { $hermesArgs += @('-RepoRoot', $repoRoot) }
    if ($seenParameters.Contains('-HomeRoot')) { $hermesArgs += @('-HomeRoot', $homeRoot) }
    if ($seenParameters.Contains('-StateRoot')) { $hermesArgs += @('-StateRoot', (Join-Path $stateRoot 'hermes')) }
    $childSpecs.Add([pscustomobject]@{ Key = 'Hermes'; ScriptPath = $hermesScript; Arguments = $hermesArgs })

    $mcpScript = Join-Path $PSScriptRoot 'mcp-sync.ps1'
    $mcpArgs = @('-Action', 'Status', '-Json')
    if ($repoRoot) { $mcpArgs += @('-RepoRoot', $repoRoot) }
    if ($seenParameters.Contains('-HomeRoot')) { $mcpArgs += @('-HomeRoot', $homeRoot) }
    $childSpecs.Add([pscustomobject]@{ Key = 'Mcp'; ScriptPath = $mcpScript; Arguments = $mcpArgs })

    if ($skillsPreState -eq 'eligible') {
        $skillsArgs = @('-Environment', $envReport.Recorded, '-SkipBuild', '-Json', '-RepoRoot', $repoRoot)
        if ($seenParameters.Contains('-HomeRoot')) { $skillsArgs += @('-HomeRoot', $homeRoot) }
        if ($seenParameters.Contains('-StateRoot')) { $skillsArgs += @('-StateRoot', $stateRoot) }
        $childSpecs.Add([pscustomobject]@{ Key = 'Skills'; ScriptPath = $deploySkillsScript; Arguments = $skillsArgs })
    }

    $childResults = Invoke-StatusChildProcesses -PwshPath $pwshPath -Specs $childSpecs.ToArray()

    # 2. Config status
    $configRes = $childResults['Config']
    $configJson = $null
    if (-not $configRes.Exists) {
        $configJson = [ordered]@{ Error = "config-status.ps1 not found at $configStatusScript" }
    }
    elseif ($configRes.TimedOut) {
        $configJson = [ordered]@{ Error = 'config-status.ps1 timed out' }
    }
    elseif ($configRes.ExitCode -eq 0) {
        $configJson = Convert-ChildJson $configRes.StdOut
        if ($null -ne (Get-SafeProperty $configJson 'Status')) {
            $configJson = @($configJson)
        }
        elseif ($configJson -isnot [array] -and $null -eq (Get-SafeProperty $configJson 'Error')) {
            $configJson = [ordered]@{ Error = 'Expected a config status report.' }
        }
    }
    else {
        $rawErr = (@($configRes.StdOut, $configRes.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        $configJson = [ordered]@{ Error = "config-status.ps1 failed (exit $($configRes.ExitCode))"; Raw = $rawErr }
    }

    # 3. Antigravity plugin status
    $agRes = $childResults['Antigravity']
    $agJson = $null
    if (-not $agRes.Exists) {
        $agJson = [ordered]@{ Error = "antigravity-plugins.ps1 not found at $agScript" }
    }
    elseif ($agRes.TimedOut) {
        $agJson = [ordered]@{ Error = 'antigravity-plugins.ps1 timed out' }
    }
    elseif ($agRes.ExitCode -eq 0) {
        $agJson = Convert-ChildJson $agRes.StdOut
        if ($null -eq (Get-SafeProperty $agJson 'Action') -and $null -eq (Get-SafeProperty $agJson 'Error')) {
            $agJson = [ordered]@{ Error = 'Expected an Antigravity plugin status report.' }
        }
    }
    else {
        $rawErr = (@($agRes.StdOut, $agRes.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        $agJson = [ordered]@{ Error = "antigravity-plugins.ps1 failed (exit $($agRes.ExitCode))"; Raw = $rawErr }
    }

    # 4. MCP status
    $mcpRes = $childResults['Mcp']
    $mcpJson = $null
    if (-not $mcpRes.Exists) {
        $mcpJson = [ordered]@{ Error = "mcp-sync.ps1 not found at $mcpScript" }
    }
    elseif ($mcpRes.TimedOut) {
        $mcpJson = [ordered]@{ Error = 'mcp-sync.ps1 timed out' }
    }
    elseif ($mcpRes.ExitCode -eq 0) {
        $mcpJson = Convert-ChildJson $mcpRes.StdOut
        if ($null -eq (Get-SafeProperty $mcpJson 'Summary') -and (Get-SafeProperty $mcpJson 'Items') -isnot [array] -and $null -eq (Get-SafeProperty $mcpJson 'Error')) {
            $mcpJson = [ordered]@{ Error = 'Expected an MCP status report.' }
        }
    }
    else {
        $rawErr = (@($mcpRes.StdOut, $mcpRes.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        $mcpJson = [ordered]@{ Error = "mcp-sync.ps1 failed (exit $($mcpRes.ExitCode))"; Raw = $rawErr }
    }

    # 4b. Hermes Skills status
    $hermesRes = $childResults['Hermes']
    $hermesJson = $null
    if (-not $hermesRes.Exists) {
        $hermesJson = [ordered]@{ Error = "hermes-skills.ps1 not found at $hermesScript" }
    }
    elseif ($hermesRes.TimedOut) {
        $hermesJson = [ordered]@{ Error = 'hermes-skills.ps1 timed out' }
    }
    elseif ($hermesRes.ExitCode -eq 0) {
        $hermesJson = Convert-ChildJson $hermesRes.StdOut
        $hermesErrProp = Get-SafeProperty $hermesJson 'Error'
        $hermesStateProp = Get-SafeProperty $hermesJson 'State'
        if ($null -eq $hermesErrProp -and ($hermesStateProp -notin @('checked', 'not-installed', 'blocked'))) {
            $hermesJson = [ordered]@{ Error = 'Expected a Hermes skills status report.' }
        }
    }
    else {
        $rawErr = (@($hermesRes.StdOut, $hermesRes.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        $hermesJson = [ordered]@{ Error = "hermes-skills.ps1 failed (exit $($hermesRes.ExitCode))"; Raw = $rawErr }
    }

    # 5. Codex Live Skills status
    $skillsReport = $null
    $skillsSummaryValue = $null
    if ($skillsPreState -ne 'eligible') {
        $skillsReport = [ordered]@{
            Environment = $envReport.Recorded
            State       = $skillsPreState
            LiveRoot    = $null
            Summary     = $null
            Error       = $null
        }
        $skillsSummaryValue = $skillsPreState
    }
    else {
        $skillsRes = $childResults['Skills']
        if ($skillsRes.TimedOut) {
            $skillsReport = [ordered]@{
                Environment = $envReport.Recorded
                State       = 'error'
                LiveRoot    = $null
                Summary     = $null
                Error       = 'deploy-skills.ps1 timed out'
            }
            $skillsSummaryValue = 'error'
        }
        elseif ($skillsRes.ExitCode -ne 0) {
            $rawErr = (@($skillsRes.StdErr, $skillsRes.StdOut) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
            $cleanErr = $rawErr -replace '\x1b\[[0-9;]*[A-Za-z]', ''
            $errLines = @($cleanErr -split "\r?\n")
            $tildeIdx = -1
            for ($idx = 0; $idx -lt $errLines.Count; $idx++) {
                if ($errLines[$idx] -match '^\s*\|\s*~+\s*$') { $tildeIdx = $idx; break }
            }
            $extracted = @()
            if ($tildeIdx -ge 0 -and ($tildeIdx + 1) -lt $errLines.Count) {
                $extracted = @($errLines[($tildeIdx + 1)..($errLines.Count - 1)] | Where-Object { $_ -match '^\s*\|\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() } | Where-Object { $_ })
            }
            if ($extracted.Count -gt 0) {
                $errMsg = $extracted -join ' '
            }
            else {
                $firstLine = ($errLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
                $errMsg = if ($firstLine) { [string]$firstLine.Trim() } else { "deploy-skills.ps1 failed (exit $($skillsRes.ExitCode))" }
            }
            $skillsReport = [ordered]@{
                Environment = $envReport.Recorded
                State       = 'error'
                LiveRoot    = $null
                Summary     = $null
                Error       = $errMsg
            }
            $skillsSummaryValue = 'error'
        }
        else {
            $skillsJson = Convert-ChildJson $skillsRes.StdOut
            $skillsJsonErr = Get-SafeProperty $skillsJson 'Error'
            $skillsJsonSummary = Get-SafeProperty $skillsJson 'Summary'
            if ($null -ne $skillsJsonErr -or $null -eq $skillsJsonSummary) {
                $errMsg = if ($skillsJsonErr) { [string]$skillsJsonErr } else { 'Expected a deploy-skills status report.' }
                $skillsReport = [ordered]@{
                    Environment = $envReport.Recorded
                    State       = 'error'
                    LiveRoot    = $null
                    Summary     = $null
                    Error       = $errMsg
                }
                $skillsSummaryValue = 'error'
            }
            else {
                $skillsCounts = [ordered]@{
                    install   = [int]((Get-SafeProperty $skillsJsonSummary 'install') ?? 0)
                    update    = [int]((Get-SafeProperty $skillsJsonSummary 'update') ?? 0)
                    unchanged = [int]((Get-SafeProperty $skillsJsonSummary 'unchanged') ?? 0)
                    prune     = [int]((Get-SafeProperty $skillsJsonSummary 'prune') ?? 0)
                    unknown   = [int]((Get-SafeProperty $skillsJsonSummary 'unknown') ?? 0)
                }
                $skillsReport = [ordered]@{
                    Environment = [string]((Get-SafeProperty $skillsJson 'Environment') ?? $envReport.Recorded)
                    State       = 'checked'
                    LiveRoot    = Get-SafeProperty $skillsJson 'LiveRoot'
                    Summary     = $skillsCounts
                    Error       = $null
                }
                $skillsSummaryValue = $skillsCounts
            }
        }
    }

    # Summary calculations
    $configSummary = [ordered]@{
        'in-sync'       = 0
        'differs'       = 0
        'repo-only'     = 0
        'home-only'     = 0
        'not-installed' = 0
        'blocked'       = 0
    }
    if ($configJson -is [array]) {
        foreach ($item in $configJson) {
            $itemStatus = Get-SafeProperty $item 'Status'
            if ($null -ne $itemStatus -and $configSummary.Contains([string]$itemStatus)) {
                $configSummary[[string]$itemStatus]++
            }
        }
    }

    $agAction = 'unavailable'
    $agActionVal = Get-SafeProperty $agJson 'Action'
    $agReasonVal = Get-SafeProperty $agJson 'Reason'
    $agErrorVal  = Get-SafeProperty $agJson 'Error'
    $agNameVal   = Get-SafeProperty $agJson 'Name'
    $agVersionVal= Get-SafeProperty $agJson 'Version'
    $agExternals = Get-SafeProperty $agJson 'ExternalExpectations'
    $agApplyRequirement = Get-SafeProperty $agJson 'ApplyRequirement'

    if ($null -ne $agActionVal) { $agAction = [string] $agActionVal }
    elseif ($null -ne $agReasonVal) { $agAction = [string] $agReasonVal }
    elseif ($null -ne $agErrorVal) { $agAction = 'error' }

    $mcpSummary = [ordered]@{
        'add'           = 0
        'update'        = 0
        'unchanged'     = 0
        'blocked'       = 0
        'not-installed' = 0
    }
    $mcpSummaryObj = Get-SafeProperty $mcpJson 'Summary'
    $mcpItems      = Get-SafeProperty $mcpJson 'Items'
    $mcpErrorVal   = Get-SafeProperty $mcpJson 'Error'

    if ($null -ne $mcpSummaryObj) {
        foreach ($k in @('add', 'update', 'unchanged', 'blocked', 'not-installed')) {
            $val = Get-SafeProperty $mcpSummaryObj $k
            if ($null -ne $val) {
                $mcpSummary[$k] = [int] $val
            }
        }
    }
    elseif ($mcpItems -is [array]) {
        foreach ($item in $mcpItems) {
            $act = Get-SafeProperty $item 'Action'
            if ($null -ne $act -and $mcpSummary.Contains([string]$act)) {
                $mcpSummary[[string]$act]++
            }
        }
    }

    $hermesErrorVal = Get-SafeProperty $hermesJson 'Error'
    $hermesStateVal = Get-SafeProperty $hermesJson 'State'
    $hermesReasonVal = Get-SafeProperty $hermesJson 'Reason'
    $hermesSummaryObj = Get-SafeProperty $hermesJson 'Summary'
    $hermesCounts = $null
    if ($null -ne $hermesErrorVal) {
        $hermesSummaryValue = 'error'
    }
    elseif ([string]$hermesStateVal -ceq 'checked') {
        $hermesCounts = [ordered]@{
            install   = [int]((Get-SafeProperty $hermesSummaryObj 'install') ?? 0)
            update    = [int]((Get-SafeProperty $hermesSummaryObj 'update') ?? 0)
            unchanged = [int]((Get-SafeProperty $hermesSummaryObj 'unchanged') ?? 0)
            prune     = [int]((Get-SafeProperty $hermesSummaryObj 'prune') ?? 0)
            unknown   = [int]((Get-SafeProperty $hermesSummaryObj 'unknown') ?? 0)
            blocked   = [int]((Get-SafeProperty $hermesSummaryObj 'blocked') ?? 0)
        }
        $hermesSummaryValue = $hermesCounts
    }
    else {
        $hermesSummaryValue = [string]$hermesStateVal
    }

    $configError = Get-SafeProperty $configJson 'Error'
    if ($configError) { $configSummary = $null }
    if ($mcpErrorVal) { $mcpSummary = $null }
    $skillsHasError = ($skillsReport.State -ceq 'error')
    $exitCode = [int][bool]($envReport.Failed -or $configError -or $agErrorVal -or $mcpErrorVal -or $hermesErrorVal -or $skillsHasError)
    $summary = [ordered]@{
        Environment = $envReport.Recorded
        Skills      = $skillsSummaryValue
        Config      = $configSummary
        Antigravity = $agAction
        Hermes      = $hermesSummaryValue
        Mcp         = $mcpSummary
    }

    $aggregatedReport = [ordered]@{
        SchemaVersion = 1
        Environment   = [ordered]@{
            Recorded  = $envReport.Recorded
            Reason    = $envReport.StateReason
            Available = $envReport.Available
            Failed    = $envReport.Failed
        }
        Skills        = $skillsReport
        Config        = $configJson
        Antigravity   = $agJson
        Hermes        = $hermesJson
        Mcp           = $mcpJson
        Summary       = $summary
    }

    if ($envError) { $aggregatedReport.Environment.Error = $envError }
    if ($isJson) {
        $jsonStr = ConvertTo-Json -InputObject $aggregatedReport -Depth 20
        Write-Output $jsonStr
        exit $exitCode
    }

    # Human-readable layout
    Write-Host '=== Unified Status ===' -ForegroundColor White
    Write-Host ''
    Write-Host '[Environment]' -ForegroundColor Cyan
    Write-Host ("  Last recorded Apply environment: {0} (record only; live contents may differ)" -f $envReport.Recorded)
    if ($envError) {
        Write-Host "  $envError" -ForegroundColor Red
    }
    elseif ($envReport.Failed) {
        Write-Host ("  Deploy state read failed: {0}. Check -StateRoot and the local deployment record before retrying." -f $envReport.StateReason) -ForegroundColor Red
    }
    elseif ($envReport.StateReason) {
        Write-Host ("  Record unavailable reason: {0}. Inspect local deploy record." -f $envReport.StateReason) -ForegroundColor Yellow
    }
    Write-Host ("  Available environments: {0}" -f ($envReport.Available -join ', '))
    Write-Host ''

    Write-Host '[Codex Live Skills]' -ForegroundColor Cyan
    if ($skillsReport.State -eq 'checked') {
        $ss = $skillsReport.Summary
        $skillsColor = if ($ss.install -gt 0 -or $ss.update -gt 0 -or $ss.prune -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host ("  Environment: {0}  live={1}" -f $skillsReport.Environment, $skillsReport.LiveRoot)
        Write-Host ("  Summary: install={0}  update={1}  unchanged={2}  prune={3}  unknown={4}" -f $ss.install, $ss.update, $ss.unchanged, $ss.prune, $ss.unknown) -ForegroundColor $skillsColor
    }
    elseif ($skillsReport.State -eq 'build-required') {
        Write-Host ("  Environment: {0}  state=build-required (run build-skills.ps1 before checking live skill drift)" -f $skillsReport.Environment) -ForegroundColor Yellow
    }
    elseif ($skillsReport.State -eq 'unavailable') {
        Write-Host ("  State: unavailable (environment={0})" -f $skillsReport.Environment) -ForegroundColor Yellow
    }
    else {
        Write-Host ("  Error checking Codex live skills: {0}" -f $skillsReport.Error) -ForegroundColor Red
    }
    Write-Host ''

    Write-Host '[Config Status]' -ForegroundColor Cyan
    if ($configJson -is [array] -and $configJson.Count -gt 0) {
        foreach ($item in $configJson) {
            $itemStatus = Get-SafeProperty $item 'Status'
            $itemPlatform = Get-SafeProperty $item 'Platform'
            $itemItem = Get-SafeProperty $item 'Item'
            $itemDetail = Get-SafeProperty $item 'Detail'
            $color = switch ($itemStatus) {
                'in-sync'       { 'Green' }
                'differs'       { 'Yellow' }
                'blocked'       { 'Red' }
                'not-installed' { 'DarkGray' }
                default         { 'Cyan' }
            }
            Write-Host ("  {0,-12} {1,-13} {2} ({3})" -f $itemPlatform, $itemStatus, $itemItem, $itemDetail) -ForegroundColor $color
        }
        Write-Host ("  Summary: in-sync={0}  differs={1}  repo-only={2}  home-only={3}  not-installed={4}  blocked={5}" -f $configSummary['in-sync'], $configSummary['differs'], $configSummary['repo-only'], $configSummary['home-only'], $configSummary['not-installed'], $configSummary['blocked'])
    }
    elseif ($null -ne $configError) {
        Write-Host ("  Error querying config status: {0}" -f $configError) -ForegroundColor Red
    }
    else {
        Write-Host '  No managed config items found.'
    }
    Write-Host ''

    Write-Host '[Antigravity Plugins]' -ForegroundColor Cyan
    if ($null -ne $agNameVal) {
        $agColor = if ($agActionVal -eq 'unchanged') { 'Green' } else { 'Yellow' }
        Write-Host ("  Plugin: {0} v{1}  action={2} ({3})" -f $agNameVal, $agVersionVal, $agActionVal, $agReasonVal) -ForegroundColor $agColor
        if ([string]$agActionVal -ceq 'update') {
            if ([string]$agApplyRequirement -ceq 'build-with-current-agy-before-apply') {
                Write-Host ("  Next step: {0}" -f (Get-SafeProperty $agJson 'NextStep')) -ForegroundColor Yellow
            }
            elseif ([string]$agApplyRequirement -ceq 'none') {
                Write-Host '  Next step: update package is ready for reviewed Apply; no rebuild is required.' -ForegroundColor Green
            }
        }
        if ($agExternals -is [array]) {
            foreach ($ext in $agExternals) {
                $extName = Get-SafeProperty $ext 'Name'
                $extAction = Get-SafeProperty $ext 'Action'
                $extReason = Get-SafeProperty $ext 'Reason'
                $extColor = if ($extAction -eq 'unchanged') { 'Green' } else { 'Yellow' }
                Write-Host ("  External: {0}  action={1} ({2})" -f $extName, $extAction, $extReason) -ForegroundColor $extColor
            }
        }
    }
    elseif ($null -ne $agErrorVal) {
        Write-Host ("  Error querying Antigravity plugins: {0}" -f $agErrorVal) -ForegroundColor Red
    }
    else {
        Write-Host '  Antigravity plugin status unavailable.' -ForegroundColor Yellow
    }
    Write-Host ''

    Write-Host '[MCP Projections]' -ForegroundColor Cyan
    if ($mcpItems -is [array] -and $mcpItems.Count -gt 0) {
        foreach ($item in $mcpItems) {
            $mcpPlatform = Get-SafeProperty $item 'Platform'
            $mcpServer = Get-SafeProperty $item 'Server'
            $mcpAction = Get-SafeProperty $item 'Action'
            $mcpReason = Get-SafeProperty $item 'Reason'
            $mcpColor = switch ($mcpAction) {
                'unchanged'     { 'Green' }
                'blocked'       { 'Red' }
                'not-installed' { 'DarkGray' }
                default         { 'Yellow' }
            }
            Write-Host ("  [{0,-11}] {1,-16} {2,-13} ({3})" -f $mcpPlatform, $mcpServer, $mcpAction, $mcpReason) -ForegroundColor $mcpColor
        }
        Write-Host ("  Summary: add={0}  update={1}  unchanged={2}  blocked={3}  not-installed={4}" -f $mcpSummary['add'], $mcpSummary['update'], $mcpSummary['unchanged'], $mcpSummary['blocked'], $mcpSummary['not-installed'])
    }
    elseif ($null -ne $mcpErrorVal) {
        Write-Host ("  Error querying MCP projections: {0}" -f $mcpErrorVal) -ForegroundColor Red
    }
    else {
        Write-Host '  No managed MCP projections found.'
    }
    Write-Host ''

    Write-Host '[Hermes Skills]' -ForegroundColor Cyan
    if ($null -ne $hermesErrorVal) {
        Write-Host ("  Error checking Hermes skills: {0}" -f $hermesErrorVal) -ForegroundColor Red
    }
    elseif ([string]$hermesStateVal -ceq 'checked') {
        $hsColor = if ($hermesCounts.blocked -gt 0) { 'Red' } elseif ($hermesCounts.install -gt 0 -or $hermesCounts.update -gt 0 -or $hermesCounts.prune -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host ("  Category: {0}  live={1}" -f (Get-SafeProperty $hermesJson 'Category'), (Get-SafeProperty $hermesJson 'LiveRoot'))
        Write-Host ("  Summary: install={0}  update={1}  unchanged={2}  prune={3}  unknown={4}  blocked={5}" -f $hermesCounts.install, $hermesCounts.update, $hermesCounts.unchanged, $hermesCounts.prune, $hermesCounts.unknown, $hermesCounts.blocked) -ForegroundColor $hsColor
    }
    elseif ([string]$hermesStateVal -ceq 'not-installed') {
        Write-Host ("  State: not-installed ({0})" -f $hermesReasonVal) -ForegroundColor DarkGray
    }
    elseif ([string]$hermesStateVal -ceq 'blocked') {
        Write-Host ("  State: blocked ({0})" -f $hermesReasonVal) -ForegroundColor Red
    }
    else {
        Write-Host '  Hermes skills status unavailable.' -ForegroundColor Yellow
    }
    exit $exitCode
}

function ConvertTo-RouteArguments {
    param(
        [Parameter(Mandatory)] [string] $CommandName,
        [Parameter(Mandatory)] [string] $GroupAction,
        [AllowEmptyCollection()] [object[]] $Arguments = @()
    )

    $routeSpecs = @{
        antigravity = @{
            IncludeActionArg   = $true
            PassThroughUnknown = $false
            ModeAction         = 'deploy'
            ValueParams        = @{
                '-RepoRoot' = @{ DisallowedValues = @('-RepoRoot', '-JsonPath', '-ExternalPlugin'); DuplicateError = 'Duplicate Antigravity path parameter.'; MissingValueError = 'Antigravity path parameters require a value.' }
                '-JsonPath' = @{ DisallowedValues = @('-RepoRoot', '-JsonPath', '-ExternalPlugin'); DuplicateError = 'Duplicate Antigravity path parameter.'; MissingValueError = 'Antigravity path parameters require a value.' }
            }
            MultiParams        = @{
                '-ExternalPlugin' = @{
                    AllowedActions    = @('deploy')
                    DisallowedError   = "The antigravity $GroupAction command accepts no -ExternalPlugin parameter."
                    DisallowedValues  = @('-RepoRoot', '-JsonPath', '-ExternalPlugin', '-DryRun', '-Apply')
                    MissingValueError = 'Antigravity -ExternalPlugin requires a value.'
                    Pattern           = '^[a-z0-9][a-z0-9-]*$'
                    PatternError      = 'Antigravity -ExternalPlugin value must be a single lowercase plugin name.'
                    SplitComma        = $false
                    Dedupe            = $false
                }
            }
            SwitchParams       = @{}
            UnsupportedError   = 'Unsupported antigravity argument. Use exact -RepoRoot, -JsonPath, -ExternalPlugin, -DryRun or -Apply names.'
            ModeDisallowedErr  = "The antigravity $GroupAction command accepts no -DryRun or -Apply mode."
            DuplicateModeError = 'The antigravity deploy command accepts only one mode: -DryRun or -Apply.'
            MissingModeError   = 'The antigravity deploy command requires an explicit -DryRun or -Apply mode. Run -DryRun first.'
        }
        hermes = @{
            IncludeActionArg   = $true
            ActionValues       = @{ status = 'Status'; deploy = 'Deploy' }
            PassThroughUnknown = $false
            ModeAction         = 'deploy'
            ValueParams        = @{
                '-RepoRoot'  = @{ DisallowedValues = @('-RepoRoot', '-HomeRoot', '-StateRoot', '-JsonPath', '-Retire'); DuplicateError = 'Duplicate Hermes path parameter: {0}.'; MissingValueError = 'Hermes parameter {0} requires a value.' }
                '-HomeRoot'  = @{ DisallowedValues = @('-RepoRoot', '-HomeRoot', '-StateRoot', '-JsonPath', '-Retire'); DuplicateError = 'Duplicate Hermes path parameter: {0}.'; MissingValueError = 'Hermes parameter {0} requires a value.' }
                '-StateRoot' = @{ DisallowedValues = @('-RepoRoot', '-HomeRoot', '-StateRoot', '-JsonPath', '-Retire'); DuplicateError = 'Duplicate Hermes path parameter: {0}.'; MissingValueError = 'Hermes parameter {0} requires a value.' }
                '-JsonPath'  = @{ DisallowedValues = @('-RepoRoot', '-HomeRoot', '-StateRoot', '-JsonPath', '-Retire'); DuplicateError = 'Duplicate Hermes path parameter: {0}.'; MissingValueError = 'Hermes parameter {0} requires a value.' }
            }
            MultiParams        = @{
                '-Retire' = @{
                    AllowedActions    = @('deploy')
                    DisallowedError   = "The hermes $GroupAction command accepts no -Retire parameter."
                    DisallowedValues  = @('-RepoRoot', '-HomeRoot', '-StateRoot', '-JsonPath', '-Retire', '-DryRun', '-Apply', '-Json', '-SkipSecretScan')
                    MissingValueError = 'Hermes -Retire requires a skill name.'
                    EmptyTokensError  = 'Hermes -Retire requires at least one skill name.'
                    SplitComma        = $true
                    Pattern           = '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$'
                    PatternError      = 'Hermes -Retire value must be a valid skill name.'
                    Dedupe            = $true
                    CaseSensitive     = $false
                }
            }
            SwitchParams       = @{
                '-Json'           = @{ DuplicateError = 'Duplicate Hermes -Json switch.' }
                '-SkipSecretScan' = @{ AllowedActions = @('deploy'); DisallowedError = "The hermes $GroupAction command accepts no -SkipSecretScan parameter."; DuplicateError = 'Duplicate Hermes -SkipSecretScan switch.' }
            }
            UnsupportedError   = 'Unsupported hermes argument. Use exact -RepoRoot, -HomeRoot, -StateRoot, -JsonPath, -Retire, -Json, -SkipSecretScan, -DryRun or -Apply names.'
            ModeDisallowedErr  = "The hermes $GroupAction command accepts no -DryRun or -Apply mode."
            DuplicateModeError = 'The hermes deploy command accepts only one mode: -DryRun or -Apply.'
            MissingModeError   = 'The hermes deploy command requires an explicit -DryRun or -Apply mode. Run -DryRun first.'
        }
        mcp = @{
            IncludeActionArg   = $true
            PassThroughUnknown = $false
            ModeAction         = 'deploy'
            ValueParams        = @{
                '-RepoRoot'   = @{ DisallowedValues = @('-RepoRoot', '-HomeRoot', '-BackupRoot', '-JsonPath', '-Platform', '-Server'); DuplicateError = 'Duplicate MCP path parameter: {0}.'; MissingValueError = 'MCP parameter {0} requires a value.' }
                '-HomeRoot'   = @{ DisallowedValues = @('-RepoRoot', '-HomeRoot', '-BackupRoot', '-JsonPath', '-Platform', '-Server'); DuplicateError = 'Duplicate MCP path parameter: {0}.'; MissingValueError = 'MCP parameter {0} requires a value.' }
                '-BackupRoot' = @{ AllowedActions = @('deploy'); DisallowedError = "The mcp $GroupAction command accepts no -BackupRoot parameter."; DisallowedValues = @('-RepoRoot', '-HomeRoot', '-BackupRoot', '-JsonPath', '-Platform', '-Server'); DuplicateError = 'Duplicate MCP path parameter: {0}.'; MissingValueError = 'MCP parameter {0} requires a value.' }
                '-JsonPath'   = @{ DisallowedValues = @('-RepoRoot', '-HomeRoot', '-BackupRoot', '-JsonPath', '-Platform', '-Server'); DuplicateError = 'Duplicate MCP path parameter: {0}.'; MissingValueError = 'MCP parameter {0} requires a value.' }
            }
            MultiParams        = @{
                '-Platform' = @{
                    DisallowedValues  = @('-RepoRoot', '-HomeRoot', '-BackupRoot', '-JsonPath', '-Platform', '-Server', '-DryRun', '-Apply', '-Json', '-SkipSecretScan')
                    MissingValueError = 'MCP -Platform requires a value.'
                    EmptyTokensError  = 'MCP -Platform requires at least one platform name.'
                    SplitComma        = $true
                    AllowedValues     = @('Antigravity', 'Codex', 'Hermes')
                    AllowedError      = "Unsupported MCP platform '{0}'. Expected Antigravity, Codex, or Hermes."
                    Dedupe            = $true
                    CaseSensitive     = $false
                }
                '-Server'   = @{
                    DisallowedValues  = @('-RepoRoot', '-HomeRoot', '-BackupRoot', '-JsonPath', '-Platform', '-Server', '-DryRun', '-Apply', '-Json', '-SkipSecretScan')
                    MissingValueError = 'MCP -Server requires a value.'
                    EmptyTokensError  = 'MCP -Server requires at least one server name.'
                    SplitComma        = $true
                    Pattern           = '^[a-z0-9][a-z0-9_-]*$'
                    PatternError      = 'MCP -Server value must be a valid lowercase server name.'
                    Dedupe            = $true
                    CaseSensitive     = $true
                }
            }
            SwitchParams       = @{
                '-Json'           = @{ DuplicateError = 'Duplicate MCP -Json switch.' }
                '-SkipSecretScan' = @{ AllowedActions = @('deploy'); DisallowedError = "The mcp $GroupAction command accepts no -SkipSecretScan parameter."; DuplicateError = 'Duplicate MCP -SkipSecretScan switch.' }
            }
            UnsupportedError   = 'Unsupported mcp argument. Use exact -RepoRoot, -HomeRoot, -BackupRoot, -JsonPath, -Platform, -Server, -Json, -SkipSecretScan, -DryRun or -Apply names.'
            ModeDisallowedErr  = "The mcp $GroupAction command accepts no -DryRun or -Apply mode."
            DuplicateModeError = 'The mcp deploy command accepts only one mode: -DryRun or -Apply.'
            MissingModeError   = 'The mcp deploy command requires an explicit -DryRun or -Apply mode. Run -DryRun first.'
        }
        config = @{
            IncludeActionArg   = $false
            PassThroughUnknown = $true
            ModeAction         = $null
            ValueParams        = @{}
            MultiParams        = @{
                '-Platform' = @{
                    CaseInsensitive       = $true
                    AllowColonSyntax      = $true
                    RejectLeadingDashVal  = $true
                    MissingValueError     = 'Config -Platform requires at least one platform name. Expected Codex, Antigravity, or Hermes.'
                    EmptyTokensError      = 'Config -Platform requires at least one platform name. Expected Codex, Antigravity, or Hermes.'
                    SplitComma            = $false
                    Dedupe                = $false
                }
            }
            SwitchParams       = @{}
        }
    }

    $spec = $routeSpecs[$CommandName]
    $outArgs = [System.Collections.Generic.List[object]]::new()
    if ($spec.IncludeActionArg) {
        $actionVal = if ($spec.ContainsKey('ActionValues') -and $spec.ActionValues.ContainsKey($GroupAction)) { $spec.ActionValues[$GroupAction] } else { $GroupAction }
        $outArgs.Add('-Action')
        $outArgs.Add($actionVal)
    }

    $seenParams = @{}
    $multiBuckets = @{}
    foreach ($k in $spec.MultiParams.Keys) { $multiBuckets[$k] = [System.Collections.Generic.List[string]]::new() }
    $modeSelected = $null

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $rawItem = $Arguments[$i]
        $argument = [string] $rawItem

        if ($spec.ValueParams.ContainsKey($argument)) {
            $vp = $spec.ValueParams[$argument]
            if ($vp.ContainsKey('AllowedActions') -and ($GroupAction -notin $vp.AllowedActions)) {
                Write-Error $vp.DisallowedError -ErrorAction Continue
                exit 1
            }
            if ($seenParams.ContainsKey($argument)) {
                Write-Error ([string]::Format($vp.DuplicateError, $argument)) -ErrorAction Continue
                exit 1
            }
            if ($i + 1 -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace([string]$Arguments[$i + 1]) -or ($Arguments[$i + 1] -in $vp.DisallowedValues)) {
                Write-Error ([string]::Format($vp.MissingValueError, $argument)) -ErrorAction Continue
                exit 1
            }
            $seenParams[$argument] = $true
            $outArgs.Add($argument + ':' + [string]$Arguments[++$i])
            continue
        }

        $matchedMultiKey = $null
        $colonValue = $null
        foreach ($mk in $spec.MultiParams.Keys) {
            $mpSpec = $spec.MultiParams[$mk]
            $isExact = if ($mpSpec['CaseInsensitive']) { $argument -ieq $mk } else { $argument -eq $mk }
            if ($isExact) {
                $matchedMultiKey = $mk
                break
            }
            if ($mpSpec['AllowColonSyntax'] -and ($argument -ilike ($mk + ':*'))) {
                $matchedMultiKey = $mk
                $colonValue = $argument.Substring($mk.Length + 1)
                break
            }
        }
        if ($null -ne $matchedMultiKey) {
            $mp = $spec.MultiParams[$matchedMultiKey]
            if ($mp.ContainsKey('AllowedActions') -and ($GroupAction -notin $mp.AllowedActions)) {
                Write-Error $mp.DisallowedError -ErrorAction Continue
                exit 1
            }
            $seenParams[$matchedMultiKey] = $true
            $rawVal = $null
            if ($null -ne $colonValue) {
                if ([string]::IsNullOrWhiteSpace($colonValue)) {
                    Write-Error $mp.MissingValueError -ErrorAction Continue
                    exit 1
                }
                $rawVal = $colonValue
            }
            else {
                $hasNext = ($i + 1 -lt $Arguments.Count)
                $nextStr = if ($hasNext) { [string]$Arguments[$i + 1] } else { '' }
                $badNext = (-not $hasNext) -or [string]::IsNullOrWhiteSpace($nextStr) -or
                    ($mp['RejectLeadingDashVal'] -and $nextStr.StartsWith('-')) -or
                    ($mp.ContainsKey('DisallowedValues') -and ($nextStr -in $mp.DisallowedValues))
                if ($badNext) {
                    Write-Error $mp.MissingValueError -ErrorAction Continue
                    exit 1
                }
                $rawVal = [string]$Arguments[++$i]
            }

            if ($mp['SplitComma']) {
                $tokens = @($rawVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($tokens.Count -eq 0) {
                    Write-Error $mp.EmptyTokensError -ErrorAction Continue
                    exit 1
                }
                foreach ($token in $tokens) {
                    if ($mp.ContainsKey('AllowedValues') -and ($token -notin $mp.AllowedValues)) {
                        Write-Error ([string]::Format($mp.AllowedError, $token)) -ErrorAction Continue
                        exit 1
                    }
                    if ($mp.ContainsKey('Pattern') -and ($token -cnotmatch $mp.Pattern)) {
                        Write-Error $mp.PatternError -ErrorAction Continue
                        exit 1
                    }
                    $already = if ($mp['CaseSensitive']) { $token -cin $multiBuckets[$matchedMultiKey] } else { $token -in $multiBuckets[$matchedMultiKey] }
                    if (-not $mp['Dedupe'] -or -not $already) {
                        $multiBuckets[$matchedMultiKey].Add($token)
                    }
                }
            }
            else {
                if ($mp.ContainsKey('Pattern') -and ($rawVal -cnotmatch $mp.Pattern)) {
                    Write-Error $mp.PatternError -ErrorAction Continue
                    exit 1
                }
                $multiBuckets[$matchedMultiKey].Add($rawVal)
            }
            continue
        }

        if ($spec.SwitchParams.ContainsKey($argument)) {
            $sp = $spec.SwitchParams[$argument]
            if ($sp.ContainsKey('AllowedActions') -and ($GroupAction -notin $sp.AllowedActions)) {
                Write-Error $sp.DisallowedError -ErrorAction Continue
                exit 1
            }
            if ($seenParams.ContainsKey($argument)) {
                Write-Error $sp.DuplicateError -ErrorAction Continue
                exit 1
            }
            $seenParams[$argument] = $true
            $outArgs.Add($argument)
            continue
        }

        if ($spec.PassThroughUnknown) {
            $outArgs.Add($rawItem)
            continue
        }

        if ($argument -notin @('-DryRun', '-Apply')) {
            Write-Error $spec.UnsupportedError -ErrorAction Continue
            exit 1
        }
        if ($GroupAction -ne $spec.ModeAction) {
            Write-Error $spec.ModeDisallowedErr -ErrorAction Continue
            exit 1
        }
        if ($null -ne $modeSelected) {
            Write-Error $spec.DuplicateModeError -ErrorAction Continue
            exit 1
        }
        $modeSelected = $argument
        if ($argument -eq '-Apply') { $outArgs.Add('-Apply') }
    }

    if ($null -ne $spec.ModeAction -and $GroupAction -eq $spec.ModeAction -and $null -eq $modeSelected) {
        Write-Error $spec.MissingModeError -ErrorAction Continue
        exit 1
    }

    foreach ($mk in $spec.MultiParams.Keys) {
        $mp = $spec.MultiParams[$mk]
        if ($multiBuckets[$mk].Count -gt 0) {
            if (-not $mp['SplitComma'] -and $mp.ContainsKey('EmptyTokensError')) {
                $tokens = @($multiBuckets[$mk] | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($tokens.Count -eq 0) {
                    Write-Error $mp.EmptyTokensError -ErrorAction Continue
                    exit 1
                }
            }
            $outArgs.Add($mk + ':' + ($multiBuckets[$mk] -join ','))
        }
    }

    return ,$outArgs.ToArray()
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-Error 'A command is required.' -ErrorAction Continue
    Write-Usage
    exit 1
}

if ($Command -ieq 'help') {
    $topics = @($RemainingArguments | Where-Object { $null -ne $_ })
    if ($topics.Count -eq 0) { Write-Usage; exit 0 }
    if ($topics.Count -ne 1 -or $topics[0] -notin @('config', 'env', 'profile', 'skills', 'antigravity', 'hermes', 'mcp', 'status', 'dashboard')) {
        Write-Error 'Unsupported help topic. Use help config, help env, help profile, help skills, help antigravity, help hermes, help mcp, help status, or help dashboard.' -ErrorAction Continue
        exit 1
    }
    Write-Usage ([string] $topics[0]).ToLowerInvariant()
    exit 0
}

$commandMap = @{
    doctor    = 'doctor.ps1'
    build     = 'build-skills.ps1'
    scan      = 'scan-secrets.ps1'
    sync      = 'deploy.ps1'
    status    = $null
    dashboard = 'dashboard.ps1'
}

$groupCommandMaps = @{
    antigravity = @{
        build  = 'antigravity-plugins.ps1'
        status = 'antigravity-plugins.ps1'
        deploy = 'antigravity-plugins.ps1'
    }
    hermes = @{
        status = 'hermes-skills.ps1'
        deploy = 'hermes-skills.ps1'
    }
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
    mcp = @{
        status = 'mcp-sync.ps1'
        deploy = 'mcp-sync.ps1'
    }
}

$normalizedCommand = $Command.ToLowerInvariant()
if (-not $groupCommandMaps.ContainsKey($normalizedCommand) -and -not $commandMap.ContainsKey($normalizedCommand)) {
    Write-Error "Unsupported command: $Command" -ErrorAction Continue
    Write-Usage
    exit 1
}

$forwardedArguments = @($RemainingArguments | Where-Object { $null -ne $_ })
if ($normalizedCommand -eq 'status') {
    if ($forwardedArguments.Count -eq 1 -and [string]$forwardedArguments[0] -ieq 'help') {
        Write-Usage 'status'
        exit 0
    }
    Invoke-UnifiedStatus $forwardedArguments
}
if ($normalizedCommand -eq 'dashboard') {
    if ($forwardedArguments.Count -eq 1 -and [string]$forwardedArguments[0] -ieq 'help') {
        Write-Usage 'dashboard'
        exit 0
    }
}
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

    if ($normalizedCommand -in @('antigravity', 'hermes', 'mcp', 'config')) {
        $forwardedArguments = ConvertTo-RouteArguments -CommandName $normalizedCommand -GroupAction $groupAction -Arguments $forwardedArguments
    }

    $requiresExplicitMode = (($normalizedCommand -eq 'env' -and $groupAction -eq 'deploy') -or
        ($normalizedCommand -eq 'config' -and $groupAction -in @('pull', 'push')) -or
        ($normalizedCommand -eq 'profile' -and $groupAction -eq 'apply') -or
        ($normalizedCommand -eq 'skills' -and $groupAction -eq 'promote'))
    if ($requiresExplicitMode) {
        $forwardedArguments = ConvertTo-ExplicitModeArguments $forwardedArguments "$normalizedCommand $groupAction"
    }
}
else {
    $targetScriptName = $commandMap[$normalizedCommand]
    if ($normalizedCommand -eq 'sync') {
        $forwardedArguments = ConvertTo-ExplicitModeArguments $forwardedArguments $normalizedCommand
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

$normalizedForward = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $forwardedArguments.Count; $i++) {
    $item = $forwardedArguments[$i]
    if ($item -is [string] -and $item -ieq '-Json' -and ($i + 1) -lt $forwardedArguments.Count -and $forwardedArguments[$i + 1] -is [bool]) {
        $boolVal = [bool] $forwardedArguments[++$i]
        $normalizedForward.Add($(if ($boolVal) { '-Json' } else { '-Json:$false' }))
        continue
    }
    if ($item -is [string] -and $item -imatch '^-Json:\$?(true|false)$') {
        $normalizedForward.Add($(if ($Matches[1] -ieq 'true') { '-Json' } else { '-Json:$false' }))
        continue
    }
    $normalizedForward.Add($item)
}
$forwardList = @($normalizedForward)
$jsonStdout = ($normalizedCommand -eq 'antigravity') -or
    ($normalizedCommand -eq 'dashboard' -and (@($forwardList | Where-Object { $_ -is [string] -and $_ -ieq '-Check' }).Count -gt 0)) -or
    (@($forwardList | Where-Object { $_ -is [string] -and $_ -ieq '-Json' }).Count -gt 0)
if (-not $jsonStdout) {
    Write-Host "Invoking script: $targetScript"
}
& $pwshPath -NoProfile -File $targetScript @forwardList
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
