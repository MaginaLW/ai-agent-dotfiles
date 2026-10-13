#requires -Version 7.0
# Behavior tests for scripts/build-skills.ps1 against fixture repositories in %TEMP%: the
# happy-path build (root placement, manifests, CREATION-LOG.md exclusion) and both
# name-conflict refusals (shared vs platform-only, and cross platform-only).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
$build = Join-Path $RepoRoot 'scripts/build-skills.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('build-skills-tests-' + [guid]::NewGuid().ToString('N'))

function Set-TestFile([string] $Path, [string] $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}
function Add-Skill([string] $Repo, [string] $Group, [string] $Name) {
    Set-TestFile (Join-Path $Repo "skills-source/$Group/$Name/SKILL.md") "# $Name`n"
}
function Invoke-Build([string] $Repo) {
    return Invoke-TestProcess -ScriptPath $build -Arguments @('-RepoRoot', $Repo)
}

try {
    Write-Host '[happy path]'
    $repo = Join-Path $work 'happy'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Add-Skill $repo 'shared' 'alpha'
    Add-Skill $repo 'codex-only' 'beta'
    Set-TestFile (Join-Path $repo 'skills-source/shared/alpha/CREATION-LOG.md') "log`n"
    $r = Invoke-Build $repo
    Assert-TestCondition ($r.Code -eq 0) "a clean build exits 0 ($($r.Out))"
    Assert-TestCondition (
        (Test-Path -LiteralPath (Join-Path $repo 'claude/skills/alpha/SKILL.md')) -and
        (Test-Path -LiteralPath (Join-Path $repo 'codex/skills/alpha/SKILL.md')) -and
        (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills/alpha/SKILL.md')) -and
        (Test-Path -LiteralPath (Join-Path $repo 'codex/skills/beta/SKILL.md')) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'claude/skills/beta'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills/beta')))
    ) 'shared skills land on all three roots, codex-only on Codex only'
    Assert-TestCondition (([IO.File]::ReadAllText((Join-Path $repo 'codex/skills/beta/SKILL.md'))) -ceq "# beta`n") 'generated SKILL.md content matches the source'
    Assert-TestCondition (
        (-not (Test-Path -LiteralPath (Join-Path $repo 'claude/skills/alpha/CREATION-LOG.md'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'codex/skills/alpha/CREATION-LOG.md'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills/alpha/CREATION-LOG.md')))
    ) 'CREATION-LOG.md is excluded from all generated roots'
    $claudeManifest = [IO.File]::ReadAllText((Join-Path $repo 'manifests/managed-skills.claude.txt'))
    $codexManifest = [IO.File]::ReadAllText((Join-Path $repo 'manifests/managed-skills.codex.txt'))
    $reasonixManifest = [IO.File]::ReadAllText((Join-Path $repo 'manifests/managed-skills.reasonix.txt'))
    Assert-TestCondition ($claudeManifest -ceq "alpha`n" -and $codexManifest -ceq "alpha`nbeta`n" -and $reasonixManifest -ceq "alpha`n") 'manifests list each platform set sorted'

    Write-Host '[shared vs platform-only name conflict]'
    $repo = Join-Path $work 'conflict-shared'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Add-Skill $repo 'shared' 'dup'
    Add-Skill $repo 'codex-only' 'dup'
    $r = Invoke-Build $repo
    Assert-TestCondition ($r.Code -eq 1 -and $r.Out -match 'Skill name conflict between shared and platform-only sources') "a shared/platform-only conflict exits 1 ($($r.Out))"
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $repo 'manifests'))) 'a rejected build creates no manifests'
    Assert-TestCondition (
        (-not (Test-Path -LiteralPath (Join-Path $repo 'claude/skills'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'codex/skills'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills')))
    ) 'a rejected build creates no generated roots'

    Write-Host '[cross platform-only name conflict]'
    $repo = Join-Path $work 'conflict-cross'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Add-Skill $repo 'claude-only' 'dup'
    Add-Skill $repo 'codex-only' 'dup'
    $r = Invoke-Build $repo
    Assert-TestCondition ($r.Code -eq 1 -and $r.Out -match 'more than one platform-only source') "a cross platform-only conflict exits 1 ($($r.Out))"
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $repo 'manifests'))) 'a rejected build creates no manifests'
    Assert-TestCondition (
        (-not (Test-Path -LiteralPath (Join-Path $repo 'claude/skills'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'codex/skills'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills')))
    ) 'a rejected build creates no generated roots'

    Write-Host 'build-skills tests: PASS'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
