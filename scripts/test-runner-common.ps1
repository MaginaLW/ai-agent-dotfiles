#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')

function Get-Utf8Sha256 {
    param([Parameter(Mandatory)] [string] $Text)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Write-CreateNewUtf8File {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)

    $full = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-TestRunnerConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing timeout configuration: $Path" }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    foreach ($field in @('DefaultTimeoutSeconds', 'SetupAndNonSuiteBudgetSeconds', 'MarginSeconds', 'Suites')) {
        if (-not $data.ContainsKey($field)) { throw "Timeout configuration is missing $field."
        }
    }
    foreach ($field in @('DefaultTimeoutSeconds', 'SetupAndNonSuiteBudgetSeconds', 'MarginSeconds')) {
        if ([int]$data[$field] -le 0) { throw "Timeout configuration $field must be positive." }
    }
    return $data
}

function Get-RootTestSuitePaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TestsRoot)

    $root = (Resolve-Path -LiteralPath $TestsRoot).Path
    return @(Get-ChildItem -LiteralPath $root -File -Filter '*.tests.ps1' |
        Sort-Object { $_.Name.ToLowerInvariant() } |
        ForEach-Object { $_.FullName })
}

function Get-TestSuiteId {
    param([Parameter(Mandatory)] [string] $SuitePath, [Parameter(Mandatory)] [string] $SuiteRoot)

    $relative = [System.IO.Path]::GetRelativePath([System.IO.Path]::GetFullPath($SuiteRoot), [System.IO.Path]::GetFullPath($SuitePath))
    if ($relative -eq '..' -or $relative.StartsWith('../') -or $relative.StartsWith('..\')) {
        throw "Suite path is outside SuiteRoot: $SuitePath"
    }
    return $relative.Replace([char]92, [char]47).ToLowerInvariant()
}

function Get-SuiteTimeoutSeconds {
    param([Parameter(Mandatory)] [hashtable] $Configuration, [Parameter(Mandatory)] [string] $SuiteId)

    if ($Configuration.Suites.ContainsKey($SuiteId)) {
        $timeout = [int] $Configuration.Suites[$SuiteId]
    }
    else {
        $timeout = [int] $Configuration.DefaultTimeoutSeconds
    }
    if ($timeout -le 0) { throw "Timeout for $SuiteId must be positive." }
    return $timeout
}

function Invoke-OneTestSuite {
    param(
        [Parameter(Mandatory)] [string] $SuitePath,
        [Parameter(Mandatory)] [string] $SuiteId,
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [hashtable] $Environment = @{}
    )

    $pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
    if ($TimeoutSeconds -gt [Math]::Floor([int]::MaxValue / 1000)) {
        throw "Timeout for $SuiteId exceeds the native runner limit."
    }
    $arguments = [string[]] @('-NoProfile', '-File', $SuitePath)
    $environmentEntries = [System.Collections.Generic.List[object]]::new()
    $environmentNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in @($Environment.Keys | Sort-Object)) {
        $name = [string] $key
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('=') -or $name.Contains([char] 0)) {
            throw "Invalid suite environment variable name: $name"
        }
        if (-not $environmentNames.Add($name)) {
            throw "Duplicate suite environment variable name: $name"
        }
        $environmentEntries.Add([pscustomobject]@{ Name = $name; Value = [string] $Environment[$key] })
    }

    $savedEnvironment = [ordered]@{}
    $nativeResult = $null
    $timedOut = $false
    $processFailed = $false
    $failureMarker = ''
    try {
        foreach ($entry in $environmentEntries) {
            $name = [string] $entry.Name
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable($name, [string] $entry.Value, [EnvironmentVariableTarget]::Process)
        }
        $startedAt = [DateTime]::UtcNow
        try {
            $nativeResult = [AiAgentDotfiles.PinnedToolProcessRunner]::Run(
                $pwsh,
                $arguments,
                $null,
                $false,
                $TimeoutSeconds * 1000,
                5000,
                67108864
            )
        }
        catch [System.TimeoutException] {
            $timedOut = $true
            $failureMarker = 'test-runner-suite-timeout' # scan-ok
        }
        catch [System.InvalidOperationException] {
            # The sealed native runner returns from this controlled failure path
            # only after terminating its Job and proving ActiveProcesses == 0
            # plus settled pipes. Keep the mapping independent of exception text.
            $processFailed = $true
            $failureMarker = 'test-runner-suite-process-failed' # scan-ok
        }
    }
    finally {
        foreach ($name in @($savedEnvironment.Keys)) {
            [Environment]::SetEnvironmentVariable(
                [string] $name,
                $savedEnvironment[$name],
                [EnvironmentVariableTarget]::Process
            )
        }
    }
    $endedAt = [DateTime]::UtcNow
    $runnerFailed = $timedOut -or $processFailed
    $exitCode = if ($runnerFailed) { -1 } else { [int] $nativeResult.ExitCode }
    $stdout = if ($runnerFailed) { '' } else { [string] $nativeResult.Stdout }
    $stderr = if ($runnerFailed) { $failureMarker } else { [string] $nativeResult.Stderr }

    return [ordered]@{
        SuiteId = $SuiteId
        Path = [System.IO.Path]::GetFullPath($SuitePath)
        State = if ($timedOut) { 'timed-out' } elseif ($processFailed -or $exitCode -ne 0) { 'failed' } else { 'passed' }
        Started = $true
        Completed = -not $timedOut
        TimedOut = $timedOut
        TreeKilled = $timedOut -or $processFailed
        TreeKillFailed = $false
        ExitCode = $exitCode
        TimeoutSeconds = $TimeoutSeconds
        DurationMilliseconds = [long] [Math]::Ceiling(($endedAt - $startedAt).TotalMilliseconds)
        Stdout = $stdout.TrimEnd("`r", "`n")
        Stderr = $stderr.TrimEnd("`r", "`n")
    }
}

