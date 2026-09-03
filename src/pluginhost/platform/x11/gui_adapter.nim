## GUI capability adapter for the concrete X11 window owner.

import ../../domain/[errors, result]
import ../../gui/[window_backend, window_host]
import ./window_host as x11_window_host

type
  X11WindowBackend* = ref object of WindowHostBackend
    host: x11_window_host.X11WindowHost

proc newX11WindowBackend*(): WindowHostBackend =
  var backend: X11WindowBackend
  new(backend)
  backend

method open*(backend: X11WindowBackend; title: string;
             width, height: uint32): Result[Unit] {.raises: [].} =
  if backend.host.isOpen:
    return failure[Unit](hostError(
      hsGui, hekGui, "X11 window backend is already open"))
  var opened = x11_window_host.openX11WindowHost(
    width = width, height = height, title = title)
  if not opened.isOk:
    return failure[Unit](move(opened.error))
  backend.host = move(opened.value)
  success()

method close*(backend: X11WindowBackend): Result[Unit] {.raises: [].} =
  backend.host.close()

method show*(backend: X11WindowBackend): Result[Unit] {.raises: [].} =
  backend.host.show()

method hide*(backend: X11WindowBackend): Result[Unit] {.raises: [].} =
  backend.host.hide()

method resize*(backend: X11WindowBackend; width, height: uint32): Result[Unit] {.
    raises: [].} =
  backend.host.resize(width, height)

method pollEvent*(backend: X11WindowBackend): Result[WindowPollResult] {.
    raises: [].} =
  backend.host.pollEvent()

method fileDescriptor*(backend: X11WindowBackend): int32 {.raises: [].} =
  backend.host.fileDescriptor

method state*(backend: X11WindowBackend): WindowHostState {.raises: [].} =
  backend.host.state

method handle*(backend: X11WindowBackend): GuiWindowHandle {.raises: [].} =
  GuiWindowHandle(api: gwaX11, id: backend.host.windowId)

method width*(backend: X11WindowBackend): uint32 {.raises: [].} =
  backend.host.width

method height*(backend: X11WindowBackend): uint32 {.raises: [].} =
  backend.host.height
