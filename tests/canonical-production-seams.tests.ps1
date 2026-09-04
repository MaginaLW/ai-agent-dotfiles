#requires -Version 7.0
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path

$script:pass=0
$script:fail=0
function Assert-TestCondition {
    param([bool]$Condition,[string]$Message)
    if($Condition){$script:pass++;Write-Host "  PASS  $Message" -ForegroundColor Green}
    else{$script:fail++;Write-Host "  FAIL  $Message" -ForegroundColor Red}
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($Text))).ToLowerInvariant()
}

function Get-OwningFunctionDefinition {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)
    $cursor=$Node.Parent
    while($null -ne $cursor){
        if($cursor -is [Management.Automation.Language.FunctionDefinitionAst]){return $cursor}
        $cursor=$cursor.Parent
    }
    return $null
}

function Get-NormalizedStaticCommandName {
    param(
        [AllowNull()][string]$CommandName,
        [Parameter(Mandatory)][hashtable]$AliasMap,
        [Parameter(Mandatory)][ref]$QualificationViolation
    )

    $QualificationViolation.Value=$null
    if([string]::IsNullOrEmpty($CommandName)){return $null}
    $normalized=$CommandName
    if($normalized.Contains([char]47) -or $normalized.Contains([char]92) -or
        $normalized.Contains([char]58)){
        $QualificationViolation.Value="qualified or path command is not reviewed: $CommandName"
        return $normalized
    }
    if($AliasMap.ContainsKey($normalized)){return [string]$AliasMap[$normalized]}
    return $normalized
}

function Get-NormalizedStaticFunctionName {
    param([Parameter(Mandatory)][string]$FunctionName)

    $normalized=$FunctionName
    $scopeSeparator=$normalized.IndexOf([char]58)
    if($scopeSeparator -gt 0 -and $scopeSeparator -lt $normalized.Length-1){
        $scopeName=$normalized.Substring(0,$scopeSeparator)
        if($scopeName -iin @('global','script','local','private')){
            $normalized=$normalized.Substring($scopeSeparator+1)
        }
    }
    return $normalized
}

function Get-MinimalTopLevelStatementAst {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)

    $cursor=$Node
    while($null -ne $cursor.Parent){
        if($cursor.Parent -is [Management.Automation.Language.NamedBlockAst]){return $cursor}
        $cursor=$cursor.Parent
    }
    return $null
}

function Get-ScriptTopLevelStatementBinding {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)

    $statement=Get-MinimalTopLevelStatementAst -Node $Node
    if($null -eq $statement -or $statement.Parent -isnot [Management.Automation.Language.NamedBlockAst] -or
        $statement.Parent.Parent -isnot [Management.Automation.Language.ScriptBlockAst] -or
        $null -ne $statement.Parent.Parent.Parent){return $null}
    $statements=@($statement.Parent.Statements)
    for($index=0;$index -lt $statements.Count;$index++){
        if([object]::ReferenceEquals($statements[$index],$statement)){
            return [pscustomobject]@{Ast=$statement;Ordinal=[long]$index}
        }
    }
    return $null
}

function Test-DirectScriptTopLevelFunctionDefinition {
    param([Parameter(Mandatory)][Management.Automation.Language.FunctionDefinitionAst]$Function)

    $binding=Get-ScriptTopLevelStatementBinding -Node $Function
    return $null -ne $binding -and [object]::ReferenceEquals($binding.Ast,$Function)
}

function Get-DirectFunctionNodes {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.FunctionDefinitionAst]$Function,
        [Parameter(Mandatory)][scriptblock]$Predicate
    )
    return @($Function.Body.FindAll($Predicate,$true) | Where-Object {
        (Get-OwningFunctionDefinition -Node $_) -eq $Function
    })
}

function New-ProductionSourceModels {
    param([Parameter(Mandatory)][string]$Root)
    $models=[Collections.Generic.List[object]]::new()
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -Recurse -File -Filter '*.ps1' | Sort-Object FullName)){
        $relative=[IO.Path]::GetRelativePath($Root,$file.FullName).Replace([char]92,[char]47)
        $models.Add([pscustomobject]@{RelativePath=$relative;Text=[IO.File]::ReadAllText($file.FullName)})
    }
    return @($models)
}

function Copy-SourceModelsWithOverride {
    param(
        [Parameter(Mandatory)][object[]]$Models,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Text
    )
    $result=[Collections.Generic.List[object]]::new()
    $replaced=$false
    foreach($model in $Models){
        if($model.RelativePath -ceq $RelativePath){
            $result.Add([pscustomobject]@{RelativePath=$RelativePath;Text=$Text})
            $replaced=$true
        } else {
            $result.Add([pscustomobject]@{RelativePath=[string]$model.RelativePath;Text=[string]$model.Text})
        }
    }
    if(-not $replaced){$result.Add([pscustomobject]@{RelativePath=$RelativePath;Text=$Text})}
    return @($result)
}

function Add-CallToFunctionSource {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$FunctionName,
        [Parameter(Mandatory)][string]$Call
    )
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Source,$FileName,[ref]$tokens,[ref]$errors)
    if(@($errors).Count -ne 0){throw "cannot mutate unparsable source: $FileName"}
    $definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $FunctionName},$true))
    if($definitions.Count -ne 1){throw "mutation root definition is not unique: $FunctionName"}
    $offset=$definitions[0].Body.Extent.EndOffset-1
    return $Source.Insert($offset,"`n    $Call`n")
}

$productionRoots=@(
    'Initialize-CanonicalRecoveryWorkspace'
    'Invoke-CanonicalParentDirectoryCreate'
    'Invoke-CanonicalDirectoryReplacement'
    'Invoke-CanonicalFileReplacement'
)

# Reviewed transitive closure from the four roots. Name and defining script are frozen.
$reviewedClosure=@(
    'Add-CanonicalJournalRecord|scripts/transaction-journal-common.ps1'
    'Assert-CanonicalJournalObservedEqual|scripts/transaction-journal-common.ps1'
    'Assert-CanonicalJournalObservedMatchesContract|scripts/transaction-journal-common.ps1'
    'Assert-CanonicalJournalRecordSemantics|scripts/transaction-journal-common.ps1'
    'Assert-CanonicalJournalSnapshotInventory|scripts/transaction-journal-common.ps1'
    'Assert-CanonicalJournalTargetTupleSemantics|scripts/transaction-journal-common.ps1'
    'Assert-CanonicalObservedStateEqual|scripts/canonical-mutation-common.ps1'
    'Assert-CanonicalPreparedTupleUnderLease|scripts/canonical-mutation-common.ps1'
    'Assert-CanonicalRecoveryOwnedPath|scripts/canonical-mutation-common.ps1'
    'Assert-CanonicalTransactionPreimageBarrier|scripts/canonical-mutation-common.ps1'
    'Assert-ExactJsonArtifactCapture|scripts/json-artifact-common.ps1'
    'Assert-NoReparseExistingChain|scripts/json-artifact-common.ps1'
    'Close-CanonicalJournalSnapshot|scripts/transaction-journal-common.ps1'
    'Close-CanonicalMutationParentLease|scripts/canonical-mutation-common.ps1'
    'Close-CanonicalRetainedTreeTraversal|scripts/canonical-mutation-common.ps1'
    'Close-HeldJsonSchemaCopy|scripts/json-artifact-common.ps1'
    'Close-PinnedToolLease|scripts/json-artifact-common.ps1'
    'Close-SafeDirectoryContainmentChain|scripts/safe-tree-walker.ps1'
    'Compare-CanonicalJournalNames|scripts/transaction-journal-common.ps1'
    'Compare-SafeContentTree|scripts/safe-tree-walker.ps1'
    'ConvertFrom-SemanticJson|scripts/semantic-json.ps1'
    'ConvertFrom-SemanticJsonElement|scripts/semantic-json.ps1'
    'ConvertTo-CanonicalPublishedJsonResult|scripts/transaction-journal-common.ps1'
    'ConvertTo-SafeRelativePath|scripts/safe-tree-walker.ps1'
    'ConvertTo-SemanticJsonBytes|scripts/semantic-json.ps1'
    'Copy-CanonicalFileCreateNew|scripts/canonical-mutation-common.ps1'
    'Copy-SafeTree|scripts/safe-tree-walker.ps1'
    'Get-CanonicalJournalEmptyDirectoryHash|scripts/transaction-journal-common.ps1'
    'Get-CanonicalJournalExpectedArtifactStates|scripts/transaction-journal-common.ps1'
    'Get-CanonicalJournalExpectedTransactionResultProjection|scripts/transaction-journal-common.ps1'
    'Get-CanonicalJournalResultProjection|scripts/transaction-journal-common.ps1'
    'Get-CanonicalJournalStateForAppend|scripts/transaction-journal-common.ps1'
    'Get-CanonicalJournalTargetId|scripts/transaction-journal-common.ps1'
    'Get-CanonicalMutationJournalLeaseLeaf|scripts/canonical-mutation-common.ps1'
    'Get-CanonicalObservedPathState|scripts/canonical-mutation-common.ps1'
    'Get-CanonicalRecoveryWorkspaceReconciliation|scripts/canonical-mutation-common.ps1'
    'Get-CanonicalRetainedDirectoryObservation|scripts/canonical-mutation-common.ps1'
    'Get-CanonicalTargetReconciliation|scripts/canonical-mutation-common.ps1'
    'Get-CanonicalTargetTuple|scripts/canonical-mutation-common.ps1'
    'Get-NoFollowRootEntryMarker|scripts/safe-tree-walker.ps1'
    'Get-PinnedToolCacheRoot|scripts/json-artifact-common.ps1'
    'Get-PinnedToolPaths|scripts/json-artifact-common.ps1'
    'Get-ProtectedReasonixRelativePaths|scripts/scan-input-common.ps1'
    'Get-SafeTreeSnapshot|scripts/safe-tree-walker.ps1'
    'Get-SafeTreeSnapshotInternal|scripts/safe-tree-walker.ps1'
    'Open-SafeTreeRetainedTraversal|scripts/safe-tree-walker.ps1'
    'Get-SemanticJsonHash|scripts/semantic-json.ps1'
    'Initialize-CanonicalRecoveryWorkspace|scripts/canonical-mutation-common.ps1'
    'Initialize-CanonicalTargetPreimage|scripts/canonical-mutation-common.ps1'
    'Invoke-CanonicalContractSchemaValidation|scripts/transaction-journal-common.ps1'
    'Invoke-CanonicalDirectoryReplacement|scripts/canonical-mutation-common.ps1'
    'Invoke-CanonicalFileReplacement|scripts/canonical-mutation-common.ps1'
    'Invoke-CanonicalJournalSchemaBatchValidation|scripts/transaction-journal-common.ps1'
    'Invoke-CanonicalParentDirectoryCreate|scripts/canonical-mutation-common.ps1'
    'Invoke-FixedJsonSchemaValidationBytes|scripts/json-artifact-common.ps1'
    'Invoke-PinnedJsonSchemaValidatorFiles|scripts/json-artifact-common.ps1'
    'Invoke-PinnedJsonSchemaValidatorProcess|scripts/json-artifact-common.ps1'
    'Invoke-PinnedToolProcess|scripts/json-artifact-common.ps1'
    'New-CanonicalPreparedJsonArtifact|scripts/transaction-journal-common.ps1'
    'New-CanonicalTargetRecordData|scripts/canonical-mutation-common.ps1'
    'New-HeldJsonSchemaCopy|scripts/json-artifact-common.ps1'
    'Open-CanonicalJournalSnapshot|scripts/transaction-journal-common.ps1'
    'Open-CanonicalMutationParentLease|scripts/canonical-mutation-common.ps1'
    'Open-PinnedToolLease|scripts/json-artifact-common.ps1'
    'Open-SafeDirectoryContainmentChain|scripts/safe-tree-walker.ps1'
    'Open-SafeExistingDirectoryContainmentChain|scripts/safe-tree-walker.ps1'
    'Publish-CanonicalHeldJson|scripts/transaction-journal-common.ps1'
    'Publish-CanonicalPreparedJsonArtifact|scripts/transaction-journal-common.ps1'
    'Read-CanonicalHeldJsonContractFile|scripts/transaction-journal-common.ps1'
    'Read-ExactJsonArtifactCapture|scripts/json-artifact-common.ps1'
    'Resolve-PrivateArtifactPath|scripts/json-artifact-common.ps1'
    'Test-CanonicalDataField|scripts/canonical-mutation-common.ps1'
    'Test-CanonicalJournalChain|scripts/transaction-journal-common.ps1'
    'Test-CanonicalJournalObservedMissing|scripts/transaction-journal-common.ps1'
    'Test-CanonicalObservedMatchesContractState|scripts/canonical-mutation-common.ps1'
    'Test-CanonicalObservedStateEqual|scripts/canonical-mutation-common.ps1'
    'Test-CanonicalTargetTupleEqual|scripts/canonical-mutation-common.ps1'
    'Test-CanonicalUnpreparedTargetTuple|scripts/canonical-mutation-common.ps1'
    'Test-PathEqualsOrInside|scripts/json-artifact-common.ps1'
    'Test-PathInsideRoot|scripts/scan-input-common.ps1'
    'Test-PinnedToolVersion|scripts/json-artifact-common.ps1'
    'Test-RepositoryJsonSchema|scripts/json-artifact-common.ps1'
    'Test-SafePathInsideRoot|scripts/safe-tree-walker.ps1'
    'Test-SafeTreeEntryExcluded|scripts/safe-tree-walker.ps1'
    'Visit-SchemaNode|scripts/json-artifact-common.ps1'
    'Write-SemanticJsonValue|scripts/semantic-json.ps1'
) | Sort-Object

$reviewedBuiltInLeaves=@(
    'Add-Member','Compare-Object','ForEach-Object','Join-Path','Out-Null','Resolve-Path',
    'Select-Object','Sort-Object','Split-Path','Test-Path','Where-Object','Write-Output'
)
$reviewedExternalLeaves=@('git')

