#requires -Version 7.0
<#
.SYNOPSIS
    Provides a single command entry point for repository maintenance scripts.

.DESCRIPTION
    Dispatches a supported subcommand to the existing repository script in a
    separate PowerShell process. Arguments after the subcommand are passed
    through unchanged and are not echoed by the wrapper.

.PARAMETER Command
    One of: help, doctor, build, scan, sync, config, profile, skills, env, antigravity, mcp, status, or dashboard.

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
            Write-Host 'status: read-only overview aggregating env list, config status, antigravity status, and mcp status.'
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
                Write-Host 'Options: -Platform Codex|Antigravity (default Codex), -RepoRoot <path>, -HomeRoot <path>.'
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
                Write-Host 'status: read-only inspection of Antigravity and Codex managed MCP projections.'
                Write-Host 'deploy: previews per-entry projection with -DryRun; authorized -Apply merges Antigravity JSON and runs codex mcp CLI.'
                Write-Host 'Examples: mcp status; mcp deploy -DryRun; mcp deploy -Platform Codex,Antigravity -DryRun'
                Write-Host 'Options: -Platform Antigravity|Codex, -Server <name>, -RepoRoot <path>, -HomeRoot <path>, -BackupRoot <path>, -JsonPath <file>, -Json, -SkipSecretScan.'
                Write-Host 'Only deploy accepts -DryRun, -Apply, -BackupRoot, or -SkipSecretScan.'
            }
        }
        Write-Host 'deploy, pull/push, apply and promote require exactly one mode: -DryRun or -Apply. Review the dry run before authorized Apply.'
        return
    }
    Write-Host 'Usage: pwsh -File scripts/agent-dotfiles.ps1 <command> [arguments]'
    Write-Host 'Commands: help, doctor, build, scan, sync, config, profile, skills, env, antigravity, mcp, status, dashboard'
    Write-Host 'Status actions: status [-Json] aggregates env list, config status, antigravity status, and mcp status.'
    Write-Host 'Dashboard actions: dashboard [-Port <port>] [-NoBrowser] [-Check] [-Offline] launches the local Chinese web monitoring console.'
    Write-Host 'Antigravity actions: build, status, deploy -DryRun|-Apply; separate from sync and env deploy.'
    Write-Host 'MCP actions: status, deploy -DryRun|-Apply; separate from sync and requires -DryRun or -Apply.'
    Write-Host 'Sync runs deploy.ps1 (skills plus config) and requires exactly one explicit mode: -DryRun or -Apply.'
    Write-Host 'Run sync in dry-run mode first: scripts/agent-dotfiles.ps1 sync -DryRun'
    Write-Host 'Config actions: status, pull, push. Profile actions: status, build, apply.'
    Write-Host 'Skills actions: promote -Path <dir> -Name <name> -Type <type> [-Replace] -DryRun|-Apply.'
    Write-Host 'Env actions: list [-RepoRoot <path>] [-StateRoot <path>] [-JsonPath <file>], deploy <name> -DryRun|-Apply.'
    Write-Host 'sync, env deploy, antigravity deploy, mcp deploy, config pull/push, profile apply, and skills promote require exactly one explicit mode: -DryRun or -Apply.'
    Write-Host 'build generates output; env list -JsonPath writes a report without a mode.'
    Write-Host 'Group help: help config (or config help); also status, dashboard, env, profile, skills, antigravity and mcp.'
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
        $envReport = [ordered]@{ Recorded = 'unavailable'; StateReason = 'catalog-unavailable'; Available = @(); Failed = $true }
    }

    # 2. Config status
    $configStatusScript = Join-Path $PSScriptRoot 'config-status.ps1'
    $configJson = $null
    if (Test-Path -LiteralPath $configStatusScript -PathType Leaf) {
        $configArgs = @('-Platform', 'Codex,Antigravity', '-Json')
        if ($repoRoot) { $configArgs += @('-RepoRoot', $repoRoot) }
        if ($seenParameters.Contains('-HomeRoot')) { $configArgs += @('-HomeRoot', $homeRoot) }
        $configOut = & $pwshPath -NoProfile -File $configStatusScript @configArgs 2>&1
        $configCode = $LASTEXITCODE
        if ($configCode -eq 0) {
            $configJson = Convert-ChildJson $configOut
            if ($null -ne (Get-SafeProperty $configJson 'Status')) {
                $configJson = @($configJson)
            }
            elseif ($configJson -isnot [array] -and $null -eq (Get-SafeProperty $configJson 'Error')) {
                $configJson = [ordered]@{ Error = 'Expected a config status report.' }
            }
        }
        else {
            $configJson = [ordered]@{ Error = "config-status.ps1 failed (exit $configCode)"; Raw = ($configOut -join "`n") }
        }
    }
    else {
        $configJson = [ordered]@{ Error = "config-status.ps1 not found at $configStatusScript" }
    }

    # 3. Antigravity plugin status
    $agScript = Join-Path $PSScriptRoot 'antigravity-plugins.ps1'
    $agJson = $null
    if (Test-Path -LiteralPath $agScript -PathType Leaf) {
        $agArgs = @('-Action', 'Status')
        if ($repoRoot) { $agArgs += @('-RepoRoot', $repoRoot) }
        if ($seenParameters.Contains('-StateRoot')) {
            $agCommand = Get-Command $agScript -ErrorAction SilentlyContinue
            if ($null -ne $agCommand -and $agCommand.Parameters.ContainsKey('StateRoot')) {
                $agArgs += @('-StateRoot', (Join-Path $stateRoot 'antigravity'))
            }
        }
        $agOut = & $pwshPath -NoProfile -File $agScript @agArgs 2>&1
        $agCode = $LASTEXITCODE
        if ($agCode -eq 0) {
            $agJson = Convert-ChildJson $agOut
            if ($null -eq (Get-SafeProperty $agJson 'Action') -and $null -eq (Get-SafeProperty $agJson 'Error')) {
                $agJson = [ordered]@{ Error = 'Expected an Antigravity plugin status report.' }
            }
        }
        else {
            $agJson = [ordered]@{ Error = "antigravity-plugins.ps1 failed (exit $agCode)"; Raw = ($agOut -join "`n") }
        }
    }
    else {
        $agJson = [ordered]@{ Error = "antigravity-plugins.ps1 not found at $agScript" }
    }

    # 4. MCP status
    $mcpScript = Join-Path $PSScriptRoot 'mcp-sync.ps1'
    $mcpJson = $null
    if (Test-Path -LiteralPath $mcpScript -PathType Leaf) {
        $mcpArgs = @('-Action', 'Status', '-Json')
        if ($repoRoot) { $mcpArgs += @('-RepoRoot', $repoRoot) }
        if ($seenParameters.Contains('-HomeRoot')) { $mcpArgs += @('-HomeRoot', $homeRoot) }
        $mcpOut = & $pwshPath -NoProfile -File $mcpScript @mcpArgs 2>&1
        $mcpCode = $LASTEXITCODE
        if ($mcpCode -eq 0) {
            $mcpJson = Convert-ChildJson $mcpOut
            if ($null -eq (Get-SafeProperty $mcpJson 'Summary') -and (Get-SafeProperty $mcpJson 'Items') -isnot [array] -and $null -eq (Get-SafeProperty $mcpJson 'Error')) {
                $mcpJson = [ordered]@{ Error = 'Expected an MCP status report.' }
            }
        }
        else {
            $mcpJson = [ordered]@{ Error = "mcp-sync.ps1 failed (exit $mcpCode)"; Raw = ($mcpOut -join "`n") }
        }
    }
    else {
        $mcpJson = [ordered]@{ Error = "mcp-sync.ps1 not found at $mcpScript" }
    }

    # Summary calculations
    $configSummary = [ordered]@{
        'in-sync'   = 0
        'differs'   = 0
        'repo-only' = 0
        'home-only' = 0
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
        'add'       = 0
        'update'    = 0
        'unchanged' = 0
        'blocked'   = 0
    }
    $mcpSummaryObj = Get-SafeProperty $mcpJson 'Summary'
    $mcpItems      = Get-SafeProperty $mcpJson 'Items'
    $mcpErrorVal   = Get-SafeProperty $mcpJson 'Error'

    if ($null -ne $mcpSummaryObj) {
        foreach ($k in @('add', 'update', 'unchanged', 'blocked')) {
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

    $configError = Get-SafeProperty $configJson 'Error'
    if ($configError) { $configSummary = $null }
    if ($mcpErrorVal) { $mcpSummary = $null }
    $exitCode = [int][bool]($envReport.Failed -or $configError -or $agErrorVal -or $mcpErrorVal)
    $summary = [ordered]@{
        Environment = $envReport.Recorded
        Config      = $configSummary
        Antigravity = $agAction
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
        Config        = $configJson
        Antigravity   = $agJson
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

    Write-Host '[Config Status]' -ForegroundColor Cyan
    if ($configJson -is [array] -and $configJson.Count -gt 0) {
        foreach ($item in $configJson) {
            $itemStatus = Get-SafeProperty $item 'Status'
            $itemPlatform = Get-SafeProperty $item 'Platform'
            $itemItem = Get-SafeProperty $item 'Item'
            $itemDetail = Get-SafeProperty $item 'Detail'
            $color = switch ($itemStatus) {
                'in-sync' { 'Green' }
                'differs' { 'Yellow' }
                default   { 'Cyan' }
            }
            Write-Host ("  {0,-12} {1,-9} {2} ({3})" -f $itemPlatform, $itemStatus, $itemItem, $itemDetail) -ForegroundColor $color
        }
        Write-Host ("  Summary: in-sync={0}  differs={1}  repo-only={2}  home-only={3}" -f $configSummary['in-sync'], $configSummary['differs'], $configSummary['repo-only'], $configSummary['home-only'])
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
            $mcpColor = if ($mcpAction -eq 'unchanged') { 'Green' } elseif ($mcpAction -eq 'blocked') { 'Red' } else { 'Yellow' }
            Write-Host ("  [{0,-11}] {1,-16} {2,-9} ({3})" -f $mcpPlatform, $mcpServer, $mcpAction, $mcpReason) -ForegroundColor $mcpColor
        }
        Write-Host ("  Summary: add={0}  update={1}  unchanged={2}  blocked={3}" -f $mcpSummary['add'], $mcpSummary['update'], $mcpSummary['unchanged'], $mcpSummary['blocked'])
    }
    elseif ($null -ne $mcpErrorVal) {
        Write-Host ("  Error querying MCP projections: {0}" -f $mcpErrorVal) -ForegroundColor Red
    }
    else {
        Write-Host '  No managed MCP projections found.'
    }
    exit $exitCode
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-Error 'A command is required.' -ErrorAction Continue
    Write-Usage
    exit 1
}

if ($Command -ieq 'help') {
    $topics = @($RemainingArguments | Where-Object { $null -ne $_ })
    if ($topics.Count -eq 0) { Write-Usage; exit 0 }
    if ($topics.Count -ne 1 -or $topics[0] -notin @('config', 'env', 'profile', 'skills', 'antigravity', 'mcp', 'status', 'dashboard')) {
        Write-Error 'Unsupported help topic. Use help config, help env, help profile, help skills, help antigravity, help mcp, help status, or help dashboard.' -ErrorAction Continue
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

    if ($normalizedCommand -eq 'antigravity') {
        # Parse only this route's exact public contract. PowerShell accepts parameter
        # abbreviations downstream, so unknown tokens must never reach the child.
        $pluginArguments = @('-Action', $groupAction)
        $seenParameters = @{}
        $externalPlugins = @()
        $pluginMode = $null
        for ($i = 0; $i -lt $forwardedArguments.Count; $i++) {
            $argument = [string] $forwardedArguments[$i]
            if ($argument -in @('-RepoRoot', '-JsonPath')) {
                if ($seenParameters.ContainsKey($argument)) {
                    Write-Error 'Duplicate Antigravity path parameter.' -ErrorAction Continue
                    exit 1
                }
                if ($i + 1 -ge $forwardedArguments.Count -or
                    [string]::IsNullOrWhiteSpace([string] $forwardedArguments[$i + 1]) -or
                    $forwardedArguments[$i + 1] -in @('-RepoRoot', '-JsonPath', '-ExternalPlugin')) {
                    Write-Error 'Antigravity path parameters require a value.' -ErrorAction Continue
                    exit 1
                }
                $seenParameters[$argument] = $true
                # A single colon-bound token preserves literal values such as -Apply;
                # forwarding them as separate tokens would change child binding.
                $pluginArguments += $argument + ':' + [string] $forwardedArguments[++$i]
                continue
            }
            if ($argument -eq '-ExternalPlugin') {
                if ($groupAction -ne 'deploy') {
                    Write-Error "The antigravity $groupAction command accepts no -ExternalPlugin parameter." -ErrorAction Continue
                    exit 1
                }
                if ($i + 1 -ge $forwardedArguments.Count -or
                    [string]::IsNullOrWhiteSpace([string] $forwardedArguments[$i + 1]) -or
                    $forwardedArguments[$i + 1] -in @('-RepoRoot', '-JsonPath', '-ExternalPlugin', '-DryRun', '-Apply')) {
                    Write-Error 'Antigravity -ExternalPlugin requires a value.' -ErrorAction Continue
                    exit 1
                }
                $extValue = [string] $forwardedArguments[++$i]
                if ($extValue -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
                    Write-Error 'Antigravity -ExternalPlugin value must be a single lowercase plugin name.' -ErrorAction Continue
                    exit 1
                }
                $externalPlugins += $extValue
                continue
            }
            if ($argument -notin @('-DryRun', '-Apply')) {
                Write-Error 'Unsupported antigravity argument. Use exact -RepoRoot, -JsonPath, -ExternalPlugin, -DryRun or -Apply names.' -ErrorAction Continue
                exit 1
            }
            if ($groupAction -ne 'deploy') {
                Write-Error "The antigravity $groupAction command accepts no -DryRun or -Apply mode." -ErrorAction Continue
                exit 1
            }
            if ($null -ne $pluginMode) {
                Write-Error 'The antigravity deploy command accepts only one mode: -DryRun or -Apply.' -ErrorAction Continue
                exit 1
            }
            $pluginMode = $argument
            if ($argument -eq '-Apply') { $pluginArguments += '-Apply' }
        }
        if ($groupAction -eq 'deploy' -and $null -eq $pluginMode) {
            Write-Error 'The antigravity deploy command requires an explicit -DryRun or -Apply mode. Run -DryRun first.' -ErrorAction Continue
            exit 1
        }
        if ($externalPlugins.Count -gt 0) { $pluginArguments += '-ExternalPlugin:' + ($externalPlugins -join ',') }
        $forwardedArguments = $pluginArguments
    }

    if ($normalizedCommand -eq 'mcp') {
        $mcpArguments = @('-Action', $groupAction)
        $seenParameters = @{}
        $mcpPlatforms = @()
        $mcpServers = @()
        $mcpMode = $null
        $mcpValueParams = @('-RepoRoot', '-HomeRoot', '-BackupRoot', '-JsonPath')
        $mcpNamedValueFlags = @('-RepoRoot', '-HomeRoot', '-BackupRoot', '-JsonPath', '-Platform', '-Server')
        for ($i = 0; $i -lt $forwardedArguments.Count; $i++) {
            $argument = [string] $forwardedArguments[$i]
            if ($argument -in $mcpValueParams) {
                if ($argument -eq '-BackupRoot' -and $groupAction -ne 'deploy') {
                    Write-Error "The mcp $groupAction command accepts no -BackupRoot parameter." -ErrorAction Continue
                    exit 1
                }
                if ($seenParameters.ContainsKey($argument)) {
                    Write-Error "Duplicate MCP path parameter: $argument." -ErrorAction Continue
                    exit 1
                }
                if ($i + 1 -ge $forwardedArguments.Count -or
                    [string]::IsNullOrWhiteSpace([string] $forwardedArguments[$i + 1]) -or
                    $forwardedArguments[$i + 1] -in $mcpNamedValueFlags) {
                    Write-Error "MCP parameter $argument requires a value." -ErrorAction Continue
                    exit 1
                }
                $seenParameters[$argument] = $true
                $mcpArguments += $argument + ':' + [string] $forwardedArguments[++$i]
                continue
            }
            if ($argument -eq '-Platform') {
                if ($i + 1 -ge $forwardedArguments.Count -or
                    [string]::IsNullOrWhiteSpace([string] $forwardedArguments[$i + 1]) -or
                    $forwardedArguments[$i + 1] -in ($mcpNamedValueFlags + @('-DryRun', '-Apply', '-Json', '-SkipSecretScan'))) {
                    Write-Error 'MCP -Platform requires a value.' -ErrorAction Continue
                    exit 1
                }
                $platRaw = [string] $forwardedArguments[++$i]
                $platTokens = @($platRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($platTokens.Count -eq 0) {
                    Write-Error 'MCP -Platform requires at least one platform name.' -ErrorAction Continue
                    exit 1
                }
                foreach ($token in $platTokens) {
                    if ($token -notin @('Antigravity', 'Codex')) {
                        Write-Error "Unsupported MCP platform '$token'. Expected Antigravity or Codex." -ErrorAction Continue
                        exit 1
                    }
                    if ($token -notin $mcpPlatforms) { $mcpPlatforms += $token }
                }
                continue
            }
            if ($argument -eq '-Server') {
                if ($i + 1 -ge $forwardedArguments.Count -or
                    [string]::IsNullOrWhiteSpace([string] $forwardedArguments[$i + 1]) -or
                    $forwardedArguments[$i + 1] -in ($mcpNamedValueFlags + @('-DryRun', '-Apply', '-Json', '-SkipSecretScan'))) {
                    Write-Error 'MCP -Server requires a value.' -ErrorAction Continue
                    exit 1
                }
                $srvRaw = [string] $forwardedArguments[++$i]
                $srvTokens = @($srvRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($srvTokens.Count -eq 0) {
                    Write-Error 'MCP -Server requires at least one server name.' -ErrorAction Continue
                    exit 1
                }
                foreach ($token in $srvTokens) {
                    if ($token -cnotmatch '^[a-z0-9][a-z0-9_-]*$') {
                        Write-Error 'MCP -Server value must be a valid lowercase server name.' -ErrorAction Continue
                        exit 1
                    }
                    if ($token -cnotin $mcpServers) { $mcpServers += $token }
                }
                continue
            }
            if ($argument -eq '-Json') {
                if ($seenParameters.ContainsKey('-Json')) {
                    Write-Error 'Duplicate MCP -Json switch.' -ErrorAction Continue
                    exit 1
                }
                $seenParameters['-Json'] = $true
                $mcpArguments += '-Json'
                continue
            }
            if ($argument -eq '-SkipSecretScan') {
                if ($groupAction -ne 'deploy') {
                    Write-Error "The mcp $groupAction command accepts no -SkipSecretScan parameter." -ErrorAction Continue
                    exit 1
                }
                if ($seenParameters.ContainsKey('-SkipSecretScan')) {
                    Write-Error 'Duplicate MCP -SkipSecretScan switch.' -ErrorAction Continue
                    exit 1
                }
                $seenParameters['-SkipSecretScan'] = $true
                $mcpArguments += '-SkipSecretScan'
                continue
            }
            if ($argument -notin @('-DryRun', '-Apply')) {
                Write-Error 'Unsupported mcp argument. Use exact -RepoRoot, -HomeRoot, -BackupRoot, -JsonPath, -Platform, -Server, -Json, -SkipSecretScan, -DryRun or -Apply names.' -ErrorAction Continue
                exit 1
            }
            if ($groupAction -ne 'deploy') {
                Write-Error "The mcp $groupAction command accepts no -DryRun or -Apply mode." -ErrorAction Continue
                exit 1
            }
            if ($null -ne $mcpMode) {
                Write-Error 'The mcp deploy command accepts only one mode: -DryRun or -Apply.' -ErrorAction Continue
                exit 1
            }
            $mcpMode = $argument
            if ($argument -eq '-Apply') { $mcpArguments += '-Apply' }
        }
        if ($groupAction -eq 'deploy' -and $null -eq $mcpMode) {
            Write-Error 'The mcp deploy command requires an explicit -DryRun or -Apply mode. Run -DryRun first.' -ErrorAction Continue
            exit 1
        }
        if ($mcpPlatforms.Count -gt 0) { $mcpArguments += '-Platform:' + ($mcpPlatforms -join ',') }
        if ($mcpServers.Count -gt 0) { $mcpArguments += '-Server:' + ($mcpServers -join ',') }
        $forwardedArguments = $mcpArguments
    }

    if ($normalizedCommand -eq 'config') {
        $consolidatedArgs = [System.Collections.Generic.List[object]]::new()
        $platformValues = [System.Collections.Generic.List[string]]::new()
        $sawPlatform = $false
        for ($i = 0; $i -lt $forwardedArguments.Count; $i++) {
            $arg = [string] $forwardedArguments[$i]
            if ($arg -ieq '-Platform') {
                $sawPlatform = $true
                if ($i + 1 -ge $forwardedArguments.Count -or ([string]$forwardedArguments[$i + 1]).StartsWith('-')) {
                    Write-Error 'Config -Platform requires at least one platform name. Expected Codex or Antigravity.' -ErrorAction Continue
                    exit 1
                }
                $val = [string]$forwardedArguments[++$i]
                if ([string]::IsNullOrWhiteSpace($val)) {
                    Write-Error 'Config -Platform requires at least one platform name. Expected Codex or Antigravity.' -ErrorAction Continue
                    exit 1
                }
                $platformValues.Add($val)
                continue
            }
            if ($arg -ilike '-Platform:*') {
                $sawPlatform = $true
                $val = $arg.Substring(10)
                if ([string]::IsNullOrWhiteSpace($val)) {
                    Write-Error 'Config -Platform requires at least one platform name. Expected Codex or Antigravity.' -ErrorAction Continue
                    exit 1
                }
                $platformValues.Add($val)
                continue
            }
            $consolidatedArgs.Add($forwardedArguments[$i])
        }
        if ($sawPlatform) {
            $tokens = @($platformValues | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($tokens.Count -eq 0) {
                Write-Error 'Config -Platform requires at least one platform name. Expected Codex or Antigravity.' -ErrorAction Continue
                exit 1
            }
            $consolidatedArgs.Add('-Platform:' + ($platformValues -join ','))
        }
        $forwardedArguments = @($consolidatedArgs)
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
