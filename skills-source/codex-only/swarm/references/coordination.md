# Live Desktop coordination

Use this workflow when the user requests live collaboration. The Project Orchestrator assigns work and owns final acceptance. Each online worker writes only to its own event directory and reads the other selected directories. An idle or stopped worker can receive the message when it next runs.

## Open a run

From the installed swarm skill directory, create a new run in an existing parent directory. The command prints the manifest path and one outbox per member. Use a run directory that will survive worker cleanup. For isolated workers, pass `--member A=ABSOLUTE_EXISTING_OUTBOX` to use the directory that worker can write to in its own checkout.

```text
python -B scripts/run.py init RUN_DIRECTORY --name sprint --member A --member B
python -B scripts/coordination.py --manifest RUN_DIRECTORY/manifest.json --reuse
```

`coordination.py` writes a sibling `board-server.json` next to `manifest.json` (never inside actor directories or archives) so `--reuse` returns the URL of an already healthy board server for the same manifest across turns or Goal continuations. Use `--no-server-info` to opt out. Pass the printed loopback URL as `url` below:

```text
mcp__codex_app__open_in_codex({target: {type: "browser", url}, placement: "right"})
```

The panel polls `/api/state` read-only. For dependency status, run `python scripts/waves.py plan.json --manifest MANIFEST` from the Teamwork skill directory using the run's actual file paths. If the panel opener is unavailable, give the user the printed URL to open manually.

### Wait for a queued open

A `queued` result means the host accepted the open request. Keep that single request pending and wait for the current chat to be visible; ask the user to bring the chat forward if needed. Reserve `cua_repl` for a separate task that requires direct UI interaction.

Confirm loading via `python -B SWARM/scripts/run.py status --manifest MANIFEST` or `GET <url>api/health`: check `server.running: true`, `uiGets >= 1`, and `statePolls >= 1` (and that `eventCount` / `lastStateAt` reflects newly written receipts). If local HTTP probing is unavailable, ask the user to confirm the panel is visible and check task state via `run.py status`.

## Inspect status

Run from any directory (no actor outbox `cwd` required) to inspect tasks, Sentinel alerts, pending messages, communication connections, recent events, and live board health in one compact JSON response:

```text
python -B SWARM/scripts/run.py status --manifest MANIFEST [--task TASK] [--actor ACTOR] [--include-text]
```

## Post and receive

Run writer commands **from your assigned outbox**. Use absolute paths for the script, manifest and artifact. The CLI derives the member from the working directory. Host write permissions determine isolation. Choose a stable `--id` for each distinct operation and reuse it when retrying that operation.

```text
python -B SWARM/scripts/member_mailbox.py --manifest MANIFEST send --to B --task build --id question1 --text "Ready to review?"
python -B SWARM/scripts/member_mailbox.py --manifest MANIFEST inbox --availability idle --wait-seconds 30
python -B SWARM/scripts/member_mailbox.py --manifest MANIFEST reply A/message/question1 --text "Reviewing it now"
python -B SWARM/scripts/member_mailbox.py --manifest MANIFEST status A/message/question1
```

The sender runs the first and last commands. The recipient runs the middle commands. A busy recipient can call `inbox --availability busy` to see its pending count. An idle read exposes message bodies; `ack EVENT_ID` and `reply EVENT_ID` record the actual recipient's action. A stopped worker sees its messages when it next starts.

Use `run.py publish --manifest MANIFEST` followed by the appropriate operation below. The publisher hashes the actual artifact bytes. A change followed by a fix needs a fresh submit event and another review.

```text
assign  --task build --id assign1 --to A --reviewer B
submit  --task build --id v1 --artifact FILE --text "Evidence from normal entry point"
changes --task build --id r1 --submission A/submit/v1 --artifact FILE --text "Failed check and expected outcome"
submit  --task build --id v2 --artifact FILE --text "Fix and retest evidence"
approve --task build --id r2 --submission A/submit/v2 --artifact FILE --text "Independently repeated the check"
release --task build --id done --submission A/submit/v2 --artifact FILE --text "Accepted artifact and review"
```

The Project Orchestrator (`Lead`) issues assign and release. A submits and B reviews. For dependent tasks, `depends --task T --id KEY --on PREREQUISITE` records an edge. A submit can carry repeated `--input TASK=SHA256` pins. Teamwork uses these pins to check the actual prerequisites reviewed at a milestone.

| Type | Author and meaning |
| --- | --- |
| `assign` | Lead sets the executor in `to`. For independent board-signed review set `requiresReview: true` and name a different writable actor in `reviewer`. |
| `depends` | Lead records an explicit task dependency in `dependsOn`. An ordinary message creates only a communication edge. |
| `message`, `reply`, `ack` | Address another member in `to`, such as `@B`. Use `text` for single- or multiline content. The reader also recognizes a worker's `question` as a message. Replies and acknowledgments refer to the received event's ID in `replyTo`. Resolve the peer's current outbox from the manifest, including after a replacement worker starts. Poll until the named receipt, cancellation or deadline. |
| `submit` | The executor checks the actual artifact and supplies its SHA-256 digest in `version`. Put the evidence location and check in `text`. |
| `changes`, `approve` | The assigned independent reviewer inspects that version, records its digest and references the submission. A return names the failed check. The executor corrects it and submits the new digest for reinspection. |
| `release` | Lead verifies the artifact and required review, then records the current version. This marks board acceptance only. Git merge, deployment and other external actions keep their own authorization. |

Sentinel derives pending, returned and stale reviews during each refresh. Use `run.py status` or open the task/edge to inspect the source record. For a `readonly` subscription review, do not assign an unwritable board `reviewer`; collect findings via the host and record the external task ID, reviewed digest, verdict, and findings in Lead's `release --text` and verification report. Lead never impersonates a reviewer.

After the last receipt, run `python -B scripts/coordination.py --manifest <manifest.json> --archive <new-directory>` before disposing of worktrees. Reopen the archive's `manifest.json` with `coordination.py --manifest ...` to inspect the archived state and retain accepted artifacts separately.
