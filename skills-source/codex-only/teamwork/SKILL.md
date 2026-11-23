---
name: teamwork
description: Plan and resume coordinated multi-person or multi-agent delivery in dependency waves. Use for cross-task prerequisites, version-bound review, integration and milestone acceptance.
---

# Teamwork

Treat the full skill text supplied with an invocation as already read. For a known run, follow the project and host rules, then start with `python scripts/waves.py plan.json --manifest manifest.json` from this skill directory, using the run's actual file paths. Use the task statuses to choose the next action and open only the reference or evidence it needs. If `plan_sha256` changes, refresh the affected plan content and check applicable approvals before dispatch.

For planning, reuse the current project plan where available. Work backward from the milestone and specify each task's deliverable, acceptance check, write paths, and upstream inputs. Assign implementation and its focused tests to one owner. Use the [plan format](references/waves.md) for executable waves or the [importer](references/waves.md#import-an-existing-gsd-phase) for an existing GSD phase.

1. **Review the plan.** Trace each requirement to a task and an observable check. Inspect producer/consumer interfaces, missing inputs and concurrent writes. Turn a required plan approval into a `plan_review` task. Its submitted artifact is the plan itself. [GSD review procedure](references/review.md)
2. **Find independent work.** Run `python scripts/waves.py plan.json` from the teamwork skill directory. Each output row in `waves` groups tasks at the same dependency depth. Fix reported graph or write-ownership conflicts before dispatch.
3. **Execute and resume.** Use swarm for routing, assignments, messages and review. On user request or when a specific visual check calls for the board, open it in the current chat's right panel with `mcp__codex_app__open_in_codex`. Keep task decisions on the resume query and receipts. Dispatch `ready` tasks within current permissions and capacity. Reconnect to the existing owner for `assigned` or `rework`. Verify the artifact digest and required review receipts before release. Rerun the resume query after a plan change or a receipt that changes task state. Start each successor when its own inputs are released. [Panel and receipt commands](../swarm/references/coordination.md#open-a-run)
4. **Verify the join.** For a required integration gate, make the integrated artifact and its user-facing check a successor to the component tasks. Bind its evidence to their released digests. For milestone acceptance, reconcile the requested requirements against task summaries, verified results and the cross-component flow. Record remaining gaps and required human checks. [Review evidence template](assets/verification-report.md)

The planner reads files locally with Python 3.10+. Its `complete` field reports accepted board tasks under this plan. The lead still checks the actual artifacts, the user’s outcomes and any separate execution or publication authority.

## Working under a Goal

When the user requests Goal-backed teamwork, use the lead chat's Goal to define the verified outcome and the approved milestones and follow-on tasks. Create a Goal only on explicit request.

On each delivery or Goal continuation, use the resume query and check existing worker handles before dispatch. Verify delivered artifacts and release accepted inputs. Continue independent approved work while a branch waits. Complete the Goal only after the approved waves and follow-on tasks satisfy the objective, integration checks and milestone acceptance.
