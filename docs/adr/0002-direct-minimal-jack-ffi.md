# ADR 0002: Use a direct minimal JACK FFI

- Status: Accepted
- Date: 2026-08-23

## Context

The host requires a narrow part of the stable JACK client ABI and must attach
strict effects to callbacks that can execute on foreign real-time threads. The
reviewed `jacket` 0.2.0 package is MIT-licensed and useful, but remains marked
beta, wraps a much broader API, models some bit fields as Nim enums, marks many
error-returning calls discardable, and does not put `raises: []` on callback
types. Adopting it would not remove the need for a complete ABI and real-time
audit.

## Decision

Maintain a policy-free JACK declaration module in
`src/pluginhost/jack/ffi.nim` for only the client, callback, port, audio, MIDI,
buffer-size, sample-rate, and latency APIs required by the MVP. The module
declares typed procedure pointers rather than eager imported procedures; ADR
0004 defines checked runtime symbol ownership.

Use `libjack.so.0`, preserving compatibility with JACK1, JACK2, and
PipeWire-JACK implementations exposing the standard ABI. Verify declarations
against the JACK development headers available on each test platform. Callback
signatures use `cdecl`, `gcsafe`, and `raises: []`.

## Alternatives considered

- Depend directly on `jacket`: rejected for the audit and API-surface reasons
  above.
- Fork or vendor `jacket`: rejected because reducing and correcting the wrapper
  would effectively create the same project-owned minimal FFI with additional
  maintenance history.
- Link a C shim: rejected because the stable C ABI can be represented directly
  in Nim and a shim would add an unnecessary production boundary.

## Consequences

- No additional Nim package dependency is introduced.
- The project owns maintenance of a small set of declarations.
- ABI tests require a C compiler, `pkg-config`, and JACK development headers.
- Runtime JACK access remains through the standard `libjack.so.0` ABI and the
  checked procedure table specified by ADR 0004.
- Adding another JACK API requires declaration, ABI-probe, and thread/RT review.
