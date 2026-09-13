#requires -Version 7.0
<#
.SYNOPSIS
    Read-only shared-authority assessment for the environment status surfaces.

.DESCRIPTION
    This file is intended to be dot-sourced. It composes the existing read-only
    primitives - the HomeAuthority context resolver, the validated authority
    reader, the canonical controller fingerprint, the lock-bound live parity,
    the legacy evidence assessment, and the lock-free unfinished-journal scan -
    into one deterministic route with exactly one recommended next operation.

    Nothing here takes a lock, writes a file, creates authority, or repairs
    state. The intended-root branch is resolved through the MetadataOnly target
    context (no capability probe, no temp files) and is reported only while no
    schema 3 claims exist.
#>

Set-StrictMode -Version Latest

# The composed readers publish and validate against the repository schema root,
# so a partial repository layout fails closed with a stable token instead of a
# raw path error from a nested module import.
$script:HarnessAuthorityStatusRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path -LiteralPath (Join-Path $script:HarnessAuthorityStatusRepoRoot 'schemas') -PathType Container)) {
    throw 'harness-authority-status-repo-layout-required'
}

. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'harness-env-common.ps1')
. (Join-Path $PSScriptRoot 'shared-authority-state-common.ps1')
. (Join-Path $PSScriptRoot 'home-authority-common.ps1')
. (Join-Path $PSScriptRoot 'live-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')

function Get-HarnessEnvAuthorityRedactedKeyLabel {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $HomeAuthorityKey)

    if ($HomeAuthorityKey -cnotmatch '\A[0-9a-f]{64}\z') { throw 'HomeAuthority key must be a 64-character lowercase hex value' }
    return $HomeAuthorityKey.Substring(0, 12) + '...'
}

function Get-HarnessEnvAuthorityRedactedRootLabel {
    <#
    .SYNOPSIS
        Redacts an intended live-root path for status output.

    .DESCRIPTION
        A root under the home directory loses the home prefix; any other root
        keeps only its drive/volume root and leaf name, so a status document
        never carries a full machine path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $HomeRoot
    )

    $full = [IO.Path]::GetFullPath($Path)
    $homeFull = [IO.Path]::GetFullPath($HomeRoot).TrimEnd([char] 92, [char] 47)
    if ($full.StartsWith($homeFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        return '<home>' + $full.Substring($homeFull.Length)
    }
    $volumeRoot = [IO.Path]::GetPathRoot($full)
    $leaf = [IO.Path]::GetFileName($full)
    return $volumeRoot + '...' + [IO.Path]::DirectorySeparatorChar + $leaf
}

function Get-HarnessEnvAuthorityLiveRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    $platforms = [System.Collections.Generic.List[object]]::new()
    $pristine = $true
    foreach ($row in @($Context.LiveTargets)) {
        $platform = [string] $row.Platform
        $targetContext = $row.TargetContext
        $rootPath = [string] $targetContext.RequestedPath
        $targetStatus = [string] $targetContext.TargetStatus
        if ($targetStatus -cne 'MISSING') { $pristine = $false }
        $managedCount = 0
        if ($targetStatus -cne 'MISSING') {
            $key = $platform.ToLowerInvariant()
            $managedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($name in (Read-HarnessEnvNameList -Path (Join-Path $RepoRoot "manifests/managed-skills.$key.txt"))) {
                [void] $managedNames.Add($name)
            }
            if (Test-Path -LiteralPath $rootPath -PathType Container) {
                $managedCount = @(Get-ChildItem -LiteralPath $rootPath -Directory -Force |
                        Where-Object { $_.Name -ne '.system' } |
                        Where-Object { $managedNames.Contains($_.Name) }).Count
            }
        }
        $platforms.Add([ordered] @{
            Platform = $platform
            Status = $targetStatus
            ManagedCount = $managedCount
        })
    }

    return [ordered] @{
        Pristine = $pristine
        Platforms = @($platforms)
    }
}

