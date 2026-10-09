#requires -Version 7.0
<#
.SYNOPSIS
    Copies one reviewed skill directory into skills-source/<Type>/<Name>.

.DESCRIPTION
    Dry run by default: prints the target and the files that would be copied. -Apply copies the
    directory, then runs build-skills.ps1 and scan-secrets.ps1 and exits non-zero if either fails;
    the copied files stay in place for review with git status / git diff.

    The name must not exist under any skills-source type. -Replace allows replacing a skill of
    the same type only; the old copy is first moved to tmp/skill-backups/<stamp>/<Type>/<Name>.
    The source must contain SKILL.md and no symlink, junction or other reparse point.
    Live skills roots are never touched; deploy with deploy-skills.ps1.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [ValidateSet('shared', 'claude-only', 'codex-only', 'reasonix-only')] [string] $Type,
    [switch] $Replace,
    [switch] $Apply,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'skills-common.ps1')

try {
    if ($DryRun -and $Apply) { throw 'Specify only one of -DryRun or -Apply.' }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    if ($Name -ceq '.system' -or $Name -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$') {
        throw "Invalid skill name: '$Name'"
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Source is not a directory: $Path" }
    $source = (Resolve-Path -LiteralPath $Path).Path
    Assert-SkillTreeNoReparsePoint -Root $source
    if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)) { throw "Source has no SKILL.md: $source" }

    $target = Join-Path $RepoRoot "skills-source/$Type/$Name"
    if ((Test-SameOrDescendant -Path $source -Root $target) -or (Test-SameOrDescendant -Path $target -Root $source)) {
        throw 'Source and target overlap.'
    }
    foreach ($existingType in @('shared', 'claude-only', 'codex-only', 'reasonix-only')) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "skills-source/$existingType/$Name"))) { continue }
        if (-not $Replace) { throw "skills-source/$existingType/$Name already exists. Pass -Replace to replace a skill of the same type." }
        if ($existingType -cne $Type) { throw "skills-source/$existingType/$Name exists under another type; -Replace only replaces the same type." }
    }
    $replacing = Test-Path -LiteralPath $target

    $files = @(Get-ChildItem -LiteralPath $source -File -Recurse -Force |
        ForEach-Object { [System.IO.Path]::GetRelativePath($source, $_.FullName).Replace('\', '/') } | Sort-Object)
    Write-Host "Mode: $(if ($Apply) { 'apply' } else { 'dry-run' })"
    Write-Host "$(if ($replacing) { 'replace' } else { 'create' }) skills-source/$Type/$Name from $source"
    foreach ($file in $files) { Write-Host "  file: $file" }
    if (-not $Apply) {
        Write-Host 'Dry run only: nothing was written. Rerun with -Apply to copy the skill.'
        exit 0
    }

    $backup = $null
    if ($replacing) {
        $backup = Join-Path $RepoRoot ('tmp/skill-backups/{0}/{1}/{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $Type, $Name)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
        Move-Item -LiteralPath $target -Destination $backup
        Write-Host "Backed up the old copy to $backup"
    }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-SkillTree -SourceRoot $source -DestinationRoot $target
    }
    catch {
        if ($backup -and -not (Test-Path -LiteralPath $target)) { Move-Item -LiteralPath $backup -Destination $target }
        throw
    }
    Write-Host "Copied $($files.Count) file(s) to skills-source/$Type/$Name"

    $failed = @()
    foreach ($check in @('build-skills.ps1', 'scan-secrets.ps1')) {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot $check) -RepoRoot $RepoRoot
        $code = $LASTEXITCODE
        Write-Host "${check}: $(if ($code -eq 0) { 'PASS' } else { "FAIL (exit $code)" })"
        if ($code -ne 0) { $failed += $check }
    }
    if ($failed.Count -gt 0) {
        Write-Host 'Checks failed. The copied files stay in place; review them with git status / git diff.'
        exit 1
    }
    Write-Host 'Promoted. Review with git status / git diff before committing.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("promote-skill: $($_.Exception.Message)")
    exit 1
}
