"""Read-only repository, status, skills catalog, swarm, GitHub, and attention collectors."""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import threading
from typing import Any, Callable
import urllib.error
import urllib.request

from dashboard.lib.security import (
    LOOPBACK_URL_RE,
    PathSanitizer,
    _norm_path_key,
    assert_plain_path_no_reparse,
    is_reparse_or_symlink,
)


ALLOWED_ENVIRONMENTS = ("work", "full", "minimal")

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
    """Return current UTC timestamp in ISO-8601 format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def extract_json_payload(raw_text: str) -> Any | None:
    """Extract the first valid JSON object/array from potentially noisy CLI stdout."""
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


def categorize_repo_path(rel_path: str) -> str:
    """Map a repo-relative path to a dashboard change category."""
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


def status_code_to_zh(code: str) -> str:
    """Translate a git porcelain status code to Chinese."""
    cleaned = code.strip()
    if cleaned == "??":
        return STATUS_CODE_ZH["??"]
    if not cleaned:
        return "已变更"
    for ch in cleaned:
        if ch in STATUS_CODE_ZH:
            return STATUS_CODE_ZH[ch]
    return "已变更"


def parse_frontmatter(text: str) -> dict[str, str]:
    """Parse minimal YAML frontmatter from SKILL.md."""
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


def extract_psd1_array(text: str, key_pattern: str) -> list[str]:
    """Extract string array values for a key in a PowerShell .psd1 file."""
    m = re.search(key_pattern + r"\s*=\s*@\((.*?)\)", text, flags=re.DOTALL)
    if not m:
        return []
    return re.findall(r"['\"]([^'\"]+)['\"]", m.group(1))


def extract_psd1_string(text: str, key_name: str) -> str:
    """Extract a scalar string value for a key in a PowerShell .psd1 file."""
    m = re.search(rf"\b{re.escape(key_name)}\s*=\s*'([^']*)'", text)
    if m:
        return m.group(1)
    m = re.search(rf'\b{re.escape(key_name)}\s*=\s*"([^"]*)"', text)
    return m.group(1) if m else ""


def collect_repo_overview(
    repo_root: Path,
    sanitizer: PathSanitizer,
    run_git: Callable[[list[str], float], Any],
) -> dict[str, Any]:
    """Collect git status, grouped file changes, and recent commits."""
    status_res = run_git(
        ["status", "--porcelain=v1", "--branch", "--untracked-files=all"],
        2.0,
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
            cat_id = categorize_repo_path(rel_path)
            grouped[cat_id].append({
                "path": sanitizer.sanitize_str(rel_path),
                "code": code.strip() or code,
                "status_zh": status_code_to_zh(code),
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

    log_res = run_git(
        ["log", "-n", "8", "--format=%h%x1f%s%x1f%cI%x1f%cr"],
        2.0,
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
            subj_clean = sanitizer.sanitize_str(c_subj)
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
        "name": repo_root.name,
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


def collect_status_doc(repo_root: Path, sanitizer: PathSanitizer) -> dict[str, Any]:
    """Parse STATUS.md open items and status/active/ records."""
    last_updated = ""
    open_items: list[dict[str, str]] = []
    status_path = repo_root / "STATUS.md"
    if status_path.is_file() and not is_reparse_or_symlink(status_path):
        try:
            text = status_path.read_text(encoding="utf-8", errors="replace")
            m = re.search(r"^Last updated:\s*(.+)$", text, flags=re.MULTILINE)
            if m:
                last_updated = m.group(1).strip().rstrip(".")
            sec_m = re.search(
                r"^##\s+Open items\s*\r?\n(.*?)(?=^##\s+|\Z)",
                text,
                flags=re.MULTILINE | re.DOTALL,
            )
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
                        "title": sanitizer.sanitize_str(title),
                        "summary": sanitizer.sanitize_str(summary),
                    })
        except OSError:
            pass

    active_tasks: list[dict[str, str]] = []
    active_dir = repo_root / "status" / "active"
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
                "title": sanitizer.sanitize_str(title),
                "excerpt": sanitizer.sanitize_str(excerpt),
            })

    return {
        "last_updated": sanitizer.sanitize_str(last_updated),
        "open_items": open_items,
        "active_tasks": active_tasks,
    }


def _stat_token(path: Path) -> tuple[int, int] | None:
    if is_reparse_or_symlink(path):
        return (-1, -1)
    try:
        st = path.stat()
    except OSError:
        return None
    return (int(st.st_mtime_ns), int(st.st_size))


class SkillsCatalogCache:
    """Thread-safe mtime/entry-fingerprint cache for skills_catalog."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._fingerprint: tuple[Any, ...] | None = None
        self._catalog: dict[str, Any] | None = None
        self.hits = 0
        self.misses = 0

    @staticmethod
    def compute_fingerprint(repo_root: Path) -> tuple[Any, ...]:
        env_dir = repo_root / "harness-source" / "envs"
        env_tokens: list[tuple[str, tuple[int, int] | None]] = []
        if env_dir.is_dir() and not is_reparse_or_symlink(env_dir):
            for ef in sorted(env_dir.glob("*.psd1"), key=lambda p: p.name):
                env_tokens.append((ef.name, _stat_token(ef)))

        plugins_psd1 = repo_root / "harness-source" / "antigravity" / "plugins.psd1"
        plugins_token = _stat_token(plugins_psd1)

        skill_tokens: list[tuple[str, tuple[int, int] | None, list[tuple[str, tuple[int, int] | None, tuple[int, int] | None]]]] = []
        for scope in ("shared", "codex-only"):
            scope_dir = repo_root / "skills-source" / scope
            entries: list[tuple[str, tuple[int, int] | None, tuple[int, int] | None]] = []
            if scope_dir.is_dir() and not is_reparse_or_symlink(scope_dir):
                for item in sorted(scope_dir.iterdir(), key=lambda p: p.name):
                    if not item.is_dir() or is_reparse_or_symlink(item):
                        continue
                    entries.append((item.name, _stat_token(item), _stat_token(item / "SKILL.md")))
            skill_tokens.append((scope, _stat_token(scope_dir), entries))

        return (tuple(env_tokens), plugins_token, tuple(skill_tokens))

    def get_or_collect(self, repo_root: Path, sanitizer: PathSanitizer) -> dict[str, Any]:
        fp = self.compute_fingerprint(repo_root)
        with self._lock:
            if self._catalog is not None and self._fingerprint == fp:
                self.hits += 1
                return self._catalog
        catalog = collect_skills_catalog_uncached(repo_root, sanitizer)
        with self._lock:
            self._fingerprint = fp
            self._catalog = catalog
            self.misses += 1
        return catalog


