# Project Status

Last updated: 2026-11-15.

This file holds only present-tense facts, open items and known boundaries. Update it by replacing
lines in place. Put dated task logs and evidence in `status/active/<task>.md`; when a task is
done, record its outcome here and delete the record (Git keeps it). Before trusting a commit or
CI run, check `git log` and the latest GitHub Actions run.

## Current state

- **Antigravity global `AGENTS.md` managed via config-sync.** Added [antigravity/AGENTS.md](antigravity/AGENTS.md)
  (distilled from `codex/AGENTS.md` for Antigravity without `agent-bridge` or
  Codex-only approval/sandbox clauses) and `Antigravity` config-sync support in
  `manifests/whitelist.psd1`, `scripts/config-common.ps1`, `config-status/pull/push.ps1`, and
  `agent-dotfiles.ps1`. Defaults remain Codex-only (`-Platform Antigravity` is explicit); live
  `config pull -Platform Antigravity -Apply` deployed the `antigravity/AGENTS.md` managed block
  to `~/.gemini/config/AGENTS.md`, and post-Apply `config status` / `config pull -DryRun`
  readbacks confirm `in-sync` (`managed block`).
- **Antigravity external plugins (`ExternalPlugins`) track B implemented.** `harness-source/antigravity/plugins.psd1` now declares `unity` (`Source = 'antigravity-plugins-partners'`, `Version = 'ANY'`, `Enabled = $true`; `gemini-api` excluded per zero-extra-API-cost decision). `scripts/antigravity-plugins.ps1` and `scripts/agent-dotfiles.ps1` support marketplace `Source` validation, `Version = 'ANY'`, `missing`/`blocked` planning states, and explicit opt-in `-ExternalPlugin <name>` installation of missing marketplace entries (`agy plugin install <name>@<marketplace>` once with pre/post readback and pending-marker failure stops). Default `deploy -Apply` leaves missing external plugins untouched, and already-installed or drifted external plugins remain blocked from automatic reinstall (T0 live verification proved `agy plugin install unity@antigravity-plugins-partners` exits `0` on clean install with `source = 'antigravity-plugins-partners'` and `version = '0.1.9-beta'`, while repeating it with Antigravity running fails with `Access is denied` and preserves the installed plugin). Live read-only `antigravity status` confirms `unity` `State: unchanged`; `antigravity-plugins.tests.ps1` passes 106 assertions and `agent-dotfiles.tests.ps1` passes 118 cases.

