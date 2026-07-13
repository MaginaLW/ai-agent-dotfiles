# Project Status

Last updated: 2026-07-14

This is the single global status file for the repository. Update it in place instead of creating additional overall status reports. Current task-level work belongs in [`status/active/`](status/active/); completed task reports belong in [`status/archived/`](status/archived/).

## Project purpose

Maintain one conservative, auditable source for Claude, Codex, and OpenClaw skills and selected harness configuration across multiple machines. The repository builds platform-specific runtime output, scans for secrets, backs up live state before changes, and performs manifest-scoped synchronization without whole-directory mirroring.

## Current phase

Operations hardening plus the first Project Harness Profiles MVP. Skill build, backup, secret scanning, manifest-scoped sync, OpenClaw plugin desired-state management, repo-local auto-sync hooks, whitelist-scoped harness config status/pull/push, minimal Windows GitHub Actions validation, and project-local harness profile generation/apply scripts are implemented. Project Harness Profiles are first-version and project-local only: they generate `.agent-harness/generated/` under a target project and `apply-harness-profile.ps1 -Apply` writes only project-local allowlist output. This repository now also has a project-local `.agent-harness/profile.psd1` for real-project dry-run validation.

Reliability-first roadmap Phase 0 (baseline and status calibration) was completed on 2026-07-13: status evidence now distinguishes dry-run, fake-home, and real apply; doctor checks the actual per-platform generated layout; and the Windows validation workflow fails closed when a core validation entry point is missing.

Reliability-first roadmap Phases 1–3 were completed and locally verified on 2026-07-13. Inventory and merge now use platform-consistent fingerprints and fail closed on conflicts; sync uses content-aware add/update/no-op/prune plans, an external plan hash, same-volume staging, backup journal, and managed-skill rollback; core JSON evidence and regression suites are wired into Windows CI. This work did not run live `-Apply` and did not modify live skills, imports, backups, or Codex `.system`.

Reliability-first roadmap Phase 4 (environment lock, attestation, rollback, and unified CLI completion) was implemented on 2026-07-14 and verified against fake repositories/homes. `env.lock.json` schema 2 records definition hash, repository commit when available, platform manifest hashes, source/staged skill hashes, profile source/output hashes, and explicit plugin non-membership. Activation validates the lock before producing the bound sync plan; `env status` reports lock validity, definition drift, managed live parity, `.system` status, and backup reference; `env rollback` requires an explicit activation backup plus reviewed plan/hash and restores only managed Claude/Codex skills and prior environment state. No real-home `-Apply` or rollback was run.

Harness Environments Phases 1-3 landed on 2026-07-10 per `docs/superpowers/specs/2026-07-10-harness-env-design.md`: named env definitions in `harness-source/envs/`, `env list`/`env status`/`env build`/`env activate` subcommands under `scripts/agent-dotfiles.ps1`, staging output in Git-ignored `envs/<name>/`, and machine-private `state/current-env.json`. `env activate` is dry-run by default; `-Apply` deploys the env's skills subset exclusively through `sync.ps1` (mandatory backup, manifest-scoped prune, unknown dirs and Codex `.system` untouched) and only then writes the state file. Phase 2 scope is skills + state: home-level config deployment (config-pull integration) is deferred because no env-differentiated home config components exist yet. Phase 3 adds project linkage: a project's `.agent-harness/profile.psd1` may declare `RequiredEnv = '<name>'` and `env status -ProjectRoot <p>` reports whether the active environment matches — detection and reminder only, never an automatic activate. This repository declares `RequiredEnv = 'work'`.

The unified CLI now groups config, profile, skills, and env lifecycle commands under `scripts/agent-dotfiles.ps1`; mutating grouped commands require an explicit `-DryRun`/`-Apply` mode, and JSON stdout mode is not polluted by dispatcher banners.

Activation evidence is intentionally separated by execution mode:

- Historical dry-run: `DESKTOP-3GMDAB7` was checked on 2026-06-30 with `sync.ps1` dry-runs only; no real-home `-Apply` was run there.
- Fake-home validation: `tests/harness-env.tests.ps1` exercises apply, switch, prune, and parity behavior against test homes; those runs do not prove a real machine activation.
- Real apply: with explicit user authorization, `MAGINA-LAPTOP` ran `env activate full -Apply` on 2026-07-10. The zero-prune baseline env applied Claude `+0 ~15 -0`, Codex `+0 ~23 -0`, OpenClaw `+0 ~0 -0`, preserved the Codex `.system` marker, passed the managed-scope parity check at that time, and wrote machine-private `state/current-env.json` (`Name=full`). Mandatory backups from the run were `sync-backup-20260710-135828` (first attempt, aborted by the parity false-positive below) and `sync-backup-20260710-140653` (successful run). A separate historical direct `sync.ps1 -Apply` report exists for `MAGINA-LAPTOP` on 2026-07-01; it is evidence of that run, not a current cross-machine attestation.

