from __future__ import annotations

import os
import re
import sys
from typing import TextIO

from .manifest import ManifestBlock, UXManifest


_NOTIFICATION_PREFIXES = {
    "zh_cn": {"update": "更新", "result": "结果", "waiting": "等待", "action": "操作", "warning": "警告", "error": "错误"},
    "en_us": {"update": "Update", "result": "Result", "waiting": "Waiting", "action": "Action", "warning": "Warning", "error": "Error"},
}

_INTERACTION_POWERSHELL_RE = re.compile(
    r"(?im)\b(Invoke-RestMethod|Write-Output|ConvertTo-Json|Start-Process|Read-Host|Get-[A-Za-z]+|Set-[A-Za-z]+)\b|"
    r"(^|\s)\$env:|(^|\s)\$[A-Za-z_][A-Za-z0-9_]*"
)
_INTERACTION_SHELL_RE = re.compile(
    r"(?im)^(#!/|curl\b|bash\b|sh\b|zsh\b|sudo\b|chmod\b|export\b|apt(-get)?\b|brew\b|npm\b|pnpm\b|yarn\b|python3?\b)"
)
_INTERACTION_JSON_RE = re.compile(r"^\s*[\[{]")
_INTERACTION_ASSIGNMENT_RE = re.compile(r"^\s*[$A-Za-z_][A-Za-z0-9_:. -]*\s*=")


def _shorten_text(text: str, limit: int = 88) -> str:
    stripped = text.strip()
    if len(stripped) <= limit:
        return stripped
    return stripped[: max(0, limit - 3)].rstrip() + "..."


def _interaction_line_looks_code_like(line: str) -> bool:
    stripped = line.strip()
    if not stripped:
        return False
    if stripped.startswith(("```", "{", "[", "PS ", ">", "$ ", "#!/")):
        return True
    if _INTERACTION_ASSIGNMENT_RE.match(stripped):
        return True
    if _INTERACTION_POWERSHELL_RE.search(stripped):
        return True
    if _INTERACTION_SHELL_RE.search(stripped):
        return True
    if sum(stripped.count(ch) for ch in "{}[]()=;|$`") >= 3:
        return True
    return False


def _extract_interaction_lead_line(question: str) -> str:
    for raw_line in question.splitlines():
        line = raw_line.strip()
        if not line or _interaction_line_looks_code_like(line):
            continue
        return line.rstrip(":：")
    return ""


def _interaction_question_kind(question: str) -> str:
    stripped = question.strip()
    if _INTERACTION_JSON_RE.match(stripped) and any(token in stripped for token in ('":', "{", "[")):
        return "json"
    if _INTERACTION_POWERSHELL_RE.search(question):
        return "powershell"
    if _INTERACTION_SHELL_RE.search(question):
        return "shell"
    if "\n" in question:
        return "technical"
    return "plain"


def _should_simplify_interaction(question: str) -> bool:
    stripped = question.strip()
    if not stripped:
        return False
    lines = [line for line in stripped.splitlines() if line.strip()]
    line_count = len(lines)
    char_count = len(stripped)
    if line_count <= 3 and char_count <= 180 and not any(_interaction_line_looks_code_like(line) for line in lines):
        return False
    if line_count >= 6 or char_count >= 260:
        return True
    return any(_interaction_line_looks_code_like(line) for line in lines) and (line_count > 1 or char_count > 140)


def format_interaction_question(
    question: str,
    *,
    lang: str = "",
    context: dict | None = None,
) -> str:
    if isinstance(context, dict):
        for key in ("display_question", "user_facing_question"):
            value = context.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()

    if not _should_simplify_interaction(question):
        return question

    kind = _interaction_question_kind(question)
    lead = _extract_interaction_lead_line(question)
    if lang == "en_us":
        headline = {
            "powershell": "The agent wants you to review a PowerShell script or command.",
            "shell": "The agent wants you to review a shell script or command.",
            "json": "The agent wants you to review a config or JSON snippet.",
            "technical": "The agent is asking about a longer technical snippet.",
        }.get(kind, "The agent is asking about a longer technical snippet.")
        focus_prefix = "Focus"
        note = "Simplified for display; the full technical text is still preserved in the background."
    else:
        headline = {
            "powershell": "智能体想让你确认一段 PowerShell 脚本或命令。",
            "shell": "智能体想让你确认一段 Shell 脚本或命令。",
            "json": "智能体想让你确认一段配置或 JSON 内容。",
            "technical": "智能体发来了一段较长的技术内容，想请你确认或补充信息。",
        }.get(kind, "智能体发来了一段较长的技术内容，想请你确认或补充信息。")
        focus_prefix = "重点"
        note = "已简化显示，后台仍保留完整技术细节。"

    lines = [headline]
    if lead:
        lines.append(f"{focus_prefix}: {_shorten_text(lead)}")
    lines.append(note)
    return "\n".join(lines)


