# Shared Environment Authority and Task Overlay Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Status:** Prepared from the approved design; implementation has not started. This phase grants no Git staging/commit/publish or real authority/live Apply authorization; production mutation remains interlocked.

**Goal:** Make one HomeAuthority-level schema 3 state the sole selector for managed live skills across clones/worktrees, with explicit migrate/adopt/repair-adopt/takeover transitions and three-platform task baselines.

**Approach:** Preserve the current env-lock schema 3 as materialization evidence and reuse the minimal shared state 3/root-claims/read/atomic-target contract already delivered in Phase 2. This phase adds transition semantics: read-only legacy/corrupt diagnosis, reviewed migrate/adopt/repair-adopt/takeover, external-plan activation, exact-receipt state commit, and task overlay transactions. Finally upgrade the pinned runner from Phase 0 diagnostics to selection-aware non-consumable previews plus exact external DryRun commands.

**Materials:** Approved design §§4.5 and 6.2–6.3; current `scripts/harness-env-common.ps1`; current schema 3 `env.lock.json`; current repo-local schema 2 `state/current-env.json`; Phase 2 live transaction/receipt/recovery host.

**Validation:** A second clone/linked worktree discovers the same active selection; legacy or corrupt state cannot enable ordinary Apply; migrate/adopt/repair-adopt/takeover routes are exclusive and plan-bound; custom roots can be established only during initial/migrate/adopt; Reasonix baseline removal is never treated as addition-only; state/receipt/journal references form an acyclic, fully validated graph.

---

### Task 1: Freeze Environment Lock 3, Consume Env Build 3, and Complete Shared-State Transition Semantics

**Artifacts / Locations:**
- Review/reuse without shape changes: `schemas/harness-env-lock.schema.json`
- Review: `schemas/harness-env-build.schema.json`
- Review/reuse without shape changes: `schemas/current-env-state.schema.json`
- Review before Task 3 emits plans: `schemas/sync-plan.schema.json`
- Modify: `scripts/harness-env-common.ps1`
- Review: `scripts/build-harness-env.ps1`
- Review: `scripts/sync.ps1`
- Modify: `scripts/shared-authority-state-common.ps1`
- Modify: `scripts/home-authority-common.ps1`
- Create: `tests/harness-authority.tests.ps1`
- Modify: `tests/harness-env.tests.ps1`
- Modify: `tests/sync.tests.ps1`
- Modify: `schemas/artifact-contracts.psd1`

- [ ] **Step 1: Add artifact graph tests**

Assert env lock contains definition, three manifest/source/materialized hash maps, task overlay hash, and complete Claude/Codex/Reasonix baseline; assert it does not contain self LockHash, plan, receipt, journal, or state hashes. Assert state references only artifacts available before state commit.

- [ ] **Step 2: Freeze current lock schema 3**

Verify that Phase 2's frozen schema already enforces the current required semantic field set, types, ordering and unique names; do not tighten or reinterpret it here. If a constraint or required semantic field is missing, return the change to the Phase 2 owner with its producer/fixtures and an explicit version decision instead of making schema 3 mean two incompatible shapes.

- [ ] **Step 3: Verify the Phase 2 materialization producer before any authority plan**

Phase 2 must already have shipped env-build v3 and initial named-`full` consumption before this checkpoint. Re-run its emitter-derived positives and missing-platform/empty-root/hash/version negatives; verify Claude/Codex/Reasonix materialized roots, normalized root evidence, per-platform source/manifest/task baselines, RepositoryCommit, definition/lock inputs, and `MaterializationHash`. Do not change that v3 shape here. Every migrate/adopt/repair-adopt/environment producer consumes only this exact contract, while initial remains covered by Phase 2 regression tests.

- [ ] **Step 4: Complete the discriminated shared-state branches**

Keep Phase 2's single `SelectionKind=environment` plus `LastOperationKind` branches. Every branch retains EnvironmentName/lock/task baseline; initial selects named `full`, so no full-repo/MISSING selection exists. Receipt-bearing initial/environment/task-overlay/migrate/adopt/repair-adopt/retirement/environment-rollback branches require ID/hash; `controller-transition` requires `ReceiptRef=NO_LIVE_MUTATION` while preserving the existing selection. `live-recover-*` is only a closing PlanKind/CommandKind, never an execution/result OperationKind and never a committed-state branch: finalize preserves the source poststate and rollback restores its prestate. Require HomeAuthorityKey, RootClaimsHash, Apply-derived FinalResolvedIdentities/FinalTargetContextHash, controller/toolchain/plan/journal/final managed hashes; never store plan-only TargetContextIntent or AuthorityStateHash inside the state.

