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

$work = Join-Path $RepoRoot 'tmp/harness-env-tests'
function Remove-Work {
    if (($work -like '*tmp*harness-env-tests*') -and (Test-Path -LiteralPath $work)) {
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
    }
    McpTemplates = @()
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

Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/profiles') `
    -Destination (Join-Path $fakeRepo 'harness-source/profiles') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components') `
    -Destination (Join-Path $fakeRepo 'harness-source/components') -Recurse -Force

# fixture-c is managed but has no generated output (build precondition case).
Set-File -Path (Join-Path $fakeRepo 'manifests/managed-skills.claude.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
Set-File -Path (Join-Path $fakeRepo 'manifests/managed-skills.codex.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
foreach ($platform in @('claude', 'codex')) {
    foreach ($skill in @('fixture-a', 'fixture-b')) {
        Set-File -Path (Join-Path $fakeRepo "$platform/skills/$skill/SKILL.md") -Content "# $skill ($platform fixture)"
    }
}

$envRoot = Join-Path $fakeRepo 'harness-source/envs'
$goodDefinitionPath = Join-Path $envRoot 'good.psd1'
Set-File -Path $goodDefinitionPath -Content (New-EnvDefinitionText -Name 'good' -ClaudeSkills @('fixture-b', 'fixture-a') -CodexSkills @('fixture-a'))

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

# --- 4. build success ---------------------------------------------------------
Write-Host 'build: success'
$result = Invoke-Script -Script $buildScript -ScriptArgs @('-Name', 'good', '-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0) 'build succeeds for the good env'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'claude/skills/fixture-a/SKILL.md')) 'staging contains claude fixture-a'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'claude/skills/fixture-b/SKILL.md')) 'staging contains claude fixture-b'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'codex/skills/fixture-a/SKILL.md')) 'staging contains codex fixture-a'
Assert (-not (Test-Path -LiteralPath (Join-Path $goodStaging 'codex/skills/fixture-b'))) 'staging omits unselected codex skill'
$claudeManifest = (Get-Content -LiteralPath (Join-Path $goodStaging 'manifest.claude.txt') | Where-Object { $_ -ne '' })
Assert (($claudeManifest -join ',') -eq 'fixture-a,fixture-b') 'claude manifest is sorted (definition listed b before a)'
$codexManifest = (Get-Content -LiteralPath (Join-Path $goodStaging 'manifest.codex.txt') | Where-Object { $_ -ne '' })
Assert (($codexManifest -join ',') -eq 'fixture-a') 'codex manifest matches the env definition'
$agentsGenerated = Join-Path $goodStaging 'profile/AGENTS.generated.md'
Assert (Test-Path -LiteralPath $agentsGenerated) 'profile/AGENTS.generated.md rendered'
Assert ((Get-Content -Raw -LiteralPath $agentsGenerated) -match '<!-- BEGIN AGENT-HARNESS: ') 'managed block markers present'
Assert (Test-Path -LiteralPath (Join-Path $goodStaging 'profile/claude-settings.generated.json')) 'profile settings fragment rendered'
$lockPath = Join-Path $goodStaging 'env.lock.json'
Assert (Test-Path -LiteralPath $lockPath) 'env.lock.json written'
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
Assert ([string] $lock.Name -eq 'good') 'lock records the env name'
$lockedFiles = @($lock.BuiltFiles.PSObject.Properties.Name)
Assert ($lockedFiles.Count -gt 0 -and ($lockedFiles -notcontains 'env.lock.json')) 'lock covers built files but not itself'
$stagedFiles = @(Get-ChildItem -LiteralPath $goodStaging -File -Recurse -Force |
        Where-Object { $_.Name -ne 'env.lock.json' })
Assert ($lockedFiles.Count -eq $stagedFiles.Count) 'lock covers every staged file'

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

# --- 8. read-only guarantee for list/status ------------------------------------
Write-Host 'list/status: read-only guarantee'
if (Test-Path -LiteralPath (Join-Path $fakeRepo 'envs')) {
    Remove-Item -LiteralPath (Join-Path $fakeRepo 'envs') -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $fakeRepo 'state')) {
    Remove-Item -LiteralPath (Join-Path $fakeRepo 'state') -Recurse -Force
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
foreach ($dir in @('.claude/skills/unknown-local', '.codex/skills/.system', '.openclaw/skills')) {
    New-Item -ItemType Directory -Path (Join-Path $fakeHome $dir) -Force | Out-Null
}
Set-File -Path (Join-Path $fakeHome '.claude/skills/unknown-local/SKILL.md') -Content '# unmanaged local skill'
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

# 9.1 dry-run writes nothing
$homeSnapshotBefore = Get-TreeSnapshot -Root $fakeHome
$result = Invoke-Activate -EnvName 'good'
Assert ($result.Code -eq 0) 'activate dry-run exits 0'
Assert ($result.Out -match 'State file would be written') 'dry-run announces the state file without writing it'
Assert ((Get-TreeSnapshot -Root $fakeHome) -eq $homeSnapshotBefore) 'dry-run changes nothing in the fake home'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'state'))) 'dry-run creates no state/'

# 9.2 apply installs skills, writes state, backs up, preserves sentinels
$result = Invoke-Activate -EnvName 'good' -Extra @('-Apply')
Assert ($result.Code -eq 0) 'activate apply exits 0'
Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/fixture-a/SKILL.md')) 'apply installs claude fixture-a'
Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/fixture-b/SKILL.md')) 'apply installs claude fixture-b'
Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.codex/skills/fixture-a/SKILL.md')) 'apply installs codex fixture-a'
$state = Get-Content -Raw -LiteralPath (Join-Path $fakeRepo 'state/current-env.json') | ConvertFrom-Json
Assert ([string] $state.Name -eq 'good') 'state file records the activated env'
Assert ($state.PSObject.Properties.Name -contains 'DefinitionHash') 'state file records the definition hash'
Assert ($state.PSObject.Properties.Name -contains 'ActivatedAtUtc') 'state file records the activation time'
Assert (@(Get-ChildItem -LiteralPath $fakeBackups -Directory -ErrorAction SilentlyContinue).Count -gt 0) 'mandatory backup ran before apply'
Assert (Test-Path -LiteralPath $systemSentinel) 'codex .system sentinel untouched by apply'
Assert (Test-Path -LiteralPath $unknownLocal) 'unmanaged live skill untouched by apply'

# 9.3 status/list integration
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'Active environment: good') 'status reports the activated env'
$result = Invoke-Script -Script $listScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match '\*\s*good') 'list marks the activated env'

