# AGENTS.md

Project instructions for Codex agents working in this repository.

## Scope trigger

Apply the full skill-management workflow below only when the task involves any of:

- installing, uninstalling, importing, exporting, promoting, merging, pruning, syncing, deploying, or repairing Claude/Codex/OpenCode skills
- `skills-source/`, `claude/skills/`, `codex/skills/`, `opencode/skills/`
- `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` (Codex fallback), `~/.config/opencode/skills`
- `imports/skills-inbox`, `imports/skills-archive`, `imports/skills-quarantine`
- `manifests/managed-skills.txt`, `manifests/managed-skills.opencode.txt`
- `scripts/build-skills.ps1`, `scripts/scan-secrets.ps1`, `scripts/backup.ps1`, `scripts/sync.ps1`, `scripts/rollback-harness-env.ps1`
- `scripts/config-status.ps1`, `scripts/config-pull.ps1`, `scripts/config-push.ps1`, `.claude/settings.json` (harness config-sync)
- `harness-source/`, `.agent-harness/generated/`
- `.agent-harness/task-skills.psd1`, `scripts/task-skills.ps1`, `scripts/auto-sync-after-git.ps1`, `tests/task-skills.tests.ps1`
- `harness-source/components/mcp-templates/`, `scripts/mcp-common.ps1`, `claude/mcp/apply-mcp.ps1`
- `scripts/harness-profile-common.ps1`, `scripts/status-harness-profile.ps1`, `scripts/build-harness-profile.ps1`, `scripts/apply-harness-profile.ps1`, `tests/harness-profile.tests.ps1` (project harness profiles)
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
   - `skills-source/opencode-only/<name>/`
4. Never edit generated output directly:
   - `claude/skills/`
   - `codex/skills/`
   - `opencode/skills/`
5. Never directly copy/delete live skills:
   - `~/.claude/skills`
   - `~/.codex/skills`
   - `~/.agents/skills` (Codex fallback, used when `~/.codex/skills` doesn't exist)
   - `~/.config/opencode/skills`
6. Run validation before live changes:
   ```powershell
   pwsh -NoProfile -File scripts/build-skills.ps1
   pwsh -NoProfile -File scripts/scan-secrets.ps1
   pwsh -NoProfile -File scripts/sync.ps1
   ```
7. Only after a safe dry-run, apply:
   ```powershell
   $plan = Join-Path $env:TEMP 'ai-agent-dotfiles-sync-plan.json'
   pwsh -NoProfile -File scripts/sync.ps1 -DryRun -PlanPath $plan
   # Review the plan, then apply the same fingerprint-bound plan.
   pwsh -NoProfile -File scripts/sync.ps1 -Apply -PlanPath $plan
   ```
8. For a fresh clone, use the bootstrap entrypoint instead of hand-installing hooks:
   ```powershell
   pwsh -NoProfile -File .\bootstrap.ps1
   ```

9. For a task-specific managed skill, use the repository-shared overlay commands instead of editing
   `work.psd1`, generated output, or live roots:
   ```powershell
   pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env task status
   pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env task ensure-skill <name> -Platform Codex -DryRun
   pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env task ensure-skill <name> -Platform Codex -Apply
   ```
   Commit `.agent-harness/task-skills.psd1` only when the task requirement should be shared with the
   branch/worktree collaborators. Task close/removal always requires an explicit dry-run and apply.

## Hard rules

- Never delete, move, overwrite, or modify `~/.codex/skills/.system`.
- Never use `robocopy /MIR` against live skills roots.
- Never weaken, bypass, or whitelist `scripts/scan-secrets.ps1` without explicit user approval.
- Never commit generated output, imports, backups, live home files, or machine-private files.
- Never put plaintext secrets, API keys, tokens, passwords, account info, or machine-private paths in skills.
- `skills-source/opencode-only/` is the hand-maintained OpenCode-only skill source.
- `opencode/skills/` is generated output — never edit or commit it.
- `~/.config/opencode/skills` is the live OpenCode skill target; `opencode.json(c)` is machine-private.
- Codex `config.toml` is excluded from config-sync (machine-private state). See `docs/README.md` §14.
- Project Harness Profiles are project-local in the first version: `.agent-harness/generated/` is disposable generated output and must not be hand-edited or committed unless a future tracked-template decision explicitly says so.
- `scripts/apply-harness-profile.ps1 -Apply` must not be treated as permission to write `~/.claude`, `~/.codex`, `~/.config/opencode`, live skills roots, or Codex `.system`; first-version apply writes only project-local allowlist output.
- Do not claim Project Harness Profiles install project-local skills or perform automatic global home harness switching.
- MCP templates may contain only safe command metadata and exact environment-variable placeholders; use `claude/mcp/apply-mcp.ps1` through a reviewed dry-run plan for single-server add/update/remove. Never overwrite `~/.claude.json` directly, and never write environment-variable values to templates, plans, reports, or command logs.
- Keep `AGENTS.md` tracked in Git so these instructions sync across machines.