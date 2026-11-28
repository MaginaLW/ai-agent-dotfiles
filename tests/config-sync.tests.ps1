#requires -Version 7.0
<#
.SYNOPSIS
    Self-contained regression tests for the config-sync scripts
    (config-status.ps1, config-pull.ps1, config-push.ps1).

.DESCRIPTION
    No Pester dependency. Runs each real script against isolated repo/home
    trees under the ignored project tmp/tests/config-sync area and asserts behavior, with emphasis on the two
    config-push gates (secret scan + machine-private path scan) and the
    never-prune / dry-run-default posture.

    Exit code 0 = all passed, 1 = one or more failures.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $WorkRoot = '',
    [string] $WorkspaceRunId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$statusScript = Join-Path $RepoRoot 'scripts/config-status.ps1'
$pullScript = Join-Path $RepoRoot 'scripts/config-pull.ps1'
$pushScript = Join-Path $RepoRoot 'scripts/config-push.ps1'

$script:pass = 0
$script:fail = 0
$script:failureMessages = [Collections.Generic.List[string]]::new()
function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    }
    else {
        $script:fail++
        $script:failureMessages.Add($Message)
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

. (Join-Path $RepoRoot 'scripts/config-sync-test-workspace.ps1')
. (Join-Path $RepoRoot 'scripts/config-common.ps1')
if ($WorkRoot -or $WorkspaceRunId) {
    if (-not $WorkRoot -or -not $WorkspaceRunId) { throw 'WorkRoot and WorkspaceRunId must be provided together.' }
    $work = Assert-ConfigSyncTestWork -RepoRoot $RepoRoot -WorkRoot $WorkRoot -RunId $WorkspaceRunId
}
else {
    $workspace = New-ConfigSyncTestWork -RepoRoot $RepoRoot
    $work = $workspace.Root
    $WorkspaceRunId = $workspace.RunId
}

$script:templateRepo = $null
function New-TempRepo {
    param([Parameter(Mandatory)] [string] $Name)
    if ($null -eq $script:templateRepo) {
        $tpl = Join-Path $work '_template-repo'
        New-Item -ItemType Directory -Path (Join-Path $tpl 'manifests') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tpl 'scripts') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'manifests/whitelist.psd1') -Destination (Join-Path $tpl 'manifests') -Force
        foreach ($scriptName in @(
            'scan-secrets.ps1'
            'pinned-tool.ps1'
            'repo-common.ps1'
        )) {
            Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts/$scriptName") -Destination (Join-Path $tpl "scripts/$scriptName") -Force
        }
        New-Item -ItemType Directory -Path (Join-Path $tpl 'tools/gitleaks') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json') -Destination (Join-Path $tpl 'tools/gitleaks/gitleaks.lock.json') -Force
        $gitleaks = Join-Path $RepoRoot '.gitleaks.toml'
        if (Test-Path -LiteralPath $gitleaks) { Copy-Item -LiteralPath $gitleaks -Destination $tpl -Force }
        & git -C $tpl init --quiet
        if ($LASTEXITCODE -ne 0) { throw "Unable to initialize config-sync fixture repository: $tpl" }
        $script:templateRepo = $tpl
    }
    $tr = Join-Path $work $Name
    Copy-Item -LiteralPath $script:templateRepo -Destination $tr -Recurse -Force
    return $tr
}

function Invoke-Script {
    # Run a config script through the shared helper.
    param([Parameter(Mandatory)] [string] $Script, [string[]] $ScriptArgs = @())
    Invoke-TestProcess -ScriptPath $Script -Arguments $ScriptArgs
}

function Invoke-UnmarkedRulesPush([hashtable] $Parameters) {
    # Capture the original error before the console wraps the marker text. Rethrowing
    # keeps the real child process exit code for both preview and Apply.
    $message = @(& pwsh -NoProfile -Command {
        param($scriptPath, $options)
        try { & $scriptPath @options > $null }
        catch { Write-Output $_.Exception.Message; throw }
    } -Args $pushScript, $Parameters 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Message = ($message -join "`n") }
}

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    Set-TestFile -Path $Path -Content $Content
}

