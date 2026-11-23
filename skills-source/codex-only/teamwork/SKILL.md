---
name: teamwork
description: Plan and resume coordinated multi-person or multi-agent delivery in dependency waves. Use for cross-task prerequisites, version-bound review, integration and milestone acceptance.
---

# Teamwork

Work backward from the milestone. Specify each task's deliverable, acceptance check, write paths, and upstream inputs. Assign implementation and its focused tests to one owner. Reuse the skill text and current plan already in context. Consult only the reference needed for the current step.

For executable waves, use the [plan format](references/waves.md). For an existing GSD phase, use the [importer](references/waves.md#import-an-existing-gsd-phase) to carry over its plans and checks.

1. **Review the plan.** Trace each requirement to a task and an observable check. Inspect producer/consumer interfaces, missing inputs and concurrent writes. Turn a required plan approval into a `plan_review` task. Its submitted artifact is the plan itself. [GSD review procedure](references/review.md)
2. **Find independent work.** Run `python scripts/waves.py plan.json` from the teamwork skill directory. Each output row in `waves` groups tasks at the same dependency depth. Fix reported graph or write-ownership conflicts before dispatch.
3. **Execute and resume.** Use swarm for routing, assignments, messages and review. Follow its Desktop board UI step only when the user requests it or visual inspection is needed. On resume or after a material receipt, run `python scripts/waves.py plan.json --manifest manifest.json`. Use the task statuses to find `ready` work. Read version, owner and underlying evidence for the affected tasks as needed. Dispatch within current permissions and capacity, and reconnect to the existing owner for `assigned` or `rework`. Start each successor when its own inputs are released.
4. **Verify the join.** For a required integration gate, make the integrated artifact and its user-facing check a successor to the component tasks. Bind its evidence to their released digests. For milestone acceptance, reconcile the requested requirements against task summaries, verified results and the cross-component flow. Record remaining gaps and required human checks. [Review evidence template](assets/verification-report.md)

The planner reads files locally with Python 3.10+. Its `complete` field reports accepted board tasks under this plan. The lead still checks the actual artifacts, the user’s outcomes and any separate execution or publication authority.

## Working under a Goal

When the user requests Goal-backed teamwork, use the lead chat's Goal to define the verified outcome and the approved milestones and follow-on tasks. Create a Goal only on explicit request.

On each delivery or Goal continuation, use the resume query and check existing worker handles before dispatch. Verify delivered artifacts and release accepted inputs. Continue independent approved work while a branch waits. Complete the Goal only after the approved waves and follow-on tasks satisfy the objective, integration checks and milestone acceptance.
