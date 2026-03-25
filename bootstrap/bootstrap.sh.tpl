#!/usr/bin/env bash
# AIMA bootstrap for Linux/macOS

set -euo pipefail

ACTIVATION_CODE="__ACTIVATION_CODE__"
BASE_URL="__BASE_URL__"
POLL_INTERVAL_SECONDS="__POLL_INTERVAL_SECONDS__"
SHOW_RAW_COMMANDS="${AIMA_SHOW_RAW_COMMANDS:-0}"

case "$SHOW_RAW_COMMANDS" in
    1|true|TRUE|yes|YES|on|ON) SHOW_RAW_COMMANDS=1 ;;
    *) SHOW_RAW_COMMANDS=0 ;;
esac

json_value() {
    echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}
json_bool() {
    echo "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p"
}

sanitize_for_json() {
    # 1. Try iconv to strip invalid UTF-8 (preserves Chinese/emoji)
    # 2. Fall back to ASCII-only if iconv unavailable
    # 3. Strip control chars except tab/newline, cap at 512KB
    if command -v iconv >/dev/null 2>&1; then
        iconv -f UTF-8 -t UTF-8//IGNORE 2>/dev/null
    else
        LC_ALL=C tr -cd '\11\12\15\40-\176'
    fi | tr -d '\000-\010\016-\037' | head -c 524288
}

escape_json() {
    # Escape for embedding in a JSON string value.
    # Process: sanitize → escape backslash/quote/tab/cr → convert newlines to \n
    printf '%s' "$1" | sanitize_for_json \
        | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s/\r/\\r/g' \
        | awk 'NR>1{printf "\\n"}{printf "%s",$0}'
}

STATE_FILE="${HOME}/.aima-device-state"