function Get-HarnessEnvAuthorityAssessment {
    <#
    .SYNOPSIS
        Computes the single read-only authority route and its recommended next operation.

    .PARAMETER Identity
        Home authority identity. Defaults to the current Windows identity and
        Known Folders; tests may pass the sealed test-adapter identity.

    .PARAMETER ReasonixLiveSkillsPath
        Optional intended custom Reasonix live root. It is legal only while no
        schema 3 claims exist; once claims exist the immutable claim is the only
        selector and the switch is rejected.
    #>
    [CmdletBinding()]
    param(
        [string] $RepoRoot,
        [AllowNull()] [object] $Identity,
        [string] $ReasonixLiveSkillsPath
    )

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    if ($null -eq $Identity) { $Identity = Get-WindowsHomeAuthorityIdentity }
    $context = Resolve-HomeAuthorityContextFromIdentity -Identity $Identity -ReasonixLiveSkillsPath $ReasonixLiveSkillsPath

    $unfinished = @(Get-SealedLiveJournalUnfinishedTransactionIds -TransactionsRoot ([string] $context.LiveTransactionsRoot))
    $recoveryStatus = if ($unfinished.Count -gt 0) { 'unfinished' } else { 'clean' }

    $authorityState = Read-HomeAuthorityState -ControlBase ([string] $context.ControlBase) -HomeAuthorityKey ([string] $context.HomeAuthorityKey) -RepoRoot $repo
    $claimsStatus = [string] $authorityState.ClaimsStatus
    $stateStatus = [string] $authorityState.StateStatus
    $pairStatus = [string] $authorityState.PairStatus
    if ($claimsStatus -ceq 'MISSING' -and -not [string]::IsNullOrWhiteSpace($ReasonixLiveSkillsPath)) {
        # Legal only before the first authority exists; the switch selects the
        # intended initial claim and is resolved metadata-only below.
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ReasonixLiveSkillsPath)) {
        throw 'authority-reasonix-root-switch-forbidden-after-claims'
    }

    $controllerMatch = $null
    $stateSummary = $null
    if ($stateStatus -ceq 'VALID') {
        $controllerFingerprint = Get-CanonicalRepoIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $repo)
        $controllerMatch = [string] $authorityState.StateDocument['ControllerRepoFingerprint'] -ceq $controllerFingerprint
        $receiptReference = $null
        $receiptReferenceHash = $null
        if ($authorityState.StateDocument.Contains('ReceiptId')) {
            $receiptReferenceHash = [string] $authorityState.StateDocument['ReceiptHash']
        }
        else {
            $receiptReference = [string] $authorityState.StateDocument['ReceiptRef']
        }
        $stateSummary = [ordered] @{
            EnvironmentName = [string] $authorityState.StateDocument['EnvironmentName']
            AuthorityGeneration = [long] $authorityState.StateDocument['AuthorityGeneration']
            LastOperationKind = [string] $authorityState.StateDocument['LastOperationKind']
            ReceiptReference = $receiptReference
            ReceiptReferenceHash = $receiptReferenceHash
            EnvironmentLockHash = [string] $authorityState.StateDocument['EnvironmentLockHash']
            TaskOverlayHash = [string] $authorityState.StateDocument['TaskOverlayHash']
        }
    }

    $lockParity = [ordered] @{
        Status = 'not-checked'
        Reasons = @()
        Mismatches = @()
    }
    if ($stateStatus -ceq 'VALID') {
        $lockReasons = [System.Collections.Generic.List[string]]::new()
        $stagingPath = Get-HarnessEnvStagingRoot -RepoRoot $repo -Name ([string] $stateSummary.EnvironmentName)
        $lockPath = Get-HarnessEnvLockPath -StagingPath $stagingPath
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
            $lockParity.Status = 'not-checked'
            $lockReasons.Add('lock-missing')
        }
        else {
            $lockHash = Get-HarnessFileHash -Path $lockPath
            if ([string] $stateSummary.EnvironmentLockHash -ine $lockHash) {
                $lockParity.Status = 'not-checked'
                $lockReasons.Add('lock-drift')
            }
            else {
                $lock = Read-HarnessEnvLock -StagingPath $stagingPath
                $parity = Get-HarnessEnvLockLiveParity -RepoRoot $repo -Lock $lock -HomeRoot ([string] $context.HomeRoot)
                $lockParity.Status = [string] $parity.Status
                $lockParity.Mismatches = @($parity.Mismatches)
            }
        }
        $lockParity.Reasons = @($lockReasons)
    }
    else {
        $lockParity.Reasons = @('state-not-valid')
    }

    $legacy = Get-HarnessLegacyEnvAssessment -RepoRoot $repo -HomeRoot ([string] $context.HomeRoot) -HomeAuthorityKey ([string] $context.HomeAuthorityKey) -TokenSid ([string] $context.TokenSid)
    $liveRoots = Get-HarnessEnvAuthorityLiveRoots -Context $context -RepoRoot $repo

    $intendedRoot = $null
    $reasonixRow = @($context.LiveTargets | Where-Object { [string] $_.Platform -ceq 'Reasonix' })
    if ($reasonixRow.Count -eq 1) {
        $reasonixTarget = $reasonixRow[0].TargetContext
        $intendedRoot = [ordered] @{
            Selection = [string] $reasonixRow[0].Selection
            RequestedInitialRootContextHash = [string] $reasonixTarget.RequestedInitialRootContextHash
            FilesystemCapabilityStatus = [string] $reasonixTarget.FilesystemCapabilityStatus
        }
        if ([string] $reasonixRow[0].Selection -ceq 'explicit-initial-claim') {
            $intendedRoot.RequestedReasonixRoot = Get-HarnessEnvAuthorityRedactedRootLabel -Path ([string] $reasonixTarget.RequestedPath) -HomeRoot ([string] $context.HomeRoot)
        }
    }

    $route = Resolve-HarnessEnvAuthorityRoute -RecoveryStatus $recoveryStatus -ClaimsStatus $claimsStatus -StateStatus $stateStatus -PairStatus $pairStatus -ControllerMatch $controllerMatch -LockParityStatus ([string] $lockParity.Status) -LegacyStatus ([string] $legacy.Status) -OldLockStatus ([string] $legacy.OldLockStatus) -LegacyLiveParityStatus ([string] $legacy.LiveParity.Status) -LiveRootsPristine ([bool] $liveRoots.Pristine)

    if ($route -cin @('initial', 'migrate', 'adopt')) {
        # The intended-root branch accompanies the transitions that may
        # establish a custom Reasonix root.
    }
    else {
        $intendedRoot = $null
    }

    $assessment = [ordered] @{
        Route = $route
        NextOperation = [string] $script:HarnessEnvAuthorityRouteNextOperation[$route]
        HomeAuthorityKeyLabel = Get-HarnessEnvAuthorityRedactedKeyLabel -HomeAuthorityKey ([string] $context.HomeAuthorityKey)
        ControllerMatch = $controllerMatch
        RecoveryStatus = $recoveryStatus
        UnfinishedTransactionIds = @($unfinished)
        RootClaimsStatus = $claimsStatus
        StateStatus = $stateStatus
        PairStatus = $pairStatus
        StateSummary = $stateSummary
        SystemStatus = Get-HarnessEnvCodexSystemStatus -HomeRoot ([string] $context.HomeRoot)
        LiveRoots = $liveRoots
        LockParity = $lockParity
        Legacy = [ordered] @{
            Status = [string] $legacy.Status
            Schema = $legacy.Schema
            EnvName = $legacy.EnvName
            Gap = [string] $legacy.Gap
            Drift = [string] $legacy.Drift
            HomeRootMatches = [bool] $legacy.HomeRootMatches
            OldLockStatus = [string] $legacy.OldLockStatus
            LiveParity = [ordered] @{
                Status = [string] $legacy.LiveParity.Status
                Mismatches = @($legacy.LiveParity.Mismatches)
            }
        }
        IntendedRoot = $intendedRoot
    }
    return $assessment
}
