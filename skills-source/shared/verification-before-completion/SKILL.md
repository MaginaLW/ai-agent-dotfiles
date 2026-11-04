---
name: verification-before-completion
description: Verify the actual result before claiming completion, a fix, passing checks, or preparing a commit or pull request. Reuse evidence that still covers the current state.
---

# Verification Before Completion

Make each claim no broader than the evidence. A changed file, green unit test or successful agent report alone does not prove the user's result.

## Select the evidence

State the claim, target/version, environment and stopping condition in the current context or existing task record; do not create a separate verification ledger. Choose the smallest check that proves the observable result, plus mandatory project gates. Prefer the project's existing command and comparison contract, including generated-file mappings and exclusions, over an equivalent custom scan. Inspect the actual artifact, diff or output rather than relying on a report.

- Local or low-impact change: focused check and review proportional to the risk.
- Cross-component change: relevant integration or contract check and affected consumers.
- Real application, device, solver or external workflow: exercise the smallest safe user path when authorized and available. Otherwise distinguish local evidence from the unverified environment.
- Full suites, independent review and CI: run when the project or change requires them; local evidence does not replace required CI.

Do not add tests that merely repeat implementation or match prose. Meaningful regression checks should expose the original defect when safe and feasible; report reproduction limits.

## Check current state once

Run the appropriate check or reuse its still-valid result. Read the output and exit status, and stop when the claim is covered. Do not run a second implementation of the same check merely for confidence. Rerun only for a relevant change, failure, conflicting result or specific coverage gap; identify that trigger before expanding the check. Another message, handoff, review or commit boundary does not alone invalidate evidence. Required independent review and mandatory gates remain separate obligations.

Keep heavy checks single-instance on shared resources. Consolidate final requirements and quality review rather than restarting a full chain for each small edit. Correct blockers, recheck affected parts and preserve required independent review.

## Report accurately

State what changed, what was checked, the observed result and material limits. Distinguish built, locally tested, pushed, installed, actually loaded and accepted in use. An empty deployment preview proves file consistency, not adoption by every running session or faster real-world delivery.

For delegated work, inspect its actual output and evidence before accepting it. Reuse covered results after confirming their target/version, environment, command and output location; check only missing or affected parts instead of repeating the worker's full audit. When verification is unavailable, say what is unverified and why; do not claim completion beyond the evidence or invent extra approvals to compensate.
