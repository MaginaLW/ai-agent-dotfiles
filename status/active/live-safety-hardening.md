# Live Safety Hardening

Last updated: 2026-09-23 (audit handoff)

Status: Complete through Phase 3. Baseline-reconciliation Task 1 is complete (5/5), the Phase 0
entry-interlock subplan is complete (43/43), Phase 1 is complete (44/44), Phase 2 is complete
(52/52: Tasks 1-9, with the one cross-authority proof recorded as a Phase 4-bound design input), and
Phase 3 is complete (47/47: Tasks 1-9, the checkpoint at `e57c608`, its two review findings closed
by `872ad03` and `976d0fe`, and the carried sealed-file slice closed by `bbfa6d5`). Phase 4
implementation Tasks 1–7 are complete; Task 8's candidate was rejected and remediation/acceptance
remain open. Task 9 follows accepted-candidate evidence. The rewrite
record anchors the force-with-lease publish head at `bbba28f` (verified: that commit is
`chore(privacy): ignore local Reasonix desktop state` and its own diff is a `.gitignore` change
only; which commit actually carries the privacy-rewrite content remains open for the owner — a
rewritten history cannot resolve pre-rewrite SHAs; pending item 8); GitHub Support ticket
`#4697323` is resolved after
server-side garbage collection/cache clearing, and the 2026-08-27 old-SHA re-probe confirms the
object is no longer served. This per-task record is a dated log: the sections below run in
completion order and several of them carry their own superseded markers. Earlier Pending lists
are historical snapshots, not instructions to restart completed work. The current task handoff is
[the 2026-09-23 audit and ordered backlog](#2026-09-23-multi-agent-audit-and-ordered-backlog);
repository-wide release and CI state belongs in [STATUS.md](../../STATUS.md#current-state).
The [staged completion plan](../../docs/superpowers/plans/2026-09-23-post-audit-completion-plan.md)
defines subsequent execution and acceptance; S0 is integrated and S1 is in progress. See the
[execution record](#2026-09-23-post-audit-execution); S2–S6 have not started.

Policy: `ProtocolVersion=3`, `ReleaseState=released`; candidate acceptance is incomplete.

## Completed evidence

- Phase 0: 43/43 checklist items complete; implementation commit `0a6c16e`.
- Phase 1: 44/44 checklist items complete.
- Phase 1 checkpoint unified validation: 31/31 suites passed with every error count zero; summary SHA-256
  `744f20d5f2155e0c0d6560c49c8f78e0fd86d95364b3048d4e3668f73214f82b`.
- Artifact validation: 19 contracts, 19 positive fixtures, 28 negative fixtures, 0 failures;
  summary SHA-256 `1304e114343120903fcaceec57ea80fa8ead77bd252ad6a609625bd2ce7216d2`.
- Build (Claude 7 / Codex 15 / Reasonix 7), secret scan, doctor, protected-path privacy test,
  diff checks, and sync DryRun passed without live mutation.
- Corrected history rewrite: fresh remote and local branch audits contain zero protected-path
  records and zero targeted STATUS matches; four local user-owned files remain present and ignored.
- GitHub Support closure: ticket `#4697323` is resolved after Support ran server-side garbage
  collection and cleared the repository cache. The independent old-SHA re-probe returned 404 for
  commit/tree/raw endpoints, 422 from the commits REST endpoint, and `upload-pack: not our ref` from
  a no-write direct-fetch dry run; local HEAD and refs remained unchanged.
- Phase 2 Task 1 intermediate read-only authority/schema slice: token/Known-Folder authority,
  no-follow metadata targets, root-claims v1, current-env-state v3, and exact-byte pair validation are
  implemented. Registered validation passed 21 positives and 66 negatives with zero failures; three
  independent authority/schema/fixture reviews passed after their findings were fixed.
- Phase 2 Task 1 sealed bootstrap/global-lock slice: an external bootstrap lock protects an exact
  six-directory plus final-lock prefix with atomic final ACLs; existing-only global acquisition,
  callback/opaque ACE rejection, two-repository zero-wait contention, test-only bounded wait,
  owner-death release, and all 14 before/after hard-kill boundaries pass. Independent security,
  concurrency-evidence, and scope reviews passed after their findings were fixed.
- Phase 2 Task 1 held-global-lock registry slice: pristine bootstrap and fixed post-bootstrap
  envelopes are separate, and a real typed global-lock witness guards a read-only unified view with
  strict in-memory zero-write validation of canonical/home claims, `VALID|MISSING|INVALID` state,
  represented-root conflicts, and unresolved normalized-UUID live markers. Tests cover typed-lock,
  zero-write, overlap, and hostile topology/type/reparse/hard-link/ADS/security cases.
- Phase 2 Task 1 caller-held canonical/current-route slice: exact canonical setup bytes and transaction
  evidence are sealed under the canonical lock; canonical-bound acquisition binds the genuine CLR
  owner in strict canonical-to-global order, and dependent locks release only tail-to-head. The
  read-only route-set capture revalidates held metadata, rejects stateful/ABA/ETS/foreign-owner
  substitution and drift, and closes private target/live-set/registry receipts through retryable
  `OPEN|CLOSING|CLOSED` states.
  Registry coverage is `HELD_METADATA_VERIFIED`; filesystem capability remains
  `UNPROBED_READ_ONLY`. Current-route overlap coverage is implemented without claiming the complete
  forbidden-root matrix or production integration.
- 2026-08-28 CI repair (infrastructure, no Task 1 step): the always-red `Validate` workflow was
  traced to elevated GitHub runner tokens creating `BUILTIN\Administrators`-owned objects while the
  current-user-only checks demanded the token user SID. Resolver version
  `windows-token-sid-current-user-only-v2` accepts owner evidence from {token user SID, token
  default owner} across canonical, home-authority, and registry checks; DACL current-user-only
  requirements are unchanged. The hard-kill suite self-seals its own bytes and the reviewed load;
  the repair re-pinned the reviewed-load manifest, actual-prelude rows and digest, pre-section
  region, transport-contract extent, function inventory, cleanup-gate self digest, and controller
  surface digest while the 299/81/2 sealed mutation inventory revalidated unchanged. Schemas and
  the three positive fixtures moved to v2. The parent-lease external-attack wait now exceeds the
  helper's own deadline so missed windows surface as explicit diagnostics. Local validation:
  syntax gate 156 files, artifact validation 21/21/66/0, targeted suites green (recovery 104/0
  including three new owner-rule assertions, command-result 46/0, registry/transaction/
  parent-lease/home-authority/live-concurrency pass), build 7/15/7, secret scan clean, sync
  DryRun without mutation. The definitive unified run passed all 34 suites exactly once with
  zero failures and timeouts (hard-kill 317/0 inside the run); external create-new summary
  SHA-256 `fef5a8e1d1ed5acd5a1bf74c8b7290b19a06aceb043f4ad5452f5735d5a396fa`. The follow-up CI
  run for `6540681` then completed green with 34/34 and hard-kill 317/0 on the runner, closing
  the failure streak since 2026-08-09. Production Apply remains interlocked.
- Phase 2 fourth-checkpoint unified validation: all 34 suites were discovered and passed exactly
  once with every runner error count zero; external create-new summary raw SHA-256
  `b8bc1c887ea1d8aaf9cffbc2ef63ded74779ea430920a117a377b695d21710ec` and independently recomputed
  discovery SHA-256
  `1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`. The hard-kill suite reached
  317/0 and the registry suite emitted 159 PASS assertions with exit code 0. Build (7/15/7), secret
  scan, and sync DryRun passed without production Apply, live-root mutation, Git index/ref mutation,
  or new hard-kill temporary-directory residue.

> **Superseded (2026-09-16).** The repeated closing line "Task 1 remains 1/6 and Phase 2 remains
> 1/52" (and the variant "Phase 2 1/52") in the 2026-08-29 through 2026-09-06 Phase 2 Task 1
> bullets below recorded the state before Phase 2 closed on 2026-09-13 (Tasks 1-9). Phase 3 later
> closed at 47/47 (checkpoint `e57c608`, review follow-ups `872ad03` and `976d0fe`). The
> "Production Apply remains interlocked" clause in those same sentences is still true. The text
> is kept as history.

- Phase 2 Task 1 Step 1 failure-matrix completion (2026-08-29, test-only): the remaining
  identity/concurrency failure cases were written with no production script change. Registry tests
  now cover a tracked working tree/GitCommonDir inside a live target root, second-repository claims
  nested in and exactly duplicating an existing recovery root, linked-worktree versus second-clone
  identity and lock namespaces, two-HomeRoot ancestor/descendant overlap, and enumerated rejection of
  public `-HomeRoot`/`-BackupRoot`/`-LockWaitSeconds`/`-TestMode` on the registry command surface.
  Home-authority tests add the exhaustive six-pair state-semantics platform-overlap matrix, per-root
  incremental absent-to-created classification, and the same parameter enumeration across
  authority/lock/bootstrap/live-target commands. Live-concurrency adds a `canonical-global-hold`
  host operation proving a canonical-bound global holder beats live-route and second-repository
  canonical contenders with exact zero-wait busy, zero writes, correct canonical-before-global order,
  and post-release witness re-acquisition; adopt/retirement races are covered at the implemented
  lock-class level pending the Step 5 retrofit. Focused suites passed (191/197/222 PASS assertions),
  and the unified `run-tests.ps1 -All` run passed all 34 suites exactly once with zero
  failures/timeouts (summary SHA-256 `0bbff288638a3ca5a509fa158a398b59d1bb4b45c10f63150452cfaa92fa15e2`,
  hard-kill 317/0); build (7/15/7), secret scan, parse gate (156 files), diff checks, and sync DryRun
  passed. Step 1 is complete (Task 1 1/6, Phase 2 1/52). Production Apply remains interlocked.

- Phase 2 Task 1 sealed under-lock capability preflight (2026-08-29, additive building block): the
  registry surface gained `Invoke-SealedHeldCapabilityPreflight` with CLR-sealed evidence types. It
  requires the genuine global-lock witness (optional canonical witness revalidated in order), accepts
  only an approved external non-reparse probe root disjoint from the authority area and targets, fails
  closed on pre-existing probe residue without modifying it, binds metadata VolumeId to the live
  volume serial, and runs the real write-capability probe per target under the held locks. Evidence
  rows are immutable and a supplied expected hash must reproduce the under-lock probe exactly; the
  tests prove the plan-bound recovery-root claim hash reproduces under the held locks, with zero
  authority-area writes and zero residue from the invocation's exact owned probe slots. The preflight
  never wildcard-cleans matching entries: foreign residue created after the initial check is
  preserved and makes the post-probe check fail closed. Lock/contract rejections and ETS forgery
  resistance remain covered. No pinned script changed and no production route consumes the
  preflight yet;
  Step 2's resolver-side wiring and setup-Apply bootstrap flow remain open. Focused
  `root-claims-registry.tests.ps1` reached 218 PASS with exit code 0. The unified `run-tests.ps1
  -All` run passed all 34 suites exactly once with zero failures/timeouts (summary SHA-256
  `51f51e8b0eba5421979b712cb586826bc392ce90251b97ea8e114e0c82a0e8c4`, hard-kill 317/0); parse gate
  (156 files), build (7/15/7), secret scan, diff checks, and sync DryRun passed. Task 1 remains 1/6
  and Phase 2 remains 1/52. Production Apply remains interlocked.

- Phase 2 Task 1 per-target/per-volume capability and exact-slot hardening (2026-08-29, additive
  building block): the preflight now accepts an exact target-to-ProbeRoot map and seals each root's
  path, location key, and captured identity into its target row. It validates the complete map before
  the first probe, including target/target, target/root, root/root, and authority overlap plus exact
  target/root volume equality. Canonical LocationKey ordering makes evidence permutation-stable. A
  dynamic two-Fixed/NTFS-volume branch executed on the current validation host and proved correct
  per-volume routing, both wrong-volume zero-probe rejections, zero authority/external drift, and
  empty probe roots. The lower probe holds the full ProbeRoot containment chain, binds the expected
  root identity, rejects matching residue case-insensitively before and after probing, and uses a
  create-new, no-delete-share held GUID slot. Exact-slot creation rollback/deletion requires the same
  identity, directory type, single-link state, no alternate streams, and emptiness; child cleanup is
  identity-bound under that held slot. Foreign entries and bytes are preserved, with no
  wildcard/recursive/path-delete fallback. Pinned-source and
  dependent hard-kill hashes are recomputed from the final reviewed bytes. No production route
  consumes this evidence; Task 1 remains 1/6 and Phase 2 remains 1/52, with production Apply still
  interlocked. Final validation on 2026-08-30 passed the 156-file parse gate, artifact validation
  (21 contracts, 21 positive fixtures, 66 negative fixtures), and all 34 unified suites exactly once
  with zero failure/timeout/discovery/process-tree anomalies; the external summary SHA-256 is
  `7e4d1c855804a4db29d9ca4175fa1bb7c9113bfc1b238564cd3ce19ec6a0e0bf`, with hard-kill 317/0.
  Final build (7/15/7), pinned gitleaks (no blocking findings; 828 reviewed hints), diff checks, and
  sync DryRun also passed; the DryRun preserved `.system` and changed no live file.

- Phase 2 Task 1 fixed-infrastructure same-lock capability capture (2026-08-30, additive Step 2
  checkpoint): the new internal `Invoke-SealedHeldFixedInfrastructureCapabilityCapture` accepts
  exactly the `ControlBase` and `BackupRoot` roles, derives both target paths only from the sealed
  authority context, holds one outer fixed-envelope lease across both real per-target probes, and
  returns CLR-sealed `FIXED_INFRASTRUCTURE_PROBED` evidence only after exact final global-lock,
  optional canonical-binding, fixed-envelope, identity, security, volume, filesystem, and role-map
  revalidation. A private-token exact issuer pins the reviewed raw-preflight and lower-probe
  ScriptBlocks so command shadows and public-factory evidence cannot substitute for the real probes;
  an independently tested validator rejects forged/reprojected or self-consistently drifted raw
  evidence. Primary and cleanup failures retain their separate evidence, including outer-envelope
  cleanup Data. Recursive production-seam guards prove zero production consumer and freeze dynamic,
  member/property, reflection, `using`, type-definition, `Add-Type`, and member-dispatch bypass
  surfaces; AppDomain/string, case-variant, and short-type/property-only reflection mutations all
  fail closed. Focused root-claims and 29/0 seam suites, modified-file parsing, and diff checks passed.
  Closure validation also hardened two tests-only bounds: legacy Job reap now uses one reviewed
  30-second absolute deadline and primary-first cleanup. At that checkpoint its dedicated semantics
  suite had a 60-second runner bound, the expanded root-claims suite had a 600-second bound, and the
  Windows workflow used 276 minutes. The 16335-second computed requirement remained below the
  16560-second job limit with a 225-second outer difference. These historical budget values are
  superseded by the 2026-09-01 correction below. The 34/34 create-new unified
  summary predates only this final budget-only adjustment; afterward reap semantics passed 27/0 and
  the runner contract passed with the 60-second/276-minute delta. That unified summary passed 34/34
  with every failure counter zero
  (SHA-256 `fdf669636415e10f7f9e76b9f404ced705e02eb9225b6a89f1060205d4462784`); hard-kill reached 317/0,
  reap semantics 27/0, and the root-claims suite completed in 306091 ms. The 156-file parse gate,
  artifact matrix 21/21/66, build 7/15/7, pinned secret scan with zero blocking findings, diff checks,
  and sync DryRun then passed; `.system` was preserved and no live file changed. The wide
  reflection/member digest intentionally requires review for future production dispatch changes. No
  production Apply/rollback/current-route consumer uses this evidence; process-static
  first-ScriptBlock/runspace lifetime and evidence temporal scope remain integration blockers.
  Task 1 remains 1/6 and Phase 2 remains 1/52, with production Apply interlocked.

- Phase 2 Task 1 receiver-backed held-route capability observation (2026-08-31, commit `4af1d79`,
  narrow Step 2 checkpoint): a caller-owned sealed receiver now accepts exact ownership transfer for
  safe containment chains, target/live leases, current-route capture, and the runtime observation.
  The observation borrows the genuine held route, canonical witness, and global lock, owns frozen
  outer fixed-envelope handle chains, and reports exactly
  `Coverage=HELD_CURRENT_ROUTE_FIXED_INFRASTRUCTURE_PROBED`, `Scope=RUNTIME_ONLY`, and
  `MutationAuthorization=NONE`. Its public `Open`/`Assert`/`Close` lifecycle APIs have zero production
  callers. The only production consumer of the current-route capture remains the read-only registry,
  whose output is still `HELD_METADATA_VERIFIED` / `UNPROBED_READ_ONLY`; no resolver, dispatcher,
  setup, Apply, rollback, or live-mutation path consumes the observation.

  The fixed-capability issuer moved from process-first ScriptBlock capture to per-runspace definitions
  weak-keyed by `Runspace`, with exact pinned ScriptBlock references, runspace identity, and a
  definition-local issuer token. Real `PowerShell.Stop` coverage pins the route's exact
  `DeliverExact`-to-transfer-flag boundary, proves observation receiver durability after public
  `Open` returns, and verifies the delivered safe-chain/target resources remain open for explicit
  cleanup. It does not claim an internal observation `DeliverExact`-to-flag breakpoint, cover legacy
  raw success-stream return branches, or make the complete public API Stop-safe. Remaining debt includes legacy raw returns (safe-existing,
  retained traversal, target, and live-set included); runspace-disposal recovery and observation
  definitions retaining strong runspace references; target/live `Assert` versus concurrent `Close`;
  transitive provider closure and raw-getter capability transfer; computed provider-path dataflow and
  a literal-provider-token static false positive; opaque bare lease wrappers; and a durable recovery
  ticket when route cleanup itself fails. Step 2 remains incomplete; Task 1 stays 1/6, Phase 2 stays
  1/52, and production Apply remains interlocked.

  Validation follow-up on 2026-09-01 proved two budget defects rather than hangs. The production-seam
  suite completed standalone in about 166.9 seconds and then passed 56/0 under the real runner in
  193092 ms with a 240-second bound. The observation lifecycle added about nine real `Open` paths
  plus route captures; the root-claims suite then passed under the real runner with 438 PASS lines and
  exit code 0 in 1291927 ms with an 1800-second bound. The first unified
  run completed 31 suites successfully, rejected one stale hard-kill reviewed baseline, and cleanly
  tree-reaped only those two under-budget suites. Seventeen directly or transitively affected
  reviewed constants were recomputed against the committed production bytes; the reviewed load set
  and 67-function/131-edge static production closure remained unchanged. The new
  suite-budget sum is 17235 seconds, the computed job requirement is 17655 seconds, and the Windows
  workflow is 298 minutes / 17880 seconds, retaining the prior 225-second outer difference. Focused
  validation passed hard-kill primitives 95/0, complete hard-kill 317/0, the runner budget contract,
  and both real-runner timeout checks. The final unified result is recorded in the recovery-stage
  follow-up below. This changes only tests and CI bounds and grants no production mutation authority.

- Test-internal recovery-stage publication-race follow-up (2026-09-01, commit `b1fe6e1`): a
  subsequent create-new validation attempt completed all 34 discovered and started suites with 33
  passing, one failing, and zero timeouts (summary SHA-256
  `88b4cfd0cfb911600c3a1fbf76c7c82e362f8ffaebeaa930c6826372d9445342`). The only failing suite was
  hard-kill at 233/5: its tests-only reader opened a publisher-private temp through `ReadAllText`,
  blocked `File.Move`, and caused four later failures to cascade. The reader now classifies the
  complete enumerated name set first, reports an exact temp as stable publication-in-progress, gives
  unknown names precedence, and reads content only from validated final names. Exclusive-open probes
  pin this behavior deterministically.

  The repair changes only the seven required transitive reviewed baselines; final hard-kill file
  SHA-256 is `2e3dae688d2334fe171558adfee00b68ba5e2778a5f6ae70a1a1637cf9e5c234`.
  Primitives passed 95/0, the original failing focused case set passed 22/0, the complete hard-kill
  suite passed 318/0, and read-only logic/baseline audits found no P0, P1, or P2 issue. This is not
  held-identity or atomic-directory-snapshot evidence: final replacement, StageRoot rebinding, and
  external scanners remain open boundaries. The final create-new unified run discovered, started,
  completed, and passed all 34 suites exactly once, with zero failures, timeouts, duplicates, missing
  suites, or tree-kill failures. Its external summary SHA-256 is
  `976f84e50aadc0ac37fb89acee183961d01c6f5fdf9a5ff99fda11424b72c5a8`; the embedded hard-kill
  record exited 0 and passed 318/0.

  Final post-run gates passed the 156-file PowerShell syntax check, registered artifact validation
  at 21 contracts / 21 positive / 66 negative / 0 failures (summary SHA-256
  `b87d5c65bc3e1f1bee8375b54acb023edf9cdb8b515da3251ca3e6ce412af0cf`), the 7/15/7
  Claude/Codex/Reasonix skill build, and the pinned secret scan with zero blocking findings. A sync
  DryRun used a fresh external path whose plan leaf was absent before invocation, changed no live
  files, and produced PlanHash
  `b94ca90b872568bddeed048a959b37b40f0cd8f1d89c90936afa876a32783e2e` with plan-file SHA-256
  `4c5ccb35185531f5da8a052371bef4a3f76a741571056536ea22a2e92a236d08`. No Apply was run. Task 1
  remains 1/6, Phase 2 remains 1/52, and production Apply remains interlocked.

- Phase 2 Task 1 observation issuer per-runscape definition migration (2026-09-01): the observation
  issuer's pinned definitions moved from a process-static `Dictionary<string,...>` keyed by
  normalized runscape-id strings to the reviewed per-runscape `ConditionalWeakTable<Runspace,...>`
  pattern with an `OwnerRunspaceId` Guid binding, matching the route-capture and fixed-capability
  issuers. Definition resolution now goes through the live current-runscape object, its instance id,
  and the owner binding; `InitializeObservationExact` validates the supplied runscape id against the
  actual current runscape. Fail-closed contracts are unchanged (cross-runscape, same-text
  substitution, clone/uninitialized rejection); the issuer public surface and every PowerShell-level
  function are byte-identical. The focused root-claims suite reached 442 PASS with exit code 0
  (438 before), pinning the storage type, the owner binding, and child-runscape recovery (a fresh
  runscape initializes its own equal-digest definition bound to itself). An out-of-repository probe
  recorded the honest boundary that forced GC after child-runscape disposal did not evict the
  existing route-capture CWT entry (the pinned ScriptBlock/session-state chain keeps the owner
  runscape reachable), so this slice claims per-runscape scoping and recovery, not collection
  guarantees. Validation: seams 56/0 after one re-pin (reflection-sensitive count 12660 unchanged;
  digest `aea11a7f…` → `343ec71636bbd1b91f0d4989d271559badb5cf28ac88bad149894a3ebac0dfcc` because
  the C# here-string edit shifts site positions), parse gate 156 files, build 7/15/7, secret scan
  clean (835 hints), `git diff --check`, and a sync DryRun with a fresh external plan path (29
  additions, zero modified/removed/unknown, `.system` preserved, no live change; plan-file SHA-256
  `44ef6692064762be975310d9a73864532e828214ba101ee08322af666a00ac54`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `2e5fc36a843481532af00606a3cb98f31e908e702b4ea1ceb309ccd6c15867dd`, with hard-kill 318/0, seams
  56/0, and root-claims 442/0 inside the run. Task 1 remains 1/6
  and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 observation caller/cleanup ledger (2026-09-01): the Step 2 named deliverable is
  production-defined as an additive sealed building block. `scripts/root-claims-registry-common.ps1`
  gains the CLR `SealedHeldObservationCleanupLedger`, five issuer lifecycle statics, and five
  reviewed facade functions (`Open-SealedHeldObservationCleanupLedger`,
  `Register-SealedHeldObservationCleanupLedgerObservation`, `Assert-SealedHeldObservationCleanupLedger`,
  `Close-SealedHeldObservationCleanupLedgerObservation`, `Close-SealedHeldObservationCleanupLedger`).
  The ledger binds to its owner runscape's live issuer definition (provenance token, definition
  digest, runscape instance id), registers only genuine receipt-bound OPEN observations as single-use
  entries, refuses ledger close while any entry is OPEN, releases each entry's observation through
  the exact reviewed `CloseObservationExact` route before committing the entry, and closes
  single-use and idempotently. Cross-runscape and clone provenance attacks fail closed. The
  observation's public Open/Assert/Close APIs retain zero production callers (the ledger closes
  through the issuer internal static route); the ledger itself has zero production consumers and
  grants no mutation authority. Focused root-claims passed 480 assertions with exit code 0 (442
  before; the issuer surface freeze now pins the ten reviewed statics and the selector enumeration
  covers the five new functions), and seams passed 56/0 after deliberate re-pin (five new invocation
  rows, five owner-binding rows, reflection count 12660 → 12682, digest →
  `374b019e0e591b913d647e99d0f6c765bceb14aebe4fb77ecdcbb016819a4dd8`, dynamic-command digest
  unchanged). Gates: parse 156 files, build 7/15/7, secret scan clean (837 hints), `git diff
  --check`, sync DryRun with a fresh external plan path (no live change; plan-file SHA-256
  `f880cf5f6778e45ec397f043d411ec152b4c457bf8700b4693afca5e67744c82`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `3e2274593188ed79fde14be647410093e0606246302ff12aa51ff902c7252512`, with hard-kill 318/0, seams
  56/0, and root-claims 480/0 inside the run. Task 1 remains 1/6
  and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 live-set receiver-backing (2026-09-01): the live-set member of the
  receiver/raw-return blocker is closed. `Open-SealedHeldLiveTargetContextSet` now requires a
  caller-owned `SealedOwnershipTransferReceiver` and delivers only through exact ownership transfer;
  the raw success-stream return branch is removed. Production was already receiver-based (the
  pinned route-capture live-set open core passes the receiver and asserts zero output), and the
  open-failure cleanup path — including a `PipelineStoppedException` before delivery — is
  unchanged. The three raw-branch test call sites converted to receiver style (the pipeline-retention
  probe now proves receiver durability), and new assertions pin the exact four-parameter
  mandatory-receiver contract and reject receiver-less invocation. Focused root-claims passed 482
  assertions with exit code 0 (480 before); seams passed 56/0 without baseline change (no
  inventoried member, type, or literal text changed). Gates: parse 156 files, build 7/15/7, secret
  scan clean (841 hints), `git diff --check`, sync DryRun with a fresh external plan path (no live
  change; plan-file SHA-256
  `dda9dcff69c1b6da4575f020c05ab6549105fb5003e454680198e685ddef08ab`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `57066efaac18f9a8b849eee852a6fc58721c7f90b1f31c2fc0ed0136229a634f`, with hard-kill 318/0, seams
  56/0, and root-claims 482/0 inside the run. Task 1 remains 1/6
  and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 target-lease receiver-backing (2026-09-02): the target-lease member of the
  receiver/raw-return blocker is closed. `Open-SealedHeldTargetContextLease` now requires a
  caller-owned receiver and delivers only through exact ownership transfer; the raw success-stream
  return branch is removed. Production was already receiver-based, and the open-failure cleanup
  path — including `PipelineStoppedException` before delivery — is unchanged. Because
  `target-context-common.ps1` is hard-kill-sealed, the full reviewed-load re-pin was performed to a
  fixpoint with an out-of-repository probe: manifest hash `d777c1c4…` →
  `a3a585b0f957f943d9a36959e304247abc8a9208c6799885cac9b3dd548d348c` (both sites), the 24-row
  actual-prelude block and digest (now
  `77d3145dbb8df1bcdf17e90c809ff34798e40803f9206ca6af1c5930dca3cf81`, four occurrences), the
  27-statement pre-section region digest (`0317b628…`), the transport-contract and mutations
  function pins, function-inventory, cleanup-gate self, main-try execution, top-level execution, and
  the whole-file controller surface digest. Final hard-kill file SHA-256
  `27da95165a92b253fea5714111cd680e8e46865f46e0d363ddccf2f7a25bda63`. The probe confirmed the
  documented hyphen leak in the historical function-pin regex (`[A-Za-z0-9]+` misses hyphenated
  names) and re-pinned through the corrected `[A-Za-z0-9-]+` loop; no suite assertion was weakened.
  All six raw-branch test call sites converted to receiver style with post-state semantics
  preserved; two new assertions pin the mandatory-receiver contract and reject receiver-less
  invocation. Validation: complete standalone hard-kill 318/0 (primitives 95/0 fast signal),
  path-safety PASS, focused root-claims 484 assertions exit 0 (482 before), seams 56/0 without
  baseline change, parse gate 156 files, build 7/15/7, secret scan clean (843 hints),
  `git diff --check`, sync DryRun with a fresh external plan path (no live change; plan-file SHA-256
  `2f89fafb31f933301d26c70c40c9161e9898581cc461e3ba566b07eae1bdc759`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run for this slice is still pending. Task 1 remains 1/6
  and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 safe-existing containment receiver-backing (2026-09-02): the safe-existing member
  of the receiver/raw-return blocker is closed.
  `Open-SafeExistingDirectoryContainmentChain` now requires a caller-owned receiver and delivers the
  held handle chain through exact ownership transfer only; the raw `return ,$handles` branch is
  removed. All six production call sites converted to the two-line receiver pattern across
  `safe-tree-walker.ps1` (entry-marker lookup, create-new copy path), `approved-runner-common.ps1`,
  `canonical-mutation-common.ps1`, and `transaction-journal-common.ps1` (journal-parent,
  worktree-root); `GetDeliveredExact` returns the identical list instance, so indexing, close, and
  finally semantics are unchanged. The three hard-kill-sealed scripts required the full reviewed-load
  re-pin to a fixpoint via the generalized N-manifest probe (manifest hashes `safe-tree-walker` →
  `0c902469…`, `canonical-mutation-common` → `70ee83e0…`, `transaction-journal-common` →
  `77594bf5…`, both sites each; prelude block+digest `ce6416f2…`; pre-section `dba2c033…`; function
  pins; inventory; self; main-try; top-execution; surface). Final hard-kill file SHA-256
  `4766228f652c99aa0728ba4e02913b43ca4775eb0644505d57260cbd5091c9ae`. The production closure
  contract (67/131/`b15898c8…`) passed unchanged, confirming boundary-function body edits stay
  outside the closure digest. Validation: primitives 95/0, full hard-kill 318/0, approved-runner,
  mutation-blockers, transaction-journal-exact-byte, and path-safety all PASS, seams 56/0 after one
  reflection re-pin (count 12682 → 12694, digest `77ec47b4…`), parse gate 156 files, build 7/15/7,
  secret scan clean (845 hints), diff-check, sync DryRun without live change (plan-file SHA-256
  `311b3e9325a072125952361bf0b1d144b46d4c1c10b1f27b551f714fb5e11fde`, deleted after the run). The
  unified run started for `48a30ae` was killed externally at suite 5/34 with no published result
  (session-restore process loss), so one definitive unified run executes after this commit covering
  both `48a30ae` and this slice; every affected suite has passed standalone. The definitive combined
  create-new unified run then passed all 34 discovered suites exactly once with zero failures,
  timeouts, duplicates, missing suites, or tree-kill failures (external summary SHA-256
  `20b522730ef2e034d3f9467ea9023d450999ba1b7baad71d523885813304753f`), with hard-kill 318/0, seams
  56/0, root-claims 484/0, approved-runner 45/0, and transaction-journal-exact-byte 12/0 inside the
  run. Task 1 remains 1/6 and
  Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 plain containment-chain receiver-backing (2026-09-02): the largest member of the
  receiver/raw-return blocker is closed. `Open-SafeDirectoryContainmentChain` now requires a
  caller-owned receiver and delivers only through exact ownership transfer; the raw return branch is
  removed. All thirty production call sites across nine scripts and the real test call sites across
  eleven files (including the hard-kill `HardKillBehaviorAcquire` delegate scriptblock and its
  fingerprint pin, and the sealed canonical-hard-kill-host helper) converted to the two-line
  receiver pattern with identical downstream semantics. The re-pin surfaced two new self-seal pin
  classes — the two pre-section section-owner IF-statement token hashes (primitives owner →
  `a5c1391c…`) and the preimage provenance `allowedMembers` whitelist now admitting the reviewed
  `GetDeliveredExact` — beyond the established ten. Final hard-kill file SHA-256
  `cb2cc1cf4e0e5ab887bd4795b901a63ab9fd813398f2010af972f811000db40a`; closure contract 67/131/
  `b15898c8…` unchanged. Validation: primitives 95/0, full hard-kill 318/0, nine affected suites
  PASS, seams 56/0 after one reflection re-pin (count 12694 → 12756, digest `7679a8a5…`), parse 156
  files, build 7/15/7, secret scan clean (847 hints), diff-check, sync DryRun without live change
  (plan-file SHA-256
  `25aa688305faeb4119c00bfd92626f1b1bc3e1c676611ff4caa8a234e1ac2a67`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures (external summary
  SHA-256 `893a9fd46c97c89105a7322e88461283a8e68be1143b10b36c44139f7074a33e`), with hard-kill 318/0,
  seams 56/0, root-claims 484/0, and home-authority 190/0 inside the run. With this slice the
  safe-existing, target-lease, live-set, and plain containment-chain raw-return branches are all
  receiver-backed; only the retained-traversal composite remains open. Task 1 remains 1/6 and Phase
  2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 retained-traversal receiver-backing (2026-09-02): the last raw success-stream
  branch in the sealed registry's resource chain is closed. `safe-tree-walker.ps1` gains the sealed
  wrapper `Open-SafeTreeRetainedTraversal` (mandatory caller-owned receiver, exact ownership
  transfer of the snapshot-plus-retained-handles composite, failure cleanup in finally), and all
  three production consumers (`Copy-SafeTree`, `New-CommittedDataSnapshot`,
  `Get-CanonicalRetainedDirectoryObservation`) open through its receiver; the raw
  `Get-SafeTreeSnapshotInternal -RetainContainmentHandles` path is no longer production-reachable.
  Hard-kill re-pin: manifest hashes (`canonical-mutation-common` → `9b77a0a3…`,
  `safe-tree-walker` → `e040c417…`), the self-seal fixpoint, and the production-closure contract
  whose referenced boundary set changed by exactly one member — `Get-SafeTreeSnapshotInternal`
  dropped out (its only closure-reachable caller now routes through the wrapper) while
  `Open-SafeTreeRetainedTraversal` entered with the identical `ShouldSkipEntry` ParameterAst digest
  `c341358e…`; 67/131/13 counts unchanged, closure digest now
  `a719c9cb940a98e091941ef079e317f0f28b6e4f66d7a9f513b5232933ab2d9c` (contract baseline and
  cleanup-gate assertion), verified first by an out-of-repository closure diagnostic. Final
  hard-kill file SHA-256
  `45c88d9fedf7a61ad0fe410f851b2bd03207176766d4a40c0ccdbb0b5c29bfc9`. The mutation-blockers static
  assertion now requires the retained-observation route through the wrapper with no direct
  `RetainContainmentHandles` reference; seams re-pinned deliberately (closure + exception inventory
  rows with `ScriptBlockParameter` digest `ad9aa49e…`, reflection count 12756 → 12768, digest
  `7c88fdec06bd95d47c49a8f9a30e6977caad3230b1ab8c465cb3f46570860437`) and passed 56/0.
  Validation: primitives 95/0 after the closure-baseline fix, complete hard-kill 318/0,
  mutation-blockers 32/0, recovery 104/0, skills-import 42/0, root-claims 484 assertions exit 0,
  parse 156 files, build 7/15/7, secret scan clean (851 hints), diff-check, sync DryRun without
  live change (plan-file SHA-256
  `74853edddd106b47106b6a8fdf5de7496121a1c05c72a86cb49b9dbe781ad209`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `d9fab280ff76df72b8b1507e96378583e9abce5671678c718834037c5b5a0f39`, with hard-kill 318/0, seams
  56/0, root-claims 484/0, mutation-blockers 32/0, recovery 104/0, and skills-import 42/0 inside
  the run. With this slice all
  receiver/raw-return branches in the sealed registry's resource chain are receiver-backed. Task 1
  remains 1/6 and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 target/live reader-close blocking (2026-09-02): both held receipt classes
  (target-lease and live-set) gained a lifecycle gate with an active-reader counter and public
  `BeginReadExact`/`EndReadExact`; both `Assert` functions hold the read for their whole
  revalidation, and both release paths restore `OPEN` and throw `target-context-close-active` when
  a reader is active. Closed receipts refuse new readers; unbalanced releases fail closed; close
  remains single-use and idempotent; the live-set cascade reaches its three nested leases only
  after the set-level reader releases. `target-context-common.ps1` required the manifest re-pin
  plus the self-seal fixpoint (final hard-kill file SHA-256
  `34f244cb0e84a27aa44e2fe764c0fcc706478a35bdf260a860cee37fa031c329`; target-context-common
  `5fc1433e7187aa9a3da0efbf7301f8ace4e2a42cccdebe2ab1dda8ba4eb973d5`); `live-target-context.ps1`
  is not hard-kill-sealed. Tests: target and live lifecycle blocks plus a real-concurrency
  orchestration (child-runscape `Assert` blocked on its first evidence re-read; the main runscape's
  concurrent close is rejected `target-context-close-active` with the lease OPEN; after release the
  assert completes and the caller closes) — focused root-claims reached 498 PASS with exit code 0
  (484 before). Seams re-pinned only the reflection inventory (12768 → 12772, digest
  `7f867f39…`) and passed 56/0. Validation: primitives 95/0, complete hard-kill 318/0, parse 156
  files, build 7/15/7, secret scan clean (853 hints), diff-check, sync DryRun without live change
  (plan-file SHA-256
  `d5dc1a2c38c94aedf351175e6a47f28482c0d0ba263c0d1fa4c4fd9318af9578`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `2ff091391f1be4fe8e9c65c83f408d33a29cc96b43c75f97a78f136e8fe301d5`, with hard-kill 318/0, seams
  56/0, and root-claims 498/0 inside the run. Task 1 remains 1/6
  and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 raw-getter capability stripping (2026-09-02): the closure survey confirmed every
  transitive-close path in the observation chain is already complete and located the real exposure
  in the facade getters that handed out the route-capture-owned live-set wrapper and receipt.
  `GetLiveSetLeaseExact`/`GetLiveSetReceiptExact` keep their reviewed names and now return the
  capability-stripped `SealedHeldLiveSetBorrowedStateProjection` (CloseState, IsClosed,
  TargetLeaseCloseStates) built through a private cross-assembly exact-reflection helper; the two
  production identity checks read the new internal field accessors; `GetCurrentRouteCaptureExact`
  and the caller-owned getters stay raw by design. The 27-name facade freeze is untouched. Tests:
  both projections reflect the open live set, the projection cannot close the borrowed set
  (receipt-missing stale), and the receipt projection exposes no nested leases — focused
  root-claims 501 PASS exit 0 (498 before). Seams re-pinned only the reflection digest (count
  12772 unchanged, `192eefa2…`) and passed 56/0; no edited file is hard-kill-sealed. Gates: parse
  156 files, build 7/15/7, secret scan clean (855 hints), diff-check, sync DryRun without live
  change (plan-file SHA-256
  `0f8bf1a4e95b1ff95daab244140d9b825e2c990d044132f39f247f6e62af92ad`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `c2a35eb71dfa9ec0e83a695d5aaeffe22d09a4d033df5229800dc2a4b4d29338`, with hard-kill 318/0, seams
  56/0, and root-claims 501/0 inside the run. Task 1 remains 1/6
  and Phase 2 remains 1/52; production Apply remains interlocked.

- Provider-token debt closure assessment (2026-09-02): the "computed provider-path dataflow and a
  literal-provider-token static false positive" sub-debt is already covered by shipped work — the
  seams suite scans literal `Alias:`/`Function:` drive tokens and drive-qualified variable forms
  with mutation-RED acceptance tests, declares computed-path data flow out of scope as a deliberate
  design boundary, and reports zero false positives at 56/0. No code change was needed. The
  remaining open Step 2 sub-debts are the opaque bare lease wrappers, the durable recovery ticket
  when route cleanup itself fails, and wiring the cleanup ledger as the reviewed observation
  lifecycle owner.

- Phase 2 Task 1 bare-lease wrapper de-mirroring (2026-09-02): the mutable `IsClosed` NoteProperty
  is removed from both target-lease and live-set wrappers (constructor line and post-close mirror
  block), after a reader census proved zero production or test readers of that property on those
  wrappers — the bound receipt CWT is now the single close-state truth for every route-capture
  collection wrapper, eliminating the drift/forge channel. The fixed-envelope lease's own
  authoritative `IsClosed` (no receipt there) is deliberately untouched as a separate follow-up. A
  new assertion pins the absence of the display on a closed wrapper. Hard-kill manifest re-pin plus
  the self-seal fixpoint (final hard-kill file SHA-256
  `4c84e4a89f9a11b40338e50743a0e42a1824fca61bc822573d8d053d5923320e`); seams reflection inventory
  12772 → 12754 (digest `45f42c81…`), 56/0. Validation: primitives 95/0, complete hard-kill 318/0,
  root-claims 502 assertions exit 0 (501 before), path-safety PASS, parse 156 files, build 7/15/7,
  secret scan clean (862 hints), diff-check, sync DryRun without live change (plan-file SHA-256
  `669bbeb39ffdadcc860ded307e5cce66cb1e4a3c4a4dc17c92c6c0fbd605a148`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `48ef95c84061f511da22a3e6ca32b681c67e99884431d86d7ca90bdfacc45076`, with hard-kill 318/0, seams
  56/0, root-claims 502/0, and path-safety 43/0 inside the run. Task 1 remains 1/6
  and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 envelope close-state CWT-ization (2026-09-02): the fixed-envelope lease's
  authoritative close state moved into the new `SealedHomeAuthorityFixedEnvelopeCloseState`
  conditional-weak-table class (volatile-backed reads; unbound objects read open, mark no-op),
  replacing the spoofable `IsClosed` NoteProperty at both construction sites, the raw close
  idempotence gate and write, the projection invalidation check, the observation owned-close and
  force-close paths, and the open-path validation. An independent Grok review caught a P0 layering
  defect pre-commit (the class initially lived above the standalone-dot-sourced HA layer); it moved
  into `home-authority-common.ps1`'s own guarded `Add-Type` with the observation side reaching it
  through cross-assembly exact reflection, and the review's P2s were adopted (volatile reads,
  early `BindExact` before the initial projection, two anti-forgery assertions). The pinned issuer
  snapshot ScriptBlocks keep the old shape by design (digest identity pins, never dispatched).
  Validation: home-authority PASS, live-concurrency PASS, root-claims 504 assertions exit 0 (502
  before), seams 56/0 after baseline re-pin (12753 → 12755, `41c54b74…`), complete hard-kill 318/0,
  path-safety PASS, parse 156 files, build 7/15/7, secret scan clean (864 hints), diff-check, sync
  DryRun without live change (plan-file SHA-256
  `44fee4cadf291bbdd3ec50107694ab0eb2e5babfbd6bc589755d454f24b4b0cb`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `fe57091678b947bd8424a799cf738dba316177af24689bd15847747d740f45f6`, with hard-kill 318/0, seams
  56/0, and root-claims 504/0 inside the run. Task 1 remains 1/6
  and Phase 2 remains 1/52; production Apply remains interlocked.

- Execution state (2026-09-02, parallel batch): staging locks rebuilt fresh (three environments
  built+valid against current HEAD, harness-env regression 126/0, working tree clean, no interlock
  impact). **Superseded:** those locks are stale again (last rebuilt on 2026-09-13; HEAD has since
  moved). External design batch under the Grok/Luna/main-agent routing rule produced the durable
  recovery ticket design, the ledger-wiring owner-trio design, and the ticket test-block draft;
  the main-agent correction requires `route-cleanup-recovery` to join the envelope
  `ControlBase` children whitelist in the same commit as ticket publication. Remaining queue:
  slice 1 (ticket), slice A (wiring), slice B (failure matrix), then the resolver consumer layer,
  `PrivateRootBootstrapIntent`, protocol-v1 dispatch, and the forbidden-root matrix.
  **Superseded:** every slice in this remaining queue was implemented in Phase 2 (closed
  2026-09-13).

- Phase 2 Task 1 slice 1, durable recovery ticket (2026-09-02): `ReleaseExact` failures now publish
  `<ControlBase>\route-cleanup-recovery\<CaptureId>\ticket.json` atomically (immutable descriptor
  snapshotted before the first release, per-lease attempt/close states, ContentHash, seven
  `DurableRecoveryTicket*` Data keys, publish errors never shadowing the primary), with read-only
  discovery and the envelope `ControlBase` children check moved to allow-list + required-set form
  (sidecar optional, original four required) plus the matching bootstrap-snapshot extra. Discovery
  is discoverability only; interpretation/consumption/retry stay with Task 4. An independent
  full-access Grok review found and fixed a real production defect in the new discovery facade
  (boolean-to-string cast made every valid ticket skipped) and verified the focused suite. A
  read-only Grok pre-commit review raised three defects, all adopted: the identity-collision branch
  was fail-open (now a per-field needle match over every immutable identity field, mismatch failing
  closed), the recovery descriptor was snapshotted after the closing CAS (now before the CAS, a
  snapshot failure leaving the capture OPEN), and the rename-hold gate had no timeout (now 60 s,
  then best-effort temp deletion and a `failed` publish). Validation: focused root-claims 529 PASS
  exit 0 re-verified after the fixes (504 before), complete hard-kill 318/0, home-authority PASS,
  path-safety PASS, seams 56/0 after reflection re-pin (12755 \u2192 12773, digest after the fixes
  `740f1171\u2026`), parse 156 files, build 7/15/7, secret scan clean (868 hints), diff-check, sync
  DryRun without live change (plan-file SHA-256
  `27ed96397e770916f860a29b61ab2b28914b0d8b192e3111bfd13cb958967ef4`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `d403207ade1a8728a434f3ebc11d9eea7e0118420573c4876d2a5dee6ea24c8a`, with hard-kill 318/0, seams
  56/0, root-claims 529/0, home-authority 190/0, and path-safety 43/0 inside the run. Task 1
  remains 1/6 and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task 1 slice A, ledger wiring (2026-09-03): the cleanup ledger is wired as the reviewed
  observation lifecycle owner via the new `Open-/Assert-/Close-SealedHeldObservationLifecycle`
  trio — dual caller receivers, private-receiver open/register/dual-assert before delivery, a
  complete failure matrix (registered observations close through the ledger entry route;
  unregistered ones through exactly one issuer `CloseObservationExact`; empty or entry-settled
  ledgers close; cleanup errors ride `SealedHeldObservationLifecycleCleanupError`), and — per the
  pre-commit review — unconditional ledger closure once the entry obligation is settled so a
  half-delivery can no longer leak an OPEN ledger to the caller. The observation `Close-` facade
  keeps zero production callers; the observation `Open-/Assert-` facades and the five ledger
  facades have exactly one reviewed production caller each, enforced by the rewritten seams
  boundary (per-facade allowed-caller inventories, owner inventory assertions, trio unique
  definitions, issuer invocation +1, owner-binding digest
  `451449d7df35a1950c099aa0da20dc18aeaf9258666ae93ead06900e7795df17`). `MutationAuthorization=NONE`
  unchanged; no resolver/dispatcher/registry/Apply/rollback/mutation consumer; the four production
  roots' closure untouched. Validation: focused root-claims 546 PASS exit 0 (529 before,
  re-verified after the review fix), complete hard-kill 318/0, home-authority PASS, path-safety
  PASS, seams 56/0 after re-pins (reflection 12773 → 12809, `2d7eb352…`), parse 156 files, build
  7/15/7, secret scan clean (869 hints), diff-check, sync DryRun without live change (plan-file
  SHA-256 `59b30f633a4b61e9a4bb8e23a877ae8ca7b5782e59ea4b90c46e279d83891006`, deleted after the
  run). The definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly
  once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `d8f6ef0e1bf3d359214db79c0844f806bff71bd89f2284a052b7c44818517189`, with hard-kill 318/0, seams
  56/0, and root-claims 546/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52;
  production Apply remains interlocked.

- Phase 2 Task 1 slice B, lifecycle owner failure matrix (2026-09-03): five failure paths pinned as
  suite-style regressions (the Luna Pester-style draft rewritten against the trio's actual
  interface): register failure delivers nothing and propagates; assert failure surfaces as the
  observation stale error while ledger/entry/observation stay OPEN and retryable; entry-close
  failure restores the observation OPEN, keeps entry and ledger OPEN, propagates, and refuses the
  ledger close; no `LiveTransactionsRoot` children and no `SealedRegistryRouteCleanupError` Data key
  on entry-close failure. Focused root-claims 556 PASS exit 0 (546 before). No production file
  changed; seams 56/0 unchanged; parse 156 files, build 7/15/7, secret scan clean (872 hints),
  diff-check, sync DryRun without live change (plan-file SHA-256
  `22fc7c597f1984801997cbcef2e0099e6325e03554b5ef6404da8152d36a49c1`, deleted after the run). The
  definitive unified `run-tests.ps1 -All` run then passed all 34 discovered suites exactly once with
  zero failures, timeouts, duplicates, missing suites, or tree-kill failures; its external
  create-new summary SHA-256 is
  `a7040d09f35de17d56911e4fedff4bd8d83dfee95826ea3312ba58d4e6893aae`, with hard-kill 318/0, seams
  56/0, and root-claims 556/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52;
  production Apply remains interlocked.

- Resolver-prereq survey (2026-09-03, Luna + main-agent): `PrivateRootBootstrapIntent` carries two
  shipped layers — the canonical plan's reduced intent (schema + implementation complete) and the
  sealed home-authority full intent (implementation complete, test-adapter-driven) — with no
  production adapter between them. Seven gaps to resolver-consumer wiring documented (production
  context-to-full-intent conversion, hash binding across layers, lock-internal recapture, ordered
  sequence, trio as sole caller, ticket boundary, protocol-v1/forbidden-root gates). Next
  implementable sub-slice: production `AuthorityContext`-to-full-intent conversion replacing the
  adapter-only restriction.

- Task-2 close-out (2026-09-03): working tree clean at `f25513d`, no code changes this round.
  The 21:34 SetupIntentHash Grok call failed as `grok-exit-code--1` (slow first token + caller
  abandonment, not an outage); session `01a0677a-…14655` verified intact but produced no blueprint
  file — rerun `tmp/grok-setupintent-impl-prompt.txt` after the directory lock clears. Luna's
  PrivateRootBootstrapIntent survey landed (146 lines, conclusions committed in `f25513d`); the
  whitelist coupling is already inside `3228a6b`. Resume order: (1) SetupIntentHash blueprint
  rerun + sub-slice, (2) AuthorityContext-to-full-intent conversion, (3) hash binding, (4)
  resolver consumer layer, (5) `PrivateRootBootstrapIntent`, (6) protocol-v1, (7) forbidden-root
  matrix.

- Phase 2 Task-2 slice 1, SetupIntentHash precompute functions (2026-09-04):
  `scripts/canonical-transaction-common.ps1` gains four pure-computation functions wired into
  `New-CanonicalSetupPlanPayload` with zero behavior change — `Get-CanonicalSetupIntentKeyNames`
  (dictionary-compatible key enumeration), `Assert-CanonicalSetupIntentRootContext` (the schema rootContext oneOf
  state machine, 15-key exact set), `Get-CanonicalSetupIntentHash` (8-key exact intent set plus
  resolver/SID/hash-shape checks), and `Get-CanonicalExpectedSetupStateProjectionHash` (19-key exact projection set
  with the Apply-derived exclusion table checked before the generic unexpected-field check). No new schema file:
  `PrivateRootBootstrapIntent` and the projection shapes are already covered exactly by `$defs/setupPayload` and
  `$defs/setupStateProjection` in `schemas/canonical-transaction-plan.schema.json`.
  `tests/canonical-transaction.tests.ps1` gains the `[setup intent precompute]` block (10 assertions), focused suite
  55/0. The hard-kill reseal plus the seams reflection re-pin (count 12809 → 12828) were verified value-only.
  Validation: hard-kill primitives 95/0, complete hard-kill 318/0, seams 56/0, transaction 55/0, parse gate 156 files,
  build 7/15/7, secret scan clean, `git diff --check` clean, sync DryRun plan hash unchanged. The definitive unified
  `run-tests.ps1 -All` run passed all 34 suites exactly once (external create-new summary SHA-256
  `445ea5d9a937c4162c5da5f9d53c77b456c4386fef2d1a766ac093790c81236c`). Task 1 remains 1/6 and Phase 2 remains 1/52;
  production Apply remains interlocked.

- Phase 2 Task-2 slice 2, production AuthorityContext-to-full-intent conversion (2026-09-04):
  `Assert-SealedHomeAuthorityBootstrapContext` (`scripts/home-authority-common.ps1`) no longer accepts only the
  `sealed-home-authority-test-adapter-v1` context — a production `windows-token-sid-known-folder-v1` context now
  passes an explicit production topology check (canonical SID shape, non-canonical rejection, current-user binding via
  `sealed-home-authority-bootstrap-token-sid-invalid/-noncanonical/-not-current-user`) before joining the same
  path-derivation validation the adapter used; forged resolver versions still fail closed and no new bypass exists
  because the intent payload already binds `IdentityResolverVersion` into `IntentHash`.
  `tests/home-authority.tests.ps1` gains the `[production bootstrap context conversion]` block (7 assertions;
  real-machine LocalAppData ACLs fail the current-user-only template and are asserted as legal fail-closed). Focused
  home-authority passes; live-concurrency passes with zero adapter-path regression; seams reflection inventory
  re-pinned count 12828 → 12833 with digest re-pin, seams 56/0; parse gate 156 files, build 7/15/7, secret scan clean,
  `git diff --check` clean, sync DryRun unchanged. Focused validation recorded; the definitive unified `run-tests.ps1
  -All` validation for this state was later recorded inside the 2026-09-05 definitive run for commit `28ce839` (see the
  Task-2 slice 4 PR2+PR3 record). Task 1 remains 1/6 and Phase 2 remains 1/52;
  production Apply remains interlocked.

- Phase 2 Task-2 slice 3, cross-layer intent binding (2026-09-05): `scripts/canonical-transaction-common.ps1` gains
  two pure-computation functions binding the canonical reduced intent (`PlanPayload.PrivateRootBootstrapIntent`) to
  the full sealed intent on the stable quantities plan and claim bind — `Get-CanonicalSealedDirectoryTemplateHash`
  (verifies the sealed template's stored `DirectorySecurityTemplateHash` reproduces the full-template hash, requires
  `ResourceKind='Directory'`, strips `ResourceKind`, hashes the remainder) and
  `Assert-CanonicalSealedSetupIntentBinding` (token-SID binding, template-hash binding, remainder-derived
  control/backup path binding, per-root template-anchor consistency, binding-evidence projection; no FS access, fails
  closed on every tampered quantity). `tests/canonical-transaction.tests.ps1` gains the FS-free `[cross-layer intent
  binding]` block (9 assertions), focused suite 64/0. The `tmp/reseal-txn.ps1` N-manifest probe reached fixpoint in
  three iterations with 13 pin updates (final hard-kill file SHA-256
  `ecfc68a0616a2b6afc1407c0642af277dd877f48415c6c6992d21e3207a33aba`), and the seams reflection-sensitive inventory
  re-pinned count 12833 → 12858 with digest re-pin, seams 56/0. Validation: complete hard-kill 318/0, transaction
  64/0, parse gate 156 files, build PASS, secret scan clean, `git diff --check` clean, sync DryRun identical to the
  established baseline with unchanged PlanHash. Focused validation recorded; the definitive unified `run-tests.ps1
  -All` validation for this state was later recorded inside the 2026-09-05 definitive run for commit `28ce839` (see the
  Task-2 slice 4 PR2+PR3 record). Task 1 remains 1/6 and Phase 2 remains 1/52;
  production Apply remains interlocked.

- Phase 2 Task-2 slice 4 PR1, resolver observation unique caller (2026-09-05, commit `b6d6353`): implemented per the
  Grok resolver consumer design (four review rounds, `tmp/grok-resolver-consumer-design.md`). `scripts/root-claims-registry-common.ps1`
  gains `Open-/Assert-/Close-SealedHeldResolverObservation` — the first production consumer of the observation lifecycle
  trio, with `MutationAuthorization=NONE`: bootstrap OpenExisting after a COMPLETE seven-entry prefix check
  (`home-authority-bootstrap-incomplete` otherwise; `Complete-SealedHomeAuthorityBootstrap` never called), existing-only
  global lock bound to the mandatory caller-held canonical witness, slice-3 `Assert-CanonicalSealedSetupIntentBinding`
  consumed under both locks, in-lock BLOCK on any valid `route-cleanup-recovery` ticket
  (`sealed-held-resolver-unhandled-route-cleanup-recovery`, Data limited to count + CaptureId GUID list), no-follow
  current-route recapture, and the lifecycle trio opened on private receivers, delivering one typed eleven-property
  handle. Open failure cleanup closes trio → route → locks tail-to-head and never releases locks while an entry or
  route stays OPEN; `Assert-` revalidates handle, bootstrap owner, intent, trio, route, and binding; `Close-` is a
  retryable state machine whose CLOSED no-op gate requires the inner objects and both lock owners released, never the
  NoteProperty alone. Seams rewrites the trio boundary to this unique owner (trio Close also allowed from resolver Open
  failure cleanup), pins the resolver trio at zero production callers and unique registry-top definitions, and re-pins
  the reflection-sensitive inventory (count 12858 → 12955, digest `70356ed7…`). `tests/root-claims-registry.tests.ps1`
  extends selector rejections, pins the exact parameter set, and adds the independent-fixture success path and the
  ticket-BLOCK failure path. No hard-kill reseal (canonical-transaction-common.ps1 unchanged; four-root closure
  untouched). Validation: focused registry suite exit 0 with 583 PASS lines and clean temp cleanup; seams 56/0;
  complete hard-kill 318/0 on a quiet re-run (one earlier run had 14 environment-flaky fixture-delete failures that
  did not reproduce and are recorded as non-code); parse gate, build 7/15/7, secret scan clean (907 hints),
  `git diff --check` clean, sync DryRun identical to the established baseline with unchanged PlanHash and the plan
  deleted after the run. The definitive unified `run-tests.ps1 -All` run executed after the PR2/PR3 test slices
  landed and is recorded in the PR2+PR3 record below. Task 1 remains 1/6 and Phase 2 remains 1/52; production Apply
  remains interlocked.

- Phase 2 Task-2 slice 4 PR2+PR3, resolver observation failure matrix, close state, and contention (2026-09-05, commit
  `28ce839`): tests-only slice from the Grok implementation draft, completed by the main agent after the Grok session
  was lost mid-verification. `tests/root-claims-registry.tests.ps1` gains shared independent-fixture adapter helpers and
  three blocks: the failure matrix (forged context `sealed-home-authority-bootstrap-context-required`; incomplete prefix
  via removal of the final global-lock entry firing the pre-lock `home-authority-bootstrap-incomplete` with zero
  re-creation and an unchanged tree hash, because `New-CanonicalFinalSetupState` requires existing private roots;
  SetupIntent OwnerSid mismatch `canonical-sealed-intent-token-sid-mismatch` with both locks released; in-lock
  recapture identity drift), the close-state machine (entry-close and route-close injection failures keeping CloseState
  OPEN with the route open and both lock wrappers held and a successful retry after removal; a forged `CLOSED`
  NoteProperty ignored while the observation is live; the canonical-early-release strand pinning `dependent-lock-active`
  on the canonical repo lock itself with bootstrap, global, and the canonical lock held until process exit and recorded
  as expected stranded residue), and the real contention probe (child-runscape Open loses `operation-lock-busy` under
  one second with an empty receiver and re-enters the global lock after the parent Close). The final cleanup gate mutes
  only the canonical-early fixture's own stranded lock paths. No production file changed, so no seams or hard-kill
  re-pin was required. Validation: full registry suite exit 0 with 614 PASS lines (583 before), seams 56/0 unchanged,
  `git diff --check` clean. The definitive unified `run-tests.ps1 -All` run for commit `28ce839` then discovered,
  started, completed, and passed all 34 suites exactly once with zero failures, timeouts, duplicates, missing suites,
  or tree-kill failures (external create-new summary SHA-256
  `5b42e119b72cb9fa91b6795da75a081415636344562ec283fdd1ff77be522474`), with hard-kill 318/0, seams 56/0, and
  transaction 64/0 inside the run; it is also the recorded unified validation for Task-2 slices 2 and 3. Task 1 remains
  1/6 and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task-2 slice 5, `PrivateRootBootstrapIntent` completion primitives (2026-09-05, commits `2bd40a6` + `fc039a9`):
  implemented per the Grok completion design (two review rounds) with the interlock untouched — completion stays a
  setup-Apply component covered by `canonical-apply-interlocked` and both primitives keep zero production callers.
  PR1: `Register-SealedHeldHomeAuthorityCanonicalGlobalBinding` in `scripts/home-authority-common.ps1` binds an
  already-held global to a live canonical witness (already-bound refusal `canonical-global-order-binding-already-present`,
  envelope re-projection with `-HeldGlobalLock`, CreateNew `FixedEnvelopeHash` supply or OpenExisting verification, the
  Enter-equivalent `ClaimForBindingExact`/`BindExact` sequence, fail-closed without exiting the global);
  `Complete-SealedHomeAuthorityBootstrap` and `Enter` unchanged. HA `[canonical-bound bind after complete]` block covers
  CreateNew, refusal, and OpenExisting on the test binding witness stub with the canonical lock acquired before every
  global acquisition; seams re-pin 12955 -> 12978 (`137134fb...`). PR2+PR3: `Complete-SealedHeldCanonicalRecoveryRootRemainder`
  and `Complete-SealedHeldCanonicalPrivateRootBootstrap` in `scripts/root-claims-registry-common.ps1` consume the slice-3
  binding and the plan payload graph before any create, complete the seven-entry prefix through the unchanged
  `Complete-SealedHomeAuthorityBootstrap`, create or validate the recovery-root remainder under the still-held unbound
  global with the sealed directory template (plan-MISSING roots may already exist; plan-EXISTS roots must exist;
  remainder-collision and manual-recovery fail-closed), compute the in-memory final setup state, and return a
  thirteen-property typed result with unbound global and `Durable*Write='deferred'`. Seams pins Complete and the
  remainder to the composer as unique production callers, the composer and Register at zero external production
  callers, all three definitions uniquely, and re-pins the reflection inventory (12978 -> 13057, `91b47e9c...`). Registry
  tests gain the success path, binding/payload-graph zero-creation failures, selector and parameter-shape rejections,
  exact partial-prefix resume with identity preservation, the idempotent COMPLETE variant, the drifted-ACL manual gate,
  and the child-runscape `operation-lock-busy` contention probe. No hard-kill reseal. Validation: full registry suite
  exit 0 with 642 PASS lines (614 before), seams 56/0, home-authority and live-concurrency PASS, diff-check and parse
  gate clean.

- Phase 2 Task-2 slice 5 review hardening (2026-09-05, commit `43fa08a`): the independent Grok review (diffs inlined,
  plan-mode terminal commands disabled after two cancelled attempts) returned three majors, all adopted — the composer
  pins `projection.CanonicalRecoveryRoot` to the sealed intent's recovery path before any create
  (`canonical-private-root-completion-recovery-path-mismatch`); the remainder validates the plan-EXISTS/plan-MISSING
  matrix with directory-type and named-stream checks and wraps all validation failures into
  `canonical-recovery-root-manual-recovery-required` with the innermost message; the registry tests gain the remainder
  fail-closed block (missing planned root, file at root, named stream, drifted DACL) and the remainder parameter-shape
  freeze; seams re-pin 13057 → 13077 (`7fdcb874…`). Recorded deviations: the OwnerSid binding negative is unreachable
  (the payload-graph template check precedes the binding) so the control-path variant pins that boundary; the
  durable-claim-absent surface is covered by the final reviewed-prefix snapshot; resolver COMPLETE-only is already
  pinned by the slice-4 incomplete block. Validation: registry suite exit 0 with 646 PASS lines, seams 56/0,
  diff-check clean. The definitive unified `run-tests.ps1 -All` run for commit `43fa08a` then passed all 34 suites
  exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures (external create-new
  summary SHA-256
  `248319e3823b79d96b1faddb905ecb52227e749a6db0db4f23ca071eab88977c`), with hard-kill 318/0 and seams 56/0 inside the
  run. Task 1 remains 1/6 and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task-2 item (6) resolution, protocol-v1 public dispatch (2026-09-06): surveyed and designed by Grok
  (evidence report `tmp/grok-protocolv1-design.md`, one review round, zero open issues) with the conclusion
  **deferred/blocked — nothing to build**. "Protocol v1 public dispatch" in the design authorities is the locked
  production CLI contract (selector rejections, zero-wait `operation-lock-busy`, Fixed/NTFS, setup Apply journaling
  claim then state, later `live recover`), not a dispatch schema; its only consumers are the interlocked setup Apply
  (D1/D2 already deferred) and the planned Task 6 `live recover` dispatcher blocked on the Task 4 journal. The read-only
  public dispatch already exists and its MetadataOnly contract forbids consuming the resolver; naming axes are separated
  (protocol v1 contract vs `ProtocolVersion=3`/`ReleaseState=interlocked` policy vs artifact `SchemaVersion` vs the
  capability-probe `ProtocolVersion=1` field). Known selector debt (`sync.ps1 -HomeRoot/-BackupRoot` USERPROFILE
  defaults) is plan Task 5 live-host migration work, recorded without being absorbed. No code changed for this item;
  it closes as deferred/blocked pending a legally released interlock.

- Phase 2 Task-2 item (7), claim-accept forbidden-root matrix (2026-09-06, commit `1e6acfc`): implemented per the Grok
  design (review revision 1; session died mid-loop, main agent completed design and implementation). `Assert-SealedProposedClaimsForbiddenRootMatrix`
  in `scripts/root-claims-registry-common.ps1` is the claim-accept gate (plan Task 1 Step 3) with zero production callers
  and `MutationAuthorization=NONE`: 0-or-3 ordered live subjects, M13 path-safety track per subject (HomeRoot equality,
  volume root, `.system`, reparse ancestor, wrapped into `manual-recovery-required`), opponents coerced to no-follow
  TargetContexts (ControlBase/BackupRoot, four witness Git-private paths as disjoint opponents only, PRESENT optional
  root-set rows, non-own reservations), the exact isOwn root-transition contract, subjects-x-subjects and
  subjects-x-opponents disjoint with `forbidden-root-path-overlap`/`forbidden-root-identity-alias` wrapped into
  `manual-recovery-required`, M11 same-parent same-volume staging-sibling with zero-live PRESENT staging failing closed,
  defensive M12 staging-x-RepoRoot, and recovery requiring a witness plus `canonical-recovery-root-cross-volume`
  wrapping. Opponent pairs and source/materialization invariants remain in the current-route gate. Recorded deviation:
  the design's staging-inside-repo M12 negative is unreachable under M11+M2 ordering, so the pair is defensive without
  a dedicated negative. `tests/root-claims-registry.tests.ps1` gains the `[forbidden-root claim-accept matrix]` block
  (default pass with zero writes, custom overlap, contract shapes, pairwise nesting, M13 bans, foreign home and
  recovery reservation overlaps, identical own reservation, root-transition rejection, witnessed-repo live overlap,
  sibling/detached/cross-volume/missing-witness recovery cases, adapter cleanup); seams pins zero production callers,
  unique registry-top definition, and re-pins the reflection inventory (13077 → 13143, `e3292903…`). No hard-kill
  reseal. Validation: full registry suite exit 0 with 672 PASS lines (646 before), seams 56/0, diff-check and parse
  gate clean. The definitive unified `run-tests.ps1 -All` run for commit `1e6acfc` then passed all 34 suites exactly
  once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures (external create-new summary
  SHA-256
  `77374bdd2e9e918b05d10d4f3e7f8225da470035a07567d92def84f61407b924`), with hard-kill 318/0, seams 56/0, and
  transaction 64/0 inside the run. With this slice Task-2 resume items (1)-(7) are all closed ((6) as deferred/blocked
  with evidence). Task 1 remains 1/6 and Phase 2 remains 1/52; production Apply remains interlocked.

- Phase 2 Task-2 close-out, slices 4 (second half) + 5 (2026-09-09, commits `3831fd9` + `0d84edf`):
  implemented directly by the main agent after the Grok quota exhaustion. The public `sync.ps1`
  surface now carries the schema 3 semantic plan face: the pristine-initial and explicit-retirement
  DryRun producers run only inside the internal sandbox (capability plus the three host-injected
  `AI_AGENT_DOTFILES_INTERNAL_{HOME_ROOT,BACKUP_ROOT,CONTROL_BASE}` locators, injected by the
  internal host beside ROOT/PATH/TOKEN and restored in `finally`), fail closed with
  `live-plan-host-resolution-required` and zero plan bytes otherwise, require a create-new
  `-PlanPath` (`live-plan-path-collision` on re-run with the bound materialization preserved), and
  emit through the immutable `Write-LiveSyncPlan`. Pristine initial requires absent live roots and
  an unoccupied control base, materializes named `full` through the single
  `Invoke-HarnessEnvMaterialization` writer beside the plan, and binds the exact lock/build bytes
  and `MaterializationHash`; retirement reads the seeded schema 3 authority state at the canonical
  `<ControlBase>/homes/<HomeAuthorityKey>/current-env.json` locator (exact-byte capture,
  schema- and semantics-validated, never a writer), reuses the reviewed staleness walk with
  unchanged messages, binds the manifest path/bytes plus canonical/generated/current-manifest
  absence evidence and per-platform target tree hashes, rejects a postset target with
  `retirement-selection-conflict`, and emits `explicit-retirement` prune actions. Apply validates
  the reviewed document through the five no-lock steps before the mandatory backup (document
  integrity, current PlanHash from the same pure producer without materialization recreation,
  bound materialization currency, selection context, and the DocumentHash-not-consumed gate with
  an empty injected evidence map); the pristine-initial live-mutation host stays unwired and fails
  closed with `live-plan-initial-apply-not-wired` after full validation, and retirement executes
  its reviewed prunes with the tree-hash gate, mandatory backup, the overwrite-style journal with
  `explicit-retirement` records, and post-apply target/marker verification. Recorded deviation
  from the adopted design: explicitly bound `-HomeRoot`/`-BackupRoot` keep selecting the legacy
  content-aware deploy route (the `activate-harness-env.ps1` Gate 4 contract; the harness-env
  activation regression stayed 140/0) because the roadmap deletes the legacy swap/journal paths
  only in Task 5 Step 1; the direct `live-plan-public-selector-rejected` posture and the "no
  schema 2 emitter residue in sync.ps1" goal are scoped to the public producer face until Task 5.
  Replay protection is staleness recomputation plus the injected `live-plan-consumed` gate; Task 4
  wires journal scanning into step six.
  `tests/sync.tests.ps1` builds the v3 fixture (in-sandbox git repository with copied
  harness-source/manifests/pinned tool locks and placeholder skills counted from the copied `full`
  definition) and covers the pristine-initial producer, the authority-present and collision gates,
  the unwired initial apply, and the full retirement regression (schema plus full semantics,
  OperationKind, envelope hashes, zero hook evidence, `explicit-retirement` authority, state-array
  intent with the reviewed projection match against the seeded state, conflict, manifest
  path/bytes/live-root/content drift rejections before backup, successful prunes with backup and
  journal authority, replay rejection, and the Reasonix override with an exact live-root binding).
  The content-aware dry-run/drift/apply/prune regression moved verbatim to
  `tests/helpers/task5-environment-sync-regression.ps1`, which `sync.tests.ps1` does not invoke
  (reason `task2-pristine-initial-only-pending-environment-producer`);
  `schemas/sync-plan.v2-live-compat.schema.json` is deleted; `tests/live-plan.tests.ps1` pins the
  producer surface instead of the v2 shims and reached 107 PASS. Seams re-pinned the
  reflection-sensitive inventory (count 13835 to 14059, digest
  `bbe86927339a19aaa01e3d5d0fe37163dea805c10958fae65a1fff7e2a56eda3`) and the all-scripts
  dynamic-command digest (`3a8bc621a93857f9ef248c6bd294afdaaddfe2cf620f3a4e2f9a8672187cde81`), and
  the boundary audit found that the slice 4 first half's `Assert-LiveSyncPlanDocumentIntegrity`
  had never been seams-validated as a production caller of `Test-LiveSyncPlanSemantics`; the
  boundary now registers exactly that one reviewed internal caller and seams passed 56/0. Suite
  budget: `sync.tests.ps1` moved from 90 to 240 seconds (measured about 86 seconds locally) and
  the Validate workflow timeout moved from 298 to 305 minutes (computed requirement 17985 seconds
  over 35 discovered suites, outer margin 315 seconds); the runner budget contract passed.
  Focused validation: live-plan 107 PASS, sync PASS, harness-env 140/0, automation-safety PASS,
  schema-validation PASS, json-artifact-exact-byte PASS, validate-json-artifacts PASS, parse gate
  160 files, build 7/15/7, secret scan clean, `git diff --check` clean, and the sandbox-hosted
  DryRun routine gate ran the pristine-initial producer against the real repository (29 adds, zero
  live changes). The definitive unified `run-tests.ps1 -All` run then discovered, started,
  completed, and passed all 35 suites exactly once with zero failures, timeouts, duplicates,
  missing suites, or tree-kill failures (external create-new summary SHA-256
  `ec0d9f1cd78768bade27cc75252ac7d64219685526be7f6c838feebde0aa0789`; discovery hash
  `96e6267d927bcdeca4ba56af9f4104cafc0467e43fad51f8ae5b0f8e5cae388e`), with hard-kill 318/0, seams
  56/0, `sync.tests.ps1` completing in 63 seconds inside its new bound, and live-plan exit 0
  inside the run. A fresh post-run sandbox DryRun gate reproduced the pristine-initial producer
  (plan hash `638258f33b700be1f788f47932e0f4a143ffaa141799f4dbc0964662f1f2be18`, plan-file SHA-256
  `5bbdda2e6213e0397c1fb92abb8ffb23bc50eeca3fd2db285374e6f84600012e`, document hash
  `213dbbcb34527473d91de2db824f9f1316e69043b1977d7e17e02cb1681bf562`), and the temporary sandbox,
  plan, and summary paths were deleted after the evidence was recorded. `docs/README.md` documents
  the schema 3 producer contract and the sandbox-hosted dry-run invocation shape. Task 2 is
  complete (7/7; Phase 2 13/52); production Apply remains interlocked, and no live root or Git
  index/ref was changed.

- Phase 2 Task-3 close-out, managed backup receipts and standalone backup retirement (2026-09-09,
  commits `2be7153` + `706fed0`): implemented directly by the main agent after the user's "both"
  instruction. `scripts/backup-receipt-common.ps1` is the transaction-internal receipt producer: it
  validates the flushed ReceiptIntent (exact keys, canonical UUID spellings, distinct ids, receipt
  path leaf bound to the ReceiptId and parent bound to the resolved BackupRoot), the exact
  SourceOperationKind and both reviewed plan hashes, the context/ControlBase/FilesystemCapability
  hashes with HomeAuthorityKey, resolved three-platform targets, and the forbidden roots; it
  validates BackupRoot (existence, no-reparse, identity stability, Fixed/NTFS, current-user-only
  security evidence, disjointness), creates the unique predeclared slot atomically, snapshots only
  planned pre-change managed targets via SafeTreeWalker with the planned tree-hash gate, records
  MISSING targets and unknown/`.system` root-entry markers without traversal, captures the
  authority-state and root-claims preimages as exact held bytes, publishes the immutable
  SchemaVersion=1 receipt (create-new temp, flush, rename; ReceiptHash excludes only itself), and
  returns a structured object. The restart classifier reads only the declared slot
  (MISSING/PARTIAL/COMPLETE); the consumer verifier re-validates schema, semantics, the COMPLETE
  marker, intent bindings, snapshot trees, and preimage bytes; failpoints are capability-gated.
  `schemas/backup-receipt.schema.json` registers one positive and eight negative fixtures
  (unknown-property/wrong-version/copied-crossing/marker-crossing Schema,
  intent-binding/self-hash/target-order/transaction-receipt-alias Semantic) with
  `Test-BackupReceiptSemantics`; the artifact validator dotsources the module.
  `scripts/backup.ps1` is retired: public standalone invocations fail closed with the zero-write
  `backup-is-transaction-internal` diagnostic before traversal; recorded deviation: the
  sandbox-internal legacy snapshot flow remains as the env-activation bridge until Task 5 Step 1,
  mirroring the Task 2 close-out deviation. `tests/backup-receipt.tests.ps1` (plus the
  sandbox-copied receipt host) covers the happy path with custom Reasonix roots, sentinel
  immutability, fresh-copy link counts, and byte-identical preimages; registered validation and
  consumer verification; fresh-process restart classification with a decoy sibling; the failure
  matrix (slot collision, drift, reparse, missing/inside-live/broad-DACL BackupRoot, intent
  mismatches); a genuine concurrent same-slot race with exactly one winner; all five kill windows
  with fresh restart classification and second-create refusal; the tamper matrix; and the
  MISSING-preimage path. Focused validation: backup-receipt PASS (~21 s locally), automation-safety
  PASS, sync PASS, harness-env 140/0, live-plan 107 PASS, schema-validation PASS,
  json-artifact-exact-byte PASS, validate-json-artifacts PASS, parse gate 163 files, secret scan
  clean, `git diff --check` clean; seams re-pinned (dynamic digest `1aff69f1…`, reflection count
  14288, digest `2580eb60…`) and 56/0. The new suite was budgeted at 300 seconds and the Validate
  workflow moved to 310 minutes (computed requirement 18285 seconds, margin 315 seconds); the
  runner budget contract passed. The definitive unified `run-tests.ps1 -All` run then passed all 36
  discovered suites exactly once with zero failures, timeouts, duplicates, missing suites, or
  tree-kill failures (external create-new summary SHA-256
  `c35cf2594b1f2baa186dee088327acfca96f8eacb6fecd43a5758badfa593c89`; discovery hash
  `bc2c80521319cd7e8ad8ae3c944174af14e31b823243844f8c1f34be26889e00`), with hard-kill exit 0, seams
  56/0, backup-receipt passed in about 20.5 seconds, sync/harness-env/automation-safety exit 0
  inside the run, and the external summary path deleted after the evidence was recorded. `docs/
  README.md` documents the retired standalone entry. Task 3 is complete (7/7; Phase 2 20/52);
  receipt consumption and the minting transaction host stay with Tasks 4/6/7; production Apply
  remains interlocked, and no live root or Git index/ref was changed.

- Phase 2 Task-4 close-out, live-mutation state machine, journal, and kill matrix (2026-09-09,
  slices `6ddc1e4`/`51425ff`/`4ba7323`+`1197ed5`/`45dd69f`; slice D implemented by Grok grok-4.6
  via Grok Build from a self-contained brief, quota probed restored, integrated and verified by the
  main agent): the three live journal/result schemas freeze the receipt-backed versus state-only
  mode oneOf, live target records (skill/parent-directory/state with identity, receipt snapshot
  reference, MISSING|PRESENT old/new states), eighteen record phases with strict per-phase data
  key contracts, and the command-versus-transaction result scope split. The journal publisher and
  zero-write chain reader enforce dense sequences, previous-hash links, per-record phase semantics,
  recovery intent precedence, terminal-record-last bound to the exact published result file bytes,
  the strict closing oneOf, and unknown-namespace-entry rejection. The receipt-backed engine runs
  the fixed record sequence (RECEIPT_COMPLETE, parent-first no-overwrite directory creation,
  per-target staging with the destructive recheck, the same-volume rename ladder with full disk
  tuple verification, the authority state target, POSTCONDITIONS_OK, committed result + terminal);
  failure classification restores live targets and this-transaction-created claims in reverse
  before the state commit boundary, publishes the failed-restored fixed result (RestorationHash
  plus the unchanged old state hash; StateHash null is the MISSING-state sentinel) and terminal on
  verified restoration (`apply-failed-but-restored`), and exits
  `live-transaction-recovery-required` with retained evidence otherwise or after the state commit
  boundary. The state-only engine runs the controller-transition sequence (claims proof, captured
  preimage + STATE_PREIMAGE_COMPLETE, the preserves-selection proof, the FILE_* replace ladder,
  committed result with no receipt fields); failures retain evidence and rethrow for reviewed
  abandon/finalize (Task 6). Capability-gated failpoints at eight record boundaries feed the kill
  matrix through the sandboxed child host (receipt-backed kills at RECEIPT_COMPLETE/PREPARED/
  OLD_MOVED/NEW_INSTALLED/STATE_PUBLISHED, state-only kills at STATE_PREIMAGE_COMPLETE/
  FILE_REPLACED) with restart classification, fail-closed re-entry refusal, preimage retention,
  and the external-race restore fail-closed assertion. `tests/live-recovery.tests.ps1` (budgeted
  300 seconds) and `tests/helpers/live-transaction-host.ps1` are new. Focused validation per slice:
  live-recovery PASS, validate-json-artifacts PASS, parse gate 166 files, secret scan clean,
  `git diff --check` clean, seams 56/0 after mechanical re-pins (final: dynamic
  `4a40541a5acf86b1694619697df43d6e510eb49b6c234082130bfa81f47745e5`, reflection count 14573,
  digest `d11b3a51c7de05a17c43f2c185198429133281e3dde6ada57b2cdd602003dbf1`); the seams boundary
  caught the unregistered New-AuthorityStatePostimage caller on the first slice C run and the
  reviewed second caller was registered. The definitive unified `run-tests.ps1 -All` run then
  passed all 37 discovered suites exactly once with zero failures, timeouts, duplicates, missing
  suites, or tree-kill failures (external create-new summary SHA-256
  `29963be7d7215d331a3b797bc1f78c0fd9f8ea03eef5efae78668e6485fc4f8d`; discovery hash
  `b5e6d64c51d66adf878e287b29ab3773794cb8d3f95463e32b82ec488672cfd0`), with live-recovery passed
  in about 41 seconds and hard-kill/seams/sync/harness-env/automation-safety all exit 0 inside the
  run; the external summary path is deleted after this evidence was recorded. The state machines
  stay unconnected to the public CLI until Task 5 wires sync into the global lock order. Task 4 is
  complete (7/7; Phase 2 27/52); production Apply remains interlocked, and no live root or Git
  index/ref was changed.

## Current checkpoint

> Historical snapshot (Phase 1/privacy era). The authoritative current status is in
> `STATUS.md` (Phase 3 complete, 47/47) and in the dated
> Phase 3 sections below; this section is retained only as history and must not be read as
> the current state.

Phase 1 Task 9 and roadmap Task 1 are complete. The branch/tag rewrite is published; Support completed
server-side garbage collection/cache clearing, and the old head is no longer available through the
web, REST, raw-content, or direct Git SHA probes. Ticket `#4697323` and the external privacy follow-up
are closed. The implementation checkpoint now includes the reviewed read-only authority/schema,
sealed fake-ControlBase bootstrap/global-lock, held-lock registry core, caller-held
canonical/current-route slices, the Step 1 identity/concurrency failure matrix, and the sealed
under-lock per-target/per-volume capability preflight with held exact-slot cleanup plus the internal
fixed-infrastructure same-lock capture and receiver-backed held-route runtime observation within Phase
2 Task 1. The observation is production-defined but production-unconsumed; the only production route
consumer remains the read-only registry with `HELD_METADATA_VERIFIED` / `UNPROBED_READ_ONLY` output.
Step 1 is complete (Task 1 1/6); these capability layers advance Step 2 without completing it and
stay unconnected to production mutation routes.

## Current phase

> Historical snapshot (2026-09-08/09, Phase 2 mid-flight). Phase 2 closed at 52/52 and Phase 3 at
> 47/47; do not read the counts below as current, and do not start from the "next implementable
> work" sentence they point at. The authoritative current list is the 2026-09-15 Pending items
> section at the end of this file.

**Phase 2 Tasks 1-4 (6/6, 7/7, 7/7, 7/7) are complete (Phase 2 overall 27/52), with Tasks 5-9 not
started.** Task 1 Step 6 (Verify identity, state shape, and locking) closed on 2026-09-08 with the
authoritative
unified validation over the Task 1-complete state (34/34 suites, summary SHA-256
`ea989bfc5c7351339f0f70265e4ec4909df3cec4d5691cdc27648a542a7cdd03`): all expected outcomes
pinned to anchors (authority-namespace preservation, global overlap rejection, kill-between
finalize/stop, schema/semantic layering, canonical-versus-live/retirement non-interleaving with
zero-write losers including the new recover-Apply route-contention block, OS owner-death
release), with real retirement/sync routes staying with Task 5.

Phase 2 Task 4 closed on 2026-09-09 with the live-mutation state machine, journal, and kill matrix
(see the close-out record above). The next implementable work is Phase 2 Task 5 (migrate normal
sync and retirement to the common host): wire sync into the global lock order, remove the legacy
per-skill swap/journal paths and the sandbox-internal backup bridge, enforce the authority and
selection guards, and re-wire the extracted content-aware regression to the environment producer.
Tasks 6-9 follow in strict sequence. Production Apply remains disconnected.

Step 3 (commits `8ab102f`/`45b9510`/`744f326`/`c107ab8`) added the shared live-transaction
immediate-child contract with ordered live reservation rows and the split fixed-infrastructure
disjoint runs, the sealed setup-finalize window primitive plus the public
`setup-finalize-required` status/Apply token, the claim-accept consumer as the forbidden-root
matrix's unique production caller, and the zero-caller TransactionId create-new mint.

Step 4 (commits `d4e82ff`/`db1af36`/`94f1287`/`ce70ada`) added the in-memory
`TargetContextIntent`/state-intent contract functions with the trusted serializer, the held
write-side validated read (`Read-SealedRegistryValidatedAuthorityDocuments`, throw-on-invalid,
forked from the view's INVALID classification), the first-authority root-claims create-new
writer as the claim-accept gate's unique production caller (pending held create-new plus
no-replace rename, claims never replaced), and the atomic create/replace/recovery-copy state
postimage writer over the serializer's bytes (Replace's OS backup holds the old state bytes,
asserted). Both steps were Grok-executed under the updated delegation model with main-agent
line-by-line diff review; the reflection inventory stands at count 13459 / digest
`876c2a3f807b74e2b09d23ac4939c6ed895e6c8a16875348874a10d72fd5b005`, and the authoritative
unified runs over both final states passed 34/34 suites. Production Apply remains disconnected,
and live-journal structure and interpretation remain deferred to Task 4.

Step 5 (commits `4ecc3b4`/`6c8be14`/`21fece7`/`b483647`) added the deterministic lock-order
machinery: the typed `SealedHeldCanonicalLiveLockOrder` handle with the
`Enter-/Exit-/Assert-SealedHeldCanonicalLiveLockOrder` orchestrator (ExistingOnly first, BOUND
witness binding versus UNBOUND_SETUP_WINDOW), the setup-only SetupBootstrap branch composing the
reviewed bootstrap completion with the two-slot deferred journal-target manifest, the
after-all-locks recompute gate with the backup authorization guard, and the production retrofit
of both unsealed Apply scripts to ExistingOnly acquisition with in-lock recompute while the
interlock results and exit 75 stay unchanged. The enable boundary holds without lifting any
tracked interlock, and the authoritative unified run over the final state passed 34/34 suites.
Production Apply remains disconnected, and live-journal structure and interpretation remain
deferred to Task 4.

Pre-lock `MetadataOnly` TargetContext is discovery/planning evidence, never mutation authority.
The sealed read-only registry now recaptures a supplied current route only under the genuine
caller-held lock pair. Future production plan/Apply consumers must hold all required locks, including
the global live lock, then recapture the full no-follow TargetContext and reject any drift before
backup/workspace creation.
The receiver-backed observation can compose that held route with fixed-infrastructure capability
evidence at runtime, but it grants no mutation authority and has no production lifecycle caller. The
sealed bootstrap and read-only registry remain insufficient as a production filesystem-capability
preflight before release.
Pristine bootstrap validation is now separate from the exact fixed post-bootstrap envelope; arbitrary
children remain fail-closed. Canonical-root-claim v1 has no GitCommonDir locator, so the current
canonical namespace and setup state resolve only through the genuine caller-held witness; no
production route supplies it yet. Before Task 4 defines the live-journal contract, any normalized UUID
live-transaction directory is inventoried as unresolved and blocks mutation as recovery-required
rather than being interpreted heuristically.

## Task 6 progress (2026-09-12): Step 1 read-only recovery status locator

Task 5's close-out (slices 1-4 across seven commits, the claims contract, legacy route removal, and
the parity sandbox with dual authoritative unified 37/37 passes) is recorded in the repository
`STATUS.md` 2026-09-10 sections; this record skipped Task 5 and resumes at Task 6.

Task 6 Step 1 landed as commit `e384a95`: `scripts/recover-live-transaction.ps1` is a strictly
read-only locator over every transaction journal under `<ControlBase>\live-transactions`. It reads
chains with immediate open/close (no retained handles), validates enough header bytes to bind
TransactionId and its OriginRepoId/GitCommonDir/canonical-lock key, and reports exactly one status
per transaction: finished journals summarize as `clean`; receipt-only journals are
`abandon-eligible`; applied target, claims, or state primitives before the complete postimage are
`rollback-required`; a published result with postconditions but no terminal record is
`finalize-eligible`; and unreadable chains, unknown namespace entries, missing header origin
bindings, or phase shapes matching no reviewed recovery form fail closed as
`manual-recovery-required`. Known `_pending` temps are never treated as published records. The
overall status is the most severe unfinished transaction. The scan renames nothing, deletes nothing,
and writes only an optional create-new JSON report (`-JsonPath` refuses to overwrite); the reviewed
recovery transitions deliberately remain with the Task 6 Step 3 dispatcher.

Verification on 2026-09-12 (this tree, canonical `pwsh -NoProfile -File` runs): focused
`tests/live-recovery.tests.ps1` passed with every locator fixture green (each status class, pending
temp tolerance, create-new machine-readable report, overwrite refusal);
`tests/canonical-production-seams.tests.ps1` passed 56/0 after the all-scripts baselines were
re-pinned inside `e384a95`; the PowerShell parse gate accepted 166 files. The unified
`run-tests.ps1 -All` pass has not run for this slice yet and remains pending at the next stage
boundary. Production Apply remains interlocked, and no live root was touched.

## Task 6 Step 2 (2026-09-12): rollback/recovery plan schema 1

Commit `3dbe911` defines `schemas/rollback-plan.schema.json` (ArtifactKind `rollback-plan`,
SchemaVersion 1) for the four PlanKinds and registers it in the artifact contracts with
`Test-RollbackPlanSemantics` (in `scripts/live-transaction-common.ps1`, which is not
hard-kill-sealed). The schema layer owns the strict TransactionMode/PlanKind/ReceiptState oneOf
shapes: complete receipt-backed rollback/finalize require the full receipt plus original-plan
references; early `live-recover-abandon` declares ReceiptState and forbids fabricated hashes outside
COMPLETE; state-only controller recovery requires `ReceiptRef=NO_LIVE_MUTATION`, the immutable state
preimage/expected tuple, and empty Targets while forbidding every receipt field;
environment-rollback is always complete receipt-backed and binds `RollbackStateIntent` (the frozen
current-env-state v3 intent shape) for Task 7 while forbidding the live-recover journal machinery.
The payload binds the reservation/journal identity, origin repo/GitCommonDir/canonical-lock keys,
optional overlay lock, original DocumentHash and prior recovery consumption keys,
header/chain/pending-temp/result inventory, target identity hashes, and the expected terminal
semantic projection. The semantic validator owns what the schema cannot: PlanKind/action/outcome/
projection correspondence, the live-recover `OriginalOperationKind` substitution ban (the schema
leaves the field spelling-only so this fails at the semantic layer), chain ordering and derived-head
binding, the terminal-COMPLETE ban, and the claims/state bindings implied by individual chain
phases.

Sixteen fixtures were added: the receipt-backed `live-recover-rollback` positive, five schema
negatives, and ten semantic negatives; three more sync-plan PlanKind rejection fixtures pin all four
rejected kinds at its schema layer. The seams all-scripts reflection-sensitive baseline was re-pinned
for the validator (14491 -> 14508 sites, digest
`278080365dd5654546d6546b2b79d9ca9e076bebc3bc26ffc456ea2fa6dcfdfc`); no assertion was weakened.

Verification on 2026-09-12 (canonical `pwsh -NoProfile -File` runs): registered artifact validation
passed 28 contracts / 28 positive / 109 negative with zero failures; `tests/live-recovery.tests.ps1`
passed with 20 new contract assertions; `tests/canonical-production-seams.tests.ps1` passed 56/0
after the re-pin; `tests/sync.tests.ps1` passed including the parity sandbox; the parse gate
accepted 166 files; `git diff --check` was clean; the pinned secret scan found no blocking findings
(1023 non-blocking hints); `build-skills.ps1` produced 7/15/7. The unified `run-tests.ps1 -All`
pass remains pending and covers the Step 1 and Step 2 trees together at the next stage boundary.
Production Apply remains interlocked, and no live root was touched.

## Task 6 Step 3 in progress (2026-09-12, superseded): recovery dispatcher slices 1-4

> **Superseded.** This section records Task 6 Step 3 mid-flight on 2026-09-12. Task 6 and Phase 2
> closed on 2026-09-13 (Phase 2 Tasks 1-9). Phase 3 later closed at 47/47 (checkpoint `e57c608`).
> The completion record is the "Task 6 Step 3 completion" section immediately below. The text is
> kept as history.

Step 3 is four slices in; the dispatcher now executes all three reviewed transitions. Slice 1
(`1423b78`, roadmap doc `61163cd`): the `agent-dotfiles.ps1 live recover status|abandon|rollback|
finalize` route, the dispatcher parameter sets, sandbox-only authority resolution
(`AI_AGENT_DOTFILES_INTERNAL_*` locators, derived-versus-injected control/backup equality), the
complete seven-directory bootstrap gate, and a fail-closed stub. Slice 2 (`5176e8b`): DryRun derives
the schema-1 rollback/recovery plan under the origin canonical/witness/global lock order — the
caller's repository is the origin candidate (RepoId, GitCommonDirHash, CanonicalLockKey, and the
header HomeAuthorityKey must all match, so a wrong clone fails closed instead of substituting its
own lock; the namespace witness falls back to the canonical recover UNBOUND setup window), the
exact transaction is re-found and chain-validated under the locks, the requested action must match
the locator classification, and the plan binds the header hash, ordered chain record hashes, the
derived journal head, consumed recovery document hashes, pending temp inventory, result inventory,
and the receipt block (declared slot state; verifier-validated receipt identity plus the
RECEIPT_COMPLETE-bound receipt hash when COMPLETE); Apply validates a reviewed plan fail-closed.
Slice 3 (`b304e8f`): execution for abandon and finalize — the mandatory RECOVERY_ACTION_INTENT
consumes the plan DocumentHash; abandon publishes RECOVERY_ACTION_APPLIED, the fixed abandoned
result (result semantics forbid a COMPLETE-receipt block on abandoned outcomes; MISSING/PARTIAL
binds a null-hash block), and the recovery terminal; finalize reuses the published result bytes,
preserves the existing Outcome, and publishes only the terminal. Two Task-4-era journal gates were
refined to this contract: the terminal ClosingPlanKind crossing check is governed by the
ClosingKind branch (a recovery terminal had been unpublishable), and the Add gate admits the
finalize intent after a published result. Slice 4 (`f2ff911`): rollback — recovery target rows are
reconstructed from the chain records (the header carries no live target rows; the fullest record
per target id binds swap-old as the preimage, created parents as MISSING; the plan schema's target
path fields became nullable), `Restore-SealedLiveMutationTargets` replays the completed primitives
in reverse through the production `Get-SealedLiveJournalCompletedFromChain`, observed states must
equal the header preimage exactly, and the restoration rows hash into the rolled-back result's
RestorationHash. A journal with a published authority state still fails closed
(`live-recovery-state-form-unsupported`) until the state recovery slice.

Verification per slice (canonical `pwsh -NoProfile -File` runs): the live-recovery suite is green
with the full dispatch matrix — wrapper gates, authority gates, the bootstrap-only sandbox
authority fixture, abandon dry-run and apply end to end with create-new discipline, state-only
finalize end to end preserving the committed outcome, rollback end to end against a real engine
transaction killed at NEW_INSTALLED with a verifier-accepted receipt (live tree restored to the
preimage hash, locator clean afterwards), and unknown/action-mismatch/wrong-clone/collision/
finished rejections; seams passed 56/0 after routine baseline re-pins; registered artifact
validation passed 28/28/109 with zero failures after the target-path relaxation; the parse gate
accepted 166 files; the pinned secret scan and `git diff --check` were clean; `tests/sync.tests.ps1`
stayed green; `build-skills.ps1` produced 7/15/7 in the earlier slices. The unified
`run-tests.ps1 -All` pass remains pending at the Step 3 closeout. Production Apply remains
interlocked, and no live root was touched.

Remaining for Step 3: dispatcher failpoint checkpoints with intent→primitive/result/terminal
hard-kill and replay fixtures, linked-worktree dispatch coverage (shared GitCommonDir dispatches
legitimately), STATE_PUBLISHED and state-only rollback through the state recovery machinery, and
the closeout (unified run plus the close-out records). Steps 4-5 of Task 6 follow.

## Task 6 Step 3 completion (2026-09-12): state rollback, recovery failpoints, worktree dispatch

Commit `0e04a2c` closes the remaining Step 3 scope named at the previous checkpoint. Two
independent read-only Grok reviews preceded it: the first produced the state-rollback design note
whose findings were applied, the second an adversarial review of the delta that found two defects
and four gaps; every finding is either fixed in this commit or recorded below as an explicit
boundary.

**Authority state recovery.** `scripts/live-transaction-common.ps1` gained the journal-bound state
evidence helpers (`Get-SealedLiveAuthorityStateReplacementRows`,
`Get-SealedLiveAuthorityStatePreimageBinding`, `Get-SealedLiveAuthorityStateReplacedHash`,
`Get-SealedLiveAuthorityStateRecoveryEvidence`, `Get-SealedLiveObservableFileState`) and
`Restore-SealedLiveAuthorityState`. The restore reads the exact bytes of the
`FILE_PREPARED.StagedPath` preimage copy, requires the copy hash to equal the recorded preimage,
requires the installed state to equal the recorded published postimage (or the preimage on
replay), requires the destination to match `Get-LiveTransactionStatePaths`, re-proves the
immutable claims against the header binding, and writes through the same same-directory temp
replace the state engines use. It journals the new `STATE_RESTORED` phase only when bytes are
written, so a replay after a kill between the write and the record is idempotent. Replays also
skip completed live targets that already match their preimage, so a kill between the live
restoration and the state restoration never repeats a move. The rolled-back result now binds the
restored state hash alongside `RestorationHash`.

**Plan and classification.** Plans bind `AuthorityStatePreimage`/`AuthorityStateExpected` for any
plan over a completed state replacement; a rollback additionally binds the optional schema-1
`AuthorityStatePreimagePath` and is only derived while that copy still reproduces the recorded
preimage. `Test-RollbackPlanSemantics` requires all three for a rollback whose chain contains
`FILE_REPLACED`/`STATE_PUBLISHED` (phases only the authority state file produces) and rejects an
orphan path via the new `rollback-plan.state-preimage-path-orphan.invalid.json` fixture.
`STATE_PREIMAGE_COMPLETE` and `FILE_PREPARED` moved to the dispatcher's pre-primitive set and
`STATE_PREIMAGE_COMPLETE` left the primitive set, so a captured preimage with zero state
primitive is abandon-eligible — the plan's disjoint state-only priority. Two boundaries fail
closed with `live-recovery-state-form-unsupported`: an authority state file replaced on disk while
its `FILE_REPLACED` record is missing (manual recovery; the locator still reports
`rollback-required`/`abandon-eligible` because it stays phase-only by design), and a `STATE_PUBLISHED`
value that disagrees with the `FILE_REPLACED` record or a `STATE_PREIMAGE_COMPLETE` value that
disagrees with the staged preimage.

**Recovery failpoints.** The dispatcher now publishes `RECOVERY_ACTION_INTENT`,
`RECOVERY_ACTION_PRIMITIVES` (both restorations durable, applied record absent),
`RECOVERY_ACTION_APPLIED`, and `RECOVERY_RESULT_PUBLISHED` checkpoints. Kill/replay fixtures prove
the intent window replays through a new plan that consumes the interrupted intent, the primitive
and applied windows replay without repeating a live move or a state write, and the result window is
finalize-only: a rollback request fails closed and the reviewed finalize reuses the published
rolled-back result bytes and preserves its outcome.

**Linked worktree.** Dispatch from a linked worktree proves the shared `GitCommonDirHash`,
repository identity, and canonical lock key (same origin namespace), closes the transaction through
the origin locks, and the origin repository sees the worktree recovery as finished; the wrong-clone
rejection is unchanged.

**Verification (2026-09-12, canonical `pwsh -NoProfile -File` runs).** `tests/live-recovery.tests.ps1`
green in 310 s including every new window, the tampered-copy and unrecorded-replace negatives, and
the linked-worktree block; `tests/canonical-production-seams.tests.ps1` 56/0 after the all-scripts
reflection-inventory re-pin (count 14616 -> 14689, digest
`285cef6a2e221ba1cc676ce00a61260f4bd6d488e225fe8fefe6f75004211c15`); registered artifact validation
28 contracts / 28 positive / 110 negative with zero failures; `tests/test-runner.tests.ps1` passes
with the live-recovery budget raised 300 -> 900 s and the workflow timeout 380 -> 390 minutes
(computed requirement 22785 s, 615 s outer difference); the parse gate accepted 166 files;
`tests/schema-validation.tests.ps1` passed; `git diff --check` was clean; the pinned secret scan
found no blocking findings (1009 non-blocking hints); `build-skills.ps1` produced 7/15/7; and the
sandboxed `sync.ps1 -DryRun` reported 29 additions, zero modified/removed/unknown targets, and
changed no live file (external plan and generated reports deleted after review). The unified
`run-tests.ps1 -All` pass has not returned yet and is the Step 3 closeout gate; its result is
recorded below when it lands. Production Apply remains interlocked, and no live root was touched.

**Step 3 closeout (2026-09-12).** The first unified run since Task 6 Step 2 discovered and started
all 37 suites exactly once with zero timeouts, duplicates, missing suites, or tree-kill failures,
but failed 2: `live-plan.tests.ps1` (a stale sync-plan negative-fixture count from the Step 2
slice) and `root-claims-registry.tests.ps1` (seven assertions matching PowerShell's own English
binder resource strings, which cannot match on this host's zh-CN UI culture; CI is en-US and never
exposed it). Both are pre-existing test-expectation defects unrelated to this slice. Commit
`9a29db6` repairs them without weakening any rejection: the registry count and the four PlanKind
fixture names plus their FailureLayer rows are pinned, and `Assert-ThrowsPattern` now matches each
pattern against the exception message or the stable `FullyQualifiedErrorId`, with the seven
assertions pinning the parameter name plus `MissingMandatoryParameter`/
`ParameterArgumentValidationErrorNullNotAllowed`. The definitive create-new external unified run
then discovered, started, completed, and passed all 37 suites exactly once with zero failures,
timeouts, duplicates, missing suites, or tree-kill failures (external summary SHA-256
`5d21f5adb362704aa1f16ad2e123189c9eab7eaffe2784a4b23cb8132441b018`, discovery SHA-256
`b5e6d64c51d66adf878e287b29ab3773794cb8d3f95463e32b82ec488672cfd0`, elapsed 6281 s). Inside that
run `canonical-hard-kill.tests.ps1` passed 318/0 in 2415 s, `canonical-production-seams.tests.ps1`
56/0 in 217 s, `root-claims-registry.tests.ps1` in 1525 s, `live-recovery.tests.ps1` in 322 s,
`live-plan.tests.ps1` 121 assertions in 10 s, `sync.tests.ps1` in 317 s, and
`live-concurrency.tests.ps1` in 68 s. The external summary file was deleted after its hash and
facts were recorded here.

## Task 6 Steps 4-5 (2026-09-12): deterministic failpoints, committed-finalize, and the restart gates

Commits `528aec5` and `99a8e87` implement Step 4 and the Step 5 items that Step 4's new windows
exposed.

**Failpoints (Step 4).** Every boundary the plan names is now a configured checkpoint:
`RESERVED` once the journal namespace and header are durable; `RECEIPT_FINALIZATION` immediately
before the managed receipt producer; `RECORD_PENDING:<Phase>` after a journal record's pending temp
is flushed and schema-validated and `RECORD_PUBLISHED:<Phase>` after its publish rename, implemented
by composing the two reviewed canonical publication primitives in the live layer so the
hard-kill-sealed shared helper stays untouched and its catch-dispose behavior is preserved;
`STATE_REPLACE_PENDING` before the authority state move in both engines; `RESULT_PUBLISH` once the
postconditions record is durable; and `TERMINAL_RECORD` before the final `COMPLETE` record in both
engines, the failed-restored path, and the recovery dispatcher. The record-boundary pair gives real
`_pending`-temp windows: a kill between them leaves exactly one reviewed record temp and never a
published record.

**Committed-finalize.** The `RESULT_PUBLISH` window (complete state postimage plus postconditions,
no published result) is now a reviewed close instead of a fail-closed dead end. DryRun binds the
missing result inventory, the committed outcome, and the installed state hash in the expected
terminal projection; `Test-RollbackPlanSemantics` requires the `STATE_PUBLISHED` and
`POSTCONDITIONS_OK` phases plus that projection hash for a result-MISSING finalize. Apply
revalidates the postimage, the immutable claims, and the projection under the held locks and then
publishes fixed bytes computed from the original evidence and the actual journal head: committed
outcome, the installed state hash, and for receipt-backed transactions the verifier-revalidated
COMPLETE receipt block, with no restoration binding. A header-only reservation is now classified
abandon-eligible, which the plan names as its `RESERVED` window.

**Restart gates (Step 5).** Two open items the new windows exposed became fail-closed rules: a live
mutation refuses to start while any transaction in the authority's journal namespace is unfinished
(`live-recovery-required`, zero new namespaces, released once the transaction is finished), and a
header binding `WorktreeOverlayLockKey` fails both recovery plan derivation and apply with
`worktree-overlay-lock-not-implemented` instead of being recovered without the overlay lock the
header requires (the reviewed lock-order primitive refuses REQUIRED applicability until the
Phase 3 worktree overlay lock exists; the dispatcher previously read the wrong field name and would
have silently skipped it). **Superseded by G4 (`976d0fe`):** the rollback entry now acquires the
worktree overlay lock in the reviewed order, and the live-recovery suite asserts the token can no
longer appear. Do not re-implement this refusal. Production Apply remains interlocked.

**Verification (2026-09-12, canonical `pwsh -NoProfile -File` runs).** `tests/live-recovery.tests.ps1`
green in 446 s: the engine kill matrix gains the record-boundary and pre-replacement windows with
their `_pending`-temp and state-untouched assertions, the state-only engine gains its
pre-replacement and pending-`STATE_PUBLISHED` windows, and the dispatcher gains reservation-only
abandon, receipt-backed and state-only committed-finalize, the pre-replacement live-only rollback,
the overlay rejection, the unfinished-transaction gate with its release proof, and an injected
mid-recovery failure that retains the preimage copy, publishes no state record/result/terminal, and
then replays to completion against the same evidence. `tests/canonical-production-seams.tests.ps1`
56/0 after the all-scripts reflection-inventory re-pin (14689 -> 14713, digest
`816d7205e9fdc6f39087bea148086ae3247c4d691d3ed08deecc78170bd7eb05`); registered artifact validation
28 contracts / 28 positive / 110 negative with zero failures; the parse gate accepted 166 files;
the pinned secret scan found no blocking findings; `build-skills.ps1` produced 7/15/7;
`tests/sync.tests.ps1`, `tests/live-plan.tests.ps1`, `tests/live-concurrency.tests.ps1`, and
`tests/doctor.tests.ps1` passed; `git diff --check` was clean. The unified `run-tests.ps1 -All` pass
is the Task 6 closeout gate. The definitive create-new external pass then discovered, started,
completed, and passed all 37 suites exactly once with zero failures, timeouts, duplicates, missing
suites, or tree-kill failures (external summary SHA-256
`62b9797b9d46313993eac33186de7bb34a9801dd809c988f0c6bdccee8e1b71b`, discovery SHA-256
`b5e6d64c51d66adf878e287b29ab3773794cb8d3f95463e32b82ec488672cfd0`, elapsed 7191 s), with
`canonical-hard-kill` 318/0 in 2721 s, seams 56/0 in 241 s, `root-claims-registry` green in 1680 s,
`live-recovery` in 545 s, `live-plan` 121 assertions in 13 s, `sync` in 287 s, `live-concurrency` in
82 s, and `doctor` in 3 s. An earlier pass of the same tree reported 36/37: its single failure was
`root-claims-registry.tests.ps1` raising `route-witness-required` from
`scripts/root-claims-registry-common.ps1:7239` inside an observation-close block that had passed in
the two preceding unified runs. That suite loads none of the files this slice changed (it does not
dot-source `scripts/live-transaction-common.ps1` and does not invoke the syntax gate) and passed
standalone in 1745 s, while that pass overlapped another session's Python coverage suite and project
verification on the same machine; it is recorded as a machine-load interference flake, and the
definitive pass above did not reproduce it. The external summary files were deleted after their
hashes and facts were recorded here. Production Apply remains interlocked and no live root was
touched.

**Remaining Step 5 proofs.** Two Step 5 clauses are not covered by this slice and stay open:
"a different HomeAuthority with overlapping custom roots" and "concurrent canonical mutation cannot
interleave". Both need the cross-authority/root-overlap and canonical-mutation fixtures that Task 8
already owns ("Lock-contention, hard-kill, root-overlap, and custom-target matrix"), and the
recovery-side overlay lock itself remains the Phase 3 worktree overlay item. The `RECEIPT_FINALIZATION`
checkpoint is emitted in the production host, which the current fixtures do not run as a killable
child, so its placement is pinned at the source boundary and its observable window is the
header-only reservation covered by the `RESERVED` kill.

## Task 7 slices 1-2 (2026-09-13): receipt-based rollback entry and a plan-layer contradiction fix

**Slice 1 (`00e3632`).** `scripts/rollback-harness-env.ps1` is rebuilt as the reviewed entry: only
`-ReceiptPath` selects a rollback (with `-DryRun|-Apply`, `-PlanPath`, `-RepoRoot`, `-JsonPath`),
the legacy `RunId`/`BackupPath`/`BackupRoot`/`HomeRoot` parameters and the legacy whole-tree
implementation are gone, and Apply still stops at the Phase 0 interlock before any work. The
resolution order is the sandbox-injected authority plus its complete bootstrap prefix, the
external-artifact preflight for the receipt and plan paths, the receipt slot state, and the receipt's
source operation kind: a missing slot is `rollback-receipt-missing`, a partial one
`rollback-receipt-not-complete`, any source kind other than `environment`
`rollback-source-kind-unsupported`, and a complete environment receipt reaches
`live-rollback-dispatch-not-wired` until the remaining slices replace it. The new
`tests/backup-recovery.tests.ps1` pins the parameter surface and legacy-switch removal, the wrapper
mode gates, the authority gate, the missing/partial/wrong-kind rejections, the interlocked Apply, and
the private-artifact-path rejection of a plan path inside the repository; `tests/automation-safety.tests.ps1`
now exercises the receipt surface for its interlock case; `docs/README.md` and `docs/RESTORE.md`
describe the new form; the new suite budget (300 s) moved the workflow timeout to 400 minutes.

**Slice 2 (`50d6616`).** The bounded design review for Task 7 found a hard contradiction introduced
by Task 6 Step 2: `Test-RollbackPlanSemantics` required `OriginalOperationKind` for every plan and
only afterwards returned early for `environment-rollback`, while `schemas/rollback-plan.schema.json`
forbids that field for that kind. No environment-rollback document could pass both layers, so Step 2
had no representable plan. The validator now handles `environment-rollback` first with its own
reviewed rules — `SourceOperationKind` must be `environment`, `OriginalOperationKind` must be absent,
`ReceiptIntent`/`ReceiptId` must agree, and `RollbackStateIntent` must carry
`LastOperationKind=environment-rollback` with the payload's `HomeAuthorityKey` — while the
live-recover path keeps its original requirement. Three registered semantic negatives (wrong source
kind, wrong intent kind, mismatched intent authority key) and an in-suite positive pin the shape.

**Verification of slices 1-2 (2026-09-13, canonical `pwsh -NoProfile -File` runs).** The new
`tests/backup-recovery.tests.ps1` passes (26 assertions) and `tests/live-recovery.tests.ps1` is green
in 469 s with the environment-rollback positive and its three registered semantic negatives;
`tests/automation-safety.tests.ps1` (its interlock case now uses the receipt surface),
`tests/agent-dotfiles.tests.ps1`, `tests/harness-env.tests.ps1`, `tests/doctor.tests.ps1`, and
`tests/test-runner.tests.ps1` pass; registered artifact validation passed 28 contracts / 113
negatives with zero failures; `tests/canonical-production-seams.tests.ps1` passed 56/0 with **no**
baseline re-pin this time (the new code adds ordinary function calls, not inventoried dispatch
sites); the parse gate accepted 167 files; the pinned secret scan found no blocking findings;
`build-skills.ps1` produced 7/15/7; `git diff --check` was clean. Adding the new suite moved the
workflow timeout to 400 minutes and the runner contract still passes. **The unified
`run-tests.ps1 -All` pass has not run for this tree yet** (it now discovers 38 suites) and belongs to
the Task 7 closeout.

**Task 7 remaining scope, from the same review (bounded to the plan text, the schema, the live
journal/engines/host, the new entry, and the named fixtures).** The review's verified facts that the
next slices must act on:

- `Invoke-SealedLiveTransactionHost` cannot run a rollback as written: it gates
  `OperationKind` to `initial|retirement` (~line 2106) while a rollback plan carries `PlanKind`; it
  loads `AuthorityStateIntent` instead of `RollbackStateIntent`; the rollback schema has no
  `TargetContextIntent`, no `Platforms`/`OrderedActions`, and no action verbs, so the host must
  reconstruct the context from current claims and map the plan's `Targets` Current/Candidate onto the
  engine's add/update/prune ladder; and the engine copies NEW bytes from `SourceRoot`, which for a
  rollback must point at the source activation's snapshot (`receipt/snapshot/<platform>/`), not at a
  materialization root.
- The rollback's own transaction is a **new original** transaction: header `ReceiptIntent` is the
  pre-rollback slot, `RECEIPT_COMPLETE`/result bind that new receipt, and the terminal closes with
  `ClosingKind=original` (never `recovery`, which belongs to `live-recover-*`); the source activation
  stays bound on the plan (`SourceTransactionId`, `SourceOperationKind`, `ReceiptId`/`ReceiptHash`,
  `OriginalPlanHash`/`OriginalDocumentHash`).
- `RollbackStateIntent` copies `HomeAuthorityKey`, `RootClaimsHash`, selection/environment, overlay,
  manifest and final-managed semantics, controller fingerprint, and toolchain hash from the
  activation preimage; `LastOperationKind=environment-rollback`; the receipt/journal refs and the
  final identities are regenerated at Apply.
- The rollback requires the worktree overlay lock in the canonical→overlay→global order, and the
  reviewed lock-order primitive still refuses `REQUIRED` applicability
  (`worktree-overlay-lock-not-implemented`). Execution verification therefore depends on the Phase 3
  worktree overlay lock or an explicit scope decision. **Superseded by G4 (`976d0fe`):** the
  rollback entry now acquires the worktree overlay lock in the reviewed order, and the
  live-recovery suite asserts the token can no longer appear. Do not re-implement this refusal.
  Production Apply remains interlocked.
- The Step 1 source graph cannot use the public host (it rejects `environment` too): the reviewed
  recipe is the sealed plan fixture for the plan shape, a real header through
  `New-SealedLiveJournalHeader`, a real receipt through `Invoke-SealedManagedBackupReceipt` with
  `SourceOperationKind=environment`, and the engine through the test host's `produce` mode.
- Cases the current fixtures cannot produce: a committed environment→**task-overlay**→old-receipt
  chain (no task-overlay producer exists and the host rejects that kind), and `abandoned`/`rolled-back`
  source terminals (the engine only publishes `committed` or `failed-restored`).

## Remaining work

> Historical snapshot (2026-09-13, Phase 2 closeout). The Phase 3 sentences below were current
> then; Phase 3 has since completed at 47/47. Read the 2026-09-15 Pending items section at the end
> of this file for the live list.

**Phase 2 (Tasks 1-9) is complete**, closing with the Task 9 checkpoint's definitive unified pass
(38/38, zero failures/timeouts). Phase 3 shared environment authority and task-overlay work,
followed by the Phase 4 schema/CI contract and safe release, have not started. Before future
environment planning, rebuild the stale commit-bound environment staging locks; this does not
authorize Apply.

| Task | Remaining steps | Remaining outcome |
|---|---:|---|
| Task 1-8 | 0 | Complete |
| Task 9 | 0/5 | Complete — focused suites, artifact validation, the definitive unified pass, the bounded independent review with its fixes, and the real-home non-mutation evidence all recorded |

The required execution order is Task 1 -> Task 2 -> Task 3 -> Task 4 -> Task 5 -> Task 6 -> Task 7
-> Task 8 -> Task 9. Phase 3 shared environment authority and task-overlay work, followed by the
Phase 4 schema/CI contract and safe release, have not started. Before future environment planning,
rebuild the stale commit-bound environment staging locks; this does not authorize Apply.

Carried boundaries: the locator stays phase-only by design, so an authority state file replaced
without its `FILE_REPLACED` record surfaces as a dispatcher DryRun failure rather than a locator
status; a live-target move whose record is still a `_pending` temp classifies as manual recovery
(the phase evidence matches no reviewed form); the recovery-side worktree overlay lock waits for
the Phase 3 worktree overlay lock primitive; and the `RECEIPT_FINALIZATION` host checkpoint is
placement-pinned because the production host is not yet run as a killable child.

## Task 7 Step 1 completion (2026-09-13): source-graph fixture and the fail-closed eligibility gates

`scripts/rollback-harness-env.ps1` now gathers the full source-graph evidence and fails closed on
every disagreement before the not-yet-wired transition stub. `Get-RollbackSourceEvidence` verifies,
in order: the receipt document's required fields (`rollback-receipt-not-complete (missing <field>)`),
the exact reviewed producer semantics and self-hash via `Test-BackupReceiptSemantics` and the
path binding (`rollback-receipt-tampered (receipt document | receipt path)`), the `_meta/COMPLETE`
marker bytes (`rollback-receipt-tampered (complete marker)`), the receipt `HomeAuthorityKey` against
the derived authority (`rollback-home-authority-mismatch`), every managed snapshot tree hash and
recorded root hash (`rollback-backup-drift (<platform> snapshot root | <platform>/<name>)`), both
authority-preimage copies' status and bytes (`rollback-preimage-missing/-tampered
(AuthorityStatePreimage | RootClaimsPreimage)`), the current claims bytes against the claims
preimage (`rollback-claims-drift`), and the linked `SourceTransactionId` journal: namespace
existence (`rollback-source-transaction-missing`), zero-write chain read plus
`Test-SealedLiveJournalChain` (`rollback-source-transaction-tampered`), a single terminal COMPLETE
record with a result (`rollback-source-transaction-unfinished`), terminal `Outcome=committed`
(`rollback-source-outcome-unsupported (outcome=failed-restored | …)`), and the full receipt
binding across header, `RECEIPT_COMPLETE` record, and committed result
(`rollback-source-receipt-mismatch (<detail>)`). `Assert-RollbackSourceEligible` then compares the
current surface with the terminal poststate: current state bytes against the result `StateHash`
(`rollback-state-drift (state absent | state hash)`), the tracked overlay baseline equality between
the activation preimage and the current state (`rollback-overlay-drift (overlay hash | overlay
skills)`), and every platform live root against the poststate `FinalResolvedIdentities` path and
directory identity (`rollback-live-root-drift (<platform> root | identity)`). The plan and JSON
output paths are preflighted through the shared private-artifact-path table before the evidence
gates, so a `PlanPath`/`JsonPath` inside the repository and a DryRun plan collision are rejected
without interpreting receipt evidence. An eligible graph still reaches
`live-rollback-dispatch-not-wired` — the derivation (Step 2), pre-rollback receipt (Step 3), and
execution (Step 4) remain.

`tests/backup-recovery.tests.ps1` builds the reviewed source graph per the design recipe: a sandbox
builder script (run through the internal sandbox host) creates the live roots, claims, and preimage
state; derives the plan shape from the sealed `OperationKind=environment` plan fixture; publishes a
real receipt through `Invoke-SealedManagedBackupReceipt -SourceOperationKind environment` bound to
the sealed plan's PlanHash/DocumentHash; publishes the real header through
`New-SealedLiveJournalHeader` with `OperationKind=environment`; and runs the mutation engine through
the test host's `produce` mode in a child process, verifying the committed terminal and state hash
before printing the graph. The fixture models real environment-activation semantics: only the first
graph creates the claimed live roots (the sandbox uses a custom Reasonix root for that first claim),
every later graph reuses the roots the current authority state resolves, and each later environment
transaction advances `AuthorityGeneration` from the actual current state as its preimage. The suite
grew from 26 to 87 assertions covering: the eligible graph reaching the stub; the relocated-receipt
path-binding rejection; modified backup bytes; both tampered preimage copies; marker, self-hash, and
missing-field receipt tampering; another HomeRoot; the overlay-baseline drift between a source
transaction's preimage and its terminal poststate; a receipt recorded against a different Reasonix
root; a header-only reservation; a real `failed-restored` terminal produced by a failing produce
run; a tampered journal record; a replaced live root with identical content; a later legitimate
generation making the earlier of two complete receipts stale while the latest stays eligible;
current state and claims drift; the private-artifact-path and collision preflights; and the
interlocked Apply. Two roadmap cases remain fixture-unbuildable boundaries: a committed
environment→task-overlay chain (no task-overlay producer; the host rejects that kind) and
`abandoned`/`rolled-back` source terminals (the engine publishes only `committed` or
`failed-restored`). PlanKind mismatch stays pinned at the plan layer (schema, semantic negatives,
and the in-suite positive from the slice-2 fix); its entry-layer Apply case arrives with Step 2's
plan validation. The layered gates also surfaced two reviewed facts recorded here: a relocated copy
of an exact receipt is rejected by its own path binding before any tree work, and the per-target
backup-drift detail is defense-in-depth behind the platform root hash (any byte change hits the root
check first); both are pinned as the reviewed tokens they produce. The suite's local time is 245 s,
so its budget moved 300 → 900 s; the computed requirement (23685 s) still sits below the 400-minute
workflow bound and the runner contract passes unchanged.

## Task 7 Step 2 (2026-09-13): the derived environment-rollback plan under the reviewed lock order

`scripts/rollback-harness-env.ps1` now performs the ordered eligibility derivation and derives the
schema-1 `environment-rollback` plan. The calling repository is bound as the origin candidate
(`Get-CanonicalGitContext`/`Get-CanonicalRepoIdentity`/`Get-CanonicalTransactionContractPaths`), and
everything after the receipt preflight runs under the reviewed origin canonical → worktree overlay →
global lock order (`Enter-CanonicalRepoLock`, the tolerated-absent canonical namespace witness,
`Enter-HomeAuthorityGlobalLiveLock` with the optional witness). Under those locks the Step 1
evidence and current-surface eligibility gates revalidate, two new fail-closed checks run, and the
derivation executes:

- `Assert-RollbackOriginMatch` compares the source journal header's `OriginRepoId`,
  `GitCommonDirHash`, and `CanonicalLockKey` with the calling clone (`rollback-origin-mismatch
  (repo identity | git common dir | canonical lock key)`), so a wrong clone can never derive or
  execute a rollback it does not own.
- `Assert-RollbackOverlayLockSupported` rejected a source header that binds a
  `WorktreeOverlayLockKey` with the reviewed `worktree-overlay-lock-not-implemented` token until
  the Phase 3 worktree overlay primitive existed. **Superseded by G4 (`976d0fe`):** that helper is
  gone from `scripts/rollback-harness-env.ps1`, the entry now acquires the worktree overlay lock in
  the reviewed order, and the live-recovery suite asserts the token can no longer appear. Do not
  re-implement this refusal.
- `New-EnvironmentRollbackPlanDocument` derives the plan entirely from verified evidence: the
  payload binds `SourceTransactionId`/`SourceOperationKind=environment`, the source
  `OriginalPlanHash`/`OriginalDocumentHash`, the source receipt identity
  (`ReceiptIntent`/`ReceiptId`/`ReceiptHash`), the origin keys, `RootClaimsHash`, and the
  `RollbackStateIntent` — the activation preimage's semantic fields
  (`HomeAuthorityKey`, `RootClaimsHash`, selection/environment, `TaskOverlayHash`/`TaskOverlaySkills`,
  `ManifestHashes`, `FinalManagedHashes`, controller fingerprint, toolchain hash) with
  `LastOperationKind=environment-rollback` and `AuthorityGeneration` advanced past the current
  state; the rollback's own receipt and journal refs are regenerated at Apply and the schema-forbidden
  live-recover fields are absent. One restore row per receipt snapshot target binds the observed
  current state (`Current`), the exact snapshot bytes and pre-change identity as `Candidate`, the
  snapshot path as `PreimagePath` with a `ReceiptSnapshotRef` for COPIED targets, and the safe bare
  name joined under the platform's recorded (eligibility-verified) live root as `TargetPath`, so the
  engine's add/update/prune ladder maps directly. The derivation self-checks through
  `Test-RollbackPlanSemantics` before any byte is written, then writes the plan create-new under
  the held locks and prints the PlanHash.
- Apply validates the reviewed plan fail-closed under the held locks — file presence
  (`rollback-plan-missing`), the pinned schema, the semantic layer, and
  `Assert-RollbackPlanInvocationMatch` (`rollback-plan-mismatch (<detail>)` for plan kind, home
  authority, receipt id/hash, source transaction, and original plan/document hash) — before the
  still-not-wired transition stub. Apply remains behind the Phase 0 production interlock, so the
  validation tail is reviewed code that only executes after policy release.

`tests/backup-recovery.tests.ps1` grew to 135 assertions (385 s locally; the 900 s budget holds).
The eligible graph's DryRun now derives and writes the reviewed plan, which is validated against the
pinned schema and semantic layer in-suite and asserted for every binding: source transaction,
receipt identity, source plan references, authority key, calling-repository origin identity, the
absence of every schema-forbidden field, the preimage-carried intent fields, the advanced authority
generation, and the three restore rows (restoration over the installed update bytes, removal of the
installed add target, and restoration of the pruned target from its snapshot). Two new source-graph
variants pin the origin mismatch (a header born with a foreign `OriginRepoId`) and the overlay-lock
refusal, each proving zero plan bytes; the stale-receipt and derivation rejections also prove zero
plan bytes. The fixture builder now binds the calling repository's real canonical origin identity
into every source header.

Verification (canonical `pwsh -NoProfile -File` runs): backup-recovery 135 assertions; seams 56/0
after re-pinning the all-scripts baselines (dynamic-command digest and reflection-sensitive
inventory 14646 → 14679 for the derivation's added dispatch sites); live-recovery;
automation-safety; agent-dotfiles; harness-env; live-plan; doctor; registered artifact validation
28 contracts / 28 positive / 113 negative with zero failures; parse gate 167 files; secret scan
clean; `build-skills.ps1` 7/15/7; `git diff --check` clean. Production Apply remains interlocked
and no live root was touched.

## Task 7 Step 3 prerequisite (2026-09-13): the receipt contract admits the rollback producer kind

The pre-rollback receipt (roadmap Step 3) is a managed receipt whose producer kind is the rollback
itself. `schemas/backup-receipt.schema.json` and `Invoke-SealedManagedBackupReceipt` now admit
`SourceOperationKind=environment-rollback`, and `tests/backup-receipt.tests.ps1` pins that a
complete rollback-kind receipt publishes a COMPLETE slot and passes both the registered schema and
`Test-BackupReceiptSemantics`. The ordinary rollback route is unchanged: its preflight still
selects only `environment` receipts, so a rollback receipt can never start a second ordinary
rollback. The remaining Step 3 work — deriving the pre-rollback receipt's platforms and context
hashes at Apply and wiring it ahead of the transition — is part of the Step 3+4 execution unit
whose verification waits for the Phase 3 worktree overlay lock and the released production
interlock. **Superseded by G4 (`976d0fe`):** the overlay lock is wired; production Apply still
waits on the interlock.

## Task 7 Steps 3-4 (2026-09-13): the executed rollback transaction, verified directly until Phase 3

> **Superseded (2026-09-16).** The overlay-lock refusal this section records is closed: `976d0fe`
> wired the rollback entry to the Phase 3 worktree overlay lock (Phase 3 closed at 47/47,
> checkpoint `e57c608`). Production Apply remains interlocked. The text is kept as history.

`scripts/live-transaction-common.ps1` gains `Invoke-SealedEnvironmentRollbackTransaction`, the
reviewed composition that executes a derived, invocation-validated `environment-rollback` plan as a
NEW original receipt-backed transaction. The caller holds the reviewed origin canonical → worktree
overlay → global lock order and has revalidated the plan and the current surface under those locks;
the lock-order primitive refuses `REQUIRED` overlay applicability until the Phase 3 primitive
exists, so the entry's Apply tail now fails closed with
`worktree-overlay-lock-not-implemented` after its plan validation (the retired
`live-rollback-dispatch-not-wired` stub is removed), and the direct tests are the reviewed
verification surface until then.

Step 3 inside the composition: the pre-rollback receipt (`SourceOperationKind=environment-rollback`,
PlanHash/DocumentHash bound to the rollback plan) snapshots exactly the live bytes every plan target
is about to change — one COPIED target per plan row whose `Current` is PRESENT, bound to the
row's observed tree hash — plus the current authority state and the immutable claims as authority
preimages, with the context hashes mirroring the sync host's derivation. Any drift between the
plan's `Current` bindings and the live tree fails the receipt producer before any mutation. The
rollback's own journal header (`OperationKind=environment-rollback`) publishes before the receipt,
mirroring the host's reservation order.

Step 4 inside the composition: the plan's restore rows map onto the engine's add/update/prune
ladder (equal `Current`/`Candidate` hashes are no-ops; PRESENT→PRESENT restores over the installed
bytes; MISSING→PRESENT restores from the source activation's snapshot; PRESENT→MISSING removes),
and the engine's source roots point at the source activation's `receipt/snapshot/<platform>/`
directories. The state intent is the plan's `RollbackStateIntent` completed with the rollback
plan's own hashes; the capability evidence comes from the current state's bound
`FinalResolvedIdentities` (the surface is proven equal to that terminal beforehand), and the context
rows are projected from those same final identities — the reviewed state-vs-claims validators pin
them to the immutable claims, whose bytes are separately proven unchanged through `RootClaimsHash`.
Staging uses the reviewed home staging base (`<HomeRoot>\.ai-agent-dotfiles-staging\<platform>`,
state recovery under the Claude staging root), and the engine runs the common state machine:
terminal `Outcome=committed` with `ClosingKind=original`, the restored state carrying
`LastOperationKind=environment-rollback` and the generation advanced past the pre-rollback state.

`tests/backup-recovery.tests.ps1` executes the eligible graph's derived plan directly in the
sandbox immediately after its derivation and grew to 150 assertions (321 s locally; the 900 s
budget holds): all three verb classes restore symmetrically on the already-claimed custom Reasonix
root (the update target's pre-activation bytes return, the installed add target is removed, the
pruned target returns from the activation snapshot); the pre-rollback receipt is COMPLETE and
snapshots the pre-rollback live bytes including the target about to be removed; the installed state
matches the returned StateHash with the advanced generation, rollback operation kind, and unchanged
overlay baseline; the journal chain validates end to end with a committed result and an original
close; and the executed source receipt is afterwards stale against its own rollback
(`rollback-state-drift`, zero plan bytes). The artifact-path assertions now pin the shared-table
rejection text directly.

Verification (canonical `pwsh -NoProfile -File` runs): backup-recovery 150 assertions; seams 56/0
after re-pinning the reflection-sensitive inventory (14679 → 14715 for the new composition's
sites; the dynamic-command digest unchanged); live-recovery, backup-receipt, live-plan,
automation-safety, agent-dotfiles, harness-env, doctor, and test-runner passing; parse gate 167
files; secret scan clean; `build-skills.ps1` 7/15/7; `git diff --check` clean. Production Apply
remains interlocked and no live root was touched.

## Task 7 Step 5 (2026-09-13): the env rollback CLI surface in harness-env

`tests/harness-env.tests.ps1` section 9.10 completes the Step 5 surface: `env rollback` without a
receipt path fails closed on the missing mandatory parameter; the legacy `RunId` token no longer
selects a rollback and fails closed (it binds as a receipt path and is rejected); and the public
non-sandbox surface fails closed with `live-plan-host-resolution-required` before any authority or
receipt work, writing no plan. The three-platform symmetric execution substance — including the
already-claimed custom Reasonix root and the rejected drift matrix — is pinned by
`tests/backup-recovery.tests.ps1`'s derivation and execution sections (150 assertions). With this,
Task 7's five roadmap steps are implemented; only the closeout unified `run-tests.ps1 -All` pass
(38 suites, workflow timeout 400 minutes) remains, together with the status/roadmap closeout and
the harness-model loop.

## Task 7 closeout (2026-09-13): the definitive unified pass

The create-new external unified `run-tests.ps1 -All` pass for the Task 7 tree (HEAD `d4b33ff`,
clean working tree) discovered, started, completed, and passed all 38 suites exactly once with zero
failures, timeouts, duplicates, missing suites, or tree-kill failures, in 7863 s: hard-kill 3001 s,
root-claims 1665 s, live-recovery 472 s, sync 332 s, backup-recovery 323 s, seams 236 s, harness-env
47 s, backup-receipt 30 s. The external create-new summary's SHA-256 is
`14fa4d36564f9310042a5562937ee59829480eb2c09f85f64a54970683abd1c0` (355600 bytes, deleted after
this record), its DiscoveryHash is
`bca55823225ad6bfb5769b99b4cd7f4c60abcd546cab63b470b81d850d7ae137`, and its computed job
requirement is 23685 s, under the 400-minute workflow bound. Task 7 (receipt-backed environment
rollback) is complete: all five roadmap steps implemented, verified by the focused suites and this
definitive pass. Production Apply remains interlocked and no live root was touched.

## Task 8 Step 1 (2026-09-13): mid-flight zero-wait losers and the canonical interleave proof

`tests/sync.tests.ps1` gains the mid-flight lock-contention section — the Task 8 Step 1 matrix
lives here rather than in `tests/live-concurrency.tests.ps1` because the full-chain sandbox fixture
(authority bootstrap, canonical setup, real plans) already exists in the sync suite, while
live-concurrency retains the lock-level contention coverage it already pins. Two different
retirement plans derive against the same overlapping roots; the winner is held mid-flight at the
deterministic `PREPARED` failpoint while it owns the origin canonical and global live locks; the
competing plan loses with exact zero-wait `operation-lock-busy` and creates zero backup and zero
journal namespace; a concurrent canonical mutation (the fixture repository's canonical lock)
cannot interleave with the mid-flight live transaction; the winner's failpoint deadline then
expires into the reviewed failed-restored terminal (the live targets are restored, and exactly the
winner's own journal namespace carries the failed-restored result); and the competing plan
completes the retirement under the fresh locks, with every existing retirement assertion
unchanged. This also executes the carried Task 6 Step 5 proof that a concurrent canonical mutation
cannot interleave.

Recorded boundary for Step 2 (bounded-wait losers): public live routes are zero-wait by reviewed
design — the bounded-wait surfaces are sealed-host-only and their contention semantics are pinned
by live-concurrency's timeout-waiter tests — and the "waiter acquires the lock and recomputes"
residue is the existing re-apply staleness pins (`live-plan-hash-mismatch` with zero backup). The
hard-kill windows of Step 3 are the Task 6 Step 4 deterministic failpoint matrix (kill/replay
fixtures per checkpoint with evidence retention); the Task 8 remainder is Step 4's root-claim
overlap and custom-target matrix.

Verification (canonical `pwsh -NoProfile -File` runs): sync.tests 455 s (budget 1200 s), zero
failures; test-runner (the workflow bound is unchanged), live-plan, automation-safety, and doctor
passing; parse gate 167 files; secret scan clean; `git diff --check` clean. Production Apply
remains interlocked and no live root was touched.

## Task 8 Step 4 (2026-09-13): the transition rejection pinned, and the cross-authority gap recorded

The default→custom Reasonix root transition after a claim exists is now pinned in
`tests/backup-recovery.tests.ps1` (155 assertions): a forged transaction whose header binds a
semantically valid claims document for a DIFFERENT (custom) Reasonix root is rejected by the
immutable claims proof and closes `failed-restored` — the on-disk claims bytes are unchanged, the
proposed transition root is never claimed or populated, the pruned target is restored, and the
rejected receipt cannot start a rollback (`rollback-source-outcome-unsupported`). The claims
semantics also pin the Claude/Codex locations to the fixed HomeRoot paths (only the Reasonix root
is customizable), which the fixture now exercises explicitly.

**Recorded finding (empirical, two-authority probe).** The other half of the roadmap's Step 4
Expected — "two authorities sharing only one platform root are rejected" — is **not implemented**:
a dedicated two-home probe built two complete authorities (independent bootstrap, claims, state,
and committed environment transactions) whose custom Reasonix root was the SAME directory, and both
transactions committed successfully. Every candidate mechanism is authority-local by construction:
the claims semantics validate disjointness within one document; the registry's global claim lives
under each authority's own control base (`canonical-roots/<repoId>.json`); the canonical namespace
witness validates the repo identity but not the ControlBase binding; and the host's unfinished
transaction scan is per-authority namespace. Cross-authority root-claim overlap rejection therefore
requires a machine-wide claim store — which is the Phase 3 shared-authority design question (where
that store lives and how it is locked), not something to invent inside a Phase 2 test slice. The
carried Task 6 Step 5 proof ("the unfinished-transaction scan blocks normal mutation — including a
different HomeAuthority with overlapping custom roots") is likewise only executable up to its
same-authority half; its cross-authority half waits for that Phase 3 mechanism.

Verification (canonical `pwsh -NoProfile -File` runs): backup-recovery 155 assertions with the new
root-transition section green; parse gate 167 files; secret scan clean; `git diff --check` clean;
test-runner passing (no budget change). Production Apply remains interlocked and no live root was
touched.

## Task 9 Phase 2 checkpoint (2026-09-13): Steps 1, 2, 4, and 5 recorded; Step 3's unified pass running

Step 1 (focused suites): home-authority, live-plan, backup-receipt, sync, live-recovery,
backup-recovery, and live-concurrency all passed standalone with exit 0. The roadmap's
`tests/live-hard-kill.tests.ps1` filename has no counterpart in the tree — the kill-window
coverage is `tests/canonical-hard-kill.tests.ps1` (in the unified pass) plus live-recovery's
kill/replay fixtures (Task 6 Step 4), recorded here as the mapping.

Step 2 (artifact validation): registered artifact validation passed 28 contracts / 28 positive /
113 negative fixtures with zero failures, covering root claims v1, current-env-state v3,
sync-plan v3 (initial/retirement), backup receipts, live journals/headers/results, and the
rollback/recovery plan v1 with every negative fixture failing at its declared layer.

Step 4 (requirements and quality review): a bounded read-only independent review (four files,
≤15 findings, severity-rated) of the Task 7/8 delta returned **VERDICT: PASS** with six P2
findings and no P0/P1. Checklist verdicts: lock timing, unknown/`.system` no-read behavior,
current-retirement evidence preservation, journal durability, and recovery cleanup all explicitly
no-defect; design compliance carried two documentation-drift notes and receipt finalization one
internal-cross-check note. Disposition: the two documentation drifts, the missing source-receipt
verification and claims/state preimage cross-checks in the execution composition, and the
discarded WaitForExit result were fixed in `24dcabe` (both affected suites re-run green); the
engine's hash-based per-target drift protection (the plan's `Current` identity binding is not
enforced by the existing ladder) is recorded as a boundary, consistent with the reviewed
hash-based engine ladder.

Step 5 (real homes untouched): the tracked policy remains `ReleaseState=interlocked`, the working
tree is clean at the checkpoint commits, and the public rollback surface fails closed on real
homes with `live-plan-host-resolution-required` (pinned in harness-env 9.10); all test traffic ran
inside sandbox homes with capability gating, and the real live roots' read-only listing shows the
owner's own content intact.

Step 3 (full runner and repository gates): the repository gates passed on the checkpoint tree —
parse gate 167 files, `build-skills.ps1` 7/15/7, secret scan with no blocking findings, doctor,
unstaged/staged `git diff --check`, and the build-clean gate with exactly the four protected
Reasonix literal negative pathspecs on the committed tree. The first create-new external unified
pass (on the `95b6772` tree, 6864 s) returned 37/38 with exactly one failure —
`canonical-production-seams` — and its cause was a process omission, not a product defect: the
review fixes in `24dcabe` added six reflection-sensitive sites to the rollback execution
composition and the all-scripts inventory baseline was not re-pinned in that commit (count
14715 → 14721; the dynamic-command digest unchanged). The baseline was re-pinned in `0c348c3`
(seams 56/0 standalone; the failed pass's external summary was recorded and deleted), and the
authoritative unified pass reran on that tree. **The definitive pass discovered, started,
completed, and passed all 38 suites exactly once with zero failures, timeouts, duplicates, missing
suites, or tree-kill failures, in 6886 s**: hard-kill 2365 s, root-claims 1567 s, live-recovery
442 s, sync 421 s, backup-recovery 264 s, seams 218 s, live-concurrency 66 s, harness-env 40 s.
Its external summary SHA-256 is
`bdbe7713b20ca618bc1af4035fa8452c60dcb1dfde313f527d2ea102acc7d581` (356948 bytes, deleted after
this record), its DiscoveryHash is
`bca55823225ad6bfb5769b99b4cd7f4c60abcd546cab63b470b81d850d7ae137`, and its computed job
requirement is 23685 s, under the 400-minute workflow bound. **With this the Task 9 checkpoint and
Phase 2 live-safety hardening are complete**: Tasks 1-9 all closed, with the two recorded
design-bound items (the cross-authority root-claim overlap rejection and the rollback execution's
production caller) assigned to the Phase 3/4 boundaries, and the production interlock unchanged.

## Phase 3 Task 1 (2026-09-13): lock 3 freeze verified, artifact graph pinned, separate legacy/shared readers

Step 1 (artifact graph tests): created `tests/harness-authority.tests.ps1` (157 assertions after the
review fixes; measured 11.4 s locally, and given an explicit 300 s suite budget alongside the other
subprocess-heavy suites rather than the 120 s default). The lock graph
is emitter-derived: a real environment is materialized in an isolated fake repository and the emitted
`env.lock.json`/`env-build.json` are inspected directly.
It asserts the lock carries exactly the frozen schema 3 field set, validates against
`schemas/harness-env-lock.schema.json`, covers all three platforms in every hash/task map, binds its
manifest, staged-tree, source, built-file and profile-output hashes to the real files, carries no
self `LockHash` and no plan/receipt/journal/state hash field, and that the build sidecar binds the
exact emitted lock bytes (sidecar→lock only; the lock never references the sidecar). The state-graph
section asserts a schema-valid state carries exactly its branch key set, stores no
`AuthorityStateHash`/`StateHash`/`TargetContextIntent`/`LockHash`, binds the exact claims bytes
(`RootClaimsHash` = SHA-256 of the claims file), binds its own `FinalTargetContextHash` projection,
and that the registered `self-hash`, `target-intent`, and `final-target-hash` negatives stay
registered at the Schema layer.

Step 2 (freeze lock schema 3): verified, no shape change. The schema already requires the complete
semantic field set with `additionalProperties: false`, so no self hash or graph-forward reference is
representable; the new emitter-derived assertions pin that behaviour.

Step 3 (Phase 2 materialization producer): verified through the harness-env suite (112 assertions,
`staging=built`/empty-root/status transitions) plus emitter-derived v3 negatives in the new suite
(mutated sidecar `SchemaVersion=2` → `env-build-schema-unsupported`; removed Reasonix root →
`env-build-missing-platform-root`; drifted `MaterializationHash` → `env-build-hash-mismatch`) and an
empty-Reasonix-subset emission (root exists, `FileCount` 0, lock still schema 3).

Step 4 (discriminated shared-state branches): verified, no shape change. The new suite pins the
state schema's three branches: the initial branch requires ReceiptId/ReceiptHash and pins named
`full`, the receipt-bearing branch enumerates exactly
`environment|task-overlay|migrate|adopt|repair-adopt|retirement|environment-rollback`,
`controller-transition` requires `ReceiptRef=NO_LIVE_MUTATION` and forbids receipt id/hash, and no
`live-recover-*` kind is a committed-state branch. `tests/home-authority.tests.ps1` (its schema and
branch sections) stays green.

Step 5 (frozen authority plan branches): verified. The new suite pins the sync-plan operation-kind
enum and the fixed evidence fields of the four authority branches: migrate
(`LegacyLocator`/`LegacyHash`/`LegacyCoreHash`/`OldLockHash`), adopt (`LegacyEvidence`),
repair-adopt (`StateEvidence`), controller-transition (`ControllerParity`); `environment-rollback`
and every `live-recover-*` kind are asserted absent from sync-plan. No new authority plan is emitted
by this task.

Step 6 (separate legacy/shared readers): implemented. `Read-LegacyHarnessEnvState`
(`scripts/harness-env-common.ps1`) captures the exact bytes of the repo-local schema 2 evidence only,
returning `MISSING`/`CORRUPT`/`VALID` plus bytes/hash/document; it never reads or writes the shared
ControlBase state or claims and never deletes or moves the legacy file. `Read-HomeAuthorityState`
(`scripts/shared-authority-state-common.ps1`) reads only
`ControlBase/homes/<HomeAuthorityKey>/{root-claims.json,current-env.json}` through the no-follow
exact-byte capture, validates each artifact with its schema and semantics, and reports
`ClaimsStatus`/`StateStatus`/`PairStatus` (`VALID`/`MISMATCH`/`MISSING`/`CORRUPT`) without taking a
lock; the existing loose `Read-HarnessEnvState` display reader is unchanged so legacy consumers keep
their current behaviour until the Task 6/7 retrofit. The new suite covers both readers end to end
(missing/claims-only/valid/mismatch/corrupt cases, key-spelling rejection, zero-byte-change
snapshots, and mutual blindness between the two locator families).

Step 7 (verification): the new suite's state/lock sections pass (157/157, exit 0, including the
exhaustive 64-combination pair-status matrix); `harness-env`
112/112, `sync` PASS, `home-authority` PASS, `test-runner` PASS; registered artifact validation
passed 29 contracts / 29 positives / 118 negatives with zero failures (the new `harness-env-lock`
contract adds 5 graph negatives, all failing at the Schema layer); the production seams inventory
was re-pinned twice for the new modules (finally reflection-sensitive sites 14780, digest
`955df89694c4f60d13855e8664ce82802dcde6f7c2ab063f8017c49ce5dc6a34`) and the seams suite is 56/56;
parse gate 168 files; secret scan clean; `git diff --check` clean. The unified regression over the
full suite catalog (launched before the bounded-review fixes) reported
`Test summary: PASS; discovered=39; passed=39; failed=0; timed-out=0` in 7859.7 s, external summary
SHA-256 `a389aa306686483bf59ab9c596b83905973823b1c037370cf2d2e3857c1c0364` (deleted after the record),
mtime 2026-09-13T15:42:11Z. The production and test changes in the review fixes are additive for the
modules the earlier suites exercise (zero deletions across both production files), and every affected
suite was re-run standalone on the frozen tree afterwards (see the Step 7 line above and the review
paragraph below), so the pass transfers to the frozen tree; the whole-phase definitive pass stays
with the Task 9 checkpoint.

Review (bounded, read-only, implementation stage): a bounded independent review of the Task 1 delta
(5 files, ≤10 findings, each with severity and a triggering scenario) returned nine findings with no
P0/P1 and no defect in the registered lock contract or its fixtures. Disposition in `d7fe10f`: a
missing pinned schema validator was mis-classified as CORRUPT (healthy evidence could route to
repair-adopt) and now reports UNAVAILABLE; the directory key is bound to the claims document so a
copied pair under a foreign key is MISMATCH; a UNC ControlBase is rejected; the legacy reader's lossy
casts no longer accept `"2"`/non-string names, it carries an `Error`, and its byte read is guarded;
the reader contract now states that "no lock" means no authority lock with no writes under
ControlBase or the repository (schema validation does run the pinned validator as a child process
with its own lease and temp files); and the test gaps were closed (inner hash-map key sets, the
identity-drift MISMATCH half, the claims/state status-matrix cases, four tautological assertions, a
dead variable). Residual boundaries recorded rather than fixed: a transient pinned-validator process
failure still classifies as CORRUPT with its `Error` text (the availability pre-check covers the
not-installed case), and the legacy reader follows reparse points because it deliberately stays
outside the sealed json-artifact layer while the migration plan revalidates location and identity
under its locks.

Implementation commits: `8f75dda` the two readers plus the suite and the seams re-pin,
`b9b00d0` the `harness-env-lock` contract and its five graph negatives, `29e3607` the content-bound
lock assertions, `a8f2981` the legacy-reader rationale comment, `d7fe10f` the bounded-review fixes
and the second seams re-pin (14771 → 14780).

Production interlock is unchanged; no real home, ControlBase, legacy state, or live root was
touched, and no plan/Apply surface was added. Task closeout feedback loop: the upstream check (see
`docs/ZCODE.md`, sixth closeout) contributed the verification-as-pinned-assertions method to
`harness-model` as `44b6b03` and re-imported its clause into this project's rule entry.

## Phase 3 Task 2 (2026-09-13): authority-aware read-only status (list/status v2)

Step 1 (status-route fixtures): fifteen registered fixtures cover the route matrix: the list and
status positives, plus Schema-layer negatives for `unknown-property`, `wrong-version`,
`missing-reasonix-count`, `wrong-route`, `probed-status`, `capability-hash` and
`intended-root-on-claims` (list) / `backup-reference` (status), and Semantic-layer negatives for a
route/facts contradiction and a next-operation mismatch. The emitter positives are exercised
directly: `tests/harness-authority.tests.ps1` validates real assessment output against the schema
through the contract validator, and `tests/harness-env.tests.ps1` asserts the CLI-level documents.

Step 2 (list/status schemas to version 2): both documents now carry one shared `Authority` object -
route, one recommended next operation, redacted `HomeAuthorityKeyLabel`, controller match, recovery
status with the unfinished transaction ids, root-claims/state/pair statuses, a state summary
(environment name, generation, last operation kind, receipt reference and hash, lock and overlay
hashes), per-platform live-root purity, lock-bound live parity with reasons and mismatches, the
legacy schema/gap/drift/old-lock/parity block, and the intended-root branch. Status rows carry
`ReasonixSkillCount`; `Active` gains `Source` and drops the clone-local `BackupReference`; the
intended-root branch is frozen here (required `RequestedInitialRootContextHash` and
`FilesystemCapabilityStatus=UNPROBED`, optional redacted `RequestedReasonixRoot` only for
`explicit-initial-claim`, present only for initial/migrate/adopt, and no branch may contain a
capability hash or probe artifact). Both kinds are registered with
`SemanticValidator = Test-HarnessEnvAuthorityDocumentSemantics`, which recomputes the route with the
same frozen decision function and checks the cross-field invariants. The CI env list/status
assertions moved to schema 2 and additionally assert the metadata-only intended-root branch.

Step 3 (status stays read-only): the new assessment takes no lock, creates no authority, writes no
plan, and its only writes are the requested `-JsonPath` documents. A whole-fixture-tree snapshot
test proves an assessment call changes no byte anywhere; the intended root is resolved through the
MetadataOnly target context (no probe, no temp file, no capability hash); production interlock
untouched.

Step 4 (deterministic routing): `Resolve-HarnessEnvAuthorityRoute` is the single decision function,
shared by the assessment and the artifact validator. Recovery wins over everything when a live
journal is unfinished. Unvalidatable or corrupt claims are manual; a valid pair is activate on the
current controller, takeover on a foreign controller only with passing state-bound live parity, and
`controller-owner-action-required` otherwise; valid claims with a corrupt or missing state are
repair-adopt; with no claims, complete internally consistent legacy evidence plus a byte-verified
old lock and passing old-live parity migrates, untrustworthy or inconsistent evidence adopts as
untrusted, and only fully pristine roots start initial. Live parity compares per-skill staged trees
from the verified lock and follows the immutable claim's resolved roots after migration; unknown
live skills are never treated as managed and `.system` is never traversed.

Step 5 (verification): six route groups are pinned end to end in the sealed fake-home matrix
(pristine, non-empty, explicit custom root, verified legacy migrate, legacy drift manual,
untrustworthy legacy adopt, missing/corrupt state repair-adopt, activate, owner action, takeover,
recovery, corrupt claims, pair mismatch) plus the exhaustive 388,800-combination matrix over the
resolver's own `ValidateSet` domains. Commits: `2e6cb85` the v2 contracts and producers, `46e447b`
the route-matrix and CLI tests, `fac75cc` the bounded-review fixes.

Review (bounded, read-only, implementation stage): ten findings, one P1 and two P2. The P1 was a
healthy-authority crash in the status surface (a nonexistent `-Path` parameter plus dictionary
indexing of the parsed lock) with no covering test; the branch was extracted into the shared
`Get-HarnessEnvAuthorityActiveSummary` and now has its own tests. The P2s were parity ignoring the
claim's resolved custom roots and malformed legacy evidence throwing instead of reporting CORRUPT;
both are fixed. The seven P3s (unsanitized legacy name in a path join, non-UUID transaction
namespace names breaking the document, unreadable state-bound locks escaping as exceptions, `list`
aborting on a corrupt legacy state, a tautological test assertion, an incomplete exhaustive matrix,
and a missing post-claims switch-rejection test) are all fixed in the same commit.

Verification (canonical `pwsh -NoProfile -File` runs): authority 223/223 in 31 s (300 s budget);
harness-env 131/131; task-skills 22/22 (its fake repository now copies `schemas/` because status
composes the authority readers and fails closed with `harness-authority-status-repo-layout-required`
otherwise); agent-dotfiles 16/16; live-plan 121 PASS; sync PASS; artifact validation 31 contracts /
31 positives / 133 negatives with zero failures; seams 56/56 after re-pinning (reflection-sensitive
sites 15068 after the parse-gate extension, dynamic-command digest `66456c02...`); parse gate
169 files; secret scan clean;
`git diff --check` clean. The unified regression over the full catalog (launched on the `fac75cc` tree at
2026-09-13T17:22:11Z) reported `Test summary: PASS; discovered=39; passed=39; failed=0;
timed-out=0` in 7105.4 s; its external summary SHA-256 is
`61c766f0dcc03391fe47262106eecb19f6ce330e951891e9548727b8846e55e7` (deleted after this record) with
a post-run mtime of 2026-09-13T19:20:35Z. The only production change made while it ran was the
parse-gate parameter-name check (no suite invokes that script) plus additive assertions in
`tests/harness-env.tests.ps1`, and that suite ran afterwards with all 131 assertions, so the pass
holds for the final tree. The whole-phase definitive pass remains with the Task 9 checkpoint.

## Phase 3 Task 3 (2026-09-13/14): the `env authority` command surface

Step 1 (routing/mode failures): `tests/harness-authority.tests.ps1` gains a sandbox CLI matrix over
the dispatcher (`env authority` without an action, an unsupported action, a transition without a
mode, both modes at once, status rejecting transition switches), over the transitions (missing name,
missing plan path, migrate-only/repaad-adopt-only/root-switch argument rejections, a transition that
is not the single current route), and over plan-path safety (a path inside the worktree and inside
Git internals are both refused by the shared external-artifact resolver).

Step 2 (status and planned transitions): `scripts/authority-harness-env.ps1` implements
`status|migrate|adopt|repair-adopt|takeover`. Status is strictly read-only and prints the single
route, its recommended next operation, and the claims/state/pair, recovery, legacy, parity and
intended-root facts. Each transition takes exactly one `-DryRun|-Apply` with a `-PlanPath`: DryRun
creates a new external plan (plus a create-new environment materialization for the branches that
need one) and Apply consumes only that exact existing plan, never regenerating it. `agent-dotfiles.ps1`
routes `env authority <action>` and gates the transitions on the explicit mode.

Step 3 (operation-specific context): migrate must receive the exact repo-local legacy locator on both
invocations and binds `LegacyLocator`/`LegacyHash`/`LegacyCoreHash`/`OldLockHash` (the core hash over
the frozen field subset) plus the name the legacy state recorded; adopt binds `LegacyEvidence`
MISSING or UNTRUSTED; repair-adopt binds the strict `StateEvidence` oneOf (CORRUPT: exact ControlBase
state path plus raw and preimage hashes; MISSING: marker only, path and hashes forbidden); takeover
maps to `OperationKind=controller-transition`, binds
`ControllerParity.PreviousControllerRepoFingerprint`, declares `ReceiptRef=NO_LIVE_MUTATION`, and
carries zero live actions. All four bind the complete `TargetContextIntent`, the platform slots with
their pre-identities, the managed actions, the preserve-only unknown-dir markers, and the measured
Codex `.system` marker; the live-root selector follows the immutable claim (or the validated
intended root) and never the platform defaults once an authority exists.

Step 4 (dispatcher behavior): the requested action must equal the route the read-only assessment
emits (`authority-route-mismatch` otherwise), Apply refuses a plan whose operation kind differs, the
intended-root switch is refused by the assessment once claims exist, and ordinary `sync` cannot plan
over an existing authority context (it can only ever emit `initial`/`retirement`).

Supporting refactor (`2d6bdf0`): the producer primitives sync.ps1 needed (host-root resolution,
target contexts and claim rows, platform slots, task-overlay/manifest binding, create-new
materialization evidence, the audited live-target guard, the hash helpers, `Write-PlanSummary`) moved
verbatim into `scripts/live-plan-evidence-common.ps1`; `New-LiveSyncMaterializationEvidence` gained
`-Name`; and the frozen sync-plan shape now admits `scripts/authority-harness-env.ps1` as a second
generator for the four authority branches (schema enum + kind spec) while the sealed fixtures keep
their own generator.

Verification: authority 290/290 (sealed fake home, 38 s against the 300 s budget); agent-dotfiles
23/23; harness-env 131/131; task-skills 22/22; live-plan 121 PASS; sync PASS; artifact validation
31 contracts / 31 positives / 133 negatives PASS; seams 56/56 after re-pinning (reflection 15245,
dynamic digest `26697519...`); parse gate 171 files; secret scan clean; `git diff --check` clean. The
parameter-name gate caught three real defects in this slice (two guessed `-Path`/`-DocumentPath`
parameters and one missing mandatory parameter hidden by a pipeline), and the seams policy required
routing the producer's validation through the reviewed `Assert-LiveSyncPlanDocumentIntegrity` gate
instead of calling the semantic validator directly. Commits: `2d6bdf0` the shared-module refactor,
`bdf9073` the command surface.

## Phase 3 Task 4 (2026-09-14, complete): the authority apply composition

Settled decision (the open question from the recon handoff below): **the private
prefix belongs to the reviewed canonical setup flow, not to the authority
apply.** `New-CanonicalFinalSetupState` cannot even be created without the
ControlBase/BackupRoot roots, and the canonical host's own lock order acquires
them existing-only, so a live transition must never bootstrap a second time or
compose a competing private-root creator. Adopt and migrate therefore *require*
a `canonical-ready` repo and a COMPLETE prefix, failing closed with the canonical
status token (`canonical-setup-required` and friends) instead of a raw
`canonical-lock-missing`.

Implemented (`d7e81b1`):

- `Invoke-SealedLiveTransactionHost` now admits `adopt`, `migrate` and
  `repair-adopt` next to `initial`/`retirement`. Per-kind guards: adopt/migrate
  require claims and state absent but keep the live-pristine requirement out
  (they exist precisely for machines whose live roots already hold content);
  repair-adopt requires the immutable claims to match the plan's exact bytes
  while tolerating a MISSING or CORRUPT state. The claims-binding block is
  extracted (`Assert-SealedLiveTransactionHostClaimsBinding`) and shared by the
  repair and existing-authority branches.
- First-authority claims creation covers adopt/migrate (the state step already
  handled create-new claims versus proving existing bytes, and both a present
  and a missing/corrupt state), and the managed backup receipt pre-images the
  authority state and claims for every kind that changes them.
- `scripts/authority-harness-env.ps1 -Apply` composes: interlock, plan path,
  integrity, kind (with the exact legacy locator re-required for `migrate`),
  materialization currency, selection context, the canonical-status gate, the
  prefix gate, the plan-consumption gate, per-platform same-volume staging roots
  with mutation-preflight capability hashes, then the host. The script imports
  the home-authority and registry modules and no longer stops at
  `authority-apply-not-wired`. (The ordering sentence here originally placed
  consumption before the canonical/prefix gates; the code — and the Task 6
  section — runs the gates first.)

Verified at this boundary: authority 293/293 (including the new precondition
assertions - a transition apply stops at `canonical-setup-required` and
publishes no claims/state); live-plan 121 PASS; sync PASS; live-recovery PASS;
live-concurrency PASS; backup-recovery PASS; backup-receipt PASS; artifact
validation 31/31/133 PASS; seams 56/56 re-pinned (reflection 15262, dynamic
digest `aafc071a...`); parse gate 171 files; secret scan and `git diff --check`
clean.

Integration fix that the apply composition forced (`d1ee128`): the private
prefix envelope pinned every immediate child, so after the canonical setup wrote
its root claim at `<ControlBase>/canonical-roots/<64-hex>.json` any later
`Get-SealedHomeAuthorityBootstrapCompletionStatus` call failed with "unexpected
children under CanonicalRootsRoot". The snapshot now tolerates exactly that
shape (no-follow single-link regular `<64-hex>.json`), mirroring the existing
authority-aware tolerance for `HomesRoot`; this also unblocks `sync`'s apply on
a machine where the canonical setup has run.

**Resolved (see the Task 4 closeout below).** The blocker was the canonical
witness binding: the resolved path was to seed the canonical setup state, its
root claim, *and* the held witness inside the sandbox from the reviewed scripts
(the suite now dot-sources `root-claims-registry-common.ps1` once per process —
the sealed route registry accepts exactly one initialization per runspace and
refuses a reload built from fresh script blocks — and calls
`New-CanonicalSetupPlanPayload`/`New-CanonicalFinalSetupState` plus
`Enter-CanonicalRepoLock` with the correct toolchain root). The authority apply
then runs end to end for adopt, migrate and repair-adopt. The host's
`controller-transition` kind is still rejected by its kind gate, which is the
Task 5 entry point.

## Task 4 handoff (2026-09-14): apply-composition recon

The remaining Task 4 work is the apply composition for `migrate`/`adopt`/`repair-adopt`. The recon is
done; the facts a next window needs:

- Single host entry: `Invoke-SealedLiveTransactionHost` (`scripts/live-transaction-common.ps1:2261`)
  takes the reviewed plan plus repo/control/backup roots, per-platform staging/source roots, the
  probed `FinalCapabilityHashesByPlatform`, the authority context, the working-tree roots and the
  toolchain root; it acquires the existing-only live route (canonical repo lock, namespace witness,
  global live lock), revalidates the authority guards under that lock, publishes the receipt-backed
  journal header, runs the managed backup receipt, then the mutation engine.
- Kind gate: `$operationKind -cnotin @('initial','retirement')` → `live-transaction-operation-kind-unsupported`
  (`:2360`). Extending it to `adopt`/`migrate`/`repair-adopt` is the Task 4 entry point.
- Guard model (`Assert-SealedLiveTransactionHostGuard`, `:2470`): `initial` requires claims+state
  absent **and** every live root MISSING; the else branch requires claims+state present, the claims
  bytes hash equal to the plan's `RootClaimsHash`, and the claim rows to bind the target rows. For
  Task 4 the `adopt`/`migrate` branch must require claims+state absent **without** the pristine
  requirement (adopt exists for non-empty live roots), and `repair-adopt` must require the claims
  present and hash-bound while tolerating a MISSING or CORRUPT state. The claims-binding block is
  currently inline in the else branch and should be extracted for reuse.
- First-authority claims creation already exists in the state step
  (`Invoke-SealedLiveTransactionAuthorityState`, `:759`): claims absent → create-new from
  `AuthorityStateIntent['__ProposedRootClaimsBytes']` (`CLAIMS_PUBLISHED`), claims present → prove the
  bytes hash unchanged; the state step also handles both a present state (recovery-copy preimage plus
  replace) and a missing state (create-new), which covers the repair-adopt CORRUPT/MISSING branches.
  The host only feeds `__ProposedRootClaimsBytes` when the kind is `initial` (`:2600`); Task 4 must
  extend that to `adopt`/`migrate`.
- The public apply template is `sync.ps1`'s apply block (`~:955-1010`): bootstrap-status gate,
  per-platform staging roots under `<home>/.ai-agent-dotfiles-staging/<platform>` used as the
  mutation-preflight probe roots, `Resolve-TargetContext -Mode MutationPreflight` capability hashes,
  source/live roots from the plan slots, and `$toolchainRoot` = the controller repository.
- **The gap the next window must decide**: sync requires the authority prefix to be COMPLETE before
  applying, because activation bootstraps it. `adopt`/`migrate` are by definition the transitions
  that establish the first authority, so their composition must run the Phase 2 sealed bootstrap
  (`New-SealedHomeAuthorityBootstrapIntent` + `Complete-SealedHomeAuthorityBootstrap`, currently
  unreferenced by any production CLI) before the host can take the existing-only route. `repair-adopt`
  and `takeover` need only a COMPLETE prefix. This decision (bootstrap inside the authority apply vs a
  separate reviewed setup step) is the first thing Task 4 must settle, because it defines what
  `-Apply` composes and what the branch tests inject around.

## Phase 3 Task 4 closeout (2026-09-14): end-to-end transitions and the four failure windows

Task 4 is complete at 5/5 steps. Adopt, migrate and repair-adopt now run through
`Invoke-SealedLiveTransactionHost` end to end inside the sandbox; the four
required failure classes are pinned as hard-killed windows; and the unit
boundary (a refused apply publishes neither claims nor state) stays covered.

Branch matrix now pinned by `tests/harness-authority.tests.ps1` (369 assertions):

- adopt on a machine whose live roots already hold content: publishes the
  immutable claims and the schema 3 state, installs the managed skills,
  preserves the unknown live directory, materializes the absent Reasonix root,
  publishes a journal namespace, and refuses a replayed plan.
- migrate on its own first-authority machine: binds the exact legacy
  locator/bytes/core hash and the preserved old-lock hash, installs the current
  build, and never deletes the only legacy evidence.
- repair-adopt: CORRUPT state replaced with claims byte-identical, state
  rebuilt, and — newly covered — the MISSING branch (marker-only evidence,
  `-CorruptStatePath` forbidden, state created new next to the claims).
- takeover DryRun for a foreign controller with verified parity (the previous
  controller fingerprint, zero live actions, `ReceiptRef=NO_LIVE_MUTATION`, no
  materialization root), plus the route refusal while the current controller
  still owns the authority.
- claim-identity drift: a claimed root that was deleted and recreated refuses
  the plan with `authority-claim-identity-drift` and writes no plan file.

Failure injection (Step 5) — one fresh machine per window, hard-killed through
the Phase 2 failpoint controller, each pinning the last durable record, the
live/claims/state/result evidence and the next apply's refusal:

| Window | Last durable record | Live | Claims | State | Result | Next apply |
| --- | --- | --- | --- | --- | --- | --- |
| `RECEIPT_FINALIZATION` (before the receipt) | none | absent | absent | absent | none | `live-recovery-required` |
| `PREPARED` (during live mutation) | `PREPARED` | absent | absent | absent | none | `live-recovery-required` |
| `STATE_REPLACE_PENDING` (state create/replace) | `FILE_REPLACE_INTENT` | installed | published | absent | none | `live-transaction-authority-present` |
| `TERMINAL_RECORD` (final journal record) | `POSTCONDITIONS_OK` | installed | published | published | published | `live-transaction-authority-present` |

Defects found and fixed by exercising the success paths (all in this window):

1. **Stale target rows** (`scripts/authority-harness-env.ps1`): the producer
   fed the immutable claim rows into `TargetContextIntent.Rows`, so the host
   derived a stale `MissingRemainder` and tried to create `~/.codex`, which the
   adopt apply had already created; the engine failed closed and the restore
   verification then raised `live-transaction-recovery-required`. Rows are now
   one fresh observation per platform, shared with the first-authority claim
   rows; the live trees themselves were restored intact (verified by comparing
   every plan `LiveHash` against the on-disk tree hash).
2. **Claims branch keyed on the wrong status**: repair-adopt selected the
   existing claims only when `PairStatus -eq 'VALID'`, but its pair is CORRUPT,
   so it silently proposed new claims and bound their hash. It now keys on
   `ClaimsStatus -eq 'VALID'`, and the live roots are selected from the claim
   (the state is not readable while being repaired).
3. **Claims-identity drift**: with fresh rows, a deleted-and-recreated claimed
   root would have published a state whose final identity contradicts the
   immutable claim — a pair no later repair could fix. The producer now
   requires the observed identity to equal the claim's for every
   `InitialState=EXISTS` row and fails closed with
   `authority-claim-identity-drift` before any plan exists.
4. **Staging blocked consecutive updates**: the engine preserves swap-old as
   durable evidence after a terminal commit, and nothing reclaimed it, so the
   *next* transaction for the same skill name failed its staging precondition
   (`Test-Path swapOldPath`). The host now reclaims `staged/<name>` and
   `swap/<name>` for this plan's own target names at transaction start, after
   the namespace proved no unfinished transaction exists (so no live recovery
   evidence can be involved). The engine's post-commit preservation contract
   and its pinned assertion stay unchanged; the rollback composition's own
   post-success cleanup remains Task 6 work.
5. **MISSING-state guard**: `Assert-SealedLiveTransactionHostClaimsBinding`
   tripped on `''` vs `$null` for an absent state file, so the repair-adopt
   MISSING branch could never start. The check now accepts an absent state hash
   and still requires a 64-hex digest when the file exists.

Two smaller fixes from the independent review: the receipt pre-images the
authority state only when the file exists (a MISSING repair state has no bytes
to preserve, and the held capture throws on a missing path), and the dead
`PairStatus` fallback in the live-root selector was removed.

Verification: authority 369/369; live-plan 121 PASS; sync, live-recovery,
live-concurrency, backup-recovery, backup-receipt PASS; canonical-transaction
64/0; canonical-transaction-apply 21/0; transaction-journal-exact-byte 12/0;
artifact validation 31/31/133 PASS; seams 56/56 re-pinned (reflection 15281,
digest `ace4d87820a264b7d6300dde8190e7d33d9afc4566c2936516144c0bfa51ccc0`,
dynamic digest unchanged); parse gate 171 files; secret scan and
`git diff --check` clean. The unified `run-tests.ps1 -All` pass stays Phase 3
Task 9's checkpoint.

## Phase 3 Task 5 (2026-09-14, complete): controller takeover

Task 5 is complete at 4/4 steps: the controller identity, the valid-parity
requirements, the state-only `controller-transition` apply, and the public
success/failure matrix.

Controller identity (`scripts/canonical-transaction-common.ps1`):
`Get-CanonicalNormalizedRemoteIdentity` projects `remote.origin.url` without
credentials — userinfo is stripped, scheme and host are lowercased, query and
fragment text is dropped, a trailing `.git` and trailing separators are
removed, scp-like `[user@]host:path` normalizes to `host:path`, a local-path
remote keeps its lowercased `/`-separated path form, and a repository without an
origin reports `none`. `Get-CanonicalControllerIdentity` combines that
projection with the Git-common-dir private repository identity, so linked
worktrees share one controller while a fresh clone of the same remote is a
different controller. Every controller-fingerprint producer and consumer now
uses it (`sync.ps1`, `authority-harness-env.ps1`, `harness-authority-status-common.ps1`,
and the host's under-lock parity proof); the canonical repo identity itself is
unchanged and still owns journal/claim/recovery identity.

Parity requirements: takeover DryRun still routes through the read-only
assessment (valid claims+state pair, passing state-bound lock parity against the
live managed trees, no pending recovery, unknown/`.system` markers bound, no
materialization root), refuses a takeover while the current controller owns the
authority (`authority-route-mismatch`), refuses a name the authority does not
select (`authority-selection-name-mismatch`, new token), and a foreign
controller with failing parity keeps routing to
`controller-owner-action-required` (pinned by the route-matrix assertions). The
retirement producer now refuses to plan when the state names another controller
(`controller-owner-action-required`), which closes a forward-migration trap:
its payload binds the current controller while its intent copies the state's,
so a foreign or pre-normalization state could otherwise only fail later at
apply.

State-only apply: the host admits `controller-transition`, still acquires the
canonical repo lock → namespace witness → global live lock in that order, and
after the unfinished-transaction gate proves parity under the lock — the plan's
previous fingerprint must equal the locked state's controller, this repository's
controller identity must differ, and the plan's intent fingerprint must be that
identity — before it publishes a `TransactionMode=state-only` header with
`ReceiptRef=NO_LIVE_MUTATION` and no receipt intent, runs
`Invoke-SealedLiveTransactionStateOnly`, and returns the committed state/result
hashes with no receipt. The engine's frozen preservation contract
(`Assert-AuthorityControllerTransitionPreservesSelection`) keeps the selection,
lock, task, final-managed, final-identity and claims fields intact.

Two engine-side scratch defects surfaced while making consecutive state
transitions work, both fixed in the host's transaction-start reclaim (under both
locks, after the namespace showed no unfinished transaction, and limited to this
plan's own target names): a completed predecessor's `swap`/`staged` content
blocked the next transaction's staging, and its
`state-recovery/current-env.preimage.json` copy blocked the next state replace
(both are `FileMode::CreateNew` scratch names). The engine's post-commit
preservation of swap-old and its pinned assertions are unchanged, and the
reclaim deletes only the preimage file, not the recovery directory.

Verified: authority 405/405 (new: takeover Apply state-only, replayed
takeover parity refusal, wrong-name refusal, plan-layer `ReceiptRef`/`ReceiptId`
rejections, state-preimage disappearance refusal with no journal namespace, and
the public `STATE_REPLACE_PENDING` kill window leaving the previous controller
bytes byte-identical with `FILE_REPLACE_INTENT` as the last durable record and
the next apply refused as `live-recovery-required`); canonical-recovery 118/0
(new controller-identity and remote-projection assertions: worktree sharing,
clone distinctness, credential-free projections for https/userinfo, scp-like,
ssh, query/fragment and local forms); live-recovery PASS (engine-level state-only
kill/recovery matrix reused unchanged); sync PASS; live-concurrency PASS;
backup-recovery PASS; backup-receipt PASS; canonical-transaction 64/0;
canonical-transaction-apply 21/0; transaction-journal-exact-byte 12/0; live-plan
121 PASS; artifact validation 31/31/133 PASS; seams 56/56 re-pinned (reflection
15321, digest `9f1b3bc9c835d316942b8ed61781018663076267b2836d6b2945283e14dab0a3`);
parse gate 171 files; secret scan and `git diff --check` clean. The unified
`run-tests.ps1 -All` pass stays Phase 3 Task 9's checkpoint.

An independent read-only review of the delta confirmed the identity projection
and its consumers, the host branch's lock ordering and gate coverage, the reclaim
safety and the new tests, and produced five findings, all adopted: the kill-window
journal lookup is order-dependent (now sorted by write time), the retirement
controller binding above, the local-path projection bypassing the shared
trim/`.git` step, query/fragment text surviving the projection (and no remote-form
coverage at all — now tested), and the reclaim being broader than necessary.

## Phase 3 Task 6 (2026-09-14, complete): external-plan activation and the exact receipt

Task 6 is complete at 8/8 steps. `scripts/activate-harness-env.ps1` is now a
plan producer + plan consumer instead of a gate chain that stopped at
`activation-deploy-not-wired`:

- DryRun (mandatory `-PlanPath`) resolves the authority root trio (explicit or
  host-injected; a partial selection fails closed and there is no USERPROFILE
  default), runs the unchanged gate chain (build-skills, scan-secrets,
  build-harness-env, `Test-HarnessEnvLock`), creates and revalidates the
  reviewed create-new `<plan-stem>.materialization` (three platform source roots
  including empty subsets, env-build v3 sidecar, frozen lock schema 3), requires
  the read-only authority route to be exactly `activate`, reads the shared pair,
  selects the live roots from the immutable claims (with the reviewed
  `authority-claim-identity-drift` refusal), and writes one
  `OperationKind=environment` plan whose intent carries the live claims-bytes
  hash, the materialization lock hash, generation+1, fresh observed target rows
  and `LastOperationKind=environment`. The document passes
  `Assert-LiveSyncPlanDocumentIntegrity` before a byte is written; a path
  collision fails closed.
- Apply consumes only that exact plan: the production interlock is the first
  gate, then path/private-artifact rules, integrity, kind, generator,
  materialization currency, source-root revalidation, build/lock shape reread,
  `Test-HarnessEnvLock` against the current repository, selection context,
  controller identity, a pre-host `prune` refusal (an activation plan only adds
  or updates), the canonical and prefix gates, the consumption gate, staging
  roots + `MutationPreflight` capability hashes, then the Phase 2 host. It never
  builds, scans or rewrites the plan, refuses the preview-only skip switches,
  reports the host's exact `ReceiptId`/`ReceiptPath`/`ReceiptHash`/`StateHash`/
  `TransactionId`/`JournalDir` (SchemaVersion 2 summary), and no longer contains
  `Get-LatestBackupReference`, any `sync-backup-*` scan, or any repo-local
  `state/current-env.json` resolution: the legacy file stays byte-identical as
  migration evidence while the shared authority state is what the transaction
  installs.
- The `environment` kind got its public generator (`scripts/activate-harness-env.ps1`)
  in the plan spec and the sync-plan schema, and the host admits it (the
  existing-authority guard already covered it). It requires the materialization
  root with an EXISTS control base and all three live slots EXISTS, forbids
  `ProposedRootClaims` and the legacy/task/parity evidence branches, and binds
  `AuthorityStateIntent.EnvironmentLockHash` to the bound materialization lock.

**Plan consumption landed here** (the carried item from Task 4/5):
`Get-SealedLiveTransactionTerminalDocumentHashes` (read-only, in
live-transaction-common) collects the `OriginalDocumentHash` of every journal
namespace whose chain carries the final `COMPLETE` record; unfinished,
unreadable or unknown-entry namespaces are skipped because the host's recovery
gate already refuses them. The activation, authority and sync apply paths pass
that evidence to `Assert-LiveSyncPlanDocumentHashNotConsumed` after the
canonical/prefix gates and before any staging work, so a completed plan cannot
mutate twice. The replay refusals in all three surfaces now assert the
`live-plan-consumed` token.

The environment receipt also pre-images the authority files now (`environment`
joined `retirement`/`repair-adopt` in the host's receipt arguments), which the
receipt-based rollback surface requires (`rollback-preimage-missing` otherwise)
and which activation — the only real producer of `SourceOperationKind=environment`
— needs to be rollback-eligible.

Recorded narrowing (Task 7 handoff): the task-overlay CLI's preview and apply
paths fail closed (`activation-root-selection-incomplete` and
`overlay-plan-required`) instead of delegating a gate-chain preview that no
longer exists; the task-overlay plan producer, its roots and the worktree
overlay lock are exactly Task 7's Step 3 work. `docs/README.md` §16 was updated
to describe the producer/consumer contract and the legacy-state change.

Verified: harness-env 311/0 (producer/consumer matrix for the empty, single and
multi subsets across all three platforms, plus the failure matrix: missing
`-PlanPath`, path collision, in-worktree/in-Git plan paths, non-environment plan,
wrong name/lock/controller, changed materialization, changed task overlay,
v2 sidecar, skip switches on apply, root-transition request, a foreign
latest-directory decoy under the receipt root, a `STATE_REPLACE_PENDING` kill
leaving the previous state byte-identical with `live-recovery-required` next, and
the legacy-state/claims byte-identity plus no-scan/no-legacy-write text bans);
harness-authority 406/0; task-skills 22/0; live-plan 121 PASS; sync PASS;
live-recovery PASS; live-concurrency PASS; backup-recovery PASS; backup-receipt
PASS; canonical-transaction 64/0; transaction-journal-exact-byte 12/0;
agent-dotfiles 23/0; artifact validation 31/31/133 PASS; seams 56/56 re-pinned
(reflection 15423, digest `3e19718cadcce53292a777652ad2e9811d3df05eaf77cd95d409d9918405cdba`);
parse gate 171 files; secret scan clean after renaming a token whose
`sk-` substring tripped the OpenAI-key pattern; `git diff --check` clean.

An independent read-only review of the delta confirmed the producer binding, the
apply gate order and the failure matrix and produced nine findings; all adopted
except where noted: the environment receipt preimages above; the plan-consumption
binding above; the pre-host `prune` refusal; the README/records updates; the
task-skills narrowing comment; the summary writer's unreadable-lock guard; two
test-quality fixes (the vacuous unknown-env assertion and the reinstated
inside-the-repository home refusal); and the helper comment scope. One finding is
recorded rather than fixed: an activation plan produced against authority
generation N can still be applied against generation N+1 (nothing enforces
monotonicity), which mirrors the reviewed Task 4/5 transitions and mutates only
the plan's own reviewed selection.

## Phase 3 Task 7 (2026-09-14, complete): three-platform, plan-bound task overlays

Task 7 is complete at 5/5 steps. `scripts/task-skills.ps1` is now a plan
producer + plan consumer for the task overlay:

- All three platform baselines are required in the shared state and the bound
  lock; a missing or legacy (schema 2) baseline produces a migration/manual-review
  refusal and is never treated as an empty addition-only overlay. The public
  `-Automatic` routing and the `-SkipBuild`/`-SkipSecretScan` gates are refusals
  after the interlock (their spellings stay so the automation-safety interlock
  pins remain meaningful), and `-TaskOverlayPath` other than the tracked
  `.agent-harness/task-skills.psd1` is refused.
- ensure/sync/close DryRun writes one external create-new `OperationKind=task-overlay`
  plan (generator `scripts/task-skills.ps1`, spec and schema now agree on the
  generator set) plus the `<plan-stem>.candidate.psd1` artifact; the payload's
  `TaskOverlayEvidence` binds the current and candidate hashes, the exact tracked
  path, the action and the removal-review flag, and the intent binds the
  materialization lock. Apply consumes only that plan: interlock, plan
  path/integrity, kind/generator, materialization currency, selection context,
  controller, canonical setup/authority, the consumption gate, the reviewed
  overlay pre-state + candidate artifact (a missing candidate is refused
  with the candidate-artifact mismatch token, never a rewrite from memory), capability
  probes, then the host.
- The tracked overlay file is journalled as a planned atomic file target:
  candidate staged beside the plan, an immutable preimage copy in the
  transaction scratch, then FILE_PREPARED → FILE_REPLACE_INTENT (re-observed
  immediately before the destructive move) → swap-old capture with hash
  verification (a raced editor/checkout change is put back and fails closed) →
  the staged candidate installed → FILE_REPLACED → postcondition re-hash.
  Failure before install restores the captured bytes; after install the
  transaction enters `live-transaction-recovery-required` with preimage and
  swap evidence retained.
- Lock order is canonical (GitCommonDir) → worktree overlay (new lock file
  inside the worktree's own Git directory, distinct per worktree) → global live
  lock, all zero-wait; the header binds `WorktreeOverlayLockKey` (frozen
  optional field) and the reviewed recovery dispatcher derives and revalidates
  it, so a dispatch from another worktree fails closed as
  `manual-recovery-required`. The recovery plan binds the overlay lock identity
  (also for a mutation-free abandon, because the lock order still acquires it),
  one overlay restore row per overlay/published pair, the preimage copy and the
  swap-old locator; rollback restores the preimage bytes. `schemas/artifact-contracts.psd1`
  needed no change and the frozen journal/rollback schemas were reused without
  shape changes (the overlay records reuse the allowlisted `TargetKind=state`
  and are distinguished by their exact path).

Three integration defects found while making the first apply pass and fixed
here: (1) the overlay swap scratch was created inside the canonical contract
root (`<GitCommonDir>/ai-agent-dotfiles/live-overlay-swap`), whose immediate
children the held namespace witness pins, so the release then failed with
`canonical contract-root inventory drift`; the swap now lives under the
worktree Git directory beside the overlay lock (same volume, outside the pinned
inventory). (2) `Restore-SealedLiveOverlayFile` rejected a state-rollback plan
that bound the authority-state preimage path (a legitimate Phase 2 field), which
broke the state rollback recovery; the no-overlay branch now refuses only a plan
that binds the overlay lock identity. (3) the recovery dispatcher used
`$authorityStatePath` without deriving it (StrictMode failure on the
committed-finalize path), and it now derives it once under the locks. Plus the
candidate-artifact path resolution tolerates the missing leaf so the dedicated
candidate check owns the refusal.

Verified: task-skills 92/0 (the three-platform baseline matrix and status, the
Reasonix ensure → baseline → sync → close path, missing/legacy baseline
refusals, plan producer/consumer semantics and schema, the tracked-file journal
records with preimage/swap retention, the consumed-plan replay refusal, the
changed-overlay-after-preview refusal, stale materialization, the missing
candidate artifact, the missing candidate check, a `FILE_REPLACED` hard-kill
window, recovery dispatch from a linked worktree, second-holder overlay-lock
`operation-lock-busy`, lock-free status, and preview never waiting on the overlay
lock); live-recovery PASS; harness-env 311/0; harness-authority 406/0; sync
PASS; agent-dotfiles 23/0; automation-safety PASS; live-concurrency PASS;
canonical-transaction 64/0; canonical-transaction-apply 21/0;
transaction-journal-exact-byte 12/0; backup-recovery PASS;
canonical-hard-kill-reap-semantics 27/0; `canonical-hard-kill` **is green:
318/0**. The re-seal in this commit (expectation values only, no check removed
or loosened) had already brought the reviewed-load manifest, the 24-row prelude
rows and digest, the pre-section token digest, the transport/transport-mutations
extent pins, the cleanup-gate self digest, the main-try extent, the top-level
execution digest, the function-inventory digest and the controller-surface sha
to their current values; the 12 failures I saw were the poisoning from runs that
predated the final file write (a single stale pin invalidates the cleanup
contract, which empties the behaviour-probe result set and fails its eleven
dependent assertions). Re-verified after the fact: full suite 318/0, primitives
section 95/0, reap-semantics 27/0, an isolated re-derivation of every
self-referential pin matches, and the behaviour probe runs its exact 20-case set
with zero residue. A pristine `git archive HEAD` copy of the repository shows
`canonical-production-seams` 56/56; the working tree showed 36/20 only while the
uncommitted Task 8 draft below was present;artifact validation 31/31/133 PASS; seams 56/56 re-pinned
(reflection 15668, digest `81bacf1b4fc984d19aad9205b51cf9470eae0efb9fd16bcad0173c04d076c807`);
parse gate 171 files; secret scan clean; `git diff --check` clean.

## Phase 3 Task 8 (2026-09-15, complete): selection-aware preview routing

Committed as `2ca0488` (implementation by the concurrent 2026-09-15 session). The
approved toolchain bundle now pins the authority/status/materialization/planner
dependencies plus a frozen `PreviewRouteActions` table keyed exactly by the
authority routes; explicit `setup.ps1 -ApproveRunner` refuses a table that
diverges from the frozen route set or that would materialize a build for a
diagnostic route, and drift over the extended bundle fails the hooks closed with
`runner-review-required`. The Git hook routes every trigger from the shared
authority state: pristine home → non-consumable `full` preview from an env-build
v3 materialization in user-temp scratch (removed in a finally block) plus the exact external DryRun command;
non-pristine → adoption diagnostic only; recovery/manual/repair-adopt/takeover/
migrate/owner-action → diagnostic-only with zero materialization; controller
mismatch decisions come from the authority route, not from clone-local state.
Drifted prior previews gain a stale sidecar and stay byte-identical; no branch
invokes Apply or exposes an internal Apply plan path. The matrix fixtures drive
the controller checkout and a linked worktree.

Verification: approved-runner PASS; automation-safety PASS; harness-authority
430/0; backup-recovery PASS (with `d6211c9` reclaiming the environment-rollback
staging scratch — the Task 6 carried item); task-skills 93/0; live-recovery PASS;
sync PASS; agent-dotfiles 23/0; canonical-hard-kill 318/0; reap-semantics 27/0;
artifact validation 31/31/133 PASS; seams 56/56; parse gate 171 files; secret
scan and `git diff --check` clean.

## Task 7 carry-over closed (2026-09-15, complete): the rollback staging reclaim

Committed as `d6211c9`. Phase 2 Task 7 Step 4 requires "cleanup swap-old/staged/pre-rollback copies
only after complete success; preserve all durable receipts/evidence on restore failure", and the
rollback composition reclaimed nothing. `Invoke-SealedEnvironmentRollbackTransaction` now calls a
new private `Remove-SealedEnvironmentRollbackStaging` after the engine returns, gating deletion on
three re-proven facts rather than on the call returning: the engine returned normally; a fresh
journal-chain read shows exactly one terminal `Phase=COMPLETE` record (`Outcome=committed`,
`ClosingKind=original`) with a matching committed result and this plan's
`OriginalPlanHash`/`OriginalDocumentHash`; and the reviewed chain validator accepts
header+records+result. Anything else reclaims nothing and still returns the committed result, so a
reclamation error can never turn a committed transaction into a reported failure.

Only this composition's own leaves are in scope: the `staged`/`swap` entry of each reviewed engine
target row, the path derived from the row as `<own platform staging root>/<area>/<target name>` and
never discovered by scanning, plus its own state-recovery preimage copy admitted only after
`Test-SafePathInsideRoot` proves containment in the composition's own staging roots.
`Assert-NoReparseExistingChain` refuses to follow a reparse point, and the journal, both receipts
(including the source activation receipt and its snapshot trees) and the authority state/claims are
untouched. `tests/backup-recovery.tests.ps1` grew from 155 to 188 assertions, adding the
success-path reclamation assertions and a failure-preservation section for both the
`failed-restored` restore path and the recovery-required path.

Verification: backup-recovery PASS 188; harness-env 311/0; canonical-production-seams 56/56 at
this commit, its re-pin derived by reproducing the suite's all-scripts inventory (byte-identical to
the tracked baseline at the previous commit) and reviewed site by site — reflection-sensitive
15668 → 15701, every added site a member/dispatch inventory entry of the new code, zero new
reflection types, zero new `Add-Type`/`Get-Command`/`Invoke-Expression` sites, dynamic-command
digest unchanged.

## Pending items (2026-09-14, after Phase 3 Task 3)

> **Superseded (2026-09-15).** This section is the position as it stood after Phase 3 Task 3.
> Everything it lists as "not started" has since landed, and the two items it names as waiting are
> both closed: Phase 3 Tasks 4-9 are complete (the checkpoint is `e57c608`) and the rollback
> execution's production caller was wired to the worktree overlay lock by `976d0fe`. The current
> list is "Pending items (2026-09-15, after the Phase 3 checkpoint and its review follow-ups)" at
> the end of this file. The text is kept as history.

**Phase 2 (Tasks 1-9) is complete and Phase 3 Task 1 is complete.** The remaining items are
design-bound or downstream:

1. **Phase 3 Tasks 4-9** — not started. Task 4 implements the reviewed migration, adoption and
   corrupt-state repair through the Phase 2 host (the Apply composition the command surface currently
   stops short of with `authority-apply-not-wired`), plus the full branch matrix; Tasks 5-9 follow.
   The two recorded design findings still feed the phase: the two recorded design findings still feed the phase: the
   cross-authority root-claim overlap rejection requires a machine-wide claim store (both
   authorities commit on a shared custom root today — see the Task 8 Step 4 finding), and the
   rollback execution composition's production caller waits for the Phase 3 worktree overlay lock
   primitive.
2. **Phase 4 schema/CI contract and safe release** — not started. Until the interlock is released,
   every production Apply/rollback/retirement returns `safety-protocol-upgrade-required`, and the
   rollback entry's validated Apply tail fails closed with
   `worktree-overlay-lock-not-implemented`.
3. **Before any future environment planning**: the stale commit-bound `minimal`, `work`, and `full`
   staging locks were rebuilt on 2026-09-13 (all three report `staging=built lock=valid` under the
   closeout HEAD; the generated `envs/` artifacts are gitignored machine-local state). This is
   artifact preparation only and does not authorize Apply.

Carried findings:

- **Sealed-file finding — closed 2026-09-15.** `tests/canonical-hard-kill.tests.ps1:8256` held a
  real instance of the operator-as-parameter defect (three intended taint checks parsed as one
  call, so two never ran). It was deliberately not bundled into `d6211c9`/`2ca0488`, because it
  changes a sealed analysis's accept/reject surface and needs its own re-seal, `-Section
  primitives` signal and full-suite verdict. The line fix, the retirement of the single parse-gate
  exemption and the re-seal are recorded in "Sealed-file operator-as-parameter slice closed
  (2026-09-15)" below.
- **Placement-pinned checkpoint**: `RECEIPT_FINALIZATION` is pinned at the source boundary because
  the production host is not yet run as a killable child.

## Safety boundary

Do not run production Apply, backup, rollback, retirement, or live mutation.
`safety-protocol-upgrade-required` remains the expected production result.

## Phase 3 Task 9 (2026-09-15, complete): the Phase 3 checkpoint

Five steps, all evidenced on the committed tree:

1. Focused suites: harness-authority 432/0, harness-env 311/0, task-skills 93/0,
   automation-safety PASS, agent-dotfiles 23/0, approved-runner PASS,
   backup-recovery PASS, live-recovery PASS, sync PASS, canonical-hard-kill
   318/0, reap-semantics 27/0.
2. Artifacts: `validate-json-artifacts.ps1 -All` 31/31/133 PASS across the
   Phase 3 artifact set (env-build 3, lock 3, state 3 `oneOf`, root claims,
   list/status 2, the four plan kinds, receipts, journals, live-operation-result
   v1) with the negative fixtures failing at their declared layer.
3. Runner + non-suite gates: the definitive
   `run-tests.ps1 -All -JsonSummaryPath <external create-new>` run reads
   `PASS; discovered=39; passed=39; failed=0; timed-out=0` (external create-new
   summary `phase3-task9-unified-rerun-20260915-123558.json`, SHA-256
   `033daf312a9a0bb38bb71326d4ce966150d6589108f4d283066aa2f29dec77b1`). The first attempt
   read `passed=36; failed=0; timed-out=3`: harness-authority (300 s),
   harness-env (180 s) and task-skills (120 s) had budgets below their
   post-Task-8 runtime, so the budgets became 900/600/900 s and the CI job
   timeout 400 → 460 minutes (the runner's own required-budget computation is
   430). Non-suite gates: parse 171 files, doctor PASS (19/10/0 in an isolated
   home), build-skills PASS with zero untracked/tracked-generated output, secret
   scan clean, dangerous-file scan 0 violations over 569 tracked files, and
   `git diff --check` with exactly the four protected Reasonix literal negative
   pathspecs (untracked leaves, never opened or hashed).
4. Reviews: an independent Phase 3 requirements/quality review reported
   compliance on all eight requested axes (design, artifact DAG, state
   replacement/recovery, route exclusivity, controller identity, root
   immutability, overlay transactionality, selection-aware pinned planning) with
   four low findings; the migrate apply-locator gap and the setup command pin
   were fixed here, the record inaccuracies were corrected, and G2 plus G4 were
   fixed right after the checkpoint (see the two sections at the end of this
   record). The Task 8 change set was reviewed separately;
   all four of its findings are addressed.
5. Real authority/live state untouched: all runs used sandbox homes/repos; no
   production Apply/rollback/retirement ran; `scripts/live-safety-policy.psd1`
   (`ProtocolVersion=3`, `ReleaseState=interlocked`) is unchanged.

## Review follow-ups after the Phase 3 checkpoint (2026-09-15)

**G2 — orphan state without claims (fixed, `872ad03`).** An orphan schema-3
state whose immutable claims are gone fell through the route resolver's
claims-MISSING branch and was recommended initial/adopt, which every
first-authority transition refuses (the host requires claims and state both
absent and fails closed with `live-transaction-authority-present`). The resolver
now returns `manual-recovery-required` whenever claims are MISSING while the
state is VALID or CORRUPT, so the status recommendation and the runner's routed
diagnostic stay actionable. Pinned by three new `harness-authority` assertions
(the orphan fixture facts, the route, and the recommended `env authority status`
operation); harness-authority 435/0, seams 56/56, harness-env 311/0, task-skills
93/0, automation-safety PASS, approved-runner PASS.

**G4 — the environment-rollback production caller (fixed).**
`scripts/rollback-harness-env.ps1` no longer refuses with
`worktree-overlay-lock-not-implemented` (the token and its declaration are
gone). The entry now probes the source transaction's journal header read-only
before the lock order starts (a namespace that does not exist stays owned by the
under-lock evidence checks, so the missing/tampered/unfinished tokens are
unchanged), derives the worktree overlay identity
(`Resolve-RollbackOverlayLockIdentity`), and acquires the reviewed origin
canonical -> worktree overlay -> global order with the canonical handle
mandatory for the overlay step. Under the locks the identity is re-derived from
the freshly read header and compared with the pre-lock binding (no TOCTOU), a
foreign identity fails closed as `rollback-origin-mismatch (overlay lock)` with
no plan written, and releases are tail-to-head. Apply validates the reviewed
plan and then runs it through `Invoke-SealedEnvironmentRollbackTransaction`; the
production interlock still owns the refusal because the composition always
passes its `-RepoRoot`, which is outside the sandbox root — so the transition
becomes reachable exactly when the protocol is released, and the transaction
itself stays covered by the live-recovery suite's direct engine tests.

Verified after the wiring: backup-recovery PASS (191 assertions, including the
rewritten foreign-overlay refusal, the new origin-identity DryRun derivation
under the full lock order, the token-inventory update, and the interlock pin
that also asserts the obsolete token can never appear), live-recovery PASS,
seams 56/56 re-pinned (reflection 15784, digest
`90cdfd7c18faeeca64819e28f5ccce7ea1fcb32e80fb28bc154450322fc8e031`), parse gate
171 files, artifact validation 31/31/133 PASS, secret scan and `git diff --check`
clean. Production Apply remains interlocked.

## Sealed-file operator-as-parameter slice closed (2026-09-15)

The carried sealed-file finding is closed. `tests/canonical-hard-kill.tests.ps1:8256` now runs all
three of its intended taint checks:

```powershell
if((Test-RegionAstTainted $commonArgument) -or (Test-RegionPsVariableProvider $commonArgument) -or (Test-RegionRefExpression $commonArgument)){throw 'preimage-transport-owner-shadow'}
```

The shape is that of the sibling three-way condition at line 8264 of the same analysis, which
already parenthesises each call. Static proof: parsing line 8256 yields three `CommandAst`
invocations inside a `BinaryExpressionAst` chain and zero command-parameter nodes — the defect
signature the parse gate keys on.

What the broken form actually did, re-measured rather than assumed: the whole condition was one
`Test-RegionAstTainted` invocation whose extra elements (`-or`, the bare name
`Test-RegionPsVariableProvider`, `$commonArgument`, `-or`, and the parenthesised
`(Test-RegionRefExpression $commonArgument)`) were silently accepted as arguments of a simple
function. The condition therefore degenerated to the first check's result, and a marker-file probe
confirms the runtime shape: the first check ran, the third ran (its boolean was consumed as an
argument instead of contributing to the condition), and the middle check never ran at all. The
earlier phrasing "two never run" is therefore imprecise for the parenthesised third call. The single reviewed exemption in
`scripts/check-powershell-syntax.ps1` is retired and the table is empty; the mechanism is kept so a
future reviewed exemption has a declared home.

Re-seal: `tmp/reseal-hard-kill.ps1 -Verify` reported the drift before the change and `total
changes: 0` after the fixpoint run. It re-pinned exactly four self-referential values —
`Require-ReviewedFunctionHash 'Test-HardKillPreimageControllerTransportContract'`
(`274c57a7…` → `e9732456…`), the cleanup-gate self digest (`9f8b86c9…` → `e9db46ea…`), the function
inventory digest (`1a631d31…` → `bffb370c…`) and the controller surface sha (`16888889…` →
`4e101dda…`). Within the hard-kill file the diff contains only those four pin lines plus the fixed
line — the companion change empties the parse-gate exemption table, and nothing else: the
reviewed-load manifest, the actual-prelude rows and digest, the pre-section region, the main-try
digest and the top-level execution digest (`94bb53a8…`) are unchanged, which is the expected
footprint for an edit inside a single function body. An independent re-derivation (not this file's
probe) recomputed the containing-function pin and the cleanup-gate self digest and reproduced both
from the committed bytes.

Verification: `-Section primitives` **95 passed, 0 failed** and the full suite
`tests/canonical-hard-kill.tests.ps1 -Section all` **318 passed, 0 failed**, both equal to their
pre-change baselines — the now-live taint checks reject no existing positive control. Parse gate
171 files pass with the exemption table empty, the secret scan is clean, artifact validation
reports 31 contracts / 31 positives / 133 negatives PASS, seams is 56/56, and `git diff --check` is
clean. The raw run output for these gates is machine-local and gitignored
(`tmp/hk-primitives-repin-20260915.log`, `tmp/hk-full-repin-20260915.log`,
`tmp/hk-gates-repin-20260915.log`); what the commits carry is this record, not those logs.

Definitive unified pass: `pwsh -NoProfile -File scripts/run-tests.ps1 -All -JsonSummaryPath
<external create-new path>` reads **`Test summary: PASS; discovered=39; passed=39; failed=0;
timed-out=0`** (external create-new summary `repin8256-unified-rerun-20260915.json`, SHA-256
`3b3134d6d05ac0411690984ff9e05a71c4184b3a406d10be8a0664b3c817b1ed`; 8485 s of suite time and the
runner's own `requiredJobTimeoutSeconds` 25785; longest suites `canonical-hard-kill` 2742 s of
5400, `root-claims-registry` 1647 s of 3600, `harness-authority` 477 s of 900, `sync` 441 s of
1200, `harness-env` 321 s of 600). An earlier attempt at the same run was truncated by the
operator's own 150-minute cap: it had reported zero failures across the ~30 suites that completed
but wrote no summary, so it is not a verdict — the cap now derives from the runner's declared
requirement instead of a remembered runtime. That run started on the tree at `cfb3db6` and finished
on the tree that also carries the gate hardening (`b791bda`); every suite that reads `scripts/**`
content — `canonical-production-seams` (56/56, including the two all-scripts baselines) and
`harness-env` — ran after that change, so the pass covers the final bytes. The seams all-scripts baselines were independently reproduced rather than re-stamped
(`tmp/seams-delta.ps1 -WorktreeOnly scripts/check-powershell-syntax.ps1`): both are byte-identical
to their pinned values (reflection-sensitive 15784 / `90cdfd7c…`, dynamic 168 / `4fc1bb2d…`),
because retiring a hashtable entry adds neither a reflection-sensitive site nor a dynamic command,
so no re-pin was needed and none was applied.

No production authority was touched: `scripts/live-safety-policy.psd1`, the interlock and the live
roots are unchanged.

## Pending items (2026-09-15, after the Phase 3 checkpoint and its review follow-ups)

**Phase 2 and Phase 3 are both complete** (Phase 3 at 47/47: the checkpoint is `e57c608`, and the
two review findings it raised are closed — G2 by `872ad03`, G4 by `976d0fe`; the carried sealed-file
slice is closed by `bbfa6d5` as recorded above). Items 1-7 are what the 2026-09-15 checkpoint window
left open — downstream, design-bound, or operational; items 8-11 were added by the sealed-file slice
window that closed on 2026-09-16, and Phase 4 remains the only open roadmap item:

1. **Phase 4 — schema/CI contract and safe release — not started.** It owns the interlock release.
   Until it lands, every production sync/environment/task/rollback Apply, standalone backup, and
   explicit retirement stops with `safety-protocol-upgrade-required` before traversal or mutation.
   The rollback entry is now *reachable* rather than token-refused (G4), and its refusal at Apply
   is the interlock itself.
2. **Design-bound finding still feeding Phase 4**: the cross-authority root-claim overlap rejection
   needs a machine-wide claim store — both authorities commit on a shared custom root today (the
   Phase 2 Task 8 Step 4 finding).
3. **Carried boundaries**, unchanged: the locator stays phase-only by design, so a state file
   replaced without its `FILE_REPLACED` record surfaces as a dispatcher DryRun failure rather than a
   locator status; a live-target move whose record is still a `_pending` temp classifies as manual
   recovery; the `RECEIPT_FINALIZATION` host checkpoint stays placement-pinned until the production
   host is child-killable; the engine's per-target drift protection is hash-based; and the rollback
   plan's `Current` identity binding is recorded as not enforced by the existing ladder.
4. **Before any future environment planning**, rebuild the stale commit-bound staging locks. They
   were last rebuilt on 2026-09-13 and have since moved several HEADs; the generated `envs/`
   artifacts are gitignored machine-local state. This is artifact preparation only and never
   authorizes Apply.
5. **Per-machine revalidation after any reviewed release**: revalidate each managed machine
   independently, and for retired skills still present elsewhere use a new machine-local retirement
   JSON with a reviewed bound plan — never this machine's deleted authorization files.
6. **Coordination**: any other clone or fork should re-clone or rebase rather than merge the old
   history.
7. **Operational, needs a human decision**: two agents were writing this repository concurrently
   through the whole 2026-09-15 window — one of them stashed and reverted the other's in-flight
   files, `HEAD` moved under the other five times, and two overlapping full runs caused three
   mutual suite timeouts. The work converged and nothing was lost, but if one owner per repository
   is intended, that is a scheduling decision this record cannot make. The window's operational
   lessons are recorded in the agent memory (`concurrent-session-hazard`), not here.
8. **Privacy-narrative verification — needs the owner.** An independent check of 103 cited short
   SHAs found 99 present and consistent. Re-verified in this tree: `bbba28f` resolves as
   `chore(privacy): ignore local Reasonix desktop state` (`.gitignore` only, ancestor of HEAD) —
   it is the force-with-lease publish head the rewrite record anchors on (roadmap `:5` and `:118`),
   not itself the rewrite content; `91e871e` resolves as
   `feat(live-safety): add phase 2 authority registry foundations` (Thu Aug 27 2026), is an
   ancestor of HEAD, and is contained in `remotes/origin/main` (the earlier claim that it does not
   exist was false); and `0a6c16e` (the Phase 0 implementation SHA) genuinely does not resolve,
   consistent with a history rewrite having removed it. Which commit actually carries the
   privacy-rewrite content remains open for the owner — a rewritten history cannot resolve
   pre-rewrite SHAs.
9. **Dated history sections still carry superseded present-tense claims.** The file header now
   states that this is a dated log and the most misleading sections (the 2026-09-08/09 `Current
   phase`, the pre-Phase-3 `Remaining work`, the `Current checkpoint` pointer, the `STATUS.md`
   wrap-up) were corrected or banner-marked this window. **Sweep done (2026-09-16):** the remaining
   2026-09-14-and-earlier sections named here were banner-marked or given inline superseded
   markers; history text was left intact. Production Apply remains interlocked; Phase 4 has still
   not started; the staging locks are stale again.
10. **Push and CI coverage — read Git before acting on this item.** The owner pushes this repository
   (the `cfb3db6` push during the 2026-09-15 slice window was the owner's, not an unexplained event).
   The window-close snapshot said `b791bda`, `996986a`, `fe149f9` and `5807727` were local-only; the
   owner then pushed through `5807727`, so `b791bda` and the gate hardening are already on the
   remote. Treat that sentence as a dated snapshot, not as current state: `git log origin/main..main`
   is the authority. What does not age is the other half — this machine cannot query CI at all
   (`gh` unauthenticated, no token), so any CI verdict must be read from the workflow, never inferred
   from a local `-All` pass.
11. **Tooling note outside this repository.** The global agent instruction that documents the Grok
   wrapper states that a read-only call may run in parallel with same-directory work, but the
   wrapper enforces a per-directory named mutex and refuses the second process
   (`grok-already-running-for-working-directory`); it also cancels terminal commands under the
   read-only (plan) mode, so a review that must execute `git show`, AST parsing or hashing has to
   run in its own throwaway checkout with full permission. Four parallel reviews ran that way this
   window and left their checkouts byte-clean. The instruction text is due an update; the working
   recipe is recorded in agent memory until then.
12. **The parse gate has no in-repo regression test — highest-value follow-up.** Two of the four
   reviews reached this independently. The gate is a CI *non-suite* step: `scripts/run-tests.ps1`
   never invokes it, so re-filling the exemption table, or turning the check's `if ($true)` wrapper
   into an off switch, leaves all 39 suites green and only the explicit run or remote CI catches it.
   The fixtures they propose: lower-case `-or` rejected, upper-case `-AND` rejected, the
   parenthesised form accepted, a genuine expression operator accepted, the exemption table asserted
   empty, and the `scripts/` unknown-parameter pass asserted not to double-report `-AND`. Adding it
   means a new `tests/*.tests.ps1`, which the runner auto-discovers, so it needs a budget entry in
   `tests/test-timeouts.psd1` and a re-verified runner bound. Do the gate script's remaining tidy-up
   in the same slice, so the new fixtures can prove it: the operator check still sits inside a
   vestigial `if ($true)` wrapper (about line 90) that can be flipped into a silent off switch, and
   that wrapper was left in place this window precisely because nothing in the suite set exercises
   this file.
13. **The 8256 rejection surface has no independent RED.** The existing common-parameter mutations
   fail earlier — `:8254-8255`'s scriptblock check or `:8245-8249` — so nothing exercises
   "provider only" or "`[ref]` only" on an unmatched common parameter, which is exactly the surface
   the fix made live. A mutation that reaches it changes the sealed function body, so it needs its
   own re-seal, `-Section primitives` signal and full-suite verdict; the reviewer supplied the three
   candidate cases, including the warning that the probe's variable must sit outside `$regionTaint`
   or the first check masks the other two.
14. **Pre-existing inconsistency found while scanning for item 12**: `Get-SkillDirectories` is
   defined twice with different signatures — `scripts/build-skills.ps1:149` takes only `-Path`, while
   `scripts/skills-common.ps1:84` takes `-RootPath`/`-ExcludeNames`. This is the defect class the
   gate's unknown-parameter pass deliberately skips (six colliding names are skipped today), so it
   is invisible to it; not a regression, but it should be settled the next time that collision
   handling is touched.
Both follow-up changes were then re-validated by a fresh definitive run on the
resulting tree: ``pwsh -NoProfile -File scripts/run-tests.ps1 -All
-JsonSummaryPath <external create-new path>`` reads **``Test summary: PASS;
discovered=39; passed=39; failed=0; timed-out=0``** (external create-new summary
``phase3-followups-unified-20260915-160911.json``, SHA-256
``f382edfbb3bf9362517b84364efb9bda4ceea2f584171de172e11f82608dbca3``). With G2
and G4 closed, the only remaining item in the roadmap is Phase 4 (the schema/CI
contract and the safe release), which requires releasing the production
interlock and running the real-machine read-only/dry-run validation — an action
reserved for the user's explicit authorization. Items 8-11 above are the
operational and documentation follow-ups on top of that, and item 9 (the sweep of
superseded present-tense sections) is the one to finish before any text written for
a release or for a new session leans on those sections.

## Parallel-grok follow-up window (2026-09-16/17, complete)

The actionable half of the 2026-09-15 pending list was executed by five independent workers
(grok-4.6 at `xhigh` with full permission, each in its own detached `git worktree` at `71b8e74`)
running concurrently, and integrated one stream at a time: W12 the parse-gate follow-up, W13 the
hard-kill taint RED, W14 the duplicated helper, W9 the record sweep, WP4 the Phase 4 proposal.
The coordinator reviewed each diff, re-verified it in the main checkout, re-derived the combined
seam baselines, and owns the commits below. Closed by this window: items 8, 9, 11, 12, 13 and 14.

- **Item 12 — the parse gate now has an in-repo regression suite (`2a90261`).**
  `tests/powershell-syntax-gate.tests.ps1` drives the real gate as a child process against
  throwaway `git init` fixture roots: lower-case `-or` and upper-case `-AND` rejected, the
  parenthesised form and a genuine expression operator accepted, the exemption table asserted
  empty by AST, and the `scripts/` unknown-parameter pass asserted not to double-report a bare
  `-AND`; plus the repository-as-is pass and a structural check that the operator `foreach` is not
  nested in a constant `if`. RED was proved both ways in the worktree — one exemption entry and an
  `if ($false)` wrapper each made the suite fail — and the exact gate bytes (SHA-256
  `7dbd9c9cec3a904950b92d17df5e985a9fdeb3a6364b647cb9d3b3df14f7ae79`) were restored afterwards.
  The vestigial `if ($true)` wrapper is gone and the check is unconditional. Measured 9.71 s,
  budget entry 90 s; `tests/test-runner.tests.ps1` still proves the workflow bound.
- **Item 14 — `Get-SkillDirectories` is defined once (`fc6e173`).** `build-skills.ps1` dot-sources
  `skills-common.ps1` and its seven call sites use `-RootPath`; the local duplicate is deleted and
  no other name of the shared library collides with a local one. Behavior is preserved by
  evidence: `build-skills.ps1` exit 0 with the 7/15/7 summary and the same manifest line in both
  runs, and a SHA-256 inventory of all 140 generated files plus the four manifests is identical.
  The gate's skipped-collision set shrank from six names to five.
- **Item 13 — the `:8256` taint surface has independent RED (`0c68ee3`).** Three mutation cases
  reach that line through an unmatched `-ErrorAction`: provider-only, `[ref]`-only and ast-only
  probes, with the first two held outside `$regionTaint` per the reviewer's warning. Arm-by-arm
  neutralization made exactly the corresponding case slip through (`Valid=True codes=[]`) while the
  other two stayed rejected with `preimage-transport-owner-shadow`. The mutation inventory is now
  302 rows and the static-boundary assertion text moves with it. Ten self-referential pins moved
  (both reviewed function hashes, the cleanup-gate self digest, the function-inventory digest, the
  controller surface sha, and the execution/region/self-test digests) and were re-sealed to a
  fixpoint; `-Verify` reports `total changes: 0` in the worktree and again in this checkout.
- **Items 9 and 8 — the sweep and the SHA correction (`23d2d37`).** One banner per repeated claim
  run plus inline G4 markers; history text is kept as history. Item 8's own claim that `91e871e`
  "does not exist at all" was itself false: it resolves
  (`91e871e271c21c4cac382b8a3f4ac6e04032658d`, `feat(live-safety): add phase 2 authority registry
  foundations`, 2026-08-27), is an ancestor of `HEAD` and is contained in `remotes/origin/main`;
  `bbba28f` resolves as the `.gitignore`-only commit and is the force-with-lease publish head the
  rewrite record anchors on, not the rewrite content; `0a6c16e` does not resolve. What the tree
  cannot settle — which commit carries the rewrite — is now marked open instead of inferred.
- **Item 11 — the Grok invocation guide matches its wrapper.** The global instruction files
  (`AGENTS.md` and `instructions/grok-build.md`, outside this repository) now state that the
  per-directory named mutex refuses a second process even for read-only calls, that `-ReadOnly` is
  plan mode and cancels terminal commands, and that reviews needing `git show`, AST parsing or
  hashing must run in their own throwaway checkout with full permission. The wrapper also caps
  `-MaxTurns` at 100, which this window hit as a pre-launch parameter error.

Combined-tree verification (code `2a90261`, `fc6e173`, `0c68ee3`; docs `23d2d37`):

- The seams baselines were re-derived on the combined tree rather than taken from either worker:
  dynamic command digest `4fc1bb2d…` → `2f518abc…`, reflection-sensitive count 15784 → 15782,
  reflection-sensitive digest `90cdfd7c…` → `c901fb35…`. The row list contains exactly four
  mutations — one `InvokeMember` row whose extent text changed because the gate tidy-up dedented a
  hashtable literal (the baseline hashes extent whitespace, not only semantics), two rows removed
  with the deleted helper, and one dynamic command added for `. $skillsHelper` — and the
  `canonical-production-seams` suite then passes 56/56 in this checkout.
- Parse gate passes with 172 files (171 before the new suite); the new suite and `test-runner`
  pass; `canonical-preflight` 27/27 and `skills-import` 42/42 (worktree runs, untouched by
  integration); `-Section primitives` 95 passed / 0 failed.

Definitive unified pass: ``pwsh -NoProfile -File scripts/run-tests.ps1 -All -JsonSummaryPath
<external create-new path>`` reads **``Test summary: PASS; discovered=40; passed=40; failed=0;
timed-out=0``** (summary `unified-parallel-grok-window-20260916.json`, SHA-256
`31d31ab9e3df7b17e83858747d64ec6118d0b9b7b600c1964014e3a87e684acd`, DiscoveryHash
`42eb47e7ec4a4f6d32ff8346e7f58b2db4960b8ecc64e6b1f87a72673ac8d2f0`, the runner's own
`RequiredJobTimeoutSeconds` 25875; 8470 s of suite time, longest suites `canonical-hard-kill`
2539 s of 5400, `root-claims-registry` 1543 s of 3600, `harness-authority` 511 s of 900,
`live-recovery` 469 s of 900, `sync` 452 s of 1200 and `backup-recovery` 431 s of 900). The 40th
suite is the new `powershell-syntax-gate` one, and the run covers exactly the committed bytes of
`d5a3cda`; the summary itself is machine-local and gitignored (`tmp/`), so the commit carries this
record rather than the JSON.

State at close (2026-09-17): `HEAD` is the commit carrying this record and the working tree is
clean; the three staging locks were rebuilt last and bind that same commit (any later commit makes
them stale again by design); all five worker worktrees and their scratch parent directory were
removed after integration. The owner pushed the window through `6488182` while it was closing, so at
the close-out check `git log origin/main..main` showed only the record commit carrying this
paragraph; item 8's rule stands — read Git rather than this snapshot, and remote CI still cannot be
queried from this machine. The machine-local evidence — the unified summary and log, the build
reports — stays gitignored under `tmp/` and `reports/`; nothing else was left in the tree.

## Pending items (2026-09-17, after the parallel-grok window)

The parse-gate RED gap and the record sweep named by the 2026-09-15 list are closed above, so this
is the reference for text written after this window. Items 1-3 and 5-7 carry over unchanged; item
4 is the post-commit rebuild; items 8-11 are new or refreshed.

1. **Phase 4 — schema/CI contract and safe release — the only open roadmap item; it now has a
   decision package.**
   [`docs/specs/2026-09-16-phase4-schema-ci-release-proposal.md`](../../docs/specs/2026-09-16-phase4-schema-ci-release-proposal.md)
   stages the release (read-only CLIs → external create-new DryRun → per-machine revalidation →
   owner-authorized policy commit plus a disposable-identity lab → protocol rollback), names the
   contract gaps, and marks its own claims as proposal analysis rather than repository evidence.
   Until a reviewed release lands, every production sync/environment/task/rollback Apply and
   explicit retirement still stops with `safety-protocol-upgrade-required` before traversal or
   mutation. Two adjacent facts were re-verified in the tree this window and are recorded in the
   proposal: the public standalone `backup.ps1` exits earlier with `backup-is-transaction-internal`
   (`backup.ps1:61-67`), and canonical `-Apply` ends in `canonical-apply-interlocked` / exit 75
   with no production engine (`canonical-transaction.ps1:62-71`).
2. **Design-bound finding still feeding Phase 4**: the cross-authority root-claim overlap rejection
   needs a machine-wide claim store — both authorities commit on a shared custom root today (the
   Phase 2 Task 8 Step 4 finding; the proposal's §4 recommends a SID-scoped occupancy index that is
   not ControlBase-relative and is never written into live skill trees).
3. **Carried boundaries**, unchanged: the locator stays phase-only by design, so a state file
   replaced without its `FILE_REPLACED` record surfaces as a dispatcher DryRun failure rather than
   a locator status; a live-target move whose record is still a `_pending` temp classifies as
   manual recovery; the `RECEIPT_FINALIZATION` host checkpoint stays placement-pinned until the
   production host is child-killable; the engine's per-target drift protection is hash-based; and
   the rollback plan's `Current` identity binding is recorded as not enforced by the existing
   ladder.
4. **Staging locks rebuilt in this window; they bind the window's final commit and go stale again
   by design.** `scripts/build-skills.ps1` then `env build minimal|work|full` rebuilt all three
   (`definition=valid staging=built lock=valid`, `Files: 32/40/145`), and each `env.lock.json`
   now carries the commit that closed this window instead of `505f57d`/`12b1f52`. Any later commit
   makes them stale again — the next rebuild is artifact preparation before environment planning
   and never authorizes Apply.
5. **Per-machine revalidation after any reviewed release**: revalidate each managed machine
   independently, and for retired skills still present elsewhere use a new machine-local retirement
   JSON with a reviewed bound plan — never this machine's deleted authorization files.
6. **Coordination**: any other clone or fork should re-clone or rebase rather than merge the old
   history.
7. **Operational, needs a human decision**: whether one owner per repository is intended. The
   2026-09-15 window's concurrency incident is recorded in the agent memory
   (`concurrent-session-hazard`); this window avoided it with one writer per worktree and a single
   integrator.
8. **Push and CI coverage — read Git before acting.** The owner pushes; `git log origin/main..main`
   is the authority, and this machine still cannot query CI (`gh` unauthenticated, no token), so a
   local `-All` pass is never a CI verdict. The owner pushed this window's commits through
   `6488182` — implementation `2a90261`/`fc6e173`/`0c68ee3`, records `23d2d37`/`d5a3cda`/`d5aac9f`,
   the ZCODE closeout `3f9ded1` and the lock record `6488182` — and only the closing record commit
   was local at the close-out check; that is a dated snapshot, not current state.
9. **The Phase 4 proposal is unreviewed by the owner.** Its §1.13 contradictions, its unregistered
   `doctor-report` schema, the live-recover Apply that is sandbox-root-gated without the interlock,
   and the claim-store options all need an owner read before any §7 decision is adopted.
10. **The gate's ambiguous-name skip list still hides five names** (`Get-CodexLiveSkillsPath`,
    `Get-FileHashHex`, `Get-PlannedCopies`, `Get-StringSha256`, `Test-Excluded`); item 14 settled
    one of six.
11. **The parse gate remains a CI non-suite step.** Its regression suite is now in-repo, but
    `scripts/run-tests.ps1` still never invokes the gate, so a local `-All` pass cannot detect a
    disabled gate; the proposal's Task 3 (repository validation orchestrator) is where that closes.

## Gate skip-list settlement window (2026-09-17, complete)

Pending item 10 of the 2026-09-17 list is closed by `117a556`: the syntax gate's ambiguous-name
skip set is empty, so its unknown-parameter pass now checks every repository-function call site
it can resolve. The five names each collapsed to one definition, following the `fc6e173`
precedent of keeping the shared-library copy instead of adding new surface:

- The three platform getters (`Get-ClaudeLiveSkillsPath`, `Get-CodexLiveSkillsPath`,
  `Get-ReasonixLiveSkillsPath`) moved verbatim from `live-plan-evidence-common.ps1` into
  `skills-common.ps1`, which every live-plan session already loads transitively via
  `canonical-transaction-common` → `build-skills.ps1`. `live-plan-evidence-common.ps1` now
  dot-sources `skills-common.ps1` explicitly and keeps `Get-PlatformLiveRoot`; `backup.ps1`
  dot-sources it too and loses its inline `Get-CodexLiveSkillsPath` (the two bodies differed
  only in comments).
- `Get-StringSha256` keeps its `skills-common.ps1` definition; the byte-identical
  `live-plan-evidence-common.ps1` copy is deleted.
- `Test-Excluded`, `Get-FileHashHex`, and `Get-PlannedCopies` moved into a new
  `scripts/config-common.ps1` dot-sourced by `config-status.ps1`, `config-push.ps1`, and
  `config-pull.ps1`; pull's `-RepoItem/-HomeItem` call form joined push's direction-neutral
  `-SrcItem/-DstItem` form and `config-pull.ps1`'s single call site was renamed. The
  single-definition locals (`Get-ItemKind`, `Get-DirFileMap`, `Find-MachinePrivatePaths`)
  stayed in their scripts.

Verification: an AST probe over all `scripts/*.ps1` reports zero duplicate function names (the
gate derives its ambiguous set from exactly those files); parse gate passes with 173 files
(172 plus the new `config-common.ps1`); secret scan PASS; `build-skills.ps1` exit 0 with the
same 7/15/7 summary and a byte-identical generated tree and manifests (git status carried
exactly the eight touched files); backup's retired public path still exits
`backup-is-transaction-internal` before traversal; config status/push/pull dry-run smoke output
unchanged. Focused suites, all green: `config-sync` 17/0, `powershell-syntax-gate` PASS,
`automation-safety` PASS, `skills-import` 42/0, `sync` PASS, `harness-env` 311/0,
`backup-recovery` PASS, `canonical-preflight` 27/0, `agent-dotfiles` 23/0, `task-skills` 93/0,
`harness-authority` 435/0, and `canonical-production-seams` 56/0 on the re-pinned baselines.

Baselines: the two all-scripts seams baselines were re-derived on this tree with the
independent reproduction tool and reviewed row by row — reflection-sensitive 15782 → 15763
(+13/−32; the additions are the moved function bodies re-attributed to `config-common.ps1`
and `skills-common.ps1`, the removals are the deleted local copies, and there are no new
reflection-type or reflection-sensitive command rows) and dynamic commands 169 → 174 (+5:
exactly the five new dot-source edges, none removed). The new pins are in `117a556`. None of
the touched files is in the hard-kill reviewed load manifest and the reseal verifier reports
`total changes: 0`, so no re-seal was applied.

Unified-pass evidence: a full ``pwsh -NoProfile -File scripts/run-tests.ps1 -All
-JsonSummaryPath <external create-new path>`` run launched against the `0e0cb7f` tree reads
**``Test summary: PASS; discovered=40; passed=40; failed=0; timed-out=0``** (summary
`unified-skip-list-settlement-20260917.json`, SHA-256
`a66028d1893575999befef84122e12c89946b7bb3447efc5dda598d0b20c3130`, DiscoveryHash
`42eb47e7ec4a4f6d32ff8346e7f58b2db4960b8ecc64e6b1f87a72673ac8d2f0` — unchanged from the
previous window because the suite set did not change; `RequiredJobTimeoutSeconds` 25875 as
read at launch; 9867 s of suite time, longest `canonical-hard-kill` 3134 s of 5400,
`root-claims-registry` 1801 s of 3600, `harness-authority` 605 s of 900). It is **not a
frozen-tree per-commit verdict**: the concurrent CI failure-rules window committed its five
documentation/budget commits (`ff9dbb3` through `0a1675a`) while the run was in flight. No
`scripts/` file and no suite's own bytes changed under the run — the only test-side delta is
the `automation-safety` budget in `tests/test-timeouts.psd1`, which is runner configuration
read at launch and asserted by `tests/test-runner.tests.ps1` (green in the run) — so the run
does exercise this window's implementation bytes as committed, and the inflated suite time
(9867 s against the previous window's 8470 s) is consistent with the shared machine rather
than the change. A frozen-tree unified pass over the combined tree is left for a quiet
window: at this record's close the concurrent session was still running its own workloads,
and a second full run would repeat the mutual-timeout incident held in the agent memory
(`concurrent-session-hazard`).

State at close: `HEAD` is the commit carrying this paragraph and the working tree is clean;
the three staging locks were rebuilt after this final record commit and bind it (`env status`
reads `lock=valid` at the rebuild; any later commit stales them again by design). The push
authority stays `git log origin/main..main`: the owner
pushed the window through `0a1675a` overnight, and a follow-up check found only this window's
record commits still local — a dated snapshot, not current state.

Frozen-tree pass (2026-09-18, quiet machine): the rerun the paragraph above deferred reads
**``Test summary: PASS; discovered=40; passed=40; failed=0; timed-out=0``** over exactly the
committed bytes of `c0f1475` (summary `unified-combined-tree-20260918.json`, SHA-256
`951d31ea4fa35b3363108978088f4769b4fe6229e2122f2fb46b1964a9093897`, DiscoveryHash unchanged,
`RequiredJobTimeoutSeconds` 26355 — the runner read the post-`6db9760` budget file; 8644 s of
suite time, back at the uncontended baseline: `canonical-hard-kill` 2762 s of 5400,
`root-claims-registry` 1660 s of 3600, `harness-authority` 489 s of 900). This closes the
caveat above: last night's 9867 s suite total was machine contention, as hypothesized there.

CI on the same commit (run `35291382501`, started 2026-09-18 08:29 +0800): **failure**, one
assertion — the root-claims-registry resolver-contention probe
(`root-claims-registry.tests.ps1:5810`) requires a child runscape's contending Open to return
`operation-lock-busy` with `State=EMPTY` in **under 1000 ms**, and the log cannot tell which of
the four conjuncts failed. The suite bytes are identical to run `35244737608`'s green three
hours earlier (the intervening commits are docs-only), and the same commit passed the
frozen-tree local pass above, so the class is timing variance versus a real zero-wait miss;
per the rules it stays open until an authorized same-SHA rerun or a recurrence.

## CI failure-rules window (2026-09-17)

A read-only diagnosis window read every non-success `Validate` run through the repository's own
GitHub API (123 runs, 57 non-success, 2026-06-20..2026-09-17) and distilled the reusable rules
into [`docs/CI_FAILURE_RULES.md`](../../docs/CI_FAILURE_RULES.md) (`ff9dbb3`), pointed at from
`AGENTS.md` and the `docs/README.md` index. The extraction corrected a working assumption: this
machine **can** query CI read-only through the stored Git credential (`git credential fill`, token
held in a process variable and never printed or persisted); the unauthenticated `gh` state and the
anonymous-API 403 were the only blockers. Two retrieval facts are now recorded in the rules file:
the page annotation carries only `Process completed with exit code 1.` (55 of 57), and the job-log
endpoint redirects to object storage, so a client that carries the `Authorization` header across
the redirect (Python `urllib`) gets a misleading `401` while `curl -L` succeeds.

The 57 non-success runs split into: test matrix 36 (22 of them suite-level timeouts over 10
distinct suites), machine-readable evidence 10, doctor 5, the retired MCP step 2, secret scan 2,
and runner loss 2. Each class carries its real message and fixing commit in the rules file
(`9583aed`/`6540681` elevated owner, `881047a`/`5e99c07`/`fa53b7c` budgets, `895c54f` schema drift,
`c25fdd4` untracked directory, `8b859e5` secret-gate false positive). Window checks, all green:
`git diff --check`, `scripts/scan-secrets.ps1` (the first draft was itself blocked by the
`Literal secret assignment` pattern it quoted; the rule now requires describing that form without
reproducing it), `scripts/check-powershell-syntax.ps1` (173 files) and `tests/doctor.tests.ps1`.
No `-All` run was made because the change is documentation only.

Follow-up on the owner's instruction, later the same day: item 11's first gap closed with
`6db9760`, which gives `automation-safety.tests.ps1` an explicit 600 s budget in
`tests/test-timeouts.psd1`. CI evidence: the three failures were killed at exactly 120.0 s with a
marker-only block, while the green run of `71b8e74` completed the same suite in 112.6 s — a **1.30x**
multiplier against the 86.5 s local measurement, i.e. the suite sat on the knife edge of the
inherited default. **This corrects what this section first recorded**: "roughly 2x CI" and "3-4x
local calibration" are window observations, not rules, and 600 s is a tier alignment with the
existing subprocess-heavy budgets (`canonical-production-seams`, `canonical-mutation-blockers`,
`harness-env`), not a 3-4x derivation — `fa53b7c`'s own precedent (11.4 s local -> 300 s) shows that
ratio was never the rule. The runner contract was recomputed with the runner's own functions:
40 suites, total budget 25935 s, required 26355 s (439.25 min) against the declared 460-minute
workflow bound, so no workflow change was needed.

Three independent reviews (grok-4.6, one-shot detached worktrees at `92d3561`, full permission,
reports kept outside the repository) were run on this window's output:

- **Fact re-derivation** confirmed every count from the API and job logs independently: 123 runs /
  57 failures, the failure-step distribution, the 55 + 2 annotation split, the 22 timeouts over the
  same 10 suites, `[FAIL] status\active` in all five doctor runs, the 9 + 1 schema messages, the two
  gitleaks runs with their commits, and the empty `tests/` diff between `5807727a` and `71b8e74`.
  The only claim it could not verify is the local-measurement quartet 231/187/1511/197 s, which is
  sourced only from that commit message and this file; the rules file now marks it as repo
  self-report rather than evidence.
- **Budget review** reproduced the contract arithmetic with the runner's own functions (before
  25455/25875 s, after 25935/26355 s, discovery hash unchanged), confirmed `tests/test-runner.tests.ps1`
  green and 600 s sound, and noted two adjacent facts: `harness-authority` ran 584 s green and 849 s
  once against its 900 s budget, and ten suites still ride the 120 s default (all at or below 41.2 s
  across four full CI matrices — low risk, high evidence).
- **Adversarial text review** produced 16 findings; the accepted ones are now in the rules file:
  R3 requires a same-SHA rerun and no longer reads as "ignore this class" (a run can carry a real
  failure leg beside the timeout), R8 no longer offers structural evasion and reconciles with the
  repository's existing `[allowlist]`/`# scan-ok` mechanisms, and R2's workflow clause is
  conditional instead of mandatory. Two of its claims did not survive checking and were not adopted:
  gitleaks 8.30.0 does have the `dir` subcommand, and `b1fe6e1` is a deliberate publication-race
  fixture, not a former flake of that class.

New fact from this window, recorded as decision item 12: GitHub's limits page states each job may run
6 hours, so the hosted-runner ceiling is **360 minutes**. The workflow declares `timeout-minutes: 460`,
which the platform will not honor, and the recomputed proved budget (439.25 min) already exceeds that
ceiling — the contract assertion passes against a bound the platform cannot execute.

Window checks: `git diff --check`, `scripts/scan-secrets.ps1`, `scripts/check-powershell-syntax.ps1`
(173 files) and `tests/test-runner.tests.ps1` all green; no `-All` run was made.

## Pending items (2026-09-17, after the skip-list settlement window)

Item 10 of the previous list — the five names hidden from the gate's unknown-parameter pass —
is closed by the window above. Items 1-3 and 5-9 carry over; item 4 is refreshed for this
window's commits; former item 11 is renumbered to 10. Item 8 is corrected and item 11 appended
by the CI failure-rules window recorded above; item 12 is appended by its review follow-up.

1. **Phase 4 — schema/CI contract and safe release — the only open roadmap item; it now has a
   decision package.**
   [`docs/specs/2026-09-16-phase4-schema-ci-release-proposal.md`](../../docs/specs/2026-09-16-phase4-schema-ci-release-proposal.md)
   stages the release (read-only CLIs → external create-new DryRun → per-machine revalidation →
   owner-authorized policy commit plus a disposable-identity lab → protocol rollback), names the
   contract gaps, and marks its own claims as proposal analysis rather than repository evidence.
   Until a reviewed release lands, every production sync/environment/task/rollback Apply and
   explicit retirement still stops with `safety-protocol-upgrade-required` before traversal or
   mutation. Two adjacent facts were re-verified in the tree this window and are recorded in the
   proposal: the public standalone `backup.ps1` exits earlier with `backup-is-transaction-internal`
   (`backup.ps1:61-67`), and canonical `-Apply` ends in `canonical-apply-interlocked` / exit 75
   with no production engine (`canonical-transaction.ps1:62-71`).
2. **Design-bound finding still feeding Phase 4**: the cross-authority root-claim overlap rejection
   needs a machine-wide claim store — both authorities commit on a shared custom root today (the
   Phase 2 Task 8 Step 4 finding; the proposal's §4 recommends a SID-scoped occupancy index that is
   not ControlBase-relative and is never written into live skill trees).
3. **Carried boundaries**, unchanged: the locator stays phase-only by design, so a state file
   replaced without its `FILE_REPLACED` record surfaces as a dispatcher DryRun failure rather than
   a locator status; a live-target move whose record is still a `_pending` temp classifies as
   manual recovery; the `RECEIPT_FINALIZATION` host checkpoint stays placement-pinned until the
   production host is child-killable; the engine's per-target drift protection is hash-based; and
   the rollback plan's `Current` identity binding is recorded as not enforced by the existing
   ladder.
4. **Staging locks rebuilt in this window**: the rebuild after this record binds the record
   commit and goes stale again with any later commit — the 2026-09-16 bindings it replaces were
   already stale under this window's commits. A rebuild is artifact preparation before
   environment planning and never authorizes Apply.
5. **Per-machine revalidation after any reviewed release**: revalidate each managed machine
   independently, and for retired skills still present elsewhere use a new machine-local retirement
   JSON with a reviewed bound plan — never this machine's deleted authorization files.
6. **Coordination**: any other clone or fork should re-clone or rebase rather than merge the old
   history.
7. **Operational, needs a human decision**: whether one owner per repository is intended. The
   2026-09-15 window's concurrency incident is recorded in the agent memory
   (`concurrent-session-hazard`); the parallel-grok window avoided it with one writer per
   worktree and a single integrator.
8. **Push and CI coverage — read Git before acting.** The owner pushes; `git log origin/main..main`
   is the authority. CI itself **is** queryable read-only from this machine through the stored Git
   credential (`docs/CI_FAILURE_RULES.md` §1); the earlier "this machine cannot query CI" note
   described only the unauthenticated `gh` state and no longer holds. A local `-All` pass is still
   never a CI verdict. As of the CI failure-rules window's close, `origin/main` matched `0c5ca92`
   and three commits were unpushed (`117a556`, `0e0cb7f`, `ff9dbb3`); a later check the same
   night found the owner had pushed through `0a1675a`, leaving only the skip-list settlement
   window's record commits local. These are dated snapshots, not current state.
9. **The Phase 4 proposal is unreviewed by the owner.** Its §1.13 contradictions, its unregistered
   `doctor-report` schema, the live-recover Apply that is sandbox-root-gated without the interlock,
   and the claim-store options all need an owner read before any §7 decision is adopted.
10. **The parse gate remains a CI non-suite step.** Its regression suite is in-repo and its
    ambiguous-name skip set is now empty, but `scripts/run-tests.ps1` still never invokes the
    gate, so a local `-All` pass cannot detect a disabled gate; the proposal's Task 3
    (repository validation orchestrator) is where that closes.
11. **CI reliability gaps found by the failure-rules window.** The first gap is closed by `6db9760`:
    `automation-safety.tests.ps1` now carries an explicit 600 s budget in `tests/test-timeouts.psd1`
    (see the follow-up paragraph in the CI failure-rules window). The `task-skills` sub-item closed
    by the 2026-09-18 read-only diagnosis as a **mis-attribution**: run `34851206631`'s one failed
    suite was `canonical-hard-kill`, which threw at load
    (`canonical-hard-kill.tests.ps1:333`, reviewed-load hash mismatch for
    `scripts/canonical-transaction-common.ps1`) because `45e9a50` changed the pinned script
    without re-sealing the manifest; the very next commit `b86b8b1` carried the re-seal and
    `06d1902` recorded the resolution (318/0). The `Task skill dry-run failed (exit 1)` text in
    that log is expected negative-path output (`scripts/task-skills.ps1:379` at that commit) and
    the suite itself passed 22/0; the same run's real timeouts were exactly two —
    `harness-authority` killed at 300.0 s and `harness-env` at 180.0 s against their then-budgets,
    both since raised (`881047a`) — while `automation-safety` passed in that run. Still open: the
    same-SHA rerun for the two 2026-09-17 runner-loss runs (`35166625038`, `35166789288`; their
    descendant `0a1675aa` has a green run, `35244737608`, which is weak evidence only), and the
    same-SHA rerun decision for run `35291382501` on `c0f1475` (see the skip-list settlement
    window's CI paragraph: the root-claims-registry contention probe's 1000 ms bound). Closing
    these is ordinary follow-up work under the existing gates and budgets, not a new authorization.
12. **The declared CI job bound exceeds the platform ceiling — needs an owner decision.** GitHub's
    limits page states a 6-hour (360-minute) job limit for hosted runners, so `timeout-minutes: 460`
    in `.github/workflows/validate.yml` cannot be executed as declared, and the 40-suite proved budget
    recomputed this window (439.25 min) already sits above that ceiling. The contract test only
    compares the declared bound against the proved budget, so it passes regardless. Closing this needs
    either a split of the suite matrix across jobs or re-derived budgets; both are structural changes
    that the CI failure-rules window does not authorize.

## Phase 4 implementation window (2026-09-18/19, Tasks 1-6+10 and Task 7 Step 2 landed)

Under the owner's authorization to complete the pending items, Phase 4's interlocked
implementation landed through eight reviewed slices, each independently validated and committed
(policy stays `ReleaseState=interlocked`; no production Apply anywhere):

- Task 1 / PR-A (`62465fa`): the artifact registry freeze - `doctor-report` registered against the
  current emitter shape with no ArtifactKind field, `repository-validation-summary` v1 with the
  children-DAG rules, the harness-profile schemas carried in a tracked exclusion list, the nested
  payload allowlist, negative sentinels for the 13 single-negative kinds, and the
  producer-registry completeness tests; registry 31/31/133 → 33/33/197.
- Task 2 / PR-B (`4803347`) plus the doctor slice (`9361290`): sync-plan, rollback-plan, and
  live-recover publishes route through one schema-validating create-new/atomic-move adapter
  (`Publish-ValidatedLiveArtifactJson`, designed home `json-artifact-common.ps1`), Apply
  schema-validates before mutate, and the doctor report publishes with the explicit kind under a
  validated-overwrite switch; fail-closed vectors for missing validator, wrong hash, invalid
  schema, invalid JSON, and hash mismatch; editing the pinned `json-artifact-common.ps1` moved 15
  self-seal pin lines (fixpoint re-seal, `-Verify` 0, primitives 95/0).
- Task 4 / PR-C (`e4bbaed`): the repository-policy suite (~90 assertions) - static doc pins,
  three-platform generated-root symmetry, no MCP/OpenClaw revival, hooks/bootstrap never Apply,
  the no-public-Apply-bypass net with the missing `authority-harness-env -Apply` case added, and
  the canonical exit-75 contract pinned as the INTERLOCKED public token (PR-G owns the post-Assert
  delta).
- Task 5 / PR-E (`d16b359`): the docs now describe the post-Phase-3 interlocked contract - the
  "Phase 0" banners are gone, the standalone-backup story is corrected everywhere
  (`backup-is-transaction-internal` before any interlock), the four bare `sync -DryRun` shapes
  route through the sandbox host, `.system` is marker-only, and the two superseded designs carry
  banners.
- Task 6 / PR-F (`e2a81bd`): the four Reasonix desktop-topic literals are pinned untracked at
  HEAD and in the index, metadata-only.
- Task 10 / PR-I (`b02e1d4`): the SID-scoped occupancy index
  (`scripts/root-claims-occupancy-common.ps1`, `<LocalAppDataRoot>\ai-agent-dotfiles.occupancy\<TokenSid>\`
  entries, create-new/no-follow/exact-byte/current-user-only) gated into the single claim-accept
  site (`root-claims-registry-common.ps1:3324`) - same-authority re-claim is a no-op, a different
  authority claiming the same (VolumeId, directory identity) fails
  `root-claims-occupancy-conflict`.
- Task 3 / PR-D (`833fd3f`): `scripts/run-repository-validation.ps1` orchestrates the eleven named
  gates (every YAML gate preserved exactly once, the env-build-list-status gate kept) and emits the
  validated child→summary→final artifact chain; CI's 13 inline steps became 5 with the orchestrator
  called once. **This closes the old pending item 10**: the parse gate is now a named orchestrator
  gate, though CI has not yet run the new workflow.
- Task 7 Step 2 (`04c554a`): live-recover Apply asserts
  `Assert-LiveSafetyMutationAllowed -Operation live-recover-<action>` before the resolver, so the
  interlocked-no-sandbox path refuses with the interlock token and zero writes; DryRun stays
  plan-only.

Each slice re-derived the seams all-scripts baselines on its own tree with row-level review
(15763 → 15785 → 15915 → 16086; dynamic 174 → 175 → 180 → 182) and carried its own re-pin;
`canonical-hard-kill` stayed at `-Verify 0` except the single pinned-file edit documented above.

The same window's CI rerun decisions (authorized) produced: run `35166625038` attempt 2 -
harness-authority failed at the `Invoke-AuthorityCliKilledAtCheckpoint` read race, the exact R3
site the rules file already cited; the fixture now reads with `FileShare ReadWrite|Delete` and a
bounded release wait (`e0bb9d7`), suite 435/0. Run `35291382501` attempts 1-2 on `c0f1475` - the
root-claims-registry contention probe failed once at its 1000 ms bound and passed on the same SHA
in attempt 2 (timing-sensitive, no recurrence; the probe is the known next-hardening candidate).
Runs `35166789288` and `35291382501` also produced pure startup stalls (a suite killed with zero
output records at its budget - automation-safety 600 s, harness-authority 900 s - on trees where
the same suites pass everywhere else); third attempts are in flight.

**Handoff**: Task 7 Steps 1 and 3 remain - Step 3, the shared production host resolver per §3.d.1
(wrap the three `Resolve-*InternalRoots` copies with sandbox-wins/released-identity/no-mkdir
semantics, make the authority trio complete-or-none, align `Get-CanonicalPrivateRootSelection`
with the identity's LocalAppDataRoot - that file is hard-kill-pinned), and Step 1, the production
canonical Apply engines (promote the two sealed engine bodies without lock re-entry, setup via the
SetupBootstrap Enter sequence with Complete inside Enter, wire both CLIs to branch after Assert:
throw keeps the exit-75 interlocked contract, return runs the engine under the held order), plus
the seams owner-inventory updates. The external-model worker quota reset at 2026-09-19 00:15; the
work resumes there or in a fresh session, on top of the commits above. Task 8 (the
`ReleaseState=released` commit) stays behind its owner gate: the disposable-identity lab is the
owner's to run, and per the proposal's risk register the flip is not autonomous work.

## Pending items (2026-09-19, after the Phase 4 implementation window)

The skip-list window's list is superseded by this one. Items 3-8 carry; items 1, 2, 9, 10, and 11
are updated below; item 12 gains the new budget arithmetic.

1. **Phase 4 — Tasks 1-6, 10, and Task 7 Step 2 are landed (see the window record above); Task 7
   Steps 1 and 3 are the remaining interlocked implementation, with their full spec in the
   proposal's Task 7 and §3.d.1; Task 8 (`ReleaseState=released`) stays behind its owner gate —
   the disposable-identity lab is the owner's to run and the flip is not autonomous work.** Until
   a reviewed release lands, every production sync/environment/authority/task/rollback/retirement
   and canonical Apply still stops with `safety-protocol-upgrade-required` before traversal or
   mutation, and live-recover now also Asserts before its resolver.
2. **Design-bound finding closed (`b02e1d4`)**: the cross-authority root-claim overlap rejection is
   implemented as the SID-scoped occupancy index (owner decision §7.1 option 2) gated into the
   single claim-accept site; `root-claims-occupancy-conflict` fails a second authority closed.
3. **Carried boundaries**, unchanged: the locator stays phase-only by design; a live-target move
   whose record is still a `_pending` temp classifies as manual recovery; the engine's per-target
   drift protection is hash-based; and the rollback plan's `Current` identity binding is recorded
   as not enforced by the existing ladder. (The `RECEIPT_FINALIZATION` placement-pinned boundary
   was exercised again by the harness-authority R3 fix above.)
4. **Staging locks**: rebuilt after this window's final record commit and binding it; any later
   commit stales them by design. A rebuild is artifact preparation and never authorizes Apply.
5. **Per-machine revalidation after any reviewed release**: revalidate each managed machine
   independently; never reuse this machine's deleted authorization files.
6. **Coordination**: any other clone or fork should re-clone or rebase rather than merge the old
   history.
7. **Operational, needs a human decision**: whether one owner per repository is intended. This
   window ran one writer (the coordinator) plus isolated per-PR worktree workers with serial
   integration — the pattern held without contention.
8. **Push and CI coverage — read Git before acting.** The owner pushed through `833fd3f` during
   the window; `04c554a` and the record commits are local at this writing. The new orchestrator
   workflow has NOT been exercised by CI yet — the next push is its first run. These are dated
   snapshots, not current state.
9. **Phase 4 §7 decisions**: the owner's authorization to complete the pending items adopted the
   proposal's recommendations as recorded here — §7.1 option 2 (landed), §7.8 register/carve-out
   (landed), §7.9-7.12 land with Task 7 Step 3. The proposal itself remains the decision record;
   any later deviation from its recommendations is an owner decision.
10. **The parse gate is now a named orchestrator gate (`833fd3f`), closing this item's substance;
    the residual is that CI has not run the new workflow yet (item 8), and the local unified
    runner still does not invoke the gate directly — the orchestrator does.**
11. **CI reliability**: the R3 harness-authority read race is fixed in the fixture (`e0bb9d7`).
    The root-claims contention probe is classified timing-sensitive (one same-SHA red, one green;
    a diagnosability hardening of its four-conjunct assertion is the sanctioned next step if it
    recurs). Third-attempt reruns for the two startup-stall runs (`35166789288`,
    `35291382501`) were in flight at this record's commit; their verdicts belong to the next
    record. Same-SHA rerun authority came from the owner's completion authorization.
12. **The declared CI job bound exceeds the platform ceiling — owner decision, now sharper**: with
    the two Phase 4 suites the proved budget is 27555 s required against the 27600 s declared bound
    (a 45 s margin), while the hosted-runner ceiling stays 360 minutes. Closing this needs the
    matrix split or re-derived budgets; the proposal's Task 3 says do not shard, the failure-rules
    window said a split is structural — the two documents conflict and the owner decides.

### Phase 4 window completion (2026-09-19): Task 7 landed; Task 8 gate ahead

Task 7 Steps 1 and 3 landed as `d30360f` after integration review: the shared host resolver
(`Resolve-LiveSafetyHostAuthority` — sandbox wins on any ReleaseState, released identity branch
with no mkdir and no builder re-wrap, interlocked-no-sandbox keeps each caller's
host-resolution token; all six consumers rewired; the authority trio is complete-or-none; the
canonical locator derives from the identity's LocalAppDataRoot) and the production canonical
Apply engines (`Invoke-CanonicalProductionSkillTransaction` / `...RecoveryTransaction` /
`...SetupTransaction`, promoted without lock re-entry, setup via the SetupBootstrap Enter
sequence with Complete inside Enter; both CLIs branch after Assert — throw keeps the exit-75
interlocked contract byte-for-byte, return runs the engine under the held order). Two worker
deviations are recorded as accepted: the Assert paths are repo+plan only (adding the
identity-derived roots would make the sandbox capability permanently false — they stay gated by
the identity-match check), and setup binds the runtime sealed intent rather than the proposal's
named plan-payload object (the sealed machinery asserts the binding between the two).
Integration: seams re-derived and row-reviewed (16086 → 16246, dynamic 182 → 191; the engine
file's two `Get-Command` load-order guards are the explained new sensitive rows); the pinned
`canonical-transaction-common.ps1` re-seal moved 15 pin-value lines (fixpoint, `-Verify` 0);
combined-tree re-validation: canonical-transaction-apply 21/0, canonical-command-result 72/0,
canonical-recovery 118/0, repository-policy PASS, parse gate 178 files.

Definitive unified pass: ``run-tests.ps1 -All`` over exactly the committed bytes of `d30360f`
reads **``Test summary: PASS; discovered=42; passed=42; failed=0; timed-out=0``** (summary
`unified-phase4-window.json`, SHA-256
`49a6165fbc6082cfae5d449bdc41cde2fbe08e22516eb11507005e0703b79484`, DiscoveryHash
`ca6f66f4724edcf1672f5124155b36120763e02453810cb136e9c16b0d6f6a9d` — changed by the two new
suites; `RequiredJobTimeoutSeconds` 27555; 8424 s of suite time, uncontended: `canonical-hard-kill`
2575 s, `root-claims-registry` 1555 s, `harness-authority` 482 s, `live-recovery` 480 s).

Rerun verdicts closing the CI item: `35166789288` attempt 3 on `0c5ca92` is **success** (the
automation-safety startup stall did not recur; the runner-loss run's same-SHA rerun is green).
`35291382501` attempt 3 on `c0f1475`: the contention probe passed again (green twice of three
same-SHA attempts — timing-sensitive, closed), while harness-authority failed with the same R3
redirect-handle read race — recurrence confirmed on the tree WITHOUT `e0bb9d7`, whose fixture
fix therefore addresses exactly this defect; its verification rides the next push, which is also
the new orchestrator workflow's first CI run.

State at close: `HEAD` is the commit carrying this paragraph and the working tree is clean; the
three staging locks were rebuilt after this final record commit and bind it. Phase 4's
interlocked implementation (Tasks 1-7) is complete; **Task 8 is the owner gate** — the
`ReleaseState=released` commit, the disposable-identity lab that proves each positive route, and
the real-machine read-only/DryRun pass are the owner's to authorize and run; the lab clones the
policy-only commit, STATUS follows as a later commit, and per the proposal's risk register none
of it is autonomous work.

### Task 8 Step 1 complete (2026-09-19): the release candidate exists, local-only

Under the owner's explicit authorization ("1. 已提交；2. 你允许下？3. 允许分片" — push confirmed,
Task 8 delegated to the agent's judgment, sharding approved), the remaining preparation landed and
the candidate was cut:

- **Sharding decision implemented (`57e2ecb`, worker slice with a row-reviewed seams re-pin)**:
  `run-tests.ps1` gains `-ShardCount`/`-ShardIndex` over a static three-way partition
  (`tests/test-shards.psd1`, union == discovery exactly once, fail-closed tokens); CI becomes one
  gates job (orchestrator minus the runner gate) plus three shard jobs at 170/185/195 minutes —
  every job under the 360-minute platform ceiling, parallel wall clock ~195 minutes against the
  old 459-minute single job. `docs/CI_FAILURE_RULES.md` R2 now states the per-shard contract and
  item 12 is closed as owner-resolved. The slice's smoke also found and fixed a real single-suite
  array-unroll bug in the shard path (`-All` was never affected). CI has not run the sharded
  workflow yet — the owner's next push is its first run.
- **Release-aware interlock pins (`15deede`, worker slice)**: the four suites whose behavioral
  pins assert the interlocked contract now read `ReleaseState` and branch — interlocked assertions
  stay byte-for-byte today's pins (zero weakening; CI keeps proving fail-closed), and the released
  branches pin the OBSERVED post-flip contracts per surface (verified by a temporary flip-revert
  cycle, both modes green). Notable observed facts recorded as pins: public canonical recovery
  Apply under released mode actually COMPLETES the reviewed abandon on an incomplete-bootstrap
  host (exit 0, `canonical-recovery-applied`), and sync/activate/task fail at their own
  reviewed-plan gates before the resolver, not at host resolution.
- **Task 8 Step 1 (`bffa7d7`)**: the policy-only release candidate — `ReleaseState: 'interlocked'`
  → `'released'`, exactly one file, created by the scripted generator (`tmp/lab8/make-candidate.ps1`,
  machine-local) after the four focused suites passed on the flipped tree. ToolchainPolicyHash
  `085fbce7db84b94c00d568e460a28d4f6cabf75bbb14c5619fa835e23a600ce2` (it binds the runner toolchain
  bundle and is unchanged by the flip, as its definition implies). The candidate worktree
  (`ai-agent-dotfiles-release-candidate`, detached at `bffa7d7`) and the stamped
  `tmp/lab8/lab8.wsb` are the sandbox mapping inputs. **The candidate is LOCAL and MUST NOT be
  pushed before the lab**; push order is owner's (sharding + pins first, candidate per Task 8
  Step 5 after lab evidence, or as the owner directs).
- **The lab kit** (`tmp/lab8/`, machine-local, gitignored): `lab8.wsb`, the PowerShell 5.1
  bootstrapper, the core route-exercise script (clone → pinned-tool verify → runner approval →
  canonical setup / sync / env activate / task ensure / rollback, each DryRun→Apply with per-step
  JSON evidence, first unexpected non-zero stops), and the README runbook. Every file is
  parse-checked but the kit is UNTESTED — this machine has no Windows Sandbox (`wsb.exe` absent);
  enabling it requires elevation and a reboot (owner action), or the owner picks another
  disposable identity. First rehearsal must pin the rollback receipt flag shape and the sandbox
  path mappings before relying on a full pass.

State at close: `HEAD` is the commit carrying this paragraph; the candidate sits directly below it;
the working tree is clean; the three staging locks were rebuilt after this final record commit and
bind it. Run #128 (`68e9903`) was still in flight at this commit — its verdict and the first
sharded-workflow run belong to the next record. Task 8 Steps 2-5 (lab, gates-on-candidate,
reject-or-proceed, STATUS) are the owner's.

### CI verdicts and the released-pin repair window (2026-09-21)

The owner pushed through `67bfdc6` on 2026-09-20, which carried the candidate onto `origin/main`
(owner's push-order decision; the Task 8 Step 1 record's "local-only" snapshot predates it). The CI
verdicts deferred by the record above:

- **Run #128 (`68e9903`): success** — the old single-job structure's final run, on a tree that
  already carried the R3 harness-authority fixture fix (`e0bb9d7`), closing that recurrence item.
- **Runs #129 (`eeedc46`), #130 (`67bfdc6`), and #131 (`cef82f9`): failure — the first three
  sharded-workflow runs, with all three shard jobs red and the gates job green every time.** The
  shard machinery itself (static partition, fail-closed discovery contract, per-shard timeouts)
  proved sound; every red assertion was a pin drift on the released tree, now rule `R11` in
  `docs/CI_FAILURE_RULES.md`. The owner pushed through `cef82f9` while this repair window ran;
  run #131's tree carried the harness-env repair but not the remaining eight suites' pins.
- **Run #132 (`5954503`, the first run on the repaired tree): shards 1 and 2 green, shard 3 and
  the gates job red — both isolated and repaired.** Shard 3's single red was `sync.tests.ps1`'s
  no-capability DryRun pin (the released resolver derives the host from the identity, moving the
  rejection to an environment-dependent later gate); the gates red was the full task-overlay
  literal tripping the secret scanner's generic API-key heuristic. Three follow-up commits make
  the affected pins environment-independent and split the literal the way the neighbouring
  assertion already does; local verification: shard 3 27/27 with the exact CI invocation, and the
  CI-equivalent gates chain `PASS` on the committed tree. Those commits are local at this
  writing.

Root cause (reproduced suite-by-suite on a detached `67bfdc6` worktree): `bffa7d7` flipped
`ReleaseState` after verifying only the four policy-aware suites from `15deede`; nine more suites
still pinned interlocked behavior unconditionally (approved-runner's pin proved environment-stable
and stayed green, so eight needed work), and `67bfdc6`'s documentation centralization rewrote the
AGENTS.md/README.md interlock passages that repository-policy pins verbatim. The repair makes every
affected pin policy-state-aware on the `15deede` pattern — interlocked branches keep the original
fail-closed pins byte-for-byte, released branches pin the observed post-flip contract per surface
(exit code + exact diagnostic token + command-result document shape, including the observed
released recover-abandon that completes the reviewed abandon at exit 0 with `canonical-recovery-applied`
and zero ControlBase writes, and the setup/normalize gate tokens `manual-recovery-required` /
`canonical-setup-required` at exit 1). `cef82f9` had already repaired harness-env the same way;
this window extends that to repository-policy (document pins aligned to the current wording),
canonical-transaction, skills-import, doctor, task-skills, canonical-command-result,
canonical-recovery, harness-authority, and root-claims-registry.

Validation: each repaired suite green on the released working tree via the runner collection
(sharded invocation shape), plus canonical-hard-kill green as the last unverified shard-1 member.
The full-repository collection and remote CI were not rerun locally; the next push is the sharded
workflow's first run on the repaired tree. No production script, policy value, or gate threshold
changed — this is test-pinning and documentation repair only, and it grants no release or
deployment authorization: Task 8 Steps 2-5 remain the owner's.

### 2026-09-22 CI run 34851206631 attribution correction

The owner requested the concrete documentation correction identified by harness-model's
2026-09-22 pilot review and confirmed that no other task was writing this repository.
The fixed starting tree was `8f84eececf71f111a28c953f07ac2b1d490ac3fe`; only
`docs/CI_FAILURE_RULES.md` and this existing task record are in scope. Historical entries above
remain unchanged. The rule text and evidence-index row now agree with the original run evidence.

The preserved run/job JSON binds run `34851206631` (Validate #116), job `103999311576`, and
head `45e9a501219778a63563aa6fe417b4daa7b25e18`. In the original job log,
line 580 says automation safety passed; lines 938/942 identify canonical-hard-kill's
reviewed-load hash mismatch; lines 1428-1431 record harness-authority's 300-second and
harness-env's 180-second timeouts. The task-skills negative-path diagnostics at lines
4198-4201 and 4216-4217 are followed by passing assertions, and line 4237 reports 22 passed /
0 failed. Line 4335 reports 39 discovered suites, 36 passed, 1 failed, and 2 timed-out.
This is a readback of historical evidence, not a new execution or a changed verdict for that run.

This also corrects the earlier pending-item-11 explanation that `45e9a50` changed the pinned
script: its parent is `8e27e4a`, and both commits contain exactly the same
`scripts/canonical-transaction-common.ps1` blob (`458b83c429ac1e6b84423f001cb68251492d02a3`).
That file last changed in `8e27e4a`; `45e9a50` inherited both those bytes and the stale pin.
The direct successor `b86b8b1` changed the reviewed-load pin to the actual script SHA256
`29d9b8088480288a97e81559417ea27903fe3a020a5460b4215a0f79e71f36f1` without changing that
script. `06d1902` later recorded local 318/0; it is not evidence of a successful rerun of #116.

Preserved raw references: `tmp/ci-run-34851206631.json`, `tmp/ci-jobs-34851206631.json`, and
`tmp/ci-job-103999311576.log`. The job log's original-byte SHA256 is
`4acee9b4179291c5f83943f214ad39a2cb8d92489fab23dfb3d7be2da026fe0c`.
Raw material and the current independent verification receipts remain outside tracked delivery.
No production script, policy, workflow, test, or gate threshold changed; no suite was rerun to
recreate historical results. Same-product sub-agents provide independent review only, not the
second product/session required by E3. No release or deployment acceptance is claimed.

Documentation checks passed: `git diff --check`, pinned gitleaks plus the repository scanner
(zero blocking findings), PowerShell syntax validation (179 files), and the new relative link
and heading anchor. Independent review matched the correction to the original log and Git
blobs. Full regression and remote CI were not run for this documentation-only correction.


## 2026-09-23 Task 8 Step 2 disposable-identity lab (owner-authorized): the released setup route is blocked by its own pinned-tool cache

Owner instruction: read the project's current state and complete the pending items — that is the
Task 8 Steps 2-5 owner gate. This section records what the run produced. **Outcome: the release
candidate is rejected per Task 8 Step 4**; the blocking defect is reproducible and code-cited below.

### 1. Environment correction

Windows Sandbox **is** enabled on this machine. The Task 8 Step 1 record's "this machine has no
Windows Sandbox (`wsb.exe` absent)" checked a path that exists on no Windows build; the launcher is
`C:\Windows\System32\WindowsSandbox.exe`. A probe executed inside the guest returned the disposable
identity `WDAGUtilityAccount`, Windows PowerShell `5.1.26100.9444`, `net=ok 200` (GitHub reachable),
token SID `S-1-5-21-…-504` and `IsAdmin=true`.

### 2. Lab harness (machine-local, gitignored, `tmp/lab8/`)

`run-route.ps1` (host launcher: payload and installer cache mapped read-only, one writable evidence
root, **one fresh snapshot per session**), `payload/prelude.ps1` (guest Windows PowerShell 5.1
bootstrap: cached PowerShell 7.4.6 MSI, MinGit 2.47.1, VC++ redistributable, then the route script
under PowerShell 7), `payload/common.ps1` (step runner; every command leaves one JSON evidence
record with exit code, duration, command line and full output), `payload/route-*.ps1`,
`host-roots-manifest.ps1` (host real-root hashes; the protected Reasonix paths stay metadata-only —
the manifest never reads them), `cache/` (installer payloads), `evidence/`.

**Session serialization (harness defect, fixed).** Windows 11 24H2+ Windows Sandbox permits several
live sessions and only the active one runs its `LogonCommand`; a session whose UI process is killed
leaves its VM alive, so a later session's logon command may never run (observed repeatedly; it is the
real reason the kit could not be exercised before). The launcher kills all sandbox UI processes,
waits for no remaining `WindowsSandboxRemoteSession`, launches exactly one session, waits for the
transcript/status sentinel, retries, and the guest now shuts itself down cleanly at the end. Under
host load a boot can take minutes, so the per-attempt wait is 400 s.

### 3. Lab-kit defects found and fixed before the run

1. **Route order.** The kit planned canonical setup before sync-initial. `sync.ps1` refuses a
   pristine-initial plan once the control base exists (`sync.ps1:296-304`,
   `live-plan-authority-present`), while its Apply asserts that the sealed authority prefix is
   COMPLETE (`sync.ps1:977-981`) — sync never bootstraps; the same code documents that the initial
   plan is authored *before* the prefix exists and applied after it (`sync.ps1:949-954`). The
   corrected chain is: initial DryRun → canonical setup DryRun/Apply (creates the prefix:
   `canonical-transaction.ps1:91-98`, `SetupBootstrap`) → initial Apply.
2. **Task skill name.** `doc-review-checklist` is not in `manifests/managed-skills.codex.txt`; the
   task route uses `verification-before-completion` with `-BaseEnv full`.
3. **Diagnostic surface.** The public canonical CLI maps unmapped exceptions to
   `canonical-command-failed`, so the raw cause is invisible in CLI evidence; the lab's diagnostic
   routes call the same internals and record the real error chain.

### 4. Environment precondition on a stock Windows Sandbox identity (recorded, disposable-only)

The canonical setup DryRun first failed with `canonical private root ancestor is not owned by the
access-token owner: C:\Users\WDAGUtilityAccount` — `Assert-CanonicalControlledPrivateAncestorSecurity`
at `canonical-transaction-common.ps1:1001`, reached from `Get-CanonicalRootSecurityContext:1026`
inside `New-CanonicalSetupPlanPayload:1328`. The sandbox image owns the logon profile directory with
`NT AUTHORITY\SYSTEM`, not with the logon token, whereas a normal Windows profile is owned by its
user. The lab records the before/after owner and takes ownership of that disposable directory before
the routes run; nothing else in the environment is altered.

### 5. Results on the exact released candidate commit `bffa7d7`

Every step below is a new invocation with per-step JSON evidence under `tmp/lab8/evidence/chain1/`,
`diag2b/`, `diag3/`, `diag4/`, `diag5/` (machine-local).

- Clone of the exact candidate commit from a read-only bundle mapping: `HEAD == bffa7d7` asserted;
  the policy reads `released`.
- Pinned tools: `install-schema-validator.ps1` install + `-VerifyOnly` PASS; `install-gitleaks.ps1`
  install + `-VerifyOnly` PASS; `scripts/setup.ps1 -ApproveRunner` PASS (approved commit `bffa7d7`).
- Generated-output build and the secret-scan gate PASS inside the disposable clone
  (`agent-dotfiles.ps1 build` 7/15/7 skills; gitleaks reports no blocking leaks).
- **Initial route DryRun PASS** (`sync.ps1 -DryRun`, exit 0): `Operation kind: initial`,
  `Environment: full`, PlanHash `cded25b5…`, DocumentHash `a1b47d66…`, `would add (29)`,
  `would update (0)`, `would no-op (0)`, `would prune (0)`, `unknown dirs (0)`.
- **Canonical setup DryRun PASS** (exit 0, `canonical-plan-created`, PlanHash `6f6524e6…`).
- **Canonical setup Apply FAIL** (exit 1): document
  `{"CommandKind":"canonical-setup","LifecycleKind":"no-transaction","MessageToken":"manual-recovery-required","Result":"FAIL"}`;
  nothing was created — the canonical lock, the transactions root and the setup state are all still
  absent afterwards and `canonical status` still reads `canonical-setup-required`.

**Raw cause (in-process diagnostic replicating the Apply path, `route-diag4.ps1`):**

```
read-plan                     OK    PlanHash=2a53dbe3… (setup)
hash-not-consumed             OK
plan-current                  OK    PASS
selection / authority-context OK    identity ControlBase == selection ControlBase
enter-existing-only           ERROR home-authority-bootstrap-manual-recovery-required: PrivateRootBase: home-authority-bootstrap-owner-dacl-mismatch
enter-setup-bootstrap         ERROR home-authority-bootstrap-manual-recovery-required: PrivateRootBase: home-authority-bootstrap-owner-dacl-mismatch
```

The check is `Assert-HomeAuthoritySecuritySnapshot` (`home-authority-common.ps1:568`), reached
through the bootstrap entry reader (`:683`). `PrivateRootBase` is `<LocalAppData>\ai-agent-dotfiles`
(`home-authority-common.ps1:619`, whose expected children are `backups` and `control`). That
directory is created **by this repository's own pinned-tool installers**, because the pinned tool
cache root is `<LocalAppData>/ai-agent-dotfiles/tool-cache`
(`json-artifact-common.ps1:652-659`) — and it is created with inheriting ACLs and an
administrator-group owner, not with the sealed current-user-only template the bootstrap requires.
Whichever comes first in the documented first-run order (the pinned tools must be installed and
verified before any mutation) makes the later canonical setup Apply fail closed.

Reproduction and control: the failure reproduces in two independent clones inside one fresh snapshot,
and also when the initial-route DryRun is removed entirely (`diag2b`), so it is not an artifact of
the lab's step order. Host-side corroboration: this machine's own `%LOCALAPPDATA%\ai-agent-dotfiles`
is owned by the local administrator group with three **inherited** ACEs and
`AreAccessRulesProtected=False`, i.e. the identity-path canonical setup has never run here either —
the recorded Phase 2 canonical state came from internal-sandbox runs with injected roots.

**Controlled experiment (`route-diag5.ps1`, labeled diagnostic).** In one fresh snapshot the lab
recorded the directory's state (`owner = BUILTIN\Administrators`, `AreAccessRulesProtected=False`,
only child `tool-cache`), then rewrote only that disposable directory's DACL to a protected,
single-ACE current-user-only shape and reran the released route: the DryRun PASSed again, and the
Apply still FAILED with the same `home-authority-bootstrap-owner-dacl-mismatch`. A hand-made DACL is
therefore not sufficient; the directory must be produced by the product's own sealed template, which
is precisely what the fix has to arrange. No further workaround was attempted — a lab-side bypass of
the sealed check is exactly what this gate exists to prevent.

### 6. Impact and disposition

While the policy is `released`, the canonical setup route is the only producer of the sealed
authority prefix that sync, activation, task-overlay and rollback Apply assert before mutating
(`sync.ps1:977-981`). On a machine that has the pinned tool caches installed — which the same
contract requires before any mutation — that route cannot complete, so the primary mutation surface
is unreachable on a fresh machine. **The candidate is rejected** under Task 8 Step 4, and the fix is
production code: either keep the pinned tool cache outside `PrivateRootBase`, or have the bootstrap
adopt a pre-existing base that holds only the tool cache, or have the tool installers create that
directory with the sealed template. Fix blast radius (read-only analysis, so the follow-up can be scoped): scripts/home-authority-common.ps1
(the check), scripts/json-artifact-common.ps1 (the tool-cache root) and both scripts/install-*.ps1 files
are listed in scripts/runner-policy.psd1 ToolchainPaths, so any fix changes ToolchainPolicyHash - the
Git-private runner approval must be renewed and a new release candidate cut, after which Task 8 Steps 2-3
repeat. Relocating the cache additionally touches the approved-runner artifacts that record ToolCacheRoot
(tests/fixtures/artifacts/approved-runner-state.valid.json, tests/approved-runner.tests.ps1). Which of the
three fixes is taken, and the acceptance of that re-approval, is an owner decision in the owning phase,
not autonomous Task 8 work.

No dirty patch was applied, no policy byte was touched and no
gate was weakened.

### 7. What did not run

The environment/task/rollback Apply routes, the authority routes (adopt, migrate, repair-adopt,
takeover), retirement and recovery, and Task 8 Step 3's gate list all sit behind the blocked setup
route; Step 3 is moot until a new candidate exists. The route recipes and seeds for those routes were
derived from the CLI surfaces and the test fixtures during this window and remain available in the
lab harness. Remote CI is still unreadable from this machine (`gh` unauthenticated), so Step 5's
STATUS totals would have to record local evidence only.

### 8. Host non-mutation evidence

`host-roots-manifest.ps1` before/after manifests are byte-identical for `~/.claude/skills`,
`~/.codex/skills` (66 files), `~/.agents/skills`, `%APPDATA%\reasonix\skills`,
`%LOCALAPPDATA%\ai-agent-dotfiles` (tool cache only) and the three generated skill trees in the
working clone; `GitHead` (`51044a5`), `git status --porcelain` and the stash list are unchanged.
Every Apply above ran inside a disposable Windows Sandbox identity; no real home, authority, live
root or backup was written. This window grants no release or deployment authorization.

## 2026-09-23 Task 8 Step 2 remediation window (owner-authorized option 1): three defects, two of them new

Owner decision: "批准，选1" — implement option 1 for the setup-route blocker (keep the pinned tool
cache outside `PrivateRootBase`). Implementing it exposed two further defects in the same released
identity path. Local commits: `097ff01` (cache relocation), `f553358` (recovery-remainder cast),
`23f458b` (committed Apply must exit 0).

### Fix 1 — pinned tool cache relocated (`097ff01`)

`Get-PinnedToolCacheRoot` now defaults to `<LocalAppData>\ai-agent-dotfiles.tool-cache`, a sibling of
the sealed private root base, following the convention the SID-scoped occupancy index already uses
(`root-claims-occupancy-common.ps1`). The cache is machine-local tooling state; no private root,
envelope or gate semantics changed.

Host migration on this machine: the legacy `<LocalAppData>\ai-agent-dotfiles\tool-cache` and the
then-empty private base were removed after asserting the base held nothing else, and the pinned tools
were re-installed and verified at the new path (`tmp/lab8/evidence/host-migration.json`). This host
held no approved-runner state, so nothing needed re-approval here; on a machine that does,
`ToolchainPolicyHash` moved and the approval must be renewed before the runner can verify again.

### Fix 2 — the recovery-remainder cast (`f553358`)

The canonical setup Apply then failed closed with

```
Safe tree containment path is missing: <profile>\[string].ai-agent-dotfiles-canonical-recovery
```

The cause is argument-mode parsing, not path logic. In

```powershell
Join-Path $cumulativeParent [string]$segment
```

PowerShell binds a bare `[string]` as `-ChildPath` (a type literal rendered as the text `[string]`)
and `$segment` as `-AdditionalChildPath`, so the joined path became `<parent>\[string]<segment>` and
the next containment walk failed. The child directory itself was created with the correct name
because the same cast inside the method call is parenthesised, which made it look like a walk
problem. The loop only runs when the canonical recovery root does not exist yet, and the fixture in
`tests/canonical-transaction-apply.tests.ps1:77` pre-creates that root, so no test covered the
fresh-machine remainder path. The cast is now parenthesised and an AST scan of `scripts/` reports
zero argument-mode type literals. Seams re-pin: count unchanged (16273), exactly one `InvokeMember`
row moved (that line's extent text), verified with `tmp/seams-delta.ps1`; the dynamic-command digest
is unchanged.

### Fix 3 — a committed Apply must exit 0 (`23f458b`)

The Apply branch of `canonical-transaction.ps1` never left the script: after printing the PASS
document with `canonical-apply-committed` it fell through to the create-new guard of the DryRun path
below, found the reviewed plan file the earlier DryRun had written, and exited 1 with
`canonical-plan-exists`. A committed transaction therefore reported failure to its caller, and the
public wrapper forwards that exit code. The apply suite drives the CLI only with `-DryRun` and
exercises Apply through the engine functions in-process, so the CLI's success exit path was
untested. The branch now ends with an explicit `exit 0` after its `finally` block; the interlocked
exit-75 contract is unchanged and no other CLI in `scripts/` shares the shape.

### Finding — released-policy fixtures write real identity state once the route works

Running the focused suites after Fix 2 showed that the released-policy pins in
`tests/repository-policy.tests.ps1` and `tests/canonical-command-result.tests.ps1` drive the public
CLIs on the **real** Windows identity (no internal sandbox). With the setup route no longer failing
early they *complete*: the host's `<LocalAppData>\ai-agent-dotfiles` gained a complete sealed
bootstrap prefix (`backups`, `control`, `control/{canonical-roots,homes,live-transactions,live-mutation.lock}`)
plus three `canonical-roots\<repo-id>.json` claims for fixture repositories, timestamped with the
suite runs. The residue was captured (`tmp/lab8/evidence/host-test-residue/`: the residue list and
the three claim files) and then removed, restoring the pre-run state (private base absent, pinned
caches at the new sibling path). No live skills root, backup or repo file was touched.

Two consequences, both for the owner:

1. **The pins encode the defect.** Nine released-policy assertions now observe a different world:
   `canonical-command-result` reports 66 passed / 7 failed (routed setup Apply no longer fails closed
   at the manual-recovery gate; MISSING setup Apply no longer "creates no ControlBase or private
   prefix"; the existing-`canonical.lock` case and the two post-holder-release cases moved with it),
   `repository-policy` fails "the public live-recovery DryRun fails closed on the released host
   authority path (released)" (it now passes the authority gate and fails at
   `live-recovery-transaction-unknown`), and `automation-safety` fails "environment rollback apply
   proceeds past the released Assert and fails closed before production work (released)". These must
   be re-derived and re-pinned with the released contract reviewed — but only *after* the fixtures
   stop writing real identity state, otherwise the new pins would lock in a test suite that mutates
   the developer's machine.
2. **The proposal's own expectation is violated by the test suite.** The validation expectation is
   "zero live/authority/backup path changes on real homes"; these pins satisfy it today only because
   the route used to fail. The hygiene fix is to run those released positive routes under the
   internal sandbox (as the other suites do) and keep only fail-closed assertions on the real
   identity.

### Lab re-run on the fixed tree (`chain3`, `tmp/lab8/evidence/chain3/`)

- **Canonical setup Apply: `canonical-apply-committed`** — the authority prefix, the canonical
  recovery root and the claim are created on a fresh disposable identity for the first time. The
  step's exit code was 1 only because of Fix 3.
- **Initial sync Apply: exit 0**, receipt-backed host, `would add (29)` / 0 updates / 0 prunes,
  receipt `…\backups\5d92f9df…`, state hash `262a27a1…`; all four roots then exist and the Codex live
  root holds 15 skills.
- **Environment activation: DryRun PASS** (plan hash `2c3d3424…`) and **Apply exit 0** (receipt
  `…\backups\2404ff96…`, state hash `fc6267d8…`, journal `…\control\live-transactions\812caf7a…`).
- **Rollback DryRun PASS** (`environment rollback plan created`, PlanHash `dbab9597…`).
- **Task overlay DryRun FAIL**: "Task overlay targets 'work', but this task command targets 'full'."
  The tracked `.agent-harness/task-skills.psd1` targets `work` while the initial route always deploys
  the `full` environment (`sync.ps1:342`), so the task route cannot run right after the initial
  route. Not yet classified as a defect or as a lab parameter choice.
- **Rollback Apply FAIL**: `Invoke-SealedEnvironmentRollbackTransaction` cannot bind `Targets`
  because it is null (`rollback-harness-env.ps1:707`). Further defect candidate for the next window.
- Host real roots byte-identical before/after; every Apply above ran inside the disposable sandbox.

### What this window did not do

Task 8 Step 3's gate list, the re-derived pins, the test-hygiene change, the two open findings above,
and the runner re-approval all remain open. Each of the three fixes moves `ToolchainPolicyHash`, so
the candidate must be re-cut once the tree is green; the release is not accepted and no real-machine
Apply was performed.

### Handoff state at wrap-up (2026-09-23; local commits `097ff01`, `f553358`, `23f458b`, `e57e129`)

- Suite status on the working tree: `canonical-production-seams` 56/0, `canonical-transaction` 64/0,
  `canonical-transaction-apply` 21/0, parse gate 179 files, secret scan clean, `git diff --check`
  clean. `canonical-command-result` reports 66 passed / 7 failed, `repository-policy` fails one
  released pin and `automation-safety` fails one released pin — all nine are the pre-fix-encoding
  assertions listed above.
- The host residue was captured and removed twice
  (`tmp/lab8/evidence/host-test-residue/residue-list.json`, `residue-list-second.json`); the second
  round was produced by a single suite run, which is the direct evidence that those fixtures must be
  sandbox-isolated before the released pins are re-derived. Final host state: the private base is
  absent and the pinned caches are present and verified at
  `<LocalAppData>\ai-agent-dotfiles.tool-cache`.
- The four commits are local and unpushed. The lab harness, the evidence trees and the helper
  scripts stay machine-local under `tmp/lab8/` (gitignored), including `run-route.ps1`,
  `payload/route-*.ps1`, `host-migration.json`, `host-test-residue/` and the `chain1`/`chain2`/
  `chain3`/`diag*` evidence directories.

## 2026-09-23 Multi-agent audit and ordered backlog

本节记录所有者要求的多 agent 项目梳理及随后授权的记录工作。审查基线为本地
`main@344ed4696a672ca23a129cfd40e2200d15830d7c`，审查开始与结束时工作区干净；相对当时远端
`main@627ef3f623dff4ba3005eb92ad7427d08da61cd4` 领先 5 个提交。主 agent 加 5 个 sub-agent
分别核对任务证据、生产路由、测试隔离、远端 CI、配置与文档；主 agent 复核主要代码位置并汇总。
此处记录结论和待办，不实施修复、不重开已完成阶段、不授予发布或真实 Apply 权限。
本节代码行号均按上述审查基线定位，后续修改应按符号和调用链重新查找。

### Findings and evidence boundaries

1. **高优先级，确认的测试身份隔离缺口。**
   `scripts/canonical-transaction.ps1:55–56` 直接解析真实 Windows identity，`:78–83` 的
   capability containment 只检查 RepoRoot/PlanPath，不包含真实 private roots。
   `tests/canonical-command-result.tests.ps1:765–775` 即使用现有 sandbox helper 仍使用真实
   authority；`:830–837` 还按真实 identity 清理 claim，且在最初 private base 不存在时递归
   删除该 base。本次另定位 `tests/canonical-recovery.tests.ps1:34,200–206` 的同类裸 setup
   Apply 路由，未执行该套件，不能新增一个实测失败计数。修复必须证明计划、authority 和清理
   根均在受控 fixture 内；机械替换为现有 helper 不足以隔离 canonical setup。
   前节的九项失败只是历史运行的 `7+1+1` 观察，不是全仓穷尽清单。前节真实残留证据保留；
   本次并未证明 `repository-policy`、`automation-safety` 各自创建真实 bootstrap，两者的
   旧失败预期还依赖主机 authority 状态。测试 runner 本身没有提供 OS 身份隔离。
2. **高优先级，已定位零变更 rollback 缺陷。**
   `scripts/live-transaction-common.ps1:1378` 跳过同 hash 动作；`:1462` 普通赋值把空目标
   集合变成 `$null`，`:1479` 将其传给 `:963` 不接受 null 的 Targets 参数。此前
   `:1434,1448` 已写 journal header 和新 receipt，因此这不是零写失败；普通 sync/activate
   后续会被 `:3213–3215` 的 unfinished gate 拒绝。既有 lab 的
   `tmp/lab8/evidence/chain3/33-artifact-rollback-plan.json` 有 29 个同 hash 目标，34 号证据
   记录绑定错误，36 号证据为 `abandon-eligible`、receipt COMPLETE。子 agent 以纯内存
   PowerShell 复现空集合变 null 及参数绑定失败，未加载生产脚本。应保留空数组或复用列表
   标准化函数，并补公共 CLI 零变更回滚、事务关闭及后续可继续操作的回归。
3. **高优先级待验证，rollback 的全局 unfinished 门禁疑点。**
   `scripts/rollback-harness-env.ps1:676–707` 验证所选 source transaction 后进入独立
   rollback 实现，后者在 `scripts/live-transaction-common.ps1:1434` 新建 header；未见
   普通 host 在 `:3213–3215` 使用的全 authority unfinished scan。已有未改变 live/state
   的未完成事务时，旧 activation receipt 可能仍符合 source 校验而允许再开 rollback。
   这是静态调用链发现，尚未隔离动态复现；验收应要求兄弟事务 unfinished 时拒绝，并且不增加
   journal/receipt。不能将该推断写成已观察到的第二次执行结果。
4. **实验路线归因，暂不认定 `work/full` 为产品缺陷。**
   tracked overlay 与 `scripts/task-skills.ps1:95` 的默认值均为 work；既有 lab 脚本
   `tmp/lab8/payload/route-chain.ps1:113,116` 显式传 BaseEnv full，触发 `:276–277` 的一致性
   拒绝。先纠正实验步骤并验证 work 环境的完整 task 路线；删去参数本身不构成验收通过。
5. **当前规则、使用文档及状态指针漂移。**
   `CLAUDE.md:62–70,105`、`README.md:87–89`、`docs/ONBOARD_NEW_MACHINE.md:7,55–56,401`
   与 `docs/RESTORE.md:3–4` 仍承诺 interlocked 或裸 DryRun 必然 fail-closed；实际 policy
   已为 released。onboarding `:179–191` 强制调用已退役 standalone backup，`:359,390,392`
   使用已删除的 sync HomeRoot 参数，`:312,348,423–425` 的 merge/promote/activate 缺少
   PlanPath。本次记录修正本文件顶部与 STATUS 当前入口，其他指南修复仍待办；历史正文保留
   当时事实。本次 GitHub 只读查询可用，前节因 gh 未认证而无法查询 CI 的描述仅属于当时窗口。
6. **历史报告的机器私有字段。**
   tracked `imports/skills-reports/skills-analysis.json:10,12` 及同类条目包含机器标识和
   本机 source path；`imports/skills-reports/auto-merge-report.json:777` 含本机绝对路径。
   本节不复制这些值，也不将其称为凭据泄露。后续脱敏保留分析事实，补齐报告提交规范。

前一 remediation window 的缓存迁移、recovery cast、Apply exit 修复
（`097ff01`、`f553358`、`23f458b`）已有本地提交，不应重复实现；仍需补 fresh recovery root
与公开 Apply 成功退出码的回归。现有 `tests/canonical-transaction-apply.tests.ps1:77` 预建 recovery root，
不能替代 fresh-machine 路径验证。canonical 正向用例必须先有可证明的隔离边界再运行。

### Remote CI snapshot

前一轮审查读取了失败 run 的原始日志；本次落盘时在 **2026-09-23 22:42 UTC+8** 重查远端
main 与运行状态。以下是时间戳快照，后续接手需刷新，不自行推导运行中的最终结果：

- [Validate #135](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/35852562723)，
  main `627ef3f`：failure。shard 1 与 gates 通过；shard 2 为 7/8，
  `root-claims-registry.tests.ps1:7301` 的 recovery 子进程触发 15 秒夹具期限，不是 suite
  timeout；shard 3 为 25/27，sync 的旧 released 断言失败，live-recovery 达到 900 秒
  suite timeout。后者更深根因未知，不能仅据此增加预算。
- `codex/ci-regressions-e4-preflight` 与本地 remediation 是独立两条线；审查时其相对远端
  main 有 `e4e1dac`、`a326dda`、`3b835f1` 三个提交，没有 open PR。工作涉及隔离 released
  入口 fixture、补 frozen 输入及区分 recovery 执行期限，未包含本地五个提交。
- [Validate #137](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/35863733603)，
  `a326dda`：只有 shard 2 的上述夹具期限失败，其他 shard 和 gates 通过。
- [Validate #138](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/35873759132)，
  `3b835f1`：落盘刷新时仍 in_progress；审查时 gates 通过、三 shard 运行中。
- 本地审查基线 `344ed46` 的 Actions 查询为零个 run；本地检查不是 CI 通过证据。

静态核对的 42 套测试全部且仅出现一次于三分片，声明预算均小于对应 job 期限；没有发现
分片遗漏。当前 workflow 没有上传完整结构化 summary/manifest 的 artifact 步骤，属于后续
可诊断性改进项，不是本次新证明的功能失败。

### Ordered backlog and acceptance

| 顺序 | 任务、并行安排与依赖 | 完成依据 |
|---|---|---|
| 1，串行，主 agent | 先核对现有 CI 修复分支的最终结果和改动范围，协调与本地 remediation 的整合；此步骤计划 0 个 sub-agent | 确定基线、待合入改动和文件归属，不重复开发、不覆盖其他工作 |
| 2，并行，3 个 sub-agent | A：测试身份隔离与旧断言；B：rollback 空集合及 unfinished 疑点；C：当前指南和历史报告脱敏。主 agent 协调公共 helper/共同测试文件；有交叉时先串行完成公共 seam | A 证明所有写入/清理均受隔离并覆盖 pristine/完整 authority/争锁；B 验证零变更成功及兄弟 unfinished 拒绝；C 示例匹配接口、无过时安全承诺或私有值 |
| 3，串行，主 agent | 依赖整合后的修复树；计划 0 个 sub-agent，统一复算需更新的 pins，运行完整本地门禁 | 固定代码树的完整结果、无未解释失败/超时；不得沿用旧通过数 |
| 4，串行，主 agent | 依赖绿色组合树及适用授权；计划 0 个 sub-agent，更新受影响的 runner approval、重切不可变候选，完成 Task 8 各互斥路线的独立 disposable snapshot lab 与 gates/CI | 全部证据绑定同一候选 SHA；失败拒绝候选，不 dirty patch，不以状态文档后继提交代替实验候选 |
| 5，串行，主 agent | 候选接受后再推进 Task 9；计划 0 个 sub-agent | 真机只读与符合路由的 DryRun，停在真实 Apply 前 |

Phase 2/3、Phase 4 Tasks 1–7、SID occupancy 实现和已批准的 CI 分片不重新列为未完成。
config-sync、平台能力注册、模块去重等发布后改进另列后续范围，不默认变成本轮 release
验收前置条件。本记录没有执行上述修复、批准真实 Apply、触发跨项目修改或远端发布。

### Actual checks and retained evidence

- 原审查基线 `344ed46`，PowerShell 7.6.6：parse gate 退出 0，179 文件通过；pinned gitleaks
  加 fallback secret scan 退出 0、0 阻断项，1278 keyword hints 为非阻断提示；
  `git diff --check` 退出 0。机内证据在 `tmp/audit-20260923/`，不提交原始日志或临时报告。
- source/manifests 静态一致：Claude 7、Codex 15、Reasonix 7；work 为 1/1/1。未发现 generated
  skills、envs/state、raw imports 或 runtime backups 误入 tracked。检查到的可复用 harness
  模板未固定模型或推理档位；此结论不代替全配置部署验证。
- 审查未运行全套测试、危险 released fixtures、build、lab 或真实 Apply，不是全项目测试通过
  证明。模型身份、费用及人工工时为 unknown；不从等待时间推断。
- 本次记录阶段复用上述证据，不把历史检查写成新跑；文档落盘按普通文档流程检查扫描、链接与
  diff，不运行已知存在身份隔离风险的套件，最终文档检查结果在本次交付说明中单独报告。

## 2026-09-23 Staged completion plan

按所有者要求制定 [后续任务分阶段完成计划](../../docs/superpowers/plans/2026-09-23-post-audit-completion-plan.md)，
规划基线 `dfa9d20`；主 agent 与 3 个只读 sub-agent 分别整合安全修复、发布验收及延后工作。
计划明确 S0 基线协调、S1 五路并行修复/审查、S2 固定候选、S3 全门禁、S4 lab/CI 接受、
S5 Task 9 与归档、S6 独立后续工作包。后续执行按该细化计划安排，上节简表保留为审查时建议。
规划时 22:50 UTC+8 重查 main/#135、修复分支/#138 与 open PR；#138 仍运行中。
计划纠正已 released 后无需再次 flip，以及 initial 计划必须先于 canonical setup 的具体顺序；
本次只修改计划和入口指针，未开始修复、运行危险套件、实验、发布或真实 Apply。
## 2026-09-23 CI repair window: released public-entry fixtures

This window follows the owner's request to repair the two failures from fixed
[run 35733693990](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/35733693990), attempt 1,
head `51044a55fc0dd8991e2ac25dad36fb1369a9027b`. It starts from
`627ef3f623dff4ba3005eb92ad7427d08da61cd4`, preserving the intervening disposable-identity lab
and its rejection. Work takes place in an isolated checkout; no production script, policy,
workflow, suite budget, live deployment or previously recorded evidence is changed.

### Fixed failure evidence

The repository gates and shard 1 passed. Shard 2 discovered 8 suites, passed 7 and failed 1;
shard 3 discovered 27, passed 26 and failed 1. Across all shards this is 42 discovered,
40 passed, 2 failed and 0 suite timeouts. The root-claims helper's 15-second child deadline
is an internal test failure, not a runner-level suite timeout. Its killed child's streams were
not retained by the old helper. The sync failure is the `Code -ne 0` assertion for a bare
released public DryRun; the next zero-plan assertion was never reached in that CI log.

The immutable prior audit receipt is `E4-GAP-REVIEW-20260923/dotfiles-ci-final-001/final-receipt-001.json`,
SHA256 `3f7f0dfaf78f51d547c498571e27a652952639e96c72b79ebab86ec53de10f70`.
Raw shard-2 and shard-3 log SHA256 values are respectively
`6c28246f9094f95bbe1406bbce31319a5cba281916ae3d6334f236326244a001` and
`bdecbd01554e7d9f5423757ac71f5488301c109f57745e876623238f2c689fa2`.

### Repair and local evidence

- Sync now exercises released public identity resolution against a pristine fake home using a
  copied toolchain with only OS identity/default-live locators replaced. The child first proves
  it inherited a genuine sandbox capability, clears it, then calls the public CLI. Positive checks
  bind the schema 3 plan, both hashes, target repository and each platform root; live and private
  authority paths remain absent. A missing known-folder case keeps exact refusal and zero-plan checks.
  The interlocked refusal remains explicit. AGENTS guidance and its repository-policy pin now
  distinguish sandboxed maintenance validation from released public behavior.
- The original sync predicate was replayed as RED from a real isolated public invocation returning
  0. The complete mode-gates window is GREEN (exit 0, 25.344 seconds), including the missing-folder
  negative. This duration includes fixture preparation and existing mode cases; it is not a measured
  incremental cost. The unchanged 1200-second full-suite budget still requires complete-run evidence.
- Root-claims now binds the public recovery child's OS identity/default-live locators to the same
  fixture as its canonical plan and lock-order holder. Only copied locators change; the production
  resolver, plan validation, locks and recovery engine execute unchanged. Pinned tool bytes are
  verified before copying into an isolated fixture cache; this does not fix or accept the real
  cache/bootstrap interaction documented by the lab. The helper retains its 15-second default,
  clears inherited internal capabilities and reports elapsed time plus both drained streams after
  bounded kill/reap, instead of discarding the timeout scene.
- Three fresh-process read-only loads of the required recovery/registry/engine modules took
  3.344, 3.078 and 2.984 seconds including process startup and exited 0. They also confirmed that
  the native identity's ControlBase differs from the old fake ControlBase. These observations
  support fixing the mixed fixture but do not prove why the historical CI child exceeded 15 seconds,
  and do not justify enlarging that deadline.
- The complete local sync attempt exited 1 at the pre-existing `Set-TestDirectoryCurrentUserOnly`
  owner assignment, after the new mode cases passed. An isolated unchanged-helper probe reproduced
  the permission error. Separate new-directory probes showed DACL-only PASS but SetOwner FAIL.
  The root-claims recovery fixture stops at that same owner-setting prerequisite before its public
  recovery child starts. No helper or host privilege was relaxed to turn these failures green.

Private raw stdout/stderr, exit codes, timing and source hashes are retained under
`E4-CI-REPAIR-20260923`, separately from tracked files. The sync diagnostic receipt is
`sync-001/diagnostic-receipt-001.json`, SHA256
`e3b2fe433863e45b7a1950f665ea8f61ff9e0d9fb97b0470806130f6a5ad2d51`.
Initial diagnostic setup failures remain in that evidence collection and are not product verdicts.

### Validation boundary at candidate preparation

Pinned validator and gitleaks VerifyOnly, the PowerShell syntax check (179 files), the complete
repository-policy suite and the secret scan passed locally. Full sync/root-claims verification
has not passed on this non-elevated test host. The fixed candidate still needs the unchanged
repository-gates job and all three full test shards in CI; no historical green is substituted.
Two independent agents handle the two test files, with cross-review before the coordinator's
single integration commit. Later candidate/CI verdicts are appended below when actually observed.

This is CI fixture repair, not Task 8 production acceptance or E4 implementation. The lab's
rejected-candidate disposition remains in force, and no real-home Apply is part of this window.

### First candidate CI and complete fixture policy inputs

The owner-authorized feature-branch push published
`e4e1dac7c07889c1a87f38c98922d52d4f796567` and triggered
[run 35856160012](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/35856160012),
attempt 1. Repository gates passed. Shard 2 (`107165009884`) completed with 8 discovered,
7 passed, 1 failed and 0 suite timeouts. Its sealed-prefix check passed, then
`New-CanonicalSetupPlanPayload` failed to hash `.gitleaks.toml` in the copied toolchain.
The recovery child was not reached, so this result establishes neither a new recovery timeout
nor a recovery pass. Shards 1 and 3 had not completed at this follow-up's preparation.

The frozen `ToolchainPaths` list contains 79 inputs: 52 scripts, 23 schemas, two tool locks
and two root files. The copied fixture lacked precisely `.gitleaks.toml` and `bootstrap.ps1`.
The six-line follow-up copies both byte-for-byte and invokes the real
`Get-CanonicalToolchainPolicyHash` before owner-sensitive claim preparation; it changes no
production source or timeout. `DataPathspecs` entries are hash inputs as strings, not additional
file reads in this function, so no unrelated source trees are copied.

An extracted-helper probe against the first candidate reproduces the exact missing-file error
(RED, exit 1). The repaired helper passes actual policy hashing, real pinned tool leases,
identity/path checks, stream/nonzero-exit checks and bounded timeout/reaping (GREEN, exit 0).
The sealed prefix is COMPLETE before, after and finally, with one unchanged snapshot hash.
Independent host maintenance had relocated the original default tool cache; this diagnostic
therefore selects the prior verified fixture cache as its read-only source. Failed cache-lookup
setup attempts remain preserved, and no real cache or host path was written. The production
fixture and its byte checks are unchanged apart from the two files and early hash call.

PowerShell syntax passed for all 179 files, and independent source review approved the six-line
change. This is focused validation; the local SetOwner prerequisite still prevents a complete
recovery case, and the follow-up must pass all unchanged CI jobs on its own commit.
Private receipt `E4-CI-REPAIR-20260923/root-claims-001/policy-fix-receipt-001.json` has SHA256
`9b1f41456248de86865b692d81e4f545849368ea1af73b7b931a445967d5f3c6`.
The first candidate's raw failed-job log has SHA256
`d940a02edc1de3cdf6749ddc71604b0f3b7a1f88dedd84558fd29d5409063b59`;
its append-only audit records the run, attempt, head, check identity and exact failure stage.

### Released recovery deadline binding

The follow-up `a326ddac89d9f5ce0ad334ca94a7eb575be9319a` was pushed to the same repair
branch. Its [run 35863733603](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/35863733603),
attempt 1, completed with repository gates and shards 1 and 3 passing: 42 discovered,
41 passed, 1 failed, 0 suite timeouts. Root-claims passed the complete sealed-prefix check,
public DryRun, held-lock busy refusal and zero-write check. Its released child then reached
the 15000ms deadline; elapsed time after kill/reap/drain was 15046ms, with the child reaped,
both drains completed and both captured strings empty. This now establishes the remaining
failure on a complete fixture; it does not locate the child's internal stopping point.

The 15000ms helper bound originated in `86255452f0f535da400edc306c935881d24c4211`, when
the tracked policy was interlocked and the released-holder assertion required only exit 75
and zero writes. `5954503f605b20d0fc5399cb1f35a2d2ae820b61` later required released Apply
to complete the reviewed abandon, retaining that same bound. The selected specifications
require immediate lock-contention refusal, not a separate 15-second released-engine SLA.
Earlier records report a released fixture pass but provide no individual-call duration;
this window does not claim to be the first historical execution of that engine.

Static review counted at least 20 real Schema validations in the header-only abandon engine:
16 nonempty journal snapshot batches plus four new-artifact validations. Each lease revalidates
the pinned bytes and executes a version probe before invoking the validator, so the engine
alone starts at least 40 external processes. These are source counts, not a measurement of
the exact CI delay. Holder cleanup releases both locks, and native contention refuses rather
than waiting; no deterministic missing release was found.

A fresh no-network Windows Sandbox instance used a normal disposable user, guest-local
PowerShell 7.6.6 and fixture trees, read-only source/tool inputs, and one writable evidence
mapping. The candidate archive was initialized as a guest Git repository before valid
measurements. Three fresh fixtures completed the same full contention case: released Apply
took 11611ms, 11376ms and 11566ms. The first and third retained the original 15-second bound;
the middle measurement used a diagnostic-only 120-second helper bound and is labeled as such.
The first measurement's DryRun and busy refusal took 4920ms and 2758ms, respectively.
All nine behavior assertions passed, including matching plan results and preserved zero writes
for the lock loser. Local timing does not establish hosted-runner timing or its exact slow phase.

The minimal correction gives only the complete released Apply an explicit 60000ms bound.
DryRun, held-lock contention and interlocked refusal keep 15000ms; the helper default, all
result/identity/zero-write assertions, the 3600-second suite budget and CI job budgets remain.
The helper returns measured child-plus-drain elapsed time in the successful result, and the
released assertion prints it. On these new test bytes, the fresh focused case passed all nine
assertions with released Apply taking 11224ms. Syntax passed for 179 files, and independent
source review approved the nine-line diff. This functional test correction does not waive a
production performance contract or count as complete-suite verification.

Setup failures from the diagnostic kit are preserved: the guest's PowerShell 5.1 archive module
failed to load, and early source archives lacked Git metadata. Neither is a product verdict.
The final fixture state and per-call raw results were exported before stopping the one sandbox;
the final sandbox list was empty. The aggregate receipt is
`E4-CI-REPAIR-20260923/recovery-deadline-receipt-001.json`, SHA256
`b1664352ba1342c2dcb8f2f7ec546124b71bdf7d8ed0014f586241d3ea1ad16c`.
Independent history/source review is `root-claims-001/released-apply-deadline-review-001.json`,
SHA256 `9ca00cd6976508467f7c559709bfa40caa2acd4a860646474b860a5c19271513`.
The fixed CI receipt is `ci-audit-002/final-receipt-001.json`, SHA256
`d98a58db7983856beceb53ab938cb0cf0c6eedb93e484ae298310185ca14acad`.

The preceding `e4e1dac` run also had a genuine 600-second harness-env suite timeout.
The `a326dda` run passed that unchanged suite (339 assertions, approximately 591.274 seconds),
but does not repair or explain the earlier timeout. Its independent diagnostic record is
`harness-env-timeout-diagnostic-001.json`, SHA256
`7ecebe86856effdb2ac818799644f31c9fce52f62287b0736826fdd614582d48`.
All original failures remain distinct from the next candidate's required full CI verdict.

## 2026-09-23 Post-audit execution

所有者在计划编制后指示“开始执行”。主 agent 在独立 `codex/post-audit-completion`
worktree 整合 `48f17e1` 与 CI 修复线 `3b835f1`，保留两侧提交来源和活动记录；原工作区及
其他已有 worktree 未改动。S0 的两个只读 sub-agent 分别审查 CI 差异和身份解析/清理链。

23:35 UTC+8 的远端快照：main 为 `627ef3f`、无 open PR；Validate #138 的 gates、
shard 2（8/8）、shard 3（27/27）成功，shard 1 仍运行中。该结果不能代表整合树通过。
远端三个提交只修复测试 fixture、文档 pin 和完整 recovery Apply 的子进程期限；
其 15912 ms 的成功 Apply 证明旧 15 秒期限不足，并不替代本轮 canonical/rollback 修复。

S1 的公共隔离接口定为测试专用 copied toolchain：AST 精确替换副本中的 Windows identity、
default live roots、pinned tool cache 三个 locator；生产 resolver 和公开 CLI 不增加测试开关。
副本须包含完整 frozen inputs，工具缓存按锁验证且位于 sealed prefix 之外；所有父/子调用、
recovery 和异常清理须落在本次 owned GUID root，拒绝越界与 reparse。真实 identity cleanup
必须移除。静态安全审查通过前不运行涉及 canonical Apply 的宿主测试。

S1 并发为 5 个 sub-agent：A 独占 canonical fixture helper 与三套 canonical 测试；B 独占
rollback 引擎/入口和 backup-recovery 测试，先完成静态实现，动态测试须有隔离证据；
C 维护当前操作指南；D 维护报告忽略/保管规则并给出精确 index 清单；E 独立只读审查
隔离和恢复边界。主 agent 独占状态、计划、AGENTS、index 操作、pins、lab kit 和最终整合。
这些职责串行依赖 E 对 A/B 写入边界的复核；完整 gates 与候选接受仍在后续 S2–S4。
