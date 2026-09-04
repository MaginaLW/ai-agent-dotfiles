#requires -Version 7.0

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'live-target-context.ps1')

if (-not ('AiAgentDotfiles.SealedHomeAuthorityFixedEnvelopeCloseState' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.CompilerServices;
using System.Threading;

namespace AiAgentDotfiles {
    public static class SealedHomeAuthorityFixedEnvelopeCloseState {
        private sealed class CloseRecord {
            internal bool Closed;
        }
        private static readonly ConditionalWeakTable<object,CloseRecord> Records =
            new ConditionalWeakTable<object,CloseRecord>();
        public static void BindExact(object envelopeLease) {
            if (envelopeLease == null)
                throw new InvalidOperationException("home-authority-fixed-envelope-lease-invalid");
            try { Records.Add(envelopeLease,new CloseRecord()); }
            catch (ArgumentException) { throw new InvalidOperationException("home-authority-fixed-envelope-lease-invalid"); }
        }
        public static bool GetIsClosedExact(object envelopeLease) {
            if (envelopeLease == null) return false;
            CloseRecord record;
            return Records.TryGetValue(envelopeLease,out record) && record != null &&
                Volatile.Read(ref record.Closed);
        }
        public static bool MarkClosedExact(object envelopeLease) {
            if (envelopeLease == null)
                throw new InvalidOperationException("home-authority-fixed-envelope-lease-invalid");
            CloseRecord record;
            if (!Records.TryGetValue(envelopeLease,out record) || record == null) return false;
            lock (record) {
                if (Volatile.Read(ref record.Closed)) return false;
                Volatile.Write(ref record.Closed,true);
                return true;
            }
        }
    }
}
'@
}

if ($IsWindows -and -not ('AiAgentDotfiles.WindowsKnownFolder' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace AiAgentDotfiles {
    public static class WindowsKnownFolder {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int SHGetKnownFolderPath(
            ref Guid rfid,
            uint dwFlags,
            SafeAccessTokenHandle hToken,
            out IntPtr ppszPath);

        public static string GetPath(string knownFolderId, SafeAccessTokenHandle token) {
            if (token == null || token.IsClosed || token.IsInvalid)
                throw new ArgumentException("A live access token is required.", "token");
            Guid id = new Guid(knownFolderId);
            IntPtr value = IntPtr.Zero;
            try {
                int result = SHGetKnownFolderPath(ref id, 0U, token, out value);
                if (result < 0) Marshal.ThrowExceptionForHR(result);
                string path = Marshal.PtrToStringUni(value);
                if (String.IsNullOrWhiteSpace(path)) throw new InvalidOperationException("Known Folder returned an empty path");
                return path;
            }
            finally {
                if (value != IntPtr.Zero) Marshal.FreeCoTaskMem(value);
            }
        }
    }
}
'@
}

if (-not ('AiAgentDotfiles.SafeLockResourceOwner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading;

namespace AiAgentDotfiles {
    public sealed class SafeLockResourceOwner {
        private static readonly ConditionalWeakTable<object, SafeLockResourceOwner> Owners = new ConditionalWeakTable<object, SafeLockResourceOwner>();
        private readonly object wrapper;
        private readonly object held;
        private readonly object[] parents;
        private readonly object info;
        private readonly object stream;
        private readonly string path;
        private readonly string securitySddl;
        private readonly string securityHash;
        private readonly long ordinal;
        private readonly string identity;
        private readonly uint linkCount;
        private readonly long length;
        private readonly string[] parentIdentities;
        private readonly uint[] parentLinkCounts;
        private int releaseState;

        private SafeLockResourceOwner(object wrapperValue, object heldValue, object[] parentValues, object infoValue,
            object streamValue, string pathValue, string securitySddlValue, string securityHashValue, long ordinalValue,
            string identityValue, uint linkCountValue, long lengthValue, string[] parentIdentityValues, uint[] parentLinkCountValues) {
            wrapper = wrapperValue;
            held = heldValue;
            parents = (object[])parentValues.Clone();
            info = infoValue;
            stream = streamValue;
            path = Path.GetFullPath(pathValue);
            securitySddl = securitySddlValue;
            securityHash = securityHashValue;
            ordinal = ordinalValue;
            identity = identityValue;
            linkCount = linkCountValue;
            length = lengthValue;
            parentIdentities = (string[])parentIdentityValues.Clone();
            parentLinkCounts = (uint[])parentLinkCountValues.Clone();
        }

        private static SafeLockResourceOwner Require(SafeLockResourceOwner value) {
            if (value == null) throw new InvalidOperationException("lock-resource-owner-required");
            return value;
        }
        public static SafeLockResourceOwner BindExact(object wrapperValue, object heldValue, object[] parentValues,
            object infoValue, object streamValue, string pathValue, string securitySddlValue, string securityHashValue,
            long ordinalValue, string identityValue, uint linkCountValue, long lengthValue,
            string[] parentIdentityValues, uint[] parentLinkCountValues) {
            if (wrapperValue == null || heldValue == null || parentValues == null || parentValues.Length == 0 ||
                infoValue == null || streamValue == null || String.IsNullOrWhiteSpace(pathValue) || ordinalValue <= 0 ||
                String.IsNullOrWhiteSpace(identityValue) || parentIdentityValues == null || parentLinkCountValues == null ||
                parentIdentityValues.Length != parentValues.Length || parentLinkCountValues.Length != parentValues.Length)
                throw new InvalidOperationException("lock-resource-owner-required");
            for (int index = 0; index < parentValues.Length; index++)
                if (parentValues[index] == null || String.IsNullOrWhiteSpace(parentIdentityValues[index])) throw new InvalidOperationException("lock-resource-owner-required");
            SafeLockResourceOwner value = new SafeLockResourceOwner(wrapperValue, heldValue, parentValues, infoValue, streamValue,
                pathValue, securitySddlValue, securityHashValue, ordinalValue, identityValue, linkCountValue, lengthValue,
                parentIdentityValues, parentLinkCountValues);
            Owners.Add(wrapperValue, value);
            return value;
        }
        public static SafeLockResourceOwner GetForWrapperExact(object wrapperValue) {
            if (wrapperValue == null) return null;
            SafeLockResourceOwner value;
            return Owners.TryGetValue(wrapperValue, out value) ? value : null;
        }
        public static bool IsExactForWrapper(SafeLockResourceOwner value, object wrapperValue) {
            if (value == null || wrapperValue == null || !Object.ReferenceEquals(value.wrapper, wrapperValue)) return false;
            SafeLockResourceOwner registered;
            return Owners.TryGetValue(wrapperValue, out registered) && Object.ReferenceEquals(value, registered);
        }
        public static object GetHeldLockExact(SafeLockResourceOwner value) { return Require(value).held; }
        public static object[] GetParentHandlesExact(SafeLockResourceOwner value) { return (object[])Require(value).parents.Clone(); }
        public static object GetInfoExact(SafeLockResourceOwner value) { return Require(value).info; }
        public static object GetStreamViewExact(SafeLockResourceOwner value) { return Require(value).stream; }
        public static string GetPathExact(SafeLockResourceOwner value) { return Require(value).path; }
        public static string GetSecuritySddlExact(SafeLockResourceOwner value) { return Require(value).securitySddl; }
        public static string GetSecurityHashExact(SafeLockResourceOwner value) { return Require(value).securityHash; }
        public static long GetAcquisitionOrdinalExact(SafeLockResourceOwner value) { return Require(value).ordinal; }
        public static string GetAcquiredIdentityExact(SafeLockResourceOwner value) { return Require(value).identity; }
        public static uint GetAcquiredLinkCountExact(SafeLockResourceOwner value) { return Require(value).linkCount; }
        public static long GetAcquiredLengthExact(SafeLockResourceOwner value) { return Require(value).length; }
        public static string GetParentIdentityExact(SafeLockResourceOwner value, int index) { return Require(value).parentIdentities[index]; }
        public static uint GetParentLinkCountExact(SafeLockResourceOwner value, int index) { return Require(value).parentLinkCounts[index]; }
        public static bool GetIsReleasedExact(SafeLockResourceOwner value) { return value != null && Volatile.Read(ref value.releaseState) == 2; }
        public static bool MatchesAcquiredEvidenceExact(SafeLockResourceOwner value) {
            return value != null && Volatile.Read(ref value.releaseState) == 0 && value.held != null && value.info != null &&
                value.stream != null && value.parents.Length > 0 && value.ordinal > 0 && !String.IsNullOrWhiteSpace(value.identity);
        }
        public static void ReleaseExact(SafeLockResourceOwner value) {
            SafeLockResourceOwner owner = Require(value);
            int prior = Interlocked.CompareExchange(ref owner.releaseState, 1, 0);
            if (prior == 2) return;
            if (prior != 0) throw new InvalidOperationException("lock-resource-owner-release-active");
            try { ((IDisposable)owner.held).Dispose(); }
            catch { Volatile.Write(ref owner.releaseState, 0); throw; }
            Exception first = null;
            for (int index = owner.parents.Length - 1; index >= 0; index--) {
                try { ((IDisposable)owner.parents[index]).Dispose(); }
                catch (Exception error) { if (first == null) first = error; }
            }
            SafeLockResourceOwner registered;
            if (Owners.TryGetValue(owner.wrapper, out registered) && Object.ReferenceEquals(owner, registered)) Owners.Remove(owner.wrapper);
            Volatile.Write(ref owner.releaseState, 2);
            if (first != null) throw first;
        }
    }
}
'@
}

if (-not ('AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Security.Cryptography;
using System.Threading;

namespace AiAgentDotfiles {
    public sealed class HomeAuthorityCanonicalGlobalAcquisitionCapture {
        private readonly object witnessSource;
        private readonly object witnessSnapshot;
        private readonly object authoritySource;
        private readonly object canonicalLockHandle;
        private readonly object canonicalOwner;
        private readonly object canonicalHeld;
        private readonly object[] canonicalParents;
        private readonly byte[] witnessProjectionBytes;
        private readonly byte[] authorityContextBytes;
        private readonly byte[] liveTargetProjectionBytes;
        private readonly string witnessHash;
        private readonly string witnessProjectionHash;
        private readonly string authorityContextHash;
        private readonly string liveTargetProjectionHash;
        private int bindingClaimed;

        private HomeAuthorityCanonicalGlobalAcquisitionCapture(object witnessSourceValue, object witnessSnapshotValue,
            object authoritySourceValue, object canonicalLockHandleValue, object canonicalOwnerValue,
            object canonicalHeldValue, object[] canonicalParentValues, byte[] witnessProjectionBytesValue,
            byte[] authorityContextBytesValue, byte[] liveTargetProjectionBytesValue, string witnessHashValue,
            string witnessProjectionHashValue, string authorityContextHashValue, string liveTargetProjectionHashValue) {
            witnessSource = witnessSourceValue;
            witnessSnapshot = witnessSnapshotValue;
            authoritySource = authoritySourceValue;
            canonicalLockHandle = canonicalLockHandleValue;
            canonicalOwner = canonicalOwnerValue;
            canonicalHeld = canonicalHeldValue;
            canonicalParents = (object[])canonicalParentValues.Clone();
            witnessProjectionBytes = (byte[])witnessProjectionBytesValue.Clone();
            authorityContextBytes = (byte[])authorityContextBytesValue.Clone();
            liveTargetProjectionBytes = (byte[])liveTargetProjectionBytesValue.Clone();
            witnessHash = witnessHashValue;
            witnessProjectionHash = witnessProjectionHashValue;
            authorityContextHash = authorityContextHashValue;
            liveTargetProjectionHash = liveTargetProjectionHashValue;
        }

        private static bool IsCanonicalHash(string value) {
            if (value == null || value.Length != 64) return false;
            for (int index = 0; index < value.Length; index++) {
                char current = value[index];
                if (!((current >= '0' && current <= '9') || (current >= 'a' && current <= 'f'))) return false;
            }
            return true;
        }
        private static HomeAuthorityCanonicalGlobalAcquisitionCapture Require(HomeAuthorityCanonicalGlobalAcquisitionCapture value) {
            if (value == null) throw new InvalidOperationException("canonical-acquisition-capture-required");
            return value;
        }
        private static bool BytesEqual(byte[] left, byte[] right) {
            return left != null && right != null && left.Length == right.Length && CryptographicOperations.FixedTimeEquals(left, right);
        }

        public static HomeAuthorityCanonicalGlobalAcquisitionCapture CreateExact(object witnessSourceValue,
            object witnessSnapshotValue, object authoritySourceValue, object canonicalLockHandleValue,
            object canonicalOwnerValue, object canonicalHeldValue, object[] canonicalParentValues,
            byte[] witnessProjectionBytesValue, byte[] authorityContextBytesValue, byte[] liveTargetProjectionBytesValue,
            string witnessHashValue, string witnessProjectionHashValue, string authorityContextHashValue,
            string liveTargetProjectionHashValue) {
            if (witnessSourceValue == null || witnessSnapshotValue == null || authoritySourceValue == null ||
                canonicalLockHandleValue == null || canonicalOwnerValue == null || canonicalHeldValue == null ||
                canonicalParentValues == null || canonicalParentValues.Length == 0 || witnessProjectionBytesValue == null ||
                witnessProjectionBytesValue.Length == 0 || authorityContextBytesValue == null || authorityContextBytesValue.Length == 0 ||
                liveTargetProjectionBytesValue == null || liveTargetProjectionBytesValue.Length == 0 ||
                !IsCanonicalHash(witnessHashValue) || !IsCanonicalHash(witnessProjectionHashValue) ||
                !IsCanonicalHash(authorityContextHashValue) || !IsCanonicalHash(liveTargetProjectionHashValue))
                throw new InvalidOperationException("canonical-acquisition-capture-required");
            for (int index = 0; index < canonicalParentValues.Length; index++)
                if (canonicalParentValues[index] == null) throw new InvalidOperationException("canonical-acquisition-capture-required");
            return new HomeAuthorityCanonicalGlobalAcquisitionCapture(witnessSourceValue, witnessSnapshotValue,
                authoritySourceValue, canonicalLockHandleValue, canonicalOwnerValue, canonicalHeldValue,
                canonicalParentValues, witnessProjectionBytesValue, authorityContextBytesValue,
                liveTargetProjectionBytesValue, witnessHashValue, witnessProjectionHashValue,
                authorityContextHashValue, liveTargetProjectionHashValue);
        }

        public static object GetWitnessSourceExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return Require(value).witnessSource; }
        public static object GetAuthoritySourceExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return Require(value).authoritySource; }
        public static object GetCanonicalLockHandleExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return Require(value).canonicalLockHandle; }
        public static object GetCanonicalOwnerExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return Require(value).canonicalOwner; }
        public static object GetCanonicalHeldExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return Require(value).canonicalHeld; }
        public static object[] GetCanonicalParentsExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return (object[])Require(value).canonicalParents.Clone(); }
        public static byte[] GetAuthorityContextBytesExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return (byte[])Require(value).authorityContextBytes.Clone(); }
        public static string GetWitnessHashExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return Require(value).witnessHash; }
        public static string GetWitnessProjectionHashExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return Require(value).witnessProjectionHash; }
        public static string GetAuthorityContextHashExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return Require(value).authorityContextHash; }
        public static string GetLiveTargetProjectionHashExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) { return Require(value).liveTargetProjectionHash; }
        public static bool MatchesSourcesExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value, object witnessSourceValue, object authoritySourceValue) {
            return value != null && Object.ReferenceEquals(value.witnessSource, witnessSourceValue) &&
                Object.ReferenceEquals(value.authoritySource, authoritySourceValue);
        }
        public static bool MatchesCurrentSnapshotExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value,
            object canonicalLockHandleValue, object canonicalOwnerValue, object canonicalHeldValue,
            object[] canonicalParentValues, byte[] witnessProjectionBytesValue, byte[] authorityContextBytesValue,
            byte[] liveTargetProjectionBytesValue, string witnessHashValue, string witnessProjectionHashValue,
            string authorityContextHashValue, string liveTargetProjectionHashValue) {
            if (value == null || !Object.ReferenceEquals(value.canonicalLockHandle, canonicalLockHandleValue) ||
                !Object.ReferenceEquals(value.canonicalOwner, canonicalOwnerValue) ||
                !Object.ReferenceEquals(value.canonicalHeld, canonicalHeldValue) || canonicalParentValues == null ||
                value.canonicalParents.Length != canonicalParentValues.Length ||
                !String.Equals(value.witnessHash, witnessHashValue, StringComparison.Ordinal) ||
                !String.Equals(value.witnessProjectionHash, witnessProjectionHashValue, StringComparison.Ordinal) ||
                !String.Equals(value.authorityContextHash, authorityContextHashValue, StringComparison.Ordinal) ||
                !String.Equals(value.liveTargetProjectionHash, liveTargetProjectionHashValue, StringComparison.Ordinal) ||
                !BytesEqual(value.witnessProjectionBytes, witnessProjectionBytesValue) ||
                !BytesEqual(value.authorityContextBytes, authorityContextBytesValue) ||
                !BytesEqual(value.liveTargetProjectionBytes, liveTargetProjectionBytesValue)) return false;
            for (int index = 0; index < value.canonicalParents.Length; index++)
                if (!Object.ReferenceEquals(value.canonicalParents[index], canonicalParentValues[index])) return false;
            return true;
        }
        public static bool ClaimForBindingExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) {
            return value != null && Interlocked.CompareExchange(ref value.bindingClaimed, 1, 0) == 0;
        }
        public static bool IsBindingClaimedExact(HomeAuthorityCanonicalGlobalAcquisitionCapture value) {
            return value != null && Volatile.Read(ref value.bindingClaimed) == 1;
        }
    }
}
'@
}

