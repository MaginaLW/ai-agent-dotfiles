# Project Status

Last updated: 2026-08-30

This is the repository's single global status file. Current task records belong in
[`status/active/`](status/active/); completed records belong in
[`status/archived/`](status/archived/).

## Purpose and current phase

This repository is the conservative, auditable source for Claude, Codex, and Reasonix skills
and selected project-local harness configuration. `skills-source/` is canonical; generated
runtime output is rebuilt, scanned for secrets, backed up, and deployed one skill directory at
a time. Whole-root mirroring is forbidden, unknown live skills are preserved by default, and
Codex `.system` is outside repository ownership.

Live-safety hardening is in progress. Baseline-reconciliation Task 1 is complete (5/5), the Phase 0
entry-interlock subplan is complete (43/43), and Phase 1 is complete (44/44). The corrected privacy
rewrite is published at `bbba28f`; GitHub Support ticket `#4697323` is resolved after server-side
garbage collection/cache clearing, and the 2026-08-27 old-SHA re-probe confirms the object is no
longer served. Phase 2 Task 1 Step 1 is complete (Task 1 1/6; Phase 2 overall 1/52), while Phases 3-4
have not started. Tracked policy remains
`ReleaseState=interlocked`: production sync/environment/task/rollback Apply, standalone backup,
and explicit retirement stop with `safety-protocol-upgrade-required` before traversal or mutation.
Bootstrap and Git hooks use an explicitly approved Git-private runner and may emit only validated,
non-consumable preview/events plus an explicit external DryRun command. They never Apply.

## Current skill inventory

| Scope | Canonical skills | Generated/live count |
|---|---:|---:|
| Shared | 7 | Claude 7, Codex 7, Reasonix 7 |
| Claude-only | 0 | 0 |
| Codex-only | 8 | Codex 8 |
| Reasonix-only | 0 | 0 |
| Unique union | 15 | Claude 7, Codex 15, Reasonix 7 |

Current canonical names:

- Shared: `brainstorming`, `git-review`, `paper-polish`, `subagent-driven-development`,
  `systematic-debugging`, `verification-before-completion`, `writing-plans`.
- Codex-only: `chatgpt-apps`, `cli-creator`, `coderabbit-review`, `define-goal`, `hatch-pet`,
  `security-best-practices`, `security-ownership-map`, `security-threat-model`.

Harness environment subsets are `minimal` 1/1/1, `work` 2/4/2, and `full` 7/15/7 for
Claude/Codex/Reasonix. All three definitions are valid; their commit-bound staging locks are stale
after the cleanup commit and must be rebuilt before future environment planning. Verified live state
remains the 2/4/2 `work` selection from the last pre-interlock activation.

## 2026-08-09 cleanup decisions

Eleven canonical skills were removed:

- Shared: `control-chrome`, `latex-tectonic`, `path-risk`, `placeholder-ok`, `writing-skills`.
- Claude-only: `codex-cli-runtime`, `codex-result-handling`, `gpt-5-4-prompting`.
- Codex-only: `codex-repo-maintainer`, `control-in-app-browser`, `google-drive-comments`.

Most were exact plugin duplicates, fake-home fixtures, incomplete local copies, or depended on
missing plugin runtime files. Removing `writing-skills` is an intentional capability reduction,
not a pure duplicate removal: its local copy depended on an unavailable Superpowers skill, while
Codex retains the platform `.system/skill-creator` path.

`code-review` became the narrower `coderabbit-review`. It now triggers only for an explicit
CodeRabbit request, never installs the CLI through `curl | sh`, requires installation approval,
and uses bounded waits compatible with normal progress updates. It remains in `full` and is not
part of `work`.

Additional repairs restored seven truncated skill descriptions, changed
`security-ownership-map` to resolve scripts from its actual skill root, and removed four
unreferenced academic/pressure-test documents from the deployed `systematic-debugging` tree.

## ArkCLI uninstall

ArkCLI 1.0.11's official `+connect uninstall` path was used; live directories were not hand
deleted. Seven detected agents resolved to five unique skill roots. The command removed 24
ArkCLI-managed skills from each of three populated roots (72 directory removals total); all five
roots then had no `ark-*`, `arkcli-*`, or `.arkcli-managed-skills.json` residue. Fifty-one
non-ArkCLI top-level entries were preserved. Codex `.system` and its marker were untouched.

## MCP and retired-platform scope

The repository MCP registration subsystem was retired. Its only template targeted the archived
`@modelcontextprotocol/server-github`, no profile actually consumed a template, and repository
status evidence showed no real MCP apply. The template, apply/helper scripts, MCP schemas/tests,
CLI route, profile/env coupling, and CI job were removed. This was scope pruning of an unused,
outdated capability; it was not a live MCP unregister, and no live Claude MCP configuration was
changed.

The env build evidence contract is now schema 2 and the env lock contract is schema 3. Obsolete
MCP count/hash fields were removed, while `TaskOverlayHash` and real Claude/Codex/Reasonix
`TaskOverlaySkills` evidence are schema-covered.

Remaining OpenClaw/OpenCode-only active specs, inventories, ignored manifests, and stale status
records were deleted or archived. Historical dated implementation plans remain historical. The
global `.gitignore` rules that hid all `package.json` and `package-lock.json` files were removed.

## Safe skill retirement

Deleting canonical source also removes its current managed-manifest entry. Previously, the old
live directory then became unknown and could not be safely pruned. `sync.ps1` now supports an
explicit external `-RetireManifestPath` for this one operation only.

The retirement path is fail-closed:

- strict JSON, safe lowercase names, exact per-platform targeting, and `.system` rejection;
- active generated/current-manifest/canonical names are rejected, including `reasonix-only`;
- both the supplied `RepoRoot` and the script's non-overridable repository root are canonical
  authorities, so env staging cannot bypass the check;
- the manifest path/bytes, canonical absence evidence, source/live roots, and target tree hashes
  are bound into sync-plan schema 2;
- saved plans self-validate before comparison, and Apply requires the unchanged reviewed plan;
- the exact Reasonix override root is included in backup;
- prune moves the target aside and re-hashes it before permanent deletion; missing, non-directory,
  or changed targets fail closed and changed directories are restored.

This mechanism does not maintain a replay-consumption ledger. Successful runs must delete their
external plan and retirement JSON after the backup journal has recorded the result.

## Historical machine evidence (redacted)

