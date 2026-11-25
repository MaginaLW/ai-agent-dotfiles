#!/usr/bin/env python3
"""Isolated unittest suite for dashboard/server.py (zero network, zero real-home writes)."""

from __future__ import annotations

import contextlib
from http.client import HTTPConnection
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
if os.fspath(REPO_ROOT) not in sys.path:
    sys.path.insert(0, os.fspath(REPO_ROOT))

from dashboard import server as srv  # noqa: E402


FAKE_USER_PATH = "C:" + "\\Users\\" + "sampleuser\\.codex\\AGENTS.md"
FAKE_USER_DIR = "C:" + "\\Users\\" + "sampleuser"


def _create_fixture_repo(base: Path) -> Path:
    repo = base / "repo"
    (repo / "dashboard").mkdir(parents=True)
    (repo / "dashboard" / "index.html").write_text(
        '<!doctype html><meta name="dashboard-token" content="__DASHBOARD_TOKEN__"><body>OK</body>',
        encoding="utf-8",
    )
    (repo / "scripts").mkdir()
    for name in ("agent-dotfiles.ps1", "doctor.ps1", "scan-secrets.ps1", "build-skills.ps1", "deploy-skills.ps1", "run-tests.ps1"):
        (repo / "scripts" / name).write_text("# stub\n", encoding="utf-8")

    (repo / "STATUS.md").write_text(
        "# Project Status\n\nLast updated: 2026-11-25.\n\n## Open items\n\n- **Sample item.** Summary line here.\n",
        encoding="utf-8",
    )
    (repo / "status" / "active").mkdir(parents=True)
    (repo / "status" / "active" / "README.md").write_text("# Active\n", encoding="utf-8")
    (repo / "status" / "active" / "task-one.md").write_text("# Task One\nWorking on widget.\n", encoding="utf-8")

    (repo / "skills-source" / "shared" / "git-review").mkdir(parents=True)
    (repo / "skills-source" / "shared" / "git-review" / "SKILL.md").write_text(
        "---\nname: git-review\ndescription: Review changes.\n---\n# Git Review\n",
        encoding="utf-8",
    )
    (repo / "skills-source" / "codex-only" / "swarm").mkdir(parents=True)
    (repo / "skills-source" / "codex-only" / "swarm" / "SKILL.md").write_text(
        "---\nname: swarm\ndescription: Coordinate workers.\n---\n# Swarm\n",
        encoding="utf-8",
    )

    (repo / "harness-source" / "envs").mkdir(parents=True)
    (repo / "harness-source" / "envs" / "work.psd1").write_text(
        "@{\n  SchemaVersion = 1\n  Name = 'work'\n  Description = '日常环境'\n  Skills = @{ Codex = @('git-review', 'swarm') }\n}\n",
        encoding="utf-8",
    )
    (repo / "harness-source" / "envs" / "minimal.psd1").write_text(
        "@{\n  SchemaVersion = 1\n  Name = 'minimal'\n  Description = '最小环境'\n  Skills = @{ Codex = @('git-review') }\n}\n",
        encoding="utf-8",
    )
    (repo / "harness-source" / "envs" / "full.psd1").write_text(
        "@{\n  SchemaVersion = 1\n  Name = 'full'\n  Description = '全量环境'\n  Skills = @{ Codex = @('git-review', 'swarm') }\n}\n",
        encoding="utf-8",
    )
    (repo / "harness-source" / "antigravity").mkdir(parents=True)
    (repo / "harness-source" / "antigravity" / "plugins.psd1").write_text(
        "@{\n  SchemaVersion = 1\n  ManagedPlugin = @{\n    Name = 'ai-agent-dotfiles'\n    Skills = @('git-review')\n  }\n}\n",
        encoding="utf-8",
    )

    (repo / "tests").mkdir()
    (repo / "tests" / "doctor.tests.ps1").write_text("# stub\n", encoding="utf-8")
    (repo / "tests" / "deploy.tests.ps1").write_text("# stub\n", encoding="utf-8")
    (repo / "tests" / "test-timeouts.psd1").write_text(
        "@{\n  Suites = @{\n    'doctor.tests.ps1' = 30\n    'deploy.tests.ps1' = 100\n  }\n}\n",
        encoding="utf-8",
    )
    return repo


class DashboardServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)
        self.repo = _create_fixture_repo(self.base)
        self.home_root = self.base / "fake_home"
        self.state_root = self.base / "fake_state"
        self.home_root.mkdir()
        self.state_root.mkdir()
        self.head_sha = "abc1234567890"
        self.calls: list[list[str]] = []
        self.custom_handlers: list = []

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _default_mock_runner(self, argv: list[str], cwd: Path, timeout: float = 300.0) -> srv.RunResult:
        self.calls.append(list(argv))
        for handler in self.custom_handlers:
            res = handler(argv, cwd, timeout)
            if res is not None:
                return res
        exe = Path(argv[0]).name.lower()
        if exe == "git":
            if "rev-parse" in argv:
                return srv.RunResult(0, f"{self.head_sha}\n", "")
            if "status" in argv:
                out = (
                    "## main...origin/main [ahead 1]\n"
                    " M scripts/doctor.ps1\n"
                    "?? skills-source/shared/git-review/SKILL.md\n"
                )
                return srv.RunResult(0, out, "")
            if "log" in argv:
                return srv.RunResult(0, "abc1234\x1fFix dashboard\x1f2026-11-26T00:00:00Z\x1f5 minutes ago\n", "")
            if "ls-files" in argv:
                return srv.RunResult(0, "scripts/doctor.ps1\n", "")
            if "diff" in argv:
                return srv.RunResult(0, f"--- a/scripts/doctor.ps1\n+++ b/scripts/doctor.ps1\n+# ref {FAKE_USER_PATH} and {self.repo}\\tmp\n", "")
        return srv.RunResult(0, "OK\n", "")

    @contextlib.contextmanager
    def _running_server(self, *, offline: bool = True, html_override: str | None = None):
        app = srv.DashboardApp(
            self.repo,
            home_root=self.home_root,
            state_root=self.state_root,
            offline=offline,
            command_runner=self._default_mock_runner,
            html_override=html_override,
        )
        server = srv.DashboardHTTPServer(("127.0.0.1", 0), app)
        t = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        t.start()
        try:
            yield server, app, int(server.server_address[1])
        finally:
            server.shutdown()
            server.server_close()
            t.join(timeout=2.0)

    def _request(
        self,
        port: int,
        method: str,
        path: str,
        *,
        headers: dict[str, str] | None = None,
        body: dict | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        conn = HTTPConnection("127.0.0.1", port, timeout=5.0)
        hdrs = dict(headers or {})
        payload = None
        if body is not None:
            payload = json.dumps(body).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/json")
        try:
            conn.request(method, path, body=payload, headers=hdrs)
            resp = conn.getresponse()
            raw = resp.read()
            resp_headers = {k.lower(): v for k, v in resp.getheaders()}
            return resp.status, resp_headers, raw
        finally:
            conn.close()

    def _wait_job(self, port: int, job_id: str, timeout: float = 3.0) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status, _, raw = self._request(port, "GET", f"/api/jobs/{job_id}")
            self.assertEqual(status, 200)
            job = json.loads(raw.decode("utf-8"))["job"]
            if job["status"] != "running":
                return job
            time.sleep(0.02)
        self.fail(f"job {job_id} did not finish within {timeout}s")

    def test_cli_host_check_and_reuse(self) -> None:
        stderr_buf = io.StringIO()
        with contextlib.redirect_stderr(stderr_buf):
            rc = srv.main(["--repo-root", os.fspath(self.repo), "--host", "0.0.0.0"])
        self.assertEqual(rc, 2)
        self.assertIn("non-loopback", stderr_buf.getvalue())

        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(srv.main(["--repo-root", os.fspath(self.repo), "--host", "192.168.1.2"]), 2)

        stdout_buf = io.StringIO()
        with contextlib.redirect_stdout(stdout_buf):
            rc = srv.main(["--repo-root", os.fspath(self.repo), "--check"])
        self.assertEqual(rc, 0)
        check_data = json.loads(stdout_buf.getvalue())
        self.assertTrue(check_data["ok"])

        with self._running_server() as (_server, app, port):
            info_path = srv.write_server_json(
                self.repo,
                {
                    "url": f"http://127.0.0.1:{port}/",
                    "port": port,
                    "pid": os.getpid(),
                    "repo_root": os.fspath(self.repo),
                    "started_at": app.started_at,
                },
            )
            self.assertTrue(info_path.is_file())
            reuse_buf = io.StringIO()
            with mock.patch("dashboard.server.webbrowser.open") as open_mock:
                with contextlib.redirect_stdout(reuse_buf):
                    rc = srv.main(["--repo-root", os.fspath(self.repo), "--reuse", "--open"])
            self.assertEqual(rc, 0)
            reused = json.loads(reuse_buf.getvalue())
            self.assertTrue(reused["reused"])
            self.assertEqual(reused["port"], port)
            open_mock.assert_called_once_with(f"http://127.0.0.1:{port}/")

            srv.cleanup_server_json(info_path, os.getpid())
            self.assertFalse(info_path.exists())

    def test_csrf_host_origin_and_no_cors(self) -> None:
        with self._running_server() as (_server, app, port):
            status, headers, raw = self._request(port, "GET", "/")
            self.assertEqual(status, 200)
            self.assertEqual(headers.get("cache-control"), "no-store")
            self.assertNotIn("access-control-allow-origin", headers)
            self.assertIn(app.token, raw.decode("utf-8"))

            # Missing header token -> 403
            s1, _, _ = self._request(port, "POST", "/api/actions/run", body={"action": "doctor"})
            self.assertEqual(s1, 403)

            # Wrong header token -> 403
            s2, _, _ = self._request(
                port,
                "POST",
                "/api/actions/run",
                headers={"X-Dashboard-Token": "bad"},
                body={"action": "doctor"},
            )
            self.assertEqual(s2, 403)

            # Wrong Host -> 403
            s3, _, _ = self._request(
                port,
                "POST",
                "/api/actions/run",
                headers={"X-Dashboard-Token": app.token, "Host": f"evil.com:{port}"},
                body={"action": "doctor"},
            )
            self.assertEqual(s3, 403)

            # Wrong Origin -> 403
            s4, _, _ = self._request(
                port,
                "POST",
                "/api/actions/run",
                headers={"X-Dashboard-Token": app.token, "Origin": f"http://evil.com:{port}"},
                body={"action": "doctor"},
            )
            self.assertEqual(s4, 403)

            # Valid localhost Host + Origin + header token -> 202
            s5, _, raw5 = self._request(
                port,
                "POST",
                "/api/actions/run",
                headers={
                    "X-Dashboard-Token": app.token,
                    "Host": f"localhost:{port}",
                    "Origin": f"http://localhost:{port}",
                },
                body={"action": "doctor"},
            )
            self.assertEqual(s5, 202)
            job_id = json.loads(raw5.decode("utf-8"))["job"]["id"]
            self._wait_job(port, job_id)

    def test_health_overview_diff_skill_and_suites(self) -> None:
        with self._running_server() as (_server, app, port):
            st_h, _, raw_h = self._request(port, "GET", "/api/health")
            self.assertEqual(st_h, 200)
            health = json.loads(raw_h.decode("utf-8"))
            self.assertTrue(health["ok"])
            self.assertEqual(health["port"], port)
            self.assertEqual(health["repo_root"], "<repo>")

            st_o, _, raw_o = self._request(port, "GET", "/api/overview")
            self.assertEqual(st_o, 200)
            ov = json.loads(raw_o.decode("utf-8"))
            self.assertEqual(ov["repo"]["branch"], "main")
            self.assertEqual(ov["repo"]["ahead"], 1)
            self.assertEqual(ov["repo"]["total_changes"], 2)
            cat_ids = {c["id"] for c in ov["repo"]["categories"]}
            self.assertEqual(cat_ids, {"scripts", "skills"})
            self.assertEqual(ov["status_doc"]["last_updated"], "2026-11-25")
            self.assertEqual(len(ov["status_doc"]["open_items"]), 1)
            self.assertEqual(len(ov["status_doc"]["active_tasks"]), 1)
            self.assertEqual(ov["skills_catalog"]["total"], 2)
            self.assertEqual(ov["skills_catalog"]["shared_count"], 1)
            self.assertEqual(ov["skills_catalog"]["codex_only_count"], 1)

            # Diff path traversal rejection
            for bad_path in ("../secret.txt", "../../etc/passwd", "C:\\Windows\\win.ini", "/etc/passwd", ""):
                st_bad, _, _ = self._request(port, "GET", f"/api/diff?path={bad_path}")
                self.assertEqual(st_bad, 400)

            # Valid diff sanitized
            st_d, _, raw_d = self._request(port, "GET", "/api/diff?path=scripts/doctor.ps1")
            self.assertEqual(st_d, 200)
            diff_data = json.loads(raw_d.decode("utf-8"))
            self.assertNotIn(FAKE_USER_DIR, diff_data["diff"])
            self.assertNotIn(os.fspath(self.repo), diff_data["diff"])
            self.assertIn("~\\.codex\\AGENTS.md", diff_data["diff"])
            self.assertIn("<repo>\\tmp", diff_data["diff"])

            # Skill endpoint
            st_sk, _, raw_sk = self._request(port, "GET", "/api/skill?name=git-review")
            self.assertEqual(st_sk, 200)
            self.assertEqual(json.loads(raw_sk.decode("utf-8"))["scope"], "shared")
            self.assertEqual(self._request(port, "GET", "/api/skill?name=../bad")[0], 400)
            self.assertEqual(self._request(port, "GET", "/api/skill?name=nonexistent")[0], 404)

            # Test suites endpoint
            st_ts, _, raw_ts = self._request(port, "GET", "/api/test-suites")
            self.assertEqual(st_ts, 200)
            ts = json.loads(raw_ts.decode("utf-8"))
            self.assertEqual(ts["total_timeout_sec"], 130)

    def test_github_offline_and_sync_status_sanitized(self) -> None:
        with self._running_server(offline=True) as (_server, _app, port):
            st_g, _, raw_g = self._request(port, "GET", "/api/github")
            self.assertEqual(st_g, 200)
            gh = json.loads(raw_g.decode("utf-8"))
            self.assertFalse(gh["available"])
            self.assertTrue(gh["offline"])
            self.assertEqual(gh["open_prs"], [])

        def _status_handler(argv: list[str], cwd: Path, timeout: float):
            if "status" in argv and "-Json" in argv:
                payload = {
                    "SchemaVersion": 1,
                    "Environment": {"Recorded": "work", "Available": ["work", "full"], "Failed": False},
                    "Config": [{"Platform": "Codex", "Item": "AGENTS.md", "Status": "in-sync", "Detail": "managed block"}],
                    "Antigravity": {
                        "Name": "ai-agent-dotfiles",
                        "Version": "0.4.1",
                        "Action": "unchanged",
                        "Reason": "identity-version-and-content-match",
                        "InstalledPath": FAKE_USER_DIR + "\\.gemini\\plugins\\ai-agent-dotfiles",
                    },
                    "Mcp": {
                        "Items": [{"Platform": "Codex", "Server": "blender", "Action": "unchanged", "TargetPath": FAKE_USER_PATH}],
                        "Summary": {"add": 0, "update": 0, "unchanged": 1, "blocked": 0},
                    },
                    "Summary": {"Environment": "work", "Antigravity": "unchanged"},
                }
                stdout = "WARNING: leading non-json line\n" + json.dumps(payload)
                return srv.RunResult(0, stdout, f"debug path {self.repo}\\scripts")
            return None

        self.custom_handlers.append(_status_handler)
        with self._running_server(offline=False) as (_server, _app, port):
            # Also test gh failure fallback when offline=False
            with mock.patch("dashboard.server.shutil.which", return_value=None):
                st_g2, _, raw_g2 = self._request(port, "GET", "/api/github")
                self.assertEqual(st_g2, 200)
                self.assertFalse(json.loads(raw_g2.decode("utf-8"))["available"])

            st_s, _, raw_s = self._request(port, "GET", "/api/sync-status")
            self.assertEqual(st_s, 200)
            text_s = raw_s.decode("utf-8")
            self.assertNotIn(FAKE_USER_DIR, text_s)
            self.assertNotIn(os.fspath(self.repo), text_s)
            sync = json.loads(text_s)
            self.assertTrue(sync["ok"])
            self.assertEqual(sync["summary_level"], "ok")
            self.assertIn("<repo>\\scripts", sync["raw_sanitized"])

    def test_actions_allowlist_doctor_parse_and_single_flight_lock(self) -> None:
        gate = threading.Event()
        entered = threading.Event()

        def _action_handler(argv: list[str], cwd: Path, timeout: float):
            if "scan-secrets.ps1" in " ".join(argv):
                entered.set()
                gate.wait(timeout=2.0)
                return srv.RunResult(1, f"leak at {FAKE_USER_PATH}\n", "")
            if "doctor.ps1" in " ".join(argv):
                out = (
                    "[PASS] PowerShell 7 is active.\n"
                    "[WARN] Ambiguous root.\n"
                    "Deploy blockers: 1 (deployment cannot proceed).\n"
                    "  Ambiguous Codex live roots.\n"
                )
                return srv.RunResult(0, out, "")
            return None

        self.custom_handlers.append(_action_handler)
        with self._running_server() as (_server, app, port):
            hdrs = {"X-Dashboard-Token": app.token}
            self.assertEqual(
                self._request(port, "POST", "/api/actions/run", headers=hdrs, body={"action": "unknown"})[0],
                400,
            )
            self.assertEqual(
                self._request(port, "POST", "/api/actions/run", headers=hdrs, body={"action": "test-suite", "suite": "../evil.tests.ps1"})[0],
                400,
            )

            # Doctor structured parse
            st_doc, _, raw_doc = self._request(port, "POST", "/api/actions/run", headers=hdrs, body={"action": "doctor"})
            self.assertEqual(st_doc, 202)
            doc_job = self._wait_job(port, json.loads(raw_doc.decode("utf-8"))["job"]["id"])
            self.assertEqual(len(doc_job["structured"]["checks"]), 2)
            self.assertEqual(doc_job["structured"]["blockers"], ["Ambiguous Codex live roots."])

            # Single-flight lock returns 409 while scan is running
            st_scan, _, raw_scan = self._request(port, "POST", "/api/actions/run", headers=hdrs, body={"action": "scan"})
            self.assertEqual(st_scan, 202)
            self.assertTrue(entered.wait(timeout=2.0))
            st_busy, _, _ = self._request(port, "POST", "/api/actions/run", headers=hdrs, body={"action": "doctor"})
            self.assertEqual(st_busy, 409)
            st_busy2, _, _ = self._request(port, "POST", "/api/sync/preview", headers=hdrs, body={"target": "codex-skills", "environment": "work"})
            self.assertEqual(st_busy2, 409)
            gate.set()

            scan_job = self._wait_job(port, json.loads(raw_scan.decode("utf-8"))["job"]["id"])
            self.assertEqual(scan_job["status"], "failed")
            self.assertNotIn(FAKE_USER_DIR, scan_job["ai_prompt"])
            self.assertIn("~\\.codex\\AGENTS.md", scan_job["ai_prompt"])

    def test_two_step_preview_and_apply_guards(self) -> None:
        preview_mode = {"kind": "ready"}
        apply_calls: list[list[str]] = []

        def _sync_handler(argv: list[str], cwd: Path, timeout: float):
            joined = " ".join(argv)
            if "antigravity" in argv and "deploy" in argv:
                if preview_mode["kind"] == "ag_blocked":
                    return srv.RunResult(
                        0,
                        json.dumps({"Name": "ai-agent-dotfiles", "Action": "update", "Reason": "version-upgrade", "ApplyRequirement": "build-with-current-agy-before-apply"}),
                        "",
                    )
            if "deploy-skills.ps1" in joined:
                if "-Apply" in argv:
                    apply_calls.append(list(argv))
                    return srv.RunResult(0, "Applied environment 'work'.\n", "")
                if preview_mode["kind"] == "no_changes":
                    return srv.RunResult(
                        0,
                        "Codex unchanged git-review\nPlan summary: install=0  update=0  unchanged=1  prune=0  unknown=0\n",
                        "",
                    )
                return srv.RunResult(
                    0,
                    "Codex install git-review\nCodex prune old-skill\nFile changes for Codex/git-review:\n  add     SKILL.md\nPlan summary: install=1  update=0  unchanged=0  prune=1  unknown=0\n",
                    "",
                )
            return None

        self.custom_handlers.append(_sync_handler)
        with self._running_server() as (_server, app, port):
            hdrs = {"X-Dashboard-Token": app.token}

            # Reject apply without preview or without confirm: true
            self.assertEqual(
                self._request(port, "POST", "/api/sync/apply", headers=hdrs, body={"preview_id": "missing", "confirm": True})[0],
                404,
            )
            self.assertEqual(
                self._request(port, "POST", "/api/sync/apply", headers=hdrs, body={"preview_id": "missing", "confirm": False})[0],
                400,
            )

            # Blocked antigravity preview cannot apply
            preview_mode["kind"] = "ag_blocked"
            st_b, _, raw_b = self._request(port, "POST", "/api/sync/preview", headers=hdrs, body={"target": "antigravity-plugin"})
            self.assertEqual(st_b, 202)
            job_b = self._wait_job(port, json.loads(raw_b.decode("utf-8"))["job"]["id"])
            self.assertFalse(job_b["preview"]["can_apply"])
            self.assertEqual(
                self._request(port, "POST", "/api/sync/apply", headers=hdrs, body={"preview_id": job_b["preview"]["preview_id"], "confirm": True})[0],
                400,
            )

            # No-changes preview cannot apply
            preview_mode["kind"] = "no_changes"
            st_nc, _, raw_nc = self._request(port, "POST", "/api/sync/preview", headers=hdrs, body={"target": "codex-skills", "environment": "work"})
            self.assertEqual(st_nc, 202)
            job_nc = self._wait_job(port, json.loads(raw_nc.decode("utf-8"))["job"]["id"])
            self.assertFalse(job_nc["preview"]["can_apply"])
            self.assertTrue(job_nc["preview"]["no_changes"])

            # Valid preview -> expired rejection
            preview_mode["kind"] = "ready"
            st_p1, _, raw_p1 = self._request(port, "POST", "/api/sync/preview", headers=hdrs, body={"target": "codex-skills", "environment": "work"})
            self.assertEqual(st_p1, 202)
            job_p1 = self._wait_job(port, json.loads(raw_p1.decode("utf-8"))["job"]["id"])
            pid1 = job_p1["preview"]["preview_id"]
            self.assertTrue(job_p1["preview"]["can_apply"])
            self.assertTrue(job_p1["preview"]["has_prune"])
            self.assertEqual([i["name"] for i in job_p1["preview"]["items"]], ["Codex/git-review", "Codex/old-skill"])

            app._previews[pid1].expires_at = time.time() - 5.0
            self.assertEqual(
                self._request(port, "POST", "/api/sync/apply", headers=hdrs, body={"preview_id": pid1, "confirm": True})[0],
                409,
            )

            # Valid preview -> HEAD change rejection
            st_p2, _, raw_p2 = self._request(port, "POST", "/api/sync/preview", headers=hdrs, body={"target": "codex-skills", "environment": "work"})
            job_p2 = self._wait_job(port, json.loads(raw_p2.decode("utf-8"))["job"]["id"])
            pid2 = job_p2["preview"]["preview_id"]
            self.head_sha = "def9999999999"
            self.assertEqual(
                self._request(port, "POST", "/api/sync/apply", headers=hdrs, body={"preview_id": pid2, "confirm": True})[0],
                409,
            )

            # Valid preview -> apply once succeeds, second apply rejected (consumed)
            st_p3, _, raw_p3 = self._request(port, "POST", "/api/sync/preview", headers=hdrs, body={"target": "codex-skills", "environment": "work"})
            job_p3 = self._wait_job(port, json.loads(raw_p3.decode("utf-8"))["job"]["id"])
            pid3 = job_p3["preview"]["preview_id"]
            app._sync_status_cache = {"cached": True}

            st_a, _, raw_a = self._request(port, "POST", "/api/sync/apply", headers=hdrs, body={"preview_id": pid3, "confirm": True})
            self.assertEqual(st_a, 202)
            apply_job = self._wait_job(port, json.loads(raw_a.decode("utf-8"))["job"]["id"])
            self.assertEqual(apply_job["status"], "succeeded")
            self.assertEqual(len(apply_calls), 1)
            self.assertIn("-Apply", apply_calls[0])
            self.assertIsNone(app._sync_status_cache)

            # Replay with same preview_id -> 409
            self.assertEqual(
                self._request(port, "POST", "/api/sync/apply", headers=hdrs, body={"preview_id": pid3, "confirm": True})[0],
                409,
            )

    def test_swarm_probe_relative_and_absolute_paths(self) -> None:
        run_dir = self.repo / "tmp" / "swarm" / "demo-run"
        run_dir.mkdir(parents=True)
        rel_manifest = run_dir / "manifest.json"
        rel_manifest.write_text(json.dumps({"run": "demo-run", "actors": {"Lead": os.fspath(run_dir)}}), encoding="utf-8")

        ext_dir = self.base / "external_board"
        ext_dir.mkdir()
        ext_manifest = ext_dir / "manifest.json"
        ext_manifest.write_text(json.dumps({"run": "ext-run", "actors": {"Lead": os.fspath(ext_dir)}}), encoding="utf-8")

        with self._running_server() as (_server, app, port):
            hdrs = {"X-Dashboard-Token": app.token}

            # Relative path resolves against repo_root (not process CWD)
            st_rel, _, raw_rel = self._request(
                port,
                "POST",
                "/api/swarm/probe",
                headers=hdrs,
                body={"manifest_path": "tmp/swarm/demo-run/manifest.json"},
            )
            self.assertEqual(st_rel, 200)
            rel_board = json.loads(raw_rel.decode("utf-8"))
            self.assertEqual(rel_board["run"], "demo-run")
            self.assertTrue(rel_board["manifest_path_display"].startswith("<repo>"))

            # Absolute path outside repo_root also remains supported
            st_abs, _, raw_abs = self._request(
                port,
                "POST",
                "/api/swarm/probe",
                headers=hdrs,
                body={"manifest_path": os.fspath(ext_manifest)},
            )
            self.assertEqual(st_abs, 200)
            abs_board = json.loads(raw_abs.decode("utf-8"))
            self.assertEqual(abs_board["run"], "ext-run")

            # Reject invalid filename and missing file
            self.assertEqual(
                self._request(port, "POST", "/api/swarm/probe", headers=hdrs, body={"manifest_path": "STATUS.md"})[0],
                400,
            )
            self.assertEqual(
                self._request(port, "POST", "/api/swarm/probe", headers=hdrs, body={"manifest_path": "tmp/missing/manifest.json"})[0],
                400,
            )


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    unittest.main()
