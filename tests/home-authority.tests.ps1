#requires -Version 7.0
[CmdletBinding()]
param([string]$Section = 'all')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/home-authority-common.ps1')
. (Join-Path $RepoRoot 'scripts/shared-authority-state-common.ps1')
. (Join-Path $RepoRoot 'scripts/transaction-journal-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/home-authority-test-host.ps1')

$sections = @($Section.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim().ToLowerInvariant() })
if ($sections.Count -eq 0) { $sections = @('all') }
foreach ($name in $sections) {
    if ($name -notin @('all', 'schema', 'locking', 'resolver')) { throw "Unknown home-authority test section: $name" }
}
function Test-Section([string]$Name) { return $sections -contains 'all' -or $sections -contains $Name }

function Assert-ThrowsPattern {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Pattern,[Parameter(Mandatory)][string]$Message)
    try { & $Action; throw "FAIL: $Message (did not throw)" }
    catch {
        if ($_.Exception.Message -like 'FAIL:*') { throw }
        Assert-TestCondition ($_.Exception.Message -match $Pattern) $Message
    }
}

function Get-FixtureInventoryHash {
    param([Parameter(Mandatory)][string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root)
    $rows = @([IO.Directory]::EnumerateFileSystemEntries($rootFull, '*', [IO.SearchOption]::AllDirectories) | Sort-Object | ForEach-Object {
        $full = [IO.Path]::GetFullPath($_)
        $marker = Get-NoFollowRootEntryMarker -Path $full
        [ordered]@{
            RelativePath = [IO.Path]::GetRelativePath($rootFull, $full).Replace([char]92, [char]47)
            EntryType = [string]$marker.EntryType
            Identity = [string]$marker.Identity
        }
    })
    return Get-SemanticJsonHash -InputObject $rows
}

function Copy-SemanticDocument {
    param([Parameter(Mandatory)]$Document)
    return ConvertFrom-SemanticJson -Json ([Text.Encoding]::UTF8.GetString((ConvertTo-SemanticJsonBytes -InputObject $Document)))
}

function Write-TestSemanticDocument {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Document)
    [IO.File]::WriteAllBytes($Path,(ConvertTo-SemanticJsonBytes -InputObject $Document))
}

