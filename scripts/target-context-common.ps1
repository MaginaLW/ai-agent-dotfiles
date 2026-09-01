#requires -Version 7.0

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'safe-tree-walker.ps1')

if (-not ('AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.CompilerServices;
using System.Threading;

namespace AiAgentDotfiles {
    public sealed class SealedHeldTargetContextLeaseReceipt {
        private static readonly ConditionalWeakTable<object, SealedHeldTargetContextLeaseReceipt> bindings =
            new ConditionalWeakTable<object, SealedHeldTargetContextLeaseReceipt>();
        private readonly object wrapper;
        private readonly object projection;
        private readonly object legacyMetadata;
        private readonly object[] directoryRows;
        private readonly object[] handles;
        private readonly object firstMissingParentHandle;
        private readonly string firstMissingName;
        private const int OpenState = 0;
        private const int ClosingState = 1;
        private const int ClosedState = 2;
        private int closeState;

        private SealedHeldTargetContextLeaseReceipt(object wrapperValue, object projectionValue,
            object legacyMetadataValue, object[] directoryRowsValue, object[] handlesValue,
            object firstMissingParentHandleValue, string firstMissingNameValue) {
            wrapper = wrapperValue;
            projection = projectionValue;
            legacyMetadata = legacyMetadataValue;
            directoryRows = (object[])directoryRowsValue.Clone();
            handles = (object[])handlesValue.Clone();
            firstMissingParentHandle = firstMissingParentHandleValue;
            firstMissingName = firstMissingNameValue;
        }

        private static SealedHeldTargetContextLeaseReceipt RequireForWrapper(object wrapperValue) {
            SealedHeldTargetContextLeaseReceipt receipt;
            if (wrapperValue == null || !bindings.TryGetValue(wrapperValue, out receipt) ||
                !Object.ReferenceEquals(receipt.wrapper, wrapperValue)) {
                throw new InvalidOperationException("target-context-plan-stale: held target lease receipt is missing");
            }
            return receipt;
        }

        public static SealedHeldTargetContextLeaseReceipt BindExact(object wrapperValue, object projectionValue,
            object legacyMetadataValue, object[] directoryRowsValue, object[] handlesValue,
            object firstMissingParentHandleValue, string firstMissingNameValue) {
            if (wrapperValue == null || projectionValue == null || legacyMetadataValue == null ||
                directoryRowsValue == null || handlesValue == null || handlesValue.Length == 0 ||
                directoryRowsValue.Length != handlesValue.Length) {
                throw new InvalidOperationException("target-context-plan-stale: held target lease receipt is invalid");
            }
            SealedHeldTargetContextLeaseReceipt receipt = new SealedHeldTargetContextLeaseReceipt(
                wrapperValue, projectionValue, legacyMetadataValue, directoryRowsValue, handlesValue,
                firstMissingParentHandleValue, firstMissingNameValue);
            try { bindings.Add(wrapperValue, receipt); }
            catch (ArgumentException) { throw new InvalidOperationException("target-context-plan-stale: held target lease receipt is already bound"); }
            return receipt;
        }

        public static SealedHeldTargetContextLeaseReceipt GetForWrapperExact(object wrapperValue) {
            SealedHeldTargetContextLeaseReceipt receipt;
            return wrapperValue != null && bindings.TryGetValue(wrapperValue, out receipt) &&
                Object.ReferenceEquals(receipt.wrapper, wrapperValue) ? receipt : null;
        }
        public static object GetWrapperExact(SealedHeldTargetContextLeaseReceipt receipt) { return receipt == null ? null : receipt.wrapper; }
        public static object GetProjectionExact(SealedHeldTargetContextLeaseReceipt receipt) { return receipt == null ? null : receipt.projection; }
        public static object GetLegacyMetadataExact(SealedHeldTargetContextLeaseReceipt receipt) { return receipt == null ? null : receipt.legacyMetadata; }
        public static object[] GetDirectoryRowsExact(SealedHeldTargetContextLeaseReceipt receipt) { return receipt == null ? null : (object[])receipt.directoryRows.Clone(); }
        public static object[] GetHandlesExact(SealedHeldTargetContextLeaseReceipt receipt) { return receipt == null ? null : (object[])receipt.handles.Clone(); }
        public static object GetFirstMissingParentHandleExact(SealedHeldTargetContextLeaseReceipt receipt) { return receipt == null ? null : receipt.firstMissingParentHandle; }
        public static string GetFirstMissingNameExact(SealedHeldTargetContextLeaseReceipt receipt) { return receipt == null ? null : receipt.firstMissingName; }
        public static bool GetIsOpenExact(SealedHeldTargetContextLeaseReceipt receipt) {
            return receipt != null && Volatile.Read(ref receipt.closeState) == OpenState;
        }
        public static bool GetIsClosedExact(SealedHeldTargetContextLeaseReceipt receipt) {
            return receipt == null || Volatile.Read(ref receipt.closeState) == ClosedState;
        }
        public static string GetCloseStateExact(SealedHeldTargetContextLeaseReceipt receipt) {
            if (receipt == null) return "CLOSED";
            int state = Volatile.Read(ref receipt.closeState);
            return state == OpenState ? "OPEN" : state == ClosingState ? "CLOSING" : "CLOSED";
        }
        public static bool ReleaseForWrapperExact(object wrapperValue) {
            SealedHeldTargetContextLeaseReceipt receipt = RequireForWrapper(wrapperValue);
            int observed = Interlocked.CompareExchange(ref receipt.closeState, ClosingState, OpenState);
            if (observed == ClosedState) return false;
            if (observed == ClosingState) throw new InvalidOperationException("target-context-close-active");
            if (observed != OpenState) throw new InvalidOperationException("target-context-plan-stale: held target lease close state is invalid");

            Exception firstError = null;
            for (int index = receipt.handles.Length - 1; index >= 0; index--) {
                try {
                    IDisposable disposable = receipt.handles[index] as IDisposable;
                    if (disposable == null)
                        throw new InvalidOperationException("target-context-plan-stale: held target cleanup handle type changed");
                    disposable.Dispose();
                }
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

function Test-TargetPathOverlap {
    param([string] $Left, [string] $Right)
    return (Test-SafePathInsideRoot -Path $Left -Root $Right) -or (Test-SafePathInsideRoot -Path $Right -Root $Left)
}

function Assert-SupportedTargetFilesystem {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $DriveType, [Parameter(Mandatory)] [string] $FileSystemType)
    if ($DriveType -cne 'Fixed' -or $FileSystemType -cne 'NTFS') { throw "unsupported target filesystem: $DriveType/$FileSystemType" }
}

function Get-TargetMetadataContext {
    param([Parameter(Mandatory)] [string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathFullyQualified($Path)) { throw 'target path must be fully-qualified and absolute' }
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal)) { throw 'network/UNC target is unsupported' }
    $rawFull = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($rawFull)
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'target path has no volume root' }
    if ([System.IO.Path]::GetRelativePath($root, $rawFull) -ceq '.') { throw 'volume root cannot be a target' }
    $full = $rawFull.TrimEnd([char]92, [char]47)
    $relative = [System.IO.Path]::GetRelativePath($root, $full)
    $segments = @($relative -split '[\\/]')
    foreach ($segment in $segments) {
        if ($segment -in @('', '.', '..') -or $segment.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "unsafe target path segment: $segment"
        }
    }
    if (@($segments | Where-Object { $_ -ieq '.system' }).Count -gt 0) { throw '.system cannot be a managed target' }
    $ancestors = [System.Collections.Generic.List[object]]::new()
    $handles = [System.Collections.Generic.List[object]]::new()
    try {
        $rootHandle = [AiAgentDotfiles.NoFollowFile]::HoldDirectory($root)
        $handles.Add($rootHandle)
        $rootInfo = [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($rootHandle)
        if (-not $rootInfo.IsDirectory -or $rootInfo.IsReparsePoint) { throw 'volume root identity is invalid' }
        $ancestors.Add([ordered]@{ Path=$root; Identity=[string]$rootInfo.Identity; Type='Directory'; ReparsePoint=$false })

        $parentHandle = $rootHandle
        $current = $root
        $deepest = $root
        $missingRemainder = [System.Collections.Generic.List[string]]::new()
        $missing = $false
        for ($index = 0; $index -lt $segments.Count; $index++) {
            $segment = $segments[$index]
            if ($missing) { $missingRemainder.Add($segment); continue }
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $current $segment))
            $info = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($parentHandle, $segment)
            if ($null -eq $info) { $missing=$true; $missingRemainder.Add($segment); continue }
            if ($info.IsReparsePoint) { throw "target path contains a reparse ancestor: $candidate" }
            $type = if ($info.IsDirectory) { 'Directory' } else { 'File' }
            if (-not $info.IsDirectory -and $index -lt ($segments.Count - 1)) { throw "target path descends through a file: $candidate" }

            if ($info.IsDirectory) {
                $childHandle = [AiAgentDotfiles.NoFollowFile]::TryHoldPathChildDirectory($parentHandle, $segment)
                if ($null -eq $childHandle) { throw "target path changed during metadata capture: $candidate" }
                $accepted = $false
                try {
                    $childInfo = [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($childHandle)
                    if (-not $childInfo.IsDirectory -or $childInfo.IsReparsePoint -or [string]$childInfo.Identity -cne [string]$info.Identity) {
                        throw "target path changed during metadata capture: $candidate"
                    }
                    $handles.Add($childHandle)
                    $accepted = $true
                }
                finally { if (-not $accepted) { $childHandle.Dispose() } }
                $parentHandle = $childHandle
            }

            $ancestors.Add([ordered]@{ Path=$candidate; Identity=[string]$info.Identity; Type=$type; ReparsePoint=$false })
            $current = $candidate
            $deepest = $candidate
        }
        $targetStatus = if ($missing) { 'MISSING' } else { 'EXISTS' }
        $targetType = if ($missing) { 'MISSING' } else { [string]$ancestors[-1].Type }
        return [ordered]@{
            LocationKey = $full.ToLowerInvariant().Replace([char]92,[char]47)
            RequestedPath = $full
            TargetStatus = $targetStatus
            TargetType = $targetType
            VolumeId = ([string]$rootInfo.Identity -split ':')[0]
            DeepestExistingParentPath = [System.IO.Path]::GetFullPath($deepest)
            DeepestExistingParentIdentity = [string]$ancestors[-1].Identity
            MissingRemainder = @($missingRemainder)
            Ancestors = @($ancestors)
        }
    }
    finally { Close-SafeDirectoryContainmentChain -Handles $handles }
}

function Get-SealedHeldTargetLocationKey {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([char]92,[char]47).ToLowerInvariant().Replace([char]92,[char]47)
}

function Get-SealedHeldTargetDirectoryEvidence {
    param(
        [Parameter(Mandatory)]$Handle,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$ParentHandle,
        [AllowNull()][string]$LeafName,
        [Parameter(Mandatory)][string]$VolumeId
    )

    if ($Handle -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($Handle)) { throw 'target-context-plan-stale: held directory type changed' }
    $handleInfo = [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($Handle)
    $securityBefore = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($Handle)
    $streamsBefore = @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($Handle))
    $securityAfter = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($Handle)
    $streamsAfter = @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($Handle))
    if ([string]$securityBefore.Identity -cne [string]$securityAfter.Identity -or
        [long]$securityBefore.LinkCount -ne [long]$securityAfter.LinkCount -or
        [string]$securityBefore.Sddl -cne [string]$securityAfter.Sddl) {
        throw 'target-context-plan-stale: held directory security changed during capture'
    }
    if ([string]$securityAfter.Identity -cne [string]$handleInfo.Identity -or
        [long]$securityAfter.LinkCount -ne 1 -or
        [string]$handleInfo.Identity -cne [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($Handle) -or
        [long]$handleInfo.LinkCount -ne [long][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredLinkCountExact($Handle) -or
        [bool]$handleInfo.IsReparsePoint -or -not [bool]$handleInfo.IsDirectory) {
        throw 'target-context-plan-stale: held directory identity/type/link contract changed'
    }
    if ($streamsBefore.Count -ne 0 -or $streamsAfter.Count -ne 0) { throw 'target-context-plan-stale: held directory has named streams' }
    if (-not ([string]$securityAfter.Identity).StartsWith(($VolumeId + ':'),[StringComparison]::Ordinal)) {
        throw 'target-context-plan-stale: held directory identity/volume mismatch'
    }
    $securityHash = Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/held-target-directory-security/v1'
        Identity = [string]$securityAfter.Identity
        LinkCount = [long]$securityAfter.LinkCount
        Sddl = [string]$securityAfter.Sddl
    })
    return [pscustomobject][ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        LocationKey = Get-SealedHeldTargetLocationKey -Path $Path
        Identity = [string]$securityAfter.Identity
        Type = 'Directory'
        ReparsePoint = $false
        VolumeId = $VolumeId
        LinkCount = [long]$securityAfter.LinkCount
        OwnerDaclHash = $securityHash
        NamedStreamCount = 0L
        SecuritySddl = [string]$securityAfter.Sddl
        Handle = $Handle
        ParentHandle = $ParentHandle
        LeafName = $LeafName
    }
}

function Get-SealedHeldTargetLegacyMetadata {
    param(
        [Parameter(Mandatory)][string]$RequestedPath,
        [Parameter(Mandatory)][ValidateSet('MISSING','EXISTS')][string]$TargetStatus,
        [Parameter(Mandatory)][ValidateSet('MISSING','Directory')][string]$TargetType,
        [Parameter(Mandatory)][string]$VolumeId,
        [Parameter(Mandatory)][object[]]$DirectoryRows,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MissingRemainder
    )

    $legacyAncestors = @($DirectoryRows | ForEach-Object {
        [ordered]@{ Path=[string]$_.Path; Identity=[string]$_.Identity; Type='Directory'; ReparsePoint=$false }
    })
    $deepest = $DirectoryRows[$DirectoryRows.Count - 1]
    return [ordered]@{
        LocationKey = Get-SealedHeldTargetLocationKey -Path $RequestedPath
        RequestedPath = [IO.Path]::GetFullPath($RequestedPath).TrimEnd([char]92,[char]47)
        TargetStatus = $TargetStatus
        TargetType = $TargetType
        VolumeId = $VolumeId
        DeepestExistingParentPath = [string]$deepest.Path
        DeepestExistingParentIdentity = [string]$deepest.Identity
        MissingRemainder = @($MissingRemainder)
        Ancestors = @($legacyAncestors)
    }
}

function Get-SealedHeldTargetMetadataHash {
    param([Parameter(Mandatory)]$Projection)
    return Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/held-target-metadata/v1'
        ResolverVersion = [string]$Projection.ResolverVersion
        CaptureKind = [string]$Projection.CaptureKind
        LocationKey = [string]$Projection.LocationKey
        RequestedPath = [string]$Projection.RequestedPath
        VolumeRootPath = [string]$Projection.VolumeRootPath
        VolumeId = [string]$Projection.VolumeId
        VolumeSerial = [string]$Projection.VolumeSerial
        DriveType = [string]$Projection.DriveType
        FileSystemType = [string]$Projection.FileSystemType
        TargetStatus = [string]$Projection.TargetStatus
        TargetType = [string]$Projection.TargetType
        DeepestExistingParentPath = [string]$Projection.DeepestExistingParentPath
        DeepestExistingParentIdentity = [string]$Projection.DeepestExistingParentIdentity
        DeepestExistingParentOwnerDaclHash = [string]$Projection.DeepestExistingParentOwnerDaclHash
        MissingRemainder = @($Projection.MissingRemainder)
        DirectoryIdentity = $Projection.DirectoryIdentity
        Ancestors = @($Projection.Ancestors)
        RequestedInitialRootContextHash = [string]$Projection.RequestedInitialRootContextHash
        FilesystemCapabilityStatus = [string]$Projection.FilesystemCapabilityStatus
        FilesystemCapabilityHash = $Projection.FilesystemCapabilityHash
    })
}

