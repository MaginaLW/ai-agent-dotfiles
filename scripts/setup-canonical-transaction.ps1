#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='Status')]
param(
    [string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory,ParameterSetName='Status')][switch]$Status,
    [Parameter(Mandatory,ParameterSetName='DryRun')][switch]$DryRun,
    [Parameter(Mandatory,ParameterSetName='Apply')][switch]$Apply,
    [Parameter(ParameterSetName='DryRun')]
    [Parameter(ParameterSetName='Apply')]
    [string]$PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')
$ToolchainRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'canonical-command-result.ps1')
$commandKind=if($Status){'canonical-status'}else{'canonical-setup'}

try{
    $RepoRoot=[System.IO.Path]::GetFullPath($RepoRoot)
    $null=Get-CanonicalGitContext -RepoRoot $RepoRoot

    if($Status){
        $token=Get-CanonicalSetupStatus -RepoRoot $RepoRoot
        $result=if($token -ceq 'canonical-ready'){'PASS'}elseif($token -ceq 'manual-recovery-required'){'FAIL'}else{'WARN'}
        $statusDocument=New-CanonicalPublicCommandResult -Result $result -CommandKind canonical-status -MessageToken $token
        Write-CanonicalPublicCommandResult -Document $statusDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
        if($token -ceq 'manual-recovery-required'){exit 2}
        exit 0
    }

    if([string]::IsNullOrWhiteSpace($PlanPath)){throw 'Canonical setup requires -PlanPath; interactive parameter prompting is disabled.'}

    $transactionScript=Join-Path $PSScriptRoot 'canonical-transaction.ps1'
    if($Apply){
        & pwsh -NoProfile -File $transactionScript -RepoRoot $RepoRoot -OperationKind setup -Apply -PlanPath $PlanPath
        exit $LASTEXITCODE
    }

    $planFull=[System.IO.Path]::GetFullPath($PlanPath)
    $preflightRoot=Split-Path -Parent $planFull
    if(-not(Test-Path -LiteralPath $preflightRoot -PathType Container)){throw 'Canonical setup PlanPath parent must already exist.'}
    $selection=Get-CanonicalPrivateRootSelection -RepoRoot $RepoRoot
    & pwsh -NoProfile -File $transactionScript -RepoRoot $RepoRoot -OperationKind setup -DryRun -PlanPath $planFull `
        -CanonicalRecoveryRoot $selection.CanonicalRecoveryRoot -ControlBase $selection.ControlBase -BackupRoot $selection.BackupRoot `
        -CanonicalPreflightOutputRoot $preflightRoot
    exit $LASTEXITCODE
}
catch{
    $failure=Write-CanonicalPublicCommandFailure -Exception $_.Exception -CommandKind $commandKind -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
    exit ([int]$failure.ExitCode)
}
