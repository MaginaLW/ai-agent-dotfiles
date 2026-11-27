"""Action allowlist, streaming subprocess execution, job tracking, and safe cancel."""

from __future__ import annotations

from dataclasses import dataclass, field
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time
from typing import Any, Callable

from dashboard.lib.collectors import utc_now_iso


ALLOWED_ACTIONS = frozenset({
    "doctor",
    "scan",
    "build-skills",
    "antigravity-build",
    "test-suite",
    "test-all",
})


@dataclass
class RunResult:
    exit_code: int
    stdout: str
    stderr: str
    error: str | None = None


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
    cancel_requested: bool = field(default=False, repr=False, compare=False)
    _proc: subprocess.Popen[str] | None = field(default=None, repr=False, compare=False)

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
    """Synchronous bounded subprocess runner used for short read-only CLI probes."""
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


def kill_process_tree(proc: subprocess.Popen[Any]) -> None:
    """Terminate a child process and its descendants cleanly across Windows/POSIX."""
    if proc.poll() is not None:
        return
    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                capture_output=True,
                timeout=5.0,
                shell=False,
            )
        except (OSError, subprocess.SubprocessError):
            pass
    if proc.poll() is None:
        try:
            proc.kill()
        except OSError:
            pass
    try:
        proc.wait(timeout=2.0)
    except (OSError, subprocess.SubprocessError):
        pass


def run_streaming_subprocess(
    argv: list[str],
    cwd: Path,
    timeout: float,
    *,
    on_line: Callable[[str], None] | None = None,
    on_process_start: Callable[[subprocess.Popen[str]], None] | None = None,
    is_cancelled: Callable[[], bool] | None = None,
) -> RunResult:
    """Run a child process with live incremental stdout/stderr line streaming and tree kill on timeout/cancel."""
    try:
        proc = subprocess.Popen(
            argv,
            cwd=os.fspath(cwd),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            shell=False,
        )
    except OSError as exc:
        return RunResult(exit_code=127, stdout="", stderr="", error=str(exc))

    if on_process_start is not None:
        on_process_start(proc)

    stdout_chunks: list[str] = []
    stderr_chunks: list[str] = []

    def _pump(stream: Any, bucket: list[str]) -> None:
        if stream is None:
            return
        try:
            for chunk in iter(stream.readline, ""):
                bucket.append(chunk)
                if on_line is not None:
                    on_line(chunk)
        except (OSError, ValueError):
            pass
        finally:
            try:
                stream.close()
            except OSError:
                pass

    t_out = threading.Thread(target=_pump, args=(proc.stdout, stdout_chunks), daemon=True)
    t_err = threading.Thread(target=_pump, args=(proc.stderr, stderr_chunks), daemon=True)
    t_out.start()
    t_err.start()

    timed_out = False
    cancelled = False
    deadline = time.monotonic() + timeout
    while proc.poll() is None:
        if is_cancelled is not None and is_cancelled():
            cancelled = True
            kill_process_tree(proc)
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            kill_process_tree(proc)
            break
        try:
            proc.wait(timeout=min(0.2, remaining))
        except subprocess.TimeoutExpired:
            continue

    t_out.join(timeout=2.0)
    t_err.join(timeout=2.0)

    exit_code = proc.returncode if proc.returncode is not None else (124 if timed_out else -1)
    error_msg: str | None = None
    if cancelled:
        error_msg = "cancelled"
    elif timed_out:
        exit_code = 124
        error_msg = f"command timed out after {timeout}s"

    return RunResult(
        exit_code=exit_code,
        stdout="".join(stdout_chunks),
        stderr="".join(stderr_chunks),
        error=error_msg,
    )


def build_action_command(
    repo_root: Path,
    home_root: Path | None,
    action: str,
    suite: str | None,
) -> tuple[str, list[str], float]:
    """Build pwsh command argv and timeout for allowlisted read-only/build/test actions."""
    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"unsupported action: {action}")
    pwsh = shutil.which("pwsh") or "pwsh"
    scripts_dir = repo_root / "scripts"
    repo_str = os.fspath(repo_root)

    if action == "doctor":
        argv = [pwsh, "-NoProfile", "-File", os.fspath(scripts_dir / "doctor.ps1"), "-RepoRoot", repo_str]
        if home_root is not None:
            argv.extend(["-HomeRoot", os.fspath(home_root)])
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
        tests_dir = repo_root / "tests"
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


def parse_doctor_structured(output_sanitized: str) -> dict[str, Any]:
    """Parse [PASS]/[WARN]/[FAIL]/[INFO] checks and deploy blockers from doctor.ps1 output."""
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


def finalize_job_locked(
    job: JobRecord,
    label_zh: str,
    res: RunResult,
    output_sanitized: str,
    sanitizer: Any,
    on_complete: Callable[[JobRecord, RunResult, str], None] | None,
) -> None:
    """Update job terminal fields under lock unless the job was already cancelled."""
    if job.cancel_requested:
        return
    job.finished_at = utc_now_iso()
    job.duration_sec = round(max(0.0, time.monotonic() - job.started_monotonic), 3)
    job.exit_code = res.exit_code
    job.output_sanitized = output_sanitized
    job.status = "succeeded" if res.exit_code == 0 else "failed"
    job.summary_zh = f"{label_zh} 完成" if res.exit_code == 0 else f"{label_zh} 失败（退出码 {res.exit_code}）"
    job._proc = None
    if on_complete is not None:
        on_complete(job, res, output_sanitized)
    if job.status == "failed" and not job.ai_prompt:
        tail = "\n".join(output_sanitized.splitlines()[-30:])
        job.ai_prompt = sanitizer.sanitize_str(
            f"本地任务「{label_zh}」执行失败（退出码 {res.exit_code}），请帮我排查以下脱敏输出：\n\n{tail}"
        )
