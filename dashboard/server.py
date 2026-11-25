#!/usr/bin/env python3
"""Local loopback-only web monitoring and controlled-sync server for ai-agent-dotfiles."""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
from urllib.parse import parse_qs, urlsplit
import urllib.request
import uuid
import webbrowser
from typing import Any, Callable


RETIRED_HINT_CHECK = False  # Pure stdlib local dashboard server
SKILL_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
LOOPBACK_URL_RE = re.compile(r"^http://127\.0\.0\.1:([1-9][0-9]{0,4})/$")
WINDOWS_USERS_RE = re.compile(r"(?i)[A-Za-z]:[\\/]+Users[\\/]+[^\\/\r\n\t\"'`<>|:;]+")
POSIX_HOME_RE = re.compile(r"(?:/Users/|/home/)[^/\r\n\t\"'`<>|:;\s]+")

ALLOWED_ENVIRONMENTS = ("work", "full", "minimal")
ALLOWED_ACTIONS = frozenset({
    "doctor",
    "scan",
    "build-skills",
    "antigravity-build",
    "test-suite",
    "test-all",
})
ALLOWED_SYNC_TARGETS = frozenset({
    "codex-env",
    "codex-skills",
    "antigravity-config",
    "antigravity-plugin",
    "mcp",
})

CATEGORY_DEFS: tuple[tuple[str, str], ...] = (
    ("skills", "技能内容"),
    ("scripts", "自动化脚本"),
    ("dashboard", "监控台界面"),
    ("rules", "全局规则与提示词"),
    ("config", "环境与清单配置"),
    ("tests", "自动化测试"),
    ("docs", "说明与状态文档"),
    ("other", "其他文件"),
)

STATUS_CODE_ZH = {
    "??": "未跟踪（新增）",
    "A": "已暂存新增",
    "M": "已修改",
    "D": "已删除",
    "R": "已重命名",
    "C": "已复制",
    "U": "存在冲突",
}

ACTION_ZH_MAP = {
    "install": "新增安装",
    "add": "新增",
    "update": "更新覆盖",
    "unchanged": "已同步（无变化）",
    "prune": "清理移除",
    "unknown": "未托管保留",
    "blocked": "受阻（不可写入）",
}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _norm_path_key(path: Path | str) -> str:
    return os.path.normcase(os.path.abspath(os.path.normpath(os.fspath(path))))


def is_reparse_or_symlink(path: Path) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    if stat.S_ISLNK(info.st_mode):
        return True
    attrs = getattr(info, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attrs & reparse_flag)


def assert_plain_path_no_reparse(path: Path, allow_missing: bool = False) -> Path:
    abs_path = Path(os.path.abspath(os.path.normpath(os.fspath(path))))
    chain = list(reversed((abs_path, *abs_path.parents)))
    for component in chain:
        if not component.exists() and not is_reparse_or_symlink(component):
            if allow_missing:
                return abs_path
            raise ValueError(f"path does not exist: {component}")
        if is_reparse_or_symlink(component):
            raise ValueError(f"reparse point or symlink refused: {component}")
    return abs_path


def resolve_repo_relative_file(repo_root: Path, raw_path: str) -> tuple[str, Path]:
    if not isinstance(raw_path, str) or not raw_path.strip():
        raise ValueError("path is required")
    normalized = raw_path.strip().replace("\\", "/")
    if normalized.startswith("/") or re.match(r"^[A-Za-z]:", normalized):
        raise ValueError("absolute path is not allowed")
    parts = [p for p in normalized.split("/") if p]
    if not parts or any(p in (".", "..") for p in parts):
        raise ValueError("path traversal is not allowed")
    candidate = repo_root.joinpath(*parts)
    abs_repo = Path(os.path.abspath(os.path.normpath(os.fspath(repo_root))))
    abs_cand = Path(os.path.abspath(os.path.normpath(os.fspath(candidate))))
    try:
        abs_cand.relative_to(abs_repo)
    except ValueError as exc:
        raise ValueError("path escapes repository root") from exc
    assert_plain_path_no_reparse(abs_cand, allow_missing=True)
    return "/".join(parts), abs_cand


class PathSanitizer:
    """Redacts repository root, user-home, and local state paths in outputs and prompts."""

    def __init__(
        self,
        repo_root: Path,
        home_root: Path | None = None,
        state_root: Path | None = None,
    ) -> None:
        self.repo_variants = self._path_variants(repo_root)
        home_candidates: list[Path] = []
        if home_root is not None:
            home_candidates.append(home_root)
        env_profile = os.environ.get("USERPROFILE")
        if env_profile:
            home_candidates.append(Path(env_profile))
        env_home = os.environ.get("HOME")
        if env_home:
            home_candidates.append(Path(env_home))
        try:
            home_candidates.append(Path.home())
        except Exception:
            pass
        self.home_variants: list[str] = []
        for h in home_candidates:
            for v in self._path_variants(h):
                if v not in self.home_variants:
                    self.home_variants.append(v)

        state_candidates: list[Path] = []
        if state_root is not None:
            state_candidates.append(state_root)
        self.state_variants: list[str] = []
        for s in state_candidates:
            for v in self._path_variants(s):
                if v not in self.state_variants:
                    self.state_variants.append(v)

        local_app = os.environ.get("LOCALAPPDATA")
        self.local_app_variants = self._path_variants(Path(local_app)) if local_app else []

    @staticmethod
    def _path_variants(path: Path) -> list[str]:
        variants: list[str] = []
        raw_items = [os.fspath(path), os.path.abspath(os.path.normpath(os.fspath(path)))]
        try:
            raw_items.append(os.fspath(path.resolve()))
        except OSError:
            pass
        for item in raw_items:
            cleaned = item.rstrip("\\/")
            if not cleaned:
                continue
            for v in (cleaned, cleaned.replace("\\", "/"), cleaned.replace("/", "\\")):
                if v not in variants:
                    variants.append(v)
        variants.sort(key=len, reverse=True)
        return variants

    @staticmethod
    def _replace_ci(text: str, needle: str, replacement: str) -> str:
        if not needle:
            return text
        pattern = re.compile(re.escape(needle), re.IGNORECASE)
        return pattern.sub(lambda _: replacement, text)

    def sanitize_str(self, text: str) -> str:
        if not text:
            return text
        out = text
        for v in self.repo_variants:
            out = self._replace_ci(out, v, "<repo>")
        for v in self.state_variants:
            out = self._replace_ci(out, v, "<state>")
        for v in self.home_variants:
            out = self._replace_ci(out, v, "~")
        for v in self.local_app_variants:
            out = self._replace_ci(out, v, "%LOCALAPPDATA%")
        out = WINDOWS_USERS_RE.sub("~", out)
        out = POSIX_HOME_RE.sub("~", out)
        return out

    def sanitize_value(self, value: Any) -> Any:
        if isinstance(value, str):
            return self.sanitize_str(value)
        if isinstance(value, list):
            return [self.sanitize_value(item) for item in value]
        if isinstance(value, dict):
            return {
                self.sanitize_str(k) if isinstance(k, str) else k: self.sanitize_value(v)
                for k, v in value.items()
            }
        return value