On the previously verified current machine, reviewed plan
`7883fbbc52bd4c259d455475d7e932a5097e59932d6d1d582eb7116bf61fd2a3` was applied on
2026-08-09. Backup basename: `sync-backup-20260809-160759` (parent path intentionally redacted).

Results:

- Claude: `+0 ~2 =5 -8`, final managed/live count 7.
- Codex: `+1 ~8 =6 -9`, final managed/live count 15; `coderabbit-review` added.
- Reasonix: `+0 ~2 =5 -5`, final managed/live count 7.
- All 22 explicit retirement targets are absent live, present in backup, and recorded once in the
  completed journal with `explicit-retirement` authority.
- Unknown live skills: 0 on all three platforms.
- Codex `.system`: root marker remained present; child count/content hashes are intentionally not
  tracked in repository status.
- The external retirement JSON and reviewed plan were destroyed after verification.
- A subsequent ordinary sync dry-run (without retirement authority) reported Claude
  `+0 ~0 =7 -0`, Codex `+0 ~0 =15 -0`, and Reasonix `+0 ~0 =7 -0`, with zero unknowns.

After the cleanup verification, the user selected the smaller stock `work` environment. Reviewed
plan `6962e66c35c9380b7da746af478d6164c3ba165a32950e52c09928e6c61dace3` was applied through
`env activate work` at 2026-08-09 16:29 local time. Backup basename:
`sync-backup-20260809-162935` (parent path intentionally redacted).

- Claude applied `+0 ~0 =2 -5`; final live set is `git-review` and `systematic-debugging`.
- Codex applied `+0 ~0 =4 -11`; final live set is `brainstorming`, `git-review`,
  `systematic-debugging`, and `writing-plans`.
- Reasonix applied `+0 ~0 =2 -5`; final live set is `git-review` and
  `systematic-debugging`.
- Task overlay additions remain empty for all three platforms. Environment lock and live parity
  pass, project `RequiredEnv=work` matches, unknown live skills are zero, and Codex `.system`
  remains present; no child content hash is recorded.

During pre-commit validation, adding a detached worktree for an exact staged-snapshot scan triggered
the repository's existing `post-checkout` hook and unexpectedly ran a full-manifest sync. The hook
created mandatory backup `sync-backup-20260809-164838`; no unknown skill or `.system` content was
lost. The machine was immediately restored through a hooks-disabled, fully scanned and reviewed
`env activate work` plan (`f08378a60b6efa7dfdcd06179124be4f21d0bc402078344c18c64ffac7c4019f`).
Recovery backup: `sync-backup-20260809-165216`. Immediately after recovery, main-repository status
again reported stock `work`, valid lock, live parity pass, zero task additions, zero unknowns, and
the `.system` root marker still present. The temporary worktree was removed. Creating the cleanup commit
then correctly made the commit-bound staging locks stale; live remains the exact 2/4/2 `work` set and
live parity still passes.

This evidence applied only to that machine snapshot. Other machines require their own reviewed dry-run;
auto-sync hooks never create or consume retirement authority.

## 2026-08-20 repository repair

The accidental `24f6bc8` work-in-progress commit tracked 156 Reasonix task-state files, twelve
root-level diagnostic scripts, and incomplete hard-kill host/engine changes. The machine-state and
diagnostic files were removed and are now ignored at their exact repository-root locations. The two
incomplete helper changes were restored to the preceding reviewed bytes; this repaired the reviewed
load hash boundary and reduced `canonical-hard-kill.tests.ps1` from 97 passed / 25 failed to
100 passed / 22 failed without weakening any assertion.

Two canonical transaction tests assumed that the repository and system TEMP directory shared a
volume. Their external recovery fixtures now use random working-tree-external siblings on the
repository volume, and the setup-only root is explicitly current-user-only. This preserves the
production cross-volume and broad-ACL rejection gates. `status/active/README.md` now keeps the
doctor-required active-status directory present in fresh clones.

## 2026-08-28 CI runner owner-authorization repair

The GitHub Actions `Validate` workflow had failed on every push since 2026-08-09 while local
unified runs of the same commits stayed green. The current-run log isolated four failing suites:
`canonical-command-result` (four routed setup cases), `canonical-recovery` (the public setup
DryRun published no plan), `root-claims-registry` (crash with
`registry owner/DACL is not current-user-only`), and `canonical-mutation-parent-lease`
(`external parent attack timed out: file-rollback`).

Root cause, confirmed at the code level and by direct reproduction of the check behavior:
GitHub-hosted Windows runners execute job processes under an elevated administrator token, so
objects the job creates without an explicit owner are owned by `BUILTIN\Administrators`
(`S-1-5-32-544`) rather than the access-token user SID. The current-user-only security checks
compared directory-owner evidence strictly against the access-token user SID, so every
test-created fixture ancestor and snapshot failed closed on CI. Non-elevated local development
shells create user-SID-owned objects and were unaffected. The same asymmetry applies to the
parent-lease external attack: the parent-side wait (30 s) was shorter than the external helper's
own 120 s deadline, so a missed lease window surfaced as a misleading timeout instead of a real
`Blocked=false` diagnostic.

Repair (resolver version `windows-token-sid-current-user-only-v2`):

- The owner expectation is now the set {access-token user SID, token default owner}. On
  non-elevated tokens the default owner equals the user SID, so non-elevated behavior is
  unchanged; on elevated tokens the default owner is the Administrators group, matching what
  that token factually creates. The DACL requirements (current-user-only, protected or the
  reviewed inherited single-ACE shape, broad-SID rejection) are unchanged and remain fail-closed.
- `canonical-transaction-common.ps1`, `home-authority-common.ps1`, and
  `root-claims-registry-common.ps1` gained token-default-owner helpers; the directory-security,
  ancestor, registry-snapshot, and canonical-root-context checks accept the owner set; stored
  artifact bindings still record the token user SID. The hard-kill suite seals its own bytes and
  the reviewed load, so the same repair re-pinned the reviewed-load manifest, the actual-prelude
  row list and digest, the 27-statement pre-section region digest, the transport-contract extent,
  the function-inventory digest, the cleanup-gate self digest, and the whole-file controller
  surface digest. The sealed mutation inventory itself (299 rejections / 81 controls / 2 actual
  prelude controls) is unchanged and revalidated green.
