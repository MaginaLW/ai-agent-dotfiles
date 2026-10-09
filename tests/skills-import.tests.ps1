#requires -Version 7.0
<###
.SYNOPSIS
    Focused regression tests for skill inventory, analysis, merge decisions and the
    normalize/promote/merge candidate flow.

    Every fixture (fake homes, disposable Git repositories, input skills) lives under
    a fresh %TEMP% directory. The tests never touch the real repository's
    skills-source/ or a real live skills root. -Apply runs only against the fixture
    repositories, where it also runs build-skills.ps1 and scan-secrets.ps1.
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
$candidateCommon = Join-Path $RepoRoot 'scripts/skill-candidate-common.ps1'
. $candidateCommon

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

$work = Join-Path ([IO.Path]::GetTempPath()) ('ai-agent-dotfiles-skills-import-' + [Guid]::NewGuid().ToString('N'))
function Remove-Work {
    if (($work -like '*ai-agent-dotfiles-skills-import-*') -and (Test-Path -LiteralPath $work)) {
        # Unlink junctions first so a recursive delete never walks through one.
        foreach ($link in @(Get-ChildItem -LiteralPath $work -Recurse -Force -Directory -Attributes ReparsePoint -ErrorAction SilentlyContinue)) {
            [IO.Directory]::Delete($link.FullName)
        }
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
    Set-File -Path (Join-Path $repo '.gitignore') -Content "tmp/`nreports/`nclaude/skills/`ncodex/skills/`nreasonix/skills/`nimports/skills-inbox/`nimports/skills-reports/`n"
    foreach ($manifest in @('managed-skills.claude.txt','managed-skills.codex.txt','managed-skills.reasonix.txt','managed-skills.txt')) {
        Set-File -Path (Join-Path $repo "manifests/$manifest") -Content ''
    }
    & git -C $repo init --quiet
    & git -C $repo config user.email test@example.invalid
    & git -C $repo config user.name skills-import-test
    & git -C $repo config core.autocrlf false
    & git -C $repo add -- .
    & git -C $repo commit --quiet -m baseline
    if ($LASTEXITCODE -ne 0) { throw "Unable to initialize disposable Git repository: $repo" }
    return $repo
}
function Get-MergeReportPath {
    param([Parameter(Mandatory)] [string] $Repo)
    return (Join-Path $Repo 'imports/skills-reports/auto-merge-report.json')
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
function Get-SourceHash {
    param([Parameter(Mandatory)] [string] $Repo)
    $root = Join-Path $Repo 'skills-source'
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force | ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName) } | Sort-Object)
    return "$(Get-TreeHash -Path $root)|$($dirs -join ',')"
}

