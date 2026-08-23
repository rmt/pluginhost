# ADR 0001: Maintain minimal CLAP bindings verified against pinned headers

- Status: Accepted
- Date: 2026-08-23

## Context

pluginhost needs ABI-exact CLAP declarations, explicit callback effects, and a
small reviewable surface. Existing Nim bindings were reviewed against an older
CLAP baseline and do not cover the host extensions required by the product.
General C binding generators also produce a broad mechanical diff that obscures
calling conventions, pointer lifetimes, and real-time constraints.

## Decision

Vendor the official CLAP 1.2.10 headers and maintain a minimal handwritten raw
binding in `src/pluginhost/clap/ffi.nim`.

The raw module mirrors C layout and semantics, contains no host policy, and marks
callbacks with the Linux C calling convention and `raises: []`. Every imported
structure, field, scalar width, constant, and callback signature used by the
host is checked against a C probe compiled from the pinned headers.

Only stable CLAP declarations enter the Nim binding. Draft headers remain in the
unaltered vendored tree for provenance but are not part of the supported ABI
surface.

## Alternatives considered

- Adopt `nim-clap`: rejected because its reviewed baseline and extension surface
  do not satisfy this project's requirements without a full audit and rewrite.
- Generate all bindings: rejected because generator handling of macros and
  callbacks would still require manual curation and ABI tests while producing a
  substantially larger review surface.
- Generate then curate: viable for a much larger API, but adds a generator and
  reproducibility workflow without reducing the current verification burden.

## Consequences

- The imported surface stays small and auditable.
- Header updates require manual declaration review and ABI-test updates.
- The C probe, rather than transcription confidence, is the ABI source of truth.
- No binding-generation dependency or generated Nim source is added.
