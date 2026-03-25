from __future__ import annotations

from pathlib import Path

import pytest

import aima_cli.os_profile as os_profile
import aima_cli.runtime as runtime


@pytest.mark.parametrize(
    ("os_name", "system_name", "expected_os_type", "expected_shell"),
    [
        ("posix", "Linux", "Linux", "bash"),
        ("posix", "Darwin", "Darwin", "bash"),
        ("nt", "Windows", "Win32NT", "powershell"),
    ],
)
def test_build_os_profile_supports_linux_windows_and_macos(
    monkeypatch: pytest.MonkeyPatch,
    os_name: str,
    system_name: str,
    expected_os_type: str,
    expected_shell: str,
) -> None:
    monkeypatch.setattr(os_profile, "platform_os_name", lambda: os_name)
    monkeypatch.setattr(os_profile.platform, "system", lambda: system_name)
    monkeypatch.setattr(os_profile.platform, "platform", lambda: f"{system_name}-unit-test")
    monkeypatch.setattr(os_profile.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(os_profile.socket, "gethostname", lambda: "device-host")
    monkeypatch.setattr(os_profile, "detect_machine_id", lambda: f"{system_name.lower()}-machine-id")
    monkeypatch.setattr(
        os_profile,
        "detect_hardware_identity",
        lambda os_type, machine_id: {
            "hardware_id": f"{os_type.lower()}-hardware-id",
            "hardware_id_candidates": [f"{machine_id}-candidate"],
        },
    )
    monkeypatch.setattr(os_profile, "detect_package_managers", lambda: ["pm-a", "pm-b"])

    profile = os_profile.build_os_profile()

    assert profile["os_type"] == expected_os_type
    assert profile["os_version"] == f"{system_name}-unit-test"
    assert profile["arch"] == "x86_64"
    assert profile["hostname"] == "device-host"
    assert profile["machine_id"] == f"{system_name.lower()}-machine-id"
    assert profile["shell"] == expected_shell
    assert profile["package_managers"] == ["pm-a", "pm-b"]
    assert profile["hardware_id"] == f"{expected_os_type.lower()}-hardware-id"
    assert profile["hardware_id_candidates"] == [f"{system_name.lower()}-machine-id-candidate"]
    assert os_profile.build_fingerprint(profile) == (
        f"{expected_os_type}|{system_name}-unit-test|x86_64|device-host|{system_name.lower()}-machine-id"
    )


def test_linux_identity_uses_stable_hardware_id_and_keeps_legacy_machine_id_candidate(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(os_profile, "detect_linux_stable_hardware_signal", lambda: "dmi-uuid-001")

    identity = os_profile.detect_hardware_identity("Linux", "linux-machine-id")

    assert identity["hardware_id"] == os_profile.detect_hardware_id("dmi-uuid-001")
    assert identity["hardware_id_candidates"] == [
        os_profile.detect_hardware_id("dmi-uuid-001"),
        os_profile.detect_hardware_id("linux-machine-id"),
    ]


def test_command_runner_uses_platform_specific_shell(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(runtime, "platform_os_name", lambda: "posix")
    monkeypatch.setattr(runtime.shutil, "which", lambda name: "/custom/bash" if name == "bash" else None)
    assert runtime._command_runner(Path("/tmp/test.sh")) == ["/custom/bash", "/tmp/test.sh"]

    monkeypatch.setattr(runtime, "platform_os_name", lambda: "nt")
    monkeypatch.setattr(runtime.shutil, "which", lambda name: None)
    assert runtime._command_runner(Path("C:/Temp/test.ps1")) == [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "C:/Temp/test.ps1",
    ]
