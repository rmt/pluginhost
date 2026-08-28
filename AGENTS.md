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
- Version: `0.0.5-dev` (`pluginhost.nimble` uses numeric `0.0.5` because of Nimble metadata syntax).
- Increments 0 through 4A are approved. Increments 4B and 4C have not started.
- The CLI uses exactly pinned `argparse` 4.0.2.
- `list` and `scan` report copied CLAP descriptors without creating a plugin
  instance; `run` remains a typed stub.
- Official CLAP 1.2.10 headers and MIT license are pinned under `vendor/clap/`.
- CLAP/JACK declarations, Linux DSO ownership, C/Nim callbacks, and the ARC RT
  spike retain their ABI, foreign-thread, allocator, and generated-C checks.
- The shared build profile is ARC, threads on, panics on, and Nim signal handlers disabled.
- The current suite contains 47 unit, 23 ABI, 27 fixture, and 6 RT tests (103 total).
- The CLAP host bridge, instance lifecycle, bounded immutable audio/note port plans,
  real-time render negotiation, and checked move-only JACK DSO/procedure-table owner
  are implemented; there is no JACK client, port realization, callback registration,
  activation, GUI, state, or real-time processing integration yet.
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
- `src/pluginhost/platform/linux/dynlib.nim` — checked, move-only DSO ownership.
- `src/pluginhost/support/` — user diagnostics and UTF-8 boundary sanitization.
- `src/pluginhost/version.nim` — embedded product/SDK/ABI version information.
- `c/abi_probe.c` and `tests/abi/` — C-header, loader, and callback conformance tests.
- `tests/fixtures/clap/` — independently compiled catalog, lifecycle, port, and render CLAP libraries.
- `tests/fixtures/ffi/` — independently compiled callback/DSO fixture.
- `tests/rt/` — ARC allocator instrumentation and generated-C callback audit.
- `tests/unit/` — pure CLI, output, discovery policy, selection, text, host bridge, port-plan, lifecycle, error, and version tests.
- `docs/adr/` — accepted binding-strategy decisions.
- `REVIEW_ISSUES.md` — preserved findings plus owner-approved dispositions and named targets.
- `config.nims` — shared ARC/thread/panic/signal profile plus optional local Nimble paths.
- `docs/adr/0003-*.md` and `0004-*.md` — callback-safety profile and checked JACK loading decisions.
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
nimble all
```

`nimble test` builds a process-test executable, rejects an eager JACK ELF dependency, and runs the fast unit suite.
`nimble testAbi` checks ABI declarations, generic and JACK-specific DSO ownership, complete JACK symbol resolution, and C/Nim callbacks.
`nimble testFixtures` builds independent synthetic CLAP DSOs and checks module,
catalog, instance lifecycle, deactivated port planning, render negotiation, cleanup,
process-level `list`, and discovery/`scan` behavior.
`nimble testRt` runs allocation, foreign-thread host-callback, and generated-C audits under the shared product profile.
`nimble all` performs source compile, unit, ABI, fixture, and RT checks. An
unavailable task must not report a false pass.

For user-visible CLI changes, also exercise the compiled process directly and verify stdout, stderr, and exit codes. Existing stubs are expected to fail with a non-zero status.

## Next planned work: Increment 4B — backend, ports, callbacks, and fake endpoint

Increment 4A is approved. The next fresh session must inspect the current state, read
the authoritative documents, and present an Increment 4B pre-code package before
editing backend or RT code. Do not begin implementation merely because this section is
prepared. Keep version `0.0.5-dev` throughout Increment 4.

### Goal

Implement the first checked JACK backend state machine and allocation-free fake RT
callback mechanics without CLAP DSP. The work is still internal/test-only: public
`run` remains disabled.

### Mandatory pre-code focus

The package must explicitly cover:

- `JackBackend` ownership of `JackApi`, JACK client handles, realized ports, and stable callback context.
- Open/configure/activate/deactivate/close states, idempotent teardown, and callback quiescence proof.
- Registration of process, shutdown/info-shutdown, buffer-size, sample-rate, xrun, freewheel, and latency callbacks before activation.
- Transactional synthetic `PortPlan` realization using the actual JACK client name and server name limits, including alias truncation and complete rollback.
- Stable fixed-layout `RtPortMap`/RT skeleton contents and pointer lifetimes.
- POD/atomic notification fields for shutdown, xrun, freewheel, buffer-size, sample-rate, and process metrics; callbacks must not perform cleanup.
- `AudioRoleGuard` exclusivity and how it remains disconnected from `clap.thread-check` until Increment 5.
- Fake endpoint behavior for silence/copy/deterministic samples and how it stays allocation-free.
- Focused tests for missing JACK server/status diagnostics, port registration failure/rollback, callback registration failures, repeated lifecycle, and quiescence.

Increment 4C remains a later gate for isolated PipeWire-JACK integration, live quiescence,
module-level generated-C auditing with a negative canary, and C allocation/lock/I/O
instrumentation. Neither 4B nor 4C activates or processes CLAP, enables public `run`,
or adds GUI, state, reactor, restart, or later-increment behavior.

Stop after the Increment 4B pre-code package unless the owner explicitly approves implementation.

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
