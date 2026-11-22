"""Create a Swarm run and publish versioned workflow events from a member's outbox."""

import argparse
import hashlib
import json
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

if __name__ == "__main__":
    sys.dont_write_bytecode = True  # A live skills directory is managed by the deployer.

import coordination
import member_mailbox


def initialize(directory, name, members):
    destination = directory.absolute()
    name = coordination._plain_string(name, "run")
    if destination.exists():
        raise ValueError("choose a new run directory")
    actors = {}
    local = []
    for member in ["Lead", *members]:
        actor, sep, external = member.partition("=")
        if (not coordination.ACTOR_NAME_RE.fullmatch(actor) or actor.endswith(".")
                or Path(actor).is_reserved() or actor.casefold() in {a.casefold() for a in actors}):
            raise ValueError(f"invalid or duplicate member: {actor}")
        outbox = Path(external) if sep else destination / "members" / actor
        if sep:
            if not outbox.is_absolute() or not coordination._is_directory_no_symlink(outbox):
                raise ValueError(f"{actor} needs an existing absolute outbox directory")
        else:
            local.append(actor)
        actors[actor] = outbox.absolute()
    # Validate all paths before creating anything, including worker-owned directories.
    for actor, outbox in actors.items():
        if any(outbox == other or outbox in other.parents or other in outbox.parents
               for key, other in actors.items() if key != actor):
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
            if (task["status"] != required or task["alerts"] or task["version"] != fields["version"]
                    or task["submissionId"] != fields.get("replyTo")):
                raise ValueError("release requires the accepted artifact and resolved Sentinel alerts")
    return member_mailbox.publish(manifest, args.id, fields)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init")
    init.add_argument("directory", type=Path)
    init.add_argument("--name", required=True)
    init.add_argument("--member", action="append", default=[], metavar="NAME[=EXISTING_OUTBOX]")
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
        result = initialize(args.directory, args.name, args.member) if args.command == "init" else publish(args)
    except (OSError, ValueError, coordination.BoardError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
