import std/[options, posix, unittest]

import pluginhost/app/main_reactor
import pluginhost/clap/host_bridge
import pluginhost/domain/[reactor, result]
import pluginhost/gui/[controller, plugin_client, window_backend, window_host]
import pluginhost/platform/linux/reactor as linux_reactor

type
  FakeGuiClient = ref object of GuiPluginClient
    embedded: bool
    floating: bool
    resizeable: bool
    sizeValue: GuiSize
    createCount: int
    destroyCount: int
    parentCount: int
    transientCount: int
    showCount: int
    hideCount: int
    setSizeCount: int
    adjustSizeCount: int
    adjustReturns: bool
    adjustedSize: GuiSize
    scaleCount: int
    rejectHide: bool

  FakeWindowBackend = ref object of WindowHostBackend
    readFd: cint
    writeFd: cint
    stateValue: WindowHostState
    widthValue: uint32
    heightValue: uint32
    resizeCount: int
    pendingEvent: WindowPollResult
    hasEvent: bool

proc newFakeGui(embedded = true; floating = true): FakeGuiClient =
  new(result)
  result.embedded = embedded
  result.floating = floating
  result.resizeable = true
  result.sizeValue = GuiSize(width: 400, height: 300)

method available*(client: FakeGuiClient): bool {.raises: [].} =
  true

method isApiSupported*(client: FakeGuiClient; api: GuiWindowApi;
                       floating: bool): bool {.raises: [].} =
  discard api
  if floating: client.floating else: client.embedded

method create*(client: FakeGuiClient; api: GuiWindowApi;
               floating: bool): Result[bool] {.raises: [].} =
  discard api
  discard floating
  inc client.createCount
  success(true)

method destroy*(client: FakeGuiClient): Result[Unit] {.raises: [].} =
  inc client.destroyCount
  success()

method setScale*(client: FakeGuiClient; scale: float64): Result[bool] {.
    raises: [].} =
  discard scale
  inc client.scaleCount
  success(true)

method getSize*(client: FakeGuiClient): Result[GuiSize] {.raises: [].} =
  success(client.sizeValue)

method canResize*(client: FakeGuiClient): Result[bool] {.raises: [].} =
  success(client.resizeable)

method getResizeHints*(client: FakeGuiClient;
                       hints: var GuiResizeHints): Result[bool] {.
    raises: [].} =
  hints = GuiResizeHints(canResizeHorizontally: true,
                         canResizeVertically: true)
  success(true)

method adjustSize*(client: FakeGuiClient; size: var GuiSize): Result[bool] {.
    raises: [].} =
  inc client.adjustSizeCount
  if client.adjustedSize.width > 0'u32 and client.adjustedSize.height > 0'u32:
    size = client.adjustedSize
  success(client.adjustReturns)

method setSize*(client: FakeGuiClient; size: GuiSize): Result[bool] {.
    raises: [].} =
  client.sizeValue = size
  inc client.setSizeCount
  success(true)

method setParent*(client: FakeGuiClient; handle: GuiWindowHandle): Result[bool] {.
    raises: [].} =
  discard handle
  inc client.parentCount
  success(true)

method setTransient*(client: FakeGuiClient;
                     handle: GuiWindowHandle): Result[bool] {.raises: [].} =
  discard handle
  inc client.transientCount
  success(true)

method suggestTitle*(client: FakeGuiClient; title: string): Result[Unit] {.
    raises: [].} =
  discard title
  success()

method show*(client: FakeGuiClient): Result[bool] {.raises: [].} =
  inc client.showCount
  success(true)

method hide*(client: FakeGuiClient): Result[bool] {.raises: [].} =
  inc client.hideCount
  if client.rejectHide:
    return success(false)
  success(true)

proc newFakeWindow(): FakeWindowBackend =
  var descriptors: array[2, cint]
  doAssert pipe(descriptors) == 0
  new(result)
  result.readFd = descriptors[0]
  result.writeFd = descriptors[1]
  result.stateValue = whClosed

method open*(backend: FakeWindowBackend; title: string;
             width, height: uint32): Result[Unit] {.raises: [].} =
  discard title
  backend.widthValue = width
  backend.heightValue = height
  backend.stateValue = whHidden
  success()

