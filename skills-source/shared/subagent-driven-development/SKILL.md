---
name: subagent-driven-development
description: Delegate independent work when its delivery benefit exceeds coordination cost and delegation is permitted. Keep small tasks and tightly coupled changes inline.
---

# Subagent-Driven Execution

Delegate bounded work with fresh, sufficient context. The lead owns integration and final user-visible acceptance.

## Before dispatch

Read the relevant plan or task breakdown once. Reuse the existing tracker; do not require a separate planning artifact. Map sequential dependencies, independent batches and a suitable concurrency level. Avoid overlapping writes and parallel heavy checks against shared resources.

Give each executor the outcome, non-goals, minimum inputs, write scope, dependencies, workspace/output boundaries and acceptance checks. Reuse already-established decisions and allocate each check to one owner; do not assign equivalent audits to both lead and worker without an independent-review requirement or concrete risk. Use implementer-prompt.md when useful, adapting it to the actual task.

Include dependencies and necessary isolated preparation in the already-authorized delivery chain. Distinguish owner/platform prohibitions from this stage's actions: a read-only preparation worker can be told "inspect only; do not install in this stage" without inventing a task-wide installation ban. Preserve the source and scope of real prohibitions; do not silently rewrite an existing ban. Missing authority pauses only the affected action, and this guidance grants no paid, credential, production, destructive or new data-transfer permission.

## Execute continuously

Continue independent work while agents run. Answer only consequential missing context. Existing authorization covers its stated finite chain; do not stop at every subtask, handoff or recoverable failure to request the same permission.

The handoff identifies the target/version, environment, covered claims, commands/results, actual output paths and gaps in the existing reply or tracker. Inspect key changes and raw evidence, then reuse covered results; do not treat integration as a reason to rerun the worker's audit. A changed dependency, conflict, unverifiable result or missing coverage triggers only the affected checks. DONE means inspect and integrate; DONE_WITH_CONCERNS means assess material concerns; NEEDS_CONTEXT means supply missing decisive input; BLOCKED means change approach or report the actual dependency. Never retry an unchanged failure mechanically.

## Review and integrate

Check requirements and quality together at a useful delivery boundary. A focused self-review is sufficient for routine work. Use spec-reviewer-prompt.md or code-quality-reviewer-prompt.md when independent review is required or adds material confidence; two separate reviewer agents and serial approval rounds are not the default.

Fix actual blockers and recheck affected parts. Advisory improvements stay nonblocking and out of scope. Required independent review, CI, security and release gates still apply. A review finding does not automatically reopen the entire plan or stop unrelated authorized work.

Run the smallest relevant user-visible acceptance plus mandatory checks. Reuse still-valid results for unchanged state; reserve full/shared-environment checks for their real trigger and run one instance per shared resource. Inspect final artifact state or git diff/status before reporting.

## Boundaries and fallback

A success report alone is not proof. Do not exceed authorization for commits, pushes, messages, publication, deletion or live changes. Keep production, paid calls, credentials, destructive actions and native approvals within their actual boundaries.

If delegation is unavailable or costs more than it saves, execute inline with the same acceptance and review responsibilities. Do not create substitute processes solely to mimic agent roles.
