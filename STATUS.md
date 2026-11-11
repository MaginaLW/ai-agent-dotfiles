# Project Status

Last updated: 2026-11-12.

This file holds only present-tense facts, open items and known boundaries. Update it by replacing
lines in place. Put dated task logs and evidence in `status/active/<task>.md`; when a task is
done, record its outcome here and delete the record (Git keeps it). Before trusting a commit or
CI run, check `git log` and the latest GitHub Actions run.

## Current state

- **Claude retirement.** The source selection for `work` is Claude/Codex/ZCode 0/9/8.
  Config status/pull/push and combined deployment default to Codex only. The shared
  `base`/`coding` and this repository profile target Codex without automatic ClaudeSettings.
  Root `CLAUDE.md` and `.claude/settings.json` developer entries are removed. The Claude
  generated skills remain the ZCode projection source; distributable templates and
  explicit Claude tools stay compatible. The old full-environment exception is retired,
  and the standing `work` grant covers Codex/ZCode only. This source change does not
  remove live Claude state or perform a live deployment.
  The first retirement candidate passed local syntax, build, pinned secret scan and all
  14 isolated suites, including the work-selection fixture and Codex-only inheritance.
  After local entry removal, syntax, repository-policy, doctor and pinned secret-scan
  checks pass. The final exact-head Validate run remains the merge gate.
  Default config dry-run is Codex-only and in sync; no live Apply was performed.

- **Proactive Git approval requests.** The Codex global agreement source explicitly requests
  missing commit, push or merge permission once the diff and checks are reviewable; it reuses
  explicit existing grants instead of ending with an unexplained uncommitted/unmerged result.
  The requested Codex-only managed-block deployment completed, its readback is in sync, and
  personal text outside the block is unchanged. The owner approved A04 for this change's
  commit/push and sequential integration of PRs #3 and #4 after current CI passes; verify
  their actual merge state and current main ref rather than inferring it from this grant.
- **Approval-feedback project grants.** The source immediately proposes project-level standing
  permission after relevant blocking feedback, with an exact rule diff, reasons, risks, scope,
  inheritance and revocation. There is no multi-task score threshold. Owner approval is still
  required to adopt a specific grant; subsequent matching tasks reuse the current formal rule.
  Existing permission is used directly when no expansion is needed. An independent read-only
  pass covered immediate proposals, inherited permission, absent formal rules, an unapproved
  grant and execution misreads; it does not establish real cross-task behavior improvement.
  Repeated expansion events also trigger consolidation of related permission files: clarify
  categories, remove superseded requirements and repair inheritance; new authority still
  requires owner approval. The owner's final clarification permits permission-neutral cleanup
  with notification; new or permanent substantive permission changes require an exact diff,
  reasons and risks for approval. Approved scopes are inherited without repeated approval.
  The usage manual records this distinction; dated design/plan documents are historical.
  The owner approved A02 and the exact standing `work` skills-only
  grant is now in AGENTS.md Skill rules 10, with its task-entry cross-reference clarified.
  Skill validation, build, secret scan, diff checks and independent review pass. The authorized
  deployment updated only the three approval-feedback copies; 22 other skills were unchanged.
  All 12 changed live files match generated output, three backups exist and the post-Apply
  dry run reports 25 unchanged, with no updates, installs, prunes or unknowns. No config Apply
  was performed. Tasks must load the current approved project rule before relying on it;
  approval history alone does not establish inheritance. Future real cross-task improvement
  remains unmeasured.
- **CLI and deployment experience.** Group help works as `help <group>` and `<group> help`
  for config/env/profile/skills; unavailable Apply records explain their fixed reason without
  changing the JSON contract. Doctor lists known deployment blockers separately from warnings.
  The README starts with install/update/inspect/recover paths. Skill plans show relative file
  additions/changes/removals, recorded-to-target environments and prune reasons, reusing the
  existing comparison. Combined Apply runs both planners before live writes, reuses the skills
  build/scan and retains config's pre-write scan. Preflight failures write no live/state data;
  runtime failures remain non-atomic. Recovery guidance and natural-task effect checks are in
  the usage manual. No live Apply was performed for these script/documentation changes.
- **Subagent policy.** Codex agreements specify a whole-root concurrent allowance of 50
  descendants with the lead excluded, no lifetime creation-count cap, human approval for a
  higher task/stage limit, and the host's effective open/active limits. The shared execution
  skill uses active expansion and staged minimal context without a platform-specific count.
  The previous `work` deployment used Claude/Codex/ZCode 8/9/8; `full` is unchanged. Build, secret scan,
  skill validation, generated parity and independent review pass. The source is integrated into
  `main` at `a104f9f`; the Validate run `43027745386` completed successfully. The live `work`
  deployment and the Codex managed-block config update were verified (post-deploy dry run:
  25 unchanged; config in sync). `README.md` and the usage manual document the asymmetric
  Codex `work` selection and the skill's authority boundary.
