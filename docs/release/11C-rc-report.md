# Increment 11C Public Acceptance and Release-Candidate Report

**Review unit:** 11C — Public acceptance, compatibility, and release candidate  
**Status:** Approved at human review gate 11 on 2026-09-11. The release
candidate remains blocked and no release version or artifact was created.
**Date:** 2026-09-11  
**Scope:** Public-process acceptance, installed-plugin compatibility, foreign-thread teardown evidence, no-event host overhead, release documentation, and fail-closed release-candidate task wiring.

## 1. Result vocabulary and scope boundary

- **VERIFIED** — the named implementation path and executed evidence support the claim.
- **BLOCKED** — execution or completion requires an unavailable prerequisite or an owner decision; no release claim is made.
- **DEFERRED** — intentionally left for a later increment or outside the approved MVP scope.
- **LIMITED** — the tested path passes, but the stated limitation prevents a broader claim.

Increment 11C adds only release-facing test support, acceptance orchestration,
documentation, and verification-task wiring. Production runtime behavior was not
expanded. The public acceptance harness uses an independently compiled C JACK
peer and independently compiled integration-only CLAP fixture where a host/plugin
teardown race cannot be represented by the approved FFI fixture.

The implementation preserves the development metadata (`VERSION=0.0.10-dev`
and Nimble package version `0.0.10`). No release-candidate binary or checksum
exists in this worktree.

## 2. Release-gating boundary

The preceding review gate for Increment 11 is gate 10, and the progress table
records Increment 10 and review units 10A, 10B, and 10C as approved. The
versioning rule in `MVP_IMPLEMENTATION_PLAN.md` §3 therefore permits the 11C
release-preparation work. Section 11C adds the stricter requirement that
`VERSION`, Nimble metadata, fixtures, and tests change only after all prior
evidence passes.

The current evidence is not complete: scenarios 5, 7, 8, and 9 remain blocked.
The missing witnesses are the full manual public GUI/tray row, the combined
GUI-service witness, an installed-plugin GUI parameter action, and the
two-process changed-state restore row. The required Memcheck run is also
blocked by the workstation's stripped dynamic loader. The
worktree therefore remains on the development version
(`VERSION=0.0.10-dev`, Nimble package version `0.0.10`) and no release
candidate binary or checksum was created.

With the required plugin environment set, `nimble releaseCandidate` fails closed
before compilation with:

```text
release candidate version is not selected: 0.0.10-dev
```

This preserves the stricter 11C evidence boundary and avoids creating an RC
artifact while required evidence remains blocked. No owner interpretation of a
document conflict is required; the remaining blockers are recorded in §12.

## 3. Release acceptance checklist

The checklist follows `REQUIREMENTS.md` §17.2. A blocked row is not counted as
a pass.

