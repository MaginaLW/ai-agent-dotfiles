# Dispatch and review

Follow the host's global delegation, privacy, subscription-routing (`desktop_run_task` vs `spawn_agent`), concurrency, and history-fork (`fork_turns`) rules. Apply the Swarm rules below to task slicing, handoff briefs, continuous execution, and review.

## Before dispatch

Read the relevant plan or task breakdown once and reuse the existing tracker; do not require a separate planning artifact. Map sequential dependencies and ready independent work. Divide by deliverable feature, module or investigation question; assign diagnosis, implementation, necessary tests and focused verification for a package to the same executor. When inputs are incomplete, dispatch the parts that do not need them; dependent work waits for the missing decision without freezing the whole stage.

Do not impose an extra fixed small cap or minimum headcount, or split trivial work to fill capacity. Respect the host's active/concurrent allowances and avoid overlapping writes or parallel heavy checks against shared resources. Obtain human approval before exceeding an authorized concurrent limit.

Give each executor a concise, self-contained brief containing only the current-stage outcome, non-goals, confirmed constraints/invariants and ruled-out paths, exact file/command pointers, write scope, dependencies, workspace/output boundaries, authorization and acceptance checks; instruct it to return `NEEDS_CONTEXT` instead of guessing when critical context is missing. Share verified facts and label provisional assumptions rather than copying chat history. Reuse an instance for the same responsibility while its context stays light; prefer a fresh `fork_turns: "none"` instance for a new stage, required independent review, or heavy/stale context. Adapt [implementer-prompt.md](implementer-prompt.md) when useful.

Distinguish owner/platform prohibitions from stage boundaries: a read-only preparation worker can be told "inspect only; do not edit in this stage" without inventing a task-wide ban. Missing authority pauses only the affected action.

## Execute continuously

For a live Desktop team board, member mentions or a visible review chain, follow [the coordination protocol](coordination.md). Project Orchestrator is the lead. Sentinel derives version-specific review alerts from the events the board and graph display.

When new work appears, a dependency clears, an important result returns or the lead is about to wait, check `run.py status` (when using a board) and dispatch ready unassigned work. Continue independent work while agents run, starting successors from usable returned results without waiting for unrelated branches. Wait only when the next step genuinely depends on the awaited result and no other useful work can advance.

If investigations duplicate effort, multiple workers await the same decision, shared writes conflict or results accumulate faster than they can be integrated, pause the affected expansion and resolve the bottleneck while keeping unrelated work moving. Use purposeful alternative exploration only when key uncertainty warrants isolated comparison with clear selection criteria.

Inspect key changes and raw evidence from handoffs (`DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, `BLOCKED`) and reuse covered results rather than rerunning equivalent audits. Never retry an unchanged failure mechanically.

## Dual-path review and integration

Check requirements and quality together at a useful delivery boundary using one combined review pass when independent review is required or adds material confidence (adapt [reviewer-prompt.md](reviewer-prompt.md)); focused self-review suffices for routine work. Separate actual blockers from non-blocking advisory improvements.

- **Writable peer review (board gate):** When a task sets `requires_review: true` (including Teamwork `plan_review`), assign a different actor with its own writable outbox (such as another writable worktree worker) so the reviewer signs its own `approve` or `changes` event. Lead never impersonates a reviewer.
- **Read-only subscription review (host return):** When running independent review via a read-only worker (such as `desktop_run_task(..., role: "review", workspaceMode: "readonly")`), do not block the task behind an unwritable board reviewer (`requires_review: true`). Collect the verdict through the host and record the external task ID, reviewed SHA-256 digest, verdict, and key findings in Lead's `release --text` and verification report.

Fix actual blockers and recheck only affected parts. Run the smallest relevant user-visible acceptance plus mandatory checks, reserving full/shared-environment checks for their real trigger. Inspect final artifact state or `git diff`/`git status` before reporting.

## Boundaries and fallback

A success report alone is not proof. Keep commits, pushes, messages, publication, deletion, paid calls, credentials, production changes and live approvals within their actual boundaries. If delegation is unavailable or a single immediate operation would cost less inline than a handoff, execute inline with the same acceptance and review responsibilities; never spawn substitute processes solely to mimic agent roles.
