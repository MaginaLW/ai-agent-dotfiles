#requires -Version 7.0
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/canonical-recovery-common.ps1')

$script:pass=0;$script:fail=0
function Assert{param([bool]$Condition,[string]$Message)if($Condition){$script:pass++;Write-Host "  PASS  $Message" -ForegroundColor Green}else{$script:fail++;Write-Host "  FAIL  $Message" -ForegroundColor Red}}
function Write-Utf8{param([string]$Path,[string]$Value)$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))}
function Get-ContractState{param([string]$Path,[ValidateSet('auto','file','directory')][string]$Kind='auto')$state=Get-CanonicalObservedPathState -Path $Path -ExpectedKind $Kind;if([string]$state.State -ceq 'MISSING'){return [ordered]@{State='MISSING'}};return [ordered]@{State='PRESENT';Hash=[string]$state.Hash}}
function New-TestTarget{
    param([string]$RecoveryRoot,[ValidateSet('directory','file','parent-directory')][string]$Kind,[string]$TargetPath,[string]$StagedPath,$Current,$Candidate,[int]$Order=0)
    $role=if($Kind -eq 'file'){'manifest'}elseif($Kind -eq 'parent-directory'){'parent'}else{'canonical'}
    $id=Get-CanonicalJournalTargetId -Order $Order -TargetKind $Kind -Role $role -TargetPath $TargetPath
    return [ordered]@{
        TargetId=$id;Order=$Order;TargetKind=$Kind;Role=$role;TargetPath=[IO.Path]::GetFullPath($TargetPath)
        PreimagePath=Join-Path $RecoveryRoot "preimage/$id";SwapOldPath=Join-Path $RecoveryRoot "swap-old/$id"
        StagedPath=if($StagedPath){[IO.Path]::GetFullPath($StagedPath)}else{Join-Path $RecoveryRoot "staged/$id"}
        Current=$Current;Candidate=$Candidate;TargetContextHash=[string](Resolve-TargetContext -Path $TargetPath -Mode MetadataOnly).RequestedInitialRootContextHash
    }
}
function New-TestJournal{
    param([string]$Namespace,[string]$RecoveryRoot,[object[]]$Targets)
    $id=[IO.Path]::GetFileName($Namespace)
    $header=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$id;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);OriginalPlanHash=('2'*64);RepoId=('3'*64);GitCommonDirHash=('4'*64);WorktreeId=('5'*64);TransactionNamespace=[IO.Path]::GetFullPath($Namespace);RecoveryTransactionRoot=[IO.Path]::GetFullPath($RecoveryRoot);ExpectedPostconditionsHash=('6'*64);Targets=@($Targets)}
    $null=New-CanonicalJournalHeader -Document $header -TransactionNamespace $Namespace
}
function New-AttackState{return [pscustomobject]@{Attempted=$false;Blocked=$false;Moved=$false}}
function Invoke-TestParentSwap{
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$Ancestor,[Parameter(Mandatory)][string]$Moved,[Parameter(Mandatory)][scriptblock]$CreateReplacement)
    $State.Attempted=$true
    try{[IO.Directory]::Move($Ancestor,$Moved)}catch{$State.Blocked=$true;return}
    $State.Moved=$true
    & $CreateReplacement $Ancestor
}
function Get-Reconciliation{param($Target,[string]$Namespace)$state=Read-CanonicalJournalDirectory -TransactionNamespace $Namespace -AllowUnfinished;return Get-CanonicalTargetReconciliation -Target $Target -Records @($state.Records)}
function Wait-TestPath{
    param([Parameter(Mandatory)][string]$Path,[int]$TimeoutMilliseconds=15000)
    if(Test-Path -LiteralPath $Path){return $true}
    $parent=Split-Path -Parent $Path;$leaf=Split-Path -Leaf $Path;$watcher=[IO.FileSystemWatcher]::new($parent,$leaf);$watcher.EnableRaisingEvents=$true
    try{$null=$watcher.WaitForChanged([IO.WatcherChangeTypes]::Created,$TimeoutMilliseconds);return Test-Path -LiteralPath $Path}finally{$watcher.Dispose()}
}
function Start-ExternalParentAttack{
    param(
        [Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$TriggerKind,[Parameter(Mandatory)][string]$WatchRoot,
        [Parameter(Mandatory)][string]$Ancestor,[Parameter(Mandatory)][string]$Moved,[string]$Namespace,[string]$Phase,[string]$StopPhase,
        [string]$TargetId,[string]$WorkspaceRole,[string]$TriggerPath,[string]$ExpectedContent,[string]$ProbePath
    )
    $ready=Join-Path $root ("attack-$Name.ready");$result=Join-Path $root ("attack-$Name.json")
    $args=@('-NoProfile','-File',(Join-Path $RepoRoot 'tests/helpers/canonical-parent-rename-attempt-host.ps1'),'-TriggerKind',$TriggerKind,'-WatchRoot',$WatchRoot,'-Ancestor',$Ancestor,'-Moved',$Moved,'-ReadyPath',$ready,'-ResultPath',$result)
    foreach($pair in @(@('TransactionNamespace',$Namespace),@('Phase',$Phase),@('StopPhase',$StopPhase),@('TargetId',$TargetId),@('WorkspaceRole',$WorkspaceRole),@('TriggerPath',$TriggerPath),@('ExpectedContent',$ExpectedContent),@('ProbePath',$ProbePath))){if(-not[string]::IsNullOrWhiteSpace([string]$pair[1])){$args+=@('-'+[string]$pair[0],[string]$pair[1])}}
    $process=Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList $args -PassThru -WindowStyle Hidden
    if(-not(Wait-TestPath -Path $ready)){if(-not $process.HasExited){Stop-Process -Id $process.Id -Force};throw "external parent attack did not arm: $Name"}
    return [pscustomobject]@{Name=$Name;Process=$process;ResultPath=$result}
}
function Complete-ExternalParentAttack{
    param([Parameter(Mandatory)]$Attack)
    if(-not $Attack.Process.WaitForExit(125000)){Stop-Process -Id $Attack.Process.Id -Force;throw "external parent attack timed out: $($Attack.Name)"}
    if(-not(Wait-TestPath -Path $Attack.ResultPath -TimeoutMilliseconds 5000)){throw "external parent attack result is missing: $($Attack.Name)"}
    $result=[IO.File]::ReadAllText($Attack.ResultPath)|ConvertFrom-Json
    Write-Host ("    controller {0}: attempted={1}; blocked={2}; moved={3}; missed={4}" -f $Attack.Name,$result.Attempted,$result.Blocked,$result.Moved,$result.Missed) -ForegroundColor DarkGray
    return $result
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('ai-agent-dotfiles-parent-lease-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    Write-Host "`n[parent handle kernel premise]" -ForegroundColor Cyan
    $kernelAncestor=Join-Path $root 'kernel/ancestor';$kernelParent=Join-Path $kernelAncestor 'parent';$kernelMoved=Join-Path $root 'kernel/ancestor-moved'
    [IO.Directory]::CreateDirectory($kernelParent)|Out-Null;Write-Utf8 (Join-Path $kernelParent 'sentinel.txt') 'unchanged'
    $kernelHandles=$null;$kernelAttack=New-AttackState
    try{$kernelHandles=Open-SafeDirectoryContainmentChain -Path $kernelParent;Invoke-TestParentSwap -State $kernelAttack -Ancestor $kernelAncestor -Moved $kernelMoved -CreateReplacement {param($path)[IO.Directory]::CreateDirectory((Join-Path $path 'parent'))|Out-Null}}
    finally{if($kernelHandles){Close-SafeDirectoryContainmentChain -Handles $kernelHandles}}
    Assert ($kernelAttack.Attempted -and $kernelAttack.Blocked -and -not $kernelAttack.Moved -and [IO.File]::ReadAllText((Join-Path $kernelParent 'sentinel.txt')) -ceq 'unchanged') 'kernel: held parent containment chain blocks ordinary ancestor rename'

    Write-Host "`n[workspace and preimage parent leases]" -ForegroundColor Cyan
    $workspaceRecovery=Join-Path $root 'workspace-forward/recovery';$workspaceMoved=Join-Path $root 'workspace-forward/recovery-moved';$workspaceStaged=Join-Path $workspaceRecovery 'staged/candidate.txt';Write-Utf8 $workspaceStaged 'new'
    $workspaceTarget=Join-Path $root 'workspace-forward/target.txt';Write-Utf8 $workspaceTarget 'old';$workspaceCurrent=Get-ContractState $workspaceTarget file;$workspaceCandidate=Get-ContractState $workspaceStaged file;$workspaceRow=New-TestTarget -RecoveryRoot $workspaceRecovery -Kind file -TargetPath $workspaceTarget -StagedPath $workspaceStaged -Current $workspaceCurrent -Candidate $workspaceCandidate;$workspaceNamespace=Join-Path $root ('workspace-forward/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal $workspaceNamespace $workspaceRecovery @($workspaceRow)
    $workspaceController=Start-ExternalParentAttack -Name workspace -TriggerKind JournalPhase -WatchRoot $workspaceNamespace -Ancestor $workspaceRecovery -Moved $workspaceMoved -Namespace $workspaceNamespace -Phase WORKSPACE_CREATE_INTENT -StopPhase WORKSPACE_CREATED -WorkspaceRole preimage;$workspaceError=$null
    try{Initialize-CanonicalRecoveryWorkspace -TransactionNamespace $workspaceNamespace}catch{$workspaceError=$_.Exception.Message};$workspaceAttack=Complete-ExternalParentAttack $workspaceController
    Assert (-not $workspaceError -and $workspaceAttack.Blocked -and -not $workspaceAttack.Moved -and (Test-Path -LiteralPath (Join-Path $workspaceRecovery 'preimage') -PathType Container) -and (Test-Path -LiteralPath (Join-Path $workspaceRecovery 'swap-old') -PathType Container)) 'workspace mkdir: recovery-root parent lease spans MISSING intent through WORKSPACE_CREATED record'

    $preimageAncestor=Join-Path $root 'preimage-forward/ancestor';$preimageParent=Join-Path $preimageAncestor 'base';$preimageMoved=Join-Path $root 'preimage-forward/ancestor-moved';$preimageTarget=Join-Path $preimageParent 'target.txt';Write-Utf8 $preimageTarget 'old'
    $preimageRecovery=Join-Path $root 'preimage-forward/recovery';$preimageStaged=Join-Path $preimageRecovery 'staged/candidate.txt';Write-Utf8 $preimageStaged 'new';$preimageCurrent=Get-ContractState $preimageTarget file;$preimageCandidate=Get-ContractState $preimageStaged file;$preimageRow=New-TestTarget -RecoveryRoot $preimageRecovery -Kind file -TargetPath $preimageTarget -StagedPath $preimageStaged -Current $preimageCurrent -Candidate $preimageCandidate;$preimageNamespace=Join-Path $root ('preimage-forward/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal $preimageNamespace $preimageRecovery @($preimageRow)
    $preimageController=Start-ExternalParentAttack -Name preimage -TriggerKind JournalPhase -WatchRoot $preimageNamespace -Ancestor $preimageAncestor -Moved $preimageMoved -Namespace $preimageNamespace -Phase PREIMAGE_COPY_INTENT -StopPhase FILE_PREPARED -TargetId $preimageRow.TargetId;$preimageError=$null;$preimagePrepared=$null
    try{$preimagePrepared=Initialize-CanonicalTargetPreimage -TransactionNamespace $preimageNamespace -Target $preimageRow}catch{$preimageError=$_.Exception.Message};$preimageAttack=Complete-ExternalParentAttack $preimageController
    Assert (-not $preimageError -and $preimageAttack.Blocked -and -not $preimageAttack.Moved -and [string]$preimagePrepared.PreimageState.Hash -ceq [string]$preimageCurrent.Hash) 'preimage copy: target and recovery parent leases span exact tuple intent, copy, hash check, and PREPARED record'

    Write-Host "`n[forward primitive parent leases]" -ForegroundColor Cyan
    $parentAncestor=Join-Path $root 'parent-forward/ancestor';$parentBase=Join-Path $parentAncestor 'base';$parentMoved=Join-Path $root 'parent-forward/ancestor-moved';$parentTarget=Join-Path $parentBase 'created'
    [IO.Directory]::CreateDirectory($parentBase)|Out-Null;Write-Utf8 (Join-Path $parentBase 'sentinel.txt') 'original'
    $parentRecovery=Join-Path $root 'parent-forward/recovery';[IO.Directory]::CreateDirectory($parentRecovery)|Out-Null
    $missing=[ordered]@{State='MISSING'};$parentRow=New-TestTarget -RecoveryRoot $parentRecovery -Kind parent-directory -TargetPath $parentTarget -Current $missing -Candidate ([ordered]@{State='PRESENT';Hash=(Get-CanonicalJournalEmptyDirectoryHash)})
    $parentNamespace=Join-Path $root ('parent-forward/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $parentNamespace -RecoveryRoot $parentRecovery -Targets @($parentRow)
    $parentController=Start-ExternalParentAttack -Name parent-forward -TriggerKind JournalPhase -WatchRoot $parentNamespace -Ancestor $parentAncestor -Moved $parentMoved -Namespace $parentNamespace -Phase DIR_CREATE_INTENT -StopPhase DIR_CREATED -TargetId $parentRow.TargetId;$parentError=$null
    try{$null=Invoke-CanonicalParentDirectoryCreate -TransactionNamespace $parentNamespace -Target $parentRow}catch{$parentError=$_.Exception.Message};$parentAttack=Complete-ExternalParentAttack $parentController
    Assert (-not $parentError -and $parentAttack.Blocked -and -not $parentAttack.Moved -and (Test-Path -LiteralPath $parentTarget -PathType Container) -and [IO.File]::ReadAllText((Join-Path $parentBase 'sentinel.txt')) -ceq 'original') 'forward parent create: lease spans precondition, intent, mkdir, postcondition, and DIR_CREATED record'

    $dirAncestor=Join-Path $root 'directory-forward/ancestor';$dirParent=Join-Path $dirAncestor 'base';$dirMoved=Join-Path $root 'directory-forward/ancestor-moved';$dirTarget=Join-Path $dirParent 'target'
    [IO.Directory]::CreateDirectory($dirTarget)|Out-Null;Write-Utf8 (Join-Path $dirTarget 'old.txt') 'old'
    $dirRecovery=Join-Path $root 'directory-forward/recovery';$dirStaged=Join-Path $dirRecovery 'staged/candidate';[IO.Directory]::CreateDirectory($dirStaged)|Out-Null;Write-Utf8 (Join-Path $dirStaged 'new.txt') 'new'
    $dirCurrent=Get-ContractState -Path $dirTarget -Kind directory;$dirCandidate=Get-ContractState -Path $dirStaged -Kind directory;$dirRow=New-TestTarget -RecoveryRoot $dirRecovery -Kind directory -TargetPath $dirTarget -StagedPath $dirStaged -Current $dirCurrent -Candidate $dirCandidate
    $dirNamespace=Join-Path $root ('directory-forward/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $dirNamespace -RecoveryRoot $dirRecovery -Targets @($dirRow)
    $dirController=Start-ExternalParentAttack -Name directory-forward -TriggerKind JournalPhase -WatchRoot $dirNamespace -Ancestor $dirAncestor -Moved $dirMoved -Namespace $dirNamespace -Phase MOVE_OLD_INTENT -StopPhase OLD_MOVED -TargetId $dirRow.TargetId;$dirError=$null
    try{$null=Invoke-CanonicalDirectoryReplacement -TransactionNamespace $dirNamespace -Target $dirRow}catch{$dirError=$_.Exception.Message};$dirAttack=Complete-ExternalParentAttack $dirController
    $dirInstalled=if(-not $dirError){Get-ContractState -Path $dirTarget -Kind directory}else{$null}
    Assert (-not $dirError -and $dirAttack.Blocked -and -not $dirAttack.Moved -and [string]$dirInstalled.Hash -ceq [string]$dirCandidate.Hash) 'forward directory replace: one lease spans old/new moves and both durable post-state records'

    $fileAncestor=Join-Path $root 'file-replace-forward/ancestor';$fileParent=Join-Path $fileAncestor 'base';$fileMoved=Join-Path $root 'file-replace-forward/ancestor-moved';$fileTarget=Join-Path $fileParent 'target.txt'
    Write-Utf8 $fileTarget 'old';$fileRecovery=Join-Path $root 'file-replace-forward/recovery';$fileStaged=Join-Path $fileRecovery 'staged/candidate.txt';Write-Utf8 $fileStaged 'new'
    $fileCurrent=Get-ContractState -Path $fileTarget -Kind file;$fileCandidate=Get-ContractState -Path $fileStaged -Kind file;$fileRow=New-TestTarget -RecoveryRoot $fileRecovery -Kind file -TargetPath $fileTarget -StagedPath $fileStaged -Current $fileCurrent -Candidate $fileCandidate
    $fileNamespace=Join-Path $root ('file-replace-forward/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $fileNamespace -RecoveryRoot $fileRecovery -Targets @($fileRow)
    $fileController=Start-ExternalParentAttack -Name file-forward -TriggerKind JournalPhase -WatchRoot $fileNamespace -Ancestor $fileAncestor -Moved $fileMoved -Namespace $fileNamespace -Phase FILE_REPLACE_INTENT -StopPhase FILE_REPLACED -TargetId $fileRow.TargetId;$fileError=$null
    try{$null=Invoke-CanonicalFileReplacement -TransactionNamespace $fileNamespace -Target $fileRow}catch{$fileError=$_.Exception.Message};$fileAttack=Complete-ExternalParentAttack $fileController
    $fileInstalled=if(-not $fileError){Get-ContractState -Path $fileTarget -Kind file}else{$null}
    Assert (-not $fileError -and $fileAttack.Blocked -and -not $fileAttack.Moved -and [string]$fileInstalled.Hash -ceq [string]$fileCandidate.Hash) 'forward file replace: lease keeps ReplaceFile source, destination, and backup parents stable through FILE_REPLACED'

    $addAncestor=Join-Path $root 'file-add-forward/ancestor';$addParent=Join-Path $addAncestor 'base';$addMoved=Join-Path $root 'file-add-forward/ancestor-moved';$addTarget=Join-Path $addParent 'target.txt'
    [IO.Directory]::CreateDirectory($addParent)|Out-Null;Write-Utf8 (Join-Path $addParent 'sentinel.txt') 'original'
    $addRecovery=Join-Path $root 'file-add-forward/recovery';$addStaged=Join-Path $addRecovery 'staged/candidate.txt';Write-Utf8 $addStaged 'new'
    $addCandidate=Get-ContractState -Path $addStaged -Kind file;$addRow=New-TestTarget -RecoveryRoot $addRecovery -Kind file -TargetPath $addTarget -StagedPath $addStaged -Current $missing -Candidate $addCandidate
    $addNamespace=Join-Path $root ('file-add-forward/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $addNamespace -RecoveryRoot $addRecovery -Targets @($addRow)
    $addController=Start-ExternalParentAttack -Name file-add-forward -TriggerKind JournalPhase -WatchRoot $addNamespace -Ancestor $addAncestor -Moved $addMoved -Namespace $addNamespace -Phase FILE_REPLACE_INTENT -StopPhase FILE_REPLACED -TargetId $addRow.TargetId;$addError=$null
    try{$null=Invoke-CanonicalFileReplacement -TransactionNamespace $addNamespace -Target $addRow}catch{$addError=$_.Exception.Message};$addAttack=Complete-ExternalParentAttack $addController
    Assert (-not $addError -and $addAttack.Blocked -and -not $addAttack.Moved -and [string](Get-ContractState -Path $addTarget -Kind file).Hash -ceq [string]$addCandidate.Hash -and [IO.File]::ReadAllText((Join-Path $addParent 'sentinel.txt')) -ceq 'original') 'forward file add: lease keeps the no-overwrite move bound to the reviewed parent'

    Write-Host "`n[rollback primitive parent leases]" -ForegroundColor Cyan
    $removeAncestor=Join-Path $root 'parent-rollback/ancestor';$removeParent=Join-Path $removeAncestor 'base';$removeMoved=Join-Path $root 'parent-rollback/ancestor-moved';$removeTarget=Join-Path $removeParent 'created'
    [IO.Directory]::CreateDirectory($removeParent)|Out-Null;Write-Utf8 (Join-Path $removeParent 'sentinel.txt') 'original';$removeRecovery=Join-Path $root 'parent-rollback/recovery';[IO.Directory]::CreateDirectory($removeRecovery)|Out-Null
    $removeRow=New-TestTarget -RecoveryRoot $removeRecovery -Kind parent-directory -TargetPath $removeTarget -Current $missing -Candidate ([ordered]@{State='PRESENT';Hash=(Get-CanonicalJournalEmptyDirectoryHash)});$removeNamespace=Join-Path $root ('parent-rollback/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal -Namespace $removeNamespace -RecoveryRoot $removeRecovery -Targets @($removeRow);$null=Invoke-CanonicalParentDirectoryCreate -TransactionNamespace $removeNamespace -Target $removeRow
    $removeRecon=Get-Reconciliation -Target $removeRow -Namespace $removeNamespace;$removeController=Start-ExternalParentAttack -Name parent-rollback -TriggerKind LeaseHeld -WatchRoot (Split-Path -Parent $removeAncestor) -Ancestor $removeAncestor -Moved $removeMoved -ProbePath ($removeMoved+'.probe');$removeError=$null
    try{Restore-CanonicalMutationTarget -Target $removeRow -Reconciliation $removeRecon}catch{$removeError=$_.Exception.Message};$removeAttack=Complete-ExternalParentAttack $removeController
    Assert (-not $removeError -and $removeAttack.Blocked -and -not $removeAttack.Moved -and -not(Test-Path -LiteralPath $removeTarget)) 'rollback parent remove: lease retains reviewed parent identity until the empty directory is deleted'

    $rollbackDirAncestor=Join-Path $root 'directory-rollback/ancestor';$rollbackDirParent=Join-Path $rollbackDirAncestor 'base';$rollbackDirMoved=Join-Path $root 'directory-rollback/ancestor-moved';$rollbackDirTarget=Join-Path $rollbackDirParent 'target'
    [IO.Directory]::CreateDirectory($rollbackDirTarget)|Out-Null;Write-Utf8 (Join-Path $rollbackDirTarget 'old.txt') 'old';$rollbackDirRecovery=Join-Path $root 'directory-rollback/recovery';$rollbackDirStaged=Join-Path $rollbackDirRecovery 'staged/candidate';[IO.Directory]::CreateDirectory($rollbackDirStaged)|Out-Null;Write-Utf8 (Join-Path $rollbackDirStaged 'new.txt') 'new'
    $rollbackDirCurrent=Get-ContractState $rollbackDirTarget directory;$rollbackDirCandidate=Get-ContractState $rollbackDirStaged directory;$rollbackDirRow=New-TestTarget -RecoveryRoot $rollbackDirRecovery -Kind directory -TargetPath $rollbackDirTarget -StagedPath $rollbackDirStaged -Current $rollbackDirCurrent -Candidate $rollbackDirCandidate;$rollbackDirNamespace=Join-Path $root ('directory-rollback/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal $rollbackDirNamespace $rollbackDirRecovery @($rollbackDirRow);$null=Invoke-CanonicalDirectoryReplacement $rollbackDirNamespace $rollbackDirRow
    $rollbackDirRecon=Get-Reconciliation $rollbackDirRow $rollbackDirNamespace;$rollbackDirController=Start-ExternalParentAttack -Name directory-rollback -TriggerKind LeaseHeld -WatchRoot (Split-Path -Parent $rollbackDirAncestor) -Ancestor $rollbackDirAncestor -Moved $rollbackDirMoved -ProbePath ($rollbackDirMoved+'.probe');$rollbackDirError=$null
    try{Restore-CanonicalMutationTarget -Target $rollbackDirRow -Reconciliation $rollbackDirRecon}catch{$rollbackDirError=$_.Exception.Message};$rollbackDirAttack=Complete-ExternalParentAttack $rollbackDirController
    Assert (-not $rollbackDirError -and $rollbackDirAttack.Blocked -and -not $rollbackDirAttack.Moved -and [string](Get-ContractState $rollbackDirTarget directory).Hash -ceq [string]$rollbackDirCurrent.Hash -and [string](Get-ContractState $rollbackDirStaged directory).Hash -ceq [string]$rollbackDirCandidate.Hash) 'rollback directory replace: lease keeps inverse new/old moves on the reviewed parent chain'

    $rollbackFileAncestor=Join-Path $root 'file-replace-rollback/ancestor';$rollbackFileParent=Join-Path $rollbackFileAncestor 'base';$rollbackFileMoved=Join-Path $root 'file-replace-rollback/ancestor-moved';$rollbackFileTarget=Join-Path $rollbackFileParent 'target.txt'
    Write-Utf8 $rollbackFileTarget 'old';$rollbackFileRecovery=Join-Path $root 'file-replace-rollback/recovery';$rollbackFileStaged=Join-Path $rollbackFileRecovery 'staged/candidate.txt';Write-Utf8 $rollbackFileStaged 'new';$rollbackFileCurrent=Get-ContractState $rollbackFileTarget file;$rollbackFileCandidate=Get-ContractState $rollbackFileStaged file;$rollbackFileRow=New-TestTarget -RecoveryRoot $rollbackFileRecovery -Kind file -TargetPath $rollbackFileTarget -StagedPath $rollbackFileStaged -Current $rollbackFileCurrent -Candidate $rollbackFileCandidate;$rollbackFileNamespace=Join-Path $root ('file-replace-rollback/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal $rollbackFileNamespace $rollbackFileRecovery @($rollbackFileRow);$null=Invoke-CanonicalFileReplacement $rollbackFileNamespace $rollbackFileRow
    $rollbackFileRecon=Get-Reconciliation $rollbackFileRow $rollbackFileNamespace;$rollbackFileController=Start-ExternalParentAttack -Name file-rollback -TriggerKind LeaseHeld -WatchRoot (Split-Path -Parent $rollbackFileAncestor) -Ancestor $rollbackFileAncestor -Moved $rollbackFileMoved -ProbePath ($rollbackFileMoved+'.probe');$rollbackFileError=$null
    try{Restore-CanonicalMutationTarget -Target $rollbackFileRow -Reconciliation $rollbackFileRecon}catch{$rollbackFileError=$_.Exception.Message};$rollbackFileAttack=Complete-ExternalParentAttack $rollbackFileController
    Assert (-not $rollbackFileError -and $rollbackFileAttack.Blocked -and -not $rollbackFileAttack.Moved -and [string](Get-ContractState $rollbackFileTarget file).Hash -ceq [string]$rollbackFileCurrent.Hash -and [string](Get-ContractState $rollbackFileStaged file).Hash -ceq [string]$rollbackFileCandidate.Hash) 'rollback file replace: lease keeps ReplaceFile inverse and staged backup on reviewed parents'

    $rollbackAddAncestor=Join-Path $root 'file-add-rollback/ancestor';$rollbackAddParent=Join-Path $rollbackAddAncestor 'base';$rollbackAddMoved=Join-Path $root 'file-add-rollback/ancestor-moved';$rollbackAddTarget=Join-Path $rollbackAddParent 'target.txt'
    [IO.Directory]::CreateDirectory($rollbackAddParent)|Out-Null;Write-Utf8 (Join-Path $rollbackAddParent 'sentinel.txt') 'original';$rollbackAddRecovery=Join-Path $root 'file-add-rollback/recovery';$rollbackAddStaged=Join-Path $rollbackAddRecovery 'staged/candidate.txt';Write-Utf8 $rollbackAddStaged 'new';$rollbackAddCandidate=Get-ContractState $rollbackAddStaged file;$rollbackAddRow=New-TestTarget -RecoveryRoot $rollbackAddRecovery -Kind file -TargetPath $rollbackAddTarget -StagedPath $rollbackAddStaged -Current $missing -Candidate $rollbackAddCandidate;$rollbackAddNamespace=Join-Path $root ('file-add-rollback/'+[Guid]::NewGuid().ToString('D').ToLowerInvariant());New-TestJournal $rollbackAddNamespace $rollbackAddRecovery @($rollbackAddRow);$null=Invoke-CanonicalFileReplacement $rollbackAddNamespace $rollbackAddRow
    $rollbackAddRecon=Get-Reconciliation $rollbackAddRow $rollbackAddNamespace;$rollbackAddLeaseMarker=Join-Path $root 'file-add-rollback.lease-held';$rollbackAddController=Start-ExternalParentAttack -Name file-add-rollback -TriggerKind PathPresent -WatchRoot $root -Ancestor $rollbackAddAncestor -Moved $rollbackAddMoved -TriggerPath $rollbackAddLeaseMarker;$rollbackAddError=$null
    $script:parentLeaseOriginal=${function:Open-CanonicalMutationParentLease};$script:parentLeaseMarker=$rollbackAddLeaseMarker;$script:parentLeaseAttackResult=[string]$rollbackAddController.ResultPath
    function Open-CanonicalMutationParentLease {
        [CmdletBinding()]param([Parameter(Mandatory)][string[]]$LeafPaths,[switch]$RequireLeafParentsExist)
        $lease=& $script:parentLeaseOriginal -LeafPaths $LeafPaths -RequireLeafParentsExist:$RequireLeafParentsExist
        try{
            [IO.File]::WriteAllText([IO.Path]::GetFullPath($script:parentLeaseMarker),'held',[Text.UTF8Encoding]::new($false))
            if(-not(Wait-TestPath -Path $script:parentLeaseAttackResult -TimeoutMilliseconds 60000)){throw 'external parent attack did not acknowledge the held lease'}
            return $lease
        }catch{Close-CanonicalMutationParentLease -Lease $lease;throw}
    }
    try{Restore-CanonicalMutationTarget -Target $rollbackAddRow -Reconciliation $rollbackAddRecon}catch{$rollbackAddError=$_.Exception.Message}finally{Set-Item -LiteralPath Function:\Open-CanonicalMutationParentLease -Value $script:parentLeaseOriginal}
    $rollbackAddAttack=Complete-ExternalParentAttack $rollbackAddController
    Assert (-not $rollbackAddError -and $rollbackAddAttack.Blocked -and -not $rollbackAddAttack.Moved -and [string](Get-CanonicalObservedPathState $rollbackAddTarget).State -ceq 'MISSING' -and [string](Get-ContractState $rollbackAddStaged file).Hash -ceq [string]$rollbackAddCandidate.Hash -and [IO.File]::ReadAllText((Join-Path $rollbackAddParent 'sentinel.txt')) -ceq 'original') 'rollback file add: lease keeps the inverse no-overwrite move on the reviewed parent'

    $leaseCommand=Get-Command Open-CanonicalMutationParentLease -ErrorAction SilentlyContinue
    $forwardSources=@(${function:Initialize-CanonicalRecoveryWorkspace}.Ast.Extent.Text,${function:Initialize-CanonicalTargetPreimage}.Ast.Extent.Text,${function:Invoke-CanonicalParentDirectoryCreate}.Ast.Extent.Text,${function:Invoke-CanonicalDirectoryReplacement}.Ast.Extent.Text,${function:Invoke-CanonicalFileReplacement}.Ast.Extent.Text)
    $restoreSource=${function:Restore-CanonicalMutationTarget}.Ast.Extent.Text
    $mutationSource=[IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/canonical-mutation-common.ps1'))
    Assert ($null -ne $leaseCommand -and @($forwardSources|Where-Object{$_ -notmatch 'Open-CanonicalMutationParentLease|Close-CanonicalMutationParentLease'}).Count -eq 0 -and $restoreSource -match 'Open-CanonicalMutationParentLease|Close-CanonicalMutationParentLease' -and $mutationSource -notmatch 'FailpointProvider|InternalBeforePrimitiveHook') 'structure: every primitive has a parent lease and mutation production exposes no injection seam'
}
catch{$script:fail++;Write-Host "  FAIL  unhandled test error: $($_.Exception.Message)" -ForegroundColor Red;Write-Host $_.ScriptStackTrace -ForegroundColor DarkYellow}
finally{Write-Host '';Write-Host ("Results: {0} passed, {1} failed" -f $script:pass,$script:fail) -ForegroundColor Cyan;if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
if($script:fail -ne 0){exit 1}
