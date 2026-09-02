#!/usr/bin/env python3
"""Audit complete generated RT modules and process-reachable callback helpers."""

from __future__ import annotations

from collections import deque
from pathlib import Path
import re
import sys

COMPLETE_MODULES = (
    "@ppluginhost@sjack@scallbacks.nim.c",
    "@ppluginhost@srt@sengine.nim.c",
    "@ppluginhost@srt@srole_guard.nim.c",
    "@ppluginhost@sclap@sparameter_transport.nim.c",
)

JACK_ROOTS = (
    "pluginhost_audio_role_try_enter",
    "pluginhost_audio_role_is_current",
    "pluginhost_audio_role_leave",
    "pluginhost_rt_set_audio_input",
    "pluginhost_rt_set_audio_output",
    "pluginhost_rt_set_midi_input",
    "pluginhost_rt_set_midi_output",
    "pluginhost_rt_zero_outputs",
    "pluginhost_rt_process_fake",
    "pluginhost_rt_process",
    "pluginhost_jack_process_callback",
    "pluginhost_jack_shutdown_callback",
    "pluginhost_jack_info_shutdown_callback",
    "pluginhost_jack_buffer_size_callback",
    "pluginhost_jack_sample_rate_callback",
    "pluginhost_jack_xrun_callback",
    "pluginhost_jack_freewheel_callback",
    "pluginhost_jack_latency_callback",
    "pluginhost_jack_midi_event_count",
    "pluginhost_jack_midi_event_get",
    "pluginhost_jack_midi_clear",
    "pluginhost_jack_midi_reserve",
    "pluginhost_jack_midi_lost_event_count",
)

CLAP_ROOTS = (
    "pluginhost_clap_host_get_extension",
    "pluginhost_clap_host_request_restart",
    "pluginhost_clap_host_request_process",
    "pluginhost_clap_host_request_callback",
    "pluginhost_clap_host_log",
    "pluginhost_clap_host_is_main_thread",
    "pluginhost_clap_host_is_audio_thread",
    "pluginhost_clap_host_params_rescan",
    "pluginhost_clap_host_params_clear",
    "pluginhost_clap_host_params_request_flush",
    "pluginhost_clap_host_audio_ports_is_rescan_supported",
    "pluginhost_clap_host_audio_ports_rescan",
    "pluginhost_clap_host_note_ports_supported_dialects",
    "pluginhost_clap_host_note_ports_rescan",
)

CLAP_PROCESS_ROOTS = (
    "pluginhost_clap_process_audio",
)

CLAP_EVENT_ROOTS = (
    "pluginhost_clap_input_event_size",
    "pluginhost_clap_input_event_get",
    "pluginhost_clap_output_event_try_push",
    "pluginhost_clap_event_cycle_begin",
    "pluginhost_clap_event_cycle_end",
    "pluginhost_clap_event_cycle_active",
)

PROBE_ROOTS = (
    "pluginhost_rt_probe_process",
    "pluginhost_host_callbacks_probe",
)

FORBIDDEN = {
    r"\b(?:alloc|alloc0|allocShared|allocShared0|dealloc|deallocShared)\w*\s*\(":
        "Nim allocation or deallocation",
    r"\b(?:nimNewObj|nimRawNewString|rawNewString|newSeq|setLengthSeq)\w*\s*\(":
        "managed allocation",
    r"\b(?:nimDecRef|nimIncRef|nimDestroy|eqdestroy|unsureAsgnRef)\w*\s*\(":
        "ARC/managed lifetime operation",
    r"\b(?:malloc|calloc|realloc|reallocarray|free|aligned_alloc|posix_memalign|"
    r"mmap|mremap|munmap)\w*\s*\(": "C allocation or deallocation",
    r"\b(?:raise|nimRaise|reraise|panic|setjmp|longjmp)\w*\s*\(":
        "exception or panic runtime",
    r"\b(?:nimfr_|nimlf_|nimln_|pushFrame|popFrame|callDepthLimitReached)\w*\s*\(":
        "trace-frame or line-trace setup",
    r"\b(?:printf|vprintf|fprintf|vfprintf|sprintf|snprintf|fwrite|fputs|puts|"
    r"putchar|write|writev)\w*\s*\(": "print or write I/O",
    r"\b(?:open|open64|openat|openat64|creat|read|pread|pwrite|close|fsync|"
    r"fdatasync|ioctl|poll|ppoll|select|pselect|epoll_wait|syscall)\w*\s*\(":
        "file, device, or blocking I/O",
    r"\b(?:socket|connect|accept|send|recv)\w*\s*\(": "network I/O",
    r"\b(?:pthread_(?:mutex|rwlock|spin|cond|create|join|once)|sleep|usleep|"
    r"nanosleep)\w*\s*\(": "lock, wait, sleep, or thread management",
    r"\b(?:dlopen|dlclose|dlsym|dlvsym)\w*\s*\(": "dynamic-library operation",
}

