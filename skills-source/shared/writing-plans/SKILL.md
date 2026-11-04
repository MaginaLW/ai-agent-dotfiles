---
name: writing-plans
description: Plan work with consequential dependencies, multiple affected components, or a real handoff. Use a short in-chat plan for routine changes; do not turn clear implementation into a document workflow.
---

# Writing Plans

Make the next useful result and its checks clear, then continue authorized execution.

## Choose the useful level

- Routine local work: keep a few steps in the conversation or existing tracker. State the observable result and necessary check; no plan file, fixed header, step timing or approval ceremony.
- Complex dependencies or handoff: write a durable plan in the project's existing location. Include the outcome, non-goals, acceptance environment, actual dependencies, affected consumers, work units and required checks.
- Planning-only request: deliver the requested plan and honor the phase boundary.

Use existing decisions and authorization. Do not create unresolved choices, alternative designs or a new spec to justify planning. Clarify only missing information that materially changes the result.

## Work units

Group work that changes together. Give each independent unit its inputs, write scope, output and observable pass condition. Name actual files, commands or source criteria when the executor needs them; detail only what prevents ambiguity. Do not repeat the whole project context in every step.

Identify the sequential chain and independent batches when parallel work is useful; choose concurrency from available capacity and conflicting write scopes. A tracker may be the plan itself; do not create a second one.

## Validation and authorization

Define the smallest check that demonstrates the user's actual result, plus mandatory repository gates. Distinguish local checks, full/shared-resource checks and real user or external-environment acceptance. Keep heavy checks single-instance where they share resources.

State finite execution boundaries for actions that need them: actual environment, object, destination, budget, recoverable failures and stop conditions. Reuse valid authorization through implementation, verification, necessary repair and explicitly included release actions. A plan does not itself authorize deployment, sending, production access or other external effects.

Reuse checks that still cover unchanged state. Consolidate requirements and quality review at a useful delivery boundary; fix blockers and recheck affected parts. Do not add repeated full review for each small step, or waive required CI or independent review.

## Finish the plan and execute

Check once that the plan covers requirements, scope, sequence and observable acceptance. Fix concrete gaps inline. Continue within authorized scope; ask only for a consequential missing decision or required authorization.

The optional plan-document-reviewer-prompt.md is for a requested or necessary independent plan review, not an automatic extra gate. Existing valid plans and checks remain usable; a template must not restart discovery, design or the full workflow.
