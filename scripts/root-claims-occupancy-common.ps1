#requires -Version 7.0

# SID-scoped occupancy index for custom live-root claims (phase 4 proposal §4.2
# option 2 / Task 10). The index maps the (VolumeId, directory identity) of a
# custom live root to the {HomeAuthorityKey, ControlBase} that claimed it. Its
# well-known per-user location is derived from the CURRENT user's identity via
# the home-authority identity primitives — never $env:USERPROFILE, never
# ProgramData, and never ControlBase-relative, so two ControlBases on one
# Windows user observe the same index. Entries are create-new, no-follow,
# exact-byte schema-validated documents; a second claimant at an existing entry
# fails closed with 'root-claims-occupancy-conflict' while the same authority
# re-claiming its own entry is a no-op success. The gate never writes into a
# live skills tree and runs only under the claiming authority's held global
# live lock — the same sealed-lock style the registry requires for its global
# claim file, with no additional lock style.

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'home-authority-common.ps1')

$script:RootClaimsOccupancyRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RootClaimsOccupancyArtifactKind = 'root-claims-occupancy'
$script:RootClaimsOccupancyDomainLeaf = 'ai-agent-dotfiles.occupancy'
$script:RootClaimsOccupancyEntryKeyDomain = 'ai-agent-dotfiles/root-claims-occupancy-entry/v1'
$script:RootClaimsOccupancyMaximumEntryBytes = 1MB
$script:RootClaimsOccupancyEntryKeyPattern = '\A[0-9a-f]{64}\z'

function Get-RootClaimsOccupancyIdentity {
    # Single seam over the existing home-authority identity primitive. The
    # current token's SID and LocalAppData known folder are the per-user scope
    # of the index; production always resolves the real token, and the sealed
    # suites redirect this one function to keep their fixtures hermetic.
    [CmdletBinding()]
    param()

    return Get-WindowsHomeAuthorityIdentity
}

function Get-RootClaimsOccupancyTokenSid {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$OccupancyIdentity)

    $sid = Get-HomeAuthorityIdentityField -Identity $OccupancyIdentity -Name 'TokenSid'
    try { $canonicalSid = [Security.Principal.SecurityIdentifier]::new($sid).Value }
    catch { throw 'root-claims-occupancy-token-sid-invalid' }
    if ($sid -cne $canonicalSid) { throw 'root-claims-occupancy-token-sid-noncanonical' }
    return $canonicalSid
}

function Get-RootClaimsOccupancyRootPath {
    # Well-known per-user index root: <LocalAppData>\ai-agent-dotfiles.occupancy\<TokenSid>.
    # The ControlBase (<LocalAppData>\ai-agent-dotfiles\control) is a sibling of
    # the domain leaf's parent, never an ancestor of the index.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$OccupancyIdentity)

    $local = ConvertTo-HomeAuthorityKnownFolderPath -Path (Get-HomeAuthorityIdentityField -Identity $OccupancyIdentity -Name 'LocalAppDataRoot') -Name 'LocalAppData'
    $sid = Get-RootClaimsOccupancyTokenSid -OccupancyIdentity $OccupancyIdentity
    return [pscustomobject][ordered]@{
        LocalAppDataRoot = $local
        TokenSid = $sid
        DomainLeaf = $script:RootClaimsOccupancyDomainLeaf
        RootPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $local $script:RootClaimsOccupancyDomainLeaf) $sid))
    }
}

function Get-RootClaimsOccupancyEntryKey {
    # Entry key: the semantic hash binding (VolumeId, directory identity), in
    # the same derived-identity style as the HomeAuthorityKey.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{8}\z')][string]$VolumeId,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{8}:[0-9a-f]{16}\z')][string]$DirectoryIdentity
    )

    return Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = $script:RootClaimsOccupancyEntryKeyDomain
        VolumeId = $VolumeId
        DirectoryIdentity = $DirectoryIdentity
    })
}

function Get-RootClaimsOccupancyIndexPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$OccupancyIdentity,
        [Parameter(Mandatory)][string]$EntryKey
    )

    if ($EntryKey -cnotmatch $script:RootClaimsOccupancyEntryKeyPattern) { throw 'root-claims-occupancy-entry-key-invalid' }
    $root = Get-RootClaimsOccupancyRootPath -OccupancyIdentity $OccupancyIdentity
    return [IO.Path]::GetFullPath((Join-Path ([string]$root.RootPath) ($EntryKey + '.json')))
}

