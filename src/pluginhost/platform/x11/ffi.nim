## Minimal declaration-only Xlib ABI used by the 10A window-host spike.
##
## Xlib is loaded explicitly by api.nim. No X11 symbol is linked eagerly into
## information commands or the headless runtime.

when not defined(linux):
  {.error: "pluginhost/platform/x11 is available only on Linux".}

const
  X11Library* = "libX11.so.6"
  X11ExposureMask* = 1'i64 shl 15
  X11StructureNotifyMask* = 1'i64 shl 17
  X11DestroyNotify* = 17
  X11UnmapNotify* = 18
  X11MapNotify* = 19
  X11ConfigureNotify* = 22
  X11ClientMessage* = 33


type
  XDisplay* = object
  XWindow* = culong
  XAtom* = culong

  ## XEvent is a union whose largest member is long[24] on the supported
  ## Linux ABIs. Keeping it as storage avoids importing Xlib's private structs.
  XEvent* = array[24, clong]

  XConfigureEvent* {.bycopy.} = object
    eventType*: cint
    serial*: culong
    sendEvent*: cint
    display*: ptr XDisplay
    eventWindow*: XWindow
    window*: XWindow
    x*: cint
    y*: cint
    width*: cint
    height*: cint
    borderWidth*: cint
    above*: XWindow
    overrideRedirect*: cint

  XClientMessageEvent* {.bycopy.} = object
    eventType*: cint
    serial*: culong
    sendEvent*: cint
    display*: ptr XDisplay
    window*: XWindow
    messageType*: XAtom
    format*: cint
    data*: array[5, clong]

  X11OpenDisplayProc* = proc(displayName: cstring): ptr XDisplay {.
    cdecl, gcsafe, raises: [].}
  X11CloseDisplayProc* = proc(display: ptr XDisplay): cint {.
    cdecl, gcsafe, raises: [].}
  X11DefaultRootWindowProc* = proc(display: ptr XDisplay): XWindow {.
    cdecl, gcsafe, raises: [].}
  X11CreateSimpleWindowProc* = proc(display: ptr XDisplay;
      parent: XWindow; x, y: cint; width, height, borderWidth: cuint;
      border, background: culong): XWindow {.cdecl, gcsafe, raises: [].}
  X11DestroyWindowProc* = proc(display: ptr XDisplay; window: XWindow): cint {.
    cdecl, gcsafe, raises: [].}
  X11SelectInputProc* = proc(display: ptr XDisplay; window: XWindow;
      eventMask: clong): cint {.cdecl, gcsafe, raises: [].}
  X11MapWindowProc* = proc(display: ptr XDisplay; window: XWindow): cint {.
    cdecl, gcsafe, raises: [].}
  X11UnmapWindowProc* = proc(display: ptr XDisplay; window: XWindow): cint {.
    cdecl, gcsafe, raises: [].}
  X11ResizeWindowProc* = proc(display: ptr XDisplay; window: XWindow;
      width, height: cuint): cint {.cdecl, gcsafe, raises: [].}
  X11StoreNameProc* = proc(display: ptr XDisplay; window: XWindow;
      name: cstring): cint {.cdecl, gcsafe, raises: [].}
  X11InternAtomProc* = proc(display: ptr XDisplay; name: cstring;
      onlyIfExists: cint): XAtom {.cdecl, gcsafe, raises: [].}
  X11SetWMProtocolsProc* = proc(display: ptr XDisplay; window: XWindow;
      protocols: ptr XAtom; count: cint): cint {.cdecl, gcsafe, raises: [].}
  X11ConnectionNumberProc* = proc(display: ptr XDisplay): cint {.
    cdecl, gcsafe, raises: [].}
  X11FlushProc* = proc(display: ptr XDisplay): cint {.
    cdecl, gcsafe, raises: [].}
  X11PendingProc* = proc(display: ptr XDisplay): cint {.
    cdecl, gcsafe, raises: [].}
  X11NextEventProc* = proc(display: ptr XDisplay; event: ptr XEvent): cint {.
    cdecl, gcsafe, raises: [].}

  X11Functions* = object
    openDisplay*: X11OpenDisplayProc
    closeDisplay*: X11CloseDisplayProc
    defaultRootWindow*: X11DefaultRootWindowProc
    createSimpleWindow*: X11CreateSimpleWindowProc
    destroyWindow*: X11DestroyWindowProc
    selectInput*: X11SelectInputProc
    mapWindow*: X11MapWindowProc
    unmapWindow*: X11UnmapWindowProc
    resizeWindow*: X11ResizeWindowProc
    storeName*: X11StoreNameProc
    internAtom*: X11InternAtomProc
    setWMProtocols*: X11SetWMProtocolsProc
    connectionNumber*: X11ConnectionNumberProc
    flush*: X11FlushProc
    pending*: X11PendingProc
    nextEvent*: X11NextEventProc
