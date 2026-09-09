#requires -Version 7.0
<##
.SYNOPSIS
    Regression tests for the repository-shared task skill overlay.

.DESCRIPTION
    Uses a copied fake repository and two fake homes. The real task, activation,
    environment build, and sync scripts are exercised with only the build and
    secret-scan gates skipped because the fixture already supplies generated
    skill output. No real home, live skill root, tracked overlay, or real state
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
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-task-skills-$([Guid]::NewGuid().ToString('N'))"
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

function Remove-Work {
    if (($work -like '*ai-agent-dotfiles-task-skills-*') -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [AllowNull()] [string] $Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value ($Content ?? '') -NoNewline -Encoding UTF8
}

function Invoke-Script {
    param([Parameter(Mandatory)] [string] $Script, [string[]] $Arguments = @())
    if ($Arguments -contains '-Apply') {
        $result = Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $Script -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
        return @{ Code = $result.Code; Out = $result.Out }
    }
    $output = & pwsh -NoProfile -File $Script @Arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $output }
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)] [string] $Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return '' }
    $rows = foreach ($file in (Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName)) {
        '{0}|{1}' -f $file.FullName, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return ($rows -join "`n")
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

Remove-Work
New-Item -ItemType Directory -Path $work -Force | Out-Null
$fakeRepo = Join-Path $work 'repo'
$homeOne = Join-Path $work 'home-one'
$homeTwo = Join-Path $work 'home-two'
$backupRoot = Join-Path $work 'backups'
New-Item -ItemType Directory -Path $fakeRepo -Force | Out-Null
& git -C $fakeRepo init --quiet
if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize the external task fixture repository.' }

# Copy the implementation and profile sources, but use tiny fixture skill trees.
Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts') -Destination (Join-Path $fakeRepo 'scripts') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source') -Destination (Join-Path $fakeRepo 'harness-source') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot '.gitleaks.toml') -Destination (Join-Path $fakeRepo '.gitleaks.toml') -Force

Set-File -Path (Join-Path $fakeRepo 'manifests/managed-skills.claude.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
Set-File -Path (Join-Path $fakeRepo 'manifests/managed-skills.codex.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
Set-File -Path (Join-Path $fakeRepo 'manifests/managed-skills.reasonix.txt') -Content ''
Set-File -Path (Join-Path $fakeRepo 'manifests/managed-skills.txt') -Content "fixture-a`nfixture-b`nfixture-c`n"
New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'reasonix/skills') -Force | Out-Null
foreach ($skill in @('fixture-a', 'fixture-b', 'fixture-c')) {
    Set-File -Path (Join-Path $fakeRepo "skills-source/shared/$skill/SKILL.md") -Content "# $skill source"
    Set-File -Path (Join-Path $fakeRepo "claude/skills/$skill/SKILL.md") -Content "# $skill claude"
    Set-File -Path (Join-Path $fakeRepo "codex/skills/$skill/SKILL.md") -Content "# $skill codex"
}
Set-File -Path (Join-Path $fakeRepo 'harness-source/envs/work.psd1') -Content @"
@{
    SchemaVersion = 1
    Name = 'work'
    Description = 'fixture work env'
    Profile = 'coding'
    Skills = @{
        Claude = @('fixture-a')
        Codex = @('fixture-a')
        Reasonix = @()
    }
}
"@
Set-File -Path (Join-Path $fakeRepo '.agent-harness/task-skills.psd1') -Content (New-OverlayText)

foreach ($homeDir in @($homeOne, $homeTwo)) {
    New-Item -ItemType Directory -Path (Join-Path $homeDir '.claude/skills') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $homeDir '.codex/skills/.system') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $homeDir 'AppData/Roaming/reasonix/skills') -Force | Out-Null
    Set-File -Path (Join-Path $homeDir '.claude/skills/fixture-a/SKILL.md') -Content '# fixture-a claude'
    Set-File -Path (Join-Path $homeDir '.codex/skills/fixture-a/SKILL.md') -Content '# fixture-a codex'
    Set-File -Path (Join-Path $homeDir '.codex/skills/.system/.codex-system-skills.marker') -Content ''
    Set-File -Path (Join-Path $homeDir '.codex/skills/.system/system.md') -Content '# fixture system'
}

