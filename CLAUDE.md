# CLAUDE.md

Project instructions for Claude Code working in this repository.

## Scope trigger

Apply the full skill-management workflow below only when the task involves any of:

- installing, uninstalling, importing, exporting, promoting, merging, pruning, syncing, deploying, or repairing Claude/Codex/OpenClaw skills
- `skills-source/`, `claude/skills/`, `codex/skills/`, `openclaw/skills/`, `openclaw/plugins/`
- `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, `~/.openclaw/skills`
- `imports/skills-inbox`, `imports/skills-archive`, `imports/skills-quarantine`
- `manifests/managed-skills.txt`, `manifests/managed-skills.openclaw.txt`
- `scripts/build-skills.ps1`, `scripts/scan-secrets.ps1`, `scripts/backup.ps1`, `scripts/sync.ps1`, `scripts/sync-openclaw-plugins.ps1`
- `scripts/config-status.ps1`, `scripts/config-pull.ps1`, `scripts/config-push.ps1`, `.claude/settings.json` (harness config-sync)
- Codex `.system`

For unrelated tasks (ordinary docs, ordinary code, ordinary Git operations), do not expand this workflow or read the full skill manual unless it becomes relevant.

## Skill-management workflow

When the scope trigger applies:

1. Read `docs/README.md` and `STATUS.md`.
2. Treat `skills-source/` as the only source of truth.
3. Put new skills in exactly one place:
   - `skills-source/shared/<name>/`
   - `skills-source/claude-only/<name>/`
   - `skills-source/codex-only/<name>/`
   - `skills-source/openclaw-only/<name>/`
4. Never edit generated output directly:
   - `claude/skills/`
   - `codex/skills/`
   - `openclaw/skills/`
5. Never directly copy/delete live skills:
   - `~/.claude/skills`
   - `~/.codex/skills`
   - `~/.agents/skills`
   - `~/.openclaw/skills`
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

## Hard rules

- Never delete, move, overwrite, or modify `~/.codex/skills/.system`.
- Never use `robocopy /MIR` against live skills roots.
- Never weaken, bypass, or whitelist `scripts/scan-secrets.ps1` without explicit user approval.
- Never commit generated output, imports, backups, live home files, or machine-private files.
- Never put plaintext secrets, API keys, tokens, passwords, account info, or machine-private paths in skills.
- `skills-source/openclaw-only/` is the **only** hand-maintained OpenClaw-only skill source.
- `openclaw/skills/` is generated output — never edit or commit it.
- `openclaw/plugins/managed-plugins.json` is tracked desired plugin state.
- `~/.openclaw/plugins/installs.json` is machine-managed — never commit or edit it directly.
- OpenClaw identity, credentials, devices, approval state, sessions, caches, npm installs, node launchers, and workspace memory are never repo-managed.
- Harness config-sync (`config-pull`/`config-push`) is dry-run by default; `-Apply` is gated. Never commit a `config-push` capture without a human `git diff` review — the secret scan blocks tokens, not machine-private paths. Codex `config.toml` is excluded from config-sync (machine-private state). See `docs/README.md` §14.
- Keep `CLAUDE.md` tracked in Git so these instructions sync across machines.
