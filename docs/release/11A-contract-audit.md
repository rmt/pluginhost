# Increment 11A Contract Audit

**Review unit:** 11A — Public contract and requirement closure
**Status:** Implementation complete; human review gate pending
**Date:** 2026-09-09
**Scope:** Public diagnostics/status behavior, control-plane warning policy, and requirement/design audit only

## 1. Scope and status vocabulary

This report audits every `MUST` requirement in `REQUIREMENTS.md` and every
checklist invariant in `DESIGN.md` against the current source and executed
evidence.

- **VERIFIED** — current implementation and focused evidence support the claim.
- **DEFECTIVE** — a current requirement gap is known and needs a focused fix.
- **BLOCKED** — verification or completion belongs to a later unit or requires
  an unavailable external environment; no release claim is made.
- **DEFERRED** — used only for intentionally deferred `SHOULD` requirements.

A VERIFIED result means the covered implementation paths passed. It does not
turn an unexecuted hostile-input or independent-compatibility matrix into a
release pass.

### 1.1 Owner-boundary resolution

The warning-stream contract requires one direct caller update in
`src/pluginhost/app/commands.nim`: `executeRun` must pass its selected
diagnostic stream into `HostSession.close()` so shutdown aggregates do not
escape to process-global stderr. The corresponding end-to-end warning and
process-status assertions live in `tests/fixtures/test_clap_audio.nim`.

The current 11A scope explicitly includes those direct consumers and the
test-only startup initialization in
`tests/fixtures/jack/fake_jack_fixture.c`. The subprocess cases use existing
CLAP/JACK fixture behavior, an invalid copied `libjack.so.0`, and environment
control only; no production seam, new fixture failure mode, or Nimble task
wiring was added.

This is the minimal boundary extension required by Acceptance line 832 and
is recorded for review rather than being an implicit scope change.

## 2. Frozen public contract

### 2.1 Exit statuses

| Status | Meaning | Mapping evidence |
|---:|---|---|
| `0` | Successful information command or clean run shutdown | `src/pluginhost/domain/errors.nim`, `src/pluginhost/app/commands.nim`, `tests/unit/test_main.nim` |
| `1` | Generic platform, reactor, internal, or cleanup failure | `HostError.exitCode()`, `tests/unit/test_errors.nim` |
| `2` | CLI usage or plugin-selection failure | `usageError`, `hekPluginSelection`, CLI/process tests |
| `3` | CLAP loading/discovery/initialization/processing failure | CLAP loader, catalog, fixture, and process tests |
| `4` | JACK loading/connection/registration/activation/shutdown failure | JACK API/backend tests and `HostError.exitCode()` |
| `5` | Required GUI failure | `HostError.exitCode()`, GUI controller policy tests |
| `6` | Requested state load/save failure | state codec/fixture tests and `HostError.exitCode()` |

`HostError.exitCode()` gives subsystem precedence for JACK, GUI, and state;
then maps usage/selection, CLAP/discovery, and generic categories. The mapping
is intentionally stable for the release candidate.

### 2.2 Diagnostic output

- Human diagnostics are written to the supplied standard-error stream.
- JSON data remains on standard output without human prefixes or diagnostics.
- `formatDiagnostic()` now sanitizes both `HostError.message` and
  `HostError.context` with the existing invalid-UTF-8/control-text policy.
- Drained CLAP log identity and text are sanitized before writing.
- `HostSession.close(errorOutput)` flushes pending warning aggregates to the
  same diagnostic stream; the no-argument overload retains standard error.
- `notImplementedError` and `hekNotImplemented` were removed after reference
  inspection found no production or test callers. Unsupported behavior must use
  an explicit typed failure; no obsolete success path remains.

### 2.3 Warning policy

`src/pluginhost/support/diagnostics.nim` owns a fixed-key,
control-plane-only `WarningLimiter`:

- Default interval: `1_000_000_000` nanoseconds.
- Keys cover xruns, freewheel changes, event drops, parameter drops, CLAP log
  queue drops, JACK connection loss, GUI show/hide/failure, and tray failure.
- Each key emits its first report immediately.
- Reports within the interval are suppressed and counted with saturating math.
- The next permitted report includes `(suppressed=N)`.
- `flushWarnings()` emits a final category/count aggregate and is one-shot.
- The caller supplies a nanosecond timestamp, allowing deterministic tests;
  `HostSession` supplies `getMonoTime().ticks` on the main/control plane.
- Quiet mode suppresses non-error warning paths before they enter the limiter.
  Required errors still return and are rendered normally.
- No limiter code is reachable from JACK or CLAP process callbacks.

## 3. MUST requirement audit

### 3.1 CLI and discovery (`REQUIREMENTS.md` 6.1–6.3)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R6.1 | Provide canonical path-only run, explicit run, `list`, `scan`, `--help`, and `--version`. | VERIFIED | `src/pluginhost/app/cli.nim`; `tests/unit/test_cli.nim`; `tests/unit/test_main.nim`; fixture process tests. |
| R6.2a | Provide all required run options. | VERIFIED | `test_cli.nim` parses the complete option set, including GUI, state, PID, JACK, and verbosity options. |
| R6.2b | Invalid or missing option values produce a concise diagnostic, usage hint, and non-zero status. | VERIFIED | CLI unit tests and invalid process invocation test. |
| R6.2c | `--plugin-id` and `--plugin-index` are mutually exclusive. | VERIFIED | CLI mutual-exclusion test. |
| R6.2d | Ambiguous multi-descriptor startup fails and lists available indices, IDs, and names. | VERIFIED | `test_plugin_catalog.nim` and catalog fixture tests. |
| R6.2e | Resolve relative plugin paths before CLAP `entry.init()` and pass the exact path. | VERIFIED | CLAP loader fixture lifecycle and canonical-path tests. |
| R6.2f | `list` reports index, ID, name, vendor, version, and features without creating an instance. | VERIFIED | `test_list_command.nim`, `test_clap_catalog.nim`, and fixture counters. |
| R6.2g | JSON output is valid and has no human-readable prefixes or diagnostics on stdout. | VERIFIED | `test_list_command.nim`, `test_scan_command.nim`, catalog-output tests, and process stdout checks. |
| R6.3a | `scan` recursively inspects all required roots and explicit directories. | VERIFIED | Discovery-path and scan fixture tests. |
| R6.3b | Avoid duplicate canonical paths and symlink directory loops. | VERIFIED | Scan canonicalization/symlink fixture tests. |
| R6.3c | Report one candidate failure without preventing remaining candidates. | VERIFIED | Failure-isolated scan fixture tests. |
| R6.3d | Retain successful scan results and return status `3` if any issue occurs. | VERIFIED | Human/JSON scan fixture tests. |
| R6.3e | Resolve relative explicit/`CLAP_PATH` roots from the working directory and do not shell-expand `~`. | VERIFIED | Discovery path unit tests. |
| R6.3f | Match every successful entry initialization with `deinit()` before unload. | VERIFIED | CLAP loader fixture ownership tests. |
| R6.3g | Document that scanning executes plugin native code. | VERIFIED | README Security section. |

