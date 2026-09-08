#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'shared-authority-state-common.ps1')

$script:LivePlanSchemaUnsupported = 'live-plan-schema-unsupported'
$script:LivePlanHashMismatch = 'live-plan-hash-mismatch'
$script:LivePlanKindMismatch = 'live-plan-operation-kind-mismatch'
$script:LivePlanSelectionMismatch = 'live-plan-selection-mismatch'
$script:LivePlanSystemMarkerDrift = 'live-plan-system-marker-drift'
$script:LivePlanUnknownMarkerDrift = 'live-plan-unknown-marker-drift'
$script:LivePlanRetirementSelectionConflict = 'retirement-selection-conflict'
$script:LivePlanPathCollision = 'live-plan-path-collision'
$script:LivePlanConsumed = 'live-plan-consumed'

$script:LivePlanPlatforms = @('Claude', 'Codex', 'Reasonix')
$script:LivePlanGeneratorSync = 'scripts/sync.ps1'
$script:LivePlanGeneratorSealed = 'tests/helpers/sealed-live-plan-fixture.ps1'
$script:LivePlanKinds = @(
    'initial',
    'environment',
    'task-overlay',
    'migrate',
    'adopt',
    'repair-adopt',
    'controller-transition',
    'retirement'
)
$script:LivePlanRuntimeFieldNames = @(
    'FinalResolvedIdentities',
    'FinalTargetContextHash',
    'ReceiptId',
    'ReceiptHash',
    'JournalId',
    'PreStatePhaseHash'
)
$script:LivePlanHashPattern = '^[0-9a-f]{64}$'
$script:LivePlanIdentityPattern = '^[0-9a-f]{8}:[0-9a-f]{16}$'
$script:LivePlanCommitPattern = '^[0-9a-f]{40,64}$'

function Test-LivePlanMapHasName {
    param($Map, [Parameter(Mandatory)] [string] $Name)
    return ($null -ne $Map -and $Map -is [System.Collections.IDictionary] -and $Map.Contains($Name))
}

function Get-LivePlanMap {
    param($Value, [Parameter(Mandatory)] [string] $Failure)
    if ($Value -isnot [System.Collections.IDictionary]) { throw $Failure }
    return $Value
}

function Assert-LivePlanHashSpelling {
    param($Value, [Parameter(Mandatory)] [string] $Failure)
    if ($Value -isnot [string] -or [string] $Value -cnotmatch $script:LivePlanHashPattern) { throw $Failure }
}

function Assert-LivePlanAbsolutePath {
    param($Value, [Parameter(Mandatory)] [string] $Failure)
    if ($Value -isnot [string] -or [string] $Value -cnotmatch '^[A-Za-z]:\\') { throw $Failure }
}

function Assert-LivePlanFieldsPresent {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Map,
        [Parameter(Mandatory)] [string[]] $Names,
        [Parameter(Mandatory)] [string] $Failure
    )
    foreach ($name in $Names) {
        if (-not (Test-LivePlanMapHasName -Map $Map -Name $name)) { throw $Failure }
    }
}

function Assert-LivePlanFieldsAbsent {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Map,
        [Parameter(Mandatory)] [string[]] $Names,
        [Parameter(Mandatory)] [string] $Failure
    )
    foreach ($name in $Names) {
        if (Test-LivePlanMapHasName -Map $Map -Name $name) { throw $Failure }
    }
}

function Get-LivePlanKindSpec {
    param([Parameter(Mandatory)] [string] $Kind)
    switch ($Kind) {
        'initial' {
            return [ordered]@{
                Generator = $script:LivePlanGeneratorSync
                Required = @('EnvironmentName', 'EnvironmentMaterializationRoot', 'ProposedRootClaims', 'RootClaimsHash')
                Forbidden = @(
                    'RetirementManifest', 'TaskOverlayEvidence', 'LegacyLocator', 'LegacyHash', 'LegacyCoreHash',
                    'OldLockHash', 'LegacyEvidence', 'StateEvidence', 'ControllerParity'
                )
            }
        }
        'environment' {
            return [ordered]@{
                Generator = $script:LivePlanGeneratorSealed
                Required = @('EnvironmentName', 'EnvironmentMaterializationRoot')
                Forbidden = @(
                    'ProposedRootClaims', 'RetirementManifest', 'TaskOverlayEvidence', 'LegacyLocator',
                    'LegacyEvidence', 'StateEvidence', 'ControllerParity'
                )
            }
        }
        'task-overlay' {
            return [ordered]@{
                Generator = $script:LivePlanGeneratorSealed
                Required = @('EnvironmentName', 'EnvironmentMaterializationRoot', 'TaskOverlayEvidence')
                Forbidden = @('RetirementManifest', 'LegacyLocator', 'LegacyEvidence', 'StateEvidence', 'ControllerParity')
            }
        }
        'migrate' {
            return [ordered]@{
                Generator = $script:LivePlanGeneratorSealed
                Required = @('EnvironmentName', 'EnvironmentMaterializationRoot', 'LegacyLocator', 'LegacyHash', 'LegacyCoreHash', 'OldLockHash')
                Forbidden = @('LegacyEvidence', 'StateEvidence', 'RetirementManifest', 'ControllerParity')
            }
        }
        'adopt' {
            return [ordered]@{
                Generator = $script:LivePlanGeneratorSealed
                Required = @('EnvironmentName', 'LegacyEvidence')
                Forbidden = @(
                    'LegacyLocator', 'LegacyHash', 'LegacyCoreHash', 'OldLockHash', 'StateEvidence',
                    'RetirementManifest', 'ControllerParity'
                )
            }
        }
        'repair-adopt' {
            return [ordered]@{
                Generator = $script:LivePlanGeneratorSealed
                Required = @('EnvironmentName', 'StateEvidence')
                Forbidden = @('LegacyEvidence', 'LegacyLocator', 'RetirementManifest', 'ControllerParity')
            }
        }
        'controller-transition' {
            return [ordered]@{
                Generator = $script:LivePlanGeneratorSealed
                Required = @('ControllerParity')
                Forbidden = @('RetirementManifest', 'ProposedRootClaims', 'TaskOverlayEvidence', 'LegacyEvidence', 'StateEvidence')
            }
        }
        'retirement' {
            return [ordered]@{
                Generator = $script:LivePlanGeneratorSync
                Required = @('RetirementManifest')
                Forbidden = @(
                    'ProposedRootClaims', 'TaskOverlayEvidence', 'LegacyLocator', 'LegacyEvidence',
                    'StateEvidence', 'ControllerParity'
                )
            }
        }
        default { throw $script:LivePlanKindMismatch }
    }
}

