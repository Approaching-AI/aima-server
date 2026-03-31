from __future__ import annotations

import asyncio
import os

from .api import AIMAApiError
from .owner_runtime import CliOwnerProcessManager, CliRuntimeStore
from .session import AttachedDeviceSession, InputClosedError


class BackgroundOwner:
    def __init__(
        self,
        *,
        session: AttachedDeviceSession,
        runtime: CliRuntimeStore,
        bootstrap_mode: str,
    ) -> None:
        self.session = session
        self.runtime = runtime
        self.bootstrap_mode = bootstrap_mode
        self.explicit_disconnect_requested = False

    @property
    def _lang(self) -> str:
        return self.session.renderer.lang or "zh_cn"

    def _text(self, section: str, field: str, fallback: str) -> str:
        assert self.session.manifest is not None
        return self.session.manifest.text_localized(section, field, self._lang, fallback)

    def _completion_title(self, payload: dict) -> str:
        assert self.session.manifest is not None
        block = self.session.manifest.block("task_completion")
        if payload.get("notif_task_status") and str(payload["notif_task_status"]) != "succeeded":
            return block.context_text_localized("failure_title", self._lang, "Task failed")
        return block.context_text_localized("success_title", self._lang, "Task reported complete")

    async def _status_callback(self, phase: str, level: str, message: str) -> None:
        self.runtime.write_session_status(
            phase=phase,
            level=level,
            message=message,
            active_task_id=self.session.active_task_id,
        )
        assert self.session.state is not None
        self.runtime.write_owner_heartbeat(
            pid=os.getpid(),
            device_id=self.session.state.device_id,
            phase=phase,
            active_task_id=self.session.active_task_id,
        )

    async def _auto_ack_notification(self, payload: dict) -> None:
        assert self.session.state is not None
        interaction_id = str(payload.get("interaction_id") or "")
        question = str(payload.get("question") or "")
        phase = str(payload.get("interaction_phase") or "update")
        level = str(payload.get("interaction_level") or "info")
        if question:
            self.runtime.write_session_status(
                phase=phase,
                level=level,
                message=question,
                active_task_id=self.session.active_task_id,
            )
        await self.session._with_reauth(
            self.session.api.respond_interaction,
            device_id=self.session.state.device_id,
            device_token=self.session.state.token,
            interaction_id=interaction_id,
            answer="displayed",
        )

    async def _try_submit_answer(self) -> bool:
        answer_payload = self.runtime.read_interaction_answer()
        interaction_id = str(answer_payload.get("interaction_id") or "")
        if not interaction_id:
            return False
        answer = str(answer_payload.get("answer") or "")
        pending_payload = self.runtime.read_pending_interaction()
        pending_interaction_id = str(pending_payload.get("interaction_id") or "")
        try:
            assert self.session.state is not None
            await self.session._with_reauth(
                self.session.api.respond_interaction,
                device_id=self.session.state.device_id,
                device_token=self.session.state.token,
                interaction_id=interaction_id,
                answer=answer,
            )
            queued_notice = self._text(
                "runtime",
                "answer_queued",
                "Your answer was queued and the background session is continuing.",
            )
            self.runtime.write_session_status(
                phase=str(pending_payload.get("interaction_phase") or "waiting"),
                level=str(pending_payload.get("interaction_level") or "info"),
                message=queued_notice,
                active_task_id=self.session.active_task_id,
            )
            if pending_interaction_id == interaction_id:
                self.runtime.clear_pending_interaction()
            else:
                self.runtime.clear_interaction_answer()
            return True
        except AIMAApiError as exc:
            if exc.status_code in {404, 409}:
                if pending_interaction_id == interaction_id:
                    self.runtime.clear_pending_interaction()
                else:
                    self.runtime.clear_interaction_answer()
                return True
            warning = (
                "回答发送失败，后台会继续重试。"
                if self._lang == "zh_cn"
                else "Failed to send the answer; the background session will retry."
            )
            self.runtime.write_session_status(
                phase="waiting",
                level="warning",
                message=warning,
                active_task_id=self.session.active_task_id,
            )
            await asyncio.sleep(1)
            return True

    async def run(self) -> int:
        await self.session.ensure_manifest()
        state = await self.session.ensure_registered()
        self.session.renderer.lang = state.display_language or "zh_cn"
        self.runtime.ensure_root()
        self.runtime.clear_disconnect_request()
        self.runtime.write_owner_pid(os.getpid())
        self.runtime.write_session_status(
            phase="waiting",
            level="info",
            message=self._text(
                "background",
                "session_started" if self.bootstrap_mode == "fresh" else "session_restored",
                "Background session started and waiting for work.",
            ),
            active_task_id=self.session.active_task_id,
        )
        self.runtime.write_owner_heartbeat(
            pid=os.getpid(),
            device_id=state.device_id,
            phase="waiting",
            active_task_id=self.session.active_task_id,
        )

        try:
            while True:
                if self.runtime.disconnect_requested():
                    self.explicit_disconnect_requested = True
                    break
                if await self._try_submit_answer():
                    continue

                self.runtime.write_owner_heartbeat(
                    pid=os.getpid(),
                    device_id=state.device_id,
                    phase="polling",
                    active_task_id=self.session.active_task_id,
                )
                payload = await self.session.poll_once(wait=10)

                if self.runtime.disconnect_requested():
                    self.explicit_disconnect_requested = True
                    break

                interaction_id = str(payload.get("interaction_id") or "")
                if interaction_id:
                    interaction_type = str(payload.get("interaction_type") or "")
                    if interaction_type == "notification":
                        await self._auto_ack_notification(payload)
                    else:
                        self.runtime.write_pending_interaction(
                            interaction_id=interaction_id,
                            question=str(payload.get("question") or ""),
                            interaction_type=interaction_type,
                            interaction_level=str(payload.get("interaction_level") or "info"),
                            interaction_phase=str(payload.get("interaction_phase") or "waiting"),
                            interaction_context=payload.get("interaction_context"),
                        )
                        self.runtime.write_session_status(
                            phase=str(payload.get("interaction_phase") or "waiting"),
                            level=str(payload.get("interaction_level") or "info"),
                            message=str(payload.get("question") or ""),
                            active_task_id=self.session.active_task_id,
                        )
                    await asyncio.sleep(1)
                    continue

                self.runtime.clear_pending_interaction()

                if payload.get("command_id"):
                    await self.session._execute_command_chain(payload, status_callback=self._status_callback)
                    continue

                if payload.get("notif_task_id"):
                    self.session._record_task_completion_notification(payload)
                    self.runtime.write_task_completion(payload)
                    self.runtime.write_session_status(
                        phase="result",
                        level="info" if str(payload.get("notif_task_status") or "") == "succeeded" else "warning",
                        message=self._completion_title(payload),
                        active_task_id="",
                    )
                    continue

                await self.session.check_active_task()
                self.runtime.write_owner_heartbeat(
                    pid=os.getpid(),
                    device_id=state.device_id,
                    phase="waiting",
                    active_task_id=self.session.active_task_id,
                )
        finally:
            self.runtime.clear_interaction_answer()
            self.runtime.clear_pending_interaction()
            self.runtime.paths.owner_heartbeat_path.unlink(missing_ok=True)
            self.runtime.clear_owner_pid()
            self.runtime.clear_disconnect_request()
            if self.explicit_disconnect_requested:
                await self.session.shutdown(mark_offline=True)
                self.runtime.clear_ephemeral_files()
        return 0