$outcome = 'Failed'
$exceptionType = ''
$failureScript = ''
$failureLine = 0
$savedHermesHome = $env:HERMES_HOME
$savedHermesSuffix = $env:HERMES_DATA_DIR_SUFFIX
try {
    Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:HERMES_DATA_DIR_SUFFIX -ErrorAction SilentlyContinue
    $defaultRepo = New-TempRepo 'codex-default-repo'
    $defaultHome = Join-Path $work 'codex-default-home'
    Set-File (Join-Path $defaultRepo 'codex/AGENTS.md') '# Managed defaults'
    Set-File (Join-Path $defaultRepo 'antigravity/AGENTS.md') '# Antigravity defaults'
    Set-File (Join-Path $defaultHome '.claude/settings.json') '{"personal":true}'
    Set-File (Join-Path $defaultHome '.zcode/AGENTS.md') '# Personal ZCode defaults'
    Set-File (Join-Path $defaultHome '.codex/AGENTS.md') "<!-- BEGIN AI-AGENT-DOTFILES: codex/AGENTS.md -->`n# Managed defaults`n<!-- END AI-AGENT-DOTFILES: codex/AGENTS.md -->"
    Set-File (Join-Path $defaultHome '.gemini/config/AGENTS.md') '# Antigravity defaults'
    foreach ($configScript in @($statusScript, $pullScript, $pushScript)) {
        $arguments = @('-RepoRoot', $defaultRepo, '-HomeRoot', $defaultHome)
        if ($configScript -eq $statusScript) { $arguments += '-Json' }
        $defaultRun = Invoke-Script -Script $configScript -ScriptArgs $arguments
        $codexOnly = if ($configScript -eq $statusScript -and $defaultRun.Code -eq 0) {
            $platforms = @(($defaultRun.Out | ConvertFrom-Json).Platform | Select-Object -Unique)
            $platforms.Count -eq 1 -and $platforms[0] -eq 'Codex'
        }
        else { $defaultRun.Out -match '(?m)scope: Codex\s*$' }
        Assert ($defaultRun.Code -eq 0 -and $codexOnly) "config defaults to Codex: $(Split-Path -Leaf $configScript)"
        $emptyPlatformRun = Invoke-Script -Script $configScript -ScriptArgs @('-RepoRoot', $defaultRepo, '-HomeRoot', $defaultHome, '-Platform', '')
        Assert ($emptyPlatformRun.Code -ne 0 -and $emptyPlatformRun.Out -match 'requires at least one platform name') "config script rejects empty -Platform with descriptive error: $(Split-Path -Leaf $configScript)"
    }

    # Platform parsing unification tests (Resolve-ConfigPlatforms)
    Assert ((Resolve-ConfigPlatforms -Values @('Codex,Antigravity')) -join ',' -eq 'Codex,Antigravity') 'Resolve-ConfigPlatforms splits comma-separated strings'
    Assert ((Resolve-ConfigPlatforms -Values @(' codex , ANTIGRAVITY ')) -join ',' -eq 'Codex,Antigravity') 'Resolve-ConfigPlatforms trims whitespace and normalizes case'
    Assert ((Resolve-ConfigPlatforms -Values @('Codex', 'codex', 'CODEX')) -join ',' -eq 'Codex') 'Resolve-ConfigPlatforms deduplicates names preserving order'
    Assert ((Resolve-ConfigPlatforms -Values @('Codex', 'Antigravity')) -join ',' -eq 'Codex,Antigravity') 'Resolve-ConfigPlatforms supports both config platforms'
    Assert ((Resolve-ConfigPlatforms -Values @('Hermes')) -join ',' -eq 'Hermes') 'Resolve-ConfigPlatforms supports Hermes'
    Assert ((Resolve-ConfigPlatforms -Values @(' codex , hermes , ANTIGRAVITY ')) -join ',' -eq 'Codex,Hermes,Antigravity') 'Resolve-ConfigPlatforms normalizes Hermes alongside Codex and Antigravity'
    try { $null = Resolve-ConfigPlatforms -Values @('BadPlatform'); Assert $false 'Expected exception on unsupported platform' }
    catch { Assert ($_.Exception.Message -match "Unsupported config platform 'BadPlatform'" -and $_.Exception.Message -match 'Expected Codex, Antigravity, or Hermes\.') 'Resolve-ConfigPlatforms rejects unsupported platform' }
    try { $null = Resolve-ConfigPlatforms -Values @(''); Assert $false 'Expected exception on empty platform string' }
    catch { Assert ($_.Exception.Message -match 'requires at least one platform name' -and $_.Exception.Message -match 'Expected Codex, Antigravity, or Hermes\.') 'Resolve-ConfigPlatforms rejects empty platform string' }

    $managedAgentsTargets = @(
        @{ Platform = 'Codex'; Item = 'AGENTS.md'; RepoRel = 'codex/AGENTS.md'; HomeRel = '.codex/AGENTS.md'; BlockId = 'codex/AGENTS.md' }
        @{ Platform = 'Antigravity'; Item = 'AGENTS.md'; RepoRel = 'antigravity/AGENTS.md'; HomeRel = '.gemini/config/AGENTS.md'; BlockId = 'antigravity/AGENTS.md' }
        @{ Platform = 'Hermes'; Item = 'SOUL.md'; RepoRel = 'hermes/SOUL.md'; HomeRel = 'AppData/Local/hermes/SOUL.md'; BlockId = 'hermes/SOUL.md' }
    )

    # ===========================================================================
    Write-Host "`n[config-status]" -ForegroundColor Cyan
    # ===========================================================================
    $tr = New-TempRepo -Name 'status-empty-repo'
    $th = Join-Path $work 'status-empty-home'
    $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-Json')
    Assert ($r.Code -eq 0 -and $r.Out.Trim() -eq '[]') 'status: no managed items emits an empty JSON array'

    $tr = New-TempRepo -Name 'status-repo'
    $th = Join-Path $work 'status-home'
    Set-File -Path (Join-Path $tr 'codex/prompts/example.md') -Content 'same'
    Set-File -Path (Join-Path $th '.codex/prompts/example.md') -Content 'same'
    Set-File -Path (Join-Path $th '.codex/AGENTS.md') -Content 'personal rules'    # home-only
    $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-Json')
    $rows = $r.Out | ConvertFrom-Json
    Assert ($r.Out.TrimStart().StartsWith('[') -and @($rows).Count -eq 2) 'status: multiple managed items emit a JSON array'
    $byItem = @{}; foreach ($row in $rows) { $byItem[$row.Item] = $row.Status }
    Assert ($byItem['prompts'] -eq 'in-sync') "status: identical directory contents -> in-sync"
    Assert ($byItem['AGENTS.md'] -eq 'home-only') "status: home-only file -> home-only"
    Assert (($rows | Where-Object Item -eq 'AGENTS.md').Detail -match 'requires a valid managed block') 'status explains the prerequisite for capturing personal rules'

    Set-File -Path (Join-Path $th '.codex/prompts/example.md') -Content 'changed'
    $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-Json')
    $rows = $r.Out | ConvertFrom-Json
    $promptRow = $rows | Where-Object { $_.Item -eq 'prompts' }
    Assert ($promptRow.Status -eq 'differs') "status: differing directory contents -> differs"

    Assert (($promptRow.PSObject.Properties.Name -join ',') -eq 'Platform,Item,Status,Detail') 'status: JSON reports the file-level schema'

    foreach ($target in $managedAgentsTargets) {
        $tr = New-TempRepo -Name "status-$($target.Platform.ToLowerInvariant())-repo"
        $th = Join-Path $work "status-$($target.Platform.ToLowerInvariant())-home"
        Set-File -Path (Join-Path $tr $target.RepoRel) -Content 'same'
        Set-File -Path (Join-Path $th $target.HomeRel) -Content 'same'
        $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-Json')
        $rows = $r.Out | ConvertFrom-Json
        $row = $rows | Where-Object { $_.Item -eq $target.Item }
        Assert ($row.Status -eq 'differs' -and $row.Detail -eq 'managed block missing; pull would add it') "status: identical $($target.Platform) content still needs its managed block"
        Set-File -Path (Join-Path $th $target.HomeRel) -Content "<!-- BEGIN AI-AGENT-DOTFILES: $($target.BlockId) -->`nsame`n<!-- END AI-AGENT-DOTFILES: $($target.BlockId) -->`n"
        $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-Json')
        $row = ($r.Out | ConvertFrom-Json) | Where-Object { $_.Item -eq $target.Item }
        Assert ($row.Status -eq 'in-sync' -and $row.Detail -eq 'managed block') "status: a matching $($target.Platform) managed block is in sync"
        Assert ($r.Out.TrimStart().StartsWith('[') -and @($rows).Count -eq 1) "status: one managed $($target.Platform) item still emits a JSON array"
    }
    foreach ($retired in 'Reasonix', 'Claude', 'ZCode') {
        foreach ($configScript in $statusScript, $pullScript, $pushScript) {
            $arguments = @('-RepoRoot', $defaultRepo, '-HomeRoot', $defaultHome, '-Platform', $retired)
            if ($configScript -ne $statusScript) {
                $arguments += @('-BackupRoot', (Join-Path $work 'retired-backup'), '-Apply')
            }
            $r = Invoke-Script -Script $configScript -ScriptArgs $arguments
            Assert ($r.Code -ne 0 -and $r.Out -match "Unsupported config platform '$retired'") "config: $(Split-Path -Leaf $configScript) rejects retired platform $retired"
        }
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $defaultRepo 'claude')) -and -not (Test-Path -LiteralPath (Join-Path $defaultRepo 'zcode'))) 'push: retired platform capture does not recreate a repository directory'
    Assert ((Get-Content -LiteralPath (Join-Path $defaultHome '.claude/settings.json') -Raw) -eq '{"personal":true}' -and (Get-Content -LiteralPath (Join-Path $defaultHome '.zcode/AGENTS.md') -Raw) -eq '# Personal ZCode defaults') 'pull: retired platform selection preserves personal settings'

    # Multi-platform status execution test
    $multiStatus = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'codex, Antigravity', '-Json')
    Assert ($multiStatus.Code -eq 0) 'config-status accepts comma-separated mixed-case platforms'

    # ===========================================================================
    Write-Host "`n[config-pull]" -ForegroundColor Cyan
    # ===========================================================================
    foreach ($target in $managedAgentsTargets) {
        $slug = $target.Platform.ToLowerInvariant()
        $tr = New-TempRepo -Name "pull-$slug-block-repo"
        $th = Join-Path $work "pull-$slug-block-home"
        $bk = Join-Path $work "pull-$slug-block-backup"
        $repoAgents = Join-Path $tr $target.RepoRel
        $homeAgents = Join-Path $th $target.HomeRel
        Set-File -Path $repoAgents -Content "# Managed`n`nRule v1.`n"
        Set-File -Path $homeAgents -Content "# Managed`n`nRule v1.`n"
        $beforeHash = (Get-FileHash -LiteralPath $homeAgents).Hash
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform)
        Assert ($r.Code -eq 0 -and $r.Out -match "update\s+$([regex]::Escape($target.Platform))/$([regex]::Escape($target.Item))" -and $r.Out -match 'managed block.*content outside it is preserved' -and (Get-FileHash -LiteralPath $homeAgents).Hash -eq $beforeHash) "pull: $($target.Platform) dry-run plans managed-block migration without writing"
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
        $text = Get-Content -Raw -LiteralPath $homeAgents
        Assert ($r.Code -eq 0 -and $text -match "BEGIN AI-AGENT-DOTFILES: $([regex]::Escape($target.BlockId))" -and $text -match 'Rule v1' -and $text -match "END AI-AGENT-DOTFILES: $([regex]::Escape($target.BlockId))") "pull: $($target.Platform) equal legacy content is wrapped in the managed block"
        [IO.File]::AppendAllText($homeAgents, "`n## Personal`nMine`n", [Text.UTF8Encoding]::new($false))
        Set-File -Path $repoAgents -Content "# Managed`n`nRule v2.`n"
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
        $text = Get-Content -Raw -LiteralPath $homeAgents
        Assert ($r.Code -eq 0 -and $text -match 'Rule v2' -and $text -notmatch 'Rule v1' -and $text -match '## Personal' -and $text -match 'Mine') "pull: $($target.Platform) updates only the managed block and preserves personal content"
        $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-Json')
        $row = ($r.Out | ConvertFrom-Json) | Where-Object { $_.Item -eq $target.Item }
        Assert ($r.Code -eq 0 -and $row.Status -eq 'in-sync' -and $row.Detail -eq 'managed block') "status: the merged $($target.Platform) file is in sync"

        $tr = New-TempRepo -Name "pull-$slug-no-marker-repo"
        $th = Join-Path $work "pull-$slug-no-marker-home"
        $bk = Join-Path $work "pull-$slug-no-marker-backup"
        Set-File -Path (Join-Path $tr $target.RepoRel) -Content "# Managed`n"
        Set-File -Path (Join-Path $th $target.HomeRel) -Content "# Personal only`n"
        $noMarker = Join-Path $th $target.HomeRel
        $noMarkerHash = (Get-FileHash -LiteralPath $noMarker).Hash
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
        Assert ($r.Code -ne 0 -and $r.Out -match 'no AI-AGENT-DOTFILES managed block' -and (Get-FileHash -LiteralPath $noMarker).Hash -eq $noMarkerHash) "pull: differing $($target.Platform) content without a block fails closed"
    }

    $tr = New-TempRepo -Name 'pull-repo'
    $th = Join-Path $work 'pull-home'
    $bk = Join-Path $work 'pull-backup'
    Set-File -Path (Join-Path $tr 'codex/prompts/example.md') -Content 'deploy-me'

    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex')
    Assert ($r.Out -match 'add\s+Codex/prompts/example.md') "pull: dry-run plans add"
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.codex/prompts/example.md'))) "pull: dry-run writes nothing"

    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
    $deployed = Join-Path $th '.codex/prompts/example.md'
    Assert ((Test-Path -LiteralPath $deployed) -and ((Get-Content -Raw -LiteralPath $deployed).TrimEnd("`r","`n") -eq 'deploy-me')) "pull: apply deploys file"

    Set-File -Path (Join-Path $th '.codex/keep-me.txt') -Content 'home-only'    # not a managed item
    Set-Content -LiteralPath $deployed -Value 'stale' -NoNewline
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
    Assert ((Get-Content -Raw -LiteralPath $deployed).TrimEnd("`r","`n") -eq 'deploy-me') "pull: update overwrites stale home copy"
    $bakFile = Get-ChildItem -Recurse -File -LiteralPath $bk -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'example.md' } | Select-Object -First 1
    Assert ($null -ne $bakFile -and (Get-Content -Raw -LiteralPath $bakFile.FullName) -eq 'stale') "pull: overwritten home file is backed up"
    Assert (Test-Path -LiteralPath (Join-Path $th '.codex/keep-me.txt')) "pull: home-only file survives (no prune)"

    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex')
    Assert ($r.Out -match 'Nothing to deploy') "pull: idempotent dry-run is a no-op"

    $tr = New-TempRepo -Name 'pull-prompts-repo'
    $th = Join-Path $work 'pull-prompts-home'
    $bk = Join-Path $work 'pull-prompts-backup'
    Set-File -Path (Join-Path $tr 'codex/prompts/ok.md') -Content 'prompt bytes'
    Set-File -Path (Join-Path $tr 'codex/prompts/sketch.local.toml') -Content 'local = true'
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
    Assert ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $th '.codex/prompts/ok.md'))) "pull: apply copies a managed directory item"
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.codex/prompts/sketch.local.toml'))) "pull: *.local.toml inside a managed directory is not copied"

    Set-File -Path (Join-Path $tr 'codex/prompts/ok.md') -Content 'updated prompt'
    Set-File -Path (Join-Path $tr 'codex/prompts/nested/new.md') -Content 'new prompt'
    Set-File -Path (Join-Path $tr 'codex/prompts/same.md') -Content 'same prompt'
    Set-File -Path (Join-Path $th '.codex/prompts/same.md') -Content 'same prompt'
    Set-File -Path (Join-Path $th '.codex/prompts/home-only.md') -Content 'keep prompt'
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex')
    Assert ($r.Code -eq 0 -and $r.Out -match 'update\s+Codex/prompts/ok.md' -and $r.Out -match 'add\s+Codex/prompts/nested/new.md') 'pull: directory plan identifies updates and nested adds'
    Assert ($r.Out -notmatch 'same.md|home-only.md|sketch.local.toml' -and $r.Out -match 'add=1' -and $r.Out -match 'update=1') 'pull: directory plan omits unchanged, destination-only and excluded files'
    Assert ((Get-Content -LiteralPath (Join-Path $th '.codex/prompts/ok.md') -Raw) -eq 'prompt bytes' -and -not (Test-Path -LiteralPath (Join-Path $th '.codex/prompts/nested/new.md'))) 'pull: directory dry-run preserves destination bytes'

    # Let the real scan finish, then save a personal edit before the planned write.
    foreach ($action in @('update', 'add')) {
        $tr = New-TempRepo -Name "pull-race-$action-repo"
        $th = Join-Path $work "pull-race-$action-home"
        $bk = Join-Path $work "pull-race-$action-backup"
        $file = Join-Path $th '.codex/AGENTS.md'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null
        Set-File (Join-Path $tr 'codex/AGENTS.md') 'updated rules'
        if ($action -eq 'update') {
            Set-File $file "<!-- BEGIN AI-AGENT-DOTFILES: codex/AGENTS.md -->`nold rules`n<!-- END AI-AGENT-DOTFILES: codex/AGENTS.md -->`n"
        }
        $expected = if ($action -eq 'update') { [IO.File]::ReadAllText($file) } else { '' }
        $expected += 'concurrent personal edit'
        $scan = Join-Path $tr 'scripts/scan-secrets.ps1'
        Rename-Item -LiteralPath $scan -NewName 'original-scan.ps1'
        Set-File $scan @'
param([string] $RepoRoot)
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'original-scan.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$homeName = (Split-Path -Leaf $RepoRoot) -replace '-repo$', '-home'
$destination = Join-Path (Split-Path -Parent $RepoRoot) "$homeName/.codex/AGENTS.md"
[IO.File]::AppendAllText($destination, 'concurrent personal edit')
'@
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-BackupRoot', $bk, '-Apply')
        Assert ($r.Code -ne 0 -and [IO.File]::ReadAllText($file) -ceq $expected) "pull: a concurrent personal save survives a planned $action"
        Assert (-not (Test-Path -LiteralPath $bk)) "pull: concurrent $action drift aborts before creating a backup directory"
    }

    # Copy-mode plans (prompts/*.md) must also abort before backup or sibling writes when destination changes after planning.
    foreach ($action in @('update', 'add')) {
        $tr = New-TempRepo -Name "pull-copy-race-$action-repo"
        $th = Join-Path $work "pull-copy-race-$action-home"
        $bk = Join-Path $work "pull-copy-race-$action-backup"
        $promptFile = Join-Path $th '.codex/prompts/example.md'
        $siblingFile = Join-Path $th '.codex/prompts/sibling.md'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $promptFile)) | Out-Null
        Set-File (Join-Path $tr 'codex/prompts/example.md') 'repo prompt v2'
        Set-File (Join-Path $tr 'codex/prompts/sibling.md') 'repo sibling'
        if ($action -eq 'update') {
            Set-File $promptFile 'home prompt v1'
        }
        $expected = if ($action -eq 'update') { 'home prompt v1' + ' + concurrent edit' } else { ' + concurrent edit' }
        $scan = Join-Path $tr 'scripts/scan-secrets.ps1'
        Rename-Item -LiteralPath $scan -NewName 'original-scan.ps1'
        Set-File $scan @'
