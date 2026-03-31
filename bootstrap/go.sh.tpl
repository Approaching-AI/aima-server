#!/usr/bin/env bash
# AIMA Self-Service Device Bootstrap
# Usage: curl -sL https://aima.cloud/go.sh | bash
#        curl -sL https://aima.cloud/go.sh | bash -s -- --token <ACTIVATION_CODE>
set -euo pipefail

detect_python3_bin() {
    local path=""
    path="$(command -v python3 2>/dev/null || true)"
    [ -n "$path" ] || return 1

    # macOS exposes /usr/bin/python3 even when Command Line Tools are absent.
    # Executing that shim pops the Xcode installer before /go can even register.
    if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ] && [ "$path" = "/usr/bin/python3" ]; then
        xcode-select -p >/dev/null 2>&1 || return 1
    fi

    printf '%s\n' "$path"
}

PYTHON3_BIN="$(detect_python3_bin || true)"

has_usable_python3() {
    [ -n "$PYTHON3_BIN" ]
}

resolve_login_home() {
    local detected_home=""

    if has_usable_python3; then
        detected_home="$(
            "$PYTHON3_BIN" - <<'PY'
import os
import pwd
import sys

try:
    sys.stdout.write(pwd.getpwuid(os.getuid()).pw_dir)
except Exception:
    sys.exit(0)
PY
        )"
    fi

    if [ -z "$detected_home" ] && command -v getent >/dev/null 2>&1; then
        detected_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 | head -1)"
    fi

    if [ -z "$detected_home" ] && [ -n "${HOME:-}" ]; then
        detected_home="${HOME:-}"
    fi

    if [ -n "$detected_home" ] && [ -d "$detected_home" ]; then
        (cd "$detected_home" 2>/dev/null && pwd -P) || printf '%s\n' "$detected_home"
        return 0
    fi

    return 1
}

PRESERVE_HOME_OVERRIDE=0
case "${AIMA_DEVICE_ENTRY_PRESERVE_HOME:-0}" in
    1|true|TRUE|yes|YES|on|ON) PRESERVE_HOME_OVERRIDE=1 ;;
esac

CANONICAL_HOME=""
if [ "$PRESERVE_HOME_OVERRIDE" -ne 1 ]; then
    CANONICAL_HOME="$(resolve_login_home || true)"
    if [ -n "$CANONICAL_HOME" ] && [ "$CANONICAL_HOME" != "${HOME:-}" ]; then
        HOME="$CANONICAL_HOME"
        export HOME
    fi
fi

BASE_URL=__BASE_URL__
POLL_INTERVAL=__POLL_INTERVAL_SECONDS__
STATE_FILE="${HOME}/.aima-device-state"
RUNTIME_DIR="${HOME}/.aima-device-runtime"
COMMAND_EXECUTION_ROOT="${RUNTIME_DIR}/executions"
OWNER_SCRIPT_PATH="${RUNTIME_DIR}/go-owner.sh"
OWNER_PID_FILE="${RUNTIME_DIR}/owner.pid"
OWNER_LOG_FILE="${RUNTIME_DIR}/owner.log"
OWNER_HEARTBEAT_FILE="${RUNTIME_DIR}/owner-heartbeat.json"
OWNER_HEARTBEAT_STALE_SECONDS="30"
SESSION_STATUS_FILE="${RUNTIME_DIR}/session-status.json"
PENDING_INTERACTION_FILE="${RUNTIME_DIR}/pending-interaction.json"
INTERACTION_ANSWER_FILE="${RUNTIME_DIR}/interaction-answer.json"
TASK_COMPLETION_FILE="${RUNTIME_DIR}/task-completion.json"
DISCONNECT_REQUEST_FILE="${RUNTIME_DIR}/disconnect.request"
CONNECT_TOKEN=""
INVITE_CODE=__INVITE_CODE__
REFERRAL_CODE=__REFERRAL_CODE__
WORKER_ENROLLMENT_CODE=__WORKER_CODE__
UTM_SOURCE=__UTM_SOURCE__
UTM_MEDIUM=__UTM_MEDIUM__
UTM_CAMPAIGN=__UTM_CAMPAIGN__
ACTIVE_TASK_ID=""
CONFIRMED_ACTIVE_TASK_ID=""
ACTIVE_TASK_LOOKUP_MISSES=0
ACTIVE_TASK_LOOKUP_GRACE_MISSES=3
PROMPT_ACTIVE_TASK_ACTION_RESULT=""
GUIDED_TASK_REQUEST=""
GUIDED_TASK_PRIMARY_ANSWER=""
LOCAL_CANCEL_REQUESTED=0
LAST_LOCALLY_CANCELLED_TASK_ID=""
TASK_CANCEL_HOTKEY_LABEL="Ctrl+K"
BIND_CONSOLE_HOTKEY_LABEL="Ctrl+B"
DEVICE_DISCONNECT_HOTKEY_LABEL="Ctrl+D"
CLEANUP_DONE=0
LAST_NOTIFIED_TASK_ID=""
IS_BOUND=0
HOTKEY_READ_TIMEOUT_SECONDS="0.05"
READ_TTY_PASTE_CONTINUATION_TIMEOUT="0.02"
ATTACH_IDLE_POLL_SECONDS="0.25"
READ_TTY_USE_READLINE=0
SHOW_RAW_COMMANDS="${AIMA_SHOW_RAW_COMMANDS:-0}"
RUN_AS_OWNER=0
OWNER_BOOTSTRAP_MODE="restore"
EXPLICIT_DISCONNECT_REQUESTED=0
ATTACH_MODE_STARTED=0
ATTACH_LAST_STATUS_KEY=""
ATTACH_LAST_INTERACTION_ID=""
ATTACH_DEFERRED_INTERACTION_ID=""
ATTACH_INTERACTION_RETRY_AFTER_TS=0
ATTACH_LAST_COMPLETION_ID=""
ASK_AND_CREATE_TASK_RESULT=""
DEVICE_MAX_TASKS=""
DEVICE_USED_TASKS=""
DEVICE_BUDGET_USD=""
DEVICE_SPENT_USD=""
UX_MANIFEST_JSON=__UX_MANIFEST_JSON__

select_preferred_platform_url() {
    local current_url="${1:-}"
    local saved_url="${2:-}"

    if [ -n "$current_url" ] && [ -n "$saved_url" ] && [ "${current_url#https://}" != "$current_url" ] && [ "${saved_url#https://}" = "$saved_url" ]; then
        printf '%s\n' "$current_url"
        return 0
    fi

    printf '%s\n' "$saved_url"
}

# ── Standalone mode bootstrap ────────────────────────────────────
# When installed via pip/npm/brew, template placeholders remain literal.
# Detect this and bootstrap configuration at runtime.
# In server-rendered mode (curl|bash), this block is a no-op.
_aima_standalone_mode=0
# Split the placeholder name across two strings so server-side rendering
# (which globally replaces __BASE_URL__) cannot alter this detection.
# Bash concatenates the halves at runtime: "__BASE" + "_URL__" = "__BASE_URL__"
_aima_unfilled="__BASE""_URL__"
case "$BASE_URL" in
    *"$_aima_unfilled"*) _aima_standalone_mode=1 ;;
esac

if [ "$_aima_standalone_mode" -eq 1 ]; then
    # Priority 1: reuse platform URL from saved state (reconnect)
    _saved_url=""
    if [ -f "$STATE_FILE" ]; then
        _saved_url="$(sed -n 's/^PLATFORM_URL=//p' "$STATE_FILE" | head -1)"
    fi
    # Priority 1b: cross-read from Python CLI JSON state
    if [ -z "$_saved_url" ] && [ -f "${HOME}/.aima-cli/device-state.json" ] && has_usable_python3; then
        _saved_url="$("$PYTHON3_BIN" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get("platform_url", "")
    if v:
        sys.stdout.write(v)
except Exception:
    pass
' "${HOME}/.aima-cli/device-state.json" 2>/dev/null || true)"
    fi

    _fallback_url=""
    if [ -n "${AIMA_BASE_URL:-}" ]; then
        # Priority 2: explicit env var override
        _fallback_url="${AIMA_BASE_URL%/}/api/v1"
    else
        # Priority 3: auto-detect region from locale/timezone
        _region="global"
        case "${LANG:-}${LC_ALL:-}" in
            zh_CN*|zh_TW*|zh_HK*) _region="cn" ;;
        esac
        if [ "$_region" = "global" ]; then
            _tz="$(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null || true)"
            case "${_tz:-}" in
                *Shanghai*|*Chongqing*|*Harbin*|*PRC*) _region="cn" ;;
            esac
        fi
        if [ "$_region" = "cn" ]; then
            _fallback_url="https://aimaserver.com/api/v1"
        else
            _fallback_url="https://aimaservice.ai/api/v1"
        fi
    fi
    if [ -n "$_saved_url" ]; then
        BASE_URL="$(select_preferred_platform_url "$_fallback_url" "$_saved_url")"
    else
        BASE_URL="$_fallback_url"
    fi

    # Clear unfilled template placeholders to sensible defaults
    case "$POLL_INTERVAL" in *__POLL_INTERVAL*) POLL_INTERVAL=5 ;; esac
    case "$INVITE_CODE" in *__INVITE*) INVITE_CODE="" ;; esac
    case "$REFERRAL_CODE" in *__REFERRAL*) REFERRAL_CODE="" ;; esac
    case "$WORKER_ENROLLMENT_CODE" in *__WORKER*) WORKER_ENROLLMENT_CODE="" ;; esac
    case "$UTM_SOURCE" in *__UTM_SOURCE*) UTM_SOURCE="" ;; esac
    case "$UTM_MEDIUM" in *__UTM_MEDIUM*) UTM_MEDIUM="" ;; esac
    case "$UTM_CAMPAIGN" in *__UTM_CAMPAIGN*) UTM_CAMPAIGN="" ;; esac

    # Channel-specific default invite code: if no explicit invite code and
    # AIMA_ENTRY_CHANNEL is set by the distribution wrapper (npm/pip/brew),
    # use the channel's pre-seeded invite code as a fallback.
    if [ -z "$INVITE_CODE" ] && [ -n "${AIMA_ENTRY_CHANNEL:-}" ]; then
        case "$AIMA_ENTRY_CHANNEL" in
            npm)  INVITE_CODE="channel-npm" ;;
            pip)  INVITE_CODE="channel-pip" ;;
            brew) INVITE_CODE="channel-brew" ;;
            aima) INVITE_CODE="channel-aima" ;;
        esac
    fi

    # Fetch UX manifest at runtime instead of using baked-in value
    case "$UX_MANIFEST_JSON" in *__UX_MANIFEST*)
        UX_MANIFEST_JSON="$(curl -sS --max-time 10 \
            "${BASE_URL}/ux-manifests/device-go" 2>/dev/null || echo '{}')"
        ;;
    esac
fi
# ── End standalone mode bootstrap ────────────────────────────────

case "$SHOW_RAW_COMMANDS" in
    1|true|TRUE|yes|YES|on|ON) SHOW_RAW_COMMANDS=1 ;;
    *) SHOW_RAW_COMMANDS=0 ;;
esac

if [ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]:-0}" -le 3 ]; then
    HOTKEY_READ_TIMEOUT_SECONDS="1"
    # Bash 3.x rejects fractional timeouts and `-t 0` misses pasted
    # continuation lines on macOS terminals, so use a short whole-second
    # idle window for multiline paste capture.
    READ_TTY_PASTE_CONTINUATION_TIMEOUT="1"
    ATTACH_IDLE_POLL_SECONDS="1"
fi

case "$(help read 2>/dev/null || true)" in
    *"-e"*) READ_TTY_USE_READLINE=1 ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --token) CONNECT_TOKEN="$2"; shift 2 ;;
        --invite-code) INVITE_CODE="$2"; shift 2 ;;
        --referral-code) REFERRAL_CODE="$2"; shift 2 ;;
        --worker-code) WORKER_ENROLLMENT_CODE="$2"; shift 2 ;;
        --owner) RUN_AS_OWNER=1; shift ;;
        --owner-bootstrap-mode) OWNER_BOOTSTRAP_MODE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────
json_extract_python() {
    local key="$1"
    local kind="$2"

    JSON_KEY="$key" JSON_KIND="$kind" "$PYTHON3_BIN" -c '
import json
import os
import sys

key = os.environ["JSON_KEY"]
kind = os.environ["JSON_KIND"]

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

value = data
for part in key.split("."):
    if isinstance(value, dict):
        value = value.get(part)
        continue
    if isinstance(value, list) and part.isdigit():
        idx = int(part)
        if 0 <= idx < len(value):
            value = value[idx]
            continue
    value = None
    break

if kind == "str":
    if isinstance(value, str):
        sys.stdout.write(value)
elif kind == "int":
    if isinstance(value, int) and not isinstance(value, bool):
        sys.stdout.write(str(value))
elif kind == "float":
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        sys.stdout.write(str(value))
elif kind == "bool":
    if isinstance(value, bool):
        sys.stdout.write("true" if value else "false")
'
}

json_extract_sed() {
    local key="$1"
    local kind="$2"
    local payload="$3"
    local parent child

    if [ "${key#*.}" != "$key" ]; then
        parent="${key%%.*}"
        child="${key#*.}"
        case "$kind" in
            str)
                printf '%s' "$payload" | sed -n 's/.*"'"$parent"'"[[:space:]]*:[[:space:]]*{[^}]*"'"$child"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
                ;;
            int)
                printf '%s' "$payload" | sed -n 's/.*"'"$parent"'"[[:space:]]*:[[:space:]]*{[^}]*"'"$child"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1
                ;;
            float)
                printf '%s' "$payload" | sed -n 's/.*"'"$parent"'"[[:space:]]*:[[:space:]]*{[^}]*"'"$child"'"[[:space:]]*:[[:space:]]*\(-\?[0-9][0-9]*\(\.[0-9][0-9]*\)\?\).*/\1/p' | head -1
                ;;
            bool)
                printf '%s' "$payload" | sed -n 's/.*"'"$parent"'"[[:space:]]*:[[:space:]]*{[^}]*"'"$child"'"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -1
                ;;
        esac
        return
    fi
    case "$kind" in
        str)
            printf '%s' "$payload" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
            ;;
        int)
            printf '%s' "$payload" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1
            ;;
        float)
            printf '%s' "$payload" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\(-\?[0-9][0-9]*\(\.[0-9][0-9]*\)\?\).*/\1/p' | head -1
            ;;
        bool)
            printf '%s' "$payload" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -1
            ;;
    esac
}

json_str() {
    if has_usable_python3; then
        printf '%s' "$2" | json_extract_python "$1" "str"
        return
    fi
    json_extract_sed "$1" "str" "$2"
}
json_int() {
    if has_usable_python3; then
        printf '%s' "$2" | json_extract_python "$1" "int"
        return
    fi
    json_extract_sed "$1" "int" "$2"
}
json_float() {
    if has_usable_python3; then
        printf '%s' "$2" | json_extract_python "$1" "float"
        return
    fi
    json_extract_sed "$1" "float" "$2"
}
json_bool() {
    if has_usable_python3; then
        printf '%s' "$2" | json_extract_python "$1" "bool"
        return
    fi
    json_extract_sed "$1" "bool" "$2"
}

ux_manifest_text() {
    local path="$1"
    local fallback="${2:-}"

    if ! has_usable_python3; then
        printf '%s' "$fallback"
        return 0
    fi

    local value
    value="$(
        UX_MANIFEST_PATH="$path" UX_MANIFEST_JSON="$UX_MANIFEST_JSON" "$PYTHON3_BIN" - <<'PY'
import json
import os
import sys

try:
    value = json.loads(os.environ["UX_MANIFEST_JSON"])
except Exception:
    sys.exit(0)

for part in os.environ.get("UX_MANIFEST_PATH", "").split("."):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part)
        continue
    if isinstance(value, list) and part.isdigit():
        idx = int(part)
        if 0 <= idx < len(value):
            value = value[idx]
            continue
    value = None
    break

if isinstance(value, str):
    sys.stdout.write(value)
PY
    )"
    if [ -n "$value" ]; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

DISPLAY_LANGUAGE=""

lang_text() {
    local zh="$1"
    local en="$2"
    if [ "$DISPLAY_LANGUAGE" = "zh_cn" ]; then
        printf '%s' "$zh"
    elif [ "$DISPLAY_LANGUAGE" = "en_us" ]; then
        printf '%s' "$en"
    else
        printf '%s' "$zh / $en"
    fi
}

ux_manifest_text_lang() {
    local path="$1"
    local fallback="${2:-}"
    if [ -z "$DISPLAY_LANGUAGE" ]; then
        ux_manifest_text "${path}.text" "$fallback"
        return
    fi
    local lang_val
    lang_val="$(ux_manifest_text "${path}.${DISPLAY_LANGUAGE}" "")"
    if [ -n "$lang_val" ]; then
        printf '%s' "$lang_val"
    else
        ux_manifest_text "${path}.text" "$fallback"
    fi
}

shorten_interaction_text() {
    local text="${1:-}"
    local limit="${2:-88}"
    if [ "${#text}" -le "$limit" ]; then
        printf '%s' "$text"
        return
    fi
    printf '%s...' "${text:0:$((limit - 3))}"
}

interaction_line_looks_code_like() {
    local line=""
    line="$(printf '%s' "${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && return 1
    case "$line" in
        '```'*|'{'*|'['*|'PS '*|'> '*|'$ '*|'#!'*)
            return 0
            ;;
    esac
    if printf '%s' "$line" | grep -Eqi '^[ $A-Za-z_][A-Za-z0-9_:. -]*='; then
        return 0
    fi
    if printf '%s' "$line" | grep -Eqi '(Invoke-RestMethod|Write-Output|ConvertTo-Json|Start-Process|Read-Host|Get-[A-Za-z]+|Set-[A-Za-z]+)|(^|[[:space:]])\$env:|(^|[[:space:]])\$[A-Za-z_][A-Za-z0-9_]*'; then
        return 0
    fi
    if printf '%s' "$line" | grep -Eqi '^(#!/|curl\b|bash\b|sh\b|zsh\b|sudo\b|chmod\b|export\b|apt(-get)?\b|brew\b|npm\b|pnpm\b|yarn\b|python3?\b)'; then
        return 0
    fi
    return 1
}

extract_interaction_lead_line() {
    local question="${1:-}"
    local line="" trimmed=""
    while IFS= read -r line; do
        trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[:：]$//')"
        [ -z "$trimmed" ] && continue
        if interaction_line_looks_code_like "$trimmed"; then
            continue
        fi
        printf '%s' "$trimmed"
        return 0
    done <<< "$question"
    return 0
}

interaction_question_kind() {
    local question="${1:-}"
    local stripped=""
    stripped="$(printf '%s' "$question" | sed 's/^[[:space:]]*//')"
    if printf '%s' "$stripped" | grep -Eq '^[\[{]' && printf '%s' "$stripped" | grep -Eq '[:\{\[]'; then
        printf 'json'
        return
    fi
    if printf '%s' "$question" | grep -Eqi '(Invoke-RestMethod|Write-Output|ConvertTo-Json|Start-Process|Read-Host|Get-[A-Za-z]+|Set-[A-Za-z]+)|(^|[[:space:]])\$env:|(^|[[:space:]])\$[A-Za-z_][A-Za-z0-9_]*'; then
        printf 'powershell'
        return
    fi
    if printf '%s' "$question" | grep -Eqi '^(#!/|curl\b|bash\b|sh\b|zsh\b|sudo\b|chmod\b|export\b|apt(-get)?\b|brew\b|npm\b|pnpm\b|yarn\b|python3?\b)'; then
        printf 'shell'
        return
    fi
    case "$question" in
        *$'\n'*)
            printf 'technical'
            return
            ;;
    esac
    printf 'plain'
}

should_simplify_interaction_question() {
    local question="${1:-}"
    local stripped="" line_count=0 char_count=0 line=""
    stripped="$(printf '%s' "$question" | sed '/^[[:space:]]*$/d')"
    [ -z "$stripped" ] && return 1
    line_count="$(printf '%s\n' "$stripped" | awk 'NF {count++} END {print count+0}')"
    char_count="${#question}"
    if [ "$line_count" -le 3 ] && [ "$char_count" -le 180 ]; then
        local code_like=0
        while IFS= read -r line; do
            [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
            if interaction_line_looks_code_like "$line"; then
                code_like=1
                break
            fi
        done <<< "$stripped"
        [ "$code_like" -eq 0 ] && return 1
    fi
    if [ "$line_count" -ge 6 ] || [ "$char_count" -ge 260 ]; then
        return 0
    fi
    while IFS= read -r line; do
        [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
        if interaction_line_looks_code_like "$line" && { [ "$line_count" -gt 1 ] || [ "$char_count" -gt 140 ]; }; then
            return 0
        fi
    done <<< "$stripped"
    return 1
}

format_interaction_question() {
    local question="${1:-}"
    local display_question="${2:-}"
    if [ -n "$display_question" ]; then
        printf '%s' "$display_question"
        return
    fi
    if ! should_simplify_interaction_question "$question"; then
        printf '%s' "$question"
        return
    fi

    local kind="" lead="" headline="" focus_prefix="" note=""
    kind="$(interaction_question_kind "$question")"
    lead="$(extract_interaction_lead_line "$question")"
    case "$kind" in
        powershell)
            headline="$(lang_text "智能体想让你确认一段 PowerShell 脚本或命令。" "The agent wants you to review a PowerShell script or command.")"
            ;;
        shell)
            headline="$(lang_text "智能体想让你确认一段 Shell 脚本或命令。" "The agent wants you to review a shell script or command.")"
            ;;
        json)
            headline="$(lang_text "智能体想让你确认一段配置或 JSON 内容。" "The agent wants you to review a config or JSON snippet.")"
            ;;
        *)
            headline="$(lang_text "智能体发来了一段较长的技术内容，想请你确认或补充信息。" "The agent is asking about a longer technical snippet.")"
            ;;
    esac
    focus_prefix="$(lang_text "重点" "Focus")"
    note="$(lang_text "已简化显示，后台仍保留完整技术细节。" "Simplified for display; the full technical text is still preserved in the background.")"

    printf '%s' "$headline"
    if [ -n "$lead" ]; then
        printf '\n%s: %s' "$focus_prefix" "$(shorten_interaction_text "$lead" 88)"
    fi
    printf '\n%s' "$note"
}

