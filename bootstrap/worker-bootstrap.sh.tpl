#!/usr/bin/env bash
set -euo pipefail

WORKER_BOOTSTRAP_CODE=__WORKER_BOOTSTRAP_CODE__
PLATFORM_URL=__PLATFORM_URL__
WORKER_NAME=__WORKER_NAME__
RUNTIME=__RUNTIME__
CLAUDE_MODEL=__CLAUDE_MODEL__
CLAUDE_EFFORT=__CLAUDE_EFFORT__
CODEX_HOME_DIR=__CODEX_HOME_DIR__
CODEX_MODEL=__CODEX_MODEL__
CODEX_MODEL_REASONING_EFFORT=__CODEX_MODEL_REASONING_EFFORT__
CODEX_SANDBOX_MODE=__CODEX_SANDBOX_MODE__
CODEX_APPROVAL_POLICY=__CODEX_APPROVAL_POLICY__
MAX_CONCURRENT=__MAX_CONCURRENT__
MAX_BUDGET_USD=__MAX_BUDGET_USD__
MAX_TURNS=__MAX_TURNS__
ARCHIVE_URL=__WORKER_ARCHIVE_URL__
WORKER_VERSION=__WORKER_VERSION__
HTTP_PROXY_VALUE="${HTTP_PROXY:-${http_proxy:-}}"
HTTPS_PROXY_VALUE="${HTTPS_PROXY:-${https_proxy:-}}"
ALL_PROXY_VALUE="${ALL_PROXY:-${all_proxy:-}}"
NO_PROXY_VALUE="${NO_PROXY:-${no_proxy:-}}"
PLATFORM_HOST="$(printf '%s' "$PLATFORM_URL" | sed -E 's#^[[:alpha:]][[:alnum:]+.-]*://([^/:]+).*#\1#')"

log() {
  printf '[aima-worker-bootstrap] %s\n' "$1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

merge_path_value() {
  local current_value="$1"
  local entries=()
  local seen=","
  local item=""
  local defaults=("/opt/homebrew/bin" "/usr/local/bin" "/usr/bin" "/bin" "/usr/sbin" "/sbin")

  IFS=':' read -r -a entries <<< "$current_value"
  local merged=()
  for item in "${entries[@]}"; do
    [ -n "$item" ] || continue
    case "$seen" in
      *,"$item",*) ;;
      *)
        merged+=("$item")
        seen="$seen$item,"
        ;;
    esac
  done

  for item in "${defaults[@]}"; do
    case "$seen" in
      *,"$item",*) ;;
      *)
        merged+=("$item")
        seen="$seen$item,"
        ;;
    esac
  done

  local joined=""
  for item in "${merged[@]}"; do
    if [ -n "$joined" ]; then
      joined="$joined:$item"
    else
      joined="$item"
    fi
  done
  printf '%s' "$joined"
}

expand_home_path() {
  local path_value="$1"
  case "$path_value" in
    "~")
      printf '%s' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s' "$HOME" "${path_value#~/}"
      ;;
    *)
      printf '%s' "$path_value"
      ;;
  esac
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif has_cmd sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

merge_no_proxy_value() {
  local current_value="$1"
  local host_value="$2"
  [ -n "$host_value" ] || {
    printf '%s' "$current_value"
    return 0
  }

  local entries=()
  local seen=",$host_value,"
  if [ -n "$current_value" ]; then
    IFS=',' read -r -a entries <<< "$current_value"
    local merged=()
    local item trimmed
    for item in "${entries[@]}"; do
      trimmed="${item#"${item%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      [ -n "$trimmed" ] || continue
      case "$seen" in
        *,"$trimmed",*) ;;
        *)
          merged+=("$trimmed")
          seen="$seen$trimmed,"
          ;;
      esac
    done
    entries=("${merged[@]}")
  else
    entries=()
  fi
  entries+=("$host_value")
  local joined=""
  local item
  for item in "${entries[@]}"; do
    if [ -n "$joined" ]; then
      joined="$joined,$item"
    else
      joined="$item"
    fi
  done
  printf '%s' "$joined"
}

select_python() {
  if has_cmd python3.11; then
    printf 'python3.11'
    return 0
  fi
  if has_cmd python3; then
    printf 'python3'
    return 0
  fi
  if has_cmd python; then
    printf 'python'
    return 0
  fi
  return 1
}

python_is_supported() {
  local py_bin=$1
  "$py_bin" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}

