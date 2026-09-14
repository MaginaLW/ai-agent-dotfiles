#requires -Version 7.0
<#
.SYNOPSIS
    Self-contained regression tests for harness environment scripts.

.DESCRIPTION
    No Pester dependency. Runs the real harness env scripts (list/status/build)
    against an isolated fake repository under <repo>/tmp/harness-env-tests
    (gitignored). The fake repo copies the real harness-source profiles and
    components but uses fixture manifests, fixture generated skills, and test
    env definitions, so no real home path, no real envs/ staging, and no real
    state/ file is ever touched. The workspace is removed on success and kept
    on failure.
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
. (Join-Path $PSScriptRoot 'helpers/safety-sandbox.ps1')
. (Join-Path $PSScriptRoot 'helpers/failpoint-controller.ps1')
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/harness-authority-status-common.ps1')
# The activation matrix drives the reviewed plan/host composition, so the test
# runspace carries the same plan, canonical, and registry surface the activation
# script itself loads. The sealed registry home accepts exactly one load per
# runspace, which is why it is loaded once here, in script scope.
. (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')
. (Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1')
$listScript = Join-Path $RepoRoot 'scripts/list-harness-env.ps1'
$statusScript = Join-Path $RepoRoot 'scripts/status-harness-env.ps1'
$buildScript = Join-Path $RepoRoot 'scripts/build-harness-env.ps1'
$activateScript = Join-Path $RepoRoot 'scripts/activate-harness-env.ps1'
$entryScript = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'

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

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-harness-env-$([Guid]::NewGuid().ToString('N'))"
function Remove-Work {
    if (($work -like '*ai-agent-dotfiles-harness-env-*') -and (Test-Path -LiteralPath $work)) {
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

function Invoke-Script {
    param([Parameter(Mandatory)] [string] $Script, [string[]] $ScriptArgs = @())
    if ($ScriptArgs -contains '-Apply') {
        $result = Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $Script -Arguments $ScriptArgs -AuthorityRepoRoot $RepoRoot
        return @{ Out = $result.Out; Code = $result.Code }
    }
    $out = & pwsh -NoProfile -File $Script @ScriptArgs 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function New-EnvDefinitionText {
    param(
        [string] $SchemaVersion = '1',
        [Parameter(Mandatory)] [string] $Name,
        [string] $EnvProfile = 'coding',
        [string[]] $ClaudeSkills = @(),
        [string[]] $CodexSkills = @(),
        [string[]] $ReasonixSkills = @(),
        [string] $ExtraLine = ''
    )
    function Join-Psd1Array([string[]] $Values) {
        if ($Values.Count -eq 0) { return '@()' }
        return '@(' + (($Values | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ')'
    }
    return @"
@{
    SchemaVersion = $SchemaVersion
    Name = '$Name'
    Description = 'test env'
    Profile = '$EnvProfile'
    Skills = @{
        Claude = $(Join-Psd1Array $ClaudeSkills)
        Codex = $(Join-Psd1Array $CodexSkills)
        Reasonix = $(Join-Psd1Array $ReasonixSkills)
    }
$ExtraLine
}
"@
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)] [string] $Root)
    $lines = foreach ($file in (Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName)) {
        '{0}|{1}' -f $file.FullName, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return ($lines -join "`n")
}

# --- Fake repository ----------------------------------------------------------
$fakeRepo = Join-Path $work 'repo'
New-Item -ItemType Directory -Path $fakeRepo -Force | Out-Null
& git -C $fakeRepo init --quiet
if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize the external harness fixture repository.' }

Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/profiles') `
    -Destination (Join-Path $fakeRepo 'harness-source/profiles') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components') `
    -Destination (Join-Path $fakeRepo 'harness-source/components') -Recurse -Force

# fixture-c is managed but has no generated output (build precondition case).
Set-File -Path (Join-Path $fakeRepo 'manifests/managed-skills.claude.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
Set-File -Path (Join-Path $fakeRepo 'manifests/managed-skills.codex.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
Set-File -Path (Join-Path $fakeRepo 'manifests/managed-skills.reasonix.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
foreach ($platform in @('claude', 'codex', 'reasonix')) {
    foreach ($skill in @('fixture-a', 'fixture-b')) {
        Set-File -Path (Join-Path $fakeRepo "$platform/skills/$skill/SKILL.md") -Content "# $skill ($platform fixture)"
    }
}
# A small source-of-truth fixture lets the lock test source provenance without
# copying the real repository's full skill library into the fake repo.
foreach ($skill in @('fixture-a', 'fixture-b')) {
    Set-File -Path (Join-Path $fakeRepo "skills-source/shared/$skill/SKILL.md") -Content "# $skill (source fixture)"
}

$envRoot = Join-Path $fakeRepo 'harness-source/envs'
$goodDefinitionPath = Join-Path $envRoot 'good.psd1'
Set-File -Path $goodDefinitionPath -Content (New-EnvDefinitionText -Name 'good' -ClaudeSkills @('fixture-b', 'fixture-a') -CodexSkills @('fixture-a') -ReasonixSkills @('fixture-a'))

$goodStaging = Join-Path $fakeRepo 'envs/good'
$statePath = Join-Path $fakeRepo 'state/current-env.json'

# --- 1. list happy path -------------------------------------------------------
Write-Host 'list: happy path'
$snapshotBefore = Get-TreeSnapshot -Root $fakeRepo
$result = Invoke-Script -Script $listScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0) 'list exits 0 when all definitions are valid'
Assert ($result.Out -match 'good') 'list shows the good env'
Assert ($result.Out -match '\bok\b') 'list reports ok for a valid definition'
Assert ($result.Out -match 'No environment activated\.') 'list reports no active environment'

# --- 2. definition validation failures ----------------------------------------
Write-Host 'list: invalid definitions'
$badCases = @(
    @{ Label = 'unknown top-level key'; File = 'badkey.psd1'; Text = (New-EnvDefinitionText -Name 'badkey' -ClaudeSkills @('fixture-a') -ExtraLine '    Bogus = 1') }
    @{ Label = 'name/filename mismatch'; File = 'wrongname.psd1'; Text = (New-EnvDefinitionText -Name 'other' -ClaudeSkills @('fixture-a')) }
    @{ Label = 'unknown profile'; File = 'badprofile.psd1'; Text = (New-EnvDefinitionText -Name 'badprofile' -EnvProfile 'no-such-profile' -ClaudeSkills @('fixture-a')) }
    @{ Label = 'unmanaged skill'; File = 'badskill.psd1'; Text = (New-EnvDefinitionText -Name 'badskill' -ClaudeSkills @('not-managed')) }
    @{ Label = 'retired MCP template field'; File = 'badmcp.psd1'; Text = (New-EnvDefinitionText -Name 'badmcp' -ClaudeSkills @('fixture-a') -ExtraLine '    McpTemplates = @()') }
    @{ Label = 'unsupported SchemaVersion'; File = 'badschema.psd1'; Text = (New-EnvDefinitionText -Name 'badschema' -SchemaVersion '2' -ClaudeSkills @('fixture-a')) }
)
foreach ($case in $badCases) {
    $badPath = Join-Path $envRoot $case.File
    Set-File -Path $badPath -Content $case.Text
    $result = Invoke-Script -Script $listScript -ScriptArgs @('-RepoRoot', $fakeRepo)
    Assert ($result.Code -eq 1) "list exits 1: $($case.Label)"
    Assert ($result.Out -match 'invalid:') "list marks invalid: $($case.Label)"
    Assert ($result.Out -match '\bok\b') "list still shows valid envs: $($case.Label)"
    Remove-Item -LiteralPath $badPath -Force
}

# --- 3. build precondition ----------------------------------------------------
Write-Host 'build: missing generated output'
$precondPath = Join-Path $envRoot 'precond.psd1'
Set-File -Path $precondPath -Content (New-EnvDefinitionText -Name 'precond' -ClaudeSkills @('fixture-c'))
$result = Invoke-Script -Script $buildScript -ScriptArgs @('-Name', 'precond', '-RepoRoot', $fakeRepo)
Assert ($result.Code -ne 0) 'build fails when generated skill output is missing'
Assert ($result.Out -match 'build-skills\.ps1') 'build failure points at build-skills.ps1'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'envs/precond'))) 'failed build writes no staging'
Remove-Item -LiteralPath $precondPath -Force

Write-Host 'build: unknown env'
$result = Invoke-Script -Script $buildScript -ScriptArgs @('-Name', 'ghost', '-RepoRoot', $fakeRepo)
Assert ($result.Code -ne 0) 'build fails for an unknown env'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'envs/ghost'))) 'unknown env build writes no staging'

# Exercise all three task-overlay arrays in the lock contract. The overlay
# targets only the good environment and is ignored by later small-env builds.
Set-File -Path (Join-Path $fakeRepo '.agent-harness/task-skills.psd1') -Content @"
@{
    SchemaVersion = 1
    BaseEnv = 'good'
    Skills = @{
        Claude = @()
        Codex = @()
        Reasonix = @('fixture-b')
    }
}
"@

# --- 4. build success ---------------------------------------------------------
Write-Host 'build: success'
$result = Invoke-Script -Script $buildScript -ScriptArgs @('-Name', 'good', '-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0) 'build succeeds for the good env'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'claude/skills/fixture-a/SKILL.md')) 'staging contains claude fixture-a'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'claude/skills/fixture-b/SKILL.md')) 'staging contains claude fixture-b'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'codex/skills/fixture-a/SKILL.md')) 'staging contains codex fixture-a'
Assert (-not (Test-Path -LiteralPath (Join-Path $goodStaging 'codex/skills/fixture-b'))) 'staging omits unselected codex skill'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'reasonix/skills/fixture-a/SKILL.md')) 'staging contains reasonix fixture-a'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'reasonix/skills/fixture-b/SKILL.md')) 'staging contains the Reasonix task-overlay skill'
$claudeManifest = (Get-Content -LiteralPath (Join-Path $goodStaging 'manifest.claude.txt') | Where-Object { $_ -ne '' })
Assert (($claudeManifest -join ',') -eq 'fixture-a,fixture-b') 'claude manifest is sorted (definition listed b before a)'
$codexManifest = (Get-Content -LiteralPath (Join-Path $goodStaging 'manifest.codex.txt') | Where-Object { $_ -ne '' })
Assert (($codexManifest -join ',') -eq 'fixture-a') 'codex manifest matches the env definition'
$reasonixManifest = (Get-Content -LiteralPath (Join-Path $goodStaging 'manifest.reasonix.txt') | Where-Object { $_ -ne '' })
Assert (($reasonixManifest -join ',') -eq 'fixture-a,fixture-b') 'reasonix manifest includes the task overlay and remains sorted'
$agentsGenerated = Join-Path $goodStaging 'profile/AGENTS.generated.md'
Assert (Test-Path -LiteralPath $agentsGenerated) 'profile/AGENTS.generated.md rendered'
Assert ((Get-Content -Raw -LiteralPath $agentsGenerated) -match '<!-- BEGIN AGENT-HARNESS: ') 'managed block markers present'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'profile/claude-settings.generated.json')) 'profile settings fragment rendered'
$lockPath = Join-Path $goodStaging 'env.lock.json'
Assert (Test-Path -LiteralPath $lockPath) 'env.lock.json written'
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
Assert ([string] $lock.Name -eq 'good') 'lock records the env name'
Assert ([int] $lock.SchemaVersion -eq 3) 'lock uses schema version 3'
Assert ($lock.PSObject.Properties.Name -contains 'TaskOverlayHash') 'lock records the task overlay hash contract'
Assert ($lock.PSObject.Properties.Name -contains 'TaskOverlaySkills' -and
    $lock.TaskOverlaySkills.PSObject.Properties.Name -contains 'Claude' -and
    $lock.TaskOverlaySkills.PSObject.Properties.Name -contains 'Codex' -and
    $lock.TaskOverlaySkills.PSObject.Properties.Name -contains 'Reasonix') 'lock records task overlay arrays for every platform'
