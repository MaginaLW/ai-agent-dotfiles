#requires -Version 7.0
<#
.SYNOPSIS
    Decides how skills in imports/skills-inbox/ merge into skills-source/ and, with
    -Apply, promotes the unambiguous candidates.

.DESCRIPTION
    Every inbox skill gets a decision (DEDUPLICATED, CANONICAL_RETAINED,
    PROMOTE_CANDIDATE, CONFLICT or QUARANTINED; see docs/MERGE_POLICY.md). Reports are
    written to imports/skills-reports/auto-merge-report.json and .md.

    -DryRun (the default) builds the PROMOTE_CANDIDATE skills as normalized candidates
    under tmp/skill-candidates/<guid> and prints what would be written. -Apply rebuilds
    them, copies each create-new into skills-source/<type>/<name> (an existing skill is
    never replaced), and runs build-skills.ps1 and scan-secrets.ps1. When an existing
    skills-source skill fails the risk checks, both modes stop with exit 1 and Apply
    writes nothing. Git is the recovery path.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch] $Apply,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'skill-candidate-common.ps1')

$sourceTypes = @('shared', 'claude-only', 'codex-only', 'reasonix-only')

function Get-InboxRecords {
    $records = [System.Collections.Generic.List[object]]::new()
    $inboxRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-inbox'
    if (-not (Test-Path -LiteralPath $inboxRoot)) { return @() }
    foreach ($machine in @(Get-ChildItem -LiteralPath $inboxRoot -Directory -Force | Sort-Object Name)) {
        foreach ($tool in @('claude', 'codex', 'reasonix')) {
            $toolRoot = Join-Path $machine.FullName $tool
            $preferred = if ($tool -eq 'reasonix') { 'reasonix-only' } else { '' }
            foreach ($skill in @(Get-SkillDirectories -RootPath $toolRoot -ExcludeNames @('.system'))) {
                $records.Add((Get-SkillRecord -RepoRoot $RepoRoot -SkillPath $skill.FullName -SourceTool $tool -MachineId $machine.Name -Collection 'inbox' -PreferredPlatform $preferred))
            }
        }
    }
    return @($records)
}

function Get-CanonicalRecords {
    param([Parameter(Mandatory)] [string] $Name)

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($type in $sourceTypes) {
        $root = Join-RepoPath -RepoRoot $RepoRoot -RelativePath "skills-source/$type"
        foreach ($skill in @(Get-SkillDirectories -RootPath $root -ExcludeNames @('.system'))) {
            $sourceTool = if ($type -eq 'reasonix-only') { 'reasonix' } else { $type }
            $record = Get-SkillRecord -RepoRoot $RepoRoot -SkillPath $skill.FullName -SourceTool $sourceTool -MachineId 'source' -Collection 'skills-source' -PreferredPlatform $type
            if ($record.normalized_name -eq $Name) { $records.Add([pscustomobject] @{ Type = $type; Record = $record }) }
        }
    }
    return @($records)
}

function Get-RecordRiskReasons {
    param([Parameter(Mandatory)] [object] $Record)

    $reasons = [System.Collections.Generic.List[string]]::new()
    if (@($Record.possible_secret_findings).Count -gt 0 -or $Record.scan_status -eq 'quarantine-secret') { $reasons.Add('possible-secret') }
    if (@($Record.possible_binary_findings).Count -gt 0 -or $Record.scan_status -eq 'quarantine-binary-or-large-file') { $reasons.Add('binary-or-large-file') }
    if (@($Record.possible_local_path_findings).Count -gt 0 -or $Record.scan_status -eq 'review-required-path') { $reasons.Add('machine-private-path') }
    if ($Record.classification -eq 'quarantine' -or $Record.scan_status -eq 'quarantine-platform-conflict') { $reasons.Add('platform-conflict') }
    if (-not $Record.has_skill_md -or $Record.scan_status -eq 'failed-missing-entrypoint') { $reasons.Add('missing-entrypoint') }
    if ($reasons.Count -eq 0 -and $Record.scan_status -ne 'passed') { $reasons.Add('scan-failed') }
    return @($reasons | Sort-Object -Unique)
}

