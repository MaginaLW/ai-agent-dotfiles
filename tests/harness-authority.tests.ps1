#requires -Version 7.0
<#
.SYNOPSIS
    Phase 3 authority tests: legacy/shared readers, the lock/state artifact graph,
    and the frozen authority contract sets.

.DESCRIPTION
    Self-contained regression tests with no Pester dependency. The lock graph is
    emitter-derived: a real environment is materialized in an isolated fake
    repository under the temp directory, and the emitted env.lock.json/env-build.json
    are inspected directly. State/plan graph and branch assertions read the tracked
    schemas and the registered artifact fixtures. No real home, real envs/ staging,
    real state/ file, or ControlBase is ever touched. The workspace is removed on
    success and kept on failure.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/shared-authority-state-common.ps1')
. (Join-Path $RepoRoot 'scripts/harness-env-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')
# The sealed route registry accepts exactly one initialization per runspace and
# refuses a reload built from fresh script blocks, so the registry home (which
# carries the canonical-transaction surface too) loads once here, in script
# scope, and every sandbox helper below reuses that single load.
. (Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1')

# Policy-state-aware behavioral pins (Phase 4 Task 8 Step 1 preparation): the
# same committed suite bytes assert the interlocked fail-closed contract while
# ReleaseState=interlocked, and each affected surface's observed released
# post-Assert contract once the reviewed release candidate flips the policy.
. (Join-Path $RepoRoot 'scripts/live-safety-interlock.ps1')
$policyState = [string] (Get-LiveSafetyPolicy).ReleaseState
$script:IsReleased = ($policyState -eq 'released')

$script:pass = 0
$script:fail = 0
function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-harness-authority-$([Guid]::NewGuid().ToString('N'))"
function Remove-Work {
    if (($work -like '*ai-agent-dotfiles-harness-authority-*') -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
Remove-Work
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [AllowNull()] [string] $Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value ($Content ?? '') -NoNewline -Encoding UTF8
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)] [string] $Root)
    $lines = foreach ($file in (Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName)) {
        '{0}|{1}' -f $file.FullName, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return ($lines -join "`n")
}

function Read-SchemaDocument {
    param([Parameter(Mandatory)] [string] $Name)
    return (Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "schemas/$Name") | ConvertFrom-Json)
}

function New-EnvDefinitionText {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $ClaudeSkills = @(),
        [string[]] $CodexSkills = @(),
        [string[]] $ReasonixSkills = @()
    )
    function Join-Psd1Array([string[]] $Values) {
        if ($Values.Count -eq 0) { return '@()' }
        return '@(' + (($Values | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ')'
    }
    return @"
@{
    SchemaVersion = 1
    Name = '$Name'
    Description = 'authority test env'
    Profile = 'coding'
    Skills = @{
        Claude = $(Join-Psd1Array $ClaudeSkills)
        Codex = $(Join-Psd1Array $CodexSkills)
        Reasonix = $(Join-Psd1Array $ReasonixSkills)
    }
}
"@
}

function New-FakeHarnessRepo {
    param([Parameter(Mandatory)] [string] $Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize the fake harness repository.' }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/profiles') -Destination (Join-Path $Path 'harness-source/profiles') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components') -Destination (Join-Path $Path 'harness-source/components') -Recurse -Force
    Set-File -Path (Join-Path $Path 'manifests/managed-skills.claude.txt') -Content "fixture-a`nfixture-b`n"
    Set-File -Path (Join-Path $Path 'manifests/managed-skills.codex.txt') -Content "fixture-a`nfixture-b`n"
    Set-File -Path (Join-Path $Path 'manifests/managed-skills.reasonix.txt') -Content "fixture-a`nfixture-b`n"
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        foreach ($skill in @('fixture-a', 'fixture-b')) {
            Set-File -Path (Join-Path $Path "$platform/skills/$skill/SKILL.md") -Content "# $skill ($platform fixture)"
        }
    }
    foreach ($skill in @('fixture-a', 'fixture-b')) {
        Set-File -Path (Join-Path $Path "skills-source/shared/$skill/SKILL.md") -Content "# $skill (source fixture)"
    }
    return $Path
}

$fixtureRoot = Join-Path $RepoRoot 'tests/fixtures/artifacts'
function Get-FixtureBytes([string] $Name) {
    return [System.IO.File]::ReadAllBytes((Join-Path $fixtureRoot $Name))
}

# ==============================================================================
Write-Host 'legacy reader: repo-local schema 2 evidence only'
$legacyRepo = Join-Path $work 'legacy-repo'
New-Item -ItemType Directory -Path (Join-Path $legacyRepo 'state') -Force | Out-Null
$legacyStatePath = Join-Path $legacyRepo 'state/current-env.json'

$legacyMissing = Read-LegacyHarnessEnvState -RepoRoot $legacyRepo
Assert ([string] $legacyMissing.Status -ceq 'MISSING') 'legacy reader reports MISSING without a state file'
Assert ($null -eq $legacyMissing.Bytes -and $null -eq $legacyMissing.BytesHash -and $null -eq $legacyMissing.Document) 'MISSING legacy read carries no bytes, hash, or document'

$legacyText = '{"SchemaVersion":2,"Name":"work","HomeRoot":"C:\\Users\\fixture"}'
Set-File -Path $legacyStatePath -Content $legacyText
$legacyValid = Read-LegacyHarnessEnvState -RepoRoot $legacyRepo
Assert ([string] $legacyValid.Status -ceq 'VALID') 'legacy reader accepts a schema 2 state with a name'
Assert ([string] $legacyValid.Document['Name'] -ceq 'work') 'legacy reader returns the parsed document'
$expectedLegacyHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($legacyStatePath))).ToLowerInvariant()
Assert ([string] $legacyValid.BytesHash -ceq $expectedLegacyHash) 'legacy reader binds the exact file bytes hash'
Assert ([string] $legacyValid.Path -ceq $legacyStatePath) 'legacy reader resolves the repo-local locator'

Set-File -Path $legacyStatePath -Content '{"SchemaVersion":3,"Name":"work"}'
Assert ([string] (Read-LegacyHarnessEnvState -RepoRoot $legacyRepo).Status -ceq 'CORRUPT') 'legacy reader rejects a schema 3 document'
Set-File -Path $legacyStatePath -Content '{"SchemaVersion":2}'
Assert ([string] (Read-LegacyHarnessEnvState -RepoRoot $legacyRepo).Status -ceq 'CORRUPT') 'legacy reader rejects a state without a name'
Set-File -Path $legacyStatePath -Content '{ corrupt'
$legacyCorrupt = Read-LegacyHarnessEnvState -RepoRoot $legacyRepo
Assert ([string] $legacyCorrupt.Status -ceq 'CORRUPT') 'legacy reader reports CORRUPT for unparsable bytes'
Assert ($null -ne $legacyCorrupt.Bytes) 'CORRUPT legacy read still returns the captured bytes'
Assert (Test-Path -LiteralPath $legacyStatePath -PathType Leaf) 'legacy reader never deletes or moves the legacy file'

# A valid shared ControlBase state is invisible to the legacy reader: were it to
# fall back to the shared locator, this read would report VALID instead of MISSING.
$sharedControlBase = Join-Path $work 'control'
$sharedKey = 'a' * 64
$sharedAuthorityRoot = Join-Path (Join-Path $sharedControlBase 'homes') $sharedKey
New-Item -ItemType Directory -Path $sharedAuthorityRoot -Force | Out-Null
Set-File -Path (Join-Path $sharedAuthorityRoot 'current-env.json') -Content '{"SchemaVersion":2,"Name":"shared-stub"}'
Remove-Item -LiteralPath $legacyStatePath -Force
$legacyBlind = Read-LegacyHarnessEnvState -RepoRoot $legacyRepo
Assert ([string] $legacyBlind.Status -ceq 'MISSING') 'legacy reader never falls back to the shared ControlBase state'
Assert ($null -eq $legacyBlind.Document) 'legacy reader returns no document when only a shared state exists'
Remove-Item -LiteralPath (Join-Path $sharedAuthorityRoot 'current-env.json') -Force

# ==============================================================================
Write-Host 'shared reader: ControlBase schema 3 state and separate claims'
$claimsBytes = Get-FixtureBytes 'root-claims.valid.json'
$stateBytes = Get-FixtureBytes 'current-env-state.valid.json'
$claimsDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($claimsBytes))
$stateDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($stateBytes))
$validKey = [string] $claimsDocument['HomeAuthorityKey']
$validAuthorityRoot = Join-Path (Join-Path $sharedControlBase 'homes') $validKey
New-Item -ItemType Directory -Path $validAuthorityRoot -Force | Out-Null
$sharedStatePath = Join-Path $validAuthorityRoot 'current-env.json'
$sharedClaimsPath = Join-Path $validAuthorityRoot 'root-claims.json'

$sharedMissing = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
Assert ([string] $sharedMissing.ClaimsStatus -ceq 'MISSING' -and [string] $sharedMissing.StateStatus -ceq 'MISSING') 'shared reader reports MISSING claims and state without files'
Assert ([string] $sharedMissing.PairStatus -ceq 'MISSING') 'shared reader reports MISSING pair without files'

[System.IO.File]::WriteAllBytes($sharedClaimsPath, $claimsBytes)
$sharedClaimsOnly = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
Assert ([string] $sharedClaimsOnly.ClaimsStatus -ceq 'VALID') 'shared reader validates a standalone claims file'
Assert ([string] $sharedClaimsOnly.StateStatus -ceq 'MISSING') 'shared reader keeps a missing state distinct from valid claims'
Assert ([string] $sharedClaimsOnly.PairStatus -ceq 'MISSING') 'claims without state is not a valid authority pair'

[System.IO.File]::WriteAllBytes($sharedStatePath, $stateBytes)
$sharedValid = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
Assert ([string] $sharedValid.ClaimsStatus -ceq 'VALID' -and [string] $sharedValid.StateStatus -ceq 'VALID') 'shared reader validates the complete authority pair'
Assert ([string] $sharedValid.PairStatus -ceq 'VALID') 'shared reader confirms the state binds the exact claims bytes'
Assert ([string] $sharedValid.ClaimsBytesHash -ceq [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($claimsBytes)).ToLowerInvariant()) 'shared reader claims hash matches SHA-256 of the exact claims bytes'
Assert ([string] $sharedValid.StateDocument['EnvironmentName'] -ceq 'full') 'shared reader returns the parsed state document'

# A state that stays schema-valid but binds different claims bytes is a MISMATCH.
$mismatchState = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($stateBytes))
$mismatchState['RootClaimsHash'] = '0' * 64
[System.IO.File]::WriteAllBytes($sharedStatePath, (ConvertTo-SemanticJsonBytes -InputObject $mismatchState))
$sharedMismatch = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
Assert ([string] $sharedMismatch.StateStatus -ceq 'VALID') 'schema-valid state binding other claims stays VALID per artifact'
Assert ([string] $sharedMismatch.PairStatus -ceq 'MISMATCH') 'state that does not bind the exact claims bytes is a MISMATCH'

# The identity half of the pair contract: identical claims bytes, drifted identity,
# and a recomputed FinalTargetContextHash so only the binding to root-claims is wrong.
$identityDriftState = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($stateBytes))
$driftedIdentities = @($identityDriftState['FinalResolvedIdentities'])
$driftedIdentities[2]['ResolvedPath'] = 'C:\fixture\drifted\reasonix\skills'
$driftedIdentities[2]['LocationKey'] = 'c:/fixture/drifted/reasonix/skills'
$identityDriftState['FinalResolvedIdentities'] = $driftedIdentities
$identityDriftState['FinalTargetContextHash'] = Get-SemanticJsonHash -InputObject @($identityDriftState['FinalResolvedIdentities'])
[System.IO.File]::WriteAllBytes($sharedStatePath, (ConvertTo-SemanticJsonBytes -InputObject $identityDriftState))
$identityDrift = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
Assert ([string] $identityDrift.StateStatus -ceq 'VALID') 'identity-drifted state stays valid per artifact'
Assert ([string] $identityDrift.PairStatus -ceq 'MISMATCH') 'state whose final identities do not match claims is a MISMATCH'

Set-File -Path $sharedStatePath -Content '{ corrupt'
$sharedCorruptState = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
Assert ([string] $sharedCorruptState.ClaimsStatus -ceq 'VALID' -and [string] $sharedCorruptState.StateStatus -ceq 'CORRUPT') 'shared reader reports corrupt state with valid claims'
Assert ([string] $sharedCorruptState.PairStatus -ceq 'CORRUPT') 'corrupt state is never a valid authority pair'
Assert (-not [string]::IsNullOrWhiteSpace([string] $sharedCorruptState.StateError)) 'corrupt state carries a diagnostic message'

[System.IO.File]::WriteAllBytes($sharedStatePath, $stateBytes)
Set-File -Path $sharedClaimsPath -Content '{"SchemaVersion":1}'
$sharedCorruptClaims = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
Assert ([string] $sharedCorruptClaims.ClaimsStatus -ceq 'CORRUPT') 'shared reader reports corrupt claims'
Assert ([string] $sharedCorruptClaims.PairStatus -ceq 'CORRUPT') 'corrupt claims are never a valid authority pair'

Remove-Item -LiteralPath $sharedStatePath -Force
$claimsCorruptStateMissing = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
Assert ([string] $claimsCorruptStateMissing.ClaimsStatus -ceq 'CORRUPT' -and [string] $claimsCorruptStateMissing.StateStatus -ceq 'MISSING') 'corrupt claims with a missing state stay two independent statuses'
Assert ([string] $claimsCorruptStateMissing.PairStatus -ceq 'CORRUPT') 'corrupt claims with a missing state is never a valid authority pair'

[System.IO.File]::WriteAllBytes($sharedStatePath, $stateBytes)
Remove-Item -LiteralPath $sharedClaimsPath -Force
$claimsMissingStateValid = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
Assert ([string] $claimsMissingStateValid.ClaimsStatus -ceq 'MISSING' -and [string] $claimsMissingStateValid.StateStatus -ceq 'VALID') 'state without claims stays a valid state artifact with missing claims'
Assert ([string] $claimsMissingStateValid.PairStatus -ceq 'MISSING') 'state without claims is never a valid authority pair'
[System.IO.File]::WriteAllBytes($sharedClaimsPath, $claimsBytes)

$badKeyRejected = $false
try { $null = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey '../escape' -RepoRoot $RepoRoot }
catch { $badKeyRejected = $true }
Assert $badKeyRejected 'shared reader rejects a non-hash authority key'
$relativeBaseRejected = $false
try { $null = Read-HomeAuthorityState -ControlBase 'relative/control' -HomeAuthorityKey $validKey -RepoRoot $RepoRoot }
catch { $relativeBaseRejected = $true }
Assert $relativeBaseRejected 'shared reader rejects a non-fully-qualified ControlBase'
$uncBaseRejected = $false
try { $null = Read-HomeAuthorityState -ControlBase '\\server\share\control' -HomeAuthorityKey $validKey -RepoRoot $RepoRoot }
catch { $uncBaseRejected = $true }
Assert $uncBaseRejected 'shared reader rejects a UNC ControlBase'

# The directory key must match the claims document, not just name the path segment.
$foreignRoot = Join-Path (Join-Path $sharedControlBase 'homes') ('b' * 64)
New-Item -ItemType Directory -Path $foreignRoot -Force | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $foreignRoot 'root-claims.json'), $claimsBytes)
[System.IO.File]::WriteAllBytes((Join-Path $foreignRoot 'current-env.json'), $stateBytes)
$keyMismatch = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey ('b' * 64) -RepoRoot $RepoRoot
Assert ([string] $keyMismatch.ClaimsStatus -ceq 'VALID' -and [string] $keyMismatch.StateStatus -ceq 'VALID') 'a copied pair under a foreign key stays valid per artifact'
Assert ([string] $keyMismatch.PairStatus -ceq 'MISMATCH') 'the directory key must match the claims document'
Remove-Item -LiteralPath $foreignRoot -Recurse -Force

