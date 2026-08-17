# Live Plan, Backup, Journal, and Recovery Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Status:** Prepared from the approved design; implementation has not started. This phase grants no Git staging/commit/publish or real live Apply/rollback authorization; all public production mutation remains interlocked.

**Goal:** Replace normal sync, explicit retirement, backup, rollback, and crash recovery with one target-bound, globally serialized, receipt-backed live transaction protocol.

**Approach:** Reuse Phase 1 semantic JSON, target identity, SafeTreeWalker, locks, and journal primitives. Build a complete execution context and immutable sync-plan schema 3, create a managed-only backup receipt before mutation, and reconcile every directory rename after failure or hard kill. Preserve the current retirement checks by making them an explicit operation, not a side flag; keep the production protocol interlocked until Phase 4.

**Materials:** Approved design §§4.3–4.4 and 6.4; current `scripts/sync.ps1` retirement implementation; current `scripts/backup.ps1`; current `scripts/rollback-harness-env.ps1`; Phase 0 internal sandbox; Phase 1 safety primitives.

**Validation:** Saved-plan tampering or context drift fails before backup; global lock losers create no backup; receipt/snapshot/journal tampering fails; normal and retirement actions are three-platform symmetric; hard kill at every rename/state boundary yields only reviewed abandon/rollback/finalize; unknown and `.system` contents are never traversed.

---

### Task 1: Define ControlBase, Root Claims, Minimal State 3, and the Global Live Lock

**Artifacts / Locations:**
- Create: `scripts/home-authority-common.ps1`
- Create: `scripts/live-target-context.ps1`
- Create: `scripts/shared-authority-state-common.ps1`
- Modify: `scripts/canonical-transaction-common.ps1`
- Modify: `scripts/recover-canonical-transaction.ps1`
- Modify: `scripts/setup-canonical-transaction.ps1`
- Review: `schemas/canonical-setup-state.schema.json`
- Review/reuse: `schemas/canonical-root-claim.schema.json`
- Create: `schemas/root-claims.schema.json`
- Create: `schemas/current-env-state.schema.json`
- Modify: `schemas/artifact-contracts.psd1`
- Create: `tests/home-authority.tests.ps1`
- Create: `tests/live-concurrency.tests.ps1`
- Modify: `tests/canonical-transaction.tests.ps1`
- Modify: `tests/canonical-recovery.tests.ps1`

- [ ] **Step 1: Write identity/overlap/lock failures**

Cover a fresh OS identity with ControlBase and every Claude/Codex/Reasonix parent/live root MISSING, two-repo simultaneous first bootstrap, hard kill before/after each deterministic ControlBase child creation, partially absent→created live roots, path case/separator variants, default/custom Reasonix roots, actual live overlap with tracked tree/GitCommonDir/ControlBase/BackupRoot/CanonicalRecoveryRoot/materialization/source/staging, pairwise platform overlap, sealed resolver fixtures for two HomeRoots with partial root overlap plus production rejection of every public `-HomeRoot`, an existing canonical-root claim from another repo, simultaneous two-repo canonical-setup versus live-adopt races, second clone, linked worktree, altered `LOCALAPPDATA`/`USERPROFILE`/`APPDATA`, corrupt claims/state, fixed-NTFS versus UNC/mapped/removable/ReFS/FAT/unknown volume capability, state selection/operation oneOf branches, canonical-vs-live/retirement concurrency, public lock busy with zero wait/rejected LockWaitSeconds, sealed-host-only bounded wait, and owner hard kill.

- [ ] **Step 2: Resolve ControlBase and HomeAuthorityKey**

Resolve Windows ControlBase and fixed sibling BackupRoot from access-token SID plus `FOLDERID_LocalAppData`, and HomeRoot/AppData from OS Known Folder APIs, never from mutable process environment variables. Before either private root exists, derive the fixed no-follow bootstrap-lock file under the already-existing Known Folder root from SID/location/domain only. The reviewed canonical setup plan binds `PrivateRootBootstrapIntent` (parent identity, fixed control/backups remainders, each MISSING|COMPLETE, final current-user DACL template, expected fixed children); Apply acquires that pre-ControlBase exclusive handle, revalidates intent, creates the private parent, BackupRoot, ControlBase plus `homes/canonical-roots/live-transactions` only with the final security descriptor, validates the deterministic prefix, and only then obtains the normal global lock. Exact crash prefixes may be completed by the same setup plan; wrong ACL/identity/extra/reparse is manual. No live/receipt/journal work precedes global lock. Read-only status never creates the bootstrap lock/file or directories. Existing ControlBase/BackupRoot bind resolved identity, owner ACL/SID, resolver version and FilesystemCapabilityHash; production on an undefined non-Windows adapter remains interlocked. Protocol v1 production dispatch rejects public `-HomeRoot`/`-BackupRoot`; sealed fake-home injection remains an internal capability only. Derive `HomeAuthorityKey` from token SID plus canonical Known-Folder HomeRoot location key only; do not include root existence/file IDs or Reasonix override.

- [ ] **Step 3: Build the registry view**

