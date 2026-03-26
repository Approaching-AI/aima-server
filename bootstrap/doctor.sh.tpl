#!/usr/bin/env bash
# AIMA Doctor Skill — Self-diagnosis and repair for OpenClaw devices
#
# Install:   curl -sL https://aimaservice.ai/doctor | bash
# Run (IM):  ~/.openclaw/skills/aima-doctor/run.sh --run [--symptom "..."]
# Run (TTY): ~/.openclaw/skills/aima-doctor/run.sh --run --terminal [--symptom "..."]
set -euo pipefail

DOCTOR_DIR="${HOME}/.openclaw/skills/aima-doctor"
API_BASE_URL=__BASE_URL__
DEFAULT_INVITE_CODE="openclaw-plugin"
REGISTRATION_RATE_LIMIT_SUMMARY="OpenClaw 插件入口当前已限流，请等待补充额度后再试 / The OpenClaw plugin entry is rate limited. Please wait for more quota."
STATE_FILE="${HOME}/.aima-device-state"
CLI_STATE_FILE="${HOME}/.aima-cli/device-state.json"
POLL_INTERVAL=5
DEVICE_ID=""
DEVICE_TOKEN=""
RECOVERY_CODE=""
LAST_REGISTRATION_FAILURE_SUMMARY=""
SYMPTOM=""
IO_MODE="jsonlines"   # jsonlines | terminal
RUN_MODE=""           # "" = install, "run" = execute

while [ $# -gt 0 ]; do
    case "$1" in
        --run)       RUN_MODE="run"; shift ;;
        --terminal)  IO_MODE="terminal"; shift ;;
        --symptom)   SYMPTOM="$2"; shift 2 ;;
        --platform-url) API_BASE_URL="$2"; shift 2 ;;
        *)           shift ;;
    esac
done

# ═══════════════════════════════════════════════════════════════════
# JSON helpers (subset of go.sh.tpl)
# ═══════════════════════════════════════════════════════════════════

json_extract_python() {
    local key="$1" kind="$2"
    JSON_KEY="$key" JSON_KIND="$kind" python3 -c '
import json, os, sys
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

json_str() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$2" | json_extract_python "$1" "str"
        return
    fi
    printf '%s' "$2" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

json_int() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$2" | json_extract_python "$1" "int"
        return
    fi
    printf '%s' "$2" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1
}

json_float() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$2" | json_extract_python "$1" "float"
        return
    fi
    printf '%s' "$2" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\(\.[0-9][0-9]*\)\?\).*/\1/p' | head -1
}

json_escape() {
    printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' | awk '
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

# ═══════════════════════════════════════════════════════════════════
# I/O layer — switches between JSON-lines (IM) and terminal modes
# ═══════════════════════════════════════════════════════════════════

emit_message() {
    local text="$1" level="${2:-info}"
    if [ "$IO_MODE" = "terminal" ]; then
        case "$level" in
            error) printf '  \033[31m✗\033[0m %s\n' "$text" ;;
            warn)  printf '  \033[33m⚠\033[0m %s\n' "$text" ;;
            *)     printf '  \033[32m●\033[0m %s\n' "$text" ;;
        esac
    else
        printf '{"type":"message","text":"%s","level":"%s"}\n' "$(json_escape "$text")" "$level"
    fi
}

emit_status() {
    local state="$1" detail="${2:-}"
    if [ "$IO_MODE" = "terminal" ]; then
        printf '\n\033[1m[%s]\033[0m %s\n' "$state" "$detail"
    else
        printf '{"type":"status","state":"%s","detail":"%s"}\n' "$state" "$(json_escape "$detail")"
    fi
}

emit_prompt() {
    local id="$1" text="$2"
    if [ "$IO_MODE" = "terminal" ]; then
        printf '\n  \033[36m%s\033[0m\n  > ' "$text"
    else
        printf '{"type":"prompt","id":"%s","text":"%s"}\n' "$id" "$(json_escape "$text")"
    fi
}

emit_command_output() {
    local intent="$1" text="$2"
    if [ "$IO_MODE" = "terminal" ]; then
        [ -n "$intent" ] && printf '  \033[2m── %s ──\033[0m\n' "$intent"
        printf '  %s\n' "$text"
    else
        local truncated="false"
        if [ "${#text}" -gt 4096 ]; then
            text="$(printf '%s' "$text" | head -c 4096)"
            truncated="true"
        fi
        printf '{"type":"command_output","intent":"%s","text":"%s","truncated":%s}\n' \
            "$(json_escape "$intent")" "$(json_escape "$text")" "$truncated"
    fi
}

emit_done() {
    local success="$1" summary="$2"
    local task_status="${3:-}" tasks_remaining="${4:-}" tasks_total="${5:-}"
    local usd_remaining="${6:-}" usd_total="${7:-}" referral_code="${8:-}" share_text="${9:-}"
    local bind_url="${10:-}" bind_user_code="${11:-}"
    if [ "$IO_MODE" = "terminal" ]; then
        if [ "$success" = "true" ]; then
            printf '\n  \033[1;32m✓ %s\033[0m\n' "$summary"
        else
            printf '\n  \033[1;31m✗ %s\033[0m\n' "$summary"
        fi
    else
        _json="{\"type\":\"done\",\"success\":${success},\"summary\":\"$(json_escape "$summary")\""
        [ -n "$task_status" ] && _json="${_json},\"task_status\":\"$(json_escape "$task_status")\""
        [ -n "$tasks_remaining" ] && _json="${_json},\"budget_tasks_remaining\":${tasks_remaining}"
        [ -n "$tasks_total" ] && _json="${_json},\"budget_tasks_total\":${tasks_total}"
        [ -n "$usd_remaining" ] && _json="${_json},\"budget_usd_remaining\":${usd_remaining}"
        [ -n "$usd_total" ] && _json="${_json},\"budget_usd_total\":${usd_total}"
        [ -n "$referral_code" ] && _json="${_json},\"referral_code\":\"$(json_escape "$referral_code")\""
        [ -n "$share_text" ] && _json="${_json},\"share_text\":\"$(json_escape "$share_text")\""
        [ -n "$bind_url" ] && _json="${_json},\"bind_url\":\"$(json_escape "$bind_url")\""
        [ -n "$bind_user_code" ] && _json="${_json},\"bind_user_code\":\"$(json_escape "$bind_user_code")\""
        _json="${_json}}"
        printf '%s\n' "$_json"
    fi
}

CONFLICT_ACTION=""
CONFLICT_RESTART_SYMPTOM=""