method close*(backend: FakeWindowBackend): Result[Unit] {.raises: [].} =
  if backend.readFd >= 0:
    discard posix.close(backend.readFd)
    backend.readFd = -1
  if backend.writeFd >= 0:
    discard posix.close(backend.writeFd)
    backend.writeFd = -1
  backend.stateValue = whClosed
  success()

method show*(backend: FakeWindowBackend): Result[Unit] {.raises: [].} =
  backend.stateValue = whVisible
  success()

method hide*(backend: FakeWindowBackend): Result[Unit] {.raises: [].} =
  backend.stateValue = whHidden
  success()

method resize*(backend: FakeWindowBackend; width, height: uint32): Result[Unit] {.
    raises: [].} =
  backend.widthValue = width
  backend.heightValue = height
  inc backend.resizeCount
  success()

method pollEvent*(backend: FakeWindowBackend): Result[WindowPollResult] {.
    raises: [].} =
  if backend.hasEvent:
    backend.hasEvent = false
    return success(backend.pendingEvent)
  success(WindowPollResult(available: false))

method fileDescriptor*(backend: FakeWindowBackend): int32 {.raises: [].} =
  int32(backend.readFd)

method state*(backend: FakeWindowBackend): WindowHostState {.raises: [].} =
  backend.stateValue

method handle*(backend: FakeWindowBackend): GuiWindowHandle {.raises: [].} =
  discard backend
  GuiWindowHandle(api: gwaX11, id: 42)

proc dispatchWindowEvent(reactor: var MainReactor; controller: GuiController;
                         backend: FakeWindowBackend; event: WindowEvent) =
  backend.hasEvent = true
  backend.pendingEvent = WindowPollResult(available: true, event: event)
  var byte = 'x'
  check posix.write(backend.writeFd, addr byte, 1) == 1
  var events = reactor.wait(monotonicNanos(50_000_000))
  require events.isOk
  check controller.handleWindowEvents(events.value).isOk

proc openTestReactor(): MainReactor =
  var driver = linux_reactor.openLinuxReactorDriver()
  doAssert driver.isOk
  var opened = initMainReactor(driver.value)
  doAssert opened.isOk
  move(opened.value)

