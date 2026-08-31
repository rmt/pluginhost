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
- Version: `0.0.6-dev` (`pluginhost.nimble` uses numeric `0.0.6` because of Nimble metadata syntax).
- Increments 0 through 4 are approved. Increment 5 has not started.
- The CLI uses exactly pinned `argparse` 4.0.2.
- `list` and `scan` report copied CLAP descriptors without creating a plugin
  instance; `run` remains a typed stub.
- Official CLAP 1.2.10 headers and MIT license are pinned under `vendor/clap/`.
- CLAP/JACK declarations, Linux DSO ownership, C/Nim callbacks, and the ARC RT
  spike retain their ABI, foreign-thread, allocator, and generated-C checks.
- The shared build profile is ARC, threads on, panics on, and Nim signal handlers disabled.
- The current suite contains 76 unit, 24 ABI, 27 fixture, 8 RT, and 1 live integration test (136 total), plus required generated-C negative-canary rejection.
- The CLAP host bridge, instance lifecycle, bounded immutable audio/note port plans,
  render negotiation, checked JACK loading, and an internal JACK client/port/callback
  harness are implemented and proven against both controllable fake and isolated live
  PipeWire-JACK backends. Public `run`, CLAP activation/DSP, GUI, state, and reactor
  behavior remain unimplemented.
- Remote `origin` is configured; no project license is currently configured.

Current source responsibilities:

- `src/pluginhost.nim` — process composition root and exit handling.
- `src/pluginhost/app/` — CLI configuration, output rendering, dispatch, and the run stub.
- `src/pluginhost/domain/` — typed results/errors/lifecycle plus host-owned catalog and immutable port-plan values.
- `src/pluginhost/clap/ffi.nim` — stable CLAP 1.2.10 raw ABI declarations.
- `src/pluginhost/clap/loader.nim` — move-only entry/factory ownership, copied catalog extraction, and checked plugin creation.
- `src/pluginhost/clap/host_bridge.nim` and `instance.nim` — stable host callbacks, bounded request/log transport, and one-instance lifecycle ownership.
- `src/pluginhost/clap/port_inspector.nim` — bounded deactivated audio/note inspection and real-time render negotiation.
- `src/pluginhost/discovery/paths.nim` and `scanner.nim` — ordered roots, deterministic
  candidate traversal, canonical deduplication, and scan reports.
- `src/pluginhost/jack/ffi.nim` — declaration-only minimal JACK ABI types, callbacks, and procedure-pointer signatures.
- `src/pluginhost/jack/api.nim` — checked move-only JACK DSO and all-or-nothing procedure-table ownership.
- `src/pluginhost/jack/backend.nim`, `callbacks.nim`, and `ports.nim` — internal move-only client state machine, stable callbacks, transactional realization, and fixed RT port map.
- `src/pluginhost/rt/atomic_pod.nim`, `engine.nim`, and `role_guard.nim` — audited trace-free C11 atomics, CLAP-free fixed-layout fake endpoint, and exclusive symbolic audio role.
- `src/pluginhost/platform/linux/dynlib.nim` — checked, move-only DSO ownership.
- `src/pluginhost/support/` — user diagnostics and UTF-8 boundary sanitization.
- `src/pluginhost/version.nim` — embedded product/SDK/ABI version information.
- `c/abi_probe.c`, `c/rt_atomic.h`, and `tests/abi/` — C-header, lock-free atomic, loader, and callback conformance tests.
- `tests/fixtures/clap/` — independently compiled catalog, lifecycle, port, and render CLAP libraries.
- `tests/fixtures/ffi/` — independently compiled callback/DSO fixture.
- `tests/fixtures/jack/` — partial-symbol and complete controllable fake JACK DSOs.
- `tests/rt/` — ARC allocator evidence, complete product-profile generated-C/call-path auditing, required negative canary, and live C callback instrumentation.
- `tests/integration/` — strict disposable PipeWire-JACK orchestration plus an independent C JACK peer for ports, samples, quiescence, and repeated lifecycle evidence.
- `tests/unit/` — control-plane, ownership, naming, rollback, quiescence, fake-processing, role, CLI, CLAP, and support tests.
- `docs/adr/` — accepted binding-strategy decisions.
- `REVIEW_ISSUES.md` — preserved findings plus owner-approved dispositions and named targets.
- `config.nims` — shared ARC/thread/panic/signal profile plus optional local Nimble paths.
- `docs/adr/0003-*.md`, `0004-*.md`, and `0005-*.md` — callback-safety profile, checked JACK loading, and audited trace-free atomic decisions.
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
`nimble testFixtures` builds independent synthetic CLAP DSOs and checks module,
catalog, instance lifecycle, deactivated port planning, render negotiation, cleanup,
process-level `list`, and discovery/`scan` behavior.
`nimble testRt` runs allocator/foreign-thread checks, complete product-profile generated-C/call-path audits, and required negative-canary rejection.
`nimble testIntegration` fails when prerequisites are missing, then runs a private PipeWire-JACK Dummy-Driver, external peer, quiescence/stress, and live C callback instrumentation.
`nimble all` performs source compile, unit, ABI, fixture, RT, and live integration checks; its integration preflight fails rather than reporting a false complete pass.

