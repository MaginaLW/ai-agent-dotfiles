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
    'ScriptBlockParameter|Test-SafeTreeEntryExcluded|scripts/safe-tree-walker.ps1|b8e0f3588dbcaeb83d768ba05a9e8ca7b61f7d9a7eac2e59e1de6362b57bf3f8'
) | Sort-Object

$reviewedAllScriptsDynamicCommandDigest='5113f059347b5b2a3de24a3d5b08e1a715d66858cfce6abfdbfc5d113183e4b4'
$reviewedAllScriptsReflectionSensitiveSiteCount=12270
$reviewedAllScriptsReflectionSensitiveDigest='0de1ed7c2bffb390dc9297fee1a57e5f974df3ab0a9afddafe04652196ecca20'
$reflectionSensitiveCommandNames=@(
    'Add-Type','Get-Command','Get-Member','Import-Module','Invoke-Command','Invoke-Expression',
    'New-Module','New-Object'
)
$memberDispatchCommandNames=@(
    '%','?','compare','ForEach-Object','Format-Custom','Format-List','Format-Table','Format-Wide',
    'group','Group-Object','measure','Measure-Object','select','Select-Object','sort','Sort-Object',
    'Where-Object'
)
$memberDispatchParameterNames=@('MemberName','ArgumentList','ExpandProperty','Property')
$reviewedIssuerInvocationInventory=@(
    'scripts/root-claims-registry-common.ps1|<script>|InitializeExact'
    'scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|InvokeProbeExact'
    'scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|IsExactIssuerToken'
    'scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|MatchesProbeExact'
    'scripts/root-claims-registry-common.ps1|Invoke-SealedHeldFixedInfrastructureCapabilityCapture|InvokeRawExact'
    'scripts/root-claims-registry-common.ps1|Invoke-SealedHeldFixedInfrastructureCapabilityCapture|MatchesRawExact'
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
    $rawCapabilityAllowedCallers=[Collections.Generic.List[string]]::new()
    $probeCapabilityAllowedCallers=[Collections.Generic.List[string]]::new()
    $validatorAllowedCallers=[Collections.Generic.List[string]]::new()
    $allScriptsDynamicCommandInventory=[Collections.Generic.List[string]]::new()
    $allScriptsDynamicCommandViolations=[Collections.Generic.List[string]]::new()
    $allScriptsReflectionSensitiveInventory=[Collections.Generic.List[string]]::new()
    $allScriptsReflectionSensitiveViolations=[Collections.Generic.List[string]]::new()
    $allScriptsUsingStatementInventory=[Collections.Generic.List[string]]::new()
    $allScriptsUsingStatementViolations=[Collections.Generic.List[string]]::new()
    $allScriptsTypeDefinitionInventory=[Collections.Generic.List[string]]::new()
    $allScriptsTypeDefinitionViolations=[Collections.Generic.List[string]]::new()
    $issuerInvocationInventory=[Collections.Generic.List[string]]::new()
    $definitions=@{}

    foreach($model in $SourceModels){
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput([string]$model.Text,[string]$model.RelativePath,[ref]$tokens,[ref]$parseErrors)
        foreach($parseError in @($parseErrors)){$parseFailures.Add("$($model.RelativePath):$($parseError.Message)")}
        foreach($match in [regex]::Matches([string]$model.Text,$testsOnlyReferencePattern)){$forbiddenReferences.Add("$($model.RelativePath):$($match.Value)")}
        foreach($command in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))){
            $commandName=$command.GetCommandName()
            $owner=Get-OwningFunctionDefinition -Node $command
            $ownerName=if($null -eq $owner){'<script>'}else{[string]$owner.Name}
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
            @(([string]$node.TypeName.FullName -split '\.'))[-1] -ieq 'SealedFixedInfrastructureCapabilityIssuer'
        },$true))){
            $owner=Get-OwningFunctionDefinition -Node $typeExpression
            $ownerName=if($null -eq $owner){'<script>'}else{[string]$owner.Name}
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
            $issuerSite="$($model.RelativePath)|$ownerName|$memberName"
            $issuerInvocationInventory.Add($issuerSite)
            if($issuerSite -cnotin $reviewedIssuerInvocationInventory){
                $fixedCapabilityBoundaryViolations.Add("unreviewed issuer member access: $issuerSite")
            }
            if($issuerSite -ceq 'scripts/root-claims-registry-common.ps1|Invoke-SealedHeldFixedInfrastructureCapabilityCapture|InvokeRawExact'){
                $rawCapabilityAllowedCallers.Add("$($model.RelativePath):$ownerName")
            }
            if($issuerSite -ceq 'scripts/root-claims-registry-common.ps1|Invoke-SealedHeldCapabilityPreflight|InvokeProbeExact'){
                $probeCapabilityAllowedCallers.Add("$($model.RelativePath):$ownerName")
            }
        }
        foreach($definition in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){
            $key=$definition.Name.ToLowerInvariant()
            if(-not $definitions.ContainsKey($key)){$definitions[$key]=[Collections.Generic.List[object]]::new()}
            $definitions[$key].Add([pscustomobject]@{Name=$definition.Name;RelativePath=[string]$model.RelativePath;Ast=$definition})
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
    $issuerInvocationInventory=@($issuerInvocationInventory | Sort-Object -CaseSensitive)
    if(($issuerInvocationInventory -join "`n") -cne ($reviewedIssuerInvocationInventory -join "`n")){
        $fixedCapabilityBoundaryViolations.Add('reviewed issuer owner/member invocation inventory changed')
    }

    $fixedCaptureDefinitions=@(if($definitions.ContainsKey('invoke-sealedheldfixedinfrastructurecapabilitycapture')){@($definitions['invoke-sealedheldfixedinfrastructurecapabilitycapture'])})
    if($fixedCaptureDefinitions.Count -ne 1 -or [string]$fixedCaptureDefinitions[0].RelativePath -cne 'scripts/root-claims-registry-common.ps1'){
        $fixedCapabilityBoundaryViolations.Add('fixed capability capture definition is missing, ambiguous, or outside root-claims-registry-common.ps1')
    }
    if($rawCapabilityAllowedCallers.Count -ne 1){
        $fixedCapabilityBoundaryViolations.Add("exact raw capability issuer allowed caller count is $($rawCapabilityAllowedCallers.Count), expected 1")
    }
    if($probeCapabilityAllowedCallers.Count -ne 1){
        $fixedCapabilityBoundaryViolations.Add("exact lower capability issuer allowed caller count is $($probeCapabilityAllowedCallers.Count), expected 1")
    }
    $validatorDefinitions=@(if($definitions.ContainsKey('assert-sealedfixedinfrastructurecapabilityevidenceexact')){@($definitions['assert-sealedfixedinfrastructurecapabilityevidenceexact'])})
    if($validatorDefinitions.Count -ne 1 -or [string]$validatorDefinitions[0].RelativePath -cne 'scripts/root-claims-registry-common.ps1'){
        $fixedCapabilityBoundaryViolations.Add('fixed capability evidence validator definition is missing, ambiguous, or outside root-claims-registry-common.ps1')
    }
    if($validatorAllowedCallers.Count -ne 1){
        $fixedCapabilityBoundaryViolations.Add("fixed capability evidence validator allowed caller count is $($validatorAllowedCallers.Count), expected 1")
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
            $commandName=$command.GetCommandName()
            if($null -eq $commandName){continue}
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
            $commandName=$node.GetCommandName()
            if($node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot){$unreviewedSeams.Add("reachable dot invocation: $($definition.Name):$($node.Extent.Text)")}
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
        $allScriptsDynamicCommandViolations.Count -eq 0 -and $allScriptsReflectionSensitiveViolations.Count -eq 0 -and
        $allScriptsUsingStatementViolations.Count -eq 0 -and $allScriptsTypeDefinitionViolations.Count -eq 0)
    return [pscustomobject]@{
        Accepted=$accepted;ParseFailures=@($parseFailures);ForbiddenReferences=@($forbiddenReferences)
        ResolutionFailures=@($resolutionFailures);UnreviewedSeams=@($unreviewedSeams);Closure=@($closureInventory)
        ClosureMatches=$closureMatches;ExceptionInventory=@($exceptionInventory);ExceptionMatches=$exceptionMatches;Definitions=$definitions
        FixedCapabilityBoundaryViolations=@($fixedCapabilityBoundaryViolations);RawCapabilityAllowedCallers=@($rawCapabilityAllowedCallers)
        ProbeCapabilityAllowedCallers=@($probeCapabilityAllowedCallers);ValidatorAllowedCallers=@($validatorAllowedCallers)
        AllScriptsDynamicCommandInventory=@($allScriptsDynamicCommandInventory)
        AllScriptsDynamicCommandDigest=$allScriptsDynamicCommandDigest
        AllScriptsDynamicCommandMatches=$allScriptsDynamicCommandMatches
        AllScriptsDynamicCommandViolations=@($allScriptsDynamicCommandViolations)
        AllScriptsReflectionSensitiveInventory=@($allScriptsReflectionSensitiveInventory)
        AllScriptsReflectionSensitiveDigest=$allScriptsReflectionSensitiveDigest
        AllScriptsReflectionSensitiveMatches=$allScriptsReflectionSensitiveMatches
        AllScriptsReflectionSensitiveViolations=@($allScriptsReflectionSensitiveViolations)
        AllScriptsUsingStatementInventory=@($allScriptsUsingStatementInventory)
        AllScriptsUsingStatementViolations=@($allScriptsUsingStatementViolations)
        AllScriptsTypeDefinitionInventory=@($allScriptsTypeDefinitionInventory)
        AllScriptsTypeDefinitionViolations=@($allScriptsTypeDefinitionViolations)
        IssuerInvocationInventory=@($issuerInvocationInventory)
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
Assert-TestCondition $baseline.AllScriptsReflectionSensitiveMatches 'all scripts/**/*.ps1 reflection and dynamic type/method-resolution sites match the compact reviewed count and digest'
Assert-TestCondition ($baseline.AllScriptsUsingStatementInventory.Count -eq 0 -and
    $baseline.AllScriptsUsingStatementViolations.Count -eq 0) 'all scripts/**/*.ps1 retain the reviewed zero using-statement baseline'
Assert-TestCondition ($baseline.AllScriptsTypeDefinitionInventory.Count -eq 0 -and
    $baseline.AllScriptsTypeDefinitionViolations.Count -eq 0) 'all scripts/**/*.ps1 retain the reviewed zero PowerShell type-definition baseline'
Assert-TestCondition ($baseline.FixedCapabilityBoundaryViolations.Count -eq 0) 'fixed capture is unconsumed; validator and exact raw/probe issuers have only their reviewed internal callers; issuer type/member inventory is exact'
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
    @($exactRawIssuerApplyMutationResult.FixedCapabilityBoundaryViolations | Where-Object {$_ -ceq 'unreviewed issuer member access: scripts/sync.ps1|<script>|iNvOkErAwExAcT'}).Count -eq 1) 'mutation RED: case variants of exact raw issuer invocation are accepted only inside the fixed capture function'

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
    if($baseline.AllScriptsDynamicCommandViolations.Count -gt 0){Write-Host ($baseline.AllScriptsDynamicCommandViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsReflectionSensitiveViolations.Count -gt 0){Write-Host ($baseline.AllScriptsReflectionSensitiveViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsUsingStatementViolations.Count -gt 0){Write-Host ($baseline.AllScriptsUsingStatementViolations -join "`n") -ForegroundColor DarkRed}
    if($baseline.AllScriptsTypeDefinitionViolations.Count -gt 0){Write-Host ($baseline.AllScriptsTypeDefinitionViolations -join "`n") -ForegroundColor DarkRed}
    exit 1
}
