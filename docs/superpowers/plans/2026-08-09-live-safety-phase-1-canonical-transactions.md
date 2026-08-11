# Canonical Source Transactions Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Status:** Prepared from the approved design; implementation has not started. This phase grants no Git staging/commit/publish or real live Apply authorization; production live mutation remains interlocked.

**Goal:** Make normalize, promote, and merge change canonical source, managed generated outputs, and manifests only through one reviewed, durable, recoverable transaction.

**Approach:** First land shared semantic-JSON, target-identity, and no-follow tree primitives because both canonical and live protocols depend on them. Then convert normalization into a pure candidate transform, add isolated build/scan planning, and journal every canonical/generated/manifest replacement under a repo-scoped lock. Preserve the current canonical/generated 7/15/7 inventory and retirement work while recognizing that the active `work` live subset is currently 2/4/2.

**Materials:** Approved design §§4.2–4.3 and 6.1; current `scripts/skills-common.ps1`; current `scripts/auto-merge-skills.ps1`; RFC 8785 canonicalization vectors; Phase 0 runner/validator/sandbox foundations.

**Validation:** Reasonix-incompatible input quarantines without touching a target; existing targets are clean replacements; dirty manifests fail before mutation; batch failure/hard kill/concurrency produces no partial canonical result and retains a reviewed recovery path; unknown generated files remain byte-identical.

---

### Task 1: Verify and Reuse Phase 0 Semantic JSON

**Artifacts / Locations:**
- Review: `scripts/semantic-json.ps1`
- Review: `tests/json-canonicalization.tests.ps1`
- Review: `tests/fixtures/json-canonicalization/`
- Keep unchanged: Phase 0 semantic hash contract

- [ ] **Step 1: Re-run the frozen canonicalization vectors**

Re-run Phase 0's property-order, nested, escaping, Unicode, empty/MISSING/null, exact I-JSON integer-boundary, duplicate-key, float/exponent/non-finite and two-fresh-process vectors before any canonical plan work. Add any newly discovered regression vector to the same suite only; do not create a second serializer or version.

Expected: every Phase 0 vector still passes and its expected bytes/hash remain unchanged.

- [ ] **Step 2: Check canonical-plan compatibility**

Confirm canonical transaction payload fields fit the frozen supported types and integer range. If they do not, stop and amend the approved cross-phase contract rather than silently changing Phase 0 hash semantics.

- [ ] **Step 3: Reuse document helpers**

Import the Phase 0 `Get-SemanticJsonHash`, `Get-PlanHash`, and `Get-DocumentHash` helpers unchanged. Do not wrap them with `ConvertTo-Json`, add a generic field-exclusion option, or create canonical-only hashing.

- [ ] **Step 4: Record the dependency checkpoint**

Run `tests/json-canonicalization.tests.ps1` and validate its machine-readable result before Task 2.

Expected: every valid vector has the committed hash in both processes; every unsupported/duplicate vector fails closed.

### Task 2: Implement Target Resolution and SafeTreeWalker

**Artifacts / Locations:**
- Create: `scripts/target-context-common.ps1`
- Create: `scripts/safe-tree-walker.ps1`
- Modify: `scripts/scan-input-common.ps1`
- Create: `tests/helpers/path-safety-fixtures.ps1`
- Create: `tests/path-safety.tests.ps1`
- Create: `tests/safe-tree-walker.tests.ps1`
- Modify: `tests/scan-input-boundary.tests.ps1`

- [ ] **Step 1: Write path and link failure fixtures**

Create isolated sentinels for target/ancestor junctions, symlinks, file symlinks, multi-link hardlinks, duplicate file identity, NTFS named alternate data streams, permission failure, path-case/separator variants, a full MISSING generated-parent chain plus absent target under an existing parent, root/volume target, source/target ancestor overlap, empty-directory add/remove/rename drift, unknown/`.system` reparse entries targeting a protected/outside sentinel, and fixed-NTFS versus UNC/mapped/removable/ReFS/FAT/unknown volume capability. Exercise both resolver modes: `MetadataOnly` with absent/custom roots and a missing capability cache must produce `UNPROBED`, stable RequestedInitialRootContextHash and zero filesystem writes; `MutationPreflight` must use only its approved probe slot, clean it, and bind a FilesystemCapabilityHash.