Assert (@($lock.TaskOverlaySkills.Reasonix) -contains 'fixture-b') 'lock records the actual Reasonix task overlay'
$lockedFiles = @($lock.BuiltFiles.PSObject.Properties.Name)
Assert ($lockedFiles.Count -gt 0 -and ($lockedFiles -notcontains 'env.lock.json') -and ($lockedFiles -notcontains 'env-build.json')) 'lock covers built files but not itself or the sidecar'
Assert ($lock.PSObject.Properties.Name -notcontains 'MaterializationHash') 'lock instance has no MaterializationHash field'
$sidecarPath = Join-Path $goodStaging 'env-build.json'
Assert (Test-Path -LiteralPath $sidecarPath -PathType Leaf) 'env-build.json sidecar written'
$sidecar = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($sidecarPath, [System.Text.UTF8Encoding]::new($false, $true)))
Assert ([long] $sidecar.SchemaVersion -eq 3) 'sidecar uses schema version 3'
Assert ([string] $sidecar.MaterializationHash -ceq (Get-HarnessEnvMaterializationHash -Document $sidecar)) 'sidecar MaterializationHash matches RFC 8785 excluding GeneratedAtUtc and itself'
$sidecar.GeneratedAtUtc = '2099-01-01T00:00:00.0000000Z'
Assert ([string] $sidecar.MaterializationHash -ceq (Get-HarnessEnvMaterializationHash -Document $sidecar)) 'MaterializationHash is unchanged after GeneratedAtUtc mutation'
Test-HarnessEnvBuildSemantics -Document $sidecar
Assert $true 'sidecar passes Test-HarnessEnvBuildSemantics after GeneratedAtUtc mutation'
$v2Evidence = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($sidecarPath, [System.Text.UTF8Encoding]::new($false, $true)))
$v2Evidence.SchemaVersion = 2
$v2Rejected = $false
try { Test-HarnessEnvBuildSemantics -Document $v2Evidence }
catch { $v2Rejected = $_.Exception.Message -match 'env-build-schema-unsupported' }
Assert $v2Rejected 'v2 env-build evidence is rejected'
$stagedFiles = @(Get-ChildItem -LiteralPath $goodStaging -File -Recurse -Force |
        Where-Object { $_.Name -ne 'env.lock.json' -and $_.Name -ne 'env-build.json' })
Assert ($lockedFiles.Count -eq $stagedFiles.Count) 'lock covers every staged file except lock and sidecar'
$runtimeReport = Join-Path $goodStaging 'reports/sync-report-fixture.md'
Set-File -Path $runtimeReport -Content '# runtime report'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'good\s+definition=valid\s+staging=built') 'status ignores runtime reports written under staging'

Write-Host 'build: empty platform root exists'
$emptyRxPath = Join-Path $envRoot 'emptyrx.psd1'
Set-File -Path $emptyRxPath -Content (New-EnvDefinitionText -Name 'emptyrx' -ClaudeSkills @('fixture-a') -CodexSkills @('fixture-a'))
$result = Invoke-Script -Script $buildScript -ScriptArgs @('-Name', 'emptyrx', '-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0) 'build succeeds with an empty Reasonix subset'
$emptyRxStaging = Join-Path $fakeRepo 'envs/emptyrx'
Assert (Test-Path -LiteralPath (Join-Path $emptyRxStaging 'reasonix/skills') -PathType Container) 'empty Reasonix skills root is created'
$emptyRxSidecar = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path $emptyRxStaging 'env-build.json'), [System.Text.UTF8Encoding]::new($false, $true)))
Assert ([bool] $emptyRxSidecar.MaterializedRoots.Reasonix.Exists -eq $true) 'empty Reasonix MaterializedRoots.Exists is true'
Assert ([string] $emptyRxSidecar.MaterializedRoots.Reasonix.RelativePath -ceq 'reasonix/skills') 'empty Reasonix RelativePath is reasonix/skills'
Assert ([long] $emptyRxSidecar.MaterializedRoots.Reasonix.FileCount -eq 0) 'empty Reasonix FileCount is 0'
Remove-Item -LiteralPath $emptyRxPath -Force
Remove-Item -LiteralPath $emptyRxStaging -Recurse -Force

Write-Host 'materialization: refuse non-empty destination'
$blockedDest = Join-Path $work 'blocked-dest'
New-Item -ItemType Directory -Path $blockedDest -Force | Out-Null
Set-File -Path (Join-Path $blockedDest 'keep.txt') -Content 'keep'
$blockedThrew = $false
try { Invoke-HarnessEnvMaterialization -Name 'good' -Destination $blockedDest -RepoRoot $fakeRepo }
catch { $blockedThrew = $_.Exception.Message -match 'not empty' }
Assert $blockedThrew 'Invoke-HarnessEnvMaterialization refuses a non-empty Destination'
Assert (Test-Path -LiteralPath (Join-Path $blockedDest 'keep.txt') -PathType Leaf) 'refused materialization does not Recurse-delete Destination'