| # | Scenario | Result | Evidence and limitation |
|---:|---|---|---|
| 1 | Synth | **VERIFIED** | Public process with Vital 1.6.4 received JACK MIDI and produced non-zero samples on both audio outputs. The release peer reported `audio-inputs=0 audio-outputs=2 midi-inputs=1 outputs=12288 nonzero=12144 channel-errors=0 errors=0`. |
| 2 | Effect | **VERIFIED** | Public process with Surge XT Effects 1.3.4 processed generated stereo input. The peer reported `audio-inputs=4 audio-outputs=2 outputs=12288 nonzero=12160 changed=12288 channel-errors=0 errors=0`. Both output channels were checked independently. |
| 3 | Multiple ports | **VERIFIED** | `build/fixtures/clap/ports_valid.clap`, ID `org.pluginhost.fixture.ports`, realized exactly three audio inputs, five audio outputs, two MIDI/note inputs, and one MIDI/note output. `release_peer.c` sorts JACK discovery results before comparison, so this public row verifies the exact name set/count/type/direction, not JACK enumeration or registration order. Plan and realization ordering are covered separately by `tests/unit/test_port_plan.nim`, `tests/unit/test_jack_ports.nim`, and `tests/fixtures/test_clap_ports.nim`. |
| 4 | MIDI timing | **VERIFIED** | `nimble testIntegration` passed the isolated live JACK MIDI/CLAP event case for multiple offsets, ordering, SysEx lifetime, lifecycle, quiescence, and instrumentation. |
| 5 | GUI | **BLOCKED for the full manual public row** | `nimble testGui` passed Xvfb window lifecycle, resize, WM-close hide/reopen, controller negotiation, and StatusNotifierWatcher registration. A manual desktop run of a public installed plugin covering signal hide/show and a real tray click was not executed in this review run; those actions remain a documented recipe, not a release pass. |
| 6 | Headless | **VERIFIED** | Public acceptance and foreign-thread public-process tests used `--no-gui --no-start-server` with no `DISPLAY` or session-bus address in the invoking environment. Audio/MIDI and clean signal shutdown completed normally. |
| 7 | GUI services | **BLOCKED for the full conjunction** | `tests/fixtures/test_clap_audio.nim` verifies CLAP timer/POSIX-FD dispatch, while `tests/integration/test_x11_window_host.nim` verifies X11 FD responsiveness. The GUI fixture does not request CLAP timers/POSIX FDs, so no single GUI-service witness proves both CLAP services and GUI responsiveness together. |
| 8 | Parameters | **BLOCKED for the full GUI-initiated row** | Existing fixture, unit, hardening, and complete regression suites passed parameter flush, output-event, rescan, dirty-state, bounded transport, and no-deadlock paths. They programmatically trigger the parameter boundary; no installed-plugin GUI control change was witnessed in this review run, so the §17.2 GUI-initiation requirement is not claimed. |
| 9 | State | **BLOCKED for the full cross-process restore row** | Existing state fixtures and `nimble testIntegration` passed bounded streams, clean signal save after quiescence, rollback, and preservation of an existing destination. The public test starts one process with prewritten `PHST9` bytes and saves the same bytes; it does not save changed settings from host A, restart into host B, and observe restored settings. |
| 10 | Restart | **VERIFIED** | Existing fixture, live integration, and complete regression suites passed coalesced restart/rescan, buffer-size reactivation, silence during transition, quiescence, and compatible connection rebuild paths. |
| 11 | JACK loss | **VERIFIED** | New public test stopped the private PipeWire server and observed exit status `4`, empty stdout, a clear JACK-shutdown diagnostic on stderr, and PID-file removal. Output: `11C JACK loss exit=4 stdout-bytes=0 stderr-bytes=110`. |
| 12 | Errors | **VERIFIED** | Existing ABI, fixture, hardening, process-status, and complete regression suites passed missing-library, missing-entry, incompatible/invalid descriptor, plugin-init, activation, process-error, and cleanup paths. |
| 13 | Real time | **VERIFIED for the exercised paths** | `nimble testRt` passed the generated callback audit and negative allocation canary. The no-event live overhead run reported zero allocations, deallocations, locks, prints, and prohibited I/O. Memcheck remains blocked as described in §§7 and 12. |
| 14 | Compatibility | **VERIFIED with an auxiliary-output limitation** | Vital, Surge XT, Surge XT Effects, and ZamComp ran as separate public processes through the PipeWire-JACK matrix. The compatibility row checks aggregate output/error behavior; Surge XT has two silent auxiliary outputs, so its separate channel metric was `channel-errors=2` and is reported rather than treated as a runtime error. |

## 4. Installed-plugin compatibility matrix

Descriptor metadata was read by the built host with `list --json` before the
live runs. All public acceptance processes used the isolated PipeWire-JACK
runner at 48 kHz and 64 frames, `--no-gui`, and `--no-start-server`.

