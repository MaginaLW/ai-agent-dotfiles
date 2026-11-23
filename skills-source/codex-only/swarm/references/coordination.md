# Live Desktop coordination

Use this workflow when the user requests live collaboration. The Project Orchestrator assigns work and owns final acceptance. Each online worker writes only to its own event directory and reads the other selected directories. An idle or stopped worker can receive the message when it next runs.

## Open a run

From the installed swarm skill directory, create a new run in an existing parent directory. The command prints the manifest path and one outbox per member. Use a run directory that will survive worker cleanup. For isolated workers, pass `--member A=ABSOLUTE_EXISTING_OUTBOX` to use the directory that worker can write to in its own checkout.

```text
python -B scripts/run.py init RUN_DIRECTORY --name sprint --member A --member B
python -B scripts/coordination.py --manifest RUN_DIRECTORY/manifest.json
```

Use the server's printed loopback URL as `url` in the call below. The call targets the current chat's right panel by default.

```text
mcp__codex_app__open_in_codex({target: {type: "browser", url}, placement: "right"})
```

The panel polls the same read-only state as any other view of the URL. For dependency status, run `python scripts/waves.py plan.json --manifest MANIFEST` from the Teamwork skill directory using the run's actual file paths. Use the queries below and the underlying receipts to check messages, reviews and releases. If the panel opener is unavailable, give the user the printed URL to open manually.

### Wait for a queued open

A `queued` result means the host accepted the open request. Keep that single request pending and wait for the current chat to be visible. Ask the user to bring the chat forward if needed. Reserve `cua_repl` for a separate task that requires direct UI interaction.

Confirm loading from the panel's `GET /` returning HTTP 200 and its subsequent `/api/state` polls. To verify live refresh, check that a poll reflects a newly written receipt. Use board-side request records when available. Otherwise ask the user to confirm the panel is visible and check task state using the scripts and receipts.

### Verified synthetic run

On 2026-11-24, a queued request loaded after the user brought the current chat forward. A fresh open with the chat visible also returned `queued` and produced a panel `GET /` with HTTP 200. After synthetic submit, approve and release receipts, `/api/state` advanced from `assigned` with one event to `released` with four events. Teamwork's resume query showed the downstream task `ready` with the released input digest. For that foreground open, adjacent main-chat requests went from 191,900 to 192,034 input tokens, a single-run increase of 134.

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
| `assign` | Lead sets the executor in `to`. For independent review set `requiresReview: true` and name a different actor in `reviewer`. |
| `depends` | Lead records an explicit task dependency in `dependsOn`. An ordinary message creates only a communication edge. |
| `message`, `reply`, `ack` | Address another member in `to`, such as `@B`. Use `text` for single- or multiline content. The reader also recognizes a worker's `question` as a message. Replies and acknowledgments refer to the received event's ID in `replyTo`. Resolve the peer's current outbox from the manifest, including after a replacement worker starts. Poll until the named receipt, cancellation or deadline. |
| `submit` | The executor checks the actual artifact and supplies its SHA-256 digest in `version`. Put the evidence location and check in `text`. |
| `changes`, `approve` | The assigned independent reviewer inspects that version, records its digest and references the submission. A return names the failed check. The executor corrects it and submits the new digest for reinspection. |
| `release` | Lead verifies the artifact and required review, then records the current version. This marks board acceptance only. Git merge, deployment and other external actions keep their own authorization. |

Sentinel derives pending, returned and stale reviews during each refresh. Open the task or the corresponding graph edge to inspect the source record. A read-only reviewer returns its findings through the host. Use a separately writable, isolated reviewer outbox when a reviewer needs to publish a signed-off event in their own actor directory. The lead never impersonates the reviewer.

After the last receipt, run `python scripts/coordination.py --manifest <manifest.json> --archive <new-directory>` before disposing of worktrees. Reopen the archive's `manifest.json` with the same command used to serve a run, compare the final state and retain the accepted artifacts separately.
