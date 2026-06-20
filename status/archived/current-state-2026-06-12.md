# Current State Snapshot — 2026-06-12

Single source-of-truth snapshot of the `ai-agent-dotfiles` project after Phase 3 office deployment and finalization. Supersedes the scattered status reports for "what is true right now."

- **Machine:** `DESKTOP-3GMDAB7` (office desktop)
- **Repo:** `C:\Repos\ai-agent-dotfiles`
- **Branch:** `main`, in sync with `origin/main`
- **PowerShell:** 7.6.2 (pwsh)

---

## 1. Repository state

| Item | State |
|---|---|
| Latest deployment hotfix | `e6a2d90 fix: sanitize security best practices example` |
| Latest rule/docs commit | `49e51db docs: record office deployment and codex system skill rule` |
| `build-skills.ps1` | ✅ Claude 12 / Codex 18, exit 0 (Codex 17→18 after `hatch-pet` promotion, 2026-06-12) |
| `scan-secrets.ps1` | ✅ no leaks / no blocking secrets, exit 0 |
| Working tree | clean except expected ignored paths + untracked docs (see §6) |

Source of truth: `skills-source/` (hand-maintained). `claude/skills/` and `codex/skills/` are
**generated** by `build-skills.ps1` and Git-ignored. `manifests/managed-skills.txt` lists the
23 repo-managed skill names (union of Claude + Codex; 22→23 after `hatch-pet` promotion, 2026-06-12).

---

## 2. Live deployment state (this machine)

| Target | Path | Count | Status |
|---|---|---|---|
| Claude skills | `C:\Users\admin\.claude\skills` | 12 | exact match to repo `claude/skills` |
| Codex managed skills | `C:\Users\admin\.codex\skills` | 17 | exact match to repo `codex/skills` |
| Codex platform dir | `C:\Users\admin\.codex\skills\.system` | — | preserved (Codex built-ins) |

`~/.codex/skills` therefore holds **17 managed + `.system`**. `.system` carries
`.codex-system-skills.marker` and Codex built-ins (`imagegen`, `openai-docs`, `plugin-creator`,
`skill-creator`, `skill-installer`).

> **Deployment is complete and verified. Do not redeploy and do not `robocopy /MIR` to live dirs.**

---

## 3. Governing rules (formalized)

1. Claude live skills must exactly match repo `claude/skills`.
2. Codex live **repo-managed** skills must exactly match repo `codex/skills`.
3. `~/.codex/skills/.system` is **not** a repo-managed skill and **must always be preserved** during
   any sync / prune / cleanup. Never delete it as if it were a stale import.
4. Sync/prune must be **manifest-scoped** (`manifests/managed-skills.txt`). **Never** run a bare
   `robocopy /MIR` (or whole-dir mirror) against `~/.codex/skills`.

Recorded in: `README.md` (Deployment Targets), `ai-agent-dotfiles-sync-plan-v2.md` (§7.5),
`scripts/sync.ps1` (TODO), `phase-3-office-deploy-status-2026-06-12.md`.

---

## 4. Backup

- **Location (outside repo, never in Git):**
  `C:\Users\admin\.ai-agent-dotfiles-backups\phase-3-office-20260612-112727`
- Contains pre-deploy `~/.codex/skills` (all 8 original entries incl. `.system`) and a
  `claude-skills.MISSING.txt` marker (Claude skills dir did not exist pre-deploy).
- The 6 user skills removed by the mirror are recoverable here:
  `brainstorming`, `codex-primary-runtime`, `subagent-driven-development`,
  `systematic-debugging`, `writing-plans`, `writing-skills`.
- Restore procedure: see [`restore.md`](restore.md).

---

## 5. Known discrepancy — Codex skills path

The design plan (`ai-agent-dotfiles-sync-plan-v2.md`) repeatedly states Codex user skills live at
`$HOME/.agents/skills`. On this machine that path **does not exist**; the live skills (and `.system`)
are in `~/.codex/skills`, which is where Phase 3 deployed.

- A correction note has been added to the plan (after the first `.agents/skills` claim).
- **Done in `sync.ps1`/`backup.ps1`:** both probe `~/.codex/skills` first, then `~/.agents/skills`,
  and otherwise default to `~/.codex/skills` (created only on `-Apply`); they never assume
  `~/.agents/skills` exists.

---

## 6. Pending / open items

| Item | Status |
|---|---|
| `scripts/sync.ps1` / `backup.ps1` | **implemented** (Q5) — manifest-scoped, dry-run by default, `.system` preserved. See §8 Q5. |
| `docs/phase-2-6-post-push-status-2026-06-12.md` | resolved — committed as `205a937` (via GitHub) and now tracked. |
| Status-doc sprawl | ~10 docs under `docs/` with overlapping status reports; see Q4 in §8. |
| 6 removed Codex user skills | live-removed, backup-preserved; **not** auto-reimported. To repo-manage: fresh inbox + Phase 2.6 merge. |

---

## 7. Standard verification commands

```powershell
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
git status --short --ignored

# live vs repo (Codex, excluding .system)
$repo = Get-ChildItem "C:\Repos\ai-agent-dotfiles\codex\skills" -Directory | Select -Expand Name | Sort-Object
$live = Get-ChildItem "$env:USERPROFILE\.codex\skills" -Directory -Force |
        Where-Object Name -ne '.system' | Select -Expand Name | Sort-Object
if (Compare-Object $repo $live) { 'MISMATCH' } else { 'OK' }
```

---

## 8. Quality findings (audit 2026-06-12)

