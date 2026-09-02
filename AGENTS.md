# Project intent (user perspective)

The user wants a small, dependable Linux CLI host for native CLAP plugins, similar in use to `carla-single`: each process owns exactly one plugin instance and exposes it as exactly one JACK client. It must support JACK audio and MIDI/note I/O, native plugin GUI show/hide, state persistence, clean process control, and strict real-time safety. It is implemented in Nim 2.x and should remain architecturally flexible without growing beyond the reviewed MVP scope.

The user also wants development to be incremental and review-driven. Present each increment's design, files, interfaces, tests, dependencies, and risks before writing its code. Stop at every review gate and do not begin the next increment without explicit approval. Stubs must fail clearly and must never claim success for unimplemented work.

## Authoritative project documents

Read these before proposing or implementing the next increment:

1. `README.md` — quick build instructions and user-visible current behavior.
2. `REQUIREMENTS.md` — authoritative product behavior, acceptance criteria, platform constraints, and non-goals. Read it fully before changing behavior.
3. `DESIGN.md` — architecture, ownership, dependency direction, thread model, FFI rules, and real-time invariants. Read it fully before changing architecture or external boundaries.
4. `MVP_IMPLEMENTATION_PLAN.md` — increment sequence and review protocol. Always read sections 4–6, the current/next increment, the progress table in section 20, and the risk register in section 21.
5. `pluginhost.nimble` and `VERSION` — actual package dependencies, tasks, and development version.
6. The implementation and corresponding tests under `src/` and `tests/`.

Document roles are deliberate:

- Requirements define **what** the product must do.
- Design defines architecture and invariants for **how** it is built.
- The implementation plan defines **when** work may be done and reviewed.
- Source, tests, and Git history show what is **actually implemented**.

If these disagree, report the discrepancy rather than silently choosing one or rewriting approved documents.

## Determine the current state at the start of a session

Do not rely only on the snapshot below; it will become stale. Run and inspect at least:

```sh
git status --short --branch
git log --oneline --decorate -5
git show --stat --oneline HEAD
```

Then:

1. Read `VERSION` and the progress table in `MVP_IMPLEMENTATION_PLAN.md`.
2. Find the highest reviewed increment and the first increment not started.
3. Inspect recent diffs and all source/tests affected by the proposed work.
4. Check `README.md` against actual CLI behavior.
5. Run the currently available verification commands before changing code.

The progress table changes only after human review. A task appearing in the plan does not mean it is implemented. A dirty worktree may contain unreviewed work; inspect it before editing and never discard it without permission.

## Current project snapshot

As of the latest reviewed state:

- Default/current branch: `main`; inspect `git status` and `git log` before editing.
- Version: `0.0.10-dev` (`pluginhost.nimble` uses numeric `0.0.10` because of Nimble metadata syntax).
- Increments 0 through 9 are approved; Increment 10 has not started.
- The CLI uses exactly pinned `argparse` 4.0.2.
- `list` and `scan` report copied CLAP descriptors without creating a plugin
  instance; canonical `run` now provides a headless signal-controlled JACK runtime.
- Official CLAP 1.2.10 headers and MIT license are pinned under `vendor/clap/`.
- CLAP/JACK declarations, Linux DSO ownership, C/Nim callbacks, and the ARC RT
  spike retain their ABI, foreign-thread, allocator, and generated-C checks.
- The shared build profile is ARC, threads on, panics on, and Nim signal handlers disabled.
- The current suite contains 106 unit, 26 ABI, 61 fixture, 9 RT, and 6 live integration tests (208 total), plus required generated-C negative-canary rejection.
- The public headless runtime composes the bounded CLAP/JACK audio/event slice with an `epoll`/`signalfd` reactor, CLAP timer/FD services, state-dirty notification, plugin/JACK latency propagation, bounded parameter transport/rescans, sleep/wake, coalesced quiescent restart/port rebuild with compatible reconnection reporting, transactional CLAP state load/save, main-thread callbacks, orderly shutdown, and atomic PID-file ownership. GUI and later host extensions remain unimplemented.
- Remote `origin` is configured; no project license is currently configured.

Current source responsibilities:

- `src/pluginhost.nim` — process composition root and exit handling.
- `src/pluginhost/app/` — CLI configuration/output, public `HostSession` policy, internal audio composition, backend-neutral main-reactor scheduling, and generation-safe CLAP timer/FD registry ownership.
- `src/pluginhost/domain/` — typed results/errors/lifecycle/reactor values plus host-owned catalog and immutable port plans.
- `src/pluginhost/clap/ffi.nim` — stable CLAP 1.2.10 raw ABI declarations.
- `src/pluginhost/clap/loader.nim` — move-only entry/factory ownership, copied catalog extraction, and checked plugin creation.
- `src/pluginhost/clap/host_bridge.nim`, `main_thread_services.nim`, and `instance.nim` — stable host callbacks/service boundary, bounded request/log/parameter transport, extension dispatch, parameter snapshots, state calls, and one-instance lifecycle ownership.
- `src/pluginhost/clap/port_inspector.nim`, `audio_process.nim`, `event_bridge.nim`, `parameter_transport.nim`, and `state_codec.nim` — bounded port inspection, grouped zero-copy float32 processing, fixed-capacity sample-accurate event/parameter translation, RT-safe sleep/wake handling, and main-thread bounded transactional state streams.
- `src/pluginhost/discovery/paths.nim` and `scanner.nim` — ordered roots, deterministic
  candidate traversal, canonical deduplication, and scan reports.