| Plugin | Path | ID | Descriptor version | Role | Observed result |
|---|---|---|---|---|---|
| Vital | `/usr/lib/clap/Vital.clap` | `audio.vital.synth` | `1.6.4` | instrument | 2/2 output channels non-zero; timestamped MIDI accepted; `channel-errors=0`. |
| Surge XT | `/usr/lib/clap/Surge XT.clap` | `org.surge-synth-team.surge-xt` | `1.3.4` | instrument | Aggregate output and clean lifecycle passed; 6 outputs, 2 auxiliary outputs silent under this patch, reported as `channel-errors=2` only in the diagnostic metric. |
| Surge XT Effects | `/usr/lib/clap/Surge XT Effects.clap` | `org.surge-synth-team.surge-xt-fx` | `1.3.4` | stereo effect | 4 inputs and 2 outputs; every output channel changed and was non-zero. |
| ZamComp | `/usr/lib/clap/ZamComp.clap` | `com.zamaudio.ZamComp` | empty descriptor version | mono effect | 2 inputs and 1 output; aggregate non-zero output and changed-sample checks passed. |

The live backend was PipeWire-JACK (`libpipewire` 1.6.7 as reported by
`pw-cli`/`pw-dump`, JACK ABI package version `3.1607.0`). There is no `jackd`
executable on this workstation, so no separate JACK1 or JACK2 result is claimed.
X11/D-Bus component tests used disposable Xvfb and session-bus environments;
the headless public rows used no GUI/session-bus environment.

## 5. Foreign-thread teardown race (H-10)

`tests/integration/foreign_thread_race_fixture.c` is an integration-only CLAP
fixture. Its plugin owns a `pthread_t`, repeatedly invokes host process,
callback, and restart requests from that worker, and continues callback batches
while destruction is entering its handshake. `plugin_destroy` marks destruction,
waits until a callback batch has observed that state, requests worker stop, joins
the worker, and aborts if the overlap/join contract is not achieved. Exported
counters make the result observable. The fixture is normally loaded and closed;
no `RTLD_NODELETE` retention or separate Nim bridge reference is used.

Direct lifecycle evidence from `nimble testAcceptance`/the focused test:

```text
11C foreign-thread teardown started=1 batches=10042 during-destroy=2 joined=1 live-allocation-delta=(allocCount: 0, deallocCount: 0)
  [OK] plugin-owned worker joins while callbacks overlap destroy
```

The live allocation comparison covers a 10,000-batch interval while the plugin
is active, after the worker has started and issued callbacks. It does not claim
that third-party plugin creation/destruction is allocation-free. The close
path is proven by the fixture's destroy handshake and exported join counter.

The same fixture was then launched through the public binary:

```text
11C public foreign-thread teardown exit=0 stdout-bytes=0 stderr-bytes=0
  [OK] public SIGTERM witnesses foreign-thread teardown
```

A failed overlap or join causes the fixture to abort, so the public subprocess
result cannot report success while the required teardown handshake is absent.

## 6. No-event host overhead

The live measurement used the real PipeWire-JACK backend, a 48 kHz/64-frame
reference quantum, a no-event `fpmSilence` internal path, and 4,096 process
cycles. It measured host process-callback CPU time only; plugin DSP time was not
included in the reported host interval.

Representative output from the successful `nimble all` run:

```text
11C overhead sample-rate=48000 buffer-size=64 cycles=4096 frames=262144 cpu-ns=56506429 wall-ns=5462250624 us-per-cycle=13.795514892578124 cpu-percent=1.0344898630561263 xruns=0 allocations=0 deallocations=0 locks=0 prints=0 io=0
  [OK] fixed reference quantum reports host-only process cost
```

The snapshot accepts only coherent `processFrames == processCycles * 64`
measurements and resets instrumentation before the baseline/time reads. Xruns
are reported rather than used as a nondeterministic pass/fail condition; this
sample recorded zero. The process path reported zero prohibited allocations,
deallocations, locks, prints, and I/O, and no process errors or late callback
calls.

## 7. Exact verification evidence

The following commands exited `0` unless marked otherwise:

