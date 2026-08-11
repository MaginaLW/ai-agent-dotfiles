#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch] $InstallPreCommit,
    [switch] $SkipInitialPlan,
    [switch] $SkipInitialSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($SkipInitialSync) { Write-Warning '-SkipInitialSync is deprecated; use -SkipInitialPlan.'; $SkipInitialPlan = $true }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'approved-runner-common.ps1')

function Install-InertHooks {
    param([switch] $IncludePreCommit)
    $hooks = ((& git -C $RepoRoot rev-parse --path-format=absolute --git-path hooks 2>$null) | Select-Object -First 1).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Git hooks directory.' }
    [System.IO.Directory]::CreateDirectory($hooks) | Out-Null
    $names = @('post-merge','post-checkout','post-rewrite')
    if ($IncludePreCommit) { $names += 'pre-commit' }
    foreach ($name in $names) {
        $path = Join-Path $hooks $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { continue }
        $body = "#!/bin/sh`necho 'runner-review-required' >&2`nexit 72`n"
        [System.IO.File]::WriteAllText($path, $body, [System.Text.UTF8Encoding]::new($false))
    }
}

function Exit-DependencyRequired {
    param([string] $Token, [string] $Command, [int] $Code)
    [Console]::Error.WriteLine($Token)
    [Console]::Out.WriteLine($Command)
    exit $Code
}

$context = Get-RunnerStorageContext -RepoRoot $RepoRoot
if (-not (Test-Path -LiteralPath $context.ApprovedStatePath -PathType Leaf)) { Install-InertHooks -IncludePreCommit:$InstallPreCommit }

$validatorInstaller = Join-Path $RepoRoot 'scripts/install-schema-validator.ps1'
try { Assert-PinnedToolInstalled -LockPath (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json') | Out-Null }
catch { Exit-DependencyRequired -Token 'validator-install-required' -Command "pwsh -NoProfile -File `"$validatorInstaller`"" -Code 70 }
$scannerInstaller = Join-Path $RepoRoot 'scripts/install-gitleaks.ps1'
try { Assert-PinnedToolInstalled -LockPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json') | Out-Null }
catch { Exit-DependencyRequired -Token 'scanner-install-required' -Command "pwsh -NoProfile -File `"$scannerInstaller`"" -Code 71 }

if (-not (Test-Path -LiteralPath $context.ApprovedStatePath -PathType Leaf)) {
    $candidate = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-runner-review-$([Guid]::NewGuid().ToString('N'))"
    try { $snapshot = Get-RunnerPolicySnapshot -RepoRoot $RepoRoot -DestinationRoot $candidate -RequireCleanData }
    catch {
        [Console]::Error.WriteLine('working-tree-review-required')
        exit 74
    }
    finally { if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force } }
    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
    $event = [ordered]@{
        SchemaVersion=1; ArtifactKind='pending-sync-event'; EventKind='diagnostic'; WorktreeNamespace=$context.WorktreeId; Trigger='bootstrap'
        ApprovedToolchainHash=$snapshot.ToolchainPolicyHash; CurrentToolchainHash=$snapshot.ToolchainPolicyHash; Commit=$snapshot.CurrentCommit
        ContextHash=(Get-SemanticJsonHash -InputObject ([ordered]@{ State='runner-review-required'; Commit=$snapshot.CurrentCommit }))
        PreviewStatus='diagnostic-only'; RedactedContext='runner approval required'; ContentHashes=@(); ExternalDryRunCommand='not-available-until-runner-approval'
    }
    Write-DeduplicatedPendingEvent -StorageContext $context -Document $event | Out-Null
    $setup = Join-Path $RepoRoot 'scripts/setup.ps1'
    $command = "pwsh -NoProfile -File `"$setup`" -RepoRoot `"$RepoRoot`" -ApproveRunner -InstallAutoSync"
    if ($InstallPreCommit) { $command += ' -InstallPreCommit' }
    [Console]::Error.WriteLine('runner-review-required')
    [Console]::Out.WriteLine($command)
    exit 72
}

if ($SkipInitialPlan) { Write-Host 'Initial preview skipped by explicit -SkipInitialPlan.'; exit 0 }
if (-not (Test-Path -LiteralPath $context.ApprovedHookEntryPath -PathType Leaf)) { [Console]::Error.WriteLine('runner-review-required'); exit 72 }
& pwsh -NoProfile -ExecutionPolicy Bypass -File $context.ApprovedHookEntryPath -RepoRoot $RepoRoot -Trigger manual -Force
exit $LASTEXITCODE
