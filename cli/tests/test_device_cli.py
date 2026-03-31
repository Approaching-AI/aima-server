from __future__ import annotations

import asyncio
import io
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator, Tuple
from urllib.parse import parse_qs, urlparse
from uuid import uuid4

import httpx
import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from aima_cli.api import AIMAApiError, DeviceApiClient
from aima_cli.owner_backed import BackgroundOwner, OwnerBackedAttachedRunner
from aima_cli.owner_runtime import CliRuntimeStore
from aima_cli.renderer import TerminalRenderer, format_interaction_question
from aima_cli.session import (
    AttachedDeviceSession,
    ConsoleInputProvider,
    DeviceClientOptions,
    InputClosedError,
    ScriptedInputProvider,
)
from aima_cli.state import DeviceStateStore
from aima_platform.config import Settings
from aima_platform.main import AppContext, create_app, utcnow
from aima_platform.models import Task


def build_settings(db_path: Path) -> Settings:
    return Settings(
        database_url=f"sqlite+aiosqlite:///{db_path}",
        admin_token="admin-token",
        internal_token="internal-token",
        email_delivery_mode="memory",
        activation_code_ttl_hours=24,
        device_token_ttl_days=7,
        poll_interval_seconds=1,
        result_max_chars=1024 * 1024,
        default_device_budget_usd=50.0,
        default_device_max_tasks=10,
    )


