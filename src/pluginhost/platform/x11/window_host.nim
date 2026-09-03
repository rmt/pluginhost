## Minimal X11 top-level window owner for the Increment 10A spike.
##
## All operations are control-plane operations and must run on the CLAP/main
## thread. The owner does not expose a raw Display pointer outside this module.

import std/posix

import ../../domain/[errors, result]
import ../../gui/window_host
import ./[api, ffi]

const
  DefaultWindowWidth* = 640'u32
  DefaultWindowHeight* = 480'u32
  MaxWindowDimension* = uint32(high(cuint))

  WmProtocolsName = "WM_PROTOCOLS"
  WmDeleteWindowName = "WM_DELETE_WINDOW"

type
  X11WindowHost* = object
    api: X11Api
    display: ptr XDisplay
    window: XWindow
    wmProtocols: XAtom
    wmDeleteWindow: XAtom
    connectionFd: int32
    stateValue: WindowHostState
    widthValue: uint32
    heightValue: uint32
    titleValue: string

proc `=destroy`*(host: var X11WindowHost) =
  doAssert host.display == nil and host.window == 0 and not host.api.isOpen,
    "an X11 window host must be explicitly closed"
  `=destroy`(host.titleValue)

proc `=copy`*(destination: var X11WindowHost; source: X11WindowHost) {.error:
  "X11WindowHost owns a display and cannot be copied; use move".}
proc `=dup`*(source: X11WindowHost): X11WindowHost {.error:
  "X11WindowHost owns a display and cannot be duplicated; use move".}

proc `=sink`*(destination: var X11WindowHost; source: X11WindowHost) =
  doAssert destination.display == nil and destination.window == 0 and
    not destination.api.isOpen,
    "an X11 window host must be closed before move assignment"
  `=sink`(destination.api, source.api)
  destination.display = source.display
  destination.window = source.window
  destination.wmProtocols = source.wmProtocols
  destination.wmDeleteWindow = source.wmDeleteWindow
  destination.connectionFd = source.connectionFd
  destination.stateValue = source.stateValue
  destination.widthValue = source.widthValue
  destination.heightValue = source.heightValue
  `=sink`(destination.titleValue, source.titleValue)

proc x11Error(message: string; context = ""): HostError =
  hostError(hsGui, hekGui, message, context)

proc validDimension(value: uint32): bool {.inline.} =
  value > 0'u32 and uint64(value) <= uint64(MaxWindowDimension)

proc pathDetail(displayName: string): string =
  if displayName.len == 0: "display=default" else: "display=" & displayName

proc addCleanupDetail(primary: var HostError; cleanup: Result[Unit]) =
  if not cleanup.isOk:
    primary.context.add("; cleanup=" & cleanup.error.message)
    if cleanup.error.context.len > 0:
      primary.context.add(" (" & cleanup.error.context & ")")

proc closeDisplayAndApi(api: var X11Api; display: ptr XDisplay): Result[Unit] =
  var first: HostError
  var failed = false
  if display != nil and api.isOpen:
    if api.functions.closeDisplay(display) != 0:
      first = x11Error("could not close the X11 display")
      failed = true
  let apiClosed = api.close()
  if not apiClosed.isOk:
    if not failed:
      first = apiClosed.error
      failed = true
    else:
      first.context.add("; library=" & apiClosed.error.message)
  if failed:
    return failure[Unit](move(first))
  success()

proc cleanupWindowAndDisplay(api: var X11Api; display: ptr XDisplay;
                             window: XWindow): Result[Unit] =
  var first: HostError
  var failed = false
  if display != nil and window != 0:
    if api.functions.destroyWindow(display, window) == 0:
      first = x11Error("could not destroy the X11 host window")
      failed = true
  let displayClosed = closeDisplayAndApi(api, display)
  if not displayClosed.isOk:
    if not failed:
      first = displayClosed.error
      failed = true
    else:
      first.context.add("; display=" & displayClosed.error.message)
  if failed:
    return failure[Unit](move(first))
  success()

proc cleanupForFailure(api: var X11Api; display: ptr XDisplay;
                       window: XWindow; primary: var HostError) =
  let cleanup = cleanupWindowAndDisplay(api, display, window)
  addCleanupDetail(primary, cleanup)

