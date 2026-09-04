# Standalone CLAP/JACK Plugin Host — MVP Implementation Plan

**Plan version:** 1.0.0  
**Target product release:** `pluginhost` 0.1.0  
**Initial development version:** 0.0.1-dev  
**Status:** Increments 0–10A approved; Increment 10B implementation complete in the current review worktree and pending review
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
- No managed strings, sequences, tables, closures, exceptions, logging, filesystem calls, GUI calls, cleanup, or blocking locks enter any JACK callback path.
- C callbacks use exact calling conventions, `raises: []`, and `gcsafe`; because `raises: []` does not track Defects, callbacks also run under the shared panic profile with local checks/trace setup disabled after explicit validation.
- Every change to `src/pluginhost/rt/`, any JACK callback, or CLAP output-event callback runs the real-time safety test task.
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

### Recommended review split

To keep lifecycle and port-model risks separately reviewable:

- **Review unit 3A:** stable `ClapHostBridge`, core host callbacks, bounded request/log
  transport, `ClapInstance` creation/init/destroy, extension caching, and every partial
  cleanup path. No port-plan or JACK work.
- **Review unit 3B:** deactivated-plugin port inspection, immutable `PortPlan`, and
  render-mode negotiation. No JACK processing or public `run` behavior.

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
**Review split:** 4A, 4B, and 4C approved

### Goal

Implement and test JACK client/port/callback mechanics independently of CLAP DSP, using a minimal fake process endpoint. Public `run` remains disabled.

### Increment 4A — build profile, checked JACK loading, and ABI

**Status:** Approved in review unit 4A.

- Pin one ARC/thread/panic/signal profile for product and every test task.
- Record the callback Defect barrier and checked JACK loading decisions in ADRs.
- Convert raw JACK imported procedures to declaration-only typed procedure pointers.
- Add a move-only checked `JackApi` DSO/procedure-table owner with complete partial-resolution rollback.
- Add typed JACK loader/symbol/close errors and exit status 4.
- Add freewheel ABI declarations while retaining the already declared xrun API; later connection and MIDI-loss APIs remain deferred.
- Prove information-command binaries have no eager `libjack.so.0` dependency.
- Test missing library, missing symbol, rollback, runtime version calls, move-only ownership, and repeated close.

### Increment 4B — backend, ports, callbacks, and fake endpoint

**Status:** Approved in review unit 4B.

- Add move-only `JackBackend` open/configure/activate/deactivate/close states.
- Register every callback before activation and convert notifications to compact POD/atomic state without callback-side cleanup.
- Realize immutable synthetic plans transactionally using actual JACK client/name limits and complete rollback.
- Add stable fixed-layout `RtPortMap`, `RtEngine` skeleton, `AudioRoleGuard`, and callback quiescence rules.
- Use a fake processor that writes silence, copies input, or emits deterministic samples without allocation.
- Test statuses, registration boundaries, failure rollback, notifications, deterministic buffers, role exclusivity, and repeated lifecycle.

### Increment 4C — live integration and strengthened RT evidence

**Status:** Approved in review unit 4C.

- Add a disposable isolated PipeWire-JACK Dummy-Driver harness with strict prerequisite failure, private runtime/server naming, readiness checks, and deterministic teardown.
- Verify live audio/MIDI ports and exact deterministic samples through an independent one-client C JACK peer.
- Prove peer-witnessed deactivation/close quiescence, client-close port removal, exact-name reuse, stable file descriptors, and 32 repeated active-close lifecycles.
- Replace traced Nim atomic helpers with an ABI-tested, always-lock-free C11 callback bridge recorded in ADR 0005.
- Audit complete RT-only generated modules and the CLAP callback helper closure under exact product flags; require a deliberately failing allocation canary.
- Instrument C allocation/deallocation, locks, print, and prohibited I/O around all live host JACK callbacks after a required detection self-test.
- Keep fake-backend failure injection in the fast unit task and add the strict live task to `nimble all`.