Findings from the review pass. Q1–Q3 were fixed on 2026-06-12 (build-output hygiene cleanup).
None were security or correctness blockers.

| # | Status | Finding | Resolution |
|---|---|---|---|
| Q1 | ✅ Resolved | **Bookkeeping files shipped to runtime.** `build-skills.ps1` did a blind recursive copy of each skill dir, so repo-internal provenance files — `MERGE_NOTES.md` (every merged skill) and `CREATION-LOG.md` (`systematic-debugging`) — were copied into `claude/skills/` + `codex/skills/` and deployed into the live dirs. | `build-skills.ps1` now strips `MERGE_NOTES.md`, `CREATION-LOG.md`, and `*.magina-laptop.*` from the generated copy (`$script:RuntimeExcludePatterns`). The provenance files remain in `skills-source/` only. Verified absent from generated output. |
| Q2 | ✅ Resolved | **Redundant identical agent yaml.** `skills-source/codex-only/google-drive-comments/agents/openai.magina-laptop.yaml` was **byte-identical** to `openai.yaml` (leftover from the magina-laptop merge of a `-copy-1` duplicate). | Deleted from source; the skill's `MERGE_NOTES.md` updated to note the removal (rest of provenance kept). |
| Q3 | ✅ Resolved | **Source↔live drift after the fix.** With redeploy disallowed, the Q1/Q2 fixes left stale internal files in the live dirs. | Removed via **targeted file delete** (31 files: 30 `MERGE_NOTES.md`/`CREATION-LOG.md` + 1 stray yaml) — no `robocopy /MIR`, `.system` untouched. Live now has file-level parity with generated output (Codex 59 files, Claude 30 files, excluding `.system`). |
| Q4 | Info | **Status-doc sprawl.** ~10 docs under `docs/`, several overlapping status reports. | Optional future consolidation; kept as-is to preserve per-phase provenance. This snapshot is the canonical "current state." |
| Q5 | ✅ Resolved | **Sync/backup scripts were placeholders.** `scripts/sync.ps1` and `backup.ps1` used to `throw`. | Implemented real scripts (2026-06-12). `backup.ps1`: timestamped full backup of live Claude/Codex skills (incl. `.system`) outside the repo + `backup-manifest.json`; supports `-BackupRoot`/`-DryRun`. `sync.ps1`: **dry-run by default**, `-Apply` required to mutate; runs build + secret scan first; `-Apply` always takes a backup first; **manifest-scoped** (`managed-skills.txt`); operates **one skill dir at a time** (no `robocopy /MIR`); prune only removes repo-managed dirs absent from output; unknown live dirs reported, never deleted; Codex `.system` always preserved; Codex path probes `~/.codex/skills` → `~/.agents/skills`. **This round: implemented + dry-run verified only; no live-changing `-Apply` was run** (live already matches output). |

---

## 9. Conclusion

Phase 3 office deployment is successful and fully documented; the repo is clean and in sync with
origin; the `.system` preservation rule is formalized across README, plan, and the sync script; a
verified backup and restore guide exist. Build-output hygiene (Q1–Q3) is fixed, and the real
manifest-scoped sync/backup scripts (Q5) are now implemented (`sync.ps1` dry-run by default,
`-Apply` takes a backup first and never mirrors or touches `.system`). All audit findings Q1–Q5 are
resolved; the remaining items are informational (Q4 doc sprawl). Nothing blocks current operation.

---

## 10. MAGINA-LAPTOP sync + `hatch-pet` promotion (2026-06-12)

Work performed on the **`MAGINA-LAPTOP`** machine (live Codex path `~/.codex/skills`):

- **Repo synced to latest:** fast-forwarded to `c934922 feat: implement manifest-scoped skill sync and backup` and ran the manifest-scoped `sync.ps1 -Apply` (backup-first, `.system` preserved, no `robocopy /MIR`).
- **Empty unknown dir removed:** `codex-primary-runtime` (a 0-file shell, residue of an old Codex user skill) was deleted from live only — confirmed empty first; not a repo change.
- **`hatch-pet` promoted to repo management** as a **codex-only** skill:
  - Two divergent variants existed. The promoted **canonical source** is the 21-file variant
    (`imports/skills-inbox/magina-laptop/codex/hatch-pet`, byte-identical to MAGINA-LAPTOP live).
    The divergent 14-file variant (`hatch-pet-copy-1` / quarantine `platform-conflict` copy) was
    **not** promoted.
  - Classified codex-only because it depends on the Codex `.system/imagegen` platform skill and
    packages pets under `${CODEX_HOME:-$HOME/.codex}/pets/`. Lives in `claude/skills`? **No** —
    Codex only.
  - Security audit: no hard-coded secrets / machine paths / accounts; API credentials read from
    env vars at runtime. Provenance recorded in `skills-source/codex-only/hatch-pet/MERGE_NOTES.md`.
- **Counts after promotion:** Claude **12** (unchanged), Codex **17 → 18**, manifest **22 → 23**.
- **Live state:** `codex/skills/hatch-pet` present, `claude/skills/hatch-pet` absent;
  live unknown Codex dirs = **0**; `.system` marker = **True**; no stale bookkeeping files in live
  managed dirs. `build-skills.ps1` and `scan-secrets.ps1` both pass.
- **Backup (MAGINA-LAPTOP, outside repo):**
  `C:\Users\Magina\.ai-agent-dotfiles-backups\sync-backup-20260612-154909`.

**Q4 status-doc sprawl remains unaddressed** (intentionally not cleaned up this round).
