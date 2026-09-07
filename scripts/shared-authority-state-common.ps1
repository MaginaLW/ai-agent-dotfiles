#requires -Version 7.0

Set-StrictMode -Version Latest
$script:AuthorityStateRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')

function Assert-AuthoritySchemaBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('root-claims','current-env-state')][string]$ArtifactKind,
        [Parameter(Mandatory)][byte[]]$InstanceBytes
    )

    $schemaRoot = Join-Path $script:AuthorityStateRepoRoot 'schemas'
    $schemaPath = Join-Path $schemaRoot ($ArtifactKind + '.schema.json')
    $schemaValidation = Test-RepositoryJsonSchema -SchemaPath $schemaPath -SchemaRoot $schemaRoot
    $instanceLabel = Join-Path $schemaRoot ('.' + $ArtifactKind + '.in-memory.json')
    $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $schemaValidation -InstanceBytes $InstanceBytes -InstancePath $instanceLabel
}

function Get-AuthorityCanonicalPathProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Role,
        [switch]$AllowVolumeRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "$Role must be a fully-qualified local path"
    }
    $rawFull = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($rawFull)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or $volumeRoot.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "$Role must be on a local drive"
    }
    $isVolumeRoot = [IO.Path]::GetRelativePath($volumeRoot, $rawFull) -ceq '.'
    if ($isVolumeRoot -and -not $AllowVolumeRoot) { throw "$Role cannot be a volume root" }
    $canonicalPath = if ($isVolumeRoot) { $volumeRoot } else { $rawFull.TrimEnd([char]92, [char]47) }
    if ($Path -cne $canonicalPath) { throw "$Role must use canonical separators and contain no trailing or dot segments" }

    $relative = [IO.Path]::GetRelativePath($volumeRoot, $canonicalPath)
    $segments = if ($relative -ceq '.') { @() } else { @($relative -split '[\\/]') }
    foreach ($segment in $segments) {
        if ($segment -in @('', '.', '..') -or $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $segment.EndsWith(' ', [StringComparison]::Ordinal) -or $segment.EndsWith('.', [StringComparison]::Ordinal)) {
            throw "$Role contains an unsafe path segment"
        }
        if ($segment -ieq '.system') { throw "$Role contains the protected .system segment" }
        if ($segment -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') { throw "$Role contains a reserved Windows path segment" }
    }

    return [pscustomobject][ordered]@{
        Path = $canonicalPath
        LocationKey = $canonicalPath.ToLowerInvariant().Replace([char]92, [char]47)
        Segments = @($segments)
    }
}

function Get-AuthorityLocationKeyProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocationKey,
        [Parameter(Mandatory)][string]$Role
    )

    if ($LocationKey -cnotmatch '^[a-z]:/[^/]' -or $LocationKey.Contains([char]92) -or $LocationKey.EndsWith('/', [StringComparison]::Ordinal) -or $LocationKey.Contains('//', [StringComparison]::Ordinal)) {
        throw "$Role must be a canonical local location key"
    }
    $nativePath = $LocationKey.Substring(0, 2) + $LocationKey.Substring(2).Replace([char]47, [char]92)
    $projection = Get-AuthorityCanonicalPathProjection -Path $nativePath -Role $Role
    if ([string]$projection.LocationKey -cne $LocationKey) { throw "$Role must be lowercase canonical location key" }
    return $projection
}

function Assert-CanonicalAuthoritySid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Sid)

    try { $canonical = [Security.Principal.SecurityIdentifier]::new($Sid).Value }
    catch { throw 'root-claims TokenSid is not a valid Windows SID' }
    if ($Sid -cne $canonical) { throw 'root-claims TokenSid must use canonical Windows SID spelling' }
}

function Assert-AuthorityLocationsDisjoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$LocationKeys,
        [Parameter(Mandatory)][string]$Role
    )

    for ($leftIndex = 0; $leftIndex -lt $LocationKeys.Count; $leftIndex++) {
        $left = $LocationKeys[$leftIndex].TrimEnd('/')
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $LocationKeys.Count; $rightIndex++) {
            $right = $LocationKeys[$rightIndex].TrimEnd('/')
            if ($left -ceq $right -or $left.StartsWith($right + '/', [StringComparison]::Ordinal) -or $right.StartsWith($left + '/', [StringComparison]::Ordinal)) {
                throw "$Role locations overlap"
            }
        }
    }
}

