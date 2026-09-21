#requires -Version 7.0
<##
.SYNOPSIS
    Regression tests for the plan-bound repository-shared task skill overlay.

.DESCRIPTION
    Uses one committed fake repository with its own approved-style toolchain
    copies, a fake home with the derived control base, the canonical setup
    records, and a shared authority established through the reviewed adopt
    transition. Every mutation runs inside the approved internal sandbox; the
    real task CLI, plan semantics, live transaction host, and journal are
    exercised. No real home, live skill root, tracked overlay, or real state
    file is touched.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'helpers/safety-sandbox.ps1')
. (Join-Path $PSScriptRoot 'helpers/failpoint-controller.ps1')
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/harness-env-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-plan-evidence-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-transaction-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')
. (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
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

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-task-skills-$([Guid]::NewGuid().ToString('N'))"
function Remove-Work {
    if (($work -like '*ai-agent-dotfiles-task-skills-*') -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [AllowNull()] [string] $Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value ($Content ?? '') -NoNewline -Encoding UTF8
}

function New-OverlayText {
    param([string[]] $Claude = @(), [string[]] $Codex = @(), [string[]] $Reasonix = @(), [string] $Base = 'work')
    function Format-Names([string[]] $Names) {
        if ($Names.Count -eq 0) { return '@()' }
        return '@(' + ((($Names | Sort-Object) | ForEach-Object { "'$_'" }) -join ', ') + ')'
    }
    return @"
@{
    SchemaVersion = 1
    BaseEnv = '$Base'
    Skills = @{
        Claude = $(Format-Names $Claude)
        Codex = $(Format-Names $Codex)
        Reasonix = $(Format-Names $Reasonix)
    }
}
"@
}

function Get-FileHashLower {
    param([Parameter(Mandatory)] [string] $Path)
    return ([string] (Get-HarnessFileHash -Path $Path)).ToLowerInvariant()
}

function Invoke-TaskCli {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $Direct
    )
    if ($Direct) {
        $out = & pwsh -NoProfile -File $ScriptPath @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    }
    $result = Invoke-SafetySandboxScript -SandboxRoot $sandbox -ScriptPath $ScriptPath -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
    return [pscustomobject]@{ Code = $result.Code; Out = $result.Out }
}

function Get-PlanDocument {
    param([Parameter(Mandatory)] [string] $Path)
    return ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($Path)))
}

function Get-JournalRecords {
    param([Parameter(Mandatory)] [string] $TransactionDirectory)
    return @(Get-ChildItem -LiteralPath $TransactionDirectory -File -Filter '0*.json' | Sort-Object Name | ForEach-Object {
            ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($_.FullName)))
        })
}

function Set-DirectoryCurrentUserOnly {
    param([Parameter(Mandatory)] [string] $Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit), [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($Path)), $security)
}

function Write-SemanticDocument {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, [System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $Document)), [System.Text.UTF8Encoding]::new($false))
}