param([string] $RepoRoot)
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'original-scan.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$homeName = (Split-Path -Leaf $RepoRoot) -replace '-repo$', '-home'
$destination = Join-Path (Split-Path -Parent $RepoRoot) "$homeName/.codex/prompts/example.md"
[IO.File]::AppendAllText($destination, ' + concurrent edit')
'@
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-BackupRoot', $bk, '-Apply')
        Assert ($r.Code -ne 0 -and [IO.File]::ReadAllText($promptFile) -ceq $expected) "pull: concurrent copy-$action edit survives"
        Assert (-not (Test-Path -LiteralPath $siblingFile) -and -not (Test-Path -LiteralPath $bk)) "pull: concurrent copy-$action drift aborts before backup or sibling writes"
    }

    # Source modification after planning must abort before backup or destination writes.
    $tr = New-TempRepo -Name 'pull-source-race-repo'
    $th = Join-Path $work 'pull-source-race-home'
    $bk = Join-Path $work 'pull-source-race-backup'
    $repoPrompt = Join-Path $tr 'codex/prompts/example.md'
    $homePrompt = Join-Path $th '.codex/prompts/example.md'
    Set-File $repoPrompt 'repo prompt v2'
    Set-File $homePrompt 'home prompt v1'
    $scan = Join-Path $tr 'scripts/scan-secrets.ps1'
    Rename-Item -LiteralPath $scan -NewName 'original-scan.ps1'
    Set-File $scan @'
