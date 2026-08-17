#requires -Version 7.0
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path,[string]$ProgressPath)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/canonical-recovery-common.ps1')

$script:pass=0;$script:fail=0
function Assert{param([bool]$Condition,[string]$Message)if($Condition){$script:pass++;Write-Host "  PASS  $Message" -ForegroundColor Green}else{$script:fail++;Write-Host "  FAIL  $Message" -ForegroundColor Red}}
function Assert-Throws{param([scriptblock]$Action,[string]$Pattern,[string]$Message)try{&$Action;Assert $false $Message}catch{Assert ($_.Exception.Message -match $Pattern) $Message}}
function Set-TestProgress{param([string]$Name)if($ProgressPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ProgressPath),$Name,[Text.UTF8Encoding]::new($false))}}
function Write-Utf8{param([string]$Path,[string]$Value)$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))}
function New-TestTarget{
    param([string]$RecoveryRoot,[string]$Name,[ValidateSet('directory','file','parent-directory')][string]$Kind,[string]$TargetPath,[string]$StagedPath,$Current,$Candidate,[int]$Order)
    $role=if($Kind -eq 'file'){'manifest'}elseif($Kind -eq 'parent-directory'){'parent'}else{'canonical'};$id=Get-CanonicalJournalTargetId -Order $Order -TargetKind $Kind -Role $role -TargetPath $TargetPath
    return [ordered]@{TargetId=$id;Order=$Order;TargetKind=$Kind;Role=$role;TargetPath=[IO.Path]::GetFullPath($TargetPath);PreimagePath=Join-Path $RecoveryRoot "preimage/$id";SwapOldPath=Join-Path $RecoveryRoot "swap-old/$id";StagedPath=if($StagedPath){[IO.Path]::GetFullPath($StagedPath)}else{Join-Path $RecoveryRoot "staged/$id"};Current=$Current;Candidate=$Candidate;TargetContextHash=[string](Resolve-TargetContext -Path $TargetPath -Mode MetadataOnly).RequestedInitialRootContextHash}
}
function New-TestJournal{
    param([string]$Namespace,[string]$RecoveryRoot,[object[]]$Targets)
    $id=[IO.Path]::GetFileName($Namespace)
    $header=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$id;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);OriginalPlanHash=('2'*64);RepoId=('3'*64);GitCommonDirHash=('4'*64);WorktreeId=('5'*64);TransactionNamespace=[IO.Path]::GetFullPath($Namespace);RecoveryTransactionRoot=[IO.Path]::GetFullPath($RecoveryRoot);ExpectedPostconditionsHash=('6'*64);Targets=@($Targets)}
    $null=New-CanonicalJournalHeader -Document $header -TransactionNamespace $Namespace
}
function Publish-TestProjectionResult{param([string]$Namespace,$Projection)$state=Read-CanonicalJournalDirectory -TransactionNamespace $Namespace -AllowUnfinished;$document=[ordered]@{};foreach($key in $Projection.Keys){$document[$key]=$Projection[$key]};$document.Insert(7,'ResultBaseHeadHash',[string]$state.DerivedJournalHeadHash);Publish-CanonicalTransactionResult -TransactionNamespace $Namespace -Document $document}

