#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-safety-interlock.ps1')
. (Join-Path $RepoRoot 'tests/helpers/sealed-live-plan-fixture.ps1')

$script:pass = 0

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:pass++
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
    $script:pass++
    Write-Host "  PASS  $Message"
}

function Copy-LivePlanDocument {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    $json = [System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $Document))
    return ConvertFrom-SemanticJson -Json $json
}

function Update-LivePlanEnvelopeHashes {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    $Document['PlanHash'] = Get-PlanHash -PlanPayload $Document.PlanPayload
    $Document['DocumentHash'] = Get-DocumentHash -Document $Document
}

function New-LivePlanRepeatedHash {
    param([Parameter(Mandatory)] [string] $Character)
    return ($Character * 64)
}

function New-FinalIdentitiesFromIntent {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Intent)
    $created = @('a1b2c3d4:0000000000000f01', 'a1b2c3d4:0000000000000f02', 'a1b2c3d4:0000000000000f03')
    $rows = @($Intent.Rows)
    $result = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 3; $index++) {
        $row = $rows[$index]
        $identity = if ([string] $row.InitialState -ceq 'EXISTS') {
            [string] $row.InitialDirectoryIdentity
        }
        else {
            $created[$index]
        }
        $result.Add([ordered]@{
            DirectoryIdentity = $identity
            FilesystemCapabilityHash = New-LivePlanRepeatedHash -Character '9'
            LocationKey = [string] $row.LocationKey
            Platform = [string] $row.Platform
            ResolvedPath = [string] $row.RequestedPath
            VolumeId = [string] $row.VolumeId
        })
    }
    return @($result)
}

function New-TestRetirementManifest {
    param(
        [string] $ConflictName,
        [string] $SafeName = 'retired-skill'
    )
    $claudeSkills = @()
    if ($ConflictName) { $claudeSkills = @($ConflictName) }
    return [ordered]@{
        CanonicalAbsenceHash = New-LivePlanRepeatedHash -Character '1'
        CurrentManifestAbsenceHash = New-LivePlanRepeatedHash -Character '2'
        GeneratedAbsenceHash = New-LivePlanRepeatedHash -Character '3'
        Hash = New-LivePlanRepeatedHash -Character '4'
        Path = 'C:\fixture\retirement\manifest.json'
        Postset = [ordered]@{
            EnvironmentLockHash = New-LivePlanRepeatedHash -Character 'b'
            EnvironmentName = 'work'
            ManifestHashes = @(
                [ordered]@{ Hash = (New-LivePlanRepeatedHash -Character 'd'); Platform = 'Claude' }
                [ordered]@{ Hash = (New-LivePlanRepeatedHash -Character 'e'); Platform = 'Codex' }
                [ordered]@{ Hash = (New-LivePlanRepeatedHash -Character 'f'); Platform = 'Reasonix' }
            )
            TaskOverlayHash = New-LivePlanRepeatedHash -Character 'c'
            TaskOverlaySkills = @(
                [ordered]@{ Platform = 'Claude'; Skills = @($claudeSkills) }
                [ordered]@{ Platform = 'Codex'; Skills = @() }
                [ordered]@{ Platform = 'Reasonix'; Skills = @() }
            )
        }
        SafeNames = @(
            [ordered]@{ Names = @($SafeName); Platform = 'Claude' }
            [ordered]@{ Names = @(); Platform = 'Codex' }
            [ordered]@{ Names = @(); Platform = 'Reasonix' }
        )
        TargetTreeHashes = @(
            [ordered]@{ Hash = (New-LivePlanRepeatedHash -Character '8'); Platform = 'Claude' }
            [ordered]@{ Hash = (New-LivePlanRepeatedHash -Character '9'); Platform = 'Codex' }
            [ordered]@{ Hash = (New-LivePlanRepeatedHash -Character 'a'); Platform = 'Reasonix' }
        )
    }
}

function New-TestPruneAction {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $Platform = 'Claude'
    )
    return [ordered]@{
        Action = 'prune'
        Authority = 'explicit-retirement'
        LiveHash = New-LivePlanRepeatedHash -Character '7'
        Name = $Name
        Order = 0
        Platform = $Platform
        SourceHash = $null
    }
}

