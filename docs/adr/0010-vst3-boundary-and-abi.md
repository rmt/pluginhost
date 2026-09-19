# ADR 0010: VST3 sibling adapter and generated C ABI

- **Status:** Accepted V0 scope decision; implementation gates remain separately reviewed
- **Date:** 2026-09-19

## Context

The host is a reviewed single-instance Linux/JACK CLAP host. VST3 is a
separate scope expansion with a COM-like ABI, processor/controller split,
seekable state streams, native editor services, and a JACK real-time endpoint.
The existing architecture already provides reusable JACK, reactor, Linux
loader, X11, and backend-neutral real-time boundaries, but the current
application composition owns concrete CLAP types.

VST3 support must not become a format switch in the JACK process loop, a fake
CLAP translation layer, or an unreviewed production C++ host. The initial
configuration is native Linux x86_64, float32 JACK processing, one processor
instance and one JACK client, optional X11/XEmbed editor hosting, and bounded
standard `.vstpreset` state persistence.

The pinned inputs are:

- VST3 SDK tag `v3.8.1_build_84`, root `3cdf9ca5d1f5b1b21e0a86832aa4abe55607bd96`.
- Generated C API commit `93a116f7c6c52a317ec3aaee9b13789068b5234e`.
- C++ fixture/interface headers commit `4f547e8e102b47de4a8b8aaf343c73b700786372`.
- Optional SDK helper source commit `586dc5e6c8012c3e4b01c79389375cbe96bdb1da`.

The generated C API is distributed with BSD-3-Clause-style license text while
its README retains a conflicting dual-license statement. The vendored license
text and provenance must be preserved and the discrepancy must be documented
before redistribution.

## Decision

Use Steinberg's official generated C declarations in production. Bind them
from Nim through explicit ABI declarations and small C probes/wrappers only
where compiler-checked UID or calling-convention details require it. Keep
production host policy in Nim. Compile an independently implemented C++
fixture for ABI interoperability evidence; the fixture must not implement
itself from the generated C header and does not make C++ a production build
requirement.

Add a sibling `pluginhost/vst3/` adapter. It owns native VST3 lifecycle,
processor/controller interfaces, host objects, run-loop registrations,
bounded parameter/event transport, preset streams, and editor resources. A
small internal `ProcessorClient` capability composes either the CLAP or VST3
adapter with the existing `JackBackend`, `MainReactor`, and
`RtProcessEndpoint`. Raw VST3 types never enter domain or application policy.

`Vst3Module` owns the canonical bundle, architecture-selected binary, DSO,
module entry/exit ledger, factory references, copied catalog, and mapping
retention. `Vst3Instance` owns separately acquired interface references and
records every successful initialization, connection, setup, processing, view,
and service transition. Module exit and DSO close occur only after all
borrowers and retained callbacks are released. A failed module entry is
balanced by one `ModuleExit` after an invocation, including a false return,
according to the pinned Linux module behavior; missing symbols never invoke
entry or exit.

The VST3 catalog identifies processors by canonical 32-hexadecimal CIDs and
filters factory classes to `kVstAudioEffectClass`. `.vst3` directories are
terminal candidates. Inner binaries, flat bundles, incompatible ELF
architectures, and controller CIDs are rejected explicitly. VST3 list/scan
must not create a plugin instance or open JACK, X11, or D-Bus.

The JACK-facing plan is format-neutral: media type, direction, grouping,
channel order, copied names, and an adapter-local opaque identity. VST3 bus
indices are layout-local and are not reconnection identities. Structural VST3
changes conservatively report connection loss rather than reconnecting by
matching index or name. The process endpoint is fully preallocated before
JACK activation and is audited independently of CLAP paths.

## Consequences

- The production compiler remains Nim plus the existing C toolchain; no C++
runtime or framework dependency is added.
- The generated header and its license/provenance are vendored only at V1A,
after this V0 decision. Generated declarations and handwritten policy must be
separable in review.
- VST3 work proceeds through V1A/V1B, V2A/V2B, V3, V4A/V4B, V5A/V5B, and V6.
Public VST3 `run` is unavailable until V6. Passing a fixture gate does not
certify later interfaces or real plugins.
- Every process-reachable VST3 callback and container adds to the existing
generated-C, allocator, lock, and prohibited-I/O audit. CLAP-only evidence is
not reused as VST3 evidence.
- The generated C API license discrepancy is a redistribution review item;
the project remains MIT and does not adopt VST branding or logos.

## Alternatives rejected

### Production C++ bridge

A narrow `extern "C"` C++ bridge would let the compiler express native
inheritance, but it adds a production language/toolchain and allocator/RT
boundary. It remains an alternative only if the independent C ABI experiment
fails and receives a new owner decision.

### Translate VST3 through CLAP

This would lose VST3 bus indices, parameter-curve semantics, controller
state, MIDI mapping, and editor/run-loop contracts. It is explicitly rejected.

### Universal plugin framework

A lowest-common-denominator framework would either weaken native contracts or
create speculative abstractions. Shared types are limited to actual
application needs and native semantics stay in sibling adapters.
