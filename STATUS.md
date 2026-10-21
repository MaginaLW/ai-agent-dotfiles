# Project Status

Last updated: 2026-10-21.

This file holds only present-tense facts, open items and known boundaries. Update it by replacing
lines in place. Put dated task logs and evidence in `status/active/<task>.md`; when a task is
done, record its outcome here and delete the record (Git keeps it). Before trusting a commit or
CI run named here, check `git log` and the latest GitHub Actions run.

## Current state

- **Product.** `skills-source/` is built by `scripts/build-skills.ps1` into the Claude, Codex and
  Reasonix generated roots. `scripts/deploy-skills.ps1 -Environment <name>` deploys one
  environment's selection to the four live roots: dry run unless `-Apply`, prune only what it
  deployed before or what `-Retire` names, unknown directories and Codex `.system` untouched,
  backups and deploy state under `%LOCALAPPDATA%\ai-agent-dotfiles.deploy`. `~/.zcode/skills` is
  a projection platform: it deploys from the Claude generated output and has no generated root or
  manifest of its own. Skills are added to
  `skills-source/` by hand or with `scripts/promote-skill.ps1`. Config-pull backs up overwrites
  and attempts rollback after a caught copy failure; project harness profiles write only
  project-local allowlisted targets. Every live Apply needs the owner's explicit authorization.
- **Second simplification (2026-10-10).** Removed the skills import/merge pipeline (replaced by
  `promote-skill.ps1`), the documentation-wording pins and the guide code-block checker, the
  build run reports, and the dated status journals (all in Git history). doctor now checks only
  the current product. Project harness profiles were reimplemented (1656 -> 741 script lines)
  with byte-identical results for this repo's profile and a copy of PINN-tFORM's; apply now
  honors a component's declared `Source`, and plan.json is byte-stable. Follow-up: the leftover
  `envs/`, `reports/`, `imports/` and `state/` ignore rules and scan exclusions were removed
  (owner-approved), `run-tests.ps1` became one self-contained script without the JSON evidence
  summary (per-suite budgets kept), and the post-release packages F1-F4 were dropped by the owner.
  Third pass: the profile schema lost `Future`, `Requires` and `Conflicts` (buckets are optional),
  the unused `multi-platform` profile and its four components were removed, config-sync shares its
  whitelist loading in `config-common.ps1`, and the union `managed-skills.txt` manifest is gone.
  PINN-tFORM's project profile was updated to match on 2026-10-10 (owner-authorized): dropping the
  dead `Future` block and the empty buckets restored status/build/apply there with byte-identical
  generated content (commit `8a43367` in that repository).
- **Fourth optimization pass (2026-10-13, grok-reviewed).** `scripts/repo-common.ps1` is the
  single policy source (protected Reasonix files, binary extensions, drive/UNC patterns) and
  carries the shared secret-scan gate; config-pull/push share their plan pipeline in
  `config-common.ps1`. The syntax-gate suite's inverted child timeout is fixed, every suite that
  waits on gitleaks has a budget above that wait, and pinned-tool/build-skills gained
  failure-path suites (10 -> 12 suites, budget 990 -> 1380 s). docs/README.md merged its three
  pointer sections (§1-§14 now) and its environment schema matches the code; the env files
  dropped the dead `Profile` key.
- **Fourth-pass follow-ups (2026-10-14).** CI installs the pinned gitleaks once (the validation
  gate re-verifies), runs with a 35-minute timeout and cancels superseded runs, and the
  pinned-tool download retries with a timeout. deploy-skills hashes and reparse-checks each tree
  in one walk. promote-skill lost its redundant `-DryRun` switch (the unified CLI still accepts
  the spelling and strips it). Fatal script errors go to stderr, and scan-secrets is split into
  named passes (input copy, gitleaks, fallback, JSON report). A final cleanup removed the dead
  code the review listed (unused return property and parameter, unread lock fields, the misleading
  fixture profile), the ignore lines covered by broader patterns, and unified backup stamps on
  UTC, git ls-files UTF-8 decoding in the syntax gate, and the fallback skip list on the single
  exclusion source.
- **Fifth optimization pass (2026-10-16).** Scan JSON preserves non-blocking hint counts
  on success and gitleaks-only failure. The dangerous-tracked-file predicate has boundary tests;
  pull and profile apply have source-scan failure fixtures. Pull recovery includes attempted
  writes, warns on individual restore failures and rethrows the original copy error; it is
  best-effort, not recovery from process termination. Backup stamps include milliseconds, push
  retains scan failure details, and failed CLI tests print their retained workspace. Redundant
  PS7 checks and test file-writer copies are removed. The profile schema no longer accepts the
  unused `RequiredEnv` key; the known external project profile was checked before its removal.
  Local full repository validation completed all 12 suites. Merge acceptance still requires
  a green `Validate` run at the final PR head; local checks do not replace CI.
