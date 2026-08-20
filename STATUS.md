# Project Status

Last updated: 2026-08-20

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

The 2026-08-20 repair validation is:

- PowerShell syntax: 146 files passed;
- build: Claude 7, Codex 15, Reasonix 7;
- secret scan: PASS; pinned gitleaks 8.30.0 found no leaks;
- unified runner: 30 suites discovered, zero timeouts; after targeted repairs, 29 suites pass;
- `canonical-transaction-apply.tests.ps1`: 21 passed;
- `canonical-transaction.tests.ps1`: 45 passed;
- `doctor.tests.ps1`: PASS;
- `canonical-hard-kill.tests.ps1`: 100 passed, 22 planned Phase 1 RED failures remain;
- follow-up `canonical-hard-kill.tests.ps1 -Section primitives`: 74 passed, 21 planned RED
  failures remain after implementing the closed 20-case child dispatcher and its twenty unique typed
  handler leaves; the reviewed child primitive authority intentionally remains RED until its native
  behavior is implemented;
- sync dry-run: PASS, no prune or unknown directories, Codex `.system` preserved; no live write or
  Apply was performed.

The remaining hard-kill failures are implementation gates from
`docs/superpowers/plans/2026-08-14-deterministic-hard-kill-checkpoints.md`, including the sealed
transport session, parent oracle/cleanup authorities, behavior host, and native/QPC lifecycle.
Production Apply remains interlocked while those gates are incomplete.

## Current boundaries and known state

- Historical machine-private `state/current-env.json` evidence attested stock `work`; it is not a
  repository-portable current-machine claim. The 2026-08-20 sync dry-run on this machine reports all
  7/15/7 generated skills as additions, with zero prune/unknown targets and Codex `.system` present.
  No live files were changed.
- Project Harness Profiles remain project-local. They do not write global homes, install
  project-local skills, or switch global environments automatically.
- Codex `config.toml`, credentials, sessions, caches, and unrelated home configuration are outside
  this repository's sync scope.
- The MCP subsystem removal did not alter any live MCP registration.
- User-owned `.reasonix/desktop-topic-*.json` files and the live-safety planning stream remain
  outside this repair. The current filtered working-tree scan passes without blocking findings.
- Git publishing is outside this cleanup task: no push or pull request has been performed.

## Next actions

1. Complete the deterministic hard-kill checkpoint implementation until the remaining 21 RED gates
   pass; do not replace them with temporary helper APIs or weaker assertions.
2. Keep production Apply interlocked. After a reviewed policy release, revalidate each managed
   machine independently. For retired skills still present elsewhere,
   use a new machine-local retirement JSON and reviewed bound plan; do not reuse this machine's
   deleted authorization files.
