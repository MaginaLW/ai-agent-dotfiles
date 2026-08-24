# Project Status

Last updated: 2026-08-24

This is the repository's single global status file. Current task records belong in
[`status/active/`](status/active/); completed records belong in
[`status/archived/`](status/archived/).

## Purpose and current phase

This repository is the conservative, auditable source for Claude, Codex, and Reasonix skills
and selected project-local harness configuration. `skills-source/` is canonical; generated
runtime output is rebuilt, scanned for secrets, backed up, and deployed one skill directory at
a time. Whole-root mirroring is forbidden, unknown live skills are preserved by default, and
Codex `.system` is outside repository ownership.

The current implementation phase is live-safety hardening Phase 0. Tracked policy remains
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

Fresh unified validation on 2026-08-24 used `scripts/run-tests.ps1 -All` and an external
create-new JSON summary. The summary's raw SHA-256 is
`2a4b1ca6946c062d3b39b6b19c7d535aa3fd2ff7d5f94a9701cbb964358aec25`, and its discovery SHA-256 is
`fcff1de8746c0633a478667df5817c2a36fa5a0416cd8492c59533fc8f99993b`:

- all 30 suites were discovered, started, completed, and passed exactly once;
- failures, timeouts, duplicates, missing suites, and tree-kill failures were all zero;
- `canonical-hard-kill.tests.ps1` reached 317 passed / 0 failed inside the unified run;
- the summary passed its registered schema and semantic consistency validation.

This supersedes the 2026-08-22 28/30 result as the current repository validation state while
retaining that older run as historical evidence. The unified runner does not include the separate
PowerShell parse, canonical build, filtered secret scan, or sync dry-run gates; their fresh same-day
evidence above remains independently recorded.

This closes the complete hard-kill process/rollback matrix and the fresh unified 30-suite runner.
Production Apply remains interlocked.

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
  outside this repair. The fresh 2026-08-24 filtered working-tree scan passed without blocking findings
  (746 non-blocking keyword hints).
- Git publishing is outside this cleanup task: no push or pull request has been performed.

## Next actions

1. Keep production Apply interlocked. After a reviewed policy release, revalidate each managed
   machine independently. For retired skills still present elsewhere,
   use a new machine-local retirement JSON and reviewed bound plan; do not reuse this machine's
   deleted authorization files.
