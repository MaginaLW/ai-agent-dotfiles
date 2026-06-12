# Phase 3 — Office Machine Deployment Status

- **Date:** 2026-06-12
- **Machine:** `DESKTOP-3GMDAB7` (office desktop)
- **Repo path:** `C:\Repos\ai-agent-dotfiles`
- **PowerShell:** 7.6.2 (pwsh)
- **Goal:** Deploy the unified `ai-agent-dotfiles` skills (generated output) from `origin/main` to this machine's live Claude and Codex skill directories.

---

## 1. Summary

| Item | Result |
|---|---|
| Repo synced to origin/main | ✅ `HEAD == origin/main` |
| build-skills.ps1 | ✅ Claude 12 / Codex 17, exit 0 |
| scan-secrets.ps1 | ✅ `no leaks found` / `No blocking secrets found`, exit 0 |
| Claude deploy | ✅ 12 skills, exact match to repo |
| Codex deploy | ✅ 17 managed skills (exact match) + `.system` preserved |
| Backup taken | ✅ (outside repo, not in Git) |
| Hotfix committed + pushed | ✅ `e6a2d90` |
| Deployment successful | ✅ Yes |

Latest commit after this work:

```
e6a2d90 fix: sanitize security best practices example
487635f Create status-report-magina-laptop-merge-2026-06-12.md
1fef8ad skills: merge imported skills from magina-laptop
```

---

## 2. Pre-deploy sync

- `git fetch --all --prune` → fast-forwarded `7619191..487635f`.
- After the hotfix, `HEAD == origin/main == e6a2d90`.
- Required commit `1fef8ad skills: merge imported skills from magina-laptop` confirmed present in history.
- Working tree clean except one pre-existing untracked doc (`docs/phase-2-6-post-push-status-2026-06-12.md`) and the normally-ignored generated/import paths.

---

## 3. Secret-scan hotfix (scan gate)

The initial `scan-secrets.ps1` run **failed (exit 1)**. Root cause was a **false positive**: gitleaks' generic `quoted-secret-value` rule flagged a documentation example in the `security-best-practices` teaching skill.

- **File (canonical source):** `skills-source/codex-only/security-best-practices/references/javascript-express-web-server-security.md`
- **Line:** 341
- **Before:** the bullet illustrated the antipattern by quoting two hard-coded example session-secret literals inline (the well-known Express.js placeholder string and a short fake value), written as quoted assignments to a session `secret` key — which is exactly the shape the `quoted-secret-value` rule matches.
- **After:**
  `* Hard-coding the session secret literal in source instead of loading it from a secret manager or environment variable at runtime.`

Fix method (per instruction — no gate weakening):
- Edited **only the canonical source** under `skills-source/`; did **not** hand-edit generated output, did **not** whitelist in `.gitleaks.toml`, did **not** disable or relax `scan-secrets.ps1`, did **not** delete the skill.
- Re-ran `build-skills.ps1` to regenerate `codex/skills/...` (fix propagated automatically), then `scan-secrets.ps1` → clean.

Commit:
- Staged only `skills-source/codex-only/security-best-practices` + `manifests` (manifest unchanged; no generated output, no raw imports staged).
- `e6a2d90 fix: sanitize security best practices example`
- Pushed: `487635f..e6a2d90  main -> main`. A pre-commit hook re-ran the scan and passed.

---

## 4. Deployment (mirror strategy)

