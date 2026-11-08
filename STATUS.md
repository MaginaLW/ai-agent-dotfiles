# Project Status

Last updated: 2026-11-08.

This file holds only present-tense facts, open items and known boundaries. Update it by replacing
lines in place. Put dated task logs and evidence in `status/active/<task>.md`; when a task is
done, record its outcome here and delete the record (Git keeps it). Before trusting a commit or
CI run, check `git log` and the latest GitHub Actions run.

## Current state

- **Grok routing.** The Codex agreement template routes explicitly requested Grok work through agent-bridge and preserves its current schema, available engines and approval flow; it has no local Grok Build CLI fallback.
- **Current scope.** `skills-source/` is the only skill source. `build-skills.ps1` generates
  `claude/skills/` and `codex/skills/`; `deploy-skills.ps1` deploys one environment to the live
  Claude, Codex and ZCode roots. Generated output is ignored by Git; `full` contains every
  managed skill, while `work` is the daily set.
- **Skills and deployment.** There are 19 managed skills: 12 shared and 7 Codex-only. The
  2026-11-08 source cleanup retired `hatch-pet` and removed the custom brainstorming browser
  server. The last completed live deployment remains the earlier `full` Apply (3 updates,
  41 unchanged; post-Apply dry run 44 unchanged). A reviewed `work` dry-run now plans
  0 installs, 0 updates, 24 unchanged, 20 prunes and 0 unknowns; its live Apply awaits explicit
  owner authorization.
- **Skill effect evidence levels.** Skill-effect claims are classified as `deployed`, `loaded`,
  `applied`, `reused`, or `outcome-improved`; a higher level is not inferred from a lower one.
  Catalog discovery and installation do not prove behavior change, and one applied case does not
  prove long-run improvement. Current evidence places `session-learnings` at
  deployed/loaded/applied/reused, `tool-scope` at deployed/loaded/applied, and
  `approval-feedback` at deployed/loaded with historical Codex application; its current-revision
  and Claude/ZCode model-level effects remain unmeasured.
- **Policy centralization.** Generated skill roots, scan-input prefixes and the Codex live-root
  rule live in `scripts/repo-common.ps1`. Build, secret scan, syntax gate, doctor, deploy and
  repository validation consume those definitions; generated/legacy roots remain excluded from
  scans and untracked-output checks.
- **Fail-closed discovery.** `Get-SkillDirectories` returns an empty set only when the root is
  absent. Enumeration errors now stop the build instead of looking like an empty skill set.
- **Latest local verification.** The 2026-11-08 cleanup commit passed the CI-equivalent
  repository validation: syntax, pinned gitleaks verification, build, secret scan, doctor,
  manifest parity, all 13 local test suites, dangerous-file checks and clean-tree checks.
  Remote Validate remains a separate CI check.
- **Pinned gitleaks.** The lock pins gitleaks 8.30.0 by archive and executable SHA-256. The
  official GitHub Releases API fallback is used only after direct downloads fail and still
  passes both hash gates.
- **CI.** One `Validate` job runs `scripts/run-repository-validation.ps1` on push to `main`,
  pull requests and manual dispatch. GitHub Actions is the source of truth for the latest head;
  this file does not name a moving commit.
- **Finite windows and de-duplication.** Future proposals that need an expiry state one
  activation event, duration, latest activation condition and stop condition. Verification
  claims bind to a target, version, environment and stopping condition; delegated evidence is
  reused after inspection. These rules add no timer, ledger, background collector or automatic
  permission.
- **Status history.** The former dated journal is preserved in Git; this file now keeps only
  facts that still affect current decisions. Historical and removed documentation is indexed by
  [docs/HISTORY.md](docs/HISTORY.md).

## Open items

- The reviewed `work` deployment is waiting for an explicit owner Apply authorization. It would
  prune 20 previously deployed managed directories across Claude/Codex/ZCode, preserve the 24
  selected directories, create deploy backups, and never touch Codex `.system`. The unused
  home-only `claude-code-plugins` marketplace declaration also remains unchanged pending a
  separate explicit decision; the tracked official `codex@openai-codex` plugin is retained.
