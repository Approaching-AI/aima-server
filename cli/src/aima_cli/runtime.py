from __future__ import annotations

import asyncio
import json
import os
import shutil
import signal
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable

PROGRESS_TAIL_LIMIT_BYTES = 4096
RESULT_TAIL_LIMIT_BYTES = 128 * 1024


@dataclass
class CommandExecutionResult:
    exit_code: int
    stdout: str
    stderr: str
    artifact_dir: Path
    work_dir: Path
    stdout_log_path: Path
    stderr_log_path: Path
    journal_path: Path


def platform_os_name() -> str:
    return os.name


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _command_runner(script_path: Path) -> list[str]:
    if platform_os_name() == "nt":
        powershell = shutil.which("powershell.exe") or "powershell.exe"
        return [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script_path)]
    bash = shutil.which("bash") or "/bin/bash"
    return [bash, str(script_path)]


def _append_runtime_note(text: str, note: str) -> str:
    if not text:
        return note
    if text.endswith("\n"):
        return text + note
    return text + "\n" + note


def _read_tail(path: Path, limit_bytes: int) -> str:
    if not path.exists():
        return ""
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        handle.seek(max(0, size - limit_bytes))
        return handle.read().decode("utf-8", errors="replace")


def _write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    tmp_path.replace(path)


def _log_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


async def _signal_process_tree(process: asyncio.subprocess.Process, *, force: bool) -> None:
    if process.returncode is not None:
        return
    if platform_os_name() == "nt":
        taskkill = shutil.which("taskkill")
        if taskkill:
            cmd = [taskkill]
            if force:
                cmd.append("/F")
            cmd.extend(["/T", "/PID", str(process.pid)])
            await asyncio.to_thread(
                subprocess.run,
                cmd,
                check=False,
                capture_output=True,
                text=True,
            )
            return
        if force:
            process.kill()
        else:
            process.terminate()
        return

    sig = signal.SIGKILL if force else signal.SIGTERM
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        return


async def _stop_process_tree(
    process: asyncio.subprocess.Process,
    *,
    grace_seconds: float,
) -> None:
    if process.returncode is not None:
        return
    await _signal_process_tree(process, force=False)
    try:
        await asyncio.wait_for(process.wait(), timeout=grace_seconds)
        return
    except asyncio.TimeoutError:
        pass
    await _signal_process_tree(process, force=True)
    await process.wait()


