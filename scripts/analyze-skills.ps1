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
$reportsRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-reports'
New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null

function Add-RecordsFromRoot {
    param(
        [Parameter(Mandatory)] [object] $Records,
        [Parameter(Mandatory)] [string] $RootPath,
        [Parameter(Mandatory)] [string] $SourceTool,
        [Parameter(Mandatory)] [string] $MachineId,
        [Parameter(Mandatory)] [string] $Collection
    )

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return
    }
    $skills = @(Get-ChildItem -LiteralPath $RootPath -Directory -Force | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md')
    })
    foreach ($skill in $skills) {
        $Records.Add((Get-SkillRecord -RepoRoot $RepoRoot -SkillPath $skill.FullName -SourceTool $SourceTool -MachineId $MachineId -Collection $Collection))
    }
}

$records = [System.Collections.Generic.List[object]]::new()

$inboxRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-inbox'
if (Test-Path -LiteralPath $inboxRoot) {
    foreach ($machine in @(Get-ChildItem -LiteralPath $inboxRoot -Directory -Force)) {
        Add-RecordsFromRoot -Records $records -RootPath (Join-Path $machine.FullName 'claude') -SourceTool 'claude' -MachineId $machine.Name -Collection 'inbox'
        Add-RecordsFromRoot -Records $records -RootPath (Join-Path $machine.FullName 'codex') -SourceTool 'codex' -MachineId $machine.Name -Collection 'inbox'
    }
}

Add-RecordsFromRoot -Records $records -RootPath (Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'skills-source/shared') -SourceTool 'shared' -MachineId 'source' -Collection 'skills-source'
Add-RecordsFromRoot -Records $records -RootPath (Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'skills-source/claude-only') -SourceTool 'claude-only' -MachineId 'source' -Collection 'skills-source'
Add-RecordsFromRoot -Records $records -RootPath (Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'skills-source/codex-only') -SourceTool 'codex-only' -MachineId 'source' -Collection 'skills-source'

$exactGroups = @($records | Where-Object { $_.sha256_tree_hash } | Group-Object sha256_tree_hash | Where-Object Count -gt 1 | ForEach-Object {
    [pscustomobject] @{ hash = $_.Name; skills = @($_.Group | ForEach-Object repo_relative_path) }
})
$sameMdGroups = @($records | Where-Object { $_.sha256_of_skill_md } | Group-Object sha256_of_skill_md | Where-Object Count -gt 1 | ForEach-Object {
    [pscustomobject] @{ hash = $_.Name; skills = @($_.Group | ForEach-Object repo_relative_path) }
})
$sameNameGroups = @($records | Group-Object normalized_name | Where-Object Count -gt 1 | ForEach-Object {
    [pscustomobject] @{ name = $_.Name; skills = @($_.Group | ForEach-Object repo_relative_path) }
})

$similarPurposeGroups = @($records | Group-Object normalized_name | Where-Object Count -gt 1 | ForEach-Object {
    [pscustomobject] @{ purpose = $_.Name; skills = @($_.Group | ForEach-Object repo_relative_path) }
})

$riskSkills = @($records | Where-Object {
    @($_.possible_secret_findings).Count -gt 0 -or
    @($_.possible_binary_findings).Count -gt 0 -or
    $_.classification -eq 'quarantine'
})

$analysis = [pscustomobject] @{
    generated_at = (Get-Date).ToString('o')
    total_skill_count = $records.Count
    claude_source_skill_count = @($records | Where-Object source_tool -eq 'claude').Count
    codex_source_skill_count = @($records | Where-Object source_tool -eq 'codex').Count
    current_skills_source_count = @($records | Where-Object collection -eq 'skills-source').Count
    records = @($records)
    exact_duplicate_groups = @($exactGroups)
    same_skill_md_groups = @($sameMdGroups)
    same_name_duplicate_groups = @($sameNameGroups)
    similar_purpose_groups = @($similarPurposeGroups)
    suspected_shared_skills = @($records | Where-Object classification -eq 'shared' | ForEach-Object normalized_name | Sort-Object -Unique)
    suspected_claude_only_skills = @($records | Where-Object classification -eq 'claude-only' | ForEach-Object normalized_name | Sort-Object -Unique)
    suspected_codex_only_skills = @($records | Where-Object classification -eq 'codex-only' | ForEach-Object normalized_name | Sort-Object -Unique)
    suspected_risk_skills = @($riskSkills | ForEach-Object normalized_name | Sort-Object -Unique)
    quality_score_ranking = @($records | Sort-Object quality_score -Descending | Select-Object normalized_name, collection, source_tool, machine_id, quality_score)
    recommended_merge_plan = @($records | Where-Object collection -eq 'inbox' | Select-Object normalized_name, source_tool, machine_id, classification, quality_score)
}

$jsonPath = Join-Path $reportsRoot 'skills-analysis.json'
$mdPath = Join-Path $reportsRoot 'skills-analysis.md'
Write-Utf8NoBomFile -Path $jsonPath -Content (($analysis | ConvertTo-Json -Depth 30) + "`n")

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Skills Analysis')
$lines.Add('')
$lines.Add("Total skills: $($analysis.total_skill_count)")
$lines.Add("Claude source skills: $($analysis.claude_source_skill_count)")
$lines.Add("Codex source skills: $($analysis.codex_source_skill_count)")
$lines.Add("Current skills-source skills: $($analysis.current_skills_source_count)")
$lines.Add('')
$lines.Add("Exact duplicate groups: $(@($analysis.exact_duplicate_groups).Count)")
$lines.Add("Same-name duplicate groups: $(@($analysis.same_name_duplicate_groups).Count)")
$lines.Add("Similar-purpose groups: $(@($analysis.similar_purpose_groups).Count)")
$lines.Add('')
$lines.Add('## Recommended Merge Plan')
$lines.Add('')
$lines.Add('| Skill | Source | Machine | Classification | Quality |')
$lines.Add('| --- | --- | --- | --- | ---: |')
foreach ($item in $analysis.recommended_merge_plan) {
    $lines.Add("| $($item.normalized_name) | $($item.source_tool) | $($item.machine_id) | $($item.classification) | $($item.quality_score) |")
}
$lines.Add('')
$lines.Add('## Risk Skills')
$lines.Add('')
if (@($analysis.suspected_risk_skills).Count -eq 0) {
    $lines.Add('None.')
}
else {
    foreach ($skill in $analysis.suspected_risk_skills) {
        $lines.Add("- $skill")
    }
}
Write-Utf8NoBomFile -Path $mdPath -Content (($lines -join "`n") + "`n")

Write-Host "Analysis records: $($records.Count)"
Write-Host "Analysis JSON: $jsonPath"
Write-Host "Analysis report: $mdPath"
