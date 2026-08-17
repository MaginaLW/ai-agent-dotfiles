#requires -Version 7.0

# This orchestration surface intentionally lives under tests/helpers. Phase 1
# production Apply remains interlocked; only an isolated test-suite process may
# use progress callbacks or a postcondition verifier.
if (-not (Get-Command Read-CanonicalTransactionPlan -ErrorAction SilentlyContinue)) {
    throw 'Load scripts/canonical-transaction-common.ps1 before the sealed test engine.'
}

function Invoke-SealedCanonicalReviewedSkillTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][ValidateSet('normalize','promote','merge')][string]$OperationKind,
        [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$TransactionId=([Guid]::NewGuid().ToString('D').ToLowerInvariant()),
        [string]$ToolchainRoot=$script:CanonicalToolchainRoot,
        [scriptblock]$InternalPostconditionVerifier,
        [scriptblock]$InternalProgressProvider
    )

    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot;$paths=Get-CanonicalTransactionContractPaths -GitContext $git
    $lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath
    $staging=$null;$headerPublished=$false;$namespace=$null
    try{
        if($InternalProgressProvider){&$InternalProgressProvider 'plan-read'}
        $document=Read-CanonicalTransactionPlan -PlanPath $PlanPath -RepoRoot $git.RepoRoot -ExpectedOperationKind $OperationKind -ToolchainRoot $ToolchainRoot
        if($InternalProgressProvider){&$InternalProgressProvider 'plan-current'}
        $null=Assert-CanonicalPlanCurrent -Document $document -PlanPath $PlanPath -ToolchainRoot $ToolchainRoot
        Assert-CanonicalTransactionSetAllowsDocument -TransactionsRoot $paths.TransactionsRoot -DocumentHash ([string]$document.DocumentHash)
        if($InternalProgressProvider){&$InternalProgressProvider 'setup-state'}
        $setup=Read-CanonicalReadySetupStateUnderLock -GitContext $git -ContractPaths $paths -ToolchainRoot $ToolchainRoot
        $namespace=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $TransactionId)
        $recovery=Join-Path ([string]$setup.CanonicalRecoveryRoot) (Join-Path $git.WorktreeId $TransactionId)
        $targets=@(New-CanonicalJournalTargetsFromPlan -PlanPayload $document.PlanPayload -RecoveryTransactionRoot $recovery)
        $header=[ordered]@{
            SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$TransactionId;CanonicalOperationKind=$OperationKind
            OriginalDocumentHash=[string]$document.DocumentHash;OriginalPlanHash=[string]$document.PlanHash;RepoId=[string]$setup.RepoId
            GitCommonDirHash=[string]$git.GitCommonDirHash;WorktreeId=[string]$git.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($namespace)
            RecoveryTransactionRoot=[string]$recovery;ExpectedPostconditionsHash=[string]$document.PlanPayload.ExpectedPostconditionsHash;Targets=$targets
        }
        if($InternalProgressProvider){&$InternalProgressProvider 'header'}
        $null=New-CanonicalJournalHeader -Document $header -TransactionNamespace $namespace;$headerPublished=$true
        if($InternalProgressProvider){&$InternalProgressProvider 'staging'}
        $staging=Initialize-CanonicalReviewedStaging -PlanPayload $document.PlanPayload -RecoveryTransactionRoot $recovery -Targets $targets
        if($InternalProgressProvider){&$InternalProgressProvider 'final-revalidation'}
        $null=Assert-CanonicalPlanCurrent -Document $document -PlanPath $PlanPath -ToolchainRoot $ToolchainRoot
        if($InternalProgressProvider){&$InternalProgressProvider 'preimages'}
        $null=Initialize-CanonicalTransactionPreimages -TransactionNamespace $namespace
        if($InternalProgressProvider){&$InternalProgressProvider 'mutations'}
        foreach($target in @($staging.Targets|Sort-Object{[long]$_.Order})){
            switch([string]$target.TargetKind){
                'parent-directory'{$null=Invoke-CanonicalParentDirectoryCreate -TransactionNamespace $namespace -Target $target;break}
                'directory'{$null=Invoke-CanonicalDirectoryReplacement -TransactionNamespace $namespace -Target $target;break}
                'file'{$null=Invoke-CanonicalFileReplacement -TransactionNamespace $namespace -Target $target;break}
            }
        }
        if($InternalProgressProvider){&$InternalProgressProvider 'postconditions'}
        $post=if($InternalPostconditionVerifier){&$InternalPostconditionVerifier $document.PlanPayload $TransactionId}else{Test-CanonicalCommittedPostconditions -PlanPayload $document.PlanPayload -TransactionId $TransactionId -ToolchainRoot $ToolchainRoot}
        if([string]$post.PostconditionsHash -cne [string]$document.PlanPayload.ExpectedPostconditionsHash){throw 'canonical postcondition verifier returned the wrong reviewed hash'}
        if($InternalProgressProvider){&$InternalProgressProvider 'commit-boundary'}
        $null=Add-CanonicalJournalRecord -TransactionNamespace $namespace -Phase POSTCONDITIONS_OK -Data ([ordered]@{PostconditionsHash=[string]$post.PostconditionsHash})
        if($InternalProgressProvider){&$InternalProgressProvider 'commit-result'}
        return Publish-CanonicalOriginalOutcome -TransactionNamespace $namespace -Outcome committed
    }catch{
        $original=$_
        if($InternalProgressProvider){&$InternalProgressProvider ("catch:"+$original.Exception.Message)}
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
                if($InternalProgressProvider){&$InternalProgressProvider 'rollback'}
                foreach($target in @($state.Header.Targets|Sort-Object{[long]$_.Order} -Descending)){
                    $current=Get-CanonicalJournalStateForAppend -TransactionNamespace $namespace
                    $reconciliation=Get-CanonicalTargetReconciliation -Target $target -Records @($current.Records)
                    Restore-CanonicalMutationTarget -Target $target -Reconciliation $reconciliation
                }
                if($InternalProgressProvider){&$InternalProgressProvider 'failed-restored-result'}
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
    }finally{Exit-CanonicalRepoLock -LockHandle $lock}
}
