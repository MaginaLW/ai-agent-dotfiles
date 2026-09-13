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
$controllerFingerprint = Get-CanonicalRepoIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $authorityRepo)
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

# One sandbox hosts the whole command-surface section: the fake controller
# repository lives inside it so every mutation path stays inside the sandbox.
$cliWork = Join-Path $work 'authority-cli'
$cliSandbox = Join-Path $cliWork 'sandbox'
New-Item -ItemType Directory -Path $cliSandbox -Force | Out-Null
$cliRepo = New-FakeHarnessRepo -Path (Join-Path $cliSandbox 'repo')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools') -Destination (Join-Path $cliRepo 'tools') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'schemas') -Destination (Join-Path $cliRepo 'schemas') -Recurse -Force
Set-File -Path (Join-Path $cliRepo 'harness-source/envs/good.psd1') -Content (New-EnvDefinitionText -Name 'good' -ClaudeSkills @('fixture-a', 'fixture-b') -CodexSkills @('fixture-a') -ReasonixSkills @('fixture-a'))
Set-File -Path (Join-Path $cliRepo 'harness-source/envs/full.psd1') -Content (New-EnvDefinitionText -Name 'full' -ClaudeSkills @('fixture-a', 'fixture-b') -CodexSkills @('fixture-a') -ReasonixSkills @('fixture-a'))
& git -C $cliRepo add -A 2>&1 | Out-Null
& git -C $cliRepo -c user.email=fixture@example.invalid -c user.name=fixture commit --quiet -m fixture
$cliHome = Join-Path $cliSandbox 'home'
New-ManagedLiveSkill -HomeRoot $cliHome -PlatformKey 'claude' -Name 'existing-local' -Content '# existing'
$cliControl = Join-Path $cliHome 'AppData/Local/ai-agent-dotfiles/control'
New-Item -ItemType Directory -Path (Join-Path $cliHome 'AppData/Roaming') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $cliHome 'AppData/Local') -Force | Out-Null
$cliIdentity = [pscustomobject][ordered]@{
    ResolverVersion = 'sealed-home-authority-test-adapter-v1'
    TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    ProfileRoot = $cliHome
    RoamingAppDataRoot = (Join-Path $cliHome 'AppData/Roaming')
    LocalAppDataRoot = (Join-Path $cliHome 'AppData/Local')
}
$cliContext = Resolve-HomeAuthorityContextFromIdentity -Identity $cliIdentity
$cliAuthorityRoot = Join-Path (Join-Path ([string] $cliContext.ControlBase) 'homes') ([string] $cliContext.HomeAuthorityKey)

# 1. Dispatcher routing and mode failures.
$routed = Invoke-EntryCli -Arguments @('env', 'authority')
Assert ($routed.Code -eq 1 -and $routed.Out -match 'requires an action') 'env authority without an action fails with guidance'
$badAction = Invoke-EntryCli -Arguments @('env', 'authority', 'promote')
Assert ($badAction.Code -eq 1 -and $badAction.Out -match 'Unsupported env authority action') 'an unsupported authority action is rejected'
$noMode = Invoke-EntryCli -Arguments @('env', 'authority', 'adopt', '-Name', 'good')
Assert ($noMode.Code -eq 1 -and $noMode.Out -match 'explicit -DryRun or -Apply') 'a transition without a mode is rejected'
$bothModes = Invoke-EntryCli -Arguments @('env', 'authority', 'adopt', '-Name', 'good', '-DryRun', '-Apply', '-PlanPath', (Join-Path $cliSandbox 'both.json'))
Assert ($bothModes.Code -eq 1 -and $bothModes.Out -match 'only one mode') 'a transition with both modes is rejected'
$statusWithPlan = Invoke-EntryCli -Arguments @('env', 'authority', 'status', '-PlanPath', (Join-Path $cliSandbox 'x.json'))
Assert ($statusWithPlan.Code -eq 1 -and $statusWithPlan.Out -match 'neither -Name nor -PlanPath') 'status rejects transition switches'
$statusRun = Invoke-EntryCli -Arguments @('env', 'authority', 'status')
Assert ($statusRun.Code -eq 0 -and $statusRun.Out -match 'Authority route:') 'env authority status prints exactly one route'

# 2. Argument and route failures on the transitions.
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

