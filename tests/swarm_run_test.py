import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request


SCRIPT = (Path(__file__).resolve().parents[1] / "skills-source/codex-only/swarm/scripts/run.py")
MAILBOX = SCRIPT.with_name("member_mailbox.py")
sys.dont_write_bytecode = True
sys.path.insert(0, str(SCRIPT.parent))
import coordination  # noqa: E402


class WorkflowCLI(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.board = self.root / "board"
        self.manifest = self.board / "manifest.json"
        self.cli(self.root, "init", str(self.board), "--name", "review", "--member", "A", "--member", "B")
        self.artifact = self.root / "result.txt"
        self.artifact.write_text("draft", encoding="utf-8")

    def cli(self, cwd, *args, ok=True):
        p = subprocess.run([sys.executable, "-B", str(SCRIPT), *args], cwd=cwd,
                           capture_output=True, text=True, timeout=5)
        if ok:
            self.assertEqual(0, p.returncode, p.stderr)
            return json.loads(p.stdout)
        self.assertNotEqual(0, p.returncode, p.stdout)

    def publish(self, actor, kind, key, *args, ok=True):
        return self.cli(self.board / "members" / actor, "publish", "--manifest", str(self.manifest),
                        kind, "--task", "build", "--id", key, *args, ok=ok)

    def test_return_fix_recheck_and_release(self):
        self.publish("Lead", "assign", "start", "--to", "A", "--reviewer", "B")
        proof = ("--artifact", str(self.artifact), "--text", "checked result.txt")
        first = self.publish("A", "submit", "v1", *proof)["id"]
        self.publish("Lead", "release", "early", *proof, ok=False)
        self.publish("B", "changes", "missing-line", "--submission", first, *proof)
        self.artifact.write_text("corrected", encoding="utf-8")
        second = self.publish("A", "submit", "v2", *proof)["id"]
        self.publish("B", "approve", "stale", "--submission", first, *proof, ok=False)
        self.publish("B", "approve", "passed", "--submission", second, *proof)
        released = self.publish("Lead", "release", "accepted", *proof)
        self.assertEqual(released["version"], hashlib.sha256(self.artifact.read_bytes()).hexdigest())
        self.assertEqual(released, self.publish("Lead", "release", "accepted", *proof))

    def test_preserves_existing_run_and_rejects_aliases(self):
        before = self.manifest.read_bytes()
        self.cli(self.root, "init", str(self.board), "--name", "another", ok=False)
        self.assertEqual(before, self.manifest.read_bytes())
        new = self.root / "new"
        self.cli(self.root, "init", str(new), "--name", "team", "--member", "a", "--member", "A", ok=False)
        self.assertFalse(new.exists())

    def test_status_reports_tasks_alerts_pending_mail_and_server_health(self):
        self.publish("Lead", "assign", "start", "--to", "A", "--reviewer", "B")
        self.publish("A", "submit", "v1", "--artifact", str(self.artifact), "--text", "checked result.txt")
        long_text = "x" * 150
        mail = subprocess.run(
            [sys.executable, "-B", str(MAILBOX), "--manifest", str(self.manifest),
             "send", "--to", "B", "--task", "build", "--id", "q1", "--text", long_text],
            cwd=self.board / "members" / "A",
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
        mail_id = json.loads(mail.stdout)["id"]

        # Works from a non-actor directory (self.root).
        status = self.cli(self.root, "status", "--manifest", str(self.manifest))
        self.assertFalse(status["server"]["running"])
        self.assertEqual(status["tasks"][0]["status"], "submitted")
        self.assertEqual(status["alerts"], [{"task": "build", "status": "submitted", "alerts": ["missing review"]}])
        self.assertEqual([m["id"] for m in status["pendingMessages"]], [mail_id])
        self.assertTrue(status["recentEvents"][-1]["textPreview"].endswith("..."))
        self.assertNotIn("text", status["recentEvents"][-1])

        filtered = self.cli(self.root, "status", "--manifest", str(self.manifest),
                            "--task", "build", "--actor", "B", "--include-text")
        self.assertEqual(filtered["pendingMessages"][0]["text"], long_text)
        self.assertEqual(filtered["recentEvents"][-1]["text"], long_text)

        manifest_obj = coordination.load_manifest(self.manifest)
        server = coordination.serve(manifest_obj, 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host, port = server.server_address[:2]
            url = f"http://{host}:{port}/"
            coordination._write_server_info(manifest_obj, url, server.started_at,
                                            coordination.server_info_path(self.manifest))
            for path in ("", "api/state"):
                with urllib.request.urlopen(f"{url}{path}", timeout=3) as resp:
                    self.assertEqual(resp.status, 200)
            live = self.cli(self.root, "status", "--manifest", str(self.manifest))
            self.assertTrue(live["server"]["running"])
            self.assertEqual((live["server"]["uiGets"], live["server"]["statePolls"]), (1, 1))
        finally:
            coordination._cleanup_server_info(coordination.server_info_path(self.manifest), url,
                                              coordination.os.getpid())
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_status_task_filters_connections(self):
        for task, key in (("t1", "m1"), ("t2", "m2")):
            subprocess.run(
                [sys.executable, "-B", str(MAILBOX), "--manifest", str(self.manifest),
                 "send", "--to", "B", "--task", task, "--id", key, "--text", f"msg-{task}"],
                cwd=self.board / "members" / "A",
                capture_output=True, text=True, timeout=5, check=True,
            )
        subprocess.run(
            [sys.executable, "-B", str(MAILBOX), "--manifest", str(self.manifest),
             "send", "--to", "A", "--task", "t2", "--id", "m3", "--text", "other-pair"],
            cwd=self.board / "members" / "Lead",
            capture_output=True, text=True, timeout=5, check=True,
        )
        filtered = self.cli(self.root, "status", "--manifest", str(self.manifest), "--task", "t1")
        self.assertEqual(len(filtered["connections"]), 1)
        self.assertEqual(filtered["connections"][0]["id"], "A->B")
        self.assertEqual(filtered["connections"][0]["count"], 1)
        self.assertEqual(filtered["connections"][0]["eventIds"], ["A/message/m1"])

    def test_init_rejects_dotdot_overlapping_outbox_and_reserved_names(self):
        shared = self.root / "shared"
        sub = shared / "sub"
        sub.mkdir(parents=True)
        other = self.root / "other"
        other.mkdir()
        self.cli(
            self.root, "init", str(self.root / "dotdot-board"), "--name", "dotdot",
            "--member", f"A={sub / '..'}", "--member", f"B={sub}", ok=False,
        )
        self.cli(
            self.root, "init", str(self.root / "reserved-board"), "--name", "res",
            "--member", "CON", ok=False,
        )

    def test_late_stale_review_does_not_block_cli_release_and_no_pycache(self):
        self.publish("Lead", "assign", "start", "--to", "A", "--reviewer", "B")
        proof = ("--artifact", str(self.artifact), "--text", "v1")
        self.publish("A", "submit", "v1", *proof)
        self.artifact.write_text("v2", encoding="utf-8")
        proof2 = ("--artifact", str(self.artifact), "--text", "v2")
        s2 = self.publish("A", "submit", "v2", *proof2)["id"]
        self.publish("B", "approve", "ok2", "--submission", s2, *proof2)
        # Write a late stale review referencing v1 after v2 is approved.
        late = {
            "id": "B/approve/late-v1", "run": "review", "from": "B", "type": "approve",
            "task": "build", "at": "2099-01-01T00:00:00Z",
            "version": hashlib.sha256(b"draft").hexdigest(), "replyTo": "A/submit/v1", "text": "late",
        }
        (self.board / "members" / "B" / "late.json").write_text(json.dumps(late), encoding="utf-8")
        released = self.publish("Lead", "release", "done", "--submission", s2, *proof2)
        self.assertEqual(released["type"], "release")

        # Invoking run.py without -B must not write __pycache__ alongside scripts.
        scripts_copy = self.root / "swarm_scripts"
        shutil.copytree(SCRIPT.parent, scripts_copy, ignore=shutil.ignore_patterns("__pycache__"))
        env = {k: v for k, v in os.environ.items() if k != "PYTHONDONTWRITEBYTECODE"}
        proc = subprocess.run(
            [sys.executable, str(scripts_copy / "run.py"), "status", "--manifest", str(self.manifest)],
            cwd=self.root, env=env, capture_output=True, text=True, timeout=5, check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse((scripts_copy / "__pycache__").exists())


if __name__ == "__main__":
    unittest.main()
