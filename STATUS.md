# Project Status

Last updated: 2026-11-18.

This file holds only present-tense facts, open items and known boundaries. Update it by replacing
lines in place. Put dated task logs and evidence in `status/active/<task>.md`; when a task is
done, record its outcome here and delete the record (Git keeps it). Before trusting a commit or
CI run, check `git log` and the latest GitHub Actions run.

## Current state

- **Managed MCP projection (`mcp-sync`).** Managed MCP projection (`harness-source/mcp/servers.psd1`, `scripts/mcp-sync.ps1`, `agent-dotfiles.ps1 mcp`) projects declared MCP server definitions (`blender`) per-entry to Codex, Antigravity, and ZCode while preserving unmanaged entries. Live read-only `mcp status` reports Codex, Antigravity, and ZCode `blender` all `unchanged` (`add=0 update=0 unchanged=3 blocked=0`).
- **Global `AGENTS.md` managed via config-sync.** [antigravity/AGENTS.md](antigravity/AGENTS.md) and [zcode/AGENTS.md](zcode/AGENTS.md) sync to `~/.gemini/config/AGENTS.md` and `~/.zcode/AGENTS.md` respectively via config-sync (`-Platform Antigravity,ZCode`) as `AI-AGENT-DOTFILES` managed blocks. Config-sync defaults remain Codex-only; structured merge preserves personal content outside markers.
- **Antigravity external plugins (`ExternalPlugins`).** `harness-source/antigravity/plugins.psd1` declares marketplace external plugins (`unity`). `scripts/antigravity-plugins.ps1` supports explicit opt-in `-ExternalPlugin <name>` installation of missing entries; default `deploy -Apply` leaves missing external plugins untouched. Live read-only `antigravity status` confirms `unity` `State: unchanged`.
- **Antigravity plugin.** The manifest selects `ai-agent-dotfiles` 0.4.1 with four shared skills (`git-review`, `multimodal-generation`, `systematic-debugging`, `verification-before-completion`). Run `antigravity status` to compare the installed copy with this target. Controlled updates require a matching scanned package validated by the current native CLI, then back up the installed plugin before uninstall, install, and readback. The installation receipt and attempt state are under `%LOCALAPPDATA%/ai-agent-dotfiles.deploy/antigravity/`.
- **Antigravity delegation.** The Codex-only skill `antigravity-delegation` is selected for Codex in `work` (0/9/7) and `full`. Default is disabled, using the Bridge managed host without distributing model defaults or credentials.
- **Claude developer entry retirement.** Local developer entry files (`CLAUDE.md`, `.claude/settings.json`) are retired; config-sync and deployment default to Codex. Claude generated skills (`claude/skills/`) serve as the projection source for ZCode; distributable templates remain in `claude/`. The live Claude skills root is absent on the current machine.
- **Proactive Git approval requests.** Agent instructions require explicit approval requests for commit, push, or merge once diffs and verification are ready, reusing existing task grants rather than ending with unexplained uncommitted changes.
- **Repository branches and worktree hygiene.** Local task branch `codex/subagent-dispatch-20261112` is deleted following ancestor proof against `main`, and temporary worktree `wt-ag-040` is removed. All 20 remote historical branches are verified fully merged into `main`; remote branch deletion is deferred pending explicit owner authorization.
- **Retired skills cleanup.** Standalone skills `approval-feedback` and `boring-engineering` are fully retired across canonical sources, manifests, Antigravity plugin, and documentation.
- **CLI and observability.** `agent-dotfiles.ps1` provides unified CLI entry points (`help <group>` and `<group> help`), structured skill plan previews with file-level diffs, preflight secret scanning, and non-atomic stage rollback guidance. The top-level `agent-dotfiles.ps1 status` command aggregates read-only status and drift detection across Git working tree, config sync, skill deployment, Antigravity plugins, and managed MCP projections. `doctor.ps1` modernizes environment checks by treating absent optional Claude roots as INFO and verifying existence of all 9 core repository scripts.
- **Subagent policy.** Codex agreements permit up to 50 concurrent descendant subagents (lead excluded). Substantive ready work is dispatched promptly, with implementation and tests sharing an owner and independent review kept separate when required.
- **Grok routing.** The Codex agreement template routes explicitly requested Grok work through agent-bridge and preserves its current schema, available engines and approval flow; it has no local Grok Build CLI fallback.
- **Codex push approval.** Codex Guardian V2 treats `git push` as data egress and trusts only a verified private user/org repository. The global Codex instructions require a read-only destination check before an escalated push, require that evidence in the justification, and allow one evidence-backed retry after a denial.
- **Current scope.** `skills-source/` is the only skill source. `build-skills.ps1` generates `claude/skills/` and `codex/skills/`; `deploy-skills.ps1` deploys one environment to the live Claude, Codex and ZCode roots. Generated output is ignored by Git; `full` contains every managed skill, while `work` is the daily set.
- **Combined deploy and config merge.** `deploy.ps1` combines skills deployment and `config-pull` into one unified dry-run/apply entry point (used by `agent-dotfiles.ps1 sync`). Claude `settings.json` merges structured objects; Codex, Antigravity, and ZCode `AGENTS.md` update their respective managed blocks.
- **Skills and deployment.** There are 19 managed skills: 11 shared and 8 Codex-only. Codex `.system` remains untouched.
- **Skill effect evidence levels.** Skill-effect claims are classified as `deployed`, `loaded`, `applied`, `reused`, or `outcome-improved`; a higher level is not inferred from a lower one. Catalog discovery and installation do not prove behavior change, and one applied case does not prove long-run improvement.
- **Policy centralization.** Generated skill roots, scan-input prefixes and the Codex live-root rule live in `scripts/repo-common.ps1`. Build, secret scan, syntax gate, doctor, deploy and repository validation consume those definitions; generated/legacy roots remain excluded from scans and untracked-output checks.
- **Fail-closed discovery.** `Get-SkillDirectories` returns an empty set only when the root is absent. Enumeration errors stop the build instead of appearing as an empty skill set.
- **Local verification and CI.** Repository validation covers PowerShell syntax, pinned gitleaks, build, secret scan, doctor, manifest parity, all 15 local test suites, dangerous-file checks, and clean-tree gate. GitHub Actions `Validate` is the CI gate on push and PR.
- **Pinned gitleaks.** Gitleaks 8.30.0 is pinned by archive and executable SHA-256 with official GitHub Releases API fallback.
- **CI.** One `Validate` job runs `scripts/run-repository-validation.ps1` on push to `main`, pull requests and manual dispatch. GitHub Actions is the source of truth for the latest head.
- **Repository hygiene and execution optimizations.** Secret scan pattern enforcement includes precision detection for Google API keys (`AIza...`), PKCS#8 private keys, and GitHub token prefixes (`gho_`, `ghu_`, `ghs_`, `ghr_`). Runtime `.gitignore` exclusions prevent local Antigravity runtime state contamination. Reasonix infrastructure and references are fully retired. `deploy.ps1 -Apply` deduplicates preflight secret scans when skills preflight has already verified the tree (`-SkipSecretScan`), and `run-tests.ps1` supports selective suite execution (`-Suite`) while enforcing timeout budgets across all test suites.
- **Observation windows.** Project Harness Profiles (`scripts/*-harness-profile.ps1`) are frozen under a 90-day passive observation window (2026-11-17 through 2027-02-15) per owner decision #5; repository evaluation safely skips non-marked files without accidental writes. Verification claims bind to a target, version, environment, and stopping condition; delegated evidence is reused after inspection.
- **Status history.** The former dated journal is preserved in Git; this file now keeps only facts that still affect current decisions. Historical and removed documentation is indexed by [docs/HISTORY.md](docs/HISTORY.md).