function Assert-AuthorityMissingRemainder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Claim,
        [Parameter(Mandatory)]$RequestedProjection,
        [Parameter(Mandatory)]$ParentProjection
    )

    $parentPrefix = $ParentProjection.LocationKey.TrimEnd('/') + '/'
    if (-not $RequestedProjection.LocationKey.StartsWith($parentPrefix, [StringComparison]::Ordinal)) {
        throw "root-claims ABSENT parent is not a strict ancestor: $($Claim.Platform)"
    }
    $relative = [IO.Path]::GetRelativePath([string]$ParentProjection.Path, [string]$RequestedProjection.Path)
    $expectedRemainder = @($relative -split '[\\/]')
    $actualRemainder = [string[]]@($Claim.MissingRemainder)
    if ($actualRemainder.Count -ne $expectedRemainder.Count) { throw "root-claims MissingRemainder does not reconstruct target: $($Claim.Platform)" }
    $reconstructed = [string]$ParentProjection.Path
    for ($index = 0; $index -lt $actualRemainder.Count; $index++) {
        $segment = $actualRemainder[$index]
        if ($segment -cne $expectedRemainder[$index] -or $segment -in @('', '.', '..') -or $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "root-claims MissingRemainder is not canonical: $($Claim.Platform)"
        }
        $reconstructed = Join-Path $reconstructed $segment
    }
    if ([IO.Path]::GetFullPath($reconstructed) -cne [string]$RequestedProjection.Path) {
        throw "root-claims parent plus remainder does not reconstruct target: $($Claim.Platform)"
    }
}

