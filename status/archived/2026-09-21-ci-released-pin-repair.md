# CI released-tree pin repair — 2026-09-21

The owner pushed the release candidate and the follow-up documentation commits to `origin/main`
through `67bfdc6`. The sharded CI workflow's first two runs (both on trees carrying
`ReleaseState=released`) came back with all three shard jobs red while the gates job stayed green:

- Run #128 (`68e9903`): success — the old single-job structure's last run, closing the R3
  harness-authority recurrence item.
- Run #129 (`eeedc46`): failure — shard 1/2/3 red, gates green.
- Run #130 (`67bfdc6`): failure — same shape.

GitHub job logs require admin rights (anonymous fetch is refused), so diagnosis ran from a
detached `67bfdc6` worktree with per-suite reproduction through the repository runner.

## Root cause

`bffa7d7` flipped the tracked policy after verifying only the four suites that `15deede` had made
policy-state-aware (automation-safety, backup-recovery, live-recovery, repository-policy). Nine
more suites still pinned interlocked behavior unconditionally. `67bfdc6`'s documentation
centralization additionally rewrote the AGENTS.md/README.md interlock passages that
`repository-policy.tests.ps1` pins verbatim, and `cef82f9` had already repaired harness-env's three
policy assumptions. On the released tree:

| Suite | Failing pins on `67bfdc6` |
|---|---|
| repository-policy | 4 documentation pins (AGENTS.md/README.md wording) |
| canonical-transaction | normalize Apply `Code 75 + canonical-apply-interlocked` |
| skills-import | normalize Apply `Code 75 + canonical-apply-interlocked` |
| doctor | doctor output must carry `safety-protocol-upgrade-required` |
| task-skills | `-Automatic` refusal must carry `safety-protocol-upgrade-required` |
| canonical-command-result | 8 setup/merge/recover pin assertions |
| canonical-recovery | 2 Apply pin assertions plus the consumed-plan chain |
| harness-authority | sandbox-外 adopt Apply must carry `safety-protocol-upgrade-required` |
| root-claims-registry | contention-winner recover Apply pin plus its zero-write companion |
| harness-env | (already repaired by `cef82f9`; both-policy fixtures) |

`approved-runner` and `live-recovery` referenced interlock tokens but passed on the released tree:
approved-runner's pin is environment- and policy-stable, and live-recovery was already
policy-aware.

## Repair

Every affected pin now branches on `$script:IsReleased` (the `15deede` pattern): the interlocked
branch keeps the original fail-closed pins byte-for-byte, and the released branch pins the observed
post-flip contract per surface — exit code, exact diagnostic token, and command-result document
shape, observed by dumping each failing call on the `67bfdc6` worktree (never guessed from another
surface). The observed released contracts:

- setup/normalize/merge Apply on fixtures without a completed bootstrap: exit 1 with
  `manual-recovery-required` (setup) or `canonical-setup-required` (merge),
  `Result` `FAIL`/`WARN`, PlanHash bound in the result document.
- public recover-abandon Apply: **completes** the reviewed abandon — exit 0,
  `canonical-recovery-applied`, `Result: PASS`, `LifecycleKind: no-transaction`; a second apply of
  the same plan is refused with `reviewed-plan-consumed`; the fixture tree records the completed
  abandon (root-claims registry fixture) while the canonical control base stays byte-identical
  (canonical-command-result fixture).
- sandbox-外 adopt Apply: exit 1 at the home-authority bootstrap gate
  (`home-authority-bootstrap-manual-recovery-required`).
- doctor reports `release state released` instead of the interlock warning.
- the removed task `-Automatic` switch is refused at the public automatic-apply gate
  (`task-overlay-automatic-removed`).

repository-policy's four documentation pins were aligned to the current wording (released-state
guidance, retired standalone backup entry, policy-versus-acceptance separation, invocation-shape
note) — no assertion was dropped or weakened.

## Validation

- Each repaired suite ran green on the released working tree through the runner collection with the
  sharded invocation shape: repository-policy, canonical-transaction, skills-import, doctor,
  canonical-recovery, canonical-command-result, task-skills, harness-authority (batch of four ran
  together: 4/4), root-claims-registry, and canonical-hard-kill (3420 s, the last unverified
  shard-1 member).
- `check-powershell-syntax.ps1` passed for 179 files; pinned secret scan passed with no blocking
  findings; `git diff --check` passed.
- The full-repository collection and remote CI were not rerun locally; the next push is the
  sharded workflow's first run on the repaired tree.

## Boundaries

No production script, policy value, gate threshold, workflow file, or plan semantics changed —
this is test-pinning and documentation repair only. It grants no release or deployment
authorization: Task 8 Steps 2-5 (disposable-identity lab, candidate gates, reject-or-proceed,
STATUS closeout) remain the owner's. The candidate sits on `origin/main` per the owner's push
decision; the Task 8 Step 1 record's "local-only" note predates that push.