- The numbered one-interaction scoring revision is installed on all three platforms. The private
  ledger holds 20 real records (17 structured plus 3 manual; all Codex; 16 at 1, 4 at 0); at least
  three known records remain pending. They show repeated low interruption value and have produced
  concrete narrow proposals, one applied and published, but not a same-scope three-independent-task
  threshold or measured reduction. The last ledger write predates the current skill revision; no
  post-update feedback exists. No future approval is enabled.
- `approval-feedback` is installed globally on all three platforms. Codex catalog discovery,
  live-file loading and selection have fresh-context and partial thread evidence; Claude/ZCode
  model-level loading and long-run selection remain unverified because those clients are not in
  active use. Installation enables no automatic approval or standing merge policy.

## Known boundaries

- **Intentional Codex global agreement drift.** The live AGENTS file has personal agreements
  beyond the canonical template. A raw whole-file pull from the template would remove them;
  preserve and review these differences before any future config pull.
- **Intentional Claude config drift.** The personal notification override and home-only
  marketplace declaration are retained locally, outside the repository template. A raw
  whole-file pull would remove them; preserve them before any future pull.
- **Primary checkout is single-writer.** Parallel agent work uses a throwaway worktree or a
  separate checkout and integrates back serially; one full local validation run at a time
  ([AGENTS.md](AGENTS.md)).
- **Privacy history rewrite.** An exact-path rewrite redacted the 82 commits then on `main` and
  was published with force-with-lease; GitHub Support ran the server-side GC. `dd4014f` is the
  first rewritten commit; pre-rewrite SHAs resolve nowhere ([docs/HISTORY.md](docs/HISTORY.md)).
- **Old clones must re-clone.** A clone that still resolves the pre-rewrite chain must export
  unique local work and re-clone; merging or rebasing the old chain reintroduces purged objects.
- **Deploy state is per machine.** deploy-skills prunes only directories recorded in its state
  file. Without that file the first run prunes nothing, and directories from an older setup show
  as unknown until `-Retire` names them.
- **ZCode user-level skills are deploy-managed.** `~/.zcode/skills` receives the Claude
  generated projection through deploy-skills; it has no generated root or manifest of its own.
- **Codex catalog refresh and loaded skill bodies.** Codex detects skill changes automatically
  and may need a restart when an update does not appear. A conversation that already loaded an
  old `SKILL.md` can retain that body; `approval-feedback` requires rereading the current file
  when its version is unknown.
- **Out of scope.** Machine-private configuration including Codex `config.toml` and private
  `.env` files, credentials, sessions and caches are outside sync scope. Machine-private
  evidence under `tmp/` and external private roots is not committed.

## Inventory and scope

| Scope | Canonical | Claude | Codex |
|---|---:|---:|---:|
| Shared | 12 | 12 | 12 |
| Codex-only (Claude-only is empty) | 7 | - | 7 |
| Managed total | 19 | 12 | 19 |

- **Shared skills:** approval-feedback, boring-engineering, brainstorming, git-review,
  meng-cmame-writing, paper-polish, session-learnings, subagent-driven-development,
  systematic-debugging, tool-scope, verification-before-completion, writing-plans.
- **Codex-only skills:** chatgpt-apps, cli-creator, coderabbit-review, define-goal,
  security-best-practices, security-ownership-map, security-threat-model.
- **Environments** (Claude/Codex/Zcode): `minimal` 1/1/1, `work` 8/8/8,
  `full` 12/19/12. Unselected unknown live directories are preserved, and Codex `.system` is
  never managed.
- **Retired:** the transactional live-sync engine, its hooks/runner/schemas/tests; the MCP
  registration subsystem; OpenClaw/OpenCode; ArkCLI-managed skills; the legacy local
  `hatch-pet` v1 packaging workflow; the custom brainstorming browser-companion server.
- **Integrations.** ZCode maintains this repository through `AGENTS.md` and is a deployment
  target through the Claude projection. The harness-model feedback-loop pilot is paused; one
  remote VPS pilot remains active.
- **Skill retirement.** Deleting a skill's source leaves an old live directory as unknown;
  `-Retire <name>` removes it after review. See
  [docs/README.md §5](docs/README.md#5-修改已有-skill-的流程).

## History

- The dated status journal, live-safety record, ZCode feedback-loop runs, removed engine,
  import/merge pipeline and old design/plan documents are in Git history. `docs/HISTORY.md`
  names the relevant commits and how to read them.
