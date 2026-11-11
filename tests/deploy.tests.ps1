#requires -Version 7.0
# Behavior tests for scripts/deploy.ps1: one dry-run/apply entry point for skills and config.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
$deploy = Join-Path $RepoRoot 'scripts/deploy.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('deploy-tests-' + [guid]::NewGuid().ToString('N'))

try {
    $repo = Join-Path $work 'repo'
    $homeDir = Join-Path $work 'home'
    New-Item -ItemType Directory -Path (Join-Path $repo 'harness-source/envs'), (Join-Path $repo 'manifests'), (Join-Path $repo 'scripts'), (Join-Path $repo 'tools/gitleaks') -Force | Out-Null
    foreach ($platform in 'claude', 'codex') {
        Set-TestFile (Join-Path $repo "$platform/skills/alpha/SKILL.md") "# alpha`n"
    }
    Set-TestFile (Join-Path $repo 'harness-source/envs/test.psd1') "@{ Skills = @{ Claude = @('alpha'); Codex = @('alpha'); Zcode = @() } }"
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'manifests/whitelist.psd1') -Destination (Join-Path $repo 'manifests/whitelist.psd1') -Force
    foreach ($name in @('scan-secrets.ps1', 'pinned-tool.ps1', 'repo-common.ps1')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts/$name") -Destination (Join-Path $repo "scripts/$name") -Force
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json') -Destination (Join-Path $repo 'tools/gitleaks/gitleaks.lock.json') -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot '.gitleaks.toml') -Destination $repo -Force
    Set-TestFile (Join-Path $repo 'claude/settings.json') '{"shared":true}'
    Set-TestFile (Join-Path $repo 'codex/AGENTS.md') "# Managed`n"
    & git -C $repo init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize deploy fixture repository.' }

    $deployArgs = @('-Environment', 'test', '-RepoRoot', $repo, '-HomeRoot', $homeDir, '-StateRoot', (Join-Path $homeDir 'state'), '-BackupRoot', (Join-Path $homeDir 'backups'), '-SkipBuild')
    $dry = Invoke-TestProcess -ScriptPath $deploy -Arguments $deployArgs
    Assert-TestCondition ($dry.Code -eq 0) "dry run exits 0 ($($dry.Out))"
    Assert-TestCondition ($dry.Out -match "Dry run for environment 'test'" -and $dry.Out -match 'config-pull' -and $dry.Out -match 'add\s+Claude/settings.json' -and $dry.Out -match 'add\s+Codex/AGENTS.md') 'dry run plans both skills and config'
    Assert-TestCondition (-not (Test-Path (Join-Path $homeDir '.claude/skills/alpha')) -and -not (Test-Path (Join-Path $homeDir '.codex/AGENTS.md')) -and -not (Test-Path (Join-Path $homeDir 'state'))) 'dry run writes no skills, config or state'

    $blockedHome = Join-Path $work 'blocked-home'
    $personalAgents = Join-Path $blockedHome '.codex/AGENTS.md'
    Set-TestFile $personalAgents '# Personal instructions without a managed block'
    $personalHash = (Get-FileHash -LiteralPath $personalAgents).Hash
    $blockedArgs = @('-Environment', 'test', '-RepoRoot', $repo, '-HomeRoot', $blockedHome, '-StateRoot', (Join-Path $blockedHome 'state'), '-BackupRoot', (Join-Path $blockedHome 'backups'), '-SkipBuild', '-Apply')
    $blocked = Invoke-TestProcess -ScriptPath $deploy -Arguments $blockedArgs
    Assert-TestCondition ($blocked.Code -ne 0 -and $blocked.Out -match 'Preflight failed; no live skills, config or deploy state written') 'config planning failure is reported before Apply'
    Assert-TestCondition ((Get-FileHash -LiteralPath $personalAgents).Hash -eq $personalHash -and -not (Test-Path (Join-Path $blockedHome '.claude')) -and -not (Test-Path (Join-Path $blockedHome '.codex/skills')) -and -not (Test-Path (Join-Path $blockedHome 'state')) -and -not (Test-Path (Join-Path $blockedHome 'backups'))) 'config preflight failure preserves personal config and writes no skills, state or backups'

    $collisionHome = Join-Path $work 'collision-home'
    Set-TestFile (Join-Path $collisionHome '.codex/skills/alpha') 'preserve ordinary file'
    $collisionArgs = @('-Environment', 'test', '-RepoRoot', $repo, '-HomeRoot', $collisionHome, '-StateRoot', (Join-Path $collisionHome 'state'), '-BackupRoot', (Join-Path $collisionHome 'backups'), '-SkipBuild', '-Apply')
    $collision = Invoke-TestProcess -ScriptPath $deploy -Arguments $collisionArgs
    Assert-TestCondition ($collision.Code -ne 0 -and $collision.Out -match 'Preflight failed' -and (Get-Content -Raw (Join-Path $collisionHome '.codex/skills/alpha')) -eq 'preserve ordinary file' -and -not (Test-Path (Join-Path $collisionHome '.claude')) -and -not (Test-Path (Join-Path $collisionHome '.codex/AGENTS.md')) -and -not (Test-Path (Join-Path $collisionHome 'state'))) 'skills planning failure stops before any config or skills write'

    $applied = Invoke-TestProcess -ScriptPath $deploy -Arguments ($deployArgs + @('-Apply'))
    Assert-TestCondition ($applied.Code -eq 0) "apply exits 0 ($($applied.Out))"
    Assert-TestCondition ($applied.Out.IndexOf('=== skills preflight ===') -lt $applied.Out.IndexOf('=== config preflight ===') -and $applied.Out.IndexOf('=== config preflight ===') -lt $applied.Out.IndexOf('=== skills ===') -and $applied.Out.IndexOf('=== skills ===') -lt $applied.Out.IndexOf('=== config ===')) 'both planners finish before either Apply stage'
    Assert-TestCondition ((Test-Path (Join-Path $homeDir '.claude/skills/alpha/SKILL.md')) -and (Test-Path (Join-Path $homeDir '.codex/skills/alpha/SKILL.md'))) 'apply installs both skill projections'
    Assert-TestCondition ((Test-Path (Join-Path $homeDir '.claude/settings.json')) -and ((Get-Content -Raw (Join-Path $homeDir '.codex/AGENTS.md')) -match 'BEGIN AI-AGENT-DOTFILES: codex/AGENTS.md')) 'apply deploys merged config'
    $state = Get-Content -Raw (Join-Path $homeDir 'state/deployed-skills.json') | ConvertFrom-Json
    Assert-TestCondition ($state.Environment -eq 'test' -and (@($state.Claude) -join ',') -eq 'alpha') 'apply records the skill environment'

    $again = Invoke-TestProcess -ScriptPath $deploy -Arguments ($deployArgs + @('-Apply'))
    Assert-TestCondition ($again.Code -eq 0 -and $again.Out -match 'unchanged' -and $again.Out -match 'Nothing to deploy') 'second apply is idempotent'

    Set-TestFile (Join-Path $repo 'claude/skills/alpha/SKILL.md') "# alpha updated`n"
    Set-TestFile (Join-Path $repo 'codex/AGENTS.md') "# Managed updated`n"
    $liveAgents = Join-Path $homeDir '.codex/AGENTS.md'
    $beforeLockHash = (Get-FileHash -LiteralPath $liveAgents).Hash
    $readLock = [IO.File]::Open($liveAgents, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $partial = Invoke-TestProcess -ScriptPath $deploy -Arguments ($deployArgs + @('-Apply')) }
    finally { $readLock.Dispose() }
    Assert-TestCondition ($partial.Code -ne 0 -and $partial.Out -match 'Preflight passed' -and $partial.Out -match 'Skills stage completed; config stage failed') 'runtime config write failure still reports partial completion after preflight'
    Assert-TestCondition ((Get-Content -Raw (Join-Path $homeDir '.claude/skills/alpha/SKILL.md')) -eq "# alpha updated`n" -and (Get-FileHash -LiteralPath $liveAgents).Hash -eq $beforeLockHash) 'completed skill update remains and locked config is preserved'
    $recovered = Invoke-TestProcess -ScriptPath $deploy -Arguments ($deployArgs + @('-Apply'))
    Assert-TestCondition ($recovered.Code -eq 0 -and (Get-Content -Raw $liveAgents) -match '# Managed updated') 'normal reviewed Apply can complete after the lock is released'

    Set-TestFile (Join-Path $repo 'scripts/build-skills.ps1') "Write-Host 'Fixture build invocation'"
    Set-TestFile (Join-Path $repo 'codex/AGENTS.md') "# Managed next revision`n"
    $normalArgs = @($deployArgs | Where-Object { $_ -ne '-SkipBuild' }) + @('-Apply')
    $normal = Invoke-TestProcess -ScriptPath $deploy -Arguments $normalArgs
    Assert-TestCondition ($normal.Code -eq 0 -and ([regex]::Matches($normal.Out, 'Fixture build invocation')).Count -eq 1 -and ([regex]::Matches($normal.Out, 'Running pinned gitleaks')).Count -eq 2) 'Apply builds once and retains both the skills and config scan gates'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
Write-Host 'deploy tests: PASS'