Remove-Work
New-Item -ItemType Directory -Path $work -Force | Out-Null
$sandbox = Join-Path $work 'sandbox'
$repo = Join-Path $sandbox 'repo'
$fakeHome = Join-Path $sandbox 'home'
New-Item -ItemType Directory -Path $repo -Force | Out-Null
& git -C $repo init --quiet
if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize the task fixture repository.' }

Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts') -Destination (Join-Path $repo 'scripts') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'schemas') -Destination (Join-Path $repo 'schemas') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools') -Destination (Join-Path $repo 'tools') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/profiles') -Destination (Join-Path $repo 'harness-source/profiles') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components') -Destination (Join-Path $repo 'harness-source/components') -Recurse -Force
Set-File -Path (Join-Path $repo 'manifests/managed-skills.claude.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
Set-File -Path (Join-Path $repo 'manifests/managed-skills.codex.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
Set-File -Path (Join-Path $repo 'manifests/managed-skills.reasonix.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
foreach ($skill in @('fixture-a', 'fixture-b', 'fixture-c')) {
    Set-File -Path (Join-Path $repo "skills-source/shared/$skill/SKILL.md") -Content "# $skill source"
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        Set-File -Path (Join-Path $repo "$platform/skills/$skill/SKILL.md") -Content "# $skill $platform"
    }
}
Set-File -Path (Join-Path $repo 'harness-source/envs/work.psd1') -Content @"
@{
    SchemaVersion = 1
    Name = 'work'
    Description = 'fixture work env'
    Profile = 'coding'
    Skills = @{
        Claude = @('fixture-a')
        Codex = @('fixture-a')
        Reasonix = @('fixture-a')
    }
}
"@
$overlayPath = Join-Path $repo '.agent-harness/task-skills.psd1'
Set-File -Path $overlayPath -Content (New-OverlayText)
& git -C $repo add -A 2>&1 | Out-Null
& git -C $repo -c user.email=fixture@example.invalid -c user.name=fixture commit --quiet -m fixture
if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the task fixture repository.' }

foreach ($dir in @('.claude/skills', '.codex/skills/.system', 'AppData/Roaming/reasonix/skills', 'AppData/Local')) {
    New-Item -ItemType Directory -Path (Join-Path $fakeHome $dir) -Force | Out-Null
}
Set-File -Path (Join-Path $fakeHome '.claude/skills/fixture-a/SKILL.md') -Content '# fixture-a claude'
Set-File -Path (Join-Path $fakeHome '.codex/skills/fixture-a/SKILL.md') -Content '# fixture-a codex'
Set-File -Path (Join-Path $fakeHome '.codex/skills/.system/.codex-system-skills.marker') -Content ''
$systemSentinel = Join-Path $fakeHome '.codex/skills/.system/system.md'
Set-File -Path $systemSentinel -Content '# fixture system'

$identity = [pscustomobject][ordered]@{
    ResolverVersion = 'windows-token-sid-known-folder-v1'
    TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    ProfileRoot = $fakeHome
    RoamingAppDataRoot = (Join-Path $fakeHome 'AppData/Roaming')
    LocalAppDataRoot = (Join-Path $fakeHome 'AppData/Local')
}
$authorityContext = Resolve-HomeAuthorityContextFromIdentity -Identity $identity
$controlBase = [string] $authorityContext.ControlBase
$backupRoot = [string] $authorityContext.BackupRoot
$authorityRoot = Join-Path (Join-Path $controlBase 'homes') ([string] $authorityContext.HomeAuthorityKey)
$statePath = Join-Path $authorityRoot 'current-env.json'
$bootstrapIntent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $authorityContext -FilesystemCapabilityHash ('a' * 64)
$bootstrapLock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $authorityContext -Intent $bootstrapIntent
Exit-HomeAuthorityGlobalLiveLock -LockHandle $bootstrapLock

$probe = Join-Path $work 'canonical-probe'
$recoveryParent = Join-Path $work 'canonical-recovery-parent'
foreach ($dir in @($probe, $recoveryParent)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Set-DirectoryCurrentUserOnly -Path $recoveryParent
$recovery = Join-Path $recoveryParent 'recovery'
New-Item -ItemType Directory -Force -Path $recovery | Out-Null
Set-DirectoryCurrentUserOnly -Path $recovery
$setupPayload = New-CanonicalSetupPlanPayload -RepoRoot $repo -CanonicalRecoveryRoot $recovery -ControlBase $controlBase -BackupRoot $backupRoot -ProbeRoot $probe -ToolchainRoot $RepoRoot
$contractPaths = Get-CanonicalTransactionContractPaths -GitContext (Get-CanonicalGitContext -RepoRoot $repo)
$setupState = New-CanonicalFinalSetupState -PlanPayload $setupPayload -RepoRoot $repo
$repoId = Get-CanonicalRepoIdentity -GitContext (Get-CanonicalGitContext -RepoRoot $repo)
$canonicalLock = Enter-CanonicalRepoLock -LockPath ([string] $contractPaths.LockPath) -AllowCreate
try {
    Write-SemanticDocument -Path ([string] $contractPaths.SetupStatePath) -Document $setupState
    Write-SemanticDocument -Path (Join-Path $controlBase (Join-Path 'canonical-roots' ($repoId + '.json'))) -Document ([System.Collections.IDictionary] $setupPayload.ExpectedRootClaim)
}
finally { Exit-CanonicalRepoLock -LockHandle $canonicalLock }
Assert ([string] (Get-CanonicalSetupStatus -RepoRoot $repo -ToolchainRoot $RepoRoot) -ceq 'canonical-ready') 'the task fixture canonical setup is accepted'

$taskScript = Join-Path $repo 'scripts/task-skills.ps1'
$entryScript = Join-Path $repo 'scripts/agent-dotfiles.ps1'
$authorityScript = Join-Path $RepoRoot 'scripts/authority-harness-env.ps1'

# Establish the shared authority through the reviewed adopt transition: the
# task-overlay kind only ever runs on a machine that already has one, and the
# adopt path establishes the complete three-platform baseline in state 3.
$adoptPlan = Join-Path $sandbox 'adopt-plan.json'
$result = Invoke-TaskCli -ScriptPath $authorityScript -Arguments @('-Action', 'adopt', '-Name', 'work', '-RepoRoot', $repo, '-PlanPath', $adoptPlan, '-DryRun')
Assert ($result.Code -eq 0) 'the task fixture plans its first authority through adopt'
$result = Invoke-TaskCli -ScriptPath $authorityScript -Arguments @('-Action', 'adopt', '-Name', 'work', '-RepoRoot', $repo, '-PlanPath', $adoptPlan, '-Apply')
if ($result.Code -ne 0) { Write-Host '----- adopt apply output -----'; Write-Host $result.Out }
Assert ($result.Code -eq 0) 'the task fixture establishes its shared authority through adopt'
Assert (Test-Path -LiteralPath $statePath -PathType Leaf) 'the adopt transition publishes the shared authority state'
$stateDocument = Get-PlanDocument -Path $statePath
$stateTripleRows = @($stateDocument.TaskOverlaySkills)
Assert ($stateTripleRows.Count -eq 3) 'the committed state carries the frozen three-platform baseline triple'
foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
    $row = @($stateTripleRows | Where-Object { [string] $_['Platform'] -ceq $platform })
    Assert ($row.Count -eq 1) "the committed state carries the $platform task baseline row"
}

# --- status and the public gate surface ----------------------------------------
Write-Host 'task overlay: status and gate surface'
$result = Invoke-TaskCli -Direct -ScriptPath $taskScript -Arguments @('-Action', 'status', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot)
if ($result.Code -ne 0 -or $result.Out -notmatch 'three-platform baseline: COMPLETE') { Write-Host '----- status output -----'; Write-Host $result.Out }
Assert ($result.Code -eq 0 -and $result.Out -match 'three-platform baseline: COMPLETE') 'status accepts the committed three-platform baseline read-only'
$result = Invoke-TaskCli -Direct -ScriptPath $entryScript -Arguments @('env', 'task', 'ensure-skill', 'fixture-b', '-RepoRoot', $repo)
Assert ($result.Code -eq 1 -and $result.Out -match 'explicit -DryRun or -Apply') 'dispatcher rejects implicit task apply'
$result = Invoke-TaskCli -Direct -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-Apply', '-Automatic', '-PlanPath', (Join-Path $sandbox 'automatic-plan.json'))
if ($script:IsReleased) {
    Assert ($result.Code -ne 0 -and $result.Out -match 'task-overlay-automatic-removed') 'the removed -Automatic switch still fails closed at the public automatic-apply gate under the released policy'
}
else {
    Assert ($result.Code -ne 0 -and $result.Out -match 'safety-protocol-upgrade-required') 'the removed -Automatic switch still fails closed at the production interlock first'
}
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-Apply', '-Automatic', '-PlanPath', (Join-Path $sandbox 'automatic-plan.json'))
Assert ($result.Code -ne 0 -and $result.Out -match ('task-overlay-' + 'automatic-removed')) 'automatic task apply is deleted from the Apply routing'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-SkipBuild', '-PlanPath', (Join-Path $sandbox 'skip-plan.json'))
Assert ($result.Code -ne 0 -and $result.Out -match ('task-overlay-' + 'skip-switch-forbidden')) '-SkipBuild is refused as a public skip gate'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', (Join-Path $sandbox 'skip-plan.json'), '-TaskOverlayPath', (Join-Path $work 'other-overlay.psd1'))
Assert ($result.Code -ne 0 -and $result.Out -match ('task-overlay-' + 'path-unsupported')) 'a caller-selected overlay path is refused'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'ensure-skill', 'not-managed', '-Platform', 'Codex', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', (Join-Path $sandbox 'unmanaged-plan.json'))
if ($result.Code -eq 0 -or $result.Out -notmatch 'not managed') { Write-Host '----- unmanaged output -----'; Write-Host $result.Out }
Assert ($result.Code -ne 0 -and $result.Out -match 'not managed') 'unmanaged skill is rejected'

# --- the reviewed producer -----------------------------------------------------
Write-Host 'task overlay: Reasonix ensure preview'
$planPath = Join-Path $sandbox 'ensure-reasonix-plan.json'
$overlayBefore = Get-FileHashLower -Path $overlayPath
$stateBefore = Get-FileHashLower -Path $statePath
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'ensure-skill', 'fixture-b', '-Platform', 'Reasonix', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', $planPath)
if ($result.Code -ne 0) { Write-Host '----- ensure dry-run output -----'; Write-Host $result.Out }
Assert ($result.Code -eq 0) 'the Reasonix ensure preview produces its plan'
Assert ((Get-FileHashLower -Path $overlayPath) -eq $overlayBefore) 'the preview leaves the tracked overlay byte-identical'
Assert ((Get-FileHashLower -Path $statePath) -eq $stateBefore) 'the preview leaves the authority state byte-identical'
$planDocument = Get-PlanDocument -Path $planPath
$semanticsOk = $true
try { Test-LiveSyncPlanSemantics -Document ([System.Collections.IDictionary] $planDocument) }
catch { $semanticsOk = $false; Write-Host "  note  plan semantics: $($_.Exception.Message)" }
Assert $semanticsOk 'the task-overlay plan passes the frozen plan semantics'
Assert ([string] $planDocument.PlanPayload.OperationKind -ceq 'task-overlay') 'the plan is a task-overlay plan'
Assert ([string] $planDocument.PlanPayload.Generator -ceq 'scripts/task-skills.ps1') 'the plan names the task CLI as its generator'
Assert ([string] $planDocument.PlanPayload.EnvironmentName -ceq 'work') 'the plan carries the base environment name'
$evidence = $planDocument.PlanPayload.TaskOverlayEvidence
Assert ([string] $evidence.CurrentHash -ceq $overlayBefore) 'the plan binds the current tracked overlay hash'
Assert ([System.IO.Path]::GetFullPath([string] $evidence.CandidatePath) -ceq [System.IO.Path]::GetFullPath($overlayPath)) 'the plan binds the tracked overlay path as its target'
Assert ($evidence.RemovalReview -eq $false) 'an addition-only plan carries no removal review flag'
$planSchemaValidation = Test-RepositoryJsonSchema -SchemaPath (Join-Path $RepoRoot 'schemas/sync-plan.schema.json') -SchemaRoot (Join-Path $RepoRoot 'schemas')
$schemaOk = $true
try { $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $planSchemaValidation -InstanceBytes ([System.IO.File]::ReadAllBytes($planPath)) -InstancePath ('task-overlay-' + 'plan.emitted.json') }
catch { $schemaOk = $false; Write-Host "  note  plan schema: $($_.Exception.Message)" }
Assert $schemaOk 'the emitted plan validates against the sync-plan schema'
$candidateArtifact = Join-Path $sandbox 'ensure-reasonix-plan.candidate.psd1'
Assert (Test-Path -LiteralPath $candidateArtifact -PathType Leaf) 'the preview writes the exact candidate artifact next to the plan'

# --- changed overlay after the preview ----------------------------------------
Write-Host 'task overlay: changed overlay after the preview'
Set-File -Path $overlayPath -Content (New-OverlayText -Codex @('fixture-c'))
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'ensure-skill', 'fixture-b', '-Platform', 'Reasonix', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-Apply', '-PlanPath', $planPath)
Assert ($result.Code -ne 0 -and $result.Out -match ('task-overlay-' + 'current-mismatch')) 'a tracked overlay changed after the preview is refused before mutation'
Assert ((Get-FileHashLower -Path $statePath) -eq $stateBefore) 'the refused apply leaves the authority state unchanged'
Set-File -Path $overlayPath -Content (New-OverlayText)
Assert ((Get-FileHashLower -Path $overlayPath) -eq $overlayBefore) 'the fixture restores the reviewed overlay bytes'

# --- private artifact path -----------------------------------------------------
Write-Host 'task overlay: private artifact paths'
$insideRepoPlan = Join-Path $repo 'inside-plan.json'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', $insideRepoPlan)
if ($result.Code -eq 0 -or $result.Out -notmatch 'disjoint from worktree') { Write-Host '----- inside-repo plan output -----'; Write-Host $result.Out }
Assert ($result.Code -ne 0 -and $result.Out -match 'disjoint from worktree') 'a plan inside the worktree is refused'
Assert (-not (Test-Path -LiteralPath $insideRepoPlan)) 'the refused plan path writes nothing'

# --- the reviewed consumer -----------------------------------------------------
Write-Host 'task overlay: reviewed apply of the Reasonix addition'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'ensure-skill', 'fixture-b', '-Platform', 'Reasonix', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-Apply', '-PlanPath', $planPath)
if ($result.Code -ne 0) { Write-Host '----- ensure apply output -----'; Write-Host $result.Out }
Assert ($result.Code -eq 0) 'the reviewed plan applies through the live transaction host'
$candidateHash = Get-FileHashLower -Path $candidateArtifact
Assert ((Get-FileHashLower -Path $overlayPath) -eq $candidateHash) 'the tracked overlay carries the reviewed candidate bytes'
$appliedOverlay = Get-Content -Raw -LiteralPath $overlayPath
Assert ($appliedOverlay -match "Reasonix = @\('fixture-b'\)") 'the applied overlay records the Reasonix addition'
Assert (Test-Path -LiteralPath (Join-Path $fakeHome 'AppData/Roaming/reasonix/skills/fixture-b/SKILL.md')) 'the Reasonix live skill was staged from the materialization'
Assert (Test-Path -LiteralPath $systemSentinel) 'the Codex .system sentinel survived the apply'
$stateAfterApply = Get-PlanDocument -Path $statePath
Assert ([string] $stateAfterApply.TaskOverlayHash -ceq $candidateHash) 'the committed state binds the applied overlay hash'
$appliedReasonixRow = @(@($stateAfterApply.TaskOverlaySkills) | Where-Object { [string] $_['Platform'] -ceq 'Reasonix' })[0]
Assert (@($appliedReasonixRow['Skills']) -ccontains 'fixture-b') 'the committed state records the Reasonix baseline addition'
Assert ([string] $stateAfterApply.EnvironmentName -ceq 'work') 'the applied state keeps its environment selection'
$stateBytesHashAfterApply = Get-FileHashLower -Path $statePath

Write-Host 'task overlay: replay, consumption, and the journal'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'ensure-skill', 'fixture-b', '-Platform', 'Reasonix', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-Apply', '-PlanPath', $planPath)
if ($result.Code -eq 0 -or $result.Out -notmatch 'live-plan-consumed') { Write-Host '----- replay output -----'; Write-Host $result.Out }
Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-consumed') 'a consumed plan can never be replayed'
Assert ((Get-FileHashLower -Path $statePath) -eq $stateBytesHashAfterApply) 'the replayed plan changes nothing'
$journalDirs = @(Get-ChildItem -LiteralPath ([string] $authorityContext.LiveTransactionsRoot) -Directory -Force | Sort-Object LastWriteTimeUtc)
$journalDir = $journalDirs[-1].FullName
$journalHeader = Get-PlanDocument -Path (Join-Path $journalDir 'header.json')
Assert ([string] $journalHeader.OperationKind -ceq 'task-overlay') 'the journal header records the task-overlay kind'
$expectedOverlayKey = Get-WorktreeOverlayLockKey -LockPath (Get-WorktreeOverlayLockPath -GitContext (Get-CanonicalGitContext -RepoRoot $repo))
Assert ([string] $journalHeader.WorktreeOverlayLockKey -ceq $expectedOverlayKey) 'the header binds the exact worktree overlay lock identity'
$records = Get-JournalRecords -TransactionDirectory $journalDir
$phases = @($records | ForEach-Object { [string] $_['Phase'] })
$overlayPhases = @('FILE_PREPARED', 'FILE_REPLACE_INTENT', 'FILE_REPLACED')
foreach ($phase in $overlayPhases) {
    Assert ($phases -ccontains $phase) "the journal carries the overlay file target record $phase"
}
$filePrepared = @($records | Where-Object { [string] $_['Phase'] -ceq 'FILE_PREPARED' -and [System.IO.Path]::GetFullPath([string] $_['Data']['TargetPath']) -ceq [System.IO.Path]::GetFullPath($overlayPath) })
Assert ($filePrepared.Count -eq 1) 'exactly one FILE_PREPARED record names the tracked overlay'
Assert ([string] $filePrepared[0]['Data']['StagedState']['Hash'] -ceq $overlayBefore) 'the FILE_PREPARED record binds the immutable overlay preimage'
$fileReplaced = @($records | Where-Object { [string] $_['Phase'] -ceq 'FILE_REPLACED' -and [System.IO.Path]::GetFullPath([string] $_['Data']['TargetPath']) -ceq [System.IO.Path]::GetFullPath($overlayPath) })
Assert ($fileReplaced.Count -eq 1 -and [string] $fileReplaced[0]['Data']['TargetState']['Hash'] -ceq $candidateHash) 'the FILE_REPLACED record binds the installed overlay bytes'
Assert (Test-Path -LiteralPath ([string] $filePrepared[0]['Data']['StagedPath']) -PathType Leaf) 'the immutable preimage copy is retained'
Assert (Test-Path -LiteralPath ([string] $filePrepared[0]['Data']['SwapOldPath']) -PathType Leaf) 'the swap-old evidence is retained'

# --- close and removal detection ----------------------------------------------
Write-Host 'task overlay: close detects the removal'
$closePlan = Join-Path $sandbox 'close-plan.json'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'close', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', $closePlan)
if ($result.Code -ne 0) { Write-Host '----- close dry-run output -----'; Write-Host $result.Out }
Assert ($result.Code -eq 0) 'the close preview produces its plan'
$closeDocument = Get-PlanDocument -Path $closePlan
Assert ([bool] $closeDocument.PlanPayload.TaskOverlayEvidence.RemovalReview) 'the close plan requires removal review'
$pruneActions = @($closeDocument.PlanPayload.OrderedActions | Where-Object { [string] $_['Action'] -ceq 'prune' })
Assert ($pruneActions.Count -eq 1 -and [string] $pruneActions[0]['Platform'] -ceq 'Reasonix' -and [string] $pruneActions[0]['Name'] -ceq 'fixture-b') 'the close plan prunes the committed Reasonix addition'
Assert ([string] $pruneActions[0]['Authority'] -ceq 'managed-manifest') 'the prune row names the managed-manifest authority'
Assert ((Get-FileHashLower -Path $overlayPath) -eq $candidateHash) 'the close preview leaves the tracked overlay unchanged'

# --- stale materialization and replayed candidate -----------------------------
Write-Host 'task overlay: stale materialization and failed candidate staging'
$stalePlan = Join-Path $sandbox 'stale-plan.json'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', $stalePlan)
Assert ($result.Code -eq 0) 'the sync preview produces its plan'
$staleMaterialization = Get-LiveSyncMaterializationPath -PlanPath $stalePlan
$staleLockPath = Join-Path $staleMaterialization 'env.lock.json'
Set-File -Path $staleLockPath -Content '{"broken":true}'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-Apply', '-PlanPath', $stalePlan)
Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-hash-mismatch') 'a materialization rewritten after the preview is refused'
Assert ((Get-FileHashLower -Path $statePath) -eq $stateBytesHashAfterApply) 'the stale-materialization refusal changes no state'

$missingCandidatePlan = Join-Path $sandbox 'missing-candidate-plan.json'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', $missingCandidatePlan)
Assert ($result.Code -eq 0) 'the missing-candidate case plans a fresh sync'
Remove-Item -LiteralPath (Join-Path $sandbox 'missing-candidate-plan.candidate.psd1') -Force
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-Apply', '-PlanPath', $missingCandidatePlan)
if ($result.Code -eq 0 -or $result.Out -notmatch ('task-overlay-' + 'candidate-mismatch')) { Write-Host '----- missing-candidate apply output -----'; Write-Host $result.Out }
Assert ($result.Code -ne 0 -and $result.Out -match ('task-overlay-' + 'candidate-mismatch')) 'a missing candidate artifact is refused (the overlay file is never rewritten from memory)'
Assert ((Get-FileHashLower -Path $statePath) -eq $stateBytesHashAfterApply) 'the missing-candidate refusal changes no state'

# --- hard kill after the overlay replace, before FILE_REPLACED -----------------
Write-Host 'task overlay: hard kill between the overlay replace and FILE_REPLACED'
$killPlan = Join-Path $sandbox 'kill-plan.json'
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'close', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', $killPlan)
Assert ($result.Code -eq 0) 'the kill case plans a fresh close'
$killOverlayBefore = Get-FileHashLower -Path $overlayPath
$killStateBefore = Get-FileHashLower -Path $statePath
$killController = New-FailpointController
$killSuffix = [Guid]::NewGuid().ToString('N')
$killOutFile = Join-Path $work "task-kill-out-$killSuffix.txt"
$killErrFile = Join-Path $work "task-kill-err-$killSuffix.txt"
$killHostScript = Join-Path $RepoRoot 'scripts/internal/live-transaction-host.ps1'
$killEncoded = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject @(@('-Action', 'close', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-Apply', '-PlanPath', $killPlan)) -Compress)))
$killChild = $null
$savedFailpoints = [System.Environment]::GetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS')
try {
    [System.Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS', (ConvertTo-Json -InputObject @([ordered]@{ Checkpoint = 'FILE_REPLACED'; PipeName = $killController.Name }) -Compress))
    $killChild = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $killHostScript, '-SandboxRoot', $sandbox, '-ScriptPath', $taskScript, '-ArgumentsBase64', $killEncoded) -PassThru -WindowStyle Hidden -RedirectStandardOutput $killOutFile -RedirectStandardError $killErrFile
    Wait-FailpointController -Controller $killController -ExpectedCheckpoint 'FILE_REPLACED' -TimeoutSeconds 240
    if ($killChild.HasExited) { throw 'the task host exited before the overlay-replace kill' }
    Stop-FailpointProcessTree -Process $killChild
    $null = $killChild.WaitForExit(60000)
}
finally {
    [System.Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS', $savedFailpoints)
    if ($null -ne $killChild -and -not $killChild.HasExited) { Stop-FailpointProcessTree -Process $killChild }
    Close-FailpointController -Controller $killController
}
Assert ($killChild.ExitCode -ne 0) 'the overlay-replace window kills the task host'
Assert ((Get-FileHashLower -Path $statePath) -eq $killStateBefore) 'the killed overlay replace leaves the authority state byte-identical'
Assert ((Get-FileHashLower -Path $overlayPath) -ne $killOverlayBefore) 'the killed overlay replace leaves the candidate bytes on disk'
Assert (Test-Path -LiteralPath $systemSentinel) 'the killed overlay replace leaves Codex .system untouched'
$killJournalDirs = @(Get-ChildItem -LiteralPath ([string] $authorityContext.LiveTransactionsRoot) -Directory -Force | Sort-Object LastWriteTimeUtc)
$killJournalDir = $killJournalDirs[-1].FullName
$killRecords = Get-JournalRecords -TransactionDirectory $killJournalDir
$killPhases = @($killRecords | ForEach-Object { [string] $_['Phase'] })
Assert ($killPhases -ccontains 'FILE_REPLACE_INTENT') 'the killed overlay replace records the replace intent'
Assert ($killPhases -cnotcontains 'FILE_REPLACED') 'the killed overlay replace never records FILE_REPLACED'
Assert (-not (Test-Path -LiteralPath (Join-Path $killJournalDir 'result.json') -PathType Leaf)) 'the killed overlay replace publishes no result'
# The killed transaction's own plan is still unconsumed: re-applying it must be
# refused before any mutation — the tracked file no longer carries the bytes the
# plan reviewed (the kill left the candidate installed), or the unfinished
# journal blocks the host — and a fresh preview is refused while the journal is
# unfinished.
$result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'close', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-Apply', '-PlanPath', $killPlan)
if ($result.Code -eq 0 -or ($result.Out -notmatch ('task-overlay-' + 'current-mismatch') -and $result.Out -notmatch 'live-recovery-required')) { Write-Host '----- blocked apply output -----'; Write-Host $result.Out }
Assert ($result.Code -ne 0 -and ($result.Out -match ('task-overlay-' + 'current-mismatch') -or $result.Out -match 'live-recovery-required')) 'the killed overlay replace blocks the next task apply before any mutation'
$blockedPlan = Join-Path $sandbox 'blocked-by-unfinished-plan.json'
$blockedDryRun = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', $blockedPlan)
Assert ($blockedDryRun.Code -ne 0 -and -not (Test-Path -LiteralPath $blockedPlan)) 'the unfinished overlay transaction blocks the next task preview'
$overlayAfterKill = Get-FileHashLower -Path $overlayPath

Write-Host 'task overlay: recovery dispatch from another worktree'
$recoveryScript = Join-Path $RepoRoot 'scripts/recover-live-transaction.ps1'
$killTransactionId = Split-Path -Leaf $killJournalDir
$linkedRoot = Join-Path $work 'linked'
& git -C $repo worktree add -b linked-overlay $linkedRoot --quiet 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $linkedRepo = (Resolve-Path -LiteralPath $linkedRoot).Path
    $linkedPlan = Join-Path $sandbox 'linked-recovery-plan.json'
    $result = Invoke-TaskCli -ScriptPath $recoveryScript -Arguments @('-Action', 'rollback', '-TransactionId', $killTransactionId, '-DryRun', '-PlanPath', $linkedPlan, '-RepoRoot', $linkedRepo)
    Assert ($result.Code -ne 0 -and $result.Out -match 'manual-recovery-required') 'a recovery dispatch from a linked worktree fails closed on the overlay lock identity'
    Assert (-not (Test-Path -LiteralPath $linkedPlan)) 'the foreign-worktree dispatch writes no plan'
    $rollbackPlan = Join-Path $sandbox 'origin-recovery-plan.json'
    $result = Invoke-TaskCli -ScriptPath $recoveryScript -Arguments @('-Action', 'rollback', '-TransactionId', $killTransactionId, '-DryRun', '-PlanPath', $rollbackPlan, '-RepoRoot', $repo)
    if ($result.Code -ne 0) { Write-Host '----- overlay rollback dry-run output -----'; Write-Host $result.Out }
    Assert ($result.Code -eq 0) 'the origin worktree derives the reviewed overlay rollback plan'
    $rollbackDocument = Get-PlanDocument -Path $rollbackPlan
    Assert ([string] $rollbackDocument.PlanPayload.OverlayLockKey -ceq $expectedOverlayKey) 'the rollback plan binds the worktree overlay lock identity'
    $overlayTargetRow = @($rollbackDocument.PlanPayload.Targets | Where-Object { [System.IO.Path]::GetFullPath([string] $_['TargetPath']) -ceq [System.IO.Path]::GetFullPath($overlayPath) })
    Assert ($overlayTargetRow.Count -eq 1) 'the rollback plan binds exactly one tracked-overlay target row'
    Assert ([string] $overlayTargetRow[0]['Current']['Hash'] -ceq $killOverlayBefore) 'the overlay target row binds the journal preimage'
    Assert (Test-Path -LiteralPath ([string] $overlayTargetRow[0]['PreimagePath']) -PathType Leaf) 'the overlay target row binds an existing immutable preimage copy'
    Assert ((Get-PathSha256 -Path ([string] $overlayTargetRow[0]['PreimagePath']).Trim()) -ceq $killOverlayBefore) 'the bound preimage copy reproduces the reviewed overlay bytes'
    Assert ([string] $overlayTargetRow[0]['SwapOldPath'] -match [regex]::Escape($killTransactionId)) 'the overlay target row binds the transaction swap-old locator'
    Assert ([string] $overlayTargetRow[0]['Candidate']['Hash'] -ceq $killOverlayBefore) 'an unreplaced overlay target row declares the journal preimage as its binding'
    $result = Invoke-TaskCli -ScriptPath $recoveryScript -Arguments @('-Action', 'rollback', '-TransactionId', $killTransactionId, '-Apply', '-PlanPath', $rollbackPlan, '-RepoRoot', $repo)
    if ($result.Code -ne 0) { Write-Host '----- overlay rollback apply output -----'; Write-Host $result.Out }
    Assert ($result.Code -eq 0) 'the reviewed overlay rollback applies'
    Assert ((Get-FileHashLower -Path $overlayPath) -eq $killOverlayBefore) 'the rollback restores the tracked overlay preimage bytes'
    Assert ((Test-Path -LiteralPath (Join-Path $fakeHome 'AppData/Roaming/reasonix/skills/fixture-b/SKILL.md'))) 'the rollback leaves the previously committed live skill in place'
}
else {
    Assert $false 'the linked worktree fixture could not be created'
}

# --- zero/bounded live-lock wait ------------------------------------------------
Write-Host 'task overlay: zero-wait lock sentinels'
$overlayLockPath = Get-WorktreeOverlayLockPath -GitContext (Get-CanonicalGitContext -RepoRoot $repo)
$held = Enter-CanonicalRepoLock -LockPath $overlayLockPath -AllowCreate
try {
    $busy = $false
    try { $second = Enter-CanonicalRepoLock -LockPath $overlayLockPath -AllowCreate; Exit-CanonicalRepoLock -LockHandle $second }
    catch { $busy = ([string] $_.Exception.Message -eq 'operation-lock-busy') }
    Assert $busy 'a second overlay lock holder loses with an exact zero-wait operation-lock-busy'
    $result = Invoke-TaskCli -ScriptPath $recoveryScript -Arguments @('-Status')
    Assert ($result.Code -eq 0) 'the read-only recovery scan does not take the overlay lock'
    Assert ($result.Out -notmatch 'operation-lock-busy') 'the read-only recovery scan reports while the overlay lock is held'
    $syncPlan = Join-Path $sandbox 'lock-order-plan.json'
    $result = Invoke-TaskCli -ScriptPath $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $repo, '-HomeRoot', $fakeHome, '-ControlBase', $controlBase, '-BackupRoot', $backupRoot, '-DryRun', '-PlanPath', $syncPlan)
    Assert ($result.Out -notmatch 'operation-lock-busy') 'a preview neither takes nor waits for the worktree overlay lock'
    $result = Invoke-TaskCli -ScriptPath $recoveryScript -Arguments @('-Action', 'rollback', '-TransactionId', $killTransactionId, '-DryRun', '-PlanPath', (Join-Path $sandbox 'busy-recovery-plan.json'), '-RepoRoot', $repo)
    Assert ($result.Code -ne 0 -and $result.Out -match 'operation-lock-busy') 'a busy overlay lock fails the recovery dispatch closed with zero wait'
    Assert (-not (Test-Path -LiteralPath (Join-Path $sandbox 'busy-recovery-plan.json'))) 'the busy-lock dispatch writes no plan'
    Assert ((Get-FileHashLower -Path $overlayPath) -eq $killOverlayBefore) 'the busy-lock refusals change no overlay bytes'
}
finally { Exit-CanonicalRepoLock -LockHandle $held }

Write-Host ''
Write-Host ("task-skills tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) {
    Write-Host "Workspace kept for inspection: $work"
    exit 1
}
Remove-Work
exit 0