- **Branch disposition (2026-10-18).** The local branches `codex/fifth-dangerous-paths`,
  `codex/fifth-profile-docs` and `codex/fifth-scan-report` are deleted after `git cherry -v main`
  reported only `-` lines. `codex/fifth-optimization-20261016` is deleted locally and on
  `origin`; `c0d8e94f48087eeaed027409bcbb8cc59138ab07` is an ancestor of `main`, and the remote
  delete had its own owner authorization. Disposing of a proven task branch is part of the
  parallel-write paragraph in `AGENTS.md`.
- **Branch disposition follow-up (2026-10-21).** The track-B task branch
  `codex/track-b-20261018` (tip `fed722b`, already an ancestor of `main` from the
  fast-forward merge) is deleted after the owner authorized it; the proof was re-run at
  execution time against the recorded full tip SHA (`update-ref -d` with expected SHA).
- **Eighth-round optimization (2026-10-21, Grok-decided).** Five parallel read-only lanes
  (three subagents plus two Grok worktree reviews) produced candidates; the owner delegated
  the selection to a Grok decision lane whose factual premises the main agent re-verified.
  Twelve items landed in six commits: scan-secrets fails closed when `.gitleaks.toml` is
  missing and always passes `--config`; build-skills refuses reparse points under the
  generated roots before the wipe; build-harness-profile always replaces the generated root
  after confirming it is a plain directory (`-Clean` is a compatibility no-op) so the
  manifest no longer carries stale files; apply-harness-profile lost the dead `-BackupRoot`
  parameter; five test-coverage gaps closed (config-sync directory round-trip with
  `*.local.json` exclusion and a Reasonix status case, the home-write refusal, an exact
  settings.json allow assertion, claude-only/reasonix-only landing, a positive
  unknown-parameter fixture) and the `.gitignore` comment pin is gone; docs name the
  config-pull backup root, the config-push staging directory, `CommonExcludedItems` and the
  Rule skip semantics. Excluded by the decision: fail-fast on `-Retire` of a selected skill
  (documented §5 behavior; enforcement would block the legal cross-platform retirement),
  generated-root prefix single-sourcing (three different literal shapes, no drift) and
  copying Reasonix `ExcludedItems` into the docs (the whitelist is the source). Working
  evidence is machine-local under ignored `tmp/grok21/` and
  `tmp/optimization-plan-20261021-findings.md`.
- **Seventh round: track-B de-complexity (2026-10-18).** Entry points lost two unused knobs:
  `scan-secrets.ps1 -ScannerConfigPath` (the scanner config is always the repository
  `.gitleaks.toml`) and `install-gitleaks.ps1 -CacheRoot`; neither had an in-repo caller.
  `promote-skill.ps1` no longer checks `.system` separately (the name regex rejects it), the
  harness profile key lists are defined once, the syntax-gate meta checks are table-driven,
  the runner suite no longer duplicates the budgets invariant that `run-tests.ps1` enforces
  before any suite starts, and three suites delegate their local process/file wrappers to
  `tests/helpers/test-common.ps1`. `docs/HISTORY.md` and `STATUS.md` now name the real last
  commits that still contain the removed engine (`9793fde`), the dated journals (`a1e3115`),
  the import pipeline (`d393999`) and the multi-platform profile (`e8ef4c2`). The full local
  suite and repository validation passed before the merge; the work is merged to `main` and
  pushed (fast-forward `0f77b96..fed722b`) with Validate run 39088767066 green.
- **Claude home config (2026-10-16, owner-authorized).** One `config-pull` Apply synchronized
  `settings.json` from a private candidate built from the repository template plus the existing
  Boolean `agentPushNotifEnabled` override. The candidate was scanned and dry-run reviewed;
  target and original-backup hashes matched, and its post-Apply plan is empty. The canonical
  template remains unchanged, so a raw repository pull still reports intentional drift for
  this personal field and must not remove it. Other platforms and live skills were not applied;
  client loading was not tested. The private receipt and backup pointer are retained under
  ignored `tmp/live-apply-20261016/`.
- **Engine removal (merged to `main` 2026-10-10).** The transactional live-sync engine is gone:
  plan-bound sync and retirement, canonical and live recovery, environment
  activate/rollback/authority, the task-skill overlay, backup receipts, the approved runner and
  Git hooks, schemas, the sandbox host, the live-safety policy and interlock, and the CI shards.
  The last commit that still has it is `9793fde` ([docs/HISTORY.md](docs/HISTORY.md)).
- **First onboarded machine (cut over 2026-10-09, owner-authorized).** `deploy-skills.ps1
  -Environment work -Apply` now manages it. The run found all six managed directories unchanged
  (`boring-engineering`, `systematic-debugging` on Claude, Codex and Reasonix), left the one
  unknown Codex directory and Codex `.system` alone, and wrote only its state file under
  `%LOCALAPPDATA%\ai-agent-dotfiles.deploy`. That state file later disappeared (cause unknown);
  an owner-authorized `work` Apply on 2026-10-14 rebuilt it and refreshed the three live
  `boring-engineering` directories to LF, because the primary working tree still carried CRLF
  copies from before the `.gitattributes` `eol=lf` rule and any fresh checkout built different
  bytes. Generated output and the managed live directories are LF again, with the pre-change
  copies in the deploy-skills backups; Codex `.system` and unknown directories keep their
  original bytes.