function Test-RootClaimsSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)

    Assert-CanonicalAuthoritySid -Sid ([string]$Document.TokenSid)
    $homeProjection = Get-AuthorityLocationKeyProjection -LocationKey ([string]$Document.HomeRootLocationKey) -Role 'root-claims HomeRootLocationKey'
    $expectedAuthorityKey = Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/home-authority/v1'
        TokenSid = [string]$Document.TokenSid
        HomeRootLocationKey = [string]$homeProjection.LocationKey
    })
    if ([string]$Document.HomeAuthorityKey -cne $expectedAuthorityKey) { throw 'root-claims HomeAuthorityKey mismatch' }

    $platforms = @($Document.LiveRootClaims | ForEach-Object { [string]$_.Platform })
    if (($platforms -join ',') -cne 'Claude,Codex,Reasonix') { throw 'root-claims platform order must be Claude,Codex,Reasonix' }
    if (@($platforms | Sort-Object -Unique).Count -ne 3) { throw 'root-claims platforms must be unique' }

    $locationKeys = [System.Collections.Generic.List[string]]::new()
    $initialDirectoryIdentities = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $parentIdentityByLocation = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $parentLocationByIdentity = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $volumeByDrive = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $driveByVolume = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $claimRows = [System.Collections.Generic.List[object]]::new()
    foreach ($claim in $Document.LiveRootClaims) {
        $platform = [string]$claim.Platform
        $requested = Get-AuthorityCanonicalPathProjection -Path ([string]$claim.RequestedPath) -Role "root-claims RequestedPath/$platform"
        $location = Get-AuthorityLocationKeyProjection -LocationKey ([string]$claim.LocationKey) -Role "root-claims LocationKey/$platform"
        if ([string]$location.LocationKey -cne [string]$requested.LocationKey) { throw "root-claims LocationKey mismatch: $platform" }
        $parent = Get-AuthorityCanonicalPathProjection -Path ([string]$claim.DeepestExistingParentPath) -Role "root-claims DeepestExistingParentPath/$platform" -AllowVolumeRoot
        $requestedRoot = [IO.Path]::GetPathRoot([string]$requested.Path)
        $parentRoot = [IO.Path]::GetPathRoot([string]$parent.Path)
        if (-not $requestedRoot.Equals($parentRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "root-claims parent must be on the requested target volume: $platform" }
        $driveKey = $requestedRoot.TrimEnd([char]92, [char]47).ToLowerInvariant()
        $volumeId = [string]$claim.VolumeId
        if ($volumeId -cnotmatch '\A[0-9a-f]{8}\z') { throw "root-claims VolumeId is not canonical: $platform" }
        $knownVolume = $null
        if ($volumeByDrive.TryGetValue($driveKey, [ref]$knownVolume)) {
            if ($knownVolume -cne $volumeId) { throw "root-claims one drive has conflicting VolumeId values: $platform" }
        }
        else { $volumeByDrive.Add($driveKey, $volumeId) }
        $knownDrive = $null
        if ($driveByVolume.TryGetValue($volumeId, [ref]$knownDrive)) {
            if ($knownDrive -cne $driveKey) { throw "root-claims one VolumeId aliases multiple drive roots: $platform" }
        }
        else { $driveByVolume.Add($volumeId, $driveKey) }

        $parentLocation = [string]$parent.LocationKey
        $parentIdentity = [string]$claim.DeepestExistingParentIdentity
        if ($parentIdentity -cnotmatch ('\A' + [regex]::Escape($volumeId) + ':[0-9a-f]{16}\z')) { throw "root-claims parent identity is not canonical for its VolumeId: $platform" }
        $knownParentIdentity = $null
        if ($parentIdentityByLocation.TryGetValue($parentLocation, [ref]$knownParentIdentity)) {
            if ($knownParentIdentity -cne $parentIdentity) { throw "root-claims parent location has conflicting identities: $platform" }
        }
        else { $parentIdentityByLocation.Add($parentLocation, $parentIdentity) }
        $knownParentLocation = $null
        if ($parentLocationByIdentity.TryGetValue($parentIdentity, [ref]$knownParentLocation)) {
            if ($knownParentLocation -cne $parentLocation) { throw "root-claims parent identity aliases multiple locations: $platform" }
        }
        else { $parentLocationByIdentity.Add($parentIdentity, $parentLocation) }

        if ([string]$claim.InitialState -ceq 'ABSENT') {
            if ($null -ne $claim.InitialDirectoryIdentity) { throw "root-claims ABSENT InitialDirectoryIdentity must be null: $platform" }
            Assert-AuthorityMissingRemainder -Claim $claim -RequestedProjection $requested -ParentProjection $parent
        }
        elseif ([string]$claim.InitialState -ceq 'EXISTS') {
            if ([string]$parent.Path -cne [string]$requested.Path -or @($claim.MissingRemainder).Count -ne 0) {
                throw "root-claims EXISTS parent tuple mismatch: $platform"
            }
            if ([string]$claim.InitialDirectoryIdentity -cne [string]$claim.DeepestExistingParentIdentity) {
                throw "root-claims EXISTS directory identity mismatch: $platform"
            }
            if (-not $initialDirectoryIdentities.Add([string]$claim.InitialDirectoryIdentity)) { throw 'root-claims existing directory identities must be unique across platforms' }
        }
        else { throw "root-claims InitialState is unsupported: $platform" }

        $locationKeys.Add([string]$requested.LocationKey)
        $claimRows.Add([pscustomobject][ordered]@{
            Claim = $claim
            RequestedLocation = [string]$requested.LocationKey
            ParentLocation = $parentLocation
            ParentIdentity = $parentIdentity
        })
    }

    $claudeExpected = [string]$homeProjection.LocationKey + '/.claude/skills'
    if ([string]$Document.LiveRootClaims[0].LocationKey -cne $claudeExpected) { throw 'root-claims Claude location is not the fixed HomeRoot/.claude/skills path' }
    $codexLocation = [string]$Document.LiveRootClaims[1].LocationKey
    if ($codexLocation -cne ([string]$homeProjection.LocationKey + '/.codex/skills') -and $codexLocation -cne ([string]$homeProjection.LocationKey + '/.agents/skills')) {
        throw 'root-claims Codex location is not a fixed preferred or fallback path'
    }
    if ($codexLocation -ceq ([string]$homeProjection.LocationKey + '/.agents/skills') -and [string]$Document.LiveRootClaims[1].InitialState -cne 'EXISTS') {
        throw 'root-claims Codex fallback must already EXIST when selected'
    }
    Assert-AuthorityLocationsDisjoint -LocationKeys @($locationKeys) -Role 'root-claims live roots'

    for ($leftIndex = 0; $leftIndex -lt $claimRows.Count; $leftIndex++) {
        $leftClaim = $claimRows[$leftIndex].Claim
        if ([string]$leftClaim.InitialState -cne 'EXISTS') { continue }
        $leftIdentity = [string]$leftClaim.InitialDirectoryIdentity
        for ($rightIndex = 0; $rightIndex -lt $claimRows.Count; $rightIndex++) {
            if ($rightIndex -eq $leftIndex) { continue }
            if ($leftIdentity -ceq [string]$claimRows[$rightIndex].ParentIdentity) { throw 'root-claims existing target identity aliases another claim parent identity' }
        }
    }
}