For user-visible CLI changes, also exercise the compiled process directly and verify stdout, stderr, and exit codes. Existing stubs are expected to fail with a non-zero status.

## Next planned work: Increment 5 — first internal CLAP audio vertical slice

Increment 4 is approved. The next fresh session must inspect the current state, read the
authoritative documents, and present an Increment 5 pre-code package before editing CLAP
activation or RT processing code. Do not begin implementation merely because this section
is prepared. Use version `0.0.6-dev` throughout Increment 5.

### Goal

Produce the first internal end-to-end CLAP/JACK float32 audio slice while keeping the
canonical public `run` path disabled until Increment 7 owns orderly signals/reactor control.

### Mandatory pre-code focus

The package must explicitly cover:

- The exact internal composition owner/harness and dependency direction connecting `ClapInstance`, immutable port inspection, `JackBackend`, and `RtEngine` without exposing public runtime behavior.
- CLAP activate/start/process/stop/deactivate ordering, rollback at every failure point, and JACK quiescence before plugin processing pointers or storage can be changed or released.
- Preallocated grouped `clap_audio_buffer` descriptors and channel-pointer storage that preserves CLAP groups while JACK ports remain flattened, with `data64 = nil` and no full-buffer copy.
- Activation frame-range policy, initial JACK sample rate/buffer size, and the bounded control-plane response to sample-rate or larger-buffer notifications without adding the later reactor/restart feature set.
- `steady_time`, null transport, defined output zeroing, and exact policies for every relevant CLAP process status, including error-to-silence/nonzero termination and conservative tail/continue handling.
- Atomic connection of `AudioRoleGuard` to `clap.thread-check`, including guarded main-thread `start_processing`/`stop_processing` and exclusive process-thread ownership.
- Synthetic tone/gain/multi-group/zero-copy/failure fixtures, complete lifecycle-order and released-storage tests, and whether an independently implemented headless CLAP plugin is available or a missing smoke prerequisite must fail explicitly.
- Extension of product-profile generated-C and live callback instrumentation evidence through the new CLAP process path and process-reachable host callbacks.
- Whether live PipeWire-JACK fixture capture belongs in `testIntegration`, while preserving fast fake-JACK/CLAP failure injection in their existing tasks.

Increment 5 must not enable public `run`, add MIDI/note translation, GUI, state, the main
reactor, signal handling, general restart/reconnection policy, latency integration, or
later-increment behavior. Unsupported paths remain explicit.

Stop after the Increment 5 pre-code package unless the owner explicitly approves implementation.

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