@asynccontextmanager
async def platform_client(settings: Settings) -> AsyncIterator[Tuple[AsyncClient, AppContext]]:
    app = create_app(settings)
    async with LifespanManager(app) as manager:
        transport = ASGITransport(app=manager.app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield client, app.state.context


async def create_invite_code(client: AsyncClient) -> str:
    code = f"invite-{uuid4().hex[:8]}"
    response = await client.post(
        "/api/v1/admin/invite-codes",
        headers={"X-Admin-Token": "admin-token"},
        json={"code": code, "max_uses": 5},
    )
    assert response.status_code == 200, response.text
    return code


async def register_device_manager(
    client: AsyncClient,
    context: AppContext,
    *,
    email: str,
    password: str = "password123",
) -> dict:
    request_code = await client.post(
        "/api/v1/device-manager/auth/register/request-code",
        json={"email": email, "password": password},
    )
    assert request_code.status_code == 200, request_code.text
    verification_code = context.email_dispatcher.outbox[-1].metadata["verification_code"]
    verify = await client.post(
        "/api/v1/device-manager/auth/register/verify-code",
        json={"email": email, "code": verification_code},
    )
    assert verify.status_code == 200, verify.text
    return verify.json()


def build_session(
    *,
    client: AsyncClient,
    tmp_path: Path,
    invite_code: str,
    transcript: io.StringIO,
    answers: list[str],
) -> AttachedDeviceSession:
    api = DeviceApiClient(platform_url="http://test", client=client)
    return AttachedDeviceSession(
        api=api,
        options=DeviceClientOptions(
            platform_url="http://test",
            invite_code=invite_code,
            state_file=str(tmp_path / "device-state.json"),
            wait_seconds=0,
        ),
        input_provider=ScriptedInputProvider(answers),
        renderer=TerminalRenderer(stream=transcript),
        state_store=DeviceStateStore(tmp_path / "device-state.json"),
    )


class FakeOwnerManager:
    def __init__(self, *, healthy: bool = True) -> None:
        self.healthy = healthy
        self.start_calls = 0
        self.stop_calls = 0
        self.disconnect_requests = 0

    def health_detail(self, *, expected_device_id: str = "") -> str | None:
        del expected_device_id
        return None if self.healthy else "owner stale"

    def start(self, *, bootstrap_mode: str) -> bool:
        del bootstrap_mode
        self.start_calls += 1
        self.healthy = True
        return True

    def wait_until_healthy(self, *, expected_device_id: str = "", timeout_seconds: float = 5.0) -> bool:
        del expected_device_id, timeout_seconds
        return self.healthy

    def stop(self) -> None:
        self.stop_calls += 1
        self.healthy = False

    def request_disconnect(self) -> None:
        self.disconnect_requests += 1
        self.healthy = False

    def wait_for_stop(self, *, timeout_seconds: float = 5.0) -> bool:
        del timeout_seconds
        return True


@pytest.mark.asyncio
async def test_device_api_client_disables_env_proxy_resolution(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    class FakeAsyncClient:
        async def aclose(self) -> None:
            return None

    def fake_async_client(*args, **kwargs):
        del args
        captured.update(kwargs)
        return FakeAsyncClient()

    monkeypatch.setattr(httpx, "AsyncClient", fake_async_client)

    api = DeviceApiClient(platform_url="http://127.0.0.1:8011")
    entered = await api.__aenter__()
    assert entered is api
    assert captured["base_url"] == "http://127.0.0.1:8011"
    assert captured["timeout"] == 30.0
    assert captured["trust_env"] is False
    await api.__aexit__(None, None, None)


@pytest.mark.asyncio
async def test_console_input_provider_wraps_eof_as_input_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def raise_eof(prompt: str) -> str:
        del prompt
        raise EOFError

    monkeypatch.setattr("builtins.input", raise_eof)
    provider = ConsoleInputProvider()

    with pytest.raises(InputClosedError):
        await provider.prompt("> ")


@pytest.mark.asyncio
async def test_cli_renders_task_menu_from_manifest_blocks(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[
                "1",
                "dify，希望用 docker 方式安装",
            ],
        )

        await session.ensure_manifest()
        await session.ensure_registered()
        choice = await session.prompt_task_menu_once()

        assert choice is not None
        assert choice != "__disconnect__"
        assert choice != "feedback"
        assert choice.intake["mode"] == "install_software"
        assert choice.intake["user_request"] == "dify，希望用 docker 方式安装"
        assert choice.intake["renderer"] == "cli"
        assert choice.intake["software_hint"] == "dify"
        assert choice.experience_search["task_type_hint"] == "software_install"
        assert choice.experience_search["target_hint"] == "dify"
        assert "dify，希望用 docker 方式安装" in choice.description
        output = transcript.getvalue()
        assert "What would you like me to help you do?" in output
        assert "Describe the goal in one sentence." in output
        assert "Examples:" in output
        assert "想装什么软件？有什么补充信息" in output
        assert "检查 python 版本，低于 3.11 就升级到 3.12" in output
        assert "Install open-source software" not in output
        assert "0. Submit feedback or report a bug" not in output
        assert "3. " not in output


@pytest.mark.asyncio
async def test_cli_builds_guided_repair_request_from_manifest_steps(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[
                "2",
                "openclaw 发消息到飞书没反应了，之前是好的",
            ],
        )

        await session.ensure_manifest()
        await session.ensure_registered()
        choice = await session.prompt_task_menu_once()

        assert choice is not None
        assert choice != "__disconnect__"
        assert choice != "feedback"
        assert choice.intake["mode"] == "repair_software"
        assert choice.intake["user_request"] == "openclaw 发消息到飞书没反应了，之前是好的"
        assert choice.intake["software_hint"] == "openclaw"
        assert choice.intake["problem_hint"] == "openclaw 发消息到飞书没反应了，之前是好的"
        assert choice.experience_search["task_type_hint"] == "software_repair"
        assert choice.experience_search["target_hint"] == "openclaw"
        assert choice.experience_search["error_message_hint"] == "openclaw 发消息到飞书没反应了，之前是好的"
        assert "openclaw 发消息到飞书没反应了，之前是好的" in choice.description
        output = transcript.getvalue()
        assert "不要粘贴密码 / API Key / Token 原文" in output
        assert "哪个软件有问题？什么现象？" in output


@pytest.mark.asyncio
async def test_cli_guided_prompt_returns_detach_when_input_closes(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    class DisconnectDuringGuidedPrompt:
        def __init__(self) -> None:
            self.calls = 0

        async def prompt(self, prompt: str) -> str:
            del prompt
            self.calls += 1
            if self.calls == 1:
                return "1"
            raise InputClosedError("stdin closed")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[],
        )
        session.input_provider = DisconnectDuringGuidedPrompt()

        await session.ensure_manifest()
        await session.ensure_registered()
        choice = await session.prompt_task_menu_once()

        assert choice == "__detach__"


@pytest.mark.asyncio
async def test_cli_task_menu_accepts_freeform_input(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["please use docker to install open-webui"],
        )

        await session.ensure_manifest()
        await session.ensure_registered()
        session.renderer.lang = "zh_cn"
        choice = await session.prompt_task_menu_once()

        assert choice is not None
        assert choice != "__disconnect__"
        assert choice != "feedback"
        assert choice.description == "please use docker to install open-webui"
        assert choice.intake["mode"] == "freeform"
        assert choice.intake["user_request"] == "please use docker to install open-webui"
        assert choice.intake["software_hint"] == "open-webui"
        assert choice.experience_search["task_type_hint"] == "software_install"
        assert choice.experience_search["target_hint"] == "open-webui"
        assert "请选择 1 / 2" not in transcript.getvalue()


@pytest.mark.asyncio
async def test_cli_task_menu_infers_known_software_target_from_freeform_request_without_install_keyword(
    tmp_path: Path,
) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["刚接上这台机器，先帮我把 OpenClaw 弄好，能用就行。"],
        )

        await session.ensure_manifest()
        await session.ensure_registered()
        session.renderer.lang = "zh_cn"
        choice = await session.prompt_task_menu_once()

        assert choice is not None
        assert choice != "__disconnect__"
        assert choice != "feedback"
        assert choice.intake["software_hint"] == "openclaw"
        assert choice.experience_search["target_hint"] == "openclaw"


@pytest.mark.asyncio
async def test_cli_task_menu_infers_ktransformers_model_deployment_hints_from_freeform_request(
    tmp_path: Path,
) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["部署 qwen2.5 7b 到 k-transformers，使用 AWQ，并验证 GPU 推理"],
        )

        await session.ensure_manifest()
        await session.ensure_registered()
        session.renderer.lang = "zh_cn"
        choice = await session.prompt_task_menu_once()

        assert choice is not None
        assert choice != "__disconnect__"
        assert choice != "feedback"
        assert choice.intake["software_hint"] == "ktransformers"
        assert choice.intake["deployment_kind"] == "ktransformers_model_deploy"
        assert choice.intake["model_name"] == "qwen2.5 7b"
        assert choice.intake["model_format"] == "awq"
        assert choice.intake["quantization"] == "awq"
        assert choice.intake["gpu_required"] is True
        assert choice.experience_search["task_type_hint"] == "software_install"
        assert choice.experience_search["target_hint"] == "ktransformers"
        assert choice.experience_search["deployment_kind"] == "ktransformers_model_deploy"
        assert choice.experience_search["model_name"] == "qwen2.5 7b"
        assert choice.experience_search["model_format"] == "awq"
        assert choice.experience_search["quantization"] == "awq"
        assert choice.experience_search["gpu_required"] is True