# The reader is read-only for both artifacts and never touches the legacy locator.
[System.IO.File]::WriteAllBytes($sharedClaimsPath, $claimsBytes)
[System.IO.File]::WriteAllBytes($sharedStatePath, $stateBytes)
$sharedSnapshotBefore = Get-TreeSnapshot -Root $sharedControlBase
$null = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
$sharedSnapshotAfter = Get-TreeSnapshot -Root $sharedControlBase
Assert ($sharedSnapshotBefore -eq $sharedSnapshotAfter) 'shared reader leaves every ControlBase file byte-identical'
Assert ([string] (Read-LegacyHarnessEnvState -RepoRoot $validAuthorityRoot).Status -ceq 'MISSING') 'legacy reader sees no legacy state under a ControlBase tree'

# ==============================================================================
Write-Host 'shared reader: exhaustive pair-status matrix'
$statusMatrixCases = 0
foreach ($claimsStatus in @('MISSING', 'CORRUPT', 'UNAVAILABLE', 'VALID')) {
    foreach ($stateStatus in @('MISSING', 'CORRUPT', 'UNAVAILABLE', 'VALID')) {
        foreach ($keyMatches in @($false, $true)) {
            foreach ($artifactsMatch in @($false, $true)) {
                $expected = 'MISSING'
                if ($claimsStatus -ceq 'UNAVAILABLE' -or $stateStatus -ceq 'UNAVAILABLE') { $expected = 'UNAVAILABLE' }
                elseif ($claimsStatus -ceq 'CORRUPT' -or $stateStatus -ceq 'CORRUPT') { $expected = 'CORRUPT' }
                elseif ($claimsStatus -ceq 'VALID' -and $stateStatus -ceq 'VALID') {
                    $expected = if ($keyMatches -and $artifactsMatch) { 'VALID' } else { 'MISMATCH' }
                }
                $actual = Resolve-HomeAuthorityPairStatus -ClaimsStatus $claimsStatus -StateStatus $stateStatus -KeyMatches $keyMatches -ArtifactsMatch $artifactsMatch
                if ([string] $actual -cne $expected) {
                    Write-Host "  FAIL  pair matrix $claimsStatus/$stateStatus key=$keyMatches artifacts=$artifactsMatch expected $expected got $actual" -ForegroundColor Red
                    $script:fail++
                }
                $statusMatrixCases++
            }
        }
    }
}
Assert ($script:fail -eq 0) "pair-status matrix: all $statusMatrixCases combinations map to their documented status"

# ==============================================================================
Write-Host 'lock graph: emitter-derived environment lock and build sidecar'
$harnessRepo = New-FakeHarnessRepo -Path (Join-Path $work 'harness-repo')
$envRoot = Join-Path $harnessRepo 'harness-source/envs'
Set-File -Path (Join-Path $envRoot 'good.psd1') -Content (New-EnvDefinitionText -Name 'good' -ClaudeSkills @('fixture-b', 'fixture-a') -CodexSkills @('fixture-a') -ReasonixSkills @('fixture-a'))
$goodStaging = Join-Path $harnessRepo 'envs/good'
$materialized = Invoke-HarnessEnvMaterialization -Name 'good' -Destination $goodStaging -RepoRoot $harnessRepo
Assert ($null -ne $materialized) 'emitter materializes the good environment'

$lockPath = Get-HarnessEnvLockPath -StagingPath $goodStaging
$sidecarPath = Get-HarnessEnvBuildPath -StagingPath $goodStaging
$lockBytes = [System.IO.File]::ReadAllBytes($lockPath)
$lock = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($lockBytes))
$lockKeys = @($lock.Keys | Sort-Object { [string] $_ })

$schemaRoot = Join-Path $RepoRoot 'schemas'
$lockSchemaPath = Join-Path $schemaRoot 'harness-env-lock.schema.json'
$lockSchema = Read-SchemaDocument 'harness-env-lock.schema.json'
$expectedLockKeys = @($lockSchema.required | Sort-Object { [string] $_ })
Assert (($lockKeys -join ',') -ceq ($expectedLockKeys -join ',')) 'emitted lock carries exactly the frozen schema 3 semantic field set'
$lockValidation = Test-RepositoryJsonSchema -SchemaPath $lockSchemaPath -SchemaRoot $schemaRoot
$lockSchemaOk = $true
try { $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $lockValidation -InstanceBytes $lockBytes -InstancePath 'harness-authority.lock.in-memory.json' }
catch { $lockSchemaOk = $false; Write-Host "  note  emitted lock failed schema validation: $($_.Exception.Message)" }
Assert $lockSchemaOk 'emitted lock validates against the frozen schema 3'

foreach ($forbidden in @('LockHash', 'MaterializationHash', 'PlanHash', 'DocumentHash', 'ReceiptId', 'ReceiptHash', 'JournalId', 'PreStatePhaseHash', 'AuthorityStateHash', 'TargetContextIntent')) {
    Assert ($lockKeys -notcontains $forbidden) "lock carries no $forbidden graph field"
}

foreach ($mapName in @('ManifestHashes', 'SkillSourceHashes', 'StagedSkillTreeHashes', 'TaskOverlaySkills')) {
    $platforms = @($lock[$mapName].Keys | Sort-Object { [string] $_ })
    Assert (($platforms -join ',') -ceq 'Claude,Codex,Reasonix') "lock $mapName covers all three platforms"
}
$expectedSkillsByPlatform = [ordered] @{ Claude = 'fixture-a,fixture-b'; Codex = 'fixture-a'; Reasonix = 'fixture-a' }
foreach ($mapName in @('SkillSourceHashes', 'StagedSkillTreeHashes')) {
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $skillKeys = @($lock[$mapName][$platform].Keys | Sort-Object { [string] $_ })
        Assert (($skillKeys -join ',') -ceq $expectedSkillsByPlatform[$platform]) "lock $mapName $platform enumerates exactly the selected skills"
    }
}
Assert ([string] $lock['SkillSourceEvidence'] -ceq 'available') 'lock records available skill-source evidence'
Assert ([string] $lock['Name'] -ceq 'good') 'lock records the environment name'
Assert (@($lock['TaskOverlaySkills']['Reasonix']).Count -eq 0) 'lock records the empty Reasonix task baseline explicitly'
Assert (@($lock['BuiltFiles'].Keys).Count -gt 0) 'lock enumerates the built staging files'

$generatedRoots = [ordered] @{ Claude = 'claude/skills'; Codex = 'codex/skills'; Reasonix = 'reasonix/skills' }
foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
    $manifestPath = Join-Path $harnessRepo "manifests/managed-skills.$($platform.ToLowerInvariant()).txt"
    $manifestHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($manifestPath))).ToLowerInvariant()
    Assert ([string] $lock['ManifestHashes'][$platform] -ieq $manifestHash) "lock $platform manifest hash binds the manifest bytes"
    foreach ($skill in @($lock['StagedSkillTreeHashes'][$platform].Keys)) {
        $stagedSkillPath = Join-Path $goodStaging "$($generatedRoots[$platform])/$skill"
        Assert ([string] $lock['StagedSkillTreeHashes'][$platform][$skill] -ceq (Get-HarnessTreeHash -Path $stagedSkillPath)) "lock $platform staged tree hash binds the $skill content"
    }
    foreach ($skill in @($lock['SkillSourceHashes'][$platform].Keys)) {
        Assert ([string] $lock['SkillSourceHashes'][$platform][$skill] -ceq (Get-HarnessSkillSourceHash -RepoRoot $harnessRepo -Platform $platform -Name $skill)) "lock $platform source hash binds the $skill source tree"
    }
}
$stagedFiles = @(Get-ChildItem -LiteralPath $goodStaging -File -Recurse -Force | Where-Object { $_.Name -ne 'env.lock.json' -and $_.Name -ne 'env-build.json' })
Assert (@($lock['BuiltFiles'].Keys).Count -eq $stagedFiles.Count) 'lock enumerates every staged file except the lock and sidecar'
foreach ($file in $stagedFiles) {
    $relative = Get-HarnessRelativePath -Root $goodStaging -Path $file.FullName
    $fileHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($file.FullName))).ToLowerInvariant()
    Assert ([string] $lock['BuiltFiles'][$relative] -ieq $fileHash) "lock built-file hash binds $relative"
}
Assert ([string] $lock['ProfileOutputHash'] -ceq (Get-HarnessTreeHash -Path (Join-Path $goodStaging 'profile'))) 'lock profile output hash binds the staged profile tree'

$sidecar = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($sidecarPath)))
$sidecarLockHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($lockBytes)).ToLowerInvariant()
Assert ([string] $sidecar['LockHash'] -ieq $sidecarLockHash) 'build sidecar binds the exact emitted lock bytes'
Assert ([string] $sidecar['MaterializationHash'] -ceq (Get-HarnessEnvMaterializationHash -Document $sidecar)) 'build sidecar self-hash excludes GeneratedAtUtc and itself'
$sidecarGateOk = $true
try { Test-HarnessEnvBuildSemantics -Document $sidecar }
catch { $sidecarGateOk = $false; Write-Host "  note  emitted build sidecar failed the semantic gate: $($_.Exception.Message)" }
Assert $sidecarGateOk 'emitted build sidecar passes the v3 semantic gate'
foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
    Assert ([bool] $sidecar['MaterializedRoots'][$platform]['Exists'] -eq $true) "build sidecar records a materialized $platform root"
}

Write-Host 'lock graph: emitter-derived v3 negatives'
$v2Sidecar = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($sidecarPath)))
$v2Sidecar['SchemaVersion'] = 2
$v2Rejected = $false
try { Test-HarnessEnvBuildSemantics -Document $v2Sidecar } catch { $v2Rejected = $_.Exception.Message -match 'env-build-schema-unsupported' }
Assert $v2Rejected 'emitter-derived v2 build evidence is rejected as unsupported'

$rootMissing = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($sidecarPath)))
$null = $rootMissing['MaterializedRoots'].Remove('Reasonix')
$rootRejected = $false
try { Test-HarnessEnvBuildSemantics -Document $rootMissing } catch { $rootRejected = $_.Exception.Message -match 'env-build-missing-platform-root' }
Assert $rootRejected 'emitter-derived build evidence without the Reasonix root is rejected'

$hashDrift = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($sidecarPath)))
$hashDrift['MaterializationHash'] = '0' * 64
$driftRejected = $false
try { Test-HarnessEnvBuildSemantics -Document $hashDrift } catch { $driftRejected = $_.Exception.Message -match 'env-build-hash-mismatch' }
Assert $driftRejected 'emitter-derived build evidence with a drifted MaterializationHash is rejected'

Write-Host 'lock graph: empty platform subset still materializes'
$emptyDefinition = Join-Path $envRoot 'empty-rx.psd1'
Set-File -Path $emptyDefinition -Content (New-EnvDefinitionText -Name 'empty-rx' -ClaudeSkills @('fixture-a') -CodexSkills @('fixture-a'))
$emptyStaging = Join-Path $harnessRepo 'envs/empty-rx'
$null = Invoke-HarnessEnvMaterialization -Name 'empty-rx' -Destination $emptyStaging -RepoRoot $harnessRepo
$emptySidecar = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Get-HarnessEnvBuildPath -StagingPath $emptyStaging))))
Assert ([bool] $emptySidecar['MaterializedRoots']['Reasonix']['Exists'] -eq $true) 'empty Reasonix subset still materializes its root'
Assert ([long] $emptySidecar['MaterializedRoots']['Reasonix']['FileCount'] -eq 0) 'empty Reasonix subset reports zero files'
$emptyLockBytes = [System.IO.File]::ReadAllBytes((Get-HarnessEnvLockPath -StagingPath $emptyStaging))
$emptyLock = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($emptyLockBytes))
$emptyLockSchemaOk = $true
try { $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $lockValidation -InstanceBytes $emptyLockBytes -InstancePath 'harness-authority.empty-lock.in-memory.json' }
catch { $emptyLockSchemaOk = $false; Write-Host "  note  empty-subset lock failed schema validation: $($_.Exception.Message)" }
Assert $emptyLockSchemaOk 'lock for an empty platform subset validates against schema 3'
Assert (@($emptyLock['StagedSkillTreeHashes']['Reasonix'].Keys).Count -eq 0) 'lock records the empty Reasonix staged map'

# ==============================================================================
Write-Host 'state graph: state references only pre-state artifacts'
$fixturePairOk = $true
try { Test-CurrentEnvStateAgainstRootClaims -StateDocument $stateDocument -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes }
catch { $fixturePairOk = $false; Write-Host "  note  fixture pair failed the pair contract: $($_.Exception.Message)" }
Assert $fixturePairOk 'registered valid claims/state fixtures pass the exact-byte pair contract'

$stateKeys = @($stateDocument.Keys)
$stateSchema = Read-SchemaDocument 'current-env-state.schema.json'
$expectedStateKeys = @($stateSchema.required | Sort-Object { [string] $_ })
$receiptBearingKinds = @('environment', 'task-overlay', 'migrate', 'adopt', 'repair-adopt', 'retirement', 'environment-rollback')
$runtimeKeys = if ([string] $stateDocument['LastOperationKind'] -ceq 'controller-transition') { @('ReceiptRef') } else { @('ReceiptId', 'ReceiptHash') }
$allowedStateKeys = @(@($expectedStateKeys) + @($runtimeKeys) | Sort-Object { [string] $_ })
Assert ((@($stateKeys | Sort-Object { [string] $_ }) -join ',') -ceq ($allowedStateKeys -join ',')) 'state carries exactly the frozen branch key set'
foreach ($forbidden in @('AuthorityStateHash', 'StateHash', 'TargetContextIntent', 'AuthorityStateIntent', 'LockHash', 'MaterializationHash')) {
    Assert ($stateKeys -notcontains $forbidden) "state stores no $forbidden"
}
Assert ([string] $stateDocument['RootClaimsHash'] -ceq [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($claimsBytes)).ToLowerInvariant()) 'state binds the exact root-claims file bytes'
Assert ([string] $stateDocument['FinalTargetContextHash'] -ceq (Get-SemanticJsonHash -InputObject @($stateDocument['FinalResolvedIdentities']))) 'state binds its own final identities projection'
Assert ([string] $stateDocument['EnvironmentLockHash'] -cnotmatch '\A0{64}\z') 'state references a real environment lock hash'
Assert ([string] $stateDocument['SelectionKind'] -ceq 'environment') 'state keeps the single environment selection kind'
Assert (@($stateDocument['FinalManagedHashes']).Count -eq 3) 'state records final managed hashes for all three platforms'
Assert (@($stateDocument['ManifestHashes']).Count -eq 3) 'state records manifest hashes for all three platforms'

Write-Host 'state graph: registered negatives reject the graph violations'
$contractsRegistry = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'schemas/artifact-contracts.psd1')
$stateContract = $contractsRegistry.Contracts['current-env-state']
$stateNegativeNames = @($stateContract.NegativeFixtures | ForEach-Object { [string] $_.Name })
foreach ($requiredNegative in @('self-hash', 'target-intent', 'final-target-hash', 'unknown-property', 'live-recover-kind')) {
    Assert ($stateNegativeNames -contains $requiredNegative) "state contract registers the $requiredNegative negative"
}
$stateFixtureNames = @(Get-ChildItem -LiteralPath $fixtureRoot -File -Filter 'current-env-state.*.json' | ForEach-Object { $_.Name })
foreach ($case in @('self-hash', 'target-intent', 'final-target-hash')) {
    Assert ($stateFixtureNames -contains "current-env-state.$case.invalid.json") "state graph violation fixture exists: $case"
}

