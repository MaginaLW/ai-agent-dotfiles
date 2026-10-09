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

## What the repository does

`scripts/build-skills.ps1` builds `skills-source/` into `claude/skills/`, `codex/skills/` and
`reasonix/skills/`. `scripts/deploy-skills.ps1` copies the skills that one environment
(`harness-source/envs/<name>.psd1`) selects into the live roots `~/.claude/skills`,
`~/.codex/skills` (or the `~/.agents/skills` fallback when only that one exists) and
`%APPDATA%\reasonix\skills`. The repository also syncs harness config (config-sync) and builds
project harness profiles. Detail: [docs/README.md](docs/README.md) (§4-6 skills and deployment,
§9 restore, §14 config-sync, §15 profiles, §16 environments).

## Skill rules

These rules apply when a task touches `skills-source/`, the generated roots, `manifests/`,
`harness-source/`, a live skills root or Codex `.system`, or the build, deploy,
skills, config-sync or profile scripts and their tests. Ordinary docs, code and Git work do not
need them.

1. **Single source.** `skills-source/` is the only source of truth. Put each skill in exactly one
   of `skills-source/shared/<name>/`, `skills-source/claude-only/<name>/`,
   `skills-source/codex-only/<name>/` or `skills-source/reasonix-only/<name>/`. The build rejects
   name conflicts.
2. **Generated output.** Never edit generated output directly: `claude/skills/`, `codex/skills/`,
   `reasonix/skills/` and `.agent-harness/generated/`. Regenerate it with `build-skills.ps1` or
   `build-harness-profile.ps1`.
3. **Live roots only through deploy-skills.** Change live skills roots only through
   `scripts/deploy-skills.ps1` (or its `agent-dotfiles.ps1 sync` and `env deploy <name>` routes).
   Never copy into or delete from a live root by hand. The one exception is restoring a
   deploy-skills backup with the owner's authorization ([docs/README.md §9](docs/README.md#9-备份与恢复)).
   Run the dry run first (no `-Apply`) and review every install, update, prune and unknown line.
   Rerun with `-Apply` only after the owner authorizes it.
4. **Retiring a skill.** deploy-skills prunes only directories it deployed itself. A deleted
   skill that it never deployed stays in the live root as unknown and preserved. To remove it,
   pass `-Retire <name>` to both the dry run and the Apply. Never pass `.system` or a selected
   skill to `-Retire`.
5. **Adding a skill.** Put it into `skills-source/` by hand, or use `scripts/promote-skill.ps1
   -Path <dir> -Name <name> -Type <type>` (dry run first, then `-Apply`, which builds and scans).
   Review the source first: no secrets, tokens, machine-private paths, caches or runtime state.
6. **Environments.** `harness-source/envs/<name>.psd1` selects the skills per platform; `work`
   is the daily set. Change a selection in a reviewed commit, not for one task.
7. **Fresh clone.** Run `bootstrap.ps1` once on a fresh clone. It installs and verifies the
   pinned gitleaks, builds the skills and prints the deploy-skills dry-run command. It never
   changes a live root, and the repository installs no Git hooks.
8. **Config and profiles.**
   - `config-pull` and `config-push` run as dry runs unless `-Apply` is given.
   - `config-pull -Apply` overwrites home config: `~/.claude`, `~/.codex`, and `%APPDATA%\reasonix`
     with `-Platform Reasonix`. It needs the owner's authorization after a review of the dry-run
     output and the user's personal overrides.
   - `apply-harness-profile.ps1 -Apply` writes only allowlisted files inside the target project.
     It never writes a home directory or a live root.

```powershell
pwsh -NoProfile -File .\bootstrap.ps1
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work
```

## Hard rules

- Never delete, move, overwrite, or modify `~/.codex/skills/.system`.
- Never use `robocopy /MIR` or any other whole-directory mirror against a live skills root.
  Deployment works one skill directory at a time, and unknown live directories are preserved.
- Never weaken, bypass, or whitelist `scripts/scan-secrets.ps1` or `.gitleaks.toml` without
  explicit user approval.
- Never commit any of the following: generated output, `imports/` or `reports/` contents,
  backups, deploy state, live home files, or machine-private files.
- Never commit a `config-push` capture until a human has reviewed its `git diff`. The secret scan
  blocks tokens, not machine-private paths or personal content.
- Never put plaintext secrets, tokens, account info, machine names or machine-private paths in
  skills, tracked docs or commits.
- Codex `config.toml`, Reasonix `config.toml`/`.env`, credentials, sessions and caches are
  machine-private and never synced.

## Checks and CI

- **Local checks.**
  - Every change needs `git diff --check` and `scan-secrets.ps1`.
  - Skill changes also need `build-skills.ps1`.
  - Script changes also need `check-powershell-syntax.ps1`, the affected suites (run each with
    `pwsh -NoProfile -File tests/<suite>.tests.ps1`) and, before merging, a full
    `run-tests.ps1 -All -JsonSummaryPath <external file>`.
- **CI.** One `Validate` job runs `scripts/run-repository-validation.ps1` on push to `main`, on
  pull requests and on manual dispatch: PowerShell syntax, gitleaks verification, build, secret
  scan, doctor, manifest parity, every test suite, dangerous tracked files and a clean tree.
  Before merging a change to `scripts/` or `tests/`, get a green run. Local checks do not stand
  in for CI.
- **Red runs.** Diagnose a red run from the failing step's log, not from the annotation. If the
  runner or a download failed, rerun without changing code. Rerun the same commit once to test
  for a flake; if it fails again, fix the test or its fixture. Never delete or weaken a suite,
  gate, timeout budget or the secret scan to get a green run.
- **Docs are not pinned.** No test checks documentation wording; keep the docs accurate by
  review. `tests/repository-policy.tests.ps1` checks working guard rails only (`CLAUDE.md`
  imports `AGENTS.md`, ignore rules, scan exclusions, `.claude/settings.json` denies).
