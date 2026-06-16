# OpenClaw Skills Sync — Design Spec

Date: 2026-06-16 | Status: draft | Author: Magic (OpenClaw)

---

## 1. Goal

Add OpenClaw as a third managed skill target in the `ai-agent-dotfiles` repo, alongside Claude and Codex. Once implemented, running `sync.ps1 -Apply` will deploy repo-managed skills to `~/.openclaw/workspace/skills/` with the same safety guarantees already in place for Claude and Codex.

---

## 2. Scope

### 2.1 Primary (must-have)

- `build-skills.ps1` generates `openclaw/skills/` from `skills-source/shared/` + `skills-source/openclaw-only/`.
- `sync.ps1` deploys to and prunes the live OpenClaw skills directory.
- All existing safety rules apply: dry-run default, mandatory backup before apply, secret scan gate, manifest-scoped operations only.
- `.clawhub` directories (OpenClaw platform metadata) are preserved during sync — like `.system` for Codex.
- `openclaw/skills/` is Git-ignored (generated output, never committed).

### 2.2 Secondary (should-have)

- All 13 OpenClaw-native skills currently in the workspace are reverse-imported into `skills-source/openclaw-only/` so they become repo-managed. That list:
  - `matlab`, `matlab-bridge`
  - `word-docx`
  - `powerpoint-pptx-cn`, `powerpoint-generator`
  - `dispatching-parallel-agents`, `executing-plans`, `finishing-a-development-branch`
  - `test-driven-development`, `using-git-worktrees`
  - `receiving-code-review`, `requesting-code-review`
  - `using-superpowers`
- Each import includes `SKILL.md` + all support files (agents/, references/, scripts/, examples/).
- `.clawhub` metadata is included in the source — harmless on non-OpenClaw targets and useful for restoring OpenClaw state.

### 2.3 Out of scope

- OpenClaw-specific skill authoring workflow (skill_workshop integration) — this spec only covers repo-side sync.
- Plugin management.

---

## 3. Directory Layout

```
ai-agent-dotfiles/
├── skills-source/
│   ├── shared/            # Cross-platform (unchanged)
│   ├── claude-only/       # Claude-only (unchanged)
│   ├── codex-only/        # Codex-only (unchanged)
│   └── openclaw-only/     # ★ NEW: OpenClaw-native skills
│       ├── .gitkeep        # (directory may be empty if all skills are shared)
│       ├── matlab/
│       ├── matlab-bridge/
│       ├── word-docx/
│       └── ...             # 13 skills imported from workspace
├── openclaw/
│   └── skills/            # ★ NEW: generated runtime output (Git-ignored)
├── claude/skills/         # unchanged
├── codex/skills/          # unchanged
├── scripts/
│   ├── build-skills.ps1   # MODIFIED: add openclaw target
│   ├── sync.ps1           # MODIFIED: add openclaw deploy
│   └── ...
├── manifests/
│   └── managed-skills.txt # auto-refreshed by build (includes openclaw skills)
└── .gitignore             # MODIFIED: add openclaw/skills/
```

**Build output per target:**

| Target | Sources | Count after import |
|---|---|---|
| `claude/skills/` | shared + claude-only | ~15 |
| `codex/skills/` | shared + codex-only | ~21 |
| `openclaw/skills/` | shared + openclaw-only | ~24 (11 shared + 13 openclaw-only) |

---

## 4. Changes to build-skills.ps1

### 4.1 New openclaw target

After the existing Claude and Codex build logic, add:

```powershell
$openclawOnlySource = Join-RepoPath 'skills-source/openclaw-only'
$openclawTarget = Join-RepoPath 'openclaw/skills'

$openclawOnlySkills = Get-SkillDirectories -Path $openclawOnlySource

# Conflict check: openclaw-only vs shared (same as existing claude/codex logic)
$openclawConflicts = @($openclawOnlySkills | Where-Object { $_.Name -in $sharedNames } | ForEach-Object Name)
if ($openclawConflicts.Count -gt 0) {
    Write-Host 'ERROR: Skill name conflict between shared and openclaw-only sources.'
    $openclawConflicts | ForEach-Object { Write-Host "Conflict: $_" }
    exit 1
}

# Build openclaw target
foreach ($target in @($openclawTarget)) {
    Assert-UnderRepo -Path $target
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
}

foreach ($skill in $sharedSkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $openclawTarget
}
foreach ($skill in $openclawOnlySkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $openclawTarget
}
```

### 4.2 Manifest update

The managed-skills.txt generation already unions all names — it will automatically pick up `openclawOnlySkills`. No code change needed for that part.

### 4.3 Output

Add to the summary output:
```
Write-Host "Built OpenClaw skills: $($builtOpenclawSkills.Count)"
```

### 4.4 Runtime exclusion patterns

Existing `MERGE_NOTES.md`, `CREATION-LOG.md`, `*.magina-laptop.*` exclusions apply to openclaw target automatically (they run inside `Copy-SkillDirectory`). No change needed.

---

## 5. Changes to sync.ps1

### 5.1 Live path resolution

Add:

```powershell
function Get-OpenClawLiveSkillsPath {
    return (Join-Path $env:USERPROFILE '.openclaw\workspace\skills')
}
```

### 5.2 Protected directories

Extend `$CodexSystemDirName = '.system'` concept:

```powershell
$OpenClawPlatformDirNames = @('.clawhub')  # OpenClaw platform metadata
```

