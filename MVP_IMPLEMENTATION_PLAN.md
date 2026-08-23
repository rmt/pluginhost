# Standalone CLAP/JACK Plugin Host — MVP Implementation Plan

**Plan version:** 1.0.0  
**Target product release:** `pluginhost` 0.1.0  
**Initial development version:** 0.0.1-dev  
**Status:** Approved; Increment 0 completed and accepted  
**Companion documents:** [`REQUIREMENTS.md`](REQUIREMENTS.md), [`DESIGN.md`](DESIGN.md)

## 1. Purpose

This plan breaks the MVP into small, reviewable increments. It starts with a compiling program, basic domain types, explicit stubs, and tests. Each increment adds one coherent capability, keeps `main` runnable, and ends with a human review gate before further generated code is accepted.

The plan favors vertical slices over building every abstraction in advance. External boundaries and real-time invariants are established early because late discovery of a Nim/C ABI or JACK callback problem would invalidate substantial work.

## 2. MVP outcome

Version 0.1.0 is complete when a user can:

1. List and select a native Linux CLAP plugin.
2. Run one plugin instance as one JACK client.
3. Use all declared float32 audio inputs/outputs and MIDI/note inputs/outputs.
4. Show, hide, close, and reopen an embedded X11/XWayland plugin GUI while audio continues.
5. Load and atomically save plugin state.
6. Stop cleanly through signals or JACK shutdown.
7. Rely on tested CLAP lifecycle/thread behavior and an allocation-free, non-blocking host process path.

The release must satisfy the applicable MUST requirements and release acceptance scenarios in `REQUIREMENTS.md`. Deferred SHOULD items must be listed in release notes rather than silently omitted.

## 3. Versioning policy

The project uses Semantic Versioning while recognizing that pre-1.0 interfaces may change.

- `0.0.x-dev`: reviewed development snapshots; no compatibility promise.
- `0.1.0-rc.1`: feature-complete MVP release candidate.
- `0.1.0`: accepted MVP.
- The CLI and internal APIs are not declared stable until separately documented.

A root `VERSION` file will be the single version source. Nimble metadata and `pluginhost --version` will read or verify that value. CI will fail if embedded/package versions disagree.

Expected progression:

| Increment | Planned version |
|---|---:|
| Scaffolding | 0.0.1-dev |
| FFI/ABI foundation | 0.0.2-dev |
| CLAP catalog and discovery | 0.0.3-dev |
| CLAP instance/lifecycle core | 0.0.4-dev |
| JACK backend and RT harness | 0.0.5-dev |
| First end-to-end audio host | 0.0.6-dev |
| MIDI/note bridge | 0.0.7-dev |
| Main reactor and process control | 0.0.8-dev |
| Host extensions and restart behavior | 0.0.9-dev |
| State persistence | 0.0.10-dev |
| Plugin GUI | 0.0.11-dev |
| Feature-complete hardening | 0.1.0-rc.1 |
| Accepted MVP | 0.1.0 |

Version changes occur only after the preceding review gate is approved.

## 4. Human-in-the-loop development protocol

Every increment follows the same workflow.

### 4.1 Before code generation

The coding assistant presents:

- The increment goal and explicit non-goals.
- Files expected to be added or changed.
- Public/internal interfaces affected.
- Tests to be written and how they demonstrate behavior.
- New dependencies or architecture decisions.
- Known risks and any question requiring human judgment.

The human may narrow or revise the increment before code is generated.

### 4.2 Implementation cycle

1. Add or update behavior-focused tests.
2. Confirm new tests fail for the intended reason when practical.
3. Add the smallest implementation that satisfies the increment.
4. Run focused tests, then the full test suite.
5. Run formatting, compile checks, ABI checks, and relevant integration tests.
6. Self-review for lifecycle, cleanup, FFI, error handling, and real-time violations.
7. Update documentation and this plan's progress table.

The initial scaffolding increment is allowed to begin with compiling smoke tests rather than a meaningful red state.

### 4.3 Review package

At each gate, the assistant supplies:

- A concise design/behavior summary.
- A file-by-file change summary.
- The exact test and build commands run, with results.
- A manual verification recipe when the increment has user-visible behavior.
- Known limitations and deferred work.
- Any generated code or vendored source clearly identified.
- The proposed next increment, without starting it.

The human reviews implementation and tests. Work does not proceed to the next increment until the human explicitly approves or requests changes.

### 4.4 Review-size rule

An increment may be split into smaller review units if its diff becomes difficult to reason about. In particular:

- Raw FFI declarations and their ABI tests should be reviewed together.
- Real-time queue/arena code should be reviewed separately from broad host behavior.
- X11 resource management should be reviewed before full CLAP GUI integration.
- Mechanical generated bindings must not obscure handwritten policy changes in the same review.

## 5. Engineering rules throughout the plan

### 5.1 Stubs and incomplete capabilities

- Stubs return a typed `NotImplemented` error or are available only to tests.
- A stub must never return success for work it did not perform.
- The host must not advertise a CLAP extension until its required callback contract is implemented and tested.
- Unsupported CLI paths fail clearly; they do not silently do nothing.
- `discard` is not acceptable error handling at an external boundary.
- Temporary implementation limits are named constants, documented, and tested at the boundary.

### 5.2 Tests

- Tests describe externally meaningful behavior rather than mirroring implementation lines.
- Unit tests do not require JACK, X11, or third-party plugins.
- Integration tests are separately tagged/tasks and create disposable dependencies.
- Tests use deterministic clocks/reactors instead of sleeps where possible.
- Every fixed-capacity structure has boundary, full-capacity, overflow, and recovery tests.
- Every acquired foreign resource has success, partial-failure, and repeated-cleanup tests.
- No flaky test is accepted as “usually passing.”

### 5.3 Real-time code

- All real-time data is preallocated before JACK activation.
- No managed strings, sequences, tables, closures, exceptions, logging, filesystem calls, GUI calls, or blocking locks enter the process path.
- C callbacks use exact calling conventions and `raises: []`.
- Every change to `src/pluginhost/rt/`, JACK process callbacks, or CLAP output-event callbacks runs the real-time safety test task.
- Performance optimization does not bypass correctness tests or introduce unmeasured complexity.

### 5.4 Dependencies

A new third-party dependency requires human approval and a short record of:

- Why standard library/minimal FFI is insufficient.
- Maintenance status and pinned version.
- Runtime/build footprint.
- License compatibility.
- Real-time and thread implications.

### 5.5 Scope control

No increment may add unrelated product features “while we are here.” Refactoring is allowed when it reduces immediate risk, is covered by tests, and is called out in the review package.

## 6. Planned project-wide test commands

These commands will be introduced progressively and must remain stable once available:

```text
nimble check              # compile/package checks
nimble test               # fast unit tests
nimble testAbi            # C/Nim ABI conformance
nimble testFixtures       # build and test synthetic CLAP fixtures
nimble testIntegration    # disposable JACK integration tests
nimble testGui            # Xvfb/X11 GUI integration tests
nimble testRt             # allocation/lock/I/O RT checks and stress tests
nimble sanitize           # generated-C sanitizer build/tests
nimble all                # required pre-review checks available at that stage
```

A command not yet implemented must be absent or fail as not implemented; it must not report a false pass.

## 7. Increment 0 — Repository and application scaffolding

**Planned version:** 0.0.1-dev

### Goal

Create a small, compiling Nim project with a working `main`, initial domain types, explicit command stubs, a unit-test harness, and basic documentation. Establish conventions before external APIs are introduced.

### Implementation

- Add `VERSION` with `0.0.1-dev`.
- Add `pluginhost.nimble` with pinned minimum Nim version and initial tasks.
- Add the executable composition root at `src/pluginhost.nim`.
- Add focused initial modules:
  - `app/cli.nim`
  - `app/commands.nim`
  - `app/run_config.nim`
  - `domain/errors.nim`
  - `domain/result.nim`
  - `domain/lifecycle.nim`
  - `support/diagnostics.nim`
  - `version.nim`