- **Antigravity plugin updated to 0.4.0 (multimodal-generation added; live 0.4.0 installed).** The independent `antigravity build/status/deploy` route
  now builds and deploys `ai-agent-dotfiles` 0.4.0 from four shared skills (`git-review`,
  `multimodal-generation`, `systematic-debugging`, `verification-before-completion`; 10 files,
  digest `41449b6e...`). Canonical and final-package scans and native strict validation
  (`agy 1.5.9`) pass; after uninstalling `0.3.0` (`agy plugin uninstall ai-agent-dotfiles`), a
  clean detached `main` worktree (`7c8841d`) installed `0.4.0` (`antigravity deploy -Apply`) with
  Antigravity Desktop App closed. Post-install readbacks (`agy plugin list --json`,
  `antigravity status`, `antigravity deploy -DryRun`) confirm `0.4.0`, `enabled: true`, all 4
  skills, `Action: unchanged` (`Reason: identity-version-and-content-match`), `SKILL.md` present
  under `~/.gemini/config/plugins/ai-agent-dotfiles/skills/multimodal-generation/`, and intact
  `config.json` (`plugins.swarm`, `sidecars`, `userSettings`); the `0.4.0` ownership receipt
  (`installed.json`) stays in that dedicated worktree's ignored `tmp/antigravity/`.
  Skill selection is schema-validated dynamically, and the host-exported default
  `ANTIGRAVITY_APP_DATA_DIR` (`<UserProfile>/.gemini/antigravity`) is accepted while non-default
  overrides remain rejected. Earlier `0.1.0` (PR #9 `fad4433`, PRs #10/#11 `19e9c4c`/`9b78244`),
  `0.2.0` (PR #15 `c697d0a`), and `0.3.0` (PR #17 `6eb9664`, `boring-engineering` retired)
  installs remain historical baselines; native real-use acceptance for `systematic-debugging`,
  `verification-before-completion`, and `multimodal-generation` remains unverified. Existing
  platform selections and default sync routes are unchanged; unknown ownership, drift, version
  reuse and unproven in-place updates/rollback still block writes. Local `0.1.0` backup and its
  historical `installed.json` remain under the primary checkout's ignored `tmp/antigravity/`.

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
- **Approval-feedback & boring-engineering retired and codex/AGENTS.md streamlined.** Both standalone skills (including the former `%LOCALAPPDATA%` feedback ledger, `A01` scoring prompts, and `S/Q/U/H` summaries) and `boring-engineering` are retired from canonical source, `work`/`full`, Antigravity `ai-agent-dotfiles`, `codex/AGENTS.md`, and docs. `codex/AGENTS.md` retains only the non-scoring engineering-restraint and low-intervention clauses.
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
- **Skills and deployment.** There are 19 managed skills: 11 shared and 8 Codex-only. The
  2026-11-08 source cleanup retired `hatch-pet` and removed the custom brainstorming browser
  server; `approval-feedback` and `boring-engineering` were retired on 2026-11-15. Codex
  `.system` remains untouched.
- **Skill effect evidence levels.** Skill-effect claims are classified as `deployed`, `loaded`,
  `applied`, `reused`, or `outcome-improved`; a higher level is not inferred from a lower one.
  Catalog discovery and installation do not prove behavior change, and one applied case does not
  prove long-run improvement. Current evidence places `session-learnings` at
  deployed/loaded/applied/reused and `tool-scope` at deployed/loaded/applied; current-revision
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

- **Multimodal/MCP extension (tracks A and B complete; track C pending).** Under the owner-approved plan in
  [docs/MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md](docs/MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md)
  §6 (tracks A → B → C):
  - Track A is complete: `multimodal-generation` (subscription-quota first, paid API opt-in only) merged in PR #19 (`112f418`), deployed to `work` Codex/ZCode (`unchanged=16, prune=0, unknown=0`), and installed via Antigravity `0.4.0`.
  - Track B is complete: `ExternalPlugins` declares `unity` (`antigravity-plugins-partners`), T0 live install verified `unity` `0.1.9-beta` (`enabled: true`, 35 skills) and non-idempotent repeat behavior, and `antigravity-plugins.ps1` / `agent-dotfiles.ps1` add explicit `-ExternalPlugin` missing-install support.
  - Track C (in progress): Part 1 amends `AGENTS.md` hard rules for per-entry managed MCP projection (Codex via `codex mcp` CLI; Antigravity `mcp_config.json` and ZCode `~/.zcode/cli/config.json` `mcp.servers` via structured JSON merge) and records T0 probe results; Part 2 (`harness-source/mcp/`, `scripts/mcp-sync.ps1`, Pester suites, and policy test update) follows in a new task after the rule PR merges. End-to-end multimodal/Unity/Blender real-use acceptance remains pending.

- **Historical `approval-feedback` & `boring-engineering` open items closed (`2026-11-15`).** Both standalone skills (along with the deleted `%LOCALAPPDATA%/ai-agent-dotfiles.feedback/` directory, `A01` scoring prompts, `S/Q/U/H` summaries, and the two `docs/APPROVAL_FEEDBACK_*.md` design/plan docs) have been removed. The earlier Skill rules 9 full-environment exception remains retired.

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
  old `SKILL.md` or `AGENTS.md` body can retain that text until reloaded.
- **Out of scope.** Machine-private configuration including whole Codex `config.toml`, private
  `.env` files, credentials, sessions and caches are outside `config-sync` scope (only per-entry
  managed MCP projection under `AGENTS.md` hard rules is permitted). Machine-private
  evidence under `tmp/` and external private roots is not committed.

## Inventory and scope

| Scope | Canonical | Claude | Codex |
|---|---:|---:|---:|
| Shared | 11 | 11 | 11 |
| Codex-only (Claude-only is empty) | 8 | - | 8 |
| Managed total | 19 | 11 | 19 |

- **Shared skills:** brainstorming, git-review, meng-cmame-writing, multimodal-generation,
  paper-polish, session-learnings, subagent-driven-development, systematic-debugging,
  tool-scope, verification-before-completion, writing-plans.
- **Codex-only skills:** antigravity-delegation, chatgpt-apps, cli-creator, coderabbit-review,
  define-goal, security-best-practices, security-ownership-map, security-threat-model.
- **Environments** (Claude/Codex/Zcode): `minimal` 1/1/1, `work` 0/9/7,
  `full` 11/19/11. Unselected unknown live directories are preserved, and Codex `.system` is
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