- The three schemas pinning `SecurityResolverVersion` moved their const to v2, and the
  `canonical-root-claim`, `canonical-setup-state`, and `canonical-transaction-plan` positive
  fixtures were regenerated (the plan's `PlanHash`/`DocumentHash` recomputed with the reviewed
  hash functions). The regeneration helper lived outside the repository and was not committed.
- The parent-lease controller now waits 125 s per external attack (above the helper's own 120 s
  deadline), the lease-acknowledgement handshake waits 60 s, and the suite budget moved from 180 s
  to 420 s. A missed lease window now surfaces as an explicit `Blocked=false` assertion failure
  rather than a timeout; the blocking assertions themselves are unchanged. The first CI run of
  this repair confirmed the elevated-owner diagnosis (hard-kill 317/0 on the runner, the registry
  whitelist accepting Administrators-owned evidence) and exposed two remaining runner-specific
  test-infrastructure issues, both fixed in this repair: the root-claims fixture root was
  shortened after the longer runner profile pushed its alternate-data-stream file past the
  MAX_PATH limit, and the parent-rename attack host now completes one full probe cycle before
  arming so a cold-start JIT delay cannot skip the whole short lease window.
- `canonical-recovery.tests.ps1` gained regression assertions pinning the v2 resolver string,
  acceptance of the token default owner, and continued rejection of a foreign owner.

Validation on 2026-08-28: the PowerShell syntax gate passed (156 files), registered artifact
validation passed 21 contracts / 21 positive / 66 negative with zero failures, and the affected
suites passed standalone (`canonical-recovery` 104/0, `canonical-command-result` 46/0,
`root-claims-registry` pass, `canonical-transaction` 45/0, `canonical-mutation-parent-lease`
12/0, `home-authority` pass, `live-concurrency` pass). The definitive unified
`run-tests.ps1 -All` run then discovered, started, completed, and passed all 34 suites exactly
once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures; the external
create-new JSON summary's SHA-256 is
`fef5a8e1d1ed5acd5a1bf74c8b7290b19a06aceb043f4ad5452f5735d5a396fa`, with `canonical-hard-kill`
reaching 317/0 inside the unified run. `build-skills.ps1` (7/15/7), `scan-secrets.ps1` (no
blocking findings; 805 non-blocking keyword hints), and `sync.ps1` DryRun (no live mutation)
passed. Production Apply remains interlocked and no live root was touched. See
`status/active/live-safety-hardening.md` for this repair's record.

CI confirmation: after the test-infrastructure follow-up, the `Validate` workflow for
`6540681` completed green with `Test summary: PASS; discovered=34; passed=34; failed=0;
timed-out=0` and hard-kill 317/0 on the runner, closing the failure streak that had run since
2026-08-09.

A follow-up audit confirmed no elevated-owner comparison points remain (the two C# test helpers
set their fixture owners explicitly, so they are elevation-independent), and re-hardened the
remaining Windows path-length margins that the audit identified: the longest root-claims fixture
names and the approved-runner fixture root prefixes were shortened (the deepest regular fixture
paths now keep >=30 characters of margin, and the one alternate-data-stream operation keeps >=30
under the longer runner profile), and one leftover indentation from the `.rcr-` rename was
corrected. The audit also recorded an environment dependency worth keeping in mind: regular
.NET file I/O in the suites relies on the GitHub Windows runner's long-path support (paths near
380 characters already exist under `canonical-hard-kill`), while PowerShell-provider named-stream
operations (`Set-Content -Stream`) remain bound by MAX_PATH -- new ADS probes must stay on short
paths. The hardening commit `43b2f85` then completed the `Validate` workflow green with
`Test summary: PASS; discovered=34; passed=34; failed=0; timed-out=0` and hard-kill 317/0,
after an independent Grok review of the diff returned PASS on stale-reference, hash-seal, and
documentation-consistency checks.

## 2026-08-29 Phase 2 Task 1 Step 1 failure-matrix completion

The remaining Step 1 identity/concurrency failure matrix was completed as test-only changes; no
production script changed, so no hard-kill re-pin was required. The additions close the previously
named Step 1 gaps:

- root-claims-registry: a tracked Git working tree and GitCommonDir inside a live target root fails
  closed as forbidden route overlap; second-repository claims nested inside and exactly duplicating
  an existing claim's recovery root fail closed as reserved-root overlap; a linked worktree shares
  the main repository's contract namespace and contends on the one canonical lock while a second
  clone derives its own identity, claim file, and concurrently holdable lock; two HomeRoots with
  ancestor/descendant live-root overlap fail closed; and the registry command surface is enumerated
  to prove no public `-HomeRoot`/`-BackupRoot`/`-LockWaitSeconds`/`-TestMode` selector exists.
- home-authority: an exhaustive ordered-pair state-semantics matrix rejects each platform final root
  nested inside another (all six pairs); live roots are created one at a time and the resolver
  classifies exactly the created platforms while requested paths and the authority namespace stay
  stable; and the same public-parameter enumeration covers the authority/lock/bootstrap/live-target
  commands.
- live-concurrency: a new sealed-host `canonical-global-hold` operation holds canonical plus global
  through a genuine canonical witness; a live-route-shaped acquisition and a second-repository
  canonical route each lose with exact zero-wait busy and zero writes, the holder's canonical lock
  stays busy, and after release the second repository acquires the same immutable global lock through
  its own witness. Canonical-setup versus live-adopt and canonical-versus-retirement races are
  covered at the implemented lock-class level; those routes are retrofitted in Step 5 and re-verified
  in Step 6. Fixed-NTFS versus UNC/mapped/removable/ReFS/FAT/unknown capability remains at the
  established unit-fixture and path-rejection level. The new canonical fixture introduced
  git-created read-only loose object files, so the suite cleanup now clears read-only attributes
  before its guarded recursive delete.

Validation on 2026-08-29: focused runs passed (home-authority 191 PASS, root-claims-registry 197
PASS, live-concurrency 222 PASS, each exit code 0); the parse gate passed 156 files; `git diff
--check` was clean; and the definitive unified `run-tests.ps1 -All` run discovered, started,
completed, and passed all 34 suites exactly once with zero failures, timeouts, duplicates, missing
suites, or tree-kill failures. The external create-new summary SHA-256 is
`0bbff288638a3ca5a509fa158a398b59d1bb4b45c10f63150452cfaa92fa15e2`, with `canonical-hard-kill` at
317/0 inside the run. `build-skills.ps1` (7/15/7), `scan-secrets.ps1` (no blocking findings; 805
non-blocking keyword hints), and `sync.ps1` DryRun (no live mutation) then passed. This completes
Task 1 Step 1 (Task 1 1/6, Phase 2 1/52). Production Apply remains interlocked, and no live root or
Git index/ref was changed.

