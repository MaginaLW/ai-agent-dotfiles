#requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for harness environment definition scripts.

.DESCRIPTION
    This file is intended to be dot-sourced. Beyond dot-sourcing
    scripts/harness-profile-common.ps1 and scripts/semantic-json.ps1, it
    defines helper functions only: no param block and no work at import
    time. Invoke-HarnessEnvMaterialization is the unique writer of staged
    skills, env.lock.json, and the env-build.json sidecar.
#>

Set-StrictMode -Version Latest

# The frozen route-to-next-operation map. Both the assessment and the artifact
# semantic validator read it, so a recommended operation can never drift from
# the route that produced it.
$script:HarnessEnvAuthorityRouteNextOperation = [ordered] @{
    'recovery'                         = 'live recover status'
    'initial'                          = 'env activate full -DryRun'
    'activate'                         = 'env activate <name> -DryRun'
    'migrate'                          = 'env authority migrate <name> -DryRun -PlanPath <external-plan.json>'
    'adopt'                            = 'env authority adopt <name> -DryRun -PlanPath <external-plan.json>'
    'repair-adopt'                     = 'env authority repair-adopt <name> -DryRun -PlanPath <external-plan.json>'
    'takeover'                         = 'env authority takeover <name> -DryRun -PlanPath <external-plan.json>'
    'controller-owner-action-required' = 'env authority status'
    'manual-recovery-required'         = 'env authority status'
}

. (Join-Path $PSScriptRoot 'harness-profile-common.ps1')
. (Join-Path $PSScriptRoot 'semantic-json.ps1')

function Get-HarnessEnvRoot {
    [CmdletBinding()]
    param([string] $RepoRoot)

    return Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) 'harness-source/envs'
}

function Get-HarnessEnvDefinitionFiles {
    [CmdletBinding()]
    param([string] $RepoRoot)

    $envRoot = Get-HarnessEnvRoot -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $envRoot -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $envRoot -File -Filter '*.psd1' | Sort-Object Name)
}

function Read-HarnessEnvDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $data = Import-HarnessDataFile -Path $Path -Kind 'env definition' -RequiredKeys @('SchemaVersion', 'Name', 'Profile', 'Skills')
    Test-HarnessKnownKeys -Data $data -Kind 'env definition' -Path $Path -AllowedKeys @(
        'SchemaVersion', 'Name', 'Description', 'Profile', 'Skills'
    )

    $expectedName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if (-not [string]::Equals([string] $data.Name, $expectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Env definition Name '$($data.Name)' does not match its filename '$expectedName': $Path"
    }
    if (-not ($data.Skills -is [hashtable])) {
        throw "Env definition Skills must be a hashtable: $Path"
    }
    Test-HarnessKnownKeys -Data $data.Skills -Kind 'env definition Skills' -Path $Path -AllowedKeys @('Claude', 'Codex', 'Reasonix')

    return $data
}

function Get-HarnessTaskSkillOverlayPath {
    [CmdletBinding()]
    param([string] $RepoRoot)

    return Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) '.agent-harness/task-skills.psd1'
}

function New-HarnessEmptyTaskSkillOverlay {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $BaseEnvName)

    return @{
        SchemaVersion = 1
        BaseEnv = $BaseEnvName
        Skills = @{
            Claude = @()
            Codex = @()
            Reasonix = @()
        }
    }
}

function Read-HarnessTaskSkillOverlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $Path,
        [string] $BaseEnvName
    )

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $overlayPath = if ([string]::IsNullOrWhiteSpace($Path)) {
        Get-HarnessTaskSkillOverlayPath -RepoRoot $repo
    }
    else {
        [System.IO.Path]::GetFullPath($Path)
    }

    if (-not (Test-Path -LiteralPath $overlayPath -PathType Leaf)) {
        $empty = New-HarnessEmptyTaskSkillOverlay -BaseEnvName $(if ($BaseEnvName) { $BaseEnvName } else { 'work' })
        return [pscustomobject]@{
            Present = $false
            Applicable = $true
            Path = $overlayPath
            Hash = $null
            BaseEnv = [string] $empty.BaseEnv
            Data = $empty
            Skills = $empty.Skills
        }
    }

    $data = Import-HarnessDataFile -Path $overlayPath -Kind 'task skill overlay' -RequiredKeys @('SchemaVersion', 'BaseEnv', 'Skills')
    Test-HarnessKnownKeys -Data $data -Kind 'task skill overlay' -Path $overlayPath -AllowedKeys @('SchemaVersion', 'BaseEnv', 'Skills')

    $overlayBaseEnv = [string] $data.BaseEnv
    if ($overlayBaseEnv -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Task skill overlay BaseEnv must be a bare identifier: $overlayPath"
    }
    if (-not [string]::IsNullOrWhiteSpace($BaseEnvName) -and
        -not [string]::Equals($overlayBaseEnv, $BaseEnvName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Task skill overlay BaseEnv '$overlayBaseEnv' does not match requested environment '$BaseEnvName': $overlayPath"
    }
    if (-not ($data.Skills -is [hashtable])) {
        throw "Task skill overlay Skills must be a hashtable: $overlayPath"
    }
    Test-HarnessKnownKeys -Data $data.Skills -Kind 'task skill overlay Skills' -Path $overlayPath -AllowedKeys @('Claude', 'Codex', 'Reasonix')

    $manifests = @{
        Claude = Join-Path $repo 'manifests/managed-skills.claude.txt'
        Codex  = Join-Path $repo 'manifests/managed-skills.codex.txt'
        Reasonix = Join-Path $repo 'manifests/managed-skills.reasonix.txt'
    }
    $skills = @{}
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $values = if ($data.Skills.ContainsKey($platform)) { @($data.Skills[$platform]) } else { @() }
        if ($data.Skills.ContainsKey($platform) -and -not ($data.Skills[$platform] -is [array])) {
            throw "Task skill overlay $platform Skills must be an array: $overlayPath"
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if (-not (Test-Path -LiteralPath $manifests[$platform] -PathType Leaf)) {
            throw "Task skill overlay cannot validate $platform skills; missing manifest: $($manifests[$platform])"
        }
        $managed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($line in (Get-Content -LiteralPath $manifests[$platform])) {
            $managedName = ([string] $line).Trim()
            if ($managedName) { [void] $managed.Add($managedName) }
        }
        foreach ($value in $values) {
            $name = [string] $value
            if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $name -ieq '.system') {
                throw "Task skill overlay $platform skill name must be a safe bare identifier: $name"
            }
            if (-not $seen.Add($name)) {
                throw "Task skill overlay contains duplicate $platform skill '$name': $overlayPath"
            }
            if (-not $managed.Contains($name)) {
                throw "Task skill overlay references unmanaged $platform skill '$name'."
            }
        }
        $skills[$platform] = @($values | ForEach-Object { [string] $_ })
    }

    return [pscustomobject]@{
        Present = $true
        Applicable = $true
        Path = $overlayPath
        Hash = Get-HarnessFileHash -Path $overlayPath
        BaseEnv = $overlayBaseEnv
        Data = $data
        Skills = $skills
    }
}

function Get-HarnessTaskSkillOverlayForEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $BaseEnvName,
        [string] $Path
    )

    $overlay = Read-HarnessTaskSkillOverlay -RepoRoot $RepoRoot -Path $Path
    if (-not $overlay.Present -or [string]::Equals($overlay.BaseEnv, $BaseEnvName, [System.StringComparison]::OrdinalIgnoreCase)) {
        $overlay.Applicable = $true
        return $overlay
    }

    $empty = New-HarnessEmptyTaskSkillOverlay -BaseEnvName $BaseEnvName
    return [pscustomobject]@{
        Present = $false
        Applicable = $false
        Path = $overlay.Path
        Hash = $null
        BaseEnv = $overlay.BaseEnv
        Data = $empty
        Skills = $empty.Skills
        IgnoredReason = "overlay BaseEnv '$($overlay.BaseEnv)' targets another environment"
    }
}

function Merge-HarnessTaskSkillOverlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Definition,
        [Parameter(Mandatory)] $Overlay
    )

    $merged = @{}
    foreach ($key in $Definition.Keys) {
        if ($key -ne 'Skills') {
            $merged[[string] $key] = $Definition[$key]
        }
    }

    $mergedSkills = @{}
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $values = [System.Collections.Generic.List[string]]::new()
        if ($Definition.Skills.ContainsKey($platform)) {
            foreach ($value in @($Definition.Skills[$platform])) { $values.Add([string] $value) }
        }
        if ($null -ne $Overlay -and $Overlay.Data.Skills.ContainsKey($platform)) {
            foreach ($value in @($Overlay.Data.Skills[$platform])) { $values.Add([string] $value) }
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $unique = [System.Collections.Generic.List[string]]::new()
        foreach ($value in $values) {
            if ($seen.Add($value)) { $unique.Add($value) }
        }
        $mergedSkills[$platform] = @($unique.ToArray())
    }
    $merged.Skills = $mergedSkills
    return $merged
}