While holding the global live-mutation lock, enumerate every immutable `canonical-roots/<repo-id>.json`, every `homes/*/root-claims.json`, then every complete `current-env.json` and unfinished reservation from the single `live-transactions/<TransactionId>/` root plus canonical transaction namespaces. TransactionId is a normalized UUID generated after required locks; its directory is create-new, and immediate-child cardinality/type/allowed-entry validation is shared by locator, manifest and wrong-clone recovery. Never store a first-authority journal under an absent home directory or discover one by scanning BackupRoot. Consume Phase 1's deterministic RepoId/setup-state v1 without changing its schema. Canonical setup precomputes stable `SetupIntentHash` plus an `ExpectedSetupStateProjectionHash` that excludes Apply-derived final identities, publishes the exact schema-valid immutable canonical-root claim, journals current-user-only root creation, then captures actual identity/owner/DACL into a final setup state that binds `RootClaimHash` and the projection hash; the full state hash enters only the journal/result/COMPLETE. Kill after claim but before state yields only `setup-finalize-required`: the original canonical-setup Apply is rejected as recovery-required; a new external `canonical-recover-finalize` plan binds the exact claim/header/root tuple, revalidates intent/projection and actual final contexts, create-new publishes only the unique matching final state, then closes with its own ClosingDocumentHash. No new root/location/id/time/nonce is chosen. Zero claim/state primitive may only reviewed-abandon; valid claim+state with terminal missing may only finalize the record. State-without-claim, intent/projection/hash mismatch, corrupt object, unfinished journal ambiguity, RepoId collision with different identity, or any location/owner/DACL/identity change blocks/manual-recovers with `canonical-root-transition-not-supported`. V1 has no replace/relocate plan. Construct one ordered registry and reject ancestor/descendant or identical file-identity overlap across canonical roots, authorities and reservations. Apply the design's complete forbidden-root matrix against repository, Git-private, source/materialization, backup/control, canonical recovery, and live staging roots before accepting any default/custom claim. Invalid claims block both canonical and live mutation as `manual-recovery-required`; invalid state with valid home claims keeps its roots reserved and permits only Phase 3 `repair-adopt`.

- [ ] **Step 4: Define the minimal shared-state and generic state-target contract**

Schema 3 requires `SelectionKind=environment`, one named environment lock/task baseline for all three platforms, and a `LastOperationKind` branch; no full-repo/MISSING selection exists. Receipt-bearing operations require ReceiptId/ReceiptHash; controller-transition requires `ReceiptRef=NO_LIVE_MUTATION` while preserving the prior selection. State references immutable RootClaimsHash and never stores its own hash. Define TargetContextIntent versus Apply-derived FinalResolvedIdentities/FinalTargetContextHash, including ABSENT→created fixtures, then implement validated read plus journaled create-new of proposed claims and atomic create/replace/recovery-copy of a caller-supplied state postimage; claims are created only for first authority, never replaced. Phase 3 owns migrate/adopt/repair-adopt/takeover/activation semantics.

- [ ] **Step 5: Implement deterministic lock semantics**

Retrofit every production canonical/live/authority/task/retirement/rollback/recovery route to acquire locks only in `GitCommonDir canonical → optional worktree overlay → pre-ControlBase bootstrap when needed → ControlBase global live` order. Enable only the Phase 1 reviewed `CanonicalOperationKind=setup` Apply to bootstrap MISSING ControlBase: under canonical→bootstrap it creates/validates the deterministic control prefix, then acquires global, revalidates its saved setup plan, and journals exact global-claim→canonical-setup-state targets before any initial live plan is legal. Fresh OS order is setup DryRun/review/Apply, then initial DryRun/review/Apply; live initial cannot bootstrap around a missing canonical claim. Canonical setup/other Apply/recovery validates canonical-setup-state plus its global canonical-root claim against every canonical/home/reservation claim while holding canonical+global; live routes hold canonical from repository/materialization revalidation through terminal journal completion, preventing canonical source/generated/manifests from changing mid-Apply. Public protocol v1 is always zero-wait and rejects `-LockWaitSeconds`; only the sealed isolated host accepts 1–300 seconds for bounded-wait fixtures. After all required locks are held, scan reservations/terminal records and recompute repository, unified registry, current plan, overlay (if any), and target identities before any backup/workspace. Reject a missing/tampered canonical claim, consumed DocumentHash, reverse-order acquisition, or drift. Lock metadata is diagnostic only and cannot be deleted to steal a lock.

- [ ] **Step 6: Verify identity, state shape, and locking**

Run both new suites.

Expected: absent→created preserves authority namespace; partial overlap is rejected globally; canonical claim→setup-state kill-between uniquely finalizes or stops, and relocation/state-without-claim is rejected; state oneOf/RootClaimsHash fixtures validate at the intended schema/semantic layer; canonical and live/retirement transactions cannot interleave, and a loser creates no backup/workspace. This task proves only OS-handle release after owner death; durable post-kill reservation classification is implemented and tested in Tasks 4, 6, and 8.

### Task 2: Replace Sync Plan Schema 2 with the Semantic Plan Contract

**Artifacts / Locations:**
- Modify: `scripts/sync.ps1`
- Modify: `schemas/sync-plan.schema.json`
- Modify: `scripts/harness-env-common.ps1`
- Modify: `scripts/build-harness-env.ps1`
- Modify: `schemas/harness-env-build.schema.json`
- Modify: `schemas/harness-env-lock.schema.json`
- Create: `tests/live-plan.tests.ps1`
- Create: `tests/helpers/sealed-live-plan-fixture.ps1`
- Modify: `tests/sync.tests.ps1`
- Modify: `tests/harness-env.tests.ps1`
- Modify: `schemas/artifact-contracts.psd1`

- [ ] **Step 1: Write document/context failure cases**

Cover create-new PlanPath collision; worktree/arbitrary-Git/reparse-alias PlanPath rejection through the shared private-artifact-path table; role confusion among ExternalUserArtifact, exact InternalContractPath and EvidenceInputPath; RetireManifest/LegacyState/CorruptState/Receipt path wrong-locator, hardlink, ADS and protected/outside aliases; tampered actions, paths, Metadata, GeneratedAtUtc, PlanHash, and DocumentHash; same action names/types but changed source/live/manifest hash; public `-HomeRoot`/`-BackupRoot` rejection; wrong operation/selection kind; changed toolchain/authority/root registry/environment lock/task overlay; unknown and `.system` marker drift; selected retirement target; and consumed-DocumentHash replay after committed/no-op/abandoned/rolled-back/failed-restored outcomes or an otherwise byte-identical retirement reconstruction.

