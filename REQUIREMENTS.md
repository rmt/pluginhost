# Standalone CLAP/JACK Plugin Host — Product Requirements

**Status:** Draft for review  
**Working product/binary name:** `pluginhost`  
**Initial platform:** Linux  
**Implementation language:** Nim  
**Research baseline:** CLAP 1.2.10 and the JACK client API, reviewed 2026-08-18

## 1. Product summary

`pluginhost` is a small standalone command-line host that loads exactly one native CLAP plugin instance and exposes it as a JACK client. Its intended role is similar to `carla-single`, but with a narrow Linux/JACK/CLAP scope and a Nim implementation.

The initial product must support:

- JACK MIDI input to an instrument or MIDI-capable plugin.
- JACK audio output from the plugin.
- JACK audio input and JACK MIDI output when the plugin provides them, so effects and MIDI processors also work.
- Showing and hiding the plugin's native GUI without stopping audio processing.
- Optional loading and saving of CLAP plugin state.
- Correct CLAP lifecycle, event, thread, and real-time behavior.

Each process hosts one plugin instance and owns one JACK client. Users can run multiple processes for multiple plugins.

## 2. Goals

1. Make a native Linux CLAP plugin usable as a standalone JACK application with one command.
2. Preserve JACK's sample-accurate MIDI timing and low-latency audio behavior.
3. Provide enough CLAP host extensions for native plugin GUIs and parameter changes to work reliably.
4. Be scriptable, predictable, and suitable for launch by shell scripts or Linux audio session managers.
5. Keep the host substantially smaller and simpler than a DAW or general-purpose host such as Carla.
6. Implement the host in idiomatic Nim while preserving C ABI correctness and real-time safety.

## 3. Non-goals for the initial release

- Hosting more than one plugin instance in a process.
- Plugin chains, mixing, routing, patchbay, or rack functionality.
- VST, LV2, LADSPA, DSSI, AU, or Windows plugin support.
- Bridging, sandboxing, or running a plugin in a separate process.
- A generic host-generated parameter editor.
- Parameter automation recording or playback.
- MIDI learn or host-managed MIDI CC-to-parameter mapping.
- JACK transport synchronization or tempo/time-signature delivery. The initial host supplies a null CLAP transport pointer and acts as a free-running host.
- Automatic JACK port connections. Connections are managed by the user, JACK tooling, or a session manager.
- Offline rendering.
- MIDI 2.0 or lossless conversion of all CLAP note-expression events to MIDI 1.0.
- Native embedded Wayland plugin windows; the stable CLAP GUI API does not support Wayland embedding.
- Recovery from arbitrary plugin crashes or memory corruption. Plugins execute trusted native code in the host process.

## 4. Terminology and requirement levels

- **MUST**: required for the initial usable release.
- **SHOULD**: expected unless implementation evidence justifies deferral.
- **MAY**: optional.
- A **CLAP audio port** may contain multiple channels. A **JACK audio port** is one mono float32 channel.
- A JACK port's direction is from the JACK client's perspective. Plugin inputs become JACK input ports; plugin outputs become JACK output ports.

## 5. Primary user stories

### 5.1 Instrument

As a musician, I can launch a CLAP synthesizer, connect a JACK MIDI source to it, connect its JACK audio outputs to a destination, and use the plugin's native GUI.

### 5.2 Audio effect

As a musician, I can launch a CLAP effect and connect JACK audio to its inputs and its outputs to another JACK client.

### 5.3 Headless/session-managed use

As a user or session manager, I can launch the plugin with its GUI initially hidden or disabled, show or hide the GUI later, load saved state, and stop the process cleanly.

### 5.4 Plugin selection

As a user, I can inspect a `.clap` library containing multiple descriptors and select an instance by stable CLAP plugin ID.

## 6. Command-line interface

### 6.1 Required commands

```text
pluginhost [run-options] PLUGIN_PATH
pluginhost list [--json] PLUGIN_PATH
pluginhost scan [--json] [DIRECTORY ...]
pluginhost --help
pluginhost --version
```

`run` MAY also be accepted as an optional explicit subcommand, but the path-only form above is canonical.