function Get-PlatformConflict {
    param([Parameter(Mandatory)] [object[]] $Records)

    $classes = @($Records | ForEach-Object classification | Where-Object { $_ -and $_ -ne 'shared' } | Sort-Object -Unique)
    return ($classes.Count -gt 1 -or ($classes.Count -eq 1 -and @($Records | Where-Object { $_.classification -eq 'shared' }).Count -gt 0))
}

function ConvertTo-CandidateSummary {
    param(
        [Parameter(Mandatory)] [object] $Record,
        [string[]] $Reasons = @()
    )

    return [pscustomobject] [ordered] @{
        source = $Record.source_path
        source_tool = $Record.source_tool
        machine_id = $Record.machine_id
        collection = $Record.collection
        normalized_name = $Record.normalized_name
        classification = $Record.classification
        scan_status = $Record.scan_status
        sha256_of_skill_md = $Record.sha256_of_skill_md
        sha256_tree_hash = $Record.sha256_tree_hash
        file_count = $Record.file_count
        total_size = $Record.total_size
        reasons = @($Reasons)
        quality_score = $Record.quality_score
    }
}

function Add-QuarantineRecord {
    param(
        [Parameter(Mandatory)] [object] $Record,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string[]] $Reasons
    )

    $reason = if ($Reasons.Count -gt 0) { $Reasons[0] } else { 'unresolved-name-conflict' }
    $targetRelative = "imports/skills-quarantine/$reason/$($Record.machine_id)/$($Record.source_tool)/$Name"
    return [pscustomobject] [ordered] @{
        name = $Name
        reason = $reason
        reason_codes = @($Reasons)
        source = $Record.source_path
        source_tool = $Record.source_tool
        machine_id = $Record.machine_id
        sha256_tree_hash = $Record.sha256_tree_hash
        target = $targetRelative
    }
}

function Get-FingerprintRows {
    param([Parameter(Mandatory)] [object[]] $Records)

    return @($Records | Group-Object sha256_tree_hash | ForEach-Object {
        [pscustomobject] [ordered] @{
            hash = $_.Name
            count = $_.Count
            sources = @($_.Group | ForEach-Object { $_.source_path })
        }
    })
}

try {
if ($DryRun -and $Apply) { throw 'Specify only one of -DryRun or -Apply.' }
$RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
$mode = if ($Apply) { 'apply' } else { 'dry-run' }
Write-Host "Mode: $mode"

$inboxRecords = @(Get-InboxRecords)
$decisions = [System.Collections.Generic.List[object]]::new()
$conflictGroups = [System.Collections.Generic.List[object]]::new()
$quarantined = [System.Collections.Generic.List[object]]::new()
$promoted = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[object]]::new()
$exactDuplicateGroups = [System.Collections.Generic.List[object]]::new()
$proposals = [System.Collections.Generic.List[object]]::new()
$exactDuplicateCount = 0