## 2026-08-29 Phase 2 under-lock capability preflight

Phase 2 Task 1 gained the sealed under-lock filesystem-capability preflight as an additive building
block in the registry surface (`Invoke-SealedHeldCapabilityPreflight` plus CLR-sealed
`SealedCapabilityPreflightEvidence`/`SealedCapabilityPreflightRow` in
`scripts/root-claims-registry-common.ps1`). No pinned script changed, so no hard-kill re-pin was
required, and no production route consumes the preflight yet. The preflight requires the genuine
global-lock witness (optionally revalidating the canonical witness in canonical-to-global order),
validates an approved external probe root (existing non-reparse container; rejects overlap with
ControlBase/BackupRoot/private base or any capability target; fails closed on pre-existing
`.target-capability-*` residue without modifying it), binds each target's metadata VolumeId to the
live volume serial, and runs the real write-capability probe on the target's deepest-existing-parent
volume. Evidence rows carry path, location key, status, drive type, filesystem type, volume serial,
the real capability hash, and an optional expected-hash verification; a supplied expected hash must
reproduce the under-lock probe exactly or the preflight fails closed. The tests prove the plan-bound
recovery-root claim hash reproduces under the held locks, zero authority-area writes and zero residue
from the invocation's exact owned probe slots, lock and contract rejections, and ETS note-property
forgery resistance. The preflight never wildcard-cleans matching entries: foreign residue created
after the initial check is preserved and makes the post-probe check fail closed. This advances Step
2's capability binding for existing ControlBase/BackupRoot;
resolver-side wiring, the `PrivateRootBootstrapIntent` setup-Apply bootstrap flow, and public
dispatch rules remain open. Production Apply remains interlocked, and no live root or Git index/ref
was changed.

Validation on 2026-08-29: `root-claims-registry.tests.ps1` passed focused with 218 assertions and
exit code 0, including the deterministic foreign-residue regression; the parse gate passed 156
files; and the definitive unified `run-tests.ps1 -All` run
discovered, started, completed, and passed all 34 suites exactly once with zero failures, timeouts,
duplicates, missing suites, or tree-kill failures. The external create-new summary SHA-256 is
`51f51e8b0eba5421979b712cb586826bc392ce90251b97ea8e114e0c82a0e8c4`, with `canonical-hard-kill` at
317/0 inside the run. `build-skills.ps1` (7/15/7), `scan-secrets.ps1` (no blocking findings; 827
non-blocking keyword hints), and `sync.ps1` DryRun (no live mutation) then passed. Task 1 remains
1/6 and Phase 2 remains 1/52; the GitHub `Validate` workflow for the previous Step 1 commit
`38d64f7` completed green on the runner before this slice.

## 2026-08-29 Phase 2 per-target/per-volume capability hardening

The sealed under-lock capability preflight now accepts an exact target-to-ProbeRoot map instead of
one aggregate ProbeRoot. Every target row binds its own normalized ProbeRoot path, location key, and
probe-time captured directory identity in the CLR-sealed evidence. Before the first real probe, the
registry layer validates the complete map: exact input shape, target type and uniqueness, target-to-target,
target-to-ProbeRoot, ProbeRoot-to-ProbeRoot, and authority-root overlap, Fixed/NTFS support, exact
target/probe volume-serial equality, expected-hash syntax, and residue in every unique ProbeRoot.
Rows are ordered by target LocationKey, so input permutation does not change the projection. A
dynamic test uses two distinct writable Fixed/NTFS volumes when available; on the current validation
host that branch executed and proved three independent target probes, bidirectional wrong-volume
zero-probe rejection, per-row sealed evidence, zero authority/external-tree drift, and empty
ProbeRoots after success.

The lower probe now holds the complete ProbeRoot containment chain and verifies the caller-captured
ProbeRoot identity before creating anything. It rejects matching residue case-insensitively both
before the GUID slot is created and after exact cleanup, preserving foreign names and bytes. The
owned slot is create-new with DELETE access and no delete sharing; its creation-failure rollback and
successful deletion act on the exact held slot. Child-file create/write rollback uses the held file,
and later cleanup stays identity-bound under the held slot. Slot cleanup validates identity, type,
single-link state, alternate streams, and emptiness before marking that same held directory for
deletion. There is no wildcard, recursive, or path-delete cleanup fallback. Primary probe failures
and cleanup failures remain
separately available inside one stable combined error. Because `target-context-common.ps1` and
`safe-tree-walker.ps1` are pinned into the hard-kill trust closure, their final source hashes and the
dependent controller/prelude pins were recomputed from the reviewed bytes rather than weakening any
check.

This remains an additive sealed building block. No production Apply, rollback, registry consumer,
or live-mutation route calls it; resolver/fixed-envelope integration, the
`PrivateRootBootstrapIntent` setup-Apply flow, protocol-v1 public dispatch, and the remaining
forbidden-root matrix are still open. Task 1 remains 1/6 and Phase 2 remains 1/52. Production Apply
remains interlocked, and no live root was changed.

Validation completed on 2026-08-30. Focused runs passed `safe-tree-walker.tests.ps1`,
`path-safety.tests.ps1`, and `root-claims-registry.tests.ps1` (247 assertions), including all 19
real mixed-volume assertions; `canonical-production-seams.tests.ps1` passed 13/0, and the standalone
`canonical-hard-kill.tests.ps1` run passed 317/0. The PowerShell syntax gate parsed all 156 files,
and registered-artifact validation passed 21 contracts, 21 positive fixtures, and 66 negative
fixtures with zero failures. The definitive create-new external `run-tests.ps1 -All` summary passed
all 34 discovered suites exactly once, with zero failures, timeouts, duplicates, missing suites, or
tree-kill failures; its SHA-256 is
`7e4d1c855804a4db29d9ca4175fa1bb7c9113bfc1b238564cd3ce19ec6a0e0bf`, and its embedded
`canonical-hard-kill.tests.ps1` record is exit 0 with 317/0.
Final repository gates then passed: skill generation produced Claude/Codex/Reasonix counts 7/15/7;
the pinned gitleaks gate found no blocking findings and reported 828 reviewed non-blocking keyword
hints; and `sync.ps1 -DryRun` completed with plan hash
`b94ca90b872568bddeed048a959b37b40f0cd8f1d89c90936afa876a32783e2e`, explicitly preserving
Codex `.system` and changing no live files. `git diff --check` also passed.

