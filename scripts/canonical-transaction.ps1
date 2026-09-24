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
        . (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')
        . (Join-Path $PSScriptRoot 'root-claims-registry-common.ps1')
        . (Join-Path $PSScriptRoot 'canonical-recovery-common.ps1')
        . (Join-Path $PSScriptRoot 'canonical-production-engine-common.ps1')
        $held=$null
        $selection=$null
        $authorityContext=$null
        try {
            try {
                $selection=Get-CanonicalPrivateRootSelection -RepoRoot $RepoRoot
                $authorityContext=Resolve-HomeAuthorityContextFromIdentity -Identity (Get-WindowsHomeAuthorityIdentity)
                if ([System.IO.Path]::GetFullPath([string]$authorityContext.ControlBase) -cne [System.IO.Path]::GetFullPath([string]$selection.ControlBase)) {
                    throw 'sealed-home-authority-bootstrap-path-mismatch: ControlBase'
                }
                $held=Enter-SealedHeldCanonicalLiveLockOrder -RepoRoot $RepoRoot -RouteKind $OperationKind -AcquisitionMode ExistingOnly -OverlayApplicability NOT_APPLICABLE -AuthorityContext $authorityContext -ToolchainRoot $ToolchainRoot
            }
            catch {
                $lockToken=[string]$_.Exception.Message
                if ($lockToken -cin @('canonical-lock-missing','live-lock-missing','global-live-lock-missing','canonical-setup-required','home-authority-bootstrap-incomplete') -or
                    $lockToken -like 'home-authority-bootstrap-manual-recovery-required*') {
                    $held=$null
                }
                else { throw }
            }
            if ($held) {
                $null=Get-SealedHeldLockOrderRecompute -LockOrderHandle $held -PlanDocument $document -ExpectedOperationKind $OperationKind
            }
            # The tracked interlock is the mutation gate, not the engine: while
            # interlocked with no sandbox capability this throws and the public
            # CLI contract below stays byte-for-byte. When it returns (sandbox
            # capability now, released policy later), the promoted production
            # engine runs under the held live lock order. The private-root
            # selection is not listed as a capability path: the real-identity
            # roots can never sit inside an OS-temp sandbox root, and they stay
            # gated by the sealed-home-authority-bootstrap-path-mismatch match
            # above plus the engine's own sealed binding checks.
            try {
                Assert-LiveSafetyMutationAllowed -Operation $commandKind -Paths @($RepoRoot,$PlanPath)
            }
            catch {
                $resultDocument=New-CanonicalPublicCommandResult -Result FAIL -CommandKind $commandKind -MessageToken canonical-apply-interlocked -PlanHash ([string]$document.PlanHash)
                Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
                [Console]::Error.WriteLine('canonical-apply-interlocked')
                exit 75
            }
            if ($OperationKind -ceq 'setup') {
                if ($held) {
                    # A complete live prefix cannot re-run SetupBootstrap; the
                    # claim/state crash window belongs to canonical recovery.
                    throw 'canonical-setup-already-complete'
                }
                $held=Enter-SealedHeldCanonicalLiveLockOrder -RepoRoot $RepoRoot -RouteKind setup -AcquisitionMode SetupBootstrap -OverlayApplicability NOT_APPLICABLE -AuthorityContext $authorityContext -PlanPayload $document.PlanPayload -Intent (New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $authorityContext -FilesystemCapabilityHash ([string]$document.PlanPayload.FilesystemCapabilityHash)) -ToolchainRoot $ToolchainRoot
                $null=Invoke-CanonicalProductionSetupTransaction -RepoRoot $RepoRoot -LockOrderHandle $held -Document $document
            }
            else {
                if (-not $held) { throw 'canonical-setup-required' }
                $applyTransactionId=[Guid]::NewGuid().ToString('D').ToLowerInvariant()
                $null=Invoke-CanonicalProductionSkillTransaction -RepoRoot $RepoRoot -PlanPath $PlanPath -OperationKind $OperationKind -TransactionId $applyTransactionId -Document $document
                $null=Assert-CanonicalOwnedTransactionCompletion -Witness $held.CanonicalWitness -RepoRoot $RepoRoot -CanonicalLockHandle $held.CanonicalLockHandle -ExpectedTransactionId $applyTransactionId -ExpectedDocumentHash ([string]$document.DocumentHash) -ExpectedPlanHash ([string]$document.PlanHash) -ExpectedOperationKind $OperationKind -ToolchainRoot $ToolchainRoot
            }
        }
        finally {
            if ($held) { Exit-SealedHeldCanonicalLiveLockOrder -LockOrderHandle $held }
        }
        # Publish success only after releasing the held lock order. A release
        # failure must reach the outer failure emitter before any result exists.
        $resultDocument=New-CanonicalPublicCommandResult -Result PASS -CommandKind $commandKind -MessageToken canonical-apply-committed -PlanHash ([string]$document.PlanHash)
        Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
        # A committed Apply terminates here. Falling through would re-enter the
        # create-new guard of the DryRun path below, so a transaction that had
        # already committed would report canonical-plan-exists with exit 1.
        exit 0
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
