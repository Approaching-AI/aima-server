# Architecture

## Overview

AIMA is an **Agentic EdgeOps** platform: AI agents execute operations on remote devices autonomously, with human oversight.

```
┌─────────────────────────────────────────────────────────────────┐
│                        User's Device                            │
│                                                                 │
│  ┌──────────┐    ┌──────────┐    ┌──────────────┐              │
│  │ aima CLI │───▶│ Worker   │───▶│ MCP Server   │              │
│  │ (Python) │    │ (Python) │    │ (TypeScript)  │              │
│  └────┬─────┘    └────┬─────┘    └──────┬───────┘              │
│       │               │                 │                       │
│       │          Spawns Claude     Exposes tools                │
│       │          Code / Codex      (shell exec,                │
│       │          sessions          ask human, etc.)             │
└───────┼───────────────┼─────────────────┼───────────────────────┘
        │               │                 │
        │ HTTP          │ HTTP            │ HTTP
        │ (register,    │ (heartbeat,     │ (commands,
        │  poll, result)│  events)        │  interactions)
        ▼               ▼                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AIMA Cloud Platform                        │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Device API   │  │ Task Engine  │  │ Experience System    │  │
│  │ Registration │  │ Dispatch     │  │ 4-level search       │  │
│  │ Polling      │  │ State machine│  │ SOP auto-generation  │  │
│  │ Auth/Token   │  │ Verification │  │ Knowledge base       │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Safety       │  │ Admin API    │  │ Dashboard            │  │
│  │ Action class.│  │ Stats        │  │ Device console       │  │
│  │ Approval     │  │ Worker mgmt  │  │ Experience CRUD      │  │
│  │ Audit log    │  │ Federation   │  │ Marketing site       │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│                                                                 │
│  PostgreSQL 17          Valkey 8 (Redis-compat)                 │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### Device-side (this repo)

| Component | Language | Role | Dependencies |
|-----------|----------|------|-------------|
| **CLI** (`cli/`) | Python 3.9+ | Device registration, user interaction, command execution | `httpx` only |
| **Worker** | Python 3.11+ | Agent task executor, session management | `httpx` — *Phase 3* |
| **MCP Server** | TypeScript 5.4+ | Tool interface for AI agents (shell, ask human, etc.) | `@modelcontextprotocol/sdk` — *Phase 2* |

### Cloud-side (managed service)

| Component | Role |
|-----------|------|
| **Platform API** | FastAPI-based control plane: device auth, task dispatch, experience management |
| **Task Engine** | State machine: created → assigned → executing → verifying → completed/failed |
| **Experience System** | Learns from every task; 4-level search (exact → partial → keyword → generic SOP) |
| **Safety Module** | Action classification (low/medium/high risk), command whitelist, approval routing |
| **Audit System** | Immutable log of all agent actions for compliance and debugging |

## Communication model

All device ↔ platform communication uses **HTTP + JSON**:

- **Registration:** `POST /api/v1/devices/self-register` with device fingerprint
- **Task polling:** `GET /api/v1/devices/{id}/poll` (long-poll, configurable interval)
- **Command results:** `POST /api/v1/devices/{id}/result`
- **Interactions:** Agent questions routed to device terminal or admin dashboard

Authentication uses **Bearer tokens** issued at registration time. Tokens are renewable and recoverable via hardware fingerprint.

No proprietary protocols, no persistent connections required. Works behind firewalls and NAT — the device always initiates outbound HTTP requests.

## Device lifecycle

```
1. Bootstrap
   curl .../go | bash
   → Script detects OS, registers device, gets token

2. Idle
   Device polls platform for tasks
   → GET /api/v1/devices/{id}/poll (long-poll)

3. Task execution
   Platform assigns task → AI agent plans and executes
   → Commands sent to device, results reported back

4. Verification
   Agent verifies outcomes (exit codes, file checks, service status)
   → Success: experience recorded for future reference
   → Failure: rollback or escalation to human

5. Experience sediment
   Successful patterns become institutional knowledge
   → Similar future problems solve faster and cheaper
```

## Security model

- **Device auth:** Bearer token, hardware-fingerprinted, 0600 file permissions
- **Action classification:** Every command classified as low/medium/high risk
- **Approval routing:** High-risk actions require human approval before execution
- **Command isolation:** Each command runs in its own directory with captured stdout/stderr
- **Audit trail:** Every action logged with timestamp, classification, and outcome
