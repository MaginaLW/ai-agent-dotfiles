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
    $definitions=@{}

    foreach($model in $SourceModels){
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput([string]$model.Text,[string]$model.RelativePath,[ref]$tokens,[ref]$parseErrors)
        foreach($parseError in @($parseErrors)){$parseFailures.Add("$($model.RelativePath):$($parseError.Message)")}
        foreach($match in [regex]::Matches([string]$model.Text,$testsOnlyReferencePattern)){$forbiddenReferences.Add("$($model.RelativePath):$($match.Value)")}
        foreach($definition in @($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){
            $key=$definition.Name.ToLowerInvariant()
            if(-not $definitions.ContainsKey($key)){$definitions[$key]=[Collections.Generic.List[object]]::new()}
            $definitions[$key].Add([pscustomobject]@{Name=$definition.Name;RelativePath=[string]$model.RelativePath;Ast=$definition})
        }
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
    $accepted=($parseFailures.Count -eq 0 -and $forbiddenReferences.Count -eq 0 -and $resolutionFailures.Count -eq 0 -and $unreviewedSeams.Count -eq 0)
    return [pscustomobject]@{
        Accepted=$accepted;ParseFailures=@($parseFailures);ForbiddenReferences=@($forbiddenReferences)
        ResolutionFailures=@($resolutionFailures);UnreviewedSeams=@($unreviewedSeams);Closure=@($closureInventory)
        ClosureMatches=$closureMatches;ExceptionInventory=@($exceptionInventory);ExceptionMatches=$exceptionMatches;Definitions=$definitions
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
Assert-TestCondition $outOfClosureResult.Accepted 'acceptance control: an unrelated generic SafeTree ScriptBlock/dynamic API is not globally banned'

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

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:pass,$script:fail) -ForegroundColor Cyan
if($script:fail -ne 0){
    if($baseline.ParseFailures.Count -gt 0){Write-Host ($baseline.ParseFailures -join "`n") -ForegroundColor DarkRed}
    if($baseline.ForbiddenReferences.Count -gt 0){Write-Host ($baseline.ForbiddenReferences -join "`n") -ForegroundColor DarkRed}
    if($baseline.ResolutionFailures.Count -gt 0){Write-Host ($baseline.ResolutionFailures -join "`n") -ForegroundColor DarkRed}
    if($baseline.UnreviewedSeams.Count -gt 0){Write-Host ($baseline.UnreviewedSeams -join "`n") -ForegroundColor DarkRed}
    exit 1
}
