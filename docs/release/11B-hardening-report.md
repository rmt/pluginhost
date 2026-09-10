# Increment 11B Hardening and Resource Report

**Review unit:** 11B — Fault injection, hostile inputs, and sanitizer evidence
**Status:** Approved after the 11B review gate
**Date:** 2026-09-10
**Scope:** Deterministic ownership/failure checks, bounded hostile inputs, generated-C sanitizer coverage, and host-resource observations

## 1. Result vocabulary and scope boundary

- **VERIFIED** — the named implementation path and executed evidence support the claim.
- **BLOCKED** — execution or completion requires an unavailable external prerequisite; no release claim is made.
- **DEFECTIVE** — a current implementation defect was found and requires a focused correction.
- **DEFERRED** — intentionally left for a later increment.

This unit does not add a production feature, dependency, backend, or GUI API. The
focused executable reuses the checked DSO, CLAP, JACK, X11, D-Bus, reactor,
state, PID, scanner, and parameter boundaries already used by the product. The
one production correction made while bringing up sanitizer coverage is an ABI
representation fix: raw CLAP timer and GUI callbacks now use the C unsigned
32-bit pointer representation (`cuint`) in modules that also contain the
host-owned atomic type. The target ABI suite confirms the resulting layouts.
No generated or vendored source was edited.

The approved 11A contract remains unchanged: statuses, diagnostic stream
selection, warning limiting, quiet-mode behavior, and clean JSON stdout retain
their previous meanings.

## 2. Focused hardening matrix

| Handoff | Boundary and cases | Result | Evidence |
|---|---|---|---|
| H-01 | CLAP entry/module/plugin acquisition; JACK API/client/port/callback setup; reactor registration/close; X11 and D-Bus API/window/tray acquisition; state and PID transactions. | VERIFIED for deterministic host-owned rows; external library internals remain outside attribution. | `tests/hardening/all_hardening_tests.nim`, existing CLAP/JACK/X11/D-Bus/state/PID rollback suites, fixture counters, mapped-DSO and FD checks. |
| H-02 | Descriptor entry/factory failures, malformed metadata, invalid UTF-8, bounded paths, symlink cycles, canonical duplicates, malformed port metadata. | VERIFIED. | Existing 77-case fixture suite plus hardening scanner/path/GUI cases. No arbitrary bytes are dereferenced as CLAP pointers. |
| H-03 | Null and malformed event pointers/headers, sizes, timestamps, unsupported types, overflow/recovery, parameter NaN and invalid values. | VERIFIED. | Existing event/RT suites plus the hardening parameter transport test. Rejection is counted and a valid event recovers the queue. |
| H-04 | Stale and reused reactor tokens, injected add/modify/remove/close failures, timer/FD capacity and retry cleanup. | VERIFIED. | Hardening reactor driver and plugin-service tests; existing main-reactor generation and stale-event tests. |
| H-05 | Repeated DSO load/unload, CLAP create/destroy, JACK activation/deactivation/close, Linux reactor FD loops, state/PID temporary allocation, GUI/tray close. | VERIFIED for host-owned resources covered here and by the existing live GUI/integration suites. | 16 DSO iterations, 12 CLAP iterations, 12 JACK iterations, 24 Linux-reactor FD iterations, 64 state and 64 PID temporary-name slots, repeated close assertions, `/proc/self/fd`, `/proc/self/maps`, fixture counters, and GUI/D-Bus integration. |
| H-06 | ASan/UBSan over the RT callback executable, C-created-thread callbacks, event paths, and fake JACK callbacks. | VERIFIED. | Clang ASan/UBSan executable passed all 9 RT cases with no sanitizer finding. |
| H-07 | Valgrind Memcheck and host-resource ownership observations. | BLOCKED by the workstation Valgrind prerequisite. | `/proc/self/fd`, `/proc/self/maps`, JACK-port, timer/FD, fixture-counter, and temporary-file observations passed. Valgrind 3.25.1 aborts before target startup because the stripped `ld-linux-x86-64.so.2` does not export the mandatory `memcmp` redirection symbol. Installing matching glibc debug symbols or using a non-stripped loader is required; no suppression was used. |
| H-08 | Generated-C forbidden-operation audit and negative allocation canary. | VERIFIED. | Existing audit passed for 49 CLAP callback/helper functions and the negative canary was rejected for C allocation/deallocation. |
| H-09 | Typed failures, cleanup/internal precedence, repeated close/shutdown, and warning/status contract beyond the baseline status cases. | VERIFIED for covered paths. | Hardening typed-failure and repeated-close assertions, 11A status/diagnostic tests, fixture subprocess status cases, and the complete regression run. |
| H-10 | C-created-thread host callbacks and teardown ownership. | BLOCKED for the exact repeated-request-during-shutdown race row. | C-created-thread callback safety and live callback instrumentation passed; a dedicated repeated foreign-thread request/logging race concurrent with teardown is not separately executed and is handed to 11C. |

