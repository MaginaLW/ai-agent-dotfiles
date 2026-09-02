#requires -Version 7.0

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'target-context-common.ps1')

if (-not ('AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;

namespace AiAgentDotfiles {
    public sealed class SealedHeldLiveTargetContextSetReceipt {
        private static readonly ConditionalWeakTable<object, SealedHeldLiveTargetContextSetReceipt> bindings =
            new ConditionalWeakTable<object, SealedHeldLiveTargetContextSetReceipt>();
        private readonly object wrapper;
        private readonly object authorityContext;
        private readonly object canonicalWitness;
        private readonly object globalLockHandle;
        private readonly object initialCodexMarkers;
        private readonly object[] targetLeases;
        private readonly object projection;
        private const int OpenState = 0;
        private const int ClosingState = 1;
        private const int ClosedState = 2;
        private int closeState;
        private readonly object lifecycleGate = new object();
        private int activeReaders;

        private SealedHeldLiveTargetContextSetReceipt(object wrapperValue, object authorityContextValue,
            object canonicalWitnessValue, object globalLockHandleValue, object initialCodexMarkersValue,
            object[] targetLeasesValue, object projectionValue) {
            wrapper = wrapperValue;
            authorityContext = authorityContextValue;
            canonicalWitness = canonicalWitnessValue;
            globalLockHandle = globalLockHandleValue;
            initialCodexMarkers = initialCodexMarkersValue;
            targetLeases = (object[])targetLeasesValue.Clone();
            projection = projectionValue;
        }

        public void BeginReadExact() {
            lock (lifecycleGate) {
                if (Volatile.Read(ref closeState) != OpenState)
                    throw new InvalidOperationException("target-context-plan-stale: held live target set is not open for reading");
                activeReaders++;
            }
        }
        public void EndReadExact() {
            lock (lifecycleGate) {
                if (activeReaders <= 0)
                    throw new InvalidOperationException("target-context-plan-stale: held live target set reader count is invalid");
                activeReaders--;
            }
        }

        private static SealedHeldLiveTargetContextSetReceipt RequireForWrapper(object wrapperValue) {
            SealedHeldLiveTargetContextSetReceipt receipt;
            if (wrapperValue == null || !bindings.TryGetValue(wrapperValue, out receipt) ||
                !Object.ReferenceEquals(receipt.wrapper, wrapperValue)) {
                throw new InvalidOperationException("target-context-plan-stale: held live target set receipt is missing");
            }
            return receipt;
        }

        public static SealedHeldLiveTargetContextSetReceipt BindExact(object wrapperValue, object authorityContextValue,
            object canonicalWitnessValue, object globalLockHandleValue, object initialCodexMarkersValue,
            object[] targetLeasesValue, object projectionValue) {
            if (wrapperValue == null || authorityContextValue == null || canonicalWitnessValue == null ||
                globalLockHandleValue == null || initialCodexMarkersValue == null || targetLeasesValue == null ||
                targetLeasesValue.Length != 3 || projectionValue == null) {
                throw new InvalidOperationException("target-context-plan-stale: held live target set receipt is invalid");
            }
            SealedHeldLiveTargetContextSetReceipt receipt = new SealedHeldLiveTargetContextSetReceipt(
                wrapperValue, authorityContextValue, canonicalWitnessValue, globalLockHandleValue,
                initialCodexMarkersValue, targetLeasesValue, projectionValue);
            try { bindings.Add(wrapperValue, receipt); }
            catch (ArgumentException) { throw new InvalidOperationException("target-context-plan-stale: held live target set receipt is already bound"); }
            return receipt;
        }

        public static SealedHeldLiveTargetContextSetReceipt GetForWrapperExact(object wrapperValue) {
            SealedHeldLiveTargetContextSetReceipt receipt;
            return wrapperValue != null && bindings.TryGetValue(wrapperValue, out receipt) &&
                Object.ReferenceEquals(receipt.wrapper, wrapperValue) ? receipt : null;
        }
        public static object GetWrapperExact(SealedHeldLiveTargetContextSetReceipt receipt) { return receipt == null ? null : receipt.wrapper; }
        public static object GetAuthorityContextExact(SealedHeldLiveTargetContextSetReceipt receipt) { return receipt == null ? null : receipt.authorityContext; }
        public static object GetCanonicalWitnessExact(SealedHeldLiveTargetContextSetReceipt receipt) { return receipt == null ? null : receipt.canonicalWitness; }
        public static object GetGlobalLockHandleExact(SealedHeldLiveTargetContextSetReceipt receipt) { return receipt == null ? null : receipt.globalLockHandle; }
        public static object GetInitialCodexMarkersExact(SealedHeldLiveTargetContextSetReceipt receipt) { return receipt == null ? null : receipt.initialCodexMarkers; }
        public static object[] GetTargetLeasesExact(SealedHeldLiveTargetContextSetReceipt receipt) { return receipt == null ? null : (object[])receipt.targetLeases.Clone(); }
        public static object GetProjectionExact(SealedHeldLiveTargetContextSetReceipt receipt) { return receipt == null ? null : receipt.projection; }
        private static Type FindRequiredType(string typeName) {
            foreach (System.Reflection.Assembly assembly in AppDomain.CurrentDomain.GetAssemblies()) {
                Type candidate = assembly.GetType(typeName, false, false);
                if (candidate != null) return candidate;
            }
            throw new InvalidOperationException("target-context-plan-stale: exact nested receipt type is unavailable");
        }
        private static void ReleaseTargetLeaseExact(object lease) {
            Type receiptType = FindRequiredType("AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt");
            MethodInfo release = receiptType.GetMethod("ReleaseForWrapperExact", BindingFlags.Public | BindingFlags.Static);
            if (release == null) throw new InvalidOperationException("target-context-plan-stale: exact nested receipt release is unavailable");
            try { release.Invoke(null, new object[] { lease }); }
            catch (TargetInvocationException error) { throw error.InnerException ?? error; }
        }
        public static bool GetIsOpenExact(SealedHeldLiveTargetContextSetReceipt receipt) {
            return receipt != null && Volatile.Read(ref receipt.closeState) == OpenState;
        }
        public static bool GetIsClosedExact(SealedHeldLiveTargetContextSetReceipt receipt) {
            return receipt == null || Volatile.Read(ref receipt.closeState) == ClosedState;
        }
        public static string GetCloseStateExact(SealedHeldLiveTargetContextSetReceipt receipt) {
            if (receipt == null) return "CLOSED";
            int state = Volatile.Read(ref receipt.closeState);
            return state == OpenState ? "OPEN" : state == ClosingState ? "CLOSING" : "CLOSED";
        }
        public static bool ReleaseForWrapperExact(object wrapperValue) {
            SealedHeldLiveTargetContextSetReceipt receipt = RequireForWrapper(wrapperValue);
            int observed = Interlocked.CompareExchange(ref receipt.closeState, ClosingState, OpenState);
            if (observed == ClosedState) return false;
            if (observed == ClosingState) throw new InvalidOperationException("target-context-close-active");
            if (observed != OpenState) throw new InvalidOperationException("target-context-plan-stale: held live target set close state is invalid");
            lock (receipt.lifecycleGate) {
                if (receipt.activeReaders != 0) {
                    Volatile.Write(ref receipt.closeState, OpenState);
                    throw new InvalidOperationException("target-context-close-active");
                }
            }

            Exception firstError = null;
            for (int index = receipt.targetLeases.Length - 1; index >= 0; index--) {
                try { ReleaseTargetLeaseExact(receipt.targetLeases[index]); }
                catch (Exception error) { if (firstError == null) firstError = error; }
            }
            if (firstError != null) {
                Volatile.Write(ref receipt.closeState, OpenState);
                throw firstError;
            }
            Volatile.Write(ref receipt.closeState, ClosedState);
            return true;
        }
    }
}
'@
}

function ConvertTo-LiveTargetFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[string]$FieldName='live target')

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$FieldName must be an absolute path"
    }
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) { throw "$FieldName cannot be a UNC path" }
    $rawFull = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($rawFull)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or [IO.Path]::GetRelativePath($volumeRoot, $rawFull) -ceq '.') { throw "$FieldName cannot be a volume root" }
    return $rawFull.TrimEnd([char]92, [char]47)
}

function Assert-LiveTargetPathsDisjoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary[]]$Targets,
        [string[]]$ForbiddenRoots = @()
    )

    for ($leftIndex = 0; $leftIndex -lt $Targets.Count; $leftIndex++) {
        $left = $Targets[$leftIndex]
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $Targets.Count; $rightIndex++) {
            $right = $Targets[$rightIndex]
            if (Test-TargetPathOverlap -Left ([string]$left.Path) -Right ([string]$right.Path)) {
                throw "live-target-overlap: $($left.Platform)/$($right.Platform)"
            }
        }
        foreach ($forbidden in @($ForbiddenRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if (Test-TargetPathOverlap -Left ([string]$left.Path) -Right ([IO.Path]::GetFullPath($forbidden))) {
                throw "live-target-overlap-with-forbidden-root: $($left.Platform)"
            }
        }
    }
}

function Get-CodexLiveRootMarkerSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PreferredPath,
        [Parameter(Mandatory)][string]$FallbackPath
    )

    return [pscustomobject][ordered]@{
        Preferred = Get-NoFollowRootEntryMarker -Path $PreferredPath
        Fallback = Get-NoFollowRootEntryMarker -Path $FallbackPath
    }
}

function Assert-CodexLiveRootMarkerSetUnambiguous {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$MarkerSet)

    $preferredPresent = [string]$MarkerSet.Preferred.EntryType -cne 'MISSING'
    $fallbackPresent = [string]$MarkerSet.Fallback.EntryType -cne 'MISSING'
    if ($preferredPresent -and $fallbackPresent) { throw 'codex-live-root-ambiguous' }
}

function Assert-CodexLiveRootMarkerSetsEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    foreach ($name in @('Preferred','Fallback')) {
        if ([string]$Expected.$name.EntryType -cne [string]$Actual.$name.EntryType -or [string]$Expected.$name.Identity -cne [string]$Actual.$name.Identity) {
            throw 'codex-live-root-selection-drift'
        }
    }
}

function Resolve-LiveTargetContextSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileRoot,
        [Parameter(Mandatory)][string]$RoamingAppDataRoot,
        [string]$ReasonixLiveSkillsPath,
        [string[]]$ForbiddenRoots = @()
    )

    $profile = ConvertTo-LiveTargetFullPath -Path $ProfileRoot -FieldName 'ProfileRoot'
    $roaming = ConvertTo-LiveTargetFullPath -Path $RoamingAppDataRoot -FieldName 'RoamingAppDataRoot'
    $claude = [IO.Path]::GetFullPath((Join-Path $profile '.claude/skills'))
    $codexPreferred = [IO.Path]::GetFullPath((Join-Path $profile '.codex/skills'))
    $codexFallback = [IO.Path]::GetFullPath((Join-Path $profile '.agents/skills'))

    $initialMarkers = Get-CodexLiveRootMarkerSet -PreferredPath $codexPreferred -FallbackPath $codexFallback
    $confirmedInitialMarkers = Get-CodexLiveRootMarkerSet -PreferredPath $codexPreferred -FallbackPath $codexFallback
    Assert-CodexLiveRootMarkerSetUnambiguous -MarkerSet $initialMarkers
    Assert-CodexLiveRootMarkerSetUnambiguous -MarkerSet $confirmedInitialMarkers
    Assert-CodexLiveRootMarkerSetsEqual -Expected $initialMarkers -Actual $confirmedInitialMarkers
    $preferredMarker = $confirmedInitialMarkers.Preferred
    $fallbackMarker = $confirmedInitialMarkers.Fallback
    $preferredPresent = [string]$preferredMarker.EntryType -cne 'MISSING'
    $fallbackPresent = [string]$fallbackMarker.EntryType -cne 'MISSING'
    $codex = if ($fallbackPresent) { $codexFallback } else { $codexPreferred }
    $codexSelection = if ($fallbackPresent) { 'fallback' } elseif ($preferredPresent) { 'preferred' } else { 'preferred-missing' }

    $reasonix = if ([string]::IsNullOrWhiteSpace($ReasonixLiveSkillsPath)) {
        [IO.Path]::GetFullPath((Join-Path $roaming 'reasonix/skills'))
    }
    else {
        ConvertTo-LiveTargetFullPath -Path $ReasonixLiveSkillsPath -FieldName 'ReasonixLiveSkillsPath'
    }
    $reasonixSelection = if ([string]::IsNullOrWhiteSpace($ReasonixLiveSkillsPath)) { 'known-folder-default' } else { 'explicit-initial-claim' }

    $targetSpecs = @(
        [ordered]@{ Platform='Claude'; Path=$claude; Selection='fixed' },
        [ordered]@{ Platform='Codex'; Path=$codex; Selection=$codexSelection },
        [ordered]@{ Platform='Reasonix'; Path=$reasonix; Selection=$reasonixSelection }
    )
    Assert-LiveTargetPathsDisjoint -Targets $targetSpecs -ForbiddenRoots $ForbiddenRoots

    $resolved = [System.Collections.Generic.List[object]]::new()
    foreach ($spec in $targetSpecs) {
        $otherRoots = @($targetSpecs | Where-Object { [string]$_.Platform -cne [string]$spec.Platform } | ForEach-Object { [string]$_.Path })
        $context = Resolve-TargetContext -Path ([string]$spec.Path) -Mode MetadataOnly -HomeRoot $profile -ForbiddenRoots (@($ForbiddenRoots) + $otherRoots)
        if ([string]$context.TargetStatus -ceq 'EXISTS' -and [string]$context.TargetType -cne 'Directory') {
            throw "live target exists but is not a directory: $($spec.Platform)"
        }
        $resolved.Add([pscustomobject][ordered]@{
            Platform = [string]$spec.Platform
            Selection = [string]$spec.Selection
            StableLocationKey = [string]$context.LocationKey
            TargetContext = $context
        })
    }

    $finalMarkers = Get-CodexLiveRootMarkerSet -PreferredPath $codexPreferred -FallbackPath $codexFallback
    $confirmedFinalMarkers = Get-CodexLiveRootMarkerSet -PreferredPath $codexPreferred -FallbackPath $codexFallback
    Assert-CodexLiveRootMarkerSetUnambiguous -MarkerSet $finalMarkers
    Assert-CodexLiveRootMarkerSetUnambiguous -MarkerSet $confirmedFinalMarkers
    Assert-CodexLiveRootMarkerSetsEqual -Expected $finalMarkers -Actual $confirmedFinalMarkers
    Assert-CodexLiveRootMarkerSetsEqual -Expected $confirmedInitialMarkers -Actual $confirmedFinalMarkers

    $selectedMarker = if ($fallbackPresent) { $confirmedInitialMarkers.Fallback } else { $confirmedInitialMarkers.Preferred }
    $codexContext = $resolved[1].TargetContext
    if ([string]$selectedMarker.EntryType -ceq 'MISSING') {
        if ([string]$codexContext.TargetStatus -cne 'MISSING') { throw 'codex-live-root-selection-drift' }
    }
    elseif ([string]$codexContext.TargetStatus -cne 'EXISTS' -or [string]$codexContext.TargetType -cne 'Directory' -or [string]$codexContext.DeepestExistingParentIdentity -cne [string]$selectedMarker.Identity) {
        throw 'codex-live-root-selection-drift'
    }
    return @($resolved)
}

