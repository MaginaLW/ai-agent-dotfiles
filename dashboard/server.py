#!/usr/bin/env python3
"""Local loopback-only web monitoring and controlled-sync server for ai-agent-dotfiles."""

from __future__ import annotations

import argparse
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import sys
import tempfile
import threading
import time
from typing import Any, Callable
import urllib.error
from urllib.parse import parse_qs, urlsplit
import urllib.request
import uuid
import webbrowser

_REPO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _REPO_DIR not in sys.path:
    sys.path.insert(0, _REPO_DIR)

from dashboard.lib.collectors import (  # noqa: E402
    ACTION_ZH_MAP,
    ALLOWED_ENVIRONMENTS,
    CATEGORY_DEFS,
    STATUS_CODE_ZH,
    SkillsCatalogCache,
    collect_github_status,
    collect_repo_overview,
    collect_status_doc,
    collect_swarm_boards,
    compute_attention,
    probe_board_manifest,
    utc_now_iso,
)
from dashboard.lib.jobs import (  # noqa: E402
    ALLOWED_ACTIONS,
    JobRecord,
    RunResult,
    build_action_command,
    default_command_runner,
    finalize_job_locked,
    kill_process_tree,
    parse_doctor_structured,
    run_streaming_subprocess,
)
from dashboard.lib.security import (  # noqa: E402
    LOOPBACK_URL_RE,
    POSIX_HOME_RE,
    SKILL_NAME_RE,
    WINDOWS_USERS_RE,
    PathSanitizer,
    _norm_path_key,
    assert_plain_path_no_reparse,
    is_reparse_or_symlink,
    resolve_repo_relative_file,
)
from dashboard.lib.sync_preview import (  # noqa: E402
    ALLOWED_SYNC_TARGETS,
    PreviewRecord,
    build_sync_command,
    compute_managed_workspace_fingerprint,
    is_managed_source_path,
    parse_preview_output,
    parse_sync_status_payload,
)


STATIC_ASSET_ALLOWLIST: dict[str, tuple[str, str]] = {
    "/static/app.css": ("app.css", "text/css; charset=utf-8"),
    "/static/app.js": ("app.js", "application/javascript; charset=utf-8"),
}