The only random input seed is **none**. All cases are deterministic controlled
values, fixture modes, injected driver failures, and fixed iteration counts.

## 3. Focused executable

`tests/hardening/all_hardening_tests.nim` contains one independent hardening
suite rather than duplicating the existing unit and fixture executables. It
covers:

- checked dynamic-library lookup, missing symbols, repeated close, mapping
  removal, and retained-owner behavior;
- CLAP/JACK/X11/D-Bus partial acquisition failures;
- repeated CLAP lifecycle and JACK callback/port cleanup with fixture counters;
- reactor generation safety and retryable failure injection;
- Linux epoll FD loops with descriptor-baseline checks;
- full timer capacity, invalid FD registrations, and retryable service cleanup;
- bounded state/PID temporary-name exhaustion and NUL-path rejection;
- PID symlink non-replacement;
- recursive scanner symlink-cycle and canonical-path behavior;
- malformed parameter events, NaN rejection, overflow accounting, and recovery;
- GUI icon, title, display, dimension, and tray boundary rejection before
  optional-library use.

The test process passed **12 focused cases** with exit status `0` under
`nimble testHardening`.

## 4. Sanitizer and ABI correction

The first ASan/UBSan bring-up reached the C-created-thread CLAP host callback
case and UBSan reported a function-pointer type mismatch for the timer
callback. Generated C showed that `ptr uint32` in a module that also imported
the host-owned `_Atomic(uint32_t)` type was emitted as an atomic pointer in one
callback table, while the independent callback probe emitted an ordinary
`uint32` pointer. That is an ABI type error even though both pointees have the
same size.

The raw CLAP timer callback, internal main-thread timer service, host bridge,
and plugin-service callback now use `ptr cuint`; the GUI `get_size` and
`adjust_size` callback pointers use the same C representation, and the instance
adapter converts at the boundary to host `uint32` values. The C/Nim unit
callback implementations were updated accordingly. After the correction:

- `nimble testAbi` passed all **32** ABI cases;
- Clang ASan/UBSan passed all **9** RT cases, including the C-created-thread
  host callback case;
- the normal RT generated-C audit remained unchanged and passed;
- no CLAP/JACK/X11/D-Bus dependency was added.

## 5. Exact verification evidence

### 5.1 Focused hardening

```text
nimble testHardening
```

Exit `0`. All 12 hardening cases passed.

### 5.2 Sanitizer, generated audit, and resource check

```text
nimble sanitize
```

The task ran the generated callback audit first:

- 49 CLAP callback/helper functions passed the complete audit;
- the generated callback probe passed;
- the negative canary was rejected for C allocation/deallocation;
- the Clang ASan/UBSan RT executable passed all 9 cases.

The task then exited `1` before the target process entered Valgrind. Valgrind
reported:

```text
Fatal error at startup: a function redirection which is mandatory for this
platform-tool combination cannot be set up: memcmp in ld-linux-x86-64.so.2
```

This is an environment blocker, not a suppressed target finding. The required
rerun needs matching glibc debug symbols or a non-stripped dynamic loader.

### 5.3 Regression matrix

```text
nimble check
nimble build
nimble test
nimble testAbi
nimble testRt
nimble testFixtures
env PLUGINHOST_CLAP_SMOKE_PLUGIN=/usr/lib/clap/ZamComp.clap nimble testIntegration
nimble testGui
env PLUGINHOST_CLAP_SMOKE_PLUGIN=/usr/lib/clap/ZamComp.clap nimble all
```

All commands above exited `0`.

The case accounting from the complete `nimble all` run is **279 passing cases,
zero failures**:

- 139 unit;
- 32 ABI;
- 9 RT;
- 77 fixture;
- 12 hardening;
- 6 live PipeWire-JACK integration;
- 4 X11/D-Bus GUI.

The 12 hardening cases are included in that `all` total. The explicit
sanitizer task adds the same 9 RT behaviors under Clang ASan/UBSan and the
Valgrind attempt described above.

### 5.4 Tool versions

```text
Nim Compiler Version 2.2.10 [Linux: amd64]
clang version 22.1.6
valgrind-3.25.1
Python 3.14.6
```