- [ ] **Step 5: Verify frozen authority plan branches before the authority producer**

Verify Phase 2's already registered migrate, adopt, repair-adopt, and controller-transition branches, including fixed command evidence fields, StateIntent, schema fixtures, named semantic validators, and sealed generic-host documents. Do not modify schema-v3 shape or reuse a sealed fixture as public evidence. Task 3 must not emit any authority plan until the frozen contracts pass with its real inputs.

- [ ] **Step 6: Implement separate legacy/shared readers**

`Read-LegacyHarnessEnvState` reads only repo-local schema 2 evidence. Reuse Phase 2 `Read-HomeAuthorityState` for ControlBase schema 3 and its separate immutable claims file. No generic reader may treat legacy/state/claims as one another or delete/move the legacy file.

- [ ] **Step 7: Verify schemas and graph**

Run the state/lock section of `tests/harness-authority.tests.ps1`, env-build v3 cases in `tests/harness-env.tests.ps1`, initial-v3 regression cases in `tests/sync.tests.ps1`, and real artifact validation.

Expected: current valid env locks remain accepted; legacy state is never accepted as authority; cyclic/self-hash fixtures fail.

### Task 2: Add Authority-Aware Read-Only Status

**Artifacts / Locations:**
- Modify: `scripts/list-harness-env.ps1`
- Modify: `scripts/status-harness-env.ps1`
- Modify: `scripts/harness-env-common.ps1`
- Modify: `schemas/harness-env-list.schema.json`
- Modify: `schemas/harness-env-status.schema.json`
- Modify: `schemas/artifact-contracts.psd1`
- Modify: `tests/harness-env.tests.ps1`
- Create/modify: env list/status v2 positive and negative fixtures under `tests/fixtures/artifacts/`

- [ ] **Step 1: Write status-route fixtures**

Cover no authority/pristine roots, no authority/non-empty roots, invalid legacy artifact with empty and non-empty roots, valid shared state, legacy state core complete with parity pass/fail, legacy Reasonix baseline gap, corrupt and MISSING schema 3 state with valid claims, corrupt claims, controller mismatch with parity pass, controller mismatch with parity failure and no journal, incomplete reservation/journal, root claim mismatch, and project RequiredEnv mismatch.

- [ ] **Step 2: Upgrade list/status schemas to version 2**

Include Reasonix skill counts and authority route/status, HomeAuthorityKey redacted label, controller match, lock/definition/task/live parity, root-claim validity, receipt reference hash, recovery status, legacy schema/gaps, and one recommended next operation. Freeze the intended-root status branch here—not in Task 3—with optional redacted RequestedReasonixRoot label, required `RequestedInitialRootContextHash`, and `FilesystemCapabilityStatus=UNPROBED`; default-root and existing-claims branches have strict required/forbidden shapes, and no status branch contains FilesystemCapabilityHash or probe artifacts. Remove clone-local BackupReference semantics. Register both producer/schema versions, emitter-derived default/custom empty/nonempty positives, unknown-field/missing-Reasonix/wrong-route/probed-status negatives, and any required semantic validators in this task before validation.

- [ ] **Step 3: Keep status strictly read-only**

Status may resolve identities/hash managed trees through SafeTreeWalker and marker-inventory unknown/`.system`; it never builds, copies, writes plans, creates authority, repairs state, or changes hooks.

- [ ] **Step 4: Implement deterministic routing**

Return recovery before every other route when a reservation/journal is incomplete. With valid schema 3 state/claims, return ordinary activate only for the current controller, takeover only for a foreign controller with parity pass, and `controller-owner-action-required` for a foreign controller with parity fail/no journal. With valid claims but CORRUPT or MISSING state, return repair-adopt with `StateEvidence=CORRUPT|MISSING`; corrupt/overlapping claims are manual. With no schema 3 claims, return migrate only when schema 2 core **and its old live parity** validate; valid core with parity failure is `manual-recovery-required`, not adopt. If any legacy artifact exists but its core is invalid—including empty live roots—return adopt while preserving/binding it as UNTRUSTED; if no legacy artifact exists, non-empty roots return adopt and only fully pristine roots return initial. Exactly one route is emitted.

