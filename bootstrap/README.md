# Bootstrap Scripts

These are **template files** rendered by the AIMA platform server at request time. They are not meant to be executed directly.

## How it works

When a user runs:

```bash
# Linux / macOS
curl -sL https://aimaservice.ai/go | bash

# Windows (PowerShell)
iex (irm https://aimaservice.ai/go)
```

The platform's `/go` endpoint detects the User-Agent (curl vs PowerShell vs browser) and renders the appropriate template with environment-specific values injected.

## Template variables

The following placeholders are replaced at render time:

| Variable | Description | Example |
|----------|-------------|---------|
| `__BASE_URL__` | Platform API base URL | `https://aimaservice.ai/api/v1` |
| `__REFERRAL_CODE__` | Tracking code from share links | `ref_abc123` |
| `__WORKER_CODE__` | Worker enrollment code | `wk_xyz789` |
| `__POLL_INTERVAL_SECONDS__` | Device poll interval | `5` |
| `__UX_MANIFEST_JSON__` | Full bilingual UI manifest (prompts, menus, messages) | `{...}` |
| `__UTM_SOURCE__` | Analytics: traffic source | `github` |
| `__UTM_MEDIUM__` | Analytics: traffic medium | `readme` |
| `__UTM_CAMPAIGN__` | Analytics: campaign name | `launch` |

## Files

| File | Purpose |
|------|---------|
| `go.sh.tpl` | Main Linux/macOS device bootstrap (registration, polling, command execution) |
| `go.ps1.tpl` | Main Windows device bootstrap |
| `bootstrap.sh.tpl` | Legacy activation-code based bootstrap (admin-controlled flow) |
| `bootstrap.ps1.tpl` | Legacy activation-code based bootstrap (Windows) |
| `worker-bootstrap.sh.tpl` | Worker provisioning (downloads repo, installs runtime) |
| `worker-bootstrap.ps1.tpl` | Worker provisioning (Windows) |
| `doctor.sh.tpl` | Diagnostic and skill helper |
| `doctor.ps1.tpl` | Diagnostic and skill helper (Windows) |

## Why are these open-sourced?

Transparency. These scripts run on user machines and we want you to be able to audit exactly what they do before executing them. The scripts:

- Register the device with the platform via HTTP
- Poll for tasks and execute commands locally
- Report results back to the platform
- Store device state at `~/.aima-cli/` (or `~/.aima-device-state` for bootstrap mode)

No data is collected beyond what's needed for device operations.