- Define typed command/configuration values without JACK, CLAP, or X11 imports.
- Implement working `--help` and `--version` paths returning exit status 0.
- Parse the top-level `run`, `list`, and `scan` forms sufficiently to validate syntax.
- Route unimplemented valid commands to a clear `NotImplemented` diagnostic and non-zero exit status.
- Add an idempotent stub `HostSession` whose methods make unsupported state transitions impossible.
- Add README build/test instructions and links to the three planning documents.
- Add `.gitignore`, formatting conventions, and a basic CI job if the repository uses hosted CI.

### Tests

- CLI help/version output and exit statuses.
- Invalid/mutually exclusive option handling.
- Conversion of typed errors to exit statuses and stderr.
- Version consistency between `VERSION`, Nimble metadata, and `--version`.
- Basic lifecycle transition tests.
- Main-process smoke tests with captured stdout/stderr.

### Explicit non-goals

- No CLAP or JACK FFI.
- No plugin path scanning.
- No real plugin initialization.
- No empty module for every future component; modules are added when their first real type is needed.

### Human review gate 0

Review naming, source layout, CLI shape, error/result approach, test style, version source, and whether the amount of scaffolding is proportionate. Approval establishes project conventions.

## 8. Increment 1 — Pinned FFI and ABI foundation

**Planned version:** 0.0.2-dev

### Goal

Prove that Nim can safely represent and call the required CLAP/JACK ABI before implementing host policy.

### Implementation

- Vendor/pin official stable CLAP 1.2.10 headers and license metadata.
- Decide through an ADR whether bindings are hand-maintained, generated, or generated then curated.
- Add minimal raw CLAP declarations needed for entry, factory, host, plugin, process, audio ports, note ports, events, and later extension growth.
- Add minimal JACK declarations needed for client lifecycle, callbacks, ports, audio buffers, MIDI, sample rate, buffer size, and latency.
- Keep raw FFI modules policy-free.
- Add a tiny C ABI probe against official headers.
- Add C-to-Nim and Nim-to-C callback smoke tests, including data-symbol lookup for `clap_entry`.
- Add checked dynamic-library wrappers with explicit ownership.
- Verify foreign-thread callback setup under the chosen Nim memory/thread configuration.
- Record the decision on direct JACK FFI versus audited `jacket` use.

### Tests

- Size, alignment, field offset, enum width/value, and callback signature comparisons.
- `clap_version` compatibility helpers.
- Dynamic loading of a tiny fixture library and lookup of data/function symbols.
- Callback invocation from a C-created thread without an exception crossing the boundary.
- Idempotent library close and partial-load rollback.
- x86_64 ABI in CI; prepare the test matrix for aarch64 without claiming support yet.

### Risk spike

Build a deliberately small process-callback-shaped Nim function and instrument it for unexpected allocation or runtime initialization. Resolve foreign-thread and memory-manager uncertainty here.

### Human review gate 1

Review every imported type used so far, generated versus handwritten code, licensing, calling conventions, ownership wrappers, and ABI test evidence. No host implementation proceeds on an unverified ABI.

## 9. Increment 2 — CLAP catalog, `list`, and discovery

**Planned version:** 0.0.3-dev

### Goal

Deliver the first useful CLAP behavior: inspect plugin libraries safely enough to list descriptors, without creating plugin instances.

### Implementation

- Add `ClapModule` owning DSO, entry initialization, factory, and matched deinitialization.
- Add copied/validated host-owned descriptor values.
- Implement descriptor selection types by index and ID.
- Implement `pluginhost list PLUGIN_PATH` in human-readable and JSON modes.
- Implement discovery of explicit roots, standard Linux paths, and `CLAP_PATH`.
- Canonicalize paths, detect duplicates, avoid symlink directory loops, and isolate per-candidate errors.
- Implement `pluginhost scan` human-readable and JSON output.
- Build an independent C CLAP fixture containing multiple descriptors and configurable invalid cases.
- Ensure scanning never creates a plugin instance.

### Tests