- [ ] **Step 5: Verify outputs**

Run relevant harness-env tests and validate list/status artifacts.

Expected: exactly one route is recommended; `ReasonixSkillCount` validates; no fixture path is modified.

### Task 3: Add the `env authority` Command Surface

**Artifacts / Locations:**
- Create: `scripts/authority-harness-env.ps1`
- Modify: `scripts/agent-dotfiles.ps1`
- Modify: `tests/agent-dotfiles.tests.ps1`
- Modify: `tests/harness-authority.tests.ps1`

- [ ] **Step 1: Add routing/mode failures**

Cover `status`, `migrate`, `adopt`, `repair-adopt`, and `takeover`; status with default/custom empty and nonempty Reasonix roots; missing action/name/required evidence path/PlanPath; DryRun+Apply; wrong operation kind; implicit plan generation; public skip switches; and the shared worktree/arbitrary-Git/reparse-alias PlanPath rejection table.

- [ ] **Step 2: Route status and planned transitions**

Add strictly read-only `env authority status [-ReasonixLiveSkillsPath <absolute>]`, where the optional root is legal only before schema 3 claims exist and the `MetadataOnly` resolver inventories it into `RequestedInitialRootContextHash` with zero capability probe/temp/filesystem write; once claims exist, reject the switch even if its text matches and resolve only from the immutable claim. Add zero-write sentinels for absent/custom roots, post-claim same/different selector rejection, and capability-cache misses. Add fixed transitions: `migrate <name> -LegacyStatePath <exact-current-repo-path> [-ReasonixLiveSkillsPath <absolute>]`, `adopt <name> [-ReasonixLiveSkillsPath <absolute>]`, `repair-adopt <name> [-CorruptStatePath <exact-authority-state-path>]`, and `takeover <name>`, each with exactly one `-DryRun|-Apply -PlanPath`. Migrate must receive the exact legacy locator on both invocations. Repair-adopt requires the exact ControlBase state path only for `StateEvidence=CORRUPT`; `StateEvidence=MISSING` forbids it. Initial/migrate/adopt must repeat the same optional root selected at status, bind the same metadata-only context hash, then separately run/bind MutationPreflight; the override is forbidden elsewhere. repair-adopt/takeover reject evidence/root switches not assigned to their state branch. DryRun creates a new external plan; Apply requires that exact existing plan and never regenerates it.

- [ ] **Step 3: Bind operation-specific context**

Migrate binds the one exact current-repo legacy file path/hash/core fields/LegacyGap, verified old live parity, target lock, and optional default/custom Reasonix stable location. Adopt binds actual current live inventories, optional default/custom Reasonix stable location, and explicitly treats any existing invalid legacy file as UNTRUSTED evidence whether live is empty or non-empty. Both bind the complete forbidden-root result and TargetContextIntent. Repair-adopt uses a strict oneOf: CORRUPT binds the exact ControlBase state path/raw bytes hash plus durable preimage; MISSING binds an explicit MISSING marker and forbids path/hash. Both require immutable claims hash/identities and current live. Takeover maps to `LastOperationKind=controller-transition`, binds existing authority/controller/parity, and declares `NO_LIVE_MUTATION`; neither accepts a root override.

- [ ] **Step 4: Verify dispatcher behavior**

Run CLI and authority tests.

Expected: custom empty/nonempty Reasonix inventory changes initial versus adopt routing correctly; no transition can be reached through ordinary activate/sync; operation kinds, requested-root contexts, and plans cannot be interchanged.

### Task 4: Implement Reviewed Migration, Adoption, and Corrupt-State Repair

**Artifacts / Locations:**
- Modify: `scripts/authority-harness-env.ps1`
- Modify: `scripts/harness-env-common.ps1`
- Modify: `scripts/shared-authority-state-common.ps1`
- Modify: `tests/harness-authority.tests.ps1`

- [ ] **Step 1: Encode the schema 2 migration core**