function Test-CurrentEnvStateSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)

    foreach ($field in @('TaskOverlaySkills','ManifestHashes','FinalManagedHashes','FinalResolvedIdentities')) {
        $platforms = @($Document[$field] | ForEach-Object { [string]$_.Platform })
        if (($platforms -join ',') -cne 'Claude,Codex,Reasonix') { throw "current-env-state $field platform order must be Claude,Codex,Reasonix" }
        if (@($platforms | Sort-Object -Unique).Count -ne 3) { throw "current-env-state $field platforms must be unique" }
    }

    foreach ($row in $Document.TaskOverlaySkills) {
        $skills = [string[]]@($row.Skills)
        $ordered = [string[]]$skills.Clone()
        [Array]::Sort($ordered,[StringComparer]::Ordinal)
        if (($skills -join "`n") -cne ($ordered -join "`n")) { throw "current-env-state TaskOverlaySkills must be ordinal sorted: $($row.Platform)" }
        $seenSkills = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($skill in $skills) {
            if ($skill.Length -gt 255 -or $skill -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $skill -ieq '.system' -or $skill.EndsWith('.', [StringComparison]::Ordinal) -or $skill.EndsWith(' ', [StringComparison]::Ordinal) -or $skill -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
                throw "current-env-state TaskOverlaySkills contains an unsafe skill name: $($row.Platform)"
            }
            if (-not $seenSkills.Add($skill)) { throw "current-env-state TaskOverlaySkills contains a case-insensitive skill collision: $($row.Platform)" }
        }
    }

    $locationKeys = [System.Collections.Generic.List[string]]::new()
    $directoryIdentities = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $volumeByDrive = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $driveByVolume = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($identity in $Document.FinalResolvedIdentities) {
        $platform = [string]$identity.Platform
        $resolved = Get-AuthorityCanonicalPathProjection -Path ([string]$identity.ResolvedPath) -Role "current-env-state ResolvedPath/$platform"
        $location = Get-AuthorityLocationKeyProjection -LocationKey ([string]$identity.LocationKey) -Role "current-env-state LocationKey/$platform"
        if ([string]$resolved.LocationKey -cne [string]$location.LocationKey) { throw "current-env-state ResolvedPath/LocationKey mismatch: $platform" }
        $locationKeys.Add([string]$location.LocationKey)
        if (-not $directoryIdentities.Add([string]$identity.DirectoryIdentity)) { throw 'current-env-state final directory identity must be unique across platforms' }
        $driveKey = [IO.Path]::GetPathRoot([string]$resolved.Path).TrimEnd([char]92, [char]47).ToLowerInvariant()
        $volumeId = [string]$identity.VolumeId
        if ($volumeId -cnotmatch '\A[0-9a-f]{8}\z') { throw "current-env-state VolumeId is not canonical: $platform" }
        if ([string]$identity.DirectoryIdentity -cnotmatch ('\A' + [regex]::Escape($volumeId) + ':[0-9a-f]{16}\z')) { throw "current-env-state DirectoryIdentity is not canonical for its VolumeId: $platform" }
        $knownVolume = $null
        if ($volumeByDrive.TryGetValue($driveKey, [ref]$knownVolume)) {
            if ($knownVolume -cne $volumeId) { throw "current-env-state one drive has conflicting VolumeId values: $platform" }
        }
        else { $volumeByDrive.Add($driveKey, $volumeId) }
        $knownDrive = $null
        if ($driveByVolume.TryGetValue($volumeId, [ref]$knownDrive)) {
            if ($knownDrive -cne $driveKey) { throw "current-env-state one VolumeId aliases multiple drive roots: $platform" }
        }
        else { $driveByVolume.Add($volumeId, $driveKey) }
    }
    Assert-AuthorityLocationsDisjoint -LocationKeys @($locationKeys) -Role 'current-env-state final roots'

    $expectedFinalTargetContextHash = Get-SemanticJsonHash -InputObject @($Document.FinalResolvedIdentities)
    if ([string]$Document.FinalTargetContextHash -cne $expectedFinalTargetContextHash) { throw 'current-env-state FinalTargetContextHash mismatch' }
    if ([string]$Document.LastOperationKind -ceq 'initial' -and [string]$Document.EnvironmentName -cne 'full') { throw 'initial authority state must select the named full environment' }
}