## Validation status

The fresh 2026-08-22 unified run used `scripts/run-tests.ps1 -All` and an external create-new JSON
summary. Its summary SHA-256 is
`cc2bf3443dddb0fb218f11f16c42a226b79322e0c6437f6e9e9451f95ebfdad5`:

- 30 suites were discovered, started, and completed;
- 28 suites passed and 2 failed; there were zero timeouts, duplicates, missing suites, or tree-kill
  failures;
- `canonical-hard-kill.tests.ps1` reached 126 passed / 1 failed. The failure was
  `before-workspace`: the actual process matrix still routes through timing-dependent journal polling,
  so the controller can miss `WORKSPACE_CREATE_INTENT -> CreateDirectoryNoOverwrite` before
  `WORKSPACE_CREATED`;
- `canonical-mutation-parent-lease.tests.ps1` initially reached 10 passed / 2 failed. Production
  leases had blocked the first rename probe, but the test helper issued a second rename after lease
  release and overwrote that evidence. The helper now treats the first blocked probe as the attack;
  two focused reruns each reached 12 passed / 0 failed;
- the latest focused `canonical-hard-kill.tests.ps1 -Section primitives` run reached 95 passed / 0
  failed. This does not cover the default process matrix and is not evidence that the complete suite
  is green.

The unified runner does not include the separate PowerShell parse, canonical build, or filtered secret
scan gates. Their earlier 2026-08-20 evidence remains historical rather than being restated as a fresh
2026-08-22 result. No live sync, backup, retirement, rollback, or Apply was performed.

The 2026-08-23 Phase 1 workspace vertical slice now routes all four preimage/swap-old before/after
workspace cases through the sealed typed transport instead of legacy journal polling. The runtime has
canonical selector parsing, protected cross-process events, root-relative held stage evidence, a suspended
process assigned atomically to one retained Job, same-epoch typed reap receipts, controller-side journal and
post-state verification, and identity-bound cleanup. Observation is single-use and bound by exact object
identity; pre-session abort and receipt-following failures release all reachable native/event/stage resources
before preserving the primary error. Hard-kill and natural-release nominal cleanup both enforce the same
immutable absolute QPC deadline through root disposition, handle release, and a completion post-check, so
an over-deadline cleanup falls back without publishing proof. Natural release consumes the held final lease
before Continue, requires the selected `WORKSPACE_CREATED` on a validated successor chain, and accepts only
the case-bound recovery classification after the child exits with code zero. The controller route is the first
loop branch and exits that case after publishing a complete proof or natural-release differential; the legacy
launcher remains a single separate path.

The Phase 1 preimage slice now also removes timing-dependent polling from `before-preimage` and
`partial-preimage`. Both checkpoints use the same sealed selector/stage transport, with independent
controller reconstruction of the exact workspace record chain, held source identity/hash, and target
arm. The retained-partial fixture converts its durable writer into a read-only sealed handle so the
controller can acquire a second read witness while writes and deletion remain blocked; the controller
requires the exact `source.Length - 1` prefix, the durable preimage workspace identity, and reconstructed
`PREIMAGE_COPY_INTENT` data. Post-state classification is independently recomputed from the reread
journal, including the canonical `manual/""/""` wire form. The legacy `after-preimage` R/W oplock ladder
remains in place, but its typed start stage is now published before real preimage initialization so its
source/header/source-copy/intent gates observe the intended intent-to-prepared boundary.

The Phase 1 parent-directory slice now removes timing-dependent polling from `before-parent` and
`after-parent`. Both checkpoints use the sealed selector/stage transport around the real
`CreateDirectoryNoOverwrite` primitive, with the controller independently binding the exact parent
target arm, sequence-7 `DIR_CREATE_INTENT`, missing branch discriminator, candidate empty-directory
state, and created identity. Natural release requires the unique sequence-8 `DIR_CREATED` successor.
The `before-parent` differential explicitly distinguishes hard-kill `abandon/abandoned` from the
completed natural path's `rollback/rolled-back`; `after-parent` remains rollback-classified in both
modes.

The Phase 1 directory-old slice now removes timing-dependent polling from `before-directory-old`
and `after-directory-old`. Both checkpoints use the sealed typed transport around the real
directory old-to-swap move. The controller independently binds the unique order-zero
directory/canonical target, sequence-7 `MOVE_OLD_INTENT`, matching unique `PREPARED` data, and the
`PRESENT` branch discriminator. Before the primitive it requires target/preimage=current,
swap-old=missing, and staged=candidate; after the primitive it requires target=missing,
preimage/swap-old=current, and staged=candidate, including the moved directory identity. Natural
release accepts only the exact hash-linked sequence-8 `OLD_MOVED`, sequence-9 `MOVE_NEW_INTENT`, and
sequence-10 `NEW_INSTALLED` successors plus the final target=candidate, preimage/swap-old=current,
staged=missing tuple. `before-directory-old` distinguishes hard-kill `abandon/abandoned` from the
completed natural path's `rollback/rolled-back`; `after-directory-old` remains rollback-classified
in both modes.

The Phase 1 directory-new slice now removes timing-dependent polling from `before-directory-new`
and `after-directory-new`. Both checkpoints use the sealed typed transport around the real staged-to-target
directory move, while the host selector is explicitly bound to `Kind=directory` so the colliding
`directory-add-new` checkpoint names remain on their legacy zero-argument path and reject sealed arguments.
The controller binds the unique order-zero directory/canonical target and sequence-9
`MOVE_NEW_INTENT` to the hash-linked sequence-8 `OLD_MOVED` record. Before the primitive it requires
target=missing, preimage/swap-old=current, and staged=candidate; after the primitive it requires
target=candidate, preimage/swap-old=current, and staged=missing, including exact moved identity and
record-data reconstruction. Natural release accepts only the unique hash-linked sequence-10
`NEW_INSTALLED` successor and the same final tuple. Both checkpoints remain
`rollback/rolled-back` in hard-kill and natural-release modes.