save_device_state() {
    printf 'DEVICE_ID=%s\nDEVICE_TOKEN=%s\n' \
        "$DEVICE_ID" "$DEVICE_TOKEN" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

load_device_state() {
    if [ -f "$STATE_FILE" ]; then
        DEVICE_ID="$(grep '^DEVICE_ID=' "$STATE_FILE" | head -1 | cut -d= -f2-)"
        DEVICE_TOKEN="$(grep '^DEVICE_TOKEN=' "$STATE_FILE" | head -1 | cut -d= -f2-)"
        return 0
    fi
    return 1
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

get_os_type() {
    uname -s
}

get_os_version() {
    if [ "$(uname -s)" = "Darwin" ]; then
        local name ver
        name="$(sw_vers -productName 2>/dev/null || echo "macOS")"
        ver="$(sw_vers -productVersion 2>/dev/null || uname -r)"
        echo "${name} ${ver}"
    elif [ -f /etc/os-release ]; then
        local pretty
        pretty="$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"
        echo "${pretty:-$(uname -r)}"
    else
        uname -r
    fi
}

get_machine_id() {
    if [ -f /etc/machine-id ]; then
        cat /etc/machine-id
    elif [ "$(uname -s)" = "Darwin" ]; then
        ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}'
    fi
}

detect_package_managers() {
    local caps=""
    command -v brew    >/dev/null 2>&1 && caps="${caps}\"brew\","
    command -v apt-get >/dev/null 2>&1 && caps="${caps}\"apt\","
    command -v dnf     >/dev/null 2>&1 && caps="${caps}\"dnf\","
    command -v yum     >/dev/null 2>&1 && caps="${caps}\"yum\","
    command -v snap    >/dev/null 2>&1 && caps="${caps}\"snap\","
    echo "[${caps%,}]"
}

generate_fingerprint() {
    local os_type
    local os_version
    local arch
    local hostname_value
    local machine_id=""

    os_type="$(get_os_type)"
    os_version="$(get_os_version)"
    arch="$(uname -m)"
    hostname_value="$(hostname)"
    machine_id="$(get_machine_id)"

    printf '%s|%s|%s|%s|%s' "$os_type" "$os_version" "$arch" "$hostname_value" "$machine_id"
}

build_os_profile() {
    local os_type os_version arch hostname_value machine_id pkg_mgrs shell_type
    os_type="$(get_os_type)"
    os_version="$(get_os_version)"
    arch="$(uname -m)"
    hostname_value="$(hostname)"
    machine_id="$(get_machine_id)"
    pkg_mgrs="$(detect_package_managers)"
    shell_type="bash"

    printf '{"os_type":"%s","os_version":"%s","arch":"%s","hostname":"%s","machine_id":"%s","package_managers":%s,"shell":"%s"}' \
        "$(escape_json "$os_type")" \
        "$(escape_json "$os_version")" \
        "$(escape_json "$arch")" \
        "$(escape_json "$hostname_value")" \
        "$(escape_json "$machine_id")" \
        "$pkg_mgrs" \
        "$shell_type"
}

# Terminal colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

log_info() { printf "${CYAN}  ● [AIMA] %b${NC}\n" "$1"; }
log_success() { printf "${GREEN}  ✔ [AIMA] %b${NC}\n" "$1"; }
log_warn() { printf "${YELLOW}  ⚠ [AIMA] %b${NC}\n" "$1"; }
log_error() { printf "${RED}  ✖ [AIMA] %b${NC}\n" "$1"; }
log_dim() { printf "${GRAY}  ● [AIMA] %b${NC}\n" "$1"; }
log_agent() { printf "${CYAN}  ➜ [AIMA Agent] %b${NC}\n" "$1"; }

register_device() {
    local fingerprint
    local os_profile
    local response

    fingerprint="$(generate_fingerprint)"
    os_profile="$(build_os_profile)"
    response="$(curl -sf -X POST "${BASE_URL}/devices/register" \
        -H "Content-Type: application/json" \
        -d "{\"activation_code\":\"${ACTIVATION_CODE}\",\"fingerprint\":\"$(escape_json "$fingerprint")\",\"os_profile\":${os_profile}}")"

    DEVICE_ID="$(json_value "$response" "device_id")"
    DEVICE_TOKEN="$(json_value "$response" "token")"

    if [ -z "${DEVICE_ID:-}" ] || [ -z "${DEVICE_TOKEN:-}" ]; then
        log_error "注册失败 / Registration failed"
        exit 1
    fi

    echo ""
    log_info "设备注册成功 / Device registered: ${DEVICE_ID}"
}

post_offline() {
    if [ -n "${DEVICE_ID:-}" ] && [ -n "${DEVICE_TOKEN:-}" ]; then
        curl -sf -X POST "${BASE_URL}/devices/${DEVICE_ID}/offline" \
            -H "Authorization: Bearer ${DEVICE_TOKEN}" >/dev/null 2>&1 || true
    fi
}

renew_token() {
    local new_token

    request_with_status -X POST "${BASE_URL}/devices/${DEVICE_ID}/renew-token" \
        -H "Authorization: Bearer ${DEVICE_TOKEN}"

    if [ "${HTTP_STATUS}" = "401" ]; then
        log_error "凭证无效或已过期，正在退出... / Device token invalid or expired during renewal; exiting"
        exit 1
    fi
    if [ "${HTTP_CURL_EXIT}" -ne 0 ] || [ "${HTTP_STATUS}" != "200" ]; then
        return 0
    fi

    new_token="$(json_value "$HTTP_BODY" "token")"
    if [ -n "$new_token" ]; then
        DEVICE_TOKEN="$new_token"
        save_device_state
        log_dim "凭证已更新 / Token renewed"
    fi
}

submit_command_result() {
    local body="$1"
    local attempt=0

    while true; do
        request_with_status -X POST "${BASE_URL}/devices/${DEVICE_ID}/result" \
            -H "Authorization: Bearer ${DEVICE_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$body"

        if [ "${HTTP_STATUS}" = "200" ]; then
            return 0
        fi
        if [ "${HTTP_STATUS}" = "401" ]; then
            log_error "凭证无效，正在退出... / Device token invalid while submitting command result; exiting"
            exit 1
        fi
        case "${HTTP_STATUS}" in
            403|404)
                log_error "凭证被拒绝 (HTTP ${HTTP_STATUS})，正在退出... / Device credentials rejected; exiting"
                rm -f "$STATE_FILE"
                return 1
                ;;
            4??)
                log_error "结果被永久拒绝 (HTTP ${HTTP_STATUS}) / Command result rejected permanently; not retrying"
                return 1
                ;;
        esac

        attempt=$((attempt + 1))
        if [ "$attempt" -ge 10 ]; then
            log_error "结果提交失败 (尝试 ${attempt} 次)，正在放弃 / Result submit failed after ${attempt} attempts; abandoning"
            return 1
        fi
        local delay=$((attempt * 5))
        if [ "$delay" -gt 30 ]; then
            delay=30
        fi
        log_warn "结果提交失败，${delay}s 后重试 (第 ${attempt} 次) / Result submit failed; retrying in ${delay}s"
        sleep "$delay"
    done
}