### Human review gates

Review 4A's compile/ABI/DSO boundary before 4B. Review 4B's callback and ownership boundary before 4C. Final Increment 4 review covers live quiescence and instrumentation credibility before any CLAP DSP integration.

## 12. Increment 5 — First end-to-end CLAP audio host

**Planned version:** 0.0.6-dev
**Status:** Approved.

### Goal

Produce the first internal end-to-end CLAP/JACK float32 audio slice without exposing a public run loop before orderly signal control exists.

### Implementation

- Connect `HostSession`, `ClapInstance`, `JackBackend`, and `RtEngine` in a test/internal harness.
- Map every CLAP audio group/channel to flattened JACK ports while preserving CLAP grouping internally.
- Preallocate CLAP audio descriptors and channel-pointer arrays.
- Pass JACK buffers directly as CLAP float32 pointers with no full-buffer copy.
- Execute activate/start/process/stop/deactivate in correct states and thread roles.
- Supply monotonic CLAP `steady_time` and null transport, retaining the documented non-conforming-plugin compatibility risk.
- Implement output zeroing for inactive, skipped, restart-pending, and error states.
- Treat `CLAP_PROCESS_ERROR` as a compact RT failure followed by main-thread shutdown.
- Treat `CLAP_PROCESS_TAIL` and `CLAP_PROCESS_CONTINUE_IF_NOT_QUIET` as continued processing.
- Schedule safe reactivation for sample-rate or larger-buffer changes.
- Extend the fixture with a tone generator and gain effect.
- Smoke-test at least one independently implemented headless CLAP plugin when available.
- Keep the canonical public `pluginhost [options] PLUGIN_PATH` command as an explicit stub until Increment 7 installs orderly signal/reactor control.

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
**Status:** Review units 6A and 6B approved; Increment 6 complete.

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

Review unit 6A uses strict fake-JACK and independent CLAP event fixtures. Approved review unit 6B uses a separate two-client C JACK peer under its own disposable PipeWire-JACK server to inject and capture live multi-port MIDI/SysEx through the production CLAP event process path.

### Human review gate 6A

Review event layout/alignment, sorting algorithm, pointer lifetimes, SysEx copies, dialect policy, overflow behavior, and RT test coverage before beginning live MIDI work.

### Review unit 6B implementation

- Add an independently linked C peer with separate injector and capture JACK clients so the live test graph remains acyclic.
- Inject deterministic MIDI and SysEx on two ports and verify exact bytes and sample offsets after CLAP fixture echo.
- Verify equal-offset global ordering through fixture observations and immediate output copying through peer capture.
- Re-establish test connections idempotently at each activation with bounded control-thread retries for PipeWire graph publication.
- Repeat 16 CLAP/JACK start/stop lifecycles with 32 peer-witnessed quiescence cycles after each stop.
- Verify port removal and continued server cycles after close.
- Require clean allocation/deallocation/lock/print/prohibited-I/O instrumentation through the live CLAP event process path.

### Human review gate 6B

Review independent live JACK MIDI injection/capture, sample offsets, repeated lifecycle behavior, and live callback instrumentation before approving Increment 6.

## 14. Increment 7 — Main reactor, signals, and orderly process control

**Planned version:** 0.0.8-dev
**Status:** Approved.

### Goal

Add the event-driven Linux control plane required for public `run`, prompt callbacks, runtime signals, and later GUI services.

### Implementation

