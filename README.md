# pluginhost

`pluginhost` is an in-progress standalone Linux JACK host for native CLAP plugins, implemented in Nim. Its intended role is similar to `carla-single`, with one plugin instance and one JACK client per process.

The current development version is **0.0.3-dev**. The reviewed implementation
adds checked CLAP entry/factory ownership, copied descriptor catalogs, selection
policy, and working human/JSON `list` output to the previously reviewed scaffold,
raw CLAP/JACK FFI, loader, callback probes, and ABI/RT tests. Discovery, plugin
instances, and JACK runtime integration are not implemented yet.

## Build

Requirements:

- Nim 2.2 or later
- Nimble
- `argparse` 4.0.2 (installed by Nimble)
- A GNU-compatible C11 compiler (GCC or Clang) and `pkg-config` for ABI tests
- JACK development headers and `libjack.so.0` for ABI tests
- Python 3 for the generated real-time callback audit

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
official CLAP 1.2.10 headers and the installed JACK development headers. The
complete CLAP header tree is preserved under `vendor/clap/` with its MIT license
and exact upstream provenance. Draft headers are vendored unchanged but are not
part of pluginhost's bound or supported ABI surface.

`nimble testFixtures` independently compiles synthetic CLAP libraries and checks
entry/factory ownership, descriptor validation, cleanup counters, and process-level
`list` behavior without creating a plugin instance.

`nimble testRt` compiles a process-shaped callback with ARC and thread support,
checks Nim allocator counters over repeated and first-foreign-thread calls, and
audits the generated C callback body for prohibited operations. This is the
initial FFI-boundary spike, not yet proof of a complete JACK process path.

The checked Linux loader uses the platform `dlopen`/`dlsym`/`dlclose` API and
adds no Nim package dependency. Its owner is move-only and requires explicit,
checked, idempotent close.

## Security

`list` loads the selected CLAP library and executes its entry initialization and
factory code in-process with the current user's permissions. A malformed or hostile
plugin can crash or compromise the host; validation and cleanup do not provide
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

`list` is implemented and reports index, ID, name, vendor, version, and features
without creating a plugin instance. `run` and `scan` remain explicit
not-implemented failures until their runtime increments are complete.

## Project documents

- [Product requirements](REQUIREMENTS.md)
- [High-level software design](DESIGN.md)
- [MVP implementation plan](MVP_IMPLEMENTATION_PLAN.md)

## License

No project license has been selected yet. Until a license is added, no permission is granted to copy, modify, or distribute the source code.
