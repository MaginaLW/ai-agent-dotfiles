#requires -Version 7.0
<#
.SYNOPSIS
    Reviewed environment rollback entry: select one complete environment
    activation receipt and derive a reviewed rollback plan from it.

.DESCRIPTION
    Only -ReceiptPath selects a rollback. The legacy RunId/BackupPath selection
    and the legacy whole-tree rollback implementation are removed; a plan is
    derived by -DryRun and applied by -Apply with the same reviewed plan file.

    Resolution order is final: the sandbox-injected authority (the same surface
    sync and live recovery use) with its complete bootstrap prefix, then the
    external-artifact preflight for the receipt and plan paths, then the
    receipt slot state and its source operation kind. The eligibility
    derivation and the transition itself are wired in the remaining Task 7
    slices, so every invocation that passes the preflight currently fails
    closed with live-rollback-dispatch-not-wired.
#>
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter(Mandatory, ParameterSetName = 'DryRun')]
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [string] $ReceiptPath,
    [Parameter(Mandatory, ParameterSetName = 'DryRun')] [switch] $DryRun,
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [switch] $Apply,
    [Parameter(Mandatory, ParameterSetName = 'DryRun')]
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [string] $PlanPath,
    [Parameter(ParameterSetName = 'DryRun')]
    [Parameter(ParameterSetName = 'Apply')] [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(ParameterSetName = 'DryRun')]
    [Parameter(ParameterSetName = 'Apply')] [string] $JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'home-authority-common.ps1')
. (Join-Path $PSScriptRoot 'backup-receipt-common.ps1')

$script:RollbackHostResolutionRequired = 'live-plan-host-resolution-required'
$script:RollbackAuthorityMissing = 'live-plan-authority-missing'
$script:RollbackNotWired = 'live-rollback-dispatch-not-wired'
$script:RollbackReceiptMissing = 'rollback-receipt-missing'
$script:RollbackReceiptIncomplete = 'rollback-receipt-not-complete'
$script:RollbackSourceKindUnsupported = 'rollback-source-kind-unsupported'
$script:RollbackPlanPathCollision = 'live-recovery-plan-path-collision'

function Resolve-RollbackInternalRoots {
    # Only a genuine sandbox capability with all three prefixed locators may
    # resolve the live surface; anything else fails closed without reading
    # USERPROFILE or an unprefixed INTERNAL_* variable.
    [CmdletBinding()]
    param()

    if (-not (Test-LiveSafetySandboxCapability)) { throw $script:RollbackHostResolutionRequired }
    $homeRoot = $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT
    $backupRoot = $env:AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT
    $controlBase = $env:AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE
    foreach ($value in @($homeRoot, $backupRoot, $controlBase)) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw $script:RollbackHostResolutionRequired }
    }
    return [pscustomobject][ordered]@{
        HomeRoot = [System.IO.Path]::GetFullPath($homeRoot)
        BackupRoot = [System.IO.Path]::GetFullPath($backupRoot)
        ControlBase = [System.IO.Path]::GetFullPath($controlBase)
    }
}

function New-RollbackAuthorityContext {
    # The derived home-authority context must land exactly on the injected
    # control and backup locators, exactly like sync and live recovery.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $ControlBase,
        [Parameter(Mandatory)] [string] $BackupRoot
    )

    $identity = [pscustomobject][ordered]@{
        ResolverVersion = $script:HomeAuthorityResolverVersion
        TokenSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ProfileRoot = $HomeRoot
        RoamingAppDataRoot = (Join-Path $HomeRoot 'AppData\Roaming')
        LocalAppDataRoot = (Join-Path $HomeRoot 'AppData\Local')
    }
    foreach ($folder in @([string] $identity.RoamingAppDataRoot, [string] $identity.LocalAppDataRoot)) {
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    }
    $context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity -ForbiddenRoots @($ControlBase, $BackupRoot)
    if ([System.IO.Path]::GetFullPath([string] $context.ControlBase) -cne [System.IO.Path]::GetFullPath($ControlBase) -or
        [System.IO.Path]::GetFullPath([string] $context.BackupRoot) -cne [System.IO.Path]::GetFullPath($BackupRoot)) {
        throw $script:RollbackHostResolutionRequired
    }
    return $context
}

function Assert-RollbackAuthorityComplete {
    # Rollback never bootstraps the authority prefix; an incomplete prefix
    # fails closed before anything under the control base is interpreted.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $AuthorityContext)

    $complete = $false
    try {
        $status = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $AuthorityContext
        $complete = ([string] $status.Status -ceq 'COMPLETE' -and [long] $status.CompletePrefixLength -eq 7)
    }
    catch {
        if ([string] $_.Exception.Message -ceq 'operation-lock-busy') { throw }
        $complete = $false
    }
    if (-not $complete) { throw $script:RollbackAuthorityMissing }
}

$repoFull = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoRoot).Path)
if ($Apply) {
    # Apply stays behind the Phase 0 production interlock: the reviewed
    # transition must not reach a mutation path before policy is released.
    Assert-LiveSafetyMutationAllowed -Operation 'environment-rollback' -Paths @($repoFull, $ReceiptPath, $PlanPath, $JsonPath)
}

$internalRoots = Resolve-RollbackInternalRoots
$authorityContext = New-RollbackAuthorityContext -HomeRoot $internalRoots.HomeRoot -ControlBase $internalRoots.ControlBase -BackupRoot $internalRoots.BackupRoot
Assert-RollbackAuthorityComplete -AuthorityContext $authorityContext

$receiptResolution = Resolve-PrivateArtifactPath -Path ([System.IO.Path]::GetFullPath($ReceiptPath)) -Role ExternalUserArtifact -RepoRoot $repoFull -AllowMissingLeaf
$receiptFull = [string] $receiptResolution.FullPath
if (-not (Test-Path -LiteralPath $receiptFull -PathType Container)) { throw $script:RollbackReceiptMissing }

$slotState = Get-SealedBackupReceiptSlotState -ReceiptPath $receiptFull
if ($slotState -cne 'COMPLETE') { throw ($script:RollbackReceiptIncomplete + ' (slot is ' + $slotState + ')') }

$sessionReceiptDocumentPath = Join-Path $receiptFull '_meta/receipt.json'
if (-not (Test-Path -LiteralPath $sessionReceiptDocumentPath -PathType Leaf)) {
    throw ($script:RollbackReceiptIncomplete + ' (no receipt document)')
}
$receiptDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($sessionReceiptDocumentPath, [System.Text.UTF8Encoding]::new($false, $true)))
if (-not $receiptDocument.Contains('SourceOperationKind')) { throw $script:RollbackSourceKindUnsupported }
if ([string] $receiptDocument['SourceOperationKind'] -cne 'environment') {
    # Only an environment activation receipt may start a later ordinary
    # rollback; every other producer kind is limited to its own transaction's
    # crash recovery.
    throw ($script:RollbackSourceKindUnsupported + ' (source=' + [string] $receiptDocument['SourceOperationKind'] + ')')
}

$planResolution = Resolve-PrivateArtifactPath -Path ([System.IO.Path]::GetFullPath($PlanPath)) -Role ExternalUserArtifact -RepoRoot $repoFull -AllowMissingLeaf:$DryRun
$planFull = [string] $planResolution.FullPath
if ($DryRun -and (Test-Path -LiteralPath $planFull)) { throw $script:RollbackPlanPathCollision }

# The receipt preflight is complete; the eligibility derivation and the
# reviewed transition arrive with the remaining Task 7 slices.
throw $script:RollbackNotWired
