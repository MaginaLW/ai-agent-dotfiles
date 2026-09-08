#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Message
    )
    $threw = $false
    try { & $Action }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw "FAIL: $Message (unexpected: $($_.Exception.Message))" }
    }
    if (-not $threw) { throw "FAIL: $Message (did not throw)" }
    Write-Host "  PASS  $Message"
}

$validatorScriptPath = Join-Path $RepoRoot 'scripts/validate-json-artifacts.ps1'
$validatorTokens = $null
$validatorParseErrors = $null
$validatorAst = [System.Management.Automation.Language.Parser]::ParseFile($validatorScriptPath, [ref] $validatorTokens, [ref] $validatorParseErrors)
Assert (@($validatorParseErrors).Count -eq 0) 'artifact validator parses before envelope-function extraction'
foreach ($statement in @($validatorAst.EndBlock.Statements)) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

$schemaPath = Join-Path $RepoRoot 'schemas/sync-plan.schema.json'
$compatSchemaPath = Join-Path $RepoRoot 'schemas/sync-plan.v2-live-compat.schema.json'
$positivePath = Join-Path $RepoRoot 'tests/fixtures/artifacts/sync-plan.valid.json'
$contractsPath = Join-Path $RepoRoot 'schemas/artifact-contracts.psd1'

Write-Host '[live-plan schema 3 contract files]'
Assert (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'sync-plan schema 3 file exists'
Assert (Test-Path -LiteralPath $compatSchemaPath -PathType Leaf) 'v2 live-compat schema exists'
Assert (Test-Path -LiteralPath $positivePath -PathType Leaf) 'sync-plan positive fixture exists'
Assert ($null -ne (Get-Command -Name Test-LiveSyncPlanEnvelopeSemantics -CommandType Function -ErrorAction SilentlyContinue)) 'Test-LiveSyncPlanEnvelopeSemantics is defined'

$compatSchema = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($compatSchemaPath, [System.Text.UTF8Encoding]::new($false, $true)))
Assert ([string] $compatSchema['$id'] -ceq 'https://ai-agent-dotfiles.invalid/schemas/sync-plan.v2-live-compat.schema.json') 'v2 live-compat $id matches basename'
Assert ([long] $compatSchema.properties.SchemaVersion.const -eq 2) 'v2 live-compat SchemaVersion remains const 2'

$contracts = Import-PowerShellDataFile -LiteralPath $contractsPath
Assert ($contracts.Contracts.ContainsKey('sync-plan')) 'artifact registry includes sync-plan'
$syncPlanContract = $contracts.Contracts['sync-plan']
Assert ([long] $syncPlanContract.SchemaVersion -eq 3) 'registry SchemaVersion is 3'
Assert ([string] $syncPlanContract.SchemaPath -ceq 'schemas/sync-plan.schema.json') 'registry SchemaPath is schema 3'
Assert ([string] $syncPlanContract.SemanticValidator -ceq 'Test-LiveSyncPlanEnvelopeSemantics') 'registry semantic validator is the envelope function'
Assert (@($syncPlanContract.NegativeFixtures).Count -eq 6) 'registry lists six negative fixtures'

