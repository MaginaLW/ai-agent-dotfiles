# Live Safety Hardening

Last updated: 2026-09-13

Status: In progress. Baseline-reconciliation Task 1 is complete (5/5), the Phase 0 entry-interlock
subplan is complete (43/43), Phase 1 is complete (44/44), and Phase 2 is complete (52/52: Tasks 1-9,
with the one cross-authority proof recorded as a Phase 3-bound finding). Phase 3 Task 1 is complete
(7/7) and Task 2 is complete (5/5), so Phase 3 stands at 12/47 across Tasks 1-9. The corrected privacy
rewrite is published at `bbba28f`; GitHub Support ticket `#4697323` is resolved after server-side
garbage collection/cache clearing, and the 2026-08-27 old-SHA re-probe confirms the object is no
longer served. Phase 3 (shared environment authority and task overlay) has started: Task 1
(environment lock 3 freeze, env-build 3 consumption, and shared-state transition semantics) is
complete at 7/7 steps, Phase 3 overall 7/47 across Tasks 1-9 (7+5+4+5+4+8+5+4+5). The Task 5 and
Task 9 close-out evidence lives in the repository `STATUS.md` records; this per-task record resumes
with Phase 3 Task 1.

Policy: `ProtocolVersion=3`, `ReleaseState=interlocked`.

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
  impact). External design batch under the Grok/Luna/main-agent routing rule produced the durable
  recovery ticket design, the ledger-wiring owner-trio design, and the ticket test-block draft;
  the main-agent correction requires `route-cleanup-recovery` to join the envelope
  `ControlBase` children whitelist in the same commit as ticket publication. Remaining queue:
  slice 1 (ticket), slice A (wiring), slice B (failure matrix), then the resolver consumer layer,
  `PrivateRootBootstrapIntent`, protocol-v1 dispatch, and the forbidden-root matrix.

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

## Task 6 Step 3 in progress (2026-09-12): recovery dispatcher slices 1-4

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
have silently skipped it).

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
  worktree overlay lock or an explicit scope decision.
- The Step 1 source graph cannot use the public host (it rejects `environment` too): the reviewed
  recipe is the sealed plan fixture for the plan shape, a real header through
  `New-SealedLiveJournalHeader`, a real receipt through `Invoke-SealedManagedBackupReceipt` with
  `SourceOperationKind=environment`, and the engine through the test host's `produce` mode.
- Cases the current fixtures cannot produce: a committed environment→**task-overlay**→old-receipt
  chain (no task-overlay producer exists and the host rejects that kind), and `abandoned`/`rolled-back`
  source terminals (the engine only publishes `committed` or `failed-restored`).

## Remaining work

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
- `Assert-RollbackOverlayLockSupported` rejects a source header that binds a
  `WorktreeOverlayLockKey` with the reviewed `worktree-overlay-lock-not-implemented` token until
  the Phase 3 worktree overlay primitive exists.
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
interlock.

## Task 7 Steps 3-4 (2026-09-13): the executed rollback transaction, verified directly until Phase 3

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
`git diff --check` clean. The unified regression over the full catalog is recorded in `STATUS.md`.

## Pending items (2026-09-13, after Phase 3 Task 2)

**Phase 2 (Tasks 1-9) is complete and Phase 3 Task 1 is complete.** The remaining items are
design-bound or downstream:

1. **Phase 3 Tasks 3-9** — not started. Task 3 adds the `env authority` command surface
   (`status|migrate|adopt|repair-adopt|takeover`) on top of the frozen v2 status and the routing;
   Task 2's route decision and its next-operation strings are the contract Task 3 consumes. The two
   recorded design findings still feed the phase: the two recorded design findings still feed the phase: the
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

- **Sealed-file finding**: `tests/canonical-hard-kill.tests.ps1:8256` holds a real instance of the
  operator-as-parameter defect (three intended taint checks parse as one call, so two never run).
  Fixing it requires the full reviewed-load re-pin, so the parse-gate exemption list
  (`scripts/check-powershell-syntax.ps1`) intentionally keeps that one line exempt and every other
  occurrence fatal; the exemption must be cleared once the re-pin lands.
- **Placement-pinned checkpoint**: `RECEIPT_FINALIZATION` is pinned at the source boundary because
  the production host is not yet run as a killable child.

## Safety boundary

Do not run production Apply, backup, rollback, retirement, or live mutation.
`safety-protocol-upgrade-required` remains the expected production result.
