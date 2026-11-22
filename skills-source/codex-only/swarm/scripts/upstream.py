#!/usr/bin/env python3
"""Exchange one offline swarm run with Agent Mission Control or multiagents."""

import argparse
from collections import Counter
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
from urllib.parse import quote

sys.dont_write_bytecode = True
import coordination


def amc_export(manifest_path, include_text):
    state = coordination.derive_state(coordination.load_manifest(manifest_path))
    events = state["events"]
    if not events:
        return [], Counter()
    run = state["run"]
    session = "swarm:" + quote(run, safe="")
    agents = {actor: f"{session}:{actor}" for actor in state["actors"]}

    def record(kind, actor, at, key, payload):
        # Keep namespaces disjoint even if a board event ID looks like a roster ID.
        identity = json.dumps([run, kind, key], ensure_ascii=True).encode("ascii")
        return {
            "event_id": hashlib.sha256(identity).hexdigest(),
            "session_id": session, "timestamp": at, "agent_id": agents[actor],
            "event_type": kind, "payload": payload,
        }

    records = [
        record("agent_registered", actor, events[0]["at"], actor, {
            "name": actor, "metadata": {"source": "swarm manifest", "time_basis": "first board event"},
        })
        for actor in agents
    ]
    counts = Counter(event["id"] for event in events)
    tasks = {task["id"]: task for task in state["tasks"]}
    final_releases = {task["releaseId"] for task in tasks.values() if task["status"] == "released"}
    skipped = Counter()
    for event in events:
        kind = event["type"]
        actor = event["from"]
        task_id = event["task"]
        body = (event.get("text") or "") if include_text else ""
        if counts[event["id"]] > 1:
            skipped["duplicate event ID"] += 1
            continue
        if kind in coordination.COMMUNICATION_TYPES:
            target = event["to"].removeprefix("@")
            message_type = "question" if event.get("sourceType") == "question" else kind
            payload = {"to_agent_id": agents[target], "content": body, "message_type": message_type}
            native_kind = "agent_message_sent"
        elif kind == "assign" and task_id in tasks and "conflicting task id" not in tasks[task_id]["alerts"]:
            target = event["to"].removeprefix("@")
            payload = {"task_id": task_id, "description": body or task_id, "assigned_to": agents[target]}
            native_kind = "task_assigned"
        elif kind == "release" and event["id"] in final_releases:
            payload = {"task_id": task_id, "success": True, "result": "Board release " + event["version"]}
            native_kind = "task_completed"
        else:
            skipped[kind] += 1
            continue
        records.append(record(native_kind, actor, event["at"], event["id"], payload))
    return records, skipped


def read_session(database, session, include_text):
    database = database.resolve(strict=True)
    if any(Path(str(database) + suffix).exists() for suffix in ("-wal", "-journal")):
        raise ValueError("use a standalone SQLite backup or a cleanly closed broker database")
    uri = database.as_uri() + "?mode=ro&immutable=1"
    with closing(sqlite3.connect(uri, uri=True)) as db:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA trusted_schema = OFF")
        selected = db.execute("SELECT id, status FROM sessions WHERE id = ?", (session,)).fetchone()
        if selected is None:
            raise ValueError("session not found in the selected database")
        slots = [dict(row) for row in db.execute("""
            SELECT id, display_name, agent_type, status, task_state,
                   input_tokens, output_tokens, cache_read_tokens
            FROM slots WHERE session_id = ? ORDER BY id
        """, (session,))]
        # Omitted transcript bodies never enter the Python process.
        body = "text" if include_text else "NULL AS text"
        messages = [dict(row) for row in db.execute(f"""
            SELECT id, from_id, from_slot_id, to_id, to_slot_id, msg_type, sent_at,
                   delivered, delivered_at, acked_at, held, {body}
            FROM messages WHERE session_id = ? ORDER BY id
        """, (session,))]
    return dict(selected), slots, messages