Write-Host '[live-plan positive envelope]'
$null = Invoke-FixedJsonSchemaValidation -SchemaPath $schemaPath -InstancePath $positivePath
Assert $true 'positive fixture passes schema 3'
$positive = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($positivePath, [System.Text.UTF8Encoding]::new($false, $true)))
Test-LiveSyncPlanEnvelopeSemantics -Document $positive
Assert $true 'positive fixture passes envelope semantics'
Assert ([long] $positive.SchemaVersion -eq 3) 'SchemaVersion is 3'
Assert ([string] $positive.ArtifactKind -ceq 'sync-plan') 'ArtifactKind is sync-plan'
Assert ($positive.Contains('Metadata') -and $positive.Contains('PlanPayload') -and $positive.Contains('PlanHash') -and $positive.Contains('DocumentHash')) 'envelope has Metadata, PlanPayload, and both hashes'
Assert (-not $positive.Metadata.Contains('Generator')) 'Metadata does not carry Generator'
Assert ([string] $positive.PlanPayload.OperationKind -ceq 'initial') 'OperationKind is initial'
Assert ([string] $positive.PlanPayload.Generator -ceq 'scripts/sync.ps1') 'Generator is scripts/sync.ps1'
Assert ([string] $positive.PlanPayload.EnvironmentName -ceq 'full') 'EnvironmentName is full'
Assert ($positive.PlanPayload.TargetContextIntent.Contains('HomeAuthorityKey') -and $positive.PlanPayload.TargetContextIntent.Contains('Rows')) 'TargetContextIntent is the wrapper, not a bare row array'
Assert (@($positive.PlanPayload.TargetContextIntent.Rows).Count -eq 3) 'TargetContextIntent.Rows length is 3'
Assert (@($positive.PlanPayload.ProposedRootClaims).Count -eq 3) 'ProposedRootClaims has three rows'
$platforms = @('Claude', 'Codex', 'Reasonix')
for ($index = 0; $index -lt 3; $index++) {
    $row = $positive.PlanPayload.TargetContextIntent.Rows[$index]
    $claim = $positive.PlanPayload.ProposedRootClaims[$index]
    $slot = $positive.PlanPayload.Platforms[$index]
    Assert ([string] $row.Platform -ceq $platforms[$index] -and [string] $row.InitialState -ceq 'ABSENT' -and $null -eq $row.InitialDirectoryIdentity -and @($row.MissingRemainder).Count -ge 1) "TargetContextIntent row $($platforms[$index]) is ABSENT"
    Assert ([string] $claim.Platform -ceq $platforms[$index] -and [string] $claim.InitialState -ceq 'ABSENT' -and $null -eq $claim.InitialDirectoryIdentity -and @($claim.MissingRemainder).Count -ge 1) "ProposedRootClaims $($platforms[$index]) is ABSENT"
    Assert ($claim.RequestedPath.StartsWith('C:\fixture\', [System.StringComparison]::Ordinal)) "ProposedRootClaims $($platforms[$index]) uses C:\fixture path"
    Assert (-not [bool] $slot.LiveRootExists -and [string] $slot.LivePreIdentity.TargetStatus -ceq 'MISSING' -and $null -eq $slot.LivePreIdentity.DirectoryIdentity -and $null -eq $slot.LiveTreeHash) "live $($platforms[$index]) is ABSENT/MISSING"
}
Assert ([string] $positive.PlanPayload.ProposedRootClaims[1].InitialState -cne 'EXISTS') 'Codex ProposedRootClaims is not the EXISTS root-claims.valid.json shape'
Assert ([string] $positive.PlanPayload.AuthorityStateIntent.LastOperationKind -ceq 'initial') 'intent LastOperationKind is initial'
Assert (-not $positive.PlanPayload.AuthorityStateIntent.Contains('PlanHash')) 'intent omits envelope PlanHash'
Assert (-not $positive.PlanPayload.AuthorityStateIntent.Contains('DocumentHash')) 'intent omits envelope DocumentHash'
Assert (-not $positive.PlanPayload.AuthorityStateIntent.Contains('ReceiptId')) 'intent omits runtime ReceiptId'
Assert ([string] $positive.PlanHash -ceq (Get-PlanHash -PlanPayload $positive.PlanPayload)) 'precomputed PlanHash matches Get-PlanHash'
Assert ([string] $positive.DocumentHash -ceq (Get-DocumentHash -Document $positive)) 'precomputed DocumentHash matches Get-DocumentHash'
Assert ([string] $positive.PlanPayload.RootClaimsHash -ceq (Get-SemanticJsonHash -InputObject @($positive.PlanPayload.ProposedRootClaims))) 'RootClaimsHash is the semantic hash of ProposedRootClaims'

Write-Host '[live-plan negative FailureLayer]'
$expectedLayers = @{
    'unknown-property' = 'Schema'
    'wrong-version' = 'Schema'
    'live-recover-kind' = 'Schema'
    'runtime-receipt' = 'Schema'
    'plan-hash-mismatch' = 'Semantic'
    'document-hash-mismatch' = 'Semantic'
}
foreach ($negative in @($syncPlanContract.NegativeFixtures)) {
    $negativePath = Join-Path $RepoRoot ([string] $negative.Path)
    Assert (Test-Path -LiteralPath $negativePath -PathType Leaf) "negative fixture $($negative.Name) exists"
    $failedAt = $null
    try {
        $null = Invoke-FixedJsonSchemaValidation -SchemaPath $schemaPath -InstancePath $negativePath
    }
    catch { $failedAt = 'Schema' }
    if (-not $failedAt) {
        try {
            $negativeDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($negativePath, [System.Text.UTF8Encoding]::new($false, $true)))
            Test-LiveSyncPlanEnvelopeSemantics -Document $negativeDocument
        }
        catch { $failedAt = 'Semantic' }
    }
    $expected = [string] $expectedLayers[[string] $negative.Name]
    Assert ($failedAt -ceq [string] $negative.FailureLayer -and $failedAt -ceq $expected) "$($negative.Name) fails at $($negative.FailureLayer)"
}

Write-Host '[live-plan forbidden kinds]'
Assert-Throws {
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $schemaPath -InstancePath (Join-Path $RepoRoot 'tests/fixtures/artifacts/sync-plan.live-recover-kind.invalid.json')
} 'validation failed' 'live-recover OperationKind is rejected by schema 3'

$syncTestsPath = Join-Path $RepoRoot 'tests/sync.tests.ps1'
$syncTestsText = [System.IO.File]::ReadAllText($syncTestsPath)
Assert ($syncTestsText.Contains("Join-Path `$RepoRoot 'schemas/sync-plan.v2-live-compat.schema.json'")) 'sync.tests.ps1 SchemaPath sites use the v2 live-compat schema'
Assert ($syncTestsText.Contains('[int] $plan.SchemaVersion -eq 2')) 'content-aware dry-run still asserts emitter SchemaVersion 2'
Assert ($syncTestsText.Contains('[int] $retirementPlanDocument.SchemaVersion -eq 2')) 'retirement dry-run still asserts emitter SchemaVersion 2'

Write-Host 'Live plan contract tests: PASS'