UX_INVITE_PROMPT="$(ux_manifest_text "onboarding.invite_prompt.text" "Please enter your invite or worker code 请输入邀请码或 Worker 接入码:")"
UX_INVITE_REQUIRED_NONINTERACTIVE="$(ux_manifest_text "onboarding.invite_required_noninteractive.text" "Invite or worker code is required but no interactive terminal is available 需要邀请码或 Worker 接入码，但当前无法交互输入")"
UX_INVITE_REQUIRED="$(ux_manifest_text "onboarding.invite_required.text" "Invite or worker code is required 需要邀请码或 Worker 接入码")"
UX_RECOVERY_PROMPT="$(ux_manifest_text "onboarding.recovery_prompt.text" "Please enter your saved recovery code 请输入已保存的恢复码:")"
UX_RECOVERY_REQUIRED_NONINTERACTIVE="$(ux_manifest_text "onboarding.recovery_required_noninteractive.text" "Recovery code is required but no interactive terminal is available 需要恢复码，但当前无法交互输入")"
UX_RECOVERY_REQUIRED="$(ux_manifest_text "onboarding.recovery_required.text" "Recovery code is required 需要恢复码")"
UX_REFERRAL_NEEDS_CODE="$(ux_manifest_text "onboarding.referral_requires_fresh_code.text" "Referral link needs a fresh invite or worker code 推荐链接当前需要新的邀请码或 Worker 接入码")"
UX_PLATFORM_NEEDS_INVITE="$(ux_manifest_text "onboarding.platform_needs_invite.text" "Platform needs an invite or worker code 平台需要邀请码或 Worker 接入码")"
UX_RECOVERY_MISSING_LOCAL_STATE="$(ux_manifest_text "onboarding.recovery_missing_local_state.text" "This device was previously registered but no local recovery code was found. Enter the saved recovery code to continue 此设备之前已经注册过，但本地没有找到恢复码。请输入已保存的恢复码后继续。")"
UX_FEEDBACK_TITLE="$(ux_manifest_text "blocks.feedback_menu.title.text" "What would you like to share? / 请选择反馈类型")"
UX_FEEDBACK_BUG_OPTION="$(ux_manifest_text "blocks.feedback_menu.options.0.label.text" "Report a problem / 反馈问题")"
UX_FEEDBACK_SUGGESTION_OPTION="$(ux_manifest_text "blocks.feedback_menu.options.1.label.text" "Share a suggestion / 提建议")"
UX_FEEDBACK_GO_BACK="$(ux_manifest_text "blocks.feedback_menu.options.2.label.text" "Go back / 返回")"
UX_FEEDBACK_DESCRIBE_PROMPT="$(ux_manifest_text "blocks.feedback_menu.prompt.text" "Describe the issue (press Enter to skip) / 问题描述（直接回车跳过）:")"
UX_POST_TASK_FEEDBACK_PROMPT="$(ux_manifest_text "blocks.feedback_menu.footer.text" "[f] Report a problem / 反馈问题  [s] Share a suggestion / 提建议  [Enter] Continue / 继续")"
UX_TASK_MENU_READY_TITLE="$(ux_manifest_text "blocks.task_menu.title.text" "What would you like me to help you do? / 请问你想让我帮你完成什么任务？")"
UX_TASK_MENU_SUBTITLE="$(ux_manifest_text "blocks.task_menu.subtitle.text" "Describe the goal in one sentence. / 直接描述你的目标即可。")"
UX_TASK_MENU_PROMPT="$(ux_manifest_text "blocks.task_menu.prompt.text" "Type your task below: / 请输入任务：")"
UX_TASK_MENU_SUBMIT_HINT="$(ux_manifest_text "blocks.task_menu.footer.text" "[Enter] Submit / 提交需求   [Ctrl+D] Disconnect / 断开设备   [Ctrl+C] Exit UI / 退出界面")"
UX_TASK_MENU_DISCONNECT="$(ux_manifest_text "blocks.task_menu.context.disconnect_option_label.text" "Disconnect device / 断开设备连接")"
UX_TASK_MENU_FEEDBACK="$(ux_manifest_text "blocks.task_menu.options.2.label.text" "Submit feedback or report a bug / 反馈问题或提建议")"
UX_TASK_MENU_ACTION_1="$(ux_manifest_text "blocks.task_menu.options.0.label.text" "Install open-source software (Dify, OpenClaw, ComfyUI...) / 安装开源软件（Dify、OpenClaw、ComfyUI…）")"
UX_TASK_MENU_ACTION_2="$(ux_manifest_text "blocks.task_menu.options.1.label.text" "Check or repair installed software / 检查或修复已安装的软件")"
UX_TASK_MENU_SECRET_WARNING="$(ux_manifest_text "blocks.task_menu.context.secret_warning.text" "Do not paste passwords / API keys / tokens directly. Describe where they are stored instead. / 不要直接粘贴密码 / API Key / Token 原文；只描述存放位置即可。")"
UX_TASK_MENU_FREEFORM_HINT="$(ux_manifest_text "blocks.task_menu.context.freeform_hint.text" "Examples: / 例如：")"
UX_TASK_MENU_EXAMPLE_1="$(ux_manifest_text "blocks.task_menu.context.freeform_examples.0.text" "Install OpenClaw, connect an LLM, and set up Feishu. / 帮我安装openclaw，连好大模型以及飞书")"
UX_TASK_MENU_EXAMPLE_2="$(ux_manifest_text "blocks.task_menu.context.freeform_examples.1.text" "Repair OpenClaw; Feishu is no longer receiving messages. / 修一下 openclaw，飞书收不到消息了")"
UX_TASK_MENU_EXAMPLE_3="$(ux_manifest_text "blocks.task_menu.context.freeform_examples.2.text" "Check Python version and upgrade to 3.12 if it is below 3.11. / 检查 python 版本，低于 3.11 就升级到 3.12")"
UX_TASK_MENU_RESUME_HOTKEY_HINT="$(ux_manifest_text "blocks.task_menu.context.resume_hotkey_hint.text" "快捷键 Hotkey: Ctrl+K 取消当前任务, Ctrl+D 断开设备, Ctrl+C 退出界面")"
UX_ACTIVE_TASK_TITLE="$(ux_manifest_text "blocks.active_task_resolution.title.text" "An unfinished task was found from a previous session. / 发现上次会话遗留的未完成任务。")"
UX_ACTIVE_TASK_PROMPT="$(ux_manifest_text "blocks.active_task_resolution.prompt.text" "Choose how to handle the unfinished task: / 请选择如何处理这个未完成任务：")"
UX_ACTIVE_TASK_TASK_ID_LABEL="$(ux_manifest_text "blocks.active_task_resolution.context.task_id_label.text" "Task ID / 任务 ID")"
UX_ACTIVE_TASK_STATUS_LABEL="$(ux_manifest_text "blocks.active_task_resolution.context.status_label.text" "Status / 状态")"
UX_ACTIVE_TASK_TARGET_LABEL="$(ux_manifest_text "blocks.active_task_resolution.context.target_label.text" "Target / 目标")"
UX_ACTIVE_TASK_RESUME_LABEL="$(ux_manifest_text "blocks.active_task_resolution.options.0.label.text" "Resume task now / 立即继续任务")"
UX_ACTIVE_TASK_CANCEL_LABEL="$(ux_manifest_text "blocks.active_task_resolution.options.1.label.text" "Cancel current task / 取消当前任务")"
UX_ACTIVE_TASK_DISCONNECT_LABEL="$(ux_manifest_text "blocks.active_task_resolution.options.2.label.text" "Disconnect device / 断开设备连接")"
UX_ACTIVE_TASK_NONINTERACTIVE_NOTICE="$(ux_manifest_text "blocks.active_task_resolution.context.noninteractive_resume_notice.text" "Non-interactive attach detected; resuming this task by default. / 当前是非交互式附着，默认继续该任务。")"
UX_ACTIVE_TASK_INPUT_UNAVAILABLE_NOTICE="$(ux_manifest_text "blocks.active_task_resolution.context.input_unavailable_resume_notice.text" "Input is unavailable; resuming this task by default. / 当前输入不可用，默认继续该任务。")"
UX_ACTIVE_TASK_INVALID_NOTICE="$(ux_manifest_text "blocks.active_task_resolution.context.invalid_selection_notice.text" "Please choose 1 / 2 or d. / 请输入 1 / 2 或 d。")"
UX_INTERACTION_TITLE="$(ux_manifest_text "blocks.interaction_prompt.title.text" "AIMA Agent asks / 智能体提问")"
UX_INTERACTION_PROMPT="$(ux_manifest_text "blocks.interaction_prompt.prompt.text" "你的回答 / Your answer (直接回车可跳过):")"
UX_INTERACTION_SKIP_NOTICE="$(ux_manifest_text "blocks.interaction_prompt.context.skip_notice.text" "已跳过，问题会继续保留在后台。 / Skipped; the question stays pending in the background.")"
UX_INTERACTION_QUEUED_NOTICE="$(ux_manifest_text "blocks.interaction_prompt.context.queued_notice.text" "已记录你的回答，后台继续处理中。 / Your answer was queued and the background session is continuing.")"
UX_APPROVAL_PROMPT="$(ux_manifest_text "blocks.interaction_prompt.context.approval_prompt.text" "需要明确审批：请输入 Y 批准，或 N 拒绝： / Approval required. Enter Y to approve or N to deny:")"
UX_APPROVAL_REQUIRED_NOTICE="$(ux_manifest_text "blocks.interaction_prompt.context.approval_required_notice.text" "这个审批不能跳过，请输入 Y 或 N。 / This approval cannot be skipped. Enter Y or N.")"
UX_APPROVAL_AUTO_DENIED_NOTICE="$(ux_manifest_text "blocks.interaction_prompt.context.approval_auto_denied_notice.text" "多次输入无效，已按拒绝处理。 / Too many invalid inputs. This approval was denied.")"
UX_APPROVAL_HINT="$(ux_manifest_text "blocks.interaction_prompt.context.approval_hint.text" "[Y] 批准  [N] 拒绝  [Enter] 不会跳过 / [Y] Approve  [N] Deny  [Enter] does not skip")"
UX_TASK_COMPLETION_SUCCESS_TITLE="$(ux_manifest_text "blocks.task_completion.context.success_title.text" "Task reported complete / 任务已报告完成")"
UX_TASK_COMPLETION_FAILURE_TITLE="$(ux_manifest_text "blocks.task_completion.context.failure_title.text" "Task failed / 任务失败")"
UX_TASK_COMPLETION_BUDGET_LABEL="$(ux_manifest_text "blocks.task_completion.context.budget_remaining_label.text" "Tasks remaining / 剩余额度")"
UX_TASK_COMPLETION_SHARE_HEADING="$(ux_manifest_text "blocks.task_completion.context.share_heading.text" "Share to earn rewards / 邀请好友得奖励")"
UX_TASK_COMPLETION_SHARE_PROMPT="$(ux_manifest_text "blocks.task_completion.context.copy_share_prompt.text" "[c] Copy share text / 复制分享文案   [Enter] Continue / 继续")"
UX_TASK_COMPLETION_BIND_PROMPT="$(ux_manifest_text "blocks.task_completion.context.bind_console_prompt.text" "Press Ctrl+B to bind this device to console. / 按 Ctrl+B 将这台设备绑定到控制台。")"
UX_TASK_COMPLETION_COPIED_NOTICE="$(ux_manifest_text "blocks.task_completion.context.copied_notice.text" "Copied to clipboard / 已复制到剪贴板")"
UX_BRAND_NAME="$(ux_manifest_text "context.brand_name.text" "AIMA灵机")"
UX_BRAND_SLOGAN="$(ux_manifest_text "context.brand_slogan.text" "一条命令，AI 接管运维 / One command. AI takes over ops.")"
UX_RUNTIME_KEEP_OPEN="$(ux_manifest_text "runtime.keep_window_open.text" "这一步可能需要几分钟，请保持窗口开启。 / This step may take a few minutes; keep this window open.")"
UX_RUNTIME_REMOTE_CANCEL="$(ux_manifest_text "runtime.remote_cancel_requested.text" "收到远程取消请求，正在停止当前步骤。 / Cancellation was requested remotely; stopping this step.")"
UX_BACKGROUND_SESSION_BOOTING="$(ux_manifest_text "background.session_booting.text" "后台会话正在本机恢复，即将重新连接。 / Background session is starting locally; reconnecting soon.")"
UX_BACKGROUND_SESSION_RESTORED="$(ux_manifest_text "background.session_restored.text" "后台会话已恢复，等待指令。 / Background session restored and waiting for work.")"
UX_BACKGROUND_SESSION_STARTED="$(ux_manifest_text "background.session_started.text" "后台会话已启动，等待指令。 / Background session started and waiting for work.")"
UX_WINDOW_TITLE="$(ux_manifest_text "context.window_title.text" "AIMA灵机：一条命令，AI 接管运维 / AIMA灵机: One command. AI takes over ops.")"

guided_flow_text() {
    local flow_key="$1"
    local field="$2"
    local fallback="${3:-}"
    ux_manifest_text "blocks.task_menu.context.guided_flows.${flow_key}.${field}.text" "$fallback"
}

guided_flow_step_text() {
    local flow_key="$1"
    local index="$2"
    local field="$3"
    local fallback="${4:-}"
    ux_manifest_text "blocks.task_menu.context.guided_flows.${flow_key}.steps.${index}.${field}.text" "$fallback"
}

guided_flow_text_lang() {
    local flow_key="$1"
    local field="$2"
    local fallback="${3:-}"
    ux_manifest_text_lang "blocks.task_menu.context.guided_flows.${flow_key}.${field}" "$fallback"
}

guided_flow_step_text_lang() {
    local flow_key="$1"
    local index="$2"
    local field="$3"
    local fallback="${4:-}"
    ux_manifest_text_lang "blocks.task_menu.context.guided_flows.${flow_key}.steps.${index}.${field}" "$fallback"
}

reload_ux_strings() {
    UX_INVITE_PROMPT="$(ux_manifest_text_lang "onboarding.invite_prompt" "Please enter your invite or worker code 请输入邀请码或 Worker 接入码:")"
    UX_INVITE_REQUIRED_NONINTERACTIVE="$(ux_manifest_text_lang "onboarding.invite_required_noninteractive" "Invite or worker code is required but no interactive terminal is available 需要邀请码或 Worker 接入码，但当前无法交互输入")"
    UX_INVITE_REQUIRED="$(ux_manifest_text_lang "onboarding.invite_required" "Invite or worker code is required 需要邀请码或 Worker 接入码")"
    UX_RECOVERY_PROMPT="$(ux_manifest_text_lang "onboarding.recovery_prompt" "Please enter your saved recovery code 请输入已保存的恢复码:")"
    UX_RECOVERY_REQUIRED_NONINTERACTIVE="$(ux_manifest_text_lang "onboarding.recovery_required_noninteractive" "Recovery code is required but no interactive terminal is available 需要恢复码，但当前无法交互输入")"
    UX_RECOVERY_REQUIRED="$(ux_manifest_text_lang "onboarding.recovery_required" "Recovery code is required 需要恢复码")"
    UX_REFERRAL_NEEDS_CODE="$(ux_manifest_text_lang "onboarding.referral_requires_fresh_code" "Referral link needs a fresh invite or worker code 推荐链接当前需要新的邀请码或 Worker 接入码")"
    UX_PLATFORM_NEEDS_INVITE="$(ux_manifest_text_lang "onboarding.platform_needs_invite" "Platform needs an invite or worker code 平台需要邀请码或 Worker 接入码")"
    UX_RECOVERY_MISSING_LOCAL_STATE="$(ux_manifest_text_lang "onboarding.recovery_missing_local_state" "This device was previously registered but no local recovery code was found. Enter the saved recovery code to continue 此设备之前已经注册过，但本地没有找到恢复码。请输入已保存的恢复码后继续。")"
    UX_FEEDBACK_TITLE="$(ux_manifest_text_lang "blocks.feedback_menu.title" "What would you like to share? / 请选择反馈类型")"
    UX_FEEDBACK_BUG_OPTION="$(ux_manifest_text_lang "blocks.feedback_menu.options.0.label" "Report a problem / 反馈问题")"
    UX_FEEDBACK_SUGGESTION_OPTION="$(ux_manifest_text_lang "blocks.feedback_menu.options.1.label" "Share a suggestion / 提建议")"
    UX_FEEDBACK_GO_BACK="$(ux_manifest_text_lang "blocks.feedback_menu.options.2.label" "Go back / 返回")"
    UX_FEEDBACK_DESCRIBE_PROMPT="$(ux_manifest_text_lang "blocks.feedback_menu.prompt" "Describe the issue (press Enter to skip) / 问题描述（直接回车跳过）:")"
    UX_POST_TASK_FEEDBACK_PROMPT="$(ux_manifest_text_lang "blocks.feedback_menu.footer" "[f] Report a problem / 反馈问题  [s] Share a suggestion / 提建议  [Enter] Continue / 继续")"
    UX_TASK_MENU_READY_TITLE="$(ux_manifest_text_lang "blocks.task_menu.title" "What would you like me to help you do? / 请问你想让我帮你完成什么任务？")"
    UX_TASK_MENU_SUBTITLE="$(ux_manifest_text_lang "blocks.task_menu.subtitle" "Describe the goal in one sentence. / 直接描述你的目标即可。")"
    UX_TASK_MENU_PROMPT="$(ux_manifest_text_lang "blocks.task_menu.prompt" "Type your task below: / 请输入任务：")"
    UX_TASK_MENU_SUBMIT_HINT="$(ux_manifest_text_lang "blocks.task_menu.footer" "[Enter] Submit / 提交需求   [Ctrl+D] Disconnect / 断开设备   [Ctrl+C] Exit UI / 退出界面")"
    UX_TASK_MENU_DISCONNECT="$(ux_manifest_text_lang "blocks.task_menu.context.disconnect_option_label" "Disconnect device / 断开设备连接")"
    UX_TASK_MENU_FEEDBACK="$(ux_manifest_text_lang "blocks.task_menu.options.2.label" "Submit feedback or report a bug / 反馈问题或提建议")"
    UX_TASK_MENU_ACTION_1="$(ux_manifest_text_lang "blocks.task_menu.options.0.label" "Install open-source software (Dify, OpenClaw, ComfyUI...) / 安装开源软件（Dify、OpenClaw、ComfyUI…）")"
    UX_TASK_MENU_ACTION_2="$(ux_manifest_text_lang "blocks.task_menu.options.1.label" "Check or repair installed software / 检查或修复已安装的软件")"
    UX_TASK_MENU_SECRET_WARNING="$(ux_manifest_text_lang "blocks.task_menu.context.secret_warning" "Do not paste passwords / API keys / tokens directly. Describe where they are stored instead. / 不要直接粘贴密码 / API Key / Token 原文；只描述存放位置即可。")"
    UX_TASK_MENU_FREEFORM_HINT="$(ux_manifest_text_lang "blocks.task_menu.context.freeform_hint" "Examples: / 例如：")"
    UX_TASK_MENU_EXAMPLE_1="$(ux_manifest_text_lang "blocks.task_menu.context.freeform_examples.0" "Install OpenClaw, connect an LLM, and set up Feishu. / 帮我安装openclaw，连好大模型以及飞书")"
    UX_TASK_MENU_EXAMPLE_2="$(ux_manifest_text_lang "blocks.task_menu.context.freeform_examples.1" "Repair OpenClaw; Feishu is no longer receiving messages. / 修一下 openclaw，飞书收不到消息了")"
    UX_TASK_MENU_EXAMPLE_3="$(ux_manifest_text_lang "blocks.task_menu.context.freeform_examples.2" "Check Python version and upgrade to 3.12 if it is below 3.11. / 检查 python 版本，低于 3.11 就升级到 3.12")"
    UX_TASK_MENU_RESUME_HOTKEY_HINT="$(ux_manifest_text_lang "blocks.task_menu.context.resume_hotkey_hint" "快捷键 Hotkey: Ctrl+K 取消当前任务, Ctrl+D 断开设备, Ctrl+C 退出界面")"
    UX_ACTIVE_TASK_TITLE="$(ux_manifest_text_lang "blocks.active_task_resolution.title" "An unfinished task was found from a previous session. / 发现上次会话遗留的未完成任务。")"
    UX_ACTIVE_TASK_PROMPT="$(ux_manifest_text_lang "blocks.active_task_resolution.prompt" "Choose how to handle the unfinished task: / 请选择如何处理这个未完成任务：")"
    UX_ACTIVE_TASK_TASK_ID_LABEL="$(ux_manifest_text_lang "blocks.active_task_resolution.context.task_id_label" "Task ID / 任务 ID")"
    UX_ACTIVE_TASK_STATUS_LABEL="$(ux_manifest_text_lang "blocks.active_task_resolution.context.status_label" "Status / 状态")"
    UX_ACTIVE_TASK_TARGET_LABEL="$(ux_manifest_text_lang "blocks.active_task_resolution.context.target_label" "Target / 目标")"
    UX_ACTIVE_TASK_RESUME_LABEL="$(ux_manifest_text_lang "blocks.active_task_resolution.options.0.label" "Resume task now / 立即继续任务")"
    UX_ACTIVE_TASK_CANCEL_LABEL="$(ux_manifest_text_lang "blocks.active_task_resolution.options.1.label" "Cancel current task / 取消当前任务")"
    UX_ACTIVE_TASK_DISCONNECT_LABEL="$(ux_manifest_text_lang "blocks.active_task_resolution.options.2.label" "Disconnect device / 断开设备连接")"
    UX_ACTIVE_TASK_NONINTERACTIVE_NOTICE="$(ux_manifest_text_lang "blocks.active_task_resolution.context.noninteractive_resume_notice" "Non-interactive attach detected; resuming this task by default. / 当前是非交互式附着，默认继续该任务。")"
    UX_ACTIVE_TASK_INPUT_UNAVAILABLE_NOTICE="$(ux_manifest_text_lang "blocks.active_task_resolution.context.input_unavailable_resume_notice" "Input is unavailable; resuming this task by default. / 当前输入不可用，默认继续该任务。")"
    UX_ACTIVE_TASK_INVALID_NOTICE="$(ux_manifest_text_lang "blocks.active_task_resolution.context.invalid_selection_notice" "Please choose 1 / 2 or d. / 请输入 1 / 2 或 d。")"
    UX_INTERACTION_TITLE="$(ux_manifest_text_lang "blocks.interaction_prompt.title" "AIMA Agent asks / 智能体提问")"
    UX_INTERACTION_PROMPT="$(ux_manifest_text_lang "blocks.interaction_prompt.prompt" "你的回答 / Your answer (直接回车可跳过):")"
    UX_INTERACTION_SKIP_NOTICE="$(ux_manifest_text_lang "blocks.interaction_prompt.context.skip_notice" "已跳过，问题会继续保留在后台。 / Skipped; the question stays pending in the background.")"
    UX_INTERACTION_QUEUED_NOTICE="$(ux_manifest_text_lang "blocks.interaction_prompt.context.queued_notice" "已记录你的回答，后台继续处理中。 / Your answer was queued and the background session is continuing.")"
    UX_APPROVAL_PROMPT="$(ux_manifest_text_lang "blocks.interaction_prompt.context.approval_prompt" "需要明确审批：请输入 Y 批准，或 N 拒绝： / Approval required. Enter Y to approve or N to deny:")"
    UX_APPROVAL_REQUIRED_NOTICE="$(ux_manifest_text_lang "blocks.interaction_prompt.context.approval_required_notice" "这个审批不能跳过，请输入 Y 或 N。 / This approval cannot be skipped. Enter Y or N.")"
    UX_APPROVAL_AUTO_DENIED_NOTICE="$(ux_manifest_text_lang "blocks.interaction_prompt.context.approval_auto_denied_notice" "多次输入无效，已按拒绝处理。 / Too many invalid inputs. This approval was denied.")"
    UX_APPROVAL_HINT="$(ux_manifest_text_lang "blocks.interaction_prompt.context.approval_hint" "[Y] 批准  [N] 拒绝  [Enter] 不会跳过 / [Y] Approve  [N] Deny  [Enter] does not skip")"
    UX_TASK_COMPLETION_SUCCESS_TITLE="$(ux_manifest_text_lang "blocks.task_completion.context.success_title" "Task reported complete / 任务已报告完成")"
    UX_TASK_COMPLETION_FAILURE_TITLE="$(ux_manifest_text_lang "blocks.task_completion.context.failure_title" "Task failed / 任务失败")"
    UX_TASK_COMPLETION_BUDGET_LABEL="$(ux_manifest_text_lang "blocks.task_completion.context.budget_remaining_label" "Tasks remaining / 剩余额度")"
    UX_TASK_COMPLETION_SHARE_HEADING="$(ux_manifest_text_lang "blocks.task_completion.context.share_heading" "Share to earn rewards / 邀请好友得奖励")"
    UX_TASK_COMPLETION_SHARE_PROMPT="$(ux_manifest_text_lang "blocks.task_completion.context.copy_share_prompt" "[c] Copy share text / 复制分享文案   [Enter] Continue / 继续")"
    UX_TASK_COMPLETION_BIND_PROMPT="$(ux_manifest_text_lang "blocks.task_completion.context.bind_console_prompt" "Press Ctrl+B to bind this device to console. / 按 Ctrl+B 将这台设备绑定到控制台。")"
    UX_TASK_COMPLETION_COPIED_NOTICE="$(ux_manifest_text_lang "blocks.task_completion.context.copied_notice" "Copied to clipboard / 已复制到剪贴板")"
    UX_BRAND_NAME="$(ux_manifest_text_lang "context.brand_name" "AIMA灵机")"
    UX_BRAND_SLOGAN="$(ux_manifest_text_lang "context.brand_slogan" "一条命令，AI 接管运维 / One command. AI takes over ops.")"
    UX_RUNTIME_KEEP_OPEN="$(ux_manifest_text_lang "runtime.keep_window_open" "这一步可能需要几分钟，请保持窗口开启。 / This step may take a few minutes; keep this window open.")"
    UX_RUNTIME_REMOTE_CANCEL="$(ux_manifest_text_lang "runtime.remote_cancel_requested" "收到远程取消请求，正在停止当前步骤。 / Cancellation was requested remotely; stopping this step.")"
    UX_BACKGROUND_SESSION_BOOTING="$(ux_manifest_text_lang "background.session_booting" "后台会话正在本机恢复，即将重新连接。 / Background session is starting locally; reconnecting soon.")"
    UX_BACKGROUND_SESSION_RESTORED="$(ux_manifest_text_lang "background.session_restored" "后台会话已恢复，等待指令。 / Background session restored and waiting for work.")"
    UX_BACKGROUND_SESSION_STARTED="$(ux_manifest_text_lang "background.session_started" "后台会话已启动，等待指令。 / Background session started and waiting for work.")"
    UX_WINDOW_TITLE="$(ux_manifest_text_lang "context.window_title" "AIMA灵机：一条命令，AI 接管运维 / AIMA灵机: One command. AI takes over ops.")"
    refresh_window_title
}

refresh_window_title() {
    if tty_available; then
        printf '\033]0;%s\007' "$UX_WINDOW_TITLE" > /dev/tty
    fi
}

format_usd() {
    printf '$%.2f' "${1:-0}"
}

format_task_budget_used_line() {
    local used="$1"
    local total="$2"
    if [ "$DISPLAY_LANGUAGE" = "zh_cn" ]; then
        printf '已用 %s / 总量 %s' "${used:-0}" "${total:-0}"
    else
        printf '%s / %s used' "${used:-0}" "${total:-0}"
    fi
}

format_task_budget_remaining_line() {
    local remaining="$1"
    local total="$2"
    if [ "$DISPLAY_LANGUAGE" = "zh_cn" ]; then
        printf '剩余 %s / 总量 %s' "${remaining:-0}" "${total:-0}"
    else
        printf '%s / %s remaining' "${remaining:-0}" "${total:-0}"
    fi
}

format_amount_budget_used_line() {
    local spent="$1"
    local total="$2"
    if [ "$DISPLAY_LANGUAGE" = "zh_cn" ]; then
        printf '已花 %s / 总额 %s' "$(format_usd "$spent")" "$(format_usd "$total")"
    else
        printf '%s / %s used' "$(format_usd "$spent")" "$(format_usd "$total")"
    fi
}

format_amount_budget_remaining_line() {
    local remaining="$1"
    local total="$2"
    if [ "$DISPLAY_LANGUAGE" = "zh_cn" ]; then
        printf '剩余 %s / 总额 %s' "$(format_usd "$remaining")" "$(format_usd "$total")"
    else
        printf '%s / %s remaining' "$(format_usd "$remaining")" "$(format_usd "$total")"
    fi
}

sync_budget_snapshot_from_payload() {
    local payload="$1"
    DEVICE_MAX_TASKS="$(json_int budget.max_tasks "$payload")"
    DEVICE_USED_TASKS="$(json_int budget.used_tasks "$payload")"
    DEVICE_BUDGET_USD="$(json_float budget.budget_usd "$payload")"
    DEVICE_SPENT_USD="$(json_float budget.spent_usd "$payload")"
}