The 2026-07-10 activation is therefore complete for `MAGINA-LAPTOP`; it must not be described as proof that every machine has been applied. The Phase 0 checks do not run live apply and do not create a new parity attestation.

## Current canonical decisions

- `skills-source/` is the only hand-maintained skill source of truth.
- New skills belong in exactly one of `shared/`, `claude-only/`, `codex-only/`, or `openclaw-only/` under `skills-source/`.
- `claude/skills/`, `codex/skills/`, and `openclaw/skills/` are generated, Git-ignored output and must not be edited or committed.
- Live skill changes use `scripts/sync.ps1`; dry-run review precedes `-Apply`, and apply requires build, secret scan, and backup.
- Codex `.system` is platform-managed and must never be modified, moved, overwritten, or pruned.
- Sync and prune are manifest-scoped; unknown live directories are reported but not deleted.
- `openclaw/plugins/managed-plugins.json` is tracked desired state. Machine-managed OpenClaw installation and identity state remain outside the repository.
- Harness config pull/push is whitelist-scoped and dry-run by default. Codex `config.toml` remains excluded as machine-private state.
- Project Harness Profiles use `harness-source/` as the component/profile library and generate disposable project-local `.agent-harness/generated/` output.
- First-version Project Harness Profiles do not write `~/.claude`, `~/.codex`, or `~/.openclaw`, do not install project-local skills, and do not provide automatic global home harness switching.
- Harness environment definitions live in `harness-source/envs/*.psd1` (tracked source of truth); `envs/` is disposable generated staging and `state/current-env.json` is machine-private activation state — neither is ever committed or hand-edited.
- `env activate` is the only sanctioned global environment switch: dry-run by default, `-Apply` gated with an explicit-mode requirement at the entry point, deployment exclusively through `sync.ps1` (whose pre-change backup cannot be skipped), and the state file written only after a successful apply. Home-only files, Codex `.system`, and unknown live skill dirs never change on activation.
- `env rollback` requires an explicit backup/run id and reviewed plan hash; its scope is current-manifest Claude/Codex skills plus the prior environment state. It never restores unknown dirs, `.system`, credentials, sessions, caches, Codex `config.toml`, or OpenClaw machine state.
- Phase 2 covers skills + state only. Home-level config deployment via `config-pull.ps1` is deferred until env-differentiated home config components exist, and its integration requires a separate review.
- `RequiredEnv` in a project profile is advisory only: `env status -ProjectRoot` detects and reminds, and nothing ever auto-activates an environment.
- `STATUS.md` is the global status record. `status/active/` contains only current task records; completed task records move to `status/archived/`.
- `reports/*.md` contains machine- and run-specific build/sync reports and is Git-ignored; only `reports/README.md` is tracked. Reports must contain metadata and skill names only, never backup contents or sensitive values.

## Machines

| Machine | Documented state |
|---|---|
| `DESKTOP-3GMDAB7` | Revalidated with dry-runs only on 2026-06-30: skill sync reported Claude `+0 ~15 -0`, Codex `+2 ~21 -0` with `.system` preserved, OpenClaw `+25 ~0 -0`, and OpenClaw plugin sync would install 2 managed plugins. No `-Apply` was run. |
| `MAGINA-LAPTOP` | Real harness-env activation completed on 2026-07-10: `env activate full -Apply` deployed Claude ~15 and Codex ~23, left OpenClaw untouched, preserved `.system`, passed activation-time managed-scope parity, and recorded active env `full`. A 2026-07-13 read-only check still finds the expected live roots and state record; it is not a new apply or a portable attestation. |
| Other machines | Run `bootstrap.ps1` once after cloning to install repo-local hooks and enter the guarded sync flow. |

## Build / scan status