$root=Join-Path ([IO.Path]::GetTempPath()) ('ai-agent-dotfiles-mutation-blockers-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    Set-TestProgress 'observation-capture';Write-Host "`n[exact observation capture]" -ForegroundColor Cyan
    $observationRoot=Join-Path $root 'observation-root';$observationReplacement=Join-Path $root 'observation-replacement';$observationOld=Join-Path $root 'observation-old'
    [IO.Directory]::CreateDirectory($observationRoot)|Out-Null;Write-Utf8 (Join-Path $observationRoot 'a.txt') 'A'
    [IO.Directory]::CreateDirectory($observationReplacement)|Out-Null;Write-Utf8 (Join-Path $observationReplacement 'b.txt') 'B'
    $originalObservationSnapshot=${function:Get-SafeTreeSnapshot}
    $originalIdentity=[string][AiAgentDotfiles.NoFollowFile]::Inspect($observationRoot).Identity;$originalHash=[string](& $originalObservationSnapshot -Root $observationRoot).TreeHash
    $replacementIdentity=[string][AiAgentDotfiles.NoFollowFile]::Inspect($observationReplacement).Identity;$replacementHash=[string](& $originalObservationSnapshot -Root $observationReplacement).TreeHash
    $script:observationSwapRoot=$observationRoot;$script:observationReplacement=$observationReplacement;$script:observationOld=$observationOld;$script:observationHookCalls=0;$script:originalObservationSnapshot=$originalObservationSnapshot
    function Get-SafeTreeSnapshot {
        param([Parameter(Mandatory)][string]$Root,[string[]]$ExcludeRelativePaths=@(),[string[]]$ExcludePrefixes=@(),[scriptblock]$ShouldSkipEntry)
        if([IO.Path]::GetFullPath($Root) -ceq [IO.Path]::GetFullPath($script:observationSwapRoot)){
            [IO.Directory]::Move($script:observationSwapRoot,$script:observationOld)
            [IO.Directory]::Move($script:observationReplacement,$script:observationSwapRoot)
            $script:observationHookCalls++
        }
        & $script:originalObservationSnapshot -Root $Root -ExcludeRelativePaths $ExcludeRelativePaths -ExcludePrefixes $ExcludePrefixes -ShouldSkipEntry $ShouldSkipEntry
    }
    try{
        $observed=Get-CanonicalObservedPathState -Path $observationRoot -ExpectedKind directory
        $coherent=([string]$observed.Identity -ceq $originalIdentity -and [string]$observed.Hash -ceq $originalHash) -or ([string]$observed.Identity -ceq $replacementIdentity -and [string]$observed.Hash -ceq $replacementHash)
        Assert ($coherent -and $script:observationHookCalls -eq 0) 'observation: directory identity and tree hash come from one retained traversal'
    }finally{Set-Item Function:\Get-SafeTreeSnapshot -Value $originalObservationSnapshot}
    $observationSource=${function:Get-CanonicalObservedPathState}.Ast.Extent.Text;$directoryCaptureSource=${function:Get-CanonicalRetainedDirectoryObservation}.Ast.Extent.Text
    Assert ($observationSource -notmatch 'GetNamedStreams|NoFollowFile\]::Inspect|Get-SafeTreeSnapshot\s' -and $observationSource -match 'HashRegularFile|Get-CanonicalRetainedDirectoryObservation' -and $directoryCaptureSource -match 'Get-SafeTreeSnapshotInternal.+RetainContainmentHandles') 'observation: file and directory state contain no split path read sequence'

    Set-TestProgress 'zero-record';Write-Host "`n[zero-record tuple classification]" -ForegroundColor Cyan
    $recovery=Join-Path $root 'zero-record-recovery';[IO.Directory]::CreateDirectory((Join-Path $recovery 'staged'))|Out-Null
    $targetPath=Join-Path $root 'zero-record.txt';$stagedPath=Join-Path $recovery 'staged/candidate.txt';Write-Utf8 $targetPath 'old';Write-Utf8 $stagedPath 'new'
    $current=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $targetPath).Hash};$candidate=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $stagedPath).Hash}
    $row=New-TestTarget -RecoveryRoot $recovery -Name zero -Kind file -TargetPath $targetPath -StagedPath $stagedPath -Current $current -Candidate $candidate -Order 0
    Assert ([string](Get-CanonicalTargetReconciliation -Target $row -Records @()).State -ceq 'UNPREPARED') 'zero records: exact reviewed tuple is UNPREPARED'
    Write-Utf8 $targetPath 'drift';Assert ([string](Get-CanonicalTargetReconciliation -Target $row -Records @()).State -ceq 'AMBIGUOUS') 'zero records: target drift is ambiguous';Write-Utf8 $targetPath 'old'
    Write-Utf8 $row.PreimagePath 'partial';Assert ([string](Get-CanonicalTargetReconciliation -Target $row -Records @()).State -ceq 'AMBIGUOUS') 'zero records: unbound partial preimage is ambiguous';Remove-Item -LiteralPath $row.PreimagePath -Force
    Write-Utf8 $row.SwapOldPath 'unexpected';Assert ([string](Get-CanonicalTargetReconciliation -Target $row -Records @()).State -ceq 'AMBIGUOUS') 'zero records: unexpected swap-old is ambiguous';Remove-Item -LiteralPath $row.SwapOldPath -Force
    Write-Utf8 $stagedPath 'candidate-drift';Assert ([string](Get-CanonicalTargetReconciliation -Target $row -Records @()).State -ceq 'AMBIGUOUS') 'zero records: staged candidate drift is ambiguous';Write-Utf8 $stagedPath 'new'
    $parentPath=Join-Path $root 'missing-parent';$missing=[ordered]@{State='MISSING'};$parentRow=New-TestTarget -RecoveryRoot $recovery -Name parent -Kind parent-directory -TargetPath $parentPath -Current $missing -Candidate ([ordered]@{State='PRESENT';Hash=('7'*64)}) -Order 0
    Write-Utf8 $parentRow.PreimagePath 'unexpected';Assert ([string](Get-CanonicalTargetReconciliation -Target $parentRow -Records @()).State -ceq 'AMBIGUOUS') 'zero records: parent requires target and every recovery leaf MISSING';Remove-Item -LiteralPath $parentRow.PreimagePath -Force
    foreach($workspace in @((Join-Path $recovery 'preimage'),(Join-Path $recovery 'swap-old'))){if(Test-Path -LiteralPath $workspace){Remove-Item -LiteralPath $workspace -Force}}

    Set-TestProgress 'rollback';Write-Host "`n[rollback no-op and multi-target ordering]" -ForegroundColor Cyan
    $barrierRecovery=Join-Path $root 'barrier-recovery';$dirTarget=Join-Path $root 'unprepared-directory';$dirStaged=Join-Path $barrierRecovery 'staged/unprepared-directory';[IO.Directory]::CreateDirectory($dirTarget)|Out-Null;Write-Utf8 (Join-Path $dirTarget 'old.txt') 'old';[IO.Directory]::CreateDirectory($dirStaged)|Out-Null;Write-Utf8 (Join-Path $dirStaged 'new.txt') 'new'
    $dirCurrent=[ordered]@{State='PRESENT';Hash=(Get-SafeTreeSnapshot -Root $dirTarget).TreeHash};$dirCandidate=[ordered]@{State='PRESENT';Hash=(Get-SafeTreeSnapshot -Root $dirStaged).TreeHash};$dirRow=New-TestTarget -RecoveryRoot $barrierRecovery -Name later -Kind directory -TargetPath $dirTarget -StagedPath $dirStaged -Current $dirCurrent -Candidate $dirCandidate -Order 1
    $dirRecon=Get-CanonicalTargetReconciliation -Target $dirRow -Records @();$noOpError=$null;try{Restore-CanonicalMutationTarget -Target $dirRow -Reconciliation $dirRecon}catch{$noOpError=$_.Exception.Message}
    Assert (-not $noOpError -and (Get-SafeTreeSnapshot -Root $dirTarget).TreeHash -ceq $dirCurrent.Hash -and (Get-SafeTreeSnapshot -Root $dirStaged).TreeHash -ceq $dirCandidate.Hash) 'rollback: verified UNPREPARED directory is a byte-preserving no-op'

    $fileTarget=Join-Path $root 'early-file.txt';$fileStaged=Join-Path $barrierRecovery 'staged/early-file.txt';Write-Utf8 $fileTarget 'early-old';Write-Utf8 $fileStaged 'early-new'
    $fileCurrent=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $fileTarget).Hash};$fileCandidate=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $fileStaged).Hash};$fileRow=New-TestTarget -RecoveryRoot $barrierRecovery -Name early -Kind file -TargetPath $fileTarget -StagedPath $fileStaged -Current $fileCurrent -Candidate $fileCandidate -Order 0
    $namespace=Join-Path $root ([Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $namespace -RecoveryRoot $barrierRecovery -Targets @($fileRow,$dirRow)
    Assert-Throws {Invoke-CanonicalFileReplacement -TransactionNamespace $namespace -Target $fileRow} 'preimage-barrier-incomplete' 'mutation barrier: no target primitive is allowed before every non-parent target has a durable preimage'
    $null=Initialize-CanonicalTransactionPreimages -TransactionNamespace $namespace;$null=Invoke-CanonicalFileReplacement -TransactionNamespace $namespace -Target $fileRow
    $state=Read-CanonicalJournalDirectory -TransactionNamespace $namespace -AllowUnfinished;$rollbackError=$null
    try{foreach($target in @($state.Header.Targets|Sort-Object{[long]$_.Order} -Descending)){Restore-CanonicalMutationTarget -Target $target -Reconciliation (Get-CanonicalTargetReconciliation -Target $target -Records @($state.Records))}}catch{$rollbackError=$_.Exception.Message}
    Assert (-not $rollbackError -and (Get-CanonicalObservedPathState $fileTarget).Hash -ceq $fileCurrent.Hash -and (Get-SafeTreeSnapshot -Root $dirTarget).TreeHash -ceq $dirCurrent.Hash) 'rollback: later PRE_PRIMITIVE target is a byte-preserving no-op after the transaction-wide preimage barrier'

    Set-TestProgress 'partial-preimage';Write-Host "`n[interrupted preimage preservation]" -ForegroundColor Cyan
    $partialRecovery=Join-Path $root 'partial-recovery';[IO.Directory]::CreateDirectory((Join-Path $partialRecovery 'staged'))|Out-Null
    $partialTarget=Join-Path $root 'partial-target.txt';$partialStaged=Join-Path $partialRecovery 'staged/candidate.txt';Write-Utf8 $partialTarget 'reviewed-old-bytes';Write-Utf8 $partialStaged 'reviewed-new-bytes'
    $partialCurrent=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $partialTarget).Hash};$partialCandidate=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $partialStaged).Hash};$partialRow=New-TestTarget -RecoveryRoot $partialRecovery -Name partial -Kind file -TargetPath $partialTarget -StagedPath $partialStaged -Current $partialCurrent -Candidate $partialCandidate -Order 0
    $partialNamespace=Join-Path $root ([Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $partialNamespace -RecoveryRoot $partialRecovery -Targets @($partialRow)
    Initialize-CanonicalRecoveryWorkspace -TransactionNamespace $partialNamespace
    $partialTargetState=Get-CanonicalObservedPathState -Path $partialRow.TargetPath -ExpectedKind file;$partialPreimageState=Get-CanonicalObservedPathState -Path $partialRow.PreimagePath;$partialSwapState=Get-CanonicalObservedPathState -Path $partialRow.SwapOldPath;$partialStagedState=Get-CanonicalObservedPathState -Path $partialRow.StagedPath -ExpectedKind file
    $partialIntent=New-CanonicalTargetRecordData -Target $partialRow -TargetState $partialTargetState -PreimageState $partialPreimageState -SwapOldState $partialSwapState -StagedState $partialStagedState;$null=Add-CanonicalJournalRecord -TransactionNamespace $partialNamespace -Phase PREIMAGE_COPY_INTENT -Data $partialIntent
    Write-Utf8 $partialRow.PreimagePath 'partial';$partialState=Read-CanonicalJournalDirectory -TransactionNamespace $partialNamespace -AllowUnfinished;$partialRecon=Get-CanonicalTargetReconciliation -Target $partialRow -Records @($partialState.Records)
    Assert ([string]$partialRecon.State -ceq 'AMBIGUOUS') 'preimage: interrupted partial copy is ambiguous rather than PRE_PRIMITIVE'
    $partialRestoreError=$null;try{Restore-CanonicalMutationTarget -Target $partialRow -Reconciliation $partialRecon}catch{$partialRestoreError=$_.Exception.Message}
    Assert ($partialRestoreError -match 'manual-recovery-required' -and [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($partialRow.PreimagePath)) -ceq 'partial') 'preimage: manual classification preserves partial bytes without cleanup'

    Set-TestProgress 'nested-finalize';Write-Host "`n[nested finalize outcome preservation]" -ForegroundColor Cyan
    $rolledProjection=New-CanonicalExpectedTransactionResultProjection -State $state -Classification ([pscustomobject]@{ExpectedOutcome='rolled-back'});$rolledProjectionHash=Get-SemanticJsonHash -InputObject $rolledProjection
    $rollbackIntent=Add-CanonicalJournalRecord -TransactionNamespace $namespace -Phase RECOVERY_ACTION_INTENT -Data ([ordered]@{PlanKind='canonical-recover-rollback';DocumentHash=('b'*64);PriorHeadHash=[string]$state.DerivedJournalHeadHash;ExpectedOutcome='rolled-back';ExpectedTerminalProjectionHash=$rolledProjectionHash})
    $null=Add-CanonicalJournalRecord -TransactionNamespace $namespace -Phase RECOVERY_ACTION_APPLIED -Data ([ordered]@{Action='rollback';DocumentHash=('b'*64)})
    $afterRollbackIntent=Read-CanonicalJournalDirectory -TransactionNamespace $namespace -AllowUnfinished;$rolledClass=Get-CanonicalTransactionRecoveryClassification -State $afterRollbackIntent -RepoRoot $root
    $finalizeIntent=Add-CanonicalJournalRecord -TransactionNamespace $namespace -Phase RECOVERY_ACTION_INTENT -Data ([ordered]@{PlanKind='canonical-recover-finalize';DocumentHash=('c'*64);PriorHeadHash=[string]$afterRollbackIntent.DerivedJournalHeadHash;ExpectedOutcome='rolled-back';ExpectedTerminalProjectionHash=$rolledProjectionHash})
    $afterFinalizeIntent=Read-CanonicalJournalDirectory -TransactionNamespace $namespace -AllowUnfinished;$nestedClass=Get-CanonicalTransactionRecoveryClassification -State $afterFinalizeIntent -RepoRoot $root
    Assert ([string]$rolledClass.AllowedAction -ceq 'finalize' -and [string]$rolledClass.ExpectedOutcome -ceq 'rolled-back' -and [string]$nestedClass.AllowedAction -ceq 'finalize' -and [string]$nestedClass.ExpectedOutcome -ceq 'rolled-back') 'recovery: nested finalize intent preserves the preceding rolled-back outcome discriminator'

    Set-TestProgress 'fixed-outcomes';Write-Host "`n[fixed-result outcome tuple revalidation]" -ForegroundColor Cyan
    $null=Add-CanonicalJournalRecord -TransactionNamespace $namespace -Phase RECOVERY_ACTION_APPLIED -Data ([ordered]@{Action='finalize';DocumentHash=('c'*64)});$null=Publish-TestProjectionResult -Namespace $namespace -Projection $rolledProjection
    $rolledState=Read-CanonicalJournalDirectory -TransactionNamespace $namespace -AllowUnfinished;$rolledFixed=Get-CanonicalTransactionRecoveryClassification -State $rolledState -RepoRoot $root;Write-Utf8 $fileTarget 'rolled-drift';$rolledDrift=Get-CanonicalTransactionRecoveryClassification -State $rolledState -RepoRoot $root;Write-Utf8 $fileTarget 'early-old'
    Assert ([string]$rolledFixed.AllowedAction -ceq 'finalize' -and [string]$rolledFixed.ExpectedOutcome -ceq 'rolled-back' -and [string]$rolledDrift.Status -ceq 'manual') 'fixed result: rolled-back outcome revalidates the restored tuple before finalize'

    $abandonRecovery=Join-Path $root 'abandon-recovery';[IO.Directory]::CreateDirectory((Join-Path $abandonRecovery 'staged'))|Out-Null;$abandonTargetPath=Join-Path $root 'abandon-target.txt';$abandonStaged=Join-Path $abandonRecovery 'staged/candidate.txt';Write-Utf8 $abandonTargetPath 'old';Write-Utf8 $abandonStaged 'new'
    $abandonCurrent=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $abandonTargetPath).Hash};$abandonCandidate=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $abandonStaged).Hash};$abandonRow=New-TestTarget -RecoveryRoot $abandonRecovery -Name abandon -Kind file -TargetPath $abandonTargetPath -StagedPath $abandonStaged -Current $abandonCurrent -Candidate $abandonCandidate -Order 0;$abandonNs=Join-Path $root ([Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $abandonNs -RecoveryRoot $abandonRecovery -Targets @($abandonRow)
    $abandonState=Read-CanonicalJournalDirectory -TransactionNamespace $abandonNs -AllowUnfinished;$abandonClass=Get-CanonicalTransactionRecoveryClassification -State $abandonState -RepoRoot $root;$abandonProjection=New-CanonicalExpectedTransactionResultProjection -State $abandonState -Classification $abandonClass;$null=Publish-TestProjectionResult -Namespace $abandonNs -Projection $abandonProjection
    $abandonFixedState=Read-CanonicalJournalDirectory -TransactionNamespace $abandonNs -AllowUnfinished;$abandonFixed=Get-CanonicalTransactionRecoveryClassification -State $abandonFixedState -RepoRoot $root;Write-Utf8 $abandonStaged 'staged-drift';$abandonDrift=Get-CanonicalTransactionRecoveryClassification -State $abandonFixedState -RepoRoot $root
    Assert ([string]$abandonFixed.AllowedAction -ceq 'finalize' -and [string]$abandonFixed.ExpectedOutcome -ceq 'abandoned' -and [string]$abandonDrift.Status -ceq 'manual') 'fixed result: abandoned outcome revalidates the exact UNPREPARED tuple before finalize'

    $commitRecovery=Join-Path $root 'commit-recovery';[IO.Directory]::CreateDirectory((Join-Path $commitRecovery 'staged'))|Out-Null;$commitTargetPath=Join-Path $root 'commit-target.txt';$commitStaged=Join-Path $commitRecovery 'staged/candidate.txt';Write-Utf8 $commitTargetPath 'old';Write-Utf8 $commitStaged 'new'
    $commitCurrent=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $commitTargetPath).Hash};$commitCandidate=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $commitStaged).Hash};$commitRow=New-TestTarget -RecoveryRoot $commitRecovery -Name commit -Kind file -TargetPath $commitTargetPath -StagedPath $commitStaged -Current $commitCurrent -Candidate $commitCandidate -Order 0;$commitNs=Join-Path $root ([Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $commitNs -RecoveryRoot $commitRecovery -Targets @($commitRow);$null=Invoke-CanonicalFileReplacement -TransactionNamespace $commitNs -Target $commitRow;$null=Add-CanonicalJournalRecord -TransactionNamespace $commitNs -Phase POSTCONDITIONS_OK -Data ([ordered]@{PostconditionsHash=('6'*64)})
    $commitState=Read-CanonicalJournalDirectory -TransactionNamespace $commitNs -AllowUnfinished;$commitClass=Get-CanonicalTransactionRecoveryClassification -State $commitState -RepoRoot $root;$commitProjection=New-CanonicalExpectedTransactionResultProjection -State $commitState -Classification $commitClass;$null=Publish-TestProjectionResult -Namespace $commitNs -Projection $commitProjection
    $commitFixedState=Read-CanonicalJournalDirectory -TransactionNamespace $commitNs -AllowUnfinished;$commitFixed=Get-CanonicalTransactionRecoveryClassification -State $commitFixedState -RepoRoot $root;Write-Utf8 $commitTargetPath 'committed-drift';$commitDrift=Get-CanonicalTransactionRecoveryClassification -State $commitFixedState -RepoRoot $root
    Assert ([string]$commitFixed.AllowedAction -ceq 'finalize' -and [string]$commitFixed.ExpectedOutcome -ceq 'committed' -and [string]$commitDrift.Status -ceq 'manual') 'fixed result: committed outcome requires POSTCONDITIONS_OK and exact installed tuple before finalize'

    $failedRecovery=Join-Path $root 'failed-recovery';[IO.Directory]::CreateDirectory((Join-Path $failedRecovery 'staged'))|Out-Null;$failedTargetPath=Join-Path $root 'failed-target.txt';$failedStaged=Join-Path $failedRecovery 'staged/candidate.txt';Write-Utf8 $failedTargetPath 'old';Write-Utf8 $failedStaged 'new'
    $failedCurrent=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $failedTargetPath).Hash};$failedCandidate=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $failedStaged).Hash};$failedRow=New-TestTarget -RecoveryRoot $failedRecovery -Name failed -Kind file -TargetPath $failedTargetPath -StagedPath $failedStaged -Current $failedCurrent -Candidate $failedCandidate -Order 0;$failedNs=Join-Path $root ([Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $failedNs -RecoveryRoot $failedRecovery -Targets @($failedRow);$null=Invoke-CanonicalFileReplacement -TransactionNamespace $failedNs -Target $failedRow;$failedState=Read-CanonicalJournalDirectory -TransactionNamespace $failedNs -AllowUnfinished;$failedRecon=Get-CanonicalTargetReconciliation -Target $failedRow -Records @($failedState.Records);Restore-CanonicalMutationTarget -Target $failedRow -Reconciliation $failedRecon;$failedProjection=New-CanonicalExpectedTransactionResultProjection -State $failedState -Classification ([pscustomobject]@{ExpectedOutcome='failed-restored'});$failedProjection.Result='FAIL';$null=Publish-TestProjectionResult -Namespace $failedNs -Projection $failedProjection
    $failedFixedState=Read-CanonicalJournalDirectory -TransactionNamespace $failedNs -AllowUnfinished;$failedFixed=Get-CanonicalTransactionRecoveryClassification -State $failedFixedState -RepoRoot $root;Write-Utf8 $failedTargetPath 'failed-drift';$failedDrift=Get-CanonicalTransactionRecoveryClassification -State $failedFixedState -RepoRoot $root
    Assert ([string]$failedFixed.AllowedAction -ceq 'finalize' -and [string]$failedFixed.ExpectedOutcome -ceq 'failed-restored' -and [string]$failedDrift.Status -ceq 'manual') 'fixed result: failed-restored outcome revalidates the restored tuple before finalize'

    Set-TestProgress 'strict-negatives';Write-Host "`n[strict journal state-machine negatives]" -ForegroundColor Cyan
    $strictRecovery=Join-Path $root 'strict-recovery';$strictTargetPath=Join-Path $root 'strict-target.txt';$strictStaged=Join-Path $strictRecovery 'staged/strict';Write-Utf8 $strictTargetPath 'old';Write-Utf8 $strictStaged 'new'
    $strictCurrent=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $strictTargetPath).Hash};$strictCandidate=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $strictStaged).Hash};$strictTarget=New-TestTarget -RecoveryRoot $strictRecovery -Name strict -Kind file -TargetPath $strictTargetPath -StagedPath $strictStaged -Current $strictCurrent -Candidate $strictCandidate -Order 0
    $strictId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$strictNamespace=Join-Path $root $strictId
    $strictHeader=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$strictId;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);OriginalPlanHash=('2'*64);RepoId=('3'*64);GitCommonDirHash=('4'*64);WorktreeId=('5'*64);TransactionNamespace=[IO.Path]::GetFullPath($strictNamespace);RecoveryTransactionRoot=[IO.Path]::GetFullPath($strictRecovery);ExpectedPostconditionsHash=('6'*64);Targets=@($strictTarget)}
    function New-Record{param([object[]]$Prior,[string]$Phase,$Data)$previous=if($Prior.Count){Get-SemanticJsonHash -InputObject $Prior[-1]}else{Get-SemanticJsonHash -InputObject $strictHeader};[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-record';TransactionId=$strictId;Sequence=$Prior.Count+1;PreviousHash=$previous;Phase=$Phase;Data=$Data}}
    $missingState=[ordered]@{State='MISSING'};$emptyDir=[ordered]@{State='PRESENT';Type='Directory';Hash=(Get-CanonicalJournalEmptyDirectoryHash);Identity='volume:workspace'}
    $strictRecords=@();foreach($role in @('preimage','swap-old')){$workspacePath=Join-Path $strictRecovery $role;$strictRecords+=New-Record -Prior $strictRecords -Phase WORKSPACE_CREATE_INTENT -Data ([ordered]@{WorkspacePath=$workspacePath;WorkspaceRole=$role;WorkspaceState=$missingState});$created=[ordered]@{WorkspacePath=$workspacePath;WorkspaceRole=$role;WorkspaceState=$emptyDir;CreatedIdentity='volume:workspace'};$strictRecords+=New-Record -Prior $strictRecords -Phase WORKSPACE_CREATED -Data $created}
    $baseTargetData=New-CanonicalTargetRecordData -Target $strictTarget -TargetState (Get-CanonicalObservedPathState $strictTargetPath) -PreimageState $missingState -SwapOldState $missingState -StagedState (Get-CanonicalObservedPathState $strictStaged)
    $forgedWorkspaceIntent=@($strictRecords[0..-2]);$forgedWorkspaceIntent[0]=New-Record -Prior @() -Phase WORKSPACE_CREATE_INTENT -Data ([ordered]@{WorkspacePath=(Join-Path $strictRecovery 'preimage');WorkspaceRole='preimage';WorkspaceState=$emptyDir})
    Assert-Throws {Test-CanonicalJournalChain -Header $strictHeader -Records @($forgedWorkspaceIntent[0])} 'WorkspaceState must be MISSING' 'journal semantics: WORKSPACE_CREATE_INTENT requires the exact MISSING tuple'
    $workspaceIntent=New-Record -Prior @() -Phase WORKSPACE_CREATE_INTENT -Data ([ordered]@{WorkspacePath=(Join-Path $strictRecovery 'preimage');WorkspaceRole='preimage';WorkspaceState=$missingState})
    $forgedWorkspaceCreated=New-Record -Prior @($workspaceIntent) -Phase WORKSPACE_CREATED -Data ([ordered]@{WorkspacePath=(Join-Path $strictRecovery 'preimage');WorkspaceRole='preimage';WorkspaceState=$missingState;CreatedIdentity='volume:workspace'})
    Assert-Throws {Test-CanonicalJournalChain -Header $strictHeader -Records @($workspaceIntent,$forgedWorkspaceCreated)} 'WorkspaceState must be a PRESENT Directory' 'journal semantics: WORKSPACE_CREATED requires a PRESENT Directory bound to CreatedIdentity'
    $forgedPreimageData=[ordered]@{};foreach($key in $baseTargetData.Keys){$forgedPreimageData[$key]=$baseTargetData[$key]};$forgedPreimageData.TargetState=[ordered]@{State='PRESENT';Type='File';Hash=('e'*64);Identity='volume:forged'}
    $forgedPreimageRecord=New-Record -Prior $strictRecords -Phase PREIMAGE_COPY_INTENT -Data $forgedPreimageData
    Assert-Throws {Test-CanonicalJournalChain -Header $strictHeader -Records (@($strictRecords)+@($forgedPreimageRecord))} 'PREIMAGE_COPY_INTENT target differs from header Current' 'journal semantics: PREIMAGE_COPY_INTENT binds Current/Candidate with preimage and swap MISSING'
    $extraData=[ordered]@{};foreach($key in $baseTargetData.Keys){$extraData[$key]=$baseTargetData[$key]};$extraData.PostconditionsHash=('6'*64);$extraRecord=New-Record -Prior $strictRecords -Phase PREIMAGE_COPY_INTENT -Data $extraData
    Assert-Throws {Test-CanonicalJournalChain -Header $strictHeader -Records (@($strictRecords)+@($extraRecord))} 'invalid data fields' 'journal semantics: phase-valid union fields cannot cross into PREIMAGE_COPY_INTENT'
    $wrongOrder=New-Record -Prior $strictRecords -Phase FILE_PREPARED -Data $baseTargetData
    Assert-Throws {Test-CanonicalJournalChain -Header $strictHeader -Records (@($strictRecords)+@($wrongOrder))} 'phase order' 'journal semantics: per-target phase order rejects FILE_PREPARED without intent'
    $wrongPath=[ordered]@{};foreach($key in $baseTargetData.Keys){$wrongPath[$key]=$baseTargetData[$key]};$wrongPath.TargetPath=Join-Path $root 'other.txt';$wrongPathRecord=New-Record -Prior $strictRecords -Phase PREIMAGE_COPY_INTENT -Data $wrongPath
    Assert-Throws {Test-CanonicalJournalChain -Header $strictHeader -Records (@($strictRecords)+@($wrongPathRecord))} 'differs from header target' 'journal semantics: target path/kind/id must equal the header target'
    $wrongIdTarget=[ordered]@{};foreach($key in $strictTarget.Keys){$wrongIdTarget[$key]=$strictTarget[$key]};$wrongIdTarget.TargetId=('f'*64)
    $wrongIdHeader=[ordered]@{};foreach($key in $strictHeader.Keys){$wrongIdHeader[$key]=$strictHeader[$key]};$wrongIdHeader.Targets=@($wrongIdTarget)
    Assert-Throws {Test-CanonicalJournalChain -Header $wrongIdHeader -Records @()} 'TargetId differs' 'journal semantics: header TargetId must be regenerated from order, kind, role, platform, and target path'
    $earlyPost=New-Record -Prior $strictRecords -Phase POSTCONDITIONS_OK -Data ([ordered]@{PostconditionsHash=('6'*64)})
    Assert-Throws {Test-CanonicalJournalChain -Header $strictHeader -Records (@($strictRecords)+@($earlyPost))} 'precedes completion' 'journal semantics: POSTCONDITIONS_OK requires every target terminal phase'

    $resultHeader=[ordered]@{};foreach($key in $strictHeader.Keys){$resultHeader[$key]=$strictHeader[$key]};$resultHeader.Targets=@();$recoveryPost=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-record';TransactionId=$strictId;Sequence=1;PreviousHash=(Get-SemanticJsonHash -InputObject $resultHeader);Phase='POSTCONDITIONS_OK';Data=[ordered]@{PostconditionsHash=('6'*64)}};$intentData=[ordered]@{PlanKind='canonical-recover-finalize';DocumentHash=('b'*64);PriorHeadHash=(Get-SemanticJsonHash -InputObject $recoveryPost);ExpectedOutcome='committed';ExpectedTerminalProjectionHash=('c'*64)}
    $intent=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-record';TransactionId=$strictId;Sequence=2;PreviousHash=$intentData.PriorHeadHash;Phase='RECOVERY_ACTION_INTENT';Data=$intentData}
    $result=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='PASS';TransactionId=$strictId;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);ResultBaseHeadHash=(Get-SemanticJsonHash -InputObject $intent);Outcome='committed';PlanHash=('2'*64);PostconditionsHash=('6'*64);ArtifactStates=@([ordered]@{Name='targets';Status='COMPLETE';Hash=(Get-SemanticJsonHash -InputObject @())})}
    Assert-Throws {Test-CanonicalJournalChain -Header $resultHeader -Records @($recoveryPost,$intent) -Results @($result)} 'projection differs' 'journal semantics: recovery intent projection hash must bind the fixed result before COMPLETE'

    $originalPost=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-record';TransactionId=$strictId;Sequence=1;PreviousHash=(Get-SemanticJsonHash -InputObject $resultHeader);Phase='POSTCONDITIONS_OK';Data=[ordered]@{PostconditionsHash=('6'*64)}}
    $forgedOriginalResult=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='PASS';TransactionId=$strictId;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);ResultBaseHeadHash=(Get-SemanticJsonHash -InputObject $originalPost);Outcome='committed';PlanHash=('e'*64);PostconditionsHash=('d'*64);ArtifactStates=@([ordered]@{Name='forged';Status='COMPLETE';Hash=('c'*64)})}
    Assert-Throws {Test-CanonicalJournalChain -Header $resultHeader -Records @($originalPost) -Results @($forgedOriginalResult)} 'semantic projection differs' 'journal semantics: original committed result binds plan, postconditions, and deterministic artifact states'
    $forgedAbandoned=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='PASS';TransactionId=$strictId;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);ResultBaseHeadHash=(Get-SemanticJsonHash -InputObject $resultHeader);Outcome='abandoned';ArtifactStates=@([ordered]@{Name='forged';Status='MISSING'})}
    Assert-Throws {Test-CanonicalJournalChain -Header $resultHeader -Records @() -Results @($forgedAbandoned)} 'semantic projection differs' 'journal semantics: original abandoned result binds deterministic actual artifact state'
    $wrongRestore=('f'*64);$forgedRestored=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='PASS';TransactionId=$strictId;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);ResultBaseHeadHash=(Get-SemanticJsonHash -InputObject $resultHeader);Outcome='rolled-back';RestorationHash=$wrongRestore;FinalStateHash=$wrongRestore;ArtifactStates=@([ordered]@{Name='targets';Status='COMPLETE';Hash=(Get-SemanticJsonHash -InputObject @())})}
    Assert-Throws {Test-CanonicalJournalChain -Header $resultHeader -Records @() -Results @($forgedRestored)} 'semantic projection differs' 'journal semantics: original rolled-back result binds deterministic restoration and final-state hashes'

    $restorationHash=Get-SemanticJsonHash -InputObject ([ordered]@{TransactionId=$strictId;Targets=@()});$emptyTargetHash=Get-SemanticJsonHash -InputObject @()
    $forgedResult=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='PASS';TransactionId=$strictId;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);ResultBaseHeadHash=('0'*64);Outcome='rolled-back';RestorationHash=$restorationHash;FinalStateHash=$restorationHash;ArtifactStates=@([ordered]@{Name='targets';Status='COMPLETE';Hash=$emptyTargetHash})}
    $forgedProjectionHash=Get-SemanticJsonHash -InputObject (Get-CanonicalJournalResultProjection -Result $forgedResult)
    $oldRollback=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-record';TransactionId=$strictId;Sequence=1;PreviousHash=(Get-SemanticJsonHash -InputObject $resultHeader);Phase='RECOVERY_ACTION_INTENT';Data=[ordered]@{PlanKind='canonical-recover-rollback';DocumentHash=('e'*64);PriorHeadHash=(Get-SemanticJsonHash -InputObject $resultHeader);ExpectedOutcome='committed';ExpectedTerminalProjectionHash=('f'*64)}}
    $newFinalize=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-record';TransactionId=$strictId;Sequence=2;PreviousHash=(Get-SemanticJsonHash -InputObject $oldRollback);Phase='RECOVERY_ACTION_INTENT';Data=[ordered]@{PlanKind='canonical-recover-finalize';DocumentHash=('a'*64);PriorHeadHash=(Get-SemanticJsonHash -InputObject $oldRollback);ExpectedOutcome='rolled-back';ExpectedTerminalProjectionHash=$forgedProjectionHash}}
    $forgedResult.ResultBaseHeadHash=Get-SemanticJsonHash -InputObject $newFinalize
    Assert-Throws {Test-CanonicalJournalChain -Header $resultHeader -Records @($oldRollback,$newFinalize) -Results @($forgedResult)} 'ancestry projection differs' 'journal semantics: an unrelated older rollback intent cannot authorize a forged rolled-back fixed result'

    $heldId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$heldNamespace=Join-Path $root $heldId;$heldRecovery=Join-Path $root 'held-snapshot-recovery';[IO.Directory]::CreateDirectory($heldRecovery)|Out-Null
    New-TestJournal -Namespace $heldNamespace -RecoveryRoot $heldRecovery -Targets @()
    $heldSnapshot=$null;$rewriteAttempted=$false;$rewriteBlocked=$false;$rewriteSucceeded=$false;$rewriteError=$null;$appendResult=$null;$heldBoundarySafe=$false
    try{
        $heldSnapshot=Open-CanonicalJournalSnapshot -TransactionNamespace $heldNamespace -AllowUnfinished
        $headerHandle=$heldSnapshot.ArtifactHandles['header.json'];$beforeBytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($headerHandle,[long]$headerHandle.ReadResult.Length);$beforeIdentity=[string]$headerHandle.ReadResult.Identity;$beforeSha=[string]$headerHandle.ReadResult.Sha256
        $reorderedHeader=[ordered]@{};$reorderedKeys=@($heldSnapshot.State.Header.Keys);[array]::Reverse($reorderedKeys);foreach($key in $reorderedKeys){$reorderedHeader[$key]=$heldSnapshot.State.Header[$key]}
        $replacementText=ConvertTo-Json -InputObject $reorderedHeader -Compress -Depth 100;$replacementBytes=[Text.UTF8Encoding]::new($false).GetBytes($replacementText)
        if($replacementBytes.Length -ne $beforeBytes.Length -or [Convert]::ToBase64String($replacementBytes) -ceq [Convert]::ToBase64String($beforeBytes) -or (Get-SemanticJsonHash -InputObject (ConvertFrom-SemanticJson -Json $replacementText)) -cne (Get-SemanticJsonHash -InputObject $heldSnapshot.State.Header)){throw 'Held header replacement fixture is not an exact same-length semantic equivalent.'}
        $rewriteAttempted=$true
        try{[IO.File]::WriteAllBytes((Join-Path $heldNamespace 'header.json'),$replacementBytes);$rewriteSucceeded=$true}
        catch [IO.IOException]{$rewriteBlocked=$true;$rewriteError=$_.Exception.Message}
        catch [UnauthorizedAccessException]{$rewriteBlocked=$true;$rewriteError=$_.Exception.Message}
        catch{$rewriteError=$_.Exception.Message}
        $afterBytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($headerHandle,[long]$headerHandle.ReadResult.Length);$relativeHeader=[AiAgentDotfiles.NoFollowFile]::InspectChild($heldSnapshot.NamespaceHandle,'header.json')
        $appendResult=Add-CanonicalJournalRecord -TransactionNamespace $heldNamespace -Phase POSTCONDITIONS_OK -Data ([ordered]@{PostconditionsHash=('6'*64)})
        $publishedRecord=[AiAgentDotfiles.NoFollowFile]::InspectChild($heldSnapshot.NamespaceHandle,'000001.json')
        $heldBoundarySafe=($rewriteAttempted -and $rewriteBlocked -and -not $rewriteSucceeded -and $rewriteError -and [Convert]::ToBase64String($afterBytes) -ceq [Convert]::ToBase64String($beforeBytes) -and [string]$headerHandle.ReadResult.Identity -ceq $beforeIdentity -and [string]$headerHandle.ReadResult.Sha256 -ceq $beforeSha -and [string]$relativeHeader.Identity -ceq $beforeIdentity -and [string]$appendResult.Path -ceq [IO.Path]::GetFullPath((Join-Path $heldNamespace '000001.json')) -and [string]$appendResult.Identity -ceq [string]$publishedRecord.Identity)
    }
    finally{if($heldSnapshot){Close-CanonicalJournalSnapshot -Snapshot $heldSnapshot}}
    Assert $heldBoundarySafe 'append session: held snapshot blocks same-semantic raw-byte replacement and preserves identity through append'
}
catch{$script:fail++;Write-Host "  FAIL  unhandled test error: $($_.Exception.Message)" -ForegroundColor Red;Write-Host $_.ScriptStackTrace -ForegroundColor DarkYellow}
finally{Write-Host '';Write-Host ("Results: {0} passed, {1} failed" -f $script:pass,$script:fail) -ForegroundColor Cyan;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
if($script:fail -ne 0){exit 1}
