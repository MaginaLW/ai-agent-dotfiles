#requires -Version 7.0
<#
.SYNOPSIS
    Gated activation of one harness environment: deploy its staged skills into
    the live home via sync.ps1. Safe by default (dry-run); only mutates with
    -Apply.

.DESCRIPTION
    Orchestrates the Phase 2 activate flow from the harness environments design
    (docs/superpowers/specs/2026-07-10-harness-env-design.md §4.2). The gate
    chain runs in order and any failure aborts with that step's exit code,
    without writing the state file:

        1. resolve + validate the env definition
        2. build-skills.ps1        (unless -SkipBuild)
        3. scan-secrets.ps1        (unless -SkipSecretScan)
        4. build-harness-env.ps1   (staging is always rebuilt, never stale)
        5. activation deployment: NOT WIRED. The legacy content-aware deploy
           route was removed from sync.ps1 by Task 5 Step 1; deployment
           rebuilds on the receipt-backed host with the Phase 3
           env-activation work. -Apply fails closed and -DryRun previews
           gates 1-4 only.

    This script itself never copies or deletes a live file. Home-only
    files, credentials, sessions, and caches never change on activation.

    Phase 2 scope is skills + state file. Home-level config deployment
    (config-pull.ps1) is deliberately not part of activation yet; see the
    design doc's implementation note.

.PARAMETER Name
    Env name (bare identifier, matches harness-source/envs/<Name>.psd1).

.PARAMETER Apply
    Actually deploy. Without it the script is a pure dry-run.

.PARAMETER DryRun
    Explicitly select dry-run mode. Equivalent to omitting -Apply; cannot be
    combined with -Apply.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory for live paths. Defaults to $env:USERPROFILE. Must not be
    the repository root or live inside it.

.PARAMETER BackupRoot
    Passed to sync.ps1 for its mandatory pre-change backup on -Apply.

.PARAMETER SkipBuild
    Skip running scripts/build-skills.ps1 first (use existing generated output).

.PARAMETER SkipSecretScan
    Skip running scripts/scan-secrets.ps1. Not recommended; default is to scan.

.PARAMETER JsonPath
    Optional machine-readable activation summary path. The summary contains
    hashes, names, mode, and backup reference only; it never contains file
    contents or machine-private live state.

.PARAMETER TaskOverlayPath
    Optional task skill overlay path. Defaults to
    .agent-harness/task-skills.psd1 under the repository.

.OUTPUTS
    Streams the gate-chain and sync output. Exit 0 on success (dry-run or
    apply), non-zero on any gate failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name,
    [switch] $Apply,
    [switch] $DryRun,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [switch] $SkipBuild,
    [switch] $SkipSecretScan,
    [string] $JsonPath,
    [string] $TaskOverlayPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Apply -and $DryRun) {
    Write-Error 'Specify -DryRun or -Apply, not both.' -ErrorAction Continue
    exit 1
}

. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')
if ($Apply) {
    Assert-LiveSafetyMutationAllowed -Operation 'environment-activate' -Paths @(
        $RepoRoot, $HomeRoot, $BackupRoot, $JsonPath, $TaskOverlayPath
    )
}
. (Join-Path $PSScriptRoot 'harness-env-common.ps1')

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$definitionPath = Join-Path (Get-HarnessEnvRoot -RepoRoot $repo) "$Name.psd1"
if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
    Write-Error "Unknown env '$Name': expected definition at $definitionPath" -ErrorAction Continue
    exit 1
}
$definition = Read-HarnessEnvDefinition -Path $definitionPath
$taskOverlay = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $repo -BaseEnvName $Name -Path $TaskOverlayPath
$effectiveDefinition = Merge-HarnessTaskSkillOverlay -Definition $definition -Overlay $taskOverlay
$null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $effectiveDefinition
$taskOverlayPathFull = $taskOverlay.Path

$homeFull = [System.IO.Path]::GetFullPath($HomeRoot)
$repoFull = [System.IO.Path]::GetFullPath($repo)
$comparison = [System.StringComparison]::OrdinalIgnoreCase
$repoPrefix = $repoFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if ($homeFull.Equals($repoFull, $comparison) -or $homeFull.StartsWith($repoPrefix, $comparison)) {
    Write-Error "HomeRoot must not be the repository or live inside it: $homeFull" -ErrorAction Continue
    exit 1
}

$modeLabel = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
Write-Host "Harness env activate ($modeLabel): $Name"
Write-Host "  Repo : $repoFull"
Write-Host "  Home : $homeFull"