is_resume_answer() {
    local answer
    answer="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$answer" in
        resume|/aima\ resume|继续|继续跟进|继续跟进当前任务|继续当前任务)
            return 0
            ;;
    esac
    return 1
}

is_restart_answer() {
    local answer
    answer="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$answer" in
        restart|restart\ *|/aima\ restart|/aima\ restart\ *|重新开始|重新开始\ *|重新发起|重新发起\ *)
            return 0
            ;;
    esac
    return 1
}

extract_restart_symptom() {
    local answer
    answer="$(printf '%s' "${1:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$answer" in
        /aima\ restart\ *)
            printf '%s' "${answer#\/aima restart }"
            ;;
        restart\ *)
            printf '%s' "${answer#restart }"
            ;;
        重新开始\ *)
            printf '%s' "${answer#重新开始 }"
            ;;
        重新发起\ *)
            printf '%s' "${answer#重新发起 }"
            ;;
        *)
            printf ''
            ;;
    esac
}

resolve_existing_task_conflict() {
    local prompt_text
    prompt_text="检测到上一次未完成的救援。请回复 /aima resume 继续跟进，或回复 /aima restart <问题> 重新开始。 / An unfinished rescue already exists. Reply with /aima resume to continue, or /aima restart <symptom> to start over."
    CONFLICT_ACTION=""
    CONFLICT_RESTART_SYMPTOM=""
    while true; do
        emit_prompt "task_conflict" "$prompt_text"
        if ! read_answer "task_conflict"; then
            emit_done "false" "用户取消 / Cancelled by user"
            return 1
        fi
        if is_resume_answer "$ANSWER"; then
            CONFLICT_ACTION="resume"
            return 0
        fi
        if is_restart_answer "$ANSWER"; then
            CONFLICT_ACTION="restart"
            CONFLICT_RESTART_SYMPTOM="$(extract_restart_symptom "$ANSWER")"
            return 0
        fi
        emit_message "请回复 /aima resume 或 /aima restart <问题>。 / Reply with /aima resume or /aima restart <symptom>." "warn"
    done
}

cancel_task_by_id() {
    local task_id="${1:-}"
    [ -n "$task_id" ] || return 1
    device_api_request "POST" "/devices/${DEVICE_ID}/tasks/${task_id}/cancel"
    _api_status=$?
    if [ "$_api_status" -ne 0 ]; then
        exit_due_to_auth_failure "$_api_status"
    fi
    [ "$HTTP_CURL_EXIT" -eq 0 ] && [ "$HTTP_STATUS" = "200" ]
}

is_transport_interruption_question() {
    local question lowered
    question="${1:-}"
    lowered="$(printf '%s' "$question" | tr '[:upper:]' '[:lower:]')"
    case "$lowered" in
        *offline*|*disconnected*)
            case "$lowered" in
                *ready*|*reconnect*|*restore*network*|*bring*back*online*)
                    return 0
                    ;;
            esac
            ;;
    esac
    case "$question" in
        *离线*恢复联网*|*离线*重新连上*|*离线*回复*ready*|*断开*重新连接*|*断开*恢复联网*)
            return 0
            ;;
    esac
    return 1
}

emit_transport_interrupted() {
    emit_done "false" "本地救援通道已中断，请重新发送 /aima <问题> 继续接管。 / The local rescue channel was interrupted. Send /aima <symptom> to take over again." "interrupted"
}

# Read an answer from stdin. For terminal mode, reads a plain line.
# For JSON-lines mode, reads a JSON object and extracts "text".
# Returns non-zero on cancel or EOF.
ANSWER=""
read_answer() {
    local expected_id="${1:-}"
    ANSWER=""
    local line=""
    if ! IFS= read -r line; then
        return 1
    fi
    if [ "$IO_MODE" = "terminal" ]; then
        ANSWER="$line"
    else
        local msg_type
        msg_type="$(json_str "type" "$line")"
        if [ "$msg_type" = "cancel" ]; then
            return 2
        fi
        ANSWER="$(json_str "text" "$line")"
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════
# HTTP helper
# ═══════════════════════════════════════════════════════════════════

HTTP_STATUS=""
HTTP_BODY=""
HTTP_CURL_EXIT=0

http_request() {
    local tmp_body
    tmp_body="$(mktemp)"
    set +e
    HTTP_STATUS="$(curl -sS -o "$tmp_body" -w "%{http_code}" "$@" 2>/dev/null)"
    HTTP_CURL_EXIT=$?
    set -e
    HTTP_BODY="$(cat "$tmp_body")"
    rm -f "$tmp_body"
}

save_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
DEVICE_ID=${DEVICE_ID}
DEVICE_TOKEN=${DEVICE_TOKEN}
RECOVERY_CODE=${RECOVERY_CODE}
PLATFORM_URL=${API_BASE_URL}
EOF
    chmod 600 "$STATE_FILE"
}

load_recovery_code_from_saved_state() {
    if [ -n "$RECOVERY_CODE" ]; then
        return 0
    fi
    if [ -f "$CLI_STATE_FILE" ] && command -v python3 >/dev/null 2>&1; then
        _saved_cli_state="$(cat "$CLI_STATE_FILE")"
        _saved_cli_rc="$(json_str "recovery_code" "$_saved_cli_state")"
        _saved_cli_url="$(json_str "platform_url" "$_saved_cli_state")"
        [ -n "$_saved_cli_rc" ] && RECOVERY_CODE="$_saved_cli_rc"
        [ -n "$_saved_cli_url" ] && API_BASE_URL="$_saved_cli_url"
    fi
    if [ -z "$RECOVERY_CODE" ] && [ -f "$STATE_FILE" ]; then
        _saved_rc="$(sed -n 's/^RECOVERY_CODE=//p' "$STATE_FILE" | head -1)"
        _saved_url="$(sed -n 's/^PLATFORM_URL=//p' "$STATE_FILE" | head -1)"
        [ -n "$_saved_rc" ] && RECOVERY_CODE="$_saved_rc"
        [ -n "$_saved_url" ] && API_BASE_URL="$_saved_url"
    fi
}

prompt_for_invite_code() {
    emit_prompt "reg_invite" "请输入邀请码 / Please enter your invite code:"
    if read_answer "reg_invite"; then
        if [ -z "$ANSWER" ]; then
            emit_message "需要邀请码才能注册 / Invite code required" "error"
            return 1
        fi
        return 0
    fi
    return 2
}

