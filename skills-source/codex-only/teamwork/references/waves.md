# Planning and resuming a run

The manifest, event directories and read-only board belong to the sibling swarm skill. The plan is a UTF-8 JSON file held by the lead. It stores task definitions only. The same file works before any workers exist, during a live run and alongside a board archive.

## Import an existing GSD phase

From the installed teamwork directory, point to one existing phase directory and a local copy of the official GSD tool. PowerShell 7 example:

```powershell
python scripts/import_gsd.py <phase-directory> --gsd-tools <path-to-gsd-tools.cjs> --run export-format > plan.json
python scripts/waves.py plan.json
```

Choose a new output filename. Check the import exit status before consuming it. The converter calls Node and GSD’s `frontmatter get` against temporary copies. The resulting plan works with Python alone. Each GSD `*-PLAN.md` becomes a teamwork task, preserving its ID, declared write paths and intra-phase dependencies. Its `verify` text contains the source’s observable truths and explicit verification sections in a JSON array string that preserves multiline checks. Graph validation rejects unresolved external prerequisites and conflicting writes. A GSD plan with a human checkpoint needs an explicit gate and owner in a manually prepared plan. Previous GSD summaries supply handoff evidence; progress in this run follows swarm receipts.

## Native plan format

```json
{
  "run": "export-format",
  "plan_review": "plan",
  "tasks": [
    {"id": "plan", "verify": "Trace both format requirements to a consumer check", "requires_review": true},
    {"id": "writer", "depends_on": ["plan"], "files_modified": ["src/writer.py"], "verify": "Export two rows and check quoting"},
    {"id": "reader", "depends_on": ["plan"], "files_modified": ["src/reader.py"], "verify": "Read quoted fields through the public entry point"},
    {"id": "integration", "depends_on": ["writer", "reader"], "verify": "Round-trip a quoted field through both public entries", "requires_review": true},
    {"id": "milestone", "depends_on": ["integration"], "verify": "Reconcile both requirements against the round-trip evidence", "requires_review": true}
  ]
}
```

The required fields are the swarm run name, a nonempty task list, and each task’s unique `id` and `verify` text. Supply `depends_on` for inputs and `files_modified` for write ownership. Paths are literal repository-relative files or directory trees. The checker treats Windows path case and separators alike. Omitting either array means empty. Add `requires_review: true` for a required independent reviewer. Set `plan_review` only if the plan itself needs versioned review. Every other task in that case must descend from the named root gate.

Run from the installed teamwork directory:

```text
python scripts/waves.py plan.json
python scripts/waves.py plan.json --manifest manifest.json
```

Preflight checks unknown/duplicate identifiers, cycles, and unordered writers of overlapping paths, even if they sit at different depths. It cannot infer undeclared paths or interfaces. The lead checks what workers will really touch. A malformed plan/manifest exits 2. A valid query exits 0 and produces JSON, including when some work is blocked; consumers must inspect the task statuses and `complete`.

For live use, create one swarm run with the same `run` value. Use normal swarm assignments, with a named independent reviewer for each required review. Mirror the plan’s edges using Lead’s `depends` events if the board should display them. A recorded edge outside the plan conflicts with the affected task. Every acceptance query uses the plan’s entire dependency set.

For a task with inputs, take the `inputs` object emitted for that task. Attach it to its swarm `submit` event as a top-level JSON object mapping each direct task ID to the SHA-256 of its current release. An example fragment is `{"inputs":{"writer":"<released writer SHA-256>","reader":"<released reader SHA-256>"}}`. Use the released artifacts matching those digests. The submission’s own `version` hashes the submitted artifact bytes. For an integration, review or milestone report, include the input digests, actual checks and findings **in the artifact** as well. If the deliverable consists of multiple files, submit a reproducible manifest of their paths and byte digests. The lead verifies its members before release. A plan gate submits the exact bytes of `plan.json`, which must hash to the printed `plan_sha256`.

| Status | Action |
| --- | --- |
| `ready` | Assign the unowned task if host policy allows. |
| `assigned` | Reconnect to its owner and inspect the existing workspace. |
| `review` / `release` | Inspect the submitted version or its completed review. Lead releases after checking the evidence. |
| `blocked` | Wait for the listed prerequisites. Continue independent eligible tasks. |
| `conflict` | Inspect the specified conflicting event, edge or reviewer assignment. Preserve the run evidence. If an immutable assignment was wrong, use a corrected run. |
| `rework` | Owner addresses the review or rechecks the current inputs, then submits the corrected artifact and pins. Include renewed verification evidence in a report when the deliverable bytes alone would be identical. |
| `released` | Current submission passed the board’s applicable review/release sequence and its pinned inputs qualify. |

Resume uses the swarm reducer’s effective submission and release event IDs. A downstream submission must follow the effective releases of all pinned prerequisites. A stale, premature or unpinned submission cannot unlock a join, even when its own board row reads released. On a changed upstream digest, follow rework through the affected descendants. If the output digest stays the same but its input map changes, submit the new map and obtain a fresh review for the new submission ID. Pass that ID as `--submission` for swarm `approve` or `changes`; the review receipt refers to it in `replyTo`. Lead’s release must also reference that effective submission when a digest has been reused with different inputs. Repeating an identical digest and map is idempotent. Preserve the original plan beside the swarm archive and reopen both to compare results.
