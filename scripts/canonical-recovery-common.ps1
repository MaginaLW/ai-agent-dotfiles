#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-mutation-common.ps1')

$script:CanonicalRecoverySchemaPath=Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-recovery-plan.schema.json'

function Read-CanonicalReadySetupStateForRecovery {
    param([Parameter(Mandatory)]$GitContext,[Parameter(Mandatory)]$Paths)
    $state=Read-CanonicalJsonContractFile -Path $Paths.SetupStatePath -SchemaPath (Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-setup-state.schema.json')
    $repoId=Get-CanonicalRepoIdentity -GitContext $GitContext
    if([string]$state.GitCommonDirHash -cne [string]$GitContext.GitCommonDirHash -or [string]$state.RepoId -cne $repoId -or [string]$state.ClaimId -cne $repoId){throw 'canonical setup identity mismatch'}
    $securityTemplate=Get-CanonicalCurrentUserOnlySecurityTemplate;$templateHash=Get-SemanticJsonHash -InputObject $securityTemplate
    if([string]$state.OwnerSid -cne [string]$securityTemplate.OwnerSid -or [string]$state.SecurityResolverVersion -cne [string]$securityTemplate.ResolverVersion -or [string]$state.SecurityTemplateHash -cne $templateHash){throw 'canonical setup security template mismatch'}
    $contexts=Get-CanonicalSetupRootContexts -GitContext $GitContext -CanonicalRecoveryRoot ([string]$state.CanonicalRecoveryRoot) -ControlBase ([string]$state.ControlBase) -BackupRoot ([string]$state.BackupRoot)
    foreach($binding in @(
        [pscustomobject]@{Context=$contexts.Recovery;Intent=$state.CanonicalRecoveryRootIntent;IntentHash=[string]$state.CanonicalRecoveryRootIntentHash;Final=$state.CanonicalRecoveryRootFinalContext;FinalHash=[string]$state.CanonicalRecoveryRootFinalContextHash},
        [pscustomobject]@{Context=$contexts.Control;Intent=$state.ControlBaseIntent;IntentHash=[string]$state.ControlBaseIntentHash;Final=$state.ControlBaseFinalContext;FinalHash=[string]$state.ControlBaseFinalContextHash},
        [pscustomobject]@{Context=$contexts.Backup;Intent=$state.BackupRootIntent;IntentHash=[string]$state.BackupRootIntentHash;Final=$state.BackupRootFinalContext;FinalHash=[string]$state.BackupRootFinalContextHash}
    )){
        $actual=Get-CanonicalRootSecurityContext -TargetContext $binding.Context -SecurityTemplate $securityTemplate
        if((Get-CanonicalStableRootContextHash -Context $binding.Intent) -cne $binding.IntentHash -or [string]$binding.Final.TargetStatus -cne 'EXISTS' -or (Get-CanonicalStableRootContextHash -Context $binding.Final) -cne $binding.FinalHash -or (Get-CanonicalStableRootContextHash -Context $actual) -cne $binding.FinalHash){throw 'canonical setup root identity/owner/DACL mismatch'}
    }
    $projection=Get-CanonicalSetupStateProjection -State $state;$projectionHash=Get-SemanticJsonHash -InputObject $projection
    if($projectionHash -cne [string]$state.SetupStateProjectionHash){throw 'canonical setup projection mismatch'}
    $claimPath=Join-Path ([string]$state.ControlBase) (Join-Path 'canonical-roots' ($repoId+'.json'))
    $claim=Read-CanonicalJsonContractFile -Path $claimPath -SchemaPath (Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-root-claim.schema.json')
    if((Get-SemanticJsonHash -InputObject $claim) -cne [string]$state.RootClaimHash -or [string]$claim.ExpectedSetupStateProjectionHash -cne $projectionHash -or [string]$claim.SetupIntentHash -cne [string]$state.SetupIntentHash){throw 'canonical setup claim/state mismatch'}
    return $state
}

function Assert-CanonicalRecoveryStateContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot;$paths=Get-CanonicalTransactionContractPaths -GitContext $git
    if([string]$State.Header.GitCommonDirHash -cne [string]$git.GitCommonDirHash -or [string]$State.Header.RepoId -cne (Get-CanonicalRepoIdentity $git)){throw 'manual-recovery-required: journal repository context mismatch'}
    $expectedNamespace=[IO.Path]::GetFullPath((Join-Path $paths.TransactionsRoot (Join-Path ([string]$State.Header.WorktreeId) ([string]$State.Header.TransactionId))))
    if(-not([IO.Path]::GetFullPath([string]$State.TransactionNamespace).Equals($expectedNamespace,[StringComparison]::OrdinalIgnoreCase)) -or -not([IO.Path]::GetFullPath([string]$State.Header.TransactionNamespace).Equals($expectedNamespace,[StringComparison]::OrdinalIgnoreCase))){throw 'manual-recovery-required: journal transaction namespace locator mismatch'}
    if([string]$State.Header.CanonicalOperationKind -ceq 'setup'){
        $projection=$State.Header.SetupRecovery.ExpectedStateProjection
        $canonicalRoot=[string]$projection.CanonicalRecoveryRoot
        $expectedClaim=[IO.Path]::GetFullPath((Join-Path ([string]$projection.ControlBase) (Join-Path 'canonical-roots' ([string]$State.Header.RepoId+'.json'))))
        if(-not([IO.Path]::GetFullPath([string]$State.Header.SetupRecovery.ClaimPath).Equals($expectedClaim,[StringComparison]::OrdinalIgnoreCase)) -or -not([IO.Path]::GetFullPath([string]$State.Header.SetupRecovery.StatePath).Equals([IO.Path]::GetFullPath($paths.SetupStatePath),[StringComparison]::OrdinalIgnoreCase))){throw 'manual-recovery-required: setup claim/state locator mismatch'}
    }else{
        try{$setupState=Read-CanonicalReadySetupStateForRecovery -GitContext $git -Paths $paths}catch{throw "manual-recovery-required: $($_.Exception.Message)"}
        if([string]$setupState.RepoId -cne [string]$State.Header.RepoId -or [string]$setupState.GitCommonDirHash -cne [string]$State.Header.GitCommonDirHash){throw 'manual-recovery-required: journal differs from canonical setup identity'}
        $canonicalRoot=[string]$setupState.CanonicalRecoveryRoot
    }
    $expectedRecovery=[IO.Path]::GetFullPath((Join-Path $canonicalRoot (Join-Path ([string]$State.Header.WorktreeId) ([string]$State.Header.TransactionId))))
    if(-not([IO.Path]::GetFullPath([string]$State.Header.RecoveryTransactionRoot).Equals($expectedRecovery,[StringComparison]::OrdinalIgnoreCase))){throw 'manual-recovery-required: recovery transaction root differs from setup claim'}
    $targets=@($State.Header.Targets)
    $targetIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $targetPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $allowedParentPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $nonParentSeen=$false
    for($targetIndex=0;$targetIndex -lt $targets.Count;$targetIndex++){
        $target=$targets[$targetIndex]
        $id=[string]$target.TargetId
        $targetPath=[IO.Path]::GetFullPath([string]$target.TargetPath);$role=[string]$target.Role;$kind=[string]$target.TargetKind
        if([long]$target.Order -ne $targetIndex){throw 'manual-recovery-required: canonical target order is not unique and continuous'}
        if(-not $targetIds.Add($id) -or -not $targetPaths.Add($targetPath)){throw 'manual-recovery-required: canonical target id/path is duplicated'}
        if(-not(Test-SafePathInsideRoot -Path $targetPath -Root $git.RepoRoot)){throw 'manual-recovery-required: canonical target resolver rejects a target outside the current repository'}
        $platform=if(Test-CanonicalDataField -Data $target -Name 'Platform'){[string]$target.Platform}else{''}
        $expectedTargetId=Get-CanonicalJournalTargetId -Order ([long]$target.Order) -TargetKind $kind -Role $role -Platform $(if($platform){$platform}else{$null}) -TargetPath $targetPath
        if($id -cne $expectedTargetId){throw 'manual-recovery-required: canonical target id differs from its header projection'}
        $targetParent=[IO.Path]::GetFullPath((Split-Path -Parent $targetPath))
        $roleValid=switch($role){
            'canonical'{
                $parents=@('shared','claude-only','codex-only','reasonix-only')|ForEach-Object{[IO.Path]::GetFullPath((Join-Path $git.RepoRoot (Join-Path 'skills-source' $_)))}
                $kind -ceq 'directory' -and [string]::IsNullOrEmpty($platform) -and @($parents|Where-Object{$targetParent.Equals($_,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 1
                break
            }
            'generated'{
                $generated=@(
                    [pscustomobject]@{Platform='Claude';Parent=[IO.Path]::GetFullPath((Join-Path $git.RepoRoot 'claude/skills'))},
                    [pscustomobject]@{Platform='Codex';Parent=[IO.Path]::GetFullPath((Join-Path $git.RepoRoot 'codex/skills'))},
                    [pscustomobject]@{Platform='Reasonix';Parent=[IO.Path]::GetFullPath((Join-Path $git.RepoRoot 'reasonix/skills'))}
                )
                $kind -ceq 'directory' -and @($generated|Where-Object{$platform -ceq $_.Platform -and $targetParent.Equals($_.Parent,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 1
                break
            }
            'manifest'{
                $manifestPlatform=@{
                    'managed-skills.txt'='Union';'managed-skills.claude.txt'='Claude';'managed-skills.codex.txt'='Codex';'managed-skills.reasonix.txt'='Reasonix'
                }
                $name=[IO.Path]::GetFileName($targetPath)
                $kind -ceq 'file' -and $manifestPlatform.ContainsKey($name) -and $platform -ceq [string]$manifestPlatform[$name] -and $targetParent.Equals([IO.Path]::GetFullPath((Join-Path $git.RepoRoot 'manifests')),[StringComparison]::OrdinalIgnoreCase)
                break
            }
            'parent'{
                if($nonParentSeen){throw 'manual-recovery-required: canonical parent targets are not parent-first'}
                $kind -ceq 'parent-directory' -and [string]::IsNullOrEmpty($platform) -and [string]$target.Current.State -ceq 'MISSING'
                break
            }
            default{$false}
        }
        if(-not [bool]$roleValid){throw 'manual-recovery-required: canonical target role/path projection is not allowed'}
        if($role -cne 'parent'){
            $nonParentSeen=$true
            $ancestor=$targetParent
            while((Test-SafePathInsideRoot -Path $ancestor -Root $git.RepoRoot) -and -not $ancestor.Equals([IO.Path]::GetFullPath($git.RepoRoot),[StringComparison]::OrdinalIgnoreCase)){
                $null=$allowedParentPaths.Add($ancestor)
                $next=Split-Path -Parent $ancestor
                if([string]::IsNullOrWhiteSpace($next) -or $next -ceq $ancestor){break}
                $ancestor=[IO.Path]::GetFullPath($next)
            }
        }
        $expectedPreimage=[IO.Path]::GetFullPath((Join-Path $expectedRecovery (Join-Path 'preimage' $id)))
        $expectedSwap=[IO.Path]::GetFullPath((Join-Path $expectedRecovery (Join-Path 'swap-old' $id)))
        if(-not([IO.Path]::GetFullPath([string]$target.PreimagePath).Equals($expectedPreimage,[StringComparison]::OrdinalIgnoreCase)) -or -not([IO.Path]::GetFullPath([string]$target.SwapOldPath).Equals($expectedSwap,[StringComparison]::OrdinalIgnoreCase))){throw 'manual-recovery-required: target recovery paths differ from journal contract'}
        if($null -ne $target.StagedPath){
            $expectedStaged=[IO.Path]::GetFullPath((Join-Path $expectedRecovery (Join-Path 'staged' $id)))
            if(-not([IO.Path]::GetFullPath([string]$target.StagedPath).Equals($expectedStaged,[StringComparison]::OrdinalIgnoreCase))){throw 'manual-recovery-required: target staged path differs from journal contract'}
        }
        if(Test-SafePathInsideRoot -Path ([string]$target.TargetPath) -Root $expectedRecovery){throw 'manual-recovery-required: live target overlaps recovery workspace'}
    }
    foreach($parentTarget in @($targets|Where-Object{[string]$_.Role -ceq 'parent'})){
        if(-not $allowedParentPaths.Contains([IO.Path]::GetFullPath([string]$parentTarget.TargetPath))){throw 'manual-recovery-required: canonical parent target is not a required ancestor of an allowed target'}
    }
    $reconciliations=@{}
    foreach($target in $targets){
        $id=[string]$target.TargetId
        $records=@($State.Records|Where-Object{(Test-CanonicalDataField -Data $_.Data -Name 'TargetId') -and [string]$_.Data.TargetId -ceq $id})
        $reconciliation=Get-CanonicalTargetReconciliation -Target $target -Records $records
        $reconciliations[$id]=$reconciliation
        if([string]$reconciliation.State -in @('UNPREPARED','PRE_PRIMITIVE')){
            $createdAncestor=@($targets|Where-Object{
                [string]$_.Role -ceq 'parent' -and $reconciliations.ContainsKey([string]$_.TargetId) -and
                [string]$reconciliations[[string]$_.TargetId].State -ceq 'PARENT_CREATED' -and
                (Test-SafePathInsideRoot -Path ([string]$target.TargetPath) -Root ([string]$_.TargetPath))
            }).Count -gt 0
            if(-not $createdAncestor){
                $context=Resolve-TargetContext -Path ([string]$target.TargetPath) -Mode MetadataOnly
                # Bounded dual-read against the repo-local generated output
                # roots: the reviewed row may carry the projected plan digest
                # or the legacy whole-object digest.
                if([string]$context.RequestedInitialRootContextHash -cne [string]$target.TargetContextHash -and
                    (Get-CanonicalPlanTargetContextHash -TargetContext $context -ManagedOutputRoots (Get-CanonicalGeneratedOutputRoots -RepoRoot $git.RepoRoot)) -cne [string]$target.TargetContextHash){throw 'manual-recovery-required: target context hash differs from reviewed header'}
            }
        }
    }
    return $true
}

function Get-CanonicalUniqueTransactionState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TransactionsRoot,[Parameter(Mandatory)][string]$TransactionId)
    $matches=@(Get-CanonicalAllTransactionStates -TransactionsRoot $TransactionsRoot|Where-Object{[string]$_.Header.TransactionId -ceq $TransactionId})
    if($matches.Count -eq 0){throw 'canonical-transaction-not-found'}
    if($matches.Count -ne 1){throw 'manual-recovery-required: duplicate canonical TransactionId'}
    return $matches[0]
}

function Get-CanonicalRecordChainHash {
    param([Parameter(Mandatory)]$State)
    $rows=[System.Collections.Generic.List[object]]::new()
    $rows.Add([ordered]@{Kind='header';Sequence=0;Hash=[string]$State.HeaderHash})
    foreach($record in @($State.Records)){$rows.Add([ordered]@{Kind='record';Sequence=[long]$record.Sequence;Hash=(Get-SemanticJsonHash -InputObject $record)})}
    return Get-SemanticJsonHash -InputObject @($rows)
}

function Get-CanonicalRecoveryTargetEvidence {
    param([Parameter(Mandatory)]$State)
    $rows=[System.Collections.Generic.List[object]]::new()
    foreach($target in @($State.Header.Targets|Sort-Object{[long]$_.Order})){
        $reconciliation=Get-CanonicalTargetReconciliation -Target $target -Records @($State.Records)
        if([string]$reconciliation.State -ceq 'AMBIGUOUS'){throw 'manual-recovery-required: canonical target tuple is ambiguous'}
        $rows.Add([ordered]@{
            TargetId=[string]$target.TargetId;TargetKind=[string]$target.TargetKind;TargetPath=[string]$target.TargetPath
            PreimagePath=[string]$target.PreimagePath;SwapOldPath=[string]$target.SwapOldPath;StagedPath=$target.StagedPath
            ReconciledState=[string]$reconciliation.State;PrimitiveOccurred=[bool]$reconciliation.PrimitiveOccurred;Tuple=$reconciliation.Tuple
        })
    }
    return @($rows)
}

function Get-CanonicalSetupClaimFileSecurityTemplate {
    param([Parameter(Mandatory)]$State)
    if([string]$State.Header.CanonicalOperationKind -cne 'setup'){throw 'setup claim security requires a setup transaction'}
    $setup=$State.Header.SetupRecovery;$projection=$setup.ExpectedStateProjection;$claim=$setup.ExpectedClaim
    if((Get-SemanticJsonHash -InputObject $claim) -cne [string]$setup.ExpectedClaimHash -or
        (Get-SemanticJsonHash -InputObject $projection) -cne [string]$setup.ExpectedStateProjectionHash -or
        [string]$claim.ExpectedSetupStateProjectionHash -cne [string]$setup.ExpectedStateProjectionHash -or
        [string]$claim.OwnerSid -cne [string]$projection.OwnerSid -or
        [string]$claim.RepoId -cne [string]$State.Header.RepoId -or [string]$projection.RepoId -cne [string]$State.Header.RepoId){throw 'manual-recovery-required: setup claim security binding mismatch'}
    $expectedPath=[IO.Path]::GetFullPath((Join-Path ([string]$projection.ControlBase) (Join-Path 'canonical-roots' ([string]$State.Header.RepoId+'.json'))))
    if(-not([IO.Path]::GetFullPath([string]$setup.ClaimPath).Equals($expectedPath,[StringComparison]::OrdinalIgnoreCase))){throw 'manual-recovery-required: setup claim locator mismatch'}
    # This validates the journal-bound SID against the current token; it never
    # substitutes a different owner into an existing journal or claim.
    return Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid ([string]$projection.OwnerSid) -ResourceKind File
}

function Assert-CanonicalSetupClaimHeldSecurity {
    param([Parameter(Mandatory)]$HeldHandle,[Parameter(Mandatory)]$SecurityTemplate)
    $snapshot=[AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($HeldHandle)
    if([string]$snapshot.Identity -cne [string]$HeldHandle.Info.Identity -or [long]$snapshot.LinkCount -ne 1){throw 'manual-recovery-required: setup claim security identity changed'}
    $actual=Get-SemanticJsonHash -InputObject (ConvertFrom-HomeAuthoritySecuritySnapshot -Snapshot $snapshot -ResourceKind File)
    # Preserve the registry's accepted legacy shape: one inherited current-user
    # ACE beneath a sealed parent, including the token-default-owner variant.
    $inherited=[ordered]@{
        ResolverVersion=[string]$SecurityTemplate.ResolverVersion;ResourceKind='File';OwnerSid=[string]$SecurityTemplate.OwnerSid;AreAccessRulesProtected=$false
        AccessRules=@([ordered]@{Sid=[string]$SecurityTemplate.OwnerSid;AccessControlType=[long][Security.AccessControl.AccessControlType]::Allow;FileSystemRights=[long][Security.AccessControl.FileSystemRights]::FullControl;InheritanceFlags=[long]0;PropagationFlags=[long]0;IsInherited=$true})
    }
    $defaultOwner=Get-HomeAuthorityTokenDefaultOwnerSid
    foreach($allowed in @($SecurityTemplate,$inherited,(Copy-HomeAuthoritySecurityTemplateWithOwner -SecurityTemplate $SecurityTemplate -OwnerSid $defaultOwner),(Copy-HomeAuthoritySecurityTemplateWithOwner -SecurityTemplate $inherited -OwnerSid $defaultOwner))){
        if($actual -ceq (Get-SemanticJsonHash -InputObject $allowed)){return}
    }
    throw 'manual-recovery-required: setup claim owner/DACL is not current-user-only'
}

function Read-CanonicalSetupClaimHeldDocument {
    param([Parameter(Mandatory)]$HeldHandle,[Parameter(Mandatory)]$State,[Parameter(Mandatory)]$SecurityTemplate,[Parameter(Mandatory)][string]$Path)
    Assert-CanonicalSetupClaimHeldSecurity -HeldHandle $HeldHandle -SecurityTemplate $SecurityTemplate
    $bytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($HeldHandle,$script:JsonArtifactMaximumBytes)
    $null=Invoke-CanonicalContractSchemaValidation -SchemaPath (Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-root-claim.schema.json') -Path $Path -ContentBytes $bytes
    $document=ConvertFrom-SemanticJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
    if((Get-SemanticJsonHash -InputObject $document) -cne [string]$State.Header.SetupRecovery.ExpectedClaimHash){throw 'manual-recovery-required: setup claim differs from journal intent'}
    Assert-CanonicalSetupClaimHeldSecurity -HeldHandle $HeldHandle -SecurityTemplate $SecurityTemplate
    return $document
}

function Read-CanonicalSetupClaimArtifact {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$Path,[switch]$PublishPending)
    $template=Get-CanonicalSetupClaimFileSecurityTemplate -State $State
    $setup=$State.Header.SetupRecovery
    $claimPath=[IO.Path]::GetFullPath([string]$setup.ClaimPath)
    $expectedPath=[IO.Path]::GetFullPath((Join-Path ([string]$setup.ExpectedStateProjection.ControlBase) (Join-Path 'canonical-roots' ([string]$State.Header.RepoId+'.json'))))
    if(-not $claimPath.Equals($expectedPath,[StringComparison]::OrdinalIgnoreCase)){throw 'manual-recovery-required: setup claim locator mismatch'}
    $full=[IO.Path]::GetFullPath($Path);$isPending=-not $full.Equals($claimPath,[StringComparison]::OrdinalIgnoreCase)
    if($PublishPending -and -not $isPending){throw 'manual-recovery-required: setup pending claim locator required'}
    if($isPending){
        $pendingRoot=[IO.Path]::GetFullPath((Join-Path $State.TransactionNamespace '_pending'))
        $pending=@($State.PendingEntries|Where-Object{[string]$_.Name -like 'setup-claim-*'})
        $records=@($State.Records|Where-Object{[string]$_.Phase -in @('SETUP_CLAIM_INTENT','SETUP_CLAIM_PUBLISHED')})
        if(-not([IO.Path]::GetDirectoryName($full).Equals($pendingRoot,[StringComparison]::OrdinalIgnoreCase)) -or
            [IO.Path]::GetFileName($full) -cnotmatch '^setup-claim-[0-9a-f]{32}\.tmp$' -or $pending.Count -ne 1 -or
            -not([IO.Path]::GetFullPath([string]$pending[0].Path).Equals($full,[StringComparison]::OrdinalIgnoreCase)) -or
            $records.Count -ne 1 -or [string]$records[0].Phase -cne 'SETUP_CLAIM_INTENT' -or
            [string]$records[0].Data.ClaimHash -cne [string]$setup.ExpectedClaimHash){throw 'manual-recovery-required: setup pending claim differs from its unique journal intent'}
    }
    $parents=$null;$finalParents=$null;$held=$null
    try{
        $receiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path ([IO.Path]::GetDirectoryName($full)) -OwnershipReceiver $receiver
        $parents=$receiver.GetDeliveredExact();$parent=$parents[$parents.Count-1];$name=[IO.Path]::GetFileName($full)
        if($isPending){
            $names=@([AiAgentDotfiles.NoFollowFile]::GetChildNames($parent)|Where-Object{$_ -like 'setup-claim-*'})
            if($names.Count -ne 1 -or [string]$names[0] -cne $name){throw 'manual-recovery-required: setup pending claim inventory changed'}
        }
        $held=if($PublishPending){[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFileForRename($parent,$name)}else{[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($parent,$name)}
        if($isPending -and ([string]$held.ReadResult.Identity -cne [string]$pending[0].Identity -or [string]$held.ReadResult.Sha256 -cne [string]$pending[0].Sha256 -or [long]$held.ReadResult.Length -ne [long]$pending[0].Length)){throw 'manual-recovery-required: setup pending claim differs from its captured inventory'}
        $document=Read-CanonicalSetupClaimHeldDocument -HeldHandle $held -State $State -SecurityTemplate $template -Path $full
        if($PublishPending){
            $finalReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
            Open-SafeDirectoryContainmentChain -Path ([IO.Path]::GetDirectoryName($claimPath)) -OwnershipReceiver $finalReceiver
            $finalParents=$finalReceiver.GetDeliveredExact()
            $names=@([AiAgentDotfiles.NoFollowFile]::GetChildNames($parent)|Where-Object{$_ -like 'setup-claim-*'})
            if($names.Count -ne 1 -or [string]$names[0] -cne $name){throw 'manual-recovery-required: setup pending claim inventory changed before publish'}
            Assert-CanonicalSetupClaimHeldSecurity -HeldHandle $held -SecurityTemplate $template
            $null=[AiAgentDotfiles.NoFollowFile]::RenameHeldRegularFileNoReplace($held,$finalParents[$finalParents.Count-1],[IO.Path]::GetFileName($claimPath))
            $document=Read-CanonicalSetupClaimHeldDocument -HeldHandle $held -State $State -SecurityTemplate $template -Path $claimPath
        }
        return $document
    }finally{
        if($held){$held.Dispose()}
        if($finalParents){Close-SafeDirectoryContainmentChain -Handles $finalParents}
        if($parents){Close-SafeDirectoryContainmentChain -Handles $parents}
    }
}

function Get-CanonicalSetupRecoveryState {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$RepoRoot)
    $setup=$State.Header.SetupRecovery
    $claimPath=[string]$setup.ClaimPath;$statePath=[string]$setup.StatePath
    $claimExists=Test-Path -LiteralPath $claimPath -PathType Leaf
    $stateExists=Test-Path -LiteralPath $statePath -PathType Leaf
    $pendingClaims=@($State.PendingEntries|Where-Object{[string]$_.Name -like 'setup-claim-*'})
    $pendingStates=@($State.PendingEntries|Where-Object{[string]$_.Name -like 'setup-state-*'})
    $claimRecords=@($State.Records|Where-Object{[string]$_.Phase -in @('SETUP_CLAIM_INTENT','SETUP_CLAIM_PUBLISHED')})
    if($pendingClaims.Count -gt 1 -or ($pendingClaims.Count -eq 1 -and $claimExists)){return [pscustomobject][ordered]@{Classification='manual';Reason='setup-claim-pending-ambiguous'}}
    if($pendingStates.Count -gt 1 -or ($pendingStates.Count -eq 1 -and $stateExists)){return [pscustomobject][ordered]@{Classification='manual';Reason='setup-state-pending-ambiguous'}}
    if($pendingClaims.Count -eq 1 -and $pendingStates.Count -eq 1){return [pscustomobject][ordered]@{Classification='manual';Reason='setup-claim-and-state-pending-ambiguous'}}
    if($pendingClaims.Count -eq 1 -and ($claimRecords.Count -ne 1 -or [string]$claimRecords[0].Phase -cne 'SETUP_CLAIM_INTENT')){return [pscustomobject][ordered]@{Classification='manual';Reason='setup-claim-pending-without-exact-intent'}}
    if($pendingStates.Count -eq 1 -and -not $claimExists -and $pendingClaims.Count -eq 0){return [pscustomobject][ordered]@{Classification='manual';Reason='setup-state-pending-without-claim'}}
    if($stateExists -and -not $claimExists){return [pscustomobject][ordered]@{Classification='manual';Reason='setup-state-without-claim'}}
    if(-not $claimExists -and $pendingClaims.Count -eq 0 -and -not $stateExists){return [pscustomobject][ordered]@{Classification='abandon';Reason='zero-claim-state-primitive'}}
    try{
        $claimReadPath=if($claimExists){$claimPath}else{[string]$pendingClaims[0].Path}
        $claim=Read-CanonicalSetupClaimArtifact -State $State -Path $claimReadPath
        if((Get-SemanticJsonHash -InputObject $claim) -cne [string]$setup.ExpectedClaimHash -or (Get-SemanticJsonHash -InputObject $claim) -cne (Get-SemanticJsonHash -InputObject $setup.ExpectedClaim)){throw 'setup claim mismatch'}
        $projection=$setup.ExpectedStateProjection
        if((Get-SemanticJsonHash -InputObject $projection) -cne [string]$setup.ExpectedStateProjectionHash){throw 'setup projection mismatch'}
        $bootstrap=[ordered]@{
            OwnerSid=[string]$projection.OwnerSid;SecurityResolverVersion=[string]$projection.SecurityResolverVersion;SecurityTemplateHash=[string]$projection.SecurityTemplateHash
            CanonicalRecoveryRootIntent=$projection.CanonicalRecoveryRootIntent;CanonicalRecoveryRootIntentHash=[string]$projection.CanonicalRecoveryRootIntentHash
            ControlBaseIntent=$projection.ControlBaseIntent;ControlBaseIntentHash=[string]$projection.ControlBaseIntentHash
            BackupRootIntent=$projection.BackupRootIntent;BackupRootIntentHash=[string]$projection.BackupRootIntentHash
        }
        if((Get-SemanticJsonHash -InputObject $bootstrap) -cne [string]$projection.SetupIntentHash){throw 'setup intent mismatch'}
        $planPayload=[ordered]@{
            OperationKind='setup';ExpectedSetupStateProjection=$projection;ExpectedSetupStateProjectionHash=[string]$setup.ExpectedStateProjectionHash
            PrivateRootBootstrapIntent=$bootstrap;SetupIntentHash=[string]$projection.SetupIntentHash;ExpectedRootClaim=$setup.ExpectedClaim;ExpectedRootClaimHash=[string]$setup.ExpectedClaimHash
        }
        $expectedFinal=New-CanonicalFinalSetupState -PlanPayload $planPayload -RepoRoot $RepoRoot
        $expectedFinalHash=Get-SemanticJsonHash -InputObject $expectedFinal
        if(-not $stateExists){
            if($pendingStates.Count -eq 1){
                $pending=Read-CanonicalJsonContractFile -Path ([string]$pendingStates[0].Path) -SchemaPath (Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-setup-state.schema.json')
                if((Get-SemanticJsonHash -InputObject $pending) -cne $expectedFinalHash){throw 'setup pending state mismatch'}
                return [pscustomobject][ordered]@{Classification='finalize';Reason='claim-present-state-pending';ExpectedFinalState=$expectedFinal;ExpectedFinalStateHash=$expectedFinalHash;PendingClaimPath=if($claimExists){$null}else{[string]$pendingClaims[0].Path};PendingStatePath=[string]$pendingStates[0].Path}
            }
            return [pscustomobject][ordered]@{Classification='finalize';Reason=if($claimExists){'claim-present-state-missing'}else{'claim-pending-state-missing'};ExpectedFinalState=$expectedFinal;ExpectedFinalStateHash=$expectedFinalHash;PendingClaimPath=if($claimExists){$null}else{[string]$pendingClaims[0].Path}}
        }
        $actualState=Read-CanonicalJsonContractFile -Path $statePath -SchemaPath (Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-setup-state.schema.json')
        if((Get-SemanticJsonHash -InputObject $actualState) -cne $expectedFinalHash){throw 'setup final state mismatch'}
        return [pscustomobject][ordered]@{Classification='finalize';Reason='claim-state-present-terminal-missing';ExpectedFinalState=$expectedFinal;ExpectedFinalStateHash=$expectedFinalHash}
    }catch{return [pscustomobject][ordered]@{Classification='manual';Reason=$_.Exception.Message}}
}

function Get-CanonicalTransactionRecoveryClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$RepoRoot)
    if($State.IsTerminal){return [pscustomobject][ordered]@{Status='terminal';AllowedAction=$null;ExpectedOutcome=[string]$State.Outcome;Reason='terminal-complete'}}
    $workspace=try{@(Get-CanonicalRecoveryWorkspaceReconciliation -State $State)}catch{return [pscustomobject][ordered]@{Status='manual';AllowedAction=$null;ExpectedOutcome=$null;Reason=$_.Exception.Message}}
    if(@($workspace|Where-Object{[string]$_.ReconciledState -ceq 'AMBIGUOUS'}).Count -gt 0){return [pscustomobject][ordered]@{Status='manual';AllowedAction=$null;ExpectedOutcome=$null;Reason='recovery-workspace-ambiguous'}}
    if(@($State.PendingEntries|Where-Object{$_.Name -like 'result-*'}).Count -gt 0){return [pscustomobject][ordered]@{Status='manual';AllowedAction=$null;ExpectedOutcome=$null;Reason='pending-result-ambiguous'}}
    if($State.Result){
        $outcome=[string]$State.Result.Outcome
        if([string]$State.Header.CanonicalOperationKind -ceq 'setup'){
            $setup=Get-CanonicalSetupRecoveryState -State $State -RepoRoot $RepoRoot
            $valid=($outcome -ceq 'committed' -and [string]$setup.Classification -ceq 'finalize' -and [string]$setup.Reason -ceq 'claim-state-present-terminal-missing') -or ($outcome -ceq 'abandoned' -and [string]$setup.Classification -ceq 'abandon')
            if(-not $valid){return [pscustomobject][ordered]@{Status='manual';AllowedAction=$null;ExpectedOutcome=$null;Reason='fixed-setup-result-final-state-mismatch'}}
        }else{
            $targets=try{Get-CanonicalRecoveryTargetEvidence -State $State}catch{return [pscustomobject][ordered]@{Status='manual';AllowedAction=$null;ExpectedOutcome=$null;Reason=$_.Exception.Message}}
            $primitiveHistory=@($State.Records|Where-Object{
                [string]$_.Phase -in @('DIR_CREATED','NEW_INSTALLED','FILE_REPLACED') -or
                ([string]$_.Phase -ceq 'OLD_MOVED' -and [string]$_.Data.SwapOldState.State -ceq 'PRESENT')
            }).Count -gt 0
            $reviewedRollbackHistory=$false
            if($State.Result){
                $projectionHash=Get-SemanticJsonHash -InputObject (Get-CanonicalTransactionResultProjection -Result $State.Result)
                $hashes=[Collections.Generic.List[string]]::new();$hashes.Add([string]$State.HeaderHash)
                foreach($record in @($State.Records|Sort-Object{[long]$_.Sequence})){$hashes.Add((Get-SemanticJsonHash -InputObject $record))}
                $baseIndex=$hashes.IndexOf([string]$State.Result.ResultBaseHeadHash)
                if($baseIndex -ge 0){
                    $reviewedRollbackHistory=@($State.Records|Where-Object{
                        [long]$_.Sequence -le $baseIndex -and [string]$_.Phase -ceq 'RECOVERY_ACTION_INTENT' -and
                        [string]$_.Data.PlanKind -ceq 'canonical-recover-rollback' -and [string]$_.Data.ExpectedOutcome -ceq $outcome -and
                        [string]$_.Data.ExpectedTerminalProjectionHash -ceq $projectionHash
                    }).Count -gt 0
                }
            }
            $valid=switch($outcome){
                'committed'{@($targets|Where-Object{[string]$_.ReconciledState -notin @('NEW_INSTALLED','PARENT_CREATED')}).Count -eq 0 -and @($State.Records|Where-Object{[string]$_.Phase -ceq 'POSTCONDITIONS_OK'}).Count -eq 1;break}
                'abandoned'{-not $primitiveHistory -and @($targets|Where-Object{[string]$_.ReconciledState -notin @('UNPREPARED','PRE_PRIMITIVE')}).Count -eq 0;break}
                {$_ -in @('rolled-back','failed-restored')}{($primitiveHistory -or $reviewedRollbackHistory) -and @($targets|Where-Object{[string]$_.ReconciledState -notin @('UNPREPARED','PRE_PRIMITIVE')}).Count -eq 0;break}
                default{$false}
            }
            if(-not $valid){return [pscustomobject][ordered]@{Status='manual';AllowedAction=$null;ExpectedOutcome=$null;Reason='fixed-result-final-tuple-mismatch'}}
        }
        return [pscustomobject][ordered]@{Status='recovery';AllowedAction='finalize';ExpectedOutcome=$outcome;Reason='fixed-result-terminal-missing'}
    }
    if([string]$State.Header.CanonicalOperationKind -ceq 'setup'){
        $setup=Get-CanonicalSetupRecoveryState -State $State -RepoRoot $RepoRoot
        if([string]$setup.Classification -ceq 'manual'){return [pscustomobject][ordered]@{Status='manual';AllowedAction=$null;ExpectedOutcome=$null;Reason=[string]$setup.Reason}}
        $outcome=if([string]$setup.Classification -ceq 'abandon'){'abandoned'}else{'committed'}
        return [pscustomobject][ordered]@{Status='recovery';AllowedAction=[string]$setup.Classification;ExpectedOutcome=$outcome;Reason=[string]$setup.Reason;SetupState=$setup}
    }
    $targets=try{Get-CanonicalRecoveryTargetEvidence -State $State}catch{return [pscustomobject][ordered]@{Status='manual';AllowedAction=$null;ExpectedOutcome=$null;Reason=$_.Exception.Message}}
    if(@($State.PendingEntries).Count -gt 0){return [pscustomobject][ordered]@{Status='manual';AllowedAction=$null;ExpectedOutcome=$null;Reason='pending-artifact-requires-manual-reconciliation'}}
    $postconditions=@($State.Records|Where-Object{[string]$_.Phase -ceq 'POSTCONDITIONS_OK'})
    if($postconditions.Count -gt 0){return [pscustomobject][ordered]@{Status='recovery';AllowedAction='finalize';ExpectedOutcome='committed';Reason='postconditions-ok-terminal-missing';Targets=$targets}}
    $lastIntent=@($State.Records|Where-Object{[string]$_.Phase -ceq 'RECOVERY_ACTION_INTENT'}|Select-Object -Last 1)
    $anyPrimitive=@($targets|Where-Object{$_.PrimitiveOccurred}).Count -gt 0
    if($lastIntent.Count -eq 1){
        $intentAction=([string]$lastIntent[0].Data.PlanKind).Substring('canonical-recover-'.Length)
        $intentOutcome=[string]$lastIntent[0].Data.ExpectedOutcome
        if($intentAction -eq 'abandon' -and -not $anyPrimitive -and $intentOutcome -ceq 'abandoned'){return [pscustomobject][ordered]@{Status='recovery';AllowedAction='finalize';ExpectedOutcome=$intentOutcome;Reason='prior-abandon-action-awaits-terminal';Targets=$targets}}
        if($intentAction -eq 'rollback' -and -not $anyPrimitive -and $intentOutcome -in @('rolled-back','failed-restored')){return [pscustomobject][ordered]@{Status='recovery';AllowedAction='finalize';ExpectedOutcome=$intentOutcome;Reason='prior-rollback-action-awaits-terminal';Targets=$targets}}
        if($intentAction -eq 'finalize'){return [pscustomobject][ordered]@{Status='recovery';AllowedAction='finalize';ExpectedOutcome=$intentOutcome;Reason='prior-finalize-action-awaits-terminal';Targets=$targets}}
    }
    if($anyPrimitive){return [pscustomobject][ordered]@{Status='recovery';AllowedAction='rollback';ExpectedOutcome='rolled-back';Reason='target-primitive-observed';Targets=$targets}}
    return [pscustomobject][ordered]@{Status='recovery';AllowedAction='abandon';ExpectedOutcome='abandoned';Reason='zero-target-primitive';Targets=$targets}
}

function Get-CanonicalArtifactStatesForRecovery {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$Outcome)
    return @(Get-CanonicalJournalExpectedArtifactStates -Header $State.Header -Records @($State.Records) -Outcome $Outcome)
}

function New-CanonicalExpectedTransactionResultProjection {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)]$Classification)
    $outcome=[string]$Classification.ExpectedOutcome
    $setupFinalStateHash=$null
    if($outcome -ceq 'committed' -and [string]$State.Header.CanonicalOperationKind -ceq 'setup' -and $Classification.PSObject.Properties['SetupState'] -and $Classification.SetupState.ExpectedFinalStateHash){
        $setupFinalStateHash=[string]$Classification.SetupState.ExpectedFinalStateHash
    }
    return Get-CanonicalJournalExpectedTransactionResultProjection -Header $State.Header -Records @($State.Records) -SetupFinalStateHash $setupFinalStateHash -Outcome $outcome
}

function Get-CanonicalTransactionResultProjection {
    param([Parameter(Mandatory)]$Result)
    $projection=[ordered]@{}
    foreach($name in @('SchemaVersion','ArtifactKind','ResultScope','Result','TransactionId','CanonicalOperationKind','OriginalDocumentHash','Outcome','PlanHash','PostconditionsHash','RestorationHash','FinalStateHash','ArtifactStates')){
        if(Test-CanonicalDataField -Data $Result -Name $name){$projection[$name]=$Result.$name}
    }
    return $projection
}

function Get-CanonicalRecoveryEvidencePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('abandon','rollback','finalize')][string]$Action,
        [string]$ToolchainRoot=$script:CanonicalToolchainRoot
    )
    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
    $null=Assert-CanonicalRecoveryStateContext -State $State -RepoRoot $git.RepoRoot
    $classification=Get-CanonicalTransactionRecoveryClassification -State $State -RepoRoot $git.RepoRoot
    if([string]$classification.Status -eq 'terminal'){throw 'reviewed-plan-consumed'}
    if([string]$classification.Status -eq 'manual'){throw "manual-recovery-required: $($classification.Reason)"}
    if([string]$classification.AllowedAction -cne $Action){throw "canonical-recovery-action-mismatch: only $($classification.AllowedAction) is legal"}
    $targets=Get-CanonicalRecoveryTargetEvidence -State $State
    $workspace=@(Get-CanonicalRecoveryWorkspaceReconciliation -State $State)
    if(@($workspace|Where-Object{[string]$_.ReconciledState -ceq 'AMBIGUOUS'}).Count -gt 0){throw 'manual-recovery-required: recovery workspace is ambiguous'}
    $resultState=if($State.Result){[ordered]@{State='PRESENT';Hash=[string]$State.ResultHash;Outcome=[string]$State.Result.Outcome}}else{[ordered]@{State='MISSING'}}
    $projection=if($State.Result){Get-CanonicalTransactionResultProjection -Result $State.Result}else{New-CanonicalExpectedTransactionResultProjection -State $State -Classification $classification}
    $currentContext=[ordered]@{
        GitCommonDirHash=[string]$git.GitCommonDirHash;RepositoryCommit=[string]$git.RepositoryCommit;ToolchainPolicyHash=Get-CanonicalToolchainPolicyHash -ToolchainRoot $ToolchainRoot
        HeaderHash=[string]$State.HeaderHash;DerivedJournalHeadHash=[string]$State.DerivedJournalHeadHash;RecordChainHash=Get-CanonicalRecordChainHash -State $State
        PendingInventory=@($State.PendingEntries);WorkspaceInventory=@($workspace);ResultState=$resultState;Targets=@($targets)
    }
    return [ordered]@{
        SchemaVersion=1;PlanKind="canonical-recover-$Action";PlannedAction=$Action;RepoRoot=[string]$git.RepoRoot;GitCommonDirHash=[string]$git.GitCommonDirHash
        RepositoryCommit=[string]$git.RepositoryCommit;ToolchainPolicyHash=[string]$currentContext.ToolchainPolicyHash;TransactionId=[string]$State.Header.TransactionId
        SourceWorktreeId=[string]$State.Header.WorktreeId;TransactionNamespace=[string]$State.TransactionNamespace;CanonicalOperationKind=[string]$State.Header.CanonicalOperationKind
        OriginalDocumentHash=[string]$State.Header.OriginalDocumentHash;OriginalPlanHash=[string]$State.Header.OriginalPlanHash;HeaderHash=[string]$State.HeaderHash
        DerivedJournalHeadHash=[string]$State.DerivedJournalHeadHash;RecordChainHash=[string]$currentContext.RecordChainHash;PendingInventory=@($State.PendingEntries);WorkspaceInventory=@($workspace)
        ResultState=$resultState;Targets=@($targets);ConsumedDocumentHashes=@($State.ConsumedDocumentHashes|Sort-Object);CurrentContextHash=Get-SemanticJsonHash -InputObject $currentContext
        ExpectedOutcome=[string]$classification.ExpectedOutcome;ExpectedTerminalProjection=$projection;ExpectedTerminalProjectionHash=Get-SemanticJsonHash -InputObject $projection
    }
}