# Digest input is category|owner|file|exact-AST-extent; line numbers are intentionally excluded.
$reviewedExceptionInventory=@(
    'CommandShadowDefinition|Test-RepositoryJsonSchema|scripts/json-artifact-common.ps1|68f6ead51cad3924b15802baf483ca3bbc4e5867d64512a5bfc24fea17523406'
    'DynamicInvocation|Test-SafeTreeEntryExcluded|scripts/safe-tree-walker.ps1|855a9bb8c5bc3a6d4ef3842ab3d126b6e23e2da064b873505f1254d49b5c82bb'
    'ScriptBlockParameter|Copy-SafeTree|scripts/safe-tree-walker.ps1|4c5689806e64abdf7b6627566c31f36a6929720a13be5f4bd198cfb18ea51da5'
    'ScriptBlockParameter|Get-SafeTreeSnapshot|scripts/safe-tree-walker.ps1|77b35fa8987cb325f6a580336e0b1ef423e563309592f363d447bb81d200dd45'
    'ScriptBlockParameter|Get-SafeTreeSnapshotInternal|scripts/safe-tree-walker.ps1|ef8dd7f405f61d69f3a59a95465902333c85712ea415df5ba47c22c26ba3722c'
    'ScriptBlockParameter|Open-SafeTreeRetainedTraversal|scripts/safe-tree-walker.ps1|ad9aa49e06084082906d3b0e94f20c6148ccb80dbe01ee7ff0a2b3f0993ef733'
    'ScriptBlockParameter|Test-SafeTreeEntryExcluded|scripts/safe-tree-walker.ps1|b8e0f3588dbcaeb83d768ba05a9e8ca7b61f7d9a7eac2e59e1de6362b57bf3f8'
) | Sort-Object

$reviewedAllScriptsDynamicCommandDigest='8a3241fcb1e06aee535e2d73906d556522c041ad318023bcf9447f7f2fd745b6'
$reviewedAllScriptsReflectionSensitiveSiteCount=12833
$reviewedAllScriptsReflectionSensitiveDigest='07e59a175a9ef3f5ba58efae123fbaee1d21b2213b6604c150fc9e30ac6657d5'
$reviewedStaticCommandAliasMap=@{
    '%'='ForEach-Object';'?'='Where-Object';compare='Compare-Object';diff='Compare-Object'
    fc='Format-Custom';fl='Format-List';foreach='ForEach-Object';ft='Format-Table';fw='Format-Wide'
    gcm='Get-Command';gm='Get-Member';group='Group-Object';icm='Invoke-Command';iex='Invoke-Expression'
    ipal='Import-Alias';ipmo='Import-Module';measure='Measure-Object';nal='New-Alias';nmo='New-Module'
    sal='Set-Alias';select='Select-Object';sort='Sort-Object';where='Where-Object'
}
$reflectionSensitiveCommandNames=@(
    'Add-Type','Get-Command','Get-Member','Import-Alias','Import-Module','Invoke-Command','Invoke-Expression',
    'New-Alias','New-Module','New-Object','Remove-Alias','Set-Alias'
)
$memberDispatchCommandNames=@(
    '%','?','compare','ForEach-Object','Format-Custom','Format-List','Format-Table','Format-Wide',
    'group','Group-Object','measure','Measure-Object','select','Select-Object','sort','Sort-Object',
    'Where-Object'
)
$memberDispatchParameterNames=@('MemberName','ArgumentList','ExpandProperty','Property')
$reviewedSensitiveIssuerTypeNames=@(
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer',
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer',
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer'
)
$reviewedSensitiveIssuerTypeShortNames=@($reviewedSensitiveIssuerTypeNames | ForEach-Object {@(([string]$_ -split '\.'))[-1]})
$reviewedIssuerInvocationInventory=@(
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|<script>|InitializeExact'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|InvokeProbeExact'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|IsExactIssuerToken'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|MatchesProbeExact'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldFixedInfrastructureCapabilityCapture|InvokeRawExact'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldFixedInfrastructureCapabilityCapture|MatchesRawExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|<script>|InitializeObservationExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation|AssertObservationExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation|CloseObservationExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Open-SealedHeldObservationCleanupLedger|OpenObservationCleanupLedgerExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Register-SealedHeldObservationCleanupLedgerObservation|RegisterObservationCleanupLedgerEntryExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Assert-SealedHeldObservationCleanupLedger|AssertObservationCleanupLedgerExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Close-SealedHeldObservationCleanupLedgerObservation|CloseObservationCleanupLedgerEntryExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Close-SealedHeldObservationCleanupLedger|CloseObservationCleanupLedgerExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation|OpenObservationExact'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Open-SealedHeldObservationLifecycle|CloseObservationExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|<script>|InitializeExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|AbandonOpenExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|BeginOpenExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|ClaimResourceSetExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|ClaimResourceSetExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|ClaimResourceSetExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|ClaimResourceSetExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|IssueExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|OpenLiveSetExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|OpenTargetExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|OpenTargetExact'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|OpenTargetExact'
) | Sort-Object -CaseSensitive
$reviewedIssuerOwnerBindingInventory=@(
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|<script>|InitializeExact|PipelineAst|eae9e74e5946ecc06cabb6ca8591e78bc089c0a17701e163daf2286439879f83'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|InvokeProbeExact|FunctionDefinitionAst|3e5dab7a9cdcec7efeb0c4b7da3c52288562cc9db12552ae007e9fc9d22abd44'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|IsExactIssuerToken|FunctionDefinitionAst|3e5dab7a9cdcec7efeb0c4b7da3c52288562cc9db12552ae007e9fc9d22abd44'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|MatchesProbeExact|FunctionDefinitionAst|3e5dab7a9cdcec7efeb0c4b7da3c52288562cc9db12552ae007e9fc9d22abd44'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldFixedInfrastructureCapabilityCapture|InvokeRawExact|FunctionDefinitionAst|78426ba022cd98f75c1963c5b673f15ed218eff76536f1ffbc9d90d6ec304786'
    'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldFixedInfrastructureCapabilityCapture|MatchesRawExact|FunctionDefinitionAst|78426ba022cd98f75c1963c5b673f15ed218eff76536f1ffbc9d90d6ec304786'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|<script>|InitializeObservationExact|TryStatementAst|af9868225f932a77a9bd428651be606838a5a547d61b7194c8036d9948658fd2'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation|AssertObservationExact|FunctionDefinitionAst|041760c7165ef82dbc11707dccab1b0b3913cd2ebde5f9feafa7845de8f17b8c'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation|CloseObservationExact|FunctionDefinitionAst|ae2f1357bbe077c65750bdf09894292e4e4862fd4800b217688e00b37e929eba'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Open-SealedHeldObservationCleanupLedger|OpenObservationCleanupLedgerExact|FunctionDefinitionAst|fc1eb42cff88b263bf3894263f83909c916c9c22267f16f46c112096982ba6c4'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Register-SealedHeldObservationCleanupLedgerObservation|RegisterObservationCleanupLedgerEntryExact|FunctionDefinitionAst|7ce785104f998a4ea96444d930bcb764e66d3d331f04a99156516cd018f1e187'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Assert-SealedHeldObservationCleanupLedger|AssertObservationCleanupLedgerExact|FunctionDefinitionAst|e5f48172b933a1f0e5de77892e9c7f8fa56fbbafef24c8ea698674e45403ce6a'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Close-SealedHeldObservationCleanupLedgerObservation|CloseObservationCleanupLedgerEntryExact|FunctionDefinitionAst|7deed77152ac90744a83a11adf04cc619f51c0ab579816df21918b50ae8ee080'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Close-SealedHeldObservationCleanupLedger|CloseObservationCleanupLedgerExact|FunctionDefinitionAst|dd313b2cc6249b65bc95fcfc2f5c8dcfa00765d16c5c4a7d7a194c906d7329ec'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation|OpenObservationExact|FunctionDefinitionAst|545e31d37f2f4b27b0a363c7d0781771e7f254d823ba9f1df7dcbe9a8a8501f0'
    'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/root-claims-registry-common.ps1|Open-SealedHeldObservationLifecycle|CloseObservationExact|FunctionDefinitionAst|451449d7df35a1950c099aa0da20dc18aeaf9258666ae93ead06900e7795df17'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|<script>|InitializeExact|TryStatementAst|f97d9cd4e5d5f884cbae847a5e5d579b0976823fb8e19888cf2f934c5570c46d'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|AbandonOpenExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|BeginOpenExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|ClaimResourceSetExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|ClaimResourceSetExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|ClaimResourceSetExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|ClaimResourceSetExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|IssueExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|OpenLiveSetExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|OpenTargetExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|OpenTargetExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
    'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|OpenTargetExact|FunctionDefinitionAst|4e1f7c393210a9ce0fb55547d5c2bb3bf8033408829da7ee625492866d8bd86a'
) | Sort-Object -CaseSensitive

$testsOnlyReferencePattern='(?ix)(?:
    canonical-reviewed-mutation-engine(?:\.ps1)? |
    tests[\\/]helpers[\\/]canonical-reviewed-mutation-engine\.ps1 |
    AiAgentDotfilesTests\. |
    \b(?:
        SealedMutationCheckpoint|SealedMutationPrimitiveVariant|SealedMutationStageSelector|
        SealedMutationPublicationTicket|SealedMutationStageCoordinator|SealedMutationInvocationContext|
        SealedStageRootLease|SealedStageFileLease|SealedMutationBehaviorTransport|
        Invoke-SealedMutationReach|Initialize-SealedCanonicalRecoveryWorkspace|
        Invoke-SealedCanonicalParentDirectoryCreate|Invoke-SealedCanonicalDirectoryReplacement|
        Invoke-SealedCanonicalFileReplacement
    )\b
)'