prompt_for_recovery_code() {
    emit_prompt "reg_recovery" "请输入恢复码 / Please enter your recovery code:"
    if read_answer "reg_recovery"; then
        if [ -z "$ANSWER" ]; then
            emit_message "需要恢复码才能继续 / Recovery code required" "error"
            return 1
        fi
        RECOVERY_CODE="$ANSWER"
        return 0
    fi
    return 2
}

open_browser_url() {
    local url="${1:-}"
    [ -n "$url" ] || return 1
    if [ "$(uname -s)" = "Darwin" ]; then
        open "$url" >/dev/null 2>&1 || return 1
        return 0
    fi
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 || return 1
        return 0
    fi
    return 1
}

complete_browser_recovery_flow() {
    local recovery_resp="$1"
    local user_code device_code verification_uri verification_uri_with_code poll_interval flow_status poll_resp
    user_code="$(json_str "user_code" "$recovery_resp")"
    device_code="$(json_str "device_code" "$recovery_resp")"
    verification_uri="$(json_str "verification_uri" "$recovery_resp")"
    verification_uri_with_code="$(json_str "verification_uri_complete" "$recovery_resp")"
    poll_interval="$(json_int "interval" "$recovery_resp")"
    poll_interval="${poll_interval:-2}"

    if [ -z "$user_code" ] || [ -z "$device_code" ] || [ -z "$verification_uri" ]; then
        emit_message "Server returned invalid recovery confirmation info / 服务器返回了无效的恢复确认信息" "error"
        return 1
    fi
    if [ -z "$verification_uri_with_code" ]; then
        verification_uri_with_code="${verification_uri}?user_code=${user_code}"
    fi

    emit_message "Confirm Device Recovery in Browser / 在浏览器中确认恢复设备" "info"
    emit_message "Open in browser: ${verification_uri_with_code} / 在浏览器中打开: ${verification_uri_with_code}" "info"
    emit_message "Enter device code: ${user_code} / 输入设备码: ${user_code}" "info"
    emit_message "Please sign in with the original device manager account to confirm recovery. / 请使用原来的 device manager 账号确认恢复。" "info"
    open_browser_url "$verification_uri_with_code" || true
    emit_message "Browser opened. Waiting for recovery confirmation... / 浏览器已打开。正在等待恢复确认..." "info"

    while true; do
        http_request "${API_BASE_URL}/device-flows/${device_code}/poll"
        if [ "$HTTP_CURL_EXIT" -ne 0 ] || [ "$HTTP_STATUS" != "200" ]; then
            sleep "$poll_interval"
            continue
        fi

        poll_resp="$HTTP_BODY"
        flow_status="$(json_str "status" "$poll_resp")"
        case "$flow_status" in
            pending)
                sleep "$poll_interval"
                continue
                ;;
            bound)
                DEVICE_ID="$(json_str "device_id" "$poll_resp")"
                DEVICE_TOKEN="$(json_str "token" "$poll_resp")"
                RECOVERY_CODE="$(json_str "recovery_code" "$poll_resp")"
                if [ -z "$DEVICE_ID" ] || [ -z "$DEVICE_TOKEN" ] || [ -z "$RECOVERY_CODE" ]; then
                    emit_message "Recovery confirmation succeeded, but the platform returned incomplete credentials. / 恢复确认完成，但平台返回的凭据不完整。" "error"
                    return 1
                fi
                save_state
                emit_message "Browser confirmation complete. Device recovery succeeded. / 浏览器已确认，设备恢复成功。" "info"
                return 0
                ;;
            expired)
                emit_message "Recovery confirmation expired. Please rerun the device entry command. / 恢复确认已过期，请重新运行设备入口命令。" "error"
                return 1
                ;;
            denied)
                emit_message "Recovery confirmation was denied. Check the signed-in account or restart recovery. / 恢复确认被拒绝，请检查登录账号或重新发起恢复。" "error"
                return 1
                ;;
            *)
                emit_message "Recovery flow returned an unexpected status. / 恢复流程返回了未预期状态。" "error"
                return 1
                ;;
        esac
    done
}