$schemaPath = Join-Path $RepoRoot 'schemas/sync-plan.schema.json'
$compatSchemaPath = Join-Path $RepoRoot 'schemas/sync-plan.v2-live-compat.schema.json'
$positivePath = Join-Path $RepoRoot 'tests/fixtures/artifacts/sync-plan.valid.json'
$contractsPath = Join-Path $RepoRoot 'schemas/artifact-contracts.psd1'
$validatorScriptPath = Join-Path $RepoRoot 'scripts/validate-json-artifacts.ps1'
$livePlanCommonPath = Join-Path $RepoRoot 'scripts/live-plan-common.ps1'
$syncScriptPath = Join-Path $RepoRoot 'scripts/sync.ps1'

Write-Host '[live-plan schema 3 contract files]'
Assert (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'sync-plan schema 3 file exists'
Assert (-not (Test-Path -LiteralPath $compatSchemaPath)) 'the frozen v2 live-compat schema is removed'
Assert (Test-Path -LiteralPath $positivePath -PathType Leaf) 'sync-plan positive fixture exists'
Assert (Test-Path -LiteralPath $livePlanCommonPath -PathType Leaf) 'live-plan-common.ps1 exists'
Assert ($null -ne (Get-Command -Name Test-LiveSyncPlanSemantics -CommandType Function -ErrorAction SilentlyContinue)) 'Test-LiveSyncPlanSemantics is defined'
Assert ($null -ne (Get-Command -Name Complete-LivePlanAuthorityStateIntent -CommandType Function -ErrorAction SilentlyContinue)) 'Complete-LivePlanAuthorityStateIntent is defined'
Assert ($null -eq (Get-Command -Name Test-LiveSyncPlanEnvelopeSemantics -CommandType Function -ErrorAction SilentlyContinue)) 'Test-LiveSyncPlanEnvelopeSemantics is not defined'

$validatorText = [System.IO.File]::ReadAllText($validatorScriptPath)
Assert ($validatorText.Contains('live-plan-common.ps1')) 'artifact validator dotsources live-plan-common.ps1'
Assert (-not $validatorText.Contains('function Test-LiveSyncPlanEnvelopeSemantics')) 'artifact validator no longer defines the thin envelope function'
$livePlanCommonText = [System.IO.File]::ReadAllText($livePlanCommonPath)
Assert ($livePlanCommonText.Contains('function Test-LiveSyncPlanSemantics')) 'live-plan-common uniquely defines Test-LiveSyncPlanSemantics'
Assert ($livePlanCommonText.Contains('function Complete-LivePlanAuthorityStateIntent')) 'live-plan-common uniquely defines Complete-LivePlanAuthorityStateIntent'
$syncScriptText = [System.IO.File]::ReadAllText($syncScriptPath)
Assert ($syncScriptText.Contains('function New-LiveSyncPlanDocument')) 'sync.ps1 defines the schema 3 producer'
Assert ($syncScriptText.Contains('Write-LiveSyncPlan')) 'sync.ps1 emitter writes through the immutable create-new write'
Assert (-not $syncScriptText.Contains('$legacyDeployRequested')) 'the legacy content-aware deploy route is removed by Task 5'
Assert (-not $syncScriptText.Contains('function Get-SyncPlan')) 'the legacy content-aware planner is removed by Task 5'
Assert (-not $syncScriptText.Contains('function Sync-OneSkillDir')) 'the legacy per-skill deploy is removed by Task 5'
Assert (-not $syncScriptText.Contains('function Write-SyncJournal')) 'the legacy overwrite-style journal is removed by Task 5'
Assert (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'tests/helpers/task5-environment-sync-regression.ps1'))) 'the extracted task5 environment regression helper is retired with the legacy route'

$contracts = Import-PowerShellDataFile -LiteralPath $contractsPath
Assert ($contracts.Contracts.ContainsKey('sync-plan')) 'artifact registry includes sync-plan'
$syncPlanContract = $contracts.Contracts['sync-plan']
Assert ([long] $syncPlanContract.SchemaVersion -eq 3) 'registry SchemaVersion is 3'
Assert ([string] $syncPlanContract.SchemaPath -ceq 'schemas/sync-plan.schema.json') 'registry SchemaPath is schema 3'
Assert ([string] $syncPlanContract.SemanticValidator -ceq 'Test-LiveSyncPlanSemantics') 'registry semantic validator is the full-semantics function'
Assert (@($syncPlanContract.NegativeFixtures).Count -eq 6) 'registry lists six negative fixtures'