Expected: current string-prefix checks and `Get-ChildItem -Recurse` accept or traverse cases the new contract must reject.

- [ ] **Step 2: Implement stable target identity**

Freeze two explicit modes in this shared module rather than adding a later Phase 3 fork. For an existing path, both record canonical final path, case-insensitive location key, volume ID, file/directory ID, type, and every ancestor reparse identity; for an absent target, both record the deepest existing parent identity plus normalized remainder. `MetadataOnly` performs only no-follow metadata/inventory/overlap resolution, returns `FilesystemCapabilityStatus=UNPROBED` plus `RequestedInitialRootContextHash`, and is forbidden from creating/opening probe paths or target content. `MutationPreflight` additionally resolves Windows drive/filesystem type and runs the approved sibling staging-area rename/ReplaceFile capability probe, cleans its dedicated slot, and binds FilesystemCapabilityHash; protocol v1 accepts only local fixed NTFS. Reject volume roots, HomeRoot itself, `.system`, identity races, unresolved reparse points, network/removable/unknown filesystems, probe residue, and probe failure. DryRun/Apply use MutationPreflight and also bind/revalidate the independently computed MetadataOnly hash; read-only authority status in Phase 3 consumes MetadataOnly only.

- [ ] **Step 3: Implement no-follow walking**

Enumerate one directory level at a time without following links; validate each entry and opened file remains under the approved root identity; reject reparse entries, hardlink count greater than one, repeated identities, read races, and any non-default NTFS named stream on source or destination. Return two separate products: stable `ContentTreeRows` containing root/every directory (`Type`, normalized relative path) including empty directories and every regular unnamed stream (`Type`, relative path, length, content hash), with no filesystem IDs/ACL/timestamps; and `TraversalIdentityEvidence` containing opened handle/file identities plus ADS enumeration evidence used only for no-follow/race validation of that traversal.

- [ ] **Step 4: Implement safe copy/hash/compare**

Use only ordered `ContentTreeRows` for semantic tree hash, candidate copy, recovery copy, and byte/shape comparison; never expect filesystem identities to survive a copy. Copy must recreate empty directories and reject any source/destination content-row mismatch, while each traversal independently validates its own identity evidence. Retrofit Phase 0 `scan-input-common.ps1` to delegate to this one walker/ADS policy and rerun its privacy fixtures; do not retain a second recursive implementation. Unknown live entries and `.system` get only no-follow root-entry markers and are never passed to the recursive walker; any reparse marker blocks mutation without resolving/opening its target, proven by protected/outside access sentinels.

- [ ] **Step 5: Verify all boundary cases**

Run both new suites.

Expected: outside sentinels are never read or changed; valid regular trees copy/hash deterministically; absent→created target retains the same location key.

### Task 3: Turn Normalization into a Pure Candidate Transform

**Artifacts / Locations:**
- Modify: `scripts/skills-common.ps1`
- Modify: `scripts/normalize-skill.ps1`
- Modify: `tests/skills-import.tests.ps1`

- [ ] **Step 1: Add the missing regression cases**

Cover Reasonix-incompatible input with absent and existing outputs, compatible input over an existing target containing stale/nested files, secret/binary/platform-conflict quarantine, and arbitrary `OutputSkillPath` rejection.

Expected: current code deletes/continues for incompatible Reasonix and leaves stale/nested output in other cases.

- [ ] **Step 2: Split classify/transform from commit**

Replace `Normalize-SkillDirectory` with a candidate-only function that writes solely beneath a caller-provided CandidateWorkspace. Incompatible inputs return `quarantine/platform-incompatible` before any target creation/deletion. Always create a fresh candidate directory and never copy into an existing destination.

- [ ] **Step 3: Derive the canonical target**

Derive `skills-source/<TargetType>/<normalized-name>` internally from validated `TargetType` and skill name. Remove public `OutputSkillPath`; reject a name already present in a different canonical class.

- [ ] **Step 4: Gate the public command**