function Resolve-HarnessEnvDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [hashtable] $Definition
    )

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $envName = [string] $Definition.Name

    $profileName = [string] $Definition.Profile
    $profilePath = Join-Path $repo "harness-source/profiles/$profileName.psd1"
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw "Env '$envName' references unknown Profile '$profileName': expected $profilePath"
    }
    try {
        # Resolve-HarnessProfileExtends resolves a profile's Extends list, so wrap
        # the env's named profile as a synthetic Extends entry to reuse it as-is.
        $resolvedProfiles = @(Resolve-HarnessProfileExtends -Profile @{ Extends = @($profileName) } -RepoRoot $repo)
    }
    catch {
        throw "Env '$envName' Profile '$profileName' failed to resolve: $($_.Exception.Message)"
    }

    $skills = if ($Definition.ContainsKey('Skills') -and $Definition.Skills -is [hashtable]) { $Definition.Skills } else { @{} }
    $manifests = @{
        Claude = Join-Path $repo 'manifests/managed-skills.claude.txt'
        Codex  = Join-Path $repo 'manifests/managed-skills.codex.txt'
        Reasonix = Join-Path $repo 'manifests/managed-skills.reasonix.txt'
    }
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        if (-not $skills.ContainsKey($platform)) { continue }
        $manifestPath = $manifests[$platform]
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Env '$envName' cannot validate $platform skills; missing manifest: $manifestPath"
        }
        # Case-insensitive on purpose: sync.ps1 matches managed names with an
        # OrdinalIgnoreCase set, and env membership must not be stricter.
        $managed = @(Get-Content -LiteralPath $manifestPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        foreach ($skill in @($skills[$platform])) {
            if ([string] $skill -notin $managed) {
                throw "Env '$envName' references unmanaged $platform skill '$skill'."
            }
        }
    }

    return [pscustomobject] @{
        Name             = $envName
        Profile          = $profileName
        ResolvedProfiles = $resolvedProfiles
        Definition       = $Definition
    }
}

function Get-HarnessEnvStagingRoot {
    [CmdletBinding()]
    param(
        [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Env name must be a bare identifier, not a path: $Name"
    }
    return Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) "envs/$Name"
}

function Get-HarnessEnvStatePath {
    [CmdletBinding()]
    param([string] $RepoRoot)

    return Join-Path (Resolve-HarnessRepoRoot -RepoRoot $RepoRoot) 'state/current-env.json'
}

function Read-HarnessEnvState {
    [CmdletBinding()]
    param([string] $RepoRoot)

    $path = Get-HarnessEnvStatePath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    }
    catch {
        throw "Corrupt env state file: $path ($($_.Exception.Message))"
    }
    if ($null -eq $state -or $state.PSObject.Properties.Name -notcontains 'Name') {
        throw "Env state file is missing required key 'Name': $path"
    }
    return $state
}

function Read-LegacyHarnessEnvState {
    <#
    .SYNOPSIS
        Read-only validated view of the repo-local legacy schema 2 state.

    .DESCRIPTION
        The legacy `state/current-env.json` file is the only artifact this
        reader touches; it never reads, interprets, or writes the shared
        ControlBase schema 3 state or its separate root-claims file, and it
        never deletes or moves the legacy file. The exact bytes are captured so
        a later plan can bind LegacyHash/LegacyCoreHash to what was read.

        Status is `VALID` for a strict semantic-JSON object whose SchemaVersion
        is exactly 2 and whose Name is a non-empty string, `CORRUPT` when the
        file exists but is not that legacy evidence, and `MISSING` when no file
        exists. Full migration-core validation (hash consistency, parity,
        LegacyGap/LegacyDrift) belongs to the migration route and is not
        decided here. This module deliberately stays free of the sealed
        json-artifact layer, so the capture is a plain exact-byte read; the
        migration plan revalidates location and identity under its locks before
        any Apply.
    #>
    [CmdletBinding()]
    param([string] $RepoRoot)

    $path = Get-HarnessEnvStatePath -RepoRoot $RepoRoot
    $legacy = [ordered] @{
        Path = $path
        Status = 'MISSING'
        Bytes = $null
        BytesHash = $null
        Document = $null
        Error = $null
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject] $legacy
    }

    $legacy.Status = 'CORRUPT'
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
    }
    catch {
        $legacy.Error = [string] $_.Exception.Message
        return [pscustomobject] $legacy
    }
    $legacy.Bytes = $bytes
    $legacy.BytesHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    try {
        $document = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($bytes))
    }
    catch {
        $legacy.Error = [string] $_.Exception.Message
        return [pscustomobject] $legacy
    }
    if ($document -isnot [System.Collections.IDictionary] -or -not $document.Contains('SchemaVersion') -or -not $document.Contains('Name')) {
        $legacy.Error = 'the legacy state is not an object with SchemaVersion and Name'
        return [pscustomobject] $legacy
    }
    $schemaVersion = $document['SchemaVersion']
    $name = $document['Name']
    if ($schemaVersion -isnot [long] -or $schemaVersion -ne 2 -or $name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) {
        $legacy.Error = 'the legacy state must use integer SchemaVersion 2 and a non-empty string Name'
        return [pscustomobject] $legacy
    }

    $legacy.Document = $document
    $legacy.Status = 'VALID'
    return [pscustomobject] $legacy
}

function Get-HarnessEnvDefinitionHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    return Get-HarnessFileHash -Path $Path
}

function Get-HarnessEnvLiveSkillRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HomeRootValue,
        [Parameter(Mandatory)] [ValidateSet('Claude', 'Codex', 'Reasonix')] [string] $Platform
    )

    if ($Platform -eq 'Claude') { return Join-Path $HomeRootValue '.claude/skills' }
    if ($Platform -eq 'Reasonix') { return Join-Path $HomeRootValue 'AppData/Roaming/reasonix/skills' }
    $preferred = Join-Path $HomeRootValue '.codex/skills'
    $fallback = Join-Path $HomeRootValue '.agents/skills'
    if (Test-Path -LiteralPath $preferred -PathType Container) { return $preferred }
    if (Test-Path -LiteralPath $fallback -PathType Container) { return $fallback }
    return $preferred
}

function Get-HarnessEnvCodexSystemStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $HomeRoot)

    $codexLive = Get-HarnessEnvLiveSkillRoot -HomeRootValue $HomeRoot -Platform Codex
    $systemDir = Join-Path $codexLive '.system'
    if (-not (Test-Path -LiteralPath $systemDir -PathType Container)) { return 'not-present' }
    if (Test-Path -LiteralPath (Join-Path $systemDir '.codex-system-skills.marker') -PathType Leaf) { return 'present-marker' }
    return 'present-marker-missing'
}