suite "GUI controller policy and lifecycle":
  test "embedded GUI is created, shown, resized, hidden, and explicitly closed":
    var reactor = openTestReactor()
    var plugin = newFakeGui()
    var produced: FakeWindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newFakeWindow()
      produced
    var controller = newGuiController(
      plugin, addr reactor, factory, "test", some(1.25))
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    check controller.start(true).isOk
    check controller.state == gcsVisible
    check controller.mode == gmEmbedded
    check controller.isCreated
    check plugin.createCount == 1
    check plugin.parentCount == 1
    check plugin.scaleCount == 1
    check produced.resizeCount == 1
    check plugin.showCount == 1

    var resize = ClapGuiRequests(resize: true, width: 720, height: 510)
    check controller.handlePluginRequests(resize).isOk
    check plugin.setSizeCount == 0
    check controller.size == GuiSize(width: 720, height: 510)
    var pluginClosed = ClapGuiRequests(closed: true)
    check controller.handlePluginRequests(pluginClosed).isOk
    check controller.state == gcsHidden
    check plugin.destroyCount == 0
    check controller.show().isOk

    check controller.hide().isOk
    check controller.state == gcsHidden
    check plugin.hideCount == 1
    check controller.close().isOk
    check plugin.destroyCount == 1
    check controller.state == gcsClosed

  test "WM close uses hide and restores even when embedded hide is rejected":
    var reactor = openTestReactor()
    var plugin = newFakeGui()
    plugin.rejectHide = true

    var produced: FakeWindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newFakeWindow()
      produced
    var controller = newGuiController(plugin, addr reactor, factory, "test")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    check controller.start(true).isOk
    check controller.state == gcsVisible
    dispatchWindowEvent(reactor, controller, produced,
      WindowEvent(kind: wekClose))
    check controller.state == gcsHidden
    check produced.state == whHidden
    check plugin.hideCount == 1
    check plugin.destroyCount == 0
    check plugin.createCount == 1

    check controller.show().isOk
    check controller.state == gcsVisible
    check plugin.showCount == 2
    check plugin.createCount == 1
    check plugin.destroyCount == 0

    check controller.close().isOk
    check plugin.destroyCount == 1

  test "actual surface destruction cleans up and permits recreation":
    var reactor = openTestReactor()
    var plugin = newFakeGui()
    var produced: FakeWindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newFakeWindow()
      produced
    var controller = newGuiController(plugin, addr reactor, factory, "test")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    check controller.start(true).isOk
    dispatchWindowEvent(reactor, controller, produced,
      WindowEvent(kind: wekDestroyed))
    check controller.state == gcsUncreated
    check plugin.destroyCount == 1
    check plugin.hideCount == 0
    check plugin.createCount == 1

    check controller.show().isOk
    check controller.state == gcsVisible
    check plugin.createCount == 2
    check plugin.destroyCount == 1
    check controller.close().isOk
    check plugin.destroyCount == 2

  test "position-only ConfigureNotify events do not renegotiate plugin size":
    var reactor = openTestReactor()
    var plugin = newFakeGui()
    var produced: FakeWindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newFakeWindow()
      produced
    var controller = newGuiController(plugin, addr reactor, factory, "test")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    check controller.start(false).isOk
    let initialResizeCount = produced.resizeCount
    let sameSize = WindowEvent(kind: wekConfigure, width: 400, height: 300)
    dispatchWindowEvent(reactor, controller, produced, sameSize)
    dispatchWindowEvent(reactor, controller, produced, sameSize)

    check plugin.adjustSizeCount == 0
    check plugin.setSizeCount == 0
    check produced.resizeCount == initialResizeCount
    check controller.size == GuiSize(width: 400, height: 300)

  test "real ConfigureNotify size changes still notify the plugin":
    var reactor = openTestReactor()
    var plugin = newFakeGui()
    plugin.adjustReturns = true
    var produced: FakeWindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newFakeWindow()
      produced
    var controller = newGuiController(plugin, addr reactor, factory, "test")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    check controller.start(false).isOk
    let initialResizeCount = produced.resizeCount
    dispatchWindowEvent(reactor, controller, produced,
      WindowEvent(kind: wekConfigure, width: 512, height: 384))

    check plugin.adjustSizeCount == 1
    check plugin.setSizeCount == 1
    check plugin.sizeValue == GuiSize(width: 512, height: 384)
    check produced.resizeCount == initialResizeCount
    check controller.size == GuiSize(width: 512, height: 384)

  test "plugin-owned GUI destruction releases the host surface without double destroy":
    var reactor = openTestReactor()
    var plugin = newFakeGui()
    var produced: FakeWindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newFakeWindow()
      produced
    var controller = newGuiController(plugin, addr reactor, factory, "test")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    check controller.start(false).isOk
    var closed = ClapGuiRequests(closed: true, wasDestroyed: true)
    check controller.handlePluginRequests(closed).isOk
    check plugin.destroyCount == 1
    check controller.state == gcsUncreated
    check controller.show().isOk
    check plugin.createCount == 2
    check controller.close().isOk
    check plugin.destroyCount == 2

  test "embedded X11 is preferred over floating X11":
    var reactor = openTestReactor()
    var plugin = newFakeGui(embedded = true, floating = true)
    var produced: FakeWindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newFakeWindow()
      produced
    var controller = newGuiController(plugin, addr reactor, factory, "test")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    check controller.start(false).isOk
    check controller.mode == gmEmbedded
    check plugin.parentCount == 1
    check plugin.transientCount == 0

  test "floating X11 is used when embedding is unsupported":
    var reactor = openTestReactor()
    var plugin = newFakeGui(embedded = false, floating = true)
    var produced: FakeWindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newFakeWindow()
      produced
    var controller = newGuiController(plugin, addr reactor, factory, "test")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    check controller.start(false).isOk
    check controller.mode == gmFloating
    check plugin.parentCount == 0
    check plugin.transientCount == 1
