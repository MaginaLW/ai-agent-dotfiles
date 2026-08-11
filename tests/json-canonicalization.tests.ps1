#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/semantic-json.ps1')

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

Write-Host '[semantic JSON serialization]'
$left = ConvertFrom-SemanticJson -Json '{"z":0,"a":{"b":2,"a":1},"s":"line\n\u20ac","empty":[],"missing":"MISSING","n":null}'
$right = ConvertFrom-SemanticJson -Json '{"n":null,"missing":"MISSING","empty":[],"s":"line\n€","a":{"a":1,"b":2},"z":0}'
$leftBytes = ConvertTo-SemanticJsonBytes -InputObject $left
$rightBytes = ConvertTo-SemanticJsonBytes -InputObject $right
Assert ([Convert]::ToHexString($leftBytes) -eq [Convert]::ToHexString($rightBytes)) 'property order and equivalent Unicode escape forms canonicalize identically'
Assert ($leftBytes.Length -gt 0 -and -not ($leftBytes[0] -eq 0xEF -and $leftBytes[1] -eq 0xBB -and $leftBytes[2] -eq 0xBF)) 'serialization is UTF-8 without BOM'
Assert (([System.Text.Encoding]::UTF8.GetString($leftBytes)) -eq '{"a":{"a":1,"b":2},"empty":[],"missing":"MISSING","n":null,"s":"line\n€","z":0}') 'nested, empty, MISSING, null, escaping and ordering have fixed bytes'

Write-Host '[hashes]'
$payload = ConvertFrom-SemanticJson -Json '{"Mode":"DryRun","Names":["a","b"]}'
$document = [ordered]@{ SchemaVersion = 1; PlanHash = (Get-PlanHash -PlanPayload $payload); PlanPayload = $payload }
$document.DocumentHash = Get-DocumentHash -Document $document
Assert ($document.PlanHash -eq (Get-PlanHash -PlanPayload $payload)) 'PlanHash covers the complete PlanPayload'
$originalDocumentHash = $document.DocumentHash
$document.PlanHash = ('0' * 64)
Assert ($originalDocumentHash -ne (Get-DocumentHash -Document $document)) 'DocumentHash includes PlanHash and excludes only DocumentHash itself'

Write-Host '[negative numeric and parser vectors]'
Assert-Throws { ConvertFrom-SemanticJson -Json '{"a":1,"a":2}' } 'duplicate' 'duplicate object properties fail closed'
Assert-Throws { ConvertFrom-SemanticJson -Json '{"n":1.0}' } 'integer|fraction|number' 'fractional spellings fail closed'
Assert-Throws { ConvertFrom-SemanticJson -Json '{"n":1e2}' } 'integer|exponent|number' 'exponent spellings fail closed'
Assert-Throws { ConvertFrom-SemanticJson -Json '{"n":9007199254740992}' } 'I-JSON|safe' 'integers above the I-JSON safe range fail closed'
Assert-Throws { ConvertFrom-SemanticJson -Json '{"n":-9007199254740992}' } 'I-JSON|safe' 'integers below the I-JSON safe range fail closed'

Write-Host '[fresh process determinism]'
$fixture = Join-Path $PSScriptRoot 'fixtures/json-canonicalization/process-vector.json'
$pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
$command = ". '$($RepoRoot.Replace("'", "''"))\scripts\semantic-json.ps1'; Get-SemanticJsonHash -Path '$($fixture.Replace("'", "''"))'"
$hash1 = (& $pwsh -NoProfile -Command $command).Trim()
$hash2 = (& $pwsh -NoProfile -Command $command).Trim()
Assert ($LASTEXITCODE -eq 0 -and $hash1 -eq $hash2 -and $hash1 -match '^[0-9a-f]{64}$') 'two fresh processes produce the same semantic hash'

Write-Host 'JSON canonicalization tests: PASS'
