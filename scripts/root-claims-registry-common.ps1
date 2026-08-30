#requires -Version 7.0

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'home-authority-common.ps1')
. (Join-Path $PSScriptRoot 'shared-authority-state-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')

$script:SealedRegistryArtifactKind = 'sealed-root-claims-registry-view'
$script:SealedRegistryResolverVersion = 'sealed-held-global-lock-registry-v2'
$script:SealedRegistryMaximumArtifactBytes = 4MB
$script:SealedRegistryHashPattern = '\A[0-9a-f]{64}\z'
$script:SealedRegistryUuidPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z'
$script:SealedCurrentRouteRootSetResolverVersion = 'sealed-current-route-root-set-v1'

if (-not ('AiAgentDotfiles.SealedRegistryCurrentRouteCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Threading;

namespace AiAgentDotfiles {
    public sealed class SealedRegistryRouteLeaseBinding {
        private readonly long _routeIndex;
        private readonly object _spec;
        private readonly object _lease;
        private readonly object _context;
        private readonly string _role;
        private readonly string _applicability;
        private readonly string _path;
        private readonly string _targetContextHash;
        private readonly string _heldMetadataHash;

        public SealedRegistryRouteLeaseBinding(long routeIndex, object spec, object lease, object context,
            string role, string applicability, string path, string targetContextHash, string heldMetadataHash) {
            if (spec == null || lease == null || context == null) throw new ArgumentNullException();
            _routeIndex = routeIndex;
            _spec = spec;
            _lease = lease;
            _context = context;
            _role = role;
            _applicability = applicability;
            _path = path;
            _targetContextHash = targetContextHash;
            _heldMetadataHash = heldMetadataHash;
        }

        public long RouteIndex { get { return _routeIndex; } }
        public object Spec { get { return _spec; } }
        public object Lease { get { return _lease; } }
        public object Context { get { return _context; } }
        public string Role { get { return _role; } }
        public string Applicability { get { return _applicability; } }
        public string Path { get { return _path; } }
        public string TargetContextHash { get { return _targetContextHash; } }
        public string HeldMetadataHash { get { return _heldMetadataHash; } }

        private static SealedRegistryRouteLeaseBinding Require(object value) {
            SealedRegistryRouteLeaseBinding binding = value as SealedRegistryRouteLeaseBinding;
            if (binding == null) throw new InvalidOperationException("route-witness-required");
            return binding;
        }
        public static bool IsGenuine(object value) { return value is SealedRegistryRouteLeaseBinding; }
        public static long GetRouteIndex(object value) { return Require(value)._routeIndex; }
        public static object GetSpec(object value) { return Require(value)._spec; }
        public static object GetLease(object value) { return Require(value)._lease; }
        public static object GetContext(object value) { return Require(value)._context; }
        public static string GetRole(object value) { return Require(value)._role; }
        public static string GetApplicability(object value) { return Require(value)._applicability; }
        public static string GetPath(object value) { return Require(value)._path; }
        public static string GetTargetContextHash(object value) { return Require(value)._targetContextHash; }
        public static string GetHeldMetadataHash(object value) { return Require(value)._heldMetadataHash; }
    }

    public sealed class SealedRegistryCurrentRouteCapture {
        private readonly object _liveSetLease;
        private readonly object _liveProjection;
        private readonly SealedRegistryRouteLeaseBinding[] _routeLeaseRows;
        private readonly object[] _reservationLeases;
        private readonly object[] _fixedLeases;
        private readonly object _originalCurrentRouteRootSet;
        private readonly object _canonicalWitness;
        private readonly object _currentRouteRootSetSnapshot;
        private readonly string _entryCurrentRouteRootSetHash;
        private readonly string _currentRouteRootSetSnapshotHash;
        private readonly string _heldTargetSetHash;
        private const int OpenState = 0;
        private const int ClosingState = 1;
        private const int ClosedState = 2;
        private int _closeState;

        public SealedRegistryCurrentRouteCapture(object liveSetLease, object liveProjection,
            SealedRegistryRouteLeaseBinding[] routeLeaseRows, object[] reservationLeases,
            object[] fixedLeases, object originalCurrentRouteRootSet, object canonicalWitness,
            object currentRouteRootSetSnapshot, string entryCurrentRouteRootSetHash,
            string currentRouteRootSetSnapshotHash, string heldTargetSetHash) {
            if (liveSetLease == null || liveProjection == null || routeLeaseRows == null ||
                reservationLeases == null || fixedLeases == null || originalCurrentRouteRootSet == null ||
                canonicalWitness == null || currentRouteRootSetSnapshot == null) throw new ArgumentNullException();
            _liveSetLease = liveSetLease;
            _liveProjection = liveProjection;
            _routeLeaseRows = (SealedRegistryRouteLeaseBinding[])routeLeaseRows.Clone();
            _reservationLeases = (object[])reservationLeases.Clone();
            _fixedLeases = (object[])fixedLeases.Clone();
            _originalCurrentRouteRootSet = originalCurrentRouteRootSet;
            _canonicalWitness = canonicalWitness;
            _currentRouteRootSetSnapshot = currentRouteRootSetSnapshot;
            _entryCurrentRouteRootSetHash = entryCurrentRouteRootSetHash;
            _currentRouteRootSetSnapshotHash = currentRouteRootSetSnapshotHash;
            _heldTargetSetHash = heldTargetSetHash;
        }

        private static void RejectMutation() { throw new InvalidOperationException("route-witness-required"); }
        public object LiveSetLease { get { return _liveSetLease; } set { RejectMutation(); } }
        public object LiveProjection { get { return _liveProjection; } set { RejectMutation(); } }
        public SealedRegistryRouteLeaseBinding[] RouteLeaseRows { get { return (SealedRegistryRouteLeaseBinding[])_routeLeaseRows.Clone(); } set { RejectMutation(); } }
        public object[] ReservationLeases { get { return (object[])_reservationLeases.Clone(); } set { RejectMutation(); } }
        public object[] FixedLeases { get { return (object[])_fixedLeases.Clone(); } set { RejectMutation(); } }
        public object OriginalCurrentRouteRootSet { get { return _originalCurrentRouteRootSet; } set { RejectMutation(); } }
        public object CanonicalWitness { get { return _canonicalWitness; } set { RejectMutation(); } }
        public object CurrentRouteRootSetSnapshot { get { return _currentRouteRootSetSnapshot; } set { RejectMutation(); } }
        public string EntryCurrentRouteRootSetHash { get { return _entryCurrentRouteRootSetHash; } set { RejectMutation(); } }
        public string CurrentRouteRootSetSnapshotHash { get { return _currentRouteRootSetSnapshotHash; } set { RejectMutation(); } }
        public string CurrentRouteRootSetHash { get { return _entryCurrentRouteRootSetHash; } set { RejectMutation(); } }
        public string HeldTargetSetHash { get { return _heldTargetSetHash; } set { RejectMutation(); } }
        public string FilesystemCapabilityCoverage { get { return "UNPROBED_READ_ONLY"; } set { RejectMutation(); } }
        public bool IsClosed { get { return Volatile.Read(ref _closeState) == ClosedState; } }

        private static SealedRegistryCurrentRouteCapture Require(object value) {
            SealedRegistryCurrentRouteCapture capture = value as SealedRegistryCurrentRouteCapture;
            if (capture == null) throw new InvalidOperationException("route-witness-required");
            return capture;
        }
        public static bool IsGenuine(object value) { return value is SealedRegistryCurrentRouteCapture; }
        public static bool GetIsOpenExact(object value) { return Volatile.Read(ref Require(value)._closeState) == OpenState; }
        public static bool GetIsClosed(object value) { return Volatile.Read(ref Require(value)._closeState) == ClosedState; }
        public static string GetCloseStateExact(object value) {
            int state = Volatile.Read(ref Require(value)._closeState);
            return state == OpenState ? "OPEN" : state == ClosingState ? "CLOSING" : "CLOSED";
        }
        public static object GetLiveSetLease(object value) { return Require(value)._liveSetLease; }
        public static object GetLiveProjection(object value) { return Require(value)._liveProjection; }
        public static SealedRegistryRouteLeaseBinding[] GetRouteLeaseRows(object value) { return (SealedRegistryRouteLeaseBinding[])Require(value)._routeLeaseRows.Clone(); }
        public static object[] GetReservationLeases(object value) { return (object[])Require(value)._reservationLeases.Clone(); }
        public static object[] GetFixedLeases(object value) { return (object[])Require(value)._fixedLeases.Clone(); }
        public static object GetOriginalCurrentRouteRootSet(object value) { return Require(value)._originalCurrentRouteRootSet; }
        public static object GetCanonicalWitness(object value) { return Require(value)._canonicalWitness; }
        public static object GetCurrentRouteRootSetSnapshot(object value) { return Require(value)._currentRouteRootSetSnapshot; }
        public static string GetEntryCurrentRouteRootSetHash(object value) { return Require(value)._entryCurrentRouteRootSetHash; }
        public static string GetCurrentRouteRootSetSnapshotHash(object value) { return Require(value)._currentRouteRootSetSnapshotHash; }
        public static string GetHeldTargetSetHash(object value) { return Require(value)._heldTargetSetHash; }

        private static Type FindRequiredType(string typeName) {
            foreach (System.Reflection.Assembly assembly in AppDomain.CurrentDomain.GetAssemblies()) {
                Type candidate = assembly.GetType(typeName, false, false);
                if (candidate != null) return candidate;
            }
            throw new InvalidOperationException("route-witness-required");
        }
        private static void InvokeReleaseExact(string typeName, object wrapper) {
            Type receiptType = FindRequiredType(typeName);
            MethodInfo release = receiptType.GetMethod("ReleaseForWrapperExact", BindingFlags.Public | BindingFlags.Static);
            if (release == null) throw new InvalidOperationException("route-witness-required");
            try { release.Invoke(null, new object[] { wrapper }); }
            catch (TargetInvocationException error) { throw error.InnerException ?? error; }
        }
        public static bool ReleaseExact(object value) {
            SealedRegistryCurrentRouteCapture capture = Require(value);
            int observed = Interlocked.CompareExchange(ref capture._closeState, ClosingState, OpenState);
            if (observed == ClosedState) return false;
            if (observed == ClosingState) throw new InvalidOperationException("route-close-active");
            if (observed != OpenState) throw new InvalidOperationException("route-witness-required");

            Exception firstError = null;
            for (int index = capture._reservationLeases.Length - 1; index >= 0; index--) {
                try { InvokeReleaseExact("AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt", capture._reservationLeases[index]); }
                catch (Exception error) { if (firstError == null) firstError = error; }
            }
            for (int index = capture._fixedLeases.Length - 1; index >= 0; index--) {
                try { InvokeReleaseExact("AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt", capture._fixedLeases[index]); }
                catch (Exception error) { if (firstError == null) firstError = error; }
            }
            for (int index = capture._routeLeaseRows.Length - 1; index >= 0; index--) {
                try { InvokeReleaseExact("AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt", capture._routeLeaseRows[index].Lease); }
                catch (Exception error) { if (firstError == null) firstError = error; }
            }
            try { InvokeReleaseExact("AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt", capture._liveSetLease); }
            catch (Exception error) { if (firstError == null) firstError = error; }

            if (firstError != null) {
                Volatile.Write(ref capture._closeState, OpenState);
                throw firstError;
            }
            Volatile.Write(ref capture._closeState, ClosedState);
            return true;
        }
    }
}
'@
}

if (-not ('AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence' -as [type])) {
    Add-Type -TypeDefinition @'
using System;

namespace AiAgentDotfiles {
    public sealed class SealedRegistryCanonicalOutputEvidence {
        private readonly object witness;
        private readonly object canonicalLockHandle;
        private readonly object setupStateCapture;
        private readonly object setupStateHandle;
        private readonly object setupStateDocument;
        private readonly string repoRoot;
        private readonly string repoId;
        private readonly string gitCommonDirHash;
        private readonly string setupStateIdentity;
        private readonly long setupStateLength;
        private readonly string setupStateBytesHash;
        private readonly string setupStateSemanticHash;
        private readonly string canonicalTransactionSetHash;

        private SealedRegistryCanonicalOutputEvidence(object witnessValue, object canonicalLockHandleValue,
            object setupStateCaptureValue, object setupStateHandleValue, object setupStateDocumentValue,
            string repoRootValue, string repoIdValue, string gitCommonDirHashValue,
            string setupStateIdentityValue, long setupStateLengthValue, string setupStateBytesHashValue,
            string setupStateSemanticHashValue, string canonicalTransactionSetHashValue) {
            witness = witnessValue;
            canonicalLockHandle = canonicalLockHandleValue;
            setupStateCapture = setupStateCaptureValue;
            setupStateHandle = setupStateHandleValue;
            setupStateDocument = setupStateDocumentValue;
            repoRoot = repoRootValue;
            repoId = repoIdValue;
            gitCommonDirHash = gitCommonDirHashValue;
            setupStateIdentity = setupStateIdentityValue;
            setupStateLength = setupStateLengthValue;
            setupStateBytesHash = setupStateBytesHashValue;
            setupStateSemanticHash = setupStateSemanticHashValue;
            canonicalTransactionSetHash = canonicalTransactionSetHashValue;
        }

        public static SealedRegistryCanonicalOutputEvidence CreateExact(object witnessValue,
            object canonicalLockHandleValue, object setupStateCaptureValue, object setupStateHandleValue,
            object setupStateDocumentValue, string repoRootValue, string repoIdValue,
            string gitCommonDirHashValue, string setupStateIdentityValue, long setupStateLengthValue,
            string setupStateBytesHashValue, string setupStateSemanticHashValue,
            string canonicalTransactionSetHashValue) {
            if (witnessValue == null || canonicalLockHandleValue == null || setupStateCaptureValue == null ||
                setupStateHandleValue == null || setupStateDocumentValue == null ||
                String.IsNullOrEmpty(repoRootValue) || String.IsNullOrEmpty(repoIdValue) ||
                String.IsNullOrEmpty(gitCommonDirHashValue) || String.IsNullOrEmpty(setupStateIdentityValue) ||
                setupStateLengthValue < 0 || String.IsNullOrEmpty(setupStateBytesHashValue) ||
                String.IsNullOrEmpty(setupStateSemanticHashValue) || String.IsNullOrEmpty(canonicalTransactionSetHashValue)) {
                throw new InvalidOperationException("canonical-witness-required");
            }
            return new SealedRegistryCanonicalOutputEvidence(witnessValue, canonicalLockHandleValue,
                setupStateCaptureValue, setupStateHandleValue, setupStateDocumentValue, repoRootValue,
                repoIdValue, gitCommonDirHashValue, setupStateIdentityValue, setupStateLengthValue,
                setupStateBytesHashValue, setupStateSemanticHashValue, canonicalTransactionSetHashValue);
        }

        public static object GetWitnessExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.witness; }
        public static object GetCanonicalLockHandleExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.canonicalLockHandle; }
        public static object GetSetupStateCaptureExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.setupStateCapture; }
        public static object GetSetupStateHandleExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.setupStateHandle; }
        public static object GetSetupStateDocumentExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.setupStateDocument; }
        public static string GetRepoRootExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.repoRoot; }
        public static string GetRepoIdExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.repoId; }
        public static string GetGitCommonDirHashExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.gitCommonDirHash; }
        public static string GetSetupStateIdentityExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.setupStateIdentity; }
        public static long GetSetupStateLengthExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? 0L : value.setupStateLength; }
        public static string GetSetupStateBytesHashExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.setupStateBytesHash; }
        public static string GetSetupStateSemanticHashExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.setupStateSemanticHash; }
        public static string GetCanonicalTransactionSetHashExact(SealedRegistryCanonicalOutputEvidence value) { return value == null ? null : value.canonicalTransactionSetHash; }
    }
}
'@
}

if (-not ('AiAgentDotfiles.SealedRegistryGlobalLockEvidence' -as [type])) {
    Add-Type -TypeDefinition @'
using System;

namespace AiAgentDotfiles {
    public sealed class SealedRegistryGlobalLockEvidence {
        private readonly object wrapper;
        private readonly object heldLock;
        private readonly object finalParent;
        private readonly object[] parentHandles;
        private readonly string expectedPath;
        private readonly string lockIdentity;
        private readonly string controlBaseIdentity;
        private readonly string lockSecurityHash;
        private readonly string fixedEnvelopeHash;
        private readonly string authorityContextHash;

        private SealedRegistryGlobalLockEvidence(object wrapperValue, object heldLockValue, object finalParentValue,
            object[] parentHandlesValue, string expectedPathValue, string lockIdentityValue,
            string controlBaseIdentityValue, string lockSecurityHashValue, string fixedEnvelopeHashValue,
            string authorityContextHashValue) {
            wrapper = wrapperValue;
            heldLock = heldLockValue;
            finalParent = finalParentValue;
            parentHandles = (object[])parentHandlesValue.Clone();
            expectedPath = expectedPathValue;
            lockIdentity = lockIdentityValue;
            controlBaseIdentity = controlBaseIdentityValue;
            lockSecurityHash = lockSecurityHashValue;
            fixedEnvelopeHash = fixedEnvelopeHashValue;
            authorityContextHash = authorityContextHashValue;
        }

        public static SealedRegistryGlobalLockEvidence CreateExact(object wrapperValue, object heldLockValue,
            object finalParentValue, object[] parentHandlesValue, string expectedPathValue, string lockIdentityValue,
            string controlBaseIdentityValue, string lockSecurityHashValue, string fixedEnvelopeHashValue,
            string authorityContextHashValue) {
            if (wrapperValue == null || heldLockValue == null || finalParentValue == null ||
                parentHandlesValue == null || parentHandlesValue.Length == 0 || expectedPathValue == null ||
                lockIdentityValue == null || controlBaseIdentityValue == null || lockSecurityHashValue == null ||
                fixedEnvelopeHashValue == null || authorityContextHashValue == null) {
                throw new InvalidOperationException("home-authority-registry-lock-required");
            }
            return new SealedRegistryGlobalLockEvidence(wrapperValue, heldLockValue, finalParentValue,
                parentHandlesValue, expectedPathValue, lockIdentityValue, controlBaseIdentityValue,
                lockSecurityHashValue, fixedEnvelopeHashValue, authorityContextHashValue);
        }

        public static object GetWrapperExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : evidence.wrapper; }
        public static object GetHeldLockExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : evidence.heldLock; }
        public static object GetFinalParentExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : evidence.finalParent; }
        public static object[] GetParentHandlesExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : (object[])evidence.parentHandles.Clone(); }
        public static string GetExpectedPathExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : evidence.expectedPath; }
        public static string GetLockIdentityExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : evidence.lockIdentity; }
        public static string GetControlBaseIdentityExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : evidence.controlBaseIdentity; }
        public static string GetLockSecurityHashExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : evidence.lockSecurityHash; }
        public static string GetFixedEnvelopeHashExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : evidence.fixedEnvelopeHash; }
        public static string GetAuthorityContextHashExact(SealedRegistryGlobalLockEvidence evidence) { return evidence == null ? null : evidence.authorityContextHash; }
        public static bool MatchesExact(SealedRegistryGlobalLockEvidence left, SealedRegistryGlobalLockEvidence right) {
            if (left == null || right == null) return false;
            if (!Object.ReferenceEquals(left.wrapper, right.wrapper) || !Object.ReferenceEquals(left.heldLock, right.heldLock) ||
                !Object.ReferenceEquals(left.finalParent, right.finalParent) || left.parentHandles.Length != right.parentHandles.Length) return false;
            for (int index = 0; index < left.parentHandles.Length; index++) {
                if (!Object.ReferenceEquals(left.parentHandles[index], right.parentHandles[index])) return false;
            }
            return String.Equals(left.expectedPath, right.expectedPath, StringComparison.Ordinal) &&
                String.Equals(left.lockIdentity, right.lockIdentity, StringComparison.Ordinal) &&
                String.Equals(left.controlBaseIdentity, right.controlBaseIdentity, StringComparison.Ordinal) &&
                String.Equals(left.lockSecurityHash, right.lockSecurityHash, StringComparison.Ordinal) &&
                String.Equals(left.fixedEnvelopeHash, right.fixedEnvelopeHash, StringComparison.Ordinal) &&
                String.Equals(left.authorityContextHash, right.authorityContextHash, StringComparison.Ordinal);
        }
    }
}
'@
}

function Get-SealedRegistryOrdinalStrings {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Values)
    $copy = [string[]]@($Values)
    [Array]::Sort($copy,[StringComparer]::Ordinal)
    foreach ($value in $copy) { Write-Output $value }
}

function Get-SealedRegistryOrderedReservations {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Reservations)
    $byKey = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($row in $Reservations) {
        $key = @([string]$row.SourceKind,[string]$row.OwnerKey,[string]$row.Role,[string]$row.Platform,[string]$row.LocationKey) -join "`0"
        if ($byKey.ContainsKey($key)) { throw 'registry reservation ordering key collision' }
        $byKey.Add($key,$row)
    }
    foreach ($row in $byKey.Values) { Write-Output $row }
}

function Get-SealedRegistryPropertyNames {
    param([Parameter(Mandatory)]$InputObject)
    if ($InputObject -isnot [System.Collections.IDictionary]) { throw 'registry contract value is not an object' }
    return @($InputObject.Keys | ForEach-Object { [string]$_ })
}

function Assert-SealedRegistryExactPropertySet {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    $actual = @(Get-SealedRegistryOrdinalStrings -Values @(Get-SealedRegistryPropertyNames -InputObject $InputObject))
    $wanted = @(Get-SealedRegistryOrdinalStrings -Values $Expected)
    if (($actual -join "`0") -cne ($wanted -join "`0")) { throw "${Label} property set mismatch" }
}

function Assert-SealedRegistryString {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Label,
        [string]$Pattern,
        [string[]]$Allowed,
        [switch]$AllowNull
    )
    if ($null -eq $Value) {
        if ($AllowNull) { return }
        throw "${Label} must be a string"
    }
    if ($Value -isnot [string]) { throw "${Label} must be a string" }
    if ($Pattern -and [string]$Value -cnotmatch $Pattern) { throw "${Label} has an invalid spelling" }
    if ($Allowed -and [string]$Value -cnotin $Allowed) { throw "${Label} has an unsupported value" }
}

function Assert-SealedRegistryArray {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Label,
        [int]$ExactCount = -1,
        [int]$MinimumCount = -1,
        [int]$MaximumCount = -1
    )
    if ($null -eq $Value -or $Value -is [string] -or $Value -isnot [System.Array]) { throw "${Label} must be an array" }
    $count = @($Value).Count
    if ($ExactCount -ge 0 -and $count -ne $ExactCount) { throw "${Label} has the wrong item count" }
    if ($MinimumCount -ge 0 -and $count -lt $MinimumCount) { throw "${Label} has too few items" }
    if ($MaximumCount -ge 0 -and $count -gt $MaximumCount) { throw "${Label} has too many items" }
}

function Assert-SealedRegistryInteger {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Label,
        [long]$Minimum,
        [long]$Maximum
    )
    if ($Value -isnot [long] -or [long]$Value -lt $Minimum -or [long]$Value -gt $Maximum) { throw "${Label} is outside the supported integer range" }
}

function Compare-SealedRegistryNames {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actual,
        [Parameter(Mandatory)][string]$Label
    )
    $left = @(Get-SealedRegistryOrdinalStrings -Values $Expected)
    $right = @(Get-SealedRegistryOrdinalStrings -Values $Actual)
    if (($left -join "`0") -cne ($right -join "`0")) { throw "registry inventory drift: $Label" }
}

function Get-SealedRegistryObjectValue {
    param([Parameter(Mandatory)]$InputObject,[Parameter(Mandatory)][string]$Name)
    if ($InputObject -is [Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return $null }
        return $InputObject[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-SealedRegistryCoreTargetContext {
    param([Parameter(Mandatory)]$InputObject)
    $projection = Get-SealedRegistryObjectValue -InputObject $InputObject -Name 'Projection'
    if ($null -ne $projection) { return $projection }
    $target = Get-SealedRegistryObjectValue -InputObject $InputObject -Name 'TargetContext'
    if ($null -ne $target) { return $target }
    return $InputObject
}

function Get-SealedRegistryContextSuffixFromAncestor {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][int]$AncestorIndex)
    $context = Get-SealedRegistryCoreTargetContext -InputObject $Context
    $ancestors = @((Get-SealedRegistryObjectValue -InputObject $context -Name 'Ancestors'))
    if ($AncestorIndex -lt 0 -or $AncestorIndex -ge $ancestors.Count) { throw 'current-route-context-contract-invalid' }
    $segments = [Collections.Generic.List[string]]::new()
    for ($index=$AncestorIndex+1; $index -lt $ancestors.Count; $index++) {
        $path = [string](Get-SealedRegistryObjectValue -InputObject $ancestors[$index] -Name 'Path')
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'current-route-context-contract-invalid' }
        $segments.Add([IO.Path]::GetFileName($path.TrimEnd([char]92,[char]47)))
    }
    foreach ($segment in @((Get-SealedRegistryObjectValue -InputObject $context -Name 'MissingRemainder'))) { $segments.Add([string]$segment) }
    return @($segments)
}