class DashboardApp:
    """Core state, security checks, job runner, and API handlers for the dashboard."""

    def __init__(
        self,
        repo_root: Path,
        *,
        home_root: Path | None = None,
        state_root: Path | None = None,
        offline: bool = False,
        command_runner: Callable[..., RunResult] | None = None,
        html_override: str | None = None,
        port_getter: Callable[[], int] | None = None,
    ) -> None:
        self.repo_root = Path(os.path.abspath(os.path.normpath(os.fspath(repo_root))))
        self.home_root = Path(os.path.abspath(os.path.normpath(os.fspath(home_root)))) if home_root else None
        self.state_root = Path(os.path.abspath(os.path.normpath(os.fspath(state_root)))) if state_root else None
        self.offline = offline
        self._has_custom_runner = command_runner is not None
        self.runner = command_runner or default_command_runner
        self.html_override = html_override
        self.port_getter = port_getter or (lambda: 0)
        self.sanitizer = PathSanitizer(self.repo_root, self.home_root, self.state_root)
        self.token = secrets.token_urlsafe(32)
        self.started_at = utc_now_iso()

        self._lock = threading.Lock()
        self._jobs: dict[str, JobRecord] = {}
        self._job_order: list[str] = []
        self._active_job_id: str | None = None
        self._previews: dict[str, PreviewRecord] = {}
        self._watched_manifests: list[Path] = []
        self._sync_status_cache: dict[str, Any] | None = None
        self._github_cache: dict[str, Any] | None = None
        self._skills_catalog_cache = SkillsCatalogCache()

    @property
    def port(self) -> int:
        return self.port_getter()

    def _active_job_summary_locked(self) -> dict[str, Any] | None:
        if not self._active_job_id:
            return None
        job = self._jobs.get(self._active_job_id)
        if not job or job.status != "running":
            return None
        return job.to_summary()

    def get_health(self) -> dict[str, Any]:
        with self._lock:
            active = self._active_job_summary_locked()
        return {
            "ok": True,
            "pid": os.getpid(),
            "port": self.port,
            "repo_root": self.sanitizer.sanitize_str(os.fspath(self.repo_root)),
            "started_at": self.started_at,
            "active_job": active,
        }

    def render_index_html(self) -> bytes | None:
        if self.html_override is not None:
            html_text = self.html_override
        else:
            index_path = self.repo_root / "dashboard" / "index.html"
            try:
                assert_plain_path_no_reparse(index_path, allow_missing=False)
                html_text = index_path.read_text(encoding="utf-8")
            except (OSError, ValueError):
                return None
        return html_text.replace("__DASHBOARD_TOKEN__", self.token).encode("utf-8")

    def read_static_asset(self, filename: str) -> bytes | None:
        static_dir = self.repo_root / "dashboard" / "static"
        asset_path = static_dir / filename
        try:
            assert_plain_path_no_reparse(static_dir, allow_missing=False)
            assert_plain_path_no_reparse(asset_path, allow_missing=False)
            if not asset_path.is_file():
                return None
            return asset_path.read_bytes()
        except (OSError, ValueError):
            return None

    def _run_git(self, args: list[str], timeout: float = 3.0) -> RunResult:
        cmd = ["git", "-c", "core.quotepath=false", "-C", os.fspath(self.repo_root), *args]
        return self.runner(cmd, cwd=self.repo_root, timeout=timeout)

    def _get_git_head_sha(self) -> str:
        res = self._run_git(["rev-parse", "HEAD"], timeout=2.0)
        if res.exit_code == 0:
            return res.stdout.strip()
        return ""

    @staticmethod
    def _is_managed_source_path(rel_path: str) -> bool:
        return is_managed_source_path(rel_path)

    def _compute_managed_workspace_fingerprint(self) -> str:
        return compute_managed_workspace_fingerprint(
            self.repo_root,
            self._get_git_head_sha(),
            self._run_git,
        )

    def _collect_skills_catalog(self) -> dict[str, Any]:
        return self._skills_catalog_cache.get_or_collect(self.repo_root, self.sanitizer)

    def get_overview(self) -> dict[str, Any]:
        repo = collect_repo_overview(self.repo_root, self.sanitizer, self._run_git)
        status_doc = collect_status_doc(self.repo_root, self.sanitizer)
        skills_catalog = self._collect_skills_catalog()
        with self._lock:
            watched = list(self._watched_manifests)
        swarm = collect_swarm_boards(self.repo_root, watched, self.sanitizer)
        with self._lock:
            active_job = self._active_job_summary_locked()
            recent_jobs = [self._jobs[jid].to_summary() for jid in reversed(self._job_order[-10:])]
            sync_cached = self._sync_status_cache
            gh_cached = self._github_cache
        attention = compute_attention(repo, status_doc, sync_cached, gh_cached, self.sanitizer)
        return {
            "generated_at": utc_now_iso(),
            "repo": repo,
            "status_doc": status_doc,
            "skills_catalog": skills_catalog,
            "swarm": swarm,
            "attention": attention,
            "active_job": active_job,
            "recent_jobs": recent_jobs,
        }

    def get_diff(self, raw_path: str) -> dict[str, Any]:
        rel_path, abs_path = resolve_repo_relative_file(self.repo_root, raw_path)
        ls_res = self._run_git(["ls-files", "--error-unmatch", "--", rel_path], timeout=3.0)
        truncated = False
        diff_text = ""

        if ls_res.exit_code != 0 and abs_path.is_file():
            raw_bytes = abs_path.read_bytes()
            if len(raw_bytes) > 8192:
                raw_bytes = raw_bytes[:8192]
                truncated = True
            if b"\x00" in raw_bytes:
                diff_text = "[二进制文件，跳过文本预览]"
            else:
                diff_text = raw_bytes.decode("utf-8", errors="replace")
        else:
            head_res = self._run_git(["diff", "HEAD", "--", rel_path], timeout=4.0)
            if head_res.exit_code == 0 and head_res.stdout.strip():
                diff_text = head_res.stdout
            else:
                staged_res = self._run_git(["diff", "--cached", "--", rel_path], timeout=4.0)
                unstaged_res = self._run_git(["diff", "--", rel_path], timeout=4.0)
                parts = [p for p in (staged_res.stdout, unstaged_res.stdout) if p and p.strip()]
                diff_text = "\n".join(parts)
            if len(diff_text) > 65536:
                diff_text = diff_text[:65536]
                truncated = True

        return {
            "path": rel_path,
            "diff": self.sanitizer.sanitize_str(diff_text),
            "truncated": truncated,
        }

    def get_skill(self, name: str) -> dict[str, Any] | None:
        if not isinstance(name, str) or not SKILL_NAME_RE.fullmatch(name):
            raise ValueError("invalid skill name")
        for scope, scope_zh in (("shared", "双端共享"), ("codex-only", "Codex 专用")):
            skill_file = self.repo_root / "skills-source" / scope / name / "SKILL.md"
            if skill_file.exists():
                assert_plain_path_no_reparse(skill_file, allow_missing=False)
                if not skill_file.is_file():
                    continue
                content = skill_file.read_text(encoding="utf-8", errors="replace")
                return {
                    "name": name,
                    "scope": scope,
                    "scope_zh": scope_zh,
                    "path": f"skills-source/{scope}/{name}/SKILL.md",
                    "content": self.sanitizer.sanitize_str(content),
                }
        return None

    def get_test_suites(self) -> dict[str, Any]:
        psd1 = self.repo_root / "tests" / "test-timeouts.psd1"
        suites: list[dict[str, Any]] = []
        if psd1.is_file() and not is_reparse_or_symlink(psd1):
            text = psd1.read_text(encoding="utf-8", errors="replace")
            for name, sec in re.findall(r"['\"]([^'\"]+\.tests\.ps1)['\"]\s*=\s*(\d+)", text):
                suites.append({"name": name, "timeout_sec": int(sec)})
        return {
            "suites": suites,
            "total_timeout_sec": sum(s["timeout_sec"] for s in suites),
        }

    def invalidate_sync_status_cache(self) -> None:
        with self._lock:
            self._sync_status_cache = None

    def get_sync_status(self, refresh: bool = False) -> dict[str, Any]:
        with self._lock:
            if not refresh and self._sync_status_cache is not None:
                return self._sync_status_cache

        pwsh = shutil.which("pwsh") or "pwsh"
        script = self.repo_root / "scripts" / "agent-dotfiles.ps1"
        argv = [
            pwsh,
            "-NoProfile",
            "-File",
            os.fspath(script),
            "status",
            "-Json",
            "-RepoRoot",
            os.fspath(self.repo_root),
        ]
        if self.home_root is not None:
            argv.extend(["-HomeRoot", os.fspath(self.home_root)])
        if self.state_root is not None:
            argv.extend(["-StateRoot", os.fspath(self.state_root)])

        res = self.runner(argv, cwd=self.repo_root, timeout=30.0)
        result = parse_sync_status_payload(res, self.sanitizer)
        with self._lock:
            self._sync_status_cache = result
        return result

    def get_github(self, refresh: bool = False) -> dict[str, Any]:
        if self.offline:
            return {
                "available": False,
                "offline": True,
                "message_zh": "当前处于离线模式（不影响本地监控）",
                "open_prs": [],
                "ci_runs": [],
            }
        with self._lock:
            if not refresh and self._github_cache is not None:
                return self._github_cache

        result = collect_github_status(self.repo_root, self.sanitizer, self.runner)
        with self._lock:
            self._github_cache = result
        return result

    def probe_swarm(self, manifest_path_raw: str) -> dict[str, Any]:
        if not isinstance(manifest_path_raw, str) or not manifest_path_raw.strip():
            raise ValueError("manifest_path is required")
        candidate = Path(manifest_path_raw.strip())
        if not candidate.is_absolute():
            candidate = self.repo_root / candidate
        if candidate.name != "manifest.json":
            raise ValueError("manifest_path must point to a file named manifest.json")
        abs_manifest = assert_plain_path_no_reparse(candidate, allow_missing=False)
        if not abs_manifest.is_file():
            raise ValueError("manifest_path must be a plain file")
        with self._lock:
            key = _norm_path_key(abs_manifest)
            if not any(_norm_path_key(p) == key for p in self._watched_manifests):
                self._watched_manifests.append(abs_manifest)
        return probe_board_manifest(abs_manifest, self.sanitizer)

    def _build_sync_command(self, target: str, environment: str, *, apply_mode: bool) -> tuple[str, list[str]]:
        return build_sync_command(
            self.repo_root,
            self.home_root,
            self.state_root,
            target,
            environment,
            apply_mode=apply_mode,
        )

    def _register_job_locked(self, kind: str, label_zh: str) -> JobRecord:
        if self._active_job_id is not None:
            active = self._active_job_summary_locked()
            if active is not None:
                raise RuntimeError("busy")
        job_id = str(uuid.uuid4())[:12]
        job = JobRecord(
            id=job_id,
            kind=kind,
            label_zh=label_zh,
            status="running",
            started_at=utc_now_iso(),
            started_monotonic=time.monotonic(),
        )
        self._jobs[job_id] = job
        self._job_order.append(job_id)
        self._active_job_id = job_id
        return job

    def _start_job_thread(
        self,
        job: JobRecord,
        label_zh: str,
        argv: list[str],
        timeout: float,
        on_complete: Callable[[JobRecord, RunResult, str], None] | None = None,
    ) -> None:
        use_streaming = (not self._has_custom_runner) and (self.runner is default_command_runner)

        def _on_line(chunk: str) -> None:
            sanitized_chunk = self.sanitizer.sanitize_str(chunk)
            with self._lock:
                if job.cancel_requested:
                    return
                job.output_sanitized += sanitized_chunk

        def _on_proc_start(proc: Any) -> None:
            should_kill = False
            with self._lock:
                if job.cancel_requested:
                    should_kill = True
                else:
                    job._proc = proc
            if should_kill:
                kill_process_tree(proc)

        def _is_cancelled() -> bool:
            with self._lock:
                return job.cancel_requested

        def _worker() -> None:
            if use_streaming:
                res = run_streaming_subprocess(
                    argv,
                    cwd=self.repo_root,
                    timeout=timeout,
                    on_line=_on_line,
                    on_process_start=_on_proc_start,
                    is_cancelled=_is_cancelled,
                )
            else:
                res = self.runner(argv, cwd=self.repo_root, timeout=timeout)
            combined = "\n".join(part for part in (res.stdout, res.stderr, res.error or "") if part)
            output_sanitized = self.sanitizer.sanitize_str(combined)
            with self._lock:
                finalize_job_locked(job, label_zh, res, output_sanitized, self.sanitizer, on_complete)
                if self._active_job_id == job.id:
                    self._active_job_id = None

        thread = threading.Thread(target=_worker, daemon=True)
        thread.start()

    def _spawn_job(
        self,
        kind: str,
        label_zh: str,
        argv: list[str],
        timeout: float,
        *,
        on_complete: Callable[[JobRecord, RunResult, str], None] | None = None,
    ) -> dict[str, Any]:
        with self._lock:
            job = self._register_job_locked(kind, label_zh)
        self._start_job_thread(job, label_zh, argv, timeout, on_complete)
        return job.to_summary()

    def cancel_job(self, job_id: str) -> tuple[int, dict[str, Any]]:
        """Safely cancel a running read-only/preview/test job; refuse apply:* jobs with HTTP 403."""
        proc_to_kill = None
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return 404, {"ok": False, "error": "job not found"}
            if job.kind.startswith("apply:"):
                return 403, {"ok": False, "error": "写入类任务禁止中途取消，以防本机状态半写"}
            if job.status != "running":
                return 409, {"ok": False, "error": "任务已结束，无法取消"}
            job.cancel_requested = True
            job.status = "cancelled"
            job.finished_at = utc_now_iso()
            job.duration_sec = round(max(0.0, time.monotonic() - job.started_monotonic), 3)
            job.summary_zh = f"{job.label_zh} 已手动中止"
            proc_to_kill = job._proc
            job._proc = None
            if self._active_job_id == job.id:
                self._active_job_id = None
            detail = job.to_detail()

        if proc_to_kill is not None:
            kill_process_tree(proc_to_kill)
        return 200, {"ok": True, "job": detail}

    def start_action_job(self, action: str, suite: str | None = None) -> dict[str, Any]:
        label_zh, argv, timeout = build_action_command(self.repo_root, self.home_root, action, suite)

        def _after(job: JobRecord, _res: RunResult, output_sanitized: str) -> None:
            if action == "doctor":
                structured = parse_doctor_structured(output_sanitized)
                job.structured = structured
                if structured["blockers"]:
                    job.summary_zh = f"健康体检发现 {len(structured['blockers'])} 个部署阻塞项"

        return self._spawn_job(f"action:{action}", label_zh, argv, timeout, on_complete=_after)

    def start_sync_preview_job(self, target: str, environment: str = "work") -> dict[str, Any]:
        label_zh, argv = self._build_sync_command(target, environment, apply_mode=False)
        head_sha = self._get_git_head_sha()
        pre_fp = self._compute_managed_workspace_fingerprint()

        def _after(job: JobRecord, res: RunResult, output_sanitized: str) -> None:
            post_head = self._get_git_head_sha()
            post_fp = self._compute_managed_workspace_fingerprint()
            preview_payload, record = parse_preview_output(
                target,
                environment,
                res,
                output_sanitized,
                post_head or head_sha,
                self.sanitizer,
                post_fp,
            )
            if post_head != head_sha or post_fp != pre_fp:
                preview_payload["blocked"] = True
                preview_payload["can_apply"] = False
                preview_payload["no_changes"] = False
                preview_payload["summary_zh"] = "预览执行期间受管源码文件或仓库 HEAD 发生变化，禁止写入，请重新预览"
                record.can_apply = False
                record.no_changes = False
            record.workspace_fingerprint = post_fp
            preview_payload["workspace_fingerprint"] = post_fp[:12]

            self._previews[record.preview_id] = record
            job.preview = preview_payload
            job.summary_zh = preview_payload["summary_zh"]
            if not preview_payload["can_apply"] and not preview_payload["no_changes"]:
                job.ai_prompt = self.sanitizer.sanitize_str(
                    f"「{label_zh}」预览未通过或存在受阻项，请帮我分析以下脱敏日志：\n\n"
                    + "\n".join(output_sanitized.splitlines()[-30:])
                )

        return self._spawn_job(f"preview:{target}", label_zh, argv, 180.0, on_complete=_after)

    def start_sync_apply_job(self, preview_id: str, confirm: Any) -> tuple[int, dict[str, Any]]:
        if confirm is not True:
            return 400, {"ok": False, "error": "必须显式传入 confirm: true 才能执行写入"}
        if not isinstance(preview_id, str) or not preview_id.strip():
            return 400, {"ok": False, "error": "缺少有效的 preview_id"}

        now_ts = time.time()
        current_head = self._get_git_head_sha()
        current_fp = self._compute_managed_workspace_fingerprint()

        def _after(job: JobRecord, res: RunResult, _output_sanitized: str) -> None:
            self._sync_status_cache = None
            if res.exit_code == 0:
                job.summary_zh = f"{label_zh} 成功，已刷新双端状态缓存"

        with self._lock:
            if self._active_job_id is not None and self._active_job_summary_locked() is not None:
                return 409, {"ok": False, "error": "已有任务正在执行，请等待完成后重试"}
            rec = self._previews.get(preview_id)
            if rec is None:
                return 404, {"ok": False, "error": "未找到对应的预览记录，请重新运行预览"}
            if rec.consumed:
                return 409, {"ok": False, "error": "该预览记录已被使用，请重新预览"}
            if now_ts > rec.expires_at:
                return 409, {"ok": False, "error": "预览已过期（超过 300 秒），请重新预览"}
            if not rec.can_apply:
                return 400, {"ok": False, "error": "该预览未通过或无变更可执行"}
            if current_head != rec.repo_head_sha or current_fp != rec.workspace_fingerprint:
                return 409, {"ok": False, "error": "仓库 HEAD 或受管工作区源码已发生变化，请重新生成预览后再写入"}

            label_zh, argv = self._build_sync_command(rec.target, rec.environment, apply_mode=True)
            rec.consumed = True
            try:
                job = self._register_job_locked(f"apply:{rec.target}", label_zh)
            except RuntimeError:
                rec.consumed = False
                return 409, {"ok": False, "error": "已有任务正在执行，请等待完成后重试"}

        self._start_job_thread(job, label_zh, argv, 300.0, _after)
        return 202, {"job": job.to_summary()}

    def list_jobs(self) -> dict[str, Any]:
        with self._lock:
            jobs = [self._jobs[jid].to_summary() for jid in reversed(self._job_order[-20:])]
        return {"jobs": jobs}

    def get_job(self, job_id: str) -> dict[str, Any] | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return job.to_detail() if job else None


class DashboardHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, address: tuple[str, int], app: DashboardApp) -> None:
        self.app = app
        super().__init__(address, DashboardRequestHandler)
        self.app.port_getter = lambda: int(self.server_address[1])


class DashboardRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "DotfilesDashboard/1.0"
    sys_version = ""

    @property
    def app(self) -> DashboardApp:
        return self.server.app  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _send_bytes(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, status: int, payload: Any) -> None:
        body = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        self._send_bytes(status, "application/json; charset=utf-8", body)

    def _is_valid_host(self, *, require_exact_port: bool) -> bool:
        host_header = self.headers.get("Host")
        if not host_header:
            return False
        port = self.app.port
        if require_exact_port:
            return host_header.lower() in {f"127.0.0.1:{port}", f"localhost:{port}"}
        try:
            parsed = urlsplit(f"//{host_header}")
        except ValueError:
            return False
        if parsed.username is not None or parsed.password is not None or parsed.path or parsed.query or parsed.fragment:
            return False
        hostname = (parsed.hostname or "").lower()
        if hostname not in {"127.0.0.1", "localhost"}:
            return False
        return parsed.port in (None, port)

    def _is_valid_origin(self) -> bool:
        origin = self.headers.get("Origin")
        if origin is None:
            return True
        port = self.app.port
        return origin.lower() in {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}

    def _enforce_post_security(self) -> bool:
        if not self._is_valid_host(require_exact_port=True):
            self._send_json(403, {"ok": False, "error": "forbidden host"})
            return False
        if not self._is_valid_origin():
            self._send_json(403, {"ok": False, "error": "forbidden origin"})
            return False
        header_token = self.headers.get("X-Dashboard-Token") or ""
        if not hmac.compare_digest(header_token, self.app.token):
            self._send_json(403, {"ok": False, "error": "invalid dashboard token"})
            return False
        return True

    def _read_json_body(self) -> dict[str, Any] | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"ok": False, "error": "invalid Content-Length"})
            return None
        if length < 0 or length > 1024 * 1024:
            self._send_json(400, {"ok": False, "error": "request body out of range"})
            return None
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"ok": False, "error": "invalid JSON body"})
            return None
        if not isinstance(data, dict):
            self._send_json(400, {"ok": False, "error": "JSON body must be an object"})
            return None
        return data

    def do_GET(self) -> None:  # noqa: N802
        if not self._is_valid_host(require_exact_port=False) or not self._is_valid_origin():
            self._send_json(403, {"ok": False, "error": "forbidden host or origin"})
            return
        parsed = urlsplit(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)
        refresh = qs.get("refresh", ["0"])[0] == "1"

        if path == "/":
            html_bytes = self.app.render_index_html()
            if html_bytes is None:
                self._send_json(404, {"ok": False, "error": "dashboard/index.html unavailable"})
                return
            self._send_bytes(200, "text/html; charset=utf-8", html_bytes)
            return

        if path in STATIC_ASSET_ALLOWLIST:
            rel_name, content_type = STATIC_ASSET_ALLOWLIST[path]
            asset_bytes = self.app.read_static_asset(rel_name)
            if asset_bytes is None:
                self._send_json(404, {"ok": False, "error": "static asset unavailable"})
                return
            self._send_bytes(200, content_type, asset_bytes)
            return

        if path.startswith("/static/"):
            self._send_json(404, {"ok": False, "error": "not found"})
            return

        if path == "/api/health":
            self._send_json(200, self.app.get_health())
            return

        if path == "/api/overview":
            self._send_json(200, self.app.get_overview())
            return

        if path == "/api/diff":
            raw_path = qs.get("path", [""])[0]
            try:
                payload = self.app.get_diff(raw_path)
            except ValueError as exc:
                self._send_json(400, {"ok": False, "error": self.app.sanitizer.sanitize_str(str(exc))})
                return
            self._send_json(200, payload)
            return

        if path == "/api/skill":
            name = qs.get("name", [""])[0]
            try:
                skill = self.app.get_skill(name)
            except ValueError as exc:
                self._send_json(400, {"ok": False, "error": str(exc)})
                return
            if skill is None:
                self._send_json(404, {"ok": False, "error": "skill not found"})
                return
            self._send_json(200, skill)
            return

        if path == "/api/sync-status":
            self._send_json(200, self.app.get_sync_status(refresh=refresh))
            return

        if path == "/api/github":
            self._send_json(200, self.app.get_github(refresh=refresh))
            return

        if path == "/api/test-suites":
            self._send_json(200, self.app.get_test_suites())
            return

        if path == "/api/jobs":
            self._send_json(200, self.app.list_jobs())
            return

        if path.startswith("/api/jobs/"):
            job_id = path[len("/api/jobs/") :].strip("/")
            if not job_id or "/" in job_id:
                self._send_json(404, {"ok": False, "error": "job not found"})
                return
            job = self.app.get_job(job_id)
            if job is None:
                self._send_json(404, {"ok": False, "error": "job not found"})
                return
            self._send_json(200, {"job": job})
            return

        self._send_json(404, {"ok": False, "error": "not found"})

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_POST(self) -> None:  # noqa: N802
        if not self._enforce_post_security():
            return
        body = self._read_json_body()
        if body is None:
            return
        path = urlsplit(self.path).path

        if path == "/api/swarm/probe":
            try:
                board = self.app.probe_swarm(str(body.get("manifest_path") or ""))
            except ValueError as exc:
                self._send_json(400, {"ok": False, "error": self.app.sanitizer.sanitize_str(str(exc))})
                return
            self._send_json(200, board)
            return

        if path == "/api/actions/run":
            action = str(body.get("action") or "").strip()
            suite = body.get("suite")
            if suite is not None and not isinstance(suite, str):
                self._send_json(400, {"ok": False, "error": "suite must be a string"})
                return
            try:
                job = self.app.start_action_job(action, suite)
            except ValueError as exc:
                self._send_json(400, {"ok": False, "error": self.app.sanitizer.sanitize_str(str(exc))})
                return
            except RuntimeError:
                self._send_json(409, {"ok": False, "error": "已有任务正在执行，请等待完成后重试"})
                return
            self._send_json(202, {"job": job})
            return

        if path == "/api/sync/preview":
            target = str(body.get("target") or "").strip()
            environment = str(body.get("environment") or "work").strip()
            try:
                job = self.app.start_sync_preview_job(target, environment)
            except ValueError as exc:
                self._send_json(400, {"ok": False, "error": self.app.sanitizer.sanitize_str(str(exc))})
                return
            except RuntimeError:
                self._send_json(409, {"ok": False, "error": "已有任务正在执行，请等待完成后重试"})
                return
            self._send_json(202, {"job": job})
            return

        if path == "/api/sync/apply":
            preview_id = body.get("preview_id")
            confirm = body.get("confirm")
            status, payload = self.app.start_sync_apply_job(preview_id, confirm)
            self._send_json(status, payload)
            return

        cancel_m = re.fullmatch(r"/api/jobs/([^/]+)/cancel", path)
        if cancel_m:
            status, payload = self.app.cancel_job(cancel_m.group(1))
            self._send_json(status, payload)
            return

        self._send_json(404, {"ok": False, "error": "not found"})