The Phase 1 directory-add-new slice now removes timing-dependent polling from
`before-directory-add-new` and `after-directory-add-new`. It reuses the reviewed staged-to-target
directory primitive with `Current=MISSING`, while the host's exact two-arm selector permits
directory replacement old/new checkpoints and directory-add new checkpoints without exposing
directory-add old or directory-delete routes. Because replacement and add share the same TargetId and
typed checkpoint, the controller independently binds case Kind to the header contract:
`directory` requires `Current=PRESENT`, and `directory-add` requires `Current=MISSING`. Before the
primitive, target/preimage/swap-old are missing and staged is the candidate; after it, target is the
candidate and preimage/swap-old/staged are missing. Natural release accepts only the unique
hash-linked sequence-10 `NEW_INSTALLED` successor. `before-directory-add-new` distinguishes hard-kill
`abandon/abandoned` from natural `rollback/rolled-back`; `after-directory-add-new` is
`rollback/rolled-back` in both modes.

The Phase 1 directory-delete installed-record slice now removes timing-dependent polling from
`directory-delete-before-installed-record` and `directory-delete-after-installed-record`. Both
cases use the sealed typed transport around the exact sequence-10 `NEW_INSTALLED` append with
`Current=PRESENT` and `Candidate=MISSING`. The controller binds the exact `Kind=directory-delete`
host selector, raw before/after checkpoint, typed `BeforeDirectoryDeletionRecord` /
`AfterDirectoryDeletionRecord`, unique order-zero directory/canonical arm, sequence-8 `OLD_MOVED`,
and hash-linked sequence-9 `MOVE_NEW_INTENT`. Both observations require target/staged=missing and
preimage/swap-old=current with exact identities and reconstructed record data. Natural release
accepts one exact sequence-10 successor before publication and zero delta after publication;
hard-kill and natural release both remain `rollback/rolled-back`.

The Phase 1 file/file-add slice now removes timing-dependent polling from
`before-file-replace`, `after-file-replace`, `before-file-add-move`, and
`after-file-add-move`. All four cases use the sealed typed transport around the real file
replace/move primitive. The controller binds `file`/`file-add`, the exact raw/typed checkpoint,
the `PRESENT`/`MISSING` branch discriminator, sequence-6 `FILE_PREPARED`, sequence-7
`FILE_REPLACE_INTENT`, held file identities, and the independently reconstructed before/after
tuple. Natural release accepts only the hash-linked sequence-8 `FILE_REPLACED` successor and
the candidate final tuple. The two before cases distinguish hard-kill `abandon/abandoned` from
natural `rollback/rolled-back`; both after cases remain `rollback/rolled-back` in both modes.

The four file rollback cases now obtain their unfinished recovery seed through the same typed
controller instead of the legacy initial launcher. This seed path is deliberately hard-kill-only:
it validates the case and definition identity, typed live reap receipt, transaction namespace,
post-state bytes and journal head, empty pending inventory, and the independently recomputed
`recovery/rollback/rolled-back` classification before falling through to the existing rollback
checkpoint host. Natural release is excluded from recovery seeding, while non-file rollback cases
retain their legacy initial path. The controller static boundary now rejects the exact 299
mutations, including seven recovery-seed partition/proof/fallthrough mutations, while accepting
81 synthetic and two actual-prelude controls.

The prelaunch wire is now also bound to held path provenance instead of trusting the case dictionary
alone. The exact twelve-token base host arguments bind `ToolchainRoot`, `FixtureRoot`,
`TransactionId`, `Kind`, `Checkpoint`, and `MarkerPath`; the controller derives the common repository
root from the exact reviewed host and engine locations, derives the fixture root from the scope-owned
invocation fixture, and requires the marker to be its canonical `checkpoint.marker` child. The
provenance validator treats every host script parameter as a protected root input and rejects direct,
foreach/unary, `[ref]`, and `SessionState.PSVariable` rebinding. It also pins the four local setup/stage
helpers, forbids relied-on external or cmdlet shadows, and scans root Function/Alias provider writes.
Actual-host and synthetic baselines validate, and the exact 63-mutant inventory rejects the protected
input, callee-authority, selector, frozen after-preimage stage, loader, owner, and partial-to-production
mutations.

Fresh focused validation on 2026-08-23 produced:

- `canonical-hard-kill.tests.ps1 -Section primitives`: 95 passed / 0 failed, including the exact
  292-rejection / 81-acceptance transport matrix, valid actual-host and synthetic provenance
  baselines, all 62 protected-input/callee-authority provenance mutations, the twenty-case behavior
  probe, held-invalid source validation, Job/oplock primitives, recursive parity, differential
  evidence, and failure cleanup;
- `canonical-hard-kill.tests.ps1 -Section process -CasePattern '*workspace'`: two independent focused
  executions each reached 10 passed / 0 failed, with all four selected workspace cases completing both
  hard-kill and natural-release through the typed controller (eight real child-process executions). A separate
  focused diagnostic execution also completed all four natural-release selectors with exact
  `natural-release-differential` results and empty stderr;
- `canonical-hard-kill.tests.ps1 -Section process -CasePattern '*preimage*'`: the final aggregate run
  reached 16 passed / 0 failed. `before-preimage` and `partial-preimage` each completed hard-kill and
  natural-release through the sealed controller, and `after-preimage` completed its exact four-gate oplock,
  Job reap, unfinished-journal, consumed-attempt, and unique-recovery assertions;
- `canonical-hard-kill.tests.ps1 -Section process -CasePattern before-parent` and the corresponding
  `after-parent` focused run each reached 10 passed / 0 failed. Both cases completed hard-kill and
  natural-release through the sealed controller, with sequence-7 intent observation and the exact
  sequence-8 natural successor;
- `canonical-hard-kill.tests.ps1 -Section process -CasePattern '*directory-old*'`: 10 passed / 0
  failed. `before-directory-old` and `after-directory-old` each completed hard-kill and
  natural-release through the sealed controller, with the exact sequence-7 intent boundary,
  independently reconstructed before/after move tuples, and sequence-8 through sequence-10 natural
  successor chain;
- `canonical-hard-kill.tests.ps1 -Section process -CasePattern '*directory-new*'`: 10 passed / 0
  failed. `before-directory-new` and `after-directory-new` each completed hard-kill and
  natural-release through the sealed controller, with the exact sequence-9 intent boundary,
  independently reconstructed pre/post staged-to-target tuples, and the unique sequence-10 natural
  successor;
- `canonical-hard-kill.tests.ps1 -Section process -CasePattern '*directory-add-new*'`: 10 passed / 0
  failed. `before-directory-add-new` and `after-directory-add-new` each completed hard-kill and
  natural-release through the sealed controller with `Current=MISSING`, exact Kind/header binding,
  independently reconstructed add-before/add-after tuples, and the unique sequence-10 natural
  successor;