- **Old machine state (removed 2026-10-10).** The old engine's Git hooks, Git-private runner
  and canonical state, canonical recovery root, control base, receipt backups and bootstrap lock
  were archived on 2026-10-09 and deleted by the owner on 2026-10-10, together with the stale
  engine-era worktrees and the local `wt-p4g` branch. Nothing on this machine refers to them;
  the `tmp/archive/engine-20261007` evidence folder survived that cleanup and was removed on
  2026-10-14 after a byte-verified copy went to
  `%LOCALAPPDATA%\ai-agent-dotfiles.deploy\archives\engine-20261007`.
- **CI.** One `Validate` job runs `scripts/run-repository-validation.ps1` on push to `main`,
  pull requests and manual dispatch (about 3 minutes; first green run on `24114ef`).
- **Other machines.** None has been set up yet. Some may still carry pre-repository or old-engine
  deployments; their dry run shows those directories as unknown. Onboarding starts only after the
  owner names a target ([docs/ONBOARD_NEW_MACHINE.md](docs/ONBOARD_NEW_MACHINE.md)). The owner
  confirmed on 2026-10-13 that no further machine is planned for now.

## Open items

- None.

## Known boundaries

- **Primary checkout is single-writer.** Parallel agent work uses a throwaway worktree or a
  separate checkout and integrates back serially; one full local validation run at a time
  ([AGENTS.md](AGENTS.md), decided 2026-10-13).
- **Privacy history rewrite (2026-08-25).** An exact-path rewrite redacted the 82 commits then on
  `main` (four Reasonix desktop-state paths removed, historical STATUS.md redacted) and was
  published with force-with-lease; GitHub Support then ran the server-side GC (closed by
  `8a70ec0`). `dd4014f` is the first rewritten commit and carries the rewritten content; the
  pre-rewrite SHAs resolve nowhere ([docs/HISTORY.md](docs/HISTORY.md)).
- **Old clones must re-clone.** A clone that still resolves the pre-rewrite chain must export its
  unique local work and re-clone; merging or rebasing the old chain onto `origin/main`
  reintroduces the purged objects.
- **Deploy state is per machine.** deploy-skills prunes only directories recorded in its state
  file. On a machine without that file the first run prunes nothing, and directories an older
  setup deployed show as unknown until `-Retire` names them.
- **ZCode user-level skills are deploy-managed.** `~/.zcode/skills` held hand-copied
  `boring-engineering` and `systematic-debugging` until 2026-10-14, when the Zcode projection
  platform first deployed there (the manual `boring-engineering` copy was CRLF and was replaced
  through the normal update path).
- **Codex catalog refresh.** Codex may need a new task or thread before a changed skill set shows.
- **Out of scope.** Codex `config.toml`, Reasonix `config.toml`/`.env`, credentials, sessions and
  caches are outside sync scope. Machine-private evidence (`tmp/` and external private roots) is
  not committed. Historical and current review/test evidence in `tmp/` is retained; no archive
  migration or deletion is part of the fifth pass.

## Inventory and scope

| Scope | Canonical | Claude | Codex | Reasonix |
|---|---:|---:|---:|---:|
| Shared | 9 | 9 | 9 | 9 |
| Codex-only (Claude-only and Reasonix-only are empty) | 8 | - | 8 | - |
| Managed total | 17 | 9 | 17 | 9 |

- **Shared skills:** boring-engineering, brainstorming, git-review, meng-cmame-writing,
  paper-polish, subagent-driven-development, systematic-debugging, verification-before-completion,
  writing-plans.
- **Codex-only skills:** chatgpt-apps, cli-creator, coderabbit-review, define-goal, hatch-pet,
  security-best-practices, security-ownership-map, security-threat-model.
- **Environments** (Claude/Codex/Reasonix/Zcode): `minimal` 1/1/1/1, `work` 2/2/2/2
  (`boring-engineering`, `systematic-debugging`), `full` 9/17/9/9. Unknown live directories are
  preserved, and Codex `.system` is never managed.
- **Retired:**
  - the transactional live-sync engine, its hooks, runner, schemas and tests (2026-10-09);
  - the MCP registration subsystem (no live MCP config was changed);
  - OpenClaw/OpenCode;
  - ArkCLI-managed skills.
- **Integrations.** ZCode is used to maintain this repository through `AGENTS.md` and, since
  2026-10-14, is also a deployment target: deploy-skills manages `~/.zcode/skills` through the
  Zcode projection platform (Claude generated output)
  ([docs/ZCODE.md](docs/ZCODE.md)). This repository's harness-model
  feedback-loop pilot is paused (owner decision 2026-10-10); one remote VPS pilot remains active.
- **Skill retirement.** Deleting a skill's source leaves an old live directory that deploy-skills
  never deployed as unknown and preserved. `-Retire <name>` removes it; see
  [docs/README.md §5](docs/README.md#5-修改已有-skill-的流程).

## History

- The dated status journal, the live-safety record, the ZCode feedback-loop runs, the removed
  engine, the import/merge pipeline and the old design and plan docs are all in Git history;
  [docs/HISTORY.md](docs/HISTORY.md) names the commits and how to read them.