function Invoke-ProductionSeamAnalysis {
    param([Parameter(Mandatory)][object[]]$SourceModels)

    $parseFailures=[Collections.Generic.List[string]]::new()
    $forbiddenReferences=[Collections.Generic.List[string]]::new()
    $resolutionFailures=[Collections.Generic.List[string]]::new()
    $fixedCapabilityBoundaryViolations=[Collections.Generic.List[string]]::new()
    $fixedObservationBoundaryViolations=[Collections.Generic.List[string]]::new()
    $rawCapabilityAllowedCallers=[Collections.Generic.List[string]]::new()
    $probeCapabilityAllowedCallers=[Collections.Generic.List[string]]::new()
    $routeCaptureIssuerAllowedCallers=[Collections.Generic.List[string]]::new()
    $validatorAllowedCallers=[Collections.Generic.List[string]]::new()
    $observationOpenAllowedCallers=[Collections.Generic.List[string]]::new()
    $observationAssertAllowedCallers=[Collections.Generic.List[string]]::new()
    $ledgerOpenAllowedCallers=[Collections.Generic.List[string]]::new()
    $ledgerRegisterAllowedCallers=[Collections.Generic.List[string]]::new()
    $ledgerAssertAllowedCallers=[Collections.Generic.List[string]]::new()
    $ledgerCloseObservationAllowedCallers=[Collections.Generic.List[string]]::new()
    $ledgerCloseAllowedCallers=[Collections.Generic.List[string]]::new()
    $allScriptsDynamicCommandInventory=[Collections.Generic.List[string]]::new()
    $allScriptsDynamicCommandViolations=[Collections.Generic.List[string]]::new()
    $allScriptsCommandQualificationViolations=[Collections.Generic.List[string]]::new()
    $allScriptsReflectionSensitiveInventory=[Collections.Generic.List[string]]::new()
    $allScriptsReflectionSensitiveViolations=[Collections.Generic.List[string]]::new()
    $allScriptsUsingStatementInventory=[Collections.Generic.List[string]]::new()
    $allScriptsUsingStatementViolations=[Collections.Generic.List[string]]::new()
    $allScriptsTypeDefinitionInventory=[Collections.Generic.List[string]]::new()
    $allScriptsTypeDefinitionViolations=[Collections.Generic.List[string]]::new()
    $allScriptsScriptBlockFunctionDefinitionInventory=[Collections.Generic.List[string]]::new()
    $allScriptsScriptBlockFunctionDefinitionViolations=[Collections.Generic.List[string]]::new()
    $allScriptsLiteralProviderDriveTokenInventory=[Collections.Generic.List[string]]::new()
    $allScriptsLiteralProviderDriveTokenViolations=[Collections.Generic.List[string]]::new()
    $issuerInvocationInventory=[Collections.Generic.List[string]]::new()
    $issuerOwnerBindingInventory=[Collections.Generic.List[string]]::new()
    $definitions=@{}

    foreach($model in $SourceModels){
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput([string]$model.Text,[string]$model.RelativePath,[ref]$tokens,[ref]$parseErrors)
        foreach($parseError in @($parseErrors)){$parseFailures.Add("$($model.RelativePath):$($parseError.Message)")}
        foreach($match in [regex]::Matches([string]$model.Text,$testsOnlyReferencePattern)){$forbiddenReferences.Add("$($model.RelativePath):$($match.Value)")}
        # This zero baseline covers only literal provider-drive syntax. It scans every non-comment token and
        # explicitly recognizes drive-qualified Alias/Function VariableExpressionAst nodes. It supplements the
        # direct named CommandAst checks below; computed paths and general provider-mutator data flow are out of scope.
        $providerVariableRanges=[Collections.Generic.List[object]]::new()
        foreach($variableExpression in @($ast.FindAll({param($node)
            $node -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.VariablePath.IsDriveQualified -and
            [string]$node.VariablePath.DriveName -iin @('alias','function')
        },$true))){
            $providerVariableRanges.Add([pscustomobject]@{
                StartOffset=$variableExpression.Extent.StartOffset
                EndOffset=$variableExpression.Extent.EndOffset
            })
            $owner=Get-OwningFunctionDefinition -Node $variableExpression
            $ownerName=if($null -eq $owner){'<script>'}else{[string]$owner.Name}
            $allScriptsLiteralProviderDriveTokenInventory.Add(
                "VariableExpressionAst|$($model.RelativePath)|$ownerName|$($variableExpression.Extent.Text)")
        }
        foreach($token in @($tokens)){
            if($token.Kind -eq [Management.Automation.Language.TokenKind]::Comment){continue}
            foreach($providerDriveMatch in [regex]::Matches(
                [string]$token.Text,
                '(?i)(?<![A-Za-z0-9_])(?:Alias|Function):')){
                $matchStart=$token.Extent.StartOffset+$providerDriveMatch.Index
                $matchEnd=$matchStart+$providerDriveMatch.Length
                $coveredByVariableAst=@($providerVariableRanges | Where-Object {
                    $matchStart -ge $_.StartOffset -and $matchEnd -le $_.EndOffset
                }).Count -gt 0
                if($coveredByVariableAst){continue}
                $allScriptsLiteralProviderDriveTokenInventory.Add(
                    "Token|$($model.RelativePath)|$($token.Kind)|$matchStart|$($token.Text)")
            }
        }
        foreach($command in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))){
            $owner=Get-OwningFunctionDefinition -Node $command
            $ownerName=if($null -eq $owner){'<script>'}else{[string]$owner.Name}
            $qualificationViolation=$null
            $commandName=Get-NormalizedStaticCommandName -CommandName ($command.GetCommandName()) `
                -AliasMap $reviewedStaticCommandAliasMap `
                -QualificationViolation ([ref]$qualificationViolation)
            if($null -ne $qualificationViolation){
                $allScriptsCommandQualificationViolations.Add(
                    "$($model.RelativePath)|$ownerName|$qualificationViolation")
            }
            if($null -eq $commandName){
                $allScriptsDynamicCommandInventory.Add("$($model.RelativePath)|$ownerName|$($command.Extent.Text)")
                continue
            }
            $hasMemberDispatchParameter=@($command.CommandElements | Where-Object {
                if($_ -isnot [Management.Automation.Language.CommandParameterAst]){return $false}
                $observedParameter=[string]$_.ParameterName
                foreach($dispatchParameter in $memberDispatchParameterNames){
                    if($dispatchParameter.StartsWith($observedParameter,[StringComparison]::OrdinalIgnoreCase)){return $true}
                }
                return $false
            }).Count -gt 0
            if($commandName -iin $reflectionSensitiveCommandNames -or $commandName -iin $memberDispatchCommandNames -or
                $hasMemberDispatchParameter){
                $allScriptsReflectionSensitiveInventory.Add("Command|$($model.RelativePath)|$ownerName|$($command.Extent.Text)")
            }
            if($commandName -ieq 'Invoke-SealedHeldFixedInfrastructureCapabilityCapture'){
                $fixedCapabilityBoundaryViolations.Add("fixed capability capture caller: $($model.RelativePath):$ownerName")
            }
            if($commandName -ieq 'Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation'){
                $fixedObservationBoundaryViolations.Add("held current-route fixed-infrastructure observation caller: $($model.RelativePath):$($ownerName):$commandName")
            }
            elseif($commandName -ieq 'Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation'){
                if([string]$model.RelativePath -ceq 'scripts/root-claims-registry-common.ps1' -and $null -ne $owner -and
                    [string]$owner.Name -ceq 'Open-SealedHeldObservationLifecycle'){
                    $observationOpenAllowedCallers.Add("$($model.RelativePath):$ownerName")
                }
                else{$fixedObservationBoundaryViolations.Add("held current-route fixed-infrastructure observation caller: $($model.RelativePath):$($ownerName):$commandName")}
            }
            elseif($commandName -ieq 'Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation'){
                if([string]$model.RelativePath -ceq 'scripts/root-claims-registry-common.ps1' -and $null -ne $owner -and
                    ([string]$owner.Name -ceq 'Open-SealedHeldObservationLifecycle' -or
                    [string]$owner.Name -ceq 'Assert-SealedHeldObservationLifecycle')){
                    $observationAssertAllowedCallers.Add("$($model.RelativePath):$ownerName")
                }
                else{$fixedObservationBoundaryViolations.Add("held current-route fixed-infrastructure observation caller: $($model.RelativePath):$($ownerName):$commandName")}
            }
            if($commandName -iin @(
                'Open-SealedHeldObservationLifecycle',
                'Assert-SealedHeldObservationLifecycle',
                'Close-SealedHeldObservationLifecycle')){
                $fixedObservationBoundaryViolations.Add("held observation lifecycle caller: $($model.RelativePath):$($ownerName):$commandName")
            }
            if($commandName -ieq 'Open-SealedHeldObservationCleanupLedger'){
                if([string]$model.RelativePath -ceq 'scripts/root-claims-registry-common.ps1' -and $null -ne $owner -and
                    [string]$owner.Name -ceq 'Open-SealedHeldObservationLifecycle'){
                    $ledgerOpenAllowedCallers.Add("$($model.RelativePath):$ownerName")
                }
                else{$fixedObservationBoundaryViolations.Add("observation cleanup ledger caller: $($model.RelativePath):$($ownerName):$commandName")}
            }
            if($commandName -ieq 'Register-SealedHeldObservationCleanupLedgerObservation'){
                if([string]$model.RelativePath -ceq 'scripts/root-claims-registry-common.ps1' -and $null -ne $owner -and
                    [string]$owner.Name -ceq 'Open-SealedHeldObservationLifecycle'){
                    $ledgerRegisterAllowedCallers.Add("$($model.RelativePath):$ownerName")
                }
                else{$fixedObservationBoundaryViolations.Add("observation cleanup ledger caller: $($model.RelativePath):$($ownerName):$commandName")}
            }
            if($commandName -ieq 'Assert-SealedHeldObservationCleanupLedger'){
                if([string]$model.RelativePath -ceq 'scripts/root-claims-registry-common.ps1' -and $null -ne $owner -and
                    ([string]$owner.Name -ceq 'Open-SealedHeldObservationLifecycle' -or
                    [string]$owner.Name -ceq 'Assert-SealedHeldObservationLifecycle')){
                    $ledgerAssertAllowedCallers.Add("$($model.RelativePath):$ownerName")
                }
                else{$fixedObservationBoundaryViolations.Add("observation cleanup ledger caller: $($model.RelativePath):$($ownerName):$commandName")}
            }
            if($commandName -ieq 'Close-SealedHeldObservationCleanupLedgerObservation'){
                if([string]$model.RelativePath -ceq 'scripts/root-claims-registry-common.ps1' -and $null -ne $owner -and
                    ([string]$owner.Name -ceq 'Open-SealedHeldObservationLifecycle' -or
                    [string]$owner.Name -ceq 'Close-SealedHeldObservationLifecycle')){
                    $ledgerCloseObservationAllowedCallers.Add("$($model.RelativePath):$ownerName")
                }
                else{$fixedObservationBoundaryViolations.Add("observation cleanup ledger caller: $($model.RelativePath):$($ownerName):$commandName")}
            }
            if($commandName -ieq 'Close-SealedHeldObservationCleanupLedger'){
                if([string]$model.RelativePath -ceq 'scripts/root-claims-registry-common.ps1' -and $null -ne $owner -and
                    ([string]$owner.Name -ceq 'Open-SealedHeldObservationLifecycle' -or
                    [string]$owner.Name -ceq 'Close-SealedHeldObservationLifecycle')){
                    $ledgerCloseAllowedCallers.Add("$($model.RelativePath):$ownerName")
                }
                else{$fixedObservationBoundaryViolations.Add("observation cleanup ledger caller: $($model.RelativePath):$($ownerName):$commandName")}
            }
            if($commandName -ieq 'Invoke-SealedHeldCapabilityPreflight'){
                $fixedCapabilityBoundaryViolations.Add("dynamic raw capability preflight caller: $($model.RelativePath):$ownerName")
            }
            if($commandName -ieq 'Assert-SealedFixedInfrastructureCapabilityEvidenceExact'){
                if([string]$model.RelativePath -ceq 'scripts/root-claims-registry-common.ps1' -and $null -ne $owner -and
                    [string]$owner.Name -ceq 'Invoke-SealedHeldFixedInfrastructureCapabilityCapture'){
                    $validatorAllowedCallers.Add("$($model.RelativePath):$ownerName")
                }
                else{$fixedCapabilityBoundaryViolations.Add("fixed capability evidence validator caller: $($model.RelativePath):$ownerName")}
            }
        }
        foreach($memberExpression in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.MemberExpressionAst]},$true))){
            $owner=Get-OwningFunctionDefinition -Node $memberExpression
            $ownerName=if($null -eq $owner){'<script>'}else{[string]$owner.Name}
            $memberKind=if($memberExpression -is [Management.Automation.Language.InvokeMemberExpressionAst]){'InvokeMember'}else{'Member'}
            $allScriptsReflectionSensitiveInventory.Add(
                "$memberKind|$($model.RelativePath)|$ownerName|$([bool]$memberExpression.Static)|$($memberExpression.Extent.Text)")
        }
        foreach($usingStatement in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.UsingStatementAst]},$true))){
            $owner=Get-OwningFunctionDefinition -Node $usingStatement
            $ownerName=if($null -eq $owner){'<script>'}else{[string]$owner.Name}
            $allScriptsUsingStatementInventory.Add("$($model.RelativePath)|$ownerName|$($usingStatement.Extent.Text)")
        }
        foreach($typeDefinition in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.TypeDefinitionAst]},$true))){
            $owner=Get-OwningFunctionDefinition -Node $typeDefinition
            $ownerName=if($null -eq $owner){'<script>'}else{[string]$owner.Name}
            $allScriptsTypeDefinitionInventory.Add("$($model.RelativePath)|$ownerName|$($typeDefinition.Extent.Text)")
        }
        foreach($typeExpression in @($ast.FindAll({param($node)
            if($node -isnot [Management.Automation.Language.TypeExpressionAst]){return $false}
            $typeName=[string]$node.TypeName.FullName
            return $typeName -imatch '^(?:System\.)?(?:Type|AppDomain|Activator)$' -or
                $typeName -imatch '^(?:System\.)?Reflection\.' -or
                $typeName -imatch '^(?:System\.)?Runtime\.InteropServices\.Marshal$'
        },$true))){
            $owner=Get-OwningFunctionDefinition -Node $typeExpression
            $ownerName=if($null -eq $owner){'<script>'}else{[string]$owner.Name}
            $allScriptsReflectionSensitiveInventory.Add("TypeExpression|$($model.RelativePath)|$ownerName|$($typeExpression.Extent.Text)")
        }
        foreach($typeExpression in @($ast.FindAll({param($node)
            $node -is [Management.Automation.Language.TypeExpressionAst] -and
            @(([string]$node.TypeName.FullName -split '\.'))[-1] -iin $reviewedSensitiveIssuerTypeShortNames
        },$true))){
            $owner=Get-OwningFunctionDefinition -Node $typeExpression
            $ownerName=if($null -eq $owner){'<script>'}else{[string]$owner.Name}
            $observedIssuerShortName=@(([string]$typeExpression.TypeName.FullName -split '\.'))[-1]
            $issuerTypeMatches=@($reviewedSensitiveIssuerTypeNames | Where-Object {
                @(([string]$_ -split '\.'))[-1] -ieq $observedIssuerShortName
            })
            if($issuerTypeMatches.Count -ne 1){
                $fixedCapabilityBoundaryViolations.Add("issuer type is ambiguous or unreviewed: $($model.RelativePath):$ownerName")
                continue
            }
            $issuerTypeName=[string]$issuerTypeMatches[0]
            $memberCall=$typeExpression.Parent
            if($memberCall -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -or
                -not [object]::ReferenceEquals($memberCall.Expression,$typeExpression)){
                $fixedCapabilityBoundaryViolations.Add("issuer type reflection or non-direct access: $($model.RelativePath):$ownerName")
                continue
            }
            if($memberCall.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]){
                $fixedCapabilityBoundaryViolations.Add("issuer nonliteral member access: $($model.RelativePath):$ownerName")
                continue
            }
            $memberName=[string]$memberCall.Member.Value
            $issuerSite="$issuerTypeName|$($model.RelativePath)|$ownerName|$memberName"
            $issuerInvocationInventory.Add($issuerSite)
            $issuerTopLevelBinding=if($null -eq $owner){
                Get-ScriptTopLevelStatementBinding -Node $typeExpression
            }
            else {
                Get-ScriptTopLevelStatementBinding -Node $owner
            }
            if($null -eq $issuerTopLevelBinding){
                $fixedCapabilityBoundaryViolations.Add("issuer owner/statement binding is missing: $issuerSite")
            }
            elseif($null -ne $owner -and -not [object]::ReferenceEquals($issuerTopLevelBinding.Ast,$owner)){
                $fixedCapabilityBoundaryViolations.Add("issuer owner function is not a direct script top-level definition: $issuerSite")
            }
            else {
                $issuerOwnerBindingAst=if($null -eq $owner){$issuerTopLevelBinding.Ast}else{$owner}
                $issuerOwnerBindingInventory.Add(
                    "$issuerSite|$($issuerOwnerBindingAst.GetType().Name)|$(Get-TextSha256 -Text $issuerOwnerBindingAst.Extent.Text)")
            }
            if($issuerSite -cnotin $reviewedIssuerInvocationInventory){
                $fixedCapabilityBoundaryViolations.Add("unreviewed issuer member access: $issuerSite")
            }
            if($issuerSite -ceq 'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldFixedInfrastructureCapabilityCapture|InvokeRawExact'){
                $rawCapabilityAllowedCallers.Add("$($model.RelativePath):$ownerName")
            }
            if($issuerSite -ceq 'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|InvokeProbeExact'){
                $probeCapabilityAllowedCallers.Add("$($model.RelativePath):$ownerName")
            }
            if($issuerSite -ceq 'AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|IssueExact'){
                $routeCaptureIssuerAllowedCallers.Add("$($model.RelativePath):$ownerName")
            }
        }
        foreach($definition in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){
            $definitionName=[string]$definition.Name
            if($definitionName.Contains([char]47) -or $definitionName.Contains([char]92) -or
                $definitionName.Contains([char]58)){
                $allScriptsCommandQualificationViolations.Add(
                    "$($model.RelativePath)|$definitionName|qualified function definition is not reviewed: $definitionName")
            }
            $definitionAncestor=$definition.Parent
            $insideScriptBlockExpression=$false
            while($null -ne $definitionAncestor){
                if($definitionAncestor -is [Management.Automation.Language.ScriptBlockExpressionAst]){
                    $insideScriptBlockExpression=$true
                    break
                }
                $definitionAncestor=$definitionAncestor.Parent
            }
            if($insideScriptBlockExpression){
                $allScriptsScriptBlockFunctionDefinitionInventory.Add(
                    "$($model.RelativePath)|$($definition.Name)|$($definition.Extent.Text)")
                continue
            }
            $normalizedDefinitionName=Get-NormalizedStaticFunctionName -FunctionName $definitionName
            $key=$normalizedDefinitionName.ToLowerInvariant()
            if(-not $definitions.ContainsKey($key)){$definitions[$key]=[Collections.Generic.List[object]]::new()}
            $definitions[$key].Add([pscustomobject]@{Name=$definitionName;RelativePath=[string]$model.RelativePath;Ast=$definition})
        }
    }

    $allScriptsDynamicCommandInventory=@($allScriptsDynamicCommandInventory | Sort-Object -CaseSensitive)
    $allScriptsDynamicCommandDigest=Get-TextSha256 -Text ($allScriptsDynamicCommandInventory -join "`n")
    $allScriptsDynamicCommandMatches=$allScriptsDynamicCommandDigest -ceq $reviewedAllScriptsDynamicCommandDigest
    if(-not $allScriptsDynamicCommandMatches){
        $allScriptsDynamicCommandViolations.Add("all-scripts dynamic command digest is $allScriptsDynamicCommandDigest, expected $reviewedAllScriptsDynamicCommandDigest")
    }
    $allScriptsReflectionSensitiveInventory=@($allScriptsReflectionSensitiveInventory | Sort-Object -CaseSensitive)
    $allScriptsReflectionSensitiveDigest=Get-TextSha256 -Text ($allScriptsReflectionSensitiveInventory -join "`n")
    $allScriptsReflectionSensitiveMatches=$allScriptsReflectionSensitiveInventory.Count -eq $reviewedAllScriptsReflectionSensitiveSiteCount -and
        $allScriptsReflectionSensitiveDigest -ceq $reviewedAllScriptsReflectionSensitiveDigest
    if(-not $allScriptsReflectionSensitiveMatches){
        $allScriptsReflectionSensitiveViolations.Add(
            "all-scripts reflection-sensitive inventory is count $($allScriptsReflectionSensitiveInventory.Count), digest $allScriptsReflectionSensitiveDigest; expected count $reviewedAllScriptsReflectionSensitiveSiteCount, digest $reviewedAllScriptsReflectionSensitiveDigest")
    }
    $allScriptsUsingStatementInventory=@($allScriptsUsingStatementInventory | Sort-Object -CaseSensitive)
    if($allScriptsUsingStatementInventory.Count -ne 0){
        $allScriptsUsingStatementViolations.Add(
            "all scripts/**/*.ps1 must retain the reviewed zero UsingStatementAst baseline; observed $($allScriptsUsingStatementInventory.Count)")
    }
    $allScriptsTypeDefinitionInventory=@($allScriptsTypeDefinitionInventory | Sort-Object -CaseSensitive)
    if($allScriptsTypeDefinitionInventory.Count -ne 0){
        $allScriptsTypeDefinitionViolations.Add(
            "all scripts/**/*.ps1 must retain the reviewed zero TypeDefinitionAst baseline; observed $($allScriptsTypeDefinitionInventory.Count)")
    }
    $allScriptsScriptBlockFunctionDefinitionInventory=@($allScriptsScriptBlockFunctionDefinitionInventory | Sort-Object -CaseSensitive)
    if($allScriptsScriptBlockFunctionDefinitionInventory.Count -ne 0){
        $allScriptsScriptBlockFunctionDefinitionViolations.Add(
            "all scripts/**/*.ps1 must retain the reviewed zero ScriptBlockExpressionAst FunctionDefinitionAst baseline; observed $($allScriptsScriptBlockFunctionDefinitionInventory.Count)")
    }
    $allScriptsLiteralProviderDriveTokenInventory=@($allScriptsLiteralProviderDriveTokenInventory | Sort-Object -CaseSensitive)
    if($allScriptsLiteralProviderDriveTokenInventory.Count -ne 0){
        $allScriptsLiteralProviderDriveTokenViolations.Add(
            "all scripts/**/*.ps1 must retain the reviewed zero literal provider-drive token baseline that supplements direct named CommandAst analysis; observed $($allScriptsLiteralProviderDriveTokenInventory.Count)")
    }
    $issuerInvocationInventory=@($issuerInvocationInventory | Sort-Object -CaseSensitive)
    if(($issuerInvocationInventory -join "`n") -cne ($reviewedIssuerInvocationInventory -join "`n")){
        $fixedCapabilityBoundaryViolations.Add('reviewed issuer owner/member invocation inventory changed')
    }
    $issuerOwnerBindingInventory=@($issuerOwnerBindingInventory | Sort-Object -CaseSensitive)
    if(($issuerOwnerBindingInventory -join "`n") -cne ($reviewedIssuerOwnerBindingInventory -join "`n")){
        $fixedCapabilityBoundaryViolations.Add('reviewed issuer owner/statement binding inventory changed')
    }

    $fixedCaptureDefinitions=@(if($definitions.ContainsKey('invoke-sealedheldfixedinfrastructurecapabilitycapture')){@($definitions['invoke-sealedheldfixedinfrastructurecapabilitycapture'])})
    if($fixedCaptureDefinitions.Count -ne 1 -or
        [string]$fixedCaptureDefinitions[0].RelativePath -cne 'scripts/root-claims-registry-common.ps1' -or
        -not (Test-DirectScriptTopLevelFunctionDefinition -Function $fixedCaptureDefinitions[0].Ast)){
        $fixedCapabilityBoundaryViolations.Add('fixed capability capture definition is missing, ambiguous, or outside root-claims-registry-common.ps1')
    }
    if($rawCapabilityAllowedCallers.Count -ne 1){
        $fixedCapabilityBoundaryViolations.Add("exact raw capability issuer allowed caller count is $($rawCapabilityAllowedCallers.Count), expected 1")
    }
    if($probeCapabilityAllowedCallers.Count -ne 1){
        $fixedCapabilityBoundaryViolations.Add("exact lower capability issuer allowed caller count is $($probeCapabilityAllowedCallers.Count), expected 1")
    }
    if($routeCaptureIssuerAllowedCallers.Count -ne 1){
        $fixedCapabilityBoundaryViolations.Add("exact current-route capture issuer allowed caller count is $($routeCaptureIssuerAllowedCallers.Count), expected 1")
    }
    $validatorDefinitions=@(if($definitions.ContainsKey('assert-sealedfixedinfrastructurecapabilityevidenceexact')){@($definitions['assert-sealedfixedinfrastructurecapabilityevidenceexact'])})
    if($validatorDefinitions.Count -ne 1 -or
        [string]$validatorDefinitions[0].RelativePath -cne 'scripts/root-claims-registry-common.ps1' -or
        -not (Test-DirectScriptTopLevelFunctionDefinition -Function $validatorDefinitions[0].Ast)){
        $fixedCapabilityBoundaryViolations.Add('fixed capability evidence validator definition is missing, ambiguous, or outside root-claims-registry-common.ps1')
    }
    if($validatorAllowedCallers.Count -ne 1){
        $fixedCapabilityBoundaryViolations.Add("fixed capability evidence validator allowed caller count is $($validatorAllowedCallers.Count), expected 1")
    }
    foreach($observationFunctionName in @(
        'Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation',
        'Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation',
        'Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation',
        'Open-SealedHeldObservationLifecycle',
        'Assert-SealedHeldObservationLifecycle',
        'Close-SealedHeldObservationLifecycle')){
        $observationDefinitionKey=$observationFunctionName.ToLowerInvariant()
        $observationDefinitions=@(if($definitions.ContainsKey($observationDefinitionKey)){@($definitions[$observationDefinitionKey])})
        if($observationDefinitions.Count -ne 1 -or
            [string]$observationDefinitions[0].RelativePath -cne 'scripts/root-claims-registry-common.ps1' -or
            -not (Test-DirectScriptTopLevelFunctionDefinition -Function $observationDefinitions[0].Ast)){
            $fixedObservationBoundaryViolations.Add("$observationFunctionName definition is missing, ambiguous, or outside root-claims-registry-common.ps1")
        }
    }
    $reviewedObservationOpenOwnerInventory=@('scripts/root-claims-registry-common.ps1:Open-SealedHeldObservationLifecycle')
    $reviewedObservationAssertOwnerInventory=@(
        'scripts/root-claims-registry-common.ps1:Assert-SealedHeldObservationLifecycle'
        'scripts/root-claims-registry-common.ps1:Open-SealedHeldObservationLifecycle'
    ) | Sort-Object -CaseSensitive
    $reviewedLedgerOpenOwnerInventory=@('scripts/root-claims-registry-common.ps1:Open-SealedHeldObservationLifecycle')
    $reviewedLedgerRegisterOwnerInventory=@('scripts/root-claims-registry-common.ps1:Open-SealedHeldObservationLifecycle')
    $reviewedLedgerAssertOwnerInventory=@(
        'scripts/root-claims-registry-common.ps1:Assert-SealedHeldObservationLifecycle'
        'scripts/root-claims-registry-common.ps1:Open-SealedHeldObservationLifecycle'
    ) | Sort-Object -CaseSensitive
    $reviewedLedgerCloseObservationOwnerInventory=@(
        'scripts/root-claims-registry-common.ps1:Close-SealedHeldObservationLifecycle'
        'scripts/root-claims-registry-common.ps1:Open-SealedHeldObservationLifecycle'
    ) | Sort-Object -CaseSensitive
    $reviewedLedgerCloseOwnerInventory=@(
        'scripts/root-claims-registry-common.ps1:Close-SealedHeldObservationLifecycle'
        'scripts/root-claims-registry-common.ps1:Open-SealedHeldObservationLifecycle'
    ) | Sort-Object -CaseSensitive
    if((@($observationOpenAllowedCallers | Sort-Object -CaseSensitive) -join "`n") -cne ($reviewedObservationOpenOwnerInventory -join "`n")){
        $fixedObservationBoundaryViolations.Add('reviewed observation Open owner inventory changed')
    }
    if((@($observationAssertAllowedCallers | Sort-Object -CaseSensitive) -join "`n") -cne ($reviewedObservationAssertOwnerInventory -join "`n")){
        $fixedObservationBoundaryViolations.Add('reviewed observation Assert owner inventory changed')
    }
    if((@($ledgerOpenAllowedCallers | Sort-Object -CaseSensitive) -join "`n") -cne ($reviewedLedgerOpenOwnerInventory -join "`n")){
        $fixedObservationBoundaryViolations.Add('reviewed observation cleanup ledger Open owner inventory changed')
    }
    if((@($ledgerRegisterAllowedCallers | Sort-Object -CaseSensitive) -join "`n") -cne ($reviewedLedgerRegisterOwnerInventory -join "`n")){
        $fixedObservationBoundaryViolations.Add('reviewed observation cleanup ledger Register owner inventory changed')
    }
    if((@($ledgerAssertAllowedCallers | Sort-Object -CaseSensitive) -join "`n") -cne ($reviewedLedgerAssertOwnerInventory -join "`n")){
        $fixedObservationBoundaryViolations.Add('reviewed observation cleanup ledger Assert owner inventory changed')
    }
    if((@($ledgerCloseObservationAllowedCallers | Sort-Object -CaseSensitive) -join "`n") -cne ($reviewedLedgerCloseObservationOwnerInventory -join "`n")){
        $fixedObservationBoundaryViolations.Add('reviewed observation cleanup ledger entry-close owner inventory changed')
    }
    if((@($ledgerCloseAllowedCallers | Sort-Object -CaseSensitive) -join "`n") -cne ($reviewedLedgerCloseOwnerInventory -join "`n")){
        $fixedObservationBoundaryViolations.Add('reviewed observation cleanup ledger close owner inventory changed')
    }

    $queue=[Collections.Generic.Queue[string]]::new()
    foreach($root in $productionRoots){$queue.Enqueue($root)}
    $closure=@{}
    while($queue.Count -gt 0){
        $requested=$queue.Dequeue();$key=$requested.ToLowerInvariant()
        if($closure.ContainsKey($key)){continue}
        if(-not $definitions.ContainsKey($key)){$resolutionFailures.Add("missing repository function: $requested");continue}
        $matches=@($definitions[$key])
        if($matches.Count -ne 1){$resolutionFailures.Add("ambiguous repository function: $requested ($($matches.Count) definitions)");continue}
        $definition=$matches[0];$closure[$key]=$definition
        foreach($command in @(Get-DirectFunctionNodes -Function $definition.Ast -Predicate {param($node)$node -is [Management.Automation.Language.CommandAst]})){
            $qualificationViolation=$null
            $commandName=Get-NormalizedStaticCommandName -CommandName ($command.GetCommandName()) `
                -AliasMap $reviewedStaticCommandAliasMap `
                -QualificationViolation ([ref]$qualificationViolation)
            if($null -eq $commandName){continue}
            if($null -ne $qualificationViolation){
                $resolutionFailures.Add("unreviewed path or module-qualified closure command: $($definition.Name) -> $commandName")
                continue
            }
            $commandKey=$commandName.ToLowerInvariant()
            if($definitions.ContainsKey($commandKey)){
                $repositoryMatches=@($definitions[$commandKey])
                if($repositoryMatches.Count -ne 1){$resolutionFailures.Add("ambiguous reachable call: $($definition.Name) -> $commandName ($($repositoryMatches.Count) definitions)")}
                else{$queue.Enqueue($commandName)}
                continue
            }
            if($commandName -cin $reviewedBuiltInLeaves){continue}
            if($commandName -cin $reviewedExternalLeaves -and $command.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand){continue}
            $resolutionFailures.Add("unreviewed closure leaf: $($definition.Name) -> $commandName")
        }
    }

    $closureInventory=@($closure.Values | ForEach-Object {"$($_.Name)|$($_.RelativePath)"} | Sort-Object)
    $closureMatches=(($closureInventory -join "`n") -ceq ($reviewedClosure -join "`n"))
    if(-not $closureMatches){$resolutionFailures.Add('reviewed transitive closure changed')}

    $exceptionInventory=[Collections.Generic.List[string]]::new()
    $unreviewedSeams=[Collections.Generic.List[string]]::new()
    foreach($definition in @($closure.Values)){
        foreach($node in @(Get-DirectFunctionNodes -Function $definition.Ast -Predicate {param($candidate)$candidate -is [Management.Automation.Language.ParameterAst] -and $candidate.StaticType -eq [scriptblock]})){
            $site="ScriptBlockParameter|$($definition.Name)|$($definition.RelativePath)|$($node.Extent.Text)"
            $inventory="ScriptBlockParameter|$($definition.Name)|$($definition.RelativePath)|$(Get-TextSha256 -Text $site)"
            $exceptionInventory.Add($inventory)
            if($inventory -cnotin $reviewedExceptionInventory){$unreviewedSeams.Add("unreviewed reachable ScriptBlockParameter: $($definition.Name)")}
        }

        foreach($node in @(Get-DirectFunctionNodes -Function $definition.Ast -Predicate {param($candidate)$candidate -is [Management.Automation.Language.CommandAst]})){
            $qualificationViolation=$null
            $commandName=Get-NormalizedStaticCommandName -CommandName ($node.GetCommandName()) `
                -AliasMap $reviewedStaticCommandAliasMap `
                -QualificationViolation ([ref]$qualificationViolation)
            if($node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot){$unreviewedSeams.Add("reachable dot invocation: $($definition.Name):$($node.Extent.Text)")}
            if($null -ne $qualificationViolation){
                $unreviewedSeams.Add("reachable unreviewed path or module-qualified command: $($definition.Name):$commandName")
                continue
            }
            if($null -eq $commandName){
                $site="DynamicInvocation|$($definition.Name)|$($definition.RelativePath)|$($node.Extent.Text)"
                $inventory="DynamicInvocation|$($definition.Name)|$($definition.RelativePath)|$(Get-TextSha256 -Text $site)"
                $exceptionInventory.Add($inventory)
                if($inventory -cnotin $reviewedExceptionInventory){$unreviewedSeams.Add("unreviewed reachable DynamicInvocation: $($definition.Name)")}
            }
            if($null -ne $commandName -and $commandName -match '^(?i:Get-Command|Invoke-Expression|Set-Alias|New-Alias|Remove-Alias|Import-Module|New-Module|Get-PSProvider|New-PSDrive|Remove-PSDrive)$'){$unreviewedSeams.Add("reachable command shadow/alias/provider site: $($definition.Name):$commandName")}
            if($node.Extent.Text -match '(?i)(?:^|[^A-Za-z0-9_])(?:Alias|Function|Env):'){$unreviewedSeams.Add("reachable provider mutation/reference site: $($definition.Name):$($node.Extent.Text)")}
        }

        foreach($node in @(Get-DirectFunctionNodes -Function $definition.Ast -Predicate {
            param($candidate)
            ($candidate -is [Management.Automation.Language.ParameterAst] -and $candidate.Name.VariablePath.UserPath -match '(?i)(?:failpoint|hook|provider)') -or
            ($candidate -is [Management.Automation.Language.CommandParameterAst] -and $candidate.ParameterName -match '(?i)(?:failpoint|hook|provider)') -or
            ($candidate -is [Management.Automation.Language.VariableExpressionAst] -and $candidate.VariablePath.UserPath -match '^(?i:env|alias|function):')
        })){$unreviewedSeams.Add("reachable hook/provider surface: $($definition.Name):$($node.Extent.Text)")}

        foreach($node in @(Get-DirectFunctionNodes -Function $definition.Ast -Predicate {
            param($candidate)
            $candidate -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
            $candidate.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $candidate.Member.Value -match '^(?i:Invoke|BeginInvoke|EndInvoke|GetEnvironmentVariable|SetEnvironmentVariable)$'
        })){$unreviewedSeams.Add("reachable dynamic callback/environment site: $($definition.Name):$($node.Extent.Text)")}

        foreach($node in @(Get-DirectFunctionNodes -Function $definition.Ast -Predicate {param($candidate)$candidate -is [Management.Automation.Language.FunctionDefinitionAst]})){
            $site="CommandShadowDefinition|$($definition.Name)|$($definition.RelativePath)|$($node.Extent.Text)"
            $inventory="CommandShadowDefinition|$($definition.Name)|$($definition.RelativePath)|$(Get-TextSha256 -Text $site)"
            $exceptionInventory.Add($inventory)
            if($inventory -cnotin $reviewedExceptionInventory){$unreviewedSeams.Add("unreviewed reachable nested command shadow definition: $($definition.Name):$($node.Name)")}
        }
    }

    $exceptionInventory=@($exceptionInventory | Sort-Object)
    $exceptionMatches=(($exceptionInventory -join "`n") -ceq ($reviewedExceptionInventory -join "`n"))
    if(-not $exceptionMatches){$unreviewedSeams.Add('reviewed reachable seam inventory or digest changed')}
    $accepted=($parseFailures.Count -eq 0 -and $forbiddenReferences.Count -eq 0 -and $resolutionFailures.Count -eq 0 -and
        $unreviewedSeams.Count -eq 0 -and $fixedCapabilityBoundaryViolations.Count -eq 0 -and
        $fixedObservationBoundaryViolations.Count -eq 0 -and
        $allScriptsCommandQualificationViolations.Count -eq 0 -and
        $allScriptsDynamicCommandViolations.Count -eq 0 -and $allScriptsReflectionSensitiveViolations.Count -eq 0 -and
        $allScriptsUsingStatementViolations.Count -eq 0 -and $allScriptsTypeDefinitionViolations.Count -eq 0 -and
        $allScriptsScriptBlockFunctionDefinitionViolations.Count -eq 0 -and $allScriptsLiteralProviderDriveTokenViolations.Count -eq 0)
    return [pscustomobject]@{
        Accepted=$accepted;ParseFailures=@($parseFailures);ForbiddenReferences=@($forbiddenReferences)
        ResolutionFailures=@($resolutionFailures);UnreviewedSeams=@($unreviewedSeams);Closure=@($closureInventory)
        ClosureMatches=$closureMatches;ExceptionInventory=@($exceptionInventory);ExceptionMatches=$exceptionMatches;Definitions=$definitions
        FixedCapabilityBoundaryViolations=@($fixedCapabilityBoundaryViolations);RawCapabilityAllowedCallers=@($rawCapabilityAllowedCallers)
        FixedObservationBoundaryViolations=@($fixedObservationBoundaryViolations)
        ProbeCapabilityAllowedCallers=@($probeCapabilityAllowedCallers);RouteCaptureIssuerAllowedCallers=@($routeCaptureIssuerAllowedCallers)
        ValidatorAllowedCallers=@($validatorAllowedCallers)
        ObservationOpenAllowedCallers=@($observationOpenAllowedCallers)
        ObservationAssertAllowedCallers=@($observationAssertAllowedCallers)
        LedgerOpenAllowedCallers=@($ledgerOpenAllowedCallers)
        LedgerRegisterAllowedCallers=@($ledgerRegisterAllowedCallers)
        LedgerAssertAllowedCallers=@($ledgerAssertAllowedCallers)
        LedgerCloseObservationAllowedCallers=@($ledgerCloseObservationAllowedCallers)
        LedgerCloseAllowedCallers=@($ledgerCloseAllowedCallers)
        AllScriptsDynamicCommandInventory=@($allScriptsDynamicCommandInventory)
        AllScriptsDynamicCommandDigest=$allScriptsDynamicCommandDigest
        AllScriptsDynamicCommandMatches=$allScriptsDynamicCommandMatches
        AllScriptsDynamicCommandViolations=@($allScriptsDynamicCommandViolations)
        AllScriptsCommandQualificationViolations=@($allScriptsCommandQualificationViolations)
        AllScriptsReflectionSensitiveInventory=@($allScriptsReflectionSensitiveInventory)
        AllScriptsReflectionSensitiveDigest=$allScriptsReflectionSensitiveDigest
        AllScriptsReflectionSensitiveMatches=$allScriptsReflectionSensitiveMatches
        AllScriptsReflectionSensitiveViolations=@($allScriptsReflectionSensitiveViolations)
        AllScriptsUsingStatementInventory=@($allScriptsUsingStatementInventory)
        AllScriptsUsingStatementViolations=@($allScriptsUsingStatementViolations)
        AllScriptsTypeDefinitionInventory=@($allScriptsTypeDefinitionInventory)
        AllScriptsTypeDefinitionViolations=@($allScriptsTypeDefinitionViolations)
        AllScriptsScriptBlockFunctionDefinitionInventory=@($allScriptsScriptBlockFunctionDefinitionInventory)
        AllScriptsScriptBlockFunctionDefinitionViolations=@($allScriptsScriptBlockFunctionDefinitionViolations)
        AllScriptsLiteralProviderDriveTokenInventory=@($allScriptsLiteralProviderDriveTokenInventory)
        AllScriptsLiteralProviderDriveTokenViolations=@($allScriptsLiteralProviderDriveTokenViolations)
        IssuerInvocationInventory=@($issuerInvocationInventory)
        IssuerOwnerBindingInventory=@($issuerOwnerBindingInventory)
    }
}

