#!/usr/bin/env python3
"""Reject prohibited runtime calls in the generated RT probe callback."""

from pathlib import Path
import re
import sys

MARKER = "pluginhost_rt_probe_process"
FORBIDDEN = {
    r"\b(?:alloc|alloc0|allocShared|allocShared0|dealloc|deallocShared)\w*\s*\(":
        "Nim allocation",
    r"\b(?:nimNewObj|nimRawNewString|rawNewString|newSeq|setLengthSeq)\w*\s*\(":
        "managed allocation",
    r"\b(?:malloc|calloc|realloc|free)\w*\s*\(": "C allocation",
    r"\b(?:raise|nimRaise|reraise)\w*\s*\(": "exception runtime",
    r"\b(?:printf|fprintf|fwrite|puts|write)\w*\s*\(": "diagnostic I/O",
    r"\b(?:pthread_mutex|pthread_rwlock|pthread_cond)\w*\s*\(": "blocking lock",
    r"\b(?:dlopen|dlclose|dlsym)\w*\s*\(": "dynamic-library operation",
}


def extract_definition(source: str) -> str | None:
    for occurrence in re.finditer(rf"\b{MARKER}\b", source):
        tail = source[occurrence.end():]
        brace_offset = tail.find("{")
        semicolon_offset = tail.find(";")
        if brace_offset < 0:
            continue
        if 0 <= semicolon_offset < brace_offset:
            continue

        start = occurrence.start()
        body_start = occurrence.end() + brace_offset
        depth = 0
        for index in range(body_start, len(source)):
            char = source[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    return source[start:index + 1]
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: audit_generated_callback.py NIMCACHE", file=sys.stderr)
        return 2

    nimcache = Path(sys.argv[1])
    definitions: list[tuple[Path, str]] = []
    for candidate in nimcache.rglob("*.c"):
        source = candidate.read_text(errors="replace")
        definition = extract_definition(source)
        if definition is not None:
            definitions.append((candidate, definition))

    if len(definitions) != 1:
        print(
            f"expected one generated {MARKER} definition, found {len(definitions)}",
            file=sys.stderr,
        )
        return 1

    source_path, definition = definitions[0]
    failures: list[str] = []
    for pattern, description in FORBIDDEN.items():
        if re.search(pattern, definition):
            failures.append(description)
    if "nimfr_" in definition or "NimFrame" in definition:
        failures.append("stack-trace frame setup")

    if failures:
        print(f"prohibited generated callback operations in {source_path}:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"Generated callback audit passed: {source_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
