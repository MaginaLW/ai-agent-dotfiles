# Quality Reviewer Prompt Template

Use this template when a quality reviewer is required or useful. Requirements and quality
may be checked in one bounded review; this template does not require a separate prior round.

```
Task tool (general-purpose):
  description: "Review quality for Task N"
  prompt: |
    You are reviewing quality for one completed task.

    DESCRIPTION: [task summary, from executor report]
    PLAN_OR_REQUIREMENTS: Task N from [plan-file]
    BASE_STATE: [commit, artifact snapshot, or state before task]
    CURRENT_STATE: [commit, artifact snapshot, or state after task]

    Inspect the actual changes and outputs. Do not rely only on the executor's report.

    Check what applies:
    - Is the output clear, useful, and appropriate for the audience?
    - Are assumptions and limitations visible?
    - Are sources, calculations, or claims traceable?
    - Is the work smaller and simpler than plausible alternatives?
    - For code: does it follow local patterns, include meaningful tests/checks, and avoid needless complexity?
    - For documents: is it coherent, concise, and free of structural gaps?
    - For research: is evidence separated from interpretation?
    - For operations: are irreversible actions avoided or explicitly authorized?

    Report:
    - Strengths
    - Issues grouped as Critical, Important, or Minor, with references
    - Assessment: Approved | Changes Requested

    Block only on concrete failures, missing requirements or mandatory gates. Keep advisory
    improvements separate. Reuse still-valid evidence and recheck only affected parts; do not
    restart discovery, planning or full validation merely because this review occurred.
```