No sanitizer or Valgrind suppression was added.

## 6. Resource observations

The focused suite compares resources against a per-test baseline rather than
assuming a machine-global count:

- `/proc/self/fd` returned to its baseline after every Linux reactor loop and
  after DSO, state, and PID exercises;
- `/proc/self/maps` reported zero remaining mapping for each explicitly closed
  CLAP/FFI fixture owner;
- fake JACK reported zero ports and inactive/cleared callbacks after each
  iteration, and its close path was called idempotently;
- CLAP fixture init/destroy/deinit counters balanced on every repeated instance;
- timer and FD registries returned to zero active entries after retryable close;
- state and PID exhaustion left no target or temporary file; PID symlink targets
  were not replaced;
- no external plugin/JACK/X11/D-Bus allocation is attributed as a host-owned
  leak by these observations. Full Memcheck attribution remains blocked by the
  loader prerequisite above.

## 7. Known gaps and explicit limitations

1. Valgrind Memcheck must be rerun on a workstation with matching glibc debug
   symbols or a non-stripped loader. The current task intentionally fails rather
   than reporting a false pass.
2. The exact H-10 race of repeated C-created-thread host requests/logging while
   teardown is concurrently progressing remains a 11C acceptance scenario.
3. JACK1 and JACK2 implementations remain unavailable; the passing live matrix
   is PipeWire-JACK only.
4. Native Wayland remains deferred by the approved product scope.
5. Third-party plugin allocations and loader-internal ownership require a
   separate attribution policy even when Valgrind is available.
6. No new artificial `dlclose` fault seam was added; OS loader failures and all
   existing checked rollback seams are exercised without weakening production
   ownership.

## 8. Changed files

- `tests/hardening/all_hardening_tests.nim` — focused hostile-input,
  fault-injection, repeated-resource, and idempotent-cleanup executable.
- `tests/rt/run_sanitizers.py` — deterministic ASan/UBSan and Valgrind runner
  with tool/version reporting and fail-closed status.
- `pluginhost.nimble` — `testHardening` and `sanitize` task wiring, focused
  executable compilation, sanitizer RT compilation, and fixture setup.
- `src/pluginhost/clap/ffi.nim` — C callback pointer representation for CLAP
  timer and GUI size callbacks.
- `src/pluginhost/clap/main_thread_services.nim` — matching timer service
  pointer representation.
- `src/pluginhost/clap/host_bridge.nim` — matching timer callback boundary.
- `src/pluginhost/app/plugin_services.nim` — matching timer callback and value
  conversion.
- `src/pluginhost/clap/instance.nim` — bounded conversion at GUI size callback
  boundaries.
- `tests/rt/test_host_bridge_safety.nim` and
  `tests/unit/test_host_bridge.nim` — matching callback test types.
- `MVP_IMPLEMENTATION_PLAN.md` — approved 11A marker and current 11B review
  metadata.
- `docs/release/11A-contract-audit.md` — approved 11A status metadata.
- `docs/release/11B-hardening-report.md` — this report.

No generated C, vendored CLAP header, dependency lock, or third-party source
was changed. `build/` and Nim cache outputs are transient verification
artifacts.

## 9. Manual verification recipe

From the repository root with Nimble, Clang, Valgrind, and the fixture build
prerequisites installed:

```text
nimble testHardening
nimble testRt
nimble testAbi
nimble testFixtures
env PLUGINHOST_CLAP_SMOKE_PLUGIN=/usr/lib/clap/ZamComp.clap nimble testIntegration
nimble testGui
nimble sanitize
```

`nimble sanitize` must be run on a host where Valgrind can initialize against
its dynamic loader. Confirm that the hardening process exits `0`, the sanitized
RT process exits `0`, generated-C audit output retains the negative-canary
rejection, and Valgrind reports no unexplained host-owned leak or descriptor.
Do not convert a Valgrind startup failure into a pass by adding a suppression.

## 10. Proposed next increment

With explicit 11B approval, begin **11C — Public acceptance,
compatibility, and release candidate**. Carry forward:

- the glibc-debug-symbol/non-stripped-loader Valgrind rerun;
- the H-10 concurrent foreign-thread teardown scenario;
- JACK1/JACK2 compatibility blockers;
- independent instrument/effect plugin runs, performance measurement, complete
  README/manual closure, release artifact/version checks, and the project
  license decision.

Increment 11B is approved after owner review. H-07 and H-10 remain explicit
11C acceptance prerequisites; the blocked Valgrind environment does not become
a release claim.
