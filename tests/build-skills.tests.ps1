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
    Add-Skill $repo 'claude-only' 'gamma'
    Add-Skill $repo 'reasonix-only' 'delta'
    Set-TestFile (Join-Path $repo 'skills-source/shared/alpha/CREATION-LOG.md') "log`n"
    $r = Invoke-Build $repo
    Assert-TestCondition ($r.Code -eq 0) "a clean build exits 0 ($($r.Out))"
    Assert-TestCondition (
        (Test-Path -LiteralPath (Join-Path $repo 'claude/skills/alpha/SKILL.md')) -and
        (Test-Path -LiteralPath (Join-Path $repo 'codex/skills/alpha/SKILL.md')) -and
        (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills/alpha/SKILL.md')) -and
        (Test-Path -LiteralPath (Join-Path $repo 'codex/skills/beta/SKILL.md')) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'claude/skills/beta'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills/beta'))) -and
        (Test-Path -LiteralPath (Join-Path $repo 'claude/skills/gamma/SKILL.md')) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'codex/skills/gamma'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills/gamma'))) -and
        (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills/delta/SKILL.md')) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'claude/skills/delta'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'codex/skills/delta')))
    ) 'shared skills land on all three roots, each platform-only skill on its own root only'
    Assert-TestCondition (([IO.File]::ReadAllText((Join-Path $repo 'codex/skills/beta/SKILL.md'))) -ceq "# beta`n") 'generated SKILL.md content matches the source'
    Assert-TestCondition (
        (-not (Test-Path -LiteralPath (Join-Path $repo 'claude/skills/alpha/CREATION-LOG.md'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'codex/skills/alpha/CREATION-LOG.md'))) -and
        (-not (Test-Path -LiteralPath (Join-Path $repo 'reasonix/skills/alpha/CREATION-LOG.md')))
    ) 'CREATION-LOG.md is excluded from all generated roots'
    $claudeManifest = [IO.File]::ReadAllText((Join-Path $repo 'manifests/managed-skills.claude.txt'))
    $codexManifest = [IO.File]::ReadAllText((Join-Path $repo 'manifests/managed-skills.codex.txt'))
    $reasonixManifest = [IO.File]::ReadAllText((Join-Path $repo 'manifests/managed-skills.reasonix.txt'))
    Assert-TestCondition ($claudeManifest -ceq "alpha`ngamma`n" -and $codexManifest -ceq "alpha`nbeta`n" -and $reasonixManifest -ceq "alpha`ndelta`n") 'manifests list each platform set sorted'

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

    Write-Host '[reparse points are refused]'
    $repo = Join-Path $work 'junction'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Add-Skill $repo 'shared' 'alpha'
    $outside = Join-Path $work 'outside'
    Set-TestFile (Join-Path $outside 'sentinel.txt') 'keep'
    New-Item -ItemType Directory -Path (Join-Path $repo 'claude/skills') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $repo 'claude/skills/alpha') -Target $outside | Out-Null
    $r = Invoke-Build $repo
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'reparse point') 'a junction under a generated root is refused before the wipe'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $outside 'sentinel.txt')) -eq 'keep' -and @(Get-ChildItem $outside).Count -eq 1) 'the junction target is untouched'

    Write-Host 'build-skills tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
