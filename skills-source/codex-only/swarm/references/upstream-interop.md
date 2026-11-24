# Use an existing run with the community projects

Run these commands from the installed `swarm` skill directory. The two adapters use Python's standard library. Select one run, and choose whether to include original message bodies with `--include-text`. Both commands keep those bodies out of their output by default. Actor and task identifiers are included.

## Show a swarm board in Agent Mission Control

```powershell
python -B scripts/upstream.py amc-export --manifest .\manifest.json > .\amc.jsonl
```

Each line is one native canonical AMC event. Open the file to review it. To replay it into an **already running local bridge with a fresh database**, send one line per request in order. Check that the bridge accepted each line, then read back the session. The collector allocates a new event ID on each request, so replaying a file twice adds duplicate activity. Use a fresh database to restart an interrupted replay. [Original collector](https://github.com/jlee056/agent-mission-control/blob/357aec908d609748005cc190f0f64888470d56b1/packages/telemetry-bridge/src/collectors/claude-code.ts)

```powershell
$records = @(Get-Content -LiteralPath .\amc.jsonl -Encoding utf8)
if ($records.Count -eq 0) { throw "This board has no exportable records" }
$bridge = 'http://127.0.0.1:4700'
foreach ($record in $records) {
    $receipt = Invoke-RestMethod -Method Post -Uri "$bridge/api/collect/claude-code" -ContentType 'application/json' -Body $record
    if ($receipt.accepted -ne 1) { throw "AMC did not accept one record" }
}
$session = ($records[0] | ConvertFrom-Json).session_id
$sessionQuery = [uri]::EscapeDataString($session)
$stored = Invoke-RestMethod -Uri "$bridge/api/events?session_id=$sessionQuery&limit=$($records.Count + 1)"
if (@($stored).Count -ne $records.Count) { throw "Stored event count differs from export" }
```

| Swarm evidence | AMC representation |
| --- | --- |
| Manifest actors | `agent_registered` with the actor name and run-specific ID. Its timestamp anchors the roster to the earliest valid board event. Membership alone provides no worker startup time. |
| Assignment | `task_assigned` with Lead as sender and the named executor in `assigned_to`. Conflicting assignments are omitted. |
| Addressed message, question, reply or ack | `agent_message_sent` with the recorded sender, recipient, and subtype. `--include-text` includes the body and assignment descriptions. |
| Task in final `released` state | One `task_completed` at the exact release event identified by the board's `releaseId`. The result includes the accepted digest. |

The exporter reports omitted board event counts on stderr. Duplicate IDs, intermediate review events and dependency declarations have no unambiguous direct mapping. Times come from the selected board. Tool calls, token usage, cost, session start/end and process activity require independent observations. [Canonical schemas](https://github.com/jlee056/agent-mission-control/blob/357aec908d609748005cc190f0f64888470d56b1/packages/shared/src/events/schema.ts)

## Inspect a multiagents broker session in swarm

Choose the exact upstream session ID and a standalone SQLite backup of its broker database. Upstream defaults to `~/.multiagents/peers.db` and supports `MULTIAGENTS_DB`. For a running broker, use SQLite's backup facility, such as the following command from a directory where `broker-snapshot.db` is a **new** filename. A raw copy of a database using WAL can omit committed messages. The native Markdown session export omits the recipient and formats the send time for display. The database retains both routing fields and the full timestamp. [Broker storage](https://github.com/zetbrush/multiagents/blob/6038986b739937aaf3f2da2346e97a25f00369b1/broker.ts) · [Session export](https://github.com/zetbrush/multiagents/blob/6038986b739937aaf3f2da2346e97a25f00369b1/cli/session.ts)

```powershell
sqlite3 -readonly .\peers.db ".backup broker-snapshot.db"
python -B scripts/upstream.py multiagents-import --database .\broker-snapshot.db --session my-team --out .\team-board
python -B scripts/coordination.py --manifest .\team-board\manifest.json
```

The import reads only the selected session from an immutable, read-only connection. It creates a new board directory under an existing parent. Keep that directory in place because the board manifest contains absolute actor directories.

- Each broker message becomes an addressed swarm `message` under the `session-messages` label. Slot IDs identify actors across reconnections. The native orchestrator becomes `MA-Orchestrator`. Unbound peers receive stable aliases with a lookup in `report.json`.
- Open `report.json` for native slot statuses, task states, token counters, counts by message type and the delivered, acknowledged and held counts. These counts can overlap. The board event's `multiagents` object contains the original message type and broker delivery fields. Acknowledgment records the broker's claim about delivery.
- Native `approval` and `release` messages appear in the communication timeline. Swarm workflow transitions require the corresponding board evidence and artifact digest. The import creates no swarm assignments, approvals or releases.
