# Project Status

Last updated: 2026-11-14.

This file holds only present-tense facts, open items and known boundaries. Update it by replacing
lines in place. Put dated task logs and evidence in `status/active/<task>.md`; when a task is
done, record its outcome here and delete the record (Git keeps it). Before trusting a commit or
CI run, check `git log` and the latest GitHub Actions run.

## Current state

- **Antigravity plugin connected.** The independent `antigravity build/status/deploy` route
  builds `ai-agent-dotfiles` 0.1.0 from only shared `boring-engineering` and `git-review`.
  Canonical and final-package scans, reproducible file maps and native strict validation pass.
  PR #9 merged at `fad4433`; Validate passed for its exact head `3900374` and merged main.
  Acceptance closeout PR #10 merged at `19e9c4c`; its exact head `b302a7d` and merged main
  also passed Validate (runs `43475060639` and `43476333032`).
  Owner grant A01 covered the first installation and six native acceptance sessions. All 12
  installed files match the approved package; enabled readback and the final preview report
  `unchanged`. The native config file is byte-identical before and after installation, preserving
  built-in swarm and other settings. Installation copies the package into an ordinary native
  plugin directory; the stable source package, ownership receipt and backup stay under the
  primary checkout's ignored `tmp/antigravity/`, outside temporary task worktrees.
  App and CLI each pass explicit review, natural design-skill loading and an unrelated
  translation in separate conversations (6/6 sessions, no added purchases or Bridge calls).
  The finite native-session allowance is exhausted; further model calls need new authorization.
  CLI expansion metadata identifies `ai-agent-dotfiles:git-review`; both clients' natural cases
  show the installed `boring-engineering/SKILL.md` being read. Unrelated cases show no skill
  reads in their visible traces. Evidence reaches built/validated/installed/enabled/loaded/used;
  long-run outcome improvement is unmeasured. Existing platform selections and default sync
  routes are unchanged. Unknown ownership, drift, version reuse and unproven updates/rollback
  still block writes. The CLI/lifecycle suites pass 114/91 assertions; affected rechecks,
  including 82 profile assertions, pass without changing existing guards. The original full
  local FAIL (12/15) is retained privately alongside its diagnosed fixes; exact-head CI covers
  all 15 suites. Native diagnostic logs remain private and are not publication artifacts.
  The clean temporary validation clone was removed after its six test logs were preserved.
  Both managed task worktrees remain: the host refused removal of the task's primary checkout
  and reported another active task using the CLI tree. No manual removal bypassed those guards;
  task branches remain. The primary checkout's unrelated WIP was preserved, so its local main
  was not fast-forwarded. Final CI and cleanup receipts stay locally in ignored `tmp/antigravity/`.

- **Antigravity delegation.** The Codex-only skill and private-config invocation entry are
  selected only for Codex in `work` (source selection 0/10/8). The source default is disabled;
  the entry uses frozen primary/fallback roles and the Bridge managed host without adding a
  Bridge engine or distributing model defaults, credentials or private routes. Source build,
  pinned secret scan, syntax/schema, 13 wrapper assertions and the actual read-only preflight
  pass. The original full local run passed 13 of 14 suites; the missing `full` selection found
  by repository-policy was repaired and the affected recheck passed. Exact-head Validate is
  required before merge. Independent source review passed. The owning Bridge task's bounded
  native acceptance proved both configured High models reading the plugin Skill, calling the
  fixture MCP, consuming its random result, repairing the allowed files and passing tests;
  command denial and original Job cleanup were independently checked. This does not establish
  all-tool isolation or arbitrary plugin/account capabilities. Live enablement, default-model
  state and deployment readback are machine-private: inspect the owning task's receipts rather
  than infer them from this source status. New installs and consumer-channel use retain their
  explicit authorization boundary; the reviewed preview is one install and 17 unchanged skills.