function Invoke-TestSuiteCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $SuitePaths,
        [Parameter(Mandatory)] [string] $SuiteRoot,
        [Parameter(Mandatory)] [string] $TimeoutConfigPath,
        [Parameter(Mandatory)] [string] $JsonSummaryPath,
        [hashtable] $Environment = @{}
    )

    $configuration = Get-TestRunnerConfiguration -Path $TimeoutConfigPath
    $descriptors = @($SuitePaths | ForEach-Object {
        [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($_); SuiteId = Get-TestSuiteId -SuitePath $_ -SuiteRoot $SuiteRoot }
    } | Sort-Object SuiteId, Path)
    $duplicateCount = 0
    foreach ($group in @($descriptors | Group-Object SuiteId)) {
        if ($group.Count -gt 1) { $duplicateCount += ($group.Count - 1) }
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $started = 0
    $completed = 0
    $passed = 0
    $failed = 0
    $timedOut = 0
    $missing = 0
    $treeKillFailed = 0
    $timeoutBudget = 0

    if ($duplicateCount -eq 0) {
        foreach ($descriptor in $descriptors) {
            $timeout = Get-SuiteTimeoutSeconds -Configuration $configuration -SuiteId $descriptor.SuiteId
            $timeoutBudget += $timeout
            if (-not (Test-Path -LiteralPath $descriptor.Path -PathType Leaf)) {
                $missing++
                $records.Add([ordered]@{
                    SuiteId = $descriptor.SuiteId; Path = $descriptor.Path; State = 'missing'; Started = $false; Completed = $false
                    TimedOut = $false; TreeKilled = $false; TreeKillFailed = $false; ExitCode = -1; TimeoutSeconds = $timeout
                    DurationMilliseconds = 0; Stdout = ''; Stderr = 'Suite file is missing.'
                })
                continue
            }
            Write-Host "=== $($descriptor.SuiteId) ==="
            $record = Invoke-OneTestSuite -SuitePath $descriptor.Path -SuiteId $descriptor.SuiteId -TimeoutSeconds $timeout -Environment $Environment
            $records.Add($record)
            $started++
            if ($record.Completed) { $completed++ }
            if ($record.State -eq 'passed') { $passed++ }
            elseif ($record.State -eq 'failed') { $failed++ }
            elseif ($record.State -eq 'timed-out') { $timedOut++ }
            if ($record.TreeKillFailed) { $treeKillFailed++ }
            if ($record.Stdout) { Write-Host $record.Stdout }
            if ($record.Stderr) { Write-Host $record.Stderr }
        }
    }

    $suiteIds = @($descriptors | ForEach-Object SuiteId)
    $discoveryHash = Get-Utf8Sha256 -Text (($suiteIds -join "`n") + "`n")
    $required = [int]$configuration.SetupAndNonSuiteBudgetSeconds + $timeoutBudget + [int]$configuration.MarginSeconds
    $result = if ($duplicateCount -eq 0 -and $missing -eq 0 -and $failed -eq 0 -and $timedOut -eq 0 -and $treeKillFailed -eq 0 -and $descriptors.Count -eq $started -and $started -eq $completed -and $completed -eq $passed) { 'PASS' } else { 'FAIL' }
    $summary = [ordered]@{
        SchemaVersion = 1
        ReportKind = 'test-run'
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        DiscoveryHash = $discoveryHash
        SetupAndNonSuiteBudgetSeconds = [int] $configuration.SetupAndNonSuiteBudgetSeconds
        MarginSeconds = [int] $configuration.MarginSeconds
        RequiredJobTimeoutSeconds = $required
        Suites = @($records)
        Counts = [ordered]@{
            Discovered = $descriptors.Count; Started = $started; Completed = $completed; Passed = $passed; Failed = $failed
            TimedOut = $timedOut; Duplicate = $duplicateCount; Missing = $missing; TreeKillFailed = $treeKillFailed
        }
        Result = $result
    }
    $json = (ConvertTo-Json -InputObject $summary -Depth 20) + "`n"
    Write-CreateNewUtf8File -Path $JsonSummaryPath -Content $json
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/test-run-summary.schema.json') -InstancePath $JsonSummaryPath
    Test-TestRunSummaryForRunner -Summary $summary
    return [pscustomobject] $summary
}

function Test-TestRunSummaryForRunner {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Summary)

    $counts = $Summary.Counts
    if ([long] $counts.Started -ne ([long] $counts.Passed + [long] $counts.Failed + [long] $counts.TimedOut)) { throw 'test-run-summary Started count is inconsistent.' }
    if ([long] $counts.Completed -ne ([long] $counts.Passed + [long] $counts.Failed)) { throw 'test-run-summary Completed count is inconsistent.' }
    if ([string] $Summary.Result -eq 'PASS') {
        foreach ($name in @('Failed', 'TimedOut', 'Duplicate', 'Missing', 'TreeKillFailed')) {
            if ([long] $counts[$name] -ne 0) { throw "PASS test-run-summary has nonzero $name." }
        }
        if ([long] $counts.Discovered -ne [long] $counts.Started -or [long] $counts.Started -ne [long] $counts.Completed -or [long] $counts.Completed -ne [long] $counts.Passed) {
            throw 'PASS test-run-summary does not prove exact once completion.'
        }
    }
}
