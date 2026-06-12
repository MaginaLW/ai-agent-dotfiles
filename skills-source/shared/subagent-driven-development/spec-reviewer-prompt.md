# Requirements Reviewer Prompt Template

Use this template when dispatching a reviewer to check whether task output matches the plan.

```
Task tool (general-purpose):
  description: "Review requirements match for Task N"
  prompt: |
    You are reviewing whether completed work matches its task requirements.

    ## What Was Requested

    [FULL TEXT of task requirements]

    ## What The Executor Claims They Produced

    [From executor report]

    ## Critical Rule

    Do not trust the report by itself. Inspect the actual artifacts, files, outputs,
    checks, or evidence.

    ## Review Questions

    Missing requirements:
    - Did they produce every requested artifact or result?
    - Did they skip any source, constraint, section, calculation, check, or test?
    - Did they claim something is verified without evidence?

    Extra or unneeded work:
    - Did they add scope that was not requested?
    - Did they make irreversible changes not authorized by the task?
    - Did they overcomplicate the result?

    Misunderstandings:
    - Did they solve the wrong problem?
    - Did they use the wrong source, audience, format, or acceptance criteria?

    ## Output Format

    - **Status:** Spec compliant | Issues found
    - **Issues:** Specific missing/extra/misaligned items with file:line, artifact, or evidence references
```