render_connected_summary() {
    printf '\n'
    printf '\033[36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '  \033[1m%s\033[0m\n' "$UX_BRAND_NAME"
    printf '  \033[2m%s\033[0m\n' "$UX_BRAND_SLOGAN"
    printf '  \033[36m  ────────────────────────────────────────────────────────────\033[0m\n'
    printf '  \033[1;32m●\033[0m %s\n' "$(lang_text "设备已连接!" "Device linked!")"
    printf '    %s: %s\n' "$(lang_text "设备 ID" "Device ID")" "$DEVICE_ID"
    printf '    %s: %s\n' "$(lang_text "任务额度" "Task budget")" "$(format_task_budget_used_line "${DEVICE_USED_TASKS:-0}" "${DEVICE_MAX_TASKS:-0}")"
    printf '    %s: %s\n' "$(lang_text "金额额度" "Amount budget")" "$(format_amount_budget_used_line "${DEVICE_SPENT_USD:-0}" "${DEVICE_BUDGET_USD:-0}")"
    if [ -n "$MY_REFERRAL_CODE" ]; then
        printf '    %s: %s\n' "$(lang_text "你的推荐码" "Your referral code")" "$MY_REFERRAL_CODE"
    fi
    printf '    %s\n' "$(lang_text "凭证已保存到 ~/.aima-device-state" "Credentials saved to ~/.aima-device-state")"
    printf '  \033[36m  ────────────────────────────────────────────────────────────\033[0m\n'
    printf '    %s\n' "$(lang_text "后台已就绪。你现在可以直接下达任务。" "Background session is ready. You can give AIMA a task now.")"
    printf '    %s\n' "$(lang_text "${TASK_CANCEL_HOTKEY_LABEL} 取消当前任务 · ${BIND_CONSOLE_HOTKEY_LABEL} 绑定控制台" "${TASK_CANCEL_HOTKEY_LABEL} cancel current task · ${BIND_CONSOLE_HOTKEY_LABEL} bind Console")"
    printf '    %s\n' "$(lang_text "${DEVICE_DISCONNECT_HOTKEY_LABEL} 断开设备 · Ctrl+C 退出前台" "${DEVICE_DISCONNECT_HOTKEY_LABEL} disconnect device · Ctrl+C exit foreground UI")"
    printf '\033[36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
}

render_security_summary() {
    printf '\n'
    printf '  \033[1m%s\033[0m\n' "$(lang_text "安全概览" "Security profile")"
    if [ "${BASE_URL}" = "${BASE_URL#https://}" ]; then
        printf '    \033[33m⚠\033[0m %s\n' "$(lang_text "链路未加密，仅 HTTP 传输" "Connection: HTTP only, not encrypted")"
    else
        printf '    \033[32m✓\033[0m %s\n' "$(lang_text "链路已加密（HTTPS）" "Connection: HTTPS encrypted")"
    fi
    printf '    \033[32m✓\033[0m %s\n' "$(lang_text "AIMA 已获权在当前终端执行指令" "AIMA can run commands in this terminal")"
    printf '    \033[32m✓\033[0m %s\n' "$(lang_text "高风险操作需管理员审批" "High-risk commands require admin approval")"
    printf '    \033[32m✓\033[0m %s\n' "$(lang_text "任务运行中可随时中断" "You can interrupt running tasks at any time")"
    printf '    \033[32m✓\033[0m %s\n' "$(lang_text "AIMA 不会强制锁死当前终端" "AIMA will not permanently lock this terminal")"
}

# ── aima shortcut ─────────────────────────────────────────────
AIMA_SHORTCUT_PATH="${HOME}/.local/bin/aima"

is_aima_shortcut_installed() {
    if [ -x "$AIMA_SHORTCUT_PATH" ]; then
        aima_shortcut_is_current && return 0
        return 1
    fi
    command -v aima >/dev/null 2>&1 && return 0
    return 1
}

aima_shortcut_is_current() {
    [ -f "$AIMA_SHORTCUT_PATH" ] || return 1
    grep -qF '_aima_url="${_aima_url%/api/v1}"' "$AIMA_SHORTCUT_PATH" 2>/dev/null || return 1
    grep -qF 'curl -fsSL "${_aima_url}/go.sh" -o "$_aima_script"' "$AIMA_SHORTCUT_PATH" 2>/dev/null || return 1
    return 0
}

install_aima_shortcut() {
    # Run in subshell so set -e failures don't kill the main script
    (
        mkdir -p "${HOME}/.local/bin"
        cat > "$AIMA_SHORTCUT_PATH" <<'WRAPPER'
#!/usr/bin/env bash
_aima_url="$(sed -n 's/^PLATFORM_URL=//p' "${HOME}/.aima-device-state" 2>/dev/null)"
if [ -z "$_aima_url" ]; then
    printf 'AIMA: 未找到设备状态。请先运行原始安装命令。\n'
    printf 'AIMA: No saved device state found. Please run the original setup command first.\n'
    exit 1
fi
_aima_url="${_aima_url%/}"
_aima_url="${_aima_url%/api/v1}"
_aima_script="$(mktemp "${TMPDIR:-/tmp}/aima-go.XXXXXX")" || exit 1
if ! curl -fsSL "${_aima_url}/go.sh" -o "$_aima_script"; then
    rm -f "$_aima_script"
    printf 'AIMA: 无法获取启动脚本：%s/go.sh\n' "$_aima_url" >&2
    printf 'AIMA: Failed to fetch launcher script: %s/go.sh\n' "$_aima_url" >&2
    exit 1
fi
bash "$_aima_script" "$@"
_aima_status=$?
rm -f "$_aima_script"
exit "$_aima_status"
WRAPPER
        chmod +x "$AIMA_SHORTCUT_PATH"

        # Ensure ~/.local/bin is in PATH (check both live PATH and rc file content to avoid duplicates)
        if ! echo "$PATH" | tr ':' '\n' | grep -qx "${HOME}/.local/bin"; then
            local_rc_updated=0
            for rc_file in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
                if [ -f "$rc_file" ]; then
                    if ! grep -qF '/.local/bin' "$rc_file" 2>/dev/null; then
                        printf '\n# Added by AIMA - aima shortcut\nexport PATH="${HOME}/.local/bin:${PATH}"\n' >> "$rc_file"
                    fi
                    local_rc_updated=1
                fi
            done
            if [ "$local_rc_updated" -eq 0 ]; then
                printf '# Added by AIMA - aima shortcut\nexport PATH="${HOME}/.local/bin:${PATH}"\n' >> "${HOME}/.bashrc"
            fi
        fi
    )
}

ensure_aima_shortcut_current() {
    [ -x "$AIMA_SHORTCUT_PATH" ] || return 0
    if aima_shortcut_is_current; then
        return 0
    fi
    if install_aima_shortcut; then
        printf '  \033[32m✓\033[0m %s\n' "$(lang_text '已更新旧版 aima 快捷命令。重新输入 aima 即可使用。' 'Updated the existing aima shortcut. Run aima again to use it.')"
    else
        warn "$(lang_text '旧版快捷命令更新失败，不影响当前连接。' 'Existing shortcut upgrade failed; current connection is unaffected.')"
    fi
}

prompt_aima_shortcut() {
    if [ "$RUN_AS_OWNER" -eq 1 ]; then return; fi
    if ! tty_available; then return; fi
    if [ -x "$AIMA_SHORTCUT_PATH" ]; then
        ensure_aima_shortcut_current
        return
    fi
    if command -v aima >/dev/null 2>&1; then return; fi

    printf '\n'
    printf '  \033[1m%s\033[0m\n' "$(lang_text '是否添加 aima 快捷命令？之后只需输入 aima 即可重新连接。' 'Add aima shortcut? Then just type aima to reconnect.')"
    printf '  [Y/n] '
    local answer=""
    read_tty answer || true
    answer="$(printf '%s' "$answer" | tr -d '[:space:]')"
    if [ "$answer" != "n" ] && [ "$answer" != "N" ]; then
        if install_aima_shortcut; then
            printf '  \033[32m✓\033[0m %s\n' "$(lang_text '已添加。打开新终端后输入 aima 即可启动。' 'Done. Open a new terminal and type aima to start.')"
        else
            warn "$(lang_text '快捷命令安装失败，不影响正常使用。' 'Shortcut installation failed; this does not affect normal usage.')"
        fi
    fi
}

render_attached_banner() {
    refresh_window_title
    printf '\n\033[36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '  \033[1m%s\033[0m · \033[2m%s\033[0m\n' "$UX_BRAND_NAME" "$UX_BRAND_SLOGAN"
    printf '  %s\n' "$(lang_text "你现在看到的是前台观察界面。" "This is the foreground observer UI.")"
    printf '  %s\n' "$(lang_text "设备会继续在后台保持连接。" "The device stays connected in the background.")"
    printf '  %s\n' "$(lang_text "${TASK_CANCEL_HOTKEY_LABEL} 取消当前任务 · ${BIND_CONSOLE_HOTKEY_LABEL} 绑定控制台" "${TASK_CANCEL_HOTKEY_LABEL} cancel current task · ${BIND_CONSOLE_HOTKEY_LABEL} bind Console")"
    printf '  %s\n' "$(lang_text "${DEVICE_DISCONNECT_HOTKEY_LABEL} 断开设备 · Ctrl+C 退出前台" "${DEVICE_DISCONNECT_HOTKEY_LABEL} disconnect device · Ctrl+C exit foreground UI")"
    printf '\033[36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
}

prompt_language_selection() {
    if ! tty_available; then
        DISPLAY_LANGUAGE="zh_cn"
        return
    fi
    printf '\n'
    printf '  \033[1m选择显示语言 / Select display language:\033[0m\n'
    printf '  \033[36m1.\033[0m 中文\n'
    printf '  \033[36m2.\033[0m English\n'
    printf '  > '
    local answer=""
    read_tty answer || true
    answer="$(printf '%s' "$answer" | tr -d '[:space:]')"
    case "$answer" in
        2|en|EN|english|English|ENGLISH) DISPLAY_LANGUAGE="en_us" ;;
        *) DISPLAY_LANGUAGE="zh_cn" ;;
    esac
    persist_state_value "DISPLAY_LANGUAGE" "$DISPLAY_LANGUAGE"
    reload_ux_strings
    # Sync language preference to platform
    if [ -n "$DEVICE_ID" ] && [ -n "$DEVICE_TOKEN" ]; then
        curl -sS -X POST "${BASE_URL}/devices/${DEVICE_ID}/language" \
            -H "Authorization: Bearer ${DEVICE_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"display_language\":\"${DISPLAY_LANGUAGE}\"}" \
            >/dev/null 2>&1 || true
    fi
}

prompt_guided_task_request() {
    local flow_key="$1"
    local missing_answer intro outro prompt_text summary_label default_answer answer index

    GUIDED_TASK_REQUEST=""
    GUIDED_TASK_PRIMARY_ANSWER=""
    intro="$(guided_flow_text_lang "$flow_key" "summary_intro" "")"
    missing_answer="$(ux_manifest_text_lang "blocks.task_menu.context.guided_missing_answer" "未说明 / Not provided")"
    if [ -z "$intro" ]; then
        return 1
    fi

    GUIDED_TASK_REQUEST="$intro"
    index=0
    while true; do
        prompt_text="$(guided_flow_step_text_lang "$flow_key" "$index" "prompt" "")"
        [ -n "$prompt_text" ] || break

        summary_label="$(guided_flow_step_text_lang "$flow_key" "$index" "summary_label" "Step $((index + 1))")"
        default_answer="$(guided_flow_step_text_lang "$flow_key" "$index" "default_answer" "")"
        printf '\n  \033[36m%s\033[0m\n' "$prompt_text"
        printf '  > '
        answer=""
        if ! read_tty answer; then
            GUIDED_TASK_REQUEST=""
            return 2
        fi
        if [ -z "$answer" ]; then
            if [ -n "$default_answer" ]; then
                answer="$default_answer"
            else
                answer="$missing_answer"
            fi
        fi
        if [ -z "$GUIDED_TASK_PRIMARY_ANSWER" ]; then
            GUIDED_TASK_PRIMARY_ANSWER="$answer"
        fi
        GUIDED_TASK_REQUEST="${GUIDED_TASK_REQUEST}
- ${summary_label}: ${answer}"
        index=$((index + 1))
    done

    outro="$(guided_flow_text_lang "$flow_key" "summary_outro" "")"
    if [ -n "$outro" ]; then
        GUIDED_TASK_REQUEST="${GUIDED_TASK_REQUEST}
${outro}"
    fi
    return 0
}

build_task_request_json() {
    local description="$1"
    local mode="${2:-}"
    local user_request="${3:-}"
    local renderer="${4:-}"
    local task_type_hint="${5:-}"
    local software_hint="${6:-}"
    local problem_hint="${7:-}"
    local target_hint="${8:-}"
    local error_message_hint="${9:-}"
    local payload=""
    local intake=""
    local search=""
    local intake_sep=""
    local search_sep=""

    payload="{\"description\":\"$(json_escape "$description")\""

    if [ -n "$mode" ] || [ -n "$user_request" ] || [ -n "$renderer" ] || [ -n "$software_hint" ] || [ -n "$problem_hint" ]; then
        intake="{"
        if [ -n "$mode" ]; then
            intake="${intake}${intake_sep}\"mode\":\"$(json_escape "$mode")\""
            intake_sep=","
        fi
        if [ -n "$user_request" ]; then
            intake="${intake}${intake_sep}\"user_request\":\"$(json_escape "$user_request")\""
            intake_sep=","
        fi
        if [ -n "$software_hint" ]; then
            intake="${intake}${intake_sep}\"software_hint\":\"$(json_escape "$software_hint")\""
            intake_sep=","
        fi
        if [ -n "$problem_hint" ]; then
            intake="${intake}${intake_sep}\"problem_hint\":\"$(json_escape "$problem_hint")\""
            intake_sep=","
        fi
        if [ -n "$renderer" ]; then
            intake="${intake}${intake_sep}\"renderer\":\"$(json_escape "$renderer")\""
        fi
        intake="${intake}}"
        payload="${payload},\"intake\":${intake}"
    fi

    if [ -n "$task_type_hint" ]; then
        search="{"
        search="${search}${search_sep}\"task_type_hint\":\"$(json_escape "$task_type_hint")\""
        search_sep=","
        if [ -n "$target_hint" ]; then
            search="${search}${search_sep}\"target_hint\":\"$(json_escape "$target_hint")\""
            search_sep=","
        fi
        if [ -n "$error_message_hint" ]; then
            search="${search}${search_sep}\"error_message_hint\":\"$(json_escape "$error_message_hint")\""
            search_sep=","
        fi
        search="${search}}"
        payload="${payload},\"experience_search\":${search}"
    fi

    payload="${payload}}"
    printf '%s' "$payload"
}

normalize_target_hint() {
    local value="$1"
    printf '%s' "$value" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9._+-]+/_/g; s/^[._-]+//; s/[._-]+$//' \
        | cut -c1-120
}

software_hint_ignored() {
    case "$1" in
        ""|aima|api|assistant|check|debug|deploy|diagnose|fix|for|from|help|install|issue|it|its|just|latest|machine|me|my|need|on|our|please|problem|repair|run|setup|system|task|that|the|their|these|this|those|to|use|using|version|want|we|with|you|your)
            return 0
            ;;
    esac
    return 1
}

infer_software_hint_from_text() {
    local text="$1"
    local lower candidate=""
    lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lower" =~ (install|setup|deploy|upgrade|repair|fix|check|debug|troubleshoot|diagnose)[[:space:]]+([a-z][a-z0-9._+-]{1,63}) ]]; then
        candidate="${BASH_REMATCH[2]}"
    elif [[ "$text" =~ (安装|装|配置|部署|升级|修复|修一下|检查|排查|诊断)[[:space:]]*([A-Za-z][A-Za-z0-9._+-]{1,63}) ]]; then
        candidate="${BASH_REMATCH[2]}"
    elif [[ "$text" =~ ^[^A-Za-z]*([A-Za-z][A-Za-z0-9._+-]{1,63}) ]]; then
        candidate="${BASH_REMATCH[1]}"
    fi

    candidate="$(normalize_target_hint "$candidate")"
    if software_hint_ignored "$candidate"; then
        return 0
    fi
    printf '%s' "$candidate"
}

infer_task_type_hint_from_text() {
    local text="$1"
    local lower
    lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
    if printf '%s' "$lower" | grep -Eq '\b(install|setup|deploy|upgrade)\b'; then
        printf 'software_install'
        return 0
    fi
    if printf '%s' "$lower" | grep -Eq '\b(repair|fix|check|debug|troubleshoot|diagnose)\b'; then
        printf 'software_repair'
        return 0
    fi
    if printf '%s' "$text" | grep -Eq '安装|配置|部署|升级'; then
        printf 'software_install'
        return 0
    fi
    if printf '%s' "$text" | grep -Eq '修复|检查|排查|诊断|升级一下|修一下'; then
        printf 'software_repair'
        return 0
    fi
    printf 'general_ops'
}

detect_command_runtime_backend() {
    if has_usable_python3; then
        printf 'python3'
        return 0
    fi
    if command -v perl >/dev/null 2>&1; then
        printf 'perl'
        return 0
    fi
    if command -v setsid >/dev/null 2>&1; then
        printf 'setsid'
        return 0
    fi
    printf 'none'
}

COMMAND_RUNTIME_BACKEND="$(detect_command_runtime_backend)"

require_command_runtime_support() {
    if [ "$COMMAND_RUNTIME_BACKEND" != "none" ]; then
        return 0
    fi
    fail "Reliable task execution requires python3, perl, or setsid on this macOS/Linux shell. Install python3 and run /go again. / 当前 macOS/Linux shell 需要 python3、perl 或 setsid 才能可靠执行任务。请先安装 python3 后重新运行 /go。"
}

read_file_prefix_bytes() {
    local path="$1"
    local limit="${2:-524288}"
    [ -f "$path" ] || return 0
    head -c "$limit" "$path" 2>/dev/null || cat "$path" 2>/dev/null || true
}

read_file_tail_bytes() {
    local path="$1"
    local limit="${2:-4096}"
    [ -f "$path" ] || return 0
    tail -c "$limit" "$path" 2>/dev/null || cat "$path" 2>/dev/null || true
}

HTTP_STATUS=""
HTTP_BODY=""
HTTP_CURL_EXIT=0

request_with_status() {
    local tmp_body
    tmp_body="$(mktemp)"

    set +e
    HTTP_STATUS="$(curl -sS -o "$tmp_body" -w "%{http_code}" "$@" 2>/dev/null)"
    HTTP_CURL_EXIT=$?
    set -e

    HTTP_BODY="$(cat "$tmp_body")"
    rm -f "$tmp_body"
}

submit_command_result_with_retry() {
    local result_url="$1"
    local payload_file="$2"
    local command_id="${3:-}"
    local attempt=0
    local delay=5

    while true; do
        if [ "$RUN_AS_OWNER" -eq 1 ]; then
            write_owner_heartbeat "result_upload" "$ACTIVE_TASK_ID" "$command_id"
        fi
        request_with_status -X POST "$result_url" \
            -H "Authorization: Bearer ${DEVICE_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "@${payload_file}"

        if [ "${HTTP_STATUS}" = "401" ] || [ "${HTTP_STATUS}" = "403" ] || [ "${HTTP_STATUS}" = "404" ]; then
            return 2
        fi
        case "${HTTP_STATUS}" in
            4??)
                return 3
                ;;
        esac

        if [ "${HTTP_CURL_EXIT}" -eq 0 ] && [ "${HTTP_STATUS}" = "200" ]; then
            return 0
        fi

        attempt=$((attempt + 1))
        delay=$((attempt * 5))
        if [ "$delay" -gt 60 ]; then
            delay=60
        fi
        warn "Command result upload failed; retrying in ${delay}s (curl=${HTTP_CURL_EXIT}, http=${HTTP_STATUS:-000})"
        # Sleep in 10s chunks so heartbeat stays fresh (staleness threshold is 30s)
        local remaining="$delay"
        while [ "$remaining" -gt 0 ]; do
            if [ "$RUN_AS_OWNER" -eq 1 ]; then
                write_owner_heartbeat "result_retry_wait" "$ACTIVE_TASK_ID" "$command_id"
            fi
            if [ "$remaining" -ge 10 ]; then
                sleep 10
                remaining=$((remaining - 10))
            else
                sleep "$remaining"
                remaining=0
            fi
        done
    done
}

build_progress_payload_file() {
    local stdout_file="$1"
    local stderr_file="$2"
    local message="$3"
    local payload_file="$4"

    local stdout_tail stderr_tail escaped_stdout escaped_stderr escaped_message
    stdout_tail="$(read_file_tail_bytes "$stdout_file" 4096)"
    stderr_tail="$(read_file_tail_bytes "$stderr_file" 4096)"
    escaped_stdout="$(json_escape "$stdout_tail")"
    escaped_stderr="$(json_escape "$stderr_tail")"
    escaped_message="$(json_escape "${message:0:500}")"

    {
        printf '{"stdout":"%s","stderr":"%s"' "$escaped_stdout" "$escaped_stderr"
        if [ -n "$message" ]; then
            printf ',"message":"%s"' "$escaped_message"
        fi
        printf '}'
    } > "$payload_file"
}

build_result_payload_file() {
    local stdout_file="$1"
    local stderr_file="$2"
    local command_id="$3"
    local exit_code="$4"
    local result_id="$5"
    local payload_file="$6"

    local stdout_text stderr_text escaped_stdout escaped_stderr escaped_command escaped_result
    stdout_text="$(read_file_prefix_bytes "$stdout_file" 524288)"
    stderr_text="$(read_file_prefix_bytes "$stderr_file" 524288)"
    escaped_stdout="$(json_escape "$stdout_text")"
    escaped_stderr="$(json_escape "$stderr_text")"
    escaped_command="$(json_escape "$command_id")"
    escaped_result="$(json_escape "$result_id")"

    printf '{"command_id":"%s","exit_code":%s,"stdout":"%s","stderr":"%s","result_id":"%s"}' \
        "$escaped_command" \
        "$exit_code" \
        "$escaped_stdout" \
        "$escaped_stderr" \
        "$escaped_result" > "$payload_file"
}

submit_command_progress_once() {
    local progress_url="$1"
    local payload_file="$2"

    request_with_status --max-time 10 -X POST "$progress_url" \
        -H "Authorization: Bearer ${DEVICE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "@${payload_file}"

    if [ "${HTTP_STATUS}" = "401" ] || [ "${HTTP_STATUS}" = "403" ] || [ "${HTTP_STATUS}" = "404" ]; then
        return 2
    fi
    if [ "${HTTP_CURL_EXIT}" -ne 0 ] || [ "${HTTP_STATUS}" != "200" ]; then
        return 1
    fi
    if [ "$(json_bool cancel_requested "$HTTP_BODY")" = "true" ] || [ "$(json_str command_status "$HTTP_BODY")" = "cancelled" ]; then
        return 10
    fi
    return 0
}

launch_command_detached() {
    local cmd="$1"
    local stdout_file="$2"
    local stderr_file="$3"
    local work_dir="${4:-$PWD}"
    local artifact_dir
    artifact_dir="$(dirname "$stdout_file")"
    local pid_file shell_pid child_pid

    LAUNCHED_COMMAND_WAIT_PID=""
    LAUNCHED_COMMAND_EXEC_PID=""
    case "$COMMAND_RUNTIME_BACKEND" in
        python3)
            pid_file="$(mktemp)"
            COMMAND_TEXT="$cmd" COMMAND_STDOUT_FILE="$stdout_file" COMMAND_STDERR_FILE="$stderr_file" COMMAND_PID_FILE="$pid_file" COMMAND_WORK_DIR="$work_dir" COMMAND_ARTIFACT_DIR="$artifact_dir" \
                "$PYTHON3_BIN" - <<'PY' &
import os
import sys


cmd = os.environ["COMMAND_TEXT"]
stdout_path = os.environ["COMMAND_STDOUT_FILE"]
stderr_path = os.environ["COMMAND_STDERR_FILE"]
pid_file = os.environ["COMMAND_PID_FILE"]
work_dir = os.environ.get("COMMAND_WORK_DIR") or os.getcwd()
artifact_dir = os.environ.get("COMMAND_ARTIFACT_DIR") or os.path.dirname(stdout_path)

pid = os.fork()
if pid == 0:
    stdin_fd = os.open(os.devnull, os.O_RDONLY)
    stdout_fd = os.open(stdout_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    stderr_fd = os.open(stderr_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)

    os.setsid()
    os.chdir(work_dir)
    os.dup2(stdin_fd, 0)
    os.dup2(stdout_fd, 1)
    os.dup2(stderr_fd, 2)

    os.environ["AIMA_EXECUTION_SANDBOX"] = "1"
    os.environ["AIMA_EXECUTION_WORKDIR"] = work_dir
    os.environ["AIMA_EXECUTION_DIR"] = artifact_dir
    for fd in (stdin_fd, stdout_fd, stderr_fd):
        if fd > 2:
            os.close(fd)

    os.execvp("bash", ["bash", "-l", "-c", cmd])

with open(pid_file, "w", encoding="utf-8") as handle:
    handle.write(str(pid))

_, status = os.waitpid(pid, 0)
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(1)
PY
            shell_pid=$!
            child_pid=""
            for _ in $(seq 1 50); do
                if [ -s "$pid_file" ]; then
                    child_pid="$(cat "$pid_file" 2>/dev/null || true)"
                    break
                fi
                if ! kill -0 "$shell_pid" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
            rm -f "$pid_file"
            if [ -z "$child_pid" ]; then
                child_pid="$shell_pid"
            fi
            LAUNCHED_COMMAND_WAIT_PID="$shell_pid"
            LAUNCHED_COMMAND_EXEC_PID="$child_pid"
            ;;
        perl)
            pid_file="$(mktemp)"
            COMMAND_TEXT="$cmd" COMMAND_STDOUT_FILE="$stdout_file" COMMAND_STDERR_FILE="$stderr_file" COMMAND_PID_FILE="$pid_file" COMMAND_WORK_DIR="$work_dir" COMMAND_ARTIFACT_DIR="$artifact_dir" \
                perl -MPOSIX=setsid -e '
use strict;
use warnings;

my $cmd = $ENV{"COMMAND_TEXT"};
my $stdout_path = $ENV{"COMMAND_STDOUT_FILE"};
my $stderr_path = $ENV{"COMMAND_STDERR_FILE"};
my $pid_file = $ENV{"COMMAND_PID_FILE"};
my $work_dir = $ENV{"COMMAND_WORK_DIR"} || ".";
my $artifact_dir = $ENV{"COMMAND_ARTIFACT_DIR"} || ".";
my $pid = fork();
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
    open STDIN, "<", "/dev/null" or die "stdin: $!";
    open STDOUT, ">", $stdout_path or die "stdout: $!";
    open STDERR, ">", $stderr_path or die "stderr: $!";
    setsid() or die "setsid: $!";
    chdir $work_dir or die "chdir: $!";
    $ENV{"AIMA_EXECUTION_SANDBOX"} = "1";
    $ENV{"AIMA_EXECUTION_WORKDIR"} = $work_dir;
    $ENV{"AIMA_EXECUTION_DIR"} = $artifact_dir;
    exec "bash", "-l", "-c", $cmd or die "exec: $!";
 }

