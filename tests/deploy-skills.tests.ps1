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

function Set-TestEnvironment([string] $Repo, [string[]] $Skills) {
    $list = ($Skills | ForEach-Object { "'$_'" }) -join ', '
    Set-TestFile (Join-Path $Repo 'harness-source/envs/test.psd1') "@{ Skills = @{ Codex = @($list) } }"
}
function Invoke-Deploy([string] $Repo, [string] $HomeDir, [string[]] $Extra = @()) {
    Invoke-TestProcess -ScriptPath $deploy -Arguments (@('-Environment', 'test', '-RepoRoot', $Repo, '-HomeRoot', $HomeDir, '-StateRoot', (Join-Path $HomeDir 'state'), '-SkipBuild') + $Extra)
}
function Invoke-DeployInProcess([string] $Repo, [string] $HomeDir, [string[]] $Extra = @()) {
    $invArgs = @{
        Environment = 'test'
        RepoRoot    = $Repo
        HomeRoot    = $HomeDir
        StateRoot   = (Join-Path $HomeDir 'state')
        SkipBuild   = $true
    }
    $retire = @()
    for ($i = 0; $i -lt $Extra.Count; $i++) {
        if ($Extra[$i] -eq '-Apply') { $invArgs['Apply'] = $true }
        elseif ($Extra[$i] -eq '-Retire' -and ($i + 1) -lt $Extra.Count) { $retire += $Extra[++$i] }
        else { throw "Unsupported Invoke-DeployInProcess argument: $($Extra[$i])" }
    }
    if ($retire.Count -gt 0) { $invArgs['Retire'] = $retire }
    try {
        $out = @(& $deploy @invArgs *>&1 | ForEach-Object { [string] $_ })
        return [pscustomobject]@{ Code = 0; Out = ($out -join "`n") }
    }
    catch {
        return [pscustomobject]@{ Code = 1; Out = $_.Exception.Message }
    }
}
function Get-LiveRoots([string] $HomeDir) {
    @((Join-Path $HomeDir '.codex/skills'))
}

