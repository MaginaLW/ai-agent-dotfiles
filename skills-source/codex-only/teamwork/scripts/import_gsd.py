#!/usr/bin/env python3
"""Convert the PLAN.md files of one GSD phase into a validated teamwork plan."""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def string_list(value, field):
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
        raise ValueError(f"{field} must contain strings")
    return value


def _extract_tag_blocks(body, tag):
    """Extract literal <tag>...</tag> sections while ignoring code spans, outer fences, and stray prose."""
    open_tag = f"<{tag}>"
    close_tag = f"</{tag}>"
    fence_re = re.compile(r"^[ \t]{0,3}(`{3,}|~{3,})")
    blocks = []
    pos = 0
    length = len(body)
    in_outer_fence = None
    capture_start = None
    in_inner_fence = None

    while pos < length:
        if capture_start is None:
            # Check fenced code block start/end at line boundaries.
            line_start = pos == 0 or body[pos - 1] == "\n"
            if line_start:
                fence_match = fence_re.match(body, pos)
                if fence_match:
                    marker = fence_match.group(1)
                    if in_outer_fence is None:
                        in_outer_fence = marker
                    elif marker[0] == in_outer_fence[0] and len(marker) >= len(in_outer_fence):
                        line_end = body.find("\n", fence_match.end())
                        rest = body[fence_match.end():] if line_end == -1 else body[fence_match.end():line_end]
                        if not rest.strip():
                            in_outer_fence = None
                    next_nl = body.find("\n", pos)
                    pos = length if next_nl == -1 else next_nl + 1
                    continue
            if in_outer_fence is not None:
                next_nl = body.find("\n", pos)
                pos = length if next_nl == -1 else next_nl + 1
                continue
            # Skip inline backtick spans outside captured sections.
            if body[pos] == "`":
                ticks = 0
                while pos + ticks < length and body[pos + ticks] == "`":
                    ticks += 1
                closer = body.find("`" * ticks, pos + ticks)
                if closer != -1:
                    pos = closer + ticks
                    continue
                pos += ticks
                continue
            if body.startswith(open_tag, pos):
                capture_start = pos + len(open_tag)
                pos = capture_start
                continue
            pos += 1
        else:
            line_start = pos == 0 or body[pos - 1] == "\n"
            if line_start:
                fence_match = fence_re.match(body, pos)
                if fence_match:
                    marker = fence_match.group(1)
                    if in_inner_fence is None:
                        in_inner_fence = marker
                    elif marker[0] == in_inner_fence[0] and len(marker) >= len(in_inner_fence):
                        line_end = body.find("\n", fence_match.end())
                        rest = body[fence_match.end():] if line_end == -1 else body[fence_match.end():line_end]
                        if not rest.strip():
                            in_inner_fence = None
                    next_nl = body.find("\n", pos)
                    pos = length if next_nl == -1 else next_nl + 1
                    continue
            if in_inner_fence is None and body.startswith(close_tag, pos):
                content = body[capture_start:pos].strip()
                if content:
                    blocks.append(content)
                capture_start = None
                pos += len(close_tag)
                continue
            if in_inner_fence is None and body.startswith(open_tag, pos):
                # An earlier unclosed <tag> was prose; restart at the inner <tag>.
                capture_start = pos + len(open_tag)
                pos = capture_start
                continue
            pos += 1
    return blocks


def verification(frontmatter, body):
    must_haves = frontmatter.get("must_haves", {})
    if not isinstance(must_haves, dict):
        raise ValueError("invalid must_haves")
    checks = list(string_list(must_haves.get("truths", []), "must_haves.truths"))
    # The official frontmatter reader does not expose the Markdown body's checks.
    # Read literal GSD section boundaries, leaving shell syntax and nested markup intact.
    for tag in ("verify", "verification"):
        checks.extend(_extract_tag_blocks(body, tag))
    if not checks:
        raise ValueError("missing must_haves.truths, <verify> or <verification>")
    # verify is one printable string. JSON quoting preserves multiline commands exactly.
    return json.dumps(list(dict.fromkeys(checks)), ensure_ascii=True)