Require SchemaVersion=2, non-empty Name, absolute HomeRoot matching HomeAuthorityKey, internally consistent DefinitionHash/LockHash/RepositoryCommit/TaskOverlayHash against preserved old activation evidence, all three ManifestHashes, and Claude/Codex TaskOverlaySkills. RepositoryCommit need not equal current HEAD; record that expected case as `LegacyDrift=RepositoryCommitAdvanced` and require old live parity plus a separately validated fresh current-HEAD lock for the same name. Only missing Reasonix baseline is allowed as `LegacyGap=ReasonixBaselineMissing`; any other missing/mismatched core field routes to adopt even when actual live roots are empty. A core-valid state whose old live parity fails routes manual and cannot silently adopt over contradictory trusted evidence.

- [ ] **Step 2: Plan the complete target state**

The public authority DryRun command itself creates a new external EnvironmentMaterializationRoot, builds the CLI-selected name, validates current-HEAD env-build/lock, and binds that exact root/artifact into its plan; there is no separate prebuilt-lock handoff or unbound user-supplied materialization. For `migrate`, the validated legacy state supplies the same name and the branch must re-read/bind exact legacy state plus matching old activation-lock paths/hashes; that stale commit-bound lock is immutable legacy evidence only, never the fresh target/current lock. For `adopt`, the user explicitly supplies `<name>` because missing/untrusted legacy bytes cannot choose it; encode `LegacyEvidence=MISSING|UNTRUSTED`, optionally bind discovered old bytes by exact path/hash, never require or trust an old lock, and use actual live plus the fresh lock as authority. Do not emit a separate unregistered evidence artifact. Establish all three immutable stable root claims (including optional custom Reasonix) and plan live actions from current content. Treat legacy BackupReference as display-only untrusted evidence and never overwrite the only old lock/state while materializing.

- [ ] **Step 3: Plan corrupt-state repair without releasing claims**

Repair-adopt is permitted only when Phase 2 validates immutable root claims and their current identities. Require the user to select `<name>` explicitly; the DryRun command independently builds it into a create-new external EnvironmentMaterializationRoot, validates its current-HEAD schema 3 env-build/lock and all three task baselines, and binds that fresh lock plus current live actions into the repair plan. Never source EnvironmentName/lock/task fields from corrupt or absent state. For `StateEvidence=CORRUPT`, bind the exact current ControlBase state locator/raw bytes hash without interpreting fields and keep the old bytes as immutable preimage. For `MISSING`, bind only the missing marker and reject `CorruptStatePath`/fabricated hash. Any discovered old lock is optional untrusted evidence, never a prerequisite. Invalid/overlapping claims route to manual recovery and cannot use ordinary adopt/takeover.

- [ ] **Step 4: Apply through the Phase 2 host**

Under Phase 2's canonical→optional-overlay→global lock order, revalidate repository/materialization/plan/evidence/current live/all canonical+home claims, create the durable reservation and exact receipt, transact every managed target, verify postconditions, then use the Phase 2 generic targets to create proposed immutable claims (first authority only) and atomically create/replace state 3 before finalizing the journal. A caught pre-state failure that fully restores/revalidates old live/claims may terminate as `failed-restored`; hard-kill, incomplete restore, or orphan claims before state requires reviewed rollback and cannot finalize. Finalize is allowed only after the complete reviewed state postimage exists. Recovery keeps legacy/corrupt evidence and never exposes claims-only as a complete authority.

- [ ] **Step 5: Test every migration/adoption/repair branch**

Generate one fixture per required legacy core field removed/corrupted, plus the Reasonix-only gap, core-valid/parity-failed manual route, invalid-legacy+empty-live adopt, and valid-claims CORRUPT/MISSING-state versus corrupt-claims cases. Cover migrate with required matching old evidence plus separate fresh lock; adopt with MISSING and UNTRUSTED legacy evidence and no old-lock prerequisite; and both repair-adopt state-evidence branches with explicit name, required/forbidden exact path, missing/stale/wrong-name fresh lock, optional-untrusted old lock, and proof that corrupt/absent state cannot supply selection/baseline fields. Test success/failure before receipt, during live mutation, during state create/replace, and during final journal record.

Expected: only the documented gap migrates; bad legacy core fixtures adopt; valid-claims corrupt state uses repair-adopt; corrupt claims remain manual-recovery-required. Failure never overwrites/deletes the only legacy/corrupt evidence.

### Task 5: Implement Controller Takeover

