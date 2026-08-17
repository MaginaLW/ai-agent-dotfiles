#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='Status')]
param(
    [string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory,ParameterSetName='Status')][switch]$Status,
    [Parameter(Mandatory,ParameterSetName='DryRun')][switch]$DryRun,
    [Parameter(Mandatory,ParameterSetName='Apply')][switch]$Apply,
    [Parameter(Mandatory,ParameterSetName='DryRun')]
    [Parameter(Mandatory,ParameterSetName='Apply')]
    [ValidateSet('abandon','rollback','finalize')][string]$Action,
    [Parameter(Mandatory,ParameterSetName='DryRun')]
    [Parameter(Mandatory,ParameterSetName='Apply')]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$TransactionId,
    [Parameter(Mandatory,ParameterSetName='DryRun')]
    [Parameter(Mandatory,ParameterSetName='Apply')]
    [string]$PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ToolchainRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'canonical-recovery-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-command-result.ps1')
$commandKind=if($Status){'canonical-recover-status'}else{"canonical-recover-$Action"}
$document=$null
$lock=$null
$failureMessageId='canonical-command-failed'

try{
    $RepoRoot=[System.IO.Path]::GetFullPath($RepoRoot)
    if($Status){
        $statusDocument=Get-CanonicalRecoveryStatusDocument -RepoRoot $RepoRoot
        Write-CanonicalPublicCommandResult -Document $statusDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
        exit 0
    }

    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
    $paths=Get-CanonicalTransactionContractPaths -GitContext $git
    if(-not(Test-Path -LiteralPath $paths.LockPath -PathType Leaf)){throw 'canonical-lock-missing'}
    $lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath
    $failureMessageId='manual-recovery-required'
    $state=Get-CanonicalUniqueTransactionState -TransactionsRoot $paths.TransactionsRoot -TransactionId $TransactionId
    if($state.IsTerminal){throw 'reviewed-plan-consumed'}
    if($DryRun){
        $payload=Get-CanonicalRecoveryEvidencePayload -State $state -RepoRoot $RepoRoot -Action $Action
        $document=Write-CanonicalRecoveryPlan -PlanPayload $payload -PlanPath $PlanPath -RepoRoot $RepoRoot
        $resultDocument=New-CanonicalPublicCommandResult -Result PASS -CommandKind ("canonical-recover-{0}" -f $Action) -MessageToken ('canonical-recovery-plan-created') -PlanHash ([string]$document.PlanHash)
        Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
        exit 0
    }
    $failureMessageId='canonical-recovery-plan-stale'
    $document=Read-CanonicalRecoveryPlan -PlanPath $PlanPath -RepoRoot $RepoRoot -ExpectedAction $Action -ExpectedTransactionId $TransactionId
    try{
        Assert-CanonicalTransactionSetAllowsDocument -TransactionsRoot $paths.TransactionsRoot -DocumentHash ([string]$document.DocumentHash) -AllowedUnfinishedTransactionId $TransactionId
    }
    catch{
        if($_.Exception.Message -cne 'canonical-recovery-required'){throw}
        $resultDocument=New-CanonicalPublicCommandResult -Result FAIL -CommandKind ("canonical-recover-{0}" -f $Action) -MessageToken ('canonical-recovery-required') -PlanHash ([string]$document.PlanHash)
        Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
        [Console]::Error.WriteLine('canonical-recovery-required')
        exit 1
    }
    $null=Assert-CanonicalRecoveryPlanCurrent -Document $document -State $state -RepoRoot $RepoRoot
    $resultDocument=New-CanonicalPublicCommandResult -Result FAIL -CommandKind ("canonical-recover-{0}" -f $Action) -MessageToken ('canonical-recovery-apply-interlocked') -PlanHash ([string]$document.PlanHash)
    Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
    [Console]::Error.WriteLine('canonical-recovery-apply-interlocked')
    exit 75
}
catch{
    $planHash=$null
    if($null -ne $document -and $document -is [System.Collections.IDictionary] -and $document.Contains('PlanHash') -and [string]$document.PlanHash -cmatch '^[0-9a-f]{64}$'){$planHash=[string]$document.PlanHash}
    $failure=Write-CanonicalPublicCommandFailure -Exception $_.Exception -CommandKind $commandKind -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath -FallbackMessageToken $failureMessageId -PlanHash $planHash
    exit ([int]$failure.ExitCode)
}
finally{if($null -ne $lock){Exit-CanonicalRepoLock -LockHandle $lock}}
