# Device ↔ Platform API Contract

All endpoints are relative to the platform base URL (e.g., `https://aimaservice.ai`).

Authentication: `Authorization: Bearer <device_token>` header (unless noted otherwise).

## Bootstrap & Registration

### `GET /api/v1/ux-manifests/device-go`

Fetch the UX manifest (bilingual prompts, menu options, messages).

**Auth:** None required.

**Query params:**
| Param | Description |
|-------|-------------|
| `schema_version` | Manifest schema version (default: `v1`) |
| `ref` | Referral code from share links |
| `worker_code` | Worker enrollment code |

**Response:** JSON manifest with localized UI strings.

---

### `POST /api/v1/devices/self-register`

Register a new device or recover an existing one.

**Auth:** None required.

**Request body:**
```json
{
  "fingerprint": "Darwin|14.2|arm64|hostname|uuid",
  "hardware_id": "sha256-of-stable-signal",
  "hardware_id_candidates": ["candidate1", "candidate2"],
  "os_profile": {
    "os_type": "Darwin",
    "os_version": "macOS 14.2",
    "arch": "arm64",
    "hostname": "my-mac",
    "machine_id": "uuid",
    "package_managers": ["brew", "pip"],
    "shell": "bash"
  },
  "invite_code": "optional",
  "referral_code": "optional",
  "recovery_code": "optional",
  "worker_enrollment_code": "optional",
  "display_language": "en_us"
}
```

**Response:**
```json
{
  "device_id": "dev_xxx",
  "token": "dev_token_xxx",
  "recovery_code": "rc_xxx",
  "referral_code": "ref_xxx",
  "share_text": "Share this link...",
  "poll_interval_seconds": 5,
  "display_language": "en_us"
}
```

**Error cases:**
- `409` with `reauth_method: "browser_confirmation"` — device exists, needs browser recovery flow
- `403` with `reauth_method: "recovery_code"` and `recovery_code_status: "missing" | "invalid"` — device exists, recovery code is required or the saved one was rejected

---

## Device Flow (Browser Recovery)

### `GET /api/v1/device-flows/{device_code}/poll`

Poll for browser confirmation during device recovery.

**Auth:** None required.

**Response:** Returns new device credentials once the user confirms in browser.

---

## Task Management

### `GET /api/v1/devices/{device_id}/active-task`

Check if there's an active task on this device.

**Response:** Task details or `404` if no active task.

---

### `POST /api/v1/devices/{device_id}/tasks`

Create a new task (user describes what they need).

**Request body:**
```json
{
  "description": "Install OpenClaw on this machine",
  "intake": {
    "user_request": "Install OpenClaw",
    "renderer": "cli",
    "mode": "install",
    "software_hint": "openclaw"
  },
  "experience_search": {
    "task_type_hint": "software_install",
    "target_hint": "openclaw"
  }
}
```

---

### `POST /api/v1/devices/{device_id}/tasks/{task_id}/cancel`

Cancel an active task.

---

## Polling & Command Execution

### `GET /api/v1/devices/{device_id}/poll?wait={seconds}`

Long-poll for pending commands or interactions.

**Query params:**
| Param | Description |
|-------|-------------|
| `wait` | Max seconds to wait (default: 5) |

**Response:** Next pending command, interaction, or `204 No Content`.

---

### `POST /api/v1/devices/{device_id}/result`

Submit command execution result.

**Request body:**
```json
{
  "command_id": "cmd_xxx",
  "exit_code": 0,
  "stdout": "command output...",
  "stderr": "",
  "result_id": "res_xxx"
}
```

---

### `POST /api/v1/devices/{device_id}/commands/{command_id}/progress`

Report progress during long-running command execution.

**Request body:**
```json
{
  "stdout": "last 4KB of stdout...",
  "stderr": "last 4KB of stderr...",
  "message": "Installing dependencies (47%)..."
}
```

---

## Interactions

### `POST /api/v1/devices/{device_id}/interactions/{interaction_id}/respond`

Respond to an agent's question.

**Request body:**
```json
{
  "answer": "Yes, proceed with the installation"
}
```

---

## Feedback

### `POST /api/v1/devices/{device_id}/feedback`

Submit user feedback (bug report or suggestion).

**Request body:**
```json
{
  "type": "bug_report",
  "description": "The install failed at step 3",
  "environment": { "os_type": "Darwin", "...": "..." },
  "context": {
    "script_version": "aima-cli/0.1.0",
    "task_id": "optional_task_id"
  }
}
```

---

## Device Lifecycle

### `POST /api/v1/devices/{device_id}/offline`

Mark device as offline (graceful disconnect).

---

### `POST /api/v1/devices/{device_id}/language`

Update display language preference.

**Request body:**
```json
{
  "display_language": "zh_cn"
}
```

Supported values: `zh_cn`, `en_us`.

---

## Notes

- All responses use JSON (`application/json`)
- Error responses include `{"detail": "error message"}` with appropriate HTTP status codes
- Long-poll endpoints return `204 No Content` when no updates are available
- Token renewal is handled automatically by the CLI
- Command output is truncated to 128KB in result submissions