ensure_python() {
  local py_bin
  py_bin="$(select_python || true)"
  if [ -n "$py_bin" ] && python_is_supported "$py_bin"; then
    return 0
  fi

  log "Installing Python 3.11+"
  if has_cmd brew; then
    brew install python@3.11
  elif has_cmd apt-get; then
    run_root apt-get update
    run_root apt-get install -y python3.11 python3.11-venv python3-pip
  elif has_cmd dnf; then
    run_root dnf install -y python3.11 python3-pip
  elif has_cmd yum; then
    run_root yum install -y python3 python3-pip
  else
    log "No supported package manager found for automatic Python installation."
    return 1
  fi

  py_bin="$(select_python || true)"
  if [ -z "$py_bin" ] || ! python_is_supported "$py_bin"; then
    log "Python 3.11+ is still unavailable after installation."
    return 1
  fi
}

ensure_node() {
  if has_cmd node && has_cmd npm; then
    return 0
  fi

  log "Installing Node.js"
  if has_cmd brew; then
    brew install node
  elif has_cmd apt-get; then
    run_root apt-get update
    run_root apt-get install -y nodejs npm
  elif has_cmd dnf; then
    run_root dnf install -y nodejs npm
  elif has_cmd yum; then
    run_root yum install -y nodejs npm
  else
    log "No supported package manager found for automatic Node.js installation."
    return 1
  fi

  if ! has_cmd node || ! has_cmd npm; then
    log "Node.js/npm is still unavailable after installation."
    return 1
  fi
}

ensure_claude() {
  if ! has_cmd claude; then
    log "claude CLI is not installed. Install and log into Claude Code first."
    return 1
  fi

  if ! claude auth status 2>/dev/null | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
    log "claude CLI is not logged in on this machine. Run 'claude auth login' first."
    return 1
  fi
}

ensure_codex() {
  if ! has_cmd codex; then
    log "Installing Codex CLI"
    npm install -g @openai/codex
  fi

  if ! has_cmd codex; then
    log "codex CLI is not installed. Install it manually or ensure npm global bin is in PATH."
    return 1
  fi

  if [ -n "$CODEX_HOME_DIR" ]; then
    CODEX_HOME_DIR="$(expand_home_path "$CODEX_HOME_DIR")"
    mkdir -p "$CODEX_HOME_DIR"
    export CODEX_HOME="$CODEX_HOME_DIR"
  fi

  if ! codex login status >/dev/null 2>&1; then
    log "codex CLI is not logged in for this worker. Seed CODEX_HOME/auth.json or run 'codex login' first."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Incremental update: skip download/install if cached version matches
# ---------------------------------------------------------------------------

needs_update() {
  local work_root="$1"
  local version_file="$work_root/.version"
  local mcp_server_path="$work_root/src/apps/mcp-server/dist/index.js"
  local venv_python="$work_root/venv/bin/python"

  # Must have all critical artifacts
  [ -f "$version_file" ] || return 0
  [ -f "$mcp_server_path" ] || return 0
  [ -x "$venv_python" ] || return 0

  # Use HTTP HEAD Content-Length as lightweight change indicator
  local remote_size local_size
  remote_size="$(curl -fsSI "$ARCHIVE_URL" 2>/dev/null | grep -i '^content-length' | tr -dc '0-9')" || return 0
  local_size="$(cat "$version_file" 2>/dev/null)" || return 0

  if [ -n "$remote_size" ] && [ "$remote_size" = "$local_size" ]; then
    return 1  # no update needed
  fi
  return 0
}

install_worker() {
  local work_root="$1"
  local py_bin="$2"
  local src_dir="$work_root/src"
  local archive_path="$work_root/aima-service-new.tar.gz"
  local venv_dir="$work_root/venv"

  rm -rf "$src_dir" "$venv_dir"

  log "Downloading worker bundle from $ARCHIVE_URL"
  curl -fsSL "$ARCHIVE_URL" -o "$archive_path"
  mkdir -p "$src_dir"
  tar -xzf "$archive_path" -C "$src_dir" --strip-components=1

  log "Creating Python virtualenv"
  "$py_bin" -m venv "$venv_dir"
  "$venv_dir/bin/python" -m pip install --upgrade pip setuptools wheel -q
  "$venv_dir/bin/python" -m pip install "$src_dir/apps/worker" -q

  log "Installing MCP server dependencies"
  (
    cd "$src_dir/apps/mcp-server"
    npm ci --silent
    npm run build --silent
  )

  # Save archive size for incremental update check (matches needs_update HEAD check)
  wc -c < "$archive_path" | tr -d ' ' > "$work_root/.version"
  rm -f "$archive_path"
}

# ---------------------------------------------------------------------------
# System service: register worker as OS service with auto-restart
# ---------------------------------------------------------------------------

install_service() {
  local work_root="$1"
  local venv_python="$2"
  shift 2
  local worker_args=("$@")

  local os_type
  os_type="$(uname -s)"

  case "$os_type" in
    Linux)
      install_systemd_service "$work_root" "$venv_python" "${worker_args[@]}"
      ;;
    Darwin)
      install_launchctl_service "$work_root" "$venv_python" "${worker_args[@]}"
      ;;
    *)
      log "No service manager support for $os_type; running in foreground"
      exec "$venv_python" "${worker_args[@]}"
      ;;
  esac
}

