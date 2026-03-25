from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional


@dataclass
class DeviceState:
    platform_url: str
    device_id: str
    token: str
    recovery_code: str
    referral_code: str = ""
    share_text: str = ""
    poll_interval_seconds: int = 5
    display_language: str = ""
    last_notified_task_id: str = ""


def default_state_path() -> Path:
    return Path.home() / ".aima-cli" / "device-state.json"


class DeviceStateStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or default_state_path()

    def load(self) -> Optional[DeviceState]:
        if not self.path.exists():
            return None
        payload = json.loads(self.path.read_text(encoding="utf-8"))
        return DeviceState(**payload)

    def save(self, state: DeviceState) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(asdict(state), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        if os.name != "nt":
            os.chmod(self.path, 0o600)

    def clear(self) -> None:
        if self.path.exists():
            self.path.unlink()