- Add a narrow reactor capability and Linux `epoll` implementation.
- Add monotonic timer scheduling with registration generations.
- Before any public-run JACK open, block handled signals with `pthread_sigmask`, create `signalfd`, and register it with the reactor.
- Implement `SIGINT`/`SIGTERM` orderly shutdown requests.
- Reserve `SIGUSR1`/`SIGUSR2` show/hide requests even though GUI is not implemented yet; they return a controlled warning.
- Implement PID-file atomic create/remove behavior.
- Drain atomic CLAP request flags within the required main-thread service deadline without audio-thread syscalls.
- Implement bounded/fair request dispatch and shutdown priority.
- Add fake deterministic reactor/clock for unit tests.
- Remove temporary sleeps/poll loops from production main.
- Enable the canonical public `pluginhost [options] PLUGIN_PATH` command only after the signal/reactor service is installed before `JackBackend`.
- Consume signals without installing a host signal handler, adopt JACK server shutdown only after callback publication proves quiescence, and restore the prior main-thread mask last.
- Treat `request_process` as satisfied by continuous processing, dispatch `request_callback` on the main thread, and terminate explicitly on restart until Increment 8 owns restart policy.
- Keep unavailable GUI/state options explicit: ordinary GUI policy falls back headlessly with a warning, while required/scaled GUI and requested state operations fail with their documented statuses.
- Record the direct Linux boundary in ADR 0006 and ABI-test `epoll_event`, `signalfd_siginfo`, and imported procedure signatures.

### Tests

- Reactor FD add/modify/remove and stale-generation protection.
- Monotonic timer ordering, cancellation, self-cancellation, and callback registration changes.
- No host signal handler is installed; blocked signals are consumed through `signalfd` and only the main thread performs actions.
- Signal ordering/idempotency and shutdown overriding restart/show.
- PID-file success, collision, rollback, and removal.
- `request_callback()` reaches `plugin.on_main_thread()` within simulated deadline.
- No busy-wait when idle.
- Public process tests cover PID publication/removal, rate-limited `SIGUSR1`/`SIGUSR2`, and clean `SIGINT`/`SIGTERM` against isolated PipeWire-JACK.
- Fake-backed control tests cover post-callback JACK shutdown adoption, CLAP process-error termination, and `on_main_thread()` dispatch.

### Manual verification

Run the headless host, send all supported signals, inspect PID-file behavior, and stop JACK to verify orderly exit.

### Human review gate 7

Review signal safety, reactor reentrancy, timing guarantees, generation tokens, fairness, PID-file semantics, and absence of polling sleeps.

## 15. Increment 8 — Host extensions, parameters, latency, and restart

**Planned version:** 0.0.9-dev
**Review split:** 8A and 8B approved; Increment 8 complete

### Goal

Implement the stable host services needed for broad plugin correctness before adding state and GUI.

### Review unit 8A — main-thread services and latency

**Status:** Approved.

#### Implementation

- Add exact stable CLAP ABI declarations for `clap.state` dirty notification, `clap.latency`, `clap.timer-support`, and `clap.posix-fd-support`.
- Advertise timer/FD extensions only when a complete application service table is attached before plugin creation; retain stable vtable/context storage through plugin destruction.
- Add an application-owned fixed-capacity registry for 256 timers and 256 POSIX FDs, mapped to generation-safe reactor tokens.
- Dispatch periodic timers and level-triggered FD read/write/error readiness only on the original CLAP main thread.
- Reject duplicate/stale registrations, support self-unregistration, and remove registrations after audio quiescence but before plugin destruction.
- Coalesce `clap.state.mark_dirty()` without implementing state serialization.
- Query plugin latency after activation, publish it atomically to the JACK latency callback, and invoke total-latency recomputation only from the control plane.
- Keep `clap.params`, host audio/note rescans, restart, reconnection, and sleep/wake unadvertised or explicitly deferred.

#### Tests

- C/Nim layout, field-offset, constant, and function-pointer ABI checks for every new bound type.
- Stable extension advertisement with and without a complete service table.
- Main-thread callback context, dirty/latency coalescing, and foreign-thread rejection.
- Timer exact capacity, overflow/recovery, periodic rearm, self-cancellation, and stale IDs.
- FD duplicate/modify/unregister, level-trigger mapping, stale events, and repeated cleanup.
- Independent CLAP fixture registration during `plugin.init()`, real epoll dispatch, dirty notification, 257-frame latency, and teardown ordering.
- JACK latency direction, saturation, and control-plane recomputation.
- Product-profile generated-C callback audit and live PipeWire-JACK regression/instrumentation.