# ==============================================================================
Write-Host 'frozen branches: sync-plan authority operation kinds'
$planSchema = Read-SchemaDocument 'sync-plan.schema.json'
$frozenOperationKinds = @('initial', 'environment', 'task-overlay', 'migrate', 'adopt', 'repair-adopt', 'controller-transition', 'retirement')
$planKinds = @($planSchema.'$defs'.operationKind.enum)
Assert (($planKinds -join ',') -ceq ($frozenOperationKinds -join ',')) 'sync-plan freezes the exact operation-kind enum'
Assert ($planKinds -notcontains 'environment-rollback') 'environment-rollback never uses sync-plan'
foreach ($closingKind in @('live-recover-status', 'live-recover-abandon', 'live-recover-rollback', 'live-recover-finalize')) {
    Assert ($planKinds -notcontains $closingKind) "$closingKind is never a sync-plan operation kind"
}

$planBranches = @{}
foreach ($branch in @($planSchema.'$defs'.planPayload.oneOf)) {
    $kindProperty = $branch.properties.OperationKind
    if ($kindProperty.PSObject.Properties.Name -notcontains 'const') { continue }
    $kind = [string] $kindProperty.const
    $planBranches[$kind] = @($branch.required | Where-Object { [string] $_ -cne 'OperationKind' } | Sort-Object { [string] $_ })
}
Assert ($planBranches.Keys.Count -eq $frozenOperationKinds.Count) 'every frozen operation kind has exactly one plan branch'
$expectedEvidence = [ordered] @{
    'migrate'              = @('EnvironmentMaterializationRoot', 'EnvironmentName', 'LegacyCoreHash', 'LegacyHash', 'LegacyLocator', 'OldLockHash')
    'adopt'                = @('EnvironmentName', 'LegacyEvidence')
    'repair-adopt'         = @('EnvironmentName', 'StateEvidence')
    'controller-transition' = @('ControllerParity')
}
foreach ($kind in $expectedEvidence.Keys) {
    $actual = @($planBranches[$kind])
    Assert (($actual -join ',') -ceq (@($expectedEvidence[$kind]) -join ',')) "sync-plan $kind branch requires exactly its fixed evidence fields"
}

Write-Host 'frozen branches: shared state committed-state branches'
$stateKinds = @($stateSchema.properties.LastOperationKind.enum)
$frozenStateKinds = @('initial', 'environment', 'task-overlay', 'migrate', 'adopt', 'repair-adopt', 'retirement', 'environment-rollback', 'controller-transition')
Assert (($stateKinds -join ',') -ceq ($frozenStateKinds -join ',')) 'state freezes the exact committed-state operation kinds'
foreach ($closingKind in @('live-recover-status', 'live-recover-abandon', 'live-recover-rollback', 'live-recover-finalize')) {
    Assert ($stateKinds -notcontains $closingKind) "$closingKind is never a committed state branch"
}
$stateBranches = @($stateSchema.oneOf)
Assert ($stateBranches.Count -eq 3) 'state declares exactly three receipt/reference branches'
$stateBranchProjections = foreach ($branch in $stateBranches) {
    $kindProperty = $branch.properties.LastOperationKind
    [pscustomobject] @{
        Const = if ($kindProperty.PSObject.Properties.Name -contains 'const') { [string] $kindProperty.const } else { $null }
        Enum = if ($kindProperty.PSObject.Properties.Name -contains 'enum') { @($kindProperty.enum) } else { @() }
        Required = @($branch.required)
        EnvironmentNameConst = if ($branch.properties.PSObject.Properties.Name -contains 'EnvironmentName' -and $branch.properties.EnvironmentName.PSObject.Properties.Name -contains 'const') { [string] $branch.properties.EnvironmentName.const } else { $null }
        ForbiddenReceiptKeys = if ($null -ne $branch.not -and $branch.not.PSObject.Properties.Name -contains 'anyOf') { @($branch.not.anyOf | ForEach-Object { [string] $_.required }) } else { @() }
    }
}
$initialBranch = @($stateBranchProjections | Where-Object { $_.Const -ceq 'initial' })
Assert ($initialBranch.Count -eq 1) 'the initial branch pins LastOperationKind'
Assert ([string] $initialBranch[0].EnvironmentNameConst -ceq 'full') 'only the initial branch pins the named full environment'
Assert ((@($initialBranch[0].Required | Sort-Object { [string] $_ }) -join ',') -ceq 'ReceiptHash,ReceiptId') 'the initial branch requires a receipt id and hash'
$receiptBranch = @($stateBranchProjections | Where-Object { $null -eq $_.Const -and $_.Enum.Count -gt 0 })
Assert ($receiptBranch.Count -eq 1) 'the receipt-bearing branch enumerates its kinds'
Assert ((@($receiptBranch[0].Enum) -join ',') -ceq ($receiptBearingKinds -join ',')) 'the receipt-bearing branch enumerates exactly the frozen kinds'
$controllerBranch = @($stateBranchProjections | Where-Object { $_.Const -ceq 'controller-transition' })
Assert ($controllerBranch.Count -eq 1) 'the controller-transition branch exists'
Assert ((@($controllerBranch[0].Required) -join ',') -ceq 'ReceiptRef') 'controller-transition requires the no-live-mutation receipt reference'
Assert ((@($controllerBranch[0].ForbiddenReceiptKeys) -join ',') -ceq 'ReceiptId,ReceiptHash') 'controller-transition forbids receipt id and hash'
Assert ([string] $stateSchema.properties.ReceiptRef.const -ceq 'NO_LIVE_MUTATION') 'the receipt reference is pinned to NO_LIVE_MUTATION'

# ==============================================================================
Write-Host 'authority routing: read-only route matrix over a sealed fake home'
. (Join-Path $RepoRoot 'scripts/harness-authority-status-common.ps1')

function New-AuthorityTestIdentity {
    param([Parameter(Mandatory)] [string] $Path)

    New-Item -ItemType Directory -Path (Join-Path $Path 'AppData/Local') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Path 'AppData/Roaming') -Force | Out-Null
    return [pscustomobject][ordered] @{
        ResolverVersion = 'sealed-home-authority-test-adapter-v1'
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ProfileRoot = $Path
        RoamingAppDataRoot = (Join-Path $Path 'AppData/Roaming')
        LocalAppDataRoot = (Join-Path $Path 'AppData/Local')
    }
}

function New-ManagedLiveSkill {
    param(
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $PlatformKey,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Content
    )
    $root = if ($PlatformKey -ceq 'reasonix') { Join-Path $HomeRoot 'AppData/Roaming/reasonix/skills' } else { Join-Path $HomeRoot ".$PlatformKey/skills" }
    Set-File -Path (Join-Path $root "$Name/SKILL.md") -Content $Content
}

function New-LegacyActivationFixture {
    <#
    Builds one internally consistent legacy schema 2 activation: live managed
    skills, the old schema 3 activation lock whose staged hashes match those live
    trees, and the repo-local legacy state whose LockHash binds that lock.
    #>
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $Name
    )

    $skills = [ordered] @{
        Claude = @('fixture-a', 'fixture-b')
        Codex = @('fixture-a')
        Reasonix = @('fixture-a')
    }
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $key = $platform.ToLowerInvariant()
        foreach ($skill in $skills[$platform]) {
            New-ManagedLiveSkill -HomeRoot $HomeRoot -PlatformKey $key -Name $skill -Content "# $skill ($key live)"
        }
    }
    $staged = [ordered] @{}
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $key = $platform.ToLowerInvariant()
        $platformHashes = [ordered] @{}
        foreach ($skill in $skills[$platform]) {
            $root = if ($key -ceq 'reasonix') { Join-Path $HomeRoot 'AppData/Roaming/reasonix/skills' } else { Join-Path $HomeRoot ".$key/skills" }
            $platformHashes[$skill] = Get-HarnessTreeHash -Path (Join-Path $root $skill)
        }
        $staged[$platform] = $platformHashes
    }

    $commit = Get-HarnessRepositoryCommit -RepoRoot $RepoRoot
    $definitionHash = Get-HarnessEnvDefinitionHash -Path (Join-Path $RepoRoot 'harness-source/envs/good.psd1')
    $manifestHashes = Get-HarnessManifestHashes -RepoRoot $RepoRoot
    $lock = [ordered] @{
        SchemaVersion = 3
        Name = $Name
        DefinitionHash = $definitionHash
        TaskOverlayHash = $null
        TaskOverlaySkills = [ordered] @{ Claude = @(); Codex = @(); Reasonix = @() }
        RepositoryCommit = $commit
        ManifestHashes = $manifestHashes
        SkillSourceEvidence = 'available'
        SkillSourceHashes = [ordered] @{ Claude = [ordered] @{}; Codex = [ordered] @{}; Reasonix = [ordered] @{} }
        StagedSkillTreeHashes = $staged
        ProfileSourceHash = $null
        ProfileOutputHash = $null
        BuiltFiles = [ordered] @{}
    }
    $lockPath = Join-Path (Join-Path $RepoRoot 'envs') (Join-Path $Name 'env.lock.json')
    Set-File -Path $lockPath -Content ([System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $lock)))
    $lockHash = Get-HarnessFileHash -Path $lockPath

    $legacy = [ordered] @{
        SchemaVersion = 2
        Name = $Name
        DefinitionHash = $definitionHash
        TaskOverlayHash = $null
        TaskOverlaySkills = [ordered] @{ Claude = @(); Codex = @(); Reasonix = @() }
        LockHash = $lockHash
        RepositoryCommit = $commit
        ManifestHashes = $manifestHashes
        ProfileOutputHash = $null
        BackupReference = 'backup-fixture'
        ActivatedAtUtc = '2026-09-01T00:00:00.0000000Z'
        HomeRoot = $HomeRoot
    }
    Set-File -Path (Join-Path $RepoRoot 'state/current-env.json') -Content ([System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $legacy)))
    return [pscustomobject] @{ Skills = $skills; LockPath = $lockPath }
}

function New-FakeAuthorityPair {
    <#
    Builds one fully synthetic claims/state pair for the supplied fake context:
    the three live-root claims are ABSENT rows under the fake home, and the
    state binds the exact claims bytes with the supplied controller fingerprint.
    #>
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $ControllerFingerprint
    )

    $volumeId = '01234567'
    $parentIdentity = "$volumeId" + ':aaaaaaaaaaaaaaaa'
    $homePath = [string] $Context.HomeRoot
    $platformRows = @(
        @{ Platform = 'Claude'; Relative = '.claude/skills'; Identity = "$volumeId" + ':bbbbbbbbbbbbbb01' }
        @{ Platform = 'Codex'; Relative = '.codex/skills'; Identity = "$volumeId" + ':bbbbbbbbbbbbbb02' }
        @{ Platform = 'Reasonix'; Relative = 'AppData/Roaming/reasonix/skills'; Identity = "$volumeId" + ':bbbbbbbbbbbbbb03' }
    )
    $claimsRows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $platformRows) {
        $requestedPath = Join-Path $homePath $row.Relative
        $locationKey = $requestedPath.TrimEnd([char] 92, [char] 47).ToLowerInvariant().Replace([char] 92, [char] 47)
        $claimsRows.Add([ordered] @{
                Platform = $row.Platform
                LocationKey = $locationKey
                RequestedPath = $requestedPath
                InitialState = 'ABSENT'
                VolumeId = $volumeId
                DeepestExistingParentPath = $homePath
                DeepestExistingParentIdentity = $parentIdentity
                MissingRemainder = @($row.Relative -split '/')
                InitialDirectoryIdentity = $null
                ExpectedPostState = 'EXISTS'
            })
    }
    $homeLocationKey = ([IO.Path]::GetFullPath($homePath)).TrimEnd([char] 92, [char] 47).ToLowerInvariant().Replace([char] 92, [char] 47)
    $claims = [ordered] @{
        SchemaVersion = 1
        ArtifactKind = 'root-claims'
        HomeAuthorityKey = [string] $Context.HomeAuthorityKey
        TokenSid = [string] $Context.TokenSid
        ResolverVersion = 'windows-token-sid-known-folder-v1'
        HomeRootLocationKey = $homeLocationKey
        LiveRootClaims = @($claimsRows)
    }
    $claimsBytes = ConvertTo-SemanticJsonBytes -InputObject $claims
    $claimsHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($claimsBytes)).ToLowerInvariant()

    $identities = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $platformRows.Count; $index++) {
        $claimsRow = $claimsRows[$index]
        $identities.Add([ordered] @{
                Platform = [string] $claimsRow.Platform
                LocationKey = [string] $claimsRow.LocationKey
                ResolvedPath = [string] $claimsRow.RequestedPath
                VolumeId = $volumeId
                DirectoryIdentity = [string] $platformRows[$index].Identity
                FilesystemCapabilityHash = '9' * 64
            })
    }
    $state = [ordered] @{
        SchemaVersion = 3
        ArtifactKind = 'current-env-state'
        HomeAuthorityKey = [string] $Context.HomeAuthorityKey
        AuthorityGeneration = 1
        RootClaimsHash = $claimsHash
        SelectionKind = 'environment'
        EnvironmentName = 'full'
        EnvironmentLockHash = 'e' * 64
        TaskOverlayHash = 'f' * 64
        TaskOverlaySkills = @(
            [ordered] @{ Platform = 'Claude'; Skills = @('fixture-a') }
            [ordered] @{ Platform = 'Codex'; Skills = @('fixture-a') }
            [ordered] @{ Platform = 'Reasonix'; Skills = @('fixture-a') }
        )
        ManifestHashes = @(
            [ordered] @{ Platform = 'Claude'; Hash = 'a' * 64 }
            [ordered] @{ Platform = 'Codex'; Hash = 'b' * 64 }
            [ordered] @{ Platform = 'Reasonix'; Hash = 'c' * 64 }
        )
        FinalManagedHashes = @(
            [ordered] @{ Platform = 'Claude'; Hash = 'd' * 64 }
            [ordered] @{ Platform = 'Codex'; Hash = 'e' * 64 }
            [ordered] @{ Platform = 'Reasonix'; Hash = 'f' * 64 }
        )
        FinalResolvedIdentities = @($identities)
        FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($identities)
        ControllerRepoFingerprint = $ControllerFingerprint
        ApprovedToolchainHash = '1' * 64
        PlanHash = '2' * 64
        DocumentHash = '3' * 64
        JournalId = '0f1e2d3c-4b5a-4978-8796-a5b4c3d2e1f0'
        PreStatePhaseHash = '4' * 64
        LastOperationKind = 'initial'
        ReceiptId = '2f3e4d5c-6b7a-4897-8986-1d2e3f4a5b6c'
        ReceiptHash = '5' * 64
    }
    $stateBytes = ConvertTo-SemanticJsonBytes -InputObject $state

    $authorityRoot = Join-Path (Join-Path ([string] $Context.ControlBase) 'homes') ([string] $Context.HomeAuthorityKey)
    New-Item -ItemType Directory -Path $authorityRoot -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $authorityRoot 'root-claims.json'), $claimsBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $authorityRoot 'current-env.json'), $stateBytes)
    return [pscustomobject] @{ Key = [string] $Context.HomeAuthorityKey; Claims = $claims; State = $state }
}

$authorityRepo = New-FakeHarnessRepo -Path (Join-Path $work 'authority-repo')
Set-File -Path (Join-Path $authorityRepo 'harness-source/envs/good.psd1') -Content (New-EnvDefinitionText -Name 'good' -ClaudeSkills @('fixture-a', 'fixture-b') -CodexSkills @('fixture-a') -ReasonixSkills @('fixture-a'))
& git -C $authorityRepo add -A 2>&1 | Out-Null
& git -C $authorityRepo -c user.email=fixture@example.invalid -c user.name=fixture commit --quiet -m 'fixture'
Assert ($LASTEXITCODE -eq 0) 'the authority fixture repository has a commit'

# 1. pristine home and roots.
$pristineHome = Join-Path $work 'authority-home-pristine'
$pristineIdentity = New-AuthorityTestIdentity -Path $pristineHome
$pristine = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $pristineIdentity
Assert ([string] $pristine.Route -ceq 'initial') 'pristine roots and no authority route to initial'
Assert ([string] $pristine.NextOperation -ceq 'env activate full -DryRun') 'initial recommends the named full activation'
Assert ($pristine.LiveRoots.Pristine) 'pristine live roots report Pristine'
Assert ([string] $pristine.IntendedRoot.Selection -ceq 'known-folder-default') 'pristine status carries the default intended root'
Assert ([string] $pristine.IntendedRoot.FilesystemCapabilityStatus -ceq 'UNPROBED') 'the intended root is metadata-only'
Assert (-not $pristine.IntendedRoot.Contains('RequestedReasonixRoot')) 'the default intended root carries no requested-root label'