function Assert-LivePlanRuntimeFieldsAbsent {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    $surfaces = [System.Collections.Generic.List[System.Collections.IDictionary]]::new()
    $surfaces.Add($Document)
    if (Test-LivePlanMapHasName -Map $Document -Name 'Metadata') {
        $metadata = $Document['Metadata']
        if ($metadata -is [System.Collections.IDictionary]) { $surfaces.Add($metadata) }
    }
    if (Test-LivePlanMapHasName -Map $Document -Name 'PlanPayload') {
        $payload = $Document['PlanPayload']
        if ($payload -is [System.Collections.IDictionary]) {
            $surfaces.Add($payload)
            foreach ($childName in @('AuthorityStateIntent', 'TargetContextIntent', 'ControlBaseIntent', 'RetirementManifest', 'EnvironmentMaterializationRoot')) {
                if (Test-LivePlanMapHasName -Map $payload -Name $childName) {
                    $child = $payload[$childName]
                    if ($child -is [System.Collections.IDictionary]) { $surfaces.Add($child) }
                }
            }
        }
    }
    foreach ($surface in $surfaces) {
        foreach ($runtimeName in $script:LivePlanRuntimeFieldNames) {
            if ($surface.Contains($runtimeName)) { throw $script:LivePlanSchemaUnsupported }
        }
        if ($surface.Contains('PlanHash') -and -not [object]::ReferenceEquals($surface, $Document)) {
            throw $script:LivePlanSchemaUnsupported
        }
        if ($surface.Contains('DocumentHash') -and -not [object]::ReferenceEquals($surface, $Document)) {
            throw $script:LivePlanSchemaUnsupported
        }
    }
}

function Assert-LivePlanEnvelopeHashes {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    if (-not (Test-LivePlanMapHasName -Map $Document -Name 'PlanPayload')) { throw $script:LivePlanSchemaUnsupported }
    if (-not (Test-LivePlanMapHasName -Map $Document -Name 'PlanHash')) { throw $script:LivePlanSchemaUnsupported }
    if (-not (Test-LivePlanMapHasName -Map $Document -Name 'DocumentHash')) { throw $script:LivePlanSchemaUnsupported }
    if ([string] $Document.PlanHash -cne (Get-PlanHash -PlanPayload $Document.PlanPayload)) {
        throw $script:LivePlanHashMismatch
    }
    if ([string] $Document.DocumentHash -cne (Get-DocumentHash -Document $Document)) {
        throw $script:LivePlanHashMismatch
    }
}

function Assert-LivePlanPlatformTriple {
    param($Rows, [Parameter(Mandatory)] [string] $ValueName)
    $items = @($Rows)
    if ($items.Count -ne 3) { throw $script:LivePlanSelectionMismatch }
    for ($index = 0; $index -lt 3; $index++) {
        $row = Get-LivePlanMap -Value $items[$index] -Failure $script:LivePlanSelectionMismatch
        if ([string] $row.Platform -cne $script:LivePlanPlatforms[$index]) { throw $script:LivePlanSelectionMismatch }
        if ($ValueName -ceq 'Skills') {
            if (-not (Test-LivePlanMapHasName -Map $row -Name 'Skills') -or $row.Skills -isnot [System.Array]) {
                throw $script:LivePlanSelectionMismatch
            }
        }
        elseif ($ValueName -ceq 'Hash') {
            if (-not (Test-LivePlanMapHasName -Map $row -Name 'Hash')) { throw $script:LivePlanSelectionMismatch }
            Assert-LivePlanHashSpelling -Value $row.Hash -Failure $script:LivePlanSelectionMismatch
        }
        elseif ($ValueName -ceq 'Names') {
            if (-not (Test-LivePlanMapHasName -Map $row -Name 'Names') -or $row.Names -isnot [System.Array]) {
                throw $script:LivePlanSelectionMismatch
            }
        }
    }
}

function Assert-LivePlanSystemMarker {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Marker)
    Assert-LivePlanFieldsPresent -Map $Marker -Names @('Platform', 'Name', 'Present', 'Identity', 'Hash') -Failure $script:LivePlanSystemMarkerDrift
    if ([string] $Marker.Platform -cne 'Codex' -or [string] $Marker.Name -cne '.system') { throw $script:LivePlanSystemMarkerDrift }
    if ([bool] $Marker.Present) {
        if ($null -eq $Marker.Identity -or [string] $Marker.Identity -eq '' -or $null -eq $Marker.Hash) { throw $script:LivePlanSystemMarkerDrift }
        Assert-LivePlanHashSpelling -Value $Marker.Hash -Failure $script:LivePlanSystemMarkerDrift
    }
    else {
        if ($null -ne $Marker.Identity -or $null -ne $Marker.Hash) { throw $script:LivePlanSystemMarkerDrift }
    }
}

