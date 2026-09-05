# ADR 0009: StatusNotifierItem tray icon over session D-Bus

- **Status:** Proposed for Increment 10C review
- **Date:** 2026-09-05

## Context

The host's CLAP GUI is controlled on the main thread by `GuiController`, and its
X11 display is integrated with `MainReactor`. Users need a discoverable way to
show or hide that GUI without sending a signal or finding the window.

The legacy freedesktop XEmbed system-tray protocol requires an X11 tray-manager
selection. That assumption is not reliable under Wayland/XWayland: a compositor
may provide XWayland without an XEmbed system-tray manager. Modern Linux panels
instead commonly consume the freedesktop StatusNotifierItem protocol over the
session D-Bus.

The host must retain a small dependency surface, avoid GUI toolkits, keep
headless commands independent of desktop libraries, and keep all tray work off
the JACK process thread. The pinned CLAP 1.2.10 headers do not define a standard
plugin-icon field or icon extension, so the host cannot claim to extract an icon
from an ordinary CLAP plugin.

## Decision

Use an optional StatusNotifierItem backend over a separately owned,
dynamically loaded `libdbus-1` session-bus connection. Remove the legacy XEmbed
system-tray implementation. XEmbed remains only where it is part of the CLAP
X11 plugin-GUI embedding contract.

1. `TrayIconBackend` remains a backend-neutral, control-plane-only seam. It
   exposes one event descriptor and bounded activation/closure events to
   application code.
2. `TrayController` owns one backend, registers its descriptor with
   `MainReactor`, drains a bounded number of events per turn, and reports
   primary activation to `HostSession`.
3. `DbusTrayIcon` owns one private session connection, requests a deterministic
   per-process `org.freedesktop.StatusNotifierItem-*` name, exports
   `/StatusNotifierItem`, and registers the service with
   `org.freedesktop.StatusNotifierWatcher`, falling back to the deployed KDE
   compatibility name/interface `org.kde.StatusNotifierWatcher`.
4. The backend handles `Activate`, `Properties.Get`, `Properties.GetAll`, and
   `Introspect` on the main/reactor thread. It publishes `IconPixmap` as a
   bounded ARGB32 image and accepts both freedesktop and KDE item interface
   spellings using the deployed standard `a(iiay)` pixmap signature. It uses
   a generic `ApplicationStatus` item without a menu or unsupported
   desktop-specific behavior.
5. `HostSession` starts the tray only after GUI hosting succeeds. A primary
   activation calls `GuiController.toggle()` on the CLAP/main reactor thread;
   it never changes JACK activation or enters the process callback.
6. `--icon` accepts only the bounded P3/P6 8-bit RGB PPM format implemented by
   `icon_loader.nim`. The validated image is applied to both the X11 window's
   `_NET_WM_ICON` property and SNI `IconPixmap`. Without `--icon`, the host
   uses a deterministic generic fallback. No standard CLAP plugin-icon path is
   advertised because CLAP 1.2.10 provides none.
7. Missing session bus/watcher, connection failure, or ordinary tray event
   failure is non-fatal: the host emits one warning and continues with its
   existing GUI, signal, and audio policy. `--no-gui` creates neither GUI nor
   tray.
8. Tray cleanup removes the reactor registration before closing the D-Bus
   connection, and occurs before GUI, CLAP, JACK, and reactor teardown.

## Alternatives considered

- **Legacy XEmbed system tray:** rejected for the tray because XWayland does not
  guarantee an XEmbed manager. It remains required for the CLAP X11 embedded
  GUI path.
- **GTK/Qt/libappindicator:** rejected because a toolkit adds substantial
  runtime dependencies and an unrelated event/lifecycle owner.
- **Direct desktop-specific Wayland protocol:** rejected because there is no
  common native Wayland tray protocol and the stable CLAP GUI contract provides
  no native embedded Wayland path.
- **Signals only:** rejected because signals do not provide a discoverable
  desktop affordance or satisfy click-to-toggle behavior.
- **Plugin-provided icon extraction:** unavailable in the pinned standard CLAP
  ABI. Host-supplied bounded PPM plus a generic fallback is explicit rather
  than relying on an undocumented extension.

## Consequences

- Wayland sessions with a StatusNotifierWatcher, including deployments that
  expose only the KDE-compatible service name, can expose a clickable tray
  item even when XWayland has no XEmbed tray manager.
- The host adds a handwritten libdbus ABI and dynamic-loader boundary, with no
  eager `libdbus-1` dependency for `list`, `scan`, or headless `run`.
- Tray availability remains desktop-dependent; systems without a session bus or
  watcher receive a warning and retain normal GUI operation.
- D-Bus dispatch is bounded and main-thread-only. The backend uses one reactor
  descriptor for the private connection; it does not implement arbitrary
  desktop menus or full watch-function integration.
- The icon contract is deliberately small: 64×64 maximum dimensions, 4 MiB
  maximum file size, 8-bit RGB PPM input, ARGB32 output, and a deterministic
  generic fallback. Native CLAP plugin icons remain unavailable until a
  documented standard extension exists.

## Verification

- D-Bus ABI tests validate `DBusError`, `DBusMessageIter`,
  `DBusObjectPathVTable`, all dynamically resolved procedure aliases, and C
  function signatures against installed libdbus headers.
- X11 ABI tests validate the retained window/event declarations and
  `XChangeProperty`; the legacy tray-only declarations and fixtures are absent.
- Unit tests cover icon bounds/PPM parsing, window/tray icon forwarding,
  controller registration, activation, bounded non-activation handling,
  unavailable backends, and idempotent cleanup.
- `nimble testGui` compiles an independent StatusNotifierWatcher fixture in
  both freedesktop and KDE compatibility modes and verifies service
  registration, `Properties.GetAll` including `IconPixmap`, and `Activate`
  delivery under disposable D-Bus sessions. The X11 window test verifies
  `_NET_WM_ICON` under Xvfb.
- `nimble test` verifies the public CLI accepts `--icon` and rejects it with
  `--no-gui`.
