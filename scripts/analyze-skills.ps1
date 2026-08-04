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
        [Parameter(Mandatory)] [string] $Collection,
        [string] $PreferredPlatform = ''
    )

    foreach ($skill in @(Get-SkillDirectories -RootPath $RootPath -ExcludeNames @('.system'))) {
        $Records.Add((Get-SkillRecord -RepoRoot $RepoRoot -SkillPath $skill.FullName -SourceTool $SourceTool -MachineId $MachineId -Collection $Collection -PreferredPlatform $PreferredPlatform))
    }
}

$records = [System.Collections.Generic.List[object]]::new()
$inboxRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-inbox'
if (Test-Path -LiteralPath $inboxRoot) {
    foreach ($machine in @(Get-ChildItem -LiteralPath $inboxRoot -Directory -Force | Sort-Object Name)) {
        Add-RecordsFromRoot -Records $records -RootPath (Join-Path $machine.FullName 'claude') -SourceTool 'claude' -MachineId $machine.Name -Collection 'inbox' -PreferredPlatform 'claude-only'
        Add-RecordsFromRoot -Records $records -RootPath (Join-Path $machine.FullName 'codex') -SourceTool 'codex' -MachineId $machine.Name -Collection 'inbox' -PreferredPlatform 'codex-only'
        Add-RecordsFromRoot -Records $records -RootPath (Join-Path $machine.FullName 'opencode') -SourceTool 'opencode' -MachineId $machine.Name -Collection 'inbox' -PreferredPlatform 'opencode-only'
    }
}

$sourceDefinitions = @(
    [pscustomobject] @{ Root = 'skills-source/shared'; Tool = 'shared'; Preferred = '' },
    [pscustomobject] @{ Root = 'skills-source/claude-only'; Tool = 'claude'; Preferred = 'claude-only' },
    [pscustomobject] @{ Root = 'skills-source/codex-only'; Tool = 'codex'; Preferred = 'codex-only' },
    [pscustomobject] @{ Root = 'skills-source/opencode-only'; Tool = 'opencode'; Preferred = 'opencode-only' }
)
foreach ($source in $sourceDefinitions) {
    Add-RecordsFromRoot -Records $records -RootPath (Join-RepoPath -RepoRoot $RepoRoot -RelativePath $source.Root) -SourceTool $source.Tool -MachineId 'source' -Collection 'skills-source' -PreferredPlatform $source.Preferred
}

$exactGroups = @($records | Where-Object { $_.sha256_tree_hash } | Group-Object sha256_tree_hash | Where-Object Count -gt 1 | ForEach-Object {
    [pscustomobject] [ordered] @{
        hash = $_.Name
        duplicate_count = $_.Count - 1
        skills = @($_.Group | ForEach-Object { ConvertTo-SafeSkillRecord -Record $_ })
    }
})
$sameMdGroups = @($records | Where-Object { $_.sha256_of_skill_md } | Group-Object sha256_of_skill_md | Where-Object Count -gt 1 | ForEach-Object {
    [pscustomobject] [ordered] @{
        hash = $_.Name
        skills = @($_.Group | ForEach-Object { ConvertTo-SafeSkillRecord -Record $_ })
    }
})
$sameNameGroups = @($records | Group-Object normalized_name | Where-Object Count -gt 1 | ForEach-Object {
    [pscustomobject] [ordered] @{
        name = $_.Name
        fingerprints = @($_.Group | Group-Object sha256_tree_hash | ForEach-Object {
            [pscustomobject] @{ hash = $_.Name; count = $_.Count }
        })
        skills = @($_.Group | ForEach-Object { ConvertTo-SafeSkillRecord -Record $_ })
    }
})
$riskSkills = @($records | Where-Object {
    $_.scan_status -ne 'passed' -or $_.classification -eq 'quarantine'
})
$exactDuplicateCount = 0
if ($exactGroups.Count -gt 0) {
    $exactMeasure = $exactGroups | Measure-Object -Property duplicate_count -Sum
    if ($null -ne $exactMeasure.Sum) { $exactDuplicateCount = [int]$exactMeasure.Sum }
}

