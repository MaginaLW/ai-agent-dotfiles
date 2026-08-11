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
    $pinnedValidator = Assert-PinnedToolInstalled -LockPath (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json')
    & $pinnedValidator.Paths.Executable metaschema $compatibilitySchema 2>$null | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Draft 2020-12 metaschema sentinel passes'

    Write-Host '[tool locks and registry]'
    $validatorLock = Get-PinnedToolLock -Path (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json')
    $gitleaksLock = Get-PinnedToolLock -Path (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json')
    Assert ($validatorLock.Version -eq '15.6.3' -and $validatorLock.AssetSha256 -match '^[0-9a-f]{64}$') 'schema-validator lock pins version and publisher asset hash'
    Assert ($gitleaksLock.Version -eq '8.30.0' -and $gitleaksLock.AssetSha256 -match '^[0-9a-f]{64}$') 'gitleaks lock avoids the known-bad 8.30.1 and pins publisher asset hash'

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

    $shadow = Join-Path $work 'shadow'
    New-Item -ItemType Directory -Path $shadow | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $shadow 'gitleaks.cmd'), '@exit /b 0', [System.Text.Encoding]::ASCII)
    $originalPath = $env:PATH
    try {
        $env:PATH = "$shadow;$originalPath"
        $pinnedGitleaks = Assert-PinnedToolInstalled -LockPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json')
        Assert (-not $pinnedGitleaks.Paths.Executable.StartsWith($shadow, [System.StringComparison]::OrdinalIgnoreCase)) 'malicious PATH shadow is ignored'
    }
    finally { $env:PATH = $originalPath }

    $sentinel = Join-Path $work 'gitleaks-sentinel'
    New-Item -ItemType Directory -Path $sentinel | Out-Null
    $prefix = ([string][char]103) + [char]104 + [char]112 + [char]95
    [System.IO.File]::WriteAllText((Join-Path $sentinel 'sentinel.txt'), ($prefix + ('A' * 36)), [System.Text.UTF8Encoding]::new($false))
    & $pinnedGitleaks.Paths.Executable detect --no-git --source $sentinel --config (Join-Path $RepoRoot '.gitleaks.toml') --redact --no-banner 2>$null | Out-Null
    Assert ($LASTEXITCODE -ne 0) 'pinned gitleaks detects the planted sentinel'

    $contracts = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'schemas/artifact-contracts.psd1')
    Assert ($contracts.Contracts.ContainsKey('scan-input-manifest')) 'registry includes scan-input-manifest v1'
    Assert ($contracts.Contracts.ContainsKey('test-run-summary')) 'registry includes test-run-summary v1'
    Assert ($contracts.Contracts.ContainsKey('artifact-validation-manifest')) 'registry bootstraps the artifact manifest'

    Write-Host 'schema validation tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