function Assert-LivePlanUnknownMarkers {
    param($Markers)
    foreach ($marker in @($Markers)) {
        $row = Get-LivePlanMap -Value $marker -Failure $script:LivePlanUnknownMarkerDrift
        Assert-LivePlanFieldsPresent -Map $row -Names @('Platform', 'Name', 'LiveHash', 'Managed', 'Identity') -Failure $script:LivePlanUnknownMarkerDrift
        if ([string] $row.Platform -cnotin $script:LivePlanPlatforms) { throw $script:LivePlanUnknownMarkerDrift }
        if ([string] $row.Name -eq '' -or [bool] $row.Managed) { throw $script:LivePlanUnknownMarkerDrift }
        if ($null -ne $row.LiveHash) { Assert-LivePlanHashSpelling -Value $row.LiveHash -Failure $script:LivePlanUnknownMarkerDrift }
    }
}

function Assert-LivePlanOrderedActions {
    param(
        $Actions,
        [Parameter(Mandatory)] [string] $Kind
    )
    $items = @($Actions)
    $orders = [System.Collections.Generic.HashSet[long]]::new()
    $sortKeys = [System.Collections.Generic.List[string]]::new()
    $rank = @{ Claude = 0; Codex = 1; Reasonix = 2 }
    for ($index = 0; $index -lt $items.Count; $index++) {
        $action = Get-LivePlanMap -Value $items[$index] -Failure $script:LivePlanSelectionMismatch
        Assert-LivePlanFieldsPresent -Map $action -Names @('Order', 'Platform', 'Action', 'Name', 'SourceHash', 'LiveHash') -Failure $script:LivePlanSelectionMismatch
        $order = [long] $action.Order
        if ($order -ne [long] $index -or -not $orders.Add($order)) { throw $script:LivePlanSelectionMismatch }
        if ([string] $action.Platform -cnotin $script:LivePlanPlatforms) { throw $script:LivePlanSelectionMismatch }
        $verb = [string] $action.Action
        if ($verb -cnotin @('add', 'update', 'no-op', 'prune')) { throw $script:LivePlanSelectionMismatch }
        if ($Kind -ceq 'controller-transition' -and $verb -cne 'no-op') { throw $script:LivePlanKindMismatch }
        if ($verb -ceq 'prune') {
            if (-not (Test-LivePlanMapHasName -Map $action -Name 'Authority')) { throw $script:LivePlanKindMismatch }
            $authority = [string] $action.Authority
            if ($Kind -ceq 'retirement') {
                if ($authority -cne 'explicit-retirement') { throw $script:LivePlanKindMismatch }
            }
            elseif ($authority -cne 'managed-manifest') { throw $script:LivePlanKindMismatch }
        }
        else {
            if (Test-LivePlanMapHasName -Map $action -Name 'Authority') { throw $script:LivePlanKindMismatch }
        }
        if ($null -ne $action.SourceHash) { Assert-LivePlanHashSpelling -Value $action.SourceHash -Failure $script:LivePlanSelectionMismatch }
        if ($null -ne $action.LiveHash) { Assert-LivePlanHashSpelling -Value $action.LiveHash -Failure $script:LivePlanSelectionMismatch }
        $sortKeys.Add(('{0}|{1}' -f $rank[[string] $action.Platform], [string] $action.Name))
    }
    $ordered = [string[]] @($sortKeys)
    $sorted = [string[]] @($sortKeys)
    if ($sorted.Count -gt 1) { [Array]::Sort($sorted, [StringComparer]::Ordinal) }
    if (($ordered -join "`n") -cne ($sorted -join "`n")) { throw $script:LivePlanSelectionMismatch }
}

function Assert-LivePlanMaterializationRoot {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Root)
    Assert-LivePlanFieldsPresent -Map $Root -Names @(
        'Path', 'Identity', 'EnvBuildPath', 'EnvBuildHash', 'EnvLockPath', 'EnvLockHash', 'MaterializationHash'
    ) -Failure $script:LivePlanKindMismatch
    Assert-LivePlanAbsolutePath -Value $Root.Path -Failure $script:LivePlanSelectionMismatch
    Assert-LivePlanAbsolutePath -Value $Root.EnvBuildPath -Failure $script:LivePlanSelectionMismatch
    Assert-LivePlanAbsolutePath -Value $Root.EnvLockPath -Failure $script:LivePlanSelectionMismatch
    foreach ($hashName in @('EnvBuildHash', 'EnvLockHash', 'MaterializationHash')) {
        Assert-LivePlanHashSpelling -Value $Root[$hashName] -Failure $script:LivePlanHashMismatch
    }
    if ([string] $Root.Identity -cnotmatch $script:LivePlanIdentityPattern) { throw $script:LivePlanSelectionMismatch }
    $pathText = [string] $Root.Path
    foreach ($segment in @($pathText.TrimEnd([char] 92).Split([char] 92))) {
        if ($segment -ieq 'envs') { throw $script:LivePlanSelectionMismatch }
    }
    $prefix = $pathText.TrimEnd([char] 92) + [char] 92
    if (-not ([string] $Root.EnvBuildPath).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw $script:LivePlanSelectionMismatch }
    if (-not ([string] $Root.EnvLockPath).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw $script:LivePlanSelectionMismatch }
}

function Assert-LivePlanPreIdentity {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Identity,
        [Parameter(Mandatory)] [string] $ExpectedStatus
    )
    Assert-LivePlanFieldsPresent -Map $Identity -Names @('TargetStatus', 'LocationKey', 'VolumeId', 'DirectoryIdentity') -Failure $script:LivePlanSelectionMismatch
    if ([string] $Identity.TargetStatus -cne $ExpectedStatus) { throw $script:LivePlanSelectionMismatch }
    if ($ExpectedStatus -ceq 'MISSING') {
        if ($null -ne $Identity.DirectoryIdentity) { throw $script:LivePlanSelectionMismatch }
    }
    else {
        if ([string] $Identity.DirectoryIdentity -cnotmatch $script:LivePlanIdentityPattern) { throw $script:LivePlanSelectionMismatch }
    }
}