function Test-SealedRegistryOrdinalIgnoreCasePrefix {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Right
    )
    if ($Left.Count -gt $Right.Count) { return $false }
    for ($index=0; $index -lt $Left.Count; $index++) {
        if (-not [string]::Equals($Left[$index],$Right[$index],[StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Test-SealedRegistryTargetContextsOverlap {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Left,[Parameter(Mandatory)]$Right)
    $leftContext = Get-SealedRegistryCoreTargetContext -InputObject $Left
    $rightContext = Get-SealedRegistryCoreTargetContext -InputObject $Right
    $leftPath = [string](Get-SealedRegistryObjectValue -InputObject $leftContext -Name 'RequestedPath')
    $rightPath = [string](Get-SealedRegistryObjectValue -InputObject $rightContext -Name 'RequestedPath')
    if (Test-TargetPathOverlap -Left $leftPath -Right $rightPath) { return $true }

    $leftAncestors = @((Get-SealedRegistryObjectValue -InputObject $leftContext -Name 'Ancestors'))
    $rightAncestors = @((Get-SealedRegistryObjectValue -InputObject $rightContext -Name 'Ancestors'))
    for ($leftIndex=0; $leftIndex -lt $leftAncestors.Count; $leftIndex++) {
        $leftIdentity = [string](Get-SealedRegistryObjectValue -InputObject $leftAncestors[$leftIndex] -Name 'Identity')
        if ([string]::IsNullOrWhiteSpace($leftIdentity)) { throw 'current-route-context-contract-invalid' }
        for ($rightIndex=0; $rightIndex -lt $rightAncestors.Count; $rightIndex++) {
            $rightIdentity = [string](Get-SealedRegistryObjectValue -InputObject $rightAncestors[$rightIndex] -Name 'Identity')
            if ($leftIdentity -cne $rightIdentity) { continue }
            $leftSuffix = @(Get-SealedRegistryContextSuffixFromAncestor -Context $leftContext -AncestorIndex $leftIndex)
            $rightSuffix = @(Get-SealedRegistryContextSuffixFromAncestor -Context $rightContext -AncestorIndex $rightIndex)
            if ((Test-SealedRegistryOrdinalIgnoreCasePrefix -Left $leftSuffix -Right $rightSuffix) -or
                (Test-SealedRegistryOrdinalIgnoreCasePrefix -Left $rightSuffix -Right $leftSuffix)) { return $true }
        }
    }
    return $false
}

function Get-CanonicalHeldWitnessPath {
    param([Parameter(Mandatory)]$Witness,[Parameter(Mandatory)][ValidateSet('RepoRoot','GitDir','GitCommonDir','ContractRoot')][string]$Role)
    $direct = Get-SealedRegistryObjectValue -InputObject $Witness -Name ($Role + 'Path')
    if ($null -ne $direct -and -not [string]::IsNullOrWhiteSpace([string]$direct)) { return [IO.Path]::GetFullPath([string]$direct) }
    $value = Get-SealedRegistryObjectValue -InputObject $Witness -Name $Role
    if ($value -is [string]) { return [IO.Path]::GetFullPath([string]$value) }
    if ($null -ne $value) {
        $path = Get-SealedRegistryObjectValue -InputObject $value -Name 'Path'
        if ($null -ne $path -and -not [string]::IsNullOrWhiteSpace([string]$path)) { return [IO.Path]::GetFullPath([string]$path) }
    }
    throw 'canonical-witness-required'
}

function New-SealedCurrentRouteRootRow {
    param(
        [Parameter(Mandatory)][string]$Role,
        [AllowNull()][string]$Platform,
        [AllowNull()][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [ordered]@{ Role=$Role; Platform=$Platform; Applicability='NOT_APPLICABLE'; Path=$null; TargetContext=$null }
    }
    $full = [IO.Path]::GetFullPath($Path)
    $context = Resolve-TargetContext -Path $full -Mode MetadataOnly
    if ([string]$context.TargetStatus -ceq 'EXISTS' -and [string]$context.TargetType -cne 'Directory') { throw 'current-route-root-must-be-directory' }
    return [ordered]@{ Role=$Role; Platform=$Platform; Applicability='PRESENT'; Path=$full; TargetContext=$context }
}

function ConvertTo-SealedCurrentRoutePlatformPaths {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string]$Label
    )
    $result = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    if ($Rows.Count -eq 0) { return $result }
    if ($Rows.Count -ne 3) { throw "$Label must contain exactly Claude, Codex, and Reasonix rows" }
    foreach ($row in $Rows) {
        $platform = [string](Get-SealedRegistryObjectValue -InputObject $row -Name 'Platform')
        $path = [string](Get-SealedRegistryObjectValue -InputObject $row -Name 'Path')
        if ($platform -cnotin @('Claude','Codex','Reasonix') -or [string]::IsNullOrWhiteSpace($path) -or $result.ContainsKey($platform)) { throw "$Label platform/path contract mismatch" }
        $result.Add($platform,[IO.Path]::GetFullPath($path))
    }
    return $result
}

function New-SealedCurrentRouteRootSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$CanonicalWitness,
        [string]$CandidateWorkspaceRoot,
        [string]$EnvironmentMaterializationRoot,
        [object[]]$SourceRoots = @(),
        [object[]]$LiveMutationStagingRoots = @()
    )
    if ('AiAgentDotfiles.CanonicalNamespaceWitness' -cnotin @($CanonicalWitness.PSObject.TypeNames)) { throw 'canonical-witness-required' }
    $witnessHash = [string](Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'WitnessHash')
    if ($witnessHash -cnotmatch $script:SealedRegistryHashPattern) { throw 'canonical-witness-required' }
    $sourceByPlatform = ConvertTo-SealedCurrentRoutePlatformPaths -Rows @($SourceRoots) -Label 'current route source roots'
    $stagingByPlatform = ConvertTo-SealedCurrentRoutePlatformPaths -Rows @($LiveMutationStagingRoots) -Label 'current route staging roots'
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($binding in @(
        [pscustomobject]@{Role='RepoRoot';Path=(Get-CanonicalHeldWitnessPath -Witness $CanonicalWitness -Role RepoRoot)},
        [pscustomobject]@{Role='GitDir';Path=(Get-CanonicalHeldWitnessPath -Witness $CanonicalWitness -Role GitDir)},
        [pscustomobject]@{Role='GitCommonDir';Path=(Get-CanonicalHeldWitnessPath -Witness $CanonicalWitness -Role GitCommonDir)},
        [pscustomobject]@{Role='CanonicalContractRoot';Path=(Get-CanonicalHeldWitnessPath -Witness $CanonicalWitness -Role ContractRoot)},
        [pscustomobject]@{Role='CandidateWorkspace';Path=$CandidateWorkspaceRoot},
        [pscustomobject]@{Role='EnvironmentMaterializationRoot';Path=$EnvironmentMaterializationRoot}
    )) { $rows.Add((New-SealedCurrentRouteRootRow -Role $binding.Role -Path $binding.Path)) }
    foreach ($platform in @('Claude','Codex','Reasonix')) {
        $sourcePath = if ($sourceByPlatform.ContainsKey($platform)) { $sourceByPlatform[$platform] } else { $null }
        $rows.Add((New-SealedCurrentRouteRootRow -Role 'SourceRoot' -Platform $platform -Path $sourcePath))
    }
    foreach ($platform in @('Claude','Codex','Reasonix')) {
        $stagingPath = if ($stagingByPlatform.ContainsKey($platform)) { $stagingByPlatform[$platform] } else { $null }
        $rows.Add((New-SealedCurrentRouteRootRow -Role 'LiveMutationStagingRoot' -Platform $platform -Path $stagingPath))
    }

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentMaterializationRoot) -and $sourceByPlatform.Count -eq 3) {
        foreach ($sourcePath in $sourceByPlatform.Values) {
            if (-not (Test-SafePathInsideRoot -Path $sourcePath -Root $EnvironmentMaterializationRoot) -or
                [IO.Path]::GetFullPath($sourcePath).TrimEnd([char]92,[char]47).Equals([IO.Path]::GetFullPath($EnvironmentMaterializationRoot).TrimEnd([char]92,[char]47),[StringComparison]::OrdinalIgnoreCase)) {
                throw 'current-route-source-outside-materialization-root'
            }
        }
    }
    foreach ($set in @($sourceByPlatform,$stagingByPlatform)) {
        $paths = @($set.Values)
        for ($left=0; $left -lt $paths.Count; $left++) {
            for ($right=$left+1; $right -lt $paths.Count; $right++) {
                if (Test-TargetPathOverlap -Left $paths[$left] -Right $paths[$right]) { throw 'current-route-platform-path-overlap' }
            }
        }
    }
    $projection = [ordered]@{
        ResolverVersion=$script:SealedCurrentRouteRootSetResolverVersion
        CanonicalWitnessHash=$witnessHash
        Roots=@($rows)
        FilesystemCapabilityCoverage='UNPROBED_READ_ONLY'
    }
    $result = [pscustomobject][ordered]@{
        ResolverVersion=[string]$projection.ResolverVersion; CanonicalWitnessHash=[string]$projection.CanonicalWitnessHash
        Roots=@($projection.Roots); FilesystemCapabilityCoverage=[string]$projection.FilesystemCapabilityCoverage
        RouteRootSetHash=Get-SemanticJsonHash -InputObject $projection
    }
    $result.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.SealedCurrentRouteRootSet')
    return $result
}

function Get-SealedCurrentRouteRootSetProjection {
    param([Parameter(Mandatory)]$RootSet)
    return [ordered]@{
        ResolverVersion=[string]$RootSet.ResolverVersion
        CanonicalWitnessHash=[string]$RootSet.CanonicalWitnessHash
        Roots=@($RootSet.Roots)
        FilesystemCapabilityCoverage=[string]$RootSet.FilesystemCapabilityCoverage
    }
}

function Copy-SealedCurrentRouteRootSetSnapshot {
    param([Parameter(Mandatory)]$RootSet)
    $envelope = [ordered]@{
        ResolverVersion=[string]$RootSet.ResolverVersion
        CanonicalWitnessHash=[string]$RootSet.CanonicalWitnessHash
        Roots=@($RootSet.Roots)
        FilesystemCapabilityCoverage=[string]$RootSet.FilesystemCapabilityCoverage
        RouteRootSetHash=[string]$RootSet.RouteRootSetHash
    }
    $bytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $envelope)
    $document = ConvertFrom-SemanticJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
    foreach ($row in @($document.Roots)) {
        if ($null -ne $row.TargetContext -and $row.TargetContext -is [Collections.IDictionary]) {
            $row.TargetContext = [pscustomobject]$row.TargetContext
        }
    }
    $snapshot = [pscustomobject]$document
    $snapshot.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.SealedCurrentRouteRootSet')
    return $snapshot
}

function Assert-SealedCurrentRouteRootSet {
    param([Parameter(Mandatory)]$RootSet,[Parameter(Mandatory)]$CanonicalWitness)
    try {
    if ('AiAgentDotfiles.SealedCurrentRouteRootSet' -cnotin @($RootSet.PSObject.TypeNames)) { throw 'route-witness-required' }
    if ([string]$RootSet.ResolverVersion -cne $script:SealedCurrentRouteRootSetResolverVersion -or [string]$RootSet.FilesystemCapabilityCoverage -cne 'UNPROBED_READ_ONLY') { throw 'route-witness-required' }
    if ([string]$RootSet.CanonicalWitnessHash -cne [string]$CanonicalWitness.WitnessHash) { throw 'route-witness-required' }
    $expectedKeys = @('RepoRoot:','GitDir:','GitCommonDir:','CanonicalContractRoot:','CandidateWorkspace:','EnvironmentMaterializationRoot:','SourceRoot:Claude','SourceRoot:Codex','SourceRoot:Reasonix','LiveMutationStagingRoot:Claude','LiveMutationStagingRoot:Codex','LiveMutationStagingRoot:Reasonix')
    $rows = @($RootSet.Roots)
    if ($rows.Count -ne $expectedKeys.Count) { throw 'route-witness-required' }
    for ($index=0; $index -lt $rows.Count; $index++) {
        $row = $rows[$index]
        if ($row -isnot [Collections.IDictionary]) { throw 'route-witness-required' }
        Assert-SealedRegistryExactPropertySet -InputObject $row -Expected @('Role','Platform','Applicability','Path','TargetContext') -Label 'current-route root row'
        $key = [string]$row.Role + ':' + [string]$row.Platform
        if ($key -cne $expectedKeys[$index] -or [string]$row.Applicability -cnotin @('PRESENT','NOT_APPLICABLE')) { throw 'route-witness-required' }
        if ([string]$row.Applicability -ceq 'PRESENT') {
            if ([string]::IsNullOrWhiteSpace([string]$row.Path) -or $null -eq $row.TargetContext -or [string]$row.Path -cne [string]$row.TargetContext.RequestedPath) { throw 'route-witness-required' }
        }
        elseif ($null -ne $row.Path -or $null -ne $row.TargetContext) { throw 'route-witness-required' }
    }
    $presentSourceRows = @($rows | Where-Object { [string]$_.Role -ceq 'SourceRoot' -and [string]$_.Applicability -ceq 'PRESENT' })
    $presentStagingRows = @($rows | Where-Object { [string]$_.Role -ceq 'LiveMutationStagingRoot' -and [string]$_.Applicability -ceq 'PRESENT' })
    if ($presentSourceRows.Count -notin @(0,3) -or $presentStagingRows.Count -notin @(0,3)) { throw 'route-witness-required' }
    $materializationRow = $rows[5]
    if ([string]$materializationRow.Applicability -ceq 'PRESENT' -and $presentSourceRows.Count -eq 3) {
        $materializationPath = [IO.Path]::GetFullPath([string]$materializationRow.Path).TrimEnd([char]92,[char]47)
        foreach ($sourceRow in $presentSourceRows) {
            $sourcePath = [IO.Path]::GetFullPath([string]$sourceRow.Path).TrimEnd([char]92,[char]47)
            if ($sourcePath.Equals($materializationPath,[StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-SafePathInsideRoot -Path $sourcePath -Root $materializationPath)) { throw 'route-witness-required' }
        }
    }
    foreach ($set in @($presentSourceRows,$presentStagingRows)) {
        for ($leftIndex=0; $leftIndex -lt $set.Count; $leftIndex++) {
            for ($rightIndex=$leftIndex+1; $rightIndex -lt $set.Count; $rightIndex++) {
                if (Test-TargetPathOverlap -Left ([string]$set[$leftIndex].Path) -Right ([string]$set[$rightIndex].Path)) { throw 'route-witness-required' }
            }
        }
    }
    foreach ($binding in @(
        [pscustomobject]@{Index=0;Role='RepoRoot'},[pscustomobject]@{Index=1;Role='GitDir'},
        [pscustomobject]@{Index=2;Role='GitCommonDir'},[pscustomobject]@{Index=3;Role='ContractRoot'}
    )) {
        if ([string]$rows[$binding.Index].Applicability -cne 'PRESENT' -or [string]$rows[$binding.Index].Path -cne (Get-CanonicalHeldWitnessPath -Witness $CanonicalWitness -Role $binding.Role)) { throw 'route-witness-required' }
    }
    $projection = Get-SealedCurrentRouteRootSetProjection -RootSet $RootSet
    if ((Get-SemanticJsonHash -InputObject $projection) -cne [string]$RootSet.RouteRootSetHash) { throw 'route-witness-required' }
    return $RootSet
    }
    catch { throw 'route-witness-required' }
}

function Assert-SealedRegistryTargetContextsDisjoint {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right,
        [Parameter(Mandatory)][string]$PathToken,
        [Parameter(Mandatory)][string]$IdentityToken
    )
    $leftContext = Get-SealedRegistryCoreTargetContext -InputObject $Left
    $rightContext = Get-SealedRegistryCoreTargetContext -InputObject $Right
    $leftPath = [string](Get-SealedRegistryObjectValue -InputObject $leftContext -Name 'RequestedPath')
    $rightPath = [string](Get-SealedRegistryObjectValue -InputObject $rightContext -Name 'RequestedPath')
    if (Test-TargetPathOverlap -Left $leftPath -Right $rightPath) { throw $PathToken }
    if (Test-SealedRegistryTargetContextsOverlap -Left $leftContext -Right $rightContext) { throw $IdentityToken }
}

function Close-SealedRegistryCurrentRouteResources {
    param(
        [AllowNull()]$LiveSetLease,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RouteLeases,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FixedLeases,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ReservationLeases
    )
    $firstError = $null
    for ($index=$ReservationLeases.Count-1; $index -ge 0; $index--) {
        try { Close-SealedHeldTargetContextLease -Lease $ReservationLeases[$index] }
        catch { if ($null -eq $firstError) { $firstError = $_ } }
    }
    for ($index=$FixedLeases.Count-1; $index -ge 0; $index--) {
        try { Close-SealedHeldTargetContextLease -Lease $FixedLeases[$index] }
        catch { if ($null -eq $firstError) { $firstError = $_ } }
    }
    for ($index=$RouteLeases.Count-1; $index -ge 0; $index--) {
        try { Close-SealedHeldTargetContextLease -Lease $RouteLeases[$index] }
        catch { if ($null -eq $firstError) { $firstError = $_ } }
    }
    if ($null -ne $LiveSetLease) {
        try { Close-SealedHeldLiveTargetContextSet -Lease $LiveSetLease }
        catch { if ($null -eq $firstError) { $firstError = $_ } }
    }
    if ($null -ne $firstError) { throw $firstError }
}

