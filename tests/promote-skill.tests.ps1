#requires -Version 7.0
# Behavior tests for scripts/promote-skill.ps1 against disposable fixture repos in %TEMP%.
# Covers dry run, Apply with build and scan, name/type/-Replace refusals, the backup on
# -Replace, missing SKILL.md, reparse points and a failing scan.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
$promote = Join-Path $RepoRoot 'scripts/promote-skill.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('promote-skill-tests-' + [guid]::NewGuid().ToString('N'))

function Set-TestFile([string] $Path, [string] $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}
function New-FixtureRepo([string] $Name) {
    $repo = Join-Path $work $Name
    Set-TestFile (Join-Path $repo '.gitignore') "tmp/`nreports/`nclaude/skills/`ncodex/skills/`nreasonix/skills/`n"
    Set-TestFile (Join-Path $repo 'skills-source/shared/existing/SKILL.md') "# existing v1`n"
    Copy-Item -LiteralPath (Join-Path $RepoRoot '.gitleaks.toml') -Destination $repo
    & git -C $repo init --quiet
    if ($LASTEXITCODE -ne 0) { throw "Unable to initialize fixture repo: $repo" }
    return $repo
}
function Invoke-Promote([string] $Repo, [string[]] $Arguments) {
    Invoke-TestProcess -ScriptPath $promote -Arguments (@('-RepoRoot', $Repo) + $Arguments)
}

try {
    $repo = New-FixtureRepo 'repo'
    $skillDir = Join-Path $work 'inputs/new-skill'
    Set-TestFile (Join-Path $skillDir 'SKILL.md') "---`nname: new-skill`n---`n# new skill`n"
    Set-TestFile (Join-Path $skillDir 'refs/notes.md') "notes`n"
    $target = Join-Path $repo 'skills-source/claude-only/new-skill'

    Write-Host '[dry run]'
    $r = Invoke-Promote $repo @('-Path', $skillDir, '-Name', 'new-skill', '-Type', 'claude-only')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'create skills-source/claude-only/new-skill' -and $r.Out -match 'file: refs/notes\.md') "dry run lists the target and files ($($r.Out))"
    Assert-TestCondition (-not (Test-Path -LiteralPath $target)) 'dry run writes nothing'
    $r = Invoke-Promote $repo @('-Path', $skillDir, '-Name', 'new-skill', '-Type', 'claude-only', '-DryRun')
    Assert-TestCondition ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $target)) 'explicit -DryRun is accepted and writes nothing'

    Write-Host '[apply]'
    $r = Invoke-Promote $repo @('-Path', $skillDir, '-Name', 'new-skill', '-Type', 'claude-only', '-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'build-skills\.ps1: PASS' -and $r.Out -match 'scan-secrets\.ps1: PASS') "Apply passes build and scan ($($r.Out))"
    Assert-TestCondition ((Test-Path -LiteralPath (Join-Path $target 'refs/notes.md')) -and (Test-Path -LiteralPath (Join-Path $repo 'claude/skills/new-skill/SKILL.md'))) 'Apply copies the tree and rebuilds generated output'

    Write-Host '[refusals]'
    foreach ($bad in '.system', '-dash', 'trailing.', 'a/b', '..') {
        $r = Invoke-Promote $repo @('-Path', $skillDir, '-Name', $bad, '-Type', 'shared', '-Apply')
        Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'Invalid skill name') "refuses the name '$bad'"
    }
    $r = Invoke-Promote $repo @('-Path', $skillDir, '-Name', 'existing', '-Type', 'shared', '-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'already exists') 'refuses an existing name without -Replace'
    $r = Invoke-Promote $repo @('-Path', $skillDir, '-Name', 'existing', '-Type', 'codex-only', '-Replace', '-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'another type' -and -not (Test-Path -LiteralPath (Join-Path $repo 'skills-source/codex-only/existing'))) 'refuses -Replace across types'
    $noSkill = Join-Path $work 'inputs/no-skill'
    Set-TestFile (Join-Path $noSkill 'README.md') "x`n"
    $r = Invoke-Promote $repo @('-Path', $noSkill, '-Name', 'no-skill', '-Type', 'shared')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'no SKILL\.md') 'refuses a source without SKILL.md'
    $linked = Join-Path $work 'inputs/linked'
    Set-TestFile (Join-Path $linked 'SKILL.md') "# linked`n"
    New-Item -ItemType Junction -Path (Join-Path $linked 'outside') -Target $noSkill | Out-Null
    $r = Invoke-Promote $repo @('-Path', $linked, '-Name', 'linked', '-Type', 'shared')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'reparse point') 'refuses a source that contains a junction'
    $r = Invoke-Promote $repo @('-Path', (Join-Path $repo 'skills-source/shared/existing'), '-Name', 'existing', '-Type', 'shared', '-Replace', '-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'overlap' -and (Test-Path -LiteralPath (Join-Path $repo 'skills-source/shared/existing/SKILL.md'))) 'refuses a source that is the target'

    Write-Host '[replace]'
    $v2 = Join-Path $work 'inputs/existing-v2'
    Set-TestFile (Join-Path $v2 'SKILL.md') "# existing v2`n"
    $r = Invoke-Promote $repo @('-Path', $v2, '-Name', 'existing', '-Type', 'shared', '-Replace', '-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (Get-Content -Raw -LiteralPath (Join-Path $repo 'skills-source/shared/existing/SKILL.md')) -match 'v2') "-Replace installs the new copy ($($r.Out))"
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $repo 'tmp/skill-backups') -Recurse -Filter SKILL.md -File)
    Assert-TestCondition ($backups.Count -eq 1 -and $backups[0].FullName -match '[\\/]shared[\\/]existing[\\/]SKILL\.md$' -and (Get-Content -Raw -LiteralPath $backups[0].FullName) -match 'v1') '-Replace backs up the old copy under tmp/skill-backups'

    Write-Host '[failing scan]'
    $secret = Join-Path $work 'inputs/leaky'
    $githubToken = 'gh' + 'p_' + ('a1B2' * 9)
    Set-TestFile (Join-Path $secret 'SKILL.md') "# leaky`n`ngithub = '$githubToken'`n"
    $r = Invoke-Promote $repo @('-Path', $secret, '-Name', 'leaky', '-Type', 'shared', '-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'scan-secrets\.ps1: FAIL' -and (Test-Path -LiteralPath (Join-Path $repo 'skills-source/shared/leaky/SKILL.md'))) "a failing scan exits non-zero and leaves the files for review ($($r.Out))"

    Write-Host 'promote-skill tests: PASS'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