function Assert-LivePlanLiveSlots {
    param(
        $Platforms,
        [Parameter(Mandatory)] [string] $ExpectedStatus
    )
    $slots = @($Platforms)
    if ($slots.Count -ne 3) { throw $script:LivePlanSelectionMismatch }
    for ($index = 0; $index -lt 3; $index++) {
        $slot = Get-LivePlanMap -Value $slots[$index] -Failure $script:LivePlanSelectionMismatch
        Assert-LivePlanFieldsPresent -Map $slot -Names @(
            'Platform', 'SourceRoot', 'LiveRoot', 'SourceRootExists', 'LiveRootExists',
            'SourcePreIdentity', 'LivePreIdentity', 'ManifestHash', 'SourceTreeHash',
            'LiveTreeHash', 'ManagedNames'
        ) -Failure $script:LivePlanSelectionMismatch
        if ([string] $slot.Platform -cne $script:LivePlanPlatforms[$index]) { throw $script:LivePlanSelectionMismatch }
        Assert-LivePlanAbsolutePath -Value $slot.SourceRoot -Failure $script:LivePlanSelectionMismatch
        Assert-LivePlanAbsolutePath -Value $slot.LiveRoot -Failure $script:LivePlanSelectionMismatch
        $liveIdentity = Get-LivePlanMap -Value $slot.LivePreIdentity -Failure $script:LivePlanSelectionMismatch
        Assert-LivePlanPreIdentity -Identity $liveIdentity -ExpectedStatus $ExpectedStatus
        if ($ExpectedStatus -ceq 'MISSING') {
            if ([bool] $slot.LiveRootExists -or $null -ne $slot.LiveTreeHash) { throw $script:LivePlanSelectionMismatch }
        }
        else {
            if (-not [bool] $slot.LiveRootExists -or $null -eq $slot.LiveTreeHash) { throw $script:LivePlanSelectionMismatch }
            Assert-LivePlanHashSpelling -Value $slot.LiveTreeHash -Failure $script:LivePlanSelectionMismatch
        }
        $manifest = [string] $slot.ManifestHash
        if ($manifest -cne 'missing') { Assert-LivePlanHashSpelling -Value $manifest -Failure $script:LivePlanSelectionMismatch }
        if ($slot.ManagedNames -isnot [System.Array]) { throw $script:LivePlanSelectionMismatch }
    }
}

function Assert-LivePlanControlBase {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Intent,
        [string] $ExpectedStatus
    )
    Assert-LivePlanFieldsPresent -Map $Intent -Names @(
        'TargetStatus', 'RequestedPath', 'LocationKey', 'VolumeId', 'DirectoryIdentity', 'FilesystemCapability'
    ) -Failure $script:LivePlanSelectionMismatch
    $capability = Get-LivePlanMap -Value $Intent.FilesystemCapability -Failure $script:LivePlanSelectionMismatch
    if ([string] $capability.Status -cne 'UNPROBED') { throw $script:LivePlanSelectionMismatch }
    if (Test-LivePlanMapHasName -Map $capability -Name 'Hash') { throw $script:LivePlanSelectionMismatch }
    if ($ExpectedStatus) {
        if ([string] $Intent.TargetStatus -cne $ExpectedStatus) { throw $script:LivePlanSelectionMismatch }
    }
    if ([string] $Intent.TargetStatus -ceq 'MISSING') {
        if ($null -ne $Intent.DirectoryIdentity) { throw $script:LivePlanSelectionMismatch }
    }
    else {
        if ([string] $Intent.DirectoryIdentity -cnotmatch $script:LivePlanIdentityPattern) { throw $script:LivePlanSelectionMismatch }
    }
    Assert-LivePlanAbsolutePath -Value $Intent.RequestedPath -Failure $script:LivePlanSelectionMismatch
}

function Assert-LivePlanIntentLayer {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Payload,
        [Parameter(Mandatory)] [string] $Kind
    )
    $intent = Get-LivePlanMap -Value $Payload.AuthorityStateIntent -Failure $script:LivePlanSchemaUnsupported
    Assert-LivePlanFieldsAbsent -Map $intent -Names $script:LivePlanRuntimeFieldNames -Failure $script:LivePlanSchemaUnsupported
    Assert-LivePlanFieldsAbsent -Map $intent -Names @('PlanHash', 'DocumentHash') -Failure $script:LivePlanSchemaUnsupported
    if ([string] $intent.LastOperationKind -cne $Kind) { throw $script:LivePlanKindMismatch }
    $expectedKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $script:AuthorityStateIntentFieldNames) {
        if ($name -ceq 'PlanHash' -or $name -ceq 'DocumentHash') { continue }
        $expectedKeys.Add($name)
    }
    if ($Kind -ceq 'controller-transition') {
        if (-not (Test-LivePlanMapHasName -Map $intent -Name 'ReceiptRef') -or [string] $intent.ReceiptRef -cne 'NO_LIVE_MUTATION') {
            throw $script:LivePlanKindMismatch
        }
        $expectedKeys.Add('ReceiptRef')
    }
    else {
        if (Test-LivePlanMapHasName -Map $intent -Name 'ReceiptRef') { throw $script:LivePlanKindMismatch }
    }
    try {
        Assert-AuthorityStateExactKeys -InputObject $intent -Expected @($expectedKeys) -Label 'live-plan authority state intent'
    }
    catch {
        throw $script:LivePlanSelectionMismatch
    }
    if ([long] $intent.SchemaVersion -ne 3 -or [string] $intent.ArtifactKind -cne 'current-env-state') { throw $script:LivePlanSchemaUnsupported }
    if ([string] $intent.SelectionKind -cne 'environment') { throw $script:LivePlanSelectionMismatch }
    Assert-LivePlanHashSpelling -Value $intent.HomeAuthorityKey -Failure $script:LivePlanSelectionMismatch
    Assert-LivePlanHashSpelling -Value $intent.RootClaimsHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanHashSpelling -Value $intent.EnvironmentLockHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanHashSpelling -Value $intent.TaskOverlayHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanHashSpelling -Value $intent.ControllerRepoFingerprint -Failure $script:LivePlanHashMismatch
    Assert-LivePlanHashSpelling -Value $intent.ApprovedToolchainHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanPlatformTriple -Rows $intent.TaskOverlaySkills -ValueName 'Skills'
    Assert-LivePlanPlatformTriple -Rows $intent.ManifestHashes -ValueName 'Hash'
    Assert-LivePlanPlatformTriple -Rows $intent.FinalManagedHashes -ValueName 'Hash'
    if ([string] $intent.ControllerRepoFingerprint -cne [string] $Payload.ControllerRepoFingerprint) { throw $script:LivePlanSelectionMismatch }
    if ([string] $intent.ApprovedToolchainHash -cne [string] $Payload.ApprovedToolchainHash) { throw $script:LivePlanSelectionMismatch }
    if (Test-LivePlanMapHasName -Map $Payload -Name 'EnvironmentName') {
        if ([string] $intent.EnvironmentName -cne [string] $Payload.EnvironmentName) { throw $script:LivePlanSelectionMismatch }
    }
    if ($Kind -ceq 'initial' -and [string] $intent.EnvironmentName -cne 'full') { throw $script:LivePlanKindMismatch }
    if ($Kind -ceq 'retirement' -and [string] $intent.LastOperationKind -cne 'retirement') { throw $script:LivePlanKindMismatch }
    return $intent
}

