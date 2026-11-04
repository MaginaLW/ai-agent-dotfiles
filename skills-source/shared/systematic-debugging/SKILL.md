---
name: systematic-debugging
description: Investigate bugs, failing checks or unexpected behavior with unclear cause, especially repeated failed attempts without new evidence. Use an established diagnosis directly for routine command or environment mistakes.
---

# Systematic Debugging

Get enough evidence to identify the failing cause, make the smallest relevant correction and verify the original result. Scale the investigation to uncertainty and risk.

## Start from existing evidence

Read the actual error, relevant output and recent changes. Reuse available logs and known working examples. A clear syntax, path, encoding or missing-command error with a verified remedy can be corrected and checked directly; it does not require a new plan, formal hypothesis document or all phases below.

For an unclear issue:
1. Find the smallest safe reproduction and expected result.
2. Inspect the relevant boundaries and configuration propagation. Report presence of secrets, never their values.
3. Compare the failing path with the closest working example. Read the necessary implementation completely enough to understand the relevant contract; do not read unrelated systems.
4. Test one evidence-backed hypothesis with a minimal change, then inspect the result.

Do not guess through repeated mutations, bundle unrelated refactors or run production/paid/credential operations merely to diagnose.

## Repeated failures

If the same failure repeats without new evidence or state change, summarize what was tried and what remains unknown before another attempt. Change the question or method: narrow the reproduction, check a missing prerequisite or use a better evidence source. Explain the expected new signal briefly.

If that branch still makes no progress, stop mechanical retries and report its actual dependency; continue independent authorized work. Normal long tests and bounded transient retries with a stated purpose are not loops. Do not conclude the architecture is wrong from an arbitrary attempt count; reassess it when evidence shows coupling or incompatible assumptions.

## Correct and verify

Fix the identified cause in the authorized scope. Capture the smallest input and expected result that expose the defect; reproduce before fixing when safe and feasible, otherwise report the limit. Keep a useful automated regression when warranted, not an implementation-mirroring test for every reversible correction.

Verify the original symptom and relevant affected behavior, plus mandatory checks. Reuse results for unchanged state; full suites and shared environments follow their actual triggers and remain single-instance. A failing unrelated check is recorded separately unless it blocks this delivery.

For environment, timing or external faults, distinguish established cause from uncertainty. Add handling or instrumentation only when the current result requires it. Unknown side effects require readback before retry; missing authorization pauses only the affected action. Preserve production, paid-call, credential, destructive-operation and platform-approval boundaries.

## Conditional techniques

Use root-cause-tracing.md for a deep call stack, condition-based-waiting.md for readiness/timing issues, and defense-in-depth.md only when the diagnosed failure warrants additional validation. These are references, not extra mandatory phases. The verification above is sufficient without loading another skill solely to repeat it.
