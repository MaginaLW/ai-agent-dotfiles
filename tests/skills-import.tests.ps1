#requires -Version 7.0
<###
.SYNOPSIS
    Focused regression tests for skill inventory, analysis and fail-closed merge.

    The tests use isolated fake homes and repositories under tmp/. They never
    call auto-merge with -Apply and never touch a real live skills root.
###>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$inventoryScript = Join-Path $RepoRoot 'scripts/inventory-skills.ps1'
$analysisScript = Join-Path $RepoRoot 'scripts/analyze-skills.ps1'
$mergeScript = Join-Path $RepoRoot 'scripts/auto-merge-skills.ps1'
$normalizeScript = Join-Path $RepoRoot 'scripts/normalize-skill.ps1'
$promoteScript = Join-Path $RepoRoot 'scripts/promote-skill.ps1'
$skillsCommon = Join-Path $RepoRoot 'scripts/skills-common.ps1'
$adapterCommon = Join-Path $RepoRoot 'scripts/canonical-skill-adapter-common.ps1'
. $skillsCommon

$script:pass = 0
$script:fail = 0
function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

$work = Join-Path $RepoRoot 'tmp/skills-import-tests'
$externalArtifacts = Join-Path ([IO.Path]::GetTempPath()) ('ai-agent-dotfiles-skills-import-' + [Guid]::NewGuid().ToString('N'))
function Remove-Work {
    if (($work -like '*tmp*skills-import-tests*') -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [AllowNull()] [string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, ($Content ?? ''), [System.Text.UTF8Encoding]::new($false))
}
function New-Skill {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Name = (Split-Path -Leaf $Path),
        [string] $Body = '## Steps`n`n- Do the work.`n',
        [hashtable] $Files = @{}
    )
    $frontMatter = "---`nname: $Name`ndescription: Test skill for $Name workflows.`n---`n`n"
    Set-File -Path (Join-Path $Path 'SKILL.md') -Content ($frontMatter + $Body)
    foreach ($entry in $Files.GetEnumerator()) {
        Set-File -Path (Join-Path $Path $entry.Key) -Content ([string]$entry.Value)
    }
}
function New-Repo {
    param([string] $Name)
    $repo = Join-Path $work $Name
    foreach ($relative in @('imports/skills-inbox','skills-source/shared','skills-source/claude-only','skills-source/codex-only','skills-source/reasonix-only','claude/skills','codex/skills','reasonix/skills','manifests')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $repo $relative) | Out-Null
    }
    Set-File -Path (Join-Path $repo '.gitignore') -Content "tmp/`n"
    foreach ($manifest in @('managed-skills.claude.txt','managed-skills.codex.txt','managed-skills.reasonix.txt','managed-skills.txt')) {
        Set-File -Path (Join-Path $repo "manifests/$manifest") -Content ''
    }
    & git -C $repo init --quiet
    & git -C $repo config user.email test@example.invalid
    & git -C $repo config user.name skills-import-test
    & git -C $repo add -- .
    & git -C $repo commit --quiet -m baseline
    if ($LASTEXITCODE -ne 0) { throw "Unable to initialize disposable Git repository: $repo" }
    return $repo
}
function New-ExternalPlanPath {
    param([Parameter(Mandatory)] [string] $Name)
    if (-not (Test-Path -LiteralPath $externalArtifacts -PathType Container)) { New-Item -ItemType Directory -Path $externalArtifacts -Force | Out-Null }
    return (Join-Path $externalArtifacts ($Name + '-' + [Guid]::NewGuid().ToString('N') + '.json'))
}
function Get-MergeReportPath {
    param([Parameter(Mandatory)] [string] $PlanPath)
    return (Join-Path ($PlanPath + '.reports') 'auto-merge-report.json')
}
function Invoke-Script {
    param([Parameter(Mandatory)] [string] $Script, [string[]] $Arguments = @())
    $output = & pwsh -NoProfile -File $Script @Arguments 2>&1 | Out-String
    return @{ Out = $output; Code = $LASTEXITCODE }
}
function Get-JsonReport {
    param([Parameter(Mandatory)] [string] $Path)
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}
function Get-CommandResultFromOutput {
    param([Parameter(Mandatory)] [string] $Text)
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line.TrimStart().StartsWith('{')) {
            try { return ($line | ConvertFrom-Json -Depth 30) } catch {}
        }
    }
    return $null
}