$sources=New-ProductionSourceModels -Root $RepoRoot
$baseline=Invoke-ProductionSeamAnalysis -SourceModels $sources

Assert-TestCondition ($sources.Count -eq @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -Recurse -File -Filter '*.ps1').Count) 'recursive scope covers every scripts/**/*.ps1 file'
Assert-TestCondition ($baseline.ParseFailures.Count -eq 0) 'every scripts/**/*.ps1 parses with zero errors'
Assert-TestCondition ($baseline.ForbiddenReferences.Count -eq 0) 'every scripts/**/*.ps1 has zero tests-only helper path, identifier, type, selector, reach, or checkpoint references'
Assert-TestCondition $baseline.ClosureMatches 'four production roots derive the exact reviewed function-level transitive closure'
Assert-TestCondition ($baseline.ResolutionFailures.Count -eq 0) 'every closure command resolves to one repository function or an explicit reviewed leaf'
Assert-TestCondition $baseline.ExceptionMatches 'reachable ScriptBlock and dynamic invocation exceptions match exact reviewed digests'
Assert-TestCondition ($baseline.UnreviewedSeams.Count -eq 0) 'closure exposes no new callback, shadow, alias, environment, failpoint, hook, or provider seam'
Assert-TestCondition $baseline.AllScriptsDynamicCommandMatches 'all scripts/**/*.ps1 dynamic CommandAst sites match the compact reviewed digest'
Assert-TestCondition ($baseline.AllScriptsCommandQualificationViolations.Count -eq 0) 'all scripts/**/*.ps1 use only unqualified static command names'
Assert-TestCondition $baseline.AllScriptsReflectionSensitiveMatches 'all scripts/**/*.ps1 reflection and dynamic type/method-resolution sites match the compact reviewed count and digest'
Assert-TestCondition ($baseline.AllScriptsUsingStatementInventory.Count -eq 0 -and
    $baseline.AllScriptsUsingStatementViolations.Count -eq 0) 'all scripts/**/*.ps1 retain the reviewed zero using-statement baseline'
