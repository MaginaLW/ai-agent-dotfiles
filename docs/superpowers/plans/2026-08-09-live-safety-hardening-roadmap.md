# Live Safety Hardening Roadmap Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Status:** Prepared from the approved design; implementation has not started. This roadmap grants no permission to stage, commit, publish, or run a real live Apply/rollback. A later `ReleaseState=released` means only that the code protocol interlock is ready; it is not repository publication or live-mutation authorization.

**Goal:** Replace the repository's current live and canonical mutation paths with the reviewed, plan-bound, process-crash/hard-kill-recoverable safety protocol without discarding the current skill/MCP cleanup or retirement work.

**Approach:** Treat current HEAD `7d9dd08` plus these untracked design/plan documents as the functional baseline. Deliver five ordered, independently reviewable phases: stop unsafe entrypoints, transact canonical changes, transact live changes, establish shared environment authority, then validate/release the protocol. Production live Apply stays interlocked until every phase passes; the final rollout stops after real-machine status and dry-run evidence.

**Materials:** `docs/superpowers/specs/2026-08-09-live-safety-hardening-design.md`; current `STATUS.md`; current commit `7d9dd087d3861f7c9ddde9eaf2a26f72552a9cb0`; `docs/superpowers/plans/2026-08-09-skill-mcp-deduplication.md`; the five phase plans linked below.

**Validation:** Every phase's focused suites pass in isolated repositories/fake homes; the final unified runner discovers every `tests/*.tests.ps1` suite exactly once; every artifact in the contract registry passes real Draft 2020-12 validation; production hooks/bootstrap perform zero live writes; no real live Apply or rollback is run without a later, separate user authorization.

---

## Current-working-tree reconciliation

The implementation must preserve these current-baseline outcomes:

| Area | Current baseline | Required treatment |
|---|---|---|
| Skill/MCP cleanup | Canonical inventory is now 7 shared + 8 Codex-only; repository MCP registration was removed | Do not restore deleted skills, MCP scripts, schemas, tests, or templates |
| Explicit retirement | `sync.ps1` now supports `-RetireManifestPath`, binds retirement evidence and rechecks a target before deletion | Promote it to `OperationKind=retirement`; interlock it in Phase 0 and migrate it into the common plan/receipt/journal protocol in Phase 2 |
| Sync plan binding | Schema 2 now includes source/live roots and rehashes saved `Plans` | Preserve those checks, then replace the ad-hoc JSON hash with `PlanPayload`/`PlanHash`/`DocumentHash` and the full execution context |
| Reasonix backup | The custom Reasonix target is now forwarded to backup and recorded in the manifest | Preserve the actual-root plumbing; replace timestamp/full-tree backup with a unique managed-only receipt |
| Environment lock | `env.lock.json` is already schema 3 and records all three task-overlay baselines; the current commit identity makes existing staging locks stale | Keep schema 3; rebuild only in isolated planning/tests. The machine authority state, still repo-local schema 2, is the artifact that must migrate to shared schema 3 |
| Current live state | `STATUS.md` records legacy schema 2 `work` with empty overlay and live 2/4/2 parity; activation attestation now drifts only because current HEAD changed, while 7/15/7 is an ended intermediate snapshot | Preserve parity/drift evidence but still require shared-authority migration; do not refresh attestation or select/Apply `work`/`full` during implementation |

The approved design did not originally list the newly introduced retirement path as an operation. Choosing the current working tree as baseline resolves that delta as follows: retirement remains supported, but only as an explicit reviewed operation; Git hooks never create or consume retirement authority.

The baseline choice means “preserve and build on these bytes”; it does not authorize staging or committing the safety implementation. The cleanup is already current HEAD; the seven safety documents remain untracked, and the three modified Reasonix desktop-state files remain user-owned. Every task must still inspect index, worktree, and untracked layers separately, record SHA-256 for every overlapping **non-protected** file immediately before editing, and abort/re-map if any prehash changes. The four protected Reasonix paths use literal metadata/no-read checks only and are never hashed. Never use reset/stash/checkout to manufacture a clean baseline.

## Ordered release unit

1. [Phase 0 — Entrypoint Interlock and Preview-Only Automation](2026-08-09-live-safety-phase-0-entry-interlock.md)
2. [Phase 1 — Canonical Source Transactions](2026-08-09-live-safety-phase-1-canonical-transactions.md)
3. [Phase 2 — Live Plan, Backup, Journal, and Recovery](2026-08-09-live-safety-phase-2-live-transactions.md)
4. [Phase 3 — Shared Environment Authority and Task Overlay](2026-08-09-live-safety-phase-3-shared-authority.md)
5. [Phase 4 — Schema/CI Contract and Safe Release](2026-08-09-live-safety-phase-4-validation-release.md)