@pytest.mark.asyncio
async def test_cli_task_menu_infers_ktransformers_test_hints_from_freeform_request(
    tmp_path: Path,
) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["测试 ktransformers 上的 qwen2.5 7b AWQ 部署，验证 GPU 推理是否正常"],
        )

        await session.ensure_manifest()
        await session.ensure_registered()
        session.renderer.lang = "zh_cn"
        choice = await session.prompt_task_menu_once()

        assert choice is not None
        assert choice != "__disconnect__"
        assert choice != "feedback"
        assert choice.intake["software_hint"] == "ktransformers"
        assert choice.intake["deployment_kind"] == "ktransformers_test"
        assert choice.intake["model_name"] == "qwen2.5 7b"
        assert choice.intake["model_format"] == "awq"
        assert choice.intake["quantization"] == "awq"
        assert choice.intake["gpu_required"] is True
        assert choice.experience_search["task_type_hint"] == "verification"
        assert choice.experience_search["target_hint"] == "ktransformers"
        assert choice.experience_search["deployment_kind"] == "ktransformers_test"
        assert choice.experience_search["model_name"] == "qwen2.5 7b"
        assert choice.experience_search["model_format"] == "awq"
        assert choice.experience_search["quantization"] == "awq"
        assert choice.experience_search["gpu_required"] is True


@pytest.mark.asyncio
async def test_cli_requires_confirmation_before_resuming_unfinished_task(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)

        setup_transcript = io.StringIO()
        setup_session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=setup_transcript,
            answers=[],
        )
        await setup_session.ensure_manifest()
        state = await setup_session.ensure_registered()
        state.display_language = "en_us"
        setup_session.state_store.save(state)
        await setup_session.create_task("resume-check")

        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["d"],
        )

        async def fail_run_until_idle(*args, **kwargs) -> None:
            del args, kwargs
            raise AssertionError("run_until_idle should not be reached without explicit resume")

        session.run_until_idle = fail_run_until_idle  # type: ignore[method-assign]

        exit_code = await session.run_attached()

        assert exit_code == 0
        output = transcript.getvalue()
        assert "An unfinished task was found from a previous session." in output
        assert "Resume task now" in output
        assert "Cancel current task" in output


@pytest.mark.asyncio
async def test_cli_recovers_when_task_submit_response_is_interrupted(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[],
        )
        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        session.renderer.lang = "en_us"

        headers = {"Authorization": f"Bearer {state.token}"}
        created = await client.post(
            f"/api/v1/devices/{state.device_id}/tasks",
            headers=headers,
            json={"description": "check python version"},
        )
        assert created.status_code == 200, created.text
        task_id = created.json()["task_id"]

        async def raise_503(*args, **kwargs):
            del args, kwargs
            raise AIMAApiError(503, "server unavailable")

        monkeypatch.setattr(session.api, "create_task", raise_503)

        recovered_task_id = await session.create_task("check python version")

        assert recovered_task_id == task_id
        assert session.active_task_id == task_id
        assert session.confirmed_active_task_id == task_id
        assert "attached to" in transcript.getvalue().lower()


@pytest.mark.asyncio
async def test_cli_input_close_detaches_without_marking_device_offline(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, context):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[],
        )

        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        session.renderer.lang = "en_us"

        class ClosedInputProvider:
            async def prompt(self, prompt: str) -> str:
                del prompt
                raise InputClosedError("stdin closed")

        session.input_provider = ClosedInputProvider()

        exit_code = await session.run_attached()
        await session.shutdown(mark_offline=session.disconnect_requested)

        assert exit_code == 0
        assert session.disconnect_requested is False

        from aima_platform.models import Device

        async with context.session_factory() as db:
            device = await db.get(Device, state.device_id)
            assert device is not None
            assert device.status != "offline"


@pytest.mark.asyncio
async def test_cli_explicit_disconnect_marks_device_offline(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, context):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["d"],
        )

        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        session.renderer.lang = "en_us"

        exit_code = await session.run_attached()
        await session.shutdown(mark_offline=session.disconnect_requested)

        assert exit_code == 0
        assert session.disconnect_requested is True

        from aima_platform.models import Device

        async with context.session_factory() as db:
            device = await db.get(Device, state.device_id)
            assert device is not None
            assert device.status == "offline"


