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

    $applied = Invoke-TestProcess -ScriptPath $deploy -Arguments ($deployArgs + @('-Apply'))
    Assert-TestCondition ($applied.Code -eq 0) "apply exits 0 ($($applied.Out))"
    Assert-TestCondition ((Test-Path (Join-Path $homeDir '.claude/skills/alpha/SKILL.md')) -and (Test-Path (Join-Path $homeDir '.codex/skills/alpha/SKILL.md'))) 'apply installs both skill projections'
    Assert-TestCondition ((Test-Path (Join-Path $homeDir '.claude/settings.json')) -and ((Get-Content -Raw (Join-Path $homeDir '.codex/AGENTS.md')) -match 'BEGIN AI-AGENT-DOTFILES: codex/AGENTS.md')) 'apply deploys merged config'
    $state = Get-Content -Raw (Join-Path $homeDir 'state/deployed-skills.json') | ConvertFrom-Json
    Assert-TestCondition ($state.Environment -eq 'test' -and (@($state.Claude) -join ',') -eq 'alpha') 'apply records the skill environment'

    $again = Invoke-TestProcess -ScriptPath $deploy -Arguments ($deployArgs + @('-Apply'))
    Assert-TestCondition ($again.Code -eq 0 -and $again.Out -match 'unchanged' -and $again.Out -match 'Nothing to deploy') 'second apply is idempotent'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
Write-Host 'deploy tests: PASS'
