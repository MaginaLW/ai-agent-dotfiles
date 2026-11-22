"""Run the installed teamwork CLI against the actual swarm event reducer."""

import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest


SKILLS = Path(__file__).resolve().parents[1] / "skills-source" / "codex-only"
PLANNER = SKILLS / "teamwork" / "scripts" / "waves.py"
BOARD = SKILLS / "swarm" / "scripts" / "coordination.py"
GSD_IMPORT = SKILLS / "teamwork" / "scripts" / "import_gsd.py"


def sha(data):
    return hashlib.sha256(data.encode()).hexdigest()


def task(name, deps=(), **kwargs):
    return dict(id=name, depends_on=list(deps), verify=f"Exercise the {name} entry point", **kwargs)


class TeamworkCLI(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.run = "sample"
        self.manifest = self.root / "manifest.json"
        self.plan = self.root / "plan.json"
        self.counter = 0
        self.actors = {key: self.root / key for key in ("Lead", "Worker", "Reviewer")}
        for folder in self.actors.values():
            folder.mkdir()
        self.manifest.write_text(json.dumps({
            "run": self.run, "actors": {key: str(path) for key, path in self.actors.items()}
        }), encoding="utf-8")

    def write(self, *tasks, **fields):
        plan = {"run": self.run, "tasks": list(tasks), **fields}
        self.plan.write_text(json.dumps(plan), encoding="utf-8")
        return hashlib.sha256(self.plan.read_bytes()).hexdigest()

    def query(self, *, live=True, error=None, manifest=None):
        args = [sys.executable, "-B", str(PLANNER), str(self.plan)]
        if live:
            args.extend(["--manifest", str(manifest or self.manifest)])
        result = subprocess.run(args, capture_output=True, text=True, check=False)
        if error:
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn(error, result.stderr)
            return
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def post(self, actor, kind, key, **fields):
        self.counter += 1
        event_id = f"{actor}/{kind}/{self.counter}"
        event = {"id": event_id, "run": self.run, "from": actor, "type": kind,
                 "task": key, "at": f"2026-01-01T00:00:{self.counter:02d}Z", **fields}
        path = self.actors[actor] / f"{self.counter}.json"
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(event), encoding="utf-8")
        temp.rename(path)
        return event_id

    def assign(self, key, reviewed=False):
        fields = {"reviewer": "Reviewer", "requiresReview": True} if reviewed else {}
        self.post("Lead", "assign", key, to="Worker", **fields)

    def accept(self, key, version, *, inputs=None, reviewed=False):
        fields = {} if inputs is None else {"inputs": inputs}
        receipt = self.post("Worker", "submit", key, version=version, **fields)
        if reviewed:
            self.post("Reviewer", "approve", key, version=version, replyTo=receipt)
        self.post("Lead", "release", key, version=version, replyTo=receipt)
        return receipt

    def test_gsd_waves_and_conflicts(self):
        self.write(task("join", ["b", "c"]), task("c", ["a"]), task("b"), task("a"))
        self.assertEqual(self.query(live=False)["waves"], [["a", "b"], ["c"], ["join"]])
        for tasks, message in [
            ([task("root"), task("root")], "duplicate task"),
            ([task("join", ["missing"])], "unknown tasks"),
            ([task("a"), task("b", ["c", "a"]), task("c", ["b"])], "dependency cycle"),
            ([task("a"), task("b", ["a"], files_modified=["SRC/Api"]),
              task("c", files_modified=[r"src\api\get.py"])], "unordered writers"),
            ([task("a", files_modified=["../x"])], "repository-relative"),
            ([task("a"), task("b", ["a", "a"])], "duplicate"),
        ]:
            with self.subTest(tasks=tasks):
                self.write(*tasks)
                self.query(live=False, error=message)
        self.write(task("gate", requires_review=True), task("side"), plan_review="gate")
        self.query(live=False, error="must depend on plan_review")
        self.write(task("gate"), plan_review="gate")
        self.query(live=False, error="requires_review")
        self.write(task("a", files_modified=["src"]), task("b", ["a"], files_modified=["src/data"]))
        self.assertEqual(self.query(live=False)["waves"], [["a"], ["b"]])

    def test_resume_rework_and_release_after_real_review(self):
        tasks = [task("plan", requires_review=True), task("left", ["plan"]),
                 task("right", ["plan"]), task("join", ["left", "right"], requires_review=True)]
        plan_sha = self.write(*tasks, plan_review="plan")
        rows = self.query()["tasks"]
        self.assertEqual(rows["plan"]["status"], "ready")
        self.assertEqual(rows["join"]["waiting_for"], ["left", "right"])
        self.assign("plan", reviewed=True)
        self.accept("plan", sha("unreviewed draft"), reviewed=True)
        self.assertEqual(self.query()["tasks"]["plan"]["status"], "rework")
        self.accept("plan", plan_sha, reviewed=True)
        for key in ("left", "right"):
            self.assign(key)
            self.accept(key, sha(key), inputs={"plan": plan_sha})
        self.assertEqual(self.query()["tasks"]["join"]["status"], "ready")
        pins = {key: sha(key) for key in ("left", "right")}
        self.assign("join", reviewed=True)
        first = self.post("Worker", "submit", "join", version=sha("bad"), inputs=pins)
        self.post("Lead", "release", "join", version=sha("bad"), replyTo=first)
        self.assertEqual(self.query()["tasks"]["join"]["status"], "review")
        self.post("Reviewer", "changes", "join", version=sha("bad"), replyTo=first)
        self.assertEqual(self.query()["tasks"]["join"]["status"], "rework")
        old = self.accept("join", sha("good"), inputs=pins, reviewed=True)
        self.assertTrue(self.query()["complete"])

        self.accept("left", sha("revised"), inputs={"plan": plan_sha})
        state = self.query()
        self.assertFalse(state["complete"])
        self.assertEqual(state["tasks"]["join"]["status"], "rework")
        self.assertEqual(state["tasks"]["right"]["status"], "released")
        pins["left"] = sha("revised").upper()
        new = self.post("Worker", "submit", "join", version=sha("good"), inputs=pins)
        self.post("Reviewer", "approve", "join", version=sha("good"), replyTo=old)
        self.assertEqual(self.query()["tasks"]["join"]["status"], "review")
        self.post("Reviewer", "approve", "join", version=sha("good"), replyTo=new)
        self.post("Lead", "release", "join", version=sha("good"), replyTo=old)
        self.assertEqual(self.query()["tasks"]["join"]["status"], "release")
        self.post("Lead", "release", "join", version=sha("good"), replyTo=new)
        current = self.query()
        self.assertTrue(current["complete"])
        archive = self.root / "archive"
        subprocess.run([sys.executable, "-B", str(BOARD), "--manifest", str(self.manifest),
                        "--archive", str(archive)], check=True, capture_output=True)
        self.assertEqual(self.query(manifest=archive / "manifest.json"), current)
        tasks[1]["verify"] = "Review an expanded left-side contract"
        self.write(*tasks, plan_review="plan")
        self.assertEqual(self.query()["tasks"]["plan"]["status"], "rework")
        self.assertEqual(self.query()["tasks"]["right"]["status"], "blocked")

    def test_premature_and_missing_pins_cannot_release_a_successor(self):
        self.write(task("item"), task("audit", ["item"]), task("next", ["audit"]), task("independent"))
        for key in ("item", "audit"):
            self.assign(key)
        self.accept("audit", sha("early"), inputs={"item": sha("item")})
        self.accept("item", sha("item"))
        rows = self.query()["tasks"]
        self.assertEqual(rows["audit"]["status"], "rework")
        self.assertEqual(rows["next"]["status"], "blocked")
        self.assertEqual(rows["independent"]["status"], "ready")
        self.accept("audit", sha("no pins"))
        self.assertEqual(self.query()["tasks"]["audit"]["status"], "rework")
        self.accept("audit", sha("evidence"), inputs={"item": sha("item")})
        self.assertEqual(self.query()["tasks"]["next"]["status"], "ready")

    def test_assignment_and_plan_board_drift_are_visible(self):
        self.write(task("a", requires_review=True), task("b"))
        self.assign("a")
        self.assertEqual(self.query()["tasks"]["a"]["status"], "conflict")
        self.post("Lead", "depends", "b", dependsOn=["a"])
        self.assertEqual(self.query()["tasks"]["b"]["status"], "conflict")
        self.write(task("a"), run="different-run")
        self.query(error="run names differ")

    def test_gsd_frontmatter_projection_preserves_multiline_checks(self):
        # A decoded frontmatter-get response; the upstream executable round trip is separate.
        metadata = {"phase": "02-export", "plan": "01", "autonomous": "true",
                    "depends_on": [], "files_modified": ["reader.py"],
                    "must_haves": {"truths": ["Quoted fields survive a round trip"]}}
        convert = runpy.run_path(str(GSD_IMPORT))["task_from_plan"]
        alias, item = convert("02-01-reader-PLAN.md", metadata,
                              "<verify>python check.py\npython verify.py</verify>")
        self.assertEqual((alias, item["id"]), ("02-01", "02-01-reader"))
        self.assertEqual(json.loads(item["verify"]), ["Quoted fields survive a round trip",
                                                      "python check.py\npython verify.py"])
        with self.assertRaisesRegex(ValueError, "checkpoint"):
            convert("PLAN.md", {**metadata, "autonomous": "false"}, "")
        with self.assertRaisesRegex(ValueError, "missing must_haves"):
            convert("PLAN.md", {**metadata, "must_haves": {}}, "")

    @unittest.skipUnless(os.environ.get("TEAMWORK_GSD_TOOLS"), "set TEAMWORK_GSD_TOOLS to test a real GSD checkout")
    def test_official_gsd_import_then_waves_with_external_dependency_rejection(self):
        phase = self.root / ".planning" / "phases" / "02-export"
        phase.mkdir(parents=True)
        for number, label, dependency in [("01", "writer", "[]"), ("02", "reader", '["02-01"]')]:
            text = (f"---\nphase: 02-export\nplan: {number}\ntype: execute\nwave: {int(number)}\n"
                    f"depends_on: {dependency}\nfiles_modified: [{label}.py]\nautonomous: true\n"
                    f"must_haves:\n  truths:\n    - {label} handles quoted values\n---\n"
                    f"<tasks><task type=\"auto\"><verify>python check.py {label}</verify></task></tasks>\n"
                    "<verification>Round-trip a quoted comma.</verification>\n")
            (phase / f"02-{number}-{label}-PLAN.md").write_text(text, encoding="utf-8")
        before = {path.name: path.read_bytes() for path in phase.iterdir()}
        args = [sys.executable, "-B", str(GSD_IMPORT), str(phase), "--gsd-tools",
                os.environ["TEAMWORK_GSD_TOOLS"], "--run", self.run]
        process = subprocess.run(args, capture_output=True, check=False)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.plan.write_bytes(process.stdout)
        self.assertEqual(self.query(live=False)["waves"], [["02-01-writer"], ["02-02-reader"]])
        second = json.loads(process.stdout)["tasks"][1]
        self.assertEqual(second["depends_on"], ["02-01-writer"])
        self.assertEqual(second["files_modified"], ["reader.py"])
        self.assertEqual(json.loads(second["verify"]), ["reader handles quoted values",
                                                       "python check.py reader", "Round-trip a quoted comma."])
        self.assertEqual({path.name: path.read_bytes() for path in phase.iterdir()}, before)
        reader = phase / "02-02-reader-PLAN.md"
        reader.write_bytes(reader.read_bytes().replace(b'["02-01"]', b'["01-external"]'))
        failed = subprocess.run(args, capture_output=True, check=False)
        self.assertEqual(failed.returncode, 2)
        self.assertIn(b"01-external", failed.stderr)
        self.assertEqual(failed.stdout, b"")


if __name__ == "__main__":
    unittest.main()