@pytest.mark.asyncio
async def test_owner_backed_runner_detaches_without_requesting_disconnect(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    class ClosedInputProvider:
        async def prompt(self, prompt: str) -> str:
            del prompt
            raise InputClosedError("stdin closed")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[],
        )
        session.input_provider = ClosedInputProvider()
        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        runtime = CliRuntimeStore(tmp_path / "device-runtime")
        owner_manager = FakeOwnerManager()
        runner = OwnerBackedAttachedRunner(session=session, runtime=runtime, owner_manager=owner_manager)

        exit_code = await runner.run()

        assert exit_code == 0
        assert owner_manager.disconnect_requests == 0


@pytest.mark.asyncio
async def test_owner_backed_runner_requests_owner_disconnect(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, context):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["d"],
        )
        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        runtime = CliRuntimeStore(tmp_path / "device-runtime")
        owner_manager = FakeOwnerManager()
        runner = OwnerBackedAttachedRunner(session=session, runtime=runtime, owner_manager=owner_manager)

        exit_code = await runner.run()

        assert exit_code == 0
        assert owner_manager.disconnect_requests == 1

        from aima_platform.models import Device

        async with context.session_factory() as db:
            device = await db.get(Device, state.device_id)
            assert device is not None
            assert device.status == "offline"


@pytest.mark.asyncio
async def test_owner_backed_runner_reads_pending_interaction_from_runtime(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["Collected logs", "quit"],
        )
        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        runtime = CliRuntimeStore(tmp_path / "device-runtime")
        runtime.ensure_root()
        runtime.write_pending_interaction(
            interaction_id="int_test",
            question="Need more context from the device?",
            interaction_type="info_request",
            interaction_level="info",
            interaction_phase="decision",
        )
        owner_manager = FakeOwnerManager()
        runner = OwnerBackedAttachedRunner(session=session, runtime=runtime, owner_manager=owner_manager)

        exit_code = await runner.run()

        assert exit_code == 0
        answer_payload = runtime.read_interaction_answer()
        assert answer_payload["interaction_id"] == "int_test"
        assert answer_payload["answer"] == "Collected logs"
        assert "Need more context from the device?" in transcript.getvalue()


@pytest.mark.asyncio
async def test_owner_backed_runner_reprompts_skipped_pending_interaction(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["", "Collected logs", "quit"],
        )
        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        runtime = CliRuntimeStore(tmp_path / "device-runtime")
        runtime.ensure_root()
        runtime.write_pending_interaction(
            interaction_id="int_test",
            question="Need more context from the device?",
            interaction_type="info_request",
            interaction_level="info",
            interaction_phase="decision",
        )
        owner_manager = FakeOwnerManager()
        runner = OwnerBackedAttachedRunner(
            session=session,
            runtime=runtime,
            owner_manager=owner_manager,
            interaction_retry_after_seconds=0.0,
        )

        exit_code = await runner.run()

        assert exit_code == 0
        answer_payload = runtime.read_interaction_answer()
        assert answer_payload["interaction_id"] == "int_test"
        assert answer_payload["answer"] == "Collected logs"
        assert transcript.getvalue().count("Need more context from the device?") >= 2


def test_format_interaction_question_summarizes_script_like_content() -> None:
    question = """Please run this PowerShell snippet to verify the bare Claude path:
model = 'anthropic/claude-sonnet-4.6'
$resp = Invoke-RestMethod -Method Post -Uri 'https://openrouter.ai/api/v1/messages'
Write-Output $resp
"""

    rendered = format_interaction_question(question, lang="zh_cn")

    assert "PowerShell" in rendered
    assert "已简化显示" in rendered
    assert "Invoke-RestMethod -Method Post" not in rendered


def test_format_interaction_question_prefers_user_facing_display_text() -> None:
    rendered = format_interaction_question(
        "Write-Output 'raw internal probe'",
        lang="zh_cn",
        context={"display_question": "智能体想请你确认是否可以运行一段检测脚本。"},
    )

    assert rendered == "智能体想请你确认是否可以运行一段检测脚本。"


@pytest.mark.asyncio
async def test_approval_prompt_accepts_y_and_normalizes_to_approved(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["y", "quit"],
        )
        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        runtime = CliRuntimeStore(tmp_path / "device-runtime")
        runtime.ensure_root()
        runtime.write_pending_interaction(
            interaction_id="int_approval_y",
            question="Approve command execution: rm -rf /tmp/old",
            interaction_type="approval",
            interaction_level="high",
            interaction_phase="waiting",
            interaction_context={"command": "rm -rf /tmp/old", "action_type": "file_delete", "risk_level": "high"},
        )
        owner_manager = FakeOwnerManager()
        runner = OwnerBackedAttachedRunner(session=session, runtime=runtime, owner_manager=owner_manager)

        exit_code = await runner.run()

        assert exit_code == 0
        answer_payload = runtime.read_interaction_answer()
        assert answer_payload["interaction_id"] == "int_approval_y"
        assert answer_payload["answer"] == "approved"
        output = transcript.getvalue()
        assert "rm -rf /tmp/old" in output
        assert "file_delete" in output


