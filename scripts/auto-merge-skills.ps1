#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(ParameterSetName = 'Apply')] [switch] $Apply,
    [Parameter(ParameterSetName = 'DryRun')] [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'skills-common.ps1')

$RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
if (-not $Apply) {
    $DryRun = $true
}

$reportsRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-reports'
$archiveRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-archive'
$quarantineRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-quarantine'
New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
if ($Apply) {
    New-Item -ItemType Directory -Force -Path $archiveRoot, $quarantineRoot | Out-Null
}

function Get-InboxRecords {
    $records = [System.Collections.Generic.List[object]]::new()
    $inboxRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-inbox'
    if (-not (Test-Path -LiteralPath $inboxRoot)) {
        return @()
    }
    foreach ($machine in @(Get-ChildItem -LiteralPath $inboxRoot -Directory -Force)) {
        foreach ($tool in @('claude', 'codex')) {
            $toolRoot = Join-Path $machine.FullName $tool
            if (-not (Test-Path -LiteralPath $toolRoot)) {
                continue
            }
            foreach ($skill in @(Get-ChildItem -LiteralPath $toolRoot -Directory -Force | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })) {
                $records.Add((Get-SkillRecord -RepoRoot $RepoRoot -SkillPath $skill.FullName -SourceTool $tool -MachineId $machine.Name -Collection 'inbox'))
            }
        }
    }
    return @($records)
}

function Get-ExistingSourcePath {
    param(
        [Parameter(Mandatory)] [string] $Name
    )

    foreach ($type in @('shared', 'claude-only', 'codex-only')) {
        $path = Join-RepoPath -RepoRoot $RepoRoot -RelativePath "skills-source/$type/$Name"
        if (Test-Path -LiteralPath (Join-Path $path 'SKILL.md')) {
            return [pscustomobject] @{ Type = $type; Path = $path }
        }
    }
    return $null
}

function Get-TargetType {
    param(
        [Parameter(Mandatory)] [object[]] $Records,
        [AllowNull()] [object] $Existing
    )

    if ($Existing) {
        return $Existing.Type
    }
    $classes = @($Records | ForEach-Object classification | Sort-Object -Unique)
    if ('quarantine' -in $classes) {
        return 'quarantine'
    }
    if ('claude-only' -in $classes -and 'codex-only' -in $classes) {
        return 'quarantine'
    }
    if ('codex-only' -in $classes) {
        return 'codex-only'
    }
    if ('claude-only' -in $classes) {
        return 'claude-only'
    }
    return 'shared'
}

function Copy-SupportingFiles {
    param(
        [Parameter(Mandatory)] [string] $SourceSkillPath,
        [Parameter(Mandatory)] [string] $TargetSkillPath,
        [Parameter(Mandatory)] [string] $MachineId
    )

    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $SourceSkillPath -File -Recurse -Force | Where-Object { $_.Name -ne 'SKILL.md' })) {
        $relative = [System.IO.Path]::GetRelativePath($SourceSkillPath, $file.FullName)
        $target = Join-Path $TargetSkillPath $relative
        Assert-PathUnderRoot -Root $RepoRoot -Path $target
        if (Test-Path -LiteralPath $target) {
            $sourceHash = Get-FileSha256 -Path $file.FullName
            $targetHash = Get-FileSha256 -Path $target
            if ($sourceHash -eq $targetHash) {
                continue
            }
            $directory = Split-Path -Parent $target
            $base = [System.IO.Path]::GetFileNameWithoutExtension($target)
            $extension = [System.IO.Path]::GetExtension($target)
            $target = Join-Path $directory "$base.$MachineId$extension"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $copied.Add((Get-RelativeDisplayPath -Root $RepoRoot -Path $target))
    }
    return @($copied)
}

function ConvertTo-PlainLog {
    param(
        [AllowNull()] [string] $Text
    )

    $value = (($Text ?? '') -replace "`r`n", "`n") -replace "`r", "`n"
    $value = [regex]::Replace($value, "`e\[[0-9;]*[A-Za-z]", '')
    return $value.Trim()
}

