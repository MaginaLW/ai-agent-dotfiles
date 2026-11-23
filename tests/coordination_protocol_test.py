#!/usr/bin/env python3
"""Focused tests for the local subagent coordination protocol."""

from __future__ import annotations

import http.client
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / (
    "skills-source/codex-only/swarm/scripts/coordination.py"
)
sys.path.insert(0, str(SCRIPT.parent))
import coordination  # noqa: E402


RUN = "run-protocol"
BASE_TIME = datetime(2026, 1, 1, 12, tzinfo=timezone.utc)


def digest(value: str) -> str:
    import hashlib

    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class BoardFixture:
    def __init__(self, root: str) -> None:
        self.root = Path(root)
        self.actor_dirs = {
            "Lead": self.root / "events-lead",
            "A": self.root / "events-a",
            "B": self.root / "events-b",
        }
        for directory in self.actor_dirs.values():
            directory.mkdir()
        self.manifest_path = self.root / "manifest.json"
        self.manifest = {
            "run": RUN,
            "actors": {
                actor: os.fspath(directory)
                for actor, directory in self.actor_dirs.items()
            },
        }
        self.write_json(self.manifest_path, self.manifest)
        self.clock = BASE_TIME

    def write_json(self, path: Path, value: object) -> None:
        data = json.dumps(value, sort_keys=True, indent=2) + "\n"
        temporary = path.with_name(f".{path.name}.tmp")
        temporary.write_text(data, encoding="utf-8")
        os.replace(temporary, path)

    def publish(self, actor: str, event: dict[str, object]) -> str:
        self.clock += timedelta(seconds=1)
        complete = {
            "run": RUN,
            "from": actor,
            "at": self.clock.isoformat().replace("+00:00", "Z"),
            **event,
        }
        name = f"{len(list(self.actor_dirs[actor].iterdir())):04d}-{complete['id']}.json"
        self.write_json(self.actor_dirs[actor] / name, complete)
        return str(complete["id"])

    def loaded_manifest(self) -> coordination.Manifest:
        return coordination.load_manifest(self.manifest_path)

    def state(self) -> dict[str, object]:
        return coordination.derive_state(self.loaded_manifest())

    def task(self, task_id: str) -> dict[str, object]:
        matches = [item for item in self.state()["tasks"] if item["id"] == task_id]
        assert len(matches) == 1, matches
        return matches[0]


class CoordinationProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.board = BoardFixture(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_unpublished_event_and_optional_review(self) -> None:
        self.board.publish("Lead", {"id":"assign", "type":"assign", "task":"small", "to":"@A"})
        submit = {"id":"submission", "type":"submit", "task":"small", "version":digest("contents")}
        self.board.publish("A", submit)
        path, = self.board.actor_dirs["A"].glob("*.json")
        pending = path.with_suffix(".tmp")
        path.rename(pending)
        self.assertEqual(self.board.task("small")["status"], "assigned")
        pending.rename(path)
        self.board.publish("Lead", {"id":"release", "type":"release", "task":"small", "version":submit["version"]})
        self.assertEqual(self.board.task("small")["status"], "released")

    def test_question_and_multiline_receipt_roundtrip(self) -> None:
        self.board.publish("A", {"id":"q", "type":"question", "task":"talk", "to":"@B", "text":"Choose a colour."})
        self.board.publish("B", {"id":"r", "type":"reply", "task":"talk", "to":"@A", "replyTo":"q", "text":"Blue.\nReceipt: abc"})
        self.board.publish("A", {"id":"a", "type":"ack", "task":"talk", "to":"@B", "replyTo":"r", "text":"Blue.\nReceipt: abc"})
        state = self.board.state()
        self.assertEqual([e["type"] for e in state["edges"]], ["message", "reply", "ack"])
        self.assertEqual(state["events"][0]["sourceType"], "question")
        self.assertEqual(state["events"][1]["text"], state["events"][2]["text"])

    def test_changed_contents_after_release_need_fresh_review(self) -> None:
        self.board.publish("Lead", {"id":"assign", "type":"assign", "task":"reviewed", "to":"@A", "reviewer":"B"})
        for actor, kind in [("A", "submit"), ("B", "approve"), ("Lead", "release")]:
            self.board.publish(actor, {"id":kind, "type":kind, "task":"reviewed", "version":digest("first")})
        self.assertEqual(self.board.task("reviewed")["status"], "released")
        self.board.publish("A", {"id":"next", "type":"submit", "task":"reviewed", "version":digest("second")})
        second = self.board.task("reviewed")
        self.assertEqual(second["status"], "submitted")
        self.assertIn("missing review", second["alerts"])

    def test_same_output_new_input_requires_a_bound_review_and_release(self) -> None:
        task = "integration"
        version = digest("identical output")
        old_input, new_input = digest("prerequisite 1"), digest("prerequisite 2")
        self.board.publish("Lead", {"id": "assign", "type": "assign", "task": task, "to": "A", "reviewer": "B"})

        def record(sender, kind, event_id, **fields):
            self.board.publish(sender, {"type": kind, "id": event_id, "task": task, "version": version, **fields})

        record("A", "submit", "malformed", inputs={"dependency": "invalid"})
        self.assertIsNone(self.board.task(task)["submissionId"])
        record("A", "submit", "first", inputs={"dependency": old_input})
        record("B", "approve", "first-review")
        record("Lead", "release", "first-release")
        record("A", "submit", "unchanged", inputs={"dependency": old_input.upper()})
        self.assertEqual(self.board.task(task)["releaseId"], "first-release")
        self.assertEqual(self.board.task(task)["submissionId"], "first")
        record("A", "submit", "second", inputs={"dependency": new_input})
        record("B", "approve", "old-review", replyTo="first")
        record("B", "approve", "unbound-review")
        self.assertEqual(self.board.task(task)["status"], "submitted")
        self.assertIsNone(self.board.task(task)["releaseId"])
        record("B", "approve", "current-review", replyTo="second")
        record("Lead", "release", "old-release", replyTo="first")
        self.assertEqual(self.board.task(task)["status"], "approved")
        record("Lead", "release", "current-release", replyTo="second")
        released = self.board.task(task)
        self.assertEqual((released["submissionId"], released["releaseId"]), ("second", "current-release"))
        self.assertEqual(released["alerts"], [])

    def test_actual_return_new_version_recheck_and_release(self) -> None:
        first = digest("implementation version 1")
        second = digest("implementation version 2")
        self.board.publish(
            "Lead",
            {
                "id": "assign-1",
                "type": "assign",
                "task": "task-1",
                "to": "A",
                "reviewer": "B",
                "requiresReview": True,
            },
        )
        self.board.publish(
            "A",
            {"id": "submit-1", "type": "submit", "task": "task-1", "version": first},
        )
        submitted = self.board.task("task-1")
        self.assertEqual(submitted["status"], "submitted")
        self.assertEqual(submitted["version"], first)
        self.assertEqual(submitted["alerts"], ["missing review"])

        self.board.publish(
            "B",
            {
                "id": "return-1",
                "type": "changes",
                "task": "task-1",
                "to": "A",
                "replyTo": "submit-1",
                "version": first,
                "text": "Return: add the missing negative test.",
            },
        )
        returned = self.board.task("task-1")
        self.assertEqual(returned["status"], "returned")
        self.assertEqual(returned["version"], first)
        self.assertEqual(returned["alerts"], ["returned review"])

        self.board.publish(
            "A",
            {"id": "submit-2", "type": "submit", "task": "task-1", "version": second},
        )
        self.board.publish(
            "B",
            {
                "id": "stale-approve-1",
                "type": "approve",
                "task": "task-1",
                "version": first,
            },
        )
        stale = self.board.task("task-1")
        self.assertEqual(stale["status"], "submitted")
        self.assertEqual(stale["version"], second)
        self.assertEqual(stale["alerts"], ["missing review", "stale review"])

        self.board.publish(
            "B",
            {
                "id": "approve-2",
                "type": "approve",
                "task": "task-1",
                "version": second,
                "text": "Rechecked after the fix.",
            },
        )
        self.board.publish(
            "Lead",
            {
                "id": "release-2",
                "type": "release",
                "task": "task-1",
                "version": second,
            },
        )
        released = self.board.task("task-1")
        self.assertEqual(released["status"], "released")
        self.assertEqual(released["version"], second)
        self.assertEqual(released["owner"], "A")
        self.assertEqual(released["reviewer"], "B")
        self.assertEqual(released["alerts"], [])
        self.assertEqual(released["submissionId"], "submit-2")
        self.assertEqual(released["releaseId"], "release-2")

        state = self.board.state()
        self.assertEqual(len(state["events"]), 7)
        self.assertEqual(
            [(edge["from"], edge["to"], edge["type"]) for edge in state["edges"]],
            [
                ("Lead", "task:task-1", "assign"),
                ("A", "task:task-1", "submit"),
                ("B", "task:task-1", "changes"),
                ("A", "task:task-1", "submit"),
                ("B", "task:task-1", "approve"),
                ("B", "task:task-1", "approve"),
                ("Lead", "task:task-1", "release"),
            ],
        )

    def test_only_independent_assigned_reviewer_can_return_or_approve(self) -> None:
        version = digest("owner implementation")
        self.board.publish(
            "Lead",
            {
                "id": "assign-self",
                "type": "assign",
                "task": "bad-task",
                "to": "A",
                "reviewer": "A",
            },
        )
        self.assertEqual(self.board.state()["tasks"], [])

        self.board.publish(
            "Lead",
            {
                "id": "assign-good",
                "type": "assign",
                "task": "task-guard",
                "to": "A",
                "reviewer": "B",
            },
        )
        self.board.publish(
            "A",
            {
                "id": "spoofed-review",
                "type": "approve",
                "task": "task-guard",
                "version": version,
            },
        )
        self.board.publish(
            "B",
            {
                "id": "outside-review",
                "type": "approve",
                "task": "missing-task",
                "version": version,
            },
        )
        task = self.board.task("task-guard")
        self.assertEqual(task["status"], "assigned")
        self.assertEqual(task["version"], None)
        self.assertIsNone(task["submissionId"])
        self.assertIsNone(task["releaseId"])
        self.assertEqual(task["alerts"], [])

        # A valid owner submission and an event falsely claiming another sender
        # are both ignored rather than changing the review state.
        self.board.publish(
            "A",
            {
                "id": "submit-good",
                "type": "submit",
                "task": "task-guard",
                "version": version,
            },
        )
        spoof_path = self.board.actor_dirs["A"] / "spoofed-from-b.json"
        self.board.write_json(
            spoof_path,
            {
                "id": "not-from-this-dir",
                "run": RUN,
                "from": "B",
                "type": "approve",
                "task": "task-guard",
                "at": "2026-01-01T12:30:00Z",
                "version": version,
            },
        )
        task = self.board.task("task-guard")
        self.assertEqual(task["status"], "submitted")
        self.assertEqual(task["alerts"], ["missing review"])

    def test_lead_cannot_release_unapproved_or_stale_version(self) -> None:
        first = digest("first")
        second = digest("second")
        self.board.publish(
            "Lead",
            {
                "id": "assign-release",
                "type": "assign",
                "task": "task-release",
                "to": "A",
                "reviewer": "B",
            },
        )
        self.board.publish(
            "A",
            {
                "id": "submit-release",
                "type": "submit",
                "task": "task-release",
                "version": first,
            },
        )
        self.board.publish(
            "Lead",
            {
                "id": "release-too-soon",
                "type": "release",
                "task": "task-release",
                "version": first,
            },
        )
        self.assertEqual(self.board.task("task-release")["status"], "submitted")

        self.board.publish(
            "B",
            {
                "id": "approve-release",
                "type": "approve",
                "task": "task-release",
                "version": first,
            },
        )
        self.board.publish(
            "A",
            {
                "id": "submit-release-2",
                "type": "submit",
                "task": "task-release",
                "version": second,
            },
        )
        self.board.publish(
            "Lead",
            {
                "id": "release-stale",
                "type": "release",
                "task": "task-release",
                "version": first,
            },
        )
        task = self.board.task("task-release")
        self.assertEqual(task["status"], "submitted")
        self.assertEqual(task["version"], second)
        self.assertEqual(task["alerts"], ["missing review"])

    def test_duplicate_and_conflicting_ids_block_release(self) -> None:
        version = digest("guarded implementation")
        self.board.publish(
            "Lead",
            {
                "id": "assign-duplicate",
                "type": "assign",
                "task": "task-duplicate",
                "to": "A",
                "reviewer": "B",
            },
        )
        self.board.publish(
            "A",
            {
                "id": "note-duplicate",
                "type": "message",
                "task": "task-duplicate",
                "to": "B",
                "text": "ready for review",
            },
        )
        self.board.publish(
            "A",
            {
                "id": "submit-duplicate",
                "type": "submit",
                "task": "task-duplicate",
                "version": version,
            },
        )
        self.board.publish(
            "B",
            {
                "id": "approve-duplicate",
                "type": "approve",
                "task": "task-duplicate",
                "version": version,
            },
        )
        # This release shares an ID with the earlier message.  Treating either
        # one as authoritative would make replay ambiguous, so neither applies.
        self.board.publish(
            "Lead",
            {
                "id": "note-duplicate",
                "type": "release",
                "task": "task-duplicate",
                "version": version,
            },
        )
        duplicate = self.board.task("task-duplicate")
        self.assertEqual(duplicate["status"], "approved")
        self.assertIsNone(duplicate["releaseId"])
        self.assertIn("duplicate event id: note-duplicate", duplicate["alerts"])

        self.board.publish(
            "Lead",
            {
                "id": "assign-conflict",
                "type": "assign",
                "task": "task-conflict",
                "to": "A",
                "reviewer": "B",
            },
        )
        self.board.publish(
            "A",
            {
                "id": "submit-conflict",
                "type": "submit",
                "task": "task-conflict",
                "version": version,
            },
        )
        self.board.publish(
            "B",
            {
                "id": "approve-conflict",
                "type": "approve",
                "task": "task-conflict",
                "version": version,
            },
        )
        self.board.publish(
            "Lead",
            {
                "id": "assign-conflict-2",
                "type": "assign",
                "task": "task-conflict",
                "to": "B",
                "reviewer": "A",
            },
        )
        self.board.publish(
            "Lead",
            {
                "id": "release-conflict",
                "type": "release",
                "task": "task-conflict",
                "version": version,
            },
        )
        conflict = self.board.task("task-conflict")
        self.assertEqual(conflict["status"], "approved")
        self.assertIsNone(conflict["releaseId"])
        self.assertIn("conflicting task id", conflict["alerts"])

    def test_weighted_directions_survive_archive_and_exclude_ambiguous_ids(self) -> None:
        for sender, recipient, kind, event_id in [
            ("A", "@B", "question", "question"),
            ("B", "A", "reply", "answer"),
            ("A", "B", "ack", "received"),
            ("A", "A", "message", "self"),
            ("A", "B", "message", "ambiguous"),
            ("B", "A", "message", "ambiguous"),
        ]:
            self.board.publish(sender, {"id": event_id, "type": kind, "task": "talk", "to": recipient})
        self.board.clock += timedelta(seconds=35)
        self.board.publish("Lead", {"id": "later", "type": "message", "task": "other", "to": "B"})
        state = self.board.state()
        connections = state["connections"]
        self.assertEqual(
            [(c["fromAgentId"], c["toAgentId"], c["count"], c["eventIds"]) for c in connections],
            [("A", "B", 2, ["question", "received"]), ("B", "A", 1, ["answer"]),
             ("A", "A", 1, ["self"]), ("Lead", "B", 1, ["later"])],
        )
        self.assertEqual(len({c["id"] for c in connections}), 4)
        self.assertEqual(connections[0]["timestamp"], state["events"][2]["at"])
        self.assertEqual([c["decay"] for c in connections], [0, 0, 0, 1])
        self.assertEqual(len(state["edges"]), 7)
        archived = coordination.archive_manifest(self.board.manifest_path, self.board.root / "archive")
        replay = coordination.derive_state(coordination.load_manifest(archived / "manifest.json"))
        self.assertEqual(replay, state)

    def test_communication_and_dependency_edges_use_actor_and_task_nodes(self) -> None:
        self.board.publish(
            "Lead",
            {
                "id": "assign-edge",
                "type": "assign",
                "task": "dependent",
                "to": "A",
                "reviewer": "B",
            },
        )
        self.board.publish(
            "Lead",
            {
                "id": "message-edge",
                "type": "message",
                "task": "dependent",
                "to": "@B",
                "text": "please check",
            },
        )
        self.board.publish(
            "B",
            {
                "id": "reply-edge",
                "type": "reply",
                "task": "dependent",
                "to": "Lead",
                "replyTo": "message-edge",
            },
        )
        self.board.publish(
            "Lead",
            {
                "id": "depends-edge",
                "type": "depends",
                "task": "dependent",
                "dependsOn": ["earlier", "later"],
            },
        )
        edges = self.board.state()["edges"]
        self.assertEqual(
            [(edge["from"], edge["to"], edge["type"], edge["eventId"]) for edge in edges],
            [
                ("Lead", "task:dependent", "assign", "assign-edge"),
                ("Lead", "B", "message", "message-edge"),
                ("B", "Lead", "reply", "reply-edge"),
                ("task:dependent", "task:earlier", "depends", "depends-edge"),
                ("task:dependent", "task:later", "depends", "depends-edge"),
            ],
        )

    def test_http_state_and_localhost_guards(self) -> None:
        version = digest("http implementation")
        self.board.publish(
            "Lead",
            {
                "id": "assign-http",
                "type": "assign",
                "task": "task-http",
                "to": "A",
                "reviewer": "B",
            },
        )
        self.board.publish(
            "A",
            {
                "id": "submit-http",
                "type": "submit",
                "task": "task-http",
                "version": version,
            },
        )
        server = coordination.serve(self.board.loaded_manifest(), 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host, port = server.server_address[:2]
            url = f"http://{host}:{port}/api/state"
            with urllib.request.urlopen(url, timeout=3) as response:
                self.assertEqual(response.status, 200)
                state = json.load(response)
            self.assertEqual(state["run"], RUN)
            self.assertEqual(state["actors"], ["A", "B", "Lead"])
            self.assertEqual(state["tasks"][0]["status"], "submitted")

            request = urllib.request.Request(
                url,
                headers={"Origin": f"http://localhost:{port}"},
            )
            with urllib.request.urlopen(request, timeout=3) as response:
                self.assertEqual(response.status, 200)

            connection = http.client.HTTPConnection(host, port, timeout=3)
            connection.request("GET", "/api/state", headers={"Host": "evil.example"})
            bad_host = connection.getresponse()
            try:
                self.assertEqual(bad_host.status, 403)
            finally:
                bad_host.read()
                connection.close()

            connection = http.client.HTTPConnection(host, port, timeout=3)
            connection.request(
                "GET",
                "/api/state",
                headers={"Origin": "https://evil.example"},
            )
            bad_origin = connection.getresponse()
            try:
                self.assertEqual(bad_origin.status, 403)
            finally:
                bad_origin.read()
                connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_offline_archive_is_atomic_and_replayable(self) -> None:
        version = digest("archived implementation")
        self.board.publish(
            "Lead",
            {
                "id": "assign-archive",
                "type": "assign",
                "task": "task-archive",
                "to": "A",
                "reviewer": "B",
            },
        )
        self.board.publish(
            "A",
            {
                "id": "submit-archive",
                "type": "submit",
                "task": "task-archive",
                "version": version,
            },
        )
        self.board.publish(
            "B",
            {
                "id": "approve-archive",
                "type": "approve",
                "task": "task-archive",
                "version": version,
            },
        )
        source_names = {
            actor: sorted(path.name for path in directory.iterdir())
            for actor, directory in self.board.actor_dirs.items()
        }
        target = self.board.root / "archive" / "board-archive"
        created = coordination.archive_manifest(self.board.manifest_path, target)
        self.assertEqual(created, target)
        self.assertTrue((target / "manifest.json").is_file())
        self.assertFalse(list(target.parent.glob(".board-archive.tmp-*")))

        replay_manifest = coordination.load_manifest(target / "manifest.json")
        replay = coordination.derive_state(replay_manifest)
        self.assertEqual(len(replay["events"]), 3)
        self.assertEqual(replay["tasks"][0]["status"], "approved")
        self.assertEqual(replay["tasks"][0]["version"], version)
        for actor, directory in self.board.actor_dirs.items():
            self.assertEqual(
                sorted(path.name for path in directory.iterdir()), source_names[actor]
            )

        with self.assertRaises(coordination.BoardError):
            coordination.archive_manifest(self.board.manifest_path, target)

    def test_health_endpoint_counts_and_localhost_guards(self) -> None:
        server = coordination.serve(self.board.loaded_manifest(), 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host, port = server.server_address[:2]
            base = f"http://{host}:{port}"
            with urllib.request.urlopen(f"{base}/api/health", timeout=3) as response:
                self.assertEqual(response.status, 200)
                health = json.load(response)
            self.assertTrue(health["ok"])
            self.assertEqual(health["run"], RUN)
            self.assertEqual((health["uiGets"], health["statePolls"], health["eventCount"]), (0, 0, 0))
            self.assertIsNone(health["lastUiAt"])
            self.assertIsNone(health["lastStateAt"])

            self.board.publish("Lead", {"id": "assign-health", "type": "assign", "task": "t", "to": "A"})
            for path in ("/", "/api/state"):
                head_req = urllib.request.Request(f"{base}{path}", method="HEAD")
                with urllib.request.urlopen(head_req, timeout=3) as response:
                    self.assertEqual(response.status, 200)
            with urllib.request.urlopen(f"{base}/api/health", timeout=3) as response:
                after_head = json.load(response)
            self.assertEqual((after_head["uiGets"], after_head["statePolls"], after_head["eventCount"]), (0, 0, 1))

            for path in ("/", "/api/state"):
                with urllib.request.urlopen(f"{base}{path}", timeout=3) as response:
                    self.assertEqual(response.status, 200)
            with urllib.request.urlopen(f"{base}/api/health", timeout=3) as response:
                after_get = json.load(response)
            self.assertEqual((after_get["uiGets"], after_get["statePolls"], after_get["eventCount"]), (1, 1, 1))
            self.assertIsNotNone(after_get["lastUiAt"])
            self.assertIsNotNone(after_get["lastStateAt"])

            for headers in ({"Host": "evil.example"}, {"Origin": "https://evil.example"}):
                connection = http.client.HTTPConnection(host, port, timeout=3)
                connection.request("GET", "/api/health", headers=headers)
                bad = connection.getresponse()
                try:
                    self.assertEqual(bad.status, 403)
                finally:
                    bad.read()
                    connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_server_info_reuse_stale_cleanup_and_ssrf_guard(self) -> None:
        manifest = self.board.loaded_manifest()
        info_path = coordination.server_info_path(self.board.manifest_path)
        proc = subprocess.Popen(
            [sys.executable, "-B", str(SCRIPT), "--manifest", str(self.board.manifest_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert proc.stdout is not None
            url = proc.stdout.readline().strip()
            self.assertRegex(url, r"^http://127\.0\.0\.1:\d+/$")
            self.assertTrue(info_path.is_file())
            for directory in self.board.actor_dirs.values():
                self.assertFalse((directory / coordination.SERVER_INFO_FILENAME).exists())

            probed = coordination.probe_server(manifest)
            self.assertIsNotNone(probed)
            assert probed is not None
            self.assertEqual(probed["url"], url)

            reused = subprocess.run(
                [sys.executable, "-B", str(SCRIPT), "--manifest", str(self.board.manifest_path), "--reuse"],
                capture_output=True,
                text=True,
                timeout=5,
                check=True,
            )
            self.assertEqual(reused.stdout.strip(), url)

            archive = self.board.root / "archive-with-server"
            coordination.archive_manifest(self.board.manifest_path, archive)
            self.assertFalse((archive / coordination.SERVER_INFO_FILENAME).exists())
        finally:
            proc.terminate()
            proc.wait(timeout=5)
            if proc.stdout:
                proc.stdout.close()
            if proc.stderr:
                proc.stderr.close()

        # Dead port in stale board-server.json and non-loopback URLs must be rejected safely.
        self.assertIsNone(coordination.probe_server(manifest))
        for bad_url in ("http://example.com:80/", "https://127.0.0.1:80/", "file:///etc/passwd"):
            self.board.write_json(info_path, {"url": bad_url})
            self.assertIsNone(coordination.probe_server(manifest))

        info_path.unlink(missing_ok=True)
        no_info = subprocess.Popen(
            [sys.executable, "-B", str(SCRIPT), "--manifest", str(self.board.manifest_path), "--no-server-info"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert no_info.stdout is not None
            self.assertRegex(no_info.stdout.readline().strip(), r"^http://127\.0\.0\.1:\d+/$")
            self.assertFalse(info_path.exists())
        finally:
            no_info.terminate()
            no_info.wait(timeout=5)
            if no_info.stdout:
                no_info.stdout.close()
            if no_info.stderr:
                no_info.stderr.close()


if __name__ == "__main__":
    unittest.main()
