#requires -Version 7.0

Set-StrictMode -Version Latest

$script:SealedLivePlanHelperPath = 'tests/helpers/sealed-live-plan-fixture.ps1'
$script:SealedLivePlanRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not (Get-Command -Name Test-LiveSafetySandboxCapability -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:SealedLivePlanRepoRoot 'scripts/live-safety-interlock.ps1')
}
if (-not (Get-Command -Name Get-PlanHash -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:SealedLivePlanRepoRoot 'scripts/live-plan-common.ps1')
}

function Get-SealedLivePlanRepeatedHash {
    param([Parameter(Mandatory)] [string] $Character)
    return ($Character * 64)
}

function New-SealedLivePlanHashSlot {
    param([Parameter(Mandatory)] [string] $Platform, [Parameter(Mandatory)] [string] $Hash)
    return [ordered]@{ Hash = $Hash; Platform = $Platform }
}

function New-SealedLivePlanSkillSlot {
    param([Parameter(Mandatory)] [string] $Platform)
    return [ordered]@{ Platform = $Platform; Skills = @() }
}

function New-SealedLivePlanExistsClaim {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestedPath,
        [Parameter(Mandatory)] [string] $LocationKey,
        [Parameter(Mandatory)] [string] $Identity
    )
    return [ordered]@{
        DeepestExistingParentIdentity = $Identity
        DeepestExistingParentPath = $RequestedPath
        ExpectedPostState = 'EXISTS'
        InitialDirectoryIdentity = $Identity
        InitialState = 'EXISTS'
        LocationKey = $LocationKey
        MissingRemainder = @()
        Platform = $Platform
        RequestedPath = $RequestedPath
        VolumeId = 'a1b2c3d4'
    }
}

function New-SealedLivePlanExistsSlot {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $SourceLocation,
        [Parameter(Mandatory)] [string] $LiveLocation,
        [Parameter(Mandatory)] [string] $SourceIdentity,
        [Parameter(Mandatory)] [string] $LiveIdentity,
        [Parameter(Mandatory)] [string] $SourceTreeHash,
        [Parameter(Mandatory)] [string] $LiveTreeHash,
        [Parameter(Mandatory)] [string] $ManifestHash
    )
    return [ordered]@{
        LivePreIdentity = [ordered]@{
            DirectoryIdentity = $LiveIdentity
            LocationKey = $LiveLocation
            TargetStatus = 'EXISTS'
            VolumeId = 'a1b2c3d4'
        }
        LiveRoot = $LiveRoot
        LiveRootExists = $true
        LiveTreeHash = $LiveTreeHash
        ManagedNames = @()
        ManifestHash = $ManifestHash
        Platform = $Platform
        SourcePreIdentity = [ordered]@{
            DirectoryIdentity = $SourceIdentity
            LocationKey = $SourceLocation
            TargetStatus = 'EXISTS'
            VolumeId = 'a1b2c3d4'
        }
        SourceRoot = $SourceRoot
        SourceRootExists = $true
        SourceTreeHash = $SourceTreeHash
    }
}

