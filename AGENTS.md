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

## Current reviewed snapshot

As of the latest reviewed state:

- Default/current branch: `main`; inspect `git log` for the exact reviewed commit.
- Version: `0.0.1-dev` (`pluginhost.nimble` uses numeric `0.0.1` because of Nimble metadata syntax).
- Increment 0 and Increment 1 review unit 1A are approved; review unit 1B is next.
- The CLI uses exactly pinned `argparse` 4.0.2.
- Typed parsing exists for implicit/explicit `run`, `list`, and `scan`, including generated scoped help and semantic validation.
- Valid `run`, `list`, and `scan` requests intentionally return typed `NotImplemented` failures.
- Official CLAP 1.2.10 headers and MIT license are pinned under `vendor/clap/`.
- Handwritten policy-free CLAP and JACK declarations are covered by C-versus-Nim size, alignment, offset, constant, and signature checks.
- The reviewed suite contains 23 unit tests and 14 ABI tests (37 total).
- There is no CLAP loading, JACK client integration, plugin GUI, state persistence, scanning, or real-time processing yet.
- No remote repository or project license is currently configured.

Current source responsibilities:

- `src/pluginhost.nim` — process composition root and exit handling.
- `src/pluginhost/app/` — CLI configuration, dispatch, and explicit operation/session stubs.
- `src/pluginhost/domain/` — typed results, errors, and lifecycle transitions.
- `src/pluginhost/clap/ffi.nim` — stable CLAP 1.2.10 raw ABI declarations.
- `src/pluginhost/jack/ffi.nim` — minimal JACK client raw ABI declarations.
- `src/pluginhost/support/diagnostics.nim` — user-facing diagnostics.
- `src/pluginhost/version.nim` — embedded version information.
- `c/abi_probe.c` and `tests/abi/` — C-header conformance probes and ABI tests.
- `tests/unit/` — CLI, process, lifecycle, error, and version tests.
- `docs/adr/` — accepted binding-strategy decisions.
- `vendor/clap/` — unmodified upstream headers, license, and provenance.

Only add modules when they gain a real responsibility; do not create the entire future layout as empty scaffolding.

## Current verification commands

Use Nim 2.2 or later; the reference compiler is Nim 2.2.10. Dependencies are managed by Nimble.

```sh
nimble check
nimble build
nimble test
nimble testAbi
nimble all
```

`nimble test` builds a process-test executable and runs the fast unit suite.
`nimble testAbi` checks raw CLAP/JACK declarations against C headers.
`nimble all` also performs the source compile and ABI checks. New planned tasks
such as `testFixtures` and `testRt` should be introduced only when they perform
real checks; an unavailable task must not report a false pass.

For user-visible CLI changes, also exercise the compiled process directly and verify stdout, stderr, and exit codes. Existing stubs are expected to fail with a non-zero status.

## Next planned work: Increment 1 review unit 1B

The approved next review unit completes the FFI/ABI foundation planned for
`0.0.2-dev`. Its scope was included in the approved Increment 1 pre-code package;
a fresh session may implement it after confirming that `main` is clean and the
current tests pass. Re-propose before coding only if research requires a scope,
dependency, or architectural change.

Review unit 1B includes:

- A checked, move-only Linux dynamic-library wrapper with explicit, idempotent close.
- Typed library-open and symbol-lookup failures plus partial-load cleanup tests.
- A tiny C FFI fixture exporting function symbols and a `clap_entry` data symbol.
- Nim-to-C and C-to-Nim callback round trips.
- Callback invocation from a C-created pthread with no exception crossing the ABI.
- A process-callback-shaped POD-only function compiled with ARC and `raises: []`.
- Allocation/runtime-initialization instrumentation, including the first foreign-thread call.
- A meaningful `nimble testRt` task integrated into `nimble all`.
- Transition of `VERSION`, Nimble metadata, version output/tests, and documentation to
  `0.0.2-dev` when the review unit is complete.

Expected primary files include `src/pluginhost/platform/linux/dynlib.nim`,
`tests/fixtures/ffi/ffi_fixture.c`, `tests/abi/test_dynlib.nim`,
`tests/abi/test_foreign_callbacks.nim`, and `tests/rt/test_callback_safety.nim`.

Do not proceed into plugin discovery, descriptor policy, or host lifecycle policy.
Raw FFI modules remain policy-free. Stop for review after unit 1B.

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