### 3.2 Runtime process control (`REQUIREMENTS.md` 6.4)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R6.4a | Linux process name and X11 title use `$PluginName [$PluginFormat]`. | VERIFIED | Naming unit tests; X11 integration; source composition. |
| R6.4b | Truncate Linux `comm` to 15 bytes on a valid UTF-8 boundary while retaining full X11 title. | VERIFIED | `test_utf8.nim`, naming tests, X11 tests. |
| R6.4c | `SIGINT` and `SIGTERM` request orderly shutdown. | VERIFIED | Public integration tests under isolated PipeWire-JACK. |
| R6.4d | `SIGUSR1` shows the GUI. | VERIFIED | GUI controller and signal integration tests. |
| R6.4e | `SIGUSR2` hides the GUI. | VERIFIED | GUI controller and signal integration tests. |
| R6.4f | Show/hide are idempotent. | VERIFIED | GUI controller lifecycle tests. |
| R6.4g | Disable Nim implicit signal handlers in production. | VERIFIED | `config.nims`, build-profile test, and complete build. |
| R6.4h | Block handled signals with `pthread_sigmask` before `jack_client_open`. | VERIFIED | Linux process-control tests and source ordering. |
| R6.4i | Consume handled signals through `signalfd`/equivalent on the main control plane. | VERIFIED | `test_process_control.nim`, public signal integration, and source audit. |
| R6.4j | Any fallback signal handler only performs async-signal-safe notification. | VERIFIED | Production uses blocked signals plus `signalfd`; no fallback policy handler exists. |
| R6.4k | GUI close hides/destroys GUI as required without stopping audio or terminating host. | VERIFIED | GUI controller/X11 integration and live audio lifecycle evidence. |
| R6.4l | Show after GUI close recreates when permitted. | VERIFIED | GUI close/reopen fixture and X11 integration tests. |
| R6.4m | `SIGUSR1` under `--no-gui` is ignored with a rate-limited warning. | VERIFIED | Public signal integration plus 11A warning limiter/flush fixture test. |
| R6.4n | Primary tray `Activate` toggles GUI on the main control thread without affecting JACK/audio. | VERIFIED | D-Bus fake-watcher integration and tray controller tests. |
| R6.4o | Missing/failing session-bus integration warns and preserves ordinary startup. | VERIFIED | Tray controller policy, D-Bus integration, and public GUI policy. |
| R6.4p | `--no-gui` does not create or advertise a tray item. | VERIFIED | CLI policy and headless GUI fixture tests; source condition in `openTray`. |

### 3.3 CLAP loading, lifecycle, and processing (`REQUIREMENTS.md` 7)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R7.1.1 | Load the native `.clap` object. | VERIFIED | Loader fixture and DSO ABI tests. |
| R7.1.2 | Resolve `clap_entry`. | VERIFIED | Loader fixture failure/success tests. |
| R7.1.3 | Validate CLAP compatibility. | VERIFIED | CLAP ABI/version tests and loader fixtures. |
| R7.1.4 | Call `entry.init()` before other plugin-library symbols. | VERIFIED | Loader lifecycle fixture. |
| R7.1.5 | Obtain factory and enumerate descriptors. | VERIFIED | Catalog fixture tests. |
| R7.1.6 | Validate mandatory descriptor fields before display/use. | VERIFIED | Descriptor boundary fixture tests. |
| R7.1.7 | Create selected plugin with a host object valid through destruction. | VERIFIED | Instance lifecycle and host-bridge fixture tests. |
| R7.1.8 | Call `plugin.init()` on the main thread. | VERIFIED | Instance lifecycle and GUI/audio fixture tests. |
| R7.1.9 | Query extensions only after/during successful `plugin.init()`. | VERIFIED | Instance lifecycle fixture ordering checks. |
| R7.1.10 | Load requested state on the main thread before activation. | VERIFIED | State fixture ordering and public state integration. |
| R7.1.11 | Inspect ports while deactivated and reject invalid stable metadata. | VERIFIED | Port-inspector fixture boundary tests. |
| R7.1.12 | Set `CLAP_RENDER_REALTIME` when render is implemented. | VERIFIED | Render fixture tests. |
| R7.1.13 | Observe freewheel while continuing the realtime-safe path. | VERIFIED | JACK callback/backend tests and control metrics. |
| R7.1.14 | Activate with JACK sample rate and a frame range covering delivered blocks. | VERIFIED | Audio fixture activation tests and live PipeWire-JACK runs. |
| R7.1.15 | Call `start_processing()` in the symbolic audio-thread context before process. | VERIFIED | Audio-role guard, lifecycle, fixture, and RT tests. |
| R7.2a | Prevent process/teardown races and perform shutdown operations in valid contexts. | VERIFIED | Quiescence, lifecycle, state, GUI, fixture, and live integration tests. |
| R7.2b | Stop processing, save requested state, hide/destroy GUI, deactivate, destroy, deinit, unload, close JACK/PID resources in a valid applicable order. | VERIFIED | Fixture lifecycle/state tests, public state integration, and source teardown order. |
| R7.2c | Save state on the CLAP main thread while the plugin remains valid. | VERIFIED | State fixture call-order tests and public state integration. |
| R7.3a | Implement restart, process, and callback host requests. | VERIFIED | Host bridge, plugin-services, audio fixture, and live tests. |
| R7.3b | Make arbitrary-thread requests thread-safe and non-blocking. | VERIFIED | C-created-thread callback tests, RT instrumentation, and live callback audit. |
| R7.3c | Dispatch `on_main_thread()` promptly, normally within 33 ms when not overloaded. | VERIFIED | 16 ms reactor service bound, deterministic reactor tests, and main-thread callback fixture. |
| R7.3d | Restart safely rescans/reactivates/resumes without unloading the plugin. | VERIFIED | Restart/rescan fixture tests. |
| R7.3e | Keep audio output silent while restart is pending/incomplete. | VERIFIED | Audio fixture restart and failure-to-silence tests. |
| R7.3f | Schedule safe reactivation for JACK format changes; never call main-thread CLAP methods from JACK notification callbacks. | VERIFIED | JACK callback tests and runtime audio-change fixture. |
| R7.3g | Failed activation/reactivation/start produces a clear error and silence. | VERIFIED | Audio activation/start failure fixtures. |
| R7.4a | `CLAP_PROCESS_ERROR` silences the cycle and schedules non-zero orderly termination. | VERIFIED | Audio process-error fixture and live process-control path. |
| R7.4b | Treat tail/continue-if-not-quiet conservatively as continued processing without tail/silence scans. | VERIFIED | Audio status fixture cases. |
| R7.4c | Start `steady_time` non-negative and advance at least processed frames. | VERIFIED | Audio fixture timing assertions. |
| R7.4d | Pass `transport = nil` in the initial release. | VERIFIED | Audio fixture and independent headless smoke; README limitation. |