CALL_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")
FUNCTION_MACRO_RE = re.compile(
    r"\b(?:N_INLINE|N_NIMCALL|N_CDECL)\([^,\n]+,\s*([A-Za-z_][A-Za-z0-9_]*)\)"
)
C_KEYWORDS = {
    "if", "for", "while", "switch", "case", "return", "sizeof", "_Alignof",
    "typeof", "__typeof__", "_Static_assert",
}
ALLOWED_EXTERNALS = {
    "memcpy", "memset", "pthread_self", "pthread_equal", "callback", "processProc",
    "N_CDECL", "N_INLINE", "N_NIMCALL", "IL64",
    "__builtin_unreachable", "portGetBuffer", "portGetLatencyRange",
    "portSetLatencyRange", "midiGetEventCount", "midiEventGet",
    "midiClearBuffer", "midiEventReserve", "midiGetLostEventCount",
    "eventCount", "eventGet", "clear", "reserve", "lostEventCount",
}
ALLOWED_EXTERNAL_PREFIXES = (
    "pluginhost_rt_atomic_",
    "pluginhost_audio_role_",
    "pluginhost_rt_set_audio_",
    "pluginhost_rt_set_midi_",
    "pluginhost_rt_zero_outputs",
    "pluginhost_rt_process_fake",
    "pluginhost_rt_process",
    "initAudioRoleGuard__",
    "initRtEngine__",
    "pluginhost_clap_event_cycle_",
    "tryPushOutput__OOZOOZsrcZpluginhostZclapZparameter95transport_",
)


