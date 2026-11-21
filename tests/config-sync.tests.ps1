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

function New-TempRepo {
    param([Parameter(Mandatory)] [string] $Name)
    $tr = Join-Path $work $Name
    New-Item -ItemType Directory -Path (Join-Path $tr 'manifests') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tr 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'manifests/whitelist.psd1') -Destination (Join-Path $tr 'manifests') -Force
    foreach ($name in @(
        'scan-secrets.ps1'
        'pinned-tool.ps1'
        'repo-common.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts/$name") -Destination (Join-Path $tr "scripts/$name") -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $tr 'tools/gitleaks') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json') -Destination (Join-Path $tr 'tools/gitleaks/gitleaks.lock.json') -Force
    $gitleaks = Join-Path $RepoRoot '.gitleaks.toml'
    if (Test-Path -LiteralPath $gitleaks) { Copy-Item -LiteralPath $gitleaks -Destination $tr -Force }
    & git -C $tr init --quiet
    if ($LASTEXITCODE -ne 0) { throw "Unable to initialize config-sync fixture repository: $tr" }
    return $tr
}

function Invoke-Script {
    # Run a config script through the shared helper.
    param([Parameter(Mandatory)] [string] $Script, [string[]] $ScriptArgs = @())
    Invoke-TestProcess -ScriptPath $Script -Arguments $ScriptArgs
}

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    Set-TestFile -Path $Path -Content $Content
}