@pytest.mark.asyncio
async def test_approval_prompt_accepts_n_and_normalizes_to_denied(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["n", "quit"],
        )
        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        runtime = CliRuntimeStore(tmp_path / "device-runtime")
        runtime.ensure_root()
        runtime.write_pending_interaction(
            interaction_id="int_approval_n",
            question="Approve command execution: ssh root@server",
            interaction_type="approval",
            interaction_level="high",
            interaction_phase="waiting",
            interaction_context={"command": "ssh root@server", "action_type": "ssh_request", "risk_level": "high"},
        )
        owner_manager = FakeOwnerManager()
        runner = OwnerBackedAttachedRunner(session=session, runtime=runtime, owner_manager=owner_manager)

        exit_code = await runner.run()

        assert exit_code == 0
        answer_payload = runtime.read_interaction_answer()
        assert answer_payload["interaction_id"] == "int_approval_n"
        assert answer_payload["answer"] == "denied"


@pytest.mark.asyncio
async def test_approval_prompt_rejects_invalid_input_then_accepts_valid(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["maybe", "yse", "yes", "quit"],
        )
        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)
        runtime = CliRuntimeStore(tmp_path / "device-runtime")
        runtime.ensure_root()
        runtime.write_pending_interaction(
            interaction_id="int_approval_retry",
            question="Approve command execution: bash detect.sh",
            interaction_type="approval",
            interaction_level="high",
            interaction_phase="waiting",
            interaction_context={"command": "bash detect.sh", "action_type": "terminal_shell_spawn", "risk_level": "high"},
        )
        owner_manager = FakeOwnerManager()
        runner = OwnerBackedAttachedRunner(session=session, runtime=runtime, owner_manager=owner_manager)

        exit_code = await runner.run()

        assert exit_code == 0
        answer_payload = runtime.read_interaction_answer()
        assert answer_payload["interaction_id"] == "int_approval_retry"
        assert answer_payload["answer"] == "approved"
        output = transcript.getvalue()
        # Should have shown the "Please enter Y or N" hint for invalid inputs
        assert "Please enter Y" in output or "请输入 Y" in output


@pytest.mark.asyncio
async def test_background_owner_submits_queued_answer_after_restart(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[],
        )
        await session.ensure_manifest()
        state = await session.ensure_registered()
        state.display_language = "en_us"
        session.state_store.save(state)

        task_id = await session.create_task("inspect runtime issue")
        interaction = await client.post(
            "/internal/interactions",
            headers={"X-Internal-Token": "internal-token"},
            json={
                "task_id": task_id,
                "type": "info_request",
                "question": "Need more context from the device?",
                "context": {"phase": "decision", "level": "info"},
                "target_responder": "device_local_only",
            },
        )
        assert interaction.status_code == 200, interaction.text
        interaction_id = interaction.json()["id"]

        runtime = CliRuntimeStore(tmp_path / "device-runtime")
        runtime.ensure_root()
        runtime.write_pending_interaction(
            interaction_id=interaction_id,
            question="Need more context from the device?",
            interaction_type="info_request",
            interaction_level="info",
            interaction_phase="decision",
        )
        runtime.write_interaction_answer(
            interaction_id=interaction_id,
            answer="Collected logs before restart",
        )

        async def fast_poll_once(*, wait: int | None = None) -> dict:
            del wait
            await asyncio.sleep(0.01)
            return {}

        async def no_active_task() -> dict:
            return {"has_active_task": False}

        async def no_shutdown(*, mark_offline: bool) -> None:
            del mark_offline
            return None

        session.poll_once = fast_poll_once  # type: ignore[method-assign]
        session.check_active_task = no_active_task  # type: ignore[method-assign]
        session.shutdown = no_shutdown  # type: ignore[method-assign]

        owner = BackgroundOwner(
            session=session,
            runtime=runtime,
            bootstrap_mode="restore",
        )
        owner_task = asyncio.create_task(owner.run())

        # Wait until the answer file is consumed (owner submitted it)
        # rather than using a fixed sleep, to avoid CI timing flakiness.
        for _ in range(200):
            if not runtime.read_interaction_answer().get("interaction_id"):
                break
            await asyncio.sleep(0.02)

        runtime.request_disconnect()
        await asyncio.wait_for(owner_task, timeout=5.0)

        interaction_detail = await client.get(
            f"/internal/interactions/{interaction_id}",
            headers={"X-Internal-Token": "internal-token"},
        )
        assert interaction_detail.status_code == 200, interaction_detail.text
        assert interaction_detail.json()["status"] == "answered"
        assert interaction_detail.json()["answer"] == "Collected logs before restart"