foreach ($group in @($inboxRecords | Group-Object normalized_name | Sort-Object Name)) {
    $name = $group.Name
    $candidates = @($group.Group | Sort-Object source_path)
    $canonicalEntries = @(Get-CanonicalRecords -Name $name)
    $canonicalValid = @($canonicalEntries | Where-Object { $_.Record.scan_status -eq 'passed' -and $_.Record.classification -ne 'quarantine' })
    $candidateReasons = @{}
    foreach ($candidate in $candidates) { $candidateReasons[$candidate.resolved_source_path] = @(Get-RecordRiskReasons -Record $candidate) }
    $validCandidates = @($candidates | Where-Object { $candidateReasons[$_.resolved_source_path].Count -eq 0 })

    $candidateTreeGroups = @($validCandidates | Where-Object sha256_tree_hash | Group-Object sha256_tree_hash)
    foreach ($treeGroup in $candidateTreeGroups | Where-Object Count -gt 1) {
        $exactDuplicateCount += $treeGroup.Count - 1
        $exactDuplicateGroups.Add([pscustomobject] [ordered] @{
            name = $name
            tree_hash = $treeGroup.Name
            duplicate_count = $treeGroup.Count - 1
            canonical_source = if ($canonicalValid.Count -eq 1 -and $canonicalValid[0].Record.sha256_tree_hash -eq $treeGroup.Name) { $canonicalValid[0].Record.source_path } else { 'none' }
            candidates = @($treeGroup.Group | ForEach-Object { $_.source_path })
        })
    }

    $allSummaries = @($candidates | ForEach-Object { ConvertTo-CandidateSummary -Record $_ -Reasons $candidateReasons[$_.resolved_source_path] })
    $status = 'CONFLICT'
    $promotionStatus = 'none'
    $reasonCodes = [System.Collections.Generic.List[string]]::new()
    $canonicalSource = 'none'
    $canonicalFingerprint = $null
    $adopted = $null

    $canonicalInvalid = @($canonicalEntries | Where-Object { $_.Record.scan_status -ne 'passed' -or $_.Record.classification -eq 'quarantine' })
    if ($canonicalInvalid.Count -gt 0) {
        $status = 'QUARANTINED'
        $reasonCodes.Add('existing-canonical-risk')
        foreach ($candidate in $candidates) {
            $reasons = $candidateReasons[$candidate.resolved_source_path]
            if ($reasons.Count -eq 0) { $reasons = @('existing-canonical-risk') }
            $quarantined.Add((Add-QuarantineRecord -Record $candidate -Name $name -Reasons $reasons))
        }
        $conflictGroups.Add([pscustomobject] [ordered] @{
            name = $name
            reason_codes = @('existing-canonical-risk')
            canonical_sources = @($canonicalEntries | ForEach-Object Record | ForEach-Object source_path)
            source_fingerprints = Get-FingerprintRows -Records $candidates
            candidates = $allSummaries
            non_adopted_candidates = $allSummaries
        })
    }
    elseif ($canonicalValid.Count -gt 1) {
        $status = 'CONFLICT'
        $reasonCodes.Add('multiple-canonical-sources')
        if ((@($canonicalValid | ForEach-Object Type | Sort-Object -Unique).Count) -gt 1) { $reasonCodes.Add('platform-conflict') }
        $conflictGroups.Add([pscustomobject] [ordered] @{
            name = $name
            reason_codes = @($reasonCodes)
            canonical_sources = @($canonicalValid | ForEach-Object Record | ForEach-Object source_path)
            source_fingerprints = Get-FingerprintRows -Records $candidates
            candidates = $allSummaries
            non_adopted_candidates = $allSummaries
        })
    }
    elseif ($canonicalValid.Count -eq 1) {
        $canonical = $canonicalValid[0]
        $canonicalSource = $canonical.Record.source_path
        $canonicalFingerprint = $canonical.Record.sha256_tree_hash
        $sameAsCanonical = @($validCandidates | Where-Object { $_.sha256_tree_hash -eq $canonicalFingerprint })
        $differentFromCanonical = @($validCandidates | Where-Object { $_.sha256_tree_hash -ne $canonicalFingerprint })
        $riskyCandidates = @($candidates | Where-Object { $candidateReasons[$_.resolved_source_path].Count -gt 0 })
        if ($sameAsCanonical.Count -gt 0) {
            $exactDuplicateCount += $sameAsCanonical.Count
            $exactDuplicateGroups.Add([pscustomobject] [ordered] @{
                name = $name
                tree_hash = $canonicalFingerprint
                duplicate_count = $sameAsCanonical.Count
                canonical_source = $canonicalSource
                candidates = @($sameAsCanonical | ForEach-Object { $_.source_path })
            })
        }
        if ($differentFromCanonical.Count -gt 0) {
            $reasonCodes.Add('unresolved-name-conflict')
        }
        if ($riskyCandidates.Count -gt 0) {
            foreach ($candidate in $riskyCandidates) {
                $quarantined.Add((Add-QuarantineRecord -Record $candidate -Name $name -Reasons $candidateReasons[$candidate.resolved_source_path]))
            }
        }
        $status = if ($differentFromCanonical.Count -eq 0) { 'DEDUPLICATED' } else { 'CANONICAL_RETAINED' }
        if ($differentFromCanonical.Count -gt 0) {
            $conflictGroups.Add([pscustomobject] [ordered] @{
                name = $name
                reason_codes = @('unresolved-name-conflict')
                canonical_sources = @($canonicalSource)
                source_fingerprints = Get-FingerprintRows -Records $candidates
                candidates = $allSummaries
                non_adopted_candidates = $allSummaries
            })
        }
        foreach ($candidate in $candidates) {
            $skipped.Add([pscustomobject] @{ name = $name; reason = if ($candidate.sha256_tree_hash -eq $canonicalFingerprint) { 'canonical-retained-exact-duplicate' } else { 'canonical-retained-conflict' }; source = $candidate.source_path })
        }
    }
    elseif ($candidates.Count -eq 0) {
        continue
    }
    elseif ($candidates | Where-Object { $candidateReasons[$_.resolved_source_path].Count -gt 0 }) {
        $status = 'QUARANTINED'
        $reasonCodes.Add('candidate-risk')
        foreach ($candidate in $candidates) {
            $reasons = $candidateReasons[$candidate.resolved_source_path]
            if ($reasons.Count -eq 0) { $reasons = @('unresolved-name-conflict') }
            $quarantined.Add((Add-QuarantineRecord -Record $candidate -Name $name -Reasons $reasons))
        }
    }
    elseif (Get-PlatformConflict -Records $validCandidates) {
        $status = 'QUARANTINED'
        $reasonCodes.Add('platform-conflict')
        foreach ($candidate in $candidates) {
            $quarantined.Add((Add-QuarantineRecord -Record $candidate -Name $name -Reasons @('platform-conflict')))
        }
        $conflictGroups.Add([pscustomobject] [ordered] @{
            name = $name
            reason_codes = @('platform-conflict')
            canonical_sources = @('none')
            source_fingerprints = Get-FingerprintRows -Records $validCandidates
            candidates = $allSummaries
            non_adopted_candidates = $allSummaries
        })
    }
    elseif ($candidateTreeGroups.Count -eq 1) {
        $treeGroup = $candidateTreeGroups[0]
        $promotionStatus = 'PROMOTE_CANDIDATE'
        $status = if ($treeGroup.Count -gt 1) { 'DEDUPLICATED' } else { 'PROMOTE_CANDIDATE' }
        # Deterministic source ordering is only a tie-breaker among identical
        # content. Quality score never participates in canonical selection.
        $adopted = @($treeGroup.Group | Sort-Object source_path | Select-Object -First 1)[0]
        $canonicalSource = $adopted.source_path
        $canonicalFingerprint = $adopted.sha256_tree_hash
        if ($treeGroup.Count -gt 1) {
            foreach ($candidate in @($treeGroup.Group | Where-Object { $_.resolved_source_path -ne $adopted.resolved_source_path })) {
                $skipped.Add([pscustomobject] @{ name = $name; reason = 'deduplicated-not-adopted'; source = $candidate.source_path })
            }
        }
        $targetType = $adopted.classification
        if ($targetType -notin $sourceTypes) { $targetType = 'shared' }
        $proposals.Add([ordered]@{InputSkillPath=[string]$adopted.resolved_source_path;TargetType=$targetType;Name=$name;Source=[string]$adopted.source_path})
    }
    else {
        $status = 'CONFLICT'
        $reasonCodes.Add('unresolved-name-conflict')
        $conflictGroups.Add([pscustomobject] [ordered] @{
            name = $name
            reason_codes = @('unresolved-name-conflict')
            canonical_sources = @('none')
            source_fingerprints = Get-FingerprintRows -Records $validCandidates
            candidates = $allSummaries
            non_adopted_candidates = $allSummaries
        })
    }

    $nonAdopted = if ($null -ne $adopted) {
        @($allSummaries | Where-Object { $_.source -ne $adopted.source_path })
    }
    else { $allSummaries }
    $decisions.Add([pscustomobject] [ordered] @{
        name = $name
        status = $status
        promotion_status = $promotionStatus
        canonical_status = if ($canonicalValid.Count -eq 1) { 'CANONICAL_RETAINED' } else { 'none' }
        reason_codes = @($reasonCodes)
        target_type = if ($adopted -and $adopted.classification -in $sourceTypes) { $adopted.classification } else { 'none' }
        canonical_source = $canonicalSource
        canonical_tree_hash = $canonicalFingerprint
        source_fingerprints = Get-FingerprintRows -Records $candidates
        candidates = $allSummaries
        non_adopted_candidates = $nonAdopted
    })
}

