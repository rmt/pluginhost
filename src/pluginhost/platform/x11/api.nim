## Checked, move-only loading of the narrow Xlib procedure table.

import ../../domain/[errors, result]
import ../linux/dynlib
import ./ffi

type
  X11Api* = object
    library: DynamicLibrary
    functions*: X11Functions

proc `=destroy`*(api: var X11Api) =
  `=destroy`(api.library)

proc `=copy`*(destination: var X11Api; source: X11Api) {.error:
  "X11Api owns a dynamic library and cannot be copied; use move".}
proc `=dup`*(source: X11Api): X11Api {.error:
  "X11Api owns a dynamic library and cannot be duplicated; use move".}

proc `=sink`*(destination: var X11Api; source: X11Api) =
  doAssert not destination.library.isOpen,
    "an open X11Api must be closed before move assignment"
  `=sink`(destination.library, source.library)
  destination.functions = source.functions

proc isOpen*(api: X11Api): bool {.inline.} =
  api.library.isOpen

proc libraryPath*(api: X11Api): string {.inline.} =
  api.library.libraryPath

proc x11ApiError(kind: HostErrorKind; message, path: string;
                 platformError: HostError): HostError =
  var context = "library=" & path
  if platformError.context.len > 0:
    context.add("; " & platformError.context)
  hostError(hsGui, kind, message, context)

proc close*(api: var X11Api): Result[Unit] =
  if not api.library.isOpen:
    api.functions = default(X11Functions)
    return success()
  let closed = api.library.close()
  if not closed.isOk:
    return failure[Unit](x11ApiError(
      hekGui, "could not unload the X11 client library", api.library.libraryPath,
      closed.error))
  api.functions = default(X11Functions)
  success()

proc rollback(api: var X11Api; primary: HostError): HostError =
  let cleanup = api.close()
  if cleanup.isOk:
    return primary
  result = cleanup.error
  result.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    result.context.add(" (" & primary.context & ")")

proc openX11Api*(path = X11Library): Result[X11Api] =
  var opened = openDynamicLibrary(path)
  if not opened.isOk:
    return failure[X11Api](x11ApiError(
      hekGui, "could not load the X11 client library", path, opened.error))

  var api = X11Api(library: move(opened.value))

  template resolveRequired(field: untyped; procedureType: typedesc;
                           symbol: static string) =
    block:
      let resolved = resolveSymbol[procedureType](api.library, symbol)
      if not resolved.isOk:
        let primary = x11ApiError(
          hekGui, "required X11 symbol is unavailable", path, resolved.error)
        return failure[X11Api](api.rollback(primary))
      api.functions.field = resolved.value

  resolveRequired(openDisplay, X11OpenDisplayProc, "XOpenDisplay")
  resolveRequired(closeDisplay, X11CloseDisplayProc, "XCloseDisplay")
  resolveRequired(defaultRootWindow, X11DefaultRootWindowProc,
    "XDefaultRootWindow")
  resolveRequired(createSimpleWindow, X11CreateSimpleWindowProc,
    "XCreateSimpleWindow")
  resolveRequired(destroyWindow, X11DestroyWindowProc, "XDestroyWindow")
  resolveRequired(selectInput, X11SelectInputProc, "XSelectInput")
  resolveRequired(mapWindow, X11MapWindowProc, "XMapWindow")
  resolveRequired(unmapWindow, X11UnmapWindowProc, "XUnmapWindow")
  resolveRequired(resizeWindow, X11ResizeWindowProc, "XResizeWindow")
  resolveRequired(storeName, X11StoreNameProc, "XStoreName")
  resolveRequired(changeProperty, X11ChangePropertyProc, "XChangeProperty")
  resolveRequired(internAtom, X11InternAtomProc, "XInternAtom")
  resolveRequired(setWMProtocols, X11SetWMProtocolsProc, "XSetWMProtocols")
  resolveRequired(connectionNumber, X11ConnectionNumberProc,
    "XConnectionNumber")
  resolveRequired(flush, X11FlushProc, "XFlush")
  resolveRequired(pending, X11PendingProc, "XPending")
  resolveRequired(nextEvent, X11NextEventProc, "XNextEvent")

  success(move(api))