try {
    $repo = Join-Path $work 'repo'
    $homeDir = Join-Path $work 'home'
    foreach ($skill in 'alpha', 'beta') { Set-TestFile (Join-Path $repo "codex/skills/$skill/SKILL.md") "# $skill v1`n" }
    Set-TestEnvironment $repo @('alpha', 'beta')
    Set-TestFile (Join-Path $homeDir '.codex/skills/.system/marker.txt') 'platform'
    Set-TestFile (Join-Path $homeDir '.codex/skills/hand-made/SKILL.md') 'mine'

    Write-Host '[dry run writes nothing]'
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -eq 0) "dry run exits 0 ($($r.Out))"
    Assert-TestCondition ($r.Out -match 'install' -and $r.Out -match 'Dry run') 'dry run reports the planned installs'
    Assert-TestCondition (-not (Test-Path (Join-Path $homeDir '.codex/skills/alpha'))) 'dry run installs nothing'
    Assert-TestCondition (-not (Test-Path (Join-Path $homeDir 'state'))) 'dry run writes no state'

    Write-Host '[file preview explains changes without printing contents]'
    $previewRepo = Join-Path $work 'preview-repo'
    $previewHome = Join-Path $work 'preview-home'
    Set-TestEnvironment $previewRepo @('alpha')
    Set-TestFile (Join-Path $previewRepo 'codex/skills/alpha/SKILL.md') 'do-not-print-preview-body new'
    Set-TestFile (Join-Path $previewRepo 'codex/skills/alpha/references/added.md') 'do-not-print-preview-body added'
    Set-TestFile (Join-Path $previewRepo 'codex/skills/alpha/Case.md') 'same'
    Set-TestFile (Join-Path $previewHome '.codex/skills/alpha/SKILL.md') 'do-not-print-preview-body old'
    Set-TestFile (Join-Path $previewHome '.codex/skills/alpha/removed.md') 'do-not-print-preview-body removed'
    Set-TestFile (Join-Path $previewHome '.codex/skills/alpha/case.md') 'same'
    Set-TestFile (Join-Path $previewHome '.codex/skills/obsolete/SKILL.md') 'old'
    Set-TestFile (Join-Path $previewHome '.codex/skills/retired/SKILL.md') 'old'
    Set-TestFile (Join-Path $previewHome 'state/deployed-skills.json') '{"Environment":"full","Codex":["alpha","obsolete"]}'
    $r = Invoke-Deploy $previewRepo $previewHome @('-Retire', 'retired')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'change\s+SKILL.md' -and $r.Out -match 'add\s+references/added.md' -and $r.Out -match 'remove\s+removed.md') "preview identifies changed, added and removed relative files ($($r.Out))"
    Assert-TestCondition ($r.Out -cmatch 'add\s+Case.md' -and $r.Out -cmatch 'remove\s+case.md') 'preview retains case-only path changes'
    Assert-TestCondition ($r.Out -notmatch 'do-not-print-preview-body' -and $r.Out -notmatch [regex]::Escape($previewHome)) 'preview omits file bodies and full home paths'
    Assert-TestCondition ($r.Out -match "last recorded 'full' -> target 'test'" -and $r.Out -match 'Prune reason for Codex/obsolete: previously managed' -and $r.Out -match 'Prune reason for Codex/retired: explicit -Retire') 'environment transition and both prune causes are explicit'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $previewHome '.codex/skills/alpha/SKILL.md')) -eq 'do-not-print-preview-body old' -and (Test-Path (Join-Path $previewHome '.codex/skills/obsolete'))) 'detailed preview remains read-only'

    Write-Host '[plan summary counts mixed and empty plans]'
    $summaryHome = Join-Path $work 'summary-home'
    Set-TestFile (Join-Path $repo 'codex/skills/summary-extra/SKILL.md') "# summary-extra v1`n"
    Set-TestEnvironment $repo @('alpha', 'beta', 'summary-extra')
    Set-TestFile (Join-Path $summaryHome '.codex/skills/alpha/SKILL.md') "# alpha v1`n"
    Set-TestFile (Join-Path $summaryHome '.codex/skills/beta/SKILL.md') 'older beta'
    Set-TestFile (Join-Path $summaryHome '.codex/skills/obsolete/SKILL.md') 'obsolete'
    Set-TestFile (Join-Path $summaryHome '.codex/skills/manual/SKILL.md') 'manual'
    Set-TestFile (Join-Path $summaryHome 'state/deployed-skills.json') '{"Codex":["obsolete"]}'
    $summaryStateHash = (Get-FileHash (Join-Path $summaryHome 'state/deployed-skills.json')).Hash
    $r = Invoke-Deploy $repo $summaryHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Plan summary: install=1\s+update=1\s+unchanged=1\s+prune=1\s+unknown=1') 'mixed plan reports each action count'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $summaryHome '.codex/skills/beta/SKILL.md')) -eq 'older beta' -and (Test-Path (Join-Path $summaryHome '.codex/skills/obsolete/SKILL.md')) -and -not (Test-Path (Join-Path $summaryHome '.codex/skills/summary-extra')) -and (Get-FileHash (Join-Path $summaryHome 'state/deployed-skills.json')).Hash -eq $summaryStateHash) 'mixed dry run preserves live content and state'
    Set-TestEnvironment $repo @()
    $emptyHome = Join-Path $work 'empty-home'
    $r = Invoke-Deploy $repo $emptyHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Plan summary: install=0\s+update=0\s+unchanged=0\s+prune=0\s+unknown=0' -and -not (Test-Path $emptyHome)) 'empty plan reports zero counts without writing home or state'
    Assert-TestCondition ($r.Out -cmatch 'Codex live root: ~/\.codex/skills' -and $r.Out -notmatch [regex]::Escape($emptyHome)) 'a no-action preview still shows the chosen live root home-relative'
    Set-TestEnvironment $repo @('alpha', 'beta')

    Write-Host '[review updates absent from deploy state]'
    $reviewHome = Join-Path $work 'review-home'
    Set-TestFile (Join-Path $reviewHome '.codex/skills/alpha/SKILL.md') 'existing content'
    $r = Invoke-Deploy $repo $reviewHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Update not recorded in deploy state: Codex/alpha' -and $r.Out -match 'ownership is unknown') 'missing state warns of an update without claiming ownership'
    Set-TestFile (Join-Path $reviewHome 'state/deployed-skills.json') '{"Codex":[]}'
    $r = Invoke-Deploy $repo $reviewHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Update not recorded in deploy state: Codex/alpha') 'existing state without the name warns'
    Set-TestFile (Join-Path $reviewHome 'state/deployed-skills.json') '{"Codex":["alpha"]}'
    $r = Invoke-Deploy $repo $reviewHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -notmatch 'Update not recorded in deploy state: Codex/alpha') 'state-recorded updates do not produce the warning'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $reviewHome '.codex/skills/alpha/SKILL.md')) -eq 'existing content') 'review does not change the existing directory'

    Write-Host '[selected names that collide with ordinary files are refused]'
    Set-TestEnvironment $repo @('alpha', 'beta')
    foreach ($mode in @('dry-run', 'apply')) {
        $collisionHome = Join-Path $work "collision-codex-$mode"
        $collision = Join-Path $collisionHome '.codex/skills/beta'
        Set-TestFile $collision 'preserve this ordinary file'
        $extra = @()
        if ($mode -eq 'apply') { $extra = @('-Apply') }
        $r = Invoke-Deploy $repo $collisionHome $extra
        Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'live-skill-target-not-directory') "codex $mode rejects a selected ordinary file (exit $($r.Code): $($r.Out))"
        Assert-TestCondition ((Test-Path -LiteralPath $collision -PathType Leaf) -and (Get-Content -Raw -LiteralPath $collision) -ceq 'preserve this ordinary file') "codex $mode preserves the conflicting file"
        Assert-TestCondition (-not (Test-Path (Join-Path $collisionHome '.codex/skills/alpha')) -and -not (Test-Path (Join-Path $collisionHome 'state'))) "codex $mode rejects the entire plan before any installation or state write"
    }
    Set-TestEnvironment $repo @('alpha', 'beta')

    Write-Host '[first apply installs selected platforms]'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) "first apply exits 0 ($($r.Out))"
    foreach ($root in Get-LiveRoots $homeDir) {
        Assert-TestCondition ((Get-Content -Raw (Join-Path $root 'alpha/SKILL.md')) -eq "# alpha v1`n") "alpha installed under $root"
        Assert-TestCondition (-not @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object Name -like '.deploying-*')) "no staging left under $root"
    }
    Assert-TestCondition ((Get-Content -Raw (Join-Path $homeDir '.codex/skills/.system/marker.txt')) -eq 'platform') 'Codex .system untouched'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $homeDir '.codex/skills/hand-made/SKILL.md')) -eq 'mine') 'unknown live skill untouched'
    $state = Get-Content -Raw (Join-Path $homeDir 'state/deployed-skills.json') | ConvertFrom-Json
    Assert-TestCondition ((@($state.Codex) -join ',') -eq 'alpha,beta') 'state records the deployed set'

    Write-Host '[state write failure preserves existing state]'
    $writeFailureHome = Join-Path $work 'state-write-failure-home'
    $writeFailureState = Join-Path $writeFailureHome 'state/deployed-skills.json'
    Set-TestFile $writeFailureState '{"Environment":"previous","Codex":[]}'
    $oldWriteHash = (Get-FileHash -LiteralPath $writeFailureState).Hash
    $writeFailureHarness = Join-Path $work 'fail-state-write.ps1'
    Set-TestFile $writeFailureHarness @'
