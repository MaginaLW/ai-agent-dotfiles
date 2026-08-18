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
    [ValidateSet('committed','failed-restored')][string]$TerminalOutcome='committed',
    [string]$ContractProbeRequestPath,
    [string]$ContractProbeRequestSha256,
    [string]$MutationEnginePath,
    [string]$ExpectedEngineSha256,
    [string]$ExpectedProbeHostSha256,
    [string]$ContractProbeResultPath,
    [string]$ContractProbeScratchRoot,
    [string]$SealedInvocationFixturePath,
    [string]$SealedInvocationFixtureSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Invoke-HardKillRealPreimageCheckpoint {
    param($TransactionNamespace,$Target,$InvocationContext)
    $null=Initialize-CanonicalRecoveryWorkspace -TransactionNamespace $TransactionNamespace
    $workspaceState=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
    if(@($workspaceState.PendingEntries).Count -ne 0){throw 'real preimage requires an empty pending inventory'}
    $preimageWorkspaceRecords=@();$swapOldWorkspaceRecords=@()
    foreach($record in @($workspaceState.Records)){
        if([string]$record.Phase -in @('WORKSPACE_CREATE_INTENT','WORKSPACE_CREATED')){
            if([string]$record.Data.WorkspaceRole -ceq 'preimage'){$preimageWorkspaceRecords=@($preimageWorkspaceRecords)+@($record)}
            elseif([string]$record.Data.WorkspaceRole -ceq 'swap-old'){$swapOldWorkspaceRecords=@($swapOldWorkspaceRecords)+@($record)}
        }
    }
    if($preimageWorkspaceRecords.Count -ne 2 -or [string]$preimageWorkspaceRecords[0].Phase -cne 'WORKSPACE_CREATE_INTENT' -or
        [string]$preimageWorkspaceRecords[1].Phase -cne 'WORKSPACE_CREATED' -or -not [string]$preimageWorkspaceRecords[1].Data.CreatedIdentity -or
        $swapOldWorkspaceRecords.Count -ne 2 -or [string]$swapOldWorkspaceRecords[0].Phase -cne 'WORKSPACE_CREATE_INTENT' -or
        [string]$swapOldWorkspaceRecords[1].Phase -cne 'WORKSPACE_CREATED' -or -not [string]$swapOldWorkspaceRecords[1].Data.CreatedIdentity){throw 'real preimage durable workspace tail is incomplete'}
    $sourceState=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath) -ExpectedKind file
    if([string]$sourceState.State -cne 'PRESENT' -or -not(Test-CanonicalObservedMatchesContractState -Actual $sourceState -Contract $Target.Current)){throw 'real preimage source differs from the target tuple'}
    Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint PreimageReady -DeclaredVariant RealPreimageFile -ActualBranchState $sourceState.State -Evidence ([ordered]@{EvidenceKind='RealPreimageReady';Target=$Target;PreimageWorkspaceIntent=$preimageWorkspaceRecords[0];PreimageWorkspaceCreated=$preimageWorkspaceRecords[1];SwapOldWorkspaceIntent=$swapOldWorkspaceRecords[0];SwapOldWorkspaceCreated=$swapOldWorkspaceRecords[1];SourceState=$sourceState})
    $null=Initialize-CanonicalTransactionPreimages -TransactionNamespace $TransactionNamespace
}

