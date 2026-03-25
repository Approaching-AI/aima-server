from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

OWNER_HEARTBEAT_STALE_SECONDS = 30


def default_runtime_root(state_file: Path) -> Path:
    return state_file.expanduser().resolve().parent / "device-runtime"


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    tmp_path.replace(path)


def _read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


@dataclass(frozen=True)
class CliRuntimePaths:
    root: Path
    owner_pid_path: Path
    owner_log_path: Path
    owner_error_log_path: Path
    owner_heartbeat_path: Path
    session_status_path: Path
    pending_interaction_path: Path
    interaction_answer_path: Path
    task_completion_path: Path
    disconnect_request_path: Path

    @classmethod
    def from_root(cls, root: Path) -> "CliRuntimePaths":
        root = root.expanduser().resolve()
        return cls(
            root=root,
            owner_pid_path=root / "owner.pid",
            owner_log_path=root / "owner.log",
            owner_error_log_path=root / "owner.err.log",
            owner_heartbeat_path=root / "owner-heartbeat.json",
            session_status_path=root / "session-status.json",
            pending_interaction_path=root / "pending-interaction.json",
            interaction_answer_path=root / "interaction-answer.json",
            task_completion_path=root / "task-completion.json",
            disconnect_request_path=root / "disconnect.request",
        )


class CliRuntimeStore:
    def __init__(self, root: Path) -> None:
        self.paths = CliRuntimePaths.from_root(root)

    @classmethod
    def from_state_file(cls, state_file: Path) -> "CliRuntimeStore":
        return cls(default_runtime_root(state_file))

    def ensure_root(self) -> None:
        self.paths.root.mkdir(parents=True, exist_ok=True)

    def prepare_for_owner_start(self) -> None:
        self.ensure_root()
        for path in (
            self.paths.owner_heartbeat_path,
            self.paths.session_status_path,
            self.paths.disconnect_request_path,
        ):
            path.unlink(missing_ok=True)

    def clear_ephemeral_files(self) -> None:
        for path in (
            self.paths.owner_pid_path,
            self.paths.owner_heartbeat_path,
            self.paths.session_status_path,
            self.paths.pending_interaction_path,
            self.paths.interaction_answer_path,
            self.paths.task_completion_path,
            self.paths.disconnect_request_path,
        ):
            path.unlink(missing_ok=True)

    def write_owner_pid(self, pid: int) -> None:
        self.ensure_root()
        self.paths.owner_pid_path.write_text(f"{pid}\n", encoding="utf-8")

    def read_owner_pid(self) -> Optional[int]:
        if not self.paths.owner_pid_path.exists():
            return None
        try:
            return int(self.paths.owner_pid_path.read_text(encoding="utf-8").strip())
        except Exception:
            return None

    def clear_owner_pid(self) -> None:
        self.paths.owner_pid_path.unlink(missing_ok=True)

    def write_session_status(
        self,
        *,
        phase: str,
        level: str,
        message: str,
        active_task_id: str = "",
    ) -> None:
        _write_json(
            self.paths.session_status_path,
            {
                "phase": phase,
                "level": level,
                "message": message,
                "active_task_id": active_task_id,
                "updated_at": int(time.time()),
            },
        )

    def read_session_status(self) -> dict[str, Any]:
        return _read_json(self.paths.session_status_path)

    def clear_session_status(self) -> None:
        self.paths.session_status_path.unlink(missing_ok=True)

    def write_owner_heartbeat(
        self,
        *,
        pid: int,
        device_id: str,
        phase: str,
        active_task_id: str = "",
        command_id: str = "",
    ) -> None:
        _write_json(
            self.paths.owner_heartbeat_path,
            {
                "pid": pid,
                "device_id": device_id,
                "phase": phase,
                "active_task_id": active_task_id,
                "command_id": command_id,
                "updated_at": int(time.time()),
            },
        )

    def read_owner_heartbeat(self) -> dict[str, Any]:
        return _read_json(self.paths.owner_heartbeat_path)

    def write_pending_interaction(
        self,
        *,
        interaction_id: str,
        question: str,
        interaction_type: str,
        interaction_level: str,
        interaction_phase: str,
    ) -> None:
        _write_json(
            self.paths.pending_interaction_path,
            {
                "interaction_id": interaction_id,
                "question": question,
                "interaction_type": interaction_type,
                "interaction_level": interaction_level,
                "interaction_phase": interaction_phase,
                "updated_at": int(time.time()),
            },
        )

    def read_pending_interaction(self) -> dict[str, Any]:
        return _read_json(self.paths.pending_interaction_path)

    def clear_pending_interaction(self) -> None:
        self.paths.pending_interaction_path.unlink(missing_ok=True)
        self.paths.interaction_answer_path.unlink(missing_ok=True)

    def write_interaction_answer(self, *, interaction_id: str, answer: str) -> None:
        _write_json(
            self.paths.interaction_answer_path,
            {
                "interaction_id": interaction_id,
                "answer": answer,
                "updated_at": int(time.time()),
            },
        )

    def read_interaction_answer(self) -> dict[str, Any]:
        return _read_json(self.paths.interaction_answer_path)

    def clear_interaction_answer(self) -> None:
        self.paths.interaction_answer_path.unlink(missing_ok=True)

    def write_task_completion(self, payload: dict[str, Any]) -> None:
        normalized = {
            "task_id": str(payload.get("notif_task_id") or ""),
            "task_status": str(payload.get("notif_task_status") or ""),
            "budget_tasks_remaining": payload.get("notif_budget_tasks_remaining"),
            "budget_tasks_total": payload.get("notif_budget_tasks_total"),
            "budget_usd_remaining": payload.get("notif_budget_usd_remaining"),
            "budget_usd_total": payload.get("notif_budget_usd_total"),
            "referral_code": str(payload.get("notif_referral_code") or ""),
            "share_text": str(payload.get("notif_share_text") or ""),
            "task_message": str(payload.get("notif_task_message") or ""),
            "updated_at": int(time.time()),
        }
        _write_json(self.paths.task_completion_path, normalized)

    def read_task_completion(self) -> dict[str, Any]:
        return _read_json(self.paths.task_completion_path)

    def clear_task_completion(self) -> None:
        self.paths.task_completion_path.unlink(missing_ok=True)

    def request_disconnect(self) -> None:
        self.ensure_root()
        self.paths.disconnect_request_path.write_text("1\n", encoding="utf-8")

    def clear_disconnect_request(self) -> None:
        self.paths.disconnect_request_path.unlink(missing_ok=True)

    def disconnect_requested(self) -> bool:
        return self.paths.disconnect_request_path.exists()