```text
nimble check
nimble build && nimble test
nimble testIntegration
nimble testGui
nimble testRt
nimble testHardening
PLUGINHOST_CLAP_SMOKE_PLUGIN=/usr/lib/clap/ZamComp.clap \
  PLUGINHOST_CLAP_SMOKE_PLUGIN_ID=com.zamaudio.ZamComp \
  PLUGINHOST_RELEASE_INSTRUMENT_PLUGIN=/usr/lib/clap/Vital.clap \
  PLUGINHOST_RELEASE_INSTRUMENT_ID=audio.vital.synth \
  PLUGINHOST_RELEASE_SECOND_INSTRUMENT_PLUGIN='/usr/lib/clap/Surge XT.clap' \
  PLUGINHOST_RELEASE_SECOND_INSTRUMENT_ID=org.surge-synth-team.surge-xt \
  PLUGINHOST_RELEASE_EFFECT_PLUGIN='/usr/lib/clap/Surge XT Effects.clap' \
  PLUGINHOST_RELEASE_EFFECT_ID=org.surge-synth-team.surge-xt-fx \
  PLUGINHOST_RELEASE_COMPATIBILITY_PLUGIN=/usr/lib/clap/ZamComp.clap \
  PLUGINHOST_RELEASE_COMPATIBILITY_ID=com.zamaudio.ZamComp \
  nimble testAcceptance
PLUGINHOST_CLAP_SMOKE_PLUGIN=/usr/lib/clap/ZamComp.clap \
  PLUGINHOST_CLAP_SMOKE_PLUGIN_ID=com.zamaudio.ZamComp \
  PLUGINHOST_RELEASE_INSTRUMENT_PLUGIN=/usr/lib/clap/Vital.clap \
  PLUGINHOST_RELEASE_INSTRUMENT_ID=audio.vital.synth \
  PLUGINHOST_RELEASE_SECOND_INSTRUMENT_PLUGIN='/usr/lib/clap/Surge XT.clap' \
  PLUGINHOST_RELEASE_SECOND_INSTRUMENT_ID=org.surge-synth-team.surge-xt \
  PLUGINHOST_RELEASE_EFFECT_PLUGIN='/usr/lib/clap/Surge XT Effects.clap' \
  PLUGINHOST_RELEASE_EFFECT_ID=org.surge-synth-team.surge-xt-fx \
  PLUGINHOST_RELEASE_COMPATIBILITY_PLUGIN=/usr/lib/clap/ZamComp.clap \
  PLUGINHOST_RELEASE_COMPATIBILITY_ID=com.zamaudio.ZamComp \
  nimble all
```

The complete `nimble all` run passed the existing unit, ABI, RT, fixture,
hardening, live PipeWire-JACK, and X11/D-Bus GUI suites, then all eight new
11C focused cases: four public compatibility/port rows, two foreign-thread
teardown rows, the overhead row, and the JACK-loss row. The pre-11C baseline
contained 279 cases; these eight additional cases also passed in the complete
run.

`python3 -m py_compile tests/integration/run_pipewire_jack.py` also passed.
The runner passed the private PipeWire server PID into the JACK-loss test so the
test can terminate the exact disposable server.

### Sanitizer and Memcheck result

```text
nimble sanitize
```

The generated audit passed for 49 CLAP callback/helper functions, the callback
probe passed, and the negative C-allocation/deallocation canary was rejected as
required. Clang ASan/UBSan passed all nine RT cases. The task then failed before
Memcheck could start the target because the installed stripped
`ld-linux-x86-64.so.2` does not export Valgrind's mandatory `memcmp`
redirection symbol:

```text
valgrind: Fatal error at startup: a function redirection
valgrind: which is mandatory for this platform-tool combination
valgrind: cannot be set up
valgrind: A must-be-redirected function whose name matches the pattern: memcmp
valgrind: in an object with soname matching: ld-linux-x86-64.so.2 was not found
```

This is an environment blocker, not a target finding or a suppression. A
matching glibc debug-symbol package or a non-stripped loader is required for a
Memcheck rerun.

### Conditional RC task

