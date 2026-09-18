#requires -Version 7.0

<#
.SYNOPSIS
    Production canonical Apply engines for the public transaction CLIs.

.DESCRIPTION
    These functions are the mutation bodies promoted from the sealed reviewed
    test engines. The public CLIs own every lock: the caller holds the repo
    lock and the sealed live lock order, and these engines never re-enter
    Enter-CanonicalRepoLock/Exit-CanonicalRepoLock, never touch the sealed
    live lock order, never call the private-root bootstrap Complete (its only
    production caller is the lock-order Enter), and expose no injectable
    progress, postcondition, failpoint, or stage-coordinator surface.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command Read-CanonicalTransactionPlan -ErrorAction SilentlyContinue)) {
    throw 'Load scripts/canonical-transaction-common.ps1 before the production canonical engine.'
}
if (-not (Get-Command Get-CanonicalTransactionRecoveryClassification -ErrorAction SilentlyContinue)) {
    throw 'Load scripts/canonical-recovery-common.ps1 before the production canonical engine.'
}

function Invoke-CanonicalProductionSkillTransaction {
    # Mutation body of the reviewed normalize/promote/merge transaction,
    # running entirely under the live lock order the caller holds.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][ValidateSet('normalize','promote','merge')][string]$OperationKind,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$TransactionId,
        [Parameter(Mandatory)]$Document,
        [string]$ToolchainRoot=$script:CanonicalToolchainRoot
    )

    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot;$paths=Get-CanonicalTransactionContractPaths -GitContext $git
    $staging=$null;$headerPublished=$false;$namespace=$null
    try{
        $null=Assert-CanonicalPlanCurrent -Document $Document -PlanPath $PlanPath -ToolchainRoot $ToolchainRoot
        Assert-CanonicalTransactionSetAllowsDocument -TransactionsRoot $paths.TransactionsRoot -DocumentHash ([string]$Document.DocumentHash)
        $setup=Read-CanonicalReadySetupStateUnderLock -GitContext $git -ContractPaths $paths -ToolchainRoot $ToolchainRoot
        $namespace=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $TransactionId)
        $recovery=Join-Path ([string]$setup.CanonicalRecoveryRoot) (Join-Path $git.WorktreeId $TransactionId)
        $targets=@(New-CanonicalJournalTargetsFromPlan -PlanPayload $Document.PlanPayload -RecoveryTransactionRoot $recovery)
        $header=[ordered]@{
            SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$TransactionId;CanonicalOperationKind=$OperationKind
            OriginalDocumentHash=[string]$Document.DocumentHash;OriginalPlanHash=[string]$Document.PlanHash;RepoId=[string]$setup.RepoId
            GitCommonDirHash=[string]$git.GitCommonDirHash;WorktreeId=[string]$git.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($namespace)
            RecoveryTransactionRoot=[string]$recovery;ExpectedPostconditionsHash=[string]$Document.PlanPayload.ExpectedPostconditionsHash;Targets=$targets
        }
        $null=New-CanonicalJournalHeader -Document $header -TransactionNamespace $namespace;$headerPublished=$true
        $staging=Initialize-CanonicalReviewedStaging -PlanPayload $Document.PlanPayload -RecoveryTransactionRoot $recovery -Targets $targets
        $null=Assert-CanonicalPlanCurrent -Document $Document -PlanPath $PlanPath -ToolchainRoot $ToolchainRoot
        $null=Initialize-CanonicalTransactionPreimages -TransactionNamespace $namespace
        foreach($target in @($staging.Targets|Sort-Object{[long]$_.Order})){
            switch([string]$target.TargetKind){
                'parent-directory'{$null=Invoke-CanonicalParentDirectoryCreate -TransactionNamespace $namespace -Target $target;break}
                'directory'{$null=Invoke-CanonicalDirectoryReplacement -TransactionNamespace $namespace -Target $target;break}
                'file'{$null=Invoke-CanonicalFileReplacement -TransactionNamespace $namespace -Target $target;break}
            }
        }
        $post=Test-CanonicalCommittedPostconditions -PlanPayload $Document.PlanPayload -TransactionId $TransactionId -ToolchainRoot $ToolchainRoot
        if([string]$post.PostconditionsHash -cne [string]$Document.PlanPayload.ExpectedPostconditionsHash){throw 'canonical postcondition verifier returned the wrong reviewed hash'}
        $null=Add-CanonicalJournalRecord -TransactionNamespace $namespace -Phase POSTCONDITIONS_OK -Data ([ordered]@{PostconditionsHash=[string]$post.PostconditionsHash})
        return Publish-CanonicalOriginalOutcome -TransactionNamespace $namespace -Outcome committed
    }catch{
        $original=$_
        if(-not $headerPublished){
            if($staging -and (Test-Path -LiteralPath $staging.RecoveryTransactionRoot)){Remove-Item -LiteralPath $staging.RecoveryTransactionRoot -Recurse -Force}
            throw $original
        }
        $state=$null
        try{$state=Get-CanonicalJournalStateForAppend -TransactionNamespace $namespace}catch{throw $original}
        if($state.IsTerminal){return $state}
        if(@($state.Records|Where-Object{[string]$_.Phase -ceq 'POSTCONDITIONS_OK'}).Count -gt 0){throw 'canonical-recovery-required'}
        $reconciliations=[Collections.Generic.List[object]]::new();$primitive=$false;$ambiguous=$false
        foreach($target in @($state.Header.Targets|Sort-Object{[long]$_.Order})){
            $reconciliation=Get-CanonicalTargetReconciliation -Target $target -Records @($state.Records)
            $reconciliations.Add([pscustomobject]@{Target=$target;Reconciliation=$reconciliation})
            if([string]$reconciliation.State -ceq 'AMBIGUOUS' -or $null -eq $reconciliation.PrimitiveOccurred){$ambiguous=$true}
            elseif([bool]$reconciliation.PrimitiveOccurred){$primitive=$true}
        }
        foreach($workspace in @(Get-CanonicalRecoveryWorkspaceReconciliation -State $state)){
            if([string]$workspace.ReconciledState -eq 'AMBIGUOUS'){$ambiguous=$true}
        }
        if($ambiguous){throw 'canonical-recovery-required'}
        try{
            if($primitive){
                foreach($target in @($state.Header.Targets|Sort-Object{[long]$_.Order} -Descending)){
                    $current=Get-CanonicalJournalStateForAppend -TransactionNamespace $namespace
                    $reconciliation=Get-CanonicalTargetReconciliation -Target $target -Records @($current.Records)
                    Restore-CanonicalMutationTarget -Target $target -Reconciliation $reconciliation
                }
                try{$null=Publish-CanonicalOriginalOutcome -TransactionNamespace $namespace -Outcome failed-restored}catch{
                    $published=Get-CanonicalJournalStateForAppend -TransactionNamespace $namespace
                    if(-not($published.IsTerminal -and [string]$published.Outcome -ceq 'failed-restored')){throw}
                }
                throw 'apply-failed-but-restored'
            }
            try{$null=Publish-CanonicalOriginalOutcome -TransactionNamespace $namespace -Outcome abandoned}catch{
                $published=Get-CanonicalJournalStateForAppend -TransactionNamespace $namespace
                if(-not($published.IsTerminal -and [string]$published.Outcome -ceq 'abandoned')){throw}
            }
            throw 'canonical-apply-failed-before-mutation'
        }catch{
            if($_.Exception.Message -in @('apply-failed-but-restored','canonical-apply-failed-before-mutation')){throw}
            throw 'canonical-recovery-required'
        }
    }
}