- Successful entry init/factory/descriptor/deinit sequence.
- Missing library, missing `clap_entry`, incompatible entry, missing factory, null descriptor, invalid mandatory fields, and invalid UTF-8.
- One and multiple descriptors; exact ID/index selection.
- JSON schema/output cleanliness.
- `CLAP_PATH` ordering, explicit-root precedence, recursive scan, duplicate canonical paths, and symlink loops.
- One failed candidate does not stop later candidates.
- Fixture counters prove every successful entry init has a matching deinit.

### Manual verification

Run `list` and `scan` against the test fixture and at least one installed CLAP plugin, without creating the plugin.

### Human review gate 2

Review DSO/entry ownership, untrusted descriptor handling, scan behavior, JSON contract, filesystem traversal, and fixture independence.

## 10. Increment 3 — CLAP instance and lifecycle core

**Planned version:** 0.0.4-dev

### Goal

Create, initialize, inspect, and destroy one CLAP instance correctly without JACK processing.

### Implementation

- Add `ClapHostBridge` at a stable address with host identity and extension lookup.
- Initially expose only fully implemented core callbacks and `clap.thread-check`/bounded logging as approved.
- Add atomic/coalesced request fields for restart, process, callback, and flush.
- Add bounded multi-producer plugin log transport to the main thread.
- Add `ClapInstance` and explicit lifecycle state machine.
- Cache plugin extension pointers only after successful init.
- Add `ClapPortInspector` and immutable `PortPlan` for all audio/note groups.
- Add render-mode negotiation.
- Add cleanup for every partial initialization level.
- Extend the fixture to validate host identity, callback lifetime, thread-check answers, extension availability, and port inspection.
- Keep normal `run` clearly unavailable until a real backend exists; use tests rather than adding a temporary public command.

### Tests

- Create/init/destroy success and every failure transition.
- Multiple calls to cleanup are harmless.
- Host object and C strings remain valid through destroy.
- Extension queries return stable pointers only for implemented capabilities.
- Main-thread identity remains stable.
- Port counts, groups, IDs, channels, names, dialects, and malformed plugin responses.
- Request coalescing and bounded log overflow.
- No plugin call occurs after destroy or entry deinit.

### Human review gate 3

Review lifecycle state machine, stable callback storage, raw-pointer lifetimes, extension-advertisement discipline, port model, and partial-failure cleanup.

## 11. Increment 4 — JACK backend and real-time harness

**Planned version:** 0.0.5-dev

### Goal

Implement and test JACK client/port/callback mechanics independently of CLAP DSP, using a minimal fake process endpoint.

### Implementation

- Add `JackBackend` with open/configure/activate/deactivate/close states.
- Register process, shutdown, sample-rate, buffer-size, and latency callbacks before activation.
- Realize an immutable synthetic `PortPlan` as JACK ports with deterministic naming.
- Add `RtEngine` fixed-layout skeleton and static process trampoline.
- Add `AudioRoleGuard`, request/metric atomics, and callback quiescence rules.
- Use a test processor that writes silence, copies input, or emits a deterministic signal without allocation.
- Add a disposable JACK dummy-server test harness.
- Add initial RT instrumentation hooks.
- Convert JACK notifications to compact main-thread-visible events; callbacks perform no cleanup.

### Tests

- JACK unavailable/status diagnostics.
- Port registration names, direction, type, cleanup, and partial registration failure.
- Sample rate and buffer size capture.
- Process callback buffer access and deterministic output.
- No callback after backend deactivation returns.
- JACK shutdown schedules but does not execute cleanup in callback context.
- Repeated open/activate/deactivate/close cycles.
- Process path performs no host allocation, logging, blocking lock, or exception.

### Manual verification

Start a dummy JACK server, launch the integration fixture, inspect ports with JACK tools, connect input/output, and verify deterministic samples.

### Human review gate 4

Review callback boundary, RT structure contents, quiescence proof, fake processor, port ownership, JACK diagnostics, and instrumentation credibility.

## 12. Increment 5 — First end-to-end CLAP audio host

**Planned version:** 0.0.6-dev

### Goal

Produce the first meaningful vertical slice: run a CLAP instrument/effect headlessly with JACK float32 audio.

### Implementation