$blockedNames = @($decisions | Where-Object { @($_.reason_codes) -contains 'existing-canonical-risk' } | ForEach-Object name)
$workspace = $null
$results = @()
if ($proposals.Count -gt 0) {
    $workspace = New-SkillCandidateWorkspace -RepoRoot $RepoRoot
    $set = New-SkillCandidateSet -RepoRoot $RepoRoot -Workspace $workspace -Proposals @($proposals)
    if ([string]$set.Status -cne 'candidate') { throw "Auto-merge candidate construction failed at index $($set.FailedIndex): $($set.Reason)" }
    $results = @($set.Results)
}

$buildSkillsResult = 'NOT_RUN'
$scanSecretsResult = 'NOT_RUN'
$promotedStatus = if ($blockedNames.Count -gt 0) { 'BLOCKED' } else { 'PLANNED' }
if ($Apply -and $blockedNames.Count -eq 0 -and $results.Count -gt 0) {
    foreach ($result in $results) {
        $relative = "skills-source/$([string]$result.TargetType)/$([string]$result.Name)"
        if (Test-Path -LiteralPath (Join-Path $RepoRoot $relative)) { throw "Refusing to overwrite existing skill: $relative" }
    }
    foreach ($result in $results) { $null = Install-SkillCandidate -RepoRoot $RepoRoot -Result $result }
    $promotedStatus = 'WRITTEN'
    $checks = Invoke-SkillCandidateChecks -RepoRoot $RepoRoot
    $buildSkillsResult = [string]$checks.Build
    $scanSecretsResult = [string]$checks.Scan
}
foreach ($result in $results) {
    $proposal = @($proposals | Where-Object { [string]$_.Name -ceq [string]$result.Name })[0]
    $promoted.Add([pscustomobject] @{ name=[string]$result.Name;target="skills-source/$([string]$result.TargetType)/$([string]$result.Name)";source=[string]$proposal.Source;status=$promotedStatus })
}