#### Manual verification

Run the public headless host with an independent plugin, inspect its JACK ports/latency, and verify clean signal shutdown. The fixture task provides deterministic timer/FD controls.

#### Human review gate 8A

Approved by owner review. Before work begins on 8B, present and obtain approval for
a fresh pre-code package covering its parameter concurrency, restart, rescan,
reconnection, and sleep/wake boundaries.

### Review unit 8B — parameters, restart, rescans, and sleep/wake

**Status:** Approved.

#### Implementation

- Implement complete `clap.params`, including parameter output, gestures, rescans, cookie invalidation, dirty tracking, and flush scheduling without overlap with `process()`.
- Implement `request_restart`, `request_process`, and process sleep/wake policy.
- Implement safe stop/deactivate/rescan/rebuild/reactivate restart sequence.
- Advertise complete `clap.audio-ports` and `clap.note-ports` host extensions and implement name/structural rescans.
- Preserve/reconnect compatible JACK connections when practical; otherwise report losses clearly per requirements.
- Add restart-loop coalescing/rate protection.
- Expand fixture behavior for every request, active/inactive flush context, rescan, and restart failure.

#### Tests

- Parameter extension advertisement, active/inactive flush, output/dirty transport, bounded overflow, rescans, and cookie invalidation.
- Sleep, event/request wake, and connected-audio conservative policy.
- Restart caused by plugin, sample rate, block size, and structural port rescan.
- Restart failure leaves silence and exits/recovers according to policy.
- Repeated restart requests cannot create a tight main-loop cycle.
- Structural port rebuild quiescence and explicit connection preservation/loss evidence.

#### Manual verification

Use the fixture to trigger every parameter/request/rescan path while processing. Smoke-test one real parameter-using plugin.

#### Human review gate 8B

Review parameter concurrency and flush/process exclusion, restart state machine, dynamic port behavior, reconnection policy, sleep/wake behavior, and loop protection before approving Increment 8.

## 16. Increment 9 — State load/save transactions

**Planned version:** 0.0.10-dev
**Status:** Approved.

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

**Review unit status:** Approved after the 10A review gate.

The 10A review unit implements:

- Xlib selection and the ownership/error decision in ADR 0007.
- The backend-neutral `WindowHost` values and a concrete dynamically loaded X11 window.
- XEmbed-ready parent-surface ownership, event processing, WM close classification, sizing, and cleanup under Xvfb.
- An independent spike with no third-party plugin GUI code.

The 10A review gate is complete; unit 10B is a separate review unit.

### Review unit 10B — CLAP GUI integration
**Current review unit status:** Implemented in the current worktree; pending human review gate 10B.