async def run_device_command(
    *,
    command: str,
    timeout_seconds: int,
    progress_callback: Callable[[str, str, str], Awaitable[bool]],
    task_id: str,
    command_id: str,
    execution_root: Path,
    intent: str = "",
) -> CommandExecutionResult:
    suffix = ".ps1" if platform_os_name() == "nt" else ".sh"
    execution_root = execution_root.expanduser().resolve()
    artifact_dir = (execution_root / task_id / command_id).resolve()
    work_dir = artifact_dir / "workdir"
    stdout_log_path = artifact_dir / "stdout.log"
    stderr_log_path = artifact_dir / "stderr.log"
    journal_path = artifact_dir / "journal.json"

    artifact_dir.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)

    script_path = (artifact_dir / f"command{suffix}").resolve()
    script_path.write_text(command, encoding="utf-8")
    if platform_os_name() != "nt":
        os.chmod(script_path, 0o700)

    journal: dict[str, object] = {
        "artifact_dir": str(artifact_dir),
        "command_id": command_id,
        "command_preview": command[:240],
        "created_at": _utcnow_iso(),
        "intent": intent,
        "journal_version": 1,
        "script_path": str(script_path),
        "status": "prepared",
        "stderr_log_path": str(stderr_log_path),
        "stdout_log_path": str(stdout_log_path),
        "task_id": task_id,
        "timeout_seconds": timeout_seconds,
        "work_dir": str(work_dir),
    }
    _write_json(journal_path, journal)

    popen_kwargs: dict[str, object] = {
        "cwd": work_dir,
        "env": {
            **os.environ,
            "AIMA_EXECUTION_SANDBOX": "1",
            "AIMA_EXECUTION_DIR": str(artifact_dir),
            "AIMA_EXECUTION_WORKDIR": str(work_dir),
            "PYTHONUNBUFFERED": os.environ.get("PYTHONUNBUFFERED", "1"),
        },
        "stdin": asyncio.subprocess.DEVNULL,
        "stdout": None,
        "stderr": None,
    }
    if platform_os_name() == "nt":
        popen_kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        popen_kwargs["start_new_session"] = True

    stdout_handle = stdout_log_path.open("wb")
    stderr_handle = stderr_log_path.open("wb")
    popen_kwargs["stdout"] = stdout_handle
    popen_kwargs["stderr"] = stderr_handle

    process: asyncio.subprocess.Process | None = None
    started = asyncio.get_running_loop().time()
    next_progress_at = started + 5
    remote_cancelled = False
    timeout_triggered = False
    raised_error: BaseException | None = None

    try:
        process = await asyncio.create_subprocess_exec(
            *_command_runner(script_path),
            **popen_kwargs,
        )
        journal.update(
            {
                "pid": process.pid,
                "started_at": _utcnow_iso(),
                "status": "running",
            }
        )
        _write_json(journal_path, journal)
    finally:
        stdout_handle.close()
        stderr_handle.close()

    assert process is not None

    try:
        while process.returncode is None:
            try:
                await asyncio.wait_for(process.wait(), timeout=1)
            except asyncio.TimeoutError:
                pass
            if process.returncode is not None:
                break

            now = asyncio.get_running_loop().time()
            if now - started >= timeout_seconds:
                timeout_triggered = True
                await _stop_process_tree(process, grace_seconds=5)
                break
            if now >= next_progress_at:
                elapsed = int(now - started)
                stdout_tail = _read_tail(stdout_log_path, PROGRESS_TAIL_LIMIT_BYTES)
                stderr_tail = _read_tail(stderr_log_path, PROGRESS_TAIL_LIMIT_BYTES)
                journal.update(
                    {
                        "last_progress_at": _utcnow_iso(),
                        "status": "running",
                    }
                )
                _write_json(journal_path, journal)
                cancel_requested = await progress_callback(
                    stdout_tail,
                    stderr_tail,
                    f"Command still running ({elapsed}s)",
                )
                next_progress_at = now + 5
                if cancel_requested:
                    remote_cancelled = True
                    await _stop_process_tree(process, grace_seconds=5)
                    break
    except BaseException as exc:
        raised_error = exc
        if process.returncode is None:
            await _stop_process_tree(process, grace_seconds=1)
    finally:
        if process.returncode is None:
            await _stop_process_tree(process, grace_seconds=1)

    stdout_text = _read_tail(stdout_log_path, RESULT_TAIL_LIMIT_BYTES)
    stderr_text = _read_tail(stderr_log_path, RESULT_TAIL_LIMIT_BYTES)

    exit_code = process.returncode if process.returncode is not None else 130
    status = "completed" if exit_code == 0 else "failed"
    if timeout_triggered:
        exit_code = 124
        status = "timed_out"
        stderr_text = _append_runtime_note(stderr_text, f"Command timed out after {timeout_seconds}s")
    elif remote_cancelled:
        exit_code = 130
        status = "cancelled"
        stderr_text = _append_runtime_note(stderr_text, "Command cancelled after remote request")

    journal.update(
        {
            "completed_at": _utcnow_iso(),
            "exit_code": exit_code,
            "status": status,
            "stderr_log_bytes": _log_size(stderr_log_path),
            "stderr_tail": stderr_text,
            "stdout_log_bytes": _log_size(stdout_log_path),
            "stdout_tail": stdout_text,
        }
    )
    _write_json(journal_path, journal)

    if raised_error is not None:
        raise raised_error

    return CommandExecutionResult(
        exit_code=exit_code,
        stdout=stdout_text,
        stderr=stderr_text,
        artifact_dir=artifact_dir,
        work_dir=work_dir,
        stdout_log_path=stdout_log_path,
        stderr_log_path=stderr_log_path,
        journal_path=journal_path,
    )