# --- 5. build idempotence -----------------------------------------------------
Write-Host 'build: idempotence'
$firstLockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
$result = Invoke-Script -Script $buildScript -ScriptArgs @('-Name', 'good', '-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0) 'rebuild succeeds'
$secondLockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
Assert ($firstLockHash -eq $secondLockHash) 'rebuild produces an identical env.lock.json'

# --- 6. status transitions ----------------------------------------------------
Write-Host 'status: built / stale / missing'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0) 'status exits 0'
Assert ($result.Out -match 'good\s+definition=valid\s+staging=built') 'status reports built after build'

$originalDefinition = [System.IO.File]::ReadAllBytes($goodDefinitionPath)
Add-Content -LiteralPath $goodDefinitionPath -Value '# temporary comment'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'staging=stale') 'status reports stale after the definition changes'
[System.IO.File]::WriteAllBytes($goodDefinitionPath, $originalDefinition)
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'staging=built') 'status reports built again after restore'

Set-File -Path $lockPath -Content '{ not valid json'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'staging=stale') 'status reports stale for a corrupt lock'
$result = Invoke-Script -Script $buildScript -ScriptArgs @('-Name', 'good', '-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0) 'rebuild recovers from a corrupt lock'
$sourceFixture = Join-Path $fakeRepo 'skills-source/shared/fixture-a/SKILL.md'
$originalSourceFixture = [System.IO.File]::ReadAllBytes($sourceFixture)
Add-Content -LiteralPath $sourceFixture -Value '# source drift'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'staging=stale') 'status reports stale after a skill source changes'
[System.IO.File]::WriteAllBytes($sourceFixture, $originalSourceFixture)
$result = Invoke-Script -Script $buildScript -ScriptArgs @('-Name', 'good', '-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0) 'rebuild recovers from skill source drift'

Remove-Item -LiteralPath $goodStaging -Recurse -Force
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'staging=missing') 'status reports missing after staging is deleted'

# --- 7. activation reporting (state file is test-authored; scripts only read it)
Write-Host 'status/list: activation reporting'
Set-File -Path $statePath -Content '{"Name":"good"}'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'Active environment: good') 'status reports the active env'
Assert ($result.Out -notmatch 'definition missing') 'no definition-missing suffix for a known env'
$result = Invoke-Script -Script $listScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match '\*\s*good') 'list marks the active env with *'

Set-File -Path $statePath -Content '{"Name":"phantom"}'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'Active environment: phantom \(definition missing\)') 'status flags a missing definition for the active env'

Set-File -Path $statePath -Content '{ corrupt'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0) 'status stays exit 0 with a corrupt state file'
Assert ($result.Out -match 'No environment activated\.') 'corrupt state is reported as not activated (with a warning)'

Remove-Item -LiteralPath $statePath -Force
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'No environment activated\.') 'status reports no activation after state removal'

# --- 7b. authority status documents (schema 2) ---------------------------------
Write-Host 'status/list: authority documents'
$statusJson = Join-Path $work 'status-authority.json'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo, '-JsonPath', $statusJson)
Assert ($result.Code -eq 0) 'status writes its authority document'
$statusDoc = Get-Content -Raw -LiteralPath $statusJson | ConvertFrom-Json
Assert ([int] $statusDoc.SchemaVersion -eq 2) 'status document uses schema 2'
Assert (-not [string]::IsNullOrWhiteSpace([string] $statusDoc.Authority.Route)) 'status document carries one authority route'
Assert (-not [string]::IsNullOrWhiteSpace([string] $statusDoc.Authority.NextOperation)) 'status document carries one recommended next operation'
Assert ($statusDoc.Environments[0].PSObject.Properties.Name -contains 'ReasonixSkillCount') 'status rows carry the Reasonix skill count'
Assert ($statusDoc.Active.PSObject.Properties.Name -notcontains 'BackupReference') 'status Active drops the clone-local backup reference'
if ([string] $statusDoc.Authority.RootClaimsStatus -eq 'MISSING') {
    Assert ([string] $statusDoc.Authority.IntendedRoot.FilesystemCapabilityStatus -eq 'UNPROBED') 'the default intended root branch is metadata-only'
    Assert (-not $statusDoc.Authority.IntendedRoot.PSObject.Properties.Name.Contains('RequestedReasonixRoot')) 'the default intended root branch carries no requested-root label'
}

$customReasonixRoot = Join-Path $work 'custom-reasonix-skills'
New-Item -ItemType Directory -Path $customReasonixRoot -Force | Out-Null
$customJson = Join-Path $work 'status-authority-custom.json'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo, '-JsonPath', $customJson, '-ReasonixLiveSkillsPath', $customReasonixRoot)
Assert ($result.Code -eq 0) 'status accepts a custom intended Reasonix root before any claims'
$customDoc = Get-Content -Raw -LiteralPath $customJson | ConvertFrom-Json
Assert ([string] $customDoc.Authority.IntendedRoot.Selection -eq 'explicit-initial-claim') 'the custom root selects the explicit intended-root branch'
Assert ([string] $customDoc.Authority.IntendedRoot.RequestedReasonixRoot -ne $customReasonixRoot) 'the status document never carries the raw custom root path'
Assert (-not [string]::IsNullOrWhiteSpace([string] $customDoc.Authority.IntendedRoot.RequestedInitialRootContextHash)) 'the explicit intended root carries its metadata context hash'

$schemaRoot = Join-Path $RepoRoot 'schemas'
$statusSchema = Test-RepositoryJsonSchema -SchemaPath (Join-Path $schemaRoot 'harness-env-status.schema.json') -SchemaRoot $schemaRoot
$listSchema = Test-RepositoryJsonSchema -SchemaPath (Join-Path $schemaRoot 'harness-env-list.schema.json') -SchemaRoot $schemaRoot
$statusSchemaOk = $true
try { $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $statusSchema -InstanceBytes ([System.IO.File]::ReadAllBytes($statusJson)) -InstancePath 'harness-env-status.emitted.json' }
catch { $statusSchemaOk = $false; Write-Host "  note  emitted status failed schema validation: $($_.Exception.Message)" }
Assert $statusSchemaOk 'the emitted status document validates against schema 2'
$customSchemaOk = $true
try { $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $statusSchema -InstanceBytes ([System.IO.File]::ReadAllBytes($customJson)) -InstancePath 'harness-env-status.emitted-custom.json' }
catch { $customSchemaOk = $false; Write-Host "  note  emitted custom status failed schema validation: $($_.Exception.Message)" }
Assert $customSchemaOk 'the emitted explicit-intended-root status document validates against schema 2'

$listJson = Join-Path $work 'list-authority.json'
$result = Invoke-Script -Script $listScript -ScriptArgs @('-RepoRoot', $fakeRepo, '-JsonPath', $listJson)
Assert ($result.Code -eq 0) 'list writes its authority document'
$listDoc = Get-Content -Raw -LiteralPath $listJson | ConvertFrom-Json
Assert ([int] $listDoc.SchemaVersion -eq 2) 'list document uses schema 2'
Assert ($listDoc.Environments[0].PSObject.Properties.Name -contains 'ReasonixSkillCount') 'list rows carry the Reasonix skill count'
Assert ([string] $listDoc.Authority.Route -eq [string] $statusDoc.Authority.Route) 'list and status agree on the single authority route'
$listSchemaOk = $true
try { $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $listSchema -InstanceBytes ([System.IO.File]::ReadAllBytes($listJson)) -InstancePath 'harness-env-list.emitted.json' }
catch { $listSchemaOk = $false; Write-Host "  note  emitted list failed schema validation: $($_.Exception.Message)" }
Assert $listSchemaOk 'the emitted list document validates against schema 2'

# --- 8. read-only guarantee for list/status ------------------------------------
Write-Host 'list/status: read-only guarantee'
if (Test-Path -LiteralPath (Join-Path $fakeRepo 'envs')) {
    Remove-Item -LiteralPath (Join-Path $fakeRepo 'envs') -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $fakeRepo 'state')) {
    Remove-Item -LiteralPath (Join-Path $fakeRepo 'state') -Recurse -Force -ErrorAction SilentlyContinue
}
$snapshotBefore = Get-TreeSnapshot -Root $fakeRepo
$null = Invoke-Script -Script $listScript -ScriptArgs @('-RepoRoot', $fakeRepo)
$null = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
$snapshotAfter = Get-TreeSnapshot -Root $fakeRepo
Assert ($snapshotBefore -eq $snapshotAfter) 'list and status change no file in the repo tree'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'state'))) 'list and status never create state/'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'envs'))) 'list and status never create envs/'