$script:HomeAuthorityResolverVersion = 'windows-token-sid-known-folder-v1'
$script:HomeAuthorityProfileFolderId = '5e6c858f-0e22-4760-9afe-ea3317b67173'
$script:HomeAuthorityRoamingFolderId = '3eb685db-65f9-4cf6-a03a-e3ef65729f3d'
$script:HomeAuthorityLocalFolderId = 'f1b32785-6fba-4fcf-9d55-7b8e7f157091'

function ConvertTo-HomeAuthorityKnownFolderPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) { throw "home-authority-known-folder-invalid: $Name" }
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) { throw "home-authority-known-folder-unc: $Name" }
    $rawFull = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($rawFull)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or [IO.Path]::GetRelativePath($volumeRoot, $rawFull) -ceq '.') { throw "home-authority-known-folder-volume-root: $Name" }
    $full = $rawFull.TrimEnd([char]92, [char]47)
    $marker = Get-NoFollowRootEntryMarker -Path $full
    if ([string]$marker.EntryType -cne 'Directory') { throw "home-authority-known-folder-unavailable: $Name" }
    return $full
}

function ConvertTo-HomeAuthorityLocationKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\', [StringComparison]::Ordinal)) { throw 'home-authority-location-invalid' }
    $rawFull = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($rawFull)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or [IO.Path]::GetRelativePath($volumeRoot, $rawFull) -ceq '.') { throw 'home-authority-location-volume-root' }
    return $rawFull.TrimEnd([char]92, [char]47).ToLowerInvariant().Replace([char]92, [char]47)
}

function Get-WindowsHomeAuthorityIdentity {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) { throw 'live-safety-non-windows-interlocked' }
    $identity = $null
    try {
        try {
            $tokenAccess = [Security.Principal.TokenAccessLevels]::Query -bor [Security.Principal.TokenAccessLevels]::Impersonate -bor [Security.Principal.TokenAccessLevels]::Duplicate
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent($tokenAccess)
            $sid = $identity.User.Value
            if ([string]::IsNullOrWhiteSpace($sid)) { throw 'empty token SID' }
        }
        catch { throw "home-authority-token-sid-unavailable: $($_.Exception.Message)" }
        try {
            $token = $identity.AccessToken
            $profile = [AiAgentDotfiles.WindowsKnownFolder]::GetPath($script:HomeAuthorityProfileFolderId, $token)
            $roaming = [AiAgentDotfiles.WindowsKnownFolder]::GetPath($script:HomeAuthorityRoamingFolderId, $token)
            $local = [AiAgentDotfiles.WindowsKnownFolder]::GetPath($script:HomeAuthorityLocalFolderId, $token)
        }
        catch { throw "home-authority-known-folder-unavailable: $($_.Exception.Message)" }
    }
    finally { if ($null -ne $identity) { $identity.Dispose() } }
    return [pscustomobject][ordered]@{
        ResolverVersion = $script:HomeAuthorityResolverVersion
        TokenSid = $sid
        ProfileRoot = ConvertTo-HomeAuthorityKnownFolderPath -Path $profile -Name 'Profile'
        RoamingAppDataRoot = ConvertTo-HomeAuthorityKnownFolderPath -Path $roaming -Name 'RoamingAppData'
        LocalAppDataRoot = ConvertTo-HomeAuthorityKnownFolderPath -Path $local -Name 'LocalAppData'
    }
}

function Get-HomeAuthorityTokenDefaultOwnerSid {
    [CmdletBinding()]
    param()

    try { $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().Owner.Value }
    catch { throw 'home-authority-token-owner-unavailable' }
    if ([string]::IsNullOrWhiteSpace($ownerSid)) { throw 'home-authority-token-owner-unavailable' }
    return $ownerSid
}

function Get-HomeAuthorityIdentityField {
    param([Parameter(Mandatory)]$Identity,[Parameter(Mandatory)][string]$Name)
    $property = $Identity.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { throw "home-authority-identity-missing-field: $Name" }
    return [string]$property.Value
}

function Get-HomeAuthorityBootstrapStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$DeterministicPaths)

    $statuses = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $DeterministicPaths) {
        $context = Resolve-TargetContext -Path $path -Mode MetadataOnly
        if ([string]$context.TargetStatus -ceq 'EXISTS' -and [string]$context.TargetType -cne 'Directory') { throw 'home-authority-private-prefix-invalid' }
        $statuses.Add([string]$context.TargetStatus)
    }
    if (@($statuses | Where-Object { $_ -cne 'MISSING' }).Count -eq 0) { return 'MISSING' }
    return 'PARTIAL'
}

$script:HomeAuthorityBootstrapIntentArtifactKind = 'sealed-private-root-bootstrap-intent'
$script:HomeAuthorityBootstrapIntentSchemaVersion = 1

function Get-HomeAuthorityObjectProperty {
    param([Parameter(Mandatory)]$InputObject,[Parameter(Mandatory)][string]$Name,[switch]$AllowNull)

    $found = $false
    $value = $null
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { $found = $true; $value = $InputObject[$Name] }
    }
    else {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) { $found = $true; $value = $property.Value }
    }
    if (-not $found -or (-not $AllowNull -and $null -eq $value)) { throw "home-authority-bootstrap-missing-field: $Name" }
    return $value
}