### 3.4 CLAP extensions (`REQUIREMENTS.md` 8)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R8.1a | Consume `clap.audio-ports`. | VERIFIED | Port inspector/audio fixtures. |
| R8.1b | Consume `clap.note-ports`. | VERIFIED | Port/event fixtures. |
| R8.1c | Consume `clap.gui`. | VERIFIED | GUI fixture/Xvfb tests. |
| R8.1d | Consume `clap.params`. | VERIFIED | Parameter fixture tests. |
| R8.1e | Consume `clap.state`. | VERIFIED | State fixture tests. |
| R8.1f | Consume `clap.latency`. | VERIFIED | Latency fixture/backend tests. |
| R8.1g | Consume `clap.render`. | VERIFIED | Render fixture tests. |
| R8.1h | Consume `clap.timer-support`. | VERIFIED | Plugin-service timer tests and public fixture. |
| R8.1i | Consume `clap.posix-fd-support`. | VERIFIED | Plugin-service FD tests and public fixture. |
| R8.1j | Handle absent optional extensions without null dereference or unrelated failure. | VERIFIED | Missing-extension fixture tests. |
| R8.2a | Expose `clap.gui` when GUI hosting is enabled. | VERIFIED | Host bridge and GUI policy fixtures. |
| R8.2b | Expose `clap.params`. | VERIFIED | Host bridge/parameter fixtures. |
| R8.2c | Expose `clap.state`. | VERIFIED | Host bridge/state fixtures. |
| R8.2d | Expose `clap.latency`. | VERIFIED | Host bridge/latency fixtures. |
| R8.2e | Expose `clap.audio-ports`. | VERIFIED | Host bridge/port fixtures. |
| R8.2f | Expose `clap.note-ports`. | VERIFIED | Host bridge/event fixtures. |
| R8.2g | Expose `clap.log`. | VERIFIED | Host bridge log tests. |
| R8.2h | Expose `clap.timer-support`. | VERIFIED | Host bridge/service tests. |
| R8.2i | Expose `clap.posix-fd-support`. | VERIFIED | Host bridge/service tests. |
| R8.2j | Expose `clap.thread-check`. | VERIFIED | Host bridge/thread-role tests. |
| R8.2k | Return null for unsupported extension queries. | VERIFIED | Host bridge advertisement tests. |
| R8.3a | Implement parameter `request_flush()` and schedule processing/flush in the correct context. | VERIFIED | Parameter transport and audio fixture tests. |
| R8.3b | Never run `flush()` concurrently with `process()`. | VERIFIED | Audio lifecycle/parameter fixture and role guard. |
| R8.3c | Accept plugin parameter value, modulation, and gesture events. | VERIFIED | Parameter transport tests. |
| R8.3d | Track dirty state for plugin state/parameter changes. | VERIFIED | Audio fixture dirty-state tests. |
| R8.3e | Handle parameter rescans and cookie invalidation flags. | VERIFIED | Parameter rescan fixture tests. |
| R8.3f | Do not invent persistence without `clap.state`. | VERIFIED | State/parameter boundary implementation and fixture coverage. |
| R8.3g | Process output events without allocation in the realtime callback. | VERIFIED | RT event/output safety tests. |
| R8.3h | Return false for unsupported/invalid output events without audio-thread logging. | VERIFIED | Event fixture and RT safety tests. |

### 3.5 JACK integration (`REQUIREMENTS.md` 9)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R9.1a | Use the `libjack.so.0` client API. | VERIFIED | JACK ABI and complete runtime table tests. |
| R9.1b | Load JACK only through a checked operation with typed errors and rollback. | VERIFIED | `test_jack_api.nim`, backend rollback tests. |
| R9.1c | Keep help/version/list/scan usable without libjack. | VERIFIED | Eager-dependency checks, list/scan fixtures, process help/version tests. |
| R9.1d | Work with JACK1, JACK2, and PipeWire JACK where standard ABI is provided. | BLOCKED | PipeWire-JACK passed; `jackd`/separate JACK1/JACK2 implementations are unavailable in this environment. 11C must not claim the missing matrix rows. |
| R9.1e | Require a JACK server unless libjack starts one. | VERIFIED | Public runtime and isolated PipeWire-JACK tests. |
| R9.1f | Identify requested client/server and summarize status flags on connection failure. | VERIFIED | JACK backend error-context tests. |
| R9.1g | Schedule orderly termination on JACK shutdown; never clean up directly in shutdown callback. | VERIFIED | JACK callback tests and public loss integration. |
| R9.2a | Register process, shutdown/info-shutdown, buffer-size, sample-rate, xrun, freewheel, and required latency callbacks before activation. | VERIFIED | JACK backend registration tests. |
| R9.2b | Record freewheel transitions for control-plane diagnostics while processing realtime. | VERIFIED | JACK callback metric tests and `HostSession` service path. |
| R9.2c | Query initial sample rate and buffer size before CLAP activation. | VERIFIED | Audio/JACK fixture tests. |
| R9.3a | Represent every CLAP audio channel as one JACK float32 audio port. | VERIFIED | Port realization/audio fixtures. |
| R9.3b | Preserve CLAP grouping and channel order internally. | VERIFIED | Port plan/audio grouping fixtures. |
| R9.3c | Pass JACK float32 pointers without a normal full-buffer copy. | VERIFIED | Zero-copy audio fixture and RT audit. |
| R9.3d | Keep `data64` null. | VERIFIED | Audio fixture assertions. |
| R9.3e | Use distinct input/output buffers and normalize dangling in-place pairs. | VERIFIED | Port-inspector and audio fixtures. |
| R9.3f | Keep JACK port names deterministic, unique, legal, and within actual limits. | VERIFIED | JACK port naming/rollback tests. |
| R9.3g | Bound and UTF-8-truncate aliases when required. | VERIFIED | JACK alias boundary tests. |
| R9.3h | Report failing flattened port registration and unregister prior ports. | VERIFIED | Transactional JACK port tests. |
| R9.3i | Define outputs before every process and zero outputs when skipped/failed. | VERIFIED | Audio engine and process-status fixtures. |
| R9.3j | Supply correct CLAP counts, channel counts, and pointer lifetimes. | VERIFIED | Audio process fixtures and RT safety audit. |
| R9.4a | Support audio-port name rescans. | VERIFIED | Rescan/restart fixtures. |
| R9.4b | Rebuild structural ports only through restart/deactivate path. | VERIFIED | Structural rebuild fixture and quiescence tests. |
| R9.4c | Log lost external connections after structural rebuild. | VERIFIED | Reconnection-loss fixture and control-plane warning path. |
| R9.5a | Reflect plugin latency in JACK ranges. | VERIFIED | Latency backend/fixture tests. |
| R9.5b | Schedule safe refresh/restart on `clap_host_latency.changed()`. | VERIFIED | Latency-change fixture. |
| R9.5c | Never call `jack_recompute_total_latencies` from latency callback; recompute in control plane. | VERIFIED | JACK callback and latency tests. |
| R9.5d | Keep latency updates out of unsafe process-callback operations. | VERIFIED | Callback instrumentation and source audit. |