- Connect `HostSession`, `ClapInstance`, `JackBackend`, and `RtEngine`.
- Map every CLAP audio group/channel to flattened JACK ports while preserving CLAP grouping internally.
- Preallocate CLAP audio descriptors and channel-pointer arrays.
- Pass JACK buffers directly as CLAP float32 pointers with no full-buffer copy.
- Execute activate/start/process/stop/deactivate in correct states and thread roles.
- Supply monotonic CLAP `steady_time` and null transport.
- Implement output zeroing for inactive, skipped, restart-pending, and error states.
- Treat `CLAP_PROCESS_ERROR` as a compact RT failure followed by main-thread shutdown.
- Schedule safe reactivation for sample-rate or larger-buffer changes.
- Extend the fixture with a tone generator and gain effect.
- Enable the canonical `pluginhost [options] PLUGIN_PATH` command for headless audio plugins.

### Tests

- Instrument with no audio input and stereo output.
- Stereo effect with input/output and known gain.
- Multiple audio groups/channel counts and exact JACK-to-CLAP pointer mapping.
- Activation/start/process failure behavior and silence.
- Frame range and steady-time behavior.
- Sample-rate/buffer-size change reactivation.
- Full startup/shutdown order and no callbacks into released plugin storage.
- Zero-copy path checked by pointer identity in the fixture.

### Manual verification

Run the fixture synth/effect against JACK and capture expected output. If available, run one real headless-capable CLAP plugin.

### Human review gate 5

Review the complete lifecycle sequence, zero-copy proof, audio grouping, failure-to-silence behavior, and main/RT ownership boundary. This is the first architectural validation checkpoint.

## 13. Increment 6 — JACK MIDI and CLAP note/event bridge

**Planned version:** 0.0.7-dev

### Goal

Add sample-accurate MIDI input/output and required CLAP note-dialect conversion without compromising RT constraints.

### Implementation

- Materialize all CLAP note ports as JACK MIDI ports.
- Add fixed-capacity aligned input event arena for at least 4,096 ordinary events.
- Add preallocated k-way merge workspace across MIDI input ports.
- Implement CLAP input event list callbacks.
- Convert normalized JACK MIDI and SysEx to CLAP events with exact offsets.
- Translate note-on, note-off, and pressure for CLAP-only note ports where semantics are defined.
- Implement real-time CLAP output event sink writing MIDI/SysEx immediately to JACK.
- Convert representable CLAP note output to MIDI 1.0.
- Validate order, port index, size, timestamp, and capacity.
- Add drop/error counters drained by the main thread.
- Extend the fixture with MIDI echo, synth note response, multiple note ports, SysEx, malformed output, and dialect modes.

### Tests

- Multiple events at different and equal offsets.
- Global stable ordering across multiple JACK MIDI ports.
- Raw MIDI, velocity-zero semantics, SysEx chunks/lifetime, and MIDI output.
- CLAP-only note translation and unsupported-message drops.
- Invalid/out-of-order plugin output rejection.
- Exactly 4,096 events, one-over-capacity, recovery next cycle, and no memory corruption.
- JACK MIDI output-buffer capacity failure.
- No allocation or logging on any success/error/overflow path.

### Manual verification

Connect a JACK MIDI generator/keyboard to the fixture or real synth and verify audio response. Connect fixture MIDI output to a JACK MIDI monitor.

### Human review gate 6

Review event layout/alignment, sorting algorithm, pointer lifetimes, SysEx copies, dialect policy, overflow behavior, and RT test coverage.

## 14. Increment 7 — Main reactor, signals, and orderly process control

**Planned version:** 0.0.8-dev

### Goal

Replace any temporary run loop with the event-driven Linux control plane needed for prompt callbacks, runtime signals, and later GUI services.

### Implementation

- Add a narrow reactor capability and Linux `epoll` implementation.
- Add monotonic timer scheduling with registration generations.
- Add signal self-pipe/eventfd handling.
- Implement `SIGINT`/`SIGTERM` orderly shutdown requests.
- Reserve `SIGUSR1`/`SIGUSR2` show/hide requests even though GUI is not implemented yet; they return a controlled warning.
- Implement PID-file atomic create/remove behavior.
- Drain atomic CLAP request flags within the required main-thread service deadline without audio-thread syscalls.
- Implement bounded/fair request dispatch and shutdown priority.
- Add fake deterministic reactor/clock for unit tests.
- Remove temporary sleeps/poll loops from production main.