proc openX11WindowHost*(displayName: string = "";
                        width: uint32 = DefaultWindowWidth;
                        height: uint32 = DefaultWindowHeight;
                        title: string = "pluginhost"): Result[X11WindowHost] =
  if displayName.find('\0') >= 0 or title.find('\0') >= 0:
    return failure[X11WindowHost](x11Error(
      "X11 display name or window title contains a NUL byte"))
  if not validDimension(width) or not validDimension(height):
    return failure[X11WindowHost](x11Error(
      "X11 window dimensions are invalid",
      "width=" & $width & "; height=" & $height))

  var openedApi = openX11Api()
  if not openedApi.isOk:
    return failure[X11WindowHost](move(openedApi.error))
  var api = move(openedApi.value)

  var displayArgument: cstring = nil
  if displayName.len > 0:
    displayArgument = displayName.cstring
  let display = api.functions.openDisplay(displayArgument)
  if display == nil:
    var primary = x11Error("could not open the X11 display", pathDetail(displayName))
    let cleanup = api.close()
    addCleanupDetail(primary, cleanup)
    return failure[X11WindowHost](primary)

  let root = api.functions.defaultRootWindow(display)
  if root == 0:
    var primary = x11Error("X11 returned no default root window",
      pathDetail(displayName))
    cleanupForFailure(api, display, 0, primary)
    return failure[X11WindowHost](primary)

  let window = api.functions.createSimpleWindow(
    display, root, 0, 0, cuint(width), cuint(height), 0, 0, 0)
  if window == 0:
    var primary = x11Error("could not create the X11 host window",
      pathDetail(displayName))
    cleanupForFailure(api, display, 0, primary)
    return failure[X11WindowHost](primary)

  let wmProtocols = api.functions.internAtom(
    display, WmProtocolsName.cstring, 0)
  let wmDeleteWindow = api.functions.internAtom(
    display, WmDeleteWindowName.cstring, 0)
  if wmProtocols == 0 or wmDeleteWindow == 0:
    var primary = x11Error(
      "could not register X11 window-manager protocol atoms",
      pathDetail(displayName))
    cleanupForFailure(api, display, window, primary)
    return failure[X11WindowHost](primary)

  var protocol = wmDeleteWindow
  if api.functions.setWMProtocols(display, window, addr protocol, 1) == 0:
    var primary = x11Error(
      "could not register the X11 WM_DELETE_WINDOW protocol",
      pathDetail(displayName))
    cleanupForFailure(api, display, window, primary)
    return failure[X11WindowHost](primary)

  let selected = api.functions.selectInput(
    display, window, clong(X11ExposureMask or X11StructureNotifyMask))
  if selected == 0:
    var primary = x11Error(
      "could not select X11 window events", pathDetail(displayName))
    cleanupForFailure(api, display, window, primary)
    return failure[X11WindowHost](primary)

  if api.functions.storeName(display, window, title.cstring) == 0:
    var primary = x11Error(
      "could not set the X11 window title", pathDetail(displayName))
    cleanupForFailure(api, display, window, primary)
    return failure[X11WindowHost](primary)

  let connectionFd = api.functions.connectionNumber(display)
  if connectionFd < 0:
    var primary = x11Error(
      "could not obtain the X11 connection descriptor", pathDetail(displayName))
    cleanupForFailure(api, display, window, primary)
    return failure[X11WindowHost](primary)

  if api.functions.flush(display) == 0:
    var primary = x11Error(
      "could not flush the X11 connection", pathDetail(displayName))
    cleanupForFailure(api, display, window, primary)
    return failure[X11WindowHost](primary)

  success(X11WindowHost(
    api: move(api), display: display, window: window,
    wmProtocols: wmProtocols, wmDeleteWindow: wmDeleteWindow,
    connectionFd: int32(connectionFd), stateValue: whHidden,
    widthValue: width, heightValue: height, titleValue: title))

proc state*(host: X11WindowHost): WindowHostState {.inline.} =
  host.stateValue

proc isOpen*(host: X11WindowHost): bool {.inline.} =
  host.display != nil and host.window != 0 and host.api.isOpen

proc fileDescriptor*(host: X11WindowHost): int32 {.inline.} =
  if not host.isOpen:
    return -1'i32
  return host.connectionFd

proc windowId*(host: X11WindowHost): uint64 {.inline.} =
  uint64(host.window)

proc width*(host: X11WindowHost): uint32 {.inline.} =
  host.widthValue

proc height*(host: X11WindowHost): uint32 {.inline.} =
  host.heightValue

proc title*(host: X11WindowHost): string =
  host.titleValue

proc requireOpen(host: X11WindowHost; operation: string): Result[Unit] =
  if not host.isOpen:
    return failure[Unit](x11Error(
      "X11 window operation requires an open window", "operation=" & operation))
  success()

proc requireStatus(status: cint; operation: string): Result[Unit] =
  if status == 0:
    return failure[Unit](x11Error(
      "X11 window operation failed", "operation=" & operation))
  success()