$inboxRecords = @(Get-InboxRecords)
$merged = [System.Collections.Generic.List[object]]::new()
$quarantined = [System.Collections.Generic.List[object]]::new()
$archived = [System.Collections.Generic.List[object]]::new()
$pathRewrites = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[object]]::new()

foreach ($group in @($inboxRecords | Group-Object normalized_name)) {
    $name = $group.Name
    $records = @($group.Group)
    $existing = Get-ExistingSourcePath -Name $name
    $targetType = Get-TargetType -Records $records -Existing $existing

    if ($targetType -eq 'quarantine') {
        foreach ($record in $records) {
            $reason = if (@($record.possible_secret_findings).Count -gt 0) { 'possible-secret' }
                elseif (@($record.possible_binary_findings).Count -gt 0) { 'binary-or-large-file' }
                else { 'platform-conflict' }
            $targetRelative = "imports/skills-quarantine/$reason/$($record.machine_id)/$($record.source_tool)/$name"
            if ($Apply) {
                Copy-SkillToArchive -RepoRoot $RepoRoot -SourcePath $record.source_path -ArchiveRelativePath $targetRelative | Out-Null
            }
            $quarantined.Add([pscustomobject] @{
                name = $name
                reason = $reason
                source = $record.repo_relative_path
                target = $targetRelative
            })
        }
        continue
    }

    $targetRelativePath = "skills-source/$targetType/$name"
    $targetPath = Join-RepoPath -RepoRoot $RepoRoot -RelativePath $targetRelativePath
    $canonical = if ($existing) {
        [pscustomobject] @{
            Path = $existing.Path
            Source = 'existing-skills-source'
            Quality = 100
        }
    }
    else {
        $best = @($records | Sort-Object quality_score -Descending | Select-Object -First 1)[0]
        [pscustomobject] @{
            Path = $best.source_path
            Source = $best.repo_relative_path
            Quality = $best.quality_score
        }
    }

    if ($DryRun) {
        $merged.Add([pscustomobject] @{
            name = $name
            target_type = $targetType
            target = $targetRelativePath
            canonical_source = $canonical.Source
            sources = @($records | ForEach-Object repo_relative_path)
            dry_run = $true
        })
        continue
    }

    $canonicalInputPath = $canonical.Path
    if ($existing) {
        $previousRelative = "imports/skills-archive/previous-source/$name"
        Copy-SkillToArchive -RepoRoot $RepoRoot -SourcePath $existing.Path -ArchiveRelativePath $previousRelative | Out-Null
        $canonicalInputPath = Join-RepoPath -RepoRoot $RepoRoot -RelativePath $previousRelative
        $archived.Add([pscustomobject] @{ name = $name; reason = 'previous-source'; target = $previousRelative })
    }

    $normalizeResult = Normalize-SkillDirectory -RepoRoot $RepoRoot -InputSkillPath $canonicalInputPath -OutputSkillPath $targetPath -TargetType $targetType
    if ($normalizeResult.Status -eq 'quarantine') {
        foreach ($record in $records) {
            $targetRelative = "imports/skills-quarantine/$($normalizeResult.Reason)/$($record.machine_id)/$($record.source_tool)/$name"
            Copy-SkillToArchive -RepoRoot $RepoRoot -SourcePath $record.source_path -ArchiveRelativePath $targetRelative | Out-Null
            $quarantined.Add([pscustomobject] @{
                name = $name
                reason = $normalizeResult.Reason
                source = $record.repo_relative_path
                target = $targetRelative
            })
        }
        continue
    }

    foreach ($rewrite in @($normalizeResult.Rewrites)) {
        $pathRewrites.Add([pscustomobject] @{ name = $name; file = $rewrite.File; rule = $rewrite.Rule; replacement = $rewrite.Replacement })
    }
    if (@($normalizeResult.Rewrites).Count -eq 0 -and @($records | Where-Object { @($_.possible_local_path_findings).Count -gt 0 }).Count -gt 0) {
        $targetSignals = Get-SkillSignals -RepoRoot $RepoRoot -SkillPath $targetPath
        if (@($targetSignals.LocalPathFindings).Count -eq 0) {
            foreach ($record in @($records | Where-Object { @($_.possible_local_path_findings).Count -gt 0 })) {
                foreach ($finding in @($record.possible_local_path_findings)) {
                    $pathRewrites.Add([pscustomobject] @{
                        name = $name
                        file = $finding.File
                        rule = "$($finding.Rule) normalized"
                        replacement = '$HOME'
                    })
                }
            }
        }
    }

    $supportingFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $records) {
        if ($record.source_path -ne $canonical.Path) {
            foreach ($copied in @(Copy-SupportingFiles -SourceSkillPath $record.source_path -TargetSkillPath $targetPath -MachineId $record.machine_id)) {
                $supportingFiles.Add($copied)
            }
        }
        $archiveRelative = "imports/skills-archive/merged/$($record.machine_id)/$($record.source_tool)/$name"
        Copy-SkillToArchive -RepoRoot $RepoRoot -SourcePath $record.source_path -ArchiveRelativePath $archiveRelative | Out-Null
        $archived.Add([pscustomobject] @{ name = $name; reason = 'merged-inbox-copy'; target = $archiveRelative })
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    $notes.Add("# Merge Notes")
    $notes.Add('')
    $notes.Add("Target type: $targetType")
    $notes.Add("Canonical source: $($canonical.Source)")
    $notes.Add('')
    $notes.Add('## Sources')
    foreach ($record in $records) {
        $notes.Add("- $($record.repo_relative_path)")
    }
    if ($supportingFiles.Count -gt 0) {
        $notes.Add('')
        $notes.Add('## Supporting Files Added')
        foreach ($file in $supportingFiles) {
            $notes.Add("- $file")
        }
    }
    if (@($normalizeResult.Rewrites).Count -gt 0) {
        $notes.Add('')
        $notes.Add('## Path Rewrites')
        foreach ($rewrite in @($normalizeResult.Rewrites)) {
            $notes.Add("- $($rewrite.File): $($rewrite.Rule) -> $($rewrite.Replacement)")
        }
    }
    Write-Utf8NoBomFile -Path (Join-Path $targetPath 'MERGE_NOTES.md') -Content (($notes -join "`n") + "`n")

    $merged.Add([pscustomobject] @{
        name = $name
        target_type = $targetType
        target = $targetRelativePath
        canonical_source = $canonical.Source
        sources = @($records | ForEach-Object repo_relative_path)
        supporting_files = @($supportingFiles)
        dry_run = $false
    })
}