function Open-SealedRegistryCurrentRouteCapture {
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$GlobalLockHandle,
        [Parameter(Mandatory)]$CanonicalWitness,
        [Parameter(Mandatory)]$CurrentRouteRootSet,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Reservations
    )
    $liveSetLease = $null
    $routeLeaseRows = [Collections.Generic.List[AiAgentDotfiles.SealedRegistryRouteLeaseBinding]]::new()
    $routeHeldLeases = [Collections.Generic.List[object]]::new()
    $reservationLeaseRows = [Collections.Generic.List[object]]::new()
    $fixedLeaseRows = [Collections.Generic.List[object]]::new()
    try {
        $null = Assert-SealedCurrentRouteRootSet -RootSet $CurrentRouteRootSet -CanonicalWitness $CanonicalWitness
        $entryCurrentRouteRootSetHash = [string]$CurrentRouteRootSet.RouteRootSetHash
        $currentRouteRootSetSnapshot = Copy-SealedCurrentRouteRootSetSnapshot -RootSet $CurrentRouteRootSet
        $null = Assert-SealedCurrentRouteRootSet -RootSet $currentRouteRootSetSnapshot -CanonicalWitness $CanonicalWitness
        if ([string]$currentRouteRootSetSnapshot.RouteRootSetHash -cne $entryCurrentRouteRootSetHash) { throw 'route-witness-required' }
        $currentRouteRootSetSnapshotHash = Get-SemanticJsonHash -InputObject ([ordered]@{
            ResolverVersion=[string]$currentRouteRootSetSnapshot.ResolverVersion
            CanonicalWitnessHash=[string]$currentRouteRootSetSnapshot.CanonicalWitnessHash
            Roots=@($currentRouteRootSetSnapshot.Roots)
            FilesystemCapabilityCoverage=[string]$currentRouteRootSetSnapshot.FilesystemCapabilityCoverage
            RouteRootSetHash=[string]$currentRouteRootSetSnapshot.RouteRootSetHash
        })
        $null = Assert-SealedCurrentRouteRootSet -RootSet $CurrentRouteRootSet -CanonicalWitness $CanonicalWitness
        if ([string]$CurrentRouteRootSet.RouteRootSetHash -cne $entryCurrentRouteRootSetHash) { throw 'route-witness-required' }
        $liveSetLease = Open-SealedHeldLiveTargetContextSet -AuthorityContext $AuthorityContext -CanonicalWitness $CanonicalWitness -GlobalLockHandle $GlobalLockHandle
        $liveProjection = Get-SealedHeldLiveTargetContextSet -Lease $liveSetLease

        $snapshotRows = @($currentRouteRootSetSnapshot.Roots)
        for ($routeIndex=0; $routeIndex -lt $snapshotRows.Count; $routeIndex++) {
            $row = $snapshotRows[$routeIndex]
            if ([string]$row.Applicability -cne 'PRESENT') { continue }
            $lease = Open-SealedHeldTargetContextLease -Path ([string]$row.Path)
            $routeHeldLeases.Add($lease)
            $actual = Get-SealedHeldTargetContextLease -Lease $lease
            $null = Assert-SealedHeldTargetContextMatchesMetadata -Expected $row.TargetContext -Actual $actual
            $routeLeaseRows.Add([AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::new(
                [long]$routeIndex,$row,$lease,$actual,[string]$row.Role,[string]$row.Applicability,[string]$row.Path,
                (Get-SemanticJsonHash -InputObject $row.TargetContext),[string]$actual.HeldMetadataHash))
        }
        foreach ($binding in @(
            [pscustomobject]@{Role='ControlBase';Path=[string]$AuthorityContext.ControlBase},
            [pscustomobject]@{Role='BackupRoot';Path=[string]$AuthorityContext.BackupRoot}
        )) {
            $lease = Open-SealedHeldTargetContextLease -Path $binding.Path
            $tracked = [pscustomobject][ordered]@{Role=$binding.Role;Lease=$lease;Context=$null}
            $fixedLeaseRows.Add($tracked)
            $tracked.Context = Get-SealedHeldTargetContextLease -Lease $lease
        }
        foreach ($reservation in $Reservations) {
            $lease = Open-SealedHeldTargetContextLease -Path ([string]$reservation.RequestedPath)
            $tracked = [pscustomobject][ordered]@{Reservation=$reservation;Lease=$lease;Context=$null}
            $reservationLeaseRows.Add($tracked)
            $context = Get-SealedHeldTargetContextLease -Lease $lease
            if ([string]$context.LocationKey -cne [string]$reservation.LocationKey -or [string]$context.VolumeId -cne [string]$reservation.VolumeId) { throw 'current-route-reservation-context-drift' }
            if ($null -ne $reservation.DirectoryIdentity -and ([string]$context.TargetStatus -cne 'EXISTS' -or [string]$context.DirectoryIdentity -cne [string]$reservation.DirectoryIdentity)) { throw 'current-route-reservation-context-drift' }
            $tracked.Context = $context
        }

        $liveTargets = @($liveProjection.Targets)
        for ($leftIndex=0; $leftIndex -lt $liveTargets.Count; $leftIndex++) {
            for ($rightIndex=$leftIndex+1; $rightIndex -lt $liveTargets.Count; $rightIndex++) {
                Assert-SealedRegistryTargetContextsDisjoint -Left $liveTargets[$leftIndex].TargetContext -Right $liveTargets[$rightIndex].TargetContext -PathToken 'current-route-platform-path-overlap' -IdentityToken 'current-route-platform-identity-alias'
            }
        }
        for ($leftIndex=0; $leftIndex -lt $routeLeaseRows.Count; $leftIndex++) {
            $leftRoute = $routeLeaseRows[$leftIndex]
            $leftRouteIndex = [long]$leftRoute.RouteIndex
            for ($rightIndex=$leftIndex+1; $rightIndex -lt $routeLeaseRows.Count; $rightIndex++) {
                $rightRoute = $routeLeaseRows[$rightIndex]
                $rightRouteIndex = [long]$rightRoute.RouteIndex
                if ($leftRouteIndex -ge 0 -and $leftRouteIndex -le 3 -and $rightRouteIndex -ge 0 -and $rightRouteIndex -le 3) { continue }
                $isMaterializationSource = ($leftRouteIndex -eq 5 -and $rightRouteIndex -ge 6 -and $rightRouteIndex -le 8) -or
                    ($rightRouteIndex -eq 5 -and $leftRouteIndex -ge 6 -and $leftRouteIndex -le 8)
                if ($isMaterializationSource) { continue }
                Assert-SealedRegistryTargetContextsDisjoint -Left $leftRoute.Context -Right $rightRoute.Context -PathToken 'current-route-forbidden-path-overlap' -IdentityToken 'current-route-forbidden-identity-alias'
            }
        }
        for ($leftIndex=0; $leftIndex -lt $fixedLeaseRows.Count; $leftIndex++) {
            for ($rightIndex=$leftIndex+1; $rightIndex -lt $fixedLeaseRows.Count; $rightIndex++) {
                Assert-SealedRegistryTargetContextsDisjoint -Left $fixedLeaseRows[$leftIndex].Context -Right $fixedLeaseRows[$rightIndex].Context -PathToken 'current-route-forbidden-path-overlap' -IdentityToken 'current-route-forbidden-identity-alias'
            }
        }
        foreach ($routeRow in $routeLeaseRows) {
            foreach ($fixedRow in $fixedLeaseRows) {
                Assert-SealedRegistryTargetContextsDisjoint -Left $routeRow.Context -Right $fixedRow.Context -PathToken 'current-route-forbidden-path-overlap' -IdentityToken 'current-route-forbidden-identity-alias'
            }
        }
        foreach ($liveTarget in $liveTargets) {
            foreach ($routeRow in $routeLeaseRows) {
                Assert-SealedRegistryTargetContextsDisjoint -Left $liveTarget.TargetContext -Right $routeRow.Context -PathToken 'current-route-forbidden-path-overlap' -IdentityToken 'current-route-forbidden-identity-alias'
            }
            foreach ($fixedRow in $fixedLeaseRows) {
                Assert-SealedRegistryTargetContextsDisjoint -Left $liveTarget.TargetContext -Right $fixedRow.Context -PathToken 'current-route-forbidden-path-overlap' -IdentityToken 'current-route-forbidden-identity-alias'
            }
            foreach ($reservationRow in $reservationLeaseRows) {
                $reservation = $reservationRow.Reservation
                $isOwn = [string]$reservation.SourceKind -ceq 'home-root-claim' -and [string]$reservation.OwnerKey -ceq [string]$AuthorityContext.HomeAuthorityKey -and [string]$reservation.Platform -ceq [string]$liveTarget.Platform
                if ($isOwn) {
                    if ([string]$reservation.LocationKey -cne [string]$liveTarget.TargetContext.LocationKey -or [string]$reservation.RequestedPath -cne [string]$liveTarget.TargetContext.RequestedPath) { throw 'root-transition-not-supported' }
                    if ($null -ne $reservation.DirectoryIdentity -and [string]$reservation.DirectoryIdentity -cne [string]$liveTarget.TargetContext.DirectoryIdentity) { throw 'root-transition-not-supported' }
                    continue
                }
                Assert-SealedRegistryTargetContextsDisjoint -Left $liveTarget.TargetContext -Right $reservationRow.Context -PathToken 'current-route-forbidden-path-overlap' -IdentityToken 'current-route-forbidden-identity-alias'
            }
        }
        foreach ($routeRow in $routeLeaseRows) {
            foreach ($reservationRow in $reservationLeaseRows) {
                Assert-SealedRegistryTargetContextsDisjoint -Left $routeRow.Context -Right $reservationRow.Context -PathToken 'current-route-forbidden-path-overlap' -IdentityToken 'current-route-forbidden-identity-alias'
            }
        }
        for ($leftIndex=0; $leftIndex -lt $reservationLeaseRows.Count; $leftIndex++) {
            for ($rightIndex=$leftIndex+1; $rightIndex -lt $reservationLeaseRows.Count; $rightIndex++) {
                Assert-SealedRegistryTargetContextsDisjoint -Left $reservationLeaseRows[$leftIndex].Context -Right $reservationLeaseRows[$rightIndex].Context -PathToken 'registry reserved roots overlap' -IdentityToken 'registry reserved root identities collide'
            }
        }
        foreach ($fixedRow in $fixedLeaseRows) {
            foreach ($reservationRow in $reservationLeaseRows) {
                Assert-SealedRegistryTargetContextsDisjoint -Left $fixedRow.Context -Right $reservationRow.Context -PathToken 'registry reservation overlaps fixed infrastructure' -IdentityToken 'registry reservation aliases fixed infrastructure'
            }
        }

        return [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::new(
            $liveSetLease,$liveProjection,[AiAgentDotfiles.SealedRegistryRouteLeaseBinding[]]@($routeLeaseRows),
            [object[]]@($reservationLeaseRows | ForEach-Object { $_.Lease }),
            [object[]]@($fixedLeaseRows | ForEach-Object { $_.Lease }),$CurrentRouteRootSet,$CanonicalWitness,
            $currentRouteRootSetSnapshot,$entryCurrentRouteRootSetHash,$currentRouteRootSetSnapshotHash,
            [string]$liveProjection.HeldTargetSetHash)
    }
    catch {
        $primaryError = $_
        $cleanupError = $null
        try {
            $closeArguments = @{
                LiveSetLease=$liveSetLease
                RouteLeases=[object[]]@($routeHeldLeases)
                FixedLeases=[object[]]@($fixedLeaseRows | ForEach-Object { $_.Lease })
                ReservationLeases=[object[]]@($reservationLeaseRows | ForEach-Object { $_.Lease })
            }
            Close-SealedRegistryCurrentRouteResources @closeArguments
        }
        catch { $cleanupError = $_ }
        if ($null -ne $cleanupError) {
            try { $primaryError.Exception.Data['SealedRegistryRouteCleanupError'] = [string]$cleanupError.Exception.Message }
            catch { }
        }
        throw $primaryError
    }
}

function Assert-SealedRegistryCurrentRouteCaptureStable {
    param([Parameter(Mandatory)]$Capture)
    if (-not [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::IsGenuine($Capture) -or
        -not [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($Capture)) { throw 'route-witness-required' }
    try {
        $original = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetOriginalCurrentRouteRootSet($Capture)
        $snapshot = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCurrentRouteRootSetSnapshot($Capture)
        $canonicalWitness = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCanonicalWitness($Capture)
        $entryHash = [string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetEntryCurrentRouteRootSetHash($Capture)
        if ($entryHash -cnotmatch $script:SealedRegistryHashPattern) { throw 'route-witness-required' }
        $null = Assert-SealedCurrentRouteRootSet -RootSet $original -CanonicalWitness $canonicalWitness
        $currentOriginalHash = Get-SemanticJsonHash -InputObject (Get-SealedCurrentRouteRootSetProjection -RootSet $original)
        if ($currentOriginalHash -cne $entryHash -or [string]$original.RouteRootSetHash -cne $entryHash) { throw 'route-witness-required' }
        $null = Assert-SealedCurrentRouteRootSet -RootSet $snapshot -CanonicalWitness $canonicalWitness
        if ([string]$snapshot.RouteRootSetHash -cne $entryHash) { throw 'route-witness-required' }
        $currentSnapshotHash = Get-SemanticJsonHash -InputObject ([ordered]@{
            ResolverVersion=[string]$snapshot.ResolverVersion
            CanonicalWitnessHash=[string]$snapshot.CanonicalWitnessHash
            Roots=@($snapshot.Roots)
            FilesystemCapabilityCoverage=[string]$snapshot.FilesystemCapabilityCoverage
            RouteRootSetHash=[string]$snapshot.RouteRootSetHash
        })
        if ($currentSnapshotHash -cne [string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCurrentRouteRootSetSnapshotHash($Capture)) { throw 'route-witness-required' }

        $expectedKeys = @('RepoRoot:','GitDir:','GitCommonDir:','CanonicalContractRoot:','CandidateWorkspace:','EnvironmentMaterializationRoot:','SourceRoot:Claude','SourceRoot:Codex','SourceRoot:Reasonix','LiveMutationStagingRoot:Claude','LiveMutationStagingRoot:Codex','LiveMutationStagingRoot:Reasonix')
        $snapshotRows = @($snapshot.Roots)
        $routeLeaseRows = @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetRouteLeaseRows($Capture))
        $leaseRowIndex = 0
        for ($routeIndex=0; $routeIndex -lt $snapshotRows.Count; $routeIndex++) {
            $snapshotRow = $snapshotRows[$routeIndex]
            $expectedKey = [string]$snapshotRow.Role + ':' + [string]$snapshotRow.Platform
            if ($expectedKey -cne $expectedKeys[$routeIndex]) { throw 'route-witness-required' }
            if ([string]$snapshotRow.Applicability -cne 'PRESENT') { continue }
            if ($leaseRowIndex -ge $routeLeaseRows.Count) { throw 'route-witness-required' }
            $binding = $routeLeaseRows[$leaseRowIndex]
            if (-not [AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::IsGenuine($binding) -or
                [long][AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetRouteIndex($binding) -ne $routeIndex -or
                -not [object]::ReferenceEquals([AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetSpec($binding),$snapshotRow) -or
                [string][AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetRole($binding) -cne [string]$snapshotRow.Role -or
                [string][AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetApplicability($binding) -cne 'PRESENT' -or
                [string][AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetPath($binding) -cne [string]$snapshotRow.Path -or
                [string][AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetTargetContextHash($binding) -cne (Get-SemanticJsonHash -InputObject $snapshotRow.TargetContext)) {
                throw 'route-witness-required'
            }
            $bindingLease = [AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetLease($binding)
            $null = Assert-SealedHeldTargetContextLease -Lease $bindingLease
            $actual = Get-SealedHeldTargetContextLease -Lease $bindingLease
            if (-not [object]::ReferenceEquals([AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetContext($binding),$actual) -or
                [string]$actual.RequestedPath -cne [string][AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetPath($binding) -or
                [string]$actual.HeldMetadataHash -cne [string][AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetHeldMetadataHash($binding)) { throw 'route-witness-required' }
            $null = Assert-SealedHeldTargetContextMatchesMetadata -Expected $snapshotRow.TargetContext -Actual $actual
            $leaseRowIndex++
        }
        if ($leaseRowIndex -ne $routeLeaseRows.Count) { throw 'route-witness-required' }
    }
    catch { throw 'route-witness-required' }
    $liveSetLease = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveSetLease($Capture)
    $null = Assert-SealedHeldLiveTargetContextSet -Lease $liveSetLease
    $actualLiveProjection = Get-SealedHeldLiveTargetContextSet -Lease $liveSetLease
    if (-not [object]::ReferenceEquals([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveProjection($Capture),$actualLiveProjection) -or
        [string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetHeldTargetSetHash($Capture) -cne [string]$actualLiveProjection.HeldTargetSetHash) { throw 'route-witness-required' }
    foreach ($lease in @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetReservationLeases($Capture))) { $null = Assert-SealedHeldTargetContextLease -Lease $lease }
    foreach ($lease in @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetFixedLeases($Capture))) { $null = Assert-SealedHeldTargetContextLease -Lease $lease }
}

function Close-SealedRegistryCurrentRouteCapture {
    param([AllowNull()]$Capture)
    if ($null -eq $Capture) { return }
    if (-not [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::IsGenuine($Capture)) { throw 'route-witness-required' }
    if ([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsClosed($Capture)) { return }
    if (-not [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($Capture)) { throw 'route-close-active' }
    $stabilityError = $null
    $cleanupError = $null
    try { $null = Assert-SealedRegistryCurrentRouteCaptureStable -Capture $Capture }
    catch { $stabilityError = $_ }
    try { $null = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($Capture) }
    catch { $cleanupError = $_ }
    if ($null -ne $stabilityError) { throw 'route-witness-required' }
    if ($null -ne $cleanupError) { throw $cleanupError }
}

function Test-SealedRegistryAllowedOwnerSid {
    param([Parameter(Mandatory)][string]$OwnerSid,[Parameter(Mandatory)][string]$TokenSid)
    return ([string]$OwnerSid -ceq $TokenSid -or [string]$OwnerSid -ceq (Get-HomeAuthorityTokenDefaultOwnerSid))
}

function Get-SealedRegistryCanonicalSecurityTemplate {
    param([Parameter(Mandatory)][string]$TokenSid)
    $inheritance = [long]([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit)
    return [ordered]@{
        ResolverVersion = 'windows-token-sid-current-user-only-v2'
        OwnerSid = $TokenSid
        AreAccessRulesProtected = $true
        AccessRules = @([ordered]@{
            Sid = $TokenSid
            AccessControlType = [long][Security.AccessControl.AccessControlType]::Allow
            FileSystemRights = [long][Security.AccessControl.FileSystemRights]::FullControl
            InheritanceFlags = $inheritance
            PropagationFlags = [long][Security.AccessControl.PropagationFlags]::None
            IsInherited = $false
        })
    }
}

function Assert-SealedRegistryCurrentUserOnlySecuritySnapshot {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][ValidateSet('Directory','File')][string]$ResourceKind,
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$ExpectedIdentity
    )
    $explicit = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $TokenSid -ResourceKind $ResourceKind
    $evidence = ConvertFrom-HomeAuthoritySecuritySnapshot -Snapshot $Snapshot -ResourceKind $ResourceKind
    if ([string]$Snapshot.Identity -cne $ExpectedIdentity -or [long]$Snapshot.LinkCount -ne 1) { throw 'registry security identity changed' }
    $actualHash = Get-SemanticJsonHash -InputObject $evidence
    $allowedHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null = $allowedHashes.Add((Get-SemanticJsonHash -InputObject $explicit))

    # A create-new child beneath the atomically sealed OI/CI parent receives this
    # one inherited current-user ACE. It is as narrow as the explicit form and is
    # the form emitted by the existing Phase 1 atomic JSON publisher.
    $inherited = [ordered]@{
        ResolverVersion = [string]$explicit.ResolverVersion
        ResourceKind = $ResourceKind
        OwnerSid = $TokenSid
        AreAccessRulesProtected = $false
        AccessRules = @([ordered]@{
            Sid = $TokenSid
            AccessControlType = [long][Security.AccessControl.AccessControlType]::Allow
            FileSystemRights = [long][Security.AccessControl.FileSystemRights]::FullControl
            InheritanceFlags = if ($ResourceKind -ceq 'Directory') { [long]([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit) } else { [long][Security.AccessControl.InheritanceFlags]::None }
            PropagationFlags = [long][Security.AccessControl.PropagationFlags]::None
            IsInherited = $true
        })
    }
    $null = $allowedHashes.Add((Get-SemanticJsonHash -InputObject $inherited))

    # v2 also accepts the token default owner (the user SID on non-elevated
    # tokens, BUILTIN\Administrators on elevated admin tokens) because that is
    # the factual owner of objects the current token creates without an
    # explicit O: SDDL assignment. The DACL shapes stay current-user-only.
    $defaultOwnerSid = Get-HomeAuthorityTokenDefaultOwnerSid
    $null = $allowedHashes.Add((Get-SemanticJsonHash -InputObject (Copy-HomeAuthoritySecurityTemplateWithOwner -SecurityTemplate $explicit -OwnerSid $defaultOwnerSid)))
    $inheritedOwnerVariant = Copy-HomeAuthoritySecurityTemplateWithOwner -SecurityTemplate $inherited -OwnerSid $defaultOwnerSid
    $null = $allowedHashes.Add((Get-SemanticJsonHash -InputObject $inheritedOwnerVariant))
    if (-not $allowedHashes.Contains($actualHash)) { throw 'registry owner/DACL is not current-user-only' }
    return [pscustomobject][ordered]@{ Evidence=$evidence; EvidenceHash=$actualHash }
}

function Assert-SealedRegistryCanonicalDirectorySecuritySnapshot {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$ExpectedIdentity,
        [Parameter(Mandatory)][string]$ExpectedSecurityTemplateHash,
        [AllowNull()][string]$ExpectedFinalDaclHash
    )
    $evidence = ConvertFrom-HomeAuthoritySecuritySnapshot -Snapshot $Snapshot -ResourceKind Directory
    if ([string]$Snapshot.Identity -cne $ExpectedIdentity -or [long]$Snapshot.LinkCount -ne 1) { throw 'canonical recovery root security identity changed' }
    $canonicalEvidence = [ordered]@{
        ResolverVersion = [string]$evidence.ResolverVersion
        OwnerSid = [string]$evidence.OwnerSid
        AreAccessRulesProtected = [bool]$evidence.AreAccessRulesProtected
        AccessRules = @($evidence.AccessRules)
    }
    $actualHash = Get-SemanticJsonHash -InputObject $canonicalEvidence
    $allowedTemplateHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null = $allowedTemplateHashes.Add([string]$ExpectedSecurityTemplateHash)
    $defaultOwnerTemplate = Get-SealedRegistryCanonicalSecurityTemplate -TokenSid (Get-HomeAuthorityTokenDefaultOwnerSid)
    $null = $allowedTemplateHashes.Add((Get-SemanticJsonHash -InputObject $defaultOwnerTemplate))
    if (-not $allowedTemplateHashes.Contains($actualHash)) { throw 'canonical recovery root owner/DACL does not match the claimed protected template' }
    if (-not [string]::IsNullOrEmpty($ExpectedFinalDaclHash) -and $actualHash -cne $ExpectedFinalDaclHash) { throw 'canonical recovery root owner/DACL differs from the existing-root intent' }
    if (-not (Test-SealedRegistryAllowedOwnerSid -OwnerSid ([string]$canonicalEvidence.OwnerSid) -TokenSid $TokenSid) -or -not [bool]$canonicalEvidence.AreAccessRulesProtected) { throw 'canonical recovery root security authority mismatch' }
    return [pscustomobject][ordered]@{ Evidence=$canonicalEvidence; EvidenceHash=$actualHash }
}

function Open-SealedRegistryDirectoryCapture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$Label
    )
    $handles = Open-SafeDirectoryContainmentChain -Path ([IO.Path]::GetFullPath($Path))
    try {
        $held = $handles[$handles.Count - 1]
        if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($held)).Count -ne 0) { throw "${Label} has named streams" }
        $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($held)
        $securityEvidence = Assert-SealedRegistryCurrentUserOnlySecuritySnapshot -Snapshot $security -ResourceKind Directory -TokenSid $TokenSid -ExpectedIdentity ([string]$held.Info.Identity)
        return [pscustomobject][ordered]@{
            Path = [IO.Path]::GetFullPath($Path)
            Handles = $handles
            Handle = $held
            Identity = [string]$held.Info.Identity
            SecurityHash = [string]$securityEvidence.EvidenceHash
            InitialNames = @(Get-SealedRegistryOrdinalStrings -Values @([AiAgentDotfiles.NoFollowFile]::GetChildNames($held)))
            Label = $Label
        }
    }
    catch { Close-SafeDirectoryContainmentChain -Handles $handles; throw }
}

function Close-SealedRegistryDirectoryCapture {
    param([AllowNull()]$Capture)
    if ($null -ne $Capture -and $null -ne $Capture.Handles) { Close-SafeDirectoryContainmentChain -Handles $Capture.Handles }
}

function Open-SealedRegistryOpaqueDirectoryCapture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ExpectedSecurityTemplateHash,
        [AllowNull()][string]$ExpectedFinalDaclHash
    )
    $handles = Open-SafeDirectoryContainmentChain -Path ([IO.Path]::GetFullPath($Path))
    try {
        $held = $handles[$handles.Count - 1]
        if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($held)).Count -ne 0) { throw "${Label} has named streams" }
        $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($held)
        $securityEvidence = Assert-SealedRegistryCanonicalDirectorySecuritySnapshot -Snapshot $security -TokenSid $TokenSid -ExpectedIdentity ([string]$held.Info.Identity) -ExpectedSecurityTemplateHash $ExpectedSecurityTemplateHash -ExpectedFinalDaclHash $ExpectedFinalDaclHash
        return [pscustomobject][ordered]@{
            Path=[IO.Path]::GetFullPath($Path); Handles=$handles; Handle=$held; Identity=[string]$held.Info.Identity
            SecurityHash=[string]$securityEvidence.EvidenceHash; Label=$Label; SecurityKind='CanonicalProtected'
            ExpectedSecurityTemplateHash=$ExpectedSecurityTemplateHash; ExpectedFinalDaclHash=$ExpectedFinalDaclHash
        }
    }
    catch { Close-SafeDirectoryContainmentChain -Handles $handles; throw }
}

function Open-SealedRegistryIdentityDirectoryCapture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedIdentity,
        [Parameter(Mandatory)][string]$Label
    )
    $handles = Open-SafeDirectoryContainmentChain -Path ([IO.Path]::GetFullPath($Path))
    try {
        $held = $handles[$handles.Count - 1]
        if ([string]$held.Info.Identity -cne $ExpectedIdentity) { throw "${Label} identity differs from valid state" }
        if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($held)).Count -ne 0) { throw "${Label} has named streams" }
        $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($held)
        if ([string]$security.Identity -cne $ExpectedIdentity -or [long]$security.LinkCount -ne 1) { throw "${Label} security identity changed" }
        return [pscustomobject][ordered]@{
            Path=[IO.Path]::GetFullPath($Path); Handles=$handles; Handle=$held; Identity=$ExpectedIdentity
            SecuritySddl=[string]$security.Sddl; Label=$Label; SecurityKind='IdentityOnly'
        }
    }
    catch { Close-SafeDirectoryContainmentChain -Handles $handles; throw }
}

function Open-SealedRegistryHeldDirectoryChild {
    param(
        [Parameter(Mandatory)]$ParentHandle,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$Label
    )
    $held = [AiAgentDotfiles.NoFollowFile]::HoldChildDirectory($ParentHandle,$Name)
    try {
        if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($held)).Count -ne 0) { throw "${Label} has named streams" }
        $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($held)
        $securityEvidence = Assert-SealedRegistryCurrentUserOnlySecuritySnapshot -Snapshot $security -ResourceKind Directory -TokenSid $TokenSid -ExpectedIdentity ([string]$held.Info.Identity)
        return [pscustomobject][ordered]@{
            Handle=$held; Identity=[string]$held.Info.Identity; SecurityHash=[string]$securityEvidence.EvidenceHash
            InitialNames=@(Get-SealedRegistryOrdinalStrings -Values @([AiAgentDotfiles.NoFollowFile]::GetChildNames($held))); Label=$Label
        }
    }
    catch { $held.Dispose(); throw }
}

function Open-SealedRegistryJsonCapture {
    param(
        [Parameter(Mandatory)]$ParentHandle,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$Label
    )
    $held = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($ParentHandle,$Name)
    try {
        if ([long]$held.ReadResult.Length -gt $script:SealedRegistryMaximumArtifactBytes) { throw "${Label} exceeds the byte limit" }
        $security = [AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($held)
        $securityEvidence = Assert-SealedRegistryCurrentUserOnlySecuritySnapshot -Snapshot $security -ResourceKind File -TokenSid $TokenSid -ExpectedIdentity ([string]$held.ReadResult.Identity)
        $bytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($held,$script:SealedRegistryMaximumArtifactBytes)
        return [pscustomobject][ordered]@{
            Name=$Name; Handle=$held; Bytes=[byte[]]$bytes; Identity=[string]$held.ReadResult.Identity
            Length=[long]$held.ReadResult.Length; BytesHash=[string]$held.ReadResult.Sha256
            SecurityHash=[string]$securityEvidence.EvidenceHash; Label=$Label
        }
    }
    catch { $held.Dispose(); throw }
}

function ConvertFrom-SealedRegistryJsonCapture {
    param([Parameter(Mandatory)]$Capture)
    try {
        $json = [Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$Capture.Bytes)
        $document = ConvertFrom-SemanticJson -Json $json
    }
    catch { throw "$($Capture.Label) is not strict UTF-8 semantic JSON: $($_.Exception.Message)" }
    if ($document -isnot [System.Collections.IDictionary]) { throw "$($Capture.Label) JSON root must be an object" }
    return $document
}

function Assert-SealedRegistryCaptureStable {
    param([Parameter(Mandatory)]$Capture,[Parameter(Mandatory)][string]$TokenSid)
    $bytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($Capture.Handle,[long]$Capture.Length)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($bytes.LongLength -ne [long]$Capture.Length -or $hash -cne [string]$Capture.BytesHash -or [string]$Capture.Handle.Info.Identity -cne [string]$Capture.Identity) {
        throw "registry artifact drift: $($Capture.Label)"
    }
    $security = [AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($Capture.Handle)
    $securityEvidence = Assert-SealedRegistryCurrentUserOnlySecuritySnapshot -Snapshot $security -ResourceKind File -TokenSid $TokenSid -ExpectedIdentity ([string]$Capture.Identity)
    if ([string]$securityEvidence.EvidenceHash -cne [string]$Capture.SecurityHash) { throw "registry artifact security drift: $($Capture.Label)" }
}

function Assert-SealedRegistryDirectoryCaptureStable {
    param([Parameter(Mandatory)]$Capture,[Parameter(Mandatory)][string]$TokenSid)
    if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($Capture.Handle)).Count -ne 0) { throw "registry directory acquired named streams: $($Capture.Label)" }
    $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($Capture.Handle)
    $securityEvidence = Assert-SealedRegistryCurrentUserOnlySecuritySnapshot -Snapshot $security -ResourceKind Directory -TokenSid $TokenSid -ExpectedIdentity ([string]$Capture.Identity)
    if ([string]$securityEvidence.EvidenceHash -cne [string]$Capture.SecurityHash) { throw "registry directory security drift: $($Capture.Label)" }
}

function Assert-SealedRegistryIdentityDirectoryCaptureStable {
    param([Parameter(Mandatory)]$Capture)
    if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($Capture.Handle)).Count -ne 0) { throw "registry directory acquired named streams: $($Capture.Label)" }
    $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($Capture.Handle)
    if ([string]$security.Identity -cne [string]$Capture.Identity -or [long]$security.LinkCount -ne 1 -or [string]$security.Sddl -cne [string]$Capture.SecuritySddl) { throw "registry live-root capture drift: $($Capture.Label)" }
}

function Assert-SealedRegistryCanonicalDirectoryCaptureStable {
    param([Parameter(Mandatory)]$Capture,[Parameter(Mandatory)][string]$TokenSid)
    if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($Capture.Handle)).Count -ne 0) { throw "registry directory acquired named streams: $($Capture.Label)" }
    $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($Capture.Handle)
    $securityEvidence = Assert-SealedRegistryCanonicalDirectorySecuritySnapshot -Snapshot $security -TokenSid $TokenSid -ExpectedIdentity ([string]$Capture.Identity) -ExpectedSecurityTemplateHash ([string]$Capture.ExpectedSecurityTemplateHash) -ExpectedFinalDaclHash ([string]$Capture.ExpectedFinalDaclHash)
    if ([string]$securityEvidence.EvidenceHash -cne [string]$Capture.SecurityHash) { throw "registry canonical directory security drift: $($Capture.Label)" }
}

function Assert-SealedRegistryRootClaimsContract {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)
    Assert-SealedRegistryExactPropertySet -InputObject $Document -Expected @('SchemaVersion','ArtifactKind','HomeAuthorityKey','TokenSid','ResolverVersion','HomeRootLocationKey','LiveRootClaims') -Label 'root-claims'
    if ($Document.SchemaVersion -isnot [long] -or [long]$Document.SchemaVersion -ne 1) { throw 'root-claims SchemaVersion mismatch' }
    if ([string]$Document.ArtifactKind -cne 'root-claims') { throw 'root-claims ArtifactKind mismatch' }
    Assert-SealedRegistryString $Document.HomeAuthorityKey 'root-claims HomeAuthorityKey' $script:SealedRegistryHashPattern
    Assert-SealedRegistryString $Document.TokenSid 'root-claims TokenSid' '\AS-[0-9]+(?:-[0-9]+)+\z'
    Assert-SealedRegistryString $Document.ResolverVersion 'root-claims ResolverVersion' $null @('windows-token-sid-known-folder-v1')
    Assert-SealedRegistryString $Document.HomeRootLocationKey 'root-claims HomeRootLocationKey' '\A[a-z]:/[^/]'
    Assert-SealedRegistryArray $Document.LiveRootClaims 'root-claims LiveRootClaims' 3
    $expectedPlatforms = @('Claude','Codex','Reasonix')
    for ($index=0; $index -lt 3; $index++) {
        $claim = $Document.LiveRootClaims[$index]
        Assert-SealedRegistryExactPropertySet -InputObject $claim -Expected @('Platform','LocationKey','RequestedPath','InitialState','VolumeId','DeepestExistingParentPath','DeepestExistingParentIdentity','MissingRemainder','InitialDirectoryIdentity','ExpectedPostState') -Label "root-claims LiveRootClaims[$index]"
        Assert-SealedRegistryString $claim.Platform "root-claims Platform[$index]" $null @($expectedPlatforms[$index])
        Assert-SealedRegistryString $claim.LocationKey "root-claims LocationKey[$index]" '\A[a-z]:/[^/]'
        Assert-SealedRegistryString $claim.RequestedPath "root-claims RequestedPath[$index]" '\A[A-Za-z]:\\'
        Assert-SealedRegistryString $claim.InitialState "root-claims InitialState[$index]" $null @('ABSENT','EXISTS')
        Assert-SealedRegistryString $claim.VolumeId "root-claims VolumeId[$index]" '\A[0-9a-f]{8}\z'
        Assert-SealedRegistryString $claim.DeepestExistingParentPath "root-claims parent path[$index]" '\A[A-Za-z]:\\'
        Assert-SealedRegistryString $claim.DeepestExistingParentIdentity "root-claims parent identity[$index]" '\A[0-9a-f]{8}:[0-9a-f]{16}\z'
        Assert-SealedRegistryArray $claim.MissingRemainder "root-claims MissingRemainder[$index]"
        foreach ($segment in @($claim.MissingRemainder)) { Assert-SealedRegistryString $segment "root-claims remainder[$index]" '\A[^\\/:]+\z' }
        Assert-SealedRegistryString $claim.ExpectedPostState "root-claims ExpectedPostState[$index]" $null @('EXISTS')
        if ([string]$claim.InitialState -ceq 'ABSENT') {
            if ($null -ne $claim.InitialDirectoryIdentity -or @($claim.MissingRemainder).Count -lt 1) { throw "root-claims ABSENT branch mismatch: $index" }
        }
        else {
            Assert-SealedRegistryString $claim.InitialDirectoryIdentity "root-claims initial identity[$index]" '\A[0-9a-f]{8}:[0-9a-f]{16}\z'
            if (@($claim.MissingRemainder).Count -ne 0) { throw "root-claims EXISTS branch mismatch: $index" }
        }
    }
    Test-RootClaimsSemantics -Document $Document
}