function Read-HarnessEnvNameList {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-HarnessEnvLockLiveParity {
    <#
    .SYNOPSIS
        Compares one environment lock's staged evidence against the live managed roots.

    .DESCRIPTION
        The lock is the trusted anchor: each platform's expected skill set is the
        lock's StagedSkillTreeHashes map, and each expected skill's tree hash must
        match the live skill directory. Live managed names outside the expected set
        are reported as unexpected-managed; `.system` is never inspected, and the
        Codex marker status is reported separately. The managed universe is the
        repository manifest, so unknown live skills are never treated as managed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [object] $Lock,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [AllowNull()] [System.Collections.IDictionary] $LiveRoots
    )

    $mismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $key = $platform.ToLowerInvariant()
        $stagedHashes = Get-HarnessJsonProperty -Object $Lock -Name 'StagedSkillTreeHashes'
        $expectedHashes = Get-HarnessJsonProperty -Object $stagedHashes -Name $platform
        $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($expectedHashes -is [System.Collections.IDictionary]) {
            foreach ($name in @($expectedHashes.Keys)) { [void] $expectedSet.Add([string] $name) }
        }
        elseif ($null -ne $expectedHashes) {
            foreach ($property in @($expectedHashes.PSObject.Properties)) { [void] $expectedSet.Add([string] $property.Name) }
        }
        $overlaySkills = Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $Lock -Name 'TaskOverlaySkills') -Name $platform
        foreach ($name in @($overlaySkills)) {
            if (-not $expectedSet.Contains([string] $name)) { $mismatches.Add("$platform/$name overlay-skill-not-staged") }
        }

        $liveRoot = if ($null -ne $LiveRoots -and $LiveRoots.Contains($platform) -and -not [string]::IsNullOrWhiteSpace([string] $LiveRoots[$platform])) {
            [string] $LiveRoots[$platform]
        }
        else {
            Get-HarnessEnvLiveSkillRoot -HomeRootValue $HomeRoot -Platform $platform
        }
        $managedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in (Read-HarnessEnvNameList -Path (Join-Path $RepoRoot "manifests/managed-skills.$key.txt"))) {
            [void] $managedNames.Add($name)
        }
        $liveNames = if (Test-Path -LiteralPath $liveRoot -PathType Container) {
            @(Get-ChildItem -LiteralPath $liveRoot -Directory -Force | Where-Object { $_.Name -ne '.system' } | ForEach-Object Name)
        }
        else { @() }
        $liveManagedNames = @($liveNames | Where-Object { $managedNames.Contains($_) })
        foreach ($name in $expectedSet) {
            if ($name -notin $liveManagedNames) { $mismatches.Add("$platform/$name missing"); continue }
            $liveHash = Get-HarnessTreeHash -Path (Join-Path $liveRoot $name)
            $expectedHash = if ($null -eq $expectedHashes) { $null } else { [string] (Get-HarnessJsonProperty -Object $expectedHashes -Name $name) }
            if ($null -eq $expectedHash) { $mismatches.Add("$platform/$name staged-hash-missing"); continue }
            if ($liveHash -cne $expectedHash) { $mismatches.Add("$platform/$name content-drift") }
        }
        foreach ($name in $liveManagedNames) {
            if (-not $expectedSet.Contains($name)) { $mismatches.Add("$platform/$name unexpected-managed") }
        }
    }

    return [pscustomobject]@{
        Status = if ($mismatches.Count -eq 0) { 'pass' } else { 'mismatch' }
        Mismatches = @($mismatches)
        SystemStatus = Get-HarnessEnvCodexSystemStatus -HomeRoot $HomeRoot
    }
}

function Get-HarnessLegacyEnvAssessment {
    <#
    .SYNOPSIS
        Read-only assessment of the repo-local legacy schema 2 activation evidence.

    .DESCRIPTION
        Distinguishes the three routing-relevant outcomes without inventing any
        new artifact: `MISSING` when no legacy state exists, `CORRUPT` when the
        legacy state or its preserved old activation lock is not valid,
        internally consistent core evidence, and `CORE` when every core field
        validates against that preserved lock. Only a missing Reasonix baseline
        is tolerated (LegacyGap=ReasonixBaselineMissing); any other missing or
        mismatched core field keeps the artifact as untrusted evidence.

        `OldLockStatus` is VERIFIED only when the state's LockHash equals the
        exact bytes hash of `envs/<Name>/env.lock.json` and the lock's recorded
        definition/task-overlay/manifest/commit evidence matches the state.
        LiveParity is computed only for a VERIFIED old lock (per managed skill,
        never a whole-root hash). Nothing here deletes, moves, or writes the
        legacy evidence, and no lock is taken.
    #>
    [CmdletBinding()]
    param(
        [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $HomeAuthorityKey,
        [Parameter(Mandatory)] [string] $TokenSid
    )

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $legacy = Read-LegacyHarnessEnvState -RepoRoot $repo
    $assessment = [ordered] @{
        Status = 'MISSING'
        Schema = $null
        EnvName = $null
        Gap = 'none'
        Drift = 'none'
        HomeRootMatches = $false
        OldLockStatus = 'MISSING'
        LiveParity = [ordered] @{ Status = 'not-checked'; Mismatches = @() }
        Lock = $null
        Reasons = @()
    }
    if ([string] $legacy.Status -ceq 'MISSING') { return [pscustomobject] $assessment }
    $assessment.Schema = 2
    if ([string] $legacy.Status -cne 'VALID') {
        $assessment.Status = 'CORRUPT'
        $assessment.Reasons = @('legacy-state-not-valid')
        return [pscustomobject] $assessment
    }

    $legacyDocument = [System.Collections.IDictionary] $legacy.Document
    $reasons = [System.Collections.Generic.List[string]]::new()
    $assessment.EnvName = [string] $legacyDocument['Name']
    foreach ($field in @('HomeRoot', 'DefinitionHash', 'TaskOverlayHash', 'LockHash', 'ManifestHashes', 'TaskOverlaySkills', 'RepositoryCommit')) {
        if (-not $legacyDocument.Contains($field)) { $reasons.Add("legacy-$($field.ToLowerInvariant())-missing") }
    }
    if ([string] $assessment.EnvName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z') { $reasons.Add('legacy-name-invalid') }
    $legacyHome = [string] $legacyDocument['HomeRoot']
    if (-not [IO.Path]::IsPathFullyQualified($legacyHome)) {
        $reasons.Add('legacy-homeroot-not-absolute')
    }
    elseif ($legacyHome.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
        $reasons.Add('legacy-homeroot-invalid')
    }
    if ($reasons.Count -eq 0) {
        $legacyLocationKey = ([IO.Path]::GetFullPath($legacyHome)).TrimEnd([char] 92, [char] 47).ToLowerInvariant().Replace([char] 92, [char] 47)
        $expectedAuthorityKey = Get-SemanticJsonHash -InputObject ([ordered] @{
            Domain = 'ai-agent-dotfiles/home-authority/v1'
            TokenSid = $TokenSid
            HomeRootLocationKey = $legacyLocationKey
        })
        if ($expectedAuthorityKey -cne $HomeAuthorityKey) { $reasons.Add('legacy-homeroot-authority-mismatch') }
        else { $assessment.HomeRootMatches = $true }
    }
    if ($reasons.Count -eq 0) {
        $manifestHashes = $null
        $overlaySkills = $null
        if ($legacyDocument['ManifestHashes'] -is [System.Collections.IDictionary]) { $manifestHashes = $legacyDocument['ManifestHashes'] } else { $reasons.Add('legacy-manifesthashes-invalid') }
        if ($legacyDocument['TaskOverlaySkills'] -is [System.Collections.IDictionary]) { $overlaySkills = $legacyDocument['TaskOverlaySkills'] } else { $reasons.Add('legacy-taskoverlayskills-invalid') }
        if ($null -ne $manifestHashes -and $null -ne $overlaySkills) {
            foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
                if (-not $manifestHashes.Contains($platform) -or [string]::IsNullOrWhiteSpace([string] $manifestHashes[$platform])) {
                    if ($platform -ceq 'Reasonix') { $assessment.Gap = 'ReasonixBaselineMissing' } else { $reasons.Add("legacy-manifest-hash-missing-$($platform.ToLowerInvariant())") }
                }
                if (-not $overlaySkills.Contains($platform)) {
                    if ($platform -ceq 'Reasonix') { $assessment.Gap = 'ReasonixBaselineMissing' } else { $reasons.Add("legacy-task-overlay-missing-$($platform.ToLowerInvariant())") }
                }
            }
        }
        foreach ($field in @('DefinitionHash', 'LockHash', 'RepositoryCommit')) {
            if ([string]::IsNullOrWhiteSpace([string] $legacyDocument[$field])) { $reasons.Add("legacy-$($field.ToLowerInvariant())-empty") }
        }
        if (-not [string]::IsNullOrWhiteSpace([string] $legacyDocument['TaskOverlayHash']) -and [string] $legacyDocument['TaskOverlayHash'] -cnotmatch '\A[0-9a-f]{64}\z') {
            $reasons.Add('legacy-taskoverlayhash-invalid')
        }
    }

    if ($reasons.Count -eq 0) {
        $oldLockPath = Join-Path (Join-Path $repo 'envs') (Join-Path $assessment.EnvName 'env.lock.json')
        if (-not (Test-Path -LiteralPath $oldLockPath -PathType Leaf)) {
            $reasons.Add('legacy-old-lock-missing')
        }
        else {
            $oldLockHash = Get-HarnessFileHash -Path $oldLockPath
            if ([string] $legacyDocument['LockHash'] -ine $oldLockHash) {
                $assessment.OldLockStatus = 'HASH-MISMATCH'
                $reasons.Add('legacy-old-lock-hash-mismatch')
            }
            else {
                $oldLock = $null
                try { $oldLock = Read-HarnessEnvLock -StagingPath (Split-Path -Parent $oldLockPath) } catch { $reasons.Add('legacy-old-lock-unreadable') }
                if ($null -ne $oldLock) {
                    foreach ($pair in @(
                            @{ Legacy = 'DefinitionHash'; Lock = 'DefinitionHash' }
                            @{ Legacy = 'TaskOverlayHash'; Lock = 'TaskOverlayHash' }
                            @{ Legacy = 'RepositoryCommit'; Lock = 'RepositoryCommit' }
                            @{ Legacy = 'ManifestHashes'; Lock = 'ManifestHashes' })) {
                        $legacyValue = $legacyDocument[$pair.Legacy]
                        $lockValue = Get-HarnessJsonProperty -Object $oldLock -Name $pair.Lock
                        if ((Get-SemanticJsonHash -InputObject $legacyValue) -cne (Get-SemanticJsonHash -InputObject $lockValue)) {
                            $reasons.Add("legacy-old-lock-$($pair.Legacy.ToLowerInvariant())-mismatch")
                        }
                    }
                    if ($reasons.Count -eq 0) {
                        $assessment.OldLockStatus = 'VERIFIED'
                        $parity = Get-HarnessEnvLockLiveParity -RepoRoot $repo -Lock $oldLock -HomeRoot $HomeRoot
                        $assessment.LiveParity = [ordered] @{ Status = [string] $parity.Status; Mismatches = @($parity.Mismatches) }
                        $assessment.Lock = $oldLock
                    }
                }
            }
        }
    }

    if ($reasons.Count -eq 0) {
        $assessment.Status = 'CORE'
        if ([string] $legacyDocument['RepositoryCommit'] -cne [string] (Get-HarnessRepositoryCommit -RepoRoot $repo)) {
            $assessment.Drift = 'RepositoryCommitAdvanced'
        }
    }
    else {
        $assessment.Status = 'CORRUPT'
    }
    $assessment.Reasons = @($reasons)
    return [pscustomobject] $assessment
}

function Resolve-HarnessEnvAuthorityRoute {
    <#
    .SYNOPSIS
        The single frozen authority route decision.

    .DESCRIPTION
        Pure function over the read-only facts. Both the assessment and the
        artifact semantic validator call it, so the emitted route can never
        drift from the documented decision order: unfinished recovery first,
        then unverifiable/corrupt claims, then the valid-pair controller
        branches, then the state-repair branch, and finally the legacy branches
        (migrate only for complete, consistent core evidence with passing live
        parity; adopt for missing or untrusted evidence and for non-pristine
        roots; initial only for fully pristine roots).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('not-checked', 'clean', 'unfinished')] [string] $RecoveryStatus,
        [Parameter(Mandatory)] [ValidateSet('not-checked', 'MISSING', 'CORRUPT', 'UNAVAILABLE', 'VALID')] [string] $ClaimsStatus,
        [Parameter(Mandatory)] [ValidateSet('not-checked', 'MISSING', 'CORRUPT', 'UNAVAILABLE', 'VALID')] [string] $StateStatus,
        [Parameter(Mandatory)] [ValidateSet('not-checked', 'MISSING', 'CORRUPT', 'UNAVAILABLE', 'MISMATCH', 'VALID')] [string] $PairStatus,
        [AllowNull()] [object] $ControllerMatch,
        [Parameter(Mandatory)] [ValidateSet('not-checked', 'pass', 'mismatch')] [string] $LockParityStatus,
        [Parameter(Mandatory)] [ValidateSet('not-checked', 'MISSING', 'CORRUPT', 'CORE')] [string] $LegacyStatus,
        [Parameter(Mandatory)] [ValidateSet('not-checked', 'MISSING', 'HASH-MISMATCH', 'VERIFIED')] [string] $OldLockStatus,
        [Parameter(Mandatory)] [ValidateSet('not-checked', 'pass', 'mismatch')] [string] $LegacyLiveParityStatus,
        [Parameter(Mandatory)] [bool] $LiveRootsPristine
    )

    if ($RecoveryStatus -ceq 'unfinished') { return 'recovery' }
    if ($ClaimsStatus -ceq 'UNAVAILABLE' -or $StateStatus -ceq 'UNAVAILABLE' -or $ClaimsStatus -ceq 'CORRUPT') { return 'manual-recovery-required' }
    if ($PairStatus -ceq 'VALID') {
        if ($ControllerMatch -eq $true) { return 'activate' }
        if ($LockParityStatus -ceq 'pass') { return 'takeover' }
        return 'controller-owner-action-required'
    }
    if ($PairStatus -ceq 'MISMATCH') { return 'manual-recovery-required' }
    if ($ClaimsStatus -ceq 'VALID' -and ($StateStatus -ceq 'CORRUPT' -or $StateStatus -ceq 'MISSING')) { return 'repair-adopt' }
    if ($ClaimsStatus -ceq 'MISSING') {
        if ($LegacyStatus -ceq 'CORE') {
            if ($OldLockStatus -ceq 'VERIFIED' -and $LegacyLiveParityStatus -ceq 'pass') { return 'migrate' }
            return 'manual-recovery-required'
        }
        if ($LegacyStatus -ceq 'CORRUPT') { return 'adopt' }
        if ($LiveRootsPristine) { return 'initial' }
        return 'adopt'
    }
    return 'manual-recovery-required'
}

