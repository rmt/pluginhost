# pluginhost

`pluginhost` is a standalone Linux JACK host for native CLAP and VST3 plugins,
implemented in Nim. Each process owns exactly one plugin instance and one JACK
client.

The current release-candidate version is **0.1.0-rc.1**. The implementation
includes checked CLAP and VST3 ownership/catalog/lifecycle, human/JSON `list`
and recursive `scan`, grouped zero-copy JACK audio, and a fixed-capacity
sample-accurate JACK MIDI/CLAP event bridge. The canonical public command runs
one selected plugin instance as one JACK client under an `epoll`/`signalfd`
main reactor, handles orderly signals and JACK/process failures, services
format-specific main-thread callbacks and run loops, and supports bounded
format-native state transactions, optional atomic PID files, and GUI/tray
hosting without entering JACK callback scope.

## Why?

Over the past few years, I've been using python and nim to create a personal (currently unpublished) musical creation tools, runtime and TUI, turning musical pattern languages and notations into MIDI, along with some audio synthesis experiments as I learn from an impressively thick book.  It's a part-time hobby project that I pick up and drop as time and interest allows.

While DAWs have _all the features_, they're usually heavy-weight, and can eat significant CPU and RAM even when idle, and aren't suitable for embedding in a nim project.  carla-single was mostly doing the job, but it also has its quirks, and I eventually want to embed this directly.

Creating a standalone pluginhost for CLAP and VST3 is the current focus. LV2
support and easier embedding (in Nim, at least) remain future work.

## How?

This was initially implemented primarily with a chatgpt business subscription
over the course of a few weeks using gpt-5.6-sol and luna primarily with the pi
coding agent, with manual testing and bugfixes along the way.

Why use AI?  Writing a plugin host is error prone and boring, but all aspects
(nim, clap, jack, X11) are quite well specified, making it a good candidate for
AI assisted development, and being an interactive program, issues can be
identified and fixed rapidly.  Also: I would not have started this without AI.

I was not completely confident that AI would get the job done, but the proof is
in the pudding: it works well, and I'm using it every day already.

## Build

VST3 public compatibility evidence additionally requires owner-selected,
independently installed VST3 instrument and effect bundles; their paths and
canonical processor CIDs are supplied through the variables documented below.
The synthetic fixtures cover lifecycle and state behavior, but cannot
substitute for compatibility evidence from independent native plugins.
Requirements:

- Nim 2.2 or later
- Nimble
- `argparse` 4.0.2 (installed by Nimble)
- A GNU-compatible C11 compiler (GCC or Clang), GNU-compatible linker `--wrap`, `pkg-config`, and Binutils `readelf` for verification
- JACK development headers and `libjack.so.0` for ABI tests
- C++17 compiler and VST3 ABI headers under `vendor/vst3` for synthetic
  fixture builds
- Python 3 for generated-code auditing and the disposable integration harness
- PipeWire, PipeWire's JACK implementation, `pw-jack`, `pw-cli`, and `pw-dump` for `testIntegration` and the strict `all` gate
- Xlib, D-Bus development headers/runtime (`dbus-1`, `dbus-run-session`, and `gdbus`), `Xvfb`, and `xvfb-run` for `testGui` and the strict `all` gate

```sh
nimble check
nimble build
```

## Test

Fast and focused checks:

```sh
nimble test
nimble testAbi
nimble testFixtures
nimble testRt
nimble testHardening
nimble testVst3Public
nimble sanitize
nimble testGui
```

The strict public acceptance matrix requires four independently selected
installed plugin paths/IDs (one may be reused only when the plugin is
independently selected) and an isolated PipeWire-JACK runtime:

```sh
export PLUGINHOST_RELEASE_INSTRUMENT_PLUGIN=/absolute/path/to/instrument.clap
export PLUGINHOST_RELEASE_INSTRUMENT_ID=stable.instrument.id
export PLUGINHOST_RELEASE_SECOND_INSTRUMENT_PLUGIN=/absolute/path/to/second-instrument.clap
export PLUGINHOST_RELEASE_SECOND_INSTRUMENT_ID=stable.second.instrument.id
export PLUGINHOST_RELEASE_EFFECT_PLUGIN=/absolute/path/to/stereo-effect.clap
export PLUGINHOST_RELEASE_EFFECT_ID=stable.effect.id
export PLUGINHOST_RELEASE_COMPATIBILITY_PLUGIN=/absolute/path/to/compatibility-effect.clap
export PLUGINHOST_RELEASE_COMPATIBILITY_ID=stable.compatibility.id
nimble testAcceptance
```