## Open items

- **Repository optimization roadmap (Tracks O1–O5 complete).** All 14 optimization items across Tracks O1–O5 from [docs/OPTIMIZATION_PLAN_2026-11-17.md](docs/OPTIMIZATION_PLAN_2026-11-17.md) are fully implemented and validated: secret scan expansions, runtime gitignore rules, Reasonix retirement, config-sync multi-platform unification, ZCode AGENTS.md managed block, deploy scan deduplication, test runner `-Suite` filter, Antigravity plugin state relocation to `%LOCALAPPDATA%`, decoupled plugin status, controlled update workflow, doctor modernization, top-level unified `status` command, Antigravity blender MCP alignment, passive observation window documentation, and local branch/worktree hygiene.
- **Multimodal/MCP extension (Tracks A, B, and C completed and accepted).** Under [docs/MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md](docs/MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md), all tracks are merged and operational: Track A (`multimodal-generation` skill deployed), Track B (`unity` external plugin verified in Antigravity), and Track C (per-entry managed MCP projection via `mcp-sync.ps1`, `servers.psd1`, with live `blender` MCP aligned and converged across Codex, Antigravity, and ZCode).
- **Active observation window: Project Harness Profiles (through 2027-02-15).** 90-day passive observation window per owner design decision #5 to ascertain downstream project requirements before deciding on active maintenance or clean retirement.
- **Remote historical branch cleanup (pending owner authorization).** All 20 remote historical branches are confirmed merged into `main`; deletion from `origin` is deferred until explicit owner authorization is granted per AGENTS.md hard rules.

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
- **Retired:** the transactional live-sync engine, its hooks/runner/schemas/tests; the former engine's
  MCP registration subsystem (replaced by per-entry `scripts/mcp-sync.ps1`); OpenClaw/OpenCode; ArkCLI-managed skills; the legacy local
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
