# AGENTS.md

Project instructions for coding agents, including Codex and ZCode, working in this repository.

## Model selection

- Describe coordinator, implementer, and reviewer responsibilities and required capabilities without
  binding them to a model family, version, or fixed reasoning effort.
- Respect the user's explicit selection and existing personal settings. Otherwise use the current
  session/runtime defaults; any task-specific override must be supported by the current runtime.
- Keep reusable agent/config templates free of model and reasoning-effort defaults. Historical
  model names and routing records remain evidence of their original runs, not current instructions.
- Model selection does not change permissions, concurrency limits, or independent-review requirements.
  Preserve personal overrides when maintaining templates or reviewing config deployment; see
  [config-sync boundaries](docs/README.md#14-harness-配置同步config-sync).

## ZCode entry and low-intervention workflow

- Open this repository root as the ZCode workspace and start a new task after instruction changes.
  Read this file and `STATUS.md`, then explicitly read instructions relevant to the files being changed.
  ZCode does not automatically expand linked documents or nested instruction files; see
  [the ZCode handoff](docs/ZCODE.md).
- Check the Git root, existing changes, and the latest task evidence before acting. Preserve other
  work and report conflicting progress records instead of treating an old summary as authorization
  to start or repeat a roadmap task.
- Complete the user's authorized, recoverable work through implementation, relevant validation,
  and fixes without repeatedly asking whether to continue. Resolve routine details independently;
  ask only for a missing direction or a genuinely required approval, and reuse valid decisions.
- Delegate independent work when supported, assign non-overlapping write ownership, and keep the
  coordinator responsible for integration and final verification. Use runtime defaults and the
  user's choices as described above; do not copy another tool's model or permission settings.
- Use this project's PowerShell 7+ checks and required CI without reducing their scope or thresholds.
  Report exactly which checks ran and any missing checks; local checks do not stand in for CI.
  Make small, coherent local commits containing only reviewed changes from the current task.
- Preserve the scope triggers, production interlock, and hard rules below. This lightweight adoption
  adds no AI Flow task ledger, live deployment target, global configuration, or background collection.
  Push, merge, deployment, destructive actions, credential export, and additional paid model calls
  still require their applicable explicit authorization.
- At task completion, summarize the task/commit range, actual checks, necessary human decisions,
  and evidenced rework once. Reuse existing status records when appropriate; missing model identity,
  fees, human work time, or defect evidence stays `unknown` and does not block delivery. Never infer
  human effort from waiting time, commit raw conversations, or claim improvement from one sample.

## Scope trigger

Apply the full skill-management workflow below only when the task involves any of:

- installing, uninstalling, importing, exporting, promoting, merging, pruning, syncing, deploying, or repairing Claude/Codex skills
- `skills-source/`, `claude/skills/`, `codex/skills/`, `reasonix/skills/`
- `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` (Codex fallback), `%APPDATA%\reasonix\skills`
- `imports/skills-inbox`, `imports/skills-archive`, `imports/skills-quarantine`
- `manifests/managed-skills.txt`, `manifests/managed-skills.reasonix.txt`
- `scripts/build-skills.ps1`, `scripts/scan-secrets.ps1`, `scripts/backup.ps1`, `scripts/sync.ps1`, `scripts/rollback-harness-env.ps1`
- `scripts/config-status.ps1`, `scripts/config-pull.ps1`, `scripts/config-push.ps1`, `.claude/settings.json` (harness config-sync)
- `harness-source/`, `.agent-harness/generated/`
- `.agent-harness/task-skills.psd1`, `scripts/task-skills.ps1`, `scripts/auto-sync-after-git.ps1`, `tests/task-skills.tests.ps1`
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
   - `skills-source/reasonix-only/<name>/`
4. Never edit generated output directly:
   - `claude/skills/`
   - `codex/skills/`
   - `reasonix/skills/`
5. Never directly copy/delete live skills:
   - `~/.claude/skills`
   - `~/.codex/skills`
   - `~/.agents/skills` (Codex fallback, used when `~/.codex/skills` doesn't exist)
   - `%APPDATA%\reasonix\skills`
6. Run validation before live changes:
   ```powershell
   pwsh -NoProfile -File scripts/build-skills.ps1
   pwsh -NoProfile -File scripts/scan-secrets.ps1
   ```
   The schema 3 sync DryRun runs only inside the internal sandbox with a create-new
   `-PlanPath` (host-injected roots; a bare `sync.ps1` invocation fails closed); see
   [docs/README.md §4](docs/README.md#4-日常同步流程) for the invocation shape.
7. Phase 0 safety interlock: production Apply/rollback/retirement is currently unavailable and
   returns `safety-protocol-upgrade-required` before backup or mutation. The commands below describe
   the reviewed future contract only; do not attempt the Apply command until tracked policy is released:
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
8. For a fresh clone, use the bootstrap entrypoint instead of hand-installing hooks. Bootstrap verifies
   the pinned schema validator, pinned gitleaks cache, and Git-private approved runner in order. Follow
   the exact installer/approval command it prints; hooks remain preview/event-only and never Apply:
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
- Codex `config.toml` is excluded from config-sync (machine-private state). See `docs/README.md` §14.
- Project Harness Profiles are project-local in the first version: `.agent-harness/generated/` is disposable generated output and must not be hand-edited or committed unless a future tracked-template decision explicitly says so.
- `scripts/apply-harness-profile.ps1 -Apply` must not be treated as permission to write `~/.claude`, `~/.codex`, live skills roots, or Codex `.system`; first-version apply writes only project-local allowlist output.
- Do not claim Project Harness Profiles install project-local skills or perform automatic global home harness switching.
- Keep `AGENTS.md` tracked in Git so these instructions sync across machines.