### 3.6 MIDI and note events (`REQUIREMENTS.md` 10)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R10.1a | Map every CLAP note port to one JACK MIDI port. | VERIFIED | Port/event fixture tests. |
| R10.1b | Expose supported CLAP note dialects through host note ports. | VERIFIED | Event/host bridge fixtures. |
| R10.1c | Support CLAP note and MIDI 1.0 dialects. | VERIFIED | Event dialect fixture tests. |
| R10.2a | Present JACK MIDI input in ascending sample-offset order. | VERIFIED | Event ordering fixture and live MIDI integration. |
| R10.2b | Preserve timestamps exactly within the JACK period. | VERIFIED | Event fixture/live offset assertions. |
| R10.2c | Set `CLAP_EVENT_IS_LIVE` for live JACK input. | VERIFIED | Event fixture checks. |
| R10.2d | Use `CLAP_EVENT_MIDI` for supported normalized MIDI messages up to three bytes. | VERIFIED | Raw MIDI fixture/live event path. |
| R10.2e | Copy/present complete SysEx chunks for the process-call lifetime. | VERIFIED | SysEx fixture/live integration and pointer-lifetime audit. |
| R10.2f | Translate supported CLAP-only note events. | VERIFIED | CLAP-only dialect fixture. |
| R10.2g | Drop unrepresentable messages safely, count them, and report later with rate limiting. | VERIFIED | Event metrics, 11A limiter tests, and live instrumentation. |
| R10.2h | Preserve raw velocity-zero semantics and translate to note-off in CLAP-note mode. | VERIFIED | Event dialect fixture. |
| R10.3a | Immediately copy MIDI/SysEx output with timestamps preserved. | VERIFIED | Output event fixture/live MIDI integration. |
| R10.3b | Consume valid `CLAP_EVENT_NOTE_END` without duplicate MIDI note-off. | VERIFIED | Event fixture. |
| R10.3c | Reject unsupported/invalid/out-of-order/overflow output safely and count errors. | VERIFIED | Event fixture and RT safety tests. |
| R10.3d | Clear every JACK MIDI output buffer each cycle. | VERIFIED | Event process fixtures. |
| R10.3e | Obey output `try_push()` copy/lifetime rules, including SysEx. | VERIFIED | Event output fixture and generated callback audit. |
| R10.4a | Allocate event storage before activation. | VERIFIED | Event bridge construction and RT generated audit. |
| R10.4b | Handle at least 4,096 ordinary input events per cycle subject to JACK capacity. | VERIFIED | Fixed-capacity event boundary tests. |
| R10.4c | Reject/report capacity exhaustion without corruption, blocking, or allocation. | VERIFIED | Overflow/recovery fixture and RT tests. |

### 3.7 GUI and main-loop services (`REQUIREMENTS.md` 11)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R11.1a | Audio does not depend on GUI availability. | VERIFIED | Headless/audio fixture and live tests. |
| R11.1b | Attempt GUI by default after activation. | VERIFIED | GUI policy fixture and public composition. |
| R11.1c | Fall back headlessly with warning unless GUI is required. | VERIFIED | GUI policy fixture and source path. |
| R11.1d | Keep all plugin GUI calls on the stable CLAP main thread. | VERIFIED | GUI fixture thread assertions and Xvfb integration. |
| R11.1e | Follow CLAP GUI negotiation/create/parent/size/show/hide/destroy sequence. | VERIFIED | GUI fixture call-order tests. |
| R11.1f | Implement plugin show/hide/resize/closed requests. | VERIFIED | GUI controller fixture tests. |
| R11.1g | Keep GUI show/hide from changing audio state. | VERIFIED | GUI/audio lifecycle and live integration tests. |
| R11.1h | Alternate GUI on tray activation without recreating an existing surface. | VERIFIED | D-Bus tray integration and GUI controller tests. |
| R11.1i | Apply validated icon to X11 and tray. | VERIFIED | Icon, X11, and D-Bus tests. |
| R11.1j | Enforce PPM size/format/file bounds. | VERIFIED | Icon loader tests. |
| R11.1k | Use deterministic generic fallback icon. | VERIFIED | Icon tests and source policy. |
| R11.2a | Implement required X11 embedded/XEmbed path. | VERIFIED | X11 ABI, GUI fixture, and Xvfb integration. |
| R11.2b | Create/manage minimal top-level X11 window for embedded UI. | VERIFIED | X11 window-host integration. |
| R11.2c | Process X11/WM-close/resize/plugin-resize events. | VERIFIED | X11 and GUI controller tests. |
| R11.3a | Provide periodic monotonic timers allowing at least 30 Hz requests. | VERIFIED | Service registry accepts millisecond periods and tests periodic dispatch. |
| R11.3b | Integrate plugin FDs with level-triggered read/write/error notifications. | VERIFIED | Service registry and reactor tests. |
| R11.3c | Make timer/FD operations stale-ID and destruction safe. | VERIFIED | Generation/stale-token and service close tests. |
| R11.3d | Call timer/FD plugin methods only on main thread. | VERIFIED | Service fixture call context and source ownership. |
| R11.3e | Multiplex GUI, FDs, timers, signals, callbacks without busy-waiting. | VERIFIED | Reactor idle-wait and integration tests. |