Phase 0 may ship alone as a safety stop. Phases 1–3 must not re-enable production live mutation. Phase 0 through Phase 4 together form the first live-capable protocol release.

Phase 4's released public-CLI test requires the complete implementation in an exact, separately user-authorized reviewed commit inside a disposable OS identity. If no such commit exists, internal sandbox verification may continue but the release switch remains interlocked; this roadmap does not grant commit or publication authority.

## Explicitly deferred follow-ups

Completion of this roadmap does not claim that every repository write path has been refactored. Track these as separate designs after the managed-skills protocol is released:

- Config pull/push: whitelist path canonicalization, absolute/`..`/reparse rejection, backup-root collision/disjointness, and production scan-gate policy.
- Project Harness Profiles: central platform capability registry and any future Reasonix project-output support; current apply remains project-local.
- Platform registry/general PowerShell module rewrite: deduplicate hard-coded platform/root tables only after the safety contract is stable.
- Real environment selection: choosing `work` versus `full` and performing any live migration/activation remains a separate, explicitly authorized operation.

### Task 1: Freeze and Reconcile the Selected Baseline

**Artifacts / Locations:**
- Modify: `STATUS.md`
- Review: `docs/superpowers/plans/2026-08-09-skill-mcp-deduplication.md`
- Review: `docs/superpowers/specs/2026-08-09-live-safety-hardening-design.md`
- Record in: this roadmap's task notes

- [ ] **Step 1: Capture the non-private workspace shape**

Run all three non-private views separately:

```powershell
$protectedReasonix = @(
  ':(exclude).reasonix/desktop-topic-auto-title-meta.json',
  ':(exclude).reasonix/desktop-topic-created-at.json',
  ':(exclude).reasonix/desktop-topic-title-sources.json',
  ':(exclude).reasonix/desktop-topic-titles.json'
)
git status --short --untracked-files=all -- . $protectedReasonix
git diff --stat -- . $protectedReasonix
git diff --cached --stat -- . $protectedReasonix
```

For the four protected Reasonix desktop-state paths, use only `git ls-files --stage --` and `Test-Path -PathType Leaf` with the four explicit names. The exact negative pathspecs above must not hide any fifth/adjacent `.reasonix` entry: a non-ignored adjacent file remains visible and is included in candidate/scan gates. Do not run an unrestricted status/diff/hash/content command over the protected files.

Expected: cleanup/retirement is current HEAD, no non-Reasonix staged/unstaged implementation change exists, and exactly the design, roadmap, and five phase plans are additional untracked documents. The three user Reasonix modifications remain visible only through exact metadata checks.

- [ ] **Step 2: Contain the committed STATUS privacy exposure before any implementation commit or publication**

Current HEAD `7d9dd08` contains complete machine-local backup paths, an unredacted device label, and a Codex `.system` content hash/count in `STATUS.md`; the same public commit/history also tracks four opaque machine-private `.reasonix/desktop-topic-*` blobs whose contents remain unread. Before any safety implementation commit or publication, apply an additive **worktree** STATUS redaction: replace paths with backup basenames, replace the device label with a generic redacted label, replace content fingerprint/count with marker-presence evidence, and change the contradictory inventory claim that current staging locks are valid to the later observed fact that commit-bound locks/attestation are stale while live parity passes. Verify only the worktree copy now; HEAD/index are expected to retain the already-public bytes until a later separately authorized staging/commit step. Because current-tree redaction and future index-only untrack do not erase public history, separately ask the user to choose whether both the historical STATUS exposure and four opaque historical blobs are accepted or require an explicitly authorized history rewrite/force-push; never read those blobs, perform destructive history remediation, or delete backups under this plan.

- [ ] **Step 3: Recheck overlapping implementation files**

Re-read the current versions of `scripts/sync.ps1`, `scripts/backup.ps1`, `scripts/build-harness-env.ps1`, `scripts/harness-env-common.ps1`, `schemas/sync-plan.schema.json`, and their tests before editing.

Expected: work is based on current `7d9dd08` bytes, not on line numbers or conclusions from the superseded `89019f4` audit alone.

- [ ] **Step 4: Protect unrelated work**

Do not reset, stash, stage, commit, restore, or rewrite any pre-existing working-tree change. If one of the overlapping files changes again during execution, stop that task, re-read the file and its diff, and update only the affected checklist before continuing.

