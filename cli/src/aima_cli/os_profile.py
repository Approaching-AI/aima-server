from __future__ import annotations

import hashlib
import os
import platform
import shutil
import socket
import subprocess
import uuid
from pathlib import Path


def _run_text(command: list[str]) -> str:
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            check=False,
            text=True,
        )
    except Exception:
        return ""
    if completed.returncode != 0:
        return ""
    return completed.stdout.strip()


def platform_os_name() -> str:
    return os.name


def current_os_type() -> str:
    system_name = platform.system()
    if system_name == "Windows":
        return "Win32NT"
    if system_name == "Darwin":
        return "Darwin"
    return "Linux"


def current_shell() -> str:
    return "powershell" if platform_os_name() == "nt" else "bash"


def detect_package_managers() -> list[str]:
    if platform_os_name() == "nt":
        names = ["winget", "choco", "pip"]
    elif current_os_type() == "Darwin":
        names = ["brew", "pip"]
    else:
        names = ["apt", "dnf", "yum", "pip"]
    return [name for name in names if shutil.which(name)]


def _read_text_file(path: str) -> str:
    file_path = Path(path)
    if not file_path.exists():
        return ""
    try:
        return file_path.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def _invalid_hardware_signal(value: str) -> bool:
    normalized = value.strip()
    if not normalized:
        return True
    lowered = normalized.lower()
    return lowered in {"not specified", "default string", "unknown", "none", "null"}


def _collect_linux_sorted_macs(*, only_physical: bool) -> str:
    sys_class_net = Path("/sys/class/net")
    if not sys_class_net.exists():
        return ""

    macs: set[str] = set()
    for iface_dir in sys_class_net.iterdir():
        addr_path = iface_dir / "address"
        if iface_dir.name == "lo" or not addr_path.exists():
            continue
        if only_physical and not (iface_dir / "device").exists():
            continue
        try:
            mac = addr_path.read_text(encoding="utf-8").strip().lower()
        except Exception:
            continue
        if mac and mac != "00:00:00:00:00:00":
            macs.add(mac)
    return ",".join(sorted(macs))


def detect_linux_stable_hardware_signal() -> str:
    for candidate in (
        "/sys/class/dmi/id/product_uuid",
        "/sys/class/dmi/id/product_serial",
        "/sys/class/dmi/id/board_serial",
    ):
        value = _read_text_file(candidate)
        if not _invalid_hardware_signal(value):
            return value

    macs = _collect_linux_sorted_macs(only_physical=True)
    if not _invalid_hardware_signal(macs):
        return macs
    return ""


def detect_machine_id() -> str:
    if platform_os_name() == "nt":
        try:
            import winreg

            with winreg.OpenKey(
                winreg.HKEY_LOCAL_MACHINE,
                r"SOFTWARE\Microsoft\Cryptography",
            ) as key:
                value, _ = winreg.QueryValueEx(key, "MachineGuid")
                if isinstance(value, str) and value.strip():
                    return value.strip()
        except Exception:
            pass

    if current_os_type() == "Darwin":
        text = _run_text(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"])
        for line in text.splitlines():
            if "IOPlatformUUID" in line:
                parts = line.split("=", 1)
                if len(parts) == 2:
                    return parts[1].strip().strip('"')

    for candidate in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        path = Path(candidate)
        if path.exists():
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return value

    return f"{socket.gethostname()}|{uuid.getnode():x}"


def detect_hardware_id(machine_id: str) -> str:
    return hashlib.sha256(machine_id.encode("utf-8")).hexdigest()


def detect_hardware_identity(os_type: str, machine_id: str) -> dict:
    if os_type == "Linux":
        hardware_id_candidates: list[str] = []
        stable_signal = detect_linux_stable_hardware_signal()
        hardware_id = detect_hardware_id(stable_signal) if stable_signal else ""
        if hardware_id:
            hardware_id_candidates.append(hardware_id)
        legacy_hardware_id = detect_hardware_id(machine_id) if machine_id else ""
        if legacy_hardware_id and legacy_hardware_id not in hardware_id_candidates:
            hardware_id_candidates.append(legacy_hardware_id)
        return {
            "hardware_id": hardware_id,
            "hardware_id_candidates": hardware_id_candidates,
        }

    hardware_id = detect_hardware_id(machine_id)
    return {
        "hardware_id": hardware_id,
        "hardware_id_candidates": [hardware_id] if hardware_id else [],
    }


def build_os_profile() -> dict:
    os_type = current_os_type()
    machine_id = detect_machine_id()
    hardware_identity = detect_hardware_identity(os_type, machine_id)
    return {
        "os_type": os_type,
        "os_version": platform.platform(),
        "arch": platform.machine() or "unknown",
        "hostname": socket.gethostname(),
        "machine_id": machine_id,
        "hardware_id": hardware_identity["hardware_id"],
        "hardware_id_candidates": hardware_identity["hardware_id_candidates"],
        "package_managers": detect_package_managers(),
        "shell": current_shell(),
    }


def build_fingerprint(os_profile: dict) -> str:
    return "|".join(
        [
            str(os_profile.get("os_type") or ""),
            str(os_profile.get("os_version") or ""),
            str(os_profile.get("arch") or ""),
            str(os_profile.get("hostname") or ""),
            str(os_profile.get("machine_id") or ""),
        ]
    )