### 6.2 Run options

The initial CLI MUST provide:

```text
--plugin-id ID          Select a descriptor by its stable CLAP ID
--plugin-index N        Select a descriptor by zero-based bundle index
--client-name NAME      Requested JACK client name
--jack-server NAME      Connect to a named JACK server
--no-start-server       Do not allow libjack to start a server
--show-gui              Show the plugin GUI after startup (default)
--hide-gui              Start with the GUI hidden, but permit later display
--no-gui                Do not create or advertise GUI hosting for this run
--require-gui           Fail startup if a usable plugin GUI cannot be shown
--gui-scale FACTOR      Request an explicit positive X11 GUI scale
--load-state FILE       Load CLAP state before activation
--save-state FILE       Atomically save CLAP state on clean shutdown
--pid-file FILE         Atomically write the running PID and remove it on exit
-v, --verbose           Enable diagnostic logging
-q, --quiet             Suppress non-error host messages
-h, --help              Print help and exit successfully
-V, --version           Print product, Nim, CLAP SDK, and build versions
```

Requirements:

- Options with invalid or missing values MUST produce a concise diagnostic, usage hint, and non-zero exit status.
- `--plugin-id` and `--plugin-index` MUST be mutually exclusive.
- If a library has one plugin descriptor, selection MAY be omitted.
- If a library has multiple descriptors and selection is omitted, startup MUST fail and list the available indices, IDs, and names.
- The default JACK client name SHOULD be a sanitized form of the plugin name. JACK may make it unique unless exact naming is added later.
- Relative paths MUST be resolved before calling the CLAP entry point's `init()` function. The exact library or bundle path MUST be supplied to `init()`.
- `list` MUST report index, ID, name, vendor, version, and features without creating a plugin instance.
- `--json` output MUST be valid JSON and contain no human-readable prefixes or diagnostics on standard output.

### 6.3 Discovery

`scan` MUST recursively inspect:

- `~/.clap`
- `/usr/lib/clap`
- Every directory in `CLAP_PATH`, split using `:` on Linux
- Explicit directories supplied to `scan`

Scanning requirements:

- Candidate files or bundles end in `.clap`.
- Explicit directories take precedence; otherwise standard paths and `CLAP_PATH` are used.
- Duplicate canonical paths and symlink directory loops MUST be avoided.
- A failure in one candidate MUST be reported and MUST NOT prevent remaining candidates from being scanned.
- Each successfully initialized entry MUST receive a matching `deinit()` before unloading.
- Scanning runs plugin-provided native code. This security and stability fact MUST be documented.

A persistent plugin cache is not required initially.

### 6.4 Runtime process control

- `SIGINT` and `SIGTERM` MUST request orderly shutdown.
- `SIGUSR1` MUST request that the GUI be shown.
- `SIGUSR2` MUST request that the GUI be hidden.
- Show and hide operations MUST be idempotent.
- POSIX signal handlers MUST only perform async-signal-safe notification, such as setting an atomic flag and waking the main loop through a self-pipe/eventfd. They MUST NOT call CLAP, JACK, X11, memory allocation, or logging APIs directly.
- Closing the GUI window MUST hide/destroy the GUI as required by the plugin, but MUST NOT stop audio or terminate the host.
- A request to show a GUI after it was closed MUST recreate it when the plugin permits recreation.
- `SIGUSR1` under `--no-gui` MUST be ignored with a rate-limited warning.

## 7. CLAP loading and lifecycle

### 7.1 Library loading

The host MUST:

1. Load the native `.clap` shared object.
2. Resolve the exported `clap_entry` data symbol.
3. Validate version compatibility using the official CLAP compatibility rules.
4. Call `clap_entry.init()` before any other symbol from the plugin library.
5. Obtain `CLAP_PLUGIN_FACTORY_ID` and enumerate descriptors.
6. Validate mandatory descriptor fields before displaying or using them.
7. Create the selected plugin with a host object that remains valid through plugin destruction.
8. Call `plugin.init()` on the main thread.
9. Query plugin extensions only after or during successful `plugin.init()`.
10. Load requested state while on the main thread and before audio activation.
11. Discover audio and note ports while the plugin is deactivated.
12. Set `CLAP_RENDER_REALTIME` when the plugin implements the render extension.
13. Activate using JACK's sample rate and a frame range that includes every JACK process block the host will deliver.
14. Call `start_processing()` in the symbolic CLAP audio-thread context before the first `process()` call.