function Open-SealedHeldTargetContextLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AiAgentDotfiles.SealedOwnershipTransferReceiver]$OwnershipReceiver
    )

    $handles = [Collections.Generic.List[object]]::new()
    $lease = $null
    $receipt = $null
    $pendingHandle = $null
    $ownershipTransferred = $false
    $primaryError = $null
    try {
        $OwnershipReceiver.AssertEmptyExact()
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) { throw 'target path must be fully-qualified and absolute' }
        if ($Path.StartsWith('\\',[StringComparison]::Ordinal)) { throw 'network/UNC target is unsupported' }
        $rawFull = [IO.Path]::GetFullPath($Path)
        $volumeRoot = [IO.Path]::GetPathRoot($rawFull)
        if ([string]::IsNullOrWhiteSpace($volumeRoot) -or [IO.Path]::GetRelativePath($volumeRoot,$rawFull) -ceq '.') { throw 'volume root cannot be a target' }
        $full = $rawFull.TrimEnd([char]92,[char]47)
        $segments = @([IO.Path]::GetRelativePath($volumeRoot,$full) -split '[\\/]')
        foreach ($segment in $segments) {
            if ($segment -in @('', '.', '..') -or $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "unsafe target path segment: $segment" }
        }
        if (@($segments | Where-Object { $_ -ieq '.system' }).Count -gt 0) { throw '.system cannot be a managed target' }

        $pendingHandle = [AiAgentDotfiles.NoFollowFile]::HoldDirectory($volumeRoot)
        $handles.Add($pendingHandle)
        $rootHandle = $pendingHandle
        $pendingHandle = $null
        $volume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($volumeRoot)
        $volumeId = ([string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($rootHandle) -split ':')[0]
        if ([string]$volume.VolumeSerial -cne $volumeId) { throw 'target volume identity/serial mismatch' }
        $rows = [Collections.Generic.List[object]]::new()
        $rows.Add((Get-SealedHeldTargetDirectoryEvidence -Handle $rootHandle -Path $volumeRoot -ParentHandle $null -LeafName $null -VolumeId $volumeId))

        $parentHandle = $rootHandle
        $currentPath = $volumeRoot
        $missingRemainder = [Collections.Generic.List[string]]::new()
        $firstMissingName = $null
        $firstMissingParent = $null
        for ($index=0; $index -lt $segments.Count; $index++) {
            $segment = [string]$segments[$index]
            if ($null -ne $firstMissingName) { $missingRemainder.Add($segment); continue }
            $candidate = [IO.Path]::GetFullPath((Join-Path $currentPath $segment))
            $info = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($parentHandle,$segment)
            if ($null -eq $info) {
                $firstMissingName = $segment
                $firstMissingParent = $parentHandle
                $missingRemainder.Add($segment)
                continue
            }
            if ($info.IsReparsePoint -or -not $info.IsDirectory) { throw "target path contains a non-directory or reparse entry: $candidate" }
            if ([long]$info.LinkCount -ne 1) { throw "target path contains a multi-link directory: $candidate" }
            $pendingHandle = [AiAgentDotfiles.NoFollowFile]::TryHoldPathChildDirectory($parentHandle,$segment)
            if ($null -eq $pendingHandle) { throw "target path changed during held capture: $candidate" }
            $child = $pendingHandle
            $accepted = $false
            try {
                $childInfo = [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($child)
                if ([string]$childInfo.Identity -cne [string]$info.Identity -or
                    [string]$childInfo.Identity -cne [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($child) -or
                    [long]$childInfo.LinkCount -ne 1) { throw "target path identity changed during held capture: $candidate" }
                $handles.Add($child)
                $accepted = $true
                $pendingHandle = $null
            }
            finally {
                if (-not $accepted -and $pendingHandle -is [AiAgentDotfiles.SafeDirectoryHandle]) {
                    [AiAgentDotfiles.SafeDirectoryHandle]::DisposeExact($pendingHandle)
                    $pendingHandle = $null
                }
            }
            $rows.Add((Get-SealedHeldTargetDirectoryEvidence -Handle $child -Path $candidate -ParentHandle $parentHandle -LeafName $segment -VolumeId $volumeId))
            $parentHandle = $child
            $currentPath = $candidate
        }
        if ($null -ne $firstMissingName -and $null -ne [AiAgentDotfiles.NoFollowFile]::TryInspectChild($firstMissingParent,$firstMissingName)) {
            throw 'target first missing entry appeared during held capture'
        }

        $status = if ($null -eq $firstMissingName) { 'EXISTS' } else { 'MISSING' }
        $targetType = if ($status -ceq 'EXISTS') { 'Directory' } else { 'MISSING' }
        $legacy = Get-SealedHeldTargetLegacyMetadata -RequestedPath $full -TargetStatus $status -TargetType $targetType -VolumeId $volumeId -DirectoryRows @($rows) -MissingRemainder @($missingRemainder)
        $legacyHash = Get-SemanticJsonHash -InputObject $legacy
        $deepest = $rows[$rows.Count - 1]
        $ancestorProjection = @($rows | ForEach-Object {
            [pscustomobject][ordered]@{
                Path=[string]$_.Path; LocationKey=[string]$_.LocationKey; Identity=[string]$_.Identity
                Type='Directory'; ReparsePoint=$false; VolumeId=$volumeId; LinkCount=[long]$_.LinkCount
                OwnerDaclHash=[string]$_.OwnerDaclHash; NamedStreamCount=0L
            }
        })
        $projection = [pscustomobject][ordered]@{
            ResolverVersion = 'windows-no-follow-held-target-context-v1'
            CaptureKind = 'HELD_METADATA'
            LocationKey = [string]$legacy.LocationKey
            RequestedPath = [string]$legacy.RequestedPath
            VolumeRootPath = [IO.Path]::GetFullPath($volumeRoot)
            VolumeId = $volumeId
            VolumeSerial = [string]$volume.VolumeSerial
            DriveType = [string]$volume.DriveType
            FileSystemType = [string]$volume.FileSystemType
            TargetStatus = $status
            TargetType = $targetType
            DeepestExistingParentPath = [string]$legacy.DeepestExistingParentPath
            DeepestExistingParentIdentity = [string]$legacy.DeepestExistingParentIdentity
            DeepestExistingParentOwnerDaclHash = [string]$deepest.OwnerDaclHash
            MissingRemainder = @($missingRemainder)
            DirectoryIdentity = if($status -ceq 'EXISTS'){[string]$deepest.Identity}else{$null}
            Ancestors = @($ancestorProjection)
            RequestedInitialRootContextHash = $legacyHash
            FilesystemCapabilityStatus = 'UNPROBED'
            FilesystemCapabilityHash = $null
            HeldMetadataHash = $null
        }
        $projection.HeldMetadataHash = Get-SealedHeldTargetMetadataHash -Projection $projection
        $lease = [pscustomobject][ordered]@{
            Projection = $projection
            LegacyMetadata = $legacy
            DirectoryRows = @($rows)
            Handles = @($handles)
            FirstMissingParentHandle = $firstMissingParent
            FirstMissingName = $firstMissingName
            IsClosed = $false
        }
        $lease.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.SealedHeldTargetContextLease')
        foreach ($heldHandle in @($handles)) {
            if ($heldHandle -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($heldHandle)) {
                throw 'target-context-plan-stale: held target lease contains an invalid acquired handle'
            }
        }
        if ($null -ne $firstMissingParent -and $firstMissingParent -isnot [AiAgentDotfiles.SafeDirectoryHandle]) {
            throw 'target-context-plan-stale: held target lease has an invalid first-missing parent'
        }
        $receipt = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::BindExact(
            $lease,$projection,$legacy,[object[]]@($rows),[object[]]@($handles),$firstMissingParent,$firstMissingName)
        $null = Assert-SealedHeldTargetContextLease -Lease $lease
        $OwnershipReceiver.DeliverExact($lease)
        $ownershipTransferred = $true
        return
    }
    catch {
        $caughtError = $_
        if ($caughtError.Exception.Message -like 'target-context-plan-stale:*') {
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
        $receiverOwnsLease = $null -ne $OwnershipReceiver -and $OwnershipReceiver.HoldsExact($lease)
        if (-not $ownershipTransferred -and -not $receiverOwnsLease) {
            $cleanupError = $null
            if ($null -ne $receipt) {
                try { $null = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($lease) }
                catch { $cleanupError = $_ }
            }
            else {
                if ($pendingHandle -is [AiAgentDotfiles.SafeDirectoryHandle]) {
                    try { [AiAgentDotfiles.SafeDirectoryHandle]::DisposeExact($pendingHandle) }
                    catch { $cleanupError = $_ }
                }
                for ($index=$handles.Count-1; $index -ge 0; $index--) {
                    try { [AiAgentDotfiles.SafeDirectoryHandle]::DisposeExact($handles[$index]) }
                    catch { if ($null -eq $cleanupError) { $cleanupError = $_ } }
                }
            }
            if ($null -ne $cleanupError) {
                if ($null -ne $primaryError) {
                    try { $primaryError.Exception.Data['SealedHeldTargetContextCleanupError'] = [string]$cleanupError.Exception.Message }
                    catch { }
                }
                else { throw $cleanupError }
            }
        }
    }
}

function Assert-SealedHeldTargetContextLease {
    [CmdletBinding()]
    param([AllowNull()]$Lease)

    try {
        $receipt = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($Lease)
        if ($null -eq $Lease -or 'AiAgentDotfiles.SealedHeldTargetContextLease' -cnotin @($Lease.PSObject.TypeNames) -or
            $receipt -isnot [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt] -or
            -not [object]::ReferenceEquals([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetWrapperExact($receipt),$Lease) -or
            -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($receipt)) {
            throw 'held target lease is missing, untyped, or closed'
        }
        $projection = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetProjectionExact($receipt)
        $legacyMetadata = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetLegacyMetadataExact($receipt)
        $rows = @([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetDirectoryRowsExact($receipt))
        $handles = @([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact($receipt))
        $firstMissingParentHandle = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetFirstMissingParentHandleExact($receipt)
        $firstMissingName = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetFirstMissingNameExact($receipt)
        $hasFirstMissing = -not [string]::IsNullOrEmpty([string]$firstMissingName)
        if ([string]$projection.CaptureKind -cne 'HELD_METADATA' -or [string]$projection.FilesystemCapabilityStatus -cne 'UNPROBED' -or $null -ne $projection.FilesystemCapabilityHash) {
            throw 'held target lease misstates filesystem capability coverage'
        }
        if ((Get-SemanticJsonHash -InputObject $legacyMetadata) -cne [string]$projection.RequestedInitialRootContextHash -or
            (Get-SealedHeldTargetMetadataHash -Projection $projection) -cne [string]$projection.HeldMetadataHash) {
            throw 'held target metadata hash mismatch'
        }
        $volume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo([string]$projection.VolumeRootPath)
        if ([string]$volume.VolumeSerial -cne [string]$projection.VolumeId -or [string]$volume.VolumeSerial -cne [string]$projection.VolumeSerial -or
            [string]$volume.DriveType -cne [string]$projection.DriveType -or [string]$volume.FileSystemType -cne [string]$projection.FileSystemType) {
            throw 'held target volume metadata changed'
        }
        if ($rows.Count -eq 0 -or $handles.Count -ne $rows.Count -or @($projection.Ancestors).Count -ne $rows.Count) { throw 'held target ancestor cardinality changed' }
        for ($index=0; $index -lt $rows.Count; $index++) {
            $row = $rows[$index]
            if ($handles[$index] -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or
                -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($handles[$index]) -or
                -not [object]::ReferenceEquals($handles[$index],$row.Handle)) { throw 'held target handle ordering changed' }
            $expectedRowPath = if ($index -eq 0) { [IO.Path]::GetFullPath([string]$projection.VolumeRootPath) } else { [IO.Path]::GetFullPath((Join-Path ([string]$rows[$index-1].Path) ([string]$row.LeafName))) }
            if ([string]$row.Path -cne $expectedRowPath -or ($index -gt 0 -and -not [object]::ReferenceEquals($row.ParentHandle,$rows[$index-1].Handle))) {
                throw 'held target ancestor path/parent binding changed'
            }
            $actual = Get-SealedHeldTargetDirectoryEvidence -Handle $row.Handle -Path ([string]$row.Path) -ParentHandle $row.ParentHandle -LeafName $row.LeafName -VolumeId ([string]$projection.VolumeId)
            if ([string]$actual.Identity -cne [string]$row.Identity -or [long]$actual.LinkCount -ne [long]$row.LinkCount -or
                [string]$actual.OwnerDaclHash -cne [string]$row.OwnerDaclHash -or [string]$actual.SecuritySddl -cne [string]$row.SecuritySddl) {
                throw 'held target ancestor identity/security changed'
            }
            $projected = @($projection.Ancestors)[$index]
            foreach ($name in @('Path','LocationKey','Identity','Type','ReparsePoint','VolumeId','LinkCount','OwnerDaclHash','NamedStreamCount')) {
                if ([string]$projected.$name -cne [string]$row.$name) { throw "held target ancestor projection changed: $index/$name" }
            }
            if ($index -gt 0) {
                $namespace = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($row.ParentHandle,[string]$row.LeafName)
                if ($null -eq $namespace -or -not $namespace.IsDirectory -or $namespace.IsReparsePoint -or [long]$namespace.LinkCount -ne 1 -or [string]$namespace.Identity -cne [string]$row.Identity) {
                    throw 'held target ancestor namespace changed'
                }
            }
        }
        if ($hasFirstMissing -and ($firstMissingParentHandle -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or
            $null -ne [AiAgentDotfiles.NoFollowFile]::TryInspectChild($firstMissingParentHandle,[string]$firstMissingName))) {
            throw "held target first missing entry appeared: $([string]$projection.RequestedPath) / $firstMissingName"
        }
        $missing = @($projection.MissingRemainder)
        $status = if ($hasFirstMissing) { 'MISSING' } else { 'EXISTS' }
        if ([string]$projection.TargetStatus -cne $status -or [string]$projection.TargetType -cne $(if($status -ceq 'EXISTS'){'Directory'}else{'MISSING'}) -or
            ($status -ceq 'EXISTS' -and ([string]$projection.DirectoryIdentity -cne [string]$rows[-1].Identity -or $missing.Count -ne 0 -or [string]$projection.RequestedPath -cne [string]$rows[-1].Path)) -or
            ($status -ceq 'MISSING' -and ($null -ne $projection.DirectoryIdentity -or $missing.Count -eq 0 -or [string]$missing[0] -cne [string]$firstMissingName))) {
            throw 'held target status/identity branch changed'
        }
        if ([string]$projection.DeepestExistingParentPath -cne [string]$rows[-1].Path -or
            [string]$projection.DeepestExistingParentIdentity -cne [string]$rows[-1].Identity -or
            [string]$projection.DeepestExistingParentOwnerDaclHash -cne [string]$rows[-1].OwnerDaclHash) {
            throw 'held target deepest-parent projection changed'
        }
        if ($status -ceq 'MISSING') {
            $reconstructed = [IO.Path]::GetFullPath((Join-Path ([string]$rows[-1].Path) ([IO.Path]::Combine([string[]]$missing))))
            if ($reconstructed -cne [string]$projection.RequestedPath) { throw 'held target missing remainder no longer reconstructs the requested path' }
        }
        $rebuiltLegacy = Get-SealedHeldTargetLegacyMetadata -RequestedPath ([string]$projection.RequestedPath) -TargetStatus $status -TargetType ([string]$projection.TargetType) -VolumeId ([string]$projection.VolumeId) -DirectoryRows $rows -MissingRemainder $missing
        if ((Get-SemanticJsonHash -InputObject $rebuiltLegacy) -cne (Get-SemanticJsonHash -InputObject $legacyMetadata)) { throw 'held target legacy metadata projection changed' }
        return $true
    }
    catch {
        if ($_.Exception.Message -like 'target-context-plan-stale:*') { throw }
        throw "target-context-plan-stale: $($_.Exception.Message)"
    }
}

function Get-SealedHeldTargetContextLease {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lease)
    $null = Assert-SealedHeldTargetContextLease -Lease $Lease
    $receipt = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($Lease)
    return [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetProjectionExact($receipt)
}

function Close-SealedHeldTargetContextLease {
    [CmdletBinding()]
    param([AllowNull()]$Lease)
    if ($null -eq $Lease) { return }
    $receipt = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($Lease)
    if ($receipt -isnot [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]) { throw 'target-context-plan-stale: held target lease receipt is missing' }
    $null = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($Lease)
    try {
        if ([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($receipt) -and
            $null -ne $Lease.PSObject.Properties['IsClosed'] -and $Lease.PSObject.Properties['IsClosed'].MemberType -eq 'NoteProperty') {
            $Lease.PSObject.Properties['IsClosed'].Value = $true
        }
    }
    catch { }
}

function Assert-SealedHeldTargetContextMatchesMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    try {
        foreach ($name in @('LocationKey','RequestedPath','TargetStatus','TargetType','VolumeId','DeepestExistingParentPath','DeepestExistingParentIdentity','RequestedInitialRootContextHash','FilesystemCapabilityStatus')) {
            if ($null -eq $Expected.PSObject.Properties[$name] -or [string]$Expected.$name -cne [string]$Actual.$name) { throw "metadata field changed: $name" }
        }
        if ([string]$Expected.FilesystemCapabilityStatus -cne 'UNPROBED' -or $null -ne $Expected.FilesystemCapabilityHash -or
            [string]$Actual.FilesystemCapabilityStatus -cne 'UNPROBED' -or $null -ne $Actual.FilesystemCapabilityHash) {
            throw 'metadata comparison attempted to claim filesystem capability coverage'
        }
        $expectedMissing = @($Expected.MissingRemainder); $actualMissing = @($Actual.MissingRemainder)
        if ($expectedMissing.Count -ne $actualMissing.Count) { throw 'missing remainder cardinality changed' }
        for ($index=0; $index -lt $expectedMissing.Count; $index++) { if ([string]$expectedMissing[$index] -cne [string]$actualMissing[$index]) { throw 'missing remainder changed' } }
        $expectedAncestors = @($Expected.Ancestors); $actualAncestors = @($Actual.Ancestors)
        if ($expectedAncestors.Count -ne $actualAncestors.Count) { throw 'ancestor cardinality changed' }
        for ($index=0; $index -lt $expectedAncestors.Count; $index++) {
            foreach ($name in @('Path','Identity','Type','ReparsePoint')) {
                if ([string]$expectedAncestors[$index].$name -cne [string]$actualAncestors[$index].$name) { throw "ancestor metadata changed: $index/$name" }
            }
        }
        return $true
    }
    catch {
        if ($_.Exception.Message -like 'target-context-plan-stale:*') { throw }
        throw "target-context-plan-stale: $($_.Exception.Message)"
    }
}

function Remove-TargetFilesystemCapabilityProbeOwnedSlot {
    param(
        [Parameter(Mandatory)]$SlotHandle,
        [Parameter(Mandatory)][string]$SlotIdentity,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedFiles,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedDirectories
    )

    $cleanupFailures = [Collections.Generic.List[Exception]]::new()
    try {
        foreach ($rows in @(@($OwnedFiles),@($OwnedDirectories))) {
            for ($index=$rows.Count-1; $index -ge 0; $index--) {
                $held = $rows[$index].Handle
                if ($null -ne $held) {
                    try { $held.Dispose() }
                    catch { $cleanupFailures.Add($_.Exception) }
                    $rows[$index].Handle = $null
                }
            }
        }

        $fileNames = [Collections.Generic.List[string]]::new()
        for ($index=$OwnedFiles.Count-1; $index -ge 0; $index--) {
            foreach ($name in @($OwnedFiles[$index].Names)) {
                if (-not $fileNames.Contains([string]$name)) { $fileNames.Add([string]$name) }
            }
        }
        foreach ($name in $fileNames) {
            try {
                $current = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($SlotHandle,$name)
                if ($null -eq $current) { continue }
                $owner = @($OwnedFiles | Where-Object {
                    [string]$_.Identity -ceq [string]$current.Identity -and @($_.Names) -ccontains [string]$name
                })
                if ($owner.Count -ne 1) { throw "capability-probe-owned-file-identity-mismatch: $name" }
                if ([bool]$current.IsDirectory -or [bool]$current.IsReparsePoint) { throw "capability-probe-owned-file-type-mismatch: $name" }
                $deleted = [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($SlotHandle,$name,[string]$owner[0].Identity)
                if ([string]$deleted.Identity -cne [string]$owner[0].Identity) { throw "capability-probe-owned-file-delete-receipt-mismatch: $name" }
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }

        $directoryNames = [Collections.Generic.List[string]]::new()
        for ($index=$OwnedDirectories.Count-1; $index -ge 0; $index--) {
            foreach ($name in @($OwnedDirectories[$index].Names)) {
                if (-not $directoryNames.Contains([string]$name)) { $directoryNames.Add([string]$name) }
            }
        }
        foreach ($name in $directoryNames) {
            try {
                $current = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($SlotHandle,$name)
                if ($null -eq $current) { continue }
                $owner = @($OwnedDirectories | Where-Object {
                    [string]$_.Identity -ceq [string]$current.Identity -and @($_.Names) -ccontains [string]$name
                })
                if ($owner.Count -ne 1) { throw "capability-probe-owned-directory-identity-mismatch: $name" }
                if (-not [bool]$current.IsDirectory -or [bool]$current.IsReparsePoint) { throw "capability-probe-owned-directory-type-mismatch: $name" }
                $deleted = [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($SlotHandle,$name,[string]$owner[0].Identity)
                if ([string]$deleted.Identity -cne [string]$owner[0].Identity) { throw "capability-probe-owned-directory-delete-receipt-mismatch: $name" }
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }

        try {
            $remaining = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($SlotHandle))
            if ($remaining.Count -ne 0) {
                throw ('capability-probe-owned-slot-residue: ' + (@($remaining | Sort-Object) -join ','))
            }
            $deletedSlot = [AiAgentDotfiles.NoFollowFile]::DeleteHeldEmptyDirectoryIfIdentity($SlotHandle,$SlotIdentity)
            if ([string]$deletedSlot.Identity -cne $SlotIdentity) { throw 'capability-probe-owned-slot-delete-receipt-mismatch' }
        }
        catch { $cleanupFailures.Add($_.Exception) }
    }
    catch { $cleanupFailures.Add($_.Exception) }
    finally {
        if ($null -ne $SlotHandle -and [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($SlotHandle)) {
            try { [AiAgentDotfiles.SafeDirectoryHandle]::DisposeExact($SlotHandle) }
            catch { $cleanupFailures.Add($_.Exception) }
        }
    }
    if ($cleanupFailures.Count -ne 0) {
        $messages = @($cleanupFailures | ForEach-Object { $_.Message }) -join ' | '
        $inner = if ($cleanupFailures.Count -eq 1) { $cleanupFailures[0] } else {
            [AggregateException]::new('capability-probe-owned-slot-cleanup-failures',[Exception[]]$cleanupFailures.ToArray())
        }
        throw [InvalidOperationException]::new("capability-probe-owned-slot-cleanup-failed: $messages",$inner)
    }
}

function Invoke-TargetFilesystemCapabilityProbe {
    param(
        [Parameter(Mandatory)][string]$ProbeRoot,
        [Parameter(Mandatory)]$VolumeInfo,
        [Parameter(Mandatory)][string]$ExpectedProbeRootIdentity
    )

    $probeRootHandles = $null
    $probeRootResiduePrecheckPassed = $false
    $probeRootResidueFailure = $null
    $slotHandle = $null
    $slotIdentity = $null
    $slotName = $null
    $ownedFiles = [Collections.Generic.List[object]]::new()
    $ownedDirectories = [Collections.Generic.List[object]]::new()
    $primaryFailure = $null
    $cleanupFailures = [Collections.Generic.List[Exception]]::new()
    $capabilityHash = $null
    try {
        if ([string]::IsNullOrWhiteSpace($ProbeRoot) -or -not [IO.Path]::IsPathFullyQualified($ProbeRoot) -or
            $ProbeRoot.StartsWith('\',[StringComparison]::Ordinal)) { throw 'capability-probe-root-invalid' }
        if ([string]::IsNullOrWhiteSpace($ExpectedProbeRootIdentity)) { throw 'capability-probe-root-stale' }
        $probeRootFull = [IO.Path]::GetFullPath($ProbeRoot).TrimEnd([char]92,[char]47)
        if ([string]::IsNullOrWhiteSpace($probeRootFull) -or [IO.Path]::GetPathRoot($probeRootFull) -ceq $probeRootFull) { throw 'capability-probe-root-invalid' }

        try {
            $probeRootHandles = Open-SafeDirectoryContainmentChain -Path $probeRootFull
            if (@($probeRootHandles).Count -eq 0) { throw 'capability-probe-root-stale' }
            $probeRootHandle = $probeRootHandles[$probeRootHandles.Count-1]
            $probeRootAcquiredIdentity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($probeRootHandle)
            $probeRootReceipt = [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($probeRootHandle)
            $probeRootCurrent = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($probeRootHandle)
            if ($probeRootHandle -isnot [AiAgentDotfiles.SafeDirectoryHandle] -or
                -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($probeRootHandle) -or
                $null -eq $probeRootReceipt -or -not [bool]$probeRootReceipt.IsDirectory -or [bool]$probeRootReceipt.IsReparsePoint -or
                $probeRootAcquiredIdentity -cne $ExpectedProbeRootIdentity -or
                [string]$probeRootReceipt.Identity -cne $probeRootAcquiredIdentity -or
                [string]$probeRootCurrent.Identity -cne $probeRootAcquiredIdentity -or
                [long]$probeRootCurrent.LinkCount -ne [long][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredLinkCountExact($probeRootHandle)) {
                throw 'capability-probe-root-stale'
            }
        }
        catch { throw 'capability-probe-root-stale' }

        $preexistingProbeResidue = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($probeRootHandle) | Where-Object {
            ([string]$_).StartsWith('.target-capability-',[StringComparison]::OrdinalIgnoreCase)
        })
        if ($preexistingProbeResidue.Count -ne 0) { throw 'capability-probe-root-residue' }
        $probeRootResiduePrecheckPassed = $true

        $probeVolume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($probeRootFull)
        $heldVolumeId = ($probeRootAcquiredIdentity -split ':')[0]
        if ([string]$probeVolume.VolumeSerial -cne $heldVolumeId -or
            [string]$probeVolume.VolumeSerial -cne [string]$VolumeInfo.VolumeSerial) {
            throw 'capability probe must be on the target volume'
        }
        Assert-SupportedTargetFilesystem -DriveType $VolumeInfo.DriveType -FileSystemType $VolumeInfo.FileSystemType

        $slotName = ".target-capability-$([Guid]::NewGuid().ToString('N'))"
        $slotPath = Join-Path $probeRootFull $slotName
        $slotHandle = [AiAgentDotfiles.NoFollowFile]::CreateHeldChildDirectoryForCleanup($probeRootHandle,$slotName)
        $slotIdentity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($slotHandle)
        $slotReceipt = [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($slotHandle)
        if ([string]$slotReceipt.Identity -cne $slotIdentity -or -not [bool]$slotReceipt.IsDirectory -or [bool]$slotReceipt.IsReparsePoint -or
            -not $slotIdentity.StartsWith(($heldVolumeId + ':'),[StringComparison]::Ordinal)) { throw 'capability-probe-owned-slot-identity-invalid' }

        $directoryRow = [pscustomobject][ordered]@{Identity=$null;Names=@('directory-new','directory-old');Handle=$null}
        $directoryRow.Handle = [AiAgentDotfiles.NoFollowFile]::CreateHeldChildDirectoryForCleanup($slotHandle,'directory-old')
        $directoryRow.Identity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($directoryRow.Handle)
        $ownedDirectories.Add($directoryRow)
        [AiAgentDotfiles.SafeDirectoryHandle]::DisposeExact($directoryRow.Handle)
        $directoryRow.Handle = $null
        [IO.Directory]::Move((Join-Path $slotPath 'directory-old'),(Join-Path $slotPath 'directory-new'))
        $renamedDirectoryHandle = $null
        try {
            $renamedDirectoryHandle = [AiAgentDotfiles.NoFollowFile]::HoldChildDirectory($slotHandle,'directory-new')
            if ([string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($renamedDirectoryHandle) -cne [string]$directoryRow.Identity -or
                $null -ne [AiAgentDotfiles.NoFollowFile]::TryInspectChild($slotHandle,'directory-old')) {
                throw 'directory rename probe postcondition failed'
            }
            $directoryRow.Handle = $renamedDirectoryHandle
            $renamedDirectoryHandle = $null
        }
        finally { if ($null -ne $renamedDirectoryHandle) { [AiAgentDotfiles.SafeDirectoryHandle]::DisposeExact($renamedDirectoryHandle) } }

        $oldBytes = [Text.UTF8Encoding]::new($false).GetBytes('old')
        $newBytes = [Text.UTF8Encoding]::new($false).GetBytes('new')
        $destinationRow = [pscustomobject][ordered]@{Identity=$null;Names=@('replace-backup.txt','replace-target.txt');Handle=$null}
        $destinationRow.Handle = [AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($slotHandle,'replace-target.txt',$oldBytes)
        $destinationRow.Identity = [string]$destinationRow.Handle.ReadResult.Identity
        $ownedFiles.Add($destinationRow)
        $replacementRow = [pscustomobject][ordered]@{Identity=$null;Names=@('replace-target.txt','replace-source.txt');Handle=$null}
        $replacementRow.Handle = [AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($slotHandle,'replace-source.txt',$newBytes)
        $replacementRow.Identity = [string]$replacementRow.Handle.ReadResult.Identity
        $ownedFiles.Add($replacementRow)

        $replacementRow.Handle.Dispose(); $replacementRow.Handle=$null
        $destinationRow.Handle.Dispose(); $destinationRow.Handle=$null
        [IO.File]::Replace(
            (Join-Path $slotPath 'replace-source.txt'),
            (Join-Path $slotPath 'replace-target.txt'),
            (Join-Path $slotPath 'replace-backup.txt'),$true)

        $targetHandle = $null
        $backupHandle = $null
        try {
            $targetHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($slotHandle,'replace-target.txt')
            $backupHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($slotHandle,'replace-backup.txt')
            if ([string]$targetHandle.ReadResult.Identity -cne [string]$replacementRow.Identity -or
                [string]$backupHandle.ReadResult.Identity -cne [string]$destinationRow.Identity -or
                $null -ne [AiAgentDotfiles.NoFollowFile]::TryInspectChild($slotHandle,'replace-source.txt') -or
                -not [Linq.Enumerable]::SequenceEqual[byte]([AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($targetHandle,$newBytes.LongLength),$newBytes) -or
                -not [Linq.Enumerable]::SequenceEqual[byte]([AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($backupHandle,$oldBytes.LongLength),$oldBytes)) {
                throw 'atomic replace probe postcondition failed'
            }
            $replacementRow.Handle=$targetHandle; $targetHandle=$null
            $destinationRow.Handle=$backupHandle; $backupHandle=$null
        }
        finally {
            if ($null -ne $backupHandle) { $backupHandle.Dispose() }
            if ($null -ne $targetHandle) { $targetHandle.Dispose() }
        }

        $capabilityHash = Get-SemanticJsonHash -InputObject ([ordered]@{
            ProtocolVersion=1; DriveType=[string]$VolumeInfo.DriveType; FileSystemType=[string]$VolumeInfo.FileSystemType
            VolumeSerial=[string]$VolumeInfo.VolumeSerial; DirectoryRename=$true; AtomicReplace=$true
        })
    }
    catch { $primaryFailure = $_ }
    finally {
        if ($null -ne $slotHandle) {
            try {
                Remove-TargetFilesystemCapabilityProbeOwnedSlot -SlotHandle $slotHandle -SlotIdentity $slotIdentity `
                    -OwnedFiles @($ownedFiles) -OwnedDirectories @($ownedDirectories)
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        if ($probeRootResiduePrecheckPassed -and $null -ne $probeRootHandles -and
            @($probeRootHandles).Count -ne 0 -and
            [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($probeRootHandles[$probeRootHandles.Count-1])) {
            try {
                $heldProbeRoot = $probeRootHandles[$probeRootHandles.Count-1]
                $matchingResidueNames = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($heldProbeRoot) | Where-Object {
                    ([string]$_).StartsWith('.target-capability-',[StringComparison]::OrdinalIgnoreCase)
                })
                $ownedSlotStillPresent = $false
                if ($matchingResidueNames -ccontains $slotName -and -not [string]::IsNullOrWhiteSpace($slotIdentity)) {
                    $currentSlot = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($heldProbeRoot,$slotName)
                    $ownedSlotStillPresent = $null -ne $currentSlot -and
                        [string]$currentSlot.Identity -ceq $slotIdentity -and
                        [bool]$currentSlot.IsDirectory -and -not [bool]$currentSlot.IsReparsePoint
                }
                $foreignResidueNames = @($matchingResidueNames | Where-Object {
                    -not ($ownedSlotStillPresent -and [string]$_ -ceq $slotName)
                })
                if ($foreignResidueNames.Count -ne 0) {
                    $probeRootResidueFailure = [InvalidOperationException]::new('capability-probe-root-residue')
                }
            }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        if ($null -ne $probeRootHandles) {
            try { Close-SafeDirectoryContainmentChain -Handles $probeRootHandles }
            catch { $cleanupFailures.Add($_.Exception) }
        }
    }

    $cleanupFailure = $null
    if ($cleanupFailures.Count -ne 0) {
        $cleanupMessages = @($cleanupFailures | ForEach-Object { $_.Message }) -join ' | '
        $cleanupInner = if ($cleanupFailures.Count -eq 1) { $cleanupFailures[0] } else {
            [AggregateException]::new('capability-probe-cleanup-failures',[Exception[]]$cleanupFailures.ToArray())
        }
        $cleanupFailure = [InvalidOperationException]::new("capability-probe-cleanup-failed: $cleanupMessages",$cleanupInner)
    }
    if ($null -ne $probeRootResidueFailure -and $null -ne $cleanupFailure) {
        $probeRootResidueFailure = [InvalidOperationException]::new(
            'capability-probe-root-residue',
            [AggregateException]::new(
                'capability-probe-root-residue-and-cleanup-failures',
                [Exception[]]@($probeRootResidueFailure,$cleanupFailure)))
    }
    $secondaryFailure = if ($null -ne $probeRootResidueFailure) { $probeRootResidueFailure } else { $cleanupFailure }
    if ($null -ne $primaryFailure) {
        if ($null -ne $secondaryFailure) {
            $combinedInner = [AggregateException]::new(
                'capability-probe-primary-and-cleanup-failures',
                [Exception[]]@($primaryFailure.Exception,$secondaryFailure))
            $combined = [InvalidOperationException]::new(
                "capability-probe-primary-and-cleanup-failed: primary=$($primaryFailure.Exception.Message); cleanup=$($secondaryFailure.Message)",
                $combinedInner)
            $combined.Data['CapabilityProbePrimaryFailure'] = $primaryFailure.Exception.Message
            $combined.Data['CapabilityProbeCleanupFailure'] = $secondaryFailure.Message
            throw $combined
        }
        throw $primaryFailure
    }
    if ($null -ne $probeRootResidueFailure) { throw $probeRootResidueFailure }
    if ($null -ne $cleanupFailure) { throw $cleanupFailure }
    return $capabilityHash
}

function Resolve-TargetContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('MetadataOnly','MutationPreflight')] [string] $Mode,
        [string] $HomeRoot,
        [string[]] $ForbiddenRoots = @(),
        [string] $ProbeRoot
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathFullyQualified($Path)) { throw 'target path must be fully-qualified and absolute' }
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal)) { throw 'network/UNC target is unsupported' }
    $metadata = Get-TargetMetadataContext -Path $Path
    if ($HomeRoot) {
        $homeFull = [System.IO.Path]::GetFullPath($HomeRoot).TrimEnd([char]92,[char]47)
        if ($metadata.RequestedPath.Equals($homeFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'HomeRoot itself cannot be a target' }
    }
    foreach ($root in @($ForbiddenRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $overlaps = Test-TargetPathOverlap -Left $metadata.RequestedPath -Right ([System.IO.Path]::GetFullPath($root))
        if ($overlaps) { throw "target overlap with forbidden root: $root" }
    }
    $intentHash = Get-SemanticJsonHash -InputObject $metadata
    $result = [ordered]@{}
    foreach ($key in $metadata.Keys) { $result[$key]=$metadata[$key] }
    $result.RequestedInitialRootContextHash = $intentHash
    if ($Mode -eq 'MetadataOnly') {
        $result.FilesystemCapabilityStatus='UNPROBED'; $result.FilesystemCapabilityHash=$null
        return [pscustomobject]$result
    }
    if ([string]::IsNullOrWhiteSpace($ProbeRoot)) { throw 'MutationPreflight requires an approved ProbeRoot' }
    $probeMetadata = Get-TargetMetadataContext -Path $ProbeRoot
    if ([string]$probeMetadata.TargetStatus -cne 'EXISTS' -or [string]$probeMetadata.TargetType -cne 'Directory' -or
        [string]::IsNullOrWhiteSpace([string]$probeMetadata.DeepestExistingParentIdentity)) { throw 'MutationPreflight requires an existing approved ProbeRoot' }
    $volume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($metadata.DeepestExistingParentPath)
    $result.FilesystemCapabilityStatus='SUPPORTED'
    $result.FilesystemCapabilityHash=Invoke-TargetFilesystemCapabilityProbe -ProbeRoot ([string]$probeMetadata.RequestedPath) -VolumeInfo $volume -ExpectedProbeRootIdentity ([string]$probeMetadata.DeepestExistingParentIdentity)
    $result.DriveType=[string]$volume.DriveType; $result.FileSystemType=[string]$volume.FileSystemType; $result.VolumeSerial=[string]$volume.VolumeSerial
    return [pscustomobject]$result
}