Write-Host '[live-plan positive envelope]'
$null = Invoke-FixedJsonSchemaValidation -SchemaPath $schemaPath -InstancePath $positivePath
Assert $true 'positive fixture passes schema 3'
$positive = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($positivePath, [System.Text.UTF8Encoding]::new($false, $true)))
Test-LiveSyncPlanSemantics -Document $positive
Assert $true 'positive fixture passes full plan semantics'
Assert ([long] $positive.SchemaVersion -eq 3) 'SchemaVersion is 3'
Assert ([string] $positive.ArtifactKind -ceq 'sync-plan') 'ArtifactKind is sync-plan'
Assert ($positive.Contains('Metadata') -and $positive.Contains('PlanPayload') -and $positive.Contains('PlanHash') -and $positive.Contains('DocumentHash')) 'envelope has Metadata, PlanPayload, and both hashes'
Assert (-not $positive.Metadata.Contains('Generator')) 'Metadata does not carry Generator'
Assert ([string] $positive.PlanPayload.OperationKind -ceq 'initial') 'OperationKind is initial'
Assert ([string] $positive.PlanPayload.Generator -ceq 'scripts/sync.ps1') 'Generator is scripts/sync.ps1'
Assert ([string] $positive.PlanPayload.EnvironmentName -ceq 'full') 'EnvironmentName is full'
Assert ($positive.PlanPayload.TargetContextIntent.Contains('HomeAuthorityKey') -and $positive.PlanPayload.TargetContextIntent.Contains('Rows')) 'TargetContextIntent is the wrapper, not a bare row array'
Assert (@($positive.PlanPayload.TargetContextIntent.Rows).Count -eq 3) 'TargetContextIntent.Rows length is 3'
Assert ([string] $positive.PlanPayload.ProposedRootClaims.ArtifactKind -ceq 'root-claims' -and [long] $positive.PlanPayload.ProposedRootClaims.SchemaVersion -eq 1) 'ProposedRootClaims is the complete root-claims document'
Assert (@($positive.PlanPayload.ProposedRootClaims.LiveRootClaims).Count -eq 3) 'ProposedRootClaims carries three claim rows'
$platforms = @('Claude', 'Codex', 'Reasonix')
for ($index = 0; $index -lt 3; $index++) {
    $row = $positive.PlanPayload.TargetContextIntent.Rows[$index]
    $claim = $positive.PlanPayload.ProposedRootClaims.LiveRootClaims[$index]
    $slot = $positive.PlanPayload.Platforms[$index]
    Assert ([string] $row.Platform -ceq $platforms[$index] -and [string] $row.InitialState -ceq 'ABSENT' -and $null -eq $row.InitialDirectoryIdentity -and @($row.MissingRemainder).Count -ge 1) "TargetContextIntent row $($platforms[$index]) is ABSENT"
    Assert ([string] $claim.Platform -ceq $platforms[$index] -and [string] $claim.InitialState -ceq 'ABSENT' -and $null -eq $claim.InitialDirectoryIdentity -and @($claim.MissingRemainder).Count -ge 1) "ProposedRootClaims $($platforms[$index]) is ABSENT"
    Assert ($claim.RequestedPath.StartsWith('C:\fixture', [System.StringComparison]::Ordinal)) "ProposedRootClaims $($platforms[$index]) uses C:\fixture path"
    Assert (-not [bool] $slot.LiveRootExists -and [string] $slot.LivePreIdentity.TargetStatus -ceq 'MISSING' -and $null -eq $slot.LivePreIdentity.DirectoryIdentity -and $null -eq $slot.LiveTreeHash) "live $($platforms[$index]) is ABSENT/MISSING"
}
Assert ([string] $positive.PlanPayload.ProposedRootClaims.LiveRootClaims[1].InitialState -cne 'EXISTS') 'Codex ProposedRootClaims is not the EXISTS root-claims.valid.json shape'
Assert ([string] $positive.PlanPayload.AuthorityStateIntent.LastOperationKind -ceq 'initial') 'intent LastOperationKind is initial'
Assert (-not $positive.PlanPayload.AuthorityStateIntent.Contains('PlanHash')) 'intent omits envelope PlanHash'
Assert (-not $positive.PlanPayload.AuthorityStateIntent.Contains('DocumentHash')) 'intent omits envelope DocumentHash'
Assert (-not $positive.PlanPayload.AuthorityStateIntent.Contains('ReceiptId')) 'intent omits runtime ReceiptId'
Assert ([string] $positive.PlanHash -ceq (Get-PlanHash -PlanPayload $positive.PlanPayload)) 'precomputed PlanHash matches Get-PlanHash'
Assert ([string] $positive.DocumentHash -ceq (Get-DocumentHash -Document $positive)) 'precomputed DocumentHash matches Get-DocumentHash'
Assert ([string] $positive.PlanPayload.RootClaimsHash -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]] (ConvertTo-SemanticJsonBytes -InputObject $positive.PlanPayload.ProposedRootClaims))).ToLowerInvariant()) 'RootClaimsHash binds the exact bytes of the complete proposed root-claims document'

