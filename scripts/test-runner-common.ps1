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

function Get-TestShardPartition {
    # Validates the tracked static shard partition (tests/test-shards.psd1) against the
    # discovered suite id set and returns it as an ordered map of shard number (string)
    # -> sorted suite id array. Fails closed on any drift: a key outside 1..ShardCount,
    # a missing or empty shard, a suite listed twice, a suite the discovery never
    # produced, or a discovered suite no shard covers. Only the -ShardCount/-ShardIndex
    # path of scripts/run-tests.ps1 loads the file; the local -All path never does.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $ShardCount,
        [Parameter(Mandatory)] [string] $ShardConfigPath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $DiscoveredSuiteIds
    )

    if ($ShardCount -lt 1) { throw 'test-shard-partition-invalid-count: ShardCount must be at least 1.' }
    if (-not (Test-Path -LiteralPath $ShardConfigPath -PathType Leaf)) { throw "test-shard-partition-missing-config: $ShardConfigPath" }
    $data = Import-PowerShellDataFile -LiteralPath $ShardConfigPath
    $shardEntries = @{}
    foreach ($key in @($data.Keys)) {
        $shardNumber = 0
        if (-not [int]::TryParse([string] $key, [ref] $shardNumber)) {
            throw "test-shard-partition-invalid-key: shard configuration key '$key' is not a shard number."
        }
        if ($shardNumber -lt 1 -or $shardNumber -gt $ShardCount) {
            throw "test-shard-partition-key-out-of-range: shard configuration key '$key' is outside 1..$ShardCount."
        }
        if ($shardEntries.ContainsKey($shardNumber)) {
            throw "test-shard-partition-duplicate-key: shard $shardNumber is defined more than once."
        }
        $shardEntries[$shardNumber] = @($data[$key])
    }
    $coveredIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $partition = [ordered]@{}
    for ($number = 1; $number -le $ShardCount; $number++) {
        if (-not $shardEntries.ContainsKey($number)) {
            throw "test-shard-partition-missing-shard: shard configuration is missing shard $number."
        }
        $shardIds = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $shardEntries[$number]) {
            if ([string]::IsNullOrWhiteSpace([string] $entry)) {
                throw "test-shard-partition-invalid-entry: shard $number carries a blank suite id."
            }
            $suiteId = ([string] $entry).Replace([char]92, [char]47).ToLowerInvariant()
            if (-not $coveredIds.Add($suiteId)) {
                throw "test-shard-partition-duplicate-suite: '$suiteId' is assigned to more than one shard."
            }
            $shardIds.Add($suiteId)
        }
        if ($shardIds.Count -eq 0) {
            throw "test-shard-partition-empty-shard: shard $number lists no suites."
        }
        $partition[[string] $number] = @($shardIds | Sort-Object)
    }
    $discoveredSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($suiteId in $DiscoveredSuiteIds) { $null = $discoveredSet.Add([string] $suiteId) }
    if ($discoveredSet.Count -ne @($DiscoveredSuiteIds).Count) {
        throw 'test-shard-partition-duplicate-discovery: discovery returned the same suite id twice.'
    }
    foreach ($suiteId in @($coveredIds)) {
        if (-not $discoveredSet.Contains($suiteId)) {
            throw "test-shard-partition-unknown-suite: '$suiteId' is not a discovered suite."
        }
    }
    foreach ($suiteId in @($discoveredSet)) {
        if (-not $coveredIds.Contains($suiteId)) {
            throw "test-shard-partition-uncovered-suite: '$suiteId' is not assigned to any shard."
        }
    }
    return $partition
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
        [hashtable] $Environment = @{},
        [int] $ShardCount = 0,
        [int] $ShardIndex = 0
    )

    $shardRequested = ($ShardCount -ne 0) -or ($ShardIndex -ne 0)
    if ($shardRequested -and ($ShardCount -le 0 -or $ShardIndex -le 0 -or $ShardIndex -gt $ShardCount)) {
        throw 'test-run-summary-invalid-shard-fields: ShardCount and ShardIndex must both be positive with 1 <= ShardIndex <= ShardCount.'
    }

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
    if ($shardRequested) {
        # Insert the shard binding next to the job-contract fields so sharded summaries
        # are self-describing; the unsharded summary bytes stay exactly as before.
        $summary.Insert(7, 'ShardCount', $ShardCount)
        $summary.Insert(8, 'ShardIndex', $ShardIndex)
    }
    $json = (ConvertTo-Json -InputObject $summary -Depth 20) + "`n"
    Write-CreateNewUtf8File -Path $JsonSummaryPath -Content $json
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/test-run-summary.schema.json') -InstancePath $JsonSummaryPath
    Test-TestRunSummaryForRunner -Summary $summary
    return [pscustomobject] $summary
}

function Test-TestRunSummaryForRunner {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Summary)

    $summaryKeys = @($Summary.Keys)
    if ($summaryKeys -ccontains 'ShardCount' -or $summaryKeys -ccontains 'ShardIndex') {
        if ($summaryKeys -cnotcontains 'ShardCount' -or $summaryKeys -cnotcontains 'ShardIndex') {
            throw 'test-run-summary ShardCount and ShardIndex must be recorded together.'
        }
        if ([int] $Summary['ShardCount'] -lt 1 -or [int] $Summary['ShardIndex'] -lt 1 -or [int] $Summary['ShardIndex'] -gt [int] $Summary['ShardCount']) {
            throw 'test-run-summary shard fields must satisfy 1 <= ShardIndex <= ShardCount.'
        }
    }
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
