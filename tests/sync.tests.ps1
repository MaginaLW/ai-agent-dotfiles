#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$syncScript = Join-Path $RepoRoot 'scripts/sync.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-sync-tests-$([Guid]::NewGuid().ToString('N'))"
$fakeRepo = Join-Path $work 'repo'
$fakeHome = Join-Path $work 'home'
$fakeBackups = Join-Path $work 'backups'
$planPath = Join-Path $work 'sync-plan.json'
. (Join-Path $PSScriptRoot 'helpers/safety-sandbox.ps1')

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

function Write-TextFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-RetirementManifest {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string[]] $Claude = @(),
        [string[]] $Codex = @(),
        [string[]] $Reasonix = @()
    )
    $document = [ordered]@{
        SchemaVersion = 1
        Claude = @($Claude)
        Codex = @($Codex)
        Reasonix = @($Reasonix)
    }
    Write-TextFile -Path $Path -Content ((ConvertTo-Json -InputObject $document -Depth 5) + "`n")
}

function Invoke-Sync {
    param([string[]] $Arguments)
    return Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $syncScript -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
}

try {
    New-Item -ItemType Directory -Force -Path $fakeRepo, $fakeHome, $fakeBackups | Out-Null
    foreach ($dir in @('claude/skills/demo', 'codex/skills/demo', 'reasonix/skills/demo', 'manifests')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $fakeRepo $dir) | Out-Null
    }
    foreach ($dir in @('.claude/skills/demo', '.codex/skills/demo', '.codex/skills/.system', 'AppData/Roaming/reasonix/skills/demo', '.claude/skills/unknown-local')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome $dir) | Out-Null
    }

    $skill = "---`nname: demo`ndescription: Sync fixture`n---`n`n# Demo`n"
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        Write-TextFile -Path (Join-Path $fakeRepo "$platform/skills/demo/SKILL.md") -Content $skill
    }
    foreach ($platform in @('.claude', '.codex', 'AppData/Roaming/reasonix')) {
        Write-TextFile -Path (Join-Path $fakeHome "$platform/skills/demo/SKILL.md") -Content $skill
    }
    Write-TextFile -Path (Join-Path $fakeHome '.codex/skills/.system/.codex-system-skills.marker') -Content 'system-sentinel'
    Write-TextFile -Path (Join-Path $fakeHome '.claude/skills/unknown-local/SKILL.md') -Content 'unknown-sentinel'
    foreach ($manifest in @('managed-skills.claude.txt', 'managed-skills.codex.txt', 'managed-skills.reasonix.txt')) {
        Write-TextFile -Path (Join-Path $fakeRepo "manifests/$manifest") -Content "demo`n"
    }

    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply')
    Assert ($result.Code -ne 0 -and $result.Out -match 'requires a reviewed.*PlanPath') 'apply requires a reviewed dry-run plan'

    Write-Host '[content-aware dry-run]'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $planPath)
    Assert ($result.Code -eq 0) 'dry-run exits successfully'
    Assert ($result.Out -match 'Claude\s*: \+0 ~0 =1 -0') 'identical Claude skill is reported as no-op'
    Assert ($result.Out -match 'Reasonix\s*: \+0 ~0 =1 -0') 'identical Reasonix skill is reported as no-op'
    Assert ($result.Out -match 'Plan hash\s*: [0-9a-f]{64}') 'dry-run reports a plan hash'
    Assert (Test-Path -LiteralPath $planPath) 'dry-run writes a plan file'
    $plan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json
    Assert ([int] $plan.SchemaVersion -eq 2) 'plan schema version is 2'
    Assert ([string] $plan.PlanHash -match '^[0-9a-f]{64}$') 'plan contains a SHA-256 fingerprint'
    Assert (@($plan.Plans[0].NoOp).Count -eq 1) 'plan records unchanged skill hashes'

    Write-TextFile -Path (Join-Path $fakeHome '.claude/skills/demo/SKILL.md') -Content ($skill + "changed`n")
    $changedPlan = Join-Path $work 'changed-plan.json'
    Write-Host '[plan drift gate]'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $changedPlan)
    Assert ($result.Code -eq 0) 'changed dry-run exits successfully'
    Assert ($result.Out -match 'Claude\s*: \+0 ~1 =0 -0') 'changed Claude skill is reported as update'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $planPath)
    Assert ($result.Code -ne 0 -and $result.Out -match 'plan drift') 'apply rejects a stale reviewed plan before backup'
    Assert (@(Get-ChildItem -LiteralPath $fakeBackups -Force -ErrorAction SilentlyContinue).Count -eq 0) 'stale plan rejection creates no backup'

    Write-Host '[transactional apply]'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $changedPlan)
    Assert ($result.Code -eq 0) 'apply with current plan exits successfully'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $fakeHome '.claude/skills/demo/SKILL.md')) -eq $skill) 'apply restores source content'
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.codex/skills/.system/.codex-system-skills.marker')) '.system sentinel survives apply'
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/unknown-local/SKILL.md')) 'unknown live skill survives apply'
    $journal = @(Get-ChildItem -LiteralPath $fakeBackups -Filter 'sync-journal.json' -File -Recurse)
    Assert ($journal.Count -gt 0) 'apply writes an external sync journal'
    $journalState = Get-Content -Raw -LiteralPath $journal[-1].FullName | ConvertFrom-Json
    Assert ($journalState.Status -eq 'complete') 'successful apply journal is complete'

    Write-Host '[manifest-scoped prune]'
    Remove-Item -LiteralPath (Join-Path $fakeRepo 'claude/skills/demo') -Recurse -Force
    $prunePlan = Join-Path $work 'prune-plan.json'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $prunePlan)
    Assert ($result.Code -eq 0 -and $result.Out -match 'Claude\s*: \+0 ~0 =0 -1') 'managed stale skill is planned for prune'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $prunePlan)
    Assert ($result.Code -eq 0) 'prune apply exits successfully'
    Assert (-not (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/demo'))) 'managed stale skill is pruned'
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/unknown-local')) 'unknown skill is not pruned'
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.codex/skills/.system')) '.system remains after prune'

    Write-Host '[explicit one-shot retirement]'
    $retirementManifest = Join-Path $work 'retire-skills.json'
    $retirementPlan = Join-Path $work 'retirement-plan.json'
    $retiredTargets = [ordered]@{
        Claude = Join-Path $fakeHome '.claude/skills/retired-claude'
        Codex = Join-Path $fakeHome '.codex/skills/retired-codex'
        Reasonix = Join-Path $fakeHome 'AppData/Roaming/reasonix/skills/retired-reasonix'
    }
    foreach ($target in $retiredTargets.Values) {
        Write-TextFile -Path (Join-Path $target 'SKILL.md') -Content "retired-sentinel`n"
    }

    $withoutRetirementPlan = Join-Path $work 'without-retirement-plan.json'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $withoutRetirementPlan)
    Assert ($result.Code -eq 0 -and $result.Out -match 'Claude\s*: \+0 ~0 =0 -0\s+\(unknown ignored: 2\)') 'retired name remains unknown without explicit retirement authority'
    Assert (Test-Path -LiteralPath $retiredTargets.Claude) 'dry-run without authority preserves retired candidate'

    Write-RetirementManifest -Path $retirementManifest -Codex @('.system')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'must never contain Codex \.system') 'retirement manifest rejects .system'

    Write-RetirementManifest -Path $retirementManifest -Claude @('../escape')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'safe bare identifier') 'retirement manifest rejects path-like names'

    Write-RetirementManifest -Path $retirementManifest -Codex @('demo')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match "cannot authorize active Codex source skill 'demo'") 'retirement manifest rejects an active source skill'

    $reasonixCanonicalOnly = Join-Path $fakeRepo 'skills-source/reasonix-only/canonical-reasonix-only'
    $reasonixCanonicalOnlyLive = Join-Path $fakeHome 'AppData/Roaming/reasonix/skills/canonical-reasonix-only'
    Write-TextFile -Path (Join-Path $reasonixCanonicalOnly 'SKILL.md') -Content "canonical-reasonix-only`n"
    Write-TextFile -Path (Join-Path $reasonixCanonicalOnlyLive 'SKILL.md') -Content "canonical-reasonix-only`n"
    Write-RetirementManifest -Path $retirementManifest -Reasonix @('canonical-reasonix-only')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match "cannot authorize canonical Reasonix skill 'canonical-reasonix-only'") 'retirement manifest rejects a Reasonix-only canonical skill even with stale generated output'
    Remove-Item -LiteralPath $reasonixCanonicalOnly, $reasonixCanonicalOnlyLive -Recurse -Force

    $authorityCanonicalLive = Join-Path $fakeHome '.claude/skills/brainstorming'
    Write-TextFile -Path (Join-Path $authorityCanonicalLive 'SKILL.md') -Content "staging-omitted-canonical`n"
    Write-RetirementManifest -Path $retirementManifest -Claude @('brainstorming')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match "cannot authorize canonical Claude skill 'brainstorming'") 'retirement checks the script repository canonical authority even when RepoRoot is staging or a fixture'
    Remove-Item -LiteralPath $authorityCanonicalLive -Recurse -Force

    $authorityInternalRetirementManifest = Join-Path $RepoRoot ".git/ai-agent-dotfiles/sync-test-retirement-$([Guid]::NewGuid().ToString('N')).json"
    try {
        Write-RetirementManifest -Path $authorityInternalRetirementManifest -Claude @('retired-claude')
        $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $authorityInternalRetirementManifest)
        Assert ($result.Code -ne 0 -and $result.Out -match 'must be external to the repository') 'retirement manifest must remain outside the script repository canonical authority when RepoRoot is staging'
    }
    finally {
        Remove-Item -LiteralPath $authorityInternalRetirementManifest -Force -ErrorAction SilentlyContinue
    }

    Write-RetirementManifest -Path $retirementManifest -Claude @('retired-claude') -Codex @('retired-codex') -Reasonix @('retired-reasonix')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'retirement-authorized dry-run exits successfully'
    Assert ($result.Out -match 'Claude\s*: \+0 ~0 =0 -1\s+\(unknown ignored: 1\)') 'Claude retirement is planned while unrelated unknown stays preserved'
    Assert ($result.Out -match 'Codex\s*: \+0 ~0 =1 -1') 'Codex retirement is planned alongside current no-op skill'
    Assert ($result.Out -match 'Reasonix\s*: \+0 ~0 =1 -1') 'Reasonix retirement is planned alongside current no-op skill'
    $retirementPlanDocument = Get-Content -Raw -LiteralPath $retirementPlan | ConvertFrom-Json
    Assert ([int] $retirementPlanDocument.SchemaVersion -eq 2) 'retirement plan uses schema version 2'
    $claudeRetirementPlan = @($retirementPlanDocument.Plans | Where-Object Platform -eq 'claude')[0]
    Assert ([string] $claudeRetirementPlan.RetirementManifestHash -match '^[0-9a-f]{64}$') 'plan binds retirement manifest bytes by SHA-256'
    Assert (@($claudeRetirementPlan.RetiredNames) -contains 'retired-claude') 'plan records platform retirement names'
    Assert ($claudeRetirementPlan.PruneEntries[0].Authority -eq 'explicit-retirement' -and -not [bool] $claudeRetirementPlan.PruneEntries[0].Managed) 'plan distinguishes explicit retirement from current manifest authority'
    Assert ([string] $claudeRetirementPlan.SourceRoot -match 'claude[\\/]skills$' -and [string] $claudeRetirementPlan.LiveRoot -match '\.claude[\\/]skills$') 'plan binds resolved source and live roots'
    Assert ([string] $claudeRetirementPlan.CanonicalAuthorityRoot -eq $RepoRoot) 'plan binds the non-overridable script repository canonical authority root'
    Assert ([string] $claudeRetirementPlan.CanonicalRetirementEvidenceHash -match '^[0-9a-f]{64}$') 'plan binds per-name canonical absence evidence'
    Assert ([string] $claudeRetirementPlan.RetirementManifestPath -eq (Resolve-Path -LiteralPath $retirementManifest).Path) 'plan binds the resolved retirement manifest path'

    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlan)
    Assert ($result.Code -ne 0 -and $result.Out -match 'plan drift') 'apply rejects a retirement plan when the retirement manifest is omitted'
    Assert ($result.Out -notmatch 'Backup complete') 'missing retirement authority is rejected before backup'

    $alternateRetirementManifest = Join-Path $work 'retire-skills-copy.json'
    Write-TextFile -Path $alternateRetirementManifest -Content (Get-Content -Raw -LiteralPath $retirementManifest)
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlan, '-RetireManifestPath', $alternateRetirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'plan drift') 'apply rejects identical retirement bytes supplied from a different path'
    Assert ($result.Out -notmatch 'Backup complete') 'retirement path drift is rejected before backup'

    $alternateReasonixRoot = Join-Path $work 'alternate-reasonix-skills'
    Copy-Item -LiteralPath (Join-Path $fakeHome 'AppData/Roaming/reasonix/skills') -Destination $alternateReasonixRoot -Recurse -Force
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ReasonixLiveSkillsPath', $alternateReasonixRoot, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'plan drift') 'apply rejects a reviewed plan against a different live root'
    Assert ($result.Out -notmatch 'Backup complete') 'live-root drift is rejected before backup'

    Write-TextFile -Path $retirementManifest -Content '{"SchemaVersion":1,"Claude":["retired-claude"],"Codex":["retired-codex"],"Reasonix":["retired-reasonix"]}'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'plan drift') 'apply rejects retirement manifest drift'
    Assert ($result.Out -notmatch 'Backup complete') 'retirement manifest drift is rejected before backup'
    Assert (Test-Path -LiteralPath $retiredTargets.Codex) 'drift rejection leaves retirement target untouched'

    Write-RetirementManifest -Path $retirementManifest -Claude @('retired-claude') -Codex @('retired-codex') -Reasonix @('retired-reasonix')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'final retirement dry-run refreshes the bound plan'

    $tamperedPlan = Get-Content -Raw -LiteralPath $retirementPlan | ConvertFrom-Json
    $tamperedPlan.Plans[0].Unknown = @()
    Write-TextFile -Path $retirementPlan -Content ((ConvertTo-Json -InputObject $tamperedPlan -Depth 30) + "`n")
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'plan self-check failed') 'apply rejects reviewed-plan content tampering even when PlanHash is unchanged'
    Assert ($result.Out -notmatch 'Backup complete') 'plan self-check failure occurs before backup'

    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'dry-run restores an untampered retirement plan'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'retirement apply exits successfully'
    foreach ($target in $retiredTargets.Values) {
        Assert (-not (Test-Path -LiteralPath $target)) "explicit retirement prunes $target"
    }
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/unknown-local')) 'explicit retirement still preserves unrelated unknown skill'
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.codex/skills/.system/.codex-system-skills.marker')) '.system sentinel survives explicit retirement'
    $retirementJournal = @(Get-ChildItem -LiteralPath $fakeBackups -Filter 'sync-journal.json' -File -Recurse | Sort-Object LastWriteTimeUtc)[-1]
    $retirementJournalState = Get-Content -Raw -LiteralPath $retirementJournal.FullName | ConvertFrom-Json
    Assert (@($retirementJournalState.Completed | Where-Object { $_.Action -eq 'prune' -and $_.Authority -eq 'explicit-retirement' }).Count -eq 3) 'sync journal records explicit retirement authority for each prune'

    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'must identify an existing unknown live skill directory') 'successful retirement cannot silently reuse the same authorization after targets are gone'

    Write-Host '[Reasonix override backup coverage]'
    $reasonixOverrideRoot = Join-Path $work 'reasonix-override-live'
    Write-TextFile -Path (Join-Path $reasonixOverrideRoot 'demo/SKILL.md') -Content $skill
    Write-TextFile -Path (Join-Path $reasonixOverrideRoot 'retired-reasonix-override/SKILL.md') -Content "override-retired-sentinel`n"
    $overrideBackupRoot = Join-Path $work 'override-backups'
    $overridePlan = Join-Path $work 'override-plan.json'
    Write-RetirementManifest -Path $retirementManifest -Reasonix @('retired-reasonix-override')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ReasonixLiveSkillsPath', $reasonixOverrideRoot, '-BackupRoot', $overrideBackupRoot, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $overridePlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'Reasonix override retirement dry-run exits successfully'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ReasonixLiveSkillsPath', $reasonixOverrideRoot, '-BackupRoot', $overrideBackupRoot, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $overridePlan, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'Reasonix override retirement apply exits successfully'
    Assert (-not (Test-Path -LiteralPath (Join-Path $reasonixOverrideRoot 'retired-reasonix-override'))) 'Reasonix override retirement target is pruned'
    $overrideBackup = @(Get-ChildItem -LiteralPath $overrideBackupRoot -Directory | Sort-Object LastWriteTimeUtc)[-1].FullName
    Assert (Test-Path -LiteralPath (Join-Path $overrideBackup 'reasonix-skills/retired-reasonix-override/SKILL.md')) 'mandatory backup contains the exact Reasonix override retirement target'

    Write-Host '[prune-time target verification]'
    $tokens = $null
    $parseErrors = $null
    $syncAst = [System.Management.Automation.Language.Parser]::ParseFile($syncScript, [ref] $tokens, [ref] $parseErrors)
    Assert ($parseErrors.Count -eq 0) 'sync script parses before function-level prune tests'
    foreach ($functionName in @('Assert-SafeLiveSkillTarget', 'Get-StringSha256', 'Get-SkillTreeHash', 'Remove-OneSkillDir')) {
        $functionAst = $syncAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
        Assert ($null -ne $functionAst) "sync script contains $functionName"
        $definition = [scriptblock]::Create($functionAst.Extent.Text)
        . $definition
    }
    $CodexSystemDirName = '.system'
    $removeUnitRoot = Join-Path $work 'remove-unit-live'
    New-Item -ItemType Directory -Force -Path $removeUnitRoot | Out-Null
    $reviewedHash = ('0' * 64) -join ''

    $missingRejected = $false
    try {
        Remove-OneSkillDir -LiveRoot $removeUnitRoot -Name 'missing-retired' -ExpectedHash $reviewedHash
    }
    catch {
        $missingRejected = $_.Exception.Message -match 'missing or non-directory'
    }
    Assert $missingRejected 'reviewed prune fails closed when the target disappeared after planning'

    Write-TextFile -Path (Join-Path $removeUnitRoot 'non-directory-retired') -Content "file-sentinel`n"
    $fileRejected = $false
    try {
        Remove-OneSkillDir -LiveRoot $removeUnitRoot -Name 'non-directory-retired' -ExpectedHash $reviewedHash
    }
    catch {
        $fileRejected = $_.Exception.Message -match 'missing or non-directory'
    }
    Assert $fileRejected 'reviewed prune fails closed when the target became a file after planning'

    $changedTarget = Join-Path $removeUnitRoot 'changed-retired'
    Write-TextFile -Path (Join-Path $changedTarget 'SKILL.md') -Content "changed-after-review`n"
    $changedRejected = $false
    try {
        Remove-OneSkillDir -LiveRoot $removeUnitRoot -Name 'changed-retired' -ExpectedHash $reviewedHash
    }
    catch {
        $changedRejected = $_.Exception.Message -match 'Refusing to prune changed skill'
    }
    Assert $changedRejected 'reviewed prune recomputes the moved target tree hash before deletion'
    Assert (Test-Path -LiteralPath (Join-Path $changedTarget 'SKILL.md')) 'hash-mismatch prune restores the original target directory'
    Assert (@(Get-ChildItem -LiteralPath $removeUnitRoot -Directory -Filter '.ai-agent-dotfiles-prune-*').Count -eq 0) 'hash-mismatch prune leaves no rollback directory behind'

    Write-Host 'sync tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
