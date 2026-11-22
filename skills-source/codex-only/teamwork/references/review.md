# GSD plan, integration and milestone review

Use the levels the deliverable needs. A small package can finish at task acceptance. A multi-component milestone can make downstream reviews executable by including them as tasks in its dependency graph.

## Before releasing a plan

Start at the requested observable result. For each requirement, identify its producing task, its consuming task or user, the actual interface between them, and the verification that would catch a broken link. Check that a worker has the needed inputs before its task becomes ready. For example, if an exporter and an importer both expect the other team to define quoting rules, give the format decision an owner and make both tasks depend on its release. Check scope against the user’s constraints, including deferred decisions.

For a blocking finding, return the affected requirement/task, the exact missing action, contract or check, the consequence and a concrete repair. An always-successful check cannot demonstrate a user outcome. When the plan is an approval gate, its independent reviewer inspects the submitted plan bytes and requests changes or approves that version; release belongs to Lead.

## From a component to an integrated milestone

- **Component verification.** Work backward from a must-have. Observe the behavior through its supported entry point, inspect the produced artifact and check the connection to its real consumer. Record the version, evidence location and any unavailable check.
- **Phase handoff.** Reuse the project’s summary for the milestone audit. When the team needs a handoff format, fill the [upstream GSD phase summary](../assets/summary-minimal.md) with the provided contracts, affected consumers, artifacts, decisions and readiness. Cite commit IDs only for actual commits; a file bundle can be identified by the board’s artifact digest. Associate the claimed requirement IDs with the accomplishments.
- **Integration review.** Build a map from each producer’s released export to the actual consuming entry point. Identify unused exports, missing consumers and mismatched contracts. Exercise the complete flow, including a representative failure path when material. Report the first broken step and its affected requirement. In the example plan, the integration owner tests the exact writer and reader releases. The reviewer inspects the round-trip evidence before Lead releases the integration report.
- **Milestone audit.** Cross-reference the requirements inventory, owners’ completion summaries, and independently verified evidence including the integration report. A checked box plus a summary cannot fill a verification gap. Flag a scoped requirement missing from every verification report. Record partial or unsatisfied requirements, unresolved human checks and the first missing piece of evidence. Submit the completed [verification report](../assets/verification-report.md) with its direct input digests.

Use the GSD milestone audit’s decision table when the three records disagree:

| Verification | Owner’s summary | Requirements inventory | Outcome |
| --- | --- | --- | --- |
| Passed | Listed | Checked or open | Satisfied; reconcile an open entry with verified evidence. |
| Passed | Missing | Either | Partial pending manual reconciliation. |
| Gaps found | Either | Either | Unsatisfied. |
| Missing for this task | Listed | Either | Partial pending verification; a requirement missing from every verification is orphaned and unsatisfied. |
| Missing | Missing | Either | Unsatisfied. |

For serial independent reviews of one deliverable, give each gate a separate task. For example, `component → spec-review → integration-review` routes the second reviewer to an immutable first report. Add a direct dependency on `component` as well if the integration reviewer consumes its bytes. Assign the report owner and its reviewer to different actors. A review task’s artifact records the inspected artifact digest, inspection and disposition. Never release a failing report as a passing gate. Return it for correction, or keep it open with the recorded blocker. Approval of one digest cannot approve a revised artifact.

## Upstream

Adapted under MIT from [Get Shit Done at bdcaab2](https://github.com/gsd-build/get-shit-done/tree/bdcaab2c752d9a33a1a1ca9acf3a3c81fb991815). The dependency wave grouping follows `get-shit-done/bin/lib/phase.cjs` (phase-plan-index). The review procedures adapt `agents/gsd-plan-checker.md`, `agents/gsd-integration-checker.md` and the three-source reconciliation in `get-shit-done/workflows/audit-milestone.md`. The phase handoff is the upstream `get-shit-done/templates/summary-minimal.md` file. The verification report adapts the observable truths, artifact, key-link and requirements tables of `get-shit-done/templates/verification-report.md`. The local planner uses Python’s standard topological sorter and swarm receipts. [MIT license](../LICENSE-GSD)