# 3. Plan-path safety: the produced plan must live outside the worktree and Git internals.
$insideRepo = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliRepo 'plan.json'), '-RepoRoot', $cliRepo)
Assert ($insideRepo.Code -eq 1 -and $insideRepo.Out -match 'disjoint from worktree') 'a plan path inside the worktree is rejected'
$insideGit = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliRepo '.git/plan.json'), '-RepoRoot', $cliRepo)
Assert ($insideGit.Code -eq 1 -and $insideGit.Out -match 'disjoint from worktree') 'a plan path inside Git internals is rejected'

# 4. The adopt transition produces a validated plan, and Apply is idempotent-free.
$adoptPlan = Join-Path $cliSandbox 'adopt-plan.json'
$adopt = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
if ($adopt.Code -ne 0) { Write-Host "  note  adopt dryrun: $($adopt.Out)" }
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
# Without the canonical repo setup the apply must fail closed with the
# canonical token before any bootstrap or host work.
$applyBeforeSetup = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
Assert ($applyBeforeSetup.Code -eq 1 -and $applyBeforeSetup.Out -match 'canonical-setup-required') 'adopt Apply requires the canonical repo setup first'
# Seed the private prefix and the canonical setup (state + root claim) the way
# the reviewed flows would; the public canonical Apply stays interlocked.
. (Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1')
. (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
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
$cliBootstrapIntent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $cliContext -FilesystemCapabilityHash ('a' * 64)
$cliBootstrapLock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $cliContext -Intent $cliBootstrapIntent
Exit-HomeAuthorityGlobalLiveLock -LockHandle $cliBootstrapLock
Assert (Test-Path -LiteralPath ([string] $cliContext.GlobalLiveLockPath) -PathType Leaf) 'the sandbox private prefix is bootstrapped'
$canonicalProbe = Join-Path $cliWork 'canonical-probe'
$canonicalRecoveryParent = Join-Path $cliWork 'canonical-recovery-parent'
foreach ($dir in @($canonicalProbe, $canonicalRecoveryParent)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Set-AuthorityTestDirectoryCurrentUserOnly -Path $canonicalRecoveryParent
$canonicalRecovery = Join-Path $canonicalRecoveryParent 'recovery'
New-Item -ItemType Directory -Force -Path $canonicalRecovery | Out-Null
Set-AuthorityTestDirectoryCurrentUserOnly -Path $canonicalRecovery
$canonicalPayload = New-CanonicalSetupPlanPayload -RepoRoot $cliRepo -CanonicalRecoveryRoot $canonicalRecovery -ControlBase ([string] $cliContext.ControlBase) -BackupRoot ([string] $cliContext.BackupRoot) -ProbeRoot $canonicalProbe -ToolchainRoot $RepoRoot
$canonicalPaths = Get-CanonicalTransactionContractPaths -GitContext (Get-CanonicalGitContext -RepoRoot $cliRepo)
$canonicalState = New-CanonicalFinalSetupState -PlanPayload $canonicalPayload -RepoRoot $cliRepo
$canonicalRepoId = Get-CanonicalRepoIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $cliRepo)
$canonicalLock = Enter-CanonicalRepoLock -LockPath ([string] $canonicalPaths.LockPath) -AllowCreate
try {
    Write-AuthorityTestSemanticDocument -Path ([string] $canonicalPaths.SetupStatePath) -Document $canonicalState
    Write-AuthorityTestSemanticDocument -Path (Join-Path ([string] $cliContext.ControlBase) (Join-Path 'canonical-roots' ($canonicalRepoId + '.json'))) -Document ([System.Collections.IDictionary] $canonicalPayload.ExpectedRootClaim)
}
finally { Exit-CanonicalRepoLock -LockHandle $canonicalLock }
Assert ([string] (Get-CanonicalSetupStatus -RepoRoot $cliRepo -ToolchainRoot $RepoRoot) -ceq 'canonical-ready') 'the seeded sandbox canonical setup is accepted'

# The apply reaches the reviewed composition (interlock, plan gates, canonical
# and prefix preconditions) and then stops inside the host's canonical global
# acquisition, which requires the canonical witness binding that only the
# (interlocked) public canonical setup Apply can create. No sandbox fixture can
# legitimately produce it, so the boundary is asserted rather than skipped; the
# two legitimate resolutions are recorded in the active task record.
$applyAdopt = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
if ($applyAdopt.Code -ne 0) { Write-Host "  note  adopt apply:"; Write-Host $applyAdopt.Out }
Assert ($applyAdopt.Code -eq 1 -and $applyAdopt.Out -match 'canonical-witness-required') 'adopt Apply passes the interlock, the static plan gates, the canonical and prefix preconditions, and stops at the canonical witness binding'
Assert (-not (Test-Path -LiteralPath (Join-Path $cliAuthorityRoot 'current-env.json'))) 'a refused apply publishes no authority state'
Assert (-not (Test-Path -LiteralPath (Join-Path $cliAuthorityRoot 'root-claims.json'))) 'a refused apply publishes no root claims'
$applyMismatch = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-Apply', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
Assert ($applyMismatch.Code -eq 1) 'Apply refuses a plan whose operation kind differs from the action'
$applyMissing = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', (Join-Path $cliSandbox 'never.json'), '-RepoRoot', $cliRepo)
Assert ($applyMissing.Code -eq 1 -and $applyMissing.Out -match 'missing') 'Apply refuses a plan path that does not exist'
$interlockedDirect = Invoke-AuthorityCli -Direct -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-Apply', '-PlanPath', $adoptPlan, '-RepoRoot', $cliRepo)
Assert ($interlockedDirect.Code -eq 1 -and $interlockedDirect.Out -match 'safety-protocol-upgrade-required') 'production Apply stays interlocked outside the approved sandbox'

# 5. Untrusted legacy evidence adopts as UNTRUSTED.
Set-File -Path (Join-Path $cliRepo 'state/current-env.json') -Content '{"SchemaVersion":2}'
$untrustedPlan = Join-Path $cliSandbox 'adopt-untrusted-plan.json'
$untrusted = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'adopt', '-Name', 'good', '-DryRun', '-PlanPath', $untrustedPlan, '-RepoRoot', $cliRepo)
Assert ($untrusted.Code -eq 0) 'adopt succeeds with untrustworthy legacy evidence'
$untrustedDocument = Test-AuthorityPlanDocument -Path $untrustedPlan -ExpectedKind 'adopt'
Assert ([string] $untrustedDocument.PlanPayload.LegacyEvidence.Status -ceq 'UNTRUSTED') 'untrustworthy legacy evidence binds UNTRUSTED'
Remove-Item -LiteralPath (Join-Path $cliRepo 'state/current-env.json') -Force

# 6. Migrate binds the exact legacy core, hash, and old lock.
$migrateHome = Join-Path $cliSandbox 'home'
$null = New-LegacyActivationFixture -RepoRoot $cliRepo -HomeRoot $migrateHome -Name 'good'
$migrateWithoutLegacy = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'p4.json'), '-RepoRoot', $cliRepo)
Assert ($migrateWithoutLegacy.Code -eq 1 -and $migrateWithoutLegacy.Out -match 'authority-legacy-locator-required') 'migrate requires the exact legacy locator once the route is migrate'
$migrateWrongLocator = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'p5.json'), '-LegacyStatePath', (Join-Path $cliSandbox 'elsewhere.json'), '-RepoRoot', $cliRepo)
Assert ($migrateWrongLocator.Code -eq 1 -and $migrateWrongLocator.Out -match 'authority-legacy-locator-mismatch') 'migrate rejects a legacy locator outside the exact repo path'
$migrateWrongName = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'migrate', '-Name', 'other', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'p7.json'), '-LegacyStatePath', (Join-Path $cliRepo 'state/current-env.json'), '-RepoRoot', $cliRepo)
Assert ($migrateWrongName.Code -eq 1 -and $migrateWrongName.Out -match 'authority-legacy-name-mismatch') 'migrate requires the name the legacy state recorded'
$migratePlan = Join-Path $cliSandbox 'migrate-plan.json'
$migrate = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'migrate', '-Name', 'good', '-DryRun', '-PlanPath', $migratePlan, '-LegacyStatePath', (Join-Path $cliRepo 'state/current-env.json'), '-RepoRoot', $cliRepo)
if ($migrate.Code -ne 0) { Write-Host "  note  migrate dryrun: $($migrate.Out)" }
Assert ($migrate.Code -eq 0) 'migrate DryRun succeeds for complete legacy evidence'
$migrateDocument = Test-AuthorityPlanDocument -Path $migratePlan -ExpectedKind 'migrate'
$legacyStatePath = Join-Path $cliRepo 'state/current-env.json'
Assert ([string] $migrateDocument.PlanPayload.LegacyLocator -ceq [System.IO.Path]::GetFullPath($legacyStatePath)) 'migrate binds the exact legacy locator'
Assert ([string] $migrateDocument.PlanPayload.LegacyHash -ceq [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($legacyStatePath))).ToLowerInvariant()) 'migrate binds the legacy bytes hash'
Assert ([string] $migrateDocument.PlanPayload.OldLockHash -ceq (Get-HarnessFileHash -Path (Join-Path $cliRepo 'envs/good/env.lock.json')).ToLowerInvariant()) 'migrate binds the preserved old lock hash'
Assert ([string] $migrateDocument.PlanPayload.LegacyCoreHash -cmatch '\A[0-9a-f]{64}\z') 'migrate binds a core hash'
Assert (-not $migrateDocument.PlanPayload.Contains('LegacyEvidence')) 'migrate never carries adopt evidence'
# 7. Repair-adopt binds the corrupt-state evidence and the existing claims.
$repairIdentityLocal = [pscustomobject][ordered]@{
    ResolverVersion = 'sealed-home-authority-test-adapter-v1'
    TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    ProfileRoot = $cliHome
    RoamingAppDataRoot = (Join-Path $cliHome 'AppData/Roaming')
    LocalAppDataRoot = (Join-Path $cliHome 'AppData/Local')
}
$repairContextLocal = Resolve-HomeAuthorityContextFromIdentity -Identity $repairIdentityLocal
$controllerFingerprintLocal = Get-CanonicalRepoIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $cliRepo)
$pairLocal = New-FakeAuthorityPair -Context $repairContextLocal -ControllerFingerprint $controllerFingerprintLocal
$pairAuthorityRoot = Join-Path (Join-Path ([string] $repairContextLocal.ControlBase) 'homes') $pairLocal.Key
$claimsDocumentLocal = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $pairAuthorityRoot 'root-claims.json'))))
$stateDocumentLocal = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $pairAuthorityRoot 'current-env.json'))))
Set-File -Path (Join-Path $pairAuthorityRoot 'current-env.json') -Content '{ corrupt'
$repairPlan = Join-Path $cliSandbox 'repair-plan.json'
$corruptStatePath = Join-Path $pairAuthorityRoot 'current-env.json'
$repair = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'full', '-DryRun', '-PlanPath', $repairPlan, '-CorruptStatePath', $corruptStatePath, '-RepoRoot', $cliRepo)
if ($repair.Code -ne 0) { Write-Host "  note  repair dryrun: $($repair.Out)" }
Assert ($repair.Code -eq 0) 'repair-adopt DryRun succeeds for a corrupt state with valid claims'
$repairDocument = Test-AuthorityPlanDocument -Path $repairPlan -ExpectedKind 'repair-adopt'
Assert ([string] $repairDocument.PlanPayload.StateEvidence.Kind -ceq 'CORRUPT') 'repair-adopt binds the CORRUPT state evidence'
Assert ([string] $repairDocument.PlanPayload.StateEvidence.Path -ceq $corruptStatePath) 'repair-adopt binds the exact state path'
Assert (-not $repairDocument.PlanPayload.Contains('LegacyEvidence')) 'repair-adopt never carries adopt evidence'
$repairWithoutEvidence = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'repair-adopt', '-Name', 'full', '-DryRun', '-PlanPath', (Join-Path $cliSandbox 'repair-missing-evidence.json'), '-RepoRoot', $cliRepo)
Assert ($repairWithoutEvidence.Code -eq 1 -and $repairWithoutEvidence.Out -match 'authority-state-evidence-required') 'repair-adopt requires the corrupt state path for the CORRUPT branch'
# 8. Takeover binds the previous controller and carries no live actions.
Set-File -Path (Join-Path $pairAuthorityRoot 'current-env.json') -Content ([System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $stateDocumentLocal)))
$null = New-FakeAuthorityPair -Context $repairContextLocal -ControllerFingerprint $controllerFingerprintLocal
$foreignPlan = Join-Path $cliSandbox 'takeover-plan.json'
$takeoverMismatch = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'full', '-DryRun', '-PlanPath', $foreignPlan, '-RepoRoot', $cliRepo)
Assert ($takeoverMismatch.Code -eq 1 -and $takeoverMismatch.Out -match 'authority-route-mismatch') 'takeover is refused for the current controller'
Remove-Item -LiteralPath (Join-Path $pairAuthorityRoot 'current-env.json') -Force
$null = New-FakeAuthorityPair -Context $repairContextLocal -ControllerFingerprint ('0' * 64)
# The state-bound lock must describe the current live managed trees, exactly
# like a real activation lock would.
$stagedLive = [ordered] @{}
foreach ($claimRow in @($claimsDocumentLocal.LiveRootClaims)) {
    $platform = [string] $claimRow.Platform
    $platformHashes = [ordered] @{}
    foreach ($skill in @('fixture-a', 'fixture-b')) {
        $skillPath = Join-Path ([string] $claimRow.RequestedPath) $skill
        if (Test-Path -LiteralPath $skillPath -PathType Container) { $platformHashes[$skill] = Get-HarnessTreeHash -Path $skillPath }
    }
    $stagedLive[$platform] = $platformHashes
}
Set-File -Path (Join-Path $cliRepo 'envs/full/env.lock.json') -Content ([System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject ([ordered] @{
                SchemaVersion = 3
                Name = 'full'
                DefinitionHash = 'a' * 64
                TaskOverlayHash = $null
                TaskOverlaySkills = [ordered] @{ Claude = @(); Codex = @(); Reasonix = @() }
                RepositoryCommit = 'b' * 40
                ManifestHashes = [ordered] @{ Claude = 'c' * 64; Codex = 'd' * 64; Reasonix = 'e' * 64 }
                SkillSourceEvidence = 'available'
                SkillSourceHashes = [ordered] @{ Claude = [ordered] @{}; Codex = [ordered] @{}; Reasonix = [ordered] @{} }
                StagedSkillTreeHashes = $stagedLive
                ProfileSourceHash = $null
                ProfileOutputHash = $null
                BuiltFiles = [ordered] @{}
            }))))
