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
. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')
. (Join-Path $PSScriptRoot 'canonical-command-result.ps1')
$commandKind=if($Status){'canonical-recover-status'}else{"canonical-recover-$Action"}
$document=$null
$lock=$null
$held=$null
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
    $failureMessageId='canonical-command-failed'
    . (Join-Path $PSScriptRoot 'root-claims-registry-common.ps1')
    . (Join-Path $PSScriptRoot 'canonical-production-engine-common.ps1')
    $selection=Get-CanonicalPrivateRootSelection -RepoRoot $RepoRoot
    $authorityContext=Resolve-HomeAuthorityContextFromIdentity -Identity (Get-WindowsHomeAuthorityIdentity)
    if([System.IO.Path]::GetFullPath([string]$authorityContext.ControlBase) -cne [System.IO.Path]::GetFullPath([string]$selection.ControlBase)){throw 'sealed-home-authority-bootstrap-path-mismatch: ControlBase'}
    $bootstrapComplete=$false
    try{
        $bootstrapStatus=Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $authorityContext
        $bootstrapComplete=([string]$bootstrapStatus.Status -ceq 'COMPLETE' -and [long]$bootstrapStatus.CompletePrefixLength -eq 7)
    }
    catch{
        if([string]$_.Exception.Message -ceq 'operation-lock-busy'){throw}
        $bootstrapComplete=$false
    }
    if($bootstrapComplete){
        $witness=$null
        $globalLock=$null
        $canonicalGlobalBinding='UNBOUND_SETUP_WINDOW'
        try{
            if(Test-Path -LiteralPath $paths.SetupStatePath -PathType Leaf){
                try{
                    $witness=Open-CanonicalHeldNamespaceWitness -RepoRoot $RepoRoot -CanonicalLockHandle $lock -ToolchainRoot $ToolchainRoot
                    $canonicalGlobalBinding='BOUND'
                }
                catch{
                    if([string]$_.Exception.Message -cin @('canonical-setup-required','canonical-recovery-required')){
                        $witness=$null
                        $canonicalGlobalBinding='UNBOUND_SETUP_WINDOW'
                    }
                    else{throw}
                }
            }
            if($canonicalGlobalBinding -ceq 'BOUND'){
                $globalLock=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $authorityContext -RequiredCanonicalWitness $witness
                $null=Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $authorityContext -GlobalLockHandle $globalLock -CanonicalWitness $witness
            }
            else{
                $globalLock=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $authorityContext
            }
            $held=[AiAgentDotfiles.SealedHeldCanonicalLiveLockOrder]::CreateExact(
                'canonical-recover','ExistingOnly','NOT_APPLICABLE',[System.IO.Path]::GetFullPath($RepoRoot),
                $lock,$witness,$null,$globalLock,$canonicalGlobalBinding,$authorityContext,$null,$null,$null,'deferred','deferred')
            $lock=$null
            $witness=$null
            $globalLock=$null
            try{$null=Get-SealedHeldLockOrderRecompute -LockOrderHandle $held}
            catch{if([string]$_.Exception.Message -cne 'canonical-recovery-required'){throw}}
        }
        catch{
            if($null -ne $globalLock){try{Exit-HomeAuthorityGlobalLiveLock -LockHandle $globalLock}catch{}}
            if($null -ne $witness){try{Close-CanonicalHeldNamespaceWitness -Witness $witness}catch{}}
            throw
        }
    }
    # The tracked interlock is the mutation gate, not the engine: while
    # interlocked with no sandbox capability this throws and the public CLI
    # contract below stays byte-for-byte. When it returns (sandbox capability
    # now, released policy later), the promoted production recovery engine
    # runs under the locks this CLI already holds; it never re-enters them.
    # The private-root selection is not listed as a capability path: the
    # real-identity roots can never sit inside an OS-temp sandbox root, and
    # they stay gated by the sealed-home-authority-bootstrap-path-mismatch
    # match above plus the engine's own sealed binding checks.
    try{
        Assert-LiveSafetyMutationAllowed -Operation $commandKind -Paths @($RepoRoot,$PlanPath)
    }
    catch{
        $resultDocument=New-CanonicalPublicCommandResult -Result FAIL -CommandKind ("canonical-recover-{0}" -f $Action) -MessageToken ('canonical-recovery-apply-interlocked') -PlanHash ([string]$document.PlanHash)
        Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
        [Console]::Error.WriteLine('canonical-recovery-apply-interlocked')
        exit 75
    }
    $engineState=Invoke-CanonicalProductionRecoveryTransaction -Document $document -State $state -RepoRoot $RepoRoot
    $resultDocument=New-CanonicalPublicCommandResult -Result PASS -CommandKind ("canonical-recover-{0}" -f $Action) -MessageToken ('canonical-recovery-applied') -PlanHash ([string]$document.PlanHash)
    Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
}
catch{
    $planHash=$null
    if($null -ne $document -and $document -is [System.Collections.IDictionary] -and $document.Contains('PlanHash') -and [string]$document.PlanHash -cmatch '^[0-9a-f]{64}$'){$planHash=[string]$document.PlanHash}
    $failure=Write-CanonicalPublicCommandFailure -Exception $_.Exception -CommandKind $commandKind -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath -FallbackMessageToken $failureMessageId -PlanHash $planHash
    exit ([int]$failure.ExitCode)
}
finally{
    if($null -ne $held){
        Exit-SealedHeldCanonicalLiveLockOrder -LockOrderHandle $held
        $lock=$null
    }
    if($null -ne $lock){Exit-CanonicalRepoLock -LockHandle $lock}
}