function Assert-SealedRegistryPlatformRows {
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)][ValidateSet('Skills','Hashes','Identities')][string]$Kind,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-SealedRegistryArray $Rows $Label 3
    $expectedPlatforms = @('Claude','Codex','Reasonix')
    for ($index=0; $index -lt 3; $index++) {
        $row = $Rows[$index]
        $fields = switch ($Kind) {
            'Skills' { @('Platform','Skills') }
            'Hashes' { @('Platform','Hash') }
            'Identities' { @('Platform','LocationKey','ResolvedPath','VolumeId','DirectoryIdentity','FilesystemCapabilityHash') }
        }
        Assert-SealedRegistryExactPropertySet -InputObject $row -Expected $fields -Label "$Label[$index]"
        Assert-SealedRegistryString $row.Platform "$Label Platform[$index]" $null @($expectedPlatforms[$index])
        if ($Kind -ceq 'Skills') {
            Assert-SealedRegistryArray $row.Skills "$Label Skills[$index]"
            foreach ($skill in @($row.Skills)) { Assert-SealedRegistryString $skill "$Label skill[$index]" '\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z' }
        }
        elseif ($Kind -ceq 'Hashes') { Assert-SealedRegistryString $row.Hash "$Label Hash[$index]" $script:SealedRegistryHashPattern }
        else {
            Assert-SealedRegistryString $row.LocationKey "$Label LocationKey[$index]" '\A[a-z]:/[^/]'
            Assert-SealedRegistryString $row.ResolvedPath "$Label ResolvedPath[$index]" '\A[A-Za-z]:\\'
            Assert-SealedRegistryString $row.VolumeId "$Label VolumeId[$index]" '\A[0-9a-f]{8}\z'
            Assert-SealedRegistryString $row.DirectoryIdentity "$Label DirectoryIdentity[$index]" '\A[0-9a-f]{8}:[0-9a-f]{16}\z'
            Assert-SealedRegistryString $row.FilesystemCapabilityHash "$Label FilesystemCapabilityHash[$index]" $script:SealedRegistryHashPattern
        }
    }
}

function Assert-SealedRegistryCurrentEnvStateContract {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RootClaimsDocument,
        [Parameter(Mandatory)][byte[]]$RootClaimsBytes
    )
    $base = @('SchemaVersion','ArtifactKind','HomeAuthorityKey','AuthorityGeneration','RootClaimsHash','SelectionKind','EnvironmentName','EnvironmentLockHash','TaskOverlayHash','TaskOverlaySkills','ManifestHashes','FinalManagedHashes','FinalResolvedIdentities','FinalTargetContextHash','ControllerRepoFingerprint','ApprovedToolchainHash','PlanHash','DocumentHash','JournalId','PreStatePhaseHash','LastOperationKind')
    $operation = [string]$Document.LastOperationKind
    $fields = if ($operation -ceq 'controller-transition') { @($base)+@('ReceiptRef') } else { @($base)+@('ReceiptId','ReceiptHash') }
    Assert-SealedRegistryExactPropertySet -InputObject $Document -Expected $fields -Label 'current-env-state'
    if ($Document.SchemaVersion -isnot [long] -or [long]$Document.SchemaVersion -ne 3) { throw 'current-env-state SchemaVersion mismatch' }
    if ([string]$Document.ArtifactKind -cne 'current-env-state') { throw 'current-env-state ArtifactKind mismatch' }
    Assert-SealedRegistryInteger $Document.AuthorityGeneration 'current-env-state AuthorityGeneration' 1 9007199254740991
    foreach ($name in @('HomeAuthorityKey','RootClaimsHash','EnvironmentLockHash','TaskOverlayHash','FinalTargetContextHash','ControllerRepoFingerprint','ApprovedToolchainHash','PlanHash','DocumentHash','PreStatePhaseHash')) {
        Assert-SealedRegistryString $Document[$name] "current-env-state $name" $script:SealedRegistryHashPattern
    }
    Assert-SealedRegistryString $Document.SelectionKind 'current-env-state SelectionKind' $null @('environment')
    Assert-SealedRegistryString $Document.EnvironmentName 'current-env-state EnvironmentName' '\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z'
    Assert-SealedRegistryString $Document.JournalId 'current-env-state JournalId' $script:SealedRegistryUuidPattern
    $allowedOperations = @('initial','environment','task-overlay','migrate','adopt','repair-adopt','retirement','environment-rollback','controller-transition')
    Assert-SealedRegistryString $operation 'current-env-state LastOperationKind' $null $allowedOperations
    if ($operation -ceq 'controller-transition') {
        Assert-SealedRegistryString $Document.ReceiptRef 'current-env-state ReceiptRef' $null @('NO_LIVE_MUTATION')
    }
    else {
        Assert-SealedRegistryString $Document.ReceiptId 'current-env-state ReceiptId' $script:SealedRegistryUuidPattern
        Assert-SealedRegistryString $Document.ReceiptHash 'current-env-state ReceiptHash' $script:SealedRegistryHashPattern
        if ($operation -ceq 'initial' -and [string]$Document.EnvironmentName -cne 'full') { throw 'current-env-state initial branch must select full' }
    }
    Assert-SealedRegistryPlatformRows -Rows $Document.TaskOverlaySkills -Kind Skills -Label 'current-env-state TaskOverlaySkills'
    Assert-SealedRegistryPlatformRows -Rows $Document.ManifestHashes -Kind Hashes -Label 'current-env-state ManifestHashes'
    Assert-SealedRegistryPlatformRows -Rows $Document.FinalManagedHashes -Kind Hashes -Label 'current-env-state FinalManagedHashes'
    Assert-SealedRegistryPlatformRows -Rows $Document.FinalResolvedIdentities -Kind Identities -Label 'current-env-state FinalResolvedIdentities'
    Test-CurrentEnvStateAgainstRootClaimsSemanticsOnly -StateDocument $Document -RootClaimsDocument $RootClaimsDocument -RootClaimsBytes $RootClaimsBytes
}

function Assert-SealedRegistryCanonicalRootContext {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Context,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$SecurityTemplateHash
    )
    $fields = @('ResolverVersion','TargetStatus','LocationKey','RequestedPath','VolumeId','DeepestExistingParentPath','DeepestExistingParentIdentity','DeepestExistingParentOwnerSid','DeepestExistingParentDaclHash','MissingRemainder','ExpectedFinalOwnerSid','ExpectedFinalDaclTemplateHash','FinalDirectoryIdentity','FinalOwnerSid','FinalDaclHash')
    Assert-SealedRegistryExactPropertySet -InputObject $Context -Expected $fields -Label $Label
    Assert-SealedRegistryString $Context.ResolverVersion "$Label ResolverVersion" $null @('windows-token-sid-current-user-only-v2')
    Assert-SealedRegistryString $Context.TargetStatus "$Label TargetStatus" $null @('MISSING','EXISTS')
    Assert-SealedRegistryString $Context.RequestedPath "$Label RequestedPath"
    Assert-SealedRegistryString $Context.LocationKey "$Label LocationKey"
    $requested = Get-AuthorityCanonicalPathProjection -Path ([string]$Context.RequestedPath) -Role "$Label RequestedPath"
    if ([string]$Context.LocationKey -cne [string]$requested.LocationKey) { throw "$Label LocationKey mismatch" }
    Assert-SealedRegistryString $Context.VolumeId "$Label VolumeId" '\A[0-9a-f]{8}\z'
    Assert-SealedRegistryString $Context.DeepestExistingParentPath "$Label parent path"
    $parent = Get-AuthorityCanonicalPathProjection -Path ([string]$Context.DeepestExistingParentPath) -Role "$Label parent path" -AllowVolumeRoot
    Assert-SealedRegistryString $Context.DeepestExistingParentIdentity "$Label parent identity" '\A[0-9a-f]{8}:[0-9a-f]{16}\z'
    if (-not ([string]$Context.DeepestExistingParentIdentity).StartsWith(([string]$Context.VolumeId + ':'),[StringComparison]::Ordinal)) { throw "$Label parent identity/volume mismatch" }
    Assert-SealedRegistryString $Context.DeepestExistingParentOwnerSid "$Label parent owner" '\AS-[0-9]+(?:-[0-9]+)+\z'
    Assert-SealedRegistryString $Context.DeepestExistingParentDaclHash "$Label parent DACL hash" $script:SealedRegistryHashPattern
    Assert-SealedRegistryArray $Context.MissingRemainder "$Label MissingRemainder"
    foreach ($segment in @($Context.MissingRemainder)) { Assert-SealedRegistryString $segment "$Label missing segment" '\A[^\\/:]+\z' }
    if (-not (Test-SealedRegistryAllowedOwnerSid -OwnerSid ([string]$Context.DeepestExistingParentOwnerSid) -TokenSid $TokenSid) -or [string]$Context.ExpectedFinalOwnerSid -cne $TokenSid) { throw "$Label owner SID mismatch" }
    if ([string]$Context.ExpectedFinalDaclTemplateHash -cne $SecurityTemplateHash) { throw "$Label expected DACL template mismatch" }
    if ([string]$Context.TargetStatus -ceq 'MISSING') {
        if ($null -ne $Context.FinalDirectoryIdentity -or $null -ne $Context.FinalOwnerSid -or $null -ne $Context.FinalDaclHash -or @($Context.MissingRemainder).Count -lt 1) { throw "$Label MISSING branch mismatch" }
        $parentPrefix = [string]$parent.LocationKey + '/'
        if (-not ([string]$requested.LocationKey).StartsWith($parentPrefix,[StringComparison]::Ordinal)) { throw "$Label missing parent is not an ancestor" }
        $relative = @([IO.Path]::GetRelativePath([string]$parent.Path,[string]$requested.Path) -split '[\\/]')
        if (($relative -join "`0") -cne (@($Context.MissingRemainder) -join "`0")) { throw "$Label MissingRemainder mismatch" }
    }
    else {
        Assert-SealedRegistryString $Context.FinalDirectoryIdentity "$Label final identity" '\A[0-9a-f]{8}:[0-9a-f]{16}\z'
        Assert-SealedRegistryString $Context.FinalOwnerSid "$Label final owner" '\AS-[0-9]+(?:-[0-9]+)+\z'
        Assert-SealedRegistryString $Context.FinalDaclHash "$Label final DACL hash" $script:SealedRegistryHashPattern
        $allowedFinalDaclHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $null = $allowedFinalDaclHashes.Add([string]$SecurityTemplateHash)
        $null = $allowedFinalDaclHashes.Add((Get-SemanticJsonHash -InputObject (Get-SealedRegistryCanonicalSecurityTemplate -TokenSid (Get-HomeAuthorityTokenDefaultOwnerSid))))
        if (@($Context.MissingRemainder).Count -ne 0 -or [string]$parent.Path -cne [string]$requested.Path -or [string]$Context.FinalDirectoryIdentity -cne [string]$Context.DeepestExistingParentIdentity -or -not (Test-SealedRegistryAllowedOwnerSid -OwnerSid ([string]$Context.FinalOwnerSid) -TokenSid $TokenSid) -or -not $allowedFinalDaclHashes.Contains([string]$Context.FinalDaclHash)) { throw "$Label EXISTS branch mismatch" }
    }
}

function Assert-SealedRegistryCanonicalRootClaimContract {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory)][string]$ExpectedRepoId,
        [Parameter(Mandatory)]$AuthorityContext
    )
    $fields = @('SchemaVersion','ArtifactKind','RepoId','ClaimId','GitCommonDirHash','OwnerSid','SecurityResolverVersion','SecurityTemplateHash','CanonicalRecoveryRoot','CanonicalRecoveryRootIntent','CanonicalRecoveryRootIntentHash','FilesystemCapabilityHash','ControlBase','ControlBaseIntent','ControlBaseIntentHash','BackupRoot','BackupRootIntent','BackupRootIntentHash','SetupIntentHash','ExpectedSetupStateProjectionHash')
    Assert-SealedRegistryExactPropertySet -InputObject $Document -Expected $fields -Label 'canonical-root-claim'
    if ($Document.SchemaVersion -isnot [long] -or [long]$Document.SchemaVersion -ne 1 -or [string]$Document.ArtifactKind -cne 'canonical-root-claim') { throw 'canonical-root-claim version/kind mismatch' }
    foreach ($name in @('RepoId','ClaimId','GitCommonDirHash','SecurityTemplateHash','CanonicalRecoveryRootIntentHash','FilesystemCapabilityHash','ControlBaseIntentHash','BackupRootIntentHash','SetupIntentHash','ExpectedSetupStateProjectionHash')) { Assert-SealedRegistryString $Document[$name] "canonical-root-claim $name" $script:SealedRegistryHashPattern }
    if ([string]$Document.RepoId -cne $ExpectedRepoId -or [string]$Document.ClaimId -cne $ExpectedRepoId) { throw 'canonical-root-claim filename/repository identity mismatch' }
    $tokenSid = [string]$AuthorityContext.TokenSid
    Assert-SealedRegistryString $Document.OwnerSid 'canonical-root-claim OwnerSid' '\AS-[0-9]+(?:-[0-9]+)+\z'
    if ([string]$Document.OwnerSid -cne $tokenSid -or [string]$Document.SecurityResolverVersion -cne 'windows-token-sid-current-user-only-v2') { throw 'canonical-root-claim owner/security resolver mismatch' }
    $securityTemplate = Get-SealedRegistryCanonicalSecurityTemplate -TokenSid $tokenSid
    $securityTemplateHash = Get-SemanticJsonHash -InputObject $securityTemplate
    if ([string]$Document.SecurityTemplateHash -cne $securityTemplateHash) { throw 'canonical-root-claim security template mismatch' }
    foreach ($name in @('CanonicalRecoveryRoot','ControlBase','BackupRoot')) { Assert-SealedRegistryString $Document[$name] "canonical-root-claim $name" }
    $recovery = Get-AuthorityCanonicalPathProjection -Path ([string]$Document.CanonicalRecoveryRoot) -Role 'canonical-root-claim CanonicalRecoveryRoot'
    $control = Get-AuthorityCanonicalPathProjection -Path ([string]$Document.ControlBase) -Role 'canonical-root-claim ControlBase'
    $backup = Get-AuthorityCanonicalPathProjection -Path ([string]$Document.BackupRoot) -Role 'canonical-root-claim BackupRoot'
    if ([string]$control.Path -cne [string]$AuthorityContext.ControlBase -or [string]$backup.Path -cne [string]$AuthorityContext.BackupRoot) { throw 'canonical-root-claim shared infrastructure mismatch' }
    if ((Test-TargetPathOverlap -Left ([string]$recovery.Path) -Right ([string]$control.Path)) -or (Test-TargetPathOverlap -Left ([string]$recovery.Path) -Right ([string]$backup.Path)) -or (Test-TargetPathOverlap -Left ([string]$control.Path) -Right ([string]$backup.Path))) { throw 'canonical-root-claim private roots overlap' }
    foreach ($binding in @(
        [pscustomobject]@{ Name='CanonicalRecoveryRoot'; Path=[string]$recovery.Path; Context=$Document.CanonicalRecoveryRootIntent; Hash=[string]$Document.CanonicalRecoveryRootIntentHash },
        [pscustomobject]@{ Name='ControlBase'; Path=[string]$control.Path; Context=$Document.ControlBaseIntent; Hash=[string]$Document.ControlBaseIntentHash },
        [pscustomobject]@{ Name='BackupRoot'; Path=[string]$backup.Path; Context=$Document.BackupRootIntent; Hash=[string]$Document.BackupRootIntentHash }
    )) {
        Assert-SealedRegistryCanonicalRootContext -Context $binding.Context -Label "canonical-root-claim $($binding.Name)Intent" -TokenSid $tokenSid -SecurityTemplateHash $securityTemplateHash
        if ([string]$binding.Context.RequestedPath -cne [string]$binding.Path -or (Get-SemanticJsonHash -InputObject $binding.Context) -cne [string]$binding.Hash) { throw "canonical-root-claim $($binding.Name) intent mismatch" }
    }
    $bootstrapIntent = [ordered]@{
        OwnerSid=[string]$Document.OwnerSid; SecurityResolverVersion=[string]$Document.SecurityResolverVersion; SecurityTemplateHash=[string]$Document.SecurityTemplateHash
        CanonicalRecoveryRootIntent=$Document.CanonicalRecoveryRootIntent; CanonicalRecoveryRootIntentHash=[string]$Document.CanonicalRecoveryRootIntentHash
        ControlBaseIntent=$Document.ControlBaseIntent; ControlBaseIntentHash=[string]$Document.ControlBaseIntentHash
        BackupRootIntent=$Document.BackupRootIntent; BackupRootIntentHash=[string]$Document.BackupRootIntentHash
    }
    if ((Get-SemanticJsonHash -InputObject $bootstrapIntent) -cne [string]$Document.SetupIntentHash) { throw 'canonical-root-claim setup intent graph mismatch' }
    $projection = [ordered]@{
        SchemaVersion=1L; ArtifactKind='canonical-setup-state-projection'; RepoId=[string]$Document.RepoId; ClaimId=[string]$Document.ClaimId; GitCommonDirHash=[string]$Document.GitCommonDirHash
        OwnerSid=[string]$Document.OwnerSid; SecurityResolverVersion=[string]$Document.SecurityResolverVersion; SecurityTemplateHash=[string]$Document.SecurityTemplateHash
        CanonicalRecoveryRoot=[string]$Document.CanonicalRecoveryRoot; CanonicalRecoveryRootIntent=$Document.CanonicalRecoveryRootIntent; CanonicalRecoveryRootIntentHash=[string]$Document.CanonicalRecoveryRootIntentHash
        FilesystemCapabilityHash=[string]$Document.FilesystemCapabilityHash; ControlBase=[string]$Document.ControlBase; ControlBaseIntent=$Document.ControlBaseIntent; ControlBaseIntentHash=[string]$Document.ControlBaseIntentHash
        BackupRoot=[string]$Document.BackupRoot; BackupRootIntent=$Document.BackupRootIntent; BackupRootIntentHash=[string]$Document.BackupRootIntentHash; SetupIntentHash=[string]$Document.SetupIntentHash
    }
    if ((Get-SemanticJsonHash -InputObject $projection) -cne [string]$Document.ExpectedSetupStateProjectionHash) { throw 'canonical-root-claim setup-state projection mismatch' }
}

