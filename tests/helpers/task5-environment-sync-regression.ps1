#requires -Version 7.0

<#
.SYNOPSIS
    Preserved content-aware environment sync regression for Task 5.

.DESCRIPTION
    This helper preserves the content-aware sync regression that Phase 2 Task 2
    (schema 3 semantic plan contract, adopted design alternative F) extracted
    out of tests/sync.tests.ps1: identical managed skills are no-ops, changed
    skills plan updates, the reviewed plan drift gate runs before any backup,
    transactional apply restores source content, and manifest-scoped pruning
    removes only authorized stale skills while unknown live skills and Codex
    .system survive.

    tests/sync.tests.ps1 must NOT dot-source or invoke this file. The current
    public sync surface deliberately produces only pristine-initial and
    explicit-retirement schema 3 plans
    (task2-pristine-initial-only-pending-environment-producer); Task 5's
    `environment` producer re-wires this regression against its own producer
    and updates the plan-document assertions to that producer's schema 3
    OperationKind before calling it.
#>

Set-StrictMode -Version Latest

function Invoke-Task5EnvironmentSyncRegression {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FixtureRepo,
        [Parameter(Mandatory)] [string] $FixtureHome,
        [Parameter(Mandatory)] [string] $FixtureBackups,
        [Parameter(Mandatory)] [string] $WorkRoot,
        [Parameter(Mandatory)] [string] $SyncScript,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $PlanSchemaPath
    )

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

    . (Join-Path $RepoRoot 'tests/helpers/safety-sandbox.ps1')

    function Invoke-Sync {
        param([string[]] $Arguments)
        return Invoke-SafetySandboxScript -SandboxRoot $WorkRoot -ScriptPath $SyncScript -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
    }

    $skill = "---`nname: demo`ndescription: Sync fixture`n---`n`n# Demo`n"
    $planPath = Join-Path $WorkRoot 'task5-environment-plan.json'

    Write-Host '[task5 environment regression: content-aware dry-run]'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $FixtureRepo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $planPath)
    Assert ($result.Code -eq 0) 'dry-run exits successfully'
    Assert ($result.Out -match 'Claude\s*: \+0 ~0 =1 -0') 'identical Claude skill is reported as no-op'
    Assert ($result.Out -match 'Reasonix\s*: \+0 ~0 =1 -0') 'identical Reasonix skill is reported as no-op'
    Assert (Test-Path -LiteralPath $planPath) 'dry-run writes a plan file'
    $plan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json
    Assert ($plan.SchemaVersion -ge 3) 'plan uses the current schema family'
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $PlanSchemaPath -InstancePath $planPath
    Assert $true 'plan passes the pinned sync-plan schema'

    Write-TextFile -Path (Join-Path $FixtureHome '.claude/skills/demo/SKILL.md') -Content ($skill + "changed`n")
    $changedPlan = Join-Path $WorkRoot 'task5-environment-changed-plan.json'
    Write-Host '[task5 environment regression: plan drift gate]'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $FixtureRepo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $changedPlan)
    Assert ($result.Code -eq 0) 'changed dry-run exits successfully'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $FixtureRepo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $planPath)
    Assert ($result.Code -ne 0) 'apply rejects a stale reviewed plan before backup'
    Assert (@(Get-ChildItem -LiteralPath $FixtureBackups -Force -ErrorAction SilentlyContinue).Count -eq 0) 'stale plan rejection creates no backup'

    Write-Host '[task5 environment regression: transactional apply]'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $FixtureRepo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $changedPlan)
    Assert ($result.Code -eq 0) 'apply with current plan exits successfully'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $FixtureHome '.claude/skills/demo/SKILL.md')) -eq $skill) 'apply restores source content'
    Assert (Test-Path -LiteralPath (Join-Path $FixtureHome '.codex/skills/.system/.codex-system-skills.marker')) '.system sentinel survives apply'
    $journal = @(Get-ChildItem -LiteralPath $FixtureBackups -Filter 'sync-journal.json' -File -Recurse)
    Assert ($journal.Count -gt 0) 'apply writes an external sync journal'
    $journalState = Get-Content -Raw -LiteralPath $journal[-1].FullName | ConvertFrom-Json
    Assert ($journalState.Status -eq 'complete') 'successful apply journal is complete'

    Write-Host '[task5 environment regression: manifest-scoped prune]'
    Remove-Item -LiteralPath (Join-Path $FixtureRepo 'claude/skills/demo') -Recurse -Force
    $prunePlan = Join-Path $WorkRoot 'task5-environment-prune-plan.json'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $FixtureRepo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $prunePlan)
    Assert ($result.Code -eq 0 -and $result.Out -match 'Claude\s*: \+0 ~0 =0 -1') 'managed stale skill is planned for prune'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $FixtureRepo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $prunePlan)
    Assert ($result.Code -eq 0) 'prune apply exits successfully'
    Assert (-not (Test-Path -LiteralPath (Join-Path $FixtureHome '.claude/skills/demo'))) 'managed stale skill is pruned'
    Assert (Test-Path -LiteralPath (Join-Path $FixtureHome '.claude/skills/unknown-local')) 'unknown skill is not pruned'
    Assert (Test-Path -LiteralPath (Join-Path $FixtureHome '.codex/skills/.system')) '.system remains after prune'

    Write-Host 'task5 environment sync regression: PASS'
}
