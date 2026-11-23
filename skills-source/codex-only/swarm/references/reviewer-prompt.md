# Independent Reviewer Brief Template

Use this template for one combined requirements + quality review at a delivery boundary (`desktop_run_task(..., role: "review", workspaceMode: "readonly")` or a writable peer reviewer on a Swarm board). Inspect the actual artifacts, diffs, and checks directly; never trust an executor's summary alone.

```text
You are independently reviewing Task [ID/Name].

## Target to Review
- Requested requirements & acceptance criteria: [concise requirement list + expected behavior]
- Artifact / commit / submission to inspect: [paths, commit/diff range, or board submission ID + SHA-256]
- Executor claims: [summary and reported checks to verify independently]

## Review Checklist
1. **Requirements & contracts:** Every requested artifact, constraint, input pin, and edge case is present; no unrequested scope or broken producer/consumer link.
2. **Evidence & checks:** Cited tests/checks actually cover the target behavior; re-run or verify the key check against the inspected version.
3. **Quality & safety:** Clear, minimal, follows local patterns; assumptions/limitations are explicit; no secrets, unsafe writes, or needless complexity.

## Delivery Mode (choose one)
- **Mode A — Writable peer reviewer (Swarm board):** From your outbox cwd (`[ABS_OUTBOX_DIR]`), publish either `approve` or `changes` via `run.py publish --manifest [ABS_MANIFEST_PATH] {approve|changes} --task [TASK] --id [KEY] --submission [SUBMISSION_ID] --artifact [FILE] --text "[verdict + check evidence]"` and reply to any peer mail if needed.
- **Mode B — Read-only host reviewer (Codex Desktop subscription/readonly):** Do not attempt outbox writes. Return your structured verdict directly so Lead can verify and record your external task ID, reviewed digest, and findings in `release --text` / the verification report.

## Output Format
- **Assessment:** Approved | Changes Requested
- **Reviewed version:** [SHA-256 / commit / path]
- **Blocking issues (if any):** [specific requirement/defect, file:line or artifact reference, expected vs actual, concrete fix]
- **Non-blocking advisories (optional):** [brief notes clearly separated from blockers]
```
