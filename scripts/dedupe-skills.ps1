#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'skills-common.ps1')

$RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
$analysisPath = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-reports/skills-analysis.json'
if (-not (Test-Path -LiteralPath $analysisPath)) {
    & (Join-Path $PSScriptRoot 'analyze-skills.ps1') -RepoRoot $RepoRoot
}
$analysis = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json
$reportPath = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-reports/dedupe-report.md'

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Skills Dedupe Report')
$lines.Add('')
$lines.Add("Exact duplicate groups: $(@($analysis.exact_duplicate_groups).Count)")
$lines.Add("Same SKILL.md groups: $(@($analysis.same_skill_md_groups).Count)")
$lines.Add("Same-name groups: $(@($analysis.same_name_duplicate_groups).Count)")
$lines.Add('')
foreach ($group in @($analysis.same_name_duplicate_groups)) {
    $lines.Add("## $($group.name)")
    foreach ($skill in @($group.skills)) {
        $lines.Add("- $skill")
    }
    $lines.Add('')
}
Write-Utf8NoBomFile -Path $reportPath -Content (($lines -join "`n") + "`n")
Write-Host "Dedupe report: $reportPath"