# 2. non-empty roots adopt.
$adoptHome = Join-Path $work 'authority-home-adopt'
$adoptIdentity = New-AuthorityTestIdentity -Path $adoptHome
New-ManagedLiveSkill -HomeRoot $adoptHome -PlatformKey 'claude' -Name 'existing-local' -Content '# existing'
$adopt = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $adoptIdentity
Assert ([string] $adopt.Route -ceq 'adopt') 'non-empty roots without any legacy artifact route to adopt'
Assert ([string] $adopt.Legacy.Status -ceq 'MISSING') 'adopt without legacy evidence reports MISSING legacy evidence'

# 3. an explicit custom Reasonix root before any claims.
$customRoot = Join-Path $work 'custom-reasonix-skills'
New-Item -ItemType Directory -Path $customRoot -Force | Out-Null
$explicit = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $adoptIdentity -ReasonixLiveSkillsPath $customRoot
Assert ([string] $explicit.IntendedRoot.Selection -ceq 'explicit-initial-claim') 'an explicit root selects the explicit intended-root branch'
Assert ([string] $explicit.IntendedRoot.RequestedReasonixRoot -ceq 'C:\...\custom-reasonix-skills') 'the requested-root label is redacted'

# 4. complete, consistent legacy evidence with passing live parity migrates.
$migrateHome = Join-Path $work 'authority-home-migrate'
$migrateIdentity = New-AuthorityTestIdentity -Path $migrateHome
$legacyFixture = New-LegacyActivationFixture -RepoRoot $authorityRepo -HomeRoot $migrateHome -Name 'good'
$migrate = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $migrateIdentity
Assert ([string] $migrate.Legacy.Status -ceq 'CORE') 'internally consistent legacy evidence reports CORE'
Assert ([string] $migrate.Legacy.OldLockStatus -ceq 'VERIFIED') 'the preserved activation lock verifies against LockHash'
Assert ([string] $migrate.Legacy.LiveParity.Status -ceq 'pass') 'legacy live parity passes for matching live trees'
Assert ([string] $migrate.Route -ceq 'migrate') 'core evidence with passing parity routes to migrate'
Assert ([string] $migrate.Legacy.Gap -ceq 'none') 'a complete three-platform baseline reports no gap'
Assert ([string] $migrate.IntendedRoot.RequestedInitialRootContextHash -cmatch '\A[0-9a-f]{64}\z') 'migrate carries a metadata-only intended-root context hash'

# 5. live drift under a verified lock requires manual recovery.
Set-File -Path (Join-Path $migrateHome '.claude/skills/fixture-a/SKILL.md') -Content '# drifted'
$manual = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $migrateIdentity
Assert ([string] $manual.Legacy.Status -ceq 'CORE') 'drifted live content keeps the core valid'
Assert ([string] $manual.Legacy.LiveParity.Status -ceq 'mismatch') 'drifted live content fails legacy live parity'
Assert ([string] $manual.Route -ceq 'manual-recovery-required') 'core evidence with failing parity routes to manual recovery'
Set-File -Path (Join-Path $migrateHome '.claude/skills/fixture-a/SKILL.md') -Content '# fixture-a (claude live)'

# 6. an untrustworthy legacy artifact adopts as untrusted evidence.
$untrustedHome = Join-Path $work 'authority-home-untrusted'
$untrustedIdentity = New-AuthorityTestIdentity -Path $untrustedHome
Set-File -Path (Join-Path $authorityRepo 'state/current-env.json') -Content '{"SchemaVersion":2}'
$untrusted = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $untrustedIdentity
Assert ([string] $untrusted.Legacy.Status -ceq 'CORRUPT') 'an invalid legacy core reports CORRUPT'
Assert ([string] $untrusted.Route -ceq 'adopt') 'an untrustworthy legacy artifact routes to adopt'

# A missing old lock is a mismatched core field, so it also adopts.
$missingLockHome = Join-Path $work 'authority-home-missing-lock'
$missingLockIdentity = New-AuthorityTestIdentity -Path $missingLockHome
$null = New-LegacyActivationFixture -RepoRoot $authorityRepo -HomeRoot $missingLockHome -Name 'good'
Remove-Item -LiteralPath (Join-Path $authorityRepo 'envs/good/env.lock.json') -Force
$missingLock = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $missingLockIdentity
Assert ([string] $missingLock.Legacy.Status -ceq 'CORRUPT' -and [string] $missingLock.Route -ceq 'adopt') 'a missing preserved lock keeps the legacy artifact untrusted'
Remove-Item -LiteralPath (Join-Path $authorityRepo 'state/current-env.json') -Force -ErrorAction SilentlyContinue

# 6b. malformed legacy evidence stays reportable instead of throwing.
$malformedHome = Join-Path $work 'authority-home-malformed'
$malformedIdentity = New-AuthorityTestIdentity -Path $malformedHome
$null = New-LegacyActivationFixture -RepoRoot $authorityRepo -HomeRoot $malformedHome -Name 'good'
$malformedDocument = ConvertFrom-SemanticJson -Json (Get-Content -Raw -LiteralPath (Join-Path $authorityRepo 'state/current-env.json'))
$malformedDocument['ManifestHashes'] = 'oops'
Set-File -Path (Join-Path $authorityRepo 'state/current-env.json') -Content ([System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $malformedDocument)))
$malformed = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $malformedIdentity
Assert ([string] $malformed.Legacy.Status -ceq 'CORRUPT' -and [string] $malformed.Route -ceq 'adopt') 'malformed legacy manifest hashes stay untrusted evidence'

$malformedDocument['ManifestHashes'] = [ordered] @{}
$malformedDocument['Name'] = '../escape'
Set-File -Path (Join-Path $authorityRepo 'state/current-env.json') -Content ([System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $malformedDocument)))
$unsafeName = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $malformedIdentity
Assert ([string] $unsafeName.Legacy.Status -ceq 'CORRUPT' -and [string] $unsafeName.Route -ceq 'adopt') 'a legacy name outside the bare-identifier shape stays untrusted evidence'

$malformedDocument['Name'] = 'good'
$malformedDocument['HomeRoot'] = 'C:\bad<path>'
Set-File -Path (Join-Path $authorityRepo 'state/current-env.json') -Content ([System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $malformedDocument)))
$badHome = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $malformedIdentity
Assert ([string] $badHome.Legacy.Status -ceq 'CORRUPT' -and [string] $badHome.Route -ceq 'adopt') 'an invalid legacy HomeRoot stays untrusted evidence'
Remove-Item -LiteralPath (Join-Path $authorityRepo 'state/current-env.json') -Force -ErrorAction SilentlyContinue

# 7. valid claims with a missing or corrupt state repairs state.
$repairHome = Join-Path $work 'authority-home-repair'
$repairIdentity = New-AuthorityTestIdentity -Path $repairHome
$repairContext = Resolve-HomeAuthorityContextFromIdentity -Identity $repairIdentity
$controllerFingerprint = Get-CanonicalControllerIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $authorityRepo)
$pair = New-FakeAuthorityPair -Context $repairContext -ControllerFingerprint $controllerFingerprint
$beforeState = Read-HomeAuthorityState -ControlBase ([string] $repairContext.ControlBase) -HomeAuthorityKey $pair.Key -RepoRoot $authorityRepo
if ([string] $beforeState.PairStatus -cne 'VALID') {
    Write-Host "  note  pair=$($beforeState.PairStatus) claims=$($beforeState.ClaimsStatus) state=$($beforeState.StateStatus)"
    Write-Host "  note  claimsError=$($beforeState.ClaimsError)"
    Write-Host "  note  stateError=$($beforeState.StateError)"
    Write-Host "  note  pairError=$($beforeState.PairError)"
}
Assert ([string] $beforeState.PairStatus -ceq 'VALID') 'the rebuilt fake pair validates against the real reader'

Remove-Item -LiteralPath (Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'current-env.json') -Force
$repairMissing = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $repairMissing.Route -ceq 'repair-adopt') 'valid claims with a missing state route to repair-adopt'
Assert ([string] $repairMissing.StateStatus -ceq 'MISSING') 'the missing state is reported as MISSING'

Set-File -Path (Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'current-env.json') -Content '{ corrupt'
$repairCorrupt = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $repairCorrupt.Route -ceq 'repair-adopt') 'valid claims with a corrupt state route to repair-adopt'
Assert ([string] $repairCorrupt.StateStatus -ceq 'CORRUPT') 'the corrupt state is reported as CORRUPT'

# 8. the valid pair on the current controller activates.
$null = New-FakeAuthorityPair -Context $repairContext -ControllerFingerprint $controllerFingerprint
$activate = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $activate.PairStatus -ceq 'VALID' -and $activate.ControllerMatch) 'the fake pair matches the current controller'
Assert ([string] $activate.Route -ceq 'activate') 'a valid pair on the current controller routes to activate'
Assert ([string] $activate.StateSummary.EnvironmentName -ceq 'full') 'the state summary carries the selected environment'
Assert ([string] $activate.NextOperation -ceq 'env activate <name> -DryRun') 'activate recommends the ordinary activation DryRun'

# 9. a foreign controller needs passing parity before takeover.
$foreignFingerprint = '0' * 64
$null = New-FakeAuthorityPair -Context $repairContext -ControllerFingerprint $foreignFingerprint
$foreign = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert (-not $foreign.ControllerMatch) 'a foreign fingerprint is reported as a controller mismatch'
Assert ([string] $foreign.Route -ceq 'controller-owner-action-required') 'a foreign controller without verified parity stops at owner action'
Assert ([string] $foreign.NextOperation -ceq 'env authority status') 'owner action recommends a status review'

# Parity requires the state-bound lock file to be present and byte-identical.
$switchRejected = $false
try { $null = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity -ReasonixLiveSkillsPath $customRoot }
catch { $switchRejected = $_.Exception.Message -match 'authority-reasonix-root-switch-forbidden-after-claims' }
Assert $switchRejected 'the intended-root switch is rejected once schema 3 claims exist'
$switchRejectedSamePath = $false
try { $null = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity -ReasonixLiveSkillsPath (Join-Path $repairHome 'AppData/Roaming/reasonix/skills') }
catch { $switchRejectedSamePath = $_.Exception.Message -match 'authority-reasonix-root-switch-forbidden-after-claims' }
Assert $switchRejectedSamePath 'the switch is rejected even when its text matches the claim default'

$stagingPath = Join-Path $authorityRepo 'envs/full'
$lockFromFixture = [ordered] @{
    SchemaVersion = 3
    Name = 'full'
    DefinitionHash = 'a' * 64
    TaskOverlayHash = $null
    TaskOverlaySkills = [ordered] @{ Claude = @(); Codex = @(); Reasonix = @() }
    RepositoryCommit = 'b' * 40
    ManifestHashes = [ordered] @{ Claude = 'c' * 64; Codex = 'd' * 64; Reasonix = 'e' * 64 }
    SkillSourceEvidence = 'available'
    SkillSourceHashes = [ordered] @{ Claude = [ordered] @{}; Codex = [ordered] @{}; Reasonix = [ordered] @{} }
    StagedSkillTreeHashes = [ordered] @{ Claude = [ordered] @{}; Codex = [ordered] @{}; Reasonix = [ordered] @{} }
    ProfileSourceHash = $null
    ProfileOutputHash = $null
    BuiltFiles = [ordered] @{}
}
Set-File -Path (Join-Path $stagingPath 'env.lock.json') -Content ([System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $lockFromFixture)))
$lockHash = Get-HarnessFileHash -Path (Join-Path $stagingPath 'env.lock.json')
$stateWithLock = ConvertFrom-SemanticJson -Json (Get-Content -Raw -LiteralPath (Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'current-env.json'))
$stateWithLock['EnvironmentLockHash'] = $lockHash.ToLowerInvariant()
[System.IO.File]::WriteAllBytes((Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'current-env.json'), (ConvertTo-SemanticJsonBytes -InputObject $stateWithLock))
$takeover = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $takeover.LockParity.Status -ceq 'pass') 'the state-bound lock verifies and passes live parity'
Assert ([string] $takeover.Route -ceq 'takeover') 'a foreign controller with passing parity routes to takeover'

# 9b. an unreadable state-bound lock is not-checked, never a raw error.
$null = New-FakeAuthorityPair -Context $repairContext -ControllerFingerprint $controllerFingerprint
$brokenLockPath = Join-Path $stagingPath 'env.lock.json'
Set-File -Path $brokenLockPath -Content '{"broken":true}'
$brokenLockHash = (Get-HarnessFileHash -Path $brokenLockPath).ToLowerInvariant()
$stateWithBrokenLock = ConvertFrom-SemanticJson -Json (Get-Content -Raw -LiteralPath (Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'current-env.json'))
$stateWithBrokenLock['EnvironmentLockHash'] = $brokenLockHash
[System.IO.File]::WriteAllBytes((Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'current-env.json'), (ConvertTo-SemanticJsonBytes -InputObject $stateWithBrokenLock))
$unreadableLock = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $unreadableLock.LockParity.Status -ceq 'not-checked') 'an unreadable state-bound lock is reported as not-checked'
Assert (@($unreadableLock.LockParity.Reasons) -contains 'lock-unreadable') 'the unreadable lock carries a stable reason'
Remove-Item -LiteralPath $brokenLockPath -Force

# 10. an unfinished live journal forces the recovery route first.
$authorityArea = Join-Path (Join-Path ([string] $repairContext.ControlBase) 'live-transactions') '11111111-1111-4111-8111-111111111111'
New-Item -ItemType Directory -Path $authorityArea -Force | Out-Null
$recovery = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $recovery.RecoveryStatus -ceq 'unfinished') 'an unfinished journal reports unfinished recovery'
Assert ([string] $recovery.Route -ceq 'recovery') 'an unfinished journal routes to recovery before every other route'
Assert ([string] $recovery.NextOperation -ceq 'live recover status') 'recovery recommends the recovery status command'
Assert ($recovery.UnfinishedTransactionIds.Count -eq 1) 'the unfinished transaction id is reported'
Remove-Item -LiteralPath (Split-Path -Parent $authorityArea) -Recurse -Force

# A stray non-UUID namespace must stay reportable rather than breaking the document.
$strayArea = Join-Path (Join-Path ([string] $repairContext.ControlBase) 'live-transactions') 'leftover-namespace'
New-Item -ItemType Directory -Path $strayArea -Force | Out-Null
$stray = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $stray.Route -ceq 'recovery') 'a stray namespace still routes to recovery'
Assert (@($stray.UnfinishedTransactionIds) -contains 'leftover-namespace') 'the stray namespace is reported verbatim'
Assert (@($stray.UnfinishedTransactionIds).Count -eq 1) 'the stray namespace is the only unfinished entry'
Remove-Item -LiteralPath (Split-Path -Parent $strayArea) -Recurse -Force

# 11. corrupt claims are always manual.
Remove-Item -LiteralPath (Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'root-claims.json') -Force
Set-File -Path (Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'root-claims.json') -Content '{"SchemaVersion":1}'
$corruptClaims = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $corruptClaims.RootClaimsStatus -ceq 'CORRUPT') 'corrupt claims are reported as CORRUPT'
Assert ([string] $corruptClaims.Route -ceq 'manual-recovery-required') 'corrupt claims route to manual recovery'

