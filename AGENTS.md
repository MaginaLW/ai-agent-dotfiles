# AGENTS.md

Project instructions for Codex agents working in this repository.

## Scope trigger

Apply the full skill-management workflow below only when the task involves any of:

- installing, uninstalling, importing, exporting, promoting, merging, pruning, syncing, deploying, or repairing Claude/Codex skills
- `skills-source/`, `claude/skills/`, `codex/skills/`
- `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`
- `imports/skills-inbox`, `imports/skills-archive`, `imports/skills-quarantine`
- `manifests/managed-skills.txt`
- `scripts/build-skills.ps1`, `scripts/scan-secrets.ps1`, `scripts/backup.ps1`, `scripts/sync.ps1`
- Codex `.system`

For unrelated tasks (ordinary docs, ordinary code, ordinary Git operations), do not expand this workflow or read the full skill manual unless it becomes relevant.

## Skill-management workflow

When the scope trigger applies:

1. Read `docs/README.md` and `docs/CURRENT_STATE.md`.
2. Treat `skills-source/` as the only source of truth.
3. Put new skills in exactly one place:
   - `skills-source/shared/<name>/`
   - `skills-source/claude-only/<name>/`
   - `skills-source/codex-only/<name>/`
4. Never edit generated output directly:
   - `claude/skills/`
   - `codex/skills/`
5. Never directly copy/delete live skills:
   - `~/.claude/skills`
   - `~/.codex/skills`
   - `~/.agents/skills`
6. Run validation before live changes:
   ```powershell
   pwsh -NoProfile -File scripts/build-skills.ps1
   pwsh -NoProfile -File scripts/scan-secrets.ps1
   pwsh -NoProfile -File scripts/sync.ps1
   ```
7. Only after a safe dry-run, apply:
   ```powershell
   pwsh -NoProfile -File scripts/sync.ps1 -Apply
   ```
8. For a fresh clone, use the bootstrap entrypoint instead of hand-installing hooks:
   ```powershell
   pwsh -NoProfile -File .\bootstrap.ps1
   ```

## Hard rules

- Never delete, move, overwrite, or modify `~/.codex/skills/.system`.
- Never use `robocopy /MIR` against live skills roots.
- Never weaken, bypass, or whitelist `scripts/scan-secrets.ps1` without explicit user approval.
- Never commit generated output, imports, backups, live home files, or machine-private files.
- Never put plaintext secrets, API keys, tokens, passwords, account info, or machine-private paths in skills.
- Keep `AGENTS.md` tracked in Git so these instructions sync across machines.