Remove-Work
New-Item -ItemType Directory -Force -Path $work | Out-Null

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

    Write-Host "`n[merge decisions (dry run)]" -ForegroundColor Cyan
    $exactRepo = New-Repo 'exact-repo'
    New-Skill -Path (Join-Path $exactRepo 'imports/skills-inbox/machine/claude/exact-skill')
    New-Skill -Path (Join-Path $exactRepo 'imports/skills-inbox/machine/codex/exact-skill')
    $exactSourceBefore = Get-SourceHash -Repo $exactRepo
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $exactRepo)
    $exactReport = Get-JsonReport -Path (Get-MergeReportPath $exactRepo)
    Assert ($r.Code -eq 0 -and $exactReport.exact_duplicate_count -eq 1 -and $exactReport.mode -eq 'dry-run') 'merge: dry run is the default and counts one exact duplicate copy'
    Assert (@($exactReport.decisions | Where-Object { $_.name -eq 'exact-skill' -and $_.status -eq 'DEDUPLICATED' -and $_.promotion_status -eq 'PROMOTE_CANDIDATE' }).Count -eq 1) 'merge: identical candidates deduplicate and expose an explicit promote candidate'
    $exactPromoted = @($exactReport.promoted)[0]
    Assert ($null -ne $exactPromoted -and $exactPromoted.status -eq 'PLANNED' -and $r.Out -match [regex]::Escape("create $($exactPromoted.target)") -and $exactReport.build_skills_result -eq 'NOT_RUN') 'merge: dry run prints the planned create and runs no build or scan'
    Assert ((Get-SourceHash -Repo $exactRepo) -ceq $exactSourceBefore -and $exactReport.candidate_workspace -like 'tmp/skill-candidates/*' -and (Test-Path -LiteralPath (Join-Path $exactRepo $exactReport.candidate_workspace))) 'merge: dry run writes only a candidate under tmp/skill-candidates'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $exactRepo, '-DryRun', '-PlanPath', (Join-Path $work 'retired-plan.json'))
    Assert ($r.Code -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $work 'retired-plan.json'))) 'merge: -PlanPath is no longer accepted'

    $conflictRepo = New-Repo 'different-tree-repo'
    New-Skill -Path (Join-Path $conflictRepo 'imports/skills-inbox/a/claude/different-tree') -Body '## Steps`n`n- First variant.`n'
    New-Skill -Path (Join-Path $conflictRepo 'imports/skills-inbox/b/codex/different-tree') -Body '## Steps`n`n- Second variant.`n'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $conflictRepo, '-DryRun')
    $conflictReport = Get-JsonReport -Path (Get-MergeReportPath $conflictRepo)
    $differentDecision = @($conflictReport.decisions | Where-Object name -eq 'different-tree')[0]
    Assert ($r.Code -eq 0 -and $differentDecision.status -eq 'CONFLICT' -and $conflictReport.conflict_group_count -gt 0) 'merge: same-name different tree is a conflict'
    Assert (@($differentDecision.non_adopted_candidates).Count -eq 2 -and @($conflictReport.promoted).Count -eq 0) 'merge: conflict retains both non-adopted candidates and promotes nothing'

    $extraRepo = New-Repo 'extra-files-repo'
    $sameMd = "---`nname: same-entry`ndescription: Same entry.`n---`n`n## Steps`n`n- Same entry.`n"
    New-Skill -Path (Join-Path $extraRepo 'imports/skills-inbox/a/claude/same-entry') -Body '## Steps`n`n- Same entry.`n' -Files @{ 'references/a.md' = 'A' }
    New-Skill -Path (Join-Path $extraRepo 'imports/skills-inbox/b/codex/same-entry') -Body '## Steps`n`n- Same entry.`n' -Files @{ 'references/b.md' = 'B' }
    Set-File -Path (Join-Path $extraRepo 'imports/skills-inbox/a/claude/same-entry/SKILL.md') -Content $sameMd
    Set-File -Path (Join-Path $extraRepo 'imports/skills-inbox/b/codex/same-entry/SKILL.md') -Content $sameMd
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $extraRepo, '-DryRun')
    $extraReport = Get-JsonReport -Path (Get-MergeReportPath $extraRepo)
    Assert (@($extraReport.decisions | Where-Object { $_.name -eq 'same-entry' -and $_.status -eq 'CONFLICT' }).Count -eq 1) 'merge: same SKILL.md with extra files is not silently combined'

    $canonicalRepo = New-Repo 'canonical-repo'
    New-Skill -Path (Join-Path $canonicalRepo 'skills-source/shared/retained-skill') -Body '## Steps`n`n- Canonical content.`n'
    New-Skill -Path (Join-Path $canonicalRepo 'imports/skills-inbox/machine/claude/retained-skill') -Body '## Steps`n`n- Candidate content.`n'
    New-Skill -Path (Join-Path $canonicalRepo 'imports/skills-inbox/machine/codex/retained-skill') -Body '## Steps`n`n- Canonical content.`n'
    $canonicalBefore = Get-FileHash -LiteralPath (Join-Path $canonicalRepo 'skills-source/shared/retained-skill/SKILL.md')
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $canonicalRepo, '-DryRun')
    $canonicalReport = Get-JsonReport -Path (Get-MergeReportPath $canonicalRepo)
    $retained = @($canonicalReport.decisions | Where-Object name -eq 'retained-skill')[0]
    $canonicalAfter = Get-FileHash -LiteralPath (Join-Path $canonicalRepo 'skills-source/shared/retained-skill/SKILL.md')
    Assert ($r.Code -eq 0 -and $retained.status -eq 'CANONICAL_RETAINED' -and $canonicalReport.exact_duplicate_count -eq 1 -and $canonicalBefore.Hash -eq $canonicalAfter.Hash) 'merge: existing canonical is retained and exact duplicate is accounted for'

    $unsafeCanonicalRepo = New-Repo 'unsafe-canonical-repo'
    $unsafeToken = 'sk-' + 'ant-' + ('U' * 24)
    New-Skill -Path (Join-Path $unsafeCanonicalRepo 'skills-source/shared/unsafe-canonical') -Body ("## Steps`n`n- token: `"$unsafeToken`"`n")
    New-Skill -Path (Join-Path $unsafeCanonicalRepo 'imports/skills-inbox/machine/claude/unsafe-canonical') -Body '## Steps`n`n- Safe candidate.`n'
    New-Skill -Path (Join-Path $unsafeCanonicalRepo 'imports/skills-inbox/machine/claude/clean-extra') -Body '## Steps`n`n- Clean candidate.`n'
    $unsafeBefore = Get-SourceHash -Repo $unsafeCanonicalRepo
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $unsafeCanonicalRepo, '-DryRun')
    $unsafeReport = Get-JsonReport -Path (Get-MergeReportPath $unsafeCanonicalRepo)
    $unsafeDecision = @($unsafeReport.decisions | Where-Object name -eq 'unsafe-canonical')[0]
    Assert ($r.Code -ne 0 -and $unsafeDecision.status -eq 'QUARANTINED' -and @($unsafeReport.blocked_by_existing_canonical_risk) -contains 'unsafe-canonical' -and $r.Out -match 'blocked:') 'merge: risky existing canonical is quarantined and blocks the run'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $unsafeCanonicalRepo, '-Apply')
    $unsafeApplyReport = Get-JsonReport -Path (Get-MergeReportPath $unsafeCanonicalRepo)
    Assert ($r.Code -ne 0 -and (Get-SourceHash -Repo $unsafeCanonicalRepo) -ceq $unsafeBefore -and @($unsafeApplyReport.promoted | Where-Object status -eq 'BLOCKED').Count -eq 1) 'merge: Apply with a risky existing canonical writes nothing, not even unrelated candidates'
    Assert ((Get-Content -Raw -LiteralPath (Get-MergeReportPath $unsafeCanonicalRepo)) -notmatch [regex]::Escape($unsafeToken)) 'merge: risky canonical value is absent from the report'

    $platformRepo = New-Repo 'platform-conflict-repo'
    New-Skill -Path (Join-Path $platformRepo 'imports/skills-inbox/machine/claude/platform-skill') -Body "---`nname: platform-skill`ndescription: Claude candidate.`nallowed-tools: Read`n---`n`n## Steps`n`n- Claude.`n"
    New-Skill -Path (Join-Path $platformRepo 'imports/skills-inbox/machine/codex/platform-skill') -Files @{ 'agents/openai.yaml' = 'name: test' }
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $platformRepo, '-DryRun')
    $platformReport = Get-JsonReport -Path (Get-MergeReportPath $platformRepo)
    $platformDecision = @($platformReport.decisions | Where-Object name -eq 'platform-skill')[0]
    Assert ($r.Code -eq 0 -and $platformDecision.status -eq 'QUARANTINED' -and ($platformReport.conflict_groups[0].reason_codes -contains 'platform-conflict')) 'merge: Claude/Codex platform conflict is quarantined'

    $secretRepo = New-Repo 'secret-repo'
    $fakeToken = 'sk-' + 'ant-' + ('F' * 24)
    New-Skill -Path (Join-Path $secretRepo 'imports/skills-inbox/machine/claude/secret-skill') -Body ("## Steps`n`n- token: `"$fakeToken`"`n")
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $secretRepo, '-DryRun')
    $secretReportPath = Get-MergeReportPath $secretRepo
    $secretReport = Get-JsonReport -Path $secretReportPath
    $secretDecision = @($secretReport.decisions | Where-Object name -eq 'secret-skill')[0]
    $secretReportText = Get-Content -Raw -LiteralPath $secretReportPath
    Assert ($r.Code -eq 0 -and $secretDecision.status -eq 'QUARANTINED' -and ($secretReport.quarantined[0].reason_codes -contains 'possible-secret')) 'merge: secret finding is quarantined with a reason code'
    Assert ($secretReportText -notmatch [regex]::Escape($fakeToken) -and $r.Out -notmatch [regex]::Escape($fakeToken)) 'merge: secret value is absent from the report and output'

    Write-Host "`n[merge apply]" -ForegroundColor Cyan
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $exactRepo, '-Apply')
    $applyReport = Get-JsonReport -Path (Get-MergeReportPath $exactRepo)
    $applyPromoted = @($applyReport.promoted)[0]
    Assert ($r.Code -eq 0 -and $applyReport.mode -eq 'apply' -and $applyPromoted.status -eq 'WRITTEN' -and (Test-Path -LiteralPath (Join-Path $exactRepo "$($applyPromoted.target)/SKILL.md"))) 'merge: Apply copies the promote candidate into skills-source'
    Assert ($applyReport.build_skills_result -eq 'PASS' -and $applyReport.scan_secrets_result -eq 'PASS' -and (Test-Path -LiteralPath (Join-Path $exactRepo 'claude/skills/exact-skill/SKILL.md'))) 'merge: Apply runs build-skills and scan-secrets afterwards'
    $exactAfterApply = Get-SourceHash -Repo $exactRepo
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $exactRepo, '-Apply')
    $reapplyReport = Get-JsonReport -Path (Get-MergeReportPath $exactRepo)
    Assert ($r.Code -eq 0 -and @($reapplyReport.promoted).Count -eq 0 -and (Get-SourceHash -Repo $exactRepo) -ceq $exactAfterApply) 'merge: a second Apply retains the promoted skill and changes nothing'

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

    Write-Host "`n[candidate set atomicity]" -ForegroundColor Cyan
    $batchRepo = New-Repo 'batch-atomic-repo'
    $firstInput = Join-Path $work 'batch-first'; $secondInput = Join-Path $work 'batch-second'
    New-Skill -Path $firstInput -Name 'batch-first'
    Set-File -Path (Join-Path $secondInput 'README.txt') -Content 'intentionally lacks SKILL.md'
    $batchBefore = Get-SourceHash -Repo $batchRepo
    $batchWorkspace = New-SkillCandidateWorkspace -RepoRoot $batchRepo
    $batch = New-SkillCandidateSet -RepoRoot $batchRepo -Workspace $batchWorkspace -Proposals @(
        [pscustomobject]@{ InputSkillPath = $firstInput; TargetType = 'shared' },
        [pscustomobject]@{ InputSkillPath = $secondInput; TargetType = 'shared' }
    )
    Assert ([string]$batch.Status -ceq 'quarantine' -and [string]$batch.Reason -ceq 'missing-skill-md' -and [int]$batch.FailedIndex -eq 1 -and @($batch.Results).Count -eq 1) 'candidates: a later rejection is reported with its index after the first candidate succeeds'
    Assert ($batchWorkspace -like '*tmp*skill-candidates*' -and (Get-SourceHash -Repo $batchRepo) -ceq $batchBefore) 'candidates: building candidates leaves skills-source byte-identical'

    Write-Host "`n[normalize script]" -ForegroundColor Cyan
    $normRepo = New-Repo 'normalize-script-repo'
    $normInput = Join-Path $work 'inputs/norm-skill'
    $privatePath = 'C:\Users\' + 'example-user\notes'
    New-Skill -Path $normInput -Body ("## Steps`n`n- Read $privatePath first.`n")
    $normTarget = Join-Path $normRepo 'skills-source/shared/norm-skill'
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot', $normRepo, '-InputSkillPath', $normInput, '-TargetType', 'shared')
    Assert ($r.Code -eq 0 -and $r.Out -match 'create skills-source/shared/norm-skill' -and $r.Out -match 'rewrite: SKILL\.md' -and -not (Test-Path -LiteralPath $normTarget)) 'normalize: default dry run prints the create and rewrites without writing skills-source'
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot', $normRepo, '-InputSkillPath', $normInput, '-TargetType', 'shared', '-Apply')
    $normText = if (Test-Path -LiteralPath (Join-Path $normTarget 'SKILL.md')) { Get-Content -Raw -LiteralPath (Join-Path $normTarget 'SKILL.md') } else { '' }
    Assert ($r.Code -eq 0 -and $normText -match '\$HOME' -and $normText -notmatch 'example-user' -and $r.Out -match 'build-skills\.ps1: PASS' -and $r.Out -match 'scan-secrets\.ps1: PASS') 'normalize: Apply writes the normalized skill and passes build and scan'

    New-Skill -Path $normInput -Body "## Steps`n`n- Updated workflow.`n" -Files @{ 'extra.md' = 'extra' }
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot', $normRepo, '-InputSkillPath', $normInput, '-TargetType', 'shared', '-Apply')
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $normRepo 'tmp/skill-candidates') -Directory | ForEach-Object { Join-Path $_.FullName 'backup/shared/norm-skill' } | Where-Object { Test-Path -LiteralPath $_ })
    Assert ($r.Code -eq 0 -and $r.Out -match 'replace skills-source/shared/norm-skill' -and (Test-Path -LiteralPath (Join-Path $normTarget 'extra.md')) -and (Get-Content -Raw -LiteralPath (Join-Path $normTarget 'SKILL.md')) -match 'Updated workflow') 'normalize: Apply updates an existing skill of the same type'
    Assert ($backups.Count -eq 1 -and (Get-Content -Raw -LiteralPath (Join-Path $backups[0] 'SKILL.md')) -match '\$HOME' -and -not (Test-Path -LiteralPath (Join-Path $backups[0] 'extra.md'))) 'normalize: the replaced skill is kept as a backup under tmp/skill-candidates'

    $otherClassBefore = Get-SourceHash -Repo $normRepo
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot', $normRepo, '-InputSkillPath', $normInput, '-TargetType', 'codex-only', '-Apply')
    Assert ($r.Code -eq 2 -and $r.Out -match 'canonical-class-conflict' -and (Get-SourceHash -Repo $normRepo) -ceq $otherClassBefore) 'normalize: a name under another type is rejected and nothing is written'
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot', $normRepo, '-InputSkillPath', $normInput, '-TargetType', 'shared', '-DryRun', '-Apply')
    Assert ($r.Code -ne 0 -and (Get-SourceHash -Repo $normRepo) -ceq $otherClassBefore) 'normalize: -DryRun with -Apply is refused'
    $legacyOutput = Join-Path $normRepo 'skills-source/shared/arbitrary-output'
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot', $normRepo, '-InputSkillPath', $normInput, '-TargetType', 'shared', '-DryRun', '-OutputSkillPath', $legacyOutput)
    Assert ($r.Code -ne 0 -and -not (Test-Path -LiteralPath $legacyOutput)) 'normalize: arbitrary OutputSkillPath is not accepted'

    Write-Host "`n[promote script]" -ForegroundColor Cyan
    $promoteRepo = New-Repo 'promote-script-repo'
    $promoteInput = Join-Path $work 'inputs/promote-input'; New-Skill -Path $promoteInput -Name 'promote-input'
    $promoteTarget = Join-Path $promoteRepo 'skills-source/claude-only/promote-input'
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot', $promoteRepo, '-InputSkillPath', $promoteInput, '-TargetType', 'claude-only', '-DryRun')
    Assert ($r.Code -eq 0 -and $r.Out -match 'create skills-source/claude-only/promote-input' -and $r.Out -match 'file: SKILL\.md' -and -not (Test-Path -LiteralPath $promoteTarget)) 'promote: dry run prints the target and files without writing'
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot', $promoteRepo, '-InputSkillPath', $promoteInput, '-TargetType', 'claude-only', '-Apply')
    Assert ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $promoteTarget 'SKILL.md')) -and (Test-Path -LiteralPath (Join-Path $promoteRepo 'claude/skills/promote-input/SKILL.md'))) 'promote: Apply creates the skill and rebuilds generated output'
    $promoteBefore = Get-SourceHash -Repo $promoteRepo
    New-Skill -Path $promoteInput -Name 'promote-input' -Body "## Steps`n`n- Different content.`n"
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot', $promoteRepo, '-InputSkillPath', $promoteInput, '-TargetType', 'shared', '-Apply')
    Assert ($r.Code -eq 3 -and $r.Out -match 'retained:' -and (Get-SourceHash -Repo $promoteRepo) -ceq $promoteBefore) 'promote: an existing skill under any type is retained and never replaced'
    $promoteSecret = Join-Path $work 'inputs/promote-secret'
    New-Skill -Path $promoteSecret -Body ("## Steps`n`n- value: `"$normalizeToken`"`n")
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot', $promoteRepo, '-InputSkillPath', $promoteSecret, '-TargetType', 'shared', '-Apply')
    Assert ($r.Code -eq 2 -and $r.Out -match 'possible-secret' -and $r.Out -notmatch [regex]::Escape($normalizeToken) -and (Get-SourceHash -Repo $promoteRepo) -ceq $promoteBefore) 'promote: a secret-shaped input is rejected without writing or echoing the value'
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot', $promoteRepo, '-InputSkillPath', $promoteSecret, '-TargetType', 'shared', '-DryRun', '-PlanPath', (Join-Path $work 'promote-plan.json'))
    Assert ($r.Code -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $work 'promote-plan.json'))) 'promote: -PlanPath is no longer accepted'

    Write-Host "`n[reparse points]" -ForegroundColor Cyan
    $reparseRepo = New-Repo 'reparse-repo'
    $linkTargetDir = Join-Path $work 'junction-target'
    New-Item -ItemType Directory -Force -Path $linkTargetDir | Out-Null
    Set-File -Path (Join-Path $linkTargetDir 'outside.txt') -Content 'outside the skill'
    $junctionInput = Join-Path $work 'inputs/junction-input'
    New-Skill -Path $junctionInput
    New-Item -ItemType Junction -Path (Join-Path $junctionInput 'linked') -Target $linkTargetDir | Out-Null
    $reparseBefore = Get-SourceHash -Repo $reparseRepo
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot', $reparseRepo, '-InputSkillPath', $junctionInput, '-TargetType', 'shared', '-Apply')
    Assert ($r.Code -eq 2 -and $r.Out -match 'unsafe-tree' -and (Get-SourceHash -Repo $reparseRepo) -ceq $reparseBefore) 'reparse: an input tree containing a junction is refused'

    $plainInput = Join-Path $work 'inputs/plain-input'
    New-Skill -Path $plainInput
    $junctionType = Join-Path $reparseRepo 'skills-source/codex-only'
    [IO.Directory]::Delete($junctionType)
    $junctionTypeTarget = Join-Path $work 'junction-type-target'
    New-Item -ItemType Directory -Force -Path $junctionTypeTarget | Out-Null
    New-Item -ItemType Junction -Path $junctionType -Target $junctionTypeTarget | Out-Null
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot', $reparseRepo, '-InputSkillPath', $plainInput, '-TargetType', 'codex-only', '-Apply')
    Assert ($r.Code -eq 1 -and $r.Out -match 'reparse point' -and @(Get-ChildItem -LiteralPath $junctionTypeTarget -Force).Count -eq 0) 'reparse: a target path through a junction is refused and nothing is written behind it'

    Write-Host "`n[engine independence]" -ForegroundColor Cyan
    $toolText = (@($normalizeScript, $promoteScript, $mergeScript, $candidateCommon) | ForEach-Object { Get-Content -Raw -LiteralPath $_ }) -join "`n"
    Assert ($toolText -notmatch 'canonical-[a-z-]+\.ps1|json-artifact-common|scan-input-common|safe-tree-walker|semantic-json|live-[a-z-]+\.ps1|home-authority|approved-runner|PlanPath|Resolve-PrivateArtifactPath') 'skills tools load no transaction engine helper and take no plan file'
}
catch {
    $script:fail++
    Write-Host "  FAIL  unhandled test error: $($_.Exception.Message) $($_.ScriptStackTrace)" -ForegroundColor Red
}
finally {
    Write-Host ''
    Write-Host ("Results: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
    if ($script:fail -eq 0) { Remove-Work }
}

if ($script:fail -ne 0) {
    Write-Host "Workspace kept for inspection: $work" -ForegroundColor Yellow
    exit 1
}
exit 0