param([string] $RepoRoot)
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'original-scan.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
[IO.File]::AppendAllText((Join-Path $RepoRoot 'codex/prompts/example.md'), ' + post-scan mutation')
'@
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -ne 0 -and $r.Out -match 'source changed since planning' -and [IO.File]::ReadAllText($homePrompt) -ceq 'home prompt v1' -and -not (Test-Path -LiteralPath $bk)) 'pull: post-plan source mutation aborts before backup or destination write'

    # The scan must stop both adds and updates before even creating a backup.
    $tr = New-TempRepo -Name 'pull-secret-repo'
    $th = Join-Path $work 'pull-secret-home'
    $bk = Join-Path $work 'pull-secret-backup'
    $fakeToken = 'sk-' + 'ant-' + ('FAKE' * 5) + '000000'
    Set-File -Path (Join-Path $tr 'codex/prompts/example.md') -Content ('unsafe ' + $fakeToken)
    Set-File -Path (Join-Path $tr 'codex/prompts/added.md') -Content 'new prompt'
    $original = Join-Path $th '.codex/prompts/example.md'
    Set-File -Path $original -Content 'keep original bytes'
    $beforeHash = (Get-FileHash -LiteralPath $original).Hash
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -ne 0 -and $r.Out -match 'Secret scan failed') 'pull: planted source secret fails closed'
    Assert ((Get-FileHash -LiteralPath $original).Hash -eq $beforeHash) 'pull: failed scan preserves the existing home file'
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.codex/prompts/added.md'))) 'pull: failed scan writes no add'
    Assert (-not (Test-Path -LiteralPath $bk)) 'pull: failed scan creates no backup'

    # Restore bytes and remove new files; empty parent directories may remain.
    # Platform and manifest order ensure two successful writes before the blocked prompts directory.
    $tr = New-TempRepo -Name 'pull-rollback-repo'
    $th = Join-Path $work 'pull-rollback-home'
    $bk = Join-Path $work 'pull-rollback-backup'
    Set-File -Path (Join-Path $tr 'antigravity/AGENTS.md') -Content 'new Antigravity rules'
    Set-File -Path (Join-Path $tr 'codex/AGENTS.md') -Content 'updated rules'
    Set-File -Path (Join-Path $tr 'codex/prompts/fail.md') -Content 'later write'
    $original = Join-Path $th '.codex/AGENTS.md'
    Set-File -Path $original -Content "<!-- BEGIN AI-AGENT-DOTFILES: codex/AGENTS.md -->`noriginal rules`n<!-- END AI-AGENT-DOTFILES: codex/AGENTS.md -->`n"
    Set-File -Path (Join-Path $th '.codex/prompts') -Content 'parent is a file'
    $beforeHash = (Get-FileHash -LiteralPath $original).Hash
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Antigravity,Codex', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
    Assert ($r.Code -ne 0 -and $r.Out -match 'best-effort rollback') 'pull: later copy failure reports attempted recovery'
    Assert ($r.Out -match 'Could not find a part of the path') 'pull: original copy error remains visible'
    Assert ((Get-FileHash -LiteralPath $original).Hash -eq $beforeHash) 'pull: rollback restores an earlier update byte-for-byte'
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.gemini/config/AGENTS.md'))) 'pull: rollback removes an earlier add'
    $bakFile = @(Get-ChildItem -LiteralPath $bk -Filter 'AGENTS.md' -File -Recurse)
    Assert ($bakFile.Count -eq 1 -and (Get-FileHash -LiteralPath $bakFile[0].FullName).Hash -eq $beforeHash) 'pull: original backup survives rollback'

    # A pure-add plan has no mirrored backup directory to restore from.
    $tr = New-TempRepo -Name 'pull-add-rollback-repo'
    $th = Join-Path $work 'pull-add-rollback-home'
    $bk = Join-Path $work 'pull-add-rollback-backup'
    Set-File -Path (Join-Path $tr 'antigravity/AGENTS.md') -Content 'new Antigravity rules'
    Set-File -Path (Join-Path $tr 'codex/prompts/fail.md') -Content 'later write'
    Set-File -Path (Join-Path $th '.codex/prompts') -Content 'parent is a file'
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Antigravity,Codex', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
    Assert ($r.Code -ne 0 -and $r.Out -match 'best-effort rollback') 'pull: pure-add failure reports recovery without a backup'
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.gemini/config/AGENTS.md'))) 'pull: pure-add rollback removes an earlier add'
    Assert (-not (Test-Path -LiteralPath $bk)) 'pull: pure-add rollback does not invent a backup directory'

    # Pull and push must reject in-repository backup paths before changing either tree.
    $tr = New-TempRepo -Name 'backup-boundary-repo'
    $th = Join-Path $work 'backup-boundary-home'
    $repoFile = Join-Path $tr 'codex/prompts/example.md'
    $homeFile = Join-Path $th '.codex/prompts/example.md'
    Set-File $repoFile 'repository text'
    Set-File $homeFile 'personal text'
    $aliasPath = Join-Path $work 'backup-boundary-link'
    New-Item -ItemType Junction -Path $aliasPath -Target $tr | Out-Null
    Push-Location -LiteralPath $work
    try {
        $trDrive = $tr.Substring(0, 1)
        $trTail = $tr.Substring(3)
        $badRoots = @(
            $tr,
            './backup-boundary-repo/new',
            (Join-Path $tr 'new'),
            (Join-Path $aliasPath 'new'),
            "\\?\$tr",
            "\\?\$tr\new",
            "\\.\$tr\new",
            "Microsoft.PowerShell.Core\FileSystem::\\?\$tr\new",
            "\\localhost\${trDrive}`$\$trTail\new",
            "\\127.0.0.1\${trDrive}`$\$trTail\new",
            'Env:\TEMP'
        )
        foreach ($badRoot in $badRoots) {
            $rejected = $false
            $errorMessage = ''
            try {
                $null = Resolve-ConfigBackupRoot -RepoRoot $tr -BackupRoot $badRoot
            }
            catch {
                $rejected = $true
                $errorMessage = $_.Exception.Message
            }
            Assert ($rejected -and $errorMessage -match 'BackupRoot must be outside') "Resolve-ConfigBackupRoot: refuses backup root $badRoot"
        }
        $expectedOutside = [IO.Path]::GetFullPath((Join-Path $work 'backup-boundary-outside'))
        foreach ($goodRoot in @((Join-Path $work 'backup-boundary-outside'), './backup-boundary-outside')) {
            $resolvedGood = Resolve-ConfigBackupRoot -RepoRoot $tr -BackupRoot $goodRoot
            Assert ($resolvedGood -eq $expectedOutside) "Resolve-ConfigBackupRoot: accepts external backup root $goodRoot"
        }
        $cliBadRoot = Join-Path $tr 'new'
        foreach ($scriptPath in @($pullScript, $pushScript)) {
            $r = Invoke-Script -Script $scriptPath -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-BackupRoot', $cliBadRoot, '-Apply', '-SkipSecretScan')
            Assert ($r.Code -ne 0 -and $r.Out -match 'BackupRoot must be outside') "$(Split-Path -Leaf $scriptPath): refuses in-repo backup root"
        }
        Assert ([IO.File]::ReadAllText($homeFile) -ceq 'personal text' -and [IO.File]::ReadAllText($repoFile) -ceq 'repository text') 'refused backup roots preserve both originals'
        Assert (-not (Test-Path (Join-Path $tr 'new')) -and @(Get-ChildItem -LiteralPath $tr -Directory -Filter 'config-*').Count -eq 0) 'refused backup roots create no backup or stage'
    }
    finally {
        Pop-Location
        [IO.Directory]::Delete($aliasPath)
    }

    # Backups precede the guarded copy: a failed backup must leave home untouched.
    $tr = New-TempRepo -Name 'pull-backup-failure-repo'
    $th = Join-Path $work 'pull-backup-failure-home'
    $bk = Join-Path $work 'pull-blocked-backup'
    Set-File -Path (Join-Path $tr 'codex/prompts/existing.md') -Content 'updated prompt'
    Set-File -Path (Join-Path $th '.codex/prompts/existing.md') -Content 'original prompt'
    Set-File -Path (Join-Path $tr 'codex/prompts/example.md') -Content 'new file'
    Set-File -Path $bk -Content 'backup parent is a file'
    $original = Join-Path $th '.codex/prompts/existing.md'
    $beforeHash = (Get-FileHash -LiteralPath $original).Hash
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
    Assert ($r.Code -ne 0 -and $r.Out -notmatch 'best-effort rollback') 'pull: backup failure does not run rollback'
    Assert ((Get-FileHash -LiteralPath $original).Hash -eq $beforeHash) 'pull: backup failure preserves existing home bytes'
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.codex/prompts/example.md'))) 'pull: backup failure writes no add'

    # Read sharing permits planning and backup, but prevents both copy and restore.
    # A failed restore of the current item must not stop recovery of earlier writes.
    $tr = New-TempRepo -Name 'pull-restore-warning-repo'
    $th = Join-Path $work 'pull-restore-warning-home'
    $bk = Join-Path $work 'pull-restore-warning-backup'
    Set-File -Path (Join-Path $tr 'antigravity/AGENTS.md') -Content 'updated Antigravity rules'
    Set-File -Path (Join-Path $th '.gemini/config/AGENTS.md') -Content "<!-- BEGIN AI-AGENT-DOTFILES: antigravity/AGENTS.md -->`noriginal rules`n<!-- END AI-AGENT-DOTFILES: antigravity/AGENTS.md -->`n"
    Set-File -Path (Join-Path $tr 'codex/prompts/example.md') -Content 'updated bytes'
    $locked = Join-Path $th '.codex/prompts/example.md'
    Set-File -Path $locked -Content 'locked original'
    $original = Join-Path $th '.gemini/config/AGENTS.md'
    $beforeHash = (Get-FileHash -LiteralPath $original).Hash
    $handle = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Antigravity,Codex', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
    }
    finally { $handle.Dispose() }
    Assert ($r.Code -ne 0 -and $r.Out -match 'Rollback could not restore') 'pull: restore failure warns and still exits non-zero'
    Assert ($r.Out -match 'Copy-Item' -and $r.Out -match 'Original files are backed up') 'pull: restore failure retains the original copy error and backup location'
    Assert ((Get-FileHash -LiteralPath $original).Hash -eq $beforeHash) 'pull: another restore continues after one restore fails'

    # ===========================================================================
    Write-Host "`n[config-push]" -ForegroundColor Cyan
    # ===========================================================================
    $tr = New-TempRepo -Name 'push-repo'
    $th = Join-Path $work 'push-home'
    $bk = Join-Path $work 'push-backup'
    $captured = Join-Path $tr 'codex/prompts/example.md'
    Set-File -Path (Join-Path $tr 'codex/keep.txt') -Content 'repo-only'         # must survive (no prune)

    # clean capture passes both gates
    Set-File -Path (Join-Path $th '.codex/prompts/example.md') -Content 'ordinary prompt'
    $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -eq 0 -and (Test-Path -LiteralPath $captured)) "push: clean config captured (passes both gates)"
    Assert (Test-Path -LiteralPath (Join-Path $tr 'codex/keep.txt')) "push: repo-only file survives (no prune)"

    # secret gate blocks + reverts (planted fake Anthropic token).
    # Assembled at runtime so the token literal never appears in this file's source
    # (otherwise scan-secrets would block committing the test itself).
    $fakeToken = 'sk-' + 'ant-' + ('FAKE' * 5) + '000000'
    Set-File -Path (Join-Path $th '.codex/prompts/example.md') -Content ('prompt contains ' + $fakeToken)
    $beforeHash = (Get-FileHash -LiteralPath $captured).Hash
    $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply')
    Assert ($r.Code -ne 0) "push: secret gate exits non-zero"
    Assert ($r.Out -match 'exit code 1' -and $r.Out -match 'Reverted') 'push: scan failure reports its exit code and completed revert'
    Assert ((Get-FileHash -LiteralPath $captured).Hash -eq $beforeHash) "push: secret gate reverts the capture (no token kept)"

    # path gate blocks + reverts (planted machine-private path); secret scan skipped to isolate it
    Set-File -Path (Join-Path $th '.codex/prompts/example.md') -Content 'Q:\fixtures\example'
    $beforeHash = (Get-FileHash -LiteralPath $captured).Hash
    $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
    Assert ($r.Code -ne 0 -and $r.Out -match 'machine-private') "push: path gate exits non-zero"
    Assert ((Get-FileHash -LiteralPath $captured).Hash -eq $beforeHash) "push: path gate reverts the capture"

    # -SkipPathScan bypass keeps the path-bearing capture
    $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply', '-SkipSecretScan', '-SkipPathScan')
    Assert ($r.Code -eq 0 -and ((Get-Content -Raw -LiteralPath $captured) -match 'Q:\\fixtures')) "push: -SkipPathScan bypasses the path gate"

    foreach ($target in $managedAgentsTargets) {
        $slug = $target.Platform.ToLowerInvariant()
        $tr = New-TempRepo -Name "push-$slug-unmarked-repo"
        $th = Join-Path $work "push-$slug-unmarked-home"
        $bk = Join-Path $work "push-$slug-unmarked-backup"
        $repoAgents = Join-Path $tr $target.RepoRel
        $homeAgents = Join-Path $th $target.HomeRel
        $begin = "<!-- BEGIN AI-AGENT-DOTFILES: $($target.BlockId) -->"
        $end = "<!-- END AI-AGENT-DOTFILES: $($target.BlockId) -->"
        Set-File -Path $repoAgents -Content 'repository original'
        Set-File -Path $homeAgents -Content 'personal unmarked rules'
        $repoHash = (Get-FileHash -LiteralPath $repoAgents).Hash
        $homeHash = (Get-FileHash -LiteralPath $homeAgents).Hash
        $pushOptions = @{ RepoRoot = $tr; HomeRoot = $th; Platform = $target.Platform; BackupRoot = $bk }
        $failure = Invoke-UnmarkedRulesPush $pushOptions
        Assert ($failure.Code -ne 0 -and $failure.Message.Contains($target.Platform) -and $failure.Message.Contains($begin) -and $failure.Message.Contains($end) -and (Get-FileHash -LiteralPath $repoAgents).Hash -eq $repoHash -and (Get-FileHash -LiteralPath $homeAgents).Hash -eq $homeHash) "push preview: $($target.Platform) rejects unmarked personal AGENTS.md without writing"

        Set-File -Path $homeAgents -Content ''
        $repoHash = (Get-FileHash -LiteralPath $repoAgents).Hash
        $homeHash = (Get-FileHash -LiteralPath $homeAgents).Hash
        $pushOptions.Apply = $true
        $failure = Invoke-UnmarkedRulesPush $pushOptions
        Assert ($failure.Code -ne 0 -and $failure.Message.Contains($target.Platform) -and $failure.Message.Contains($begin) -and $failure.Message.Contains($end) -and (Get-FileHash -LiteralPath $repoAgents).Hash -eq $repoHash -and (Get-FileHash -LiteralPath $homeAgents).Hash -eq $homeHash) "push apply: $($target.Platform) rejects an empty unmarked AGENTS.md without writing"

        $tr = New-TempRepo -Name "push-$slug-block-repo"
        $th = Join-Path $work "push-$slug-block-home"
        $bk = Join-Path $work "push-$slug-block-backup"
        $repoAgents = Join-Path $tr $target.RepoRel
        $homeAgents = Join-Path $th $target.HomeRel
        Set-File -Path $repoAgents -Content "# Previous rules`n"
        $otherBlockId = if ($target.Platform -eq 'Codex') { 'antigravity/AGENTS.md' } else { 'codex/AGENTS.md' }
        Set-File -Path $homeAgents -Content (@(
            $begin
            '# Managed v1'
            $end
            ''
            '## Personal'
            "<!-- BEGIN AI-AGENT-DOTFILES: $otherBlockId -->"
            'Personal marked text'
            "<!-- END AI-AGENT-DOTFILES: $otherBlockId -->"
        ) -join "`n")
        $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
        $capturedAgents = Get-Content -Raw -LiteralPath $repoAgents
        Assert ($r.Code -eq 0 -and $capturedAgents.TrimEnd("`r", "`n") -eq '# Managed v1' -and $capturedAgents -notmatch 'Personal|AI-AGENT-DOTFILES') "push: $($target.Platform) capture takes only the managed block"

        Set-File -Path $homeAgents -Content (@($begin, 'Personal notes', $begin, 'Old rules', $end) -join "`n")
        $homeHash = (Get-FileHash -LiteralPath $homeAgents).Hash
        $repoHash = (Get-FileHash -LiteralPath $repoAgents).Hash
        foreach ($scriptPath in @($pullScript, $pushScript)) {
            $r = Invoke-Script -Script $scriptPath -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
            Assert ($r.Code -ne 0 -and $r.Out -match 'managed block boundaries' -and (Get-FileHash -LiteralPath $homeAgents).Hash -eq $homeHash -and (Get-FileHash -LiteralPath $repoAgents).Hash -eq $repoHash) "$($target.Platform): $(Split-Path -Leaf $scriptPath) preserves both files when a start marker is duplicated"
        }
    }

    # Regression tests: ancestor/leaf reparse guards in Assert-ConfigPullOpUnchanged & config-push,
    # Get-ConfigTargets StrictMode key safety, and Restore-Plan per-file resilience.
    $tr = New-TempRepo -Name 'reparse-config-repo'
    $th = Join-Path $work 'reparse-config-home'
    $bk = Join-Path $work 'reparse-config-backup'
    $juncOutside = Join-Path $work 'reparse-config-outside'
    [IO.Directory]::CreateDirectory($juncOutside) | Out-Null
    Set-File -Path (Join-Path $tr 'codex/prompts/example.md') -Content 'prompt'
    New-Item -ItemType Directory -Path (Join-Path $th '.codex') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $th '.codex/prompts') -Target $juncOutside | Out-Null
    try {
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-BackupRoot', $bk, '-Apply', '-SkipSecretScan')
        Assert ($r.Code -ne 0 -and $r.Out -match 'reparse' -and -not (Test-Path -LiteralPath (Join-Path $juncOutside 'example.md'))) 'pull: refuses ancestor junction on destination without writing'
    }
    finally {
        [IO.Directory]::Delete((Join-Path $th '.codex/prompts'))
    }

    $trPushJunc = New-TempRepo -Name 'reparse-push-repo'
    $thPushJunc = Join-Path $work 'reparse-push-home'
    $bkPushJunc = Join-Path $work 'reparse-push-backup'
    New-Item -ItemType Directory -Path (Join-Path $thPushJunc '.codex') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $thPushJunc '.codex/prompts') -Target $juncOutside | Out-Null
    Set-File -Path (Join-Path $juncOutside 'secret.md') -Content 'outside'
    try {
        $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $trPushJunc, '-HomeRoot', $thPushJunc, '-BackupRoot', $bkPushJunc)
        Assert ($r.Code -ne 0 -and $r.Out -match 'reparse') 'push: refuses junction on source directory'
    }
    finally {
        [IO.Directory]::Delete((Join-Path $thPushJunc '.codex/prompts'))
    }

    # Get-ConfigTargets safely handles missing platform or missing PushItems/PullItems keys.
    $targetsMissingKey = @(Get-ConfigTargets -RepoRoot $tr -HomeRoot $th -Platform @('Codex', 'NonExistent') -ItemKeys @('MissingKey'))
    Assert ($targetsMissingKey.Count -eq 1 -and $targetsMissingKey[0].Items.Count -eq 0) 'Get-ConfigTargets handles missing platform and item keys under StrictMode'

    # Push revert resilience: a directory occupying an added target or a locked file must not stop restoring other files.
    $trRev = New-TempRepo -Name 'push-restore-repo'
    $thRev = Join-Path $work 'push-restore-home'
    $bkRev = Join-Path $work 'push-restore-backup'
    Set-File -Path (Join-Path $trRev 'codex/prompts/existing.md') -Content 'repo original'
    Set-File -Path (Join-Path $thRev '.codex/prompts/existing.md') -Content 'home updated'
    Set-File -Path (Join-Path $thRev '.codex/prompts/added.md') -Content ('sk-' + 'ant-' + ('FAKE' * 5) + '000000')
    $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $trRev, '-HomeRoot', $thRev, '-BackupRoot', $bkRev, '-Apply')
    Assert ($r.Code -ne 0 -and ((Get-Content -Raw -LiteralPath (Join-Path $trRev 'codex/prompts/existing.md')) -ceq 'repo original') -and (-not (Test-Path -LiteralPath (Join-Path $trRev 'codex/prompts/added.md')))) 'push: Restore-Plan restores updated file and removes added file on gate failure'

    # ===========================================================================
    Write-Host "`n[Hermes SOUL.md config-sync]" -ForegroundColor Cyan
    # ===========================================================================
    # 1. Real repository hermes/SOUL.md format & markers
    $realHermesSoulPath = Join-Path $RepoRoot 'hermes/SOUL.md'
    Assert (Test-Path -LiteralPath $realHermesSoulPath -PathType Leaf) 'hermes/SOUL.md exists in repository'
    $realSoulBytes = [IO.File]::ReadAllBytes($realHermesSoulPath)
    $hasBom = ($realSoulBytes.Length -ge 3 -and $realSoulBytes[0] -eq 0xEF -and $realSoulBytes[1] -eq 0xBB -and $realSoulBytes[2] -eq 0xBF)
    Assert (-not $hasBom) 'hermes/SOUL.md is UTF-8 without BOM'
    $realSoulText = [IO.File]::ReadAllText($realHermesSoulPath)
    Assert (-not $realSoulText.Contains("`r`n")) 'hermes/SOUL.md uses LF line endings'
    Assert ($realSoulText -notmatch '<!--\s*(?:BEGIN|END) AI-AGENT-DOTFILES:') 'hermes/SOUL.md contains no managed block markers'
    foreach ($marker in @('## 编码与验证', '## 执行与沟通', '## 修改、验证与提交', '## 工作区与安全', '停止条件', '小步提交', '密钥与凭据永不入库', '严禁静默降级')) {
        Assert ($realSoulText.Contains($marker)) "hermes/SOUL.md contains shared guardrail '$marker'"
    }

    # 2. Not-installed Hermes status (exit 0), pull refusal (no dir created), and push clean skip (exit 0)
    $trH = New-TempRepo -Name 'hermes-not-installed-repo'
    $thH = Join-Path $work 'hermes-not-installed-home'
    $bkH = Join-Path $work 'hermes-not-installed-backup'
    Set-File -Path (Join-Path $trH 'hermes/SOUL.md') -Content "# Hermes Repo Rules`n"
    $hermesDefaultDir = Join-Path $thH 'AppData/Local/hermes'
    $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $trH, '-HomeRoot', $thH, '-Platform', 'Hermes', '-Json')
    $rows = @($r.Out | ConvertFrom-Json)
    Assert ($r.Code -eq 0 -and $rows.Count -eq 1 -and $rows[0].Platform -eq 'Hermes' -and $rows[0].Item -eq 'SOUL.md' -and $rows[0].Status -eq 'not-installed' -and $rows[0].Detail -eq 'Hermes default home not found') 'hermes: not-installed status exits 0 with not-installed row'
    $rText = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $trH, '-HomeRoot', $thH, '-Platform', 'Hermes')
    Assert ($rText.Code -eq 0 -and $rText.Out -match 'not-installed') 'hermes: not-installed table output exits 0'
    $rPull = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $trH, '-HomeRoot', $thH, '-Platform', 'Hermes', '-BackupRoot', $bkH, '-Apply', '-SkipSecretScan')
    Assert ($rPull.Code -ne 0 -and $rPull.Out -match 'Hermes is not installed at default home' -and -not (Test-Path -LiteralPath $hermesDefaultDir)) 'hermes: pull refuses when default home is absent and creates no directory'
    $rPush = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $trH, '-HomeRoot', $thH, '-Platform', 'Hermes', '-BackupRoot', $bkH)
    Assert ($rPush.Code -eq 0 -and $rPush.Out -match 'Nothing to capture') 'hermes: push skips cleanly when Hermes is not installed'

    # 3. Blocked guards: HERMES_HOME override, HERMES_DATA_DIR_SUFFIX, non-default active_profile,
    #    directory active_profile, file root, and reparse point.
    $trBlock = New-TempRepo -Name 'hermes-blocked-repo'
    $thBlock = Join-Path $work 'hermes-blocked-home'
    $bkBlock = Join-Path $work 'hermes-blocked-backup'
    $hermesBlockDir = Join-Path $thBlock 'AppData/Local/hermes'
    [IO.Directory]::CreateDirectory($hermesBlockDir) | Out-Null
    Set-File -Path (Join-Path $trBlock 'hermes/SOUL.md') -Content "# Hermes Rules`n"
    Set-File -Path (Join-Path $hermesBlockDir 'SOUL.md') -Content "<!-- BEGIN AI-AGENT-DOTFILES: hermes/SOUL.md -->`n# Hermes Live`n<!-- END AI-AGENT-DOTFILES: hermes/SOUL.md -->`n"

    # 3a. HERMES_HOME override pointing elsewhere
    try {
        $env:HERMES_HOME = Join-Path $work 'other-hermes-home'
        $rS = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $trBlock, '-HomeRoot', $thBlock, '-Platform', 'Hermes', '-Json')
        $rows = @($rS.Out | ConvertFrom-Json)
        Assert ($rS.Code -eq 0 -and $rows.Count -eq 1 -and $rows[0].Status -eq 'blocked' -and $rows[0].Detail -eq 'hermes-home-override-unsupported') 'hermes: HERMES_HOME override reports blocked in status'
        $rP = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $trBlock, '-HomeRoot', $thBlock, '-Platform', 'Hermes', '-BackupRoot', $bkBlock, '-Apply', '-SkipSecretScan')
        Assert ($rP.Code -ne 0 -and $rP.Out -match 'Hermes config pull blocked \(hermes-home-override-unsupported\)') 'hermes: HERMES_HOME override blocks pull'
        $rU = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $trBlock, '-HomeRoot', $thBlock, '-Platform', 'Hermes', '-BackupRoot', $bkBlock, '-Apply', '-SkipSecretScan')
        Assert ($rU.Code -ne 0 -and $rU.Out -match 'Hermes config push blocked \(hermes-home-override-unsupported\)') 'hermes: HERMES_HOME override blocks push'

        # Matching HERMES_HOME equals default path -> allowed
        $env:HERMES_HOME = ($hermesBlockDir + '\').Replace('\', '/')
        $stateMatch = Get-ConfigHermesRootState -HomeRoot $thBlock
        Assert ($stateMatch.Installed -and -not $stateMatch.Blocked) 'hermes: HERMES_HOME matching default path is allowed'
    }
    finally {
        Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
    }

    # 3b. HERMES_DATA_DIR_SUFFIX
    try {
        $env:HERMES_DATA_DIR_SUFFIX = 'dev'
        $rS = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $trBlock, '-HomeRoot', $thBlock, '-Platform', 'Hermes', '-Json')
        $rows = @($rS.Out | ConvertFrom-Json)
        Assert ($rS.Code -eq 0 -and $rows[0].Status -eq 'blocked' -and $rows[0].Detail -eq 'hermes-home-override-unsupported') 'hermes: HERMES_DATA_DIR_SUFFIX reports blocked in status'
        $rP = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $trBlock, '-HomeRoot', $thBlock, '-Platform', 'Hermes', '-BackupRoot', $bkBlock, '-Apply', '-SkipSecretScan')
        Assert ($rP.Code -ne 0 -and $rP.Out -match 'Hermes config pull blocked \(hermes-home-override-unsupported\)') 'hermes: HERMES_DATA_DIR_SUFFIX blocks pull'
        $rU = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $trBlock, '-HomeRoot', $thBlock, '-Platform', 'Hermes', '-BackupRoot', $bkBlock, '-Apply', '-SkipSecretScan')
        Assert ($rU.Code -ne 0 -and $rU.Out -match 'Hermes config push blocked \(hermes-home-override-unsupported\)') 'hermes: HERMES_DATA_DIR_SUFFIX blocks push'
    }
    finally {
        Remove-Item Env:HERMES_DATA_DIR_SUFFIX -ErrorAction SilentlyContinue
    }

    # 3c. Non-default active_profile, directory active_profile, and 'default' active_profile
    $activeProfileFile = Join-Path $hermesBlockDir 'active_profile'
    Set-File -Path $activeProfileFile -Content "work`n"
    $rS = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $trBlock, '-HomeRoot', $thBlock, '-Platform', 'Hermes', '-Json')
    $rows = @($rS.Out | ConvertFrom-Json)
    Assert ($rS.Code -eq 0 -and $rows[0].Status -eq 'blocked' -and $rows[0].Detail -eq 'hermes-non-default-profile-unsupported') 'hermes: non-default active_profile reports blocked in status'
    $rP = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $trBlock, '-HomeRoot', $thBlock, '-Platform', 'Hermes', '-BackupRoot', $bkBlock, '-Apply', '-SkipSecretScan')
    Assert ($rP.Code -ne 0 -and $rP.Out -match 'Hermes config pull blocked \(hermes-non-default-profile-unsupported\)') 'hermes: non-default active_profile blocks pull'
    $rU = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $trBlock, '-HomeRoot', $thBlock, '-Platform', 'Hermes', '-BackupRoot', $bkBlock, '-Apply', '-SkipSecretScan')
    Assert ($rU.Code -ne 0 -and $rU.Out -match 'Hermes config push blocked \(hermes-non-default-profile-unsupported\)') 'hermes: non-default active_profile blocks push'

    Set-File -Path $activeProfileFile -Content "DEFAULT`n"
    $stateDefaultProfile = Get-ConfigHermesRootState -HomeRoot $thBlock
    Assert ($stateDefaultProfile.Installed -and -not $stateDefaultProfile.Blocked) 'hermes: default active_profile is allowed'

    Remove-Item -LiteralPath $activeProfileFile -Force
    New-Item -ItemType Directory -Path $activeProfileFile -Force | Out-Null
    $stateDirProfile = Get-ConfigHermesRootState -HomeRoot $thBlock
    Assert ($stateDirProfile.Blocked -and $stateDirProfile.Reason -eq 'hermes-active-profile-invalid') 'hermes: directory active_profile is blocked'

    # 3d. Leaf file hermes root and junction hermes root
    $thLeaf = Join-Path $work 'hermes-leaf-home'
    Set-File -Path (Join-Path $thLeaf 'AppData/Local/hermes') -Content 'not a directory'
    $stateLeaf = Get-ConfigHermesRootState -HomeRoot $thLeaf
    Assert ($stateLeaf.Blocked -and $stateLeaf.Reason -eq 'hermes-root-not-directory') 'hermes: file at default root is blocked'

    $thJunc = Join-Path $work 'hermes-junc-home'
    $juncTarget = Join-Path $work 'hermes-junc-target'
    [IO.Directory]::CreateDirectory($juncTarget) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $thJunc 'AppData/Local')) | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $thJunc 'AppData/Local/hermes') -Target $juncTarget | Out-Null
    try {
        $stateJunc = Get-ConfigHermesRootState -HomeRoot $thJunc
        Assert ($stateJunc.Blocked -and $stateJunc.Reason -eq 'reparse-point-blocked') 'hermes: reparse point at default root is blocked'
    }
    finally {
        [IO.Directory]::Delete((Join-Path $thJunc 'AppData/Local/hermes'))
    }

    # 4. Managed-block pull preserving outside persona + push capturing only block body + exclusions
    $trExcl = New-TempRepo -Name 'hermes-excl-repo'
    $thExcl = Join-Path $work 'hermes-excl-home'
    $bkExcl = Join-Path $work 'hermes-excl-backup'
    $hermesExclDir = Join-Path $thExcl 'AppData/Local/hermes'
    [IO.Directory]::CreateDirectory($hermesExclDir) | Out-Null
    Set-File -Path (Join-Path $trExcl 'hermes/SOUL.md') -Content "# Hermes Managed v1`n"
    Set-File -Path (Join-Path $trExcl 'hermes/config.yaml') -Content "repo_yaml: should_not_pull`n"
    Set-File -Path (Join-Path $hermesExclDir 'SOUL.md') -Content (@(
        '# My Custom Persona Top'
        ''
        '<!-- BEGIN AI-AGENT-DOTFILES: hermes/SOUL.md -->'
        '# Hermes Managed v0'
        '<!-- END AI-AGENT-DOTFILES: hermes/SOUL.md -->'
        ''
        '# My Custom Persona Bottom'
    ) -join "`n")
    Set-File -Path (Join-Path $hermesExclDir 'config.yaml') -Content "api_key: local-only`n"
    Set-File -Path (Join-Path $hermesExclDir '.env') -Content "SECRET_KEY=local-only`n"
    Set-File -Path (Join-Path $hermesExclDir 'auth.json') -Content '{"token":"local-only"}'

    $hermesTarget = Get-ConfigTargets -RepoRoot $trExcl -HomeRoot $thExcl -Platform @('Hermes') -ItemKeys @('PushItems', 'PullItems')
    Assert (($hermesTarget.Items -join ',') -eq 'SOUL.md') 'hermes: whitelist selects only SOUL.md'
    foreach ($excludedName in @('config.yaml', '.env', 'auth.json', 'vault', 'memories', 'sessions', 'active_profile', 'state.db')) {
        Assert (Test-Excluded -RelativePath $excludedName -Patterns $hermesTarget.Excluded) "hermes: excludes $excludedName"
    }

    $rPull = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $trExcl, '-HomeRoot', $thExcl, '-Platform', 'Hermes', '-BackupRoot', $bkExcl, '-Apply', '-SkipSecretScan')
    $pulledSoul = [IO.File]::ReadAllText((Join-Path $hermesExclDir 'SOUL.md'))
    Assert ($rPull.Code -eq 0 -and $pulledSoul -match '# My Custom Persona Top' -and $pulledSoul -match '# My Custom Persona Bottom' -and $pulledSoul -match '# Hermes Managed v1' -and $pulledSoul -notmatch '# Hermes Managed v0') 'hermes: pull updates only managed block and preserves outside persona'
    Assert (([IO.File]::ReadAllText((Join-Path $hermesExclDir 'config.yaml'))) -eq "api_key: local-only`n" -and ([IO.File]::ReadAllText((Join-Path $hermesExclDir '.env'))) -eq "SECRET_KEY=local-only`n" -and ([IO.File]::ReadAllText((Join-Path $hermesExclDir 'auth.json'))) -eq '{"token":"local-only"}') 'hermes: pull leaves config.yaml, .env, and auth.json untouched'

    [IO.File]::WriteAllText((Join-Path $hermesExclDir 'SOUL.md'), (@(
        '# My Custom Persona Top'
        ''
        '<!-- BEGIN AI-AGENT-DOTFILES: hermes/SOUL.md -->'
        '# Hermes Managed v2'
        '<!-- END AI-AGENT-DOTFILES: hermes/SOUL.md -->'
        ''
        '# My Custom Persona Bottom'
    ) -join "`n"), [Text.UTF8Encoding]::new($false))
    $rPush = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $trExcl, '-HomeRoot', $thExcl, '-Platform', 'Hermes', '-BackupRoot', $bkExcl, '-Apply', '-SkipSecretScan')
    $capturedSoul = [IO.File]::ReadAllText((Join-Path $trExcl 'hermes/SOUL.md'))
    Assert ($rPush.Code -eq 0 -and $capturedSoul.TrimEnd("`r", "`n") -eq '# Hermes Managed v2' -and $capturedSoul -notmatch 'Custom Persona|AI-AGENT-DOTFILES') 'hermes: push captures only managed block body'
    Assert (-not (Test-Path -LiteralPath (Join-Path $trExcl 'hermes/.env')) -and -not (Test-Path -LiteralPath (Join-Path $trExcl 'hermes/auth.json')) -and ([IO.File]::ReadAllText((Join-Path $trExcl 'hermes/config.yaml'))) -eq "repo_yaml: should_not_pull`n") 'hermes: push never captures config.yaml, .env, or auth.json'

    if ($script:fail -eq 0) { $outcome = 'Passed' }
}
catch {
    $exceptionType = $_.Exception.GetType().Name
    $failureScript = [IO.Path]::GetFileName($_.InvocationInfo.ScriptName)
    $failureLine = $_.InvocationInfo.ScriptLineNumber
    Write-Host ('Fixture failure: ' + $exceptionType) -ForegroundColor Red
}
finally {
    if ($null -eq $savedHermesHome) { Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue }
    else { $env:HERMES_HOME = $savedHermesHome }
    if ($null -eq $savedHermesSuffix) { Remove-Item Env:HERMES_DATA_DIR_SUFFIX -ErrorAction SilentlyContinue }
    else { $env:HERMES_DATA_DIR_SUFFIX = $savedHermesSuffix }
    # The fixture calls only synchronous children. A forced timeout skips this block;
    # its owning parent records the exact workspace without assuming descendants stopped.
    Complete-ConfigSyncTestWork -RepoRoot $RepoRoot -WorkRoot $work -RunId $WorkspaceRunId `
        -Outcome $outcome -FailureMessages $script:failureMessages.ToArray() -ExceptionType $exceptionType `
        -FailureScript $failureScript -FailureLine $failureLine -RemovePayload
}
Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
if ($outcome -eq 'Passed') { exit 0 }
Write-Host ('Failure summary: ' + (Join-Path $RepoRoot "tmp/tests/config-sync/receipts/$WorkspaceRunId.json")) -ForegroundColor Yellow
exit 1