# --- 9. activate: gated deploy against a fake home -----------------------------
Write-Host 'activate: fake home apply'
$fakeHome = Join-Path $work 'home'
$fakeBackups = Join-Path $work 'backups'
foreach ($dir in @('.claude/skills/unknown-local', '.codex/skills/.system', 'AppData/Roaming/reasonix/skills')) {
    New-Item -ItemType Directory -Path (Join-Path $fakeHome $dir) -Force | Out-Null
}
Set-File -Path (Join-Path $fakeHome '.claude/skills/unknown-local/SKILL.md') -Content '# unmanaged local skill'
Set-File -Path (Join-Path $fakeHome 'AppData/Roaming/reasonix/skills/rx-unknown/SKILL.md') -Content '# unmanaged reasonix skill'
Set-File -Path (Join-Path $fakeHome '.codex/skills/.system/system.md') -Content '# platform-managed sentinel'
Set-File -Path (Join-Path $fakeHome '.codex/skills/.system/.codex-system-skills.marker') -Content ''
$systemSentinel = Join-Path $fakeHome '.codex/skills/.system/system.md'
$unknownLocal = Join-Path $fakeHome '.claude/skills/unknown-local/SKILL.md'

$smallDefinitionPath = Join-Path $envRoot 'small.psd1'
Set-File -Path $smallDefinitionPath -Content (New-EnvDefinitionText -Name 'small' -ClaudeSkills @('fixture-a') -CodexSkills @('fixture-a'))

function Invoke-Activate {
    param([string] $EnvName, [string[]] $Extra = @())
    # -SkipBuild: the fake repo has no skills-source; generated fixtures are the input.
    # The secret scan is NOT skipped — the gate runs for real against the fake repo.
    return Invoke-Script -Script $activateScript -ScriptArgs (@(
            '-Name', $EnvName, '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome,
            '-BackupRoot', $fakeBackups, '-SkipBuild') + $Extra)
}

# 9.1 DryRun is a plan producer only: without an explicit external -PlanPath it
# fails closed before any gate or traversal.
$homeSnapshotBefore = Get-TreeSnapshot -Root $fakeHome
$result = Invoke-Activate -EnvName 'good'
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-plan-path-required') 'activate DryRun requires an explicit external plan path'
Assert ((Get-TreeSnapshot -Root $fakeHome) -eq $homeSnapshotBefore) 'the refused DryRun changes nothing in the fake home'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'state'))) 'the refused DryRun creates no state/'

# 9.2 Apply without a plan is refused: internal plan generation is impossible,
# and the production interlock is the first gate outside the approved sandbox.
$result = Invoke-Activate -EnvName 'good' -Extra @('-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-plan-path-required') 'activate Apply without -PlanPath is refused (no internal plan generation)'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'state'))) 'the refused apply writes no state'
Assert (@(Get-ChildItem -LiteralPath $fakeBackups -Directory -ErrorAction SilentlyContinue).Count -eq 0) 'the refused apply creates no backup root'
Assert (Test-Path -LiteralPath $systemSentinel) 'codex .system sentinel untouched by the refused apply'
Assert (Test-Path -LiteralPath $unknownLocal) 'unmanaged live skill untouched by the refused apply'

# The interlock is the first gate of the production (non-sandbox) invocation.
$neverPlannedPath = Join-Path $work 'never-planned.json'
$interlockedOut = & pwsh -NoProfile -File $activateScript -Name 'good' -RepoRoot $fakeRepo -HomeRoot $fakeHome -BackupRoot $fakeBackups -Apply -PlanPath $neverPlannedPath 2>&1 | Out-String
Assert ($LASTEXITCODE -ne 0 -and $interlockedOut -match 'safety-protocol-upgrade-required') 'production activation Apply stays interlocked outside the approved sandbox'
Assert (-not (Test-Path -LiteralPath $neverPlannedPath)) 'the interlocked apply writes no plan'

# 9.8 failures never write state
Remove-Item -LiteralPath (Join-Path $fakeRepo 'state') -Recurse -Force -ErrorAction SilentlyContinue
$result = Invoke-Activate -EnvName 'ghost' -Extra @('-PlanPath', (Join-Path $work 'ghost-plan.json'), '-DryRun')
Assert ($result.Code -ne 0 -and $result.Out -match 'Unknown env') 'activating an unknown env fails'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'state'))) 'failed activation writes no state'
Assert (-not (Test-Path -LiteralPath (Join-Path $work 'ghost-plan.json'))) 'the unknown-env refusal writes no plan'

# 9.9 the home must not be the repository or live inside it
$insideHomePlan = Join-Path $work 'inside-home-plan.json'
$insideHomePath = Join-Path $fakeRepo 'home-inside'
$result = Invoke-Script -Script $activateScript -ScriptArgs @(
    '-Name', 'good', '-RepoRoot', $fakeRepo, '-HomeRoot', $insideHomePath,
    '-ControlBase', (Join-Path $insideHomePath 'AppData/Local/ai-agent-dotfiles/control'),
    '-BackupRoot', $fakeBackups, '-PlanPath', $insideHomePlan, '-DryRun', '-SkipBuild')
Assert ($result.Code -ne 0 -and $result.Out -match 'must not be the repository') 'a home inside the repository is refused'
Assert (-not (Test-Path -LiteralPath $insideHomePlan)) 'the inside-repo home refusal writes no plan'

# ==============================================================================
# 9.3-9.7 activation: the plan producer + consumer matrix. Every mutation runs
# inside the approved internal sandbox against a fake home whose shared
# authority was established by the reviewed adopt transition; the repo-local
# legacy state is seeded with sentinel bytes and must stay byte-identical.
Write-Host 'activate: plan producer and plan consumer'

function New-ActivationFakeRepo {
    param([Parameter(Mandatory)] [string] $Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize the activation fixture repository.' }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/profiles') -Destination (Join-Path $Path 'harness-source/profiles') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components') -Destination (Join-Path $Path 'harness-source/components') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools') -Destination (Join-Path $Path 'tools') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'schemas') -Destination (Join-Path $Path 'schemas') -Recurse -Force
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
    Set-File -Path (Join-Path $Path 'harness-source/envs/multi.psd1') -Content (New-EnvDefinitionText -Name 'multi' -ClaudeSkills @('fixture-a', 'fixture-b') -CodexSkills @('fixture-a', 'fixture-b') -ReasonixSkills @('fixture-a', 'fixture-b'))
    Set-File -Path (Join-Path $Path 'harness-source/envs/single.psd1') -Content (New-EnvDefinitionText -Name 'single' -ClaudeSkills @('fixture-a') -CodexSkills @('fixture-a') -ReasonixSkills @('fixture-a'))
    Set-File -Path (Join-Path $Path 'harness-source/envs/empty.psd1') -Content (New-EnvDefinitionText -Name 'empty')
    & git -C $Path add -A 2>&1 | Out-Null
    & git -C $Path -c user.email=fixture@example.invalid -c user.name=fixture commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the activation fixture repository.' }
    return $Path
}

function Set-ActivationDirectoryCurrentUserOnly {
    param([Parameter(Mandatory)] [string] $Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit), [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($Path)), $security)
}

function Write-ActivationSemanticDocument {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, [System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $Document)), [System.Text.UTF8Encoding]::new($false))
}