- [ ] **Step 2: Define sync-plan schema 3**

Use top-level `SchemaVersion=3`, `Metadata`, `PlanPayload`, `PlanHash`, and `DocumentHash`; `DocumentHash` is the retained-journal consumption key. Payload includes repository/toolchain/controller/authority/root-claim context, ControlBaseIntent/existing identity and FilesystemCapabilityHash when probed, actual three-platform source/live roots and pre-identities, per-platform manifest/source/live hashes, unknown entry markers, `.system` marker, ordered actions, `TargetContextIntent`, and an `AuthorityStateIntent` containing every semantic field knowable before Apply. It must not fabricate receipt/journal IDs, Apply-derived ControlBase/FinalResolvedIdentities/FinalTargetContextHash, or a final state hash. Phase 2 freezes the final schema-v3 OperationKind branches `initial|environment|task-overlay|migrate|adopt|repair-adopt|controller-transition|retirement`; only initial/retirement get public producers here. Sealed fixture producers create registered environment/controller-transition documents for generic state-only/recovery/rollback DAG tests; Phase 3 consumes the frozen branches and adds public semantics without modifying v3 shape. Initial always selects materialized named `full`. Full-repo and environment-rollback never use sync-plan; no `live-recover-*` PlanKind is an OperationKind or sync-plan branch. Task 6 owns rollback/recover schema 1: environment-rollback starts a new transaction of the same OperationKind, while recovery PlanKinds close an existing transaction and bind its original OperationKind.

- [ ] **Step 3: Establish env-build v3 before the initial consumer**

Freeze env-lock schema 3 and make `build-harness-env.ps1` emit env-build v3 now. Always create Claude/Codex/Reasonix materialized source roots, including empty platform subsets; bind normalized root evidence, per-platform source/manifest/task baselines, RepositoryCommit, definition/lock inputs, and `MaterializationHash`. Register emitter-derived positives plus missing-platform/empty-root/hash/version negatives. Initial planning materializes named `full`, accepts only this exact v3 artifact/lock, binds its external EnvironmentMaterializationRoot, and rejects v2/missing/drifted evidence before backup. No Phase 2 checkpoint may ship a temporary v2 initial branch for Phase 3 to reinterpret later.

- [ ] **Step 4: Define operation-specific evidence**

Freeze required/forbidden evidence for every final branch now. `environment` binds current valid authority plus named materialization/lock/task overlay and target state; `task-overlay` additionally binds current/candidate tracked overlay bytes/hash, action and removal-review flag; `migrate` binds the unique current-repo legacy locator/hash/core/old-lock evidence plus fresh named materialization; `adopt` uses MISSING|UNTRUSTED legacy evidence, actual live and explicit fresh name. `repair-adopt` has a strict `StateEvidence=CORRUPT|MISSING` oneOf: CORRUPT requires the exact current HomeAuthority state internal locator/raw bytes hash/preimage, while MISSING requires a marker and forbids path/hash; both require immutable claims, actual live and fresh explicit name. `controller-transition` binds valid current parity/controller and `NO_LIVE_MUTATION`. For `retirement`, require the `ExternalUserArtifact` manifest resolved path/hash, safe names, canonical/generated/current-manifest absence evidence, target tree hashes, valid schema 3 named-environment authority/lock/task postset, and `Authority=explicit-retirement`. Every target must be a stale managed entry outside that postset; otherwise fail `retirement-selection-conflict`. Bind each reviewed AuthorityStateIntent with its permitted final semantic fields; Apply later adds actual receipt/journal/final identity refs. Branch fields are mutually forbidden elsewhere; hooks never supply retirement input. Register emitter-independent positives/negatives and a sealed helper that can instantiate valid environment/controller-transition plans only beneath the isolated test capability—never in production or as public migration evidence.

- [ ] **Step 5: Implement immutable write and five-step Apply validation**

DryRun writes create-new and validates its schema. Apply under the lock recomputes DocumentHash, saved PlanHash, current semantic plan/PlanHash, and selection context before any backup. PlanPath is never overwritten, refreshed, or deleted by Apply.

- [ ] **Step 6: Preserve and extend current retirement regressions**

Retain strict JSON/name/`.system`/canonical authority/path drift tests from current `sync.tests.ps1`; update them to assert `OperationKind=retirement`, semantic hashes, shared authority/selection StateIntent and runtime postimage projection, zero hook usage, selected-target conflict, and old-plan replay rejection even after the same target bytes are recreated.

- [ ] **Step 7: Verify plan behavior**

Run `tests/live-plan.tests.ps1`, env-build v3 cases in `tests/harness-env.tests.ps1`, and the plan/initial-v3 sections of `tests/sync.tests.ps1`.

Expected: only an unchanged reviewed document/context reaches the backup step.

### Task 3: Create Unique Managed and Authority-Preimage Backup Receipts

**Artifacts / Locations:**
- Create: `scripts/backup-receipt-common.ps1`
- Modify: `scripts/backup.ps1`
- Create: `schemas/backup-receipt.schema.json`
- Create: `tests/backup-receipt.tests.ps1`
- Modify: `schemas/artifact-contracts.psd1`

- [ ] **Step 1: Write receipt failure tests**

Cover two simultaneous/same-millisecond backups, existing destination collision, source drift during copy, missing skill, partial receipt, absent COMPLETE marker, receipt tamper, missing/wrong `SchemaVersion=1`, missing/wrong SourceOperationKind, PlanHash/DocumentHash drift, managed snapshot tamper, missing/tampered authority-state or root-claims preimage, target identity drift, custom Reasonix root, reparse/hardlink injection, `.system` sentinel, and unknown sentinel. Hard-kill after exact receipt directory creation, during snapshot/meta publication, after receipt/COMPLETE flush, and before `RECEIPT_COMPLETE`; restart must find only the header-declared receipt slot and classify it MISSING/PARTIAL/COMPLETE without scanning arbitrary BackupRoot children.