function New-SealedLivePlanAuthorityIntent {
    param(
        [Parameter(Mandatory)] [string] $LastOperationKind,
        [Parameter(Mandatory)] [string] $EnvironmentName,
        [string] $ReceiptRef
    )
    $intent = [ordered]@{
        ApprovedToolchainHash = Get-SealedLivePlanRepeatedHash -Character '4'
        ArtifactKind = 'current-env-state'
        AuthorityGeneration = 1
        ControllerRepoFingerprint = Get-SealedLivePlanRepeatedHash -Character '5'
        EnvironmentLockHash = Get-SealedLivePlanRepeatedHash -Character 'b'
        EnvironmentName = $EnvironmentName
        FinalManagedHashes = @(
            (New-SealedLivePlanHashSlot -Platform 'Claude' -Hash (Get-SealedLivePlanRepeatedHash -Character '1'))
            (New-SealedLivePlanHashSlot -Platform 'Codex' -Hash (Get-SealedLivePlanRepeatedHash -Character '2'))
            (New-SealedLivePlanHashSlot -Platform 'Reasonix' -Hash (Get-SealedLivePlanRepeatedHash -Character '3'))
        )
        HomeAuthorityKey = Get-SealedLivePlanRepeatedHash -Character 'a'
        LastOperationKind = $LastOperationKind
        ManifestHashes = @(
            (New-SealedLivePlanHashSlot -Platform 'Claude' -Hash (Get-SealedLivePlanRepeatedHash -Character 'd'))
            (New-SealedLivePlanHashSlot -Platform 'Codex' -Hash (Get-SealedLivePlanRepeatedHash -Character 'e'))
            (New-SealedLivePlanHashSlot -Platform 'Reasonix' -Hash (Get-SealedLivePlanRepeatedHash -Character 'f'))
        )
        RootClaimsHash = Get-SealedLivePlanRepeatedHash -Character 'c'
        SchemaVersion = 3
        SelectionKind = 'environment'
        TaskOverlayHash = Get-SealedLivePlanRepeatedHash -Character 'c'
        TaskOverlaySkills = @(
            (New-SealedLivePlanSkillSlot -Platform 'Claude')
            (New-SealedLivePlanSkillSlot -Platform 'Codex')
            (New-SealedLivePlanSkillSlot -Platform 'Reasonix')
        )
    }
    if ($PSBoundParameters.ContainsKey('ReceiptRef')) {
        $intent['ReceiptRef'] = $ReceiptRef
    }
    return $intent
}

function New-SealedLivePlanExistingAuthorityPayload {
    param(
        [Parameter(Mandatory)] [string] $OperationKind,
        [Parameter(Mandatory)] [string] $EnvironmentName,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $AuthorityStateIntent
    )
    $claims = @(
        (New-SealedLivePlanExistsClaim -Platform 'Claude' -RequestedPath 'C:\fixture\profile\.claude\skills' -LocationKey 'c:/fixture/profile/.claude/skills' -Identity 'a1b2c3d4:0000000000000a01')
        (New-SealedLivePlanExistsClaim -Platform 'Codex' -RequestedPath 'C:\fixture\profile\.codex\skills' -LocationKey 'c:/fixture/profile/.codex/skills' -Identity 'a1b2c3d4:0000000000000a02')
        (New-SealedLivePlanExistsClaim -Platform 'Reasonix' -RequestedPath 'C:\fixture\roaming\reasonix\skills' -LocationKey 'c:/fixture/roaming/reasonix/skills' -Identity 'a1b2c3d4:0000000000000a03')
    )
    $payload = [ordered]@{
        ApprovedToolchainHash = Get-SealedLivePlanRepeatedHash -Character '4'
        AuthorityStateIntent = $AuthorityStateIntent
        ControlBaseIntent = [ordered]@{
            DirectoryIdentity = 'a1b2c3d4:00000000000000cc'
            FilesystemCapability = [ordered]@{ Status = 'UNPROBED' }
            LocationKey = 'c:/fixture/control'
            RequestedPath = 'C:\fixture\control'
            TargetStatus = 'EXISTS'
            VolumeId = 'a1b2c3d4'
        }
        ControllerRepoFingerprint = Get-SealedLivePlanRepeatedHash -Character '5'
        EnvironmentName = $EnvironmentName
        Generator = $script:SealedLivePlanHelperPath
        OperationKind = $OperationKind
        OrderedActions = @()
        Platforms = @(
            (New-SealedLivePlanExistsSlot -Platform 'Claude' -SourceRoot 'C:\fixture\plans\sealed-live-plan.materialization\claude\skills' -LiveRoot 'C:\fixture\profile\.claude\skills' -SourceLocation 'c:/fixture/plans/sealed-live-plan.materialization/claude/skills' -LiveLocation 'c:/fixture/profile/.claude/skills' -SourceIdentity 'a1b2c3d4:0000000000000101' -LiveIdentity 'a1b2c3d4:0000000000000a01' -SourceTreeHash (Get-SealedLivePlanRepeatedHash -Character '8') -LiveTreeHash (Get-SealedLivePlanRepeatedHash -Character '9') -ManifestHash (Get-SealedLivePlanRepeatedHash -Character 'd'))
            (New-SealedLivePlanExistsSlot -Platform 'Codex' -SourceRoot 'C:\fixture\plans\sealed-live-plan.materialization\codex\skills' -LiveRoot 'C:\fixture\profile\.codex\skills' -SourceLocation 'c:/fixture/plans/sealed-live-plan.materialization/codex/skills' -LiveLocation 'c:/fixture/profile/.codex/skills' -SourceIdentity 'a1b2c3d4:0000000000000102' -LiveIdentity 'a1b2c3d4:0000000000000a02' -SourceTreeHash (Get-SealedLivePlanRepeatedHash -Character '9') -LiveTreeHash (Get-SealedLivePlanRepeatedHash -Character '8') -ManifestHash (Get-SealedLivePlanRepeatedHash -Character 'e'))
            (New-SealedLivePlanExistsSlot -Platform 'Reasonix' -SourceRoot 'C:\fixture\plans\sealed-live-plan.materialization\reasonix\skills' -LiveRoot 'C:\fixture\roaming\reasonix\skills' -SourceLocation 'c:/fixture/plans/sealed-live-plan.materialization/reasonix/skills' -LiveLocation 'c:/fixture/roaming/reasonix/skills' -SourceIdentity 'a1b2c3d4:0000000000000103' -LiveIdentity 'a1b2c3d4:0000000000000a03' -SourceTreeHash (Get-SealedLivePlanRepeatedHash -Character 'a') -LiveTreeHash (Get-SealedLivePlanRepeatedHash -Character 'b') -ManifestHash (Get-SealedLivePlanRepeatedHash -Character 'f'))
        )
        RepoRoot = 'C:\fixture\repo'
        RepositoryCommit = '1111111111111111111111111111111111111111'
        SystemMarker = [ordered]@{ Hash = $null; Identity = $null; Name = '.system'; Platform = 'Codex'; Present = $false }
        TargetContextIntent = [ordered]@{
            HomeAuthorityKey = Get-SealedLivePlanRepeatedHash -Character 'a'
            Rows = $claims
        }
        UnknownMarkers = @()
    }
    return $payload
}