function Get-HomeAuthorityObjectPropertyNames {
    param([Parameter(Mandatory)]$InputObject)
    if ($InputObject -is [System.Collections.IDictionary]) { return @($InputObject.Keys | ForEach-Object { [string]$_ }) }
    return @($InputObject.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty','Property') } | ForEach-Object Name)
}

function Assert-HomeAuthorityExactPropertySet {
    param([Parameter(Mandatory)]$InputObject,[Parameter(Mandatory)][string[]]$Expected,[Parameter(Mandatory)][string]$Label)
    $actual = @(Get-HomeAuthorityObjectPropertyNames -InputObject $InputObject | Sort-Object -CaseSensitive)
    $wanted = @($Expected | Sort-Object -CaseSensitive)
    if (($actual -join "`0") -cne ($wanted -join "`0")) { throw "home-authority-bootstrap-invalid-property-set: $Label" }
}

function Get-HomeAuthorityCurrentUserOnlySecurityTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][ValidateSet('Directory','File')][string]$ResourceKind
    )

    try { $canonicalSid = [Security.Principal.SecurityIdentifier]::new($TokenSid).Value }
    catch { throw 'home-authority-bootstrap-token-sid-invalid' }
    if ($TokenSid -cne $canonicalSid) { throw 'home-authority-bootstrap-token-sid-noncanonical' }
    try { $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    catch { throw 'home-authority-bootstrap-current-token-unavailable' }
    if ($currentSid -cne $TokenSid) { throw 'home-authority-bootstrap-token-sid-not-current-user' }
    $inheritance = if ($ResourceKind -ceq 'Directory') {
        [long]([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit)
    }
    else { [long][Security.AccessControl.InheritanceFlags]::None }
    return [ordered]@{
        ResolverVersion = 'windows-token-sid-current-user-only-v2'
        ResourceKind = $ResourceKind
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

function ConvertTo-HomeAuthoritySecurityDescriptorSddl {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SecurityTemplate)

    $kind = [string](Get-HomeAuthorityObjectProperty -InputObject $SecurityTemplate -Name 'ResourceKind')
    $sid = [string](Get-HomeAuthorityObjectProperty -InputObject $SecurityTemplate -Name 'OwnerSid')
    if ($kind -notin @('Directory','File')) { throw 'home-authority-bootstrap-security-kind-invalid' }
    $flags = if ($kind -ceq 'Directory') { 'OICI' } else { '' }
    return "O:$sid" + "G:$sid" + "D:P(A;$flags;FA;;;$sid)"
}

function ConvertFrom-HomeAuthoritySecuritySnapshot {
    param([Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][ValidateSet('Directory','File')][string]$ResourceKind)

    $raw = [Security.AccessControl.RawSecurityDescriptor]::new([string]$Snapshot.Sddl)
    if ($null -eq $raw.Owner -or $null -eq $raw.DiscretionaryAcl) { throw 'home-authority-bootstrap-security-unavailable' }
    $rules = [Collections.Generic.List[object]]::new()
    foreach ($ace in @($raw.DiscretionaryAcl)) {
        if ($ace -isnot [Security.AccessControl.CommonAce]) { throw 'home-authority-bootstrap-security-entry-unsupported' }
        if ($ace.IsCallback -or [long]$ace.OpaqueLength -ne 0) { throw 'home-authority-bootstrap-security-entry-unsupported' }
        $supportedAceFlags = [int]([Security.AccessControl.AceFlags]::ObjectInherit -bor [Security.AccessControl.AceFlags]::ContainerInherit -bor [Security.AccessControl.AceFlags]::NoPropagateInherit -bor [Security.AccessControl.AceFlags]::InheritOnly -bor [Security.AccessControl.AceFlags]::Inherited)
        if (([int]$ace.AceFlags -band (-bnot $supportedAceFlags)) -ne 0) { throw 'home-authority-bootstrap-security-entry-unsupported' }
        $accessType = switch ($ace.AceQualifier) {
            ([Security.AccessControl.AceQualifier]::AccessAllowed) { [long][Security.AccessControl.AccessControlType]::Allow; break }
            ([Security.AccessControl.AceQualifier]::AccessDenied) { [long][Security.AccessControl.AccessControlType]::Deny; break }
            default { throw 'home-authority-bootstrap-security-entry-unsupported' }
        }
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
        if (($ace.AceFlags -band [Security.AccessControl.AceFlags]::ContainerInherit) -ne 0) { $inheritance = $inheritance -bor [Security.AccessControl.InheritanceFlags]::ContainerInherit }
        if (($ace.AceFlags -band [Security.AccessControl.AceFlags]::ObjectInherit) -ne 0) { $inheritance = $inheritance -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit }
        $propagation = [Security.AccessControl.PropagationFlags]::None
        if (($ace.AceFlags -band [Security.AccessControl.AceFlags]::NoPropagateInherit) -ne 0) { $propagation = $propagation -bor [Security.AccessControl.PropagationFlags]::NoPropagateInherit }
        if (($ace.AceFlags -band [Security.AccessControl.AceFlags]::InheritOnly) -ne 0) { $propagation = $propagation -bor [Security.AccessControl.PropagationFlags]::InheritOnly }
        $rules.Add([ordered]@{
            Sid = [string]$ace.SecurityIdentifier.Value
            AccessControlType = $accessType
            FileSystemRights = [long]$ace.AccessMask
            InheritanceFlags = [long]$inheritance
            PropagationFlags = [long]$propagation
            IsInherited = (($ace.AceFlags -band [Security.AccessControl.AceFlags]::Inherited) -ne 0)
        })
    }
    $orderedRules = @($rules | Sort-Object @{Expression={[string]$_.Sid}},@{Expression={[long]$_.AccessControlType}},@{Expression={[long]$_.FileSystemRights}},@{Expression={[long]$_.InheritanceFlags}},@{Expression={[long]$_.PropagationFlags}},@{Expression={[bool]$_.IsInherited}})
    $protected = ($raw.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0
    return [ordered]@{
        ResolverVersion = 'windows-token-sid-current-user-only-v2'
        ResourceKind = $ResourceKind
        OwnerSid = [string]$raw.Owner.Value
        AreAccessRulesProtected = $protected
        AccessRules = $orderedRules
    }
}

function Copy-HomeAuthoritySecurityTemplateWithOwner {
    param([Parameter(Mandatory)]$SecurityTemplate,[Parameter(Mandatory)][string]$OwnerSid)

    $variant = [ordered]@{}
    if ($SecurityTemplate -is [System.Collections.IDictionary]) {
        foreach ($key in @($SecurityTemplate.Keys)) { $variant[$key] = $SecurityTemplate[$key] }
    }
    else {
        foreach ($property in @($SecurityTemplate.PSObject.Properties)) { $variant[$property.Name] = $property.Value }
    }
    $variant.OwnerSid = $OwnerSid
    return $variant
}

function Assert-HomeAuthoritySecuritySnapshot {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$SecurityTemplate,
        [Parameter(Mandatory)][string]$ExpectedIdentity
    )

    if ([string]$Snapshot.Identity -cne $ExpectedIdentity -or [long]$Snapshot.LinkCount -ne 1) { throw 'home-authority-bootstrap-security-identity-changed' }
    $kind = [string](Get-HomeAuthorityObjectProperty -InputObject $SecurityTemplate -Name 'ResourceKind')
    $evidence = ConvertFrom-HomeAuthoritySecuritySnapshot -Snapshot $Snapshot -ResourceKind $kind
    $actualHash = Get-SemanticJsonHash -InputObject $evidence
    $expectedHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null = $expectedHashes.Add((Get-SemanticJsonHash -InputObject $SecurityTemplate))
    $null = $expectedHashes.Add((Get-SemanticJsonHash -InputObject (Copy-HomeAuthoritySecurityTemplateWithOwner -SecurityTemplate $SecurityTemplate -OwnerSid (Get-HomeAuthorityTokenDefaultOwnerSid))))
    if (-not $expectedHashes.Contains($actualHash)) { throw 'home-authority-bootstrap-owner-dacl-mismatch' }
    return [pscustomobject][ordered]@{ Evidence=$evidence; EvidenceHash=$actualHash }
}

function Assert-SealedHomeAuthorityBootstrapContext {
    param([Parameter(Mandatory)]$AuthorityContext)

    $identityResolver = [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'IdentityResolverVersion')
    if ($identityResolver -ceq 'sealed-home-authority-test-adapter-v1') {
    }
    elseif ($identityResolver -ceq $script:HomeAuthorityResolverVersion) {
        $tokenSid = [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'TokenSid')
        try { $canonicalSid = [Security.Principal.SecurityIdentifier]::new($tokenSid).Value }
        catch { throw 'sealed-home-authority-bootstrap-token-sid-invalid' }
        if ($tokenSid -cne $canonicalSid) { throw 'sealed-home-authority-bootstrap-token-sid-noncanonical' }
        try { $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
        catch { throw 'sealed-home-authority-bootstrap-current-token-unavailable' }
        if ($currentSid -cne $tokenSid) { throw 'sealed-home-authority-bootstrap-token-sid-not-current-user' }
    }
    else {
        throw 'sealed-home-authority-bootstrap-context-required'
    }
    $local = ConvertTo-HomeAuthorityKnownFolderPath -Path ([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'LocalAppDataRoot')) -Name 'LocalAppData'
    $privateBase = [IO.Path]::GetFullPath((Join-Path $local 'ai-agent-dotfiles'))
    $control = [IO.Path]::GetFullPath((Join-Path $privateBase 'control'))
    $backup = [IO.Path]::GetFullPath((Join-Path $privateBase 'backups'))
    $expected = [ordered]@{
        PrivateRootBase = $privateBase
        ControlBase = $control
        BackupRoot = $backup
        HomesRoot = [IO.Path]::GetFullPath((Join-Path $control 'homes'))
        CanonicalRootsRoot = [IO.Path]::GetFullPath((Join-Path $control 'canonical-roots'))
        LiveTransactionsRoot = [IO.Path]::GetFullPath((Join-Path $control 'live-transactions'))
        GlobalLiveLockPath = [IO.Path]::GetFullPath((Join-Path $control 'live-mutation.lock'))
        ControlBootstrapLockPath = [IO.Path]::GetFullPath((Join-Path $local 'ai-agent-dotfiles.control-bootstrap.lock'))
    }
    foreach ($name in $expected.Keys) {
        if ([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name $name) -cne [string]$expected[$name]) {
            throw "sealed-home-authority-bootstrap-path-mismatch: $name"
        }
    }
    return [pscustomobject][ordered]@{ LocalAppDataRoot=$local; ExpectedPaths=$expected }
}

function Get-HomeAuthorityBootstrapEntryDefinitions {
    param([Parameter(Mandatory)]$AuthorityContext)

    $validated = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
    $local = [string]$validated.LocalAppDataRoot
    $paths = $validated.ExpectedPaths
    return @(
        [ordered]@{ Order=0L; Name='PrivateRootBase'; Kind='Directory'; Path=[string]$paths.PrivateRootBase; ParentPath=$local; LeafName='ai-agent-dotfiles'; ExpectedFinalChildren=@('backups','control') },
        [ordered]@{ Order=1L; Name='BackupRoot'; Kind='Directory'; Path=[string]$paths.BackupRoot; ParentPath=[string]$paths.PrivateRootBase; LeafName='backups'; ExpectedFinalChildren=@() },
        [ordered]@{ Order=2L; Name='ControlBase'; Kind='Directory'; Path=[string]$paths.ControlBase; ParentPath=[string]$paths.PrivateRootBase; LeafName='control'; ExpectedFinalChildren=@('canonical-roots','homes','live-mutation.lock','live-transactions') },
        [ordered]@{ Order=3L; Name='HomesRoot'; Kind='Directory'; Path=[string]$paths.HomesRoot; ParentPath=[string]$paths.ControlBase; LeafName='homes'; ExpectedFinalChildren=@() },
        [ordered]@{ Order=4L; Name='CanonicalRootsRoot'; Kind='Directory'; Path=[string]$paths.CanonicalRootsRoot; ParentPath=[string]$paths.ControlBase; LeafName='canonical-roots'; ExpectedFinalChildren=@() },
        [ordered]@{ Order=5L; Name='LiveTransactionsRoot'; Kind='Directory'; Path=[string]$paths.LiveTransactionsRoot; ParentPath=[string]$paths.ControlBase; LeafName='live-transactions'; ExpectedFinalChildren=@() },
        [ordered]@{ Order=6L; Name='GlobalLiveLock'; Kind='File'; Path=[string]$paths.GlobalLiveLockPath; ParentPath=[string]$paths.ControlBase; LeafName='live-mutation.lock'; ExpectedFinalChildren=@() }
    )
}

function Get-HomeAuthorityLockFileState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$FileSecurityTemplate,
        $HeldLockHandle
    )

    $marker = Get-NoFollowRootEntryMarker -Path $Path
    if ([string]$marker.EntryType -ceq 'MISSING') {
        return [ordered]@{ Name=$Name; Kind='File'; Path=[IO.Path]::GetFullPath($Path); Status='MISSING'; Identity=$null; SecurityHash=$null }
    }
    if ([string]$marker.EntryType -cne 'File') { throw "home-authority-bootstrap-manual-recovery-required: wrong type for $Name" }
    try {
        $heldOwner = if ($null -eq $HeldLockHandle) { $null } else { [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($HeldLockHandle) }
        if ($null -ne $HeldLockHandle -and ($heldOwner -isnot [AiAgentDotfiles.SafeLockResourceOwner] -or
            -not [AiAgentDotfiles.SafeLockResourceOwner]::IsExactForWrapper($heldOwner,$HeldLockHandle))) {
            throw 'lock resource owner is missing'
        }
        $heldForPath = $null -ne $heldOwner -and ([AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($heldOwner)).Equals([IO.Path]::GetFullPath($Path),[StringComparison]::OrdinalIgnoreCase)
        if ($heldForPath) {
            $heldFile = [AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($heldOwner)
            $info = [AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($heldFile)
            if (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($heldFile) -or
                [string][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact($heldFile) -cne [AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredIdentityExact($heldOwner) -or
                [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLinkCountExact($heldFile) -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLinkCountExact($heldOwner) -or
                [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLengthExact($heldFile) -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLengthExact($heldOwner)) {
                throw 'lock immutable acquisition evidence changed'
            }
            if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($heldFile)).Count -ne 0) { throw 'lock file has named streams' }
            $securityBefore = [AiAgentDotfiles.NoFollowFile]::GetLockFileSecuritySnapshot($heldFile)
            $security = [AiAgentDotfiles.NoFollowFile]::GetLockFileSecuritySnapshot($heldFile)
            if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($heldFile)).Count -ne 0) { throw 'lock file acquired named streams during capture' }
        }
        else {
            $before = [AiAgentDotfiles.NoFollowFile]::Inspect($Path)
            if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($Path)).Count -ne 0) { throw 'lock file has named streams' }
            $securityBefore = [AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($Path)
            $after = [AiAgentDotfiles.NoFollowFile]::Inspect($Path)
            if ([string]$before.Identity -cne [string]$after.Identity -or [long]$before.Length -ne [long]$after.Length) { throw 'lock file identity changed during capture' }
            $info = $after
            $security = [AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($Path)
        }
        if ([string]$securityBefore.Identity -cne [string]$security.Identity -or [string]$securityBefore.Sddl -cne [string]$security.Sddl) { throw 'lock file owner/DACL changed during capture' }
        if ($info.IsDirectory -or $info.IsReparsePoint -or [long]$info.LinkCount -ne 1 -or [long]$info.Length -ne 0) { throw 'lock file contract mismatch' }
        if ([string]$info.Identity -cne [string]$marker.Identity) { throw 'lock file marker identity changed' }
        $securityEvidence = Assert-HomeAuthoritySecuritySnapshot -Snapshot $security -SecurityTemplate $FileSecurityTemplate -ExpectedIdentity ([string]$marker.Identity)
        return [ordered]@{
            Name=$Name; Kind='File'; Path=[IO.Path]::GetFullPath($Path); Status='COMPLETE'
            Identity=[string]$marker.Identity; SecurityHash=[string]$securityEvidence.EvidenceHash
        }
    }
    catch {
        if ($_.Exception.Message -like 'home-authority-bootstrap-manual-recovery-required:*') { throw }
        throw "home-authority-bootstrap-manual-recovery-required: ${Name}: $($_.Exception.Message)"
    }
}

function Get-SealedHomeAuthorityBootstrapSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$DirectorySecurityTemplate,
        [Parameter(Mandatory)]$FileSecurityTemplate,
        $HeldGlobalLock,
        $HeldBootstrapLock
    )

    $bootstrapLockState = Get-HomeAuthorityLockFileState -Path ([string]$AuthorityContext.ControlBootstrapLockPath) -Name 'ControlBootstrapLock' -FileSecurityTemplate $FileSecurityTemplate -HeldLockHandle $HeldBootstrapLock
    $definitions = @(Get-HomeAuthorityBootstrapEntryDefinitions -AuthorityContext $AuthorityContext)
    $states = [Collections.Generic.List[object]]::new()
    foreach ($definition in $definitions) {
        $marker = Get-NoFollowRootEntryMarker -Path ([string]$definition.Path)
        if ([string]$marker.EntryType -ceq 'MISSING') {
            $states.Add([ordered]@{
                Order=[long]$definition.Order; Name=[string]$definition.Name; Kind=[string]$definition.Kind
                Path=[string]$definition.Path; Status='MISSING'; Identity=$null; SecurityHash=$null; ImmediateChildren=@()
            })
            continue
        }
        if ([string]$marker.EntryType -cne [string]$definition.Kind) {
            throw "home-authority-bootstrap-manual-recovery-required: wrong type for $($definition.Name)"
        }
        try {
            if ([string]$definition.Kind -ceq 'Directory') {
                $handlesReceiver2=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
                Open-SafeDirectoryContainmentChain -Path ([string]$definition.Path) -OwnershipReceiver $handlesReceiver2
                $handles = $handlesReceiver2.GetDeliveredExact()
                try {
                    $held = $handles[$handles.Count - 1]
                    if ([string]$held.Info.Identity -cne [string]$marker.Identity) { throw 'directory identity changed during capture' }
                    $securityBefore = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($held)
                    if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($held)).Count -ne 0) { throw 'directory has named streams' }
                    $children = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($held) | Sort-Object -CaseSensitive)
                    $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($held)
                    if ([string]$securityBefore.Identity -cne [string]$security.Identity -or [string]$securityBefore.Sddl -cne [string]$security.Sddl) { throw 'directory owner/DACL changed during capture' }
                    $securityEvidence = Assert-HomeAuthoritySecuritySnapshot -Snapshot $security -SecurityTemplate $DirectorySecurityTemplate -ExpectedIdentity ([string]$marker.Identity)
                    $states.Add([ordered]@{
                        Order=[long]$definition.Order; Name=[string]$definition.Name; Kind='Directory'
                        Path=[string]$definition.Path; Status='COMPLETE'; Identity=[string]$marker.Identity
                        SecurityHash=[string]$securityEvidence.EvidenceHash; ImmediateChildren=$children
                    })
                }
                finally { Close-SafeDirectoryContainmentChain -Handles $handles }
            }
            else {
                $lockState = Get-HomeAuthorityLockFileState -Path ([string]$definition.Path) -Name ([string]$definition.Name) -FileSecurityTemplate $FileSecurityTemplate -HeldLockHandle $HeldGlobalLock
                $states.Add([ordered]@{
                    Order=[long]$definition.Order; Name=[string]$definition.Name; Kind='File'
                    Path=[string]$definition.Path; Status=[string]$lockState.Status; Identity=[string]$lockState.Identity
                    SecurityHash=[string]$lockState.SecurityHash; ImmediateChildren=@()
                })
            }
        }
        catch {
            if ($_.Exception.Message -like 'home-authority-bootstrap-manual-recovery-required:*') { throw }
            throw "home-authority-bootstrap-manual-recovery-required: $($definition.Name): $($_.Exception.Message)"
        }
    }

    $missingSeen = $false
    foreach ($state in $states) {
        if ([string]$state.Status -ceq 'MISSING') { $missingSeen = $true; continue }
        if ($missingSeen) { throw 'home-authority-bootstrap-manual-recovery-required: non-prefix bootstrap state' }
    }
    foreach ($definition in @($definitions | Where-Object { [string]$_.Kind -ceq 'Directory' })) {
        $state = @($states | Where-Object { [string]$_.Name -ceq [string]$definition.Name })[0]
        if ([string]$state.Status -cne 'COMPLETE') { continue }
        $expectedChildren = [Collections.Generic.List[string]]::new()
        foreach ($childDefinition in $definitions) {
            if ([string]$childDefinition.ParentPath -cne [string]$definition.Path) { continue }
            $childState = @($states | Where-Object { [string]$_.Name -ceq [string]$childDefinition.Name })[0]
            if ([string]$childState.Status -ceq 'COMPLETE') { $expectedChildren.Add([string]$childDefinition.LeafName) }
        }
        $allowedExtra = [string[]]@()
        if ([string]$definition.Name -ceq 'ControlBase') { $allowedExtra = @('route-cleanup-recovery') }
        $actualOrdered = @($state.ImmediateChildren | Sort-Object -CaseSensitive)
        $expectedOrdered = @($expectedChildren | Sort-Object -CaseSensitive)
        $actualRequired = @($state.ImmediateChildren | Where-Object { $_ -cnotin $allowedExtra } | Sort-Object -CaseSensitive)
        if (($actualRequired -join "`0") -cne ($expectedOrdered -join "`0")) {
            throw "home-authority-bootstrap-manual-recovery-required: unexpected children under $($definition.Name)"
        }
    }
    $completeCount = @($states | Where-Object { [string]$_.Status -ceq 'COMPLETE' }).Count
    if ([string]$bootstrapLockState.Status -ceq 'MISSING' -and $completeCount -gt 0) { throw 'home-authority-bootstrap-manual-recovery-required: private prefix exists without bootstrap lock' }
    $status = if ([string]$bootstrapLockState.Status -ceq 'MISSING' -and $completeCount -eq 0) { 'MISSING' } elseif ([string]$bootstrapLockState.Status -ceq 'COMPLETE' -and $completeCount -eq $states.Count) { 'COMPLETE' } else { 'PARTIAL' }
    $projection = [ordered]@{ Status=$status; BootstrapLock=$bootstrapLockState; CompletePrefixLength=[long]$completeCount; Entries=@($states) }
    return [pscustomobject][ordered]@{
        Status = $status
        BootstrapLock = [pscustomobject]$bootstrapLockState
        CompletePrefixLength = [long]$completeCount
        Entries = @($states)
        SnapshotHash = Get-SemanticJsonHash -InputObject $projection
    }
}

function Get-SealedHomeAuthorityFixedEnvelopeContextHash {
    param([Parameter(Mandatory)]$AuthorityContext)

    return Get-SemanticJsonHash -InputObject ([ordered]@{
        TokenSid = [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'TokenSid')
        LocalAppDataRoot = [IO.Path]::GetFullPath([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'LocalAppDataRoot'))
        ControlBootstrapLockPath = [IO.Path]::GetFullPath([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'ControlBootstrapLockPath'))
        PrivateRootBase = [IO.Path]::GetFullPath([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'PrivateRootBase'))
        BackupRoot = [IO.Path]::GetFullPath([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'BackupRoot'))
        ControlBase = [IO.Path]::GetFullPath([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'ControlBase'))
        HomesRoot = [IO.Path]::GetFullPath([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'HomesRoot'))
        CanonicalRootsRoot = [IO.Path]::GetFullPath([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'CanonicalRootsRoot'))
        LiveTransactionsRoot = [IO.Path]::GetFullPath([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'LiveTransactionsRoot'))
        GlobalLiveLockPath = [IO.Path]::GetFullPath([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'GlobalLiveLockPath'))
    })
}

function Close-SealedHomeAuthorityFixedEnvelope {
    param([Parameter(Mandatory)]$EnvelopeLease)

    $observationOwnershipGuard='AiAgentDotfiles.SealedFixedEnvelopeOwnershipGuard' -as [type]
    if($null -ne $observationOwnershipGuard -and
        [AiAgentDotfiles.SealedFixedEnvelopeOwnershipGuard]::IsReservedExact($EnvelopeLease)){
        throw 'home-authority-fixed-envelope-lease-reserved'
    }
    if ([AiAgentDotfiles.SealedHomeAuthorityFixedEnvelopeCloseState]::GetIsClosedExact($EnvelopeLease)) { return }
    $leases = @($EnvelopeLease.DirectoryLeases)
    for ($index = $leases.Count - 1; $index -ge 0; $index--) {
        if ($null -ne $leases[$index].Handles) { Close-SafeDirectoryContainmentChain -Handles $leases[$index].Handles }
    }
    $null = [AiAgentDotfiles.SealedHomeAuthorityFixedEnvelopeCloseState]::MarkClosedExact($EnvelopeLease)
}