function Test-CurrentEnvStateAgainstRootClaimsSemanticsOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$StateDocument,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RootClaimsDocument,
        [Parameter(Mandatory)][byte[]]$RootClaimsBytes
    )

    try {
        $claimsJson = [Text.UTF8Encoding]::new($false, $true).GetString($RootClaimsBytes)
        $boundClaimsDocument = ConvertFrom-SemanticJson -Json $claimsJson
    }
    catch { throw "current-env-state root-claims bytes are not strict semantic JSON: $($_.Exception.Message)" }
    if ((Get-SemanticJsonHash -InputObject $boundClaimsDocument) -cne (Get-SemanticJsonHash -InputObject $RootClaimsDocument)) {
        throw 'current-env-state root-claims document does not match the exact hashed bytes object'
    }
    Test-RootClaimsSemantics -Document $boundClaimsDocument
    Test-CurrentEnvStateSemantics -Document $StateDocument
    $expectedClaimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($RootClaimsBytes)).ToLowerInvariant()
    if ([string]$StateDocument.RootClaimsHash -cne $expectedClaimsHash) { throw 'current-env-state RootClaimsHash does not match exact root-claims bytes' }
    if ([string]$StateDocument.HomeAuthorityKey -cne [string]$boundClaimsDocument.HomeAuthorityKey) { throw 'current-env-state HomeAuthorityKey does not match root-claims' }

    for ($index = 0; $index -lt $boundClaimsDocument.LiveRootClaims.Count; $index++) {
        $claim = $boundClaimsDocument.LiveRootClaims[$index]
        $identity = $StateDocument.FinalResolvedIdentities[$index]
        if ([string]$identity.Platform -cne [string]$claim.Platform -or [string]$identity.LocationKey -cne [string]$claim.LocationKey -or [string]$identity.ResolvedPath -cne [string]$claim.RequestedPath) {
            throw "current-env-state final resolved location does not match root-claims: $($claim.Platform)"
        }
        if ([string]$identity.VolumeId -cne [string]$claim.VolumeId) { throw "current-env-state final VolumeId does not match root-claims: $($claim.Platform)" }
        if ([string]$claim.InitialState -ceq 'EXISTS' -and [string]$identity.DirectoryIdentity -cne [string]$claim.InitialDirectoryIdentity) {
            throw "current-env-state final DirectoryIdentity does not match existing root-claims identity: $($claim.Platform)"
        }
        for ($parentIndex = 0; $parentIndex -lt $boundClaimsDocument.LiveRootClaims.Count; $parentIndex++) {
            $parentClaim = $boundClaimsDocument.LiveRootClaims[$parentIndex]
            $allowedOwnExistingIdentity = $parentIndex -eq $index -and [string]$claim.InitialState -ceq 'EXISTS'
            if (-not $allowedOwnExistingIdentity -and [string]$identity.DirectoryIdentity -ceq [string]$parentClaim.DeepestExistingParentIdentity) {
                throw "current-env-state final directory identity aliases a root-claims parent identity: $($claim.Platform)"
            }
        }
    }
}

function Test-CurrentEnvStateAgainstRootClaims {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$StateDocument,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RootClaimsDocument,
        [Parameter(Mandatory)][byte[]]$RootClaimsBytes
    )

    Assert-AuthoritySchemaBytes -ArtifactKind 'root-claims' -InstanceBytes $RootClaimsBytes
    $stateBytes = ConvertTo-SemanticJsonBytes -InputObject $StateDocument
    Assert-AuthoritySchemaBytes -ArtifactKind 'current-env-state' -InstanceBytes $stateBytes
    Test-CurrentEnvStateAgainstRootClaimsSemanticsOnly -StateDocument $StateDocument -RootClaimsDocument $RootClaimsDocument -RootClaimsBytes $RootClaimsBytes
}

$script:AuthorityTargetContextIntentRowKeys = @('Platform','LocationKey','RequestedPath','InitialState','VolumeId','DeepestExistingParentPath','DeepestExistingParentIdentity','MissingRemainder','InitialDirectoryIdentity','ExpectedPostState')
$script:AuthorityStateIntentFieldNames = @('SchemaVersion','ArtifactKind','HomeAuthorityKey','AuthorityGeneration','RootClaimsHash','SelectionKind','EnvironmentName','EnvironmentLockHash','TaskOverlayHash','TaskOverlaySkills','ManifestHashes','FinalManagedHashes','ControllerRepoFingerprint','ApprovedToolchainHash','PlanHash','DocumentHash','LastOperationKind')
$script:AuthorityStateRuntimeFieldNames = @('FinalResolvedIdentities','FinalTargetContextHash','ReceiptId','ReceiptHash','JournalId','PreStatePhaseHash')