register_or_refresh_device() {
    local invite_code="${1:-}"
    local require_invite_prompt="${2:-false}"
    local os_type os_version arch hostname_val fingerprint hw_raw hardware_id os_profile
    LAST_REGISTRATION_FAILURE_SUMMARY=""

    os_type="$(uname -s)"
    case "$os_type" in
        Linux)  os_version="$(awk -F= '$1 == "PRETTY_NAME" { gsub(/^"/, "", $2); gsub(/"$/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || echo "Linux")"
                [ -n "$os_version" ] || os_version="Linux" ;;
        Darwin) os_version="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')" ;;
        *)      os_version="$os_type" ;;
    esac
    arch="$(uname -m)"
    hostname_val="$(hostname 2>/dev/null || echo 'unknown')"
    fingerprint="${os_type}|${arch}|${hostname_val}"

    hw_raw=""
    case "$os_type" in
        Darwin) hw_raw="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p' || true)" ;;
        Linux)
            for _p in /sys/class/dmi/id/product_uuid /sys/class/dmi/id/product_serial /sys/class/dmi/id/board_serial; do
                [ -r "$_p" ] || continue
                hw_raw="$(tr -d '\n' < "$_p" 2>/dev/null || true)"
                case "${hw_raw:-}" in ""|"Not Specified"|"Default string") hw_raw="" ;; *) break ;; esac
            done
            if [ -z "$hw_raw" ]; then
                hw_raw="$(tr -d '\n' < /etc/machine-id 2>/dev/null || tr -d '\n' < /var/lib/dbus/machine-id 2>/dev/null || true)"
            fi
            ;;
    esac
    hardware_id=""
    if [ -n "$hw_raw" ]; then
        hardware_id="$(printf '%s' "$hw_raw" | shasum -a 256 2>/dev/null | cut -d' ' -f1 \
            || printf '%s' "$hw_raw" | sha256sum 2>/dev/null | cut -d' ' -f1 || true)"
    fi

    os_profile="$(cat <<EOJSON
{"os_type":"$(json_escape "$os_type")","os_version":"$(json_escape "$os_version")","arch":"$(json_escape "$arch")","hostname":"$(json_escape "$hostname_val")","hardware_id":"$(json_escape "$hardware_id")","shell":"bash"}
EOJSON
)"

    if [ "$require_invite_prompt" = "true" ] && [ -z "$invite_code" ]; then
        prompt_for_invite_code
        case $? in
            0) invite_code="$ANSWER" ;;
            2) return 2 ;;
            *) return 1 ;;
        esac
    fi

    while true; do
        _reg_hw=""
        _reg_hw_candidates=""
        [ -n "$hardware_id" ] && _reg_hw="\"hardware_id\":\"$(json_escape "$hardware_id")\","
        [ -n "$hardware_id" ] && _reg_hw_candidates="\"hardware_id_candidates\":[\"$(json_escape "$hardware_id")\"],"
        _reg_rc=""
        [ -n "$RECOVERY_CODE" ] && _reg_rc="\"recovery_code\":\"$(json_escape "$RECOVERY_CODE")\","
        _reg_invite=""
        [ -n "$invite_code" ] && _reg_invite="\"invite_code\":\"$(json_escape "$invite_code")\","

        http_request -X POST "${API_BASE_URL}/devices/self-register" \
            -H "Content-Type: application/json" \
            -d "{${_reg_hw}${_reg_hw_candidates}${_reg_rc}${_reg_invite}\"fingerprint\":\"$(json_escape "$fingerprint")\",\"os_profile\":${os_profile}}"

        if [ "$HTTP_CURL_EXIT" -ne 0 ] || [ -z "$HTTP_BODY" ]; then
            emit_message "无法连接平台 / Cannot reach platform" "error"
            return 1
        fi

        _new_device_id="$(json_str "device_id" "$HTTP_BODY")"
        _new_device_token="$(json_str "token" "$HTTP_BODY")"
        _new_recovery_code="$(json_str "recovery_code" "$HTTP_BODY")"

        if [ -n "$_new_device_id" ] && [ -n "$_new_device_token" ]; then
            DEVICE_ID="$_new_device_id"
            DEVICE_TOKEN="$_new_device_token"
            [ -n "$_new_recovery_code" ] && RECOVERY_CODE="$_new_recovery_code"
            save_state
            return 0
        fi

        _detail="$(json_str "detail" "$HTTP_BODY")"
        _reauth_method="$(json_str "reauth_method" "$HTTP_BODY")"
        _error_code="$(json_str "error_code" "$HTTP_BODY")"
        if [ "$HTTP_STATUS" = "409" ] && [ "$_reauth_method" = "browser_confirmation" ]; then
            complete_browser_recovery_flow "$HTTP_BODY"
            return $?
        fi
        if [ "$_reauth_method" = "recovery_code" ]; then
            prompt_for_recovery_code
            case $? in
                0) continue ;;
                2) return 2 ;;
                *) return 1 ;;
            esac
        fi
        # Structured invite error_code — clear stale invite and re-prompt
        case "$_error_code" in
            invite_quota_exhausted|invite_expired|invite_disabled|invite_invalid)
                invite_code=""
                emit_message "$REGISTRATION_RATE_LIMIT_SUMMARY" "warn"
                prompt_for_invite_code
                case $? in
                    0) invite_code="$ANSWER"; continue ;;
                    2) return 2 ;;
                    *) LAST_REGISTRATION_FAILURE_SUMMARY="$REGISTRATION_RATE_LIMIT_SUMMARY"; return 1 ;;
                esac
                ;;
            invite_required|referral_error)
                prompt_for_invite_code
                case $? in
                    0) invite_code="$ANSWER"; continue ;;
                    2) return 2 ;;
                    *) return 1 ;;
                esac
                ;;
        esac
        # Legacy fallback: 429 or string match for older servers without error_code
        if [ "$HTTP_STATUS" = "429" ] || printf '%s' "${_detail:-}" | grep -Eqi 'quota exhausted|invite code.*(expired|disabled)'; then
            invite_code=""
            emit_message "$REGISTRATION_RATE_LIMIT_SUMMARY" "warn"
            prompt_for_invite_code
            case $? in
                0) invite_code="$ANSWER"; continue ;;
                2) return 2 ;;
                *) LAST_REGISTRATION_FAILURE_SUMMARY="$REGISTRATION_RATE_LIMIT_SUMMARY"; return 1 ;;
            esac
        fi
        if printf '%s' "${_detail:-}" | grep -qi 'recovery_code'; then
            prompt_for_recovery_code
            case $? in
                0) continue ;;
                2) return 2 ;;
                *) return 1 ;;
            esac
        fi
        if printf '%s' "${_detail:-}" | grep -Eqi 'invite_code|worker_enrollment_code' && [ -z "$invite_code" ]; then
            prompt_for_invite_code
            case $? in
                0) invite_code="$ANSWER"; continue ;;
                2) return 2 ;;
                *) return 1 ;;
            esac
        fi

        emit_message "注册失败 / Registration failed: ${_detail:-$HTTP_BODY}" "error"
        return 1
    done
}

refresh_device_credentials() {
    load_recovery_code_from_saved_state
    emit_message "设备凭证已过期，正在刷新 / Device credentials expired, refreshing..." "warn"
    register_or_refresh_device ""
    _refresh_status=$?
    if [ "$_refresh_status" -ne 0 ]; then
        return "$_refresh_status"
    fi
    emit_message "设备凭证已刷新 / Device credentials refreshed" "info"
    return 0
}

device_api_request() {
    local method="$1" path="$2" body="${3:-}"

    if [ -n "$body" ]; then
        http_request -X "$method" "${API_BASE_URL}${path}" \
            -H "Authorization: Bearer ${DEVICE_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$body"
    else
        http_request -X "$method" "${API_BASE_URL}${path}" \
            -H "Authorization: Bearer ${DEVICE_TOKEN}"
    fi

    if [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "403" ] || [ "$HTTP_STATUS" = "404" ]; then
        refresh_device_credentials
        _refresh_status=$?
        if [ "$_refresh_status" -ne 0 ]; then
            return "$_refresh_status"
        fi
        if [ -n "$body" ]; then
            http_request -X "$method" "${API_BASE_URL}${path}" \
                -H "Authorization: Bearer ${DEVICE_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$body"
        else
            http_request -X "$method" "${API_BASE_URL}${path}" \
                -H "Authorization: Bearer ${DEVICE_TOKEN}"
        fi
    fi

    return 0
}

exit_due_to_auth_failure() {
    local code="${1:-1}"
    if [ "$code" -eq 2 ]; then
        emit_done "false" "取消刷新凭证 / Credential refresh cancelled"
    elif [ -n "$LAST_REGISTRATION_FAILURE_SUMMARY" ]; then
        emit_done "false" "$LAST_REGISTRATION_FAILURE_SUMMARY"
    else
        emit_done "false" "Auth failed"
    fi
    exit 1
}

ACCOUNT_TASKS_REMAINING=""
ACCOUNT_TASKS_TOTAL=""
ACCOUNT_USD_REMAINING=""
ACCOUNT_USD_TOTAL=""
ACCOUNT_REFERRAL_CODE=""
ACCOUNT_SHARE_TEXT=""
ACCOUNT_IS_BOUND=""
ACCOUNT_BIND_URL=""
ACCOUNT_BIND_USER_CODE=""