- `src/pluginhost/jack/ffi.nim` — declaration-only minimal JACK ABI types, callbacks, and procedure-pointer signatures.
- `src/pluginhost/jack/api.nim` — checked move-only JACK DSO and all-or-nothing procedure-table ownership.
- `src/pluginhost/jack/backend.nim`, `callbacks.nim`, and `ports.nim` — internal move-only client state machine, stable audio/MIDI adapters, transactional realization, fixed RT port maps, and control-plane connection snapshot/rebuild/reconnection.
- `src/pluginhost/rt/atomic_pod.nim`, `engine.nim`, `midi_io.nim`, and `role_guard.nim` — audited trace-free atomics, backend-neutral fixed-layout endpoints, and exclusive symbolic audio role.
- `src/pluginhost/platform/linux/` — checked move-only DSO, epoll, signalfd/signal-mask, and atomic PID-file ownership.
- `src/pluginhost/support/` — user diagnostics, UTF-8 handling, and deterministic default JACK naming.
- `src/pluginhost/version.nim` — embedded product/SDK/ABI version information.
- `c/abi_probe.c`, `c/rt_atomic.h`, and `tests/abi/` — C-header, lock-free atomic, loader, and callback conformance tests.
- `tests/fixtures/clap/` — independently compiled catalog, lifecycle, port, render, audio, and event CLAP libraries.
- `tests/fixtures/ffi/` — independently compiled callback/DSO fixture.
- `tests/fixtures/jack/` — partial-symbol and complete controllable fake JACK DSOs.
- `tests/rt/` — ARC allocator evidence including event overflow/malformed paths, complete product-profile generated-C/call-path auditing, required negative canary, and live C callback instrumentation.
- `tests/integration/` — strict disposable PipeWire-JACK orchestration plus public signal/PID process tests and independent C audio/MIDI peers.
- `tests/unit/` — control-plane, ownership, naming, rollback, quiescence, fake-processing, role, CLI, CLAP, and support tests.
- `docs/adr/` — accepted binding-strategy decisions.
- `REVIEW_ISSUES.md` — preserved findings plus owner-approved dispositions and named targets.
- `config.nims` — shared ARC/thread/panic/signal profile plus optional local Nimble paths.
- `docs/adr/0003-*.md` through `0006-*.md` — callback profile, checked JACK loading, audited atomics, and direct Linux reactor decisions.
- `vendor/clap/` — unmodified upstream headers, license, and provenance.

Only add modules when they gain a real responsibility; do not create the entire future layout as empty scaffolding.

## Current verification commands

Use Nim 2.2 or later; the reference compiler is Nim 2.2.10. Dependencies are managed by Nimble.

```sh
nimble check
nimble build
nimble test
nimble testAbi
nimble testFixtures
nimble testRt
nimble testIntegration
nimble all
```

`nimble test` builds a process-test executable and fake JACK DSO, rejects an eager JACK ELF dependency, and runs the fast unit suite.
`nimble testAbi` checks ABI declarations, generic and JACK-specific DSO ownership, complete JACK symbol resolution, and C/Nim callbacks.
`nimble testFixtures` builds independent synthetic CLAP DSOs and checks module, catalog, lifecycle, port planning, audio processing, fixed-capacity event translation, cleanup, `list`, and `scan` behavior.
`nimble testRt` runs allocator/foreign-thread checks through audio and event paths, complete product-profile generated-C/call-path audits, and required negative-canary rejection.
`nimble testIntegration` fails when prerequisites are missing, then runs four private PipeWire-JACK scenarios covering public signals/PID cleanup, independent CLAP smoke, live audio/MIDI capture, quiescence/stress, and callback instrumentation.
`nimble all` performs source compile, unit, ABI, fixture, RT, and live integration checks; its integration preflight fails rather than reporting a false complete pass.

For user-visible CLI changes, also exercise the compiled process directly and verify stdout, stderr, signals, PID cleanup, and exit codes. Deferred GUI capabilities remain explicit failures.

## Next planned work: Increment 10A — X11/XEmbed window-host spike

Increment 9 is approved. It adds bounded 64 KiB/64 MiB CLAP state streams,
pre-configuration load, and clean-signal transactional save after JACK/CLAP quiescence.
The strict reviewed gate passed 208 tests.

Before editing Increment 10A, inspect the current approved state, run the existing
verification matrix, and present a fresh pre-code package choosing Xlib or XCB, defining
the narrow window-host capability and resource ownership, XEmbed/window lifecycle,
reactor integration, Xvfb fixtures/tests, dependencies/ADR, RT isolation, risks, and
non-goals. Stop for explicit owner approval before implementation.

## Non-negotiable engineering rules

- One plugin instance and one JACK client per process.
- Initial platform/backend/format: Linux, JACK, native CLAP.
- Keep control-plane and real-time-plane code separate.
- The JACK process path must not allocate/deallocate, block, take unsuitable locks, throw/catch exceptions, log, access files, call GUI APIs, or use managed strings/sequences/tables/closures.
- C callbacks need exact calling conventions, stable storage/lifetimes, and `raises: []`; no exception may cross an ABI boundary.
- Keep raw external API types out of application/domain policy.
- Use explicit state machines, ownership, cleanup, and idempotent close behavior.
- Quiesce JACK before replacing or freeing processing/plugin resources.
- Unsupported behavior must be explicit, never silently approximated.
- Add behavior-focused tests, including boundary, overflow, partial-failure, and repeated-cleanup cases where relevant.
- A substantial dependency or architectural invariant change requires approval and usually an ADR under `docs/adr/`.
- Do not add unrelated features or refactors to an increment.
- Do not commit, amend, tag, push, or change branches unless the user asks.

Before handing an increment back for review, provide the summary, file-by-file changes, exact verification results, manual recipe, limitations, generated/vendored-source identification, and the proposed next increment. Then stop for review.