### 7.2 Shutdown order

On orderly shutdown, the host MUST ensure no process callback can race teardown, then perform the applicable operations in valid CLAP thread/state contexts:

1. Stop processing.
2. Save requested plugin state.
3. Hide and destroy the GUI.
4. Deactivate the plugin.
5. Destroy the plugin.
6. Call the matching entry `deinit()`.
7. Unload the shared object.
8. Close the JACK client and remove transient files such as the PID file.

The exact ordering of state save and JACK deactivation MAY differ if required for safe serialization, but state save MUST occur on the CLAP main thread while the plugin object is valid.

### 7.3 Host requests and restart

The host MUST correctly implement:

- `clap_host.request_restart()`
- `clap_host.request_process()`
- `clap_host.request_callback()`

Requirements:

- Calls may originate on arbitrary threads and MUST be thread-safe and non-blocking.
- `request_callback()` MUST cause `plugin.on_main_thread()` to run promptly on the main thread, normally within 33 ms when the host is not overloaded.
- Restart MUST stop processing, deactivate, rescan invalidated configuration, reactivate, and resume without unloading the plugin.
- Audio output MUST be silence while a restart is pending or incomplete.
- JACK sample-rate or maximum-buffer-size changes MUST schedule a safe CLAP reactivation; main-thread-only CLAP methods MUST NOT be invoked directly from JACK notification callbacks.
- A failed activation, reactivation, or `start_processing()` MUST produce a clear error and leave outputs silent.

### 7.4 Processing status

- `CLAP_PROCESS_ERROR` MUST discard/zero that cycle's output and schedule an orderly non-zero termination.
- The host SHOULD honor `CLAP_PROCESS_SLEEP`, waking for incoming events, relevant audio input, or `request_process()`.
- The host MAY continue processing when audio inputs are connected rather than scan buffers to prove silence.
- `steady_time` MUST begin at a non-negative value and advance by at least the processed frame count on every call.
- The initial release MUST pass `transport = nil`.

## 8. Required CLAP extension support

### 8.1 Plugin extensions consumed by the host

The host MUST consume these extensions when provided:

- `clap.audio-ports`
- `clap.note-ports`
- `clap.gui`
- `clap.params`
- `clap.state`
- `clap.latency`
- `clap.render`
- `clap.timer-support`
- `clap.posix-fd-support`

The absence of an optional extension MUST be handled without dereferencing null pointers or failing unrelated functionality.

### 8.2 Host extensions exposed to plugins

The initial host MUST implement:

- `clap.gui` when GUI hosting is enabled
- `clap.params`
- `clap.state`
- `clap.latency`
- `clap.audio-ports`
- `clap.note-ports`
- `clap.log`
- `clap.timer-support`
- `clap.posix-fd-support`
- `clap.thread-check`

The host MAY initially omit thread-pool, preset discovery, remote controls, context menus, track info, surround, ambisonic, and all draft extensions. Unsupported extension queries MUST return null.

### 8.3 Parameters and output events

Even though there is no generic parameter UI, the host MUST:

- Implement `clap_host_params.request_flush()` and schedule either `process()` or `clap_plugin_params.flush()` in the correct context.
- Ensure `flush()` never runs concurrently with `process()`.
- Accept parameter value, modulation, and gesture events emitted by the plugin.
- Track dirty state when plugin state or parameter values change.
- Handle parameter rescans and cookie invalidation according to the flags.
- Never invent parameter persistence when the plugin lacks `clap.state`.
- Process output events without allocation in the real-time callback.
- Return `false` from output-event `try_push()` for unsupported or invalid events, without logging directly from the audio thread.

## 9. JACK integration

### 9.1 Compatibility