def collect_skills_catalog_uncached(repo_root: Path, sanitizer: PathSanitizer) -> dict[str, Any]:
    """Read environment manifests, Antigravity plugin selection, and skill frontmatter."""
    env_dir = repo_root / "harness-source" / "envs"
    environments: list[dict[str, Any]] = []
    env_skills_map: dict[str, set[str]] = {}
    if env_dir.is_dir() and not is_reparse_or_symlink(env_dir):
        env_files = sorted(
            env_dir.glob("*.psd1"),
            key=lambda p: (ALLOWED_ENVIRONMENTS.index(p.stem) if p.stem in ALLOWED_ENVIRONMENTS else 99, p.stem),
        )
        for ef in env_files:
            if is_reparse_or_symlink(ef) or not ef.is_file():
                continue
            try:
                text = ef.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            desc = extract_psd1_string(text, "Description")
            codex_skills = extract_psd1_array(text, r"\bCodex")
            env_skills_map[ef.stem] = set(codex_skills)
            environments.append({
                "name": ef.stem,
                "description": sanitizer.sanitize_str(desc),
                "count": len(codex_skills),
                "skills": codex_skills,
            })

    ag_plugin_skills: set[str] = set()
    plugins_psd1 = repo_root / "harness-source" / "antigravity" / "plugins.psd1"
    if plugins_psd1.is_file() and not is_reparse_or_symlink(plugins_psd1):
        try:
            p_text = plugins_psd1.read_text(encoding="utf-8", errors="replace")
            ag_plugin_skills = set(extract_psd1_array(p_text, r"\bSkills"))
        except OSError:
            pass

    skills: list[dict[str, Any]] = []
    shared_count = 0
    codex_only_count = 0
    for scope, scope_zh in (("shared", "双端共享"), ("codex-only", "Codex 专用")):
        scope_dir = repo_root / "skills-source" / scope
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
            fm = parse_frontmatter(content)
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
                "description": sanitizer.sanitize_str(desc),
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


def probe_board_manifest(manifest_path: Path, sanitizer: PathSanitizer) -> dict[str, Any]:
    """Read a swarm/teamwork manifest and probe its loopback board server if present."""
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
        "run": sanitizer.sanitize_str(run_name),
        "manifest_path_display": sanitizer.sanitize_str(os.fspath(manifest_path)),
        "url": url,
        "running": running,
        "event_count": event_count,
        "ui_gets": ui_gets,
        "state_polls": state_polls,
    }


def collect_swarm_boards(
    repo_root: Path,
    watched_manifests: list[Path],
    sanitizer: PathSanitizer,
) -> dict[str, Any]:
    """Scan tmp/ (bounded depth) plus explicitly watched manifests for board instances."""
    candidates: list[Path] = []
    seen: set[str] = set()

    def _add_candidate(p: Path) -> None:
        key = _norm_path_key(p)
        if key not in seen:
            seen.add(key)
            candidates.append(p)

    tmp_root = repo_root / "tmp"
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

    for p in watched_manifests:
        if p.is_file() and not is_reparse_or_symlink(p):
            _add_candidate(p)

    return {"boards": [probe_board_manifest(p, sanitizer) for p in candidates]}