function New-ActivationSandbox {
    # Mirrors tests/harness-authority.tests.ps1's CLI sandbox: a committed fake
    # repository, the sealed private prefix, the canonical setup records, and a
    # live home with an unmanaged skill plus the Codex .system sentinel.
    param([Parameter(Mandatory)] [string] $Root)

    $sandbox = Join-Path $Root 'sandbox'
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $cliRepo = New-ActivationFakeRepo -Path (Join-Path $sandbox 'repo')
    $sandboxHome = Join-Path $sandbox 'home'
    New-Item -ItemType Directory -Path (Join-Path $sandboxHome '.claude/skills/unknown-local') -Force | Out-Null
    Set-File -Path (Join-Path $sandboxHome '.claude/skills/unknown-local/SKILL.md') -Content '# unmanaged local skill'
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
    Set-ActivationDirectoryCurrentUserOnly -Path $recoveryParent
    $recovery = Join-Path $recoveryParent 'recovery'
    New-Item -ItemType Directory -Force -Path $recovery | Out-Null
    Set-ActivationDirectoryCurrentUserOnly -Path $recovery
    $payload = New-CanonicalSetupPlanPayload -RepoRoot $cliRepo -CanonicalRecoveryRoot $recovery -ControlBase ([string] $context.ControlBase) -BackupRoot ([string] $context.BackupRoot) -ProbeRoot $probe -ToolchainRoot $RepoRoot
    $paths = Get-CanonicalTransactionContractPaths -GitContext (Get-CanonicalGitContext -RepoRoot $cliRepo)
    $state = New-CanonicalFinalSetupState -PlanPayload $payload -RepoRoot $cliRepo
    $repoId = Get-CanonicalRepoIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $cliRepo)
    $lock = Enter-CanonicalRepoLock -LockPath ([string] $paths.LockPath) -AllowCreate
    try {
        Write-ActivationSemanticDocument -Path ([string] $paths.SetupStatePath) -Document $state
        Write-ActivationSemanticDocument -Path (Join-Path ([string] $context.ControlBase) (Join-Path 'canonical-roots' ($repoId + '.json'))) -Document ([System.Collections.IDictionary] $payload.ExpectedRootClaim)
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

function Invoke-ActivationCli {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $SandboxRoot,
        [string] $ScriptPath = $activateScript,
        [switch] $Direct
    )
    if ($Direct) {
        # Direct invocation outside the sandbox: the production interlock owns
        # the outcome and no sandbox capability is present.
        $out = & pwsh -NoProfile -File $ScriptPath @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    }
    $result = Invoke-SafetySandboxScript -SandboxRoot $SandboxRoot -ScriptPath $ScriptPath -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
    return [pscustomobject]@{ Code = $result.Code; Out = $result.Out }
}

function Get-ActivationPlanDocument {
    param([Parameter(Mandatory)] [string] $Path)
    return ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($Path)))
}

function Get-ActivationFileHash {
    # The plan/state artifacts spell hashes lowercase; Get-FileHash does not.
    param([Parameter(Mandatory)] [string] $Path)
    return ([string] (Get-HarnessFileHash -Path $Path)).ToLowerInvariant()
}

function New-ActivationTamperedPlan {
    # Copies a plan with a mutation applied and both envelope hashes recomputed,
    # so the semantic layer (not the integrity gate) owns the refusal.
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [Parameter(Mandatory)] [scriptblock] $Mutate
    )
    $document = Get-ActivationPlanDocument -Path $SourcePath
    & $Mutate $document
    $document['PlanHash'] = Get-PlanHash -PlanPayload $document['PlanPayload']
    $document['DocumentHash'] = Get-DocumentHash -Document $document
    [System.IO.File]::WriteAllText($DestinationPath, (ConvertTo-Json -InputObject $document -Depth 40) + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Get-ActivationJournalRecords {
    param([Parameter(Mandatory)] [string] $TransactionDirectory)
    return @(Get-ChildItem -LiteralPath $TransactionDirectory -File -Filter '0*.json' | Sort-Object Name | ForEach-Object {
            ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($_.FullName)))
        })
}

$activationRoot = Join-Path $work 'activation'
$activation = New-ActivationSandbox -Root $activationRoot
$actSandbox = [string] $activation.Sandbox
$actRepo = [string] $activation.Repo
$actHome = [string] $activation.Home
$actBackups = [string] $activation.Context.BackupRoot
$actAuthorityRoot = [string] $activation.AuthorityRoot
$actStatePath = Join-Path $actAuthorityRoot 'current-env.json'
$actClaimsPath = Join-Path $actAuthorityRoot 'root-claims.json'
Assert ([string] (Get-CanonicalSetupStatus -RepoRoot $actRepo -ToolchainRoot $RepoRoot) -ceq 'canonical-ready') 'the activation sandbox canonical setup is accepted'

# Establish the shared authority through the reviewed adopt transition: the
# activation kind only ever runs on a machine that already has one.
$adoptPlan = Join-Path $actSandbox 'adopt-plan.json'
$authorityScript = Join-Path $RepoRoot 'scripts/authority-harness-env.ps1'
$adoptDryRun = Invoke-ActivationCli -SandboxRoot $actSandbox -ScriptPath $authorityScript -Arguments @('-Action', 'adopt', '-Name', 'multi', '-DryRun', '-PlanPath', $adoptPlan, '-RepoRoot', $actRepo)
Assert ($adoptDryRun.Code -eq 0) 'the activation sandbox plans its first authority through adopt'
$adoptApply = Invoke-ActivationCli -SandboxRoot $actSandbox -ScriptPath $authorityScript -Arguments @('-Action', 'adopt', '-Name', 'multi', '-Apply', '-PlanPath', $adoptPlan, '-RepoRoot', $actRepo)
if ($adoptApply.Code -ne 0) { Write-Host "  note  adopt apply:"; Write-Host $adoptApply.Out }
Assert ($adoptApply.Code -eq 0) 'the activation sandbox establishes its shared authority through adopt'
Assert (Test-Path -LiteralPath $actStatePath -PathType Leaf) 'the adopt transition publishes the shared authority state'

# The repo-local legacy state is immutable evidence for this whole matrix.
$legacyStatePath = Join-Path $actRepo 'state/current-env.json'
$legacySentinelBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{"SchemaVersion":2,"Name":"legacy-sentinel","Legacy":true}')
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacyStatePath) | Out-Null
[System.IO.File]::WriteAllBytes($legacyStatePath, $legacySentinelBytes)
$legacyHashBefore = Get-ActivationFileHash -Path $legacyStatePath
$claimsHashBefore = Get-ActivationFileHash -Path $actClaimsPath

# The private-root envelope pins the backup root to receipt slots only, so the
# deleted latest-directory scan can never select a foreign "sync-backup-*"
# directory: the activation receipt is the only reference the summary reports.
$decoyBackup = Join-Path $actBackups 'sync-backup-20301231-000000'
Set-File -Path (Join-Path $decoyBackup 'backup-manifest.json') -Content '{"SchemaVersion":1,"Decoy":true}'
$decoyPlan = Join-Path $actSandbox 'decoy-plan.json'
$decoyDryRun = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $decoyPlan, '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($decoyDryRun.Code -eq 0) 'the latest-backup race case plans against the valid authority'
$decoyStateHashBefore = Get-ActivationFileHash -Path $actStatePath
$decoyApply = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $decoyPlan, '-Apply')
Assert ($decoyApply.Code -ne 0 -and $decoyApply.Out -match 'home-authority-bootstrap-manual-recovery-required') 'a foreign latest-directory backup under the receipt root is refused by the prefix gate'
Assert ((Get-ActivationFileHash -Path $actStatePath) -eq $decoyStateHashBefore) 'the refused latest-directory race changes no state'
Remove-Item -LiteralPath $decoyBackup -Recurse -Force

