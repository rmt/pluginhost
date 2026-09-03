# ADR 0007: Dynamically loaded Xlib window-host spike

- **Status:** Accepted for Increment 10A
- **Date:** 2026-09-02

## Context

Increment 10 needs an X11/XEmbed host surface before CLAP GUI negotiation is
added. The host must remain usable headlessly and must not acquire an eager
`libX11` dependency merely because the executable contains GUI-capable code.
The existing main reactor already owns event-driven Linux FD readiness, and the
JACK process callback must remain entirely independent of GUI operations.

The 10A review unit is deliberately narrower than CLAP GUI support: it proves
that a host-owned X11 window can be created, shown, hidden, resized, monitored,
and explicitly destroyed on the existing main thread. It does not create a
plugin GUI or claim that a CLAP GUI has been embedded.

## Decision

Use a handwritten, declaration-only Xlib boundary and load `libX11.so.6`
through the existing checked dynamic-library owner:

- Resolve only the Xlib procedures needed for display/window lifecycle, WM
  protocol registration, event polling, and the connection descriptor.
- Keep `Display*`, the X window ID, WM atoms, the title, and the connection FD
  in one move-only `X11WindowHost` owner. Successful construction must be
  followed by explicit `close`; destructors assert that foreign resources are
  already released.
- Create a minimal top-level X11 window under the default root window. Its XID
  is the future parent surface for the embedded CLAP GUI; actual XEmbed
  negotiation and child-plugin parenting are Increment 10B responsibilities.
- Register `WM_DELETE_WINDOW`, select exposure/structure events, and translate
  client-close, configure, map, unmap, and destroy notifications to the
  backend-neutral `WindowEvent` values.
- Expose the X connection FD for registration with `MainReactor`. Xlib calls
  and event draining stay on the existing CLAP/main thread; reactor readiness
  is control-plane work and never enters JACK processing.
- Do not call `XInitThreads`; no Xlib call is made from a foreign or real-time
  thread.
- Verify the event storage and offsets against installed `<X11/Xlib.h>` types,
  and exercise the lifecycle under Xvfb with a dedicated `nimble testGui` task.

## Alternatives considered

- **XCB:** rejected for 10A because the required surface is small, Xlib is
  already available on the target Linux/XWayland environments, and Xlib avoids
  introducing a second connection/event ownership model before CLAP GUI policy
  exists. Reconsider if 10B requires XCB-only facilities or Xlib's threading
  model becomes a constraint.
- **Eager link to `libX11`:** rejected because headless and information
  commands must not acquire GUI runtime dependencies, and dynamic loading
  keeps the failure typed and local to GUI creation.
- **A GUI toolkit:** rejected because it adds window ownership, event-loop,
  deployment, and licensing surface unrelated to this spike.
- **Implement CLAP GUI at the same time:** rejected by the review-size rule;
  CLAP call ordering, reentrancy, resize negotiation, and recreation need a
  separate 10B review.

## Consequences

The host can now prove a real X11 display/window and reactor-FD lifecycle while
headless product paths remain free of an ELF X11 dependency. Xlib resource
cleanup and event ABI assumptions are explicit and testable. The spike is not
yet a user-visible GUI feature: no CLAP GUI extension is advertised, no plugin
window is parented, no Wayland adapter exists, and no GUI CLI policy changes.
The X11 display connection is single-thread-owned by the main thread, so future
10B integration must preserve that ownership while routing plugin requests
through the existing main-thread service boundary.