def extract_braced(source: str, opening: int) -> str | None:
    depth = 0
    for index in range(opening, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return None


def definitions_in(source: str) -> dict[str, str]:
    definitions: dict[str, str] = {}
    for match in FUNCTION_MACRO_RE.finditer(source):
        semicolon = source.find(";", match.end())
        opening = source.find("{", match.end())
        if opening < 0 or (semicolon >= 0 and semicolon < opening):
            continue
        body = extract_braced(source, opening)
        if body is None:
            continue
        name = match.group(1)
        definitions[name] = source[match.start():opening] + body
    return definitions


def generated_sources(nimcache: Path) -> dict[Path, str]:
    return {
        candidate: candidate.read_text(errors="replace")
        for candidate in nimcache.rglob("*.c")
    }


def find_marker(sources: dict[Path, str], marker: str) -> list[tuple[Path, str]]:
    matches: list[tuple[Path, str]] = []
    for path, source in sources.items():
        definition = definitions_in(source).get(marker)
        if definition is not None:
            matches.append((path, definition))
    return matches


def prohibited(definition: str) -> list[str]:
    failures: list[str] = []
    for pattern, description in FORBIDDEN.items():
        if re.search(pattern, definition):
            failures.append(description)
    if "NimFrame" in definition:
        failures.append("trace-frame storage")
    return failures


def helper_closure(source: str, roots: tuple[str, ...]) -> tuple[dict[str, str], set[str]]:
    definitions = definitions_in(source)
    reached: dict[str, str] = {}
    external: set[str] = set()
    pending = deque(roots)
    while pending:
        name = pending.popleft()
        if name in reached:
            continue
        definition = definitions.get(name)
        if definition is None:
            external.add(name)
            continue
        reached[name] = definition
        for called in CALL_RE.findall(definition):
            if called == name or called in C_KEYWORDS:
                continue
            if called in definitions:
                if called not in reached:
                    pending.append(called)
            else:
                external.add(called)
    return reached, external


def allowed_external(name: str) -> bool:
    return name in ALLOWED_EXTERNALS or any(
        name.startswith(prefix) for prefix in ALLOWED_EXTERNAL_PREFIXES
    )


def audit_complete_module(path: Path, source: str) -> list[str]:
    failures = [f"{path}: {failure}" for failure in prohibited(source)]
    definitions = definitions_in(source)
    external: set[str] = set()
    for name, definition in definitions.items():
        for called in CALL_RE.findall(definition):
            if called != name and called not in definitions and \
                    called not in C_KEYWORDS:
                external.add(called)
    for name in sorted(external):
        if not allowed_external(name):
            failures.append(
                f"{path}: unreviewed external call from complete RT module: {name}"
            )
    return failures


def audit_closure(path: Path, source: str,
                  roots: tuple[str, ...]) -> tuple[list[str], int]:
    reached, external = helper_closure(source, roots)
    failures: list[str] = []
    for root in roots:
        if root not in reached:
            failures.append(f"{path}: missing callback root {root}")
    for name, definition in reached.items():
        for failure in prohibited(definition):
            failures.append(f"{path}: {name}: {failure}")
    unexpected = sorted(
        name for name in external
        if name not in roots and not allowed_external(name)
    )
    for name in unexpected:
        failures.append(f"{path}: unreviewed external call from callback closure: {name}")
    return failures, len(reached)


def audit_atomic_header() -> list[str]:
    root = Path(__file__).resolve().parents[2]
    header = root / "c" / "rt_atomic.h"
    if not header.is_file():
        return [f"missing real-time atomic header: {header}"]
    source = header.read_text(errors="replace")
    failures = [f"{header}: {failure}" for failure in prohibited(source)]
    for name in sorted(set(CALL_RE.findall(source))):
        if name in C_KEYWORDS or name == "_Atomic" or \
                name.startswith("pluginhost_rt_atomic_") or \
                name.startswith("atomic_") or \
                name == "__atomic_always_lock_free":
            continue
        failures.append(f"{header}: unreviewed C atomic bridge call: {name}")
    return failures


def audit_main(nimcache: Path) -> int:
    sources = generated_sources(nimcache)
    failures: list[str] = []
    audited: set[Path] = set()

    for filename in COMPLETE_MODULES:
        matches = [(path, source) for path, source in sources.items()
                   if path.name == filename]
        if len(matches) != 1:
            failures.append(
                f"expected one generated RT module {filename}, found {len(matches)}"
            )
            continue
        path, source = matches[0]
        audited.add(path)
        failures.extend(audit_complete_module(path, source))

    all_roots = JACK_ROOTS + CLAP_ROOTS + CLAP_PROCESS_ROOTS + CLAP_EVENT_ROOTS
    for root in all_roots:
        matches = find_marker(sources, root)
        if len(matches) != 1:
            failures.append(
                f"expected one generated {root} definition, found {len(matches)}"
            )

    bridge_matches = [(path, source) for path, source in sources.items()
                      if path.name == "@ppluginhost@sclap@shost_bridge.nim.c"]
    if len(bridge_matches) != 1:
        failures.append(
            "expected one generated CLAP host bridge module, "
            f"found {len(bridge_matches)}"
        )
        bridge_count = 0
    else:
        bridge_path, bridge_source = bridge_matches[0]
        audited.add(bridge_path)
        bridge_failures, bridge_count = audit_closure(
            bridge_path, bridge_source, CLAP_ROOTS)
        failures.extend(bridge_failures)

    audio_matches = [(path, source) for path, source in sources.items()
                     if path.name == "@ppluginhost@sclap@saudio_process.nim.c"]
    audio_count = 0
    if len(audio_matches) != 1:
        failures.append(
            "expected one generated CLAP audio process module, "
            f"found {len(audio_matches)}"
        )
    else:
        audio_path, audio_source = audio_matches[0]
        audited.add(audio_path)
        audio_failures, audio_count = audit_closure(
            audio_path, audio_source, CLAP_PROCESS_ROOTS)
        failures.extend(audio_failures)

    event_matches = [(path, source) for path, source in sources.items()
                     if path.name == "@ppluginhost@sclap@sevent_bridge.nim.c"]
    event_count = 0
    if len(event_matches) != 1:
        failures.append(
            "expected one generated CLAP event bridge module, "
            f"found {len(event_matches)}"
        )
    else:
        event_path, event_source = event_matches[0]
        audited.add(event_path)
        event_failures, event_count = audit_closure(
            event_path, event_source, CLAP_EVENT_ROOTS)
        failures.extend(event_failures)

    failures.extend(audit_atomic_header())

    if failures:
        print("Generated callback audit failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    paths = ", ".join(str(path) for path in sorted(audited))
    paths += ", c/rt_atomic.h"
    print(
        "Complete generated callback audit passed "
        f"({bridge_count + audio_count + event_count} CLAP callback/helper functions): {paths}"
    )
    return 0


def audit_probes(nimcache: Path) -> int:
    sources = generated_sources(nimcache)
    failures: list[str] = []
    audited: set[Path] = set()
    for root in PROBE_ROOTS:
        matches = find_marker(sources, root)
        if len(matches) != 1:
            failures.append(
                f"expected one generated {root} definition, found {len(matches)}"
            )
            continue
        path, definition = matches[0]
        audited.add(path)
        for failure in prohibited(definition):
            failures.append(f"{path}: {root}: {failure}")
    if failures:
        print("Generated callback probe audit failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    paths = ", ".join(str(path) for path in sorted(audited))
    print(f"Generated callback probe audit passed: {paths}")
    return 0


def audit_canary(nimcache: Path, marker: str) -> int:
    sources = generated_sources(nimcache)
    matches = find_marker(sources, marker)
    if len(matches) != 1:
        print(
            f"expected one generated canary {marker} definition, found {len(matches)}",
            file=sys.stderr,
        )
        return 2
    path, definition = matches[0]
    failures = prohibited(definition)
    if not failures:
        print(f"audit accepted prohibited canary {marker} ({path})", file=sys.stderr)
        return 0
    print(f"prohibited generated operations in canary {marker} ({path}):",
          file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) == 2:
        return audit_main(Path(sys.argv[1]))
    if len(sys.argv) == 3 and sys.argv[1] == "--probes":
        return audit_probes(Path(sys.argv[2]))
    if len(sys.argv) == 4 and sys.argv[1] == "--canary":
        return audit_canary(Path(sys.argv[2]), sys.argv[3])
    print(
        "usage: audit_generated_callback.py NIMCACHE\n"
        "       audit_generated_callback.py --probes NIMCACHE\n"
        "       audit_generated_callback.py --canary NIMCACHE MARKER",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