open my $fh, ">", $pid_file or die "pidfile: $!";
print {$fh} $pid;
close $fh;
waitpid($pid, 0);
my $status = $?;
if ($status & 127) {
    exit(128 + ($status & 127));
 }
exit($status >> 8);
' &
            shell_pid=$!
            child_pid=""
            for _ in $(seq 1 50); do
                if [ -s "$pid_file" ]; then
                    child_pid="$(cat "$pid_file" 2>/dev/null || true)"
                    break
                fi
                if ! kill -0 "$shell_pid" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
            rm -f "$pid_file"
            if [ -z "$child_pid" ]; then
                child_pid="$shell_pid"
            fi
            LAUNCHED_COMMAND_WAIT_PID="$shell_pid"
            LAUNCHED_COMMAND_EXEC_PID="$child_pid"
            ;;
        setsid)
            (
                cd "$work_dir" || exit 1
                exec env \
                    AIMA_EXECUTION_SANDBOX=1 \
                    AIMA_EXECUTION_WORKDIR="$work_dir" \
                    AIMA_EXECUTION_DIR="$artifact_dir" \
                    setsid bash -l -c "$cmd"
            ) > "$stdout_file" 2> "$stderr_file" < /dev/null &
            child_pid=$!
            LAUNCHED_COMMAND_WAIT_PID="$child_pid"
            LAUNCHED_COMMAND_EXEC_PID="$child_pid"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

terminate_process_tree() {
    local cmd_pid="$1"
    if [ -z "$cmd_pid" ]; then
        return 0
    fi
    if [ "$COMMAND_RUNTIME_BACKEND" = "python3" ]; then
        "$PYTHON3_BIN" - "$cmd_pid" <<'PY'
import os
import signal
import sys
import time


pid = int(sys.argv[1])
for sig in (signal.SIGTERM, signal.SIGKILL):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        break
    except Exception:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            break
    if sig == signal.SIGTERM:
        time.sleep(1)
PY
        return 0
    fi
    kill -TERM -- "-${cmd_pid}" 2>/dev/null || kill -TERM "${cmd_pid}" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-${cmd_pid}" 2>/dev/null || kill -KILL "${cmd_pid}" 2>/dev/null || true
}

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }
step() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }

read_tty() {
    if tty_available; then
        stty sane < /dev/tty 2>/dev/null || true
    fi

    if [ "$READ_TTY_USE_READLINE" -eq 1 ]; then
        read -e -r "$@" < /dev/tty
        return
    fi

    read -r "$@" < /dev/tty
}

read_tty_plain() {
    if tty_available; then
        stty sane < /dev/tty 2>/dev/null || true
    fi

    read -r "$@" < /dev/tty
}

READ_TTY_ACTION=""
READ_TTY_VALUE=""

read_tty_with_hotkeys() {
    local allow_disconnect="${1:-0}"
    local allow_bind="${2:-0}"
    local idle_hook="${3:-}"
    local key="" escape_tail="" buffer=""
    local read_status=0

    READ_TTY_ACTION="unavailable"
    READ_TTY_VALUE=""
    if ! tty_available; then
        return 1
    fi

    stty sane < /dev/tty 2>/dev/null || true
    while true; do
        if [ -n "$idle_hook" ]; then
            IFS= read -rsn 1 -t "$ATTACH_IDLE_POLL_SECONDS" key < /dev/tty
            read_status=$?
            if [ "$read_status" -ne 0 ]; then
                local idle_result=""
                if ! tty_available; then
                    READ_TTY_ACTION="eof"
                    READ_TTY_VALUE="$buffer"
                    return 1
                fi
                idle_result="$($idle_hook 2>/dev/null || true)"
                if [ -n "$idle_result" ]; then
                    printf '\n'
                    READ_TTY_ACTION="refresh"
                    READ_TTY_VALUE="$idle_result"
                    return 0
                fi
                continue
            fi
        elif ! IFS= read -rsn 1 key < /dev/tty; then
            READ_TTY_ACTION="eof"
            READ_TTY_VALUE="$buffer"
            return 1
        fi

        case "$key" in
            ''|$'\n'|$'\r')
                # '' handles Enter when stty icrnl converts CR→NL and read
                # treats the NL as its delimiter, returning an empty key.
                printf '\n'
                READ_TTY_ACTION="submit"
                READ_TTY_VALUE="$buffer"
                return 0
                ;;
            $'\004')
                if [ "$allow_disconnect" = "1" ]; then
                    printf '\n'
                    READ_TTY_ACTION="disconnect"
                    READ_TTY_VALUE=""
                    return 0
                fi
                ;;
            $'\002')
                if [ "$allow_bind" = "1" ]; then
                    printf '\n'
                    READ_TTY_ACTION="bind"
                    READ_TTY_VALUE=""
                    return 0
                fi
                ;;
            $'\177'|$'\010')
                if [ -n "$buffer" ]; then
                    buffer="${buffer%?}"
                    printf '\b \b'
                fi
                ;;
            $'\033')
                IFS= read -rsn 2 -t 0.01 escape_tail < /dev/tty || true
                ;;
            *)
                case "$key" in
                    $'\000'|$'\001'|$'\002'|$'\003'|$'\005'|$'\006'|$'\007'|$'\013'|$'\014'|$'\016'|$'\017'|$'\020'|$'\021'|$'\022'|$'\023'|$'\024'|$'\025'|$'\026'|$'\027'|$'\030'|$'\031'|$'\032'|$'\034'|$'\035'|$'\036'|$'\037')
                        ;;
                    *)
                        buffer="${buffer}${key}"
                        printf '%s' "$key"
                        ;;
                esac
                ;;
        esac
    done
}

read_tty_paste_continuation() {
    if ! tty_available; then
        return 0
    fi

    local key="" escape_tail="" buffer="" saw_input=0
    while IFS= read -rsn 1 -t "$READ_TTY_PASTE_CONTINUATION_TIMEOUT" key < /dev/tty; do
        saw_input=1
        case "$key" in
            ''|$'\n'|$'\r')
                buffer="${buffer}"$'\n'
                ;;
            $'\177'|$'\010')
                if [ -n "$buffer" ]; then
                    buffer="${buffer%?}"
                fi
                ;;
            $'\033')
                IFS= read -rsn 2 -t 0.01 escape_tail < /dev/tty || true
                ;;
            *)
                case "$key" in
                    $'\000'|$'\001'|$'\002'|$'\003'|$'\005'|$'\006'|$'\007'|$'\013'|$'\014'|$'\016'|$'\017'|$'\020'|$'\021'|$'\022'|$'\023'|$'\024'|$'\025'|$'\026'|$'\027'|$'\030'|$'\031'|$'\032'|$'\034'|$'\035'|$'\036'|$'\037')
                        ;;
                    *)
                        buffer="${buffer}${key}"
                        ;;
                esac
                ;;
        esac
    done

    [ "$saw_input" -eq 1 ] || return 0
    buffer="${buffer#$'\r'}"
    buffer="${buffer#$'\n'}"
    printf '%s' "$buffer"
}

merge_tty_paste_continuation() {
    local initial="${1:-}"
    local continuation=""

    continuation="$(read_tty_paste_continuation || true)"
    if [ -n "$continuation" ]; then
        if [ -n "$initial" ]; then
            printf '%s\n%s' "$initial" "$continuation"
        else
            printf '%s' "$continuation"
        fi
        return 0
    fi

    printf '%s' "$initial"
}

tty_available() {
    [ -r /dev/tty ] && [ -w /dev/tty ]
}

invalid_hardware_signal() {
    case "${1:-}" in
        ""|"Not Specified"|"Default string"|"To be filled by O.E.M."|"None"|"Unknown")
            return 0
            ;;
    esac
    return 1
}