function Assert-RootClaimsOccupancySchemaBytes {
    # Exact-byte validation against the pinned repository schema and the pinned
    # validator binary, mirroring the registry's claims/state byte validation.
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$InstanceBytes)

    $schemaRoot = Join-Path $script:RootClaimsOccupancyRepoRoot 'schemas'
    $schemaPath = Join-Path $schemaRoot ($script:RootClaimsOccupancyArtifactKind + '.schema.json')
    $schemaValidation = Test-RepositoryJsonSchema -SchemaPath $schemaPath -SchemaRoot $schemaRoot
    $instanceLabel = Join-Path $schemaRoot ('.' + $script:RootClaimsOccupancyArtifactKind + '.in-memory.json')
    $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $schemaValidation -InstanceBytes $InstanceBytes -InstancePath $instanceLabel
}

function Test-RootClaimsOccupancySemantics {
    # Registered semantic validator for the 'root-claims-occupancy' artifact
    # contract: the entry key must bind the recorded (VolumeId, directory
    # identity) pair, and the directory identity must be canonical for its
    # recorded volume.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)

    $volumeId = [string]$Document.VolumeId
    if ($volumeId -cnotmatch '\A[0-9a-f]{8}\z') { throw 'root-claims-occupancy VolumeId is not canonical' }
    $directoryIdentity = [string]$Document.DirectoryIdentity
    if ($directoryIdentity -cnotmatch ('\A' + [regex]::Escape($volumeId) + ':[0-9a-f]{16}\z')) { throw 'root-claims-occupancy DirectoryIdentity is not canonical for its VolumeId' }
    $expectedKey = Get-RootClaimsOccupancyEntryKey -VolumeId $volumeId -DirectoryIdentity $directoryIdentity
    if ([string]$Document.EntryKey -cne $expectedKey) { throw 'root-claims-occupancy EntryKey does not bind the recorded (VolumeId, DirectoryIdentity)' }
}

function Assert-RootClaimsOccupancyCurrentUserOnlySnapshot {
    # Same ACL posture as the ControlBase: current-user-only. Accepts the
    # explicit protected template (with owner or token-default owner) and the
    # one inherited current-user ACE a create-new child receives beneath an
    # OI/CI protected parent — the allowed set the registry uses for its own
    # artifacts.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][ValidateSet('Directory','File')][string]$ResourceKind,
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$ExpectedIdentity
    )

    $explicit = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $TokenSid -ResourceKind $ResourceKind
    $evidence = ConvertFrom-HomeAuthoritySecuritySnapshot -Snapshot $Snapshot -ResourceKind $ResourceKind
    if ([string]$Snapshot.Identity -cne $ExpectedIdentity -or [long]$Snapshot.LinkCount -ne 1) { throw 'root-claims-occupancy security identity changed' }
    $actualHash = Get-SemanticJsonHash -InputObject $evidence
    $allowedHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null = $allowedHashes.Add((Get-SemanticJsonHash -InputObject $explicit))
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
    $defaultOwnerSid = Get-HomeAuthorityTokenDefaultOwnerSid
    $null = $allowedHashes.Add((Get-SemanticJsonHash -InputObject (Copy-HomeAuthoritySecurityTemplateWithOwner -SecurityTemplate $explicit -OwnerSid $defaultOwnerSid)))
    $null = $allowedHashes.Add((Get-SemanticJsonHash -InputObject (Copy-HomeAuthoritySecurityTemplateWithOwner -SecurityTemplate $inherited -OwnerSid $defaultOwnerSid)))
    if (-not $allowedHashes.Contains($actualHash)) { throw 'root-claims-occupancy-owner-dacl-mismatch' }
    return [pscustomobject][ordered]@{ Evidence=$evidence; EvidenceHash=$actualHash }
}

