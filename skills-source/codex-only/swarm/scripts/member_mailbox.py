#!/usr/bin/env python3
"""Cooperative member mail over the swarm board's append-only event files.

Invoke from the current member's own manifest outbox. Isolation of writers
comes from the host's workspace permissions. Polling or viewing the board
does not create a read receipt. See NOTICE-herdr.txt for the upstream sources.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import stat
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
import coordination as board
from coordination import _addressed_mail, _matches_receipt, _unique_events, delivery_receipts


def current_actor(manifest: board.Manifest) -> str:
    directory = Path.cwd()
    for name, outbox in manifest.actors.items():
        if directory == outbox and board._is_directory_no_symlink(outbox):
            return name
    raise board.BoardError("run the command from your own manifest actor directory")


def _thread_of(events: list[dict], root: str) -> list[dict]:
    """Adapted from herdr_team/cmd_board.py:_thread_of with receipt validation."""
    unique = _unique_events(events)
    wanted = {root}
    changed = True
    while changed:
        changed = False
        for event_id, record in unique.items():
            parent = record.get("replyTo")
            if event_id not in wanted and parent in wanted and _matches_receipt(record, unique[parent]):
                wanted.add(event_id)
                changed = True
    return [record for event_id, record in unique.items() if event_id in wanted]


def _same_request(existing: dict, candidate: dict) -> dict:
    if {k: v for k, v in existing.items() if k != "at"} != {k: v for k, v in candidate.items() if k != "at"}:
        raise board.BoardError(f"event id already has a different payload: {candidate['id']}")
    return existing


def publish(manifest: board.Manifest, key: str, fields: dict) -> dict:
    """Validate and append an event once. Only the actor's current directory is writable."""
    actor = current_actor(manifest)
    if not isinstance(key, str) or not board.ACTOR_NAME_RE.fullmatch(key):
        raise board.BoardError("use a stable id key matching [A-Za-z0-9][A-Za-z0-9_.-]*")
    if {"from", "id", "run", "at"}.intersection(fields):
        raise board.BoardError("from, id, run and at are assigned by the publisher")
    event_id = f"{actor}/{fields.get('type')}/{key}"
    event = board._validate_event(
        {**fields, "id": event_id, "run": manifest.run, "from": actor,
         "at": datetime.now(timezone.utc).isoformat()},
        run=manifest.run, actor=actor, actors=manifest.actors,
    )
    data = (json.dumps(event, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
    if len(data) > board.MAX_EVENT_BYTES:
        raise board.BoardError("event exceeds the board file size limit")
    # Also respect a compatible event created under an older, arbitrary filename.
    matches = [item for item in board.collect_events(manifest) if item["id"] == event_id]
    if len(matches) > 1:
        raise board.BoardError(f"ambiguous event id: {event_id}")
    if matches:
        return _same_request(matches[0], event)

    directory = manifest.actors[actor]
    # Hash the logical id. User text and ids never compose a filesystem path.
    final = directory / ("mail-" + hashlib.sha256(event_id.encode("utf-8")).hexdigest() + ".json")
    fd, temporary = tempfile.mkstemp(prefix=".swarm-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            if os.name == "nt":
                os.rename(temporary, final)  # Windows rename never replaces an existing destination.
            else:
                os.link(temporary, final)  # POSIX rename would overwrite a concurrent winner.
        except FileExistsError:
            info = final.lstat()
            if not stat.S_ISREG(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise board.BoardError(f"occupied event filename: {final.name}")
            existing = board._validate_event(
                json.loads(board._read_regular_file(final).decode("utf-8-sig")),
                run=manifest.run, actor=actor, actors=manifest.actors,
            )
            return _same_request(existing, event)
        board._fsync_directory(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return event


def _get_mail(events: list[dict], event_id: str) -> dict:
    matches = [event for event in events if event["id"] == event_id]
    if len(matches) != 1 or matches[0]["type"] not in {"message", "reply"}:
        raise board.BoardError(f"expected one message or reply with id: {event_id}")
    return matches[0]


def _inbox(manifest: board.Manifest, actor: str, args: argparse.Namespace) -> dict:
    if not math.isfinite(args.wait_seconds) or args.wait_seconds < 0:
        raise board.BoardError("wait-seconds must be a finite nonnegative number")
    deadline = time.monotonic() + args.wait_seconds
    while True:
        events = board.collect_events(manifest)
        states = delivery_receipts(events)
        mail = [item for item in events if item["id"] in states and _addressed_mail(item, actor)]
        pending = [item for item in mail if states[item["id"]] == "pending"]
        remaining = deadline - time.monotonic()
        if args.availability == "busy" or pending or remaining <= 0:
            shown = [] if args.availability == "busy" else (mail if args.all else pending)
            return {
                "actor": actor, "availability": args.availability, "pending": len(pending),
                "messages": [{"state": states[item["id"]], "event": item} for item in shown],
            }
        # Reload peer outboxes when a worker changes worktrees during the wait.
        time.sleep(min(0.5, remaining))
        try:
            updated = board.load_manifest(manifest.path)
        except OSError:
            if time.monotonic() >= deadline:
                raise
            continue
        except board.BoardError as exc:
            if isinstance(exc.__cause__, OSError) and time.monotonic() < deadline:
                continue
            raise
        if updated.run != manifest.run or current_actor(updated) != actor:
            raise board.BoardError("the polling member or run changed during the wait")
        manifest = updated


def _run(args: argparse.Namespace) -> dict:
    manifest = board.load_manifest(args.manifest)
    actor = current_actor(manifest)
    if args.command == "inbox":
        return _inbox(manifest, actor, args)
    if args.command == "send":
        recipient = board._actor_reference(args.to, manifest.actors, "to")
        if recipient == actor:
            raise board.BoardError("select a different recipient")
        return publish(manifest, args.id, {"type": "message", "to": recipient, "task": args.task, "text": args.text})

    events = board.collect_events(manifest)
    source = _get_mail(events, args.event_id)
    if args.command == "status":
        states = delivery_receipts(events)
        if source["id"] not in states or (source["from"] != actor and not _addressed_mail(source, actor)):
            raise board.BoardError("status is for the sender or recipient of a message")
        return {"event": source, "state": states[source["id"]], "thread": _thread_of(events, source["id"])}
    if not _addressed_mail(source, actor):
        raise board.BoardError("only the addressed recipient can acknowledge or reply")
    receipt = {"type": args.command, "task": source["task"], "to": source["from"], "replyTo": source["id"]}
    if args.command == "reply":
        receipt["text"] = args.text
    key = hashlib.sha256(source["id"].encode("utf-8")).hexdigest()
    return publish(manifest, key, receipt)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    send = commands.add_parser("send", help="post one message using a stable retry key")
    send.add_argument("--to", required=True)
    send.add_argument("--task", required=True)
    send.add_argument("--id", required=True)
    send.add_argument("--text", required=True)
    inbox = commands.add_parser("inbox", help="poll addressed messages without acknowledging them")
    inbox.add_argument("--availability", choices=("idle", "busy"), default="idle")
    inbox.add_argument("--all", action="store_true", help="include acknowledged and replied history when idle")
    inbox.add_argument("--wait-seconds", type=float, default=0, help="when idle, wait up to this long for pending mail")
    for name in ("ack", "reply", "status"):
        command = commands.add_parser(name)
        command.add_argument("event_id", help="the full id of the original message or reply")
        if name == "reply":
            command.add_argument("--text", required=True)
    try:
        result = _run(parser.parse_args())
    except (board.BoardError, OSError, ValueError) as exc:
        parser.exit(1, f"mailbox: {exc}\n")
    # ASCII escapes round-trip Unicode even on a redirected Windows console.
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