param([string] $Deploy, [string] $Repo, [string] $HomeDir)
$ErrorActionPreference = 'Stop'
function Set-Content {
    param([string] $LiteralPath, [string] $Encoding, [Parameter(ValueFromPipeline = $true)] $Value)
    process {
        Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value '{"partial":' -Encoding utf8
        throw 'injected partial state write failure'
    }
}
try {
    & $Deploy -Environment test -RepoRoot $Repo -HomeRoot $HomeDir -StateRoot (Join-Path $HomeDir 'state') -SkipBuild -Apply
    exit 0
}
catch { Write-Error $_ -ErrorAction Continue; exit 1 }
'@
    Set-TestEnvironment $repo @('alpha')
    $r = Invoke-TestProcess -ScriptPath $writeFailureHarness -Arguments @($deploy, $repo, $writeFailureHome)
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'injected partial state write failure') 'injected partial state write fails the Apply'
    Assert-TestCondition ((Get-FileHash -LiteralPath $writeFailureState).Hash -eq $oldWriteHash) 'partial state write leaves previous state unchanged'
    Assert-TestCondition (Test-Path (Join-Path $writeFailureHome '.codex/skills/alpha/SKILL.md')) 'completed skill installs remain after state write failure'
    Assert-TestCondition ($r.Out -match 'Live changes may already have occurred' -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $writeFailureState) -Filter 'deployed-skills.*.tmp').Count -eq 0) 'failure warns about live changes and removes its temporary state'

    Write-Host '[blocked state replacement preserves existing state]'
    $replacementLock = [IO.File]::Open($writeFailureState, 'Open', 'Read', 'Read')
    try { $r = Invoke-Deploy $repo $writeFailureHome @('-Apply') } finally { $replacementLock.Dispose() }
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'Deployment state update failed' -and (Get-FileHash -LiteralPath $writeFailureState).Hash -eq $oldWriteHash) 'blocked replacement fails and preserves the old state'
    Assert-TestCondition (@(Get-ChildItem -LiteralPath (Split-Path -Parent $writeFailureState) -Filter 'deployed-skills.*.tmp').Count -eq 0) 'blocked replacement removes its temporary state'
    $r = Invoke-Deploy $repo $writeFailureHome @('-Apply')
    $updatedState = Get-Content -Raw -LiteralPath $writeFailureState | ConvertFrom-Json
    Assert-TestCondition ($r.Code -eq 0 -and $updatedState.Environment -eq 'test') "retry replaces the existing state after the lock is released (exit $($r.Code), environment $($updatedState.Environment), output: $($r.Out))"
    $file = Join-Path $writeFailureHome '.codex/skills/alpha/SKILL.md'
    Assert-TestCondition ($updatedState.Codex.Count -eq 0 -and (Get-Content -Raw -LiteralPath $file) -ceq "# alpha v1`n") 'retry preserves the Codex skill without a recorded owner'

    Write-Host '[invalid deployment state paths stop planning before any write]'
    $blockedStateHome = Join-Path $work 'blocked-state-home'
    $blockedStateRoot = Join-Path $blockedStateHome 'state'
    Set-TestFile $blockedStateRoot 'not a directory'
    $pathArgs = @('-Environment', 'test', '-RepoRoot', $repo, '-HomeRoot', $blockedStateHome, '-StateRoot', $blockedStateRoot)
    foreach ($modeArgs in @($pathArgs, ($pathArgs + '-Apply'))) {
        $r = Invoke-TestProcess -ScriptPath $deploy -Arguments $modeArgs
        Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'state-root-not-directory') 'a file occupying StateRoot stops the planner before build'
        Assert-TestCondition ((Get-Content -Raw -LiteralPath $blockedStateRoot) -ceq 'not a directory' -and -not (Test-Path (Join-Path $blockedStateHome '.codex'))) 'planning preserves the file and the empty home'
    }
    $directoryStateHome = Join-Path $work 'directory-state-home'
    New-Item -ItemType Directory -Path (Join-Path $directoryStateHome 'state/deployed-skills.json') -Force | Out-Null
    $r = Invoke-Deploy $repo $directoryStateHome
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'state-path-is-directory') 'preview identifies a directory occupying the state file'
    Set-TestEnvironment $repo @('alpha', 'beta')

    Write-Host '[present invalid state cannot authorize prune or write]'
    $invalidStateHome = Join-Path $work 'invalid-state-home'
    Set-TestFile (Join-Path $invalidStateHome '.codex/skills/alpha/SKILL.md') 'live alpha'
    Set-TestFile (Join-Path $invalidStateHome '.codex/skills/stray/SKILL.md') 'live stray'
    $invalidStatePath = Join-Path $invalidStateHome 'state/deployed-skills.json'
    $invalidStates = @(
        '{"Environment":"test","Codex":"stray"}',
        '{"Environment":"test"}',
        '{"Environment":"test","Codex":["stray",5]}',
        '{"Environment":"test","Codex":[""]}',
        '[{"Environment":"test","Codex":["stray"]}]',
        '{"Environment":"test","Codex":["stray","bad/name"]}',
        '[]'
    )
    for ($i = 0; $i -lt $invalidStates.Count; $i++) {
        $invalidState = $invalidStates[$i]
        # Keep the first invalid-state case as a full child-pwsh subprocess run; run the rest in-process.
        $invoke = if ($i -eq 0) { ${function:Invoke-Deploy} } else { ${function:Invoke-DeployInProcess} }
        Set-TestFile $invalidStatePath $invalidState
        $invalidStateHash = (Get-FileHash -LiteralPath $invalidStatePath).Hash
        $r = & $invoke $repo $invalidStateHome
        Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'deploy-state-invalid-state' -and $r.Out -notmatch '(?m)^\s*Codex\s+prune\s+') "a present invalid state plans no prune: $invalidState"
        $r = & $invoke $repo $invalidStateHome @('-Apply')
        Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'deploy-state-invalid-state' -and (Get-FileHash -LiteralPath $invalidStatePath).Hash -eq $invalidStateHash) "a present invalid state blocks Apply without rewriting state: $invalidState"
        Assert-TestCondition ((Get-Content -Raw (Join-Path $invalidStateHome '.codex/skills/stray/SKILL.md')) -eq 'live stray' -and -not (Test-Path (Join-Path $invalidStateHome 'state/skill-backups')) -and -not (Test-Path (Join-Path $invalidStateHome '.codex/skills/beta'))) "a present invalid state authorizes no live write: $invalidState"
        $r = & $invoke $repo $invalidStateHome @('-Retire', 'stray')
        Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'deploy-state-invalid-state' -and (Test-Path (Join-Path $invalidStateHome '.codex/skills/stray/SKILL.md'))) "an invalid state cannot authorize even an explicit retire: $invalidState"
    }
    $unreadableStateHome = Join-Path $work 'unreadable-state-home'
    Set-TestFile (Join-Path $unreadableStateHome '.codex/skills/alpha/SKILL.md') 'live alpha'
    $unreadableStatePath = Join-Path $unreadableStateHome 'state/deployed-skills.json'
    Set-TestFile $unreadableStatePath '{"Environment":"test","Codex":["stray"]}'
    $unreadableHash = (Get-FileHash -LiteralPath $unreadableStatePath).Hash
    $unreadableLock = [IO.File]::Open($unreadableStatePath, 'Open', 'Read', 'None')
    try { $r = Invoke-Deploy $repo $unreadableStateHome @('-Apply') } finally { $unreadableLock.Dispose() }
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'deploy-state-read-error' -and (Get-FileHash -LiteralPath $unreadableStatePath).Hash -eq $unreadableHash) 'an unreadable present state blocks Apply before writes'
    Set-TestFile $invalidStatePath '{"Codex":["stray"]}'
    $r = Invoke-Deploy $repo $invalidStateHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match "last recorded 'unavailable'" -and $r.Out -match 'Codex\s+prune\s+stray') 'legacy valid Codex ownership without Environment still authorizes its recorded prune'

    Write-Host '[retiring a selected skill is refused before build]'
    $retireHome = Join-Path $work 'retire-selected-home'
    Set-TestFile (Join-Path $retireHome '.codex/skills/alpha/SKILL.md') 'live alpha'
    foreach ($mode in @(@(), @('-Apply'))) {
        $r = Invoke-Deploy $repo $retireHome (@('-Retire', 'alpha') + $mode)
        Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'retire-selected-skill: -Retire names .alpha., which the environment .test. still selects') "retiring selected alpha is refused ($($mode -join ' '))"
        Assert-TestCondition ((Get-Content -Raw (Join-Path $retireHome '.codex/skills/alpha/SKILL.md')) -eq 'live alpha' -and -not (Test-Path (Join-Path $retireHome 'state'))) "the refusal writes nothing ($($mode -join ' '))"
    }
    $noBuildRepo = Join-Path $work 'no-build-repo'
    Set-TestEnvironment $noBuildRepo @('alpha')
    Set-TestFile (Join-Path $noBuildRepo 'codex/skills/alpha/SKILL.md') 'generated'
    $r = Invoke-TestProcess -ScriptPath $deploy -Arguments @('-Environment', 'test', '-RepoRoot', $noBuildRepo, '-HomeRoot', $retireHome, '-StateRoot', (Join-Path $retireHome 'state'), '-Retire', 'alpha')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'retire-selected-skill' -and $r.Out -notmatch 'build-skills failed') 'the refusal happens before the build stage'
    Assert-TestCondition (-not (Test-Path (Join-Path $retireHome 'state'))) 'the pre-build refusal still writes no state'

    Write-Host '[identical manual skill stays unowned when deselected]'
    $manualHome = Join-Path $work 'matching-manual-home'
    $manualFile = Join-Path $manualHome '.codex/skills/alpha/SKILL.md'
    Set-TestFile $manualFile "# alpha v1`n"
    $r = Invoke-Deploy $repo $manualHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Codex\s+unchanged\s+alpha' -and $r.Out -match 'install Codex/beta') 'deployment preserves the matching manual skill and installs the control'
    Set-TestEnvironment $repo @()
    $r = Invoke-Deploy $repo $manualHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Codex\s+unknown\s+alpha' -and $r.Out -match 'Codex\s+prune\s+beta') 'deselection preview distinguishes the manual skill from the installed control'
    $r = Invoke-Deploy $repo $manualHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (Get-Content -Raw -LiteralPath $manualFile) -ceq "# alpha v1`n" -and -not (Test-Path (Join-Path $manualHome '.codex/skills/beta'))) 'deselection preserves the manual file and removes the installed control'
    Set-TestEnvironment $repo @('alpha', 'beta')

    Write-Host '[lost state does not authorize pruning]'
    $lostStateHome = Join-Path $work 'lost-state-home'
    Set-TestFile (Join-Path $lostStateHome '.codex/skills/.system/marker.txt') 'platform'
    $r = Invoke-Deploy $repo $lostStateHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) 'lost-state fixture starts with both managed skills'
    Remove-Item -LiteralPath (Join-Path $lostStateHome 'state/deployed-skills.json')
    Set-TestEnvironment $repo @('alpha')
    $r = Invoke-Deploy $repo $lostStateHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Codex\s+unknown\s+beta' -and $r.Out -notmatch '(?m)^\s*Codex\s+prune\s+beta') 'previously deployed beta becomes unknown when state is lost'
    $r = Invoke-Deploy $repo $lostStateHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (Test-Path (Join-Path $lostStateHome '.codex/skills/beta/SKILL.md'))) 'apply preserves formerly managed directories that are now unknown'
    $r = Invoke-Deploy $repo $lostStateHome @('-Retire', 'beta')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Codex\s+prune\s+beta' -and (Test-Path (Join-Path $lostStateHome '.codex/skills/beta/SKILL.md'))) 'explicit retire is visible in dry run without removing beta'
    $r = Invoke-Deploy $repo $lostStateHome @('-Apply', '-Retire', 'beta')
    Assert-TestCondition ($r.Code -eq 0 -and -not (Test-Path (Join-Path $lostStateHome '.codex/skills/beta')) -and (Get-Content -Raw (Join-Path $lostStateHome '.codex/skills/.system/marker.txt')) -eq 'platform') 'explicit retirement removes beta while preserving .system'
    Set-TestEnvironment $repo @('alpha', 'beta')

    Write-Host '[legacy state is ignored and retired on apply]'
    $statePath = Join-Path $homeDir 'state/deployed-skills.json'
    $oldState = Get-Content -Raw $statePath | ConvertFrom-Json -AsHashtable
    $oldState['Reasonix'] = @('alpha')
    $oldState['Claude'] = @('legacy-skill')
    $oldState['Zcode'] = @('legacy-skill')
    Set-TestFile $statePath ($oldState | ConvertTo-Json)
    $stateHash = (Get-FileHash -LiteralPath $statePath).Hash
    $legacyFile = Join-Path $homeDir 'AppData/Roaming/reasonix/skills/alpha/SKILL.md'
    Set-TestFile $legacyFile 'legacy bytes'
    $retiredClaudeFile = Join-Path $homeDir '.claude/skills/legacy-skill/SKILL.md'
    $retiredZcodeFile = Join-Path $homeDir '.zcode/skills/legacy-skill/SKILL.md'
    $independentFile = Join-Path $homeDir '.codex/skills/legacy-skill/SKILL.md'
    Set-TestFile $retiredClaudeFile 'retired claude bytes'
    Set-TestFile $retiredZcodeFile 'retired zcode bytes'
    Set-TestFile $independentFile 'manually installed'
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -eq 0 -and (Get-FileHash -LiteralPath $statePath).Hash -eq $stateHash -and (Get-Content -Raw $legacyFile) -eq 'legacy bytes') 'dry run ignores legacy state without changing it or the retired root'
    Assert-TestCondition ($r.Out -notmatch 'Claude|Zcode' -and $r.Out -match 'Codex\s+unknown\s+legacy-skill') 'retired state grants no ownership of the same Codex name'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    $state = Get-Content -Raw $statePath | ConvertFrom-Json -AsHashtable
    Assert-TestCondition ($r.Code -eq 0 -and -not $state.ContainsKey('Reasonix') -and (Get-Content -Raw $legacyFile) -eq 'legacy bytes') 'apply writes active state only and preserves the retired root'
    Assert-TestCondition (-not $state.ContainsKey('Claude') -and -not $state.ContainsKey('Zcode') -and (Get-Content -Raw $retiredClaudeFile) -ceq 'retired claude bytes' -and (Get-Content -Raw $retiredZcodeFile) -ceq 'retired zcode bytes' -and (Get-Content -Raw $independentFile) -ceq 'manually installed') 'old Claude and Zcode state is discarded without changing live directories'

    Write-Host '[second apply is a no-op]'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'unchanged' -and $r.Out -notmatch '(?m)^(install|update|prune) ') 'unchanged skills are left alone'

    Write-Host '[changed source updates with a backup]'
    Set-TestFile (Join-Path $repo 'codex/skills/alpha/SKILL.md') "# alpha v2`n"
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'update Codex/alpha') 'changed skill is updated'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $homeDir '.codex/skills/alpha/SKILL.md')) -eq "# alpha v2`n") 'live copy has the new content'
    $backup = @(Get-ChildItem -LiteralPath (Join-Path $homeDir 'state/skill-backups') -Recurse -File -Filter SKILL.md | Where-Object { $_.FullName -match 'Codex[\\/]alpha' })
    Assert-TestCondition ($backup.Count -eq 1 -and (Get-Content -Raw $backup[0].FullName) -eq "# alpha v1`n") 'the previous copy is backed up'

    Write-Host '[deselected skill is pruned; unknown stays]'
    Set-TestEnvironment $repo @('alpha')
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'prune Codex/beta') 'deselected skill is pruned'
    foreach ($root in Get-LiveRoots $homeDir) { Assert-TestCondition (-not (Test-Path (Join-Path $root 'beta'))) "beta removed from $root" }
    Assert-TestCondition (Test-Path (Join-Path $homeDir '.codex/skills/hand-made')) 'unknown skill still untouched after prune'
    Assert-TestCondition (Test-Path (Join-Path $homeDir '.codex/skills/.system/marker.txt')) '.system still untouched after prune'

    Write-Host '[explicit retire removes a named unknown skill]'
    $r = Invoke-Deploy $repo $homeDir @('-Retire', 'hand-made')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'prune' -and (Test-Path (Join-Path $homeDir '.codex/skills/hand-made'))) 'retire is only planned on dry run'
    $r = Invoke-Deploy $repo $homeDir @('-Apply', '-Retire', 'hand-made')
    Assert-TestCondition ($r.Code -eq 0 -and -not (Test-Path (Join-Path $homeDir '.codex/skills/hand-made'))) 'retire removes the named skill on apply'
    $r = Invoke-Deploy $repo $homeDir @('-Apply', '-Retire', '.system')
    Assert-TestCondition ($r.Code -ne 0 -and (Test-Path (Join-Path $homeDir '.codex/skills/.system/marker.txt'))) '.system can never be retired'

    Write-Host '[preview names the chosen live root home-relative]'
    $preferredPreviewHome = Join-Path $work 'root-preview-home'
    New-Item -ItemType Directory -Path (Join-Path $preferredPreviewHome '.codex/skills') -Force | Out-Null
    Set-TestFile (Join-Path $preferredPreviewHome '.codex/skills/stray/SKILL.md') 'stray'
    $r = Invoke-Deploy $repo $preferredPreviewHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -cmatch 'Codex live root: ~/\.codex/skills' -and $r.Out -notmatch 'fallback') 'the preferred root is chosen and shown home-relative'
    Assert-TestCondition ($r.Out -notmatch [regex]::Escape($preferredPreviewHome)) 'the live-root preview omits the machine-private home path'
    $fallbackPreviewHome = Join-Path $work 'root-preview-fallback-home'
    New-Item -ItemType Directory -Path (Join-Path $fallbackPreviewHome '.agents/skills') -Force | Out-Null
    $r = Invoke-Deploy $repo $fallbackPreviewHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -cmatch 'Codex live root: ~/\.agents/skills \(fallback; ~/\.codex/skills is absent\)' -and $r.Out -notmatch [regex]::Escape($fallbackPreviewHome)) 'the fallback root is identified home-relative'

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
    Assert-TestCondition ((Test-Path (Join-Path $homeDir '.codex/skills/alpha/refs/a.md')) -and (Get-Content -Raw (Join-Path $homeDir '.codex/skills/alpha/SKILL.md')) -eq "# alpha v2`n") 'the live skill is left whole'
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (Get-Content -Raw (Join-Path $homeDir '.codex/skills/alpha/SKILL.md')) -eq "# alpha v3`n") 'the next run completes the update'
    Assert-TestCondition (-not @(Get-ChildItem -LiteralPath (Join-Path $homeDir '.codex/skills') -Directory -Force | Where-Object Name -like '.deploying-*')) 'leftover staging is cleaned'

    Write-Host '[interrupted update preserves the old directory]'
    $interruptedHome = Join-Path $work 'interrupted-home'
    $r = Invoke-Deploy $repo $interruptedHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) 'interrupted fixture is initially deployed'
    $interruptedRoot = Join-Path $interruptedHome '.codex/skills'
    $oldStatePath = Join-Path $interruptedHome 'state/deployed-skills.json'
    $beforeState = Get-FileHash -LiteralPath $oldStatePath
    New-Item -ItemType Directory -Path (Join-Path $interruptedHome 'state/skill-backups/prior/Codex') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $interruptedRoot 'alpha') -Destination (Join-Path $interruptedHome 'state/skill-backups/prior/Codex/alpha') -Recurse -Force
    Rename-Item -LiteralPath (Join-Path $interruptedRoot 'alpha') -NewName '.deploying-old-alpha'
    Set-TestFile (Join-Path $repo 'codex/skills/alpha/SKILL.md') "# alpha v5`n"
    Copy-Item -LiteralPath (Join-Path $repo 'codex/skills/alpha') -Destination (Join-Path $interruptedRoot '.deploying-alpha') -Recurse
    $r = Invoke-Deploy $repo $interruptedHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'interrupted' -and $r.Out -match '\.deploying-old-alpha' -and $r.Out -match 'skill-backups') 'dry run reports interrupted remnants and backup location'
    Assert-TestCondition ((Get-FileHash -LiteralPath $oldStatePath).Hash -eq $beforeState.Hash -and (Test-Path (Join-Path $interruptedRoot '.deploying-old-alpha/SKILL.md'))) 'dry run preserves state and old directory'
    $r = Invoke-Deploy $repo $interruptedHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'Preserved interrupted') 'apply explicitly reports preservation of the old directory'
    $preserved = @(Get-ChildItem -LiteralPath (Join-Path $interruptedHome 'state/skill-backups') -Recurse -File -Filter SKILL.md | Where-Object { $_.FullName -match '[\\/]interrupted[\\/]Codex[\\/]alpha[\\/]' })
    Assert-TestCondition ($preserved.Count -gt 0 -and (Get-Content -Raw $preserved[0].FullName) -eq "# alpha v3`n") 'old content is copied to a backup before its leftover is removed'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $interruptedRoot 'alpha/SKILL.md')) -eq "# alpha v5`n") 'selected skill is installed after preserving the interrupted old directory'
    Set-TestFile (Join-Path $repo 'codex/skills/alpha/SKILL.md') "# alpha v3`n"

    $blockedHome = Join-Path $work 'backup-blocked-home'
    $r = Invoke-Deploy $repo $blockedHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) 'backup failure fixture is initially deployed'
    $blockedRoot = Join-Path $blockedHome '.codex/skills'
    Rename-Item -LiteralPath (Join-Path $blockedRoot 'alpha') -NewName '.deploying-old-alpha'
    Set-TestFile (Join-Path $blockedHome 'state/skill-backups') 'blocks backup directory'
    $r = Invoke-Deploy $repo $blockedHome @('-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and (Get-Content -Raw (Join-Path $blockedRoot '.deploying-old-alpha/SKILL.md')) -eq "# alpha v3`n") 'backup failure leaves the interrupted old directory untouched'

    Write-Host '[overlapping temporary names preserve interrupted data]'
    $overlapHome = Join-Path $work 'overlap-home'
    Set-TestFile (Join-Path $repo 'codex/skills/old-alpha/SKILL.md') "# old-alpha v1`n"
    Set-TestEnvironment $repo @('alpha', 'old-alpha')
    $r = Invoke-Deploy $repo $overlapHome @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) 'overlap fixture deploys alpha and old-alpha'
    $overlapRoot = Join-Path $overlapHome '.codex/skills'
    Rename-Item -LiteralPath (Join-Path $overlapRoot 'alpha') -NewName '.deploying-old-alpha'
    Set-TestFile (Join-Path $repo 'codex/skills/old-alpha/SKILL.md') "# old-alpha v2`n"
    Set-TestEnvironment $repo @('old-alpha')
    $r = Invoke-Deploy $repo $overlapHome
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match '\.deploying-old-alpha') 'dry run reports the ambiguous interrupted directory'
    $overlapLock = [IO.File]::Open((Join-Path $overlapRoot '.deploying-old-alpha/SKILL.md'), 'Open', 'Read', 'None')
    try { $r = Invoke-Deploy $repo $overlapHome @('-Apply') } finally { $overlapLock.Dispose() }
    Assert-TestCondition ($r.Code -ne 0 -and (Get-Content -Raw (Join-Path $overlapRoot '.deploying-old-alpha/SKILL.md')) -eq "# alpha v3`n" -and (Get-Content -Raw (Join-Path $overlapRoot 'old-alpha/SKILL.md')) -eq "# old-alpha v1`n") 'failed staging backup leaves both the interrupted data and current target intact'
    $r = Invoke-Deploy $repo $overlapHome @('-Apply')
    $overlapBackups = @(Get-ChildItem -LiteralPath (Join-Path $overlapHome 'state/skill-backups') -Recurse -File -Filter SKILL.md | Where-Object { $_.FullName -match '[\\/]interrupted-staging[\\/]Codex[\\/]old-alpha[\\/]' })
    Assert-TestCondition ($r.Code -eq 0 -and $overlapBackups.Count -eq 1 -and (Get-Content -Raw $overlapBackups[0].FullName) -eq "# alpha v3`n") 'ambiguous staging name is backed up before it is removed'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $overlapRoot 'old-alpha/SKILL.md')) -eq "# old-alpha v2`n") 'the requested update still completes'
    Set-TestEnvironment $repo @('alpha')

    Write-Host '[selection without generated output is refused]'
    Set-TestEnvironment $repo @('alpha', 'missing-skill')
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'no generated output for Codex') 'a Codex selection without its generated output is refused'
    Set-TestEnvironment $repo @('alpha')

    Write-Host '[malformed environments are refused]'
    $envFile = Join-Path $repo 'harness-source/envs/test.psd1'
    $good = [IO.File]::ReadAllText($envFile)
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Codx = @('alpha') } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'exactly the key Codex') 'a misspelled platform key is refused instead of pruning everything'
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Codex = @('alpha.') } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'invalid skill name') 'a trailing-dot name is refused'
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Codex = @('') } }")
    $stateFile = Join-Path $homeDir 'state/deployed-skills.json'
    $stateHash = (Get-FileHash -LiteralPath $stateFile).Hash
    $r = Invoke-Deploy $repo $homeDir @('-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'invalid skill name' -and (Test-Path -LiteralPath (Join-Path $homeDir '.codex/skills/alpha/SKILL.md')) -and (Get-FileHash -LiteralPath $stateFile).Hash -eq $stateHash) 'a blank skill name cannot prune a managed skill or publish empty state'
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Codex = @('alpha'); Zcode = @() } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'exactly the key Codex') 'an env with retired Zcode key is refused'
    [IO.File]::WriteAllText($envFile, "@{ Skills = @{ Codex = @('alpha'); Claude = @() } }")
    $r = Invoke-Deploy $repo $homeDir
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'exactly the key Codex') 'an env with a retired platform key is refused'
    [IO.File]::WriteAllText($envFile, $good)

    Write-Host '[reparse points are refused]'
    $outside = Join-Path $work 'outside'
    Set-TestFile (Join-Path $outside 'sentinel.txt') 'keep'
    $junctionHome = Join-Path $work 'junction-home'
    New-Item -ItemType Directory -Path (Join-Path $junctionHome '.codex/skills') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $junctionHome '.codex/skills/alpha') -Target $outside | Out-Null
    $r = Invoke-Deploy $repo $junctionHome @('-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'reparse-point-refused') 'a junction under a live root is refused'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $outside 'sentinel.txt')) -eq 'keep' -and @(Get-ChildItem $outside).Count -eq 1) 'the junction target is untouched'

    Write-Host '[ancestor reparse points, environment validation, and multi-retire]'
    $ancestorJuncHome = Join-Path $work 'ancestor-junc-home'
    New-Item -ItemType Directory -Path $ancestorJuncHome -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $ancestorJuncHome '.codex') -Target $outside | Out-Null
    $r = Invoke-Deploy $repo $ancestorJuncHome
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'reparse-point-refused') 'a junction on ~/.codex ancestor is refused even when skills subdir is missing'

    $stateJuncHome = Join-Path $work 'state-junc-home'
    New-Item -ItemType Directory -Path $stateJuncHome -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $stateJuncHome 'state') -Target $outside | Out-Null
    $r = Invoke-Deploy $repo $stateJuncHome
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'reparse-point-refused') 'a junction StateRoot is refused'

    foreach ($badEnv in @('../test', 'bad env')) {
        $r = Invoke-TestProcess -ScriptPath $deploy -Arguments @('-Environment', $badEnv, '-RepoRoot', $repo, '-HomeRoot', $homeDir, '-StateRoot', (Join-Path $homeDir 'state'), '-SkipBuild')
        Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'invalid environment name') "invalid environment name '$badEnv' is refused"
    }

    Set-TestFile (Join-Path $repo 'harness-source/envs/noskills.psd1') '@{ Description = "missing skills" }'
    $r = Invoke-TestProcess -ScriptPath $deploy -Arguments @('-Environment', 'noskills', '-RepoRoot', $repo, '-HomeRoot', $homeDir, '-StateRoot', (Join-Path $homeDir 'state'), '-SkipBuild')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'exactly the key Codex') 'env without Skills key fails cleanly'

    Set-TestFile (Join-Path $repo 'harness-source/envs/dups.psd1') "@{ Skills = @{ Codex = @('alpha', 'alpha') } }"
    $r = Invoke-TestProcess -ScriptPath $deploy -Arguments @('-Environment', 'dups', '-RepoRoot', $repo, '-HomeRoot', $homeDir, '-StateRoot', (Join-Path $homeDir 'state'), '-SkipBuild')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'duplicate skill name') 'duplicate skill names in Skills.Codex are refused'

    $commaRetireHome = Join-Path $work 'comma-retire-home'
    Set-TestFile (Join-Path $commaRetireHome '.codex/skills/r1/SKILL.md') 'r1'
    Set-TestFile (Join-Path $commaRetireHome '.codex/skills/r2/SKILL.md') 'r2'
    $r = Invoke-Deploy $repo $commaRetireHome @('-Retire', 'r1,r2,r1', '-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and -not (Test-Path (Join-Path $commaRetireHome '.codex/skills/r1')) -and -not (Test-Path (Join-Path $commaRetireHome '.codex/skills/r2'))) 'comma-separated duplicate -Retire tokens split, deduplicate, and prune cleanly'

    Write-Host 'deploy-skills tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
