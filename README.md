# pluginhost

`pluginhost` is an in-progress standalone Linux JACK host for native CLAP plugins, implemented in Nim. Its intended role is similar to `carla-single`, with one plugin instance and one JACK client per process.

The current development version is **0.0.9-dev**. The implementation includes checked CLAP ownership/catalog/lifecycle, human/JSON `list` and recursive `scan`, grouped zero-copy JACK audio, and a fixed-capacity sample-accurate JACK MIDI/CLAP event bridge. The canonical public command runs one plugin headlessly under an `epoll`/`signalfd` main reactor, handles orderly signals and JACK/process failures, services CLAP main-thread callbacks plus generation-safe plugin timers and POSIX FDs, reflects plugin latency through JACK, tracks dirty-state notification, refreshes runtime audio configuration, and owns an optional atomic PID file. State serialization, parameters, restart/rescans, GUI, and later host extensions remain unavailable.

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
# These strict gates require an independently installed headless CLAP plugin:
PLUGINHOST_CLAP_SMOKE_PLUGIN=/absolute/path/to/headless.clap nimble testIntegration
PLUGINHOST_CLAP_SMOKE_PLUGIN=/absolute/path/to/headless.clap nimble all
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

`nimble testFixtures` independently compiles synthetic CLAP libraries and checks entry/factory ownership, descriptor validation, instance cleanup, deactivated port inspection, render negotiation, internal grouped float32 audio, fixed-capacity event translation, and main-thread timer/FD/dirty/latency services. Event cases cover global ordering, equal timestamps, raw MIDI/SysEx lifetime, CLAP-only note conversion, malformed events, exact capacity, output reserve failure, recovery, and MIDI2-only rejection.

All builds share `--mm:arc --threads:on --panics:on -d:noSignalHandler` through
`config.nims`. Foreign callbacks additionally disable checks and trace setup locally
after explicit input validation; `raises: []` alone is not treated as a Defect barrier.
Callback atomics use a narrow audited, always-lock-free C11 bridge because Nim 2.2.10's
standard atomic helpers install trace frames under the product profile.

`nimble testRt` retains repeated/first-foreign-thread Nim allocation checks, includes success/overflow/malformed event-process paths, audits complete JACK/RT generated modules and process-reachable CLAP host/audio/event callback closures under product flags, and requires rejection of a prohibited allocation canary.

`nimble testIntegration` creates isolated mode-0700 private runtimes, launches uniquely
named PipeWire cores with their Dummy-Drivers at 48 kHz/64 frames, and runs four
isolated scenarios. It validates public PID publication, rate-limited GUI-signal
reservation, clean `SIGINT`/`SIGTERM` shutdown, the internal CLAP float32 lifecycle
against an independently installed headless plugin, deterministic live audio, and exact
multi-port MIDI/SysEx offsets. It also proves quiescence, client-close port removal,
repeated lifecycles, and zero instrumented C allocation, deallocation, lock, print, or
prohibited-I/O operations in host callback scope. Set
`PLUGINHOST_CLAP_SMOKE_PLUGIN=/absolute/path/to/headless.clap`; optionally set
`PLUGINHOST_CLAP_SMOKE_PLUGIN_ID` when the library contains multiple plugins. Missing
prerequisites fail rather than skip. `nimble all` includes all four isolated live runs.

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
from the current working directory; environment values do not expand `~`.
The canonical path-only command runs headlessly. `SIGINT` and `SIGTERM` request clean
shutdown; `SIGUSR1` and `SIGUSR2` are safely consumed but only warn until GUI hosting
lands. `--pid-file` atomically publishes the running PID and removes only the entry the
process owns. Default/show/hidden GUI policies warn and fall back to headless operation;
`--require-gui`, `--gui-scale`, `--load-state`, and `--save-state` fail explicitly until
their owning increments.

## Project documents

- [Product requirements](REQUIREMENTS.md)
- [High-level software design](DESIGN.md)
- [MVP implementation plan](MVP_IMPLEMENTATION_PLAN.md)

## License

No project license has been selected yet. Until a license is added, no permission is granted to copy, modify, or distribute the source code.
