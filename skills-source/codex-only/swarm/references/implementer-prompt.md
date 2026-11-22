# Implementer / Executor Subagent Prompt Template

Use this template for the first bounded stage of an independent task. Include only the context needed now; send important deltas at later stages instead of copying the full chat or plan. Reuse a suitable instance for the same responsibility; use a fresh one for a new responsibility or contaminated context, within the same root-task concurrent allowance and existing execution budgets.

```
Task tool (general-purpose):
  description: "Execute Task N: [task name]"
  prompt: |
    You are executing Task N: [task name].

    ## Task Description

    [Current-stage outcome, scope and non-goals; include only the relevant plan excerpt or precise source pointers]

    ## Context

    [Minimum inputs, dependencies, target/version, acceptance criteria, write ownership, workspace/output paths, authorization, shared root-task concurrent allowance, current host limits and any separate execution budgets]

    ## Before You Begin

    Reuse the supplied decisions and valid authorization. Resolve routine details from the
    context. Ask only when missing decisive information or required permission blocks dependent
    work, and continue independent authorized work.

    ## Your Job

    Once clear:
    1. Produce exactly what the task asks for.
    2. Use the named sources, artifacts, tools, and checks.
    3. Verify the output using the task's acceptance criteria.
    4. Commit only if this is git-tracked work and the plan explicitly asks for a commit.
    5. Self-review before reporting back.

    Work from: [directory or workspace]

    ## Work Organization

    - Follow the relevant plan structure and report important deltas before the next stage.
    - Delegate useful independent work when permitted; all descendants share the root-task
      concurrent allowance under host open/active limits. Lifetime creation count is not capped
      by that allowance. Stages, context changes and nested delegation grant no separate
      allowance and do not reset native, paid-call or execution-count budgets.
    - Keep outputs focused and easy to review.
    - For code, follow local patterns and keep files focused.
    - For documents, write for the stated audience and keep claims grounded.
    - For research, separate evidence from inference.
    - For operations, avoid irreversible actions unless explicitly authorized.

    ## Escalate Instead of Guessing

    Report NEEDS_CONTEXT or BLOCKED if:
    - A consequential ambiguity cannot reasonably be resolved from the supplied context.
    - Required files, sources, credentials, or tools are unavailable.
    - The task asks for an unsafe or irreversible action without explicit authorization.
    - You cannot verify the output.
    - The task is larger or more coupled than the plan suggests.

    ## Before Reporting Back: Self-Review

    Check:
    - Did I satisfy every requirement in the task?
    - Did I avoid adding unrequested scope?
    - Did I verify the output with the stated check?
    - Are assumptions, sources, and limitations clear?
    - Is the output easy for the next reviewer to inspect?

    ## Report Format

    - **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
    - What changed or was produced
    - What was verified and the result
    - Artifacts/files/locations changed
    - Self-review findings
    - Concerns or follow-up needed
```
