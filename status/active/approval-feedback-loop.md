# Approval Feedback Loop Execution Plan

> **For agentic workers:** Follow applicable delegation and workspace rules; execute independent tasks in parallel when permitted and useful, and review their results.

**Goal:** Make real feedback reliably recordable and make repeated low scores trigger a concrete decision before another related approval request.

**Approach:** The primary checkout was clean and unclaimed; this task owns it. Implement the helper and its integration serially. One read-only reviewer can check the candidate while the primary writer finishes documentation; no parallel writers or live changes.

**Materials:** `skills-source/shared/approval-feedback/`, `docs/README.md`, the two approval-feedback design documents, and `tests/test-timeouts.psd1`.

**Validation:** Isolated behavioral tests for recording, replay, conflicting input, same-task multiple feedback, legacy preservation, busy storage and concurrent writers; syntax, build, secret scan, full tests, diff review and remote CI. Validate proposal behavior with independent synthetic cases. Live deployment needs a reviewed dry run and owner authorization.

---

- [x] Add a self-contained PowerShell recorder inside the skill; explicit paths, source-based deduplication, exclusive lock, atomic replacement and readback; no permission decisions or background collector.
- [x] Revise receive-feedback and before-next-question behavior, distinguish independent-sample counts from repeated friction, and make missing write access visible without blocking authorized work.
- [x] Add meaningful regression tests and document invocation, privacy, legacy records and real-world effect boundaries.
- [ ] Obtain independent review, resolve findings, run the required local checks, commit and push reviewed changes, and inspect CI.
- [ ] Review the actual deployment preview; install only when its exact scope is authorized, then verify the result or report the precise pending step.

## Evidence

- Initial primary checkout: clean `main`, no active task record other than the directory README.
- Planned source, test, generated and temporary paths passed the workspace storage preflight.
- Targeted recorder regression passed, including concurrent submissions followed by source-stable replay.
- Full local tests passed: 14 suites, zero failures; logs in ignored `tmp/approval-feedback-loop/`.
- Independent read-only review covered six decision scenarios. API compatibility and lock failure classification were corrected and re-reviewed; PowerShell 7.0 itself was not installed or run.
- Actual full preview: update=3, unchanged=41, install=0, prune=0, unknown=0. No live writes yet.
