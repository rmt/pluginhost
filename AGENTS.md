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
- Version: `0.0.4-dev` (`pluginhost.nimble` uses numeric `0.0.4` because of Nimble metadata syntax).
- Increments 0, 1, and 2 plus review unit 3A are approved; review unit 3B is not started.
- The CLI uses exactly pinned `argparse` 4.0.2.
- `list` and `scan` report copied CLAP descriptors without creating a plugin
  instance; `run` remains a typed stub.
- Official CLAP 1.2.10 headers and MIT license are pinned under `vendor/clap/`.
- CLAP/JACK declarations, Linux DSO ownership, C/Nim callbacks, and the ARC RT
  spike retain their ABI, foreign-thread, allocator, and generated-C checks.
- The current suite contains 47 unit, 20 ABI, 21 fixture, and 6 RT tests (94 total).
- The CLAP host bridge and instance lifecycle core are implemented; there is no JACK
  client integration, GUI, state, or real-time processing yet.
- No remote repository or project license is currently configured.

Current source responsibilities:

- `src/pluginhost.nim` — process composition root and exit handling.
- `src/pluginhost/app/` — CLI configuration, output rendering, dispatch, and the run stub.
- `src/pluginhost/domain/` — typed results/errors/lifecycle plus host-owned catalog values.
- `src/pluginhost/clap/ffi.nim` — stable CLAP 1.2.10 raw ABI declarations.
- `src/pluginhost/clap/loader.nim` — move-only entry/factory ownership, copied catalog extraction, and checked plugin creation.
- `src/pluginhost/clap/host_bridge.nim` and `instance.nim` — stable host callbacks, bounded request/log transport, and one-instance lifecycle ownership.
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
- `tests/unit/` — pure CLI, output, discovery policy, selection, text, host bridge, lifecycle, error, and version tests.
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
catalog, instance lifecycle, cleanup, process-level `list`, and discovery/`scan` behavior.
`nimble testRt` runs the current ARC allocation spike, foreign-thread host-callback checks, and generated-C audits.
`nimble all` performs source compile, unit, ABI, fixture, and RT checks. An
unavailable task must not report a false pass.

For user-visible CLI changes, also exercise the compiled process directly and verify stdout, stderr, and exit codes. Existing stubs are expected to fail with a non-zero status.

## Next planned work: Increment 3 review unit 3B

Increment 3A is approved. The next fresh session must present the Increment 3B
pre-code package and obtain approval before editing; do not begin implementation
merely because this section is prepared. Keep version `0.0.4-dev` throughout 3B.

### Goal

Inspect the initialized, deactivated plugin and build a host-owned immutable
`PortPlan` for every audio and note group, then negotiate real-time render mode.
Do not activate or process the plugin and do not add JACK or public `run` behavior.

### Required pre-code package

Before any edit, re-read the official audio-ports, note-ports, and render headers
plus the port-model sections of `DESIGN.md` and `REQUIREMENTS.md`, then present:

- Exact files and interfaces for domain-only port-plan values, CLAP port inspection,
  minimal render FFI/ABI additions, instance integration, fixtures, and tests.
- Explicit bounds and validation for plugin-provided counts, channel totals, IDs,
  names, flags, in-place pairs, and note dialect combinations.
- Audio-group/channel flattening and deterministic provisional names without
  creating JACK ports or depending on JACK runtime limits.
- Main-thread/deactivated-state enforcement, immutable host ownership, extension
  pointer lifetime, and typed cleanup/error behavior.
- Render policy for absent extensions, hard real-time requirements, successful
  `CLAP_RENDER_REALTIME`, and rejection of the requested mode.
- Focused tests, dependency impact, risks, exclusions, and exact verification commands.

The package should consider `src/pluginhost/domain/port_plan.nim` and a focused
CLAP inspector module, but file names and public interfaces are not approved until
the pre-code review. Extend only the raw render ABI needed by the accepted design.
Do not advertise host audio/note rescan extensions in 3B.

### Expected tests and boundaries

- Missing port extensions produce valid empty groups; valid fixtures cover multiple
  input/output audio groups, flattened channels, and multiple note ports.
- Preserve direction, index, stable ID, bounded name, audio metadata, supported and
  preferred note dialects, and deterministic ordering in host-owned values.
- Reject missing callbacks, failed `get()`, impossible counts/totals, duplicate IDs
  where invalid, unterminated text, invalid dialects, and inconsistent port metadata.
- Cover render-extension absence, real-time success/failure, hard-requirement reporting,
  repeated inspection where allowed, and cleanup without calls after destruction.
- Keep domain modules free of raw CLAP/JACK types and add C-header ABI probes for
  every new render declaration.
- No new third-party dependency or version change is expected.

Stop after implementing approved 3B for human review. Do not begin JACK, activation,
processing, GUI, state, reactor, rescan-host-extension, or public `run` work.

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