@pytest.mark.asyncio
async def test_owner_backed_runner_clears_session_status_after_rendering_completion(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[],
        )
        await session.ensure_manifest()
        await session.ensure_registered()

        runtime = CliRuntimeStore(tmp_path / "device-runtime")
        runtime.ensure_root()
        runtime.write_session_status(
            phase="result",
            level="info",
            message="Task reported complete",
        )
        runtime.write_task_completion(
            {
                "notif_task_id": "task_done_001",
                "notif_task_status": "succeeded",
                "notif_task_message": "Verified Python version.",
            }
        )

        runner = OwnerBackedAttachedRunner(
            session=session,
            runtime=runtime,
            owner_manager=FakeOwnerManager(),
        )

        assert runner._handle_task_completion() is True
        assert runtime.read_task_completion() == {}
        assert runtime.read_session_status() == {}
        assert "Verified Python version." in transcript.getvalue()


@pytest.mark.asyncio
async def test_cli_executes_polled_command_and_submits_result(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[],
        )

        await session.ensure_manifest()
        state = await session.ensure_registered()

        enqueue = await client.post(
            f"/internal/devices/{state.device_id}/commands",
            headers={"X-Internal-Token": "internal-token"},
            json={
                "command": "printf cli-ok",
                "timeout_seconds": 30,
                "intent": "Print cli-ok",
            },
        )
        assert enqueue.status_code == 200, enqueue.text
        command_id = enqueue.json()["command_id"]

        payload = await session.poll_once(wait=0)
        assert payload["command_id"] == command_id
        handled = await session.process_poll_payload(payload)
        assert handled is True

        result = await client.get(
            f"/internal/commands/{command_id}/result",
            headers={"X-Internal-Token": "internal-token"},
        )
        assert result.status_code == 200, result.text
        assert result.json()["status"] == "completed"
        assert result.json()["stdout"] == "cli-ok"
        assert "Print cli-ok" in transcript.getvalue()


@pytest.mark.asyncio
async def test_cli_answers_interaction_and_renders_task_completion(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, context):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=["Collected the latest logs"],
        )

        await session.ensure_manifest()
        state = await session.ensure_registered()
        task_id = await session.create_task("inspect runtime issue")

        interaction = await client.post(
            "/internal/interactions",
            headers={"X-Internal-Token": "internal-token"},
            json={
                "task_id": task_id,
                "type": "info_request",
                "question": "Need more context from the device?",
                "context": {"phase": "decision", "level": "info"},
                "target_responder": "device_local_only",
            },
        )
        assert interaction.status_code == 200, interaction.text
        interaction_id = interaction.json()["id"]

        poll = await session.poll_once(wait=0)
        assert poll["interaction_id"] == interaction_id
        handled = await session.process_poll_payload(poll)
        assert handled is True

        interaction_detail = await client.get(
            f"/internal/interactions/{interaction_id}",
            headers={"X-Internal-Token": "internal-token"},
        )
        assert interaction_detail.status_code == 200, interaction_detail.text
        assert interaction_detail.json()["status"] == "answered"
        assert interaction_detail.json()["answer"] == "Collected the latest logs"

        async with context.session_factory() as db:
            task = await db.get(Task, task_id)
            assert task is not None
            task.status = "succeeded"
            task.completed_at = utcnow()
            await db.commit()

        completion_poll = await session.poll_once(wait=0)
        assert completion_poll["notif_task_id"] == task_id
        handled = await session.process_poll_payload(completion_poll)
        assert handled is True
        assert "Task reported complete" in transcript.getvalue()
        assert "Task budget" in transcript.getvalue()
        assert "Amount budget" in transcript.getvalue()
        assert "Referral code" in transcript.getvalue()
        assert "Invite code" not in transcript.getvalue()


@pytest.mark.asyncio
async def test_cli_ignores_duplicate_completion_notification_after_first_render(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, context):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[],
        )

        await session.ensure_manifest()
        state = await session.ensure_registered()
        task_id = await session.create_task("check python version")
        assert task_id

        async with context.session_factory() as db:
            task = await db.get(Task, task_id)
            assert task is not None
            task.status = "succeeded"
            task.completed_at = utcnow()
            await db.commit()

        first_poll = await session.poll_once(wait=0)
        assert first_poll["notif_task_id"] == task_id
        handled = await session.process_poll_payload(first_poll)
        assert handled is True

        second_poll = await session.poll_once(wait=0)
        assert "notif_task_id" not in second_poll


@pytest.mark.asyncio
async def test_cli_create_task_shows_actionable_budget_exhausted_message(tmp_path: Path) -> None:
    settings = Settings(
        database_url=f"sqlite+aiosqlite:///{tmp_path / 'test.db'}",
        admin_token="admin-token",
        internal_token="internal-token",
        email_delivery_mode="memory",
        activation_code_ttl_hours=24,
        device_token_ttl_days=7,
        poll_interval_seconds=1,
        result_max_chars=1024 * 1024,
        default_device_budget_usd=50.0,
        default_device_max_tasks=0,
    )

    async with platform_client(settings) as (client, _):
        invite_code = await create_invite_code(client)
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=transcript,
            answers=[],
        )

        await session.ensure_manifest()
        state = await session.ensure_registered()

        created_task_id = await session.create_task("one more task")

        assert created_task_id == ""
        assert "remaining task budget" in transcript.getvalue().lower()