function Get-SealedHomeAuthorityFixedEnvelopeProjection {
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$DirectorySecurityTemplate,
        [Parameter(Mandatory)]$FileSecurityTemplate,
        [Parameter(Mandatory)]$EnvelopeLease,
        $HeldGlobalLock
    )

    $null = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
    if ([AiAgentDotfiles.SealedHomeAuthorityFixedEnvelopeCloseState]::GetIsClosedExact($EnvelopeLease) -or [string]$EnvelopeLease.ContextHash -cne (Get-SealedHomeAuthorityFixedEnvelopeContextHash -AuthorityContext $AuthorityContext)) {
        throw 'home-authority-fixed-envelope-lease-invalid'
    }
    $definitions = @(Get-HomeAuthorityBootstrapEntryDefinitions -AuthorityContext $AuthorityContext)
    $directoryDefinitions = @($definitions | Where-Object { [string]$_.Kind -ceq 'Directory' })
    $directoryLeases = @($EnvelopeLease.DirectoryLeases)
    if ($directoryLeases.Count -ne $directoryDefinitions.Count) { throw 'home-authority-fixed-envelope-lease-invalid' }

    $fixedChildren = @{
        PrivateRootBase = @('backups','control')
        ControlBase = @('canonical-roots','homes','live-mutation.lock','live-transactions','route-cleanup-recovery')
    }
    $fixedChildrenRequired = @{
        PrivateRootBase = @('backups','control')
        ControlBase = @('canonical-roots','homes','live-mutation.lock','live-transactions')
    }
    $directoryStates = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $directoryDefinitions.Count; $index++) {
        $definition = $directoryDefinitions[$index]
        $lease = $directoryLeases[$index]
        if ([string]$lease.Name -cne [string]$definition.Name -or [string]$lease.Path -cne [IO.Path]::GetFullPath([string]$definition.Path) -or $lease.Held -isnot [AiAgentDotfiles.SafeDirectoryHandle]) {
            throw 'home-authority-fixed-envelope-lease-invalid'
        }
        $marker = Get-NoFollowRootEntryMarker -Path ([string]$definition.Path)
        if ([string]$marker.EntryType -cne 'Directory' -or [string]$marker.Identity -cne [string]$lease.Identity) {
            throw "home-authority-fixed-envelope-manual-recovery-required: identity or type drift for $($definition.Name)"
        }
        try {
            $securityBefore = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($lease.Held)
            if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($lease.Held)).Count -ne 0) { throw 'directory has named streams' }
            $immediateEnvelopeChildren = $null
            if ($fixedChildren.ContainsKey([string]$definition.Name)) {
                $immediateEnvelopeChildren = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($lease.Held) | Sort-Object -CaseSensitive)
                $expected = @($fixedChildren[[string]$definition.Name] | Sort-Object -CaseSensitive)
                $required = @($fixedChildrenRequired[[string]$definition.Name] | Sort-Object -CaseSensitive)
                if (@($immediateEnvelopeChildren | Where-Object { $_ -cnotin $expected }).Count -ne 0 -or
                    @($required | Where-Object { $_ -cnotin $immediateEnvelopeChildren }).Count -ne 0) {
                    throw 'unexpected immediate envelope children'
                }
            }
            $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($lease.Held)
            if ([string]$securityBefore.Identity -cne [string]$security.Identity -or [string]$securityBefore.Sddl -cne [string]$security.Sddl) { throw 'directory owner/DACL changed during capture' }
            $securityEvidence = Assert-HomeAuthoritySecuritySnapshot -Snapshot $security -SecurityTemplate $DirectorySecurityTemplate -ExpectedIdentity ([string]$lease.Identity)
            $directoryStates.Add([ordered]@{
                Order=[long]$definition.Order; Name=[string]$definition.Name; Path=[IO.Path]::GetFullPath([string]$definition.Path)
                Identity=[string]$lease.Identity; SecurityHash=[string]$securityEvidence.EvidenceHash
                ImmediateEnvelopeChildren=if($null -eq $immediateEnvelopeChildren){$null}else{@($immediateEnvelopeChildren)}
            })
        }
        catch {
            if ($_.Exception.Message -like 'home-authority-fixed-envelope-manual-recovery-required:*') { throw }
            throw "home-authority-fixed-envelope-manual-recovery-required: $($definition.Name): $($_.Exception.Message)"
        }
    }

    $bootstrapLockState = Get-HomeAuthorityLockFileState -Path ([string]$AuthorityContext.ControlBootstrapLockPath) -Name 'ControlBootstrapLock' -FileSecurityTemplate $FileSecurityTemplate
    if ([string]$bootstrapLockState.Status -cne 'COMPLETE') { throw 'home-authority-fixed-envelope-manual-recovery-required: bootstrap lock is missing' }
    $globalLockState = Get-HomeAuthorityLockFileState -Path ([string]$AuthorityContext.GlobalLiveLockPath) -Name 'GlobalLiveLock' -FileSecurityTemplate $FileSecurityTemplate -HeldLockHandle $HeldGlobalLock
    if ([string]$globalLockState.Status -cne 'COMPLETE') { throw 'global-live-lock-missing' }
    $projection = [ordered]@{
        BootstrapLock = $bootstrapLockState
        Directories = @($directoryStates)
        GlobalLiveLock = $globalLockState
    }
    return [pscustomobject][ordered]@{
        Projection = $projection
        EnvelopeHash = Get-SemanticJsonHash -InputObject $projection
        Directories = @($directoryStates)
        BootstrapLock = [pscustomobject]$bootstrapLockState
        GlobalLiveLock = [pscustomobject]$globalLockState
    }
}

function Open-SealedHomeAuthorityFixedEnvelope {
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$DirectorySecurityTemplate,
        [Parameter(Mandatory)]$FileSecurityTemplate,
        $HeldGlobalLock
    )

    $null = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
    $definitions = @(Get-HomeAuthorityBootstrapEntryDefinitions -AuthorityContext $AuthorityContext)
    $bootstrapLockState = Get-HomeAuthorityLockFileState -Path ([string]$AuthorityContext.ControlBootstrapLockPath) -Name 'ControlBootstrapLock' -FileSecurityTemplate $FileSecurityTemplate
    $markers = [Collections.Generic.List[object]]::new()
    $missingSeen = $false
    $completeCount = 0
    foreach ($definition in $definitions) {
        $marker = Get-NoFollowRootEntryMarker -Path ([string]$definition.Path)
        if ([string]$marker.EntryType -ceq 'MISSING') {
            $missingSeen = $true
        }
        else {
            if ([string]$marker.EntryType -cne [string]$definition.Kind) { throw "home-authority-fixed-envelope-manual-recovery-required: wrong type for $($definition.Name)" }
            if ($missingSeen) { throw 'home-authority-fixed-envelope-manual-recovery-required: non-prefix bootstrap state' }
            $completeCount++
        }
        $markers.Add([pscustomobject][ordered]@{ Definition=$definition; Marker=$marker })
    }
    if ([string]$bootstrapLockState.Status -ceq 'MISSING' -and $completeCount -gt 0) { throw 'home-authority-fixed-envelope-manual-recovery-required: private prefix exists without bootstrap lock' }
    if ($completeCount -lt $definitions.Count) {
        if ($completeCount -eq ($definitions.Count - 1) -and [string]$markers[$markers.Count - 1].Marker.EntryType -ceq 'MISSING') { throw 'global-live-lock-missing' }
        throw 'home-authority-bootstrap-incomplete'
    }
    if ([string]$bootstrapLockState.Status -cne 'COMPLETE') { throw 'home-authority-bootstrap-incomplete' }

    $directoryLeases = [Collections.Generic.List[object]]::new()
    $lease = $null
    try {
        foreach ($row in @($markers | Where-Object { [string]$_.Definition.Kind -ceq 'Directory' })) {
            $handlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
            Open-SafeDirectoryContainmentChain -Path ([string]$row.Definition.Path) -OwnershipReceiver $handlesReceiver
            $handles = $handlesReceiver.GetDeliveredExact()
            $held = $handles[$handles.Count - 1]
            if ([string]$held.Info.Identity -cne [string]$row.Marker.Identity) {
                Close-SafeDirectoryContainmentChain -Handles $handles
                throw "home-authority-fixed-envelope-manual-recovery-required: directory identity changed while opening $($row.Definition.Name)"
            }
            $directoryLeases.Add([pscustomobject][ordered]@{
                Name=[string]$row.Definition.Name; Path=[IO.Path]::GetFullPath([string]$row.Definition.Path)
                Identity=[string]$row.Marker.Identity; Handles=$handles; Held=$held
            })
        }
        $lease = [pscustomobject][ordered]@{
            ContextHash = Get-SealedHomeAuthorityFixedEnvelopeContextHash -AuthorityContext $AuthorityContext
            DirectoryLeases = @($directoryLeases)
            InitialProjection = $null
            InitialEnvelopeHash = $null
        }
        [AiAgentDotfiles.SealedHomeAuthorityFixedEnvelopeCloseState]::BindExact($lease)
        $initial = Get-SealedHomeAuthorityFixedEnvelopeProjection -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $DirectorySecurityTemplate -FileSecurityTemplate $FileSecurityTemplate -EnvelopeLease $lease -HeldGlobalLock $HeldGlobalLock
        $lease.InitialProjection = $initial.Projection
        $lease.InitialEnvelopeHash = [string]$initial.EnvelopeHash
        return $lease
    }
    catch {
        if ($null -ne $lease) { Close-SealedHomeAuthorityFixedEnvelope -EnvelopeLease $lease }
        else {
            for ($index = $directoryLeases.Count - 1; $index -ge 0; $index--) { Close-SafeDirectoryContainmentChain -Handles $directoryLeases[$index].Handles }
        }
        throw
    }
}

function New-SealedHomeAuthorityBootstrapIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$AuthorityContext,[Parameter(Mandatory)][string]$FilesystemCapabilityHash)

    if ($FilesystemCapabilityHash -notmatch '\A[0-9a-f]{64}\z') { throw 'home-authority-bootstrap-capability-hash-invalid' }
    $validated = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
    $sid = [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'TokenSid')
    $directoryTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind Directory
    $fileTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind File
    $parent = Resolve-TargetContext -Path ([string]$validated.LocalAppDataRoot) -Mode MetadataOnly
    if ([string]$parent.TargetStatus -cne 'EXISTS' -or [string]$parent.TargetType -cne 'Directory') { throw 'home-authority-bootstrap-known-folder-parent-unavailable' }
    $snapshot = Get-SealedHomeAuthorityBootstrapSnapshot -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate
    $definitions = @(Get-HomeAuthorityBootstrapEntryDefinitions -AuthorityContext $AuthorityContext)
    $entryIntents = [Collections.Generic.List[object]]::new()
    foreach ($definition in $definitions) {
        $state = @($snapshot.Entries | Where-Object { [string]$_.Name -ceq [string]$definition.Name })[0]
        $entryIntents.Add([ordered]@{
            Order=[long]$definition.Order; Name=[string]$definition.Name; Kind=[string]$definition.Kind
            RelativePath=[IO.Path]::GetRelativePath([string]$validated.LocalAppDataRoot,[string]$definition.Path).Replace([char]92,[char]47)
            InitialStatus=[string]$state.Status; InitialIdentity=if([string]$state.Status -ceq 'COMPLETE'){[string]$state.Identity}else{$null}
            InitialSecurityHash=if([string]$state.Status -ceq 'COMPLETE'){[string]$state.SecurityHash}else{$null}
            ExpectedFinalChildren=@($definition.ExpectedFinalChildren)
        })
    }
    $payload = [ordered]@{
        SchemaVersion = [long]$script:HomeAuthorityBootstrapIntentSchemaVersion
        ArtifactKind = $script:HomeAuthorityBootstrapIntentArtifactKind
        ResolverVersion = [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'ResolverVersion')
        IdentityResolverVersion = [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'IdentityResolverVersion')
        TokenSid = $sid
        HomeAuthorityKey = [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'HomeAuthorityKey')
        ControlBootstrapLockKey = [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'ControlBootstrapLockKey')
        LocalAppDataRoot = [string]$validated.LocalAppDataRoot
        LocalAppDataRootLocationKey = ConvertTo-HomeAuthorityLocationKey -Path ([string]$validated.LocalAppDataRoot)
        LocalAppDataRootIdentity = [string]$parent.DeepestExistingParentIdentity
        ControlBootstrapLockPath = [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'ControlBootstrapLockPath')
        ControlRemainder = @('ai-agent-dotfiles','control')
        BackupRemainder = @('ai-agent-dotfiles','backups')
        DirectorySecurityTemplate = $directoryTemplate
        DirectorySecurityTemplateHash = Get-SemanticJsonHash -InputObject $directoryTemplate
        LockFileSecurityTemplate = $fileTemplate
        LockFileSecurityTemplateHash = Get-SemanticJsonHash -InputObject $fileTemplate
        FilesystemCapabilityHash = $FilesystemCapabilityHash
        BootstrapLockInitialStatus = [string]$snapshot.BootstrapLock.Status
        BootstrapLockInitialIdentity = if([string]$snapshot.BootstrapLock.Status -ceq 'COMPLETE'){[string]$snapshot.BootstrapLock.Identity}else{$null}
        BootstrapLockInitialSecurityHash = if([string]$snapshot.BootstrapLock.Status -ceq 'COMPLETE'){[string]$snapshot.BootstrapLock.SecurityHash}else{$null}
        InitialBootstrapStatus = [string]$snapshot.Status
        InitialCompletePrefixLength = [long]$snapshot.CompletePrefixLength
        ExpectedEntries = @($entryIntents)
    }
    $result = [ordered]@{}
    foreach ($key in $payload.Keys) { $result[$key] = $payload[$key] }
    $result.IntentHash = Get-SemanticJsonHash -InputObject $payload
    return [pscustomobject]$result
}

