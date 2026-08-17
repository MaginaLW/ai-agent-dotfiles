#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

function Assert-Throws {
    param([Parameter(Mandatory)] [scriptblock] $Action, [Parameter(Mandatory)] [string] $Pattern, [Parameter(Mandatory)] [string] $Message)
    $threw = $false
    try { & $Action }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw "FAIL: $Message (unexpected: $($_.Exception.Message))" }
    }
    if (-not $threw) { throw "FAIL: $Message (did not throw)" }
    Write-Host "  PASS  $Message"
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-schema-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Write-Host '[schema preflight]'
    $valid = Join-Path $RepoRoot 'schemas/scan-input-manifest.schema.json'
    $result = Test-RepositoryJsonSchema -SchemaPath $valid -SchemaRoot (Join-Path $RepoRoot 'schemas')
    Assert ($result.SchemaId -eq 'https://ai-agent-dotfiles.invalid/schemas/scan-input-manifest.schema.json') 'valid repository schema passes no-fetch preflight'

    $badCases = @(
        @{ Name='wrong-dialect'; Json='{"$schema":"http://json-schema.org/draft-07/schema#","$id":"https://ai-agent-dotfiles.invalid/schemas/wrong-dialect.json","type":"object"}'; Pattern='2020-12|dialect' },
        @{ Name='wrong-id'; Json='{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://example.com/wrong-id.json","type":"object"}'; Pattern='\$id|identifier' },
        @{ Name='cross-ref'; Json='{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://ai-agent-dotfiles.invalid/schemas/cross-ref.json","$ref":"other.json"}'; Pattern='\$ref|same-document' },
        @{ Name='file-ref'; Json='{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://ai-agent-dotfiles.invalid/schemas/file-ref.json","$ref":"file:///C:/outside.json"}'; Pattern='\$ref|same-document' },
        @{ Name='dynamic'; Json='{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://ai-agent-dotfiles.invalid/schemas/dynamic.json","$dynamicRef":"#x"}'; Pattern='dynamic' }
    )
    foreach ($case in $badCases) {
        $path = Join-Path $work ($case.Name + '.json')
        [System.IO.File]::WriteAllText($path, $case.Json, [System.Text.UTF8Encoding]::new($false))
        Assert-Throws { Test-RepositoryJsonSchema -SchemaPath $path -SchemaRoot $work } $case.Pattern "$($case.Name) schema is rejected before validator launch"
    }

    Write-Host '[validator compatibility]'
    $compatibilitySchema = Join-Path $work 'compatibility.schema.json'
    $compatibilityValid = Join-Path $work 'compatibility.valid.json'
    $compatibilityExtra = Join-Path $work 'compatibility.extra.invalid.json'
    $compatibilityDuplicate = Join-Path $work 'compatibility.duplicate.invalid.json'
    [System.IO.File]::WriteAllText($compatibilitySchema, @'
{
  "$schema":"https://json-schema.org/draft/2020-12/schema",
  "$id":"https://ai-agent-dotfiles.invalid/schemas/compatibility.schema.json",
  "type":"object",
  "required":["kind","stamp","items"],
  "properties":{
    "kind":{"const":"demo"},
    "stamp":{"type":"string","format":"date-time"},
    "items":{"type":"array","uniqueItems":true,"items":{"$ref":"#/$defs/item"}}
  },
  "$defs":{"item":{"type":"string","minLength":1}},
  "unevaluatedProperties":false
}
'@, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($compatibilityValid, '{"kind":"demo","stamp":"2026-08-11T00:00:00Z","items":["a","b"]}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($compatibilityExtra, '{"kind":"demo","stamp":"2026-08-11T00:00:00Z","items":["a"],"extra":true}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($compatibilityDuplicate, '{"kind":"demo","stamp":"2026-08-11T00:00:00Z","items":["a","a"]}', [System.Text.UTF8Encoding]::new($false))
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $compatibilitySchema -InstancePath $compatibilityValid
    Assert-Throws { Invoke-FixedJsonSchemaValidation -SchemaPath $compatibilitySchema -InstancePath $compatibilityExtra } 'validation failed' 'unevaluatedProperties is enforced'
    Assert-Throws { Invoke-FixedJsonSchemaValidation -SchemaPath $compatibilitySchema -InstancePath $compatibilityDuplicate } 'validation failed' 'duplicate-sensitive uniqueItems is enforced'
    $validatorLease = $null
    try {
        $validatorLease = Open-PinnedToolLease -LockPath (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json')
        $metaschemaResult = Invoke-PinnedToolProcess `
            -ToolLease $validatorLease `
            -Arguments @('metaschema', $compatibilitySchema) `
            -Operation 'Draft 2020-12 metaschema sentinel'
        Assert (
            $metaschemaResult.ExitCode -eq 0 -and
            [string]$metaschemaResult.Stdout -ceq '' -and
            [string]$metaschemaResult.Stderr -ceq '' -and
            [string]$metaschemaResult.Output -ceq ''
        ) 'Draft 2020-12 metaschema sentinel passes with exact empty output'
    }
    finally { Close-PinnedToolLease -ToolLease $validatorLease }

    Write-Host '[pinned tool attestation cache boundary]'
    $validatorLockPath = Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json'
    $validatorLockForCache = Get-PinnedToolLock -Path $validatorLockPath
    $validatorPathsForCache = Get-PinnedToolPaths -Lock $validatorLockForCache
    $forgedExecutable = Join-Path $work 'forged-validator.cmd'
    $forgedMarker = Join-Path $work 'forged-validator-ran.txt'
    [System.IO.File]::WriteAllText(
        $forgedExecutable,
        "@echo off`r`necho forged>`"$forgedMarker`"`r`nexit /b 0`r`n",
        [System.Text.ASCIIEncoding]::new()
    )
    $forgedCacheKey = "$( $validatorPathsForCache.Root)|$((Get-Item -LiteralPath $validatorPathsForCache.Archive).LastWriteTimeUtc.Ticks)|$((Get-Item -LiteralPath $validatorPathsForCache.Executable).LastWriteTimeUtc.Ticks)"
    $exposedToolCache = Get-Variable -Name PinnedToolValidationCache -Scope Script -ErrorAction SilentlyContinue
    if ($exposedToolCache) {
        $exposedToolCache.Value[$forgedCacheKey] = [pscustomobject]@{
            Lock = $validatorLockForCache
            Paths = [pscustomobject]@{ Root=$validatorPathsForCache.Root;Archive=$validatorPathsForCache.Archive;Executable=$forgedExecutable }
            ExecutableSha256 = ('0' * 64)
            VersionOutput = 'forged'
        }
    }
    $forgedCacheAccepted = $false
    try {
        Invoke-FixedJsonSchemaValidation -SchemaPath $compatibilitySchema -InstancePath $compatibilityExtra | Out-Null
        $forgedCacheAccepted = $true
    }
    catch {}
    finally { if ($exposedToolCache) { $null = $exposedToolCache.Value.Remove($forgedCacheKey) } }
    Assert ($null -eq $exposedToolCache -and -not $forgedCacheAccepted -and -not (Test-Path -LiteralPath $forgedMarker)) 'caller-forged pinned-tool cache entries cannot bypass schema validation'

    Write-Host '[tool locks and registry]'
    $validatorLock = Get-PinnedToolLock -Path (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json')
    $gitleaksLock = Get-PinnedToolLock -Path (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json')
    Assert ($validatorLock.Version -eq '15.6.3' -and $validatorLock.AssetSha256 -match '^[0-9a-f]{64}$' -and $validatorLock.ExecutableSha256 -match '^[0-9a-f]{64}$') 'schema-validator lock pins version, publisher asset hash, and extracted executable hash'
    Assert ($gitleaksLock.Version -eq '8.30.0' -and $gitleaksLock.AssetSha256 -match '^[0-9a-f]{64}$' -and $gitleaksLock.ExecutableSha256 -match '^[0-9a-f]{64}$') 'gitleaks lock avoids the known-bad 8.30.1 and pins publisher asset and executable hashes'

    $missingCache = Join-Path $work 'missing-cache'
    Assert-Throws { Assert-PinnedToolInstalled -LockPath (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json') -CacheRoot $missingCache } 'not installed' 'missing pinned validator fails closed without installation'
    Assert (-not (Test-Path -LiteralPath $missingCache)) 'VerifyOnly-style validation does not create a missing cache'

    $tamperCache = Join-Path $work 'tamper-cache'
    $sourcePaths = Get-PinnedToolPaths -Lock $validatorLock
    $targetPaths = Get-PinnedToolPaths -Lock $validatorLock -CacheRoot $tamperCache
    New-Item -ItemType Directory -Path (Split-Path -Parent $targetPaths.Root) -Force | Out-Null
    Copy-Item -LiteralPath $sourcePaths.Root -Destination $targetPaths.Root -Recurse
    $tamperStream = [System.IO.File]::Open($targetPaths.Executable, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $tamperStream.WriteByte(0); $tamperStream.Flush($true) } finally { $tamperStream.Dispose() }
    Assert-Throws { Assert-PinnedToolInstalled -LockPath (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json') -CacheRoot $tamperCache } 'differs|mismatch' 'tampered pinned executable fails closed'

    $sameTimeCache = Join-Path $work 'same-time-cache'
    $sameTimePaths = Get-PinnedToolPaths -Lock $validatorLock -CacheRoot $sameTimeCache
    New-Item -ItemType Directory -Path (Split-Path -Parent $sameTimePaths.Root) -Force | Out-Null
    Copy-Item -LiteralPath $sourcePaths.Root -Destination $sameTimePaths.Root -Recurse
    $sameTimeStamp = (Get-Item -LiteralPath $sameTimePaths.Executable).LastWriteTimeUtc
    $sameTimeBytes = [System.IO.File]::ReadAllBytes($sameTimePaths.Executable)
    $sameTimeBytes[0] = $sameTimeBytes[0] -bxor 1
    [System.IO.File]::WriteAllBytes($sameTimePaths.Executable, $sameTimeBytes)
    [System.IO.File]::SetLastWriteTimeUtc($sameTimePaths.Executable, $sameTimeStamp)
    Assert-Throws { Assert-PinnedToolInstalled -LockPath (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json') -CacheRoot $sameTimeCache } 'hash mismatch' 'same-length same-mtime pinned executable tampering fails closed'

    $lease = Open-PinnedToolLease -LockPath (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json')
    $leaseMoveBlocked = $false
    $leaseMovedPath = [string]$lease.Paths.Executable + '.moved'
    try {
        try { [System.IO.File]::Move([string]$lease.Paths.Executable, $leaseMovedPath) }
        catch [System.IO.IOException] { $leaseMoveBlocked = $true }
        Assert ($leaseMoveBlocked -and -not (Test-Path -LiteralPath $leaseMovedPath)) 'pinned tool lease blocks executable replacement through process exit'
    }
    finally { Close-PinnedToolLease -ToolLease $lease }
    [System.IO.File]::Move($sourcePaths.Executable, $leaseMovedPath)
    [System.IO.File]::Move($leaseMovedPath, $sourcePaths.Executable)
    Close-PinnedToolLease -ToolLease $lease
    Assert (Test-Path -LiteralPath $sourcePaths.Executable -PathType Leaf) 'pinned tool lease close is idempotent and releases executable replacement sharing'

    Write-Host '[pinned tool inherited-pipe process cleanup]'
    $processStateRoot = Join-Path $work 'pinned-tool-process-state'
    $processOutcomePath = Join-Path $work 'pinned-tool-process-outcome.txt'
    New-Item -ItemType Directory -Path $processStateRoot | Out-Null
    $processProbe = $null
    $processDescendantId = $null
    $processProbeExited = $false
    $processDescendantPublished = $false
    $processDescendantReaped = $false
    $processElapsed = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $processStart = [System.Diagnostics.ProcessStartInfo]::new()
        $processStart.FileName = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
        $processStart.UseShellExecute = $false
        $processStart.CreateNoWindow = $true
        foreach ($argument in @(
            '-NoProfile',
            '-File',
            (Join-Path $PSScriptRoot 'helpers/pinned-tool-process-probe.ps1'),
            '-RepoRoot',
            $RepoRoot,
            '-StateRoot',
            $processStateRoot,
            '-OutcomePath',
            $processOutcomePath
        )) {
            $null = $processStart.ArgumentList.Add([string] $argument)
        }

        $processProbe = [System.Diagnostics.Process]::Start($processStart)
        if ($null -eq $processProbe) { throw 'Unable to start the isolated pinned-tool process probe.' }
        $processProbeExited = $processProbe.WaitForExit(18000)
        $processElapsed.Stop()

        $descendantPidPath = Join-Path $processStateRoot 'descendant.pid'
        $processDescendantPublished = Test-Path -LiteralPath $descendantPidPath -PathType Leaf
        if ($processDescendantPublished) {
            $processDescendantId = [int] (Get-Content -Raw -LiteralPath $descendantPidPath)
            $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(2)
            while ($null -ne (Get-Process -Id $processDescendantId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $cleanupDeadline) {
                Start-Sleep -Milliseconds 25
            }
            $processDescendantReaped = $null -eq (Get-Process -Id $processDescendantId -ErrorAction SilentlyContinue)
        }
    }
    finally {
        if ($processProbe) {
            if (-not $processProbe.HasExited) {
                try { $processProbe.Kill($true) } catch {}
                try { $null = $processProbe.WaitForExit(5000) } catch {}
            }
            $processProbe.Dispose()
        }
        if ($null -ne $processDescendantId) {
            $processSurvivor = Get-Process -Id $processDescendantId -ErrorAction SilentlyContinue
            if ($processSurvivor) {
                try { $processSurvivor.Kill($true) } catch {}
                try { $null = $processSurvivor.WaitForExit(5000) } catch {}
                $processSurvivor.Dispose()
            }
        }
    }
    Assert $processProbeExited 'the isolated production wrapper returns or fail-fasts within the hard bound'
    Assert ($processElapsed.ElapsedMilliseconds -le 18000) 'the inherited-pipe case respects the hard wall-clock bound'
    Assert $processDescendantPublished 'the target parent exits after publishing its inherited-pipe descendant PID'
    Assert $processDescendantReaped 'production process lifecycle cleanup reaps the inherited-pipe descendant before held resources can be released'

    $shadow = Join-Path $work 'shadow'
    New-Item -ItemType Directory -Path $shadow | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $shadow 'gitleaks.cmd'), '@exit /b 0', [System.Text.Encoding]::ASCII)
    $sentinel = Join-Path $work 'gitleaks-sentinel'
    New-Item -ItemType Directory -Path $sentinel | Out-Null
    $prefix = ([string][char]103) + [char]104 + [char]112 + [char]95
    $sentinelValue = $prefix + ('A' * 36)
    [System.IO.File]::WriteAllText((Join-Path $sentinel 'sentinel.txt'), $sentinelValue, [System.Text.UTF8Encoding]::new($false))
    $originalPath = $env:PATH
    $gitleaksLease = $null
    try {
        $env:PATH = "$shadow;$originalPath"
        $gitleaksLease = Open-PinnedToolLease -LockPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json')
        Assert (-not $gitleaksLease.Paths.Executable.StartsWith($shadow, [System.StringComparison]::OrdinalIgnoreCase)) 'malicious PATH shadow is ignored'
        $gitleaksResult = Invoke-PinnedToolProcess `
            -ToolLease $gitleaksLease `
            -Arguments @('detect', '--no-git', '--source', $sentinel, '--config', (Join-Path $RepoRoot '.gitleaks.toml'), '--redact', '--no-banner') `
            -Operation 'Pinned gitleaks sentinel scan'
        $normalizedGitleaksOutput = [regex]::Replace([string]$gitleaksResult.Output, '\x1b\[[0-9;]*m', '')
        $gitleaksOutputLines = @($normalizedGitleaksOutput -split '\r?\n')
        Assert (
            $gitleaksResult.ExitCode -eq 1 -and
            [string]$gitleaksResult.Stdout -ceq '' -and
            ([string]$gitleaksResult.Stderr).Trim() -ceq [string]$gitleaksResult.Output -and
            $gitleaksOutputLines.Count -eq 2 -and
            $gitleaksOutputLines[0] -cmatch '^\S+ INF scanned ~40 bytes \(40 bytes\) in \S+$' -and
            $gitleaksOutputLines[1] -cmatch '^\S+ WRN leaks found: 1$' -and
            [string]$gitleaksResult.Output -notmatch [regex]::Escape($sentinelValue)
        ) 'pinned gitleaks reports exactly one redacted planted sentinel finding with exit code 1'
    }
    finally {
        $env:PATH = $originalPath
        Close-PinnedToolLease -ToolLease $gitleaksLease
    }

    $contracts = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'schemas/artifact-contracts.psd1')
    Assert ($contracts.Contracts.ContainsKey('scan-input-manifest')) 'registry includes scan-input-manifest v1'
    Assert ($contracts.Contracts.ContainsKey('test-run-summary')) 'registry includes test-run-summary v1'
    Assert ($contracts.Contracts.ContainsKey('artifact-validation-manifest')) 'registry bootstraps the artifact manifest'

    Write-Host '[manifest semantic dispatch]'
    $tamperedPlanPath = Join-Path $RepoRoot 'tests/fixtures/artifacts/canonical-transaction-plan.plan-hash.invalid.json'
    $tamperedManifestPath = Join-Path $work 'tampered-plan-manifest.json'
    $tamperedSummaryPath = Join-Path $work 'tampered-plan-summary.json'
    $tamperedManifest = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'artifact-validation-manifest'
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Artifacts = @([ordered]@{
            ArtifactKind = 'canonical-transaction-plan'
            SchemaVersion = 1
            Path = [System.IO.Path]::GetFullPath($tamperedPlanPath)
            Sha256 = (Get-FileHash -LiteralPath $tamperedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    [System.IO.File]::WriteAllText($tamperedManifestPath, (ConvertTo-Json -InputObject $tamperedManifest -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))
    $validatorOutput = & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts/validate-json-artifacts.ps1') -ArtifactManifestPath $tamperedManifestPath -JsonSummaryPath $tamperedSummaryPath 2>&1 | Out-String
    $validatorExitCode = $LASTEXITCODE
    $tamperedSummary = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($tamperedSummaryPath, [System.Text.UTF8Encoding]::new($false, $true)))
    Assert (
        $validatorExitCode -ne 0 -and
        [string]$tamperedSummary.Mode -ceq 'Manifest' -and
        [string]$tamperedSummary.Result -ceq 'FAIL' -and
        [long]$tamperedSummary.Counts.ArtifactsValidated -eq 0 -and
        [long]$tamperedSummary.Counts.Failed -eq 1 -and
        @($tamperedSummary.Failures | Where-Object { [string]$_ -match 'canonical-transaction-plan PlanHash' }).Count -eq 1
    ) 'manifest mode dispatches canonical plan artifacts through the same named semantic hash validator'

    Write-Host 'schema validation tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