### Tests

- Reactor FD add/modify/remove and stale-generation protection.
- Monotonic timer ordering, cancellation, self-cancellation, and callback registration changes.
- Signal handler only notifies; main thread performs actions.
- Signal ordering/idempotency and shutdown overriding restart/show.
- PID-file success, collision, rollback, and removal.
- `request_callback()` reaches `plugin.on_main_thread()` within simulated deadline.
- No busy-wait when idle.

### Manual verification

Run the headless host, send all supported signals, inspect PID-file behavior, and stop JACK to verify orderly exit.

### Human review gate 7

Review signal safety, reactor reentrancy, timing guarantees, generation tokens, fairness, PID-file semantics, and absence of polling sleeps.

## 15. Increment 8 — Host extensions, parameters, latency, and restart

**Planned version:** 0.0.9-dev

### Goal

Implement the stable host services needed for broad plugin correctness before adding state and GUI.

### Implementation

- Implement host extensions only as their complete callbacks become available:
  - `clap.log`
  - `clap.params`
  - `clap.state` dirty notification
  - `clap.latency`
  - `clap.audio-ports`
  - `clap.note-ports`
  - `clap.timer-support`
  - `clap.posix-fd-support`
  - `clap.thread-check`
- Handle parameter output, gestures, rescans, cookie invalidation, and flush scheduling.
- Ensure parameter `flush()` never overlaps `process()`.
- Implement plugin timers and POSIX FD dispatch through the main reactor.
- Implement `request_restart`, `request_process`, and process sleep/wake policy.
- Implement safe stop/deactivate/rescan/rebuild/reactivate restart sequence.
- Implement audio/note name and structural rescans.
- Reflect plugin latency through JACK latency ranges.
- Preserve/reconnect compatible JACK connections when practical; otherwise report losses clearly per requirements.
- Add restart-loop coalescing/rate protection.
- Expand fixture behavior for every extension and callback context.

### Tests

- Each host extension advertised only when complete.
- Callback context/thread checks and stable vtable pointers.
- Active versus inactive parameter flush.
- Parameter output/dirty state and bounded queue overflow.
- Plugin timer and level-triggered FD behavior, including unregister during callback.
- Sleep, event/request wake, and connected-audio conservative policy.
- Restart caused by plugin, sample rate, block size, and structural port rescan.
- Restart failure leaves silence and exits/recovers according to policy.
- Latency range updates and latency-change request.
- Repeated restart requests cannot create a tight main-loop cycle.

### Manual verification

Use the fixture to trigger every request/extension while processing. Smoke-test one real plugin that uses parameters and one that uses timer or POSIX FD support.

### Human review gate 8

Review each extension against its official header, concurrency rules, flush/process exclusion, restart state machine, dynamic port behavior, latency mapping, and loop protection.

## 16. Increment 9 — State load/save transactions

**Planned version:** 0.0.10-dev

### Goal

Add reliable plugin state persistence independently of GUI implementation.

### Implementation

- Add bounded CLAP input/output stream adapters with explicit context lifetime.
- Implement `--load-state` before activation.
- Implement `--save-state` on clean shutdown while the plugin remains valid.
- Implement same-directory temporary write, flush/close, and atomic rename.
- Preserve existing destination on every failed save path.
- Reject requested state behavior when the plugin lacks `clap.state`.
- Track dirty state for diagnostics without inventing parameter persistence.
- Extend fixture state with versioned deterministic content and short/error stream modes.

### Tests

- Full, partial, short, interrupted, and failed reads/writes.
- Valid save/load round trip.
- Load failure prevents activation with state-specific exit status.
- Failed save leaves old destination byte-identical and removes temporary files.
- SIGINT/SIGTERM clean save.
- Plugin crash/uncatchable signal is not claimed to save.
- No state callback after instance destruction.
- File permissions and destination-directory behavior are documented and tested.

