# ADR 0008: CLAP GUI controller over the X11 window-host adapter

- **Status:** Proposed for Increment 10B review
- **Date:** 2025-02-14

## Context

The 10A spike owns a dynamically loaded Xlib display, a host window, WM-delete
classification, and an X connection FD. It deliberately does not call a CLAP
GUI extension. Increment 10B needs to connect that surface to one initialized
CLAP instance without allowing GUI work into the JACK process callback or a
foreign CLAP callback.

The stable CLAP GUI contract supports X11 embedding and floating windows. The
initial host must remain useful on headless systems and must not acquire an
ELF dependency on Xlib merely by being built.

## Decision

Add a main-thread-only `GuiController` with the following ownership and policy:

1. `HostSession` creates it only when GUI hosting is enabled. The host bridge
   advertises `clap.gui` only in that mode; `--no-gui` therefore produces a
   genuinely headless CLAP host view.
2. The controller negotiates embedded X11 first (`is_floating = false`) and
   then floating X11. Native Wayland is deferred.
3. A narrow `GuiPluginClient` adapts checked `ClapInstance` GUI calls, and a
   narrow `WindowHostBackend` adapts the concrete X11 owner. Unit tests can
   replace both with fakes.
4. Creation follows the checked sequence: create, optional scale, query resize
   support/hints, get the initial size, resize the host surface, then set the
   X11 parent; floating mode uses a transient host surface and the suggested
   title. Show/hide and destruction are explicit and idempotent at the
   controller boundary.
5. The X connection FD is registered with `MainReactor`. Window events are
   drained with a fixed per-turn bound. WM close is a user hide request: the
   controller applies the same plugin-hide/host-unmap path as `SIGUSR2` without
   destroying the CLAP GUI, so a later show reuses the same plugin GUI object. For
   embedded GUIs, a plugin `hide()` result of false is tolerated because unmapping
   the host parent is authoritative. Actual X11 surface destruction releases the
   host surface and calls exactly one `clap_plugin_gui.destroy()` so a later show
   can recreate it. `clap_host_gui.closed(true)` uses the same destroy path.
6. Host GUI callbacks publish only bounded atomic requests. The main loop drains
   and applies them after plugin/timer/FD dispatch; callbacks never call Xlib or
   CLAP lifecycle methods directly.
7. GUI failure is a warning and headless continuation unless `--require-gui`
   is set. GUI state never changes JACK activation or audio processing.

## Consequences

- The public run path now attempts the default GUI policy after successful
  audio startup, while `--hide-gui` creates a hidden GUI and `--no-gui` does
  not create or advertise one.
- `SIGUSR1` and `SIGUSR2` operate on the controller when enabled and retain the
  existing rate-limited unavailable warning when disabled. Window events are
  applied before same-turn GUI signal actions, so WM close followed by `SIGUSR1`
  restores visibility without unnecessary CLAP GUI recreation.
- X11 remains dynamically loaded and all Xlib/CLAP GUI operations remain on the
  process's CLAP main thread.
- Resize constraints are validated at the CLAP boundary and plugin-requested
  resize is applied by the host surface. Full native Wayland support and richer
  window-manager size-hint integration remain outside this increment.
- The adapter boundary adds test seams but does not add a GUI toolkit or a new
  runtime dependency.

## Verification

The review unit includes raw CLAP ABI declarations, host callback/coalescing
unit tests, fake-client/fake-window controller tests, an independently compiled
CLAP GUI fixture, and an Xvfb test that negotiates that fixture through the real
dynamically loaded X11 adapter. `testGui` also verifies the resulting test
binary has no eager `libX11` dependency.