$taskScript = Join-Path $fakeRepo 'scripts/task-skills.ps1'
$statusScript = Join-Path $fakeRepo 'scripts/status-harness-env.ps1'
$entryScript = Join-Path $fakeRepo 'scripts/agent-dotfiles.ps1'
$overlayPath = Join-Path $fakeRepo '.agent-harness/task-skills.psd1'
$systemOne = Join-Path $homeOne '.codex/skills/.system/system.md'

Write-Host 'task overlay: status and explicit-mode gates'
$result = Invoke-Script -Script $taskScript -Arguments @('-Action', 'status', '-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 0 -and $result.Out -match 'overlay state: present') 'status accepts the empty tracked overlay'
$result = Invoke-Script -Script $entryScript -Arguments @('env', 'task', 'ensure-skill', 'fixture-b', '-RepoRoot', $fakeRepo)
Assert ($result.Code -eq 1 -and $result.Out -match 'explicit -DryRun or -Apply') 'dispatcher rejects implicit task apply'

Write-Host 'task overlay: invalid skill rejection'
$overlayBefore = Get-TreeSnapshot -Root (Split-Path -Parent $overlayPath)
$result = Invoke-Script -Script $taskScript -Arguments @('-Action', 'ensure-skill', 'not-managed', '-Platform', 'Codex', '-RepoRoot', $fakeRepo, '-HomeRoot', $homeOne, '-BackupRoot', $backupRoot, '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($result.Code -ne 0 -and $result.Out -match 'not managed') 'unmanaged skill is rejected'
Assert ((Get-TreeSnapshot -Root (Split-Path -Parent $overlayPath)) -eq $overlayBefore) 'invalid request does not change the overlay'

Write-Host 'task overlay: addition dry-run'
$homeOneBefore = Get-TreeSnapshot -Root $homeOne
$result = Invoke-Script -Script $entryScript -Arguments @('env', 'task', 'ensure-skill', 'fixture-b', '-Platform', 'Codex', '-RepoRoot', $fakeRepo, '-HomeRoot', $homeOne, '-BackupRoot', $backupRoot, '-DryRun', '-SkipBuild', '-SkipSecretScan')
if ($result.Code -ne 0) { Write-Host '----- addition dry-run output -----'; Write-Host $result.Out }
Assert ($result.Code -eq 0) 'addition dry-run exits 0 through the activation preview gate'
Assert ((Get-Content -Raw -LiteralPath $overlayPath) -match "Codex = @\(\)" ) 'addition dry-run leaves the tracked overlay empty'
Assert ((Get-TreeSnapshot -Root $homeOne) -eq $homeOneBefore) 'addition dry-run leaves live home unchanged'

Write-Host 'task overlay: apply is interlocked'
$result = Invoke-Script -Script $taskScript -Arguments @('-Action', 'ensure-skill', 'fixture-b', '-Platform', 'Codex', '-RepoRoot', $fakeRepo, '-HomeRoot', $homeOne, '-BackupRoot', $backupRoot, '-Apply', '-SkipBuild', '-SkipSecretScan')
if ($result.Code -eq 0 -or $result.Out -notmatch 'activation-deploy-not-wired') { Write-Host '----- ensure apply output -----'; Write-Host $result.Out }
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-deploy-not-wired') 'task ensure apply fails closed without a deployment mechanism'
Assert (-not (Test-Path -LiteralPath (Join-Path $homeOne '.codex/skills/fixture-b/SKILL.md'))) 'interlocked task apply installs no skill'
Assert ((Get-Content -Raw -LiteralPath $overlayPath) -match "Codex = @\(\)") 'interlocked task apply leaves the tracked overlay empty'
Assert (Test-Path -LiteralPath $systemOne) 'interlocked task apply preserves Codex .system'
Assert (@(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue).Count -eq 0) 'interlocked task apply creates no backup'

Write-Host 'task overlay: second-home apply is interlocked'
$result = Invoke-Script -Script $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $fakeRepo, '-HomeRoot', $homeTwo, '-BackupRoot', $backupRoot, '-Apply', '-SkipBuild', '-SkipSecretScan')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-deploy-not-wired') 'second-home sync apply fails closed without a deployment mechanism'
Assert (-not (Test-Path -LiteralPath (Join-Path $homeTwo '.codex/skills/fixture-b/SKILL.md'))) 'interlocked second-home sync installs no skill'

Write-Host 'task overlay: automatic addition-only policy refuses removals pre-deploy'
# Seed the activation-state overlay baseline that the automatic policy reads;
# a real baseline is written by a successful activation (Phase 3 rewires it).
Set-File -Path (Join-Path $fakeRepo 'state/current-env.json') -Content (@{
    SchemaVersion = 2
    Name = 'work'
    TaskOverlaySkills = [ordered]@{ Claude = @(); Codex = @('fixture-b', 'ghost-skill'); Reasonix = @() }
} | ConvertTo-Json -Depth 4)
Set-File -Path $overlayPath -Content (New-OverlayText -Codex @('fixture-b', 'fixture-c'))
$homeOneWithOverlay = Get-TreeSnapshot -Root $homeOne
$result = Invoke-Script -Script $taskScript -Arguments @('-Action', 'sync', '-RepoRoot', $fakeRepo, '-HomeRoot', $homeOne, '-BackupRoot', $backupRoot, '-Apply', '-Automatic', '-SkipBuild', '-SkipSecretScan')
Assert ($result.Code -eq 0 -and $result.Out -match 'removal requires explicit review') 'automatic sync skips overlay removals without deploying'
Assert ((Get-TreeSnapshot -Root $homeOne) -eq $homeOneWithOverlay) 'the removal refusal leaves live skills untouched'

Set-File -Path $overlayPath -Content (New-OverlayText)

Write-Host 'task overlay: close apply is interlocked'
$result = Invoke-Script -Script $taskScript -Arguments @('-Action', 'close', '-RepoRoot', $fakeRepo, '-HomeRoot', $homeOne, '-BackupRoot', $backupRoot, '-DryRun', '-SkipBuild', '-SkipSecretScan')
Assert ($result.Code -eq 0) 'close dry-run exits 0 through the activation preview gate'
Assert (Test-Path -LiteralPath $overlayPath) 'close dry-run keeps the overlay file'
$result = Invoke-Script -Script $taskScript -Arguments @('-Action', 'close', '-RepoRoot', $fakeRepo, '-HomeRoot', $homeOne, '-BackupRoot', $backupRoot, '-Apply', '-SkipBuild', '-SkipSecretScan')
Assert ($result.Code -ne 0 -and $result.Out -match 'activation-deploy-not-wired') 'close apply fails closed without a deployment mechanism'
Assert (Test-Path -LiteralPath $overlayPath) 'the interlocked close apply keeps the shared overlay'
Assert (Test-Path -LiteralPath $systemOne) 'the interlocked close apply preserves Codex .system'

Write-Host 'task overlay: lock drift and status recovery'
Set-File -Path $overlayPath -Content (New-OverlayText)
Set-File -Path (Join-Path $fakeRepo 'envs/work/env.lock.json') -Content '{"broken":true}'
$result = Invoke-Script -Script $statusScript -Arguments @('-RepoRoot', $fakeRepo)
Assert ($result.Out -match 'staging=stale') 'status reports stale staging after lock drift'

Write-Host ''
Write-Host ("task-skills tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) {
    Write-Host "Workspace kept for inspection: $work"
    exit 1
}
Remove-Work
exit 0