function Write-ActivationSummary {
    param(
        [Parameter(Mandatory)] [string] $Result,
        [AllowNull()] [string] $BackupReference,
        [AllowNull()] [object] $LockResult
    )

    if ([string]::IsNullOrWhiteSpace($JsonPath)) { return }
    $parent = Split-Path -Parent $JsonPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [string[]] $lockReasons = @()
    if ($null -ne $LockResult) {
        $lockReasons = [string[]] @($LockResult.Reasons)
    }
    $document = [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Name = $Name
        Mode = if ($Apply) { 'apply' } else { 'dry-run' }
        Result = $Result
        LockValidity = if ($null -eq $LockResult) { 'not-checked' } elseif ($LockResult.Valid) { 'valid' } else { 'invalid' }
        LockHash = if ($null -eq $LockResult) { $null } else { $LockResult.LockHash }
        TaskOverlayHash = if ($null -eq $LockResult) { $null } else { $LockResult.Lock.TaskOverlayHash }
        LockReasons = $lockReasons
        BackupReference = $BackupReference
        StateWritten = ($Apply -and $Result -eq 'PASS')
    }
    [System.IO.File]::WriteAllText($JsonPath, (ConvertTo-Json -InputObject $document -Depth 15) + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Get-LatestBackupReference {
    param([Parameter(Mandatory)] [string] $Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    $candidate = Get-ChildItem -LiteralPath $Root -Directory -Filter 'sync-backup-*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'backup-manifest.json') -PathType Leaf } |
        Sort-Object LastWriteTimeUtc, Name -Descending |
        Select-Object -First 1
    if ($null -eq $candidate) { return $null }
    return $candidate.Name
}

function Get-PreviousStateSummary {
    param([AllowNull()] [object] $PreviousState)

    if ($null -eq $PreviousState) { return [ordered]@{ Present = $false } }
    return [ordered]@{
        Present = $true
        Name = if ($PreviousState.PSObject.Properties.Name -contains 'Name') { [string] $PreviousState.Name } else { $null }
        DefinitionHash = if ($PreviousState.PSObject.Properties.Name -contains 'DefinitionHash') { [string] $PreviousState.DefinitionHash } else { $null }
        LockHash = if ($PreviousState.PSObject.Properties.Name -contains 'LockHash') { [string] $PreviousState.LockHash } else { $null }
        RepositoryCommit = if ($PreviousState.PSObject.Properties.Name -contains 'RepositoryCommit') { [string] $PreviousState.RepositoryCommit } else { $null }
        BackupReference = if ($PreviousState.PSObject.Properties.Name -contains 'BackupReference') { [string] $PreviousState.BackupReference } else { $null }
    }
}

$previousState = $null
try { $previousState = Read-HarnessEnvState -RepoRoot $repoFull } catch { throw }

function Invoke-GateScript {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [string[]] $Arguments = @()
    )
    $script = Join-Path $PSScriptRoot $ScriptName
    & pwsh -NoProfile -File $script @Arguments | Out-Host
    return $LASTEXITCODE
}

if (-not $SkipBuild) {
    Write-Host ''
    Write-Host 'Gate 1/4: build-skills'
    $code = Invoke-GateScript -ScriptName 'build-skills.ps1' -Arguments @('-RepoRoot', $repoFull)
    if ($code -ne 0) {
        Write-Error "build-skills.ps1 failed (exit $code). Activation aborted." -ErrorAction Continue
        exit $code
    }
}
else {
    Write-Host 'Gate 1/4: build-skills skipped (-SkipBuild)'
}

if (-not $SkipSecretScan) {
    Write-Host ''
    Write-Host 'Gate 2/4: secret scan'
    $code = Invoke-GateScript -ScriptName 'scan-secrets.ps1' -Arguments @('-RepoRoot', $repoFull)
    if ($code -ne 0) {
        Write-Error "scan-secrets.ps1 failed (exit $code). Activation aborted." -ErrorAction Continue
        exit $code
    }
}
else {
    Write-Host 'Gate 2/4: secret scan skipped (-SkipSecretScan)'
}

Write-Host ''
Write-Host 'Gate 3/4: rebuild env staging'
$code = Invoke-GateScript -ScriptName 'build-harness-env.ps1' -Arguments @('-Name', $Name, '-RepoRoot', $repoFull, '-TaskOverlayPath', $taskOverlayPathFull)
if ($code -ne 0) {
    Write-Error "build-harness-env.ps1 failed (exit $code). Activation aborted." -ErrorAction Continue
    exit $code
}
$staging = Get-HarnessEnvStagingRoot -RepoRoot $repoFull -Name $Name

$lockResult = Test-HarnessEnvLock -RepoRoot $repoFull -DefinitionPath $definitionPath -StagingPath $staging -TaskOverlayPath $taskOverlayPathFull
if (-not $lockResult.Valid) {
    Write-ActivationSummary -Result 'FAIL' -BackupReference $null -LockResult $lockResult
    Write-Error ("Environment lock is not valid; rebuild before activation: {0}" -f (@($lockResult.Reasons) -join '; ')) -ErrorAction Continue
    exit 1
}
Write-Host "Environment lock: valid ($($lockResult.LockHash))"

Write-Host ''
Write-Host 'Gate 4/4: activation deployment'
# The legacy content-aware deploy route was removed from sync.ps1 by Task 5
# Step 1. Activation deployment rebuilds on the receipt-backed host with the
# Phase 3 env-activation work; until then -Apply has no deployment mechanism
# and -DryRun has no deployment preview to show.
Write-Host 'Deployment preview and apply are not wired; the legacy content-aware'
Write-Host 'deploy route was removed by Task 5 (Phase 3 rebuilds activation on the'
Write-Host 'receipt-backed host).'
if ($Apply) {
    Write-ActivationSummary -Result 'FAIL' -BackupReference $null -LockResult $lockResult
    Write-Error 'activation-deploy-not-wired: Activation -Apply has no deployment mechanism; the legacy content-aware deploy route was removed by Task 5 and deployment rebuilds on the receipt-backed host in Phase 3. No state file was written.' -ErrorAction Continue
    exit 1
}

$statePath = Get-HarnessEnvStatePath -RepoRoot $repoFull
Write-Host ''
Write-Host "State file would be written: $statePath"
Write-Host "DRY-RUN complete. Re-run with -Apply to activate '$Name'."
Write-ActivationSummary -Result 'DRY-RUN' -BackupReference $null -LockResult $lockResult
exit 0
