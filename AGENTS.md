# AGENTS.md

Project instructions for coding agents working in this repository, including Codex and ZCode.
Claude Code loads this file through `CLAUDE.md`. Codex and ZCode do not expand linked documents,
so every rule an agent must follow is written here. Links only point to detail for the area you
are changing.

## Start of a task

- Open the repository root as the workspace. After this file changes, start a new task so the
  new rules are loaded ([ZCode notes](docs/ZCODE.md)).
- Read [STATUS.md](STATUS.md) for the current state. Status entries and older task records are
  evidence. They are not authorization to start or repeat roadmap work.
- Windows and PowerShell 7+ only. Run repository scripts as
  `pwsh -NoProfile -File scripts/<name>.ps1`. The unified CLI is `scripts/agent-dotfiles.ps1`.
- On every task, push, merge, any live Apply, destructive actions, credential export and
  additional paid model calls each need the owner's explicit authorization.
- Finish authorized, recoverable work through validation without asking again whether to
  continue. Ask only when a decision that changes direction is missing or an approval is required.
- Make small commits that contain only reviewed changes from the current task, and report which
  checks actually ran.
- Templates in `harness-source/`, `claude/` and `codex/` carry no model or reasoning-effort
  defaults. Use the user's selection or the runtime default. When deploying config, preserve the
  user's personal overrides.

## Scope trigger

The skill-management rules below apply only when a task touches one of these:

- installing, importing, promoting, merging, pruning, syncing, deploying or repairing
  Claude/Codex/Reasonix skills;
- `skills-source/`, the generated `claude/skills/`, `codex/skills/` and `reasonix/skills/`,
  `manifests/`, or `imports/`;
- the live roots `~/.claude/skills`, `~/.codex/skills` (or the `~/.agents/skills` fallback when
  only that one exists), `%APPDATA%\reasonix\skills`, and Codex `.system`;
- sync, backup/restore, config-sync, harness profile, harness environment or task-skill scripts
  and their tests, `harness-source/`, `.agent-harness/`, `envs/`, `state/`, or
  `.claude/settings.json`.

Ordinary docs, code and Git work do not need this workflow.

## Skill-management rules

Before acting, read the [docs/README.md](docs/README.md) section for the area you are changing:
§4-6 for skills and sync, §14 for config-sync, §15 for profiles, §16 for environments. For rollback and recovery, read [docs/RESTORE.md](docs/RESTORE.md); never substitute `env rollback` for recovering an unfinished transaction.

1. **Single source.** `skills-source/` is the only source of truth. Put each skill in exactly one
   of `skills-source/shared/<name>/`, `skills-source/claude-only/<name>/`,
   `skills-source/codex-only/<name>/` or `skills-source/reasonix-only/<name>/`. The build rejects
   name conflicts.
2. **Generated output.** Never edit generated output directly: `claude/skills/`, `codex/skills/`,
   `reasonix/skills/`, `envs/` and `.agent-harness/generated/`. Regenerate it with
   `build-skills.ps1`, `build-harness-env.ps1` or `build-harness-profile.ps1`.
3. **Managed routes only.** Change live roots only through `deploy-skills.ps1`, `sync.ps1` or the
   `agent-dotfiles.ps1` `env`, `canonical` and `live recover` routes. Never copy into or delete
   from a live root by hand, and never hand-copy `envs/` staging into a home directory.
   `deploy-skills.ps1` is the simple replacement for the transactional routes. It has no plan
   file: review its dry-run output, then rerun with `-Apply` only after the owner authorizes it.
4. **Plan-bound changes.** Every plan-bound live command runs in two steps. These commands are
   sync, env activate/rollback/task/authority, canonical setup/recover and live recover. First run
   `-DryRun -PlanPath <new external file>` and review the plan. Then run
   `-Apply -PlanPath <same file>`. Never reuse a consumed plan.