# 12. a pair mismatch is manual, and the reader never writes.
$null = New-FakeAuthorityPair -Context $repairContext -ControllerFingerprint $controllerFingerprint
$mismatchState = ConvertFrom-SemanticJson -Json (Get-Content -Raw -LiteralPath (Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'current-env.json'))
$mismatchState['RootClaimsHash'] = '0' * 64
[System.IO.File]::WriteAllBytes((Join-Path (Join-Path ([string] $repairContext.ControlBase) (Join-Path 'homes' $pair.Key)) 'current-env.json'), (ConvertTo-SemanticJsonBytes -InputObject $mismatchState))
$mismatch = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $mismatch.PairStatus -ceq 'MISMATCH') 'a state that does not bind the claims bytes is a MISMATCH'
Assert ([string] $mismatch.Route -ceq 'manual-recovery-required') 'a pair mismatch routes to manual recovery'

# An orphan schema 3 state without its immutable claims is not a first-authority
# situation: the route must be manual recovery, never the initial/adopt
# recommendation its legacy branch would otherwise emit (the host refuses those,
# so the status recommendation would be unactionable).
$orphanClaimsPath = [System.IO.Path]::Combine([string] $repairContext.ControlBase, 'homes', [string] $pair.Key, 'root-claims.json')
$orphanClaimsBytes = [System.IO.File]::ReadAllBytes($orphanClaimsPath)
Remove-Item -LiteralPath $orphanClaimsPath -Force
$orphan = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
Assert ([string] $orphan.RootClaimsStatus -ceq 'MISSING' -and [string] $orphan.StateStatus -ceq 'VALID') 'the orphan-state fixture is claims-MISSING with a valid state'
Assert ([string] $orphan.Route -ceq 'manual-recovery-required') 'an orphan state without claims routes to manual recovery'
Assert ([string] $orphan.NextOperation -ceq 'env authority status') 'the orphan-state route recommends the status review'
[System.IO.File]::WriteAllBytes($orphanClaimsPath, $orphanClaimsBytes)

# The authority-active status branch: definition map, overlay path and the
# state-bound lock drive the summary the schema 2 status document carries.
$definitionByName = @{}
foreach ($file in @(Get-HarnessEnvDefinitionFiles -RepoRoot $authorityRepo)) {
    $definitionByName[[System.IO.Path]::GetFileNameWithoutExtension($file.Name)] = $file.FullName
}
$activeSummary = Get-HarnessEnvAuthorityActiveSummary -RepoRoot $authorityRepo -Authority $mismatch -DefinitionByName $definitionByName -TaskOverlayPath (Get-HarnessTaskSkillOverlayPath -RepoRoot $authorityRepo) -HomeRoot $repairHome
Assert ([string] $activeSummary.Active.Source -ceq 'authority') 'the active summary reports the shared authority source'
Assert ([string] $activeSummary.Active.Name -ceq 'full') 'the active summary takes the name from the state'
Assert ([string] $activeSummary.Active.Status -ceq 'drift') 'a pair mismatch keeps the active summary in drift'
$activateSummary = Get-HarnessEnvAuthorityActiveSummary -RepoRoot $authorityRepo -Authority $takeover -DefinitionByName $definitionByName -TaskOverlayPath (Get-HarnessTaskSkillOverlayPath -RepoRoot $authorityRepo) -HomeRoot $repairHome
Assert ([string] $activateSummary.Active.LockValidity -ceq 'valid') 'a verified state-bound lock reports valid lock validity'
Assert ([string] $activateSummary.Active.LockHash -ceq [string] $takeover.StateSummary.EnvironmentLockHash) 'the active summary carries the verified lock hash'
Assert ([string] $activateSummary.Active.LiveParity.Status -ceq 'pass') 'the active summary carries the lock-bound live parity'
Assert ($null -eq $activateSummary.Active.LockReasons.Count -or $activateSummary.Active.LockReasons.Count -eq 0) 'a clean authority carries no lock reasons'

$homeSnapshotBefore = Get-TreeSnapshot -Root $work
$null = Get-HarnessEnvAuthorityAssessment -RepoRoot $authorityRepo -Identity $repairIdentity
$homeSnapshotAfter = Get-TreeSnapshot -Root $work
Assert ($homeSnapshotBefore -eq $homeSnapshotAfter) 'the authority assessment writes no file anywhere in the fixture tree'

# 13. the frozen route/next-operation mapping is exhaustive.
$routeNextOperations = @{
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
$routeCounts = @{}
$routeViolations = 0
$resolverCommand = Get-Command Resolve-HarnessEnvAuthorityRoute
function Get-ResolverDomain {
    param([Parameter(Mandatory)] [string] $Name)
    $attribute = @($resolverCommand.Parameters[$Name].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
    if ($attribute.Count -ne 1) { throw "resolver parameter $Name has no single ValidateSet" }
    return @($attribute[0].ValidValues)
}
# The matrix is driven by the decision function's own accepted domains, so a new
# token cannot be added without extending the pinned coverage.
$recoveryDomain = Get-ResolverDomain -Name 'RecoveryStatus'
$claimsDomain = Get-ResolverDomain -Name 'ClaimsStatus'
$stateDomain = Get-ResolverDomain -Name 'StateStatus'
$pairDomain = Get-ResolverDomain -Name 'PairStatus'
$lockParityDomain = Get-ResolverDomain -Name 'LockParityStatus'
$legacyDomain = Get-ResolverDomain -Name 'LegacyStatus'
$oldLockDomain = Get-ResolverDomain -Name 'OldLockStatus'
$legacyParityDomain = Get-ResolverDomain -Name 'LegacyLiveParityStatus'
$combinations = 0
foreach ($recoveryStatus in $recoveryDomain) {
    foreach ($claimsStatus in $claimsDomain) {
        foreach ($stateStatus in $stateDomain) {
            foreach ($pairStatus in $pairDomain) {
                foreach ($controllerMatch in @($null, $false, $true)) {
                    foreach ($lockParityStatus in $lockParityDomain) {
                        foreach ($legacyStatus in $legacyDomain) {
                            foreach ($oldLockStatus in $oldLockDomain) {
                                foreach ($legacyParity in $legacyParityDomain) {
                                    foreach ($pristine in @($true, $false)) {
                                        $combinations++
                                        $route = Resolve-HarnessEnvAuthorityRoute -RecoveryStatus $recoveryStatus -ClaimsStatus $claimsStatus -StateStatus $stateStatus -PairStatus $pairStatus -ControllerMatch $controllerMatch -LockParityStatus $lockParityStatus -LegacyStatus $legacyStatus -OldLockStatus $oldLockStatus -LegacyLiveParityStatus $legacyParity -LiveRootsPristine $pristine
                                        if ($routeNextOperations.ContainsKey($route)) {
                                            $routeCounts[$route] = 1 + ($routeCounts[$route] ?? 0)
                                        }
                                        else {
                                            $routeViolations++
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
Assert ($routeViolations -eq 0) "every one of the $combinations fact combinations over the resolver's own domains maps to a frozen route"
Assert ((@($routeCounts.Keys | Sort-Object) -join ',') -ceq (@($routeNextOperations.Keys | Sort-Object) -join ',')) 'the matrix reaches every frozen route'
Assert ($combinations -eq ($recoveryDomain.Count * $claimsDomain.Count * $stateDomain.Count * $pairDomain.Count * 3 * $lockParityDomain.Count * $legacyDomain.Count * $oldLockDomain.Count * $legacyParityDomain.Count * 2)) 'the matrix enumerates the complete cross product'

# ==============================================================================
Write-Host 'authority command surface: dispatcher, plan paths, and the four transitions'
. (Join-Path $RepoRoot 'tests/helpers/safety-sandbox.ps1')
. (Join-Path $RepoRoot 'tests/helpers/failpoint-controller.ps1')

$authorityScript = Join-Path $RepoRoot 'scripts/authority-harness-env.ps1'
$entryScript = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'

function Invoke-AuthorityCli {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $SandboxRoot,
        [switch] $Direct
    )
    if ($Direct) {
        # Direct invocation outside the sandbox: the production interlock owns
        # the outcome and no sandbox capability is present.
        $out = & pwsh -NoProfile -File $authorityScript @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    }
    $result = Invoke-SafetySandboxScript -SandboxRoot $SandboxRoot -ScriptPath $authorityScript -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
    return [pscustomobject]@{ Code = $result.Code; Out = $result.Out }
}

function Invoke-EntryCli {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $out = & pwsh -NoProfile -File $entryScript @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Invoke-AuthorityCliKilledAtCheckpoint {
    # Runs the authority CLI inside the sandbox host and hard-kills the process
    # tree once it reports the configured checkpoint. The failpoint variable is
    # process-scoped and restored afterwards so no later sandbox run inherits it.
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $SandboxRoot,
        [Parameter(Mandatory)] [string] $Checkpoint
    )
    $controller = New-FailpointController
    $suffix = [Guid]::NewGuid().ToString('N')
    $outFile = Join-Path $work "authority-kill-out-$Checkpoint-$suffix.txt"
    $errFile = Join-Path $work "authority-kill-err-$Checkpoint-$suffix.txt"
    $hostScript = Join-Path $RepoRoot 'scripts/internal/live-transaction-host.ps1'
    $encoded = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject @($Arguments) -Compress)))
    $child = $null
    $saved = [System.Environment]::GetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS')
    try {
        [System.Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS', (ConvertTo-Json -InputObject @([ordered]@{ Checkpoint = $Checkpoint; PipeName = $controller.Name }) -Compress))
        $child = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $hostScript, '-SandboxRoot', $SandboxRoot, '-ScriptPath', $authorityScript, '-ArgumentsBase64', $encoded) -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        Wait-FailpointController -Controller $controller -ExpectedCheckpoint $Checkpoint -TimeoutSeconds 240
        if ($child.HasExited) { throw "the authority host exited before the $Checkpoint kill" }
        Stop-FailpointProcessTree -Process $child
        $null = $child.WaitForExit(60000)
    }
    finally {
        [System.Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS', $saved)
        if ($null -ne $child -and -not $child.HasExited) { Stop-FailpointProcessTree -Process $child }
        Close-FailpointController -Controller $controller
    }
    $out = ''
    foreach ($file in @($outFile, $errFile)) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        # R3 fixture sync (docs/CI_FAILURE_RULES.md): an orphan of the killed
        # tree can hold the redirect handle after WaitForExit returns. Read
        # with explicit sharing and a bounded release wait instead of letting
        # the assertion fail on the race; this bounded wait lives in the
        # fixture only and never in a production script.
        $releaseDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while ($true) {
            try {
                $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                try {
                    $reader = [System.IO.StreamReader]::new($stream)
                    $out += $reader.ReadToEnd()
                    $reader.Dispose()
                }
                finally { $stream.Dispose() }
                break
            }
            catch [System.IO.IOException] {
                if ([DateTime]::UtcNow -gt $releaseDeadline) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    return [pscustomobject]@{ Code = $child.ExitCode; Out = $out }
}

function Get-InjectionJournalSummary {
    # Journal evidence for a hard-killed transaction, read as raw artifacts so
    # the assertion does not depend on the engine's chain reader.
    param([Parameter(Mandatory)] [string] $TransactionDirectory)

    $records = @(Get-ChildItem -LiteralPath $TransactionDirectory -File -Filter '0*.json' | Sort-Object Name)
    $lastPhase = $null
    foreach ($record in $records) {
        $document = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($record.FullName)))
        $lastPhase = [string] $document.Phase
    }
    $unknown = @(Get-ChildItem -LiteralPath $TransactionDirectory -File -Force | Where-Object { $_.Name -notmatch '\A(header\.json|result\.json|0[0-9]{5}\.json)\z' })
    return [pscustomobject]@{
        RecordCount = $records.Count
        LastPhase = $lastPhase
        HasResult = (Test-Path -LiteralPath (Join-Path $TransactionDirectory 'result.json') -PathType Leaf)
        UnknownCount = $unknown.Count
    }
}

function Test-AuthorityPlanDocument {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ExpectedKind
    )

    . (Join-Path $RepoRoot 'scripts/semantic-json.ps1')
    . (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
    . (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')
    $schemaRoot = Join-Path $RepoRoot 'schemas'
    $validation = Test-RepositoryJsonSchema -SchemaPath (Join-Path $schemaRoot 'sync-plan.schema.json') -SchemaRoot $schemaRoot
    $schemaOk = $true
    try { $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $validation -InstanceBytes ([System.IO.File]::ReadAllBytes($Path)) -InstancePath 'authority-plan-emitted.json' }
    catch { $schemaOk = $false; Write-Host "  note  emitted plan failed schema validation: $($_.Exception.Message)" }
    Assert $schemaOk "$ExpectedKind plan validates against the sync-plan schema"
    $document = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($Path)))
    $semanticsOk = $true
    try { Test-LiveSyncPlanSemantics -Document $document }
    catch { $semanticsOk = $false; Write-Host "  note  emitted plan failed semantics: $($_.Exception.Message)" }
    Assert $semanticsOk "$ExpectedKind plan passes the frozen plan semantics"
    Assert ([string] $document.PlanPayload.OperationKind -ceq $ExpectedKind) "$ExpectedKind plan carries its own operation kind"
    Assert ([string] $document.PlanPayload.Generator -ceq 'scripts/authority-harness-env.ps1') "$ExpectedKind plan names the authority producer"
    return $document
}

# Each first-authority transition needs its own machine: once an authority
# exists the other first-authority routes are refused by design.
function New-AuthorityCliSandbox {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [string] $EnvName = 'good'
    )

    $sandbox = Join-Path $Root 'sandbox'
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $cliRepo = New-FakeHarnessRepo -Path (Join-Path $sandbox 'repo')
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools') -Destination (Join-Path $cliRepo 'tools') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'schemas') -Destination (Join-Path $cliRepo 'schemas') -Recurse -Force
    foreach ($name in @('good', 'full', 'other')) {
        Set-File -Path (Join-Path $cliRepo "harness-source/envs/$name.psd1") -Content (New-EnvDefinitionText -Name $name -ClaudeSkills @('fixture-a', 'fixture-b') -CodexSkills @('fixture-a') -ReasonixSkills @('fixture-a'))
    }
    & git -C $cliRepo add -A 2>&1 | Out-Null
    & git -C $cliRepo -c user.email=fixture@example.invalid -c user.name=fixture commit --quiet -m fixture
    $sandboxHome = Join-Path $sandbox 'home'
    New-ManagedLiveSkill -HomeRoot $sandboxHome -PlatformKey 'claude' -Name 'existing-local' -Content '# existing'
    New-Item -ItemType Directory -Path (Join-Path $sandboxHome 'AppData/Roaming') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sandboxHome 'AppData/Local') -Force | Out-Null
    $identity = [pscustomobject][ordered]@{
        ResolverVersion = 'windows-token-sid-known-folder-v1'
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ProfileRoot = $sandboxHome
        RoamingAppDataRoot = (Join-Path $sandboxHome 'AppData/Roaming')
        LocalAppDataRoot = (Join-Path $sandboxHome 'AppData/Local')
    }
    $context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity
    $bootstrapIntent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $context -FilesystemCapabilityHash ('a' * 64)
    $bootstrapLock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $context -Intent $bootstrapIntent
    Exit-HomeAuthorityGlobalLiveLock -LockHandle $bootstrapLock
    $probe = Join-Path $Root 'canonical-probe'
    $recoveryParent = Join-Path $Root 'canonical-recovery-parent'
    foreach ($dir in @($probe, $recoveryParent)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-AuthorityTestDirectoryCurrentUserOnly -Path $recoveryParent
    $recovery = Join-Path $recoveryParent 'recovery'
    New-Item -ItemType Directory -Force -Path $recovery | Out-Null
    Set-AuthorityTestDirectoryCurrentUserOnly -Path $recovery
    $payload = New-CanonicalSetupPlanPayload -RepoRoot $cliRepo -CanonicalRecoveryRoot $recovery -ControlBase ([string] $context.ControlBase) -BackupRoot ([string] $context.BackupRoot) -ProbeRoot $probe -ToolchainRoot $RepoRoot
    $paths = Get-CanonicalTransactionContractPaths -GitContext (Get-CanonicalGitContext -RepoRoot $cliRepo)
    $state = New-CanonicalFinalSetupState -PlanPayload $payload -RepoRoot $cliRepo
    $repoId = Get-CanonicalRepoIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $cliRepo)
    $lock = Enter-CanonicalRepoLock -LockPath ([string] $paths.LockPath) -AllowCreate
    try {
        Write-AuthorityTestSemanticDocument -Path ([string] $paths.SetupStatePath) -Document $state
        Write-AuthorityTestSemanticDocument -Path (Join-Path ([string] $context.ControlBase) (Join-Path 'canonical-roots' ($repoId + '.json'))) -Document ([System.Collections.IDictionary] $payload.ExpectedRootClaim)
    }
    finally { Exit-CanonicalRepoLock -LockHandle $lock }
    return [pscustomobject]@{
        Sandbox = $sandbox
        Repo = $cliRepo
        Home = $sandboxHome
        Identity = $identity
        Context = $context
        AuthorityRoot = Join-Path (Join-Path ([string] $context.ControlBase) 'homes') ([string] $context.HomeAuthorityKey)
    }
}

function Set-AuthorityForeignControllerState {
    # Makes a valid authority look like it belongs to another controller: the
    # state records a foreign controller fingerprint and binds the state-bound
    # activation lock the assessment verifies against the live trees (the plan's
    # materialization lock stands in for the Task 6 activation publication).
    param(
        [Parameter(Mandatory)] [string] $AuthorityRoot,
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $PlanPath,
        [string] $ControllerFingerprint = ('0' * 64)
    )
    $materialization = Join-Path (Split-Path -Parent $PlanPath) (([System.IO.Path]::GetFileNameWithoutExtension($PlanPath)) + '.materialization')
    $lockDir = Join-Path $Repo "envs/$Name"
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
    Copy-Item -LiteralPath (Get-HarnessEnvLockPath -StagingPath $materialization) -Destination (Join-Path $lockDir 'env.lock.json') -Force
    $statePath = Join-Path $AuthorityRoot 'current-env.json'
    $state = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($statePath)))
    $state['ControllerRepoFingerprint'] = $ControllerFingerprint
    $state['EnvironmentLockHash'] = (Get-HarnessFileHash -Path (Join-Path $lockDir 'env.lock.json')).ToLowerInvariant()
    [System.IO.File]::WriteAllBytes($statePath, (ConvertTo-SemanticJsonBytes -InputObject $state))
}

function Set-AuthorityTestDirectoryCurrentUserOnly {
    param([Parameter(Mandatory)] [string] $Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit), [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($Path)), $security)
}

function Write-AuthorityTestSemanticDocument {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, [System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $Document)), [System.Text.UTF8Encoding]::new($false))
}

# 1. Dispatcher routing and mode failures.
$routed = Invoke-EntryCli -Arguments @('env', 'authority')
Assert ($routed.Code -eq 1 -and $routed.Out -match 'requires an action') 'env authority without an action fails with guidance'
$badAction = Invoke-EntryCli -Arguments @('env', 'authority', 'promote')
Assert ($badAction.Code -eq 1 -and $badAction.Out -match 'Unsupported env authority action') 'an unsupported authority action is rejected'
$noMode = Invoke-EntryCli -Arguments @('env', 'authority', 'adopt', '-Name', 'good')
Assert ($noMode.Code -eq 1 -and $noMode.Out -match 'explicit -DryRun or -Apply') 'a transition without a mode is rejected'
$statusRun = Invoke-EntryCli -Arguments @('env', 'authority', 'status')
Assert ($statusRun.Code -eq 0 -and $statusRun.Out -match 'Authority route:') 'env authority status prints exactly one route'

# 2. Adopt: the first authority for a machine whose live roots already hold
#    content and whose legacy evidence is untrustworthy.
$sandboxA = New-AuthorityCliSandbox -Root (Join-Path $work 'authority-cli-a')
$cliSandbox = $sandboxA.Sandbox
$cliRepo = $sandboxA.Repo
$cliHome = $sandboxA.Home
$cliContext = $sandboxA.Context
$cliAuthorityRoot = $sandboxA.AuthorityRoot
Assert ([string] (Get-CanonicalSetupStatus -RepoRoot $cliRepo -ToolchainRoot $RepoRoot) -ceq 'canonical-ready') 'the seeded canonical setup is accepted'

$bothModes = Invoke-EntryCli -Arguments @('env', 'authority', 'adopt', '-Name', 'good', '-DryRun', '-Apply', '-PlanPath', (Join-Path $cliSandbox 'both.json'))
Assert ($bothModes.Code -eq 1 -and $bothModes.Out -match 'only one mode') 'a transition with both modes is rejected'
$statusWithPlan = Invoke-EntryCli -Arguments @('env', 'authority', 'status', '-PlanPath', (Join-Path $cliSandbox 'x.json'))
Assert ($statusWithPlan.Code -eq 1 -and $statusWithPlan.Out -match 'neither -Name nor -PlanPath') 'status rejects transition switches'
$missingName = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'p1.json'), '-RepoRoot', $cliRepo)
Assert ($missingName.Code -eq 1 -and $missingName.Out -match 'authority-name-required') 'a transition without a name is rejected'
$missingPlan = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-RepoRoot', $cliRepo)
Assert ($missingPlan.Code -eq 1 -and $missingPlan.Out -match 'authority-plan-path-required') 'a transition without a plan path is rejected'
$wrongEvidence = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'p2.json'), '-LegacyStatePath', (Join-Path $cliRepo 'state/current-env.json'), '-RepoRoot', $cliRepo)
Assert ($wrongEvidence.Code -eq 1 -and $wrongEvidence.Out -match 'authority-argument-unsupported') 'adopt rejects migrate-only evidence switches'
$switchOnTakeover = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'p3.json'), '-ReasonixLiveSkillsPath', (Join-Path $cliSandbox 'custom'), '-RepoRoot', $cliRepo)
Assert ($switchOnTakeover.Code -eq 1 -and $switchOnTakeover.Out -match 'authority-argument-unsupported') 'takeover rejects the intended-root switch'
$routeMismatch = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'p6.json'), '-RepoRoot', $cliRepo)
Assert ($routeMismatch.Code -eq 1 -and $routeMismatch.Out -match 'authority-route-mismatch') 'a transition that is not the single current route is rejected'
$insideRepo = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliRepo 'plan.json'), '-RepoRoot', $cliRepo)
Assert ($insideRepo.Code -eq 1 -and $insideRepo.Out -match 'disjoint from worktree') 'a plan path inside the worktree is rejected'
$insideGit = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliRepo '.git/plan.json'), '-RepoRoot', $cliRepo)
Assert ($insideGit.Code -eq 1 -and $insideGit.Out -match 'disjoint from worktree') 'a plan path inside Git internals is rejected'