Make `normalize-skill.ps1` require exactly one `-DryRun -PlanPath <new>` or `-Apply -PlanPath <existing>`. At this task boundary, remove direct canonical copy and return `canonical-transaction-not-ready` before mutation; tests call only the internal candidate transform. Task 5 creates the adapter/plan contract and Task 8 performs final public routing, so this step has no dependency on a file that does not yet exist.

- [ ] **Step 5: Verify normalization behavior**

Run `tests/skills-import.tests.ps1`.

Expected: quarantine is zero-write; compatible candidates have no nested input or stale files; mode/target misuse fails.

### Task 4: Add Explicit Candidate Build and Scan Roots

**Artifacts / Locations:**
- Modify: `scripts/build-skills.ps1`
- Modify: `scripts/scan-secrets.ps1`
- Create: `tests/canonical-preflight.tests.ps1`
- Review: `.gitleaks.toml`

- [ ] **Step 1: Write isolation tests**

Snapshot real canonical/generated/manifest/report bytes, run a candidate build and scan against external output/report paths, and inject build/scan failure.

Expected: current RepoRoot-shaped calls cannot prove that every output is isolated.

- [ ] **Step 2: Add explicit internal preflight parameters**

The internal adapter accepts SourceRoot, three CandidateWorkspace generated output roots, CandidateWorkspace manifest root, a separately approved external/Git-private CanonicalPreflightOutputRoot, scanner configuration, and result paths beneath that output root. It resolves tool scripts from the approved toolchain, never from the candidate source tree; result/report/artifact-manifest/validation-summary paths all pass `Resolve-PrivateArtifactPath`.

- [ ] **Step 3: Enforce result gates**

Check child exit code, presence/content hash of the result JSON, registered schema, and `Result=PASS`. Treat missing/invalid JSON as failure even when exit code is zero.

- [ ] **Step 4: Verify zero real-tree writes**

Run `tests/canonical-preflight.tests.ps1`.

Expected: successful/failing preflight leaves current canonical/generated/manifests/reports byte-identical; only source/generated/manifests exist under CandidateWorkspace, while every registered result/report/manifest/summary is create-new beneath the approved CanonicalPreflightOutputRoot. No reviewed artifact is published inside the working tree.

### Task 5: Define the Canonical Transaction Plan

**Artifacts / Locations:**
- Create: `scripts/canonical-transaction-common.ps1`
- Create: `scripts/canonical-transaction.ps1`
- Create: `schemas/canonical-transaction-plan.schema.json`
- Create: `schemas/canonical-transaction-result.schema.json`
- Create: `schemas/canonical-setup-state.schema.json`
- Create: `schemas/canonical-root-claim.schema.json`
- Create: `tests/canonical-transaction.tests.ps1`
- Modify: `schemas/artifact-contracts.psd1`

- [ ] **Step 1: Write plan-contract failures**

Cover existing PlanPath, changed input, changed canonical source, dirty tracked manifest, changed managed generated target, unknown generated inventory drift, tampered metadata/payload/hash, wrong operation kind, and replay of a consumed `DocumentHash` after committed/no-op/abandoned/rolled-back/failed-restored outcomes even when every byte/context is reconstructed. Reuse the shared private-artifact-path table to require public canonical PlanPath be a validated `ExternalUserArtifact`; reject worktree, every arbitrary or contracted GitCommonDir/per-worktree internal path, reparse/hardlink/ADS/protected alias, and role substitution.

- [ ] **Step 2: Build the complete target list**

Use a strict operation oneOf. `setup` has no skill/candidate target: freeze the final v1 canonical-root-claim and canonical-setup-state schemas/serializers first, then bind PrivateRootBootstrapIntent for fixed ControlBase+BackupRoot, deterministic RepoId/ClaimId, selected CanonicalRecoveryRoot identity/capability, and their schema-valid exact expected global-claim/setup-state bytes hashes; its Apply remains interlocked until Phase 2 supplies bootstrap/global locking. `normalize|promote|merge` plan canonical directories, every managed generated directory changed by candidate build, per-platform/union manifest files, and every MISSING parent-directory component required to reach those targets. Bind old/new/MISSING hashes, parent creation order/expected identities, input hash, rewrite list, approved toolchain/policy hash, target identities plus FilesystemCapabilityHash, expected postconditions, and ordered unknown generated inventory. Reject setup fields on skill operations and vice versa.