function Test-HarnessEnvAuthorityDocumentSemantics {
    <#
    .SYNOPSIS
        Semantic validator for the harness-env-list v2 and harness-env-status v2 documents.

    .DESCRIPTION
        Recomputes the route from the document's own facts with the frozen
        decision function and checks the cross-field invariants that JSON Schema
        cannot express: exactly one recommended next operation per route,
        intended-root presence bound to the transitions that may establish a
        custom Reasonix root, no capability hash or probe artifact in any status
        branch, a state summary only for a valid state, and
        lock/legacy/parity/recovery consistency.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)

    $authority = Get-HarnessJsonProperty -Object $Document -Name 'Authority'
    if ($null -eq $authority) { throw 'harness-env-authority-document-missing-authority' }
    $authority = [System.Collections.IDictionary] $authority

    $route = [string] (Get-HarnessJsonProperty -Object $authority -Name 'Route')
    $expectedNextOperation = [string] $script:HarnessEnvAuthorityRouteNextOperation[$route]
    if ([string]::IsNullOrWhiteSpace($expectedNextOperation)) { throw 'harness-env-authority-document-route-unsupported' }
    if ([string] (Get-HarnessJsonProperty -Object $authority -Name 'NextOperation') -cne $expectedNextOperation) {
        throw 'harness-env-authority-document-next-operation-mismatch'
    }

    $recoveryStatus = [string] (Get-HarnessJsonProperty -Object $authority -Name 'RecoveryStatus')
    $claimsStatus = [string] (Get-HarnessJsonProperty -Object $authority -Name 'RootClaimsStatus')
    $stateStatus = [string] (Get-HarnessJsonProperty -Object $authority -Name 'StateStatus')
    $pairStatus = [string] (Get-HarnessJsonProperty -Object $authority -Name 'PairStatus')
    $controllerMatch = Get-HarnessJsonProperty -Object $authority -Name 'ControllerMatch'
    $lockParity = [System.Collections.IDictionary] (Get-HarnessJsonProperty -Object $authority -Name 'LockParity')
    $lockParityStatus = [string] (Get-HarnessJsonProperty -Object $lockParity -Name 'Status')
    $legacy = [System.Collections.IDictionary] (Get-HarnessJsonProperty -Object $authority -Name 'Legacy')
    $legacyStatus = [string] (Get-HarnessJsonProperty -Object $legacy -Name 'Status')
    $oldLockStatus = [string] (Get-HarnessJsonProperty -Object $legacy -Name 'OldLockStatus')
    $legacyLiveParity = [System.Collections.IDictionary] (Get-HarnessJsonProperty -Object $legacy -Name 'LiveParity')
    $legacyLiveParityStatus = [string] (Get-HarnessJsonProperty -Object $legacyLiveParity -Name 'Status')
    $liveRoots = [System.Collections.IDictionary] (Get-HarnessJsonProperty -Object $authority -Name 'LiveRoots')
    $pristine = Get-HarnessJsonProperty -Object $liveRoots -Name 'Pristine'

    $recomputed = Resolve-HarnessEnvAuthorityRoute -RecoveryStatus $recoveryStatus -ClaimsStatus $claimsStatus -StateStatus $stateStatus -PairStatus $pairStatus -ControllerMatch $controllerMatch -LockParityStatus $lockParityStatus -LegacyStatus $legacyStatus -OldLockStatus $oldLockStatus -LegacyLiveParityStatus $legacyLiveParityStatus -LiveRootsPristine ([bool] $pristine)
    if ($recomputed -cne $route) { throw 'harness-env-authority-document-route-inconsistent' }

    $unfinished = @((Get-HarnessJsonProperty -Object $authority -Name 'UnfinishedTransactionIds'))
    if ($recoveryStatus -ceq 'unfinished' -and $unfinished.Count -eq 0) { throw 'harness-env-authority-document-recovery-inconsistent' }
    if ($recoveryStatus -ceq 'clean' -and $unfinished.Count -ne 0) { throw 'harness-env-authority-document-recovery-inconsistent' }
    $previousId = $null
    foreach ($transactionId in $unfinished) {
        # The scan reports namespace directory names verbatim, so a stray or
        # unreadable entry must stay reportable; only its shape is pinned.
        if ([string] $transactionId -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z') {
            throw 'harness-env-authority-document-transaction-id-invalid'
        }
        if ($null -ne $previousId -and [string] $transactionId -cnotmatch ('\A' + [regex]::Escape([string] $previousId) + '\z') -and
            [string]::CompareOrdinal([string] $previousId, [string] $transactionId) -gt 0) {
            throw 'harness-env-authority-document-transaction-ids-unsorted'
        }
        $previousId = $transactionId
    }

    $stateSummary = Get-HarnessJsonProperty -Object $authority -Name 'StateSummary'
    if ($stateStatus -ceq 'VALID' -and $null -eq $stateSummary) { throw 'harness-env-authority-document-state-summary-missing' }
    if ($stateStatus -cne 'VALID' -and $null -ne $stateSummary) { throw 'harness-env-authority-document-state-summary-unexpected' }

    $reasons = @((Get-HarnessJsonProperty -Object $lockParity -Name 'Reasons'))
    if ($lockParityStatus -ceq 'not-checked' -and $reasons.Count -eq 0) { throw 'harness-env-authority-document-lock-parity-reason-missing' }
    if ($lockParityStatus -cne 'not-checked' -and $reasons.Count -ne 0) { throw 'harness-env-authority-document-lock-parity-reason-unexpected' }

    if ($oldLockStatus -cne 'VERIFIED' -and $legacyLiveParityStatus -cne 'not-checked') { throw 'harness-env-authority-document-legacy-parity-unexpected' }
    if ($oldLockStatus -ceq 'VERIFIED' -and $legacyLiveParityStatus -ceq 'not-checked') { throw 'harness-env-authority-document-legacy-parity-missing' }

    $intendedRoot = Get-HarnessJsonProperty -Object $authority -Name 'IntendedRoot'
    $intendedRootRoutes = @('initial', 'migrate', 'adopt')
    if ($route -cin $intendedRootRoutes) {
        if ($null -eq $intendedRoot) { throw 'harness-env-authority-document-intended-root-missing' }
        $intendedRoot = [System.Collections.IDictionary] $intendedRoot
        if ([string] (Get-HarnessJsonProperty -Object $intendedRoot -Name 'FilesystemCapabilityStatus') -cne 'UNPROBED') {
            throw 'harness-env-authority-document-intended-root-probed'
        }
        if ([string] (Get-HarnessJsonProperty -Object $intendedRoot -Name 'RequestedInitialRootContextHash') -cnotmatch '\A[0-9a-f]{64}\z') {
            throw 'harness-env-authority-document-intended-root-hash-invalid'
        }
        $selection = [string] (Get-HarnessJsonProperty -Object $intendedRoot -Name 'Selection')
        $hasLabel = $intendedRoot.Contains('RequestedReasonixRoot')
        if ($selection -ceq 'explicit-initial-claim' -and -not $hasLabel) { throw 'harness-env-authority-document-intended-root-label-missing' }
        if ($selection -ceq 'known-folder-default' -and $hasLabel) { throw 'harness-env-authority-document-intended-root-label-unexpected' }
    }
    elseif ($null -ne $intendedRoot) {
        throw 'harness-env-authority-document-intended-root-unexpected'
    }

    foreach ($forbidden in @('FilesystemCapabilityHash', 'ProbeRoot', 'CapabilityProbe')) {
        if ($authority.Contains($forbidden)) { throw 'harness-env-authority-document-probe-artifact-present' }
    }
    if ([string] (Get-HarnessJsonProperty -Object $authority -Name 'HomeAuthorityKeyLabel') -cnotmatch '\A[0-9a-f]{12}\.\.\.\z') {
        throw 'harness-env-authority-document-key-label-invalid'
    }
}