function Invoke-HardKillRetainedPartialPreimageFixture {
    param($TransactionNamespace,$Target,$InvocationContext)
    $null=Initialize-CanonicalRecoveryWorkspace -TransactionNamespace $TransactionNamespace
    if([string]$Target.TargetKind -cne 'file'){throw 'retained partial preimage requires a file target'}
    $workspaceState=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
    if(@($workspaceState.PendingEntries).Count -ne 0){throw 'retained partial preimage requires an empty pending inventory'}
    $preimageWorkspaceRecords=@();$swapOldWorkspaceRecords=@()
    foreach($record in @($workspaceState.Records)){
        if([string]$record.Phase -in @('WORKSPACE_CREATE_INTENT','WORKSPACE_CREATED')){
            if([string]$record.Data.WorkspaceRole -ceq 'preimage'){$preimageWorkspaceRecords=@($preimageWorkspaceRecords)+@($record)}
            elseif([string]$record.Data.WorkspaceRole -ceq 'swap-old'){$swapOldWorkspaceRecords=@($swapOldWorkspaceRecords)+@($record)}
        }
    }
    if($preimageWorkspaceRecords.Count -ne 2 -or [string]$preimageWorkspaceRecords[0].Phase -cne 'WORKSPACE_CREATE_INTENT' -or
        [string]$preimageWorkspaceRecords[1].Phase -cne 'WORKSPACE_CREATED' -or -not [string]$preimageWorkspaceRecords[1].Data.CreatedIdentity -or
        $swapOldWorkspaceRecords.Count -ne 2 -or [string]$swapOldWorkspaceRecords[0].Phase -cne 'WORKSPACE_CREATE_INTENT' -or
        [string]$swapOldWorkspaceRecords[1].Phase -cne 'WORKSPACE_CREATED' -or -not [string]$swapOldWorkspaceRecords[1].Data.CreatedIdentity){throw 'retained partial preimage durable workspace tail is incomplete'}
    $targetState=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath) -ExpectedKind file
    $preimageState=Get-CanonicalObservedPathState -Path ([string]$Target.PreimagePath)
    $swapState=Get-CanonicalObservedPathState -Path ([string]$Target.SwapOldPath)
    $stagedState=Get-CanonicalObservedPathState -Path ([string]$Target.StagedPath) -ExpectedKind file
    if(-not(Test-CanonicalObservedMatchesContractState -Actual $targetState -Contract $Target.Current) -or
        -not(Test-CanonicalObservedMatchesContractState -Actual $stagedState -Contract $Target.Candidate) -or
        [string]$preimageState.State -cne 'MISSING' -or [string]$swapState.State -cne 'MISSING'){throw 'retained partial preimage tuple is invalid'}
    $intentData=New-CanonicalTargetRecordData -Target $Target -TargetState $targetState -PreimageState $preimageState -SwapOldState $swapState -StagedState $stagedState
    $partialPath=[IO.Path]::GetFullPath([string]$Target.PreimagePath)
    $partialParentPath=Split-Path -Parent $partialPath
    $partialLeaf=Split-Path -Leaf $partialPath
    $sourcePath=[IO.Path]::GetFullPath([string]$Target.TargetPath)
    $sourceParentPath=Split-Path -Parent $sourcePath
    $sourceLeaf=Split-Path -Leaf $sourcePath
    $workspaceHandles=$null;$sourceHandles=$null;$sourceCapture=$null;$partialCapture=$null
    $partialPrimary=$null
    $partialCleanupErrors=[Collections.Generic.List[Exception]]::new()
    try{
        $workspaceHandles=Open-SafeDirectoryContainmentChain -Path $partialParentPath
        $workspaceHandle=$workspaceHandles[$workspaceHandles.Count-1]
        if([string]$workspaceHandle.Info.Identity -cne [string]$preimageWorkspaceRecords[1].Data.CreatedIdentity){throw 'retained partial preimage workspace identity differs from the durable record'}
        $sourceHandles=Open-SafeDirectoryContainmentChain -Path $sourceParentPath
        $sourceParentHandle=$sourceHandles[$sourceHandles.Count-1]
        $sourceCapture=[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($sourceParentHandle,$sourceLeaf)
        if([string]$sourceCapture.Info.Identity -cne [string]$targetState.Identity -or [string]$sourceCapture.ReadResult.Sha256 -cne [string]$targetState.Hash){throw 'retained partial preimage source differs from the durable target tuple'}
        $sourceBytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($sourceCapture,[long]$sourceCapture.ReadResult.Length)
        if($sourceBytes.LongLength -le 1){throw 'retained partial preimage source cannot yield a strict prefix'}
        $payload=[byte[]]::new([int]($sourceBytes.LongLength-1))
        [Array]::Copy($sourceBytes,0,$payload,0,$payload.Length)
        $prefixSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase PREIMAGE_COPY_INTENT -Data $intentData
        $postIntentState=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
        if(@($postIntentState.PendingEntries).Count -ne 0){throw 'retained partial preimage pending inventory changed after intent publication'}
        $partialCapture=[AiAgentDotfiles.NoFollowFile]::CreateAndHashChildRegularFile($workspaceHandle,$partialLeaf,$payload)
        if([long]$partialCapture.ReadResult.Length -ne [long]$payload.LongLength -or [string]$partialCapture.ReadResult.Sha256 -cne $prefixSha256){throw 'retained partial preimage bytes differ from the strict source prefix'}
        $partialEvidence=[ordered]@{EvidenceKind='SyntheticDirectRetainedPartialPreimage';Target=$Target;PreimagePath=$partialPath;PreimageWorkspaceIntent=$preimageWorkspaceRecords[0];PreimageWorkspaceCreated=$preimageWorkspaceRecords[1];SwapOldWorkspaceIntent=$swapOldWorkspaceRecords[0];SwapOldWorkspaceCreated=$swapOldWorkspaceRecords[1];PartialIdentity=[string]$partialCapture.Info.Identity;PartialLength=[long]$partialCapture.ReadResult.Length;PartialRawSha256=[string]$partialCapture.ReadResult.Sha256;SourceIdentity=[string]$sourceCapture.Info.Identity;SourceLength=[long]$sourceCapture.ReadResult.Length;SourceRawSha256=[string]$sourceCapture.ReadResult.Sha256}
        Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint RetainedPartialPreimage -DeclaredVariant RetainedPartialPreimageFile -ActualBranchState $targetState.State -Evidence $partialEvidence
    }catch{
        $partialPrimary=$_.Exception
    }finally{
        if($partialCapture){try{$partialCapture.Dispose()}catch{$null=$partialCleanupErrors.Add($_.Exception)}}
        if($workspaceHandles){try{Close-SafeDirectoryContainmentChain -Handles $workspaceHandles}catch{$null=$partialCleanupErrors.Add($_.Exception)}}
        if($sourceCapture){try{$sourceCapture.Dispose()}catch{$null=$partialCleanupErrors.Add($_.Exception)}}
        if($sourceHandles){try{Close-SafeDirectoryContainmentChain -Handles $sourceHandles}catch{$null=$partialCleanupErrors.Add($_.Exception)}}
    }
    if($null -ne $partialPrimary -or $partialCleanupErrors.Count -ne 0){
        $partialFailures=[Collections.Generic.List[Exception]]::new()
        if($null -ne $partialPrimary){$null=$partialFailures.Add($partialPrimary)}
        foreach($cleanupError in $partialCleanupErrors){$null=$partialFailures.Add($cleanupError)}
        if($partialFailures.Count -eq 1){throw $partialFailures[0]}
        throw [AggregateException]::new('retained-partial-preimage-primary-and-cleanup',[Exception[]]$partialFailures.ToArray())
    }
}

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

