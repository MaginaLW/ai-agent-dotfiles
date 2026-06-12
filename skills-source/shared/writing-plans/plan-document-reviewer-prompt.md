# Plan Document Reviewer Prompt Template

Use this template when dispatching a plan reviewer.

**Purpose:** Verify the plan is complete, matches the spec, and decomposes work into executable tasks.

**Dispatch after:** The complete plan is written.

```
Task tool (general-purpose):
  description: "Review plan document"
  prompt: |
    You are a plan document reviewer. Verify this plan is ready for execution.

    **Plan to review:** [PLAN_FILE_PATH]
    **Spec or requirements for reference:** [SPEC_FILE_PATH or pasted requirements]

    ## What to Check

    | Category | What to Look For |
    |----------|------------------|
    | Completeness | Placeholders, missing tasks, incomplete steps, missing artifacts |
    | Requirement Alignment | Plan covers requirements without major scope creep |
    | Task Decomposition | Tasks have clear boundaries, inputs, outputs, and checks |
    | Executability | A capable agent or human could follow it without hidden context |
    | Validation | Every task and the whole plan have observable pass conditions |

    ## Calibration

    Only flag issues that would cause real problems during execution. Minor wording,
    style preferences, and optional improvements are advisory.

    ## Output Format

    ## Plan Review

    **Status:** Approved | Issues Found

    **Issues (if any):**
    - [Task X, Step Y]: [specific issue] - [why it matters]

    **Recommendations (advisory, do not block approval):**
    - [suggestions for improvement]
```

**Reviewer returns:** Status, Issues, Recommendations