def task_from_plan(filename, metadata, body):
    phase = metadata.get("phase")
    plan = metadata.get("plan")
    if isinstance(plan, int) and not isinstance(plan, bool):
        if plan < 0:
            raise ValueError("expected GSD phase and plan identifiers in frontmatter")
        plan = f"{plan:02d}"
    if not isinstance(phase, str) or not phase.strip() or not isinstance(plan, str) or not plan.strip():
        raise ValueError("expected GSD phase and plan identifiers in frontmatter")
    if str(metadata.get("autonomous", "true")).lower() != "true" or 'type="checkpoint:' in body or "type='checkpoint:" in body:
        raise ValueError("human checkpoint requires explicit mapping before team execution")
    alias = f"{phase.split('-', 1)[0]}-{plan}"
    key = alias if filename == "PLAN.md" else filename.removesuffix("-PLAN.md")
    if "depends_on" not in metadata:
        raise ValueError("missing depends_on; use [] for independent plans")
    files = metadata.get("files_modified")
    if files is None:
        files = metadata.get("files-modified")
    if files is None:
        files = []
    return alias, {
        "id": key,
        "depends_on": string_list(metadata["depends_on"], "depends_on"),
        "files_modified": string_list(files, "files_modified"),
        "verify": verification(metadata, body),
    }


def convert(phase_dir, cli, run, scratch):
    # Never import a module into the live installed skill's __pycache__.
    sys.dont_write_bytecode = True
    from waves import plan_waves, read_plan

    sources = sorted(
        path for path in phase_dir.iterdir()
        if path.is_file() and (path.name == "PLAN.md" or path.name.endswith("-PLAN.md"))
    )
    if not sources:
        raise ValueError(f"no GSD plans in {phase_dir}")
    tasks = []
    aliases = {}
    fallback_aliases = {}
    for source in sources:
        try:
            # Snapshot once so the official parser and verification reader see the same bytes.
            # The parser runs entirely against this private copy, with a scratch cwd.
            raw = source.read_bytes()
            snapshot = scratch / "input.md"
            snapshot.write_bytes(raw)
            proc = subprocess.run(["node", str(cli), "frontmatter", "get", snapshot.name],
                                  cwd=scratch, capture_output=True, encoding="utf-8", check=False)
            if proc.returncode:
                raise ValueError(f"GSD frontmatter get failed: {proc.stderr.strip()}")
            metadata = json.loads(proc.stdout)
            if not isinstance(metadata, dict) or "error" in metadata:
                raise ValueError(f"invalid GSD response: {metadata!r}")
            alias, task = task_from_plan(source.name, metadata, raw.decode("utf-8-sig"))
        except ValueError as exc:
            raise ValueError(f"{source.name}: {exc}") from exc
        if alias in aliases:
            raise ValueError(f"ambiguous GSD plan identifier {alias}")
        aliases[alias] = task["id"]
        raw_plan = metadata.get("plan")
        if isinstance(raw_plan, int) and not isinstance(raw_plan, bool):
            unpadded = f"{metadata['phase'].split('-', 1)[0]}-{raw_plan}"
            if unpadded != alias and unpadded not in aliases:
                fallback_aliases[unpadded] = task["id"]
        tasks.append(task)
    ids = {task["id"] for task in tasks}
    for task in tasks:
        task["depends_on"] = [
            dep if dep in ids else aliases.get(dep, fallback_aliases.get(dep, dep))
            for dep in task["depends_on"]
        ]
    output = json.dumps({"run": run, "tasks": tasks}, indent=2, ensure_ascii=True)
    staged = scratch / "plan.json"
    staged.write_text(output, encoding="utf-8")
    _, specs, gate, _ = read_plan(staged)
    plan_waves(specs, gate)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase_directory", type=Path)
    parser.add_argument("--gsd-tools", required=True, type=Path, help="existing official gsd-tools.cjs")
    parser.add_argument("--run", required=True, help="swarm run identifier")
    args = parser.parse_args()
    try:
        cli = args.gsd_tools.resolve(strict=True)
        with tempfile.TemporaryDirectory() as scratch:
            output = convert(args.phase_directory, cli, args.run, Path(scratch))
    except (OSError, ValueError) as exc:
        parser.exit(2, f"import_gsd: {exc}\n")
    print(output)


if __name__ == "__main__":
    main()