function Get-HarnessTextSha256 {
    [CmdletBinding()]
    param([AllowNull()] [string] $Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text ?? '')
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-HarnessTreeHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string[]] $ExcludeDirectoryNames = @()
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }

    $root = (Resolve-Path -LiteralPath $Path).Path
    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName)) {
        $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName) -replace '\\', '/'
        if (@($ExcludeDirectoryNames).Count -gt 0 -and
            (($relative -split '/') | Where-Object { $_ -in $ExcludeDirectoryNames }).Count -gt 0) {
            continue
        }
        $rows.Add("$relative|$($file.Length)|$(Get-HarnessFileHash -Path $file.FullName)")
    }
    return Get-HarnessTextSha256 -Text (($rows.ToArray() -join "`n") + "`n")
}

function Get-HarnessRepositoryCommit {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { return $null }

    $output = & $git.Source -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $commit = ([string] ($output | Select-Object -First 1)).Trim()
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') { return $null }
    return $commit.ToLowerInvariant()
}

function Get-HarnessManifestHashes {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    return [ordered]@{
        Claude = Get-HarnessFileHash -Path (Join-Path $repo 'manifests/managed-skills.claude.txt')
        Codex = Get-HarnessFileHash -Path (Join-Path $repo 'manifests/managed-skills.codex.txt')
        Reasonix = Get-HarnessFileHash -Path (Join-Path $repo 'manifests/managed-skills.reasonix.txt')
    }
}

function Get-HarnessSkillSourceHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [ValidateSet('Claude', 'Codex', 'Reasonix')] [string] $Platform,
        [Parameter(Mandatory)] [string] $Name
    )

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $platformOnly = switch ($Platform) {
        'Claude' { 'claude-only' }
        'Codex' { 'codex-only' }
        'Reasonix' { 'reasonix-only' }
    }
    $candidatePaths = @(
        (Join-Path $repo "skills-source/shared/$Name"),
        (Join-Path $repo "skills-source/$platformOnly/$Name")
    )
    $candidates = @($candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($candidates.Count -gt 1) {
        throw "Skill '$Name' exists in both shared and $platformOnly source roots. Resolve the source conflict before building an environment."
    }
    if ($candidates.Count -eq 0) { return $null }
    return Get-HarnessTreeHash -Path $candidates[0]
}

function Get-HarnessSkillSourceEvidenceStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    if ((Test-Path -LiteralPath (Join-Path $repo 'skills-source') -PathType Container)) {
        return 'available'
    }
    return 'not-collected'
}

function Get-HarnessProfileSourceHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $profiles = Join-Path $repo 'harness-source/profiles'
    $components = Join-Path $repo 'harness-source/components'
    if (-not (Test-Path -LiteralPath $profiles -PathType Container) -and
        -not (Test-Path -LiteralPath $components -PathType Container)) {
        return $null
    }
    $text = "profiles=$(Get-HarnessTreeHash -Path $profiles)`ncomponents=$(Get-HarnessTreeHash -Path $components)`n"
    return Get-HarnessTextSha256 -Text $text
}

function Sort-HarnessOrdinal {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Values)

    $sorted = [string[]] @($Values)
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return @($sorted)
}

function Get-HarnessEnvLockPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StagingPath)

    return Join-Path $StagingPath 'env.lock.json'
}

function Get-HarnessEnvBuildPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StagingPath)

    return Join-Path $StagingPath 'env-build.json'
}

function ConvertTo-HarnessEnvDocumentTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] [object] $Document)

    if ($Document -is [System.Collections.IDictionary]) { return $Document }
    $table = [ordered]@{}
    if ($null -eq $Document) { return $table }
    foreach ($property in $Document.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }
    return $table
}

function Get-HarnessEnvMaterializationHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Document)

    $source = ConvertTo-HarnessEnvDocumentTable -Document $Document
    $copy = [ordered]@{}
    foreach ($key in $source.Keys) {
        $name = [string] $key
        if ($name -ceq 'GeneratedAtUtc' -or $name -ceq 'MaterializationHash') { continue }
        $copy[$name] = $source[$key]
    }
    return Get-SemanticJsonHash -InputObject $copy
}

function Test-HarnessEnvBuildSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)

    $schemaUnsupported = 'env-build-schema-unsupported'
    $missingPlatformRoot = 'env-build-missing-platform-root'
    $hashMismatch = 'env-build-hash-mismatch'
    if ([long] (Get-HarnessJsonProperty -Object $Document -Name 'SchemaVersion') -ne 3) {
        throw $schemaUnsupported
    }

    $roots = Get-HarnessJsonProperty -Object $Document -Name 'MaterializedRoots'
    $expectedRelative = [ordered]@{
        Claude = 'claude/skills'
        Codex = 'codex/skills'
        Reasonix = 'reasonix/skills'
    }
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $root = Get-HarnessJsonProperty -Object $roots -Name $platform
        if ($null -eq $root) { throw $missingPlatformRoot }
        $relative = [string] (Get-HarnessJsonProperty -Object $root -Name 'RelativePath')
        $exists = Get-HarnessJsonProperty -Object $root -Name 'Exists'
        if ($relative -cne [string] $expectedRelative[$platform] -or $exists -ne $true) {
            throw $missingPlatformRoot
        }
    }

    $expectedHash = Get-HarnessEnvMaterializationHash -Document $Document
    if ([string] (Get-HarnessJsonProperty -Object $Document -Name 'MaterializationHash') -cne $expectedHash) {
        throw $hashMismatch
    }
}

function Read-HarnessEnvBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StagingPath)

    $path = Get-HarnessEnvBuildPath -StagingPath $StagingPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing environment build sidecar: $path"
    }
    try {
        $json = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $true))
        $build = ConvertFrom-SemanticJson -Json $json
    }
    catch {
        throw "Corrupt environment build sidecar: $path ($($_.Exception.Message))"
    }
    Test-HarnessEnvBuildSemantics -Document $build
    return $build
}

function Read-HarnessEnvLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StagingPath)

    $path = Get-HarnessEnvLockPath -StagingPath $StagingPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing environment lock: $path"
    }
    try {
        $lock = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    }
    catch {
        throw "Corrupt environment lock: $path ($($_.Exception.Message))"
    }
    foreach ($required in @('SchemaVersion', 'Name', 'DefinitionHash', 'TaskOverlayHash', 'TaskOverlaySkills', 'RepositoryCommit', 'ManifestHashes', 'SkillSourceEvidence', 'SkillSourceHashes', 'StagedSkillTreeHashes', 'ProfileSourceHash', 'ProfileOutputHash', 'BuiltFiles')) {
        if ($null -eq $lock -or $lock.PSObject.Properties.Name -notcontains $required) {
            throw "Environment lock is missing required key '$required': $path"
        }
    }
    if ([int] $lock.SchemaVersion -ne 3) {
        throw "Unsupported environment lock schema $($lock.SchemaVersion): $path"
    }
    return $lock
}

function Get-HarnessJsonProperty {
    [CmdletBinding()]
    param(
        [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $null }
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-HarnessLockMapKeys {
    [CmdletBinding()]
    param([AllowNull()] [object] $Map)

    if ($null -eq $Map) { return @() }
    return @($Map.PSObject.Properties.Name | Sort-Object)
}

function Test-HarnessEnvLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $DefinitionPath,
        [Parameter(Mandatory)] [string] $StagingPath,
        [string] $TaskOverlayPath
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $lock = $null
    $lockPath = Get-HarnessEnvLockPath -StagingPath $StagingPath
    try {
        $lock = Read-HarnessEnvLock -StagingPath $StagingPath
    }
    catch {
        $reasons.Add($_.Exception.Message)
        return [pscustomobject]@{
            Valid = $false
            Reasons = @($reasons)
            Lock = $null
            LockHash = $null
        }
    }

    $definition = $null
    try { $definition = Read-HarnessEnvDefinition -Path $DefinitionPath }
    catch { $reasons.Add($_.Exception.Message) }
    if ($null -ne $definition) {
        if ([string] $lock.Name -ne [string] $definition.Name) { $reasons.Add('lock environment name does not match definition') }
        $definitionHash = Get-HarnessEnvDefinitionHash -Path $DefinitionPath
        if ([string] $lock.DefinitionHash -ne $definitionHash) { $reasons.Add('environment definition changed since build') }

        try {
            $taskOverlay = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $RepoRoot -BaseEnvName ([string] $definition.Name) -Path $TaskOverlayPath
            $currentOverlayHash = [string] $taskOverlay.Hash
            $savedOverlayHash = [string] (Get-HarnessJsonProperty -Object $lock -Name 'TaskOverlayHash')
            if ($savedOverlayHash -ne $currentOverlayHash) {
                $reasons.Add('task skill overlay changed since build')
            }
        }
        catch {
            $reasons.Add($_.Exception.Message)
        }
    }

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $currentCommit = Get-HarnessRepositoryCommit -RepoRoot $repo
    if ($null -ne $lock.RepositoryCommit -and $null -ne $currentCommit -and [string] $lock.RepositoryCommit -ne $currentCommit) {
        $reasons.Add('repository commit changed since build')
    }

    $manifestHashes = Get-HarnessManifestHashes -RepoRoot $repo
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $saved = [string] (Get-HarnessJsonProperty -Object $lock.ManifestHashes -Name $platform)
        $current = [string] (Get-HarnessJsonProperty -Object $manifestHashes -Name $platform)
        if ($saved -ne $current) { $reasons.Add("$platform managed-skills manifest changed since build") }
    }

    $sourceEvidence = [string] $lock.SkillSourceEvidence
    if ($sourceEvidence -eq 'available') {
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $platformManifest = Join-Path $StagingPath ("manifest.{0}.txt" -f $platform.ToLowerInvariant())
            $names = if (Test-Path -LiteralPath $platformManifest -PathType Leaf) {
                @(Get-Content -LiteralPath $platformManifest | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            } else { @() }
            foreach ($name in $names) {
                $saved = [string] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $lock.SkillSourceHashes -Name $platform) -Name $name)
                $current = Get-HarnessSkillSourceHash -RepoRoot $repo -Platform $platform -Name $name
                if ($saved -ne [string] $current) { $reasons.Add("$platform skill source '$name' changed since build") }
            }
        }
    }

    $profileSourceHash = Get-HarnessProfileSourceHash -RepoRoot $repo
    if ($null -ne $lock.ProfileSourceHash -and $null -ne $profileSourceHash -and [string] $lock.ProfileSourceHash -ne $profileSourceHash) {
        $reasons.Add('harness profile/component source changed since build')
    }

    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $stagedRoot = Join-Path $StagingPath "$($platform.ToLowerInvariant())/skills"
        $names = if (Test-Path -LiteralPath (Join-Path $StagingPath "manifest.$($platform.ToLowerInvariant()).txt") -PathType Leaf) {
            @(Get-Content -LiteralPath (Join-Path $StagingPath "manifest.$($platform.ToLowerInvariant()).txt") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } else { @() }
        foreach ($name in $names) {
            $saved = [string] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $lock.StagedSkillTreeHashes -Name $platform) -Name $name)
            $current = Get-HarnessTreeHash -Path (Join-Path $stagedRoot $name)
            if ($saved -ne [string] $current) { $reasons.Add("staged $platform skill '$name' changed or is missing") }
        }
    }
    $profileOutputHash = Get-HarnessTreeHash -Path (Join-Path $StagingPath 'profile')
    if ([string] $lock.ProfileOutputHash -ne [string] $profileOutputHash) { $reasons.Add('staged profile output changed or is missing') }

    $savedFiles = @($lock.BuiltFiles.PSObject.Properties.Name | Sort-Object)
    $buildPath = Get-HarnessEnvBuildPath -StagingPath $StagingPath
    # sync.ps1 writes run reports under a staging repo during activation. Those
    # reports are runtime evidence, not build artifacts covered by env.lock.json.
    # env-build.json is the v3 sidecar written after the lock and is likewise
    # outside the lock's BuiltFiles set.
    $currentFiles = @(Get-ChildItem -LiteralPath $StagingPath -File -Recurse -Force |
        Where-Object { $_.FullName -ne $lockPath -and $_.FullName -ne $buildPath } |
        ForEach-Object { [System.IO.Path]::GetRelativePath($StagingPath, $_.FullName) -replace '\\', '/' } |
        Where-Object { -not $_.StartsWith('reports/', [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object)
    if ((ConvertTo-Json $savedFiles -Compress) -ne (ConvertTo-Json $currentFiles -Compress)) {
        $reasons.Add('staging file set differs from env.lock.json')
    }
    foreach ($relative in $currentFiles) {
        $savedHash = [string] (Get-HarnessJsonProperty -Object $lock.BuiltFiles -Name $relative)
        $currentHash = Get-HarnessFileHash -Path (Join-Path $StagingPath ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar))
        if ($savedHash -ne [string] $currentHash) { $reasons.Add("staged file changed: $relative") }
    }

    [pscustomobject]@{
        Valid = ($reasons.Count -eq 0)
        Reasons = @($reasons)
        Lock = $lock
        LockHash = Get-HarnessFileHash -Path $lockPath
    }
}

function Assert-HarnessEnvDestinationEmpty {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Destination)

    $destinationFull = [System.IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $destinationFull -PathType Leaf) {
        throw "Harness env materialization destination is a file: $destinationFull"
    }
    if (-not (Test-Path -LiteralPath $destinationFull -PathType Container)) {
        return $destinationFull
    }
    $children = @(Get-ChildItem -LiteralPath $destinationFull -Force)
    if ($children.Count -gt 0) {
        throw "Harness env materialization destination is not empty: $destinationFull"
    }
    return $destinationFull
}

