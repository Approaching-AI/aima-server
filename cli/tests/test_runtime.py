from __future__ import annotations

import json
import os
import shlex
import sys
from contextlib import contextmanager
from pathlib import Path

import pytest

from aima_cli.runtime import RESULT_TAIL_LIMIT_BYTES, run_device_command


def _device_command_for_python(snippet: str) -> str:
    if os.name == "nt":
        def ps_quote(value: str) -> str:
            return "'" + value.replace("'", "''") + "'"

        return f"& {ps_quote(sys.executable)} -c {ps_quote(snippet)}"

    return f"{shlex.quote(sys.executable)} -c {shlex.quote(snippet)}"


@pytest.mark.asyncio
async def test_run_device_command_uses_dedicated_workdir_and_devnull(tmp_path: Path) -> None:
    snippet = "import os,sys; print(os.getcwd()); print(repr(sys.stdin.read()))"
    result = await run_device_command(
        command=_device_command_for_python(snippet),
        timeout_seconds=10,
        progress_callback=_never_cancel,
        task_id="task_demo",
        command_id="cmd_demo",
        execution_root=tmp_path / "executions",
        intent="verify sandbox",
    )

    assert result.exit_code == 0
    stdout_lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    assert stdout_lines[0] == str(result.work_dir)
    assert stdout_lines[1] == "''"
    assert result.work_dir.is_dir()
    assert result.stdout_log_path.is_file()
    assert result.stderr_log_path.is_file()

    journal = json.loads(result.journal_path.read_text(encoding="utf-8"))
    assert journal["status"] == "completed"
    assert journal["work_dir"] == str(result.work_dir)
    assert journal["artifact_dir"] == str(result.artifact_dir)


@pytest.mark.asyncio
async def test_run_device_command_caps_result_output_but_persists_full_logs(tmp_path: Path) -> None:
    snippet = f"import sys; sys.stdout.write('x' * {RESULT_TAIL_LIMIT_BYTES + 8192})"
    result = await run_device_command(
        command=_device_command_for_python(snippet),
        timeout_seconds=10,
        progress_callback=_never_cancel,
        task_id="task_big",
        command_id="cmd_big",
        execution_root=tmp_path / "executions",
        intent="emit large stdout",
    )

    assert result.exit_code == 0
    assert len(result.stdout) <= RESULT_TAIL_LIMIT_BYTES + 32
    assert result.stdout_log_path.stat().st_size > len(result.stdout)
    assert result.stdout.endswith("x" * 512)


@pytest.mark.asyncio
async def test_run_device_command_resolves_relative_execution_root(tmp_path: Path) -> None:
    base_dir = tmp_path / "workspace"
    base_dir.mkdir()
    relative_root = Path("relative-executions")
    with pushd(base_dir):
        result = await run_device_command(
            command=_device_command_for_python("import os; print(os.getcwd())"),
            timeout_seconds=10,
            progress_callback=_never_cancel,
            task_id="task_rel",
            command_id="cmd_rel",
            execution_root=relative_root,
            intent="relative root smoke",
        )

    assert result.exit_code == 0
    assert result.artifact_dir.is_absolute()
    assert result.stdout.strip() == str(result.work_dir)
    assert result.artifact_dir == (base_dir / relative_root / "task_rel" / "cmd_rel").resolve()


@pytest.mark.asyncio
async def test_run_device_command_truncates_existing_logs_for_same_command_id(tmp_path: Path) -> None:
    execution_root = tmp_path / "executions"
    artifact_dir = execution_root / "task_same" / "cmd_same"
    artifact_dir.mkdir(parents=True)
    (artifact_dir / "stdout.log").write_text("stale-stdout\n", encoding="utf-8")
    (artifact_dir / "stderr.log").write_text("stale-stderr\n", encoding="utf-8")

    result = await run_device_command(
        command=_device_command_for_python("print('fresh-stdout')"),
        timeout_seconds=10,
        progress_callback=_never_cancel,
        task_id="task_same",
        command_id="cmd_same",
        execution_root=execution_root,
        intent="overwrite previous logs",
    )

    assert result.exit_code == 0
    assert "fresh-stdout" in result.stdout
    assert "stale-stdout" not in result.stdout
    assert result.stdout_log_path.read_text(encoding="utf-8") == "fresh-stdout\n"
    assert result.stderr_log_path.read_text(encoding="utf-8") == ""


async def _never_cancel(stdout: str, stderr: str, message: str) -> bool:
    del stdout, stderr, message
    return False


@contextmanager
def pushd(path: Path):
    previous = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)
