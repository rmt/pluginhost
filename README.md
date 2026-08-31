# pluginhost

`pluginhost` is an in-progress standalone Linux JACK host for native CLAP plugins, implemented in Nim. Its intended role is similar to `carla-single`, with one plugin instance and one JACK client per process.

The current development version is **0.0.6-dev**. The implementation includes
checked CLAP ownership/catalog/lifecycle, human/JSON `list` and recursive `scan`,
a stable CLAP host bridge, bounded immutable audio/note port planning, real-time
render negotiation, and an internal checked JACK backend with transactional ports and
stable callbacks. Increment 5 adds an internal CLAP/JACK float32 audio slice with
zero-copy grouped buffers, lifecycle rollback, configuration quiescence, synthetic
fixtures, generated-call-path evidence, and an explicit independent-plugin smoke
hook. The canonical public `run` path remains disabled.

## Build

Requirements:

- Nim 2.2 or later
- Nimble
- `argparse` 4.0.2 (installed by Nimble)
- A GNU-compatible C11 compiler (GCC or Clang), GNU-compatible linker `--wrap`, `pkg-config`, and Binutils `readelf` for verification
- JACK development headers and `libjack.so.0` for ABI tests
- Python 3 for generated-code auditing and the disposable integration harness
- PipeWire, PipeWire's JACK implementation, `pw-jack`, `pw-cli`, and `pw-dump` for `testIntegration` and the strict `all` gate

```sh
nimble check
nimble build
```

## Test

```sh
nimble test
nimble testAbi
nimble testFixtures
nimble testRt
# Requires an independently installed headless CLAP plugin:
PLUGINHOST_CLAP_SMOKE_PLUGIN=/absolute/path/to/headless.clap nimble testIntegration
nimble all
```

## Dependency note

The CLI uses [`argparse`](https://github.com/iffy/nim-argparse) 4.0.2,
pinned exactly in `pluginhost.nimble`. It was selected over more manual
`std/parseopt` handling because it provides typed subcommands, generated scoped
help, and parsing from explicit argument arrays for tests. It is MIT-licensed,
has no transitive package dependencies, and is used only in the non-real-time
control plane.

`nimble testAbi` verifies the handwritten raw bindings against the vendored
official CLAP 1.2.10 headers and the installed JACK development headers. It also
checks missing-library/symbol rollback and runtime calls through the owned JACK
procedure table. The complete CLAP header tree is preserved under `vendor/clap/`
with its MIT license and exact upstream provenance. Draft headers are vendored
unchanged but are not part of pluginhost's bound or supported ABI surface.

`nimble test` also compiles a complete controllable fake JACK DSO and checks client
statuses, callback registration, transactional ports, quiescence, role exclusivity, and
fake silence/copy/deterministic processing without requiring a JACK server.

`nimble testFixtures` independently compiles synthetic CLAP libraries and checks
entry/factory ownership, descriptor validation, instance cleanup, deactivated audio/note
port inspection, render negotiation, the internal float32 audio lifecycle and zero-copy
group mapping, process-level `list`, and recursive `scan` behavior.

All builds share `--mm:arc --threads:on --panics:on -d:noSignalHandler` through
`config.nims`. Foreign callbacks additionally disable checks and trace setup locally
after explicit input validation; `raises: []` alone is not treated as a Defect barrier.
Callback atomics use a narrow audited, always-lock-free C11 bridge because Nim 2.2.10's
standard atomic helpers install trace frames under the product profile.

`nimble testRt` retains repeated/first-foreign-thread Nim allocation checks, audits
complete JACK/RT generated modules and the process-reachable CLAP host callback helper
closure under product flags, and requires rejection of a prohibited allocation canary.

`nimble testIntegration` creates isolated mode-0700 private runtimes, launches uniquely
named PipeWire cores with their Dummy-Drivers at 48 kHz/64 frames, validates the internal
CLAP float32 lifecycle against an independently installed headless plugin, validates live
audio/MIDI ports and deterministic samples through a separate JACK peer, proves
cycle-based quiescence and client-close port removal, runs 32 repeated active-close
lifecycles, and requires zero instrumented C allocation, deallocation, lock, print, or
prohibited-I/O operations in host callback scope. Set
`PLUGINHOST_CLAP_SMOKE_PLUGIN=/absolute/path/to/headless.clap`; missing smoke
prerequisites fail rather than skip. `nimble all` includes this live task.

The checked Linux loader uses `dlopen`/`dlsym`/`dlclose` without another Nim package.
Both its generic owner and `JackApi` are move-only and require explicit, checked,
idempotent close. Importing JACK declarations does not load `libjack.so.0`; information
commands remain independent of JACK, and the internal backend loads it explicitly.

## Security

`list` and `scan` load and unload CLAP libraries and execute their entry, factory,
and descriptor code in-process with the current user's permissions. A malformed or
hostile plugin can crash or compromise the host; plugin-created threads, TLS, or exit
handlers can also make unload unsafe. Validation and cleanup do not provide
sandboxing. Inspect only plugins you trust.

Descriptor inspection is bounded to 4,096 descriptors, 64 KiB per descriptor
string, 256 features of 4 KiB each, and 16 MiB total copied metadata per library.
Invalid UTF-8 is replaced and human-readable control characters are escaped.

## Current commands

```text
pluginhost --help
pluginhost --version
pluginhost [options] PLUGIN_PATH
pluginhost list [--json] PLUGIN_PATH
pluginhost scan [--json] [DIRECTORY ...]
```

`list` reports index, ID, name, vendor, version, and features without creating a
plugin instance. `scan` recursively discovers canonical `.clap` files, continues
past per-root and per-candidate failures, reports successful descriptors, and uses
exit status 3 when any issue occurred. Relative explicit/`CLAP_PATH` roots resolve
from the current working directory; environment values do not expand `~`. The
Increment 5 audio slice is internal/test-only; `run` remains an explicit
not-implemented failure until orderly signal/reactor control is implemented.

## Project documents

- [Product requirements](REQUIREMENTS.md)
- [High-level software design](DESIGN.md)
- [MVP implementation plan](MVP_IMPLEMENTATION_PLAN.md)

## License

No project license has been selected yet. Until a license is added, no permission is granted to copy, modify, or distribute the source code.
