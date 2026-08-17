#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolchainRoot,
    [Parameter(Mandatory)][string]$FixtureRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f-]{36}$')][string]$TransactionId,
    [Parameter(Mandatory)][ValidateSet('parent','directory','directory-add','directory-delete','file','file-add')][string]$Kind,
    [Parameter(Mandatory)][string]$Checkpoint,
    [Parameter(Mandatory)][string]$MarkerPath,
    [string]$AfterPreimageStagePath,
    [ValidatePattern('^AiAgentDotfilesTests-AfterPreimage-[0-9a-f]{32}$')][string]$AfterPreimageStageEventName,
    [ValidateSet('committed','failed-restored')][string]$TerminalOutcome='committed'
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $ToolchainRoot 'scripts/canonical-recovery-common.ps1')

$afterPreimageStageSupplied=-not [string]::IsNullOrWhiteSpace($AfterPreimageStagePath) -or -not [string]::IsNullOrWhiteSpace($AfterPreimageStageEventName)
if($Checkpoint -ceq 'after-preimage-copy'){
    if([string]::IsNullOrWhiteSpace($AfterPreimageStagePath) -or [string]::IsNullOrWhiteSpace($AfterPreimageStageEventName)){throw 'after-preimage requires its complete typed stage contract'}
    $expectedAfterPreimageStage=[IO.Path]::GetFullPath((Join-Path $FixtureRoot 'after-preimage-start.json'))
    if(-not [IO.Path]::GetFullPath($AfterPreimageStagePath).Equals($expectedAfterPreimageStage,[StringComparison]::OrdinalIgnoreCase)){throw 'after-preimage stage path differs from its sealed fixture locator'}
}elseif($afterPreimageStageSupplied){throw 'after-preimage typed stage inputs are forbidden for other checkpoints'}

