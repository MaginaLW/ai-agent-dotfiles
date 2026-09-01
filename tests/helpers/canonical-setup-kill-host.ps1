#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolchainRoot,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f-]{36}$')][string]$TransactionId,
    [Parameter(Mandatory)][ValidateSet('claim','state')][string]$Mode,
    [Parameter(Mandatory)][ValidateSet(
        'before-setup-claim-publish',
        'after-setup-claim-temp-flush',
        'after-setup-claim-publish',
        'before-setup-state-publish',
        'after-setup-state-temp-flush',
        'after-setup-state-publish'
    )][string]$Checkpoint,
    [Parameter(Mandatory)][string]$MarkerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $ToolchainRoot 'scripts/canonical-recovery-common.ps1')

function Write-SemanticJson([string]$Path,$Value){$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllBytes($Path,(ConvertTo-SemanticJsonBytes -InputObject $Value))}
function Set-CurrentUserOnlyAcl([string]$Path){
    $template=Get-CanonicalCurrentUserOnlySecurityTemplate;$sid=[Security.Principal.SecurityIdentifier]::new([string]$template.OwnerSid)
    $security=[Security.AccessControl.DirectorySecurity]::new();$security.SetOwner($sid);$security.SetAccessRuleProtection($true,$false)
    $inherit=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow));Set-Acl -LiteralPath $Path -AclObject $security
}
function Stop-SealedHostAtBoundary([string]$Name,$PreparedArtifact=$null){
    if($Checkpoint -cne $Name){return}
    $preparedEvidence=$null
    if($PreparedArtifact){
        $preparedEvidence=[ordered]@{
            TempPath=[IO.Path]::GetFullPath([string]$PreparedArtifact.TempPath)
            PendingName=[IO.Path]::GetFileName([string]$PreparedArtifact.TempPath)
            Identity=[string]$PreparedArtifact.Identity
            Length=[long]$PreparedArtifact.Length
            Sha256=[string]$PreparedArtifact.Sha256
            SemanticHash=[string]$PreparedArtifact.Hash
            SchemaValidated=$true
            FlushCompleted=$true
        }
    }
    $marker=[ordered]@{SchemaVersion=1;ArtifactKind='sealed-setup-checkpoint';Checkpoint=$Name;PreparedArtifact=$preparedEvidence}
    $bytes=ConvertTo-SemanticJsonBytes -InputObject $marker
    $fullMarkerPath=[IO.Path]::GetFullPath($MarkerPath)
    $markerParent=Split-Path -Parent $fullMarkerPath
    $markerTemp=Join-Path $markerParent ('.'+[IO.Path]::GetFileName($fullMarkerPath)+'.'+[Guid]::NewGuid().ToString('N')+'.tmp')
    $published=$false
    try{
        $stream=[IO.File]::Open($markerTemp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush($true)
        }finally{$stream.Dispose()}
        [IO.File]::Move($markerTemp,$fullMarkerPath,$false)
        $published=$true
    }finally{
        if(-not $published -and (Test-Path -LiteralPath $markerTemp -PathType Leaf)){Remove-Item -LiteralPath $markerTemp -Force}
    }
    [Threading.ManualResetEventSlim]::new($false).Wait()
}
function Invoke-SealedPreparedSetupPublish {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][string]$PendingDirectory,
        [Parameter(Mandatory)][string]$PendingName,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$PreparedCheckpoint
    )
    $finalHandles=$null;$pendingHandles=$null;$prepared=$null
    try{
        $finalHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path (Split-Path -Parent ([IO.Path]::GetFullPath($FinalPath))) -OwnershipReceiver $finalHandlesReceiver
        $finalHandles = $finalHandlesReceiver.GetDeliveredExact()
        $pendingHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path ([IO.Path]::GetFullPath($PendingDirectory)) -OwnershipReceiver $pendingHandlesReceiver
        $pendingHandles = $pendingHandlesReceiver.GetDeliveredExact()
        $prepared=New-CanonicalPreparedJsonArtifact -Document $Document -PendingParent $pendingHandles[$pendingHandles.Count-1] -PendingPath $PendingDirectory -PendingName $PendingName -SchemaPath $SchemaPath
        Stop-SealedHostAtBoundary $PreparedCheckpoint $prepared
        return Publish-CanonicalPreparedJsonArtifact -PreparedArtifact $prepared -FinalParent $finalHandles[$finalHandles.Count-1] -FinalPath $FinalPath
    }finally{
        if($prepared -and $prepared.HeldHandle){$prepared.HeldHandle.Dispose()}
        if($pendingHandles){Close-SafeDirectoryContainmentChain -Handles $pendingHandles}
        if($finalHandles){Close-SafeDirectoryContainmentChain -Handles $finalHandles}
    }
}