**Artifacts / Locations:**
- Modify: `scripts/authority-harness-env.ps1`
- Modify: `scripts/home-authority-common.ps1`
- Modify: `scripts/live-transaction-common.ps1`
- Modify: `scripts/recover-live-transaction.ps1`
- Review/reuse without shape changes: `schemas/live-journal-header.schema.json`
- Review/reuse without shape changes: `schemas/live-journal-record.schema.json`
- Review/reuse without shape changes: `schemas/rollback-plan.schema.json`
- Modify: `tests/harness-authority.tests.ps1`
- Modify: `tests/live-recovery.tests.ps1`
- Modify: `tests/live-hard-kill.tests.ps1`

- [ ] **Step 1: Define controller identity**

Normalize remote identity without credentials/userinfo and combine it with the Git-common-dir stable private repo ID. Linked worktrees share a controller; a fresh clone does not. Toolchain hash changes are a plan/state precondition, not a controller change.

- [ ] **Step 2: Require valid parity**

Takeover DryRun validates current authority, lock, root claims, live managed hashes, unknown/`.system` markers, and no pending recovery. An unfinished transaction routes to recovery; corrupt claims route manual. A valid foreign controller with parity failure and no journal rejects takeover as `controller-owner-action-required` and never recommends adopt/recovery. Test this dead-end explicitly.

- [ ] **Step 3: Commit controller metadata only**

Apply under Phase 2's canonical→global lock order as `LastOperationKind=controller-transition` through `TransactionMode=state-only`: RESERVED → immutable state preimage/STATE_PREIMAGE_COMPLETE → FILE_PREPARED/FILE_REPLACE_INTENT/FILE_REPLACED → controller postcondition → complete. The state schema requires `ReceiptRef=NO_LIVE_MUTATION`, rejects ReceiptId/ReceiptHash, and preserves selection/lock/task/final managed fields. Do not combine takeover with activation or root changes.

- [ ] **Step 4: Verify state/finalize failure**

Test valid takeover, invalid parity, receipt-bearing controller-transition rejection, `NO_LIVE_MUTATION` on a live transition rejection, state-preimage failure, hard kill before/after state replace and before FILE_REPLACED, plus abandon/rollback/finalize recovery. Reuse Phase 2's already frozen state-only journal and rollback-plan fixtures; Phase 3 adds public producer/behavior assertions without changing either v1 shape.

Expected: old controller remains on pre-commit failure; post-commit crash enters reviewed finalize; no live/backup skill target changes.

### Task 6: Make Environment Activation Consume an External Plan and Exact Receipt

**Artifacts / Locations:**
- Modify: `scripts/activate-harness-env.ps1`
- Modify: `scripts/harness-env-common.ps1`
- Review before emitting plans: `schemas/sync-plan.schema.json`
- Modify: `schemas/artifact-contracts.psd1`
- Modify: `tests/harness-env.tests.ps1`

- [ ] **Step 1: Add external-plan and receipt failures**

Cover Apply without PlanPath, existing DryRun path, shared private-artifact-path rejection, internal plan generation, wrong env/lock/overlay/controller, changed materialization, latest-backup race, receipt mismatch, state write failure, and root transition request.

- [ ] **Step 2: Verify producer contracts before producer code**

Verify Phase 2's already registered environment and task-overlay branches plus schema/semantic negative fixtures; replace sealed fixture inputs only with the public producer's real inputs, without changing v3 shape. Authority branches and the env-build v3 producer/contract were reverified in Task 1; activation must reject every older or mismatched build shape. Do not defer emitter verification to Phase 4.

- [ ] **Step 3: Keep materialization three-platform complete**

Consume the Task 1 env-build v3 output, revalidate all three source roots even when a platform subset is empty, validate the frozen lock schema 3, then bind the exact MaterializationHash/EnvironmentMaterializationRoot used by the plan. This task must not redefine the v3 producer shape.

- [ ] **Step 4: Separate DryRun and Apply invocations**

DryRun performs mandatory build/scan/materialization checks and writes an external `OperationKind=environment` plan. Apply takes the same Name/PlanPath, removes public skip gates, and never creates/deletes/rewrites the plan.

- [ ] **Step 5: Replace authority state inside the live transaction**

Use the exact receipt object returned by the Phase 2 host; delete `Get-LatestBackupReference`. Journal a state recovery copy and PreStatePhaseHash, atomically replace schema 3 state after all three platform postconditions, then write final state hash/complete record.

- [ ] **Step 6: Stop writing repo-local state**

