# Document and Implementation Review — Findings and Dispositions

**Review date:** 2026-08-28
**Reviewed baseline:** `main` at `642b629`, version `0.0.5-dev`
**Disposition approval:** 2026-08-28 Increment 4 pre-code review
**Implementation approvals:** Increment 4A, Increment 4B, and Increment 4C reviewed and approved

Increment 3B remains approved. The owner approved the dispositions below and reviewed
and approved Increment 4A, Increment 4B, and Increment 4C. This register distinguishes
accepted, implemented, and deliberately deferred work; deferred findings remain review
inputs for their named increments rather than silently becoming product behavior.

## Approved dispositions

| # | Approved disposition | Target/status |
|---:|---|---|
| 1 | Use `--panics:on`; callbacks also disable checks and validate explicitly. | Implemented and approved in 4A |
| 2 | Pin ARC, threads, panics, and signal behavior in one product/test profile. | Implemented and approved in 4A |
| 3 | Replace eager JACK imports with a checked move-only DSO/procedure table. | Implemented and approved in 4A |
| 4 | Disable Nim signal handlers now; block/consume signals explicitly before public JACK-backed `run`. | Build part approved in 4A; signal service in 7 |
| 5 | Observe freewheel transitions but remain in `CLAP_RENDER_REALTIME`; offline rendering remains unsupported. | Notification policy implemented and approved in 4B; CLAP mode remains in 5 |
| 6 | Apply bounded allocation-free rules to every JACK-invoked callback; latency uses only mandated JACK APIs. | Behavior approved in 4B; strengthened live/static evidence implemented and approved in 4C |
| 7 | Retain strict validator-compatible port checks unless independent plugins prove a compatibility problem. | Accepted current behavior |
| 8 | Retain `transport = nil` and record its compatibility risk. | Risk recorded in 4A; runtime behavior in 5 |
| 9 | Treat `TAIL` and `CONTINUE_IF_NOT_QUIET` conservatively as continued processing. | Increment 5 |
| 10 | Document trusted in-process unload risk and add same-DSO double-open coverage. | Increment 11 hardening |
| 11 | Add xrun/freewheel support now; defer connection/reconnection and MIDI-loss APIs to their owning increments. | ABI approved in 4A; callbacks approved in 4B; remaining APIs in 6/8 |
| 12 | Realize ports transactionally, diagnose the failed count/name, validate actual JACK name limits, and roll back completely. | Implemented and approved in 4B |
| 13 | Build/test `AudioRoleGuard` in 4B and connect `clap.thread-check` atomically with CLAP processing in 5. | Guard implemented and approved in 4B; CLAP connection remains in 5 |
| 14 | Keep current scan policy; document partial-failure status and `CLAP_PATH` relative/tilde behavior. | Implemented and approved in 4A |
| 15 | Add independent-plugin smoke evidence with the audio vertical slice. | Increment 5 |
| 16 | Audit complete RT-only generated modules/call paths and require a failing negative canary. | Implemented and approved in 4C |
| 17 | Retain Nim counters and add C allocation/lock/I/O instrumentation around live callbacks. | Implemented and approved in 4C, including deallocation and print categories |
| 18 | Keep fixture refactoring separate; add double-load coverage with hardening. | Increment 11/test cleanup |
| 19 | Add CI/release matrices later; use the available isolated PipeWire Dummy-Driver for Increment 4 integration. | Isolated integration implemented and approved in 4C; matrices remain in 11 |
| 20 | Close stale plan-state drift; retain JACK naming-boundary checks during realization. | Naming checks implemented and approved in 4B |

The detailed text below preserves the original evidence and suggested resolutions for
audit history. Where it conflicts with the approved table, the approved disposition
controls.

## Original severity summary