Assert-TestCondition ($baseline.AllScriptsTypeDefinitionInventory.Count -eq 0 -and
    $baseline.AllScriptsTypeDefinitionViolations.Count -eq 0) 'all scripts/**/*.ps1 retain the reviewed zero PowerShell type-definition baseline'
Assert-TestCondition ($baseline.AllScriptsScriptBlockFunctionDefinitionInventory.Count -eq 0 -and
    $baseline.AllScriptsScriptBlockFunctionDefinitionViolations.Count -eq 0) 'all scripts/**/*.ps1 retain the reviewed zero ScriptBlockExpression nested-function baseline'
Assert-TestCondition ($baseline.AllScriptsLiteralProviderDriveTokenInventory.Count -eq 0 -and
    $baseline.AllScriptsLiteralProviderDriveTokenViolations.Count -eq 0) 'all scripts/**/*.ps1 retain the reviewed zero literal provider-drive token baseline alongside direct named CommandAst analysis'
Assert-TestCondition ($baseline.FixedCapabilityBoundaryViolations.Count -eq 0) 'fixed capture, route, observation, raw, and probe issuers plus the fixed validator have only their exact reviewed definitions, owners, and members'
Assert-TestCondition ($baseline.FixedObservationBoundaryViolations.Count -eq 0) 'held current-route observation Open/Assert and the five cleanup-ledger facades have only the reviewed lifecycle owner, observation Close and the lifecycle owner retain zero production callers, and all six functions remain uniquely defined'
Assert-TestCondition $baseline.Accepted 'current production seam contract is accepted'

