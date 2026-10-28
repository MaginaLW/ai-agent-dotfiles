---
name: git-review
description: Review git changes, summarize modifications, identify risks, and suggest commit messages. Use when asked to inspect diffs, review code changes, or prepare commits.
---

# Git Review

## Purpose

Review current repository changes and produce a concise risk-oriented summary.

## Steps

1. Establish the requested review scope and inspect the actual changes and relevant surrounding code. Preserve unrelated work.
2. Prioritize actionable defects and regressions; explain the trigger and impact and point to the relevant file and line. Distinguish confirmed problems from unverified risks.
3. Check whether appropriate verification exists or has run. Report tests actually run and any material gaps; do not claim a check passed without evidence.
4. Summarize the change and suggest a commit message only if requested.

## Output

- Findings first, ordered by impact, with precise locations and suggested fixes where useful.
- Brief summary and verification, including remaining uncertainty. If no actionable findings are found, say so without implying that untested behavior is proven correct.
- Optional commit message when requested.