### 3.8 State persistence (`REQUIREMENTS.md` 12)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R12.1 | `--load-state` fails clearly for unreadable files or missing `clap.state`. | VERIFIED | State codec and fixture failure tests. |
| R12.2 | State load uses bounded-error stream on main thread. | VERIFIED | State stream bounds and ordering fixtures. |
| R12.3 | `--save-state` fails clearly for missing `clap.state`. | VERIFIED | State fixture failure tests. |
| R12.4 | Save uses plugin `clap.state`, not synthesized parameters. | VERIFIED | State fixture call path. |
| R12.5 | Successful save is synchronized, same-directory temporary, and atomic rename. | VERIFIED | State codec transaction tests. |
| R12.6 | Failed save preserves existing destination. | VERIFIED | State rollback fixture tests. |
| R12.7 | Stream callbacks support partial I/O and reject invalid negative/error behavior. | VERIFIED | State codec stream tests. |
| R12.8 | Clean SIGINT/SIGTERM is a save opportunity; crash/uncatchable signal is not. | VERIFIED for clean signals | Public state integration; crash behavior is outside in-process recovery scope. |

### 3.9 Threading and realtime safety (`REQUIREMENTS.md` 13)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R13.1a | One stable OS thread serves as CLAP main thread for plugin lifetime. | VERIFIED | Host bridge thread-check, GUI, state, and live fixture evidence. |
| R13.1b | JACK process thread is symbolic CLAP audio thread. | VERIFIED | Audio-role guard and process fixtures. |
| R13.1c | `clap.thread-check` reports contexts accurately, including guarded transitions. | VERIFIED | Role/host bridge tests. |
| R13.1d | Never have two simultaneous symbolic audio threads. | VERIFIED | Audio-role guard contention tests and RT evidence. |
| R13.1e | Main/audio communication uses bounded lock-free queues or atomics with documented ownership. | VERIFIED | Atomic ABI, bridge, event, parameter, and source audit. |
| R13.2 | JACK and process-reachable callbacks perform none of the prohibited allocation, GC, managed-memory, I/O, blocking, sleep, lock, dynamic-library, lifecycle, logging, cleanup, or ownership operations. | VERIFIED | Complete generated callback audit, negative canary rejection, RT allocation/lock/I/O instrumentation, and live callback tests. |
| R13.3a | No exception, Defect, or foreign exception unwinds across C callbacks. | VERIFIED | Shared panic profile, callback-local checks policy, generated audit, negative canary. |
| R13.3b | Validate callback inputs/ports/events/timestamps before unchecked access. | VERIFIED | Event, port, callback safety, and malformed fixture tests. |
| R13.3c | Host callbacks use bounded storage/flags and realtime log overflow only increments a counter. | VERIFIED | Host bridge queue/overflow tests and RT instrumentation. |
| R13.3d | Render realtime-collected errors on the main thread later. | VERIFIED | Metrics/control-service tests. |

### 3.10 Nim, ABI, dependency, and platform constraints (`REQUIREMENTS.md` 14)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R14.1 | Production host logic is Nim. | VERIFIED | Source layout and build. |
| R14.2 | C is limited to ABI probes/build probes/FFI necessities, not alternate host implementation. | VERIFIED | Source review and build tasks. |
| R14.3 | Build through Nimble with documented release/build command. | VERIFIED for current build command | README and `nimble build`; release artifact command remains 11C work. |
| R14.4 | CI/release builds use supported Nim 2.x, reference 2.2.10. | VERIFIED | Current Nim 2.2.10 complete run. |
| R14.5 | Product/unit/fixture/ABI/RT builds share ARC, threads, panics, and disabled signal handlers. | VERIFIED | `config.nims`, build-profile tests, complete run. |
| R14.6 | Checks stay enabled in control tests; RT/callback code disables checks/traces only after validation. | VERIFIED | Source annotations, generated audit, RT tests. |
| R14.7 | No managed allocation on audio thread. | VERIFIED | RT allocator and live instrumentation. |
| R14.8 | C callbacks use exact calling convention and are non-capturing. | VERIFIED | ABI and generated callback tests. |
| R14.9 | Every used FFI type/signature has automated ABI checks. | VERIFIED for current used surface | CLAP/JACK/X11/D-Bus ABI suites. |
| R14.10 | Draft CLAP extensions are not in initial ABI surface. | VERIFIED | Vendored headers and binding surface audit. |
| R14.11 | Incomplete `nim-clap` bindings are not adopted without audit/completion. | VERIFIED | Project uses curated official bindings, not `nim-clap`. |
| R14.12 | Runtime/build dependencies and their licenses are documented. | DEFECTIVE | README documents core build requirements and argparse/CLAP licensing but lacks a complete runtime dependency/license matrix; 11C must close this. |
| R14.13 | Initial source build supports Linux x86_64. | VERIFIED | Current Linux x86_64 build and complete suite. |

