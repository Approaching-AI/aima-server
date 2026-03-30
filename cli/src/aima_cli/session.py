from __future__ import annotations

import argparse
import asyncio
import base64
import re
import uuid
import webbrowser
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Optional, Protocol

import httpx

from .api import AIMAApiError, DeviceApiClient
from .manifest import UXManifest
from .os_profile import build_fingerprint, build_os_profile
from .renderer import TerminalRenderer
from .runtime import run_device_command
from .state import DeviceState, DeviceStateStore


class InputProvider(Protocol):
    async def prompt(self, prompt: str) -> str:
        ...


class InputClosedError(RuntimeError):
    """Raised when interactive stdin closes during a prompt."""


class ConsoleInputProvider:
    async def prompt(self, prompt: str) -> str:
        try:
            return await asyncio.to_thread(input, prompt)
        except (EOFError, KeyboardInterrupt) as exc:
            raise InputClosedError("interactive input closed") from exc


class ScriptedInputProvider:
    def __init__(self, answers: list[str]) -> None:
        self.answers = list(answers)

    async def prompt(self, prompt: str) -> str:
        del prompt
        if not self.answers:
            return ""
        return self.answers.pop(0)


@dataclass
class DeviceClientOptions:
    platform_url: str
    invite_code: str = ""
    referral_code: str = ""
    worker_code: str = ""
    state_file: str = ""
    wait_seconds: int = 5


@dataclass
class TaskSubmission:
    description: str
    intake: dict[str, Any] = field(default_factory=dict)
    experience_search: dict[str, Any] = field(default_factory=dict)