Leave `state/current-env.json` unchanged as legacy evidence. Activation writes only the shared authority state.

- [ ] **Step 7: Integrate retirement with active selection**

With a valid active environment, prove selected lock/task targets fail `retirement-selection-conflict`; only stale managed targets outside the postset may retire. Success uses a receipt-bearing state postimage and advances authority generation/final hashes. Recreate identical retired bytes and prove the completed plan remains stale because state/receipt/journal context changed.

- [ ] **Step 8: Verify activation matrix**

Run fake-home activation for empty/single/multi skill subsets and all three platforms.

Expected: state/lock/receipt/journal refs match; injected failure leaves prior authority/live state or reviewed recovery; no latest-directory scan exists.

### Task 7: Make Task Overlay Changes Three-Platform and Plan-Bound

**Artifacts / Locations:**
- Modify: `scripts/task-skills.ps1`
- Modify: `scripts/agent-dotfiles.ps1`
- Modify: `scripts/transaction-journal-common.ps1`
- Modify: `scripts/live-transaction-common.ps1`
- Modify: `scripts/recover-live-transaction.ps1`
- Review/reuse without shape changes: `schemas/live-journal-header.schema.json`
- Review/reuse without shape changes: `schemas/live-journal-record.schema.json`
- Review/reuse without shape changes: `schemas/rollback-plan.schema.json`
- Modify: `schemas/artifact-contracts.psd1`
- Modify: `tests/task-skills.tests.ps1`
- Modify: `tests/harness-env.tests.ps1`
- Modify: `tests/live-recovery.tests.ps1`
- Modify: `tests/live-hard-kill.tests.ps1`

- [ ] **Step 1: Add Reasonix lifecycle fixtures**

Cover Reasonix ensure → materialization/lock/state baseline → sync → close/removal; missing each platform baseline; legacy schema 2; changed overlay after DryRun; shared private-artifact-path rejection; overlay file write failure; live/state failure after overlay replacement.

- [ ] **Step 2: Remove empty-baseline fallback and automatic Apply**

Require Claude/Codex/Reasonix baselines in lock/state. Delete `-Automatic` Apply routing and public skip gates. A missing/legacy baseline produces migration-required/manual-review-required, never addition-only.

- [ ] **Step 3: Use external task plans**

Ensure/sync/close DryRun writes an external `OperationKind=task-overlay` plan containing current/candidate overlay hashes, materialization/lock, live actions, authority, and whether removals/prunes require manual review. Apply consumes only that plan.

- [ ] **Step 4: Journal the tracked overlay file**

Treat `.agent-harness/task-skills.psd1` as a planned atomic file target with pre/post hash and immutable preimage, using the shared FILE_PREPARED→FILE_REPLACE_INTENT→FILE_REPLACED state machine so the OS primitive captures any raced old bytes in swap-old. Acquire the Git-common-dir canonical lock, then worktree/repo overlay lock, then global live lock; no path may reverse or skip this sequence. Recompute repository/materialization, tracked-file and live/state plan under all locks, journal the file replace with live/state, and detect non-cooperating editor/checkout changes before replace, from captured swap-old, and in postconditions. On failure restore the overlay or enter recovery-required without deleting preimage/swap evidence.

Recovery status may scan global headers read-only, but a transaction header containing an overlay target must identify the exact GitCommonDir and worktree overlay locks. Its reviewed recovery dispatcher releases the scan handle, acquires canonical lock, then overlay lock, then global live lock, re-finds that exact transaction, and revalidates repository/materialization/header/record chain/overlay tuple/all live state before action. Bind both lock identities plus overlay path/file preimage/swap-old/staged hashes into rollback-plan v1; no recovery path may take global then repo/overlay.

- [ ] **Step 5: Verify three-platform safety**

Run task, harness-env, live-recovery, and hard-kill suites, including two repository commands racing, an external file edit/checkout immediately before and after the atomic overlay replace, hard-kill after replace before FILE_REPLACED, zero/bounded live-lock wait, recovery dispatch from another worktree, and lock-order deadlock sentinels.

Expected: Reasonix removal is detected; no task path auto-Applies; overlay/live/state converge together or remain/recover together.

### Task 8: Upgrade the Pinned Runner to Selection-Aware Preview Routing