### 3.11 Reliability, diagnostics, security, and statuses (`REQUIREMENTS.md` 15)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R15.1 | Every failure path leaves resources in a valid cleaned-up state. | VERIFIED for implemented covered paths; exhaustive matrix BLOCKED | Fixture rollback, repeated cleanup, integration resource checks pass; 11B must exercise every acquisition fault. |
| R15.2 | Cleanup is idempotent and shared with partial initialization. | VERIFIED | Loader/backend/GUI/state/session repeated-close tests. |
| R15.3 | Diagnostics identify subsystem and relevant path/ID. | VERIFIED | Typed errors, context tests, process tests, and 11A message sanitization. |
| R15.4 | Host logs go stderr and JSON data stdout. | VERIFIED | Command/scan/list fixture and process tests. |
| R15.5 | Plugin logs have severity and plugin identity prefixes. | VERIFIED | Host bridge/log tests; drained log output now sanitizes identity/text. |
| R15.6 | Repeated realtime warnings are rate-limited with suppressed/dropped count. | VERIFIED | New deterministic limiter tests and fixture shutdown-flush test. |
| R15.7 | Never silently select wrong multi-plugin descriptor. | VERIFIED | Plugin catalog selection tests. |
| R15.8 | Invalid plugin UTF-8 is safely replaced/escaped for display and naming. | VERIFIED | UTF-8, catalog, naming, diagnostic-message, and log sanitization tests. |
| R15.9 | Document native-code execution and unsafe plugin-thread/TLS/exit-handler unload risk. | VERIFIED | README Security section. |
| R15.10 | Do not claim crash isolation or sandboxing. | VERIFIED | README explicitly states no sandboxing/crash isolation; no source claim. |
| R15.11 | Document and test exact exit statuses. | VERIFIED | Frozen mapping plus subprocess assertions in `tests/fixtures/test_clap_audio.nim` cover statuses `0` through `6`; every case asserts exact exit code, empty stdout, and subsystem/context on stderr. |

### 3.12 Performance (`REQUIREMENTS.md` 16)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R16.1 | No full audio-buffer copy in normal float32 path. | VERIFIED | Zero-copy audio fixture and RT audit. |
| R16.2 | Per-cycle non-DSP work is linear in exposed channels plus events. | VERIFIED by bounded implementation review | Fixed maps/arenas and bounded callback audit; performance measurement remains 11C evidence. |
| R16.3 | Process path has no unbounded loops beyond bounded current buffers/events. | VERIFIED | Fixed-capacity source/RT audit. |
| R16.4 | Idle main loop blocks in event wait instead of polling. | VERIFIED | Reactor unit test and live runs. |
| R16.5 | GUI/state operations stay off realtime thread. | VERIFIED | GUI/state lifecycle and callback instrumentation. |
| R16.6 | Expose/log xruns and dropped MIDI/log/event counters outside process callback. | VERIFIED | Control metrics, warning limiter, and live instrumentation. |

### 3.13 Automated tests and release acceptance (`REQUIREMENTS.md` 17)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R17.1a | Unit coverage for CLI, selection, paths, names, state, events, ordering, overflow, lifecycle. | VERIFIED | Unit/fixture suites. |
| R17.1b | C-vs-Nim ABI tests for every used CLAP/JACK/X11/D-Bus surface. | VERIFIED | `nimble testAbi` within complete run. |
| R17.1c | Purpose-built controllable CLAP library with required behavior. | VERIFIED | Independent fixtures and fixture suite. |
| R17.1d | Disposable JACK integration and PipeWire-JACK evidence. | VERIFIED | Isolated live integration runs. |
| R17.1e | Debug bounds/overflow and generated-C sanitizer runs where practical. | BLOCKED | Existing bounds/RT generated audit passes; sanitizer/fault-injection expansion is 11B. |
| R17.1f | Complete RT generated-C audit with rejected negative canary. | VERIFIED | Complete run reports 49 callback/helper functions and rejected the allocation canary. |
| R17.1g | Live instrumentation proves zero host allocation/lock/print/prohibited I/O. | VERIFIED | RT and live callback instrumentation. |
| R17.1h | Repeated lifecycle/resource leak tests, including repeated same-DSO opens. | BLOCKED for exhaustive matrix | Existing repeated lifecycle evidence passes; 11B owns broader resource/fault matrix. |
| R17.2.1 | Synth acceptance scenario. | BLOCKED | Existing independent smoke is ZamComp effect-oriented; independent instrument acceptance is 11C. |
| R17.2.2 | Stereo effect acceptance scenario. | BLOCKED | Fixture/effect evidence exists; public independent-plugin acceptance matrix is 11C. |
| R17.2.3 | Multiple grouped audio/note ports. | VERIFIED | Multi-port fixture and port-plan tests. |
| R17.2.4 | Sample-offset MIDI input/output timing. | VERIFIED | Live multi-port MIDI/SysEx integration. |
| R17.2.5 | Embedded GUI, resize, signals, close/reopen, tray toggle while audio continues. | VERIFIED for fixtures/Xvfb; real-plugin manual row BLOCKED | Xvfb, D-Bus, GUI fixture, and live audio evidence pass; 11C owns manual independent GUI run. |
| R17.2.6 | Headless no-display audio/MIDI. | VERIFIED | Public headless and live integration runs. |
| R17.2.7 | GUI timer and POSIX-FD responsiveness. | VERIFIED | Service registry and GUI fixture tests. |
| R17.2.8 | GUI parameter flush/events/dirty state without deadlock. | VERIFIED | Parameter fixture tests. |
| R17.2.9 | Save/restart/load state and failed-save preservation. | VERIFIED | State fixture and public SIGTERM state integration. |
| R17.2.10 | Restart/rescan/buffer-size transition and silence/no-UAF. | VERIFIED | Audio/restart/quiescence fixtures and live stress. |
| R17.2.11 | JACK loss clear diagnostic, no callback cleanup, orderly non-zero exit. | VERIFIED | JACK shutdown/control and live integration tests. |
| R17.2.12 | Missing library/entry, invalid descriptor, init/activation/process errors. | VERIFIED | Loader, descriptor, lifecycle, audio, and process tests. |
| R17.2.13 | Sustained realtime zero prohibited operations. | VERIFIED | RT generated audit and live instrumentation. |
| R17.2.14 | Three independent Linux CLAP plugins including instrument and effect. | BLOCKED | Independent compatibility matrix belongs to 11C; local candidates are available but not release evidence yet. |

### 3.14 Delivery/documentation (`REQUIREMENTS.md` 18)

| ID | Requirement | Status | Evidence / gap |
|---|---|---|---|
| R18.1 | Source and reproducible Nimble build instructions. | VERIFIED | README and Nimble tasks. |
| R18.2 | README/manual covers every command, option, signal, status, and environment variable. | DEFECTIVE | Current README has commands and major behavior but not a complete option/environment/manual matrix; 11C owns closure. |
| R18.3 | Examples for synth, effect, headless, PID GUI control, state, and CLAP_PATH scanning. | DEFECTIVE | Current README lacks the complete requested example set; 11C owns closure. |
| R18.4 | Supported Linux architectures, Nim, CLAP, and JACK implementations documented. | BLOCKED | Current environment proves Linux x86_64/PipeWire-JACK; JACK1/JACK2 and aarch64 claims require 11C matrix/evidence. |
| R18.5 | Runtime/build dependency and license information. | DEFECTIVE | Complete dependency/license inventory and project-license decision remain open. |
| R18.6 | Native Wayland GUI limitations documented. | VERIFIED | README and requirements/design limitations. |
| R18.7 | Tray limitations without bus/watcher documented. | VERIFIED | README tray policy. |
| R18.8 | Icon policy documented. | VERIFIED | README and GUI policy tests. |
| R18.9 | In-process third-party native-code security warning documented. | VERIFIED | README Security section. |