Generated output (source of truth):
- `C:\Repos\ai-agent-dotfiles\claude\skills\` → 12 skills
- `C:\Repos\ai-agent-dotfiles\codex\skills\` → 17 skills

Live targets:
- Claude: `C:\Users\admin\.claude\skills`
- Codex:  `C:\Users\admin\.codex\skills`

### Pre-deploy state of live dirs
- `~/.claude` existed; `~/.claude/skills` **did not exist** → clean install (no conflicts).
- `~/.codex/skills` existed with **8** entries.

### Method
- `robocopy /MIR` (mirror) from repo generated output to each live dir.
- Claude: created and populated `~/.claude/skills` with all 12 (no deletions — dir was empty).
- Codex: mirrored to the 17 generated skills, purging entries not in the repo.

### Result
- `~/.claude/skills` = **12** dirs, exact match to repo `claude/skills`.
- `~/.codex/skills` = **17 managed** dirs (exact match to repo `codex/skills`) **+ `.system`** = 18 total dirs.

---

## 5. ⚠️ Deviation you should know about — `.system`

The plan treated the 7 non-repo Codex entries as "old imported skills" to remove. During the purge it became clear that **`.system` is NOT a user/imported skill — it is Codex CLI's own system-managed skills directory**:

- Marker file: `.codex-system-skills.marker`
- Contains Codex platform built-ins: `imagegen`, `openai-docs`, `plugin-creator`, `skill-creator`, `skill-installer`

A pure mirror deleted it, which would likely break Codex's native features. Because removing platform internals was clearly not the intent of "sync imported skills," **`.system` was restored from the backup**.

**Net effect:** the 17 managed skills match the repo exactly, and Codex's own `.system` infrastructure is preserved alongside them.

### Formal rule (not a temporary workaround)

- **Claude live skills** (`~/.claude/skills`) must exactly match repo `claude/skills`.
- **Codex repo-managed skills** in `~/.codex/skills` must exactly match repo `codex/skills`.
- **`~/.codex/skills` may additionally contain `.system`** — the Codex CLI platform-managed skills directory, identified by `.codex-system-skills.marker` (contains built-ins such as `imagegen`, `openai-docs`, `plugin-creator`, `skill-creator`, `skill-installer`). `.system` is **not** a repo-managed skill and **must be preserved** on every sync / cleanup / prune. It must never be deleted as if it were a stale imported skill.
- Any future Codex sync must be **manifest-scoped** (only act on entries listed in `manifests/managed-skills.txt`) and must **never** blanket-mirror the whole `~/.codex/skills` directory (no bare `robocopy /MIR`).

The other 6 entries were genuine user/imported skills and were correctly removed from the live dir (all preserved in backup):
`brainstorming`, `codex-primary-runtime`, `subagent-driven-development`, `systematic-debugging`, `writing-plans`, `writing-skills`.

These were **not** added to the repo. If any are still wanted, re-import them as a new inbox and merge through the Phase 2.6 workflow into `skills-source/`.

---

## 6. Backup

- **Backup root:** `C:\Users\admin\.ai-agent-dotfiles-backups\phase-3-office-20260612-112727`
- `codex-skills/` — full copy of the pre-deploy `~/.codex/skills` (all 8 original entries incl. `.system`).
- `claude-skills.MISSING.txt` — records that `~/.claude/skills` did not exist at backup time (not an error).
- Located **outside** the repo; **not** tracked by Git; **not** deleted.

Backup integrity verified — all removed entries recoverable:

| Entry | In backup |
|---|---|
| brainstorming | ✅ |
| codex-primary-runtime | ✅ |
| subagent-driven-development | ✅ |
| systematic-debugging | ✅ |
| writing-plans | ✅ |
| writing-skills | ✅ |
| .system | ✅ |

---

## 7. Final verification

- `build-skills.ps1` → Claude 12 / Codex 17, exit 0.
- `scan-secrets.ps1` → no leaks / no blocking secrets, exit 0.
- `git status --short --ignored` → only the pre-existing untracked doc; generated output (`claude/skills/`, `codex/skills/`) and imports remain ignored; no unexpected tracked changes.
- Consistency checks:
  - Claude: repo 12 == live 12 (exact match).
  - Codex managed: repo 17 == live 17 excluding `.system` (exact match).

---

## 8. Notes / follow-ups

- Generated output stays Git-ignored; raw `imports/skills-inbox|archive|quarantine` were **not** copied to live dirs.
- `scripts/sync.ps1` and `scripts/backup.ps1` are still phase-1/2 disabled placeholders (they `throw`); this deployment was done via manual `robocopy`. Implementing real sync/backup scripts is a separate task — when it happens, the `.system` preservation rule above is mandatory. A TODO to that effect has been added to `scripts/sync.ps1`.
- The `.system` rule is now also recorded in `README.md` (deployment-target principles) and `docs/ai-agent-dotfiles-sync-plan-v2.md` (§7.5 prune rules).
- The 6 removed user skills are **not** auto-reimported into the repo; if wanted later they go through a fresh inbox + Phase 2.6 merge.

## 9. Conclusion

**Phase 3 office deployment successful.** Claude (12) and Codex (17 managed) live skills are in exact sync with the repo's generated output, Codex's `.system` platform directory is preserved, a verified backup exists outside Git, and the scan gate is green on a clean canonical-source fix. No redeployment is required.