With the required plugin environment set, `nimble releaseCandidate` was
executed and exited non-zero before compilation because the repository still
has the development version. This confirms the task does not silently produce a
wrong-version artifact. `build/release/pluginhost` and
`build/release/pluginhost.sha256` are therefore intentionally absent.

## 8. Tool and environment matrix

| Tool or environment | Observed value |
|---|---|
| OS/kernel | Linux 6.18.37-1-lts |
| Architecture | x86_64 |
| Nim | 2.2.10, `Linux: amd64` |
| C compiler | GCC 16.1.1 (`cc`) |
| Clang | 22.1.6 |
| Python | 3.14.6 |
| Valgrind | 3.25.1 |
| pkg-config | 2.5.1 |
| D-Bus | 1.16.2 |
| X11 | 1.8.13 |
| XCB | 1.17.0 |
| PipeWire libraries | 1.6.7 (`pw-cli`/`pw-dump` compiled-with report) |
| JACK ABI | `pkg-config jack` 3.1607.0; `/usr/lib/libjack.so.0.3.1607` |
| Xvfb | Available and used by `nimble testGui`; this binary does not expose a version through its `-version` option. |

## 9. Manual acceptance recipe and result

The following recipe is the manual handoff for the installed-plugin GUI row;
run it from a real X11 desktop with a session bus and a running JACK server:

```sh
# GUI-enabled synth with PID control.
pluginhost --pid-file "$XDG_RUNTIME_DIR/pluginhost-vital.pid" \
  --client-name vital-gui /usr/lib/clap/Vital.clap

kill -USR2 "$(cat "$XDG_RUNTIME_DIR/pluginhost-vital.pid")"  # hide
kill -USR1 "$(cat "$XDG_RUNTIME_DIR/pluginhost-vital.pid")"  # show
# Resize the embedded window, close it through the window manager, show it
# again, and activate the StatusNotifierItem once to toggle visibility.
kill -TERM "$(cat "$XDG_RUNTIME_DIR/pluginhost-vital.pid")"
```

For an effect and headless process:

```sh
pluginhost --no-gui --no-start-server \
  --client-name surge-fx '/usr/lib/clap/Surge XT Effects.clap'
```

For state persistence and discovery:

```sh
pluginhost --no-gui --load-state ./preset.state \
  --save-state ./preset.state /path/to/plugin.clap
CLAP_PATH="$HOME/.local/lib/clap:/opt/clap" pluginhost scan
```

The manual desktop recipe was **not executed** in this review run. Its
component-level equivalents passed under disposable Xvfb/D-Bus: window map,
resize, hide/show, WM-close recovery, controller recreation, and compatible
StatusNotifierWatcher registration. No manual tray-click or installed-plugin
GUI result is claimed.

## 10. Documentation, dependency, and support status

`README.md` now covers:

- path-only run, explicit `run`, `list`, and `scan` commands;
- every current run/information option and option precedence;
- signals, exit statuses, stdout/stderr policy, and PID ownership;
- `CLAP_PATH`, delegated `HOME`, `DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`, and
  `JACK_DEFAULT_SERVER` behavior and precedence;
- synth, stereo-effect, headless, PID-file GUI-control, state, and scan examples;
- troubleshooting, supported environment, security, tray/icon limits, and
  native-Wayland limitations;
- build/runtime dependencies and license status.

Direct project/dependency status:

- Nim 2.x and its standard library: MIT.
- `argparse` 4.0.2: MIT.
- Vendored CLAP 1.2.10 headers: MIT; upstream source and license remain
  unchanged under `vendor/clap/`.
- GCC/Clang, Binutils, `pkg-config`, and development headers: build-time inputs,
  not bundled into the executable.
- libc, `libdl`, and pthreads: supplied by the target C runtime; common glibc
  installations use LGPL-2.1-or-later, while musl uses MIT. Exact package
  licensing varies by distribution and must be checked on the target.
- JACK: distribution-provided LGPL-2.1-or-later; PipeWire: MIT; X11 libraries:
  MIT/X11; D-Bus: AFL-2.1 or GPL-2.0-or-later. These are not bundled here.