## 4. Intentionally deferred SHOULD requirements

These are not failures of the 11A MUST contract:

| Requirement | Decision and owner |
|---|---|
| Default JACK name should be sanitized plugin name | Implemented current policy; exact JACK uniqueness remains server-managed. |
| Canonical `audio_in_N`/`audio_out_N` and `midi_in_N`/`midi_out_N` names | Implemented current naming policy. |
| CLAP channel names as aliases/metadata | Implemented where supported with bounded UTF-8 aliases. |
| Compatible external connection reconnection after structural rebuild | Implemented for exact compatible identities; richer reconnection remains post-MVP backlog. |
| `CLAP_PROCESS_SLEEP` wake policy | Implemented for covered event/input/request cases. |
| CLAP note output to MIDI 1.0 where representable | Current event implementation covers the supported reviewed subset; broader expression compatibility remains 11C evidence. |
| StatusNotifierItem registration when watcher exists | Implemented and tested under standard/KDE watcher fixtures. |
| Floating X11 GUI fallback | Implemented and tested. |
| Floating Wayland GUI without X11 | Deferred; native Wayland remains explicitly out of scope. |
| GUI window title including JACK client name | Current title follows the frozen plugin/format contract; richer title composition deferred. |
| Host no-event overhead measurement | Deferred to 11C reference-system performance report. |
| Linux aarch64 support | Deferred until ABI CI/architecture evidence exists. |
| Vendored stable CLAP headers | Implemented under `vendor/clap/` with provenance/license. |
| Minimal pinned JACK FFI rather than beta `jacket` | Implemented. |

## 5. DESIGN invariant audit (`DESIGN.md` §22)

| ID | Invariant | Status | Evidence / gap |
|---|---|---|---|
| D22.1 | Same OS thread remains CLAP main thread for plugin lifetime. | VERIFIED | Host bridge thread identity, GUI/state fixtures, live runs. |
| D22.2 | JACK quiescent before replacing/freeing RT snapshot, borrowed pointer, DSO, or plugin process resource. | VERIFIED | JACK quiescence/backend tests, restart fixtures, live stress. |
| D22.3 | Exactly one symbolic CLAP audio thread at a time. | VERIFIED | AudioRoleGuard unit/RT tests. |
| D22.4 | No allocation/deallocation, blocking lock, exception, cleanup, or diagnostic I/O in JACK callbacks. | VERIFIED | Generated-C audit, negative canary, C instrumentation, live callbacks. |
| D22.5 | C callback storage and strings outlive foreign users. | VERIFIED | ABI, host bridge, lifecycle, and DSO tests. |
| D22.6 | No exception/Defect crosses C ABI; checks disabled only after validation. | VERIFIED | Panic/check profile, callback audit, negative canary. |
| D22.7 | JACK loaded only through checked owned procedure table. | VERIFIED | JACK ABI/API ownership tests and ELF checks. |
| D22.8 | Every successful entry/plugin/GUI/JACK/file acquisition has matching cleanup. | VERIFIED for covered paths; exhaustive fault matrix BLOCKED | Existing rollback/repeated-close evidence; 11B owns all injected acquisition failures. |
| D22.9 | GUI state is independent from audio activation. | VERIFIED | GUI/audio fixture and live tests. |
| D22.10 | Tray activation is main/reactor-thread-only and cannot alter JACK activation/process. | VERIFIED | Tray D-Bus integration and controller/source boundary. |
| D22.11 | Tray/GUI resources close idempotently before reactor/plugin teardown. | VERIFIED | Controller, tray, GUI, and session close tests. |
| D22.12 | Input events globally sample-sort and output timestamps validate. | VERIFIED | Event fixture/live ordering and malformed tests. |
| D22.13 | SysEx pointers never retained past specified lifetime. | VERIFIED | Event fixture/live SysEx and generated callback audit. |
| D22.14 | Structural port changes only while JACK quiescent and CLAP deactivated. | VERIFIED | Rescan/restart fixtures and source sequencing. |
| D22.15 | Unsupported capabilities explicit, not silently approximated. | VERIFIED | Null extension queries, MIDI2 rejection, transport limitation, GUI policy tests. |
| D22.16 | Raw external API types do not leak into application/domain policy. | VERIFIED | Source layout/import boundaries and ABI adapter tests. |
| D22.17 | New backend/plugin format can be a sibling adapter. | VERIFIED | Source layout and dependency-direction review. |

## 6. 11B hardening handoff

The following machine-readable cases remain required before treating Increment
11 as release-ready:

```json
[
  {"id":"H-01","area":"ownership","target":"all acquisition boundaries","case":"inject each CLAP/JACK/reactor/X11/D-Bus/PID/state acquisition failure","expected":"typed failure, independent cleanup, repeated close succeeds"},
  {"id":"H-02","area":"metadata","target":"loader, catalog, port inspector","case":"bounded malformed descriptors, port counts, lengths, UTF-8, feature data, and path inputs","expected":"reject safely without unbounded work or false success"},
  {"id":"H-03","area":"events","target":"event_bridge and parameter_transport","case":"malformed headers, sizes, pointers, ports, timestamps, dialects, overflow, and repeated recovery","expected":"bounded rejection, counters, no callback allocation/logging"},
  {"id":"H-04","area":"reactor","target":"plugin_services and main_reactor","case":"stale/reused timer and FD tokens during reentrant unregister/close","expected":"no dispatch to removed resource; cleanup remains idempotent"},
  {"id":"H-05","area":"lifecycle","target":"session, DSO, JACK, GUI, tray, state","case":"deterministic repeated load/start/restart/show/hide/save/shutdown/unload loops","expected":"no host-owned FD, mapping, port, timer, GUI, PID, or temporary-file leak"},
  {"id":"H-06","area":"sanitizer","target":"generated C and process-reachable callbacks","case":"ASan/UBSan runs under the shared product profile","expected":"pass with no unexplained host-owned finding"},
  {"id":"H-07","area":"resource","target":"host-owned allocations and files","case":"Valgrind/resource checks with external plugin/JACK/X11/D-Bus ownership separated","expected":"no unexplained host-owned leak or stale resource"},
  {"id":"H-08","area":"audit","target":"tests/rt/generated_audit_target.nim","case":"retain and execute the prohibited-operation negative canary","expected":"audit rejects the canary"},
  {"id":"H-09","area":"contract","target":"commands and HostError.exitCode","case":"fault-injected cleanup/internal precedence, repeated shutdown, and diagnostic aggregation beyond the baseline status subprocess cases","expected":"stable status mapping, stderr diagnostics, clean stdout, and no duplicate aggregate"}
  {"id":"H-10","area":"foreign_threads","target":"host callbacks and teardown","case":"repeated C-created-thread requests/logging during orderly shutdown","expected":"no race, unwind, allocation, or use-after-free"}
]
```