| # | Finding | Severity | Earliest affected increment |
|---:|---|---|---|
| 1 | `raises: []` does not stop Defects crossing the ABI boundary | High | Already live (3A/3B) |
| 2 | Shipped binary and RT evidence use different memory managers | High | Already live |
| 3 | `{.dynlib.}` loads `libjack.so.0` eagerly at process start | High | 4 |
| 4 | Nim signal handlers and RT-thread signal delivery | High | 7 |
| 5 | JACK freewheeling absent from documents and FFI | High | 4–5 |
| 6 | RT prohibitions specified only for the process callback | High | 4 |
| 7 | Strict port validation rejects real, harmless plugins | Medium | Already live (3B) |
| 8 | `transport = nil` is a stated MUST and a compatibility hazard | Medium | 5 |
| 9 | Process status handling incomplete (`TAIL`, `CONTINUE_IF_NOT_QUIET`) | Medium | 5 |
| 10 | DSO unload hazards and entry init/deinit counting | Medium | Already live (2) |
| 11 | JACK FFI missing what the SHOULD requirements need | Medium | 4, 8 |
| 12 | Port-count bounds exceed what a JACK server accepts | Medium | 4 |
| 13 | `is_audio_thread` currently lies by construction | Medium | 4–5 |
| 14 | `scan` exit status, default roots, and `CLAP_PATH` expansion | Medium | Already live (2) |
| 15 | Fixture tautology: no independent implementation until Increment 11 | Testing | 5 |
| 16 | Generated-C audit is non-transitive and lacks a negative control | Testing | Already live |
| 17 | `nimAllocStats` is not sufficient real-time evidence | Testing | 4 |
| 18 | Fixture build scalability and missing double-load case | Testing | Already live |
| 19 | No CI exists; ABI matrix and PipeWire matrix unproven | Testing | Already live |
| 20 | Document drift between `DESIGN.md`, the plan, and the implementation | Minor | Already live |

## High severity

### 1. `raises: []` does not stop Defects crossing the ABI boundary

`REQUIREMENTS.md` section 13.3 and `DESIGN.md` sections 6.3 and 22 treat `raises: []` as the
guarantee that no exception crosses a C ABI boundary.

In Nim, `raises: []` tracks `Exception` only. `IndexDefect`, `OverflowDefect`, `NilAccessDefect`,
and `AssertionDefect` derive from `Defect`, and with the default `--panics:off` they are raised
and unwound exactly like exceptions. Any range, index, or overflow check inside a `{.cdecl.}`
callback can therefore unwind into CLAP or JACK.

`src/pluginhost/clap/host_bridge.nim` already mitigates this locally with
`{.push checks: off, stackTrace: off, lineTrace: off.}`, but the rule is stated nowhere as an
invariant and nothing enforces it for future callback modules.

Suggested resolution:

- Mandate `--panics:on` for the product binary and for every callback/RT test build.
- State the "checks off plus explicit validation" rule for C callbacks in `DESIGN.md` section 12.
- Add "no Defect can unwind out of a C callback" to the `DESIGN.md` section 22 checklist.
- Note in `MVP_IMPLEMENTATION_PLAN.md` section 5.3 that `raises: []` alone is insufficient.

### 2. Shipped binary and RT evidence use different memory managers

`config.nims` contains only the Nimble path stanza. In `pluginhost.nimble`, `compileTestBinary`
and the default `nimble build` pass no `--mm` or `--threads` flags, so the product and the unit
suite use ORC, while `runAbiTests` and `runRtTests` build with `--mm:arc --threads:on`.

Consequences:

- `REQUIREMENTS.md` section 14's "release builds SHOULD use ARC" is not actually implemented.
- Every allocation and foreign-thread claim is proven for a configuration users never run.
- `tests/rt/audit_generated_callback.py` inspects `build/nimcache/rt`, not the binary's cache,
  so the audited C is not the shipped C. ORC emits additional cycle-collector calls.

Suggested resolution: pin memory manager, thread, and panic flags in `config.nims` or one shared
nimble helper so build, unit, fixture, ABI, and RT builds agree, and run the generated-C audit
over the shipped configuration.

### 3. `{.dynlib.}` loads `libjack.so.0` eagerly at process start

`src/pluginhost/jack/ffi.nim` uses `{.push cdecl, dynlib: JackLibrary, ...}`. Nim resolves
dynlib symbols in the module init section, not lazily at first call. As soon as any reachable
code path imports this module, `pluginhost --help`, `--version`, `list`, and `scan` will abort
at startup on a machine without JACK, with Nim's untyped `could not load: libjack.so.0` message.