function Write-CanonicalRecoveryPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$PlanPayload,[Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$RepoRoot,[string]$ToolchainRoot=$script:CanonicalToolchainRoot)
    $resolved=Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf
    if($resolved.Exists){throw 'Canonical recovery PlanPath must be create-new.'}
    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
    $document=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-recovery-plan';Metadata=[ordered]@{CreatedAtUtc=[DateTime]::UtcNow.ToString('o');Generator='scripts/recover-canonical-transaction.ps1';RepositoryCommit=[string]$git.RepositoryCommit};PlanPayload=$PlanPayload;PlanHash=Get-PlanHash -PlanPayload $PlanPayload}
    $document.DocumentHash=Get-DocumentHash -Document $document
    $null=Publish-ValidatedPreflightJson -Document $document -Path $resolved.FullPath -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-recovery-plan.schema.json')
    return $document
}

function Read-CanonicalRecoveryPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$RepoRoot,[string]$ExpectedAction,[string]$ExpectedTransactionId,[string]$ToolchainRoot=$script:CanonicalToolchainRoot)
    $resolved=Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $RepoRoot
    $document=Read-CanonicalJsonContractFile -Path $resolved.FullPath -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-recovery-plan.schema.json')
    if([string]$document.PlanHash -cne (Get-PlanHash -PlanPayload $document.PlanPayload)){throw 'canonical-recovery-plan-hash-mismatch'}
    if([string]$document.DocumentHash -cne (Get-DocumentHash -Document $document)){throw 'canonical-recovery-document-hash-mismatch'}
    if($ExpectedAction -and [string]$document.PlanPayload.PlannedAction -cne $ExpectedAction){throw 'canonical-recovery-action-mismatch'}
    if($ExpectedTransactionId -and [string]$document.PlanPayload.TransactionId -cne $ExpectedTransactionId){throw 'canonical-recovery-transaction-mismatch'}
    if([string]$document.PlanPayload.RepoRoot -cne (Resolve-Path -LiteralPath $RepoRoot).Path){throw 'canonical-recovery-repository-mismatch'}
    if((Get-SemanticJsonHash -InputObject $document.PlanPayload.ExpectedTerminalProjection) -cne [string]$document.PlanPayload.ExpectedTerminalProjectionHash){throw 'canonical-recovery-terminal-projection-hash-mismatch'}
    return $document
}