linux_collect_sorted_macs() {
    local only_physical="${1:-0}"
    local addr_file=""
    local iface=""
    local mac=""
    local macs=""

    for addr_file in /sys/class/net/*/address; do
        [ -e "$addr_file" ] || continue
        iface="$(basename "$(dirname "$addr_file")")"
        [ "$iface" = "lo" ] && continue
        if [ "$only_physical" = "1" ] && [ ! -e "/sys/class/net/${iface}/device" ]; then
            continue
        fi
        mac="$(tr '[:upper:]' '[:lower:]' < "$addr_file" 2>/dev/null || true)"
        case "$mac" in
            ""|"00:00:00:00:00:00") continue ;;
        esac
        macs="${macs}${mac}
"
    done

    [ -n "$macs" ] || return 1
    printf '%s' "$macs" | awk 'NF' | LC_ALL=C sort -u | paste -sd, -
}

linux_read_stable_hardware_signal() {
    local path=""
    local value=""

    for path in /sys/class/dmi/id/product_uuid /sys/class/dmi/id/product_serial /sys/class/dmi/id/board_serial; do
        [ -r "$path" ] || continue
        value="$(tr -d '\n' < "$path" 2>/dev/null || true)"
        if invalid_hardware_signal "$value"; then
            continue
        fi
        printf '%s' "$value"
        return 0
    done

    value="$(linux_collect_sorted_macs 1 || true)"
    if ! invalid_hardware_signal "$value"; then
        printf '%s' "$value"
        return 0
    fi

    return 1
}

linux_read_legacy_hardware_signal() {
    local value=""

    if [ -r /sys/class/dmi/id/product_uuid ]; then
        value="$(tr -d '\n' < /sys/class/dmi/id/product_uuid 2>/dev/null || true)"
    fi
    if { [ -z "$value" ] || [ "$value" = "Not Specified" ]; } && [ -r /sys/class/dmi/id/product_serial ]; then
        value="$(tr -d '\n' < /sys/class/dmi/id/product_serial 2>/dev/null || true)"
    fi
    if { [ -z "$value" ] || [ "$value" = "Not Specified" ]; } && [ -r /sys/class/dmi/id/board_serial ]; then
        value="$(tr -d '\n' < /sys/class/dmi/id/board_serial 2>/dev/null || true)"
    fi
    if [ -z "$value" ] || [ "$value" = "Not Specified" ] || [ "$value" = "Default string" ]; then
        value="$(ip link 2>/dev/null | awk '/^[0-9].*state UP/ { getline; if ($1 == "link/ether") { print $2; exit } }' | head -1 || true)"
    fi
    if [ -z "$value" ]; then
        value="$(tr -d '\n' < /etc/machine-id 2>/dev/null || tr -d '\n' < /var/lib/dbus/machine-id 2>/dev/null || true)"
    fi
    [ -n "$value" ] || return 1
    printf '%s' "$value"
}

prompt_for_invite_code() {
    local reason="${1:-}"
    if ! tty_available; then
        if [ -n "$reason" ]; then
            fail "${reason}"
        fi
        fail "$UX_INVITE_REQUIRED_NONINTERACTIVE"
    fi
    if [ -n "$reason" ]; then
        printf '\n'
        warn "$reason"
    fi
    printf '\n  %s\n  > ' "$UX_INVITE_PROMPT"
    read_tty INVITE_CODE || true
    if [ -z "$INVITE_CODE" ]; then
        fail "$UX_INVITE_REQUIRED"
    fi
}

prompt_for_recovery_code() {
    local reason="${1:-}"
    if ! tty_available; then
        if [ -n "$reason" ]; then
            fail "${reason}"
        fi
        fail "$UX_RECOVERY_REQUIRED_NONINTERACTIVE"
    fi
    if [ -n "$reason" ]; then
        printf '\n'
        warn "$reason"
    fi
    printf '\n  %s\n  > ' "$UX_RECOVERY_PROMPT"
    read_tty EXISTING_RECOVERY_CODE || true
    if [ -z "$EXISTING_RECOVERY_CODE" ]; then
        fail "$UX_RECOVERY_REQUIRED"
    fi
}

json_escape() {
    # Strip ANSI escape sequences (no semantic value in results), then
    # JSON-escape backslash, double-quote, and all control chars (\u0001-\u001F).
    printf '%s' "$1" | LC_ALL=C sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' | awk '
        BEGIN {
            ORS = ""
            first = 1
            _esc["\\"] = "\\\\"
            _esc["\""] = "\\\""
            for (i = 1; i <= 31; i++) {
                ch = sprintf("%c", i)
                if      (i == 9)  _esc[ch] = "\\t"
                else if (i == 13) _esc[ch] = "\\r"
                else              _esc[ch] = sprintf("\\u%04x", i)
            }
        }
        {
            if (!first) printf "\\n"
            first = 0
            out = ""
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c in _esc) out = out _esc[c]
                else           out = out c
            }
            printf "%s", out
        }
    '
}

hash_hardware_signal() {
    local raw_value="${1:-}"
    [ -n "$raw_value" ] || return 1
    printf '%s' "$raw_value" | shasum -a 256 2>/dev/null | cut -d' ' -f1 \
        || printf '%s' "$raw_value" | sha256sum 2>/dev/null | cut -d' ' -f1 \
        || return 1
}

write_recovery_state() {
    local recovery_code="${1:-}"
    local referral_code="${2:-}"

    cat > "$STATE_FILE" <<EOF
DEVICE_ID=
DEVICE_TOKEN=
RECOVERY_CODE=${recovery_code}
REFERRAL_CODE=${referral_code}
LAST_NOTIFIED_TASK_ID=
PLATFORM_URL=${BASE_URL}
DISPLAY_LANGUAGE=${DISPLAY_LANGUAGE}
EOF
    chmod 600 "$STATE_FILE"
}

clear_saved_state() {
    local preserved_recovery_code="${RECOVERY_CODE:-${EXISTING_RECOVERY_CODE:-}}"
    local preserved_referral_code="${MY_REFERRAL_CODE:-}"
    local preserved_display_language="${DISPLAY_LANGUAGE:-}"

    DEVICE_ID=""
    DEVICE_TOKEN=""
    RECOVERY_CODE="$preserved_recovery_code"
    EXISTING_RECOVERY_CODE="$preserved_recovery_code"
    LAST_NOTIFIED_TASK_ID=""
    if [ -n "$preserved_recovery_code" ] || [ -n "$preserved_referral_code" ] || [ -n "$preserved_display_language" ]; then
        write_recovery_state "$preserved_recovery_code" "$preserved_referral_code"
        return
    fi
    rm -f "$STATE_FILE"
}

persist_state_value() {
    local key="$1"
    local value="${2:-}"
    local tmp_state=""
    local found=0
    local line=""

    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    tmp_state="$(mktemp "${TMPDIR:-/tmp}/aima-state.XXXXXX")" || return
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "${key}="*)
                printf '%s=%s\n' "$key" "$value" >> "$tmp_state"
                found=1
                ;;
            *)
                printf '%s\n' "$line" >> "$tmp_state"
                ;;
        esac
    done < "$STATE_FILE"

    if [ "$found" -ne 1 ]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmp_state"
    fi

    chmod 600 "$tmp_state"
    mv "$tmp_state" "$STATE_FILE"
}

sync_saved_state_from_disk() {
    [ -f "$STATE_FILE" ] || return 1

    local line=""
    local state_device_id="${DEVICE_ID:-}"
    local state_device_token="${DEVICE_TOKEN:-}"
    local state_recovery_code="${RECOVERY_CODE:-${EXISTING_RECOVERY_CODE:-}}"
    local state_referral_code="${MY_REFERRAL_CODE:-}"
    local state_last_notified="${LAST_NOTIFIED_TASK_ID:-}"
    local state_platform_url="${BASE_URL}"
    local state_display_language="${DISPLAY_LANGUAGE:-}"

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            DEVICE_ID=*) state_device_id="${line#DEVICE_ID=}" ;;
            DEVICE_TOKEN=*) state_device_token="${line#DEVICE_TOKEN=}" ;;
            RECOVERY_CODE=*) state_recovery_code="${line#RECOVERY_CODE=}" ;;
            REFERRAL_CODE=*) state_referral_code="${line#REFERRAL_CODE=}" ;;
            LAST_NOTIFIED_TASK_ID=*) state_last_notified="${line#LAST_NOTIFIED_TASK_ID=}" ;;
            PLATFORM_URL=*) state_platform_url="${line#PLATFORM_URL=}" ;;
            DISPLAY_LANGUAGE=*) state_display_language="${line#DISPLAY_LANGUAGE=}" ;;
        esac
    done < "$STATE_FILE"

    DEVICE_ID="$state_device_id"
    DEVICE_TOKEN="$state_device_token"
    RECOVERY_CODE="$state_recovery_code"
    EXISTING_RECOVERY_CODE="$state_recovery_code"
    MY_REFERRAL_CODE="$state_referral_code"
    LAST_NOTIFIED_TASK_ID="$state_last_notified"
    DISPLAY_LANGUAGE="$state_display_language"
    state_platform_url="$(select_preferred_platform_url "$BASE_URL" "$state_platform_url")"
    [ -n "$state_platform_url" ] && BASE_URL="$state_platform_url"
    return 0
}

load_recovery_code_from_saved_state() {
    local saved_rc="" saved_url="" saved_state="" os_key="" cli_state_file=""

    [ -n "${EXISTING_RECOVERY_CODE:-${RECOVERY_CODE:-}}" ] && return 1

    cli_state_file="${HOME}/.aima-cli/device-state.json"
    if [ -f "$cli_state_file" ] && has_usable_python3; then
        saved_rc="$(
            CLI_STATE_FILE="$cli_state_file" "$PYTHON3_BIN" - <<'PY'
import json
import os
import sys

path = os.environ.get("CLI_STATE_FILE", "")
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)

value = data.get("recovery_code")
if isinstance(value, str):
    sys.stdout.write(value)
PY
        )"
        saved_url="$(
            CLI_STATE_FILE="$cli_state_file" "$PYTHON3_BIN" - <<'PY'
import json
import os
import sys

path = os.environ.get("CLI_STATE_FILE", "")
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)

value = data.get("platform_url")
if isinstance(value, str):
    sys.stdout.write(value)
PY
        )"
    fi

    case "$(uname -s 2>/dev/null || echo '')" in
        Linux) os_key="linux" ;;
        Darwin) os_key="macos" ;;
        *) os_key="" ;;
    esac

    for saved_state in \
        "$STATE_FILE" \
        "${HOME}/.aima-device-entry-smoke/${os_key}/.aima-device-state" \
        "${HOME}/.aima-device-entry-smoke/.aima-device-state"
    do
        [ -f "$saved_state" ] || continue
        [ -n "$saved_rc" ] || saved_rc="$(sed -n 's/^RECOVERY_CODE=//p' "$saved_state" | head -1)"
        [ -n "$saved_url" ] || saved_url="$(sed -n 's/^PLATFORM_URL=//p' "$saved_state" | head -1)"
        [ -n "$saved_rc" ] && break
    done

    if [ -z "$saved_rc" ] && [ -d "${HOME}/.aima-device-entry-smoke" ]; then
        while IFS= read -r saved_state; do
            [ -f "$saved_state" ] || continue
            saved_rc="$(sed -n 's/^RECOVERY_CODE=//p' "$saved_state" | head -1)"
            saved_url="$(sed -n 's/^PLATFORM_URL=//p' "$saved_state" | head -1)"
            [ -n "$saved_rc" ] && break
        done <<EOF
$(find "${HOME}/.aima-device-entry-smoke" -type f -name '.aima-device-state' 2>/dev/null)
EOF
    fi

    [ -n "$saved_rc" ] || return 1

    EXISTING_RECOVERY_CODE="$saved_rc"
    RECOVERY_CODE="$saved_rc"
    saved_url="$(select_preferred_platform_url "$BASE_URL" "$saved_url")"
    [ -n "$saved_url" ] && BASE_URL="$saved_url"
    return 0
}

auth_status_invalid() {
    case "${1:-}" in
        401|403|404) return 0 ;;
    esac
    return 1
}

device_request_with_status() {
    sync_saved_state_from_disk || true
    request_with_status "$@" -H "Authorization: Bearer ${DEVICE_TOKEN}"
    if auth_status_invalid "$HTTP_STATUS"; then
        sync_saved_state_from_disk || true
        request_with_status "$@" -H "Authorization: Bearer ${DEVICE_TOKEN}"
    fi
}

ensure_runtime_dir() {
    mkdir -p "$RUNTIME_DIR"
    chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
}

runtime_read_file() {
    local path="$1"
    [ -f "$path" ] || return 1
    cat "$path"
}

write_runtime_file() {
    local path="$1"
    local content="$2"
    local parent_dir tmp_path
    ensure_runtime_dir
    parent_dir="$(dirname "$path")"
    mkdir -p "$parent_dir"
    chmod 700 "$parent_dir" 2>/dev/null || true
    umask 077
    tmp_path="$(mktemp "${path}.tmp.XXXXXX" 2>/dev/null || true)"
    if [ -z "$tmp_path" ]; then
        printf '%s' "$content" > "$path"
        chmod 600 "$path" 2>/dev/null || true
        return 0
    fi
    printf '%s' "$content" > "$tmp_path"
    chmod 600 "$tmp_path" 2>/dev/null || true
    mv -f "$tmp_path" "$path"
}

append_owner_log_line() {
    local level="${1:-INFO}"
    shift || true
    local message="$*"

    [ -n "$message" ] || return 0
    ensure_runtime_dir
    umask 077
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$message" >> "$OWNER_LOG_FILE"
    chmod 600 "$OWNER_LOG_FILE" 2>/dev/null || true
}

clear_runtime_ephemeral_files() {
    rm -f "$OWNER_HEARTBEAT_FILE" "$SESSION_STATUS_FILE" "$PENDING_INTERACTION_FILE" "$INTERACTION_ANSWER_FILE" "$TASK_COMPLETION_FILE" "$DISCONNECT_REQUEST_FILE"
}

clear_task_runtime_state() {
    rm -f "$PENDING_INTERACTION_FILE" "$INTERACTION_ANSWER_FILE" "$SESSION_STATUS_FILE" "$TASK_COMPLETION_FILE"
}

reset_attach_runtime_cache() {
    ATTACH_LAST_STATUS_KEY=""
    ATTACH_LAST_INTERACTION_ID=""
    ATTACH_DEFERRED_INTERACTION_ID=""
    ATTACH_INTERACTION_RETRY_AFTER_TS=0
    ATTACH_LAST_COMPLETION_ID=""
}

clear_runtime_owner_bootstrap_files() {
    rm -f "$OWNER_HEARTBEAT_FILE" "$PENDING_INTERACTION_FILE" "$INTERACTION_ANSWER_FILE" "$SESSION_STATUS_FILE" "$TASK_COMPLETION_FILE" "$DISCONNECT_REQUEST_FILE"
}

write_session_status() {
    local phase="${1:-progress}"
    local level="${2:-info}"
    local message="${3:-}"
    local active_task_id="${4:-${ACTIVE_TASK_ID:-}}"
    local escaped_phase escaped_level escaped_message escaped_task
    escaped_phase="$(json_escape "$phase")"
    escaped_level="$(json_escape "$level")"
    escaped_message="$(json_escape "$message")"
    escaped_task="$(json_escape "$active_task_id")"
    write_runtime_file "$SESSION_STATUS_FILE" "{\"phase\":\"${escaped_phase}\",\"level\":\"${escaped_level}\",\"message\":\"${escaped_message}\",\"active_task_id\":\"${escaped_task}\",\"updated_at\":\"$(date +%s)\"}"
}

write_owner_heartbeat() {
    local phase="${1:-idle}"
    local active_task_id="${2:-${ACTIVE_TASK_ID:-}}"
    local command_id="${3:-}"
    local escaped_pid escaped_device escaped_phase escaped_task escaped_command

    [ "$RUN_AS_OWNER" -eq 1 ] || return 0

    escaped_pid="$(json_escape "$$")"
    escaped_device="$(json_escape "${DEVICE_ID:-}")"
    escaped_phase="$(json_escape "$phase")"
    escaped_task="$(json_escape "$active_task_id")"
    escaped_command="$(json_escape "$command_id")"
    write_runtime_file "$OWNER_HEARTBEAT_FILE" "{\"pid\":\"${escaped_pid}\",\"device_id\":\"${escaped_device}\",\"phase\":\"${escaped_phase}\",\"active_task_id\":\"${escaped_task}\",\"command_id\":\"${escaped_command}\",\"updated_at\":\"$(date +%s)\"}"
}

write_pending_interaction_file() {
    local interaction_id="$1"
    local question="$2"
    local interaction_type="${3:-info_request}"
    local interaction_level="${4:-info}"
    local interaction_phase="${5:-progress}"
    local display_question="${6:-}"
    local active_task_id="${7:-${ACTIVE_TASK_ID:-}}"
    local escaped_id escaped_question escaped_type escaped_level escaped_phase escaped_display escaped_task
    escaped_id="$(json_escape "$interaction_id")"
    escaped_question="$(json_escape "$question")"
    escaped_type="$(json_escape "$interaction_type")"
    escaped_level="$(json_escape "$interaction_level")"
    escaped_phase="$(json_escape "$interaction_phase")"
    escaped_display="$(json_escape "$display_question")"
    escaped_task="$(json_escape "$active_task_id")"
    write_runtime_file "$PENDING_INTERACTION_FILE" "{\"interaction_id\":\"${escaped_id}\",\"question\":\"${escaped_question}\",\"interaction_type\":\"${escaped_type}\",\"interaction_level\":\"${escaped_level}\",\"interaction_phase\":\"${escaped_phase}\",\"display_question\":\"${escaped_display}\",\"active_task_id\":\"${escaped_task}\",\"updated_at\":\"$(date +%s)\"}"
}

clear_pending_interaction_file() {
    rm -f "$PENDING_INTERACTION_FILE" "$INTERACTION_ANSWER_FILE"
}

write_interaction_answer_file() {
    local interaction_id="$1"
    local answer="$2"
    local escaped_id escaped_answer
    escaped_id="$(json_escape "$interaction_id")"
    escaped_answer="$(json_escape "$answer")"
    write_runtime_file "$INTERACTION_ANSWER_FILE" "{\"interaction_id\":\"${escaped_id}\",\"answer\":\"${escaped_answer}\",\"updated_at\":\"$(date +%s)\"}"
}

write_task_completion_file() {
    local task_id="$1"
    local task_status="$2"
    local budget_tasks_remaining="$3"
    local budget_tasks_total="$4"
    local budget_usd_remaining="$5"
    local budget_usd_total="$6"
    local referral_code="$7"
    local share_text="$8"
    local task_message="${9:-}"
    local budget_warning="${10:-}"
    local budget_binding_incentive="${11:-}"
    local escaped_task escaped_status escaped_tasks_remaining escaped_tasks_total
    local escaped_usd_remaining escaped_usd_total escaped_referral escaped_share escaped_message
    local escaped_budget_warning escaped_budget_binding_incentive
    escaped_task="$(json_escape "$task_id")"
    escaped_status="$(json_escape "$task_status")"
    escaped_tasks_remaining="$(json_escape "$budget_tasks_remaining")"
    escaped_tasks_total="$(json_escape "$budget_tasks_total")"
    escaped_usd_remaining="$(json_escape "$budget_usd_remaining")"
    escaped_usd_total="$(json_escape "$budget_usd_total")"
    escaped_referral="$(json_escape "$referral_code")"
    escaped_share="$(json_escape "$share_text")"
    escaped_message="$(json_escape "$task_message")"
    escaped_budget_warning="$(json_escape "$budget_warning")"
    escaped_budget_binding_incentive="$(json_escape "$budget_binding_incentive")"
    write_runtime_file "$TASK_COMPLETION_FILE" "{\"task_id\":\"${escaped_task}\",\"task_status\":\"${escaped_status}\",\"budget_tasks_remaining\":\"${escaped_tasks_remaining}\",\"budget_tasks_total\":\"${escaped_tasks_total}\",\"budget_usd_remaining\":\"${escaped_usd_remaining}\",\"budget_usd_total\":\"${escaped_usd_total}\",\"referral_code\":\"${escaped_referral}\",\"share_text\":\"${escaped_share}\",\"task_message\":\"${escaped_message}\",\"budget_warning\":\"${escaped_budget_warning}\",\"budget_binding_incentive\":\"${escaped_budget_binding_incentive}\",\"updated_at\":\"$(date +%s)\"}"
}

owner_pid() {
    [ -f "$OWNER_PID_FILE" ] || return 1
    local pid=""
    pid="$(sed -n '1p' "$OWNER_PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    printf '%s\n' "$pid"
}

owner_is_running() {
    local pid=""
    pid="$(owner_pid 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

owner_session_healthy() {
    owner_session_health_detail >/dev/null 2>&1
}

owner_heartbeat_active_task_id() {
    local heartbeat_payload=""
    heartbeat_payload="$(runtime_read_file "$OWNER_HEARTBEAT_FILE" || true)"
    json_str active_task_id "$heartbeat_payload"
}

owner_session_health_detail() {
    local heartbeat_payload updated_at heartbeat_device_id now age

    if ! owner_is_running; then
        printf 'owner pid missing or process not running'
        return 1
    fi
    heartbeat_payload="$(runtime_read_file "$OWNER_HEARTBEAT_FILE" || true)"
    if [ -z "$heartbeat_payload" ]; then
        printf 'owner heartbeat file missing'
        return 1
    fi

    updated_at="$(json_str updated_at "$heartbeat_payload")"
    case "$updated_at" in
        ''|*[!0-9]*)
            printf 'owner heartbeat missing updated_at'
            return 1
            ;;
    esac

    local phase active_task_id command_id
    phase="$(json_str phase "$heartbeat_payload")"
    active_task_id="$(json_str active_task_id "$heartbeat_payload")"
    command_id="$(json_str command_id "$heartbeat_payload")"
    [ -n "$phase" ] || phase="unknown"
    [ -n "$active_task_id" ] || active_task_id="-"
    [ -n "$command_id" ] || command_id="-"

    now="$(date +%s)"
    age=$((now - updated_at))
    if [ "$age" -lt 0 ] 2>/dev/null; then
        age=0
    fi
    if ! [ "$age" -le "$OWNER_HEARTBEAT_STALE_SECONDS" ]; then
        printf 'owner heartbeat stale (age=%ss, phase=%s, active_task=%s, command_id=%s)' "$age" "$phase" "$active_task_id" "$command_id"
        return 1
    fi

    heartbeat_device_id="$(json_str device_id "$heartbeat_payload")"
    if [ -n "${DEVICE_ID:-}" ] && [ -n "$heartbeat_device_id" ] && [ "$heartbeat_device_id" != "$DEVICE_ID" ]; then
        printf 'owner heartbeat device mismatch (heartbeat=%s, current=%s)' "$heartbeat_device_id" "$DEVICE_ID"
        return 1
    fi

    printf 'owner heartbeat healthy (age=%ss, phase=%s, active_task=%s, command_id=%s)' "$age" "$phase" "$active_task_id" "$command_id"
    return 0
}

install_owner_script() {
    ensure_runtime_dir
    local script_source="${BASH_SOURCE[0]:-}"
    if [ -n "$script_source" ] && [ -f "$script_source" ] && [ "${script_source#/dev/fd/}" = "$script_source" ]; then
        cp "$script_source" "$OWNER_SCRIPT_PATH"
    else
        local owner_url="${BASE_URL%/api/v1}/go.sh"
        curl -fsS "$owner_url" -o "$OWNER_SCRIPT_PATH"
    fi
    chmod 700 "$OWNER_SCRIPT_PATH"
}

start_owner_process() {
    local owner_bootstrap_mode="${1:-restore}"
    ensure_runtime_dir
    if owner_session_healthy; then
        return 0
    fi
    if owner_is_running; then
        stop_owner_process
    fi
    install_owner_script || return 1
    clear_runtime_owner_bootstrap_files
    nohup bash "$OWNER_SCRIPT_PATH" --owner --owner-bootstrap-mode "$owner_bootstrap_mode" >> "$OWNER_LOG_FILE" 2>&1 &
    local pid=$!
    local attempts=0
    printf '%s\n' "$pid" > "$OWNER_PID_FILE"
    chmod 600 "$OWNER_PID_FILE" 2>/dev/null || true
    while [ "$attempts" -lt 30 ]; do
        if owner_session_healthy; then
            return 0
        fi
        sleep 0.5
        attempts=$((attempts + 1))
    done
    return 1
}

stop_owner_process() {
    local pid=""
    pid="$(owner_pid 2>/dev/null || true)"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$OWNER_PID_FILE"
}

wait_for_owner_shutdown() {
    local attempts=0
    while [ "$attempts" -lt 25 ]; do
        if ! owner_is_running; then
            return 0
        fi
        sleep 0.2
        attempts=$((attempts + 1))
    done
    return 1
}

upsert_interaction_retry_at() {
    local interaction_id="$1"
    local retry_at="$2"
    local updated=""
    local entry=""
    for entry in $interaction_retry_at; do
        case "$entry" in
            "${interaction_id}:"*) continue ;;
        esac
        updated="${updated} ${entry}"
    done
    interaction_retry_at="${updated} ${interaction_id}:${retry_at}"
}

interaction_retry_wait() {
    local interaction_id="$1"
    local now entry retry_at
    now="$(date +%s)"
    for entry in $interaction_retry_at; do
        case "$entry" in
            "${interaction_id}:"*)
                retry_at="${entry#*:}"
                if [ "$retry_at" -gt "$now" ] 2>/dev/null; then
                    printf '%s\n' "$((retry_at - now))"
                    return 0
                fi
                return 1
                ;;
        esac
    done
    return 1
}

clear_interaction_retry() {
    local interaction_id="$1"
    local updated=""
    local entry=""
    for entry in $interaction_retry_at; do
        case "$entry" in
            "${interaction_id}:"*) continue ;;
        esac
        updated="${updated} ${entry}"
    done
    interaction_retry_at="$updated"
}

copy_to_clipboard() {
    local text="$1"
    if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$text" | pbcopy && return 0
    elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$text" | xclip -selection clipboard 2>/dev/null && return 0
    elif command -v xsel >/dev/null 2>&1; then
        printf '%s' "$text" | xsel --clipboard 2>/dev/null && return 0
    fi
    return 1
}

open_browser_url() {
    local url="${1:-}"
    [ -n "$url" ] || return 1
    if [ "$(uname)" = "Darwin" ]; then
        open "$url" >/dev/null 2>&1 || return 1
        return 0
    fi
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 || return 1
        return 0
    fi
    return 1
}

initiate_binding() {
    local fingerprint
    fingerprint="${ESCAPED_FINGERPRINT:-$(json_escape "${FINGERPRINT}")}"
    local os_profile
    os_profile="${OS_PROFILE:-$(get_os_profile_json)}"
    local binding_body
    binding_body="{\"fingerprint\":\"${fingerprint}\",\"os_profile\":${os_profile}}"
    local -a binding_headers
    binding_headers=(-H "Content-Type: application/json")
    if [ -n "${DEVICE_ID:-}" ] && [ -n "${DEVICE_TOKEN:-}" ]; then
        binding_body="{\"device_id\":\"$(json_escape "${DEVICE_ID}")\",\"fingerprint\":\"${fingerprint}\",\"os_profile\":${os_profile}}"
        binding_headers+=(-H "Authorization: Bearer ${DEVICE_TOKEN}")
    fi

    printf '\n  \033[2m%s\033[0m\n' "$(lang_text "正在启动绑定流程..." "Starting binding flow...")"
    
    local resp
    request_with_status --max-time 15 -X POST \
        "${binding_headers[@]}" \
        -d "${binding_body}" \
        "${BASE_URL}/device-flows"
    
    if [ "${HTTP_CURL_EXIT}" -ne 0 ] || [ "${HTTP_STATUS}" != "200" ]; then
        err "$(lang_text "无法启动绑定流程" "Failed to start binding flow.") (HTTP ${HTTP_STATUS})"
        return 1
    fi
    resp="$HTTP_BODY"

    local user_code verification_uri verification_uri_with_code
    user_code="$(json_str user_code "$resp")"
    verification_uri="$(json_str verification_uri "$resp")"
    verification_uri_with_code="${verification_uri}?user_code=${user_code}"

    if [ -z "$user_code" ] || [ -z "$verification_uri" ]; then
        err "$(lang_text "服务器返回了无效的绑定信息" "Server returned invalid binding info.")"
        return 1
    fi

    printf '\n'
    printf '\033[35m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '  \033[1m%s\033[0m\n' "$(lang_text "绑定设备到控制台" "Link Device to Console")"
    printf '\033[35m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '  1. %s\n' "$(lang_text "在浏览器中打开" "Open in browser:")"
    printf '     \033[4;34m%s\033[0m\n\n' "$verification_uri_with_code"
    printf '  2. %s\n' "$(lang_text "输入设备码" "Enter device code:")"
    printf '     \033[1;33m%s\033[0m\n\n' "$user_code"
    printf '  \033[2m%s\033[0m\n' "$(lang_text "浏览器会先检查控制台登录，再继续绑定。" "The browser will verify Console login before continuing the binding flow.")"
    printf '\033[35m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'

    open_browser_url "$verification_uri_with_code" || true

    printf '\n  \033[2m%s\033[0m\n' "$(lang_text "浏览器已打开。完成绑定后，终端会在下一次状态刷新时显示最新结果。" "Browser opened. The terminal will show the latest binding state on the next refresh.")"
    if [ -n "${DEVICE_ID:-}" ] && [ -n "${DEVICE_TOKEN:-}" ]; then
        refresh_binding_state || true
    fi
}

complete_browser_recovery_flow() {
    local recovery_resp="$1"
    local user_code device_code verification_uri verification_uri_with_code poll_interval flow_status poll_resp
    user_code="$(json_str user_code "$recovery_resp")"
    device_code="$(json_str device_code "$recovery_resp")"
    verification_uri="$(json_str verification_uri "$recovery_resp")"
    verification_uri_with_code="$(json_str verification_uri_complete "$recovery_resp")"
    poll_interval="$(json_int interval "$recovery_resp")"
    poll_interval="${poll_interval:-2}"

    if [ -z "$user_code" ] || [ -z "$device_code" ] || [ -z "$verification_uri" ]; then
        err "$(lang_text "服务器返回了无效的恢复确认信息" "Server returned invalid recovery confirmation info.")"
        return 1
    fi
    if [ -z "$verification_uri_with_code" ]; then
        verification_uri_with_code="${verification_uri}?user_code=${user_code}"
    fi

    printf '\n'
    printf '\033[35m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '  \033[1m%s\033[0m\n' "$(lang_text "在浏览器中确认恢复设备" "Confirm Device Recovery in Browser")"
    printf '\033[35m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '  1. %s\n' "$(lang_text "在浏览器中打开" "Open in browser:")"
    printf '     \033[4;34m%s\033[0m\n\n' "$verification_uri_with_code"
    printf '  2. %s\n' "$(lang_text "输入设备码" "Enter device code:")"
    printf '     \033[1;33m%s\033[0m\n\n' "$user_code"
    printf '  \033[2m%s\033[0m\n' "$(lang_text "请使用原来的 device manager 账号确认恢复。确认后终端会自动继续。" "Please sign in with the original device manager account to confirm recovery. The terminal will continue automatically after approval.")"
    printf '\033[35m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'

    open_browser_url "$verification_uri_with_code" || true
    printf '\n  \033[2m%s\033[0m\n' "$(lang_text "浏览器已打开。正在等待恢复确认..." "Browser opened. Waiting for recovery confirmation...")"

    while true; do
        request_with_status --max-time 15 "${BASE_URL}/device-flows/${device_code}/poll"
        if [ "${HTTP_CURL_EXIT}" -ne 0 ] || [ "${HTTP_STATUS}" != "200" ]; then
            sleep "$poll_interval"
            continue
        fi

        poll_resp="$HTTP_BODY"
        flow_status="$(json_str status "$poll_resp")"
        case "$flow_status" in
            bound)
                DEVICE_ID="$(json_str device_id "$poll_resp")"
                DEVICE_TOKEN="$(json_str token "$poll_resp")"
                RECOVERY_CODE="$(json_str recovery_code "$poll_resp")"
                EXISTING_RECOVERY_CODE="$RECOVERY_CODE"
                if [ -z "$DEVICE_ID" ] || [ -z "$DEVICE_TOKEN" ] || [ -z "$RECOVERY_CODE" ]; then
                    err "$(lang_text "恢复确认完成，但平台返回的凭据不完整" "Recovery confirmation succeeded, but the platform returned incomplete credentials.")"
                    return 1
                fi
                ok "$(lang_text "浏览器已确认，设备恢复成功。" "Browser confirmation complete. Device recovery succeeded.")"
                return 0
                ;;
            expired)
                err "$(lang_text "恢复确认已过期，请重新运行 /go" "Recovery confirmation expired. Please rerun /go.")"
                return 1
                ;;
            denied)
                err "$(lang_text "恢复确认被拒绝，请检查登录账号或重新发起恢复" "Recovery confirmation was denied. Check the signed-in account or restart recovery.")"
                return 1
                ;;
        esac

        sleep "$poll_interval"
    done
}

show_task_completion_card() {
    local task_status="$1"
    local budget_tasks_remaining="$2"
    local budget_tasks_total="$3"
    local budget_usd_remaining="$4"
    local budget_usd_total="$5"
    local referral_code="$6"
    local share_text="$7"
    local task_message="${8:-}"
    local budget_warning="${9:-}"
    local budget_binding_incentive="${10:-}"

    refresh_window_title

    if [ "$task_status" = "succeeded" ]; then
        printf '\n'
        printf '\033[36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
        printf '  \033[1;32m✓\033[0m \033[1m%s\033[0m\n' "$UX_TASK_COMPLETION_SUCCESS_TITLE"
        if [ -n "$task_message" ]; then
            printf '  %s: %s\n' "$(lang_text "说明" "Message")" "$task_message"
        fi
        if [ -n "$budget_tasks_remaining" ] || [ -n "$budget_tasks_total" ]; then
            printf '  %s: \033[1m%s\033[0m\n' \
                "$(lang_text "任务额度" "Task budget")" \
                "$(format_task_budget_remaining_line "$budget_tasks_remaining" "$budget_tasks_total")"
        fi
        if [ -n "$budget_usd_remaining" ] || [ -n "$budget_usd_total" ]; then
            printf '  %s: \033[1m%s\033[0m\n' \
                "$(lang_text "金额额度" "Amount budget")" \
                "$(format_amount_budget_remaining_line "$budget_usd_remaining" "$budget_usd_total")"
        fi

        if [ -n "$budget_warning" ]; then
            printf '\n  \033[1;33m⚠ %s\033[0m\n' "$budget_warning"
            if [ -n "$budget_binding_incentive" ]; then
                printf '  \033[33m💡 %s\033[0m\n' "$budget_binding_incentive"
            fi
        fi

        if [ -n "$referral_code" ]; then
            printf '\n  \033[33m%s\033[0m\n' "$UX_TASK_COMPLETION_SHARE_HEADING"
            printf '  %s\n' "$(lang_text "每邀请一位好友，双方各得 $10 + 5 次任务额度" "Invite a friend and both of you get $10 + 5 task credits.")"
            printf '  %s: \033[1;33m%s\033[0m\n' "$(lang_text "推荐码" "Referral code")" "$referral_code"
            printf '  \033[2m%s\033[0m\n' "$UX_TASK_COMPLETION_SHARE_PROMPT"
        fi

        if [ "$IS_BOUND" -eq 0 ]; then
            printf '\n  \033[35m%s\033[0m\n' "$(lang_text "想在控制台里管理这台设备？" "Manage this device in Console?")"
            printf '  %s\n' "$(lang_text "绑定到 Console workspace，开启审批、历史和预算。" "Bind this device to Console to unlock approvals, history, and budget control.")"
            printf '  \033[1;45;37m %s \033[0m\n' "$UX_TASK_COMPLETION_BIND_PROMPT"
        fi
        printf '\033[36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'

        if { [ -n "$referral_code" ] || [ "$IS_BOUND" -eq 0 ]; } && tty_available; then
            printf '\n  > '
            read_tty_with_hotkeys 0 1 || true
            if [ "$READ_TTY_ACTION" = "bind" ]; then
                initiate_binding
            elif [ "$READ_TTY_ACTION" = "submit" ] && { [ "$READ_TTY_VALUE" = "c" ] || [ "$READ_TTY_VALUE" = "C" ]; }; then
                if [ -n "$share_text" ] && copy_to_clipboard "$share_text"; then
                    ok "$UX_TASK_COMPLETION_COPIED_NOTICE"
                else
                    # Fallback: display the text for manual copy
                    printf '\n  \033[2m--- 复制以下文字分享 Copy text below ---\033[0m\n'
                    printf '  %s\n' "$share_text"
                    printf '  \033[2m--- end ---\033[0m\n'
                fi
            fi
        fi
    elif [ "$task_status" = "failed" ]; then
        printf '\n  \033[31m❌ %s.\033[0m\n' "$UX_TASK_COMPLETION_FAILURE_TITLE"
        if [ -n "$task_message" ]; then
            printf '  %s: %s\n' "$(lang_text "原因" "Reason")" "$task_message"
        fi
        if [ -n "$budget_tasks_remaining" ] || [ -n "$budget_tasks_total" ]; then
            printf '  %s: %s\n' \
                "$(lang_text "任务额度" "Task budget")" \
                "$(format_task_budget_remaining_line "$budget_tasks_remaining" "$budget_tasks_total")"
        fi
        if [ -n "$budget_usd_remaining" ] || [ -n "$budget_usd_total" ]; then
            printf '  %s: %s\n' \
                "$(lang_text "金额额度" "Amount budget")" \
                "$(format_amount_budget_remaining_line "$budget_usd_remaining" "$budget_usd_total")"
        fi
    fi
}

render_agent_notification() {
    local phase="${1:-progress}"
    local level="${2:-info}"
    local message="$3"
    local label
    local color="36"

    [ -n "$message" ] || return 0
    if [ "$RUN_AS_OWNER" -eq 1 ]; then
        write_session_status "$phase" "$level" "$message"
    fi

    label="$(lang_text "更新" "Update")"
    case "$phase" in
        start) label="$(lang_text "AIMA" "AIMA")"; color="36" ;;
        action) label="$(lang_text "操作" "Action")"; color="36" ;;
        decision) label="$(lang_text "决策" "Decision")"; color="33" ;;
        waiting) label="$(lang_text "等待" "Waiting")"; color="34" ;;
        result) label="$(lang_text "结果" "Result")"; color="32" ;;
        progress) label="$(lang_text "更新" "Update")"; color="36" ;;
    esac

    case "$level" in
        warning) label="$(lang_text "警告" "Warning")"; color="33" ;;
        error) label="$(lang_text "错误" "Error")"; color="31" ;;
    esac

    printf '\n  \033[%sm[%s]\033[0m %s\n' "$color" "$label" "$message"
}

print_execution_separator() {
    printf '\033[2m─── %s ────────────────────────────────\033[0m\n' "$(lang_text "执行" "Execution")"
}

respond_interaction() {
    local interaction_id="$1"
    local answer="$2"
    local escaped status_code
    escaped="$(json_escape "$answer")"
    status_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
        "${BASE_URL}/devices/${DEVICE_ID}/interactions/${interaction_id}/respond" \
        -H "Authorization: Bearer ${DEVICE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"answer\":\"${escaped}\"}" 2>/dev/null || true)"
    [ "$status_code" = "200" ]
}

# ── Functions ────────────────────────────────────────────────────

disconnect_device() {
    if [ "${CLEANUP_DONE:-0}" -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1

    if [ -z "${DEVICE_ID:-}" ] || [ -z "${DEVICE_TOKEN:-}" ]; then
        return
    fi

    trap '' HUP INT TERM

    printf '\n\n  %s\n' "$(lang_text "正在断开连接..." "Disconnecting...")"
    device_request_with_status --max-time 5 -X POST "${BASE_URL}/devices/${DEVICE_ID}/offline"
    ok "$(lang_text "已断开。重新运行即可重连。" "Disconnected. Run again to reconnect.")"
    clear_runtime_ephemeral_files
    rm -f "$OWNER_PID_FILE"
}

cleanup_and_exit() {
    disconnect_device
    exit 0
}

detach_launcher() {
    if [ "${CLEANUP_DONE:-0}" -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1
    printf '\n\n  %s\n' "$(lang_text "已退出前台界面。" "Detached from device session.")"
    printf '  %s\n' "$(lang_text "设备会继续在后台保持连接，重新运行即可恢复界面。" "The device stays connected in the background. Run again to reattach.")"
}

launcher_exit() {
    local exit_code=$?
    if [ "$RUN_AS_OWNER" -eq 1 ] || [ "$EXPLICIT_DISCONNECT_REQUESTED" -eq 1 ]; then
        return
    fi
    if [ "$ATTACH_MODE_STARTED" -eq 1 ]; then
        if [ "$DETACH_REQUESTED" -eq 1 ] || [ "$exit_code" -eq 0 ]; then
            detach_launcher
            return
        fi
    fi
    if [ -n "${DEVICE_ID:-}" ] && [ -n "${DEVICE_TOKEN:-}" ]; then
        disconnect_device
    fi
}

detach_and_exit() {
    detach_launcher
    exit 0
}

DETACH_REQUESTED=0
request_detach() {
    DETACH_REQUESTED=1
    trap '' INT
}

if [ "$RUN_AS_OWNER" -eq 1 ]; then
    ensure_runtime_dir
    sync_saved_state_from_disk || true
    if [ -n "$DISPLAY_LANGUAGE" ]; then
        reload_ux_strings
    fi
    printf '\n─── owner restart pid=%s %s ───\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$OWNER_LOG_FILE"
    trap 'append_owner_log_line "ERROR" "set -e killed owner at line ${LINENO:-?} cmd=${BASH_COMMAND:-?}"' ERR
    clear_runtime_owner_bootstrap_files
    printf '%s\n' "$$" > "$OWNER_PID_FILE"
    chmod 600 "$OWNER_PID_FILE" 2>/dev/null || true
    write_session_status "start" "info" "$UX_BACKGROUND_SESSION_BOOTING"
    write_owner_heartbeat "booting" "$ACTIVE_TASK_ID"
    trap 'disconnect_device' EXIT
    trap 'cleanup_and_exit' INT TERM HUP
else
    trap 'launcher_exit' EXIT
    trap 'request_detach' INT
    trap 'detach_and_exit' TERM HUP
fi

poll_hotkey_action() {
    local key=""
    if ! tty_available; then
        return 1
    fi
    if IFS= read -rsn 1 -t "$HOTKEY_READ_TIMEOUT_SECONDS" key < /dev/tty; then
        case "$key" in
            $'\002')
                printf 'bind'
                return 0
                ;;
            $'\v')
                printf 'cancel'
                return 0
                ;;
            $'\004')
                printf 'disconnect'
                return 0
                ;;
        esac
    fi
    return 1
}

fetch_active_task() {
    device_request_with_status "${BASE_URL}/devices/${DEVICE_ID}/active-task"
    if [ "${HTTP_CURL_EXIT}" -eq 0 ] && [ "${HTTP_STATUS}" = "200" ]; then
        printf '%s' "$HTTP_BODY"
    fi
}

sync_active_task_from_platform() {
    local active_resp active_id
    active_resp="$(fetch_active_task)"
    active_id="$(json_str task_id "$active_resp")"
    [ -n "$active_id" ] || return 1
    ACTIVE_TASK_ID="$active_id"
    ACTIVE_TASK_LOOKUP_MISSES=0
    return 0
}

recover_active_task_after_submit_failure() {
    local submitted_description="${1:-}"
    local active_resp active_id active_target
    active_resp="$(fetch_active_task)"
    active_id="$(json_str task_id "$active_resp")"
    active_target="$(json_str target "$active_resp")"
    [ -n "$active_id" ] || return 1

    ACTIVE_TASK_ID="$active_id"
    CONFIRMED_ACTIVE_TASK_ID="$active_id"
    ACTIVE_TASK_LOOKUP_MISSES=0
    warn "$(lang_text "任务提交响应中断，已附着到当前任务" "Task submit response was interrupted; attached to the current task"): ${active_id}"
    if [ -n "$active_target" ]; then
        printf '  \033[2m  %s\033[0m\n' "$active_target"
    elif [ -n "$submitted_description" ]; then
        printf '  \033[2m  %s\033[0m\n' "$submitted_description"
    fi
    return 0
}

refresh_binding_state() {
    device_request_with_status --max-time 5 "${BASE_URL}/devices/${DEVICE_ID}/session"
    if [ "${HTTP_CURL_EXIT}" -eq 0 ] && [ "${HTTP_STATUS}" = "200" ]; then
        local bound_val
        bound_val="$(json_bool is_bound "$HTTP_BODY")"
        if [ "$bound_val" = "true" ]; then
            IS_BOUND=1
        else
            IS_BOUND=0
        fi
        return 0
    fi
    return 1
}

refresh_account_snapshot() {
    device_request_with_status --max-time 5 "${BASE_URL}/devices/${DEVICE_ID}/account"
    if [ "${HTTP_CURL_EXIT}" -ne 0 ] || [ "${HTTP_STATUS}" != "200" ]; then
        return 1
    fi

    sync_budget_snapshot_from_payload "$HTTP_BODY"
    local bound_val referral_code
    bound_val="$(json_bool is_bound "$HTTP_BODY")"
    referral_code="$(json_str referral_code "$HTTP_BODY")"
    if [ "$bound_val" = "true" ]; then
        IS_BOUND=1
    else
        IS_BOUND=0
    fi
    if [ -n "$referral_code" ]; then
        MY_REFERRAL_CODE="$referral_code"
    fi
    return 0
}

cancel_active_task() {
    local active_resp task_id status_code
    active_resp="$(fetch_active_task)"
    task_id="${ACTIVE_TASK_ID:-$(json_str task_id "$active_resp")}"
    if [ -z "$task_id" ]; then
        return 1
    fi

    device_request_with_status -X POST "${BASE_URL}/devices/${DEVICE_ID}/tasks/${task_id}/cancel"
    status_code="${HTTP_STATUS:-000}"
    if [ "$status_code" = "200" ]; then
        LAST_LOCALLY_CANCELLED_TASK_ID="$task_id"
        ACTIVE_TASK_ID=""
        CONFIRMED_ACTIVE_TASK_ID=""
        ACTIVE_TASK_LOOKUP_MISSES=0
        LOCAL_CANCEL_REQUESTED=1
        clear_task_runtime_state
        reset_attach_runtime_cache
        warn "$(lang_text "当前任务已取消" "Current task cancelled")"
        return 0
    fi

    active_resp="$(fetch_active_task)"
    task_id_now="$(json_str task_id "$active_resp")"
    if [ -z "$task_id_now" ] || [ "$task_id_now" != "$task_id" ]; then
        LAST_LOCALLY_CANCELLED_TASK_ID="$task_id"
        ACTIVE_TASK_ID=""
        CONFIRMED_ACTIVE_TASK_ID=""
        ACTIVE_TASK_LOOKUP_MISSES=0
        LOCAL_CANCEL_REQUESTED=1
        clear_task_runtime_state
        reset_attach_runtime_cache
        warn "$(lang_text "当前任务已取消" "Current task cancelled")"
        return 0
    fi

    warn "$(lang_text "取消任务失败" "Failed to cancel current task") (HTTP ${status_code:-000})"
    return 1
}

submit_feedback() {
    local related_task_id="${1:-${ACTIVE_TASK_ID:-}}"
    printf '\n  \033[36m%s\033[0m\n' "$UX_FEEDBACK_TITLE"
    printf '  \033[1m[b]\033[0m %s\n' "$UX_FEEDBACK_BUG_OPTION"
    printf '  \033[1m[s]\033[0m %s\n' "$UX_FEEDBACK_SUGGESTION_OPTION"
    printf '  \033[2m[Enter] %s\033[0m\n' "$UX_FEEDBACK_GO_BACK"
    printf '  > '
    local choice=""
    read_tty choice || true
    local fb_type=""
    case "$choice" in
        b|B) fb_type="bug_report" ;;
        s|S) fb_type="suggestion" ;;
        *) return ;;
    esac

    printf '  %s\n  > ' "$UX_FEEDBACK_DESCRIBE_PROMPT"
    local initial_desc="" desc=""
    read_tty_plain initial_desc || true
    desc="$(merge_tty_paste_continuation "$initial_desc")"

    local uptime=$SECONDS
    local escaped_desc
    escaped_desc="$(json_escape "${desc}")"
    local escaped_task_id=""
    if [ -n "$related_task_id" ]; then
        escaped_task_id="$(json_escape "${related_task_id}")"
    fi

    local body
    body="{\"type\":\"${fb_type}\""
    if [ -n "$desc" ]; then
        body="${body},\"description\":\"${escaped_desc}\""
    fi
    body="${body},\"environment\":${OS_PROFILE},\"context\":{\"session_uptime_seconds\":${uptime},\"script_version\":\"go.sh/1.0\""
    if [ -n "$escaped_task_id" ]; then
        body="${body},\"task_id\":\"${escaped_task_id}\""
    fi
    body="${body}}}"

    local resp
    device_request_with_status -X POST "${BASE_URL}/devices/${DEVICE_ID}/feedback" \
        -H "Content-Type: application/json" \
        -d "$body"
    resp="$HTTP_BODY"

    local fb_id
    fb_id="$(json_str feedback_id "$resp")"
    if [ -n "$fb_id" ]; then
        ok "$(lang_text "已提交" "Submitted"): ${fb_id}"
    else
        warn "$(lang_text "提交失败" "Submission failed"): $(json_str detail "$resp")"
    fi
}

prompt_post_task_feedback() {
    local completed_task_id="${1:-}"
    if ! tty_available; then
        return
    fi
    printf '\n  \033[2m%s\033[0m\n' "$UX_POST_TASK_FEEDBACK_PROMPT"
    printf '  > '
    local choice=""
    read_tty choice || true
    case "$choice" in
        f|F) submit_feedback_quick "bug_report" "$completed_task_id" ;;
        s|S) submit_feedback_quick "suggestion" "$completed_task_id" ;;
    esac
}

submit_feedback_quick() {
    local fb_type="$1"
    local related_task_id="${2:-${ACTIVE_TASK_ID:-}}"
    printf '  %s\n  > ' "$UX_FEEDBACK_DESCRIBE_PROMPT"
    local initial_desc="" desc=""
    read_tty_plain initial_desc || true
    desc="$(merge_tty_paste_continuation "$initial_desc")"

    local uptime=$SECONDS
    local escaped_desc
    escaped_desc="$(json_escape "${desc}")"
    local escaped_task_id=""
    if [ -n "$related_task_id" ]; then
        escaped_task_id="$(json_escape "${related_task_id}")"
    fi

    local body
    body="{\"type\":\"${fb_type}\""
    if [ -n "$desc" ]; then
        body="${body},\"description\":\"${escaped_desc}\""
    fi
    body="${body},\"environment\":${OS_PROFILE},\"context\":{\"session_uptime_seconds\":${uptime},\"script_version\":\"go.sh/1.0\""
    if [ -n "$escaped_task_id" ]; then
        body="${body},\"task_id\":\"${escaped_task_id}\""
    fi
    body="${body}}}"

    local resp
    device_request_with_status -X POST "${BASE_URL}/devices/${DEVICE_ID}/feedback" \
        -H "Content-Type: application/json" \
        -d "$body"
    resp="$HTTP_BODY"

    local fb_id
    fb_id="$(json_str feedback_id "$resp")"
    if [ -n "$fb_id" ]; then
        ok "$(lang_text "已提交" "Submitted"): ${fb_id}"
    else
        warn "$(lang_text "提交失败" "Submission failed"): $(json_str detail "$resp")"
    fi
}

show_active_task_resume_status() {
    local active_id="$1"
    local active_target="${2:-}"
    local active_status="${3:-}"

    ok "$(lang_text "继续任务" "Resuming task"): ${active_id}"
    [ -n "$active_target" ] && printf '  \033[2m  %s\033[0m\n' "$active_target"
    printf '  \033[2m%s\033[0m\n' "$UX_TASK_MENU_RESUME_HOTKEY_HINT"
    if [ "$active_status" = "paused_device_offline" ]; then
        warn "$(lang_text "平台之前因设备疑似离线暂停了此任务，正在重新附着。" "Platform had paused this task because the device looked offline. Re-attaching now...")"
    fi
}

prompt_attached_active_task_action() {
    local active_id="$1"
    local active_target="${2:-}"
    local active_status="${3:-}"
    PROMPT_ACTIVE_TASK_ACTION_RESULT="resume"

    if [ -z "$active_id" ]; then
        return 0
    fi

    printf '\n'
    printf '  \033[33m%s\033[0m\n' "$UX_ACTIVE_TASK_TITLE"
    printf '    %s: %s\n' "$UX_ACTIVE_TASK_TASK_ID_LABEL" "$active_id"
    [ -n "$active_status" ] && printf '    \033[2m%s: %s\033[0m\n' "$UX_ACTIVE_TASK_STATUS_LABEL" "$active_status"
    [ -n "$active_target" ] && printf '    \033[2m%s: %s\033[0m\n' "$UX_ACTIVE_TASK_TARGET_LABEL" "$active_target"
    printf '\n'
    printf '    1  %s\n' "$UX_ACTIVE_TASK_RESUME_LABEL"
    printf '    2  %s\n' "$UX_ACTIVE_TASK_CANCEL_LABEL"
    printf '    d  %s\n' "$UX_ACTIVE_TASK_DISCONNECT_LABEL"

    if ! tty_available; then
        warn "$UX_ACTIVE_TASK_NONINTERACTIVE_NOTICE"
        return 0
    fi

    while true; do
        printf '  %s\n' "$UX_ACTIVE_TASK_PROMPT"
        printf '  > '
        read_tty_with_hotkeys 1 0 || true
        if [ "$DETACH_REQUESTED" -eq 1 ]; then
            PROMPT_ACTIVE_TASK_ACTION_RESULT="__detach__"
            return 0
        fi
        case "$READ_TTY_ACTION" in
            disconnect)
                request_explicit_disconnect
                PROMPT_ACTIVE_TASK_ACTION_RESULT="disconnect"
                return 0
                ;;
            unavailable|eof)
                warn "$UX_ACTIVE_TASK_INPUT_UNAVAILABLE_NOTICE"
                return 0
                ;;
            submit)
                local choice
                choice="$(printf '%s' "$READ_TTY_VALUE" | tr '[:upper:]' '[:lower:]')"
                case "$choice" in
                    1|r|resume)
                        PROMPT_ACTIVE_TASK_ACTION_RESULT="resume"
                        return 0
                        ;;
                    2|c|cancel)
                        PROMPT_ACTIVE_TASK_ACTION_RESULT="cancel"
                        return 0
                        ;;
                    exit|quit)
                        PROMPT_ACTIVE_TASK_ACTION_RESULT="__detach__"
                        return 0
                        ;;
                    d|disconnect)
                        request_explicit_disconnect
                        PROMPT_ACTIVE_TASK_ACTION_RESULT="disconnect"
                        return 0
                        ;;
                esac
                warn "$UX_ACTIVE_TASK_INVALID_NOTICE"
                ;;
        esac
    done
}

ask_and_create_task() {
    ASK_AND_CREATE_TASK_RESULT=""
    # Check for existing active task
    local active_resp
    active_resp="$(fetch_active_task)"
    if printf '%s' "$active_resp" | grep -q '"has_active_task".*true'; then
        local active_id active_target active_status
        active_id="$(json_str task_id "$active_resp")"
        active_target="$(json_str target "$active_resp")"
        active_status="$(json_str status "$active_resp")"
        ACTIVE_TASK_ID="$active_id"
        ACTIVE_TASK_LOOKUP_MISSES=0
        prompt_attached_active_task_action "$active_id" "$active_target" "$active_status"
        case "$PROMPT_ACTIVE_TASK_ACTION_RESULT" in
            cancel)
                cancel_active_task || true
                return
                ;;
            disconnect|__detach__)
                return
                ;;
            *)
                CONFIRMED_ACTIVE_TASK_ID="$active_id"
                show_active_task_resume_status "$active_id" "$active_target" "$active_status"
                ;;
        esac
        return
    fi
    ACTIVE_TASK_ID=""
    CONFIRMED_ACTIVE_TASK_ID=""
    ACTIVE_TASK_LOOKUP_MISSES=0

    while true; do
        # No active task — show menu
        refresh_window_title
        local submit_hint="$UX_TASK_MENU_SUBMIT_HINT"
        if [ "$IS_BOUND" -eq 0 ]; then
            submit_hint="${submit_hint}   ${BIND_CONSOLE_HOTKEY_LABEL} $(lang_text "绑定控制台" "Bind console")"
        fi
        printf '\n'
        printf '  \033[1m%s\033[0m\n' "$UX_TASK_MENU_READY_TITLE"
        if [ -n "${UX_TASK_MENU_SUBTITLE:-}" ]; then
            printf '    \033[2m%s\033[0m\n' "$UX_TASK_MENU_SUBTITLE"
        fi
        printf '\n'
        if [ -n "${UX_TASK_MENU_FREEFORM_HINT:-}" ]; then
            printf '    \033[2m%s\033[0m\n' "${UX_TASK_MENU_FREEFORM_HINT:-}"
        fi
        for example in "${UX_TASK_MENU_EXAMPLE_1:-}" "${UX_TASK_MENU_EXAMPLE_2:-}" "${UX_TASK_MENU_EXAMPLE_3:-}"; do
            if [ -n "$example" ]; then
                printf '    \033[2m- %s\033[0m\n' "$example"
            fi
        done
        printf '\n'
        printf '    \033[2m%s\033[0m\n' "$submit_hint"
        printf '\n'
        printf '  \033[1;36m%s\033[0m\n' "$UX_TASK_MENU_PROMPT"
        local user_request="" guided_status=0 task_description="" task_mode="" task_user_request="" task_type_hint="" software_hint="" problem_hint="" target_hint="" error_message_hint=""
        printf '  \033[1;36m>\033[0m '
        read_tty_with_hotkeys 1 1 "attach_menu_poll_event" || true
        case "$READ_TTY_ACTION" in
            bind)
                initiate_binding
                continue
                ;;
            refresh)
                ASK_AND_CREATE_TASK_RESULT="refresh"
                return
                ;;
            disconnect)
                request_explicit_disconnect
                return
                ;;
            eof|unavailable)
                if [ "$DETACH_REQUESTED" -eq 1 ]; then
                    return
                fi
                request_explicit_disconnect
                return
                ;;
        esac
        user_request="$READ_TTY_VALUE"

        case "$user_request" in
            0)
                submit_feedback
                continue
                ;;
            1)
                if prompt_guided_task_request "install_software"; then
                    task_mode="install_software"
                    task_type_hint="software_install"
                    task_user_request="${GUIDED_TASK_PRIMARY_ANSWER:-$GUIDED_TASK_REQUEST}"
                    software_hint="$(infer_software_hint_from_text "$task_user_request")"
                    target_hint="$software_hint"
                    task_description="$UX_TASK_MENU_ACTION_1"
                    if [ -n "$task_user_request" ] && [ "$task_user_request" != "$task_description" ]; then
                        task_description="${UX_TASK_MENU_ACTION_1}: ${task_user_request}"
                    fi
                else
                    guided_status=$?
                    if [ $guided_status -eq 2 ]; then
                        [ "$DETACH_REQUESTED" -eq 1 ] && return
                        request_explicit_disconnect
                        return
                    fi
                    continue
                fi
                ;;
            2)
                if prompt_guided_task_request "repair_software"; then
                    task_mode="repair_software"
                    task_type_hint="software_repair"
                    task_user_request="${GUIDED_TASK_PRIMARY_ANSWER:-$GUIDED_TASK_REQUEST}"
                    software_hint="$(infer_software_hint_from_text "$task_user_request")"
                    target_hint="$software_hint"
                    problem_hint="$task_user_request"
                    error_message_hint="$task_user_request"
                    task_description="$UX_TASK_MENU_ACTION_2"
                    if [ -n "$task_user_request" ] && [ "$task_user_request" != "$task_description" ]; then
                        task_description="${UX_TASK_MENU_ACTION_2}: ${task_user_request}"
                    fi
                else
                    guided_status=$?
                    if [ $guided_status -eq 2 ]; then
                        [ "$DETACH_REQUESTED" -eq 1 ] && return
                        request_explicit_disconnect
                        return
                    fi
                    continue
                fi
                ;;
            "")
                continue
                ;;
            *)
                if printf '%s' "$user_request" | grep -Eq '^[0-9]+$'; then
                    warn "$(ux_manifest_text_lang "blocks.task_menu.context.invalid_selection_notice" "请直接输入你的需求，按 0 可反馈问题，或使用 Ctrl+B / Ctrl+D。")"
                    continue
                fi
                task_mode="freeform"
                task_user_request="$user_request"
                task_description="$user_request"
                task_type_hint="$(infer_task_type_hint_from_text "$task_user_request")"
                software_hint="$(infer_software_hint_from_text "$task_user_request")"
                target_hint="$software_hint"
                if [ "$task_type_hint" = "software_repair" ]; then
                    problem_hint="$task_user_request"
                    error_message_hint="$task_user_request"
                fi
                ;;
        esac

        if [ -n "$task_description" ]; then
            clear_task_runtime_state
            reset_attach_runtime_cache
            ok "$(lang_text "正在提交任务..." "Submitting task...")"
            local request_body
            request_body="$(build_task_request_json "$task_description" "$task_mode" "$task_user_request" "go_bash" "$task_type_hint" "$software_hint" "$problem_hint" "$target_hint" "$error_message_hint")"
            local task_resp
            device_request_with_status -X POST "${BASE_URL}/devices/${DEVICE_ID}/tasks" \
                -H "Content-Type: application/json" \
                -d "$request_body"
            task_resp="$HTTP_BODY"
            local task_id
            task_id="$(json_str task_id "$task_resp")"
            if [ -n "$task_id" ]; then
                ACTIVE_TASK_ID="$task_id"
                CONFIRMED_ACTIVE_TASK_ID="$task_id"
                ACTIVE_TASK_LOOKUP_MISSES=0
                ok "$(lang_text "任务已创建" "Task created"): ${task_id}"
            else
                if ! recover_active_task_after_submit_failure "$task_description"; then
                    local task_error_detail
                    task_error_detail="$(json_str detail "$task_resp")"
                    if [ "${HTTP_STATUS:-000}" = "402" ] || printf '%s' "$task_error_detail" | grep -qi 'device budget exhausted'; then
                        warn "$(lang_text "当前设备额度已用完，请在控制台补充额度，或换一台仍有额度的设备后重试。" "This device has no remaining task budget. Add budget in the console or use a device with remaining budget, then retry.")"
                    else
                        warn "$(lang_text "创建任务失败" "Task creation failed"): ${task_error_detail}"
                    fi
                fi
            fi
        fi
        return
    done
}

request_explicit_disconnect() {
    EXPLICIT_DISCONNECT_REQUESTED=1
    ensure_runtime_dir
    : > "$DISCONNECT_REQUEST_FILE"
    if [ "$RUN_AS_OWNER" -ne 1 ] && owner_is_running; then
        if wait_for_owner_shutdown; then
            CLEANUP_DONE=1
            ok "$(lang_text "已断开。重新运行即可重连。" "Disconnected. Run again to reconnect.")"
            clear_runtime_ephemeral_files
            rm -f "$OWNER_PID_FILE"
            return
        fi
    fi
    stop_owner_process
    sync_saved_state_from_disk || true
    disconnect_device
}

attach_show_status_if_changed() {
    local current_active_task_id="${1:-}"
    local status_payload=""
    local phase="" level="" message="" active_task_id="" status_key=""
    status_payload="$(runtime_read_file "$SESSION_STATUS_FILE" || true)"
    phase="$(json_str phase "$status_payload")"
    level="$(json_str level "$status_payload")"
    message="$(json_str message "$status_payload")"
    active_task_id="$(json_str active_task_id "$status_payload")"
    if [ -n "$active_task_id" ] && { [ -z "$current_active_task_id" ] || [ "$active_task_id" != "$current_active_task_id" ]; }; then
        return 1
    fi
    [ -n "$message" ] || return 1
    status_key="${phase}|${level}|${message}|${active_task_id}"
    [ "$status_key" = "$ATTACH_LAST_STATUS_KEY" ] && return 1
    ATTACH_LAST_STATUS_KEY="$status_key"
    render_agent_notification "${phase:-progress}" "${level:-info}" "$message"
    return 0
}

pending_interaction_active_task_id() {
    local payload="" active_task_id=""
    payload="$(runtime_read_file "$PENDING_INTERACTION_FILE" || true)"
    active_task_id="$(json_str active_task_id "$payload")"
    [ -n "$active_task_id" ] || return 1
    printf '%s\n' "$active_task_id"
    return 0
}

attach_menu_poll_event() {
    local completion_payload="" task_id="" interaction_payload="" interaction_id="" owner_active_task_id=""
    completion_payload="$(runtime_read_file "$TASK_COMPLETION_FILE" || true)"
    task_id="$(json_str task_id "$completion_payload")"
    if [ -n "$task_id" ]; then
        printf 'task_completion\n'
        return 0
    fi

    interaction_payload="$(runtime_read_file "$PENDING_INTERACTION_FILE" || true)"
    interaction_id="$(json_str interaction_id "$interaction_payload")"
    if [ -n "$interaction_id" ]; then
        printf 'pending_interaction\n'
        return 0
    fi

    owner_active_task_id="$(owner_heartbeat_active_task_id)"
    if [ -n "$owner_active_task_id" ]; then
        printf 'active_task\n'
        return 0
    fi

    return 1
}

attach_handle_pending_interaction() {
    local current_active_task_id="${1:-}"
    local payload="" interaction_id="" question="" interaction_type="" interaction_level="" interaction_phase="" display_question="" rendered_question="" pending_task_id="" now=""
    payload="$(runtime_read_file "$PENDING_INTERACTION_FILE" || true)"
    interaction_id="$(json_str interaction_id "$payload")"
    [ -n "$interaction_id" ] || return 1
    [ "$interaction_id" = "$ATTACH_LAST_INTERACTION_ID" ] && return 1
    pending_task_id="$(json_str active_task_id "$payload")"
    if [ -n "$pending_task_id" ] && [ -n "$current_active_task_id" ] && [ "$pending_task_id" != "$current_active_task_id" ]; then
        clear_pending_interaction_file
        return 1
    fi
    now="$(date +%s)"
    if [ "$interaction_id" = "$ATTACH_DEFERRED_INTERACTION_ID" ] && [ "${ATTACH_INTERACTION_RETRY_AFTER_TS:-0}" -gt "$now" ] 2>/dev/null; then
        return 1
    fi
    question="$(json_str question "$payload")"
    interaction_type="$(json_str interaction_type "$payload")"
    interaction_level="$(json_str interaction_level "$payload")"
    interaction_phase="$(json_str interaction_phase "$payload")"
    display_question="$(json_str display_question "$payload")"
    rendered_question="$(format_interaction_question "$question" "$display_question")"

    printf '\n\033[2m─── %s ──────────────────────────────────\033[0m\n' "$UX_INTERACTION_TITLE"
    printf '  \033[33m%s\033[0m\n' "$rendered_question"
    local answer="" attempts=0 normalized=""
    if [ "$interaction_type" = "approval" ]; then
        printf '  \033[36m%s\033[0m\n' "$UX_APPROVAL_HINT"
        while [ "$attempts" -lt 5 ]; do
            printf '  \033[36m%s\033[0m\n  \033[36m>\033[0m ' "$UX_APPROVAL_PROMPT"
            read_tty_with_hotkeys 1 || true
            case "$READ_TTY_ACTION" in
                disconnect)
                    request_explicit_disconnect
                    return 0
                    ;;
                eof|unavailable)
                    ATTACH_DEFERRED_INTERACTION_ID="$interaction_id"
                    ATTACH_INTERACTION_RETRY_AFTER_TS=$((now + 30))
                    warn "$(lang_text "当前终端不可交互，审批会保持待处理，稍后会再次提示。" "Non-interactive terminal; the approval stays pending and will be shown again later.")"
                    print_execution_separator
                    return 0
                    ;;
            esac
            answer="$(merge_tty_paste_continuation "$READ_TTY_VALUE")"
            normalized="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
            case "$normalized" in
                y|yes|approve|approved|ok)
                    answer="approved"
                    break
                    ;;
                n|no|deny|denied|reject|rejected)
                    answer="denied"
                    break
                    ;;
                *)
                    attempts=$((attempts + 1))
                    warn "$UX_APPROVAL_REQUIRED_NOTICE"
                    ;;
            esac
        done
        if [ -z "$answer" ] || { [ "$answer" != "approved" ] && [ "$answer" != "denied" ]; }; then
            answer="denied"
            warn "$UX_APPROVAL_AUTO_DENIED_NOTICE"
        fi
    else
        printf '  \033[36m%s\033[0m\n  \033[36m>\033[0m ' "$UX_INTERACTION_PROMPT"
        read_tty_with_hotkeys 1 || true
        case "$READ_TTY_ACTION" in
            disconnect)
                request_explicit_disconnect
                return 0
                ;;
            eof|unavailable)
                ATTACH_DEFERRED_INTERACTION_ID="$interaction_id"
                ATTACH_INTERACTION_RETRY_AFTER_TS=$((now + 30))
                warn "$(lang_text "已跳过，稍后会再次提问。" "Skipped; will wait a bit before asking again.")"
                print_execution_separator
                return 0
                ;;
        esac
        answer="$(merge_tty_paste_continuation "$READ_TTY_VALUE")"
        if [ -z "$answer" ]; then
            ATTACH_DEFERRED_INTERACTION_ID="$interaction_id"
            ATTACH_INTERACTION_RETRY_AFTER_TS=$((now + 30))
            warn "$(lang_text "已跳过，稍后会再次提问。" "Skipped; will wait a bit before asking again.")"
            print_execution_separator
            return 0
        fi
    fi
    ATTACH_LAST_INTERACTION_ID="$interaction_id"
    ATTACH_DEFERRED_INTERACTION_ID=""
    ATTACH_INTERACTION_RETRY_AFTER_TS=0
    write_interaction_answer_file "$interaction_id" "$answer"
    write_session_status "$interaction_phase" "$interaction_level" "$UX_INTERACTION_QUEUED_NOTICE"
    ok "$(lang_text "已提交，后台会继续发送。" "Answer queued. The background session is continuing.")"
    print_execution_separator
    return 0
}

attach_handle_task_completion() {
    local payload="" task_id="" task_status="" referral_code="" share_text="" task_message=""
    payload="$(runtime_read_file "$TASK_COMPLETION_FILE" || true)"
    task_id="$(json_str task_id "$payload")"
    [ -n "$task_id" ] || return 1
    task_status="$(json_str task_status "$payload")"
    if [ -n "$LAST_LOCALLY_CANCELLED_TASK_ID" ] && [ "$task_id" = "$LAST_LOCALLY_CANCELLED_TASK_ID" ] && [ "$task_status" != "succeeded" ]; then
        LAST_LOCALLY_CANCELLED_TASK_ID=""
        rm -f "$TASK_COMPLETION_FILE" "$SESSION_STATUS_FILE"
        return 0
    fi
    [ "$task_id" = "$ATTACH_LAST_COMPLETION_ID" ] && return 1
    ATTACH_LAST_COMPLETION_ID="$task_id"
    budget_remaining="$(json_str budget_remaining "$payload")"
    referral_code="$(json_str referral_code "$payload")"
    share_text="$(json_str share_text "$payload")"
    task_message="$(json_str task_message "$payload")"
    local budget_tasks_remaining budget_tasks_total budget_usd_remaining budget_usd_total
    budget_tasks_remaining="$(json_str budget_tasks_remaining "$payload")"
    budget_tasks_total="$(json_str budget_tasks_total "$payload")"
    budget_usd_remaining="$(json_str budget_usd_remaining "$payload")"
    budget_usd_total="$(json_str budget_usd_total "$payload")"
    local attach_budget_warning attach_budget_binding_incentive
    attach_budget_warning="$(json_str budget_warning "$payload")"
    attach_budget_binding_incentive="$(json_str budget_binding_incentive "$payload")"
    show_task_completion_card "$task_status" "$budget_tasks_remaining" "$budget_tasks_total" "$budget_usd_remaining" "$budget_usd_total" "$referral_code" "$share_text" "$task_message" "$attach_budget_warning" "$attach_budget_binding_incentive"
    [ "$DETACH_REQUESTED" -eq 1 ] && return 0
    prompt_post_task_feedback "$task_id"
    rm -f "$TASK_COMPLETION_FILE" "$SESSION_STATUS_FILE"
    return 0
}

attach_main_loop() {
    local last_active_task_id=""
    render_attached_banner
    print_execution_separator
    while true; do
        if [ "$DETACH_REQUESTED" -eq 1 ]; then
            return
        fi
        local owner_health_detail=""
        if ! owner_health_detail="$(owner_session_health_detail)"; then
            warn "$(lang_text "后台会话看起来已经失活，正在重启本地 owner。" "Background session looks unhealthy; restarting local owner.")"
            append_owner_log_line "WARN" "launcher detected unhealthy owner while attached: ${owner_health_detail}"
            if ! start_owner_process; then
                append_owner_log_line "ERROR" "launcher failed to restart owner while attached: ${owner_health_detail}"
                warn "$(lang_text "无法重启后台会话，请检查本地日志后重新运行 /go。" "Failed to restart the background session. Please run /go again after checking the local logs.")"
                return 1
            fi
            append_owner_log_line "INFO" "launcher restarted background owner while attached: ${owner_health_detail}"
            ATTACH_LAST_STATUS_KEY=""
            ATTACH_LAST_INTERACTION_ID=""
            ATTACH_DEFERRED_INTERACTION_ID=""
            ATTACH_INTERACTION_RETRY_AFTER_TS=0
            ATTACH_LAST_COMPLETION_ID=""
            last_active_task_id=""
            ACTIVE_TASK_ID=""
            CONFIRMED_ACTIVE_TASK_ID=""
            sleep 1
            continue
        fi
        local hotkey_action=""
        if hotkey_action="$(poll_hotkey_action)"; then
            case "$hotkey_action" in
                cancel)
                    cancel_active_task || true
                    ;;
                bind)
                    initiate_binding
                    ;;
                disconnect)
                    request_explicit_disconnect
                    return
                    ;;
            esac
        fi
        if [ "$LOCAL_CANCEL_REQUESTED" -eq 1 ]; then
            LOCAL_CANCEL_REQUESTED=0
        fi
        attach_handle_task_completion || true
        if [ "$DETACH_REQUESTED" -eq 1 ]; then
            return
        fi
        local active_resp active_id active_target active_status heartbeat_active_task_id current_attach_task_id
        active_resp="$(fetch_active_task)"
        active_id="$(json_str task_id "$active_resp")"
        active_target="$(json_str target "$active_resp")"
        active_status="$(json_str status "$active_resp")"
        heartbeat_active_task_id=""
        current_attach_task_id="$active_id"
        if [ -z "$current_attach_task_id" ]; then
            heartbeat_active_task_id="$(owner_heartbeat_active_task_id)"
            current_attach_task_id="$heartbeat_active_task_id"
        fi
        if [ -z "$current_attach_task_id" ]; then
            current_attach_task_id="$(pending_interaction_active_task_id || true)"
        fi
        if [ -n "$current_attach_task_id" ]; then
            ACTIVE_TASK_ID="$current_attach_task_id"
            ACTIVE_TASK_LOOKUP_MISSES=0
        fi
        if [ -f "$PENDING_INTERACTION_FILE" ] && tty_available; then
            attach_handle_pending_interaction "$current_attach_task_id" || true
        fi
        if [ -n "$current_attach_task_id" ]; then
            attach_show_status_if_changed "$current_attach_task_id" || true
        fi
        if [ -n "$active_id" ]; then
            ACTIVE_TASK_ID="$active_id"
            ACTIVE_TASK_LOOKUP_MISSES=0
            if [ "$CONFIRMED_ACTIVE_TASK_ID" != "$active_id" ]; then
                prompt_attached_active_task_action "$active_id" "$active_target" "$active_status"
                case "$PROMPT_ACTIVE_TASK_ACTION_RESULT" in
                    cancel)
                        cancel_active_task || true
                        sleep 1
                        continue
                        ;;
                    disconnect|__detach__)
                        return
                        ;;
                    *)
                        CONFIRMED_ACTIVE_TASK_ID="$active_id"
                        show_active_task_resume_status "$active_id" "$active_target" "$active_status"
                        ;;
                esac
            fi
            if [ "$last_active_task_id" != "$active_id" ]; then
                ok "$(lang_text "已连接任务" "Attached task"): ${active_id}"
                [ -n "$active_target" ] && printf '  \033[2m  %s\033[0m\n' "$active_target"
                last_active_task_id="$active_id"
            fi
            sleep 1
            continue
        fi

        if [ -n "$current_attach_task_id" ]; then
            sleep 1
            continue
        fi

        if [ -n "$ACTIVE_TASK_ID" ] && [ "$ACTIVE_TASK_LOOKUP_MISSES" -lt "$ACTIVE_TASK_LOOKUP_GRACE_MISSES" ]; then
            ACTIVE_TASK_LOOKUP_MISSES=$((ACTIVE_TASK_LOOKUP_MISSES + 1))
            sleep 1
            continue
        fi

        last_active_task_id=""
        ACTIVE_TASK_ID=""
        CONFIRMED_ACTIVE_TASK_ID=""
        ACTIVE_TASK_LOOKUP_MISSES=0
        ask_and_create_task
        if [ "$EXPLICIT_DISCONNECT_REQUESTED" -eq 1 ]; then
            return
        fi
        if [ "$ASK_AND_CREATE_TASK_RESULT" = "refresh" ]; then
            continue
        fi
        sleep 1
    done
}

handle_interaction() {
    local interaction_id="$1"
    local question="$2"
    local interaction_type="${3:-info_request}"
    local interaction_level="${4:-info}"
    local interaction_phase="${5:-progress}"
    local display_question="${6:-}"
    local rendered_question=""

    rendered_question="$(format_interaction_question "$question" "$display_question")"

    if [ "$interaction_type" = "notification" ]; then
        render_agent_notification "$interaction_phase" "$interaction_level" "$question"
        if respond_interaction "$interaction_id" "displayed"; then
            return 0
        fi
        warn "$(lang_text "设备更新确认失败，稍后重试。" "Failed to acknowledge device update; will retry.")"
        return 10
    fi

    if [ "$RUN_AS_OWNER" -eq 1 ]; then
        local answer_payload="" answer_interaction_id="" answer_value=""
        # Check for a queued answer BEFORE (re)writing the pending file so
        # that the attach process's dedup key (interaction_id) is not
        # accidentally bumped, which would re-prompt the user.
        answer_payload="$(runtime_read_file "$INTERACTION_ANSWER_FILE" || true)"
        answer_interaction_id="$(json_str interaction_id "$answer_payload")"
        answer_value="$(json_str answer "$answer_payload")"
        if [ -n "$answer_interaction_id" ] && [ "$answer_interaction_id" = "$interaction_id" ] && [ -n "$answer_value" ]; then
            if respond_interaction "$interaction_id" "$answer_value"; then
                clear_pending_interaction_file
                write_session_status "result" "info" "$(lang_text "已发送你的回答。" "Sent your answer.")"
                return 0
            fi
            warn "$(lang_text "回答发送失败，将重试。" "Failed to send deferred answer; will retry.")"
            return 10
        fi
        write_pending_interaction_file "$interaction_id" "$question" "$interaction_type" "$interaction_level" "$interaction_phase" "$display_question"
        write_session_status "$interaction_phase" "$interaction_level" "$rendered_question"
        return 5
    fi

    printf '\n\033[2m─── Agent 智能体 ──────────────────────────────────\033[0m\n'
    printf '  \033[33m%s\033[0m\n' "$rendered_question"

    if ! tty_available; then
        if [ "$interaction_type" = "approval" ]; then
            warn "$(lang_text "当前终端不可交互，审批会保持待处理，稍后会再次提示。" "Non-interactive terminal; the approval stays pending and will be shown again later.")"
        else
            warn "$(lang_text "当前终端不可交互，稍后会再次提问。" "Non-interactive terminal; will retry this question later.")"
        fi
        print_execution_separator
        return 30
    fi

    local answer="" attempts=0 normalized=""
    if [ "$interaction_type" = "approval" ]; then
        printf '  \033[36m%s\033[0m\n' "$UX_APPROVAL_HINT"
        while [ "$attempts" -lt 5 ]; do
            printf '  \033[36m%s\033[0m\n  \033[36m>\033[0m ' "$UX_APPROVAL_PROMPT"
            read_tty_with_hotkeys 1 || true
            case "$READ_TTY_ACTION" in
                disconnect)
                    request_explicit_disconnect
                    return 30
                    ;;
                eof|unavailable)
                    warn "$(lang_text "当前终端不可交互，审批会保持待处理，稍后会再次提示。" "Non-interactive terminal; the approval stays pending and will be shown again later.")"
                    print_execution_separator
                    return 30
                    ;;
            esac
            answer="$(merge_tty_paste_continuation "$READ_TTY_VALUE")"
            normalized="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
            case "$normalized" in
                y|yes|approve|approved|ok)
                    answer="approved"
                    break
                    ;;
                n|no|deny|denied|reject|rejected)
                    answer="denied"
                    break
                    ;;
                *)
                    attempts=$((attempts + 1))
                    warn "$UX_APPROVAL_REQUIRED_NOTICE"
                    ;;
            esac
        done
        if [ -z "$answer" ] || { [ "$answer" != "approved" ] && [ "$answer" != "denied" ]; }; then
            answer="denied"
            warn "$UX_APPROVAL_AUTO_DENIED_NOTICE"
        fi
    else
        printf '  \033[36m>\033[0m '
        read_tty_with_hotkeys 1 || true
        case "$READ_TTY_ACTION" in
            disconnect)
                request_explicit_disconnect
                return 30
                ;;
            eof|unavailable)
                warn "$(lang_text "当前终端不可交互，稍后会再次提问。" "Non-interactive terminal; will retry this question later.")"
                print_execution_separator
                return 30
                ;;
        esac
        answer="$(merge_tty_paste_continuation "$READ_TTY_VALUE")"
        if [ -z "$answer" ]; then
            warn "$(lang_text "已跳过，稍后会再次提问。" "Skipped; will wait a bit before asking again.")"
            print_execution_separator
            return 20
        fi
    fi

    if respond_interaction "$interaction_id" "$answer"; then
        ok "$(lang_text "已发送。" "Sent.")"
        print_execution_separator
        return 0
    fi

    warn "$(lang_text "回答发送失败，将重试。" "Failed to send answer; will retry.")"
    print_execution_separator
    return 10
}

exec_main_loop() {
    local poll_url="${BASE_URL}/devices/${DEVICE_ID}/poll"
    local result_url="${BASE_URL}/devices/${DEVICE_ID}/result"
    local renew_url="${BASE_URL}/devices/${DEVICE_ID}/renew-token"
    local last_renew=$SECONDS
    local RENEW_INTERVAL=86400
    local cmd_count=0
    local answered_interactions=""
    local interaction_retry_at=""
    local notified_tasks="${LAST_NOTIFIED_TASK_ID:-}"

    printf '\n\033[2m─── Execution 执行 ────────────────────────────────\033[0m\n'
    printf '  \033[2mWaiting for commands 等待指令... (%s 取消当前任务, Ctrl+C 退出会话)\033[0m\n' "$TASK_CANCEL_HOTKEY_LABEL"

    while true; do
        if [ "$RUN_AS_OWNER" -eq 1 ] && [ -f "$DISCONNECT_REQUEST_FILE" ]; then
            cleanup_and_exit
        fi
        if [ "$RUN_AS_OWNER" -ne 1 ]; then
            local hotkey_action=""
            if hotkey_action="$(poll_hotkey_action)"; then
                case "$hotkey_action" in
                    cancel)
                        if cancel_active_task; then
                            continue
                        fi
                        ;;
                    disconnect)
                        request_explicit_disconnect
                        break
                        ;;
                esac
            fi
        fi

        if [ "$LOCAL_CANCEL_REQUESTED" -eq 1 ]; then
            LOCAL_CANCEL_REQUESTED=0
            ask_and_create_task
            continue
        fi

        if [ "$RUN_AS_OWNER" -eq 1 ]; then
            write_owner_heartbeat "polling" "$ACTIVE_TASK_ID"
        fi

        # Token renewal
        if [ $((SECONDS - last_renew)) -ge $RENEW_INTERVAL ]; then
            local new_token
            if [ "$RUN_AS_OWNER" -eq 1 ]; then
                write_owner_heartbeat "renewing" "$ACTIVE_TASK_ID"
            fi
            request_with_status -X POST "$renew_url" \
                -H "Authorization: Bearer ${DEVICE_TOKEN}"
            if [ "${HTTP_STATUS}" = "401" ] || [ "${HTTP_STATUS}" = "403" ] || [ "${HTTP_STATUS}" = "404" ]; then
                warn "Saved device credentials rejected during renewal (HTTP ${HTTP_STATUS}); clearing local state and stopping."
                clear_saved_state
                break
            fi
            new_token="$(json_str token "$HTTP_BODY")"
            if [ "${HTTP_CURL_EXIT}" -eq 0 ] && [ "${HTTP_STATUS}" = "200" ] && [ -n "$new_token" ]; then
                DEVICE_TOKEN="$new_token"
                persist_state_value "DEVICE_TOKEN" "$DEVICE_TOKEN"
            fi
            last_renew=$SECONDS
        fi

        # Poll
        local resp
        request_with_status --max-time 15 \
            -H "Authorization: Bearer ${DEVICE_TOKEN}" \
            "${poll_url}?wait=10"
        if [ "${HTTP_STATUS}" = "401" ] || [ "${HTTP_STATUS}" = "403" ] || [ "${HTTP_STATUS}" = "404" ]; then
            warn "Saved device credentials rejected during poll (HTTP ${HTTP_STATUS}); clearing local state and stopping."
            clear_saved_state
            break
        fi
        if [ "${HTTP_CURL_EXIT}" -ne 0 ] || [ "${HTTP_STATUS}" != "200" ]; then
            sleep "$POLL_INTERVAL"
            continue
        fi
        resp="$HTTP_BODY"

        # Update binding status from poll
        local bound_val
        bound_val="$(json_bool is_bound "$resp")"
        if [ "$bound_val" = "true" ]; then
            IS_BOUND=1
        else
            IS_BOUND=0
        fi

        if [ "$RUN_AS_OWNER" -eq 1 ] && [ -z "$ACTIVE_TASK_ID" ]; then
            sync_active_task_from_platform || true
        fi

        local command_id raw_command command_encoding command_timeout command_intent interaction_id question interaction_type interaction_level interaction_phase display_question
        command_id="$(json_str command_id "$resp")"
        raw_command="$(json_str command "$resp")"
        command_encoding="$(json_str command_encoding "$resp")"
        command_timeout="$(json_int command_timeout_seconds "$resp")"
        command_timeout="${command_timeout:-300}"
        command_intent="$(json_str command_intent "$resp")"
        interaction_id="$(json_str interaction_id "$resp")"
        question="$(json_str question "$resp")"
        interaction_type="$(json_str interaction_type "$resp")"
        interaction_level="$(json_str interaction_level "$resp")"
        interaction_phase="$(json_str interaction_phase "$resp")"
        display_question="$(json_str "interaction_context.display_question" "$resp")"

        # ── Agent conversation (TTY-exclusive) ─────────────
        if [ -n "$interaction_id" ] && [ -n "$question" ]; then
            case " ${answered_interactions} " in
                *" ${interaction_id} "*)
                    sleep 1
                    continue
                    ;;
            esac

            local retry_wait=""
            if retry_wait="$(interaction_retry_wait "$interaction_id")"; then
                if [ "$retry_wait" -gt 5 ]; then
                    retry_wait=5
                fi
                sleep "$retry_wait"
                continue
            fi

            if handle_interaction "$interaction_id" "$question" "$interaction_type" "$interaction_level" "$interaction_phase" "$display_question"; then
                clear_interaction_retry "$interaction_id"
                answered_interactions="${answered_interactions} ${interaction_id}"
            else
                local handle_status=$?
                local retry_delay=5
                case "$handle_status" in
                    20) retry_delay=10 ;;
                    10) retry_delay=5 ;;
                esac
                upsert_interaction_retry_at "$interaction_id" "$(( $(date +%s) + retry_delay ))"
                sleep 1
            fi
            continue
        fi

        # ── Command execution (compact) ───────────────────
        # Inner loop: chains inline commands returned by result submission
        local _submit_fatal=0
        while [ -n "$command_id" ] && [ -n "$raw_command" ]; do
            local cmd="$raw_command"
            local progress_url="${BASE_URL}/devices/${DEVICE_ID}/commands/${command_id}/progress"
            if [ "$command_encoding" = "base64" ]; then
                cmd="$(printf '%s' "$raw_command" | base64 -d 2>/dev/null || printf '%s' "$raw_command" | base64 -D 2>/dev/null)" || cmd="$raw_command"
            fi

            cmd_count=$((cmd_count + 1))
            local cmd_short
            cmd_short="$(echo "$cmd" | tr '\n' ' ' | head -c 60)"
            if [ -n "$command_intent" ]; then
                render_agent_notification "action" "info" "$command_intent"
            else
                render_agent_notification "action" "info" "$(lang_text "正在执行下一步。" "Working on the next step.")"
            fi
            if [ "$command_timeout" -gt 300 ] 2>/dev/null; then
                render_agent_notification "waiting" "info" "$UX_RUNTIME_KEEP_OPEN"
            fi
            if [ "$SHOW_RAW_COMMANDS" -eq 1 ]; then
                printf '  \033[2m[%d]\033[0m \033[34m%s\033[0m ' "$cmd_count" "$cmd_short"
            fi

            local tmp_stdout tmp_stderr exit_code cmd_start timed_out cmd_deadline next_progress_at next_local_notice_at remote_cancel_requested
            local cmd_task_id_safe cmd_command_id_safe cmd_artifact_dir cmd_work_dir
            cmd_task_id_safe="$(printf '%s' "${ACTIVE_TASK_ID:-task-unknown}" | tr -c 'A-Za-z0-9._-' '_')"
            cmd_command_id_safe="$(printf '%s' "$command_id" | tr -c 'A-Za-z0-9._-' '_')"
            cmd_artifact_dir="${COMMAND_EXECUTION_ROOT}/${cmd_task_id_safe}/${cmd_command_id_safe}"
            cmd_work_dir="${cmd_artifact_dir}/workdir"
            mkdir -p "$cmd_work_dir"
            chmod 700 "$cmd_work_dir" 2>/dev/null || true
            tmp_stdout="${cmd_artifact_dir}/stdout.log"
            tmp_stderr="${cmd_artifact_dir}/stderr.log"
            : > "$tmp_stdout"
            : > "$tmp_stderr"
            chmod 600 "$tmp_stdout" "$tmp_stderr" 2>/dev/null || true
            cmd_start=$SECONDS
            timed_out=0
            cmd_deadline=$((SECONDS + command_timeout))
            next_progress_at=$((SECONDS + 5))
            next_local_notice_at=$((SECONDS + 10))
            local next_heartbeat_at=$((SECONDS + 1))
            remote_cancel_requested=0
            if [ "$RUN_AS_OWNER" -eq 1 ]; then
                write_owner_heartbeat "command" "$ACTIVE_TASK_ID" "$command_id"
            fi
            set +e
            local cmd_wait_pid cmd_exec_pid
            # Do not wrap this in $(...). The background python waiter must stay
            # a child of the current shell or wait "$cmd_wait_pid" will fail 127.
            launch_command_detached "$cmd" "$tmp_stdout" "$tmp_stderr" "$cmd_work_dir" || true
            cmd_wait_pid="${LAUNCHED_COMMAND_WAIT_PID:-}"
            cmd_exec_pid="${LAUNCHED_COMMAND_EXEC_PID:-}"
            if [ -z "$cmd_wait_pid" ]; then
                cmd_wait_pid="$cmd_exec_pid"
            fi
            if [ -z "$cmd_exec_pid" ]; then
                cmd_exec_pid="$cmd_wait_pid"
            fi
            if [ -z "$cmd_wait_pid" ] || [ -z "$cmd_exec_pid" ]; then
                exit_code=127
                echo "No supported detached task runtime backend found (need python3, perl, or setsid)" >> "$tmp_stderr"
            fi
            # NOTE: do NOT call poll_hotkey_action here — the command may
            # read /dev/tty directly (e.g. sudo password prompt), and our
            # hotkey read would race for the same input, silently stealing
            # characters.  The user can still Ctrl+C to exit the session,
            # and the timeout mechanism handles hung commands.
            while [ -n "$cmd_wait_pid" ] && kill -0 "$cmd_wait_pid" 2>/dev/null; do
                if [ "$RUN_AS_OWNER" -eq 1 ] && [ "$SECONDS" -ge "$next_heartbeat_at" ]; then
                    write_owner_heartbeat "command" "$ACTIVE_TASK_ID" "$command_id"
                    next_heartbeat_at=$((SECONDS + 1))
                fi
                if [ "$SECONDS" -ge "$cmd_deadline" ]; then
                    terminate_process_tree "$cmd_exec_pid"
                    wait "$cmd_wait_pid" 2>/dev/null || true
                    exit_code=124
                    timed_out=1
                    echo "Command timed out after ${command_timeout}s" >> "$tmp_stderr"
                    break
                fi
                if [ "$SECONDS" -ge "$next_progress_at" ]; then
                    local progress_elapsed progress_message progress_payload_file progress_status
                    progress_elapsed=$((SECONDS - cmd_start))
                    progress_message="Command still running (${progress_elapsed}s)"
                    progress_payload_file="$(mktemp)"
                    progress_status=0
                    if build_progress_payload_file "$tmp_stdout" "$tmp_stderr" "$progress_message" "$progress_payload_file"; then
                        submit_command_progress_once "$progress_url" "$progress_payload_file"
                        progress_status=$?
                    fi
                    rm -f "$progress_payload_file"
                    next_progress_at=$((SECONDS + 5))
                    if [ "$SECONDS" -ge "$next_local_notice_at" ]; then
                        local wait_summary
                        wait_summary="${command_intent:-$cmd_short}"
                        render_agent_notification "waiting" "info" "$(lang_text "仍在执行：${wait_summary} (${progress_elapsed}s)。请保持窗口开启，不要中断。" "Still working: ${wait_summary} (${progress_elapsed}s). Keep this window open.")"
                        next_local_notice_at=$((SECONDS + 15))
                    fi
                    if [ "$progress_status" -eq 10 ]; then
                        render_agent_notification "waiting" "warning" "$UX_RUNTIME_REMOTE_CANCEL"
                        terminate_process_tree "$cmd_exec_pid"
                        wait "$cmd_wait_pid" 2>/dev/null || true
                        exit_code=130
                        remote_cancel_requested=1
                        echo "Command cancelled after remote request" >> "$tmp_stderr"
                        break
                    fi
                fi
                sleep 0.2
            done
            if [ "$LOCAL_CANCEL_REQUESTED" -eq 1 ]; then
                set -e
                rm -f "$tmp_stdout" "$tmp_stderr"
                break
            fi
            if [ -n "$cmd_wait_pid" ] && [ "$timed_out" -ne 1 ] && [ "$remote_cancel_requested" -ne 1 ]; then
                wait "$cmd_wait_pid"
                exit_code=$?
            fi
            set -e
            local elapsed=$((SECONDS - cmd_start))

            if [ "$SHOW_RAW_COMMANDS" -eq 1 ]; then
                if [ "$exit_code" -eq 0 ]; then
                    printf '\033[32m✓\033[0m'
                else
                    printf '\033[31m✗ exit %d\033[0m' "$exit_code"
                fi
                [ "$elapsed" -gt 0 ] && printf ' \033[2m(%ds)\033[0m' "$elapsed"
                printf '\n'
            else
                printf '  \033[2m[Step %d]\033[0m ' "$cmd_count"
                if [ "$exit_code" -eq 0 ]; then
                    printf '\033[32m%s\033[0m' "$(lang_text "已完成" "Completed")"
                else
                    printf '\033[31m%s (exit %d)\033[0m' "$(lang_text "失败" "Failed")" "$exit_code"
                fi
                [ "$elapsed" -gt 0 ] && printf ' \033[2m(%ds)\033[0m' "$elapsed"
                printf '\n'
            fi

            # Submit result
            local result_id="res_$(date +%s)_$$"
            local payload_file
            payload_file="$(mktemp)"
            build_result_payload_file "$tmp_stdout" "$tmp_stderr" "$command_id" "$exit_code" "$result_id" "$payload_file"
            if submit_command_result_with_retry "$result_url" "$payload_file" "$command_id"; then
                rm -f "$tmp_stdout" "$tmp_stderr" "$payload_file"
                # Check for inline next command in result response
                local _next_cmd_id _next_cmd _next_enc _next_timeout _next_intent
                _next_cmd_id="$(json_str next_command_id "$HTTP_BODY")"
                if [ -n "$_next_cmd_id" ]; then
                    _next_cmd="$(json_str next_command "$HTTP_BODY")"
                    _next_enc="$(json_str next_command_encoding "$HTTP_BODY")"
                    _next_timeout="$(json_int next_command_timeout_seconds "$HTTP_BODY")"
                    _next_intent="$(json_str next_command_intent "$HTTP_BODY")"
                    if [ -n "$_next_cmd" ]; then
                        # Chain inline command: loop back to execute directly
                        command_id="$_next_cmd_id"
                        raw_command="$_next_cmd"
                        command_encoding="$_next_enc"
                        command_timeout="${_next_timeout:-300}"
                        command_intent="$_next_intent"
                        continue
                    fi
                fi
                # No inline command; break inner loop, resume outer poll
                break
            else
                local submit_status=$?
                if [ "$submit_status" -eq 2 ]; then
                    warn "Saved device credentials rejected while submitting command result (HTTP ${HTTP_STATUS}); clearing local state and stopping."
                    clear_saved_state
                elif [ "$submit_status" -eq 3 ]; then
                    warn "Command result was rejected permanently (HTTP ${HTTP_STATUS}); stopping instead of retrying the same payload."
                fi
                rm -f "$tmp_stdout" "$tmp_stderr" "$payload_file"
                _submit_fatal=1
                break
            fi
        done
        if [ "$_submit_fatal" -eq 1 ]; then
            break
        fi
        if [ -n "$command_id" ]; then
            continue
        fi

        # ── Task completion notification ─────────────────────
        local notif_task_id notif_task_status notif_task_message notif_referral_code notif_share_text
        local notif_budget_tasks_remaining notif_budget_tasks_total notif_budget_usd_remaining notif_budget_usd_total
        notif_task_id="$(json_str notif_task_id "$resp")"
        notif_task_status="$(json_str notif_task_status "$resp")"

        if [ -n "$notif_task_id" ] && [ -n "$notif_task_status" ]; then
            if [ -n "$ACTIVE_TASK_ID" ] && [ "$ACTIVE_TASK_ID" != "$notif_task_id" ]; then
                sleep "$POLL_INTERVAL"
                continue
            fi
            # Only show notification once per task
            case " ${notified_tasks} " in
                *" ${notif_task_id} "*)
                    sleep "$POLL_INTERVAL"
                    continue
                    ;;
            esac
            notified_tasks="${notified_tasks} ${notif_task_id}"
            LAST_NOTIFIED_TASK_ID="$notif_task_id"
            persist_state_value "LAST_NOTIFIED_TASK_ID" "$LAST_NOTIFIED_TASK_ID"
            if [ "$ACTIVE_TASK_ID" = "$notif_task_id" ]; then
                ACTIVE_TASK_ID=""
                CONFIRMED_ACTIVE_TASK_ID=""
                ACTIVE_TASK_LOOKUP_MISSES=0
            fi

            notif_referral_code="$(json_str notif_referral_code "$resp")"
            notif_share_text="$(json_str notif_share_text "$resp")"
            notif_budget_tasks_remaining="$(json_int notif_budget_tasks_remaining "$resp")"
            notif_budget_tasks_total="$(json_int notif_budget_tasks_total "$resp")"
            notif_budget_usd_remaining="$(json_float notif_budget_usd_remaining "$resp")"
            notif_budget_usd_total="$(json_float notif_budget_usd_total "$resp")"
            notif_task_message="$(json_str notif_task_message "$resp")"
            local notif_budget_warning notif_budget_binding_incentive
            notif_budget_warning="$(json_str budget_warning "$resp")"
            notif_budget_binding_incentive="$(json_str budget_binding_incentive "$resp")"

            # Update local referral code if received
            if [ -n "$notif_referral_code" ]; then
                MY_REFERRAL_CODE="$notif_referral_code"
                persist_state_value "REFERRAL_CODE" "$MY_REFERRAL_CODE"
            fi

            if [ "$RUN_AS_OWNER" -eq 1 ]; then
                write_task_completion_file \
                    "$notif_task_id" \
                    "$notif_task_status" \
                    "$notif_budget_tasks_remaining" \
                    "$notif_budget_tasks_total" \
                    "$notif_budget_usd_remaining" \
                    "$notif_budget_usd_total" \
                    "$notif_referral_code" \
                    "$notif_share_text" \
                    "$notif_task_message" \
                    "$notif_budget_warning" \
                    "$notif_budget_binding_incentive"
                if [ "$notif_task_status" = "succeeded" ]; then
                    write_session_status "result" "info" "$(lang_text "任务已报告完成，请验证实际结果。" "Task reported complete. Please verify the result.")"
                else
                    write_session_status "result" "warning" "$(lang_text "任务已结束，请查看结果。" "Task finished. Check the result.")"
                fi
            else
                show_task_completion_card \
                    "$notif_task_status" \
                    "$notif_budget_tasks_remaining" \
                    "$notif_budget_tasks_total" \
                    "$notif_budget_usd_remaining" \
                    "$notif_budget_usd_total" \
                    "$notif_referral_code" \
                    "$notif_share_text" \
                    "$notif_task_message" \
                    "$notif_budget_warning" \
                    "$notif_budget_binding_incentive"
                prompt_post_task_feedback "$notif_task_id"
                printf '\n'
                print_execution_separator

                # After task completes, offer to create a new task
                ask_and_create_task
            fi
        fi
    done
}

# ── Step 1: Detect system 检测系统 ───────────────────────────────
step "1/3" "Detecting system 检测系统环境..."

OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
    Linux)
        OS_VERSION="$(awk -F= '$1 == "PRETTY_NAME" { gsub(/^"/, "", $2); gsub(/"$/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || echo "Linux")"
        [ -n "$OS_VERSION" ] || OS_VERSION="Linux"
        ;;
    Darwin) OS_VERSION="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')" ;;
    *)      OS_VERSION="$OS_TYPE" ;;
esac
ARCH="$(uname -m)"
HOSTNAME_VAL="$(hostname 2>/dev/null || echo 'unknown')"
SHELL_TYPE="bash"

# Hardware identity (survives OS reinstall 重装系统不变)
HW_RAW=""
LEGACY_HW_RAW=""
case "$OS_TYPE" in
    Darwin)
        HW_RAW="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p' || echo '')"
        ;;
    Linux)
        HW_RAW="$(linux_read_stable_hardware_signal || echo '')"
        LEGACY_HW_RAW="$(linux_read_legacy_hardware_signal || echo '')"
        ;;
esac

HARDWARE_ID=""
LEGACY_HARDWARE_ID=""
HARDWARE_ID_CANDIDATES="[]"
HARDWARE_ID="$(hash_hardware_signal "$HW_RAW" || echo '')"
LEGACY_HARDWARE_ID="$(hash_hardware_signal "$LEGACY_HW_RAW" || echo '')"
hardware_id_candidates_json=""
if [ -n "$HARDWARE_ID" ]; then
    hardware_id_candidates_json="\"$(json_escape "$HARDWARE_ID")\""
fi
if [ -n "$LEGACY_HARDWARE_ID" ] && [ "$LEGACY_HARDWARE_ID" != "$HARDWARE_ID" ]; then
    if [ -n "$hardware_id_candidates_json" ]; then
        hardware_id_candidates_json="${hardware_id_candidates_json},"
    fi
    hardware_id_candidates_json="${hardware_id_candidates_json}\"$(json_escape "$LEGACY_HARDWARE_ID")\""
fi
if [ -n "$hardware_id_candidates_json" ]; then
    HARDWARE_ID_CANDIDATES="[${hardware_id_candidates_json}]"
fi

FINGERPRINT="${OS_TYPE}|${ARCH}|${HOSTNAME_VAL}"

PKG_MANAGERS="[]"
pm_list=""
command -v apt-get >/dev/null 2>&1 && pm_list="${pm_list}\"apt\","
command -v brew >/dev/null 2>&1    && pm_list="${pm_list}\"brew\","
command -v dnf >/dev/null 2>&1     && pm_list="${pm_list}\"dnf\","
command -v yum >/dev/null 2>&1     && pm_list="${pm_list}\"yum\","
command -v snap >/dev/null 2>&1    && pm_list="${pm_list}\"snap\","
command -v pip3 >/dev/null 2>&1    && pm_list="${pm_list}\"pip\","
if [ -n "$pm_list" ]; then
    PKG_MANAGERS="[${pm_list%,}]"
fi

# Collect shell environment summary for agent context
_SH_PROXY_HTTP_CONFIGURED=false
_SH_PROXY_HTTPS_CONFIGURED=false
_SH_PROXY_NO_CONFIGURED=false
[ -n "${http_proxy:-${HTTP_PROXY:-}}" ] && _SH_PROXY_HTTP_CONFIGURED=true
[ -n "${https_proxy:-${HTTPS_PROXY:-}}" ] && _SH_PROXY_HTTPS_CONFIGURED=true
[ -n "${no_proxy:-${NO_PROXY:-}}" ] && _SH_PROXY_NO_CONFIGURED=true
_SH_NODE_VER="$(node --version 2>/dev/null || true)"
if has_usable_python3; then
    _SH_PY_VER="$("$PYTHON3_BIN" --version 2>/dev/null | awk '{print $2}' || true)"
else
    _SH_PY_VER=""
fi
_SH_LOCALE="${LANG:-}"

ESCAPED_OS_TYPE="$(json_escape "${OS_TYPE}")"
ESCAPED_OS_VERSION="$(json_escape "${OS_VERSION}")"
ESCAPED_ARCH="$(json_escape "${ARCH}")"
ESCAPED_HOSTNAME="$(json_escape "${HOSTNAME_VAL}")"
ESCAPED_HARDWARE_ID="$(json_escape "${HARDWARE_ID}")"
ESCAPED_NODE_VER="$(json_escape "${_SH_NODE_VER}")"
ESCAPED_PY_VER="$(json_escape "${_SH_PY_VER}")"
ESCAPED_LOCALE="$(json_escape "${_SH_LOCALE}")"
ESCAPED_FINGERPRINT="$(json_escape "${FINGERPRINT}")"

OS_PROFILE=$(cat <<EOJSON
{
  "os_type": "${ESCAPED_OS_TYPE}",
  "os_version": "${ESCAPED_OS_VERSION}",
  "arch": "${ESCAPED_ARCH}",
  "hostname": "${ESCAPED_HOSTNAME}",
  "hardware_id": "${ESCAPED_HARDWARE_ID}",
  "package_managers": ${PKG_MANAGERS},
  "shell": "${SHELL_TYPE}",
  "shell_env": {
    "proxy": {
      "http_configured": ${_SH_PROXY_HTTP_CONFIGURED},
      "https_configured": ${_SH_PROXY_HTTPS_CONFIGURED},
      "no_proxy_configured": ${_SH_PROXY_NO_CONFIGURED}
    },
    "runtimes": {"node": "${ESCAPED_NODE_VER}", "python": "${ESCAPED_PY_VER}"},
    "locale": "${ESCAPED_LOCALE}"
  }
}
EOJSON
)

ok "${OS_VERSION} (${ARCH}) · ${HOSTNAME_VAL}"
pkg_display="$(echo "$PKG_MANAGERS" | tr -d '[]"' | tr ',' ', ')"
[ -n "$pkg_display" ] && ok "Package managers: ${pkg_display}"
[ -n "$HARDWARE_ID" ] && ok "Hardware ID: ${HARDWARE_ID:0:16}..."
if [ "$RUN_AS_OWNER" -ne 1 ]; then
    require_command_runtime_support
fi

# ── Check existing state 检查已有状态 ────────────────────────────
if [ -f "$STATE_FILE" ]; then
    EXISTING_DEVICE_ID="$(sed -n 's/^DEVICE_ID=//p' "$STATE_FILE" 2>/dev/null || echo '')"
    EXISTING_TOKEN="$(sed -n 's/^DEVICE_TOKEN=//p' "$STATE_FILE" 2>/dev/null || echo '')"
    EXISTING_RECOVERY_CODE="$(sed -n 's/^RECOVERY_CODE=//p' "$STATE_FILE" 2>/dev/null || echo '')"
    MY_REFERRAL_CODE="$(sed -n 's/^REFERRAL_CODE=//p' "$STATE_FILE" 2>/dev/null || echo '')"
    LAST_NOTIFIED_TASK_ID="$(sed -n 's/^LAST_NOTIFIED_TASK_ID=//p' "$STATE_FILE" 2>/dev/null || echo '')"
    DISPLAY_LANGUAGE="$(sed -n 's/^DISPLAY_LANGUAGE=//p' "$STATE_FILE" 2>/dev/null || echo '')"
    if [ -n "$EXISTING_DEVICE_ID" ] && [ -n "$EXISTING_TOKEN" ]; then
        request_with_status --max-time 10 \
            -H "Authorization: Bearer ${EXISTING_TOKEN}" \
            "${BASE_URL}/devices/${EXISTING_DEVICE_ID}/session"
        HTTP_CODE="${HTTP_STATUS:-000}"
        if [ "$HTTP_CODE" = "200" ]; then
            ok "$(lang_text "已重连" "Reconnected"): ${EXISTING_DEVICE_ID}"
            DEVICE_ID="$EXISTING_DEVICE_ID"
            DEVICE_TOKEN="$EXISTING_TOKEN"
            bound_val="$(json_bool is_bound "$HTTP_BODY")"
            if [ "$bound_val" = "true" ]; then
                IS_BOUND=1
            else
                IS_BOUND=0
            fi
            if [ -n "$DISPLAY_LANGUAGE" ]; then
                reload_ux_strings
            else
                prompt_language_selection
            fi
            ensure_runtime_dir
            if [ "$RUN_AS_OWNER" -eq 1 ]; then
                if [ "$OWNER_BOOTSTRAP_MODE" = "fresh" ]; then
                    write_session_status "waiting" "info" "$UX_BACKGROUND_SESSION_STARTED"
                else
                    write_session_status "waiting" "info" "$UX_BACKGROUND_SESSION_RESTORED"
                fi
                write_owner_heartbeat "waiting" "$ACTIVE_TASK_ID"
                exec_main_loop
                exit 0
            fi
            owner_health_detail=""
            if ! owner_health_detail="$(owner_session_health_detail)"; then
                warn "$(lang_text "凭据有效，但本地后台会话看起来已经失活，正在重启。" "Saved credentials are valid, but the background session looks stale; restarting local owner.")"
                append_owner_log_line "WARN" "launcher detected unhealthy owner during reconnect: ${owner_health_detail}"
            fi
            if ! start_owner_process restore; then
                append_owner_log_line "ERROR" "launcher could not restart background owner during reconnect: ${owner_health_detail:-unknown reason}"
                fail "$(lang_text "凭据有效，但无法重启本地后台设备会话。" "Saved credentials are valid, but the background device session could not be restarted.")"
            fi
            if [ -n "$owner_health_detail" ]; then
                append_owner_log_line "INFO" "launcher restarted background owner during reconnect: ${owner_health_detail}"
            fi
            prompt_aima_shortcut
            ATTACH_MODE_STARTED=1
            attach_main_loop
            exit 0
        fi
        warn "$(lang_text "凭据过期，正在重新注册..." "Credentials expired; re-registering...")"
        [ -z "$EXISTING_RECOVERY_CODE" ] && warn "$(lang_text "未找到恢复码；重新注册可能失败，需要手动重新接入。" "No recovery code found; re-registration may fail and require manual re-onboarding.")"
    fi
fi

# ── Step 2: Register 注册设备 ────────────────────────────────────
if load_recovery_code_from_saved_state; then
    warn "$(lang_text "已从本机其他 AIMA saved state 找回恢复码，将继续尝试恢复设备。" "Recovered a saved recovery code from another local AIMA state file and will continue device recovery.")"
fi

self_register() {
    step "2/3" "Registering device 注册设备..."

    local response detail reauth_method recovery_code_status hw_field hw_candidates_field recovery_field referral_field invite_field worker_code_field utm_source_field utm_medium_field utm_campaign_field
    while true; do
        hw_field=""
        hw_candidates_field=""
        recovery_field=""
        referral_field=""
        invite_field=""
        worker_code_field=""
        utm_source_field=""
        utm_medium_field=""
        utm_campaign_field=""
        [ -n "$HARDWARE_ID" ] && hw_field="\"hardware_id\":\"$(json_escape "${HARDWARE_ID}")\","
        [ "$HARDWARE_ID_CANDIDATES" != "[]" ] && hw_candidates_field="\"hardware_id_candidates\":${HARDWARE_ID_CANDIDATES},"
        [ -n "${EXISTING_RECOVERY_CODE:-}" ] && recovery_field="\"recovery_code\":\"$(json_escape "${EXISTING_RECOVERY_CODE}")\","
        [ -n "$REFERRAL_CODE" ] && referral_field="\"referral_code\":\"$(json_escape "${REFERRAL_CODE}")\","
        [ -n "$INVITE_CODE" ] && invite_field="\"invite_code\":\"$(json_escape "${INVITE_CODE}")\","
        [ -n "$WORKER_ENROLLMENT_CODE" ] && worker_code_field="\"worker_enrollment_code\":\"$(json_escape "${WORKER_ENROLLMENT_CODE}")\","
        [ -n "$UTM_SOURCE" ] && utm_source_field="\"utm_source\":\"$(json_escape "${UTM_SOURCE}")\","
        [ -n "$UTM_MEDIUM" ] && utm_medium_field="\"utm_medium\":\"$(json_escape "${UTM_MEDIUM}")\","
        [ -n "$UTM_CAMPAIGN" ] && utm_campaign_field="\"utm_campaign\":\"$(json_escape "${UTM_CAMPAIGN}")\","

        request_with_status -X POST "${BASE_URL}/devices/self-register" \
            -H "Content-Type: application/json" \
            -d "{${hw_field}${hw_candidates_field}${recovery_field}${referral_field}${invite_field}${worker_code_field}${utm_source_field}${utm_medium_field}${utm_campaign_field}\"fingerprint\":\"${ESCAPED_FINGERPRINT}\",\"os_profile\":${OS_PROFILE}}"
        [ "${HTTP_CURL_EXIT}" -ne 0 ] && fail "Failed to contact platform 无法连接平台"

        response="$HTTP_BODY"
        DEVICE_ID="$(json_str device_id "$response")"
        DEVICE_TOKEN="$(json_str token "$response")"
        RECOVERY_CODE="$(json_str recovery_code "$response")"
        MY_REFERRAL_CODE="$(json_str referral_code "$response")"
        sync_budget_snapshot_from_payload "$response"

        if [ -n "$DEVICE_ID" ] && [ -n "$DEVICE_TOKEN" ] && [ -n "$RECOVERY_CODE" ]; then
            return 0
        fi
        detail="$(json_str detail "$response")"
        reauth_method="$(json_str reauth_method "$response")"
        recovery_code_status="$(json_str recovery_code_status "$response")"
        error_code="$(json_str error_code "$response")"
        if [ "$reauth_method" = "browser_confirmation" ]; then
            complete_browser_recovery_flow "$response" || return 1
            return 0
        fi
        if [ "$reauth_method" = "recovery_code" ]; then
            if [ "$recovery_code_status" = "missing" ] && [ -z "${EXISTING_RECOVERY_CODE:-}" ]; then
                prompt_for_recovery_code "$UX_RECOVERY_MISSING_LOCAL_STATE"
            else
                prompt_for_recovery_code "${detail:-$UX_RECOVERY_MISSING_LOCAL_STATE}"
            fi
            continue
        fi
        # Structured invite error_code — clear stale invite and re-prompt
        case "$error_code" in
            invite_quota_exhausted|invite_expired|invite_disabled)
                INVITE_CODE=""
                prompt_for_invite_code "$(lang_text '当前邀请码不可用' 'Current invite code is unavailable'): ${detail}"
                continue
                ;;
            invite_invalid)
                INVITE_CODE=""
                prompt_for_invite_code "$(lang_text '邀请码无效' 'Invalid invite code')"
                continue
                ;;
            invite_required|referral_error)
                prompt_for_invite_code "${UX_PLATFORM_NEEDS_INVITE}: ${detail}"
                continue
                ;;
        esac
        # Legacy fallback: grep detail string for older servers without error_code
        if [ -n "$REFERRAL_CODE" ] && [ -n "$detail" ] \
            && printf '%s' "$detail" | grep -Eqi 'referral|invite_code'; then
            INVITE_CODE=""
            prompt_for_invite_code "${UX_REFERRAL_NEEDS_CODE}: ${detail}"
            continue
        fi
        if [ -n "$detail" ] && printf '%s' "$detail" | grep -Eqi 'invite_code|worker_enrollment_code|invite code.*exhaust|invite code.*expired|invite code.*disabled'; then
            INVITE_CODE=""
            prompt_for_invite_code "${UX_PLATFORM_NEEDS_INVITE}: ${detail}"
            continue
        fi
        if [ -n "$detail" ] && printf '%s' "$detail" | grep -qi 'recovery_code'; then
            if [ -n "${EXISTING_RECOVERY_CODE:-}" ]; then
                prompt_for_recovery_code "${detail}"
            else
                prompt_for_recovery_code "$UX_RECOVERY_MISSING_LOCAL_STATE"
            fi
            continue
        fi

        fail "$(lang_text "注册失败" "Registration failed"): ${detail:-$response}"
    done
}

if [ -n "$CONNECT_TOKEN" ]; then
    step "2/3" "Registering with code 使用激活码注册..."
    response="$(curl -sS -X POST "${BASE_URL}/devices/register" \
        -H "Content-Type: application/json" \
        -d "{\"activation_code\":\"${CONNECT_TOKEN}\",\"fingerprint\":\"${FINGERPRINT}\",\"os_profile\":${OS_PROFILE}}" \
        2>/dev/null)" || fail "$(lang_text "失败" "Failed")"
    DEVICE_ID="$(json_str device_id "$response")"
    DEVICE_TOKEN="$(json_str token "$response")"
    [ -z "$DEVICE_ID" ] || [ -z "$DEVICE_TOKEN" ] && fail "$(lang_text "注册失败" "Registration failed"): $response"
else
    self_register
fi

# ── Language selection 语言选择 ───────────────────────────────────
prompt_language_selection

# ── Save state 保存状态 ──────────────────────────────────────────
cat > "$STATE_FILE" <<EOF
DEVICE_ID=${DEVICE_ID}
DEVICE_TOKEN=${DEVICE_TOKEN}
RECOVERY_CODE=${RECOVERY_CODE:-${EXISTING_RECOVERY_CODE:-}}
REFERRAL_CODE=${MY_REFERRAL_CODE:-}
LAST_NOTIFIED_TASK_ID=${LAST_NOTIFIED_TASK_ID:-}
PLATFORM_URL=${BASE_URL}
DISPLAY_LANGUAGE=${DISPLAY_LANGUAGE}
EOF
chmod 600 "$STATE_FILE"

step "3/3" "$(lang_text "设备已连接!" "Device linked!")"
refresh_account_snapshot || true
persist_state_value "REFERRAL_CODE" "${MY_REFERRAL_CODE:-}"
render_connected_summary
render_security_summary
prompt_aima_shortcut

# ── Start ────────────────────────────────────────────────────────
ensure_runtime_dir
if [ "$RUN_AS_OWNER" -eq 1 ]; then
    write_session_status "waiting" "info" "$UX_BACKGROUND_SESSION_STARTED"
    write_owner_heartbeat "waiting" "$ACTIVE_TASK_ID"
    exec_main_loop
else
    if ! start_owner_process fresh; then
        disconnect_device
        fail "$(lang_text "无法启动后台设备会话。" "Failed to start background device session.")"
    fi
    ATTACH_MODE_STARTED=1
    attach_main_loop
fi