**Artifacts / Locations:**
- Modify: `scripts/auto-sync-after-git.ps1`
- Modify: `scripts/runner-policy.psd1`
- Modify: `scripts/setup.ps1`
- Modify: `tests/automation-safety.tests.ps1`
- Modify: `tests/harness-authority.tests.ps1`

- [ ] **Step 1: Extend the approved toolchain bundle**

Explicit setup approves/pins the authority/status/materialization/planner dependencies. Hooks never self-approve the new bundle; until approval, toolchain drift produces `runner-review-required`.

- [ ] **Step 2: Route from shared authority**

First run canonical recovery/status. Unfinished canonical transaction emits only recovery diagnostic; missing setup emits only `canonical-setup-required` and an external setup DryRun command, with zero environment build/preview. Only when canonical-ready: valid active authority/controller uses pinned toolchain plus committed data snapshot to materialize that environment and generate a non-consumable environment/task preview plus exact external DryRun command; legacy routes migration diagnostic; valid claims with CORRUPT/MISSING state emits repair-adopt diagnostic only, with no materialization/plan until the user selects a name and exact evidence branch; no authority/pristine roots materializes named `full` through env-build v3 and generates only the non-consumable initial preview plus external DryRun command; no authority/non-empty emits adoption diagnostic requiring an explicit user-selected name at DryRun. Controller mismatch plus valid parity emits takeover diagnostic; controller mismatch plus invalid parity and no journal emits only `controller-owner-action-required`. Live recovery journal emits recovery diagnostic without environment materialization; corrupt claims emit manual-recovery-required. Reject v2/missing/MaterializationHash drift in every branch that consumes a build and never use clone-local state as absence evidence.

- [ ] **Step 3: Keep every trigger preview/event-only**

Add/update/prune/overlay/controller changes create validated non-consumable pending previews/events and manual-review flags; no branch invokes Apply or exposes an internal path as Apply PlanPath. Mark prior previews stale via sidecars after context drift.

- [ ] **Step 4: Verify clones/worktrees**

Trigger hooks from controller clone, second clone, and linked worktree.

Expected: all read the same HomeAuthority selection; only the controller with valid parity generates a matching non-consumable env preview plus external DryRun command; a non-controller gets takeover only when parity is valid, otherwise the exact owner-action stop diagnostic. Setup/recovery/repair-adopt/manual routes obey their diagnostic-only branches, never build an environment preview prematurely, and perform zero live writes.

### Task 9: Run the Phase 3 Checkpoint

**Artifacts / Locations:**
- Record evidence in: this plan
- Keep unchanged: production interlock release state

- [ ] **Step 1: Run focused suites**

```powershell
pwsh -NoProfile -File tests/harness-authority.tests.ps1
pwsh -NoProfile -File tests/harness-env.tests.ps1
pwsh -NoProfile -File tests/task-skills.tests.ps1
pwsh -NoProfile -File tests/automation-safety.tests.ps1
pwsh -NoProfile -File tests/agent-dotfiles.tests.ps1
```

Expected: all migrate/adopt/repair-adopt/takeover/activation/task/retirement/controller cases pass in isolated homes/repos and emit the Phase 2 live-operation-result v1 shape where machine-readable output is requested.

- [ ] **Step 2: Validate emitted artifacts**

Validate env-build 3, lock 3, state 3 oneOf branches, root claims, list/status 2, environment/task/authority/retirement plans, receipts, journals, and the shared live-operation-result v1. Negative fixtures for missing Reasonix, wrong controller/root claims, invalid receipt/sentinel/result branch, unknown fields, corrupt-state route misuse, and legacy/completed-plan reuse fail at their declared layer.

- [ ] **Step 3: Run the full runner and non-suite gates**

Require exactly-once suites and syntax/build/scan/doctor/parity/dangerous-file checks. Run unstaged/staged `git diff --check` with exactly four protected Reasonix literal negative pathspecs, never broad `.reasonix/**`; prove those leaves were never opened and a fifth adjacent file remains visible/scanned.

- [ ] **Step 4: Perform requirements and quality reviews**

Review design compliance first, then artifact DAG, state replacement/recovery, route exclusivity, controller identity, root immutability, overlay transactionality, and selection-aware pinned planning.

- [ ] **Step 5: Keep real authority/live state untouched**

Do not migrate/adopt/repair-adopt/takeover or activate the real machine; do not change the interlock policy.