fetch_account_snapshot() {
    ACCOUNT_TASKS_REMAINING=""
    ACCOUNT_TASKS_TOTAL=""
    ACCOUNT_USD_REMAINING=""
    ACCOUNT_USD_TOTAL=""
    ACCOUNT_REFERRAL_CODE=""
    ACCOUNT_SHARE_TEXT=""
    ACCOUNT_IS_BOUND=""
    ACCOUNT_BIND_URL=""
    ACCOUNT_BIND_USER_CODE=""

    [ -n "$DEVICE_ID" ] || return 0
    [ -n "$DEVICE_TOKEN" ] || return 0

    device_api_request "GET" "/devices/${DEVICE_ID}/account"
    _acct_status=$?
    if [ "$_acct_status" -ne 0 ] || [ "$HTTP_CURL_EXIT" -ne 0 ] || [ "$HTTP_STATUS" != "200" ]; then
        return 0
    fi

    ACCOUNT_TASKS_TOTAL="$(json_int "budget.max_tasks" "$HTTP_BODY")"
    _used_tasks="$(json_int "budget.used_tasks" "$HTTP_BODY")"
    if [ -n "$ACCOUNT_TASKS_TOTAL" ] && [ -n "$_used_tasks" ]; then
        ACCOUNT_TASKS_REMAINING=$((ACCOUNT_TASKS_TOTAL - _used_tasks))
        if [ "$ACCOUNT_TASKS_REMAINING" -lt 0 ]; then
            ACCOUNT_TASKS_REMAINING=0
        fi
    fi

    ACCOUNT_USD_TOTAL="$(json_float "budget.budget_usd" "$HTTP_BODY")"
    _spent_usd="$(json_float "budget.spent_usd" "$HTTP_BODY")"
    if [ -n "$ACCOUNT_USD_TOTAL" ] && [ -n "$_spent_usd" ]; then
        if command -v python3 >/dev/null 2>&1; then
            ACCOUNT_USD_REMAINING="$(python3 - "$ACCOUNT_USD_TOTAL" "$_spent_usd" <<'PY'
import sys
total = float(sys.argv[1])
spent = float(sys.argv[2])
print(f"{max(0.0, total - spent):.2f}")
PY
)"
        else
            ACCOUNT_USD_REMAINING="$(awk -v total="$ACCOUNT_USD_TOTAL" -v spent="$_spent_usd" 'BEGIN { remaining = total - spent; if (remaining < 0) remaining = 0; printf "%.2f", remaining }')"
        fi
    fi

    ACCOUNT_REFERRAL_CODE="$(json_str "referral_code" "$HTTP_BODY")"
    ACCOUNT_SHARE_TEXT="$(json_str "share_text" "$HTTP_BODY")"
    ACCOUNT_IS_BOUND="$(printf '%s' "$HTTP_BODY" | json_extract_python "is_bound" "bool" 2>/dev/null || true)"
}

ensure_binding_link() {
    ACCOUNT_BIND_URL=""
    ACCOUNT_BIND_USER_CODE=""

    [ "${ACCOUNT_IS_BOUND:-}" = "true" ] && return 0
    [ -n "$DEVICE_ID" ] || return 0
    [ -n "$DEVICE_TOKEN" ] || return 0

    local os_type os_version arch hostname_val fingerprint hw_raw hardware_id os_profile
    os_type="$(uname -s)"
    case "$os_type" in
        Linux)  os_version="$(awk -F= '$1 == "PRETTY_NAME" { gsub(/^"/, "", $2); gsub(/"$/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || echo "Linux")"
                [ -n "$os_version" ] || os_version="Linux" ;;
        Darwin) os_version="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')" ;;
        *)      os_version="$os_type" ;;
    esac
    arch="$(uname -m)"
    hostname_val="$(hostname 2>/dev/null || echo 'unknown')"
    fingerprint="${os_type}|${arch}|${hostname_val}"

    hw_raw=""
    case "$os_type" in
        Darwin) hw_raw="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p' || true)" ;;
        Linux)
            for _p in /sys/class/dmi/id/product_uuid /sys/class/dmi/id/product_serial /sys/class/dmi/id/board_serial; do
                [ -r "$_p" ] || continue
                hw_raw="$(tr -d '\n' < "$_p" 2>/dev/null || true)"
                case "${hw_raw:-}" in ""|"Not Specified"|"Default string") hw_raw="" ;; *) break ;; esac
            done
            if [ -z "$hw_raw" ]; then
                hw_raw="$(tr -d '\n' < /etc/machine-id 2>/dev/null || tr -d '\n' < /var/lib/dbus/machine-id 2>/dev/null || true)"
            fi
            ;;
    esac
    hardware_id=""
    if [ -n "$hw_raw" ]; then
        hardware_id="$(printf '%s' "$hw_raw" | shasum -a 256 2>/dev/null | cut -d' ' -f1 \
            || printf '%s' "$hw_raw" | sha256sum 2>/dev/null | cut -d' ' -f1 || true)"
    fi

    os_profile="$(cat <<EOJSON
{"os_type":"$(json_escape "$os_type")","os_version":"$(json_escape "$os_version")","arch":"$(json_escape "$arch")","hostname":"$(json_escape "$hostname_val")","hardware_id":"$(json_escape "$hardware_id")","shell":"bash"}
EOJSON
)"

    device_api_request "POST" "/device-flows" "{\"device_id\":\"$(json_escape "$DEVICE_ID")\",\"fingerprint\":\"$(json_escape "$fingerprint")\",\"os_profile\":${os_profile}}"
    _flow_status=$?
    if [ "$_flow_status" -ne 0 ] || [ "$HTTP_CURL_EXIT" -ne 0 ] || [ "$HTTP_STATUS" != "200" ]; then
        return 0
    fi

    _bind_user_code="$(json_str "user_code" "$HTTP_BODY")"
    _bind_verification_uri="$(json_str "verification_uri" "$HTTP_BODY")"
    if [ -n "$_bind_user_code" ] && [ -n "$_bind_verification_uri" ]; then
        ACCOUNT_BIND_USER_CODE="$_bind_user_code"
        ACCOUNT_BIND_URL="${_bind_verification_uri}?user_code=${_bind_user_code}"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Phase 0: Install mode
# ═══════════════════════════════════════════════════════════════════

