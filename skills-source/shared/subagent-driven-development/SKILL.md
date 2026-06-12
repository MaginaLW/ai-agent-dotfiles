---
name: subagent-driven-development
description: Use when executing multi-step plans with independent tasks in the current session
---

# Subagent-Driven Execution

Execute an approved plan by dispatching a fresh subagent for each independent task, then reviewing the result before moving on. The historical skill name says "development", but this workflow is useful for any planned work: writing, research, analysis, document production, operations, and software.

**Core principle:** fresh context per task plus review checkpoints gives better work than one overloaded session trying to remember everything.

**Continuous execution:** Do not pause after every task to ask whether to continue. Continue until all tasks are complete, a blocker cannot be resolved, or the plan is genuinely ambiguous.

## When To Use

Use this when:
- A written plan exists.
- Tasks are mostly independent or can be executed sequentially without heavy shared state.
- Subagents are available in the current environment.
- Each task has clear acceptance criteria or can be reviewed against the plan.

Do not use this when:
- There is no plan yet. Use `brainstorming` or `writing-plans` first.
- The work is one tiny edit that is faster and safer inline.
- The task requires one continuous conversation with the user.
- Subagents are unavailable; execute inline with the same checklist and review discipline instead.

## Process

1. Read the plan once.
2. Extract every task with its full text, context, artifacts, and checks.
3. Create a task tracker using TodoWrite, Codex `update_plan`, a Markdown checklist, or the platform equivalent.
4. For each task:
   - Dispatch an implementer/executor subagent using `./implementer-prompt.md`.
   - Give the subagent the full task text. Do not make it rediscover the plan.
   - Answer clarification questions with only the needed context.
   - After the subagent reports back, inspect the actual outputs.
   - Dispatch a requirements reviewer using `./spec-reviewer-prompt.md`.
   - If requirements are missing or extra work was added, send the task back for correction and re-review.
   - Dispatch a quality reviewer using `./code-quality-reviewer-prompt.md`. Despite the filename, this prompt covers general quality as well as code quality.
   - If quality issues matter, correct them and re-review.
   - Mark the task complete only after requirements and quality both pass.
5. After all tasks, run the plan's final validation checks.
6. Inspect git status/diff or the relevant artifact state.
7. Report what changed, what was verified, and any residual risk.

## Subagent Statuses

Implementer subagents report one status:

- **DONE:** Work completed and verified.
- **DONE_WITH_CONCERNS:** Work completed, but the subagent has doubts or tradeoffs to surface.
- **NEEDS_CONTEXT:** The subagent needs specific missing information.
- **BLOCKED:** The subagent cannot complete the task with the current plan, tools, or context.

Handle statuses deliberately:

- For **DONE**, review before moving on.
- For **DONE_WITH_CONCERNS**, read concerns before review; decide whether to revise, accept, or ask the user.
- For **NEEDS_CONTEXT**, provide the missing context and re-dispatch.
- For **BLOCKED**, decide whether to add context, use a stronger model/tool, split the task, fix the plan, or ask the user.

Never force the same failing attempt to retry without changing context, scope, tools, or instructions.

## Prompt Templates

- `./implementer-prompt.md` - Dispatch the task executor.
- `./spec-reviewer-prompt.md` - Review whether the output matches the plan.
- `./code-quality-reviewer-prompt.md` - Review quality, maintainability, clarity, and verification.

## Review Gates

Requirements review comes first:
- Did the executor produce exactly what the task requested?
- Are any required artifacts, checks, sections, calculations, tests, or decisions missing?
- Did the executor add unnecessary scope?

Quality review comes second:
- Is the output clear, maintainable, and usable?
- Are sources, assumptions, and decisions visible enough?
- Are tests, checks, or review evidence meaningful?
- For code, does it follow local patterns and avoid needless complexity?
- For documents, is it coherent, concise, and fit for the audience?
- For research, are claims tied to evidence and uncertainty labeled?

## Red Flags

Never:
- Dispatch multiple subagents to edit the same files or artifacts concurrently.
- Let a subagent read the plan instead of giving it the task text.
- Skip requirements review.
- Skip quality review when the task has durable output.
- Accept "close enough" when the reviewer found a real mismatch.
- Move to the next task while review issues remain unresolved.
- Treat a subagent's success report as proof without inspecting the output.
- Commit, push, send, publish, delete, or apply irreversible changes unless the user or plan explicitly authorizes it.

## Fallback

If subagents are unavailable, execute the same plan inline:

1. Work one task at a time.
2. Run the task's stated checks.
3. Self-review against requirements.
4. Self-review for quality.
5. Mark the checkbox only after both reviews pass.

The fallback is slower and uses more of the current session context, but it preserves the same quality gates.