- [ ] **Step 2: Pass resolved targets into backup**

Before publishing RESERVED, the transaction host generates the TransactionId and a unique ReceiptId/exact receipt path (deterministically derived from or explicitly bound to that TransactionId), validates the absent create-new slot, and places this `ReceiptIntent` in the receipt-backed header. The internal receipt function receives exact SourceOperationKind, reviewed PlanHash/DocumentHash, execution-context/ControlBase/FilesystemCapability hashes, already resolved three-platform targets, and that existing flushed reservation/ReceiptIntent. It never re-derives paths from HomeRoot, invents a second receipt id, or accepts an absent/mismatched intent. Retire public standalone `backup.ps1` to a zero-write, non-zero `backup-is-transaction-internal` diagnostic; managed backup preview is already part of the source reviewed plan, and only the transaction host creates a mutation-bound receipt.

- [ ] **Step 3: Create a unique directory**

Resolve BackupRoot only from `FOLDERID_LocalAppData/ai-agent-dotfiles/backups`, validate current-user ACL/identity/filesystem, and reject public `-BackupRoot`; sealed tests may inject a capability-scoped fake path. Use the unique predeclared ReceiptId/path with create-new semantics; human-readable high-resolution UTC may be display metadata but cannot select another slot. Validate BackupRoot identity/non-overlap with working tree, materialization, live, control, and mutation/recovery roots. Never use `-Force` to reuse a snapshot directory.

- [ ] **Step 4: Copy only planned pre-change managed targets**

Use SafeTreeWalker into `snapshot/claude|codex|reasonix/<skill>`. Record MISSING without a fake directory. Record unknown and `.system` root-entry markers only; do not recurse into or copy them. Separately copy the pre-Apply shared authority state and immutable root-claims files, or record MISSING, beneath `authority-preimage/`; bind their exact hashes without mixing them into managed snapshot hashes.

- [ ] **Step 5: Finalize the receipt**

Re-hash live sources, managed snapshots, and authority preimages; build the semantic `SchemaVersion=1` receipt including SourceTransactionId, ReceiptIntent id/path, SourceOperationKind and both original plan hashes; calculate ReceiptHash excluding only itself; create/flush/rename `_meta/receipt.json`; then create/flush COMPLETE. `_meta`, logs, journal, and marker are excluded from managed snapshot hashes, while authority preimage hashes remain explicit receipt fields. The host then appends/flushed `RECEIPT_COMPLETE` with the same ReceiptId/ReceiptHash to the already durable transaction; it never creates the first transaction record after backup.

- [ ] **Step 6: Return a structured object**

The transaction host receives SchemaVersion, ReceiptId, path, ReceiptHash, SourceTransactionId, SourceOperationKind, original PlanHash/DocumentHash, managed snapshot hashes, authority state/root-claims preimage status+hashes, and actual target identities directly—not by scanning BackupRoot or parsing `BACKUP_DIR=` text.

- [ ] **Step 7: Verify receipt behavior**

Run `tests/backup-receipt.tests.ps1`.

Expected: valid three-platform receipts with matching reservation ReceiptIntent and state/claims preimages pass; restart classifies only that exact slot at every injected crash window; missing/mismatched reservation/intent, orphan or second receipt directory, authority preimage, collision, tamper, link, and race cases fail; unknown/`.system` contents retain their original access timestamps/bytes where the platform permits that assertion.

### Task 4: Implement the Live Mutation State Machine

**Artifacts / Locations:**
- Create: `scripts/live-transaction-common.ps1`
- Modify: `scripts/transaction-journal-common.ps1`
- Create: `schemas/live-journal-header.schema.json`
- Create: `schemas/live-journal-record.schema.json`
- Create: `schemas/live-operation-result.schema.json`
- Create/modify: live-operation-result positive and negative artifact fixtures
- Create: `tests/live-recovery.tests.ps1`
- Modify: `schemas/artifact-contracts.psd1`

- [ ] **Step 1: Define live target records**

For every add/update/prune/retirement action, bind platform/name, live identity, OLD/MISSING hash, NEW/MISSING hash, same-volume staged path, mutation-time swap-old path, and immutable receipt snapshot reference. Add every MISSING parent-directory component as an ordered explicit target with deepest-existing-parent identity, expected MISSING state and Apply-derived final identity. Keep unknown and `.system` out of recursive target lists; reparse markers block mutation without target resolution.

- [ ] **Step 2: Prepare same-volume staging**

Validate each LiveMutationStagingRoot is a working-tree-external sibling/control location on the live target volume and non-overlapping with source/live/backup/control/canonical recovery. Copy NEW bytes with SafeTreeWalker; require swap-old MISSING and the immutable receipt preimage complete before PREPARED.

- [ ] **Step 3: Execute the fixed record sequence**

