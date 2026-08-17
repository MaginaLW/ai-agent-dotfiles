#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolchainRoot,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f-]{36}$')][string]$TransactionId,
    [Parameter(Mandatory)][string]$StageRoot,
    [Parameter(Mandatory)][string]$StageEventName,
    [ValidateSet('entering','visited')][string]$StagePosition='visited',
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$StopTargetId,
    [ValidateRange(1,600)][int]$StageTimeoutSeconds=300
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $ToolchainRoot 'scripts/canonical-recovery-common.ps1')
. (Join-Path $ToolchainRoot 'tests/helpers/canonical-reviewed-recovery-engine.ps1')

$repo=[IO.Path]::GetFullPath($RepoRoot);$git=Get-CanonicalGitContext -RepoRoot $repo;$paths=Get-CanonicalTransactionContractPaths -GitContext $git
$document=Read-CanonicalRecoveryPlan -PlanPath $PlanPath -RepoRoot $repo -ExpectedTransactionId $TransactionId
$lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath
$stageCoordinator=$null
try{
    $state=Get-CanonicalUniqueTransactionState -TransactionsRoot $paths.TransactionsRoot -TransactionId $TransactionId
    $null=Assert-CanonicalRecoveryPlanCurrent -Document $document -State $state -RepoRoot $repo
    $stageCoordinator=[AiAgentDotfilesTests.SealedRecoveryStageCoordinator]::new(
        [IO.Path]::GetFullPath($StageRoot),$StopTargetId,$StageEventName,($StageTimeoutSeconds*1000)
    )
    $engineArguments=@{Document=$document;State=$state;RepoRoot=$repo}
    if($StagePosition -ceq 'entering'){$engineArguments.BeforeRestoreStageCoordinator=$stageCoordinator}
    else{$engineArguments.AfterRestoreStageCoordinator=$stageCoordinator}
    $null=Invoke-SealedCanonicalReviewedRecovery @engineArguments
}finally{
    if($stageCoordinator){$stageCoordinator.Dispose()}
    Exit-CanonicalRepoLock -LockHandle $lock
}
