#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ValidatorCacheRoot = $null
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/transaction-journal-common.ps1')

function Assert-TestCondition {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

function Assert-TestThrows {
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

function Write-TestBytes {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [byte[]] $Bytes)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $Bytes.Length) { throw 'Test replacement must preserve the exact byte length.' }
        $stream.Position = 0
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

$validatorScriptPath = Join-Path $RepoRoot 'scripts/validate-json-artifacts.ps1'
$validatorTokens = $null
$validatorParseErrors = $null
$validatorAst = [System.Management.Automation.Language.Parser]::ParseFile($validatorScriptPath, [ref] $validatorTokens, [ref] $validatorParseErrors)
Assert-TestCondition (@($validatorParseErrors).Count -eq 0) 'artifact validator parses before exact-byte function extraction'
foreach ($statement in @($validatorAst.EndBlock.Statements)) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-exact-byte-tests-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($work) | Out-Null
try {
    $schemaPath = Join-Path $work 'exact-byte-race.schema.json'
    $instancePath = Join-Path $work 'exact-byte-race.json'
    $schemaAText = @'
{
  "$schema":"https://json-schema.org/draft/2020-12/schema",
  "$id":"https://ai-agent-dotfiles.invalid/schemas/exact-byte-race.schema.json",
  "type":"object",
  "required":["SchemaVersion","Mode","Pad"],
  "properties":{
    "SchemaVersion":{"const":1},
    "Mode":{"const":"schema"},
    "Pad":{"type":"string","minLength":4,"maxLength":4}
  },
  "unevaluatedProperties":false
}
'@
    $schemaBText = $schemaAText.Replace('"Mode":{"const":"schema"}', '"Mode":{"const":"semanx"}')
    $schemaABytes = [System.Text.UTF8Encoding]::new($false).GetBytes($schemaAText)
    $schemaBBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($schemaBText)
    Assert-TestCondition ($schemaABytes.Length -eq $schemaBBytes.Length) 'schema race vectors have exactly the same byte length'
    [System.IO.File]::WriteAllBytes($schemaPath, $schemaABytes)

    Write-Host '[instance schema and semantic snapshot binding]'
    $instanceAText = '{"SchemaVersion":1,"Mode":"schema","Pad":"aaaa"}'
    $instanceBText = '{"SchemaVersion":1,"Mode":"semanx","Pad":"bbbb"}'
    $instanceABytes = [System.Text.UTF8Encoding]::new($false).GetBytes($instanceAText)
    $instanceBBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($instanceBText)
    Assert-TestCondition ($instanceABytes.Length -eq $instanceBBytes.Length) 'instance race vectors have exactly the same byte length'
    [System.IO.File]::WriteAllBytes($instancePath, $instanceABytes)

    function Test-ExactByteSemanticSentinel {
        [CmdletBinding(DefaultParameterSetName = 'Document')]
        param(
            [Parameter(Mandatory, ParameterSetName = 'Path')] [string] $Path,
            [Parameter(Mandatory, ParameterSetName = 'Document')] [System.Collections.IDictionary] $Document
        )
        if ($PSCmdlet.ParameterSetName -ceq 'Path') {
            $Document = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true)))
        }
        if ([string] $Document.Mode -cne 'semanx') { throw 'exact-byte semantic sentinel rejected the schema-valid snapshot' }
    }

    $semanticRaceContract = @{
        SchemaVersion = 1
        SchemaPath = $schemaPath
        SemanticValidator = 'Test-ExactByteSemanticSentinel'
    }
    $realFixedValidator = ${function:Invoke-FixedJsonSchemaValidation}
    $script:ExactByteReplacement = $instanceBBytes
    $script:ExactByteBoundaryCount = 0
    function Invoke-FixedJsonSchemaValidation {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] [string] $SchemaPath,
            [Parameter(Mandatory)] [string] $InstancePath,
            [string] $ValidatorCacheRoot
        )
        $arguments = @{ SchemaPath = $SchemaPath; InstancePath = $InstancePath }
        if ($PSBoundParameters.ContainsKey('ValidatorCacheRoot')) { $arguments.ValidatorCacheRoot = $ValidatorCacheRoot }
        $result = & $realFixedValidator @arguments
        Write-TestBytes -Path $InstancePath -Bytes $script:ExactByteReplacement
        $script:ExactByteBoundaryCount++
        return $result
    }
    try {
        Assert-TestThrows {
            Invoke-ContractValidation -ArtifactKind 'exact-byte-race' -Contract $semanticRaceContract -Path $instancePath
        } 'exact-byte semantic sentinel' 'schema and semantic validation cannot accept different same-identity file states'
        Assert-TestCondition ($script:ExactByteBoundaryCount -eq 1) 'instance content changes exactly once after schema validation'
    }
    finally {
        Set-Item -LiteralPath Function:Invoke-FixedJsonSchemaValidation -Value $realFixedValidator
        Remove-Variable -Name ExactByteReplacement, ExactByteBoundaryCount -Scope Script -ErrorAction SilentlyContinue
    }

    Write-Host '[manifest hash and child validation snapshot binding]'
    $manifestAText = '{"SchemaVersion":1,"Mode":"schema","Pad":"aaaa"}'
    $manifestBText = '{"SchemaVersion":1,"Mode":"schema","Pad":"bbbb"}'
    $manifestABytes = [System.Text.UTF8Encoding]::new($false).GetBytes($manifestAText)
    $manifestBBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($manifestBText)
    Assert-TestCondition ($manifestABytes.Length -eq $manifestBBytes.Length) 'manifest child race vectors have exactly the same byte length'
    [System.IO.File]::WriteAllBytes($instancePath, $manifestABytes)
    $expectedManifestHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($manifestABytes)).ToLowerInvariant()

    function Test-ExactByteManifestSentinel {
        [CmdletBinding(DefaultParameterSetName = 'Document')]
        param(
            [Parameter(Mandatory, ParameterSetName = 'Path')] [string] $Path,
            [Parameter(Mandatory, ParameterSetName = 'Document')] [System.Collections.IDictionary] $Document
        )
        if ($PSCmdlet.ParameterSetName -ceq 'Path') {
            $Document = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true)))
        }
        if ([string] $Document.Mode -cne 'schema') { throw 'manifest child semantic sentinel rejected the captured document' }
    }
    $manifestRaceContract = @{
        SchemaVersion = 1
        SchemaPath = $schemaPath
        SemanticValidator = 'Test-ExactByteManifestSentinel'
    }
    $realFixedValidator = ${function:Invoke-FixedJsonSchemaValidation}
    $script:ExactByteReplacement = $manifestBBytes
    $script:ExactByteBoundaryCount = 0
    function Invoke-FixedJsonSchemaValidation {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] [string] $SchemaPath,
            [Parameter(Mandatory)] [string] $InstancePath,
            [string] $ValidatorCacheRoot
        )
        Write-TestBytes -Path $InstancePath -Bytes $script:ExactByteReplacement
        $script:ExactByteBoundaryCount++
        $arguments = @{ SchemaPath = $SchemaPath; InstancePath = $InstancePath }
        if ($PSBoundParameters.ContainsKey('ValidatorCacheRoot')) { $arguments.ValidatorCacheRoot = $ValidatorCacheRoot }
        return & $realFixedValidator @arguments
    }
    try {
        Assert-TestThrows {
            if ((Get-Command Invoke-ContractValidation -CommandType Function).Parameters.ContainsKey('ExpectedSha256')) {
                Invoke-ContractValidation -ArtifactKind 'exact-byte-manifest-child' -Contract $manifestRaceContract -Path $instancePath -ExpectedSha256 $expectedManifestHash
            }
            else {
                $separateHash = (Get-FileHash -LiteralPath $instancePath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($separateHash -cne $expectedManifestHash) { throw "Artifact content hash mismatch: $instancePath" }
                Invoke-ContractValidation -ArtifactKind 'exact-byte-manifest-child' -Contract $manifestRaceContract -Path $instancePath
            }
        } 'content hash mismatch' 'manifest hash and child validation bind one captured byte sequence'
        Assert-TestCondition ($script:ExactByteBoundaryCount -eq 1) 'manifest child changes exactly once at the validation boundary'
    }
    finally {
        Set-Item -LiteralPath Function:Invoke-FixedJsonSchemaValidation -Value $realFixedValidator
        Remove-Variable -Name ExactByteReplacement, ExactByteBoundaryCount -Scope Script -ErrorAction SilentlyContinue
    }

    Write-Host '[repository schema snapshot binding]'
    [System.IO.File]::WriteAllBytes($schemaPath, $schemaABytes)
    [System.IO.File]::WriteAllBytes($instancePath, $instanceBBytes)
    $realSchemaPreflight = ${function:Test-RepositoryJsonSchema}
    $script:ExactByteSchemaPath = $schemaPath
    $script:ExactByteSchemaReplacement = $schemaBBytes
    $script:ExactByteSchemaBoundaryCount = 0
    function Test-RepositoryJsonSchema {
        [CmdletBinding()]
        param([Parameter(Mandatory)] [string] $SchemaPath, [Parameter(Mandatory)] [string] $SchemaRoot)
        $result = & $realSchemaPreflight -SchemaPath $SchemaPath -SchemaRoot $SchemaRoot
        Write-TestBytes -Path $script:ExactByteSchemaPath -Bytes $script:ExactByteSchemaReplacement
        $script:ExactByteSchemaBoundaryCount++
        return $result
    }
    try {
        Assert-TestThrows {
            Invoke-FixedJsonSchemaValidation -SchemaPath $schemaPath -InstancePath $instancePath
        } 'JSON Schema validation failed' 'schema policy and external validation consume one captured schema state'
        Assert-TestCondition ($script:ExactByteSchemaBoundaryCount -eq 1) 'schema content changes exactly once after policy validation captures it'
    }
    finally {
        Set-Item -LiteralPath Function:Test-RepositoryJsonSchema -Value $realSchemaPreflight
        Remove-Variable -Name ExactByteSchemaPath, ExactByteSchemaReplacement, ExactByteSchemaBoundaryCount -Scope Script -ErrorAction SilentlyContinue
    }

    Write-Host '[controlled schema copy and validator cleanup]'
    $heldCopyCommand = Get-Command New-HeldJsonSchemaCopy -CommandType Function -ErrorAction SilentlyContinue
    Assert-TestCondition (
        $null -ne $heldCopyCommand -and
        $heldCopyCommand.Definition -match 'Open-SafeDirectoryContainmentChain' -and
        $heldCopyCommand.Definition -match 'CreateChildDirectory' -and
        $heldCopyCommand.Definition -match 'CreateAndSealChildRegularFile' -and
        $heldCopyCommand.Definition -match 'DeleteChildRegularFileIfIdentity' -and
        $heldCopyCommand.Definition -match 'DeleteChildEmptyDirectoryIfIdentity'
    ) 'schema copy is created beneath a fully held no-follow temp containment chain'
    $schemaValidationForLease = Test-RepositoryJsonSchema -SchemaPath $schemaPath -SchemaRoot $work
    $heldSchemaCopy = New-HeldJsonSchemaCopy -SchemaCapture $schemaValidationForLease.ArtifactCapture
    $movedSchemaRoot = [string] $heldSchemaCopy.RootPath + '-replaced'
    $schemaParentReplacementBlocked = $false
    try {
        try { [System.IO.Directory]::Move([string] $heldSchemaCopy.RootPath, $movedSchemaRoot) }
        catch [System.IO.IOException] { $schemaParentReplacementBlocked = $true }
        Assert-TestCondition ($schemaParentReplacementBlocked -and (Test-Path -LiteralPath $heldSchemaCopy.SchemaPath -PathType Leaf) -and -not (Test-Path -LiteralPath $movedSchemaRoot)) 'held schema copy blocks ordinary parent replacement for the validator lifetime'
    }
    finally {
        Close-HeldJsonSchemaCopy -SchemaCopy $heldSchemaCopy
        if (Test-Path -LiteralPath $movedSchemaRoot) { Remove-Item -LiteralPath $movedSchemaRoot -Recurse -Force }
    }
    $closeSchemaCopyCommand = Get-Command Close-HeldJsonSchemaCopy -CommandType Function -ErrorAction Stop
    Assert-TestCondition (
        $closeSchemaCopyCommand.Definition -match 'GetChildNames' -and
        $closeSchemaCopyCommand.Definition -match 'DeleteChildRegularFileIfIdentity' -and
        $closeSchemaCopyCommand.Definition -match 'DeleteChildEmptyDirectoryIfIdentity' -and
        $closeSchemaCopyCommand.Definition -notmatch '\[System\.IO\.(File|Directory)\]::(Exists|Delete)|Remove-Item|Test-Path'
    ) 'controlled schema cleanup is held-parent-relative and identity-bound without path deletion fallback'

    $unknownSchemaCopy = New-HeldJsonSchemaCopy -SchemaCapture $schemaValidationForLease.ArtifactCapture
    $unknownSchemaRoot = [string] $unknownSchemaCopy.RootPath
    $unknownSchemaLeaf = Join-Path $unknownSchemaRoot 'unknown-entry.txt'
    try {
        [System.IO.File]::WriteAllText($unknownSchemaLeaf, 'unknown', [System.Text.UTF8Encoding]::new($false))
        Assert-TestThrows {
            Close-HeldJsonSchemaCopy -SchemaCopy $unknownSchemaCopy
        } 'unknown directory entry' 'schema cleanup rejects an unknown child instead of recursively deleting it'
        Assert-TestCondition (
            (Test-Path -LiteralPath $unknownSchemaLeaf -PathType Leaf) -and
            (Test-Path -LiteralPath $unknownSchemaCopy.SchemaPath -PathType Leaf)
        ) 'schema cleanup preserves every child when its exact inventory is not recognized'
    }
    finally {
        if (Test-Path -LiteralPath $unknownSchemaRoot -PathType Container) {
            Remove-Item -LiteralPath $unknownSchemaRoot -Recurse -Force
        }
    }
    $processCommand = Get-Command Invoke-PinnedToolProcess -CommandType Function -ErrorAction SilentlyContinue
    $singleValidatorCommand = Get-Command Invoke-PinnedJsonSchemaValidatorProcess -CommandType Function -ErrorAction SilentlyContinue
    $batchValidatorCommand = Get-Command Invoke-PinnedJsonSchemaValidatorFiles -CommandType Function -ErrorAction SilentlyContinue
    Assert-TestCondition (
        $null -ne $processCommand -and
        $processCommand.Definition -match 'PinnedToolProcessRunner.*::Run' -and
        $processCommand.Definition -match 'ExecutableHandle' -and
        $processCommand.Definition -match 'InspectChild' -and
        $processCommand.Definition -notmatch 'ProcessStartInfo|ReadToEndAsync|WaitForExit|\.Kill\(' -and
        $singleValidatorCommand.Definition -match 'Invoke-PinnedToolProcess' -and
        $batchValidatorCommand.Definition -match 'Invoke-PinnedToolProcess' -and
        $singleValidatorCommand.Definition -notmatch 'ReadToEndAsync|ProcessStartInfo' -and
        $batchValidatorCommand.Definition -notmatch 'ReadToEndAsync|ProcessStartInfo'
    ) 'all validator launches share bounded process wait, drain, tree termination, and confirmed reap handling'

    $tempPrefix = 'ai-agent-dotfiles-schema-copy-'
    $beforeSchemaCopies = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter ($tempPrefix + '*') | ForEach-Object FullName | Sort-Object)
    Assert-TestThrows {
        [System.IO.File]::WriteAllBytes($instancePath, [System.Text.UTF8Encoding]::new($false).GetBytes('{"SchemaVersion":1,"Mode":"invalid","Pad":"zzzz"}'))
        Invoke-FixedJsonSchemaValidation -SchemaPath $schemaPath -InstancePath $instancePath | Out-Null
    } 'JSON Schema validation failed' 'invalid stdin instance fails through the pinned validator'
    $afterSchemaCopies = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter ($tempPrefix + '*') | ForEach-Object FullName | Sort-Object)
    Assert-TestCondition (@(Compare-Object $beforeSchemaCopies $afterSchemaCopies -CaseSensitive).Count -eq 0) 'validator failure leaves no controlled schema-copy directory'

    Write-Host '[journal final raw bytes and held contract read]'
    $journalReadText = ${function:Read-CanonicalJsonContractFile}.Ast.Extent.Text
    Assert-TestCondition ($journalReadText -match 'Read-ExactJsonArtifactCapture' -and $journalReadText -notmatch '\[System\.IO\.File\]::Open|ReadAllText') 'canonical contract read delegates to the shared held exact-byte capture'
    $journalRoot = Join-Path $work 'journal-raw-publish'
    $journalPending = Join-Path $journalRoot '_pending'
    [System.IO.Directory]::CreateDirectory($journalPending) | Out-Null
    $journalFinal = Join-Path $journalRoot 'result.json'
    $journalDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path $RepoRoot 'tests/fixtures/artifacts/canonical-transaction-result.valid.json'), [System.Text.UTF8Encoding]::new($false, $true)))
    $journalPublish = Write-CanonicalAtomicJson -Document $journalDocument -FinalPath $journalFinal -PendingDirectory $journalPending -PendingName 'raw-equivalent.tmp' -SchemaPath (Join-Path $RepoRoot 'schemas/canonical-transaction-result.schema.json')
    $journalExpectedBytes = ConvertTo-SemanticJsonBytes -InputObject $journalDocument
    Assert-TestCondition (
        (Test-Path -LiteralPath $journalFinal -PathType Leaf) -and
        [string]$journalPublish.Sha256 -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($journalExpectedBytes)).ToLowerInvariant() -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalFinal)) -ceq [Convert]::ToBase64String($journalExpectedBytes)
    ) 'journal publishes the same held exact bytes that passed schema validation'

    Write-Host 'JSON artifact exact-byte tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
