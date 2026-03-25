from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

from .api import DeviceApiClient
from .owner_backed import BackgroundOwner, OwnerBackedAttachedRunner
from .owner_runtime import CliOwnerProcessManager, CliRuntimeStore, default_runtime_root
from .renderer import TerminalRenderer
from .session import AttachedDeviceSession, ConsoleInputProvider, ScriptedInputProvider, build_options_from_args
from .state import DeviceStateStore, default_state_path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="aima", description="AIMA cross-platform device CLI")
    subparsers = parser.add_subparsers(dest="command")

    device_parser = subparsers.add_parser("device", help="Run the device-side CLI")
    device_subparsers = device_parser.add_subparsers(dest="device_command")

    run_parser = device_subparsers.add_parser("run", help="Run the attached device client")
    run_parser.add_argument("--platform-url", required=True, help="Platform base URL, for example http://127.0.0.1:8000")
    run_parser.add_argument("--invite-code", default="", help="Invite code used for new self-registration")
    run_parser.add_argument("--referral-code", default="", help="Referral code inherited from a share link")
    run_parser.add_argument("--worker-code", default="", help="Worker enrollment code for worker onboarding")
    run_parser.add_argument("--state-file", default=str(default_state_path()), help="State file path")
    run_parser.add_argument("--wait-seconds", type=int, default=5, help="Default poll wait seconds")
    run_parser.add_argument("--runtime-dir", default="", help=argparse.SUPPRESS)
    run_parser.add_argument("--owner", action="store_true", help=argparse.SUPPRESS)
    run_parser.add_argument("--owner-bootstrap-mode", default="restore", help=argparse.SUPPRESS)

    return parser


async def _run_device_client(args: argparse.Namespace) -> int:
    options = build_options_from_args(args)
    state_path = Path(options.state_file)
    state_store = DeviceStateStore(state_path)
    runtime = CliRuntimeStore(Path(args.runtime_dir) if args.runtime_dir else default_runtime_root(state_path))
    async with DeviceApiClient(platform_url=options.platform_url) as api:
        session = AttachedDeviceSession(
            api=api,
            options=options,
            input_provider=ScriptedInputProvider([]) if args.owner else ConsoleInputProvider(),
            renderer=TerminalRenderer(),
            state_store=state_store,
        )
        if args.owner:
            owner = BackgroundOwner(
                session=session,
                runtime=runtime,
                bootstrap_mode=str(args.owner_bootstrap_mode or "restore"),
            )
            return await owner.run()
        owner_manager = CliOwnerProcessManager(
            runtime=runtime,
            platform_url=options.platform_url,
            state_file=state_path,
            wait_seconds=options.wait_seconds,
        )
        runner = OwnerBackedAttachedRunner(
            session=session,
            runtime=runtime,
            owner_manager=owner_manager,
        )
        return await runner.run()


def cli_main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "device" and args.device_command == "run":
        try:
            return asyncio.run(_run_device_client(args))
        except KeyboardInterrupt:
            return 0

    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(cli_main())