- The host MUST use the JACK client API exposed by `libjack.so.0`.
- It MUST work with JACK1, JACK2, and PipeWire's JACK-compatible implementation where they provide the standard client ABI.
- A JACK server is required at run time unless libjack successfully starts one.
- Failure to connect MUST identify the requested client/server and summarize the JACK status flags.
- JACK shutdown MUST schedule orderly host termination; cleanup MUST NOT be attempted directly in the JACK shutdown callback.

### 9.2 JACK callbacks

Before activating the JACK client, the host MUST register:

- Process callback
- Shutdown/info-shutdown callback
- Buffer-size callback
- Sample-rate callback
- Latency callback when needed for plugin latency reporting

The host MUST query the initial sample rate and buffer size before CLAP activation.

### 9.3 Audio ports

- Every channel of every CLAP audio input and output port MUST be represented by one JACK `JACK_DEFAULT_AUDIO_TYPE` port.
- CLAP port grouping and channel order MUST be preserved internally in the `clap_audio_buffer` arrays.
- JACK buffers MUST be passed to the plugin as float32 channel pointers without a full-buffer copy whenever possible.
- `data64` MUST be null in the initial release. CLAP requires plugins to support float32 processing.
- Port names MUST be deterministic, unique within the client, legal for JACK, and short enough for the server's reported name limit.
- Canonical short names SHOULD follow `audio_in_N` and `audio_out_N`, using one-based flattened channel numbers.
- CLAP port/channel names SHOULD be exposed as JACK aliases or metadata when supported.
- If registration of any required port fails, startup MUST fail and unregister already-created ports.
- Before each call to `process()`, output buffers MUST be in a defined state. When processing is skipped or fails, all JACK audio output buffers MUST contain zeroes.
- The host MUST provide correct CLAP audio-buffer counts, channel counts, and pointer lifetimes for the duration of `process()`.
- The host SHOULD set input `constant_mask` bits for known disconnected zero-filled channels; it MUST NOT claim a connected buffer is constant without proving it.

### 9.4 Dynamic audio configuration

- The host MUST support audio-port name rescans while allowed by CLAP.
- Structural audio-port changes MUST use the restart/deactivate path before JACK ports are rebuilt.
- Lost external JACK connections caused by a structural port rebuild MUST be logged.
- Preserving and reconnecting compatible external connections after a rebuild is a SHOULD requirement.
- The initial host uses the plugin's current/default audio-port configuration; a UI for selecting `audio-ports-config` entries is not required.

### 9.5 Latency

- When the plugin implements `clap.latency`, its reported processing latency MUST be reflected in JACK latency ranges.
- `clap_host_latency.changed()` MUST schedule a safe latency refresh/restart as required by CLAP.
- Latency updates MUST not occur through unsafe operations in the process callback.

## 10. MIDI and note event requirements

### 10.1 JACK MIDI ports

- Every CLAP note input/output port MUST map to one JACK `JACK_DEFAULT_MIDI_TYPE` input/output port.
- Canonical names SHOULD follow `midi_in_N` and `midi_out_N`.
- The host MUST expose its supported CLAP note dialects through `clap_host_note_ports`.
- The initial host MUST support CLAP note and MIDI 1.0 dialects. MIDI 2.0 is not required.

### 10.2 JACK-to-CLAP input

- JACK MIDI events MUST be presented to CLAP in ascending sample-offset order.
- Event timestamps MUST be preserved exactly within the current JACK period.
- Live JACK input MUST set `CLAP_EVENT_IS_LIVE`.
- For a note port supporting the MIDI dialect, normalized MIDI messages of up to three bytes MUST use `CLAP_EVENT_MIDI`.
- System-exclusive input MUST use `CLAP_EVENT_MIDI_SYSEX`, preserving the complete JACK-provided event or chunk and its process-call lifetime.
- For a port supporting only the CLAP dialect, note-on, note-off, and polyphonic pressure MUST be translated to the corresponding CLAP note/note-expression events where semantics are well-defined.
- MIDI messages with no safe representation in the selected dialect MUST be dropped safely and counted for a rate-limited main-thread warning.
- MIDI Note On with velocity zero MUST retain raw MIDI semantics when passed as raw MIDI; when translated to CLAP notes it MUST be translated as MIDI Note Off.