function Assert-SealedHomeAuthorityBootstrapIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$AuthorityContext,[Parameter(Mandatory)]$Intent,$HeldGlobalLock,$HeldBootstrapLock)

    $fields = @('SchemaVersion','ArtifactKind','ResolverVersion','IdentityResolverVersion','TokenSid','HomeAuthorityKey','ControlBootstrapLockKey','LocalAppDataRoot','LocalAppDataRootLocationKey','LocalAppDataRootIdentity','ControlBootstrapLockPath','ControlRemainder','BackupRemainder','DirectorySecurityTemplate','DirectorySecurityTemplateHash','LockFileSecurityTemplate','LockFileSecurityTemplateHash','FilesystemCapabilityHash','BootstrapLockInitialStatus','BootstrapLockInitialIdentity','BootstrapLockInitialSecurityHash','InitialBootstrapStatus','InitialCompletePrefixLength','ExpectedEntries','IntentHash')
    Assert-HomeAuthorityExactPropertySet -InputObject $Intent -Expected $fields -Label 'intent'
    $payload = [ordered]@{}
    foreach ($field in $fields | Where-Object { $_ -cne 'IntentHash' }) { $payload[$field] = Get-HomeAuthorityObjectProperty -InputObject $Intent -Name $field -AllowNull }
    if ([long]$payload.SchemaVersion -ne $script:HomeAuthorityBootstrapIntentSchemaVersion -or [string]$payload.ArtifactKind -cne $script:HomeAuthorityBootstrapIntentArtifactKind) { throw 'home-authority-bootstrap-intent-version-invalid' }
    if ([string]$Intent.IntentHash -cne (Get-SemanticJsonHash -InputObject $payload)) { throw 'home-authority-bootstrap-intent-hash-mismatch' }
    $validated = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
    foreach ($field in @('ResolverVersion','IdentityResolverVersion','TokenSid','HomeAuthorityKey','ControlBootstrapLockKey','ControlBootstrapLockPath')) {
        if ([string]$payload[$field] -cne [string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name $field)) { throw "home-authority-bootstrap-intent-context-mismatch: $field" }
    }
    if ([string]$payload.LocalAppDataRoot -cne [string]$validated.LocalAppDataRoot -or [string]$payload.LocalAppDataRootLocationKey -cne (ConvertTo-HomeAuthorityLocationKey -Path ([string]$validated.LocalAppDataRoot))) { throw 'home-authority-bootstrap-intent-known-folder-mismatch' }
    if ((@($payload.ControlRemainder) -join '/') -cne 'ai-agent-dotfiles/control' -or (@($payload.BackupRemainder) -join '/') -cne 'ai-agent-dotfiles/backups') { throw 'home-authority-bootstrap-intent-remainder-mismatch' }
    if ([string]$payload.FilesystemCapabilityHash -notmatch '\A[0-9a-f]{64}\z') { throw 'home-authority-bootstrap-capability-hash-invalid' }
    $parent = Resolve-TargetContext -Path ([string]$validated.LocalAppDataRoot) -Mode MetadataOnly
    if ([string]$parent.TargetStatus -cne 'EXISTS' -or [string]$parent.DeepestExistingParentIdentity -cne [string]$payload.LocalAppDataRootIdentity) { throw 'home-authority-bootstrap-parent-identity-drift' }
    $directoryTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid ([string]$payload.TokenSid) -ResourceKind Directory
    $fileTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid ([string]$payload.TokenSid) -ResourceKind File
    if ([string]$payload.DirectorySecurityTemplateHash -cne (Get-SemanticJsonHash -InputObject $directoryTemplate) -or [string]$payload.DirectorySecurityTemplateHash -cne (Get-SemanticJsonHash -InputObject $payload.DirectorySecurityTemplate)) { throw 'home-authority-bootstrap-directory-template-drift' }
    if ([string]$payload.LockFileSecurityTemplateHash -cne (Get-SemanticJsonHash -InputObject $fileTemplate) -or [string]$payload.LockFileSecurityTemplateHash -cne (Get-SemanticJsonHash -InputObject $payload.LockFileSecurityTemplate)) { throw 'home-authority-bootstrap-lock-template-drift' }
    if ([string]$payload.BootstrapLockInitialStatus -notin @('MISSING','COMPLETE')) { throw 'home-authority-bootstrap-lock-initial-status-invalid' }
    if ([string]$payload.BootstrapLockInitialStatus -ceq 'MISSING') {
        if ($null -ne $payload.BootstrapLockInitialIdentity -or $null -ne $payload.BootstrapLockInitialSecurityHash) { throw 'home-authority-bootstrap-missing-lock-has-identity' }
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$payload.BootstrapLockInitialIdentity) -or [string]$payload.BootstrapLockInitialSecurityHash -notmatch '\A[0-9a-f]{64}\z') { throw 'home-authority-bootstrap-lock-initial-evidence-invalid' }

    $definitions = @(Get-HomeAuthorityBootstrapEntryDefinitions -AuthorityContext $AuthorityContext)
    $entryIntents = @($payload.ExpectedEntries)
    if ($entryIntents.Count -ne $definitions.Count) { throw 'home-authority-bootstrap-entry-count-mismatch' }
    $initialComplete = 0
    $initialMissingSeen = $false
    for ($index = 0; $index -lt $definitions.Count; $index++) {
        $definition = $definitions[$index]
        $entry = $entryIntents[$index]
        Assert-HomeAuthorityExactPropertySet -InputObject $entry -Expected @('Order','Name','Kind','RelativePath','InitialStatus','InitialIdentity','InitialSecurityHash','ExpectedFinalChildren') -Label "entry-$index"
        if ([long]$entry.Order -ne [long]$definition.Order -or [string]$entry.Name -cne [string]$definition.Name -or [string]$entry.Kind -cne [string]$definition.Kind) { throw 'home-authority-bootstrap-entry-definition-mismatch' }
        $relative = [IO.Path]::GetRelativePath([string]$validated.LocalAppDataRoot,[string]$definition.Path).Replace([char]92,[char]47)
        if ([string]$entry.RelativePath -cne $relative -or (@($entry.ExpectedFinalChildren) -join "`0") -cne (@($definition.ExpectedFinalChildren) -join "`0")) { throw 'home-authority-bootstrap-entry-path-mismatch' }
        if ([string]$entry.InitialStatus -notin @('MISSING','COMPLETE')) { throw 'home-authority-bootstrap-entry-status-invalid' }
        if ([string]$entry.InitialStatus -ceq 'MISSING') {
            $initialMissingSeen = $true
            if ($null -ne $entry.InitialIdentity -or $null -ne $entry.InitialSecurityHash) { throw 'home-authority-bootstrap-missing-entry-has-identity' }
        }
        else {
            if ($initialMissingSeen -or [string]::IsNullOrWhiteSpace([string]$entry.InitialIdentity) -or [string]$entry.InitialSecurityHash -notmatch '\A[0-9a-f]{64}\z') { throw 'home-authority-bootstrap-initial-prefix-invalid' }
            $initialComplete++
        }
    }
    $initialStatus = if ([string]$payload.BootstrapLockInitialStatus -ceq 'MISSING' -and $initialComplete -eq 0) { 'MISSING' } elseif ([string]$payload.BootstrapLockInitialStatus -ceq 'COMPLETE' -and $initialComplete -eq $definitions.Count) { 'COMPLETE' } else { 'PARTIAL' }
    if ([long]$payload.InitialCompletePrefixLength -ne $initialComplete -or [string]$payload.InitialBootstrapStatus -cne $initialStatus) { throw 'home-authority-bootstrap-initial-summary-mismatch' }
    $current = Get-SealedHomeAuthorityBootstrapSnapshot -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate -HeldGlobalLock $HeldGlobalLock -HeldBootstrapLock $HeldBootstrapLock
    if ([string]$payload.BootstrapLockInitialStatus -ceq 'COMPLETE') {
        if ([string]$current.BootstrapLock.Status -cne 'COMPLETE' -or [string]$current.BootstrapLock.Identity -cne [string]$payload.BootstrapLockInitialIdentity -or [string]$current.BootstrapLock.SecurityHash -cne [string]$payload.BootstrapLockInitialSecurityHash) { throw 'home-authority-bootstrap-reviewed-lock-drift' }
    }
    for ($index = 0; $index -lt $definitions.Count; $index++) {
        $initial = $entryIntents[$index]
        $actual = $current.Entries[$index]
        if ([string]$initial.InitialStatus -ceq 'COMPLETE') {
            if ([string]$actual.Status -cne 'COMPLETE' -or [string]$actual.Identity -cne [string]$initial.InitialIdentity -or [string]$actual.SecurityHash -cne [string]$initial.InitialSecurityHash) { throw 'home-authority-bootstrap-reviewed-entry-drift' }
        }
    }
    return $current
}

function Get-HomeAuthorityWin32ErrorCode {
    param([Parameter(Mandatory)][Exception]$Exception)
    $cursor = $Exception
    while ($null -ne $cursor) {
        if ($cursor -is [ComponentModel.Win32Exception]) { return [int]$cursor.NativeErrorCode }
        if ($null -eq $cursor.InnerException) { break }
        $cursor = $cursor.InnerException
    }
    return [int]($Exception.HResult -band 0xFFFF)
}

function Register-HomeAuthorityLockResourceOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$LockHandle,
        [Parameter(Mandatory)][AiAgentDotfiles.SafeLockFileHandle]$HeldLock,
        [Parameter(Mandatory)][object[]]$ParentHandles,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SecurityHash
    )

    if (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($HeldLock) -or @($ParentHandles).Count -lt 1) { throw 'home-authority-lock-owner-required' }
    $parentIdentities = [Collections.Generic.List[string]]::new()
    $parentLinkCounts = [Collections.Generic.List[uint32]]::new()
    foreach ($parent in @($ParentHandles)) {
        if ($parent -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($parent)) { throw 'home-authority-lock-owner-required' }
        $parentIdentities.Add([AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($parent))
        $parentLinkCounts.Add([AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredLinkCountExact($parent))
    }
    return [AiAgentDotfiles.SafeLockResourceOwner]::BindExact(
        $LockHandle,
        $HeldLock,
        [object[]]@($ParentHandles),
        [AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($HeldLock),
        [AiAgentDotfiles.SafeLockFileHandle]::GetStreamViewExact($HeldLock),
        [IO.Path]::GetFullPath($Path),
        $null,
        $SecurityHash,
        [AiAgentDotfiles.SafeLockFileHandle]::GetAcquisitionOrdinalExact($HeldLock),
        [AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact($HeldLock),
        [AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLinkCountExact($HeldLock),
        [AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLengthExact($HeldLock),
        [string[]]$parentIdentities.ToArray(),
        [uint32[]]$parentLinkCounts.ToArray())
}

function Close-HomeAuthorityLockResourceOwner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AiAgentDotfiles.SafeLockResourceOwner]$Owner)
    [AiAgentDotfiles.SafeLockResourceOwner]::ReleaseExact($Owner)
}

function Test-HomeAuthorityLockResourceOwnerDisplay {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$LockHandle,[Parameter(Mandatory)][AiAgentDotfiles.SafeLockResourceOwner]$Owner)

    try {
        if ('AiAgentDotfiles.HomeAuthorityLockHandle' -cnotin @($LockHandle.PSObject.TypeNames) -or
            -not [AiAgentDotfiles.SafeLockResourceOwner]::IsExactForWrapper($Owner,$LockHandle)) { return $false }
        $display = [ordered]@{}
        foreach ($name in @('Path','HeldLock','ParentHandles','Info','SecurityHash')) {
            $property = $LockHandle.PSObject.Properties[$name]
            if ($null -eq $property) { return $false }
            $display[$name] = $property.Value
            if ($null -eq $display[$name]) { return $false }
        }
        $held = [AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($Owner)
        $parents = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($Owner))
        if (-not [object]::ReferenceEquals($display.HeldLock,$held) -or
            -not [object]::ReferenceEquals($display.Info,[AiAgentDotfiles.SafeLockResourceOwner]::GetInfoExact($Owner)) -or
            -not ([IO.Path]::GetFullPath([string]$display.Path)).Equals([AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($Owner),[StringComparison]::OrdinalIgnoreCase) -or
            [string]$display.SecurityHash -cne [AiAgentDotfiles.SafeLockResourceOwner]::GetSecurityHashExact($Owner)) { return $false }
        $displayParents = @($display.ParentHandles)
        if ($displayParents.Count -ne $parents.Count) { return $false }
        for ($index=0; $index -lt $parents.Count; $index++) {
            if (-not [object]::ReferenceEquals($displayParents[$index],$parents[$index])) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Enter-HomeAuthorityLockFileCore {
    param(
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)]$FileSecurityTemplate,
        [Parameter(Mandatory)][ValidateSet('OpenExisting','CreateNew','OpenOrCreate')][string]$Mode,
        [Parameter(Mandatory)][string]$MissingToken,
        [string]$ExpectedParentIdentity
    )

    $fullParent = [IO.Path]::GetFullPath($ParentPath)
    $fullLock = [IO.Path]::GetFullPath($LockPath)
    if ([string](Split-Path -Parent $fullLock) -cne $fullParent) { throw 'home-authority-lock-parent-mismatch' }
    $parents = $null
    $held = $null
    $resourceOwner = $null
    try {
        try { $parentsReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new(); Open-SafeDirectoryContainmentChain -Path $fullParent -OwnershipReceiver $parentsReceiver; $parents = $parentsReceiver.GetDeliveredExact() }
        catch { if ($_.Exception.Message -match 'missing') { throw $MissingToken }; throw }
        $parentHandle = $parents[$parents.Count - 1]
        if ($ExpectedParentIdentity -and [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($parentHandle) -cne $ExpectedParentIdentity) { throw 'home-authority-lock-parent-identity-drift' }
        $leaf = [IO.Path]::GetFileName($fullLock)
        $sddl = ConvertTo-HomeAuthoritySecurityDescriptorSddl -SecurityTemplate $FileSecurityTemplate
        try {
            $held = switch ($Mode) {
                'OpenExisting' { [AiAgentDotfiles.NoFollowFile]::OpenChildLockFile($parentHandle,$leaf); break }
                'CreateNew' { [AiAgentDotfiles.NoFollowFile]::CreateChildLockFileWithSecurityDescriptor($parentHandle,$leaf,$sddl); break }
                'OpenOrCreate' { [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFileWithSecurityDescriptor($parentHandle,$leaf,$sddl); break }
            }
        }
        catch {
            $code = Get-HomeAuthorityWin32ErrorCode -Exception $_.Exception
            if ($code -in @(32,33)) { throw 'operation-lock-busy' }
            if ($Mode -ceq 'OpenExisting' -and $code -in @(2,3)) { throw $MissingToken }
            if ($Mode -ceq 'CreateNew' -and $code -in @(80,183)) { throw 'home-authority-bootstrap-manual-recovery-required: unexpected lock creation collision' }
            throw
        }
        if ([long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLengthExact($held) -ne 0) { throw 'home-authority-bootstrap-manual-recovery-required: lock file is not empty' }
        $security = [AiAgentDotfiles.NoFollowFile]::GetLockFileSecuritySnapshot($held)
        $securityEvidence = Assert-HomeAuthoritySecuritySnapshot -Snapshot $security -SecurityTemplate $FileSecurityTemplate -ExpectedIdentity ([AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact($held))
        $result = [pscustomobject][ordered]@{
            Path=$fullLock; HeldLock=$held; ParentHandles=$parents; Info=[AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($held)
            SecurityHash=[string]$securityEvidence.EvidenceHash
        }
        $result.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.HomeAuthorityLockHandle')
        $resourceOwner = Register-HomeAuthorityLockResourceOwner -LockHandle $result -HeldLock $held -ParentHandles @($parents) -Path $fullLock -SecurityHash ([string]$securityEvidence.EvidenceHash)
        return $result
    }
    catch {
        if ($null -ne $resourceOwner) { try { Close-HomeAuthorityLockResourceOwner -Owner $resourceOwner } catch {} }
        else {
            if ($null -ne $held) { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($held) }
            if ($null -ne $parents) { Close-SafeDirectoryContainmentChain -Handles $parents }
        }
        throw
    }
}

function Exit-HomeAuthorityLockHandle {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$LockHandle)
    $owner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($LockHandle)
    if ($owner -isnot [AiAgentDotfiles.SafeLockResourceOwner]) { throw 'home-authority-lock-owner-required' }
    $displayValid = Test-HomeAuthorityLockResourceOwnerDisplay -LockHandle $LockHandle -Owner $owner
    Close-HomeAuthorityLockResourceOwner -Owner $owner
    if (-not $displayValid) { throw 'home-authority-lock-owner-required' }
}

function Enter-SealedHomeAuthorityBootstrapLock {
    param([Parameter(Mandatory)]$AuthorityContext,[Parameter(Mandatory)]$Intent)

    $null = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
    $fileTemplate = Get-HomeAuthorityObjectProperty -InputObject $Intent -Name 'LockFileSecurityTemplate'
    return Enter-HomeAuthorityLockFileCore -ParentPath ([string]$Intent.LocalAppDataRoot) -LockPath ([string]$Intent.ControlBootstrapLockPath) -FileSecurityTemplate $fileTemplate -Mode OpenOrCreate -MissingToken 'home-authority-bootstrap-known-folder-parent-unavailable' -ExpectedParentIdentity ([string]$Intent.LocalAppDataRootIdentity)
}

function Copy-HomeAuthoritySemanticValueOnce {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) { return $Value }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { throw 'home-authority-capture-forbids-floating-point' }
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            if ($key -isnot [string] -or $result.Contains([string]$key)) { throw 'home-authority-capture-invalid-object-key' }
            $captured = $Value[$key]
            $result[[string]$key] = Copy-HomeAuthoritySemanticValueOnce -Value $captured
        }
        return $result
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            if ($property.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty) { throw 'home-authority-capture-stateful-property' }
            if ($result.Contains([string]$property.Name)) { throw 'home-authority-capture-duplicate-property' }
            $captured = $property.Value
            $result[[string]$property.Name] = Copy-HomeAuthoritySemanticValueOnce -Value $captured
        }
        return $result
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((Copy-HomeAuthoritySemanticValueOnce -Value $item)) }
        return ,([object[]]$items.ToArray())
    }
    throw "home-authority-capture-unsupported-value: $($Value.GetType().FullName)"
}

function Get-HomeAuthorityNotePropertyMapOnce {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$InputObject,[Parameter(Mandatory)][string]$Label)

    if ($InputObject -isnot [Management.Automation.PSCustomObject]) { throw "${Label}-object-required" }
    $result = [ordered]@{}
    foreach ($property in @($InputObject.PSObject.Properties)) {
        if ($property.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty) { throw "${Label}-stateful-property" }
        if ($result.Contains([string]$property.Name)) { throw "${Label}-duplicate-property" }
        $result[[string]$property.Name] = $property.Value
    }
    return $result
}

function Copy-HomeAuthorityCanonicalDirectoryCaptureOnce {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Capture)

    $values = Get-HomeAuthorityNotePropertyMapOnce -InputObject $Capture -Label 'canonical-directory-capture'
    foreach ($name in @('Path','Label','Handles','Projection','ProjectionHash','IsClosed')) {
        if (-not $values.Contains($name) -or $null -eq $values[$name]) { throw "canonical-directory-capture-missing-$name" }
    }
    $snapshot = [pscustomobject][ordered]@{
        Path = [string]$values.Path
        Label = [string]$values.Label
        Handles = [object[]]@($values.Handles)
        Projection = Copy-HomeAuthoritySemanticValueOnce -Value $values.Projection
        ProjectionHash = [string]$values.ProjectionHash
        IsClosed = [bool]$values.IsClosed
    }
    $snapshot.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalHeldDirectoryChainCapture')
    return $snapshot
}