# Untrustworthy legacy evidence still adopts, bound as UNTRUSTED.
Set-File -Path (Join-Path $cliRepo 'state/current-env.json') -Content '{"SchemaVersion":2}'
$untrustedPlan = Join-Path $cliSandbox 'adopt-untrusted-plan.json'
$untrusted = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', $untrustedPlan, '-RepoRoot', $cliRepo)
Assert ($untrusted.Code -eq 0) 'adopt succeeds with untrustworthy legacy evidence'
$untrustedDocument = Test-AuthorityPlanDocument -Path $untrustedPlan -ExpectedKind 'adopt'
Assert ([string] $untrustedDocument.PlanPayload.LegacyEvidence.Status -ceq 'UNTRUSTED') 'untrustworthy legacy evidence binds UNTRUSTED'
Remove-Item -LiteralPath (Join-Path $cliRepo 'state/current-env.json') -Force

$adoptPlan = Join-Path $cliSandbox 'adopt-plan.json'
$adopt = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
Assert ($adopt.Code -eq 0) 'adopt DryRun succeeds inside the sandbox'
$adoptDocument = Test-AuthorityPlanDocument -Path $adoptPlan -ExpectedKind 'adopt'
Assert ([string] $adoptDocument.PlanPayload.LegacyEvidence.Status -ceq 'MISSING') 'adopt without legacy evidence binds MISSING'
Assert (@($adoptDocument.PlanPayload.ProposedRootClaims.LiveRootClaims).Count -eq 3) 'adopt binds the three proposed root claims'
Assert (@($adoptDocument.PlanPayload.OrderedActions).Count -gt 0) 'adopt binds the managed install actions'
Assert (@($adoptDocument.PlanPayload.UnknownMarkers).Count -eq 1) 'adopt records the unknown live directory as a preserved marker'
$claudeSlot = @($adoptDocument.PlanPayload.Platforms | Where-Object { [string] $_.Platform -ceq 'Claude' })[0]
Assert ([bool] $claudeSlot.LiveRootExists) 'adopt binds the existing live root as a platform slot'
$adoptAgain = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
Assert ($adoptAgain.Code -eq 1 -and $adoptAgain.Out -match 'live-plan-path-collision') 'a second DryRun at the same plan path is refused'
$applyMissing = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', (Join-Path $cliSandbox 'never.json'), '-RepoRoot', $cliRepo)
Assert ($applyMissing.Code -eq 1 -and $applyMissing.Out -match 'missing') 'Apply refuses a plan path that does not exist'
$interlockedDirect = Invoke-AuthorityCli -Direct -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
if ($script:IsReleased) {
    Assert ($interlockedDirect.Code -eq 1 -and $interlockedDirect.Out -match 'home-authority-bootstrap-manual-recovery-required') 'production Apply outside the approved sandbox fails closed at the home-authority bootstrap gate under the released policy'
}
else {
    Assert ($interlockedDirect.Code -eq 1 -and $interlockedDirect.Out -match 'safety-protocol-upgrade-required') 'production Apply stays interlocked outside the approved sandbox'
}
$applyMismatch = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-Apply', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
Assert ($applyMismatch.Code -eq 1) 'Apply refuses a plan whose operation kind differs from the action'

$applyAdopt = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
if ($applyAdopt.Code -ne 0) { Write-Host "  note  adopt apply:"; Write-Host $applyAdopt.Out }
Assert ($applyAdopt.Code -eq 0) 'adopt Apply runs the reviewed composition end to end'
Assert (Test-Path -LiteralPath (Join-Path $cliAuthorityRoot 'root-claims.json') -PathType Leaf) 'adopt Apply publishes the immutable root claims'
Assert (Test-Path -LiteralPath (Join-Path $cliAuthorityRoot 'current-env.json') -PathType Leaf) 'adopt Apply publishes the schema 3 state'
Assert (Test-Path -LiteralPath (Join-Path $cliHome '.claude/skills/fixture-a/SKILL.md') -PathType Leaf) 'adopt Apply installs the managed live skills'
Assert (Test-Path -LiteralPath (Join-Path $cliHome '.claude/skills/fixture-b/SKILL.md') -PathType Leaf) 'adopt Apply installs the second managed Claude skill'
Assert (Test-Path -LiteralPath (Join-Path $cliHome '.claude/skills/existing-local/SKILL.md') -PathType Leaf) 'adopt Apply preserves the unknown live directory'
Assert (Test-Path -LiteralPath (Join-Path $cliHome 'AppData/Roaming/reasonix/skills/fixture-a/SKILL.md') -PathType Leaf) 'adopt Apply materializes the absent Reasonix live root'
$publishedState = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $cliAuthorityRoot 'current-env.json'))))
Assert ([string] $publishedState.LastOperationKind -ceq 'adopt') 'the published state records the adopt operation kind'
Assert ([string] $publishedState.EnvironmentName -ceq 'good') 'the published state records the selected environment'
Assert ([string] $publishedState.RootClaimsHash -ceq [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes((Join-Path $cliAuthorityRoot 'root-claims.json')))).ToLowerInvariant()) 'the published state binds the exact claims bytes'
$publishedClaims = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $cliAuthorityRoot 'root-claims.json'))))
Assert ([string] $publishedClaims.HomeAuthorityKey -ceq [string] $cliContext.HomeAuthorityKey) 'the published claims carry the derived authority key'
Assert (@(Get-ChildItem -LiteralPath ([string] $cliContext.LiveTransactionsRoot) -Directory -Force -ErrorAction SilentlyContinue).Count -ge 1) 'adopt Apply publishes a live transaction namespace'
$applyAdoptAgain = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
# The terminal journal evidence now consumes the document hash: a completed
# plan cannot mutate twice, whatever kind produced it.
Assert ($applyAdoptAgain.Code -eq 1 -and $applyAdoptAgain.Out -match 'live-plan-consumed') 'a completed authority consumes its plan so a replay is refused'
$migrateOnExistingAuthority = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'migrate-after.json'), '-LegacyStatePath', (Join-Path $cliRepo 'state/current-env.json'), '-RepoRoot', $cliRepo)
Assert ($migrateOnExistingAuthority.Code -eq 1) 'a first-authority transition is refused once an authority exists'

# 3. Repair-adopt: the claims stay immutable while the corrupt state is replaced.
$corruptStatePath = Join-Path $cliAuthorityRoot 'current-env.json'
Set-File -Path $corruptStatePath -Content '{ corrupt'
$claimsPathRepair = Join-Path $cliAuthorityRoot 'root-claims.json'
$claimsHashBeforeRepair = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($claimsPathRepair))).ToLowerInvariant()
$repairPlan = Join-Path $cliSandbox 'repair-plan.json'
$repair = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'good', '-DryRun', '-PlanPath', $repairPlan, '-CorruptStatePath', $corruptStatePath, '-RepoRoot', $cliRepo)
if ($repair.Code -ne 0) { Write-Host "  note  repair dryrun:"; Write-Host $repair.Out }
Assert ($repair.Code -eq 0) 'repair-adopt DryRun succeeds for a corrupt state with valid claims'
$repairDocument = Test-AuthorityPlanDocument -Path $repairPlan -ExpectedKind 'repair-adopt'
Assert ([string] $repairDocument.PlanPayload.StateEvidence.Kind -ceq 'CORRUPT') 'repair-adopt binds the CORRUPT state evidence'
Assert ([string] $repairDocument.PlanPayload.StateEvidence.Path -ceq $corruptStatePath) 'repair-adopt binds the exact state path'
Assert (-not $repairDocument.PlanPayload.Contains('LegacyEvidence')) 'repair-adopt never carries adopt evidence'
Assert (-not $repairDocument.PlanPayload.Contains('ProposedRootClaims')) 'repair-adopt never re-proposes the immutable claims'
Assert ([string] $repairDocument.PlanPayload.AuthorityStateIntent.RootClaimsHash -ceq $claimsHashBeforeRepair) 'the repair plan binds the exact current claims bytes hash'
$repairApply = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'good', '-Apply', '-PlanPath', $repairPlan, '-CorruptStatePath', $corruptStatePath, '-RepoRoot', $cliRepo)
if ($repairApply.Code -ne 0) { Write-Host "  note  repair apply:"; Write-Host $repairApply.Out }
Assert ($repairApply.Code -eq 0) 'repair-adopt Apply runs the reviewed composition'
Assert ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($claimsPathRepair))).ToLowerInvariant() -ceq $claimsHashBeforeRepair) 'repair-adopt keeps the immutable claims byte-identical'
$repairedState = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($corruptStatePath)))
Assert ([string] $repairedState.LastOperationKind -ceq 'repair-adopt') 'the repaired state records the repair-adopt operation kind'
Assert ([string] $repairedState.HomeAuthorityKey -ceq [string] $cliContext.HomeAuthorityKey) 'the repaired state keeps the authority key'
$repairReplay = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'good', '-Apply', '-PlanPath', $repairPlan, '-CorruptStatePath', $corruptStatePath, '-RepoRoot', $cliRepo)
Assert ($repairReplay.Code -eq 1 -and $repairReplay.Out -match 'live-plan-consumed') 'a completed repair consumes its plan so a replay is refused'
# The state is valid again after the repair; the missing-evidence refusal needs
# its own corrupt precondition.
Set-File -Path $corruptStatePath -Content '{ corrupt'
$repairWithoutEvidence = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'repair-missing-evidence.json'), '-RepoRoot', $cliRepo)
Assert ($repairWithoutEvidence.Code -eq 1 -and $repairWithoutEvidence.Out -match 'authority-state-evidence-required') 'repair-adopt requires the corrupt state path for the CORRUPT branch'