function Open-RootClaimsOccupancySidDirectoryHandle {
    # Creates the occupancy root and the SID-scoped child create-new with the
    # current-user-only directory template when missing (exact ACL asserted
    # either way) and returns a held no-follow handle on the SID directory.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$OccupancyIdentity)

    $projection = Get-RootClaimsOccupancyRootPath -OccupancyIdentity $OccupancyIdentity
    $sid = [string]$projection.TokenSid
    $domainLeaf = [string]$projection.DomainLeaf
    $directorySddl = ConvertTo-HomeAuthoritySecurityDescriptorSddl -SecurityTemplate (Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid $sid -ResourceKind Directory)
    $localHandles = $null
    $occupancyHandles = $null
    $created = $null
    try {
        $localReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path ([string]$projection.LocalAppDataRoot) -OwnershipReceiver $localReceiver
        $localHandles = $localReceiver.GetDeliveredExact()
        $localParent = $localHandles[$localHandles.Count - 1]
        $existingDomain = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($localParent,$domainLeaf)
        if ($null -eq $existingDomain) {
            $created = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectoryWithSecurityDescriptor($localParent,$domainLeaf,$directorySddl)
            $created.Dispose()
            $created = $null
        }
        elseif ([bool]$existingDomain.IsReparsePoint -or -not [bool]$existingDomain.IsDirectory) { throw 'root-claims-occupancy-root-invalid' }

        $occupancyReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path (Join-Path ([string]$projection.LocalAppDataRoot) $domainLeaf) -OwnershipReceiver $occupancyReceiver
        $occupancyHandles = $occupancyReceiver.GetDeliveredExact()
        $occupancyParent = $occupancyHandles[$occupancyHandles.Count - 1]
        $existingSid = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($occupancyParent,$sid)
        if ($null -eq $existingSid) {
            $created = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectoryWithSecurityDescriptor($occupancyParent,$sid,$directorySddl)
            $created.Dispose()
            $created = $null
        }
        elseif ([bool]$existingSid.IsReparsePoint -or -not [bool]$existingSid.IsDirectory) { throw 'root-claims-occupancy-root-invalid' }
    }
    finally {
        if ($null -ne $created) { $created.Dispose() }
        if ($null -ne $occupancyHandles) { Close-SafeDirectoryContainmentChain -Handles $occupancyHandles }
        if ($null -ne $localHandles) { Close-SafeDirectoryContainmentChain -Handles $localHandles }
    }

    $sidHandles = $null
    try {
        $sidReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path ([string]$projection.RootPath) -OwnershipReceiver $sidReceiver
        $sidHandles = $sidReceiver.GetDeliveredExact()
        $held = $sidHandles[$sidHandles.Count - 1]
        if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($held)).Count -ne 0) { throw 'root-claims-occupancy-root-invalid' }
        $security = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($held)
        $null = Assert-RootClaimsOccupancyCurrentUserOnlySnapshot -Snapshot $security -ResourceKind Directory -TokenSid $sid -ExpectedIdentity ([string]$held.Info.Identity)
        # On success the returned child handle stays open for the caller: drop
        # it from the chain array so the finally-close disposes only parents.
        # On any failure the child is still a chain member and is closed here.
        $sidHandles = @($sidHandles | Select-Object -First (@($sidHandles).Count - 1))
        return $held
    }
    finally {
        if ($null -ne $sidHandles) { Close-SafeDirectoryContainmentChain -Handles $sidHandles }
    }
}