### 10.3 CLAP-to-JACK output

- `CLAP_EVENT_MIDI` and `CLAP_EVENT_MIDI_SYSEX` MUST be copied immediately into the corresponding JACK MIDI output buffer with the event timestamp preserved.
- CLAP note-on and note-off events SHOULD be translated to MIDI 1.0 when values are representable.
- Unsupported note expressions, MIDI 2.0 events, invalid port indices, out-of-order timestamps, or events that do not fit in the JACK buffer MUST fail safely and increment a drop/error counter.
- Each JACK MIDI output buffer MUST be cleared at the start of its process cycle.
- Plugin output-event `try_push()` MUST obey CLAP's copy/lifetime rules, including immediate copying of SysEx data.

### 10.4 Capacity and overload behavior

- Event storage used during processing MUST be allocated before JACK activation.
- The initial implementation MUST handle at least 4,096 ordinary input events per JACK cycle without allocation or loss, subject to the JACK buffer's own capacity.
- Capacity exhaustion MUST never corrupt memory, block, or allocate. Excess events MUST be rejected/dropped and reported later from the main thread.

## 11. Plugin GUI requirements

### 11.1 General behavior

- Audio operation MUST not depend on GUI availability.
- By default, the host MUST attempt to show the plugin GUI after successful activation.
- GUI creation failure MUST fall back to headless operation with a warning unless `--require-gui` was supplied.
- All plugin GUI API calls MUST occur on the same CLAP main thread used for the plugin lifetime.
- The host MUST follow the CLAP GUI sequence for API negotiation, creation, parent/transient setup, size negotiation, show/hide, and destruction.
- The host MUST implement plugin requests to show, hide, resize, and report closure.
- Show/hide MUST not activate, deactivate, reset, or interrupt audio processing.
- The window title SHOULD contain the plugin name and JACK client name.

### 11.2 X11 and Wayland

- X11 embedded GUI hosting through `CLAP_WINDOW_API_X11` and XEmbed is the required initial GUI path.
- The host MUST create and manage a minimal top-level X11 window for an embedded plugin UI.
- The host MUST process X11 events, WM close events, resize constraints, and plugin-requested resize operations.
- The host SHOULD try a plugin-supported floating X11 GUI if embedded X11 is unsupported.
- Under a Wayland desktop with XWayland available, X11/XEmbed remains the required compatibility path.
- A plugin-supported floating `CLAP_WINDOW_API_WAYLAND` GUI SHOULD be supported when no X11 path is available.
- Native Wayland embedding is explicitly out of scope because the stable CLAP GUI contract describes Wayland as floating-only.

### 11.3 Main-loop services needed by GUIs

- `clap.timer-support` MUST provide periodic monotonic timers and allow at least 30 Hz callbacks.
- `clap.posix-fd-support` MUST integrate plugin FDs into the main-thread poll loop with level-triggered read, write, and error notifications.
- Timer and FD registration, modification, and removal MUST be safe against stale IDs/FDs and GUI destruction.
- Timer and FD callbacks MUST call plugin methods only on the main thread.
- The main loop MUST multiplex GUI events, plugin FDs, timers, signals, and pending CLAP callbacks without busy-waiting.

## 12. State persistence

- `--load-state` MUST fail clearly if the file cannot be read or if the plugin lacks `clap.state`.
- State load MUST use a bounded-error CLAP input stream and occur on the main thread.
- `--save-state` MUST fail clearly if the plugin lacks `clap.state`.
- State save MUST use the plugin's `clap.state` extension rather than synthesizing state from parameter values.
- Successful save MUST be atomic: write a temporary file in the destination directory, flush/close it, then rename it over the target.
- A failed save MUST leave an existing destination file unchanged.
- State stream callbacks MUST correctly support partial reads/writes and reject invalid negative/error behavior.
- Clean shutdown caused by `SIGINT` or `SIGTERM` counts as an opportunity to save. An uncatchable signal or plugin crash does not.