function Assert-AuthorityStateExactKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$InputObject,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    $actual = @([string[]]$InputObject.Keys | Sort-Object { [string]$_ })
    $wanted = @($Expected | Sort-Object { [string]$_ })
    if (($actual -join "`0") -cne ($wanted -join "`0")) { throw "${Label} property set mismatch" }
}

function Assert-AuthorityStateString {
    [CmdletBinding()]
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

function New-AuthorityTargetContextIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$RootClaimsDocument)

    Test-RootClaimsSemantics -Document $RootClaimsDocument
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($claim in @($RootClaimsDocument.LiveRootClaims)) {
        Assert-AuthorityStateExactKeys -InputObject $claim -Expected $script:AuthorityTargetContextIntentRowKeys -Label 'root-claims LiveRootClaim'
        $row = [ordered]@{}
        foreach ($key in $script:AuthorityTargetContextIntentRowKeys) { $row[$key] = $claim[$key] }
        $rows.Add($row)
    }
    return [ordered]@{
        HomeAuthorityKey = [string]$RootClaimsDocument.HomeAuthorityKey
        Rows = @($rows)
    }
}

function Assert-AuthorityTargetContextIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Intent)

    Assert-AuthorityStateExactKeys -InputObject $Intent -Expected @('HomeAuthorityKey','Rows') -Label 'authority target-context intent'
    Assert-AuthorityStateString $Intent.HomeAuthorityKey 'authority target-context intent HomeAuthorityKey' '\A[0-9a-f]{64}\z'
    $rows = @($Intent.Rows)
    if ($rows.Count -ne 3) { throw 'authority-target-context-intent-invalid' }
    $platforms = @('Claude','Codex','Reasonix')
    for ($index = 0; $index -lt 3; $index++) {
        $row = $rows[$index]
        Assert-AuthorityStateExactKeys -InputObject $row -Expected $script:AuthorityTargetContextIntentRowKeys -Label "authority target-context intent row $index"
        if ([string]$row.Platform -cne $platforms[$index]) { throw 'authority-target-context-intent-invalid' }
        Assert-AuthorityStateString $row.InitialState "authority target-context intent InitialState[$index]" $null @('ABSENT','EXISTS')
        Assert-AuthorityStateString $row.ExpectedPostState "authority target-context intent ExpectedPostState[$index]" $null @('EXISTS')
        Assert-AuthorityStateString $row.VolumeId "authority target-context intent VolumeId[$index]" '\A[0-9a-f]{8}\z'
        $requested = Get-AuthorityCanonicalPathProjection -Path ([string]$row.RequestedPath) -Role "authority target-context intent RequestedPath/$($row.Platform)"
        $location = Get-AuthorityLocationKeyProjection -LocationKey ([string]$row.LocationKey) -Role "authority target-context intent LocationKey/$($row.Platform)"
        if ([string]$requested.LocationKey -cne [string]$location.LocationKey) { throw 'authority-target-context-intent-invalid' }
        $parent = Get-AuthorityCanonicalPathProjection -Path ([string]$row.DeepestExistingParentPath) -Role "authority target-context intent DeepestExistingParentPath/$($row.Platform)" -AllowVolumeRoot
        if (-not [IO.Path]::GetPathRoot([string]$requested.Path).Equals([IO.Path]::GetPathRoot([string]$parent.Path), [StringComparison]::OrdinalIgnoreCase)) { throw 'authority-target-context-intent-invalid' }
        Assert-AuthorityStateString $row.DeepestExistingParentIdentity "authority target-context intent parent identity[$index]" ('\A' + [regex]::Escape([string]$row.VolumeId) + ':[0-9a-f]{16}\z')
        if ($row.MissingRemainder -isnot [System.Array]) { throw 'authority-target-context-intent-invalid' }
        foreach ($segment in @($row.MissingRemainder)) { Assert-AuthorityStateString $segment "authority target-context intent remainder[$index]" '\A[^\\/:]+\z' }
        if ([string]$row.InitialState -ceq 'ABSENT') {
            if ($null -ne $row.InitialDirectoryIdentity -or @($row.MissingRemainder).Count -lt 1) { throw 'authority-target-context-intent-invalid' }
            Assert-AuthorityMissingRemainder -Claim $row -RequestedProjection $requested -ParentProjection $parent
        }
        else {
            Assert-AuthorityStateString $row.InitialDirectoryIdentity "authority target-context intent initial identity[$index]" ('\A' + [regex]::Escape([string]$row.VolumeId) + ':[0-9a-f]{16}\z')
            if (@($row.MissingRemainder).Count -ne 0 -or [string]$parent.Path -cne [string]$requested.Path) { throw 'authority-target-context-intent-invalid' }
        }
    }
}

