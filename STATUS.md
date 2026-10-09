# Project Status

Last updated: 2026-10-09.

This file holds only present-tense facts, open items and known boundaries. Update it by replacing
lines in place. Put dated task logs and evidence in `status/active/<task>.md`, and move finished
records to [`status/archived/`](status/archived/). Before trusting a commit or CI run named here,
check `git log` and the latest GitHub Actions run.

## Current state

- **Policy.** [`scripts/live-safety-policy.psd1`](scripts/live-safety-policy.psd1) has been
  `ReleaseState=released` since `bffa7d7` (2026-09-19). That only makes the production code paths
  reachable. It is not lab acceptance, not deployment authorization and not a mechanical interlock.
  Every production Apply needs four things:
  - live-engine code at HEAD that is covered by an accepted candidate (see **Code** below);
  - a fresh reviewed plan at the current HEAD;
  - the owner's explicit per-item authorization;
  - the built-in host, identity, secret-scan and protected-directory gates.

  Production Apply covers sync, retirement, environment, authority, task overlay, env rollback,
  canonical setup/recover and live recover.
- **Bare calls are not isolated.** A bare public DryRun resolves the real Windows identity and
  writes a real plan. Run maintenance DryRuns only inside the internal sandbox host
  ([docs/README.md §4](docs/README.md#4-日常同步流程)). The standalone `backup.ps1` entry is
  retired and exits `backup-is-transaction-internal`. Managed snapshots come only from transaction
  receipts.
- **Code.** Live-safety Phases 0-3 are complete. Phase 4 implementation, candidate acceptance and
  the read-only/DryRun checkpoint are done. The latest accepted candidate is `ffee36e`
  (cross-volume setup-claim publication), merged as `6741e69` on 2026-10-07. It passed local
  `-All` 43/43, the disposable-identity lab (11 gates, 43/43 suites) and CI. Commits since then
  change only docs, tests and the parse gate (`check-powershell-syntax.ps1`). None of them
  changes a live-engine script. Any later live-engine change needs a new
  accepted candidate before Apply.
- **CI.** `main` was last recorded all green at
  [#206](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/37662955635) (`7c0aab1`).
  Later heads change only docs and tests; check Actions for their runs.
- **First onboarded machine (2026-10-07, owner-authorized).** Canonical setup is `canonical-ready`.
  The first Apply hit the cross-volume defect, and the fixed recovery finalize completed it. The
  `work` environment was adopted through a reviewed plan: claims, state and pair are VALID, one
  unknown live directory was preserved, and Codex `.system` was not touched. The per-machine runner
  is approved, three preview-only Git hooks are installed, and doctor passes.
  A second owner-authorized activation on 2026-10-09 (`work`, environment generation 2) added
  `boring-engineering` to Claude, Codex and Reasonix; lock and live parity pass, no prune occurred,
  the unknown Codex directory and the `.system` marker are preserved.
- **Other machines.** No authority-based setup, adopt or runner approval has run on any other
  machine. Some may still carry legacy pre-live-safety deployments. Take their route from
  `canonical status` and `env authority status` (initial, migrate or adopt); do not assume their
  roots are pristine. Onboarding starts only after the owner names a target; follow
  [docs/ONBOARD_NEW_MACHINE.md](docs/ONBOARD_NEW_MACHINE.md). Onboarding covers the harness-model
  I2 gate, setup, adopt and runner approval. The I2 gate is harness-model's gate for expanding to
  more targets. It is upstream-controlled and currently closed, and the owner clears it; it is not
  a step in the onboarding guide.
- **Hooks and bootstrap.** Both run through the approved Git-private runner. They emit only
  validated, non-consumable previews or events plus an explicit external DryRun command, and never
  Apply or create retirement authority.

## Open items

The [2026-10-07 handoff list](status/archived/2026-10-08-live-safety-hardening.md#2026-10-07-收尾待办清单接手入口)
(items 1-8) is closed.

1. **Owner:** name any further machine before onboarding starts. Each machine gets its own reviewed
   plans and runner approval.
2. **Owner:** decide the over-engineering cleanup. The global entry files were slimmed and the docs/status
   history was pruned on 2026-10-09. CI was split the same day (fast suites per push,
   full suite nightly). Still open: whether to replace the transactional live-sync engine with a
   simpler manifest-scoped copy.
3. **Owner:** adopt, defer or drop the post-release packages F1 (CI evidence persistence),
   F2 (config pull/push boundary), F3 (platform capability registry) and F4 (module dedup).
4. **Owner, low priority:**
   - Which commit carries the privacy-rewrite content.
   - Other clones should re-clone or rebase instead of merging the old history.
   - Whether one agent at a time owns this repository; concurrent agents have collided before.
5. **Agent, when CI work is authorized:** under rule R3, fix the oot-claims-registry
   PowerShell.Stop fixture. It has recurred on #181 and #205 and was closed with reruns.
6. **Opportunistic:** at the next hard-kill reseal, retire the single `@()` flattening-gate
   exemption.

## Known boundaries

- **Plans go stale.** Reviewed plans and `envs/` staging locks are bound to a commit, so any new
  commit invalidates them. `env build` only prepares artifacts. Runner approval is bound to its
  pinned toolchain; drift fails closed with `runner-review-required`.
- **Machine setup.** Real-machine setup has several fail-closed preconditions. All of them
  surface only as canonical-command-failed:
  - the plan and recovery directories must be on the repository's volume;
  - the repository's parent directory must be owned by the access-token owner;
  - that parent must carry no Allow entry for Everyone, Authenticated Users or Users. The check's
    mask includes FullControl, so even a read-only entry fails. This check is the one that caught
    the first onboarded machine.
- **Cross-volume fix.** The setup-claim cross-volume publication fix (fee36e) is proven on one
  machine only.
- **Engine limits.** Cross-authority root overlap is rejected by the SID-scoped occupancy index
  (`b02e1d4`). Known limits remain:
  - the recovery locator is phase-only;
  - `_pending` move records classify as manual recovery;
  - drift protection is hash-based;
  - a rollback plan's `Current` identity binding is not enforced;
  - the authority-active status surface compares the recorded task-overlay hash to the computed
    one with a case-sensitive `-cne` (`harness-authority-status-common.ps1`), while the recorded
    intent hash is lowercase and the computed hash is uppercase; the derived "task skill overlay
    changed since activation" suffix can therefore be a false signal, verified by case-insensitive
    equality. Lock and live parity still pass and the command exits 0.
- **CI.** Push and pull request run the gates job plus fast suites. The three heavy shards (about 97 minutes) run nightly and on manual dispatch. A same-SHA rerun only shows
  whether a red is unrelated to the commit (rule R3 in
  [docs/CI_FAILURE_RULES.md](docs/CI_FAILURE_RULES.md)). The `root-claims-registry`
  PowerShell.Stop timing red has recurred on docs-only commits (#181, #205); see open item 5. A further recurrence
  needs the fixture fix or escalation R3 calls for, not another rerun, and never a weaker gate or
  budget. `canonical-hard-kill` seals the reviewed script bytes, so editing a sealed script needs
  a full reseal.
- **Local validation on an onboarded machine.** `tests/harness-env.tests.ps1` cannot complete on
  this machine. Its activation-reporting sections invoke the real status script without an identity
  override, and the machine has a live authority with claims, so the run fails closed with
  `authority-reasonix-root-switch-forbidden-after-claims` (seven assertions) and aborts before its
  summary. The failure reproduces at a parent commit that lacks the change under test, so it is
  machine-state-driven; use a control run like that before attributing this suite's red to a change,
  and treat CI, where no authority exists, as its arbiter.
- **Out of scope.** Codex `config.toml`, Reasonix `config.toml`/`.env`, credentials, sessions and
  caches are outside sync scope. Machine-private evidence (`tmp/` and an external private root) is
  not committed; check its index in the archived live-safety record before deleting any of it.

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
  - the MCP registration subsystem (no live MCP config was changed);
  - OpenClaw/OpenCode;
  - ArkCLI-managed skills.
- **Integrations.** ZCode is a project-instruction integration, not a deployment target. The
  harness-model feedback loop runs only for a substantive issue or an explicit request
  ([docs/ZCODE.md](docs/ZCODE.md)).
- **Skill retirement.** Deleting a skill's source leaves its old live directory unknown and
  preserved. Pruning it needs an explicit, plan-bound retirement; see
  [docs/README.md §5](docs/README.md#5-修改已有-skill-的流程).

## History

- Dated journal through 2026-10-08:
  [status/archived/2026-10-08-status-history.md](status/archived/2026-10-08-status-history.md).
- Live-safety evidence and handoff lists:
  [status/archived/2026-10-08-live-safety-hardening.md](status/archived/2026-10-08-live-safety-hardening.md).
- ZCode feedback-loop runs: [status/archived/2026-10-09-zcode-feedback-loop-history.md](status/archived/2026-10-09-zcode-feedback-loop-history.md).
- Removed design and plan docs: [docs/HISTORY.md](docs/HISTORY.md).