- `canonical-hard-kill.tests.ps1 -Section process -CasePattern '*directory-delete*'`: 10 passed / 0
  failed. Both installed-record cases completed hard-kill and natural-release through the sealed
  controller with exact host-wire and raw/typed checkpoint binding, the sequence-8/9 durable prefix,
  the sequence-10 before/after differential, and the final missing-target tuple;
- `canonical-hard-kill.tests.ps1 -Section process -CasePattern '*directory*new*'`: 10 passed / 0
  failed. The four replacement-new and directory-add-new cases completed eight real child-process
  executions, confirming that the new directory-delete selector does not capture either colliding
  staged-to-target route;
- `canonical-production-seams.tests.ps1`: 13 passed / 0 failed across every `scripts/**/*.ps1` file and
  the reviewed production closure;
- `build-skills.ps1`: Claude 7, Codex 15, Reasonix 7; `scan-secrets.ps1`: no blocking findings (745
  non-blocking keyword hints); and `sync.ps1`: dry-run only, plan
  `b94ca90b872568bddeed048a959b37b40f0cd8f1d89c90936afa876a32783e2e`, with no live mutation and
  Codex `.system` preserved.

Fresh closure validation on 2026-08-24 produced:

- `canonical-hard-kill.tests.ps1 -Section rollback -CasePattern 'rollback-file*'`: 54 passed / 0
  failed across all four typed file/file-add recovery seeds;
- `canonical-hard-kill.tests.ps1 -Section process`: 60 passed / 0 failed across all 28 logical
  process cases; the four file/file-add cases each completed hard-kill and natural-release through
  the typed controller;
- `canonical-hard-kill.tests.ps1 -Section rollback`: 151 passed / 0 failed across all 12 logical
  rollback cases; the four file/file-add cases used typed hard-kill-only recovery seeds before the
  existing recovery checkpoint path;
- both complete matrices revalidated the exact 299-rejection / 81-acceptance controller boundary,
  the two actual-prelude controls, and the 63-mutant host provenance inventory;
- both changed PowerShell files passed parser validation and `git diff --check`; `build-skills.ps1`
  rebuilt Claude 7, Codex 15, and Reasonix 7; `scan-secrets.ps1` found no blocking secrets (746
  non-blocking keyword hints); and `sync.ps1` completed dry-run plan
  `b94ca90b872568bddeed048a959b37b40f0cd8f1d89c90936afa876a32783e2e` with no live changes and
  Codex `.system` preserved.

Fresh Phase 1 checkpoint validation on 2026-08-25 used `scripts/run-tests.ps1 -All` and an external
create-new JSON summary. The summary's raw SHA-256 is
`744f20d5f2155e0c0d6560c49c8f78e0fd86d95364b3048d4e3668f73214f82b`, and its discovery SHA-256 is
`12e438c9bf7c5d2222447d79c39e1afeb8781062d15a97fe851f454aaeaacc05`:

- all 31 suites were discovered, started, completed, and passed exactly once;
- failures, timeouts, duplicates, missing suites, and tree-kill failures were all zero;
- `canonical-hard-kill.tests.ps1` reached 317 passed / 0 failed inside the unified run;
- the summary passed its registered schema and semantic consistency validation.

The separate registered artifact validator passed 19 contracts, 19 positive fixtures, and 28
negative fixtures with zero failures; its external summary SHA-256 is
`1304e114343120903fcaceec57ea80fa8ead77bd252ad6a609625bd2ce7216d2`. PowerShell parsing,
canonical build, filtered secret scan, doctor, exact protected-path privacy coverage, staged and
unstaged diff checks, and sync DryRun also passed. The managed inventory remains 7/15/7.

This closes the complete hard-kill process/rollback matrix and Phase 1's 44/44 checkpoint.
Production Apply remains interlocked; no live mutation or Git staging/commit/publication occurred.

The 2026-08-26 Phase 2 Task 1 intermediate checkpoint completed one runtime read-only
authority/schema slice: access-token SID plus Known Folder authority resolution, no-follow metadata
TargetContext capture, root-claims v1, current-env-state v3, exact-byte claims/state binding, and
failure-layer coverage. Registered artifact validation passed 21 positive and 66 negative fixtures
with zero failures. Independent no-follow/token, schema-to-pair, and fixture-layer reviews found and
then revalidated the closed race, identity-format, schema-boundary, and Windows-name issues. This
does not complete any whole Task 1 step: Task 1 remains 0/6 and Phase 2 remains 0/52. No production
live root or Git index/ref was changed.

The current pre-lock `MetadataOnly` TargetContext is discovery/planning evidence only. The sealed
read-only registry now recaptures a supplied current route only under the genuine caller-held lock
pair; any future production plan or Apply consumer must likewise hold every required route lock,
including the global live lock, then recapture and compare the complete no-follow TargetContext before
backup/workspace creation. Path, ancestor, reparse, volume, directory-identity, or capability drift
must fail closed.

A second 2026-08-26 intermediate checkpoint completed the sealed fake-ControlBase bootstrap and
existing-only global-lock slice. The pre-ControlBase bootstrap lock is created under the already-held
Known Folder parent; the six deterministic directories and final global lock are created in one exact
prefix with their final current-user security descriptors, and the global lock is created last and
retained through bootstrap handoff. Snapshot validation rejects wrong type/ACL/identity, extra or
non-prefix children, reparse points, hard links, named streams, callback/opaque ACEs, and security
drift. The complete `live-concurrency` suite passes two real Git-repository contenders, strict
zero-wait loss with whole-fake-home zero-write evidence, a sealed test-only bounded wait, owner-death
handle release, and hard kill before/after all seven creation boundaries with exact-prefix resume and
identity preservation. Three independent security/concurrency/scope reviews passed after their
findings were fixed. This remains sealed test-adapter work: caller-supplied capability evidence is not
a production capability preflight, no production route consumes the bootstrap/global-lock API, and no
whole Task 1 step is complete. Task 1 remains 0/6 and Phase 2 remains 0/52.