5. **Authorization and acceptance.** The tracked policy is `ReleaseState=released`, but
   a released policy value is not deployment authorization or completed lab acceptance.
   There is no mechanical interlock. Before any live Apply, check
   [STATUS.md](STATUS.md#current-state) and confirm two things:
   - the live-engine code at HEAD is covered by the accepted candidate recorded there. Live-engine
     code means the files in `scripts/runner-policy.psd1` ToolchainPaths; check them with
     `git diff --name-only <candidate>..HEAD`. A later change to any of them needs new acceptance
     first;
   - the owner has explicitly authorized this Apply.
6. **Sandbox for validation.** A bare public DryRun resolves the real Windows identity and writes a
   real plan, so a rejection you expect does not prove isolation. For validation, run maintenance
   DryRuns only inside the internal sandbox host (`scripts/internal/live-transaction-host.ps1`,
   [docs/README.md §4](docs/README.md#4-日常同步流程)).
7. **First deployment.** Plain `sync.ps1` only plans a pristine first deployment or an explicit
   retirement. On a machine that already has an authority, run `agent-dotfiles.ps1 canonical status`
   and then `agent-dotfiles.ps1 env authority status`, and follow the route they report
   ([onboarding](docs/ONBOARD_NEW_MACHINE.md#5-select-the-machine-route)).
8. **Retirement.** Deleting a skill's source leaves its live directory unknown and preserved. To
   prune it, pass the same external one-shot JSON via `-RetireManifestPath` to both the DryRun and
   the Apply. The JSON must never list `.system` or an active skill, and must never be committed.
   After a successful Apply, delete both the plan and the JSON
   ([format](docs/README.md#5-修改已有-skill-的流程)).
9. **Task-only skills.** Use `agent-dotfiles.ps1 env task status|ensure-skill|sync|close`, which
   follows the same plan rule
   ([§16.1](docs/README.md#161-task-skill-overlay按任务热插拔)). Do not edit
   `harness-source/envs/work.psd1` for one task. Commit `.agent-harness/task-skills.psd1` only when
   collaborators should share the requirement.
10. **Fresh clone.** Run `bootstrap.ps1` once on a fresh clone. It checks the pinned schema
    validator, the pinned gitleaks and the runner approval in that order, and prints the exact next
    command. Approving the runner on a machine is the owner's per-machine decision. Its Git hooks
    remain preview/event-only and never Apply.
11. **Config and profiles.**
    - `config-pull` and `config-push` run as dry runs unless `-Apply` is given.
    - `config-pull -Apply` overwrites home config: `~/.claude`, `~/.codex`, and `%APPDATA%\reasonix` with `-Platform Reasonix`. It needs the owner's
      authorization after a review of the dry-run output and the user's personal overrides.
    - Config deployment is not part of `env activate`. Adding it there needs a separate review.
    - `apply-harness-profile.ps1 -Apply` writes only allowlisted files inside the target project.
      It never writes a home directory or a live root.

```powershell
pwsh -NoProfile -File .\bootstrap.ps1
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 canonical status
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env authority status
```

## Hard rules

- Never delete, move, overwrite, or modify `~/.codex/skills/.system`.
- Never use `robocopy /MIR` or any other whole-directory mirror against a live skills root.
  Deployment is manifest-scoped, and unknown live directories are preserved.
- Never weaken, bypass, or whitelist `scripts/scan-secrets.ps1` or `.gitleaks.toml` without
  explicit user approval.
- Never commit any of the following: generated output, `imports/` and `reports/` contents (other than their README placeholders), backups,
  `state/`, transaction plans (`-PlanPath` JSON) or retirement JSON, live home files, or machine-private files.
- Never commit a `config-push` capture until a human has reviewed its `git diff`. The secret scan
  blocks tokens, not machine-private paths or personal content.
- Never put plaintext secrets, tokens, account info, machine names or machine-private paths in
  skills, tracked docs or commits.
- Codex `config.toml`, Reasonix `config.toml`/`.env`, credentials, sessions and caches are
  machine-private and never synced.

## Checks and CI

- **Local checks.**
  - Every change needs `git diff --check` and `scan-secrets.ps1`.
  - Changes to this file, `CLAUDE.md`, `README.md`, `STATUS.md` or the `docs/` guides also need
    `tests/repository-policy.tests.ps1`, `tests/doctor.tests.ps1` and
    `tests/guide-examples.tests.ps1`.
  - Skill changes also need `build-skills.ps1`.
  - Script changes also need `check-powershell-syntax.ps1` and the affected suites (run each with
    `pwsh -NoProfile -File tests/<suite>.tests.ps1`).
  - For a full regression, run `run-tests.ps1 -All -JsonSummaryPath <external file>`.
- **CI.** Push and pull request run the gates job plus a fast suite set. The three heavy test
  shards (the full suite) run nightly and on manual dispatch. Do not delete or weaken any suite,
  gate or budget. Before merging a change to `scripts/` or `tests/`, get a green full suite:
  dispatch the `Validate` workflow or run `run-tests.ps1 -All` locally. Local checks do not
  stand in for CI. Diagnose a red `Validate` run with
  [the CI failure rules](docs/CI_FAILURE_RULES.md) instead of guessing from the annotation.
- **Pinned phrases.** The tests above check the entry and guide files:
  - `tests/repository-policy.tests.ps1` pins phrases in this file, `CLAUDE.md` (the import),
    `README.md` and `docs/README.md`.
  - `tests/doctor.tests.ps1` requires `STATUS.md` and the guides to mention Reasonix, and never to
    describe hooks or bootstrap as applying live changes.
  - `tests/guide-examples.tests.ps1` requires each of the seven guides, including `CLAUDE.md` and
    `docs/ZCODE.md`, to keep at least one valid `powershell` block.

  Change the wording and its pins in the same commit.

## harness-model feedback loop (ZCode pilot)

Follow the feedback loop in [docs/ZCODE.md](docs/ZCODE.md) only when there is a substantive issue
or an explicit user request. Ordinary task completion triggers nothing. The loop authorizes edits
to rule entries and adoption docs only, and it relaxes no gate.