### Manual verification

Change fixture state through a test mechanism, save, restart, load, and verify restored DSP behavior. Repeat with read-only/broken destination paths.

### Human review gate 9

Review stream ABI/lifetimes, partial-I/O handling, transaction atomicity, shutdown ordering, error statuses, and filesystem cleanup.

## 17. Increment 10 — X11/XEmbed plugin GUI

**Planned version:** 0.0.11-dev

### Goal

Add the required plugin-native GUI path with runtime show/hide while preserving uninterrupted audio.

### Review unit 10A — Window-host spike

Before full integration:

- Decide Xlib versus XCB and record an ADR.
- Build `WindowHost` capability and concrete minimal X11 window.
- Verify XEmbed parent window, event processing, WM close, sizing, and resource cleanup under Xvfb.
- Keep this spike independent of third-party plugin GUI code.

Human review is required before unit 10B.

### Review unit 10B — CLAP GUI integration

- Add `GuiController` state machine.
- Negotiate embedded X11 first, then supported floating fallback.
- Follow CLAP create/size/parent/show/hide/destroy order.
- Implement host GUI resize/show/hide/closed callbacks through coalesced main-thread requests.
- Connect X11 readiness to the reactor.
- Implement `--show-gui`, `--hide-gui`, `--no-gui`, `--require-gui`, and `--gui-scale` policy.
- Implement `SIGUSR1` show and `SIGUSR2` hide.
- Make WM close hide/destroy without stopping audio and allow recreation.
- Ensure `--no-gui` does not advertise GUI hosting.
- Extend fixture with embedded/floating, resize, timer, POSIX FD, close, failure, and recreate GUI modes.

### Tests

- GUI negotiation preference/fallback without X11 using `FakeWindowHost`.
- Full embedded lifecycle under Xvfb.
- Show/hide idempotency, close/reopen, resize hints, host/plugin resize, and scale.
- GUI unavailable fallback versus `--require-gui` failure.
- Headless run without `DISPLAY`.
- Timers/FDs remain main-thread and are removed at destruction.
- Audio cycle counter continues while GUI is shown, hidden, resized, and recreated.
- Reentrant plugin GUI requests are deferred to safe points.
- Repeated create/destroy has no X11/FD/timer leaks.

### Manual verification

Run the fixture and at least two independent real plugin GUIs under X11/XWayland. Exercise signals, resize, WM close, and state changes while monitoring JACK xruns.

### Human review gate 10

Review X11 ownership/error handling, CLAP GUI call order, callback reentrancy, headless policy, timer/FD cleanup, and evidence that audio is unaffected.

## 18. Increment 11 — Feature-complete hardening and release candidate

**Planned version:** 0.1.0-rc.1

### Goal

Stop adding features. Close requirement/test gaps, validate independent plugins and JACK implementations, and prepare a release candidate.

### Implementation and verification

- Audit every MUST statement in `REQUIREMENTS.md` and every invariant checklist item in `DESIGN.md`.
- Complete stable exit statuses and diagnostics.
- Run failure injection at every lifecycle acquisition point.
- Add malformed plugin/event/state/path fuzz/property tests.
- Run generated-C sanitizers and leak/resource checks.
- Run sustained RT stress with allocation/lock/I/O instrumentation.
- Measure and document host overhead on a reference system.
- Test JACK1/JACK2 and PipeWire-JACK according to available CI/manual environments.
- Smoke-test at least three independently implemented CLAP plugins, including an instrument and effect.
- Repeat startup/restart/show/hide/save/shutdown loops.
- Finish README/manual, examples, troubleshooting, dependencies, licenses, security warning, and known Wayland limitations.
- Record all deferred SHOULD requirements explicitly.
- Remove obsolete stubs, debug-only public options, and dead code.
- Freeze the 0.1.0 CLI unless the human approves a breaking correction.

### Required acceptance evidence

- Full automated command output.
- Manual acceptance checklist corresponding to all scenarios in requirements section 17.2.
- Supported environment matrix.
- Performance/RT instrumentation report.
- Known issues and deferred requirements.
- Release artifact build and version output.