function Invoke-HarnessEnvMaterialization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Destination,
        [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
        [string] $TaskOverlayPath
    )

    $destinationFull = Assert-HarnessEnvDestinationEmpty -Destination $Destination
    if (-not (Test-Path -LiteralPath $destinationFull -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
    }

    $repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
    $definitionPath = Join-Path (Get-HarnessEnvRoot -RepoRoot $repo) "$Name.psd1"
    if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
        throw "Unknown env '$Name': expected definition at $definitionPath"
    }
    $definition = Read-HarnessEnvDefinition -Path $definitionPath
    $taskOverlay = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $repo -BaseEnvName $Name -Path $TaskOverlayPath
    $effectiveDefinition = Merge-HarnessTaskSkillOverlay -Definition $definition -Overlay $taskOverlay
    $resolved = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $effectiveDefinition

    $skillsByPlatform = @{}
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $names = @()
        if ($effectiveDefinition.Skills.ContainsKey($platform)) {
            $names = @($effectiveDefinition.Skills[$platform] | ForEach-Object { [string] $_ })
        }
        foreach ($skill in $names) {
            if ($skill -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                throw "Env '$Name' $platform skill name must be a bare identifier, not a path: $skill"
            }
        }
        $skillsByPlatform[$platform] = @(Sort-HarnessOrdinal -Values $names | Select-Object -Unique)
    }

    $generatedRoots = @{ Claude = 'claude/skills'; Codex = 'codex/skills'; Reasonix = 'reasonix/skills' }
    $missingSkills = [System.Collections.Generic.List[string]]::new()
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        foreach ($skill in $skillsByPlatform[$platform]) {
            $skillDir = Join-Path $repo "$($generatedRoots[$platform])/$skill"
            if (-not (Test-Path -LiteralPath $skillDir -PathType Container)) {
                $missingSkills.Add("$($generatedRoots[$platform])/$skill")
            }
        }
    }
    if ($missingSkills.Count -gt 0) {
        throw "Env '$Name' references skills with no generated output: $($missingSkills -join ', '). Run scripts/build-skills.ps1 first."
    }

    $mergedProfile = @{}
    foreach ($chainProfile in @($resolved.ResolvedProfiles)) {
        $mergedProfile = Merge-HarnessProfileObject -Base $mergedProfile -Overlay $chainProfile.Data
    }

    $components = @(Get-HarnessComponents -RepoRoot $repo)
    [void] (Test-HarnessUniqueComponentIds -Components $components)
    $componentIndex = @{}
    foreach ($component in $components) {
        $componentIndex[$component.Id] = $component
    }

    $componentIds = @(Get-HarnessProfileComponentIds -Profile $mergedProfile)
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $componentIds) {
        $safeId = Normalize-HarnessCandidatePath -Candidate $id -AllowedRoot (Join-Path $repo 'harness-source/components') -LeafOnly
        if (-not $componentIndex.ContainsKey($safeId)) {
            throw "Env '$Name' profile chain references unknown component '$id'."
        }
        $selected.Add($componentIndex[$safeId])
    }
    $targetPlatforms = @($mergedProfile.TargetPlatforms)
    [void] (Test-HarnessTargetPlatforms -TargetPlatforms $targetPlatforms -SelectedComponents $selected.ToArray())
    [void] (Test-HarnessRequiresAndConflicts -SelectedComponents $selected.ToArray() -ComponentIndex $componentIndex)

    $componentOutputs = [System.Collections.Generic.List[object]]::new()
    foreach ($component in $selected) {
        if (-not $component.Data.ContainsKey('Outputs')) { continue }
        foreach ($output in @($component.Data.Outputs)) {
            if (-not ($output -is [hashtable]) -or -not $output.ContainsKey('Target') -or -not $output.ContainsKey('Mode')) {
                throw "Component '$($component.Id)' has an output without Target/Mode."
            }
            $componentOutputs.Add([pscustomobject] @{
                    Component = $component
                    Target    = [string] $output.Target
                    Mode      = [string] $output.Mode
                    Output    = $output
                })
        }
    }

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        foreach ($skill in $skillsByPlatform[$platform]) {
            $plan.Add([pscustomobject] @{
                    Kind         = 'CopyDir'
                    RelativePath = "$($generatedRoots[$platform])/$skill"
                    Source       = Join-Path $repo "$($generatedRoots[$platform])/$skill"
                })
        }
    }

    $plan.Add([pscustomobject] @{
            Kind         = 'Text'
            RelativePath = 'manifest.claude.txt'
            Content      = ($skillsByPlatform['Claude'] -join "`n")
        })
    $plan.Add([pscustomobject] @{
            Kind         = 'Text'
            RelativePath = 'manifest.codex.txt'
            Content      = ($skillsByPlatform['Codex'] -join "`n")
        })
    $plan.Add([pscustomobject] @{
            Kind         = 'Text'
            RelativePath = 'manifest.reasonix.txt'
            Content      = ($skillsByPlatform['Reasonix'] -join "`n")
        })

    foreach ($manifestName in @('managed-skills.claude.txt', 'managed-skills.codex.txt', 'managed-skills.reasonix.txt')) {
        $manifestSource = Join-Path $repo "manifests/$manifestName"
        if (-not (Test-Path -LiteralPath $manifestSource -PathType Leaf)) {
            throw "Missing repo manifest required for staging: $manifestSource"
        }
        $plan.Add([pscustomobject] @{
                Kind         = 'CopyFile'
                RelativePath = "manifests/$manifestName"
                Source       = $manifestSource
            })
    }

    foreach ($group in @($componentOutputs | Where-Object { $_.Mode -eq 'ManagedBlock' } | Group-Object Target)) {
        $outputName = if ($group.Name -ieq 'AGENTS.md') {
            'AGENTS.generated.md'
        }
        elseif ($group.Name -ieq 'CLAUDE.md') {
            'CLAUDE.generated.md'
        }
        else {
            ((Split-Path -Leaf $group.Name) -replace '\.md$', '') + '.generated.md'
        }

        $blocks = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in @($group.Group)) {
            $contentPath = Get-HarnessComponentContentPath -Component $entry.Component -FileName 'content.md'
            $content = if ($contentPath) { (Get-Content -Raw -LiteralPath $contentPath).TrimEnd() } else { '' }
            $blockId = if ($entry.Output.ContainsKey('BlockId') -and $entry.Output.BlockId) {
                [string] $entry.Output.BlockId
            }
            else {
                [string] $entry.Component.Id
            }
            $blocks.Add("<!-- BEGIN AGENT-HARNESS: $blockId -->`n$content`n<!-- END AGENT-HARNESS: $blockId -->")
        }
        $plan.Add([pscustomobject] @{
                Kind         = 'Text'
                RelativePath = "profile/$outputName"
                Content      = (($blocks.ToArray() -join "`n`n") + "`n")
            })
    }

    foreach ($group in @($componentOutputs | Where-Object { $_.Mode -eq 'StructuredMerge' } | Group-Object Target)) {
        $merged = [ordered] @{}
        foreach ($entry in @($group.Group)) {
            $settingsPath = Get-HarnessComponentContentPath -Component $entry.Component -FileName 'settings.json'
            if (-not $settingsPath) {
                throw "StructuredMerge component '$($entry.Component.Id)' is missing settings.json."
            }
            $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
            $merged = Merge-HarnessJsonObject -Base $merged -Overlay (ConvertTo-HarnessPlainObject -Value $settings)
        }

        $outputName = if ($group.Name -ieq '.claude/settings.json') {
            'claude-settings.generated.json'
        }
        else {
            ((Split-Path -Leaf $group.Name) -replace '\.json$', '') + '.generated.json'
        }
        $plan.Add([pscustomobject] @{
                Kind         = 'Json'
                RelativePath = "profile/$outputName"
                Object       = $merged
            })
    }

    foreach ($entry in @($componentOutputs | Where-Object { $_.Mode -eq 'GeneratedOnly' })) {
        $contentPath = Get-HarnessComponentContentPath -Component $entry.Component -FileName 'content.md'
        if (-not $contentPath) {
            throw "GeneratedOnly component '$($entry.Component.Id)' is missing content.md."
        }
        $targetRelative = $entry.Target -replace '\\', '/'
        if (-not $targetRelative.StartsWith('.agent-harness/generated/', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "GeneratedOnly target must be under .agent-harness/generated/: $($entry.Target)"
        }
        $generatedRelative = $targetRelative.Substring('.agent-harness/generated/'.Length)
        foreach ($part in ($generatedRelative -split '/')) {
            if ($part -in @('', '.', '..')) {
                throw "GeneratedOnly target contains unsafe path segments: $($entry.Target)"
            }
        }
        $plan.Add([pscustomobject] @{
                Kind         = 'CopyFile'
                RelativePath = "profile/$generatedRelative"
                Source       = $contentPath
            })
    }

    foreach ($item in $plan) {
        $itemDestination = Join-Path $destinationFull ($item.RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        switch ($item.Kind) {
            'Text' {
                Write-HarnessTextFile -Path $itemDestination -Content $item.Content
            }
            'Json' {
                Write-HarnessJsonFile -InputObject $item.Object -Path $itemDestination
            }
            'CopyFile' {
                New-Item -ItemType Directory -Path (Split-Path -Parent $itemDestination) -Force | Out-Null
                Copy-Item -LiteralPath $item.Source -Destination $itemDestination -Force
            }
            'CopyDir' {
                New-Item -ItemType Directory -Path (Split-Path -Parent $itemDestination) -Force | Out-Null
                Copy-Item -LiteralPath $item.Source -Destination $itemDestination -Recurse -Force
            }
            default {
                throw "Unknown plan entry kind: $($item.Kind)"
            }
        }
    }

    foreach ($relativeRoot in @('claude/skills', 'codex/skills', 'reasonix/skills')) {
        New-Item -ItemType Directory -Path (Join-Path $destinationFull $relativeRoot) -Force | Out-Null
    }

    $skillSourceEvidence = Get-HarnessSkillSourceEvidenceStatus -RepoRoot $repo
    $skillSourceHashes = [ordered]@{}
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $platformHashes = [ordered]@{}
        foreach ($skill in $skillsByPlatform[$platform]) {
            $sourceHash = if ($skillSourceEvidence -eq 'available') {
                Get-HarnessSkillSourceHash -RepoRoot $repo -Platform $platform -Name $skill
            }
            else {
                $null
            }
            if ($skillSourceEvidence -eq 'available' -and $null -eq $sourceHash) {
                throw "Env '$Name' cannot record source provenance for $platform skill '$skill'. Source directory is missing."
            }
            $platformHashes[$skill] = $sourceHash
        }
        $skillSourceHashes[$platform] = $platformHashes
    }

    $stagedSkillTreeHashes = [ordered]@{}
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $platformHashes = [ordered]@{}
        foreach ($skill in $skillsByPlatform[$platform]) {
            $platformHashes[$skill] = Get-HarnessTreeHash -Path (Join-Path $destinationFull "$($generatedRoots[$platform])/$skill")
        }
        $stagedSkillTreeHashes[$platform] = $platformHashes
    }

    $lockPath = Get-HarnessEnvLockPath -StagingPath $destinationFull
    $buildPath = Get-HarnessEnvBuildPath -StagingPath $destinationFull
    $builtFiles = @(Get-ChildItem -LiteralPath $destinationFull -File -Recurse -Force)
    $relativeToFull = @{}
    foreach ($file in $builtFiles) {
        $relative = Get-HarnessRelativePath -Root $destinationFull -Path $file.FullName
        if ($relative -ceq 'env.lock.json' -or $relative -ceq 'env-build.json') { continue }
        $relativeToFull[$relative] = $file.FullName
    }
    $builtHashes = [ordered] @{}
    foreach ($relative in (Sort-HarnessOrdinal -Values @($relativeToFull.Keys))) {
        $builtHashes[$relative] = Get-HarnessFileHash -Path $relativeToFull[$relative]
    }
    $lock = [ordered] @{
        SchemaVersion             = 3
        Name                      = $resolved.Name
        DefinitionHash            = Get-HarnessEnvDefinitionHash -Path $definitionPath
        TaskOverlayHash           = $taskOverlay.Hash
        TaskOverlaySkills         = [ordered]@{
            Claude = @($taskOverlay.Skills.Claude)
            Codex = @($taskOverlay.Skills.Codex)
            Reasonix = @($taskOverlay.Skills.Reasonix)
        }
        RepositoryCommit          = Get-HarnessRepositoryCommit -RepoRoot $repo
        ManifestHashes            = Get-HarnessManifestHashes -RepoRoot $repo
        SkillSourceEvidence       = $skillSourceEvidence
        SkillSourceHashes         = $skillSourceHashes
        StagedSkillTreeHashes     = $stagedSkillTreeHashes
        ProfileSourceHash         = Get-HarnessProfileSourceHash -RepoRoot $repo
        ProfileOutputHash         = Get-HarnessTreeHash -Path (Join-Path $destinationFull 'profile')
        BuiltFiles                = $builtHashes
    }
    Write-HarnessJsonFile -InputObject $lock -Path $lockPath

    $materializedRoots = [ordered]@{}
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $relativeRoot = [string] $generatedRoots[$platform]
        $rootPath = Join-Path $destinationFull $relativeRoot
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
            throw ('env-build-missing-platform-root')
        }
        $treeHash = Get-HarnessTreeHash -Path $rootPath
        $fileCount = @(Get-ChildItem -LiteralPath $rootPath -File -Recurse -Force).Count
        $materializedRoots[$platform] = [ordered]@{
            RelativePath = $relativeRoot
            Exists       = $true
            TreeHash     = $treeHash
            FileCount    = $fileCount
        }
    }

    $sidecar = [ordered]@{
        SchemaVersion         = 3
        GeneratedAtUtc        = [DateTime]::UtcNow.ToString('o')
        Name                  = $resolved.Name
        Result                = 'PASS'
        DefinitionHash        = $lock.DefinitionHash
        TaskOverlayHash       = $lock.TaskOverlayHash
        TaskOverlaySkills     = $lock.TaskOverlaySkills
        LockHash              = Get-HarnessFileHash -Path $lockPath
        RepositoryCommit      = $lock.RepositoryCommit
        SkillSourceEvidence   = $lock.SkillSourceEvidence
        FileCount             = $builtHashes.Count
        ManifestHashes        = $lock.ManifestHashes
        SkillSourceHashes     = $lock.SkillSourceHashes
        StagedSkillTreeHashes = $lock.StagedSkillTreeHashes
        MaterializedRoots     = $materializedRoots
    }
    $sidecar['MaterializationHash'] = Get-HarnessEnvMaterializationHash -Document $sidecar
    $sidecarBytes = ConvertTo-SemanticJsonBytes -InputObject $sidecar
    [System.IO.File]::WriteAllText(
        $buildPath,
        ([System.Text.UTF8Encoding]::new($false).GetString($sidecarBytes) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    Test-HarnessEnvBuildSemantics -Document $sidecar
    $null = Read-HarnessEnvBuild -StagingPath $destinationFull

    return [pscustomobject]@{
        Name              = $resolved.Name
        Destination       = $destinationFull
        TaskOverlay       = $taskOverlay
        LockPath          = $lockPath
        BuildPath         = $buildPath
        BuiltFileCount    = $builtHashes.Count
        MaterializationHash = [string] $sidecar.MaterializationHash
    }
}
