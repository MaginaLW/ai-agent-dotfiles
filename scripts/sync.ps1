#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('push', 'pull')]
    [string] $Mode,

    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot,

    [Alias('dry-run')]
    [switch] $DryRun,

    [switch] $Prune
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path $RepoRoot).Path

# TODO (real sync implementation — see README "Deployment Targets" and sync-plan-v2 §7.5):
#   - Deploy/prune MUST be scoped to entries in manifests/managed-skills.txt.
#   - DO NOT run a bare `robocopy /MIR` (or any whole-directory mirror) against
#     $HOME/.codex/skills: that deletes Codex's platform-managed `.system` directory
#     (marked by `.codex-system-skills.marker`, e.g. imagegen / openai-docs /
#     plugin-creator / skill-creator / skill-installer) and any other non-managed
#     skills installed by Codex itself.
#   - `.system` is NOT a repo-managed skill and MUST be preserved (exclude it from any
#     mirror/purge, or restore it from backup afterward). This is a formal rule, not a
#     temporary workaround. Phase 3 (2026-06-12, DESKTOP-3GMDAB7) hit this exact issue.
#   - Always back up the target before overwriting.

Write-Host "sync.ps1 placeholder loaded for RepoRoot: $RepoRoot"
Write-Host "Mode: $Mode; DryRun: $DryRun; Prune: $Prune; HomeRoot: $HomeRoot"
throw 'Real sync is intentionally disabled in phase 1/2. No files were copied to or from HOME.'