$sourceStructure = @()
foreach ($type in @('shared', 'claude-only', 'codex-only')) {
    $root = Join-RepoPath -RepoRoot $RepoRoot -RelativePath "skills-source/$type"
    if (Test-Path -LiteralPath $root) {
        foreach ($skill in @(Get-ChildItem -LiteralPath $root -Directory -Force | Sort-Object Name)) {
            if (Test-Path -LiteralPath (Join-Path $skill.FullName 'SKILL.md')) {
                $sourceStructure += "$type/$($skill.Name)"
            }
        }
    }
}

$buildSkillsResult = 'not-run-in-dry-run'
$scanSecretsResult = 'not-run-in-dry-run'
if ($Apply) {
    try {
        $buildOutput = & (Join-Path $PSScriptRoot 'build-skills.ps1') -RepoRoot $RepoRoot *>&1 | Out-String
        $buildSkillsResult = ConvertTo-PlainLog -Text $buildOutput
    }
    catch {
        $buildSkillsResult = "failed: $($_.Exception.Message)"
        throw
    }

    try {
        $scanOutput = & (Join-Path $PSScriptRoot 'scan-secrets.ps1') -RepoRoot $RepoRoot *>&1 | Out-String
        $scanSecretsResult = ConvertTo-PlainLog -Text $scanOutput
    }
    catch {
        $scanSecretsResult = "failed: $($_.Exception.Message)"
        throw
    }
}