@pytest.mark.asyncio
async def test_cli_self_register_sends_hardware_id_candidates(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        "aima_cli.session.build_os_profile",
        lambda: {
            "os_type": "Linux",
            "os_version": "Ubuntu 24.04",
            "arch": "x86_64",
            "hostname": "demo-host",
            "machine_id": "legacy-machine-id",
            "hardware_id": "hw-stable-001",
            "hardware_id_candidates": ["hw-stable-001", "hw-legacy-001"],
            "package_managers": ["apt"],
            "shell": "bash",
        },
    )

    client = httpx.AsyncClient(base_url="http://test")
    api = DeviceApiClient(platform_url="http://test", client=client)
    session = AttachedDeviceSession(
        api=api,
        options=DeviceClientOptions(
            platform_url="http://test",
            invite_code="invite-demo",
            state_file=str(tmp_path / "device-state.json"),
            wait_seconds=0,
        ),
        input_provider=ScriptedInputProvider([]),
        renderer=TerminalRenderer(stream=io.StringIO()),
        state_store=DeviceStateStore(tmp_path / "device-state.json"),
    )

    captured: dict[str, object] = {}

    async def fake_self_register(payload: dict[str, object]) -> dict[str, object]:
        captured.update(payload)
        return {
            "device_id": "dev_cli_test",
            "token": "tok_cli_test",
            "recovery_code": "rc_cli_test",
            "poll_interval_seconds": 5,
            "display_language": "en_us",
            "nickname": "CLI Host",
        }

    session.api.self_register = fake_self_register  # type: ignore[method-assign]
    try:
        state = await session._self_register_loop()
    finally:
        await client.aclose()

    assert state.device_id == "dev_cli_test"
    assert state.nickname == "CLI Host"
    assert captured["hardware_id"] == "hw-stable-001"
    assert captured["hardware_id_candidates"] == ["hw-stable-001", "hw-legacy-001"]
    assert captured["invite_code"] == "invite-demo"


@pytest.mark.asyncio
async def test_cli_reprompts_when_saved_recovery_code_is_invalid(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, _):
        transcript = io.StringIO()
        session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code="",
            transcript=transcript,
            answers=["fresh-recovery-code"],
        )
        await session.ensure_manifest()

        attempts: list[dict[str, object]] = []

        async def fake_self_register(payload: dict[str, object]) -> dict[str, object]:
            attempts.append(dict(payload))
            if len(attempts) == 1:
                raise AIMAApiError(
                    403,
                    "provided recovery_code is invalid for existing device credentials",
                    payload={
                        "detail": "provided recovery_code is invalid for existing device credentials",
                        "reauth_method": "recovery_code",
                        "recovery_code_status": "invalid",
                        "device_id": "dev_cli_test",
                    },
                )
            return {
                "device_id": "dev_cli_test",
                "token": "tok_cli_test",
                "recovery_code": "fresh-recovery-code",
                "poll_interval_seconds": 5,
                "display_language": "en_us",
                "nickname": "Recovered Host",
            }

        session.api.self_register = fake_self_register  # type: ignore[method-assign]
        state = await session._self_register_loop(recovery_code="stale-recovery-code")

    assert state.device_id == "dev_cli_test"
    assert state.nickname == "Recovered Host"
    assert len(attempts) == 2
    assert attempts[0]["recovery_code"] == "stale-recovery-code"
    assert attempts[1]["recovery_code"] == "fresh-recovery-code"
    assert "provided recovery_code is invalid for existing device credentials" in transcript.getvalue()


# ---------------------------------------------------------------------------
# Language preference tests
# ---------------------------------------------------------------------------


def test_localized_text_returns_correct_language() -> None:
    from aima_cli.manifest import LocalizedText

    lt = LocalizedText(text="你好 / Hello", zh_cn="你好", en_us="Hello")
    assert lt.localized("zh_cn") == "你好"
    assert lt.localized("en_us") == "Hello"
    assert lt.localized("") == "你好 / Hello"
    assert lt.localized("fr") == "你好 / Hello"


def test_localized_text_fallback_when_field_empty() -> None:
    from aima_cli.manifest import LocalizedText

    lt = LocalizedText(text="fallback", zh_cn="", en_us="Hello")
    assert lt.localized("zh_cn") == "fallback"
    assert lt.localized("en_us") == "Hello"


def test_renderer_lang_parameter() -> None:
    buf = io.StringIO()
    renderer = TerminalRenderer(stream=buf, lang="zh_cn")
    assert renderer.lang == "zh_cn"

    renderer2 = TerminalRenderer(stream=buf, lang="")
    assert renderer2.lang == ""


def test_device_state_display_language_roundtrip(tmp_path: Path) -> None:
    from aima_cli.state import DeviceState

    store = DeviceStateStore(tmp_path / "state.json")
    state = DeviceState(platform_url="http://test", device_id="dev_test", token="tok_test", recovery_code="rc")
    assert state.display_language == ""
    assert state.nickname == ""

    state.display_language = "zh_cn"
    state.nickname = "CLI Host"
    store.save(state)

    reloaded = store.load()
    assert reloaded is not None
    assert reloaded.display_language == "zh_cn"
    assert reloaded.nickname == "CLI Host"


