# AGENTS.md

Project instructions for coding agents working in this repository, including Codex and ZCode.
Codex and ZCode do not expand linked documents, so every rule an agent must follow is written
here. Links only point to detail for the area you are changing. Local Claude developer entry
files are retired; distributable Claude compatibility templates remain under `claude/`.

## Start of a task

- Open the repository root as the workspace. After this file changes, start a new task so the
  new rules are loaded ([ZCode notes](docs/ZCODE.md)).
- Read [STATUS.md](STATUS.md) for the current state. Status entries and older task records are
  evidence. They are not authorization to start or repeat roadmap work.
- One writer on the primary checkout. Before editing, committing, stashing, checking out,
  resetting or making any other write, confirm this working tree is the one this task owns; if
  the primary tree is dirty or `status/active/` already names another task, continue in a
  throwaway worktree or a separate checkout (or stop and ask). Read-only use of the primary
  stays allowed. A task holding the primary leaves a record under `status/active/` and deletes
  it when done.
- Parallel write work uses its own branch in a throwaway worktree or a separate checkout. Stash,
  checkout, reset and clean only the tree this task created. Integrate back into the primary
  serially, one agent, in small commits. Merge still needs the owner's authorization.
  Remove the throwaway tree when the task ends. A local branch created for this task may be deleted
  without further authorization after its recorded full tip SHA is proven integrated:
  `git merge-base --is-ancestor <full-sha> main` exits 0, or, when the commits were copied by
  rebase or cherry-pick, `git cherry -v main <full-sha>` prints one `-` line per commit counted
  by `git rev-list --count main..<full-sha>` (at least one, no `+` line, no merge commit in that
  range, and never an empty output). Immediately before deletion, verify that no worktree uses the
  branch, and delete its ref only if it still points to that recorded SHA. If the proof fails or
  the owner asked to keep the branch, keep it and report it. Never delete `main` or `origin/main`.
  A remote branch needs its own explicit authorization, separate from any push or merge approval,
  with its pull request merged or closed first.
- Run only one full local `run-tests.ps1` or `run-repository-validation.ps1` on the machine at a
  time. Live Applies write shared home paths and never overlap either. Each Apply must be
  covered by explicit owner authorization, including the standing grant in Skill rules 10,
  except the narrow approval-feedback exception in Skill rules 9. An authorized finite task
  chain or matching standing grant does not need a repeated question at every stage or task.
- Windows and PowerShell 7+ only. Run repository scripts as
  `pwsh -NoProfile -File scripts/<name>.ps1`. The unified CLI is `scripts/agent-dotfiles.ps1`.
- Commit reviewed changes and push them normally after validation, verifying the target remote
  and branch first. Force pushes still need the owner's explicit authorization.
- Merge, live Apply other than the approval-feedback exception in Skill rules 9, destructive
  actions, credential export and additional paid model calls need explicit owner authorization
  covering their actual scope. Reuse an existing task grant that explicitly includes the action
  and finite recovery; do not infer it from a plan, score or ordinary implementation permission.
  New scope, revoked permission or unknown side effects pause only the affected action.
  Proven-integrated local task branch deletion follows the exception above.
- Finish authorized, recoverable work through validation without asking again whether to
  continue. Ask only when a decision that changes direction is missing or an approval is required.
- Make small commits that contain only reviewed changes from the current task, and report which
  checks actually ran.
- Templates in `harness-source/`, `claude/` and `codex/` carry no model or reasoning-effort
  defaults. Use the user's selection or the runtime default. When deploying config, preserve the
  user's personal overrides.

## What the repository does