A third 2026-08-26 intermediate checkpoint implemented the held-global-lock, read-only unified
registry core. Pristine bootstrap validation is now separate from the fixed post-bootstrap envelope;
under a real typed global-lock witness, strict in-memory zero-write validators read immutable
canonical and home claims, classify associated state as `VALID`, `MISSING`, or `INVALID`, retain
represented roots for conflict detection, and inventory normalized UUID live-transaction directories
as unresolved markers. Tests cover typed-lock rejection, fake-root zero-write behavior, represented-root
overlap, and hostile topology/type/reparse/hard-link/ADS/security cases. This remains an intermediate
registry slice: canonical-root-claim v1 has no GitCommonDir locator, so the current canonical namespace
and setup state still require a caller-held typed witness; before Task 4, a nonempty live-transaction
namespace fails closed as recovery-required without inventing a journal schema. The complete forbidden
matrix, held-route TargetContext recapture, and production integration remain unfinished. No whole Task
1 step is complete: Task 1 remains 0/6 and Phase 2 remains 0/52. Production Apply remains interlocked,
and no live root or Git index/ref was changed.

Fresh closure validation for this third intermediate checkpoint used `scripts/run-tests.ps1 -All`
with an external create-new JSON summary. Its raw SHA-256 is
`e08248fd63e895a2245db0fa416c778111009a5a34c99c7b662999d5c7da3b24`, and its discovery SHA-256 is
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`: all 34 suites were
discovered, started, completed, and passed exactly once; failures, timeouts, duplicates, missing
suites, and tree-kill failures were zero. `canonical-hard-kill.tests.ps1` reached 317 passed / 0
failed, and `root-claims-registry.tests.ps1` reached 69 passed / 0 failed. `build-skills.ps1`,
`scan-secrets.ps1`, and `sync.ps1` DryRun then passed; no production Apply, live-root mutation, or Git
index/ref mutation occurred.

A fourth 2026-08-27 intermediate checkpoint completed the sealed caller-held canonical-witness and
current-route registry slice. The canonical witness now retains the exact canonical setup bytes and
transaction-namespace evidence captured under its own lock; global-lock acquisition binds that exact
CLR-held owner and capture in canonical-to-global order, and a dependent-lock chain can close only
tail-to-head. The canonical-bound current-route path accepts only the genuine acquisition pair,
revalidates immutable held metadata, and can capture a read-only current-route root set under those
locks. Its returned coverage is exactly `HELD_METADATA_VERIFIED`; filesystem capability remains
`UNPROBED_READ_ONLY`. Tests now
fail closed on stateful getters, ABA substitution, ETS shadowing, genuine foreign owners, mutable
display replacement, identity/path/hash drift, and wrong lock order. Target, live-set, and registry
receipts use private `OPEN`/`CLOSING`/`CLOSED` state with exact retryable close and best-effort cleanup,
including injected cleanup failure. The implemented current-route overlap checks cover the current
repository, Git-private/setup, fixed control/backup/recovery, live targets/reservations, and applicable
workspace/materialization/source/staging roles, without claiming the complete Task 1 matrix.

This fourth slice remains read-only and disconnected from production routes. Task 4 still owns the
live-journal structure and interpretation, so any nonempty live-transaction namespace remains
recovery-required. Remaining Task 1 work includes the rest of the identity/concurrency failure matrix,
production route lock integration, a real under-lock filesystem-capability preflight, and the complete
forbidden-root matrix where applicable. No whole step is complete: Task 1 remains 0/6 and Phase 2
remains 0/52. Production Apply remains interlocked; no live root or Git index/ref was changed.

Fresh validation for this fourth checkpoint used `scripts/run-tests.ps1 -All` with a path proven
absent before the runner's create-new write. The external summary raw SHA-256 is
`b8bc1c887ea1d8aaf9cffbc2ef63ded74779ea430920a117a377b695d21710ec`; its independently recomputed
discovery SHA-256 is `1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`.
All 34 suites were discovered, started, completed, and passed exactly once; failures, timeouts,
duplicates, missing suites, and tree-kill failures were zero. `canonical-hard-kill.tests.ps1`
reached 317 passed / 0 failed, and `root-claims-registry.tests.ps1` emitted 159 PASS assertions with
exit code 0. `build-skills.ps1`, `scan-secrets.ps1`, and `sync.ps1` DryRun then passed; the build
inventory remained 7/15/7, and the hard-kill suite added no temporary-directory residue.

## Current boundaries and known state

- Historical machine-private `state/current-env.json` evidence attested stock `work`; it is not a
  repository-portable current-machine claim. The 2026-08-24 sync dry-run on this machine reports all
  7/15/7 generated skills as additions, with zero update/prune/unknown targets and Codex `.system`
  present. No live files were changed.
- Project Harness Profiles remain project-local. They do not write global homes, install
  project-local skills, or switch global environments automatically.
- Codex `config.toml`, credentials, sessions, caches, and unrelated home configuration are outside
  this repository's sync scope.
- The MCP subsystem removal did not alter any live MCP registration.
- User-owned `.reasonix/desktop-topic-*.json` files and the live-safety planning stream remain
  outside this repair. The fresh 2026-08-25 filtered working-tree scan passed without blocking findings
  (750 non-blocking keyword hints).
- Corrected rewritten state through `bbba28f` and the Phase 2 checkpoint through `91e871e` are
  published. Branch/tag history and fresh clones contain no protected-path records or targeted STATUS
  exposure.
  GitHub Support ticket `#4697323` is resolved after server-side garbage collection and cache clearing.
  The 2026-08-27 independent re-probe of old SHA
  `58b4bc329e3acca6ed38dfe6e0319dcf0f56e173` returned 404 for commit/tree/raw endpoints, 422 from the
  commits REST endpoint, and `upload-pack: not our ref` from a no-write direct-fetch dry run; local
  HEAD and refs remained unchanged. The external privacy follow-up is closed.

## Next actions

1. Continue Phase 2 Task 1 with production-route integration of the canonical-to-global lock order
   and current-route witness, resolver/fixed-envelope consumption of the sealed per-target capability
   evidence, the `PrivateRootBootstrapIntent` setup path and protocol-v1 public dispatch, and the
   remaining forbidden-root cases.
   Apply the complete forbidden-root matrix before accepting any default/custom claim. Keep
   production Apply disconnected and leave live-journal structure and interpretation to Task 4.
2. Coordinate any other clones/forks to re-clone or rebase rather than merge the old history.
3. Keep production Apply interlocked. After a reviewed policy release, revalidate each managed
   machine independently. For retired skills still present elsewhere,
   use a new machine-local retirement JSON and reviewed bound plan; do not reuse this machine's
   deleted authorization files.