- [ ] **Step 5: Record the baseline result**

Add a dated note under this task stating which current fixes were retained and which targeted defects remain. Do not record machine-private paths or `.reasonix` contents.

### Task 2: Complete Phase 0

**Artifacts / Locations:**
- Execute: `docs/superpowers/plans/2026-08-09-live-safety-phase-0-entry-interlock.md`
- Review: `scripts/sync.ps1`, `scripts/auto-sync-after-git.ps1`, `scripts/bootstrap-clone.ps1`

- [ ] **Step 1: Execute every Phase 0 task in order**

Keep the production live interlock enabled throughout the phase.

Before Phase 0 runs any repository scan, obtain the explicit user approval required by `AGENTS.md` for the exact four-path `.reasonix/desktop-topic-*` no-read input boundary. If approval is absent, Phase 0 stops before scan; it must not read those files or broaden the exclusion.

- [ ] **Step 2: Run the Phase 0 checkpoint**

Expected: default bootstrap and all installed Git hooks are non-consumable-preview-only and actionable plans require an explicit external DryRun; checkout toolchain changes produce `runner-review-required`; every production Apply/rollback path, including retirement, plus standalone legacy backup exits before live traversal, backup or mutation with `safety-protocol-upgrade-required`; doctor records only the no-follow `.system` root-entry marker.

- [ ] **Step 3: Review requirements, then quality**

First compare behavior to design §§4.1 and 5 Phase 0. Then review path/ACL handling, pinned-runner trust, error exits, and fake-home isolation.

### Task 3: Complete Phase 1

**Artifacts / Locations:**
- Execute: `docs/superpowers/plans/2026-08-09-live-safety-phase-1-canonical-transactions.md`
- Review: `scripts/skills-common.ps1`, `scripts/normalize-skill.ps1`, `scripts/promote-skill.ps1`, `scripts/auto-merge-skills.ps1`

- [ ] **Step 1: Execute every Phase 1 task in order**

Preserve the selected canonical inventory and never treat current manifest dirty bytes as transaction recovery input.

- [ ] **Step 2: Run the Phase 1 checkpoint**

Expected: normalize/promote/merge use reviewed external plans, one repo-scoped lock, durable multi-target recovery, and deterministic isolated build/scan; injected failure or hard kill leaves canonical source, managed generated outputs, and manifests byte-for-byte unchanged or recoverable.

- [ ] **Step 3: Review requirements, then quality**

First compare behavior to design §§4.2 and 6.1. Then review SafeTreeWalker use, journal reconciliation, dirty-manifest handling, and batch atomicity.

### Task 4: Complete Phase 2

**Artifacts / Locations:**
- Execute: `docs/superpowers/plans/2026-08-09-live-safety-phase-2-live-transactions.md`
- Review: `scripts/sync.ps1`, `scripts/backup.ps1`, `scripts/rollback-harness-env.ps1`

- [ ] **Step 1: Execute every Phase 2 task in order**

Migrate normal sync and explicit retirement into the same transaction host; do not retain a flag-only mutation branch.

- [ ] **Step 2: Run the Phase 2 checkpoint**

Expected: a saved document is self-validated and re-planned under a global lock; backup returns a complete managed-only receipt; numbered journals survive hard kill; rollback/recovery bind every snapshot and disk identity; `.system` and unknown contents are never traversed.

- [ ] **Step 3: Review requirements, then quality**

First compare behavior to design §§4.3–4.4 and 6.4. Then review lock timing, receipt finalization, crash windows, retirement parity, and cleanup-on-success.

### Task 5: Complete Phase 3

**Artifacts / Locations:**
- Execute: `docs/superpowers/plans/2026-08-09-live-safety-phase-3-shared-authority.md`
- Review: `scripts/harness-env-common.ps1`, `scripts/activate-harness-env.ps1`, `scripts/task-skills.ps1`

- [ ] **Step 1: Execute every Phase 3 task in order**

Use the existing lock schema 3 as materialization evidence and migrate only the machine authority state.

- [ ] **Step 2: Run the Phase 3 checkpoint**

Expected: clones/worktrees discover one HomeAuthority; migrate/adopt/repair-adopt/takeover are distinct reviewed operations; ordinary activation cannot migrate implicitly; all three platform baselines are required; env/task Apply consumes the caller-reviewed external plan and exact receipt.

- [ ] **Step 3: Review requirements, then quality**

First compare behavior to design §§4.5 and 6.2–6.3. Then review authority-key stability, root-claim overlap, controller takeover, legacy gaps, and state/journal reference order.