function Assert-LivePlanTaskOverlayEvidence {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Evidence)
    Assert-LivePlanFieldsPresent -Map $Evidence -Names @('CurrentHash', 'CandidateHash', 'CandidatePath', 'Action', 'RemovalReview') -Failure $script:LivePlanKindMismatch
    Assert-LivePlanHashSpelling -Value $Evidence.CurrentHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanHashSpelling -Value $Evidence.CandidateHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanAbsolutePath -Value $Evidence.CandidatePath -Failure $script:LivePlanSelectionMismatch
    if ([string] $Evidence.Action -eq '') { throw $script:LivePlanKindMismatch }
    if ($Evidence.RemovalReview -isnot [bool]) { throw $script:LivePlanKindMismatch }
}

function Assert-LivePlanLegacyEvidence {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Evidence)
    Assert-LivePlanFieldsPresent -Map $Evidence -Names @('Status') -Failure $script:LivePlanKindMismatch
    if ([string] $Evidence.Status -cnotin @('MISSING', 'UNTRUSTED')) { throw $script:LivePlanKindMismatch }
    $names = @($Evidence.Keys | ForEach-Object { [string] $_ })
    if ($names.Count -ne 1) { throw $script:LivePlanKindMismatch }
}

function Assert-LivePlanStateEvidence {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Evidence)
    if (-not (Test-LivePlanMapHasName -Map $Evidence -Name 'Kind')) { throw $script:LivePlanKindMismatch }
    $kind = [string] $Evidence.Kind
    if ($kind -ceq 'CORRUPT') {
        Assert-LivePlanFieldsPresent -Map $Evidence -Names @('Kind', 'Path', 'RawHash', 'PreimageHash') -Failure $script:LivePlanKindMismatch
        Assert-LivePlanFieldsAbsent -Map $Evidence -Names @('Marker') -Failure $script:LivePlanKindMismatch
        Assert-LivePlanAbsolutePath -Value $Evidence.Path -Failure $script:LivePlanSelectionMismatch
        Assert-LivePlanHashSpelling -Value $Evidence.RawHash -Failure $script:LivePlanHashMismatch
        Assert-LivePlanHashSpelling -Value $Evidence.PreimageHash -Failure $script:LivePlanHashMismatch
        $expected = @('Kind', 'Path', 'RawHash', 'PreimageHash')
        try { Assert-AuthorityStateExactKeys -InputObject $Evidence -Expected $expected -Label 'live-plan StateEvidence CORRUPT' }
        catch { throw $script:LivePlanKindMismatch }
    }
    elseif ($kind -ceq 'MISSING') {
        Assert-LivePlanFieldsPresent -Map $Evidence -Names @('Kind', 'Marker') -Failure $script:LivePlanKindMismatch
        Assert-LivePlanFieldsAbsent -Map $Evidence -Names @('Path', 'RawHash', 'PreimageHash') -Failure $script:LivePlanKindMismatch
        if ([bool] $Evidence.Marker -ne $true) { throw $script:LivePlanKindMismatch }
        try { Assert-AuthorityStateExactKeys -InputObject $Evidence -Expected @('Kind', 'Marker') -Label 'live-plan StateEvidence MISSING' }
        catch { throw $script:LivePlanKindMismatch }
    }
    else { throw $script:LivePlanKindMismatch }
}