`scripts/build-skills.ps1` builds `skills-source/` into `claude/skills/` and `codex/skills/`.
`scripts/deploy.ps1` runs `deploy-skills.ps1` for one environment and then `config-pull.ps1`;
`scripts/deploy-skills.ps1` copies the skills that one environment
(`harness-source/envs/<name>.psd1`) selects into the live roots `~/.claude/skills`,
`~/.codex/skills` (or the `~/.agents/skills` fallback when only that one exists),
and `~/.zcode/skills`. Zcode is a projection platform: it has no
generated root of its own and deploys from the Claude generated output. The repository also
syncs harness config (config-sync) and builds
project harness profiles. Detail: [docs/README.md](docs/README.md) (§4-6 skills and deployment,
§8 restore, §11 config-sync, §12 profiles, §13 environments).

## Skill rules

These rules apply when a task touches `skills-source/`, the generated roots, `manifests/`,
`harness-source/`, a live skills root or Codex `.system`, or the build, deploy,
skills, config-sync or profile scripts and their tests. Ordinary docs, code and Git work do not
need them.

1. **Single source.** `skills-source/` is the only source of truth. Put each skill in exactly one
   of `skills-source/shared/<name>/`, `skills-source/claude-only/<name>/` or
   `skills-source/codex-only/<name>/`. The build rejects
   name conflicts.
2. **Generated output.** Never edit generated output directly: `claude/skills/`, `codex/skills/`
   and `.agent-harness/generated/`. Regenerate it with `build-skills.ps1` or
   `build-harness-profile.ps1`.
3. **Live roots only through deploy.** Change live skills roots only through
   `scripts/deploy-skills.ps1` or `scripts/deploy.ps1` (the `agent-dotfiles.ps1 sync` and
   `env deploy <name>` routes now use the combined entry point).
   Never copy into or delete from a live root by hand. The one exception is restoring a
   deploy-skills backup with the owner's authorization ([docs/README.md §8](docs/README.md#8-备份与恢复)).
   Run the dry run first (no `-Apply`) and review every install, update, prune and unknown line.
   Use `-Apply` only within explicit owner authorization for that reviewed scope. Reuse an
   existing grant covering this finite deployment; ask only for a missing or materially changed
   decision, not for the same authorization again.
4. **Retiring a skill.** deploy-skills prunes only directories it deployed itself. A deleted
   skill that it never deployed stays in the live root as unknown and preserved. To remove it,
   pass `-Retire <name>` to both the dry run and the Apply. Never pass `.system` or a selected
   skill to `-Retire`.
5. **Adding a skill.** Put it into `skills-source/` by hand, or use `scripts/promote-skill.ps1
   -Path <dir> -Name <name> -Type <type>` (dry run first, then `-Apply`, which builds and scans).
   Review the source first: no secrets, tokens, machine-private paths, caches or runtime state.
6. **Environments.** `harness-source/envs/<name>.psd1` selects the skills per platform; `work`
   is the daily Codex/ZCode set with an empty Claude selection. Keep the Claude build
   output as the ZCode projection source. Change a selection in a reviewed commit, not for one task.
7. **Fresh clone.** Run `bootstrap.ps1` once on a fresh clone. It installs and verifies the
   pinned gitleaks, builds the skills and prints the combined deploy dry-run command. It never
   changes a live root or config, and the repository installs no Git hooks.
8. **Config and profiles.**
   - `config-pull` and `config-push` run as dry runs unless `-Apply` is given.
   - `config-pull -Apply` defaults to Codex home config in `~/.codex`; Claude requires
     explicit `-Platform Claude` and separate authorization. Claude
     `settings.json` is merged object-by-object and Codex `AGENTS.md` updates only its marked
     block; other files are copied. Review the dry-run and confirm the managed changes.
     It needs explicit owner authorization covering this config deployment; an existing
     finite task grant can satisfy it without another question.
   - `apply-harness-profile.ps1 -Apply` writes only allowlisted files inside the target project.
     It never writes a home directory or a live root.
9. **Retired full-environment exception.** The former approval-feedback three-platform
   exception is retired with Claude. It grants no new full-environment or Claude live
   writes. Use the current `work` grant below for matching Codex/ZCode updates.