if [ "$RUN_MODE" != "run" ]; then
    mkdir -p "$DOCTOR_DIR"

    # Re-download the script with the embedded BASE_URL
    if curl -fsSL "${API_BASE_URL%/api/v1}/doctor?raw=1" -o "${DOCTOR_DIR}/run.sh" 2>/dev/null; then
        chmod +x "${DOCTOR_DIR}/run.sh"
    else
        # Fallback: write placeholder with the correct URL
        _base_no_api="${API_BASE_URL%/api/v1}"
        cat > "${DOCTOR_DIR}/run.sh" <<EOF
#!/usr/bin/env bash
echo "AIMA Doctor: install incomplete — script was not fully downloaded."
echo "Please re-run: curl -sL ${_base_no_api}/doctor | bash"
exit 1
EOF
        chmod +x "${DOCTOR_DIR}/run.sh"
        printf '  \033[33m⚠\033[0m Could not download doctor script; placeholder installed.\n'
    fi

    # Also grab PowerShell version (best-effort)
    curl -fsSL "${API_BASE_URL%/api/v1}/doctor?raw=1&shell=powershell" \
        -o "${DOCTOR_DIR}/run.ps1" 2>/dev/null || true

    # Write config
    cat > "${DOCTOR_DIR}/config.json" <<EOF
{
  "platform_url": "${API_BASE_URL}",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'unknown')",
  "version": "1.0.0"
}
EOF

    printf '\n  \033[1;32m✓ AIMA Doctor installed\033[0m\n'
    printf '  Location: %s\n' "$DOCTOR_DIR"
    printf '  Usage:\n'
    printf '    IM:       /aima [symptom]\n'
    printf '    Control:  /aima status | /aima cancel\n'
    printf '    Legacy:   /askforhelp* | /doctor*\n'
    printf '    Terminal: %s/run.sh --run --terminal\n' "$DOCTOR_DIR"
    printf '\n'
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════
# Phase 1: Load device identity
# ═══════════════════════════════════════════════════════════════════

emit_status "collecting" "AIMA Doctor 启动中... / Starting AIMA Doctor..."

# Try config.json for platform URL (if launched from installed location)
if [ "$API_BASE_URL" = "__BASE_URL__" ] && [ -f "${DOCTOR_DIR}/config.json" ]; then
    _cfg_url="$(json_str "platform_url" "$(cat "${DOCTOR_DIR}/config.json")")"
    [ -n "$_cfg_url" ] && API_BASE_URL="$_cfg_url"
fi

# Ensure we have a usable API URL
if [ "$API_BASE_URL" = "__BASE_URL__" ] || [ -z "$API_BASE_URL" ]; then
    emit_message "无法确定平台地址。请使用 --platform-url 参数。/ Cannot determine platform URL. Use --platform-url." "error"
    emit_done "false" "No platform URL configured"
    exit 1
fi

# --- Identity resolution (priority order) ---

# 1. Environment variables from OpenClaw
if [ -n "${OPENCLAW_DEVICE_ID:-}" ] && [ -n "${OPENCLAW_DEVICE_TOKEN:-}" ]; then
    DEVICE_ID="$OPENCLAW_DEVICE_ID"
    DEVICE_TOKEN="$OPENCLAW_DEVICE_TOKEN"
    RECOVERY_CODE="${OPENCLAW_RECOVERY_CODE:-}"
    emit_message "从 OpenClaw 环境读取设备身份 / Device identity from OpenClaw env" "info"

# 2. Python CLI state (JSON)
elif [ -f "$CLI_STATE_FILE" ] && command -v python3 >/dev/null 2>&1; then
    _cli_state="$(cat "$CLI_STATE_FILE")"
    _cli_did="$(json_str "device_id" "$_cli_state")"
    _cli_tok="$(json_str "token" "$_cli_state")"
    if [ -n "$_cli_did" ] && [ -n "$_cli_tok" ]; then
        DEVICE_ID="$_cli_did"
        DEVICE_TOKEN="$_cli_tok"
        RECOVERY_CODE="$(json_str "recovery_code" "$_cli_state")"
        _cli_url="$(json_str "platform_url" "$_cli_state")"
        [ -n "$_cli_url" ] && API_BASE_URL="$_cli_url"
        emit_message "从 CLI 状态文件读取设备身份 / Device identity from CLI state" "info"
    fi

# 3. Bash bootstrap state (KEY=VALUE)
elif [ -f "$STATE_FILE" ]; then
    _load_kv() { sed -n "s/^${1}=//p" "$STATE_FILE" | head -1; }
    _bs_did="$(_load_kv DEVICE_ID)"
    _bs_tok="$(_load_kv DEVICE_TOKEN)"
    if [ -n "$_bs_did" ] && [ -n "$_bs_tok" ]; then
        DEVICE_ID="$_bs_did"
        DEVICE_TOKEN="$_bs_tok"
        RECOVERY_CODE="$(_load_kv RECOVERY_CODE)"
        _bs_url="$(_load_kv PLATFORM_URL)"
        [ -n "$_bs_url" ] && API_BASE_URL="$_bs_url"
        emit_message "从本地状态文件读取设备身份 / Device identity from local state" "info"
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# Phase 1b: Register if needed
# ═══════════════════════════════════════════════════════════════════

if [ -z "$DEVICE_ID" ] || [ -z "$DEVICE_TOKEN" ]; then
    emit_status "registering" "设备未注册，需要注册新设备 / Device not registered"
    register_or_refresh_device "$DEFAULT_INVITE_CODE"
    _register_status=$?
    if [ "$_register_status" -ne 0 ]; then
        if [ "$_register_status" -eq 2 ]; then
            emit_done "false" "取消注册 / Registration cancelled"
        elif [ -n "$LAST_REGISTRATION_FAILURE_SUMMARY" ]; then
            emit_done "false" "$LAST_REGISTRATION_FAILURE_SUMMARY"
        else
            emit_done "false" "Registration failed"
        fi
        exit 1
    fi
    emit_message "设备注册成功 / Device registered: ${DEVICE_ID}" "info"
fi

# ═══════════════════════════════════════════════════════════════════
# Phase 2: Collect diagnostics
# ═══════════════════════════════════════════════════════════════════

emit_status "collecting" "正在收集系统诊断信息... / Collecting system diagnostics..."

DIAG_LINES=""
_diag() { DIAG_LINES="${DIAG_LINES}$1\n"; }

# OpenClaw process
if pgrep -f '[o]penclaw' >/dev/null 2>&1; then
    _diag "- openclaw_running: true"
    emit_message "OpenClaw 进程运行中 / OpenClaw process running" "info"