function Invoke-CanonicalProductionRecoveryTransaction {
    # Mutation body of the reviewed canonical recovery action, running under
    # the repo lock and live lock order the caller already holds.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $null=Assert-CanonicalRecoveryStateContext -State $State -RepoRoot $RepoRoot
    $action=[string]$Document.PlanPayload.PlannedAction
    $classification=Get-CanonicalTransactionRecoveryClassification -State $State -RepoRoot $RepoRoot
    if([string]$classification.AllowedAction -cne $action){throw 'canonical-recovery-action-mismatch'}
    if([string]$Document.DocumentHash -in @($State.ConsumedDocumentHashes)){throw 'reviewed-plan-consumed'}
    $null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase RECOVERY_ACTION_INTENT -Data ([ordered]@{
        PlanKind=[string]$Document.PlanPayload.PlanKind;DocumentHash=[string]$Document.DocumentHash;PriorHeadHash=[string]$State.DerivedJournalHeadHash;ExpectedOutcome=[string]$Document.PlanPayload.ExpectedOutcome;ExpectedTerminalProjectionHash=[string]$Document.PlanPayload.ExpectedTerminalProjectionHash
    })
    if($action -eq 'rollback'){
        $current=Get-CanonicalJournalStateForAppend -TransactionNamespace $State.TransactionNamespace
        foreach($target in @($current.Header.Targets|Sort-Object{[long]$_.Order} -Descending)){
            $reconciliation=Get-CanonicalTargetReconciliation -Target $target -Records @($current.Records)
            Restore-CanonicalMutationTarget -Target $target -Reconciliation $reconciliation
        }
    }elseif($action -eq 'finalize' -and [string]$State.Header.CanonicalOperationKind -ceq 'setup' -and $classification.PSObject.Properties['SetupState'] -and $classification.SetupState){
        $null=Publish-CanonicalSetupFinalStateForRecovery -State $State -Classification $classification
    }
    $null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase RECOVERY_ACTION_APPLIED -Data ([ordered]@{Action=$action;DocumentHash=[string]$Document.DocumentHash})
    $afterAction=Get-CanonicalJournalStateForAppend -TransactionNamespace $State.TransactionNamespace
    $null=Assert-CanonicalRecoveryOutcomeReady -State $afterAction -RepoRoot $RepoRoot -ExpectedOutcome ([string]$Document.PlanPayload.ExpectedOutcome)
    $result=$afterAction.Result
    if($result){
        $projection=Get-CanonicalTransactionResultProjection -Result $result
        if((Get-SemanticJsonHash -InputObject $projection) -cne [string]$Document.PlanPayload.ExpectedTerminalProjectionHash){throw 'manual-recovery-required: existing fixed result differs from reviewed projection'}
        $resultHash=[string]$afterAction.ResultHash
    }else{
        $projection=$Document.PlanPayload.ExpectedTerminalProjection
        $resultDocument=[ordered]@{}
        foreach($name in $projection.Keys){$resultDocument[$name]=$projection[$name]}
        $resultDocument.Insert(7,'ResultBaseHeadHash',[string]$afterAction.DerivedJournalHeadHash)
        $published=Publish-CanonicalTransactionResult -TransactionNamespace $State.TransactionNamespace -Document $resultDocument
        $resultHash=[string]$published.Hash
    }
    $beforeComplete=Get-CanonicalJournalStateForAppend -TransactionNamespace $State.TransactionNamespace
    $null=Assert-CanonicalRecoveryOutcomeReady -State $beforeComplete -RepoRoot $RepoRoot -ExpectedOutcome ([string]$Document.PlanPayload.ExpectedOutcome)
    $null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase COMPLETE -Data ([ordered]@{
        ResultHash=$resultHash;OriginalDocumentHash=[string]$State.Header.OriginalDocumentHash;Outcome=[string]$Document.PlanPayload.ExpectedOutcome
        ClosingKind='recovery';ClosingDocumentHash=[string]$Document.DocumentHash;ClosingPlanKind=[string]$Document.PlanPayload.PlanKind
    })
    return Read-CanonicalJournalDirectory -TransactionNamespace $State.TransactionNamespace
}

