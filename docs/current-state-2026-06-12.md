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
| `build-skills.ps1` | ✅ Claude 12 / Codex 17, exit 0 |
| `scan-secrets.ps1` | ✅ no leaks / no blocking secrets, exit 0 |
| Working tree | clean except expected ignored paths + untracked docs (see §6) |

Source of truth: `skills-source/` (hand-maintained). `claude/skills/` and `codex/skills/` are
**generated** by `build-skills.ps1` and Git-ignored. `manifests/managed-skills.txt` lists the
22 repo-managed skill names (union of Claude + Codex).

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
- **Action when implementing `sync.ps1`:** probe for the directory that actually exists rather than
  assuming `~/.agents/skills`; treat `~/.codex/skills` as the live target on this environment.

---

## 6. Pending / open items

| Item | Status |
|---|---|
| `scripts/sync.ps1` / `backup.ps1` | still phase-1/2 disabled placeholders (`throw`); only a TODO added. Real sync is a separate task. |
| `docs/phase-2-6-post-push-status-2026-06-12.md` | resolved — committed as `205a937` (via GitHub) and now tracked. |
| Status-doc sprawl | 9 docs under `docs/` with overlapping status reports; optional future consolidation (kept as-is to preserve provenance). |
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

**Conclusion:** Phase 3 office deployment is successful and fully documented; the repo is clean and
in sync with origin; the `.system` preservation rule is formalized across README, plan, and the sync
script; a verified backup and restore guide exist. Remaining work is the (separate) real sync/backup
script implementation.
