# Live Safety Hardening

Last updated: 2026-08-30

Status: In progress. Baseline-reconciliation Task 1 is complete (5/5), the Phase 0 entry-interlock
subplan is complete (43/43), and Phase 1 is complete (44/44). The corrected privacy rewrite is
published at `bbba28f`; GitHub Support ticket `#4697323` is resolved after server-side garbage
collection/cache clearing, and the 2026-08-27 old-SHA re-probe confirms the object is no longer served.
Phase 2 Task 1 Step 1 is complete (Task 1 1/6; Phase 2 overall 1/52), while Phases 3-4 have not
started.

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

## Current checkpoint

Phase 1 Task 9 and roadmap Task 1 are complete. The branch/tag rewrite is published; Support completed
server-side garbage collection/cache clearing, and the old head is no longer available through the
web, REST, raw-content, or direct Git SHA probes. Ticket `#4697323` and the external privacy follow-up
are closed. The implementation checkpoint now includes the reviewed read-only authority/schema,
sealed fake-ControlBase bootstrap/global-lock, held-lock registry core, caller-held
canonical/current-route slices, the Step 1 identity/concurrency failure matrix, and the sealed
under-lock per-target/per-volume capability preflight with held exact-slot cleanup within Phase 2
Task 1. Step 1 is complete (Task 1 1/6); the capability preflight advances Step 2 without completing
it and stays unconnected to production mutation routes.

## Current phase

Phase 2 is 0/9 Tasks and 1/52 Steps with Task 1 at 1/6. Next are production-route integration of the
strict canonical-to-global lock order and current-route witness, resolver/fixed-envelope consumption
of the sealed per-target capability evidence, the `PrivateRootBootstrapIntent` setup path and
protocol-v1 public dispatch, and the remaining forbidden-root cases, including applying the complete
forbidden-root matrix before accepting any default/custom claim. Production Apply remains
disconnected, and live-journal structure and interpretation remain deferred to Task 4.

Pre-lock `MetadataOnly` TargetContext is discovery/planning evidence, never mutation authority.
The sealed read-only registry now recaptures a supplied current route only under the genuine
caller-held lock pair. Future production plan/Apply consumers must hold all required locks, including
the global live lock, then recapture the full no-follow TargetContext and reject any drift before
backup/workspace creation.
The current sealed bootstrap and route snapshot accept or report read-only evidence only; they are not
the production filesystem-capability preflight required before release.
Pristine bootstrap validation is now separate from the exact fixed post-bootstrap envelope; arbitrary
children remain fail-closed. Canonical-root-claim v1 has no GitCommonDir locator, so the current
canonical namespace and setup state resolve only through the genuine caller-held witness; no
production route supplies it yet. Before Task 4 defines the live-journal contract, any normalized UUID
live-transaction directory is inventoried as unresolved and blocks mutation as recovery-required
rather than being interpreted heuristically.

## Safety boundary

Do not run production Apply, backup, rollback, retirement, or live mutation.
`safety-protocol-upgrade-required` remains the expected production result.
