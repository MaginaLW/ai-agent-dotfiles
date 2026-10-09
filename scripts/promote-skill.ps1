#requires -Version 7.0
<#
.SYNOPSIS
    Promotes one reviewed skill directory into skills-source/<TargetType>/<name>.

.DESCRIPTION
    -DryRun (the default) builds a normalized candidate under
    tmp/skill-candidates/<guid> and prints what would be written. -Apply rebuilds the
    candidate, copies it create-new into skills-source/, and runs build-skills.ps1 and
    scan-secrets.ps1. Promote never replaces an existing skill (exit 3); use
    normalize-skill.ps1 to update one. Git is the recovery path.

    Exit codes: 0 success, 1 error or failed check, 2 candidate rejected, 3 retained.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [string] $InputSkillPath,
    [Parameter(Mandatory)] [ValidateSet('shared', 'claude-only', 'codex-only', 'reasonix-only')] [string] $TargetType,
    [switch] $Apply,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'skill-candidate-common.ps1')

try {
    if ($DryRun -and $Apply) { throw 'Specify only one of -DryRun or -Apply.' }
    $RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
    $InputSkillPath = (Resolve-Path -LiteralPath $InputSkillPath).Path
    Write-Host "Mode: $(if ($Apply) { 'apply' } else { 'dry-run' })"

    $name = Get-SkillName -SkillPath $InputSkillPath
    foreach ($type in @('shared', 'claude-only', 'codex-only', 'reasonix-only')) {
        if (Test-Path -LiteralPath (Join-Path $RepoRoot "skills-source/$type/$name")) {
            Write-Host "retained: skills-source/$type/$name already exists; promote never replaces a skill. Use normalize-skill.ps1 to update it."
            exit 3
        }
    }

    $workspace = New-SkillCandidateWorkspace -RepoRoot $RepoRoot
    $set = New-SkillCandidateSet -RepoRoot $RepoRoot -Workspace $workspace -Proposals @(
        [pscustomobject]@{ InputSkillPath = $InputSkillPath; TargetType = $TargetType }
    )
    if ([string]$set.Status -cne 'candidate') {
        Write-Host "rejected: $($set.Reason)"
        exit 2
    }
    Write-SkillCandidatePlan -RepoRoot $RepoRoot -Results @($set.Results)
    if (-not $Apply) {
        Write-Host 'Dry run only: nothing was written to skills-source/. Rerun with -Apply to promote.'
        exit 0
    }

    $null = Install-SkillCandidate -RepoRoot $RepoRoot -Result @($set.Results)[0]
    $checks = Invoke-SkillCandidateChecks -RepoRoot $RepoRoot
    if ($checks.Build -ne 'PASS' -or $checks.Scan -ne 'PASS') {
        Write-Host 'Checks failed. Review the change with git status / git diff and revert it with Git if needed.'
        exit 1
    }
    Write-Host 'Promoted. Review with git status / git diff before committing.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("promote-skill: $($_.Exception.Message)")
    exit 1
}
