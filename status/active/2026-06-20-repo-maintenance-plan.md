# Repository Maintenance Status Refactor Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** Establish one global status file plus explicit active and archived local-task status directories without changing skill sources, generated output, imports, or live skills.

**Approach:** Promote the existing current-state document to the repository root, archive existing historical task reports by moving them, and update only existing status references. Record repository evidence and final validation in this file as the work proceeds.

**Materials:** `docs/CURRENT_STATE.md`, `docs/README.md`, `README.md`, `AGENTS.md`, `CLAUDE.md`, `docs/archive/status-reports/`, current manifests, and the user-specified status layout.

**Validation:** Confirm the requested tree and headings, inspect `git status` and `git diff --stat`, run `scripts/scan-secrets.ps1`, and run the repository hook validation script.

---

## Task objective

Replace the fragmented status-file layout with `STATUS.md`, `status/active/`, and `status/archived/` while retaining all historical status records.

## Scope

- Promote and refresh the existing overall current-state document as `STATUS.md`.
- Keep this file as the only current local-task status record in `status/active/`.
- Move the seven tracked historical reports from `docs/archive/status-reports/` to `status/archived/`.
- Update existing documentation and agent instructions that point to the former status locations.
- Do not modify `skills-source/`, generated output, `imports/`, or live skill directories.

## Files changed

- Promoted and rewrote `docs/CURRENT_STATE.md` as the root `STATUS.md` global status record.
- Added this active task status and execution plan.
- Moved seven unchanged historical reports from `docs/archive/status-reports/` to `status/archived/`.
- Updated status references in `AGENTS.md`, `CLAUDE.md`, `README.md`, `docs/README.md`, and `docs/specs/2026-06-16-openclaw-skills-design.md`.

## Validation performed

- Confirmed the initial worktree was clean on `main` and synchronized with `origin/main`.
- Located one global current-state document and seven tracked historical status reports.
- Confirmed the repository provides `scripts/scan-secrets.ps1` and `scripts/check-hooks.ps1` as validation entry points.
- Confirmed all seven archived files retain the exact Git blob content of their original locations.
- Confirmed the global and local status files contain every required heading, with exactly one file in `status/active/` and seven files in `status/archived/`.
- Confirmed no changed path is under `skills-source/`, generated output, or `imports/`, and no operational documentation link still points to the former status locations; this migration record retains their names for traceability.
- `git diff --check` completed successfully with no whitespace errors.
- `scripts/scan-secrets.ps1` completed successfully: gitleaks and the fallback scanner reported no blocking secrets; reported keyword hints were non-blocking.
- `scripts/check-hooks.ps1` completed successfully: the auto-sync runner exists, while `post-merge`, `post-checkout`, and `post-rewrite` are not installed in this checkout.
- The installed pre-commit hook completed successfully using Git's bundled shell and reran the same secret scan with no blocking findings.
- Build and sync were not run because generated output and live skills are outside this task's scope; `sync -Apply` was not used.

## Open questions

The missing repo-local post-operation auto-sync hooks are an operational follow-up. Installing them is outside this status-only task because bootstrap may enter a guarded live-sync flow.

## Next step

Review the final diff and commit the status restructuring. After commit, move this task record to `status/archived/` only when the maintenance task is considered fully closed.

## Execution checklist

- [x] Promote and rewrite the global status document.
- [x] Move all existing historical task status files to `status/archived/`.
- [x] Update existing references without expanding unrelated documentation.
- [x] Verify prohibited paths are unchanged.
- [x] Run secret scan, hook validation, and final Git checks.