if($ContractProbe){
    Invoke-SealedMutationContractProbe -ContractProbeRequestPath $ContractProbeRequestPath -ContractProbeRequestSha256 $ContractProbeRequestSha256 -MutationEnginePath $MutationEnginePath -ExpectedEngineSha256 $ExpectedEngineSha256 -ExpectedProbeHostSha256 $ExpectedProbeHostSha256 -ContractProbeResultPath $ContractProbeResultPath -ContractProbeScratchRoot $ContractProbeScratchRoot
    return
}

. (Microsoft.PowerShell.Management\Join-Path $ToolchainRoot 'scripts/canonical-recovery-common.ps1')


$afterPreimageStageSupplied=-not [string]::IsNullOrWhiteSpace($AfterPreimageStagePath) -or -not [string]::IsNullOrWhiteSpace($AfterPreimageStageEventName)
if($Checkpoint -ceq 'after-preimage-copy'){
    if([string]::IsNullOrWhiteSpace($AfterPreimageStagePath) -or [string]::IsNullOrWhiteSpace($AfterPreimageStageEventName)){throw 'after-preimage requires its complete typed stage contract'}
    $expectedAfterPreimageStage=[IO.Path]::GetFullPath((Join-Path $FixtureRoot 'after-preimage-start.json'))
    if(-not [IO.Path]::GetFullPath($AfterPreimageStagePath).Equals($expectedAfterPreimageStage,[StringComparison]::OrdinalIgnoreCase)){throw 'after-preimage stage path differs from its sealed fixture locator'}
}elseif($afterPreimageStageSupplied){throw 'after-preimage typed stage inputs are forbidden for other checkpoints'}