- **Grok routing.** The Codex agreement template routes explicitly requested Grok work through agent-bridge and preserves its current schema, available engines and approval flow; it has no local Grok Build CLI fallback.
- **Codex push approval.** Codex Guardian V2 treats `git push` as data egress and trusts only a verified private user/org repository. The global Codex instructions now require a read-only destination check before an escalated push, require that evidence in the justification, and allow one evidence-backed retry after a denial; public destinations are limited to repositories explicitly authorized to publish their own content.
- **Current scope.** `skills-source/` is the only skill source. `build-skills.ps1` generates
  `claude/skills/` and `codex/skills/`; `deploy-skills.ps1` deploys one environment to the live
  Claude, Codex and ZCode roots. Generated output is ignored by Git; `full` contains every
  managed skill, while `work` is the daily set.
- **Combined deploy and config merge.** `deploy.ps1` runs the selected skills environment and
  `config-pull` in one dry-run/apply entry point; the unified `sync` and `env deploy` routes use
  it. Claude `settings.json` uses structured object merge (home-only fields survive, arrays
  replace as a whole), Codex `AGENTS.md` updates only its `AI-AGENT-DOTFILES` managed block, and
  config-push captures only that block body. The 2026-11-10 live `work` Apply left all 24 skills
  unchanged and added the block to the live Codex file; the post-Apply config status is in-sync.
- **Historical approval-feedback deployment exception.** The former three-platform full
  exception is retired in AGENTS.md Skill rules 9. Its earlier approval and deployment
  readbacks remain historical evidence; current work updates use the Codex/ZCode grant.
- **Skills and deployment.** There are 19 managed skills: 12 shared and 7 Codex-only. The
  2026-11-08 source cleanup retired `hatch-pet` and removed the custom brainstorming browser
  server. The `work` live Apply completed with 0 installs, 0 updates, 24 unchanged, 20 prunes
  and 0 unknowns; its post-Apply dry run reported 24 unchanged. That historical deployment
  exposed the same eight-skill daily set on three platforms; Codex `.system` remains untouched.
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
- **Latest local verification.** The 2026-11-11 CLI/deployment changes passed the full repository
  validation: PowerShell syntax, pinned gitleaks, build, secret scan, doctor, manifest parity,
  all 14 local test suites, dangerous-file checks and the clean-tree gate. Remote Validate is the
  separate CI gate for the pushed head.
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

- The numbered one-interaction scoring revision is installed on all three platforms. The private
  ledger holds 23 real records (20 structured plus 3 manual; all Codex; 19 at 1, 4 at 0) across
  11 task references. The three retained local pending inputs were reconciled on 2026-11-10 with
  source attribution and readback; no further pending input was found in the inspected local
  evidence. Three independent Codex tasks now cover the same core action, a full-environment
  approval-feedback live update, with scores of 1 and no 2/3 or permission conflict. That
  threshold led to the owner-approved narrow exception in Skill rules 9; no other future
  approval is enabled.
  The feedback still shows repeated low interruption value and has produced concrete narrow
  proposals, one applied and published, but no measured reduction. The current skill revision is
  `3aa4391`; its source matches all three live roots, and the Codex managed block is in-sync. A
  fresh Codex task on 2026-11-11 discovered and read the current body, but had no comparable
  approval opportunity, so the current-revision S/Q effect remains unmeasured (U). The next
  natural checkpoint is the next real Codex approval request.
- `approval-feedback` is installed globally on all three platforms. Codex catalog discovery,
  live-file loading and selection have fresh-context and partial thread evidence; Claude/ZCode
  model-level loading and long-run selection remain unverified because those clients are not in
  active use. Installation enables no automatic approval or standing merge policy.

## Known boundaries

- **Codex global agreements use a managed block.** `codex/AGENTS.md` is the canonical body; the
  live Codex file wraps it in `<!-- BEGIN/END AI-AGENT-DOTFILES: codex/AGENTS.md -->` markers.
  Content outside the block is local and preserved, and config-status compares the block body.
- **Intentional Claude config drift.** The personal `agentPushNotifEnabled` override remains
  home-only and is preserved by structured merge. The unused `claude-code-plugins` marketplace
  declaration was removed on 2026-11-10; the tracked `openai-codex` declaration remains.
- **Combined deploy is not atomic.** The skills stage and config stage share one command and
  authorization boundary but do not share a transaction. A config failure leaves completed skill
  changes in place; each stage keeps its own backups and rollback behavior.
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
- **Environments** (Claude/Codex/Zcode): `minimal` 1/1/1, `work` 0/9/8,
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