class CliOwnerProcessManager:
    def __init__(
        self,
        *,
        runtime: CliRuntimeStore,
        platform_url: str,
        state_file: Path,
        wait_seconds: int,
        python_executable: str | None = None,
    ) -> None:
        self.runtime = runtime
        self.platform_url = platform_url.rstrip("/")
        self.state_file = state_file.expanduser().resolve()
        self.wait_seconds = wait_seconds
        self.python_executable = python_executable or sys.executable

    def _owner_command(self, *, bootstrap_mode: str) -> list[str]:
        return [
            self.python_executable,
            "-m",
            "aima_cli.main",
            "device",
            "run",
            "--platform-url",
            self.platform_url,
            "--state-file",
            str(self.state_file),
            "--wait-seconds",
            str(self.wait_seconds),
            "--runtime-dir",
            str(self.runtime.paths.root),
            "--owner",
            "--owner-bootstrap-mode",
            bootstrap_mode,
        ]

    def start(self, *, bootstrap_mode: str) -> bool:
        self.runtime.prepare_for_owner_start()
        env = dict(os.environ)
        cli_src_root = str(Path(__file__).resolve().parent.parent)
        existing_pythonpath = env.get("PYTHONPATH", "")
        env["PYTHONPATH"] = (
            cli_src_root
            if not existing_pythonpath
            else cli_src_root + os.pathsep + existing_pythonpath
        )
        with self.runtime.paths.owner_log_path.open("ab") as stdout_handle:
            with self.runtime.paths.owner_error_log_path.open("ab") as stderr_handle:
                popen_kwargs: dict[str, Any] = {
                    "stdin": subprocess.DEVNULL,
                    "stdout": stdout_handle,
                    "stderr": stderr_handle,
                    "cwd": str(self.runtime.paths.root),
                    "close_fds": True,
                    "env": env,
                }
                if os.name == "nt":
                    creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
                    creationflags |= getattr(subprocess, "DETACHED_PROCESS", 0)
                    creationflags |= getattr(subprocess, "CREATE_NO_WINDOW", 0)
                    popen_kwargs["creationflags"] = creationflags
                else:
                    popen_kwargs["start_new_session"] = True
                process = subprocess.Popen(
                    self._owner_command(bootstrap_mode=bootstrap_mode),
                    **popen_kwargs,
                )
        self.runtime.write_owner_pid(process.pid)
        return True

    def health_detail(self, *, expected_device_id: str = "") -> Optional[str]:
        owner_pid = self.runtime.read_owner_pid()
        if owner_pid is None:
            return "owner pid missing"
        if not self._pid_running(owner_pid):
            return "owner process not running"
        heartbeat = self.runtime.read_owner_heartbeat()
        if not heartbeat:
            return "owner heartbeat file missing"
        updated_at = heartbeat.get("updated_at")
        if not isinstance(updated_at, int):
            return "owner heartbeat missing updated_at"
        age = time.time() - float(updated_at)
        if age >= OWNER_HEARTBEAT_STALE_SECONDS:
            phase = str(heartbeat.get("phase") or "unknown")
            return f"owner heartbeat stale (age={int(age)}s, phase={phase})"
        heartbeat_device_id = str(heartbeat.get("device_id") or "")
        if expected_device_id and heartbeat_device_id and heartbeat_device_id != expected_device_id:
            return f"owner heartbeat device mismatch (heartbeat={heartbeat_device_id}, current={expected_device_id})"
        return None

    def wait_until_healthy(self, *, expected_device_id: str = "", timeout_seconds: float = 5.0) -> bool:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if self.health_detail(expected_device_id=expected_device_id) is None:
                return True
            time.sleep(0.2)
        return self.health_detail(expected_device_id=expected_device_id) is None

    def request_disconnect(self) -> None:
        self.runtime.request_disconnect()

    def wait_for_stop(self, *, timeout_seconds: float = 5.0) -> bool:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            owner_pid = self.runtime.read_owner_pid()
            if owner_pid is None or not self._pid_running(owner_pid):
                return True
            time.sleep(0.2)
        owner_pid = self.runtime.read_owner_pid()
        return owner_pid is None or not self._pid_running(owner_pid)

    def stop(self) -> None:
        owner_pid = self.runtime.read_owner_pid()
        if owner_pid is None:
            return
        if os.name == "nt":
            taskkill = shutil.which("taskkill")
            if taskkill:
                subprocess.run(
                    [taskkill, "/F", "/T", "/PID", str(owner_pid)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
            else:
                try:
                    os.kill(owner_pid, signal.SIGTERM)
                except OSError:
                    pass
        else:
            try:
                os.killpg(owner_pid, signal.SIGTERM)
            except OSError:
                try:
                    os.kill(owner_pid, signal.SIGTERM)
                except OSError:
                    pass
            time.sleep(1)
            try:
                os.killpg(owner_pid, signal.SIGKILL)
            except OSError:
                try:
                    os.kill(owner_pid, signal.SIGKILL)
                except OSError:
                    pass

    @staticmethod
    def _pid_running(pid: int) -> bool:
        if pid <= 0:
            return False
        if os.name == "nt":
            try:
                process = subprocess.run(
                    ["tasklist", "/FI", f"PID eq {pid}"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
            except OSError:
                return False
            return str(pid) in process.stdout
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True