$repo=[IO.Path]::GetFullPath($RepoRoot);$git=Get-CanonicalGitContext -RepoRoot $repo;$paths=Get-CanonicalTransactionContractPaths -GitContext $git;$fixture=Split-Path -Parent $repo
$private=Join-Path $fixture 'setup-private';$canonicalRoot=Join-Path $private 'canonical-recovery';$control=Join-Path $private 'control';$backup=Join-Path $private 'backups';$probe=Join-Path $fixture 'setup-probe'
foreach($path in @($canonicalRoot,$control,$backup,$probe)){[IO.Directory]::CreateDirectory($path)|Out-Null};foreach($path in @($canonicalRoot,$control,$backup)){Set-CurrentUserOnlyAcl $path};[IO.Directory]::CreateDirectory((Join-Path $control 'canonical-roots'))|Out-Null
$payload=New-CanonicalSetupPlanPayload -RepoRoot $repo -CanonicalRecoveryRoot $canonicalRoot -ControlBase $control -BackupRoot $backup -ProbeRoot $probe
$namespace=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $TransactionId);$recovery=Join-Path $canonicalRoot (Join-Path $git.WorktreeId $TransactionId);[IO.Directory]::CreateDirectory($recovery)|Out-Null
$claimPath=Join-Path $control (Join-Path 'canonical-roots' ($payload.ExpectedSetupStateProjection.RepoId+'.json'))
$header=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$TransactionId;CanonicalOperationKind='setup';OriginalDocumentHash=('1'*64);OriginalPlanHash=('2'*64);RepoId=[string]$payload.ExpectedSetupStateProjection.RepoId;GitCommonDirHash=[string]$git.GitCommonDirHash;WorktreeId=[string]$git.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($namespace);RecoveryTransactionRoot=[IO.Path]::GetFullPath($recovery);ExpectedPostconditionsHash=[string]$payload.ExpectedPostconditionsHash;Targets=@();SetupRecovery=[ordered]@{ClaimPath=$claimPath;StatePath=[string]$paths.SetupStatePath;ExpectedClaim=$payload.ExpectedRootClaim;ExpectedClaimHash=[string]$payload.ExpectedRootClaimHash;ExpectedStateProjection=$payload.ExpectedSetupStateProjection;ExpectedStateProjectionHash=[string]$payload.ExpectedSetupStateProjectionHash}}
$lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath -AllowCreate;Exit-CanonicalRepoLock $lock;$null=New-CanonicalJournalHeader -Document $header -TransactionNamespace $namespace
$state=Read-CanonicalJournalDirectory -TransactionNamespace $namespace -AllowUnfinished
if($Mode -ceq 'claim'){
    Stop-SealedHostAtBoundary 'before-setup-claim-publish'
    if($Checkpoint -ceq 'after-setup-claim-temp-flush'){
        $null=Add-CanonicalJournalRecord -TransactionNamespace $state.TransactionNamespace -Phase SETUP_CLAIM_INTENT -Data ([ordered]@{ClaimHash=[string]$payload.ExpectedRootClaimHash})
        $null=Invoke-SealedPreparedSetupPublish -Document $payload.ExpectedRootClaim -FinalPath $claimPath -PendingDirectory (Join-Path $state.TransactionNamespace '_pending') -PendingName ('setup-claim-'+[Guid]::NewGuid().ToString('N')+'.tmp') -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-root-claim.schema.json') -PreparedCheckpoint 'after-setup-claim-temp-flush'
        $null=Add-CanonicalJournalRecord -TransactionNamespace $state.TransactionNamespace -Phase SETUP_CLAIM_PUBLISHED -Data ([ordered]@{ClaimHash=[string]$payload.ExpectedRootClaimHash})
    }else{
        $null=Publish-CanonicalSetupClaimUnderJournal -State $state
    }
    Stop-SealedHostAtBoundary 'after-setup-claim-publish'
    exit 0
}
Write-SemanticJson $claimPath $payload.ExpectedRootClaim;$classification=Get-CanonicalTransactionRecoveryClassification -State $state -RepoRoot $repo
if([string]$classification.AllowedAction -cne 'finalize'){throw 'sealed setup state host did not obtain unique finalize classification'}
Stop-SealedHostAtBoundary 'before-setup-state-publish'
if($Checkpoint -ceq 'after-setup-state-temp-flush'){
    $null=Add-CanonicalJournalRecord -TransactionNamespace $state.TransactionNamespace -Phase SETUP_STATE_INTENT -Data ([ordered]@{StateHash=[string]$classification.SetupState.ExpectedFinalStateHash})
    $null=Invoke-SealedPreparedSetupPublish -Document $classification.SetupState.ExpectedFinalState -FinalPath ([string]$paths.SetupStatePath) -PendingDirectory (Join-Path $state.TransactionNamespace '_pending') -PendingName ('setup-state-'+[Guid]::NewGuid().ToString('N')+'.tmp') -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-setup-state.schema.json') -PreparedCheckpoint 'after-setup-state-temp-flush'
    $null=Add-CanonicalJournalRecord -TransactionNamespace $state.TransactionNamespace -Phase SETUP_STATE_PUBLISHED -Data ([ordered]@{StateHash=[string]$classification.SetupState.ExpectedFinalStateHash})
}else{
    $null=Publish-CanonicalSetupFinalStateForRecovery -State $state -Classification $classification
}
Stop-SealedHostAtBoundary 'after-setup-state-publish'
