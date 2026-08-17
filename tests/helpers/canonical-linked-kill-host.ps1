#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolchainRoot,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$CanonicalRecoveryRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f-]{36}$')][string]$TransactionId,
    [Parameter(Mandatory)][string]$MarkerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $ToolchainRoot 'scripts/canonical-transaction-common.ps1')

$git=Get-CanonicalGitContext -RepoRoot $RepoRoot;$paths=Get-CanonicalTransactionContractPaths -GitContext $git
$lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath
try{
    $namespace=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $TransactionId)
    $header=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$TransactionId;CanonicalOperationKind='normalize';OriginalDocumentHash=('4'*64);OriginalPlanHash=('2'*64)
        RepoId=(Get-CanonicalRepoIdentity $git);GitCommonDirHash=[string]$git.GitCommonDirHash;WorktreeId=[string]$git.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($namespace)
        RecoveryTransactionRoot=Join-Path ([IO.Path]::GetFullPath($CanonicalRecoveryRoot)) (Join-Path $git.WorktreeId $TransactionId);ExpectedPostconditionsHash=('3'*64);Targets=@()
    }
    $null=New-CanonicalJournalHeader -Document $header -TransactionNamespace $namespace
    $stream=[IO.File]::Open($MarkerPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$bytes=[Text.Encoding]::ASCII.GetBytes('reservation-published');$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    while($true){Start-Sleep -Milliseconds 100}
}
finally{Exit-CanonicalRepoLock -LockHandle $lock}