class OwnerBackedAttachedRunner:
    def __init__(
        self,
        *,
        session: AttachedDeviceSession,
        runtime: CliRuntimeStore,
        owner_manager: CliOwnerProcessManager,
        interaction_retry_after_seconds: float = 30.0,
    ) -> None:
        self.session = session
        self.runtime = runtime
        self.owner_manager = owner_manager
        self.interaction_retry_after_seconds = max(0.0, interaction_retry_after_seconds)
        self.attach_last_status_key = ""
        self.attach_last_interaction_id = ""
        self.attach_deferred_interaction_id = ""
        self.attach_deferred_interaction_retry_at = 0.0
        self.attach_last_completion_id = ""

    @property
    def _lang(self) -> str:
        return self.session.renderer.lang

    def _text(self, section: str, field: str, fallback: str) -> str:
        assert self.session.manifest is not None
        return self.session.manifest.text_localized(section, field, self._lang, fallback)

    async def _start_or_restart_owner(self, *, restart: bool) -> bool:
        assert self.session.state is not None
        if restart:
            await asyncio.to_thread(self.owner_manager.stop)
        bootstrap_mode = "restore"
        if self.runtime.read_owner_pid() is None and not self.runtime.read_owner_heartbeat():
            bootstrap_mode = "fresh"
        try:
            await asyncio.to_thread(self.owner_manager.start, bootstrap_mode=bootstrap_mode)
        except Exception:
            return False
        return await asyncio.to_thread(
            self.owner_manager.wait_until_healthy,
            expected_device_id=self.session.state.device_id,
            timeout_seconds=5.0,
        )

    async def _ensure_owner_running(self) -> bool:
        assert self.session.manifest is not None
        assert self.session.state is not None
        had_runtime_before = self.runtime.read_owner_pid() is not None or bool(self.runtime.read_owner_heartbeat())
        detail = await asyncio.to_thread(
            self.owner_manager.health_detail,
            expected_device_id=self.session.state.device_id,
        )
        if detail is None:
            return True
        if not self.session.active_task_id:
            self.session.active_task_id = str((await self.session.check_active_task()).get("task_id") or "")
        if had_runtime_before:
            self.session.renderer.warn(
                self._text(
                    "background",
                    "unhealthy_restart",
                    "Background session looks unhealthy; restarting local owner.",
                )
            )
        started = await self._start_or_restart_owner(restart=had_runtime_before)
        if started:
            return True
        self.session.renderer.error(
            self._text(
                "background",
                "restart_failed",
                "Failed to restart the background session. Please run /go again after checking the local logs.",
            )
        )
        return False

    def _show_status_if_changed(self) -> bool:
        payload = self.runtime.read_session_status()
        message = str(payload.get("message") or "")
        if not message:
            return False
        key = "|".join(
            [
                str(payload.get("phase") or ""),
                str(payload.get("level") or ""),
                message,
                str(payload.get("active_task_id") or ""),
            ]
        )
        if key == self.attach_last_status_key:
            return False
        self.attach_last_status_key = key
        self.session.renderer.render_notification(
            message,
            phase=str(payload.get("phase") or ""),
            level=str(payload.get("level") or ""),
        )
        return True

    async def _handle_pending_interaction(self) -> bool:
        payload = self.runtime.read_pending_interaction()
        interaction_id = str(payload.get("interaction_id") or "")
        if not interaction_id:
            self.attach_deferred_interaction_id = ""
            self.attach_deferred_interaction_retry_at = 0.0
            return False
        now = asyncio.get_running_loop().time()
        if interaction_id == self.attach_last_interaction_id:
            return False
        if (
            interaction_id == self.attach_deferred_interaction_id
            and now < self.attach_deferred_interaction_retry_at
        ):
            return False
        assert self.session.manifest is not None
        block = self.session.manifest.block("interaction_prompt")
        question = str(payload.get("question") or "")
        interaction_type = str(payload.get("interaction_type") or "")
        interaction_context = payload.get("interaction_context")

        is_approval = interaction_type == "approval"
        if is_approval:
            self.session.renderer.render_approval(interaction_context, question)
        else:
            self.session.renderer.render_interaction(question, block, context=interaction_context)

        if is_approval:
            _APPROVE_INPUTS = ("y", "yes", "approve", "approved", "ok")
            _DENY_INPUTS = ("n", "no", "deny", "denied", "reject", "rejected")
            approval_prompt = block.context_text_localized(
                "approval_prompt",
                self._lang,
                "Approval required. Enter Y to approve or N to deny:",
            )
            approval_required_notice = block.context_text_localized(
                "approval_required_notice",
                self._lang,
                "This approval cannot be skipped. Enter Y or N.",
            )
            approval_auto_denied_notice = block.context_text_localized(
                "approval_auto_denied_notice",
                self._lang,
                "Too many invalid inputs. This approval was denied.",
            )
            answer = ""
            for _attempt in range(5):
                try:
                    raw = (await self.session.input_provider.prompt(f"{approval_prompt}\n> ")).strip()
                except InputClosedError:
                    raise
                if not raw:
                    self.session.renderer.warn(approval_required_notice)
                    continue
                lowered = raw.lower()
                if lowered in _APPROVE_INPUTS:
                    answer = "approved"
                    break
                elif lowered in _DENY_INPUTS:
                    answer = "denied"
                    break
                else:
                    self.session.renderer.warn(approval_required_notice)
            else:
                answer = "denied"
                self.session.renderer.warn(approval_auto_denied_notice)
        else:
            try:
                prompt_text = f"{block.prompt.localized(self._lang)}\n> "
                answer = (await self.session.input_provider.prompt(prompt_text)).strip()
            except InputClosedError:
                raise
            if not answer:
                self.attach_deferred_interaction_id = interaction_id
                self.attach_deferred_interaction_retry_at = now + self.interaction_retry_after_seconds
                self.session.renderer.warn(
                    block.context_text_localized(
                        "skip_notice",
                        self._lang,
                        "Skipped; the question stays pending.",
                    )
                )
                return True
        self.attach_last_interaction_id = interaction_id
        self.attach_deferred_interaction_id = ""
        self.attach_deferred_interaction_retry_at = 0.0
        self.runtime.write_interaction_answer(interaction_id=interaction_id, answer=answer)
        queued_notice = block.context_text_localized(
            "queued_notice",
            self._lang,
            self._text(
                "runtime",
                "answer_queued",
                "Your answer was queued and the background session is continuing.",
            ),
        )
        self.runtime.write_session_status(
            phase=str(payload.get("interaction_phase") or "waiting"),
            level=str(payload.get("interaction_level") or "info"),
            message=queued_notice,
            active_task_id=self.session.active_task_id,
        )
        self.session.renderer.info(queued_notice)
        return True

    def _handle_task_completion(self) -> bool:
        payload = self.runtime.read_task_completion()
        task_id = str(payload.get("task_id") or "")
        if not task_id:
            return False
        if task_id == self.attach_last_completion_id:
            return False
        self.attach_last_completion_id = task_id
        assert self.session.manifest is not None
        self.session.renderer.render_task_completion(
            self.session.manifest,
            {
                "notif_task_id": task_id,
                "notif_task_status": payload.get("task_status"),
                "notif_budget_tasks_remaining": payload.get("budget_tasks_remaining"),
                "notif_budget_tasks_total": payload.get("budget_tasks_total"),
                "notif_budget_usd_remaining": payload.get("budget_usd_remaining"),
                "notif_budget_usd_total": payload.get("budget_usd_total"),
                "notif_referral_code": payload.get("referral_code"),
                "notif_share_text": payload.get("share_text"),
                "notif_task_message": payload.get("task_message"),
            },
        )
        self.runtime.clear_task_completion()
        self.runtime.clear_session_status()
        return True

    async def _explicit_disconnect(self) -> None:
        await asyncio.to_thread(self.owner_manager.request_disconnect)
        stopped = await asyncio.to_thread(self.owner_manager.wait_for_stop, timeout_seconds=5.0)
        if not stopped:
            await asyncio.to_thread(self.owner_manager.stop)
            await asyncio.to_thread(self.owner_manager.wait_for_stop, timeout_seconds=1.0)
        await self.session.shutdown(mark_offline=True)
        self.runtime.clear_ephemeral_files()

    async def run(self) -> int:
        await self.session.ensure_manifest()
        await self.session.ensure_registered()
        await self.session._ensure_language()
        self.session.renderer.info("AIMA CLI connected." if self._lang == "en_us" else "AIMA CLI 已连接。")

        if not await self._ensure_owner_running():
            return 1

        try:
            while True:
                if not await self._ensure_owner_running():
                    return 1
                self._handle_task_completion()
                if await self._handle_pending_interaction():
                    continue
                self._show_status_if_changed()

                active = await self.session.check_active_task()
                if active.get("has_active_task"):
                    if self.session.active_task_id != self.session.confirmed_active_task_id:
                        choice = await self.session._prompt_active_task_action(active)
                        if choice is None:
                            continue
                        if choice == "__detach__":
                            return 0
                        if choice == "__disconnect__":
                            await self._explicit_disconnect()
                            return 0
                        if choice == "cancel":
                            await self.session.cancel_task(self.session.active_task_id)
                            notice = (
                                "已取消未完成任务。"
                                if self._lang == "zh_cn"
                                else "Cancelled the unfinished task."
                            )
                            self.session.renderer.info(notice)
                            continue
                        self.session.confirmed_active_task_id = self.session.active_task_id
                    await asyncio.sleep(1)
                    continue

                choice = await self.session.prompt_task_menu_once()
                if choice is None:
                    continue
                if choice == "__detach__":
                    return 0
                if choice == "__disconnect__":
                    await self._explicit_disconnect()
                    return 0
                if choice == "feedback":
                    feedback_result = await self.session.prompt_feedback_once()
                    if feedback_result == "__detach__":
                        return 0
                    if feedback_result == "__disconnect__":
                        await self._explicit_disconnect()
                        return 0
                    continue
                self.runtime.clear_task_completion()
                self.runtime.clear_session_status()
                created_task_id = await self.session.create_task(choice)
                if not created_task_id:
                    continue
        except InputClosedError:
            return 0