This violates `REQUIREMENTS.md` section 9.1 ("identify the requested client/server and summarize
the JACK status flags") and section 15 (subsystem-tagged diagnostics), and it makes the
JACK-free information commands depend on JACK.

Suggested resolution: resolve JACK through the existing checked owner in
`src/pluginhost/platform/linux/dynlib.nim` (or `--dynlibOverride` plus manual resolution) so
absence becomes a typed `hsJack` error, and keep `list`, `scan`, `--help`, and `--version`
independent of libjack.

### 4. Nim signal handlers and RT-thread signal delivery

Two traps that `REQUIREMENTS.md` section 6.4 and Increment 7 of the plan do not cover:

- Nim installs its own handlers for `SIGINT`, `SIGTERM`, `SIGSEGV`, and others unless the build
  uses `-d:noSignalHandler`. The default `SIGINT` handler quits without running the orderly
  shutdown path required by section 6.4.
- POSIX delivers process-directed signals to an arbitrary thread that has the signal unblocked,
  which can be the JACK real-time thread. The prescribed async-signal-safe self-pipe write then
  performs a syscall inside the process callback and can cause an xrun.

Suggested resolution: build with `-d:noSignalHandler` and install handlers explicitly; block the
handled signals with `pthread_sigmask` before `jack_client_open` so JACK's threads inherit the
mask; then use `signalfd` or a dedicated handler thread on the main thread only. Record this in
`DESIGN.md` section 5.7 and in Increment 7.

### 5. JACK freewheeling absent from documents and FFI

`jack_set_freewheel_callback` is not declared in `src/pluginhost/jack/ffi.nim`, and freewheeling
appears nowhere in `REQUIREMENTS.md` section 9 or `DESIGN.md` section 11.

Any other client (Ardour export, `jack_capture`, `jack_freewheel`) can put the graph into
freewheel mode, after which the process callback runs far faster than real time. This interacts
directly with the already-implemented render negotiation in
`src/pluginhost/clap/port_inspector.nim`, which currently hard-fails when a plugin rejects
`CLAP_RENDER_REALTIME`; `clap.render` exists precisely to switch to `CLAP_RENDER_OFFLINE` for
this case.

Suggested resolution: decide explicitly. Either register the freewheel callback and switch render
mode on transitions, or document freewheel as unsupported with defined, predictable behavior.
Either way, add a requirement and a design note.

### 6. RT prohibitions specified only for the process callback

`REQUIREMENTS.md` section 13.2 and `DESIGN.md` section 8.2 constrain the JACK process callback and
host callbacks reachable from plugin `process()`. They do not constrain the other JACK callbacks:

- The buffer-size callback runs in the real-time thread on JACK1.
- The xrun, latency, and future port-connect callbacks run concurrently with processing.
- The latency callback must not call `jack_recompute_total_latencies`.

Without an explicit rule, Increment 4 can legitimately allocate in the buffer-size callback and
still pass review.

Suggested resolution: extend the prohibition to every JACK-invoked callback, and state the
latency-callback restriction in `REQUIREMENTS.md` section 9.5 and `DESIGN.md` section 5.4.

## Medium severity

### 7. Strict port validation rejects real, harmless plugins

`src/pluginhost/clap/port_inspector.nim` hard-fails the entire run on:

- `CLAP_AUDIO_PORT_IS_MAIN` at an index other than zero,
- `mono` or `stereo` port type disagreeing with the channel count,
- `PREFERS_64BITS` without `SUPPORTS_64BITS`.

None of these threaten memory safety, and shipping plugins do violate them. The current policy
makes a specification nit render a plugin unhostable, which is a worse user outcome than a
rate-limited warning.

Suggested resolution: split validation into "must reject" (channel count, IDs, name termination,
bounds, anything the real-time map depends on) and "warn and normalize". Additionally, in-place
pair validation does not check that paired ports agree on channel count and port type, and the
host never processes in place, so the field's status as informational should be stated.

### 8. `transport = nil` is a stated MUST and a compatibility hazard

`REQUIREMENTS.md` section 7.4 mandates a null transport and section 3 lists transport as a
non-goal. CLAP permits null, but plugins that dereference it unconditionally will crash
in-process, and the host offers no crash isolation.

Suggested resolution: record this as a compatibility risk in the plan's section 21 risk register
and keep a cheap escape hatch in mind (a static zero-flag `clap_event_transport`), rather than
discovering it during acceptance scenario 14.

### 9. Process status handling incomplete

`REQUIREMENTS.md` section 7.4 defines behavior for `CLAP_PROCESS_ERROR` and `CLAP_PROCESS_SLEEP`
only. `CLAP_PROCESS_TAIL` and `CLAP_PROCESS_CONTINUE_IF_NOT_QUIET` are declared in
`src/pluginhost/clap/ffi.nim` but have no specified host behavior.

Suggested resolution: define both before Increment 5. The safest initial policy is to treat both
as `CONTINUE` and to consume no `clap.tail` extension.

### 10. DSO unload hazards and entry init/deinit counting

`vendor/clap/include/clap/entry.h` explicitly documents that `init()` and `deinit()` may be called
multiple times in a process and that implementations should count them. Beyond that, `dlclose` on
a plugin that started threads, registered `atexit` handlers, or uses static TLS is a well-known
crash source, and `scan` unloads every candidate it inspects.

None of this is covered by the documents.

Suggested resolution: document the trust and unload model. Options worth considering are
`RTLD_NODELETE` for run mode, skipping `dlclose` at process exit, and fork-per-candidate for
`scan`. The plan's section 21 currently lists third-party plugin crashes as an accepted risk with
no mitigation option; fork-per-candidate would give `scan` genuine isolation cheaply.

### 11. JACK FFI missing what the SHOULD requirements need

`src/pluginhost/jack/ffi.nim` does not declare:

- `jack_port_connected`, needed for section 9.3's `constant_mask` handling of disconnected inputs.
- Port registration and port connect callbacks, needed to track connection state safely.
- `jack_get_ports`, `jack_connect`, `jack_free`, needed for section 9.4's reconnection SHOULD.
- `jack_midi_get_lost_event_count`, so JACK-side MIDI loss is invisible although section 16
  requires reporting dropped events.

Also, section 9.2's MUST-register list omits the xrun callback even though section 16 requires
xrun reporting; `jack_set_xrun_callback` is already declared.

### 12. Port-count bounds exceed what a JACK server accepts

`MaxAudioChannelsPerDirection` is 4,096 per direction, so a plan can require 8,192 JACK ports.
JACK2's default server port limit is far lower. The bound is defensible as a CLAP-side sanity
limit, but `JackBackend` must fail with a clear, non-partial diagnostic and unregister cleanly.

Related naming issue: canonical short names and aliases are generated in the CLAP layer before a
JACK client exists. `jack_port_name_size()` (which includes the client-name prefix) and
`jack_client_name_size()` can only be checked at realization, and plugin-derived aliases are
unbounded in length.

### 13. `is_audio_thread` currently lies by construction

`src/pluginhost/clap/host_bridge.nim` returns `false` unconditionally from
`hostIsAudioThread`. That is correct today because no audio role exists, but it must land
atomically with `AudioRoleGuard` in Increment 4 or 5. Plugins built with clap-helpers assert on
`is_audio_thread()` inside `process()`.

Separately, main-thread identity is captured per bridge in `newClapHostBridge` via
`pthread_self()`. If a bridge is ever constructed off the reactor thread, thread-check silently
misreports. Binding the main-thread identity once at the composition root would be safer.

### 14. `scan` exit status, default roots, and `CLAP_PATH` expansion

- `REQUIREMENTS.md` section 6.3 requires per-candidate failures to be reported without aborting
  the scan, but does not require a non-zero exit status. The implementation returns 3 whenever
  any issue occurred, which conflates "found plugins, one candidate failed" with failure and is
  awkward for scripting.
- `src/pluginhost/discovery/paths.nim` omits `/usr/local/lib/clap`. This is faithful to
  `entry.h`, but locally built plugins commonly live there.
- `CLAP_PATH` entries are not tilde-expanded and relative entries have undefined behavior. The
  requirements do not specify either case.

## Testing methodology

### 15. Fixture tautology

Every CLAP fixture under `tests/fixtures/clap/` is written from the same reading of the headers as
the host, so the suite cannot detect a misread specification, which is the highest-value failure
mode for this project. The plan defers all independent-implementation evidence to Increment 11
(acceptance scenario 14).

Suggested resolution: pull at least one independently implemented plugin (for example the
free-audio `clap-plugins` reference set) into a smoke test at Increment 5, when lifecycle
correctness is cheapest to fix.

### 16. Generated-C audit is non-transitive and lacks a negative control

`tests/rt/audit_generated_callback.py` inspects only the bodies of an explicit marker list and
requires exactly one definition per marker, which is a good positive control. However:

- It does not follow callees, so any future real-time helper is unaudited unless someone remembers
  to add a marker. This will not scale to `RtEngine`.
- There is no negative control proving the forbidden-pattern regexes still match current Nim
  codegen, so the audit could silently become vacuous.
- It runs only against the ARC RT nimcache, not the shipped configuration (see finding 2).

Suggested resolution: audit by module or call graph, add a deliberately allocating canary function
that the audit must flag, and run the audit over the product build.

### 17. `nimAllocStats` is not sufficient real-time evidence

The RT task uses `-d:nimAllocStats`, which observes Nim's allocator only. It does not see libc
`malloc` (which is what `-d:useMalloc` produces, and `-d:useMalloc` is likely wanted anyway for
foreign-thread allocator safety and for ASan or valgrind to be usable), plugin allocations, futex
contention, or syscalls.

Suggested resolution: for acceptance scenario 13, plan a real interposer (LD_PRELOAD over
`malloc`, `free`, `mmap`, `write`, or ASan) around a live JACK run, and consider `-d:useMalloc`
plus a `nimble sanitize` task as already sketched in `DESIGN.md` section 17.

### 18. Fixture build scalability and missing double-load case

`nimble testFixtures` unconditionally recompiles 55 shared objects through `exec` with no
dependency tracking, one per behavior mode.

- Consider a runtime mode selector (environment variable) for the majority of cases, keeping
  separate DSOs only where fresh entry state matters.
- Nothing currently tests loading the same DSO twice in one process, which is exactly the case
  `entry.h`'s init/deinit counting rationale exists for (see finding 10).

### 19. No CI exists

`REQUIREMENTS.md` section 14 requires ABI checks on each supported architecture and section 17.1
requires a PipeWire test matrix, but the repository contains no CI configuration.

- `nimble testAbi` silently depends on system JACK headers and `pkg-config` with no skip path or
  actionable diagnostic.
- The `arm`, `arm64`, `mips`, and `powerpc` packing branch for `JackLatencyRange` in
  `src/pluginhost/jack/ffi.nim` is untested, which is precisely what ABI tests exist to catch.

## Minor: document drift

- `DESIGN.md` section 15 lists `clap/catalog.nim`, `clap/lifecycle.nim`, and `clap/ports.nim`. The
  implementation uses `clap/port_inspector.nim` plus `domain/port_plan.nim` and folds catalog and
  lifecycle into `loader.nim` and `instance.nim`. `AGENTS.md` is accurate; `DESIGN.md` is stale.
- `AudioChannelPlan.shortName` and `alias` are JACK naming policy produced inside the CLAP
  adapter. `DESIGN.md` section 6.2 sanctions this, but it sits awkwardly against sections 3.6 and
  7, and the JACK-specific length and uniqueness rules can only be enforced in `JackBackend`. This
  deserves an explicit decision rather than an implied one.
- `MVP_IMPLEMENTATION_PLAN.md` section 23 instructed the next session to present the
  Increment 3A package in the reviewed tree; the Increment 3 approval-state update corrects it.

## Suggested handling order

1. Findings 1, 2, and 3 are pre-Increment-4 build and boundary decisions and are the cheapest to
   fix now.
2. Findings 5, 6, 11, and 12 should be resolved as requirements and design text before Increment 4
   is designed.
3. Findings 7, 9, 10, and 14 are behavior-policy decisions that touch already-implemented code and
   should be settled during or immediately after the Increment 3B review.
4. Findings 15 through 19 are testing-strategy changes that should be reflected in the plan's
   sections 5.2, 5.3, and 6 before more suites are added.
