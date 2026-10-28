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

function Set-TestEnvironment([string] $Repo, [string[]] $Skills, [string[]] $ZcodeSkills = @()) {
    $list = ($Skills | ForEach-Object { "'$_'" }) -join ', '
    $zlist = ($ZcodeSkills | ForEach-Object { "'$_'" }) -join ', '
    Set-TestFile (Join-Path $Repo 'harness-source/envs/test.psd1') "@{ Skills = @{ Claude = @($list); Codex = @($list); Zcode = @($zlist) } }"
}
function Invoke-Deploy([string] $Repo, [string] $HomeDir, [string[]] $Extra = @()) {
    Invoke-TestProcess -ScriptPath $deploy -Arguments (@('-Environment', 'test', '-RepoRoot', $Repo, '-HomeRoot', $HomeDir, '-StateRoot', (Join-Path $HomeDir 'state'), '-SkipBuild') + $Extra)
}
function Get-LiveRoots([string] $HomeDir) {
    @((Join-Path $HomeDir '.claude/skills'), (Join-Path $HomeDir '.codex/skills'))
}

try {
    $repo = Join-Path $work 'repo'
    $homeDir = Join-Path $work 'home'
    foreach ($platform in 'claude', 'codex') {
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

    Write-Host '[review updates absent from deploy state]'
    $reviewHome = Join-Path $work 'review-home'
    Set-TestFile (Join-Path $reviewHome '.claude/skills/alpha/SKILL.md') 'existing content'
    $r = Invoke-Deploy $repo $reviewHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Update not recorded in deploy state: Claude/alpha' -and $r.Out -match 'ownership is unknown') 'missing state warns of an update without claiming ownership'
    Set-TestFile (Join-Path $reviewHome 'state/deployed-skills.json') '{"Claude":[],"Codex":[],"Zcode":[]}'
    $r = Invoke-Deploy $repo $reviewHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Update not recorded in deploy state: Claude/alpha') 'existing state without the name warns'
    Set-TestFile (Join-Path $reviewHome 'state/deployed-skills.json') '{"Claude":["alpha"],"Codex":[],"Zcode":[]}'
    $r = Invoke-Deploy $repo $reviewHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -notmatch 'Update not recorded in deploy state: Claude/alpha') 'state-recorded updates do not produce the warning'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $reviewHome '.claude/skills/alpha/SKILL.md')) -eq 'existing content') 'review does not change the existing directory'

    Write-Host '[first apply installs selected platforms]'
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

    Write-Host '[legacy state is ignored and retired on apply]'
    $statePath = Join-Path $homeDir 'state/deployed-skills.json'
    $oldState = Get-Content -Raw $statePath | ConvertFrom-Json -AsHashtable
    $oldState['Reasonix'] = @('alpha')
    Set-TestFile $statePath ($oldState | ConvertTo-Json)
    $stateHash = (Get-FileHash -LiteralPath $statePath).Hash
    $legacyFile = Join-Path $homeDir 'AppData/Roaming/reasonix/skills/alpha/SKILL.md'
    Set-TestFile $legacyFile 'legacy bytes'
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -eq 0 -and (Get-FileHash -LiteralPath $statePath).Hash -eq $stateHash -and (Get-Content -Raw $legacyFile) -eq 'legacy bytes') 'dry run ignores legacy state without changing it or the retired root'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    $state = Get-Content -Raw $statePath | ConvertFrom-Json -AsHashtable
    Assert-TestCondition ($r.Code -eq 0 -and -not $state.ContainsKey('Reasonix') -and (Get-Content -Raw $legacyFile) -eq 'legacy bytes') 'apply writes active state only and preserves the retired root'

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
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'Apply failed; backups created so far') 'update over a locked file fails and reports its backup location'
    Assert-TestCondition ((Test-Path (Join-Path $homeDir '.codex/skills/alpha/refs/a.md')) -and (Get-Content -Raw (Join-Path $homeDir '.codex/skills/alpha/SKILL.md')) -eq "# alpha v1`n") 'the live skill is left whole'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (Get-Content -Raw (Join-Path $homeDir '.codex/skills/alpha/SKILL.md')) -eq "# alpha v3`n") 'the next run completes the update'
    Assert-TestCondition (-not @(Get-ChildItem -LiteralPath (Join-Path $homeDir '.codex/skills') -Directory -Force | Where-Object Name -like '.deploying-*')) 'leftover staging is cleaned'

    Write-Host '[interrupted update preserves the old directory]'
    $interruptedHome = Join-Path $work 'interrupted-home'
    $r = Invoke-Deploy $repo $interruptedHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) 'interrupted fixture is initially deployed'
    $interruptedRoot = Join-Path $interruptedHome '.claude/skills'
    $oldStatePath = Join-Path $interruptedHome 'state/deployed-skills.json'
    $beforeState = Get-FileHash -LiteralPath $oldStatePath
    New-Item -ItemType Directory -Path (Join-Path $interruptedHome 'state/skill-backups/prior/Claude') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $interruptedRoot 'alpha') -Destination (Join-Path $interruptedHome 'state/skill-backups/prior/Claude/alpha') -Recurse -Force
    Rename-Item -LiteralPath (Join-Path $interruptedRoot 'alpha') -NewName '.deploying-old-alpha'
    Set-TestFile (Join-Path $repo 'claude/skills/alpha/SKILL.md') "# alpha v5`n"
    Copy-Item -LiteralPath (Join-Path $repo 'claude/skills/alpha') -Destination (Join-Path $interruptedRoot '.deploying-alpha') -Recurse
    $r = Invoke-Deploy $repo $interruptedHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'interrupted' -and $r.Out -match '\.deploying-old-alpha' -and $r.Out -match 'skill-backups') 'dry run reports interrupted remnants and backup location'
    Assert-TestCondition ((Get-FileHash -LiteralPath $oldStatePath).Hash -eq $beforeState.Hash -and (Test-Path (Join-Path $interruptedRoot '.deploying-old-alpha/SKILL.md'))) 'dry run preserves state and old directory'
    $r = Invoke-Deploy $repo $interruptedHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Preserved interrupted') 'apply explicitly reports preservation of the old directory'
    $preserved = @(Get-ChildItem -LiteralPath (Join-Path $interruptedHome 'state/skill-backups') -Recurse -File -Filter SKILL.md | Where-Object { $_.FullName -match '[\\/]interrupted[\\/]Claude[\\/]alpha[\\/]' })
    Assert-TestCondition ($preserved.Count -gt 0 -and (Get-Content -Raw $preserved[0].FullName) -eq "# alpha v2`n") 'old content is copied to a backup before its leftover is removed'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $interruptedRoot 'alpha/SKILL.md')) -eq "# alpha v5`n") 'selected skill is installed after preserving the interrupted old directory'
    Set-TestFile (Join-Path $repo 'claude/skills/alpha/SKILL.md') "# alpha v2`n"

    $blockedHome = Join-Path $work 'backup-blocked-home'
    $r = Invoke-Deploy $repo $blockedHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) 'backup failure fixture is initially deployed'
    $blockedRoot = Join-Path $blockedHome '.claude/skills'
    Rename-Item -LiteralPath (Join-Path $blockedRoot 'alpha') -NewName '.deploying-old-alpha'
    Set-TestFile (Join-Path $blockedHome 'state/skill-backups') 'blocks backup directory'
    $r = Invoke-Deploy $repo $blockedHome @('-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and (Get-Content -Raw (Join-Path $blockedRoot '.deploying-old-alpha/SKILL.md')) -eq "# alpha v2`n") 'backup failure leaves the interrupted old directory untouched'

    Write-Host '[Zcode projects the Claude generated output]'
    $zcodeRoot = Join-Path $homeDir '.zcode/skills'
    Set-TestFile (Join-Path $zcodeRoot 'hand-made-z/SKILL.md') 'manual'
    Set-TestEnvironment $repo @('alpha') @('alpha')
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Zcode\s+install\s+alpha' -and $r.Out -match 'Zcode\s+unknown\s+hand-made-z') 'zcode plans install from the projection and reports unknown dirs'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (Get-Content -Raw (Join-Path $zcodeRoot 'alpha/SKILL.md')) -eq "# alpha v2`n") 'zcode installs the Claude generated content'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $zcodeRoot 'hand-made-z/SKILL.md')) -eq 'manual') 'zcode unknown dir untouched'
    $state = Get-Content -Raw (Join-Path $homeDir 'state/deployed-skills.json') | ConvertFrom-Json
    Assert-TestCondition ((@($state.Zcode) -join ',') -eq 'alpha') 'state records the Zcode set'
    Set-TestEnvironment $repo @('alpha') @()
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Zcode\s+prune\s+alpha' -and (Get-Content -Raw (Join-Path $zcodeRoot 'hand-made-z/SKILL.md')) -eq 'manual') 'deselecting prunes the zcode-deployed dir but keeps unknown dirs'
    Set-TestEnvironment $repo @('alpha') @('alpha')
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Set-TestFile (Join-Path $repo 'claude/skills/alpha/SKILL.md') "# alpha v4`n"
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'update Zcode/alpha') 'a changed Claude projection updates Zcode'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $zcodeRoot 'alpha/SKILL.md')) -eq "# alpha v4`n" -and (Get-Content -Raw (Join-Path $homeDir '.codex/skills/alpha/SKILL.md')) -eq "# alpha v3`n") 'zcode follows the Claude output while Codex keeps its own'
    Set-TestEnvironment $repo @('alpha') @()
    Set-TestFile (Join-Path $repo 'codex/skills/gamma/SKILL.md') "# gamma v1`n"
    Set-TestEnvironment $repo @('alpha') @('gamma')
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'no generated output for Zcode') 'a Zcode selection without Claude output is refused'
    Set-TestEnvironment $repo @('alpha') @()

    Write-Host '[malformed environments are refused]'
    $envFile = Join-Path $repo 'harness-source/envs/test.psd1'
    $good = [IO.File]::ReadAllText($envFile)
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Claude = @('alpha'); Codx = @('alpha'); Zcode = @() } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'exactly the keys') 'a misspelled platform key is refused instead of pruning everything'
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Claude = @('alpha.'); Codex = @('alpha'); Zcode = @() } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'invalid skill name') 'a trailing-dot name is refused'
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Claude = @('alpha'); Codex = @('alpha') } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'exactly the keys') 'an env without the Zcode key is refused'
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Claude = @('alpha'); Codex = @('alpha'); Zcode = @(); Reasonix = @() } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'exactly the keys') 'an env with a retired platform key is refused'
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
