#requires -Version 7.0
# Behavior tests for scripts/hermes-skills.ps1 and harness-source/hermes/skills.psd1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

$hermesScript = Join-Path $RepoRoot 'scripts\hermes-skills.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('hermes-skills-tests-' + [guid]::NewGuid().ToString('N'))

$savedHermesHome = [Environment]::GetEnvironmentVariable('HERMES_HOME')
$savedHermesSuffix = [Environment]::GetEnvironmentVariable('HERMES_DATA_DIR_SUFFIX')

function Invoke-Hermes {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $HomeDir,
        [Parameter(Mandatory)] [string] $StateDir,
        [string[]] $Extra = @(),
        [switch] $IncludeSkipScan
    )
    $argsList = @('-RepoRoot', $Repo, '-HomeRoot', $HomeDir, '-StateRoot', $StateDir)
    if ($IncludeSkipScan) {
        $argsList += '-SkipSecretScan'
    }
    $argsList += $Extra
    return Invoke-TestProcess -ScriptPath $hermesScript -Arguments $argsList
}

function Invoke-HermesInProcess {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $HomeDir,
        [Parameter(Mandatory)] [string] $StateDir,
        [hashtable] $Params = @{}
    )
    $invArgs = @{
        RepoRoot  = $Repo
        HomeRoot  = $HomeDir
        StateRoot = $StateDir
    }
    foreach ($k in $Params.Keys) {
        $invArgs[$k] = $Params[$k]
    }
    try {
        $out = @(& $hermesScript @invArgs *>&1 | ForEach-Object { [string] $_ })
        return [pscustomobject]@{ Code = 0; Out = ($out -join "`n") }
    }
    catch {
        return [pscustomobject]@{ Code = 1; Out = $_.Exception.Message }
    }
}

function Set-FixtureManifest {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [AllowEmptyCollection()] [string[]] $Skills
    )
    $list = ($Skills | ForEach-Object { "'$_'" }) -join ', '
    Set-TestFile (Join-Path $Repo 'harness-source\hermes\skills.psd1') "@{ SchemaVersion = 1; Category = 'ai-agent-dotfiles'; Skills = @($list) }"
}