# 9.4 re-apply adds and prunes nothing and leaves content identical
# (sync.ps1 always refreshes managed skills present on both sides, so the plan
# shows updates; idempotence is asserted via adds/prunes and content hashes)
$homeSnapshotBefore = Get-TreeSnapshot -Root $fakeHome
$result = Invoke-Activate -EnvName 'good' -Extra @('-Apply')
Assert ($result.Code -eq 0) 're-activate exits 0'
Assert ($result.Out -match 'Claude\s*:\s*\+0 ~2 -0') 're-activate plans refresh-only for claude'
Assert ($result.Out -match 'Codex\s*:\s*\+0 ~1 -0') 're-activate plans refresh-only for codex'
Assert ((Get-TreeSnapshot -Root $fakeHome) -eq $homeSnapshotBefore) 're-activate leaves home content identical'

# 9.5 switching to a smaller env prunes managed skills, preserves the rest
$result = Invoke-Activate -EnvName 'small' -Extra @('-Apply')
Assert ($result.Code -eq 0) 'activate small exits 0'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/fixture-b'))) 'switching prunes the managed skill not in the new env'
Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/fixture-a/SKILL.md')) 'shared skill survives the switch'
Assert (Test-Path -LiteralPath $systemSentinel) 'codex .system sentinel survives the switch'
Assert (Test-Path -LiteralPath $unknownLocal) 'unmanaged live skill survives the switch'
$state = Get-Content -Raw -LiteralPath (Join-Path $fakeRepo 'state/current-env.json') | ConvertFrom-Json
Assert ([string] $state.Name -eq 'small') 'state file follows the switch'

# 9.6 status flags definition drift after activation
$originalSmall = [System.IO.File]::ReadAllBytes($smallDefinitionPath)
Add-Content -LiteralPath $smallDefinitionPath -Value '# post-activation edit'
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'definition changed since activation') 'status flags definition drift after activation'
[System.IO.File]::WriteAllBytes($smallDefinitionPath, $originalSmall)
$result = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $fakeRepo)
Assert ($result.Out -notmatch 'definition changed since activation') 'drift flag clears after restore'

# 9.7 failures never write state
Remove-Item -LiteralPath (Join-Path $fakeRepo 'state') -Recurse -Force
$result = Invoke-Activate -EnvName 'ghost' -Extra @('-Apply')
Assert ($result.Code -ne 0) 'activating an unknown env fails'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'state'))) 'failed activation writes no state'
$result = Invoke-Script -Script $activateScript -ScriptArgs @(
    '-Name', 'good', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeRepo, '-SkipBuild', '-Apply')
Assert ($result.Code -ne 0) 'activation refuses HomeRoot inside the repository'
Assert (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'state'))) 'refused activation writes no state'

# 9.8 entry point requires an explicit mode
$result = Invoke-Script -Script $entryScript -ScriptArgs @('env', 'activate', 'good')
Assert ($result.Code -eq 1) 'entry point rejects activate without an explicit mode'
$result = Invoke-Script -Script $entryScript -ScriptArgs @('env', 'activate', 'good', '-DryRun', '-Apply')
Assert ($result.Code -eq 1) 'entry point rejects activate with both modes'

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

# activate the required env -> matches
$result = Invoke-Activate -EnvName 'small' -Extra @('-Apply')
Assert ($result.Code -eq 0) 'activating the required env succeeds'
$result = Invoke-ProjectStatus
Assert ($result.Out -match "requires env 'small' - matches active") 'reports a match after activation'

# mismatch: switch active env away from the requirement
$result = Invoke-Activate -EnvName 'good' -Extra @('-Apply')
Assert ($result.Code -eq 0) 'switching to another env succeeds'
$result = Invoke-ProjectStatus
Assert ($result.Out -match "requires env 'small' - does not match active 'good'") 'reports the mismatch'
Assert ($result.Out -match 'env activate small -DryRun') 'mismatch suggests the activate command'
$state = Get-Content -Raw -LiteralPath (Join-Path $fakeRepo 'state/current-env.json') | ConvertFrom-Json
Assert ([string] $state.Name -eq 'good') 'detection never auto-activates (state unchanged)'

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