`nimble testAcceptance` also measures no-event host overhead, exercises the
foreign-thread teardown race and public JACK-loss status, and verifies grouped
audio/note ports with the independent fixture. Missing prerequisites fail; no
acceptance row is silently skipped. `nimble all` includes this matrix after the
unit, ABI, RT, fixture, hardening, live, and GUI checks.

The live checks require an independently installed headless CLAP plugin:

```sh
export PLUGINHOST_CLAP_SMOKE_PLUGIN=/absolute/path/to/headless.clap
export PLUGINHOST_CLAP_SMOKE_PLUGIN_ID=optional.stable.id
nimble testIntegration
nimble all
```
The strict public VST3 process task uses synthetic bundles for deterministic
selection, JACK audio, PID/signal cleanup, `.vstpreset` load/save, and reload
lifecycle evidence. It also runs independent instrument and effect bundles
under the disposable PipeWire-JACK server and exercises the effect GUI under
Xvfb. The effect path MUST identify a GUI-capable VST3 bundle; set all four
variables before running it. Missing compatibility prerequisites fail
before any row can pass:

```sh
export PLUGINHOST_VST3_INSTRUMENT_PLUGIN=/absolute/path/to/instrument.vst3
export PLUGINHOST_VST3_INSTRUMENT_ID=canonical.processor.cid
export PLUGINHOST_VST3_EFFECT_PLUGIN=/absolute/path/to/stereo-effect.vst3
export PLUGINHOST_VST3_EFFECT_ID=canonical.processor.cid
nimble testVst3Public
```

GUI plugins using OpenGL need working GLX in Xvfb. On systems with a
proprietary EGL vendor that crashes the software X server, select the installed
Mesa vendor for this test process (if available), for example:

```sh
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json \
  LIBGL_ALWAYS_SOFTWARE=1 nimble testVst3Public
```

`nimble all` performs the same VST3 preflight and includes the strict public
task. The independent plugin paths are intentionally owner-provided: native
VST3 compatibility, GUI behavior, and vendor state quirks cannot be inferred
from synthetic fixtures.

After all prior evidence passes and the owner selects the release-candidate
version, `nimble releaseCandidate` builds and inspects
`build/release/pluginhost`, checks its version/architecture and forbidden
eager platform dependencies, and writes
`build/release/pluginhost.sha256`. It refuses to run while `VERSION` is still
the development version.

## Dependency note

