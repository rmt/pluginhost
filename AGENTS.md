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
- Version: `0.0.3-dev` (`pluginhost.nimble` uses numeric `0.0.3` because of Nimble metadata syntax).
- Increments 0, 1, and 2 are approved; Increment 2 includes review units 2A and 2B.
- The CLI uses exactly pinned `argparse` 4.0.2.
- `list` and `scan` report copied CLAP descriptors without creating a plugin
  instance; `run` remains a typed stub.
- Official CLAP 1.2.10 headers and MIT license are pinned under `vendor/clap/`.
- CLAP/JACK declarations, Linux DSO ownership, C/Nim callbacks, and the ARC RT
  spike retain their ABI, foreign-thread, allocator, and generated-C checks.
- The current suite contains 41 unit, 20 ABI, 18 fixture, and 4 RT tests (83 total).
- There is no plugin instance, JACK client integration, GUI, state, or real-time
  processing yet.
- No remote repository or project license is currently configured.

Current source responsibilities:

- `src/pluginhost.nim` — process composition root and exit handling.
- `src/pluginhost/app/` — CLI configuration, output rendering, dispatch, and the run stub.
- `src/pluginhost/domain/` — typed results/errors/lifecycle plus host-owned catalog values.
- `src/pluginhost/clap/ffi.nim` — stable CLAP 1.2.10 raw ABI declarations.
- `src/pluginhost/clap/loader.nim` — move-only entry/factory ownership and copied catalog extraction.
- `src/pluginhost/discovery/paths.nim` and `scanner.nim` — ordered roots, deterministic
  candidate traversal, canonical deduplication, and scan reports.
- `src/pluginhost/jack/ffi.nim` — minimal JACK client raw ABI declarations.
- `src/pluginhost/platform/linux/dynlib.nim` — checked, move-only DSO ownership.
- `src/pluginhost/support/` — user diagnostics and UTF-8 boundary sanitization.
- `src/pluginhost/version.nim` — embedded product/SDK/ABI version information.
- `c/abi_probe.c` and `tests/abi/` — C-header, loader, and callback conformance tests.
- `tests/fixtures/clap/` — independently compiled synthetic CLAP libraries.
- `tests/fixtures/ffi/` — independently compiled callback/DSO fixture.
- `tests/rt/` — ARC allocator instrumentation and generated-C callback audit.
- `tests/unit/` — pure CLI, output, discovery policy, selection, text, lifecycle, error, and version tests.
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
nimble testFixtures
nimble testRt
nimble all
```

`nimble test` builds a process-test executable and runs the fast unit suite.
`nimble testAbi` checks ABI declarations, DSO ownership, and C/Nim callbacks.
`nimble testFixtures` builds independent synthetic CLAP DSOs and checks module,
catalog, cleanup, process-level `list`, and discovery/`scan` behavior.
`nimble testRt` runs the current ARC allocation spike and generated-C audit.
`nimble all` performs source compile, unit, ABI, fixture, and RT checks. An
unavailable task must not report a false pass.

For user-visible CLI changes, also exercise the compiled process directly and verify stdout, stderr, and exit codes. Existing stubs are expected to fail with a non-zero status.

## Next planned work: Increment 3 review unit 3A

Increment 2 is approved. The next fresh session must present the Increment 3A
pre-code package and obtain approval before editing; do not begin implementation
merely because this section is prepared. Keep version `0.0.3-dev` until the next
reviewed increment is complete.

### Goal

Create, initialize, inspect, and destroy exactly one CLAP plugin instance correctly,
without JACK processing, GUI, state persistence, or public `run` behavior.

### Recommended review-unit split

- **3A:** stable `ClapHostBridge`, host identity/core callbacks, bounded request/log
  transport, `ClapInstance` create/init/destroy, extension caching, and partial cleanup.
- **3B:** deactivated-plugin port inspection, immutable `PortPlan`, and render-mode
  negotiation. No JACK processing or public `run` behavior.

Implement 3A only, then stop for review before 3B.

### Expected files and interfaces

- `src/pluginhost/clap/host_bridge.nim` — stable host storage, host identity, extension
  lookup, and tested request/log transport; no raw host pointer escapes its owner.
- `src/pluginhost/clap/instance.nim` — explicit instance state machine, selected
  descriptor creation, plugin `init()`/`destroy()`, cached extension pointers, and
  idempotent cleanup while the `ClapModule` remains alive.
- Focused domain/request types only where a real ownership or queue boundary requires
  them; do not create future JACK/GUI/state modules as scaffolding.
- Extend the independent CLAP fixture and add focused lifecycle/process tests.

The proposed boundary must preserve stable host strings/vtables through plugin destroy,
keep all C callbacks `cdecl`, `gcsafe`, and `raises: []`, and expose only completely
implemented host extensions. `run` remains an explicit failure.

### Tests, dependencies, and risks

- Success and every create/init/destroy partial-failure transition, repeated cleanup,
  no calls after destroy/deinit, and host-storage lifetime.
- Host identity and extension lookup, main-thread identity, request coalescing, bounded
  log overflow, callback context, and malformed plugin responses.
- Port inspection/render negotiation are deferred to 3B; JACK and RT behavior are
  explicitly out of scope.
- No new third-party dependency is expected; use existing raw CLAP FFI and ownership.
- Main risks are callback lifetime, plugin calls after teardown, extension advertisement
  before implementation, and unbounded callback-thread logging/request behavior.

Stop at the 3A human review gate. Do not implement 3B, JACK, GUI, state, caching,
or a plugin processing loop.

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