# 4. The MISSING state branch of the same transition: no corrupt evidence path
#    is allowed, the plan binds only the missing marker, and the apply creates
#    the state new next to the immutable claims.
Remove-Item -LiteralPath $corruptStatePath -Force
$forbiddenEvidence = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'repair-forbidden-evidence.json'), '-CorruptStatePath', $corruptStatePath, '-RepoRoot', $cliRepo)
Assert ($forbiddenEvidence.Code -eq 1 -and $forbiddenEvidence.Out -match 'authority-state-evidence-forbidden') 'the MISSING branch rejects a corrupt evidence path'
$missingPlan = Join-Path $cliSandbox 'repair-missing-state-plan.json'
$missingRepair = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'good', '-DryRun', '-PlanPath', $missingPlan, '-RepoRoot', $cliRepo)
if ($missingRepair.Code -ne 0) { Write-Host "  note  missing-state repair dryrun:"; Write-Host $missingRepair.Out }
Assert ($missingRepair.Code -eq 0) 'repair-adopt DryRun succeeds for a missing state with valid claims'
$missingDocument = Test-AuthorityPlanDocument -Path $missingPlan -ExpectedKind 'repair-adopt'
Assert ([string] $missingDocument.PlanPayload.StateEvidence.Kind -ceq 'MISSING' -and [bool] $missingDocument.PlanPayload.StateEvidence.Marker) 'the MISSING branch binds only the missing marker'
Assert (-not $missingDocument.PlanPayload.Contains('ProposedRootClaims')) 'the MISSING branch never re-proposes the immutable claims'
$missingApply = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'good', '-Apply', '-PlanPath', $missingPlan, '-RepoRoot', $cliRepo)
if ($missingApply.Code -ne 0) { Write-Host "  note  missing-state repair apply:"; Write-Host $missingApply.Out }
Assert ($missingApply.Code -eq 0) 'repair-adopt Apply creates a missing state next to the claims'
Assert ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($claimsPathRepair))).ToLowerInvariant() -ceq $claimsHashBeforeRepair) 'the MISSING branch keeps the claims byte-identical'

# 5. Takeover binds the previous controller and carries no live actions.
$stateForTakeover = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($corruptStatePath)))
$currentControllerFingerprint = [string] $stateForTakeover['ControllerRepoFingerprint']
$sameController = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'takeover-same.json'), '-RepoRoot', $cliRepo)
Assert ($sameController.Code -eq 1 -and $sameController.Out -match 'authority-route-mismatch') 'takeover is refused while the current controller owns the authority'
# The state-bound activation lock is what the assessment verifies against the
# live trees; publishing the plan's materialization lock into the repository's
# env staging stands in for the activation publication that Task 6 wires.
Set-AuthorityForeignControllerState -AuthorityRoot $cliAuthorityRoot -Repo $cliRepo -Name 'good' -PlanPath $missingPlan
$takeoverPlan = Join-Path $cliSandbox 'takeover-plan.json'
$takeover = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-DryRun', '-PlanPath', $takeoverPlan, '-RepoRoot', $cliRepo)
if ($takeover.Code -ne 0) { Write-Host "  note  takeover dryrun:"; Write-Host $takeover.Out }
Assert ($takeover.Code -eq 0) 'takeover DryRun succeeds for a foreign controller with verified parity'
$takeoverDocument = Test-AuthorityPlanDocument -Path $takeoverPlan -ExpectedKind 'controller-transition'
Assert ([string] $takeoverDocument.PlanPayload.ControllerParity.PreviousControllerRepoFingerprint -ceq ('0' * 64)) 'takeover binds the previous controller fingerprint'
Assert (@($takeoverDocument.PlanPayload.OrderedActions).Count -eq 0) 'takeover carries no live actions'
Assert ([string] $takeoverDocument.PlanPayload.AuthorityStateIntent.ReceiptRef -ceq 'NO_LIVE_MUTATION') 'takeover declares the no-live-mutation receipt reference'
Assert (-not $takeoverDocument.PlanPayload.Contains('EnvironmentMaterializationRoot')) 'takeover binds no materialization root'
Assert ([string] $currentControllerFingerprint -cne ('0' * 64)) 'the fixture starts from the real controller fingerprint'
# The name is not a selector for a takeover: only the selection the authority
# already carries is accepted. This runs while the state still names a foreign
# controller, because after the transition the route is no longer takeover.
$wrongNameTakeover = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'other', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'takeover-wrong-name.json'), '-RepoRoot', $cliRepo)
Assert ($wrongNameTakeover.Code -eq 1 -and $wrongNameTakeover.Out -match 'authority-selection-name-mismatch') 'takeover refuses a name the authority does not select'

# The takeover Apply runs the state-only sequence: controller metadata is the
# only committed change, no receipt is created, and every live tree plus the
# immutable claims stay byte-identical.
$takeoverClaimsBefore = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($claimsPathRepair))).ToLowerInvariant()
$takeoverLiveRoots = [ordered]@{
    Claude = (Join-Path $cliHome '.claude/skills')
    Codex = (Join-Path $cliHome '.codex/skills')
    Reasonix = (Join-Path $cliHome 'AppData/Roaming/reasonix/skills')
}
$takeoverLiveBefore = [ordered]@{}
foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
    $takeoverLiveBefore[$platform] = Get-HarnessTreeHash -Path ([string] $takeoverLiveRoots[$platform])
}
$takeoverBackupsBefore = @(Get-ChildItem -LiteralPath ([string] $cliContext.BackupRoot) -Directory -Force -ErrorAction SilentlyContinue).Count
$takeoverApply = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-Apply', '-PlanPath', $takeoverPlan, '-RepoRoot', $cliRepo)
if ($takeoverApply.Code -ne 0) { Write-Host "  note  takeover apply:"; Write-Host $takeoverApply.Out }
Assert ($takeoverApply.Code -eq 0) 'takeover Apply commits the controller transition state-only'
$takeoverState = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($corruptStatePath)))
Assert ([string] $takeoverState.LastOperationKind -ceq 'controller-transition') 'the takeover state records the controller-transition kind'
Assert ([string] $takeoverState.ReceiptRef -ceq 'NO_LIVE_MUTATION') 'the takeover state declares no live mutation'
Assert (-not $takeoverState.Contains('ReceiptId') -and -not $takeoverState.Contains('ReceiptHash')) 'the takeover state carries no receipt fields'
Assert ([string] $takeoverState.ControllerRepoFingerprint -ceq [string] $takeoverDocument.PlanPayload.ControllerRepoFingerprint) 'the takeover state adopts the planning controller'
Assert ([string] $takeoverState.ControllerRepoFingerprint -cne ('0' * 64)) 'the takeover state no longer names the previous controller'
Assert ([string] $takeoverState.EnvironmentName -ceq 'good') 'the takeover preserves the environment selection'
Assert ([string] $takeoverState.RootClaimsHash -ceq $takeoverClaimsBefore) 'the takeover state keeps the claims bytes hash'
Assert ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($claimsPathRepair))).ToLowerInvariant() -ceq $takeoverClaimsBefore) 'takeover keeps the immutable claims byte-identical'
foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
    Assert ((Get-HarnessTreeHash -Path ([string] $takeoverLiveRoots[$platform])) -ceq $takeoverLiveBefore[$platform]) "takeover leaves the $platform live tree byte-identical"
}
Assert (Test-Path -LiteralPath (Join-Path $cliHome '.claude/skills/existing-local/SKILL.md') -PathType Leaf) 'takeover preserves the unknown live directory'
Assert (@(Get-ChildItem -LiteralPath ([string] $cliContext.BackupRoot) -Directory -Force -ErrorAction SilentlyContinue).Count -eq $takeoverBackupsBefore) 'a state-only takeover creates no backup receipt'
$takeoverTransactions = @(Get-ChildItem -LiteralPath ([string] $cliContext.LiveTransactionsRoot) -Directory -Force | Sort-Object LastWriteTimeUtc)
$takeoverJournalDir = $takeoverTransactions[-1].FullName
$takeoverJournal = Get-InjectionJournalSummary -TransactionDirectory $takeoverJournalDir
Assert ($takeoverJournal.LastPhase -ceq 'COMPLETE' -and $takeoverJournal.HasResult) 'the takeover journal closes with a result and the terminal record'
$takeoverHeader = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $takeoverJournalDir 'header.json'))))
Assert ([string] $takeoverHeader.TransactionMode -ceq 'state-only') 'the takeover journal header is state-only'
Assert ([string] $takeoverHeader.ReceiptRef -ceq 'NO_LIVE_MUTATION') 'the takeover journal header names no live mutation'
Assert (-not $takeoverHeader.Contains('ReceiptIntent')) 'the takeover journal header carries no receipt intent'
$takeoverResult = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $takeoverJournalDir 'result.json'))))
Assert ([string] $takeoverResult.Outcome -ceq 'committed' -and [string] $takeoverResult.OperationKind -ceq 'controller-transition') 'the takeover result commits the controller transition'
Assert (-not $takeoverResult.Contains('ReceiptRef')) 'the state-only result carries no receipt reference'

# A replayed takeover is refused: under the lock the state no longer names the
# plan's previous controller, so parity fails closed.
$takeoverReplay = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-Apply', '-PlanPath', $takeoverPlan, '-RepoRoot', $cliRepo)
Assert ($takeoverReplay.Code -eq 1 -and $takeoverReplay.Out -match 'live-plan-consumed') 'a completed takeover consumes its plan so a replay is refused'
# A receipt-bearing controller-transition plan and a NO_LIVE_MUTATION live plan
# are both rejected by the frozen plan contract. Each tampered copy recomputes
# its envelope hashes so the semantic layer, not the integrity gate, decides.
function New-TamperedPlanDocument {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Field,
        [Parameter(Mandatory)] [string] $Value
    )
    $document = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($Path)))
    $document['PlanPayload']['AuthorityStateIntent'][$Field] = $Value
    $document['PlanHash'] = Get-PlanHash -PlanPayload $document['PlanPayload']
    $document['DocumentHash'] = Get-DocumentHash -Document $document
    return $document
}
$livePlanWithNoMutation = New-TamperedPlanDocument -Path $adoptPlan -Field 'ReceiptRef' -Value 'NO_LIVE_MUTATION'
$noMutationRejected = $false
try { Test-LiveSyncPlanSemantics -Document $livePlanWithNoMutation } catch { $noMutationRejected = ([string] $_.Exception.Message -ceq 'live-plan-operation-kind-mismatch') }
Assert $noMutationRejected 'a live transition plan cannot declare NO_LIVE_MUTATION'
$receiptBearingTransition = New-TamperedPlanDocument -Path $takeoverPlan -Field 'ReceiptId' -Value '00000000-0000-0000-0000-000000000000'
$receiptBearingRejected = $false
try { Test-LiveSyncPlanSemantics -Document $receiptBearingTransition } catch { $receiptBearingRejected = ([string] $_.Exception.Message -ceq 'live-plan-schema-unsupported') }
Assert $receiptBearingRejected 'a plan document cannot carry a runtime receipt field'

# A state-preimage failure fails closed: when the bound state file disappears
# between the plan and the apply, the host refuses before it writes anything.
Set-AuthorityForeignControllerState -AuthorityRoot $cliAuthorityRoot -Repo $cliRepo -Name 'good' -PlanPath $missingPlan -ControllerFingerprint ('1' * 64)
$preimagePlan = Join-Path $cliSandbox 'takeover-preimage-plan.json'
$preimageDryRun = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-DryRun', '-PlanPath', $preimagePlan, '-RepoRoot', $cliRepo)
Assert ($preimageDryRun.Code -eq 0) 'the state-preimage case plans against the foreign controller'
$preimageStateBytes = [System.IO.File]::ReadAllBytes($corruptStatePath)
Remove-Item -LiteralPath $corruptStatePath -Force
$preimageApply = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-Apply', '-PlanPath', $preimagePlan, '-RepoRoot', $cliRepo)
Assert ($preimageApply.Code -eq 1 -and $preimageApply.Out -match 'live-transaction-authority-required') 'a takeover whose state disappeared is refused before any mutation'
Assert (-not (Test-Path -LiteralPath $corruptStatePath)) 'the refused takeover does not recreate the state'
[System.IO.File]::WriteAllBytes($corruptStatePath, $preimageStateBytes)
Assert (@(Get-ChildItem -LiteralPath ([string] $cliContext.LiveTransactionsRoot) -Directory -Force).Count -eq $takeoverTransactions.Count) 'the refused takeover publishes no journal namespace'

# 6. The state-only transition's public kill window: a hard kill before the
#    state replace leaves the previous controller byte-identical on disk with an
#    unfinished journal that blocks every later mutation (the engine-level kill
#    matrix for the remaining windows stays with the Phase 2 live-recovery suite).
$sandboxK = New-AuthorityCliSandbox -Root (Join-Path $work 'authority-cli-takeover-kill')
$killAdoptPlan = Join-Path $sandboxK.Sandbox 'adopt-plan.json'
$killAdopt = Invoke-AuthorityCli -SandboxRoot $sandboxK.Sandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', $killAdoptPlan, '-RepoRoot', $sandboxK.Repo)
Assert ($killAdopt.Code -eq 0) 'the kill-window machine plans its first authority'
$killAdoptApply = Invoke-AuthorityCli -SandboxRoot $sandboxK.Sandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', $killAdoptPlan, '-RepoRoot', $sandboxK.Repo)
Assert ($killAdoptApply.Code -eq 0) 'the kill-window machine establishes its authority'
Set-AuthorityForeignControllerState -AuthorityRoot $sandboxK.AuthorityRoot -Repo $sandboxK.Repo -Name 'good' -PlanPath $killAdoptPlan
$killTakeoverPlan = Join-Path $sandboxK.Sandbox 'takeover-kill-plan.json'
$killTakeoverDryRun = Invoke-AuthorityCli -SandboxRoot $sandboxK.Sandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-DryRun', '-PlanPath', $killTakeoverPlan, '-RepoRoot', $sandboxK.Repo)
Assert ($killTakeoverDryRun.Code -eq 0) 'the kill-window takeover plans against a foreign controller'
$killStatePath = Join-Path $sandboxK.AuthorityRoot 'current-env.json'
$killStateHashBefore = Get-HarnessFileHash -Path $killStatePath
$killedTakeover = Invoke-AuthorityCliKilledAtCheckpoint -SandboxRoot $sandboxK.Sandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-Apply', '-PlanPath', $killTakeoverPlan, '-RepoRoot', $sandboxK.Repo) -Checkpoint 'STATE_REPLACE_PENDING'
Assert ($killedTakeover.Code -ne 0) 'the takeover host is killed before the state replace'
Assert ((Get-HarnessFileHash -Path $killStatePath) -ceq $killStateHashBefore) 'a kill before the state replace leaves the previous controller bytes in place'
$killJournalDir = (@(Get-ChildItem -LiteralPath ([string] $sandboxK.Context.LiveTransactionsRoot) -Directory -Force) | Sort-Object LastWriteTimeUtc)[-1].FullName
$killJournal = Get-InjectionJournalSummary -TransactionDirectory $killJournalDir
Assert ($killJournal.UnknownCount -eq 0) 'the killed takeover leaves no unknown journal entries'
Assert ($killJournal.LastPhase -ceq 'FILE_REPLACE_INTENT' -and -not $killJournal.HasResult) 'the killed takeover stops before the state replace with no result'
$killReplay = Invoke-AuthorityCli -SandboxRoot $sandboxK.Sandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-Apply', '-PlanPath', $killTakeoverPlan, '-RepoRoot', $sandboxK.Repo)
Assert ($killReplay.Code -eq 1 -and $killReplay.Out -match 'live-recovery-required') 'the unfinished takeover blocks the next apply'