Remove-Work
New-Item -ItemType Directory -Force -Path $work | Out-Null
New-Item -ItemType Directory -Force -Path $externalArtifacts | Out-Null

try {
    Write-Host "`n[inventory path selection and record contract]" -ForegroundColor Cyan
    $inventoryRepo = New-Repo 'inventory-repo'
    $preferredHome = Join-Path $work 'home-preferred'
    New-Skill -Path (Join-Path $preferredHome '.claude/skills/claude-skill')
    New-Skill -Path (Join-Path $preferredHome '.codex/skills/preferred-skill')
    New-Skill -Path (Join-Path $preferredHome '.agents/skills/fallback-skill')
    New-Skill -Path (Join-Path $preferredHome '.codex/skills/.system') -Name 'system'
    New-Skill -Path (Join-Path $preferredHome 'AppData/Roaming/reasonix/skills/reasonix-skill')

    $r = Invoke-Script -Script $inventoryScript -Arguments @('-RepoRoot', $inventoryRepo, '-HomeRoot', $preferredHome, '-MachineId', 'test-machine')
    $inventory = Get-JsonReport -Path (Join-Path $inventoryRepo 'imports/skills-reports/test-machine-inventory.json')
    Assert ($r.Code -eq 0) 'inventory: preferred run succeeds'
    Assert ($inventory.codex_selection.selection -eq 'preferred' -and $inventory.codex_selection.selected_path -eq '.codex/skills') 'inventory: Codex prefers .codex/skills'
    Assert (@($inventory.records | Where-Object { $_.normalized_name -eq 'fallback-skill' }).Count -eq 0) 'inventory: fallback is not scanned when preferred exists'
    Assert (@($inventory.records | Where-Object { $_.normalized_name -eq 'system' }).Count -eq 0) 'inventory: Codex .system is excluded'
    $reasonixRecord = @($inventory.records | Where-Object { $_.source_tool -eq 'reasonix' })[0]
    Assert ($null -ne $reasonixRecord -and $reasonixRecord.classification -eq 'reasonix-only') 'inventory: Reasonix record is auditable and classified'
    Assert ($null -ne $reasonixRecord.scan_status -and $reasonixRecord.modified_time_utc -eq 'not-collected' -and $reasonixRecord.sha256_tree_hash) 'record: scan status, no fabricated mtime, and fingerprints are present'
    Assert ($null -ne $reasonixRecord.platform_signals -and $null -ne $reasonixRecord.possible_binary_findings) 'record: platform and binary/path/secret finding fields are present'

    $fallbackRepo = New-Repo 'fallback-repo'
    $fallbackHome = Join-Path $work 'home-fallback'
    New-Skill -Path (Join-Path $fallbackHome '.agents/skills/fallback-only')
    $r = Invoke-Script -Script $inventoryScript -Arguments @('-RepoRoot', $fallbackRepo, '-HomeRoot', $fallbackHome, '-MachineId', 'fallback-machine', '-IncludeCodex')
    $fallbackInventory = Get-JsonReport -Path (Join-Path $fallbackRepo 'imports/skills-reports/fallback-machine-inventory.json')
    Assert ($r.Code -eq 0 -and $fallbackInventory.codex_selection.selection -eq 'fallback') 'inventory: Codex falls back to .agents/skills when preferred is missing'

    $beforeBatch = Get-FileHash -LiteralPath (Join-Path $inventoryRepo 'imports/skills-inbox/test-machine/codex/preferred-skill/SKILL.md')
    $r = Invoke-Script -Script $inventoryScript -Arguments @('-RepoRoot', $inventoryRepo, '-HomeRoot', $preferredHome, '-MachineId', 'test-machine', '-IncludeCodex')
    $afterBatch = Get-FileHash -LiteralPath (Join-Path $inventoryRepo 'imports/skills-inbox/test-machine/codex/preferred-skill/SKILL.md')
    Assert ($r.Code -ne 0 -and $beforeBatch.Hash -eq $afterBatch.Hash) 'inventory: repeated batch refuses to overwrite prior inbox evidence'

    $r = Invoke-Script -Script $analysisScript -Arguments @('-RepoRoot', $inventoryRepo)
    $analysis = Get-JsonReport -Path (Join-Path $inventoryRepo 'imports/skills-reports/skills-analysis.json')
    Assert ($r.Code -eq 0 -and $analysis.reasonix_source_skill_count -gt 0) 'analysis: Reasonix source is included'

    Write-Host "`n[merge decisions]" -ForegroundColor Cyan
    $exactRepo = New-Repo 'exact-repo'
    New-Skill -Path (Join-Path $exactRepo 'imports/skills-inbox/machine/claude/exact-skill')
    New-Skill -Path (Join-Path $exactRepo 'imports/skills-inbox/machine/codex/exact-skill')
    $exactPlan = New-ExternalPlanPath 'exact-merge'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $exactRepo, '-DryRun', '-PlanPath', $exactPlan)
    $exactReport = Get-JsonReport -Path (Get-MergeReportPath $exactPlan)
    $exactCommand = Get-CommandResultFromOutput $r.Out
    Assert ($r.Code -eq 0 -and $exactReport.exact_duplicate_count -eq 1) 'merge: exact duplicate count reports one duplicate copy'
    Assert (@($exactReport.decisions | Where-Object { $_.name -eq 'exact-skill' -and $_.status -eq 'DEDUPLICATED' -and $_.promotion_status -eq 'PROMOTE_CANDIDATE' }).Count -eq 1) 'merge: identical candidates deduplicate and expose an explicit promote candidate'
    Assert ([string]$exactCommand.ArtifactKind -ceq 'canonical-transaction-result' -and [string]$exactCommand.CommandKind -ceq 'canonical-merge' -and [string]$exactCommand.Result -ceq 'PASS') 'merge: child machine result is strict and uses the fixed merge command discriminator'

    $conflictRepo = New-Repo 'different-tree-repo'
    New-Skill -Path (Join-Path $conflictRepo 'imports/skills-inbox/a/claude/different-tree') -Body '## Steps`n`n- First variant.`n'
    New-Skill -Path (Join-Path $conflictRepo 'imports/skills-inbox/b/codex/different-tree') -Body '## Steps`n`n- Second variant.`n'
    $conflictPlan = New-ExternalPlanPath 'conflict-merge'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $conflictRepo, '-DryRun', '-PlanPath', $conflictPlan)
    $conflictReport = Get-JsonReport -Path (Get-MergeReportPath $conflictPlan)
    $differentDecision = @($conflictReport.decisions | Where-Object name -eq 'different-tree')[0]
    Assert ($r.Code -eq 0 -and $differentDecision.status -eq 'CONFLICT' -and $conflictReport.conflict_group_count -gt 0) 'merge: same-name different tree is a conflict'
    Assert (@($differentDecision.non_adopted_candidates).Count -eq 2) 'merge: conflict retains both non-adopted candidates'

    $extraRepo = New-Repo 'extra-files-repo'
    $sameMd = "---`nname: same-entry`ndescription: Same entry.`n---`n`n## Steps`n`n- Same entry.`n"
    New-Skill -Path (Join-Path $extraRepo 'imports/skills-inbox/a/claude/same-entry') -Body '## Steps`n`n- Same entry.`n' -Files @{ 'references/a.md' = 'A' }
    New-Skill -Path (Join-Path $extraRepo 'imports/skills-inbox/b/codex/same-entry') -Body '## Steps`n`n- Same entry.`n' -Files @{ 'references/b.md' = 'B' }
    Set-File -Path (Join-Path $extraRepo 'imports/skills-inbox/a/claude/same-entry/SKILL.md') -Content $sameMd
    Set-File -Path (Join-Path $extraRepo 'imports/skills-inbox/b/codex/same-entry/SKILL.md') -Content $sameMd
    $extraPlan = New-ExternalPlanPath 'extra-merge'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $extraRepo, '-DryRun', '-PlanPath', $extraPlan)
    $extraReport = Get-JsonReport -Path (Get-MergeReportPath $extraPlan)
    Assert (@($extraReport.decisions | Where-Object { $_.name -eq 'same-entry' -and $_.status -eq 'CONFLICT' }).Count -eq 1) 'merge: same SKILL.md with extra files is not silently combined'

    $canonicalRepo = New-Repo 'canonical-repo'
    New-Skill -Path (Join-Path $canonicalRepo 'skills-source/shared/retained-skill') -Body '## Steps`n`n- Canonical content.`n'
    New-Skill -Path (Join-Path $canonicalRepo 'imports/skills-inbox/machine/claude/retained-skill') -Body '## Steps`n`n- Candidate content.`n'
    New-Skill -Path (Join-Path $canonicalRepo 'imports/skills-inbox/machine/codex/retained-skill') -Body '## Steps`n`n- Canonical content.`n'
    $canonicalBefore = Get-FileHash -LiteralPath (Join-Path $canonicalRepo 'skills-source/shared/retained-skill/SKILL.md')
    $canonicalPlan = New-ExternalPlanPath 'canonical-merge'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $canonicalRepo, '-DryRun', '-PlanPath', $canonicalPlan)
    $canonicalReport = Get-JsonReport -Path (Get-MergeReportPath $canonicalPlan)
    $retained = @($canonicalReport.decisions | Where-Object name -eq 'retained-skill')[0]
    $canonicalAfter = Get-FileHash -LiteralPath (Join-Path $canonicalRepo 'skills-source/shared/retained-skill/SKILL.md')
    Assert ($r.Code -eq 0 -and $retained.status -eq 'CANONICAL_RETAINED' -and $canonicalReport.exact_duplicate_count -eq 1 -and $canonicalBefore.Hash -eq $canonicalAfter.Hash) 'merge: existing canonical is retained and exact duplicate is accounted for'

    $unsafeCanonicalRepo = New-Repo 'unsafe-canonical-repo'
    $unsafeToken = 'sk-' + 'ant-' + ('U' * 24)
    New-Skill -Path (Join-Path $unsafeCanonicalRepo 'skills-source/shared/unsafe-canonical') -Body ("## Steps`n`n- token: `"$unsafeToken`"`n")
    New-Skill -Path (Join-Path $unsafeCanonicalRepo 'imports/skills-inbox/machine/claude/unsafe-canonical') -Body '## Steps`n`n- Safe candidate.`n'
    $unsafeBefore = Get-FileHash -LiteralPath (Join-Path $unsafeCanonicalRepo 'skills-source/shared/unsafe-canonical/SKILL.md')
    $unsafePlan = New-ExternalPlanPath 'unsafe-merge'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $unsafeCanonicalRepo, '-DryRun', '-PlanPath', $unsafePlan)
    $unsafeReport = Get-JsonReport -Path (Get-MergeReportPath $unsafePlan)
    $unsafeDecision = @($unsafeReport.decisions | Where-Object name -eq 'unsafe-canonical')[0]
    $unsafeAfter = Get-FileHash -LiteralPath (Join-Path $unsafeCanonicalRepo 'skills-source/shared/unsafe-canonical/SKILL.md')
    Assert ($r.Code -ne 0 -and $unsafeDecision.status -eq 'QUARANTINED' -and $unsafeBefore.Hash -eq $unsafeAfter.Hash -and -not (Test-Path -LiteralPath $unsafePlan)) 'merge: risky existing canonical reports quarantine, blocks plan publication, and preserves canonical bytes'

    $platformRepo = New-Repo 'platform-conflict-repo'
    New-Skill -Path (Join-Path $platformRepo 'imports/skills-inbox/machine/claude/platform-skill') -Body "---`nname: platform-skill`ndescription: Claude candidate.`nallowed-tools: Read`n---`n`n## Steps`n`n- Claude.`n"
    New-Skill -Path (Join-Path $platformRepo 'imports/skills-inbox/machine/codex/platform-skill') -Files @{ 'agents/openai.yaml' = 'name: test' }
    $platformPlan = New-ExternalPlanPath 'platform-merge'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $platformRepo, '-DryRun', '-PlanPath', $platformPlan)
    $platformReport = Get-JsonReport -Path (Get-MergeReportPath $platformPlan)
    $platformDecision = @($platformReport.decisions | Where-Object name -eq 'platform-skill')[0]
    Assert ($r.Code -eq 0 -and $platformDecision.status -eq 'QUARANTINED' -and ($platformReport.conflict_groups[0].reason_codes -contains 'platform-conflict')) 'merge: Claude/Codex platform conflict is quarantined'

    $secretRepo = New-Repo 'secret-repo'
    $fakeToken = 'sk-' + 'ant-' + ('F' * 24)
    New-Skill -Path (Join-Path $secretRepo 'imports/skills-inbox/machine/claude/secret-skill') -Body ("## Steps`n`n- token: `"$fakeToken`"`n")
    $secretPlan = New-ExternalPlanPath 'secret-merge'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $secretRepo, '-DryRun', '-PlanPath', $secretPlan)
    $secretReportPath = Get-MergeReportPath $secretPlan
    $secretReport = Get-JsonReport -Path $secretReportPath
    $secretDecision = @($secretReport.decisions | Where-Object name -eq 'secret-skill')[0]
    $secretReportText = Get-Content -Raw -LiteralPath $secretReportPath
    Assert ($r.Code -eq 0 -and $secretDecision.status -eq 'QUARANTINED' -and ($secretReport.quarantined[0].reason_codes -contains 'possible-secret')) 'merge: secret finding is quarantined with a reason code'
    Assert ($secretReportText -notmatch [regex]::Escape($fakeToken)) 'merge: secret value is absent from the report'

    Write-Host "`n[pure normalization candidate]" -ForegroundColor Cyan
    $rxRepo = New-Repo 'reasonix-normalize-repo'
    $rxInput = Join-Path $work 'reasonix-normalized'
    New-Skill -Path $rxInput -Body "## Steps`n`n- Reasonix workflow.`n"
    $rxWorkspace = Join-Path $work 'reasonix-candidate'
    New-Item -ItemType Directory -Path $rxWorkspace | Out-Null
    $rx = New-NormalizedSkillCandidate -RepoRoot $rxRepo -InputSkillPath $rxInput -CandidateWorkspace $rxWorkspace -TargetType 'reasonix-only'
    Assert ($rx.Status -eq 'candidate' -and (Test-Path -LiteralPath (Join-Path $rx.CandidatePath 'SKILL.md'))) 'normalize: compatible Reasonix input produces a fresh candidate'
    Assert ($rx.CanonicalTargetPath -ceq (Join-Path $rxRepo 'skills-source/reasonix-only/reasonix-normalized')) 'normalize: canonical target is derived internally from class and skill name'

    $incompatibleInput = Join-Path $work 'reasonix-incompatible'
    New-Skill -Path $incompatibleInput -Body "---`nname: reasonix-incompatible`ndescription: Claude-only test candidate.`nallowed-tools: Read`n---`n`n## Steps`n`n- Claude-specific command.`n"
    $incompatibleTarget = Join-Path $rxRepo 'skills-source/reasonix-only/reasonix-incompatible'
    New-Skill -Path $incompatibleTarget -Body "## Existing`n`n- preserve me`n"
    $beforeIncompatible = (Get-FileHash -LiteralPath (Join-Path $incompatibleTarget 'SKILL.md')).Hash
    $incompatibleWorkspace = Join-Path $work 'reasonix-incompatible-candidate'
    New-Item -ItemType Directory -Path $incompatibleWorkspace | Out-Null
    $incompatible = New-NormalizedSkillCandidate -RepoRoot $rxRepo -InputSkillPath $incompatibleInput -CandidateWorkspace $incompatibleWorkspace -TargetType 'reasonix-only'
    $afterIncompatible = (Get-FileHash -LiteralPath (Join-Path $incompatibleTarget 'SKILL.md')).Hash
    Assert ($incompatible.Status -eq 'quarantine' -and $incompatible.Reason -eq 'platform-incompatible') 'normalize: Reasonix-incompatible input quarantines before candidate creation'
    Assert ($beforeIncompatible -eq $afterIncompatible -and @([IO.Directory]::EnumerateFileSystemEntries($incompatibleWorkspace)).Count -eq 0) 'normalize: incompatible existing target remains byte-identical and absent candidate remains absent'

    $replaceInput = Join-Path $work 'replace-skill'
    New-Skill -Path $replaceInput -Files @{ 'fresh.txt' = 'fresh' }
    $replaceTarget = Join-Path $rxRepo 'skills-source/shared/replace-skill'
    New-Skill -Path $replaceTarget -Files @{ 'stale.txt' = 'stale'; 'replace-skill/nested.txt' = 'nested stale' }
    $replaceWorkspace = Join-Path $work 'replace-candidate'
    New-Item -ItemType Directory -Path $replaceWorkspace | Out-Null
    $replace = New-NormalizedSkillCandidate -RepoRoot $rxRepo -InputSkillPath $replaceInput -CandidateWorkspace $replaceWorkspace -TargetType 'shared'
    Assert ($replace.Status -eq 'candidate' -and (Test-Path -LiteralPath (Join-Path $replace.CandidatePath 'fresh.txt'))) 'normalize: compatible existing canonical produces a replacement candidate'
    Assert (-not (Test-Path -LiteralPath (Join-Path $replace.CandidatePath 'stale.txt')) -and -not (Test-Path -LiteralPath (Join-Path $replace.CandidatePath 'replace-skill'))) 'normalize: replacement candidate contains no stale or nested prior target files'
    Assert ((Test-Path -LiteralPath (Join-Path $replaceTarget 'stale.txt')) -and (Test-Path -LiteralPath (Join-Path $replaceTarget 'replace-skill/nested.txt'))) 'normalize: candidate transform does not modify the existing canonical target'

    $secretInput = Join-Path $work 'secret-normalize'
    $normalizeToken = 'sk-' + 'ant-' + ('N' * 24)
    New-Skill -Path $secretInput -Body ("## Steps`n`n- value: `"$normalizeToken`"`n")
    $secretWorkspace = Join-Path $work 'secret-candidate'; New-Item -ItemType Directory -Path $secretWorkspace | Out-Null
    $secretCandidate = New-NormalizedSkillCandidate -RepoRoot $rxRepo -InputSkillPath $secretInput -CandidateWorkspace $secretWorkspace -TargetType 'shared'
    Assert ($secretCandidate.Status -eq 'quarantine' -and $secretCandidate.Reason -eq 'possible-secret') 'normalize: secret-shaped input quarantines without a candidate'

    $binaryInput = Join-Path $work 'binary-normalize'
    New-Skill -Path $binaryInput
    [IO.File]::WriteAllBytes((Join-Path $binaryInput 'payload.bin'), [byte[]](0,1,2,0,255,4))
    $binaryWorkspace = Join-Path $work 'binary-candidate'; New-Item -ItemType Directory -Path $binaryWorkspace | Out-Null
    $binaryCandidate = New-NormalizedSkillCandidate -RepoRoot $rxRepo -InputSkillPath $binaryInput -CandidateWorkspace $binaryWorkspace -TargetType 'shared'
    Assert ($binaryCandidate.Status -eq 'quarantine' -and $binaryCandidate.Reason -eq 'binary-or-large-file') 'normalize: binary input quarantines without a candidate'

    $conflictInput = Join-Path $work 'conflict-normalize'
    New-Skill -Path $conflictInput -Body "---`nname: conflict-normalize`ndescription: Mixed-platform test candidate.`nallowed-tools: Read`n---`n`n## Steps`n`n- Mixed platform.`n" -Files @{ 'agents/openai.yaml'='Codex' }
    $conflictWorkspace = Join-Path $work 'conflict-candidate'; New-Item -ItemType Directory -Path $conflictWorkspace | Out-Null
    $conflictCandidate = New-NormalizedSkillCandidate -RepoRoot $rxRepo -InputSkillPath $conflictInput -CandidateWorkspace $conflictWorkspace -TargetType 'shared'
    Assert ($conflictCandidate.Status -eq 'quarantine' -and $conflictCandidate.Reason -eq 'platform-conflict') 'normalize: mixed-platform input quarantines without a candidate'

    $classInput = Join-Path $work 'retained-skill'
    New-Skill -Path $classInput
    $classWorkspace = Join-Path $work 'class-candidate'; New-Item -ItemType Directory -Path $classWorkspace | Out-Null
    $classCandidate = New-NormalizedSkillCandidate -RepoRoot $canonicalRepo -InputSkillPath $classInput -CandidateWorkspace $classWorkspace -TargetType 'codex-only'
    Assert ($classCandidate.Status -eq 'quarantine' -and $classCandidate.Reason -eq 'canonical-class-conflict') 'normalize: a name in another canonical class is rejected'

    $externalPlan = Join-Path ([IO.Path]::GetTempPath()) "normalize-plan-$([guid]::NewGuid().ToString('N')).json"
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot',$rxRepo,'-InputSkillPath',$rxInput,'-TargetType','reasonix-only','-DryRun','-PlanPath',$externalPlan)
    $normalizeDocument = if (Test-Path -LiteralPath $externalPlan) { Get-Content -Raw -LiteralPath $externalPlan | ConvertFrom-Json -Depth 100 } else { $null }
    $normalizeCommand = Get-CommandResultFromOutput $r.Out
    Assert ($r.Code -eq 0 -and $null -ne $normalizeDocument -and [string]$normalizeDocument.PlanPayload.OperationKind -ceq 'normalize' -and [string]$normalizeCommand.CommandKind -ceq 'canonical-normalize') 'normalize: public DryRun creates one external reviewed canonical plan and validates its child result'
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot',$rxRepo,'-InputSkillPath',$rxInput,'-TargetType','reasonix-only','-Apply','-PlanPath',$externalPlan)
    Assert ($r.Code -eq 75 -and $r.Out -match 'canonical-apply-interlocked') 'normalize: Apply consumes the same stored normalize plan and remains production-interlocked'
    $legacyOutput = Join-Path $rxRepo 'skills-source/reasonix-only/arbitrary-output'
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot',$rxRepo,'-InputSkillPath',$rxInput,'-TargetType','reasonix-only','-DryRun','-PlanPath',$externalPlan,'-OutputSkillPath',$legacyOutput)
    Assert ($r.Code -ne 0 -and -not (Test-Path -LiteralPath $legacyOutput)) 'normalize: arbitrary OutputSkillPath is no longer accepted'

    $promoteRepo = New-Repo 'promote-adapter-repo'
    $promoteInput = Join-Path $work 'promote-adapter-input'; New-Skill -Path $promoteInput -Name 'promote-adapter-input'
    $promotePlan = New-ExternalPlanPath 'promote-adapter'
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot',$promoteRepo,'-InputSkillPath',$promoteInput,'-TargetType','shared','-DryRun','-PlanPath',$promotePlan)
    $promoteDocument = if (Test-Path -LiteralPath $promotePlan) { Get-Content -Raw -LiteralPath $promotePlan | ConvertFrom-Json -Depth 100 } else { $null }
    $promoteCommand = Get-CommandResultFromOutput $r.Out
    Assert ($r.Code -eq 0 -and [string]$promoteDocument.PlanPayload.OperationKind -ceq 'promote' -and [string]$promoteCommand.CommandKind -ceq 'canonical-promote') 'promote: public DryRun stores the exact promote operation kind and validates its child result'
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot',$rxRepo,'-InputSkillPath',$rxInput,'-TargetType','reasonix-only','-Apply','-PlanPath',$externalPlan)
    $promoteMismatchCommand = Get-CommandResultFromOutput $r.Out
    Assert ($r.Code -eq 1 -and [string]$promoteMismatchCommand.Result -ceq 'FAIL' -and [string]$promoteMismatchCommand.CommandKind -ceq 'canonical-promote' -and [string]$promoteMismatchCommand.MessageToken -ceq 'canonical-plan-stale' -and $r.Out -notmatch 'canonical-operation-kind-mismatch') 'promote: an Apply alias cannot reinterpret a reviewed normalize plan'
    New-Skill -Path (Join-Path $promoteRepo 'skills-source/shared/retained-promote') -Name 'retained-promote'
    $retainedInput = Join-Path $work 'retained-promote'; New-Skill -Path $retainedInput -Name 'retained-promote'
    $retainedPlan = New-ExternalPlanPath 'retained-promote'
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot',$promoteRepo,'-InputSkillPath',$retainedInput,'-TargetType','shared','-DryRun','-PlanPath',$retainedPlan)
    Assert ($r.Code -eq 3 -and $r.Out -match 'canonical-retained' -and -not (Test-Path -LiteralPath $retainedPlan)) 'promote: an existing canonical skill is retained and no replacement plan is issued'

    if (Test-Path -LiteralPath $adapterCommon -PathType Leaf) {
        . $adapterCommon
        $batchRepo = New-Repo 'batch-atomic-repo'
        $firstInput = Join-Path $work 'batch-first'; $secondInput = Join-Path $work 'batch-second'
        New-Skill -Path $firstInput -Name 'batch-first'
        Set-File -Path (Join-Path $secondInput 'README.txt') -Content 'intentionally lacks SKILL.md'
        $batchWorkspace = New-CanonicalAdapterWorkspace -RepoRoot $batchRepo
        $batchCanonicalRoot = Join-Path $batchRepo 'skills-source'
        $batchCanonicalBefore = (Get-SafeTreeSnapshot -Root $batchCanonicalRoot).TreeHash
        $batchCommand = Get-Command New-CanonicalBatchCandidateWorkspace -CommandType Function -ErrorAction Stop
        Assert (-not $batchCommand.Parameters.ContainsKey('InternalCandidateBuilder')) 'adapters: production batch candidate builder exposes no executable test seam'
        $batch = New-CanonicalBatchCandidateWorkspace -RepoRoot $batchRepo -CandidateWorkspace $batchWorkspace -Proposals @(
            [ordered]@{InputSkillPath=$firstInput;TargetType='shared'},
            [ordered]@{InputSkillPath=$secondInput;TargetType='shared'}
        )
        $batchCanonicalAfter = (Get-SafeTreeSnapshot -Root $batchCanonicalRoot).TreeHash
        $firstBatchResult = @($batch.Results)[0]
        Assert ([string]$batch.Status -ceq 'quarantine' -and [string]$batch.Reason -ceq 'missing-skill-md' -and [int]$batch.FailedIndex -eq 1 -and @($batch.Results).Count -eq 1 -and [string]$firstBatchResult.Status -ceq 'candidate' -and [string]$firstBatchResult.Name -ceq 'batch-first') 'merge: a natural later candidate rejection occurs only after the first isolated candidate succeeds'
        Assert (-not (Test-Path -LiteralPath (Join-Path $batchWorkspace 'skills-source')) -and $batchCanonicalBefore -ceq $batchCanonicalAfter -and -not (Test-Path -LiteralPath (Join-Path $batchRepo 'skills-source/shared/batch-first'))) 'merge: a later candidate failure publishes no candidate source view and leaves canonical source byte-identical'
    }
    else { Assert $false 'merge: canonical adapter common exists for batch atomicity tests' }

    $legacyMutationText = (@($normalizeScript,$promoteScript,$mergeScript) | ForEach-Object { Get-Content -Raw -LiteralPath $_ }) -join "`n"
    Assert ($legacyMutationText -notmatch 'Normalize-SkillDirectory|Copy-SkillToArchive|\bCopy-Item\b|\bRemove-Item\b') 'adapters: legacy direct canonical/archive mutation paths and write-after-build flow are absent'

}
catch {
    $script:fail++
    Write-Host "  FAIL  unhandled test error: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host ''
    Write-Host ("Results: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
    if ($script:fail -eq 0) {
        Remove-Work
        if (Test-Path -LiteralPath $externalArtifacts) { Remove-Item -LiteralPath $externalArtifacts -Recurse -Force }
    }
}

if ($script:fail -ne 0) {
    Write-Host "Workspace kept for inspection: $work" -ForegroundColor Yellow
    exit 1
}
exit 0