$work = Join-Path ([IO.Path]::GetTempPath()) "ai-agent-dotfiles-home-authority-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($work) | Out-Null
try {
    if (Test-Section 'schema') {
        Write-Host '[home authority artifact contracts]'
        foreach ($relative in @(
            'scripts/home-authority-common.ps1',
            'scripts/live-target-context.ps1',
            'scripts/shared-authority-state-common.ps1',
            'schemas/root-claims.schema.json',
            'schemas/current-env-state.schema.json'
        )) {
            Assert-TestCondition (Test-Path -LiteralPath (Join-Path $RepoRoot $relative) -PathType Leaf) "Task 1 contract exists: $relative"
        }
        $contracts = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'schemas/artifact-contracts.psd1')
        Assert-TestCondition ($contracts.Contracts.ContainsKey('root-claims') -and [long]$contracts.Contracts['root-claims'].SchemaVersion -eq 1) 'registry includes root-claims v1'
        Assert-TestCondition ($contracts.Contracts.ContainsKey('current-env-state') -and [long]$contracts.Contracts['current-env-state'].SchemaVersion -eq 3) 'registry includes current-env-state v3'

        $claimsFixture = Join-Path $RepoRoot 'tests/fixtures/artifacts/root-claims.valid.json'
        $stateFixture = Join-Path $RepoRoot 'tests/fixtures/artifacts/current-env-state.valid.json'
        $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/root-claims.schema.json') -InstancePath $claimsFixture
        $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/current-env-state.schema.json') -InstancePath $stateFixture
        $claimsDocument = ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText($claimsFixture,[Text.UTF8Encoding]::new($false,$true)))
        $stateDocument = ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText($stateFixture,[Text.UTF8Encoding]::new($false,$true)))
        Test-RootClaimsSemantics -Document $claimsDocument
        Test-CurrentEnvStateSemantics -Document $stateDocument
        $claimsBytes = [IO.File]::ReadAllBytes($claimsFixture)
        Test-CurrentEnvStateAgainstRootClaims -StateDocument $stateDocument -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes
        Assert-TestCondition $true 'registered positive claims/state fixtures pass schema and semantic validation'

        $badClaimsHash = Copy-SemanticDocument -Document $stateDocument
        $badClaimsHash.RootClaimsHash = '0000000000000000000000000000000000000000000000000000000000000000'
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $badClaimsHash -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes } 'RootClaimsHash|exact' 'state binds the exact root-claims file bytes'

        $badPairAuthority = Copy-SemanticDocument -Document $stateDocument
        $badPairAuthority.HomeAuthorityKey = '0000000000000000000000000000000000000000000000000000000000000000'
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $badPairAuthority -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes } 'HomeAuthorityKey' 'state authority key must match immutable claims'

        $badPairLocation = Copy-SemanticDocument -Document $stateDocument
        $badPairLocation.FinalResolvedIdentities[2].LocationKey = 'c:/fixture/other/reasonix/skills'
        $badPairLocation.FinalResolvedIdentities[2].ResolvedPath = 'C:\fixture\other\reasonix\skills'
        $badPairLocation.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($badPairLocation.FinalResolvedIdentities)
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $badPairLocation -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes } 'root-claims|location' 'state final location must match its platform claim'

        $badPairVolume = Copy-SemanticDocument -Document $stateDocument
        foreach ($identity in @($badPairVolume.FinalResolvedIdentities)) {
            $identity.VolumeId = 'deadbeef'
            $identity.DirectoryIdentity = 'deadbeef' + ([string]$identity.DirectoryIdentity).Substring(8)
        }
        $badPairVolume.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($badPairVolume.FinalResolvedIdentities)
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $badPairVolume -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes } 'VolumeId' 'state final volume must match its platform claim'

        $badExistingIdentity = Copy-SemanticDocument -Document $stateDocument
        $badExistingIdentity.FinalResolvedIdentities[1].DirectoryIdentity = 'a1b2c3d4:0000000000000092'
        $badExistingIdentity.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($badExistingIdentity.FinalResolvedIdentities)
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $badExistingIdentity -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes } 'DirectoryIdentity|existing' 'an initially existing root preserves its immutable directory identity'

        $detachedClaimsObject = Copy-SemanticDocument -Document $claimsDocument
        $detachedClaimsObject.LiveRootClaims[2].LocationKey = 'c:/fixture/custom/reasonix/skills'
        $detachedClaimsObject.LiveRootClaims[2].RequestedPath = 'C:\fixture\custom\reasonix\skills'
        $detachedClaimsObject.LiveRootClaims[2].DeepestExistingParentPath = 'C:\fixture\custom'
        $detachedClaimsObject.LiveRootClaims[2].DeepestExistingParentIdentity = 'a1b2c3d4:0000000000000091'
        $detachedState = Copy-SemanticDocument -Document $stateDocument
        $detachedState.FinalResolvedIdentities[2].LocationKey = [string]$detachedClaimsObject.LiveRootClaims[2].LocationKey
        $detachedState.FinalResolvedIdentities[2].ResolvedPath = [string]$detachedClaimsObject.LiveRootClaims[2].RequestedPath
        $detachedState.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($detachedState.FinalResolvedIdentities)
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $detachedState -RootClaimsDocument $detachedClaimsObject -RootClaimsBytes $claimsBytes } 'bytes|document|object' 'pair validation proves the claims object was parsed from the exact hashed bytes'

        $absentIdentityAlias = Copy-SemanticDocument -Document $stateDocument
        $absentIdentityAlias.FinalResolvedIdentities[0].DirectoryIdentity = [string]$claimsDocument.LiveRootClaims[0].DeepestExistingParentIdentity
        $absentIdentityAlias.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($absentIdentityAlias.FinalResolvedIdentities)
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $absentIdentityAlias -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes } 'identity|parent|alias' 'an ABSENT root cannot resolve to its existing parent identity'

        $badParent = Copy-SemanticDocument -Document $claimsDocument
        $badParent.LiveRootClaims[0].DeepestExistingParentPath = 'C:\fixture\unrelated'
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $badParent } 'parent|remainder|reconstruct' 'ABSENT root claim must close over parent plus missing remainder'

        $badHomeLocation = Copy-SemanticDocument -Document $claimsDocument
        $badHomeLocation.HomeRootLocationKey = 'c:/fixture/other/../profile'
        $badHomeLocation.HomeAuthorityKey = Get-SemanticJsonHash -InputObject ([ordered]@{ Domain='ai-agent-dotfiles/home-authority/v1'; TokenSid=[string]$badHomeLocation.TokenSid; HomeRootLocationKey=[string]$badHomeLocation.HomeRootLocationKey })
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $badHomeLocation } 'canonical|segment|location' 'HomeRootLocationKey must be a canonical local location key'

        $noncanonicalSid = Copy-SemanticDocument -Document $claimsDocument
        $noncanonicalSid.TokenSid = 'S-01-05-021-01000'
        $noncanonicalSid.HomeAuthorityKey = Get-SemanticJsonHash -InputObject ([ordered]@{ Domain='ai-agent-dotfiles/home-authority/v1'; TokenSid=[string]$noncanonicalSid.TokenSid; HomeRootLocationKey=[string]$noncanonicalSid.HomeRootLocationKey })
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $noncanonicalSid } 'SID|canonical' 'root claims require canonical Windows SID spelling'

        $badVolumeFormat = Copy-SemanticDocument -Document $claimsDocument
        $badVolumeFormat.LiveRootClaims[0].VolumeId = ' A1B2C3D4 '
        $badVolumeFormatPath = Join-Path $work 'root-claims-bad-volume-format.json'
        Write-TestSemanticDocument -Path $badVolumeFormatPath -Document $badVolumeFormat
        Assert-ThrowsPattern { Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/root-claims.schema.json') -InstancePath $badVolumeFormatPath } 'schema|pattern|valid' 'root-claims schema rejects noncanonical VolumeId spelling'
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $badVolumeFormat } 'VolumeId|canonical' 'root-claims semantics reject noncanonical VolumeId spelling'

        $badIdentityFormat = Copy-SemanticDocument -Document $stateDocument
        $badIdentityFormat.FinalResolvedIdentities[0].DirectoryIdentity = 'A1B2C3D4:0000000000000011'
        $badIdentityFormat.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($badIdentityFormat.FinalResolvedIdentities)
        $badIdentityFormatPath = Join-Path $work 'current-env-state-bad-identity-format.json'
        Write-TestSemanticDocument -Path $badIdentityFormatPath -Document $badIdentityFormat
        Assert-ThrowsPattern { Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/current-env-state.schema.json') -InstancePath $badIdentityFormatPath } 'schema|pattern|valid' 'current-env-state schema rejects noncanonical DirectoryIdentity spelling'
        Assert-ThrowsPattern { Test-CurrentEnvStateSemantics -Document $badIdentityFormat } 'DirectoryIdentity|canonical' 'current-env-state semantics reject noncanonical DirectoryIdentity spelling'

        $badClaimIdentityPrefix = Copy-SemanticDocument -Document $claimsDocument
        $badClaimIdentityPrefix.LiveRootClaims[2].DeepestExistingParentIdentity = 'deadbeef:0000000000000003'
        $badClaimIdentityPrefixPath = Join-Path $work 'root-claims-bad-identity-prefix.json'
        Write-TestSemanticDocument -Path $badClaimIdentityPrefixPath -Document $badClaimIdentityPrefix
        $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/root-claims.schema.json') -InstancePath $badClaimIdentityPrefixPath
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $badClaimIdentityPrefix } 'identity|VolumeId|prefix' 'root-claims semantics bind each identity prefix to its VolumeId'

        $badStateIdentityPrefix = Copy-SemanticDocument -Document $stateDocument
        $badStateIdentityPrefix.FinalResolvedIdentities[2].DirectoryIdentity = 'deadbeef:0000000000000013'
        $badStateIdentityPrefix.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($badStateIdentityPrefix.FinalResolvedIdentities)
        $badStateIdentityPrefixPath = Join-Path $work 'current-env-state-bad-identity-prefix.json'
        Write-TestSemanticDocument -Path $badStateIdentityPrefixPath -Document $badStateIdentityPrefix
        $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/current-env-state.schema.json') -InstancePath $badStateIdentityPrefixPath
        Assert-ThrowsPattern { Test-CurrentEnvStateSemantics -Document $badStateIdentityPrefix } 'identity|VolumeId|prefix' 'current-env-state semantics bind each identity prefix to its VolumeId'

        $newlineClaims = Copy-SemanticDocument -Document $claimsDocument
        foreach ($claim in @($newlineClaims.LiveRootClaims)) {
            $claim.VolumeId = [string]$claim.VolumeId + [char]10
            $claim.DeepestExistingParentIdentity = [string]$claim.VolumeId + ([string]$claim.DeepestExistingParentIdentity).Substring(8)
            if ($null -ne $claim.InitialDirectoryIdentity) {
                $claim.InitialDirectoryIdentity = [string]$claim.VolumeId + ([string]$claim.InitialDirectoryIdentity).Substring(8)
            }
        }
        $newlineClaimsBytes = ConvertTo-SemanticJsonBytes -InputObject $newlineClaims
        $newlineClaimsDocument = ConvertFrom-SemanticJson -Json ([Text.Encoding]::UTF8.GetString($newlineClaimsBytes))
        $newlineClaimsPath = Join-Path $work 'root-claims-newline-identity.json'
        [IO.File]::WriteAllBytes($newlineClaimsPath,$newlineClaimsBytes)
        Assert-ThrowsPattern { Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/root-claims.schema.json') -InstancePath $newlineClaimsPath } 'schema|length|pattern|valid' 'root-claims schema rejects coordinated trailing-newline identity tuples'
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $newlineClaimsDocument } 'VolumeId|canonical' 'root-claims semantics reject coordinated trailing-newline identity tuples'

        $newlineState = Copy-SemanticDocument -Document $stateDocument
        foreach ($identity in @($newlineState.FinalResolvedIdentities)) {
            $identity.VolumeId = [string]$identity.VolumeId + [char]10
            $identity.DirectoryIdentity = [string]$identity.VolumeId + ([string]$identity.DirectoryIdentity).Substring(8)
        }
        $newlineState.RootClaimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($newlineClaimsBytes)).ToLowerInvariant()
        $newlineState.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($newlineState.FinalResolvedIdentities)
        $newlineStatePath = Join-Path $work 'current-env-state-newline-identity.json'
        Write-TestSemanticDocument -Path $newlineStatePath -Document $newlineState
        Assert-ThrowsPattern { Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/current-env-state.schema.json') -InstancePath $newlineStatePath } 'schema|length|pattern|valid' 'current-env-state schema rejects coordinated trailing-newline identity tuples'
        Assert-ThrowsPattern { Test-CurrentEnvStateSemantics -Document $newlineState } 'VolumeId|canonical' 'current-env-state semantics reject coordinated trailing-newline identity tuples'
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $newlineState -RootClaimsDocument $newlineClaimsDocument -RootClaimsBytes $newlineClaimsBytes } 'schema|validation|VolumeId|canonical' 'pair validation rejects coordinated trailing-newline identity tuples'

        $wrongKindClaims = Copy-SemanticDocument -Document $claimsDocument
        $wrongKindClaims.ArtifactKind = 'not-root-claims'
        $wrongKindClaimsBytes = ConvertTo-SemanticJsonBytes -InputObject $wrongKindClaims
        $wrongKindClaimsDocument = ConvertFrom-SemanticJson -Json ([Text.Encoding]::UTF8.GetString($wrongKindClaimsBytes))
        $wrongKindBoundState = Copy-SemanticDocument -Document $stateDocument
        $wrongKindBoundState.RootClaimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($wrongKindClaimsBytes)).ToLowerInvariant()
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $wrongKindBoundState -RootClaimsDocument $wrongKindClaimsDocument -RootClaimsBytes $wrongKindClaimsBytes } 'schema|validation' 'pair validation enforces the root-claims schema before supplemental semantics'

        $missingVersionState = Copy-SemanticDocument -Document $stateDocument
        $null = $missingVersionState.Remove('SchemaVersion')
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $missingVersionState -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes } 'schema|validation' 'pair validation enforces required current-env-state fields'

        $missingReceiptState = Copy-SemanticDocument -Document $stateDocument
        $null = $missingReceiptState.Remove('ReceiptId')
        $null = $missingReceiptState.Remove('ReceiptHash')
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $missingReceiptState -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes } 'schema|validation' 'pair validation enforces current-env-state receipt oneOf branches'

        $scalarSkillsState = Copy-SemanticDocument -Document $stateDocument
        $scalarSkillsState.TaskOverlaySkills[0].Skills = 'alpha'
        Assert-ThrowsPattern { Test-CurrentEnvStateAgainstRootClaims -StateDocument $scalarSkillsState -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes } 'schema|validation' 'pair validation rejects scalar values that imitate one-element arrays'

        $absentWithIdentity = Copy-SemanticDocument -Document $claimsDocument
        $absentWithIdentity.LiveRootClaims[0].InitialDirectoryIdentity = 'a1b2c3d4:0000000000000094'
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $absentWithIdentity } 'ABSENT|InitialDirectoryIdentity|null' 'root-claims semantics require a null initial identity for ABSENT roots'

        $badClaudeLocation = Copy-SemanticDocument -Document $claimsDocument
        $badClaudeLocation.LiveRootClaims[0].LocationKey = 'c:/fixture/profile/.claude-alt/skills'
        $badClaudeLocation.LiveRootClaims[0].RequestedPath = 'C:\fixture\profile\.claude-alt\skills'
        $badClaudeLocation.LiveRootClaims[0].MissingRemainder = @('.claude-alt','skills')
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $badClaudeLocation } 'Claude|fixed' 'Claude root claim is fixed under HomeRoot/.claude/skills'

        $badCodexLocation = Copy-SemanticDocument -Document $claimsDocument
        $badCodexLocation.LiveRootClaims[1].LocationKey = 'c:/fixture/profile/.codex-alt/skills'
        $badCodexLocation.LiveRootClaims[1].RequestedPath = 'C:\fixture\profile\.codex-alt\skills'
        $badCodexLocation.LiveRootClaims[1].DeepestExistingParentPath = 'C:\fixture\profile\.codex-alt\skills'
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $badCodexLocation } 'Codex|fixed' 'Codex root claim is limited to the preferred or fallback fixed path'

        $absentFallback = Copy-SemanticDocument -Document $claimsDocument
        $absentFallback.LiveRootClaims[1].LocationKey = 'c:/fixture/profile/.agents/skills'
        $absentFallback.LiveRootClaims[1].RequestedPath = 'C:\fixture\profile\.agents\skills'
        $absentFallback.LiveRootClaims[1].InitialState = 'ABSENT'
        $absentFallback.LiveRootClaims[1].DeepestExistingParentPath = 'C:\fixture\profile'
        $absentFallback.LiveRootClaims[1].DeepestExistingParentIdentity = 'a1b2c3d4:0000000000000001'
        $absentFallback.LiveRootClaims[1].MissingRemainder = @('.agents','skills')
        $absentFallback.LiveRootClaims[1].InitialDirectoryIdentity = $null
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $absentFallback } 'fallback|ABSENT|Codex' 'Codex fallback cannot be claimed absent because the resolver selects it only when present'

        $aliasedExistingIdentity = Copy-SemanticDocument -Document $claimsDocument
        $aliasedExistingIdentity.LiveRootClaims[2].DeepestExistingParentIdentity = [string]$aliasedExistingIdentity.LiveRootClaims[1].InitialDirectoryIdentity
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $aliasedExistingIdentity } 'identity|alias|overlap' 'an existing live-root identity cannot alias another claim parent'

        $conflictingParentIdentity = Copy-SemanticDocument -Document $claimsDocument
        $conflictingParentIdentity.LiveRootClaims[2].LocationKey = 'c:/fixture/profile/reasonix/skills'
        $conflictingParentIdentity.LiveRootClaims[2].RequestedPath = 'C:\fixture\profile\reasonix\skills'
        $conflictingParentIdentity.LiveRootClaims[2].DeepestExistingParentPath = 'C:\fixture\profile'
        $conflictingParentIdentity.LiveRootClaims[2].DeepestExistingParentIdentity = 'a1b2c3d4:0000000000000093'
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $conflictingParentIdentity } 'parent|identity|conflict' 'one canonical parent location cannot claim conflicting identities'

        $conflictingVolume = Copy-SemanticDocument -Document $claimsDocument
        $conflictingVolume.LiveRootClaims[2].VolumeId = 'deadbeef'
        $conflictingVolume.LiveRootClaims[2].DeepestExistingParentIdentity = 'deadbeef:0000000000000003'
        Assert-ThrowsPattern { Test-RootClaimsSemantics -Document $conflictingVolume } 'VolumeId|volume|drive' 'one local drive cannot claim conflicting volume identities'

        $badStatePath = Copy-SemanticDocument -Document $stateDocument
        $badStatePath.FinalResolvedIdentities[0].ResolvedPath = 'C:\fixture\profile\.claude\other'
        $badStatePath.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($badStatePath.FinalResolvedIdentities)
        Assert-ThrowsPattern { Test-CurrentEnvStateSemantics -Document $badStatePath } 'LocationKey|ResolvedPath' 'final resolved path must match its canonical location key'

        $duplicateIdentity = Copy-SemanticDocument -Document $stateDocument
        $duplicateIdentity.FinalResolvedIdentities[1].DirectoryIdentity = [string]$duplicateIdentity.FinalResolvedIdentities[0].DirectoryIdentity
        $duplicateIdentity.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($duplicateIdentity.FinalResolvedIdentities)
        Assert-ThrowsPattern { Test-CurrentEnvStateSemantics -Document $duplicateIdentity } 'identity|unique|duplicate' 'final directory identities must be unique across platforms'

        $overlappingState = Copy-SemanticDocument -Document $stateDocument
        $overlappingState.FinalResolvedIdentities[2].LocationKey = 'c:/fixture/profile/.claude/skills/reasonix'
        $overlappingState.FinalResolvedIdentities[2].ResolvedPath = 'C:\fixture\profile\.claude\skills\reasonix'
        $overlappingState.FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($overlappingState.FinalResolvedIdentities)
        Assert-ThrowsPattern { Test-CurrentEnvStateSemantics -Document $overlappingState } 'overlap' 'final platform root locations must be disjoint'

        $systemSkill = Copy-SemanticDocument -Document $stateDocument
        $systemSkill.TaskOverlaySkills[1].Skills = @('.system')
        Assert-ThrowsPattern { Test-CurrentEnvStateSemantics -Document $systemSkill } 'skill|system' 'TaskOverlaySkills rejects the protected .system name'

        $caseCollision = Copy-SemanticDocument -Document $stateDocument
        $caseCollision.TaskOverlaySkills[0].Skills = @('Alpha','alpha')
        Assert-ThrowsPattern { Test-CurrentEnvStateSemantics -Document $caseCollision } 'skill|collision|unique' 'TaskOverlaySkills rejects case-insensitive name collisions'

        foreach ($reservedSkill in @('CON','NUL.txt','COM1','alpha.',('a' * 256))) {
            $reservedState = Copy-SemanticDocument -Document $stateDocument
            $reservedState.TaskOverlaySkills[0].Skills = @($reservedSkill)
            Assert-ThrowsPattern { Test-CurrentEnvStateSemantics -Document $reservedState } 'skill|reserved|unsafe' "TaskOverlaySkills rejects Windows-unsafe name: $reservedSkill"
        }

        $stateSchema = Join-Path $RepoRoot 'schemas/current-env-state.schema.json'
        foreach ($operationKind in @('initial','environment','task-overlay','migrate','adopt','repair-adopt','retirement','environment-rollback')) {
            $candidate = Copy-SemanticDocument -Document $stateDocument
            $candidate.LastOperationKind = $operationKind
            $candidate.EnvironmentName = if ($operationKind -ceq 'initial') { 'full' } else { 'work' }
            $candidatePath = Join-Path $work ("state-$operationKind.json")
            Write-TestSemanticDocument -Path $candidatePath -Document $candidate
            $null = Invoke-FixedJsonSchemaValidation -SchemaPath $stateSchema -InstancePath $candidatePath
            Test-CurrentEnvStateSemantics -Document $candidate
        }
        $controller = Copy-SemanticDocument -Document $stateDocument
        $controller.LastOperationKind = 'controller-transition'
        $controller.Remove('ReceiptId')
        $controller.Remove('ReceiptHash')
        $controller['ReceiptRef'] = 'NO_LIVE_MUTATION'
        $controllerPath = Join-Path $work 'state-controller-transition.json'
        Write-TestSemanticDocument -Path $controllerPath -Document $controller
        $null = Invoke-FixedJsonSchemaValidation -SchemaPath $stateSchema -InstancePath $controllerPath
        Test-CurrentEnvStateSemantics -Document $controller
        Assert-TestCondition $true 'all eight receipt-bearing state branches and controller-transition validate'
    }

    if (Test-Section 'locking') {
        Write-Host '[CLR-held canonical/global lock-order binding]'
        Assert-TestCondition ($null -eq (Get-Variable -Name HomeAuthorityCanonicalGlobalLockBindings -Scope Script -ErrorAction SilentlyContinue)) 'dot-sourced home authority exports no script-scope canonical/global binding table'
        $homeTokens = $null; $homeErrors = $null
        $homeAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/home-authority-common.ps1'),[ref]$homeTokens,[ref]$homeErrors)
        $enterGlobalAst = @($homeAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Enter-HomeAuthorityGlobalLiveLock' },$true))[0]
        $enterGlobalText = [string]$enterGlobalAst.Extent.Text
        $sealedInputCapture = [regex]::Match($enterGlobalText,'Assert-HomeAuthorityRequiredCanonicalWitness\s+-CanonicalWitness\s+\$RequiredCanonicalWitness\s+-AuthorityContext\s+\$AuthorityContext')
        $globalAcquire = [regex]::Match($enterGlobalText,'\$lock\s*=\s*Enter-HomeAuthorityLockFileCore')
        $postCaptureCheck = [regex]::Match($enterGlobalText,'Assert-HomeAuthorityCanonicalGlobalAcquisitionCaptureCurrent')
        $exactBind = [regex]::Match($enterGlobalText,'SafeLockOrderBinding\]::BindExact\([^\r\n]+\$acquisitionCapture,\$acquisitionCapture')
        Assert-TestCondition ($homeErrors.Count -eq 0 -and $sealedInputCapture.Success -and $globalAcquire.Success -and $postCaptureCheck.Success -and $exactBind.Success -and
            $sealedInputCapture.Index -lt $globalAcquire.Index -and $globalAcquire.Index -lt $postCaptureCheck.Index -and $postCaptureCheck.Index -lt $exactBind.Index) 'one sealed witness/context capture is acquired before the global lock, revalidated afterward, and passed intact to exact CLR bind'

        function New-TestHomeAuthorityBindingWitness {
            param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)]$CanonicalLockHandle)
            $owner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($CanonicalLockHandle)
            if ($owner -isnot [AiAgentDotfiles.SafeLockResourceOwner]) { throw 'test canonical owner is missing' }
            $projection = [ordered]@{
                ResolverVersion = 'home-authority-binding-test-witness-v1'
                RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
                CanonicalLockPath = [AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($owner)
                CanonicalLockIdentity = [AiAgentDotfiles.SafeLockResourceOwner]::GetAcquiredIdentityExact($owner)
                CanonicalLockOrdinal = [long][AiAgentDotfiles.SafeLockResourceOwner]::GetAcquisitionOrdinalExact($owner)
            }
            $value = [pscustomobject][ordered]@{
                ResolverVersion = 'home-authority-binding-test-witness-v1'
                RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
                CanonicalLockHandle = $CanonicalLockHandle
                WitnessHash = Get-SemanticJsonHash -InputObject $projection
            }
            $value.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalNamespaceWitness')
            return $value
        }

        $canonicalProofRoot = Join-Path $work 'canonical-private-proof'
        [IO.Directory]::CreateDirectory($canonicalProofRoot) | Out-Null
        $canonicalProof = $null
        $foreignProof = $null
        $originalDisplay = $null
        try {
            $canonicalProof = Enter-CanonicalRepoLock -LockPath (Join-Path $canonicalProofRoot 'canonical.lock') -AllowCreate
            $foreignProof = Enter-CanonicalRepoLock -LockPath (Join-Path $canonicalProofRoot 'foreign.lock') -AllowCreate
            $originalDisplay = [ordered]@{
                Path = $canonicalProof.Path
                Stream = $canonicalProof.Stream
                Info = $canonicalProof.Info
                HeldLock = $canonicalProof.HeldLock
                ParentHandles = $canonicalProof.ParentHandles
                SecuritySddl = $canonicalProof.SecuritySddl
                SecurityHash = $canonicalProof.SecurityHash
            }
            foreach ($name in @('Path','Stream','Info','HeldLock','ParentHandles','SecuritySddl','SecurityHash')) {
                $canonicalProof.$name = $foreignProof.$name
            }
            Assert-ThrowsPattern {
                Assert-CanonicalRepoLockHandle -LockHandle $canonicalProof -ExpectedLockPath ([string]$foreignProof.Path) | Out-Null
            } '^canonical-witness-required$' 'a genuine handle for another file cannot replace the canonical wrapper acquisition proof'
            foreach ($name in $originalDisplay.Keys) { $canonicalProof.$name = $originalDisplay[$name] }
        }
        finally {
            if ($null -ne $foreignProof) { Exit-CanonicalRepoLock -LockHandle $foreignProof }
            if ($null -ne $canonicalProof) {
                if ($null -ne $originalDisplay) { foreach ($name in $originalDisplay.Keys) { $canonicalProof.$name = $originalDisplay[$name] } }
                Exit-CanonicalRepoLock -LockHandle $canonicalProof
            }
        }

        $canonicalExit = $null
        $canonicalExitSubstitute = $null
        try {
            $canonicalExit = Enter-CanonicalRepoLock -LockPath (Join-Path $canonicalProofRoot 'canonical-exit.lock') -AllowCreate
            $canonicalExitSubstitute = Enter-CanonicalRepoLock -LockPath (Join-Path $canonicalProofRoot 'canonical-exit-substitute.lock') -AllowCreate
            $canonicalExitOwner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($canonicalExit)
            $canonicalExitActualHeld = [AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($canonicalExitOwner)
            $canonicalExitActualParents = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($canonicalExitOwner))
            $canonicalExitSubstituteOwner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($canonicalExitSubstitute)
            $script:CanonicalExitActualHeldForTest = $canonicalExitActualHeld
            $script:CanonicalExitActualParentsForTest = $canonicalExitActualParents
            $script:CanonicalExitActualInfoForTest = [AiAgentDotfiles.SafeLockResourceOwner]::GetInfoExact($canonicalExitOwner)
            $script:CanonicalExitActualStreamForTest = [AiAgentDotfiles.SafeLockResourceOwner]::GetStreamViewExact($canonicalExitOwner)
            $script:CanonicalExitSubstituteHeldForTest = [AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($canonicalExitSubstituteOwner)
            $script:CanonicalExitSubstituteParentsForTest = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($canonicalExitSubstituteOwner))
            $script:CanonicalExitSubstituteInfoForTest = [AiAgentDotfiles.SafeLockResourceOwner]::GetInfoExact($canonicalExitSubstituteOwner)
            $script:CanonicalExitSubstituteStreamForTest = [AiAgentDotfiles.SafeLockResourceOwner]::GetStreamViewExact($canonicalExitSubstituteOwner)
            $script:CanonicalExitHeldReadCountForTest = 0
            $script:CanonicalExitParentReadCountForTest = 0
            $script:CanonicalExitInfoReadCountForTest = 0
            $script:CanonicalExitStreamReadCountForTest = 0
            $canonicalExit.PSObject.Properties.Remove('HeldLock')
            $canonicalExit.PSObject.Properties.Remove('ParentHandles')
            $canonicalExit.PSObject.Properties.Remove('Info')
            $canonicalExit.PSObject.Properties.Remove('Stream')
            $canonicalExit | Add-Member -MemberType ScriptProperty -Name HeldLock -Value {
                $script:CanonicalExitHeldReadCountForTest++
                if (($script:CanonicalExitHeldReadCountForTest % 2) -eq 1) { return $script:CanonicalExitSubstituteHeldForTest }
                return $script:CanonicalExitActualHeldForTest
            }
            $canonicalExit | Add-Member -MemberType ScriptProperty -Name ParentHandles -Value {
                $script:CanonicalExitParentReadCountForTest++
                if (($script:CanonicalExitParentReadCountForTest % 2) -eq 1) { return $script:CanonicalExitSubstituteParentsForTest }
                return $script:CanonicalExitActualParentsForTest
            }
            $canonicalExit | Add-Member -MemberType ScriptProperty -Name Info -Value {
                $script:CanonicalExitInfoReadCountForTest++
                if (($script:CanonicalExitInfoReadCountForTest % 2) -eq 1) { return $script:CanonicalExitSubstituteInfoForTest }
                return $script:CanonicalExitActualInfoForTest
            }
            $canonicalExit | Add-Member -MemberType ScriptProperty -Name Stream -Value {
                $script:CanonicalExitStreamReadCountForTest++
                if (($script:CanonicalExitStreamReadCountForTest % 2) -eq 1) { return $script:CanonicalExitSubstituteStreamForTest }
                return $script:CanonicalExitActualStreamForTest
            }
            Assert-ThrowsPattern { Exit-CanonicalRepoLock -LockHandle $canonicalExit } '^canonical-witness-required$' 'stateful canonical HeldLock, ParentHandles, Info, and Stream substitution is reported after owner-based release'
            Assert-TestCondition (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($canonicalExitActualHeld) -and
                @($canonicalExitActualParents | Where-Object { [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_) }).Count -eq 0) 'canonical Exit releases the privately owned lock and complete parent chain'
            Assert-TestCondition ([AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($script:CanonicalExitSubstituteHeldForTest) -and
                @($script:CanonicalExitSubstituteParentsForTest | Where-Object { -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_) }).Count -eq 0) 'canonical Exit never releases stateful HeldLock or ParentHandles substitutes'
            $canonicalExit = $null
        }
        finally {
            foreach ($name in @('CanonicalExitActualHeldForTest','CanonicalExitActualParentsForTest','CanonicalExitActualInfoForTest','CanonicalExitActualStreamForTest','CanonicalExitSubstituteHeldForTest','CanonicalExitSubstituteParentsForTest','CanonicalExitSubstituteInfoForTest','CanonicalExitSubstituteStreamForTest','CanonicalExitHeldReadCountForTest','CanonicalExitParentReadCountForTest','CanonicalExitInfoReadCountForTest','CanonicalExitStreamReadCountForTest')) {
                Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
            }
            if ($null -ne $canonicalExit -and $null -ne ([AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($canonicalExit))) { try { Exit-CanonicalRepoLock -LockHandle $canonicalExit } catch {} }
            if ($null -ne $canonicalExitSubstitute) { Exit-CanonicalRepoLock -LockHandle $canonicalExitSubstitute }
        }

        $lowRoot = Join-Path $work 'low-level-lock-order'
        [IO.Directory]::CreateDirectory($lowRoot) | Out-Null
        $lowParents = Open-SafeDirectoryContainmentChain -Path $lowRoot
        $firstLock = $null
        $secondLock = $null
        $thirdLock = $null
        try {
            $lowParent = $lowParents[$lowParents.Count - 1]
            $firstLock = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lowParent,'first.lock')
            $view = [AiAgentDotfiles.SafeLockFileHandle]::GetStreamViewExact($firstLock)
            $view.Dispose()
            Assert-TestCondition ([AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($firstLock)) 'disposing the public stream view does not dispose the owning lock handle'
            Assert-ThrowsPattern { [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lowParent,'first.lock') | Out-Null } '.' 'disposing the public stream view does not release the native lock'

            $secondLock = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lowParent,'second.lock')
            Assert-ThrowsPattern {
                [AiAgentDotfiles.SafeLockOrderBinding]::BindExact($firstLock,$secondLock,$lowParent,[pscustomobject]@{},[pscustomobject]@{},[pscustomobject]@{},('d' * 64)) | Out-Null
            } 'prerequisite|order' 'a later prerequisite cannot forge a reverse acquisition order'

            $thirdLock = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lowParent,'third.lock')
            $secondWrapper = [pscustomobject]@{ Name='second' }
            $thirdWrapper = [pscustomobject]@{ Name='third' }
            $secondBinding = [AiAgentDotfiles.SafeLockOrderBinding]::BindExact($secondLock,$firstLock,$lowParent,[pscustomobject]@{},[pscustomobject]@{},$secondWrapper,('e' * 64))
            $thirdBinding = [AiAgentDotfiles.SafeLockOrderBinding]::BindExact($thirdLock,$secondLock,$lowParent,[pscustomobject]@{},[pscustomobject]@{},$thirdWrapper,('f' * 64))
            Assert-ThrowsPattern { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($secondLock) } 'dependent-lock-active' 'a middle lock cannot release while a third ordered lock still depends on it'
            Assert-TestCondition ([AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($firstLock) -and
                [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($secondLock) -and
                [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($thirdLock) -and
                [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($secondWrapper),$secondBinding) -and
                [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($thirdWrapper),$thirdBinding)) 'failed middle release preserves the entire three-lock chain and both private bindings'
            Assert-TestCondition ([AiAgentDotfiles.SafeLockOrderBinding]::ReleaseExact($thirdBinding)) 'third lock releases while its middle prerequisite remains open'
            Assert-TestCondition (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($thirdLock) -and
                $null -eq [AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($thirdWrapper) -and
                [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($secondLock)) 'third release detaches only the tail dependency'
            Assert-TestCondition ([AiAgentDotfiles.SafeLockOrderBinding]::ReleaseExact($secondBinding)) 'middle lock retry succeeds only after the tail dependency is released'
            Assert-TestCondition (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($secondLock) -and
                [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($firstLock) -and
                $null -eq [AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($secondWrapper)) 'middle retry detaches from the first lock without releasing its prerequisite'
            [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($firstLock)
            Assert-TestCondition (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($firstLock)) 'three-lock chain releases strictly tail to head'
            $thirdLock = $null; $secondLock = $null; $firstLock = $null
        }
        finally {
            [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($thirdLock)
            [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($secondLock)
            [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($firstLock)
            Close-SafeDirectoryContainmentChain -Handles $lowParents
        }

        $bindingRoot = Join-Path $work 'bound-lock-order'
        $bindingProfile = Join-Path $bindingRoot 'profile'
        $bindingRoaming = Join-Path $bindingRoot 'roaming'
        $bindingLocal = Join-Path $bindingRoot 'local'
        foreach ($path in @($bindingRoot,$bindingProfile,$bindingRoaming,$bindingLocal)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
        $bindingSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $bindingContext = Resolve-SealedHomeAuthorityTestContext -TokenSid $bindingSid -ProfileRoot $bindingProfile -RoamingAppDataRoot $bindingRoaming -LocalAppDataRoot $bindingLocal
        $bindingIntent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $bindingContext -FilesystemCapabilityHash ('e' * 64)
        $bootstrapGlobal = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $bindingContext -Intent $bindingIntent
        Exit-HomeAuthorityGlobalLiveLock -LockHandle $bootstrapGlobal

        $unboundHomeLock = $null
        $homeExitSubstituteParents = $null
        $homeExitSubstituteHeld = $null
        try {
            $unboundHomeLock = Enter-SealedHomeAuthorityBootstrapLock -AuthorityContext $bindingContext -Intent $bindingIntent
            $unboundHomeOwner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($unboundHomeLock)
            $unboundHomeActualHeld = [AiAgentDotfiles.SafeLockResourceOwner]::GetHeldLockExact($unboundHomeOwner)
            $unboundHomeActualParents = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($unboundHomeOwner))
            $homeExitSubstituteRoot = Join-Path $bindingRoot 'home-exit-substitute'
            [IO.Directory]::CreateDirectory($homeExitSubstituteRoot) | Out-Null
            $homeExitSubstituteParents = Open-SafeDirectoryContainmentChain -Path $homeExitSubstituteRoot
            $homeExitSubstituteHeld = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($homeExitSubstituteParents[$homeExitSubstituteParents.Count - 1],'substitute.lock')
            $script:HomeExitActualHeldForTest = $unboundHomeActualHeld
            $script:HomeExitActualParentsForTest = $unboundHomeActualParents
            $script:HomeExitSubstituteHeldForTest = $homeExitSubstituteHeld
            $script:HomeExitSubstituteParentsForTest = @($homeExitSubstituteParents)
            $script:HomeExitHeldReadCountForTest = 0
            $script:HomeExitParentReadCountForTest = 0
            $unboundHomeLock.PSObject.Properties.Remove('HeldLock')
            $unboundHomeLock.PSObject.Properties.Remove('ParentHandles')
            $unboundHomeLock | Add-Member -MemberType ScriptProperty -Name HeldLock -Value {
                $script:HomeExitHeldReadCountForTest++
                if (($script:HomeExitHeldReadCountForTest % 2) -eq 1) { return $script:HomeExitSubstituteHeldForTest }
                return $script:HomeExitActualHeldForTest
            }
            $unboundHomeLock | Add-Member -MemberType ScriptProperty -Name ParentHandles -Value {
                $script:HomeExitParentReadCountForTest++
                if (($script:HomeExitParentReadCountForTest % 2) -eq 1) { return $script:HomeExitSubstituteParentsForTest }
                return $script:HomeExitActualParentsForTest
            }
            Assert-ThrowsPattern { Exit-HomeAuthorityLockHandle -LockHandle $unboundHomeLock } '^home-authority-lock-owner-required$' 'stateful unbound home wrapper substitution is reported after owner-based release'
            Assert-TestCondition (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($unboundHomeActualHeld) -and
                @($unboundHomeActualParents | Where-Object { [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_) }).Count -eq 0) 'unbound home Exit releases the privately owned lock and complete parent chain'
            Assert-TestCondition ([AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($homeExitSubstituteHeld) -and
                @($homeExitSubstituteParents | Where-Object { -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_) }).Count -eq 0) 'unbound home Exit never releases stateful HeldLock or ParentHandles substitutes'
            $unboundHomeLock = $null
        }
        finally {
            foreach ($name in @('HomeExitActualHeldForTest','HomeExitActualParentsForTest','HomeExitSubstituteHeldForTest','HomeExitSubstituteParentsForTest','HomeExitHeldReadCountForTest','HomeExitParentReadCountForTest')) {
                Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
            }
            if ($null -ne $unboundHomeLock -and $null -ne ([AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($unboundHomeLock))) { try { Exit-HomeAuthorityLockHandle -LockHandle $unboundHomeLock } catch {} }
            if ($null -ne $homeExitSubstituteHeld) { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($homeExitSubstituteHeld) }
            if ($null -ne $homeExitSubstituteParents) { Close-SafeDirectoryContainmentChain -Handles $homeExitSubstituteParents }
        }

        $canonicalRoot = Join-Path $bindingRoot 'canonical-locks'
        [IO.Directory]::CreateDirectory($canonicalRoot) | Out-Null
        $savedCanonicalValidator = Get-Command Assert-CanonicalHeldNamespaceWitness -CommandType Function -ErrorAction SilentlyContinue
        $savedCanonicalValidatorBlock = if ($null -eq $savedCanonicalValidator) { $null } else { $savedCanonicalValidator.ScriptBlock }
        Set-Item -LiteralPath Function:\Assert-CanonicalHeldNamespaceWitness -Value {
            param([Parameter(Mandatory)]$Witness,[Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)]$CanonicalLockHandle)
            $canonicalOwner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($CanonicalLockHandle)
            if (-not [object]::ReferenceEquals($Witness.CanonicalLockHandle,$CanonicalLockHandle) -or
                [string]$Witness.RepoRoot -cne [IO.Path]::GetFullPath($RepoRoot) -or
                $canonicalOwner -isnot [AiAgentDotfiles.SafeLockResourceOwner]) {
                throw 'canonical-witness-required'
            }
            $null = Assert-CanonicalRepoLockHandle -LockHandle $CanonicalLockHandle -ExpectedLockPath ([AiAgentDotfiles.SafeLockResourceOwner]::GetPathExact($canonicalOwner))
            return $true
        }

        try {
            $canonicalParents = Open-SafeDirectoryContainmentChain -Path $canonicalRoot
            $canonicalHeld = $null
            $canonicalWrapper = $null
            $foreignCanonicalParents = $null
            $foreignCanonicalHeld = $null
            $foreignCanonicalWrapper = $null
            $boundGlobal = $null
            try {
                $canonicalHeld = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($canonicalParents[$canonicalParents.Count - 1],'canonical-a.lock')
                $canonicalSecurity = Get-CanonicalRepoLockSecurityEvidence -HeldLock $canonicalHeld
                $canonicalSecurityHash = Get-SemanticJsonHash -InputObject $canonicalSecurity
                $canonicalWrapper = [pscustomobject][ordered]@{
                    Path = [IO.Path]::GetFullPath((Join-Path $canonicalRoot 'canonical-a.lock'))
                    Stream = [AiAgentDotfiles.SafeLockFileHandle]::GetStreamViewExact($canonicalHeld)
                    Info = [AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($canonicalHeld)
                    HeldLock = $canonicalHeld
                    ParentHandles = $canonicalParents
                    SecuritySddl = [string]$canonicalSecurity.Sddl
                    SecurityHash = $canonicalSecurityHash
                }
                $canonicalWrapper.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalRepoLockHandle')
                $null = Register-CanonicalRepoLockResourceOwner -LockHandle $canonicalWrapper -HeldLock $canonicalHeld -ParentHandles @($canonicalParents) -Path ([string]$canonicalWrapper.Path) -SecuritySddl ([string]$canonicalSecurity.Sddl) -SecurityHash $canonicalSecurityHash
                $witness = New-TestHomeAuthorityBindingWitness -RepoRoot $canonicalRoot -CanonicalLockHandle $canonicalWrapper

                $script:StatefulCanonicalHandleForTest = $canonicalWrapper
                $witness.PSObject.Properties.Remove('CanonicalLockHandle')
                $witness | Add-Member -MemberType ScriptProperty -Name CanonicalLockHandle -Value { return $script:StatefulCanonicalHandleForTest }
                Assert-ThrowsPattern {
                    $unexpected = $null
                    try { $unexpected = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $bindingContext -RequiredCanonicalWitness $witness }
                    finally { if ($null -ne $unexpected) { Exit-HomeAuthorityGlobalLiveLock -LockHandle $unexpected } }
                } '^canonical-witness-required$' 'stateful canonical-witness getters are rejected before global acquisition'
                $witness.PSObject.Properties.Remove('CanonicalLockHandle')
                $witness | Add-Member -NotePropertyName CanonicalLockHandle -NotePropertyValue $canonicalWrapper
                Remove-Variable -Name StatefulCanonicalHandleForTest -Scope Script -ErrorAction SilentlyContinue

                $statefulContext = [pscustomobject](Copy-SemanticDocument -Document $bindingContext)
                $script:StatefulGlobalPathForTest = [string]$bindingContext.GlobalLiveLockPath
                $statefulContext.PSObject.Properties.Remove('GlobalLiveLockPath')
                $statefulContext | Add-Member -MemberType ScriptProperty -Name GlobalLiveLockPath -Value { return $script:StatefulGlobalPathForTest }
                Assert-ThrowsPattern {
                    $unexpected = $null
                    try { $unexpected = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $statefulContext -RequiredCanonicalWitness $witness }
                    finally { if ($null -ne $unexpected) { Exit-HomeAuthorityGlobalLiveLock -LockHandle $unexpected } }
                } '^canonical-witness-required$' 'stateful authority-context getters are rejected instead of being reread across acquisition'
                Remove-Variable -Name StatefulGlobalPathForTest -Scope Script -ErrorAction SilentlyContinue

                $foreignCanonicalParents = Open-SafeDirectoryContainmentChain -Path $canonicalRoot
                $foreignCanonicalHeld = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($foreignCanonicalParents[$foreignCanonicalParents.Count - 1],'canonical-foreign.lock')
                $foreignSecurity = Get-CanonicalRepoLockSecurityEvidence -HeldLock $foreignCanonicalHeld
                $foreignSecurityHash = Get-SemanticJsonHash -InputObject $foreignSecurity
                $foreignCanonicalWrapper = [pscustomobject][ordered]@{
                    Path = [IO.Path]::GetFullPath((Join-Path $canonicalRoot 'canonical-foreign.lock'))
                    Stream = [AiAgentDotfiles.SafeLockFileHandle]::GetStreamViewExact($foreignCanonicalHeld)
                    Info = [AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($foreignCanonicalHeld)
                    HeldLock = $foreignCanonicalHeld
                    ParentHandles = $foreignCanonicalParents
                    SecuritySddl = [string]$foreignSecurity.Sddl
                    SecurityHash = $foreignSecurityHash
                }
                $foreignCanonicalWrapper.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalRepoLockHandle')
                $null = Register-CanonicalRepoLockResourceOwner -LockHandle $foreignCanonicalWrapper -HeldLock $foreignCanonicalHeld -ParentHandles @($foreignCanonicalParents) -Path ([string]$foreignCanonicalWrapper.Path) -SecuritySddl ([string]$foreignSecurity.Sddl) -SecurityHash $foreignSecurityHash
                $witness.CanonicalLockHandle = $foreignCanonicalWrapper
                Assert-ThrowsPattern {
                    $unexpected = $null
                    try { $unexpected = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $bindingContext -RequiredCanonicalWitness $witness }
                    finally { if ($null -ne $unexpected) { Exit-HomeAuthorityGlobalLiveLock -LockHandle $unexpected } }
                } '^canonical-witness-required$' 'a genuine foreign canonical owner cannot replace the owner sealed into the witness semantic hash'
                $witness.CanonicalLockHandle = $canonicalWrapper

                $boundGlobal = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $bindingContext -RequiredCanonicalWitness $witness
                $actualGlobalHeld = [AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentExact([AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($boundGlobal))
                Assert-TestCondition ($actualGlobalHeld -is [AiAgentDotfiles.SafeLockFileHandle]) 'bound wrapper resolves its actual global handle only through the private CLR registry'
                Assert-TestCondition (Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness) 'canonical-before-global acquisition produces one valid immutable binding'

                $witness.CanonicalLockHandle = $foreignCanonicalWrapper
                Assert-ThrowsPattern { Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness | Out-Null } '^canonical-witness-required$' 'post-bind exchange with a still-live genuine foreign canonical owner fails closed'
                Assert-TestCondition ([AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($canonicalHeld) -and
                    [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($foreignCanonicalHeld) -and
                    [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($actualGlobalHeld)) 'foreign-owner rejection preserves the sealed canonical/global pair and does not release the substitute'
                $witness.CanonicalLockHandle = $canonicalWrapper

                $originalAuthorityKey = [string]$bindingContext.HomeAuthorityKey
                $bindingContext.HomeAuthorityKey = '0' * 64
                Assert-ThrowsPattern { Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness | Out-Null } '^canonical-witness-required$' 'post-bind authority semantic drift cannot alter the acquisition-time snapshot'
                $bindingContext.HomeAuthorityKey = $originalAuthorityKey
                Assert-TestCondition (Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness) 'restoring caller display values leaves the private acquisition capture bound to its original exact resources'

                Exit-CanonicalRepoLock -LockHandle $foreignCanonicalWrapper
                $foreignCanonicalWrapper = $null; $foreignCanonicalHeld = $null; $foreignCanonicalParents = $null
                Assert-ThrowsPattern { [AiAgentDotfiles.SafeLockOrderBinding]::BindExact($actualGlobalHeld,$canonicalHeld,$canonicalParents[$canonicalParents.Count-1],$witness,$bindingContext,$boundGlobal,('f' * 64)) | Out-Null } 'already has|dependent' 'a global handle cannot be bound twice'

                $detachedContext = Copy-SemanticDocument -Document $bindingContext
                Assert-ThrowsPattern { Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $detachedContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness | Out-Null } '^canonical-witness-required$' 'equal-value detached authority context cannot replace the exact bound object'

                $originalPath = $boundGlobal.Path
                $boundGlobal.Path = Join-Path $bindingContext.ControlBase 'forged.lock'
                Assert-ThrowsPattern { Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness | Out-Null } '^canonical-witness-required$' 'mutable global path substitution fails closed'
                $boundGlobal.Path = $originalPath

                $originalInfo = $boundGlobal.Info
                $boundGlobal.Info = [AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($canonicalHeld)
                Assert-ThrowsPattern { Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness | Out-Null } '^canonical-witness-required$' 'mutable global identity display substitution fails closed'
                $boundGlobal.Info = $originalInfo

                $originalParents = $boundGlobal.ParentHandles
                $boundGlobal.ParentHandles = $canonicalParents
                Assert-ThrowsPattern { Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness | Out-Null } '^canonical-witness-required$' 'mutable global parent-handle substitution fails closed'
                $boundGlobal.ParentHandles = $originalParents

                $originalSecurityHash = $boundGlobal.SecurityHash
                $boundGlobal.SecurityHash = '0' * 64
                Assert-ThrowsPattern { Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness | Out-Null } '^canonical-witness-required$' 'mutable global security evidence substitution fails closed'
                $boundGlobal.SecurityHash = $originalSecurityHash

                $binding = [AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($boundGlobal)
                $actualCapture = [AiAgentDotfiles.SafeLockOrderBinding]::GetPrerequisiteWitnessExact($binding)
                $boundGlobal.HeldLock | Add-Member -NotePropertyName OrderBinding -NotePropertyValue $null -Force
                $binding | Add-Member -NotePropertyName AuthorityContext -NotePropertyValue ([pscustomobject]@{Forged=$true}) -Force
                $binding | Add-Member -NotePropertyName PrerequisiteWitness -NotePropertyValue ([pscustomobject]@{Forged=$true}) -Force
                $binding | Add-Member -MemberType ScriptMethod -Name Matches -Value { return $true } -Force
                $binding | Add-Member -MemberType ScriptMethod -Name ReleaseCurrentAndReportPrerequisiteOpen -Value { return $true } -Force
                Assert-TestCondition ($actualCapture -is [AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture] -and
                    [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetAuthorityContextExact($binding),$actualCapture) -and
                    [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetPrerequisiteWitnessExact($binding),$actualCapture) -and
                    [object]::ReferenceEquals([AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetAuthoritySourceExact($actualCapture),$bindingContext) -and
                    [object]::ReferenceEquals([AiAgentDotfiles.HomeAuthorityCanonicalGlobalAcquisitionCapture]::GetWitnessSourceExact($actualCapture),$witness)) 'static CLR access ignores ETS-shadowed binding properties and retains exact acquisition sources only inside the sealed capture'
                Assert-TestCondition (Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness) 'ETS-shadowed instance properties and methods cannot bypass or disable exact CLR validation'

                Assert-ThrowsPattern { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($canonicalHeld) } 'dependent-lock-active' 'canonical release is rejected while its dependent global lock remains open'
                Assert-TestCondition ([AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($canonicalHeld) -and [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($actualGlobalHeld)) 'rejected reverse release keeps both ordered locks open'

                $tailParents = Open-SafeDirectoryContainmentChain -Path $canonicalRoot
                $tailHeld = $null
                $tailBinding = $null
                try {
                    $tailHeld = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($tailParents[$tailParents.Count - 1],'global-tail.lock')
                    $tailWrapper = [pscustomobject]@{ Name='global-tail' }
                    $tailBinding = [AiAgentDotfiles.SafeLockOrderBinding]::BindExact($tailHeld,$actualGlobalHeld,$tailParents[$tailParents.Count - 1],[pscustomobject]@{},[pscustomobject]@{},$tailWrapper,('9' * 64))
                    Assert-ThrowsPattern { Exit-HomeAuthorityGlobalLiveLock -LockHandle $boundGlobal } 'dependent-lock-active' 'home global exit cannot release a middle lock while an ordered tail remains open'
                    Assert-TestCondition ([AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($canonicalHeld) -and
                        [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($actualGlobalHeld) -and
                        [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($tailHeld) -and
                        $null -ne [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($boundGlobal) -and
                        [object]::ReferenceEquals([AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($boundGlobal),$binding)) 'failed home exit preserves the exact canonical/global/tail chain and retryable global resource owner'
                    Assert-TestCondition ([AiAgentDotfiles.SafeLockOrderBinding]::ReleaseExact($tailBinding)) 'ordered tail releases while the global prerequisite remains open'
                    $tailBinding = $null; $tailHeld = $null
                    Assert-TestCondition (Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $bindingContext -GlobalLockHandle $boundGlobal -CanonicalWitness $witness) 'global binding remains valid after the tail detaches'
                }
                finally {
                    if ($null -ne $tailBinding) { try { $null = [AiAgentDotfiles.SafeLockOrderBinding]::ReleaseExact($tailBinding) } catch {} }
                    elseif ($null -ne $tailHeld) { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($tailHeld) }
                    Close-SafeDirectoryContainmentChain -Handles $tailParents
                }
                $releasedWrapper = $boundGlobal
                Exit-HomeAuthorityGlobalLiveLock -LockHandle $boundGlobal
                $boundGlobal = $null
                Assert-TestCondition (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($actualGlobalHeld) -and $null -eq [AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($releasedWrapper)) 'global exit releases the actual CLR handle and unregisters its wrapper binding'
                Exit-CanonicalRepoLock -LockHandle $canonicalWrapper
                Assert-TestCondition (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($canonicalHeld)) 'canonical release succeeds after global release detaches the dependency'
                $canonicalHeld = $null
            }
            finally {
                Remove-Variable -Name StatefulCanonicalHandleForTest -Scope Script -ErrorAction SilentlyContinue
                Remove-Variable -Name StatefulGlobalPathForTest -Scope Script -ErrorAction SilentlyContinue
                if ($null -ne $boundGlobal) { Exit-HomeAuthorityGlobalLiveLock -LockHandle $boundGlobal }
                if ($null -ne $foreignCanonicalWrapper -and $null -ne ([AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($foreignCanonicalWrapper))) { Exit-CanonicalRepoLock -LockHandle $foreignCanonicalWrapper }
                else {
                    if ($null -ne $foreignCanonicalHeld) { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($foreignCanonicalHeld) }
                    if ($null -ne $foreignCanonicalParents) { Close-SafeDirectoryContainmentChain -Handles $foreignCanonicalParents }
                }
                if ($null -ne $canonicalWrapper -and $null -ne ([AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($canonicalWrapper))) {
                    Exit-CanonicalRepoLock -LockHandle $canonicalWrapper
                }
                else {
                    if ($null -ne $canonicalHeld) { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($canonicalHeld) }
                    Close-SafeDirectoryContainmentChain -Handles $canonicalParents
                }
            }

            $swapCanonicalParents = Open-SafeDirectoryContainmentChain -Path $canonicalRoot
            $swapCanonicalHeld = $null
            $swapWrapper = $null
            $replacementHeld = $null
            $swappedGlobal = $null
            try {
                $swapCanonicalHeld = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($swapCanonicalParents[$swapCanonicalParents.Count - 1],'canonical-b.lock')
                $swapSecurity = Get-CanonicalRepoLockSecurityEvidence -HeldLock $swapCanonicalHeld
                $swapSecurityHash = Get-SemanticJsonHash -InputObject $swapSecurity
                $swapWrapper = [pscustomobject][ordered]@{ Path=[IO.Path]::GetFullPath((Join-Path $canonicalRoot 'canonical-b.lock')); Stream=[AiAgentDotfiles.SafeLockFileHandle]::GetStreamViewExact($swapCanonicalHeld); Info=[AiAgentDotfiles.SafeLockFileHandle]::GetInfoExact($swapCanonicalHeld); HeldLock=$swapCanonicalHeld; ParentHandles=$swapCanonicalParents; SecuritySddl=[string]$swapSecurity.Sddl; SecurityHash=$swapSecurityHash }
                $swapWrapper.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalRepoLockHandle')
                $null = Register-CanonicalRepoLockResourceOwner -LockHandle $swapWrapper -HeldLock $swapCanonicalHeld -ParentHandles @($swapCanonicalParents) -Path ([string]$swapWrapper.Path) -SecuritySddl ([string]$swapSecurity.Sddl) -SecurityHash $swapSecurityHash
                $swapWitness = New-TestHomeAuthorityBindingWitness -RepoRoot $canonicalRoot -CanonicalLockHandle $swapWrapper
                $swappedGlobal = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $bindingContext -RequiredCanonicalWitness $swapWitness
                $swapBinding = [AiAgentDotfiles.SafeLockOrderBinding]::GetForWrapperExact($swappedGlobal)
                $realSwappedGlobalHeld = [AiAgentDotfiles.SafeLockOrderBinding]::GetCurrentExact($swapBinding)
                $realSwappedGlobalOwner = [AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($swappedGlobal)
                $realSwappedGlobalParents = @([AiAgentDotfiles.SafeLockResourceOwner]::GetParentHandlesExact($realSwappedGlobalOwner))
                $replacementHeld = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($swapCanonicalParents[$swapCanonicalParents.Count - 1],'replacement.lock')
                $swappedGlobal.HeldLock = $replacementHeld
                $swappedGlobal.ParentHandles = $swapCanonicalParents
                Assert-ThrowsPattern { Exit-HomeAuthorityGlobalLiveLock -LockHandle $swappedGlobal } '^canonical-witness-required$' 'swapped HeldLock and ParentHandles displays make Exit fail closed after releasing privately bound resources'
                Assert-TestCondition (-not [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($realSwappedGlobalHeld) -and
                    @($realSwappedGlobalParents | Where-Object { [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_) }).Count -eq 0) 'bound global Exit releases the actual lock and complete private parent chain'
                Assert-TestCondition ([AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($replacementHeld) -and
                    @($swapCanonicalParents | Where-Object { -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_) }).Count -eq 0) 'bound global Exit never disposes HeldLock or ParentHandles substitutes'
                $swappedGlobal = $null
            }
            finally {
                if ($null -ne $swappedGlobal) { try { Exit-HomeAuthorityGlobalLiveLock -LockHandle $swappedGlobal } catch {} }
                if ($null -ne $replacementHeld) { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($replacementHeld) }
                if ($null -ne $swapWrapper -and $null -ne ([AiAgentDotfiles.SafeLockResourceOwner]::GetForWrapperExact($swapWrapper))) {
                    Exit-CanonicalRepoLock -LockHandle $swapWrapper
                }
                else {
                    if ($null -ne $swapCanonicalHeld) { [AiAgentDotfiles.SafeLockFileHandle]::DisposeExact($swapCanonicalHeld) }
                    Close-SafeDirectoryContainmentChain -Handles $swapCanonicalParents
                }
            }
        }
        finally {
            if ($null -eq $savedCanonicalValidatorBlock) { Remove-Item -LiteralPath Function:\Assert-CanonicalHeldNamespaceWitness -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath Function:\Assert-CanonicalHeldNamespaceWitness -Value $savedCanonicalValidatorBlock }
        }
    }

    if (Test-Section 'resolver') {
        Write-Host '[sealed known-folder authority resolver]'
        $profile = Join-Path $work 'profile'
        $roaming = Join-Path $work 'roaming'
        $local = Join-Path $work 'local'
        foreach ($path in @($profile, $roaming, $local)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
        $sid = 'S-1-5-21-1000-1001-1002-1003'

        $beforeInventory = Get-FixtureInventoryHash -Root $work
        $first = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local
        $second = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile.ToUpperInvariant() -RoamingAppDataRoot $roaming.ToUpperInvariant() -LocalAppDataRoot $local.ToUpperInvariant()
        $separatorVariant = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile.Replace([char]92,[char]47) -RoamingAppDataRoot $roaming.Replace([char]92,[char]47) -LocalAppDataRoot $local.Replace([char]92,[char]47)
        $afterInventory = Get-FixtureInventoryHash -Root $work

        $privateBase = Join-Path $local 'ai-agent-dotfiles'
        Assert-TestCondition ([string]$first.ControlBase -ceq [IO.Path]::GetFullPath((Join-Path $privateBase 'control'))) 'ControlBase is the fixed LocalAppData child'
        Assert-TestCondition ([string]$first.BackupRoot -ceq [IO.Path]::GetFullPath((Join-Path $privateBase 'backups'))) 'BackupRoot is the fixed ControlBase sibling'
        Assert-TestCondition ([string]$first.ControlBootstrapLockPath -ceq [IO.Path]::GetFullPath((Join-Path $local 'ai-agent-dotfiles.control-bootstrap.lock'))) 'bootstrap lock locator is under the existing Known Folder root'
        Assert-TestCondition ([string]$first.HomeAuthorityKey -ceq [string]$second.HomeAuthorityKey) 'authority key is case and separator stable'
        Assert-TestCondition ([string]$first.HomeAuthorityKey -ceq [string]$separatorVariant.HomeAuthorityKey) 'authority key ignores slash spelling variants'
        Assert-TestCondition ([string]$first.PrivateRootBootstrapStatus -ceq 'MISSING') 'fresh deterministic private prefix is classified MISSING'
        Assert-TestCondition ($beforeInventory -ceq $afterInventory) 'MetadataOnly authority resolution creates no file or directory'
        Assert-TestCondition (-not (Test-Path -LiteralPath $first.ControlBootstrapLockPath) -and -not (Test-Path -LiteralPath $privateBase)) 'read-only resolution creates neither bootstrap lock nor private roots'
        Assert-TestCondition (@($first.LiveTargets).Count -eq 3 -and (@($first.LiveTargets | ForEach-Object Platform) -join ',') -ceq 'Claude,Codex,Reasonix') 'resolver returns the ordered three-platform target set'
        Assert-TestCondition (@($first.LiveTargets | Where-Object { [string]$_.TargetContext.TargetStatus -ceq 'MISSING' }).Count -eq 3) 'fresh-home live targets are represented as MISSING'

        [IO.Directory]::CreateDirectory((Join-Path $privateBase 'control')) | Out-Null
        $partial = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local
        Assert-TestCondition ([string]$partial.PrivateRootBootstrapStatus -ceq 'PARTIAL') 'a partially present private prefix is classified PARTIAL'

        foreach ($path in @(
            (Join-Path $profile '.claude/skills'),
            (Join-Path $profile '.codex/skills'),
            (Join-Path $roaming 'reasonix/skills'),
            (Join-Path $privateBase 'control/homes'),
            (Join-Path $privateBase 'control/canonical-roots'),
            (Join-Path $privateBase 'control/live-transactions'),
            (Join-Path $privateBase 'backups')
        )) { [IO.Directory]::CreateDirectory($path) | Out-Null }
        $created = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local
        Assert-TestCondition ([string]$created.HomeAuthorityKey -ceq [string]$first.HomeAuthorityKey) 'MISSING to created roots preserve the authority namespace'
        Assert-TestCondition (@($created.LiveTargets | Where-Object { [string]$_.TargetContext.TargetStatus -ceq 'EXISTS' }).Count -eq 3) 'created live roots resolve as EXISTS'
        Assert-TestCondition ([string]$created.PrivateRootBootstrapStatus -ceq 'PARTIAL') 'directory existence alone never grants bootstrap COMPLETE'

        foreach ($conversion in @(
            { ConvertTo-HomeAuthorityKnownFolderPath -Path ([IO.Path]::GetPathRoot($work)) -Name 'VolumeRoot' },
            { ConvertTo-HomeAuthorityLocationKey -Path ([IO.Path]::GetPathRoot($work)) },
            { ConvertTo-LiveTargetFullPath -Path ([IO.Path]::GetPathRoot($work)) }
        )) {
            Assert-ThrowsPattern -Action $conversion -Pattern 'volume-root|volume root' -Message 'volume roots are rejected before trailing-separator trimming'
        }

        $cwdProbe = Join-Path $work 'cwd-probe'; [IO.Directory]::CreateDirectory($cwdProbe) | Out-Null
        Push-Location $cwdProbe
        try { $fromOtherCwd = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local }
        finally { Pop-Location }
        Assert-TestCondition ([string]$fromOtherCwd.ControlBootstrapLockPath -ceq [string]$created.ControlBootstrapLockPath -and [string]$fromOtherCwd.ControlBootstrapLockKey -ceq [string]$created.ControlBootstrapLockKey) 'bootstrap lock identity is independent of cwd/repository'

        $customReasonix = Join-Path $work 'custom-reasonix/skills'
        $custom = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local -ReasonixLiveSkillsPath $customReasonix
        Assert-TestCondition ([string]$custom.HomeAuthorityKey -ceq [string]$first.HomeAuthorityKey) 'Reasonix override does not participate in HomeAuthorityKey'
        Assert-TestCondition ([string]$custom.LiveTargets[2].TargetContext.RequestedPath -ceq [IO.Path]::GetFullPath($customReasonix)) 'custom Reasonix target is resolved exactly'

        $otherSid = Resolve-SealedHomeAuthorityTestContext -TokenSid 'S-1-5-21-2000-2001-2002-2003' -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local
        $otherProfile = Join-Path $work 'other-profile'; [IO.Directory]::CreateDirectory($otherProfile) | Out-Null
        $otherHome = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $otherProfile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local
        Assert-TestCondition ([string]$otherSid.HomeAuthorityKey -cne [string]$first.HomeAuthorityKey) 'different access-token SID produces a different authority key'
        Assert-TestCondition ([string]$otherHome.HomeAuthorityKey -cne [string]$first.HomeAuthorityKey) 'different canonical Profile location produces a different authority key'

        Assert-ThrowsPattern { Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local -ReasonixLiveSkillsPath (Join-Path $profile '.claude') } 'overlap' 'platform ancestor/descendant overlap is rejected'
        Assert-ThrowsPattern { Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local -ForbiddenRoots @((Join-Path $profile '.claude/skills/managed')) } 'overlap' 'live target overlap with a forbidden root is rejected'

        $agentsSkills = Join-Path $profile '.agents/skills'; [IO.Directory]::CreateDirectory($agentsSkills) | Out-Null
        Assert-ThrowsPattern { Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local } 'codex-live-root-ambiguous' 'simultaneous Codex preferred and fallback roots fail closed'

        $resolverCommand = Get-Command Resolve-HomeAuthorityContext -ErrorAction Stop
        foreach ($publicSelector in @('HomeRoot', 'BackupRoot', 'LockWaitSeconds')) {
            Assert-TestCondition (-not $resolverCommand.Parameters.ContainsKey($publicSelector)) "production authority resolver rejects public -$publicSelector"
        }

        $knownFolderMethods = @([AiAgentDotfiles.WindowsKnownFolder].GetMethods([Reflection.BindingFlags]'Public,Static') | Where-Object Name -ceq 'GetPath')
        Assert-TestCondition ($knownFolderMethods.Count -eq 1) 'known-folder resolver exposes exactly one token-required GetPath entrypoint'
        $knownFolderParameters = @($knownFolderMethods[0].GetParameters())
        Assert-TestCondition ($knownFolderParameters.Count -eq 2 -and $knownFolderParameters[0].ParameterType -eq [string] -and $knownFolderParameters[1].ParameterType -eq [Microsoft.Win32.SafeHandles.SafeAccessTokenHandle]) 'known-folder resolver requires a SafeAccessTokenHandle and has no NULL-token bypass'

        Write-Host '[Codex preferred/fallback selection stability]'
        $raceProfile = Join-Path $work 'codex-race-profile'
        $raceRoaming = Join-Path $work 'codex-race-roaming'
        [IO.Directory]::CreateDirectory($raceProfile) | Out-Null
        [IO.Directory]::CreateDirectory($raceRoaming) | Out-Null
        $racePreferred = Join-Path $raceProfile '.codex/skills'
        $raceFallback = Join-Path $raceProfile '.agents/skills'
        [IO.Directory]::CreateDirectory($raceFallback) | Out-Null
        $script:CodexRaceOriginalMarker = (Get-Command Get-NoFollowRootEntryMarker -CommandType Function -ErrorAction Stop).ScriptBlock
        $script:CodexRacePreferred = $racePreferred
        $script:CodexRaceMarkerCall = 0
        try {
            Set-Item -LiteralPath Function:\Get-NoFollowRootEntryMarker -Value {
                param([Parameter(Mandatory)][string]$Path)
                $script:CodexRaceMarkerCall++
                $marker = & $script:CodexRaceOriginalMarker -Path $Path
                if ($script:CodexRaceMarkerCall -eq 1) { [IO.Directory]::CreateDirectory($script:CodexRacePreferred) | Out-Null }
                return $marker
            }
            Assert-ThrowsPattern { Resolve-LiveTargetContextSet -ProfileRoot $raceProfile -RoamingAppDataRoot $raceRoaming } 'ambiguous|drift|changed' 'Codex marker creation between preferred/fallback captures is rejected'
        }
        finally {
            Set-Item -LiteralPath Function:\Get-NoFollowRootEntryMarker -Value $script:CodexRaceOriginalMarker
            Remove-Variable -Scope Script -Name CodexRaceOriginalMarker,CodexRacePreferred,CodexRaceMarkerCall -ErrorAction SilentlyContinue
        }

        Write-Host '[Windows known-folder environment isolation]'
        $savedEnvironment = [ordered]@{ USERPROFILE=$env:USERPROFILE; APPDATA=$env:APPDATA; LOCALAPPDATA=$env:LOCALAPPDATA }
        try {
            $knownBefore = Get-WindowsHomeAuthorityIdentity
            $env:USERPROFILE = Join-Path $work 'poison-profile'
            $env:APPDATA = Join-Path $work 'poison-roaming'
            $env:LOCALAPPDATA = Join-Path $work 'poison-local'
            $knownAfter = Get-WindowsHomeAuthorityIdentity
            foreach ($field in @('TokenSid', 'ProfileRoot', 'RoamingAppDataRoot', 'LocalAppDataRoot')) {
                Assert-TestCondition ([string]$knownBefore.$field -ceq [string]$knownAfter.$field) "mutable environment does not change $field"
            }
        }
        finally {
            $env:USERPROFILE = $savedEnvironment.USERPROFILE
            $env:APPDATA = $savedEnvironment.APPDATA
            $env:LOCALAPPDATA = $savedEnvironment.LOCALAPPDATA
        }
    }

    Write-Host 'home authority tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