install_systemd_service() {
  local work_root="$1"
  local venv_python="$2"
  shift 2
  local worker_args=("$@")
  local user_name
  user_name="$(id -un)"
  local env_lines=""

  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"

  # Build ExecStart with proper quoting for paths with spaces
  local exec_line="\"$venv_python\""
  for arg in "${worker_args[@]}"; do
    exec_line="$exec_line \"$arg\""
  done

  append_systemd_env_line env_lines HTTP_PROXY "$HTTP_PROXY_VALUE"
  append_systemd_env_line env_lines http_proxy "$HTTP_PROXY_VALUE"
  append_systemd_env_line env_lines HTTPS_PROXY "$HTTPS_PROXY_VALUE"
  append_systemd_env_line env_lines https_proxy "$HTTPS_PROXY_VALUE"
  append_systemd_env_line env_lines ALL_PROXY "$ALL_PROXY_VALUE"
  append_systemd_env_line env_lines all_proxy "$ALL_PROXY_VALUE"
  append_systemd_env_line env_lines NO_PROXY "$NO_PROXY_VALUE"
  append_systemd_env_line env_lines no_proxy "$NO_PROXY_VALUE"
  append_systemd_env_line env_lines AIMA_WORKER_HOME "$work_root"
  append_systemd_env_line env_lines AIMA_WORKER_VERSION "$WORKER_VERSION"

  cat > "$unit_dir/aima-worker.service" << UNIT
[Unit]
Description=AIMA Worker
After=network-online.target

[Service]
ExecStart=$exec_line
Restart=on-failure
RestartSec=10
Environment=PATH=$PATH
$env_lines

[Install]
WantedBy=default.target
UNIT

  if has_cmd loginctl; then
    if run_root loginctl enable-linger "$user_name" >/dev/null 2>&1; then
      log "Enabled linger for $user_name so the worker survives logout"
    else
      log "Could not enable linger for $user_name; worker may stop when the user session ends"
    fi
  fi

  systemctl --user daemon-reload
  systemctl --user enable aima-worker 2>/dev/null || true
  systemctl --user restart aima-worker
  log "Installed and started systemd user service (aima-worker)"
  log "View logs: journalctl --user -u aima-worker -f"
}

install_launchctl_service() {
  local work_root="$1"
  local venv_python="$2"
  shift 2
  local worker_args=("$@")

  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_path="$plist_dir/com.aima.worker.plist"
  local log_dir="$HOME/.aima-worker/logs"
  mkdir -p "$plist_dir" "$log_dir"

  # Build ProgramArguments XML
  local program_args="    <string>$venv_python</string>"
  for arg in "${worker_args[@]}"; do
    program_args="$program_args
    <string>$arg</string>"
  done
  local env_dict=""
  local path_value
  path_value="$(merge_path_value "${PATH:-}")"
  append_plist_env_entry env_dict PATH "$path_value"
  append_plist_env_entry env_dict HTTP_PROXY "$HTTP_PROXY_VALUE"
  append_plist_env_entry env_dict http_proxy "$HTTP_PROXY_VALUE"
  append_plist_env_entry env_dict HTTPS_PROXY "$HTTPS_PROXY_VALUE"
  append_plist_env_entry env_dict https_proxy "$HTTPS_PROXY_VALUE"
  append_plist_env_entry env_dict ALL_PROXY "$ALL_PROXY_VALUE"
  append_plist_env_entry env_dict all_proxy "$ALL_PROXY_VALUE"
  append_plist_env_entry env_dict NO_PROXY "$NO_PROXY_VALUE"
  append_plist_env_entry env_dict no_proxy "$NO_PROXY_VALUE"
  append_plist_env_entry env_dict AIMA_WORKER_HOME "$work_root"
  append_plist_env_entry env_dict AIMA_WORKER_VERSION "$WORKER_VERSION"

  cat > "$plist_path" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.aima.worker</string>
  <key>ProgramArguments</key>
  <array>
$program_args
  </array>
  <key>EnvironmentVariables</key>
  <dict>
$env_dict
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/worker-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/worker-stderr.log</string>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
PLIST

  launchctl bootout "gui/$(id -u)" "$plist_path" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist_path"
  log "Installed and started LaunchAgent (com.aima.worker)"
  log "View logs: tail -f $log_dir/worker-stdout.log"
}