else
    _diag "- openclaw_running: false"
    emit_message "OpenClaw 进程未运行 / OpenClaw process NOT running" "warn"
fi

# Config files
_oc_config=""
for _cf in \
    "${OPENCLAW_CONFIG_PATH:-}" \
    "${HOME}/.openclaw/openclaw.json" \
    "${HOME}/.openclaw/config.json" \
    "${HOME}/.openclaw/config.yaml" \
    "${HOME}/.config/openclaw/openclaw.json" \
    "${HOME}/.config/openclaw/config.json"; do
    [ -n "$_cf" ] || continue
    if [ -f "$_cf" ]; then
        _oc_config="$_cf"
        break
    fi
done
if [ -n "$_oc_config" ]; then
    _diag "- config_file: ${_oc_config} (exists)"
    emit_message "配置文件存在 / Config file found: ${_oc_config}" "info"
else
    _diag "- config_file: not found"
    emit_message "未找到配置文件 / No config file found" "warn"
fi

# Recent logs (last 30 lines)
_oc_log=""
for _lf in "${HOME}/.openclaw/logs/latest.log" "${HOME}/.openclaw/"*.log; do
    if [ -f "$_lf" ]; then
        _oc_log="$_lf"
        break
    fi
done
if [ -n "$_oc_log" ]; then
    _log_tail="$(tail -30 "$_oc_log" 2>/dev/null || true)"
    _diag "- recent_log: ${_oc_log} (last 30 lines attached)"
    _diag "--- log start ---"
    _diag "$_log_tail"
    _diag "--- log end ---"
else
    _diag "- recent_log: no log file found"
fi

# Disk space
_disk_info="$(df -h "${HOME}" 2>/dev/null | tail -1 || echo 'unknown')"
_diag "- disk: ${_disk_info}"

# Network
_net_status="unknown"
if curl -fsS -o /dev/null -w '%{http_code}' "${API_BASE_URL%/api/v1}/healthz" --max-time 5 >/dev/null 2>&1; then
    _net_status="ok"
    emit_message "网络连通 / Network OK" "info"
else
    _net_status="unreachable"
    emit_message "平台网络不通 / Platform unreachable" "warn"
fi
_diag "- network: ${_net_status}"

# OS info
_diag "- os: $(uname -s) $(uname -r) $(uname -m)"
_diag "- hostname: $(hostname 2>/dev/null || echo unknown)"
_py_ver="$(python3 --version 2>/dev/null || echo 'python3 not found')"
_diag "- python: ${_py_ver}"
_node_ver="$(node --version 2>/dev/null || echo 'node not found')"
_diag "- node: ${_node_ver}"

# ═══════════════════════════════════════════════════════════════════
# Phase 3: Create diagnostic task
# ═══════════════════════════════════════════════════════════════════

emit_status "diagnosing" "正在创建诊断任务... / Creating diagnosis task..."
_task_id=""
while true; do
    _task_desc="OpenClaw doctor: ${SYMPTOM:-用户通过 /aima 触发诊断 / User triggered /aima diagnosis}

自动诊断信息 / Auto-collected diagnostics:
$(printf '%b' "$DIAG_LINES")"

    _escaped_desc="$(json_escape "$_task_desc")"

    device_api_request "POST" "/devices/${DEVICE_ID}/tasks" "{\"description\":\"${_escaped_desc}\"}"
    _api_status=$?
    if [ "$_api_status" -ne 0 ]; then
        exit_due_to_auth_failure "$_api_status"
    fi

    if [ "$HTTP_CURL_EXIT" -eq 0 ] && [ "$HTTP_STATUS" = "200" ]; then
        _task_id="$(json_str "task_id" "$HTTP_BODY")"
        emit_message "诊断任务已创建，AI agent 正在分析... / Diagnosis task created, AI agent analyzing..." "info"
        break
    fi

    _detail="$(json_str "detail" "$HTTP_BODY")"
    if [ "$HTTP_STATUS" = "409" ]; then
        _existing_task_id="$(printf '%s' "${_detail:-}" | sed -n 's/^device already has active task: //p' | head -n 1)"
        if [ -z "$_existing_task_id" ]; then
            emit_done "false" "${_detail:-创建任务失败 / Task creation failed}" "failed"
            exit 1
        fi
        if ! resolve_existing_task_conflict "$_existing_task_id"; then
            exit 1
        fi
        if [ "$CONFLICT_ACTION" = "resume" ]; then
            _task_id="$_existing_task_id"
            emit_message "继续跟进上一次未完成的救援 / Continuing the unfinished rescue" "warn"
            break
        fi
        if [ "$CONFLICT_ACTION" = "restart" ]; then
            if [ -n "$CONFLICT_RESTART_SYMPTOM" ]; then
                SYMPTOM="$CONFLICT_RESTART_SYMPTOM"
            fi
            if ! cancel_task_by_id "$_existing_task_id"; then
                emit_done "false" "无法取消旧救援，请稍后重试 / Failed to cancel the previous rescue. Please try again." "failed"
                exit 1
            fi
            emit_message "已取消旧救援，正在重新创建任务 / Previous rescue cancelled; creating a new task" "warn"
            sleep 1
            continue
        fi
    elif [ "$HTTP_STATUS" = "402" ]; then
        fetch_account_snapshot || true
        ensure_binding_link || true
        emit_done "false" "${_detail:-创建任务失败 / Task creation failed}" "failed" \
            "$ACCOUNT_TASKS_REMAINING" "$ACCOUNT_TASKS_TOTAL" \
            "$ACCOUNT_USD_REMAINING" "$ACCOUNT_USD_TOTAL" \
            "$ACCOUNT_REFERRAL_CODE" "$ACCOUNT_SHARE_TEXT" \
            "$ACCOUNT_BIND_URL" "$ACCOUNT_BIND_USER_CODE"
        exit 1
    else
        emit_done "false" "${_detail:-创建任务失败 / Task creation failed}" "failed"
        exit 1
    fi
done

# ═══════════════════════════════════════════════════════════════════
# Phase 4: Poll loop
# ═══════════════════════════════════════════════════════════════════

emit_status "executing" "等待 AI agent 响应... / Waiting for AI agent..."

_answered=""