10. **Owner-approved standing skills deployment grant.** Once the owner explicitly approves
    this clause, an authorized task that changes selected skill sources may complete the
    skills-only deployment to the last-recorded `work` environment without another owner
    confirmation. The grant covers Codex and ZCode and subsequent tasks or chats in
    this project that read this current rule, until the owner revokes or narrows it.
    - Review the exact source diff; build, secret scan and diff checks must pass. Run and review
      the complete dry run for each changed version. The selection must be unchanged, and every
      selected directory must be `update` for a reviewed task change or `unchanged`; stop for any
      install, prune, unknown, unexpected change, staging residue, reparse point or other writer.
    - Use only `deploy-skills.ps1 -Environment work -Apply`. Verify the deployment readback and
      repeat the same dry run. Report the result in the original task. Recover startup or
      preparation failures only after proving no live side effect; do not blindly retry unknown
      or partially applied writes. Read back first. Recovery may restore only this task's
      verified pre-Apply backups of directories actually changed by this deployment; confirm
      backup provenance and current state before restoring, never touch `.system` or unrelated
      directories. Stop for a concrete decision when recovery falls outside this scope.
    - This permits writes to the two selected live roots and the deployment script's normal
      backups/state. Risks include changed agent instructions and automated replacement of live
      skill files. Preserve backups; rollback is limited to the verified task-owned scope above.
      It does not authorize environment/selection changes, installs, retirement or pruning,
      config/global instructions, credentials, extra paid calls, merge, branch deletion or
      bypassing platform approval. Other actions retain their existing authorization rules.
    - Approval to adopt this exact clause also covers the reviewed current skills deployment.
      This clause cannot authorize its own adoption, expansion or reinstatement after revocation.
      Further tasks must verify the effective project rule and revocation state, not rely only
      on an old chat, private ledger or an unintegrated branch.

```powershell
pwsh -NoProfile -File .\bootstrap.ps1
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
pwsh -NoProfile -File scripts/deploy.ps1 -Environment work
```

## Hard rules

- Never delete, move, overwrite, or modify `~/.codex/skills/.system`.
- Never use `robocopy /MIR` or any other whole-directory mirror against a live skills root.
  Deployment works one skill directory at a time, and unknown live directories are preserved.
- Never weaken, bypass, or whitelist `scripts/scan-secrets.ps1` or `.gitleaks.toml` without
  explicit user approval.
- Never commit any of the following: generated output, backups, deploy state, live home files,
  or machine-private files.
- Never commit a `config-push` capture until a human has reviewed its `git diff`. The secret scan
  blocks tokens, not machine-private paths or personal content.
- Never put plaintext secrets, tokens, account info, machine names or machine-private paths in
  skills, tracked docs or commits.
- Machine-private configuration including Codex `config.toml` and private `.env` files,
  credentials, sessions and caches are never synced.

## Checks and CI

- **Local checks.**
  - Every change needs `git diff --check` and `scan-secrets.ps1`.
  - Skill changes also need `build-skills.ps1`.
  - Script changes also need `check-powershell-syntax.ps1`, the affected suites (run each with
    `pwsh -NoProfile -File tests/<suite>.tests.ps1`) and, before merging, a full `run-tests.ps1`.
- **Read-only deployment rechecks.** Use the existing config-status and deploy-skills commands
  with the recorded environment; inspect their actual output and stop when the requested claims
  are covered. `-SkipBuild` requires a successful build and scan covering unchanged canonical
  sources, build inputs and generated output; otherwise perform the missing checks once.
  Do not repeat an equivalent source/live tree walk or an inspected delegated audit. Build owns
  runtime exclusions, including source-only `CREATION-LOG.md`; apply its comparison contract.
  See [the bounded recheck recipe](docs/README.md#部署后的只读复核).
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
  review. `tests/repository-policy.tests.ps1` checks working guard rails only (retired local
  entry points, manifests, generated-root boundaries, ignore rules and scan exclusions).