11B must not change these public status meanings or warning semantics without a
focused defect report and owner review.

## 7. Exact verification evidence

Executed after the 11A changes:

```text
nimble test
```

Exit `0`. Fast unit suites passed, including the 11A warning, diagnostic
sanitization, and typed exit-mapping cases. Fixture process tests cover the
remaining public status paths.

```text
nimble testFixtures
```

Exit `0`. All synthetic CLAP/JACK fixture suites passed, including the actual
`HostSession` warning rate-limit, shutdown aggregate, and quiet-mode cases.

The four subprocess cases use a five-second `waitForExit` guard. They cover
the invalid PID-file parent after fake-JACK startup, an invalid
`libjack.so.0` placed first in `LD_LIBRARY_PATH`, `--require-gui` with
`DISPLAY` and `WAYLAND_DISPLAY` removed, and missing/directory state inputs
against the state-capable fixture. Every case asserts the exact status, empty
stdout, and subsystem/path context on stderr.

```text
env PLUGINHOST_CLAP_SMOKE_PLUGIN=/usr/lib/clap/ZamComp.clap nimble testIntegration
```

Exit `0`. Prerequisite-failure detection passed; all four isolated PipeWire-
JACK scenarios passed: public signal/PID/state control, independent CLAP audio
smoke, live MIDI/SysEx events, and live PipeWire-JACK backend instrumentation.

```text
env PLUGINHOST_CLAP_SMOKE_PLUGIN=/usr/lib/clap/ZamComp.clap nimble all
```

Exit `0`. Complete compile, unit, ABI, RT, fixture, live integration, Xvfb,
and D-Bus suites passed. The run retained generated callback auditing and
rejected the prohibited allocation canary. Updated case accounting is **267
passing cases, zero failures**: 139 unit, 32 ABI, 9 RT, 77 fixture, 6 live
integration, and 4 GUI/D-Bus cases.

## 8. Manual verification recipe

Run from the repository root with the build prerequisites installed:

```text
nimble build
./pluginhost --version
./pluginhost --help
env PLUGINHOST_CLAP_SMOKE_PLUGIN=/usr/lib/clap/ZamComp.clap nimble testIntegration
nimble testGui
```

Confirm that `--version` and `--help` write only to stdout with exit `0`.
For a live headless run, use the integration harness or launch the built
binary under the disposable PipeWire-JACK environment with `--no-gui`,
`--pid-file`, and the fixture/plugin path. Send `SIGUSR1` twice within one
second, then `SIGUSR2`, then `SIGTERM`; confirm the GUI-disabled warnings
remain on stderr, the repeated show warnings aggregate with a suppressed count
on shutdown, stdout remains empty,
the process exits `0`, and the PID file is removed. Use a fixture state path
with `--load-state` and `--save-state` to confirm clean shutdown state
serialization. Do not interpret a missing JACK1/JACK2, display, or session-bus
prerequisite as a pass.

## 9. Changed files


- `src/pluginhost/support/diagnostics.nim` — warning-key limiter, deterministic
  report/flush API, diagnostic message sanitization.
- `src/pluginhost/app/host_session.nim` — control-plane limiter integration,
  quiet-mode warning guards, sanitized plugin logs, explicit diagnostic-stream
  close overload, shutdown warning flush.
- `src/pluginhost/domain/errors.nim` — removed obsolete `NotImplemented`
  category/helper while preserving frozen exit mapping.
- `src/pluginhost/app/commands.nim` — close run sessions using the selected
  diagnostic stream.
- `tests/unit/test_errors.nim` — status, limiter, flush, interval, and message
  sanitization behavior tests.
- `tests/fixtures/test_clap_audio.nim` — actual session rate-limit,
  shutdown-flush, quiet-mode, and subprocess status-contract tests.
- `tests/fixtures/jack/fake_jack_fixture.c` — test-only constructor initializes
  the existing fake JACK behavior for subprocess loading.
- `MVP_IMPLEMENTATION_PLAN.md` — corrected approved Increment 10 markers,
  marked 11A in progress, and removed the obsolete generic NotImplemented rule.
- `docs/release/11A-contract-audit.md` — this report.

No generated source, vendored source, ABI probe, or dependency changed.
`build/` and Nim cache outputs are transient verification artifacts only.

## 10. Unresolved risks and review decisions

1. JACK1/JACK2 compatibility is not tested because separate implementations
   are unavailable; PipeWire-JACK alone is not a substitute release claim.
2. Full sanitizer/fault-injection/resource evidence belongs to 11B.
3. Independent instrument/effect compatibility, performance measurement, full
   README/manual closure, release artifact preparation, and license inventory
   belong to 11C.
4. The project license remains unselected. No distributability claim is made.
5. Requirements and design documents remain marked draft; this report audits
   implementation against them but does not silently promote them to approved
   product scope.
6. The report's VERIFIED rows rely on the current controlled fixtures and
   tested Linux x86_64/PipeWire environment; hostile third-party plugin
   behavior remains an explicit trust boundary.

## 11. Proposed next increment

After explicit Human approval of 11A, begin **11B — Fault injection, hostile
inputs, and sanitizer evidence** using the remaining hardening cases in
Section 6. The baseline process status/stdout/stderr contract is already
verified; 11B must extend it only for injected cleanup, precedence, and
resource variants. Do not begin 11B until this review gate is approved.
