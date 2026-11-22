---
name: teamwork
description: Plan and resume coordinated multi-person or multi-agent delivery in dependency waves. Use for cross-task prerequisites, version-bound review, integration and milestone acceptance.
---

# Teamwork

Work backward from the user-visible milestone. Give each task a concrete deliverable, a check that could fail, the paths it may write, and named upstream tasks whose outputs it consumes. Keep an implementation and its focused tests with one owner. Use the existing project plan if it already records this information. For executable waves, project its task graph into the small JSON format in [the run guide](references/waves.md).

For an existing GSD phase, use [the GSD importer](references/waves.md#import-an-existing-gsd-phase) to convert its plans and verification checks with the official frontmatter reader.

1. **Review the plan.** Trace each requirement to a task and an observable check. Inspect producer/consumer interfaces, missing inputs and concurrent writes. Turn a required plan approval into a `plan_review` task. Its submitted artifact is the plan itself. [GSD review procedure](references/review.md)
2. **Find independent work.** Run `python scripts/waves.py plan.json` from the teamwork skill directory. Each output row in `waves` groups tasks at the same dependency depth. Fix reported graph or write-ownership conflicts before dispatch.
3. **Execute and resume.** Use the sibling swarm skill for host routing, actor assignments, messages, review and the board. Run `python scripts/waves.py plan.json --manifest manifest.json` to read the current release receipts. Dispatch eligible `ready` tasks within the host's actual permissions and capacity. Reconnect to the existing owner for `assigned` or `rework`. As soon as its own inputs are released, a successor can start while unrelated branches continue. Re-read after each material receipt or restart.
4. **Verify the join.** For a required integration gate, make the integrated artifact and its user-facing check a successor to the component tasks. Bind its evidence to their released digests. For milestone acceptance, reconcile the requested requirements against task summaries, verified results and the cross-component flow. Record remaining gaps and required human checks. [Review evidence template](assets/verification-report.md)

The planner reads files locally with Python 3.10+. Its `complete` field reports accepted board tasks under this plan. The lead still checks the actual artifacts, the user’s outcomes and any separate execution or publication authority.
