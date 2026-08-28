# ADR 0004: Load JACK through a checked owned procedure table

- Status: Accepted
- Date: 2026-08-28

## Context

Nim `{.dynlib.}` procedure imports generate module-initialization code that
loads the named library and resolves imported symbols as soon as the module is
reachable. Once the application imports its JACK backend, that behavior would
make `--help`, `--version`, `list`, and `scan` fail during process startup on a
machine without `libjack.so.0`. It would also bypass the host's typed JACK error
and cleanup model.

The project already has a checked, move-only Linux `dlopen`/`dlsym`/`dlclose`
owner for CLAP libraries.

## Decision

`jack/ffi.nim` contains only constants, ABI types, callback types, and typed
procedure-pointer declarations. It has no `{.dynlib.}` imports.

`jack/api.nim` explicitly opens `libjack.so.0` through the checked Linux loader,
resolves the complete reviewed JACK procedure table, and returns a move-only
`JackApi`. A missing library or required symbol is a typed JACK error with exit
status 4. Any partial resolution is rolled back before failure is returned.
Close is explicit, checked, and idempotent.

Procedure pointers borrowed or copied from the table are valid only while their
owning `JackApi` remains open. The future `JackBackend` must keep that owner open
until its client is closed and every callback is quiescent.

## Alternatives considered

- Keep `{.dynlib.}` imports: rejected because loading is eager and diagnostics
  bypass application policy.
- Link directly with `-ljack`: rejected for the same information-command
  dependency and untyped dynamic-loader failure.
- Add a C wrapper library: rejected because the stable procedure signatures can
  be represented and resolved directly in Nim.
- Resolve symbols lazily on each call: rejected because it adds control and DSO
  operations to call sites and could reach real-time code.

## Consequences

- Information commands remain independent of JACK at process startup.
- Backend startup performs one explicit all-or-nothing symbol-resolution step.
- The project owns the procedure-table declaration and its ABI tests.
- Runtime code calls prevalidated function pointers; it never performs DSO
  operations in a JACK callback.
- No additional package or runtime dependency is introduced.