$schemaRootForPlans = Join-Path $RepoRoot 'schemas'
$syncPlanSchemaValidation = Test-RepositoryJsonSchema -SchemaPath (Join-Path $schemaRootForPlans 'sync-plan.schema.json') -SchemaRoot $schemaRootForPlans
$activationMatrix = @(
    [ordered]@{ Name = 'empty'; Label = 'empty'; Actions = 0 }
    [ordered]@{ Name = 'single'; Label = 'single'; Actions = 3 }
    [ordered]@{ Name = 'multi'; Label = 'multi'; Actions = 6 }
)
$activationMatrixIndex = 0
foreach ($case in $activationMatrix) {
    $activationMatrixIndex++
    $envName = [string] $case.Name
    $planPath = Join-Path $actSandbox "activate-$envName-plan.json"
    $summaryPath = Join-Path $actSandbox "activate-$envName-summary.json"

    $dryRun = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', $envName, '-RepoRoot', $actRepo, '-PlanPath', $planPath, '-JsonPath', $summaryPath, '-DryRun', '-SkipBuild', '-SkipSecretScan')
    if ($dryRun.Code -ne 0) { Write-Host "  note  $envName dryrun:"; Write-Host $dryRun.Out }
    Assert ($dryRun.Code -eq 0) "activation DryRun succeeds for the $($case.Label) skill subset"
    Assert (Test-Path -LiteralPath $planPath -PathType Leaf) "the $($case.Label) DryRun writes its external plan"

    $schemaOk = $true
    try { $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $syncPlanSchemaValidation -InstanceBytes ([System.IO.File]::ReadAllBytes($planPath)) -InstancePath "activation-$envName-plan.emitted.json" }
    catch { $schemaOk = $false; Write-Host "  note  $envName plan failed schema validation: $($_.Exception.Message)" }
    Assert $schemaOk "the $($case.Label) plan validates against the sync-plan schema"
    $planDocument = Get-ActivationPlanDocument -Path $planPath
    $semanticsOk = $true
    try { Test-LiveSyncPlanSemantics -Document $planDocument }
    catch { $semanticsOk = $false; Write-Host "  note  $envName plan failed semantics: $($_.Exception.Message)" }
    Assert $semanticsOk "the $($case.Label) plan passes the frozen plan semantics"
    Assert ([string] $planDocument.PlanPayload.OperationKind -ceq 'environment') "the $($case.Label) plan is an environment plan"
    Assert ([string] $planDocument.PlanPayload.Generator -ceq 'scripts/activate-harness-env.ps1') "the $($case.Label) plan names the activation producer"
    Assert ([string] $planDocument.PlanPayload.EnvironmentName -ceq $envName) "the $($case.Label) plan carries the requested name"
    Assert ([string] $planDocument.PlanPayload.AuthorityStateIntent.LastOperationKind -ceq 'environment') "the $($case.Label) intent records the environment operation"
    Assert ([string] $planDocument.PlanPayload.AuthorityStateIntent.RootClaimsHash -ceq $claimsHashBefore) "the $($case.Label) plan binds the exact live claims bytes hash"
    Assert (@($planDocument.PlanPayload.OrderedActions).Count -eq [int] $case.Actions) "the $($case.Label) plan binds $($case.Actions) managed actions"

    $boundMaterialization = [string] $planDocument.PlanPayload.EnvironmentMaterializationRoot.Path
    Assert ([string] $planDocument.PlanPayload.EnvironmentMaterializationRoot.EnvLockHash -ceq [string] $planDocument.PlanPayload.AuthorityStateIntent.EnvironmentLockHash) "the $($case.Label) plan binds the materialization lock into the state intent"
    $buildBytes = [System.IO.File]::ReadAllBytes((Join-Path $boundMaterialization 'env-build.json'))
    $buildDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString($buildBytes))
    Assert ([string] $planDocument.PlanPayload.EnvironmentMaterializationRoot.EnvBuildHash -ceq (Get-ActivationFileHash -Path (Join-Path $boundMaterialization 'env-build.json'))) "the $($case.Label) plan binds the exact env-build bytes"
    Assert ([string] $planDocument.PlanPayload.EnvironmentMaterializationRoot.MaterializationHash -ceq [string] $buildDocument.MaterializationHash) "the $($case.Label) plan binds the exact MaterializationHash"
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        Assert (Test-Path -LiteralPath (Join-Path $boundMaterialization "$platform/skills") -PathType Container) "the $($case.Label) materialization revalidates the $platform source root"
    }

    $apply = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', $envName, '-RepoRoot', $actRepo, '-PlanPath', $planPath, '-JsonPath', $summaryPath, '-Apply')
    if ($apply.Code -ne 0) { Write-Host "  note  $envName apply:"; Write-Host $apply.Out }
    Assert ($apply.Code -eq 0) "activation Apply completes for the $($case.Label) skill subset"

    $state = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($actStatePath)))
    Assert ([string] $state.LastOperationKind -ceq 'environment') "the $($case.Label) apply publishes LastOperationKind=environment"
    Assert ([string] $state.EnvironmentName -ceq $envName) "the $($case.Label) apply publishes the selected environment name"
    Assert ([string] $state.RootClaimsHash -ceq $claimsHashBefore) "the $($case.Label) state keeps the immutable claims binding"
    Assert ([string] $state.EnvironmentLockHash -ceq [string] $planDocument.PlanPayload.AuthorityStateIntent.EnvironmentLockHash) "the $($case.Label) state publishes the planned lock hash"
    Assert ([string] $state.SelectionKind -ceq 'environment') "the $($case.Label) state keeps the environment selection kind"

    $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
    Assert ([string] $summary.Result -ceq 'PASS') "the $($case.Label) summary reports PASS"
    Assert ([string] $summary.ReceiptId -ceq [string] $state.ReceiptId) "the $($case.Label) summary carries the state's exact receipt id"
    Assert ([string] $summary.ReceiptPath -ceq (Join-Path $actBackups ([string] $state.ReceiptId))) "the $($case.Label) summary carries the exact receipt path"
    Assert ([string] $summary.ReceiptId -cne 'sync-backup-20301231-000000') "the $($case.Label) receipt is never the newest backup directory"
    Assert (Test-Path -LiteralPath (Join-Path ([string] $summary.ReceiptPath) '_meta/receipt.json') -PathType Leaf) "the $($case.Label) host receipt exists"
    $receiptDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path ([string] $summary.ReceiptPath) '_meta/receipt.json'))))
    Assert ([string] $receiptDocument.ReceiptHash -ceq [string] $state.ReceiptHash) "the $($case.Label) receipt hash matches the committed state"
    Assert ([string] $receiptDocument.SourceOperationKind -ceq 'environment') "the $($case.Label) receipt records the environment operation kind"
    Assert ([string] $summary.ReceiptHash -ceq [string] $state.ReceiptHash) "the $($case.Label) summary carries the exact receipt hash"
    Assert ([string] $summary.StateHash -ceq (Get-ActivationFileHash -Path $actStatePath)) "the $($case.Label) summary carries the installed state hash"
    Assert ([string] $summary.TransactionId -ceq [string] $state.JournalId) "the $($case.Label) summary carries the journaled transaction id"
    Assert (([string] $summary.ReceiptPath).StartsWith($actBackups + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) "the $($case.Label) receipt lives directly under the injected receipt root"

    $journalDir = Join-Path ([string] $activation.Context.LiveTransactionsRoot) ([string] $state.JournalId)
    $records = Get-ActivationJournalRecords -TransactionDirectory $journalDir
    $phases = @($records | ForEach-Object { [string] $_['Phase'] })
    Assert ($phases -ccontains 'STATE_PUBLISHED') "the $($case.Label) journal publishes the state"
    Assert ($phases -ccontains 'POSTCONDITIONS_OK') "the $($case.Label) journal records the postconditions"
    Assert ($phases -ccontains 'COMPLETE') "the $($case.Label) journal closes with COMPLETE"
    $statePreimageRecords = @($records | Where-Object {
            [string] $_['Phase'] -ceq 'FILE_PREPARED' -and [string] ($_['Data'])['TargetKind'] -ceq 'state' -and
            -not [string]::IsNullOrWhiteSpace([string] ($_['Data'])['StagedPath'])
        })
    Assert ($statePreimageRecords.Count -ge 1) "the $($case.Label) journal binds the state recovery preimage"
    Assert (Test-Path -LiteralPath (Join-Path $journalDir 'result.json') -PathType Leaf) "the $($case.Label) journal has a result"
    $journalResult = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes((Join-Path $journalDir 'result.json'))))
    Assert ([string] $journalResult.Outcome -ceq 'committed') "the $($case.Label) result commits"

    # One plan mutates once: the terminal journal now consumes the document
    # hash, so replaying the same plan is refused before any staging work.
    $appliedStateHash = Get-ActivationFileHash -Path $actStatePath
    $replay = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', $envName, '-RepoRoot', $actRepo, '-PlanPath', $planPath, '-Apply')
    Assert ($replay.Code -ne 0 -and $replay.Out -match 'live-plan-consumed') "the $($case.Label) plan is consumed by its first apply"
    Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $appliedStateHash) "the $($case.Label) replay changes no state"
}

Assert ((Get-ActivationFileHash -Path $legacyStatePath) -ceq $legacyHashBefore) 'the repo-local legacy state stays byte-identical through every activation'
Assert ([System.Linq.Enumerable]::SequenceEqual([byte[]] [System.IO.File]::ReadAllBytes($legacyStatePath), [byte[]] $legacySentinelBytes)) 'the legacy state bytes are the seeded sentinel bytes'
Assert ((Get-ActivationFileHash -Path $actClaimsPath) -ceq $claimsHashBefore) 'the immutable root claims stay byte-identical through every activation'
Assert (Test-Path -LiteralPath (Join-Path $actHome '.claude/skills/unknown-local/SKILL.md') -PathType Leaf) 'the unknown live directory survives every activation'