build_progress_payload() {
    local stdout_file="$1"
    local stderr_file="$2"
    local message="$3"
    local stdout_text=""
    local stderr_text=""
    local trimmed_message=""

    if [ -f "$stdout_file" ]; then
        stdout_text="$(tail -c 4096 "$stdout_file" 2>/dev/null || cat "$stdout_file" 2>/dev/null || true)"
    fi
    if [ -f "$stderr_file" ]; then
        stderr_text="$(tail -c 4096 "$stderr_file" 2>/dev/null || cat "$stderr_file" 2>/dev/null || true)"
    fi
    trimmed_message="$(printf '%s' "$message" | head -c 500)"

    printf '{"stdout":"%s","stderr":"%s"' \
        "$(escape_json "$stdout_text")" \
        "$(escape_json "$stderr_text")"
    if [ -n "$trimmed_message" ]; then
        printf ',"message":"%s"' "$(escape_json "$trimmed_message")"
    fi
    printf '}'
}

submit_command_progress() {
    local command_id="$1"
    local body="$2"

    request_with_status -X POST "${BASE_URL}/devices/${DEVICE_ID}/commands/${command_id}/progress" \
        --max-time 10 \
        -H "Authorization: Bearer ${DEVICE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$body"

    if [ "${HTTP_STATUS}" = "401" ] || [ "${HTTP_STATUS}" = "403" ] || [ "${HTTP_STATUS}" = "404" ]; then
        return 2
    fi
    if [ "${HTTP_CURL_EXIT}" -ne 0 ] || [ "${HTTP_STATUS}" != "200" ]; then
        return 1
    fi
    if [ "$(json_bool cancel_requested "$HTTP_BODY")" = "true" ] || [ "$(json_value "$HTTP_BODY" "command_status")" = "cancelled" ]; then
        return 10
    fi
    return 0
}

terminate_process_tree() {
    local cmd_pid="$1"
    pkill -TERM -P "$cmd_pid" 2>/dev/null || true
    kill "$cmd_pid" 2>/dev/null || true
    sleep 1
    pkill -KILL -P "$cmd_pid" 2>/dev/null || true
    kill -9 "$cmd_pid" 2>/dev/null || true
}

