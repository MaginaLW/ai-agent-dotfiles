#!/usr/bin/env python3
"""A small, read-only coordination board for local subagent development.

Actors publish append-only JSON event files in their own directories.  This
program never changes those directories: every API request replays the selected
directories and derives the current task state from the event stream.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit


EVENT_TYPES = frozenset(
    {
        "assign",
        "message",
        "reply",
        "ack",
        "submit",
        "changes",
        "approve",
        "release",
        "depends",
    }
)
COMMUNICATION_TYPES = frozenset({"message", "reply", "ack"})
WORKFLOW_TYPES = frozenset({"assign", "submit", "changes", "approve", "release"})
MAX_EVENT_BYTES = 2 * 1024 * 1024
ACTOR_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
LEAD = "Lead"


class BoardError(Exception):
    """An expected board or manifest error."""


@dataclass(frozen=True)
class Manifest:
    """A validated manifest and its explicitly selected event directories."""

    path: Path
    run: str
    actors: dict[str, Path]


@dataclass
class TaskState:
    owner: str
    reviewer: str | None
    version: str | None = None
    status: str = "assigned"
    approved_version: str | None = None
    alerts: set[str] = field(default_factory=set)


def _plain_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise ValueError(f"{field} must be a non-empty, trimmed string")
    if any(ord(char) < 0x20 for char in value):
        raise ValueError(f"{field} contains a control character")
    return value


def _absolute_directory(value: Any) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError("actor directory must be a non-empty string")
    path = Path(value)
    if not path.is_absolute():
        raise ValueError(f"actor directory is not absolute: {value}")
    return Path(os.path.abspath(os.path.normpath(os.fspath(path))))


def _same_path(left: Path, right: Path) -> bool:
    return os.path.normcase(os.fspath(left)) == os.path.normcase(os.fspath(right))


def _is_directory_no_symlink(path: Path) -> bool:
    try:
        chain = (path, *path.parents)
        for component in chain:
            info = component.lstat()
            if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                return False
        mode = path.lstat().st_mode
    except OSError:
        return False
    return stat.S_ISDIR(mode) and not stat.S_ISLNK(mode)


def load_manifest(path: Path | str) -> Manifest:
    """Load and validate a manifest without following actor-directory symlinks."""

    manifest_path = Path(path)
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BoardError(f"cannot read manifest {manifest_path}: {exc}") from exc

    if not isinstance(data, dict):
        raise BoardError("manifest must be a JSON object")
    run = data.get("run")
    try:
        run = _plain_string(run, "run")
    except ValueError as exc:
        raise BoardError(str(exc)) from exc

    raw_actors = data.get("actors")
    if not isinstance(raw_actors, dict) or not raw_actors:
        raise BoardError("manifest actors must be a non-empty object")
    if LEAD not in raw_actors:
        raise BoardError(f"manifest actors must include {LEAD}")

    actors: dict[str, Path] = {}
    seen_paths: list[Path] = []
    for name, value in raw_actors.items():
        try:
            plain_name = _plain_string(name, "actor name")
        except ValueError as exc:
            raise BoardError(str(exc)) from exc
        if not ACTOR_NAME_RE.fullmatch(plain_name):
            raise BoardError(f"invalid actor name: {name!r}")
        try:
            directory = _absolute_directory(value)
        except ValueError as exc:
            raise BoardError(str(exc)) from exc
        if not _is_directory_no_symlink(directory):
            raise BoardError(f"actor directory is not a real directory: {directory}")
        if any(_same_path(directory, old) for old in seen_paths):
            raise BoardError(f"actor directories must be unique: {directory}")
        # Nested selected directories would make one event observable under two
        # actor identities.  Sibling event directories are the supported layout.
        for old in seen_paths:
            if directory in old.parents or old in directory.parents:
                raise BoardError(
                    "actor directories must not contain another actor directory: "
                    f"{old} and {directory}"
                )
        actors[plain_name] = directory
        seen_paths.append(directory)

    return Manifest(manifest_path.absolute(), run, actors)


def _parse_utc(value: Any) -> datetime:
    if not isinstance(value, str) or not value:
        raise ValueError("at must be a UTC ISO-8601 string")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    except ValueError as exc:
        raise ValueError("at must be a UTC ISO-8601 string") from exc
    if parsed.tzinfo is None or parsed.utcoffset() != timezone.utc.utcoffset(parsed):
        raise ValueError("at must be in UTC")
    return parsed.astimezone(timezone.utc)


def _actor_reference(value: Any, actors: dict[str, Path], field: str) -> str:
    plain = _plain_string(value, field)
    if plain.startswith("@"):
        plain = plain[1:]
    if plain not in actors:
        raise ValueError(f"{field} names an unknown actor")
    return plain


def _digest(value: Any) -> str:
    plain = _plain_string(value, "version")
    if not SHA256_RE.fullmatch(plain):
        raise ValueError("version must be a 64-character SHA-256 digest")
    return plain.lower()


def _dependencies(value: Any) -> list[str]:
    if isinstance(value, str):
        values: list[Any] = [value]
    elif isinstance(value, list):
        values = value
    else:
        raise ValueError("dependsOn must be a task id or list of task ids")
    if not values:
        raise ValueError("dependsOn must not be empty")
    return [_plain_string(item, "dependsOn item") for item in values]


def _validate_event(
    value: Any,
    *,
    run: str,
    actor: str,
    actors: dict[str, Path],
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("event must be a JSON object")
    event = value
    _plain_string(event.get("id"), "id")
    if event.get("run") != run:
        raise ValueError("event run does not match the manifest")
    if event.get("from") != actor:
        raise ValueError("event from does not match its actor directory")
    event_type = _plain_string(event.get("type"), "type")
    if event_type == "question":
        event_type = "message"
        event = {**event, "type": event_type, "sourceType": "question"}
    if event_type not in EVENT_TYPES:
        raise ValueError(f"unsupported event type: {event_type}")
    _plain_string(event.get("task"), "task")
    _parse_utc(event.get("at"))

    if event.get("replyTo") is not None:
        _plain_string(event["replyTo"], "replyTo")
    if event.get("text") is not None and not isinstance(event["text"], str):
        raise ValueError("text must be a string")
    if "requiresReview" in event and not isinstance(event["requiresReview"], bool):
        raise ValueError("requiresReview must be boolean")

    version: str | None = None
    if "version" in event and event["version"] is not None:
        version = _digest(event["version"])

    if "to" in event and event["to"] is not None:
        _actor_reference(event.get("to"), actors, "to")

    if event_type == "assign":
        if actor != LEAD:
            raise ValueError("only Lead can assign")
        owner = _actor_reference(event.get("to"), actors, "to")
        reviewer = event.get("reviewer")
        if reviewer is None and event.get("requiresReview", False):
            raise ValueError("reviewer must be named when review is required")
        if reviewer is not None and (not isinstance(reviewer, str) or reviewer not in actors):
            raise ValueError("reviewer must be a plain known actor name")
        if owner == LEAD or reviewer == LEAD:
            raise ValueError("owner and reviewer must be plain executors")
        if reviewer == owner:
            raise ValueError("reviewer must be independent of the owner")
    elif event_type in COMMUNICATION_TYPES:
        _actor_reference(event.get("to"), actors, "to")
    elif event_type == "depends":
        if actor != LEAD:
            raise ValueError("only Lead can register a task dependency")
        _dependencies(event.get("dependsOn"))
    elif event_type in {"submit", "changes", "approve", "release"}:
        if version is None:
            raise ValueError(f"{event_type} requires version")
        if event_type == "release" and actor != LEAD:
            raise ValueError("only Lead can release")
        if event_type == "submit" and actor == LEAD:
            raise ValueError("Lead cannot submit an implementation")
    else:  # pragma: no cover - the type set above makes this unreachable.
        raise ValueError(f"unsupported event type: {event_type}")

    if "reviewer" in event and event["reviewer"] is not None and event_type != "assign":
        raise ValueError("reviewer is only valid on assign events")
    if "dependsOn" in event and event["dependsOn"] is not None and event_type != "depends":
        raise ValueError("dependsOn is only valid on depends events")
    return event


def _read_regular_file(path: Path) -> bytes:
    """Read a direct regular file without accepting a symlink substitute."""

    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if nofollow:
        flags |= nofollow
    try:
        fd = os.open(path, flags)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise OSError("not a regular file")
            if info.st_size > MAX_EVENT_BYTES:
                raise OSError("event file is too large")
            chunks: list[bytes] = []
            remaining = MAX_EVENT_BYTES
            while True:
                chunk = os.read(fd, min(65536, remaining + 1))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
                if remaining < 0:
                    raise OSError("event file is too large")
            return b"".join(chunks)
        finally:
            os.close(fd)
    except OSError as exc:
        raise OSError(f"cannot read regular file {path}: {exc}") from exc


def _event_sort_key(event: dict[str, Any]) -> tuple[Any, ...]:
    return (
        _parse_utc(event["at"]).timestamp(),
        event["id"],
        event["from"],
        event["type"],
        event["task"],
        json.dumps(event, sort_keys=True, separators=(",", ":")),
    )


def collect_events(manifest: Manifest) -> list[dict[str, Any]]:
    """Collect valid events from direct files in the selected actor dirs."""

    events: list[dict[str, Any]] = []
    for actor, directory in manifest.actors.items():
        if not _is_directory_no_symlink(directory):
            raise BoardError(f"actor directory is unavailable: {actor}")
        try:
            entries = list(os.scandir(directory))
        except OSError as exc:
            raise BoardError(f"cannot scan actor directory {directory}: {exc}") from exc
        for entry in sorted(entries, key=lambda item: item.name):
            try:
                if not entry.name.endswith(".json") or entry.is_symlink() or not entry.is_file(follow_symlinks=False):
                    continue
                raw = _read_regular_file(Path(entry.path))
                value = json.loads(raw.decode("utf-8-sig"))
                event = _validate_event(
                    value, run=manifest.run, actor=actor, actors=manifest.actors
                )
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                # A partially written or invalid file is not an event.  The
                # publishers' atomic final names make this race very small.
                continue
            events.append(event)
    events.sort(key=_event_sort_key)
    return events


def _task_node(task: str) -> str:
    return f"task:{task}"


def _edges(events: Iterable[dict[str, Any]]) -> list[dict[str, str]]:
    edges: list[dict[str, str]] = []
    for event in events:
        event_type = event["type"]
        if event_type in COMMUNICATION_TYPES:
            to = event["to"]
            target = to[1:] if isinstance(to, str) and to.startswith("@") else to
            edges.append(
                {
                    "from": event["from"],
                    "to": target,
                    "type": event_type,
                    "eventId": event["id"],
                }
            )
        elif event_type in WORKFLOW_TYPES:
            edges.append(
                {
                    "from": event["from"],
                    "to": _task_node(event["task"]),
                    "type": event_type,
                    "eventId": event["id"],
                }
            )
        elif event_type == "depends":
            for dependency in _dependencies(event.get("dependsOn")):
                edges.append(
                    {
                        "from": _task_node(event["task"]),
                        "to": _task_node(dependency),
                        "type": event_type,
                        "eventId": event["id"],
                    }
                )
    return edges


def _apply_effective_event(task: TaskState, event: dict[str, Any]) -> None:
    event_type = event["type"]
    actor = event["from"]
    version = _digest(event["version"]) if event.get("version") is not None else None

    if event_type == "submit":
        if actor == task.owner and version != task.version:
            task.version = version
            task.status = "submitted"
            task.approved_version = None
        return

    if event_type not in {"changes", "approve", "release"}:
        return

    if event_type == "release":
        if (
            actor == LEAD
            and version == task.version
            and ((task.status == "approved" and task.approved_version == version)
                 or (task.reviewer is None and task.status == "submitted"))
        ):
            task.status = "released"
        return

    if actor != task.reviewer or task.status != "submitted":
        if actor == task.reviewer and version != task.version:
            task.alerts.add("stale review")
        return

    if version != task.version:
        task.alerts.add("stale review")
        return

    if event_type == "changes":
        task.alerts.discard("stale review")
        task.status = "returned"
    else:
        task.alerts.discard("stale review")
        task.status = "approved"
        task.approved_version = version


def derive_state(manifest: Manifest) -> dict[str, Any]:
    """Replay all events and produce the complete Board API state."""

    events = collect_events(manifest)
    id_counts = Counter(event["id"] for event in events)
    duplicate_ids = {event_id for event_id, count in id_counts.items() if count > 1}
    effective_events = [event for event in events if event["id"] not in duplicate_ids]

    tasks: dict[str, TaskState] = {}
    assignments: dict[str, tuple[str, str | None]] = {}
    conflicting_tasks: set[str] = set()
    duplicate_alert_tasks: defaultdict[str, set[str]] = defaultdict(set)
    for event in events:
        if event["id"] in duplicate_ids:
            duplicate_alert_tasks[event["task"]].add(event["id"])

    for event in effective_events:
        task_id = event["task"]
        if event["type"] != "assign":
            if task_id in tasks:
                _apply_effective_event(tasks[task_id], event)
            continue
        to = event["to"]
        owner = to[1:] if isinstance(to, str) and to.startswith("@") else to
        assignment = (owner, event.get("reviewer"))
        previous = assignments.get(task_id)
        if previous is None:
            assignments[task_id] = assignment
            tasks[task_id] = TaskState(owner=assignment[0], reviewer=assignment[1])
        elif previous != assignment:
            conflicting_tasks.add(task_id)

    result_tasks: list[dict[str, Any]] = []
    for task_id in sorted(tasks):
        task = tasks[task_id]
        alerts = set(task.alerts)
        if task_id in conflicting_tasks:
            alerts.add("conflicting task id")
        for event_id in sorted(duplicate_alert_tasks.get(task_id, ())):
            alerts.add(f"duplicate event id: {event_id}")
        if task.status == "submitted" and task.reviewer:
            alerts.add("missing review")
        elif task.status == "returned":
            alerts.add("returned review")

        blocked = task_id in conflicting_tasks or bool(duplicate_alert_tasks.get(task_id))
        if task.status == "released" and blocked:
            # A conflict cannot be unobserved by a later event.  If state was
            # released before replay reached the conflicting event, expose the
            # release as blocked rather than reporting it as clean.
            task.status = "approved"
        result_tasks.append(
            {
                "id": task_id,
                "owner": task.owner,
                "reviewer": task.reviewer,
                "version": task.version,
                "status": task.status,
                "alerts": sorted(alerts),
            }
        )

    return {
        "run": manifest.run,
        "actors": sorted(manifest.actors),
        "tasks": result_tasks,
        "events": events,
        "edges": _edges(events),
    }


def _write_atomic(path: Path, data: bytes) -> None:
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _fsync_directory(path: Path) -> None:
    # Directory fsync is not available on every Python/Windows combination;
    # durability is best-effort at that boundary and event files are still fsynced.
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def archive_manifest(manifest_path: Path | str, archive_path: Path | str) -> Path:
    """Create an atomically renamed, self-contained archive of current events."""

    manifest = load_manifest(manifest_path)
    target = Path(archive_path)
    if not target.is_absolute():
        target = Path(os.path.abspath(os.fspath(target)))
    if target.exists() or target.is_symlink():
        raise BoardError(f"archive target already exists: {target}")
    if any(target == directory or directory in target.parents for directory in manifest.actors.values()):
        raise BoardError("archive target must be outside the selected actor directories")
    parent = target.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise BoardError(f"cannot create archive parent {parent}: {exc}") from exc
    if not _is_directory_no_symlink(parent):
        raise BoardError(f"archive parent is not a real directory: {parent}")
    if target.parent != Path(os.path.abspath(os.fspath(parent))):
        raise BoardError("archive target changed unexpectedly")

    stage = Path(tempfile.mkdtemp(prefix=f".{target.name}.tmp-", dir=parent))
    try:
        events_root = stage / "events"
        events_root.mkdir()
        archive_actors: dict[str, str] = {}
        saved = 0
        for actor, source_directory in manifest.actors.items():
            actor_directory = events_root / actor
            actor_directory.mkdir()
            archive_actors[actor] = os.fspath(target / "events" / actor)
            entries = sorted(os.scandir(source_directory), key=lambda item: item.name)
            for entry in entries:
                try:
                    if not entry.name.endswith(".json") or entry.is_symlink() or not entry.is_file(follow_symlinks=False):
                        continue
                    raw = _read_regular_file(Path(entry.path))
                    value = json.loads(raw.decode("utf-8-sig"))
                    event = _validate_event(
                        value, run=manifest.run, actor=actor, actors=manifest.actors
                    )
                except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                    continue
                destination = actor_directory / entry.name
                if destination.parent != actor_directory:
                    raise BoardError("unsafe archive filename")
                _write_atomic(destination, raw)
                saved += 1
            _fsync_directory(actor_directory)
        _fsync_directory(events_root)

        standalone = {
            "run": manifest.run,
            "actors": archive_actors,
        }
        manifest_bytes = (
            json.dumps(standalone, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
        ).encode("utf-8")
        _write_atomic(stage / "manifest.json", manifest_bytes)
        _fsync_directory(stage)
        os.replace(stage, target)
        _fsync_directory(parent)
        print(f"archived {saved} events to {target}", flush=True)
        return target
    except Exception as exc:
        # Only remove the private staging directory created above.
        if stage.exists() and stage.parent == parent and stage.name.startswith(
            f".{target.name}.tmp-"
        ):
            shutil.rmtree(stage, ignore_errors=True)
        if isinstance(exc, BoardError):
            raise
        raise BoardError(f"cannot create archive {target}: {exc}") from exc


class BoardHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, address: tuple[str, int], manifest: Manifest) -> None:
        self.manifest = manifest
        super().__init__(address, BoardRequestHandler)


class BoardRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SubagentCoordination/1.0"
    sys_version = ""

    @property
    def board(self) -> BoardHTTPServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _reject(self, status: int, reason: str) -> None:
        body = (json.dumps({"error": reason}, sort_keys=True) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _allowed_host(self) -> bool:
        host = self.headers.get("Host", "")
        parsed = urlsplit(f"//{host}")
        hostname = (parsed.hostname or "").lower()
        return hostname in {"127.0.0.1", "localhost", "::1"}

    def _allowed_origin(self) -> bool:
        origin = self.headers.get("Origin")
        if origin is None:
            return True
        parsed = urlsplit(origin)
        if parsed.scheme.lower() != "http":
            return False
        hostname = (parsed.hostname or "").lower()
        if hostname not in {"127.0.0.1", "localhost", "::1"}:
            return False
        try:
            port = parsed.port
        except ValueError:
            return False
        return port == self.server.server_address[1]

    def _send_bytes(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self._allowed_host() or not self._allowed_origin():
            self._reject(403, "forbidden host or origin")
            return
        path = urlsplit(self.path).path
        if path == "/api/state":
            try:
                # The lead publishes a replacement manifest when actors join or
                # their finalized outboxes move to the verified archive.
                state = derive_state(load_manifest(self.board.manifest.path))
                body = (
                    json.dumps(state, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
                    + "\n"
                ).encode("utf-8")
            except BoardError as exc:
                self._reject(500, str(exc))
                return
            self._send_bytes(200, "application/json; charset=utf-8", body)
            return

        if path == "/":
            html_path = Path(__file__).with_name("coordination.html")
            try:
                if html_path.is_symlink():
                    raise OSError("coordination.html is a symlink")
                body = _read_regular_file(html_path)
            except OSError:
                self._reject(404, "board UI unavailable")
                return
            self._send_bytes(200, "text/html; charset=utf-8", body)
            return

        self._reject(404, "not found")

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.do_GET()

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._reject(405, "method not allowed")


def serve(manifest: Manifest, port: int = 0) -> BoardHTTPServer:
    if not isinstance(port, int) or not 0 <= port <= 65535:
        raise BoardError("port must be between 0 and 65535")
    try:
        return BoardHTTPServer(("127.0.0.1", port), manifest)
    except OSError as exc:
        raise BoardError(f"cannot bind 127.0.0.1:{port}: {exc}") from exc


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local read-only subagent coordination board")
    parser.add_argument("--manifest", required=True, type=Path, help="path to manifest.json")
    parser.add_argument("--port", type=int, default=0, help="local port (default: 0)")
    parser.add_argument(
        "--archive",
        type=Path,
        help="create an offline standalone archive at a new directory, then exit",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.archive is not None:
            archive_manifest(args.manifest, args.archive)
            return 0
        manifest = load_manifest(args.manifest)
        server = serve(manifest, args.port)
    except BoardError as exc:
        print(f"coordination: {exc}", file=sys.stderr, flush=True)
        return 2

    host, actual_port = server.server_address[:2]
    print(f"http://{host}:{actual_port}/", flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