@dataclass
class RunResult:
    exit_code: int
    stdout: str
    stderr: str
    error: str | None = None


@dataclass
class PreviewRecord:
    preview_id: str
    target: str
    environment: str
    repo_head_sha: str
    created_at: float
    expires_at: float
    can_apply: bool
    has_prune: bool
    no_changes: bool
    consumed: bool = False


@dataclass
class JobRecord:
    id: str
    kind: str
    label_zh: str
    status: str
    started_at: str
    started_monotonic: float
    finished_at: str | None = None
    duration_sec: float | None = None
    exit_code: int | None = None
    summary_zh: str = "正在执行中..."
    output_sanitized: str = ""
    structured: dict[str, Any] | None = None
    preview: dict[str, Any] | None = None
    ai_prompt: str | None = None

    def to_summary(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "label_zh": self.label_zh,
            "status": self.status,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "duration_sec": self.duration_sec,
            "exit_code": self.exit_code,
            "summary_zh": self.summary_zh,
        }

    def to_detail(self) -> dict[str, Any]:
        data = self.to_summary()
        data["output_sanitized"] = self.output_sanitized
        data["structured"] = self.structured
        data["preview"] = self.preview
        data["ai_prompt"] = self.ai_prompt
        return data


def default_command_runner(
    argv: list[str],
    cwd: Path,
    timeout: float = 300.0,
) -> RunResult:
    try:
        completed = subprocess.run(
            argv,
            cwd=os.fspath(cwd),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            shell=False,
        )
        return RunResult(
            exit_code=completed.returncode,
            stdout=completed.stdout or "",
            stderr=completed.stderr or "",
        )
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout.decode("utf-8", errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        err = exc.stderr.decode("utf-8", errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        return RunResult(exit_code=124, stdout=out, stderr=err, error=f"command timed out after {timeout}s")
    except OSError as exc:
        return RunResult(exit_code=127, stdout="", stderr="", error=str(exc))


def _extract_json_payload(raw_text: str) -> Any | None:
    text = (raw_text or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    lines = text.splitlines()
    for idx, line in enumerate(lines):
        stripped = line.lstrip()
        if not (stripped.startswith("{") or stripped.startswith("[")):
            continue
        candidate = "\n".join(lines[idx:]).strip()
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            closing = "}" if stripped.startswith("{") else "]"
            pos = candidate.rfind(closing)
            if pos > 0:
                try:
                    return json.loads(candidate[: pos + 1])
                except json.JSONDecodeError:
                    continue
    return None


def _categorize_repo_path(rel_path: str) -> str:
    norm = rel_path.replace("\\", "/")
    if norm.startswith("skills-source/") or norm.startswith("codex/skills/"):
        return "skills"
    if norm.startswith("scripts/") or norm in ("bootstrap.ps1", "start-dashboard.cmd"):
        return "scripts"
    if norm.startswith("dashboard/"):
        return "dashboard"
    if norm == "AGENTS.md" or norm.startswith("codex/") or norm.startswith("antigravity/"):
        return "rules"
    if (
        norm.startswith("harness-source/")
        or norm.startswith("manifests/")
        or norm.startswith("tools/")
        or norm.startswith(".agent-harness/")
        or norm.startswith(".github/")
        or norm in (".gitleaks.toml", ".gitignore", ".gitattributes")
    ):
        return "config"
    if norm.startswith("tests/"):
        return "tests"
    if norm in ("README.md", "STATUS.md") or norm.startswith("docs/") or norm.startswith("status/"):
        return "docs"
    return "other"


def _status_code_to_zh(code: str) -> str:
    cleaned = code.strip()
    if cleaned == "??":
        return STATUS_CODE_ZH["??"]
    if not cleaned:
        return "已变更"
    for ch in cleaned:
        if ch in STATUS_CODE_ZH:
            return STATUS_CODE_ZH[ch]
    return "已变更"


def _parse_frontmatter(text: str) -> dict[str, str]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end_idx = i
            break
    if end_idx is None:
        return {}
    result: dict[str, str] = {}
    current_key: str | None = None
    buffer: list[str] = []
    for line in lines[1:end_idx]:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m and not line.startswith((" ", "\t")):
            if current_key is not None and current_key not in result:
                result[current_key] = " ".join(buffer).strip()
            current_key = m.group(1)
            raw_val = m.group(2).strip()
            if raw_val in ("|", ">", "|-", ">-"):
                buffer = []
            else:
                if (raw_val.startswith('"') and raw_val.endswith('"')) or (
                    raw_val.startswith("'") and raw_val.endswith("'")
                ):
                    raw_val = raw_val[1:-1]
                result[current_key] = raw_val
                current_key = None
                buffer = []
        elif current_key is not None:
            buffer.append(line.strip())
    if current_key is not None and current_key not in result:
        result[current_key] = " ".join(buffer).strip()
    return result


def _extract_psd1_array(text: str, key_pattern: str) -> list[str]:
    m = re.search(key_pattern + r"\s*=\s*@\((.*?)\)", text, flags=re.DOTALL)
    if not m:
        return []
    return re.findall(r"['\"]([^'\"]+)['\"]", m.group(1))


def _extract_psd1_string(text: str, key_name: str) -> str:
    m = re.search(rf"\b{re.escape(key_name)}\s*=\s*'([^']*)'", text)
    if m:
        return m.group(1)
    m = re.search(rf'\b{re.escape(key_name)}\s*=\s*"([^"]*)"', text)
    return m.group(1) if m else ""


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

    def _run_git(self, args: list[str], timeout: float = 3.0) -> RunResult:
        cmd = ["git", "-c", "core.quotepath=false", "-C", os.fspath(self.repo_root), *args]
        return self.runner(cmd, cwd=self.repo_root, timeout=timeout)

    def _get_git_head_sha(self) -> str:
        res = self._run_git(["rev-parse", "HEAD"], timeout=2.0)
        if res.exit_code == 0:
            return res.stdout.strip()
        return ""

    def _collect_repo_overview(self) -> dict[str, Any]:
        status_res = self._run_git(
            ["status", "--porcelain=v1", "--branch", "--untracked-files=all"],
            timeout=2.0,
        )
        branch = ""
        upstream = ""
        ahead = 0
        behind = 0
        grouped: dict[str, list[dict[str, str]]] = {cid: [] for cid, _ in CATEGORY_DEFS}
        total_changes = 0

        if status_res.exit_code == 0:
            for line in status_res.stdout.splitlines():
                if line.startswith("## "):
                    header = line[3:].strip()
                    if header.startswith("No commits yet on "):
                        branch = header[len("No commits yet on ") :].strip()
                        continue
                    bracket_m = re.search(r"\s+\[(.+)\]$", header)
                    if bracket_m:
                        info = bracket_m.group(1)
                        header = header[: bracket_m.start()].strip()
                        ahead_m = re.search(r"ahead\s+(\d+)", info)
                        behind_m = re.search(r"behind\s+(\d+)", info)
                        if ahead_m:
                            ahead = int(ahead_m.group(1))
                        if behind_m:
                            behind = int(behind_m.group(1))
                    if "..." in header:
                        branch, upstream = [p.strip() for p in header.split("...", 1)]
                    else:
                        branch = header
                    continue
                if len(line) < 4:
                    continue
                code = line[:2]
                raw_path = line[3:].strip()
                if " -> " in raw_path:
                    raw_path = raw_path.split(" -> ", 1)[1].strip()
                if raw_path.startswith('"') and raw_path.endswith('"'):
                    raw_path = raw_path[1:-1]
                rel_path = raw_path.replace("\\", "/")
                cat_id = _categorize_repo_path(rel_path)
                grouped[cat_id].append({
                    "path": self.sanitizer.sanitize_str(rel_path),
                    "code": code.strip() or code,
                    "status_zh": _status_code_to_zh(code),
                })
                total_changes += 1

        categories = []
        for cid, label in CATEGORY_DEFS:
            files = grouped[cid]
            if files:
                categories.append({
                    "id": cid,
                    "label": label,
                    "count": len(files),
                    "files": files,
                })

        log_res = self._run_git(
            ["log", "-n", "8", "--format=%h%x1f%s%x1f%cI%x1f%cr"],
            timeout=2.0,
        )
        recent_commits: list[dict[str, str]] = []
        head_short = ""
        head_subject = ""
        if log_res.exit_code == 0:
            for line in log_res.stdout.splitlines():
                parts = line.split("\x1f")
                if len(parts) < 4:
                    continue
                c_hash, c_subj, c_date, c_rel = parts[0], parts[1], parts[2], parts[3]
                subj_clean = self.sanitizer.sanitize_str(c_subj)
                if not head_short:
                    head_short = c_hash
                    head_subject = subj_clean
                recent_commits.append({
                    "hash": c_hash,
                    "subject": subj_clean,
                    "date": c_date,
                    "relative": c_rel,
                })

        return {
            "name": self.repo_root.name,
            "branch": branch or "HEAD",
            "upstream": upstream,
            "ahead": ahead,
            "behind": behind,
            "head_short": head_short,
            "head_subject": head_subject,
            "dirty": total_changes > 0,
            "total_changes": total_changes,
            "categories": categories,
            "recent_commits": recent_commits,
        }

    def _collect_status_doc(self) -> dict[str, Any]:
        last_updated = ""
        open_items: list[dict[str, str]] = []
        status_path = self.repo_root / "STATUS.md"
        if status_path.is_file() and not is_reparse_or_symlink(status_path):
            try:
                text = status_path.read_text(encoding="utf-8", errors="replace")
                m = re.search(r"^Last updated:\s*(.+)$", text, flags=re.MULTILINE)
                if m:
                    last_updated = m.group(1).strip().rstrip(".")
                sec_m = re.search(r"^##\s+Open items\s*\r?\n(.*?)(?=^##\s+|\Z)", text, flags=re.MULTILINE | re.DOTALL)
                if sec_m:
                    bullets = re.split(r"(?m)^-\s+", sec_m.group(1).strip())
                    for raw_b in bullets:
                        item = " ".join(line.strip() for line in raw_b.splitlines() if line.strip())
                        if not item:
                            continue
                        title_m = re.match(r"^\*\*(.+?)\*\*\s*(.*)$", item)
                        if title_m:
                            title = title_m.group(1).strip().rstrip(".")
                            summary = title_m.group(2).strip()
                        else:
                            title = item[:60]
                            summary = item
                        open_items.append({
                            "title": self.sanitizer.sanitize_str(title),
                            "summary": self.sanitizer.sanitize_str(summary),
                        })
            except OSError:
                pass

        active_tasks: list[dict[str, str]] = []
        active_dir = self.repo_root / "status" / "active"
        if active_dir.is_dir() and not is_reparse_or_symlink(active_dir):
            for f in sorted(active_dir.glob("*.md")):
                if f.name.upper() == "README.MD" or is_reparse_or_symlink(f) or not f.is_file():
                    continue
                try:
                    raw = f.read_text(encoding="utf-8", errors="replace")[:2048]
                except OSError:
                    continue
                lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
                title = f.stem
                excerpt_parts: list[str] = []
                for ln in lines:
                    if ln.startswith("# ") and title == f.stem:
                        title = ln[2:].strip()
                    elif not ln.startswith("#"):
                        excerpt_parts.append(ln)
                        if sum(len(p) for p in excerpt_parts) >= 220:
                            break
                excerpt = " ".join(excerpt_parts)[:220]
                active_tasks.append({
                    "file": f.name,
                    "title": self.sanitizer.sanitize_str(title),
                    "excerpt": self.sanitizer.sanitize_str(excerpt),
                })

        return {
            "last_updated": self.sanitizer.sanitize_str(last_updated),
            "open_items": open_items,
            "active_tasks": active_tasks,
        }

    def _collect_skills_catalog(self) -> dict[str, Any]:
        env_dir = self.repo_root / "harness-source" / "envs"
        environments: list[dict[str, Any]] = []
        env_skills_map: dict[str, set[str]] = {}
        if env_dir.is_dir() and not is_reparse_or_symlink(env_dir):
            env_files = sorted(env_dir.glob("*.psd1"), key=lambda p: (ALLOWED_ENVIRONMENTS.index(p.stem) if p.stem in ALLOWED_ENVIRONMENTS else 99, p.stem))
            for ef in env_files:
                if is_reparse_or_symlink(ef) or not ef.is_file():
                    continue
                try:
                    text = ef.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                desc = _extract_psd1_string(text, "Description")
                codex_skills = _extract_psd1_array(text, r"\bCodex")
                env_skills_map[ef.stem] = set(codex_skills)
                environments.append({
                    "name": ef.stem,
                    "description": self.sanitizer.sanitize_str(desc),
                    "count": len(codex_skills),
                    "skills": codex_skills,
                })

        ag_plugin_skills: set[str] = set()
        plugins_psd1 = self.repo_root / "harness-source" / "antigravity" / "plugins.psd1"
        if plugins_psd1.is_file() and not is_reparse_or_symlink(plugins_psd1):
            try:
                p_text = plugins_psd1.read_text(encoding="utf-8", errors="replace")
                ag_plugin_skills = set(_extract_psd1_array(p_text, r"\bSkills"))
            except OSError:
                pass

        skills: list[dict[str, Any]] = []
        shared_count = 0
        codex_only_count = 0
        for scope, scope_zh in (("shared", "双端共享"), ("codex-only", "Codex 专用")):
            scope_dir = self.repo_root / "skills-source" / scope
            if not scope_dir.is_dir() or is_reparse_or_symlink(scope_dir):
                continue
            for item in sorted(scope_dir.iterdir(), key=lambda p: p.name):
                if not item.is_dir() or is_reparse_or_symlink(item):
                    continue
                skill_md = item / "SKILL.md"
                if not skill_md.is_file() or is_reparse_or_symlink(skill_md):
                    continue
                try:
                    content = skill_md.read_text(encoding="utf-8", errors="replace")[:4096]
                except OSError:
                    continue
                fm = _parse_frontmatter(content)
                name = fm.get("name") or item.name
                desc = fm.get("description", "")
                in_envs = [e["name"] for e in environments if name in env_skills_map.get(e["name"], set())]
                in_ag = scope == "shared" and name in ag_plugin_skills
                if scope == "shared":
                    shared_count += 1
                else:
                    codex_only_count += 1
                skills.append({
                    "name": name,
                    "scope": scope,
                    "scope_zh": scope_zh,
                    "description": self.sanitizer.sanitize_str(desc),
                    "in_envs": in_envs,
                    "in_antigravity_plugin": in_ag,
                    "path": f"skills-source/{scope}/{item.name}/SKILL.md",
                })

        return {
            "total": len(skills),
            "shared_count": shared_count,
            "codex_only_count": codex_only_count,
            "environments": environments,
            "skills": skills,
        }

    def _probe_board_manifest(self, manifest_path: Path) -> dict[str, Any]:
        info_path = manifest_path.with_name("board-server.json")
        run_name = manifest_path.parent.name
        try:
            assert_plain_path_no_reparse(manifest_path, allow_missing=False)
            m_data = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
            if isinstance(m_data, dict) and isinstance(m_data.get("run"), str) and m_data["run"].strip():
                run_name = m_data["run"].strip()
        except (OSError, ValueError, json.JSONDecodeError):
            pass

        url = ""
        running = False
        event_count = 0
        ui_gets = 0
        state_polls = 0

        if info_path.is_file() and not is_reparse_or_symlink(info_path):
            try:
                assert_plain_path_no_reparse(info_path, allow_missing=False)
                b_data = json.loads(info_path.read_text(encoding="utf-8-sig"))
                if isinstance(b_data, dict):
                    if isinstance(b_data.get("run"), str) and b_data["run"].strip():
                        run_name = b_data["run"].strip()
                    raw_url = b_data.get("url")
                    if isinstance(raw_url, str) and LOOPBACK_URL_RE.fullmatch(raw_url):
                        port = int(LOOPBACK_URL_RE.fullmatch(raw_url).group(1))  # type: ignore[union-attr]
                        if 1 <= port <= 65535:
                            url = raw_url
            except (OSError, ValueError, json.JSONDecodeError):
                pass

        if url:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            try:
                with opener.open(f"{url}api/health", timeout=0.4) as resp:
                    if resp.status == 200:
                        health = json.loads(resp.read().decode("utf-8"))
                        if isinstance(health, dict) and health.get("ok") is True:
                            running = True
                            event_count = int(health.get("eventCount") or 0)
                            ui_gets = int(health.get("uiGets") or 0)
                            state_polls = int(health.get("statePolls") or 0)
                            if isinstance(health.get("run"), str) and health["run"].strip():
                                run_name = health["run"].strip()
            except (OSError, ValueError, json.JSONDecodeError, urllib.error.URLError, TimeoutError):
                running = False

        return {
            "run": self.sanitizer.sanitize_str(run_name),
            "manifest_path_display": self.sanitizer.sanitize_str(os.fspath(manifest_path)),
            "url": url,
            "running": running,
            "event_count": event_count,
            "ui_gets": ui_gets,
            "state_polls": state_polls,
        }

    def _collect_swarm_boards(self) -> dict[str, Any]:
        candidates: list[Path] = []
        seen: set[str] = set()

        def _add_candidate(p: Path) -> None:
            key = _norm_path_key(p)
            if key not in seen:
                seen.add(key)
                candidates.append(p)

        tmp_root = self.repo_root / "tmp"
        if tmp_root.is_dir() and not is_reparse_or_symlink(tmp_root):
            base_depth = len(tmp_root.parts)
            for root_str, dirnames, filenames in os.walk(tmp_root, followlinks=False):
                cur = Path(root_str)
                if is_reparse_or_symlink(cur):
                    dirnames[:] = []
                    continue
                depth = len(cur.parts) - base_depth
                dirnames[:] = [
                    d
                    for d in dirnames
                    if depth < 4 and not is_reparse_or_symlink(cur / d)
                ]
                if "manifest.json" in filenames and "board-server.json" in filenames:
                    m_path = cur / "manifest.json"
                    if not is_reparse_or_symlink(m_path):
                        _add_candidate(m_path)

        with self._lock:
            watched = list(self._watched_manifests)
        for p in watched:
            if p.is_file() and not is_reparse_or_symlink(p):
                _add_candidate(p)

        boards = [self._probe_board_manifest(p) for p in candidates]
        return {"boards": boards}

    def _compute_attention(
        self,
        repo: dict[str, Any],
        status_doc: dict[str, Any],
        sync_cached: dict[str, Any] | None,
        gh_cached: dict[str, Any] | None,
    ) -> list[dict[str, Any]]:
        cards: list[dict[str, Any]] = []

        if sync_cached is not None:
            lvl = sync_cached.get("summary_level")
            if lvl in ("warn", "error"):
                cards.append({
                    "level": lvl,
                    "title": "双端配置存在差异或异常" if lvl == "warn" else "双端状态检查报错",
                    "detail": self.sanitizer.sanitize_str(str(sync_cached.get("summary_zh") or "请先运行预览或体检排查。")),
                    "action_type": "preview" if lvl == "warn" else "doctor",
                    "action_label": "前往同步预览" if lvl == "warn" else "运行健康体检",
                    "ai_prompt": self.sanitizer.sanitize_str(
                        f"请帮我分析 ai-agent-dotfiles 当前双端同步状态（{sync_cached.get('summary_zh', '')}），判断是否需要执行同步并给出最小安全操作。"
                    ),
                })

        if gh_cached and gh_cached.get("available"):
            for run in gh_cached.get("ci_runs", [])[:3]:
                conclusion = (run.get("conclusion") or "").lower()
                if conclusion in ("failure", "timed_out", "cancelled"):
                    cards.append({
                        "level": "error",
                        "title": f"GitHub CI 失败：{run.get('workflowName', 'Validate')}",
                        "detail": self.sanitizer.sanitize_str(
                            f"分支 {run.get('headBranch', '')} 提交「{run.get('displayTitle', '')}」结果为 {conclusion}。"
                        ),
                        "action_type": "ai",
                        "action_label": "复制给 AI 排查 CI",
                        "ai_prompt": self.sanitizer.sanitize_str(
                            f"GitHub CI 工作流 {run.get('workflowName', '')}（run {run.get('databaseId', '')}，分支 {run.get('headBranch', '')}）失败，请帮我检查失败日志并定位原因。"
                        ),
                    })
                    break

        if repo.get("dirty"):
            n = int(repo.get("total_changes") or 0)
            cards.append({
                "level": "warn",
                "title": f"工作区有 {n} 项未提交改动",
                "detail": "请核对改动内容，确认无误后再提交或同步。",
                "action_type": "ai",
                "action_label": "复制给 AI 复核并提交",
                "ai_prompt": self.sanitizer.sanitize_str(
                    f"请帮我复核当前仓库（分支 {repo.get('branch', '')}）中的 {n} 项未提交改动，运行必要校验后准备小步提交。"
                ),
            })

        active_tasks = status_doc.get("active_tasks") or []
        if active_tasks:
            titles = "、".join(t.get("file", "") for t in active_tasks[:3])
            cards.append({
                "level": "warn",
                "title": f"有 {len(active_tasks)} 个进行中的任务记录",
                "detail": self.sanitizer.sanitize_str(f"status/active/ 中存在：{titles}"),
                "action_type": "none",
                "action_label": "",
                "ai_prompt": "",
            })

        if not cards:
            cards.append({
                "level": "ok",
                "title": "一切正常，工作区干净",
                "detail": "当前没有未提交改动或已知阻塞项，可按需刷新双端同步状态。",
                "action_type": "none",
                "action_label": "",
                "ai_prompt": "",
            })
        return cards

    def get_overview(self) -> dict[str, Any]:
        repo = self._collect_repo_overview()
        status_doc = self._collect_status_doc()
        skills_catalog = self._collect_skills_catalog()
        swarm = self._collect_swarm_boards()
        with self._lock:
            active_job = self._active_job_summary_locked()
            recent_jobs = [self._jobs[jid].to_summary() for jid in reversed(self._job_order[-10:])]
            sync_cached = self._sync_status_cache
            gh_cached = self._github_cache
        attention = self._compute_attention(repo, status_doc, sync_cached, gh_cached)
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
            diff_res = self._run_git(["diff", "--", rel_path], timeout=4.0)
            diff_text = diff_res.stdout
            if not diff_text.strip():
                staged_res = self._run_git(["diff", "--cached", "--", rel_path], timeout=4.0)
                if staged_res.stdout.strip():
                    diff_text = staged_res.stdout
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
        combined_raw = "\n".join(part for part in (res.stdout, res.stderr, res.error or "") if part)
        raw_sanitized = self.sanitizer.sanitize_str(combined_raw)
        parsed = _extract_json_payload(res.stdout)
        fetched_at = utc_now_iso()

        if not isinstance(parsed, dict):
            result = {
                "ok": False,
                "fetched_at": fetched_at,
                "exit_code": res.exit_code,
                "summary_level": "error",
                "summary_zh": "无法解析双端同步状态输出",
                "environment": {"recorded": "unavailable", "available": [], "failed": True, "summary_zh": "环境状态不可用"},
                "config": {"items": [], "summary": None, "summary_zh": "配置状态不可用"},
                "antigravity": {"action": "error", "summary_zh": "Antigravity 插件状态不可用"},
                "mcp": {"items": [], "summary": None, "summary_zh": "MCP 状态不可用"},
                "attention": [],
                "raw_sanitized": raw_sanitized,
                "error": self.sanitizer.sanitize_str(res.error or "status -Json 未返回有效 JSON"),
            }
            with self._lock:
                self._sync_status_cache = result
            return result

        sanitized_report = self.sanitizer.sanitize_value(parsed)
        env_raw = sanitized_report.get("Environment") or {}
        cfg_raw = sanitized_report.get("Config")
        ag_raw = sanitized_report.get("Antigravity") or {}
        mcp_raw = sanitized_report.get("Mcp") or {}
        summary_raw = sanitized_report.get("Summary") or {}

        recorded_env = env_raw.get("Recorded") or "unavailable"
        env_failed = bool(env_raw.get("Failed"))
        env_summary_zh = (
            "未检测到技能部署记录" if recorded_env == "unavailable" else f"上次记录环境：{recorded_env}"
        )

        cfg_items = cfg_raw if isinstance(cfg_raw, list) else []
        cfg_summary = summary_raw.get("Config") if isinstance(summary_raw, dict) else None
        cfg_differs = int((cfg_summary or {}).get("differs", 0) + (cfg_summary or {}).get("repo-only", 0))
        if isinstance(cfg_raw, dict) and cfg_raw.get("Error"):
            cfg_summary_zh = f"配置检查出错：{cfg_raw.get('Error')}"
        elif cfg_differs > 0:
            cfg_summary_zh = f"有 {cfg_differs} 项受管规则与仓库存在差异"
        else:
            cfg_summary_zh = "Codex 与 Antigravity 全局规则均已对齐"

        ag_action = str(ag_raw.get("Action") or summary_raw.get("Antigravity") or "unavailable")
        ag_req = ag_raw.get("ApplyRequirement")
        if ag_raw.get("Error"):
            ag_summary_zh = f"插件状态异常：{ag_raw.get('Error')}"
        elif ag_action == "unchanged":
            ag_summary_zh = f"自有插件 v{ag_raw.get('Version', '?')} 已安装且一致"
        elif ag_action == "update" and ag_req == "build-with-current-agy-before-apply":
            ag_summary_zh = "插件有新版本，需先使用当前 agy 重新打包后再部署"
        elif ag_action in ("install", "update"):
            ag_summary_zh = f"自有插件可执行{ACTION_ZH_MAP.get(ag_action, ag_action)}"
        else:
            ag_summary_zh = f"插件状态：{ag_raw.get('Reason') or ag_action}"

        mcp_items = mcp_raw.get("Items") if isinstance(mcp_raw, dict) and isinstance(mcp_raw.get("Items"), list) else []
        mcp_summary = mcp_raw.get("Summary") if isinstance(mcp_raw, dict) else None
        if isinstance(mcp_raw, dict) and mcp_raw.get("Error"):
            mcp_summary_zh = f"MCP 状态异常：{mcp_raw.get('Error')}"
        elif isinstance(mcp_summary, dict):
            blocked = int(mcp_summary.get("blocked", 0))
            pending = int(mcp_summary.get("add", 0)) + int(mcp_summary.get("update", 0))
            if blocked > 0:
                mcp_summary_zh = f"有 {blocked} 项 MCP 映射受阻"
            elif pending > 0:
                mcp_summary_zh = f"有 {pending} 项 MCP 映射待同步"
            else:
                mcp_summary_zh = "受管 MCP 服务已对齐"
        else:
            mcp_summary_zh = "MCP 状态不可用"

        has_error = res.exit_code != 0 or env_failed or bool(
            (isinstance(cfg_raw, dict) and cfg_raw.get("Error"))
            or ag_raw.get("Error")
            or (isinstance(mcp_raw, dict) and mcp_raw.get("Error"))
        )
        has_blocked = (
            ag_action == "blocked"
            or ag_req == "build-with-current-agy-before-apply"
            or (isinstance(mcp_summary, dict) and int(mcp_summary.get("blocked", 0)) > 0)
        )
        has_drift = (
            cfg_differs > 0
            or ag_action in ("install", "update")
            or (isinstance(mcp_summary, dict) and (int(mcp_summary.get("add", 0)) + int(mcp_summary.get("update", 0))) > 0)
        )

        if has_error or has_blocked:
            summary_level = "error"
            summary_zh = "检测到状态异常或受阻项，请先排查后再执行写入"
        elif has_drift or recorded_env == "unavailable":
            summary_level = "warn"
            summary_zh = "部分配置或资产与仓库不完全一致，可先预览差异"
        else:
            summary_level = "ok"
            summary_zh = "双端规则、插件与受管 MCP 均已同步"

        attention = []
        if has_drift:
            attention.append({"level": "warn", "detail": summary_zh})

        result = {
            "ok": res.exit_code == 0,
            "fetched_at": fetched_at,
            "exit_code": res.exit_code,
            "summary_level": summary_level,
            "summary_zh": summary_zh,
            "environment": {
                "recorded": recorded_env,
                "reason": env_raw.get("Reason"),
                "available": env_raw.get("Available") or [],
                "failed": env_failed,
                "summary_zh": env_summary_zh,
            },
            "config": {
                "items": cfg_items,
                "summary": cfg_summary,
                "error": cfg_raw.get("Error") if isinstance(cfg_raw, dict) else None,
                "summary_zh": cfg_summary_zh,
            },
            "antigravity": {
                "name": ag_raw.get("Name"),
                "version": ag_raw.get("Version"),
                "action": ag_action,
                "reason": ag_raw.get("Reason"),
                "enabled": ag_raw.get("Enabled"),
                "apply_requirement": ag_req,
                "external": ag_raw.get("ExternalExpectations") or [],
                "error": ag_raw.get("Error"),
                "summary_zh": ag_summary_zh,
            },
            "mcp": {
                "items": mcp_items,
                "summary": mcp_summary,
                "error": mcp_raw.get("Error") if isinstance(mcp_raw, dict) else None,
                "summary_zh": mcp_summary_zh,
            },
            "attention": attention,
            "raw_sanitized": raw_sanitized,
            "error": None if res.exit_code == 0 else self.sanitizer.sanitize_str(res.error or f"status exited with {res.exit_code}"),
        }
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

        gh_exe = shutil.which("gh")
        if not gh_exe:
            offline_res = {
                "available": False,
                "offline": True,
                "message_zh": "当前离线或无法连接 GitHub（不影响本地监控）",
                "open_prs": [],
                "ci_runs": [],
            }
            with self._lock:
                self._github_cache = offline_res
            return offline_res

        pr_res = self.runner(
            [gh_exe, "pr", "list", "--state", "open", "--limit", "10", "--json", "number,title,headRefName,url,updatedAt"],
            cwd=self.repo_root,
            timeout=8.0,
        )
        run_res = self.runner(
            [gh_exe, "run", "list", "--limit", "8", "--json", "databaseId,workflowName,status,conclusion,headBranch,displayTitle,url,createdAt"],
            cwd=self.repo_root,
            timeout=8.0,
        )

        if pr_res.exit_code != 0 or run_res.exit_code != 0:
            offline_res = {
                "available": False,
                "offline": True,
                "message_zh": "当前离线或无法连接 GitHub（不影响本地监控）",
                "open_prs": [],
                "ci_runs": [],
            }
            with self._lock:
                self._github_cache = offline_res
            return offline_res

        try:
            prs = json.loads(pr_res.stdout or "[]")
            runs = json.loads(run_res.stdout or "[]")
            if not isinstance(prs, list) or not isinstance(runs, list):
                raise ValueError("unexpected GitHub JSON shape")
        except (ValueError, json.JSONDecodeError):
            offline_res = {
                "available": False,
                "offline": True,
                "message_zh": "当前离线或无法连接 GitHub（不影响本地监控）",
                "open_prs": [],
                "ci_runs": [],
            }
            with self._lock:
                self._github_cache = offline_res
            return offline_res

        result = {
            "available": True,
            "offline": False,
            "message_zh": "已连接 GitHub",
            "open_prs": self.sanitizer.sanitize_value(prs),
            "ci_runs": self.sanitizer.sanitize_value(runs),
        }
        with self._lock:
            self._github_cache = result
        return result

    def probe_swarm(self, manifest_path_raw: str) -> dict[str, Any]:
        if not isinstance(manifest_path_raw, str) or not manifest_path_raw.strip():
            raise ValueError("manifest_path is required")
        candidate = Path(manifest_path_raw.strip())
        if candidate.name != "manifest.json":
            raise ValueError("manifest_path must point to a file named manifest.json")
        abs_manifest = assert_plain_path_no_reparse(candidate, allow_missing=False)
        if not abs_manifest.is_file():
            raise ValueError("manifest_path must be a plain file")
        with self._lock:
            key = _norm_path_key(abs_manifest)
            if not any(_norm_path_key(p) == key for p in self._watched_manifests):
                self._watched_manifests.append(abs_manifest)
        return self._probe_board_manifest(abs_manifest)

    def _build_action_command(self, action: str, suite: str | None) -> tuple[str, list[str], float]:
        if action not in ALLOWED_ACTIONS:
            raise ValueError(f"unsupported action: {action}")
        pwsh = shutil.which("pwsh") or "pwsh"
        scripts_dir = self.repo_root / "scripts"
        repo_str = os.fspath(self.repo_root)

        if action == "doctor":
            argv = [pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "doctor.ps1"), "-RepoRoot", repo_str]
            if self.home_root is not None:
                argv.extend(["-HomeRoot", os.fspath(self.home_root)])
            return "运行健康体检 (doctor)", argv, 120.0
        if action == "scan":
            return (
                "秘密扫描 (scan-secrets)",
                [pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "scan-secrets.ps1"), "-RepoRoot", repo_str],
                120.0,
            )
        if action == "build-skills":
            return (
                "构建技能目录 (build-skills)",
                [pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "build-skills.ps1"), "-RepoRoot", repo_str],
                120.0,
            )
        if action == "antigravity-build":
            return (
                "打包 Antigravity 插件",
                [pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "agent-dotfiles.ps1"), "antigravity", "build", "-RepoRoot", repo_str],
                120.0,
            )
        if action == "test-suite":
            if not isinstance(suite, str) or not suite.strip():
                raise ValueError("suite is required for test-suite")
            suite_clean = suite.strip()
            if "/" in suite_clean or "\\" in suite_clean:
                raise ValueError("invalid suite filename")
            tests_dir = self.repo_root / "tests"
            valid_suites = {p.name for p in tests_dir.glob("*.tests.ps1") if p.is_file()}
            if suite_clean not in valid_suites:
                raise ValueError(f"unknown test suite: {suite_clean}")
            return (
                f"运行单套测试 ({suite_clean})",
                [pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "run-tests.ps1"), "-RepoRoot", repo_str, "-Suite", suite_clean],
                300.0,
            )
        return (
            "运行全量测试 (run-tests)",
            [pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "run-tests.ps1"), "-RepoRoot", repo_str],
            1800.0,
        )

    def _build_sync_command(self, target: str, environment: str, *, apply_mode: bool) -> tuple[str, list[str]]:
        if target not in ALLOWED_SYNC_TARGETS:
            raise ValueError(f"unsupported sync target: {target}")
        if environment not in ALLOWED_ENVIRONMENTS:
            raise ValueError(f"unsupported environment: {environment}")
        pwsh = shutil.which("pwsh") or "pwsh"
        scripts_dir = self.repo_root / "scripts"
        repo_str = os.fspath(self.repo_root)
        mode_flag = "-Apply" if apply_mode else "-DryRun"
        mode_zh = "写入" if apply_mode else "预览"

        if target == "codex-env":
            argv = [
                pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "agent-dotfiles.ps1"),
                "env", "deploy", environment, mode_flag, "-RepoRoot", repo_str,
            ]
            if self.home_root is not None:
                argv.extend(["-HomeRoot", os.fspath(self.home_root)])
                argv.extend(["-BackupRoot", os.fspath(self.home_root / ".ai-agent-dotfiles-backups")])
            if self.state_root is not None:
                argv.extend(["-StateRoot", os.fspath(self.state_root)])
            return f"{mode_zh} Codex 完整同步 ({environment})", argv

        if target == "codex-skills":
            argv = [
                pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "deploy-skills.ps1"),
                "-Environment", environment, "-RepoRoot", repo_str,
            ]
            if apply_mode:
                argv.append("-Apply")
            if self.home_root is not None:
                argv.extend(["-HomeRoot", os.fspath(self.home_root)])
            if self.state_root is not None:
                argv.extend(["-StateRoot", os.fspath(self.state_root)])
            return f"{mode_zh} Codex 技能同步 ({environment})", argv

        if target == "antigravity-config":
            argv = [
                pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "agent-dotfiles.ps1"),
                "config", "pull", "-Platform", "Antigravity", mode_flag, "-RepoRoot", repo_str,
            ]
            if self.home_root is not None:
                argv.extend(["-HomeRoot", os.fspath(self.home_root)])
                argv.extend(["-BackupRoot", os.fspath(self.home_root / ".ai-agent-dotfiles-backups")])
            return f"{mode_zh} Antigravity 全局规则同步", argv

        if target == "antigravity-plugin":
            argv = [
                pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "agent-dotfiles.ps1"),
                "antigravity", "deploy", mode_flag, "-RepoRoot", repo_str,
            ]
            return f"{mode_zh} Antigravity 自有插件部署", argv

        # target == "mcp"
        argv = [
            pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "agent-dotfiles.ps1"),
            "mcp", "deploy", mode_flag, "-RepoRoot", repo_str,
        ]
        if self.home_root is not None:
            argv.extend(["-HomeRoot", os.fspath(self.home_root)])
            argv.extend(["-BackupRoot", os.fspath(self.home_root / ".ai-agent-dotfiles-backups")])
        return f"{mode_zh}受管 MCP 服务同步", argv

    def _parse_doctor_structured(self, output_sanitized: str) -> dict[str, Any]:
        checks: list[dict[str, str]] = []
        blockers: list[str] = []
        in_blockers = False
        for raw_line in output_sanitized.splitlines():
            line = raw_line.strip()
            m = re.match(r"^\[(PASS|WARN|FAIL|INFO)\]\s*(.+)$", line)
            if m:
                in_blockers = False
                checks.append({"level": m.group(1), "message": m.group(2).strip()})
                continue
            bm = re.match(r"^Deploy blockers:\s*(\d+)\b", line)
            if bm and int(bm.group(1)) > 0:
                in_blockers = True
                continue
            if line.startswith("Deploy blockers: none"):
                in_blockers = False
                continue
            if line.startswith("Doctor result:") or line.startswith("==="):
                in_blockers = False
                continue
            if in_blockers and line:
                blockers.append(line)
        return {"checks": checks, "blockers": blockers}

    def _parse_preview_output(
        self,
        target: str,
        environment: str,
        res: RunResult,
        output_sanitized: str,
        repo_head_sha: str,
    ) -> tuple[dict[str, Any], PreviewRecord]:
        items: list[dict[str, str]] = []
        has_prune = False
        has_blocked = False
        has_changes = False

        lowered = output_sanitized.lower()
        if "build-with-current-agy-before-apply" in lowered or "preflight failed" in lowered:
            has_blocked = True
        if re.search(r"Deploy blockers:\s*[1-9]\d*", output_sanitized):
            has_blocked = True

        if target == "antigravity-plugin":
            parsed = _extract_json_payload(res.stdout)
            if isinstance(parsed, dict):
                s_parsed = self.sanitizer.sanitize_value(parsed)
                action = str(s_parsed.get("Action") or "blocked")
                reason = str(s_parsed.get("Reason") or "")
                req = str(s_parsed.get("ApplyRequirement") or "")
                name = str(s_parsed.get("Name") or "ai-agent-dotfiles")
                if action == "blocked" or req == "build-with-current-agy-before-apply":
                    has_blocked = True
                if action in ("install", "update"):
                    has_changes = True
                items.append({
                    "action": action,
                    "action_zh": ACTION_ZH_MAP.get(action, action),
                    "name": name,
                    "detail": f"{reason}" + (f" ({req})" if req and req != "none" else ""),
                })
            else:
                has_blocked = True
        else:
            for line in output_sanitized.splitlines():
                stripped = line.strip()
                # deploy-skills table line: Codex install skill-name
                sm = re.match(r"^(Codex)\s+(install|update|unchanged|prune|unknown)\s+(\S+)$", line.strip())
                if sm:
                    act, name = sm.group(2), sm.group(3)
                    if act in ("install", "update", "prune"):
                        has_changes = True
                    if act == "prune":
                        has_prune = True
                    items.append({
                        "action": act,
                        "action_zh": ACTION_ZH_MAP.get(act, act),
                        "name": f"{sm.group(1)}/{name}",
                        "detail": "技能目录变更" if act != "unchanged" else "内容一致",
                    })
                    continue

                # config-pull line:   add     Codex/AGENTS.md
                cm = re.match(r"^\s{2}(add|update)\s+(\S.*)$", line)
                if cm and not stripped.startswith("["):
                    act, name = cm.group(1), cm.group(2).strip()
                    if name.startswith("Codex/") or name.startswith("Antigravity/"):
                        has_changes = True
                        items.append({
                            "action": act,
                            "action_zh": ACTION_ZH_MAP.get(act, act),
                            "name": name,
                            "detail": "受管配置更新（保留块外个人内容）" if "AGENTS.md" in name else "配置文件复制",
                        })
                    continue

                # mcp-sync line:   [Codex      ] blender          add       (missing-in-codex)  unmanaged-preserved=1
                mm = re.match(r"^\s*\[([^\]]+)\]\s+(\S+)\s+(add|update|unchanged|blocked)\s+\(([^)]*)\)", line)
                if mm:
                    plat, srv, act, reason = mm.group(1).strip(), mm.group(2).strip(), mm.group(3), mm.group(4)
                    if act in ("add", "update"):
                        has_changes = True
                    if act == "blocked":
                        has_blocked = True
                    items.append({
                        "action": act,
                        "action_zh": ACTION_ZH_MAP.get(act, act),
                        "name": f"{plat}/{srv}",
                        "detail": reason,
                    })
                    continue

                if re.search(r"\bblocked=[1-9]\d*\b", line) or re.search(r"\bAction\s*[:=]\s*blocked\b", line, re.IGNORECASE):
                    has_blocked = True
                if re.search(r"\bprune=[1-9]\d*\b", line):
                    has_prune = True
                    has_changes = True
                if re.search(r"\b(install|add|update)=[1-9]\d*\b", line):
                    has_changes = True

        no_changes = (res.exit_code == 0) and (not has_blocked) and (not has_changes)
        can_apply = (res.exit_code == 0) and (not has_blocked) and has_changes

        if res.exit_code != 0:
            summary_zh = f"预览命令执行失败（退出码 {res.exit_code}），禁止写入"
        elif has_blocked:
            summary_zh = "存在受阻项或未满足前置构建门禁，禁止写入"
        elif no_changes:
            summary_zh = "当前所有项目均已同步，无需执行写入"
        else:
            change_cnt = sum(1 for it in items if it["action"] in ("install", "add", "update", "prune"))
            summary_zh = f"预览通过，共 {change_cnt or 1} 项待写入变更，核对后可执行"

        risk_map = {
            "codex-env": "写入范围：~/.codex/skills（逐目录原子替换，保留 .system 与未托管目录）及 ~/.codex 下受管配置（覆盖前自动备份）。",
            "codex-skills": "写入范围：仅写入选中的 Codex 技能目录；旧版本自动备份到部署状态目录，绝不触碰 .system 或未托管目录。",
            "antigravity-config": "写入范围：仅更新 ~/.gemini/config/AGENTS.md 中的受管标记块，块外个人规则完整保留，覆盖前自动备份。",
            "antigravity-plugin": "写入范围：通过官方 agy plugin 命令安装或升级自有插件 ai-agent-dotfiles，升级前自动备份，其他插件保持不变。",
            "mcp": "写入范围：仅投影 servers.psd1 声明的受管服务条目（Antigravity 按条目合并 JSON，Codex 调用 codex mcp），保留全部未托管服务并自动备份。",
        }
        risk_notice_zh = risk_map[target]
        if has_prune:
            risk_notice_zh += " 注意：本次计划包含清理移除（prune）此前由本工具部署但当前环境未选中的旧技能。"

        now_ts = time.time()
        preview_id = str(uuid.uuid4())
        record = PreviewRecord(
            preview_id=preview_id,
            target=target,
            environment=environment,
            repo_head_sha=repo_head_sha,
            created_at=now_ts,
            expires_at=now_ts + 300.0,
            can_apply=can_apply,
            has_prune=has_prune,
            no_changes=no_changes,
            consumed=False,
        )
        preview_payload = {
            "preview_id": preview_id,
            "target": target,
            "environment": environment,
            "can_apply": can_apply,
            "has_prune": has_prune,
            "no_changes": no_changes,
            "summary_zh": summary_zh,
            "items": items,
            "risk_notice_zh": risk_notice_zh,
            "expires_in_sec": 300,
            "repo_head_sha": repo_head_sha,
        }
        return preview_payload, record

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

        def _worker() -> None:
            res = self.runner(argv, cwd=self.repo_root, timeout=timeout)
            combined = "\n".join(part for part in (res.stdout, res.stderr, res.error or "") if part)
            output_sanitized = self.sanitizer.sanitize_str(combined)
            with self._lock:
                job.finished_at = utc_now_iso()
                job.duration_sec = round(max(0.0, time.monotonic() - job.started_monotonic), 3)
                job.exit_code = res.exit_code
                job.output_sanitized = output_sanitized
                job.status = "succeeded" if res.exit_code == 0 else "failed"
                job.summary_zh = f"{label_zh} 完成" if res.exit_code == 0 else f"{label_zh} 失败（退出码 {res.exit_code}）"
                if on_complete is not None:
                    on_complete(job, res, output_sanitized)
                if job.status == "failed" and not job.ai_prompt:
                    tail = "\n".join(output_sanitized.splitlines()[-30:])
                    job.ai_prompt = self.sanitizer.sanitize_str(
                        f"本地任务「{label_zh}」执行失败（退出码 {res.exit_code}），请帮我排查以下脱敏输出：\n\n{tail}"
                    )
                if self._active_job_id == job.id:
                    self._active_job_id = None

        thread = threading.Thread(target=_worker, daemon=True)
        thread.start()
        return job.to_summary()

    def start_action_job(self, action: str, suite: str | None = None) -> dict[str, Any]:
        label_zh, argv, timeout = self._build_action_command(action, suite)

        def _after(job: JobRecord, _res: RunResult, output_sanitized: str) -> None:
            if action == "doctor":
                structured = self._parse_doctor_structured(output_sanitized)
                job.structured = structured
                if structured["blockers"]:
                    job.summary_zh = f"健康体检发现 {len(structured['blockers'])} 个部署阻塞项"

        return self._spawn_job(f"action:{action}", label_zh, argv, timeout, on_complete=_after)

    def start_sync_preview_job(self, target: str, environment: str = "work") -> dict[str, Any]:
        label_zh, argv = self._build_sync_command(target, environment, apply_mode=False)
        head_sha = self._get_git_head_sha()

        def _after(job: JobRecord, res: RunResult, output_sanitized: str) -> None:
            preview_payload, record = self._parse_preview_output(target, environment, res, output_sanitized, head_sha)
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

            current_head = self._get_git_head_sha()
            if current_head != rec.repo_head_sha:
                return 409, {"ok": False, "error": "仓库 HEAD 已发生变化，请重新生成预览后再写入"}

            rec.consumed = True

        label_zh, argv = self._build_sync_command(rec.target, rec.environment, apply_mode=True)

        def _after(job: JobRecord, res: RunResult, _output_sanitized: str) -> None:
            self._sync_status_cache = None
            if res.exit_code == 0:
                job.summary_zh = f"{label_zh} 成功，已刷新双端状态缓存"

        try:
            job_summary = self._spawn_job(f"apply:{rec.target}", label_zh, argv, 300.0, on_complete=_after)
        except RuntimeError:
            return 409, {"ok": False, "error": "已有任务正在执行，请等待完成后重试"}
        return 202, {"job": job_summary}

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
    if args.open:
        webbrowser.open(url)

    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        cleanup_server_json(info_path, os.getpid())
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main())