execute_command() {
    local command_id="$1"
    local raw_command="$2"
    local command_encoding="${3:-}"
    local command_timeout="${4:-300}"
    local command_intent="${5:-}"
    local stdout_text=""
    local stderr_text=""
    local output=""
    local exit_code=0
    local started_at="$SECONDS"
    local result_id
    result_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || printf 'res_%s_%s' "$(date +%s)" "$$")"

    # Decode base64-encoded commands (transparent transport)
    local command
    if [ "$command_encoding" = "base64" ]; then
        command="$(printf '%s' "$raw_command" | base64 -d 2>/dev/null)" || command="$raw_command"
    else
        command="$raw_command"
    fi

    local COMMAND_TIMEOUT="$command_timeout"

    if [ -n "$command_intent" ]; then
        log_agent "${command_intent}"
    else
        local command_preview
        command_preview="$(printf '%s' "$command" | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//' | head -c 96)"
        log_warn "未提供步骤说明，正在执行已授权命令：${command_preview} / No step summary was provided; running authorized command: ${command_preview}"
    fi
    if [ "$SHOW_RAW_COMMANDS" -eq 1 ]; then
        log_dim "正在执行 / Executing: ${command}"
    fi
    local tmp_stdout tmp_stderr tmp_script
    tmp_stdout="$(mktemp)"
    tmp_stderr="$(mktemp)"
    tmp_script="$(mktemp /tmp/aima_cmd_XXXXXX.sh)"
    printf '%s\n' "$command" > "$tmp_script"
    chmod +x "$tmp_script"
    local progress_deadline progress_next_at remote_cancel_requested timed_out
    progress_deadline=$((SECONDS + COMMAND_TIMEOUT))
    progress_next_at=$((SECONDS + 5))
    remote_cancel_requested=0
    timed_out=0
    set +e
    bash -l "$tmp_script" >"$tmp_stdout" 2>"$tmp_stderr" &
    local cmd_pid=$!
    while kill -0 "$cmd_pid" 2>/dev/null; do
        if [ "$SECONDS" -ge "$progress_deadline" ]; then
            terminate_process_tree "$cmd_pid"
            wait "$cmd_pid" 2>/dev/null || true
            exit_code=124
            timed_out=1
            log_error "指令执行超时 (${COMMAND_TIMEOUT}s) / Command timed out."
            echo "Command timed out after ${COMMAND_TIMEOUT}s" >> "$tmp_stderr"
            break
        fi
        if [ "$SECONDS" -ge "$progress_next_at" ]; then
            local progress_elapsed progress_body progress_status
            progress_elapsed=$((SECONDS - started_at))
            progress_body="$(build_progress_payload "$tmp_stdout" "$tmp_stderr" "Command still running (${progress_elapsed}s)")"
            submit_command_progress "$command_id" "$progress_body"
            progress_status=$?
            progress_next_at=$((SECONDS + 5))
            if [ "$progress_status" -eq 10 ]; then
                log_warn "收到远程取消请求，正在停止... / Cancellation requested remotely; stopping."
                terminate_process_tree "$cmd_pid"
                wait "$cmd_pid" 2>/dev/null || true
                exit_code=130
                remote_cancel_requested=1
                echo "Command cancelled after remote request" >> "$tmp_stderr"
                break
            fi
        fi
        sleep 1
    done
    if [ "$timed_out" -ne 1 ] && [ "$remote_cancel_requested" -ne 1 ]; then
        wait "$cmd_pid"
        exit_code=$?
    fi
    set -e
    stdout_text="$(cat "$tmp_stdout")"
    stderr_text="$(cat "$tmp_stderr")"
    rm -f "$tmp_stdout" "$tmp_stderr" "$tmp_script"

    stdout_text="$(printf '%s' "$stdout_text" | head -c 524288)"
    stderr_text="$(printf '%s' "$stderr_text" | head -c 524288)"

    if [ "$SHOW_RAW_COMMANDS" -ne 1 ]; then
        local elapsed=$((SECONDS - started_at))
        if [ "$exit_code" -eq 0 ]; then
            log_success "步骤已完成 / Step completed (${elapsed}s)"
        else
            log_error "步骤失败 / Step failed (exit ${exit_code}, ${elapsed}s)"
        fi
    fi

    submit_command_result "{\"command_id\":\"${command_id}\",\"exit_code\":${exit_code},\"stdout\":\"$(escape_json "$stdout_text")\",\"stderr\":\"$(escape_json "$stderr_text")\",\"result_id\":\"${result_id}\"}"
}