def test_device_state_missing_display_language_defaults_empty(tmp_path: Path) -> None:
    """Old state files without display_language or nickname should still load."""
    state_file = tmp_path / "state.json"
    state_file.write_text(
        '{"platform_url": "http://test", "device_id": "dev_123", "token": "tok", "recovery_code": "rc"}'
    )

    store = DeviceStateStore(state_file)
    state = store.load()
    assert state is not None
    assert state.display_language == ""
    assert state.nickname == ""
    assert state.last_notified_task_id == ""
    assert state.device_id == "dev_123"


@pytest.mark.asyncio
async def test_cli_uses_browser_confirmation_for_bound_device_recovery(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, context):
        invite_code = await create_invite_code(client)

        initial_transcript = io.StringIO()
        initial_session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=initial_transcript,
            answers=[],
        )
        initial_state = await initial_session.ensure_registered()

        manager_session = await register_device_manager(
            client,
            context,
            email="cli-browser-recovery@example.com",
        )
        assert manager_session["authenticated"] is True

        flow_response = await client.post(
            "/api/v1/device-flows",
            json={
                "fingerprint": initial_session.fingerprint,
                "os_profile": initial_session.os_profile,
            },
        )
        assert flow_response.status_code == 200, flow_response.text
        bind_response = await client.post(
            "/api/v1/device-manager/devices/bind",
            json={"user_code": flow_response.json()["user_code"]},
        )
        assert bind_response.status_code == 200, bind_response.text
        assert bind_response.json()["device_id"] == initial_state.device_id

        state_path = tmp_path / "device-state.json"
        state_path.unlink()

        transcript = io.StringIO()
        recovery_session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code="",
            transcript=transcript,
            answers=[],
        )

        async def fake_open_browser(url: str) -> bool:
            user_code = parse_qs(urlparse(url).query).get("user_code", [""])[0]
            assert user_code
            asyncio.create_task(
                client.post(
                    "/api/v1/device-manager/devices/bind",
                    json={"user_code": user_code},
                )
            )
            return True

        recovery_session._open_browser_url = fake_open_browser  # type: ignore[method-assign]

        recovered = await recovery_session.ensure_registered()
        assert recovered.device_id == initial_state.device_id
        assert recovered.token
        assert recovered.recovery_code

        output = transcript.getvalue()
        assert (
            "Confirm Device Recovery in Browser" in output
            or "在浏览器中确认恢复设备" in output
        )
        assert (
            "Browser opened. Waiting for recovery confirmation..." in output
            or "浏览器已打开。正在等待恢复确认..." in output
        )


@pytest.mark.asyncio
async def test_cli_browser_recovery_retries_transient_poll_errors(tmp_path: Path) -> None:
    settings = build_settings(tmp_path / "test.db")

    async with platform_client(settings) as (client, context):
        invite_code = await create_invite_code(client)

        initial_session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code=invite_code,
            transcript=io.StringIO(),
            answers=[],
        )
        initial_state = await initial_session.ensure_registered()

        manager_session = await register_device_manager(
            client,
            context,
            email="cli-browser-recovery-retry@example.com",
        )
        assert manager_session["authenticated"] is True

        flow_response = await client.post(
            "/api/v1/device-flows",
            json={
                "fingerprint": initial_session.fingerprint,
                "os_profile": initial_session.os_profile,
            },
        )
        assert flow_response.status_code == 200, flow_response.text
        bind_response = await client.post(
            "/api/v1/device-manager/devices/bind",
            json={"user_code": flow_response.json()["user_code"]},
        )
        assert bind_response.status_code == 200, bind_response.text
        assert bind_response.json()["device_id"] == initial_state.device_id

        state_path = tmp_path / "device-state.json"
        state_path.unlink()

        recovery_session = build_session(
            client=client,
            tmp_path=tmp_path,
            invite_code="",
            transcript=io.StringIO(),
            answers=[],
        )

        async def fake_open_browser(url: str) -> bool:
            user_code = parse_qs(urlparse(url).query).get("user_code", [""])[0]
            assert user_code
            asyncio.create_task(
                client.post(
                    "/api/v1/device-manager/devices/bind",
                    json={"user_code": user_code},
                )
            )
            return True

        original_poll_device_flow = recovery_session.api.poll_device_flow
        poll_attempts = 0

        async def flaky_poll_device_flow(*, device_code: str) -> dict:
            nonlocal poll_attempts
            poll_attempts += 1
            if poll_attempts == 1:
                raise AIMAApiError(503, "temporary poll failure")
            return await original_poll_device_flow(device_code=device_code)

        recovery_session._open_browser_url = fake_open_browser  # type: ignore[method-assign]
        recovery_session.api.poll_device_flow = flaky_poll_device_flow  # type: ignore[method-assign]

        recovered = await recovery_session.ensure_registered()
        assert recovered.device_id == initial_state.device_id
        assert recovered.token
        assert recovered.recovery_code
        assert poll_attempts >= 2