$report = [pscustomobject] @{
    generated_at = (Get-Date).ToString('o')
    mode = if ($Apply) { 'apply' } else { 'dry-run' }
    scanned_skill_count = $inboxRecords.Count
    merged_shared = @($merged | Where-Object target_type -eq 'shared' | ForEach-Object name)
    merged_claude_only = @($merged | Where-Object target_type -eq 'claude-only' | ForEach-Object name)
    merged_codex_only = @($merged | Where-Object target_type -eq 'codex-only' | ForEach-Object name)
    exact_duplicate_count = 0
    similar_purpose_groups = @($inboxRecords | Group-Object normalized_name | Where-Object Count -gt 1 | ForEach-Object { $_.Name })
    archived = @($archived)
    quarantined = @($quarantined)
    path_rewrites = @($pathRewrites)
    skipped = @($skipped)
    merged = @($merged)
    final_skills_source_structure = @($sourceStructure | Sort-Object)
    build_skills_result = $buildSkillsResult
    scan_secrets_result = $scanSecretsResult
}

$jsonPath = Join-Path $reportsRoot 'auto-merge-report.json'
$mdPath = Join-Path $reportsRoot 'auto-merge-report.md'
Write-Utf8NoBomFile -Path $jsonPath -Content (($report | ConvertTo-Json -Depth 30) + "`n")

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Auto-Merge Report')
$lines.Add('')
$lines.Add("Mode: $($report.mode)")
$lines.Add("Scanned skills: $($report.scanned_skill_count)")
$lines.Add('')
$lines.Add("Merged to shared: $(@($report.merged_shared).Count)")
foreach ($skill in @($report.merged_shared)) { $lines.Add("- $skill") }
$lines.Add('')
$lines.Add("Merged to claude-only: $(@($report.merged_claude_only).Count)")
foreach ($skill in @($report.merged_claude_only)) { $lines.Add("- $skill") }
$lines.Add('')
$lines.Add("Merged to codex-only: $(@($report.merged_codex_only).Count)")
foreach ($skill in @($report.merged_codex_only)) { $lines.Add("- $skill") }
$lines.Add('')
$lines.Add("Archived copies: $(@($report.archived).Count)")
foreach ($item in @($report.archived)) { $lines.Add("- $($item.name): $($item.reason) -> $($item.target)") }
$lines.Add('')
$lines.Add("Quarantined skills: $(@($report.quarantined).Count)")
if (@($report.quarantined).Count -eq 0) {
    $lines.Add('- none')
}
else {
    foreach ($item in @($report.quarantined)) { $lines.Add("- $($item.name): $($item.reason) -> $($item.target)") }
}
$lines.Add('')
$lines.Add("Path rewrites: $(@($report.path_rewrites).Count)")
foreach ($item in @($report.path_rewrites)) { $lines.Add("- $($item.name): $($item.file) $($item.rule) -> $($item.replacement)") }
$lines.Add('')
$lines.Add('## Final skills-source Structure')
foreach ($item in @($report.final_skills_source_structure)) { $lines.Add("- $item") }
$lines.Add('')
$lines.Add('## Build Result')
$lines.Add('')
$lines.Add('```text')
$lines.Add($report.build_skills_result)
$lines.Add('```')
$lines.Add('')
$lines.Add('## Scan Result')
$lines.Add('')
$lines.Add('```text')
$lines.Add($report.scan_secrets_result)
$lines.Add('```')
Write-Utf8NoBomFile -Path $mdPath -Content (($lines -join "`n") + "`n")

Write-Host "Auto-merge mode: $($report.mode)"
Write-Host "Scanned skills: $($report.scanned_skill_count)"
Write-Host "Merged shared: $(@($report.merged_shared).Count)"
Write-Host "Merged claude-only: $(@($report.merged_claude_only).Count)"
Write-Host "Merged codex-only: $(@($report.merged_codex_only).Count)"
Write-Host "Quarantined: $(@($report.quarantined).Count)"
Write-Host "Archived: $(@($report.archived).Count)"
Write-Host "Auto-merge JSON: $jsonPath"
Write-Host "Auto-merge report: $mdPath"