$stateForTakeover = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $pairAuthorityRoot 'current-env.json'))))
$stateForTakeover['EnvironmentLockHash'] = (Get-HarnessFileHash -Path (Join-Path $cliRepo 'envs/full/env.lock.json')).ToLowerInvariant()
[System.IO.File]::WriteAllBytes((Join-Path $pairAuthorityRoot 'current-env.json'), (ConvertTo-SemanticJsonBytes -InputObject $stateForTakeover))
$takeover = Invoke-AuthorityCli -SandboxRoot $cliSandbox -Arguments @('-Action', 'takeover', '-Name', 'full', '-DryRun', '-PlanPath', $foreignPlan, '-RepoRoot', $cliRepo)
if ($takeover.Code -ne 0) { Write-Host "  note  takeover dryrun:"; Write-Host $takeover.Out }
Assert ($takeover.Code -eq 0) 'takeover DryRun succeeds for a foreign controller with verified parity'
$takeoverDocument = Test-AuthorityPlanDocument -Path $foreignPlan -ExpectedKind 'controller-transition'
Assert ([string] $takeoverDocument.PlanPayload.ControllerParity.PreviousControllerRepoFingerprint -ceq ('0' * 64)) 'takeover binds the previous controller fingerprint'
Assert (@($takeoverDocument.PlanPayload.OrderedActions).Count -eq 0) 'takeover carries no live actions'
Assert ([string] $takeoverDocument.PlanPayload.AuthorityStateIntent.ReceiptRef -ceq 'NO_LIVE_MUTATION') 'takeover declares the no-live-mutation receipt reference'
Assert (-not $takeoverDocument.PlanPayload.Contains('EnvironmentMaterializationRoot')) 'takeover binds no materialization root'
Remove-Item -LiteralPath (Join-Path $cliRepo 'envs/full/env.lock.json') -Force

# 9. Ordinary activate/sync never reach a transition.
$syncDryRun = Invoke-SafetySandboxScript -SandboxRoot $cliSandbox -ScriptPath (Join-Path $RepoRoot 'scripts/sync.ps1') -Arguments @('-DryRun', '-PlanPath', (Join-Path $cliSandbox 'sync-plan.json'), '-RepoRoot', $cliRepo) -AuthorityRepoRoot $RepoRoot
Assert ($syncDryRun.Code -ne 0) 'ordinary sync cannot plan over an existing authority context'
if (Test-Path -LiteralPath (Join-Path $cliSandbox 'sync-plan.json')) {
    $syncDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $cliSandbox 'sync-plan.json'))))
    Assert ([string] $syncDocument.PlanPayload.OperationKind -cin @('initial', 'retirement')) 'sync can only ever emit its own operation kinds'
}

Write-Host ("harness-authority tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) {
    Write-Host "Workspace kept for inspection: $work"
    exit 1
}
Remove-Work
exit 0
