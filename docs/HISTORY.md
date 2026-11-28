# Design and plan history

Removed code and docs stay in Git history. This page says where to find them.

## Recent merged PRs and verification milestones (PRs #51–#65, 2026-11)

- **Teamwork, Swarm, and Grill-Me collaboration (PRs #51, #53, #56):** PR #51 (`1eabe05`, head `68b8923`, PR run `45242905682`, merge run `45243874138`) landed the Swarm/Teamwork/Grill-Me baseline; PR #53 (`d430500`, run `45296135807`) added automatic native Codex Goal assurance (`get_goal` / `create_goal`); PR #56 (`7c1fcb8`, run `45435806998`) fixed protocol edge cases, `security-ownership-map` UTF-8/`cp1252`/decay/UTC handling, and expanded Python tests. Live-deployed script verification on 2026-11-25 passed against `codex-cli 0.171.0` and `~/.codex/prompts/teamwork.md` (SHA-256 `891F02F8C6D45B2AB0F5AB4F597D4024B8386EA9CB8556402AEFD621871A2932`): 2-wave `waves.py`, `coordination.py --reuse` sibling `board-server.json`, `/api/health` (`uiGets: 1`, `statePolls: 1 -> 2`, `eventCount: 6`), `run.py status`, and `--archive` replay.
- **Hardening, policy gates, and closeouts (PRs #54, #55, #57–#60):** PR #54 (`b4163b7`, run `45416408595`) archived finished plans and updated `STATUS.md` / `manifests/whitelist.psd1`; PR #55 (`a02d697`, run `45423706790`) hardened `Assert-PlainPathNoReparse` / `Assert-TreeNoReparse` and PowerShell security gates; PR #57 (`2aa0330`, run `45439851794`) added `python-syntax` (`py_compile`), expanded `tests/repository-policy.tests.ps1`, optimized `tests/config-sync.tests.ps1`, and balanced `tests/test-timeouts.psd1` (1255s); follow-on closeouts merged in PR #58 (`3f7449c`, run `45446275515`), PR #59 (`004e64d`, PR run `45603955337`, merge run `45605860982`), and PR #60 (`b99a086`, merge run `45611449749`).
- **Interactive monitoring dashboard (PRs #61, #62):** PR #61 (`8a77f9e`, PR run `45719680892`, merge run `45720812163`) introduced the pure-stdlib loopback dashboard (`dashboard/server.py`, `dashboard/index.html`, `start-dashboard.cmd`, `tests/dashboard.tests.ps1`); PR #62 (`4d5a43a`, head `d020bcf`, PR run `45842165338`, merge run `45844030242`) completed hardening and gate alignment (60s suite budget, 1315s total in `test-timeouts.psd1`).
- **4-track optimization and Antigravity `0.5.0` rollout (PRs #63, #64):** PR #63 (`0945966`, head `eecf298`) recorded the PR #62 closeout. PR #64 (`36e88fa`, head `79a8967`, PR run `46036241684` in `3m17s`, merge run `46090608419` in `3m08s`) landed four optimization tracks: parallel LPT test scheduling in `scripts/run-tests.ps1` (2.58x local speedup, `584.75s` -> `227.07s`) and pinned gitleaks CI cache; `Invoke-BoundedProcess`, DryRun `-Json` contracts, concurrent `agent-dotfiles.ps1 status` with `[Codex Live Skills]`, and MCP `EnabledPolicy = 'preserve-disabled'`; modular `dashboard/lib/` and `dashboard/static/` with streaming `Popen` job logs, safe read-only cancel (`403` on `apply:*`), and `SkillsCatalogCache`; and Antigravity plugin `0.5.0` (9 shared skills), dual-host `AGENTS.md` parity guards, and slimmed `STATUS.md`. On 2026-11-28, live Antigravity `0.5.0` deployment converged (`unchanged`, `unity` `0.1.9-beta` preserved, unified status zero drift) after running `antigravity deploy -Apply` from an external PowerShell 7 window with Antigravity IDE closed.
- **PR #64 closeout and parallel runner contention fix (PR #65):** PR #65 (`b1aa960`, head `7f442af`, PR run `46112075858` in `4m10s`, merge run `46112451312` in `3m33s`) recorded the PR #64 closeout, Antigravity `0.5.0` live convergence, and Windows open-IDE deploy recovery boundary in `STATUS.md`, `docs/HISTORY.md`, and `docs/README.md`, and fixed 4-vCPU CI oversubscription and pipe-drain starvation in `scripts/run-tests.ps1` (default `-MaxParallel` `min(4, max(1, floor(ProcessorCount / 2)))`, ThreadPool minimum worker floor, `WaitForExit` sync before bounded drain, and partial stream output preservation) without weakening any timeout budget.

## Historical branch cleanup archive (2026-11-20 – 2026-11-28)

- **2026-11-20:** Authorized atomic lease-checked deletion of 25 merged remote branches (ancestors of `main` at `f996888`, including 24 matching merged PRs and PR #9 integration), leaving only `main` on `origin`.
- **2026-11-21:** Authorized atomic lease-checked deletion of 5 merged remote branches (PRs #35–#39) and force-deletion of 6 local `fix/*` branches with unmatched `git cherry` commits, leaving only `main` on `origin`.
- **2026-11-25:** Authorized removal of 15 non-`main` local branches (12 ancestors + 3 obsolete) and 16 remote branches via lease-checked deletion, plus cleanup of ignored local leftovers under `tmp/`, `.agent-harness/generated/`, and `.ruff_cache/`, leaving only `main` (`2aa0330`).
- **PR #59 cleanup:** Removed merged `docs/acceptance-and-ci-docs` (local and `origin`), `origin/docs/closeout-5track-optimization`, and `tmp/multimodal-acceptance/`.
- **2026-11-26 (PRs #60–#61):** Authorized lease-checked deletion of `origin/docs/closeout-pr59-cleanup` (`8dec731`, PR #60) and `origin/feat/interactive-dashboard` (`cab2ff6`, PR #61), leaving only `main` (`8a77f9e`) on `origin`.
- **PR #62 cleanup:** Removed merged `fix/dashboard-hardening-and-hygiene` (`d020bcf`, local proven-integrated and remote lease-checked), leaving only `main` (`4d5a43a`) locally and on `origin`.
- **2026-11-28 (PRs #64–#65 cleanup):** Removed proven-integrated local branches (`feat/4track-optimization`, `docs/closeout-pr64`, `swarm-cli-mcp-f64e03ea`, `swarm-cross-docs-638f7e01`) and authorized atomic lease-checked deletion of `origin/feat/4track-optimization` (`79a8967`, PR #64) and `origin/docs/closeout-pr64` (`7f442af`, PR #65), leaving only `main` (`b1aa960`) locally and on `origin`.

## Multimodal and MCP extension acceptance plan (removed 2026-11-25)

Tracks A–C merged into `main` (PRs #19, #23, #24, #25), and ZCode was retired on 2026-11-21. Blender MCP was verified in Codex CLI and Antigravity Desktop on 2026-11-23 (`localhost:9800`, Blender 5.3.0, add-on 2.0, protocol 16). On 2026-11-25, `multimodal-generation` was verified (`applied`) in Antigravity with `$0` extra API spend via the built-in `image-generator` subagent (`1024x1024` `.jpg` artifact, `.prompt.md` sidecar, and vision read-back; video/audio generation and `ffprobe` local checks remain on demand as `ffprobe` is absent locally). Antigravity `unity` plugin `0.1.9-beta` is enabled with skills readable (`loaded`) alongside Unity 6 Editor `6000.3.28f1` (`unity` CLI absent from `PATH`), with live Unity Editor workflow verification deferred to the first active Unity project per owner direction on 2026-11-25. The last commit containing `docs/MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md` is `3f7449c`.

```powershell
git show 3f7449c:docs/MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md
```

## Five code issues and fix verification (removed 2026-11-24)

The five code issues identified against `main` commit `ee2fe15` (plugin upgrade lockout, concurrent personal save overwrite in `config-pull`, MCP diagnostic JSON private values, manual skill ownership tracking, and backup-root boundary enforcement) were all fixed (`5c1126a`, `019d63e`, `3e952dc`, `c167673`, `3ed5b04`, `1d538f7`) and follow-up hardened in PR #39 (`ffb3234`) with isolated regression coverage. The last commit containing `docs/OPEN_CODE_ISSUES.md` is `d430500`.

```powershell
git show d430500:docs/OPEN_CODE_ISSUES.md
```

## Repository-wide optimization plan 2026-11-17 (removed 2026-11-24)

The five tracks closed with an implementation or an owner decision for each of the 14 items.
The [archived plan](https://github.com/MaginaLW/ai-agent-dotfiles/blob/514a564707624ccbacf814f4184667126be9db85/docs/OPTIMIZATION_PLAN_2026-11-17.md) preserves all six decisions.
Under decision 5, the 2026-11-21 inventory confirmed that a downstream project uses
`.agent-harness/profile.psd1`. Project Harness Profiles are now maintained on demand.

```powershell
git show 514a564:docs/OPTIMIZATION_PLAN_2026-11-17.md
```

## ZCode platform, `antigravity-delegation`, and Grok routing retirement (2026-11-21)

ZCode skill deployment, configuration sync (`zcode/AGENTS.md`), MCP projection, `docs/ZCODE.md`, `skills-source/zcode-only/`, `manifests/managed-skills.zcode.txt`, the Codex-only `antigravity-delegation` skill, and the Grok routing clause in `codex/AGENTS.md` were retired on 2026-11-21. The last commit that still contains them is `f1faa91`. Existing `~/.zcode/` files on user machines remain outside this tool's scope.

```powershell
git show f1faa91:docs/ZCODE.md
git show f1faa91:zcode/AGENTS.md
git show f1faa91:skills-source/codex-only/antigravity-delegation/SKILL.md
```

## Antigravity 0.1.0 execution plan (removed 2026-11-16)

The initial Antigravity plugin onboarding plan (`docs/ANTIGRAVITY_PLUGIN_EXECUTION_PLAN_2026-11-13.md`, covering `0.1.0` design, gates, and the six-session App/CLI synthetic acceptance record) was archived after PR #9 (`fad4433`) and subsequent `0.4.0` updates superseded it. The last commit that still has it is `9e81abe`.

```powershell
git show 9e81abe:docs/ANTIGRAVITY_PLUGIN_EXECUTION_PLAN_2026-11-13.md
```

## Transactional live-sync engine (removed 2026-10-09)

The transactional engine was replaced by `scripts/deploy-skills.ps1` and removed on 2026-10-09,
together with its tests, schemas, Git hooks, approved runner and docs. The last commit that
still has all of it is `9793fde`.

| Former path | Content |
|---|---|
| `scripts/sync.ps1`, `scripts/live-*`, `scripts/canonical-*`, `scripts/*-harness-env.ps1`, `scripts/task-skills.ps1`, `scripts/backup*.ps1`, `scripts/internal/` | Plan-bound sync and retirement, live and canonical transactions and recovery, environment activate/rollback/authority, task-skill overlay, backup receipts, the sandbox host |
| `scripts/live-safety-policy.psd1`, `scripts/live-safety-interlock.ps1`, `scripts/runner-policy.psd1` | The release policy, the interlock and the runner toolchain list |
| `scripts/setup.ps1`, `scripts/apply-hooks.ps1`, `scripts/check-hooks.ps1`, `scripts/auto-sync-after-git.ps1`, `scripts/approved-*` | The approved Git-private runner and the preview-only Git hooks |
| `schemas/`, `tools/schema-validator/` | JSON artifact schemas and the pinned schema validator |
| `tests/` (about 30 suites), `tests/test-shards.psd1` | Engine test suites and the CI shard partition |
| `docs/RESTORE.md`, `docs/CI_FAILURE_RULES.md` | Rollback/transaction recovery guide and the CI failure rules R1-R11 |

```powershell
git ls-tree -r --name-only 9793fde -- scripts schemas tests docs
git show 9793fde:docs/CI_FAILURE_RULES.md
```

## Design and plan docs (removed 2026-10-09)

The implementation plans and design specs for finished work were removed from the tree on
2026-10-09 to cut reading cost. The last commit that still has them is `bd46b85`.

| Former path | Content |
|---|---|
| `docs/superpowers/plans/` | Plans: live-safety phases 0-4 and roadmap, hard-kill checkpoints, the post-audit completion plan, harness env phases 1-3, project harness profiles, task-skill hotplug, runtime drift repair, skill/MCP dedup, the agent-platform hardening roadmap |
| `docs/superpowers/specs/` | Designs: live-safety hardening, harness env, task-skill hotplug |
| `docs/specs/` | The Phase 4 schema/CI/release proposal and the project harness profiles design |
| `docs/archive/` | Early sync plan v2, the auto-merge instructions and workflow, the MCP multi-platform design |

To read or restore one:

```powershell
git show bd46b85:docs/superpowers/specs/2026-08-09-live-safety-hardening-design.md
git ls-tree -r --name-only bd46b85 -- docs/superpowers docs/specs docs/archive
```

## Dated status journals and task records (removed 2026-10-10)

The dated status journals and finished task records under `status/archived/` (about 1 MB, mostly
about the removed transactional engine) were removed on 2026-10-10. The last commit that still
has them is `a1e3115`. They may link to files that no longer exist; read those files at the
commits above.

```powershell
git ls-tree -r --name-only a1e3115 -- status/archived
git show a1e3115:status/archived/2026-10-08-status-history.md
```

## Skills import and merge pipeline (removed 2026-10-10)

The import pipeline (`imports/` inbox, archive, quarantine and reports; `inventory-`, `analyze-`,
`dedupe-skills.ps1`, `auto-merge-skills.ps1`, `normalize-skill.ps1`, `skill-candidate-common.ps1`
and `docs/MERGE_POLICY.md`) was replaced by the small `scripts/promote-skill.ps1` on 2026-10-10,
together with the build run reports (`report-common.ps1`, `reports/README.md`) and the guide
code-block checker (`check-guide-examples.ps1`). The last commit that still has them is
`d393999`.

```powershell
git show d393999:docs/MERGE_POLICY.md
git show d393999:scripts/auto-merge-skills.ps1
```

## ZCode feedback-loop pilot (paused 2026-10-10)

The owner paused this repository's harness-model feedback-loop pilot on 2026-10-10. The full
`docs/ZCODE.md` (adoption notes, source versions, the five method adaptations) and the AGENTS.md
feedback-loop section are in commit `08d9021`; the thirteen dated loop runs are in `3341ec9`.

```powershell
git show 08d9021:docs/ZCODE.md
git show 3341ec9:status/archived/2026-10-09-zcode-feedback-loop-history.md
```

## Skill merge notes (removed 2026-10-10)

Each imported skill carried a `MERGE_NOTES.md` with its upstream source and import details. Some
of them named a machine or a local backup path, so all of them were removed; build had always
excluded them from the generated output. The last commit that has them is `ee96301`.

```powershell
git ls-tree -r --name-only ee96301 -- skills-source | Select-String MERGE_NOTES
git show ee96301:skills-source/shared/brainstorming/MERGE_NOTES.md
```

## Claude platform retirement (2026-11-21)

In `4c7dabd`, ZCode still used the Claude build output. Claude configuration sync was opt-in,
and its settings merge preserved home-only fields. The status record at that revision documents
the previous template's marketplace declarations and the local drift observed then. The current
deployment, configuration and profile tools leave existing Claude client files under user control.

## Multi-platform harness profile (removed 2026-10-10)

The unused `multi-platform` library profile, the components only it selected (`commit-command`,
`claude-reviewer`, `codex-reviewer`, `review-prompt`) and `tests/harness-multiplatform.tests.ps1`
were removed on 2026-10-10, together with the unused `Future`, `Requires` and `Conflicts` schema
fields. At that point the profile engine still supported the Command, ClaudeAgent, CodexPrompt
and CodexAgent kinds. It later retired the Claude targets. The last commit containing the
removed `multi-platform` profile and components is `e8ef4c2`.

```powershell
git show e8ef4c2:harness-source/profiles/multi-platform.psd1
git ls-tree -r --name-only e8ef4c2 -- harness-source/components
```

## Privacy history rewrite (2026-08-25)

An exact-path index rewrite redacted the 82 commits then on `main`: four private desktop-state
paths were removed from every commit without opening their contents, and every historical
`STATUS.md` snapshot was mechanically redacted (machine-local paths, device labels, the `.system`
child fingerprint). The rewritten history was published with force-with-lease, and GitHub Support
then ran the server-side GC (ticket `#4697323`, closed by commit `8a70ec0`). The rewrite did not
touch commit messages, so subjects in the unchanged prefix still name the old machine.

- First rewritten commit: `dd4014f` carries the rewritten content (the record names the first
  changed pair old `58b4bc3` -> new `dd4014f`; the 30 commits before `dd4014f` should keep their
  original SHAs by first-changed semantics — the old objects are gone and cannot be diffed).
- Publish head: `bbba28f` (ignore local desktop state; `.gitignore` only, the 83rd commit).
  The rewrite tip before it was `490189d` (82 commits).
- The contemporaneous record lives in the removed design docs at `91e871e`:
  `docs/superpowers/plans/2026-08-09-live-safety-hardening-roadmap.md`.
- Residual cleanups after the rewrite: `5478aa9` (redact two machine paths) and `d11e081`
  (remove the import-era `MERGE_NOTES.md` files that named a machine and local backup paths).

Clones that still resolve the pre-rewrite SHAs predate the rewrite. They must re-clone: export
unique local work first (patches against the old `origin/main` tip, not the old published chain)
and apply it on a fresh clone, then confirm the old SHA no longer resolves. Merging or rebasing
the old chain onto `origin/main` reintroduces the purged objects, and after the server-side GC
that would need another rewrite.

```powershell
git cat-file -t 58b4bc329e3acca6ed38dfe6e0319dcf0f56e173   # fatal on rewritten clones
git rev-list --count bbba28f                                 # 83
git show 91e871e:docs/superpowers/plans/2026-08-09-live-safety-hardening-roadmap.md
```
