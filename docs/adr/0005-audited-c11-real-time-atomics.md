# ADR 0005: Use an audited C11 bridge for real-time atomics

- Status: Accepted for Increment 4C
- Date: 2026-08-28

## Context

The shared product profile keeps stack and line tracing available to the control
plane. Source-level callback pragmas remove trace setup from callback bodies, but
Nim 2.2.10 instantiations of `std/concurrency/atomics` still emit helper functions
that call `nimfr_`, `nimln_`, and `popFrame`. JACK callbacks and process-reachable
CLAP host callbacks invoked those helpers transitively even though the existing
generated-C audit inspected only exported function bodies.

Disabling traces globally would reduce control-plane diagnostics. Accepting the
helpers or continuing a non-transitive audit would contradict the callback safety
profile and the requirement to audit complete real-time call paths.

## Decision

Real-time and foreign-callback storage uses fixed-width atomics declared in
`c/rt_atomic.h` and exposed to Nim through `pluginhost/rt/atomic_pod.nim`.
The bridge:

- Uses C11 `_Atomic` storage and explicit operations.
- Names every operation by memory order rather than accepting an unchecked
  generic order parameter.
- Preserves the approved acquire/release/relaxed semantics at each call site.
- Statically requires always-lock-free 32-bit and 64-bit operations.
- Statically verifies atomic size and alignment against the corresponding
  fixed-width integer type.
- Is included directly in generated translation units so operations can inline
  without a Nim runtime helper or trace frame.

C-versus-Nim ABI tests verify the storage size and alignment. Unit tests exercise
all operations. The generated-C audit scans complete JACK/RT modules, follows the
CLAP host callback helper closure, and audits the C header itself. A compile-only
negative canary must be rejected by that audit.

The bridge is not a general concurrency abstraction. It is limited to the types,
orders, and operations required by current bounded callback communication.

## Alternatives considered

- Disable stack and line traces for the complete product: rejected because
  control-plane diagnostics should retain them.
- Keep `std/concurrency/atomics` and allow its trace helpers: rejected because
  callback-local pragmas would not describe the transitive generated path.
- Audit only exported callback bodies: rejected because prohibited work can hide
  in generated helpers.
- Handwrite callback logic in C: rejected because C must remain a narrow ABI or
  safety bridge rather than an alternate host implementation.
- Use compiler-specific atomics directly from Nim: rejected in favor of the
  standard C11 interface plus explicit lock-free compile-time checks.

## Consequences

- JACK callbacks, the audio-role guard, and process-reachable CLAP host callbacks
  no longer import Nim's atomic wrappers.
- A target without always-lock-free required widths fails at compile time rather
  than silently introducing a lock-based atomic runtime.
- Changes to atomic storage or memory ordering require C/Nim ABI, unit, RT, and
  generated-C audit coverage.
- `c/rt_atomic.h` is handwritten product support code, not generated or vendored
  source, and adds no third-party dependency.