$outcome = 'Failed'
$exceptionType = ''
$failureScript = ''
$failureLine = 0
try {
    $defaultRepo = New-TempRepo 'codex-default-repo'
    $defaultHome = Join-Path $work 'codex-default-home'
    Set-File (Join-Path $defaultRepo 'codex/AGENTS.md') '# Managed defaults'
    Set-File (Join-Path $defaultRepo 'antigravity/AGENTS.md') '# Antigravity defaults'
    Set-File (Join-Path $defaultHome '.claude/settings.json') '{"personal":true}'
    Set-File (Join-Path $defaultHome '.zcode/AGENTS.md') '# Personal ZCode defaults'
    Set-File (Join-Path $defaultHome '.codex/AGENTS.md') '# Managed defaults'
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
    try { $null = Resolve-ConfigPlatforms -Values @('BadPlatform'); Assert $false 'Expected exception on unsupported platform' }
    catch { Assert ($_.Exception.Message -match "Unsupported config platform 'BadPlatform'") 'Resolve-ConfigPlatforms rejects unsupported platform' }
    try { $null = Resolve-ConfigPlatforms -Values @(''); Assert $false 'Expected exception on empty platform string' }
    catch { Assert ($_.Exception.Message -match 'requires at least one platform name') 'Resolve-ConfigPlatforms rejects empty platform string' }

    $managedAgentsTargets = @(
        @{ Platform = 'Codex'; RepoRel = 'codex/AGENTS.md'; HomeRel = '.codex/AGENTS.md'; BlockId = 'codex/AGENTS.md' }
        @{ Platform = 'Antigravity'; RepoRel = 'antigravity/AGENTS.md'; HomeRel = '.gemini/config/AGENTS.md'; BlockId = 'antigravity/AGENTS.md' }
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
        $row = $rows | Where-Object { $_.Item -eq 'AGENTS.md' }
        Assert ($row.Status -eq 'differs' -and $row.Detail -eq 'managed block missing; pull would add it') "status: identical $($target.Platform) content still needs its managed block"
        Set-File -Path (Join-Path $th $target.HomeRel) -Content "<!-- BEGIN AI-AGENT-DOTFILES: $($target.BlockId) -->`nsame`n<!-- END AI-AGENT-DOTFILES: $($target.BlockId) -->`n"
        $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-Json')
        $row = ($r.Out | ConvertFrom-Json) | Where-Object { $_.Item -eq 'AGENTS.md' }
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
        Assert ($r.Code -eq 0 -and $r.Out -match "update\s+$([regex]::Escape($target.Platform))/AGENTS\.md" -and $r.Out -match 'managed block.*content outside it is preserved' -and (Get-FileHash -LiteralPath $homeAgents).Hash -eq $beforeHash) "pull: $($target.Platform) dry-run plans managed-block migration without writing"
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply')
        $text = Get-Content -Raw -LiteralPath $homeAgents
        Assert ($r.Code -eq 0 -and $text -match "BEGIN AI-AGENT-DOTFILES: $([regex]::Escape($target.BlockId))" -and $text -match 'Rule v1' -and $text -match "END AI-AGENT-DOTFILES: $([regex]::Escape($target.BlockId))") "pull: $($target.Platform) equal legacy content is wrapped in the managed block"
        [IO.File]::AppendAllText($homeAgents, "`n## Personal`nMine`n", [Text.UTF8Encoding]::new($false))
        Set-File -Path $repoAgents -Content "# Managed`n`nRule v2.`n"
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply')
        $text = Get-Content -Raw -LiteralPath $homeAgents
        Assert ($r.Code -eq 0 -and $text -match 'Rule v2' -and $text -notmatch 'Rule v1' -and $text -match '## Personal' -and $text -match 'Mine') "pull: $($target.Platform) updates only the managed block and preserves personal content"
        $r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-Json')
        $row = ($r.Out | ConvertFrom-Json) | Where-Object { $_.Item -eq 'AGENTS.md' }
        Assert ($r.Code -eq 0 -and $row.Status -eq 'in-sync' -and $row.Detail -eq 'managed block') "status: the merged $($target.Platform) file is in sync"

        $tr = New-TempRepo -Name "pull-$slug-no-marker-repo"
        $th = Join-Path $work "pull-$slug-no-marker-home"
        $bk = Join-Path $work "pull-$slug-no-marker-backup"
        Set-File -Path (Join-Path $tr $target.RepoRel) -Content "# Managed`n"
        Set-File -Path (Join-Path $th $target.HomeRel) -Content "# Personal only`n"
        $noMarker = Join-Path $th $target.HomeRel
        $noMarkerHash = (Get-FileHash -LiteralPath $noMarker).Hash
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply')
        Assert ($r.Code -ne 0 -and $r.Out -match 'no AI-AGENT-DOTFILES managed block' -and (Get-FileHash -LiteralPath $noMarker).Hash -eq $noMarkerHash) "pull: differing $($target.Platform) content without a block fails closed"
    }

    $tr = New-TempRepo -Name 'pull-repo'
    $th = Join-Path $work 'pull-home'
    $bk = Join-Path $work 'pull-backup'
    Set-File -Path (Join-Path $tr 'codex/prompts/example.md') -Content 'deploy-me'

    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex')
    Assert ($r.Out -match 'add\s+Codex/prompts/example.md') "pull: dry-run plans add"
    Assert (-not (Test-Path -LiteralPath (Join-Path $th '.codex/prompts/example.md'))) "pull: dry-run writes nothing"

    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply')
    $deployed = Join-Path $th '.codex/prompts/example.md'
    Assert ((Test-Path -LiteralPath $deployed) -and ((Get-Content -Raw -LiteralPath $deployed).TrimEnd("`r","`n") -eq 'deploy-me')) "pull: apply deploys file"

    Set-File -Path (Join-Path $th '.codex/keep-me.txt') -Content 'home-only'    # not a managed item
    Set-Content -LiteralPath $deployed -Value 'stale' -NoNewline
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply')
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
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply')
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
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Antigravity,Codex', '-BackupRoot', $bk, '-Apply')
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
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Antigravity,Codex', '-BackupRoot', $bk, '-Apply')
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
        foreach ($scriptPath in @($pullScript, $pushScript)) {
            foreach ($badRoot in $badRoots) {
                $r = Invoke-Script -Script $scriptPath -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-BackupRoot', $badRoot, '-Apply')
                Assert ($r.Code -ne 0 -and $r.Out -match 'BackupRoot must be outside') "$(Split-Path -Leaf $scriptPath): refuses backup root $badRoot"
            }
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
    $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Codex', '-BackupRoot', $bk, '-Apply')
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
        $r = Invoke-Script -Script $pullScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', 'Antigravity,Codex', '-BackupRoot', $bk, '-Apply')
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
        $tr = New-TempRepo -Name "push-$slug-block-repo"
        $th = Join-Path $work "push-$slug-block-home"
        $bk = Join-Path $work "push-$slug-block-backup"
        $repoAgents = Join-Path $tr $target.RepoRel
        $homeAgents = Join-Path $th $target.HomeRel
        Set-File -Path $repoAgents -Content "# Managed v1`n"
        Set-File -Path $homeAgents -Content "<!-- BEGIN AI-AGENT-DOTFILES: $($target.BlockId) -->`n# Managed v1`n<!-- END AI-AGENT-DOTFILES: $($target.BlockId) -->`n`n## Personal`nMine`n"
        $r = Invoke-Script -Script $pushScript -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply')
        $capturedAgents = Get-Content -Raw -LiteralPath $repoAgents
        Assert ($r.Code -eq 0 -and $capturedAgents.TrimEnd("`r", "`n") -eq '# Managed v1' -and $capturedAgents -notmatch 'Personal|Mine') "push: $($target.Platform) capture takes only the managed block"

        $begin = "<!-- BEGIN AI-AGENT-DOTFILES: $($target.BlockId) -->"
        $end = "<!-- END AI-AGENT-DOTFILES: $($target.BlockId) -->"
        Set-File -Path $homeAgents -Content (@($begin, 'Personal notes', $begin, 'Old rules', $end) -join "`n")
        $homeHash = (Get-FileHash -LiteralPath $homeAgents).Hash
        $repoHash = (Get-FileHash -LiteralPath $repoAgents).Hash
        foreach ($scriptPath in @($pullScript, $pushScript)) {
            $r = Invoke-Script -Script $scriptPath -ScriptArgs @('-RepoRoot', $tr, '-HomeRoot', $th, '-Platform', $target.Platform, '-BackupRoot', $bk, '-Apply')
            Assert ($r.Code -ne 0 -and $r.Out -match 'managed block boundaries' -and (Get-FileHash -LiteralPath $homeAgents).Hash -eq $homeHash -and (Get-FileHash -LiteralPath $repoAgents).Hash -eq $repoHash) "$($target.Platform): $(Split-Path -Leaf $scriptPath) preserves both files when a start marker is duplicated"
        }
    }

    if ($script:fail -eq 0) { $outcome = 'Passed' }
}
catch {
    $exceptionType = $_.Exception.GetType().Name
    $failureScript = [IO.Path]::GetFileName($_.InvocationInfo.ScriptName)
    $failureLine = $_.InvocationInfo.ScriptLineNumber
    Write-Host ('Fixture failure: ' + $exceptionType) -ForegroundColor Red
}
finally {
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