function Copy-HomeAuthorityCanonicalSetupStateCaptureOnce {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Capture)

    $values = Get-HomeAuthorityNotePropertyMapOnce -InputObject $Capture -Label 'canonical-setup-state-capture'
    foreach ($name in @('Path','Handle','Identity','Length','Bytes','BytesHash','SemanticHash','SecuritySddl','SecurityHash','Document','SchemaPath','RepoId','GitCommonDirHash','TokenSid','ProjectionHash','IsClosed')) {
        if (-not $values.Contains($name) -or $null -eq $values[$name]) { throw "canonical-setup-state-capture-missing-$name" }
    }
    $snapshot = [pscustomobject][ordered]@{
        Path = [string]$values.Path
        Handle = $values.Handle
        Identity = [string]$values.Identity
        Length = [long]$values.Length
        Bytes = [byte[]]@($values.Bytes)
        BytesHash = [string]$values.BytesHash
        SemanticHash = [string]$values.SemanticHash
        SecuritySddl = [string]$values.SecuritySddl
        SecurityHash = [string]$values.SecurityHash
        Document = Copy-HomeAuthoritySemanticValueOnce -Value $values.Document
        SchemaPath = [string]$values.SchemaPath
        RepoId = [string]$values.RepoId
        GitCommonDirHash = [string]$values.GitCommonDirHash
        TokenSid = [string]$values.TokenSid
        ProjectionHash = [string]$values.ProjectionHash
        IsClosed = [bool]$values.IsClosed
    }
    $snapshot.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalHeldSetupStateCapture')
    return $snapshot
}

function Copy-HomeAuthorityCanonicalWitnessOnce {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$CanonicalWitness)

    if ('AiAgentDotfiles.CanonicalNamespaceWitness' -cnotin @($CanonicalWitness.PSObject.TypeNames)) { throw 'canonical witness type is invalid' }
    $values = Get-HomeAuthorityNotePropertyMapOnce -InputObject $CanonicalWitness -Label 'canonical-witness'
    foreach ($name in @('RepoRoot','CanonicalLockHandle','WitnessHash')) {
        if (-not $values.Contains($name) -or $null -eq $values[$name]) { throw "canonical-witness-missing-$name" }
    }
    foreach ($name in @('RepoRootCapture','GitDirCapture','GitCommonDirCapture','ContractRootCapture')) {
        if ($values.Contains($name)) { $values[$name] = Copy-HomeAuthorityCanonicalDirectoryCaptureOnce -Capture $values[$name] }
    }
    if ($values.Contains('SetupStateCapture')) { $values.SetupStateCapture = Copy-HomeAuthorityCanonicalSetupStateCaptureOnce -Capture $values.SetupStateCapture }
    if ($values.Contains('SetupStateDocument')) { $values.SetupStateDocument = Copy-HomeAuthoritySemanticValueOnce -Value $values.SetupStateDocument }
    if ($values.Contains('SetupStateBytes')) { $values.SetupStateBytes = [byte[]]@($values.SetupStateBytes) }
    if ($values.Contains('CanonicalTransactionSetProjection')) { $values.CanonicalTransactionSetProjection = Copy-HomeAuthoritySemanticValueOnce -Value $values.CanonicalTransactionSetProjection }
    if ($values.Contains('ContractRootInitialNames')) { $values.ContractRootInitialNames = [string[]]@($values.ContractRootInitialNames) }
    $snapshot = [pscustomobject]$values
    $snapshot.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalNamespaceWitness')
    return $snapshot
}

function Get-HomeAuthoritySha256Hex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-HomeAuthorityCanonicalWitnessCaptureProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$WitnessSnapshot,
        [Parameter(Mandatory)][AiAgentDotfiles.SafeLockResourceOwner]$CanonicalOwner
    )

    $resolver = [string](Get-HomeAuthorityObjectProperty -InputObject $WitnessSnapshot -Name 'ResolverVersion')
    if ($resolver -ceq 'home-authority-binding-test-witness-v1') {
        return [ordered]@{
            ResolverVersion = $resolver
            RepoRoot = [IO.Path]::GetFullPath([string]$WitnessSnapshot.RepoRoot)
            CanonicalLockPath = [AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($CanonicalOwner)
            CanonicalLockIdentity = [AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredIdentityExact($CanonicalOwner)
            CanonicalLockOrdinal = [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquisitionOrdinalExact($CanonicalOwner)
        }
    }
    if ($resolver -cne 'windows-no-follow-canonical-namespace-witness-v1') { throw 'canonical witness resolver is invalid' }
    return [ordered]@{
        ResolverVersion = $resolver
        TokenSid = [string]$WitnessSnapshot.TokenSid
        RepoRoot = [string]$WitnessSnapshot.RepoRoot
        RepoRootPath = [string]$WitnessSnapshot.RepoRootPath
        RepoRootChainHash = [string]$WitnessSnapshot.RepoRootCapture.ProjectionHash
        GitDir = [string]$WitnessSnapshot.GitDir
        GitDirPath = [string]$WitnessSnapshot.GitDirPath
        GitDirChainHash = [string]$WitnessSnapshot.GitDirCapture.ProjectionHash
        GitCommonDir = [string]$WitnessSnapshot.GitCommonDir
        GitCommonDirPath = [string]$WitnessSnapshot.GitCommonDirPath
        GitCommonDirChainHash = [string]$WitnessSnapshot.GitCommonDirCapture.ProjectionHash
        ContractRoot = [string]$WitnessSnapshot.ContractRoot
        ContractRootPath = [string]$WitnessSnapshot.ContractRootPath
        ContractRootChainHash = [string]$WitnessSnapshot.ContractRootCapture.ProjectionHash
        LockPath = [string]$WitnessSnapshot.LockPath
        LockIdentity = [AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredIdentityExact($CanonicalOwner)
        LockSecurityHash = [AiAgentDotfiles.SafeLockResourceOwner]::GetSecurityHashExact($CanonicalOwner)
        RepoId = [string]$WitnessSnapshot.RepoId
        GitCommonDirHash = [string]$WitnessSnapshot.GitCommonDirHash
        WorktreeId = [string]$WitnessSnapshot.WorktreeId
        RepositoryCommit = [string]$WitnessSnapshot.RepositoryCommit
        SetupStatePath = [string]$WitnessSnapshot.SetupStatePath
        SetupStateProjectionHash = [string]$WitnessSnapshot.SetupStateCapture.ProjectionHash
        SetupStateSemanticHash = [string]$WitnessSnapshot.SetupStateSemanticHash
        SetupStateStatus = [string]$WitnessSnapshot.SetupStateStatus
        CanonicalTransactionCoverage = [string]$WitnessSnapshot.CanonicalTransactionCoverage
        UnfinishedCanonicalTransactionCount = [long]$WitnessSnapshot.UnfinishedCanonicalTransactionCount
        CanonicalTransactionSetHash = [string]$WitnessSnapshot.CanonicalTransactionSetHash
        ToolchainRoot = [string]$WitnessSnapshot.ToolchainRoot
        ContractRootInitialNames = [string[]]@($WitnessSnapshot.ContractRootInitialNames)
    }
}

function Read-HomeAuthorityCanonicalGlobalInputSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$AuthorityContext,[Parameter(Mandatory)]$CanonicalWitness)

    $authoritySnapshot = Copy-HomeAuthoritySemanticValueOnce -Value $AuthorityContext
    $null = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $authoritySnapshot
    $null = Assert-SealedHeldLiveTargetExpectedSet -AuthorityContext $authoritySnapshot
    $authorityBytes = ConvertTo-SemanticJsonBytes -InputObject $authoritySnapshot
    $liveTargetSnapshot = @((Get-HomeAuthorityObjectProperty -InputObject $authoritySnapshot -Name 'LiveTargets'))
    $liveTargetBytes = ConvertTo-SemanticJsonBytes -InputObject $liveTargetSnapshot

    $witnessSnapshot = Copy-HomeAuthorityCanonicalWitnessOnce -CanonicalWitness $CanonicalWitness
    $canonicalLockHandle = $witnessSnapshot.CanonicalLockHandle
    if ('AiAgentDotfiles.CanonicalRepoLockHandle' -cnotin @($canonicalLockHandle.PSObject.TypeNames)) { throw 'canonical lock wrapper type is invalid' }
    foreach ($name in @('Path','Stream','Info','HeldLock','ParentHandles','SecuritySddl','SecurityHash')) {
        $property = $canonicalLockHandle.PSObject.Properties[$name]
        if ($null -eq $property -or $property.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty -or $null -eq $property.Value) {
            throw 'canonical lock wrapper has stateful or missing acquisition evidence'
        }
    }
    $canonicalOwner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($canonicalLockHandle)
    if ($canonicalOwner -isnot [AiAgentDotfiles.SafeLockResourceOwner] -or
        -not [AiAgentDotfiles.SafeLockResourceOwner]::IsExactForWrapper($canonicalOwner,$canonicalLockHandle) -or
        -not [AiAgentDotfiles.SafeLockResourceOwner]::MatchesAcquiredEvidenceExact($canonicalOwner)) { throw 'canonical lock owner is invalid' }
    $canonicalHeld = [AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($canonicalOwner)
    $canonicalParents = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($canonicalOwner))
    if ($canonicalHeld -isnot [AiAgentDotfiles.SafeLockFileHandle] -or -not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($canonicalHeld) -or $canonicalParents.Count -lt 1) {
        throw 'canonical lock acquisition is not live'
    }
    foreach ($parent in $canonicalParents) {
        if ($parent -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($parent)) { throw 'canonical lock parent acquisition is not live' }
    }
    if ($null -eq (Get-Command Assert-CanonicalHeldNamespaceWitness -CommandType Function -ErrorAction Stop)) { throw 'missing canonical witness validator' }
    $null = Assert-CanonicalHeldNamespaceWitness -Witness $witnessSnapshot -RepoRoot ([string]$witnessSnapshot.RepoRoot) -CanonicalLockHandle $canonicalLockHandle
    $null = Assert-CanonicalRepoLockHandle -LockHandle $canonicalLockHandle -ExpectedLockPath ([AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($canonicalOwner))
    if (-not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($canonicalOwner),$canonicalHeld)) { throw 'canonical lock owner changed during validation' }
    $afterParents = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($canonicalOwner))
    if ($afterParents.Count -ne $canonicalParents.Count) { throw 'canonical lock parent owner changed during validation' }
    for ($index=0; $index -lt $canonicalParents.Count; $index++) {
        if (-not [object]::ReferenceEquals($afterParents[$index],$canonicalParents[$index])) { throw 'canonical lock parent owner changed during validation' }
    }

    $witnessProjection = Get-HomeAuthorityCanonicalWitnessCaptureProjection -WitnessSnapshot $witnessSnapshot -CanonicalOwner $canonicalOwner
    $witnessProjectionBytes = ConvertTo-SemanticJsonBytes -InputObject $witnessProjection
    $witnessProjectionHash = Get-HomeAuthoritySha256Hex -Bytes $witnessProjectionBytes
    $witnessHash = [string]$witnessSnapshot.WitnessHash
    if ($witnessHash -cnotmatch '\A[0-9a-f]{64}\z' -or $witnessHash -cne $witnessProjectionHash) { throw 'canonical witness semantic hash mismatch' }
    return [pscustomobject][ordered]@{
        AuthoritySnapshot = $authoritySnapshot
        AuthorityBytes = [byte[]]$authorityBytes
        AuthorityHash = Get-HomeAuthoritySha256Hex -Bytes $authorityBytes
        LiveTargetBytes = [byte[]]$liveTargetBytes
        LiveTargetHash = Get-HomeAuthoritySha256Hex -Bytes $liveTargetBytes
        WitnessSnapshot = $witnessSnapshot
        WitnessProjectionBytes = [byte[]]$witnessProjectionBytes
        WitnessProjectionHash = $witnessProjectionHash
        WitnessHash = $witnessHash
        CanonicalLockHandle = $canonicalLockHandle
        CanonicalOwner = $canonicalOwner
        CanonicalHeld = $canonicalHeld
        CanonicalParents = [object[]]$canonicalParents
    }
}

function Assert-HomeAuthorityRequiredCanonicalWitness {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$CanonicalWitness,[Parameter(Mandatory)]$AuthorityContext)

    try {
        $state = Read-HomeAuthorityCanonicalGlobalInputSnapshot -AuthorityContext $AuthorityContext -CanonicalWitness $CanonicalWitness
        return [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::CreateExact(
            $CanonicalWitness,$state.WitnessSnapshot,$AuthorityContext,$state.CanonicalLockHandle,$state.CanonicalOwner,
            $state.CanonicalHeld,[object[]]$state.CanonicalParents,[byte[]]$state.WitnessProjectionBytes,
            [byte[]]$state.AuthorityBytes,[byte[]]$state.LiveTargetBytes,[string]$state.WitnessHash,
            [string]$state.WitnessProjectionHash,[string]$state.AuthorityHash,[string]$state.LiveTargetHash)
    }
    catch {
        if ($_.Exception.Message -ceq 'canonical-recovery-required') { throw 'canonical-recovery-required' }
        throw [InvalidOperationException]::new('canonical-witness-required',$_.Exception)
    }
}

function Get-HomeAuthorityCapturedAuthorityContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]$AcquisitionCapture)

    $bytes = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetAuthorityContextBytesExact($AcquisitionCapture)
    $json = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    return ConvertFrom-SemanticJson -Json $json
}

