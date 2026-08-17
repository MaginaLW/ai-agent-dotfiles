#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [ValidateSet('setup','normalize','promote','merge')] [string] $OperationKind,
    [string] $PlanPath,
    [switch] $DryRun,
    [switch] $Apply,
    [string] $CandidateWorkspace,
    [string] $InputPath,
    [string[]] $RewriteList=@(),
    [string] $CanonicalPreflightOutputRoot,
    [string] $CanonicalRecoveryRoot,
    [string] $ControlBase,
    [string] $BackupRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-command-result.ps1')

$ToolchainRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$commandKind="canonical-$OperationKind"
$document=$null
$failureMessageId='canonical-command-failed'

try {
    if ($DryRun -eq $Apply) { throw 'Specify exactly one of -DryRun or -Apply.' }
    if ([string]::IsNullOrWhiteSpace($PlanPath)) { throw 'Canonical transaction requires -PlanPath; interactive parameter prompting is disabled.' }
    $RepoRoot=[System.IO.Path]::GetFullPath($RepoRoot)
    $null=Get-CanonicalGitContext -RepoRoot $RepoRoot

    if ($Apply) {
        foreach ($name in @('CandidateWorkspace','InputPath','CanonicalPreflightOutputRoot','CanonicalRecoveryRoot','ControlBase','BackupRoot')) {
            if ($PSBoundParameters.ContainsKey($name)) { throw "-$name is not accepted with canonical -Apply; the reviewed plan owns that value." }
        }
        $failureMessageId='canonical-plan-not-found'
        $applyPlanResolution=Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf
        if(-not $applyPlanResolution.Exists){throw 'Apply requires an existing reviewed PlanPath.'}
        $failureMessageId='canonical-plan-stale'
        $document=Read-CanonicalTransactionPlan -PlanPath $PlanPath -RepoRoot $RepoRoot -ExpectedOperationKind $OperationKind -ToolchainRoot $ToolchainRoot
        Assert-CanonicalDocumentHashNotConsumed -DocumentHash ([string]$document.DocumentHash)
        $null=Assert-CanonicalPlanCurrent -Document $document -PlanPath $PlanPath -ToolchainRoot $ToolchainRoot
        $failureMessageId='canonical-command-failed'
        $resultDocument=New-CanonicalPublicCommandResult -Result FAIL -CommandKind $commandKind -MessageToken canonical-apply-interlocked -PlanHash ([string]$document.PlanHash)
        Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
        [Console]::Error.WriteLine('canonical-apply-interlocked')
        exit 75
    }

    $planResolution=Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf
    if ($planResolution.Exists) { throw "Canonical PlanPath must be create-new: $($planResolution.FullPath)" }

    $payload=$null
    if ($OperationKind -eq 'setup') {
        foreach ($name in @('CanonicalRecoveryRoot','ControlBase','BackupRoot','CanonicalPreflightOutputRoot')) {
            if (-not $PSBoundParameters.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string](Get-Variable -Name $name -ValueOnly))) { throw "canonical setup requires -$name." }
        }
        foreach ($name in @('CandidateWorkspace','InputPath')) { if ($PSBoundParameters.ContainsKey($name)) { throw "canonical setup rejects -$name." } }
        $outputRoot=[System.IO.Path]::GetFullPath($CanonicalPreflightOutputRoot)
        $probeArtifact=Join-Path $outputRoot 'setup-preflight-placeholder.json'
        $null=Resolve-CanonicalPreflightArtifactPath -Path $probeArtifact -CanonicalPreflightOutputRoot $outputRoot -RepoRoot $RepoRoot -ForbiddenRoots @($CanonicalRecoveryRoot,$ControlBase,$BackupRoot) -AllowMissingLeaf
        if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { [System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null }
        $payload=New-CanonicalSetupPlanPayload -RepoRoot $RepoRoot -CanonicalRecoveryRoot $CanonicalRecoveryRoot -ControlBase $ControlBase -BackupRoot $BackupRoot -ProbeRoot $outputRoot -ToolchainRoot $ToolchainRoot
    }
    else {
        foreach ($name in @('CandidateWorkspace','InputPath','CanonicalPreflightOutputRoot')) {
            if (-not $PSBoundParameters.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string](Get-Variable -Name $name -ValueOnly))) { throw "$OperationKind requires -$name." }
        }
        foreach ($name in @('CanonicalRecoveryRoot','ControlBase','BackupRoot')) { if ($PSBoundParameters.ContainsKey($name)) { throw "$OperationKind rejects setup field -$name." } }
        $candidate=(Resolve-Path -LiteralPath $CandidateWorkspace).Path
        $source=(Resolve-Path -LiteralPath (Join-Path $candidate 'skills-source')).Path
        $outputRoot=[System.IO.Path]::GetFullPath($CanonicalPreflightOutputRoot)
        $buildResult=Join-Path $outputRoot 'build-result.json'
        $scanResult=Join-Path $outputRoot 'scan-result.json'
        $artifactManifest=Join-Path $outputRoot 'artifact-manifest.json'
        $artifactValidationSummary=Join-Path $outputRoot 'artifact-validation-summary.json'
        $buildArgs=@(
            '-RepoRoot',$ToolchainRoot,'-CanonicalPreflight','-CandidateWorkspace',$candidate,'-SourceRoot',$source,
            '-ClaudeOutputRoot',(Join-Path $candidate 'claude/skills'),'-CodexOutputRoot',(Join-Path $candidate 'codex/skills'),
            '-ReasonixOutputRoot',(Join-Path $candidate 'reasonix/skills'),'-ManifestOutputRoot',(Join-Path $candidate 'manifests'),
            '-CanonicalPreflightOutputRoot',$outputRoot,'-JsonPath',$buildResult
        )
        $failureMessageId='canonical-preflight-failed'
        $null=Invoke-CanonicalPreflightChild -ToolchainRoot $ToolchainRoot -ScriptName 'build-skills.ps1' -Arguments $buildArgs -ResultPath $buildResult -SchemaPath (Join-Path $ToolchainRoot 'schemas/run-report.schema.json')
        $scanArgs=@(
            '-RepoRoot',$ToolchainRoot,'-CanonicalPreflight','-SourceRoot',$candidate,'-CanonicalPreflightOutputRoot',$outputRoot,
            '-ScannerConfigPath',(Join-Path $ToolchainRoot '.gitleaks.toml'),'-JsonPath',$scanResult
        )
        $null=Invoke-CanonicalPreflightChild -ToolchainRoot $ToolchainRoot -ScriptName 'scan-secrets.ps1' -Arguments $scanArgs -ResultPath $scanResult -SchemaPath (Join-Path $ToolchainRoot 'schemas/secret-scan.schema.json')
        $null=Publish-CanonicalPreflightArtifactValidation -ToolchainRoot $ToolchainRoot -RepoRoot $RepoRoot -CanonicalPreflightOutputRoot $outputRoot -BuildResultPath $buildResult -ScanResultPath $scanResult -ArtifactManifestPath $artifactManifest -ArtifactValidationSummaryPath $artifactValidationSummary -ForbiddenRoots @($candidate)
        $payload=New-CanonicalSkillPlanPayload -OperationKind $OperationKind -RepoRoot $RepoRoot -CandidateWorkspace $candidate -InputPath $InputPath -RewriteList $RewriteList -CanonicalPreflightOutputRoot $outputRoot -BuildResultPath $buildResult -ScanResultPath $scanResult -ArtifactManifestPath $artifactManifest -ArtifactValidationSummaryPath $artifactValidationSummary -ToolchainRoot $ToolchainRoot
        $failureMessageId='canonical-command-failed'
    }

    $document=Write-CanonicalTransactionPlan -PlanPayload $payload -PlanPath $planResolution.FullPath -RepoRoot $RepoRoot -ToolchainRoot $ToolchainRoot
    $resultDocument=New-CanonicalPublicCommandResult -Result PASS -CommandKind $commandKind -MessageToken canonical-plan-created -PlanHash ([string]$document.PlanHash)
    Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
}
catch {
    $planHash=$null
    if ($null -ne $document -and $document -is [System.Collections.IDictionary] -and $document.Contains('PlanHash') -and [string]$document.PlanHash -cmatch '^[0-9a-f]{64}$') {
        $planHash=[string]$document.PlanHash
    }
    $failure=Write-CanonicalPublicCommandFailure -Exception $_.Exception -CommandKind $commandKind -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath -FallbackMessageToken $failureMessageId -PlanHash $planHash
    exit ([int]$failure.ExitCode)
}