function Assert-NoLeakedPaths {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [string] $HomeDir,
        [Parameter(Mandatory)] [string] $StateDir,
        [Parameter(Mandatory)] [string] $Label
    )
    $homeFwd = $HomeDir.Replace('\', '/')
    $stateFwd = $StateDir.Replace('\', '/')
    $ok = ($Text -notmatch [regex]::Escape($HomeDir)) -and
          ($Text -notmatch [regex]::Escape($homeFwd)) -and
          ($Text -notmatch [regex]::Escape($StateDir)) -and
          ($Text -notmatch [regex]::Escape($stateFwd))
    Assert-TestCondition $ok "$Label omits HomeRoot and StateRoot absolute paths"
}

try {
    [Environment]::SetEnvironmentVariable('HERMES_HOME', $null)
    [Environment]::SetEnvironmentVariable('HERMES_DATA_DIR_SUFFIX', $null)
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    # -------------------------------------------------------------------------
    # 1. Real manifest validation + mode validation
    # -------------------------------------------------------------------------
    Write-Host '[real manifest and mode validation]'
    $missingHome = Join-Path $work 'missing-hermes-home'
    $missingState = Join-Path $work 'missing-hermes-state'
    $r = Invoke-Hermes -Repo $RepoRoot -HomeDir $missingHome -StateDir $missingState -Extra @('-Action', 'Status', '-Json')
    Assert-TestCondition ($r.Code -eq 0) "real manifest Status -Json on absent Hermes home exits 0 ($($r.Out))"
    $json = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($json.SchemaVersion -eq 1 -and $json.Action -ceq 'Status' -and $json.State -ceq 'not-installed' -and $json.Reason -ceq 'hermes-home-missing' -and $json.Category -ceq 'ai-agent-dotfiles' -and $json.LiveRoot -ceq '%LOCALAPPDATA%/hermes/skills/ai-agent-dotfiles') 'real manifest not-installed Status JSON matches schema'
    Assert-NoLeakedPaths -Text $r.Out -HomeDir $missingHome -StateDir $missingState -Label 'not-installed Status JSON'
    Assert-TestCondition ((-not (Test-Path -LiteralPath $missingHome)) -and (-not (Test-Path -LiteralPath $missingState))) 'Status creates no home or state directories'

    $r = Invoke-Hermes -Repo $RepoRoot -HomeDir $missingHome -StateDir $missingState -Extra @('-DryRun', '-Json')
    Assert-TestCondition ($r.Code -eq 0) 'DryRun implies Action=Deploy and exits 0 when Hermes home missing'
    $dryJson = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($dryJson.Action -ceq 'Deploy' -and $dryJson.State -ceq 'not-installed' -and $dryJson.Reason -ceq 'hermes-home-missing') 'DryRun JSON reports Action=Deploy and not-installed'
    Assert-TestCondition ((-not (Test-Path -LiteralPath $missingHome)) -and (-not (Test-Path -LiteralPath $missingState))) 'DryRun creates no home or state directories'

    $r = Invoke-Hermes -Repo $RepoRoot -HomeDir $missingHome -StateDir $missingState -IncludeSkipScan -Extra @('-Action', 'Deploy', '-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'hermes-home-missing') 'Deploy -Apply refuses fail-closed when Hermes home is missing'
    Assert-TestCondition ((-not (Test-Path -LiteralPath $missingHome)) -and (-not (Test-Path -LiteralPath $missingState))) 'refused Deploy -Apply creates no directories'

    # Validate real manifest has exact 8 skills when Hermes home exists
    $realProbeHome = Join-Path $work 'real-probe-home'
    New-Item -ItemType Directory -Path (Join-Path $realProbeHome 'AppData\Local\hermes') -Force | Out-Null
    $r = Invoke-HermesInProcess -Repo $RepoRoot -HomeDir $realProbeHome -StateDir (Join-Path $work 'real-probe-state') -Params @{ Action = 'Status'; Json = $true }
    Assert-TestCondition ($r.Code -eq 0) 'real manifest against present Hermes home succeeds'
    $realPlan = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($realPlan.State -ceq 'checked' -and $realPlan.Summary.install -eq 8 -and (@($realPlan.Items).Count -eq 8)) 'real manifest selects exact 8 shared skills'

    # Mode validation rejections
    $modeRejectCases = @(
        @{ Params = @{ Apply = $true; DryRun = $true }; Label = '-Apply + -DryRun rejected' },
        @{ Params = @{ Apply = $true; Json = $true }; Label = '-Apply + -Json rejected' },
        @{ Params = @{ Action = 'Status'; Apply = $true }; Label = '-Action Status + -Apply rejected' },
        @{ Params = @{ Action = 'Status'; Retire = @('alpha') }; Label = '-Action Status + -Retire rejected' },
        @{ Params = @{ Action = 'Status'; SkipSecretScan = $true }; Label = '-Action Status + -SkipSecretScan rejected' },
        @{ Params = @{ Action = 'Status'; DryRun = $true }; Label = '-Action Status + -DryRun rejected' }
    )
    foreach ($case in $modeRejectCases) {
        $r = Invoke-HermesInProcess -Repo $RepoRoot -HomeDir $missingHome -StateDir $missingState -Params $case.Params
        Assert-TestCondition ($r.Code -ne 0) $case.Label
    }

    # Malformed manifest rejections
    Write-Host '[malformed manifest rejections]'
    $badRepo = Join-Path $work 'bad-manifest-repo'
    Set-TestFile (Join-Path $badRepo 'skills-source\shared\alpha\SKILL.md') "---`nname: alpha`n---`n# alpha`n"
    $r = Invoke-HermesInProcess -Repo $badRepo -HomeDir $missingHome -StateDir $missingState -Params @{ Action = 'Status' }
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'manifest not found') 'missing manifest rejected'

    $badManifests = @(
        @{ Content = "@{ SchemaVersion = 2; Category = 'ai-agent-dotfiles'; Skills = @('alpha') }"; Label = 'wrong SchemaVersion rejected' },
        @{ Content = "@{ SchemaVersion = 1; Category = 'other'; Skills = @('alpha') }"; Label = 'wrong Category rejected' },
        @{ Content = "@{ SchemaVersion = 1; Category = 'ai-agent-dotfiles'; Skills = @('alpha'); Extra = 1 }"; Label = 'extra manifest key rejected' },
        @{ Content = "@{ SchemaVersion = 1; Category = 'ai-agent-dotfiles'; Skills = @() }"; Label = 'empty Skills rejected' },
        @{ Content = "@{ SchemaVersion = 1; Category = 'ai-agent-dotfiles'; Skills = 'alpha' }"; Label = 'non-array Skills rejected' },
        @{ Content = "@{ SchemaVersion = 1; Category = 'ai-agent-dotfiles'; Skills = @('alpha.') }"; Label = 'invalid skill name rejected' },
        @{ Content = "@{ SchemaVersion = 1; Category = 'ai-agent-dotfiles'; Skills = @('alpha', 'alpha') }"; Label = 'duplicate skill name rejected' },
        @{ Content = "@{ SchemaVersion = 1; Category = 'ai-agent-dotfiles'; Skills = @('missing-skill') }"; Label = 'missing skill dir rejected' }
    )
    foreach ($bm in $badManifests) {
        Set-TestFile (Join-Path $badRepo 'harness-source\hermes\skills.psd1') $bm.Content
        $r = Invoke-HermesInProcess -Repo $badRepo -HomeDir $missingHome -StateDir $missingState -Params @{ Action = 'Status' }
        Assert-TestCondition ($r.Code -ne 0) $bm.Label
    }

    # Source skill without SKILL.md or with reparse point
    New-Item -ItemType Directory -Path (Join-Path $badRepo 'skills-source\shared\no-md') -Force | Out-Null
    Set-FixtureManifest -Repo $badRepo -Skills @('no-md')
    $r = Invoke-HermesInProcess -Repo $badRepo -HomeDir $missingHome -StateDir $missingState -Params @{ Action = 'Status' }
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'missing SKILL.md') 'source skill without SKILL.md rejected'

    $outsideSource = Join-Path $work 'outside-source'
    Set-TestFile (Join-Path $outsideSource 'sentinel.txt') 'keep'
    New-Item -ItemType Directory -Path (Join-Path $badRepo 'skills-source\shared\junc-skill') -Force | Out-Null
    Set-TestFile (Join-Path $badRepo 'skills-source\shared\junc-skill\SKILL.md') "---`nname: junc-skill`n---`n"
    New-Item -ItemType Junction -Path (Join-Path $badRepo 'skills-source\shared\junc-skill\sub') -Target $outsideSource | Out-Null
    Set-FixtureManifest -Repo $badRepo -Skills @('junc-skill')
    $r = Invoke-HermesInProcess -Repo $badRepo -HomeDir $missingHome -StateDir $missingState -Params @{ Action = 'Status' }
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'reparse') 'reparse point in source skill rejected'

    # -------------------------------------------------------------------------
    # 2. Fixture repo setup for Hermes home guard, collisions, lifecycle
    # -------------------------------------------------------------------------
    $repo = Join-Path $work 'repo'
    Set-TestFile (Join-Path $repo 'skills-source\shared\alpha\SKILL.md') "---`nname: alpha`n---`n# alpha v1`n"
    Set-TestFile (Join-Path $repo 'skills-source\shared\alpha\CREATION-LOG.md') 'do-not-deploy-or-hash-alpha'
    Set-TestFile (Join-Path $repo 'skills-source\shared\alpha\refs\guide.md') 'secret-body-never-print'
    Set-TestFile (Join-Path $repo 'skills-source\shared\beta\SKILL.md') "---`nname: beta`n---`n# beta v1`n"
    Set-FixtureManifest -Repo $repo -Skills @('alpha', 'beta')

    Write-Host '[Hermes home guard blocked states]'
    $guardHome = Join-Path $work 'guard-home'
    $guardState = Join-Path $work 'guard-state'
    New-Item -ItemType Directory -Path (Join-Path $guardHome 'AppData\Local\hermes') -Force | Out-Null

    try {
        [Environment]::SetEnvironmentVariable('HERMES_HOME', (Join-Path $work 'other-hermes'))
        $r = Invoke-HermesInProcess -Repo $repo -HomeDir $guardHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
        $g = $r.Out | ConvertFrom-Json
        Assert-TestCondition ($r.Code -eq 0 -and $g.State -ceq 'blocked' -and $g.Reason -ceq 'hermes-home-override-unsupported') 'non-default HERMES_HOME blocks Status'
        $rApply = Invoke-HermesInProcess -Repo $repo -HomeDir $guardHome -StateDir $guardState -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
        Assert-TestCondition ($rApply.Code -ne 0 -and $rApply.Out -match 'hermes-home-override-unsupported') 'non-default HERMES_HOME blocks Apply'

        # Exact default HERMES_HOME is allowed
        [Environment]::SetEnvironmentVariable('HERMES_HOME', (Join-Path $guardHome 'AppData\Local\hermes\'))
        $r = Invoke-HermesInProcess -Repo $repo -HomeDir $guardHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
        $g = $r.Out | ConvertFrom-Json
        Assert-TestCondition ($r.Code -eq 0 -and $g.State -ceq 'checked') 'default HERMES_HOME is permitted'
    }
    finally {
        [Environment]::SetEnvironmentVariable('HERMES_HOME', $null)
    }

    try {
        [Environment]::SetEnvironmentVariable('HERMES_DATA_DIR_SUFFIX', '-canary')
        $r = Invoke-HermesInProcess -Repo $repo -HomeDir $guardHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
        $g = $r.Out | ConvertFrom-Json
        Assert-TestCondition ($r.Code -eq 0 -and $g.State -ceq 'blocked' -and $g.Reason -ceq 'hermes-data-dir-suffix-unsupported') 'non-empty HERMES_DATA_DIR_SUFFIX blocks Status'
        $rApply = Invoke-HermesInProcess -Repo $repo -HomeDir $guardHome -StateDir $guardState -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
        Assert-TestCondition ($rApply.Code -ne 0) 'non-empty HERMES_DATA_DIR_SUFFIX blocks Apply'
    }
    finally {
        [Environment]::SetEnvironmentVariable('HERMES_DATA_DIR_SUFFIX', $null)
    }

    # active_profile checks
    $activeProfilePath = Join-Path $guardHome 'AppData\Local\hermes\active_profile'
    Set-TestFile $activeProfilePath "work`n"
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $guardHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
    $g = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($r.Code -eq 0 -and $g.State -ceq 'blocked' -and $g.Reason -ceq 'hermes-non-default-active-profile') 'non-default active_profile blocks Status'
    $rApply = Invoke-HermesInProcess -Repo $repo -HomeDir $guardHome -StateDir $guardState -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
    Assert-TestCondition ($rApply.Code -ne 0) 'non-default active_profile blocks Apply'

    Set-TestFile $activeProfilePath "   `n"
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $guardHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
    $g = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($r.Code -eq 0 -and $g.State -ceq 'blocked') 'blank/invalid active_profile blocks Status'

    Set-TestFile $activeProfilePath "default`n"
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $guardHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
    $g = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($r.Code -eq 0 -and $g.State -ceq 'checked') 'default active_profile is permitted'
    Remove-Item -LiteralPath $activeProfilePath -Force

    # Regular file occupying hermes / skills / ai-agent-dotfiles
    $fileHermesHome = Join-Path $work 'file-hermes-home'
    Set-TestFile (Join-Path $fileHermesHome 'AppData\Local\hermes') 'regular-file'
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $fileHermesHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
    Assert-TestCondition ($r.Code -eq 0 -and ($r.Out | ConvertFrom-Json).State -ceq 'blocked') 'file occupying AppData\Local\hermes blocks Status'
    $rApply = Invoke-HermesInProcess -Repo $repo -HomeDir $fileHermesHome -StateDir $guardState -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
    Assert-TestCondition ($rApply.Code -ne 0) 'file occupying AppData\Local\hermes blocks Apply'

    $fileSkillsHome = Join-Path $work 'file-skills-home'
    Set-TestFile (Join-Path $fileSkillsHome 'AppData\Local\hermes\skills') 'regular-file'
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $fileSkillsHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
    Assert-TestCondition ($r.Code -eq 0 -and ($r.Out | ConvertFrom-Json).State -ceq 'blocked') 'file occupying skills dir blocks Status'

    $fileCatHome = Join-Path $work 'file-cat-home'
    Set-TestFile (Join-Path $fileCatHome 'AppData\Local\hermes\skills\ai-agent-dotfiles') 'regular-file'
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $fileCatHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
    Assert-TestCondition ($r.Code -eq 0 -and ($r.Out | ConvertFrom-Json).State -ceq 'blocked') 'file occupying ai-agent-dotfiles dir blocks Status'

    # Reparse points on hermes / skills / ai-agent-dotfiles
    $outsideGuard = Join-Path $work 'outside-guard'
    Set-TestFile (Join-Path $outsideGuard 'keep.txt') 'keep'
    foreach ($jRel in @('AppData\Local\hermes', 'AppData\Local\hermes\skills', 'AppData\Local\hermes\skills\ai-agent-dotfiles')) {
        $jHome = Join-Path $work ('junc-' + ($jRel -replace '[\\/:]', '_'))
        $jPath = Join-Path $jHome $jRel
        New-Item -ItemType Directory -Path (Split-Path -Parent $jPath) -Force | Out-Null
        New-Item -ItemType Junction -Path $jPath -Target $outsideGuard | Out-Null
        $r = Invoke-HermesInProcess -Repo $repo -HomeDir $jHome -StateDir $guardState -Params @{ Action = 'Status'; Json = $true }
        $g = $r.Out | ConvertFrom-Json
        Assert-TestCondition ($r.Code -eq 0 -and $g.State -ceq 'blocked' -and $g.Reason -ceq 'reparse-point-refused') "junction at $jRel blocks Status"
        $rApply = Invoke-HermesInProcess -Repo $repo -HomeDir $jHome -StateDir $guardState -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
        Assert-TestCondition ($rApply.Code -ne 0) "junction at $jRel blocks Apply"
    }

    # -------------------------------------------------------------------------
    # 3. Same-tier sibling local skill collision detector
    # -------------------------------------------------------------------------
    Write-Host '[same-tier sibling collision detection]'
    $collHome = Join-Path $work 'collision-home'
    $collState = Join-Path $work 'collision-state'
    # Skipped directories should NOT trigger collisions
    Set-TestFile (Join-Path $collHome 'AppData\Local\hermes\skills\.hub\alpha\SKILL.md') "---`nname: alpha`n---`n"
    Set-TestFile (Join-Path $collHome 'AppData\Local\hermes\skills\.locks\beta\SKILL.md') "---`nname: beta`n---`n"
    Set-TestFile (Join-Path $collHome 'AppData\Local\hermes\skills\.archive\alpha\SKILL.md') "---`nname: alpha`n---`n"
    Set-TestFile (Join-Path $collHome 'AppData\Local\hermes\skills\.curator_backups\beta\SKILL.md') "---`nname: beta`n---`n"
    Set-TestFile (Join-Path $collHome 'AppData\Local\hermes\skills\.git\alpha\SKILL.md') "---`nname: alpha`n---`n"
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $collHome -StateDir $collState -Params @{ Action = 'Status'; Json = $true }
    $cJson = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($r.Code -eq 0 -and $cJson.State -ceq 'checked' -and $cJson.Summary.blocked -eq 0 -and $cJson.Summary.install -eq 2) 'skipped sibling dirs do not trigger collisions'

    # Frontmatter name collision + directory name fallback collision
    Set-TestFile (Join-Path $collHome 'AppData\Local\hermes\skills\custom-cat\my-alias\SKILL.md') "---`nname: `"alpha`"`ndescription: x`n---`n"
    Set-TestFile (Join-Path $collHome 'AppData\Local\hermes\skills\software-development\beta\SKILL.md') "# no frontmatter`n"
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $collHome -StateDir $collState -Params @{ Action = 'Deploy'; DryRun = $true; Json = $true }
    $cJson = $r.Out | ConvertFrom-Json
    $alphaItem = @($cJson.Items | Where-Object Name -ceq 'alpha')[0]
    $betaItem = @($cJson.Items | Where-Object Name -ceq 'beta')[0]
    Assert-TestCondition ($r.Code -eq 0 -and $cJson.State -ceq 'checked' -and $cJson.Summary.blocked -eq 2) 'both frontmatter and dir-fallback collisions mark items blocked'
    Assert-TestCondition ($alphaItem.Action -ceq 'blocked' -and $alphaItem.Reason -ceq 'hermes-local-skill-collision:custom-cat/my-alias/SKILL.md') 'frontmatter collision reports exact relative path'
    Assert-TestCondition ($betaItem.Action -ceq 'blocked' -and $betaItem.Reason -ceq 'hermes-local-skill-collision:software-development/beta/SKILL.md') 'directory-name fallback collision reports exact relative path'
    Assert-NoLeakedPaths -Text $r.Out -HomeDir $collHome -StateDir $collState -Label 'collision JSON'
    $rApply = Invoke-HermesInProcess -Repo $repo -HomeDir $collHome -StateDir $collState -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
    Assert-TestCondition ($rApply.Code -ne 0 -and (-not (Test-Path -LiteralPath (Join-Path $collHome 'AppData\Local\hermes\skills\ai-agent-dotfiles')))) 'collision refuses Apply without creating ai-agent-dotfiles'

    # Sibling reparse point is refused safely without descending into target
    $sibJuncHome = Join-Path $work 'sib-junc-home'
    $sibOutside = Join-Path $work 'sib-outside'
    Set-TestFile (Join-Path $sibOutside 'alpha\SKILL.md') "---`nname: alpha`n---`n"
    New-Item -ItemType Directory -Path (Join-Path $sibJuncHome 'AppData\Local\hermes\skills\custom') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $sibJuncHome 'AppData\Local\hermes\skills\custom\link') -Target $sibOutside | Out-Null
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $sibJuncHome -StateDir $collState -Params @{ Action = 'Status'; Json = $true }
    $sj = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($r.Code -eq 0 -and $sj.State -ceq 'blocked' -and $sj.Reason -ceq 'reparse-point-refused') 'sibling reparse point fails closed without traversing target'

    # -------------------------------------------------------------------------
    # 4. Full lifecycle: install, unchanged, update+backup, prune+backup, unknown, -Retire, CREATION-LOG.md, bundled siblings
    # -------------------------------------------------------------------------
    Write-Host '[full lifecycle and sibling bundled files preservation]'
    $lifeHome = Join-Path $work 'life-home'
    $lifeState = Join-Path $work 'life-state'
    $hermesSkillsDir = Join-Path $lifeHome 'AppData\Local\hermes\skills'
    $liveCatDir = Join-Path $hermesSkillsDir 'ai-agent-dotfiles'

    # Seed Hermes bundled manifest, .hub, software-development, plus unknown skill and .deploying remnant
    Set-TestFile (Join-Path $hermesSkillsDir '.bundled_manifest') '{"bundled":true}'
    Set-TestFile (Join-Path $hermesSkillsDir '.hub\index.json') '{"hub":1}'
    Set-TestFile (Join-Path $hermesSkillsDir 'software-development\github\SKILL.md') "---`nname: github`n---`n# bundled github`n"
    Set-TestFile (Join-Path $liveCatDir 'hand-made\SKILL.md') 'custom manual skill'
    New-Item -ItemType Directory -Path (Join-Path $liveCatDir '.deploying-alpha') -Force | Out-Null
    Set-TestFile (Join-Path $liveCatDir '.deploying-alpha\stale.txt') 'stale remnant'

    $bundledHashBefore = (Get-FileHash -LiteralPath (Join-Path $hermesSkillsDir '.bundled_manifest')).Hash
    $githubHashBefore = (Get-FileHash -LiteralPath (Join-Path $hermesSkillsDir 'software-development\github\SKILL.md')).Hash

    # Dry-run JSON & JsonPath
    $previewJsonPath = Join-Path $work 'preview-report.json'
    $r = Invoke-Hermes -Repo $repo -HomeDir $lifeHome -StateDir $lifeState -IncludeSkipScan -Extra @('-DryRun', '-Json', '-JsonPath', $previewJsonPath)
    Assert-TestCondition ($r.Code -eq 0) "lifecycle dry-run -Json exits 0 ($($r.Out))"
    Assert-NoLeakedPaths -Text $r.Out -HomeDir $lifeHome -StateDir $lifeState -Label 'lifecycle dry-run -Json'
    Assert-TestCondition ($r.Out -notmatch 'do-not-deploy-or-hash-alpha' -and $r.Out -notmatch 'secret-body-never-print') 'JSON omits file contents and CREATION-LOG.md'
    $pJson = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($pJson.Summary.install -eq 2 -and $pJson.Summary.unknown -eq 1 -and (@($pJson.InterruptedRemnants) -join ',') -ceq '.deploying-alpha') 'dry-run reports 2 installs, 1 unknown, and leaf InterruptedRemnants'
    $alphaPlan = @($pJson.Items | Where-Object Name -ceq 'alpha')[0]
    $alphaPaths = @($alphaPlan.FileChanges | ForEach-Object Path)
    Assert-TestCondition (($alphaPaths -contains 'SKILL.md') -and ($alphaPaths -contains 'refs/guide.md') -and ($alphaPaths -notcontains 'CREATION-LOG.md')) 'FileChanges lists relative paths and excludes CREATION-LOG.md'
    Assert-TestCondition ((Test-Path -LiteralPath $previewJsonPath) -and (-not (Test-Path -LiteralPath $lifeState))) '-JsonPath writes report while dry-run creates no state'

    # Apply first install (and write -JsonPath on Apply)
    $applyJsonPath = Join-Path $work 'apply-report.json'
    $r = Invoke-Hermes -Repo $repo -HomeDir $lifeHome -StateDir $lifeState -IncludeSkipScan -Extra @('-Action', 'Deploy', '-Apply', '-JsonPath', $applyJsonPath)
    Assert-TestCondition ($r.Code -eq 0) "first Apply exits 0 ($($r.Out))"
    Assert-TestCondition ((Get-Content -Raw (Join-Path $liveCatDir 'alpha\SKILL.md')) -ceq "---`nname: alpha`n---`n# alpha v1`n") 'alpha installed'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $liveCatDir 'alpha\CREATION-LOG.md'))) 'CREATION-LOG.md excluded from installed alpha'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $liveCatDir '.deploying-alpha'))) 'interrupted remnant cleaned on apply'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $liveCatDir 'hand-made\SKILL.md')) -ceq 'custom manual skill') 'unknown skill preserved'
    Assert-TestCondition (((Get-FileHash -LiteralPath (Join-Path $hermesSkillsDir '.bundled_manifest')).Hash -ceq $bundledHashBefore) -and ((Get-FileHash -LiteralPath (Join-Path $hermesSkillsDir 'software-development\github\SKILL.md')).Hash -ceq $githubHashBefore)) 'sibling bundled Hermes files untouched'

    $stateObj = Get-Content -Raw (Join-Path $lifeState 'deployed-skills.json') | ConvertFrom-Json
    Assert-TestCondition ($stateObj.SchemaVersion -eq 1 -and $stateObj.Category -ceq 'ai-agent-dotfiles' -and ((@($stateObj.Skills) -join ',') -ceq 'alpha,beta')) 'deployed-skills.json written with valid schema and sorted Skills'
    $applyReport = Get-Content -Raw $applyJsonPath | ConvertFrom-Json
    Assert-TestCondition ($applyReport.Summary.unchanged -eq 2 -and $applyReport.Summary.unknown -eq 1) 'Apply -JsonPath reflects post-Apply readback convergence'
    Assert-NoLeakedPaths -Text (Get-Content -Raw $applyJsonPath) -HomeDir $lifeHome -StateDir $lifeState -Label 'Apply -JsonPath'

    # Second Apply is a clean no-op
    $r = Invoke-Hermes -Repo $repo -HomeDir $lifeHome -StateDir $lifeState -IncludeSkipScan -Extra @('-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'unchanged=2') 'second Apply is a no-op'

    # Update alpha (and modify only CREATION-LOG.md in beta to verify beta stays unchanged!)
    Set-TestFile (Join-Path $repo 'skills-source\shared\alpha\SKILL.md') "---`nname: alpha`n---`n# alpha v2`n"
    Set-TestFile (Join-Path $repo 'skills-source\shared\beta\CREATION-LOG.md') 'beta-creation-log-ignored'
    $r = Invoke-Hermes -Repo $repo -HomeDir $lifeHome -StateDir $lifeState -IncludeSkipScan -Extra @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) "update Apply exits 0 ($($r.Out))"
    Assert-TestCondition ((Get-Content -Raw (Join-Path $liveCatDir 'alpha\SKILL.md')) -ceq "---`nname: alpha`n---`n# alpha v2`n") 'alpha updated'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $liveCatDir 'beta\CREATION-LOG.md'))) 'CREATION-LOG.md change does not deploy to beta'
    $alphaBackups = @(Get-ChildItem -LiteralPath (Join-Path $lifeState 'skill-backups') -Recurse -File -Filter 'SKILL.md' | Where-Object { $_.FullName -match 'Hermes[\\/]alpha[\\/]' })
    Assert-TestCondition ($alphaBackups.Count -eq 1 -and (Get-Content -Raw $alphaBackups[0].FullName) -ceq "---`nname: alpha`n---`n# alpha v1`n") 'previous alpha backed up under Hermes/alpha'

    # Prune beta by removing it from manifest
    Set-FixtureManifest -Repo $repo -Skills @('alpha')
    $r = Invoke-Hermes -Repo $repo -HomeDir $lifeHome -StateDir $lifeState -IncludeSkipScan -Extra @('-Apply')
    Assert-TestCondition ($r.Code -eq 0) "prune Apply exits 0 ($($r.Out))"
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $liveCatDir 'beta'))) 'deselected beta pruned'
    $betaBackups = @(Get-ChildItem -LiteralPath (Join-Path $lifeState 'skill-backups') -Recurse -File -Filter 'SKILL.md' | Where-Object { $_.FullName -match 'Hermes[\\/]beta[\\/]' })
    Assert-TestCondition ($betaBackups.Count -eq 1) 'pruned beta backed up under Hermes/beta'
    Assert-TestCondition (Test-Path -LiteralPath (Join-Path $liveCatDir 'hand-made\SKILL.md')) 'unknown skill still preserved after prune'
    $stateAfterPrune = Get-Content -Raw (Join-Path $lifeState 'deployed-skills.json') | ConvertFrom-Json
    Assert-TestCondition ((@($stateAfterPrune.Skills).Count -eq 1) -and (@($stateAfterPrune.Skills)[0] -ceq 'alpha')) 'state retains single-element array after prune'

    # Explicit -Retire selected skill rejected
    $r = Invoke-Hermes -Repo $repo -HomeDir $lifeHome -StateDir $lifeState -IncludeSkipScan -Extra @('-Retire', 'alpha', '-Apply')
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'retire-selected-skill' -and (Test-Path -LiteralPath (Join-Path $liveCatDir 'alpha\SKILL.md'))) 'retiring selected skill is rejected without modifying alpha'

    # Explicit -Retire unknown skill
    $r = Invoke-Hermes -Repo $repo -HomeDir $lifeHome -StateDir $lifeState -IncludeSkipScan -Extra @('-Retire', 'hand-made')
    Assert-TestCondition ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $liveCatDir 'hand-made\SKILL.md'))) 'dry-run -Retire preserves hand-made'
    $r = Invoke-Hermes -Repo $repo -HomeDir $lifeHome -StateDir $lifeState -IncludeSkipScan -Extra @('-Retire', 'hand-made', '-Apply')
    Assert-TestCondition ($r.Code -eq 0 -and (-not (Test-Path -LiteralPath (Join-Path $liveCatDir 'hand-made')))) 'apply -Retire removes hand-made'
    $retireBackups = @(Get-ChildItem -LiteralPath (Join-Path $lifeState 'skill-backups') -Recurse -File -Filter 'SKILL.md' | Where-Object { $_.FullName -match 'Hermes[\\/]hand-made[\\/]' })
    Assert-TestCondition ($retireBackups.Count -eq 1) 'retired skill backed up'
    Assert-TestCondition (((Get-FileHash -LiteralPath (Join-Path $hermesSkillsDir '.bundled_manifest')).Hash -ceq $bundledHashBefore) -and ((Get-FileHash -LiteralPath (Join-Path $hermesSkillsDir 'software-development\github\SKILL.md')).Hash -ceq $githubHashBefore)) 'sibling bundled Hermes files still untouched after prune and retire'

    # Unrecorded update detection
    $unrecHome = Join-Path $work 'unrec-home'
    $unrecState = Join-Path $work 'unrec-state'
    Set-TestFile (Join-Path $unrecHome 'AppData\Local\hermes\skills\ai-agent-dotfiles\alpha\SKILL.md') 'manual alpha'
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $unrecHome -StateDir $unrecState -Params @{ Action = 'Status'; Json = $true }
    $uJson = $r.Out | ConvertFrom-Json
    Assert-TestCondition ($r.Code -eq 0 -and (@($uJson.UnrecordedUpdates) -contains 'alpha')) 'unrecorded live difference is reported in UnrecordedUpdates'

    # -------------------------------------------------------------------------
    # 5. Target reparse, regular file target, and corrupt state fail-closed
    # -------------------------------------------------------------------------
    Write-Host '[target reparse, file target, and corrupt state fail-closed]'
    Set-FixtureManifest -Repo $repo -Skills @('alpha', 'beta')

    $targetJuncHome = Join-Path $work 'target-junc-home'
    $targetOutside = Join-Path $work 'target-outside'
    Set-TestFile (Join-Path $targetOutside 'sentinel.txt') 'keep-target'
    New-Item -ItemType Directory -Path (Join-Path $targetJuncHome 'AppData\Local\hermes\skills\ai-agent-dotfiles') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $targetJuncHome 'AppData\Local\hermes\skills\ai-agent-dotfiles\beta') -Target $targetOutside | Out-Null
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $targetJuncHome -StateDir (Join-Path $work 'tj-state') -Params @{ Action = 'Deploy'; DryRun = $true; Json = $true }
    $tj = $r.Out | ConvertFrom-Json
    $tjBeta = @($tj.Items | Where-Object Name -ceq 'beta')[0]
    Assert-TestCondition ($r.Code -eq 0 -and $tjBeta.Action -ceq 'blocked' -and $tjBeta.Reason -ceq 'reparse-point-refused') 'target junction marked blocked'
    $rApply = Invoke-HermesInProcess -Repo $repo -HomeDir $targetJuncHome -StateDir (Join-Path $work 'tj-state') -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
    Assert-TestCondition ($rApply.Code -ne 0 -and ((Get-Content -Raw (Join-Path $targetOutside 'sentinel.txt')) -ceq 'keep-target') -and (-not (Test-Path -LiteralPath (Join-Path $targetJuncHome 'AppData\Local\hermes\skills\ai-agent-dotfiles\alpha')))) 'target junction blocks entire Apply and leaves outside target untouched'

    $targetFileHome = Join-Path $work 'target-file-home'
    Set-TestFile (Join-Path $targetFileHome 'AppData\Local\hermes\skills\ai-agent-dotfiles\beta') 'ordinary file'
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $targetFileHome -StateDir (Join-Path $work 'tf-state') -Params @{ Action = 'Deploy'; DryRun = $true; Json = $true }
    $tf = $r.Out | ConvertFrom-Json
    $tfBeta = @($tf.Items | Where-Object Name -ceq 'beta')[0]
    Assert-TestCondition ($r.Code -eq 0 -and $tfBeta.Action -ceq 'blocked' -and $tfBeta.Reason -ceq 'live-skill-target-not-directory') 'ordinary file at target skill marked blocked'
    $rApply = Invoke-HermesInProcess -Repo $repo -HomeDir $targetFileHome -StateDir (Join-Path $work 'tf-state') -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
    Assert-TestCondition ($rApply.Code -ne 0 -and ((Get-Content -Raw (Join-Path $targetFileHome 'AppData\Local\hermes\skills\ai-agent-dotfiles\beta')) -ceq 'ordinary file') -and (-not (Test-Path -LiteralPath (Join-Path $targetFileHome 'AppData\Local\hermes\skills\ai-agent-dotfiles\alpha')))) 'file at target skill blocks entire Apply and preserves file'

    # Corrupt state cases
    $corruptHome = Join-Path $work 'corrupt-home'
    Set-TestFile (Join-Path $corruptHome 'AppData\Local\hermes\skills\ai-agent-dotfiles\stray\SKILL.md') 'live stray'
    $fileStateRoot = Join-Path $work 'file-state-root'
    Set-TestFile $fileStateRoot 'not a dir'
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $corruptHome -StateDir $fileStateRoot -Params @{ Action = 'Status' }
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'state-root-not-directory') 'file at StateRoot fails closed'

    $dirStatePathRoot = Join-Path $work 'dir-state-path'
    New-Item -ItemType Directory -Path (Join-Path $dirStatePathRoot 'deployed-skills.json') -Force | Out-Null
    $r = Invoke-HermesInProcess -Repo $repo -HomeDir $corruptHome -StateDir $dirStatePathRoot -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'state-path-is-directory') 'directory at deployed-skills.json fails closed'

    $badStateRoot = Join-Path $work 'bad-state-root'
    $badStateFile = Join-Path $badStateRoot 'deployed-skills.json'
    $corruptPayloads = @(
        '{invalid-json',
        '[]',
        '{"SchemaVersion":2,"Category":"ai-agent-dotfiles","Skills":["stray"]}',
        '{"SchemaVersion":1,"Category":"wrong","Skills":["stray"]}',
        '{"SchemaVersion":1,"Category":"ai-agent-dotfiles","Skills":"stray"}',
        '{"SchemaVersion":1,"Category":"ai-agent-dotfiles","Skills":["bad/name"]}',
        '{"SchemaVersion":1,"Category":"ai-agent-dotfiles","Skills":["stray","stray"]}',
        '{"SchemaVersion":1,"Category":"ai-agent-dotfiles"}'
    )
    foreach ($payload in $corruptPayloads) {
        Set-TestFile $badStateFile $payload
        $rStatus = Invoke-HermesInProcess -Repo $repo -HomeDir $corruptHome -StateDir $badStateRoot -Params @{ Action = 'Status' }
        $rApply = Invoke-HermesInProcess -Repo $repo -HomeDir $corruptHome -StateDir $badStateRoot -Params @{ Action = 'Deploy'; Apply = $true; SkipSecretScan = $true }
        Assert-TestCondition ($rStatus.Code -ne 0 -and $rApply.Code -ne 0 -and (Test-Path -LiteralPath (Join-Path $corruptHome 'AppData\Local\hermes\skills\ai-agent-dotfiles\stray\SKILL.md'))) "corrupt state fails closed without pruning: $payload"
    }

    # -------------------------------------------------------------------------
    # 6. Secret scan gate invoked when -SkipSecretScan is omitted
    # -------------------------------------------------------------------------
    Write-Host '[secret scan gate invoked on Apply]'
    $scanHome = Join-Path $work 'scan-home'
    $scanState = Join-Path $work 'scan-state'
    New-Item -ItemType Directory -Path (Join-Path $scanHome 'AppData\Local\hermes') -Force | Out-Null
    $scanHarness = Join-Path $work 'scan-harness.ps1'
    Set-TestFile $scanHarness @"