These directories inside any skill directory should never be deleted during prune. When syncing a skill, if the live copy has `.clawhub` but the source doesn't (e.g., source imported before `.clawhub` was added), the sync should merge rather than replace.

**Implementation approach:** After copying source to live, if `.clawhub` existed in the old live copy, restore it from backup. (Backup is always taken before apply.)

### 5.3 Sync plan

Add an OpenClaw plan alongside Claude and Codex:

```powershell
$openclawSource = Join-Path $RepoRoot 'openclaw\skills'
$openclawLive = Get-OpenClawLiveSkillsPath
$openclawPlan = Get-SyncPlan -Platform 'openclaw' -SourceRoot $openclawSource -LiveRoot $openclawLive -ManagedNames $managedNames
```

### 5.4 Plan report

Extend `Get-SyncPlan` to report `.clawhub` directories found:

```
Write-Host "  .clawhub dirs   : $clawhubCount (present -> PRESERVED)"
```

### 5.5 Apply logic

During apply, for each skill that gets updated:
1. Before removing old live copy, enumerate any `.clawhub` dirs inside it.
2. After copying new source content, restore the preserved `.clawhub` dirs.
3. For newly added skills (not previously in live), no `.clawhub` to preserve.

Pseudocode:

```powershell
function Sync-OneSkillDir-WithClawhubPreservation {
    param($SourceSkillDir, $LiveRoot, $Name)
    $dest = Join-Path $LiveRoot $Name
    # Snapshot .clawhub dirs before deletion
    $clawhubBackup = @()
    if (Test-Path -LiteralPath $dest) {
        Get-ChildItem -LiteralPath $dest -Recurse -Directory -Filter '.clawhub' -Force |
            ForEach-Object { $clawhubBackup += $_ }
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $LiveRoot | Out-Null
    Copy-Item -LiteralPath $SourceSkillDir -Destination $dest -Recurse
    # Restore .clawhub dirs if the source didn't include them
    foreach ($backup in $clawhubBackup) {
        $relativePath = $backup.FullName.Substring($dest.Length + 1)
        $restorePath = Join-Path $dest $relativePath
        if (-not (Test-Path -LiteralPath $restorePath)) {
            Copy-Item -LiteralPath $backup.FullName -Destination $restorePath -Recurse
        }
    }
}
```

Note: If `.clawhub` contents are included in the source (as they would be after reverse-import), this preservation is a no-op — but it acts as a safety net.

### 5.6 `.clawhub` handling during prune

When pruning a stale managed skill, `.clawhub` dirs are deleted along with the skill. This is intentional — if the skill was removed from the manifest, it's truly removed. Manual restore from backup is available if needed.

---

## 6. Reverse Import: Workspace → Repo

### 6.1 What to import

For each OpenClaw-native skill in `~/.openclaw/workspace/skills/`:

| Skill | Has .clawhub? | Imported? |
|---|---|---|
| matlab | Yes | Yes |
| matlab-bridge | Yes | Yes |
| word-docx | Yes | Yes |
| powerpoint-pptx-cn | Yes | Yes |
| powerpoint-generator | Yes | Yes |
| dispatching-parallel-agents | No | Yes |
| executing-plans | No | Yes |
| finishing-a-development-branch | No | Yes |
| test-driven-development | No | Yes |
| using-git-worktrees | No | Yes |
| receiving-code-review | No | Yes |
| requesting-code-review | No | Yes |
| using-superpowers | No | Yes |

Skills already in `shared/` (brainstorming, writing-plans, etc.) are NOT imported — they come from shared.

### 6.2 Import process

For each skill:
1. Copy `SKILL.md` + all support files to `skills-source/openclaw-only/<name>/`
2. Include `.clawhub/` if present
3. Scan for secrets before commit
4. Run `build-skills.ps1` to validate
5. Run `sync.ps1 -Apply` (confirm no-op: source == live)

### 6.3 Post-import state

After import and first build:
- `openclaw/skills/` contains ~24 skills (11 shared + 13 openclaw-only)
- `managed-skills.txt` lists ~39 skills (pre-existing ~26 + 13 new)
- First sync is effectively a no-op (source == live for all managed skills)

---

## 7. Changes to .gitignore

Add:

```
# Generated runtime output: openclaw skills (built from skills-source)
openclaw/skills/
```

---

## 8. Protection Rules Summary

| Target | Protected | Mechanism |
|---|---|---|
| Codex | `.system/` | Never listed in managed set; skip during plan; never delete |
| OpenClaw | `.clawhub/` in any skill dir | Snapshot before replace, restore after copy; no-op if source already includes it |

---

## 9. Verification Checklist

After implementation, verify:

- [ ] `build-skills.ps1` runs clean and outputs `Built OpenClaw skills: N` (N = shared + openclaw-only)
- [ ] `sync.ps1` (dry-run) reports correct add/update/prune for all three targets
- [ ] `sync.ps1 -Apply` runs without errors
- [ ] Post-apply, `~/.openclaw/workspace/skills/<managed-skill>/.clawhub/` survives intact
- [ ] Non-managed OpenClaw skills (if any remain) are reported as unknown, never deleted
- [ ] `managed-skills.txt` includes all openclaw-only skill names
- [ ] `openclaw/skills/` is not tracked by Git

---

## 10. Out of Scope / Future Work

- Integrating with OpenClaw's `skill_workshop` tool for skill lifecycle management
- Plugin sync
- Auto-sync Git hooks for OpenClaw (the existing hooks already work — they call `sync.ps1 -Apply` which will now include OpenClaw)