function Write-Utf8([string]$Path,[string]$Value){$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))}
function Write-SemanticJson([string]$Path,$Value){$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllBytes($Path,(ConvertTo-SemanticJsonBytes -InputObject $Value))}
function Set-CurrentUserOnlyAcl([string]$Path){
    $template=Get-CanonicalCurrentUserOnlySecurityTemplate;$sid=[Security.Principal.SecurityIdentifier]::new([string]$template.OwnerSid)
    $security=[Security.AccessControl.DirectorySecurity]::new();$security.SetOwner($sid);$security.SetAccessRuleProtection($true,$false)
    $inherit=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow));Set-Acl -LiteralPath $Path -AclObject $security
}
function Stop-AtCheckpoint([string]$Name){
    if($Name -cne $Checkpoint -and -not $Name.StartsWith($Checkpoint+':',[StringComparison]::Ordinal)){return}
    $stream=[IO.File]::Open($MarkerPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$bytes=[Text.Encoding]::ASCII.GetBytes($Name);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    while($true){Start-Sleep -Milliseconds 100}
}
function Publish-AfterPreimageStartStage {
    param([Parameter(Mandatory)]$Document,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$EventName)
    $finalPath=[IO.Path]::GetFullPath($Path)
    $tempPath=Join-Path (Split-Path -Parent $finalPath) ('.after-preimage-start.'+[Guid]::NewGuid().ToString('N')+'.tmp')
    $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes(($Document|ConvertTo-Json -Compress -Depth 10))
    $published=$false;$stageEvent=$null
    try{
        $stream=[IO.File]::Open($tempPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        [IO.File]::Move($tempPath,$finalPath,$false);$published=$true
        $stageEvent=[Threading.EventWaitHandle]::OpenExisting($EventName)
        if(-not $stageEvent.WaitOne(300000)){throw 'after-preimage typed stage release timed out'}
    }finally{
        if($stageEvent){$stageEvent.Dispose()}
        if(-not $published -and (Test-Path -LiteralPath $tempPath -PathType Leaf)){[IO.File]::Delete($tempPath)}
    }
}

$repoRoot=Join-Path $FixtureRoot 'repo';$git=Get-CanonicalGitContext -RepoRoot $repoRoot;$paths=Get-CanonicalTransactionContractPaths -GitContext $git
$private=Join-Path $FixtureRoot 'private';$canonicalRoot=Join-Path $private 'canonical-recovery';$control=Join-Path $private 'control';$backup=Join-Path $private 'backups';$probe=Join-Path $FixtureRoot 'probe'
foreach($path in @($canonicalRoot,$control,$backup,$probe)){[IO.Directory]::CreateDirectory($path)|Out-Null};foreach($path in @($canonicalRoot,$control,$backup)){Set-CurrentUserOnlyAcl $path};[IO.Directory]::CreateDirectory((Join-Path $control 'canonical-roots'))|Out-Null
$setupPayload=New-CanonicalSetupPlanPayload -RepoRoot $repoRoot -CanonicalRecoveryRoot $canonicalRoot -ControlBase $control -BackupRoot $backup -ProbeRoot $probe
$setupState=New-CanonicalFinalSetupState -PlanPayload $setupPayload -RepoRoot $repoRoot;Write-SemanticJson $paths.SetupStatePath $setupState;Write-SemanticJson (Join-Path $control (Join-Path 'canonical-roots' ($setupState.RepoId+'.json'))) $setupPayload.ExpectedRootClaim
$setupLock=Enter-CanonicalRepoLock -LockPath $paths.LockPath -AllowCreate;Exit-CanonicalRepoLock $setupLock
$namespace=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $TransactionId)
$baseKind=if($Kind -like 'directory*'){'directory'}elseif($Kind -like 'file*'){'file'}else{'parent'}
$targetPath=if($baseKind -eq 'parent'){[IO.Directory]::CreateDirectory((Join-Path $repoRoot 'skills-source'))|Out-Null;Join-Path $repoRoot 'skills-source/shared'}elseif($baseKind -eq 'directory'){Join-Path $repoRoot 'skills-source/shared/hardkill-target'}else{Join-Path $repoRoot 'manifests/managed-skills.txt'}
$targetParent=Split-Path -Parent $targetPath;if(-not(Test-Path -LiteralPath $targetParent)){[IO.Directory]::CreateDirectory($targetParent)|Out-Null}
$targetKind=if($baseKind -eq 'parent'){'parent-directory'}elseif($baseKind -eq 'directory'){'directory'}else{'file'};$role=if($baseKind -eq 'parent'){'parent'}elseif($baseKind -eq 'directory'){'canonical'}else{'manifest'}
$platform=if($baseKind -eq 'file'){'Union'}else{$null}
$targetId=Get-CanonicalJournalTargetId -Order 0 -TargetKind $targetKind -Role $role -Platform $platform -TargetPath $targetPath
$recovery=Join-Path $canonicalRoot (Join-Path $git.WorktreeId $TransactionId);[IO.Directory]::CreateDirectory((Join-Path $recovery 'staged'))|Out-Null
$stagedPath=Join-Path $recovery ("staged/$targetId")
$missing=[ordered]@{State='MISSING'}
if($baseKind -eq 'parent'){
    $emptyProbe=Join-Path $FixtureRoot 'empty-directory-hash-probe';[IO.Directory]::CreateDirectory($emptyProbe)|Out-Null;$emptyHash=(Get-SafeTreeSnapshot -Root $emptyProbe).TreeHash;[IO.Directory]::Delete($emptyProbe,$false)
    $current=$missing;$candidate=[ordered]@{State='PRESENT';Hash=$emptyHash}
}elseif($baseKind -eq 'directory'){
    if($Kind -ne 'directory-add'){[IO.Directory]::CreateDirectory($targetPath)|Out-Null;Write-Utf8 (Join-Path $targetPath 'old.txt') 'old'}
    if($Kind -ne 'directory-delete'){[IO.Directory]::CreateDirectory($stagedPath)|Out-Null;Write-Utf8 (Join-Path $stagedPath 'new.txt') 'new'}
    $current=if($Kind -eq 'directory-add'){$missing}else{[ordered]@{State='PRESENT';Hash=(Get-SafeTreeSnapshot -Root $targetPath).TreeHash}}
    $candidate=if($Kind -eq 'directory-delete'){$missing}else{[ordered]@{State='PRESENT';Hash=(Get-SafeTreeSnapshot -Root $stagedPath).TreeHash}}
}else{
    if($Kind -ne 'file-add'){
        if($Checkpoint -ceq 'during-preimage-copy'){
            $large=[byte[]]::new(64MB);for($index=0;$index -lt $large.Length;$index+=4096){$large[$index]=[byte]($index%251)};[IO.File]::WriteAllBytes($targetPath,$large)
        }else{Write-Utf8 $targetPath 'old'}
    }
    Write-Utf8 $stagedPath 'new'
    $current=if($Kind -eq 'file-add'){$missing}else{[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $targetPath).Hash}};$candidate=[ordered]@{State='PRESENT';Hash=(Get-CanonicalObservedPathState $stagedPath).Hash}
}
$script:target=[ordered]@{
    TargetId=$targetId;Order=0;TargetKind=$targetKind;Role=$role;TargetPath=[IO.Path]::GetFullPath($targetPath)
    PreimagePath=Join-Path $recovery ("preimage/$targetId");SwapOldPath=Join-Path $recovery ("swap-old/$targetId");StagedPath=[IO.Path]::GetFullPath($stagedPath)
    Current=$current;Candidate=$candidate;TargetContextHash=[string](Resolve-TargetContext -Path $targetPath -Mode MetadataOnly).RequestedInitialRootContextHash
}
if($platform){$script:target.Platform=$platform}
$targets=@($script:target)
if($baseKind -eq 'parent'){
    $dependentPath=Join-Path $targetPath 'hardkill-dependent';$dependentId=Get-CanonicalJournalTargetId -Order 1 -TargetKind directory -Role canonical -TargetPath $dependentPath
    $dependentStaged=Join-Path $recovery ("staged/$dependentId");[IO.Directory]::CreateDirectory($dependentStaged)|Out-Null;Write-Utf8 (Join-Path $dependentStaged 'new.txt') 'new-dependent'
    $dependent=[ordered]@{
        TargetId=$dependentId;Order=1;TargetKind='directory';Role='canonical';TargetPath=[IO.Path]::GetFullPath($dependentPath)
        PreimagePath=Join-Path $recovery ("preimage/$dependentId");SwapOldPath=Join-Path $recovery ("swap-old/$dependentId");StagedPath=[IO.Path]::GetFullPath($dependentStaged)
        Current=$missing;Candidate=[ordered]@{State='PRESENT';Hash=(Get-SafeTreeSnapshot -Root $dependentStaged).TreeHash};TargetContextHash=[string](Resolve-TargetContext -Path $dependentPath -Mode MetadataOnly).RequestedInitialRootContextHash
    }
    $targets=@($script:target,$dependent)
}
$header=[ordered]@{
    SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$TransactionId;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64)
    OriginalPlanHash=('2'*64);RepoId=(Get-CanonicalRepoIdentity $git);GitCommonDirHash=[string]$git.GitCommonDirHash;WorktreeId=[string]$git.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($namespace)
    RecoveryTransactionRoot=[IO.Path]::GetFullPath($recovery);ExpectedPostconditionsHash=('6'*64);Targets=@($targets)
}
$null=New-CanonicalJournalHeader -Document $header -TransactionNamespace $namespace
if($Checkpoint -ceq 'after-preimage-copy'){
    $stageSource=Get-CanonicalObservedPathState -Path ([string]$script:target.TargetPath) -ExpectedKind file
    if([string]$stageSource.Hash -cne [string]$script:target.Current.Hash){throw 'after-preimage stage source differs from the journal header Current contract'}
    Publish-AfterPreimageStartStage -Path $AfterPreimageStagePath -EventName $AfterPreimageStageEventName -Document ([ordered]@{
        SchemaVersion=1;ArtifactKind='sealed-after-preimage-stage';Stage='preimage-start';TransactionId=$TransactionId
        TransactionNamespace=[IO.Path]::GetFullPath($namespace);TargetId=[string]$script:target.TargetId;TargetPath=[string]$script:target.TargetPath
        TargetIdentity=[string]$stageSource.Identity;TargetHash=[string]$stageSource.Hash
    })
}
$null=Initialize-CanonicalTransactionPreimages -TransactionNamespace $namespace
if($baseKind -eq 'parent'){$null=Invoke-CanonicalParentDirectoryCreate -TransactionNamespace $namespace -Target $script:target;exit 0}
if($baseKind -eq 'directory'){$null=Invoke-CanonicalDirectoryReplacement -TransactionNamespace $namespace -Target $script:target;exit 0}
$null=Invoke-CanonicalFileReplacement -TransactionNamespace $namespace -Target $script:target
$targetSetHash=Get-SemanticJsonHash -InputObject @([ordered]@{TargetId=$targetId;Current=$current;Candidate=$candidate})
if($TerminalOutcome -eq 'committed'){
    Stop-AtCheckpoint 'before-postconditions'
    $post=Add-CanonicalJournalRecord -TransactionNamespace $namespace -Phase POSTCONDITIONS_OK -Data ([ordered]@{PostconditionsHash=('6'*64)})
    Stop-AtCheckpoint 'after-postconditions'
    $result=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='PASS';TransactionId=$TransactionId;CanonicalOperationKind='normalize'
        OriginalDocumentHash=('1'*64);ResultBaseHeadHash=[string]$post.Hash;Outcome='committed';PlanHash=('2'*64);PostconditionsHash=('6'*64)
        ArtifactStates=@([ordered]@{Name='targets';Status='COMPLETE';Hash=$targetSetHash})
    }
}else{
    $mutationState=Read-CanonicalJournalDirectory -TransactionNamespace $namespace -AllowUnfinished
    $reconciliation=Get-CanonicalTargetReconciliation -Target $script:target -Records @($mutationState.Records)
    Restore-CanonicalMutationTarget -Target $script:target -Reconciliation $reconciliation
    $restorationHash=Get-SemanticJsonHash -InputObject ([ordered]@{TransactionId=$TransactionId;Targets=@([ordered]@{TargetId=$targetId;Current=$current})})
    $result=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='FAIL';TransactionId=$TransactionId;CanonicalOperationKind='normalize'
        OriginalDocumentHash=('1'*64);ResultBaseHeadHash=[string]$mutationState.DerivedJournalHeadHash;Outcome='failed-restored';RestorationHash=$restorationHash;FinalStateHash=$restorationHash
        ArtifactStates=@([ordered]@{Name='targets';Status='COMPLETE';Hash=$targetSetHash})
    }
}
Stop-AtCheckpoint 'before-result'
$resultPublish=Publish-CanonicalTransactionResult -TransactionNamespace $namespace -Document $result
Stop-AtCheckpoint 'after-result'
Stop-AtCheckpoint 'before-complete'
$null=Add-CanonicalJournalRecord -TransactionNamespace $namespace -Phase COMPLETE -Data ([ordered]@{ResultHash=[string]$resultPublish.Hash;OriginalDocumentHash=('1'*64);Outcome=$TerminalOutcome;ClosingKind='original';ClosingDocumentHash=('1'*64)})
Stop-AtCheckpoint 'after-complete'