function Read-RootClaimsOccupancyEntryByPath {
    # No-follow, exact-byte read of one index entry. Returns $null when the
    # entry (or its SID directory) does not exist; any present-but-invalid
    # entry fails closed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryPath,
        [Parameter(Mandatory)][string]$EntryKey,
        [Parameter(Mandatory)][string]$TokenSid
    )

    if ($EntryKey -cnotmatch $script:RootClaimsOccupancyEntryKeyPattern) { throw 'root-claims-occupancy-entry-key-invalid' }
    $full = [IO.Path]::GetFullPath($EntryPath)
    $parentPath = Split-Path -Parent $full
    $leafName = [IO.Path]::GetFileName($full)
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) { return $null }
    $parentHandles = $null
    $held = $null
    try {
        $parentReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $parentPath -OwnershipReceiver $parentReceiver
        $parentHandles = $parentReceiver.GetDeliveredExact()
        $parentHandle = $parentHandles[$parentHandles.Count - 1]
        $marker = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($parentHandle,$leafName)
        if ($null -eq $marker) { return $null }
        if ([bool]$marker.IsReparsePoint -or [bool]$marker.IsDirectory) { throw 'root-claims-occupancy-entry-invalid' }
        $held = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($parentHandle,$leafName)
        if ([long]$held.ReadResult.Length -gt $script:RootClaimsOccupancyMaximumEntryBytes) { throw 'root-claims-occupancy-entry exceeds the byte limit' }
        $security = [AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($held)
        $null = Assert-RootClaimsOccupancyCurrentUserOnlySnapshot -Snapshot $security -ResourceKind File -TokenSid $TokenSid -ExpectedIdentity ([string]$held.ReadResult.Identity)
        $bytes = [byte[]][AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($held,$script:RootClaimsOccupancyMaximumEntryBytes)
        $null = Assert-RootClaimsOccupancySchemaBytes -InstanceBytes $bytes
        $document = ConvertFrom-SemanticJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
        if ($document -isnot [System.Collections.IDictionary]) { throw 'root-claims-occupancy entry JSON root must be an object' }
        $null = Test-RootClaimsOccupancySemantics -Document $document
        if ([string]$document.EntryKey -cne $EntryKey) { throw 'root-claims-occupancy-entry-key-mismatch' }
        return [pscustomobject][ordered]@{
            Document = $document
            BytesHash = [string]$held.ReadResult.Sha256
            FileIdentity = [string]$held.ReadResult.Identity
            Length = [long]$held.ReadResult.Length
        }
    }
    finally {
        if ($null -ne $held) { $held.Dispose() }
        if ($null -ne $parentHandles) { Close-SafeDirectoryContainmentChain -Handles $parentHandles }
    }
}

function New-RootClaimsOccupancyEntryCreateNew {
    # Records one occupancy entry create-new beneath the SID directory. The
    # bytes are fully determined and validated (schema plus semantics) before
    # any file exists, the create fails closed on an existing entry, and the
    # no-follow write helper rolls its own created bytes back on any mid-write
    # failure — a failure mode never leaves partial index bytes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$OccupancyIdentity,
        [Parameter(Mandatory)][string]$EntryPath,
        [Parameter(Mandatory)][byte[]]$Bytes
    )

    $full = [IO.Path]::GetFullPath($EntryPath)
    $parentPath = Split-Path -Parent $full
    $leafName = [IO.Path]::GetFileName($full)
    if ($leafName -cnotmatch ('\A' + '[0-9a-f]{64}' + '\.json\z')) { throw 'root-claims-occupancy-entry-key-invalid' }
    $null = Assert-RootClaimsOccupancySchemaBytes -InstanceBytes $Bytes

    $sidDirectory = $null
    $held = $null
    try {
        $sidDirectory = Open-RootClaimsOccupancySidDirectoryHandle -OccupancyIdentity $OccupancyIdentity
        try {
            $held = [AiAgentDotfiles.NoFollowFile]::CreateAndHashChildRegularFile($sidDirectory,$leafName,$Bytes)
        }
        catch [ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -in @(80,183)) { return [pscustomobject][ordered]@{ Created=$false; BytesHash=$null; FileIdentity=$null } }
            throw
        }
        $heldBytes = [byte[]][AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($held,[long]$Bytes.LongLength)
        $heldHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($heldBytes)).ToLowerInvariant()
        if ($heldHash -cne [string]$held.ReadResult.Sha256 -or $heldBytes.LongLength -ne [long]$Bytes.LongLength) { throw 'root-claims-occupancy-entry-write-drift' }
        $null = Assert-RootClaimsOccupancySchemaBytes -InstanceBytes $heldBytes
        $security = [AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($held)
        $null = Assert-RootClaimsOccupancyCurrentUserOnlySnapshot -Snapshot $security -ResourceKind File -TokenSid ([string](Get-RootClaimsOccupancyTokenSid -OccupancyIdentity $OccupancyIdentity)) -ExpectedIdentity ([string]$held.ReadResult.Identity)
        return [pscustomobject][ordered]@{
            Created = $true
            BytesHash = $heldHash
            FileIdentity = [string]$held.ReadResult.Identity
        }
    }
    finally {
        if ($null -ne $held) { $held.Dispose() }
        if ($null -ne $sidDirectory) { $sidDirectory.Dispose() }
    }
}

