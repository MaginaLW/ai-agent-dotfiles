import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = (Path(__file__).resolve().parents[1] / "skills-source/codex-only/swarm/scripts/run.py")


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


if __name__ == "__main__":
    unittest.main()