- **Claude retirement.** The retirement baseline selected Claude/Codex/ZCode 0/9/8; the
  Antigravity source candidate above adds one Codex selection.
  Config status/pull/push and combined deployment default to Codex only. The shared
  `base`/`coding` and this repository profile target Codex without automatic ClaudeSettings.
  Root `CLAUDE.md` and `.claude/settings.json` developer entries are removed. The Claude
  generated skills remain the ZCode projection source; distributable templates and
  explicit Claude tools stay compatible. The old full-environment exception is retired,
  and the standing `work` grant covers Codex/ZCode only. This source change did not
  remove live Claude state or perform a live deployment. A post-merge read-only check
  found the live Claude root absent on the current machine; the `work` dry run reported
  17 unchanged skills, no prunes and no config changes.
  The first retirement candidate passed local syntax, build, pinned secret scan and all
  14 isolated suites, including the work-selection fixture and Codex-only inheritance.
  After local entry removal, syntax, repository-policy, doctor and pinned secret-scan
  checks pass. PR #5 merged to `main` at `50574f6`; Validate passed for both the exact
  PR head and the merged main commit. Default config dry-run is Codex-only and in sync;
  no live Apply was performed.

- **Proactive Git approval requests.** The Codex global agreement source explicitly requests
  missing commit, push or merge permission once the diff and checks are reviewable; it reuses
  explicit existing grants instead of ending with an unexplained uncommitted/unmerged result.
  The requested Codex-only managed-block deployment completed, its readback is in sync, and
  personal text outside the block is unchanged. The owner approved A04 for this change's
  commit/push and sequential integration of PRs #3 and #4 after current CI passes; both PRs
  are merged.
- **Repository branches.** The subagent-dispatch task branch is retained locally and on `origin`; remote deletion is not authorized. Earlier task branches for
  PRs #3, #4 and #5 were deleted after their merge state and full-tip ancestry were verified;
  their cleanup does not include the current task branch.
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
- **Subagent policy.** Codex agreements retain the whole-root concurrent allowance of 50
  descendants with the lead excluded, the host's lower open/active limits and existing budgets.
  Ready substantive work is dispatched promptly; independent parts proceed when other inputs
  are missing, and dependency/result/wait boundaries trigger follow-on dispatch. Integration
  bottlenecks contract only affected expansion. Implementation and necessary tests normally
  share an owner, with independent review kept independent when required. The shared skill
  has matching platform-neutral guidance; the unchanged `work` selection uses it only on Codex.
  Build, pinned secret scan, diff checks and independent review passed. PR #6 integrated
  source `fc60c19` with merge commit `15b2a5e` after Validate `43228587969` passed.
  Owner grant A01 covered the public PR, normal merge and both sequential Codex deployments.
  The skills Apply updated only the target skill; its source, generated and live files match.
  The post-Apply preview reports 17 unchanged, no updates/installs/prunes/unknowns. Config
  status and pull readback show the managed block in sync; personal config and outside-block
  text are unchanged, and both task-owned backups match their pre-Apply content. The current
  chat received refreshed global instructions; loading in other existing chats and real-task
  speedup remain unverified. No extra model acceptance was run and no standing grant changed.
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
  ZCode model-level effect remains unmeasured, and the current machine has no Claude live root.
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

- The numbered one-interaction scoring revision is installed on Codex and ZCode; the current
  machine has no Claude live root. The private ledger holds 23 real records (20 structured plus
  3 manual; all Codex; 19 at 1, 4 at 0) across 11 task references. The three retained local
  pending inputs were reconciled on 2026-11-10 with source attribution and readback; no further
  pending input was found in the inspected local evidence. Three independent Codex tasks now
  cover the same core action, a full-environment approval-feedback live update, with scores of
  1 and no 2/3 or permission conflict. That threshold led to the owner-approved narrow exception
  in Skill rules 9; no other future approval is enabled.
  The feedback still shows repeated low interruption value and has produced concrete narrow
  proposals, one applied and published, but no measured reduction. The current skill revision is
  `3aa4391`; its source matches the Codex and ZCode live roots, and the Codex managed block is
  in-sync. A fresh Codex task on 2026-11-11 discovered and read the current body, but had no
  comparable approval opportunity, so the current-revision S/Q effect remains unmeasured (U).
  The next natural checkpoint is the next real Codex approval request.
- `approval-feedback` is installed in the Codex and ZCode live roots; the current machine has
  no Claude live root. Codex catalog discovery, live-file loading and selection have
  fresh-context and partial thread evidence; ZCode model-level loading and long-run selection
  remain unverified because that client is not in active use. Installation enables no automatic
  approval or standing merge policy.

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