param([string] `$ScriptPath, [string] `$Repo, [string] `$HomeDir, [string] `$StateDir)
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. `$ScriptPath
`$script:ScanCalls = 0
function Invoke-SecretScanGate {
    param([Parameter(Mandatory)] [string] `$RepoRoot)
    `$script:ScanCalls++
    throw 'sentinel-scan-gate-invoked'
}
try {
    `$null = Invoke-HermesSkillsDeploy -RepoRoot `$Repo -HomeRoot `$HomeDir -StateRoot `$StateDir -DoApply
    exit 2
}
catch {
    if (`$_.Exception.Message -eq 'sentinel-scan-gate-invoked' -and `$script:ScanCalls -eq 1) {
        Write-Output 'SCAN_GATE_OK'
        exit 0
    }
    Write-Output `$_.Exception.Message
    exit 1
}
"@
    $r = Invoke-TestProcess -ScriptPath $scanHarness -Arguments @($hermesScript, $repo, $scanHome, $scanState)
    Assert-TestCondition ($r.Code -eq 0 -and $r.Out -match 'SCAN_GATE_OK' -and (-not (Test-Path -LiteralPath (Join-Path $scanHome 'AppData\Local\hermes\skills\ai-agent-dotfiles')))) 'Invoke-SecretScanGate runs before Apply writes'

    Write-Host 'hermes-skills tests: PASS'
}
finally {
    [Environment]::SetEnvironmentVariable('HERMES_HOME', $savedHermesHome)
    [Environment]::SetEnvironmentVariable('HERMES_DATA_DIR_SUFFIX', $savedHermesSuffix)
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
