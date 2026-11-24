#!/usr/bin/env python3
"""Focused tests for security-ownership-map scripts."""

from __future__ import annotations

import contextlib
import csv
import io
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
SCRIPTS = (
    Path(__file__).resolve().parents[1]
    / "skills-source"
    / "codex-only"
    / "security-ownership-map"
    / "scripts"
)
sys.path.insert(0, str(SCRIPTS))
import build_ownership_map as bom  # noqa: E402
import community_maintainers as cm  # noqa: E402
import query_ownership as qo  # noqa: E402


def _git(repo: Path, *args: str, env: dict[str, str] | None = None) -> str:
    import os

    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=merged_env,
        check=True,
    )
    return proc.stdout


class SecurityOwnershipMapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_decay_formula_uses_ln2_and_clamps_negative_age(self) -> None:
        self.assertEqual(cm.recency_weight(0.0, 180.0), 1.0)
        self.assertEqual(cm.recency_weight(-10.0, 180.0), 1.0)
        self.assertAlmostEqual(cm.recency_weight(180.0, 180.0), 0.5, places=9)
        self.assertAlmostEqual(cm.recency_weight(360.0, 180.0), 0.25, places=9)
        self.assertAlmostEqual(
            cm.recency_weight(45.0, 90.0),
            math.exp(-math.log(2) * 45.0 / 90.0),
            places=12,
        )

    def test_load_sensitive_rules_csv_header_quotes_and_comments(self) -> None:
        cfg = self.root / "sensitive.csv"
        cfg.write_text(
            "\n".join(
                [
                    "# comment line",
                    "pattern,tag,weight",
                    '"**/auth/**",auth,2.5',
                    "**/crypto/**,crypto,1.5",
                    "",
                ]
            ),
            encoding="utf-8-sig",
        )
        rules = bom.load_sensitive_rules(str(cfg))
        self.assertEqual(
            rules,
            [("**/auth/**", "auth", 2.5), ("**/crypto/**", "crypto", 1.5)],
        )

    def test_utf8_non_ascii_paths_and_authors_in_git_log(self) -> None:
        repo = self.root / "repo"
        repo.mkdir()
        _git(repo, "init")
        _git(repo, "config", "user.name", "张伟")
        _git(repo, "config", "user.email", "zhangwei@example.com")

        rel_path = Path("src/安全模块/auth_模块.py")
        target = repo / rel_path
        target.parent.mkdir(parents=True)
        target.write_text("# 权限校验\n", encoding="utf-8")
        _git(repo, "add", str(rel_path))
        _git(
            repo,
            "commit",
            "-m",
            "Add non-ASCII auth file",
            env={
                "GIT_AUTHOR_DATE": "2026-02-10T10:00:00+08:00",
                "GIT_COMMITTER_DATE": "2026-02-10T10:00:00+08:00",
            },
        )

        out_dir = self.root / "out"
        proc = subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPTS / "build_ownership_map.py"),
                "--repo",
                str(repo),
                "--out",
                str(out_dir),
                "--no-communities",
                "--emit-commits",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

        with (out_dir / "files.csv").open("r", encoding="utf-8") as handle:
            files_rows = list(csv.DictReader(handle))
        self.assertEqual([row["path"] for row in files_rows], ["src/安全模块/auth_模块.py"])

        with (out_dir / "people.csv").open("r", encoding="utf-8") as handle:
            people_rows = list(csv.DictReader(handle))
        self.assertEqual(people_rows[0]["name"], "张伟")

        # Also exercise community_maintainers git log path with non-ASCII path.
        (out_dir / "commits.jsonl").unlink()
        (out_dir / "communities.json").write_text(
            json.dumps([{"id": 1, "size": 1, "files": ["src/安全模块/auth_模块.py"]}]),
            encoding="utf-8",
        )
        cm_proc = subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPTS / "community_maintainers.py"),
                "--data-dir",
                str(out_dir),
                "--repo",
                str(repo),
                "--file",
                "auth_模块.py",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )
        self.assertEqual(cm_proc.returncode, 0, cm_proc.stderr)
        rows = list(csv.DictReader(io.StringIO(cm_proc.stdout)))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["period"], "2026-02")
        self.assertEqual(rows[0]["name"], "张伟")

    def test_utc_monthly_bucketing_and_find_file_node_ignores_person(self) -> None:
        data_dir = self.root / "utc-data"
        data_dir.mkdir()
        (data_dir / "people.csv").write_text(
            "person_id,name,email,primary_tz_offset\nalice@example.com,Alice,alice@example.com,-05:00\n",
            encoding="utf-8",
        )
        # Include a person node matching "alice" and a file node matching "alice_service.py"
        (data_dir / "ownership.graph.json").write_text(
            json.dumps(
                {
                    "nodes": [
                        {"id": "alice@example.com", "node_type": "person", "community_id": 99},
                        {"id": "src/alice_service.py", "node_type": "file", "community_id": 1},
                    ],
                    "edges": [],
                }
            ),
            encoding="utf-8",
        )
        # 2026-01-31T20:00:00-05:00 == 2026-02-01T01:00:00Z -> must bucket into 2026-02!
        (data_dir / "commits.jsonl").write_text(
            json.dumps(
                {
                    "hash": "abc123",
                    "parents": [],
                    "is_merge": False,
                    "author_name": "Alice",
                    "author_email": "alice@example.com",
                    "author_date": "2026-01-31T20:00:00-05:00",
                    "committer_name": "Alice",
                    "committer_email": "alice@example.com",
                    "committer_date": "2026-01-31T20:00:00-05:00",
                    "files": ["src/alice_service.py"],
                }
            )
            + "\n",
            encoding="utf-8",
        )

        # find_file_node must ignore person node "alice@example.com" when querying "alice"
        node = cm.find_file_node(
            json.loads((data_dir / "ownership.graph.json").read_text(encoding="utf-8"))["nodes"],
            "alice",
        )
        self.assertEqual(node["id"], "src/alice_service.py")

        proc = subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPTS / "community_maintainers.py"),
                "--data-dir",
                str(data_dir),
                "--file",
                "alice",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = list(csv.DictReader(io.StringIO(proc.stdout)))
        self.assertEqual([(r["period"], r["email"]) for r in rows], [("2026-02", "alice@example.com")])

    def test_query_ownership_sort_none_validation_and_files_truncated(self) -> None:
        data_dir = self.root / "query-data"
        data_dir.mkdir()
        (data_dir / "people.csv").write_text(
            "person_id,name,email,touches,commit_count,sensitive_touches,primary_tz_offset\n"
            "a@x,A,a@x,3,2,1.0,+00:00\n",
            encoding="utf-8",
        )
        (data_dir / "files.csv").write_text(
            "file_id,path,touches,commit_count,bus_factor,sensitivity_score,sensitivity_tags,last_seen\n"
            "f.py,f.py,3,2,1,1.0,auth,2026-01-01T00:00:00Z\n",
            encoding="utf-8",
        )
        (data_dir / "communities.json").write_text(
            json.dumps(
                [
                    {"id": 1, "size": 5, "files": ["a.py", "b.py", "c.py"]},
                    {"id": 2, "size": 2, "files": ["x.py", "y.py"]},
                ]
            ),
            encoding="utf-8",
        )

        # sort_records handles None safely and rejects invalid keys
        sorted_items = qo.sort_records(
            [{"touches": None}, {"touches": 5}, {"touches": 2}],
            "touches",
            qo.PEOPLE_SORT_KEYS,
        )
        self.assertEqual([item["touches"] for item in sorted_items], [5, 2, None])
        with self.assertRaises(ValueError):
            qo.sort_records([{"touches": 1}], "nonexistent_key", qo.PEOPLE_SORT_KEYS)

        bad = subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPTS / "query_ownership.py"),
                "--data-dir",
                str(data_dir),
                "people",
                "--sort",
                "not_a_field",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(bad.returncode, 2)
        self.assertIn("Invalid sort key", bad.stderr)

        # files_truncated uses entry["size"] even when entry["files"] was already capped at build time
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            qo.handle_community(
                type("Args", (), {"id": 1, "include_files": True, "file_limit": 3})(),
                data_dir,
            )
        c1 = json.loads(buf.getvalue())
        self.assertTrue(c1["files_truncated"])

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            qo.handle_community(
                type("Args", (), {"id": 2, "include_files": True, "file_limit": 3})(),
                data_dir,
            )
        c2 = json.loads(buf.getvalue())
        self.assertFalse(c2["files_truncated"])

        # Missing communities.json message references --no-communities
        (data_dir / "communities.json").unlink()
        with self.assertRaisesRegex(FileNotFoundError, "--no-communities"):
            qo.load_communities(data_dir)

    def test_run_ownership_map_forwards_half_life_min_touches_and_max_community_files(self) -> None:
        repo = self.root / "fwd-repo"
        repo.mkdir()
        _git(repo, "init")
        _git(repo, "config", "user.name", "Dev")
        _git(repo, "config", "user.email", "dev@example.com")
        (repo / "one.py").write_text("1\n", encoding="utf-8")
        (repo / "two.py").write_text("2\n", encoding="utf-8")
        _git(repo, "add", "one.py", "two.py")
        _git(repo, "commit", "-m", "c1")
        (repo / "two.py").write_text("2b\n", encoding="utf-8")
        _git(repo, "add", "two.py")
        _git(repo, "commit", "-m", "c2")

        out_dir = self.root / "fwd-out"
        proc = subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPTS / "run_ownership_map.py"),
                "--repo",
                str(repo),
                "--out",
                str(out_dir),
                "--no-communities",
                "--half-life-days",
                "90",
                "--min-touches",
                "2",
                "--max-community-files",
                "7",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        summary = json.loads((out_dir / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual(summary["parameters"]["half_life_days"], 90.0)
        with (out_dir / "edges.csv").open("r", encoding="utf-8") as handle:
            edges = list(csv.DictReader(handle))
        self.assertEqual([e["file_id"] for e in edges], ["two.py"])


if __name__ == "__main__":
    unittest.main()
