# CLAUDE.md

Project instructions for Claude Code working in this repository.

## Scope trigger

Apply the full skill-management workflow below only when the task involves any of:

- installing, uninstalling, importing, exporting, promoting, merging, pruning, syncing, deploying, or repairing Claude/Codex/Reasonix skills
- `skills-source/`, `claude/skills/`, `codex/skills/`, `reasonix/skills/`
- `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, `%APPDATA%\reasonix\skills`
- `imports/skills-inbox`, `imports/skills-archive`, `imports/skills-quarantine`
- `manifests/managed-skills.txt`, `manifests/managed-skills.reasonix.txt`
- `scripts/build-skills.ps1`, `scripts/scan-secrets.ps1`, `scripts/backup.ps1`, `scripts/sync.ps1`
- `scripts/config-status.ps1`, `scripts/config-pull.ps1`, `scripts/config-push.ps1`, `.claude/settings.json` (harness config-sync)
- `harness-source/`, `.agent-harness/generated/`
- `scripts/harness-profile-common.ps1`, `scripts/status-harness-profile.ps1`, `scripts/build-harness-profile.ps1`, `scripts/apply-harness-profile.ps1`, `tests/harness-profile.tests.ps1` (project harness profiles)
- `harness-source/envs/`, `envs/` (repo-root staging), `state/current-env.json`
- `scripts/harness-env-common.ps1`, `scripts/list-harness-env.ps1`, `scripts/status-harness-env.ps1`, `scripts/build-harness-env.ps1`, `scripts/activate-harness-env.ps1`, `tests/harness-env.tests.ps1` (harness environments)
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
   - `skills-source/reasonix-only/<name>/`
4. Never edit generated output directly:
   - `claude/skills/`
   - `codex/skills/`
   - `reasonix/skills/`
5. Never directly copy/delete live skills:
   - `~/.claude/skills`
   - `~/.codex/skills`
   - `~/.agents/skills`
   - `%APPDATA%\reasonix\skills`
6. Run validation before live changes:
   ```powershell
   pwsh -NoProfile -File scripts/build-skills.ps1
   pwsh -NoProfile -File scripts/scan-secrets.ps1
   pwsh -NoProfile -File scripts/sync.ps1
   ```
7. Phase 0 safety interlock: production Apply/rollback/retirement currently returns
   `safety-protocol-upgrade-required` before backup or mutation. The following Apply command is the
   reviewed future contract only and must not be attempted until tracked policy is released:
   ```powershell
   $plan = Join-Path $env:TEMP 'ai-agent-dotfiles-sync-plan.json'
   pwsh -NoProfile -File scripts/sync.ps1 -DryRun -PlanPath $plan
   # Review the plan, then apply the same fingerprint-bound plan.
   pwsh -NoProfile -File scripts/sync.ps1 -Apply -PlanPath $plan
   ```
   When a reviewed canonical deletion has already removed the old name from the current manifests,
   use an external one-shot JSON retirement manifest and pass the same file to both commands with
   `-RetireManifestPath`. The retirement file, its resolved path, live/source roots, and target tree
   hashes are plan-bound; it must never contain `.system` or an active/canonical skill. Do not commit
   retirement manifests, do not expect auto-sync hooks to consume them, and delete the external plan
   and retirement JSON after a successful Apply to prevent later replay.

## Hard rules

- Never delete, move, overwrite, or modify `~/.codex/skills/.system`.
- Never use `robocopy /MIR` against live skills roots.
- Never weaken, bypass, or whitelist `scripts/scan-secrets.ps1` without explicit user approval.
- Never commit generated output, imports, backups, live home files, or machine-private files.
- Never put plaintext secrets, API keys, tokens, passwords, account info, or machine-private paths in skills.
- `skills-source/reasonix-only/` is the Reasonix-only source.
- `reasonix/skills/` are generated output — never edit or commit them.
- `%APPDATA%\reasonix\skills` is the live Reasonix skill target; `config.toml`/`.env` are machine-private and never synced.
- Harness config-sync (`config-pull`/`config-push`) is dry-run by default; `-Apply` is gated. Never commit a `config-push` capture without a human `git diff` review — the secret scan blocks tokens, not machine-private paths. Codex `config.toml` is excluded from config-sync (machine-private state). See `docs/README.md` §14.
- Project Harness Profiles are project-local in the first version: `.agent-harness/generated/` is disposable generated output and must not be hand-edited or committed unless a future tracked-template decision explicitly says so.
- `scripts/apply-harness-profile.ps1 -Apply` must not be treated as permission to write `~/.claude`, `~/.codex`, live skills roots, or Codex `.system`; first-version apply writes only project-local allowlist output.
- Do not claim Project Harness Profiles install project-local skills or perform automatic global home harness switching.
- Multi-platform Harness outputs are allowlist-bound project files: Claude commands/agents, Codex prompts/agents only. They are generated/reviewed through the profile scripts and never write global home state.
- `envs/` is generated Harness Environments staging — never hand-edit or commit it; rebuild with `scripts/build-harness-env.ps1`. `state/current-env.json` is machine-private and never committed.
- `env list`/`env status`/`env build` are read-only toward home directories and must never write `~/.claude`, `~/.codex`, live skills roots, or `state/`.
- `env activate` is the future sanctioned global environment switch, but Phase 0 production Apply is interlocked with `safety-protocol-upgrade-required`. Never hand-copy env staging into a home directory. DryRun review remains machine-local; tracked docs must not record machine names or private home paths. Config deployment via `config-pull.ps1` is NOT part of activation; adding it requires a separate review. See `docs/README.md` §16.
- `env rollback` is the separate managed-scope recovery path: it requires an explicitly selected environment activation backup, a reviewed dry-run plan, and an exact plan hash on Apply. It restores only current-manifest Claude/Codex/Reasonix skills and the corresponding environment state; it never touches unknown live directories, Codex `.system`, credentials, sessions, caches, or Codex `config.toml`.
- Keep `CLAUDE.md` tracked in Git so these instructions sync across machines.
