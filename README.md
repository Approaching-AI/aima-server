# AIMA Server

**AI-powered autonomous device operations platform.**

AIMA enables AI agents to remotely diagnose, install, repair, and upgrade software on your devices through a simple text-based channel. Connect any PC or laptop with a single command — an AI agent handles the rest.

## How it works

```
Your Device                          AIMA Cloud
┌────────────────┐                  ┌─────────────────────┐
│ aima CLI       │───── HTTP ──────▶│ Platform API        │
│ (Python, httpx)│◀──── JSON ──────│ Task dispatch       │
│                │                  │ Experience system   │
│ Executes       │                  │ Safety & audit      │
│ commands       │                  │ AI agent orchestr.  │
│ locally        │                  └─────────────────────┘
└────────────────┘
```

1. **Bootstrap** — Run a single command to register your device
2. **Describe** — Tell the platform what you need (install software, fix an error, etc.)
3. **AI executes** — An AI agent analyzes, plans, and executes operations on your device
4. **Verify** — Results are automatically verified; rollback if needed

## Quick start

### Option A: One-line bootstrap (connects to AIMA cloud)

```bash
# Linux / macOS
curl -sL https://aimaservice.ai/go | bash

# Windows (PowerShell)
iex (irm https://aimaservice.ai/go)

# China region
curl -sL https://aimaserver.com/go | bash
```

### Option B: Install the CLI directly

```bash
pip install aima-cli

# Connect to AIMA cloud
aima device run --platform-url https://aimaservice.ai --invite-code <your-code>

# Or connect to a self-hosted platform
aima device run --platform-url http://your-server:8000 --invite-code <code>
```

## What's in this repo

This repo contains the **device-side** components of AIMA — everything that runs on your machine. The cloud platform is a managed service.

```
aima-server/
├── cli/                    # Device CLI (Python)
│   ├── src/aima_cli/       # Source code
│   ├── tests/              # Tests
│   └── pyproject.toml      # Package config (pip install -e cli/)
├── bootstrap/              # Bootstrap script templates
│   └── README.md           # How bootstrap works
├── docs/
│   ├── architecture.md     # System architecture
│   └── api-contract.md     # Device ↔ Platform API reference
└── LICENSE                 # Apache 2.0
```

### CLI features

- **Cross-platform** — Windows 10/11, macOS, Ubuntu 22.04/24.04
- **Minimal dependencies** — Only requires `httpx` (async HTTP client)
- **Python 3.9+** — Works with any modern Python
- **Secure** — Bearer token auth, device state stored with 0600 permissions
- **Bilingual** — Chinese and English UI
- **Resilient** — Device recovery via hardware fingerprint, background session management

## Supported platforms

| OS | Version | Architecture |
|----|---------|-------------|
| Windows | 10, 11 | x86_64 |
| macOS | 12+ | x86_64, arm64 |
| Ubuntu | 22.04, 24.04 | x86_64, arm64 |

## Development

```bash
# Clone
git clone https://github.com/Approaching-AI/aima-server.git
cd aima-server

# Install CLI in dev mode
cd cli
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"

# Run tests
pytest
```

## Open-source roadmap

This repo follows a **gradual open-source strategy**:

| Phase | Component | Status |
|-------|-----------|--------|
| 1 | Device CLI + Bootstrap scripts | Current |
| 2 | MCP Server (AI agent tool interface) | Planned |
| 3 | Worker (local agent executor) | Planned |
| 4 | Simplified self-hosted platform | Under consideration |

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full system architecture.

See [docs/api-contract.md](docs/api-contract.md) for the device ↔ platform API reference.

## License

[Apache License 2.0](LICENSE)

## Links

- **AIMA Cloud (Global):** https://aimaservice.ai
- **AIMA Cloud (China):** https://aimaserver.com
- **Organization:** https://github.com/Approaching-AI
