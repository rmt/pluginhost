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

At the time this file was created:

- Default/current branch: `main`.
- Reviewed baseline commit: `3c7c411` (`feat: complete iteration 0 scaffold with argparse CLI`).
- Version: `0.0.1-dev` (`pluginhost.nimble` uses numeric `0.0.1` because of Nimble metadata syntax).
- Increment 0 is approved; Increment 1 is not started.
- The CLI uses exactly pinned `argparse` 4.0.2.
- Typed parsing exists for implicit/explicit `run`, `list`, and `scan`, including generated scoped help and semantic validation.
- Valid `run`, `list`, and `scan` requests intentionally return typed `NotImplemented` failures.
- There is no CLAP loading, JACK integration, plugin GUI, state persistence, scanning, or real-time processing yet.
- The reviewed suite contains 23 passing tests.
- No remote repository or project license is currently configured.

Current source responsibilities:

- `src/pluginhost.nim` — process composition root and exit handling.
- `src/pluginhost/app/cli.nim` — `argparse` declarations, implicit-`run` normalization, and typed configuration conversion.
- `src/pluginhost/app/run_config.nim` — command/configuration types.
- `src/pluginhost/app/commands.nim` — command dispatch and explicit operation stubs.
- `src/pluginhost/app/host_session.nim` — idempotent stub session coordinator.
- `src/pluginhost/domain/` — typed results, errors, and lifecycle transitions.
- `src/pluginhost/support/diagnostics.nim` — user-facing diagnostics.
- `src/pluginhost/version.nim` — embedded version information.
- `tests/unit/` — CLI, process, lifecycle, error, and version tests.

Only add modules when they gain a real responsibility; do not create the entire future layout as empty scaffolding.

## Current verification commands

Use Nim 2.2 or later; the reference compiler is Nim 2.2.10. Dependencies are managed by Nimble.

```sh
nimble check
nimble build
nimble test
nimble all
```

`nimble test` builds a process-test executable and runs the fast unit suite. `nimble all` also performs the source compile check. New planned tasks such as `testAbi`, `testFixtures`, and `testRt` should be introduced only when they perform real checks; an unavailable task must not report a false pass.

For user-visible CLI changes, also exercise the compiled process directly and verify stdout, stderr, and exit codes. Existing stubs are expected to fail with a non-zero status.

## Next planned work: Increment 1

The next increment is **Pinned FFI and ABI foundation**, planned for `0.0.2-dev`. Its purpose is to prove the Nim/C boundary before host policy is built. See `MVP_IMPLEMENTATION_PLAN.md` section 8 for the complete scope.

Before writing Increment 1 code, present a pre-code review package and wait for explicit approval. It must cover:

- Goal and explicit non-goals.
- Exact files to add/change.
- Raw CLAP and JACK interfaces included in this increment.
- ABI probes, fixture libraries, callback/thread tests, and commands to run them.
- How official CLAP 1.2.10 headers and license metadata will be pinned.
- Binding strategy (hand-maintained, generated, or generated then curated) and the proposed ADR.
- Direct JACK FFI versus audited `jacket` use.
- Dynamic-library ownership and partial-failure cleanup.
- Calling conventions, `raises: []`, C-created-thread behavior, memory-manager assumptions, and the process-callback-shaped allocation/runtime spike.
- Any new dependencies, maintenance/license record, and unresolved human decisions.

Do not proceed into plugin discovery or host lifecycle policy during this increment. Raw FFI modules must remain policy-free, and imported declarations must be verified against official headers rather than copied from memory.

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
