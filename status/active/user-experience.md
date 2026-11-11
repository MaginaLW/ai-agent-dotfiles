# User experience improvements

Started: 2026-11-11. Owner: current Codex task, primary checkout.
Base: `0281a86`; branch: `codex/user-experience`.

## Outcome and boundaries

Make the existing Windows/PowerShell CLI easier to discover, review and recover.
Keep explicit Apply authorization, existing exit codes, JSON contracts, secret scanning,
unknown-directory preservation and Codex `.system` protection. No live Apply, merge,
automatic repair, background metrics or new dependencies in this task.

## Plan and acceptance

1. CLI guidance: support group help in both spellings; explain config direction and
   write scope; distinguish unavailable environment-record reasons without exposing data.
   Doctor must name proven deployment blockers separately from ordinary warnings.
   Check the CLI and doctor suites plus real read-only help/list commands.
2. Deployment review: show relative file additions/changes/removals using the existing
   skill comparison, and explain environment switches and prune causes. Before combined
   Apply, run both existing dry-run planners; a config planning failure must leave skills,
   config and state untouched in an isolated fixture. Keep runtime failure boundaries.
   Check deployment suites with synthetic homes only.
3. Documentation: put first install, daily update, read-only inspection and recovery near
   the top of the README; retain maintenance detail in the manual. Explain preflight limits
   and a natural-task skill-effect check without claiming observed improvement.
4. Review the diff, run syntax/build/secret-scan and affected suites, then commit in small
   coherent stages. Run one full repository validation on the committed state (estimated
   5-15 minutes, existing per-suite budgets); no overlapping full run or live Apply.
   Verify the remote destination before pushing this single branch; inspect its CI result.

The lead is the only writer. Read-only agents advise on CLI compatibility and deployment
preflight/test design. Tests and logs use ignored `tmp/user-experience/`; process TEMP/TMP
are scoped to this task. No unrelated fixes or changes to AGENTS.md/skill bodies.

## Progress

- Confirmed the primary checkout was clean and no other active task owned it.
- Read current scripts, test contracts and workspace storage rules; storage preflight passed.
- Stage 1 implemented: group help, deploy-record reasons, doctor blocker summary and
  task-oriented README. Syntax passed; CLI suite: 61 passed, 0 failed; doctor suite passed.
  Doctor's isolated junction fixture required the normal host context. The pinned scanner
  was absent only in the sandbox's redirected cache; the unchanged host scan passed.
- Stage 2 implemented: file-level preview reuses the existing comparison, environment/prune
  explanations, and both planners run before combined Apply. Both deployment suites passed,
  including preflight zero-write failures, runtime locking/recovery, case-only paths,
  unknown/.system preservation, and one-build/two-scan gate coverage. Read-only review found
  no blockers. Syntax, build (Claude 12 / Codex 19) and secret scan passed.
- Documentation includes recovery choices, preflight limitations and natural-task effect checks.
- Full committed-state repository validation next; no live Apply performed.
