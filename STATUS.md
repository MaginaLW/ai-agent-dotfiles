# Project Status

Last updated: 2026-09-15

This is the repository's single global status file. Current task records belong in
[`status/active/`](status/active/); completed records belong in
[`status/archived/`](status/archived/).

## Purpose and current phase

This repository is the conservative, auditable source for Claude, Codex, and Reasonix skills
and selected project-local harness configuration. `skills-source/` is canonical; generated
runtime output is rebuilt, scanned for secrets, backed up, and deployed one skill directory at
a time. Whole-root mirroring is forbidden, unknown live skills are preserved by default, and
Codex `.system` is outside repository ownership.

Live-safety hardening: **Phase 2 is complete (Tasks 1-9)**, closing on 2026-09-13 with the Task 9
checkpoint's definitive unified pass (38/38 suites, zero failures/timeouts; see the Phase 2
closeout section below). Baseline-reconciliation Task 1 (5/5), the Phase 0 entry-interlock subplan
(43/43), and Phase 1 (44/44) are complete; the corrected privacy rewrite is published at `bbba28f`
with GitHub Support ticket `#4697323` resolved and the old object re-probe confirmed clean.
**Phase 3 (shared environment authority and task-overlay) is complete (47/47): Tasks 1-9 are all
closed** — Task 1 (lock 3 freeze, env-build 3 consumption, shared-state semantics, and separate
legacy/shared readers) at 7/7 steps, Task 2 (authority-aware read-only status with list/status v2)
at 5/5, Task 3 (the `env authority` command surface) at 4/4, Task 4 (reviewed migration, adoption
and corrupt-state repair through the Phase 2 host, with the four failure injection windows) at 5/5,
Task 5 (controller identity, valid-parity requirements and the state-only controller takeover) at
4/4, Task 6 (external-plan environment activation with the exact receipt and plan consumption) at
8/8, Task 7 (three-platform, plan-bound task overlays with the tracked-overlay file journal and the
worktree overlay lock) at 5/5, Task 8 (selection-aware preview routing for the pinned runner,
`2ca0488`) at 4/4, and Task 9 (the Phase 3 checkpoint, `e57c608`, with its review follow-ups
`872ad03` and `976d0fe`) at 5/5** — see the Phase 3
Task 1-9 sections below. Phase 4 (schema/CI contract and
safe release) has not started. One design-bound finding from the Phase 2 closeout
feeds the later Phase 4 design: the cross-authority root-claim overlap rejection (a machine-wide
claim store). The second, the rollback execution's production caller, is closed: `976d0fe` wired
it to the Phase 3 worktree overlay lock.
Tracked policy remains
`ReleaseState=interlocked`: production sync/environment/task/rollback Apply, standalone backup,
and explicit retirement stop with `safety-protocol-upgrade-required` before traversal or mutation.
Bootstrap and Git hooks use an explicitly approved Git-private runner and may emit only validated,
non-consumable preview/events plus an explicit external DryRun command. They never Apply.

## 2026-09-09 ZCode lightweight adoption

The owner selected this repository for continued work primarily in ZCode. The project `AGENTS.md`
now includes the lightweight collaboration rules adapted from harness-model; `docs/ZCODE.md`
provides the new-task handoff, existing verification entrypoints, and evidence-based closeout.
This is a project-instruction integration, not a new ZCode skills deployment target or a full
AI Flow installation. Global settings, model selections, skills, scripts, CI, and production
`ReleaseState=interlocked` are unchanged. Existing live-safety roadmap records are preserved;
the new handoff does not itself select or start the next implementation task.

Runtime loading and a real ZCode coding task remain to be observed in a new ZCode task. No ZCode
model invocation, background collection, or efficiency/defect-rate acceptance is part of this preparation.
Future task closeout should reuse existing evidence and keep unavailable measurements `unknown`.

Local preparation checks passed: the existing doctor regression, pinned secret scan, 18 local
Markdown link targets, and whitespace checks. Independent review found no blocking issue.
This documentation-only change did not run the full regression collection or remote CI.

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

## 2026-08-30 Phase 2 fixed-infrastructure same-lock capability capture

Phase 2 Task 1 now has an internal same-lock composition layer for already-complete fixed private
infrastructure. `Invoke-SealedHeldFixedInfrastructureCapabilityCapture` accepts exactly one
`ControlBase` and one `BackupRoot` role binding, each selecting only an approved external ProbeRoot
and optional expected capability hash; the target paths always come from the sealed
`AuthorityContext`. Under the genuine caller-held global lock, and an optional canonical witness
already bound in canonical-to-global order, it opens one outer fixed-envelope lease, runs both real
filesystem probes, and revalidates the exact global-lock evidence, canonical binding, fixed-envelope
projection, directory identity, security, volume, filesystem, and role mapping before returning.
The CLR-sealed result is ordered `ControlBase`, then `BackupRoot`, reports coverage exactly
`FIXED_INFRASTRUCTURE_PROBED`, and binds the authority-context, fixed-envelope, lock-security, role,
target, ProbeRoot, volume, capability, expected-hash, and reproducible projection evidence.

The capture does not trust caller-supplied preflight evidence or a dynamically shadowed raw/probe
function. A process-sealed exact issuer retains the first reviewed raw-preflight and lower-probe
ScriptBlocks behind a private issuer token; repeated loading must match their exact AST text, while
execution continues through the sealed first definitions. An extracted side-effect-free evidence
validator is called only by the fixed capture and independently rejects forged type names,
unreproducible projections, header/path/identity/volume/filesystem drift, and invalid expected-hash
semantics. Exact-issuer exception handling removes only PowerShell invocation wrappers, preserving
the first domain exception, aggregate boundary, combined primary/cleanup message, type, and Data.
If outer fixed-envelope close fails with a primary error, the primary remains authoritative and the
cleanup message is retained in `SealedFixedInfrastructureCapabilityCleanupError`; cleanup-only
failure remains visible directly.

At this checkpoint, the recursive production-seam test proved that the fixed capture had zero
production callers and that the validator plus exact raw/probe issuer calls had only their reviewed
internal owners. It
freezes all `scripts/**/*.ps1` dynamic-command and member/property/reflection dispatch surfaces with
reviewed count/digests, retains zero `using` and PowerShell type-definition baselines, and rejects
direct, dynamic, public-factory, explicit-type reflection, split-string AppDomain reflection,
mixed-case reflection, short-type/property-only member discovery, `ForEach-Object -MemberName`, and
new `Add-Type`/PowerShell class mutations. This broad digest is deliberately a change-review guard,
not a runtime non-interference proof; any production dispatch-surface change requires explicit
review and re-pinning.

This paragraph records the 2026-08-30 tree. The 2026-08-31 checkpoint below supersedes its current-tree
zero-caller and process-static-issuer statements with a runtime-only observation and per-runspace
issuer; the historical no-Apply boundary remains unchanged.

This is an additive Step 2 checkpoint only. No production Apply, rollback, registry/current-route
consumer, resolver adapter, bootstrap setup, public dispatcher, receipt, journal, or live-mutation
route calls the capture. Process-static first-ScriptBlock/runspace lifetime and the returned probe
evidence's temporal scope remain production-integration blockers to test before any consumer is
connected. The `PrivateRootBootstrapIntent` path, protocol-v1 public selector rejection, and the
remaining forbidden-root matrix are still open. Task 1 remains 1/6 and Phase 2 remains 1/52;
production Apply remains interlocked, and no live root or Git index/ref was changed.

Focused validation passed `root-claims-registry.tests.ps1`, the 29/0 recursive production-seam
suite, parser checks for all three modified feature PowerShell files, and `git diff --check`.

Fresh closure validation exposed two bounded test-infrastructure defects without reaching a
production route. The first create-new unified summary (raw SHA-256
`bea7544faf1700639c23e387390f7cc97d8fd3c63d36dfceff7c63bceefa3ef7`) completed all 34 suites and
passed 33: only `canonical-hard-kill.tests.ps1` failed after the legacy Job cleanup exceeded its
borrowed five-second caller budget and a retrying cleanup path covered the primary failure. The
tests-only helper now binds one reviewed 30-second absolute QPC deadline, attempts `TerminateJobObject` at most
once, preserves its first native failure across PowerShell reflection wrappers, and reports setup
cleanup primary-first. Its dedicated semantics suite reached 27/0, the focused after-state matrix
reached 10/0, and the complete hard-kill suite reached 317/0.

The next create-new unified summary (raw SHA-256
`9d58ce17fb46f4edb6ca97c52c2a23d632a2e262a4e047aba04bfc16c3bddf87`) completed and passed 33
suites with zero assertion failures, but the expanded `root-claims-registry.tests.ps1` was cleanly
tree-reaped at its old 300-second suite boundary. The same suite had passed at 284196 ms and 298324
ms, while the definitive run required 306091 ms, so this was a measured budget defect rather than a
hang. For that checkpoint, its bounded suite budget was raised to 600 seconds. The dedicated
reap-semantics suite was bounded at
60 seconds so its reviewed 30-second cleanup deadline and preceding exact-process-identity wait
could not be preempted by the runner. The Windows validation workflow at that checkpoint was 276
minutes: the computed repository requirement was 16335 seconds versus a 16560-second job limit,
retaining a 225-second outer difference. The existing runner contract recomputes and tests that
bound. These values are historical and are superseded by the 2026-09-01 correction below. The
34/34 unified summary below predates only this final budget-only adjustment; afterward the dedicated
reap-semantics suite passed 27/0 and the runner contract passed with the 60-second/276-minute delta.

The definitive external create-new unified summary passed all 34 suites exactly once with zero
failures, timeouts, duplicates, missing suites, or tree-kill failures. Its raw SHA-256 is
`fdf669636415e10f7f9e76b9f404ced705e02eb9225b6a89f1060205d4462784`, and its discovery SHA-256 is
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`.
`canonical-hard-kill.tests.ps1` reached 317/0, the reap-semantics suite reached 27/0, the recursive
production-seam suite reached 29/0, and the root-claims suite completed under its new bound.

Final repository gates passed: the PowerShell parser accepted all 156 files; artifact validation
accepted 21 contracts, 21 positive fixtures, and 66 negative fixtures with zero failures (summary
SHA-256 `5d771d2d0a5139732e19204c26f1ad7af1b4f49f21f8c1cdb97be184dd96a432`); skill generation remained
7/15/7; pinned gitleaks found no blocking secret and reported 835 non-blocking keyword hints; and
`git diff --check` passed. `sync.ps1 -DryRun` reproduced plan hash
`b94ca90b872568bddeed048a959b37b40f0cd8f1d89c90936afa876a32783e2e`, preserved Codex `.system`,
and changed no live file. No production Apply, backup, rollback, retirement, live-root mutation, or
Git index/ref mutation was performed.

## 2026-08-31 Phase 2 receiver-backed held-route capability observation

Commit `4af1d79` adds a narrow runtime observation over a genuine held current route and the fixed
infrastructure capability capture. The observation borrows the route, canonical witness, and global
lock while owning the frozen outer fixed-envelope handle chains delivered through a caller-owned
sealed receiver. Its contract is exactly
`Coverage=HELD_CURRENT_ROUTE_FIXED_INFRASTRUCTURE_PROBED`, `Scope=RUNTIME_ONLY`, and
`MutationAuthorization=NONE`; it is neither a plan/receipt nor mutation authority.

The public observation lifecycle surface (`Open`, `Assert`, and `Close`) has zero production callers.
In the production call graph, the current-route capture is still consumed only by the read-only
registry, whose published result remains `CurrentRouteCoverage=HELD_METADATA_VERIFIED` with
`FilesystemCapabilityCoverage=UNPROBED_READ_ONLY`. The observation therefore establishes a reviewed runtime
composition boundary without claiming resolver, dispatcher, setup, Apply, rollback, or live-mutation
integration.

The fixed-capability issuer is now scoped per PowerShell runspace in a
`ConditionalWeakTable<Runspace,...>`, with exact pinned ScriptBlock references, runspace identity,
and a definition-local issuer token. This removes the previous process-first ScriptBlock capture
across runspaces. Real `PowerShell.Stop` tests cover the receiver-backed trusted path: the route test
pins the exact `DeliverExact`-to-transfer-flag boundary, while the observation test proves receiver
durability after public `Open` has returned. Safe-chain and target tests verify their delivered
resources remain open for explicit cleanup. The observation test does not claim an internal
`DeliverExact`-to-flag breakpoint, and none of these claims extends to legacy raw success-stream
return branches or makes the complete public API Stop-safe.

Known follow-up debt includes those legacy raw returns (including safe-existing, retained traversal,
target, and live-set paths); runspace-disposal recovery and observation definitions that retain strong
runspace references; target/live `Assert` versus concurrent `Close`; transitive provider closure and
raw-getter capability transfer; computed provider-path dataflow and the literal-provider-token static
false positive; opaque bare lease wrappers; and a durable recovery ticket when route cleanup itself
fails. Step 2 remains incomplete. Task 1 remains 1/6 and Phase 2 remains 1/52; production Apply stays
interlocked.

The 2026-09-01 validation follow-up identified two deterministic suite-budget defects rather than
runtime hangs. After its analysis matrix grew from 29 to 56 results,
`canonical-production-seams.tests.ps1` completed standalone in about 166.9 seconds and then passed
56/0 under the real runner in 193092 ms with a 240-second bound. The observation lifecycle added
about nine real `Open` paths plus route captures; `root-claims-registry.tests.ps1` then passed under
the real runner with 438 PASS lines and exit code 0 in 1291927 ms with an 1800-second bound. The first
unified run had 31 passing suites, one stale reviewed-load baseline failure, and exactly those two
clean timeouts. Seventeen directly or transitively affected reviewed constants were recomputed
against the committed production bytes; the reviewed load set and static closure cardinality
remained unchanged. With suite budgets totaling
17235 seconds, setup/non-suite allowance 300 seconds, and margin 120 seconds, the computed job
requirement is 17655 seconds. The Windows workflow is now 298 minutes (17880 seconds), preserving the
same 225-second outer difference. Focused validation passed hard-kill primitives 95/0, the complete
hard-kill suite 317/0, the runner budget contract, and both real-runner timeout checks. The final
unified result is recorded in the recovery-stage follow-up below; no production Apply is authorized
by these test configuration changes.

A subsequent create-new final-validation attempt completed all 34 discovered and started suites,
with 33 passing, one failing, and zero timeouts; its summary SHA-256 is
`88b4cfd0cfb911600c3a1fbf76c7c82e362f8ffaebeaa930c6826372d9445342`. The sole failing suite was
`canonical-hard-kill.tests.ps1` at 233/5. Its first failure was a tests-only sharing race: the
recovery-stage reader used `ReadAllText` on a publisher-private temp file and thereby blocked the
publisher's `File.Move`; the other four failures cascaded from that stall.

Commit `b1fe6e1` fixes only this test-internal reader/publication race. The reader now classifies the
complete enumerated name set before opening content, treats an exact publication-temp name as stable
in-progress, gives unknown entries precedence, and reads only validated final names. Exclusive-open
probes make the temp and unknown/final classifications deterministic. Only the seven required
reviewed baselines changed; the final `canonical-hard-kill.tests.ps1` SHA-256 is
`2e3dae688d2334fe171558adfee00b68ba5e2778a5f6ae70a1a1637cf9e5c234`. Focused validation passed
primitives 95/0 and the original failing case set 22/0; the complete hard-kill suite then passed
318/0, and read-only logic/baseline audits reported no P0, P1, or P2 finding.

This does not establish held directory identity or an atomic directory snapshot. Final-file
replacement, StageRoot rebinding, and uncoordinated external scanners remain outside this tests-only
fix. The final create-new unified run discovered, started, completed, and passed all 34 suites
exactly once, with zero failures, timeouts, duplicates, missing suites, or tree-kill failures. Its
external summary SHA-256 is
`976f84e50aadc0ac37fb89acee183961d01c6f5fdf9a5ff99fda11424b72c5a8`; the embedded
`canonical-hard-kill.tests.ps1` record exited 0 and passed 318/0.

Final post-run gates also passed: the project syntax checker parsed 156 PowerShell files; registered
artifact validation passed 21 contracts, 21 positive fixtures, and 66 negative fixtures with zero
failures (summary SHA-256
`b87d5c65bc3e1f1bee8375b54acb023edf9cdb8b515da3251ca3e6ce412af0cf`); the skill build produced
Claude/Codex/Reasonix counts 7/15/7; and the pinned secret scan found zero blocking findings. A sync
DryRun used a fresh external path whose plan leaf was absent before invocation, changed no live
files, and produced PlanHash
`b94ca90b872568bddeed048a959b37b40f0cd8f1d89c90936afa876a32783e2e` with plan-file SHA-256
`4c5ccb35185531f5da8a052371bef4a3f76a741571056536ea22a2e92a236d08`. No Apply was run. Task 1
remains 1/6, Phase 2 remains 1/52, and production Apply remains interlocked.

## 2026-09-01 Phase 2 observation issuer per-runscape definition migration

Commit `4af1d79` left the observation issuer
(`SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer`) as the last issuer in
`scripts/root-claims-registry-common.ps1` whose pinned definitions were stored in one process-static
`Dictionary<string,...>` keyed by normalized runscape-id strings. That closed Step 1 but kept the
runspace-lifecycle debt open. This slice migrates that store to the reviewed per-runscape pattern the
route-capture and fixed-capability issuers already use: definitions now live in a
`ConditionalWeakTable<Runspace,...>` and each definition carries an `OwnerRunspaceId` Guid binding.
`RequireDefinition` and the observation receipt validation resolve definitions only through the live
current-runscape object, its instance id, and that owner binding; `InitializeObservationExact`
validates the supplied runscape id against the actual current runscape before registration. The
fail-closed contracts are unchanged: cross-runscape assert/close still rejects, same-text
ScriptBlock substitution still rejects, and clone/uninitialized instances still cannot forge
provenance. The public issuer surface, the observation facade, and every PowerShell-level function
are byte-identical; only the C# definition store changed.

Test changes in `tests/root-claims-registry.tests.ps1`: the definition lookup now goes through the
weak-keyed table exactly like the route-capture lookup, a new assertion pins the storage type and the
`OwnerRunspaceId` binding, and a child-runscape probe proves recovery semantics — a fresh runscape
that dot-sources the registry initializes its own equal-digest definition bound to itself while the
parent definition stays bound to the parent. The focused suite reached 442 PASS lines with exit code
0 (438 before this slice), with zero failures.

An eviction probe (kept outside the repository under `tmp/`) also recorded an honest boundary:
forced garbage collection after disposing a child runscape did NOT evict the route-capture issuer's
existing CWT entry, because the pinned ScriptBlock/session-state chain keeps the owner runscape
reachable. The migration therefore delivers per-runscape scoping, identity binding, and fresh-runscape
recovery; it does not claim collection or eviction guarantees for any of the three issuers.

Validation on 2026-09-01: focused `root-claims-registry.tests.ps1` passed 442 assertions with exit
code 0, and `canonical-production-seams.tests.ps1` passed 56/0 after a single re-pin — the
reflection-sensitive inventory count stayed 12660 while its digest moved from
`aea11a7fb381a9e9533f0b015507f9661f35dad426461b486b7d64b37a7dc2ab` to
`343ec71636bbd1b91f0d4989d271559badb5cf28ac88bad149894a3ebac0dfcc` because the C# here-string edit
shifts inventoried-site positions. The PowerShell parse gate accepted all 156 files; the skill build
produced 7/15/7; the pinned secret scan found no blocking findings (835 non-blocking hints);
`git diff --check` was clean; and `sync.ps1 -DryRun` with a fresh external plan path reported 29
additions with zero modified/removed/unknown targets, preserved Codex `.system`, changed no live
file (plan-file SHA-256
`44ef6692064762be975310d9a73864532e828214ba101ee08322af666a00ac54`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`2e5fc36a843481532af00606a3cb98f31e908e702b4ea1ceb309ccd6c15867dd`; discovery SHA-256
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`; computed job requirement 17655
seconds). Inside that run `canonical-hard-kill.tests.ps1` passed 318/0,
`canonical-production-seams.tests.ps1` passed 56/0, and `root-claims-registry.tests.ps1` passed
442/0. Task 1 remains 1/6 and Phase 2 remains 1/52. Production Apply remains interlocked, and no
live root or Git index/ref was changed.

## 2026-09-01 Phase 2 observation caller/cleanup ledger

Step 2's named deliverable is now production-defined: an additive sealed caller/cleanup ledger that
can own and explicitly close the runtime observation. `scripts/root-claims-registry-common.ps1`
gains the CLR `SealedHeldObservationCleanupLedger`, five issuer lifecycle statics
(`OpenObservationCleanupLedgerExact`, `RegisterObservationCleanupLedgerEntryExact`,
`AssertObservationCleanupLedgerExact`, `CloseObservationCleanupLedgerEntryExact`,
`CloseObservationCleanupLedgerExact`), and five reviewed facade functions
(`Open-SealedHeldObservationCleanupLedger`,
`Register-SealedHeldObservationCleanupLedgerObservation`,
`Assert-SealedHeldObservationCleanupLedger`,
`Close-SealedHeldObservationCleanupLedgerObservation`,
`Close-SealedHeldObservationCleanupLedger`). The ledger opens only through a caller-owned
`SealedOwnershipTransferReceiver` and binds to its owner runscape's live issuer definition by
provenance token, definition digest, and runscape instance id. Registration accepts only a genuine,
receipt-bound, OPEN observation and records it as a single-use entry; duplicate registration,
registration of a closed observation, and registration on a closing/closed ledger all fail closed
with `held-observation-cleanup-ledger-stale`. Ledger close refuses while any registered entry is
OPEN (`held-observation-cleanup-ledger-open-entries`); each entry close releases the observation
through the exact reviewed `CloseObservationExact` route before committing the entry, and the ledger
close itself is single-use and idempotent. Assert, close, and state inspection all fail closed from
a foreign runscape and against `MemberwiseClone` provenance copies. The observation's public
Open/Assert/Close APIs retain zero production callers — the ledger closes through the issuer's
internal static route, and no PowerShell-level observation call was added. The ledger itself has
zero production consumers; no resolver, dispatcher, setup, Apply, rollback, or live-mutation route
uses it, and it grants no mutation authority.

Test changes: `tests/root-claims-registry.tests.ps1` extends the issuer public-method freeze to the
ten reviewed statics, extends the public-command selector-rejection enumeration to the five new
functions, and adds a full ledger lifecycle block — receiver-delivered open, genuine/OPEN/empty/
owner-bound evidence, receiver-reuse rejection, duplicate and closed-observation registration
rejection, open-entries close rejection, entry close through the exact route, idempotent entry
close, unregistered-observation close rejection, clone rejection, foreign-runscape rejection,
single-use ledger close, and closed-ledger rejection — reaching 480 PASS lines with exit code 0
(442 before this slice). `tests/canonical-production-seams.tests.ps1` re-pins deliberately: five new
issuer invocation rows, five owner-binding rows with the reviewed function-AST digests, and the
reflection-sensitive inventory (count 12660 → 12682, digest
`343ec71636bbd1b91f0d4989d271559badb5cf28ac88bad149894a3ebac0dfcc` →
`374b019e0e591b913d647e99d0f6c765bceb14aebe4fb77ecdcbb016819a4dd8`; the dynamic-command digest is
unchanged), passing 56/0.

Validation on 2026-09-01: focused `root-claims-registry.tests.ps1` passed 480 assertions with exit
code 0; `canonical-production-seams.tests.ps1` passed 56/0; the parse gate accepted all 156 files;
the skill build produced 7/15/7; the pinned secret scan found no blocking findings (837 non-blocking
hints); `git diff --check` was clean; and `sync.ps1 -DryRun` with a fresh external plan path changed
no live file (plan-file SHA-256
`f880cf5f6778e45ec397f043d411ec152b4c457bf8700b4693afca5e67744c82`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`3e2274593188ed79fde14be647410093e0606246302ff12aa51ff902c7252512`; discovery SHA-256
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`), with hard-kill 318/0, seams
56/0, and root-claims 480/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52. Production
Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-01 Phase 2 live-set receiver-backing

The live-set member of the receiver/raw-return blocker is closed.
`Open-SealedHeldLiveTargetContextSet` in `scripts/live-target-context.ps1` now requires a
caller-owned `SealedOwnershipTransferReceiver` and delivers the held live-set lease through exact
ownership transfer only; the legacy raw success-stream return branch is removed. Production was
already receiver-based — the pinned route-capture live-set open core passes the receiver and asserts
zero output — so no production caller changed behavior. The open-failure cleanup path is unchanged:
when delivery never happens (including a `PipelineStoppedException` raised before delivery), the
finally block releases the receipt and every nested lease exactly as before.

Test changes in `tests/root-claims-registry.tests.ps1`: the three raw-branch call sites were
converted to receiver style (the pipeline-retention probe now proves receiver durability instead of
`Select-Object -First 1` short-circuit retention; the provider-isolation victim opens through its
own receiver), and two new assertions pin the exact four-parameter mandatory-receiver contract and
reject a receiver-less invocation with the parameter-binding error. The focused suite reached 482
PASS lines with exit code 0 (480 before this slice). The seams suite passed 56/0 without any
baseline change — the edit touches no inventoried member, type, or literal text in the
reflection-sensitive inventory. The target-lease, safe-existing, and retained-traversal raw-return
branches remain open (two of them live in hard-kill-pinned files).

Validation on 2026-09-01: focused `root-claims-registry.tests.ps1` passed 482 assertions with exit
code 0; `canonical-production-seams.tests.ps1` passed 56/0; the parse gate accepted all 156 files;
the skill build produced 7/15/7; the pinned secret scan found no blocking findings (841 non-blocking
hints); `git diff --check` was clean; and `sync.ps1 -DryRun` with a fresh external plan path changed
no live file (plan-file SHA-256
`dda9dcff69c1b6da4575f020c05ab6549105fb5003e454680198e685ddef08ab`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`57066efaac18f9a8b849eee852a6fc58721c7f90b1f31c2fc0ed0136229a634f`), with hard-kill 318/0, seams
56/0, and root-claims 482/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52. Production
Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-02 Phase 2 target-lease receiver-backing

The target-lease member of the receiver/raw-return blocker is closed.
`Open-SealedHeldTargetContextLease` in `scripts/target-context-common.ps1` now requires a
caller-owned `SealedOwnershipTransferReceiver` and delivers the held target-context lease through
exact ownership transfer only; the legacy raw success-stream return branch is removed. Production
was already receiver-based — both the pinned route-capture target open core and the live-set open
pass the receiver — so no production caller changed behavior. The open-failure cleanup path is
unchanged: when delivery never happens (including a `PipelineStoppedException` before delivery),
the finally block releases the receipt and every frozen directory handle exactly as before.

Because `scripts/target-context-common.ps1` is sealed byte-for-byte by the hard-kill suite, the
change required the full reviewed-load re-pin: the manifest hash moved from `d777c1c4…` to
`a3a585b0f957f943d9a36959e304247abc8a9208c6799885cac9b3dd548d348c` at both recorded sites, and the
self-seal pins were recomputed to a fixpoint with an out-of-repository probe — the 24-row
actual-prelude block and its digest (now
`77d3145dbb8df1bcdf17e90c809ff34798e40803f9206ca6af1c5930dca3cf81`, four occurrences), the
27-statement pre-section region digest (`0317b628…`), the
`Test-HardKillPreimageControllerTransportContract` and `…ContractMutations` function pins, the
function-inventory digest, the cleanup-gate self digest, the main-try execution digest, the
top-level execution digest, and the whole-file controller surface digest. The final hard-kill file
SHA-256 is `27da95165a92b253fea5714111cd680e8e46865f46e0d363ddccf2f7a25bda63`. The probe also
confirmed the known hyphen leak in the historical function-pin regex — function names containing
hyphens were invisible to the previous `[A-Za-z0-9]+` pattern and are matched by
`[A-Za-z0-9-]+` in the adapted probe; the shipped suite was re-pinned by the corrected loop, and no
suite assertion was weakened.

Test changes: the six raw-branch call sites were converted to receiver style — the two target Stop
probes (stop during evidence capture and stop at the receipt-binding assert both keep their
post-state semantics because delivery is never reached), the target `Select-Object -First 1`
probe (now receiver-durability), the provider-isolation victim, the path-safety held-missing lease,
and the root-claims fixture invocations — plus two new assertions pinning the exact
path-plus-mandatory-receiver contract and rejecting a receiver-less invocation. The focused
root-claims suite reached 484 PASS lines with exit code 0 (482 before this slice). The seams suite
passed 56/0 without baseline change (no inventoried member, type, or literal text changed).

Validation: the complete standalone `canonical-hard-kill.tests.ps1` run passed 318/0 (primitives
first passed 95/0 as a fast signal); `tests/path-safety.tests.ps1` passed; focused root-claims
passed 484 assertions with exit code 0; seams passed 56/0; the parse gate accepted all 156 files;
the skill build produced 7/15/7; the pinned secret scan found no blocking findings (843 non-blocking
hints); `git diff --check` was clean; and `sync.ps1 -DryRun` with a fresh external plan path changed
no live file (plan-file SHA-256
`2f89fafb31f933301d26c70c40c9161e9898581cc461e3ba566b07eae1bdc759`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run for this slice has not been executed yet and remains
pending. Task 1 remains 1/6 and Phase 2 remains 1/52. Production Apply remains interlocked, and no
live root or Git index/ref was changed.

## 2026-09-02 Phase 2 safe-existing containment receiver-backing

The safe-existing member of the receiver/raw-return blocker is closed.
`Open-SafeExistingDirectoryContainmentChain` in `scripts/safe-tree-walker.ps1` now requires a
caller-owned `SealedOwnershipTransferReceiver` and delivers the held containment handle chain
through exact ownership transfer only; the legacy raw `return ,$handles` branch is removed and the
empty-receiver assertion is unconditional. Production was already receiver-shaped at every reviewed
consumer: all six raw call sites were converted to the two-line receiver pattern (create receiver,
open with it, extract the delivered list) — `safe-tree-walker.ps1` internal callers in the
entry-marker lookup and the create-new copy path, `approved-runner-common.ps1` destination
materialization, `canonical-mutation-common.ps1` leaf-parent preparation, and
`transaction-journal-common.ps1` journal-parent and worktree-root capture. `GetDeliveredExact`
returns the identical list instance, so downstream indexing, close-on-error, and finally cleanup
semantics are unchanged at every site. The plain `Open-SafeDirectoryContainmentChain` variant and
the retained-traversal composite remain open members of the blocker.

Because `safe-tree-walker.ps1`, `canonical-mutation-common.ps1`, and
`transaction-journal-common.ps1` are all hard-kill-sealed, the full reviewed-load re-pin was
performed to a fixpoint with the generalized out-of-repository probe (now covering N manifest
hashes): three manifest hashes re-pinned at both recorded sites (`safe-tree-walker` →
`0c9024699101cd260ae731b2ebf6970cf0846134af92ffa2faca2f1ddf7fb889`, `canonical-mutation-common` →
`70ee83e0a901559a8aa2bf14dfce4f38882689dbc97f222c2a76830b3a1b92a6`, `transaction-journal-common` →
`77594bf5c7632ce7b83cc53f5f5eda2f6048e88a2f104dc654e7c521164642c8`), plus the 24-row actual-prelude
block and digest (`ce6416f2…`, four occurrences), the 27-statement pre-section region digest
(`dba2c033…`), the transport-contract and mutations function pins, the function inventory, the
cleanup-gate self digest, the main-try execution digest, the top-level execution digest, and the
whole-file controller surface digest. Final hard-kill file SHA-256 is
`4766228f652c99aa0728ba4e02913b43ca4775eb0644505d57260cbd5091c9ae`. The production closure contract
(67 functions / 131 edges / digest `b15898c8…`) passed unchanged inside the full hard-kill run,
confirming that boundary-function body edits do not enter the closure digest.

Validation: primitives passed 95/0 as a fast signal; the complete standalone
`canonical-hard-kill.tests.ps1` run passed 318/0; `approved-runner.tests.ps1`,
`canonical-mutation-blockers.tests.ps1`, `transaction-journal-exact-byte.tests.ps1`, and
`path-safety.tests.ps1` all passed; the seams suite passed 56/0 after one re-pin (the six call-site
conversions add twelve reflection-sensitive sites: count 12682 → 12694, digest
`374b019e…` → `77ec47b44f27267a3c3943d5078d3070b0b5cf5eadb0d405150915c5326904f5`); the parse gate
accepted all 156 files; the skill build produced 7/15/7; the pinned secret scan found no blocking
findings (845 non-blocking hints); `git diff --check` was clean; and `sync.ps1 -DryRun` with a
fresh external plan path changed no live file (plan-file SHA-256
`311b3e9325a072125952361bf0b1d144b46d4c1c10b1f27b551f714fb5e11fde`, deleted after the run). The
unified `run-tests.ps1 -All` run started for the previous commit `48a30ae` was killed externally at
suite 5 of 34 with no summary (background-process loss during a session restore; no result was
published), so the definitive unified run for the branch state executes once after this commit and
covers both `48a30ae` and this slice; every suite affected by either slice has passed standalone.
The definitive combined create-new unified run then discovered, started, completed, and passed all
34 suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill
failures (external summary SHA-256
`20b522730ef2e034d3f9467ea9023d450999ba1b7baad71d523885813304753f`; discovery SHA-256
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`), with hard-kill 318/0, seams
56/0, root-claims 484/0, approved-runner 45/0, mutation suites green, and
transaction-journal-exact-byte 12/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52.
Production Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-02 Phase 2 plain containment-chain receiver-backing

