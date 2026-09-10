#!/usr/bin/env python3
"""Run sanitizer and ownership checks over host-owned test executables."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


def command_text(command: list[str]) -> str:
    return " ".join(command)


def run(command: list[str], environment: dict[str, str] | None = None) -> None:
    print("$ " + command_text(command), flush=True)
    subprocess.run(command, check=True, env=environment)


def tool_version(tool: str, version_args: list[str]) -> None:
    path = shutil.which(tool)
    if path is None:
        raise SystemExit(f"required sanitizer/resource tool is unavailable: {tool}")
    run([path, *version_args])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asan", type=Path, required=True)
    parser.add_argument("--valgrind", type=Path, required=True)
    args = parser.parse_args()

    for executable in (args.asan, args.valgrind):
        if not executable.is_file():
            raise SystemExit(f"sanitizer target does not exist: {executable}")

    tool_version("clang", ["--version"])
    tool_version("valgrind", ["--version"])

    sanitizer_environment = os.environ.copy()
    sanitizer_environment["ASAN_OPTIONS"] = (
        "detect_leaks=1:halt_on_error=1:abort_on_error=1:"
        "allocator_may_return_null=0"
    )
    sanitizer_environment["UBSAN_OPTIONS"] = (
        "halt_on_error=1:print_stacktrace=1"
    )
    run([str(args.asan)], sanitizer_environment)

    run(
        [
            "valgrind",
            "--tool=memcheck",
            "--leak-check=full",
            "--show-leak-kinds=definite,indirect",
            "--errors-for-leak-kinds=definite,indirect",
            "--error-exitcode=1",
            "--track-fds=yes",
            str(args.valgrind),
        ],
        os.environ.copy(),
    )
    print("Sanitizer and Valgrind checks passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
