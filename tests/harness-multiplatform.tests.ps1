#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$pass = 0
$fail = 0
function Assert([bool] $Condition, [string] $Message) {
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Message" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}

$work = Join-Path $RepoRoot 'tmp/harness-multiplatform-tests'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Set-FixtureFile([string] $Path, [AllowNull()][string] $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Set-Content -LiteralPath $Path -Value ($Content ?? '') -Encoding UTF8 -NoNewline
}
function Invoke-Fixture([string] $Script, [string[]] $ScriptArguments = @()) {
    $out = & pwsh -NoProfile -File $Script @ScriptArguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

$fakeRepo = Join-Path $work 'repo'
Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source') -Destination (Join-Path $fakeRepo 'harness-source') -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'scripts') -Force | Out-Null
foreach ($name in @('harness-profile-common.ps1', 'build-harness-profile.ps1', 'apply-harness-profile.ps1', 'status-harness-profile.ps1', 'scan-secrets.ps1')) {
    Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts/$name") -Destination (Join-Path $fakeRepo "scripts/$name") -Force
}
if (Test-Path -LiteralPath (Join-Path $RepoRoot '.gitleaks.toml')) { Copy-Item -LiteralPath (Join-Path $RepoRoot '.gitleaks.toml') -Destination $fakeRepo -Force }

$profileText = @'
@{
    SchemaVersion = 1
    Name = 'multi-platform-test'
    TargetPlatforms = @('Claude', 'Codex', 'Codex')
    Extends = @('multi-platform')
    Components = @{
        Rules = @()
        Prompts = @()
        Commands = @()
        Agents = @()
        ClaudeSettings = @()
        CodexAgents = @()
    }
    Future = @{ ProjectSkills = @() }
}
'@

function New-Project([string] $Name) {
    $project = Join-Path $work $Name
    New-Item -ItemType Directory -Path (Join-Path $project '.agent-harness') -Force | Out-Null
    Set-FixtureFile -Path (Join-Path $project '.agent-harness/profile.psd1') -Content $profileText
    return $project
}

$build = Join-Path $fakeRepo 'scripts/build-harness-profile.ps1'
$status = Join-Path $fakeRepo 'scripts/status-harness-profile.ps1'
$apply = Join-Path $fakeRepo 'scripts/apply-harness-profile.ps1'

Write-Host '[multi-platform harness output]'
$project = New-Project 'project'
$result = Invoke-Fixture $build @('-RepoRoot', $fakeRepo, '-ProjectRoot', $project)
Assert ($result.Code -eq 0) 'build supports Claude/Codex component outputs'
$generated = Join-Path $project '.agent-harness/generated'
foreach ($relative in @(
    'files/.claude/commands/commit-summary.md',
    'files/.claude/agents/reviewer.md',
    'files/.codex/prompts/review.md',
    'files/.codex/agents/reviewer.md'
)) {
    Assert (Test-Path -LiteralPath (Join-Path $generated $relative) -PathType Leaf) "build emits $relative"
}

$dry = Invoke-Fixture $apply @('-RepoRoot', $fakeRepo, '-ProjectRoot', $project)
Assert ($dry.Code -eq 0 -and $dry.Out -match 'Dry-run only') 'apply defaults to dry-run'
Assert (-not (Test-Path -LiteralPath (Join-Path $project '.claude/commands/commit-summary.md'))) 'dry-run does not write project command'

$real = Invoke-Fixture $apply @('-RepoRoot', $fakeRepo, '-ProjectRoot', $project, '-Apply')
Assert ($real.Code -eq 0) 'apply writes allowlisted project outputs'
foreach ($relative in @(
    '.claude/commands/commit-summary.md',
    '.claude/agents/reviewer.md',
    '.codex/prompts/review.md',
    '.codex/agents/reviewer.md'
)) {
    Assert (Test-Path -LiteralPath (Join-Path $project $relative) -PathType Leaf) "apply writes $relative"
}
Assert (Test-Path -LiteralPath (Join-Path $project '.agent-harness/backups') -PathType Container) 'apply creates a project-local backup'

$repeat = Invoke-Fixture $status @('-RepoRoot', $fakeRepo, '-ProjectRoot', $project)
Assert ($repeat.Code -eq 0 -and $repeat.Out -match 'action=noop') 'repeat status is idempotent'

Write-Host '[transactional rollback]'
$failureProject = New-Project 'failure-project'
New-Item -ItemType Directory -Path (Join-Path $failureProject '.codex/agents/reviewer.md') -Force | Out-Null
$failed = Invoke-Fixture $apply @('-RepoRoot', $fakeRepo, '-ProjectRoot', $failureProject, '-Apply')
Assert ($failed.Code -ne 0) 'apply failure is reported'
Assert (-not (Test-Path -LiteralPath (Join-Path $failureProject '.claude/commands/commit-summary.md'))) 'failed apply rolls back earlier writes'

Write-Host '[allowlist safety]'
$unsafeComponent = Join-Path $fakeRepo 'harness-source/components/commands/commit-command/component.psd1'
$originalComponent = Get-Content -Raw -LiteralPath $unsafeComponent
Set-FixtureFile -Path $unsafeComponent -Content ($originalComponent -replace '\.claude/commands/commit-summary\.md', '../escape.md')
$unsafe = Invoke-Fixture $status @('-RepoRoot', $fakeRepo, '-ProjectRoot', $project)
Assert ($unsafe.Code -ne 0 -and $unsafe.Out -match 'outside|unsafe|allowlist|escapes') 'target outside allowlist is rejected'
Set-FixtureFile -Path $unsafeComponent -Content $originalComponent

# Build a real secret-shaped key at runtime so the test file itself stays scan-clean.
# 'sk-ant-...' trips both the gitleaks rule (anthropic-api-key in .gitleaks.toml) and
# the fallback scanner, so the gate holds with or without gitleaks installed.
$blockingContent = ('sk-ant-' + 'Kz9xQ4mNvB7wRpT2YcH8dE1')

if ($fail -gt 0) {
    Write-Host "Results: $pass passed, $fail failed" -ForegroundColor Red
    throw 'Harness multi-platform regression failed.'
}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Results: $pass passed, $fail failed" -ForegroundColor Green