The largest member of the receiver/raw-return blocker is closed. `Open-SafeDirectoryContainmentChain`
in `scripts/safe-tree-walker.ps1` now requires a caller-owned `SealedOwnershipTransferReceiver` and
delivers the held containment handle chain through exact ownership transfer only; the legacy raw
`return ,$handles` branch is removed and the empty-receiver assertion is unconditional. All thirty
production call sites across nine scripts converted to the two-line receiver pattern
(`approved-runner-common` ×2, `canonical-preflight-common` ×2, `canonical-transaction-common` ×3,
`home-authority-common` ×5, `json-artifact-common` ×6, `root-claims-registry-common` ×4,
`safe-tree-walker` ×2, `target-context-common` ×1, `transaction-journal-common` ×6 including the
`-CreateMissing` early-return branch); `GetDeliveredExact` returns the identical list instance, so
downstream indexing, close-on-error, and finally cleanup semantics are unchanged. Test-side real
call sites converted across eleven files (canonical-hard-kill ×5 plus the
`HardKillBehaviorAcquire` delegate scriptblock and its fingerprint pin, canonical-recovery,
canonical-mutation-parent-lease inline compound, home-authority ×6, transaction-journal-exact-byte
×2, root-claims-registry ×3, canonical-hard-kill-host ×2, canonical-setup-kill-host ×2,
pinned-tool-process-probe, safe-tree-walker ×7); source-text assertions were unaffected. With this
slice the safe-existing, target-lease, live-set, and plain containment-chain raw-return branches are
all receiver-backed; only the retained-traversal composite remains open in the blocker.

The six hard-kill-sealed production scripts plus the sealed `canonical-hard-kill-host.ps1` helper
required the full reviewed-load re-pin to a fixpoint, which surfaced two new self-seal pin classes
beyond the established ten: the two pre-section section-owner IF-statement token hashes
(`43811abcef…` → `a5c1391c…` for the primitives-section owner; the setup owner unchanged), and the
preimage provenance contract's `allowedMembers` whitelist, which now admits the reviewed
`GetDeliveredExact` extraction call used by the receiver pattern. Final hard-kill file SHA-256 is
`cb2cc1cf4e0e5ab887bd4795b901a63ab9fd813398f2010af972f811000db40a`. The production closure contract
(67/131/`b15898c8…`) again passed unchanged.

Validation: primitives passed 95/0 after the fixpoint; the complete standalone
`canonical-hard-kill.tests.ps1` run passed 318/0; canonical-recovery, canonical-mutation-parent-lease,
home-authority, transaction-journal-exact-byte, path-safety, approved-runner, canonical-preflight,
json-artifact-exact-byte, and safe-tree-walker suites all passed; the seams suite passed 56/0 after
one reflection re-pin (count 12694 → 12756, digest →
`7679a8a55fcbdc96a6654cb914bcd2ea337e2654d54d3211d7df6d647b18097c`); the parse gate accepted all 156
files; the skill build produced 7/15/7; the pinned secret scan found no blocking findings (847
non-blocking hints); `git diff --check` was clean; and `sync.ps1 -DryRun` with a fresh external plan
path changed no live file (plan-file SHA-256
`25aa688305faeb4119c00bfd92626f1b1bc3e1c676611ff4caa8a234e1ac2a67`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`893a9fd46c97c89105a7322e88461283a8e68be1143b10b36c44139f7074a33e`), with hard-kill 318/0, seams
56/0, root-claims 484/0, home-authority 190/0, and the mutation suites green inside the run. Task 1
remains 1/6 and Phase 2 remains 1/52. Production Apply remains interlocked, and no live root or Git
index/ref was changed.

## 2026-09-02 Phase 2 retained-traversal receiver-backing

The retained-traversal member of the receiver/raw-return blocker is closed — the last raw
success-stream branch in the sealed read-only registry's resource chain.
`scripts/safe-tree-walker.ps1` gains the reviewed sealed wrapper `Open-SafeTreeRetainedTraversal`
(mandatory caller-owned `SealedOwnershipTransferReceiver`, exact ownership transfer of the
snapshot-plus-retained-handles composite, and a finally block that disposes the file-handle map and
containment chain if delivery never happens), and the raw
`Get-SafeTreeSnapshotInternal -RetainContainmentHandles` path is no longer reachable from
production: all three consumers (`Copy-SafeTree`, `New-CommittedDataSnapshot` in
approved-runner-common, and `Get-CanonicalRetainedDirectoryObservation` in canonical-mutation-common)
now open through the wrapper's receiver. `Get-SafeTreeSnapshot`/`Get-SafeTreeSnapshotInternal`
remain for read-only tree hashing with no retained handles.

Because both edited scripts are hard-kill-sealed, the full re-pin was performed: reviewed-load
manifest hashes (`canonical-mutation-common` → `9b77a0a3…`, `safe-tree-walker` → `e040c417…` at
both sites), the self-seal fixpoint (prelude rows/digest, pre-section region, function pins,
inventory, self, main-try, top-execution, surface), and the production-closure contract whose
boundary set changed membership by exactly one — `Get-SafeTreeSnapshotInternal` dropped out of the
referenced boundary set (its only closure-reachable caller now goes through the wrapper) while
`Open-SafeTreeRetainedTraversal` entered with the identical `ShouldSkipEntry` ParameterAst digest
`c341358e…`; `FunctionCount=67`, `EdgeCount=131`, `BoundaryCount=13` are unchanged and the closure
digest moved to `a719c9cb940a98e091941ef079e317f0f28b6e4f66d7a9f513b5232933ab2d9c` in the contract
baseline and the cleanup-gate assertion. A closure diagnostic (out-of-repository) reproduced the
exact boundary membership change before re-pinning. Final hard-kill file SHA-256
`45c88d9fedf7a61ad0fe410f851b2bd03207176766d4a40c0ccdbb0b5c29bfc9`.

Test changes: the mutation-blockers static assertion now requires
`Get-CanonicalRetainedDirectoryObservation` to route through `Open-SafeTreeRetainedTraversal` and
to retain no direct `RetainContainmentHandles` reference; the seams suite re-pins deliberately —
the closure inventory gains `Open-SafeTreeRetainedTraversal|scripts/safe-tree-walker.ps1`, the
exception inventory gains its `ScriptBlockParameter` row (digest
`ad9aa49e06084082906d3b0e94f20c6148ccb80dbe01ee7ff0a2b3f0993ef733`), and the reflection-sensitive
inventory moves from count 12756/digest `7679a8a5…` to count 12768/digest
`7c88fdec06bd95d47c49a8f9a30e6977caad3230b1ab8c465cb3f46570860437` — passing 56/0.

Validation: hard-kill primitives 95/0 (after the closure-baseline fix) then the complete standalone
suite 318/0; `canonical-mutation-blockers` 32/0, `canonical-recovery` 104/0, `skills-import` 42/0,
focused root-claims 484 assertions with exit code 0; seams 56/0; the parse gate accepted all 156
files; the skill build produced 7/15/7; the pinned secret scan found no blocking findings (851
non-blocking hints); `git diff --check` was clean; and `sync.ps1 -DryRun` with a fresh external plan
path changed no live file (plan-file SHA-256
`74853edddd106b47106b6a8fdf5de7496121a1c05c72a86cb49b9dbe781ad209`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`d9fab280ff76df72b8b1507e96378583e9abce5671678c718834037c5b5a0f39`), with hard-kill 318/0, seams
56/0, root-claims 484/0, mutation-blockers 32/0, recovery 104/0, and skills-import 42/0 inside the
run. Task 1 remains 1/6 and Phase 2 remains 1/52. Production Apply remains interlocked, and no live
root or Git index/ref was changed.

## 2026-09-02 Phase 2 target/live reader-close blocking

The target/live reader-close blocker is closed: the held target-lease receipt and the held live-set
receipt now protect their release path from concurrent readers. Both CLR receipt classes
(`SealedHeldTargetContextLeaseReceipt`, `SealedHeldLiveTargetContextSetReceipt`) gained a lifecycle
gate with an active-reader counter and public `BeginReadExact`/`EndReadExact` instance methods;
`Assert-SealedHeldTargetContextLease` and `Assert-SealedHeldLiveTargetContextSet` hold the read for
their whole revalidation, and `ReleaseForWrapperExact` in both classes — after acquiring the
closing transition — restores `OPEN` and throws `target-context-close-active` when any reader is
still active. A closed receipt refuses new readers with the stale message; an unbalanced reader
release fails closed; closing is still single-use and idempotent for repeated calls. The nested
live-set close continues to cascade to its three target leases only after the set-level reader
releases. `live-target-context.ps1` is not hard-kill-sealed; `target-context-common.ps1` required
the manifest re-pin plus the full self-seal fixpoint (13 updates across two fixpoint iterations).
Final hashes: hard-kill file `34f244cb0e84a27aa44e2fe764c0fcc706478a35bdf260a860cee37fa031c329`,
target-context-common `5fc1433e7187aa9a3da0efbf7301f8ace4e2a42cccdebe2ab1dda8ba4eb973d5`.

Tests in `tests/root-claims-registry.tests.ps1` (498 PASS lines with exit code 0, up from 484):
a target lifecycle block (active reader blocks close, rejected close leaves OPEN, nested second
reader keeps blocking, unbalanced release fails closed, close after last release, closed lease
refuses readers), a live-set lifecycle block (reader blocks close with all three nested leases
OPEN, close after release cascades closed, closed set refuses readers), and a real-concurrency
orchestration in which a child runscape's target `Assert` is blocked on its first evidence re-read
while the main runscape's concurrent close is rejected `target-context-close-active` with the lease
left OPEN, after which the assert completes and the caller closes. The seams suite re-pinned only
the reflection-sensitive inventory (count 12768 → 12772, digest →
`7f867f392eeb3210fc17964f407a774ba6cbbb9ff81ca86a1aac43be53c69efb`) and passed 56/0.

Validation: hard-kill primitives 95/0 then the complete standalone suite 318/0; focused
root-claims 498 assertions with exit code 0; seams 56/0; the parse gate accepted all 156 files; the
skill build produced 7/15/7; the pinned secret scan found no blocking findings (853 non-blocking
hints); `git diff --check` was clean; and `sync.ps1 -DryRun` with a fresh external plan path
changed no live file (plan-file SHA-256
`d5dc1a2c38c94aedf351175e6a47f28482c0d0ba263c0d1fa4c4fd9318af9578`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`2ff091391f1be4fe8e9c65c83f408d33a29cc96b43c75f97a78f136e8fe301d5`), with hard-kill 318/0, seams
56/0, and root-claims 498/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52. Production
Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-02 Phase 2 raw-getter capability stripping

The raw-getter capability-transfer member of the provider-closure blocker is closed. An
out-of-repository closure survey first established that every transitive-close path in the
observation chain is already complete (observation-owned envelope plus six chains, live-set
cascade to three nested leases, route-capture cascade to every lease, per-chain disposal) and that
the real exposure is the observation facade handing out the route-capture-owned live-set wrapper
and its internal receipt: a caller could close the nested leases under an open container and leave
an unclosable capture. `SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation` now returns
a capability-stripped state projection from both getters: `GetLiveSetLeaseExact` and
`GetLiveSetReceiptExact` keep their reviewed names (the 27-name facade method table freeze is
untouched) but return the new CLR `SealedHeldLiveSetBorrowedStateProjection` (CloseState, IsClosed,
TargetLeaseCloseStates), built through a private cross-assembly exact-reflection helper so the
borrowed receipt types stay reachable without a direct type reference. The two production identity
checks in `ObservationMatchesBorrowedExact` now compare the internal `LiveSetLeaseFieldExact` /
`LiveSetReceiptFieldExact` accessors; `GetCurrentRouteCaptureExact` and the caller-owned authority,
witness, and global-lock getters remain raw by design (transfer by design, identity-pinned by
tests).

Tests in `tests/root-claims-registry.tests.ps1` (501 PASS lines with exit code 0, up from 498):
both getters return the projection type with the open live set reflected (OPEN, not closed, three
nested OPEN states), `Close-SealedHeldLiveTargetContextSet` fed the projection fails closed with
the receipt-missing stale error, and the receipt projection carries no nested-lease accessor. The
seams suite re-pinned only the reflection-sensitive digest (count 12772 unchanged, digest →
`192eefa23d29fd66d776f6197b1b5071dafc8911f852b776c19f58852e652a33`) and passed 56/0; none of the
three edited files is hard-kill-sealed. Focused root-claims passed 501 assertions with exit code 0;
the parse gate accepted all 156 files; the skill build produced 7/15/7; the pinned secret scan
found no blocking findings (855 non-blocking hints); `git diff --check` was clean; and
`sync.ps1 -DryRun` with a fresh external plan path changed no live file (plan-file SHA-256
`0f8bf1a4e95b1ff95daab244140d9b825e2c990d044132f39f247f6e62af92ad`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`c2a35eb71dfa9ec0e83a695d5aaeffe22d09a4d033df5229800dc2a4b4d29338`), with hard-kill 318/0, seams
56/0, and root-claims 501/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52. Production
Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-02 provider-token debt closure assessment