while true; do
    device_api_request "GET" "/devices/${DEVICE_ID}/poll?wait=${POLL_INTERVAL}"
    _api_status=$?
    if [ "$_api_status" -ne 0 ]; then
        exit_due_to_auth_failure "$_api_status"
    fi

    # Network / server error — retry
    if [ "$HTTP_CURL_EXIT" -ne 0 ] || [ "$HTTP_STATUS" != "200" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    _resp="$HTTP_BODY"

    # --- Interaction (agent question) ---
    _int_id="$(json_str "interaction_id" "$_resp")"
    _question="$(json_str "question" "$_resp")"
    _interaction_type="$(json_str "interaction_type" "$_resp")"
    _interaction_level="$(json_str "interaction_level" "$_resp")"

    if [ -n "$_int_id" ] && [ -n "$_question" ]; then
        if is_transport_interruption_question "$_question"; then
            emit_transport_interrupted
            exit 0
        fi
        # Skip already-answered
        case " $_answered " in *" $_int_id "*) sleep 1; continue ;; esac

        if [ "$_interaction_type" = "notification" ]; then
            emit_message "$_question" "${_interaction_level:-info}"
            device_api_request "POST" "/devices/${DEVICE_ID}/interactions/${_int_id}/respond" "{\"answer\":\"displayed\"}"
            _api_status=$?
            if [ "$_api_status" -ne 0 ]; then
                exit_due_to_auth_failure "$_api_status"
            fi
            if [ "${HTTP_CURL_EXIT}" -eq 0 ] && [ "$HTTP_STATUS" = "200" ]; then
                _answered="$_answered $_int_id"
            fi
            continue
        fi

        emit_prompt "$_int_id" "$_question"
        if read_answer "$_int_id"; then
            device_api_request "POST" "/devices/${DEVICE_ID}/interactions/${_int_id}/respond" "{\"answer\":\"$(json_escape "$ANSWER")\"}"
            _api_status=$?
            if [ "$_api_status" -ne 0 ]; then
                exit_due_to_auth_failure "$_api_status"
            fi
            _answered="$_answered $_int_id"
        else
            # Cancel
            emit_done "false" "用户取消 / Cancelled by user"
            exit 0
        fi
        continue
    fi

    # --- Command (agent wants to execute on device) ---
    _cmd_id="$(json_str "command_id" "$_resp")"
    _raw_cmd="$(json_str "command" "$_resp")"
    _cmd_encoding="$(json_str "command_encoding" "$_resp")"
    _cmd_timeout="$(json_int "command_timeout_seconds" "$_resp")"
    _cmd_timeout="${_cmd_timeout:-300}"
    _cmd_intent="$(json_str "command_intent" "$_resp")"

    if [ -n "$_cmd_id" ] && [ -n "$_raw_cmd" ]; then
        _cmd="$_raw_cmd"
        if [ "$_cmd_encoding" = "base64" ]; then
            _cmd="$(printf '%s' "$_raw_cmd" | base64 -d 2>/dev/null || printf '%s' "$_raw_cmd" | base64 -D 2>/dev/null || printf '%s' "$_raw_cmd")"
        fi

        emit_message "正在执行: ${_cmd_intent:-command} / Running: ${_cmd_intent:-command}" "info"

        # Execute with deadline (no GNU timeout — must work on macOS)
        _tmp_out="$(mktemp)"
        _timed_out=0
        set +e
        bash -c "$_cmd" > "$_tmp_out" 2>&1 &
        _cmd_pid=$!
        _deadline=$((SECONDS + _cmd_timeout))
        while kill -0 "$_cmd_pid" 2>/dev/null; do
            if [ "$SECONDS" -ge "$_deadline" ]; then
                kill "$_cmd_pid" 2>/dev/null; wait "$_cmd_pid" 2>/dev/null
                _timed_out=1
                break
            fi
            sleep 1
        done
        wait "$_cmd_pid" 2>/dev/null
        _exit_code=$?
        set -e
        _stdout="$(cat "$_tmp_out")"
        rm -f "$_tmp_out"

        if [ "$_timed_out" -eq 1 ]; then
            _exit_code=124
            _stdout="${_stdout}\n[TIMED OUT after ${_cmd_timeout}s]"
        fi

        emit_command_output "$_cmd_intent" "$_stdout"

        # Report result
        _payload_file="$(mktemp)"
        cat > "$_payload_file" <<EOJSON
{
  "command_id": "${_cmd_id}",
  "exit_code": ${_exit_code},
  "stdout": "$(json_escape "$_stdout")",
  "stderr": "",
  "timed_out": $([ "$_timed_out" -eq 1 ] && echo true || echo false)
}
EOJSON

        _result_payload="$(cat "$_payload_file")"
        device_api_request "POST" "/devices/${DEVICE_ID}/result" "$_result_payload"
        _api_status=$?
        if [ "$_api_status" -ne 0 ]; then
            rm -f "$_payload_file"
            exit_due_to_auth_failure "$_api_status"
        fi
        rm -f "$_payload_file"
        continue
    fi

    # --- Task completion notification ---
    _notif_status="$(json_str "notif_task_status" "$_resp")"
    if [ -n "$_notif_status" ]; then
        _notif_msg="$(json_str "notif_task_message" "$_resp")"
        _notif_budget_tasks_remaining="$(json_int "notif_budget_tasks_remaining" "$_resp")"
        _notif_budget_tasks_total="$(json_int "notif_budget_tasks_total" "$_resp")"
        _notif_budget_usd_remaining="$(json_float "notif_budget_usd_remaining" "$_resp")"
        _notif_budget_usd_total="$(json_float "notif_budget_usd_total" "$_resp")"
        _notif_referral_code="$(json_str "notif_referral_code" "$_resp")"
        _notif_share_text="$(json_str "notif_share_text" "$_resp")"
        fetch_account_snapshot || true
        ensure_binding_link || true
        case "${_notif_status}" in
            succeeded|SUCCEEDED)
            emit_done "true" "${_notif_msg:-诊断完成 / Diagnosis complete}" "$_notif_status" \
                "$_notif_budget_tasks_remaining" "$_notif_budget_tasks_total" \
                "$_notif_budget_usd_remaining" "$_notif_budget_usd_total" \
                "$_notif_referral_code" "$_notif_share_text" \
                "$ACCOUNT_BIND_URL" "$ACCOUNT_BIND_USER_CODE"
            ;;
            *)
            emit_done "false" "${_notif_msg:-任务失败 / Task failed (${_notif_status})}" "$_notif_status" \
                "$_notif_budget_tasks_remaining" "$_notif_budget_tasks_total" \
                "$_notif_budget_usd_remaining" "$_notif_budget_usd_total" \
                "$_notif_referral_code" "$_notif_share_text" \
                "$ACCOUNT_BIND_URL" "$ACCOUNT_BIND_USER_CODE"
            ;;
        esac
        exit 0
    fi

    # Nothing to do — just wait
done