Create/flush the global `RESERVED` header with original operation DocumentHash, immutable `OriginRepoId`/resolved GitCommonDir identity/canonical-lock key, complete root-claim reservation and `TransactionMode=receipt-backed|state-only`; receipt-backed headers also contain the prevalidated exact ReceiptIntent, while state-only headers contain `ReceiptRef=NO_LIVE_MUTATION`. For receipt-backed operations, create only that receipt slot and after a complete receipt flush `RECEIPT_COMPLETE`; then create MISSING parent components parent-first through DIR_CREATE_INTENT→single no-overwrite mkdir→DIR_CREATED, followed by PREPARED, MOVE_OLD_INTENT, target→swap-old, OLD_MOVED, MOVE_NEW_INTENT, staged→target and NEW_INSTALLED. Rollback removes created parents child-first only when captured identity is unchanged and empty; nonempty/raced parents are manual recovery and never recursively deleted. For the controller-only state-only seam, skip backup/receipt, create/validate an immutable state preimage and flush `STATE_PREIMAGE_COMPLETE`, then use the file-target records for state. For MISSING old/new states record explicit no-op semantics. The transaction namespace allows only header, numbered records, zero-or-one fixed `result.json`, and known `_pending` temps. Before any reviewed recovery primitive/result/terminal, publish a numbered `RECOVERY_ACTION_INTENT` binding recovery PlanKind/DocumentHash, prior head and expected terminal semantic projection; that attempt remains consumed after hard-kill. Publish deterministic result bytes (bound to original DocumentHash and actual ResultBaseHeadHash, not a recovery-plan hash) first, then the only reservation-closing artifact—the final `Phase=COMPLETE` record with matching ResultHash and `Outcome=committed|abandoned|rolled-back|failed-restored`. Its closing oneOf is exact: original command closure uses `ClosingKind=original`, repeats header DocumentHash and forbids ClosingPlanKind; reviewed recovery uses `ClosingKind=recovery` plus its recovery PlanKind/DocumentHash. Backup receipt COMPLETE remains separately scoped.

- [ ] **Step 4: Recheck before every destructive primitive**

Immediately before a prune/retirement move, verify target identity and hash still equal the reviewed plan and receipt evidence. Treat drift as plan stale and restore any earlier completed targets.

- [ ] **Step 5: Journal the generic authority state target**

Every receipt-backed operation uses the trusted serializer to combine reviewed AuthorityStateIntent/TargetContextIntent with Apply-derived final identities plus ReceiptId/ReceiptHash and JournalId/PreStatePhaseHash, validates the complete state postimage, and proves its projection/derivation. For first authority, journal/create proposed immutable claims from RESERVED, then journal state file records and create state referencing RootClaimsHash; existing authority proves claims unchanged. The generic controller state-only branch instead requires existing valid state/claims, a complete immutable state preimage, `ReceiptRef=NO_LIVE_MUTATION`, and a state-only journal oneOf; it may change only controller/toolchain/generation fields. A kill after claims or state replace uses reviewed rollback/finalize as defined; finalize is possible only after the complete state postimage exists and all postconditions revalidate. Transition semantics remain Phase 3, but both transaction modes and their recovery are testable here.

- [ ] **Step 6: Verify postconditions and failure classification**

After all targets/state install, compare managed live trees, marker inventories, and state posthash to the plan. Before the shared-state commit boundary, caught failure restores completed live/claims targets in reverse under the lock; verified full restoration publishes `Phase=COMPLETE, Outcome=failed-restored` and exits non-zero `apply-failed-but-restored`. Once the reviewed state postimage is atomically installed, later result/final-record failure must not rewrite state/live; it retains evidence for reviewed finalize. Incomplete/ambiguous restoration retains receipt preimage, swap-old, staging, state recovery material, and journal and exits `recovery-required`.

Before any producer claims a machine-readable result, register and self-validate `live-operation-result.schema.json` v1 with strict `ResultScope=command|transaction`. Command scope exact `CommandKind` is `initial|environment|task-overlay|retirement|migrate|adopt|repair-adopt|controller-transition|environment-rollback|live-recover-status|live-recover-abandon|live-recover-rollback|live-recover-finalize`; it allows only no-transaction, unfinished, or terminal-reference lifecycle branches and never appears in the transaction namespace. Original command kinds map one-to-one to OperationKind; recovery action requires matching PlanKind and, once located, header OriginalOperationKind. Transaction scope allows only fixed terminal-intent, requires original OperationKind from `initial|environment|task-overlay|migrate|adopt|repair-adopt|controller-transition|retirement|environment-rollback`, and forbids CommandKind/PlanKind. Committed requires complete state and complete receipt for receipt-backed mode; abandoned permits MISSING/PARTIAL/COMPLETE receipt/state but hashes only COMPLETE objects; rolled-back/failed-restored require exact restoration proof/final old hashes plus only refs that actually exist. State-only always forbids receipt refs. The fixed result binds original OperationKind/DocumentHash/ResultBaseHeadHash and remains provisional until a final record references ResultHash through the strict `ClosingKind=original|recovery` oneOf; ResultBaseHeadHash may be an ancestor when a later recovery finalize intent precedes COMPLETE, but every intervening record must be schema-authorized. Only recovery closure permits/requires ClosingPlanKind and a different ClosingDocumentHash. Publish recovery intent before action, result first and terminal record last, with hard-kill failpoints on every boundary. Add scope/field-crossing negatives, original environment/task crash before and after result publication, original/recovery closing-field mismatch, early-abandon positives, fabricated partial-hash negatives, result-MISSING acyclic projection construction, prior-attempt replay, and existing-result/new-recovery-close cases. Phase 3 reuses this exact contract for authority/env/task producers rather than inventing per-script JSON.

- [ ] **Step 7: Test every phase**

Inject normal exceptions before/after reservation, receipt completion or state-only preimage completion, each parent mkdir/directory/file record primitive, and state create/replace. On a fresh HOME, hard-kill before/after every DIR_CREATE_INTENT/mkdir/DIR_CREATED and race an external writer into a created parent; verify exact empty same-identity cleanup versus manual preservation. Hard-kill state-only takeover before/after FILE_REPLACE_INTENT and after replace before FILE_REPLACED; verify abandon/rollback/finalize and rejection of receipt fields.

Expected: no later platform runs after failure; cleanup occurs only after complete success; the final old copy is never deleted on recovery failure.

### Task 5: Migrate Normal Sync and Retirement to the Common Host

