#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolchainRoot,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$TransactionId,
    [Parameter(Mandatory)][string]$ValidatedMarker,
    [Parameter(Mandatory)][string]$TerminalMarker,
    [Parameter(Mandatory)][string]$ReleaseMarker,
    [ValidateRange(1,300)][int]$WaitSeconds=3
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $ToolchainRoot 'scripts/canonical-transaction-common.ps1')

function Write-SealedMarker {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Value)
    $stream=[System.IO.File]::Open($Path,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try{$bytes=[System.Text.Encoding]::ASCII.GetBytes($Value);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

$git=Get-CanonicalGitContext -RepoRoot $RepoRoot
$paths=Get-CanonicalTransactionContractPaths -GitContext $git
$deadline=[DateTime]::UtcNow.AddSeconds($WaitSeconds)
$lock=$null
do {
    try{$lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath -AllowCreate}
    catch{
        if($_.Exception.Message -notmatch 'operation-lock-busy' -or [DateTime]::UtcNow -ge $deadline){throw}
        Start-Sleep -Milliseconds 50
    }
}while($null -eq $lock)
try{
    $document=Read-CanonicalTransactionPlan -PlanPath $PlanPath -RepoRoot $RepoRoot -ExpectedOperationKind setup -ToolchainRoot $ToolchainRoot
    $null=Assert-CanonicalPlanCurrent -Document $document -PlanPath $PlanPath -ToolchainRoot $ToolchainRoot
    Assert-CanonicalTransactionSetAllowsDocument -TransactionsRoot $paths.TransactionsRoot -DocumentHash ([string]$document.DocumentHash)
    Write-SealedMarker -Path $ValidatedMarker -Value 'validated-under-lock'

    $payload=$document.PlanPayload
    $transactionNamespace=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $TransactionId)
    $recoveryTransactionRoot=Join-Path ([string]$payload.ExpectedSetupStateProjection.CanonicalRecoveryRoot) (Join-Path $git.WorktreeId $TransactionId)
    $header=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$TransactionId;CanonicalOperationKind='setup'
        OriginalDocumentHash=[string]$document.DocumentHash;OriginalPlanHash=[string]$document.PlanHash;RepoId=[string]$payload.ExpectedSetupStateProjection.RepoId
        GitCommonDirHash=[string]$git.GitCommonDirHash;WorktreeId=[string]$git.WorktreeId;TransactionNamespace=[System.IO.Path]::GetFullPath($transactionNamespace)
        RecoveryTransactionRoot=[System.IO.Path]::GetFullPath($recoveryTransactionRoot);ExpectedPostconditionsHash=[string]$payload.ExpectedPostconditionsHash;Targets=@()
        SetupRecovery=[ordered]@{
            ClaimPath=Join-Path ([string]$payload.ExpectedSetupStateProjection.ControlBase) (Join-Path 'canonical-roots' ([string]$payload.ExpectedSetupStateProjection.RepoId+'.json'))
            StatePath=[string]$paths.SetupStatePath;ExpectedClaim=$payload.ExpectedRootClaim;ExpectedClaimHash=[string]$payload.ExpectedRootClaimHash
            ExpectedStateProjection=$payload.ExpectedSetupStateProjection;ExpectedStateProjectionHash=[string]$payload.ExpectedSetupStateProjectionHash
        }
    }
    $headerPublish=New-CanonicalJournalHeader -Document $header -TransactionNamespace $transactionNamespace
    $result=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='PASS';TransactionId=$TransactionId
        CanonicalOperationKind='setup';OriginalDocumentHash=[string]$document.DocumentHash;ResultBaseHeadHash=[string]$headerPublish.Hash
        Outcome='abandoned';ArtifactStates=@([ordered]@{Name='targets';Status='MISSING'})
    }
    $resultPublish=Publish-CanonicalTransactionResult -TransactionNamespace $transactionNamespace -Document $result
    $null=Add-CanonicalJournalRecord -TransactionNamespace $transactionNamespace -Phase COMPLETE -Data ([ordered]@{
        ResultHash=[string]$resultPublish.Hash;OriginalDocumentHash=[string]$document.DocumentHash;Outcome='abandoned'
        ClosingKind='original';ClosingDocumentHash=[string]$document.DocumentHash
    })
    $terminal=Read-CanonicalJournalDirectory -TransactionNamespace $transactionNamespace
    if(-not $terminal.IsTerminal){throw 'sealed critical section did not publish a terminal journal'}
    Write-SealedMarker -Path $TerminalMarker -Value 'terminal-under-lock'

    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(-not(Test-Path -LiteralPath $ReleaseMarker -PathType Leaf)){
        if([DateTime]::UtcNow -ge $deadline){throw 'sealed critical section release marker timed out'}
        Start-Sleep -Milliseconds 50
    }
}
finally{Exit-CanonicalRepoLock -LockHandle $lock}