- No project license has been selected. The source is not claimed distributable,
  and third-party CLAP plugins are not distributed.

Supported and deferred matrix:

| Area | Status |
|---|---|
| Linux architecture | x86_64 validated; aarch64 not release-validated. |
| Native plugin ABI | CLAP 1.2.10. |
| JACK runtime | PipeWire-JACK validated; JACK1/JACK2 separately blocked by unavailable `jackd`/server implementations. |
| GUI | X11 embedded/floating fallback and optional D-Bus StatusNotifierItem. |
| Wayland | Native Wayland deferred. |
| Isolation | In-process trusted-plugin model; no crash sandbox. |
| License | Project license decision pending. |

## 11. Changed and excluded sources

Changed implementation/test/documentation files:

- `README.md` — complete manual, environment, dependency, support, and example
  coverage.
- `MVP_IMPLEMENTATION_PLAN.md` — corrected 11C status metadata to distinguish
  implementation/review state from approval.
- `pluginhost.nimble` — release acceptance, integration-only fixture, overhead,
  JACK-loss, and fail-closed RC task wiring.
- `tests/integration/release_peer.c` — bounded independent JACK peer with synth,
  effect, grouped-port, per-channel, and clean-protocol checks.
- `tests/integration/test_release_acceptance.nim` — public synth/effect/ports/
  compatibility process matrix.
- `tests/integration/foreign_thread_race_fixture.c` — integration-only
  plugin-owned worker teardown race fixture.
- `tests/integration/test_foreign_thread_teardown.nim` — direct and public H-10
  lifecycle evidence with allocation interval and exported counters.
- `tests/integration/test_host_overhead.nim` — coherent fixed-quantum host-only
  overhead measurement.
- `tests/integration/test_jack_loss.nim` — public PipeWire/JACK loss status and
  PID cleanup test.
- `tests/integration/run_pipewire_jack.py` — exact private PipeWire PID export
  for the JACK-loss test.
- `docs/release/11C-rc-report.md` — this report.

No generated C output, vendored CLAP header/license, or third-party plugin source
was edited. `build/` and Nim cache outputs are transient verification artifacts.
The two integration C sources are hand-written test support, not generated or
vendored source.

## 12. Known blockers and limitations

1. Release metadata remains at `VERSION=0.0.10-dev` and no RC artifact exists
   until the missing required evidence is complete.
2. Valgrind Memcheck cannot start on this workstation because the stripped
   dynamic loader lacks the mandatory `memcmp` redirection symbol. The ASan/UBSan
   and generated-C portions pass; matching glibc debug symbols or a compatible
   loader is required for Memcheck.
3. JACK1 and JACK2 were not separately run. The live compatibility claim is
   limited to PipeWire-JACK.
4. The full manual public GUI/tray row was not executed; automated X11/D-Bus
   component evidence passes.
5. The installed-plugin GUI parameter-control interaction was not witnessed;
   programmatic parameter/flush/dirty-state paths pass.
6. The GUI-service conjunction remains unwitnessed in one fixture: CLAP timer/
   POSIX-FD dispatch and X11 GUI responsiveness pass separately.
7. A two-process changed-state save/reload witness remains outstanding; current
   state tests prove bounded transaction and rollback behavior.
8. Native Wayland is deferred.
9. x86_64 is the only release-validated architecture; aarch64 remains open.
10. Plugins execute in-process and are not sandboxed; hostile native plugin code,
    plugin-owned threads, TLS destructors, and exit handlers can terminate the
    host or make unload unsafe.
11. No project license was selected, so no source-distribution permission is
    claimed.

## 13. Proposed next increment

After completion of all blocked acceptance evidence (or an owner-approved
requirements correction that changes the applicable acceptance contract),
resolution of the remaining license/environment blockers, and a clean
release-candidate verification, begin **Increment 12 — MVP release and
post-review corrections**. Increment 12, not this review unit, owns the final
release version/tag decision under the implementation plan.