$sourceStructure = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($type in $sourceTypes) {
    foreach ($skill in @(Get-SkillDirectories -RootPath (Join-Path $RepoRoot "skills-source/$type") -ExcludeNames @('.system'))) {
        $null = $sourceStructure.Add("$type/$($skill.Name)")
    }
}
if ($promotedStatus -ne 'BLOCKED') {
    foreach ($result in $results) { $null = $sourceStructure.Add("$([string]$result.TargetType)/$([string]$result.Name)") }
}

$report = [pscustomobject] [ordered] @{
    generated_at = (Get-Date).ToString('o')
    mode = $mode
    scanned_skill_count = $inboxRecords.Count
    exact_duplicate_count = $exactDuplicateCount
    exact_duplicate_group_count = $exactDuplicateGroups.Count
    exact_duplicate_groups = @($exactDuplicateGroups)
    conflict_group_count = $conflictGroups.Count
    conflict_groups = @($conflictGroups)
    quarantine_count = $quarantined.Count
    quarantined = @($quarantined)
    decisions = @($decisions)
    promoted = @($promoted)
    skipped = @($skipped)
    canonical_sources = @($decisions | Where-Object { $_.canonical_source -and $_.canonical_source -ne 'none' } | ForEach-Object {
        [pscustomobject] @{ name = $_.name; source = $_.canonical_source; status = $_.status }
    })
    merged_shared = @($promoted | Where-Object target -like 'skills-source/shared/*' | ForEach-Object name)
    merged_claude_only = @($promoted | Where-Object target -like 'skills-source/claude-only/*' | ForEach-Object name)
    merged_codex_only = @($promoted | Where-Object target -like 'skills-source/codex-only/*' | ForEach-Object name)
    merged_reasonix_only = @($promoted | Where-Object target -like 'skills-source/reasonix-only/*' | ForEach-Object name)
    blocked_by_existing_canonical_risk = @($blockedNames)
    candidate_workspace = if ($workspace) { Get-RelativeDisplayPath -Root $RepoRoot -Path $workspace } else { 'none' }
    final_skills_source_structure = @($sourceStructure | Sort-Object)
    build_skills_result = $buildSkillsResult
    scan_secrets_result = $scanSecretsResult
}

