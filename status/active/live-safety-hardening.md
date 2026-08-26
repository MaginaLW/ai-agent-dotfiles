# Live Safety Hardening

Last updated: 2026-08-27

Status: In progress. Baseline-reconciliation Task 1 is complete (5/5), the Phase 0 entry-interlock
subplan is complete (43/43), and Phase 1 is complete (44/44). The corrected privacy rewrite is
published at `bbba28f`; GitHub Support ticket `#4697323` is open and the server-side purge remains
pending as a parallel external follow-up. Phase 2 Task 1 is in progress (0/6 steps; Phase 2 overall
0/52), while Phases 3-4 have not started.

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
- GitHub Support request: ticket `#4697323` is open with the required repository, changed-commit,
  affected-PR, and LFS audit metadata; no protected file contents were included.
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
- Phase 2 fourth-checkpoint unified validation: all 34 suites were discovered and passed exactly
  once with every runner error count zero; external create-new summary raw SHA-256
  `b8bc1c887ea1d8aaf9cffbc2ef63ded74779ea430920a117a377b695d21710ec` and independently recomputed
  discovery SHA-256
  `1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`. The hard-kill suite reached
  317/0 and the registry suite emitted 159 PASS assertions with exit code 0. Build (7/15/7), secret
  scan, and sync DryRun passed without production Apply, live-root mutation, Git index/ref mutation,
  or new hard-kill temporary-directory residue.

## Current checkpoint

Phase 1 Task 9 and roadmap Task 1 are complete. The branch/tag rewrite is published, but the old
head remains fetchable directly by SHA from GitHub. GitHub Support ticket `#4697323` is open; the
external checkpoint remains Support confirmation followed by an old-SHA probe, but it no longer
blocks unrelated hardening work. The implementation checkpoint now includes the reviewed read-only
authority/schema, sealed fake-ControlBase bootstrap/global-lock, held-lock registry core, and
caller-held canonical/current-route slices within Phase 2 Task 1. They complete no whole Task 1 step
and are not connected to production mutation routes. Task 1 remains 0/6 and Phase 2 remains 0/52.

## Current phase

Phase 2 is 0/9 Tasks and 0/52 Steps with Task 1 in progress at 0/6. Next are the remaining
identity/concurrency failure cases, production-route integration of the strict canonical-to-global
lock order and current-route witness, a real under-lock filesystem-capability preflight, and the
remaining forbidden-root matrix. Production Apply remains disconnected, and live-journal structure
and interpretation remain deferred to Task 4.

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
