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

# A shared ControlBase state is invisible to the legacy reader.
$sharedControlBase = Join-Path $work 'control'
$sharedKey = 'a' * 64
$sharedAuthorityRoot = Join-Path (Join-Path $sharedControlBase 'homes') $sharedKey
New-Item -ItemType Directory -Path $sharedAuthorityRoot -Force | Out-Null
Set-File -Path (Join-Path $sharedAuthorityRoot 'current-env.json') -Content '{"SchemaVersion":3}'
Assert ([string] (Read-LegacyHarnessEnvState -RepoRoot $legacyRepo).Status -ceq 'CORRUPT') 'legacy reader sees only the repo-local file'
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
$sharedSnapshotBefore = Get-TreeSnapshot -Root $sharedControlBase

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

$badKeyRejected = $false
try { $null = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey '../escape' -RepoRoot $RepoRoot }
catch { $badKeyRejected = $true }
Assert $badKeyRejected 'shared reader rejects a non-hash authority key'

# The reader is read-only for both artifacts and never touches the legacy locator.
[System.IO.File]::WriteAllBytes($sharedClaimsPath, $claimsBytes)
[System.IO.File]::WriteAllBytes($sharedStatePath, $stateBytes)
$sharedSnapshotBefore = Get-TreeSnapshot -Root $sharedControlBase
$null = Read-HomeAuthorityState -ControlBase $sharedControlBase -HomeAuthorityKey $validKey -RepoRoot $RepoRoot
$sharedSnapshotAfter = Get-TreeSnapshot -Root $sharedControlBase
Assert ($sharedSnapshotBefore -eq $sharedSnapshotAfter) 'shared reader leaves every ControlBase file byte-identical'
Assert ([string] (Read-LegacyHarnessEnvState -RepoRoot $validAuthorityRoot).Status -ceq 'MISSING') 'legacy reader sees no legacy state under a ControlBase tree'

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
$null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $lockValidation -InstanceBytes $lockBytes -InstancePath 'harness-authority.lock.in-memory.json'
Assert $true 'emitted lock validates against the frozen schema 3'

foreach ($forbidden in @('LockHash', 'MaterializationHash', 'PlanHash', 'DocumentHash', 'ReceiptId', 'ReceiptHash', 'JournalId', 'PreStatePhaseHash', 'AuthorityStateHash', 'TargetContextIntent')) {
    Assert ($lockKeys -notcontains $forbidden) "lock carries no $forbidden graph field"
}

foreach ($mapName in @('ManifestHashes', 'SkillSourceHashes', 'StagedSkillTreeHashes', 'TaskOverlaySkills')) {
    $platforms = @($lock[$mapName].Keys | Sort-Object { [string] $_ })
    Assert (($platforms -join ',') -ceq 'Claude,Codex,Reasonix') "lock $mapName covers all three platforms"
}
Assert ([string] $lock['SkillSourceEvidence'] -ceq 'available') 'lock records available skill-source evidence'
Assert ([string] $lock['Name'] -ceq 'good') 'lock records the environment name'
Assert (@($lock['TaskOverlaySkills']['Reasonix']).Count -eq 0) 'lock records the empty Reasonix task baseline explicitly'
Assert (@($lock['BuiltFiles'].Keys).Count -gt 0) 'lock enumerates the built staging files'

$sidecar = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($sidecarPath)))
$sidecarLockHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($lockBytes)).ToLowerInvariant()
Assert ([string] $sidecar['LockHash'] -ieq $sidecarLockHash) 'build sidecar binds the exact emitted lock bytes'
Assert ([string] $sidecar['MaterializationHash'] -ceq (Get-HarnessEnvMaterializationHash -Document $sidecar)) 'build sidecar self-hash excludes GeneratedAtUtc and itself'
Test-HarnessEnvBuildSemantics -Document $sidecar
Assert $true 'emitted build sidecar passes the v3 semantic gate'
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
$null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $lockValidation -InstanceBytes $emptyLockBytes -InstancePath 'harness-authority.empty-lock.in-memory.json'
Assert $true 'lock for an empty platform subset validates against schema 3'
Assert (@($emptyLock['StagedSkillTreeHashes']['Reasonix'].Keys).Count -eq 0) 'lock records the empty Reasonix staged map'

# ==============================================================================
Write-Host 'state graph: state references only pre-state artifacts'
Test-CurrentEnvStateAgainstRootClaims -StateDocument $stateDocument -RootClaimsDocument $claimsDocument -RootClaimsBytes $claimsBytes
Assert $true 'registered valid claims/state fixtures pass the exact-byte pair contract'

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

Write-Host ("harness-authority tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) {
    Write-Host "Workspace kept for inspection: $work"
    exit 1
}
Remove-Work
exit 0
