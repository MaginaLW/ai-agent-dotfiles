# Live Desktop coordination

Use this workflow when the user requests live collaboration. The Project Orchestrator assigns work and owns final acceptance. Each online worker writes only to its own event directory and reads the other selected directories. An idle or stopped worker can receive the message when it next runs.

## Open a run

Give the run a unique name. Create an empty directory for each participating writer, using an ignored location in its own worktree. Give the lead a separate directory outside the disposable trees. Write a UTF-8 manifest with the run name in `run` and a mapping in `actors` from names (including `Lead`) to those absolute directories. Share only the run's manifest, assigned artifacts and event paths with each worker.

From this skill's directory run `python scripts/coordination.py --manifest <manifest.json>`. Open the printed loopback URL as a browser tab in the current Desktop chat's right panel. Multiple views of that URL poll the same read-only state. The lead and workers can read the event directories directly while the panel is closed.

## Post and receive

Publish one UTF-8 JSON object per event. Include unique `id`, `run`, `from` (your manifest actor), `task`, UTC ISO timestamp `at` and `type`. Write to a new temporary file in your own event directory, close it, then rename it to a new `.json` filename. A run may contain independent tasks. On restart read existing IDs before sending an event again.

| Type | Author and meaning |
| --- | --- |
| `assign` | Lead sets the executor in `to`. For independent review set `requiresReview: true` and name a different actor in `reviewer`. |
| `depends` | Lead records an explicit task dependency in `dependsOn`. An ordinary message creates only a communication edge. |
| `message`, `reply`, `ack` | Address another member in `to`, such as `@B`. Use `text` for single- or multiline content. The reader also recognizes a worker's `question` as a message. Replies and acknowledgments refer to the received event's ID in `replyTo`. Resolve the peer's current outbox from the manifest, including after a replacement worker starts. Poll until the named receipt, cancellation or deadline. |
| `submit` | The executor checks the actual artifact and supplies its SHA-256 digest in `version`. Put the evidence location and check in `text`. |
| `changes`, `approve` | The assigned independent reviewer inspects that version, records its digest and references the submission. A return names the failed check. The executor corrects it and submits the new digest for reinspection. |
| `release` | Lead verifies the artifact and required review, then records the current version. This marks board acceptance only. Git merge, deployment and other external actions keep their own authorization. |

Sentinel derives pending, returned and stale reviews during each refresh. Open the task or the corresponding graph edge to inspect the source record. A read-only reviewer returns its findings through the host. Use a separately writable, isolated reviewer outbox when a reviewer needs to publish a signed-off event in their own actor directory. The lead never impersonates the reviewer.

After the last receipt, run `python scripts/coordination.py --manifest <manifest.json> --archive <new-directory>` before disposing of worktrees. Reopen the archive's `manifest.json` with the same command used to serve a run, compare the final state and retain the accepted artifacts separately.