The CLI uses [`argparse`](https://github.com/iffy/nim-argparse) 4.0.2,
pinned exactly in `pluginhost.nimble`. It was selected over more manual
`std/parseopt` handling because it provides typed subcommands, generated scoped
help, and parsing from explicit argument arrays for tests. It is MIT-licensed,
has no transitive package dependencies, and is used only in the non-real-time
control plane.

`nimble testAbi` verifies the handwritten raw bindings against the vendored
official CLAP 1.2.10 headers, the installed JACK development headers, the installed Xlib and libdbus layouts, and the dynamic-loader boundaries. `nimble testGui` independently compiles the CLAP GUI fixture, X11 window-host/controller test, and a fake StatusNotifierWatcher, then runs the X11 and D-Bus paths under disposable Xvfb/session-bus environments. The complete CLAP header tree is preserved under `vendor/clap/`
with its MIT license and exact upstream provenance. Draft headers are vendored
unchanged but are not part of pluginhost's bound or supported ABI surface.

`nimble test` also compiles a complete controllable fake JACK DSO and checks client
statuses, callback registration, transactional ports, quiescence, role exclusivity, and
fake silence/copy/deterministic processing without requiring a JACK server.

`nimble testFixtures` independently compiles synthetic CLAP libraries and checks entry/factory ownership, descriptor validation, instance cleanup, bounded CLAP state load/save and rollback, deactivated port inspection, render negotiation, internal grouped float32 audio, fixed-capacity event/parameter translation, CLAP GUI call order/policy, sleep/wake, main-thread timer/FD/dirty/latency services, restart/rescan rebuild, and compatible JACK reconnection/loss reporting. Unchanged JACK-visible restart layouts keep the JACK client and external connections in place; structural changes use the bounded snapshot/rebuild/reconnect path. Event cases cover global ordering, equal timestamps, raw MIDI/SysEx lifetime, CLAP-only note conversion, malformed events, exact capacity, output reserve failure, recovery, and MIDI2-only rejection.

All builds share `--mm:arc --threads:on --panics:on -d:noSignalHandler` through
`config.nims`. Foreign callbacks additionally disable checks and trace setup locally
after explicit input validation; `raises: []` alone is not treated as a Defect barrier.
Callback atomics use a narrow audited, always-lock-free C11 bridge because Nim 2.2.10's
standard atomic helpers install trace frames under the product profile.

`nimble testRt` retains repeated/first-foreign-thread Nim allocation checks, includes success/overflow/malformed event-process paths, audits complete JACK/RT/parameter generated modules and process-reachable CLAP host/audio/event callback closures under product flags, and requires rejection of a prohibited allocation canary.

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

The checked Linux loader uses `dlopen`/`dlsym`/`dlclose` without another Nim
package. Its generic owner, `JackApi`, `X11Api`, `DbusApi`, and VST3 module
owners are move-only and require explicit, checked, idempotent close.
Importing JACK, X11, D-Bus, or VST3 declarations does not eagerly load their
shared libraries; information and headless commands remain independent of
those platform libraries, and concrete backends load them explicitly.


The optional tray backend owns a private dynamically loaded libdbus-1 session
connection and exports a `org.freedesktop.StatusNotifierItem` object. It
registers with the standard `org.freedesktop.StatusNotifierWatcher` and also
tries the deployed KDE-compatible `org.kde.StatusNotifierWatcher` name.
If no watcher or session bus is available, the host warns and continues with
its normal GUI and signal policy. The legacy XEmbed system-tray protocol is
not used. CLAP 1.2.10 has no standard plugin-icon extension, so `--icon` accepts
a bounded 8-bit RGB PPM image; otherwise the host uses a generic fallback icon
for both the StatusNotifierItem and the X11 window.

## Security

`list` and `scan` load and unload CLAP or VST3 libraries and execute their
entry, factory, and descriptor code in-process with the current user's
permissions. A malformed or hostile plugin can crash or compromise the host;
plugin-created threads, TLS, or exit handlers can also make unload unsafe.
Validation and cleanup do not provide sandboxing. Inspect only plugins you
trust.

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
plugin instance. It accepts both `.clap` files and canonical `.vst3` bundles.
`scan` recursively discovers canonical `.clap` files and `.vst3` bundles,
continues past per-root and per-candidate failures, reports successful
descriptors, and uses exit status 3 when any issue occurred. Relative explicit
roots resolve from the current working directory; environment values do not
expand `~`.
The canonical path-only command runs one selected CLAP or VST3 plugin instance
as one JACK client. The Linux process name and X11 window title use
`$PluginName [$PluginFormat]`, for example `Surge XT [CLAP]` or
`Surge XT [VST3]`.
Linux `ps`/`top` `COMM` output is limited to 15 bytes, so long process names
are UTF-8-safe truncated; the X11 title retains the full display name.
`SIGINT` and `SIGTERM` request clean shutdown; `SIGUSR1` shows and `SIGUSR2`
hides the GUI when enabled, while `--no-gui` retains a rate-limited disabled-GUI
warning. `--pid-file` atomically publishes the running PID and removes only the
entry the process owns.
By default the host attempts an embedded X11 GUI, falls back to floating X11
when supported, and otherwise warns and continues headlessly; `--hide-gui`
creates it hidden, `--require-gui` makes failure fatal, and `--gui-scale`
requests a positive scale. `--icon PATH` loads a bounded P3/P6 8-bit RGB PPM
image and applies it to both the X11 window and the StatusNotifierItem tray
item; without it, a generic icon is used.
When a StatusNotifierWatcher is available, the tray item's left-click activation
alternates GUI show/hide; watcher/session-bus absence is a warning, not a
startup failure. Tray events are handled on the CLAP main/reactor thread and do
not affect audio. The backend accepts both the standard freedesktop and KDE
StatusNotifierItem interface spellings.
The GUI path is main-thread-only and does not enter JACK processing. `--load-state`
loads format-native state before audio configuration. `--save-state` saves after
JACK processing is quiesced during clean `SIGINT`/`SIGTERM` shutdown; CLAP state
uses its native stream, while VST3 state uses a standard `.vstpreset` container.
Both transactions are bounded and saved atomically through a mode-0600
same-directory temporary.

## Run options

The path-only form is an alias for `run`. The options below are available on
`run` and on the path-only form:

| Option | Effect |
|---|---|
| `--plugin-id ID` | Select a descriptor with its stable native CLAP or VST3 ID. |
| `--plugin-index N` | Select the zero-based descriptor index. |
| `--client-name NAME` | Request a JACK client name. |
| `--jack-server NAME` | Connect to a named JACK server. |
| `--no-start-server` | Refuse to start a JACK server when connecting. |
| `--show-gui` | Start the GUI shown; this is the default policy. |
| `--hide-gui` | Create the GUI hidden. |
| `--no-gui` | Disable all GUI hosting and GUI signal actions. |
| `--require-gui` | Fail if the selected GUI policy cannot provide a usable GUI. |
| `--gui-scale SCALE` | Request a finite positive GUI scale. |
| `--icon PATH` | Load a bounded 8-bit RGB P3/P6 PPM for the GUI and tray. |
| `--load-state PATH` | Load CLAP state or a VST3 `.vstpreset` before activation. |
| `--save-state PATH` | Save CLAP state or a VST3 `.vstpreset` after clean signal shutdown. |
| `--pid-file PATH` | Atomically publish the running PID and remove only the owned entry. |
| `-v`, `--verbose` | Emit non-error host diagnostics. |
| `-q`, `--quiet` | Suppress non-error host diagnostics. |
| `-V`, `--version` | Print product, Nim, CLAP SDK, VST3, and JACK ABI versions. |
| `-h`, `--help` | Print generated command help. |

`--plugin-id` and `--plugin-index` are mutually exclusive. The three GUI
policy flags are mutually exclusive; `--no-gui` cannot be combined with
`--require-gui`, `--gui-scale`, or `--icon`. `--save-state` is attempted only
for a clean `SIGINT` or `SIGTERM` shutdown. A plugin that does not expose its
format-native state interface makes a requested load/save fail with status 6.

For a VST3 event bus that advertises one MIDI channel, JACK MIDI channel-voice
messages are routed to that channel (VST3 channel index 0). Buses advertising
multiple channels retain the source channel when it is in range. MIDI system
real-time messages, such as clock, have no supported VST3 input conversion and
can still produce event-drop warnings.

VST3 processors can request tempo and transport context, but the host provides
only a free-running sample clock. Requested fields that are unavailable remain
invalid in each process context; tempo-synced plugin features may not work.

Information commands have these options:

- `list [--json] PLUGIN_PATH` copies descriptors without creating a plugin
  instance.
- `scan [--json] [DIRECTORY ...]` recursively scans explicit roots. Explicit
  roots replace the default roots; no explicit root uses `$HOME/.clap`,
  `/usr/lib/clap`, then each colon-separated `CLAP_PATH` entry.

## Signals and exit statuses

| Signal/status | Meaning |
|---|---|
| `SIGINT`, `SIGTERM` | Request orderly shutdown; requested state is saved. |
| `SIGUSR1` | Show the GUI, or emit the rate-limited disabled-GUI warning. |
| `SIGUSR2` | Hide the GUI, or emit the rate-limited disabled-GUI warning. |
| `0` | Successful information command or clean run shutdown. |
| `1` | Generic platform, reactor, internal, or cleanup failure. |
| `2` | Usage or plugin-selection failure. |
| `3` | CLAP or VST3 load, discovery, initialization, processing, or scan-issue failure. |
| `4` | JACK load, connection, registration, activation, or shutdown failure. |
| `5` | Required GUI failure. |
| `6` | Requested state load/save failure. |

Diagnostics go to standard error. JSON and other requested data go to standard
output. A normal `--quiet` run has no informational output; errors remain
diagnostic output.

## Environment variables

The runtime and delegated platform integrations use these variables:

- `CLAP_PATH`: colon-separated additional roots for `scan` when no explicit
  directories are supplied. Empty entries are ignored. Values are not shell
  expanded and `~` is not interpreted.
- `HOME`: supplies the default `$HOME/.clap` discovery root.
- `DISPLAY`: selects the X11 display. If it is absent or unusable, GUI hosting
  falls back or warns unless `--require-gui` is set.
- `DBUS_SESSION_BUS_ADDRESS`: selects the session bus used by the optional
  StatusNotifierItem tray service.
- `JACK_DEFAULT_SERVER`: is honored by libjack when `--jack-server` is absent.
  The explicit `--jack-server NAME` option takes precedence.

The release and integration tasks use these test-only variables:

- `PLUGINHOST_CLAP_SMOKE_PLUGIN` and optional
  `PLUGINHOST_CLAP_SMOKE_PLUGIN_ID`: independent headless plugin for the live
  smoke test.
- `PLUGINHOST_RELEASE_INSTRUMENT_PLUGIN` /
  `PLUGINHOST_RELEASE_INSTRUMENT_ID`,
  `PLUGINHOST_RELEASE_SECOND_INSTRUMENT_PLUGIN` /
  `PLUGINHOST_RELEASE_SECOND_INSTRUMENT_ID`,
  `PLUGINHOST_RELEASE_EFFECT_PLUGIN` / `PLUGINHOST_RELEASE_EFFECT_ID`, and
  `PLUGINHOST_RELEASE_COMPATIBILITY_PLUGIN` /
  `PLUGINHOST_RELEASE_COMPATIBILITY_ID`: absolute plugin paths and selected
  IDs for `nimble testAcceptance`.
- `PLUGINHOST_TEST_BIN`, `PLUGINHOST_RELEASE_PEER`, and `PLUGINHOST_JACK_PEER`:
  task-generated test executable and independent JACK peers.
- `PLUGINHOST_CLAP_FIXTURE_DIR`, `PLUGINHOST_CLAP_AUDIO_FIXTURE_DIR`, and
  `PLUGINHOST_CLAP_EVENT_FIXTURE_DIR`: task-generated synthetic fixture roots.
  `PLUGINHOST_INTEGRATION_ISOLATED` and `PLUGINHOST_PIPEWIRE_PID` are set by
  the disposable PipeWire runner.
- `PLUGINHOST_VST3_INSTRUMENT_PLUGIN` /
  `PLUGINHOST_VST3_INSTRUMENT_ID` and `PLUGINHOST_VST3_EFFECT_PLUGIN` /
  `PLUGINHOST_VST3_EFFECT_ID`: owner-provided absolute VST3 bundle paths and
  canonical processor CIDs required by `nimble testVst3Public` and `nimble all`.
- `PLUGINHOST_VST3_PUBLIC_FIXTURE_DIR` and `PLUGINHOST_VST3_JACK_PEER`:
  task-generated public VST3 fixture root and JACK peer.

The remaining `PLUGINHOST_*` variables used by `testAbi`, `testHardening`, and
`testGui` are task-internal paths for generated fixtures and helper binaries;
they are not runtime configuration.

## Examples

List and run a VST3 bundle by canonical processor CID:

```sh
pluginhost list --json /usr/lib/vst3/ZamCompX2.vst3
pluginhost --no-gui --no-start-server \
  --plugin-id 2046504473616C633250435A00000000 \
  --pid-file /run/user/$UID/zamcomp-vst3.pid \
  /usr/lib/vst3/ZamCompX2.vst3
kill -TERM "$(cat /run/user/$UID/zamcomp-vst3.pid)"
```

List a bundle before selecting one of its descriptors:

```sh
pluginhost list --json /usr/lib/clap/Surge\ XT.clap
pluginhost --plugin-id org.surge-synth-team.surge-xt /usr/lib/clap/Surge\ XT.clap
```

Run headlessly with a fixed JACK server and PID file:

```sh
pluginhost --no-gui --no-start-server \
  --client-name vital --pid-file /run/user/$UID/vital.pid \
  /usr/lib/clap/Vital.clap
kill -TERM "$(cat /run/user/$UID/vital.pid)"
```

Run a stereo effect and connect its JACK ports with your normal JACK patching
tool:

```sh
pluginhost --no-gui --no-start-server \
  --client-name surge-fx \
  "/usr/lib/clap/Surge XT Effects.clap"
```

Control a GUI-enabled instance through its PID file:

```sh
pluginhost --pid-file /run/user/$UID/vital-gui.pid \
  --client-name vital-gui /usr/lib/clap/Vital.clap
kill -USR2 "$(cat /run/user/$UID/vital-gui.pid)"  # hide
kill -USR1 "$(cat /run/user/$UID/vital-gui.pid)"  # show
kill -TERM "$(cat /run/user/$UID/vital-gui.pid)"

Load and save plugin-owned state. CLAP keeps its native state contract; VST3
uses a `.vstpreset` destination:

```sh
pluginhost --no-gui --load-state ./preset.vstpreset \
  --save-state ./preset.vstpreset /path/to/plugin.vst3
pluginhost --no-gui --load-state ./preset.state \
  --save-state ./preset.state /path/to/plugin.clap
```

Scan an explicit root or the configured roots:

```sh
pluginhost scan --json ~/.clap /usr/lib/clap
CLAP_PATH="$HOME/.local/lib/clap:/opt/clap" pluginhost scan
```

## Troubleshooting

- `JACK` status 4: start the desired JACK server, or pass
  `--jack-server NAME` and `--no-start-server` to select it explicitly.
  `list` and `scan` do not require a JACK server.
- No display or session bus: use `--no-gui` for a headless run. Without
  `--require-gui`, X11 and StatusNotifier failures are warnings and audio
  continues. Native Wayland hosting is not implemented.
- Multiple descriptors: run `list` first, then pass exactly one
  `--plugin-id` or `--plugin-index`; the host never silently chooses among
  multiple descriptors.
- State status 6: check that the state file is readable and that the save
  destination directory is writable. Failed saves leave an existing
  destination unchanged.
- VST3 selection errors identify the VST3 subsystem and require either the
  canonical processor CID (`--plugin-id`) or displayed zero-based index
  (`--plugin-index`) when a bundle exposes more than one processor. State
  files must be standard `.vstpreset` files for VST3; vendor GUI and state
  compatibility still requires an independently installed plugin.
- VST3 processors that require transport/process-context fields beyond
  continuous sample time are rejected rather than given fabricated values.
  Plugin-held host interface references remain rooted until process exit
  after run-loop registrations are removed and the reactor is detached.
- A plugin crash, hostile native code, plugin-created thread, TLS destructor,
  or exit handler can terminate the host or make unloading unsafe. The host
  is not a sandbox and does not provide crash isolation.

## Supported environment and known limitations

| Area | Current status |
|---|---|
| Operating system/architecture | Linux x86_64; aarch64 is not release-validated. |
| Plugin ABI | Native CLAP 1.2.10 and VST3 ABI declarations; independent VST3 vendor compatibility is not guaranteed by synthetic fixtures. |
| JACK | `libjack.so.0`, loaded dynamically; PipeWire-JACK is locally validated. |
| JACK1/JACK2 | Not separately validated in this environment; no release claim. |
| GUI | X11 embedded/floating fallback; optional D-Bus StatusNotifierItem tray. |
| Wayland | Native Wayland is deferred. |
| Isolation | In-process only; third-party plugin code is trusted input. |
| License | MIT; project terms are in `LICENSE`. |

The JACK process callback has a fixed, bounded path: no host allocation,
managed-memory operation, blocking, file/console/network I/O, GUI call, dynamic
library operation, or ownership cleanup. No-event overhead is measured at
48 kHz/64 frames by `nimble testAcceptance`; the report distinguishes host
callback time from plugin DSP time and records xruns.

## Dependency and license status

The project directly uses Nim 2.x and its standard library (MIT),
`argparse` 4.0.2 (MIT), and the vendored CLAP 1.2.10 and VST3 ABI headers
(MIT/upstream terms as documented in `vendor`). GCC or Clang, Binutils,
`pkg-config`, and the JACK/X11/D-Bus development headers are build-time
inputs; their licenses are not bundled into the executable. The runtime uses
distribution-provided JACK (`LGPL-2.1-or-later`), PipeWire (`MIT`), X11
libraries (MIT/X11), and D-Bus (`AFL-2.1 or GPL-2.0-or-later`). On the common
glibc target these C-runtime components are LGPL-2.1-or-later; musl-based
targets use musl's MIT license. Exact system-library/package licenses vary by
distribution and must be verified from the target system before redistributing
a binary. These libraries are not bundled by this repository. The project source
is MIT-licensed under `LICENSE`; CLAP and VST3 plugins are third-party works
with their own licenses and are not distributed here.

## Project documents

- [Product requirements](REQUIREMENTS.md)
- [High-level software design](DESIGN.md)
- [MVP implementation plan](MVP_IMPLEMENTATION_PLAN.md)

## License

The project is licensed under the MIT License; see [`LICENSE`](LICENSE). CLAP
plugins and system dependencies remain third-party works with their own
licenses.
 