class AttachedDeviceSession:
    _SOFTWARE_TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9._+-]{1,63}")
    _ENGLISH_SOFTWARE_CONTEXT_RE = re.compile(
        r"(?i)(install|setup|deploy|upgrade|repair|fix|check|debug|troubleshoot|diagnose)\s*$"
    )
    _CHINESE_SOFTWARE_CONTEXT_RE = re.compile(r"(安装|装|配置|部署|升级|修复|修一下|检查|排查|诊断)\s*$")
    _INSTALL_HINT_RE = re.compile(r"(?i)\b(install|setup|deploy|upgrade)\b|安装|配置|部署|升级")
    _REPAIR_HINT_RE = re.compile(r"(?i)\b(repair|fix|check|debug|troubleshoot|diagnose)\b|修复|检查|排查|诊断|升级一下|修一下")
    _VERIFY_HINT_RE = re.compile(r"(?i)\b(test|verify|validation|smoke\s*test|benchmark)\b|测试|验证|验收|跑测")
    _SOFTWARE_HINT_IGNORES = {
        "aima",
        "api",
        "assistant",
        "check",
        "debug",
        "deploy",
        "diagnose",
        "fix",
        "for",
        "from",
        "help",
        "install",
        "issue",
        "it",
        "its",
        "just",
        "latest",
        "machine",
        "me",
        "my",
        "need",
        "on",
        "our",
        "please",
        "problem",
        "repair",
        "run",
        "setup",
        "system",
        "task",
        "that",
        "the",
        "their",
        "these",
        "this",
        "those",
        "to",
        "use",
        "using",
        "version",
        "want",
        "we",
        "with",
        "you",
        "your",
    }
    _SECRET_PREFIXES = ("http", "www", "sk-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "glpat-", "xox")
    _KNOWN_SOFTWARE_PHRASES: tuple[tuple[re.Pattern[str], str], ...] = (
        (re.compile(r"(?i)\bopen[\s._-]*claw\b"), "openclaw"),
        (re.compile(r"(?i)\bdify\b"), "dify"),
        (re.compile(r"(?i)\bopen[\s._-]*webui\b"), "open-webui"),
        (re.compile(r"(?i)\bcomfy[\s._-]*ui\b"), "comfyui"),
        (re.compile(r"(?i)\bk[\s._-]*transformers\b"), "ktransformers"),
    )
    _KNOWN_SOFTWARE_TARGET_ALIASES = {
        "openclaw": "openclaw",
        "dify": "dify",
        "open-webui": "open-webui",
        "openwebui": "open-webui",
        "webui": "open-webui",
        "comfyui": "comfyui",
        "ktransformers": "ktransformers",
        "k-transformers": "ktransformers",
        "k_transformers": "ktransformers",
    }
    _KTRANSFORMERS_DEPLOYMENT_RE = re.compile(
        r"(?i)\b(model|deploy|deployment|serve|serving|load|gguf|awq|gptq|fp8|fp16|int4|int8)\b|模型|部署|加载|量化"
    )
    _KTRANSFORMERS_TEST_RE = re.compile(
        r"(?i)\b(test|verify|validation|smoke\s*test|benchmark|inference)\b|测试|验证|验收|推理|跑测"
    )
    _KTRANSFORMERS_MODEL_NAME_RE = re.compile(
        r"(?i)\b((?:qwen|llama|deepseek|mistral|mixtral|phi|gemma|baichuan|glm|internlm|yi)[a-z0-9._/-]*\s*\d+(?:\.\d+)?\s*[bm])\b"
    )
    _KTRANSFORMERS_MODEL_FORMATS: tuple[tuple[re.Pattern[str], str], ...] = (
        (re.compile(r"(?i)\bgguf\b"), "gguf"),
        (re.compile(r"(?i)\bawq\b"), "awq"),
        (re.compile(r"(?i)\bgptq\b"), "gptq"),
    )
    _KTRANSFORMERS_QUANTIZATION_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
        (re.compile(r"(?i)\bawq\b"), "awq"),
        (re.compile(r"(?i)\bgptq\b"), "gptq"),
        (re.compile(r"(?i)\bfp8\b"), "fp8"),
        (re.compile(r"(?i)\bfp16\b"), "fp16"),
        (re.compile(r"(?i)\bint4\b|\b4[- ]?bit\b"), "int4"),
        (re.compile(r"(?i)\bint8\b|\b8[- ]?bit\b"), "int8"),
    )
    _KTRANSFORMERS_GPU_RE = re.compile(
        r"(?i)\bgpu\b|\bcuda\b|\b(?:rtx\s*)?(?:4090|3090|5090|a100|h100|v100|l40s)\b|显卡|GPU|CUDA"
    )

    def __init__(
        self,
        *,
        api: DeviceApiClient,
        options: DeviceClientOptions,
        input_provider: InputProvider,
        renderer: TerminalRenderer,
        state_store: DeviceStateStore,
    ) -> None:
        self.api = api
        self.options = options
        self.input_provider = input_provider
        self.renderer = renderer
        self.state_store = state_store
        self.os_profile = build_os_profile()
        self.fingerprint = build_fingerprint(self.os_profile)
        self.hardware_id = str(self.os_profile.get("hardware_id") or "")
        self.hardware_id_candidates = [
            str(candidate)
            for candidate in (self.os_profile.get("hardware_id_candidates") or [])
            if str(candidate or "").strip()
        ]
        self.manifest: Optional[UXManifest] = None
        self.state: Optional[DeviceState] = None
        self.active_task_id: str = ""
        self.confirmed_active_task_id: str = ""
        self.disconnect_requested = False
        self.poll_interval_seconds = max(1, options.wait_seconds)

    async def ensure_manifest(self) -> UXManifest:
        payload = await self.api.fetch_go_manifest(
            schema_version="v1",
            referral_code=self.options.referral_code,
            worker_code=self.options.worker_code,
        )
        self.manifest = UXManifest.from_raw(payload)
        return self.manifest

    async def ensure_registered(self) -> DeviceState:
        if self.manifest is None:
            await self.ensure_manifest()

        loaded = self.state_store.load()
        if loaded is not None and loaded.platform_url.rstrip("/") == self.options.platform_url.rstrip("/"):
            self.state = loaded
            self.poll_interval_seconds = loaded.poll_interval_seconds or self.poll_interval_seconds
            try:
                active = await self.api.get_active_task(
                    device_id=loaded.device_id,
                    device_token=loaded.token,
                )
                if active.get("has_active_task"):
                    self.active_task_id = str(active.get("task_id") or "")
                return loaded
            except AIMAApiError as exc:
                if exc.status_code != 401 or not loaded.recovery_code:
                    raise

        registered = await self._self_register_loop(
            recovery_code=loaded.recovery_code if loaded else "",
        )
        self.state = registered
        return registered

    async def _self_register_loop(self, *, recovery_code: str = "") -> DeviceState:
        invite_code = self.options.invite_code.strip()
        referral_code = self.options.referral_code.strip()
        worker_code = self.options.worker_code.strip()
        current_recovery_code = recovery_code.strip()

        while True:
            payload = {
                "fingerprint": self.fingerprint,
                "hardware_id": self.hardware_id,
                "os_profile": self.os_profile,
            }
            if self.hardware_id_candidates:
                payload["hardware_id_candidates"] = self.hardware_id_candidates
            if current_recovery_code:
                payload["recovery_code"] = current_recovery_code
            if invite_code:
                payload["invite_code"] = invite_code
            if referral_code:
                payload["referral_code"] = referral_code
            if worker_code:
                payload["worker_enrollment_code"] = worker_code

            try:
                response = await self.api.self_register(payload)
            except AIMAApiError as exc:
                payload_data = exc.payload if isinstance(exc.payload, dict) else {}
                if (
                    exc.status_code == 409
                    and payload_data.get("reauth_method") == "browser_confirmation"
                ):
                    state = await self._complete_browser_recovery_flow(payload_data)
                    self.poll_interval_seconds = state.poll_interval_seconds
                    self.state_store.save(state)
                    return state
                detail = exc.detail
                if payload_data.get("reauth_method") == "recovery_code":
                    assert self.manifest is not None
                    prompt_reason = detail
                    if not current_recovery_code:
                        prompt_reason = self.manifest.text_localized(
                            "onboarding",
                            "recovery_missing_local_state",
                            self._lang,
                            "This device was previously registered but no local recovery code was found.",
                        )
                    current_recovery_code = await self._prompt_recovery_code(prompt_reason)
                    continue
                if ("invite_code" in detail or "worker_enrollment_code" in detail or "referral" in detail) and not invite_code:
                    invite_code = await self._prompt_invite_code(detail)
                    continue
                if "recovery_code" in detail:
                    assert self.manifest is not None
                    prompt_reason = detail
                    if not current_recovery_code:
                        prompt_reason = self.manifest.text_localized(
                            "onboarding",
                            "recovery_missing_local_state",
                            self._lang,
                            "This device was previously registered but no local recovery code was found.",
                        )
                    current_recovery_code = await self._prompt_recovery_code(prompt_reason)
                    continue
                raise

            state = DeviceState(
                platform_url=self.options.platform_url,
                device_id=str(response["device_id"]),
                token=str(response["token"]),
                recovery_code=str(response["recovery_code"]),
                referral_code=str(response.get("referral_code") or ""),
                share_text=str(response.get("share_text") or ""),
                poll_interval_seconds=int(response.get("poll_interval_seconds") or self.poll_interval_seconds),
                display_language=str(response.get("display_language") or ""),
            )
            self.poll_interval_seconds = state.poll_interval_seconds
            self.state_store.save(state)
            return state

    async def _open_browser_url(self, url: str) -> bool:
        return bool(await asyncio.to_thread(webbrowser.open, url))

    async def _complete_browser_recovery_flow(self, payload: dict[str, Any]) -> DeviceState:
        user_code = str(payload.get("user_code") or "")
        device_code = str(payload.get("device_code") or "")
        verification_uri = str(payload.get("verification_uri") or "")
        verification_uri_complete = str(payload.get("verification_uri_complete") or "")
        poll_interval = int(payload.get("interval") or 2)

        if not user_code or not device_code or not verification_uri:
            raise RuntimeError(
                "Server returned invalid recovery confirmation info."
                if self._lang == "en_us"
                else "服务器返回了无效的恢复确认信息。"
            )
        if not verification_uri_complete:
            verification_uri_complete = f"{verification_uri}?user_code={user_code}"

        self.renderer.line()
        self.renderer.info(
            "Confirm Device Recovery in Browser"
            if self._lang == "en_us"
            else "在浏览器中确认恢复设备"
        )
        self.renderer.info(
            f"1. {'Open in browser' if self._lang == 'en_us' else '在浏览器中打开'}: {verification_uri_complete}"
        )
        self.renderer.info(
            f"2. {'Enter device code' if self._lang == 'en_us' else '输入设备码'}: {user_code}"
        )
        self.renderer.info(
            "Please sign in with the original device manager account to confirm recovery."
            if self._lang == "en_us"
            else "请使用原来的 device manager 账号确认恢复。"
        )

        try:
            await self._open_browser_url(verification_uri_complete)
        except Exception:
            pass

        self.renderer.info(
            "Browser opened. Waiting for recovery confirmation..."
            if self._lang == "en_us"
            else "浏览器已打开。正在等待恢复确认..."
        )

        while True:
            try:
                poll = await self.api.poll_device_flow(device_code=device_code)
            except AIMAApiError as exc:
                if exc.status_code >= 500 or exc.status_code in {408, 429}:
                    await asyncio.sleep(max(1, poll_interval))
                    continue
                raise
            except httpx.HTTPError:
                await asyncio.sleep(max(1, poll_interval))
                continue
            status = str(poll.get("status") or "")
            if status == "pending":
                await asyncio.sleep(max(1, poll_interval))
                continue
            if status == "bound":
                state = DeviceState(
                    platform_url=self.options.platform_url,
                    device_id=str(poll["device_id"]),
                    token=str(poll["token"]),
                    recovery_code=str(poll["recovery_code"]),
                    referral_code=self.state.referral_code if self.state is not None else "",
                    share_text=self.state.share_text if self.state is not None else "",
                    poll_interval_seconds=int(poll.get("poll_interval_seconds") or self.poll_interval_seconds),
                    display_language=self.state.display_language if self.state is not None else "",
                )
                self.renderer.info(
                    "Browser confirmation complete. Device recovery succeeded."
                    if self._lang == "en_us"
                    else "浏览器已确认，设备恢复成功。"
                )
                return state
            if status == "expired":
                raise RuntimeError(
                    "Recovery confirmation expired. Please rerun the device entry command."
                    if self._lang == "en_us"
                    else "恢复确认已过期，请重新运行设备入口命令。"
                )
            if status == "denied":
                raise RuntimeError(
                    "Recovery confirmation was denied."
                    if self._lang == "en_us"
                    else "恢复确认被拒绝。"
                )
            raise RuntimeError(
                f"Unexpected recovery flow status: {status}"
                if self._lang == "en_us"
                else f"恢复流程返回了未预期状态: {status}"
            )

    async def _prompt_invite_code(self, reason: str = "") -> str:
        assert self.manifest is not None
        if reason:
            self.renderer.warn(reason)
        prompt = self.manifest.text_localized(
            "onboarding",
            "invite_prompt",
            self._lang,
            "Please enter your invite or worker code:",
        )
        answer = (await self.input_provider.prompt(f"{prompt}\n> ")).strip()
        if not answer:
            raise RuntimeError(
                self.manifest.text_localized(
                    "onboarding",
                    "invite_required",
                    self._lang,
                    "Invite or worker code is required",
                )
            )
        return answer

    async def _prompt_recovery_code(self, reason: str = "") -> str:
        assert self.manifest is not None
        if reason:
            self.renderer.warn(reason)
        prompt = self.manifest.text_localized(
            "onboarding",
            "recovery_prompt",
            self._lang,
            "Please enter your saved recovery code:",
        )
        answer = (await self.input_provider.prompt(f"{prompt}\n> ")).strip()
        if not answer:
            raise RuntimeError(
                self.manifest.text_localized(
                    "onboarding",
                    "recovery_required",
                    self._lang,
                    "Recovery code is required",
                )
            )
        return answer

    async def _with_reauth(self, call, *args, **kwargs):
        try:
            return await call(*args, **kwargs)
        except AIMAApiError as exc:
            if exc.status_code != 401 or self.state is None or not self.state.recovery_code:
                raise
            self.state = await self._self_register_loop(recovery_code=self.state.recovery_code)
            return await call(*args, **kwargs)

    async def create_task(self, submission: str | TaskSubmission) -> str:
        assert self.state is not None
        if isinstance(submission, TaskSubmission):
            description = submission.description
            intake = submission.intake
            experience_search = submission.experience_search
        else:
            description = submission
            intake = {}
            experience_search = {}
        try:
            response = await self._with_reauth(
                self.api.create_task,
                device_id=self.state.device_id,
                device_token=self.state.token,
                description=description,
                intake=intake,
                experience_search=experience_search,
            )
        except (AIMAApiError, httpx.HTTPError) as exc:
            should_recover = not isinstance(exc, AIMAApiError) or exc.status_code >= 500 or exc.status_code == 409
            if not should_recover:
                if isinstance(exc, AIMAApiError) and (
                    exc.status_code == 402 or "device budget exhausted" in exc.detail.casefold()
                ):
                    self.renderer.error(self._task_budget_exhausted_message())
                    return ""
                raise
            active = await self.check_active_task()
            active_task_id = str(active.get("task_id") or "")
            if not active.get("has_active_task") or not active_task_id:
                raise
            self.active_task_id = active_task_id
            self.confirmed_active_task_id = active_task_id
            notice = (
                f"Task submit response was interrupted; attached to {active_task_id}."
                if self._lang == "en_us"
                else f"任务提交响应中断，已附着到 {active_task_id}。"
            )
            self.renderer.warn(notice)
            return active_task_id
        self.active_task_id = str(response["task_id"])
        self.confirmed_active_task_id = self.active_task_id
        return self.active_task_id

    async def submit_feedback(self, *, feedback_type: str, description: str = "", task_id: str = "") -> dict:
        assert self.state is not None
        return await self._with_reauth(
            self.api.submit_feedback,
            device_id=self.state.device_id,
            device_token=self.state.token,
            feedback_type=feedback_type,
            description=description,
            os_profile=self.os_profile,
            task_id=task_id,
        )

    async def cancel_task(self, task_id: str) -> dict:
        assert self.state is not None
        response = await self._with_reauth(
            self.api.cancel_task,
            device_id=self.state.device_id,
            device_token=self.state.token,
            task_id=task_id,
        )
        self.active_task_id = ""
        self.confirmed_active_task_id = ""
        return response

    async def poll_once(self, *, wait: Optional[int] = None) -> dict:
        assert self.state is not None
        payload = await self._with_reauth(
            self.api.poll,
            device_id=self.state.device_id,
            device_token=self.state.token,
            wait=self.poll_interval_seconds if wait is None else wait,
        )
        self.poll_interval_seconds = int(payload.get("poll_interval_seconds") or self.poll_interval_seconds)
        if self.state is not None:
            self.state.poll_interval_seconds = self.poll_interval_seconds
            self.state_store.save(self.state)
        task_id = str(payload.get("notif_task_id") or "")
        if (
            self.state is not None
            and task_id
            and task_id == self.state.last_notified_task_id
        ):
            filtered_payload = dict(payload)
            for key in list(filtered_payload.keys()):
                if key.startswith("notif_"):
                    filtered_payload.pop(key, None)
            return filtered_payload
        return payload

    async def process_poll_payload(self, payload: dict) -> bool:
        if payload.get("interaction_id"):
            return await self._handle_interaction(payload)
        if payload.get("command_id"):
            await self._execute_command_chain(payload)
            return True
        if payload.get("notif_task_id"):
            assert self.manifest is not None
            self._record_task_completion_notification(payload)
            self.renderer.render_task_completion(self.manifest, payload)
            return True
        return False

    async def _handle_interaction(self, payload: dict) -> bool:
        assert self.manifest is not None
        assert self.state is not None
        interaction_id = str(payload["interaction_id"])
        question = str(payload.get("question") or "")
        interaction_type = str(payload.get("interaction_type") or "")
        if interaction_type == "notification":
            self.renderer.render_notification(
                question,
                phase=str(payload.get("interaction_phase") or ""),
                level=str(payload.get("interaction_level") or ""),
            )
            await self._with_reauth(
                self.api.respond_interaction,
                device_id=self.state.device_id,
                device_token=self.state.token,
                interaction_id=interaction_id,
                answer="displayed",
            )
            return True

        block = self.manifest.block("interaction_prompt")
        self.renderer.render_interaction(question, block, context=payload.get("interaction_context"))
        lang = self._lang
        answer = (await self.input_provider.prompt(f"{block.prompt.localized(lang)}\n> ")).strip()
        if not answer:
            self.renderer.warn(
                block.context_text_localized(
                    "skip_notice",
                    lang,
                    "Skipped; the question stays pending.",
                )
            )
            return True
        await self._with_reauth(
            self.api.respond_interaction,
            device_id=self.state.device_id,
            device_token=self.state.token,
            interaction_id=interaction_id,
            answer=answer,
        )
        self.renderer.info(
            block.context_text_localized(
                "queued_notice",
                lang,
                self.manifest.text_localized(
                    "runtime",
                    "answer_queued",
                    lang,
                    "Your answer was queued and the background session is continuing.",
                ),
            )
        )
        return True

    async def _execute_command_chain(
        self,
        initial_payload: dict,
        *,
        status_callback: Callable[[str, str, str], Awaitable[None]] | None = None,
    ) -> None:
        payload = initial_payload
        while payload.get("command_id") and payload.get("command"):
            ack = await self._execute_single_command(payload, status_callback=status_callback)
            if not ack.get("next_command_id") or not ack.get("next_command"):
                return
            payload = {
                "command_id": ack["next_command_id"],
                "command": ack["next_command"],
                "command_encoding": ack.get("next_command_encoding"),
                "command_timeout_seconds": ack.get("next_command_timeout_seconds"),
                "command_intent": ack.get("next_command_intent"),
            }

    async def _execute_single_command(
        self,
        payload: dict,
        *,
        status_callback: Callable[[str, str, str], Awaitable[None]] | None = None,
    ) -> dict:
        assert self.state is not None
        assert self.manifest is not None
        command_text = str(payload.get("command") or "")
        if payload.get("command_encoding") == "base64":
            command_text = base64.b64decode(command_text).decode("utf-8")
        timeout_seconds = int(payload.get("command_timeout_seconds") or 300)
        command_id = str(payload["command_id"])
        command_intent = str(payload.get("command_intent") or "")
        if command_intent:
            self.renderer.render_notification(command_intent, phase="action", level="info")
            if status_callback is not None:
                await status_callback("action", "info", command_intent)
        else:
            fallback = "正在执行下一步。" if self._lang == "zh_cn" else "Running the next authorized step."
            self.renderer.render_notification(fallback, phase="action", level="info")
            if status_callback is not None:
                await status_callback("action", "info", fallback)

        async def progress_callback(stdout: str, stderr: str, message: str) -> bool:
            if status_callback is not None:
                await status_callback("waiting", "info", message)
            response = await self._with_reauth(
                self.api.submit_progress,
                device_id=self.state.device_id,
                device_token=self.state.token,
                command_id=command_id,
                stdout=stdout,
                stderr=stderr,
                message=message,
            )
            return bool(response.get("cancel_requested"))

        result = await run_device_command(
            command=command_text,
            timeout_seconds=timeout_seconds,
            progress_callback=progress_callback,
            task_id=self.active_task_id or "task-unknown",
            command_id=command_id,
            execution_root=self.state_store.path.parent / "executions",
            intent=command_intent,
        )
        return await self._with_reauth(
            self.api.submit_result,
            device_id=self.state.device_id,
            device_token=self.state.token,
            command_id=command_id,
            exit_code=result.exit_code,
            stdout=result.stdout,
            stderr=result.stderr,
            result_id=str(uuid.uuid4()),
        )

    async def check_active_task(self) -> dict:
        assert self.state is not None
        payload = await self._with_reauth(
            self.api.get_active_task,
            device_id=self.state.device_id,
            device_token=self.state.token,
        )
        if payload.get("has_active_task"):
            self.active_task_id = str(payload.get("task_id") or "")
        else:
            self.active_task_id = ""
            self.confirmed_active_task_id = ""
        return payload

    async def run_until_idle(self, *, max_polls: int = 100) -> None:
        for _ in range(max_polls):
            payload = await self.poll_once(wait=0)
            handled = await self.process_poll_payload(payload)
            if payload.get("notif_task_id"):
                return
            active = await self.check_active_task()
            if not active.get("has_active_task") and not handled:
                # Task may have completed between poll_once and
                # check_active_task; do one more poll to pick up the
                # completion notification before returning.
                final = await self.poll_once(wait=0)
                await self.process_poll_payload(final)
                return
            if not handled and active.get("has_active_task"):
                await asyncio.sleep(0)

    @property
    def _lang(self) -> str:
        return self.renderer.lang

    def _localized_text(self, raw: Any, fallback: str = "") -> str:
        if isinstance(raw, dict):
            lang = self._lang
            if lang and lang in raw and raw[lang]:
                return str(raw[lang])
            return str(raw.get("text") or fallback)
        if isinstance(raw, str):
            return raw
        return fallback

    def _normalize_target_hint(self, value: str) -> str:
        cleaned = re.sub(r"[^a-z0-9._+-]+", "_", value.lower()).strip("._-")
        canonical = self._KNOWN_SOFTWARE_TARGET_ALIASES.get(cleaned, cleaned)
        return canonical[:120]

    def _infer_software_hint(self, *values: str) -> str:
        for raw_value in values:
            normalized = raw_value.strip()
            if not normalized:
                continue
            for pattern, canonical_target in self._KNOWN_SOFTWARE_PHRASES:
                if pattern.search(normalized):
                    return canonical_target
            best_token = ""
            best_canonical_token = ""
            best_score = -1
            for match in self._SOFTWARE_TOKEN_RE.finditer(normalized):
                token = match.group(0)
                lowered = token.lower()
                if lowered in self._SOFTWARE_HINT_IGNORES:
                    continue
                if lowered.startswith(self._SECRET_PREFIXES):
                    continue

                start, end = match.span()
                before = normalized[max(0, start - 32):start]
                after = normalized[end:min(len(normalized), end + 16)]
                canonical_target = self._KNOWN_SOFTWARE_TARGET_ALIASES.get(
                    self._normalize_target_hint(token)
                )
                score = 0
                if start == 0:
                    score += 2
                if self._ENGLISH_SOFTWARE_CONTEXT_RE.search(before):
                    score += 4
                if self._CHINESE_SOFTWARE_CONTEXT_RE.search(before):
                    score += 4
                if after and not after[0].isalnum():
                    score += 1
                if "." in token or "-" in token or "_" in token:
                    score += 1
                if canonical_target:
                    score += 3

                if score > best_score:
                    best_token = token
                    best_canonical_token = canonical_target or ""
                    best_score = score

            if best_token and best_score >= 2:
                return best_canonical_token or self._normalize_target_hint(best_token)
        return ""

    def _record_task_completion_notification(self, payload: dict[str, Any]) -> None:
        task_id = str(payload.get("notif_task_id") or "")
        if not task_id:
            return
        if self.state is not None:
            self.state.last_notified_task_id = task_id
            referral_code = str(payload.get("notif_referral_code") or "")
            share_text = str(payload.get("notif_share_text") or "")
            if referral_code:
                self.state.referral_code = referral_code
            if share_text:
                self.state.share_text = share_text
            self.state_store.save(self.state)
        if self.active_task_id == task_id:
            self.active_task_id = ""
            self.confirmed_active_task_id = ""

    def _task_budget_exhausted_message(self) -> str:
        if self._lang == "zh_cn":
            return "当前设备额度已用完，暂时不能创建新任务。请在控制台补充额度，或换一台仍有额度的设备后重试。"
        return "This device has no remaining task budget. Add budget in the console or use a device with remaining budget, then retry."

    def _infer_task_type_hint(self, *, mode: str, user_request: str, description: str) -> str:
        if mode == "install_software":
            return "software_install"
        if mode == "repair_software":
            return "software_repair"
        if mode == "install_deploy_ktransformers":
            return "software_install"
        if mode == "test_ktransformers":
            return "verification"

        combined = " ".join(value for value in (user_request, description) if value)
        if self._INSTALL_HINT_RE.search(combined):
            return "software_install"
        if self._REPAIR_HINT_RE.search(combined):
            return "software_repair"
        if self._VERIFY_HINT_RE.search(combined):
            return "verification"
        return "general_ops"

    def _infer_ktransformers_task_hints(
        self,
        *,
        mode: str,
        user_request: str,
        description: str,
        software_hint: str,
        task_type_hint: str,
    ) -> tuple[str, dict[str, Any], dict[str, Any]]:
        if software_hint != "ktransformers":
            return task_type_hint, {}, {}

        combined = "\n".join(part for part in (user_request, description) if part).strip()
        if not combined:
            return task_type_hint, {}, {}

        effective_task_type = task_type_hint
        test_match = self._KTRANSFORMERS_TEST_RE.search(combined)
        deploy_match = self._KTRANSFORMERS_DEPLOYMENT_RE.search(combined)
        if mode == "test_ktransformers":
            effective_task_type = "verification"
        elif mode == "install_deploy_ktransformers":
            effective_task_type = "software_install"
        elif test_match and (
            effective_task_type == "verification"
            or deploy_match is None
            or test_match.start() <= deploy_match.start()
        ):
            effective_task_type = "verification"

        if effective_task_type == "software_install":
            deployment_kind = "ktransformers_model_deploy"
        elif effective_task_type == "verification":
            deployment_kind = "ktransformers_test"
        elif test_match:
            effective_task_type = "verification"
            deployment_kind = "ktransformers_test"
        elif deploy_match:
            effective_task_type = "software_install"
            deployment_kind = "ktransformers_model_deploy"
        else:
            return effective_task_type, {}, {}

        intake_hints: dict[str, Any] = {"deployment_kind": deployment_kind}
        search_hints: dict[str, Any] = {"deployment_kind": deployment_kind}

        model_name_match = self._KTRANSFORMERS_MODEL_NAME_RE.search(combined)
        if model_name_match:
            model_name = " ".join(model_name_match.group(1).split()).lower()
            intake_hints["model_name"] = model_name
            search_hints["model_name"] = model_name

        for pattern, model_format in self._KTRANSFORMERS_MODEL_FORMATS:
            if pattern.search(combined):
                intake_hints["model_format"] = model_format
                search_hints["model_format"] = model_format
                break

        for pattern, quantization in self._KTRANSFORMERS_QUANTIZATION_PATTERNS:
            if pattern.search(combined):
                intake_hints["quantization"] = quantization
                search_hints["quantization"] = quantization
                break

        if self._KTRANSFORMERS_GPU_RE.search(combined):
            intake_hints["gpu_required"] = True
            search_hints["gpu_required"] = True

        return effective_task_type, intake_hints, search_hints

    def _build_task_submission(
        self,
        *,
        description: str,
        user_request: str,
        mode: str,
    ) -> TaskSubmission:
        software_hint = self._infer_software_hint(user_request, description)
        task_type_hint = self._infer_task_type_hint(
            mode=mode,
            user_request=user_request,
            description=description,
        )
        intake: dict[str, Any] = {
            "user_request": user_request,
            "renderer": "cli",
        }
        if mode:
            intake["mode"] = mode
        if software_hint:
            intake["software_hint"] = software_hint
        if task_type_hint == "software_repair" and user_request:
            intake["problem_hint"] = user_request[:1000]

        experience_search: dict[str, Any] = {}
        if task_type_hint:
            experience_search["task_type_hint"] = task_type_hint
        if software_hint:
            experience_search["target_hint"] = software_hint
        if task_type_hint == "software_repair" and user_request:
            experience_search["error_message_hint"] = user_request[:1000]

        task_type_hint, deployment_intake_hints, deployment_search_hints = self._infer_ktransformers_task_hints(
            mode=mode,
            user_request=user_request,
            description=description,
            software_hint=software_hint,
            task_type_hint=task_type_hint,
        )
        experience_search["task_type_hint"] = task_type_hint
        if deployment_intake_hints:
            intake.update(deployment_intake_hints)
        if deployment_search_hints:
            experience_search.update(deployment_search_hints)

        return TaskSubmission(
            description=description,
            intake=intake,
            experience_search=experience_search,
        )

    def _task_menu_action_options(self, block) -> list[Any]:
        return [option for option in block.options if option.id != "feedback"]

    def _task_menu_feedback_option(self, block) -> Any | None:
        for option in block.options:
            if option.id == "feedback":
                return option
        return None

    async def _build_guided_task_request(self, *, block, option) -> TaskSubmission:
        guided_flows = block.context.get("guided_flows") or {}
        flow = guided_flows.get(option.id) or {}
        steps = list(flow.get("steps") or [])
        if not steps:
            label = option.label.localized(self._lang) or option.value
            return self._build_task_submission(
                description=label,
                user_request=label,
                mode=option.id,
            )

        missing_answer = self._localized_text(
            block.context.get("guided_missing_answer"),
            "Not provided",
        )
        summary_parts: list[str] = []
        primary_answer = ""

        for index, step in enumerate(steps, start=1):
            prompt = self._localized_text(step.get("prompt"), f"Step {index}")
            summary_label = self._localized_text(step.get("summary_label"), f"Step {index}")
            default_answer = self._localized_text(step.get("default_answer"), "")
            self.renderer.line()
            self.renderer.info(prompt)
            answer = (await self.input_provider.prompt("> ")).strip()
            normalized = answer or default_answer or missing_answer
            if not primary_answer:
                primary_answer = normalized
            summary_parts.append(f"{summary_label}: {normalized}")

        label = option.label.localized(self._lang) or option.value
        description = f"{label}: {primary_answer}" if primary_answer else label
        user_request = primary_answer
        if len(summary_parts) > 1:
            user_request = "\n".join(summary_parts)
        return self._build_task_submission(
            description=description.strip(),
            user_request=(user_request or label).strip(),
            mode=option.id,
        )

    async def prompt_task_menu_once(self) -> Optional[TaskSubmission | str]:
        assert self.manifest is not None
        lang = self._lang
        self._refresh_window_title()
        block = self.manifest.block("task_menu")
        action_options = self._task_menu_action_options(block)
        feedback_option = self._task_menu_feedback_option(block)
        example_lines: list[str] = []
        for example in list(block.context.get("freeform_examples") or []):
            localized = self._localized_text(example)
            if localized:
                example_lines.append(localized)
        footer = (
            "[Enter] Submit request   [d] Disconnect   [Ctrl+C] Exit UI"
            if lang == "en_us"
            else "[Enter] 提交需求   [d] 断开设备   [Ctrl+C] 退出界面"
        )
        self.renderer.render_task_intake(
            block,
            example_lines=example_lines,
            footer=footer,
        )
        try:
            answer = (await self.input_provider.prompt(self.renderer.input_cursor())).strip()
        except InputClosedError:
            return "__detach__"
        if not answer:
            return None
        if answer.lower() in {"exit", "quit"}:
            return "__detach__"
        if answer.lower() in {"d", "disconnect"}:
            return "__disconnect__"
        if answer == "0" and feedback_option is not None:
            return "feedback"
        if answer.isdigit():
            index = int(answer) - 1
            if 0 <= index < len(action_options):
                try:
                    return await self._build_guided_task_request(
                        block=block,
                        option=action_options[index],
                    )
                except InputClosedError:
                    return "__detach__"
        elif block.supports_freeform:
            return self._build_task_submission(
                description=answer,
                user_request=answer,
                mode="freeform",
            )
        self.renderer.warn(
            block.context_text_localized(
                "invalid_selection_notice",
                lang,
                "Type your request directly, press 0 for feedback, or use the local bind / disconnect controls.",
            )
        )
        return None

    async def prompt_feedback_once(self, *, related_task_id: str = "") -> Optional[str]:
        assert self.manifest is not None
        block = self.manifest.block("feedback_menu")
        self.renderer.render_menu(block)
        try:
            answer = (await self.input_provider.prompt("> ")).strip().lower()
        except InputClosedError:
            return "__detach__"
        if not answer or answer in {"3", "g", "go_back"}:
            return None
        if answer in {"1", "b", "bug_report"}:
            feedback_type = "bug_report"
        elif answer in {"2", "s", "suggestion"}:
            feedback_type = "suggestion"
        else:
            return None
        try:
            description = await self.input_provider.prompt(f"{block.prompt.localized(self._lang)}\n> ")
        except InputClosedError:
            return "__detach__"
        await self.submit_feedback(
            feedback_type=feedback_type,
            description=description.strip(),
            task_id=related_task_id,
        )
        return feedback_type

    async def _prompt_language_selection(self) -> str:
        self.renderer.line()
        self.renderer.info("选择显示语言 / Select display language:")
        self.renderer.info("1. 中文")
        self.renderer.info("2. English")
        answer = (await self.input_provider.prompt("> ")).strip()
        if answer in {"2", "en", "english", "English"}:
            return "en_us"
        return "zh_cn"

    async def _ensure_language(self) -> None:
        assert self.state is not None
        if self.state.display_language:
            self.renderer.lang = self.state.display_language
            self._refresh_window_title()
            return
        lang = await self._prompt_language_selection()
        self.state.display_language = lang
        self.state_store.save(self.state)
        self.renderer.lang = lang
        self._refresh_window_title()
        try:
            await self._with_reauth(
                self.api.update_language,
                device_id=self.state.device_id,
                device_token=self.state.token,
                display_language=lang,
            )
        except Exception:
            pass

    def _refresh_window_title(self) -> None:
        if self.manifest is None:
            return
        self.renderer.set_window_title(
            self.manifest.text_localized(
                "context",
                "window_title",
                self._lang,
                "AIMA灵机：一条命令，AI 接管运维",
            )
        )

    async def _prompt_active_task_action(self, active: dict) -> Optional[str]:
        task_id = str(active.get("task_id") or "")
        status = str(active.get("status") or "")
        target = str(active.get("target") or "")
        assert self.manifest is not None
        block = self.manifest.block("active_task_resolution")
        prompt = block.prompt.localized(self._lang)
        invalid = block.context_text_localized("invalid_selection_notice", self._lang, "Please choose 1 / 2 or d.")
        self.renderer.render_active_task_resolution(
            block,
            task_id=task_id,
            status=status,
            target=target,
        )

        try:
            answer = (await self.input_provider.prompt(f"{prompt}\n> ")).strip().lower()
        except InputClosedError:
            return "__detach__"
        if answer in {"1", "r", "resume"}:
            return "resume"
        if answer in {"2", "c", "cancel"}:
            return "cancel"
        if answer in {"exit", "quit"}:
            return "__detach__"
        if answer in {"d", "disconnect"}:
            return "__disconnect__"
        self.renderer.warn(invalid)
        return None

    async def run_attached(self) -> int:
        try:
            await self.ensure_manifest()
            await self.ensure_registered()
            await self._ensure_language()
            self.renderer.info("AIMA CLI connected." if self._lang == "en_us" else "AIMA CLI 已连接。")

            while True:
                active = await self.check_active_task()
                if active.get("has_active_task"):
                    if self.active_task_id != self.confirmed_active_task_id:
                        choice = await self._prompt_active_task_action(active)
                        if choice is None:
                            continue
                        if choice == "__detach__":
                            return 0
                        if choice == "__disconnect__":
                            self.disconnect_requested = True
                            return 0
                        if choice == "cancel":
                            await self.cancel_task(self.active_task_id)
                            notice = (
                                "已取消未完成任务。"
                                if self._lang == "zh_cn"
                                else "Cancelled the unfinished task."
                            )
                            self.renderer.info(notice)
                            continue
                        self.confirmed_active_task_id = self.active_task_id
                    await self.run_until_idle()
                    continue

                choice = await self.prompt_task_menu_once()
                if choice is None:
                    continue
                if choice == "__detach__":
                    return 0
                if choice == "__disconnect__":
                    self.disconnect_requested = True
                    return 0
                if choice == "feedback":
                    feedback_result = await self.prompt_feedback_once()
                    if feedback_result == "__detach__":
                        return 0
                    if feedback_result == "__disconnect__":
                        self.disconnect_requested = True
                        return 0
                    continue
                created_task_id = await self.create_task(choice)
                if not created_task_id:
                    continue
                await self.run_until_idle()
        except InputClosedError:
            return 0

    async def shutdown(self, *, mark_offline: bool) -> None:
        if not mark_offline or self.state is None:
            return
        try:
            await self._with_reauth(
                self.api.mark_offline,
                device_id=self.state.device_id,
                device_token=self.state.token,
            )
        except Exception:
            pass


def build_options_from_args(args: argparse.Namespace) -> DeviceClientOptions:
    return DeviceClientOptions(
        platform_url=args.platform_url.rstrip("/"),
        invite_code=args.invite_code or "",
        referral_code=args.referral_code or "",
        worker_code=args.worker_code or "",
        state_file=args.state_file or "",
        wait_seconds=args.wait_seconds,
    )