def server_json_path(repo_root: Path) -> Path:
    return repo_root / "tmp" / "dashboard" / "server.json"


def _probe_existing_instance(repo_root: Path) -> dict[str, Any] | None:
    info_path = server_json_path(repo_root)
    try:
        assert_plain_path_no_reparse(repo_root / "tmp", allow_missing=True)
        assert_plain_path_no_reparse(repo_root / "tmp" / "dashboard", allow_missing=True)
        assert_plain_path_no_reparse(info_path, allow_missing=True)
    except ValueError:
        return None
    if not info_path.is_file():
        return None
    try:
        data = json.loads(info_path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    recorded_root = data.get("repo_root")
    if not isinstance(recorded_root, str) or _norm_path_key(recorded_root) != _norm_path_key(repo_root):
        return None
    url = data.get("url")
    if not isinstance(url, str) or not LOOPBACK_URL_RE.fullmatch(url):
        return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(f"{url}api/health", timeout=0.6) as resp:
            if resp.status != 200:
                return None
            health = json.loads(resp.read().decode("utf-8"))
    except (OSError, ValueError, json.JSONDecodeError, urllib.error.URLError, TimeoutError):
        return None
    if not isinstance(health, dict) or health.get("ok") is not True:
        return None
    if health.get("pid") != data.get("pid") or health.get("port") != data.get("port"):
        return None
    return {
        "url": url,
        "port": int(data["port"]),
        "pid": int(data["pid"]),
        "reused": True,
    }


def write_server_json(repo_root: Path, payload: dict[str, Any]) -> Path:
    tmp_dir = repo_root / "tmp"
    dash_dir = tmp_dir / "dashboard"
    assert_plain_path_no_reparse(tmp_dir, allow_missing=True)
    assert_plain_path_no_reparse(dash_dir, allow_missing=True)
    dash_dir.mkdir(parents=True, exist_ok=True)
    assert_plain_path_no_reparse(dash_dir, allow_missing=False)
    target = dash_dir / "server.json"
    assert_plain_path_no_reparse(target, allow_missing=True)

    raw = (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    fd, tmp_name = tempfile.mkstemp(prefix="server-", suffix=".tmp", dir=os.fspath(dash_dir))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(raw)
        os.replace(tmp_name, target)
    except Exception:
        Path(tmp_name).unlink(missing_ok=True)
        raise
    return target


def cleanup_server_json(info_path: Path, own_pid: int) -> None:
    try:
        assert_plain_path_no_reparse(info_path, allow_missing=True)
        if not info_path.is_file():
            return
        data = json.loads(info_path.read_text(encoding="utf-8-sig"))
        if isinstance(data, dict) and data.get("pid") == own_pid:
            info_path.unlink(missing_ok=True)
    except (OSError, ValueError, UnicodeDecodeError, json.JSONDecodeError):
        pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Local monitoring dashboard for ai-agent-dotfiles")
    parser.add_argument("--repo-root", type=Path, default=default_repo)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--reuse", action="store_true")
    parser.add_argument("--open", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--state-root", type=Path, default=None)
    parser.add_argument("--home-root", type=Path, default=None)
    parser.add_argument("--offline", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    host_norm = str(args.host).strip().lower()
    if host_norm not in {"127.0.0.1", "localhost"}:
        print(f"dashboard: rejected non-loopback host '{args.host}' (only 127.0.0.1 or localhost allowed)", file=sys.stderr, flush=True)
        return 2
    if not 0 <= args.port <= 65535:
        print("dashboard: port must be between 0 and 65535", file=sys.stderr, flush=True)
        return 2

    repo_root = Path(os.path.abspath(os.path.normpath(os.fspath(args.repo_root))))
    if not repo_root.is_dir():
        print(f"dashboard: repo root does not exist: {repo_root}", file=sys.stderr, flush=True)
        return 2

    html_path = repo_root / "dashboard" / "index.html"
    if args.check:
        try:
            assert_plain_path_no_reparse(html_path, allow_missing=False)
            if not html_path.is_file():
                raise ValueError("dashboard/index.html is not a plain file")
        except (OSError, ValueError) as exc:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), flush=True)
            return 2
        print(
            json.dumps(
                {
                    "ok": True,
                    "repo_root": os.fspath(repo_root),
                    "html": os.fspath(html_path),
                },
                ensure_ascii=False,
            ),
            flush=True,
        )
        return 0

    if args.reuse:
        reused = _probe_existing_instance(repo_root)
        if reused is not None:
            if args.open:
                webbrowser.open(reused["url"])
            print(json.dumps(reused, ensure_ascii=False), flush=True)
            return 0

    app = DashboardApp(
        repo_root=repo_root,
        home_root=args.home_root,
        state_root=args.state_root,
        offline=args.offline,
    )
    server = DashboardHTTPServer(("127.0.0.1", args.port), app)
    actual_port = int(server.server_address[1])
    url = f"http://127.0.0.1:{actual_port}/"
    info_payload = {
        "url": url,
        "port": actual_port,
        "pid": os.getpid(),
        "repo_root": os.fspath(repo_root),
        "started_at": app.started_at,
    }
    try:
        info_path = write_server_json(repo_root, info_payload)
    except ValueError as exc:
        server.server_close()
        print(f"dashboard: {exc}", file=sys.stderr, flush=True)
        return 2

    print(
        json.dumps(
            {
                "url": url,
                "port": actual_port,
                "pid": os.getpid(),
                "reused": False,
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    open_timer: threading.Timer | None = None
    if args.open:
        open_timer = threading.Timer(0.15, webbrowser.open, args=(url,))
        open_timer.daemon = True
        open_timer.start()

    stop_event = threading.Event()
    prev_handlers: dict[int, Any] = {}

    def _handle_stop_signal(_signum: int, _frame: Any) -> None:
        if not stop_event.is_set():
            stop_event.set()
            threading.Thread(target=server.shutdown, daemon=True).start()

    if threading.current_thread() is threading.main_thread():
        sig_names = ["SIGTERM"]
        if hasattr(signal, "SIGBREAK"):
            sig_names.append("SIGBREAK")
        for sig_name in sig_names:
            sig_num = getattr(signal, sig_name, None)
            if sig_num is not None:
                try:
                    prev_handlers[sig_num] = signal.getsignal(sig_num)
                    signal.signal(sig_num, _handle_stop_signal)
                except (OSError, ValueError):
                    pass

    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        for sig_num, prev_handler in prev_handlers.items():
            try:
                signal.signal(sig_num, prev_handler)
            except (OSError, ValueError):
                pass
        if open_timer is not None:
            open_timer.cancel()
        server.server_close()
        cleanup_server_json(info_path, os.getpid())
    return 0


__all__ = [
    "ACTION_ZH_MAP",
    "ALLOWED_ACTIONS",
    "ALLOWED_ENVIRONMENTS",
    "ALLOWED_SYNC_TARGETS",
    "CATEGORY_DEFS",
    "DashboardApp",
    "DashboardHTTPServer",
    "DashboardRequestHandler",
    "JobRecord",
    "LOOPBACK_URL_RE",
    "POSIX_HOME_RE",
    "PathSanitizer",
    "PreviewRecord",
    "RunResult",
    "SKILL_NAME_RE",
    "STATIC_ASSET_ALLOWLIST",
    "STATUS_CODE_ZH",
    "WINDOWS_USERS_RE",
    "_norm_path_key",
    "assert_plain_path_no_reparse",
    "cleanup_server_json",
    "is_reparse_or_symlink",
    "main",
    "parse_args",
    "resolve_repo_relative_file",
    "server_json_path",
    "shutil",
    "webbrowser",
    "write_server_json",
]


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main())