$reportsRoot = Join-Path $RepoRoot 'imports/skills-reports'
Assert-SkillCandidateNoReparseChain -Root $RepoRoot -Path $reportsRoot
$jsonPath = Join-Path $reportsRoot 'auto-merge-report.json'
$mdPath = Join-Path $reportsRoot 'auto-merge-report.md'
Write-Utf8NoBomFile -Path $jsonPath -Content (($report | ConvertTo-Json -Depth 50) + "`n")

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Auto-Merge Report')
$lines.Add('')
$lines.Add("Mode: $($report.mode)")
$lines.Add("Scanned skills: $($report.scanned_skill_count)")
$lines.Add("Exact duplicate groups: $($report.exact_duplicate_group_count) (duplicate copies: $($report.exact_duplicate_count))")
$lines.Add("Conflict groups: $($report.conflict_group_count)")
$lines.Add("Quarantined candidates: $($report.quarantine_count)")
$lines.Add('')
$lines.Add('## Decisions')
$lines.Add('')
$lines.Add('| Skill | Status | Target | Canonical source | Reason codes |')
$lines.Add('| --- | --- | --- | --- | --- |')
foreach ($decision in $report.decisions) {
    $lines.Add("| $($decision.name) | $($decision.status) | $($decision.target_type) | $($decision.canonical_source) | $([string]::Join(', ', @($decision.reason_codes))) |")
}
$lines.Add('')
$lines.Add('## Promoted')
foreach ($item in $report.promoted) { $lines.Add("- $($item.name): $($item.target) ($($item.status))") }
$lines.Add('')
$lines.Add('## Conflicts')
foreach ($conflict in $report.conflict_groups) {
    $lines.Add("- $($conflict.name): $([string]::Join(', ', @($conflict.reason_codes)))")
    foreach ($fingerprint in $conflict.source_fingerprints) { $lines.Add("  - $($fingerprint.hash): $($fingerprint.count) candidate(s)") }
}
$lines.Add('')
$lines.Add('## Quarantine')
foreach ($item in $report.quarantined) { $lines.Add("- $($item.name): $($item.reason) ($($item.source))") }
$lines.Add('')
$lines.Add('## Build / Scan')
$lines.Add('')
$lines.Add("Build: $($report.build_skills_result)")
$lines.Add("Secret scan: $($report.scan_secrets_result)")
Write-Utf8NoBomFile -Path $mdPath -Content (($lines -join "`n") + "`n")

Write-Host 'Report: imports/skills-reports/auto-merge-report.json and auto-merge-report.md'
Write-Host ('Decisions: {0}; promote candidates: {1}; conflicts: {2}; quarantined: {3}' -f $decisions.Count, $results.Count, $conflictGroups.Count, $quarantined.Count)
Write-SkillCandidatePlan -RepoRoot $RepoRoot -Results $results

if ($blockedNames.Count -gt 0) {
    Write-Host "blocked: existing skills-source skill(s) failed the risk checks: $([string]::Join(', ', $blockedNames)). Fix them first; nothing was written."
    exit 1
}
if (-not $Apply) {
    Write-Host 'Dry run only: nothing was written to skills-source/. Rerun with -Apply to promote the candidates.'
    exit 0
}
if ($buildSkillsResult -eq 'FAIL' -or $scanSecretsResult -eq 'FAIL') {
    Write-Host 'Checks failed. Review the change with git status / git diff and revert it with Git if needed.'
    exit 1
}
Write-Host 'Merge applied. Review with git status / git diff before committing.'
exit 0
}
catch {
    [Console]::Error.WriteLine("auto-merge-skills: $($_.Exception.Message)")
    exit 1
}