- [ ] **Step 3: Reject dirty manifest ownership**

Compare each tracked manifest target to the Git index in DryRun and Apply. Any pre-existing dirty bytes fail before candidate preflight/mutation; there is no force option.

- [ ] **Step 4: Write immutable plans**

Use create-new `Metadata`, `PlanPayload`, `PlanHash`, and `DocumentHash`; `DocumentHash` is the consumption key. Freeze `CanonicalOperationKind=setup|normalize|promote|merge` in plan/header/fixed-result schemas and map the public adapters exactly; aliases cannot invent `auto-merge` as another stored value. Register and validate the artifact before reporting DryRun success. Define canonical-transaction-result v1 with the same command-versus-transaction scope discipline as the design and exact command enum `canonical-status|canonical-setup|canonical-normalize|canonical-promote|canonical-merge|canonical-recover-status|canonical-recover-abandon|canonical-recover-rollback|canonical-recover-finalize`: canonical-status is a no-transaction selector only; other command DryRun/preflight/lock/stale/recovery-required responses cannot masquerade as the fixed result. The transaction terminal-intent requires CanonicalOperationKind and branches by Outcome so early abandon binds only actual MISSING/PARTIAL/COMPLETE state, while committed/rolled-back/failed-restored require their respective postcondition/restoration refs and never fabricate future hashes. The terminal-intent is provisional until the matching `Phase=COMPLETE` record references ResultHash. Freeze `CanonicalRecoveryPlanKind=canonical-recover-abandon|canonical-recover-rollback|canonical-recover-finalize` for recovery-plan schema and recovery ClosingPlanKind; normal closure forbids it. Add wrong/alias operation, scope crossing, setup/skill-field crossing, missing/partial/fabricated-ref and consumed-document negatives.

- [ ] **Step 5: Verify plan binding**

Run the plan-only section of `tests/canonical-transaction.tests.ps1`.

Expected: every drift/tamper case fails; a clean unchanged context reproduces the reviewed PlanHash in a second process.

### Task 6: Add Repo Lock, Recovery Root, and Durable Journal

**Artifacts / Locations:**
- Create: `scripts/transaction-journal-common.ps1`
- Modify: `scripts/canonical-transaction-common.ps1`
- Create: `scripts/setup-canonical-transaction.ps1`
- Create: `scripts/recover-canonical-transaction.ps1`
- Review/reuse: `schemas/canonical-setup-state.schema.json`
- Review/reuse: `schemas/canonical-root-claim.schema.json`
- Create: `schemas/canonical-recovery-plan.schema.json`
- Create: `schemas/canonical-journal-header.schema.json`
- Create: `schemas/canonical-journal-record.schema.json`
- Create: `tests/canonical-recovery.tests.ps1`
- Modify: `schemas/artifact-contracts.psd1`
- Modify: `scripts/agent-dotfiles.ps1`
- Modify: `tests/canonical-transaction.tests.ps1`
- Create: `tests/canonical-hard-kill.tests.ps1`

- [ ] **Step 1: Select and validate CanonicalRecoveryRoot**

