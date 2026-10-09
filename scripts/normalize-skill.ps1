#requires -Version 7.0
<#
.SYNOPSIS
    Normalizes one skill directory into skills-source/<TargetType>/<name>, creating or
    updating it.

.DESCRIPTION
    -DryRun (the default) builds a normalized candidate (portable paths, canonical
    front matter) under tmp/skill-candidates/<guid> and prints what would be written.
    -Apply rebuilds the candidate and copies it into skills-source/. This is the update
    mode: an existing skill of the same type is first moved to
    tmp/skill-candidates/<guid>/backup/<type>/<name>. A name that already exists under
    another type is rejected. build-skills.ps1 and scan-secrets.ps1 run after the copy.
    Git is the recovery path.

    Exit codes: 0 success, 1 error or failed check, 2 candidate rejected.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [string] $InputSkillPath,
    [Parameter(Mandatory)] [ValidateSet('shared', 'claude-only', 'codex-only', 'reasonix-only')] [string] $TargetType,
    [switch] $DryRun,
    [switch] $Apply
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
        Write-Host 'Dry run only: nothing was written to skills-source/. Rerun with -Apply to write the candidate.'
        exit 0
    }

    $null = Install-SkillCandidate -RepoRoot $RepoRoot -Result @($set.Results)[0] -AllowReplace -BackupRoot (Join-Path $workspace 'backup')
    $checks = Invoke-SkillCandidateChecks -RepoRoot $RepoRoot
    if ($checks.Build -ne 'PASS' -or $checks.Scan -ne 'PASS') {
        Write-Host 'Checks failed. Review the change with git status / git diff and revert it with Git if needed.'
        exit 1
    }
    Write-Host 'Normalized. Review with git status / git diff before committing.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("normalize-skill: $($_.Exception.Message)")
    exit 1
}