function Invoke-CanonicalProductionSetupTransaction {
    # Setup Apply durable tail under the held SetupBootstrap lock order: the
    # private-root bootstrap itself stays inside the lock-order Enter (this
    # function never calls it again), and the journal target manifest is read
    # from the handle the Enter attached. Publishes the root claim and the
    # final setup state under the journal, then closes the transaction.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$LockOrderHandle,
        [Parameter(Mandatory)]$Document
    )

    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
    $paths=Get-CanonicalTransactionContractPaths -GitContext $git
    $payload=$Document.PlanPayload
    $transactionId=[Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $namespace=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $transactionId)
    $recovery=Join-Path ([string]$payload.ExpectedSetupStateProjection.CanonicalRecoveryRoot) (Join-Path $git.WorktreeId $transactionId)
    $worktreeRecoveryRoot=Split-Path -Parent $recovery
    if(-not(Test-Path -LiteralPath $worktreeRecoveryRoot -PathType Container)){[IO.Directory]::CreateDirectory($worktreeRecoveryRoot)|Out-Null}
    [AiAgentDotfiles.CanonicalNativeMutation]::CreateDirectoryNoOverwrite($recovery)
    $header=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$transactionId;CanonicalOperationKind='setup'
        OriginalDocumentHash=[string]$Document.DocumentHash;OriginalPlanHash=[string]$Document.PlanHash;RepoId=[string]$payload.ExpectedSetupStateProjection.RepoId
        GitCommonDirHash=[string]$git.GitCommonDirHash;WorktreeId=[string]$git.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($namespace)
        RecoveryTransactionRoot=[IO.Path]::GetFullPath($recovery);ExpectedPostconditionsHash=[string]$payload.ExpectedPostconditionsHash;Targets=@()
        SetupRecovery=[ordered]@{
            ClaimPath=[string]$LockOrderHandle.JournalTargets.GlobalClaimPath
            StatePath=[string]$LockOrderHandle.JournalTargets.CanonicalSetupStatePath
            ExpectedClaim=$payload.ExpectedRootClaim
            ExpectedClaimHash=[string]$payload.ExpectedRootClaimHash
            ExpectedStateProjection=$payload.ExpectedSetupStateProjection
            ExpectedStateProjectionHash=[string]$payload.ExpectedSetupStateProjectionHash
        }
    }
    $null=New-CanonicalJournalHeader -Document $header -TransactionNamespace $namespace
    $state=Read-CanonicalJournalDirectory -TransactionNamespace $namespace -AllowUnfinished
    $null=Publish-CanonicalSetupClaimUnderJournal -State $state
    $state=Read-CanonicalJournalDirectory -TransactionNamespace $namespace -AllowUnfinished
    $classification=Get-CanonicalTransactionRecoveryClassification -State $state -RepoRoot $RepoRoot
    if([string]$classification.AllowedAction -cne 'finalize' -or -not($classification.PSObject.Properties['SetupState'] -and $classification.SetupState)){
        throw 'manual-recovery-required: setup finalize classification is unavailable after claim publication'
    }
    $null=Publish-CanonicalSetupFinalStateForRecovery -State $state -Classification $classification
    return (Publish-CanonicalOriginalOutcome -TransactionNamespace $namespace -Outcome committed)
}