$approvedRunnerDefinitions=@($baseline.Definitions['invoke-withpendinglock'])
$approvedRunnerHasScriptBlock=$approvedRunnerDefinitions.Count -eq 1 -and @(Get-DirectFunctionNodes -Function $approvedRunnerDefinitions[0].Ast -Predicate {param($node)$node -is [Management.Automation.Language.ParameterAst] -and $node.StaticType -eq [scriptblock]}).Count -eq 1
Assert-TestCondition ($approvedRunnerHasScriptBlock -and 'Invoke-WithPendingLock|scripts/approved-runner-common.ps1' -cnotin $baseline.Closure) 'acceptance control: approved-runner ScriptBlock API remains outside the four-root closure'

$safeTreeModel=@($sources | Where-Object RelativePath -ceq 'scripts/safe-tree-walker.ps1')[0]
$outOfClosureSafeTreeText=[string]$safeTreeModel.Text+@'

function Get-NeutralTreeProjection {
    param([scriptblock]$Projection)
    & $Projection
}
'@
$outOfClosureResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $safeTreeModel.RelativePath -Text $outOfClosureSafeTreeText)
Assert-TestCondition (-not $outOfClosureResult.Accepted -and $outOfClosureResult.ClosureMatches -and
    $outOfClosureResult.UnreviewedSeams.Count -eq 0 -and $outOfClosureResult.AllScriptsDynamicCommandViolations.Count -eq 1) 'acceptance control: an unrelated out-of-closure dynamic API changes only the reviewed all-scripts dynamic digest'

$mutationBase=@($sources | Where-Object RelativePath -ceq 'scripts/canonical-mutation-common.ps1')[0]
$scriptBlockMutation=Add-CallToFunctionSource -Source ([string]$mutationBase.Text) -FileName $mutationBase.RelativePath -FunctionName 'Initialize-CanonicalRecoveryWorkspace' -Call 'Invoke-NeutralTransform'
$scriptBlockMutation+=@'

function Invoke-NeutralTransform {
    param([scriptblock]$Operation)
    return $null
}
'@
$scriptBlockMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $mutationBase.RelativePath -Text $scriptBlockMutation)
Assert-TestCondition (-not $scriptBlockMutationResult.Accepted -and @($scriptBlockMutationResult.UnreviewedSeams | Where-Object {$_ -match 'ScriptBlockParameter'}).Count -gt 0) 'mutation RED: a neutral-name reachable helper with a ScriptBlock parameter is rejected'

$dynamicMutation=Add-CallToFunctionSource -Source ([string]$mutationBase.Text) -FileName $mutationBase.RelativePath -FunctionName 'Initialize-CanonicalRecoveryWorkspace' -Call 'Invoke-NeutralDispatch'
$dynamicMutation+=@'

function Invoke-NeutralDispatch {
    param($Operation)
    & $Operation
}
'@
$dynamicMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $mutationBase.RelativePath -Text $dynamicMutation)
Assert-TestCondition (-not $dynamicMutationResult.Accepted -and @($dynamicMutationResult.UnreviewedSeams | Where-Object {$_ -match 'DynamicInvocation'}).Count -gt 0) 'mutation RED: a separate neutral-name reachable dynamic callback is rejected'

$identifierMutation=@'
function Get-NeutralInternalState {
    param([AiAgentDotfilesTests.SealedMutationInvocationContext]$State)
    return $State
}
'@
$identifierMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath 'scripts/internal/neutral-state.ps1' -Text $identifierMutation)
Assert-TestCondition (-not $identifierMutationResult.Accepted -and @($identifierMutationResult.ForbiddenReferences | Where-Object {$_ -match '^scripts/internal/neutral-state\.ps1:'}).Count -gt 0) 'mutation RED: recursive all-scripts scan rejects a tests-only identifier under scripts/internal'

$typeDefinitionMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath 'scripts/internal/neutral-runtime-type.ps1' -Text 'class NeutralRuntimeDispatchShim {}')
Assert-TestCondition (-not $typeDefinitionMutationResult.Accepted -and
    $typeDefinitionMutationResult.AllScriptsTypeDefinitionViolations.Count -eq 1 -and
    $typeDefinitionMutationResult.AllScriptsReflectionSensitiveMatches) 'mutation RED: zero-baseline TypeDefinitionAst inventory rejects a new production PowerShell runtime type'

$addTypeMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath 'scripts/internal/neutral-add-type.ps1' -Text "Add-Type -TypeDefinition 'public sealed class NeutralCompiledDispatchShim {}'")
Assert-TestCondition (-not $addTypeMutationResult.Accepted -and
    $addTypeMutationResult.AllScriptsReflectionSensitiveViolations.Count -eq 1 -and
    $addTypeMutationResult.AllScriptsUsingStatementViolations.Count -eq 0 -and
    $addTypeMutationResult.AllScriptsTypeDefinitionViolations.Count -eq 0) 'mutation RED: exact reflection-sensitive CommandAst inventory rejects a new production Add-Type site'

$moduleQualifiedAddTypeMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath 'scripts/internal/neutral-module-add-type.ps1' -Text "Microsoft.PowerShell.Utility\Add-Type -TypeDefinition 'public sealed class NeutralModuleQualifiedDispatchShim {}'")
Assert-TestCondition (-not $moduleQualifiedAddTypeMutationResult.Accepted -and
    $moduleQualifiedAddTypeMutationResult.AllScriptsCommandQualificationViolations.Count -eq 1 -and
    $moduleQualifiedAddTypeMutationResult.AllScriptsReflectionSensitiveMatches -and
    $moduleQualifiedAddTypeMutationResult.AllScriptsDynamicCommandMatches) 'mutation RED: module-qualified Add-Type is rejected before a same-name function can shadow it'

$moduleQualifiedGetCommandMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath 'scripts/internal/neutral-module-get-command.ps1' -Text 'Microsoft.PowerShell.Core\Get-Command Get-Item | Out-Null')
Assert-TestCondition (-not $moduleQualifiedGetCommandMutationResult.Accepted -and
    $moduleQualifiedGetCommandMutationResult.AllScriptsCommandQualificationViolations.Count -eq 1 -and
    $moduleQualifiedGetCommandMutationResult.AllScriptsReflectionSensitiveMatches -and
    $moduleQualifiedGetCommandMutationResult.AllScriptsDynamicCommandMatches) 'mutation RED: module-qualified Get-Command is rejected before a same-name function can shadow it'

$invokeExpressionAliasMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath 'scripts/internal/neutral-iex.ps1' -Text "iex 'Write-Output neutral'")
Assert-TestCondition (-not $invokeExpressionAliasMutationResult.Accepted -and
    $invokeExpressionAliasMutationResult.AllScriptsReflectionSensitiveViolations.Count -eq 1 -and
    $invokeExpressionAliasMutationResult.AllScriptsDynamicCommandMatches) 'mutation RED: fixed Invoke-Expression alias cannot bypass normalized reflection inventory'

$moduleQualifiedMemberDispatchMutation=@'
$neutralBlock={ 'neutral' }
$dispatch=@{MemberName='InvokeWithContext';ArgumentList=@($null,$null,[object[]]@())}
$neutralBlock | Microsoft.PowerShell.Core\ForEach-Object @dispatch | Out-Null
'@
$moduleQualifiedMemberDispatchMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath 'scripts/internal/neutral-module-member-dispatch.ps1' -Text $moduleQualifiedMemberDispatchMutation)
Assert-TestCondition (-not $moduleQualifiedMemberDispatchMutationResult.Accepted -and
    $moduleQualifiedMemberDispatchMutationResult.AllScriptsCommandQualificationViolations.Count -eq 1 -and
    $moduleQualifiedMemberDispatchMutationResult.AllScriptsReflectionSensitiveMatches -and
    $moduleQualifiedMemberDispatchMutationResult.AllScriptsDynamicCommandMatches) 'mutation RED: module-qualified splatted member dispatch is rejected before a same-name function can shadow it'

$relativePathCommandMutation=Add-CallToFunctionSource `
    -Source ([string]$mutationBase.Text) `
    -FileName $mutationBase.RelativePath `
    -FunctionName 'Initialize-CanonicalRecoveryWorkspace' `
    -Call '.\Test-Path -LiteralPath $RepoRoot | Out-Null'
$relativePathCommandMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $mutationBase.RelativePath -Text $relativePathCommandMutation)
Assert-TestCondition (-not $relativePathCommandMutationResult.Accepted -and
    @($relativePathCommandMutationResult.AllScriptsCommandQualificationViolations | Where-Object {$_ -match [regex]::Escape('.\Test-Path')}).Count -eq 1 -and
    @($relativePathCommandMutationResult.ResolutionFailures | Where-Object {$_ -match [regex]::Escape('Initialize-CanonicalRecoveryWorkspace -> .\Test-Path')}).Count -eq 1 -and
    @($relativePathCommandMutationResult.UnreviewedSeams | Where-Object {$_ -match [regex]::Escape('Initialize-CanonicalRecoveryWorkspace:.\Test-Path')}).Count -eq 1) 'mutation RED: a reachable relative-path command cannot normalize to a reviewed Test-Path leaf'

$unknownModuleCommandMutation=Add-CallToFunctionSource `
    -Source ([string]$mutationBase.Text) `
    -FileName $mutationBase.RelativePath `
    -FunctionName 'Initialize-CanonicalRecoveryWorkspace' `
    -Call 'EvilModule\Test-Path -LiteralPath $RepoRoot | Out-Null'
$unknownModuleCommandMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $mutationBase.RelativePath -Text $unknownModuleCommandMutation)
Assert-TestCondition (-not $unknownModuleCommandMutationResult.Accepted -and
    @($unknownModuleCommandMutationResult.AllScriptsCommandQualificationViolations | Where-Object {$_ -match [regex]::Escape('EvilModule\Test-Path')}).Count -eq 1 -and
    @($unknownModuleCommandMutationResult.ResolutionFailures | Where-Object {$_ -match [regex]::Escape('Initialize-CanonicalRecoveryWorkspace -> EvilModule\Test-Path')}).Count -eq 1 -and
    @($unknownModuleCommandMutationResult.UnreviewedSeams | Where-Object {$_ -match [regex]::Escape('Initialize-CanonicalRecoveryWorkspace:EvilModule\Test-Path')}).Count -eq 1) 'mutation RED: an unknown module qualifier cannot normalize to a reviewed Test-Path leaf'

$reviewedModuleCommandMutation=Add-CallToFunctionSource `
    -Source ([string]$mutationBase.Text) `
    -FileName $mutationBase.RelativePath `
    -FunctionName 'Initialize-CanonicalRecoveryWorkspace' `
    -Call 'Microsoft.PowerShell.Management\Test-Path -LiteralPath $RepoRoot | Out-Null'
$reviewedModuleCommandMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $mutationBase.RelativePath -Text $reviewedModuleCommandMutation)
Assert-TestCondition (-not $reviewedModuleCommandMutationResult.Accepted -and
    @($reviewedModuleCommandMutationResult.AllScriptsCommandQualificationViolations | Where-Object {
        $_ -match [regex]::Escape('Microsoft.PowerShell.Management\Test-Path')
    }).Count -eq 1 -and
    @($reviewedModuleCommandMutationResult.ResolutionFailures | Where-Object {
        $_ -match [regex]::Escape('Initialize-CanonicalRecoveryWorkspace -> Microsoft.PowerShell.Management\Test-Path')
    }).Count -eq 1 -and
    @($reviewedModuleCommandMutationResult.UnreviewedSeams | Where-Object {
        $_ -match [regex]::Escape('Initialize-CanonicalRecoveryWorkspace:Microsoft.PowerShell.Management\Test-Path')
    }).Count -eq 1) 'mutation RED: even a standard module-qualified command is rejected because a same-name function can shadow it'

$moduleQualifiedFunctionShadowMutation=$reviewedModuleCommandMutation+@'

function Microsoft.PowerShell.Management\Test-Path {
    param([string]$LiteralPath)
    return $true
}
'@
$moduleQualifiedFunctionShadowMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $mutationBase.RelativePath -Text $moduleQualifiedFunctionShadowMutation)
Assert-TestCondition (-not $moduleQualifiedFunctionShadowMutationResult.Accepted -and
    $moduleQualifiedFunctionShadowMutationResult.ParseFailures.Count -eq 0 -and
    @($moduleQualifiedFunctionShadowMutationResult.AllScriptsCommandQualificationViolations | Where-Object {
        $_ -match 'qualified or path command is not reviewed: Microsoft\.PowerShell\.Management\\Test-Path$'
    }).Count -eq 1 -and
    @($moduleQualifiedFunctionShadowMutationResult.AllScriptsCommandQualificationViolations | Where-Object {
        $_ -match 'qualified function definition is not reviewed: Microsoft\.PowerShell\.Management\\Test-Path$'
    }).Count -eq 1) 'mutation RED: a standard module-qualified call plus its exact same-name function shadow are both rejected'

$scopeQualifiedBuiltInMutation=Add-CallToFunctionSource `
    -Source ([string]$mutationBase.Text) `
    -FileName $mutationBase.RelativePath `
    -FunctionName 'Initialize-CanonicalRecoveryWorkspace' `
    -Call 'global:Test-Path -LiteralPath $RepoRoot | Out-Null'
$scopeQualifiedBuiltInMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $mutationBase.RelativePath -Text $scopeQualifiedBuiltInMutation)
Assert-TestCondition (-not $scopeQualifiedBuiltInMutationResult.Accepted -and
    @($scopeQualifiedBuiltInMutationResult.AllScriptsCommandQualificationViolations | Where-Object {
        $_ -match [regex]::Escape('global:Test-Path')
    }).Count -eq 1 -and
    @($scopeQualifiedBuiltInMutationResult.ResolutionFailures | Where-Object {
        $_ -match [regex]::Escape('Initialize-CanonicalRecoveryWorkspace -> global:Test-Path')
    }).Count -eq 1 -and
    @($scopeQualifiedBuiltInMutationResult.UnreviewedSeams | Where-Object {
        $_ -match [regex]::Escape('Initialize-CanonicalRecoveryWorkspace:global:Test-Path')
    }).Count -eq 1) 'mutation RED: scope-qualified built-in syntax is rejected before a global function can shadow it'

$rootClaimsModel=@($sources | Where-Object RelativePath -ceq 'scripts/root-claims-registry-common.ps1')[0]
$fixedEnvelopeCoreOffset=([string]$rootClaimsModel.Text).IndexOf('$sealedHeldCurrentRouteFixedEnvelopeOpenCore={',[StringComparison]::Ordinal)
$fixedEnvelopeValidatorText='    $null=Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext'
$fixedEnvelopeValidatorOffset=if($fixedEnvelopeCoreOffset -lt 0){-1}else{([string]$rootClaimsModel.Text).IndexOf($fixedEnvelopeValidatorText,$fixedEnvelopeCoreOffset,[StringComparison]::Ordinal)}
if($fixedEnvelopeValidatorOffset -lt 0){throw 'fixed-envelope nested-shadow mutation marker is missing'}
$nestedShadowDefinition=@'
    function Assert-SealedHomeAuthorityBootstrapContext {
        param($AuthorityContext)
        return $AuthorityContext
    }
'@
$sourceNewline=if(([string]$rootClaimsModel.Text).Contains("`r`n")){"`r`n"}else{"`n"}
$nestedFunctionShadowMutation=([string]$rootClaimsModel.Text).Insert(
    $fixedEnvelopeValidatorOffset,$nestedShadowDefinition+$sourceNewline)
$nestedFunctionShadowMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $rootClaimsModel.RelativePath -Text $nestedFunctionShadowMutation)
Assert-TestCondition (-not $nestedFunctionShadowMutationResult.Accepted -and
    $nestedFunctionShadowMutationResult.AllScriptsScriptBlockFunctionDefinitionInventory.Count -eq 1 -and
    $nestedFunctionShadowMutationResult.AllScriptsScriptBlockFunctionDefinitionViolations.Count -eq 1 -and
    $nestedFunctionShadowMutationResult.AllScriptsDynamicCommandMatches -and
    $nestedFunctionShadowMutationResult.AllScriptsReflectionSensitiveMatches) 'mutation RED: nested function definition cannot shadow a fixed-envelope safety validator'

$scopeQualifiedObservationDefinitionMutation=([string]$rootClaimsModel.Text)+@'

function script:Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation {
    'shadowed'
}
'@
$scopeQualifiedObservationDefinitionMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $rootClaimsModel.RelativePath -Text $scopeQualifiedObservationDefinitionMutation)
Assert-TestCondition (-not $scopeQualifiedObservationDefinitionMutationResult.Accepted -and
    @($scopeQualifiedObservationDefinitionMutationResult.FixedObservationBoundaryViolations | Where-Object {
        $_ -ceq 'Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation definition is missing, ambiguous, or outside root-claims-registry-common.ps1'
    }).Count -eq 1 -and
    $scopeQualifiedObservationDefinitionMutationResult.AllScriptsScriptBlockFunctionDefinitionViolations.Count -eq 0 -and
    $scopeQualifiedObservationDefinitionMutationResult.AllScriptsDynamicCommandMatches -and
    $scopeQualifiedObservationDefinitionMutationResult.AllScriptsReflectionSensitiveMatches) 'mutation RED: scope-qualified function definition cannot shadow a protected observation API'

$routeBeginIssuerMarker='    $routeOpenOperation = [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::BeginOpenExact()'
if(([regex]::Matches([string]$rootClaimsModel.Text,[regex]::Escape($routeBeginIssuerMarker))).Count -ne 1){
    throw 'route issuer relocation mutation marker is not unique'
}
$routeIssuerRelocationMutation=([string]$rootClaimsModel.Text).Replace(
    $routeBeginIssuerMarker,
    "    `$routeOpenOperation = `$null`n    if(`$false){`n$routeBeginIssuerMarker`n    }")
$routeIssuerRelocationMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $rootClaimsModel.RelativePath -Text $routeIssuerRelocationMutation)
Assert-TestCondition (-not $routeIssuerRelocationMutationResult.Accepted -and
    ($routeIssuerRelocationMutationResult.IssuerInvocationInventory -join "`n") -ceq ($reviewedIssuerInvocationInventory -join "`n") -and
    @($routeIssuerRelocationMutationResult.FixedCapabilityBoundaryViolations | Where-Object {
        $_ -ceq 'reviewed issuer owner/statement binding inventory changed'
    }).Count -eq 1 -and
    $routeIssuerRelocationMutationResult.AllScriptsDynamicCommandMatches -and
    $routeIssuerRelocationMutationResult.AllScriptsReflectionSensitiveMatches) 'mutation RED: issuer call relocation into a dead function branch changes the bound owner digest'

$rootClaimsTokens=$null;$rootClaimsParseErrors=$null
$rootClaimsAst=[Management.Automation.Language.Parser]::ParseInput(
    [string]$rootClaimsModel.Text,$rootClaimsModel.RelativePath,[ref]$rootClaimsTokens,[ref]$rootClaimsParseErrors)
if(@($rootClaimsParseErrors).Count -ne 0){throw 'root-claims source is not parseable for script issuer relocation mutation'}
$routeOpenDefinitions=@($rootClaimsAst.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    [string]$node.Name -ceq 'Open-SealedRegistryCurrentRouteCapture'
},$true))
if($routeOpenDefinitions.Count -ne 1){throw 'route owner definition relocation mutation target is not unique'}
$routeOwnerDefinitionRelocationMutation=([string]$rootClaimsModel.Text).Insert(
    $routeOpenDefinitions[0].Extent.EndOffset,$sourceNewline+'}').Insert(
    $routeOpenDefinitions[0].Extent.StartOffset,'if($false){'+$sourceNewline)
$routeOwnerDefinitionRelocationMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $rootClaimsModel.RelativePath -Text $routeOwnerDefinitionRelocationMutation)
Assert-TestCondition (-not $routeOwnerDefinitionRelocationMutationResult.Accepted -and
    ($routeOwnerDefinitionRelocationMutationResult.IssuerInvocationInventory -join "`n") -ceq ($reviewedIssuerInvocationInventory -join "`n") -and
    @($routeOwnerDefinitionRelocationMutationResult.FixedCapabilityBoundaryViolations | Where-Object {
        $_ -ceq 'issuer owner function is not a direct script top-level definition: AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/root-claims-registry-common.ps1|Open-SealedRegistryCurrentRouteCapture|BeginOpenExact'
    }).Count -eq 1 -and
    $routeOwnerDefinitionRelocationMutationResult.AllScriptsDynamicCommandMatches -and
    $routeOwnerDefinitionRelocationMutationResult.AllScriptsReflectionSensitiveMatches) 'mutation RED: a reviewed issuer owner function cannot be relocated wholesale into a dead script branch'

$fixedIssuerInitializeExpressions=@($rootClaimsAst.FindAll({param($node)
    $node -is [Management.Automation.Language.TypeExpressionAst] -and
    [string]$node.TypeName.FullName -ceq 'AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer' -and
    $node.Parent -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Parent.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
    [string]$node.Parent.Member.Value -ceq 'InitializeExact' -and
    $null -eq (Get-OwningFunctionDefinition -Node $node)
},$true))
if($fixedIssuerInitializeExpressions.Count -ne 1){throw 'script issuer relocation mutation target is not unique'}
$fixedIssuerInitializeStatement=Get-MinimalTopLevelStatementAst -Node $fixedIssuerInitializeExpressions[0]
if($null -eq $fixedIssuerInitializeStatement){throw 'script issuer relocation mutation has no top-level statement'}
$scriptIssuerRelocationMutation=([string]$rootClaimsModel.Text).Insert(
    $fixedIssuerInitializeStatement.Extent.EndOffset,$sourceNewline+'}').Insert(
    $fixedIssuerInitializeStatement.Extent.StartOffset,'if($false){'+$sourceNewline)
$scriptIssuerRelocationMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $rootClaimsModel.RelativePath -Text $scriptIssuerRelocationMutation)
Assert-TestCondition (-not $scriptIssuerRelocationMutationResult.Accepted -and
    ($scriptIssuerRelocationMutationResult.IssuerInvocationInventory -join "`n") -ceq ($reviewedIssuerInvocationInventory -join "`n") -and
    @($scriptIssuerRelocationMutationResult.FixedCapabilityBoundaryViolations | Where-Object {
        $_ -ceq 'reviewed issuer owner/statement binding inventory changed'
    }).Count -eq 1 -and
    $scriptIssuerRelocationMutationResult.AllScriptsDynamicCommandMatches -and
    $scriptIssuerRelocationMutationResult.AllScriptsReflectionSensitiveMatches) 'mutation RED: script issuer call relocation changes the bound top-level statement digest'

$syncApplyModel=@($sources | Where-Object RelativePath -ceq 'scripts/sync.ps1')[0]
$applyMarkerMatches=[regex]::Matches([string]$syncApplyModel.Text,'(?m)^# Apply\r?$')
if($applyMarkerMatches.Count -ne 1){throw 'sync Apply mutation marker is not unique'}
$fixedCapabilityApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`nInvoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext `$authority -GlobalLockHandle `$globalLock -CapabilityProbeBindings `$bindings",
    1)
$fixedCapabilityApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $fixedCapabilityApplyMutation)
Assert-TestCondition (-not $fixedCapabilityApplyMutationResult.Accepted -and
    @($fixedCapabilityApplyMutationResult.FixedCapabilityBoundaryViolations | Where-Object {$_ -ceq 'fixed capability capture caller: scripts/sync.ps1:<script>'}).Count -eq 1) 'mutation RED: recursive all-scripts guard rejects fixed capability capture injected into the production Apply branch'

$fixedObservationApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`nOpen-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture `$currentRouteCapture -CapabilityProbeBindings `$bindings | Out-Null",
    1)
$fixedObservationApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $fixedObservationApplyMutation)
Assert-TestCondition (-not $fixedObservationApplyMutationResult.Accepted -and
    @($fixedObservationApplyMutationResult.FixedObservationBoundaryViolations | Where-Object {
        $_ -ceq 'held current-route fixed-infrastructure observation caller: scripts/sync.ps1:<script>:Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation'
    }).Count -eq 1) 'mutation RED: recursive all-scripts guard rejects opening a held observation from the production Apply branch'

$scopeQualifiedObservationApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`nscript:Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture `$currentRouteCapture -CapabilityProbeBindings `$bindings | Out-Null",
    1)
$scopeQualifiedObservationApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $scopeQualifiedObservationApplyMutation)
Assert-TestCondition (-not $scopeQualifiedObservationApplyMutationResult.Accepted -and
    @($scopeQualifiedObservationApplyMutationResult.AllScriptsCommandQualificationViolations | Where-Object {
        $_ -match [regex]::Escape('script:Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation')
    }).Count -eq 1 -and
    $scopeQualifiedObservationApplyMutationResult.FixedObservationBoundaryViolations.Count -eq 0 -and
    $scopeQualifiedObservationApplyMutationResult.AllScriptsDynamicCommandMatches) 'mutation RED: scope-qualified observation call is rejected before provider or function shadow resolution'

$aliasedObservationApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`nSet-Alias -Name NeutralObservationOpen -Value Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation`nNeutralObservationOpen -CurrentRouteCapture `$currentRouteCapture -CapabilityProbeBindings `$bindings | Out-Null",
    1)
$aliasedObservationApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $aliasedObservationApplyMutation)
Assert-TestCondition (-not $aliasedObservationApplyMutationResult.Accepted -and
    $aliasedObservationApplyMutationResult.AllScriptsReflectionSensitiveViolations.Count -eq 1 -and
    $aliasedObservationApplyMutationResult.AllScriptsDynamicCommandMatches -and
    $aliasedObservationApplyMutationResult.FixedObservationBoundaryViolations.Count -eq 0) 'mutation RED: alias creation cannot hide an observation API call'

$providerAliasedObservationApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`nSet-Item Alias:NeutralObservationOpen -Value Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation`nSet-Item Function:NeutralObservationShadow -Value { 'neutral' }`nNeutralObservationOpen -CurrentRouteCapture `$currentRouteCapture -CapabilityProbeBindings `$bindings | Out-Null",
    1)
$providerAliasedObservationApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $providerAliasedObservationApplyMutation)
Assert-TestCondition (-not $providerAliasedObservationApplyMutationResult.Accepted -and
    $providerAliasedObservationApplyMutationResult.AllScriptsLiteralProviderDriveTokenInventory.Count -eq 2 -and
    $providerAliasedObservationApplyMutationResult.AllScriptsLiteralProviderDriveTokenViolations.Count -eq 1 -and
    $providerAliasedObservationApplyMutationResult.AllScriptsDynamicCommandMatches -and
    $providerAliasedObservationApplyMutationResult.AllScriptsReflectionSensitiveMatches -and
    $providerAliasedObservationApplyMutationResult.FixedObservationBoundaryViolations.Count -eq 0) 'mutation RED: contiguous literal Alias:/Function: provider-drive tokens cannot hide an observation API call from direct named CommandAst analysis'

$providerVariableAliasedObservationApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`n`$alias:NeutralObservationOpen = 'Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation'`n`${function:NeutralObservationShadow} = { 'neutral' }`nNeutralObservationOpen -CurrentRouteCapture `$currentRouteCapture -CapabilityProbeBindings `$bindings | Out-Null",
    1)
$providerVariableAliasedObservationApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $providerVariableAliasedObservationApplyMutation)
$expectedProviderVariableInventory=@(
    'VariableExpressionAst|scripts/sync.ps1|<script>|$alias:NeutralObservationOpen'
    'VariableExpressionAst|scripts/sync.ps1|<script>|${function:NeutralObservationShadow}'
) | Sort-Object -CaseSensitive
Assert-TestCondition (-not $providerVariableAliasedObservationApplyMutationResult.Accepted -and
    ($providerVariableAliasedObservationApplyMutationResult.AllScriptsLiteralProviderDriveTokenInventory -join "`n") -ceq ($expectedProviderVariableInventory -join "`n") -and
    $providerVariableAliasedObservationApplyMutationResult.AllScriptsLiteralProviderDriveTokenViolations.Count -eq 1 -and
    $providerVariableAliasedObservationApplyMutationResult.AllScriptsDynamicCommandMatches -and
    $providerVariableAliasedObservationApplyMutationResult.AllScriptsReflectionSensitiveMatches -and
    $providerVariableAliasedObservationApplyMutationResult.FixedObservationBoundaryViolations.Count -eq 0) 'mutation RED: drive-qualified $alias:name and ${function:name} VariableExpressionAst forms cannot hide an observation API call from direct named CommandAst analysis'

foreach($observationMutation in @(
    [pscustomobject]@{Name='assert';Command='Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation | Out-Null';Expected='Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation'},
    [pscustomobject]@{Name='close';Command='Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation | Out-Null';Expected='Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation'}
)){
    $observationLifecycleApplyMutation=[regex]::Replace(
        [string]$syncApplyModel.Text,
        '(?m)^# Apply\r?$',
        "# Apply`n$([string]$observationMutation.Command)",
        1)
    $observationLifecycleApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $observationLifecycleApplyMutation)
    $expectedObservationLifecycleViolation="held current-route fixed-infrastructure observation caller: scripts/sync.ps1:<script>:$([string]$observationMutation.Expected)"
    Assert-TestCondition (-not $observationLifecycleApplyMutationResult.Accepted -and
        @($observationLifecycleApplyMutationResult.FixedObservationBoundaryViolations | Where-Object {$_ -ceq $expectedObservationLifecycleViolation}).Count -eq 1) "mutation RED: recursive all-scripts guard rejects observation $([string]$observationMutation.Name) from the production Apply branch"
}

$rawCapabilityApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`nInvoke-SealedHeldCapabilityPreflight -AuthorityContext `$authority -GlobalLockHandle `$globalLock -CapabilityTargets `$targets",
    1)
$rawCapabilityApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $rawCapabilityApplyMutation)
Assert-TestCondition (-not $rawCapabilityApplyMutationResult.Accepted -and
    @($rawCapabilityApplyMutationResult.FixedCapabilityBoundaryViolations | Where-Object {$_ -ceq 'dynamic raw capability preflight caller: scripts/sync.ps1:<script>'}).Count -eq 1) 'mutation RED: recursive all-scripts guard rejects a direct raw capability preflight injected into production Apply'

$exactRawIssuerApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`n[AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer]::iNvOkErAwExAcT(`$authority,`$globalLock,`$null,`$targets) | Out-Null",
    1)
$exactRawIssuerApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $exactRawIssuerApplyMutation)
Assert-TestCondition (-not $exactRawIssuerApplyMutationResult.Accepted -and
    @($exactRawIssuerApplyMutationResult.FixedCapabilityBoundaryViolations | Where-Object {$_ -ceq 'unreviewed issuer member access: AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer|scripts/sync.ps1|<script>|iNvOkErAwExAcT'}).Count -eq 1) 'mutation RED: case variants of exact raw issuer invocation are accepted only inside the fixed capture function'

foreach($issuerApplyMutation in @(
    [pscustomobject]@{
        Name='observation broker access'
        Text="# Apply`n[AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer]::oPeNoBsErVaTiOnExAcT(`$route,`$bindings) | Out-Null"
        Expected='unreviewed issuer member access: AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer|scripts/sync.ps1|<script>|oPeNoBsErVaTiOnExAcT'
    },
    [pscustomobject]@{
        Name='current-route issuance'
        Text="# Apply`n[AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::iSsUeExAcT() | Out-Null"
        Expected='unreviewed issuer member access: AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer|scripts/sync.ps1|<script>|iSsUeExAcT'
    }
)){
    $directIssuerApplyText=[regex]::Replace([string]$syncApplyModel.Text,'(?m)^# Apply\r?$',[string]$issuerApplyMutation.Text,1)
    $directIssuerApplyResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $directIssuerApplyText)
    Assert-TestCondition (-not $directIssuerApplyResult.Accepted -and
        @($directIssuerApplyResult.FixedCapabilityBoundaryViolations | Where-Object {$_ -ceq [string]$issuerApplyMutation.Expected}).Count -eq 1) "mutation RED: direct $([string]$issuerApplyMutation.Name) is rejected outside its exact reviewed owner"
}

$dynamicRawApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`n`$rawCapabilityCommand='Invoke-SealedHeldCapabilityPreflight'`n& `$rawCapabilityCommand -AuthorityContext `$authority -GlobalLockHandle `$globalLock -CapabilityTargets `$targets",
    1)
$dynamicRawApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $dynamicRawApplyMutation)
Assert-TestCondition (-not $dynamicRawApplyMutationResult.Accepted -and
    $dynamicRawApplyMutationResult.AllScriptsDynamicCommandViolations.Count -eq 1) 'mutation RED: all-scripts dynamic-command inventory rejects an indirect raw preflight injected into production Apply'

$issuerReflectionApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`n([AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer]).GetMethod('InvokeRawExact').Invoke(`$null,@(`$authority,`$globalLock,`$null,`$targets)) | Out-Null",
    1)
$issuerReflectionApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $issuerReflectionApplyMutation)
Assert-TestCondition (-not $issuerReflectionApplyMutationResult.Accepted -and
    @($issuerReflectionApplyMutationResult.FixedCapabilityBoundaryViolations | Where-Object {$_ -ceq 'issuer type reflection or non-direct access: scripts/sync.ps1:<script>'}).Count -eq 1) 'mutation RED: issuer TypeExpression/reflection inventory rejects reflective InvokeRawExact access in production Apply'

$hiddenIssuerReflectionApplyMutation=([regex]::new('(?m)^# Apply\r?$')).Replace(
    [string]$syncApplyModel.Text,
    "# Apply`n`$issuerType=`$null`nforeach(`$assembly in [AppDomain]::CurrentDomain.GetAssemblies()){`n    `$candidateType=`$assembly.GetType(('AiAgentDotfiles.'+'SealedFixedInfrastructureCapabilityIssuer'))`n    if(`$null -ne `$candidateType){`$issuerType=`$candidateType;break}`n}`n`$issuerType.GetMethod(('InvokeRaw'+'Exact')).Invoke(`$null,@(`$authority,`$globalLock,`$null,`$targets)) | Out-Null",
    1)
$hiddenIssuerReflectionApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $hiddenIssuerReflectionApplyMutation)
Assert-TestCondition (-not $hiddenIssuerReflectionApplyMutationResult.Accepted -and
    $hiddenIssuerReflectionApplyMutationResult.AllScriptsReflectionSensitiveViolations.Count -eq 1 -and
    $hiddenIssuerReflectionApplyMutationResult.AllScriptsDynamicCommandMatches -and
    $hiddenIssuerReflectionApplyMutationResult.FixedCapabilityBoundaryViolations.Count -eq 0) 'mutation RED: all-scripts reflection inventory rejects assembly/type/method resolution with concatenated issuer names in production Apply'

$caseVariantIssuerReflectionApplyMutation=([regex]::new('(?m)^# Apply\r?$')).Replace(
    [string]$syncApplyModel.Text,
    "# Apply`n`$issuerType=`$null`nforeach(`$assembly in [aPpDoMaIn]::CurrentDomain.gEtAsSeMbLiEs()){`n    `$candidateType=`$assembly.gEtTyPe(('aiagentdotfiles.'+'sealedfixedinfrastructurecapabilityissuer'),`$false,`$true)`n    if(`$null -ne `$candidateType){`$issuerType=`$candidateType;break}`n}`n`$issuerType.gEtMeThOd(('iNvOkErAw'+'ExAcT')).iNvOkE(`$null,@(`$authority,`$globalLock,`$null,`$targets)) | Out-Null",
    1)
$caseVariantIssuerReflectionApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $caseVariantIssuerReflectionApplyMutation)
Assert-TestCondition (-not $caseVariantIssuerReflectionApplyMutationResult.Accepted -and
    $caseVariantIssuerReflectionApplyMutationResult.AllScriptsReflectionSensitiveViolations.Count -eq 1 -and
    $caseVariantIssuerReflectionApplyMutationResult.AllScriptsDynamicCommandMatches -and
    $caseVariantIssuerReflectionApplyMutationResult.FixedCapabilityBoundaryViolations.Count -eq 0) 'mutation RED: reflection inventory is case-insensitive to member spelling and rejects split lowercase issuer/method strings'

$propertyDispatchIssuerReflectionApplyMutation=([regex]::new('(?m)^# Apply\r?$')).Replace(
    "using namespace AiAgentDotfiles`n$([string]$syncApplyModel.Text)",
    "# Apply`n`$issuerType=[SealedFixedInfrastructureCapabilityIssuer]`n`$issuerMethod=`$issuerType.DeclaredMethods | Where-Object -Property Name -CEQ 'InvokeRawExact' | Select-Object -First 1`n`$issuerMethod | ForEach-Object -MemberName Invoke -ArgumentList @(`$null,[object[]]@(`$authority,`$globalLock,`$null,`$targets)) | Out-Null",
    1)
$propertyDispatchIssuerReflectionApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $propertyDispatchIssuerReflectionApplyMutation)
Assert-TestCondition (-not $propertyDispatchIssuerReflectionApplyMutationResult.Accepted -and
    $propertyDispatchIssuerReflectionApplyMutationResult.AllScriptsReflectionSensitiveViolations.Count -eq 1 -and
    $propertyDispatchIssuerReflectionApplyMutationResult.AllScriptsUsingStatementViolations.Count -eq 1 -and
    $propertyDispatchIssuerReflectionApplyMutationResult.AllScriptsTypeDefinitionViolations.Count -eq 0 -and
    $propertyDispatchIssuerReflectionApplyMutationResult.AllScriptsDynamicCommandMatches -and
    @($propertyDispatchIssuerReflectionApplyMutationResult.FixedCapabilityBoundaryViolations | Where-Object {
        $_ -ceq 'issuer type reflection or non-direct access: scripts/sync.ps1:<script>'
    }).Count -eq 1) 'mutation RED: using-namespace, short issuer type, property-only method discovery, and ForEach-Object member dispatch cannot bypass the all-scripts reflection guard'

$validatorApplyMutation=[regex]::Replace(
    [string]$syncApplyModel.Text,
    '(?m)^# Apply\r?$',
    "# Apply`nAssert-SealedFixedInfrastructureCapabilityEvidenceExact -Evidence `$evidence -AuthorityContext `$authority -ExpectedAuthorityContextHash `$a -ExpectedFixedEnvelopeHash `$f -ExpectedLockSecurityHash `$l -ControlBaseProbeRoot `$p1 -BackupRootProbeRoot `$p2",
    1)
$validatorApplyMutationResult=Invoke-ProductionSeamAnalysis -SourceModels (Copy-SourceModelsWithOverride -Models $sources -RelativePath $syncApplyModel.RelativePath -Text $validatorApplyMutation)
Assert-TestCondition (-not $validatorApplyMutationResult.Accepted -and
    @($validatorApplyMutationResult.FixedCapabilityBoundaryViolations | Where-Object {$_ -ceq 'fixed capability evidence validator caller: scripts/sync.ps1:<script>'}).Count -eq 1) 'mutation RED: fixed evidence validator has exactly one production caller inside fixed capture'

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:pass,$script:fail) -ForegroundColor Cyan
if($script:fail -ne 0){
    if($baseline.ParseFailures.Count -gt 0){Write-Host ($baseline.ParseFailures -join "`n") -ForegroundColor DarkRed}
    if($baseline.ForbiddenReferences.Count -gt 0){Write-Host ($baseline.ForbiddenReferences -join "`n") -ForegroundColor DarkRed}
    if($baseline.ResolutionFailures.Count -gt 0){Write-Host ($baseline.ResolutionFailures -join "`n") -ForegroundColor DarkRed}
    if($baseline.UnreviewedSeams.Count -gt 0){Write-Host ($baseline.UnreviewedSeams -join "`n") -ForegroundColor DarkRed}
    if($baseline.FixedCapabilityBoundaryViolations.Count -gt 0){Write-Host ($baseline.FixedCapabilityBoundaryViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.FixedObservationBoundaryViolations.Count -gt 0){Write-Host ($baseline.FixedObservationBoundaryViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsCommandQualificationViolations.Count -gt 0){Write-Host ($baseline.AllScriptsCommandQualificationViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsDynamicCommandViolations.Count -gt 0){Write-Host ($baseline.AllScriptsDynamicCommandViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsReflectionSensitiveViolations.Count -gt 0){Write-Host ($baseline.AllScriptsReflectionSensitiveViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsUsingStatementViolations.Count -gt 0){Write-Host ($baseline.AllScriptsUsingStatementViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsTypeDefinitionViolations.Count -gt 0){Write-Host ($baseline.AllScriptsTypeDefinitionViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsScriptBlockFunctionDefinitionViolations.Count -gt 0){Write-Host ($baseline.AllScriptsScriptBlockFunctionDefinitionViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsLiteralProviderDriveTokenViolations.Count -gt 0){Write-Host ($baseline.AllScriptsLiteralProviderDriveTokenViolations -join "`n") -ForegroundColor DarkRed}
    exit 1
}
