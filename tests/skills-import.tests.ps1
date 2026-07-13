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
    foreach ($relative in @('imports/skills-inbox','imports/skills-reports','skills-source/shared','skills-source/claude-only','skills-source/codex-only','skills-source/openclaw-only')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $repo $relative) | Out-Null
    }
    return $repo
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
    New-Skill -Path (Join-Path $preferredHome '.openclaw/skills/openclaw-skill') -Files @{ '.clawhub/metadata.json' = '{"source":"test"}' }

    $r = Invoke-Script -Script $inventoryScript -Arguments @('-RepoRoot', $inventoryRepo, '-HomeRoot', $preferredHome, '-MachineId', 'test-machine')
    $inventory = Get-JsonReport -Path (Join-Path $inventoryRepo 'imports/skills-reports/test-machine-inventory.json')
    Assert ($r.Code -eq 0) 'inventory: preferred run succeeds'
    Assert ($inventory.codex_selection.selection -eq 'preferred' -and $inventory.codex_selection.selected_path -eq '.codex/skills') 'inventory: Codex prefers .codex/skills'
    Assert (@($inventory.records | Where-Object { $_.normalized_name -eq 'fallback-skill' }).Count -eq 0) 'inventory: fallback is not scanned when preferred exists'
    Assert (@($inventory.records | Where-Object { $_.normalized_name -eq 'system' }).Count -eq 0) 'inventory: Codex .system is excluded'
    $openRecord = @($inventory.records | Where-Object { $_.source_tool -eq 'openclaw' })[0]
    Assert ($null -ne $openRecord -and $openRecord.classification -eq 'openclaw-only') 'inventory: OpenClaw record is auditable and classified'
    Assert ($null -ne $openRecord.scan_status -and $openRecord.modified_time_utc -eq 'not-collected' -and $openRecord.sha256_tree_hash) 'record: scan status, no fabricated mtime, and fingerprints are present'
    Assert ($null -ne $openRecord.platform_signals -and $null -ne $openRecord.possible_binary_findings) 'record: platform and binary/path/secret finding fields are present'

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
    Assert ($r.Code -eq 0 -and $analysis.openclaw_source_skill_count -gt 0) 'analysis: OpenClaw source is included'

    Write-Host "`n[merge decisions]" -ForegroundColor Cyan
    $exactRepo = New-Repo 'exact-repo'
    New-Skill -Path (Join-Path $exactRepo 'imports/skills-inbox/machine/claude/exact-skill')
    New-Skill -Path (Join-Path $exactRepo 'imports/skills-inbox/machine/codex/exact-skill')
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $exactRepo, '-DryRun')
    $exactReport = Get-JsonReport -Path (Join-Path $exactRepo 'imports/skills-reports/auto-merge-report.json')
    Assert ($r.Code -eq 0 -and $exactReport.exact_duplicate_count -eq 1) 'merge: exact duplicate count reports one duplicate copy'
    Assert (@($exactReport.decisions | Where-Object { $_.name -eq 'exact-skill' -and $_.status -eq 'DEDUPLICATED' -and $_.promotion_status -eq 'PROMOTE_CANDIDATE' }).Count -eq 1) 'merge: identical candidates deduplicate and expose an explicit promote candidate'

    $conflictRepo = New-Repo 'different-tree-repo'
    New-Skill -Path (Join-Path $conflictRepo 'imports/skills-inbox/a/claude/different-tree') -Body '## Steps`n`n- First variant.`n'
    New-Skill -Path (Join-Path $conflictRepo 'imports/skills-inbox/b/codex/different-tree') -Body '## Steps`n`n- Second variant.`n'
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $conflictRepo, '-DryRun')
    $conflictReport = Get-JsonReport -Path (Join-Path $conflictRepo 'imports/skills-reports/auto-merge-report.json')
    $differentDecision = @($conflictReport.decisions | Where-Object name -eq 'different-tree')[0]
    Assert ($r.Code -eq 0 -and $differentDecision.status -eq 'CONFLICT' -and $conflictReport.conflict_group_count -gt 0) 'merge: same-name different tree is a conflict'
    Assert (@($differentDecision.non_adopted_candidates).Count -eq 2) 'merge: conflict retains both non-adopted candidates'

    $extraRepo = New-Repo 'extra-files-repo'
    $sameMd = "---`nname: same-entry`ndescription: Same entry.`n---`n`n## Steps`n`n- Same entry.`n"
    New-Skill -Path (Join-Path $extraRepo 'imports/skills-inbox/a/claude/same-entry') -Body '## Steps`n`n- Same entry.`n' -Files @{ 'references/a.md' = 'A' }
    New-Skill -Path (Join-Path $extraRepo 'imports/skills-inbox/b/codex/same-entry') -Body '## Steps`n`n- Same entry.`n' -Files @{ 'references/b.md' = 'B' }
    Set-File -Path (Join-Path $extraRepo 'imports/skills-inbox/a/claude/same-entry/SKILL.md') -Content $sameMd
    Set-File -Path (Join-Path $extraRepo 'imports/skills-inbox/b/codex/same-entry/SKILL.md') -Content $sameMd
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $extraRepo, '-DryRun')
    $extraReport = Get-JsonReport -Path (Join-Path $extraRepo 'imports/skills-reports/auto-merge-report.json')
    Assert (@($extraReport.decisions | Where-Object { $_.name -eq 'same-entry' -and $_.status -eq 'CONFLICT' }).Count -eq 1) 'merge: same SKILL.md with extra files is not silently combined'

    $canonicalRepo = New-Repo 'canonical-repo'
    New-Skill -Path (Join-Path $canonicalRepo 'skills-source/shared/retained-skill') -Body '## Steps`n`n- Canonical content.`n'
    New-Skill -Path (Join-Path $canonicalRepo 'imports/skills-inbox/machine/claude/retained-skill') -Body '## Steps`n`n- Candidate content.`n'
    New-Skill -Path (Join-Path $canonicalRepo 'imports/skills-inbox/machine/codex/retained-skill') -Body '## Steps`n`n- Canonical content.`n'
    $canonicalBefore = Get-FileHash -LiteralPath (Join-Path $canonicalRepo 'skills-source/shared/retained-skill/SKILL.md')
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $canonicalRepo, '-DryRun')
    $canonicalReport = Get-JsonReport -Path (Join-Path $canonicalRepo 'imports/skills-reports/auto-merge-report.json')
    $retained = @($canonicalReport.decisions | Where-Object name -eq 'retained-skill')[0]
    $canonicalAfter = Get-FileHash -LiteralPath (Join-Path $canonicalRepo 'skills-source/shared/retained-skill/SKILL.md')
    Assert ($r.Code -eq 0 -and $retained.status -eq 'CANONICAL_RETAINED' -and $canonicalReport.exact_duplicate_count -eq 1 -and $canonicalBefore.Hash -eq $canonicalAfter.Hash) 'merge: existing canonical is retained and exact duplicate is accounted for'

    $unsafeCanonicalRepo = New-Repo 'unsafe-canonical-repo'
    $unsafeToken = 'sk-' + 'ant-' + ('U' * 24)
    New-Skill -Path (Join-Path $unsafeCanonicalRepo 'skills-source/shared/unsafe-canonical') -Body ("## Steps`n`n- token: `"$unsafeToken`"`n")
    New-Skill -Path (Join-Path $unsafeCanonicalRepo 'imports/skills-inbox/machine/claude/unsafe-canonical') -Body '## Steps`n`n- Safe candidate.`n'
    $unsafeBefore = Get-FileHash -LiteralPath (Join-Path $unsafeCanonicalRepo 'skills-source/shared/unsafe-canonical/SKILL.md')
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $unsafeCanonicalRepo, '-DryRun')
    $unsafeReport = Get-JsonReport -Path (Join-Path $unsafeCanonicalRepo 'imports/skills-reports/auto-merge-report.json')
    $unsafeDecision = @($unsafeReport.decisions | Where-Object name -eq 'unsafe-canonical')[0]
    $unsafeAfter = Get-FileHash -LiteralPath (Join-Path $unsafeCanonicalRepo 'skills-source/shared/unsafe-canonical/SKILL.md')
    Assert ($r.Code -eq 0 -and $unsafeDecision.status -eq 'QUARANTINED' -and $unsafeBefore.Hash -eq $unsafeAfter.Hash) 'merge: risky existing canonical blocks candidate promotion'

    $platformRepo = New-Repo 'platform-conflict-repo'
    New-Skill -Path (Join-Path $platformRepo 'imports/skills-inbox/machine/claude/platform-skill') -Body "---`nname: platform-skill`ndescription: Claude candidate.`nallowed-tools: Read`n---`n`n## Steps`n`n- Claude.`n"
    New-Skill -Path (Join-Path $platformRepo 'imports/skills-inbox/machine/codex/platform-skill') -Files @{ 'agents/openai.yaml' = 'name: test' }
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $platformRepo, '-DryRun')
    $platformReport = Get-JsonReport -Path (Join-Path $platformRepo 'imports/skills-reports/auto-merge-report.json')
    $platformDecision = @($platformReport.decisions | Where-Object name -eq 'platform-skill')[0]
    Assert ($r.Code -eq 0 -and $platformDecision.status -eq 'QUARANTINED' -and ($platformReport.conflict_groups[0].reason_codes -contains 'platform-conflict')) 'merge: Claude/Codex platform conflict is quarantined'

    $secretRepo = New-Repo 'secret-repo'
    $fakeToken = 'sk-' + 'ant-' + ('F' * 24)
    New-Skill -Path (Join-Path $secretRepo 'imports/skills-inbox/machine/claude/secret-skill') -Body ("## Steps`n`n- token: `"$fakeToken`"`n")
    $r = Invoke-Script -Script $mergeScript -Arguments @('-RepoRoot', $secretRepo, '-DryRun')
    $secretReportPath = Join-Path $secretRepo 'imports/skills-reports/auto-merge-report.json'
    $secretReport = Get-JsonReport -Path $secretReportPath
    $secretDecision = @($secretReport.decisions | Where-Object name -eq 'secret-skill')[0]
    $secretReportText = Get-Content -Raw -LiteralPath $secretReportPath
    Assert ($r.Code -eq 0 -and $secretDecision.status -eq 'QUARANTINED' -and ($secretReport.quarantined[0].reason_codes -contains 'possible-secret')) 'merge: secret finding is quarantined with a reason code'
    Assert ($secretReportText -notmatch [regex]::Escape($fakeToken)) 'merge: secret value is absent from the report'

    Write-Host "`n[OpenClaw normalize/promote surface]" -ForegroundColor Cyan
    $openRepo = New-Repo 'openclaw-normalize-repo'
    $openInput = Join-Path $work 'openclaw-input'
    New-Skill -Path $openInput -Body "## Steps`n`n- OpenClaw workflow.`n" -Files @{ '.clawhub/metadata.json' = '{"kind":"skill"}' }
    $openOutput = Join-Path $openRepo 'skills-source/openclaw-only/openclaw-normalized'
    $r = Invoke-Script -Script $normalizeScript -Arguments @('-RepoRoot', $openRepo, '-InputSkillPath', $openInput, '-OutputSkillPath', $openOutput, '-TargetType', 'openclaw-only')
    Assert ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $openOutput 'SKILL.md'))) 'normalize: openclaw-only target is supported'
    $r = Invoke-Script -Script $promoteScript -Arguments @('-RepoRoot', $openRepo, '-InputSkillPath', $openInput, '-TargetType', 'openclaw-only', '-DryRun')
    Assert ($r.Code -eq 0 -and $r.Out -match 'openclaw-only') 'promote: openclaw-only dry-run is supported'
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
    }
}

if ($script:fail -ne 0) {
    Write-Host "Workspace kept for inspection: $work" -ForegroundColor Yellow
    exit 1
}
exit 0