## 13. Threading and real-time safety

### 13.1 Thread model

- One stable OS thread MUST serve as the CLAP main thread for the plugin's complete lifetime.
- The JACK process thread is the CLAP audio-thread while it calls audio-thread methods.
- `clap.thread-check` MUST report these contexts accurately, including any guarded transition used to call `start_processing()` or `stop_processing()`.
- A plugin instance MUST never have two simultaneous symbolic audio threads.
- Main/audio communication MUST use bounded lock-free queues or atomics with documented ownership.

### 13.2 Prohibited process-callback operations

The JACK process callback and every host callback reachable from plugin `process()` MUST NOT perform:

- Heap allocation or deallocation
- Nim GC activity
- Managed string, sequence, table, closure, or exception operations that may allocate or release memory
- File, console, X11, or network I/O
- Blocking system calls
- Sleeping or waiting
- Contended mutex acquisition
- Dynamic library operations
- Plugin activation, deactivation, destruction, GUI operations, or state serialization
- Direct logging to stdout/stderr

Allowed operations must be bounded and deterministic. JACK's documented real-time-safe buffer and MIDI functions may be used.

### 13.3 Fault handling in callbacks

- No Nim or foreign exception may cross a C callback boundary.
- Callback inputs, port indices, event sizes, and timestamps MUST be validated without unbounded work.
- Host callbacks such as logging and restart requests MUST use bounded preallocated storage or lock-free flags.
- Real-time log queue overflow MUST increment a counter rather than block or allocate.
- Errors collected in real time MUST be rendered by the main thread later.

## 14. Nim and implementation constraints

- Production host logic MUST be written in Nim.
- Small C files MAY be used only for ABI assertions, build probes, or functionality that cannot be expressed safely through Nim's FFI; they MUST NOT become an alternate host implementation.
- The project MUST build through Nimble with a documented release command.
- CI and release builds MUST use a supported Nim 2.x compiler; Nim 2.2.6 is the initial reference compiler.
- Release builds SHOULD use ARC (`--mm:arc`) unless measurement demonstrates another memory manager is equally safe. No managed allocation is permitted on the audio thread regardless of memory manager.
- Thread support MUST be enabled where required for foreign JACK callbacks and atomics.
- C callback functions MUST use the exact CLAP/JACK calling convention and be non-capturing.
- Every CLAP/JACK struct used across the FFI MUST have automated size, alignment, field-offset, enum-width, and function-pointer ABI checks against the official C headers on each supported architecture.
- The stable CLAP 1.2.10 headers SHOULD be vendored or pinned reproducibly under their MIT license. Draft extensions MUST not be included in the initial host ABI surface.
- Existing `nim-clap` bindings are incomplete and identify CLAP 1.2.0 as their tested baseline. They MUST NOT be adopted without an ABI/API audit and completion of required host extensions.
- The `jacket` package is a beta dynamic wrapper around libjack. It MAY be used after an API/real-time audit; otherwise the project SHOULD maintain a minimal, pinned JACK FFI for only the required client API.
- Runtime dependencies and their licenses MUST be documented. At minimum, the host expects `libjack.so.0`; GUI builds may require X11/Xlib or XCB libraries.
- The initial source build MUST support Linux x86_64. Linux aarch64 SHOULD be supported once ABI CI is available.

## 15. Reliability, diagnostics, and security

- Every failure path MUST leave JACK ports, plugin objects, GUI resources, entry initialization, dynamic libraries, files, and PID files in a valid cleaned-up state.
- Cleanup MUST be idempotent so partial initialization can use the same teardown path.
- Diagnostics MUST identify the failing subsystem (`CLI`, `CLAP`, `JACK`, `GUI`, or `state`) and include plugin path/ID where relevant.
- Host logs go to standard error. Data requested as JSON goes to standard output.
- Plugin-provided log messages MUST be prefixed with severity and plugin identity.
- Repeated real-time warnings MUST be rate-limited and include a suppressed/dropped count.
- The host MUST never silently select the wrong descriptor from a multi-plugin library.
- Invalid UTF-8 from a misbehaving plugin MUST be escaped or replaced safely for display and port naming.
- The documentation MUST warn that loading or scanning a CLAP plugin executes third-party native code with the user's permissions.
- The host MUST not claim crash isolation or sandboxing.

