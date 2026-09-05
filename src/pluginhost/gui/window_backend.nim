## Control-plane capability for a host-owned native window.
##
## The GUI controller depends on this narrow boundary rather than importing a
## platform window API. Implementations must be explicitly opened and closed.

import ../domain/[errors, result]
import ./[icon, window_host]
type
  WindowHostBackend* = ref object of RootObj

  WindowHostFactory* = proc(): WindowHostBackend

proc windowBackendError(message: string): HostError =
  hostError(hsGui, hekGui, message)

method open*(backend: WindowHostBackend; title: string;
             width, height: uint32): Result[Unit] {.base, raises: [].} =
  discard backend
  discard title
  discard width
  discard height
  failure[Unit](windowBackendError("window backend does not support opening"))


method setIcon*(backend: WindowHostBackend; icon: GuiIcon): Result[Unit] {.
    base, raises: [].} =
  discard backend
  discard icon
  failure[Unit](windowBackendError("window backend does not support icons"))
method close*(backend: WindowHostBackend): Result[Unit] {.base, raises: [].} =
  discard backend
  success()

method show*(backend: WindowHostBackend): Result[Unit] {.base, raises: [].} =
  discard backend
  failure[Unit](windowBackendError("window backend does not support showing"))

method hide*(backend: WindowHostBackend): Result[Unit] {.base, raises: [].} =
  discard backend
  failure[Unit](windowBackendError("window backend does not support hiding"))

method resize*(backend: WindowHostBackend; width, height: uint32): Result[Unit] {.
    base, raises: [].} =
  discard backend
  discard width
  discard height
  failure[Unit](windowBackendError("window backend does not support resizing"))

method pollEvent*(backend: WindowHostBackend): Result[WindowPollResult] {.
    base, raises: [].} =
  discard backend
  failure[WindowPollResult](windowBackendError(
    "window backend does not support event polling"))

method fileDescriptor*(backend: WindowHostBackend): int32 {.base, raises: [].} =
  discard backend
  -1'i32

method state*(backend: WindowHostBackend): WindowHostState {.base, raises: [].} =
  discard backend
  whClosed

method handle*(backend: WindowHostBackend): GuiWindowHandle {.base, raises: [].} =
  discard backend
  GuiWindowHandle(api: gwaX11, id: 0'u64)

method width*(backend: WindowHostBackend): uint32 {.base, raises: [].} =
  discard backend
  0'u32

method height*(backend: WindowHostBackend): uint32 {.base, raises: [].} =
  discard backend
  0'u32