Write-Host 'activate: external plan and receipt failure matrix'
$failurePlan = Join-Path $actSandbox 'failure-base-plan.json'
$failureDryRun = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $failurePlan, '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($failureDryRun.Code -eq 0) 'the failure matrix has a fresh reviewed multi plan'

$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-plan-path-required') 'apply without -PlanPath is refused'
$stateHashBeforeFailures = Get-ActivationFileHash -Path $actStatePath

$failurePlanHashBefore = Get-ActivationFileHash -Path $failurePlan
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $failurePlan, '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-path-collision') 'a DryRun at an existing plan path is refused'
Assert ((Get-ActivationFileHash -Path $failurePlan) -ceq $failurePlanHashBefore) 'the collided plan path is not rewritten'

$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', (Join-Path $actRepo 'inside-plan.json'), '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($result.Code -ne 0 -and $result.Out -match 'disjoint from worktree') 'a plan path inside the worktree is refused'
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', (Join-Path $actRepo '.git/inside-plan.json'), '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($result.Code -ne 0 -and $result.Out -match 'disjoint from worktree') 'a plan path inside Git internals is refused'
Assert (-not (Test-Path -LiteralPath (Join-Path $actRepo 'inside-plan.json'))) 'the refused plan paths write no plan'
Assert (-not (Test-Path -LiteralPath (Join-Path $actRepo '.git/inside-plan.json'))) 'the Git-internal plan path writes no plan'

$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $adoptPlan, '-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-plan-kind-mismatch') 'a plan whose OperationKind is not environment is refused'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $stateHashBeforeFailures) 'the refused non-environment plan changes no state'

$wrongNamePlan = Join-Path $actSandbox 'tamper-wrong-name.json'
New-ActivationTamperedPlan -SourcePath $failurePlan -DestinationPath $wrongNamePlan -Mutate {
    param($document)
    $document['PlanPayload']['EnvironmentName'] = 'single'
    $document['PlanPayload']['AuthorityStateIntent']['EnvironmentName'] = 'single'
}
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $wrongNamePlan, '-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-selection-mismatch') 'a plan selecting another environment is refused'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $stateHashBeforeFailures) 'the refused wrong-name plan changes no state'

$wrongLockPlan = Join-Path $actSandbox 'tamper-wrong-lock.json'
New-ActivationTamperedPlan -SourcePath $failurePlan -DestinationPath $wrongLockPlan -Mutate {
    param($document)
    $document['PlanPayload']['AuthorityStateIntent']['EnvironmentLockHash'] = '0' * 64
}
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $wrongLockPlan, '-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-hash-mismatch') 'a plan whose state intent carries another lock hash is refused'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $stateHashBeforeFailures) 'the refused wrong-lock plan changes no state'

$wrongControllerPlan = Join-Path $actSandbox 'tamper-wrong-controller.json'
New-ActivationTamperedPlan -SourcePath $failurePlan -DestinationPath $wrongControllerPlan -Mutate {
    param($document)
    $document['PlanPayload']['ControllerRepoFingerprint'] = '0' * 64
    $document['PlanPayload']['AuthorityStateIntent']['ControllerRepoFingerprint'] = '0' * 64
}
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $wrongControllerPlan, '-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-controller-mismatch') 'a plan produced by another controller is refused'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $stateHashBeforeFailures) 'the refused foreign-controller plan changes no state'

$changedPlan = Join-Path $actSandbox 'failure-stale-plan.json'
$changedDryRun = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $changedPlan, '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($changedDryRun.Code -eq 0) 'the stale-materialization case plans first'
$changedMaterialization = Join-Path $actSandbox 'failure-stale-plan.materialization'
Add-Content -LiteralPath (Join-Path $changedMaterialization 'env.lock.json') -Value ' '
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $changedPlan, '-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-hash-mismatch') 'a changed materialization makes the plan stale'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $stateHashBeforeFailures) 'the refused stale plan changes no state'

# An older build shape is refused even when the plan was rewritten to bind it:
# the reviewed sidecar reader owns the frozen schema 3 semantics.
$v2Plan = Join-Path $actSandbox 'failure-v2-build-plan.json'
$v2DryRun = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $v2Plan, '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($v2DryRun.Code -eq 0) 'the older-build-shape case plans first'
$v2Materialization = Join-Path $actSandbox 'failure-v2-build-plan.materialization'
$v2BuildPath = Join-Path $v2Materialization 'env-build.json'
$v2Build = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($v2BuildPath)))
$v2Build['SchemaVersion'] = 2
$v2Build['MaterializationHash'] = Get-HarnessEnvMaterializationHash -Document $v2Build
[System.IO.File]::WriteAllText($v2BuildPath, (ConvertTo-Json -InputObject $v2Build -Depth 40) + "`n", [System.Text.UTF8Encoding]::new($false))
New-ActivationTamperedPlan -SourcePath $v2Plan -DestinationPath (Join-Path $actSandbox 'failure-v2-build-bound.json') -Mutate {
    param($document)
    $document['PlanPayload']['EnvironmentMaterializationRoot']['EnvBuildHash'] = ([string] (Get-HarnessFileHash -Path $v2BuildPath)).ToLowerInvariant()
    $document['PlanPayload']['EnvironmentMaterializationRoot']['MaterializationHash'] = [string] $v2Build['MaterializationHash']
}
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', (Join-Path $actSandbox 'failure-v2-build-bound.json'), '-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'env-build-schema-unsupported') 'a v2 env-build sidecar is refused even when the plan binds its bytes'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $stateHashBeforeFailures) 'the refused v2 build shape changes no state'

$overlayPlan = Join-Path $actSandbox 'failure-overlay-plan.json'
$overlayDryRun = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $overlayPlan, '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($overlayDryRun.Code -eq 0) 'the changed-overlay case plans first'
$overlayPath = Join-Path $actRepo '.agent-harness/task-skills.psd1'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $overlayPath) | Out-Null
Set-File -Path $overlayPath -Content "@{ SchemaVersion = 1; BaseEnv = 'multi'; Skills = @{ Claude = @('fixture-b'); Codex = @(); Reasonix = @() } }`n"
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $overlayPlan, '-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-materialization-invalid') 'a task overlay changed after the DryRun is refused'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $stateHashBeforeFailures) 'the refused changed-overlay plan changes no state'
Remove-Item -LiteralPath $overlayPath -Force

$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $failurePlan, '-Apply', '-SkipBuild')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-skip-switch-forbidden') 'Apply refuses -SkipBuild'
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $failurePlan, '-Apply', '-SkipSecretScan')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-skip-switch-forbidden') 'Apply refuses -SkipSecretScan'
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $failurePlan, '-Apply', '-ReasonixLiveSkillsPath', (Join-Path $actSandbox 'custom-reasonix'))
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-root-selection-forbidden') 'Apply refuses an explicit live-root request'
$result = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', (Join-Path $actSandbox 'root-selector-plan.json'), '-DryRun', '-SkipBuild', '-SkipSecretScan', '-ReasonixLiveSkillsPath', (Join-Path $actSandbox 'custom-reasonix'))
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-root-selection-forbidden') 'DryRun refuses an explicit live-root request'
Assert (-not (Test-Path -LiteralPath (Join-Path $actSandbox 'root-selector-plan.json'))) 'the refused root selection writes no plan'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $stateHashBeforeFailures) 'the refused switches change no state'