**Artifacts / Locations:**
- Modify: `scripts/sync.ps1`
- Modify: `scripts/internal/live-transaction-host.ps1`
- Modify: `tests/sync.tests.ps1`
- Modify: `tests/automation-safety.tests.ps1`

- [ ] **Step 1: Remove legacy per-skill swap/journal paths**

Delete `Sync-OneSkillDir-Transactional`, overwrite-style `sync-journal.json`, whole-root backup parsing, and cleanup-in-finally behavior after equivalent common-host coverage exists.

- [ ] **Step 2: Enforce authority/selection guards**

No authority plus pristine roots accepts only reviewed `initial` selecting named `full`; any existing authority rejects public direct sync Apply and requires `env activate <name>`; legacy/missing authority plus non-empty roots accepts only later migrate/adopt operations; controller mismatch requires takeover; root-location change after authority is `root-transition-not-supported`. Retirement requires valid schema 3 authority, rejects every target present in the active lock/task postset, and must carry a receipt-bearing state postimage; it cannot be used to repair legacy/corrupt/missing authority.

- [ ] **Step 3: Route both operation types identically**

Normal sync and retirement use the same global reservation/lock, current-plan recomputation, receipt, journal, target/state machine, postconditions, and recovery scan. Retirement adds its manifest/canonical-absence authorization, selection-conflict check, prune action type, and authority-generation postimage. Reconstructing identical live bytes does not make an already completed retirement plan reusable because current state/receipt/journal context has advanced.

- [ ] **Step 4: Check build and scan results**

Use Phase 1 isolated preflight/result adapters. Public `sync.ps1 -Apply` no longer accepts `-SkipBuild` or `-SkipSecretScan`; internal sandbox tests inject approved fake dependencies through the in-process host.

- [ ] **Step 5: Verify three-platform parity**

Cover add/update/no-op/prune/unknown and explicit retirement for Claude, Codex, and Reasonix; test Codex fallback and custom Reasonix roots; assert `.system` marker/unknown entries are preserved without content traversal.

- [ ] **Step 6: Keep production interlocked**

Production Apply still exits at Phase 0 policy. Exercise the new host only through the internal sandbox until Phase 4 release.

### Task 6: Add Crash Recovery Status and Reviewed Transitions

**Artifacts / Locations:**
- Create: `scripts/recover-live-transaction.ps1`
- Create: `schemas/rollback-plan.schema.json`
- Modify: `schemas/artifact-contracts.psd1`
- Create/modify: rollback/recovery positive and negative artifact fixtures
- Modify: `scripts/agent-dotfiles.ps1`
- Modify: `tests/live-recovery.tests.ps1`
- Create: `tests/live-hard-kill.tests.ps1`

- [ ] **Step 1: Add read-only recovery status**

Perform a strictly read-only locator scan of every unfinished reservation/journal under ControlBase without retaining any mutation lock. Validate enough header bytes to identify TransactionId and its OriginRepoId/GitCommonDir/canonical-lock key; report exactly one of clean, abandon-eligible, rollback-required, finalize-eligible, or manual-recovery-required. Missing/ambiguous/unresolvable origin is manual. Status never renames/deletes and releases all scan handles before any dispatcher lock acquisition.

- [ ] **Step 2: Define official rollback/recovery plan schema 1**

This is a new formal contract, so use `SchemaVersion=1`; `ContractId` and `PlanKind` reject current ad-hoc legacy JSON without pretending the new artifact is v2. The only PlanKinds are `environment-rollback`, `live-recover-abandon`, `live-recover-rollback`, and `live-recover-finalize`; sync-plan schema 3 must reject all four. `PlanKind=environment-rollback` starts a new transaction whose header/context/result `OperationKind=environment-rollback`; if that original command closes normally, its COMPLETE record uses `ClosingKind=original` and forbids ClosingPlanKind. Every `live-recover-*` plan instead carries `OriginalOperationKind`, which must exactly equal the existing header/context and, if present, fixed result; its own action becomes the required `ClosingPlanKind` only in a `ClosingKind=recovery` COMPLETE record. The fixed result always preserves OriginalOperationKind, while that terminal record binds the recovery plan's ClosingDocumentHash. Treat substitution of `live-recover` into OperationKind, an original-kind mismatch, forbidden/required ClosingPlanKind mismatch, or a PlanKind/action mismatch as semantic negatives. Bind reservation/journal ID, OriginRepoId/resolved GitCommonDir/canonical-lock identity, optional overlay-lock identity, original DocumentHash consumption key, every prior recovery-intent consumption key, DerivedJournalHeadHash/chain hash/pending-temp/result inventory, target/staged/swap-old/immutable-preimage identities and hashes, root claims, authority/state recovery hashes, planned recovery actions, and an expected terminal semantic projection through semantic PlanHash/DocumentHash. The projection excludes ResultHash, ResultBaseHeadHash and the current recovery plan hash. `TransactionMode` plus PlanKind/ReceiptState forms a strict oneOf: complete receipt-backed rollback/finalize requires ReceiptId/ReceiptHash/SourceOperationKind/original PlanHash+DocumentHash; early `live-recover-abandon` permits declared ReceiptState=MISSING|PARTIAL|COMPLETE, requires ReceiptId/path intent when declared by the header, and permits ReceiptHash/source refs only for COMPLETE while forbidding fabricated hashes for MISSING/PARTIAL. State-only controller recovery requires `ReceiptRef=NO_LIVE_MUTATION` plus immutable state-preimage and state file tuple hashes and forbids every receipt field. `environment-rollback` is always complete receipt-backed; state-only is legal only for live-recover PlanKinds. Every recovery plan DocumentHash becomes consumed when its mandatory `RECOVERY_ACTION_INTENT` is published; the eventual terminal record additionally identifies the plan that closes the transaction.

- [ ] **Step 3: Implement the fixed public dispatcher and transitions**