function Assert-RootClaimsOccupancyAvailable {
    # The claim-accept occupancy gate. Runs before the first commit of a custom
    # live-root claim: the first claimant records occupancy, a DIFFERENT
    # authority claiming the same (VolumeId, directory identity) fails closed
    # with 'root-claims-occupancy-conflict', and the SAME authority
    # re-claiming its own recorded entry is a no-op success. Only the custom
    # Reasonix live root is gated — the fixed HomeRoot-derived Claude/Codex
    # roots and the known-folder-default Reasonix root are per-authority
    # identity-derived paths, and a not-yet-created custom root has no
    # directory identity to occupy (its creation is bounded by the reviewed
    # plan's pre-state binding in the live transaction).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$GlobalLockHandle,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProposedClaims
    )

    # Sealed-lock style: the occupancy transition belongs to the claim-accept
    # commit and only runs under the same held home-authority global live lock
    # the registry already proved for its global claim file.
    $null = Assert-SealedHomeAuthorityGlobalLockWitness -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle

    $reasonixRows = @(@($ProposedClaims.LiveRootClaims) | Where-Object { [string]$_.Platform -ceq 'Reasonix' })
    if (@($reasonixRows).Count -ne 1) { throw 'root-claims-occupancy-reasonix-row-required' }
    $requestedPath = [string]$reasonixRows[0].RequestedPath

    $roamingRoot = ConvertTo-HomeAuthorityKnownFolderPath -Path ([string](Get-HomeAuthorityObjectProperty -InputObject $AuthorityContext -Name 'RoamingAppDataRoot')) -Name 'RoamingAppData'
    $defaultReasonix = [IO.Path]::GetFullPath((Join-Path $roamingRoot 'reasonix/skills')).TrimEnd([char]92,[char]47)
    if ([IO.Path]::GetFullPath($requestedPath).TrimEnd([char]92,[char]47).Equals($defaultReasonix, [StringComparison]::OrdinalIgnoreCase)) { return }

    # Fresh observation through the target-context machinery; never re-derived
    # and never taken from the claim document bytes.
    $observed = Resolve-TargetContext -Path $requestedPath -Mode MetadataOnly
    if ([string]$observed.TargetStatus -cne 'EXISTS') { return }
    $volumeId = [string]$observed.VolumeId
    $directoryIdentity = [string]$observed.DeepestExistingParentIdentity
    if ($directoryIdentity -cnotmatch ('\A' + [regex]::Escape($volumeId) + ':[0-9a-f]{16}\z')) { throw 'root-claims-occupancy-identity-invalid' }

    $occupancyIdentity = Get-RootClaimsOccupancyIdentity
    if ([string](Get-RootClaimsOccupancyTokenSid -OccupancyIdentity $occupancyIdentity) -cne [string]$AuthorityContext.TokenSid) { throw 'root-claims-occupancy-identity-sid-mismatch' }
    $entryKey = Get-RootClaimsOccupancyEntryKey -VolumeId $volumeId -DirectoryIdentity $directoryIdentity
    $entryPath = Get-RootClaimsOccupancyIndexPath -OccupancyIdentity $occupancyIdentity -EntryKey $entryKey
    $tokenSid = [string](Get-RootClaimsOccupancyTokenSid -OccupancyIdentity $occupancyIdentity)

    $existing = Read-RootClaimsOccupancyEntryByPath -EntryPath $entryPath -EntryKey $entryKey -TokenSid $tokenSid
    if ($null -ne $existing) {
        if ([string]$existing.Document.HomeAuthorityKey -ceq [string]$AuthorityContext.HomeAuthorityKey) { return }
        throw 'root-claims-occupancy-conflict'
    }

    $document = [ordered]@{
        SchemaVersion = 1L
        ArtifactKind = $script:RootClaimsOccupancyArtifactKind
        EntryKey = $entryKey
        VolumeId = $volumeId
        DirectoryIdentity = $directoryIdentity
        ClaimedLocationKey = [string]$observed.LocationKey
        HomeAuthorityKey = [string]$AuthorityContext.HomeAuthorityKey
        ControlBase = [IO.Path]::GetFullPath([string]$AuthorityContext.ControlBase)
    }
    $bytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $document)
    $null = Test-RootClaimsOccupancySemantics -Document $document
    $writeOutcome = New-RootClaimsOccupancyEntryCreateNew -OccupancyIdentity $occupancyIdentity -EntryPath $entryPath -Bytes $bytes
    if ([bool]$writeOutcome.Created) { return }

    # Lost a create race to a concurrent claimant: classify against the winner
    # exactly as the pre-read classification above.
    $winner = Read-RootClaimsOccupancyEntryByPath -EntryPath $entryPath -EntryKey $entryKey -TokenSid $tokenSid
    if ($null -ne $winner -and [string]$winner.Document.HomeAuthorityKey -ceq [string]$AuthorityContext.HomeAuthorityKey) { return }
    throw 'root-claims-occupancy-conflict'
}