Add zero-write `agent-dotfiles.ps1 canonical status` plus `canonical setup -DryRun -PlanPath <new>` / matching `-Apply -PlanPath <existing>`, routed only to `setup-canonical-transaction.ps1` and `CanonicalOperationKind=setup`. Status reuses the no-create canonical recovery/setup locator and returns exactly `canonical-recovery-required|canonical-setup-required|canonical-ready|manual-recovery-required`; bootstrap and rollout call this same helper. Existing `scripts/setup.ps1` remains exclusively the runner-approval/inert-hook installer; it rejects canonical DryRun/Apply/PlanPath, while canonical setup rejects runner approve/install switches and never modifies hooks/approved-runner pointer. Canonical DryRun chooses a current-user-only, working-tree-external sibling/control directory on the repository volume and binds PrivateRootBootstrapIntent for fixed ControlBase+BackupRoot without creating either. Define `RepoId=ClaimId` deterministically from domain tag+token SID+GitCommonDir volume/directory identity so linked worktrees share it and fresh clones do not. Reuse Task 5's create-new/immutable, timestamp/nonce-free canonical setup-state/root-claim v1 serializers; setup-state's only locator is absolute resolved `git rev-parse --git-common-dir` plus literal `ai-agent-dotfiles/canonical-setup-state.json`, with linked-worktree equality, zero-or-one regular file and extra/reparse rejection. The setup plan binds exact expected global claim bytes/hash so Phase 2 can journal claim→state without regenerating choices. Do not mutate Phase 0 approved-runner-state v1 and do not offer replace/relocate in v1. Add linked/fresh/restart/identity-drift/collision/extra-entry/BackupRoot-MISSING/status-zero-write/cross-command-parameter/Apply-without-plan fixtures. Reject cross-volume, root, repo-descendant, source/live/backup/control overlap, or reparse ancestry. Phase 1 production canonical setup Apply returns interlocked; Phase 2 enables the same reviewed branch only after it can bootstrap ControlBase+BackupRoot, acquire global live lock, publish/finalize the matching global claim, and validate this root against every canonical/HomeAuthority claim on each use.

- [ ] **Step 2: Acquire the Git-common-dir lock**

Use an OS exclusive handle at `git rev-parse --git-common-dir`/`ai-agent-dotfiles/canonical.lock`. Public protocol v1 is fixed zero-wait and rejects `-LockWaitSeconds`; only the sealed isolated host may inject a 1–300 second bounded wait for concurrency tests, and that test-only value never enters plan/result. Hold from saved-plan revalidation through postconditions and journal completion. While holding it, enumerate every worktree namespace under the common-dir transaction root—not just the caller's worktree—and block on any unfinished reservation; validate each retained terminal header+published record chain+fixed result, reading original DocumentHash from the header, every recovery attempt DocumentHash from `RECOVERY_ACTION_INTENT` records, and ClosingDocumentHash from the final COMPLETE record, then reject the current operation or recovery hash as `reviewed-plan-consumed` if any matches. This phase tests the engine only through the sealed isolated host; Phase 2 adds the second global-live lock before production release.

- [ ] **Step 3: Implement hash-chained record files**

Write a create-new header binding the original operation `DocumentHash`, plus numbered create-new records with sequence, previous hash, phase, target identities, expected hashes, and paths. Self-validate each record in a unique `_pending/` temp, flush, then atomic rename to its fixed published sequence filename; no mutable head/complete-marker file exists, and DerivedJournalHeadHash comes from the highest contiguous valid published record. Before any reviewed recovery primitive/result/terminal, append `RECOVERY_ACTION_INTENT` with recovery PlanKind/DocumentHash, prior head and expected terminal semantic projection hash; this record consumes that attempt even if a later hard-kill requires a new recovery plan. The transaction namespace permits exactly zero or one fixed `result.json` plus `_pending/result-<guid>.tmp`: publish deterministic terminal-intent bytes by atomic create-new, binding TransactionId/original DocumentHash/ResultBaseHeadHash/Outcome without referencing a recovery plan. ResultBaseHeadHash must remain an ancestor of the final chain; later records may only be valid recovery intents/closing records. The sole terminal artifact is a published `Phase=COMPLETE` record that contains ResultHash, original header DocumentHash, `Outcome=committed|abandoned|rolled-back|failed-restored`, and a strict closing oneOf: original-command closure requires `ClosingKind=original`, `ClosingDocumentHash=header.DocumentHash` and forbids ClosingPlanKind; reviewed recovery requires `ClosingKind=recovery`, its exact canonical-recovery PlanKind and recovery-plan DocumentHash. Only the matching pair closes the reservation, while header/intent/terminal together consume original, every attempt and closing document hash; a result without terminal record remains unfinished. Register header/record/result ArtifactKinds and a chain semantic validator consuming a manifest that enumerates header/every published record/the optional result and rejects result cardinality greater than one. Known pending temps are excluded from the chain but preserved/reconciled after crash; published gaps/duplicates/extras/hash breaks, recovery action without prior intent, invalid result-base ancestry, mismatched result bytes/Outcome/ClosingKind, or unknown entries are manual recovery. Hard-kill before/after intent, result and record publish as well as mutation primitives. Never treat the directory as one journal JSON.