$normalSetupPaths=@($FixtureRoot,$TransactionId)
foreach($normalSetupPath in $normalSetupPaths){if([string]::IsNullOrWhiteSpace([string]$normalSetupPath)){throw 'normal preimage setup input is missing'}}
$repoRoot=Join-Path $FixtureRoot 'repo';$git=Get-CanonicalGitContext -RepoRoot $repoRoot;$paths=Get-CanonicalTransactionContractPaths -GitContext $git
$private=Join-Path $FixtureRoot 'private';$canonicalRoot=Join-Path $private 'canonical-recovery';$control=Join-Path $private 'control';$backup=Join-Path $private 'backups';$probe=Join-Path $FixtureRoot 'probe'
foreach($path in @($canonicalRoot,$control,$backup,$probe)){[IO.Directory]::CreateDirectory($path)|Out-Null};foreach($path in @($canonicalRoot,$control,$backup)){Set-CurrentUserOnlyAcl $path};$null=[IO.Directory]::CreateDirectory((Join-Path $control 'canonical-roots'))
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
$recovery=Join-Path $canonicalRoot (Join-Path $git.WorktreeId $TransactionId);$null=[IO.Directory]::CreateDirectory((Join-Path $recovery 'staged'))
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
$sealedPreimageSelected=$Checkpoint -ceq 'before-preimage-copy' -or $Checkpoint -ceq 'after-preimage-copy' -or $Checkpoint -ceq 'during-preimage-copy'
$sealedStageArguments=@($MutationEnginePath,$ExpectedEngineSha256,$SealedInvocationFixturePath,$SealedInvocationFixtureSha256)
$sealedStageArgumentCount=[int](-not[string]::IsNullOrWhiteSpace([string]$MutationEnginePath))+[int](-not[string]::IsNullOrWhiteSpace([string]$ExpectedEngineSha256))+[int](-not[string]::IsNullOrWhiteSpace([string]$SealedInvocationFixturePath))+[int](-not[string]::IsNullOrWhiteSpace([string]$SealedInvocationFixtureSha256))
if(($sealedPreimageSelected -and $sealedStageArgumentCount -ne 4) -or (-not $sealedPreimageSelected -and $sealedStageArgumentCount -ne 0)){throw 'sealed preimage stage arguments must be all present or all absent'}
if($sealedPreimageSelected){
    $normalEnginePath=[IO.Path]::GetFullPath($MutationEnginePath)
    $normalEngineBytes=[IO.File]::ReadAllBytes($normalEnginePath)
    $normalEngineSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($normalEngineBytes)).ToLowerInvariant()
    if($normalEngineSha256 -cne $ExpectedEngineSha256){throw 'sealed preimage engine hash mismatch'}
    . $normalEnginePath
    Assert-SealedMutationBehaviorChildPrimitiveAuthority
    $normalFixturePath=[IO.Path]::GetFullPath($SealedInvocationFixturePath)
    $normalFixtureBytes=[IO.File]::ReadAllBytes($normalFixturePath)
    $normalFixtureSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($normalFixtureBytes)).ToLowerInvariant()
    if($normalFixtureSha256 -cne $SealedInvocationFixtureSha256){throw 'sealed preimage invocation fixture hash mismatch'}
    $normalFixtureText=[Text.UTF8Encoding]::new($false,$true).GetString($normalFixtureBytes)
    $sealedInvocationFixture=ConvertFrom-SemanticJson -Json $normalFixtureText
    if([string]$sealedInvocationFixture.HostRawSha256 -cne $ExpectedProbeHostSha256 -or [string]$sealedInvocationFixture.EngineProvenance.RawSha256 -cne $ExpectedEngineSha256){throw 'sealed preimage invocation fixture provenance mismatch'}
    $stageSelector=[AiAgentDotfilesTests.SealedMutationStageSelector]::ParseCanonicalWire($sealedInvocationFixture.Selector,$sealedInvocationFixture.SelectorSha256)
    $InvocationContext=$null
    $contextPrimary=$null
    $contextCleanupErrors=[Collections.Generic.List[Exception]]::new()
    try{
        $InvocationContext=[AiAgentDotfilesTests.SealedMutationInvocationContext]::Open($stageSelector)
        if($Checkpoint -ceq 'before-preimage-copy' -or $Checkpoint -ceq 'after-preimage-copy'){
            Invoke-HardKillRealPreimageCheckpoint -TransactionNamespace $namespace -Target $script:target -InvocationContext $InvocationContext
        }elseif($Checkpoint -ceq 'during-preimage-copy'){
            Invoke-HardKillRetainedPartialPreimageFixture -TransactionNamespace $namespace -Target $script:target -InvocationContext $InvocationContext
        }
        $InvocationContext.Coordinator.AssertMatchedExactlyOnce()
    }catch{
        $contextPrimary=$_.Exception
    }finally{
        if($InvocationContext){try{$InvocationContext.Dispose()}catch{$null=$contextCleanupErrors.Add($_.Exception)};$InvocationContext=$null}
    }
    if($null -ne $contextPrimary -or $contextCleanupErrors.Count -ne 0){
        $contextFailures=[Collections.Generic.List[Exception]]::new()
        if($null -ne $contextPrimary){$null=$contextFailures.Add($contextPrimary)}
        foreach($cleanupError in $contextCleanupErrors){$null=$contextFailures.Add($cleanupError)}
        if($contextFailures.Count -eq 1){throw $contextFailures[0]}
        throw [AggregateException]::new('sealed-preimage-context-primary-and-cleanup',[Exception[]]$contextFailures.ToArray())
    }
    exit 0
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
