"""Regression tests for swarm's local native-data adapters."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1] / "skills-source/codex-only/swarm/scripts"
sys.path.insert(0, str(SCRIPTS))
import coordination
import upstream


class UpstreamTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def board(self, records):
        actors = {name: str(self.root / name) for name in ("Lead", "Worker", "QA")}
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"run": "run/一", "actors": actors}), encoding="utf-8")
        for path in actors.values():
            Path(path).mkdir()
        for i, (sender, kind, fields) in enumerate(records):
            event = {"id": str(i), "from": sender, "type": kind, "task": "T", "run": "run/一",
                     "at": f"2026-01-01T00:00:{i:02}Z", **fields}
            (Path(actors[sender]) / f"{i}.json").write_text(json.dumps(event), encoding="utf-8")
        return manifest

    def test_amc_native_payloads_and_actor_registration(self):
        version = "4" * 64
        manifest = self.board([
            ("Lead", "assign", {"to": "@Worker", "reviewer": "QA", "text": "assignment body"}),
            ("Worker", "question", {"to": "@QA", "text": "私有正文"}),
            ("Lead", "release", {"version": version}),  # Early, ineffective.
            ("Worker", "submit", {"version": version}),
            ("QA", "approve", {"version": version}),
            ("Lead", "release", {"version": version}),
            ("Lead", "release", {"version": version}),  # Repeat after acceptance.
            ("Worker", "message", {"to": "unknown", "text": "invalid address"}),
        ])
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(upstream.main(["amc-export", "--manifest", str(manifest)]), 0)
        records = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([r["event_type"] for r in records],
                         ["agent_registered"] * 3 + ["task_assigned", "agent_message_sent", "task_completed"])
        actors = {r["payload"]["name"]: r["agent_id"] for r in records[:3]}
        assignment, message, completed = records[3:]
        self.assertEqual(assignment["agent_id"], actors["Lead"])
        self.assertEqual(assignment["payload"], {"assigned_to": actors["Worker"], "description": "T", "task_id": "T"})
        self.assertEqual(message["agent_id"], actors["Worker"])
        self.assertEqual(message["payload"], {"message_type": "question", "to_agent_id": actors["QA"], "content": ""})
        self.assertEqual(completed["timestamp"], "2026-01-01T00:00:05Z")
        self.assertIn(version, completed["payload"]["result"])
        with_text, skipped = upstream.amc_export(manifest, True)
        self.assertEqual(with_text[4]["payload"]["content"], "私有正文")
        self.assertEqual(with_text[3]["payload"]["description"], "assignment body")
        self.assertEqual([r["event_id"] for r in records], [r["event_id"] for r in with_text])
        self.assertEqual(skipped, {"submit": 1, "approve": 1, "release": 2})

    def test_ambiguous_events_never_complete_native_task(self):
        version = "3" * 64
        manifest = self.board([
            ("Lead", "assign", {"to": "Worker"}), ("Lead", "assign", {"to": "QA"}),
            ("Worker", "submit", {"version": version}), ("Lead", "release", {"version": version}),
            ("QA", "message", {"id": "duplicate", "to": "Lead"}),
            ("Worker", "message", {"id": "duplicate", "to": "Lead"}),
        ])
        records, skipped = upstream.amc_export(manifest, False)
        self.assertEqual({r["event_type"] for r in records}, {"agent_registered"})
        self.assertEqual(skipped["duplicate event ID"], 2)

    def test_duplicate_assignments_then_valid_assignment_via_installed_entry(self):
        manifest = self.board([
            ("Lead", "assign", {"id": "collision", "to": "QA", "task": "discarded"}),
            ("Lead", "assign", {"id": "collision", "to": "Worker", "task": "remaining"}),
            ("Lead", "assign", {"id": "valid", "to": "QA", "task": "remaining"}),
        ])
        installed = self.root / "installed"
        installed.mkdir()
        shutil.copyfile(upstream.__file__, installed / "upstream.py")
        shutil.copyfile(coordination.__file__, installed / "coordination.py")
        result = subprocess.run(
            [sys.executable, "-E", str(installed / "upstream.py"), "amc-export", "--manifest", str(manifest)],
            capture_output=True, encoding="utf-8", check=True,
        )
        records = [json.loads(line) for line in result.stdout.splitlines()]
        assignments = [r["payload"] for r in records if r["event_type"] == "task_assigned"]
        self.assertEqual([x["task_id"] for x in assignments], ["remaining"])
        self.assertTrue(assignments[0]["assigned_to"].endswith(":QA"))
        self.assertIn("'duplicate event ID': 2", result.stderr)
        self.assertFalse((installed / "__pycache__").exists())

    def broker(self):
        database = self.root / "broker snapshot #1.db"
        # Columns used from broker.ts's tables and post-CREATE migrations.
        with contextlib.closing(sqlite3.connect(database)) as db:
            db.executescript("""
                CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, status TEXT, project_dir TEXT);
                CREATE TABLE slots (id INTEGER PRIMARY KEY, session_id TEXT, display_name TEXT,
                    agent_type TEXT, status TEXT, task_state TEXT, input_tokens INTEGER,
                    output_tokens INTEGER, cache_read_tokens INTEGER);
                CREATE TABLE messages (id INTEGER PRIMARY KEY, from_id TEXT, to_id TEXT, text TEXT,
                    sent_at TEXT, delivered INTEGER DEFAULT 0, session_id TEXT, from_slot_id INTEGER,
                    to_slot_id INTEGER, msg_type TEXT DEFAULT 'chat', delivered_at TEXT,
                    held INTEGER DEFAULT 0, acked_at TEXT);
                INSERT INTO sessions VALUES ('one','private name','paused','private directory'),
                                            ('other','other','active','somewhere else');
                INSERT INTO slots VALUES (4,'one','Worker','codex','connected','released',99,10,8),
                                         (8,'other','Other Worker','claude','disconnected','idle',0,0,0);
                INSERT INTO messages VALUES
                    (1,'orchestrator','__slot_4__','private text','2026-02-01T10:00:00.000Z',
                     1,'one',NULL,4,'release','2026-02-01T10:00:03Z',0,'2026-02-01T10:00:04Z'),
                    (2,'__slot_4__','cl-ab12','held text','2026-02-01T10:01:00.000Z',
                     0,'one',NULL,NULL,'chat',NULL,1,NULL),
                    (3,'__orchestrator__','cl-ab12','other private text','2026-02-01T10:02:00.000Z',
                     0,'other',NULL,8,'approval',NULL,0,NULL);
            """)
        return database

    def test_import_opens_as_board_without_promoting_broker_lifecycle(self):
        database = self.broker()
        original = hashlib.sha256(database.read_bytes()).digest()
        target = self.root / "board"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(upstream.main([
                "multiagents-import", "--database", str(database), "--session", "one", "--out", str(target),
            ]), 0)
        report = json.loads((target / "report.json").read_text(encoding="utf-8"))
        state = coordination.derive_state(coordination.load_manifest(target / "manifest.json"))
        self.assertEqual(state["tasks"], [])
        self.assertEqual(len(state["edges"]), 2)
        first, second = state["events"]
        self.assertEqual((first["type"], first["from"], first["to"]), ("message", "MA-Orchestrator", "slot-4"))
        self.assertEqual(second["from"], "slot-4")
        self.assertEqual(report["peer_addresses"][second["to"]], "cl-ab12")
        self.assertEqual(first["multiagents"]["msg_type"], "release")
        self.assertEqual(report["slots"][0]["input_tokens"], 99)
        self.assertEqual(report["by_message_type"], {"release": 1, "chat": 1})
        self.assertEqual([report[k] for k in ("message_count", "delivered", "acknowledged", "held")], [2, 1, 1, 1])
        self.assertNotIn("private", json.dumps([state, report]))
        self.assertNotIn("slot-8", state["actors"])
        self.assertEqual(hashlib.sha256(database.read_bytes()).digest(), original)
        self.assertFalse(Path(str(database) + "-shm").exists())
        with self.assertRaisesRegex(ValueError, "already exists"):
            upstream.import_session(database, "one", target, False)
        path = upstream.import_session(database, "one", self.root / "with-text", True)
        records, _ = upstream.amc_export(path, True)
        self.assertEqual([r["payload"]["content"] for r in records if r["event_type"] == "agent_message_sent"],
                         ["private text", "held text"])

    def test_invalid_session_or_uncheckpointed_snapshot_does_not_publish(self):
        database = self.broker()
        target = self.root / "new"
        with self.assertRaisesRegex(ValueError, "not found"):
            upstream.import_session(database, "missing", target, False)
        Path(str(database) + "-wal").touch()
        with self.assertRaisesRegex(ValueError, "standalone SQLite"):
            upstream.import_session(database, "one", target, False)
        self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
