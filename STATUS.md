# Project Status

Last updated: 2026-11-21.

This file holds only present-tense facts, open items and known boundaries. Update it by replacing
lines in place. Put dated task logs and evidence in `status/active/<task>.md`; when a task is
done, record its outcome here and delete the record (Git keeps it). Before trusting a commit or
CI run, check `git log` and the latest GitHub Actions run.

## Current state

- **Five maintenance fixes verified.** An unresolved Antigravity upgrade blocks another native attempt. Config pull preserves concurrent personal saves, and config pull/push enforce an external backup root. MCP diagnostic JSON reports changed fields without their configured values. Skills deployment tracks ownership independently of a matching manual directory. All five have isolated regression coverage. [Fix commits and verification](docs/OPEN_CODE_ISSUES.md)
- **Managed MCP projection (`mcp-sync`).** Use `agent-dotfiles.ps1 mcp status` for current per-host configuration drift. At the last successful runtime check, a read-only `get_addon_status` call from Codex reached Blender 5.3.0 and reported add-on 2.0, protocol 16 (expected 16). Antigravity has configuration-level verification only. [Blender connection check](docs/ONBOARD_NEW_MACHINE.md#5-project-managed-mcp-servers-mcp-sync)
- **Global `AGENTS.md` managed via config-sync.** [codex/AGENTS.md](codex/AGENTS.md) and [antigravity/AGENTS.md](antigravity/AGENTS.md) sync to `~/.codex/AGENTS.md` and `~/.gemini/config/AGENTS.md` respectively via config-sync (`-Platform Codex,Antigravity`) as `AI-AGENT-DOTFILES` managed blocks. Config-sync defaults remain Codex-only; structured merge preserves personal content outside markers. Both global rules enforce explicit external CLI version/exit-code verification, forbid silent model downgrade and cross-model relabeling, and disallow invoking or reviving retired channels.
- **Antigravity external plugins (`ExternalPlugins`).** `harness-source/antigravity/plugins.psd1` declares the marketplace plugin `unity`. Installing a missing entry requires `-ExternalPlugin <name>`. After the managed plugin upgrade, readback showed Unity 0.1.9-beta enabled and matching its declared source. Unity Editor workflows remain unverified.
- **Antigravity plugin.** `ai-agent-dotfiles` 0.4.1 is installed and enabled. Its files match the validated package containing `git-review`, `multimodal-generation`, `systematic-debugging`, and `verification-before-completion`. The upgrade from 0.4.0 retained the previous installation backup. Controlled updates check the scanned package and current native CLI validation before uninstalling the working version. Receipts and backups are under `%LOCALAPPDATA%/ai-agent-dotfiles.deploy/antigravity/`.
- **ZCode, `antigravity-delegation`, and Grok routing retired.** Repository support for ZCode skill deployment, configuration sync, MCP projection, `zcode/AGENTS.md`, `skills-source/zcode-only/`, `docs/ZCODE.md`, and `manifests/managed-skills.zcode.txt` is retired. The Codex-only `antigravity-delegation` skill and the Grok routing clause in `codex/AGENTS.md` are retired. Earlier deployment state may contain a `Zcode` entry, which deployment ignores and drops on apply without touching `~/.zcode/`.
- **Claude platform retirement.** Repository support for Claude skill deployment, configuration capture and deployment, and project templates is retired. Existing Claude files on user machines are outside the tool's scope. Earlier deployment state may contain a Claude entry, which deployment ignores.
- **Proactive Git approval requests.** Agent instructions require explicit approval requests for commit, push, or merge once diffs and verification are ready, reusing existing task grants rather than ending with unexplained uncommitted changes.
- **Historical branch cleanup.** On 2026-11-20 the owner authorized deletion of 25 remote branches. Every tip was an ancestor of `main` at `f996888`. For 24 branches the tip matched a merged PR from the same branch. The plugin planning branch was integrated through [PR #9](https://github.com/MaginaLW/ai-agent-dotfiles/pull/9). The atomic deletion checked all 25 tip SHAs, and GitHub readback showed only `main` immediately afterward.
- **Retired skills cleanup.** Standalone skills `approval-feedback`, `boring-engineering`, and `antigravity-delegation` are fully retired across canonical sources, manifests, and documentation.
- **CLI and observability.** `agent-dotfiles.ps1` provides unified CLI entry points (`help <group>` and `<group> help`), structured skill plan previews with file-level diffs, preflight secret scanning, and non-atomic stage rollback guidance. The top-level `status` command reports the recorded environment, configuration drift (Codex and Antigravity), Antigravity plugin state, and managed MCP projections. Use the skills deployment dry run for a file-level comparison of live skills. `doctor.ps1` checks the nine core repository scripts.
- **Subagent policy.** Codex agreements permit up to 50 concurrent descendant subagents (lead excluded). Substantive ready work is dispatched promptly, with implementation and tests sharing an owner and independent review kept separate when required. At `079f4fe` ([Validate](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/44880732275)), `codex/AGENTS.md` and `subagent-driven-development` default Codex `spawn_agent` to `fork_turns: "none"` with a concise self-contained handoff (reserving `fork_turns: "all"` for tight dependency on unpersisted parent discussion or small parent context) and prefer fresh instances on stage changes or heavy context; paired with an optional local `[features.multi_agent_v2].usage_hint_text` snippet in [CODEX_TUNING.md](docs/CODEX_TUNING.md#子代理历史继承multi-agent-v2). Current evidence level: `reused` (verified on one blind read-only CLI check and one medium-intensity desktop session with 100% `fork_turns="none"` compliance, low child startup context, and no `NEEDS_CONTEXT` or rework).
- **Codex push approval.** Codex Guardian V2 treats `git push` as data egress and trusts only a verified private user/org repository. The global Codex instructions require a read-only destination check before an escalated push, require that evidence in the justification, and allow one evidence-backed retry after a denial.
- **Current scope.** `build-skills.ps1` builds `codex/skills/` from `skills-source/`. `deploy-skills.ps1` deploys the chosen environment to the Codex live root. Git ignores the generated directory.
- **Combined deploy and config merge.** `agent-dotfiles.ps1 sync` runs the skills deployment followed by `config-pull`. Config-sync defaults to Codex and supports the Codex and Antigravity `AGENTS.md` managed blocks.
- **Skills and deployment.** All 18 managed skill entry points (11 shared, 7 Codex-only) have readable names and descriptions. The `systematic-debugging` helper passed seven npm scenarios, including zero matches and failed tests. In a fixture repository, the full-only `security-ownership-map` skill produced a queryable report using `run_ownership_map.py --no-communities` without NetworkX. Codex `.system` stays outside deployment.
- **Skill effect evidence levels.** Skill-effect claims are classified as `deployed`, `loaded`, `applied`, `reused`, or `outcome-improved`; a higher level is not inferred from a lower one. Catalog discovery and installation do not prove behavior change, and one applied case does not prove long-run improvement.
- **Scan and build policy.** `scripts/repo-common.ps1` defines the generated skill root (`codex/skills`) and scan-input prefixes used by the build, secret scan and validation scripts. The generated Codex skill directory is excluded from scan input.
- **Fail-closed discovery.** `Get-SkillDirectories` returns an empty set only when the root is absent. Enumeration errors stop the build instead of appearing as an empty skill set.
- **Local verification and CI.** At `b911265`, the full local run passed 14 of 15 suites. The harness-profile suite refused its checkout under the user home, then passed all 83 checks in a separate checkout of the same commit outside the home. The dangerous-file and clean-tree checks also passed separately. GitHub Actions validated the preceding `main` commit `a922ba2`. [Main validation](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/44776595118) · [Latest main runs](https://github.com/MaginaLW/ai-agent-dotfiles/actions/workflows/validate.yml?query=branch%3Amain)
- **Pinned gitleaks.** Gitleaks 8.30.0 is pinned by archive and executable SHA-256 with official GitHub Releases API fallback.
- **CI.** One `Validate` job runs `scripts/run-repository-validation.ps1` on push to `main`, pull requests and manual dispatch. GitHub Actions is the source of truth for the latest head.
- **Repository hygiene and execution optimizations.** Secret scan pattern enforcement includes precision detection for Google API keys (`AIza...`), PKCS#8 private keys, and GitHub token prefixes (`gho_`, `ghu_`, `ghs_`, `ghr_`). Runtime `.gitignore` exclusions prevent local Antigravity runtime state contamination. Reasonix infrastructure and references are fully retired. `deploy.ps1 -Apply` deduplicates preflight secret scans when skills preflight has already verified the tree (`-SkipSecretScan`), and `run-tests.ps1` supports selective suite execution (`-Suite`) while enforcing timeout budgets across all test suites.
- **O1–O5 optimization work.** All 14 items in the [optimization plan](docs/OPTIMIZATION_PLAN_2026-11-17.md) have an implementation or an owner decision. Gitleaks, the fallback scanner and MCP registry validation recognize both plain and encrypted PKCS#8 private key headers. For O2, `agent-dotfiles.ps1 config status|pull|push` dispatches to `config-status.ps1`, `config-pull.ps1` and `config-push.ps1`, respectively. [CLI implementation](scripts/agent-dotfiles.ps1) · [Config integration tests](tests/config-sync.tests.ps1)
- **Multimodal/MCP extension (A–C merged).** The merged scope covers deployment of `multimodal-generation`, registration of the Unity plugin and Blender MCP configuration on three clients. Subscription media generation remains unverified. [Extension plan](docs/MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md)
- **Status history.** The former dated journal is preserved in Git; this file now keeps only facts that still affect current decisions. Historical and removed documentation is indexed by [docs/HISTORY.md](docs/HISTORY.md).

## Open items

- **Subagent `fork_turns: "none"` high-intensity observation.** Current evidence is at `reused`. After a round of high-intensity multi-subagent usage, compare post-`2026-11-21` rollouts against the pre-change baseline across both cost/context-size and quality (`NEEDS_CONTEXT` rate, redundant re-reads, constraint misses/rework) before promoting to `outcome-improved` or adding further levers.
- **Project Harness Profiles (on-demand maintenance).** The 2026-11-21 cross-repository inventory confirmed active downstream use (`.agent-harness/profile.psd1` in an active project), moving Project Harness Profiles to on-demand maintenance per [Owner decision 5](docs/OPTIMIZATION_PLAN_2026-11-17.md#1-所有者设计决议记录2026-11-17).

## Known boundaries

- **Codex global agreements use a managed block.** `codex/AGENTS.md` is the canonical body; the
  live Codex file wraps it in `<!-- BEGIN/END AI-AGENT-DOTFILES: codex/AGENTS.md -->` markers.
  Content outside the block is local and preserved, and config-status compares the block body.
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
- **Codex catalog refresh and loaded skill bodies.** Codex detects skill changes automatically
  and may need a restart when an update does not appear. A conversation that already loaded an
  old `SKILL.md` or `AGENTS.md` body can retain that text until reloaded.
- **Out of scope.** Machine-private configuration including whole Codex `config.toml`, private
  `.env` files, credentials, sessions and caches are outside `config-sync` scope (only per-entry
  managed MCP projection under `AGENTS.md` hard rules is permitted). Machine-private
  evidence under `tmp/` and external private roots is not committed.

## Inventory and scope

| Scope | Canonical | Codex |
|---|---:|---:|
| Shared | 11 | 11 |
| Codex-only | 7 | 7 |
| Managed total | 18 | 18 |

- **Shared skills:** brainstorming, git-review, meng-cmame-writing, multimodal-generation,
  paper-polish, session-learnings, subagent-driven-development, systematic-debugging,
  tool-scope, verification-before-completion, writing-plans.
- **Codex-only skills:** chatgpt-apps, cli-creator, coderabbit-review,
  define-goal, security-best-practices, security-ownership-map, security-threat-model.
- **Environments** (Codex): `minimal` 1, `work` 8, `full` 18.
  Unselected unknown live directories are preserved, and Codex `.system` is never managed.
- **Retired:** ZCode platform support (`zcode/`, `docs/ZCODE.md`, `skills-source/zcode-only/`, `manifests/managed-skills.zcode.txt`); `antigravity-delegation` skill; Grok routing; Claude platform support; the transactional live-sync engine, its hooks/runner/schemas/tests; the former engine's
  MCP registration subsystem (replaced by per-entry `scripts/mcp-sync.ps1`); OpenClaw/OpenCode; Reasonix; ArkCLI-managed skills; the legacy local
  `hatch-pet` v1 packaging workflow; the custom brainstorming browser-companion server.
- **Integrations.** The harness-model feedback-loop pilot is paused. One remote VPS pilot remains active.
- **Skill retirement.** Deleting a skill's source leaves an old live directory as unknown;
  `-Retire <name>` removes it after review. See
  [docs/README.md §5](docs/README.md#5-修改已有-skill-的流程).

## History

- The dated status journal, live-safety record, ZCode feedback-loop runs, removed engine,
  import/merge pipeline and old design/plan documents are in Git history. `docs/HISTORY.md`
  names the relevant commits and how to read them.
