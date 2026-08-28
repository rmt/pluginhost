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
- Increments 0 through 3 are approved; Increment 4 is not started.
- The CLI uses exactly pinned `argparse` 4.0.2.
- `list` and `scan` report copied CLAP descriptors without creating a plugin
  instance; `run` remains a typed stub.
- Official CLAP 1.2.10 headers and MIT license are pinned under `vendor/clap/`.
- CLAP/JACK declarations, Linux DSO ownership, C/Nim callbacks, and the ARC RT
  spike retain their ABI, foreign-thread, allocator, and generated-C checks.
- The current suite contains 49 unit, 20 ABI, 27 fixture, and 6 RT tests (102 total).
- The CLAP host bridge, instance lifecycle, bounded immutable audio/note port plans,
  and real-time render negotiation are implemented; there is no JACK client
  integration, GUI, state, or real-time processing yet.
- No remote repository or project license is currently configured.

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
- `src/pluginhost/jack/ffi.nim` — minimal JACK client raw ABI declarations.
- `src/pluginhost/platform/linux/dynlib.nim` — checked, move-only DSO ownership.
- `src/pluginhost/support/` — user diagnostics and UTF-8 boundary sanitization.
- `src/pluginhost/version.nim` — embedded product/SDK/ABI version information.
- `c/abi_probe.c` and `tests/abi/` — C-header, loader, and callback conformance tests.
- `tests/fixtures/clap/` — independently compiled catalog, lifecycle, port, and render CLAP libraries.
- `tests/fixtures/ffi/` — independently compiled callback/DSO fixture.
- `tests/rt/` — ARC allocator instrumentation and generated-C callback audit.
- `tests/unit/` — pure CLI, output, discovery policy, selection, text, host bridge, port-plan, lifecycle, error, and version tests.
- `docs/adr/` — accepted binding-strategy decisions.
- `REVIEW_ISSUES.md` — open review findings; it is a backlog, not approved behavior.
- `config.nims` — optional local Nimble path loading only; product compile-profile decisions remain open.
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

`nimble test` builds a process-test executable and runs the fast unit suite.
`nimble testAbi` checks ABI declarations, DSO ownership, and C/Nim callbacks.
`nimble testFixtures` builds independent synthetic CLAP DSOs and checks module,
catalog, instance lifecycle, deactivated port planning, render negotiation, cleanup,
process-level `list`, and discovery/`scan` behavior.
`nimble testRt` runs the current ARC allocation spike, foreign-thread host-callback checks, and generated-C audits.
`nimble all` performs source compile, unit, ABI, fixture, and RT checks. An
unavailable task must not report a false pass.

For user-visible CLI changes, also exercise the compiled process directly and verify stdout, stderr, and exit codes. Existing stubs are expected to fail with a non-zero status.

## Next planned work: Increment 4 — JACK backend and real-time harness

Increment 3 is approved. The next fresh session must triage the applicable findings
in `REVIEW_ISSUES.md`, present the Increment 4 pre-code package, and obtain approval
before editing. Do not begin implementation merely because this section is prepared.
Keep version `0.0.5-dev` throughout Increment 4.

### Goal

Implement and test JACK client, port, notification, callback, and quiescence mechanics
independently of CLAP DSP, using an immutable synthetic `PortPlan` and a minimal fake
process endpoint. Do not activate or process a CLAP plugin or enable public `run`.

### Mandatory pre-code decisions

Before proposing files or interfaces, read `REQUIREMENTS.md` and `DESIGN.md` fully,
the Increment 4 plan and risk register, current JACK FFI/tests, and `REVIEW_ISSUES.md`.
The package must explicitly resolve or seek guidance on:

- One product/test compile profile for memory manager, thread support, panic behavior,
  callback checks, and generated-C auditing; `raises: []` alone is not a Defect barrier.
- Checked JACK DSO loading and symbol ownership so help/version/list/scan remain usable
  without `libjack.so.0`, while backend failures retain typed JACK diagnostics.
- Freewheel support or explicit unsupported behavior, including its interaction with
  render mode, without adding CLAP processing in this increment.
- Real-time prohibitions for every JACK-invoked callback, especially buffer-size,
  shutdown, xrun, freewheel, and latency paths; callbacks must never perform cleanup.
- The exact minimal JACK declarations needed now, including callback registration,
  connection-state/port needs, and whether later SHOULD-only APIs remain deferred.
- JACK port-count/name limits, alias handling, deterministic realization, complete
  partial-registration rollback, and how CLAP-side bounds map to server constraints.
- `AudioRoleGuard`, `clap.thread-check` timing, fixed-layout `RtEngine` ownership, and
  a quiescence proof that prevents callbacks after deactivate/close returns.
- Stronger RT evidence: transitive or module-level generated-C coverage, a negative
  canary, matching product flags, foreign-thread first-call checks, and dummy-server
  allocator/syscall/lock instrumentation expectations.
- Classification of remaining review findings as accepted now, deferred to a named
  increment, or requiring an approved requirements/design/ADR change.

Any resulting requirements, design, build-profile, or risk-policy change must be
included in the pre-code package and approved before implementation.

### Expected implementation boundary after approval

- Move-only `JackBackend` open/configure/activate/deactivate/close ownership and typed
  JACK status errors, with every callback registered before activation.
- Immutable synthetic-plan realization into explicitly owned JACK audio/MIDI ports and
  a fixed-layout `RtPortMap`; no live structural replacement.
- Static non-capturing callback trampolines, POD/atomic notifications, callback-role
  tracking, and a fake endpoint that writes silence/copy/deterministic samples.
- Disposable JACK dummy-server integration tests and initial credible RT hooks.
- No CLAP activation/process call, real plugin audio, GUI, state, reactor, restart
  handling, public `run`, unrelated FFI expansion, or version change.

Stop after an approved Increment 4 implementation for human review. Do not begin
Increment 5 or connect the JACK callback to CLAP DSP.

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