function Assert-LivePlanRetirementManifest {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Manifest,
        $Actions
    )
    Assert-LivePlanFieldsPresent -Map $Manifest -Names @(
        'Path', 'Hash', 'SafeNames', 'CanonicalAbsenceHash', 'GeneratedAbsenceHash',
        'CurrentManifestAbsenceHash', 'TargetTreeHashes', 'Postset'
    ) -Failure $script:LivePlanKindMismatch
    Assert-LivePlanAbsolutePath -Value $Manifest.Path -Failure $script:LivePlanSelectionMismatch
    foreach ($hashName in @('Hash', 'CanonicalAbsenceHash', 'GeneratedAbsenceHash', 'CurrentManifestAbsenceHash')) {
        Assert-LivePlanHashSpelling -Value $Manifest[$hashName] -Failure $script:LivePlanHashMismatch
    }
    Assert-LivePlanPlatformTriple -Rows $Manifest.SafeNames -ValueName 'Names'
    Assert-LivePlanPlatformTriple -Rows $Manifest.TargetTreeHashes -ValueName 'Hash'
    $postset = Get-LivePlanMap -Value $Manifest.Postset -Failure $script:LivePlanKindMismatch
    Assert-LivePlanFieldsPresent -Map $postset -Names @(
        'EnvironmentName', 'EnvironmentLockHash', 'TaskOverlayHash', 'TaskOverlaySkills', 'ManifestHashes'
    ) -Failure $script:LivePlanKindMismatch
    Assert-LivePlanHashSpelling -Value $postset.EnvironmentLockHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanHashSpelling -Value $postset.TaskOverlayHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanPlatformTriple -Rows $postset.TaskOverlaySkills -ValueName 'Skills'
    Assert-LivePlanPlatformTriple -Rows $postset.ManifestHashes -ValueName 'Hash'

    $postsetSkills = @{}
    foreach ($row in @($postset.TaskOverlaySkills)) {
        $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($skill in @($row.Skills)) { $null = $set.Add([string] $skill) }
        $postsetSkills[[string] $row.Platform] = $set
    }
    foreach ($row in @($Manifest.SafeNames)) {
        $platform = [string] $row.Platform
        foreach ($name in @($row.Names)) {
            if ($postsetSkills[$platform].Contains([string] $name)) { throw $script:LivePlanRetirementSelectionConflict }
        }
    }
    foreach ($action in @($Actions)) {
        $row = Get-LivePlanMap -Value $action -Failure $script:LivePlanSelectionMismatch
        if ([string] $row.Action -cne 'prune') { continue }
        $platform = [string] $row.Platform
        $name = [string] $row.Name
        if ($postsetSkills.ContainsKey($platform) -and $postsetSkills[$platform].Contains($name)) {
            throw $script:LivePlanRetirementSelectionConflict
        }
    }
}

function Assert-LivePlanKindBody {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Payload,
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Intent
    )
    $control = Get-LivePlanMap -Value $Payload.ControlBaseIntent -Failure $script:LivePlanSelectionMismatch
    switch ($Kind) {
        'initial' {
            if ([string] $Payload.EnvironmentName -cne 'full') { throw $script:LivePlanKindMismatch }
            Assert-LivePlanMaterializationRoot -Root (Get-LivePlanMap -Value $Payload.EnvironmentMaterializationRoot -Failure $script:LivePlanKindMismatch)
            $claims = @($Payload.ProposedRootClaims)
            if ($claims.Count -ne 3) { throw $script:LivePlanKindMismatch }
            $expectedClaimsHash = Get-SemanticJsonHash -InputObject @($claims)
            if ([string] $Payload.RootClaimsHash -cne $expectedClaimsHash -or [string] $Intent.RootClaimsHash -cne $expectedClaimsHash) {
                throw $script:LivePlanHashMismatch
            }
            $rows = @($Payload.TargetContextIntent.Rows)
            if ((Get-SemanticJsonHash -InputObject @($rows)) -cne $expectedClaimsHash) { throw $script:LivePlanSelectionMismatch }
            for ($index = 0; $index -lt 3; $index++) {
                $claim = Get-LivePlanMap -Value $claims[$index] -Failure $script:LivePlanKindMismatch
                if ([string] $claim.Platform -cne $script:LivePlanPlatforms[$index] -or [string] $claim.InitialState -cne 'ABSENT') {
                    throw $script:LivePlanSelectionMismatch
                }
                if ($null -ne $claim.InitialDirectoryIdentity -or @($claim.MissingRemainder).Count -lt 1) { throw $script:LivePlanSelectionMismatch }
            }
            Assert-LivePlanControlBase -Intent $control -ExpectedStatus 'MISSING'
            Assert-LivePlanLiveSlots -Platforms $Payload.Platforms -ExpectedStatus 'MISSING'
        }
        'environment' {
            Assert-LivePlanMaterializationRoot -Root (Get-LivePlanMap -Value $Payload.EnvironmentMaterializationRoot -Failure $script:LivePlanKindMismatch)
            Assert-LivePlanControlBase -Intent $control -ExpectedStatus 'EXISTS'
            Assert-LivePlanLiveSlots -Platforms $Payload.Platforms -ExpectedStatus 'EXISTS'
        }
        'task-overlay' {
            Assert-LivePlanMaterializationRoot -Root (Get-LivePlanMap -Value $Payload.EnvironmentMaterializationRoot -Failure $script:LivePlanKindMismatch)
            Assert-LivePlanTaskOverlayEvidence -Evidence (Get-LivePlanMap -Value $Payload.TaskOverlayEvidence -Failure $script:LivePlanKindMismatch)
            Assert-LivePlanControlBase -Intent $control -ExpectedStatus 'EXISTS'
            Assert-LivePlanLiveSlots -Platforms $Payload.Platforms -ExpectedStatus 'EXISTS'
        }
        'migrate' {
            Assert-LivePlanMaterializationRoot -Root (Get-LivePlanMap -Value $Payload.EnvironmentMaterializationRoot -Failure $script:LivePlanKindMismatch)
            Assert-LivePlanAbsolutePath -Value $Payload.LegacyLocator -Failure $script:LivePlanKindMismatch
            Assert-LivePlanHashSpelling -Value $Payload.LegacyHash -Failure $script:LivePlanHashMismatch
            Assert-LivePlanHashSpelling -Value $Payload.LegacyCoreHash -Failure $script:LivePlanHashMismatch
            Assert-LivePlanHashSpelling -Value $Payload.OldLockHash -Failure $script:LivePlanHashMismatch
            Assert-LivePlanControlBase -Intent $control
        }
        'adopt' {
            Assert-LivePlanLegacyEvidence -Evidence (Get-LivePlanMap -Value $Payload.LegacyEvidence -Failure $script:LivePlanKindMismatch)
            Assert-LivePlanControlBase -Intent $control
        }
        'repair-adopt' {
            Assert-LivePlanStateEvidence -Evidence (Get-LivePlanMap -Value $Payload.StateEvidence -Failure $script:LivePlanKindMismatch)
            Assert-LivePlanControlBase -Intent $control
        }
        'controller-transition' {
            $parity = Get-LivePlanMap -Value $Payload.ControllerParity -Failure $script:LivePlanKindMismatch
            Assert-LivePlanFieldsPresent -Map $parity -Names @('PreviousControllerRepoFingerprint') -Failure $script:LivePlanKindMismatch
            Assert-LivePlanHashSpelling -Value $parity.PreviousControllerRepoFingerprint -Failure $script:LivePlanHashMismatch
            Assert-LivePlanControlBase -Intent $control -ExpectedStatus 'EXISTS'
            Assert-LivePlanLiveSlots -Platforms $Payload.Platforms -ExpectedStatus 'EXISTS'
        }
        'retirement' {
            Assert-LivePlanRetirementManifest -Manifest (Get-LivePlanMap -Value $Payload.RetirementManifest -Failure $script:LivePlanKindMismatch) -Actions $Payload.OrderedActions
            Assert-LivePlanControlBase -Intent $control
        }
        default { throw $script:LivePlanKindMismatch }
    }
}

