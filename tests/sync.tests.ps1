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

function Invoke-Sync {
    param([string[]] $Arguments)
    $output = @(& pwsh -NoProfile -File $syncScript @Arguments 2>&1)
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($output -join "`n") }
}

try {
    New-Item -ItemType Directory -Force -Path $fakeRepo, $fakeHome, $fakeBackups | Out-Null
    foreach ($dir in @('claude/skills/demo', 'codex/skills/demo', 'opencode/skills/demo', 'manifests')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $fakeRepo $dir) | Out-Null
    }
    foreach ($dir in @('.claude/skills/demo', '.codex/skills/demo', '.codex/skills/.system', '.config/opencode/skills/demo', '.claude/skills/unknown-local')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome $dir) | Out-Null
    }

    $skill = "---`nname: demo`ndescription: Sync fixture`n---`n`n# Demo`n"
    foreach ($platform in @('claude', 'codex', 'opencode')) {
        Write-TextFile -Path (Join-Path $fakeRepo "$platform/skills/demo/SKILL.md") -Content $skill
    }
    foreach ($platform in @('.claude', '.codex', '.config/opencode')) {
        Write-TextFile -Path (Join-Path $fakeHome "$platform/skills/demo/SKILL.md") -Content $skill
    }
    Write-TextFile -Path (Join-Path $fakeHome '.codex/skills/.system/.codex-system-skills.marker') -Content 'system-sentinel'
    Write-TextFile -Path (Join-Path $fakeHome '.claude/skills/unknown-local/SKILL.md') -Content 'unknown-sentinel'
    foreach ($manifest in @('managed-skills.claude.txt', 'managed-skills.codex.txt', 'managed-skills.opencode.txt')) {
        Write-TextFile -Path (Join-Path $fakeRepo "manifests/$manifest") -Content "demo`n"
    }

    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-Apply')
    Assert ($result.Code -ne 0 -and $result.Out -match 'requires a reviewed.*PlanPath') 'apply requires a reviewed dry-run plan'

    Write-Host '[content-aware dry-run]'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-BackupRoot', $fakeBackups, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $planPath)
    Assert ($result.Code -eq 0) 'dry-run exits successfully'
    Assert ($result.Out -match 'Claude\s*: \+0 ~0 =1 -0') 'identical Claude skill is reported as no-op'
    Assert ($result.Out -match 'OpenCode\s*: \+0 ~0 =1 -0') 'identical OpenCode skill is reported as no-op'
    Assert ($result.Out -match 'Plan hash\s*: [0-9a-f]{64}') 'dry-run reports a plan hash'
    Assert (Test-Path -LiteralPath $planPath) 'dry-run writes a plan file'
    $plan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json
    Assert ([int] $plan.SchemaVersion -eq 1) 'plan schema version is 1'
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
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $fakeHome '.config/opencode/skills/demo/SKILL.md')) -eq $skill) 'OpenCode skill content is restored by apply'
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

    Write-Host 'sync tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