- [ ] **Step 4: Implement directory/file replacement records**

Create immutable `preimage/` copies/MISSING records for every target before the first primitive, and a distinct initially empty `swap-old/` path for mutation. For each MISSING parent component, record DIR_CREATE_INTENT, create exactly one component without overwrite, capture identity, and record DIR_CREATED parent-first; rollback removes child-first only when the captured identity is unchanged and the directory remains empty, otherwise manual recovery preserves it. For directories record PREPARED, MOVE_OLD_INTENT, OLD_MOVED, MOVE_NEW_INTENT, NEW_INSTALLED against target/swap-old/staged while separately binding preimage identity/hash. For each manifest record FILE_PREPARED and FILE_REPLACE_INTENT, then use same-directory staged bytes plus OS atomic replace that captures the existing destination into swap-old (or no-overwrite atomic move for MISSING), reconcile the file tuple, and record FILE_REPLACED. Never reuse or delete preimage to make room for swap-old.

- [ ] **Step 5: Implement disk reconciliation**

For intent-only records, compare target/swap-old/staged plus immutable preimage existence, identity, and hash to known pre/post tuples. Ambiguous tuples become `manual-recovery-required` and preserve all bytes.

- [ ] **Step 6: Add the reviewed canonical recovery surface**

Add read-only `canonical recover status`, plus `abandon|rollback|finalize -TransactionId <id> -DryRun -PlanPath <new>` and matching `-Apply -PlanPath <existing>` dispatch; these actions map exactly to `canonical-recover-abandon|canonical-recover-rollback|canonical-recover-finalize`. Status never creates the common-dir parent, transaction namespace, or `canonical.lock`: it no-create opens an existing lock; if both lock and namespace are absent it performs a before/after metadata double-check and reports no transaction, while a namespace without its contracted lock or any concurrent creation returns retry/manual diagnostic without opening content. Plan generation/Apply for an existing transaction acquire that pre-existing common lock, enumerate all worktree namespaces, and require TransactionId to resolve uniquely across them. Reject missing/wrong/duplicate id and bind it in the v1 recovery schema together with source worktree namespace, header/published-record chain/DerivedJournalHeadHash/pending-temp/result inventory, every target/swap-old/staged/preimage tuple, original plus prior-attempt consumption keys, current context, expected Outcome/terminal semantic projection when result is MISSING, and planned action through PlanHash/DocumentHash. The projection excludes ResultHash, ResultBaseHeadHash and the current plan hash, so the reference graph is acyclic. Apply revalidates the saved plan, publishes its `RECOVERY_ACTION_INTENT` before any action, then either creates a projection-matching result from the actual post-action head or reuses a matching existing `result.json` byte-for-byte; finalize preserves its Outcome. It records the closing DocumentHash in `ClosingKind=recovery` COMPLETE together with the exact canonical recovery PlanKind. Normal success/caught fully-restored closure instead uses `ClosingKind=original`, repeats the header DocumentHash and forbids ClosingPlanKind. No automatic forward resume is permitted outside the explicit canonical-setup recovery row below.

- [ ] **Step 7: Verify locking, recovery, and hard-kill windows**

Run public zero-wait lock-busy tests plus sealed-host-only bounded-wait tests, and use the Phase 0 failpoint/process-tree helpers for this named checkpoint matrix:

| Checkpoint and reconciled disk state | Only legal status/action |
|---|---|
| canonical setup: exact global claim published, prebound setup-state MISSING | `canonical-recover-finalize` may create only the deterministic state bytes/hash already bound by claim/header, then publish matching result/COMPLETE; original setup Apply and generic rollback/forward resume are forbidden |
| canonical setup: zero claim/state primitive | abandon |
| canonical setup: exact claim+state present, terminal missing | finalize record/result only; no target primitive |
| canonical setup: state without claim, mismatched/corrupt claim/state, changed root or unfinished ambiguity | manual-recovery-required |
| flushed `PREPARED`/`FILE_PREPARED`, before any primitive | abandon |
| `DIR_CREATE_INTENT` with component absent | abandon |
| parent component created, before flushed `DIR_CREATED` | rollback only if same identity and empty; otherwise manual |
| old→swap-old succeeded, before flushed `OLD_MOVED` | rollback |
| staged→target succeeded, before flushed `NEW_INSTALLED` | rollback |
| atomic file replace/move succeeded, before flushed `FILE_REPLACED` | rollback |
| all targets have flushed `NEW_INSTALLED`/`FILE_REPLACED`, before flushed `POSTCONDITIONS_OK` | rollback |
| flushed `POSTCONDITIONS_OK`, result MISSING, before published `Phase=COMPLETE` record | finalize may create only the deterministic reviewed `committed` result, then COMPLETE |
| matching fixed `result.json` exists, before published `Phase=COMPLETE` record | finalize reuses it and preserves its existing Outcome exactly |
| tuple, immutable preimage, hash-chain, pending result temp, or fixed result is ambiguous/mismatched | manual-recovery-required |
| `Phase=COMPLETE` record exists and validates | terminal clean/auditable outcome; every prior operation/recovery plan is stale |

Hard-kill exactly between each parent mkdir, directory rename, or file replace/move and its result record, and immediately before/after `POSTCONDITIONS_OK`, fixed result and final `Phase=COMPLETE` record publish. In linked worktree A create/kill a transaction, then prove worktree B's status finds it, new mutation is blocked, the TransactionId resolves uniquely, reviewed recovery succeeds from B, and original/closing plan replay is rejected globally. Race an external manifest edit between final precheck and atomic replace; require either plan-stale before primitive or manual recovery with the raced bytes captured in swap-old, never silent loss. Exercise status, the one allowed reviewed action, stale recovery plans, every terminal Outcome, and injected recovery failure at every row; never offer forward resume.

Expected: concurrent transactions never interleave; every checkpoint has exactly one classification above; a killed transaction blocks new mutation and can be recovered only through a retained, externally reviewed recovery plan; preimage and swap-old remain distinct until complete success/recovery.

### Task 7: Apply and Verify the Multi-Target Transaction

**Artifacts / Locations:**
- Modify: `scripts/canonical-transaction-common.ps1`
- Modify: `scripts/canonical-transaction.ps1`
- Modify: `tests/canonical-transaction.tests.ps1`

- [ ] **Step 1: Stage verified target bytes**

Copy candidate canonical/generated/manifest bytes to same-volume staged targets using SafeTreeWalker. Revalidate the reviewed document, current plan, input, canonical source, managed outputs, manifests, unknown inventory, identities, and dirty state under the lock before creating immutable preimages; verify every swap-old path is still MISSING.

- [ ] **Step 2: Execute all targets through the journal**

Apply each planned target in deterministic order. Never touch generated unknown/runtime-exclusion entries. Before the canonical commit boundary, a caught failure restores every touched target in reverse order while holding the lock and, after exact old-state verification, publishes `Outcome=failed-restored` while returning non-zero. Flushed `POSTCONDITIONS_OK` is the canonical commit boundary; after it, any result/final-record failure retains evidence and uses reviewed finalize rather than restoring targets.

- [ ] **Step 3: Verify postconditions without writing real output**

From the committed canonical tree, rebuild into a new CandidateWorkspace, run scan, and compare expected candidate bytes to real managed generated/manifests. Any mismatch triggers byte-preserving rollback; only after every comparison passes may the journal flush `POSTCONDITIONS_OK`.

- [ ] **Step 4: Finalize or retain recovery**