- Add `GuiController` state machine.
- Negotiate embedded X11 first, then supported floating fallback.
- Follow CLAP create/size/parent/show/hide/destroy order.
- Implement host GUI resize/show/hide/closed callbacks through coalesced main-thread requests.
- Connect X11 readiness to the reactor.
- Implement `--show-gui`, `--hide-gui`, `--no-gui`, `--require-gui`, and `--gui-scale` policy.
- Implement `SIGUSR1` show and `SIGUSR2` hide.
- Make WM close hide/unmap without stopping audio, and clean up/recreate after actual surface destruction.
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
| 1 — FFI/ABI | Approved | Review unit 1B | Includes verified ownership, callbacks, and RT spike |
| 2 — CLAP catalog | Approved | Review unit 2B | Loader, catalog, `list`, discovery, and `scan` accepted |
| 3 — CLAP lifecycle | Approved | Review unit 3B | Host bridge, instance lifecycle, immutable port plans, and render negotiation accepted |
| 4 — JACK/RT harness | Approved | Review units 4A, 4B, and 4C | Checked loading, fake-backed mechanics, live PipeWire-JACK integration, and strengthened RT evidence accepted |
| 5 — Audio vertical slice | Approved | Review unit 5 | Internal grouped zero-copy CLAP/JACK float32 slice, lifecycle rollback, live capture, and RT evidence accepted |
| 6 — MIDI/events | Approved | Review units 6A and 6B | Fixed-capacity event bridge and isolated live multi-port MIDI/SysEx evidence accepted |
| 7 — Reactor/signals | Approved | Increment 7 review | Public headless run, epoll/signalfd reactor, orderly shutdown, main-thread callbacks, and atomic PID files accepted |
| 8 — Host extensions/restart | Approved | Review units 8A and 8B | Main-thread timer/FD services, dirty notification, JACK latency, bounded parameter transport, restart/rescan, sleep/wake, and compatible reconnection/loss evidence accepted |
| 9 — State | Approved | Increment 9 review | Bounded 64 KiB/64 MiB CLAP streams, pre-configuration load, clean-signal transactional save, rollback, and live evidence accepted |
| 10 — GUI | In progress | Review unit 10B pending | 10A Xlib window-host spike approved; 10B CLAP GUI negotiation/controller, dynamic X11 adapter, callback transport, CLI policy, fixture, unit, and Xvfb evidence implemented in the current review worktree |
| 11 — Release candidate | Not started | — | — |
| 12 — MVP release | Not started | — | Target 0.1.0 |

Allowed statuses: `Not started`, `In progress`, `Changes requested`, `Approved`, and `Deferred`.

## 21. Risk register

| Risk | Earliest mitigation | Release evidence |
|---|---|---|
| Nim/C ABI mismatch | Increment 1 probes and ABI tests | ABI CI on supported architectures |
| Nim runtime activity on JACK foreign thread | Shared ARC/panic profile plus Increments 1 and 4 instrumentation | Sustained `testRt` report |
| Defect or runtime check unwinds through C | Increment 4A profile plus callback-local checks policy | Generated-C/module audit and negative canary |
| Eager or partial JACK DSO loading | Increment 4A checked `JackApi` ownership | Missing-library/symbol/rollback tests and ELF dependency check |
| Incorrect CLAP lifecycle/thread role | Increment 3 state machine, Increment 5 vertical slice | Fixture and independent-plugin tests |
| MIDI event ordering/capacity corruption | Increment 6 fixed arena and k-way merge tests | Boundary/stress/sanitizer results |
| Plugin callback reentrancy | Increments 7–8 deferred request dispatch | Reentrant fixture tests |
| Restart races/use-after-free | Increments 4, 5, and 8 quiescence tests | Repeated restart stress |
| X11/XEmbed incompatibility | Increment 10A isolated spike | Xvfb, GUI fixture, and real-plugin matrix |
| GUI timer/FD leaks | Increments 8 and 10 | Repeated GUI lifecycle checks |
| State-file corruption | Increment 9 transaction design | Failure-injection tests |
| Scope growth obscures review | Review-size rule and per-increment non-goals | Progress/review record |
| Null CLAP transport crashes a non-conforming plugin | Increment 5 fixture/independent-plugin smoke tests; retain approved null policy | Compatibility matrix and documented limitation |
| DSO unload after misbehaving plugin threads/TLS | Increment 11 trust documentation and double-load hardening | Security/limitations documentation |
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

## 23. First action after each review gate

After the human approves a completed increment or review unit, update the progress table, current state, verification counts, and next-session gate. Increment 9 and review unit 10A are approved. Increment 10B is implemented in the current review worktree and awaits review of the CLAP GUI call order, callback transport, controller ownership, X11 integration, and focused/full verification evidence.
