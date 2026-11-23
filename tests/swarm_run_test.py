import hashlib
import json
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
