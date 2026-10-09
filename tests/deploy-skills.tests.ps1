#requires -Version 7.0
# Behavior tests for scripts/deploy-skills.ps1 against a fixture repo and a fake home in %TEMP%.
# Covers dry-run, install/unchanged/update/prune, backups, .system and unknown preservation,
# explicit -Retire, the Codex fallback root, and reparse-point refusal.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
$deploy = Join-Path $RepoRoot 'scripts/deploy-skills.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('deploy-skills-tests-' + [guid]::NewGuid().ToString('N'))

function Set-TestFile([string] $Path, [string] $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}
function Set-TestEnvironment([string] $Repo, [string[]] $Skills) {
    $list = ($Skills | ForEach-Object { "'$_'" }) -join ', '
    Set-TestFile (Join-Path $Repo 'harness-source/envs/test.psd1') "@{ Skills = @{ Claude = @($list); Codex = @($list); Reasonix = @($list) } }"
}
function Invoke-Deploy([string] $Repo, [string] $HomeDir, [string[]] $Extra = @()) {
    Invoke-TestProcess -ScriptPath $deploy -Arguments (@('-Environment', 'test', '-RepoRoot', $Repo, '-HomeRoot', $HomeDir, '-StateRoot', (Join-Path $HomeDir 'state'), '-SkipBuild') + $Extra)
}
function Get-LiveRoots([string] $HomeDir) {
    @((Join-Path $HomeDir '.claude/skills'), (Join-Path $HomeDir '.codex/skills'), (Join-Path $HomeDir 'AppData/Roaming/reasonix/skills'))
}