function New-SealedLivePlanDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('environment', 'controller-transition')]
        [string] $OperationKind
    )

    $hostResolutionRequired = 'live-plan-host-resolution-required'
    if (-not (Test-LiveSafetySandboxCapability)) { throw $hostResolutionRequired }

    $environmentName = 'work'
    $intent = if ($OperationKind -ceq 'controller-transition') {
        New-SealedLivePlanAuthorityIntent -LastOperationKind $OperationKind -EnvironmentName $environmentName -ReceiptRef 'NO_LIVE_MUTATION'
    }
    else {
        New-SealedLivePlanAuthorityIntent -LastOperationKind $OperationKind -EnvironmentName $environmentName
    }
    $payload = New-SealedLivePlanExistingAuthorityPayload -OperationKind $OperationKind -EnvironmentName $environmentName -AuthorityStateIntent $intent
    if ($OperationKind -ceq 'environment') {
        $payload['EnvironmentMaterializationRoot'] = [ordered]@{
            EnvBuildHash = Get-SealedLivePlanRepeatedHash -Character '7'
            EnvBuildPath = 'C:\fixture\plans\sealed-live-plan.materialization\env-build.json'
            EnvLockHash = Get-SealedLivePlanRepeatedHash -Character 'b'
            EnvLockPath = 'C:\fixture\plans\sealed-live-plan.materialization\env.lock.json'
            Identity = 'a1b2c3d4:00000000000000aa'
            MaterializationHash = Get-SealedLivePlanRepeatedHash -Character '6'
            Path = 'C:\fixture\plans\sealed-live-plan.materialization'
        }
    }
    else {
        $payload['ControllerParity'] = [ordered]@{
            PreviousControllerRepoFingerprint = Get-SealedLivePlanRepeatedHash -Character '0'
        }
    }

    $document = [ordered]@{
        ArtifactKind = 'sync-plan'
        Metadata = [ordered]@{ GeneratedAtUtc = '2026-09-08T00:00:00.0000000Z' }
        PlanPayload = $payload
        SchemaVersion = 3
    }
    $document['PlanHash'] = Get-PlanHash -PlanPayload $payload
    $document['DocumentHash'] = Get-DocumentHash -Document $document
    return $document
}
