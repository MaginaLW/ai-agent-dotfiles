#requires -Version 7.0
# One-time setup for a fresh clone: install and verify the pinned gitleaks,
# build the generated skills, then print the deploy dry-run to review.
# It never changes a live skills root.
[CmdletBinding()]
param([string] $RepoRoot = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'This script requires PowerShell 7 or newer. Run it with pwsh.' }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

foreach ($step in @(
    @{ Name = 'Install pinned gitleaks'; Script = 'scripts/install-gitleaks.ps1'; Arguments = @() },
    @{ Name = 'Verify pinned gitleaks'; Script = 'scripts/install-gitleaks.ps1'; Arguments = @('-VerifyOnly') },
    @{ Name = 'Build generated skills'; Script = 'scripts/build-skills.ps1'; Arguments = @() }
)) {
    Write-Host "== $($step.Name)"
    $arguments = [string[]] $step.Arguments
    & pwsh -NoProfile -File (Join-Path $RepoRoot $step.Script) @arguments
    if ($LASTEXITCODE -ne 0) { throw "$($step.Name) failed with exit code $LASTEXITCODE." }
}

Write-Host ''
Write-Host 'Bootstrap complete. Review the skill deployment dry run next:'
Write-Host '  pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work'