try {
    $repo = Join-Path $work 'repo'
    $homeDir = Join-Path $work 'home'
    foreach ($platform in 'claude', 'codex', 'reasonix') {
        foreach ($skill in 'alpha', 'beta') { Set-TestFile (Join-Path $repo "$platform/skills/$skill/SKILL.md") "# $skill v1`n" }
    }
    Set-TestEnvironment $repo @('alpha', 'beta')
    Set-TestFile (Join-Path $homeDir '.codex/skills/.system/marker.txt') 'platform'
    Set-TestFile (Join-Path $homeDir '.claude/skills/hand-made/SKILL.md') 'mine'

    Write-Host '[dry run writes nothing]'
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -eq 0) "dry run exits 0 ($($r.Out))"
    Assert-TestCondition ($r.Out -match 'install' -and $r.Out -match 'Dry run') 'dry run reports the planned installs'
    Assert-TestCondition (-not (Test-Path (Join-Path $homeDir '.claude/skills/alpha'))) 'dry run installs nothing'
    Assert-TestCondition (-not (Test-Path (Join-Path $homeDir 'state'))) 'dry run writes no state'

    Write-Host '[first apply installs on all three platforms]'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) "first apply exits 0 ($($r.Out))"
    foreach ($root in Get-LiveRoots $homeDir) {
        Assert-TestCondition ((Get-Content -Raw (Join-Path $root 'alpha/SKILL.md')) -eq "# alpha v1`n") "alpha installed under $root"
        Assert-TestCondition (-not @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object Name -like '.deploying-*')) "no staging left under $root"
    }
    Assert-TestCondition ((Get-Content -Raw (Join-Path $homeDir '.codex/skills/.system/marker.txt')) -eq 'platform') 'Codex .system untouched'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $homeDir '.claude/skills/hand-made/SKILL.md')) -eq 'mine') 'unknown live skill untouched'
    $state = Get-Content -Raw (Join-Path $homeDir 'state/deployed-skills.json') | ConvertFrom-Json
    Assert-TestCondition ((@($state.Codex) -join ',') -eq 'alpha,beta') 'state records the deployed set'

    Write-Host '[second apply is a no-op]'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'unchanged' -and $r.Out -notmatch '(?m)^(install|update|prune) ') 'unchanged skills are left alone'

    Write-Host '[changed source updates with a backup]'
    Set-TestFile (Join-Path $repo 'claude/skills/alpha/SKILL.md') "# alpha v2`n"
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'update Claude/alpha') 'changed skill is updated'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $homeDir '.claude/skills/alpha/SKILL.md')) -eq "# alpha v2`n") 'live copy has the new content'
    $backup = @(Get-ChildItem -LiteralPath (Join-Path $homeDir 'state/skill-backups') -Recurse -File -Filter SKILL.md | Where-Object { $_.FullName -match 'Claude[\\/]alpha' })
    Assert-TestCondition ($backup.Count -eq 1 -and (Get-Content -Raw $backup[0].FullName) -eq "# alpha v1`n") 'the previous copy is backed up'

    Write-Host '[deselected skill is pruned; unknown stays]'
    Set-TestEnvironment $repo @('alpha')
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'prune Codex/beta') 'deselected skill is pruned'
    foreach ($root in Get-LiveRoots $homeDir) { Assert-TestCondition (-not (Test-Path (Join-Path $root 'beta'))) "beta removed from $root" }
    Assert-TestCondition (Test-Path (Join-Path $homeDir '.claude/skills/hand-made')) 'unknown skill still untouched after prune'
    Assert-TestCondition (Test-Path (Join-Path $homeDir '.codex/skills/.system/marker.txt')) '.system still untouched after prune'

    Write-Host '[explicit retire removes a named unknown skill]'
    $r = Invoke-Deploy $repo $homeDir @('-Retire', 'hand-made')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'prune' -and (Test-Path (Join-Path $homeDir '.claude/skills/hand-made'))) 'retire is only planned on dry run'
    $r = Invoke-Deploy $repo $homeDir @('-Apply', '-Retire', 'hand-made')
    Assert-TestCondition ($r.Code -eq 0 -and -not (Test-Path (Join-Path $homeDir '.claude/skills/hand-made'))) 'retire removes the named skill on apply'
    $r = Invoke-Deploy $repo $homeDir @('-Apply', '-Retire', '.system')
    Assert-TestCondition ($r.Code -ne 0 -and (Test-Path (Join-Path $homeDir '.codex/skills/.system/marker.txt'))) '.system can never be retired'

    Write-Host '[Codex fallback root]'
    $fallbackHome = Join-Path $work 'fallback-home'
    New-Item -ItemType Directory -Path (Join-Path $fallbackHome '.agents/skills') -Force | Out-Null
    $r = Invoke-Deploy $repo $fallbackHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (Test-Path (Join-Path $fallbackHome '.agents/skills/alpha')) -and -not (Test-Path (Join-Path $fallbackHome '.codex/skills'))) 'only ~/.agents/skills present: it is used'
    New-Item -ItemType Directory -Path (Join-Path $fallbackHome '.codex/skills') -Force | Out-Null
    $r = Invoke-Deploy $repo $fallbackHome
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'codex-live-root-ambiguous') 'both Codex roots present is refused'

    Write-Host '[a locked file fails the update as a whole]'
    Set-TestFile (Join-Path $repo 'codex/skills/alpha/refs/a.md') 'ref'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (Test-Path (Join-Path $homeDir '.codex/skills/alpha/refs/a.md'))) 'alpha with refs is deployed'
    Set-TestFile (Join-Path $repo 'codex/skills/alpha/SKILL.md') "# alpha v3`n"
    $lock = [IO.File]::Open((Join-Path $homeDir '.codex/skills/alpha/SKILL.md'), 'Open', 'Read', 'Read')
    try { $r = Invoke-Deploy $repo $homeDir @('-Apply') } finally { $lock.Dispose() }
    Assert-TestCondition ($r.Code -ne 0) 'update over a locked file fails'
    Assert-TestCondition ((Test-Path (Join-Path $homeDir '.codex/skills/alpha/refs/a.md')) -and (Get-Content -Raw (Join-Path $homeDir '.codex/skills/alpha/SKILL.md')) -eq "# alpha v1`n") 'the live skill is left whole'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (Get-Content -Raw (Join-Path $homeDir '.codex/skills/alpha/SKILL.md')) -eq "# alpha v3`n") 'the next run completes the update'
    Assert-TestCondition (-not @(Get-ChildItem -LiteralPath (Join-Path $homeDir '.codex/skills') -Directory -Force | Where-Object Name -like '.deploying-*')) 'leftover staging is cleaned'

    Write-Host '[malformed environments are refused]'
    $envFile = Join-Path $repo 'harness-source/envs/test.psd1'
    $good = [IO.File]::ReadAllText($envFile)
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Claude = @('alpha'); Codx = @('alpha'); Reasonix = @('alpha') } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'exactly the keys') 'a misspelled platform key is refused instead of pruning everything'
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Claude = @('alpha.'); Codex = @('alpha'); Reasonix = @('alpha') } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'invalid skill name') 'a trailing-dot name is refused'
    [IO.File]::WriteAllText($envFile, $good)

    Write-Host '[reparse points are refused]'
    $outside = Join-Path $work 'outside'
    Set-TestFile (Join-Path $outside 'sentinel.txt') 'keep'
    $junctionHome = Join-Path $work 'junction-home'
    New-Item -ItemType Directory -Path (Join-Path $junctionHome '.claude/skills') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $junctionHome '.claude/skills/alpha') -Target $outside | Out-Null
    $r = Invoke-Deploy $repo $junctionHome @('-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'reparse-point-refused') 'a junction under a live root is refused'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $outside 'sentinel.txt')) -eq 'keep' -and @(Get-ChildItem $outside).Count -eq 1) 'the junction target is untouched'

    Write-Host 'deploy-skills tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