Only after all postconditions pass, flush `POSTCONDITIONS_OK`, atomic-create the fixed validated `result.json`, then publish the final `Phase=COMPLETE, Outcome=committed` record referencing ResultHash; no required publish follows it. Reviewed abandon/rollback use the same order with `Outcome=abandoned|rolled-back`; a fully restored caught failure uses `failed-restored`. If result exists but terminal publish fails, reviewed finalize must reuse its exact bytes/hash/Outcome rather than issuing `committed`; if result is MISSING, its recovery plan binds the unique deterministic expected bytes. Result or terminal-record failure leaves an unfinished transaction for reviewed recovery. Keep durable audit/recovery evidence on any non-terminal failure; classify `apply-failed-but-restored` versus `recovery-required`.

- [ ] **Step 5: Verify failure matrix**

Inject failure at every target, build/scan result gate, postcondition, and cleanup boundary.

Expected: success matches the reviewed candidate; every failure is byte-identical to pre-state or has an intact reviewed recovery route.

### Task 8: Migrate Normalize, Promote, and Merge

**Artifacts / Locations:**
- Modify: `scripts/normalize-skill.ps1`
- Modify: `scripts/promote-skill.ps1`
- Modify: `scripts/auto-merge-skills.ps1`
- Modify: `scripts/agent-dotfiles.ps1`
- Modify: `tests/skills-import.tests.ps1`
- Modify: `tests/agent-dotfiles.tests.ps1`

- [ ] **Step 1: Route every canonical write through one CLI**

Normalize/promote create one proposed replacement; auto-merge creates one batch replacement set. All require external DryRun/Apply PlanPath and exactly the same stored `CanonicalOperationKind=normalize|promote|merge` on both invocations; script/CLI aliases map before plan generation and cannot alter the stored value.

- [ ] **Step 2: Remove legacy mutation paths**

Delete direct `Copy-Item`/`Remove-Item` canonical writes and auto-merge's post-write build/scan. Check every child exit and schema-validated machine result.

- [ ] **Step 3: Preserve current classification/inventory behavior**

Do not resurrect deleted skills or MCP integration. Preserve existing-canonical retention, quarantine/archive reporting, current canonical counts, and explicit user-owned dirty changes.

- [ ] **Step 4: Verify batch atomicity**

Run import tests plus canonical transaction tests with a later candidate forced to fail.

Expected: no earlier candidate appears in canonical source; one reviewed plan covers the whole batch.

### Task 9: Run the Phase 1 Checkpoint

**Artifacts / Locations:**
- Record evidence in: this plan
- Keep unchanged: `scripts/live-safety-policy.psd1` release state

- [ ] **Step 1: Run focused suites**

```powershell
pwsh -NoProfile -File tests/json-canonicalization.tests.ps1
pwsh -NoProfile -File tests/path-safety.tests.ps1
pwsh -NoProfile -File tests/safe-tree-walker.tests.ps1
pwsh -NoProfile -File tests/skills-import.tests.ps1
pwsh -NoProfile -File tests/canonical-preflight.tests.ps1
pwsh -NoProfile -File tests/canonical-transaction.tests.ps1
pwsh -NoProfile -File tests/canonical-hard-kill.tests.ps1
pwsh -NoProfile -File tests/canonical-recovery.tests.ps1
```

Expected: zero failures; all tests use isolated candidates/recovery roots.

- [ ] **Step 2: Run full runner and artifact validation**

Use new external summary paths and require discovered=started=completed=passed with all error counts zero. Validate every canonical transaction/recovery plan, result, journal fixture, semantic validator, and emitted artifact.

- [ ] **Step 3: Run build/scan/doctor and diff checks**

Run current repository gates, then unstaged/staged `git diff --check` with exactly the four protected Reasonix literal negative pathspecs, never a broad directory exclude. The Phase 0 privacy test must prove no protected desktop-state content was opened while a fifth adjacent `.reasonix` file remains visible/scanned. Confirm current manifests still describe 7 Claude, 15 Codex, and 7 Reasonix skills unless an explicitly reviewed canonical change in this phase intended otherwise.

- [ ] **Step 4: Perform requirements and quality reviews**

Review design compliance first, then path identity, no-follow behavior, lock lifetime, recovery durability, journal reconciliation, and unknown generated preservation.

- [ ] **Step 5: Leave live mutation interlocked**

Do not change the protocol policy to released and do not run any production live Apply.