function Test-LiveSyncPlanSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)

    $documentMap = Get-LivePlanMap -Value $Document -Failure $script:LivePlanSchemaUnsupported
    if (-not (Test-LivePlanMapHasName -Map $documentMap -Name 'SchemaVersion') -or [long] $documentMap.SchemaVersion -ne 3) {
        throw $script:LivePlanSchemaUnsupported
    }
    if (-not (Test-LivePlanMapHasName -Map $documentMap -Name 'ArtifactKind') -or [string] $documentMap.ArtifactKind -cne 'sync-plan') {
        throw $script:LivePlanSchemaUnsupported
    }
    Assert-LivePlanRuntimeFieldsAbsent -Document $documentMap
    Assert-LivePlanEnvelopeHashes -Document $documentMap

    $payload = Get-LivePlanMap -Value $documentMap.PlanPayload -Failure $script:LivePlanSchemaUnsupported
    Assert-LivePlanFieldsPresent -Map $payload -Names @(
        'OperationKind', 'Generator', 'RepositoryCommit', 'RepoRoot', 'ApprovedToolchainHash',
        'ControllerRepoFingerprint', 'ControlBaseIntent', 'Platforms', 'OrderedActions',
        'UnknownMarkers', 'SystemMarker', 'TargetContextIntent', 'AuthorityStateIntent'
    ) -Failure $script:LivePlanSchemaUnsupported

    $kind = [string] $payload.OperationKind
    if ($kind.StartsWith('live-recover-', [StringComparison]::Ordinal) -or $kind -cnotin $script:LivePlanKinds) {
        throw $script:LivePlanKindMismatch
    }
    $spec = Get-LivePlanKindSpec -Kind $kind
    if ([string] $payload.Generator -cne [string] $spec.Generator) { throw $script:LivePlanKindMismatch }
    Assert-LivePlanFieldsPresent -Map $payload -Names @($spec.Required) -Failure $script:LivePlanKindMismatch
    Assert-LivePlanFieldsAbsent -Map $payload -Names @($spec.Forbidden) -Failure $script:LivePlanKindMismatch
    if ([string] $payload.RepositoryCommit -cnotmatch $script:LivePlanCommitPattern) { throw $script:LivePlanSelectionMismatch }
    Assert-LivePlanAbsolutePath -Value $payload.RepoRoot -Failure $script:LivePlanSelectionMismatch
    Assert-LivePlanHashSpelling -Value $payload.ApprovedToolchainHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanHashSpelling -Value $payload.ControllerRepoFingerprint -Failure $script:LivePlanHashMismatch

    $intent = Assert-LivePlanIntentLayer -Payload $payload -Kind $kind
    $lastKind = [string] $intent.LastOperationKind
    if ($lastKind.StartsWith('live-recover-', [StringComparison]::Ordinal)) { throw $script:LivePlanKindMismatch }

    $targetIntent = Get-LivePlanMap -Value $payload.TargetContextIntent -Failure $script:LivePlanSelectionMismatch
    try {
        Assert-AuthorityTargetContextIntent -Intent $targetIntent
    }
    catch {
        throw $script:LivePlanSelectionMismatch
    }
    if ([string] $targetIntent.HomeAuthorityKey -cne [string] $intent.HomeAuthorityKey) { throw $script:LivePlanSelectionMismatch }

    Assert-LivePlanSystemMarker -Marker (Get-LivePlanMap -Value $payload.SystemMarker -Failure $script:LivePlanSystemMarkerDrift)
    Assert-LivePlanUnknownMarkers -Markers $payload.UnknownMarkers
    Assert-LivePlanOrderedActions -Actions $payload.OrderedActions -Kind $kind
    Assert-LivePlanKindBody -Payload $payload -Kind $kind -Intent $intent
}

function Complete-LivePlanAuthorityStateIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)

    $documentMap = Get-LivePlanMap -Value $Document -Failure $script:LivePlanSchemaUnsupported
    if (-not (Test-LivePlanMapHasName -Map $documentMap -Name 'PlanPayload')) { throw $script:LivePlanSchemaUnsupported }
    if (-not (Test-LivePlanMapHasName -Map $documentMap -Name 'PlanHash')) { throw $script:LivePlanSchemaUnsupported }
    if (-not (Test-LivePlanMapHasName -Map $documentMap -Name 'DocumentHash')) { throw $script:LivePlanSchemaUnsupported }
    Assert-LivePlanHashSpelling -Value $documentMap.PlanHash -Failure $script:LivePlanHashMismatch
    Assert-LivePlanHashSpelling -Value $documentMap.DocumentHash -Failure $script:LivePlanHashMismatch

    $payload = Get-LivePlanMap -Value $documentMap.PlanPayload -Failure $script:LivePlanSchemaUnsupported
    $intent = Get-LivePlanMap -Value $payload.AuthorityStateIntent -Failure $script:LivePlanSchemaUnsupported
    $kind = [string] $intent.LastOperationKind
    $completed = [ordered]@{}
    foreach ($name in $script:AuthorityStateIntentFieldNames) {
        if ($name -ceq 'PlanHash') {
            $completed[$name] = [string] $documentMap.PlanHash
            continue
        }
        if ($name -ceq 'DocumentHash') {
            $completed[$name] = [string] $documentMap.DocumentHash
            continue
        }
        if (-not (Test-LivePlanMapHasName -Map $intent -Name $name)) { throw $script:LivePlanSelectionMismatch }
        $completed[$name] = $intent[$name]
    }
    $expected = [System.Collections.Generic.List[string]]::new()
    $expected.AddRange([string[]] $script:AuthorityStateIntentFieldNames)
    if ($kind -ceq 'controller-transition') {
        if (-not (Test-LivePlanMapHasName -Map $intent -Name 'ReceiptRef') -or [string] $intent.ReceiptRef -cne 'NO_LIVE_MUTATION') {
            throw $script:LivePlanKindMismatch
        }
        $completed['ReceiptRef'] = [string] $intent.ReceiptRef
        $expected.Add('ReceiptRef')
    }
    elseif (Test-LivePlanMapHasName -Map $intent -Name 'ReceiptRef') {
        throw $script:LivePlanKindMismatch
    }
    try {
        Assert-AuthorityStateExactKeys -InputObject $completed -Expected @($expected) -Label 'completed live-plan authority state intent'
    }
    catch {
        throw $script:LivePlanSelectionMismatch
    }
    return $completed
}

function Write-LiveSyncPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document
    )
    if (Test-Path -LiteralPath $Path) { throw $script:LivePlanPathCollision }
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $documentText = (ConvertTo-Json -InputObject $Document -Depth 40) + "`n"
    [System.IO.File]::WriteAllText($Path, $documentText, [System.Text.UTF8Encoding]::new($false))
}

function Read-LiveSyncPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $script:LivePlanPathCollision }
    $document = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($Path))
    if ([string] $document.SchemaVersion -cne '3' -or [string] $document.ArtifactKind -cne 'sync-plan') {
        throw $script:LivePlanSchemaUnsupported
    }
    return $document
}

function Assert-LiveSyncPlanDocumentIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    Test-LiveSyncPlanSemantics -Document $Document
    Assert-LivePlanEnvelopeHashes -Document $Document
}

function Assert-LiveSyncPlanCurrent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $MaterializationDirectory
    )
    $payload = $Document['PlanPayload']
    $bound = $payload['EnvironmentMaterializationRoot']
    if ($bound -isnot [System.Collections.IDictionary]) { throw $script:LivePlanHashMismatch }
    $materializationFull = [System.IO.Path]::GetFullPath($MaterializationDirectory)
    if ([string] $bound['Path'] -cne $materializationFull) { throw $script:LivePlanHashMismatch }
    $envBuildPath = [System.IO.Path]::GetFullPath((Join-Path $materializationFull 'env-build.json'))
    $envLockPath = [System.IO.Path]::GetFullPath((Join-Path $materializationFull 'env.lock.json'))
    if ([string] $bound['EnvBuildPath'] -cne $envBuildPath -or [string] $bound['EnvLockPath'] -cne $envLockPath) {
        throw $script:LivePlanHashMismatch
    }
    if (-not (Test-Path -LiteralPath $envBuildPath -PathType Leaf) -or -not (Test-Path -LiteralPath $envLockPath -PathType Leaf)) {
        throw $script:LivePlanHashMismatch
    }
    $envBuildBytes = [System.IO.File]::ReadAllBytes($envBuildPath)
    $envLockBytes = [System.IO.File]::ReadAllBytes($envLockPath)
    $envBuildBytesHash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($envBuildBytes)).ToLowerInvariant()
    $envLockBytesHash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($envLockBytes)).ToLowerInvariant()
    if ([string] $bound['EnvBuildHash'] -cne $envBuildBytesHash -or [string] $bound['EnvLockHash'] -cne $envLockBytesHash) {
        throw $script:LivePlanHashMismatch
    }
    $envBuildDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($envBuildBytes))
    $materializationHash = Get-HarnessEnvMaterializationHash -Document $envBuildDocument
    if ([string] $bound['MaterializationHash'] -cne $materializationHash) { throw $script:LivePlanHashMismatch }
}

function Assert-LiveSyncPlanSelectionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $ExpectedOperationKind,
        [AllowNull()] [string] $ExpectedEnvironmentName
    )
    $payload = $Document['PlanPayload']
    if ([string] $payload['OperationKind'] -cne $ExpectedOperationKind) { throw $script:LivePlanSelectionMismatch }
    $intent = $payload['AuthorityStateIntent']
    if ([string] $intent['LastOperationKind'] -cne $ExpectedOperationKind) { throw $script:LivePlanSelectionMismatch }
    if ($null -ne $ExpectedEnvironmentName -and [string] $payload['EnvironmentName'] -cne $ExpectedEnvironmentName) {
        throw $script:LivePlanSelectionMismatch
    }
}

function Assert-LiveSyncPlanDocumentHashNotConsumed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [AllowNull()] [System.Collections.IDictionary] $TerminalEvidence
    )
    $documentHash = [string] $Document['DocumentHash']
    if ([string]::IsNullOrWhiteSpace($documentHash)) { throw $script:LivePlanHashMismatch }
    if ($null -ne $TerminalEvidence -and $TerminalEvidence.Contains($documentHash)) {
        throw $script:LivePlanConsumed
    }
}