function Assert-HomeAuthorityCanonicalGlobalAcquisitionCaptureCurrent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]$AcquisitionCapture,
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$CanonicalWitness,
        [switch]$RequireBindingClaim
    )

    try {
        if (-not [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::MatchesSourcesExact($AcquisitionCapture,$CanonicalWitness,$AuthorityContext)) { throw 'canonical acquisition source reference changed' }
        if ($RequireBindingClaim -and -not [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::IsBindingClaimedExact($AcquisitionCapture)) { throw 'canonical acquisition binding was not claimed' }
        $state = Read-HomeAuthorityCanonicalGlobalInputSnapshot -AuthorityContext $AuthorityContext -CanonicalWitness $CanonicalWitness
        if (-not [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::MatchesCurrentSnapshotExact(
            $AcquisitionCapture,$state.CanonicalLockHandle,$state.CanonicalOwner,$state.CanonicalHeld,
            [object[]]$state.CanonicalParents,[byte[]]$state.WitnessProjectionBytes,[byte[]]$state.AuthorityBytes,
            [byte[]]$state.LiveTargetBytes,[string]$state.WitnessHash,[string]$state.WitnessProjectionHash,
            [string]$state.AuthorityHash,[string]$state.LiveTargetHash)) { throw 'canonical acquisition snapshot changed' }
        return $true
    }
    catch {
        if ($_.Exception.Message -ceq 'canonical-recovery-required') { throw 'canonical-recovery-required' }
        throw [InvalidOperationException]::new('canonical-witness-required',$_.Exception)
    }
}

function Get-HomeAuthorityCanonicalGlobalBindingEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]$AcquisitionCapture,
        [Parameter(Mandatory)]$GlobalLockHandle,
        [Parameter(Mandatory)][AiAgentDotfiles.SafeLockFileHandle]$GlobalHeld,
        [Parameter(Mandatory)][AiAgentDotfiles.SafeDirectoryHandle]$GlobalParent,
        [Parameter(Mandatory)][string]$FixedEnvelopeHash
    )

    $AuthorityContext = Get-HomeAuthorityCapturedAuthorityContext -AcquisitionCapture $AcquisitionCapture
    $canonicalLockHandle = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetCanonicalLockHandleExact($AcquisitionCapture)
    $canonicalOwner = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetCanonicalOwnerExact($AcquisitionCapture)
    $CanonicalHeld = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetCanonicalHeldExact($AcquisitionCapture)
    $null = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
    $null = Assert-SealedHeldLiveTargetExpectedSet -AuthorityContext $AuthorityContext
    if ($FixedEnvelopeHash -cnotmatch '\A[0-9a-f]{64}\z') { throw 'invalid fixed-envelope hash' }
    $globalOwner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($GlobalLockHandle)
    if ('AiAgentDotfiles.HomeAuthorityLockHandle' -cnotin @($GlobalLockHandle.PSObject.TypeNames) -or
        $globalOwner -isnot [AiAgentDotfiles.SafeLockResourceOwner] -or
        -not [AiAgentDotfiles.SafeLockResourceOwner]::IsExactForWrapper($globalOwner,$GlobalLockHandle) -or
        -not [AiAgentDotfiles.SafeLockResourceOwner]::MatchesAcquiredEvidenceExact($globalOwner)) { throw 'invalid global lock wrapper' }
    $display = [ordered]@{}
    foreach ($name in @('Path','HeldLock','ParentHandles','Info','SecurityHash','FixedEnvelopeHash')) {
        $property = $GlobalLockHandle.PSObject.Properties[$name]
        if ($null -eq $property -or $property.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty) { throw "global lock wrapper has a stateful or missing $name" }
        $display[$name] = $property.Value
        if ($null -eq $display[$name]) { throw "global lock wrapper is missing $name" }
    }

    if ($canonicalOwner -isnot [AiAgentDotfiles.SafeLockResourceOwner] -or
        -not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($canonicalLockHandle),$canonicalOwner) -or
        -not [AiAgentDotfiles.SafeLockResourceOwner]::IsExactForWrapper($canonicalOwner,$canonicalLockHandle) -or
        -not [AiAgentDotfiles.SafeLockResourceOwner]::MatchesAcquiredEvidenceExact($canonicalOwner) -or
        -not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($canonicalOwner),$CanonicalHeld)) { throw 'canonical lock wrapper was substituted' }
    $canonicalHeldDisplay = $canonicalLockHandle.PSObject.Properties['HeldLock']
    $canonicalPathDisplay = $canonicalLockHandle.PSObject.Properties['Path']
    if ($null -eq $canonicalHeldDisplay -or $null -eq $canonicalPathDisplay -or
        $canonicalHeldDisplay.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty -or
        $canonicalPathDisplay.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty -or
        -not [object]::ReferenceEquals($canonicalHeldDisplay.Value,$CanonicalHeld) -or
        -not ([IO.Path]::GetFullPath([string]$canonicalPathDisplay.Value)).Equals([AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($canonicalOwner),[StringComparison]::OrdinalIgnoreCase) -or
        [string][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact($CanonicalHeld) -cne [AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredIdentityExact($canonicalOwner) -or
        [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLinkCountExact($CanonicalHeld) -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLinkCountExact($canonicalOwner) -or
        [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLengthExact($CanonicalHeld) -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLengthExact($canonicalOwner) -or
        [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquisitionOrdinalExact($CanonicalHeld) -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquisitionOrdinalExact($canonicalOwner)) {
        throw 'canonical lock immutable acquisition evidence changed'
    }
    if (-not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($globalOwner),$GlobalHeld) -or
        -not [object]::ReferenceEquals($display.HeldLock,$GlobalHeld)) { throw 'global lock wrapper was substituted' }
    if (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($CanonicalHeld)) { throw 'canonical lock is not open' }
    if (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($GlobalHeld)) { throw 'global lock is not open' }
    $globalInfo = [AiAgentDotfiles.SafeLockResourceOwner]::GetInfoExact($globalOwner)
    $globalIdentity = [AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredIdentityExact($globalOwner)
    $globalLinkCount = [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLinkCountExact($globalOwner)
    $globalLength = [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLengthExact($globalOwner)
    if ([string][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact($GlobalHeld) -cne $globalIdentity -or
        [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLinkCountExact($GlobalHeld) -ne $globalLinkCount -or
        [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredLengthExact($GlobalHeld) -ne $globalLength -or
        -not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($GlobalHeld),$globalInfo) -or
        -not [object]::ReferenceEquals($display.Info,$globalInfo)) { throw 'global lock identity wrapper was substituted' }
    if ([string]$globalInfo.Identity -cne $globalIdentity -or [long]$globalInfo.LinkCount -ne $globalLinkCount -or
        [long]$globalInfo.Length -ne $globalLength -or $globalLinkCount -ne 1 -or $globalLength -ne 0) {
        throw 'global lock immutable acquisition evidence mismatch'
    }

    $expectedPath = [IO.Path]::GetFullPath([string]$AuthorityContext.GlobalLiveLockPath)
    if (-not ([AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($globalOwner)).Equals($expectedPath,[StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFullPath([string]$display.Path)).Equals($expectedPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'global lock path mismatch' }
    $parents = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($globalOwner))
    $displayParents = @($display.ParentHandles)
    if ($parents.Count -lt 1) { throw 'global lock parent chain is missing' }
    if ($displayParents.Count -ne $parents.Count) { throw 'global lock parent chain display was substituted' }
    for ($index=0; $index -lt $parents.Count; $index++) {
        $parentEntry = $parents[$index]
        if ($parentEntry -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($parentEntry) -or
            -not [object]::ReferenceEquals($displayParents[$index],$parentEntry) -or
            [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($parentEntry) -cne [AiAgentDotfiles.SafeLockResourceOwner]::GetParentIdentityExact($globalOwner,$index) -or
            [long][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredLinkCountExact($parentEntry) -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetParentLinkCountExact($globalOwner,$index)) {
            throw 'global lock parent chain is invalid, closed, or substituted'
        }
    }
    $parent = $parents[$parents.Count - 1]
    if (-not [object]::ReferenceEquals($parent,$GlobalParent)) { throw 'global lock final parent handle was substituted' }
    $parentInfo = [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($parent)
    $parentIdentity = [AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($parent)
    $parentLinkCount = [long][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredLinkCountExact($parent)
    if ([string]$parentInfo.Identity -cne $parentIdentity -or [long]$parentInfo.LinkCount -ne $parentLinkCount) {
        throw 'global lock parent mutable identity evidence changed'
    }

    $freshParents = $null
    try {
        $freshParentsReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path ([string]$AuthorityContext.ControlBase) -OwnershipReceiver $freshParentsReceiver
        $freshParents = $freshParentsReceiver.GetDeliveredExact()
        if ($freshParents.Count -ne $parents.Count) { throw 'global lock parent chain cardinality changed' }
        for ($index=0; $index -lt $parents.Count; $index++) {
            if ([string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($freshParents[$index]) -cne [AiAgentDotfiles.SafeLockResourceOwner]::GetParentIdentityExact($globalOwner,$index) -or
                [long][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredLinkCountExact($freshParents[$index]) -ne [long][AiAgentDotfiles.SafeLockResourceOwner]::GetParentLinkCountExact($globalOwner,$index)) { throw 'global lock parent chain identity changed' }
        }
    }
    finally { if ($null -ne $freshParents) { Close-SafeDirectoryContainmentChain -Handles $freshParents } }

    $parentMarker = Get-NoFollowRootEntryMarker -Path ([string]$AuthorityContext.ControlBase)
    $relative = [AiAgentDotfiles.NoFollowFile]::InspectChild($parent,[IO.Path]::GetFileName($expectedPath))
    if ([string]$parentMarker.EntryType -cne 'Directory' -or [string]$parentMarker.Identity -cne $parentIdentity -or
        [string]$relative.Identity -cne $globalIdentity -or [long]$relative.LinkCount -ne 1 -or [long]$relative.Length -ne 0 -or
        $relative.IsDirectory -or $relative.IsReparsePoint -or @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($GlobalHeld)).Count -ne 0) {
        throw 'global lock or final parent identity drift'
    }

    $sid = [string]$AuthorityContext.TokenSid
    $directoryTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind Directory
    $fileTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind File
    $parentSecurity = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($GlobalParent)
    $parentSecurityEvidence = Assert-HomeAuthoritySecuritySnapshot -Snapshot $parentSecurity -SecurityTemplate $directoryTemplate -ExpectedIdentity $parentIdentity
    $globalSecurity = [AiAgentDotfiles.NoFollowFile]::GetLockFileSecuritySnapshot($GlobalHeld)
    $globalSecurityEvidence = Assert-HomeAuthoritySecuritySnapshot -Snapshot $globalSecurity -SecurityTemplate $fileTemplate -ExpectedIdentity $globalIdentity
    if ([string]$display.SecurityHash -cne [string]$globalSecurityEvidence.EvidenceHash -or
        [string][AiAgentDotfiles.SafeLockResourceOwner]::GetSecurityHashExact($globalOwner) -cne [string]$globalSecurityEvidence.EvidenceHash -or
        [string]$display.FixedEnvelopeHash -cne $FixedEnvelopeHash) {
        throw 'global lock security or fixed-envelope binding changed'
    }

    $authorityContextHash = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetAuthorityContextHashExact($AcquisitionCapture)
    $liveTargetProjectionHash = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetLiveTargetProjectionHashExact($AcquisitionCapture)
    if ((Get-SemanticJsonHash -InputObject $AuthorityContext) -cne $authorityContextHash -or
        (Get-SemanticJsonHash -InputObject @($AuthorityContext.LiveTargets)) -cne $liveTargetProjectionHash) {
        throw 'captured authority projection is invalid'
    }
    $projection = [ordered]@{
        Domain = 'ai-agent-dotfiles/canonical-global-lock-order/v1'
        Canonical = [ordered]@{
            WitnessHash = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetWitnessHashExact($AcquisitionCapture)
            LockPath = [AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($canonicalOwner)
            LockIdentity = [AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredIdentityExact($canonicalOwner)
            LockLinkCount = [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLinkCountExact($canonicalOwner)
            LockLength = [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredLengthExact($canonicalOwner)
            AcquisitionOrdinal = [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquisitionOrdinalExact($canonicalOwner)
        }
        Global = [ordered]@{
            LockPath = $expectedPath
            LockIdentity = $globalIdentity
            LockLinkCount = $globalLinkCount
            LockLength = $globalLength
            AcquisitionOrdinal = [long][AiAgentDotfiles.SafeLockFileHandle]::GetAcquisitionOrdinalExact($GlobalHeld)
            SecurityHash = [string]$globalSecurityEvidence.EvidenceHash
            FinalParentPath = [IO.Path]::GetFullPath([string]$AuthorityContext.ControlBase)
            FinalParentIdentity = $parentIdentity
            FinalParentLinkCount = $parentLinkCount
            FinalParentSecurityHash = [string]$parentSecurityEvidence.EvidenceHash
            FixedEnvelopeHash = $FixedEnvelopeHash
        }
        AuthorityContextHash = $authorityContextHash
        LiveTargetProjectionHash = $liveTargetProjectionHash
    }
    return [pscustomobject][ordered]@{
        Projection = $projection
        BindingHash = Get-SemanticJsonHash -InputObject $projection
        AuthorityContextHash = $authorityContextHash
        LiveTargetProjectionHash = $liveTargetProjectionHash
        GlobalParent = $parent
    }
}

function Assert-HomeAuthorityCanonicalGlobalLockBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$GlobalLockHandle,
        [Parameter(Mandatory)]$CanonicalWitness
    )

    $envelope = $null
    try {
        $binding = [AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($GlobalLockHandle)
        if ($binding -isnot [AiAgentDotfiles.SafeLockOrderBinding]) { throw 'missing CLR canonical/global order binding' }
        $acquisitionCapture = [AiAgentDotfiles.SafeLockOrderBinding]::GetPrerequisiteWitnessExact($binding)
        if ($acquisitionCapture -isnot [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture] -or
            -not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetAuthorityContextExact($binding),$acquisitionCapture)) {
            throw 'missing sealed canonical/global acquisition capture'
        }
        $canonicalHeld = [AiAgentDotfiles.SafeLockOrderBinding]::GetPrerequisiteExact($binding)
        $globalHeld = [AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentExact($binding)
        $globalParent = [AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentParentExact($binding)
        if (-not [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::MatchesSourcesExact($acquisitionCapture,$CanonicalWitness,$AuthorityContext)) { throw 'canonical acquisition source reference changed' }
        if (-not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentWrapperExact($binding),$GlobalLockHandle)) { throw 'bound global wrapper reference changed' }
        $null = Assert-HomeAuthorityCanonicalGlobalAcquisitionCaptureCurrent -AcquisitionCapture $acquisitionCapture -AuthorityContext $AuthorityContext -CanonicalWitness $CanonicalWitness -RequireBindingClaim
        $operationContext = Get-HomeAuthorityCapturedAuthorityContext -AcquisitionCapture $acquisitionCapture
        if (-not [object]::ReferenceEquals($canonicalHeld,[AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetCanonicalHeldExact($acquisitionCapture))) { throw 'bound canonical handle changed' }
        $bindingDisplay = [ordered]@{}
        foreach ($name in @('HeldLock','CanonicalWitness','CanonicalWitnessHash','CanonicalGlobalOrderBinding','CanonicalGlobalBindingHash','AuthorityContext','AuthorityContextHash','LiveTargetProjectionHash')) {
            $property = $GlobalLockHandle.PSObject.Properties[$name]
            if ($null -eq $property -or $property.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty) { throw "global lock binding display is stateful or missing $name" }
            $bindingDisplay[$name] = $property.Value
            if ($null -eq $bindingDisplay[$name]) { throw "global lock binding display is missing $name" }
        }
        if (-not [object]::ReferenceEquals($bindingDisplay.HeldLock,$globalHeld) -or
            -not [object]::ReferenceEquals($bindingDisplay.CanonicalWitness,$CanonicalWitness) -or
            -not [object]::ReferenceEquals($bindingDisplay.AuthorityContext,$AuthorityContext) -or
            -not [object]::ReferenceEquals($bindingDisplay.CanonicalGlobalOrderBinding,$binding) -or
            [string]$bindingDisplay.CanonicalWitnessHash -cne [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetWitnessHashExact($acquisitionCapture)) {
            throw 'canonical/global binding display was substituted'
        }

        $sid = [string](Get-HomeAuthorityObjectProperty -InputObject $operationContext -Name 'TokenSid')
        $directoryTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind Directory
        $fileTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind File
        $envelope = Open-SealedHomeAuthorityFixedEnvelope -AuthorityContext $operationContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate -HeldGlobalLock $GlobalLockHandle
        $evidence = Get-HomeAuthorityCanonicalGlobalBindingEvidence -AcquisitionCapture $acquisitionCapture -GlobalLockHandle $GlobalLockHandle -GlobalHeld $globalHeld -GlobalParent $globalParent -FixedEnvelopeHash ([string]$envelope.InitialEnvelopeHash)
        if ([string]$bindingDisplay.AuthorityContextHash -cne [string]$evidence.AuthorityContextHash -or
            [string]$bindingDisplay.LiveTargetProjectionHash -cne [string]$evidence.LiveTargetProjectionHash -or
            [string]$bindingDisplay.CanonicalGlobalBindingHash -cne [string]$evidence.BindingHash -or
            [string][AiAgentDotfiles.SafeLockOrderBinding]::GetBindingHashExact($binding) -cne [string]$evidence.BindingHash -or
            -not [AiAgentDotfiles.SafeLockOrderBinding]::MatchesExact($binding,$canonicalHeld,$globalHeld,$globalParent,$acquisitionCapture,$acquisitionCapture,$GlobalLockHandle,[string]$evidence.BindingHash)) {
            throw 'canonical/global immutable order binding drift'
        }
        return $true
    }
    catch {
        if ($_.Exception.Message -ceq 'canonical-recovery-required') { throw 'canonical-recovery-required' }
        throw [InvalidOperationException]::new('canonical-witness-required',$_.Exception)
    }
    finally { if ($null -ne $envelope) { Close-SealedHomeAuthorityFixedEnvelope -EnvelopeLease $envelope } }
}

function Enter-HomeAuthorityGlobalLiveLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [AllowNull()]$RequiredCanonicalWitness
    )

    $acquisitionCapture = if ($null -eq $RequiredCanonicalWitness) { $null } else {
        Assert-HomeAuthorityRequiredCanonicalWitness -CanonicalWitness $RequiredCanonicalWitness -AuthorityContext $AuthorityContext
    }
    $operationContext = if ($null -eq $acquisitionCapture) { $AuthorityContext } else { Get-HomeAuthorityCapturedAuthorityContext -AcquisitionCapture $acquisitionCapture }
    $null = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $operationContext
    $sid = [string](Get-HomeAuthorityObjectProperty -InputObject $operationContext -Name 'TokenSid')
    $directoryTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind Directory
    $fileTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind File
    $envelope = Open-SealedHomeAuthorityFixedEnvelope -AuthorityContext $operationContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate
    $lock = $null
    try {
        $controlState = @($envelope.InitialProjection.Directories | Where-Object { [string]$_.Name -ceq 'ControlBase' })[0]
        $lock = Enter-HomeAuthorityLockFileCore -ParentPath ([string]$operationContext.ControlBase) -LockPath ([string]$operationContext.GlobalLiveLockPath) -FileSecurityTemplate $fileTemplate -Mode OpenExisting -MissingToken 'global-live-lock-missing' -ExpectedParentIdentity ([string]$controlState.Identity)
        $after = Get-SealedHomeAuthorityFixedEnvelopeProjection -AuthorityContext $operationContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate -EnvelopeLease $envelope -HeldGlobalLock $lock
        if ([string]$envelope.InitialEnvelopeHash -cne [string]$after.EnvelopeHash) { throw 'home-authority-fixed-envelope-drift-before-global-lock' }
        $lock | Add-Member -NotePropertyName FixedEnvelopeHash -NotePropertyValue ([string]$after.EnvelopeHash)
        $lock | Add-Member -NotePropertyName BootstrapSnapshotHash -NotePropertyValue ([string]$after.EnvelopeHash)
        if ($null -ne $acquisitionCapture) {
            $null = Assert-HomeAuthorityCanonicalGlobalAcquisitionCaptureCurrent -AcquisitionCapture $acquisitionCapture -AuthorityContext $AuthorityContext -CanonicalWitness $RequiredCanonicalWitness
            $globalOwner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($lock)
            if ($globalOwner -isnot [AiAgentDotfiles.SafeLockResourceOwner]) { throw 'canonical-witness-required' }
            $parentHandles = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($globalOwner))
            $globalParent = $parentHandles[$parentHandles.Count - 1]
            $canonicalHeld = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetCanonicalHeldExact($acquisitionCapture)
            $globalHeld = [AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($globalOwner)
            $evidence = Get-HomeAuthorityCanonicalGlobalBindingEvidence -AcquisitionCapture $acquisitionCapture -GlobalLockHandle $lock -GlobalHeld $globalHeld -GlobalParent $globalParent -FixedEnvelopeHash ([string]$after.EnvelopeHash)
            try {
                if (-not [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::ClaimForBindingExact($acquisitionCapture)) { throw 'canonical acquisition capture already claimed' }
                $binding = [AiAgentDotfiles.SafeLockOrderBinding]::BindExact($globalHeld,$canonicalHeld,$globalParent,$acquisitionCapture,$acquisitionCapture,$lock,[string]$evidence.BindingHash)
            }
            catch { throw 'canonical-witness-required' }
            $lock | Add-Member -NotePropertyName CanonicalWitness -NotePropertyValue $RequiredCanonicalWitness
            $lock | Add-Member -NotePropertyName CanonicalWitnessHash -NotePropertyValue ([AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetWitnessHashExact($acquisitionCapture))
            $lock | Add-Member -NotePropertyName CanonicalGlobalOrderBinding -NotePropertyValue $binding
            $lock | Add-Member -NotePropertyName CanonicalGlobalBindingHash -NotePropertyValue ([string]$evidence.BindingHash)
            $lock | Add-Member -NotePropertyName AuthorityContext -NotePropertyValue $AuthorityContext
            $lock | Add-Member -NotePropertyName AuthorityContextHash -NotePropertyValue ([string]$evidence.AuthorityContextHash)
            $lock | Add-Member -NotePropertyName LiveTargetProjectionHash -NotePropertyValue ([string]$evidence.LiveTargetProjectionHash)
            $null = Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $AuthorityContext -GlobalLockHandle $lock -CanonicalWitness $RequiredCanonicalWitness
        }
        return $lock
    }
    catch {
        if ($null -ne $lock) { Exit-HomeAuthorityLockHandle -LockHandle $lock }
        throw
    }
    finally { Close-SealedHomeAuthorityFixedEnvelope -EnvelopeLease $envelope }
}

function Exit-HomeAuthorityGlobalLiveLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$LockHandle)

    $resourceOwner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($LockHandle)
    if ($resourceOwner -isnot [AiAgentDotfiles.SafeLockResourceOwner] -or
        -not [AiAgentDotfiles.SafeLockResourceOwner]::IsExactForWrapper($resourceOwner,$LockHandle)) { throw 'home-authority-lock-owner-required' }
    $binding = [AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($LockHandle)
    if ($binding -isnot [AiAgentDotfiles.SafeLockOrderBinding]) {
        Exit-HomeAuthorityLockHandle -LockHandle $LockHandle
        return
    }

    $bindingValid = $false
    $bindingValidationError = $null
    $prerequisiteOpenAtRelease = $false
    $releaseError = $null
    try {
        try {
            $acquisitionCapture = [AiAgentDotfiles.SafeLockOrderBinding]::GetPrerequisiteWitnessExact($binding)
            if ($acquisitionCapture -isnot [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture] -or
                -not [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetAuthorityContextExact($binding),$acquisitionCapture)) {
                throw 'canonical-witness-required'
            }
            $boundAuthority = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetAuthoritySourceExact($acquisitionCapture)
            $boundWitness = [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetWitnessSourceExact($acquisitionCapture)
            $null = Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $boundAuthority -GlobalLockHandle $LockHandle -CanonicalWitness $boundWitness
            $bindingValid = $true
        }
        catch { $bindingValid = $false; $bindingValidationError = $_ }
    }
    finally {
        try { $prerequisiteOpenAtRelease = [bool][AiAgentDotfiles.SafeLockOrderBinding]::ReleaseExact($binding) }
        catch {
            $releaseError = $_
            try { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact([AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentExact($binding)) } catch { if ($null -eq $releaseError) { $releaseError = $_ } }
        }
        finally {
            try { Close-HomeAuthorityLockResourceOwner -Owner $resourceOwner }
            catch { if ($null -eq $releaseError) { $releaseError = $_ } }
        }
    }
    if ($null -ne $releaseError) { throw $releaseError }
    if (-not $bindingValid) { throw $bindingValidationError }
    if (-not $prerequisiteOpenAtRelease) { throw 'canonical-witness-required' }
}

function Get-SealedHomeAuthorityBootstrapCompletionStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$AuthorityContext)
    $null = Assert-SealedHomeAuthorityBootstrapContext -AuthorityContext $AuthorityContext
    $sid = [string]$AuthorityContext.TokenSid
    $directoryTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind Directory
    $fileTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind File
    return Get-SealedHomeAuthorityBootstrapSnapshot -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $directoryTemplate -FileSecurityTemplate $fileTemplate
}

function Complete-SealedHomeAuthorityBootstrap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$Intent,
        [scriptblock]$BeforeCreate,
        [scriptblock]$AfterCreate
    )

    $bootstrapLock = $null
    $globalLock = $null
    $succeeded = $false
    try {
        $null = Assert-SealedHomeAuthorityBootstrapIntent -AuthorityContext $AuthorityContext -Intent $Intent
        $bootstrapLock = Enter-SealedHomeAuthorityBootstrapLock -AuthorityContext $AuthorityContext -Intent $Intent
        $current = Assert-SealedHomeAuthorityBootstrapIntent -AuthorityContext $AuthorityContext -Intent $Intent -HeldBootstrapLock $bootstrapLock
        $definitions = @(Get-HomeAuthorityBootstrapEntryDefinitions -AuthorityContext $AuthorityContext)
        $directoryTemplate = $Intent.DirectorySecurityTemplate
        $fileTemplate = $Intent.LockFileSecurityTemplate
        $directorySddl = ConvertTo-HomeAuthoritySecurityDescriptorSddl -SecurityTemplate $directoryTemplate
        foreach ($definition in $definitions) {
            $state = $current.Entries[[int]$definition.Order]
            if ([string]$state.Status -ceq 'COMPLETE') { continue }
            if ($BeforeCreate) { & $BeforeCreate ([pscustomobject]$definition) }
            if ([string]$definition.Kind -ceq 'Directory') {
                $parentHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
                Open-SafeDirectoryContainmentChain -Path ([string]$definition.ParentPath) -OwnershipReceiver $parentHandlesReceiver
                $parentHandles = $parentHandlesReceiver.GetDeliveredExact()
                $created = $null
                try {
                    $created = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectoryWithSecurityDescriptor($parentHandles[$parentHandles.Count - 1],[string]$definition.LeafName,$directorySddl)
                    $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot([string]$definition.Path)
                    $null = Assert-HomeAuthoritySecuritySnapshot -Snapshot $security -SecurityTemplate $directoryTemplate -ExpectedIdentity ([string]$created.Info.Identity)
                }
                catch [ComponentModel.Win32Exception] {
                    if ($_.Exception.NativeErrorCode -in @(80,183)) { throw 'home-authority-bootstrap-manual-recovery-required: unexpected directory creation collision' }
                    throw
                }
                finally {
                    if ($null -ne $created) { $created.Dispose() }
                    Close-SafeDirectoryContainmentChain -Handles $parentHandles
                }
            }
            else {
                $controlState = @($current.Entries | Where-Object { [string]$_.Name -ceq 'ControlBase' })[0]
                $globalLock = Enter-HomeAuthorityLockFileCore -ParentPath ([string]$AuthorityContext.ControlBase) -LockPath ([string]$AuthorityContext.GlobalLiveLockPath) -FileSecurityTemplate $fileTemplate -Mode CreateNew -MissingToken 'home-authority-bootstrap-incomplete' -ExpectedParentIdentity ([string]$controlState.Identity)
            }
            if ($AfterCreate) { & $AfterCreate ([pscustomobject]$definition) }
            $current = Assert-SealedHomeAuthorityBootstrapIntent -AuthorityContext $AuthorityContext -Intent $Intent -HeldGlobalLock $globalLock -HeldBootstrapLock $bootstrapLock
        }
        if ($null -eq $globalLock) { $globalLock = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $AuthorityContext }
        $final = Assert-SealedHomeAuthorityBootstrapIntent -AuthorityContext $AuthorityContext -Intent $Intent -HeldGlobalLock $globalLock -HeldBootstrapLock $bootstrapLock
        if ([string]$final.Status -cne 'COMPLETE') { throw 'home-authority-bootstrap-incomplete' }
        $globalLock | Add-Member -NotePropertyName BootstrapIntentHash -NotePropertyValue ([string]$Intent.IntentHash)
        $globalLock | Add-Member -NotePropertyName BootstrapSnapshotHash -NotePropertyValue ([string]$final.SnapshotHash) -Force
        $succeeded = $true
        return $globalLock
    }
    finally {
        if ($null -ne $bootstrapLock) { Exit-HomeAuthorityLockHandle -LockHandle $bootstrapLock }
        if (-not $succeeded -and $null -ne $globalLock) { Exit-HomeAuthorityGlobalLiveLock -LockHandle $globalLock }
    }
}

function Resolve-HomeAuthorityContextFromIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Identity,
        [string]$ReasonixLiveSkillsPath,
        [string[]]$ForbiddenRoots = @()
    )

    $identityResolver = Get-HomeAuthorityIdentityField -Identity $Identity -Name 'ResolverVersion'
    if ($identityResolver -notin @($script:HomeAuthorityResolverVersion, 'sealed-home-authority-test-adapter-v1')) { throw 'home-authority-identity-resolver-unsupported' }
    $sid = Get-HomeAuthorityIdentityField -Identity $Identity -Name 'TokenSid'
    try { $canonicalSid = [Security.Principal.SecurityIdentifier]::new($sid).Value }
    catch { throw 'home-authority-token-sid-invalid' }
    if ($sid -cne $canonicalSid) { throw 'home-authority-token-sid-noncanonical' }
    $profile = ConvertTo-HomeAuthorityKnownFolderPath -Path (Get-HomeAuthorityIdentityField -Identity $Identity -Name 'ProfileRoot') -Name 'Profile'
    $roaming = ConvertTo-HomeAuthorityKnownFolderPath -Path (Get-HomeAuthorityIdentityField -Identity $Identity -Name 'RoamingAppDataRoot') -Name 'RoamingAppData'
    $local = ConvertTo-HomeAuthorityKnownFolderPath -Path (Get-HomeAuthorityIdentityField -Identity $Identity -Name 'LocalAppDataRoot') -Name 'LocalAppData'

    $homeLocationKey = ConvertTo-HomeAuthorityLocationKey -Path $profile
    $localLocationKey = ConvertTo-HomeAuthorityLocationKey -Path $local
    $homeAuthorityKey = Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/home-authority/v1'
        TokenSid = $sid
        HomeRootLocationKey = $homeLocationKey
    })
    $bootstrapLockKey = Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/control-bootstrap-lock/v1'
        TokenSid = $sid
        LocalAppDataLocationKey = $localLocationKey
    })

    $privateBase = [IO.Path]::GetFullPath((Join-Path $local 'ai-agent-dotfiles'))
    $controlBase = [IO.Path]::GetFullPath((Join-Path $privateBase 'control'))
    $backupRoot = [IO.Path]::GetFullPath((Join-Path $privateBase 'backups'))
    $homesRoot = [IO.Path]::GetFullPath((Join-Path $controlBase 'homes'))
    $canonicalRootsRoot = [IO.Path]::GetFullPath((Join-Path $controlBase 'canonical-roots'))
    $liveTransactionsRoot = [IO.Path]::GetFullPath((Join-Path $controlBase 'live-transactions'))
    $authorityRoot = [IO.Path]::GetFullPath((Join-Path $homesRoot $homeAuthorityKey))
    $bootstrapPaths = @($privateBase, $backupRoot, $controlBase, $homesRoot, $canonicalRootsRoot, $liveTransactionsRoot)
    $bootstrapStatus = Get-HomeAuthorityBootstrapStatus -DeterministicPaths $bootstrapPaths

    $liveArguments = @{
        ProfileRoot = $profile
        RoamingAppDataRoot = $roaming
        ForbiddenRoots = @($ForbiddenRoots) + @($controlBase, $backupRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($ReasonixLiveSkillsPath)) { $liveArguments.ReasonixLiveSkillsPath = $ReasonixLiveSkillsPath }
    $liveTargets = @(Resolve-LiveTargetContextSet @liveArguments)

    return [pscustomobject][ordered]@{
        ResolverVersion = $script:HomeAuthorityResolverVersion
        IdentityResolverVersion = $identityResolver
        TokenSid = $sid
        HomeRoot = $profile
        HomeRootLocationKey = $homeLocationKey
        RoamingAppDataRoot = $roaming
        RoamingAppDataLocationKey = ConvertTo-HomeAuthorityLocationKey -Path $roaming
        LocalAppDataRoot = $local
        LocalAppDataLocationKey = $localLocationKey
        HomeAuthorityKey = $homeAuthorityKey
        ControlBootstrapLockKey = $bootstrapLockKey
        ControlBootstrapLockPath = [IO.Path]::GetFullPath((Join-Path $local 'ai-agent-dotfiles.control-bootstrap.lock'))
        PrivateRootBase = $privateBase
        PrivateRootBootstrapStatus = $bootstrapStatus
        ControlBase = $controlBase
        BackupRoot = $backupRoot
        HomesRoot = $homesRoot
        CanonicalRootsRoot = $canonicalRootsRoot
        LiveTransactionsRoot = $liveTransactionsRoot
        GlobalLiveLockPath = [IO.Path]::GetFullPath((Join-Path $controlBase 'live-mutation.lock'))
        AuthorityRoot = $authorityRoot
        RootClaimsPath = [IO.Path]::GetFullPath((Join-Path $authorityRoot 'root-claims.json'))
        CurrentEnvStatePath = [IO.Path]::GetFullPath((Join-Path $authorityRoot 'current-env.json'))
        LiveTargets = $liveTargets
    }
}

function Resolve-HomeAuthorityContext {
    [CmdletBinding()]
    param([string]$ReasonixLiveSkillsPath,[string[]]$ForbiddenRoots = @())

    $identity = Get-WindowsHomeAuthorityIdentity
    $arguments = @{ Identity=$identity; ForbiddenRoots=@($ForbiddenRoots) }
    if (-not [string]::IsNullOrWhiteSpace($ReasonixLiveSkillsPath)) { $arguments.ReasonixLiveSkillsPath=$ReasonixLiveSkillsPath }
    return Resolve-HomeAuthorityContextFromIdentity @arguments
}