class TerminalRenderer:
    def __init__(self, *, stream: TextIO | None = None, lang: str = "") -> None:
        self.stream = stream or sys.stdout
        self.lang = lang

    def _l(self, localized_text) -> str:
        return localized_text.localized(self.lang)

    def _supports_ansi(self) -> bool:
        isatty = getattr(self.stream, "isatty", None)
        return bool(callable(isatty) and isatty() and not os.environ.get("NO_COLOR"))

    def _style(self, text: str, *codes: str) -> str:
        if not text or not self._supports_ansi():
            return text
        return f"\033[{';'.join(codes)}m{text}\033[0m"

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

    def render_task_intake(
        self,
        block: ManifestBlock,
        *,
        example_lines: list[str],
        footer: str = "",
    ) -> None:
        self.line()
        if block.title.text:
            self.line(self._style(self._l(block.title), "1"))
        if block.subtitle.text:
            self.line(self._style(self._l(block.subtitle), "2"))
        if example_lines:
            self.line()
            hint = block.context_text_localized("freeform_hint", self.lang, "")
            if hint:
                self.line(self._style(hint, "2"))
            for line in example_lines:
                self.line(self._style(f"- {line}", "2"))
        if footer:
            self.line()
            self.line(self._style(footer, "2"))
        if block.prompt.text:
            self.line()
            self.line(self._style(self._l(block.prompt), "1", "36"))

    def input_cursor(self) -> str:
        return f"{self._style('>', '1', '36')} "

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

    def render_interaction(self, question: str, block: ManifestBlock, *, context: dict | None = None) -> None:
        self.line()
        title = self._l(block.title)
        display_question = format_interaction_question(question, lang=self.lang, context=context)
        if title:
            if "\n" in display_question:
                self.line(f"{title}:")
                for line in display_question.splitlines():
                    self.line(line)
            else:
                self.line(f"{title}: {display_question}")
        else:
            self.line(display_question)

    def render_approval(self, context: dict | None, question: str) -> None:
        self.line()
        sep = self._style("─" * 50, "2")  # dim
        self.line(sep)
        if context:
            command = context.get("command", "")
            action_type = context.get("action_type", "")
            risk_level = context.get("risk_level", "")
            label_cmd = "命令" if self.lang == "zh_cn" else "Command"
            label_type = "类型" if self.lang == "zh_cn" else "Type"
            label_risk = "风险" if self.lang == "zh_cn" else "Risk"
            self.line(f"  {label_cmd}:  {self._style(command, '1')}")  # bold
            if action_type:
                self.line(f"  {label_type}:  {action_type}")
            if risk_level:
                risk_styled = self._style(risk_level, "1;33") if risk_level == "high" else risk_level
                self.line(f"  {label_risk}:  {risk_styled}")
        else:
            display_question = format_interaction_question(question, lang=self.lang)
            for line in display_question.splitlines():
                self.line(f"  {line}")
        self.line(sep)
        hint = "[Y]es / [N]o" if self.lang != "zh_cn" else "[Y] 批准 / [N] 拒绝"
        self.line(f"  {hint}")

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
        if payload.get("budget_warning"):
            self.line(f"⚠ {payload['budget_warning']}")
        if payload.get("budget_binding_incentive"):
            self.line(f"💡 {payload['budget_binding_incentive']}")
        if payload.get("notif_referral_code"):
            share_heading = block.context_text_localized("share_heading", lang, "")
            if share_heading:
                self.line(share_heading)
            referral_label = "推荐码" if lang == "zh_cn" else "Referral code"
            self.line(f"{referral_label}: {payload['notif_referral_code']}")
        if payload.get("notif_share_text"):
            share_label = "分享文案" if lang == "zh_cn" else "Share text"
            self.line(f"{share_label}: {payload['notif_share_text']}")
