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
        5. sync.ps1 -RepoRoot <staging> -HomeRoot <home>
           with -SkipBuild -SkipSecretScan (steps 2-3 already ran); sync's
           own mandatory pre-change backup CANNOT be skipped
        6. on -Apply success only: write state/current-env.json

    This script itself never copies or deletes a live file: the ONLY write path
    into the home directories is the existing sync.ps1, with its manifest-scoped
    plan, unknown-dir preservation, and Codex .system protection. Home-only
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
    [switch] $SkipSecretScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-env-common.ps1')

if ($Apply -and $DryRun) {
    Write-Error 'Specify -DryRun or -Apply, not both.' -ErrorAction Continue
    exit 1
}

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$definitionPath = Join-Path (Get-HarnessEnvRoot -RepoRoot $repo) "$Name.psd1"
if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
    Write-Error "Unknown env '$Name': expected definition at $definitionPath" -ErrorAction Continue
    exit 1
}
$definition = Read-HarnessEnvDefinition -Path $definitionPath
$null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $definition

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
$code = Invoke-GateScript -ScriptName 'build-harness-env.ps1' -Arguments @('-Name', $Name, '-RepoRoot', $repoFull)
if ($code -ne 0) {
    Write-Error "build-harness-env.ps1 failed (exit $code). Activation aborted." -ErrorAction Continue
    exit $code
}
$staging = Get-HarnessEnvStagingRoot -RepoRoot $repoFull -Name $Name

Write-Host ''
Write-Host 'Gate 4/4: manifest-scoped deploy via sync.ps1 (mandatory backup on apply)'
$syncArguments = @(
    '-RepoRoot', $staging
    '-HomeRoot', $homeFull
    '-SkipBuild'
    '-SkipSecretScan'
)
$syncArguments += if ($Apply) { @('-Apply', '-BackupRoot', $BackupRoot) } else { @('-DryRun') }
$code = Invoke-GateScript -ScriptName 'sync.ps1' -Arguments $syncArguments
if ($code -ne 0) {
    Write-Error "sync.ps1 failed (exit $code). State file not written." -ErrorAction Continue
    exit $code
}

$statePath = Get-HarnessEnvStatePath -RepoRoot $repoFull
if (-not $Apply) {
    Write-Host ''
    Write-Host "State file would be written: $statePath"
    Write-Host "DRY-RUN complete. Re-run with -Apply to activate '$Name'."
    exit 0
}

$stateDir = Split-Path -Parent $statePath
if (-not (Test-Path -LiteralPath $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}
Write-HarnessJsonFile -InputObject ([ordered] @{
        SchemaVersion  = 1
        Name           = $Name
        DefinitionHash = Get-HarnessEnvDefinitionHash -Path $definitionPath
        ActivatedAtUtc = [DateTime]::UtcNow.ToString('o')
        HomeRoot       = $homeFull
    }) -Path $statePath

Write-Host ''
Write-Host "Activated environment: $Name"
Write-Host "State: $statePath"
exit 0
