"""Create a Swarm run and publish versioned workflow events from a member's outbox."""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

if __name__ == "__main__":
    sys.dont_write_bytecode = True  # A live skills directory is managed by the deployer.

import coordination
import member_mailbox

_WINDOWS_RESERVED_NAMES = frozenset(
    {"CON", "PRN", "AUX", "NUL"}
    | {f"COM{i}" for i in range(1, 10)}
    | {f"LPT{i}" for i in range(1, 10)}
)


def _is_reserved_name(name):
    return name.split(".", 1)[0].upper() in _WINDOWS_RESERVED_NAMES


def _normalize_abs(path):
    return Path(os.path.abspath(os.path.normpath(os.fspath(path))))


def initialize(directory, name, members):
    destination = _normalize_abs(directory)
    name = coordination._plain_string(name, "run")
    if destination.exists() or destination.is_symlink():
        raise ValueError("choose a new run directory")
    actors = {}
    local = []
    for member in ["Lead", *members]:
        actor, sep, external = member.partition("=")
        if (not coordination.ACTOR_NAME_RE.fullmatch(actor) or actor.endswith(".")
                or _is_reserved_name(actor) or actor.casefold() in {a.casefold() for a in actors}):
            raise ValueError(f"invalid or duplicate member: {actor}")
        if sep:
            raw_outbox = Path(external)
            if not raw_outbox.is_absolute():
                raise ValueError(f"{actor} needs an existing absolute outbox directory")
            outbox = _normalize_abs(raw_outbox)
            if not coordination._is_directory_no_symlink(outbox):
                raise ValueError(f"{actor} needs an existing absolute outbox directory")
        else:
            outbox = _normalize_abs(destination / "members" / actor)
            local.append(actor)
        actors[actor] = outbox
    # Validate all paths before creating anything, including worker-owned directories.
    for actor, outbox in actors.items():
        for key, other in actors.items():
            if key == actor:
                continue
            if (coordination._same_path(outbox, other)
                    or any(coordination._same_path(outbox, parent) for parent in other.parents)
                    or any(coordination._same_path(other, parent) for parent in outbox.parents)):
                raise ValueError("members need disjoint outboxes")
    if not coordination._is_directory_no_symlink(destination.parent):
        raise ValueError("choose an existing parent directory without filesystem links")
    with TemporaryDirectory(dir=destination.parent) as temporary:
        staged = Path(temporary) / "run"
        for actor in local:
            (staged / "members" / actor).mkdir(parents=True, exist_ok=True)
        manifest = {"run": name, "actors": {k: str(v) for k, v in actors.items()}}
        (staged / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        staged.rename(destination)
    return {"manifest": str(destination / "manifest.json"), **manifest}


def digest(path):
    with path.open("rb") as source:
        h = hashlib.sha256()
        for part in iter(lambda: source.read(1024 * 1024), b""):
            h.update(part)
    return h.hexdigest()


def event_fields(args):
    fields = {"type": args.kind, "task": args.task}
    if args.kind == "assign":
        fields["to"] = args.to
        if args.reviewer:
            fields.update(requiresReview=True, reviewer=args.reviewer)
    elif args.kind == "depends":
        if args.task in args.on:
            raise ValueError("a task cannot depend on itself")
        fields["dependsOn"] = args.on
    else:
        fields.update(version=digest(args.artifact), text=args.text)
        if args.kind in ("approve", "changes"):
            fields["replyTo"] = args.submission
        if args.kind == "submit" and args.input:
            inputs = {}
            for item in args.input:
                task, sep, version = item.partition("=")
                if (not sep or not task.strip() or task in inputs
                        or not coordination.SHA256_RE.fullmatch(version)):
                    raise ValueError("each --input must be a distinct TASK=SHA256")
                inputs[task] = version.lower()
            fields["inputs"] = inputs
    return fields


def publish(args):
    manifest = coordination.load_manifest(args.manifest)
    actor = member_mailbox.current_actor(manifest)
    fields = event_fields(args)
    state = coordination.derive_state(manifest)
    event_id = f"{actor}/{args.kind}/{args.id}"
    existing = next((event for event in state["events"] if event["id"] == event_id), None)
    task = next((t for t in state["tasks"] if t["id"] == args.task), None)
    if args.kind == "release":
        submission = args.submission or (existing or {}).get("replyTo") or (task or {}).get("submissionId")
        if submission:
            fields["replyTo"] = submission
    if existing:
        return member_mailbox.publish(manifest, args.id, fields)  # Checks identical payload on retries.
    if args.kind == "assign":
        if task and (task["owner"], task["reviewer"]) != (args.to.lstrip("@"), args.reviewer):
            raise ValueError("task already assigned to a different owner or reviewer")
    elif args.kind != "depends":
        if task is None:
            raise ValueError("assign the task before publishing workflow events")
        if args.kind == "submit" and task["owner"] != actor:
            raise ValueError("only the assigned owner can submit")
        if args.kind in ("approve", "changes"):
            if (task["reviewer"] != actor or task["status"] != "submitted"
                    or task["version"] != fields["version"] or task["submissionId"] != args.submission):
                raise ValueError("review must address the current submission, artifact and assigned reviewer")
        if args.kind == "release":
            required = "approved" if task["reviewer"] else "submitted"
            if (task["status"] != required or coordination.blocking_alerts(task["alerts"])
                    or task["version"] != fields["version"]
                    or task["submissionId"] != fields.get("replyTo")):
                raise ValueError("release requires the accepted artifact and resolved Sentinel alerts")
    return member_mailbox.publish(manifest, args.id, fields)


def board_status(args):
    manifest = coordination.load_manifest(args.manifest)
    state = coordination.derive_state(manifest)
    live = coordination.probe_server(manifest)
    server_info = {"running": True, **live} if live is not None else {"running": False}
    task_filter = args.task
    actor_filter = args.actor

    tasks = state["tasks"]
    if task_filter:
        tasks = [t for t in tasks if t["id"] == task_filter]
    if actor_filter:
        tasks = [t for t in tasks if t["owner"] == actor_filter or t["reviewer"] == actor_filter]
    alerts = [{"task": t["id"], "status": t["status"], "alerts": t["alerts"]} for t in tasks if t["alerts"]]

    receipts = state["receipts"]
    pending_messages = []
    for event in state["events"]:
        if receipts.get(event["id"]) != "pending":
            continue
        recipient = (event.get("to") or "").removeprefix("@")
        if task_filter and event["task"] != task_filter:
            continue
        if actor_filter and event["from"] != actor_filter and recipient != actor_filter:
            continue
        entry = {
            "id": event["id"],
            "type": event["type"],
            "from": event["from"],
            "to": recipient,
            "task": event["task"],
            "at": event["at"],
        }
        if args.include_text and event.get("text") is not None:
            entry["text"] = event["text"]
        pending_messages.append(entry)

    connections = state["connections"]
    if task_filter:
        task_events = {e["id"]: e for e in state["events"] if e["task"] == task_filter}
        board_latest = coordination._parse_utc(state["events"][-1]["at"]) if state["events"] else None
        filtered_connections = []
        for conn in connections:
            matching_ids = [eid for eid in conn["eventIds"] if eid in task_events]
            if not matching_ids:
                continue
            if len(matching_ids) == len(conn["eventIds"]):
                filtered_connections.append(conn)
            else:
                last_at = task_events[matching_ids[-1]]["at"]
                age = (board_latest - coordination._parse_utc(last_at)).total_seconds() if board_latest else 0.0
                filtered_connections.append({
                    **conn,
                    "timestamp": last_at,
                    "decay": max(0.0, 1.0 - age / 30.0),
                    "count": len(matching_ids),
                    "eventIds": matching_ids,
                })
        connections = filtered_connections
    if actor_filter:
        connections = [
            c for c in connections if c["fromAgentId"] == actor_filter or c["toAgentId"] == actor_filter
        ]

    matched_events = []
    for event in state["events"]:
        recipient = (event.get("to") or "").removeprefix("@")
        if task_filter and event["task"] != task_filter:
            continue
        if actor_filter and (
            event["from"] != actor_filter and recipient != actor_filter and event.get("reviewer") != actor_filter
        ):
            continue
        matched_events.append(event)

    recent_events = []
    for event in matched_events[-10:]:
        summary = {
            "id": event["id"],
            "type": event["type"],
            "from": event["from"],
            "task": event["task"],
            "at": event["at"],
        }
        if event.get("to") is not None:
            summary["to"] = event["to"].removeprefix("@")
        if event.get("reviewer") is not None:
            summary["reviewer"] = event["reviewer"]
        if event.get("version") is not None:
            summary["version"] = event["version"]
        if event.get("replyTo") is not None:
            summary["replyTo"] = event["replyTo"]
        text = event.get("text")
        if text is not None:
            if args.include_text:
                summary["text"] = text
            else:
                summary["textPreview"] = text[:120] + ("..." if len(text) > 120 else "")
        recent_events.append(summary)

    return {
        "run": state["run"],
        "actors": state["actors"],
        "eventCount": len(state["events"]),
        "server": server_info,
        "tasks": tasks,
        "alerts": alerts,
        "pendingMessages": pending_messages,
        "connections": connections,
        "recentEvents": recent_events,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init")
    init.add_argument("directory", type=Path)
    init.add_argument("--name", required=True)
    init.add_argument("--member", action="append", default=[], metavar="NAME[=EXISTING_OUTBOX]")
    status = commands.add_parser("status", help="inspect board state, alerts, pending mail and server health")
    status.add_argument("--manifest", type=Path, required=True)
    status.add_argument("--task", help="filter to one task id")
    status.add_argument("--actor", help="filter to one actor name")
    status.add_argument("--include-text", action="store_true", help="include full text on pending/recent events")
    pub = commands.add_parser("publish")
    pub.add_argument("--manifest", type=Path, required=True)
    kinds = pub.add_subparsers(dest="kind", required=True)
    for kind in ("assign", "depends", "submit", "changes", "approve", "release"):
        item = kinds.add_parser(kind)
        item.add_argument("--task", required=True)
        item.add_argument("--id", required=True, help="stable key for this occurrence and retries")
        if kind == "assign":
            item.add_argument("--to", required=True)
            item.add_argument("--reviewer")
        elif kind == "depends":
            item.add_argument("--on", nargs="+", required=True)
        else:
            item.add_argument("--artifact", required=True, type=Path)
            item.add_argument("--text", required=True, help="evidence, check result or requested fix")
            if kind in ("approve", "changes"):
                item.add_argument("--submission", required=True, help="exact submit event id")
            if kind == "release":
                item.add_argument("--submission", help="pin a specific effective submission")
            if kind == "submit":
                item.add_argument("--input", action="append", metavar="TASK=SHA256")
    args = parser.parse_args(argv)
    try:
        if args.command == "init":
            result = initialize(args.directory, args.name, args.member)
        elif args.command == "status":
            result = board_status(args)
        else:
            result = publish(args)
    except (OSError, ValueError, coordination.BoardError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
