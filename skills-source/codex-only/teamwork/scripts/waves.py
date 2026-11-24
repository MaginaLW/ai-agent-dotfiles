#!/usr/bin/env python3
"""Plan GSD dependency waves and resume from the sibling swarm board."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter, defaultdict
from graphlib import CycleError, TopologicalSorter
from itertools import combinations
from pathlib import Path, PureWindowsPath


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def name(value, field):
    if not isinstance(value, str) or not value.strip() or value != value.strip() or not value.isprintable():
        raise ValueError(f"{field} must be a nonempty, trimmed string")
    return value


def text_list(task, field):
    values = task.get(field, [])
    if not isinstance(values, list):
        raise ValueError(f"{field} must be an array")
    items = [name(value, field) for value in values]
    if len(items) != len(set(items)):
        raise ValueError(f"{field} contains a duplicate")
    return items


def write_path(value):
    path = PureWindowsPath(value)
    if path.anchor or not path.parts or ".." in path.parts or any(c in value for c in '*?[]:"<>|'):
        raise ValueError(f"files_modified needs a repository-relative literal path, got {value!r}")
    return path


def read_plan(path):
    raw = path.read_bytes()
    plan = json.loads(raw.decode("utf-8-sig"), object_pairs_hook=unique_fields)
    if not isinstance(plan, dict) or plan.keys() - {"run", "tasks", "plan_review"}:
        raise ValueError("plan must be an object with run, tasks and optional plan_review")
    run = name(plan.get("run"), "run")
    if not isinstance(plan.get("tasks"), list) or not plan["tasks"]:
        raise ValueError("tasks must be a nonempty array")
    tasks = {}
    for task in plan["tasks"]:
        if not isinstance(task, dict) or task.keys() - {"id", "verify", "depends_on", "files_modified", "requires_review"}:
            raise ValueError("unexpected task field or invalid task object")
        task_id = name(task.get("id"), "task id")
        if task_id in tasks:
            raise ValueError(f"duplicate task {task_id!r}")
        name(task.get("verify"), f"{task_id}.verify")
        if not isinstance(task.get("requires_review", False), bool):
            raise ValueError(f"{task_id}.requires_review must be boolean")
        tasks[task_id] = {
            **task,
            "depends_on": sorted(text_list(task, "depends_on")),
            "files_modified": [write_path(v) for v in text_list(task, "files_modified")],
        }
    gate = name(plan["plan_review"], "plan_review") if "plan_review" in plan else None
    if gate is not None and (gate not in tasks or not tasks[gate].get("requires_review") or tasks[gate]["depends_on"]):
        raise ValueError("plan_review must name an independent root task with requires_review set")
    return run, tasks, gate, hashlib.sha256(raw).hexdigest()


def plan_waves(tasks, gate):
    # GSD phase-plan-index groups each ready frontier of the depends_on DAG.
    graph = {key: task["depends_on"] for key, task in tasks.items()}
    for key, deps in graph.items():
        unknown = set(deps) - tasks.keys()
        if unknown:
            raise ValueError(f"{key} depends on unknown tasks {sorted(unknown)}")
    sorter = TopologicalSorter(graph)
    try:
        sorter.prepare()
    except CycleError as exc:
        raise ValueError("dependency cycle: " + " -> ".join(exc.args[1])) from exc
    ancestors = {}
    waves = []
    while sorter.is_active():
        wave = sorted(sorter.get_ready())
        for key in wave:
            ancestors[key] = set(graph[key]).union(*(ancestors[dep] for dep in graph[key]))
            if gate and key != gate and gate not in ancestors[key]:
                raise ValueError(f"{key} must depend on plan_review task {gate}")
        waves.append(wave)
        sorter.done(*wave)
    # Dispatch follows released predecessors, so unordered tasks can overlap even
    # at different static wave numbers. Directories own their entire subtree.
    for a, b in combinations(tasks, 2):
        if a in ancestors[b] or b in ancestors[a]:
            continue
        for left in tasks[a]["files_modified"]:
            for right in tasks[b]["files_modified"]:
                if left == right or left in right.parents or right in left.parents:
                    raise ValueError(f"unordered writers {a} and {b} overlap at {left} / {right}")
    return waves


def _import_coordination():
    board_dir = Path(__file__).resolve().parents[2] / "swarm" / "scripts"
    if not (board_dir / "coordination.py").is_file():
        raise ValueError("resume needs the installed sibling swarm/scripts/coordination.py")
    sys.dont_write_bytecode = True
    if str(board_dir) not in sys.path:
        sys.path.insert(0, str(board_dir))
    import coordination

    return coordination


def board_state(manifest):
    coordination = _import_coordination()
    try:
        return coordination.derive_state(coordination.load_manifest(manifest))
    except coordination.BoardError as exc:
        raise ValueError(str(exc)) from exc


def event_index(events, tasks):
    counts = Counter(event["id"] for event in events)
    index = {}
    problems = defaultdict(list)
    for i, event in enumerate(events):
        key = event["task"]
        if key not in tasks:
            continue
        if counts[event["id"]] != 1:
            problems[key].append(f"duplicate event id {event['id']}")
            continue
        index[event["id"]] = (i, event)
        if event["type"] == "depends":
            deps = event["dependsOn"]
            declared = {deps} if isinstance(deps, str) else set(deps)
            extra = declared - set(tasks[key]["depends_on"])
            if extra:
                problems[key].append(f"board dependency absent from plan: {sorted(extra)}")
    return index, problems


def resume(plan, waves, gate, digest, board):
    coordination = _import_coordination()
    existing = {task["id"]: task for task in board["tasks"]}
    index, problems = event_index(board["events"], plan)
    releases = {}
    result = {}
    for wave in waves:
        for key in wave:
            spec = plan[key]
            current = existing.get(key)
            deps = spec["depends_on"]
            waiting = [dep for dep in deps if dep not in releases]
            if current:
                problems[key].extend(coordination.blocking_alerts(current["alerts"]))
                if spec.get("requires_review") and not current["reviewer"]:
                    problems[key].append("board assignment is missing the required independent reviewer")
            if problems[key]:
                result[key] = {"status": "conflict", "reasons": sorted(set(problems[key]))}
                continue
            if waiting:
                result[key] = {"status": "blocked", "waiting_for": waiting}
                continue
            inputs = {dep: releases[dep][0] for dep in deps}
            row = {"status": "ready", "inputs": inputs}
            result[key] = row
            if not current:
                continue
            row.update(owner=current["owner"], reviewer=current["reviewer"], version=current["version"])
            status = current["status"]
            if status == "assigned":
                row["status"] = "assigned"
                continue
            if "submissionId" not in current or "releaseId" not in current:
                raise ValueError("swarm board must expose effective submissionId and releaseId")
            submission = index.get(current["submissionId"])
            if not submission:
                raise ValueError(f"effective submission missing for {key}")
            submit_order, event = submission
            pinned = {dep: version.lower() for dep, version in event.get("inputs", {}).items()}
            if (pinned != inputs
                    or any(releases[dep][1] >= submit_order for dep in deps)
                    or (key == gate and current["version"] != digest)):
                row.update(status="rework", reason="submit a version verified against the current plan and released inputs")
                continue
            if status == "released":
                release = index.get(current["releaseId"])
                if not release or release[0] <= submit_order:
                    raise ValueError(f"effective release missing for {key}")
                releases[key] = (current["version"], release[0])
                row["status"] = "released"
            elif status == "submitted":
                row["status"] = "review" if current["reviewer"] else "release"
            elif status == "approved":
                row["status"] = "release"
            elif status == "returned":
                row.update(status="rework", reason="reviewer requested changes")
            else:
                raise ValueError(f"unknown board status for {key}: {status}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--manifest", type=Path, help="read the same live or archived manifest as swarm")
    args = parser.parse_args()
    try:
        run, tasks, gate, digest = read_plan(args.plan)
        waves = plan_waves(tasks, gate)
        output = {"run": run, "plan_sha256": digest, "waves": waves}
        if args.manifest is not None:
            board = board_state(args.manifest)
            if board["run"] != run:
                raise ValueError("plan and board run names differ")
            rows = resume(tasks, waves, gate, digest, board)
            output.update(tasks=rows, complete=all(row["status"] == "released" for row in rows.values()))
    except (OSError, ValueError) as exc:
        parser.exit(2, f"waves: {exc}\n")
    print(json.dumps(output, indent=2, ensure_ascii=True))


if __name__ == "__main__":
    main()
