---
name: writing-plans
description: Use when you have a spec, decision, or requirements for a multi-step task, before execution
---

# Writing Plans

## Overview

Write concrete execution plans for multi-step work. This skill is for software projects, writing projects, research, operations, design reviews, personal workflows, and any task where the next agent or human needs a clear path from intent to verified outcome.

Assume the executor is capable but has little context. Give them the purpose, relevant materials, exact artifacts or locations, steps, checks, and decision points they need. Keep the plan bite-sized, practical, and free of vague placeholders.

**Announce at start:** "I'm using the writing-plans skill to create the execution plan."

**Save plans to:** `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`
- User preferences for plan location override this default.
- Outside a repo, create a normal Markdown plan in the current workspace or present the plan in the conversation if no durable file is useful.

## Scope Check

If the spec covers multiple independent outcomes, split it into separate plans. Each plan should produce one useful, reviewable result on its own.

Good scope:
- Draft and review one proposal.
- Analyze one dataset and produce one summary.
- Complete one bounded deliverable.
- Prepare one repeatable operating procedure.

Too broad:
- "Launch the whole product."
- "Fix all documentation."
- "Research every possible option."

## Work Structure

Before defining tasks, map the work into clear units. For each unit, name what it produces, what it depends on, and how it will be checked.

Use whatever structure fits the domain:
- **Artifacts:** documents, spreadsheets, slides, files, code, diagrams, notes, datasets, tickets, emails, decisions.
- **Locations:** exact file paths, Drive docs, repo areas, issue URLs, folders, or conversation sections.
- **Inputs:** source material, constraints, examples, acceptance criteria, stakeholders.
- **Validation:** tests, review checklists, calculations, source checks, visual QA, manual acceptance, or user approval.

Prefer focused units over large blended tasks. Work that changes together should be planned together; unrelated cleanup should stay out unless it is necessary for the outcome.

## Bite-Sized Task Granularity

Each task should be small enough to complete and review without losing the thread. Use 2-10 minute steps when practical.

Good step shapes:
- Read a named source and extract the required facts.
- Draft a specific section.
- Run a named command or check.
- Compare output against exact acceptance criteria.
- Revise a concrete artifact.
- Commit only when the plan is for git-tracked work and a commit is requested or expected.

## Plan Document Header

Every plan MUST start with this header:

```markdown
# [Outcome Name] Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** [One sentence describing the outcome]

**Approach:** [2-3 sentences about how the work is organized]

**Materials:** [Key source files, docs, links, data, examples, or constraints]

**Validation:** [How completion will be checked]

---
```

## Task Structure

Use this shape for each task. Adapt labels to the domain, but keep exact artifacts and checks.

````markdown
### Task N: [Task Name]

**Artifacts / Locations:**
- Create: `exact/path-or-location`
- Modify: `exact/path-or-location`
- Review: `exact/source-or-reference`

- [ ] **Step 1: Gather the needed input**

Read: `exact/source-or-reference`
Extract: [specific facts, constraints, examples, or requirements]

- [ ] **Step 2: Produce the task output**

Create or modify: `exact/path-or-location`
Include:
- [specific content or change]
- [specific content or change]

- [ ] **Step 3: Verify the output**

Check: [exact command, checklist, comparison, review, or acceptance test]
Expected: [specific pass condition]

- [ ] **Step 4: Record the result**

Update: [task tracker, plan checkbox, commit, note, or handoff]
```
````

For software tasks, include exact test commands and code snippets where useful. For non-software tasks, include the actual checklist, outline, calculation, source comparison, or review prompt the executor should use.

## No Placeholders

Never write:
- "TBD", "TODO", "fill in later", "handle edge cases"
- "Write tests/checks for the above" without saying what those checks are
- "Use appropriate sources" without naming the sources or source criteria
- "Polish this" without defining the quality bar
- "Similar to Task N" when the executor may read tasks independently

Every step must tell the executor exactly what to do and how to know it worked.

## Self-Review

After writing the complete plan, review it yourself:

1. **Coverage:** Does every requirement in the spec map to a task?
2. **Placeholders:** Are there any vague instructions or missing checks?
3. **Sequence:** Can tasks be done in the written order without hidden dependencies?
4. **Validation:** Is there an observable pass condition for each task and for the whole plan?

Fix issues inline before handing off.

## Execution Handoff

After saving the plan, hand off execution:

> "Plan complete and saved to `docs/superpowers/plans/<filename>.md`. Recommended next step: use `subagent-driven-development` so each task gets a fresh executor plus review. If this environment has no subagent capability, I can execute inline using the same checklist and review checkpoints."

If subagent-driven execution is available:
- Use `subagent-driven-development`.
- Fresh subagent per task.
- Review after each task: requirements match first, quality second.

If executing inline:
- Follow the same task order.
- Run the stated checks.
- Mark checkboxes as work is completed.
- Do not skip review just because there is no subagent.
