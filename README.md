# pluginhost

`pluginhost` is an in-progress standalone Linux JACK host for native CLAP plugins, implemented in Nim. Its intended role is similar to `carla-single`, with one plugin instance and one JACK client per process.

The current development version is **0.0.1-dev**. The reviewed implementation
includes the project scaffold, working CLI shell, pinned raw CLAP/JACK FFI, and
C-versus-Nim ABI tests. Plugin loading and JACK runtime integration are not
implemented yet.

## Build

Requirements:

- Nim 2.2 or later
- Nimble
- `argparse` 4.0.2 (installed by Nimble)
- A GNU-compatible C11 compiler (GCC or Clang) and `pkg-config` for ABI tests
- JACK development headers and `libjack.so.0` for ABI tests

```sh
nimble check
nimble build
```

## Test

```sh
nimble test
nimble testAbi
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

## Current commands

```text
pluginhost --help
pluginhost --version
pluginhost [options] PLUGIN_PATH
pluginhost list [--json] PLUGIN_PATH
pluginhost scan [--json] [DIRECTORY ...]
```

`run`, `list`, and `scan` are parsed and validated but intentionally return a not-implemented error in this scaffolding increment.

## Project documents

- [Product requirements](REQUIREMENTS.md)
- [High-level software design](DESIGN.md)
- [MVP implementation plan](MVP_IMPLEMENTATION_PLAN.md)

## License

No project license has been selected yet. Until a license is added, no permission is granted to copy, modify, or distribute the source code.
