# Project Status

Last updated: 2026-10-10.

This file holds only present-tense facts, open items and known boundaries. Update it by replacing
lines in place. Put dated task logs and evidence in `status/active/<task>.md`; when a task is
done, record its outcome here and delete the record (Git keeps it). Before trusting a commit or
CI run named here, check `git log` and the latest GitHub Actions run.

## Current state

- **Product.** `skills-source/` is built by `scripts/build-skills.ps1` into the Claude, Codex and
  Reasonix generated roots. `scripts/deploy-skills.ps1 -Environment <name>` deploys one
  environment's selection to the three live roots: dry run unless `-Apply`, prune only what it
  deployed before or what `-Retire` names, unknown directories and Codex `.system` untouched,
  backups and deploy state under `%LOCALAPPDATA%\ai-agent-dotfiles.deploy`. Skills are added to
  `skills-source/` by hand or with `scripts/promote-skill.ps1`. Config-sync and project harness
  profiles keep their behavior. Every live Apply needs the owner's explicit authorization.
- **Second simplification (2026-10-10).** Removed the skills import/merge pipeline (replaced by
  `promote-skill.ps1`), the documentation-wording pins and the guide code-block checker, the
  build run reports, and the dated status journals (all in Git history). doctor now checks only
  the current product. Project harness profiles were reimplemented (1656 -> 741 script lines)
  with byte-identical results for this repo's profile and a copy of PINN-tFORM's; apply now
  honors a component's declared `Source`, and plan.json is byte-stable.
- **Engine removal (merged to `main` 2026-10-10).** The transactional live-sync engine is gone:
  plan-bound sync and retirement, canonical and live recovery, environment
  activate/rollback/authority, the task-skill overlay, backup receipts, the approved runner and
  Git hooks, schemas, the sandbox host, the live-safety policy and interlock, and the CI shards.
  The last commit that still has it is `c011fb4` ([docs/HISTORY.md](docs/HISTORY.md)).
- **First onboarded machine (cut over 2026-10-09, owner-authorized).** `deploy-skills.ps1
  -Environment work -Apply` now manages it. The run found all six managed directories unchanged
  (`boring-engineering`, `systematic-debugging` on Claude, Codex and Reasonix), left the one
  unknown Codex directory and Codex `.system` alone, and wrote only its state file under
  `%LOCALAPPDATA%\ai-agent-dotfiles.deploy`.
- **Old machine state (removed 2026-10-10).** The old engine's Git hooks, Git-private runner
  and canonical state, canonical recovery root, control base, receipt backups and bootstrap lock
  were archived on 2026-10-09 and deleted by the owner on 2026-10-10, together with the stale
  engine-era worktrees and the local `wt-p4g` branch. Nothing on this machine refers to them.
- **CI.** One `Validate` job runs `scripts/run-repository-validation.ps1` on push to `main`,
  pull requests and manual dispatch (about 3 minutes; first green run on `24114ef`).
- **Other machines.** None has been set up yet. Some may still carry pre-repository or old-engine
  deployments; their dry run shows those directories as unknown. Onboarding starts only after the
  owner names a target ([docs/ONBOARD_NEW_MACHINE.md](docs/ONBOARD_NEW_MACHINE.md)).

## Open items

1. **Owner:** name any further machine before onboarding starts.
2. **Owner:** adopt, defer or drop the post-release packages F1 (CI evidence persistence),
   F2 (config pull/push boundary), F3 (platform capability registry) and F4 (module dedup).
3. **Owner:** decide whether to keep the ZCode pilot ([docs/ZCODE.md](docs/ZCODE.md)).
4. **Owner, low priority:**
   - Which commit carries the privacy-rewrite content.
   - Other clones should re-clone or rebase instead of merging the old history.
   - Whether one agent at a time owns this repository; concurrent agents have collided before.

## Known boundaries

- **Deploy state is per machine.** deploy-skills prunes only directories recorded in its state
  file. On a machine without that file the first run prunes nothing, and directories an older
  setup deployed show as unknown until `-Retire` names them.
- **Codex catalog refresh.** Codex may need a new task or thread before a changed skill set shows.
- **Out of scope.** Codex `config.toml`, Reasonix `config.toml`/`.env`, credentials, sessions and
  caches are outside sync scope. Machine-private evidence (`tmp/` and external private roots) is
  not committed.

## Inventory and scope

| Scope | Canonical | Claude | Codex | Reasonix |
|---|---:|---:|---:|---:|
| Shared | 8 | 8 | 8 | 8 |
| Codex-only (Claude-only and Reasonix-only are empty) | 8 | - | 8 | - |
| Managed total | 16 | 8 | 16 | 8 |

- **Shared skills:** boring-engineering, brainstorming, git-review, paper-polish,
  subagent-driven-development, systematic-debugging, verification-before-completion, writing-plans.
- **Codex-only skills:** chatgpt-apps, cli-creator, coderabbit-review, define-goal, hatch-pet,
  security-best-practices, security-ownership-map, security-threat-model.
- **Environments** (Claude/Codex/Reasonix): `minimal` 1/1/1, `work` 2/2/2
  (`boring-engineering`, `systematic-debugging`), `full` 8/16/8. Unknown live directories are
  preserved, and Codex `.system` is never managed.
- **Retired:**
  - the transactional live-sync engine, its hooks, runner, schemas and tests (2026-10-09);
  - the MCP registration subsystem (no live MCP config was changed);
  - OpenClaw/OpenCode;
  - ArkCLI-managed skills.
- **Integrations.** ZCode is a project-instruction integration, not a deployment target. The
  harness-model feedback loop runs only for a substantive issue or an explicit request
  ([docs/ZCODE.md](docs/ZCODE.md)).
- **Skill retirement.** Deleting a skill's source leaves an old live directory that deploy-skills
  never deployed as unknown and preserved. `-Retire <name>` removes it; see
  [docs/README.md §5](docs/README.md#5-修改已有-skill-的流程).

## History

- The dated status journal, the live-safety record, the ZCode feedback-loop runs, the removed
  engine, the import/merge pipeline and the old design and plan docs are all in Git history;
  [docs/HISTORY.md](docs/HISTORY.md) names the commits and how to read them.