### Human review gate 11

Perform release-candidate code, test, behavior, dependency/license, documentation, and security review. Only defect fixes and approved requirement corrections follow this gate.

## 19. Increment 12 — MVP release

**Planned version:** 0.1.0

### Goal

Release only after the human accepts the release candidate evidence.

### Tasks

- Resolve approved release-candidate defects with focused regression tests.
- Re-run the complete release matrix on a clean checkout.
- Set `VERSION` and package metadata to `0.1.0`.
- Generate final release notes with limitations and deferred SHOULD items.
- Tag the exact reviewed commit as `v0.1.0`.
- Build and checksum release artifacts if binary distribution is selected.
- Archive test/acceptance evidence.

### Human review gate 12

The human explicitly approves the final diff, test evidence, release notes, and version/tag. The tag is not created before this approval.

## 20. Progress tracking

This table is updated only when work is reviewed.

| Increment | Status | Review reference | Notes |
|---|---|---|---|
| 0 — Scaffolding | Approved | Iteration 0 review | Includes the `argparse` 4.0.2 CLI |
| 1 — FFI/ABI | Not started | — | — |
| 2 — CLAP catalog | Not started | — | — |
| 3 — CLAP lifecycle | Not started | — | — |
| 4 — JACK/RT harness | Not started | — | — |
| 5 — Audio vertical slice | Not started | — | — |
| 6 — MIDI/events | Not started | — | — |
| 7 — Reactor/signals | Not started | — | — |
| 8 — Host extensions/restart | Not started | — | — |
| 9 — State | Not started | — | — |
| 10 — GUI | Not started | — | Split into 10A/10B reviews |
| 11 — Release candidate | Not started | — | — |
| 12 — MVP release | Not started | — | Target 0.1.0 |

Allowed statuses: `Not started`, `In progress`, `Changes requested`, `Approved`, and `Deferred`.

## 21. Risk register

| Risk | Earliest mitigation | Release evidence |
|---|---|---|
| Nim/C ABI mismatch | Increment 1 probes and ABI tests | ABI CI on supported architectures |
| Nim runtime activity on JACK foreign thread | Increments 1 and 4 instrumentation | Sustained `testRt` report |
| Incorrect CLAP lifecycle/thread role | Increment 3 state machine, increment 5 vertical slice | Fixture and independent-plugin tests |
| MIDI event ordering/capacity corruption | Increment 6 fixed arena and k-way merge tests | Boundary/stress/sanitizer results |
| Plugin callback reentrancy | Increments 7–8 deferred request dispatch | Reentrant fixture tests |
| Restart races/use-after-free | Increments 4, 5, and 8 quiescence tests | Repeated restart stress |
| X11/XEmbed incompatibility | Increment 10A isolated spike | Xvfb and real-plugin matrix |
| GUI timer/FD leaks | Increments 8 and 10 | Repeated GUI lifecycle checks |
| State-file corruption | Increment 9 transaction design | Failure-injection tests |
| Scope growth obscures review | Review-size rule and per-increment non-goals | Progress/review record |
| Third-party plugin crash during scan/run | Documented trust model and cleanup where possible | Security/limitations documentation |

## 22. Post-MVP backlog candidates

These do not enter 0.1.0 unless a requirement is deliberately revised:

- Native Wayland floating GUI improvements.
- Linux aarch64 release support after ABI CI is available.
- More complete compatible-port reconnection after structural rescans.
- JACK transport/tempo mapping.
- Native PipeWire backend rather than JACK compatibility.
- Generic parameter CLI/editor.
- Preset browsing/loading.
- MIDI 2.0 and richer CLAP note-expression conversion.
- Multi-plugin graphs.
- Out-of-process plugin isolation.
- Additional plugin formats.

Each candidate requires requirements/design updates and, where architectural, an ADR before implementation.

## 23. First action after plan approval

After the human approves this plan, begin only **Increment 0**. Before generating scaffolding code, present the increment-0 pre-code package required by section 4.1: proposed files, interfaces, tests, commands, and any small deviations from the source layout in `DESIGN.md`.
