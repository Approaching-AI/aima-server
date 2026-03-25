from __future__ import annotations

import sys
from typing import TextIO

from .manifest import ManifestBlock, UXManifest


_NOTIFICATION_PREFIXES = {
    "zh_cn": {"update": "更新", "result": "结果", "waiting": "等待", "action": "操作", "warning": "警告", "error": "错误"},
    "en_us": {"update": "Update", "result": "Result", "waiting": "Waiting", "action": "Action", "warning": "Warning", "error": "Error"},
}


class TerminalRenderer:
    def __init__(self, *, stream: TextIO | None = None, lang: str = "") -> None:
        self.stream = stream or sys.stdout
        self.lang = lang

    def _l(self, localized_text) -> str:
        return localized_text.localized(self.lang)

    def line(self, text: str = "") -> None:
        self.stream.write(text + "\n")
        self.stream.flush()

    def set_window_title(self, title: str) -> None:
        if not title:
            return
        if hasattr(self.stream, "isatty") and not self.stream.isatty():
            return
        self.stream.write(f"\033]0;{title}\007")
        self.stream.flush()

    def info(self, text: str) -> None:
        self.line(text)

    def warn(self, text: str) -> None:
        self.line(f"Warning: {text}")

    def error(self, text: str) -> None:
        self.line(f"Error: {text}")

    def render_entrypoint(self, manifest: UXManifest) -> None:
        block = manifest.block("entrypoint")
        self.line(self._l(block.title))
        if block.subtitle.text:
            self.line(self._l(block.subtitle))
        for command in block.commands:
            self.line(f"[{self._l(command.label)}] {command.command}")
        if block.footer.text:
            self.line(self._l(block.footer))

    def render_menu(
        self,
        block: ManifestBlock,
        *,
        extra_lines: list[str] | None = None,
        option_lines: list[str] | None = None,
        footer_override: str | None = None,
    ) -> None:
        self.line()
        if block.title.text:
            self.line(self._l(block.title))
        if block.subtitle.text:
            self.line(self._l(block.subtitle))
        if option_lines is not None:
            for line in option_lines:
                self.line(line)
        else:
            for index, option in enumerate(block.options, start=1):
                self.line(f"{index}. {self._l(option.label)}")
        for line in extra_lines or []:
            self.line(line)
        footer = footer_override
        if footer is None and block.footer.text:
            footer = self._l(block.footer)
        if footer:
            self.line(footer)

    def render_task_menu(
        self,
        block: ManifestBlock,
        *,
        option_lines: list[str],
        disconnect_label: str,
    ) -> None:
        footer = (
            "[Enter] 提交需求   [d] 断开设备   [Ctrl+C] 退出界面"
            if self.lang == "zh_cn"
            else "[Enter] Submit   [d] Disconnect   [Ctrl+C] Exit UI"
        )
        self.render_menu(
            block,
            option_lines=option_lines,
            extra_lines=[f"d. {disconnect_label}"],
            footer_override=footer,
        )

    def render_active_task_resolution(
        self,
        block: ManifestBlock,
        *,
        task_id: str,
        status: str = "",
        target: str = "",
    ) -> None:
        task_label = block.context_text_localized("task_id_label", self.lang, "Task ID")
        status_label = block.context_text_localized("status_label", self.lang, "Status")
        target_label = block.context_text_localized("target_label", self.lang, "Target")
        self.line()
        if block.title.text:
            self.line(self._l(block.title))
        self.line(f"{task_label}: {task_id}")
        if status:
            self.line(f"{status_label}: {status}")
        if target:
            self.line(f"{target_label}: {target}")
        self.line()
        if len(block.options) > 0:
            self.line(f"1. {self._l(block.options[0].label)}")
        if len(block.options) > 1:
            self.line(f"2. {self._l(block.options[1].label)}")
        if len(block.options) > 2:
            self.line(f"d. {self._l(block.options[2].label)}")

    def render_interaction(self, question: str, block: ManifestBlock) -> None:
        self.line()
        title = self._l(block.title)
        if title:
            self.line(f"{title}: {question}")
        else:
            self.line(question)

    def render_notification(self, message: str, *, phase: str | None = None, level: str | None = None) -> None:
        prefixes = _NOTIFICATION_PREFIXES.get(self.lang, {})
        prefix = prefixes.get("update", "Update")
        if phase == "result":
            prefix = prefixes.get("result", "Result")
        elif phase == "waiting":
            prefix = prefixes.get("waiting", "Waiting")
        elif phase == "action":
            prefix = prefixes.get("action", "Action")
        if level == "warning":
            prefix = prefixes.get("warning", "Warning")
        elif level == "error":
            prefix = prefixes.get("error", "Error")
        self.line(f"[{prefix}] {message}")

    def render_task_completion(self, manifest: UXManifest, payload: dict) -> None:
        block = manifest.block("task_completion")
        lang = self.lang
        self.line()
        title = block.context_text_localized("success_title", lang, self._l(block.title) or "Task reported complete")
        if payload.get("notif_task_status") and str(payload["notif_task_status"]) != "succeeded":
            title = block.context_text_localized("failure_title", lang, "Task failed")
        self.line(title)
        if block.subtitle.text:
            self.line(self._l(block.subtitle))
        if payload.get("notif_task_status"):
            status_label = "状态" if lang == "zh_cn" else "Status"
            self.line(f"{status_label}: {payload['notif_task_status']}")
        if payload.get("notif_task_message"):
            message_label = "说明" if lang == "zh_cn" else "Message"
            self.line(f"{message_label}: {payload['notif_task_message']}")
        if payload.get("notif_budget_tasks_remaining") is not None or payload.get("notif_budget_tasks_total") is not None:
            budget_label = block.context_text_localized("budget_tasks_label", lang, "Task budget")
            remaining = payload.get("notif_budget_tasks_remaining") or 0
            total = payload.get("notif_budget_tasks_total") or 0
            budget_value = f"剩余 {remaining} / 总量 {total}" if lang == "zh_cn" else f"{remaining} / {total} remaining"
            self.line(f"{budget_label}: {budget_value}")
        if payload.get("notif_budget_usd_remaining") is not None or payload.get("notif_budget_usd_total") is not None:
            amount_label = block.context_text_localized("budget_amount_label", lang, "Amount budget")
            remaining_usd = float(payload.get("notif_budget_usd_remaining") or 0.0)
            total_usd = float(payload.get("notif_budget_usd_total") or 0.0)
            amount_value = (
                f"剩余 ${remaining_usd:.2f} / 总额 ${total_usd:.2f}"
                if lang == "zh_cn"
                else f"${remaining_usd:.2f} / ${total_usd:.2f} remaining"
            )
            self.line(f"{amount_label}: {amount_value}")
        if payload.get("notif_referral_code"):
            share_heading = block.context_text_localized("share_heading", lang, "")
            if share_heading:
                self.line(share_heading)
            referral_label = "推荐码" if lang == "zh_cn" else "Referral code"
            self.line(f"{referral_label}: {payload['notif_referral_code']}")
        if payload.get("notif_share_text"):
            share_label = "分享文案" if lang == "zh_cn" else "Share text"
            self.line(f"{share_label}: {payload['notif_share_text']}")
