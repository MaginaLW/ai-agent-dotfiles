"""Path validation, reparse-point refusal, and output sanitization helpers."""

from __future__ import annotations

import os
from pathlib import Path
import re
from typing import Any


SKILL_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
LOOPBACK_URL_RE = re.compile(r"^http://127\.0\.0\.1:([1-9][0-9]{0,4})/$")
WINDOWS_USERS_RE = re.compile(r"(?i)[A-Za-z]:[\\/]+Users[\\/]+[^\\/\r\n\t\"'`<>|:;]+")
POSIX_HOME_RE = re.compile(r"(?:/Users/|/home/)[^/\r\n\t\"'`<>|:;\s]+")


def _norm_path_key(path: Path | str) -> str:
    return os.path.normcase(os.path.abspath(os.path.normpath(os.fspath(path))))


def is_reparse_or_symlink(path: Path) -> bool:
    """Return True if path exists as a symlink or Windows reparse point."""
    try:
        info = path.lstat()
    except OSError:
        return False
    if os.path.islink(path):
        return True
    import stat

    if stat.S_ISLNK(info.st_mode):
        return True
    attrs = getattr(info, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attrs & reparse_flag)


def assert_plain_path_no_reparse(path: Path, allow_missing: bool = False) -> Path:
    """Verify every existing path component is a plain directory/file without reparse points."""
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
    """Validate and resolve a repo-relative path without traversal or reparse points."""
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