def collect_github_status(
    repo_root: Path,
    sanitizer: PathSanitizer,
    runner: Callable[..., Any],
) -> dict[str, Any]:
    """Query open PRs and recent workflow runs via gh CLI, gracefully falling back offline."""
    offline_res = {
        "available": False,
        "offline": True,
        "message_zh": "当前离线或无法连接 GitHub（不影响本地监控）",
        "open_prs": [],
        "ci_runs": [],
    }
    gh_exe = shutil.which("gh")
    if not gh_exe:
        return offline_res

    pr_res = runner(
        [gh_exe, "pr", "list", "--state", "open", "--limit", "10", "--json", "number,title,headRefName,url,updatedAt"],
        cwd=repo_root,
        timeout=8.0,
    )
    run_res = runner(
        [gh_exe, "run", "list", "--limit", "8", "--json", "databaseId,workflowName,status,conclusion,headBranch,displayTitle,url,createdAt"],
        cwd=repo_root,
        timeout=8.0,
    )
    if pr_res.exit_code != 0 or run_res.exit_code != 0:
        return offline_res

    try:
        prs = json.loads(pr_res.stdout or "[]")
        runs = json.loads(run_res.stdout or "[]")
        if not isinstance(prs, list) or not isinstance(runs, list):
            raise ValueError("unexpected GitHub JSON shape")
    except (ValueError, json.JSONDecodeError):
        return offline_res

    return {
        "available": True,
        "offline": False,
        "message_zh": "已连接 GitHub",
        "open_prs": sanitizer.sanitize_value(prs),
        "ci_runs": sanitizer.sanitize_value(runs),
    }


def compute_attention(
    repo: dict[str, Any],
    status_doc: dict[str, Any],
    sync_cached: dict[str, Any] | None,
    gh_cached: dict[str, Any] | None,
    sanitizer: PathSanitizer,
) -> list[dict[str, Any]]:
    """Prioritize actionable attention cards from sync drift, CI failures, dirty workspace, and active tasks."""
    cards: list[dict[str, Any]] = []

    if sync_cached is not None:
        lvl = sync_cached.get("summary_level")
        if lvl in ("warn", "error"):
            cards.append({
                "level": lvl,
                "title": "双端配置存在差异或异常" if lvl == "warn" else "双端状态检查报错",
                "detail": sanitizer.sanitize_str(str(sync_cached.get("summary_zh") or "请先运行预览或体检排查。")),
                "action_type": "preview" if lvl == "warn" else "doctor",
                "action_label": "前往同步预览" if lvl == "warn" else "运行健康体检",
                "ai_prompt": sanitizer.sanitize_str(
                    f"请帮我分析 ai-agent-dotfiles 当前双端同步状态（{sync_cached.get('summary_zh', '')}），判断是否需要执行同步并给出最小安全操作。"
                ),
            })

    if gh_cached and gh_cached.get("available"):
        latest_by_branch: dict[str, dict[str, Any]] = {}
        for run in gh_cached.get("ci_runs", []):
            if not isinstance(run, dict):
                continue
            branch_name = str(run.get("headBranch") or "")
            existing = latest_by_branch.get(branch_name)
            if existing is None:
                latest_by_branch[branch_name] = run
            else:
                new_ts = str(run.get("createdAt") or "")
                old_ts = str(existing.get("createdAt") or "")
                if new_ts and (not old_ts or new_ts > old_ts):
                    latest_by_branch[branch_name] = run

        current_branch = str(repo.get("branch") or "")
        ordered_branches: list[str] = []
        for priority_branch in (current_branch, "main"):
            if priority_branch and priority_branch in latest_by_branch and priority_branch not in ordered_branches:
                ordered_branches.append(priority_branch)
        for branch_name in latest_by_branch:
            if branch_name not in ordered_branches:
                ordered_branches.append(branch_name)

        for branch_name in ordered_branches:
            run = latest_by_branch[branch_name]
            conclusion = (run.get("conclusion") or "").lower()
            if conclusion in ("failure", "timed_out", "cancelled"):
                cards.append({
                    "level": "error",
                    "title": f"GitHub CI 失败：{run.get('workflowName', 'Validate')}",
                    "detail": sanitizer.sanitize_str(
                        f"分支 {run.get('headBranch', '')} 提交「{run.get('displayTitle', '')}」结果为 {conclusion}。"
                    ),
                    "action_type": "ai",
                    "action_label": "复制给 AI 排查 CI",
                    "ai_prompt": sanitizer.sanitize_str(
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
            "ai_prompt": sanitizer.sanitize_str(
                f"请帮我复核当前仓库（分支 {repo.get('branch', '')}）中的 {n} 项未提交改动，运行必要校验后准备小步提交。"
            ),
        })

    active_tasks = status_doc.get("active_tasks") or []
    if active_tasks:
        titles = "、".join(t.get("file", "") for t in active_tasks[:3])
        cards.append({
            "level": "warn",
            "title": f"有 {len(active_tasks)} 个进行中的任务记录",
            "detail": sanitizer.sanitize_str(f"status/active/ 中存在：{titles}"),
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