Suggested exit statuses:

- `0`: clean exit or successful information command
- `2`: command-line usage or plugin-selection error
- `3`: CLAP load, compatibility, initialization, or processing failure
- `4`: JACK connection, registration, activation, or shutdown failure
- `5`: required GUI failure
- `6`: requested state load/save failure

Exact values may change before the CLI is declared stable, but they MUST be documented and tested.

## 16. Performance requirements

- The host MUST add no full audio-buffer copy in the normal float32 path.
- Per-cycle work outside plugin DSP MUST be linear in the number of exposed channels plus MIDI/events for that cycle.
- The process path MUST contain no unbounded loops other than bounded traversal of current JACK buffers/events.
- The idle main loop MUST block in an event wait rather than poll continuously.
- GUI show/hide and state operations MUST not run in the real-time thread.
- With no MIDI events and a fixed port configuration, host overhead SHOULD be measured and documented on a reference system before release.
- The host MUST expose or log JACK xruns and its own dropped MIDI/log/event counters outside the process callback.

## 17. Testing and acceptance criteria

### 17.1 Automated tests

The project MUST include:

- Unit tests for CLI parsing, descriptor selection, path discovery, name sanitization, state streams, event conversion, ordering, overflow, and lifecycle state transitions.
- C-vs-Nim ABI conformance tests for every imported CLAP and JACK type used by the host.
- A purpose-built test CLAP library with multiple descriptors and controllable audio, MIDI, state, parameter, restart, timer, FD, and GUI behavior.
- Integration tests against a disposable JACK server/dummy backend.
- Tests with PipeWire's JACK implementation in CI or a documented pre-release test matrix.
- Debug builds with bounds/overflow checks where compatible, and sanitizer runs over generated C code where practical.
- A test or instrumentation mode proving the host itself does not allocate, lock, print, or perform prohibited I/O in the process path.
- Repeated load/start/show/hide/stop/unload tests to detect lifecycle and resource leaks.

### 17.2 Release acceptance scenarios

The initial release is accepted only when all of these pass:

1. **Synth:** Launch a known CLAP synthesizer, observe its JACK MIDI input and all audio outputs, send timestamped JACK MIDI notes, and capture non-zero audio on the expected channels.
2. **Effect:** Launch a stereo CLAP effect, connect generated JACK audio to it, and verify processed stereo output.
3. **Multiple ports:** Use a fixture with multiple grouped audio and note ports and verify counts, direction, ordering, and naming.
4. **MIDI timing:** Verify events at multiple offsets in one JACK period reach the plugin at the same offsets and plugin MIDI output retains offsets.
5. **GUI:** Show the embedded X11 GUI, resize it, hide with `SIGUSR2`, show with `SIGUSR1`, close and reopen it, all while audio continues.
6. **Headless:** Run with `--no-gui` without an X display and process audio/MIDI normally.
7. **GUI services:** Verify a test GUI using CLAP timers and POSIX FD support remains responsive.
8. **Parameters:** Change a control in the plugin GUI and verify `request_flush`, parameter events, and dirty state work without deadlock.
9. **State:** Save state, restart the host, reload state, and verify the plugin restores its settings. Verify failed save does not damage an existing file.
10. **Restart:** Trigger plugin restart/port rescan and JACK buffer-size change; verify valid reactivation, silence during transition, and no use-after-free.
11. **JACK loss:** Stop JACK and verify a clear diagnostic, no callback-thread cleanup, and orderly non-zero exit.
12. **Errors:** Exercise missing library, missing `clap_entry`, incompatible/invalid descriptor, failed plugin init, failed activation, and process error paths.
13. **Real time:** Run under sustained load and verify host process-path instrumentation reports zero prohibited allocations/locks/I/O.
14. **Compatibility:** Complete smoke tests with at least three independently implemented Linux CLAP plugins, including one instrument and one effect.