Route `agent-dotfiles.ps1 live recover status` to the locator scan above. For `live recover <abandon|rollback|finalize> -TransactionId <id> -DryRun|-Apply -PlanPath`, resolve the origin, release scan handles, acquire the **origin** canonical lock, then optional origin overlay lock, then global live lock; re-find the exact transaction and revalidate origin identity/header/chain/repository/registry before planning or Apply. A wrong clone may dispatch recovery but may not substitute its own repo lock. Reject missing/unknown/duplicate/unresolvable origin or id, consumed recovery DocumentHash, action/PlanKind mismatch, internal plan generation, every legacy rollback JSON, and every PlanPath rejected by the shared private-artifact-path table. Give a schema-valid matching `result.json` with no terminal record the highest route priority regardless of Outcome: it is only `finalize-eligible`, must revalidate the tuple/refs appropriate to that existing Outcome, and after publishing the new finalize intent may publish only the matching `ClosingKind=recovery` COMPLETE record—never repeat an abandon/rollback/live/state primitive. Only when result is MISSING may receipt-backed classification choose abandon for RESERVED/partial-receipt/RECEIPT_COMPLETE/PREPARED with zero target/state/claims primitive, rollback after a target/claims/state primitive before a complete state postimage, or committed-finalize when the complete state postimage and all postconditions/claims/receipt/journal agree. For state-only controller transition with result MISSING, use a disjoint priority: complete preimage plus zero state primitive → abandon; reviewed state postimage plus valid target/swap-old/preimage tuple and state/claims/controller/plan revalidation → committed-finalize, even if `FILE_REPLACED` was not published; primitive occurred but postimage is invalid and reviewed old bytes are uniquely recoverable → rollback; otherwise manual-recovery-required. Each reviewed action first publishes its mandatory `RECOVERY_ACTION_INTENT`. If `result.json` is MISSING, the plan binds an expected semantic projection that excludes ResultHash/ResultBaseHeadHash/current plan hash; after the action, the host computes fixed bytes from original evidence plus the actual journal head and requires the projection to match before create-new publication. If result is present it must match byte/hash/Outcome and be reused. The host then publishes the sole terminal `Phase=COMPLETE` record with ResultHash, original/closing DocumentHashes, required ClosingPlanKind and the existing or action-selected Outcome. Thus finalize preserves an existing `failed-restored|abandoned|rolled-back|committed` Outcome instead of rewriting it; header, every attempt intent and terminal together consume original/action/closing plans while retaining audit bytes. Add intent→primitive/result/terminal hard-kill and replay fixtures, result-publish→new-finalize for all four Outcomes, plus original/recovery ClosingKind mismatches. Ambiguous tuple/result/pending temp never resumes forward mutation.

- [ ] **Step 4: Add deterministic failpoints**

Use the Phase 0 `tests/helpers/failpoint-controller.ps1` and process-tree helper to receive checkpoints after RESERVED, during/after receipt finalization, before/after each journal-record temp flush and publish rename, after each target rename/replace succeeds but before result-record publish, before/after authority state replacement, and before the final transaction `Phase=COMPLETE` record. Kill the child process forcefully at the signaled checkpoint; known `_pending` temps are never treated as published records or silently deleted.

- [ ] **Step 5: Verify restart behavior**

Start a new process after every hard kill; assert the global unfinished-transaction scan blocks normal mutation—including a different HomeAuthority with overlapping custom roots—and only the correct reviewed recovery transition succeeds. Dispatch from the origin clone, a wrong clone and a linked worktree; prove all use the header-bound origin canonical/optional-overlay/global lock order, caller-repo substitution fails, missing/tampered origin is manual, and concurrent canonical mutation cannot interleave. Verify all last copies/reservations/journal records remain after an injected recovery failure.

### Task 7: Rebuild Environment Rollback on Receipts

**Artifacts / Locations:**
- Modify: `scripts/rollback-harness-env.ps1`
- Modify: `scripts/agent-dotfiles.ps1`
- Modify: `tests/harness-env.tests.ps1`
- Modify: `tests/agent-dotfiles.tests.ps1`
- Create: `tests/backup-recovery.tests.ps1`

- [ ] **Step 1: Write current rollback failures**

Cover modified backup skill bytes with unchanged manifest, missing/tampered prior authority state or claims preimage, wrong SourceOperationKind including initial/task/retirement, missing/wrong ReceiptPath, legacy RunId/BackupPath switches, PlanKind mismatch, every shared private-artifact-path PlanPath rejection, custom Reasonix target, another HomeRoot, incomplete receipt, changed current live/state/claims, recovery-move failure, state restore failure, and two backups created concurrently. Use Task 2's sealed registered `OperationKind=environment` plan fixture plus the internal host to create the committed source transaction/receipt graph required by these tests; do not handwrite an orphan receipt/header or claim a Phase 3 public activation producer already exists. Add complete environment receipts whose linked SourceTransactionId is missing/unfinished/tampered or terminal `Outcome=abandoned|failed-restored|rolled-back`; all must be rejected despite a valid receipt marker/hash. Also test committed environment→successful sealed task-overlay/authority generation→old receipt rollback, tracked overlay drift, and an environment transaction whose preimage overlay baseline differs from its terminal poststate; all reject before pre-rollback receipt.

- [ ] **Step 2: Generate rollback plans from a complete receipt**