function Get-CanonicalRecoveryTargetIdentityProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ReviewedTargets,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ManagedOutputRoots
    )
    # Identity churn inside a generated output root is projected back onto the
    # reviewed tuple when that tuple still matches the reviewed State/Type/Hash
    # and target path. Every other difference stays observable, so the plan
    # still goes stale; workspace ObservedState identities are never touched.
    foreach($row in @($Targets)){
        if(-not(Test-CanonicalDataField -Data $row -Name 'Tuple') -or $null -eq $row.Tuple -or
            -not(Test-TargetContextPathInsideManagedOutputRoot -Path ([string]$row.TargetPath) -ManagedOutputRoots $ManagedOutputRoots)){continue}
        $reviewed=@($ReviewedTargets|Where-Object{[string]$_.TargetId -ceq [string]$row.TargetId})
        if($reviewed.Count -ne 1 -or -not(Test-CanonicalDataField -Data $reviewed[0] -Name 'Tuple') -or
            -not([IO.Path]::GetFullPath([string]$reviewed[0].TargetPath).Equals(
            [IO.Path]::GetFullPath([string]$row.TargetPath),[StringComparison]::OrdinalIgnoreCase))){continue}
        foreach($slot in @('Target','Preimage','SwapOld','Staged')){
            if(-not(Test-CanonicalDataField -Data $row.Tuple -Name $slot) -or
                -not(Test-CanonicalDataField -Data $reviewed[0].Tuple -Name $slot)){continue}
            $actual=$row.Tuple.$slot;$expected=$reviewed[0].Tuple.$slot
            if($null -eq $actual -or $null -eq $expected -or
                -not(Test-CanonicalDataField -Data $actual -Name 'Identity') -or
                -not(Test-CanonicalDataField -Data $expected -Name 'Identity')){continue}
            if([string]$actual.State -cne [string]$expected.State -or [string]$actual.Type -cne [string]$expected.Type -or
                [string]$actual.Hash -cne [string]$expected.Hash){continue}
            $actual.Identity=[string]$expected.Identity
        }
    }
}