## 18. Delivery and documentation

The initial release MUST include:

- Source code and reproducible Nimble build instructions.
- A concise manual page or README covering every command, option, signal, exit status, and environment variable.
- Examples for a synth, an effect, headless use, PID-file GUI control, state persistence, and `CLAP_PATH` scanning.
- Supported Linux architectures, Nim versions, CLAP version, and JACK implementations.
- Runtime/build dependency and license information.
- Known GUI limitations under native Wayland.
- A security warning about executing plugins in-process.
- A troubleshooting section for JACK connection failures, missing ports, missing GUI, plugin selection, and state failures.

## 19. Initial design decisions requiring owner confirmation

The requirements above proceed with these working decisions:

1. The host supports all plugin-declared audio and note ports in both directions, not only MIDI input and audio output.
2. The GUI is shown by default; `SIGUSR1` shows it and `SIGUSR2` hides it at runtime.
3. X11/XEmbed, including XWayland, is the initial embedded GUI target. Native Wayland is floating-only when the plugin supports it.
4. CLAP state load/save is included because otherwise GUI changes cannot be reliably restored between runs.
5. JACK connections remain externally managed; there is no auto-connect behavior initially.
6. JACK transport and tempo are deferred.
7. One plugin instance per process is intentional.
8. `pluginhost` is a working name. The final product name and project license remain undecided.

Changing any of these decisions should update this document and the associated acceptance tests before implementation.

## 20. Research notes and primary references

The following findings shaped these requirements:

- CLAP is a stable C ABI. CLAP 1.x plugins and hosts use `clap_entry`, a plugin factory, `clap_host`, `clap_plugin`, and optional extensions.
- CLAP's official fundamental-extension list includes state, parameters, note ports, audio ports, render, latency, and GUI.
- On Linux, GUI compatibility commonly also requires timer support and POSIX FD support.
- CLAP defines one stable main-thread identity and a symbolic, non-concurrent audio-thread context. Each API method specifies its permitted thread/state.
- CLAP float32 audio support is mandatory; float64 is optional.
- The CLAP GUI contract supports X11 embedding through XEmbed. Wayland is currently described as floating-only.
- JACK's process callback is real-time and explicitly forbids operations including allocation, printing, blocking locks, sleeping, waiting, and polling.
- JACK MIDI events are normalized, sample-timestamped events. SysEx may arrive in backend-sized chunks.
- `carla-single` launches one plugin bridge from a command line, but Carla is intentionally much broader than this product.
- The official minimal `clap-host` is a useful host implementation reference but uses C++, Qt, RtAudio, and RtMidi rather than JACK/Nim.

Primary sources:

- CLAP repository and headers: <https://github.com/free-audio/clap>
- CLAP entry/search paths: <https://github.com/free-audio/clap/blob/main/include/clap/entry.h>
- CLAP plugin lifecycle: <https://github.com/free-audio/clap/blob/main/include/clap/plugin.h>
- CLAP GUI extension: <https://github.com/free-audio/clap/blob/main/include/clap/ext/gui.h>
- CLAP audio ports: <https://github.com/free-audio/clap/blob/main/include/clap/ext/audio-ports.h>
- CLAP note ports/events: <https://github.com/free-audio/clap/blob/main/include/clap/ext/note-ports.h>
- CLAP parameter extension: <https://github.com/free-audio/clap/blob/main/include/clap/ext/params.h>
- CLAP threading rules: <https://github.com/free-audio/clap/blob/main/include/clap/ext/thread-check.h>
- Official minimal CLAP host: <https://github.com/free-audio/clap-host>
- JACK client API: <https://jackaudio.org/api/>
- JACK client callbacks: <https://jackaudio.org/api/group__ClientCallbacks.html>
- JACK MIDI API: <https://jackaudio.org/api/group__MIDIAPI.html>
- Carla and `carla-single`: <https://github.com/falkTX/Carla>
- Nim CLAP bindings reviewed: <https://github.com/NimAudio/nim-clap>
- Nim JACK wrapper reviewed: <https://github.com/SpotlightKid/jacket>