# 7. Claim identity drift fails closed: a claimed root that was deleted and
#    recreated carries a new identity, and publishing a state with it would
#    contradict the immutable claim that no later repair could satisfy.
Set-File -Path $corruptStatePath -Content '{ corrupt'
Remove-Item -LiteralPath (Join-Path $cliHome '.claude/skills') -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $cliHome '.claude/skills') -Force | Out-Null
$driftPlan = Join-Path $cliSandbox 'repair-drift-plan.json'
$drift = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'good', '-DryRun', '-PlanPath', $driftPlan, '-CorruptStatePath', $corruptStatePath, '-RepoRoot', $cliRepo)
Assert ($drift.Code -eq 1 -and $drift.Out -match 'authority-claim-identity-drift') 'a recreated claimed root fails closed before any plan exists'
Assert (-not (Test-Path -LiteralPath $driftPlan)) 'the drift refusal writes no plan'

# 8. Migrate: its own first-authority machine with complete legacy evidence.
$sandboxB = New-AuthorityCliSandbox -Root (Join-Path $work 'authority-cli-b')
$migrateRepo = $sandboxB.Repo
$migrateHome = $sandboxB.Home
$null = New-LegacyActivationFixture -RepoRoot $migrateRepo -HomeRoot $migrateHome -Name 'good'
Assert ([string] (Get-CanonicalSetupStatus -RepoRoot $migrateRepo -ToolchainRoot $RepoRoot) -ceq 'canonical-ready') 'the second sandbox canonical setup is accepted'
$legacyStatePath = Join-Path $migrateRepo 'state/current-env.json'
$migrateWithoutLegacy = Invoke-AuthorityCli -SandboxRoot $sandboxB.Sandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $sandboxB.Sandbox 'p4.json'), '-RepoRoot', $migrateRepo)
Assert ($migrateWithoutLegacy.Code -eq 1 -and $migrateWithoutLegacy.Out -match 'authority-legacy-locator-required') 'migrate requires the exact legacy locator once the route is migrate'
$migrateWrongLocator = Invoke-AuthorityCli -SandboxRoot $sandboxB.Sandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $sandboxB.Sandbox 'p5.json'), '-LegacyStatePath', (Join-Path $sandboxB.Sandbox 'elsewhere.json'), '-RepoRoot', $migrateRepo)
Assert ($migrateWrongLocator.Code -eq 1 -and $migrateWrongLocator.Out -match 'authority-legacy-locator-mismatch') 'migrate rejects a legacy locator outside the exact repo path'
$migrateWrongName = Invoke-AuthorityCli -SandboxRoot $sandboxB.Sandbox -Arguments @('-Action', 'migrate', '-Name', 'other', '-DryRun', '-PlanPath', (Join-Path $sandboxB.Sandbox 'p7.json'), '-LegacyStatePath', $legacyStatePath, '-RepoRoot', $migrateRepo)
Assert ($migrateWrongName.Code -eq 1 -and $migrateWrongName.Out -match 'authority-legacy-name-mismatch') 'migrate requires the name the legacy state recorded'
$migratePlan = Join-Path $sandboxB.Sandbox 'migrate-plan.json'
$migrate = Invoke-AuthorityCli -SandboxRoot $sandboxB.Sandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-DryRun', '-PlanPath', $migratePlan, '-LegacyStatePath', $legacyStatePath, '-RepoRoot', $migrateRepo)
if ($migrate.Code -ne 0) { Write-Host "  note  migrate dryrun:"; Write-Host $migrate.Out }
Assert ($migrate.Code -eq 0) 'migrate DryRun succeeds for complete legacy evidence'
$migrateDocument = Test-AuthorityPlanDocument -Path $migratePlan -ExpectedKind 'migrate'
Assert ([string] $migrateDocument.PlanPayload.LegacyLocator -ceq [System.IO.Path]::GetFullPath($legacyStatePath)) 'migrate binds the exact legacy locator'
Assert ([string] $migrateDocument.PlanPayload.LegacyHash -ceq [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($legacyStatePath))).ToLowerInvariant()) 'migrate binds the legacy bytes hash'
Assert ([string] $migrateDocument.PlanPayload.OldLockHash -ceq (Get-HarnessFileHash -Path (Join-Path $migrateRepo 'envs/good/env.lock.json')).ToLowerInvariant()) 'migrate binds the preserved old lock hash'
Assert ([string] $migrateDocument.PlanPayload.LegacyCoreHash -cmatch '\A[0-9a-f]{64}\z') 'migrate binds a core hash'
Assert (-not $migrateDocument.PlanPayload.Contains('LegacyEvidence')) 'migrate never carries adopt evidence'
# The legacy locator is part of the contract on both invocations: an apply that
# names no locator, or a different one, is refused before it consumes the plan.
$migrateApplyNoLocator = Invoke-AuthorityCli -SandboxRoot $sandboxB.Sandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-Apply', '-PlanPath', $migratePlan, '-RepoRoot', $migrateRepo)
Assert ($migrateApplyNoLocator.Code -eq 1 -and $migrateApplyNoLocator.Out -match 'authority-legacy-locator-required') 'migrate Apply requires the exact legacy locator'
$migrateApplyWrongLocator = Invoke-AuthorityCli -SandboxRoot $sandboxB.Sandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-Apply', '-PlanPath', $migratePlan, '-LegacyStatePath', (Join-Path $sandboxB.Sandbox 'elsewhere.json'), '-RepoRoot', $migrateRepo)
Assert ($migrateApplyWrongLocator.Code -eq 1 -and $migrateApplyWrongLocator.Out -match 'authority-legacy-locator-mismatch') 'migrate Apply rejects a locator outside the exact repo path'
$migrateApply = Invoke-AuthorityCli -SandboxRoot $sandboxB.Sandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-Apply', '-PlanPath', $migratePlan, '-LegacyStatePath', $legacyStatePath, '-RepoRoot', $migrateRepo)
if ($migrateApply.Code -ne 0) { Write-Host "  note  migrate apply:"; Write-Host $migrateApply.Out }
Assert ($migrateApply.Code -eq 0) 'migrate Apply runs the reviewed composition'
$migrateState = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $sandboxB.AuthorityRoot 'current-env.json'))))
Assert ([string] $migrateState.LastOperationKind -ceq 'migrate') 'the migrated state records the migrate operation kind'
Assert (Test-Path -LiteralPath (Join-Path $migrateHome '.claude/skills/fixture-a/SKILL.md') -PathType Leaf) 'migrate Apply keeps the managed live skills installed'
Assert (Test-Path -LiteralPath $legacyStatePath -PathType Leaf) 'migrate never deletes the only legacy evidence'

# 9. Failure injection: one hard-killed window per required class (before the
#    receipt, during live mutation, during state create/replace, during the final
#    journal record). Every window gets its own machine: a hard-killed receipt-
#    backed transaction deliberately leaves an unfinished journal, and the next
#    Apply must refuse on exactly that evidence instead of resuming. RecordPhase
#    is the last durable record before the checkpoint, not the checkpoint name;
#    STATE_REPLACE_PENDING fires after FILE_REPLACE_INTENT and TERMINAL_RECORD
#    after POSTCONDITIONS_OK.
Write-Host '[failure injection windows]'
$injectionWindows = @(
    [ordered]@{ Checkpoint = 'RECEIPT_FINALIZATION'; RecordPhase = $null; Live = $false; Claims = $false; State = $false; Result = $false },
    [ordered]@{ Checkpoint = 'PREPARED'; RecordPhase = 'PREPARED'; Live = $false; Claims = $false; State = $false; Result = $false },
    [ordered]@{ Checkpoint = 'STATE_REPLACE_PENDING'; RecordPhase = 'FILE_REPLACE_INTENT'; Live = $true; Claims = $true; State = $false; Result = $false },
    [ordered]@{ Checkpoint = 'TERMINAL_RECORD'; RecordPhase = 'POSTCONDITIONS_OK'; Live = $true; Claims = $true; State = $true; Result = $true }
)
$windowIndex = 0
foreach ($window in $injectionWindows) {
    $windowIndex++
    $checkpoint = [string] $window['Checkpoint']
    $injection = New-AuthorityCliSandbox -Root (Join-Path $work "authority-cli-inject-$windowIndex")
    $injectionClaimsPath = Join-Path $injection.AuthorityRoot 'root-claims.json'
    $injectionStatePath = Join-Path $injection.AuthorityRoot 'current-env.json'
    $injectionPlan = Join-Path $injection.Sandbox "inject-$checkpoint-plan.json"
    $windowDryRun = Invoke-AuthorityCli -SandboxRoot $injection.Sandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', $injectionPlan, '-RepoRoot', $injection.Repo)
    Assert ($windowDryRun.Code -eq 0) "$checkpoint window plans an adopt for a fresh machine"
    $killed = Invoke-AuthorityCliKilledAtCheckpoint -SandboxRoot $injection.Sandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', $injectionPlan, '-RepoRoot', $injection.Repo) -Checkpoint $checkpoint
    Assert ($killed.Code -ne 0) "the $checkpoint window kills the authority host mid-flight"

    $transactions = @(Get-ChildItem -LiteralPath ([string] $injection.Context.LiveTransactionsRoot) -Directory -Force -ErrorAction SilentlyContinue)
    Assert ($transactions.Count -eq 1) "the $checkpoint window publishes exactly one unfinished journal namespace"
    $journal = Get-InjectionJournalSummary -TransactionDirectory $transactions[0].FullName
    Assert ($journal.UnknownCount -eq 0) "the $checkpoint window leaves no unknown journal entries"
    if ($null -eq $window['RecordPhase']) {
        # The reservation window precedes the first journal record.
        Assert ($journal.RecordCount -eq 0 -and $null -eq $journal.LastPhase) "the $checkpoint window stops before the first journal record"
    }
    else {
        Assert ($journal.LastPhase -ceq [string] $window['RecordPhase']) "the $checkpoint window stops on its own phase"
    }
    Assert ($journal.HasResult -eq [bool] $window['Result']) "the $checkpoint window result evidence matches its class"
    Assert ((Test-Path -LiteralPath (Join-Path $injection.Home '.claude/skills/fixture-a/SKILL.md') -PathType Leaf) -eq [bool] $window['Live']) "the $checkpoint window live evidence matches its class"
    Assert ((Test-Path -LiteralPath $injectionClaimsPath -PathType Leaf) -eq [bool] $window['Claims']) "the $checkpoint window claims evidence matches its class"
    Assert ((Test-Path -LiteralPath $injectionStatePath -PathType Leaf) -eq [bool] $window['State']) "the $checkpoint window state evidence matches its class"

    $refused = Invoke-AuthorityCli -SandboxRoot $injection.Sandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', $injectionPlan, '-RepoRoot', $injection.Repo)
    # Windows that published the authority hit the first-authority guard, the
    # earlier ones hit the unfinished-transaction gate; both stay fail-closed
    # and neither resumes the killed transaction.
    $expectedRefusal = if ([bool] $window['Claims']) { 'live-transaction-authority-present' } else { 'live-recovery-required' }
    Assert ($refused.Code -eq 1 -and $refused.Out -match $expectedRefusal) "the $checkpoint window refuses the next Apply with $expectedRefusal"
}

# 10. Takeover still requires a valid authority pair: a machine without one
#     routes elsewhere and the transition is refused.
$sandboxC = New-AuthorityCliSandbox -Root (Join-Path $work 'authority-cli-c')
$takeoverRefused = Invoke-AuthorityCli -SandboxRoot $sandboxC.Sandbox -Arguments @('-Action', 'takeover', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $sandboxC.Sandbox 'takeover.json'), '-RepoRoot', $sandboxC.Repo)
Assert ($takeoverRefused.Code -eq 1 -and $takeoverRefused.Out -match 'authority-route-mismatch') 'takeover is refused without a valid authority pair'

# 11. Ordinary activate/sync never reach a transition.
$syncDryRun = Invoke-SafetySandboxScript -SandboxRoot $cliSandbox -ScriptPath (Join-Path $RepoRoot 'scripts/sync.ps1') -Arguments @('-DryRun', '-PlanPath', (Join-Path $cliSandbox 'sync-plan.json'), '-RepoRoot', $cliRepo) -AuthorityRepoRoot $RepoRoot
Assert ($syncDryRun.Code -ne 0) 'ordinary sync cannot plan over an existing authority context'
if (Test-Path -LiteralPath (Join-Path $cliSandbox 'sync-plan.json')) {
    $syncDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $cliSandbox 'sync-plan.json'))))
    Assert ([string] $syncDocument.PlanPayload.OperationKind -cin @('initial', 'retirement')) 'sync can only ever emit its own operation kinds'
}

# ==============================================================================
Write-Host 'Phase 3 Task 8: the pinned runner preview route table and its bundle closure'
$runnerPolicy = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'scripts/runner-policy.psd1')
$previewRoutes = $runnerPolicy.PreviewRouteActions
Assert ($previewRoutes -is [System.Collections.IDictionary]) 'the runner policy carries a preview route table'
$authorityRoutes = @($script:HarnessEnvAuthorityRouteNextOperation.Keys | Sort-Object { [string] $_ })
$policyRoutes = @($previewRoutes.Keys | Sort-Object { [string] $_ })
Assert (@(Compare-Object $authorityRoutes $policyRoutes).Count -eq 0) 'the preview route table covers exactly the frozen authority route set'
foreach ($route in $authorityRoutes) {
    $row = $previewRoutes[$route]
    $nextOperation = [string] $script:HarnessEnvAuthorityRouteNextOperation[$route]
    $expectedAction = if ($nextOperation -clike 'env activate*') { 'environment-preview' } else { 'diagnostic' }
    Assert (([string] $row['Action']) -ceq $expectedAction -and -not [string]::IsNullOrWhiteSpace([string] $row['Command'])) "the $route route is pinned to its $expectedAction action"
    Assert (([string] $row['Command']) -ceq $nextOperation) "the $route route command is exactly the frozen next operation"
}
$environmentPreviewRoutes = @($policyRoutes | Where-Object { [string] $previewRoutes[$_]['Action'] -ceq 'environment-preview' })
Assert (($environmentPreviewRoutes -join ',') -ceq 'activate,initial') 'only the activate and initial routes may materialize a build'

$task8BundlePins = @(
    'scripts/harness-profile-common.ps1'
    'scripts/harness-authority-status-common.ps1'
    'scripts/live-transaction-common.ps1'
    'scripts/backup-receipt-common.ps1'
    'scripts/status-harness-env.ps1'
    'scripts/list-harness-env.ps1'
    'schemas/harness-env-build.schema.json'
    'schemas/harness-env-lock.schema.json'
    'schemas/harness-env-list.schema.json'
    'schemas/harness-env-status.schema.json'
    'schemas/live-journal-header.schema.json'
    'schemas/live-journal-record.schema.json'
)
$missingPins = @($task8BundlePins | Where-Object { @($runnerPolicy.ToolchainPaths) -cnotcontains $_ })
Assert ($missingPins.Count -eq 0) 'the approved toolchain bundle pins the authority/status/materialization dependencies of the routing'
# The bundle's shape has always included two root-level toolchain entrypoints
# (the scanner config and the bootstrap entrypoint) next to the scripts/,
# schemas/, and tools/ trees; anything else — and any overlap with the data
# pathspecs — would mean the pinned bundle started selecting working data.
$rootLevelToolchainEntries = @('.gitleaks.toml', 'bootstrap.ps1')
$outsideBundleRoots = @($runnerPolicy.ToolchainPaths | Where-Object { $_ -cnotmatch '\Ascripts/|schemas/|tools/' -and $rootLevelToolchainEntries -cnotcontains $_ })
Assert ($outsideBundleRoots.Count -eq 0) 'the toolchain bundle keeps selecting only toolchain and schema paths'
$dataPathspecOverlap = @($runnerPolicy.ToolchainPaths | Where-Object { @($runnerPolicy.DataPathspecs) -ccontains $_ })
Assert ($dataPathspecOverlap.Count -eq 0) 'the toolchain bundle never overlaps the data pathspecs'

Write-Host ("harness-authority tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) {
    Write-Host "Workspace kept for inspection: $work"
    exit 1
}
Remove-Work
exit 0
