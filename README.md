# pluginhost

`pluginhost` is an in-progress standalone Linux JACK host for native CLAP plugins, implemented in Nim. Its intended role is similar to `carla-single`, with one plugin instance and one JACK client per process.

The current development version is **0.0.1-dev**. This increment provides project scaffolding and a working CLI shell only; plugin loading and JACK integration are not implemented yet.

## Build

Requirements:

- Nim 2.2 or later
- Nimble
- `argparse` 4.0.2 (installed by Nimble)

```sh
nimble check
nimble build
```

## Test

```sh
nimble test
nimble all
```

## Dependency note

The CLI uses [`argparse`](https://github.com/iffy/nim-argparse) 4.0.2,
pinned exactly in `pluginhost.nimble`. It was selected over more manual
`std/parseopt` handling because it provides typed subcommands, generated scoped
help, and parsing from explicit argument arrays for tests. It is MIT-licensed,
has no transitive package dependencies, and is used only in the non-real-time
control plane.

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
