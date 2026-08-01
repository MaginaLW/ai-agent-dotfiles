# Plan: Task-Level Skill Hot-Plugging

> **For Codex:** REQUIRED SUB-SKILL: Use the `writing-plans` skill to execute this plan task-by-task.

**Goal:** Add a repository-shared task skill overlay so a task can start with the normal `work` skill set, add a managed skill on demand, and reproduce that addition on every computer that checks out the repository.

**Design reference:** the approved hot-plug design note in the sibling `specs/` directory.

**Architecture:** Keep `harness-source/` as the base source of truth. Read `.agent-harness/task-skills.psd1` as a small, tracked, platform-specific overlay. Merge it into the selected base environment only while building that environment. Route all live writes through the existing build → secret scan → bound dry-run → backup → apply pipeline. Git-triggered automation may apply additions only; removals require the explicit `env task close` or `env task sync -Apply` path.

**Status:** Implemented and locally verified; the optional real-home task-overlay re-attestation was intentionally not performed.

## Task 1: Add overlay data model and make environment builds overlay-aware

**Files:** `scripts/harness-env-common.ps1`, `scripts/build-harness-env.ps1`, `scripts/activate-harness-env.ps1`, `scripts/status-harness-env.ps1`, `.agent-harness/task-skills.psd1`

- Add a stable overlay path, schema validation, hashing, and base-definition merge helpers to `harness-env-common.ps1`.
- Treat an absent overlay as an empty overlay; validate `SchemaVersion`, `BaseEnv`, platform keys, bare skill names, duplicate entries, and managed skill membership.
- Make build, activation, status, and lock validation consume the effective base-plus-overlay skill set while retaining the base definition hash separately.
- Record the overlay hash and selected overlay skills in the environment lock/state without changing the existing lock schema contract.
- Add a canonical empty tracked overlay so every clone starts with the same schema and behavior.
- Verify base-only behavior remains unchanged when the overlay is empty.

## Task 2: Implement the task command surface and dispatcher routing

**Files:** `scripts/task-skills.ps1`, `scripts/agent-dotfiles.ps1`

- Implement `env task status`, `env task ensure-skill <name> -Platform <Claude|Codex>`, `env task sync`, and `env task close`.
- Require explicit `-DryRun` or `-Apply` for every mutating action; keep `status` read-only.
- For `ensure-skill`, validate the skill against the selected platform’s managed manifest, build a temporary candidate overlay, run the normal activation dry-run, and on apply atomically update the tracked overlay before invoking the normal activation apply. Restore the previous overlay if apply fails.
- Keep `close` explicit and removal-capable: dry-run first, then remove the tracked overlay only after the candidate activation passes; restore it if activation fails.
- Add nested `env task` parsing and usage text without changing existing `env list/status/build/activate/rollback` behavior.
- Ensure no command ever writes directly to live skill roots or `.system`.

## Task 3: Add safe Git-triggered cross-computer synchronization and documentation

**Files:** `scripts/auto-sync-after-git.ps1`, `docs/README.md`, `AGENTS.md`, `STATUS.md`

- Detect changes to the tracked task overlay during post-merge/post-checkout/post-rewrite automation.
- Route overlay changes through the active environment’s task-aware build and sync path.
- Allow automation to apply only addition-only changes; log and leave removal/prune changes for an explicit user command.
- Preserve the existing full-root auto-sync path when no task overlay is involved.
- Document the shared-overlay model, command examples, safety boundaries, new-machine behavior, branch/worktree scope, and the Codex app catalog refresh limitation.

## Task 4: Add focused tests and run regression verification

**Files:** `tests/task-skills.tests.ps1` and any directly affected existing test files

- Test overlay parsing, invalid data rejection, base-plus-overlay merging, lock drift detection, and empty-overlay compatibility.
- Test dry-run non-mutation, addition apply, second-home reproduction, close/prune behavior, failure restoration, dispatcher mode gates, and automatic addition-only versus removal handling.
- Run the focused task tests, existing harness environment/profile/sync/CLI tests, secret scans, skill build, and hook inspection.
- Inspect the final diff and confirm generated outputs, imports, backups, live home files, and machine-private state are not staged.

## Task 5: Commit the implementation

- Update the status record with the completed feature and verification results.
- Stage only the tracked source, scripts, tests, docs, plan, and canonical overlay files.
- Create one focused commit on the current branch; do not push unless separately requested.
- Report the commit and the exact commands needed for future task-level additions, synchronization, and closure.
