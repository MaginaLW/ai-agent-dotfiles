"""Sync status parsing, workspace fingerprinting, and preview command/output handling."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import shutil
import time
from typing import Any, Callable
import uuid

from dashboard.lib.collectors import (
    ACTION_ZH_MAP,
    ALLOWED_ENVIRONMENTS,
    extract_json_payload,
    utc_now_iso,
)
from dashboard.lib.security import (
    PathSanitizer,
    is_reparse_or_symlink,
    resolve_repo_relative_file,
)


ALLOWED_SYNC_TARGETS = frozenset({
    "codex-env",
    "codex-skills",
    "antigravity-config",
    "antigravity-plugin",
    "mcp",
})


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
    workspace_fingerprint: str = ""
    consumed: bool = False


def is_managed_source_path(rel_path: str) -> bool:
    """Return True if a repo-relative path belongs to managed sync sources (not generated outputs)."""
    norm = rel_path.replace("\\", "/").lstrip("/")
    if norm == "codex/skills" or norm.startswith("codex/skills/") or norm == "manifests/managed-skills.codex.txt":
        return False
    if norm in ("manifests/whitelist.psd1", ".gitleaks.toml"):
        return True
    return norm.startswith(("skills-source/", "codex/", "antigravity/", "harness-source/"))


def compute_managed_workspace_fingerprint(
    repo_root: Path,
    head_sha: str,
    run_git: Callable[[list[str], float], Any],
) -> str:
    """Compute a SHA-256 fingerprint of HEAD plus dirty managed source file contents."""
    status_res = run_git(
        ["status", "--porcelain=v1", "--untracked-files=all"],
        2.0,
    )
    hasher = hashlib.sha256()
    hasher.update(f"HEAD:{head_sha}\n".encode("utf-8"))
    if status_res.exit_code != 0:
        hasher.update(f"STATUS_ERR:{status_res.exit_code}\n".encode("utf-8"))
        return hasher.hexdigest()

    matched: list[tuple[str, str]] = []
    for line in status_res.stdout.splitlines():
        if len(line) < 4:
            continue
        code = line[:2]
        raw_path = line[3:].strip()
        if " -> " in raw_path:
            raw_path = raw_path.split(" -> ", 1)[1].strip()
        if raw_path.startswith('"') and raw_path.endswith('"'):
            raw_path = raw_path[1:-1]
        norm_path = raw_path.replace("\\", "/")
        if not is_managed_source_path(norm_path):
            continue
        matched.append((norm_path, code))

    for norm_path, code in sorted(matched):
        digest = "missing"
        try:
            _, abs_path = resolve_repo_relative_file(repo_root, norm_path)
            if is_reparse_or_symlink(abs_path):
                digest = "reparse"
            elif abs_path.is_dir():
                digest = "dir"
            elif abs_path.is_file():
                file_hash = hashlib.sha256()
                with abs_path.open("rb") as fh:
                    while True:
                        chunk = fh.read(65536)
                        if not chunk:
                            break
                        file_hash.update(chunk)
                digest = file_hash.hexdigest()
        except (OSError, ValueError):
            digest = "reparse"
        hasher.update(f"{code}\t{norm_path}\t{digest}\n".encode("utf-8"))
    return hasher.hexdigest()


def build_sync_command(
    repo_root: Path,
    home_root: Path | None,
    state_root: Path | None,
    target: str,
    environment: str,
    *,
    apply_mode: bool,
) -> tuple[str, list[str]]:
    """Build pwsh command argv for preview (-DryRun/-Json) or apply (-Apply)."""
    if target not in ALLOWED_SYNC_TARGETS:
        raise ValueError(f"unsupported sync target: {target}")
    if environment not in ALLOWED_ENVIRONMENTS:
        raise ValueError(f"unsupported environment: {environment}")
    pwsh = shutil.which("pwsh") or "pwsh"
    scripts_dir = repo_root / "scripts"
    repo_str = os.fspath(repo_root)
    mode_flag = "-Apply" if apply_mode else "-DryRun"
    mode_zh = "写入" if apply_mode else "预览"

    if target == "codex-env":
        argv = [
            pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "agent-dotfiles.ps1"),
            "env", "deploy", environment, mode_flag, "-RepoRoot", repo_str,
        ]
        if home_root is not None:
            argv.extend(["-HomeRoot", os.fspath(home_root)])
            argv.extend(["-BackupRoot", os.fspath(home_root / ".ai-agent-dotfiles-backups")])
        if state_root is not None:
            argv.extend(["-StateRoot", os.fspath(state_root)])
        return f"{mode_zh} Codex 完整同步 ({environment})", argv

    if target == "codex-skills":
        argv = [
            pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "deploy-skills.ps1"),
            "-Environment", environment, "-RepoRoot", repo_str,
        ]
        if apply_mode:
            argv.append("-Apply")
        else:
            argv.append("-Json")
        if home_root is not None:
            argv.extend(["-HomeRoot", os.fspath(home_root)])
        if state_root is not None:
            argv.extend(["-StateRoot", os.fspath(state_root)])
        return f"{mode_zh} Codex 技能同步 ({environment})", argv

    if target == "antigravity-config":
        argv = [
            pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "agent-dotfiles.ps1"),
            "config", "pull", "-Platform", "Antigravity", mode_flag, "-RepoRoot", repo_str,
        ]
        if not apply_mode:
            argv.append("-Json")
        if home_root is not None:
            argv.extend(["-HomeRoot", os.fspath(home_root)])
            argv.extend(["-BackupRoot", os.fspath(home_root / ".ai-agent-dotfiles-backups")])
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
    if not apply_mode:
        argv.append("-Json")
    if home_root is not None:
        argv.extend(["-HomeRoot", os.fspath(home_root)])
        argv.extend(["-BackupRoot", os.fspath(home_root / ".ai-agent-dotfiles-backups")])
    return f"{mode_zh}受管 MCP 服务同步", argv


def parse_sync_status_payload(
    res: Any,
    sanitizer: PathSanitizer,
) -> dict[str, Any]:
    """Parse `agent-dotfiles.ps1 status -Json` output into normalized dashboard sync state."""
    combined_raw = "\n".join(part for part in (res.stdout, res.stderr, res.error or "") if part)
    raw_sanitized = sanitizer.sanitize_str(combined_raw)
    parsed = extract_json_payload(res.stdout)
    fetched_at = utc_now_iso()

    if not isinstance(parsed, dict):
        return {
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
            "error": sanitizer.sanitize_str(res.error or "status -Json 未返回有效 JSON"),
        }

    sanitized_report = sanitizer.sanitize_value(parsed)
    env_raw = sanitized_report.get("Environment") or {}
    cfg_raw = sanitized_report.get("Config")
    ag_raw = sanitized_report.get("Antigravity") or {}
    mcp_raw = sanitized_report.get("Mcp") or {}
    skills_raw = sanitized_report.get("Skills")
    summary_raw = sanitized_report.get("Summary") or {}

    recorded_env = env_raw.get("Recorded") or "unavailable"
    env_failed = bool(env_raw.get("Failed"))
    env_summary_zh = (
        "未检测到技能部署记录" if recorded_env == "unavailable" else f"上次记录环境：{recorded_env}"
    )

    skills_obj: dict[str, Any] | None = None
    skills_has_error = False
    skills_has_drift = False
    if isinstance(skills_raw, dict):
        sk_state = str(skills_raw.get("State") or "unavailable")
        sk_env = str(skills_raw.get("Environment") or recorded_env or "unavailable")
        sk_live_root = skills_raw.get("LiveRoot")
        sk_summary = skills_raw.get("Summary") if isinstance(skills_raw.get("Summary"), dict) else None
        sk_error = skills_raw.get("Error")
        inst = int(sk_summary.get("install", 0)) if sk_summary else 0
        upd = int(sk_summary.get("update", 0)) if sk_summary else 0
        unch = int(sk_summary.get("unchanged", 0)) if sk_summary else 0
        prn = int(sk_summary.get("prune", 0)) if sk_summary else 0
        unk = int(sk_summary.get("unknown", 0)) if sk_summary else 0
        pending = inst + upd + prn
        total_selected = inst + upd + unch

        if sk_state == "error" or sk_error:
            skills_has_error = True
            skills_summary_zh = f"技能状态异常：{sk_error or sk_state}"
        elif sk_state == "build-required":
            skills_has_drift = True
            skills_summary_zh = "需先构建技能目录 (build-skills)"
        elif sk_state == "unavailable":
            skills_summary_zh = "未检测到 Codex 技能实时部署"
        elif sk_state == "checked" and sk_summary is not None:
            if pending > 0:
                skills_has_drift = True
                parts: list[str] = []
                if inst:
                    parts.append(f"新增 {inst}")
                if upd:
                    parts.append(f"更新 {upd}")
                if prn:
                    parts.append(f"清理 {prn}")
                skills_summary_zh = f"待同步（{unch}/{total_selected} 一致；" + "、".join(parts) + "）"
            else:
                skills_summary_zh = f"{unch}/{total_selected} 一致"
                if unk > 0:
                    skills_summary_zh += f"（另有 {unk} 个未托管目录保留）"
        else:
            skills_summary_zh = f"技能状态：{sk_state}"

        skills_obj = {
            "environment": sk_env,
            "state": sk_state,
            "live_root": sk_live_root,
            "summary": sk_summary,
            "error": sk_error,
            "summary_zh": skills_summary_zh,
            "pending_count": pending,
            "total_selected": total_selected,
            "unchanged_count": unch,
        }

    cfg_items = cfg_raw if isinstance(cfg_raw, list) else []
    cfg_summary = summary_raw.get("Config") if isinstance(summary_raw, dict) else None
    if isinstance(cfg_summary, dict):
        cfg_differs = int(cfg_summary.get("differs", 0) + cfg_summary.get("repo-only", 0))
        cfg_home_only = int(cfg_summary.get("home-only", 0))
    else:
        cfg_differs = sum(1 for it in cfg_items if isinstance(it, dict) and it.get("Status") in ("differs", "repo-only"))
        cfg_home_only = sum(1 for it in cfg_items if isinstance(it, dict) and it.get("Status") == "home-only")
    if isinstance(cfg_raw, dict) and cfg_raw.get("Error"):
        cfg_summary_zh = f"配置检查出错：{cfg_raw.get('Error')}"
    elif cfg_differs > 0:
        cfg_summary_zh = f"有 {cfg_differs} 项受管规则与仓库存在差异"
        if cfg_home_only > 0:
            cfg_summary_zh += f"（另有 {cfg_home_only} 项仅本机存在）"
    elif cfg_home_only > 0:
        cfg_summary_zh = f"受管规则已对齐（另有 {cfg_home_only} 项仅本机存在）"
    else:
        cfg_summary_zh = "Codex 与 Antigravity 全局规则均已对齐"

    ag_action = str(ag_raw.get("Action") or summary_raw.get("Antigravity") or "unavailable")
    ag_req = ag_raw.get("ApplyRequirement")
    ag_externals = ag_raw.get("ExternalExpectations") if isinstance(ag_raw.get("ExternalExpectations"), list) else []
    ext_blocked = 0
    ext_drift = 0
    for ext in ag_externals:
        if not isinstance(ext, dict):
            continue
        ext_state = str(ext.get("State") or "")
        ext_act = str(ext.get("Action") or "")
        if ext_state != "unchanged" and (ext_state == "blocked" or ext_act == "blocked"):
            ext_blocked += 1
        if ext_state in ("missing", "different"):
            ext_drift += 1

    if ag_raw.get("Error"):
        ag_summary_zh = f"插件状态异常：{ag_raw.get('Error')}"
    else:
        if ag_action == "unchanged":
            ag_summary_zh = f"自有插件 v{ag_raw.get('Version', '?')} 已安装且一致"
        elif ag_action == "update" and ag_req == "build-with-current-agy-before-apply":
            ag_summary_zh = "插件有新版本，需先使用当前 agy 重新打包后再部署"
        elif ag_action in ("install", "update"):
            ag_summary_zh = f"自有插件可执行{ACTION_ZH_MAP.get(ag_action, ag_action)}"
        else:
            ag_summary_zh = f"插件状态：{ag_raw.get('Reason') or ag_action}"
        ext_notes: list[str] = []
        if ext_blocked > 0:
            ext_notes.append(f"{ext_blocked} 个外部插件受阻")
        if ext_drift > 0:
            ext_notes.append(f"{ext_drift} 个外部插件存在差异/缺失")
        if ext_notes:
            ag_summary_zh += "；" + "、".join(ext_notes)

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

    has_error = res.exit_code != 0 or env_failed or skills_has_error or bool(
        (isinstance(cfg_raw, dict) and cfg_raw.get("Error"))
        or ag_raw.get("Error")
        or (isinstance(mcp_raw, dict) and mcp_raw.get("Error"))
    )
    has_blocked = (
        ag_action == "blocked"
        or ag_req == "build-with-current-agy-before-apply"
        or ext_blocked > 0
        or (isinstance(mcp_summary, dict) and int(mcp_summary.get("blocked", 0)) > 0)
    )
    has_drift = (
        skills_has_drift
        or cfg_differs > 0
        or ag_action in ("install", "update")
        or ext_drift > 0
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
        summary_zh = "双端技能、规则、插件与受管 MCP 均已同步" if skills_obj is not None else "双端规则、插件与受管 MCP 均已同步"

    result: dict[str, Any] = {
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
        "attention": [],
        "raw_sanitized": raw_sanitized,
        "error": None if res.exit_code == 0 else sanitizer.sanitize_str(res.error or f"status exited with {res.exit_code}"),
    }
    if skills_obj is not None:
        result["skills"] = skills_obj
    return result


def _format_file_changes_detail(changes: list[tuple[str, str]]) -> str:
    total = len(changes)
    preview_parts = [f"{act} {rel}" for act, rel in changes[:4]]
    detail = f"变更 {total} 项：" + ", ".join(preview_parts)
    if total > 4:
        detail += f" 等共 {total} 项"
    return detail


def _parse_antigravity_plugin_json(
    parsed: dict[str, Any],
    sanitizer: PathSanitizer,
) -> tuple[list[dict[str, str]], bool, bool]:
    s_parsed = sanitizer.sanitize_value(parsed)
    items: list[dict[str, str]] = []
    has_blocked = False
    has_changes = False

    action = str(s_parsed.get("Action") or "blocked")
    reason = str(s_parsed.get("Reason") or "")
    req = str(s_parsed.get("ApplyRequirement") or "")
    name = str(s_parsed.get("Name") or "ai-agent-dotfiles")
    version = str(s_parsed.get("Version") or "").strip()
    if action == "blocked" or req == "build-with-current-agy-before-apply":
        has_blocked = True
    if action in ("install", "update"):
        has_changes = True

    detail_parts: list[str] = []
    if version:
        detail_parts.append(f"v{version}")
    if reason:
        detail_parts.append(reason)
    if req and req != "none":
        detail_parts.append(f"({req})")
    changes = s_parsed.get("Changes")
    if isinstance(changes, dict):
        added = len(changes.get("Added") or []) if isinstance(changes.get("Added"), list) else 0
        changed = len(changes.get("Changed") or []) if isinstance(changes.get("Changed"), list) else 0
        removed = len(changes.get("Removed") or []) if isinstance(changes.get("Removed"), list) else 0
        change_parts: list[str] = []
        if added:
            change_parts.append(f"新增 {added}")
        if changed:
            change_parts.append(f"修改 {changed}")
        if removed:
            change_parts.append(f"移除 {removed}")
        if change_parts:
            detail_parts.append("文件变更：" + " / ".join(change_parts))

    items.append({
        "action": action,
        "action_zh": ACTION_ZH_MAP.get(action, action),
        "name": name,
        "detail": " · ".join(detail_parts),
    })

    externals = s_parsed.get("ExternalExpectations")
    if isinstance(externals, list):
        for ext in externals:
            if not isinstance(ext, dict):
                continue
            ext_name = str(ext.get("Name") or "unknown")
            ext_state = str(ext.get("State") or "")
            ext_act = str(ext.get("Action") or ext_state or "unknown")
            ext_reason = str(ext.get("Reason") or "")
            ext_detail_parts = []
            if ext_state:
                ext_detail_parts.append(f"状态 {ext_state}")
            if ext_reason:
                ext_detail_parts.append(ext_reason)
            items.append({
                "action": ext_act,
                "action_zh": f"只读（{ACTION_ZH_MAP.get(ext_act, ext_act)}）",
                "name": f"外部插件/{ext_name}",
                "detail": " · ".join(ext_detail_parts),
            })
    return items, has_blocked, has_changes


def _parse_codex_skills_json(
    parsed: dict[str, Any],
    sanitizer: PathSanitizer,
) -> tuple[list[dict[str, str]], bool, bool, list[str], bool]:
    s_parsed = sanitizer.sanitize_value(parsed)
    items: list[dict[str, str]] = []
    has_prune = False
    has_changes = False
    unrecorded_updates: list[str] = []
    has_interrupted_remnants = False

    raw_items = s_parsed.get("Items") if isinstance(s_parsed.get("Items"), list) else []
    for it in raw_items:
        if not isinstance(it, dict):
            continue
        plat = str(it.get("Platform") or "Codex")
        name = str(it.get("Name") or "")
        act = str(it.get("Action") or "unchanged")
        reason = it.get("Reason")
        if act in ("install", "update", "prune"):
            has_changes = True
        if act == "prune":
            has_prune = True

        raw_fc = it.get("FileChanges") if isinstance(it.get("FileChanges"), list) else []
        file_changes: list[tuple[str, str]] = []
        for fc in raw_fc:
            if isinstance(fc, dict):
                fc_act = str(fc.get("Action") or "change")
                fc_path = str(fc.get("Path") or "")
                if fc_path:
                    file_changes.append((fc_act, fc_path))

        if file_changes:
            detail = _format_file_changes_detail(file_changes)
        elif reason:
            detail = str(reason)
        else:
            detail = "内容一致" if act == "unchanged" else "技能目录变更"

        items.append({
            "action": act,
            "action_zh": ACTION_ZH_MAP.get(act, act),
            "name": f"{plat}/{name}" if name else plat,
            "detail": detail,
        })

    summary = s_parsed.get("Summary")
    if isinstance(summary, dict):
        if int(summary.get("prune", 0)) > 0:
            has_prune = True
            has_changes = True
        if int(summary.get("install", 0)) + int(summary.get("update", 0)) > 0:
            has_changes = True

    raw_unrec = s_parsed.get("UnrecordedUpdates")
    if isinstance(raw_unrec, list):
        unrecorded_updates = [str(x) for x in raw_unrec if x]

    raw_remnants = s_parsed.get("InterruptedRemnants")
    if isinstance(raw_remnants, list) and len(raw_remnants) > 0:
        has_interrupted_remnants = True

    return items, has_prune, has_changes, unrecorded_updates, has_interrupted_remnants


def _parse_antigravity_config_json(
    parsed: dict[str, Any],
    sanitizer: PathSanitizer,
) -> tuple[list[dict[str, str]], bool, bool]:
    s_parsed = sanitizer.sanitize_value(parsed)
    items: list[dict[str, str]] = []
    has_blocked = False
    has_changes = False

    raw_items = s_parsed.get("Items") if isinstance(s_parsed.get("Items"), list) else []
    for it in raw_items:
        if not isinstance(it, dict):
            continue
        rel = str(it.get("Rel") or "")
        act = str(it.get("Action") or "unchanged")
        managed_only = bool(it.get("ManagedBlockOnly"))
        mode = str(it.get("Mode") or "")
        if act in ("add", "update"):
            has_changes = True
        if act == "blocked":
            has_blocked = True
        if managed_only or "AGENTS.md" in rel:
            detail = "受管配置更新（保留块外个人内容）"
        elif mode:
            detail = f"配置文件复制 ({mode})"
        else:
            detail = "配置文件复制"
        items.append({
            "action": act,
            "action_zh": ACTION_ZH_MAP.get(act, act),
            "name": rel,
            "detail": detail,
        })

    summary = s_parsed.get("Summary")
    if isinstance(summary, dict):
        if int(summary.get("blocked", 0)) > 0:
            has_blocked = True
        if int(summary.get("add", 0)) + int(summary.get("update", 0)) > 0:
            has_changes = True
    return items, has_blocked, has_changes


def _parse_mcp_json(
    parsed: dict[str, Any],
    sanitizer: PathSanitizer,
) -> tuple[list[dict[str, str]], bool, bool]:
    s_parsed = sanitizer.sanitize_value(parsed)
    items: list[dict[str, str]] = []
    has_blocked = False
    has_changes = False

    raw_items = s_parsed.get("Items") if isinstance(s_parsed.get("Items"), list) else []
    for it in raw_items:
        if not isinstance(it, dict):
            continue
        plat = str(it.get("Platform") or "")
        srv = str(it.get("Server") or "")
        act = str(it.get("Action") or "unchanged")
        reason = str(it.get("Reason") or "")
        changes = it.get("Changes")
        if act in ("add", "update"):
            has_changes = True
        if act == "blocked":
            has_blocked = True
        detail = reason
        if isinstance(changes, list) and changes:
            diff_preview = ", ".join(str(c) for c in changes[:3])
            detail = f"{reason} ({diff_preview})" if reason else diff_preview
        items.append({
            "action": act,
            "action_zh": ACTION_ZH_MAP.get(act, act),
            "name": f"{plat}/{srv}" if plat and srv else (srv or plat),
            "detail": detail,
        })

    summary = s_parsed.get("Summary")
    if isinstance(summary, dict):
        if int(summary.get("blocked", 0)) > 0:
            has_blocked = True
        if int(summary.get("add", 0)) + int(summary.get("update", 0)) > 0:
            has_changes = True
    return items, has_blocked, has_changes


def _parse_legacy_text_preview(
    output_sanitized: str,
) -> tuple[list[dict[str, str]], bool, bool, bool, list[str], bool]:
    items: list[dict[str, str]] = []
    has_prune = False
    has_blocked = False
    has_changes = False
    unrecorded_updates: list[str] = []
    has_interrupted_remnants = False

    skill_file_changes: dict[str, list[tuple[str, str]]] = {}
    current_skill_name: str | None = None
    for line in output_sanitized.splitlines():
        stripped = line.strip()

        fhm = re.match(r"^File changes for (Codex/\S+):$", stripped)
        if fhm:
            current_skill_name = fhm.group(1)
            skill_file_changes.setdefault(current_skill_name, [])
            continue

        if current_skill_name is not None:
            fcm = re.match(r"^\s{2}(add|change|remove)\s+(\S.*)$", line)
            if fcm:
                skill_file_changes[current_skill_name].append((fcm.group(1), fcm.group(2).strip()))
                continue
            current_skill_name = None

        if stripped.startswith("Update not recorded in deploy state:"):
            unrecorded_updates.append(stripped)
            continue
        if "Possible interrupted deployment remnants" in stripped:
            has_interrupted_remnants = True
            continue

        sm = re.match(r"^(Codex)\s+(install|update|unchanged|prune|unknown)\s+(\S+)$", stripped)
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

    for item in items:
        changes = skill_file_changes.get(item["name"])
        if changes:
            item["detail"] = _format_file_changes_detail(changes)

    return items, has_prune, has_blocked, has_changes, unrecorded_updates, has_interrupted_remnants


def parse_preview_output(
    target: str,
    environment: str,
    res: Any,
    output_sanitized: str,
    repo_head_sha: str,
    sanitizer: PathSanitizer,
    workspace_fingerprint: str = "",
) -> tuple[dict[str, Any], PreviewRecord]:
    """Parse structured JSON (or legacy text fallback) preview output and create a PreviewRecord."""
    items: list[dict[str, str]] = []
    has_prune = False
    has_blocked = False
    has_changes = False
    unrecorded_updates: list[str] = []
    has_interrupted_remnants = False

    lowered = output_sanitized.lower()
    if "build-with-current-agy-before-apply" in lowered or "preflight failed" in lowered:
        has_blocked = True
    if re.search(r"Deploy blockers:\s*[1-9]\d*", output_sanitized):
        has_blocked = True

    parsed = extract_json_payload(res.stdout) if target in (
        "antigravity-plugin",
        "codex-skills",
        "antigravity-config",
        "mcp",
    ) else None

    if target == "antigravity-plugin":
        if isinstance(parsed, dict):
            items, parsed_blocked, has_changes = _parse_antigravity_plugin_json(parsed, sanitizer)
            has_blocked = has_blocked or parsed_blocked
        else:
            has_blocked = True
    elif target == "codex-skills" and isinstance(parsed, dict) and ("Items" in parsed or "Summary" in parsed):
        items, has_prune, has_changes, unrecorded_updates, has_interrupted_remnants = _parse_codex_skills_json(
            parsed,
            sanitizer,
        )
    elif target == "antigravity-config" and isinstance(parsed, dict) and ("Items" in parsed or "Summary" in parsed):
        items, parsed_blocked, has_changes = _parse_antigravity_config_json(parsed, sanitizer)
        has_blocked = has_blocked or parsed_blocked
    elif target == "mcp" and isinstance(parsed, dict) and ("Items" in parsed or "Summary" in parsed):
        items, parsed_blocked, has_changes = _parse_mcp_json(parsed, sanitizer)
        has_blocked = has_blocked or parsed_blocked
    else:
        (
            items,
            has_prune,
            text_blocked,
            has_changes,
            unrecorded_updates,
            has_interrupted_remnants,
        ) = _parse_legacy_text_preview(output_sanitized)
        has_blocked = has_blocked or text_blocked

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
    if unrecorded_updates:
        risk_notice_zh += " 注意：部分待更新目录未记录在部署状态中（覆盖前将自动备份，但原有归属未知）。"
    if has_interrupted_remnants:
        risk_notice_zh += " 警告：检测到可能存在上次中断部署的残留目录（.deploying-*），建议在执行写入前先核查。"

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
        workspace_fingerprint=workspace_fingerprint,
        consumed=False,
    )
    preview_payload = {
        "preview_id": preview_id,
        "target": target,
        "environment": environment,
        "blocked": has_blocked,
        "can_apply": can_apply,
        "has_prune": has_prune,
        "no_changes": no_changes,
        "summary_zh": summary_zh,
        "items": items,
        "risk_notice_zh": risk_notice_zh,
        "expires_in_sec": 300,
        "repo_head_sha": repo_head_sha,
        "workspace_fingerprint": workspace_fingerprint[:12],
    }
    return preview_payload, record