function Assert-SealedHeldLiveTargetRouteWitness {
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [AllowNull()]$CanonicalWitness,
        [AllowNull()]$GlobalLockHandle
    )

    try {
        $canonicalTypeNames = if ($null -eq $CanonicalWitness) { @() } else { @($CanonicalWitness.PSObject.TypeNames) }
        if ($null -eq $CanonicalWitness -or 'AiAgentDotfiles.CanonicalNamespaceWitness' -cnotin $canonicalTypeNames) {
            throw 'invalid canonical witness'
        }
        if ($null -eq $CanonicalWitness.PSObject.Properties['CanonicalLockHandle'] -or
            $CanonicalWitness.CanonicalLockHandle -isnot [object] -or
            'AiAgentDotfiles.CanonicalRepoLockHandle' -cnotin @($CanonicalWitness.CanonicalLockHandle.PSObject.TypeNames)) { throw 'invalid canonical lock witness' }
        $canonicalAssertion = Get-Command Assert-CanonicalHeldNamespaceWitness -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $canonicalAssertion) { throw 'canonical witness validator is unavailable' }
        $null = Assert-CanonicalHeldNamespaceWitness -Witness $CanonicalWitness -RepoRoot ([string]$CanonicalWitness.RepoRoot) -CanonicalLockHandle $CanonicalWitness.CanonicalLockHandle

        if ($null -eq $GlobalLockHandle -or 'AiAgentDotfiles.HomeAuthorityLockHandle' -cnotin @($GlobalLockHandle.PSObject.TypeNames)) { throw 'invalid global lock witness' }
        $bindingAssertion = Get-Command Assert-HomeAuthorityCanonicalGlobalLockBinding -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $bindingAssertion) { throw 'canonical/global lock binding validator is unavailable' }
        $null = Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness
        $binding = [AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($GlobalLockHandle)
        $acquisitionCapture = [AiAgentDotfiles.SafeLockOrderBinding]::GetPrerequisiteWitnessExact($binding)
        if ($binding -isnot [AiAgentDotfiles.SafeLockOrderBinding] -or
            -not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentWrapperExact($binding),$GlobalLockHandle) -or
            $acquisitionCapture -isnot [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture] -or
            -not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetAuthorityContextExact($binding),$acquisitionCapture) -or
            -not [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::MatchesSourcesExact($acquisitionCapture,$CanonicalWitness,$AuthorityContext)) {
            throw 'global lock private order binding is missing'
        }
        $canonicalHeld = [AiAgentDotfiles.SafeLockOrderBinding]::GetPrerequisiteExact($binding)
        if (-not [object]::ReferenceEquals($canonicalHeld,[AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetCanonicalHeldExact($acquisitionCapture))) {
            throw 'global lock private canonical prerequisite changed'
        }
        $heldGlobal = [AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentExact($binding)
        $heldParent = [AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentParentExact($binding)
        if ($heldGlobal -isnot [AiAgentDotfiles.SafeLockFileHandle] -or $heldParent -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or
            -not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($heldGlobal) -or -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($heldParent)) {
            throw 'global lock private resources are missing or closed'
        }
        $expectedPath = [IO.Path]::GetFullPath([string]$AuthorityContext.GlobalLiveLockPath)
        $lockIdentity = [string][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact($heldGlobal)
        $lockInfo = [AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($heldGlobal)
        $parentIdentity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($heldParent)
        $parentInfo = [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($heldParent)
        $parentMarker = Get-NoFollowRootEntryMarker -Path ([string]$AuthorityContext.ControlBase)
        $relative = [AiAgentDotfiles.NoFollowFile]::InspectChild($heldParent,[IO.Path]::GetFileName($expectedPath))
        $security = [AiAgentDotfiles.NoFollowFile]::GetLockFileSecuritySnapshot($heldGlobal)
        if ([string]$lockInfo.Identity -cne $lockIdentity -or [long]$lockInfo.LinkCount -ne 1 -or [long]$lockInfo.Length -ne 0 -or
            [string]$parentInfo.Identity -cne $parentIdentity -or [string]$parentMarker.Identity -cne $parentIdentity -or
            [string]$relative.Identity -cne $lockIdentity -or [string]$security.Identity -cne $lockIdentity -or
            [long]$relative.LinkCount -ne 1 -or [long]$security.LinkCount -ne 1 -or [long]$relative.Length -ne 0 -or $relative.IsDirectory -or $relative.IsReparsePoint -or
            @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($heldGlobal)).Count -ne 0) { throw 'global lock witness drift' }
        return $binding
    }
    catch { throw 'route-witness-required' }
}

function Assert-SealedHeldLiveTargetExpectedSet {
    param([Parameter(Mandatory)]$AuthorityContext)

    try {
        $targets = @($AuthorityContext.LiveTargets)
        if ($targets.Count -ne 3 -or (@($targets | ForEach-Object { [string]$_.Platform }) -join "`0") -cne (@('Claude','Codex','Reasonix') -join "`0")) {
            throw 'pre-lock live target set is incomplete or unordered'
        }
        foreach ($target in $targets) {
            if ($null -eq $target.TargetContext -or [string]$target.StableLocationKey -cne [string]$target.TargetContext.LocationKey -or
                [string]$target.TargetContext.FilesystemCapabilityStatus -cne 'UNPROBED' -or $null -ne $target.TargetContext.FilesystemCapabilityHash -or
                ([string]$target.TargetContext.TargetStatus -ceq 'EXISTS' -and [string]$target.TargetContext.TargetType -cne 'Directory')) {
                throw "pre-lock live target metadata is invalid: $($target.Platform)"
            }
        }
        $specs = @($targets | ForEach-Object { [ordered]@{ Platform=[string]$_.Platform; Path=[string]$_.TargetContext.RequestedPath } })
        Assert-LiveTargetPathsDisjoint -Targets $specs
        return $true
    }
    catch {
        if ($_.Exception.Message -like 'target-context-plan-stale:*') { throw }
        throw "target-context-plan-stale: $($_.Exception.Message)"
    }
}

function Get-SealedHeldLiveTargetMarkerSet {
    param([Parameter(Mandatory)]$AuthorityContext)
    $profile = ConvertTo-LiveTargetFullPath -Path ([string]$AuthorityContext.HomeRoot) -FieldName 'HomeRoot'
    return Get-CodexLiveRootMarkerSet -PreferredPath ([IO.Path]::GetFullPath((Join-Path $profile '.codex/skills'))) -FallbackPath ([IO.Path]::GetFullPath((Join-Path $profile '.agents/skills')))
}

function Assert-SealedHeldLiveTargetCodexSelection {
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$ExpectedMarkers,
        [Parameter(Mandatory)]$ActualMarkers
    )

    try {
        Assert-CodexLiveRootMarkerSetUnambiguous -MarkerSet $ExpectedMarkers
        Assert-CodexLiveRootMarkerSetUnambiguous -MarkerSet $ActualMarkers
        Assert-CodexLiveRootMarkerSetsEqual -Expected $ExpectedMarkers -Actual $ActualMarkers
        $codex = @($AuthorityContext.LiveTargets)[1]
        $profile = ConvertTo-LiveTargetFullPath -Path ([string]$AuthorityContext.HomeRoot) -FieldName 'HomeRoot'
        $preferred = [IO.Path]::GetFullPath((Join-Path $profile '.codex/skills'))
        $fallback = [IO.Path]::GetFullPath((Join-Path $profile '.agents/skills'))
        $fallbackPresent = [string]$ActualMarkers.Fallback.EntryType -cne 'MISSING'
        $preferredPresent = [string]$ActualMarkers.Preferred.EntryType -cne 'MISSING'
        $expectedPath = if ($fallbackPresent) { $fallback } else { $preferred }
        $expectedSelection = if ($fallbackPresent) { 'fallback' } elseif ($preferredPresent) { 'preferred' } else { 'preferred-missing' }
        if ([string]$codex.TargetContext.RequestedPath -cne $expectedPath -or [string]$codex.Selection -cne $expectedSelection) { throw 'Codex pre-lock selection changed' }
        return $true
    }
    catch {
        if ($_.Exception.Message -like 'target-context-plan-stale:*') { throw }
        throw "target-context-plan-stale: $($_.Exception.Message)"
    }
}

function Get-SealedHeldLiveTargetSetHash {
    param([Parameter(Mandatory)]$Projection)
    return Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/held-live-target-set/v1'
        ResolverVersion = [string]$Projection.ResolverVersion
        CaptureKind = [string]$Projection.CaptureKind
        CanonicalWitnessHash = [string]$Projection.CanonicalWitnessHash
        GlobalLiveLockIdentity = [string]$Projection.GlobalLiveLockIdentity
        PreLockTargetSetHash = [string]$Projection.PreLockTargetSetHash
        Targets = @($Projection.Targets)
        FilesystemCapabilityStatus = [string]$Projection.FilesystemCapabilityStatus
        FilesystemCapabilityHash = $Projection.FilesystemCapabilityHash
    })
}

function Open-SealedHeldLiveTargetContextSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$CanonicalWitness,
        [Parameter(Mandatory)]$GlobalLockHandle,
        [Parameter(Mandatory)][AiAgentDotfiles.SealedOwnershipTransferReceiver]$OwnershipReceiver
    )

    $leases = [Collections.Generic.List[object]]::new()
    $setLease = $null
    $setReceipt = $null
    $pendingLease = $null
    $pendingLeaseReceiver = $null
    $ownershipTransferred = $false
    $primaryError = $null
    try {
        $OwnershipReceiver.AssertEmptyExact()
        $globalBinding = Assert-SealedHeldLiveTargetRouteWitness -AuthorityContext $AuthorityContext -CanonicalWitness $CanonicalWitness -GlobalLockHandle $GlobalLockHandle
        $null = Assert-SealedHeldLiveTargetExpectedSet -AuthorityContext $AuthorityContext
        $initialMarkers = Get-SealedHeldLiveTargetMarkerSet -AuthorityContext $AuthorityContext
        $confirmedInitialMarkers = Get-SealedHeldLiveTargetMarkerSet -AuthorityContext $AuthorityContext
        $null = Assert-SealedHeldLiveTargetCodexSelection -AuthorityContext $AuthorityContext -ExpectedMarkers $initialMarkers -ActualMarkers $confirmedInitialMarkers

        $rows = [Collections.Generic.List[object]]::new()
        foreach ($expected in @($AuthorityContext.LiveTargets)) {
            $pendingLeaseReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
            Open-SealedHeldTargetContextLease -Path ([string]$expected.TargetContext.RequestedPath) `
                -OwnershipReceiver $pendingLeaseReceiver
            $pendingLease = $pendingLeaseReceiver.GetDeliveredExact()
            $leases.Add($pendingLease)
            $lease = $pendingLease
            $pendingLease = $null
            $pendingLeaseReceiver = $null
            $actual = Get-SealedHeldTargetContextLease -Lease $lease
            $null = Assert-SealedHeldTargetContextMatchesMetadata -Expected $expected.TargetContext -Actual $actual
            $rows.Add([pscustomobject][ordered]@{
                Platform = [string]$expected.Platform
                Selection = [string]$expected.Selection
                StableLocationKey = [string]$expected.StableLocationKey
                TargetContext = $actual
            })
        }

        $finalMarkers = Get-SealedHeldLiveTargetMarkerSet -AuthorityContext $AuthorityContext
        $confirmedFinalMarkers = Get-SealedHeldLiveTargetMarkerSet -AuthorityContext $AuthorityContext
        $null = Assert-SealedHeldLiveTargetCodexSelection -AuthorityContext $AuthorityContext -ExpectedMarkers $finalMarkers -ActualMarkers $confirmedFinalMarkers
        $null = Assert-SealedHeldLiveTargetCodexSelection -AuthorityContext $AuthorityContext -ExpectedMarkers $confirmedInitialMarkers -ActualMarkers $confirmedFinalMarkers
        $projection = [pscustomobject][ordered]@{
            ResolverVersion = 'windows-no-follow-held-live-target-set-v1'
            CaptureKind = 'HELD_METADATA_SET'
            CanonicalWitnessHash = [string]$CanonicalWitness.WitnessHash
            GlobalLiveLockIdentity = [string][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact([AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentExact($globalBinding))
            PreLockTargetSetHash = Get-SemanticJsonHash -InputObject @($AuthorityContext.LiveTargets)
            Targets = @($rows)
            FilesystemCapabilityStatus = 'UNPROBED'
            FilesystemCapabilityHash = $null
            HeldTargetSetHash = $null
        }
        $projection.HeldTargetSetHash = Get-SealedHeldLiveTargetSetHash -Projection $projection
        $setLease = [pscustomobject][ordered]@{
            AuthorityContext = $AuthorityContext
            CanonicalWitness = $CanonicalWitness
            GlobalLockHandle = $GlobalLockHandle
            InitialCodexMarkers = $confirmedInitialMarkers
            TargetLeases = @($leases)
            Projection = $projection
            IsClosed = $false
        }
        $setLease.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.SealedHeldLiveTargetContextSet')
        $setReceipt = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::BindExact(
            $setLease,$AuthorityContext,$CanonicalWitness,$GlobalLockHandle,$confirmedInitialMarkers,[object[]]@($leases),$projection)
        $null = Assert-SealedHeldLiveTargetContextSet -Lease $setLease
        $OwnershipReceiver.DeliverExact($setLease)
        $ownershipTransferred = $true
        return
    }
    catch {
        $caughtError = $_
        if ($caughtError.Exception.Message -eq 'route-witness-required' -or $caughtError.Exception.Message -like 'target-context-plan-stale:*') {
            $primaryError = $caughtError
            throw
        }
        try { throw "target-context-plan-stale: $($caughtError.Exception.Message)" }
        catch {
            $primaryError = $_
            throw
        }
    }
    finally {
        $receiverOwnsSetLease = $null -ne $OwnershipReceiver -and $OwnershipReceiver.HoldsExact($setLease)
        if (-not $ownershipTransferred -and -not $receiverOwnsSetLease) {
            $cleanupError = $null
            if ($null -ne $setReceipt) {
                try { $null = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::ReleaseForWrapperExact($setLease) }
                catch { $cleanupError = $_ }
            }
            else {
                $receiverLease = $null
                if ($null -ne $pendingLeaseReceiver -and
                    [string]$pendingLeaseReceiver.GetStateExact() -ceq 'DELIVERED') {
                    try {
                        $receiverLease = $pendingLeaseReceiver.GetDeliveredExact()
                        $null = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($receiverLease)
                    }
                    catch { $cleanupError = $_ }
                }
                if ($null -ne $pendingLease) {
                    try { $null = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($pendingLease) }
                    catch { if ($null -eq $cleanupError) { $cleanupError = $_ } }
                }
                for ($index=$leases.Count-1; $index -ge 0; $index--) {
                    try { $null = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($leases[$index]) }
                    catch { if ($null -eq $cleanupError) { $cleanupError = $_ } }
                }
            }
            if ($null -ne $cleanupError) {
                if ($null -ne $primaryError) {
                    try { $primaryError.Exception.Data['SealedHeldLiveTargetContextCleanupError'] = [string]$cleanupError.Exception.Message }
                    catch { }
                }
                else { throw $cleanupError }
            }
        }
    }
}

function Assert-SealedHeldLiveTargetContextSet {
    [CmdletBinding()]
    param([AllowNull()]$Lease)

    try {
        $receipt = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($Lease)
        if ($null -eq $Lease -or 'AiAgentDotfiles.SealedHeldLiveTargetContextSet' -cnotin @($Lease.PSObject.TypeNames) -or
            $receipt -isnot [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt] -or
            -not [object]::ReferenceEquals([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetWrapperExact($receipt),$Lease) -or
            -not [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsOpenExact($receipt)) { throw 'held live target set is missing, untyped, or closed' }
        $receipt.BeginReadExact()
        try {
        $authorityContext = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetAuthorityContextExact($receipt)
        $canonicalWitness = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetCanonicalWitnessExact($receipt)
        $globalLockHandle = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetGlobalLockHandleExact($receipt)
        $initialCodexMarkers = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetInitialCodexMarkersExact($receipt)
        $targetLeases = @([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetTargetLeasesExact($receipt))
        $projection = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetProjectionExact($receipt)
        $globalBinding = Assert-SealedHeldLiveTargetRouteWitness -AuthorityContext $authorityContext -CanonicalWitness $canonicalWitness -GlobalLockHandle $globalLockHandle
        $null = Assert-SealedHeldLiveTargetExpectedSet -AuthorityContext $authorityContext
        $expectedTargets = @($authorityContext.LiveTargets)
        if ($targetLeases.Count -ne 3 -or @($projection.Targets).Count -ne 3) { throw 'held live target set cardinality changed' }
        for ($index=0; $index -lt 3; $index++) {
            $actual = Get-SealedHeldTargetContextLease -Lease $targetLeases[$index]
            $null = Assert-SealedHeldTargetContextMatchesMetadata -Expected $expectedTargets[$index].TargetContext -Actual $actual
            $row = $projection.Targets[$index]
            if ([string]$row.Platform -cne [string]$expectedTargets[$index].Platform -or [string]$row.Selection -cne [string]$expectedTargets[$index].Selection -or
                [string]$row.StableLocationKey -cne [string]$expectedTargets[$index].StableLocationKey -or [string]$row.TargetContext.HeldMetadataHash -cne [string]$actual.HeldMetadataHash) {
                throw "held live target projection changed: $index"
            }
        }
        $markerA = Get-SealedHeldLiveTargetMarkerSet -AuthorityContext $authorityContext
        $markerB = Get-SealedHeldLiveTargetMarkerSet -AuthorityContext $authorityContext
        $null = Assert-SealedHeldLiveTargetCodexSelection -AuthorityContext $authorityContext -ExpectedMarkers $markerA -ActualMarkers $markerB
        $null = Assert-SealedHeldLiveTargetCodexSelection -AuthorityContext $authorityContext -ExpectedMarkers $initialCodexMarkers -ActualMarkers $markerB
        $exactGlobalIdentity = [string][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact([AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentExact($globalBinding))
        if ([string]$projection.CanonicalWitnessHash -cne [string]$canonicalWitness.WitnessHash -or
            [string]$projection.GlobalLiveLockIdentity -cne $exactGlobalIdentity -or
            [string]$projection.PreLockTargetSetHash -cne (Get-SemanticJsonHash -InputObject @($authorityContext.LiveTargets))) {
            throw 'held live target route/pre-lock binding changed'
        }
        if ([string]$projection.CaptureKind -cne 'HELD_METADATA_SET' -or [string]$projection.FilesystemCapabilityStatus -cne 'UNPROBED' -or
            $null -ne $projection.FilesystemCapabilityHash -or (Get-SealedHeldLiveTargetSetHash -Projection $projection) -cne [string]$projection.HeldTargetSetHash) {
            throw 'held live target set hash/capability coverage changed'
        }
        return $true
        }
        finally {
            $receipt.EndReadExact()
        }
    }
    catch {
        if ($_.Exception.Message -eq 'route-witness-required' -or $_.Exception.Message -like 'target-context-plan-stale:*') { throw }
        throw "target-context-plan-stale: $($_.Exception.Message)"
    }
}

function Get-SealedHeldLiveTargetContextSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lease)
    $null = Assert-SealedHeldLiveTargetContextSet -Lease $Lease
    $receipt = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($Lease)
    return [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetProjectionExact($receipt)
}

function Close-SealedHeldLiveTargetContextSet {
    [CmdletBinding()]
    param([AllowNull()]$Lease)
    if ($null -eq $Lease) { return }
    $receipt = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($Lease)
    if ($receipt -isnot [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]) { throw 'target-context-plan-stale: held live target set receipt is missing' }
    $null = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::ReleaseForWrapperExact($Lease)
    try {
        if ([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($receipt) -and
            $null -ne $Lease.PSObject.Properties['IsClosed'] -and $Lease.PSObject.Properties['IsClosed'].MemberType -eq 'NoteProperty') {
            $Lease.PSObject.Properties['IsClosed'].Value = $true
        }
    }
    catch { }
}

function Assert-LiveAuthorityRootSetsDisjoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$LeftTargets,
        [Parameter(Mandatory)][object[]]$RightTargets
    )

    foreach ($left in $LeftTargets) {
        foreach ($right in $RightTargets) {
            $leftPath = if ($left.PSObject.Properties['TargetContext']) { [string]$left.TargetContext.RequestedPath } else { [string]$left.Path }
            $rightPath = if ($right.PSObject.Properties['TargetContext']) { [string]$right.TargetContext.RequestedPath } else { [string]$right.Path }
            if (Test-TargetPathOverlap -Left $leftPath -Right $rightPath) {
                throw "home-authority-root-overlap: $($left.Platform)/$($right.Platform)"
            }
        }
    }
}
