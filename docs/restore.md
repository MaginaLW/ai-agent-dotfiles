# Restore Guide

How to restore live agent skill directories from a backup created during deployment.

Backups are taken **outside** the repository, under:

```
%USERPROFILE%\.ai-agent-dotfiles-backups\<label>-<YYYYMMDD-HHMMSS>\
```

They are never tracked by Git. Each backup contains:

- `claude-skills\` — a copy of `~/.claude/skills` at backup time (or `claude-skills.MISSING.txt` if it did not exist).
- `codex-skills\` — a copy of `~/.codex/skills` at backup time (or `codex-skills.MISSING.txt`).

> All restore commands are PowerShell 7+ (`pwsh`). `robocopy` exit codes **< 8 mean success** (1 = files copied).

---

## 1. Find the backup you want

```powershell
Get-ChildItem "$env:USERPROFILE\.ai-agent-dotfiles-backups" -Directory |
  Sort-Object Name -Descending | Select-Object Name, FullName
```

Set it as a variable for the steps below:

```powershell
$backup = "$env:USERPROFILE\.ai-agent-dotfiles-backups\phase-3-office-20260612-112727"
```

---

## 2. Restore Codex `.system` only (most common)

`.system` is Codex's platform-managed skills directory (marker: `.codex-system-skills.marker`,
built-ins such as `imagegen`, `openai-docs`, `plugin-creator`, `skill-creator`, `skill-installer`).
It is **not** a repo-managed skill and must always be preserved. If a sync/prune ever removes it,
restore it without touching the repo-managed skills:

```powershell
$src = Join-Path $backup 'codex-skills\.system'
$dst = "$env:USERPROFILE\.codex\skills\.system"
robocopy $src $dst /E /COPY:DAT /R:1 /W:1
Test-Path "$dst\.codex-system-skills.marker"   # expect True
```

---

## 3. Restore a single removed skill

Example: bring back one of the user skills removed during a mirror sync
(`brainstorming`, `codex-primary-runtime`, `subagent-driven-development`,
`systematic-debugging`, `writing-plans`, `writing-skills`):

```powershell
$name = 'brainstorming'
robocopy (Join-Path $backup "codex-skills\$name") "$env:USERPROFILE\.codex\skills\$name" /E /COPY:DAT /R:1 /W:1
```

> Restoring a skill into the **live** directory does **not** add it to the repo. To make a skill
> repo-managed, route it through a fresh `imports/skills-inbox/` + Phase 2.6 merge into
> `skills-source/`, then `build-skills.ps1`.

---

## 4. Restore an entire live directory

Additive (copy back without deleting anything currently present):

```powershell
robocopy (Join-Path $backup 'codex-skills')  "$env:USERPROFILE\.codex\skills"  /E /COPY:DAT /R:1 /W:1
robocopy (Join-Path $backup 'claude-skills') "$env:USERPROFILE\.claude\skills" /E /COPY:DAT /R:1 /W:1
```

Full restore to the exact backup snapshot (mirror — **deletes** anything not in the backup):

```powershell
# WARNING: /MIR purges extras. The backup already includes .system, so this preserves it,
# but double-check the backup is the snapshot you actually want before running.
robocopy (Join-Path $backup 'codex-skills') "$env:USERPROFILE\.codex\skills" /MIR /COPY:DAT /R:1 /W:1
```

---

## 5. Verify after restore

```powershell
# .system present
Test-Path "$env:USERPROFILE\.codex\skills\.system\.codex-system-skills.marker"

# repo-managed skills still match the generated output (excluding .system)
$repo = Get-ChildItem "C:\Repos\ai-agent-dotfiles\codex\skills" -Directory | Select -Expand Name | Sort-Object
$live = Get-ChildItem "$env:USERPROFILE\.codex\skills" -Directory -Force |
        Where-Object Name -ne '.system' | Select -Expand Name | Sort-Object
if (Compare-Object $repo $live) { 'MISMATCH' } else { 'OK: managed skills match repo' }
```

---

## Rules (do not violate)

- Never delete `~/.codex/skills/.system` — see `README.md` (Deployment Targets) and
  `ai-agent-dotfiles-sync-plan-v2.md` §7.5.
- Never run a bare `robocopy /MIR` against `~/.codex/skills` from the **repo** generated output
  (it would purge `.system`); only mirror from a backup that already contains `.system`.
- Restoring into a live dir is not the same as adding to the repo; use the inbox + Phase 2.6 flow
  for that.
