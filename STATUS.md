# Project Status

Last updated: 2026-06-29

This is the single global status file for the repository. Update it in place instead of creating additional overall status reports. Current task-level work belongs in [`status/active/`](status/active/); completed task reports belong in [`status/archived/`](status/archived/).

## Project purpose

Maintain one conservative, auditable source for Claude, Codex, and OpenClaw skills and selected harness configuration across multiple machines. The repository builds platform-specific runtime output, scans for secrets, backs up live state before changes, and performs manifest-scoped synchronization without whole-directory mirroring.

## Current phase

Operations hardening plus the first Project Harness Profiles MVP. Skill build, backup, secret scanning, manifest-scoped sync, OpenClaw plugin desired-state management, repo-local auto-sync hooks, whitelist-scoped harness config status/pull/push, minimal Windows GitHub Actions validation, and project-local harness profile generation/apply scripts are implemented. Project Harness Profiles are first-version and project-local only: they generate `.agent-harness/generated/` under a target project and `apply-harness-profile.ps1 -Apply` writes only project-local allowlist output.

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
- `STATUS.md` is the global status record. `status/active/` contains only current task records; completed task records move to `status/archived/`.
- `reports/*.md` contains machine- and run-specific build/sync reports and is Git-ignored; only `reports/README.md` is tracked. Reports must contain metadata and skill names only, never backup contents or sensitive values.

## Machines

| Machine | Documented state |
|---|---|
| `redacted-device` | Previously verified for the Claude/Codex baseline; not revalidated during the 2026-06-20 status refactor. |
| `MAGINA-LAPTOP` | Previously verified for the Claude/Codex baseline. The last documented OpenClaw check used dry-run and fake-home apply; no real OpenClaw live apply was recorded. |
| Other machines | Run `bootstrap.ps1` once after cloning to install repo-local hooks and enter the guarded sync flow. |

## Build / scan status

- `.github/workflows/validate.yml` validates pushes, pull requests, and manual runs on `windows-latest`: it runs doctor, secret scan, build reproducibility checks, Project Harness Profile regression tests, and a tracked dangerous-file policy check without sync or live-skill changes.
- Current manifests describe Claude **15**, Codex **23**, and OpenClaw **25** managed skills.
- Repository-local generated output observed before this refactor: Claude **15**, Codex **21**, OpenClaw output directory absent.
- Codex generated output is missing `systematic-debugging` and `writing-skills`; OpenClaw generated output needs regeneration.
- Build was not run during this status-only change because generated output is explicitly out of scope.
- Secret scan passed on 2026-06-20 with no blocking findings; keyword hints were non-blocking.
- Project Harness Profile MVP scripts and tests are present: `scripts/harness-profile-common.ps1`, `scripts/status-harness-profile.ps1`, `scripts/build-harness-profile.ps1`, `scripts/apply-harness-profile.ps1`, and `tests/harness-profile.tests.ps1`; the regression test is part of the Windows validation workflow.

## Sync status

- No sync command or live-skill operation was run during the 2026-06-20 status refactor.
- The last documented live baseline predates the current Codex/OpenClaw manifest counts, so current live parity is not asserted here.
- `scripts/sync.ps1` remains dry-run by default; `-Apply` was not used.

## Known risks

- Generated Codex and OpenClaw output is not currently aligned with the manifests.
- Project Harness Profiles are an MVP and should be treated as project-local only until a separately reviewed task expands the model.
- Live-machine parity has not been revalidated after the managed counts increased to 15/23/25.
- Historical machine verification describes earlier baselines and must not be treated as proof of current live state.
- This checkout has a working pre-commit secret-scan hook, but the repo-local `post-merge`, `post-checkout`, and `post-rewrite` auto-sync hooks are not installed.
- Claude MCP application remains documented as a placeholder.
- Status can drift again if current facts are duplicated in README files instead of being maintained here.

## Next actions

1. Review and commit the Project Harness Profiles documentation update.
2. In a separate maintenance task, install or intentionally waive the missing repo-local auto-sync hooks without invoking an unreviewed live sync.
3. In a separately reviewed skill-management task, run build, secret scan, and sync dry-run to reconcile generated output and inspect the live plan.
4. Apply sync only after the dry-run is reviewed and the mandatory backup path is confirmed.
5. Revalidate each managed machine and update this file with evidence-backed results.
6. Keep Project Harness Profiles project-local unless a future reviewed design explicitly adds global home switching or project-local skill installation.