- `.github/workflows/validate.yml` validates pushes, pull requests, and manual runs on `windows-latest`: it runs doctor, secret scan, build reproducibility checks, Project Harness Profile regression tests, and a tracked dangerous-file policy check without sync or live-skill changes.
- Current manifests describe Claude **15**, Codex **23**, and OpenClaw **25** managed skills.
- Repository-local generated output was regenerated on 2026-06-30 with `scripts/build-skills.ps1`: Claude **15**, Codex **23**, and OpenClaw **25**.
- Secret scan passed on 2026-06-30 with no blocking findings; keyword hints were non-blocking.
- Project Harness Profile MVP scripts and tests are present: `scripts/harness-profile-common.ps1`, `scripts/status-harness-profile.ps1`, `scripts/build-harness-profile.ps1`, `scripts/apply-harness-profile.ps1`, and `tests/harness-profile.tests.ps1`; the regression test is part of the Windows validation workflow.
- Harness Environments scripts and tests are present: `scripts/harness-env-common.ps1`, `scripts/list-harness-env.ps1`, `scripts/status-harness-env.ps1`, `scripts/build-harness-env.ps1`, `scripts/activate-harness-env.ps1`, `scripts/rollback-harness-env.ps1`, and `tests/harness-env.tests.ps1` (115/115 passed locally on 2026-07-14, including lock/source drift, fake-home activate/switch/prune, A→B→rollback A, unknown/.system preservation, and RequiredEnv linkage; `tests/harness-profile.tests.ps1` still 33/33). The env regression test and unified CLI smoke test run in the Windows validation workflow.
- A third latent `sync.ps1` defect surfaced during the first real-home activation and is fixed with a regression sentinel: `Test-Parity` skipped its managed-set filter when the set was empty, so unknown (ignored-never-deleted) OpenClaw dirs failed post-apply parity; the filter now applies whenever a managed set is provided. The first apply attempt stopped at that false positive after deploying correctly; the re-run passed cleanly.
- Two latent `sync.ps1` defects were fixed while wiring activation and are covered by the fake-home tests: an empty managed-skills manifest broke StrictMode (`Read-ManagedNames` now returns the HashSet intact; `Get-SyncPlan` allows an empty managed set), and the post-apply parity check now scopes Claude/Codex to their managed sets like OpenClaw, so ignored-never-deleted unknown live dirs no longer fail parity.
- Project Harness Profile real-project dry-run was exercised on this repository on 2026-06-30: status resolved `base` and `coding`, build generated ignored `.agent-harness/generated/` output, apply dry-run reported `AGENTS.md` skipped due missing markers, `.claude/settings.json` would update, and generated-only prompt output skipped. `tests/harness-profile.tests.ps1` passed 33/33.

## Sync status

- `scripts/sync.ps1` was run in default dry-run mode on 2026-06-30 after build and secret scan. It reported no prune actions and no unknown live skill directories for Claude, Codex, or OpenClaw.
- The 2026-06-30 dry-run plan was: Claude `+0 ~15 -0`; Codex `+2 ~21 -0`, with `.system` present and preserved; OpenClaw `+25 ~0 -0`.
- OpenClaw plugin dry-run reported 2 managed plugin installs pending and 90 unknown plugins ignored.
- The 2026-07-10 `env activate full -Apply` did use the gated real apply path and passed managed-scope parity at that time. No live apply was run for Phase 0; a fresh post-activation parity attestation is not recorded here.
- The 2026-07-13 reliability validation generated a fresh external sync plan: Claude `+0 ~0 =15 -0`, Codex `+0 ~1 =22 -0`, OpenClaw `+0 ~0 =25 -0`; Codex `.system` was reported preserved. The Codex `hatch-pet` content update remains unapplied pending explicit plan review and authorization.

## Known risks

- Project Harness Profiles are an MVP and should be treated as project-local only until a separately reviewed task expands the model.
- `MAGINA-LAPTOP` has a recorded real activation for the current Claude/Codex managed scope; `DESKTOP-3GMDAB7` remains dry-run-only, and other machines remain unverified.
- The active `full` environment intentionally leaves OpenClaw unchanged; OpenClaw's current live state must be evaluated separately from the environment activation record.
- Historical machine verification describes earlier baselines and must not be treated as proof of current live state.
- This checkout has a working pre-commit secret-scan hook, but the repo-local `post-merge`, `post-checkout`, and `post-rewrite` auto-sync hooks are not installed.
- Claude MCP application remains documented as a placeholder.
- Status can drift again if current facts are duplicated in README files instead of being maintained here.

## Next actions

1. Review and commit the Project Harness Profiles real-project profile/status update.
2. In a separate maintenance task, install or intentionally waive the missing repo-local auto-sync hooks without invoking an unreviewed live sync.
3. Review the 2026-06-30 sync dry-run plan before any live apply.
4. Apply sync only after the dry-run is reviewed and the mandatory backup path is confirmed.
5. Revalidate each managed machine and update this file with evidence-backed results.
6. Keep Project Harness Profiles project-local unless a future reviewed design explicitly adds global home switching or project-local skill installation.
7. For each machine that has not completed a real activation, run `env activate <name> -DryRun`, review the plan (especially the prune list) by hand, and confirm the backup root before `-Apply`. `MAGINA-LAPTOP` has already completed this first real activation; future changes still require the same review.
8. Integrating config deployment (config-pull) into `env activate` stays deferred until env-differentiated home config components exist; that integration needs its own review.
9. Before any new real-home environment apply or rollback, review the generated lock/status/plan and confirm the external backup reference; the Phase 4 implementation was validated only with fake homes in this task.
