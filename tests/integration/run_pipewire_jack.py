#!/usr/bin/env python3
"""Run live backend tests against a disposable isolated PipeWire-JACK core."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

REQUIRED_COMMANDS = (
    "pipewire", "pw-jack", "pw-cli", "pw-dump", "pkg-config", "cc",
    "readelf",
)
STARTUP_TIMEOUT = 5.0
TEST_TIMEOUT = 90.0
TEARDOWN_TIMEOUT = 3.0

PROPERTIES = """{
  module.rt = false
  module.portal = false
  module.x11.bell = false
  module.jackdbus-detect = false
  module.client-device = false
  module.session-manager = false
  default.clock.rate = 48000
  default.clock.allowed-rates = [ 48000 ]
  default.clock.quantum = 64
  default.clock.min-quantum = 64
  default.clock.max-quantum = 64
}"""

SANITIZED_VARIABLES = (
    "PIPEWIRE_CONFIG_DIR", "PIPEWIRE_CONFIG_PREFIX", "PIPEWIRE_CONFIG_NAME",
    "PIPEWIRE_NO_CONFIG", "PIPEWIRE_LATENCY", "PIPEWIRE_QUANTUM",
    "JACK_PROMISCUOUS_SERVER", "JACK_NO_AUDIO_RESERVATION",
    "DBUS_SESSION_BUS_ADDRESS", "PULSE_SERVER",
)


def command_output(command: list[str]) -> str:
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()


def pipewire_config() -> Path:
    datadir = command_output([
        "pkg-config", "--variable=datadir", "libpipewire-0.3",
    ])
    if not datadir:
        prefix = command_output([
            "pkg-config", "--variable=prefix", "libpipewire-0.3",
        ])
        datadir = str(Path(prefix) / "share")
    return Path(datadir) / "pipewire" / "pipewire.conf"


def prerequisite_failures() -> tuple[list[str], Path | None]:
    failures: list[str] = []
    for command in REQUIRED_COMMANDS:
        if shutil.which(command) is None:
            failures.append(f"missing required command: {command}")

    config: Path | None = None
    if shutil.which("pkg-config") is not None:
        checked = subprocess.run(
            ["pkg-config", "--exists", "jack", "libpipewire-0.3"],
            check=False,
        )
        if checked.returncode != 0:
            failures.append("pkg-config could not resolve jack and libpipewire-0.3")
        else:
            try:
                config = pipewire_config()
                if not config.is_file():
                    failures.append(f"installed PipeWire config is missing: {config}")
            except (OSError, subprocess.CalledProcessError) as error:
                failures.append(f"could not locate installed PipeWire config: {error}")

    if shutil.which("cc") is not None and shutil.which("pkg-config") is not None:
        try:
            cflags = command_output(["pkg-config", "--cflags", "jack"]).split()
            libraries = command_output(["pkg-config", "--libs", "jack"]).split()
            with tempfile.TemporaryDirectory(prefix="pluginhost-jack-probe-") as root:
                output = Path(root) / "probe"
                compiled = subprocess.run(
                    ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                     *cflags, "-x", "c", "-", "-o", str(output), *libraries],
                    input="#include <jack/jack.h>\nint main(void) { return 0; }\n",
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
                if compiled.returncode != 0:
                    failures.append(
                        "JACK header/library compile probe failed:\n" + compiled.stdout
                    )
        except (OSError, subprocess.CalledProcessError) as error:
            failures.append(f"could not run JACK compile probe: {error}")

    return failures, config


def private_environment(root: Path, remote: str) -> dict[str, str]:
    environment = os.environ.copy()
    for variable in SANITIZED_VARIABLES:
        environment.pop(variable, None)
    runtime = root / "runtime"
    home = root / "home"
    config_home = root / "config"
    for directory in (runtime, home, config_home):
        directory.mkdir(mode=0o700)
        directory.chmod(0o700)
    environment.update({
        "PIPEWIRE_RUNTIME_DIR": str(runtime),
        "XDG_RUNTIME_DIR": str(runtime),
        "XDG_CONFIG_HOME": str(config_home),
        "HOME": str(home),
        "PIPEWIRE_CORE": remote,
        "PIPEWIRE_REMOTE": remote,
        "JACK_DEFAULT_SERVER": f"no-user-server-{remote}",
        "PIPEWIRE_DEBUG": "0",
    })
    return environment


def server_ready(server: subprocess.Popen[bytes], environment: dict[str, str],
                 remote: str) -> bool:
    deadline = time.monotonic() + STARTUP_TIMEOUT
    while time.monotonic() < deadline:
        if server.poll() is not None:
            return False
        checked = subprocess.run(
            ["pw-cli", "-r", remote, "info", "0"],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=1.0,
        )
        if checked.returncode == 0:
            return True
        time.sleep(0.02)
    return False


def require_dummy_driver(environment: dict[str, str], remote: str) -> None:
    dumped = subprocess.run(
        ["pw-dump", "-r", remote],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=3.0,
    )
    if dumped.returncode != 0:
        raise RuntimeError("pw-dump readiness check failed: " + dumped.stderr.strip())
    objects = json.loads(dumped.stdout)
    dummy = []
    for item in objects:
        if not isinstance(item, dict):
            continue
        info = item.get("info")
        props = info.get("props", {}) if isinstance(info, dict) else {}
        if props.get("node.name") == "Dummy-Driver":
            dummy.append(item)
    if len(dummy) != 1:
        raise RuntimeError(
            f"expected exactly one private Dummy-Driver, found {len(dummy)}"
        )


def terminate_group(process: subprocess.Popen[bytes], timeout: float) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=timeout)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=timeout)


def run_test(test_binary: Path, peer_binary: Path,
             environment: dict[str, str], remote: str,
             server_pid: int) -> int:
    test_environment = environment.copy()
    test_environment.update({
        "PLUGINHOST_INTEGRATION_ISOLATED": "1",
        "PLUGINHOST_JACK_PEER": str(peer_binary),
        "PLUGINHOST_PIPEWIRE_PID": str(server_pid),
    })
    command = [
        "pw-jack", "-r", remote, "-s", "48000", "-p", "64",
        str(test_binary),
    ]
    process = subprocess.Popen(
        command,
        env=test_environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=TEST_TIMEOUT)
    except subprocess.TimeoutExpired:
        terminate_group(process, TEARDOWN_TIMEOUT)
        stdout, stderr = process.communicate()
        sys.stdout.buffer.write(stdout)
        sys.stderr.buffer.write(stderr)
        print("live integration test timed out", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(stdout)
    sys.stderr.buffer.write(stderr)
    return process.returncode


def runtime_entries(runtime: Path) -> list[Path]:
    return list(runtime.iterdir()) if runtime.exists() else []


def run_integration(config: Path, test_binary: Path, peer_binary: Path) -> int:
    if not test_binary.is_file() or not os.access(test_binary, os.X_OK):
        print(f"integration test binary is unavailable: {test_binary}", file=sys.stderr)
        return 1
    if not peer_binary.is_file() or not os.access(peer_binary, os.X_OK):
        print(f"integration JACK peer is unavailable: {peer_binary}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="pluginhost-pipewire-") as temporary:
        root = Path(temporary)
        remote = f"pluginhost-4c-{os.getpid()}-{secrets.token_hex(8)}"
        environment = private_environment(root, remote)
        runtime = root / "runtime"
        log_path = root / "pipewire.log"
        socket_path = runtime / remote
        server: subprocess.Popen[bytes] | None = None
        result = 1
        teardown_error: str | None = None
        with log_path.open("wb") as log:
            try:
                server = subprocess.Popen(
                    ["pipewire", "-c", str(config), "-P", PROPERTIES],
                    env=environment,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                if not server_ready(server, environment, remote):
                    raise RuntimeError("private PipeWire server did not become ready")
                if not socket_path.exists() or not stat.S_ISSOCK(socket_path.stat().st_mode):
                    raise RuntimeError(f"private PipeWire socket is missing: {socket_path}")
                require_dummy_driver(environment, remote)
                result = run_test(
                    test_binary, peer_binary, environment, remote, server.pid)
            except (OSError, RuntimeError, ValueError, json.JSONDecodeError,
                    subprocess.SubprocessError) as error:
                print(f"isolated PipeWire-JACK integration failed: {error}",
                      file=sys.stderr)
                result = 1
            finally:
                if server is not None:
                    try:
                        terminate_group(server, TEARDOWN_TIMEOUT)
                    except (OSError, subprocess.SubprocessError) as error:
                        teardown_error = f"could not terminate private PipeWire server: {error}"
                log.flush()

        if server is not None and server.poll() is None:
            teardown_error = "private PipeWire server remained alive after teardown"
        remaining = runtime_entries(runtime)
        if remaining:
            rendered = ", ".join(path.name for path in remaining)
            teardown_error = f"private PipeWire runtime was not empty: {rendered}"
        if teardown_error is not None:
            print(teardown_error, file=sys.stderr)
            result = 1
        if result != 0:
            try:
                log_text = log_path.read_text(errors="replace")
            except OSError:
                log_text = ""
            if log_text:
                print("private PipeWire log:", file=sys.stderr)
                print(log_text, file=sys.stderr, end="" if log_text.endswith("\n") else "\n")
        else:
            print(f"Isolated PipeWire-JACK integration passed: remote={remote}")
        return result


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--test", type=Path,
                        default=Path("build/test/all_integration_tests"))
    parser.add_argument("--peer", type=Path,
                        default=Path("build/integration/jack_peer"))
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    failures, config = prerequisite_failures()
    if failures:
        print("PipeWire-JACK integration prerequisites are unavailable:",
              file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        print("integration test did not run", file=sys.stderr)
        return 1
    assert config is not None
    if arguments.check_only:
        print(f"PipeWire-JACK integration prerequisites available: {config}")
        return 0
    return run_integration(
        config.resolve(), arguments.test.resolve(), arguments.peer.resolve()
    )


if __name__ == "__main__":
    raise SystemExit(main())