Write-Host '[live-plan complete intent]'
$completedInitial = Complete-LivePlanAuthorityStateIntent -Document $positive
Assert-AuthorityStateExactKeys -InputObject $completedInitial -Expected $script:AuthorityStateIntentFieldNames -Label 'completed initial intent'
Assert ([string] $completedInitial.PlanHash -ceq [string] $positive.PlanHash) 'completed intent PlanHash matches envelope'
Assert ([string] $completedInitial.DocumentHash -ceq [string] $positive.DocumentHash) 'completed intent DocumentHash matches envelope'
Assert (-not $completedInitial.Contains('ReceiptRef')) 'completed initial intent omits ReceiptRef'
$initialRuntime = [ordered]@{
    JournalId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    PreStatePhaseHash = New-LivePlanRepeatedHash -Character '1'
    ReceiptHash = New-LivePlanRepeatedHash -Character '2'
    ReceiptId = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'
}
$initialPostimage = New-AuthorityStatePostimage -AuthorityStateIntent $completedInitial -TargetContextIntent $positive.PlanPayload.TargetContextIntent -FinalResolvedIdentities (New-FinalIdentitiesFromIntent -Intent $positive.PlanPayload.TargetContextIntent) -RuntimeRefs $initialRuntime
Assert ([string] $initialPostimage.LastOperationKind -ceq 'initial') 'completed initial intent is accepted by New-AuthorityStatePostimage'

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
            Test-LiveSyncPlanSemantics -Document $negativeDocument
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
Assert (-not $syncTestsText.Contains('sync-plan.v2-live-compat.schema.json')) 'sync.tests.ps1 no longer references the removed v2 live-compat schema'
Assert (-not $syncTestsText.Contains('task5-environment-sync-regression')) 'sync.tests.ps1 does not invoke the extracted task5 environment helper'
Assert ($syncTestsText.Contains("'-RetireManifestPath'")) 'sync.tests.ps1 still exercises the explicit retirement producer'

Write-Host '[sealed helper capability]'
Assert-Throws {
    $null = New-SealedLivePlanDocument -OperationKind environment
} '^live-plan-host-resolution-required$' 'sealed helper throws when sandbox capability is missing'