$safeRecords = @($records | ForEach-Object { ConvertTo-SafeSkillRecord -Record $_ })
$analysis = [pscustomobject] [ordered] @{
    generated_at = (Get-Date).ToString('o')
    total_skill_count = $records.Count
    claude_source_skill_count = @($records | Where-Object source_tool -eq 'claude').Count
    codex_source_skill_count = @($records | Where-Object source_tool -eq 'codex').Count
    opencode_source_skill_count = @($records | Where-Object source_tool -eq 'opencode').Count
    current_skills_source_count = @($records | Where-Object collection -eq 'skills-source').Count
    exact_duplicate_count = $exactDuplicateCount
    exact_duplicate_group_count = @($exactGroups).Count
    records = $safeRecords
    exact_duplicate_groups = @($exactGroups)
    same_skill_md_groups = @($sameMdGroups)
    same_name_duplicate_groups = @($sameNameGroups)
    similar_purpose_groups = @($sameNameGroups)
    suspected_shared_skills = @($records | Where-Object classification -eq 'shared' | ForEach-Object normalized_name | Sort-Object -Unique)
    suspected_claude_only_skills = @($records | Where-Object classification -eq 'claude-only' | ForEach-Object normalized_name | Sort-Object -Unique)
    suspected_codex_only_skills = @($records | Where-Object classification -eq 'codex-only' | ForEach-Object normalized_name | Sort-Object -Unique)
    suspected_opencode_only_skills = @($records | Where-Object classification -eq 'opencode-only' | ForEach-Object normalized_name | Sort-Object -Unique)
    suspected_risk_skills = @($riskSkills | ForEach-Object normalized_name | Sort-Object -Unique)
    quality_score_ranking = @($records | Sort-Object @{ Expression = 'quality_score'; Descending = $true }, @{ Expression = 'normalized_name'; Descending = $false } | ForEach-Object {
        [pscustomobject] @{ normalized_name = $_.normalized_name; collection = $_.collection; source_tool = $_.source_tool; machine_id = $_.machine_id; quality_score = $_.quality_score }
    })
    recommended_merge_plan = @($records | Where-Object collection -eq 'inbox' | ForEach-Object {
        [pscustomobject] [ordered] @{
            normalized_name = $_.normalized_name
            source_tool = $_.source_tool
            machine_id = $_.machine_id
            classification = $_.classification
            scan_status = $_.scan_status
            sha256_tree_hash = $_.sha256_tree_hash
            recommendation = 'review-by-fingerprint'
        }
    })
}

$jsonPath = Join-Path $reportsRoot 'skills-analysis.json'
$mdPath = Join-Path $reportsRoot 'skills-analysis.md'
Write-Utf8NoBomFile -Path $jsonPath -Content (($analysis | ConvertTo-Json -Depth 40) + "`n")

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Skills Analysis')
$lines.Add('')
$lines.Add("Total skills: $($analysis.total_skill_count)")
$lines.Add("Claude source skills: $($analysis.claude_source_skill_count)")
$lines.Add("Codex source skills: $($analysis.codex_source_skill_count)")
$lines.Add("OpenCode source skills: $($analysis.opencode_source_skill_count)")
$lines.Add("Current skills-source skills: $($analysis.current_skills_source_count)")
$lines.Add("Exact duplicate groups: $($analysis.exact_duplicate_group_count) (duplicate copies: $($analysis.exact_duplicate_count))")
$lines.Add("Same-name groups: $(@($analysis.same_name_duplicate_groups).Count)")
$lines.Add('')
$lines.Add('## Recommended Merge Review')
$lines.Add('')
$lines.Add('| Skill | Tool | Machine | Classification | Scan | Tree hash |')
$lines.Add('| --- | --- | --- | --- | --- | --- |')
foreach ($item in $analysis.recommended_merge_plan) {
    $lines.Add("| $($item.normalized_name) | $($item.source_tool) | $($item.machine_id) | $($item.classification) | $($item.scan_status) | $($item.sha256_tree_hash) |")
}
$lines.Add('')
$lines.Add('## Risk Skills')
$lines.Add('')
if (@($analysis.suspected_risk_skills).Count -eq 0) {
    $lines.Add('None.')
}
else {
    foreach ($skill in $analysis.suspected_risk_skills) { $lines.Add("- $skill") }
}
Write-Utf8NoBomFile -Path $mdPath -Content (($lines -join "`n") + "`n")

Write-Host "Analysis records: $($records.Count)"
Write-Host "Analysis JSON: $jsonPath"
Write-Host "Analysis report: $mdPath"
