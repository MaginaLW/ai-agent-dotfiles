"""Exercise the swarm mailbox from separate worker processes and outboxes."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "skills-source/codex-only/swarm/scripts/member_mailbox.py"


class SwarmMailboxTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.actors = {actor: self.root / f"outbox-{actor}" for actor in ("Lead", "A", "B")}
        for directory in self.actors.values():
            directory.mkdir()
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps({
            "run": "mail-test",
            "actors": {actor: str(directory) for actor, directory in self.actors.items()},
        }), encoding="utf-8")

    def invoke(self, actor: str, *args: str, fail: bool = False):
        cmd = [sys.executable, "-B", str(SCRIPT), "--manifest", str(self.manifest), *args]
        result = subprocess.run(cmd, cwd=self.actors.get(actor, self.root), capture_output=True, timeout=12)
        if fail:
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b"Traceback", result.stderr)
            return result.stderr.decode()
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def send(self, actor="A", recipient="B", text="line one\n第二行", key="draft", **kwargs):
        return self.invoke(actor, "send", "--to", recipient, "--task", "T", "--id", key, "--text", text, **kwargs)

    def write_legacy(self, author, filename, **fields):
        event = {"run": "mail-test", "at": "2025-01-01T00:00:00Z", "from": author, "task": "T", **fields}
        (self.actors[author] / filename).write_text(json.dumps(event), encoding="utf-8")

    def test_busy_queue_idle_delivery_round_trip_and_history(self):
        original = self.send()
        event_id = original["id"]
        busy = self.invoke("B", "inbox", "--availability", "busy", "--all")
        self.assertEqual((busy["messages"], busy["pending"]), ([], 1))
        for _ in range(2):
            poll = self.invoke("B", "inbox", "--availability", "idle")
            self.assertEqual(poll["messages"], [{"state": "pending", "event": original}])
        self.assertEqual(self.invoke("A", "status", event_id)["state"], "pending")
        self.assertEqual(list(self.actors["B"].iterdir()), [])

        receipt = self.invoke("B", "ack", event_id)
        self.assertEqual(self.invoke("B", "ack", event_id), receipt)
        self.assertEqual(self.invoke("A", "status", event_id)["state"], "acknowledged")
        self.assertEqual(self.invoke("B", "inbox")["pending"], 0)
        self.assertEqual(self.invoke("B", "inbox", "--all")["messages"][0]["state"], "acknowledged")

        reply = self.invoke("B", "reply", event_id, "--text", "Checked")
        self.assertEqual(self.invoke("B", "reply", event_id, "--text", "Checked"), reply)
        self.assertIn("different payload", self.invoke("B", "reply", event_id, "--text", "Other", fail=True))
        self.assertEqual(self.invoke("A", "inbox")["messages"], [{"state": "pending", "event": reply}])
        self.invoke("A", "ack", reply["id"])
        status = self.invoke("A", "status", event_id)
        self.assertEqual(status["state"], "replied")
        self.assertEqual([item["type"] for item in status["thread"]], ["message", "ack", "reply", "ack"])
        self.assertEqual(self.invoke("B", "status", reply["id"])["state"], "acknowledged")

    def test_concurrent_send_and_ack_retries_publish_only_once(self):
        with ThreadPoolExecutor(max_workers=6) as pool:
            sends = list(pool.map(lambda _: self.send(), range(6)))
            self.assertTrue(all(item == sends[0] for item in sends))
            event_id = sends[0]["id"]
            acks = list(pool.map(lambda _: self.invoke("B", "ack", event_id), range(6)))
        self.assertTrue(all(item == acks[0] for item in acks))
        self.assertEqual(len(list(self.actors["A"].iterdir())), 1)
        self.assertEqual(len(list(self.actors["B"].iterdir())), 1)
        self.assertIn("different payload", self.send(text="changed", fail=True))
        other = self.send(actor="Lead")
        self.assertNotEqual(other["id"], event_id)
        self.assertEqual(self.invoke("B", "inbox")["messages"][0]["event"], other)

    def test_only_recipient_can_ack_and_duplicate_ids_never_count(self):
        original = self.send()
        event_id = original["id"]
        for actor in ("Lead", "A"):
            self.assertIn("addressed recipient", self.invoke(actor, "ack", event_id, fail=True))
        self.assertIn("own manifest actor directory", self.invoke("outside", "ack", event_id, fail=True))
        self.assertIn("different recipient", self.send(recipient="A", fail=True))
        self.assertIn("unknown actor", self.send(recipient="C", fail=True))
        self.write_legacy("Lead", "foreign.json", id="bad-reader", type="ack", to="A", replyTo=event_id)
        self.write_legacy("B", "wrong.json", id="wrong-task", type="ack", to="A", task="X", replyTo=event_id)
        self.assertEqual(self.invoke("A", "status", event_id)["thread"], [original])
        self.write_legacy("A", "duplicate.json", **{k: v for k, v in original.items() if k != "from"})
        self.assertEqual(self.invoke("B", "inbox")["pending"], 0)
        self.assertIn("expected one message", self.invoke("B", "ack", event_id, fail=True))
        self.assertIn("ambiguous event id", self.send(fail=True))

    def test_wait_reads_peer_and_legacy_questions_and_times_out(self):
        with ThreadPoolExecutor(max_workers=1) as pool:
            worker = pool.submit(self.invoke, "B", "inbox", "--wait-seconds", "4")
            self.write_legacy("A", "old-style.json", id="hand-written", type="question", to="@B", text="Ready?")
            item = worker.result()["messages"][0]
        self.assertEqual((item["state"], item["event"]["sourceType"]), ("pending", "question"))
        self.invoke("B", "reply", item["event"]["id"], "--text", "Yes")
        self.assertEqual(self.invoke("B", "inbox", "--wait-seconds", "0.01")["messages"], [])
        self.assertIn("finite nonnegative", self.invoke("B", "inbox", "--wait-seconds", "nan", fail=True))

    def test_corrupt_or_occupied_destinations_are_preserved(self):
        digest = hashlib.sha256(b"A/message/draft").hexdigest()
        destination = self.actors["A"] / f"mail-{digest}.json"
        destination.write_text("broken", encoding="ascii")
        self.send(fail=True)
        self.assertEqual(destination.read_text(encoding="ascii"), "broken")
        self.assertEqual(list(self.actors["A"].iterdir()), [destination])
        self.assertIn("stable id key", self.send(key="../other", fail=True))

    def test_board_archives_messages_and_receipts_for_replay(self):
        sent = self.send()
        replied = self.invoke("B", "reply", sent["id"], "--text", "Done")
        archive = self.root / "archive"
        subprocess.run(
            [sys.executable, "-B", str(SCRIPT.with_name("coordination.py")), "--manifest",
             str(self.manifest), "--archive", str(archive)],
            check=True, capture_output=True, timeout=12,
        )
        self.manifest = archive / "manifest.json"
        self.actors = {name: Path(path) for name, path in json.loads(self.manifest.read_text())["actors"].items()}
        replay = self.invoke("A", "status", sent["id"])
        self.assertEqual(replay["state"], "replied")
        self.assertEqual(replay["thread"], [sent, replied])

    def test_inbox_wait_retries_transient_permission_error_and_no_pycache(self):
        scripts_copy = self.root / "swarm_scripts"
        shutil.copytree(SCRIPT.parent, scripts_copy, ignore=shutil.ignore_patterns("__pycache__"))
        env = {k: v for k, v in os.environ.items() if k != "PYTHONDONTWRITEBYTECODE"}
        proc = subprocess.run(
            [sys.executable, str(scripts_copy / "member_mailbox.py"), "--manifest", str(self.manifest), "inbox"],
            cwd=self.actors["B"], env=env, capture_output=True, text=True, timeout=5, check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse((scripts_copy / "__pycache__").exists())

        sys.path.insert(0, str(SCRIPT.parent))
        import coordination
        import member_mailbox

        loaded = coordination.load_manifest(self.manifest)
        real_load = coordination.load_manifest
        calls = {"n": 0}

        def flaky_load(path):
            calls["n"] += 1
            if calls["n"] == 1:
                raise coordination.BoardError("locked") from PermissionError("transient")
            self.send()
            return real_load(path)

        args = type("Args", (), {"availability": "idle", "all": False, "wait_seconds": 3.0})()
        old_cwd = os.getcwd()
        os.chdir(self.actors["B"])
        try:
            with mock.patch.object(member_mailbox.board, "load_manifest", side_effect=flaky_load):
                result = member_mailbox._inbox(loaded, "B", args)
        finally:
            os.chdir(old_cwd)
        self.assertEqual(result["pending"], 1)
        self.assertGreaterEqual(calls["n"], 2)


if __name__ == "__main__":
    unittest.main()