$result = Invoke-ActivationCli -Direct -SandboxRoot $actSandbox -Arguments @('-Name', 'multi', '-RepoRoot', $actRepo, '-PlanPath', $failurePlan, '-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'safety-protocol-upgrade-required') 'production Apply stays interlocked through the direct non-sandbox invocation'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $stateHashBeforeFailures) 'the interlocked direct apply changes no state'

# The state-write failure window: the host is hard-killed after the journaled
# state preimage and before the atomic state replace. The previous state stays
# byte-identical, the journal stops on FILE_REPLACE_INTENT without a result, and
# the next Apply is refused as recovery-required instead of resuming.
$killPlan = Join-Path $actSandbox 'failure-state-write-plan.json'
$killDryRun = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'single', '-RepoRoot', $actRepo, '-PlanPath', $killPlan, '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($killDryRun.Code -eq 0) 'the state-write failure case plans a fresh environment'
$killStateHashBefore = Get-ActivationFileHash -Path $actStatePath
$killController = New-FailpointController
$killSuffix = [Guid]::NewGuid().ToString('N')
$killOutFile = Join-Path $work "activation-kill-out-$killSuffix.txt"
$killErrFile = Join-Path $work "activation-kill-err-$killSuffix.txt"
$killHostScript = Join-Path $RepoRoot 'scripts/internal/live-transaction-host.ps1'
$killEncoded = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject @(@('-Name', 'single', '-RepoRoot', $actRepo, '-PlanPath', $killPlan, '-Apply')) -Compress)))
$killChild = $null
$savedFailpoints = [System.Environment]::GetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS')
try {
    [System.Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS', (ConvertTo-Json -InputObject @([ordered]@{ Checkpoint = 'STATE_REPLACE_PENDING'; PipeName = $killController.Name }) -Compress))
    $killChild = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $killHostScript, '-SandboxRoot', $actSandbox, '-ScriptPath', $activateScript, '-ArgumentsBase64', $killEncoded) -PassThru -WindowStyle Hidden -RedirectStandardOutput $killOutFile -RedirectStandardError $killErrFile
    Wait-FailpointController -Controller $killController -ExpectedCheckpoint 'STATE_REPLACE_PENDING' -TimeoutSeconds 240
    if ($killChild.HasExited) { throw 'the activation host exited before the state-write kill' }
    Stop-FailpointProcessTree -Process $killChild
    $null = $killChild.WaitForExit(60000)
}
finally {
    [System.Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS', $savedFailpoints)
    if ($null -ne $killChild -and -not $killChild.HasExited) { Stop-FailpointProcessTree -Process $killChild }
    Close-FailpointController -Controller $killController
}
Assert ($killChild.ExitCode -ne 0) 'the state-write failure window kills the activation host'
Assert ((Get-ActivationFileHash -Path $actStatePath) -ceq $killStateHashBefore) 'the killed state write leaves the previous authority state byte-identical'
$killJournalDirectories = @(Get-ChildItem -LiteralPath ([string] $activation.Context.LiveTransactionsRoot) -Directory -Force | Sort-Object LastWriteTimeUtc)
$killJournalDir = $killJournalDirectories[-1].FullName
$killRecords = Get-ActivationJournalRecords -TransactionDirectory $killJournalDir
$killPhases = @($killRecords | ForEach-Object { [string] $_['Phase'] })
Assert ($killPhases -ccontains 'FILE_REPLACE_INTENT') 'the killed state write records the replace intent'
Assert ($killPhases -cnotcontains 'STATE_PUBLISHED') 'the killed state write never publishes the state'
Assert (-not (Test-Path -LiteralPath (Join-Path $killJournalDir 'result.json') -PathType Leaf)) 'the killed state write leaves no result'
$killReplay = Invoke-ActivationCli -SandboxRoot $actSandbox -Arguments @('-Name', 'single', '-RepoRoot', $actRepo, '-PlanPath', $killPlan, '-Apply')
Assert ($killReplay.Code -ne 0 -and $killReplay.Out -match 'live-recovery-required') 'the unfinished state write blocks the next activation'

# 9.7 the deleted latest-directory scan is gone everywhere in scripts/.
$scanHits = @()
foreach ($scriptFile in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -File -Recurse -Filter '*.ps1')) {
    if ([System.IO.File]::ReadAllText($scriptFile.FullName).Contains('sync-backup-*')) { $scanHits += $scriptFile.FullName }
}
Assert ($scanHits.Count -eq 0) "no scripts/ file performs a sync-backup-* latest-directory scan ($($scanHits -join ', '))"
$activationText = [System.IO.File]::ReadAllText($activateScript)
Assert (-not $activationText.Contains('Get-LatestBackupReference')) 'the latest-backup lookup helper is deleted from activation'
Assert (-not $activationText.Contains('StateWritten')) 'the activation summary no longer claims a repo-local state write'
Assert (-not $activationText.Contains('Get-HarnessEnvStatePath')) 'activation never resolves the repo-local legacy state path'

# 9.9 entry point requires an explicit mode
$result = Invoke-Script -Script $entryScript -ScriptArgs @('env', 'activate', 'good')
Assert ($result.Code -eq 1) 'entry point rejects activate without an explicit mode'
$result = Invoke-Script -Script $entryScript -ScriptArgs @('env', 'activate', 'good', '-DryRun', '-Apply')
Assert ($result.Code -eq 1) 'entry point rejects activate with both modes'

# 9.10 env rollback CLI surface: the receipt selects a rollback, the legacy
# selection names are gone, and the public (non-sandbox) surface fails closed
# at the host-resolution gate before any authority or receipt work.
$result = Invoke-Script -Script $entryScript -ScriptArgs @('env', 'rollback')
Assert ($result.Code -eq 1) 'entry point rejects env rollback without a receipt path'
$legacyRollback = Invoke-Script -Script $entryScript -ScriptArgs @('env', 'rollback', 'RunId', '-Apply')
Assert ($legacyRollback.Code -eq 1) 'the legacy RunId token no longer selects a rollback and fails closed'
$publicRollback = Invoke-Script -Script $entryScript -ScriptArgs @(
    'env', 'rollback', '-ReceiptPath', (Join-Path $work 'absent-receipt'), '-DryRun', '-PlanPath', (Join-Path $work 'public-plan.json'))
Assert ($publicRollback.Code -ne 0 -and $publicRollback.Out -match 'live-plan-host-resolution-required') 'the public rollback surface fails closed without the sandbox authority'
Assert (-not (Test-Path -LiteralPath (Join-Path $work 'public-plan.json'))) 'the host-resolution rejection writes no plan'

# --- 10. project linkage: RequiredEnv detection (never auto-activates) ---------
Write-Host 'status: project RequiredEnv linkage'
$fakeProject = Join-Path $work 'project'
function Set-ProjectProfile {
    param([AllowNull()] [string] $RequiredEnvLine)
    Set-File -Path (Join-Path $fakeProject '.agent-harness/profile.psd1') -Content @"
@{
    SchemaVersion = 1
    Name = 'fixture-project'
    TargetPlatforms = @('Claude', 'Codex')
$RequiredEnvLine
}
"@
}
function Invoke-ProjectStatus {
    return Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo, '-ProjectRoot', $fakeProject)
}

Set-ProjectProfile -RequiredEnvLine "    RequiredEnv = 'small'"

# no activation yet (group 9 ended with state/ removed)
$result = Invoke-ProjectStatus
Assert ($result.Code -eq 0) 'project status exits 0'
Assert ($result.Out -match "requires env 'small' - no environment activated") 'reminds when nothing is activated'
Assert ($result.Out -match 'env activate small -DryRun') 'reminder suggests the activate command'

# activation -Apply without a reviewed external plan is refused, so the project
# reminder persists
$result = Invoke-Activate -EnvName 'small' -Extra @('-Apply')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-plan-path-required') 'activating the required env fails closed without a reviewed plan'
$result = Invoke-ProjectStatus
Assert ($result.Out -match "requires env 'small' - no environment activated") 'still reminds while activation has no reviewed plan'

# declared env without a definition
Set-ProjectProfile -RequiredEnvLine "    RequiredEnv = 'ghost'"
$result = Invoke-ProjectStatus
Assert ($result.Code -eq 0) 'missing-definition case still exits 0'
Assert ($result.Out -match "requires env 'ghost', which has no definition") 'warns when the required env has no definition'

# profile without RequiredEnv / project without profile
Set-ProjectProfile -RequiredEnvLine ''
$result = Invoke-ProjectStatus
Assert ($result.Out -match 'declares no RequiredEnv') 'plain profile reports no declaration'
Remove-Item -LiteralPath (Join-Path $fakeProject '.agent-harness') -Recurse -Force
$result = Invoke-ProjectStatus
Assert ($result.Code -eq 0 -and $result.Out -match 'declares no RequiredEnv') 'missing profile file reports no declaration without failing'

# --- Summary --------------------------------------------------------------------
Write-Host ''
Write-Host ("harness-env tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) {
    Write-Host "Workspace kept for inspection: $work"
    exit 1
}
Remove-Work
exit 0