def import_session(database, session, target, include_text):
    selected, slots, messages = read_session(database, session, include_text)
    run = "multiagents:" + session
    coordination._plain_string(run, "run")
    target = target.absolute()
    if target.exists() or target.is_symlink():
        raise ValueError("board output already exists")
    if not coordination._is_directory_no_symlink(target.parent):
        raise ValueError("board output parent must be an existing regular directory")

    actors = {coordination.LEAD}
    slot_ids = {slot["id"] for slot in slots}
    if any(type(number) is not int for number in slot_ids):
        raise ValueError("invalid broker slot ID")
    actors.update(f"slot-{slot_id}" for slot_id in slot_ids)
    peer_names = {}

    def address(peer, slot):
        if slot is not None:
            if type(slot) is not int:
                raise ValueError("invalid broker message slot ID")
            prefix = "slot" if slot in slot_ids else "unlisted-slot"
            return f"{prefix}-{slot}"
        coordination._plain_string(peer, "broker peer ID")
        if peer in ("orchestrator", "__orchestrator__"):
            return "MA-Orchestrator"
        # The broker uses this address for a driver-managed slot without a peer.
        if peer.startswith("__slot_") and peer.endswith("__"):
            number = peer[7:-2]
            if number.isdigit() and int(number) in slot_ids:
                return "slot-" + str(int(number))
        if peer not in peer_names:
            peer_names[peer] = "peer-" + hashlib.sha256(peer.encode("utf-8")).hexdigest()
        return peer_names[peer]

    events = []
    kinds = Counter()
    delivery = Counter()
    for row in messages:
        if type(row["id"]) is not int:
            raise ValueError("invalid broker message ID")
        coordination._plain_string(row["msg_type"], "broker message type")
        sender = address(row["from_id"], row["from_slot_id"])
        recipient = address(row["to_id"], row["to_slot_id"])
        actors.update((sender, recipient))
        kinds[row["msg_type"]] += 1
        for key in ("delivered", "acked_at", "held"):
            delivery[key] += bool(row[key])
        provenance = {key: row[key] for key in ("msg_type", "delivered", "delivered_at", "acked_at", "held")}
        events.append({
            "id": f"multiagents-{row['id']}", "run": run, "at": row["sent_at"],
            "from": sender, "to": recipient, "type": "message", "task": "session-messages",
            "text": row["text"] if include_text else f"[multiagents {row['msg_type']}]",
            "multiagents": provenance,
        })

    # Actor names are labels. Only locally generated numeric components become paths.
    directories = {name: Path("events", str(i)) for i, name in enumerate(sorted(actors))}
    manifest = {"run": run, "actors": {name: str(target / path) for name, path in directories.items()}}
    report = {
        "source": "multiagents broker", "session": selected, "slots": slots,
        "peer_addresses": {actor: peer for peer, actor in peer_names.items()},
        "message_count": len(messages), "by_message_type": kinds,
        "delivered": delivery["delivered"], "acknowledged": delivery["acked_at"], "held": delivery["held"],
        "message_text_included": include_text,
    }
    with tempfile.TemporaryDirectory(dir=target.parent) as temporary:
        stage = Path(temporary) / "board"
        for path in directories.values():
            (stage / path).mkdir(parents=True)
        for event in events:
            coordination._validate_event(event, run=run, actor=event["from"], actors=directories)
            content = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
            if len(content) > coordination.MAX_EVENT_BYTES:
                raise ValueError(f"board event {event['id']} exceeds the board size limit")
            file = stage / directories[event["from"]] / (event["id"] + ".json")
            with file.open("xb") as stream:
                stream.write(content)
        for name, data in (("manifest.json", manifest), ("report.json", report)):
            (stage / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        stage.rename(target)
    return target / "manifest.json"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    export = sub.add_parser("amc-export", help="write native AMC canonical objects to stdout as JSONL")
    export.add_argument("--manifest", type=Path, required=True)
    load = sub.add_parser("multiagents-import", help="read one broker snapshot session into a new board")
    load.add_argument("--database", type=Path, required=True)
    load.add_argument("--session", required=True, help="exact broker session ID")
    load.add_argument("--out", type=Path, required=True, help="new board directory under an existing parent")
    for command in (export, load):
        command.add_argument("--include-text", action="store_true", help="include original message or assignment text")
    args = parser.parse_args(argv)
    try:
        if args.command == "amc-export":
            records, skipped = amc_export(args.manifest, args.include_text)
            for record in records:
                print(json.dumps(record, ensure_ascii=True))
            print(f"{len(records)} AMC records; omitted board events: {dict(skipped)}", file=sys.stderr)
        else:
            print(import_session(args.database, args.session, args.out, args.include_text))
    except (coordination.BoardError, OSError, ValueError, sqlite3.Error) as exc:
        print(f"upstream: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