append_systemd_env_line() {
  local __target_var="$1"
  local env_name="$2"
  local env_value="$3"
  [ -n "$env_value" ] || return 0
  printf -v "$__target_var" '%sEnvironment="%s=%s"\n' "${!__target_var}" "$env_name" "$env_value"
}

append_plist_env_entry() {
  local __target_var="$1"
  local env_name="$2"
  local env_value="$3"
  [ -n "$env_value" ] || return 0
  printf -v "$__target_var" '%s    <key>%s</key>\n    <string>%s</string>\n' "${!__target_var}" "$env_name" "$env_value"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  NO_PROXY_VALUE="$(merge_no_proxy_value "$NO_PROXY_VALUE" "$PLATFORM_HOST")"
  ensure_node
  if [ "$RUNTIME" = "codex" ]; then
    ensure_codex
  else
    ensure_claude
  fi
  if [ -n "$HTTP_PROXY_VALUE" ]; then
    export HTTP_PROXY="$HTTP_PROXY_VALUE" http_proxy="$HTTP_PROXY_VALUE"
  fi
  if [ -n "$HTTPS_PROXY_VALUE" ]; then
    export HTTPS_PROXY="$HTTPS_PROXY_VALUE" https_proxy="$HTTPS_PROXY_VALUE"
  fi
  if [ -n "$ALL_PROXY_VALUE" ]; then
    export ALL_PROXY="$ALL_PROXY_VALUE" all_proxy="$ALL_PROXY_VALUE"
  fi
  if [ -n "$NO_PROXY_VALUE" ]; then
    export NO_PROXY="$NO_PROXY_VALUE" no_proxy="$NO_PROXY_VALUE"
  fi
  ensure_python

  local py_bin
  py_bin="$(select_python)"

  local work_root src_dir venv_dir mcp_server_path
  work_root="${AIMA_WORKER_HOME:-$HOME/.aima-worker}"
  src_dir="$work_root/src"
  venv_dir="$work_root/venv"
  mcp_server_path="$src_dir/apps/mcp-server/dist/index.js"

  mkdir -p "$work_root"

  # Incremental update: only reinstall if version changed
  if needs_update "$work_root"; then
    install_worker "$work_root" "$py_bin"
  else
    log "Cached installation is up to date, skipping download"
  fi

  if [ ! -f "$mcp_server_path" ]; then
    log "Expected MCP server build artifact missing: $mcp_server_path"
    return 1
  fi

  local worker_args=(
    -m aima_worker.main
    --platform-url "$PLATFORM_URL"
    --runtime "$RUNTIME"
    --mcp-server-path "$mcp_server_path"
    --bootstrap-code "$WORKER_BOOTSTRAP_CODE"
    --max-concurrent "$MAX_CONCURRENT"
    --max-budget-usd "$MAX_BUDGET_USD"
    --max-turns "$MAX_TURNS"
    --workspace-base-dir "$work_root/workspaces"
  )
  if [ -n "$WORKER_NAME" ]; then
    worker_args+=(--name "$WORKER_NAME")
  fi
  if [ -n "$CLAUDE_MODEL" ]; then
    worker_args+=(--claude-model "$CLAUDE_MODEL")
  fi
  if [ -n "$CLAUDE_EFFORT" ]; then
    worker_args+=(--claude-effort "$CLAUDE_EFFORT")
  fi
  if [ "$RUNTIME" = "codex" ]; then
    if [ -n "$CODEX_HOME_DIR" ]; then
      worker_args+=(--codex-home-dir "$CODEX_HOME_DIR")
    fi
    if [ -n "$CODEX_MODEL" ]; then
      worker_args+=(--codex-model "$CODEX_MODEL")
    fi
    if [ -n "$CODEX_MODEL_REASONING_EFFORT" ]; then
      worker_args+=(--codex-model-reasoning-effort "$CODEX_MODEL_REASONING_EFFORT")
    fi
    if [ -n "$CODEX_SANDBOX_MODE" ]; then
      worker_args+=(--codex-sandbox-mode "$CODEX_SANDBOX_MODE")
    fi
    if [ -n "$CODEX_APPROVAL_POLICY" ]; then
      worker_args+=(--codex-approval-policy "$CODEX_APPROVAL_POLICY")
    fi
  fi

  log "Starting AIMA worker against $PLATFORM_URL"
  install_service "$work_root" "$venv_dir/bin/python" "${worker_args[@]}"
}

main "$@"