A read-only assessment of the remaining provider-closure sub-debt concluded that the
"computed provider-path dataflow and a literal-provider-token static false positive" item from the
2026-08-31 checkpoint is already covered by shipped work and needs no code change. The seams suite
scans every non-comment token for literal `Alias:`/`Function:` drive syntax, explicitly recognizes
drive-qualified variable forms (`$alias:name`, `${function:name}`), and pairs both with mutation-RED
acceptance tests ("contiguous literal Alias:/Function: provider-drive tokens cannot hide an
observation API call"); the suite comment declares computed paths and general provider-mutator data
flow out of scope as a deliberate design boundary supplemented by direct named CommandAst analysis,
and the full 56/0 suite shows zero false positives. The remaining open Step 2 sub-debts are the
opaque bare lease wrappers, the durable recovery ticket when route cleanup itself fails, and then
wiring the cleanup ledger as the reviewed observation lifecycle owner.

## 2026-09-02 Phase 2 bare-lease wrapper de-mirroring

The opaque bare lease wrappers sub-debt is materially reduced. An out-of-repository survey of the
route-capture chain established that every route-capture collection wrapper (live-set, three route
rows, reservations, fixed leases) is receipt-bound before delivery, so the receipt CWT is always
the authoritative state store; the opacity channel is the mutable `IsClosed` NoteProperty that both
close functions best-effort mirrored onto wrappers inside a swallowed-catch block, duplicating
receipt state and drifting or forging silently. A precise reader census found zero production or
test readers of that property on target/live wrappers (the identically named property on
canonical captures, witnesses, and the fixed-envelope lease belongs to different objects and stays
untouched). This slice deletes the display: the `IsClosed = $false` constructor line and the whole
post-close mirror block are removed from both `target-context-common.ps1` and
`live-target-context.ps1`, making the bound receipt the single close-state truth for every
route-capture collection wrapper. A new root-claims assertion pins that a closed target wrapper
carries no `IsClosed` property at all (502 PASS lines with exit code 0, up from 501). The envelope
lease's own `IsClosed` — which is authoritative there because that wrapper has no receipt — is
deliberately untouched and remains a separate follow-up.

Because `target-context-common.ps1` is hard-kill-sealed, the manifest re-pin plus the full self-seal
fixpoint was performed (13 updates, fixpoint reached); final hard-kill file SHA-256
`4c84e4a89f9a11b40338e50743a0e42a1824fca61bc822573d8d053d5923320e`. The seams suite re-pinned the
reflection-sensitive inventory (count 12772 → 12754, digest →
`45f42c81ed65ead0ed0ec7bb4967e2064958853613e2c7df5e215e7e28624788`) and passed 56/0. Validation:
primitives 95/0, complete hard-kill 318/0, focused root-claims 502 assertions exit 0, path-safety
PASS, parse gate 156 files, build 7/15/7, secret scan clean (862 non-blocking hints),
`git diff --check`, and `sync.ps1 -DryRun` with a fresh external plan path changed no live file
(plan-file SHA-256
`669bbeb39ffdadcc860ded307e5cce66cb1e4a3c4a4dc17c92c6c0fbd605a148`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`48ef95c84061f511da22a3e6ca32b681c67e99884431d86d7ca90bdfacc45076`), with hard-kill 318/0, seams
56/0, root-claims 502/0, and path-safety 43/0 inside the run. Task 1 remains 1/6 and Phase 2
remains 1/52. Production Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-02 Phase 2 envelope close-state CWT-ization

The fixed-envelope lease's authoritative close state moved from the mutable `IsClosed`
NoteProperty into the new CLR `SealedHomeAuthorityFixedEnvelopeCloseState` table (a
`ConditionalWeakTable<object,CloseRecord>` with `BindExact`/`GetIsClosedExact`/`MarkClosedExact`,
volatile-backed reads, unbound objects read as open and mark as a no-op), replacing the spoofable
display at every authority point: both envelope construction sites (the HA bootstrap open and the
observation's C# owned-envelope construction) bind at construction, the raw
`Close-SealedHomeAuthorityFixedEnvelope` idempotence gate and write, the projection invalidation
check, the observation owned-close and force-close paths, and the open-path validation all read and
write only the table. The `IsClosed` NoteProperty no longer exists on any envelope.

An independent Grok review (read-only, invoked through the reviewed wrapper) caught a P0 layering
defect before commit: the class initially lived in `root-claims-registry-common.ps1`, but
`home-authority-common.ps1` is dot-sourced standalone by `tests/home-authority.tests.ps1`,
`tests/live-concurrency.tests.ps1`, and the bootstrap test host, so the hard dependency would have
broken the HA-only path. The class moved into `home-authority-common.ps1`'s own guarded `Add-Type`
(single definition — the observation side reaches it through the existing cross-assembly
exact-reflection helper), and the two HA-only suites plus the full suite were then run for the
first time in this slice. The review's P2s were also adopted: volatile-backed close reads,
`BindExact` moved before the initial projection so the open-failure close path marks a bound lease,
and two anti-forgery assertions pin that a forged `IsClosed` NoteProperty cannot set the
authoritative state. The pinned issuer snapshot ScriptBlocks still describe the old NoteProperty
shape by design — they are definition-digest identity pins, never dispatched; that boundary is
recorded here rather than changed.

Validation: `home-authority.tests.ps1` PASS, `live-concurrency.tests.ps1` PASS, focused
root-claims 504 PASS lines with exit code 0 (502 before; the two new anti-forgery assertions),
seams 56/0 after the reflection baseline re-pin (count 12753 → 12755, digest →
`41c54b748eebd551d71c4e84a4cdca8535a336a10853e9dabbacf41f3ff66e3f`), complete hard-kill 318/0,
path-safety PASS, parse gate 156 files, build 7/15/7, secret scan clean (864 non-blocking hints),
`git diff --check`, and `sync.ps1 -DryRun` with a fresh external plan path changed no live file
(plan-file SHA-256
`44fee4cadf291bbdd3ec50107694ab0eb2e5babfbd6bc589755d454f24b4b0cb`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`fe57091678b947bd8424a799cf738dba316177af24689bd15847747d740f45f6`), with hard-kill 318/0, seams
56/0, and root-claims 504/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52. Production
Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-02 execution status: parallel design batch, staging locks rebuilt, remaining queue

Execution state after the envelope close-state slice (`d8adace`):

- **Staging locks rebuilt (Next actions #2 done).** `envs/` was entirely absent (`staging=missing`,
  not stale); `env build minimal/work/full` created the trees fresh and bound all three locks to the
  current HEAD. `env status` reports `definition=valid staging=built lock=valid` for all three;
  `tests/harness-env.tests.ps1` passed 126/0; the working tree stays clean (the whole `envs/` and
  `state/` trees are git-ignored) and no interlock or live state was touched.
- **External design batch (first round).** Under the model routing rule (Grok = hard, Luna = easy,
  main agent = medium; all efforts maxed): Luna produced the durable recovery ticket design
  (410 lines: schema with `CloseState`+`AttemptState` per lease, sibling
  `route-cleanup-recovery` placement, CreateNew/flush/rename atomic protocol, 7-key
  `DurableRecoveryTicket*` Exception.Data set, 9-test plan, 7-step slice list); Grok produced the
  ledger-wiring design (334 lines: three-candidate comparison, the adopted (b) lifecycle
  Open/Assert/Close owner trio, full freeze/seams impact matrix, failure matrix, ticket-separation
  decision, A/B/C slice list with ten explicit non-goals); Luna also drafted the ticket test block
  (52 KB, 9 test blocks + 22 declared helper prerequisites) for adoption at implementation time.
- **Main-agent medium-task correction.** The planned ticket root
  `<ControlBase>
oute-cleanup-recovery` conflicts with the envelope projection's exact immediate-
  children whitelist for `ControlBase` (HA `$fixedChildren`), which would break every observation
  open once a ticket is written. Implementation slice 1 must therefore add `route-cleanup-recovery`
  to `$fixedChildren.ControlBase` and update both suites' children assertions **in the same
  commit**; the sibling directory does not affect the read-only registry's `recovery-required`
  inventory of `live-transactions` itself.

### Remaining queue (in dependency order)

1. **Slice 1 — durable recovery ticket** (Luna's 7-step list): descriptor + sibling root with the
   whitelist coupling above, canonical JSON/ContentHash/atomic protocol, `ReleaseExact` firstError
   publication with `Exception.Data`, read-only discovery, failure/collision matrix, docs. Files:
   `scripts/root-claims-registry-common.ps1` (or HA for the root policy), both test files.
2. **Slice A — ledger wiring owner trio** (Grok's slice A): `Open-/Assert-/Close-SealedHeldObservationLifecycle`
   with dual receivers, seams zero-caller boundary rewritten to unique-owner for `Open-/Assert-`
   (Close stays zero), unique-caller checks for the five ledger facades, reflection re-pin.
3. **Slice B — owner failure matrix** (Grok's slice B, separate merge): five failure-path tests;
   no seams re-pin unless the owner finally changes.
4. **After A/B:** resolver/dispatcher becomes the sole consumer of the lifecycle trio (Phase 3
   adjacent); `PrivateRootBootstrapIntent` setup path; protocol-v1 public dispatch; the complete
   forbidden-root matrix before accepting any default/custom claim. Production Apply stays
   interlocked throughout.

## 2026-09-02 Phase 2 slice 1: durable recovery ticket published from ReleaseExact

Slice 1 of the durable recovery ticket design is implemented. `scripts/root-claims-registry-common.ps1`
gains `SealedRegistryRouteCleanupTicketPublisher` plus the recovery descriptor and per-lease snapshot
types: on `ReleaseExact` entry an immutable descriptor is snapshotted before the first release
(CaptureId, entry hashes, per-lease kind/path/location key/close state/attempt state/opaque handle
identity taken via `GetAcquiredIdentityExact` while handles are still open); the release loop marks
each attempt; on `firstError` the capture is restored OPEN, close states are refreshed, and
`AttachPublishAttemptExact` publishes
`<ControlBase>
oute-cleanup-recovery\<CaptureId>	icket.json` atomically (CreateNew temp,
WriteThrough flush, non-overwriting `File.Move`, same-CaptureId idempotent, identity-collision
fail-closed) with the seven `DurableRecoveryTicket*` keys attached to the original error and the
publish error never shadowing it; `GetCaptureIdExact` and the read-only discovery facade
`Get-SealedRegistryRouteCleanupRecoveryTicket` (schema/version/hash validation, `.tmp` ignored) were
added. `scripts/home-authority-common.ps1` extends the envelope `ControlBase` children check to an
allow-list (`route-cleanup-recovery` allowed as an optional sidecar, the original four still
required) and the bootstrap snapshot check to permit the same extra — after an out-of-repository
diagnostic proved that a plain whitelist entry would break every envelope projection and bootstrap
snapshot once a ticket existed. Discovery is discoverability only: no interpretation, consumption,
retry, deletion, or `LiveTransactionsRoot` writes; those stay with Task 4. An independent Grok
review (full-access per the updated routing rules) found and fixed a real production defect in the
new facade — `[string]$row.Path.EndsWith(...)` casts the boolean instead of the path, so every
valid ticket was skipped — then verified the focused suite end to end.

Tests: `tests/root-claims-registry.tests.ps1` adds the synthetic cleanup-capture helpers
(`New-TestSyntheticLiveReceiptLease` gains an optional `-AuthorityContext` so the ticket's
ControlBase is injected through `BindExact` rather than a reflection write) and five core blocks:
publication from the firstError branch (path/hash/CaptureId/OPEN assertions), atomic visibility
(rename barrier: final absent, discovery empty, exactly one `.tmp`; after release: exactly one
valid row), ContentHash over the canonical payload (mutation sensitivity), retry idempotence
(byte-identical single `ticket.json`), and the whitelist coupling (no `LiveTransactionsRoot`
marker, registry inventory unaffected, sidecar discoverable). Focused root-claims reached 529 PASS
lines with exit 0 (504 before this slice). `scripts/home-authority-common.ps1` and
`scripts/root-claims-registry-common.ps1` are not hard-kill-sealed; hard-kill was re-run as the
authoritative regression anyway. The seams suite re-pinned the reflection-sensitive inventory
(count 12755 → 12773, digest after the pre-commit review fixes →
`740f11712cd9f3bfc397add337b90e759ae3c3e29c59ee8d038f8b49a6b28c51`) and passed 56/0. A read-only
Grok pre-commit review raised three defects that were all adopted: the identity-collision branch
was fail-open (now a per-field needle match over every immutable identity field, mismatch failing
closed), the recovery descriptor was snapshotted after the closing CAS (now before the CAS, a
snapshot failure leaving the capture OPEN), and the rename-hold gate had no timeout (now 60 s, then
best-effort temp deletion and a `failed` publish). The focused suite was re-verified at 529 PASS
with exit 0 after those fixes.

Validation: complete hard-kill 318/0, focused root-claims 529 assertions exit 0, home-authority
PASS, path-safety PASS, seams 56/0, parse gate 156 files, build 7/15/7, secret scan clean (868
non-blocking hints), `git diff --check`, and `sync.ps1 -DryRun` with a fresh external plan path
changed no live file (plan-file SHA-256
`27ed96397e770916f860a29b61ab2b28914b0d8b192e3111bfd13cb958967ef4`, deleted after the run; an
earlier DryRun before the review fixes had plan-file SHA-256
`0378709ba89ea826a363398d23bebb56bbc2a6d2ccfc670058ed0978972990f5`). The definitive unified
`run-tests.ps1 -All` run then discovered, started, completed, and passed all 34 suites exactly once
with zero failures, timeouts, duplicates, missing suites, or tree-kill failures (external
create-new summary SHA-256
`d403207ade1a8728a434f3ebc11d9eea7e0118420573c4876d2a5dee6ea24c8a`), with hard-kill 318/0, seams
56/0, root-claims 529/0, home-authority 190/0, and path-safety 43/0 inside the run. Task 1 remains
1/6 and Phase 2 remains 1/52. Production Apply remains interlocked, and no live root or Git
index/ref was changed. Task 1 remains 1/6 and Phase 2 remains 1/52. Production Apply remains interlocked, and no
live root or Git index/ref was changed.

## 2026-09-03 Phase 2 slice A: observation lifecycle owner wired

The cleanup ledger is wired as the reviewed lifecycle owner for the observation. `scripts/root-claims-registry-common.ps1`
gains the reviewed trio `Open-/Assert-/Close-SealedHeldObservationLifecycle`:

- `Open-` verifies both caller receivers are empty and distinct, opens the ledger and the
  observation on private receivers, registers the observation, runs the observation full assert and
  the ledger assert, and only then delivers both payloads to the caller receivers. The failure
  matrix is complete: nothing is delivered on failure; a registered observation is closed through
  the ledger entry route; an unregistered one through exactly one issuer `CloseObservationExact`
  call; an empty or entry-settled ledger is closed; cleanup errors ride
  `SealedHeldObservationLifecycleCleanupError` on the primary domain exception. Following the
  pre-commit review, ledger closure is unconditional once its entry obligation is settled even when
  the ledger half was already delivered — a half-delivery can no longer leak an OPEN ledger to the
  caller (a caller receiver left holding a CLOSED ledger must be discarded; retry requires fresh
  receivers).
- `Assert-` rejects unregistered pairs, runs the observation full assert, and requires the ledger
  assert to be current.
- `Close-` closes the registered observation through the ledger entry route (which internally uses
  the reviewed `CloseObservationExact`), refuses while an entry is OPEN, then closes the ledger
  single-use.

The observation `Close-` facade retains zero production callers; the observation `Open-/Assert-`
facades and the five ledger facades now have exactly one reviewed production caller each (the
trio), enforced by the rewritten seams boundary: per-facade allowed-caller inventories, owner
inventory assertions, unique-definition coverage extended to the trio, and the issuer invocation
inventory plus owner-binding digest for the trio's single unregistered-cleanup `CloseObservationExact`
call site (digest `451449d7df35a1950c099aa0da20dc18aeaf9258666ae93ead06900e7795df17` after the
review fix). `MutationAuthorization=NONE` is unchanged; no resolver, dispatcher, registry view,
setup Apply, rollback, or live mutation consumes the trio (the four production roots' closure is
untouched). An independent read-only Grok pre-commit review returned one medium finding — the
half-delivery ledger leak — which was adopted as above, plus test-freeze suggestions partially
adopted (the missing-receiver assertion now pins the exact parameter name; the remaining freeze
alignments move to the slice B follow-up).

Tests: selector rejections for the three functions, parameter-freeze assertions (receiver types,
mandatory flags, no Action/ScriptBlock), and the success-path block (zero success-stream payload,
both receivers DELIVERED and holding, one registered OPEN entry, NONE authorization, lifecycle
assert current, close releases through the ledger entry then the ledger, single-use with all three
states CLOSED). Focused root-claims reached 546 PASS lines with exit 0 (529 before), re-verified
after the review fix. The seams suite passed 56/0 after the boundary rewrite and re-pins
(reflection-sensitive count 12773 → 12809, digest →
`2d7eb3525ad63bc7ff6292c56a74d0255059b26f9ba0430b9947b295f1dd7ea2`; binding digest
`451449d7…`; no dynamic-command, closure, or exception-inventory changes). Complete hard-kill
318/0, home-authority PASS, path-safety PASS, parse gate 156 files, build 7/15/7, secret scan
clean (869 non-blocking hints), `git diff --check`, and `sync.ps1 -DryRun` with a fresh external
plan path changed no live file (plan-file SHA-256
`59b30f633a4b61e9a4bb8e23a877ae8ca7b5782e59ea4b90c46e279d83891006`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`d8f6ef0e1bf3d359214db79c0844f806bff71bd89f2284a052b7c44818517189`), with hard-kill 318/0, seams
56/0, and root-claims 546/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52. Production
Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-03 Phase 2 slice B: lifecycle owner failure matrix

Slice B lands the owner failure matrix as suite-style regressions (the Luna Pester-style draft was
rewritten against the trio's actual interface; the draft's injection semantics were kept, its
assertion expectations aligned with the shipped fail-closed behavior — e.g. a lifecycle assert
failure surfaces as the observation stale error because the observation assert core converts any
revalidation error). Five failure paths are now pinned in `tests/root-claims-registry.tests.ps1`:

- a register failure inside the lifecycle open propagates the primary error and delivers nothing
  (both caller receivers remain EMPTY, the shadowed register was invoked);
- a lifecycle assert failure (the pinned `RouteCaptureStable` definition field injected to throw)
  surfaces as the observation stale error while the ledger, entry, and observation all stay OPEN;
- a ledger with an OPEN entry refuses its own close after an assert failure
  (`held-observation-cleanup-ledger-open-entries`);
- an entry-close failure (the pinned `FixedDirectoryClose` definition field injected to throw)
  restores the observation OPEN, keeps the entry OPEN, keeps the ledger OPEN, propagates, and
  refuses the ledger close;
- an entry-close failure publishes no `LiveTransactionsRoot` children and attaches no
  `SealedRegistryRouteCleanupError` Data key.

Focused root-claims reached 556 PASS lines with exit 0 (546 before this slice). No production file
changed; the seams suite passed 56/0 unchanged. Validation: parse gate 156 files, build 7/15/7,
secret scan clean (872 non-blocking hints), `git diff --check`, and `sync.ps1 -DryRun` with a fresh
external plan path changed no live file (plan-file SHA-256
`22fc7c597f1984801997cbcef2e0099e6325e03554b5ef6404da8152d36a49c1`, deleted after the run). The
definitive unified `run-tests.ps1 -All` run then discovered, started, completed, and passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external create-new summary SHA-256
`a7040d09f35de17d56911e4fedff4bd8d83dfee95826ea3312ba58d4e6893aae`), with hard-kill 318/0, seams
56/0, and root-claims 556/0 inside the run. Task 1 remains 1/6 and Phase 2 remains 1/52. Production
Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-03 resolver-prereq survey: PrivateRootBootstrapIntent two-layer semantics mapped

A Luna survey (read-only context preprocessing, 146 lines) plus main-agent verification mapped the
`PrivateRootBootstrapIntent` landscape. Key finding: the name carries **two shipped layers** — the
canonical setup plan's reduced intent (`PlanPayload.PrivateRootBootstrapIntent` with
`SetupIntentHash`/`ExpectedRootClaimHash`/`ExpectedSetupStateProjectionHash` DAG,
schemas/canonical-transaction-plan.schema.json:160-194, implemented by
`New-CanonicalSetupPlanPayload`/`Get-CanonicalSetupStatus` in
scripts/canonical-transaction-common.ps1:1118-1290) and the sealed home-authority full intent
(`sealed-private-root-bootstrap-intent`, scripts/home-authority-common.ps1:984-1080, with seven
ordered entries, bootstrap lock, and reviewed-prefix validation, driven by
`Complete-SealedHomeAuthorityBootstrap` :1877-1937). There is **no production adapter between the
two layers**: `Assert-SealedHomeAuthorityBootstrapContext` (:572-597) still accepts only the test
adapter, and the production resolver returns only a `PrivateRootBootstrapStatus`. The seven
identified gaps to resolver-consumer wiring are recorded (production context-to-full-intent
conversion, canonical-reduced-to-full hash binding, lock-internal no-follow recapture, ordered
bootstrap/global sequence, trio as sole caller, ticket boundary, protocol-v1 + forbidden-root
gates). The detailed survey is retained at tmp/luna-pbi-survey.md (untracked working notes).
Design authority for the full flow remains
docs/superpowers/plans/2026-08-09-live-safety-phase-2-live-transactions.md:401-405 and Step 4.
Next implementable sub-slice identified: production `AuthorityContext`-to-full-intent conversion
with the adapter-only restriction replaced by an explicit production topology check.

## 2026-09-03 Task-2 session close-out: SetupIntentHash blueprint lost, tickets routed to Task-2

Session closed with no code changes; working tree is clean at `f25513d`. Status of the open work:

- **SetupIntentHash blueprint Grok call (21:34, lost).** The Grok CLI returned `grok-exit-code--1`
  (slow first token plus caller-side abandonment), not an official outage. A rerun attempt was
  refused by the working-directory lock (`grok-already-running-for-working-directory`) because the
  original session `01a0677a-0e16-7740-bf9b-7167dd014655` was still alive; the session record and
  prompt were verified intact via `grok export`. No blueprint file was produced
  (`tmp/setup-intent-impl-blueprint.md` absent). **Rerun the same blueprint prompt at session
  resume** (prompt preserved at `tmp/grok-setupintent-impl-prompt.txt`) after confirming the lock
  is free via `grok sessions list`.
- **Luna PrivateRootBootstrapIntent survey (landed).** 146-line survey at
  `tmp/luna-pbi-survey.md` plus main-agent verification; its conclusions are already committed in
  `f25513d` (two-layer semantics: canonical reduced intent vs sealed home-authority full intent,
  no production adapter between them; seven gaps documented; next sub-slice identified as
  production `AuthorityContext`-to-full-intent conversion).
- **Whitelist coupling is committed.** The `route-cleanup-recovery` allow-list for the envelope
  `ControlBase` children check and the bootstrap-snapshot extra live in `3228a6b` (durable
  recovery ticket slice), not in a later commit; nothing pending.
- **Enqueue order for Task-2 (resolver prerequisites).** (1) Rerun+adopt the SetupIntentHash
  blueprint (hash precompute functions + schema + tests); (2) production
  `AuthorityContext`-to-full-intent conversion replacing the adapter-only restriction; (3) cross-
  layer hash binding; (4) resolver consumer layer (lifecycle trio as sole caller); (5)
  `PrivateRootBootstrapIntent` completion; (6) protocol-v1 dispatch; (7) full forbidden-root
  matrix. Production Apply stays interlocked; Task 1 remains 1/6, Phase 2 remains 1/52.

## 2026-09-04 Task-2 slice 1: SetupIntentHash precompute functions implemented

Task-2 resume item (1) is implemented. `scripts/canonical-transaction-common.ps1` gains four
pure-computation functions wired into `New-CanonicalSetupPlanPayload` with zero behavior change
(same input, same hash; the pre-existing `:1193`/`:1254` recompute checks are the regression net):

- `Get-CanonicalSetupIntentKeyNames`: dictionary-compatible key enumeration (`IDictionary.Keys`
  vs `PSObject.Properties`; a blueprint-stage probe proved `[ordered]` dictionaries expose
  `Count/Keys/...` through `PSObject`, not their entries).
- `Assert-CanonicalSetupIntentRootContext`: the schema `rootContext` oneOf state machine
  (15-key exact set; `MISSING` requires non-empty remainder with null `Final*`;
  `EXISTS` requires empty remainder with valid `Final*`).
- `Get-CanonicalSetupIntentHash`: 8-key exact intent set plus resolver/SID/hash-shape checks,
  then `Get-SemanticJsonHash`.
- `Get-CanonicalExpectedSetupStateProjectionHash`: 19-key exact projection set with the
  Apply-derived exclusion table (`*FinalContext*`, `RootClaimHash`, `SetupStateProjectionHash`)
  checked before the generic unexpected-field check so pollution gets its dedicated error,
  then `Get-SemanticJsonHash`.

No new schema file: `PrivateRootBootstrapIntent` and the projection shapes are already covered
exactly by `$defs/setupPayload` and `$defs/setupStateProjection` in
`schemas/canonical-transaction-plan.schema.json`. `tests/canonical-transaction.tests.ps1`
gains the `[setup intent precompute]` block (10 assertions: hash parity with the plan payload,
reproduction, key-order independence, OwnerSid sensitivity, missing/unexpected rejection,
`RootClaimHash`/`FinalContext` pollution rejection with the dedicated exclusion error).
Focused suite passes 55/0. The hard-kill reseal (manifest both sites, prelude block/digest 4
sites, surface, region, contract/mutation pins, self, main-try, top-execution, inventory) plus
the seams reflection re-pin (count 12809 → 12828, digest re-pinned; dynamic-command digest and
exception/issuer inventories untouched) were produced by the lingering Grok session's output found
in the working tree; the reseal diff was verified value-only (all 30 hard-kill changed lines
contain a 64-hex pin, zero non-pin lines; seams diff is exactly count+digest). Standalone
validation: hard-kill primitives 95/0, complete hard-kill 318/0, seams 56/0, transaction 55/0,
parse gate 156 files, build 7/15/7, secret scan clean (878 non-blocking hints),
`git diff --check` clean, sync DryRun plan hash
`b94ca90b872568bddeed048a959b37b40f0cd8f1d89c90936afa876a32783e2e` (unchanged, no live
mutation, `.system` preserved). Production Apply remains interlocked; Task 1 remains 1/6 and
Phase 2 remains 1/52. Next: unified `run-tests.ps1 -All` result below, then resume item (2)
production `AuthorityContext`-to-full-intent conversion.

The definitive unified `run-tests.ps1 -All` run for this slice discovered, started, completed,
and passed all 34 suites exactly once with zero failures, timeouts, duplicates, missing suites,
or tree-kill failures (external create-new summary SHA-256
`445ea5d9a937c4162c5da5f9d53c77b456c4386fef2d1a766ac093790c81236c`), with hard-kill 318/0,
seams 56/0, and transaction 55/0 inside the run. No production Apply, backup, rollback,
retirement, live-root mutation, or Git index/ref mutation was performed.

## 2026-09-04 Task-2 slice 2: production AuthorityContext-to-full-intent conversion

Task-2 resume item (2) is implemented. `Assert-SealedHomeAuthorityBootstrapContext`
(`scripts/home-authority-common.ps1:572-611`) no longer accepts only the
`sealed-home-authority-test-adapter-v1` context: a production
`windows-token-sid-known-folder-v1` context now passes through an explicit production topology
check — canonical SID shape, non-canonical rejection, and current-user binding
(`sealed-home-authority-bootstrap-token-sid-invalid/-noncanonical/-not-current-user`) —
before joining the exact same path-derivation validation the adapter already used
(`LocalAppDataRoot` normalization plus all eight derived paths, `bootstrap-path-mismatch`
unchanged). Forged resolver versions still fail closed with
`sealed-home-authority-bootstrap-context-required`. No new bypass exists: the intent payload
already binds `IdentityResolverVersion` into `IntentHash`, the intent constructor revalidates
through the same gate, and downstream snapshot/template/drift checks are untouched.
`home-authority-common.ps1` is not hard-kill-sealed, so no reviewed-load re-pin was required.

`tests/home-authority.tests.ps1` gains the `[production bootstrap context conversion]` block
(7 assertions: production resolver version carried, production context passes the gate with a
stable local root, intent construction passes the resolver gate — downstream evidence gates may
still fail closed on real-machine ACLs, which the suite asserts as legal rather than masking;
forged resolver rejected, non-current SID rejected, tampered control path rejected, intent
construction inherits the gate). Two environment-robustness fixes were needed before green:
real-machine `LocalAppData` ACLs fail the current-user-only template (asserted as legal
fail-closed), and the forged SID must stay canonical-form to reach the `not-current-user`
branch. Focused home-authority passes; live-concurrency passes with zero adapter-path
regression. The seams reflection inventory re-pinned count 12828 → 12833 with digest re-pin
(the five new member-access sites from the SID check); dynamic-command digest and
exception/issuer inventories untouched; seams 56/0. Parse gate 156 files, build 7/15/7,
secret scan clean (886 non-blocking hints), `git diff --check` clean, sync DryRun unchanged
(no live mutation, `.system` preserved). Production Apply remains interlocked; Task 1 remains
1/6 and Phase 2 remains 1/52. Next: resume item (3) cross-layer hash binding
(canonical reduced intent ↔ full sealed intent).

## 2026-09-05 Task-2 slice 3: cross-layer intent binding

Task-2 resume item (3) is implemented. `scripts/canonical-transaction-common.ps1` gains two
pure-computation functions binding the canonical reduced intent
(`PlanPayload.PrivateRootBootstrapIntent`) to the full sealed intent
(`sealed-private-root-bootstrap-intent`) on the stable quantities the design says plan and
claim bind — token SID, DACL template, and fixed remainders — with time-varying state excluded:

- `Get-CanonicalSealedDirectoryTemplateHash`: verifies the sealed directory template's stored
  `DirectorySecurityTemplateHash` reproduces the full-template hash (integrity; a tampered
  stored hash fails closed), requires `ResourceKind='Directory'`, strips `ResourceKind`, and
  hashes the remainder. An out-of-repository probe proved the stripped sealed directory
  template hash equals the canonical `Get-CanonicalCurrentUserOnlySecurityTemplate` hash
  exactly (`8e6b080f…470446c1` in the probe; both encode the same resolver constant, owner
  SID, protected DACL, and single FullControl allow rule) — the full sealed hash differs only
  by the `ResourceKind` key the canonical layer does not carry.
- `Assert-CanonicalSealedSetupIntentBinding`: token-SID binding
  (`SealedIntent.TokenSid == SetupIntent.OwnerSid`), template-hash binding through the helper,
  remainder-derived path binding (`LocalAppDataRoot` plus the two-segment control/backup
  remainders must derive exactly the canonical `ControlBaseIntent/BackupRootIntent`
  `RequestedPath`, with remainder shape rejected before derivation), per-root template-anchor
  consistency (each rootContext's `ExpectedFinalDaclTemplateHash` equals the intent's
  `SecurityTemplateHash`), and a binding-evidence projection. No FS access, no new bypass:
  callers are expected to validate payload shapes with their own layer's validator first; the
  binding fails closed independently on every tampered quantity.

`tests/canonical-transaction.tests.ps1` gains the FS-free `[cross-layer intent binding]` block
(9 assertions: legal binding with correct derived paths and equal template hashes, token-SID
mismatch, sealed stored-hash integrity mismatch, file-kind template, malformed remainder,
control-path mismatch, backup-path mismatch, drifted root anchor — focused suite 64/0).
Reseal: the `tmp/reseal-txn.ps1` N-manifest probe (dynamically re-pinning from reviewed bytes)
reached fixpoint in three iterations with 13 pin updates (manifest both sites, prelude
block/digest four sites, pre-section region, both transport-contract function pins, function
inventory, self twice, main-try, top-level execution, surface; final hard-kill file SHA-256
`ecfc68a0616a2b6afc1407c0642af277dd877f48415c6c6992d21e3207a33aba`), and the seams
reflection-sensitive inventory re-pinned count 12833 → 12858 with digest re-pin (the 25 new
member-access sites from the two functions); dynamic-command digest and exception/issuer
inventories untouched, seams 56/0. Validation: complete hard-kill 318/0, transaction 64/0,
seams 56/0, parse gate 156 files, build PASS, secret scan clean, `git diff --check` clean,
and sync DryRun with Summary identical to the established baseline (29 additions, zero
modified/removed/unknown, `.system` PRESERVED) and unchanged PlanHash
`b94ca90b872568bddeed048a959b37b40f0cd8f1d89c90936afa876a32783e2e`. Production Apply remains
interlocked; Task 1 remains 1/6 and Phase 2 remains 1/52. Next: resume item (4) resolver
consumer layer (lifecycle trio as sole caller), which consumes this binding under the
bootstrap/global lock pair.

## 2026-09-05 Task-2 slice 4 PR1: resolver observation unique caller wired

Task-2 resume item (4) PR1 is implemented per the reviewed resolver consumer design
(`tmp/grok-resolver-consumer-design.md`, produced by Grok through four review rounds; the design is
an untracked working note). `scripts/root-claims-registry-common.ps1` gains the reviewed trio
`Open-/Assert-/Close-SealedHeldResolverObservation` — the first production consumer of the
observation lifecycle trio:

- `Open-` walks the ordered sequence with `MutationAuthorization=NONE`: bootstrap lock OpenExisting
  only after the snapshot is verified COMPLETE with the full seven-entry prefix
  (`home-authority-bootstrap-incomplete` otherwise; `Complete-SealedHomeAuthorityBootstrap` is never
  called), existing-only global lock bound to the mandatory caller-held canonical witness, the
  slice-3 `Assert-CanonicalSealedSetupIntentBinding` consumed under both held locks, an in-lock
  BLOCK on any valid `route-cleanup-recovery` ticket
  (`sealed-held-resolver-unhandled-route-cleanup-recovery` with only the count and CaptureId GUID
  list in `Exception.Data`), the no-follow current-route recapture under the held locks, and the
  lifecycle trio opened on private receivers. One typed handle (exactly eleven properties,
  `AiAgentDotfiles.SealedHeldResolverObservation`, `CloseState='OPEN'`) is delivered receiver-only.
  The Open failure ladder closes the trio through the trio's own Close (the reviewed second
  production caller of trio Close), then the route capture, then the global and bootstrap locks
  tail-to-head, and never releases locks while an observation entry or route capture remains OPEN.
- `Assert-` revalidates the handle type and property set, the bootstrap-lock owner, the sealed
  intent under both held locks, the lifecycle assert, route stability, and the global/canonical
  binding, and stays OPEN on any failure.
- `Close-` is a retryable tail-to-head state machine (`OPEN|CLOSING|CLOSED`); the CLOSED no-op gate
  requires the inner observation and ledger to be CLOSED and both lock wrappers released from the
  owner table, never the NoteProperty alone, and a forged `CLOSED` display with a live observation
  is ignored.

The seams suite rewrites the lifecycle-trio boundary deliberately: each trio verb's unique
production caller is the matching resolver function, with trio Close additionally allowed from the
resolver Open failure cleanup (the slice A ledger-Close inventory shape); the resolver trio itself
is pinned at zero production callers and unique top-level registry definitions; the
reflection-sensitive inventory re-pinned count 12858 → 12955 with digest
`70356ed7f4bb0a7d0c6b9438cf3d56a56b5ced7293576d5a4767a37f4cc6cdb6` (dynamic-command, exception,
and issuer inventories unchanged). `tests/root-claims-registry.tests.ps1` extends the
selector-rejection enumeration to the three new functions, pins the exact parameter set with no
`-Action`/`-ScriptBlock`, and adds the independent-fixture success path (zero success-stream, NONE
authorization, frozen binding evidence for the current token and both fixed roots, zero tickets,
single-use close, global re-entry) plus the ticket-BLOCK failure path (exactly one valid ticket,
count+GUID Data only, empty receiver, both locks released). No hard-kill reseal:
`canonical-transaction-common.ps1` is unchanged and the four-root production closure is untouched.

Validation on 2026-09-05: focused `root-claims-registry.tests.ps1` passed with exit code 0 and 583
PASS lines (clean temp cleanup); `canonical-production-seams.tests.ps1` passed 56/0 after the
boundary rewrite and re-pin; the complete standalone `canonical-hard-kill.tests.ps1` passed 318/0
on a quiet re-run after one environment-flaky run whose fourteen failures (transient
fixture-delete contention under concurrent machine load) did not reproduce and are recorded as
non-code; the parse gate accepted all scripts; `build-skills.ps1` produced 7/15/7; the pinned
secret scan found no blocking findings (907 non-blocking hints); `git diff --check` was clean; and
`sync.ps1 -DryRun` with a fresh external plan path reported the established baseline (Claude +7,
Codex +15, Reasonix +7, zero modified/removed/unknown, `.system` preserved) with unchanged PlanHash
`b94ca90b872568bddeed048a959b37b40f0cd8f1d89c90936afa876a32783e2e`, deleting the plan file after
the run. The definitive unified `run-tests.ps1 -All` run for this state executes after the PR2/PR3
test slices land. Task 1 remains 1/6 and Phase 2 remains 1/52. Production Apply remains
interlocked, and no live root or Git index/ref was changed.

## 2026-09-05 Task-2 slice 4 PR2+PR3: resolver observation failure matrix, close state, and contention

Task-2 resume item (4) PR2+PR3 land as suite-style regressions in
`tests/root-claims-registry.tests.ps1` only (commit `28ce839`), from the Grok implementation draft
completed by the main agent after the Grok session was lost mid-verification. The shared
`New-TestResolverObservationAdapter`/`Close-TestResolverObservationAdapter` helpers build
independent COMPLETE fixtures (registry fixture + canonical claim + setup state + repo lock +
namespace witness + two external ProbeRoots):

- `[resolver observation failure matrix]`: a forged AuthorityContext resolver version fails with
  `sealed-home-authority-bootstrap-context-required` and zero locks; removing the final global-lock
  prefix entry makes the pre-lock COMPLETE check fire `home-authority-bootstrap-incomplete` with
  zero re-creation and an unchanged tree hash (the incomplete variant reuses a standard fixture
  because `New-CanonicalFinalSetupState` requires existing private roots); a tampered SetupIntent
  OwnerSid fails `canonical-sealed-intent-token-sid-mismatch` after both locks with the locks
  released; and an in-lock recapture identity drift on a candidate workspace root fails closed.
- `[resolver observation close-state machine]`: an injected
  `Close-SealedHeldObservationCleanupLedgerObservation` failure keeps CloseState OPEN, the route
  capture open, and both lock wrappers held, and a retry after removing the injection succeeds; the
  same contract holds for an injected `Close-SealedRegistryCurrentRouteCapture` failure; a forged
  `CloseState='CLOSED'` NoteProperty with a live observation is ignored and the real close
  completes; and the canonical-early-release case pins that Close fails closed, bootstrap and
  global stay held, and the canonical repo lock itself refuses release with `dependent-lock-active`
  while the stranded global lock holds its order binding — bootstrap, global, and the canonical
  lock remain held until process exit, recorded by the suite as an expected stranded residue rather
  than a cleanup failure.
- `[resolver observation real contention]`: a child runscape loading the registry independently
  loses with `operation-lock-busy` in under one second with an empty receiver, and re-enters the
  global lock after the parent Close.

The final cleanup gate narrows the expected stranded residue to the canonical-early fixture's own
lock paths; any other removal failure still throws. No production file changed, so no seams or
hard-kill re-pin was required.

Validation on 2026-09-05: the full `root-claims-registry.tests.ps1` suite passed with exit code 0
and 614 PASS lines (583 before this slice); `canonical-production-seams.tests.ps1` passed 56/0
unchanged; `git diff --check` was clean. The definitive unified `run-tests.ps1 -All` run for commit
`28ce839` then discovered, started, completed, and passed all 34 suites exactly once with zero
failures, timeouts, duplicates, missing suites, or tree-kill failures (external create-new summary
SHA-256
`5b42e119b72cb9fa91b6795da75a081415636344562ec283fdd1ff77be522474`). Inside the run
`canonical-hard-kill.tests.ps1` passed 318/0, `canonical-production-seams.tests.ps1` passed 56/0,
and `canonical-transaction.tests.ps1` passed 64/0. This definitive run is also the recorded unified
validation for the earlier Task-2 slice 2 (production AuthorityContext-to-full-intent conversion)
and slice 3 (cross-layer intent binding) states, whose focused validation was recorded at the time
with the unified run pending. No production Apply, backup, rollback, retirement, live-root
mutation, or Git index/ref mutation was performed. Task 1 remains 1/6 and Phase 2 remains 1/52.
Production Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-05 Task-2 slice 5: PrivateRootBootstrapIntent completion primitives (interlock preserved)

Task-2 resume item (5) is implemented per the reviewed completion design
(`tmp/grok-pbi-completion-design.md`, Grok, two review rounds; an untracked working note) in two
commits, without lifting any interlock: completion stays a `CanonicalOperationKind=setup` Apply
component covered by `canonical-apply-interlocked`, and both new primitives keep zero production
callers.

- PR1 (commit `2bd40a6`): `scripts/home-authority-common.ps1` gains
  `Register-SealedHeldHomeAuthorityCanonicalGlobalBinding` — an already-held bind of a held
  `HomeAuthorityLockHandle` global to a live canonical witness. It refuses an existing order
  binding (`canonical-global-order-binding-already-present`), captures the witness through
  `Assert-HomeAuthorityRequiredCanonicalWitness`, revalidates the capture, opens the fixed envelope
  with `-HeldGlobalLock`, requires envelope-hash stability, supplies a missing `FixedEnvelopeHash`
  on the CreateNew Complete path or verifies it on the OpenExisting path, and completes the same
  `ClaimForBindingExact`/`BindExact` and wrapper NoteProperty sequence as
  `Enter-HomeAuthorityGlobalLiveLock`, failing closed without exiting the global.
  `Complete-SealedHomeAuthorityBootstrap` and `Enter` are unchanged (the KD2 return contract stays
  unbound-global plus always-Exit-bootstrap). `tests/home-authority.tests.ps1` gains the
  `[canonical-bound bind after complete]` block on the test binding witness stub covering the
  CreateNew path, the already-bound refusal, and the OpenExisting path of an idempotent Complete of
  the same fresh fixture, with the canonical repo lock acquired before every global acquisition so
  the lock-order prerequisite holds; the selector-rejection list gained the new function. The seams
  reflection-sensitive inventory re-pinned count 12955 -> 12978, digest `137134fb...`. Validation:
  home-authority suite PASS, live-concurrency PASS, seams 56/0.
- PR2+PR3 (commit `fc039a9`): `scripts/root-claims-registry-common.ps1` gains
  `Complete-SealedHeldCanonicalRecoveryRootRemainder` and
  `Complete-SealedHeldCanonicalPrivateRootBootstrap` — the first-run composition primitive that
  consumes the slice-3 cross-layer binding and the plan payload graph before any create (full
  projection/intent/claim hash chain, repository identity, current-user-only template,
  remainder-derived path equality against the projection and the authority context), then completes
  the seven-entry prefix through the unchanged `Complete-SealedHomeAuthorityBootstrap`, creates or
  validates the canonical recovery root remainder under the still-held unbound global using the
  sealed directory template (plan-MISSING roots may already exist; plan-EXISTS roots must exist;
  collision 80/183 is `canonical-recovery-root-remainder-collision`; topology drift is
  manual-recovery), computes the in-memory final setup state, and returns a thirteen-property typed
  result (`AiAgentDotfiles.SealedHeldCanonicalPrivateRootCompletion`) whose global lock is unbound
  and whose durable claim and setup-state writes are explicitly `deferred`. No Register call, no
  witness, no durable artifact. The seams suite pins bootstrap Complete and the recovery remainder
  to the composer as their unique production callers, pins the composer and Register at zero
  external production callers, pins all three completion definitions uniquely, and re-pins the
  reflection-sensitive inventory (count 12978 -> 13057, digest `91b47e9c...`).
  `tests/root-claims-registry.tests.ps1` gains the completion success path, the
  binding-before-create and payload-graph-before-create zero-creation failures, selector and
  parameter-shape rejections, the exact partial-prefix resume with identity preservation, the
  idempotent COMPLETE variant (`RecoveryCreated=$false`), the drifted-ACL manual-recovery gate, and
  the child-runscape `operation-lock-busy` contention probe. No hard-kill reseal:
  `canonical-transaction-common.ps1` is unchanged and the four-root closure is untouched.

Validation on 2026-09-05: the full `root-claims-registry.tests.ps1` suite passed with exit code 0
and 642 PASS lines (614 before this slice); `canonical-production-seams.tests.ps1` passed 56/0
after the re-pins; `tests/home-authority.tests.ps1` and `tests/live-concurrency.tests.ps1` passed;
`git diff --check` and the parse gate were clean.

An independent read-only Grok review of both commits (invoked with the diffs inlined and terminal
commands disabled after two cancelled attempts demonstrated that plan-mode terminal calls are
auto-cancelled) returned three major and three minor findings, all adopted as commit `43fa08a`:

- The composer's payload-graph step now pins the plan projection's `CanonicalRecoveryRoot` to the
  sealed intent's `CanonicalRecoveryRootIntent.RequestedPath`
  (`canonical-private-root-completion-recovery-path-mismatch`), closing the path-drift gap between
  the overlap precheck, the remainder mkdir, and the final-state projection.
- The recovery remainder now validates the plan-EXISTS/plan-MISSING state matrix with explicit
  directory-type and named-stream checks on the recovery root and wraps every validation failure
  into the `canonical-recovery-root-manual-recovery-required` family with the innermost exception
  message, instead of leaking raw inner tokens or accepting an ADS-bearing root.
- `tests/root-claims-registry.tests.ps1` adds the `[canonical private-root completion remainder
  fail-closed]` block (plan-EXISTS root disappearing, a file at the planned root, a named stream on
  the root, a drifted root DACL) plus the remainder parameter-shape freeze; the seams
  reflection-sensitive inventory re-pinned count 13057 → 13077, digest `7fdcb874…`.
- Recorded deviations: the design's OwnerSid binding negative is unreachable because the
  payload-graph current-user-only template check precedes the binding, so the control-path-drift
  variant pins that boundary instead; the durable-claim-absent surface is covered by the final
  reviewed-prefix snapshot, which rejects unexpected children under every authority root; the
  resolver COMPLETE-only contract is already pinned by the slice-4 incomplete-prefix block.

Validation after the review fixes: the full `root-claims-registry.tests.ps1` suite passed with exit
code 0 and 646 PASS lines; `canonical-production-seams.tests.ps1` passed 56/0 after the re-pin;
`git diff --check` was clean. The definitive unified `run-tests.ps1 -All` run for commit `43fa08a`
then discovered, started, completed, and passed all 34 suites exactly once with zero failures,
timeouts, duplicates, missing suites, or tree-kill failures (external create-new summary SHA-256
`248319e3823b79d96b1faddb905ecb52227e749a6db0db4f23ca071eab88977c`), with `canonical-hard-kill.tests.ps1`
at 318/0 and `canonical-production-seams.tests.ps1` at 56/0 inside the run. No production Apply,
backup, rollback, retirement, live-root mutation, or Git index/ref mutation was performed. Task 1
remains 1/6 and Phase 2 remains 1/52. Production Apply remains interlocked, and no live root or Git
index/ref was changed.

## 2026-09-06 Task-2 item (6) resolution: protocol-v1 public dispatch is deferred/blocked

Task-2 resume item (6) was surveyed and designed by Grok (evidence report at
`tmp/grok-protocolv1-design.md`, one review round, zero open issues) and the conclusion is
**deferred/blocked: nothing to build**. The design authorities define "protocol v1 public dispatch"
as the locked production CLI contract (reject public `-HomeRoot`/`-BackupRoot`/`-LockWaitSeconds`,
zero-wait with `operation-lock-busy`, Fixed/NTFS gate, setup Apply journaling claim then state,
later `live recover`) — not a dispatch schema and not a new public surface. Its only consumers are
the setup Apply (currently `canonical-apply-interlocked` / exit 75) and the planned Task 6 Step 3
`live recover` dispatcher (blocked on the Task 4 journal contract, which does not exist yet), so no
slice can be built without either inventing a zero-caller facade or lifting the interlock — both
explicitly rejected. The read-only public dispatch already exists (`canonical status`, canonical
recover status, env status; all MetadataOnly) and its contract forbids consuming the resolver
(COMPLETE-prefix plus a setup-state-bearing witness would break status on MISSING setups).
Naming axes are separated: "protocol v1" is the CLI/lock/selector contract, `ProtocolVersion=3`
with `ReleaseState=interlocked` is the Phase 0 policy axis (scripts/live-safety-policy.psd1), the
artifact `SchemaVersion` fields are another axis, and the `ProtocolVersion=1` in
scripts/target-context-common.ps1:883 is a filesystem-capability probe field. Known selector debt
(`sync.ps1 -HomeRoot/-BackupRoot` defaults to USERPROFILE) is live-host/plan Task 5 migration work,
not a dispatch consumption layer, and is recorded here without being silently absorbed. No code,
schema, or CLI change was made for this item; the item closes as deferred/blocked with the design
authority evidence, pending a legally released interlock (which would reopen D1/D2 wiring first).

## 2026-09-06 Task-2 item (7): claim-accept forbidden-root matrix helper

Task-2 resume item (7) is implemented per the reviewed forbidden-root design
(`tmp/grok-forbidden-root-design.md`, review revision 1; the Grok session died mid-loop after
incorporating one review round and the main agent completed the design and implementation).
`scripts/root-claims-registry-common.ps1` gains `Assert-SealedProposedClaimsForbiddenRootMatrix` —
the claim-accept gate (plan Task 1 Step 3) that runs before any default/custom claim is accepted,
with zero production callers and `MutationAuthorization=NONE`:

- The gate enforces the 0-or-3 ordered live subjects contract and runs the M13 path-safety track
  per subject (`Resolve-TargetContext -HomeRoot`: HomeRoot equality, volume root, `.system`,
  reparse ancestor — wrapped into `manual-recovery-required`).
- Every opponent is coerced to a no-follow `TargetContext` (ControlBase/BackupRoot, the witness's
  four Git-private paths as disjoint opponents only, PRESENT optional root-set rows, non-own
  reservations), the exact isOwn root-transition contract is copied from the current-route capture
  (owner+platform+kind match, location/path identity, `DirectoryIdentity` only when present,
  `root-transition-not-supported` unwrapped), and subjects-x-subjects plus subjects-x-opponents
  disjoint runs with `forbidden-root-path-overlap` / `forbidden-root-identity-alias` tokens wrapped
  into the `manual-recovery-required` family. Opponent pairs and source/materialization invariants
  stay in the current-route gate by design (KD8); the Git-private opponents are never paired with
  each other.
- M11 enforces the same-parent same-volume staging-sibling rule with zero-live PRESENT staging
  failing closed (`live-mutation-staging-not-sibling`); the defensive M12 staging-x-RepoRoot pair
  is retained; recovery subjects require a canonical witness and wrap
  `canonical-recovery-root-cross-volume`.
- The implementation is ordered so the zero-subjects contract check follows the staging gathering
  (a PRESENT staging row with zero live subjects is the staging failure, not the empty-subjects
  failure), and the platform-order check skips anonymous (bare TargetContext) entries.

`tests/root-claims-registry.tests.ps1` gains the `[forbidden-root claim-accept matrix]` block:
default-claim pass with zero writes, custom overlap with ControlBase, contract shape rejections,
pairwise nesting, the four M13 bans, foreign home and canonical-recovery reservation overlaps
(foreign authorities claiming the proposed directories), identical own reservation passing without
a transition rejection, root-transition rejection, witnessed-repo live overlap, writable-sibling
recovery pass, recovery-in-repo and recovery-over-ControlBase failures, missing-witness failure,
cross-volume recovery (second fixed volume present on this host), staging sibling pass, zero-live
staging failure, detached-staging failure, and adapter cleanup. The seams suite pins the helper at
zero production callers and unique registry-top definition and re-pins the reflection-sensitive
inventory (count 13077 → 13143, digest `e3292903…`). No hard-kill reseal:
`canonical-transaction-common.ps1` is unchanged and the four-root closure is untouched.

Recorded deviations from the design: the design's "staging root inside the witnessed repo" M12
negative is geometrically unreachable once the M11 sibling rule and the M2 live-x-RepoRoot rule
both hold (a staging sibling shares its live root's parent, which M2 keeps outside the repo), so
the M12 pair is retained in the helper as a defensive check without a dedicated negative test; and
the design's OwnerSid binding negative from the earlier slice remains recorded with the same
rationale.

Validation on 2026-09-06: the full `root-claims-registry.tests.ps1` suite passed with exit code 0
and 672 PASS lines (646 before this slice); `canonical-production-seams.tests.ps1` passed 56/0
after the re-pin; `git diff --check` and the parse gate were clean. The definitive unified
`run-tests.ps1 -All` run for commit `1e6acfc` then discovered, started, completed, and passed all
34 suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill
failures (external create-new summary SHA-256
`77374bdd2e9e918b05d10d4f3e7f8225da470035a07567d92def84f61407b924`), with `canonical-hard-kill.tests.ps1`
at 318/0, `canonical-production-seams.tests.ps1` at 56/0, and `canonical-transaction.tests.ps1` at
64/0 inside the run. No production Apply, backup, rollback, retirement, live-root mutation, or Git
index/ref mutation was performed. Task 1 remains 1/6 and Phase 2 remains 1/52. Production Apply
remains interlocked, and no live root or Git index/ref was changed. With this slice, Task-2 resume
items (1)-(7) are all closed: (1)-(5) and (7) implemented with definitive validation, (6)
deferred/blocked with evidence. The remaining Task-1 Step 2 debt stays as recorded (durable
recovery ticket consumption/interpretation belongs to Task 4), and the next implementable work is
the Phase 2 plan's Task 1 Step 3 onward.

## 2026-09-06 Phase 2 Task 1 Step 2 closure

Task 1 Step 2 (Resolve ControlBase and HomeAuthorityKey) is closed. The closure is evidence-based
(per-clause function and test anchors verified in the tree), not a scope change:

- The Windows Known-Folder identity resolver (`Get-WindowsHomeAuthorityIdentity`,
  `Resolve-HomeAuthorityContextFromIdentity`) derives ControlBase/BackupRoot from the access-token
  SID plus `FOLDERID_LocalAppData` and never reads `USERPROFILE`/`APPDATA`/`LOCALAPPDATA`; the
  non-Windows path throws `live-safety-non-windows-interlocked` and tracked policy remains
  `ReleaseState=interlocked`.
- The pre-ControlBase bootstrap lock is derived from SID/location/domain under the already-existing
  Known Folder (`Enter-SealedHomeAuthorityBootstrapLock`), and MetadataOnly status creates neither
  the bootstrap lock nor private roots.
- `PrivateRootBootstrapIntent` exists as two bound layers: the canonical `$defs/setupPayload`
  precompute (`Get-CanonicalSetupIntentHash`, `Get-CanonicalExpectedSetupStateProjectionHash`,
  `Assert-CanonicalSetupIntentRootContext`) and the sealed seven-slot intent
  (`New-SealedHomeAuthorityBootstrapIntent`), joined by `Assert-CanonicalSealedSetupIntentBinding`.
- The bootstrap completion chain (`Complete-SealedHomeAuthorityBootstrap`,
  `Register-SealedHeldHomeAuthorityCanonicalGlobalBinding`, and the composer
  `Complete-SealedHeldCanonicalPrivateRootBootstrap` with
  `Complete-SealedHeldCanonicalRecoveryRootRemainder`) implements the exact-prefix create/validate
  path with durable claim and setup-state writes explicitly `deferred`; no live/receipt/journal work
  precedes the global lock.
- FilesystemCapabilityHash evidence layers are implemented (per-target/per-volume preflight,
  fixed-infrastructure same-lock capture, receiver-backed held-route observation, the cleanup ledger,
  the lifecycle owner trio, and the resolver observation consumer); the read-only registry view
  continues to report `HELD_METADATA_VERIFIED` / `UNPROBED_READ_ONLY`.
- Public `-HomeRoot`/`-BackupRoot`/`-LockWaitSeconds`/`-TestMode` selectors are rejected across the
  authority/registry/resolver surfaces; `HomeAuthorityKey` is derived from token SID plus HomeRoot
  location key only.

The step's Apply sentence is held by the Phase 0 policy gate (`canonical-apply-interlocked` /
exit 75), not by a missing primitive; the completion composer and Register remain zero-external-
caller primitives pending Step 5 D1/D2. Recorded remainders owned elsewhere: durable recovery
ticket consumption/interpretation (Task 4), public selector defaults in the sync/backup/env scripts
(Task 5 live-host migration), protocol-v1 public dispatch (deferred/blocked with design evidence at
`tmp/grok-protocolv1-design.md`), and production capability-capture consumption (Apply release). A
recorded vocabulary difference: the step text says remainders are `MISSING|COMPLETE`, the canonical
`$defs/rootContext` uses `MISSING|EXISTS`, and the sealed seven-slot intent uses `MISSING|COMPLETE`;
the cross-layer binding pins token SID, DACL template, and remainder-derived paths, so no clause is
relaxed. The design-authority evidence for this closure is retained at
`tmp/grok-step3-registry-design.md` §0. With this closure, Task 1 is 2/6 and Phase 2 is 2/52. The
next implementable work is Step 3 (Build the registry view), designed in four slices per the same
document (live-namespace child contract, setup-finalize window, claim-accept consumer,
TransactionId create-new). Production Apply remains interlocked, and no live root or Git index/ref
was changed.

## 2026-09-06 Phase 2 Task 1 Step 3 slice 1: live-namespace child contract

Per the reviewed four-slice Step 3 design (`tmp/grok-step3-registry-design.md`, Grok), slice 1 is
implemented in commit `8ab102f`:

- `scripts/root-claims-registry-common.ps1` gains
  `Assert-SealedLiveTransactionNamespaceImmediateChildren` (mandatory
  TransactionId/ImmediateChildren/AllowedEntries; a noncanonical id throws
  `live-transaction-namespace-id-invalid`, any child outside the reviewed allow table throws
  `live-transaction-namespace-child-not-allowed`, both wrapped into the
  `home-authority-registry-manual-recovery-required:` family by the view's catch) and
  `Assert-SealedRegistryReservationSetsDisjoint` (the claims-only run against
  ControlBase+BackupRoot, plus, when live rows exist, the extended claims+live run against
  BackupRoot only). The V1 allow table `$script:SealedLiveTransactionAllowedEntriesV1` ships
  empty: Task 4 owns the journal contract, so any published child of a live transaction directory
  fails closed while an empty UUID directory remains `RECOVERY_REQUIRED` /
  `UNRESOLVED_UNTIL_TASK_4`.
- `Get-SealedHomeAuthorityRegistryView` now asserts the child contract inside the live loop,
  derives each transaction's canonical path projection and volume-prefixed identity (format
  asserted before extraction), and adds one ordered `live-transaction-namespace` reservation row
  per UUID directory (Role `LiveTransactionRoot`, parent bound to the LiveTransactionsRoot
  location/identity). The projection `RootReservations` includes the live rows; the current-route
  capture input stays claims-only by design (slice 3's claim-accept consumer must consume the
  live rows).
- Recorded design deviation (confirmed correct by the independent Grok review): the design's
  single extended `Assert-SealedRegistryReservationsDisjoint` call is impossible because
  `Test-TargetPathOverlap` is a bidirectional containment check and every legitimate transaction
  directory is inside ControlBase, so the fixed-infrastructure forbidden check is split — claims
  keep both forbidden roots, the extended run uses BackupRoot only, and both run inside one
  helper with the view as its unique production caller.
- Recorded token deviation: the view-level identity-collision negative (a contract-legal home
  claim carrying the transaction directory's real identity) fires the single-row
  `registry directory identity aliases multiple locations` token rather than the pairwise
  `registry reserved root identities collide` token; the aliasing check precedes the pairwise
  loop and is equally exclusive to the extended run.

Tests: `tests/root-claims-registry.tests.ps1` gains 19 assertions (672 → 691 PASS): the V1 table
pinned empty; the empty-UUID fixture's reservation row pinned on
path/location/parent/volume/identity; a stray file, a pre-filled `header.json`, and a stray child
directory each failing closed as `live-transaction-namespace-child-not-allowed`; a two-UUID
fixture sharing one LiveTransactionsRoot parent binding; home claims coexisting with an empty
live namespace in `RootReservations`; the view-level identity-aliasing negative; direct unit
rejections for a noncanonical id and an off-table child; and the synthetic path-nesting negative
proving the extended set rejects a transaction nested inside a canonical recovery root. The seams
suite pins both new functions as uniquely defined with the view as their unique production caller
and re-pins the reflection-sensitive inventory (count 13143 → 13156, digest
`fb90c6fe962dda813b5d22958eaf2f444cfb5893aa4f1a8b1ffdcbdca1688ffd`).

Validation on 2026-09-06: the parse gate accepted all 156 files;
`canonical-production-seams.tests.ps1` passed 56/0 after the re-pin; the full
`root-claims-registry.tests.ps1` suite passed with exit code 0 and 691 PASS lines (672 before);
`git diff --check` was clean. An independent read-only Grok review of the diff returned
NEEDS-FIX with zero P0s and one P1; all findings were adopted in the committed bytes (the helper
extraction, the identity-format assertion before volume extraction, the V1-table pin, the
parent-binding assertions, the two-UUID and claims-plus-namespace view positives, the
journal-shaped `header.json` negative, and the two view-level/synthetic negatives that lock the
extended disjoint run). The definitive unified `run-tests.ps1 -All` run for this slice has not
been executed yet and remains pending. No production Apply, backup, rollback, retirement,
live-root mutation, or Git index/ref mutation was performed. Production Apply remains interlocked.

## 2026-09-06 Phase 2 Task 1 Step 3 slice 2: setup-finalize window and public token

Per the same four-slice design, slice 2 (the G4/G5 `setup-finalize-required` semantics) is
implemented in commit `45b9510` without touching the sealed `Get-CanonicalSetupStatus`:

- `scripts/root-claims-registry-common.ps1` gains `Get-SealedRegistryCanonicalSetupWindow` — the
  read-only setup-window classification primitive: without a caller-held canonical locator it
  returns `UNRESOLVED`; with a locator (`{RepoRoot, CanonicalRepoLockHandle}`, validated through
  `Assert-CanonicalRepoLockHandle` against the derived contract paths) it binds the claim document
  to the authority token SID via `OwnerSid`, the Git common directory hash, and the repo id, then
  classifies the setup-state path. An absent state with zero unfinished canonical transactions
  returns `SETUP_FINALIZE_REQUIRED` with the public `setup-finalize-required` token; a present
  leaf state returns `PRESENT` and leaves the witnessed binding path unchanged; a non-leaf state
  path, an unreadable canonical journal, or any unfinished canonical transaction throws the bare
  `canonical-root-transition-not-supported` token. The function has zero production callers and
  joins the seams zero-external-caller list with a unique top-level definition.
- Recorded design deviation (accepted by the independent Grok review): the design's view wiring
  for the window function is unreachable — the sealed witness evidence requires a setup-state
  capture and zero unfinished transactions, so a witnessed claim can never present a missing
  state; the window stays a zero-caller primitive for the Step 5 D1/D2 consumers, and the
  design's "unfinished with recovery classification=finalize" refinement belongs to the
  recover-finalize Apply consumer (G8, not this slice), so unfinished transactions fail closed
  here.
- `scripts/canonical-command-result.ps1` gains `Test-CanonicalSetupFinalizeClaimPresence` (pins
  the repo id to the 64-hex shape before path composition) and
  `Resolve-CanonicalSetupFinalizePublicToken` (only `canonical-setup-required` can promote to
  `setup-finalize-required`). `scripts/setup-canonical-transaction.ps1` now routes both public
  branches through the resolver: Status emits `setup-finalize-required` as WARN with exit 0 when
  `ControlBase/canonical-roots/<repoId>.json` exists, and Apply writes a FAIL command result plus
  the exact stderr token with exit 1 without spawning the engine; any selection or probe error
  falls back to the previous behavior (status token unchanged, Apply spawns the interlocked
  engine).
- Tests: `tests/root-claims-registry.tests.ps1` gains the `[registry setup-finalize window]`
  block (11 assertions: unresolved without a locator, malformed-locator rejection, the
  finalize-window classification under a held locator, forged-`OwnerSid`/other-repo/repo-id
  binding rejections, the unreadable-journal fail-closed path, the PRESENT classification after
  the setup state is written, and the claim-presence probe on a fake ControlBase);
  `tests/canonical-command-result.tests.ps1` gains the `[setup finalize public token]` block
  (5 assertions over the resolver: pass-through, absence, noncanonical repo id, exact-claim
  promotion, foreign repo id). The seams suite re-pinned the reflection-sensitive inventory
  (count 13156 → 13180, digest
  `ad5022ab7e62daf6678e79dbe8ad559adc0d9d04f4f9f60b1b5859b1cca5dfb6`).

Validation on 2026-09-06: the parse gate accepted all 156 files;
`canonical-production-seams.tests.ps1` passed 56/0 after the re-pin; the full
`root-claims-registry.tests.ps1` suite passed with exit code 0 and 702 PASS lines (691 before);
`tests/canonical-command-result.tests.ps1` passed 51/0 (46 before); `git diff --check` was clean.
An independent read-only Grok review of the diff returned one P0, two P1s, and two P2s; all were
adopted in the committed bytes (the P0: the window originally bound the claim's `TokenSid`, which
the canonical-root-claim v1 schema does not carry — it now binds `OwnerSid` and a forged-OwnerSid
negative was added; the P1s: the shared `Resolve-CanonicalSetupFinalizePublicToken` helper with
command-result suite coverage, and the fail-closed journal path test; the P2s: the repo-id shape
pin in the probe and the leaf-state discipline). All four recorded deviations were accepted. The
real-ControlBase positive for the status/Apply wrapper is documented as untestable without a
claim file only a real interlocked Apply could produce. The definitive unified
`run-tests.ps1 -All` run for slices 1-2 has not been executed yet and remains pending. No
production Apply, backup, rollback, retirement, live-root mutation, or Git index/ref mutation was
performed. Production Apply remains interlocked.

## 2026-09-06 Phase 2 Task 1 Step 3 slice 3: claim-accept consumer of the forbidden-root matrix

Per the same four-slice design, slice 3 (G6) is implemented in commit `744f326`:

- `scripts/root-claims-registry-common.ps1` gains `Assert-SealedRegistryClaimAccept` — the
  claim-accept gate a future first-authority writer calls before accepting any default/custom
  claim. It is the unique production CommandAst caller of
  `Assert-SealedProposedClaimsForbiddenRootMatrix` (item 7's helper, whose own contract is
  unchanged), then splits `$ExistingReservations` by `SourceKind` and runs
  `Assert-SealedRegistryReservationSetsDisjoint` so ControlBase-resident
  `live-transaction-namespace` rows flow through the live-kind run instead of failing the
  claims-only forbidden check. The consumer has zero external production callers (Step 5 D2's
  writer becomes its caller) and the matrix's blanket CommandAst prohibition was rewritten into
  the unique-caller pattern; the disjoint helper's owner inventory now admits exactly the view
  and the claim-accept consumer. The seams reflection-sensitive inventory re-pinned to count
  13185 / digest `8a2d2272fa2b728b1a3ab0c5c8b6924b1b4c33e65b855af6601398e6fd4feed2`.
- `tests/root-claims-registry.tests.ps1` gains the `[claim-accept unique consumer]` block on a
  fresh fixture (702 → 708 PASS): the default three-platform claim passes with zero writes; a
  ControlBase-overlapping custom live target fails through the consumer with the exact matrix
  token; a real `live-transaction-namespace` reservation row is consumed as a live-kind row with
  zero writes; a live namespace nested inside a canonical recovery reservation fails the extended
  disjoint run; and the exact parameter set is frozen with no public root or lock selectors.

Review provenance for this slice, recorded honestly: two read-only review attempts died to the
known plan-mode terminal-cancellation defect, and a third full-access attempt reached its turn
budget without publishing a verdict — but that session applied the mandatory-parameter default fix
(omitted `$ProposedLiveTargets`/`$ExistingReservations` bound `$null` into the matrix's null
rejection) and added the two consumer-routing coverage cases directly in the working tree. The
main agent reviewed all three files' diffs line by line (seams changes were entirely the main
agent's), adopted the registry and test changes as reviewed above, and no other foreign edits
existed. Validation on 2026-09-06: the parse gate accepted all 156 files;
`canonical-production-seams.tests.ps1` passed 56/0 without a further baseline shift; the full
`root-claims-registry.tests.ps1` suite passed with exit code 0 and 708 PASS lines (702 before);
`git diff --check` was clean. The definitive unified `run-tests.ps1 -All` run for slices 1-3 has
not been executed yet and remains pending. No production Apply, backup, rollback, retirement,
live-root mutation, or Git index/ref mutation was performed. Production Apply remains interlocked.

## 2026-09-06 Phase 2 Task 1 Step 3 slice 4: live TransactionId create-new primitive

Per the same four-slice design, slice 4 (G1/G2 create-new) is implemented in commit `c107ab8`,
completing all four Step 3 slices:

- `scripts/root-claims-registry-common.ps1` gains `New-SealedHeldLiveTransactionNamespace` — the
  zero-production-caller mint primitive. It requires the genuine held global lock witness
  (optionally revalidating a supplied canonical witness through the canonical-to-global binding),
  opens the held containment chain over `LiveTransactionsRoot`, mints a normalized lowercase
  D-format UUID after the locks are held, creates the child directory create-new with the
  current-user-only directory security descriptor
  (`live-transaction-namespace-must-be-create-new` on native 80/183), and returns
  `{TransactionId, DirectoryIdentity}`. It writes no header, no journal, and no reservation
  record; the empty V1 immediate-child contract applies to the created directory exactly as to
  any other live transaction directory. The 80/183 collision branch is defensive and untestable
  without Guid injection (recorded, mirroring the M12 precedent); the same primitive call shape
  is exercised by the composer's remainder tests.
- The seams suite adds the mint to the zero-external-caller blanket list and the unique-definition
  inventory, re-pinning the reflection-sensitive inventory to count 13199 / digest
  `66e7a9146b890dfec49be254ed91577ea31067551d5e1ea011d820b22c68d38b`.
- `tests/root-claims-registry.tests.ps1` gains the `[live-transaction create-new]` block
  (708 → 713 PASS): a held-lock mint returns a canonical lowercase UUID with a real created
  directory identity matching the created child; a second held-lock mint creates a distinct
  namespace; a released genuine global lock fails the mint closed.

Validation on 2026-09-06: the parse gate accepted all 156 files;
`canonical-production-seams.tests.ps1` passed 56/0 after the re-pin; the full
`root-claims-registry.tests.ps1` suite passed with exit code 0 and 713 PASS lines (708 before);
`git diff --check` was clean. This closes all four Step 3 slices from the reviewed design:
slice 1 `8ab102f` (live-namespace child contract and ordered reservation rows), slice 2 `45b9510`
(the setup-finalize window primitive and the status/Apply public token), slice 3 `744f326` (the
claim-accept consumer of the forbidden-root matrix), and slice 4 `c107ab8` (the TransactionId
create-new primitive). The authoritative unified `run-tests.ps1 -All` run for the Step 3 state
has not been executed yet and remains pending before Task 1 Step 3 is declared complete. No
production Apply, backup, rollback, retirement, live-root mutation, or Git index/ref mutation was
performed. Production Apply remains interlocked.

## 2026-09-07 Step 3 unified-validation interlude: secret-gate finding fixed, authoritative rerun in flight

The first unified `run-tests.ps1 -All` run for the Step 3 state (over commit `774b5e3`) passed
all 34 suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill
failures (external create-new summary SHA-256
`72b204171ee2eda45f47cfc2e20f71b35577b5a7bc507f74e4bd3bc69d5afc8b`, discovery hash
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`; hard-kill 318/0, seams 56/0,
root-claims 713/0, transaction 64/0, command-result 51/0 inside the run). The unified runner does
not include the filtered secret scan, and the separate gate then caught one real
`quoted-secret-value` finding introduced by slice 2: the window function assigned the quoted
`setup-finalize-required` literal directly after the `MessageToken=` key (and after a
`*Token`-suffixed variable in the first fix attempt), which the pinned gitleaks rule treats as a
secret-shaped assignment. The scan gate was not weakened or bypassed; the fix
(commit `8b859e5`) routes the token through a non-keyword local variable with identical
semantics. Re-validation: the parse gate accepted all 156 files; the pinned scan reported zero
leaks (958 non-blocking keyword hints); `canonical-production-seams.tests.ps1` passed 56/0
without a baseline shift; the full `root-claims-registry.tests.ps1` suite passed with exit code 0
and 713 PASS lines; `git diff --check` was clean; `build-skills.ps1` produced 7/15/7 and the sync
DryRun completed with no live mutation. The authoritative unified run over the final committed
state then passed all 34 suites exactly once with zero failures, timeouts, duplicates, missing
suites, or tree-kill failures (external create-new summary SHA-256
`fac9c474926389e6334c64b62897d6aad77a6bb0f9c82fd255e141c18e0ca848`, discovery hash
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`; hard-kill 318/0, seams
56/0, root-claims 713/0, transaction 64/0, command-result 51/0 inside the run). With that
authoritative validation, Step 3 is complete: Task 1 is 3/6 and Phase 2 is 3/52, and the next
implementable work is Task 1 Step 4 (Define the minimal shared-state and generic state-target
contract). No production Apply, backup, rollback, retirement, live-root mutation, or Git
index/ref mutation was performed. Production Apply remains interlocked.

## 2026-09-07 Phase 2 Task 1 Step 4: shared-state and state-target contract implemented in four slices

Per the reviewed four-slice design (`tmp/grok-step4-shared-state-design.md`, Grok), Step 4 is
implemented with Grok as the implementation agent under the updated delegation model (main agent
orchestrates, reviews every diff line by line, and commits), in four commits, with zero schema
changes, zero sealed-script changes, and no live-journal structure:

- Slice 1 (commit `d4e82ff`): `scripts/shared-authority-state-common.ps1` gains the in-memory
  intent contract — `New-AuthorityTargetContextIntent` (claims projection without capability),
  `Assert-AuthorityTargetContextIntent`, `Assert-AuthorityFinalIdentitiesDerivedFromIntent`
  (EXISTS identity freeze, ABSENT new-identity rules including the parent-alias ban,
  `FinalTargetContextHash` reproduction), `Get-AuthorityStateIntentProjection` (strips exactly
  the Apply-derived runtime fields), `Assert-AuthorityControllerTransitionPreservesSelection`
  (the eleven frozen selection fields with the allowed-drift set), and the trusted serializer
  `New-AuthorityStatePostimage` (intent runtime-pollution rejection, receipt-bearing versus
  controller-transition `RuntimeRefs` shapes, `Test-CurrentEnvStateSemantics` on the assembled
  postimage). The first Grok verification round caught a real main-agent defect (a string
  assertion contradicting the array-typed `MissingRemainder` check) that was fixed before commit.
- Slice 2 (commit `db1af36`): `Read-SealedRegistryValidatedAuthorityDocuments` — the held
  write-side validated read (genuine global witness; MISSING states returned, contract-invalid
  documents thrown as `authority-state-validated-read-invalid` with the inner contract message),
  deliberately forked from the view's `INVALID` classification, which a regression pair pins.
- Slice 3 (commit `94f1287`): `New-SealedRegistryRootClaimsCreateNew` — the first-authority
  claims writer (proposed-claims schema/semantics/SID binding, MISSING gate, the claim-accept
  consumer as its unique production caller, authority-directory create-new with the
  current-user-only descriptor, pending held create-new plus no-replace rename, and the returned
  `TargetContextIntent` with the claims file-byte hash). The seams boundary was rewritten:
  claim-accept moved from the zero-external blanket to a unique-caller inventory.
- Slice 4 (commit `ce70ada`): `Write-SealedRegistryCurrentEnvStatePostimage` — the atomic
  create / replace / recovery-copy trio (Create via held create-new plus no-replace rename;
  Replace via OS `File.Replace` with the old state bytes landing in the caller-supplied recovery
  path and asserted; RecoveryCopy publishing the new postimage bytes create-new), all through the
  trusted serializer's bytes with held schema revalidation, the pair semantics, the
  controller-transition G4 comparator, and identity-checked failure cleanup.

Focused validation per slice: root-claims-registry progressed 713 → 724 → 736 → 756 → 777 PASS
with exit code 0 each time; seams stayed 56/0 with the reflection inventory re-pinned to count
13459 / digest `876c2a3f807b74e2b09d23ac4939c6ed895e6c8a16875348874a10d72fd5b005`; the parse gate
accepted all 156 files; the pinned secret scan reported zero leaks; `git diff --check` was clean;
`build-skills.ps1` produced 7/15/7 and the sync DryRun changed no live file. The authoritative
unified `run-tests.ps1 -All` run over the Step 4 state then passed all 34 suites exactly once
with zero failures, timeouts, duplicates, missing suites, or tree-kill failures (external
create-new summary SHA-256
`741dbd345b458e451a436a94d3dd532be74afc7c6f530a04ca9160ea553cdb55`, discovery hash
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`; hard-kill 318/0, seams
56/0, root-claims 777/0, transaction 64/0, command-result 51/0 inside the run). With that
authoritative validation, Step 4 is complete: Task 1 is 4/6 and Phase 2 is 4/52, and the next
implementable work is Task 1 Step 5 (Implement deterministic lock semantics). Claims are created
only for first authority and never replaced; Phase 3 owns migrate/adopt/repair-adopt/takeover/
activation; Task 4 owns the live-journal phases that will wrap these primitives. Production
Apply remains interlocked, and no live root or Git index/ref was changed.

## 2026-09-08 Phase 2 Task 1 Step 5: deterministic lock semantics implemented in four slices

Per the reviewed four-slice design (`tmp/grok-step5-lock-semantics-design.md`, Grok), Step 5 is
implemented with the enable boundary resolved without lifting any tracked interlock:
"enable only the setup Apply" means the lock-order machinery plus the single legal route shape —
only `RouteKind='setup'` with `AcquisitionMode='SetupBootstrap'` may bootstrap a MISSING prefix,
live/normalize/promote/merge/canonical-recover reject it with
`live-cannot-bootstrap-missing-canonical-claim`, the composer's durable writes stay `deferred`,
`Register` stays uncalled on production paths, and `scripts/live-safety-policy.psd1` plus the
`canonical-apply-interlocked` / `canonical-recovery-apply-interlocked` / 75 production results
are untouched.

- Slice 1 (commit `4ecc3b4`): the typed CLR handle `SealedHeldCanonicalLiveLockOrder` and the
  `Enter-/Exit-/Assert-SealedHeldCanonicalLiveLockOrder` orchestrator (ExistingOnly): overlay
  `REQUIRED` rejected before any lock, canonical OpenExisting (`canonical-lock-missing`),
  bootstrap-COMPLETE gate, the BOUND witness binding versus `UNBOUND_SETUP_WINDOW`
  (setup/canonical-recover only, non-setup with a missing setup state throws
  `canonical-setup-required`), tail-to-head failure cleanup, idempotent Exit, and full Assert
  revalidation. Reverse-order acquisition fails the witness binding.
- Slice 2 (commit `6c8be14`): the SetupBootstrap branch (zero production callers) —
  plan payload revalidation, canonical `AllowCreate` in this mode only, the reviewed composer
  invoked for the bootstrap→prefix→unbound-global chain, `Register` not called, the two-slot
  `New-SealedHeldCanonicalSetupJournalTargetManifest` with `Write='deferred'` attached through
  the CLR-guarded single-shot `AttachJournalTargetsExact`; the composer's unique-caller
  allowlist is now only the orchestrator.
- Slice 3 (commit `21fece7`): `Get-SealedHeldLockOrderRecompute` — after all required locks are
  held: the full worktree journal scan (unfinished → `canonical-recovery-required`, consumed
  DocumentHash → `reviewed-plan-consumed`), the BOUND-path registry view (missing/tampered
  claims surface with the view tokens), the UNBOUND-window validated read, repository identity
  drift rejection, in-lock plan currency, the `lock-order-route-kind-mismatch` guard, and the
  single-shot `AttachRecomputeExact` with `Assert-LockOrderBackupAllowed` returning
  `lock-order-recompute-incomplete` until the recompute exists (`BackupWorkspaceAuthorized` is
  constantly `$false` on production paths).
- Slice 4 (commit `b483647`): the production retrofit — `canonical-transaction.ps1 -Apply` now
  takes the ExistingOnly lock order after plan revalidation (first-run missing prefixes are
  swallowed to `$held=$null` with zero creation; a held lock chain runs the recompute) and still
  emits `canonical-apply-interlocked` / exit 75; `recover-canonical-transaction.ps1 -Apply`
  assembles the handle on its already-held canonical lock (BOUND or UNBOUND_SETUP_WINDOW), runs
  the recompute tolerating `canonical-recovery-required`, and still emits
  `canonical-recovery-apply-interlocked` / exit 75. A contended COMPLETE fixture now observably
  yields `operation-lock-busy` instead of silent interlock, and releases back to interlock.

Focused validation per slice: root-claims-registry progressed 777 → 817 → 841 → 876 → 876 PASS
(exit 0 each), live-concurrency passed, command-result progressed 51 → 66 PASS, canonical
recovery stayed 104/0, seams stayed 56/0 with the reflection inventory re-pinned along the way
(final baseline recorded in the committed suite), the parse gate accepted all 156 files, the
pinned secret scan reported zero leaks, and `git diff --check` was clean. Two Grok
implementation sessions reached their turn budget after writing near-complete slices; the main
agent reviewed the left-behind diffs line by line, completed validation, and committed. The
unified `run-tests.ps1 -All` run over the Step 5 state then passed all 34 suites exactly once
with zero failures, timeouts, duplicates, missing suites, or tree-kill failures (external
create-new summary SHA-256
`9f60a75cf33b615b2ced24e41670066146d6bbf28406fd83043fddce736b352f`, discovery hash
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`; hard-kill 318/0, seams
56/0, root-claims 876/0, live-concurrency 221/0, command-result 66/0, transaction 64/0 inside
the run). With that authoritative validation, Step 5 is complete: Task 1 was 5/6 and Phase 2 was
5/52 at that checkpoint, and the next implementable work was Task 1 Step 6 (Verify identity,
state shape, and locking) — the final Task 1 step, re-verifying the adopt/retirement route
contention the fifth checkpoint recorded for Step 5/6. Worktree overlay locking, journal phases,
and the task/sync route retrofit stay with Phase 3 / Task 4 / Task 5. Production Apply remains
interlocked, and no live root or Git index/ref was changed.

## 2026-09-08 Phase 2 Task 1 Step 6: verification of identity, state shape, and locking

Step 6 (the final Task 1 step) is the verification pass over the plan's expected outcomes, with
each outcome pinned to its existing test anchors plus one new route-contention block:

- (a) absent→created preserves the authority namespace: home-authority
  `[home authority artifact contracts]` and the live-root classification blocks — COVERED.
- (b) partial overlap rejected globally: the ordered-reservation disjoint matrix, the two
  HomeRoots ancestor/descendant rejection, and the forbidden-root pairwise nesting — COVERED.
- (c) kill-between claim→setup-state uniquely finalizes or stops with relocation and
  state-without-claim rejected: the hard-kill setup claim/state matrix and the recovery
  locator/without-claim fixtures — COVERED.
- (d) state oneOf/RootClaimsHash at the schema/semantic layers: the HA artifact-contract block
  and the registered negative fixtures' FailureLayer matrix — COVERED.
- (e) canonical versus live/retirement non-interleaving with a zero-write loser: the
  live-concurrency canonical-bound contention blocks, the Step 5 setup-Apply interlocked
  contention block, and the new `[canonical live lock-order route contention]` block added this
  step (a recover Apply lock-order loser emits `operation-lock-busy` with a tree-hash-zero-write
  fixture, and a released holder returns to `canonical-recovery-apply-interlocked` / 75, also
  zero-write) — COVERED for the routes that exist; real retirement/sync routes stay with Task 5.
- (f) OS-handle release after owner death only (durable post-kill classification stays with
  Tasks 4/6/8): the live-concurrency owner-death assertion — COVERED.

Validation on 2026-09-08: `tests/home-authority.tests.ps1` passed 207/0, `tests/live-concurrency.tests.ps1`
passed 221/0, `tests/root-claims-registry.tests.ps1` passed 883/0 (876 + 7 new route-contention
assertions), seams stayed 56/0 without a baseline change (tests-only diff), the pinned secret
scan reported zero leaks, and `git diff --check` was clean. No production script changed. The
authoritative unified `run-tests.ps1 -All` run over the Task 1-complete state then passed all 34
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill
failures (external create-new summary SHA-256
`ea989bfc5c7351339f0f70265e4ec4909df3cec4d5691cdc27648a542a7cdd03`, discovery hash
`1c323da6ae6872e58d8a0cf9af3c6d15ef9c0b9130fbfdc178f73602f69500b0`; hard-kill 318/0, seams 56/0,
home-authority 207/0, live-concurrency 221/0, root-claims 883/0 inside the run). With that
authoritative validation, Step 6 is complete and **Task 1 is complete at 6/6** (Phase 2 is
6/52): identity, state shape, and locking are verified to the plan's expected outcomes, with the
recover-Apply route contention re-verified at route level and real retirement/sync routes
staying with Task 5. The next implementable work is Phase 2 Task 2 (Replace Sync Plan Schema 2
with the Semantic Plan Contract). Production Apply remains interlocked, and no live root or Git
index/ref was changed.

## 2026-09-08 Phase 2 Task 2 slices 1-3: semantic plan contract foundation

Per the reviewed five-slice design (`tmp/grok-task2-semantic-plan-design.md`, Grok; public DryRun
narrowed to pristine initial plus retirement per adopted Alternative F; production Apply and
`ReleaseState=interlocked` untouched; sync is not an Enter caller), the first three Task 2
slices are implemented:

- Slice 1 (commit `b51a742`): `schemas/sync-plan.schema.json` is replaced with the schema 3
  semantic contract (const 3 envelope with `Metadata`/`PlanPayload`/`PlanHash`/`DocumentHash`,
  `additionalProperties:false`, the frozen eight-kind OperationKind oneOf with no
  full-repo/environment-rollback/live-recover kinds, the `TargetContextIntent` $def matching
  Task 1's row keys, `ProposedRootClaims` reusing the root-claims $defs copies, and the
  AuthorityStateIntent subset excluding PlanHash/DocumentHash and runtime fields), with the
  initial positive fixture, six negative fixtures, the new `tests/live-plan.tests.ps1` (60
  PASS), and a test-frozen `sync-plan.v2-live-compat.schema.json` so the still-v2 emitter keeps
  the content-aware sync tests green (82 PASS).
- Slice 2 (commit `3d3aa7f`): env-build v3 — the sidecar `env-build.json` with the
  `MaterializationHash` (RFC 8785 excluding `GeneratedAtUtc` and itself), per-platform
  materialized roots with empty-root `Exists=true`, the shared
  `Invoke-HarnessEnvMaterialization` as the single skills/lock/sidecar writer that refuses a
  non-empty destination and never recursively deletes it, and lock-file-set exclusion of both
  the lock and the sidecar. A real build was verified (schema 3 sidecar, reproducible
  MaterializationHash, lock shape unchanged, empty roots present).
- Slice 3 (commit `6f0ddd3`): `scripts/live-plan-common.ps1` with the sole full-semantics
  validator `Test-LiveSyncPlanSemantics` (the eight-kind required/forbidden matrix, intent
  three-layer consistency, retirement manifest/postset shape with
  `retirement-selection-conflict`, system/unknown-marker shapes) replacing the slice-1 envelope
  function in the same commit, plus `Complete-LivePlanAuthorityStateIntent` (adds the envelope
  hashes so the result is directly consumable by `New-AuthorityStatePostimage`; zero production
  callers) and the sealed fixture helper. `Assert-AuthorityTargetContextIntent`'s unique-caller
  inventory extends to the semantics validator.

Focused validation: live-plan progressed 60 → 94 PASS, sync stayed 82 PASS, validate-json-
artifacts passed 23 positive / 76 negative, seams stayed 56/0 with the reflection inventory
re-pinned (count 13640 / digest `7600aa01…`), the parse gate accepted all 159 files, the pinned
secret scan reported zero leaks, and `git diff --check` was clean. Grok implemented slices 1-2
end to end; its slice-3 session exited abnormally after writing a complete, defect-free
implementation that the main agent validated and committed (the Grok Build quota pool was then
exhausted with HTTP 402, recorded in project memory). The next Task 2 slice is slice 4
(immutable plan write, the pristine-initial/retirement DryRun producers, host injection via the
`AI_AGENT_DOTFILES_INTERNAL_*` prefixed variables, the five no-lock step functions, and the
content-aware test extraction), followed by slice 5 (retirement regression). Production Apply
remains interlocked, and no live root or Git index/ref was changed.

The main agent then implemented the first half of slice 4 directly (commit `6318abe`, after the
Grok quota exhaustion): `Write-LiveSyncPlan` (create-new with `live-plan-path-collision`),
`Read-LiveSyncPlan`, `Assert-LiveSyncPlanDocumentIntegrity` (full semantics plus both envelope
hashes), `Assert-LiveSyncPlanCurrent` (the bound materialization identity, both file-byte hashes,
and the semantic `MaterializationHash` recomputed against the held `env-build.json`/`env.lock.json`),
`Assert-LiveSyncPlanSelectionContext`, and `Assert-LiveSyncPlanDocumentHashNotConsumed` (injected
terminal evidence with `live-plan-consumed`), with eleven live-plan assertions (105 PASS total).
Remaining for Task 2's close-out: the `sync.ps1` producer rework (pristine-initial and retirement
DryRun producers behind the sandbox capability gate with host injection, the emitter switched to
`Write-LiveSyncPlan`, and the content-aware test extraction), the retirement matrix migration, and
the authoritative unified validation. Production Apply remains interlocked, and no live root or
Git index/ref was changed.

## 2026-09-09 Phase 2 Task 2 close-out: schema 3 producers, retirement regression, and unified validation

Phase 2 Task 2 (Replace Sync Plan Schema 2 with the Semantic Plan Contract) is complete (7/7; Phase 2
13/52). The main agent implemented the remaining slice 4 second half (immutable write and DryRun
producers) and slice 5 (retirement regression) directly after the Grok quota exhaustion, as recorded
in project memory. Commits `3831fd9` (implementation) and `0d84edf` (suite budget) carry the work;
the earlier slices 1-3 and the slice 4 first half were commits `b51a742`, `3d3aa7f`, `6f0ddd3`, and
`6318abe`.

The public `sync.ps1` surface now has a schema 3 semantic plan face:

- DryRun requires the internal sandbox: the capability must be present and the host must inject
  `AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT`/`_BACKUP_ROOT`/`_CONTROL_BASE` (the internal host now sets
  the three locators beside the existing ROOT/PATH/TOKEN trio and restores them in `finally`).
  Without them the dry-run fails closed with `live-plan-host-resolution-required` and zero plan
  bytes; it never reads USERPROFILE or an unprefixed `INTERNAL_*` variable. A create-new `-PlanPath`
  is required, and a second run on the same path returns `live-plan-path-collision` while the bound
  materialization is preserved.
- Without `-RetireManifestPath` the producer is pristine-initial only (adopted Alternative F): it
  requires absent live roots and an unoccupied control base (`live-plan-selection-mismatch` /
  `live-plan-authority-present`), materializes the named `full` environment through the single
  `Invoke-HarnessEnvMaterialization` writer into the create-new `<PlanStem>.materialization`
  directory beside the plan, and binds the exact lock/build file bytes plus the sidecar
  `MaterializationHash`. The plan's add actions and counts come from the copied definition.
- With `-RetireManifestPath` the producer reads the seeded schema 3 authority state at the canonical
  `<ControlBase>/homes/<HomeAuthorityKey>/current-env.json` locator (schema- and semantics-validated,
  exact-byte capture; never a writer), reuses the reviewed staleness walk (messages unchanged), binds
  the manifest path/bytes, canonical/generated/current-manifest absence evidence, per-platform target
  tree hashes, and the state-derived postset, rejects a target inside the postset selection with
  `retirement-selection-conflict`, and emits prune actions carrying `explicit-retirement`.
- The emitter is `Write-LiveSyncPlan` (create-new schema 3), and Apply validates the reviewed
  document through the five no-lock steps before the mandatory backup: document integrity, current
  PlanHash recomputed from the same pure producer (no materialization recreation, `PlanPath` never
  rewritten), bound materialization currency, selection context, and the DocumentHash-not-consumed
  gate with an empty injected evidence map (Task 4 wires journal scanning into step six). The
  pristine-initial live-mutation host (claims create, receipts, state postimage) stays unwired and
  fails closed with `live-plan-initial-apply-not-wired` after full validation; retirement executes
  its reviewed prune actions one skill directory at a time with the reviewed tree-hash gate, the
  mandatory backup, the overwrite-style journal with `explicit-retirement` authority records, and
  post-apply target/marker verification.

Recorded deviation from the adopted design: explicitly bound `-HomeRoot`/`-BackupRoot` keep
selecting the legacy content-aware deploy route instead of being rejected outright, because
`activate-harness-env.ps1` Gate 4 delegates its deploy to `sync.ps1` and the roadmap deletes the
legacy swap/journal paths only in Task 5 Step 1; the harness-env activation regression stayed green
(140/0) through the migration. The new surface never sees a public selector, and the direct
`live-plan-public-selector-rejected` posture returns with Task 5. The design's "no schema 2 emitter
residue in sync.ps1" goal is likewise scoped to the public producer face: the legacy route keeps its
plan-file binding and per-skill swap/journal behavior until Task 5, with the deviation recorded here.
Replay protection in Task 2 comes from staleness recomputation (a retired target set is rejected
after it is pruned, even if the same bytes are recreated) and the injected `live-plan-consumed`
gate; a byte-identical document hash is rejected only with injected terminal evidence, and no
live-transaction scanning exists in this task.

Test-side migration: `tests/sync.tests.ps1` builds the v3 fixture (an in-sandbox git repository with
copied harness-source, manifests, pinned tool locks, and placeholder skills counted from the copied
`full` definition), exercises the pristine-initial producer, the authority-present and collision
gates, the unwired initial apply, and the full retirement regression (schema and full semantics,
OperationKind, semantic envelope hashes, zero hook evidence, `explicit-retirement` authority,
state-array intent with the reviewed projection match against the seeded state, conflict, manifest
path/bytes/live-root/content drift rejections all before backup, successful prunes with backup and
journal authority, replay rejection after the targets are gone, and the Reasonix override dry-run
and apply with an exact live-root binding). The content-aware dry-run/drift/apply/prune regression
moved verbatim to `tests/helpers/task5-environment-sync-regression.ps1`, which `sync.tests.ps1`
deliberately does not dot-source or invoke (reason
`task2-pristine-initial-only-pending-environment-producer`).
`schemas/sync-plan.v2-live-compat.schema.json` is deleted, and `tests/live-plan.tests.ps1` now pins
the producer surface (the schema 3 producer definition, the immutable create-new emitter, the
selector-triggered legacy route) instead of the v2 compatibility shims; its own assertions grew to
107 PASS.

Seams: the reflection-sensitive inventory was re-pinned (count 13835 to 14059, digest to
`bbe86927339a19aaa01e3d5d0fe37163dea805c10958fae65a1fff7e2a56eda3`) together with the all-scripts
dynamic-command digest
(`3a8bc621a93857f9ef248c6bd294afdaaddfe2cf620f3a4e2f9a8672187cde81`), and the boundary audit exposed
that the slice 4 first half had added `Assert-LiveSyncPlanDocumentIntegrity` as a production caller
of `Test-LiveSyncPlanSemantics` without a seams run. The boundary now registers exactly that one
reviewed internal caller (allowed-caller list plus reviewed owner inventory) and every other
production call site still fails closed; seams passed 56/0.

Suite budget: the migrated `sync.tests.ps1` measures about 86 seconds locally, beyond its 90-second
bound, so its budget moved to 240 seconds and the Validate workflow timeout moved from 298 to 305
minutes (computed requirement 17985 seconds over 35 discovered suites, outer margin 315 seconds);
the runner budget contract passed.

Focused validation on the closed state: live-plan 107 PASS, sync PASS, harness-env 140/0,
automation-safety PASS, schema-validation PASS, json-artifact-exact-byte PASS, validate-json-
artifacts PASS, the PowerShell parse gate accepted all 160 files, the build produced Claude/Codex/
Reasonix 7/15/7, the pinned secret scan found no blocking findings, `git diff --check` was clean,
and the sandbox-hosted DryRun routine gate ran the pristine-initial producer against the real
repository (29 adds, zero live changes). The definitive unified `run-tests.ps1 -All` run then
discovered, started, completed, and passed all 35 suites exactly once with zero failures, timeouts,
duplicates, missing suites, or tree-kill failures; the external create-new summary SHA-256 is
`ec0d9f1cd78768bade27cc75252ac7d64219685526be7f6c838feebde0aa0789` and the discovery hash is
`96e6267d927bcdeca4ba56af9f4104cafc0467e43fad51f8ae5b0f8e5cae388e`, with `canonical-hard-kill` at
318/0 and `canonical-production-seams` at 56/0 inside the run and `sync.tests.ps1` completing in
63 seconds inside its new 240-second bound. After the run, a fresh sandbox-hosted DryRun gate
reproduced the pristine-initial producer (plan hash
`638258f33b700be1f788f47932e0f4a143ffaa141799f4dbc0964662f1f2be18`, plan-file SHA-256
`5bbdda2e6213e0397c1fb92abb8ffb23bc50eeca3fd2db285374e6f84600012e`, document hash
`213dbbcb34527473d91de2db824f9f1316e69043b1977d7e17e02cb1681bf562`, 29 adds), and the temporary
sandbox, plan, and external summary paths were deleted after the evidence was recorded. Production
Apply remains interlocked, and no live root or Git index/ref was changed. `docs/README.md` now
documents the schema 3 producer contract and the sandbox-hosted dry-run invocation shape.

## 2026-09-09 Phase 2 Task 3 close-out: managed backup receipts and standalone backup retirement

Phase 2 Task 3 (Create Unique Managed and Authority-Preimage Backup Receipts) is complete (7/7;
Phase 2 20/52), implemented directly by the main agent (the user's "both" instruction after the
read-only state report) as commits `2be7153` (implementation) and `706fed0` (suite budget), on top
of the Task 2 close-out and the ZCode adoption docs commit `8bc666c`/`00ca8bf`.

`scripts/backup-receipt-common.ps1` delivers the transaction-internal receipt producer. It receives
the flushed ReceiptIntent (exact keys, canonical UUID spellings, distinct transaction and receipt
ids, receipt path leaf bound to the ReceiptId and parent bound to the resolved BackupRoot), the
exact SourceOperationKind and reviewed PlanHash/DocumentHash, the execution-context/ControlBase/
FilesystemCapability hashes with the HomeAuthorityKey, already-resolved three-platform targets, and
the forbidden-root set. It validates BackupRoot (existence, no-reparse ancestry, identity
stability, Fixed/NTFS, current-user-only security evidence with the reviewed v2 owner set, and
disjointness from the forbidden/live roots), creates the unique predeclared slot atomically
(no-follow create-new, collision token), snapshots only the planned pre-change managed targets
through SafeTreeWalker with the reviewed planned tree-hash gate, records planned-missing targets as
MISSING without fake directories, records unknown and Codex `.system` root-entry markers without
traversal, captures the authority state and root-claims preimages as exact held bytes, publishes
the immutable SchemaVersion=1 receipt (create-new temp, flush, rename) whose ReceiptHash excludes
only itself, and returns the structured object the host consumes directly. The restart classifier
reads only the declared slot and reports MISSING/PARTIAL/COMPLETE; the consumer verifier re-reads
the published receipt exact-byte, re-validates the registered schema and semantics, the COMPLETE
marker, the intent bindings, the managed snapshot trees, and the preimage bytes (the bound source
Identity is provenance and intentionally not re-derivable from the snapshot copy). Test-only
failpoints are capability-gated.

`schemas/backup-receipt.schema.json` registers the receipt with the artifact registry (one positive,
eight negative fixtures: unknown-property/wrong-version/copied-crossing/marker-crossing at the
Schema layer and intent-binding/self-hash/target-order/transaction-receipt-alias at the Semantic
layer) and `validate-json-artifacts.ps1` dotsources the new module; the fixture set passes 25
contracts' worth of registered validation with zero failures.

`scripts/backup.ps1` is retired: a public standalone invocation now fails closed with the zero-write
non-zero `backup-is-transaction-internal` diagnostic before any traversal or BackupRoot work.
Recorded deviation: the sandbox-internal legacy snapshot flow remains as the bridge for the env
activation route (`activate-harness-env.ps1` Gate 4 inside `sync.ps1`'s selector-triggered legacy
deploy), because the roadmap deletes the legacy swap/journal paths only in Task 5 Step 1; the
production-facing standalone entry is fully dead and the diagnostic replaces the interlock message
that automation-safety previously asserted.

`tests/backup-receipt.tests.ps1` (with the sandbox-copied receipt host helper) covers the happy path
(custom Reasonix root, MISSING targets, unknown/`.system` sentinel bytes and write timestamps
unchanged, fresh-copy link counts, byte-identical preimages), the registered artifact validation and
consumer verification with and without optional bindings, restart classification in a fresh process
with a decoy sibling slot, the producer failure matrix (same-slot collision, pre-created destination,
planned tree-hash drift, planned-present target missing, planned-missing target now existing,
reparse entries leaving a partial slot, missing/inside-live/broad-DACL BackupRoot, receipt-path leaf
and parent and aliasing intent mismatches), a genuine concurrent same-slot race with exactly one
winner, all five kill windows (slot-created, snapshot-published, preimage-published, receipt-published,
complete-published) with fresh restart classification and second-create refusal, and the tamper
matrix (byte-tampered document, wrong SchemaVersion, drifted SourceOperationKind and plan hashes
against the expected bindings, tampered snapshot, missing preimage, tampered COMPLETE marker), plus
the MISSING-preimage recording and verification path.

Focused validation: backup-receipt PASS (about 21 seconds locally), automation-safety PASS,
sync PASS, harness-env 140/0, live-plan 107 PASS, schema-validation PASS, json-artifact-exact-byte
PASS, validate-json-artifacts PASS, the PowerShell parse gate accepted all 163 files, the pinned
secret scan found no blocking findings, and `git diff --check` was clean; the seams boundary was
re-pinned (all-scripts dynamic-command digest `1aff69f1842635904847dc47a6c3e0bf0fa1aed4f466156f2ce560ec414e5062`,
reflection-sensitive inventory count 14288, digest
`2580eb60d85f5b3e1b53f093dd009c1dbe252d877e5b3e5bbb3e571575e20dab`) and passed 56/0. The new suite
was budgeted at 300 seconds and the Validate workflow timeout moved from 305 to 310 minutes
(computed requirement 18285 seconds over 36 discovered suites, outer margin 315 seconds); the
runner budget contract passed. The definitive unified `run-tests.ps1 -All` run then discovered,
started, completed, and passed all 36 suites exactly once with zero failures, timeouts, duplicates,
missing suites, or tree-kill failures; the external create-new summary SHA-256 is
`c35cf2594b1f2baa186dee088327acfca96f8eacb6fecd43a5758badfa593c89` and the discovery hash is
`bc2c80521319cd7e8ad8ae3c944174af14e31b823243844f8c1f34be26889e00`, with hard-kill exit 0, seams
56/0, backup-receipt passed in about 20.5 seconds, sync exit 0, harness-env exit 0, and
automation-safety exit 0 inside the run. The external summary path is deleted after this evidence
was recorded. Production Apply remains interlocked, and no live root or Git index/ref was changed.
`docs/README.md` documents the retired standalone backup entry. Receipt consumption (restart
classification plus verified rollback) stays with Tasks 4/6/7; the transaction host that mints
TransactionId/ReceiptId and flushes the reservation header arrives with Task 4.

## 2026-09-09 Phase 2 Task 4 close-out: live-mutation state machine, journal, and kill matrix

Phase 2 Task 4 (Implement the Live Mutation State Machine) is complete (7/7; Phase 2 27/52),
delivered in four slices across 2026-09-09: slice A `6ddc1e4` (journal schemas and chain layer),
slice B `51425ff` (target plans, same-volume staging, and the receipt-backed engine), slice C
`4ba7323` + `1197ed5` (authority state target and failure classification), slice D `45dd69f`
(state-only branch and the kill matrix, implemented by Grok grok-4.6 via Grok Build from a
self-contained brief after the quota pool was probed restored, integrated and verified by the main
agent).

`schemas/live-journal-header.schema.json`, `live-journal-record.schema.json`, and
`live-operation-result.schema.json` freeze the live transaction contract: the receipt-backed versus
state-only mode oneOf (ReceiptIntent with the receipt-path leaf bound to the id versus
ReceiptRef=NO_LIVE_MUTATION), the original OperationKind set, OriginRepoId/GitCommonDirHash/
CanonicalLockKey binding, live target records (skill/parent-directory/state with identity, receipt
snapshot reference, MISSING|PRESENT old/new states), eighteen record phases with strict per-phase
data key contracts, and the command-versus-transaction result scope split (command scope carries
only CommandKind with an optional lifecycle TransactionId; transaction scope binds original
OperationKind/DocumentHash/ResultBaseHeadHash/Outcome with receipt-state/hash consistency,
committed/rolled-back requirements, the state-only no-receipt rule, and the nullable StateHash
MISSING-state sentinel).

`scripts/live-transaction-common.ps1` delivers the journal publisher (create-new namespace with
_pending, held-chain pending-rename publication reused from the canonical journal primitives,
record append with previous-hash links, the closing-COMPLETE-only-after-result rule), the zero-write
chain reader, and the chain validator (dense sequences, hash links, per-record phase semantics,
recovery intent precedence for applied records, terminal-record-last bound to the exact published
result file bytes, the strict closing oneOf, and unknown-namespace-entry rejection). The receipt-
backed engine `Invoke-SealedLiveTransactionMutation` runs the fixed record sequence:
RECEIPT_COMPLETE, parent-first no-overwrite directory creation with captured identities
(DIR_CREATE_INTENT/DIR_CREATED), per-target staging with the destructive recheck, the same-volume
rename ladder with full disk tuple verification (MOVE_OLD_INTENT/OLD_MOVED/MOVE_NEW_INTENT/
NEW_INSTALLED with MISSING no-op semantics for prune), the authority state target, POSTCONDITIONS_OK,
and the committed fixed result and terminal record. Failure classification: before the state commit
boundary a caught failure restores completed live targets and this-transaction-created claims in
reverse (identity-bound, empty-only parent removal), verifies the restoration, and publishes the
failed-restored fixed result (RestorationHash plus the unchanged old state hash; StateHash null is
the MISSING-state sentinel) and terminal record, then exits non-zero
`apply-failed-but-restored`; unverified restoration or any failure after the state commit boundary
retains the evidence and exits `live-transaction-recovery-required` without rewriting live/state.
The state-only engine `Invoke-SealedLiveTransactionStateOnly` runs the controller-transition
sequence: immutable claims proof, the captured state preimage journaled with
STATE_PREIMAGE_COMPLETE, the controller-transition postimage proven by
Assert-AuthorityControllerTransitionPreservesSelection (only controller/toolchain/generation fields
change), the FILE_* replace ladder, POSTCONDITIONS_OK, and a committed result with no receipt
fields; failures retain the preimage/journal evidence and rethrow for reviewed
abandon/finalize (Task 6). Capability-gated failpoints at eight record boundaries feed the kill
matrix.

Tests: `tests/live-recovery.tests.ps1` covers the journal chain semantics and publication
(create-new refusal, hash links, phase/closing oneOf negatives, result head binding, pending-temp
tolerance), the receipt-backed engine (update/add/prune across platforms with old-copy
preservation), the authority state target (existing-authority claims proof, recovery copy
retention, committed result and terminal), failure restoration (a corrupted staged copy fails the
second target after the first installed; the old content is restored into live, the installed copy
returns to staging as recovery material, only one NEW_INSTALLED is journaled, the failed-restored
result binds the unchanged old state hash), the state-only branch (claims proof, preimage
capture, controller-transition replace, committed result with no receipt fields), the kill matrix
through the sandboxed child host (receipt-backed kills at RECEIPT_COMPLETE/PREPARED/OLD_MOVED/
NEW_INSTALLED/STATE_PUBLISHED and state-only kills at STATE_PREIMAGE_COMPLETE/FILE_REPLACED with
restart classification, fail-closed re-entry refusal, and preimage retention), and the external
race assertion (Restore-SealedLiveMutationTargets fails closed on a non-empty or identity-drifted
created parent). The suite is budgeted at 300 seconds.

Focused validation at each slice: live-recovery PASS, validate-json-artifacts PASS (the three new
contracts with positive and negative fixtures), parse gate 166 files, secret scan clean,
`git diff --check` clean, and seams 56/0 after mechanical re-pins (final: dynamic
`4a40541a5acf86b1694619697df43d6e510eb49b6c234082130bfa81f47745e5`, reflection count 14573, digest
`d11b3a51c7de05a17c43f2c185198429133281e3dde6ada57b2cdd602003dbf1`); the seams boundary also
caught the unregistered production caller of New-AuthorityStatePostimage on the first slice C run,
registered as the second reviewed caller alongside the registry writer. The definitive unified
`run-tests.ps1 -All` run then discovered, started, completed, and passed all 37 suites exactly once
with zero failures, timeouts, duplicates, missing suites, or tree-kill failures; the external
create-new summary SHA-256 is
`29963be7d7215d331a3b797bc1f78c0fd9f8ea03eef5efae78668e6485fc4f8d` and the discovery hash is
`b5e6d64c51d66adf878e287b29ab3773794cb8d3f95463e32b82ec488672cfd0`, with live-recovery passed in
about 41 seconds, hard-kill exit 0, seams 56/0, and sync/harness-env/automation-safety exit 0
inside the run; the external summary path is deleted after this evidence was recorded. Production
Apply remains interlocked, and no live root or Git index/ref was changed. Grok's model identity for
slice D is evidenced by the probe and session logs; model identity for the GLM slices, fees, and
human work time remain `unknown`.

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

## Task 5 progress (2026-09-10): host wiring, legacy removal, claims contract

Phase 2 Task 5 slices 1-3 landed across seven commits. Slice 1 composed the public
receipt-backed host (`Invoke-SealedLiveTransactionHost`, 84d382c): the existing-only lock order
with under-lock authority and live-rows revalidation, receipt-backed journal header, managed
backup receipt, and the mutation engine; the bootstrap snapshot now tolerates the legal dynamic
authority child under HomesRoot (64-hex key directory holding only root-claims.json or
current-env.json) and GUID-named receipt/transaction directories under BackupRoot and
LiveTransactionsRoot, everything else still fails closed. Slice 2 wired the schema 3 apply tail
onto that host for both initial and retirement (ec8f478): full home-authority context resolution
from the injected sandbox home, per-platform capability probes against same-volume staging roots,
per-platform sealed-hash action bindings, and a claims contract that binds `RootClaimsHash` to the
exact bytes of the complete proposed root-claims document (schema, semantics validator, and
producer updated together). Slice 3 removed the legacy content-aware deploy route (b333673):
`Sync-OneSkillDir-Transactional`, `Remove-OneSkillDir`, the overwrite-style sync journal,
`Restore-CompletedManagedSkills`, the whole-root backup parsing, the `-HomeRoot`/`-BackupRoot`
selector surface, and the extracted task5 regression helper (-998 lines net).

Architectural decisions recorded here: sync never bootstraps the authority prefix (activation
does; sync requires COMPLETE and otherwise fails `live-plan-authority-missing`); canonical setup
requires existing private roots, which is why activation owns both; initial plans are exempt from
apply-time recomputation because the control base legitimately transitions MISSING to EXISTS
between planning and apply, so initial staleness is guarded by materialization integrity plus the
host's under-lock revalidation while retirement keeps the plan-hash comparison;
`activate-harness-env` Gate 4 is a fail-closed stub (`activation-deploy-not-wired`) and
task-skills attestations now read the candidate overlay directly instead of the removed plan
report text; the Reasonix override retirement scenario now asserts the claims-binding rejection,
with a claimed custom root to be covered by a dedicated sandbox in Step 5.

Slice 4 closed Step 5 with a dedicated parity sandbox in sync.tests (0cc6ccc): a second
full chain — authority bootstrap and canonical setup in their own process (the sealed registry
route capture is process-global), initial transaction against a Reasonix root overridden at
initial planning time with the claims binding that exact root, retirement pruning an explicitly
retired skill from it, and the .agents fallback posture pinned as a fail-closed refusal
(fallback-root machines are non-pristine and wait for Phase 3 migrate/adopt). Two authoritative
unified runs passed 37/37 discovered suites with zero failures and zero timeouts: the first on
the clean tree at 408da9a, the second on the final Task 5 tree including the parity sandbox
(DiscoveryHash b5e6d64c51d66adf878e287b29ab3773794cb8d3f95463e32b82ec488672cfd0 for both, the
suite set is unchanged; external JSON summaries stay outside Git). The harness-model feedback
loop was checked at closeout: no new upstream feedback since the recorded application, so
docs/ZCODE.md is unchanged per the loop's no-repeat rule.

Verification (canonical `pwsh -NoProfile -File` runs): sync.tests (initial and retirement full
chains, re-apply fail-closed, manifest negatives, Reasonix override rejection), live-plan.tests
(111 assertions), harness-env.tests (109), task-skills.tests (22), automation-safety.tests,
live-recovery.tests, backup-receipt.tests, canonical-production-seams.tests (56, after baseline
re-pins f9a2611 and the reflection inventory in the slice 3 commit), parse (166 files), secret
scan, and `git diff --check`. The authoritative unified run on the clean tree at 408da9a passed
37/37 discovered suites with zero failures and zero timeouts (DiscoveryHash
b5e6d64c51d66adf878e287b29ab3773794cb8d3f95463e32b82ec488672cfd0, 2026-09-10T00:29:07Z, job
budget 18585 seconds; the external JSON summary stays outside Git). Known
deferrals recorded: public `-SkipBuild`/`-SkipSecretScan` rejection under `-Apply` and in-process
fake build/scan adapters land with the Phase 4 public-surface work; the sandbox layout now
derives backup/control under the injected home's AppData\Local\ai-agent-dotfiles path, mirroring
the production home-authority derivation.

## 2026-09-10 CI validate repair: schema-3 drift and suite budgets

The Validate workflow had failed 9 consecutive times since 2026-09-08 (`2bef22b`) with two
distinct causes, both now fixed on main.

1. Machine-readable evidence drift (8 consecutive failures, `2bef22b`..`408da9a`): commit
   `3d3aa7f` moved the env-build sidecar to schema 3 but `.github/workflows/validate.yml`
   still required `SchemaVersion -ne 2` at the evidence step, so every run died with
   "Harness environment build JSON is invalid." before the test matrix. `git log -L` on the
   assertion shows it was never touched between the schema bump and the fix. Fixed in
   `895c54f` (assertion pinned to 3); run 34415557457 confirmed the step now passes. All
   other version assertions in the step already matched their schemas at that commit
   (secret-scan 1, build-report 1, env-lock 3, env-list 1, env-status 1).
2. Suite budget exhaustion (run 34415557457, step 13): 33/37 suites passed with zero
   assertion failures while four hit their exact budgets on the slower runner —
   canonical-command-result 420s, canonical-production-seams 240s, root-claims-registry
   1800s, sync 240s (summary `discovered=37; passed=33; failed=0; timed-out=4`). Same-tree
   local canonical runs measured 231s/187s/1511s/197s, a roughly 2x CI multiplier, so each
   old budget sat at or below the CI observation. Fixed in `881047a`: budgets moved to
   900/600/3600/900 and the workflow bound to 380 minutes (proven total 21465 seconds over
   37 suites including the eleven 120s defaults, required bound 364.75 minutes). Verified
   with `tests/test-runner.tests.ps1`: discovery, timeout semantics fixtures, and the
   budget contract all pass. The full Validate run on `881047a` then completed green
   (run 34430424975, 147.3 minutes, 37/37 suites, zero failures and zero timeouts),
   ending the streak.

Follow-up: the Task 5 parity sandbox landed in `0cc6ccc` after those numbers were taken,
making sync heavier. Measured at `5def813` in an isolated worktree: sync.tests passes in
321s locally (about 650s projected on CI), so its budget moved again 900 -> 1200; with the
eleven 120s defaults the proven total is 21765 seconds and the required bound 370.25
minutes, still inside the 380-minute workflow limit (test-runner contract re-verified).
Production Apply remains interlocked; nothing in these commits touches live roots or
generated output.

## Task 6 Step 1 (2026-09-11): read-only recovery status locator

Commit `e384a95` adds `scripts/recover-live-transaction.ps1`, the Task 6 Step 1 locator. It scans
every transaction journal under `<ControlBase>\live-transactions` with the zero-write chain reader
and classifies each transaction into exactly one status: finished journals summarize as `clean`;
receipt-only journals are `abandon-eligible`; applied target, claims, or state primitives before the
complete postimage are `rollback-required`; a published result with postconditions but no terminal
record is `finalize-eligible`; and unreadable chains, unknown namespace entries, missing header
origin bindings, or phase shapes matching no reviewed recovery form fail closed as
`manual-recovery-required`. The overall status is the most severe unfinished transaction. The scan
retains no handles, renames nothing, deletes nothing, and writes only an optional create-new JSON
report (`-JsonPath` refuses to overwrite); the reviewed transitions deliberately stay with the Task 6
Step 3 dispatcher.

Verification (canonical `pwsh -NoProfile -File` runs on this tree, 2026-09-12): focused
`tests/live-recovery.tests.ps1` passed with all locator fixtures green (each status class, the known
`_pending` temp tolerance, the create-new machine-readable report, and report-overwrite refusal);
`tests/canonical-production-seams.tests.ps1` passed 56/0 after the all-scripts baselines were
re-pinned inside `e384a95`; the PowerShell parse gate accepted 166 files. The unified
`run-tests.ps1 -All` pass has not been executed for this slice yet and remains pending at the next
stage boundary. Production Apply remains interlocked, and no live root was touched.

## Task 6 Step 2 (2026-09-12): rollback/recovery plan schema 1

Commit `3dbe911` defines the formal schema-1 rollback/recovery plan contract
(`schemas/rollback-plan.schema.json`, ArtifactKind `rollback-plan`) for the four PlanKinds
`environment-rollback`, `live-recover-abandon`, `live-recover-rollback`, and
`live-recover-finalize`. The schema layer enforces the strict TransactionMode/PlanKind/ReceiptState
oneOf shapes from the plan: complete receipt-backed rollback/finalize require
ReceiptId/ReceiptHash/SourceTransactionId/SourceOperationKind/OriginalPlanHash; early abandon
declares ReceiptState MISSING/PARTIAL/COMPLETE and forbids fabricated receipt hashes outside
COMPLETE; state-only controller recovery requires `ReceiptRef=NO_LIVE_MUTATION` plus the immutable
state preimage/expected tuple and forbids every receipt field with empty Targets; environment-rollback
is always complete receipt-backed, binds the Task 7 `RollbackStateIntent` (the frozen
current-env-state v3 intent shape) plus ReceiptIntent/ReceiptId/ReceiptHash/original plan
references, and forbids the live-recover journal machinery. The payload binds reservation/journal
identity, OriginRepoId/GitCommonDir/canonical-lock keys, the optional overlay lock, the original
DocumentHash and prior recovery consumption keys, header/chain-record/pending-temp/result
inventory, target identity hashes, and the expected terminal semantic projection.

`Test-RollbackPlanSemantics` (added to `scripts/live-transaction-common.ps1`, which is not
hard-kill-sealed) owns the cross-artifact consistency the schema cannot express: the
PlanKind/action/outcome/projection correspondence, the live-recover `OriginalOperationKind`
substitution ban, chain-record ordering and derived-head binding, the terminal-COMPLETE ban, and
the root-claims/authority-state bindings implied by `CLAIMS_PUBLISHED`/`STATE_PUBLISHED`/
`STATE_PREIMAGE_COMPLETE` chain phases. The schema deliberately leaves `OriginalOperationKind` as a
spelling-only string so the substitution negative fails at the semantic layer, as the plan requires.
Envelope PlanHash/DocumentHash binding reuses the reviewed semantic-JSON hash functions.

Fixtures: a receipt-backed `live-recover-rollback` positive, five schema-layer negatives, and ten
semantic-layer negatives; the sync-plan contract gains three more PlanKind rejection fixtures so all
four rejected kinds are pinned at its schema layer (joining `live-recover-finalize`). The seams
all-scripts reflection-sensitive baseline was re-pinned for the new validator (14491 -> 14508
sites, new digest); no suite assertion was weakened.

Verification (2026-09-12, canonical `pwsh -NoProfile -File` runs): registered artifact validation
passed 28 contracts / 28 positive / 109 negative fixtures with zero failures; the extended
`tests/live-recovery.tests.ps1` passed with 20 new contract assertions (positive dual-pass, each
semantic negative by reviewed token, each schema negative, all four sync-plan rejections);
`tests/canonical-production-seams.tests.ps1` passed 56/0 after the re-pin; `tests/sync.tests.ps1`
passed (sandbox-hosted chains including the parity sandbox); the parse gate accepted 166 files;
`git diff --check` was clean; the pinned secret scan found no blocking findings (1023 non-blocking
hints); and `build-skills.ps1` produced 7/15/7. The unified `run-tests.ps1 -All` pass remains
pending and now covers the Task 6 Step 1 and Step 2 trees together at the next stage boundary.
Production Apply remains interlocked, and no live root was touched.

## Task 6 Step 3 in progress (2026-09-12): recovery dispatcher slices 1-4

Task 6 Step 3 is four slices in with the recovery dispatcher executable for all three reviewed
transitions; the checkpoint record lives in [`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md).
Landed: slice 1 `1423b78` (the `agent-dotfiles.ps1 live recover` route, dispatcher parameter sets,
sandbox authority resolution with the complete-bootstrap gate, fail-closed stub, roadmap doc
`61163cd`); slice 2 `5176e8b` (DryRun derives the schema-1 rollback/recovery plan under the origin
canonical/witness/global lock order — origin candidate matching on RepoId/GitCommonDirHash/
CanonicalLockKey/HomeAuthorityKey, under-lock chain revalidation, classification-vs-action
eligibility, evidence bindings including verifier-validated COMPLETE receipts, create-new plan
write; Apply validates plans fail-closed); slice 3 `b304e8f` (abandon and finalize execution:
mandatory RECOVERY_ACTION_INTENT, abandoned result with result-semantics receipt binding, finalize
reusing the published result bytes and preserving its Outcome; two Task-4-era journal gates refined
— the terminal ClosingPlanKind crossing exemption and the Add gate admitting the finalize intent
after a published result); slice 4 `f2ff911` (rollback execution: recovery targets reconstructed
from the chain records, `Restore-SealedLiveMutationTargets` reverse replay with exact preimage
verification, RestorationHash into the rolled-back result; a real-engine kill-window fixture with a
verifier-accepted receipt exercises the full flow).

Verification per slice: the live-recovery suite is green with the dispatch matrix (CLI gates,
authority gates, abandon dry-run/apply end to end, state-only finalize end to end, rollback end to
end, unknown/action-mismatch/wrong-clone/collision/finished rejections), seams passed 56/0 after
routine baseline re-pins, registered artifact validation passed 28/28/109 with zero failures, the
parse gate accepted 166 files, the pinned secret scan and `git diff --check` were clean, and
`tests/sync.tests.ps1` stayed green. The unified `run-tests.ps1 -All` pass remains pending and will
cover the whole Step 3 tree at its closeout.

Remaining for Task 6 Step 3: dispatcher failpoint checkpoints with hard-kill/replay fixtures,
linked-worktree dispatch coverage, STATE_PUBLISHED and state-only rollback (state recovery
machinery — currently fail-closed `live-recovery-state-form-unsupported`), and the Step 3 closeout
(unified run plus the close-out records). Production Apply remains interlocked; no live root was
touched.

## Task 6 Step 3 completion (2026-09-12): authority state rollback, recovery failpoints, worktree dispatch

Commit `0e04a2c` closes the Step 3 scope named at the previous checkpoint; the detailed record lives
in [`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md). Two
independent read-only Grok reviews preceded the commit: the first produced the state-rollback design
note whose findings were applied, the second found two defects and four gaps in the delta; every
finding is fixed in this commit or recorded as an explicit boundary.

Authority state recovery: `scripts/live-transaction-common.ps1` gained the journal-bound state
evidence helpers and `Restore-SealedLiveAuthorityState`, which restores `current-env.json` from the
`FILE_PREPARED.StagedPath` preimage copy (exact bytes, copy hash re-verified), requires the installed
state to equal the recorded published postimage or the preimage on replay, re-proves the immutable
claims against the header, and journals the new `STATE_RESTORED` phase only when bytes are written,
so replays are idempotent. Rollback replays also skip completed live targets already at their
preimage, and the rolled-back result binds the restored state hash. Plans bind
`AuthorityStatePreimage`/`AuthorityStateExpected` for any completed state replacement and a rollback
additionally binds the optional schema-1 `AuthorityStatePreimagePath` (verified against the copy);
`Test-RollbackPlanSemantics` requires all three for a rollback over `FILE_REPLACED`/`STATE_PUBLISHED`
and rejects an orphan path through the new `rollback-plan.state-preimage-path-orphan.invalid.json`
fixture. `STATE_PREIMAGE_COMPLETE`/`FILE_PREPARED` moved to the pre-primitive set, so a captured
preimage with zero state primitive is abandon-eligible per the plan's disjoint state-only priority.
Two shapes fail closed with `live-recovery-state-form-unsupported`: a state file replaced on disk
while its `FILE_REPLACED` record is missing, and a receipt-backed live-target rollback whose state
was staged but not yet replaced — the latter now derives and applies a live-only rollback while the
state still equals the recorded preimage.

Recovery failpoints: the dispatcher publishes `RECOVERY_ACTION_INTENT`,
`RECOVERY_ACTION_PRIMITIVES`, `RECOVERY_ACTION_APPLIED`, and `RECOVERY_RESULT_PUBLISHED`. Kill/replay
fixtures prove the intent window replays through a plan that consumes the interrupted intent, the
primitive and applied windows replay without repeating a live move or state write, and the result
window is finalize-only (a rollback request fails closed and finalize reuses the rolled-back result
bytes and preserves its outcome). A linked worktree dispatches through the shared GitCommonDir
origin namespace and closes the transaction; the wrong-clone rejection is unchanged.

Verification: `tests/live-recovery.tests.ps1` green in 310 s; `tests/canonical-production-seams.tests.ps1`
56/0 after the all-scripts reflection-inventory re-pin (count 14616 -> 14689, digest
`285cef6a2e221ba1cc676ce00a61260f4bd6d488e225fe8fefe6f75004211c15`); registered artifact validation
28 contracts / 28 positive / 110 negative with zero failures; `tests/test-runner.tests.ps1` passes
with the live-recovery budget raised 300 -> 900 s and the workflow timeout 380 -> 390 minutes
(computed requirement 22785 s); the parse gate accepted 166 files; `tests/schema-validation.tests.ps1`
passed; `git diff --check` was clean; the pinned secret scan found no blocking findings (1009
non-blocking hints); `build-skills.ps1` produced 7/15/7; and the sandboxed `sync.ps1 -DryRun`
reported 29 additions with zero live mutation. The definitive create-new external unified
`run-tests.ps1 -All` pass then discovered, started, completed, and passed all 37 suites exactly once
with zero failures, timeouts, duplicates, missing suites, or tree-kill failures (external summary
SHA-256 `5d21f5adb362704aa1f16ad2e123189c9eab7eaffe2784a4b23cb8132441b018`, discovery SHA-256
`b5e6d64c51d66adf878e287b29ab3773794cb8d3f95463e32b82ec488672cfd0`, elapsed 6281 s, with
`canonical-hard-kill` 318/0 in 2415 s, seams 56/0 in 217 s, root-claims in 1525 s, live-recovery in
322 s, live-plan 121 assertions in 10 s, and sync in 317 s). The first unified pass of this window
had failed exactly two pre-existing test-expectation defects — a stale sync-plan negative-fixture
count from the Step 2 slice and seven assertions matching PowerShell's English binder resource
strings, which cannot match on this host's zh-CN UI culture while CI (en-US) stayed green; commit
`9a29db6` repairs both by pinning the registry count and fixture names and by matching the
exception message or the stable `FullyQualifiedErrorId`, with no rejection weakened. Production
Apply remains interlocked and no live root was touched.

## Task 6 Steps 4-5 (2026-09-12): deterministic failpoints, committed-finalize, and the restart gates

Commits `528aec5` and `99a8e87` implement Step 4 and the Step 5 items it exposed; the detailed
record lives in [`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md).
Every Step 4 boundary is now a configured checkpoint: `RESERVED` (namespace and header durable),
`RECEIPT_FINALIZATION` (immediately before the managed receipt producer), `RECORD_PENDING:<Phase>`
and `RECORD_PUBLISHED:<Phase>` around every journal-record publication (composed from the two
reviewed canonical publication primitives, so the hard-kill-sealed shared helper is untouched),
`STATE_REPLACE_PENDING` before the authority state move in both engines, `RESULT_PUBLISH` once the
postconditions record is durable, and `TERMINAL_RECORD` before the final `COMPLETE` record in both
engines, the failed-restored path, and the dispatcher.

The `RESULT_PUBLISH` window (complete state postimage plus postconditions, no published result) is
now a reviewed committed-finalize instead of a fail-closed dead end: DryRun binds the missing
result inventory, the committed outcome, and the installed state hash in the expected terminal
projection; the semantic layer requires those phases and that projection for a result-MISSING
finalize; Apply revalidates the postimage, the immutable claims, and the projection under the held
locks and publishes fixed bytes computed from the original evidence and the actual journal head
(committed outcome, installed state hash, and for receipt-backed transactions the
verifier-revalidated COMPLETE receipt block, with no restoration binding). A header-only
reservation is now abandon-eligible, which the plan names as its `RESERVED` window.

Two open items the new windows exposed became fail-closed rules: a live mutation refuses to start
while any transaction in the authority's journal namespace is unfinished (`live-recovery-required`,
zero new namespaces, released once the transaction is finished), and a header binding
`WorktreeOverlayLockKey` fails recovery plan derivation and apply with
`worktree-overlay-lock-not-implemented` instead of being recovered without the overlay lock the
header requires (the reviewed lock-order primitive refuses REQUIRED applicability until the Phase 3
worktree overlay lock exists; the dispatcher previously read the wrong field name and would have
silently skipped it).

Verification: `tests/live-recovery.tests.ps1` green in 446 s with the new engine record-boundary and
pre-replacement windows, the state-only pre-replacement and pending-`STATE_PUBLISHED` windows, and
the dispatcher's reservation-only abandon, receipt-backed and state-only committed-finalize,
pre-replacement live-only rollback, overlay rejection, unfinished-transaction gate with its release
proof, and an injected mid-recovery failure that retains the preimage copy and then replays to
completion; `tests/canonical-production-seams.tests.ps1` 56/0 after the all-scripts
reflection-inventory re-pin (14689 -> 14713, digest
`816d7205e9fdc6f39087bea148086ae3247c4d691d3ed08deecc78170bd7eb05`); registered artifact validation
28/28/110 with zero failures; the parse gate accepted 166 files; the pinned secret scan found no
blocking findings; `build-skills.ps1` produced 7/15/7; `tests/sync.tests.ps1`,
`tests/live-plan.tests.ps1`, `tests/live-concurrency.tests.ps1`, and `tests/doctor.tests.ps1`
passed; `git diff --check` was clean. The unified `run-tests.ps1 -All` pass is the Task 6 closeout
gate: the definitive create-new external pass discovered, started, completed, and passed all 37
suites exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures
(external summary SHA-256 `62b9797b9d46313993eac33186de7bb34a9801dd809c988f0c6bdccee8e1b71b`,
discovery SHA-256 `b5e6d64c51d66adf878e287b29ab3773794cb8d3f95463e32b82ec488672cfd0`, elapsed
7191 s; hard-kill 318/0 in 2721 s, seams 56/0 in 241 s, root-claims 1680 s, live-recovery 545 s,
live-plan 121 assertions, sync 287 s). An earlier pass of the same tree reported 36/37 with a single
`root-claims-registry` failure (`route-witness-required`) that did not reproduce standalone (1745 s)
or in the definitive pass and is recorded as machine-load interference. Production Apply remains
interlocked and no live root was touched.

Two Step 5 clauses remain open and are assigned to Task 8's matrix fixtures: a different
HomeAuthority with overlapping custom roots, and a concurrent canonical mutation being unable to
interleave. The recovery-side worktree overlay lock remains the Phase 3 item, and the
`RECEIPT_FINALIZATION` checkpoint is placement-pinned because the production host is not yet run as
a killable child.

## Task 7 slices 1-2 (2026-09-13): receipt-based rollback entry and a plan-layer contradiction fix

Commits `00e3632` and `50d6616` start Task 7; the detailed record and the remaining-scope map live in
[`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md). The rollback
entry is rebuilt on receipts: only `-ReceiptPath` selects a rollback, the legacy
`RunId`/`BackupPath`/`BackupRoot`/`HomeRoot` switches and the legacy whole-tree implementation are
removed, Apply still stops at the Phase 0 interlock, and the preflight fails closed with
`rollback-receipt-missing`, `rollback-receipt-not-complete`, or `rollback-source-kind-unsupported`
before a complete environment receipt reaches the not-yet-wired transition stub. The new
`tests/backup-recovery.tests.ps1` pins that surface; `docs/README.md` and `docs/RESTORE.md` describe
the new form; the new suite's 300-second budget moved the workflow timeout to 400 minutes.

A bounded design review for Task 7 then found a hard contradiction introduced by Task 6 Step 2:
`Test-RollbackPlanSemantics` required `OriginalOperationKind` for every plan and only then returned
early for `environment-rollback`, while the schema forbids that field for that kind — so no
environment-rollback plan could pass both layers and Task 7 Step 2 had no representable plan. The
validator now handles that kind first with its own rules (`SourceOperationKind=environment`,
no `OriginalOperationKind`, receipt id agreement, and `RollbackStateIntent` carrying
`LastOperationKind=environment-rollback` with the payload authority key); three registered semantic
negatives and an in-suite positive pin it.

The review's remaining findings are recorded as the next slices' scope: the host cannot run a
rollback as written (kind gate, `RollbackStateIntent` instead of `AuthorityStateIntent`, a
`TargetContextIntent` reconstructed from current claims, mapping the plan's targets onto the engine's
add/update/prune ladder, and source roots pointing at the activation snapshot); the rollback is a new
**original** receipt-backed transaction whose terminal closes with `ClosingKind=original`; the
`RollbackStateIntent` copies preimage semantics while regenerating the rollback's own refs; the
worktree overlay lock the order requires is still unimplemented, so execution verification depends on
the Phase 3 overlay lock; and the Step 1 source graph must be composed from the sealed plan fixture,
a real header, a real managed receipt with `SourceOperationKind=environment`, and the test host's
`produce` engine mode rather than the public host (which rejects `environment`).

## Task 7 Step 1 completion (2026-09-13): source graph and eligibility gates

Commit (this slice) completes Task 7 Step 1; the detailed record lives in
[`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md). The rollback
entry now gathers the complete source-graph evidence and fails closed before the transition stub:
receipt field/semantics/path/marker integrity, `HomeAuthorityKey` binding, managed snapshot tree
hashes, both authority-preimage copies, current claims bytes, the linked `SourceTransactionId`
journal (existence, zero-write chain validation, single terminal record, `Outcome=committed`, and
the full header/`RECEIPT_COMPLETE`/result receipt binding), and the current-surface comparison
against the terminal poststate (state bytes hash, overlay-baseline equality between the activation
preimage and the current state, and per-platform live-root path and directory identity). Each
disagreement throws its own reviewed token; plan/JSON output paths are preflighted through the
shared private-artifact-path table before the evidence gates; an eligible graph still reaches
`live-rollback-dispatch-not-wired`.

`tests/backup-recovery.tests.ps1` builds the reviewed source graph per the design recipe (sandbox
builder + sealed `environment` plan fixture + `New-SealedLiveJournalHeader` + a real
`Invoke-SealedManagedBackupReceipt` receipt with `SourceOperationKind=environment` + the test host's
`produce` engine mode) and grew from 26 to 87 assertions covering the rejection matrix: relocated
receipt path binding, backup snapshot drift, tampered preimage copies, marker/self-hash/missing-field
tampering, another HomeRoot, preimage-vs-poststate overlay-baseline drift, a receipt against a
different Reasonix root, header-only reservations, a real `failed-restored` terminal, tampered
journal records, a replaced live root, a later legitimate generation staling the earlier of two
complete receipts, current state/claims drift, the artifact-path and collision preflights, and the
interlocked Apply. The fixture models real activation semantics: the first graph claims a custom
Reasonix root and later graphs reuse the roots the current authority state resolves. Two named cases
stay fixture-unbuildable boundaries (a committed environment→task-overlay chain and
`abandoned`/`rolled-back` source terminals); PlanKind mismatch remains pinned at the plan layer
until Step 2 adds the entry-layer Apply case. Verification (canonical `pwsh -NoProfile -File`
runs): backup-recovery 87 assertions in 245 s locally, live-recovery, seams 56/0 after re-pinning
the all-scripts baselines (dynamic-command digest and reflection-sensitive inventory 14591 → 14646
for the entry's added dictionary/CLR dispatch sites), backup-receipt, automation-safety,
agent-dotfiles, harness-env, live-plan, doctor, and test-runner all passing; registered artifact
validation 28 contracts / 28 positive / 113 negative with zero failures; the parse gate accepted
167 files; the pinned secret scan found no blocking findings; `build-skills.ps1` produced 7/15/7;
`git diff --check` was clean. The backup-recovery budget moved 300 → 900 s; the computed
requirement (23685 s) stays below the 400-minute workflow bound. Production Apply remains
interlocked and no live root was touched.

## Task 7 Step 2 (2026-09-13): the derived environment-rollback plan under the reviewed lock order

The detailed record lives in
[`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md). The rollback
entry now binds the calling repository as the origin candidate and runs everything after the receipt
preflight under the origin canonical → worktree overlay → global lock order. Under those locks the
Step 1 evidence and eligibility gates revalidate, a wrong origin clone fails closed
(`rollback-origin-mismatch`), a source header binding the worktree overlay lock fails closed with
`worktree-overlay-lock-not-implemented` until the Phase 3 primitive exists, and DryRun derives the
schema-1 `environment-rollback` plan entirely from verified evidence — source transaction, source
receipt identity, original plan references, origin keys, `RootClaimsHash`, the `RollbackStateIntent`
carrying the activation preimage's semantic fields with `LastOperationKind=environment-rollback` and
the authority generation advanced past the current state, and one restore row per receipt snapshot
target (observed `Current`, exact snapshot bytes and pre-change identity as `Candidate`, snapshot
path and `ReceiptSnapshotRef` for COPIED targets) — self-checks through
`Test-RollbackPlanSemantics`, writes the plan create-new, and prints the PlanHash. Apply validates
the reviewed plan fail-closed (presence, schema, semantics, and the invocation match for plan kind,
authority, receipt id/hash, source transaction, and original hashes) before the still-not-wired
transition stub; Apply remains behind the Phase 0 production interlock.

Verification (canonical `pwsh -NoProfile -File` runs): `tests/backup-recovery.tests.ps1` grew to 135
assertions (385 s locally, inside its 900 s budget) with the derived plan validated against the
pinned schema and semantic layer in-suite and asserted for every binding including the three restore
rows; new source-graph variants pin the origin mismatch and the overlay-lock refusal, each with zero
plan bytes; `tests/canonical-production-seams.tests.ps1` passed 56/0 after re-pinning the
all-scripts baselines (reflection-sensitive inventory 14646 → 14679 for the derivation's added
dispatch sites); live-recovery, automation-safety, agent-dotfiles, harness-env, live-plan, and
doctor passed; registered artifact validation 28/28/113 with zero failures; the parse gate accepted
167 files; the secret scan found no blocking findings; `build-skills.ps1` produced 7/15/7;
`git diff --check` was clean. Production Apply remains interlocked and no live root was touched.

## Task 7 Steps 3-4 (2026-09-13): the executed rollback transaction, verified directly until Phase 3

The detailed record lives in
[`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md).
`scripts/live-transaction-common.ps1` gains `Invoke-SealedEnvironmentRollbackTransaction`, the
reviewed composition that executes a derived `environment-rollback` plan as a new original
receipt-backed transaction under a caller-held reviewed lock order. Step 3 inside it creates the
pre-rollback receipt (`SourceOperationKind=environment-rollback`, bound to the rollback plan's
hashes) that snapshots exactly the live bytes every plan target is about to change plus the current
authority state and claims — any drift between the plan's `Current` bindings and the live tree
fails the producer before any mutation. Step 4 maps the plan's restore rows onto the engine's
add/update/prune ladder (equal rows are no-ops), stages the restore copies from the source
activation's receipt snapshots, completes the `RollbackStateIntent` with the rollback plan's hashes,
projects the context rows from the current state's bound final identities (the reviewed
state-vs-claims validators pin them to the immutable claims, proven unchanged through
`RootClaimsHash`), uses the reviewed home staging base, and runs the common state machine to a
committed terminal with `ClosingKind=original` and the restored state carrying
`LastOperationKind=environment-rollback` with the generation advanced past the pre-rollback state.

Because the reviewed lock-order primitive refuses `REQUIRED` worktree-overlay applicability until
Phase 3 and production Apply stays interlocked, the entry's Apply tail now fails closed with
`worktree-overlay-lock-not-implemented` after full plan validation (the
`live-rollback-dispatch-not-wired` stub is retired), and the direct tests are the reviewed
verification surface: `tests/backup-recovery.tests.ps1` executes the eligible plan end to end in
the sandbox and grew to 150 assertions (321 s locally) — all three verb classes restore
symmetrically on the already-claimed custom Reasonix root, the pre-rollback receipt snapshots the
pre-rollback live bytes, the installed state matches the returned StateHash with the advanced
generation and rollback kind, the chain validates with a committed original close, and the executed
source receipt is afterwards stale against its own rollback.

Verification: seams 56/0 after re-pinning the reflection-sensitive inventory (14679 → 14715;
dynamic-command digest unchanged); live-recovery, backup-receipt, live-plan, automation-safety,
agent-dotfiles, harness-env, doctor, and test-runner passing; registered artifact validation,
parse gate (167 files), secret scan, `build-skills.ps1` (7/15/7), and `git diff --check` clean.
Production Apply remains interlocked and no live root was touched.

## Task 7 Step 5 (2026-09-13): the env rollback CLI surface

`tests/harness-env.tests.ps1` section 9.10 completes Step 5: `env rollback` without a receipt path
fails closed on the missing mandatory parameter, the legacy `RunId` token no longer selects a
rollback, and the public non-sandbox surface fails closed with `live-plan-host-resolution-required`
before any authority or receipt work, writing no plan. The three-platform symmetric execution
substance on the already-claimed custom Reasonix root is pinned by the backup-recovery suite's
derivation and execution sections. With this, Task 7's five roadmap steps are implemented; only the
closeout unified `run-tests.ps1 -All` pass (38 suites) remains. Verification: harness-env 112/0;
parse gate, secret scan, and `git diff --check` clean. Production Apply remains interlocked and no
live root was touched.

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
definitive pass. Production Apply remains interlocked and no live root was touched. A first
background launch attempt silently failed on a quoting error (its shell chain broke before the
runner started and an unrelated stale log mimicked a result); the run was relaunched through an
external wrapper that reports the summary path, SHA-256, and counts itself, and only that second
run is recorded as definitive.

## Task 8 Step 1 (2026-09-13): mid-flight zero-wait losers and the canonical interleave proof

`tests/sync.tests.ps1` gains the mid-flight lock-contention section (the full-chain sandbox fixture
lives there; live-concurrency retains the lock-level coverage): two different retirement plans
against the same overlapping roots, the winner held mid-flight at the deterministic `PREPARED`
failpoint while it owns the origin canonical and global live locks, the competing plan losing with
exact zero-wait `operation-lock-busy` and zero backup/journal mutation, a concurrent canonical
mutation unable to interleave, the winner's failpoint deadline expiring into the reviewed
failed-restored terminal, and the competing plan completing the retirement under the fresh locks.
This also executes the carried Task 6 Step 5 canonical-interleave proof. Step 2 is recorded as the
zero-wait-by-design boundary; Step 3's kill windows are the Task 6 Step 4 failpoint matrix. The
Task 8 remainder is Step 4's root-claim overlap and custom-target matrix. Verification: sync.tests
455 s (budget 1200 s) with zero failures; test-runner, live-plan, automation-safety, and doctor
passing; parse gate, secret scan, and `git diff --check` clean. Production Apply remains
interlocked and no live root was touched.

## Task 8 Step 4 (2026-09-13): the transition rejection pinned, and the cross-authority gap recorded

`tests/backup-recovery.tests.ps1` (155 assertions) pins the default→custom Reasonix root transition
after a claim exists: a forged transaction whose header binds a semantically valid claims document
for a different root is rejected by the immutable claims proof, closes `failed-restored`, leaves
the claims bytes unchanged, never claims or populates the proposed root, restores its pruned
target, and its receipt cannot start a rollback. The claims semantics' fixed Claude/Codex home
paths (only Reasonix is customizable) are exercised explicitly.

**Recorded finding (empirical, two-authority probe):** the other half of Step 4's Expected — two
authorities sharing one platform root being rejected — is **not implemented**. A dedicated
two-home probe committed full environment transactions for BOTH authorities claiming the same
custom Reasonix root: the claims semantics validate disjointness within one document only, the
registry's global claim lives under each authority's own control base, the canonical witness
validates the repo identity but not the ControlBase, and the unfinished-transaction scan is
per-authority. Cross-authority root-claim overlap rejection requires a machine-wide claim store —
the Phase 3 shared-authority design question — so the carried Task 6 Step 5 cross-authority proof
waits for that mechanism. Verification: backup-recovery green; parse gate, secret scan,
`git diff --check`, and test-runner clean. Production Apply remains interlocked and no live root
was touched.

## Phase 2 closeout (2026-09-13): Task 9 checkpoint complete

The Task 9 checkpoint closed Phase 2 live-safety hardening. Steps 1, 2, 4, and 5 were recorded
first (focused suites green; artifact validation 28/28/113; a bounded independent review that
returned VERDICT PASS with six P2 findings, all dispositioned in `24dcabe`; the real-home
non-mutation evidence). Step 3's first unified pass (on the `95b6772` tree) returned 37/38 with
exactly one failure — the seams inventory baseline omitted from the review-fix commit (14715 →
14721; dynamic-command digest unchanged) — re-pinned in `0c348c3` and recorded as non-definitive.
The authoritative pass on that tree **discovered, started, completed, and passed all 38 suites
exactly once with zero failures, timeouts, duplicates, missing suites, or tree-kill failures, in
6886 s** (hard-kill 2365 s, root-claims 1567 s, live-recovery 442 s, sync 421 s, backup-recovery
264 s, seams 218 s); its external summary SHA-256 is
`bdbe7713b20ca618bc1af4035fa8452c60dcb1dfde313f527d2ea102acc7d581` (deleted after this record),
DiscoveryHash `bca55823225ad6bfb5769b99b4cd7f4c60abcd546cab63b470b81d850d7ae137`, computed job
requirement 23685 s under the 400-minute workflow bound.

**Phase 2 (Tasks 1-9) is complete.** The two design-bound open items feed Phase 3: the
cross-authority root-claim overlap rejection (a machine-wide claim store — both authorities commit
on a shared custom root today) and the rollback execution's production caller (the Phase 3
worktree overlay lock). The production interlock is unchanged: every production
Apply/rollback/retirement still returns `safety-protocol-upgrade-required`, and no live root was
touched by any of this work.

## Phase 3 Task 1 (2026-09-13): lock 3 freeze verified, artifact graph pinned, separate readers

Phase 3 opened with Task 1 (freeze environment lock 3, consume env-build 3, and complete the
shared-state transition semantics), completed at 7/7 steps. New work: `tests/harness-authority.tests.ps1`
(157 assertions, 11.4 s measured against its new 300 s suite budget) with an emitter-derived lock graph (a real environment is materialized
in an isolated fake repository), the state/claims graph, the frozen sync-plan authority branches,
and the registered `harness-env-lock` contract (5 graph negatives, all Schema-layer). Production
change: `Read-LegacyHarnessEnvState` (`scripts/harness-env-common.ps1`) reads only the repo-local
schema 2 evidence with exact bytes and `MISSING`/`CORRUPT`/`VALID` status, and `Read-HomeAuthorityState`
(`scripts/shared-authority-state-common.ps1`) read-only validates the ControlBase schema 3 state and
its separate claims with `ClaimsStatus`/`StateStatus`/`PairStatus`; the legacy display reader is
unchanged, and neither reader can see the other's locator family.

Verification: the new suite 157/157 (including the exhaustive 64-combination pair-status matrix);
`harness-env` 112/112; `sync` PASS; `home-authority` PASS; `test-runner` PASS; artifact validation
29 contracts / 29 positives / 118 negatives, zero failures; seams re-pinned twice, finally to
reflection-sensitive 14780 / digest
`955df89694c4f60d13855e8664ce82802dcde6f7c2ab063f8017c49ce5dc6a34`, and 56/56; parse gate 168
files; secret scan clean; `git diff --check` clean. Implementation commits:
`8f75dda` (readers, suite, seams re-pin), `b9b00d0` (lock contract), `29e3607` (content-bound lock
assertions), `a8f2981` (reader rationale comment), `d7fe10f` (bounded-review fixes and the second
seams re-pin), `fa53b7c` (explicit suite budget). A bounded independent review of the delta returned nine findings with no P0/P1; the
mis-classification of a missing schema validator, the missing directory-key binding, the accepted
UNC ControlBase, the legacy reader's lossy casts, and the test gaps were all fixed in `d7fe10f`,
with the remaining validator-process and reparse-point behaviours recorded as boundaries.

The unified regression over the full suite catalog (launched 2026-09-13T13:31:12Z, before the bounded
review fixes landed) reported `Test summary: PASS; discovered=39; passed=39; failed=0;
timed-out=0` in 7859.7 s; its external summary SHA-256 is
`a389aa306686483bf59ab9c596b83905973823b1c037370cf2d2e3857c1c0364` (deleted after this record) with
a post-run mtime of 2026-09-13T15:42:11Z. The tree moved during the run: the production and test
changes in the review fixes are additive for the modules the earlier suites exercise (verified zero
deletions across both production files), and every affected suite was re-run standalone on the
frozen tree afterwards (authority 157/157 including the pair-status matrix, harness-env 112/112,
home-authority PASS, seams 56/56 at the final 14780 pin, artifact validation PASS, test-runner
PASS, parse gate 168 files, secret scan clean, `git diff --check` clean). The frozen-tree definitive
pass for the whole Phase 3 remains with the Task 9 checkpoint. Task closeout feedback loop: the
verification-as-pinned-assertions method was contributed upstream (`harness-model` `44b6b03`) and
re-imported into `docs/ZCODE.md`. Production interlock is unchanged, and no real home, ControlBase,
legacy state, or live root was touched.

## Phase 3 Task 2 (2026-09-13): authority-aware read-only status (list/status v2)

`list-harness-env.ps1` and `status-harness-env.ps1` now emit schema 2 documents carrying one shared
read-only `Authority` object: the route, exactly one recommended next operation, a redacted
`HomeAuthorityKeyLabel`, controller match, recovery status with unfinished transaction ids,
root-claims/state/pair statuses, a state summary (environment, generation, last operation kind,
receipt reference and hash, lock and overlay hashes), per-platform live-root purity, lock-bound live
parity, the legacy schema/gap/drift/old-lock/parity block, and the frozen intended-root branch
(MetadataOnly, `UNPROBED`, redacted requested-root label, present only for initial/migrate/adopt).
Rows carry `ReasonixSkillCount`, `Active` gains `Source` and drops the clone-local `BackupReference`,
and status accepts `-ReasonixLiveSkillsPath` only while no claims exist. Both kinds are registered
artifacts with fifteen fixtures and the `Test-HarnessEnvAuthorityDocumentSemantics` validator, which
recomputes the route with the same frozen decision function used by the producer.

Routing is a single pure function: unfinished live journals win first; corrupt or unvalidatable
claims are manual; a valid pair is activate on the current controller, takeover on a foreign
controller only with passing state-bound live parity, and `controller-owner-action-required`
otherwise; valid claims with a corrupt or missing state repair-adopt; with no claims, complete
internally consistent legacy evidence with a byte-verified old lock and passing old-live parity
migrates, untrustworthy evidence adopts as untrusted, and only fully pristine roots start initial.
The new `harness-authority-status-common.ps1` composes the readers, controller fingerprint, parity,
legacy assessment and the lock-free journal scan; it takes no lock and writes nothing but the
requested `-JsonPath` document.

Verification: authority 223/223 in 31 s (including a 388,800-combination route matrix and a
whole-tree zero-write snapshot); harness-env 131/131; task-skills 22/22; agent-dotfiles 16/16;
live-plan 121 PASS; sync PASS; artifact validation 31 contracts / 31 positives / 133 negatives PASS;
seams 56/56 after re-pinning (reflection-sensitive 15068 after the parse-gate extension, dynamic digest `66456c02...`); parse gate
169 files; secret scan clean; `git diff --check` clean. A bounded read-only review returned ten
findings (one P1: a healthy-authority crash in the status surface, now fixed and covered by the
extracted `Get-HarnessEnvAuthorityActiveSummary`; two P2: parity ignoring the claim's resolved roots
and malformed legacy evidence throwing instead of reporting CORRUPT) — all ten are fixed in
`fac75cc`. Implementation commits: `2e6cb85` the v2 contracts and producers, `46e447b` the
route-matrix and CLI tests, `fac75cc` the review fixes.

The unified regression over the full catalog (launched on the `fac75cc` tree at
2026-09-13T17:22:11Z) reported `Test summary: PASS; discovered=39; passed=39; failed=0;
timed-out=0` in 7105.4 s; its external summary SHA-256 is
`61c766f0dcc03391fe47262106eecb19f6ce330e951891e9548727b8846e55e7` (deleted after this record) with
a post-run mtime of 2026-09-13T19:20:35Z. The only production change made while it ran was the
parse-gate parameter-name check (no suite invokes that script) plus additive assertions in
`tests/harness-env.tests.ps1`, and that suite ran afterwards with all 131 assertions, so the pass
holds for the final tree. The whole-phase definitive pass remains with the Task 9 checkpoint. Production interlock is unchanged and no real home, authority
state, or live root was written.

## Phase 3 Task 4 (2026-09-14): the authority apply composition

Settled decision: the private prefix belongs to the reviewed canonical setup
flow (its own final setup state requires those roots), so adopt/migrate require
a `canonical-ready` repo and a COMPLETE prefix instead of bootstrapping a second
creator; the apply fails closed with the canonical status token. The live
transaction host admits `adopt`/`migrate`/`repair-adopt` with per-kind guards
(first authority without the live-pristine requirement; repair with claims
byte-bound and a MISSING or CORRUPT state tolerated), first-authority claims
creation covers adopt/migrate, and the backup receipt pre-images the authority
state and claims for the kinds that still have those bytes. The authority
`-Apply` composes interlock, static plan gates, the canonical and prefix
preconditions, per-platform staging/capability evidence, then the host.

All three transitions run end to end in the sandbox: adopt publishes the
immutable claims and the schema 3 state and materializes the absent Reasonix
root while preserving unknown live directories; migrate binds the exact legacy
locator/bytes/lock hashes and installs the current build; repair-adopt replaces
a CORRUPT state **and** creates a MISSING state next to byte-identical claims.
Step 5's four failure classes are pinned as hard-killed windows
(`RECEIPT_FINALIZATION`, `PREPARED`, `STATE_REPLACE_PENDING`, `TERMINAL_RECORD`)
with their live/claims/state/result evidence and the fail-closed refusal of the
next apply. Four real defects were found and fixed on the way: the producer fed
the immutable claim rows into `TargetContextIntent.Rows` (stale
`MissingRemainder` → the host re-created an existing parent directory and the
verification then failed closed), the claims branch keyed on `PairStatus`
instead of `ClaimsStatus` (so repair-adopt never took the existing claims), a
MISSING-state snapshot tripped a null-vs-empty guard, and a completed
predecessor's swap-old blocked the next transaction's staging (reclaimed at
transaction start, only for this plan's own target names, after the namespace
showed no unfinished transaction). The reviewed delta also added the
claim-identity drift refusal (`authority-claim-identity-drift`) and the receipt
preimage existence guard; the engine's evidence-preserving swap-old contract is
unchanged.

Verified: authority 369/369 (fixture seeds the private prefix, a canonical setup
state and its root claim, the schema root; covers adopt/migrate/repair-adopt
CORRUPT+MISSING, the takeover DryRun for a foreign controller with verified
parity, the drift refusal, and the four injection windows); live-plan 121 PASS;
sync, live-recovery, live-concurrency, backup-recovery, backup-receipt,
canonical-transaction 64/0, canonical-transaction-apply 21/0,
transaction-journal-exact-byte 12/0 all PASS; artifact validation 31/31/133
PASS; seams 56/56 re-pinned (reflection 15281, digest `ace4d878...`, dynamic
digest unchanged `aafc071a...`); parse gate 171 files; secret scan and
`git diff --check` clean. An independent read-only review of the delta confirmed
the row/claims/action bindings and the injection windows and produced the drift,
preimage, dead-branch and takeover-coverage findings, all adopted. Commits
`d7e81b1`, `d1ee128`, `0959a80`, `9676c7b`, `7ab55df`, and this window's fixes.
Production Apply remains interlocked.

## Phase 3 Task 5 (2026-09-14): controller takeover

The controller identity is now `Get-CanonicalControllerIdentity`: the
credential-free `origin` projection (`Get-CanonicalNormalizedRemoteIdentity`
strips userinfo and query/fragment text, lowercases scheme/host, drops a trailing
`.git`, normalizes scp-like and local forms, and reports `none` without a
remote) combined with the Git-common-dir private repository identity, so linked
worktrees share one controller and a fresh clone of the same remote is a
different controller. Every controller-fingerprint producer and consumer uses
it; the canonical repo identity keeps owning journals/claims/recovery.

Takeover requirements: the DryRun keeps routing through the read-only
assessment (valid pair, passing state-bound lock parity against the live managed
trees, no pending recovery, unknown/`.system` markers bound, no materialization
root), refuses while the current controller owns the authority, and refuses a
name the authority does not select (`authority-selection-name-mismatch`). A
foreign controller with failing parity still routes to
`controller-owner-action-required`. The retirement producer now refuses a state
that names another controller (`controller-owner-action-required`), closing a
forward-migration trap where its payload (current controller) and its intent
(state's controller) could only disagree later at apply.

The state-only apply is wired: the host admits `controller-transition`, keeps the
canonical → witness → global lock order, re-proves parity under the lock (plan's
previous fingerprint equals the locked state's, this repository's controller
differs, and the plan's intent fingerprint is that identity), publishes a
`TransactionMode=state-only` header with `ReceiptRef=NO_LIVE_MUTATION` and no
receipt intent, runs `Invoke-SealedLiveTransactionStateOnly`, and returns the
committed hashes with no receipt. The host also reclaims this plan's own
home-scoped staging scratch at transaction start (after the namespace proved no
unfinished transaction), which fixed two real consecutive-transition defects: a
completed predecessor's `swap`/`staged` content and its
`state-recovery/current-env.preimage.json` copy both blocked the next
transaction's staging/state-replace preconditions while the engine's post-commit
preservation contract stays intact.

Verified: authority 405/405 (takeover Apply state-only, replayed-takeover parity
refusal, wrong-name refusal, plan-layer `ReceiptRef`/`ReceiptId` rejections,
state-preimage disappearance refusal without a journal namespace, and a public
`STATE_REPLACE_PENDING` kill window leaving the previous controller bytes
byte-identical with `FILE_REPLACE_INTENT` as the last durable record); the
engine-level state-only kill/recovery matrix stays with the Phase 2 live-recovery
suite (PASS); canonical-recovery 118/0 with the new controller-identity and
credential-free projection tests; sync, live-concurrency, backup-recovery,
backup-receipt, canonical-transaction 64/0, canonical-transaction-apply 21/0,
transaction-journal-exact-byte 12/0, live-plan 121 all PASS; artifact validation
31/31/133 PASS; seams 56/56 re-pinned (reflection 15321, digest `9f1b3bc9...`);
parse gate 171 files; secret scan and `git diff --check` clean. An independent
read-only review of the delta confirmed the identity projection, the host
branch and the reclaim, and produced five findings, all adopted. Production Apply
remains interlocked.

## Phase 3 Task 7 (2026-09-14): three-platform, plan-bound task overlays

`scripts/task-skills.ps1` is a plan producer + consumer for the tracked task
overlay. All three platform baselines are required in the shared state and the
bound lock; a missing or legacy schema 2 baseline refuses as migration/
manual-review, never as an empty addition-only overlay. `-Automatic` and the
`-SkipBuild`/`-SkipSecretScan` gates are post-interlock refusals, and
`-TaskOverlayPath` other than the tracked `.agent-harness/task-skills.psd1` is
refused. ensure/sync/close DryRun writes one external create-new
`OperationKind=task-overlay` plan (generator `scripts/task-skills.ps1`; the plan
spec and schema now agree) plus the `<plan-stem>.candidate.psd1` artifact whose
hashes the `TaskOverlayEvidence` binds; Apply consumes only that plan through
the interlock → static gates → canonical/authority → consumption → pre-state and
candidate artifact → capability → host chain, and never rewrites the overlay
from memory (a missing candidate is refused with the candidate-artifact mismatch
token).

The tracked overlay file is journalled as a planned atomic file target
(FILE_PREPARED → FILE_REPLACE_INTENT with a re-observed pre-state → swap-old
capture with hash verification → install → FILE_REPLACED → postcondition
re-hash; raced editor/checkout bytes are put back and fail closed, and the
install instant is flagged so a post-install failure can never read as a clean
restore). The new worktree overlay lock sits in the worktree's own Git
directory and is acquired in the reviewed canonical → overlay → global order on
both the forward and the recovery paths; the header binds
`WorktreeOverlayLockKey` (frozen optional field) and the dispatcher revalidates
it, so a linked-worktree dispatch fails closed. The recovery plan binds the
overlay lock identity, the restore row (hash-shaped TargetId, schema-valid), the
preimage copy and the swap-old locator; rollback restores the preimage bytes,
including the swap-window form (target absent, evidence complete), and abandon
refuses a journal whose overlay bytes moved. `schemas/artifact-contracts.psd1`
and the frozen journal/rollback shapes are unchanged (the overlay rows reuse the
allowlisted `TargetKind=state` and are distinguished by their exact path).

Three integration defects were found and fixed on the way: the overlay swap
scratch was created inside the canonical contract root (whose immediate children
the held namespace witness pins), breaking the lock release with `canonical
contract-root inventory drift` — it now lives under the worktree Git directory;
the overlay restore rejected legitimate state-rollback plans and refused the
swap-window form; and the recovery dispatcher used an underived
`$authorityStatePath`. An independent review produced twelve findings; the four
high ones (post-install misclassification, the overlay-key refusal, the
state-only `FILE_REPLACED` semantics rule now path-aware, and the abandon guard)
and the actionable lows (schema-shaped row id, swap-window restore, plan-row
comparison, the undefined-variable throw, the mandatory canonical handle, the
`.system` postcondition failure, staged-temp cleanup, and the test pin that
passed for the wrong reason) are all adopted.

Verified: task-skills 93/0 (three-platform baseline matrix and status, the
Reasonix ensure → baseline → sync → close path, baseline refusals, producer/
consumer semantics, the tracked-file journal records with retained preimage and
swap evidence, the consumed-plan replay refusal, the changed-overlay-after-
preview refusal, stale materialization, the missing candidate artifact, the
`FILE_REPLACED` hard-kill window, the blocked next apply and preview, recovery
dispatch from a linked worktree, second-holder overlay-lock `operation-lock-busy`,
lock-free status, and preview never waiting on the overlay lock); live-recovery
PASS; harness-env 311/0; harness-authority 406/0; sync PASS; agent-dotfiles 23/0;
automation-safety PASS; live-concurrency PASS; canonical-transaction 64/0;
canonical-transaction-apply 21/0; transaction-journal-exact-byte 12/0;
backup-recovery PASS; canonical-hard-kill-reap-semantics 27/0; `canonical-hard-kill`
**is green: 318/0.** The re-seal committed here already carried the correct
derived values (expectation values only, no check removed or loosened); the
twelve failures came from runs that predated the file's final write, and the
full suite, the primitives section (95/0), an isolated re-derivation of every
self-referential pin and the 20-case behaviour probe with zero residue all
re-verified green afterwards. `canonical-production-seams` is 56/56 in a
pristine `git archive HEAD` copy; the working tree showed 36/20 only while the
uncommitted Task 8 draft was present, so that draft is now stashed instead of
left dirty. The carried item — finishing that re-seal — is therefore closed;Task 9 checkpoint; artifact validation 31/31/133 PASS; seams 56/56 re-pinned (reflection
15668, digest `81bacf1b...`); parse gate 171 files; secret scan clean (two token
literals whose `sk-` substring tripped the OpenAI-key pattern were split);
`git diff --check` clean. Production Apply remains interlocked.

## Phase 3 Task 6 (2026-09-14): external-plan activation, exact receipt, plan consumption

`scripts/activate-harness-env.ps1` is now a plan producer + plan consumer. DryRun
(mandatory `-PlanPath`) resolves the authority root trio (explicit or
host-injected; partial selection fails closed), runs the gate chain (build-skills,
scan-secrets, build-harness-env, `Test-HarnessEnvLock`), creates and revalidates
the reviewed create-new materialization (three platform source roots including
empty subsets, env-build v3 sidecar, frozen lock schema 3), requires the
read-only route to be exactly `activate`, and writes one
`OperationKind=environment` plan bound to the live claims bytes, the
materialization lock, generation+1 and fresh observed target rows (with the
claim-identity drift refusal). Apply consumes only that plan: interlock first
(the first gate), then path/integrity/kind/generator/currency/selection/
controller gates, a pre-host `prune` refusal, the canonical and prefix gates,
the consumption gate, staging + capability hashes, then the Phase 2 host,
reporting the host's exact `ReceiptId`/`ReceiptPath`/`ReceiptHash`/state hash.
`Get-LatestBackupReference`, every `sync-backup-*` scan and every repo-local
`state/current-env.json` write/preview are gone; the legacy file stays
byte-identical while the shared authority state is what the transaction
installs. The `environment` kind gained its public generator in the plan spec
and schema, the host admits it, and its receipt now pre-images the authority
files so the receipt-based rollback surface is eligible.

Plan consumption landed here (the carried Task 4/5 item):
`Get-SealedLiveTransactionTerminalDocumentHashes` collects the
`OriginalDocumentHash` of every terminal journal namespace, and the activation,
authority and sync apply paths pass it to
`Assert-LiveSyncPlanDocumentHashNotConsumed` after the canonical/prefix gates and
before staging, so a completed plan cannot mutate twice; the replay refusals in
all three surfaces assert `live-plan-consumed`.

Recorded narrowing for Task 7: the task-overlay CLI's preview/apply paths fail
closed (`activation-root-selection-incomplete`, `overlay-plan-required`) instead
of delegating a gate-chain preview that no longer exists; the task-overlay plan
producer, its roots and the worktree overlay lock are Task 7 Step 3 work.
`docs/README.md` §16 now documents the producer/consumer contract and the
legacy-state change.

Verified: harness-env 311/0 (producer/consumer matrix for empty/single/multi
subsets across all three platforms plus the full failure matrix and the
consumption replay), harness-authority 406/0, task-skills 22/0, live-plan 121,
sync/live-recovery/live-concurrency/backup-recovery/backup-receipt PASS,
canonical-transaction 64/0, transaction-journal-exact-byte 12/0,
agent-dotfiles 23/0, home-authority PASS, private-path-boundary PASS, artifact
validation 31/31/133 PASS, seams 56/56 re-pinned (reflection 15423, digest
`3e19718c...`), parse gate 171 files, secret scan clean (a token whose `sk-`
substring tripped the OpenAI-key pattern was renamed), `git diff --check` clean.
An independent read-only review produced nine findings; all adopted except one
recorded item (an activation plan is not bound to a specific authority
generation, mirroring the reviewed Task 4/5 transitions). Production Apply
remains interlocked.

## Phase 3 Task 3 (2026-09-14): the `env authority` command surface

`scripts/authority-harness-env.ps1` adds `status|migrate|adopt|repair-adopt|takeover`, routed by
`agent-dotfiles.ps1 env authority`. Status is strictly read-only and prints the single route with its
recommended next operation plus the claims/state/pair, recovery, legacy, parity and intended-root
facts. Each transition takes exactly one `-DryRun|-Apply` with an external `-PlanPath`: DryRun
validates that the requested action equals the route the read-only assessment emits, binds the
operation-specific context (migrate: exact legacy locator/hash/core hash/old lock hash and the
legacy-recorded name; adopt: MISSING or UNTRUSTED legacy evidence; repair-adopt: the CORRUPT or
MISSING state-evidence oneOf; takeover: `controller-transition` with the previous controller
fingerprint and `ReceiptRef=NO_LIVE_MUTATION`), creates a create-new environment materialization
where the branch needs one, and writes a create-new plan validated through the reviewed
`Assert-LiveSyncPlanDocumentIntegrity` gate. Apply consumes only that exact existing plan: the
production interlock is the first gate, then the plan path, envelope, materialization currency,
selection context and consumption state; at the Task 3 boundary it still stopped at
`authority-apply-not-wired`, which the Task 4 slice replaced with the reviewed host composition.

Supporting refactor: the producer primitives moved from `sync.ps1` into
`scripts/live-plan-evidence-common.ps1` (behavior unchanged; live-plan 121 PASS, sync PASS), and the
frozen sync-plan shape admits `scripts/authority-harness-env.ps1` as a second generator for the four
authority branches while the sealed fixtures keep their own.

Verification: authority 290/290 (sandbox CLI matrix over the dispatcher, plan paths, DryRun/Apply
discipline and all four transitions); agent-dotfiles 23/23; harness-env 131/131; task-skills 22/22;
live-plan 121 PASS; sync PASS; artifact validation 31/31/133 PASS; seams 56/56 re-pinned (reflection
15245, dynamic digest `26697519...`); parse gate 171 files; secret scan and `git diff --check` clean.
The parameter-name gate added in Task 2 caught three real defects here. Commits: `2d6bdf0` the
shared-module refactor, `bdf9073` the command surface.

## Task 7 carry-over closed (2026-09-15): the rollback composition reclaims its own staging scratch

Committed as `d6211c9`. Phase 2 Task 7 Step 4 requires "cleanup swap-old/staged/pre-rollback copies
only after complete success; preserve all durable receipts/evidence on restore failure", and the
rollback composition reclaimed nothing. `Invoke-SealedEnvironmentRollbackTransaction` now calls a
new private `Remove-SealedEnvironmentRollbackStaging` after the engine returns, so deletion is gated
on three re-proven facts rather than on the call simply returning: the engine returned normally; a
fresh journal-chain read shows exactly one terminal `Phase=COMPLETE` record (`Outcome=committed`,
`ClosingKind=original`) with a matching committed result and this plan's
`OriginalPlanHash`/`OriginalDocumentHash`; and the reviewed chain validator accepts
header+records+result. Anything else reclaims nothing and still returns the committed result, so a
reclamation error can never turn a committed transaction into a reported failure.

In scope are only this composition's own leaves: the `staged`/`swap` entry of each reviewed engine
target row, the path derived from the row as `<own platform staging root>/<area>/<target name>`
rather than discovered by scanning, and its own state-recovery preimage copy, admitted only after
`Test-SafePathInsideRoot` proves it sits inside the composition's own staging roots.
`Assert-NoReparseExistingChain` refuses to follow a reparse point, and the journal, both receipts
(including the source activation receipt and its snapshot trees) and the authority state/claims are
never touched. `tests/backup-recovery.tests.ps1` grew from 155 to 188 assertions: the success-path
reclamation assertions plus a failure-preservation section covering both the `failed-restored`
restore path and the recovery-required path, where live bytes, swap-old and staged entries, the
pre-rollback copy and both receipts all survive. Verification: backup-recovery PASS 188;
harness-env 311/0; canonical-production-seams 56/56 at this commit, its re-pin derived by
reproducing the suite's all-scripts inventory (byte-identical to the tracked baseline at the
previous commit) and reviewed site by site — reflection-sensitive 15668 → 15701 (the then-current
pin; later commits moved it to 15784, see the G4 record) with all 33 added
sites being member/dispatch inventory entries of the new code, zero new reflection types and zero
new `Add-Type`/`Get-Command`/`Invoke-Expression` sites, and the dynamic-command digest unchanged.

## Phase 3 Task 8 (2026-09-15): selection-aware preview routing for the pinned runner

Task 8 is complete at 4/4 steps and committed as `2ca0488` (implementation by the
concurrent 2026-09-15 session, integrated and verified by the coordinator):

- **Step 1 — extended approved toolchain bundle.** `scripts/runner-policy.psd1`
  now pins the authority/status/materialization/planner dependencies
  (`harness-profile-common`, `harness-authority-status-common`,
  `live-transaction-common`, `backup-receipt-common`, `status-harness-env`,
  `list-harness-env` plus the harness-env-build/-lock/-list/-status and
  live-journal schemas) and carries a frozen `PreviewRouteActions` table whose
  keys are exactly the authority routes. `scripts/setup.ps1` refuses to approve a
  runner whose table differs from `$script:HarnessEnvAuthorityRouteNextOperation`
  or whose row would materialize a build for a diagnostic route, so the hooks
  never self-approve and toolchain drift keeps failing closed with
  `runner-review-required`.
- **Step 2 — routing from shared authority.** `scripts/auto-sync-after-git.ps1`
  routes each trigger from the canonical/authority state: a pristine home
  materializes the named `full` environment through env-build v3 into user-temp
  scratch and emits only the non-consumable initial preview plus the exact
  external `env activate full -DryRun -PlanPath <external-user-artifact>`
  command; a non-pristine home emits only the adoption diagnostic with the
  user-selected-name placeholder; recovery/manual/repair-adopt/takeover/migrate
  and `controller-owner-action-required` routes are diagnostic-only with zero
  materialization; drift in the extended bundle fails closed before any routing.
- **Step 3 — preview/event-only triggers.** Every routed change writes a
  validated non-consumable pending preview/diagnostic event (never `-Apply`, never
  an internal Apply plan path) and marks drifted prior previews stale through
  sidecars while the prior preview file stays byte-identical.
- **Step 4 — clones/worktrees.** The fixtures drive the routing from the
  controller checkout and from a linked worktree (`git worktree add`), asserting
  zero home writes and no repository materialization on the diagnostic branches.

Verified after `2ca0488`: approved-runner PASS, automation-safety PASS (the
routing matrix incl. the setup refusals, the initial preview, the stale sidecar,
the adoption diagnostic and the zero-write fingerprints), harness-authority 430/0
(the route-table/bundle assertions), backup-recovery PASS (`d6211c9`, which also
reclaimed the environment-rollback staging scratch after success — the Task 6
carried item), task-skills 93/0, live-recovery PASS, sync PASS, agent-dotfiles
23/0, canonical-hard-kill 318/0, reap-semantics 27/0, artifact validation
31/31/133 PASS, seams 56/56, parse gate 171 files, secret scan and
`git diff --check` clean. Production Apply remains interlocked.
## Phase 3 Task 9 (2026-09-15): the Phase 3 checkpoint

Task 9 is complete at 5/5 steps on the tree committed here (the checkpoint commit
follows `2ca0488`/`d6211c9`; the working state is otherwise unchanged).

**Step 1 — focused suites** (all green before and after the checkpoint edits):
`harness-authority` 432/0, `harness-env` 311/0, `task-skills` 93/0,
`automation-safety` PASS, `agent-dotfiles` 23/0, plus `approved-runner` PASS,
`backup-recovery` PASS, `live-recovery` PASS, `sync` PASS,
`canonical-hard-kill` 318/0 and `canonical-hard-kill-reap-semantics` 27/0.

**Step 2 — emitted artifacts**: `scripts/validate-json-artifacts.ps1 -All` PASS
(31 contracts, 31 positives, 133 negatives) over env-build 3, lock 3, state 3
`oneOf`, root claims, list/status 2, the environment/task-overlay/authority/
retirement plans, receipts, journals and live-operation-result v1; the negative
fixtures fail at their declared layer.

**Step 3 — the full runner and the non-suite gates**:
`pwsh -NoProfile -File scripts/run-tests.ps1 -All -JsonSummaryPath <external
create-new path>` → **`Test summary: PASS; discovered=39; passed=39; failed=0;
timed-out=0`** (external create-new summary phase3-task9-unified-rerun-20260915-123558.json, SHA-256 `033daf312a9a0bb38bb71326d4ce966150d6589108f4d283066aa2f29dec77b1`, requiredJobTimeoutSeconds 25785) (the first attempt of this checkpoint read
`passed=36; failed=0; timed-out=3` because `harness-authority` (300 s),
`harness-env` (180 s) and `task-skills` (120 s) had budgets smaller than their
post-Task-8 runtime; the budgets were raised to 900/600/900 s and the CI job
timeout from 400 to 460 minutes — the runner's own
`SetupAndNonSuiteBudgetSeconds + Σsuite budgets + margin` computation demands
430 — and the rerun is the PASS above). Non-suite gates: parse gate 171 files;
`doctor.ps1 -HomeRoot <isolated> -SkipSecretsScan` PASS (19 PASS/10 WARN/0 FAIL);
`build-skills.ps1` PASS with the build-leaves-Git-clean proof (0 unexpected
untracked files, 0 tracked generated output); secret scan clean; artifact
validation PASS; dangerous tracked-file scan 0 violations over 569 files; and
`git diff --check` run with exactly the four protected Reasonix literal negative
pathspecs (`.reasonix/desktop-topic-auto-title-meta.json`,
`-created-at.json`, `-title-sources.json`, `-titles.json`), which are untracked
leaves whose contents were never opened, hashed or committed (the same scan sees
no tracked `.reasonix` entry, and the adjacent-file probe stayed visible).

**Step 4 — requirements and quality reviews.** An independent read-only Phase 3
requirements review covered design compliance, the artifact DAG, state
replacement/recovery (including the new overlay file target), route exclusivity
(388,800-combination matrix), controller identity, root immutability, overlay
transactionality and selection-aware pinned planning, and reported compliance on
all eight axes with four low findings. Adopted here: the migrate `-Apply` legacy
locator is now required and validated against the exact repo-local path (with
two new refusals pinned in `harness-authority`), the setup approval path now
pins the route *command* to the frozen next operation (not just the action
class), the Task 4 record's apply-order sentence was corrected, and the stale
`Current checkpoint` section is marked as Phase 1 history. Both fixed right
after this checkpoint: (G2) an orphan schema-3 state without claims now routes to
`manual-recovery-required` instead of recommending initial/adopt (which the host
refuses), pinned by three new `harness-authority` assertions at 435/0; and (G4)
the environment-rollback entry now acquires the worktree overlay lock in the
reviewed canonical -> overlay -> global order (a foreign identity fails closed
as `rollback-origin-mismatch (overlay lock)`) and runs the reviewed plan through
`Invoke-SealedEnvironmentRollbackTransaction`, with the obsolete token gone and
backup-recovery/live-recovery/seams re-verified. The transition itself still
waits behind the production interlock, which owns the Apply refusal because the
composition always passes its `-RepoRoot`, which is outside the sandbox root. The `worktree-overlay-lock-not-implemented` token this step still observed was removed by
the G4 follow-up recorded below, so the rollback entry is now reachable rather
than token-refused and the remaining refusal is the interlock itself. The Phase 3 Task 8 change
set was reviewed separately (four findings, all addressed: the command pin, the
user-temp scratch wording, and two test-coverage tightenings).

**Step 5 — real authority/live state untouched**: every suite and every
transition ran inside sandbox homes/repos under the injected capability; no
production Apply/rollback/retirement ran, `scripts/live-safety-policy.psd1` is
unchanged (`ProtocolVersion=3`, `ReleaseState=interlocked`), and no tracked file
under the live home or the machine-private paths was written by this work.
### Post-checkpoint follow-ups (2026-09-15)

Both review follow-ups are fixed and committed, and a fresh definitive run on
the resulting tree reads `Test summary: PASS; discovered=39; passed=39;
failed=0; timed-out=0` (external create-new summary
`phase3-followups-unified-20260915-160911.json`, SHA-256 `f382edfb...`).

- **G2** (`872ad03`): an orphan schema-3 state without claims routes to
  `manual-recovery-required` instead of recommending initial/adopt.
- **G4** (`976d0fe`): the environment-rollback entry acquires the worktree
  overlay lock in the reviewed canonical → overlay → global order and runs its
  reviewed plan through `Invoke-SealedEnvironmentRollbackTransaction`; the
  obsolete `worktree-overlay-lock-not-implemented` refusal is gone, a foreign
  overlay identity fails closed as `rollback-origin-mismatch (overlay lock)`, and
  the transition itself stays behind the production interlock (which owns the
  Apply refusal because the composition passes its `-RepoRoot`, outside the
  sandbox root) until the protocol is released.

With these closed, the only remaining roadmap item is **Phase 4** (schema/CI
contract and safe release): it needs the production interlock released and the
real-machine read-only/dry-run validation, which is reserved for the user's
explicit authorization.
## Session wrap-up (2026-09-15 morning; superseded later the same day)

> **Superseded.** This section is the red-state snapshot of the 2026-09-15 morning sessions. Every
> item it lists as open was closed the same day: the `canonical-hard-kill` re-seal by `06d1902`
> (318/0), the Task 8 draft by `2ca0488`, and the Task 9 checkpoint by `e57c608`. The inline
> corrections inside the section mark which sentences are the morning snapshot and which are the
> later findings; read them as history, not as open work.

Task 7 is committed as `b86b8b1` (production, tests, and records, with its twelve
independent-review findings adopted); see the Phase 3 Task 7 section above. This section is the
wrap-up snapshot of the 2026-09-15 sessions that followed; the interim cross-session handoff file
was folded in here and removed.

**The `canonical-hard-kill` re-seal is resolved (2026-09-15, later the same day): the suite is
green at 318/0.** Verified by a full run, the `-Section primitives` subset (95/0), the
reap-semantics suite (27/0), an isolated re-derivation of every self-referential pin (24 prelude
rows and digest, the 27-root pre-section token digest, all 28 `Require-ReviewedFunctionHash` extent
pins, the function-inventory digest, the cleanup-gate self digest, the controller-surface sha and
the header digest - all matching) and the behaviour probe's exact 20-case set with zero residue.
The twelve failures reported at the Task 7 boundary came from runs that predated the test file's
final write (one stale pin invalidates the cleanup contract, which empties the behaviour-probe
result set and fails its eleven dependent assertions); the re-seal committed in `b86b8b1` was
already correct, and `canonical-production-seams` is 56/56 in a pristine `git archive HEAD` copy
(the working tree read 36/20 only while the uncommitted Task 8 draft was present, which is now
stashed). The account below is the red-state snapshot as it stood before that verification:
**Red-state snapshot (superseded by `06d1902`): the `canonical-hard-kill` re-seal was open and the
suite was red** (12 stale self-seal digest pins at the Task 7 boundary; the pins had drifted since
Task 5/6, where the suite was not re-run). A breakpoint-instrumented diagnostic run of the unmodified suite,
launched 2026-09-15 06:47 +0800 by the prior session, was found dead at ~08:04 without writing
its completion marker — the second vanishing run that day. Its surviving value is the dump
written through 07:29 to the machine-local `%TEMP%\hk-bp-out.txt`: the live behavior probe
passes 20/20 with zero residue and a valid validator self-test, while the held engine and host
validation probes refuse to launch on static preflight gates
(`behavior-child-primitive-authority:behavior-child-primitive-source-literal`,
`behavior-probe-contract:probe-case-flow-route-parameters`; all 20 cases not run in each), and
`behaviorFailedCasesExact=False`. The wrapper captured no suite-level verdict (console output
was lost with the prior session), so the next attempt must run the suite with captured output.
The dependency-ordered re-seal helper `tmp/reseal-hard-kill.ps1` (gitignored, machine-local)
still has the pre-existing parse error around its lines 100/107 and must be fixed or rewritten
before the next re-seal attempt.

Correction (2026-09-15, later the same day). The "found dead" reading above is wrong, and so is
the sentence it supports: the tree was already consistent, and a run that is said to be dead is
not evidence about the current tree until it is re-verified. The 06:47 run's successor was launched
at 07:49 and was still alive and actively starting checkpoint hosts at 08:20 +0800 — an orphan whose
parent process had exited, writing progress to the machine-local `%TEMP%\hk-progress2.txt` while its
stdout went to an unrecoverable broken pipe, so its verdict could never have been recovered. It was
terminated so the controlled runs could proceed. Independently: every self-referential pin
re-derives clean, `-Section primitives` is 95/0, and two full runs read 318/0 (`06d1902`, and this
window's `-All` run). The re-seal helper was rewritten from the proven `tmp/reseal-safe.ps1` rather
than patched — `tmp/reseal-hard-kill.ps1` now parses cleanly (12 errors → 0) and offers a `-Verify`
mode that reports mismatches without writing plus the full ordered fixpoint re-seal.

**Red-state snapshot (superseded by `2ca0488`): Phase 3 Task 8 ("Upgrade the Pinned Runner to
Selection-Aware Preview Routing", roadmap line 270) existed at this point only as an uncommitted,
broken working-tree draft**: six files last edited
05:00-05:21 +0800 — `scripts/auto-sync-after-git.ps1` (+265), `scripts/runner-policy.psd1` (+30:
the frozen `PreviewRouteActions` route table plus six toolchain and six schema pins),
`scripts/setup.ps1` (+27: explicit setup pins the route table against the frozen authority route
set and refuses `runner-review-required` on mismatch), and `tests/approved-runner.tests.ps1`
(+46), `tests/automation-safety.tests.ps1` (+180), `tests/harness-authority.tests.ps1` (+36).
Verified at ~07:50: `tests/harness-authority.tests.ps1` 424 passed / 5 failed — the adopt,
migrate, repair-adopt, and takeover route `Command` values disagree with the frozen
next-operation mapping, and "the toolchain bundle keeps selecting only toolchain and schema
paths" rejects the new pins; `tests/approved-runner.tests.ps1` and
`tests/automation-safety.tests.ps1` die in fixture setup because `WriteAllText` on
`manifests/managed-skills.claude.txt` finds no parent directory (approved-runner line 188;
automation-safety `Initialize-Task8PolicyRepo` line 124), with the same defect class waiting at
the `harness-source/envs/` write whose parent directory is also never created — every assertion
before the fixture failure passes. The draft covers the Step 1 shape (approval-pinned toolchain
and route table); Steps 2-4 are incomplete. Do not commit the draft as-is and never `git add -A`
while it is parked; finish or revert it deliberately.

Wrap-up verification: parse gate 171 files PASS; secret scan clean; `git diff --check` clean;
the three Task 8 suites as quoted above. The harness-model closure loop was executed: no new
generalizable feedback (the double/orphaned-run observations are instances of already-recorded
lessons) and no upstream method-file drift since `194f294`, so no loop edits were made.

## Remaining roadmap snapshot

**Phase 2 is complete (52 of 52 steps accounted for: Tasks 1-9 all closed; the one proof that
could not execute — Task 6 Step 5's cross-authority overlapping-roots — is recorded as a Phase
3-bound finding rather than an open step).** **Phase 3 is complete (47/47: Tasks 1-9 all closed; the Task 7 carried cleanup item closed by `d6211c9` and the Task 9 checkpoint by `e57c608` — see the Phase 3 Task 8 section, the Task 7 carry-over section and the 2026-09-15 wrap-up section).**
Phase 4 schema/CI contract and safe release remains downstream and has not started. Before future environment planning, rebuild the stale commit-bound
environment staging locks; this does not authorize Apply.

| Phase 2 task | Remaining steps | Scope |
|---|---:|---|
| Task 1-5 | 0 | Complete |
| Task 6 | 0/5 | Complete — the cross-authority overlapping-roots proof is recorded as Phase 3-bound (the mechanism does not exist yet — see the Task 8 Step 4 finding); the canonical-interleave proof executed in Task 8 Step 1 |
| Task 7 | 0/5 | Complete — all five roadmap steps implemented and the definitive unified pass (38/38, zero failures/timeouts) recorded; production execution waits for the Phase 4 interlock release (the Phase 3 overlay lock it depended on is wired, `976d0fe`) |
| Task 8 | 0/4 | Complete as pin-able (Step 1 mid-flight zero-wait matrix, Step 2 zero-wait-by-design boundary, Step 3 the Task 6 failpoint matrix, Step 4 the transition rejection plus the recorded cross-authority finding) |
| Task 9 | 0/5 | Complete — focused suites, artifact validation, the definitive unified pass, the bounded independent review with its fixes, and the real-home non-mutation evidence |

The required execution order was Task 1 through Task 9, strictly in sequence, and Phase 3 executed in
that order: Tasks 1-9 are complete. The earlier note here that Task 8 was only an uncommitted working-tree
draft and that Task 9 remained (see the 2026-09-15 wrap-up section) is superseded — Task 8 is committed as
`2ca0488` and Task 9 as `e57c608`. The Phase 4 schema/CI contract and
safe release remain downstream and have not started. The Phase 3 plan and its per-task
step lists are in
[`docs/superpowers/plans/2026-08-09-live-safety-phase-3-shared-authority.md`](docs/superpowers/plans/2026-08-09-live-safety-phase-3-shared-authority.md).

## Next actions

1. **Task 9 checkpoint — complete** (`e57c608`, 5/5 steps). The focused suites ran
   (`harness-authority`, `harness-env`, `task-skills`, `automation-safety`, `agent-dotfiles`), the
   registered artifact validation passed 31/31/133, and the non-suite gates were reproduced: parse
   gate 171 files, secret scan clean, doctor PASS, the generated-skill build leaving the tree
   byte-identical, the machine-readable schema/build-evidence gate PASS, the pinned schema-validator
   and gitleaks caches verified, the dangerous-tracked-file check 0 violations over 569 tracked
   files, and `git diff --check` clean with exactly the four protected Reasonix literal negative
   pathspecs. The authoritative, itemised record lives in
   [`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md).
   This window's own `-All` run passed 36 of 39 suites with zero failures and three timeouts
   (`harness-authority` 300 s, `harness-env` 180 s, `task-skills` 120 s) while a second full run
   held the machine. Re-run serially on a quiet machine all three suites pass clean but do not fit
   their original budgets, so those budgets were simply too small for this machine and the timeouts
   were not purely contention: `harness-env` 311/0 in 312 s against 180 s, `task-skills` 93/0 in
   195 s against 120 s, and `harness-authority` 435/0 in 458 s against 300 s (the assertion count
   moved from 430 to 435 with the concurrent session's exact-equality route pin). The
   failure-injection flake seen once under load — the killed CLI's output file still held when the
   reader opens it, at `Invoke-AuthorityCliKilledAtCheckpoint` — did not recur on the quiet machine.
   **The definitive full-runner pass is now green**: 39 of 39 suites, zero failures, zero timeouts
   (summary `phase3-task9-unified-rerun-20260915-123558.json`), with `canonical-hard-kill` 2393 s,
   `harness-authority` 450 s, `harness-env` 303 s and `task-skills` 197 s against the raised
   budgets. That run covers the tree including the concurrent session's then-uncommitted
   enhancements, so it is a superset of the commits recorded here rather than a per-commit verdict.
2. **Carried finding — closed (`bbfa6d5`)**: `tests/canonical-hard-kill.tests.ps1:8256` held the
   operator-as-parameter defect — the condition degenerated to the first check's result, the middle
   check never ran, and the parenthesised third check ran but had its boolean consumed as an
   argument (a marker-file probe, so "two never ran" was the wrong shorthand).
   Each call is now parenthesised, the parse-gate exemption in `scripts/check-powershell-syntax.ps1`
   is retired (the reviewed table is empty), and the four self-referential pins the edit moves were
   re-sealed. Verified: `-Section primitives` 95/0 and the full hard-kill suite 318/0, both equal to
   their pre-change baselines; parse gate 171 files, secret scan, artifact validation
   31/31/133 PASS, seams 56/56 and `git diff --check` clean, with the two seams all-scripts
   baselines independently reproduced (`tmp/seams-delta.ps1 -WorktreeOnly
   scripts/check-powershell-syntax.ps1`) as byte-identical to their pinned values, so no re-pin was
   applied, and a definitive unified rerun on the resulting tree reads `discovered=39; passed=39;
   failed=0; timed-out=0` (summary `repin8256-unified-rerun-20260915.json`, SHA-256
   `3b3134d6…`). The raw run output for those gates is machine-local and gitignored (`tmp/hk-*-repin-20260915.log`);
   this entry is what the repository carries. The itemised record is in
   [`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md).
3. **Phase 2 live-safety hardening remains complete** (Tasks 1-9; see the closeout section above for
   the definitive unified pass). This window's implementation commits: `a9cb765` Task 7 Step 1
   source graph and eligibility gates, `56489e0` Task 7 Step 2 lock-ordered plan derivation,
   `2944a98` the rollback receipt producer kind, `365f8d3` Task 7 Steps 3-4 the executed rollback
   transaction, `d4b33ff` Task 7 Step 5 the env-rollback CLI surface, `34a943f` Task 8 Step 1 the
   mid-flight zero-wait matrix and the canonical-interleave proof, `4a99b0e` Task 8 Step 4 the
   transition rejection plus the recorded cross-authority finding, `24dcabe` the bounded
   independent review fixes, and the re-pin/closeout commits. The one design-bound open item feeds
   Phase 4: the cross-authority root-claim overlap rejection (a machine-wide claim store — both
   authorities commit on a shared custom root today). The rollback execution's production caller is
   closed by `976d0fe`. The authoritative, itemised record lives in
   [`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md) under
   "Pending items (2026-09-15, after the Phase 3 checkpoint and its review follow-ups)".
4. Carried boundaries: the locator stays phase-only by design, so a state file replaced without its
   `FILE_REPLACED` record surfaces as a dispatcher DryRun failure rather than a locator status; a
   live-target move whose record is still a `_pending` temp classifies as manual recovery; and the
   `RECEIPT_FINALIZATION` host checkpoint stays placement-pinned until the production host is
   child-killable. The engine's per-target drift protection is hash-based; the rollback plan's
   `Current` identity binding is recorded as not enforced by the existing ladder.
5. The stale commit-bound `minimal`, `work`, and `full` staging locks were rebuilt on 2026-09-13
   (all three reported `staging=built lock=valid` under the then-current HEAD, which `HEAD` has since
   moved away from; the generated `envs/`
   artifacts are gitignored machine-local state). This is artifact preparation only and does not
   authorize environment Apply.
6. Coordinate any other clones/forks to re-clone or rebase rather than merge the old history.
7. Keep production Apply interlocked. After a reviewed policy release, revalidate each managed
   machine independently. For retired skills still present elsewhere,
   use a new machine-local retirement JSON and reviewed bound plan; do not reuse this machine's
   deleted authorization files.
8. **Operational, needs a human decision.** Two agents wrote this repository concurrently through
   the whole 2026-09-15 window: one stashed and reverted the other's in-flight files, `HEAD` moved
   under the other five times, and two overlapping full runs caused three mutual suite timeouts.
   The work converged and nothing was lost, but if one owner per repository is intended, that is a
   scheduling decision this record cannot make. The transferable lessons are held in agent memory
   as the concurrent-session hazard note, not here. The window's ordered list is closed: items 1-4
   above record what was delivered, and the current pending set is in
   [`status/active/live-safety-hardening.md`](status/active/live-safety-hardening.md) under
   "Pending items (2026-09-15, after the Phase 3 checkpoint and its review follow-ups)".
9. **Added by the sealed-file slice window (2026-09-15, closed 2026-09-16).** Four items join that pending set: the
   privacy narrative still needs verification (`bbba28f` is described as the corrected privacy
   rewrite but is a `.gitignore` commit, and the pre-rewrite Phase 0 SHA `0a6c16e` is not in the
   current history — both left for the owner, because an inference is not evidence); the
   pre-2026-09-15 sections that still assert superseded states need a sweep, not just the banner
   the header now carries; four commits (`b791bda`, `996986a`, `fe149f9`, `5807727`) were still
   local-only at the window close, so remote CI covers `cfb3db6` at most and could not be queried
   from this machine (`gh` unauthenticated); and the global Grok invocation guide is out of step
   with its wrapper (per-directory mutex forbids the parallel read-only calls it advertises, and
   read-only mode cancels the commands a review needs).