proc show*(host: var X11WindowHost): Result[Unit] =
  var open = host.requireOpen("show")
  if not open.isOk:
    return open
  if host.stateValue == whVisible:
    return success()
  var mapped = requireStatus(
    host.api.functions.mapWindow(host.display, host.window), "map")
  if not mapped.isOk:
    return mapped
  var flushed = requireStatus(host.api.functions.flush(host.display), "flush")
  if not flushed.isOk:
    return flushed
  host.stateValue = whVisible
  success()

proc hide*(host: var X11WindowHost): Result[Unit] =
  var open = host.requireOpen("hide")
  if not open.isOk:
    return open
  if host.stateValue == whHidden:
    return success()
  var unmapped = requireStatus(
    host.api.functions.unmapWindow(host.display, host.window), "unmap")
  if not unmapped.isOk:
    return unmapped
  var flushed = requireStatus(host.api.functions.flush(host.display), "flush")
  if not flushed.isOk:
    return flushed
  host.stateValue = whHidden
  success()

proc resize*(host: var X11WindowHost; width, height: uint32): Result[Unit] =
  var open = host.requireOpen("resize")
  if not open.isOk:
    return open
  if not validDimension(width) or not validDimension(height):
    return failure[Unit](x11Error(
      "X11 window dimensions are invalid",
      "width=" & $width & "; height=" & $height))
  var resized = requireStatus(host.api.functions.resizeWindow(
    host.display, host.window, cuint(width), cuint(height)), "resize")
  if not resized.isOk:
    return resized
  var flushed = requireStatus(host.api.functions.flush(host.display), "flush")
  if not flushed.isOk:
    return flushed
  host.widthValue = width
  host.heightValue = height
  success()

proc isWmDeleteEvent*(event: ptr XEvent; window, wmProtocols,
                    wmDeleteWindow: XAtom): bool {.inline.} =
  if event == nil:
    return false
  let client = cast[ptr XClientMessageEvent](event)
  client.eventType == X11ClientMessage and client.window == window and
    client.messageType == wmProtocols and client.format == 32 and
    client.data[0] == clong(wmDeleteWindow)

proc pollEvent*(host: var X11WindowHost): Result[WindowPollResult] =
  var open = host.requireOpen("poll-event")
  if not open.isOk:
    return failure[WindowPollResult](move(open.error))
  let pending = host.api.functions.pending(host.display)
  if pending < 0:
    return failure[WindowPollResult](x11Error(
      "X11 event query failed", "display=" & $host.connectionFd))
  if pending == 0:
    return success(WindowPollResult(available: false))

  var raw: XEvent
  if host.api.functions.nextEvent(host.display, addr raw) != 0:
    return failure[WindowPollResult](x11Error(
      "could not read the next X11 event", "display=" & $host.connectionFd))
  let eventType = cast[ptr cint](addr raw)[]
  case eventType
  of X11ClientMessage:
    if isWmDeleteEvent(addr raw, host.window, host.wmProtocols,
                       host.wmDeleteWindow):
      host.stateValue = whHidden
      return success(WindowPollResult(
        available: true, event: WindowEvent(kind: wekClose)))
  of X11ConfigureNotify:
    let configure = cast[ptr XConfigureEvent](addr raw)
    if configure.window == host.window:
      if configure.width > 0 and configure.height > 0:
        host.widthValue = uint32(configure.width)
        host.heightValue = uint32(configure.height)
      return success(WindowPollResult(available: true, event: WindowEvent(
        kind: wekConfigure, width: host.widthValue, height: host.heightValue)))
  of X11MapNotify:
    host.stateValue = whVisible
    return success(WindowPollResult(available: true, event: WindowEvent(kind: wekMap)))
  of X11UnmapNotify:
    host.stateValue = whHidden
    return success(WindowPollResult(available: true, event: WindowEvent(kind: wekUnmap)))
  of X11DestroyNotify:
    host.window = 0
    host.stateValue = whClosed
    return success(WindowPollResult(available: true, event: WindowEvent(kind: wekClose)))
  else:
    discard
  success(WindowPollResult(available: true, event: WindowEvent(kind: wekOther)))

proc close*(host: var X11WindowHost): Result[Unit] =
  if host.display == nil and host.window == 0:
    return host.api.close()

  var first: HostError
  var failed = false
  if host.display != nil:
    let cleaned = cleanupWindowAndDisplay(host.api, host.display, host.window)
    if not cleaned.isOk:
      first = cleaned.error
      failed = true
  else:
    let apiClosed = host.api.close()
    if not apiClosed.isOk:
      first = apiClosed.error
      failed = true
  host.window = 0
  host.display = nil
  host.connectionFd = -1
  host.stateValue = whClosed
  if failed:
    return failure[Unit](move(first))
  success()