handle_interaction() {
    local interaction_id="$1"
    local question="$2"
    local interaction_type="${3:-info_request}"

    if [ "$interaction_type" = "notification" ]; then
        echo ""
        log_agent "${question}"
        curl -sf -X POST \
            "${BASE_URL}/devices/${DEVICE_ID}/interactions/${interaction_id}/respond" \
            -H "Authorization: Bearer ${DEVICE_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"answer\":\"displayed\"}" >/dev/null 2>&1 || true
        return
    fi

    if [ -t 0 ] && [ -t 1 ]; then
        echo ""
        log_agent "智能体提问 / Agent asks: ${question}"
        printf "  你的回答 / Your answer (直接回车可跳过): "
        local answer
        IFS= read -r answer
        if [ -n "$answer" ]; then
            curl -sf -X POST \
                "${BASE_URL}/devices/${DEVICE_ID}/interactions/${interaction_id}/respond" \
                -H "Authorization: Bearer ${DEVICE_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"answer\":\"$(escape_json "$answer")\"}" >/dev/null || true
        fi
    fi
    # Non-interactive terminal: silently skip
}

main_loop() {
    local retry_interval=5
    local LAST_RENEW
    LAST_RENEW=$(date +%s)
    local TOKEN_RENEW_INTERVAL=86400  # 24 hours

    while true; do
        local NOW
        NOW=$(date +%s)
        if [ $((NOW - LAST_RENEW)) -ge $TOKEN_RENEW_INTERVAL ]; then
            renew_token
            LAST_RENEW=$NOW
        fi

        local poll_response
        request_with_status --max-time 15 "${BASE_URL}/devices/${DEVICE_ID}/poll?wait=10" \
            -H "Authorization: Bearer ${DEVICE_TOKEN}"
        if [ "${HTTP_STATUS}" = "401" ]; then
            log_error "凭证无效或已过期，正在退出... / Device token invalid or expired; exiting"
            break
        fi
        if [ "${HTTP_CURL_EXIT}" -ne 0 ] || [ "${HTTP_STATUS}" != "200" ]; then
            log_dim "轮询失败，${retry_interval}s 后重试... / Poll failed, retry in ${retry_interval}s"
            sleep "$retry_interval"
            retry_interval=$((retry_interval * 2))
            if [ "$retry_interval" -gt 60 ]; then
                retry_interval=60
            fi
            continue
        fi

        poll_response="$HTTP_BODY"

        retry_interval=5

        # Handle commands
        local command_id
        local command
        local command_encoding
        local command_timeout
        local command_intent
        command_id="$(json_value "$poll_response" "command_id")"
        command="$(json_value "$poll_response" "command")"
        command_encoding="$(json_value "$poll_response" "command_encoding")"
        command_timeout="$(json_value "$poll_response" "command_timeout_seconds")"
        command_intent="$(json_value "$poll_response" "command_intent")"
        if [ -n "$command_id" ] && [ -n "$command" ]; then
            execute_command "$command_id" "$command" "$command_encoding" "${command_timeout:-300}" "$command_intent"
        fi

        # Handle interactions
        local interaction_id
        local question
        local interaction_type
        interaction_id="$(json_value "$poll_response" "interaction_id")"
        question="$(json_value "$poll_response" "question")"
        interaction_type="$(json_value "$poll_response" "interaction_type")"
        if [ -n "$interaction_id" ] && [ -n "$question" ]; then
            handle_interaction "$interaction_id" "$question" "$interaction_type"
        fi
    done
}

trap post_offline INT TERM EXIT

# Try to reuse existing device identity
if load_device_state && [ -n "${DEVICE_ID:-}" ] && [ -n "${DEVICE_TOKEN:-}" ]; then
    log_dim "发现已保存的状态，正在验证... / Found saved state, validating..."
    request_with_status --max-time 10 "${BASE_URL}/devices/${DEVICE_ID}/poll?wait=0" \
        -H "Authorization: Bearer ${DEVICE_TOKEN}"
    if [ "${HTTP_STATUS}" = "200" ] || [ "${HTTP_STATUS}" = "204" ]; then
        log_info "正在使用现有设备 / Reusing existing device: ${DEVICE_ID}"
    else
        log_warn "状态无效，正在重新注册... / Saved state invalid (HTTP ${HTTP_STATUS}), registering fresh"
        DEVICE_ID=""
        DEVICE_TOKEN=""
        rm -f "$STATE_FILE"
        register_device
        save_device_state
    fi
else
    register_device
    save_device_state
fi
main_loop