Route only `agent-dotfiles.ps1 env rollback -ReceiptPath <path> -DryRun|-Apply -PlanPath`; remove/reject legacy RunId/BackupPath selection. Acquire canonical→worktree overlay→global locks. Require a complete activation receipt with `SourceOperationKind=environment`, then use SourceTransactionId to validate the retained header/result/terminal COMPLETE chain has `Outcome=committed`, matching original/closing plan refs and exact ReceiptIntent/ReceiptId/ReceiptHash. Require current authority state bytes/hash/generation to equal that terminal poststate exactly, and require activation preimage, terminal poststate, and current tracked overlay hash/three-platform baselines all equal; any later task/authority/retirement generation or activation-time stale-overlay repair makes the old receipt ineligible. Bind that provenance plus overlay hash, every backup skill tree hash, its existing old authority-state/root-claims bytes and hashes, current live/state/claims hashes, actual path identity, active selection/authority identity, original plan/document hash, receipt hash, and restore/add/remove/no-op action. Derive a reviewed `PlanKind=environment-rollback` and RollbackStateIntent that restores the prior selection/controller/final-managed semantics but receives this rollback's new receipt/journal refs at Apply. Reject MISSING authority preimage, unfinished/noncommitted/missing/tampered source transaction, every other producer kind, and PlanKind/invocation mismatch; never trust legacy `BackupReference` or choose a backup by timestamp.

- [ ] **Step 3: Create a pre-rollback receipt**

Before any rollback mutation, create/validate a durable receipt of the current managed live plus current authority state/root claims and tracked-overlay hash marker using the rollback PlanHash/context. If it fails, perform zero mutation.

- [ ] **Step 4: Use the common state machine**

Restore/remove live targets and atomically replace the existing authority state through the common journal; root claims are immutable and must match but are never created, replaced, or removed by ordinary environment rollback. Serialize a new rollback state whose semantic projection matches RollbackStateIntent. Cleanup swap-old/staged/pre-rollback copies only after complete success; preserve all durable receipts/evidence on restore failure.

- [ ] **Step 5: Verify three-platform rollback**

Run `tests/backup-recovery.tests.ps1` and the rollback section of `tests/harness-env.tests.ps1`.

Expected: Claude/Codex/Reasonix and the prior environment selection restore symmetrically only for an immediately eligible activation with identical overlay baseline, including an already-claimed custom Reasonix root; later generation/overlay drift, non-environment or noncommitted/unlinked receipts, MISSING/tampered authority preimage, or current drift fail before pre-rollback backup or mutation as applicable.

### Task 8: Run Concurrency and Hard-Kill Matrix

**Artifacts / Locations:**
- Modify: `tests/live-concurrency.tests.ps1`
- Modify: `tests/live-hard-kill.tests.ps1`
- Modify: `tests/helpers/failpoint-controller.ps1`
- Modify: `tests/helpers/process-tree.ps1`

- [ ] **Step 1: Test zero-wait losers**

Run two different plans against overlapping roots. Hold the winner at prepared; start loser with zero wait.

Expected: loser returns `operation-lock-busy` with zero backup/staging/journal mutation.

- [ ] **Step 2: Test sealed-host bounded-wait losers**

Through the sealed isolated host only, run two processes with the same reviewed plan and an injected bounded wait. Allow winner to complete, then waiter acquires lock and recomputes; separately prove every public `-LockWaitSeconds` form is rejected before side effects.

Expected: waiter returns `reviewed-plan-stale` with zero backup.

- [ ] **Step 3: Test all hard-kill windows**

Kill after RESERVED, during partial receipt, after RECEIPT_COMPLETE, after PREPARED, after target→swap-old rename before OLD_MOVED, after staged→target rename before NEW_INSTALLED, before/after state replace, and before the transaction `Phase=COMPLETE` record for each platform/action class. Associate every checkpoint with one expected recover classification and terminal Outcome.

Expected: restart classification matches reservation/receipt/disk tuple; no automatic forward resume; an unfinished reservation remains globally visible and outside/unknown/`.system` sentinels remain unchanged.

- [ ] **Step 4: Test root-claim overlap and custom targets**

Attempt two authorities sharing only one platform root; attempt default→custom Reasonix after a claim exists.

Expected: overlap and root transition are rejected with old/new roots untouched.

### Task 9: Run the Phase 2 Checkpoint

**Artifacts / Locations:**
- Record evidence in: this plan
- Keep unchanged: production interlock release state

- [ ] **Step 1: Run focused suites**

```powershell
pwsh -NoProfile -File tests/home-authority.tests.ps1
pwsh -NoProfile -File tests/live-plan.tests.ps1
pwsh -NoProfile -File tests/backup-receipt.tests.ps1
pwsh -NoProfile -File tests/sync.tests.ps1
pwsh -NoProfile -File tests/live-recovery.tests.ps1
pwsh -NoProfile -File tests/backup-recovery.tests.ps1
pwsh -NoProfile -File tests/live-concurrency.tests.ps1
pwsh -NoProfile -File tests/live-hard-kill.tests.ps1
```

Expected: zero failures and no process-tree residue.

- [ ] **Step 2: Validate every emitted artifact**

Validate root claims v1, minimal shared state 3 oneOf branches, sync schema 3 normal/retirement plans, receipts, live journals/reservations including terminal Outcome, rollback/recovery plan v1, and live-operation-result v1 via an external artifact manifest plus named semantic validators. Every negative fixture must fail at its declared layer.

- [ ] **Step 3: Run the full runner and repository gates**

Require exactly-once suite counts and syntax/build/scan/doctor/parity/dangerous-file gates. Run unstaged/staged `git diff --check` with exactly four protected Reasonix literal negative pathspecs, never broad `.reasonix/**`; the private-path test proves those leaves were never opened and a fifth adjacent file remains visible/scanned.

- [ ] **Step 4: Perform requirements and quality reviews**

Review design compliance first, then lock timing, unknown/`.system` no-read behavior, receipt finalization, current retirement guarantee preservation, journal durability, and recovery cleanup.

- [ ] **Step 5: Keep real homes untouched**

Confirm the tracked policy is still interlocked and no real live, legacy state, shared authority, or backup root was modified.
