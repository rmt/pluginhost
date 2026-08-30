#!/usr/bin/env python3
"""Reject prohibited runtime calls in generated real-time callback paths."""

from pathlib import Path
import re
import sys

MARKERS = (
    "pluginhost_rt_probe_process",
    "pluginhost_host_callbacks_probe",
    "pluginhost_clap_host_cstring_equals",
    "pluginhost_clap_host_log_try_push",
    "pluginhost_clap_host_callback_data",
    "pluginhost_clap_host_record_request",
    "pluginhost_clap_host_get_extension",
    "pluginhost_clap_host_request_restart",
    "pluginhost_clap_host_request_process",
    "pluginhost_clap_host_request_callback",
    "pluginhost_clap_host_log",
    "pluginhost_clap_host_is_main_thread",
    "pluginhost_clap_host_is_audio_thread",
    "pluginhost_audio_role_try_enter",
    "pluginhost_audio_role_is_current",
    "pluginhost_audio_role_leave",
    "pluginhost_rt_set_audio_input",
    "pluginhost_rt_set_audio_output",
    "pluginhost_rt_zero_outputs",
    "pluginhost_rt_process_fake",
    "pluginhost_jack_process_callback",
    "pluginhost_jack_shutdown_callback",
    "pluginhost_jack_info_shutdown_callback",
    "pluginhost_jack_buffer_size_callback",
    "pluginhost_jack_sample_rate_callback",
    "pluginhost_jack_xrun_callback",
    "pluginhost_jack_freewheel_callback",
    "pluginhost_jack_latency_callback",
)
FORBIDDEN = {
    r"\b(?:alloc|alloc0|allocShared|allocShared0|dealloc|deallocShared)\w*\s*\(":
        "Nim allocation",
    r"\b(?:nimNewObj|nimRawNewString|rawNewString|newSeq|setLengthSeq)\w*\s*\(":
        "managed allocation",
    r"\b(?:malloc|calloc|realloc|free)\w*\s*\(": "C allocation",
    r"\b(?:raise|nimRaise|reraise)\w*\s*\(": "exception runtime",
    r"\b(?:printf|fprintf|fwrite|puts|write)\w*\s*\(": "diagnostic I/O",
    r"\b(?:pthread_(?:mutex|rwlock|cond|create|join)|sleep|usleep|nanosleep)\w*\s*\(":
        "blocking or thread-management call",
    r"\b(?:dlopen|dlclose|dlsym)\w*\s*\(": "dynamic-library operation",
}


def extract_definition(source: str, marker: str) -> str | None:
    for occurrence in re.finditer(rf"\b{re.escape(marker)}\b", source):
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
    definitions: dict[str, list[tuple[Path, str]]] = {
        marker: [] for marker in MARKERS
    }
    for candidate in nimcache.rglob("*.c"):
        source = candidate.read_text(errors="replace")
        for marker in MARKERS:
            definition = extract_definition(source, marker)
            if definition is not None:
                definitions[marker].append((candidate, definition))

    invalid_counts = False
    for marker, matches in definitions.items():
        if len(matches) != 1:
            print(
                f"expected one generated {marker} definition, found {len(matches)}",
                file=sys.stderr,
            )
            invalid_counts = True
    if invalid_counts:
        return 1

    failed = False
    audited_paths: set[Path] = set()
    for marker, matches in definitions.items():
        source_path, definition = matches[0]
        audited_paths.add(source_path)
        failures: list[str] = []
        for pattern, description in FORBIDDEN.items():
            if re.search(pattern, definition):
                failures.append(description)
        if "nimfr_" in definition or "NimFrame" in definition:
            failures.append("stack-trace frame setup")

        if failures:
            failed = True
            print(
                f"prohibited generated operations in {marker} ({source_path}):",
                file=sys.stderr,
            )
            for failure in failures:
                print(f"- {failure}", file=sys.stderr)

    if failed:
        return 1

    paths = ", ".join(str(path) for path in sorted(audited_paths))
    print(f"Generated callback audit passed: {paths}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