Write-Host '[sealed helper positives and complete intent]'
$sandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('live-plan-cap-' + [Guid]::NewGuid().ToString('N'))
$capability = $null
$previousRoot = $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT
$previousPath = $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_PATH
$previousCapability = $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_TOKEN
try {
    $null = New-Item -ItemType Directory -Path $sandboxRoot
    $capability = New-LiveSafetySandboxCapability -SandboxRoot $sandboxRoot
    $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT = $capability.Root
    $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_PATH = $capability.Path
    $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_TOKEN = $capability.Token

    $environmentDocument = New-SealedLivePlanDocument -OperationKind environment
    Test-LiveSyncPlanSemantics -Document $environmentDocument
    Assert $true 'sealed environment document passes full plan semantics'
    Assert ([string] $environmentDocument.PlanPayload.OperationKind -ceq 'environment') 'sealed environment OperationKind is environment'
    Assert ([string] $environmentDocument.PlanPayload.Generator -ceq 'tests/helpers/sealed-live-plan-fixture.ps1') 'sealed environment Generator is the helper'
    Assert ($environmentDocument.PlanPayload.Contains('EnvironmentMaterializationRoot')) 'sealed environment binds materialization'
    Assert (-not $environmentDocument.PlanPayload.Contains('ProposedRootClaims')) 'sealed environment omits ProposedRootClaims'
    Assert ([string] $environmentDocument.PlanPayload.AuthorityStateIntent.LastOperationKind -ceq 'environment') 'sealed environment intent LastOperationKind is environment'
    $completedEnvironment = Complete-LivePlanAuthorityStateIntent -Document $environmentDocument
    Assert-AuthorityStateExactKeys -InputObject $completedEnvironment -Expected $script:AuthorityStateIntentFieldNames -Label 'completed environment intent'
    $environmentRuntime = [ordered]@{
        JournalId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        PreStatePhaseHash = New-LivePlanRepeatedHash -Character '1'
        ReceiptHash = New-LivePlanRepeatedHash -Character '2'
        ReceiptId = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'
    }
    $environmentPostimage = New-AuthorityStatePostimage -AuthorityStateIntent $completedEnvironment -TargetContextIntent $environmentDocument.PlanPayload.TargetContextIntent -FinalResolvedIdentities (New-FinalIdentitiesFromIntent -Intent $environmentDocument.PlanPayload.TargetContextIntent) -RuntimeRefs $environmentRuntime
    Assert ([string] $environmentPostimage.LastOperationKind -ceq 'environment') 'completed environment intent is accepted by New-AuthorityStatePostimage'

    $controllerDocument = New-SealedLivePlanDocument -OperationKind controller-transition
    Test-LiveSyncPlanSemantics -Document $controllerDocument
    Assert $true 'sealed controller-transition document passes full plan semantics'
    Assert ([string] $controllerDocument.PlanPayload.OperationKind -ceq 'controller-transition') 'sealed controller-transition OperationKind is controller-transition'
    Assert ([string] $controllerDocument.PlanPayload.Generator -ceq 'tests/helpers/sealed-live-plan-fixture.ps1') 'sealed controller-transition Generator is the helper'
    Assert ($controllerDocument.PlanPayload.Contains('ControllerParity')) 'sealed controller-transition binds ControllerParity'
    Assert ([string] $controllerDocument.PlanPayload.AuthorityStateIntent.ReceiptRef -ceq 'NO_LIVE_MUTATION') 'sealed controller-transition intent ReceiptRef is NO_LIVE_MUTATION'
    Assert (-not $controllerDocument.PlanPayload.AuthorityStateIntent.Contains('ReceiptId')) 'sealed controller-transition omits ReceiptId'
    $controllerExpected = [System.Collections.Generic.List[string]]::new()
    $controllerExpected.AddRange([string[]] $script:AuthorityStateIntentFieldNames)
    $controllerExpected.Add('ReceiptRef')
    $completedController = Complete-LivePlanAuthorityStateIntent -Document $controllerDocument
    Assert-AuthorityStateExactKeys -InputObject $completedController -Expected @($controllerExpected) -Label 'completed controller-transition intent'
    $controllerRuntime = [ordered]@{
        JournalId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        PreStatePhaseHash = New-LivePlanRepeatedHash -Character '1'
    }
    $controllerPostimage = New-AuthorityStatePostimage -AuthorityStateIntent $completedController -TargetContextIntent $controllerDocument.PlanPayload.TargetContextIntent -FinalResolvedIdentities (New-FinalIdentitiesFromIntent -Intent $controllerDocument.PlanPayload.TargetContextIntent) -RuntimeRefs $controllerRuntime
    Assert ([string] $controllerPostimage.ReceiptRef -ceq 'NO_LIVE_MUTATION') 'completed controller-transition intent is accepted by New-AuthorityStatePostimage'

    Write-Host '[live-plan negative matrix]'
    $crossEnvironment = Copy-LivePlanDocument -Document $environmentDocument
    $crossEnvironment.PlanPayload['ProposedRootClaims'] = $positive.PlanPayload.ProposedRootClaims
    Update-LivePlanEnvelopeHashes -Document $crossEnvironment
    Assert-Throws { Test-LiveSyncPlanSemantics -Document $crossEnvironment } '^live-plan-operation-kind-mismatch$' 'environment carrying ProposedRootClaims is rejected'

    $crossInitial = Copy-LivePlanDocument -Document $positive
    $crossInitial.PlanPayload['RetirementManifest'] = New-TestRetirementManifest
    Update-LivePlanEnvelopeHashes -Document $crossInitial
    Assert-Throws { Test-LiveSyncPlanSemantics -Document $crossInitial } '^live-plan-operation-kind-mismatch$' 'initial carrying RetirementManifest is rejected'

    $retirementHook = Copy-LivePlanDocument -Document $positive
    $retirementHook.PlanPayload.OperationKind = 'retirement'
    $retirementHook.PlanPayload.AuthorityStateIntent.LastOperationKind = 'retirement'
    $null = $retirementHook.PlanPayload.Remove('ProposedRootClaims')
    $null = $retirementHook.PlanPayload.Remove('RootClaimsHash')
    $retirementHook.PlanPayload['RetirementManifest'] = New-TestRetirementManifest
    $retirementHook.PlanPayload['TaskOverlayEvidence'] = [ordered]@{
        Action = 'replace'
        CandidateHash = New-LivePlanRepeatedHash -Character '8'
        CandidatePath = 'C:\fixture\overlay\task-overlay.json'
        CurrentHash = New-LivePlanRepeatedHash -Character '7'
        RemovalReview = $true
    }
    $retirementHook.PlanPayload.OrderedActions = @((New-TestPruneAction -Name 'retired-skill'))
    Update-LivePlanEnvelopeHashes -Document $retirementHook
    Assert-Throws { Test-LiveSyncPlanSemantics -Document $retirementHook } '^live-plan-operation-kind-mismatch$' 'retirement carrying hook TaskOverlayEvidence is rejected'

    $controllerReceipt = Copy-LivePlanDocument -Document $controllerDocument
    $controllerReceipt.PlanPayload.AuthorityStateIntent['ReceiptId'] = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'
    Update-LivePlanEnvelopeHashes -Document $controllerReceipt
    Assert-Throws { Test-LiveSyncPlanSemantics -Document $controllerReceipt } '^live-plan-schema-unsupported$' 'controller-transition carrying ReceiptId is rejected'

    $controllerLiveAction = Copy-LivePlanDocument -Document $controllerDocument
    $controllerLiveAction.PlanPayload.OrderedActions = @(
        [ordered]@{
            Action = 'add'
            LiveHash = $null
            Name = 'brainstorming'
            Order = 0
            Platform = 'Claude'
            SourceHash = New-LivePlanRepeatedHash -Character '8'
        }
    )
    Update-LivePlanEnvelopeHashes -Document $controllerLiveAction
    Assert-Throws { Test-LiveSyncPlanSemantics -Document $controllerLiveAction } '^live-plan-operation-kind-mismatch$' 'controller-transition carrying a live add action is rejected'

    $repairCorruptMarker = Copy-LivePlanDocument -Document $positive
    $repairCorruptMarker.PlanPayload.OperationKind = 'repair-adopt'
    $repairCorruptMarker.PlanPayload.Generator = 'tests/helpers/sealed-live-plan-fixture.ps1'
    $repairCorruptMarker.PlanPayload.AuthorityStateIntent.LastOperationKind = 'repair-adopt'
    $null = $repairCorruptMarker.PlanPayload.Remove('ProposedRootClaims')
    $null = $repairCorruptMarker.PlanPayload.Remove('RootClaimsHash')
    $repairCorruptMarker.PlanPayload['StateEvidence'] = [ordered]@{
        Kind = 'CORRUPT'
        Marker = $true
        Path = 'C:\fixture\control\current-env.json'
        PreimageHash = New-LivePlanRepeatedHash -Character '6'
        RawHash = New-LivePlanRepeatedHash -Character '5'
    }
    Update-LivePlanEnvelopeHashes -Document $repairCorruptMarker
    Assert-Throws { Test-LiveSyncPlanSemantics -Document $repairCorruptMarker } '^live-plan-operation-kind-mismatch$' 'repair-adopt CORRUPT evidence carrying MISSING Marker is rejected'

    $repairMissingPath = Copy-LivePlanDocument -Document $positive
    $repairMissingPath.PlanPayload.OperationKind = 'repair-adopt'
    $repairMissingPath.PlanPayload.Generator = 'tests/helpers/sealed-live-plan-fixture.ps1'
    $repairMissingPath.PlanPayload.AuthorityStateIntent.LastOperationKind = 'repair-adopt'
    $null = $repairMissingPath.PlanPayload.Remove('ProposedRootClaims')
    $null = $repairMissingPath.PlanPayload.Remove('RootClaimsHash')
    $repairMissingPath.PlanPayload['StateEvidence'] = [ordered]@{
        Kind = 'MISSING'
        Marker = $true
        Path = 'C:\fixture\control\current-env.json'
        RawHash = New-LivePlanRepeatedHash -Character '5'
    }
    Update-LivePlanEnvelopeHashes -Document $repairMissingPath
    Assert-Throws { Test-LiveSyncPlanSemantics -Document $repairMissingPath } '^live-plan-operation-kind-mismatch$' 'repair-adopt MISSING evidence carrying Path/hash is rejected'

    $repairLegacy = Copy-LivePlanDocument -Document $positive
    $repairLegacy.PlanPayload.OperationKind = 'repair-adopt'
    $repairLegacy.PlanPayload.Generator = 'tests/helpers/sealed-live-plan-fixture.ps1'
    $repairLegacy.PlanPayload.AuthorityStateIntent.LastOperationKind = 'repair-adopt'
    $null = $repairLegacy.PlanPayload.Remove('ProposedRootClaims')
    $null = $repairLegacy.PlanPayload.Remove('RootClaimsHash')
    $repairLegacy.PlanPayload['StateEvidence'] = [ordered]@{
        Kind = 'MISSING'
        Marker = $true
    }
    $repairLegacy.PlanPayload['LegacyEvidence'] = [ordered]@{ Status = 'UNTRUSTED' }
    Update-LivePlanEnvelopeHashes -Document $repairLegacy
    Assert-Throws { Test-LiveSyncPlanSemantics -Document $repairLegacy } '^live-plan-operation-kind-mismatch$' 'repair-adopt carrying adopt LegacyEvidence is rejected'

    $retirementConflict = Copy-LivePlanDocument -Document $positive
    $retirementConflict.PlanPayload.OperationKind = 'retirement'
    $retirementConflict.PlanPayload.AuthorityStateIntent.LastOperationKind = 'retirement'
    $null = $retirementConflict.PlanPayload.Remove('ProposedRootClaims')
    $null = $retirementConflict.PlanPayload.Remove('RootClaimsHash')
    $retirementConflict.PlanPayload['RetirementManifest'] = New-TestRetirementManifest -ConflictName 'brainstorming' -SafeName 'brainstorming'
    $retirementConflict.PlanPayload.OrderedActions = @((New-TestPruneAction -Name 'brainstorming'))
    Update-LivePlanEnvelopeHashes -Document $retirementConflict
    Assert-Throws { Test-LiveSyncPlanSemantics -Document $retirementConflict } '^retirement-selection-conflict$' 'retirement target in Postset Skills is rejected'
}
finally {
    $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT = $previousRoot
    $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_PATH = $previousPath
    $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_TOKEN = $previousCapability
    if ($null -ne $capability) {
        $capability.Stream.Dispose()
        Remove-Item -LiteralPath $capability.Path -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $sandboxRoot) {
        Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

    Write-Host '[live plan immutable write and five-step]'

    $writeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('live-plan-write-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $writeRoot | Out-Null
    $writePlanPath = Join-Path $writeRoot 'sync-plan.json'
    $fixtureDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path $RepoRoot 'tests/fixtures/artifacts/sync-plan.valid.json')))

    . (Join-Path $RepoRoot 'scripts/harness-env-common.ps1')
    $writeMaterialization = Join-Path $writeRoot 'sync-plan.materialization'
    Invoke-HarnessEnvMaterialization -Name 'full' -Destination $writeMaterialization
    $writeEnvBuildPath = Join-Path $writeMaterialization 'env-build.json'
    $writeEnvLockPath = Join-Path $writeMaterialization 'env.lock.json'
    $writeEnvBuildBytes = [System.IO.File]::ReadAllBytes($writeEnvBuildPath)
    $writeEnvLockBytes = [System.IO.File]::ReadAllBytes($writeEnvLockPath)
    $writeEnvBuildHash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($writeEnvBuildBytes)).ToLowerInvariant()
    $writeEnvLockHash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($writeEnvLockBytes)).ToLowerInvariant()
    $writeEnvBuildDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($writeEnvBuildPath))
    $writeMaterializationHash = Get-HarnessEnvMaterializationHash -Document $writeEnvBuildDocument

    $payload = $fixtureDocument['PlanPayload']
    $fixtureIdentity = [string] $payload['EnvironmentMaterializationRoot']['Identity']
    $payload['EnvironmentMaterializationRoot'] = [ordered]@{
        Path = [System.IO.Path]::GetFullPath($writeMaterialization)
        Identity = $fixtureIdentity
        EnvBuildPath = $writeEnvBuildPath
        EnvBuildHash = $writeEnvBuildHash
        EnvLockPath = $writeEnvLockPath
        EnvLockHash = $writeEnvLockHash
        MaterializationHash = $writeMaterializationHash
    }
    $fixtureDocument['PlanHash'] = Get-PlanHash -PlanPayload $payload
    $fixtureDocument['DocumentHash'] = Get-DocumentHash -Document $fixtureDocument

    Write-LiveSyncPlan -Path $writePlanPath -Document $fixtureDocument
    Assert (Test-Path -LiteralPath $writePlanPath -PathType Leaf) 'the immutable write creates the plan file'
    try { Write-LiveSyncPlan -Path $writePlanPath -Document $fixtureDocument; Assert $false 'second write on the same path is rejected' } catch { Assert ($_.Exception.Message -ceq 'live-plan-path-collision') 'second write on the same path fails with the collision token' }
    $roundTripped = Read-LiveSyncPlan -Path $writePlanPath
    Assert ((Get-SemanticJsonHash -InputObject $roundTripped) -ceq (Get-SemanticJsonHash -InputObject $fixtureDocument)) 'the written plan round-trips byte-equivalent'
    $null = Assert-LiveSyncPlanDocumentIntegrity -Document $roundTripped
    Assert $true 'an untouched plan passes document integrity'
    $tampered = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($writePlanPath))
    $tampered['PlanHash'] = ('f' * 64)
    try { Assert-LiveSyncPlanDocumentIntegrity -Document $tampered; Assert $false 'a tampered envelope hash fails integrity' } catch { Assert ($_.Exception.Message -ceq 'live-plan-hash-mismatch') 'a tampered envelope hash fails with the hash-mismatch token' }

    $null = Assert-LiveSyncPlanCurrent -Document $roundTripped -MaterializationDirectory $writeMaterialization
    Assert $true 'an unchanged bound materialization passes the currency gate'
    $driftedBuildDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($writeEnvBuildPath))
    $driftedBuildDocument['MaterializedRoots'][0]['FileCount'] = [long] $driftedBuildDocument['MaterializedRoots'][0]['FileCount'] + 1L
    [System.IO.File]::WriteAllBytes($writeEnvBuildPath, [byte[]] (ConvertTo-SemanticJsonBytes -InputObject $driftedBuildDocument))
    try { Assert-LiveSyncPlanCurrent -Document $roundTripped -MaterializationDirectory $writeMaterialization; Assert $false 'a drifted materialization fails the currency gate' } catch { Assert ($_.Exception.Message -ceq 'live-plan-hash-mismatch') 'a drifted materialization fails with the hash-mismatch token' }
    [System.IO.File]::WriteAllBytes($writeEnvBuildPath, $writeEnvBuildBytes)

    $null = Assert-LiveSyncPlanSelectionContext -Document $roundTripped -ExpectedOperationKind 'initial' -ExpectedEnvironmentName 'full'
    Assert $true 'a matching selection context passes'
    try { Assert-LiveSyncPlanSelectionContext -Document $roundTripped -ExpectedOperationKind 'retirement' -ExpectedEnvironmentName $null; Assert $false 'a mismatched operation kind fails selection' } catch { Assert ($_.Exception.Message -ceq 'live-plan-selection-mismatch') 'a mismatched operation kind fails with the selection token' }

    $null = Assert-LiveSyncPlanDocumentHashNotConsumed -Document $roundTripped -TerminalEvidence $null
    Assert $true 'an empty terminal evidence passes the consumption gate'
    try { Assert-LiveSyncPlanDocumentHashNotConsumed -Document $roundTripped -TerminalEvidence ([ordered]@{ [string] $roundTripped['DocumentHash'] = 'committed' }); Assert $false 'a consumed document hash fails the gate' } catch { Assert ($_.Exception.Message -ceq 'live-plan-consumed') 'a consumed document hash fails with the consumed token' }

    Remove-Item -LiteralPath $writeRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Live plan contract tests: PASS ($script:pass)"
