#requires -Version 7.0
<#
.SYNOPSIS
    Deploys the skills selected by one environment (harness-source/envs/<name>.psd1) to the
    live Claude, Codex and Reasonix skill directories. Dry-run unless -Apply.

.DESCRIPTION
    Builds the generated skills (scripts/build-skills.ps1) and scans for secrets
    (scripts/scan-secrets.ps1), then plans each live skill directory one at a time:
      install    selected, missing live
      update     selected, live content differs (old copy is backed up first)
      unchanged  selected, live content identical
      prune      deployed by this tool before but no longer selected, or named in -Retire
      unknown    present live but never deployed by this tool: reported, never touched
    Codex .system, reparse points and whole-directory mirrors are never touched or used.
    The previously deployed set is kept in a machine-private state file, so pruning only
    ever removes directories this tool put there (or that -Retire names explicitly).
#>
[CmdletBinding()]
param(
    [string] $Environment = 'work',
    [switch] $Apply,
    [string[]] $Retire = @(),
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = [Environment]::GetFolderPath('UserProfile'),
    [string] $StateRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-agent-dotfiles'),
    [switch] $SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$platforms = @('Claude', 'Codex', 'Reasonix')
$statePath = Join-Path $StateRoot 'deployed-skills.json'
$backupRoot = Join-Path $StateRoot ('skill-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))

function Get-DeploySkillsLiveRoot([string] $Platform) {
    switch ($Platform) {
        'Claude' { return Join-Path $HomeRoot '.claude\skills' }
        'Reasonix' { return Join-Path $HomeRoot 'AppData\Roaming\reasonix\skills' }
        'Codex' {
            $preferred = Join-Path $HomeRoot '.codex\skills'
            $fallback = Join-Path $HomeRoot '.agents\skills'
            $hasPreferred = Test-Path -LiteralPath $preferred
            $hasFallback = Test-Path -LiteralPath $fallback
            if ($hasPreferred -and $hasFallback) { throw "codex-live-root-ambiguous: both $preferred and $fallback exist" }
            if ($hasFallback) { return $fallback }
            return $preferred
        }
    }
}

function Assert-DeploySkillsPlainTree([string] $Path) {
    # Refuse any reparse point at or below a directory this tool reads, replaces or deletes.
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "reparse-point-refused: $Path" }
    $link = Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop | Select-Object -First 1
    if ($link) { throw "reparse-point-refused: $($link.FullName)" }
}

function Get-DeploySkillsTreeHash([string] $Path) {
    $rows = Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        [IO.Path]::GetRelativePath($Path, $_.FullName).Replace('\', '/') + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    return ($rows -join "`n")
}

$envPath = Join-Path $RepoRoot "harness-source\envs\$Environment.psd1"
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { throw "unknown environment: $Environment ($envPath)" }
$selection = (Import-PowerShellDataFile -LiteralPath $envPath).Skills
# A missing or misspelled platform key would read as an empty selection and prune everything.
if ($selection -isnot [hashtable] -or @($platforms | Where-Object { -not $selection.ContainsKey($_) }).Count -or @($selection.Keys | Where-Object { $_ -notin $platforms }).Count) {
    throw "env $Environment must define Skills with exactly the keys Claude, Codex and Reasonix (use @() for none)"
}

if (-not $SkipBuild) {
    & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\build-skills.ps1') -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "build-skills failed with exit code $LASTEXITCODE" }
    & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\scan-secrets.ps1') -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "scan-secrets failed with exit code $LASTEXITCODE" }
}

$state = @{}
if (Test-Path -LiteralPath $statePath) {
    $saved = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -AsHashtable
    foreach ($platform in $platforms) { $state[$platform] = @($saved[$platform] | Where-Object { $_ }) }
}
foreach ($platform in $platforms) { if (-not $state.ContainsKey($platform)) { $state[$platform] = @() } }

$plan = foreach ($platform in $platforms) {
    $liveRoot = Get-DeploySkillsLiveRoot $platform
    $sourceRoot = Join-Path $RepoRoot ($platform.ToLowerInvariant() + '\skills')
    $selected = @($selection[$platform] | Where-Object { $_ })
    foreach ($name in @($selected) + @($Retire)) {
        # No trailing dot: Win32 strips it, so 'alpha.' would resolve to 'alpha'.
        if ($name -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$') { throw "invalid skill name: '$name'" }
    }
    if ((Test-Path -LiteralPath $liveRoot) -and ((Get-Item -LiteralPath $liveRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "reparse-point-refused: $liveRoot" }
    $liveNames = if (Test-Path -LiteralPath $liveRoot) { @(Get-ChildItem -LiteralPath $liveRoot -Directory -Force | ForEach-Object Name) } else { @() }

    foreach ($name in $selected) {
        $source = Join-Path $sourceRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "selected skill '$name' has no generated output for $platform at $source" }
        $target = Join-Path $liveRoot $name
        Assert-DeploySkillsPlainTree $source
        Assert-DeploySkillsPlainTree $target
        $action = if ($name -notin $liveNames) { 'install' }
            elseif ((Get-DeploySkillsTreeHash $source) -ceq (Get-DeploySkillsTreeHash $target)) { 'unchanged' }
            else { 'update' }
        [pscustomobject]@{ Platform = $platform; Action = $action; Name = $name; Source = $source; Target = $target }
    }
    $prunable = @($state[$platform]) + @($Retire)
    foreach ($name in $liveNames) {
        if ($name -in $selected -or $name -eq '.system' -or $name.StartsWith('.deploying-')) { continue }
        $action = if ($name -in $prunable) { 'prune' } else { 'unknown' }
        if ($action -eq 'prune') { Assert-DeploySkillsPlainTree (Join-Path $liveRoot $name) }
        [pscustomobject]@{ Platform = $platform; Action = $action; Name = $name; Source = $null; Target = (Join-Path $liveRoot $name) }
    }
}

$plan | Sort-Object Platform, Action, Name | Format-Table Platform, Action, Name -AutoSize | Out-String | Write-Host
if (-not $Apply) { Write-Host "Dry run for environment '$Environment'. Re-run with -Apply to make these changes."; return }

foreach ($step in @($plan | Where-Object Action -in 'install', 'update', 'prune')) {
    $liveRoot = Split-Path -Parent $step.Target
    if ($step.Action -ne 'install') {
        Assert-DeploySkillsPlainTree $step.Target
        $backup = Join-Path $backupRoot "$($step.Platform)\$($step.Name)"
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        Copy-Item -LiteralPath $step.Target -Destination $backup -Recurse -Force
    }
    # The live directory only ever changes by whole-directory renames: a locked file makes the
    # rename fail as a unit instead of leaving a half-deleted skill. Leftover .deploying-* siblings
    # are hidden from the planner and cleaned on the next run.
    New-Item -ItemType Directory -Path $liveRoot -Force | Out-Null
    $staging = Join-Path $liveRoot ".deploying-$($step.Name)"
    $retired = Join-Path $liveRoot ".deploying-old-$($step.Name)"
    foreach ($leftover in $staging, $retired) { if (Test-Path -LiteralPath $leftover) { Assert-DeploySkillsPlainTree $leftover; Remove-Item -LiteralPath $leftover -Recurse -Force } }
    if ($step.Action -ne 'prune') { Copy-Item -LiteralPath $step.Source -Destination $staging -Recurse }
    if (Test-Path -LiteralPath $step.Target) { Rename-Item -LiteralPath $step.Target -NewName (Split-Path -Leaf $retired) }
    if ($step.Action -ne 'prune') { Rename-Item -LiteralPath $staging -NewName $step.Name }
    if (Test-Path -LiteralPath $retired) { Remove-Item -LiteralPath $retired -Recurse -Force }
    Write-Host "$($step.Action) $($step.Platform)/$($step.Name)"
}

# Every previously deployed, no-longer-selected directory was pruned above, so the deployed
# set is now exactly the selection. A failed Apply never reaches this line and keeps the old state.
New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
$deployed = [ordered]@{ Environment = $Environment }
foreach ($platform in $platforms) { $deployed[$platform] = @($selection[$platform] | Where-Object { $_ } | Sort-Object -Unique) }
$deployed | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
Write-Host "Applied environment '$Environment'. State: $statePath"
if (Test-Path -LiteralPath $backupRoot) { Write-Host "Backups: $backupRoot" }