function Assert-AuthorityFinalIdentitiesDerivedFromIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Intent,
        [Parameter(Mandatory)][AllowNull()][object[]]$FinalResolvedIdentities,
        [Parameter(Mandatory)][string]$FinalTargetContextHash
    )

    Assert-AuthorityTargetContextIntent -Intent $Intent
    $finalRows = @($FinalResolvedIdentities)
    $rowKeys = @('Platform','LocationKey','ResolvedPath','VolumeId','DirectoryIdentity','FilesystemCapabilityHash')
    if ($finalRows.Count -ne 3) { throw 'authority-final-identities-not-derived-from-intent' }
    if ((Get-SemanticJsonHash -InputObject $finalRows) -cne [string]$FinalTargetContextHash) { throw 'authority-final-identities-not-derived-from-intent' }
    for ($index = 0; $index -lt 3; $index++) {
        $row = $finalRows[$index]
        Assert-AuthorityStateExactKeys -InputObject $row -Expected $rowKeys -Label "authority final identity row $index"
        if ([string]$row.Platform -cne @('Claude','Codex','Reasonix')[$index]) { throw 'authority-final-identities-not-derived-from-intent' }
        Assert-AuthorityStateString $row.FilesystemCapabilityHash "authority final identity capability hash[$index]" '\A[0-9a-f]{64}\z'
        $intentRow = $Intent.Rows[$index]
        if ([string]$row.LocationKey -cne [string]$intentRow.LocationKey -or
            [string]$row.ResolvedPath -cne [string]$intentRow.RequestedPath -or
            [string]$row.VolumeId -cne [string]$intentRow.VolumeId) { throw 'authority-final-identities-drift' }
        if ([string]$intentRow.InitialState -ceq 'EXISTS') {
            if ([string]$row.DirectoryIdentity -cne [string]$intentRow.InitialDirectoryIdentity) { throw 'authority-final-identities-drift' }
        }
        else {
            Assert-AuthorityStateString $row.DirectoryIdentity "authority final identity[$index]" ('\A' + [regex]::Escape([string]$intentRow.VolumeId) + ':[0-9a-f]{16}\z')
            if ([string]$row.DirectoryIdentity -ceq [string]$intentRow.DeepestExistingParentIdentity) { throw 'authority-final-identities-drift' }
        }
    }
    for ($leftIndex = 0; $leftIndex -lt 3; $leftIndex++) {
        $leftIntent = $Intent.Rows[$leftIndex]
        $leftIdentity = [string]$finalRows[$leftIndex].DirectoryIdentity
        if ([string]$leftIntent.InitialState -cne 'EXISTS' -and $leftIdentity -ceq [string]$leftIntent.DeepestExistingParentIdentity) { throw 'authority-final-identities-drift' }
        for ($rightIndex = 0; $rightIndex -lt 3; $rightIndex++) {
            if ($leftIndex -eq $rightIndex) { continue }
            if ($leftIdentity -ceq [string]$Intent.Rows[$rightIndex].DeepestExistingParentIdentity) { throw 'authority-final-identities-drift' }
            if ($leftIdentity -ceq [string]$finalRows[$rightIndex].DirectoryIdentity) { throw 'authority-final-identities-drift' }
        }
    }
}

function Get-AuthorityStateIntentProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$StateDocument)

    $projection = [ordered]@{}
    foreach ($key in @($StateDocument.Keys)) {
        if ([string]$key -cin $script:AuthorityStateRuntimeFieldNames) { continue }
        $projection[[string]$key] = $StateDocument[$key]
    }
    return $projection
}

function Assert-AuthorityControllerTransitionPreservesSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$PreviousState,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Postimage
    )

    if ([string]$Postimage.LastOperationKind -cne 'controller-transition' -or
        [string]$Postimage.ReceiptRef -cne 'NO_LIVE_MUTATION' -or
        $Postimage.Contains('ReceiptId') -or $Postimage.Contains('ReceiptHash')) { throw 'authority-controller-transition-receipt-shape' }
    $previousIsControllerTransition = [string]$PreviousState.LastOperationKind -ceq 'controller-transition' -and [string]$PreviousState.ReceiptRef -ceq 'NO_LIVE_MUTATION'
    $previousIsReceiptBearing = $PreviousState.Contains('ReceiptId') -and $PreviousState.Contains('ReceiptHash')
    if (-not $previousIsControllerTransition -and -not $previousIsReceiptBearing) { throw 'authority-controller-transition-receipt-shape' }
    foreach ($field in @('SelectionKind','EnvironmentName','EnvironmentLockHash','TaskOverlayHash','TaskOverlaySkills','ManifestHashes','FinalManagedHashes','FinalResolvedIdentities','FinalTargetContextHash','RootClaimsHash','HomeAuthorityKey')) {
        if ((Get-SemanticJsonHash -InputObject $PreviousState[$field]) -cne (Get-SemanticJsonHash -InputObject $Postimage[$field])) { throw 'authority-controller-transition-selection-drift' }
    }
}

function New-AuthorityStatePostimage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$AuthorityStateIntent,
        [Parameter(Mandatory)][System.Collections.IDictionary]$TargetContextIntent,
        [Parameter(Mandatory)][AllowNull()][object[]]$FinalResolvedIdentities,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RuntimeRefs
    )

    foreach ($runtimeKey in $script:AuthorityStateRuntimeFieldNames) {
        if ($AuthorityStateIntent.Contains($runtimeKey)) { throw 'authority-state-intent-mismatch' }
    }
    $intentKeySet = [Collections.Generic.List[string]]::new()
    $intentKeySet.AddRange([string[]]$script:AuthorityStateIntentFieldNames)
    $kind = [string]$AuthorityStateIntent.LastOperationKind
    if ($kind -ceq 'controller-transition') {
        if (-not $AuthorityStateIntent.Contains('ReceiptRef') -or [string]$AuthorityStateIntent.ReceiptRef -cne 'NO_LIVE_MUTATION') { throw 'authority-controller-transition-receipt-shape' }
        $intentKeySet.Add('ReceiptRef')
    }
    else {
        if ($AuthorityStateIntent.Contains('ReceiptRef')) { throw 'authority-state-intent-mismatch' }
    }
    Assert-AuthorityStateExactKeys -InputObject $AuthorityStateIntent -Expected $intentKeySet.ToArray() -Label 'authority state intent'
    Assert-AuthorityTargetContextIntent -Intent $TargetContextIntent
    if ([string]$AuthorityStateIntent.HomeAuthorityKey -cne [string]$TargetContextIntent.HomeAuthorityKey) { throw 'authority-state-intent-mismatch' }
    $expectedRefKeys = @('JournalId','PreStatePhaseHash')
    if ($kind -cne 'controller-transition') { $expectedRefKeys = @('JournalId','PreStatePhaseHash','ReceiptId','ReceiptHash') }
    Assert-AuthorityStateExactKeys -InputObject $RuntimeRefs -Expected $expectedRefKeys -Label 'authority state runtime refs'
    if ($kind -cne 'controller-transition') {
        Assert-AuthorityStateString $RuntimeRefs.ReceiptId 'authority state runtime ReceiptId' '\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z'
        Assert-AuthorityStateString $RuntimeRefs.ReceiptHash 'authority state runtime ReceiptHash' '\A[0-9a-f]{64}\z'
    }
    Assert-AuthorityStateString $RuntimeRefs.JournalId 'authority state runtime JournalId' '\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z'
    Assert-AuthorityStateString $RuntimeRefs.PreStatePhaseHash 'authority state runtime PreStatePhaseHash' '\A[0-9a-f]{64}\z'
    $finalTargetContextHash = Get-SemanticJsonHash -InputObject @($FinalResolvedIdentities)
    Assert-AuthorityFinalIdentitiesDerivedFromIntent -Intent $TargetContextIntent -FinalResolvedIdentities $FinalResolvedIdentities -FinalTargetContextHash $finalTargetContextHash
    $postimage = [ordered]@{}
    foreach ($key in @($AuthorityStateIntent.Keys)) { $postimage[[string]$key] = $AuthorityStateIntent[$key] }
    foreach ($key in @($RuntimeRefs.Keys)) { $postimage[[string]$key] = $RuntimeRefs[$key] }
    $postimage['FinalResolvedIdentities'] = @($FinalResolvedIdentities)
    $postimage['FinalTargetContextHash'] = $finalTargetContextHash
    Test-CurrentEnvStateSemantics -Document $postimage
    return $postimage
}