function Assert-CanonicalRecoveryPlanCurrent {
    param([Parameter(Mandatory)]$Document,[Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$RepoRoot,[string]$ToolchainRoot=$script:CanonicalToolchainRoot)
    $current=Get-CanonicalRecoveryEvidencePayload -State $State -RepoRoot $RepoRoot -Action ([string]$Document.PlanPayload.PlannedAction) -ToolchainRoot $ToolchainRoot
    $null=(Get-CanonicalRecoveryTargetIdentityProjection -Targets @($current.Targets) -ReviewedTargets @($Document.PlanPayload.Targets) -ManagedOutputRoots (Get-CanonicalGeneratedOutputRoots -RepoRoot $RepoRoot))
    if((Get-PlanHash -PlanPayload $current) -cne [string]$Document.PlanHash){throw 'canonical-recovery-plan-stale'}
    return $current
}

function Publish-CanonicalSetupFinalStateForRecovery {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)]$Classification)
    $setup=$State.Header.SetupRecovery
    $statePath=[string]$setup.StatePath
    $claimPath=[string]$setup.ClaimPath
    if(-not(Test-Path -LiteralPath $claimPath) -and $Classification.SetupState.PSObject.Properties['PendingClaimPath'] -and $Classification.SetupState.PendingClaimPath){
        $null=Read-CanonicalSetupClaimArtifact -State $State -Path ([string]$Classification.SetupState.PendingClaimPath) -PublishPending
    }else{$null=Read-CanonicalSetupClaimArtifact -State $State -Path $claimPath}
    $claimRecords=@($State.Records|Where-Object{[string]$_.Phase -in @('SETUP_CLAIM_INTENT','SETUP_CLAIM_PUBLISHED')})
    if($claimRecords.Count -eq 1 -and [string]$claimRecords[0].Phase -ceq 'SETUP_CLAIM_INTENT'){$null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase SETUP_CLAIM_PUBLISHED -Data ([ordered]@{ClaimHash=[string]$setup.ExpectedClaimHash})}
    $stateRecords=@($State.Records|Where-Object{[string]$_.Phase -in @('SETUP_STATE_INTENT','SETUP_STATE_PUBLISHED')})
    if($stateRecords.Count -eq 0){$null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase SETUP_STATE_INTENT -Data ([ordered]@{StateHash=[string]$Classification.SetupState.ExpectedFinalStateHash})}
    elseif($stateRecords.Count -gt 2 -or [string]$stateRecords[0].Phase -cne 'SETUP_STATE_INTENT'){throw 'manual-recovery-required: setup state journal sequence is invalid'}
    if(Test-Path -LiteralPath $statePath){
        $existing=Read-CanonicalJsonContractFile -Path $statePath -SchemaPath (Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-setup-state.schema.json')
        if((Get-SemanticJsonHash -InputObject $existing) -cne [string]$Classification.SetupState.ExpectedFinalStateHash){throw 'manual-recovery-required: setup state changed before finalize'}
    }elseif($Classification.SetupState.PSObject.Properties['PendingStatePath']){
        [IO.File]::Move([string]$Classification.SetupState.PendingStatePath,$statePath,$false)
    }else{
        $null=Write-CanonicalAtomicJson -Document $Classification.SetupState.ExpectedFinalState -FinalPath $statePath -PendingDirectory (Join-Path $State.TransactionNamespace '_pending') -PendingName ("setup-state-{0}.tmp" -f [Guid]::NewGuid().ToString('N')) -SchemaPath (Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-setup-state.schema.json')
    }
    $current=Get-CanonicalJournalStateForAppend -TransactionNamespace $State.TransactionNamespace
    if(@($current.Records|Where-Object{[string]$_.Phase -ceq 'SETUP_STATE_PUBLISHED'}).Count -eq 0){$null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase SETUP_STATE_PUBLISHED -Data ([ordered]@{StateHash=[string]$Classification.SetupState.ExpectedFinalStateHash})}
    return [string]$Classification.SetupState.ExpectedFinalStateHash
}

function Publish-CanonicalSetupClaimUnderJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    if([string]$State.Header.CanonicalOperationKind -cne 'setup'){throw 'setup claim publication requires a setup transaction'}
    $setup=$State.Header.SetupRecovery;$claimPath=[string]$setup.ClaimPath;$expectedHash=[string]$setup.ExpectedClaimHash
    if((Get-SemanticJsonHash -InputObject $setup.ExpectedClaim) -cne $expectedHash){throw 'setup claim header hash mismatch'}
    $fileSddl=ConvertTo-HomeAuthoritySecurityDescriptorSddl -SecurityTemplate (Get-CanonicalSetupClaimFileSecurityTemplate -State $State)
    # Reject an existing bad claim before adding any journal record. Never repair
    # its permissions or replace it with a newly generated claim.
    $claimExists=Test-Path -LiteralPath $claimPath
    if($claimExists){$null=Read-CanonicalSetupClaimArtifact -State $State -Path $claimPath}
    $claimRecords=@($State.Records|Where-Object{[string]$_.Phase -in @('SETUP_CLAIM_INTENT','SETUP_CLAIM_PUBLISHED')})
    if($claimRecords.Count -eq 0){$null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase SETUP_CLAIM_INTENT -Data ([ordered]@{ClaimHash=$expectedHash})}
    elseif($claimRecords.Count -gt 2 -or [string]$claimRecords[0].Phase -cne 'SETUP_CLAIM_INTENT'){throw 'manual-recovery-required: setup claim journal sequence is invalid'}
    if($claimExists){$null=Read-CanonicalSetupClaimArtifact -State $State -Path $claimPath}else{
        $null=Write-CanonicalAtomicJson -Document $setup.ExpectedClaim -FinalPath $claimPath -PendingDirectory (Join-Path $State.TransactionNamespace '_pending') -PendingName ("setup-claim-{0}.tmp" -f [Guid]::NewGuid().ToString('N')) -SchemaPath (Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-root-claim.schema.json') -FileSecurityDescriptorSddl $fileSddl
    }
    $current=Get-CanonicalJournalStateForAppend -TransactionNamespace $State.TransactionNamespace
    if(@($current.Records|Where-Object{[string]$_.Phase -ceq 'SETUP_CLAIM_PUBLISHED'}).Count -eq 0){$null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase SETUP_CLAIM_PUBLISHED -Data ([ordered]@{ClaimHash=$expectedHash})}
    return $expectedHash
}

function Assert-CanonicalRecoveryOutcomeReady {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('committed','abandoned','rolled-back','failed-restored')][string]$ExpectedOutcome
    )
    $verification=Get-CanonicalTransactionRecoveryClassification -State $State -RepoRoot $RepoRoot
    $finalizeReady=[string]$verification.AllowedAction -ceq 'finalize' -and [string]$verification.ExpectedOutcome -ceq $ExpectedOutcome
    $preResultAbandonReady=-not $State.Result -and $ExpectedOutcome -ceq 'abandoned' -and [string]$verification.AllowedAction -ceq 'abandon' -and [string]$verification.ExpectedOutcome -ceq 'abandoned'
    if([string]$verification.Status -ceq 'manual' -or -not($finalizeReady -or $preResultAbandonReady)){
        throw ("manual-recovery-required: recovery terminal disk tuple no longer matches the reviewed outcome (status={0}; action={1}; expected={2}; reason={3})" -f [string]$verification.Status,[string]$verification.AllowedAction,[string]$verification.ExpectedOutcome,[string]$verification.Reason)
    }
    return $verification
}

function Get-CanonicalRecoveryStatusDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $retryMessageId='canonical-recovery-status-retry'
    $noTransactionMessageId='no-canonical-transaction'
    $manualRecoveryMessageId='manual-recovery-required'
    $lockBusyMessageId='operation-lock-busy'
    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot;$paths=Get-CanonicalTransactionContractPaths -GitContext $git
    $beforeLock=Test-Path -LiteralPath $paths.LockPath -PathType Leaf;$beforeTransactions=Test-Path -LiteralPath $paths.TransactionsRoot -PathType Container
    if(-not $beforeLock -and -not $beforeTransactions){
        $afterLock=Test-Path -LiteralPath $paths.LockPath -PathType Leaf;$afterTransactions=Test-Path -LiteralPath $paths.TransactionsRoot -PathType Container
        if($afterLock -or $afterTransactions){return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='WARN';CommandKind='canonical-recover-status';LifecycleKind='no-transaction';MessageToken=$retryMessageId}}
        return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='PASS';CommandKind='canonical-recover-status';LifecycleKind='no-transaction';MessageToken=$noTransactionMessageId}
    }
    if($beforeTransactions -and -not $beforeLock){return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='FAIL';CommandKind='canonical-recover-status';LifecycleKind='no-transaction';MessageToken=$manualRecoveryMessageId}}
    try{$lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath}catch{return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='WARN';CommandKind='canonical-recover-status';LifecycleKind='no-transaction';MessageToken=$lockBusyMessageId}}
    try{
        try{$unfinished=@(Get-CanonicalAllTransactionStates -TransactionsRoot $paths.TransactionsRoot|Where-Object{-not $_.IsTerminal})}
        catch{return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='FAIL';CommandKind='canonical-recover-status';LifecycleKind='no-transaction';MessageToken=$manualRecoveryMessageId}}
        if($unfinished.Count -eq 0){return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='PASS';CommandKind='canonical-recover-status';LifecycleKind='no-transaction';MessageToken=$noTransactionMessageId}}
        if($unfinished.Count -ne 1){return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='FAIL';CommandKind='canonical-recover-status';LifecycleKind='no-transaction';MessageToken=$manualRecoveryMessageId}}
        $state=$unfinished[0]
        try{$null=Assert-CanonicalRecoveryStateContext -State $state -RepoRoot $git.RepoRoot}catch{return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='FAIL';CommandKind='canonical-recover-status';LifecycleKind='no-transaction';MessageToken=$manualRecoveryMessageId}}
        $classification=Get-CanonicalTransactionRecoveryClassification -State $state -RepoRoot $git.RepoRoot
        if([string]$classification.Status -eq 'manual'){return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='FAIL';CommandKind='canonical-recover-status';LifecycleKind='no-transaction';MessageToken=$manualRecoveryMessageId}}
        $actionMessageId="canonical-recover-{0}" -f [string]$classification.AllowedAction
        return [ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='WARN';CommandKind='canonical-recover-status';LifecycleKind='unfinished';TransactionId=[string]$state.Header.TransactionId;DerivedJournalHeadHash=[string]$state.DerivedJournalHeadHash;OriginalOperationKind=[string]$state.Header.CanonicalOperationKind;MessageToken=$actionMessageId}
    }finally{Exit-CanonicalRepoLock -LockHandle $lock}
}