### Task 6: Complete Phase 4 and Release the Protocol

**Artifacts / Locations:**
- Execute: `docs/superpowers/plans/2026-08-09-live-safety-phase-4-validation-release.md`
- Review: `.github/workflows/validate.yml`, `schemas/`, `docs/`, `.gitignore`, `.claude/settings.json`

- [ ] **Step 1: Execute validation, CI, and documentation tasks**

Do not switch the tracked protocol policy from interlocked to released until every earlier phase and every Phase 4 negative/positive test passes.

- [ ] **Step 2: Remove `.reasonix` desktop-state paths from the Git index only**

Follow the exact preservation checks in Phase 4. Never open, copy, rewrite, or delete the local files.

- [ ] **Step 3: Run the release checkpoint**

Expected: real Draft 2020-12 validation passes, the unified runner discovers every suite exactly once, non-suite CI gates remain, docs match the new CLI, and production Apply has no skip-gate or internal-plan path.

- [ ] **Step 4: Review requirements, then quality**

First compare the result to design §§4.6 and 11. Then review dependency pinning, offline behavior, timeout process-tree cleanup, docs consistency, and tracked-file hygiene.

### Task 7: Produce Real-Machine Read-Only and Dry-Run Evidence

**Artifacts / Locations:**
- Update after evidence: `STATUS.md`
- Create outside tracked working tree: pending authority/activation plan and artifact manifest
- Review: `docs/superpowers/specs/2026-08-09-live-safety-hardening-design.md` §7

- [ ] **Step 1: Run read-only status commands**

Run doctor, hook status, config status, env status, task status, `agent-dotfiles.ps1 canonical status`, `canonical recover status`, and `live recover status`. The zero-write canonical selector checks the exact common-dir setup-state/global claim before live authority routing. If setup is complete and a first-authority custom Reasonix root is intended, pass the same `-ReasonixLiveSkillsPath` to `env authority status`; otherwise use the default. Do not read protected `.reasonix` contents.

Expected: unresolved canonical/live transaction selects recovery first; absent canonical setup selects only `canonical-setup-required`; otherwise authority status identifies exactly one of initial, ordinary activation, migrate, adopt, repair-adopt, takeover, recovery, `controller-owner-action-required`, or manual recovery.

- [ ] **Step 2: Build and validate the route-correct fresh lock without Apply**

Branch before any build. If setup is absent, create/review only `agent-dotfiles.ps1 canonical setup -DryRun -PlanPath <new>` and stop for a separate Apply authorization; after setup succeeds, restart this task from Step 1 in a new invocation. `controller-owner-action-required` and manual recovery report evidence and stop with no plan; recovery builds only transaction-recovery evidence; takeover validates existing parity/state-only evidence; initial/ordinary activation and authority routes needing a selected environment let their DryRun command create and bind its own external materialization/env-build v3 artifact. Migrate uses the validated legacy name and requires exact legacy state plus matching old activation lock; the stale old lock remains immutable legacy evidence only and is never used as the fresh/current lock. Adopt/repair-adopt never infer a name from missing/corrupt bytes: pause for an explicit user-selected `<name>`, then build a fresh lock; adopt records legacy as MISSING|UNTRUSTED with no old-lock prerequisite, while repair-adopt binds valid claims plus either exact corrupt ControlBase bytes/path/hash or a MISSING marker that forbids the path, and treats any old lock as optional untrusted evidence. No route emits a separate unregistered evidence artifact or overwrites the only old evidence.

- [ ] **Step 3: Generate one route-correct external plan**

Generate exactly one plan selected by status: canonical setup when setup is absent, otherwise initial/environment/migrate/adopt/repair-adopt/takeover/recovery. Setup, owner-action, and manual routes end the invocation without falling through to a second plan. Use only the route-owned fresh lock where required; inspect all three platform actions and treat any unexplained mutation or prune as drift.

- [ ] **Step 4: Validate and review the plan artifact**

Run the artifact validator against the plan manifest and verify PlanHash, DocumentHash, legacy evidence/fresh lock, controller/root claims, `.system` marker, unknown inventory markers, and expected backup targets.

- [ ] **Step 5: Stop before mutation**

Do not run Apply or rollback. Report the exact plan path, redacted hashes, route, and material add/update/no-op/prune counts to the user and wait for a new explicit authorization.

- [ ] **Step 6: Update current evidence only**

Update `STATUS.md` with commands actually run and observed outcomes. Do not mark live parity restored or authority migrated until an independently authorized Apply has really succeeded.