function New-SealedRegistryCanonicalOutputEvidence {
    param(
        [Parameter(Mandatory)]$CanonicalWitness,
        [Parameter(Mandatory)]$AuthorityContext
    )

    try {
        $repoRoot = [string](Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'RepoRoot')
        $canonicalLockHandle = Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'CanonicalLockHandle'
        $repoId = [string](Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'RepoId')
        $gitCommonDirHash = [string](Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'GitCommonDirHash')
        $tokenSid = [string](Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'TokenSid')
        $transactionsRoot = [string](Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'TransactionsRoot')
        $transactionSetHashDisplay = [string](Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'CanonicalTransactionSetHash')
        $unfinishedCountDisplay = [long](Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'UnfinishedCanonicalTransactionCount')
        $setupStateCapture = Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'SetupStateCapture'
        if ([string]::IsNullOrWhiteSpace($repoRoot) -or $null -eq $canonicalLockHandle -or
            $repoId -cnotmatch $script:SealedRegistryHashPattern -or $gitCommonDirHash -cnotmatch $script:SealedRegistryHashPattern -or
            $tokenSid -cne [string]$AuthorityContext.TokenSid -or [string]::IsNullOrWhiteSpace($transactionsRoot) -or
            $transactionSetHashDisplay -cnotmatch $script:SealedRegistryHashPattern -or $unfinishedCountDisplay -ne 0 -or
            $null -eq $setupStateCapture) { throw 'invalid canonical witness entry evidence' }

        $setupStateHandle = Get-SealedRegistryObjectValue -InputObject $setupStateCapture -Name 'Handle'
        $setupStatePath = [string](Get-SealedRegistryObjectValue -InputObject $setupStateCapture -Name 'Path')
        $schemaPath = [string](Get-SealedRegistryObjectValue -InputObject $setupStateCapture -Name 'SchemaPath')
        $captureIdentity = [string](Get-SealedRegistryObjectValue -InputObject $setupStateCapture -Name 'Identity')
        $captureLength = [long](Get-SealedRegistryObjectValue -InputObject $setupStateCapture -Name 'Length')
        $captureBytesHash = [string](Get-SealedRegistryObjectValue -InputObject $setupStateCapture -Name 'BytesHash')
        $captureSemanticHash = [string](Get-SealedRegistryObjectValue -InputObject $setupStateCapture -Name 'SemanticHash')
        if ($setupStateHandle -isnot [AiAgentDotfiles.SafeRegularFileHandle] -or
            [string]::IsNullOrWhiteSpace($setupStatePath) -or [string]::IsNullOrWhiteSpace($schemaPath) -or
            $captureIdentity -cnotmatch '\A[0-9a-f]{8}:[0-9a-f]{16}\z' -or $captureLength -lt 0 -or
            $captureBytesHash -cnotmatch $script:SealedRegistryHashPattern -or $captureSemanticHash -cnotmatch $script:SealedRegistryHashPattern) {
            throw 'invalid canonical setup-state entry capture'
        }

        $null = Assert-CanonicalHeldNamespaceWitness -Witness $CanonicalWitness -RepoRoot $repoRoot -CanonicalLockHandle $canonicalLockHandle
        $null = Assert-CanonicalHeldSetupStateCapture -Capture $setupStateCapture
        $bytesBefore = [byte[]][AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($setupStateHandle,$script:SealedRegistryMaximumArtifactBytes)
        $securityBefore = [AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($setupStateHandle)
        $bytesAfter = [byte[]][AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($setupStateHandle,$script:SealedRegistryMaximumArtifactBytes)
        $securityAfter = [AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($setupStateHandle)
        $bytesHashBefore = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytesBefore)).ToLowerInvariant()
        $bytesHashAfter = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytesAfter)).ToLowerInvariant()
        if ($bytesBefore.LongLength -ne $bytesAfter.LongLength -or $bytesHashBefore -cne $bytesHashAfter -or
            [string]$securityBefore.Identity -cne [string]$securityAfter.Identity -or [long]$securityBefore.LinkCount -ne 1 -or
            [long]$securityAfter.LinkCount -ne 1 -or [string]$securityBefore.Sddl -cne [string]$securityAfter.Sddl -or
            [string]$securityAfter.Identity -cne $captureIdentity -or $bytesAfter.LongLength -ne $captureLength -or
            $bytesHashAfter -cne $captureBytesHash) { throw 'canonical setup-state exact entry evidence drift' }

        $stateDocument = ConvertFrom-CanonicalHeldSetupStateBytes -Bytes $bytesAfter -Path $setupStatePath -SchemaPath $schemaPath -RepoId $repoId -GitCommonDirHash $gitCommonDirHash -TokenSid $tokenSid
        $semanticHash = Get-SemanticJsonHash -InputObject $stateDocument
        if ($semanticHash -cne $captureSemanticHash) { throw 'canonical setup-state exact semantic evidence drift' }

        $transactionProjection = Get-CanonicalHeldTransactionSetProjection -TransactionsRoot $transactionsRoot -ExpectedRepoId $repoId -ExpectedGitCommonDirHash $gitCommonDirHash
        $transactionSetHash = Get-SemanticJsonHash -InputObject $transactionProjection
        if ($transactionSetHash -cne $transactionSetHashDisplay) { throw 'canonical-recovery-required' }

        $null = Assert-CanonicalHeldNamespaceWitness -Witness $CanonicalWitness -RepoRoot $repoRoot -CanonicalLockHandle $canonicalLockHandle
        $currentCapture = Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'SetupStateCapture'
        $currentHandle = if ($null -eq $currentCapture) { $null } else { Get-SealedRegistryObjectValue -InputObject $currentCapture -Name 'Handle' }
        if (-not [object]::ReferenceEquals($currentCapture,$setupStateCapture) -or
            -not [object]::ReferenceEquals($currentHandle,$setupStateHandle)) { throw 'canonical setup-state entry reference drift' }

        return [AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::CreateExact(
            $CanonicalWitness,$canonicalLockHandle,$setupStateCapture,$setupStateHandle,$stateDocument,
            $repoRoot,$repoId,$gitCommonDirHash,[string]$securityAfter.Identity,[long]$bytesAfter.LongLength,
            $bytesHashAfter,$semanticHash,$transactionSetHash)
    }
    catch {
        if ($_.Exception.Message -ceq 'canonical-recovery-required') { throw }
        throw 'canonical-witness-required'
    }
}

function Assert-SealedRegistryCanonicalSetupStateBinding {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Claim,
        [Parameter(Mandatory)][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]$CanonicalEvidence,
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$RecoveryCapture,
        [Parameter(Mandatory)]$ControlHandle,
        [Parameter(Mandatory)]$BackupCapture
    )
    $fields = @(
        'SchemaVersion','ArtifactKind','RepoId','ClaimId','GitCommonDirHash','OwnerSid','SecurityResolverVersion','SecurityTemplateHash',
        'CanonicalRecoveryRoot','CanonicalRecoveryRootIntent','CanonicalRecoveryRootIntentHash','CanonicalRecoveryRootFinalContext','CanonicalRecoveryRootFinalContextHash','FilesystemCapabilityHash',
        'ControlBase','ControlBaseIntent','ControlBaseIntentHash','ControlBaseFinalContext','ControlBaseFinalContextHash',
        'BackupRoot','BackupRootIntent','BackupRootIntentHash','BackupRootFinalContext','BackupRootFinalContextHash',
        'SetupIntentHash','SetupStateProjectionHash','RootClaimHash'
    )
    Assert-SealedRegistryExactPropertySet -InputObject $State -Expected $fields -Label 'canonical-setup-state'
    if ($State.SchemaVersion -isnot [long] -or [long]$State.SchemaVersion -ne 1 -or [string]$State.ArtifactKind -cne 'canonical-setup-state') { throw 'canonical-root-transition-not-supported' }
    foreach ($name in @('RepoId','ClaimId','GitCommonDirHash','SecurityTemplateHash','CanonicalRecoveryRootIntentHash','CanonicalRecoveryRootFinalContextHash','FilesystemCapabilityHash','ControlBaseIntentHash','ControlBaseFinalContextHash','BackupRootIntentHash','BackupRootFinalContextHash','SetupIntentHash','SetupStateProjectionHash','RootClaimHash')) {
        Assert-SealedRegistryString $State[$name] "canonical-setup-state $name" $script:SealedRegistryHashPattern
    }
    $evidenceRepoId = [string][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetRepoIdExact($CanonicalEvidence)
    $evidenceGitCommonDirHash = [string][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetGitCommonDirHashExact($CanonicalEvidence)
    if ([string]$State.RepoId -cne $evidenceRepoId -or [string]$State.ClaimId -cne $evidenceRepoId -or [string]$State.GitCommonDirHash -cne $evidenceGitCommonDirHash) { throw 'canonical-root-transition-not-supported' }
    if ([string]$Claim.RepoId -cne [string]$State.RepoId -or [string]$Claim.ClaimId -cne [string]$State.ClaimId -or [string]$Claim.GitCommonDirHash -cne [string]$State.GitCommonDirHash) { throw 'canonical-root-transition-not-supported' }
    foreach ($name in @('OwnerSid','SecurityResolverVersion','SecurityTemplateHash','CanonicalRecoveryRoot','CanonicalRecoveryRootIntentHash','FilesystemCapabilityHash','ControlBase','ControlBaseIntentHash','BackupRoot','BackupRootIntentHash','SetupIntentHash')) {
        if ([string]$Claim[$name] -cne [string]$State[$name]) { throw 'canonical-root-transition-not-supported' }
    }
    foreach ($name in @('CanonicalRecoveryRootIntent','ControlBaseIntent','BackupRootIntent')) {
        if ((Get-SemanticJsonHash -InputObject $Claim[$name]) -cne (Get-SemanticJsonHash -InputObject $State[$name])) { throw 'canonical-root-transition-not-supported' }
    }
    if ([string]$State.OwnerSid -cne [string]$AuthorityContext.TokenSid -or [string]$State.ControlBase -cne [string]$AuthorityContext.ControlBase -or [string]$State.BackupRoot -cne [string]$AuthorityContext.BackupRoot) { throw 'canonical-root-transition-not-supported' }

    $projection = [ordered]@{
        SchemaVersion=1L; ArtifactKind='canonical-setup-state-projection'; RepoId=[string]$State.RepoId; ClaimId=[string]$State.ClaimId; GitCommonDirHash=[string]$State.GitCommonDirHash
        OwnerSid=[string]$State.OwnerSid; SecurityResolverVersion=[string]$State.SecurityResolverVersion; SecurityTemplateHash=[string]$State.SecurityTemplateHash
        CanonicalRecoveryRoot=[string]$State.CanonicalRecoveryRoot; CanonicalRecoveryRootIntent=$State.CanonicalRecoveryRootIntent; CanonicalRecoveryRootIntentHash=[string]$State.CanonicalRecoveryRootIntentHash
        FilesystemCapabilityHash=[string]$State.FilesystemCapabilityHash; ControlBase=[string]$State.ControlBase; ControlBaseIntent=$State.ControlBaseIntent; ControlBaseIntentHash=[string]$State.ControlBaseIntentHash
        BackupRoot=[string]$State.BackupRoot; BackupRootIntent=$State.BackupRootIntent; BackupRootIntentHash=[string]$State.BackupRootIntentHash; SetupIntentHash=[string]$State.SetupIntentHash
    }
    $projectionHash = Get-SemanticJsonHash -InputObject $projection
    if ($projectionHash -cne [string]$State.SetupStateProjectionHash -or $projectionHash -cne [string]$Claim.ExpectedSetupStateProjectionHash -or
        (Get-SemanticJsonHash -InputObject $Claim) -cne [string]$State.RootClaimHash) { throw 'canonical-root-transition-not-supported' }

    $securityTemplateHash = [string]$State.SecurityTemplateHash
    foreach ($binding in @(
        [pscustomobject]@{Name='CanonicalRecoveryRoot';Context=$State.CanonicalRecoveryRootFinalContext;Hash=[string]$State.CanonicalRecoveryRootFinalContextHash;Path=[string]$State.CanonicalRecoveryRoot;Handle=$RecoveryCapture.Handle;Identity=[string]$RecoveryCapture.Identity},
        [pscustomobject]@{Name='ControlBase';Context=$State.ControlBaseFinalContext;Hash=[string]$State.ControlBaseFinalContextHash;Path=[string]$State.ControlBase;Handle=$ControlHandle;Identity=[string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($ControlHandle)},
        [pscustomobject]@{Name='BackupRoot';Context=$State.BackupRootFinalContext;Hash=[string]$State.BackupRootFinalContextHash;Path=[string]$State.BackupRoot;Handle=$BackupCapture.Handle;Identity=[string]$BackupCapture.Identity}
    )) {
        Assert-SealedRegistryCanonicalRootContext -Context $binding.Context -Label "canonical-setup-state $($binding.Name)FinalContext" -TokenSid ([string]$AuthorityContext.TokenSid) -SecurityTemplateHash $securityTemplateHash
        if ([string]$binding.Context.TargetStatus -cne 'EXISTS' -or [string]$binding.Context.RequestedPath -cne [string]$binding.Path -or
            [string]$binding.Context.FinalDirectoryIdentity -cne [string]$binding.Identity -or (Get-SemanticJsonHash -InputObject $binding.Context) -cne [string]$binding.Hash) { throw 'canonical-root-transition-not-supported' }
        $snapshot = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($binding.Handle)
        $security = Assert-SealedRegistryCanonicalDirectorySecuritySnapshot -Snapshot $snapshot -TokenSid ([string]$AuthorityContext.TokenSid) -ExpectedIdentity ([string]$binding.Identity) -ExpectedSecurityTemplateHash $securityTemplateHash -ExpectedFinalDaclHash ([string]$binding.Context.FinalDaclHash)
        if ([string]$security.EvidenceHash -cne [string]$binding.Context.FinalDaclHash) { throw 'canonical-root-transition-not-supported' }
    }
    return [pscustomobject][ordered]@{
        SetupStateProjectionHash=$projectionHash; RootClaimHash=[string]$State.RootClaimHash; SetupIntentHash=[string]$State.SetupIntentHash
    }
}

function Assert-SealedHomeAuthorityGlobalLockWitness {
    param([Parameter(Mandatory)]$AuthorityContext,[AllowNull()]$GlobalLockHandle)
    if ($null -eq $GlobalLockHandle) { throw 'home-authority-registry-lock-required' }
    if ('AiAgentDotfiles.HomeAuthorityLockHandle' -cnotin @($GlobalLockHandle.PSObject.TypeNames)) { throw 'home-authority-registry-lock-required' }
    try {
        $display = @{}
        foreach ($name in @('Path','HeldLock','ParentHandles','Info','SecurityHash','FixedEnvelopeHash')) {
            $property = $GlobalLockHandle.PSObject.Properties[$name]
            if ($null -eq $property) { throw "missing wrapper property: $name" }
            $value = $property.Value
            if ($null -eq $value) { throw "null wrapper property: $name" }
            $display[$name] = $value
        }
        $expectedPath = [IO.Path]::GetFullPath([string]$AuthorityContext.GlobalLiveLockPath)
        $owner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($GlobalLockHandle)
        if ($owner -isnot [AiAgentDotfiles.SafeLockResourceOwner] -or
            -not [AiAgentDotfiles.SafeLockResourceOwner]::IsExactForWrapper($owner,$GlobalLockHandle) -or
            -not [AiAgentDotfiles.SafeLockResourceOwner]::MatchesAcquiredEvidenceExact($owner) -or
            [AiAgentDotfiles.SafeLockResourceOwner]::GetIsReleasedExact($owner)) { throw 'missing or invalid private lock owner' }
        if ([string]$display.Path -cne $expectedPath -or
            -not ([AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($owner)).Equals($expectedPath,[StringComparison]::OrdinalIgnoreCase) -or
            [string]$display.SecurityHash -cnotmatch $script:SealedRegistryHashPattern -or
            [string]$display.FixedEnvelopeHash -cnotmatch $script:SealedRegistryHashPattern) { throw 'invalid global lock display evidence' }

        $binding = [AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($GlobalLockHandle)
        $heldLock = [AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($owner)
        $boundParent = if ($binding -is [AiAgentDotfiles.SafeLockOrderBinding]) { [AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentParentExact($binding) } else { $null }
        if ($heldLock -isnot [AiAgentDotfiles.SafeLockFileHandle] -or -not [object]::ReferenceEquals($display.HeldLock,$heldLock) -or
            ($binding -is [AiAgentDotfiles.SafeLockOrderBinding] -and -not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentExact($binding),$heldLock)) -or
            -not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($heldLock)) { throw 'wrong or disposed lock type' }
        $lockInfo = [AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($heldLock)
        $lockIdentity = [string][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact($heldLock)
        $lockLinkCount = [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLinkCountExact($heldLock)
        $lockLength = [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLengthExact($heldLock)
        if (-not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockResourceOwner]::GetInfoExact($owner),$lockInfo) -or
            -not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockResourceOwner]::GetStreamViewExact($owner),[AiAgentDotfiles.SafeLockFileHandle]::GetStreamViewExact($heldLock)) -or
            -not [object]::ReferenceEquals($display.Info,$lockInfo) -or [string]$lockInfo.Identity -cne $lockIdentity -or
            [long]$lockInfo.LinkCount -ne $lockLinkCount -or [long]$lockInfo.Length -ne $lockLength -or
            $lockIdentity -cne [string][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredIdentityExact($owner) -or
            $lockLinkCount -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLinkCountExact($owner) -or
            $lockLength -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLengthExact($owner) -or
            [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquisitionOrdinalExact($heldLock) -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquisitionOrdinalExact($owner) -or
            $lockLinkCount -ne 1 -or $lockLength -ne 0) { throw 'immutable lock acquisition evidence mismatch' }

        $parentHandles = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($owner))
        if ($parentHandles.Count -lt 1) { throw 'missing parent' }
        $displayParents = @($display.ParentHandles)
        if ($displayParents.Count -ne $parentHandles.Count) { throw 'parent display cardinality changed' }
        for ($index=0; $index -lt $parentHandles.Count; $index++) {
            if (-not [object]::ReferenceEquals($displayParents[$index],$parentHandles[$index])) { throw 'parent display reference changed' }
        }
        for ($index=0; $index -lt $parentHandles.Count; $index++) {
            $parentEntry = $parentHandles[$index]
            if ($parentEntry -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($parentEntry) -or
                [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($parentEntry) -cne [string][AiAgentDotfiles.SafeLockResourceOwner]::GetParentIdentityExact($owner,$index) -or
                [long][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredLinkCountExact($parentEntry) -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetParentLinkCountExact($owner,$index)) {
                throw 'wrong, disposed, or drifted parent type'
            }
        }
        $parent = $parentHandles[$parentHandles.Count-1]
        if ($null -ne $boundParent -and -not [object]::ReferenceEquals($parent,$boundParent)) { throw 'bound final parent was substituted' }
        $parentInfo = [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($parent)
        $parentIdentity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($parent)
        if ([string]$parentInfo.Identity -cne $parentIdentity -or [long]$parentInfo.LinkCount -ne [long][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredLinkCountExact($parent)) {
            throw 'immutable parent acquisition evidence mismatch'
        }
        $freshParents = $null
        try {
            $freshParents = Open-SafeDirectoryContainmentChain -Path ([string]$AuthorityContext.ControlBase)
            if ($freshParents.Count -ne $parentHandles.Count) { throw 'parent chain cardinality changed' }
            for ($index=0; $index -lt $parentHandles.Count; $index++) {
                if ([string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($freshParents[$index]) -cne
                    [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($parentHandles[$index])) { throw 'parent chain identity changed' }
            }
        }
        finally { if ($null -ne $freshParents) { Close-SafeDirectoryContainmentChain -Handles $freshParents } }

        $relative = [AiAgentDotfiles.NoFollowFile]::InspectChild($parent,[IO.Path]::GetFileName($expectedPath))
        $parentMarker = Get-NoFollowRootEntryMarker -Path ([string]$AuthorityContext.ControlBase)
        if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($heldLock)).Count -ne 0) { throw 'lock file has named streams' }
        $securityBefore = [AiAgentDotfiles.NoFollowFile]::GetLockFileSecuritySnapshot($heldLock)
        $security = [AiAgentDotfiles.NoFollowFile]::GetLockFileSecuritySnapshot($heldLock)
        if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($heldLock)).Count -ne 0) { throw 'lock file acquired named streams' }
        $fileTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid ([string]$AuthorityContext.TokenSid) -ResourceKind File
        $securityEvidence = Assert-HomeAuthoritySecuritySnapshot -Snapshot $security -SecurityTemplate $fileTemplate -ExpectedIdentity $lockIdentity
        if ([string]$securityBefore.Identity -cne [string]$security.Identity -or [string]$securityBefore.Sddl -cne [string]$security.Sddl -or
            [string]$parentMarker.EntryType -cne 'Directory' -or [string]$parentMarker.Identity -cne $parentIdentity -or
            [string]$relative.Identity -cne $lockIdentity -or [long]$relative.LinkCount -ne 1 -or [long]$relative.Length -ne 0 -or
            $relative.IsDirectory -or $relative.IsReparsePoint -or
            [string][AiAgentDotfiles.SafeLockResourceOwner]::GetSecurityHashExact($owner) -cne [string]$securityEvidence.EvidenceHash -or
            [string]$display.SecurityHash -cne [string]$securityEvidence.EvidenceHash) { throw 'identity mismatch' }

        $directoryTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid ([string]$AuthorityContext.TokenSid) -ResourceKind Directory
        $parentSecurity = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($parent)
        $parentSecurityEvidence = Assert-HomeAuthoritySecuritySnapshot -Snapshot $parentSecurity -SecurityTemplate $directoryTemplate -ExpectedIdentity $parentIdentity
        if ([string]$parentSecurityEvidence.EvidenceHash -cnotmatch $script:SealedRegistryHashPattern) { throw 'invalid parent security evidence' }
        return [AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::CreateExact(
            $GlobalLockHandle,$heldLock,$parent,[object[]]$parentHandles,$expectedPath,$lockIdentity,$parentIdentity,
            [string]$securityEvidence.EvidenceHash,[string]$display.FixedEnvelopeHash,(Get-SemanticJsonHash -InputObject $AuthorityContext))
    }
    catch { throw 'home-authority-registry-lock-required' }
}

function Assert-SealedRegistryReservationsDisjoint {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Reservations,
        [Parameter(Mandatory)][string[]]$ForbiddenRoots
    )
    $ordered = @(Get-SealedRegistryOrderedReservations -Reservations $Reservations)
    $volumeByDrive = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $driveByVolume = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $identityByLocation = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $locationByIdentity = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $parentIdentityByLocation = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $parentLocationByIdentity = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($row in $ordered) {
        $projection = Get-AuthorityCanonicalPathProjection -Path ([string]$row.RequestedPath) -Role 'registry reservation path'
        if ([string]$projection.LocationKey -cne [string]$row.LocationKey) { throw 'registry reservation path/location mismatch' }
        foreach ($forbiddenRoot in $ForbiddenRoots) {
            if (Test-TargetPathOverlap -Left ([string]$projection.Path) -Right ([IO.Path]::GetFullPath($forbiddenRoot))) { throw "registry reservation overlaps fixed infrastructure: $($row.OwnerKey)/$($row.Role)" }
        }
        Assert-SealedRegistryString $row.VolumeId 'registry reservation VolumeId' '\A[0-9a-f]{8}\z'
        $drive = [IO.Path]::GetPathRoot([string]$projection.Path).TrimEnd([char]92,[char]47).ToLowerInvariant()
        $known = $null
        if ($volumeByDrive.TryGetValue($drive,[ref]$known)) { if ($known -cne [string]$row.VolumeId) { throw 'registry one drive has conflicting VolumeId values' } }
        else { $volumeByDrive.Add($drive,[string]$row.VolumeId) }
        $known = $null
        if ($driveByVolume.TryGetValue([string]$row.VolumeId,[ref]$known)) { if ($known -cne $drive) { throw 'registry one VolumeId aliases multiple drive roots' } }
        else { $driveByVolume.Add([string]$row.VolumeId,$drive) }
        $known = $null
        if ($parentIdentityByLocation.TryGetValue([string]$row.ParentLocationKey,[ref]$known)) { if ($known -cne [string]$row.ParentIdentity) { throw 'registry parent location has conflicting identities' } }
        else { $parentIdentityByLocation.Add([string]$row.ParentLocationKey,[string]$row.ParentIdentity) }
        $known = $null
        if ($parentLocationByIdentity.TryGetValue([string]$row.ParentIdentity,[ref]$known)) { if ($known -cne [string]$row.ParentLocationKey) { throw 'registry parent identity aliases multiple locations' } }
        else { $parentLocationByIdentity.Add([string]$row.ParentIdentity,[string]$row.ParentLocationKey) }
        if ($null -ne $row.DirectoryIdentity) {
            Assert-SealedRegistryString $row.DirectoryIdentity 'registry reservation DirectoryIdentity' '\A[0-9a-f]{8}:[0-9a-f]{16}\z'
            if (-not ([string]$row.DirectoryIdentity).StartsWith(([string]$row.VolumeId + ':'),[StringComparison]::Ordinal)) { throw 'registry reservation identity/volume mismatch' }
            $known = $null
            if ($identityByLocation.TryGetValue([string]$row.LocationKey,[ref]$known)) { if ($known -cne [string]$row.DirectoryIdentity) { throw 'registry location has conflicting identities' } }
            else { $identityByLocation.Add([string]$row.LocationKey,[string]$row.DirectoryIdentity) }
            $known = $null
            if ($locationByIdentity.TryGetValue([string]$row.DirectoryIdentity,[ref]$known)) { if ($known -cne [string]$row.LocationKey) { throw 'registry directory identity aliases multiple locations' } }
            else { $locationByIdentity.Add([string]$row.DirectoryIdentity,[string]$row.LocationKey) }
        }
    }
    for ($leftIndex=0; $leftIndex -lt $ordered.Count; $leftIndex++) {
        $left = $ordered[$leftIndex]
        for ($rightIndex=$leftIndex+1; $rightIndex -lt $ordered.Count; $rightIndex++) {
            $right = $ordered[$rightIndex]
            if (Test-TargetPathOverlap -Left ([string]$left.RequestedPath) -Right ([string]$right.RequestedPath)) { throw "registry reserved roots overlap: $($left.OwnerKey)/$($right.OwnerKey)" }
            if ($null -ne $left.DirectoryIdentity -and $null -ne $right.DirectoryIdentity -and [string]$left.DirectoryIdentity -ceq [string]$right.DirectoryIdentity) { throw "registry reserved root identities collide: $($left.OwnerKey)/$($right.OwnerKey)" }
            if ($null -ne $left.DirectoryIdentity -and [string]$left.DirectoryIdentity -ceq [string]$right.ParentIdentity) { throw "registry reserved root aliases another parent: $($left.OwnerKey)/$($right.OwnerKey)" }
            if ($null -ne $right.DirectoryIdentity -and [string]$right.DirectoryIdentity -ceq [string]$left.ParentIdentity) { throw "registry reserved root aliases another parent: $($left.OwnerKey)/$($right.OwnerKey)" }
        }
    }
}

function Get-SealedHomeAuthorityRegistryView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$GlobalLockHandle,
        [AllowNull()]$CanonicalWitness,
        [AllowNull()]$CurrentRouteRootSet
    )

    $null = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
    $entryGlobalLockEvidence = Assert-SealedHomeAuthorityGlobalLockWitness -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle
    $entryCanonicalOutputEvidence = $null
    if ($null -eq $CanonicalWitness -and $null -ne $CurrentRouteRootSet) { throw 'route-witness-required' }
    if ($null -ne $CanonicalWitness) {
        if ('AiAgentDotfiles.CanonicalNamespaceWitness' -cnotin @($CanonicalWitness.PSObject.TypeNames)) { throw 'canonical-witness-required' }
        $canonicalRepoRoot = Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'RepoRoot'
        $canonicalLockHandle = Get-SealedRegistryObjectValue -InputObject $CanonicalWitness -Name 'CanonicalLockHandle'
        if ([string]::IsNullOrWhiteSpace([string]$canonicalRepoRoot) -or $null -eq $canonicalLockHandle) { throw 'canonical-witness-required' }
        $null = Assert-CanonicalHeldNamespaceWitness -Witness $CanonicalWitness -RepoRoot ([string]$canonicalRepoRoot) -CanonicalLockHandle $canonicalLockHandle
        if ($null -eq $CurrentRouteRootSet) { throw 'route-witness-required' }
        $null = Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness
        $null = Assert-SealedCurrentRouteRootSet -RootSet $CurrentRouteRootSet -CanonicalWitness $CanonicalWitness
        $entryCanonicalOutputEvidence = New-SealedRegistryCanonicalOutputEvidence -CanonicalWitness $CanonicalWitness -AuthorityContext $AuthorityContext
    }
    $tokenSid = [string]$AuthorityContext.TokenSid
    $directoryTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $tokenSid -ResourceKind Directory
    $fileTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $tokenSid -ResourceKind File
    $fixedEnvelope = $null
    $rootCaptures = [Collections.Generic.List[object]]::new()
    $externalRootCaptures = [Collections.Generic.List[object]]::new()
    $liveRootCaptures = [Collections.Generic.List[object]]::new()
    $directoryChildren = [Collections.Generic.List[object]]::new()
    $fileCaptures = [Collections.Generic.List[object]]::new()
    $currentRouteCapture = $null
    $registryCleanupStack = [Collections.Generic.List[object]]::new()
    $registryPrimaryError = $null
    try {
        $fixedEnvelope = Open-SealedHomeAuthorityFixedEnvelope -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate -HeldGlobalLock $GlobalLockHandle
        $registryCleanupStack.Add([pscustomobject]@{Kind='FixedEnvelope';Resource=$fixedEnvelope})
        if ([string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetFixedEnvelopeHashExact($entryGlobalLockEvidence) -cne [string]$fixedEnvelope.InitialEnvelopeHash) { throw 'fixed envelope differs from the acquired-lock witness' }
        foreach ($spec in @(
            [pscustomobject]@{ Name='CanonicalRoots'; Path=[string]$AuthorityContext.CanonicalRootsRoot },
            [pscustomobject]@{ Name='Homes'; Path=[string]$AuthorityContext.HomesRoot },
            [pscustomobject]@{ Name='LiveTransactions'; Path=[string]$AuthorityContext.LiveTransactionsRoot },
            [pscustomobject]@{ Name='Backups'; Path=[string]$AuthorityContext.BackupRoot }
        )) {
            $rootCapture = Open-SealedRegistryDirectoryCapture -Path $spec.Path -TokenSid $tokenSid -Label $spec.Name
            $rootCaptures.Add($rootCapture)
            $registryCleanupStack.Add([pscustomobject]@{Kind='DirectoryCapture';Resource=$rootCapture})
        }
        $canonicalRoot = $rootCaptures[0]; $homesRoot = $rootCaptures[1]; $liveRoot = $rootCaptures[2]; $backupRoot = $rootCaptures[3]
        if (@($backupRoot.InitialNames).Count -ne 0) { throw 'backup receipt contract not yet supported' }

        $canonicalRows = [Collections.Generic.List[object]]::new()
        $reservations = [Collections.Generic.List[object]]::new()
        $repoIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $gitHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $canonicalWitnessMatched = $false
        foreach ($name in @($canonicalRoot.InitialNames)) {
            if ($name -cnotmatch '\A([0-9a-f]{64})\.json\z') { throw "canonical-roots contains an unsupported child: $name" }
            $repoId = [string]$Matches[1]
            $capture = Open-SealedRegistryJsonCapture -ParentHandle $canonicalRoot.Handle -Name $name -TokenSid $tokenSid -Label "canonical-roots/$name"
            $fileCaptures.Add($capture)
            $registryCleanupStack.Add([pscustomobject]@{Kind='HeldHandleCapture';Resource=$capture})
            $document = ConvertFrom-SealedRegistryJsonCapture -Capture $capture
            Assert-SealedRegistryCanonicalRootClaimContract -Document $document -ExpectedRepoId $repoId -AuthorityContext $AuthorityContext
            if (-not $repoIds.Add($repoId) -or -not $gitHashes.Add([string]$document.GitCommonDirHash)) { throw 'canonical-root-claim repository identity collision' }
            $intent = $document.CanonicalRecoveryRootIntent
            $expectedFinalDaclHash = if ([string]$intent.TargetStatus -ceq 'EXISTS') { [string]$intent.FinalDaclHash } else { $null }
            $actualRecovery = Open-SealedRegistryOpaqueDirectoryCapture -Path ([string]$document.CanonicalRecoveryRoot) -TokenSid $tokenSid -Label "canonical recovery root/$repoId" -ExpectedSecurityTemplateHash ([string]$document.SecurityTemplateHash) -ExpectedFinalDaclHash $expectedFinalDaclHash
            $externalRootCaptures.Add($actualRecovery)
            $registryCleanupStack.Add([pscustomobject]@{Kind='DirectoryCapture';Resource=$actualRecovery})
            if (-not ([string]$actualRecovery.Identity).StartsWith(([string]$intent.VolumeId + ':'),[StringComparison]::Ordinal)) { throw 'canonical-root-claim current recovery identity/volume mismatch' }
            if ([string]$intent.TargetStatus -ceq 'EXISTS' -and [string]$actualRecovery.Identity -cne [string]$intent.FinalDirectoryIdentity) { throw 'canonical-root-claim current recovery identity drift' }
            $setupStateStatus = 'UNRESOLVED'; $canonicalTransactionCoverage = 'CALLER_WITNESS_REQUIRED'
            $setupStateIdentity = $null; $setupStateLength = $null; $setupStateBytesHash = $null; $setupStateSemanticHash = $null
            $setupStateProjectionHash = $null; $setupStateRootClaimHash = $null; $setupStateSetupIntentHash = $null; $canonicalTransactionSetHash = $null
            if ($null -ne $entryCanonicalOutputEvidence -and
                [string][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetRepoIdExact($entryCanonicalOutputEvidence) -ceq $repoId) {
                if ($canonicalWitnessMatched -or
                    [string][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetGitCommonDirHashExact($entryCanonicalOutputEvidence) -cne [string]$document.GitCommonDirHash) { throw 'canonical-root-transition-not-supported' }
                $state = [AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetSetupStateDocumentExact($entryCanonicalOutputEvidence)
                if ($state -isnot [Collections.IDictionary]) { throw 'canonical-root-transition-not-supported' }
                $binding = Assert-SealedRegistryCanonicalSetupStateBinding -State $state -Claim $document -CanonicalEvidence $entryCanonicalOutputEvidence -AuthorityContext $AuthorityContext -RecoveryCapture $actualRecovery -ControlHandle ([AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetFinalParentExact($entryGlobalLockEvidence)) -BackupCapture $backupRoot
                $setupStateStatus = 'VALID'; $canonicalTransactionCoverage = 'WITNESSED'; $canonicalWitnessMatched = $true
                $setupStateIdentity = [string][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetSetupStateIdentityExact($entryCanonicalOutputEvidence)
                $setupStateLength = [long][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetSetupStateLengthExact($entryCanonicalOutputEvidence)
                $setupStateBytesHash = [string][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetSetupStateBytesHashExact($entryCanonicalOutputEvidence)
                $setupStateSemanticHash = [string][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetSetupStateSemanticHashExact($entryCanonicalOutputEvidence)
                $setupStateProjectionHash = [string]$binding.SetupStateProjectionHash; $setupStateRootClaimHash = [string]$binding.RootClaimHash; $setupStateSetupIntentHash = [string]$binding.SetupIntentHash
                $canonicalTransactionSetHash = [string][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetCanonicalTransactionSetHashExact($entryCanonicalOutputEvidence)
            }
            $canonicalRows.Add([pscustomobject][ordered]@{
                RepoId=$repoId; GitCommonDirHash=[string]$document.GitCommonDirHash; ClaimFileIdentity=[string]$capture.Identity
                ClaimBytesHash=[string]$capture.BytesHash; ClaimSecurityHash=[string]$capture.SecurityHash
                CanonicalRecoveryRoot=[string]$document.CanonicalRecoveryRoot; CanonicalRecoveryRootLocationKey=[string]$intent.LocationKey
                CanonicalRecoveryRootInitialIdentity=if([string]$intent.TargetStatus -ceq 'EXISTS'){[string]$intent.FinalDirectoryIdentity}else{$null}
                CanonicalRecoveryRootIdentity=[string]$actualRecovery.Identity; CanonicalRecoveryRootSecurityHash=[string]$actualRecovery.SecurityHash
                SetupStateStatus=$setupStateStatus; SetupStateFileIdentity=$setupStateIdentity; SetupStateLength=$setupStateLength
                SetupStateBytesHash=$setupStateBytesHash; SetupStateSemanticHash=$setupStateSemanticHash
                SetupStateProjectionHash=$setupStateProjectionHash; SetupStateRootClaimHash=$setupStateRootClaimHash; SetupStateSetupIntentHash=$setupStateSetupIntentHash
                CanonicalTransactionCoverage=$canonicalTransactionCoverage; CanonicalTransactionSetHash=$canonicalTransactionSetHash
            })
            $reservations.Add([pscustomobject][ordered]@{
                SourceKind='canonical-root-claim'; OwnerKey=$repoId; Role='CanonicalRecoveryRoot'; Platform=$null
                LocationKey=[string]$intent.LocationKey; RequestedPath=[string]$document.CanonicalRecoveryRoot; VolumeId=[string]$intent.VolumeId
                DirectoryIdentity=[string]$actualRecovery.Identity
                ParentLocationKey=[string](Get-AuthorityCanonicalPathProjection -Path ([string]$intent.DeepestExistingParentPath) -Role 'canonical claim parent' -AllowVolumeRoot).LocationKey
                ParentIdentity=[string]$intent.DeepestExistingParentIdentity
            })
        }
        if ($null -ne $CanonicalWitness -and -not $canonicalWitnessMatched) { throw 'canonical-root-transition-not-supported' }

        $authorityRows = [Collections.Generic.List[object]]::new()
        $repairOnly = [Collections.Generic.List[string]]::new()
        foreach ($authorityName in @($homesRoot.InitialNames)) {
            if ($authorityName -cnotmatch '\A[0-9a-f]{64}\z') { throw "homes contains an unsupported authority child: $authorityName" }
            $authority = Open-SealedRegistryHeldDirectoryChild -ParentHandle $homesRoot.Handle -Name $authorityName -TokenSid $tokenSid -Label "homes/$authorityName"
            $directoryChildren.Add($authority)
            $registryCleanupStack.Add([pscustomobject]@{Kind='HeldHandleCapture';Resource=$authority})
            $allowed = @('root-claims.json')
            if (@($authority.InitialNames) -contains 'current-env.json') { $allowed += 'current-env.json' }
            Compare-SealedRegistryNames -Expected $allowed -Actual @($authority.InitialNames) -Label "homes/$authorityName"
            $claimsCapture = Open-SealedRegistryJsonCapture -ParentHandle $authority.Handle -Name 'root-claims.json' -TokenSid $tokenSid -Label "homes/$authorityName/root-claims.json"
            $fileCaptures.Add($claimsCapture)
            $registryCleanupStack.Add([pscustomobject]@{Kind='HeldHandleCapture';Resource=$claimsCapture})
            $claims = ConvertFrom-SealedRegistryJsonCapture -Capture $claimsCapture
            Assert-SealedRegistryRootClaimsContract -Document $claims
            if ([string]$claims.HomeAuthorityKey -cne $authorityName) { throw 'root-claims authority directory/key mismatch' }
            if ([string]$claims.TokenSid -cne $tokenSid) { throw 'root-claims token SID does not belong to this ControlBase' }

            $stateStatus = 'MISSING'; $stateIdentity = $null; $stateLength = $null; $stateBytesHash = $null; $stateSecurityHash = $null; $finalTargetContextHash = $null
            $finalIdentityByPlatform = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            if (@($authority.InitialNames) -contains 'current-env.json') {
                $stateCapture = Open-SealedRegistryJsonCapture -ParentHandle $authority.Handle -Name 'current-env.json' -TokenSid $tokenSid -Label "homes/$authorityName/current-env.json"
                $fileCaptures.Add($stateCapture)
                $registryCleanupStack.Add([pscustomobject]@{Kind='HeldHandleCapture';Resource=$stateCapture})
                $stateIdentity = [string]$stateCapture.Identity; $stateLength = [long]$stateCapture.Length; $stateBytesHash = [string]$stateCapture.BytesHash; $stateSecurityHash = [string]$stateCapture.SecurityHash
                try {
                    $state = ConvertFrom-SealedRegistryJsonCapture -Capture $stateCapture
                    Assert-SealedRegistryCurrentEnvStateContract -Document $state -RootClaimsDocument $claims -RootClaimsBytes ([byte[]]$claimsCapture.Bytes)
                    $stateStatus = 'VALID'; $finalTargetContextHash = [string]$state.FinalTargetContextHash
                    foreach ($identity in @($state.FinalResolvedIdentities)) { $finalIdentityByPlatform.Add([string]$identity.Platform,[string]$identity.DirectoryIdentity) }
                }
                catch { $stateStatus = 'INVALID' }
            }
            if ($stateStatus -ne 'VALID') { $repairOnly.Add($authorityName) }
            $authorityRows.Add([pscustomobject][ordered]@{
                HomeAuthorityKey=$authorityName; AuthorityDirectoryIdentity=[string]$authority.Identity; AuthoritySecurityHash=[string]$authority.SecurityHash
                RootClaimsFileIdentity=[string]$claimsCapture.Identity; RootClaimsHash=[string]$claimsCapture.BytesHash; RootClaimsSecurityHash=[string]$claimsCapture.SecurityHash
                StateStatus=$stateStatus; StateFileIdentity=$stateIdentity; StateLength=$stateLength; StateBytesHash=$stateBytesHash; StateSecurityHash=$stateSecurityHash
                FinalTargetContextHash=$finalTargetContextHash
            })
            foreach ($claim in @($claims.LiveRootClaims)) {
                if ($stateStatus -ceq 'VALID') {
                    $directoryIdentity = [string]$finalIdentityByPlatform[[string]$claim.Platform]
                    if (-not $directoryIdentity.StartsWith(([string]$claim.VolumeId + ':'),[StringComparison]::Ordinal)) { throw "valid state live-root identity/volume mismatch: $authorityName/$($claim.Platform)" }
                    $liveCapture = Open-SealedRegistryIdentityDirectoryCapture -Path ([string]$claim.RequestedPath) -ExpectedIdentity $directoryIdentity -Label "live root/$authorityName/$($claim.Platform)"
                    $liveRootCaptures.Add($liveCapture)
                    $registryCleanupStack.Add([pscustomobject]@{Kind='DirectoryCapture';Resource=$liveCapture})
                }
                elseif ([string]$claim.InitialState -ceq 'EXISTS') { $directoryIdentity = [string]$claim.InitialDirectoryIdentity }
                else { $directoryIdentity = $null }
                $reservations.Add([pscustomobject][ordered]@{
                    SourceKind='home-root-claim'; OwnerKey=$authorityName; Role='LiveRoot'; Platform=[string]$claim.Platform
                    LocationKey=[string]$claim.LocationKey; RequestedPath=[string]$claim.RequestedPath; VolumeId=[string]$claim.VolumeId
                    DirectoryIdentity=$directoryIdentity
                    ParentLocationKey=[string](Get-AuthorityCanonicalPathProjection -Path ([string]$claim.DeepestExistingParentPath) -Role 'home claim parent' -AllowVolumeRoot).LocationKey
                    ParentIdentity=[string]$claim.DeepestExistingParentIdentity
                })
            }
        }

        $liveMarkers = [Collections.Generic.List[object]]::new()
        foreach ($name in @($liveRoot.InitialNames)) {
            if ($name -cnotmatch $script:SealedRegistryUuidPattern) { throw "live-transactions contains an unsupported child: $name" }
            $transaction = Open-SealedRegistryHeldDirectoryChild -ParentHandle $liveRoot.Handle -Name $name -TokenSid $tokenSid -Label "live-transactions/$name"
            $directoryChildren.Add($transaction)
            $registryCleanupStack.Add([pscustomobject]@{Kind='HeldHandleCapture';Resource=$transaction})
            $liveMarkers.Add([pscustomobject][ordered]@{
                TransactionId=$name; DirectoryIdentity=[string]$transaction.Identity; SecurityHash=[string]$transaction.SecurityHash
                ImmediateChildren=@($transaction.InitialNames); ContractStatus='UNRESOLVED_UNTIL_TASK_4'
            })
        }

        Assert-SealedRegistryReservationsDisjoint -Reservations @($reservations) -ForbiddenRoots @([string]$AuthorityContext.ControlBase,[string]$AuthorityContext.BackupRoot)
        if ($null -ne $CanonicalWitness) {
            $currentRouteCapture = Open-SealedRegistryCurrentRouteCapture -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness -CurrentRouteRootSet $CurrentRouteRootSet -Reservations @($reservations)
            $registryCleanupStack.Add([pscustomobject]@{Kind='CurrentRouteCapture';Resource=$currentRouteCapture})
            Assert-SealedRegistryCurrentRouteCaptureStable -Capture $currentRouteCapture
        }
        foreach ($capture in $fileCaptures) { Assert-SealedRegistryCaptureStable -Capture $capture -TokenSid $tokenSid }
        foreach ($capture in $directoryChildren) {
            Assert-SealedRegistryDirectoryCaptureStable -Capture $capture -TokenSid $tokenSid
            $finalNames = @(Get-SealedRegistryOrdinalStrings -Values @([AiAgentDotfiles.NoFollowFile]::GetChildNames($capture.Handle)))
            Compare-SealedRegistryNames -Expected @($capture.InitialNames) -Actual $finalNames -Label ([string]$capture.Label)
        }
        foreach ($capture in $externalRootCaptures) { Assert-SealedRegistryCanonicalDirectoryCaptureStable -Capture $capture -TokenSid $tokenSid }
        foreach ($capture in $liveRootCaptures) { Assert-SealedRegistryIdentityDirectoryCaptureStable -Capture $capture }
        foreach ($capture in $rootCaptures) {
            Assert-SealedRegistryDirectoryCaptureStable -Capture $capture -TokenSid $tokenSid
            $finalNames = @(Get-SealedRegistryOrdinalStrings -Values @([AiAgentDotfiles.NoFollowFile]::GetChildNames($capture.Handle)))
            Compare-SealedRegistryNames -Expected @($capture.InitialNames) -Actual $finalNames -Label ([string]$capture.Label)
        }
        $finalEnvelope = Get-SealedHomeAuthorityFixedEnvelopeProjection -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate -EnvelopeLease $fixedEnvelope -HeldGlobalLock $GlobalLockHandle
        if ([string]$finalEnvelope.EnvelopeHash -cne [string]$fixedEnvelope.InitialEnvelopeHash) { throw 'fixed envelope drift during registry capture' }
        if ($null -ne $currentRouteCapture) { Assert-SealedRegistryCurrentRouteCaptureStable -Capture $currentRouteCapture }
        if ($null -ne $CanonicalWitness) {
            $null = Assert-CanonicalHeldNamespaceWitness -Witness $CanonicalWitness -RepoRoot ([string][AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetRepoRootExact($entryCanonicalOutputEvidence)) -CanonicalLockHandle ([AiAgentDotfiles.SealedRegistryCanonicalOutputEvidence]::GetCanonicalLockHandleExact($entryCanonicalOutputEvidence))
            $null = Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness
        }
        $finalGlobalLockEvidence = Assert-SealedHomeAuthorityGlobalLockWitness -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle
        if (-not [AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::MatchesExact($entryGlobalLockEvidence,$finalGlobalLockEvidence)) { throw 'home-authority-registry-lock-required' }

        $blockers = [Collections.Generic.List[string]]::new()
        if ($liveMarkers.Count -gt 0) { $blockers.Add('LIVE_TRANSACTION_CONTRACT_UNRESOLVED') }
        $unresolvedCanonicalCount = @($canonicalRows | Where-Object { [string]$_.SetupStateStatus -cne 'VALID' }).Count
        if ($unresolvedCanonicalCount -gt 0) { $blockers.Add('CANONICAL_WITNESS_REQUIRED') }
        if ($repairOnly.Count -gt 0) { $blockers.Add('REPAIR_ADOPT_ONLY') }
        $gate = if ($liveMarkers.Count -gt 0) { 'RECOVERY_REQUIRED' } elseif ($unresolvedCanonicalCount -gt 0) { 'CANONICAL_WITNESS_REQUIRED' } elseif ($repairOnly.Count -gt 0) { 'REPAIR_ADOPT_ONLY' } else { 'READY' }
        $projection = [ordered]@{
            SchemaVersion=1L; ArtifactKind=$script:SealedRegistryArtifactKind; ResolverVersion=$script:SealedRegistryResolverVersion
            TokenSid=$tokenSid; ControlBaseIdentity=[string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetControlBaseIdentityExact($finalGlobalLockEvidence)
            GlobalLiveLockIdentity=[string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetLockIdentityExact($finalGlobalLockEvidence); FixedEnvelopeHash=[string]$fixedEnvelope.InitialEnvelopeHash
            CanonicalClaims=@($canonicalRows); Authorities=@($authorityRows); LiveTransactionMarkers=@($liveMarkers)
            RootReservations=@(Get-SealedRegistryOrderedReservations -Reservations @($reservations))
            RepairOnlyAuthorities=@(Get-SealedRegistryOrdinalStrings -Values @($repairOnly)); MutationGate=$gate; MutationBlockers=@($blockers)
            CanonicalNamespaceCoverage=if($canonicalRows.Count -eq 0){'NO_CLAIMS'}elseif($unresolvedCanonicalCount -eq 0){'CURRENT_ROUTE_WITNESSED'}else{'CALLER_WITNESS_REQUIRED'}
            LiveTransactionCoverage=if($liveMarkers.Count -eq 0){'EMPTY'}else{'UNRESOLVED_UNTIL_TASK_4'}
            CurrentRouteCoverage=if($null -eq $currentRouteCapture){'NOT_REQUESTED'}else{'HELD_METADATA_VERIFIED'}
            CurrentRouteRootSetHash=if($null -eq $currentRouteCapture){$null}else{[string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetEntryCurrentRouteRootSetHash($currentRouteCapture)}
            HeldTargetSetHash=if($null -eq $currentRouteCapture){$null}else{[string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetHeldTargetSetHash($currentRouteCapture)}
            FilesystemCapabilityCoverage=if($null -eq $currentRouteCapture){'NOT_REQUESTED'}else{'UNPROBED_READ_ONLY'}
        }
        $registryHash = Get-SemanticJsonHash -InputObject $projection
        $result = [ordered]@{}
        foreach ($key in $projection.Keys) { $result[$key]=$projection[$key] }
        $result.RegistryHash=$registryHash
        return [pscustomobject]$result
    }
    catch {
        $registryPrimaryError = $_
        if ($_.Exception.Message -in @('home-authority-registry-lock-required','canonical-witness-required','route-witness-required')) { throw }
        if ($_.Exception.Message -like 'home-authority-registry-manual-recovery-required:*') { throw }
        throw "home-authority-registry-manual-recovery-required: $($_.Exception.Message)"
    }
    finally {
        $registryCleanupError = $null
        for ($index=$registryCleanupStack.Count-1; $index -ge 0; $index--) {
            $cleanup = $registryCleanupStack[$index]
            try {
                switch ([string]$cleanup.Kind) {
                    'CurrentRouteCapture' { Close-SealedRegistryCurrentRouteCapture -Capture $cleanup.Resource; break }
                    'HeldHandleCapture' { if ($null -ne $cleanup.Resource.Handle) { $cleanup.Resource.Handle.Dispose() }; break }
                    'DirectoryCapture' { Close-SealedRegistryDirectoryCapture -Capture $cleanup.Resource; break }
                    'FixedEnvelope' { Close-SealedHomeAuthorityFixedEnvelope -EnvelopeLease $cleanup.Resource; break }
                    default { throw 'registry cleanup stack contains an unsupported resource kind' }
                }
            }
            catch { if ($null -eq $registryCleanupError) { $registryCleanupError = $_ } }
        }
        if ($null -eq $registryPrimaryError -and $null -ne $registryCleanupError) { throw $registryCleanupError }
    }
}

if (-not ('AiAgentDotfiles.SealedCapabilityPreflightEvidence' -as [type])) {
    Add-Type -TypeDefinition @'
using System;

namespace AiAgentDotfiles {
    public sealed class SealedCapabilityPreflightRow {
        private readonly string requestedPath;
        private readonly string locationKey;
        private readonly string targetStatus;
        private readonly string probeRootPath;
        private readonly string probeRootLocationKey;
        private readonly string probeRootIdentity;
        private readonly string driveType;
        private readonly string fileSystemType;
        private readonly string volumeSerial;
        private readonly string filesystemCapabilityHash;
        private readonly string expectedCapabilityHash;
        private readonly bool? verifiedAgainstExpected;

        private SealedCapabilityPreflightRow(string requestedPathValue, string locationKeyValue, string targetStatusValue,
            string probeRootPathValue, string probeRootLocationKeyValue, string probeRootIdentityValue,
            string driveTypeValue, string fileSystemTypeValue, string volumeSerialValue,
            string filesystemCapabilityHashValue, string expectedCapabilityHashValue, bool? verifiedAgainstExpectedValue) {
            requestedPath = requestedPathValue;
            locationKey = locationKeyValue;
            targetStatus = targetStatusValue;
            probeRootPath = probeRootPathValue;
            probeRootLocationKey = probeRootLocationKeyValue;
            probeRootIdentity = probeRootIdentityValue;
            driveType = driveTypeValue;
            fileSystemType = fileSystemTypeValue;
            volumeSerial = volumeSerialValue;
            filesystemCapabilityHash = filesystemCapabilityHashValue;
            expectedCapabilityHash = expectedCapabilityHashValue;
            verifiedAgainstExpected = verifiedAgainstExpectedValue;
        }

        public static SealedCapabilityPreflightRow CreateExact(string requestedPathValue, string locationKeyValue,
            string targetStatusValue, string probeRootPathValue, string probeRootLocationKeyValue, string probeRootIdentityValue,
            string driveTypeValue, string fileSystemTypeValue, string volumeSerialValue,
            string filesystemCapabilityHashValue, string expectedCapabilityHashValue, bool? verifiedAgainstExpectedValue) {
            if (String.IsNullOrEmpty(requestedPathValue) || String.IsNullOrEmpty(locationKeyValue) ||
                String.IsNullOrEmpty(targetStatusValue) || String.IsNullOrEmpty(probeRootPathValue) ||
                String.IsNullOrEmpty(probeRootLocationKeyValue) || String.IsNullOrEmpty(probeRootIdentityValue) ||
                String.IsNullOrEmpty(driveTypeValue) ||
                String.IsNullOrEmpty(fileSystemTypeValue) || String.IsNullOrEmpty(volumeSerialValue) ||
                String.IsNullOrEmpty(filesystemCapabilityHashValue) || filesystemCapabilityHashValue.Length != 64) {
                throw new InvalidOperationException("capability-preflight-evidence-invalid");
            }
            bool? verifiedValue = verifiedAgainstExpectedValue;
            if (expectedCapabilityHashValue == null || expectedCapabilityHashValue.Length == 0) {
                expectedCapabilityHashValue = null;
                verifiedValue = null;
            }
            else {
                if (expectedCapabilityHashValue.Length != 64 || !verifiedValue.HasValue) {
                    throw new InvalidOperationException("capability-preflight-evidence-invalid");
                }
            }
            return new SealedCapabilityPreflightRow(requestedPathValue, locationKeyValue, targetStatusValue,
                probeRootPathValue, probeRootLocationKeyValue, probeRootIdentityValue, driveTypeValue, fileSystemTypeValue,
                volumeSerialValue, filesystemCapabilityHashValue,
                expectedCapabilityHashValue, verifiedValue);
        }

        public static string GetRequestedPathExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.requestedPath; }
        public static string GetLocationKeyExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.locationKey; }
        public static string GetTargetStatusExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.targetStatus; }
        public static string GetProbeRootPathExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.probeRootPath; }
        public static string GetProbeRootLocationKeyExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.probeRootLocationKey; }
        public static string GetProbeRootIdentityExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.probeRootIdentity; }
        public static string GetDriveTypeExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.driveType; }
        public static string GetFileSystemTypeExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.fileSystemType; }
        public static string GetVolumeSerialExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.volumeSerial; }
        public static string GetFilesystemCapabilityHashExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.filesystemCapabilityHash; }
        public static string GetExpectedCapabilityHashExact(SealedCapabilityPreflightRow value) { return value == null ? null : value.expectedCapabilityHash; }
        public static bool? GetVerifiedAgainstExpectedExact(SealedCapabilityPreflightRow value) { return value == null ? (bool?)null : value.verifiedAgainstExpected; }
    }

    public sealed class SealedCapabilityPreflightEvidence {
        private readonly string authorityContextHash;
        private readonly string fixedEnvelopeHash;
        private readonly string lockSecurityHash;
        private readonly SealedCapabilityPreflightRow[] rows;
        private readonly string projectionHash;

        private SealedCapabilityPreflightEvidence(string authorityContextHashValue, string fixedEnvelopeHashValue,
            string lockSecurityHashValue, SealedCapabilityPreflightRow[] rowsValue, string projectionHashValue) {
            authorityContextHash = authorityContextHashValue;
            fixedEnvelopeHash = fixedEnvelopeHashValue;
            lockSecurityHash = lockSecurityHashValue;
            rows = (SealedCapabilityPreflightRow[])rowsValue.Clone();
            projectionHash = projectionHashValue;
        }

        public static SealedCapabilityPreflightEvidence CreateExact(string authorityContextHashValue,
            string fixedEnvelopeHashValue, string lockSecurityHashValue, SealedCapabilityPreflightRow[] rowsValue,
            string projectionHashValue) {
            if (String.IsNullOrEmpty(authorityContextHashValue) || authorityContextHashValue.Length != 64 ||
                String.IsNullOrEmpty(fixedEnvelopeHashValue) || fixedEnvelopeHashValue.Length != 64 ||
                String.IsNullOrEmpty(lockSecurityHashValue) || lockSecurityHashValue.Length != 64 ||
                rowsValue == null || rowsValue.Length == 0 ||
                String.IsNullOrEmpty(projectionHashValue) || projectionHashValue.Length != 64) {
                throw new InvalidOperationException("capability-preflight-evidence-invalid");
            }
            foreach (SealedCapabilityPreflightRow row in rowsValue) {
                if (row == null) { throw new InvalidOperationException("capability-preflight-evidence-invalid"); }
            }
            return new SealedCapabilityPreflightEvidence(authorityContextHashValue, fixedEnvelopeHashValue,
                lockSecurityHashValue, rowsValue, projectionHashValue);
        }

        public static string GetAuthorityContextHashExact(SealedCapabilityPreflightEvidence value) { return value == null ? null : value.authorityContextHash; }
        public static string GetFixedEnvelopeHashExact(SealedCapabilityPreflightEvidence value) { return value == null ? null : value.fixedEnvelopeHash; }
        public static string GetLockSecurityHashExact(SealedCapabilityPreflightEvidence value) { return value == null ? null : value.lockSecurityHash; }
        public static int GetRowCountExact(SealedCapabilityPreflightEvidence value) { return value == null ? 0 : value.rows.Length; }
        public static SealedCapabilityPreflightRow GetRowExact(SealedCapabilityPreflightEvidence value, int index) {
            if (value == null || index < 0 || index >= value.rows.Length) { throw new ArgumentOutOfRangeException("index"); }
            return value.rows[index];
        }
        public static SealedCapabilityPreflightRow[] GetRowsExact(SealedCapabilityPreflightEvidence value) { return value == null ? null : (SealedCapabilityPreflightRow[])value.rows.Clone(); }
        public static string GetProjectionHashExact(SealedCapabilityPreflightEvidence value) { return value == null ? null : value.projectionHash; }
    }
}
'@
}

function Get-SealedCapabilityPreflightRowProjection {
    param([Parameter(Mandatory)][AiAgentDotfiles.SealedCapabilityPreflightRow]$Row)
    return [ordered]@{
        RequestedPath=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetRequestedPathExact($Row)
        LocationKey=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($Row)
        TargetStatus=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetTargetStatusExact($Row)
        ProbeRootPath=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootPathExact($Row)
        ProbeRootLocationKey=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootLocationKeyExact($Row)
        ProbeRootIdentity=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootIdentityExact($Row)
        DriveType=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetDriveTypeExact($Row)
        FileSystemType=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFileSystemTypeExact($Row)
        VolumeSerial=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVolumeSerialExact($Row)
        FilesystemCapabilityHash=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($Row)
        ExpectedCapabilityHash=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetExpectedCapabilityHashExact($Row)
        VerifiedAgainstExpected=[AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVerifiedAgainstExpectedExact($Row)
    }
}

function Get-SealedCapabilityPreflightProjectionHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AiAgentDotfiles.SealedCapabilityPreflightEvidence]$Evidence)
    $rowCount = [int][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowCountExact($Evidence)
    $rows = for ($index = 0; $index -lt $rowCount; $index++) {
        Get-SealedCapabilityPreflightRowProjection -Row ([AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowExact($Evidence,$index))
    }
    return Get-SemanticJsonHash -InputObject ([ordered]@{
        AuthorityContextHash=[string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetAuthorityContextHashExact($Evidence)
        FixedEnvelopeHash=[string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetFixedEnvelopeHashExact($Evidence)
        LockSecurityHash=[string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetLockSecurityHashExact($Evidence)
        Rows=@($rows)
    })
}

function Throw-SealedFixedInfrastructureCapabilityIssuerException {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Exception]$Exception)

    $domainException=$Exception
    while(($domainException -is [System.Management.Automation.MethodInvocationException] -or
        $domainException -is [System.Management.Automation.RuntimeException]) -and
        $null -ne $domainException.InnerException){
        $domainException=$domainException.InnerException
        if($domainException -is [AggregateException]){break}
    }
    throw $domainException
}

if (-not ('AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.ObjectModel;
using System.Management.Automation;

namespace AiAgentDotfiles {
    public static class SealedFixedInfrastructureCapabilityIssuer {
        private static readonly object Gate = new object();
        private static readonly object ExactIssuerToken = new object();
        private static ScriptBlock rawPreflight;
        private static ScriptBlock capabilityProbe;
        private static string rawPreflightText;
        private static string capabilityProbeText;

        private static string GetExactText(ScriptBlock value) {
            return value == null || value.Ast == null || value.Ast.Extent == null ? null : value.Ast.Extent.Text;
        }

        private static bool MatchesExactDefinition(ScriptBlock candidate, ScriptBlock canonical, string canonicalText) {
            if (candidate == null || canonical == null || canonicalText == null) return false;
            if (Object.ReferenceEquals(candidate, canonical)) return true;
            return String.Equals(GetExactText(candidate), canonicalText, StringComparison.Ordinal);
        }

        public static void InitializeExact(ScriptBlock rawPreflightValue, ScriptBlock capabilityProbeValue) {
            if (rawPreflightValue == null || capabilityProbeValue == null)
                throw new InvalidOperationException("fixed-infrastructure-capability-evidence-invalid");
            lock (Gate) {
                if (rawPreflight == null && capabilityProbe == null) {
                    rawPreflight = rawPreflightValue;
                    capabilityProbe = capabilityProbeValue;
                    rawPreflightText = GetExactText(rawPreflightValue);
                    capabilityProbeText = GetExactText(capabilityProbeValue);
                    return;
                }
                if (!MatchesExactDefinition(rawPreflightValue, rawPreflight, rawPreflightText) ||
                    !MatchesExactDefinition(capabilityProbeValue, capabilityProbe, capabilityProbeText))
                    throw new InvalidOperationException("fixed-infrastructure-capability-evidence-invalid");
            }
        }

        public static bool MatchesRawExact(ScriptBlock candidate) {
            lock (Gate) { return MatchesExactDefinition(candidate, rawPreflight, rawPreflightText); }
        }

        public static bool MatchesProbeExact(ScriptBlock candidate) {
            lock (Gate) { return MatchesExactDefinition(candidate, capabilityProbe, capabilityProbeText); }
        }

        public static bool IsExactIssuerToken(object candidate) {
            return Object.ReferenceEquals(ExactIssuerToken, candidate);
        }

        private static object InvokeSingleExact(ScriptBlock command, object[] arguments) {
            if (command == null)
                throw new InvalidOperationException("fixed-infrastructure-capability-evidence-invalid");
            Collection<PSObject> output = command.Invoke(arguments);
            if (output == null || output.Count != 1 || output[0] == null)
                throw new InvalidOperationException("fixed-infrastructure-capability-evidence-invalid");
            return output[0].BaseObject;
        }

        public static object InvokeRawExact(object authorityContext, object globalLockHandle,
            object canonicalWitness, object[] capabilityTargets) {
            ScriptBlock command;
            lock (Gate) { command = rawPreflight; }
            return InvokeSingleExact(command, new object[] {
                authorityContext, globalLockHandle, canonicalWitness, capabilityTargets, ExactIssuerToken
            });
        }

        public static object InvokeProbeExact(object issuerToken, string probeRoot, object volumeInfo,
            string expectedProbeRootIdentity) {
            if (!Object.ReferenceEquals(ExactIssuerToken, issuerToken))
                throw new InvalidOperationException("fixed-infrastructure-capability-evidence-invalid");
            ScriptBlock command;
            lock (Gate) { command = capabilityProbe; }
            return InvokeSingleExact(command, new object[] { probeRoot, volumeInfo, expectedProbeRootIdentity });
        }
    }
}
'@
}

function Invoke-SealedHeldCapabilityPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)][AllowNull()]$GlobalLockHandle,
        [AllowNull()]$CanonicalWitness,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$CapabilityTargets,
        [Parameter(DontShow)][AllowNull()]$FixedInfrastructureExactIssuerToken
    )

    $useFixedInfrastructureExactIssuer = $null -ne $FixedInfrastructureExactIssuerToken
    if ($useFixedInfrastructureExactIssuer) {
        if (-not [AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer]::IsExactIssuerToken($FixedInfrastructureExactIssuerToken)) {
            throw 'fixed-infrastructure-capability-evidence-invalid'
        }
        $currentCapabilityProbe = $ExecutionContext.SessionState.InvokeCommand.GetCommand(
            'Invoke-TargetFilesystemCapabilityProbe',[System.Management.Automation.CommandTypes]::Function)
        if ($null -eq $currentCapabilityProbe -or
            -not [AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer]::MatchesProbeExact($currentCapabilityProbe.ScriptBlock)) {
            throw 'fixed-infrastructure-capability-evidence-invalid'
        }
    }

    if (@($CapabilityTargets).Count -eq 0) { throw 'capability-preflight-target-required' }
    $lockEvidence = Assert-SealedHomeAuthorityGlobalLockWitness -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle
    if ($null -ne $CanonicalWitness) {
        $null = Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness
    }

    $bindingsByTarget = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $probeRootsByLocation = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $targetLocationsByIdentity = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $probeLocationsByIdentity = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($target in @($CapabilityTargets)) {
        if ($null -eq $target) { throw 'capability-preflight-target-required' }
        $targetShape = @(Get-SealedRegistryOrdinalStrings -Values @(Get-SealedRegistryPropertyNames -InputObject $target))
        $shapeText = $targetShape -join "`0"
        $baseShapeText = [string[]]@('Path','ProbeRoot') -join "`0"
        $expectedShapeText = [string[]]@('ExpectedFilesystemCapabilityHash','Path','ProbeRoot') -join "`0"
        if ($shapeText -cne $baseShapeText -and $shapeText -cne $expectedShapeText) { throw 'capability-preflight-target-contract-invalid' }
        $targetPathRaw = Get-SealedRegistryObjectValue -InputObject $target -Name 'Path'
        $probeRootRaw = Get-SealedRegistryObjectValue -InputObject $target -Name 'ProbeRoot'
        if ($targetPathRaw -isnot [string] -or $probeRootRaw -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$targetPathRaw) -or [string]::IsNullOrWhiteSpace([string]$probeRootRaw)) {
            throw 'capability-preflight-target-contract-invalid'
        }
        $hasExpected = $shapeText -ceq $expectedShapeText
        $expectedValue = if ($hasExpected) { Get-SealedRegistryObjectValue -InputObject $target -Name 'ExpectedFilesystemCapabilityHash' } else { $null }
        if ($hasExpected) { Assert-SealedRegistryString $expectedValue 'capability preflight expected hash' -Pattern $script:SealedRegistryHashPattern }

        $metadata = Resolve-TargetContext -Path ([string]$targetPathRaw) -Mode MetadataOnly
        $targetLocationKey = [string]$metadata.LocationKey
        if ($bindingsByTarget.ContainsKey($targetLocationKey)) { throw 'capability-preflight-target-duplicate' }
        if ([string]$metadata.TargetStatus -ceq 'EXISTS') {
            if ([string]$metadata.TargetType -cne 'Directory') { throw 'capability-preflight-target-contract-invalid' }
            $targetIdentity = [string]$metadata.DeepestExistingParentIdentity
            if ($targetLocationsByIdentity.ContainsKey($targetIdentity) -and
                [string]$targetLocationsByIdentity[$targetIdentity] -cne $targetLocationKey) { throw 'capability-preflight-target-duplicate' }
            $targetLocationsByIdentity[$targetIdentity] = $targetLocationKey
        }
        $targetVolumeInfo = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo([string]$metadata.DeepestExistingParentPath)
        if ([string]$targetVolumeInfo.VolumeSerial -cne [string]$metadata.VolumeId) { throw 'capability-target-volume-drift' }
        Assert-SupportedTargetFilesystem -DriveType ([string]$targetVolumeInfo.DriveType) -FileSystemType ([string]$targetVolumeInfo.FileSystemType)

        $probeMetadata = $null
        try {
            if (-not [System.IO.Path]::IsPathFullyQualified([string]$probeRootRaw) -or ([string]$probeRootRaw).StartsWith('\',[StringComparison]::Ordinal)) {
                throw 'invalid'
            }
            $probeRootFull = [System.IO.Path]::GetFullPath([string]$probeRootRaw).TrimEnd([char]92,[char]47)
            if ([string]::IsNullOrWhiteSpace($probeRootFull) -or [System.IO.Path]::GetPathRoot($probeRootFull) -ceq $probeRootFull) { throw 'invalid' }
            $probeMetadata = Resolve-TargetContext -Path $probeRootFull -Mode MetadataOnly
            if ([string]$probeMetadata.TargetStatus -cne 'EXISTS' -or [string]$probeMetadata.TargetType -cne 'Directory') { throw 'invalid' }
        }
        catch { throw 'capability-probe-root-invalid' }
        $probeVolumeInfo = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo([string]$probeMetadata.DeepestExistingParentPath)
        if ([string]$probeVolumeInfo.VolumeSerial -cne [string]$probeMetadata.VolumeId) { throw 'capability-probe-root-invalid' }
        Assert-SupportedTargetFilesystem -DriveType ([string]$probeVolumeInfo.DriveType) -FileSystemType ([string]$probeVolumeInfo.FileSystemType)
        if ([string]$probeVolumeInfo.VolumeSerial -cne [string]$targetVolumeInfo.VolumeSerial) { throw 'capability-probe-target-volume-mismatch' }

        $probeLocationKey = [string]$probeMetadata.LocationKey
        $probeIdentity = [string]$probeMetadata.DeepestExistingParentIdentity
        if ($probeLocationsByIdentity.ContainsKey($probeIdentity) -and
            [string]$probeLocationsByIdentity[$probeIdentity] -cne $probeLocationKey) { throw 'capability-probe-root-invalid' }
        if (-not $probeRootsByLocation.ContainsKey($probeLocationKey)) {
            $probeRootsByLocation.Add($probeLocationKey,[pscustomobject][ordered]@{
                Path=[string]$probeMetadata.RequestedPath
                LocationKey=$probeLocationKey
                Identity=$probeIdentity
                VolumeInfo=$probeVolumeInfo
                Metadata=$probeMetadata
            })
            $probeLocationsByIdentity[$probeIdentity] = $probeLocationKey
        }
        elseif ([string]$probeRootsByLocation[$probeLocationKey].Identity -cne $probeIdentity -or
            [string]$probeRootsByLocation[$probeLocationKey].VolumeInfo.VolumeSerial -cne [string]$probeVolumeInfo.VolumeSerial -or
            [string]$probeRootsByLocation[$probeLocationKey].VolumeInfo.DriveType -cne [string]$probeVolumeInfo.DriveType -or
            [string]$probeRootsByLocation[$probeLocationKey].VolumeInfo.FileSystemType -cne [string]$probeVolumeInfo.FileSystemType) {
            throw 'capability-probe-root-invalid'
        }
        $bindingsByTarget.Add($targetLocationKey,[pscustomobject][ordered]@{
            Metadata=$metadata
            TargetVolumeInfo=$targetVolumeInfo
            ProbeRootPath=[string]$probeMetadata.RequestedPath
            ProbeRootLocationKey=$probeLocationKey
            ProbeRootIdentity=$probeIdentity
            ExpectedCapabilityHash=if($hasExpected){[string]$expectedValue}else{$null}
        })
    }

    $probeRootRows = @($probeRootsByLocation.Values)
    $bindingRows = @($bindingsByTarget.Values)
    for ($leftIndex=0; $leftIndex -lt $bindingRows.Count; $leftIndex++) {
        for ($rightIndex=$leftIndex+1; $rightIndex -lt $bindingRows.Count; $rightIndex++) {
            if (Test-SealedRegistryTargetContextsOverlap -Left $bindingRows[$leftIndex].Metadata -Right $bindingRows[$rightIndex].Metadata) {
                throw 'capability-preflight-target-duplicate'
            }
        }
    }
    $reservedRootContexts = [Collections.Generic.List[object]]::new()
    foreach ($reservedRoot in @([string]$AuthorityContext.ControlBase,[string]$AuthorityContext.BackupRoot,[string]$AuthorityContext.PrivateRootBase)) {
        if (-not [string]::IsNullOrWhiteSpace($reservedRoot)) {
            $reservedRootContexts.Add((Resolve-TargetContext -Path ([System.IO.Path]::GetFullPath($reservedRoot)) -Mode MetadataOnly))
        }
    }
    foreach ($probeRootRow in $probeRootRows) {
        foreach ($reservedRootContext in $reservedRootContexts) {
            if (Test-SealedRegistryTargetContextsOverlap -Left $probeRootRow.Metadata -Right $reservedRootContext) {
                throw 'capability-probe-root-forbidden-overlap'
            }
        }
        foreach ($binding in $bindingRows) {
            if (Test-SealedRegistryTargetContextsOverlap -Left $probeRootRow.Metadata -Right $binding.Metadata) {
                throw 'capability-probe-root-forbidden-overlap'
            }
        }
    }
    for ($leftIndex=0; $leftIndex -lt $probeRootRows.Count; $leftIndex++) {
        for ($rightIndex=$leftIndex+1; $rightIndex -lt $probeRootRows.Count; $rightIndex++) {
            if (Test-SealedRegistryTargetContextsOverlap -Left $probeRootRows[$leftIndex].Metadata -Right $probeRootRows[$rightIndex].Metadata) {
                throw 'capability-probe-root-forbidden-overlap'
            }
        }
    }
    # Only the lower-level probe owns its exact GUID slot. Any matching entry observed by this
    # layer may be foreign concurrent evidence, so validation fails closed without deleting it.
    foreach ($probeRootRow in $probeRootRows) {
        if (@([System.IO.Directory]::EnumerateFileSystemEntries([string]$probeRootRow.Path,'.target-capability-*')).Count -gt 0) {
            throw 'capability-probe-root-residue'
        }
    }

    $rows = [Collections.Generic.List[AiAgentDotfiles.SealedCapabilityPreflightRow]]::new()
    foreach ($binding in $bindingRows) {
        $metadata = $binding.Metadata
        $volumeInfo = $binding.TargetVolumeInfo
        $expectedValue = $binding.ExpectedCapabilityHash
        $capabilityHash = if ($useFixedInfrastructureExactIssuer) {
            try {
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer]::InvokeProbeExact(
                    $FixedInfrastructureExactIssuerToken,[string]$binding.ProbeRootPath,$volumeInfo,[string]$binding.ProbeRootIdentity)
            }
            catch {
                Throw-SealedFixedInfrastructureCapabilityIssuerException -Exception $_.Exception
            }
        }
        else {
            Invoke-TargetFilesystemCapabilityProbe -ProbeRoot ([string]$binding.ProbeRootPath) -VolumeInfo $volumeInfo -ExpectedProbeRootIdentity ([string]$binding.ProbeRootIdentity)
        }

        $verified = $null
        if ($null -ne $expectedValue) {
            $verified = ([string]$expectedValue -ceq [string]$capabilityHash)
            if (-not $verified) { throw 'capability-evidence-mismatch' }
        }
        $expectedForEvidence = if ($null -eq $expectedValue) { $null } else { [string]$expectedValue }
        $rows.Add([AiAgentDotfiles.SealedCapabilityPreflightRow]::CreateExact(
            [string]$metadata.RequestedPath,[string]$metadata.LocationKey,[string]$metadata.TargetStatus,
            [string]$binding.ProbeRootPath,[string]$binding.ProbeRootLocationKey,[string]$binding.ProbeRootIdentity,
            [string]$volumeInfo.DriveType,[string]$volumeInfo.FileSystemType,[string]$volumeInfo.VolumeSerial,
            [string]$capabilityHash,$expectedForEvidence,$verified))
    }
    foreach ($probeRootRow in $probeRootRows) {
        $postProbeMetadata = $null
        try {
            $postProbeMetadata = Resolve-TargetContext -Path ([string]$probeRootRow.Path) -Mode MetadataOnly
            if ([string]$postProbeMetadata.TargetStatus -cne 'EXISTS' -or [string]$postProbeMetadata.TargetType -cne 'Directory' -or
                [string]$postProbeMetadata.LocationKey -cne [string]$probeRootRow.LocationKey -or
                [string]$postProbeMetadata.DeepestExistingParentIdentity -cne [string]$probeRootRow.Identity -or
                [string]$postProbeMetadata.VolumeId -cne [string]$probeRootRow.VolumeInfo.VolumeSerial) { throw 'invalid' }
        }
        catch { throw 'capability-probe-root-stale' }
        if (@([System.IO.Directory]::EnumerateFileSystemEntries([string]$probeRootRow.Path,'.target-capability-*')).Count -gt 0) {
            throw 'capability-probe-root-residue'
        }
    }

    $rowArray = [AiAgentDotfiles.SealedCapabilityPreflightRow[]]::new($rows.Count)
    $rows.CopyTo($rowArray)
    $rowProjections = for ($index = 0; $index -lt $rowArray.Length; $index++) {
        Get-SealedCapabilityPreflightRowProjection -Row $rowArray[$index]
    }
    $authorityContextHash = Get-SemanticJsonHash -InputObject $AuthorityContext
    $projectionHash = Get-SemanticJsonHash -InputObject ([ordered]@{
        AuthorityContextHash=[string]$authorityContextHash
        FixedEnvelopeHash=[string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetFixedEnvelopeHashExact($lockEvidence)
        LockSecurityHash=[string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetLockSecurityHashExact($lockEvidence)
        Rows=@($rowProjections)
    })
    return [AiAgentDotfiles.SealedCapabilityPreflightEvidence]::CreateExact(
        [string]$authorityContextHash,
        [string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetFixedEnvelopeHashExact($lockEvidence),
        [string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetLockSecurityHashExact($lockEvidence),
        $rowArray,[string]$projectionHash)
}

$sealedFixedInfrastructureRawCommand = $ExecutionContext.SessionState.InvokeCommand.GetCommand(
    'Invoke-SealedHeldCapabilityPreflight',[System.Management.Automation.CommandTypes]::Function)
$sealedFixedInfrastructureProbeCommand = $ExecutionContext.SessionState.InvokeCommand.GetCommand(
    'Invoke-TargetFilesystemCapabilityProbe',[System.Management.Automation.CommandTypes]::Function)
if ($null -eq $sealedFixedInfrastructureRawCommand -or $null -eq $sealedFixedInfrastructureProbeCommand) {
    throw 'fixed-infrastructure-capability-evidence-invalid'
}
[AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer]::InitializeExact(
    $sealedFixedInfrastructureRawCommand.ScriptBlock,$sealedFixedInfrastructureProbeCommand.ScriptBlock)

if (-not ('AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence' -as [type])) {
    Add-Type -TypeDefinition @'
using System;

namespace AiAgentDotfiles {
    public sealed class SealedFixedInfrastructureCapabilityRoleRow {
        private readonly string role;
        private readonly string requestedPath;
        private readonly string locationKey;
        private readonly string targetStatus;
        private readonly string probeRootPath;
        private readonly string probeRootLocationKey;
        private readonly string probeRootIdentity;
        private readonly string driveType;
        private readonly string fileSystemType;
        private readonly string volumeSerial;
        private readonly string filesystemCapabilityHash;
        private readonly string expectedCapabilityHash;
        private readonly bool? verifiedAgainstExpected;

        private SealedFixedInfrastructureCapabilityRoleRow(string roleValue, string requestedPathValue,
            string locationKeyValue, string targetStatusValue, string probeRootPathValue,
            string probeRootLocationKeyValue, string probeRootIdentityValue, string driveTypeValue,
            string fileSystemTypeValue, string volumeSerialValue, string filesystemCapabilityHashValue,
            string expectedCapabilityHashValue, bool? verifiedAgainstExpectedValue) {
            role = roleValue;
            requestedPath = requestedPathValue;
            locationKey = locationKeyValue;
            targetStatus = targetStatusValue;
            probeRootPath = probeRootPathValue;
            probeRootLocationKey = probeRootLocationKeyValue;
            probeRootIdentity = probeRootIdentityValue;
            driveType = driveTypeValue;
            fileSystemType = fileSystemTypeValue;
            volumeSerial = volumeSerialValue;
            filesystemCapabilityHash = filesystemCapabilityHashValue;
            expectedCapabilityHash = expectedCapabilityHashValue;
            verifiedAgainstExpected = verifiedAgainstExpectedValue;
        }

        private static bool IsLowerHex64(string value) {
            if (value == null || value.Length != 64) return false;
            for (int index = 0; index < value.Length; index++) {
                char current = value[index];
                if (!((current >= '0' && current <= '9') || (current >= 'a' && current <= 'f'))) return false;
            }
            return true;
        }

        public static SealedFixedInfrastructureCapabilityRoleRow CreateExact(string roleValue,
            string requestedPathValue, string locationKeyValue, string targetStatusValue,
            string probeRootPathValue, string probeRootLocationKeyValue, string probeRootIdentityValue,
            string driveTypeValue, string fileSystemTypeValue, string volumeSerialValue,
            string filesystemCapabilityHashValue, string expectedCapabilityHashValue,
            bool? verifiedAgainstExpectedValue) {
            if (!(String.Equals(roleValue,"ControlBase",StringComparison.Ordinal) ||
                    String.Equals(roleValue,"BackupRoot",StringComparison.Ordinal)) ||
                String.IsNullOrEmpty(requestedPathValue) || String.IsNullOrEmpty(locationKeyValue) ||
                !String.Equals(targetStatusValue,"EXISTS",StringComparison.Ordinal) ||
                String.IsNullOrEmpty(probeRootPathValue) || String.IsNullOrEmpty(probeRootLocationKeyValue) ||
                String.IsNullOrEmpty(probeRootIdentityValue) ||
                !String.Equals(driveTypeValue,"Fixed",StringComparison.Ordinal) ||
                !String.Equals(fileSystemTypeValue,"NTFS",StringComparison.Ordinal) ||
                String.IsNullOrEmpty(volumeSerialValue) || !IsLowerHex64(filesystemCapabilityHashValue)) {
                throw new InvalidOperationException("fixed-infrastructure-capability-evidence-invalid");
            }
            if (String.IsNullOrEmpty(expectedCapabilityHashValue)) {
                if (verifiedAgainstExpectedValue.HasValue) {
                    throw new InvalidOperationException("fixed-infrastructure-capability-evidence-invalid");
                }
                expectedCapabilityHashValue = null;
                verifiedAgainstExpectedValue = null;
            }
            else if (!IsLowerHex64(expectedCapabilityHashValue) ||
                !verifiedAgainstExpectedValue.HasValue || !verifiedAgainstExpectedValue.Value ||
                !String.Equals(expectedCapabilityHashValue,filesystemCapabilityHashValue,StringComparison.Ordinal)) {
                throw new InvalidOperationException("fixed-infrastructure-capability-evidence-invalid");
            }
            return new SealedFixedInfrastructureCapabilityRoleRow(roleValue,requestedPathValue,
                locationKeyValue,targetStatusValue,probeRootPathValue,probeRootLocationKeyValue,
                probeRootIdentityValue,driveTypeValue,fileSystemTypeValue,volumeSerialValue,
                filesystemCapabilityHashValue,expectedCapabilityHashValue,verifiedAgainstExpectedValue);
        }

        public static string GetRoleExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.role; }
        public static string GetRequestedPathExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.requestedPath; }
        public static string GetLocationKeyExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.locationKey; }
        public static string GetTargetStatusExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.targetStatus; }
        public static string GetProbeRootPathExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.probeRootPath; }
        public static string GetProbeRootLocationKeyExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.probeRootLocationKey; }
        public static string GetProbeRootIdentityExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.probeRootIdentity; }
        public static string GetDriveTypeExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.driveType; }
        public static string GetFileSystemTypeExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.fileSystemType; }
        public static string GetVolumeSerialExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.volumeSerial; }
        public static string GetFilesystemCapabilityHashExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.filesystemCapabilityHash; }
        public static string GetExpectedCapabilityHashExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? null : value.expectedCapabilityHash; }
        public static bool? GetVerifiedAgainstExpectedExact(SealedFixedInfrastructureCapabilityRoleRow value) { return value == null ? (bool?)null : value.verifiedAgainstExpected; }
    }

    public sealed class SealedFixedInfrastructureCapabilityEvidence {
        private readonly string authorityContextHash;
        private readonly string fixedEnvelopeHash;
        private readonly string lockSecurityHash;
        private readonly string coverage;
        private readonly SealedFixedInfrastructureCapabilityRoleRow[] rows;
        private readonly string projectionHash;

        private SealedFixedInfrastructureCapabilityEvidence(string authorityContextHashValue,
            string fixedEnvelopeHashValue, string lockSecurityHashValue, string coverageValue,
            SealedFixedInfrastructureCapabilityRoleRow[] rowsValue, string projectionHashValue) {
            authorityContextHash = authorityContextHashValue;
            fixedEnvelopeHash = fixedEnvelopeHashValue;
            lockSecurityHash = lockSecurityHashValue;
            coverage = coverageValue;
            rows = (SealedFixedInfrastructureCapabilityRoleRow[])rowsValue.Clone();
            projectionHash = projectionHashValue;
        }

        private static bool IsLowerHex64(string value) {
            if (value == null || value.Length != 64) return false;
            for (int index = 0; index < value.Length; index++) {
                char current = value[index];
                if (!((current >= '0' && current <= '9') || (current >= 'a' && current <= 'f'))) return false;
            }
            return true;
        }

        public static SealedFixedInfrastructureCapabilityEvidence CreateExact(string authorityContextHashValue,
            string fixedEnvelopeHashValue, string lockSecurityHashValue, string coverageValue,
            SealedFixedInfrastructureCapabilityRoleRow[] rowsValue, string projectionHashValue) {
            if (!IsLowerHex64(authorityContextHashValue) || !IsLowerHex64(fixedEnvelopeHashValue) ||
                !IsLowerHex64(lockSecurityHashValue) ||
                !String.Equals(coverageValue,"FIXED_INFRASTRUCTURE_PROBED",StringComparison.Ordinal) ||
                rowsValue == null || rowsValue.Length != 2 || rowsValue[0] == null || rowsValue[1] == null ||
                !String.Equals(SealedFixedInfrastructureCapabilityRoleRow.GetRoleExact(rowsValue[0]),"ControlBase",StringComparison.Ordinal) ||
                !String.Equals(SealedFixedInfrastructureCapabilityRoleRow.GetRoleExact(rowsValue[1]),"BackupRoot",StringComparison.Ordinal) ||
                !IsLowerHex64(projectionHashValue)) {
                throw new InvalidOperationException("fixed-infrastructure-capability-evidence-invalid");
            }
            return new SealedFixedInfrastructureCapabilityEvidence(authorityContextHashValue,
                fixedEnvelopeHashValue,lockSecurityHashValue,coverageValue,rowsValue,projectionHashValue);
        }

        public static string GetAuthorityContextHashExact(SealedFixedInfrastructureCapabilityEvidence value) { return value == null ? null : value.authorityContextHash; }
        public static string GetFixedEnvelopeHashExact(SealedFixedInfrastructureCapabilityEvidence value) { return value == null ? null : value.fixedEnvelopeHash; }
        public static string GetLockSecurityHashExact(SealedFixedInfrastructureCapabilityEvidence value) { return value == null ? null : value.lockSecurityHash; }
        public static string GetCoverageExact(SealedFixedInfrastructureCapabilityEvidence value) { return value == null ? null : value.coverage; }
        public static int GetRowCountExact(SealedFixedInfrastructureCapabilityEvidence value) { return value == null ? 0 : value.rows.Length; }
        public static SealedFixedInfrastructureCapabilityRoleRow GetRowExact(SealedFixedInfrastructureCapabilityEvidence value, int index) {
            if (value == null || index < 0 || index >= value.rows.Length) throw new ArgumentOutOfRangeException("index");
            return value.rows[index];
        }
        public static SealedFixedInfrastructureCapabilityRoleRow[] GetRowsExact(SealedFixedInfrastructureCapabilityEvidence value) { return value == null ? null : (SealedFixedInfrastructureCapabilityRoleRow[])value.rows.Clone(); }
        public static string GetProjectionHashExact(SealedFixedInfrastructureCapabilityEvidence value) { return value == null ? null : value.projectionHash; }
    }
}
'@
}

function Get-SealedFixedInfrastructureCapabilityRoleRowProjection {
    param([Parameter(Mandatory)][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]$Row)
    return [ordered]@{
        Role=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetRoleExact($Row)
        RequestedPath=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetRequestedPathExact($Row)
        LocationKey=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetLocationKeyExact($Row)
        TargetStatus=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetTargetStatusExact($Row)
        ProbeRootPath=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetProbeRootPathExact($Row)
        ProbeRootLocationKey=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetProbeRootLocationKeyExact($Row)
        ProbeRootIdentity=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetProbeRootIdentityExact($Row)
        DriveType=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetDriveTypeExact($Row)
        FileSystemType=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetFileSystemTypeExact($Row)
        VolumeSerial=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetVolumeSerialExact($Row)
        FilesystemCapabilityHash=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetFilesystemCapabilityHashExact($Row)
        ExpectedCapabilityHash=[AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetExpectedCapabilityHashExact($Row)
        VerifiedAgainstExpected=[AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetVerifiedAgainstExpectedExact($Row)
    }
}

function Get-SealedFixedInfrastructureCapabilityProjectionHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]$Evidence)
    $rowCount=[int][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetRowCountExact($Evidence)
    $rows=for($index=0;$index -lt $rowCount;$index++){
        Get-SealedFixedInfrastructureCapabilityRoleRowProjection -Row ([AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetRowExact($Evidence,$index))
    }
    return Get-SemanticJsonHash -InputObject ([ordered]@{
        AuthorityContextHash=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetAuthorityContextHashExact($Evidence)
        FixedEnvelopeHash=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetFixedEnvelopeHashExact($Evidence)
        LockSecurityHash=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetLockSecurityHashExact($Evidence)
        Coverage=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetCoverageExact($Evidence)
        Rows=@($rows)
    })
}

function Assert-SealedFixedInfrastructureCapabilityEvidenceExact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Evidence,
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)][string]$ExpectedAuthorityContextHash,
        [Parameter(Mandatory)][string]$ExpectedFixedEnvelopeHash,
        [Parameter(Mandatory)][string]$ExpectedLockSecurityHash,
        [Parameter(Mandatory)][string]$ControlBaseProbeRoot,
        [Parameter(Mandatory)][string]$BackupRootProbeRoot,
        [AllowNull()]$ControlBaseExpectedCapabilityHash,
        [AllowNull()]$BackupRootExpectedCapabilityHash
    )

    try {
        if($ExpectedAuthorityContextHash -cnotmatch $script:SealedRegistryHashPattern -or
            $ExpectedFixedEnvelopeHash -cnotmatch $script:SealedRegistryHashPattern -or
            $ExpectedLockSecurityHash -cnotmatch $script:SealedRegistryHashPattern -or
            $ExpectedAuthorityContextHash -cne (Get-SemanticJsonHash -InputObject $AuthorityContext)){
            throw 'invalid'
        }
        $targetPaths=@{
            ControlBase=[IO.Path]::GetFullPath([string]$AuthorityContext.ControlBase).TrimEnd([char]92,[char]47)
            BackupRoot=[IO.Path]::GetFullPath([string]$AuthorityContext.BackupRoot).TrimEnd([char]92,[char]47)
        }
        $probeRoots=@{
            ControlBase=[IO.Path]::GetFullPath($ControlBaseProbeRoot).TrimEnd([char]92,[char]47)
            BackupRoot=[IO.Path]::GetFullPath($BackupRootProbeRoot).TrimEnd([char]92,[char]47)
        }
        $expectedHashes=@{
            ControlBase=$ControlBaseExpectedCapabilityHash
            BackupRoot=$BackupRootExpectedCapabilityHash
        }
        foreach($role in @('ControlBase','BackupRoot')){
            if([string]::IsNullOrWhiteSpace([string]$targetPaths[$role]) -or
                [string]::IsNullOrWhiteSpace([string]$probeRoots[$role]) -or
                ($null -ne $expectedHashes[$role] -and [string]$expectedHashes[$role] -cnotmatch $script:SealedRegistryHashPattern)){
                throw 'invalid'
            }
        }

        if($Evidence -isnot [AiAgentDotfiles.SealedCapabilityPreflightEvidence]){throw 'invalid'}
        if((Get-SealedCapabilityPreflightProjectionHash -Evidence $Evidence) -cne
            [string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetProjectionHashExact($Evidence)){throw 'invalid'}
        if([string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetAuthorityContextHashExact($Evidence) -cne $ExpectedAuthorityContextHash -or
            [string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetFixedEnvelopeHashExact($Evidence) -cne $ExpectedFixedEnvelopeHash -or
            [string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetLockSecurityHashExact($Evidence) -cne $ExpectedLockSecurityHash -or
            [int][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowCountExact($Evidence) -ne 2){throw 'invalid'}

        $rawRowsByRole=@{}
        foreach($rawRow in @([AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowsExact($Evidence))){
            if($rawRow -isnot [AiAgentDotfiles.SealedCapabilityPreflightRow]){throw 'invalid'}
            $requestedPath=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetRequestedPathExact($rawRow)
            $roleMatches=@('ControlBase','BackupRoot' | Where-Object { [string]$targetPaths[$_] -ceq $requestedPath })
            if($roleMatches.Count -ne 1 -or $rawRowsByRole.ContainsKey([string]$roleMatches[0])){throw 'invalid'}
            $role=[string]$roleMatches[0]
            $targetMetadata=Resolve-TargetContext -Path ([string]$targetPaths[$role]) -Mode MetadataOnly
            $probeMetadata=Resolve-TargetContext -Path ([string]$probeRoots[$role]) -Mode MetadataOnly
            $targetVolumeInfo=[AiAgentDotfiles.NoFollowFile]::GetVolumeInfo([string]$targetMetadata.DeepestExistingParentPath)
            $probeVolumeInfo=[AiAgentDotfiles.NoFollowFile]::GetVolumeInfo([string]$probeMetadata.DeepestExistingParentPath)
            if([string]$targetMetadata.TargetStatus -cne 'EXISTS' -or [string]$targetMetadata.TargetType -cne 'Directory' -or
                [string]$targetMetadata.RequestedPath -cne [string]$targetPaths[$role] -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($rawRow) -cne [string]$targetMetadata.LocationKey -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetTargetStatusExact($rawRow) -cne 'EXISTS' -or
                [string]$probeMetadata.TargetStatus -cne 'EXISTS' -or [string]$probeMetadata.TargetType -cne 'Directory' -or
                [string]$probeMetadata.RequestedPath -cne [string]$probeRoots[$role] -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootPathExact($rawRow) -cne [string]$probeMetadata.RequestedPath -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootLocationKeyExact($rawRow) -cne [string]$probeMetadata.LocationKey -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootIdentityExact($rawRow) -cne [string]$probeMetadata.DeepestExistingParentIdentity -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetDriveTypeExact($rawRow) -cne 'Fixed' -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFileSystemTypeExact($rawRow) -cne 'NTFS' -or
                [string]$targetVolumeInfo.DriveType -cne 'Fixed' -or [string]$targetVolumeInfo.FileSystemType -cne 'NTFS' -or
                [string]$probeVolumeInfo.DriveType -cne 'Fixed' -or [string]$probeVolumeInfo.FileSystemType -cne 'NTFS' -or
                [string]$targetVolumeInfo.VolumeSerial -cne [string]$targetMetadata.VolumeId -or
                [string]$probeVolumeInfo.VolumeSerial -cne [string]$probeMetadata.VolumeId -or
                [string]$probeVolumeInfo.VolumeSerial -cne [string]$targetVolumeInfo.VolumeSerial -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVolumeSerialExact($rawRow) -cne [string]$targetMetadata.VolumeId -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVolumeSerialExact($rawRow) -cne [string]$probeMetadata.VolumeId -or
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($rawRow) -cnotmatch $script:SealedRegistryHashPattern){throw 'invalid'}

            $expectedActual=[AiAgentDotfiles.SealedCapabilityPreflightRow]::GetExpectedCapabilityHashExact($rawRow)
            $verifiedActual=[AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVerifiedAgainstExpectedExact($rawRow)
            $expectedForRole=$expectedHashes[$role]
            if($null -ne $expectedForRole){
                if([string]$expectedActual -cne [string]$expectedForRole -or
                    [string]$expectedActual -cne [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($rawRow) -or
                    $null -eq $verifiedActual -or -not [bool]$verifiedActual){throw 'invalid'}
            }
            elseif($null -ne $expectedActual -or $null -ne $verifiedActual){throw 'invalid'}
            $rawRowsByRole[$role]=$rawRow
        }
        if($rawRowsByRole.Count -ne 2 -or -not $rawRowsByRole.ContainsKey('ControlBase') -or
            -not $rawRowsByRole.ContainsKey('BackupRoot')){throw 'invalid'}
        return [pscustomobject][ordered]@{
            ControlBase=$rawRowsByRole.ControlBase
            BackupRoot=$rawRowsByRole.BackupRoot
        }
    }
    catch { throw 'fixed-infrastructure-capability-evidence-invalid' }
}

function Invoke-SealedHeldFixedInfrastructureCapabilityCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)][AllowNull()]$GlobalLockHandle,
        [AllowNull()]$CanonicalWitness,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$CapabilityProbeBindings
    )

    $normalizedBindings=@{}
    try {
        $bindingRows=@($CapabilityProbeBindings)
        if($bindingRows.Count -ne 2){throw 'invalid'}
        foreach($binding in $bindingRows){
            if($null -eq $binding){throw 'invalid'}
            $shape=@(Get-SealedRegistryOrdinalStrings -Values @(Get-SealedRegistryPropertyNames -InputObject $binding))
            $shapeText=$shape -join "`0"
            $baseShapeText=[string[]]@('ProbeRoot','Role') -join "`0"
            $expectedShapeText=[string[]]@('ExpectedFilesystemCapabilityHash','ProbeRoot','Role') -join "`0"
            if($shapeText -cne $baseShapeText -and $shapeText -cne $expectedShapeText){throw 'invalid'}
            $role=Get-SealedRegistryObjectValue -InputObject $binding -Name 'Role'
            $probeRoot=Get-SealedRegistryObjectValue -InputObject $binding -Name 'ProbeRoot'
            if($role -isnot [string] -or $probeRoot -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$role) -or [string]::IsNullOrWhiteSpace([string]$probeRoot) -or
                [string]$role -cnotin @('ControlBase','BackupRoot') -or $normalizedBindings.ContainsKey([string]$role)){
                throw 'invalid'
            }
            if(-not [IO.Path]::IsPathFullyQualified([string]$probeRoot) -or ([string]$probeRoot).StartsWith('\',[StringComparison]::Ordinal)){throw 'invalid'}
            $probeRootFull=[IO.Path]::GetFullPath([string]$probeRoot).TrimEnd([char]92,[char]47)
            if([string]::IsNullOrWhiteSpace($probeRootFull) -or [IO.Path]::GetPathRoot($probeRootFull) -ceq $probeRootFull){throw 'invalid'}
            $hasExpected=$shapeText -ceq $expectedShapeText
            $expectedValue=if($hasExpected){Get-SealedRegistryObjectValue -InputObject $binding -Name 'ExpectedFilesystemCapabilityHash'}else{$null}
            if($hasExpected -and ($expectedValue -isnot [string] -or [string]$expectedValue -cnotmatch $script:SealedRegistryHashPattern)){throw 'invalid'}
            $normalizedBindings[[string]$role]=[pscustomobject][ordered]@{
                Role=[string]$role
                ProbeRoot=$probeRootFull
                HasExpected=[bool]$hasExpected
                ExpectedFilesystemCapabilityHash=if($hasExpected){[string]$expectedValue}else{$null}
            }
        }
        if($normalizedBindings.Count -ne 2 -or -not $normalizedBindings.ContainsKey('ControlBase') -or -not $normalizedBindings.ContainsKey('BackupRoot')){throw 'invalid'}
    }
    catch { throw 'fixed-infrastructure-capability-binding-invalid' }

    $entryLockEvidence=$null
    try {
        $null=Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
        $entryLockEvidence=Assert-SealedHomeAuthorityGlobalLockWitness -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle
        if($null -ne $CanonicalWitness){
            $null=Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness
        }
    }
    catch { throw 'fixed-infrastructure-capability-lock-drift' }

    $authorityContextHash=[string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetAuthorityContextHashExact($entryLockEvidence)
    $entryFixedEnvelopeHash=[string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetFixedEnvelopeHashExact($entryLockEvidence)
    $entryLockSecurityHash=[string][AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::GetLockSecurityHashExact($entryLockEvidence)
    $targetPaths=@{
        ControlBase=[IO.Path]::GetFullPath([string]$AuthorityContext.ControlBase).TrimEnd([char]92,[char]47)
        BackupRoot=[IO.Path]::GetFullPath([string]$AuthorityContext.BackupRoot).TrimEnd([char]92,[char]47)
    }
    $directoryTemplate=Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid ([string]$AuthorityContext.TokenSid) -ResourceKind Directory
    $fileTemplate=Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid ([string]$AuthorityContext.TokenSid) -ResourceKind File
    $fixedEnvelope=$null
    $initialEnvelopeHash=$null
    $capturePrimaryError=$null
    try {
        try {
            $fixedEnvelope=Open-SealedHomeAuthorityFixedEnvelope -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate -HeldGlobalLock $GlobalLockHandle
            $initialEnvelopeHash=[string]$fixedEnvelope.InitialEnvelopeHash
            if($initialEnvelopeHash -cnotmatch $script:SealedRegistryHashPattern -or $initialEnvelopeHash -cne $entryFixedEnvelopeHash){throw 'invalid'}
        }
        catch { throw 'fixed-infrastructure-capability-envelope-drift' }

        $capabilityTargets=[Collections.Generic.List[object]]::new()
        foreach($role in @('ControlBase','BackupRoot')){
            $binding=$normalizedBindings[$role]
            $target=[ordered]@{Path=[string]$targetPaths[$role];ProbeRoot=[string]$binding.ProbeRoot}
            if([bool]$binding.HasExpected){$target.ExpectedFilesystemCapabilityHash=[string]$binding.ExpectedFilesystemCapabilityHash}
            $capabilityTargets.Add($target)
        }

        $currentRawPreflight=$ExecutionContext.SessionState.InvokeCommand.GetCommand(
            'Invoke-SealedHeldCapabilityPreflight',[System.Management.Automation.CommandTypes]::Function)
        if($null -eq $currentRawPreflight -or
            -not [AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer]::MatchesRawExact($currentRawPreflight.ScriptBlock)){
            throw 'fixed-infrastructure-capability-evidence-invalid'
        }
        try {
            $rawEvidence=[AiAgentDotfiles.SealedFixedInfrastructureCapabilityIssuer]::InvokeRawExact(
                $AuthorityContext,$GlobalLockHandle,$CanonicalWitness,[object[]]$capabilityTargets.ToArray())
        }
        catch {
            Throw-SealedFixedInfrastructureCapabilityIssuerException -Exception $_.Exception
        }
        $validatedRawRows=Assert-SealedFixedInfrastructureCapabilityEvidenceExact -Evidence $rawEvidence `
            -AuthorityContext $AuthorityContext -ExpectedAuthorityContextHash $authorityContextHash `
            -ExpectedFixedEnvelopeHash $entryFixedEnvelopeHash -ExpectedLockSecurityHash $entryLockSecurityHash `
            -ControlBaseProbeRoot ([string]$normalizedBindings.ControlBase.ProbeRoot) `
            -BackupRootProbeRoot ([string]$normalizedBindings.BackupRoot.ProbeRoot) `
            -ControlBaseExpectedCapabilityHash $(if([bool]$normalizedBindings.ControlBase.HasExpected){[string]$normalizedBindings.ControlBase.ExpectedFilesystemCapabilityHash}else{$null}) `
            -BackupRootExpectedCapabilityHash $(if([bool]$normalizedBindings.BackupRoot.HasExpected){[string]$normalizedBindings.BackupRoot.ExpectedFilesystemCapabilityHash}else{$null})
        $rawRowsByRole=@{
            ControlBase=$validatedRawRows.ControlBase
            BackupRoot=$validatedRawRows.BackupRoot
        }

        $sealedRows=[AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow[]]::new(2)
        for($index=0;$index -lt 2;$index++){
            $role=@('ControlBase','BackupRoot')[$index]
            $rawRow=$rawRowsByRole[$role]
            $sealedRows[$index]=[AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::CreateExact(
                $role,
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetRequestedPathExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetTargetStatusExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootPathExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootLocationKeyExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootIdentityExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetDriveTypeExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFileSystemTypeExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVolumeSerialExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetExpectedCapabilityHashExact($rawRow),
                [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVerifiedAgainstExpectedExact($rawRow))
        }
        $rowProjections=foreach($row in $sealedRows){Get-SealedFixedInfrastructureCapabilityRoleRowProjection -Row $row}
        $coverage='FIXED_INFRASTRUCTURE_PROBED'
        $projectionHash=Get-SemanticJsonHash -InputObject ([ordered]@{
            AuthorityContextHash=$authorityContextHash
            FixedEnvelopeHash=$entryFixedEnvelopeHash
            LockSecurityHash=$entryLockSecurityHash
            Coverage=$coverage
            Rows=@($rowProjections)
        })
        $sealedEvidence=[AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::CreateExact(
            $authorityContextHash,$entryFixedEnvelopeHash,$entryLockSecurityHash,$coverage,$sealedRows,$projectionHash)
        if((Get-SealedFixedInfrastructureCapabilityProjectionHash -Evidence $sealedEvidence) -cne
            [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetProjectionHashExact($sealedEvidence)){
            throw 'fixed-infrastructure-capability-evidence-invalid'
        }

        $finalEnvelope=$null
        $finalEnvelopeError=$null
        try {
            $finalEnvelope=Get-SealedHomeAuthorityFixedEnvelopeProjection -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate -EnvelopeLease $fixedEnvelope -HeldGlobalLock $GlobalLockHandle
        }
        catch { $finalEnvelopeError=$_ }
        $finalLockEvidence=$null
        try { $finalLockEvidence=Assert-SealedHomeAuthorityGlobalLockWitness -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle }
        catch { throw 'fixed-infrastructure-capability-lock-drift' }
        if(-not [AiAgentDotfiles.SealedRegistryGlobalLockEvidence]::MatchesExact($entryLockEvidence,$finalLockEvidence)){
            throw 'fixed-infrastructure-capability-lock-drift'
        }
        if($null -ne $finalEnvelopeError -or [string]$finalEnvelope.EnvelopeHash -cne $initialEnvelopeHash){
            throw 'fixed-infrastructure-capability-envelope-drift'
        }
        if($null -ne $CanonicalWitness){
            try {
                $null=Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness
            }
            catch { throw 'fixed-infrastructure-capability-lock-drift' }
        }
        return $sealedEvidence
    }
    catch {
        $capturePrimaryError=$_
        throw
    }
    finally {
        if($null -ne $fixedEnvelope){
            $captureCleanupError=$null
            try { Close-SealedHomeAuthorityFixedEnvelope -EnvelopeLease $fixedEnvelope }
            catch { $captureCleanupError=$_ }
            if($null -ne $captureCleanupError){
                if($null -ne $capturePrimaryError){
                    try {
                        $capturePrimaryError.Exception.Data['SealedFixedInfrastructureCapabilityCleanupError']=[string]$captureCleanupError.Exception.Message
                    }
                    catch { }
                    throw $capturePrimaryError
                }
                throw $captureCleanupError
            }
        }
    }
}
