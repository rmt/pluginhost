import std/[os, options, osproc, posix, streams, strutils, unittest]

import fixtures/clap/gui_fixture_api
import pluginhost/app/[main_reactor, plugin_services]
import pluginhost/clap/[gui_client, instance, loader, main_thread_services]
import pluginhost/domain/[plugin_catalog, reactor, result]
import pluginhost/gui/[controller, icon, window_backend, window_host]
import pluginhost/platform/linux/reactor as linux_reactor
import pluginhost/platform/x11/[gui_adapter, window_host]
import pluginhost/platform/linux/dynlib

proc drainEvents(host: var X11WindowHost;
                 sawMap, sawUnmap, sawConfigure, sawClose,
                 sawDestroyed: var bool;
                 configureWidth, configureHeight: var uint32) =
  for ignored in 0 ..< 128:
    discard ignored
    var polled = host.pollEvent()
    require polled.isOk
    if not polled.value.available:
      break
    case polled.value.event.kind
    of wekMap:
      sawMap = true
    of wekUnmap:
      sawUnmap = true
    of wekConfigure:
      sawConfigure = true
      configureWidth = polled.value.event.width
      configureHeight = polled.value.event.height
    of wekClose:
      sawClose = true
    of wekDestroyed:
      sawDestroyed = true
    else:
      discard

proc waitForWindowFd(reactor: var MainReactor; token: ReactorToken): bool =
  for ignored in 0 ..< 8:
    discard ignored
    var events = reactor.wait(monotonicNanos(250_000_000))
    require events.isOk
    for event in events.value:
      if event.kind == rekFd and event.token == token:
        return true
  false

proc openGuiFixture(path: string;
                    mainServices: ptr ClapMainThreadServices = nil;
                    servicesEnabled = false;
                    failureStep = GuiServiceFailureNone):
    tuple[instance: ClapInstance, observer: DynamicLibrary] =
  var observerResult = openDynamicLibrary(path)
  require observerResult.isOk
  var observer = move(observerResult.value)
  let api = guiFixtureApi(observer)
  api.reset()
  api.enableServices(if servicesEnabled: 1'u32 else: 0'u32)
  api.setServiceFailureStep(failureStep)
  var moduleResult = openClapModule(path)
  require moduleResult.isOk
  var module = move(moduleResult.value)
  var catalog = module.readCatalog()
  require catalog.isOk
  var selected = catalog.value.selectDescriptor(PluginSelector(
    kind: pskId, pluginId: "org.pluginhost.fixture.gui"))
  require selected.isOk
  var created = createClapInstance(
    move(module), move(selected.value), mainServices, true)
  require created.isOk
  (move(created.value), move(observer))

proc dispatchCombinedEvents(reactor: var MainReactor;
                            services: PluginServiceRegistry;
                            instance: var ClapInstance;
                            controller: GuiController;
                            closeRequested: ptr bool = nil): bool =
  var ready = reactor.wait(monotonicNanos(100_000_000))
  require ready.isOk
  if ready.value.len == 0:
    return false
  for rawEvent in ready.value:
    let serviceEvent = services.classify(rawEvent)
    if serviceEvent.isNone:
      continue
    case serviceEvent.get.kind
    of psekTimer:
      require instance.callOnTimer(serviceEvent.get.timerId).isOk
      require services.completeTimerDispatch(serviceEvent.get.timerId).isOk
    of psekFd:
      require instance.callOnFd(serviceEvent.get.fd,
        serviceEvent.get.fdFlags).isOk
  let handled = controller.handleWindowEvents(ready.value)
  require handled.isOk
  if closeRequested != nil:
    closeRequested[] = handled.value
  # The fixture FD is level-triggered and may keep wait() immediately ready;
  # yield so the X server can process a newly flushed map/resize request.
  sleep(5)
  true

proc waitForCombinedServices(reactor: var MainReactor;
                             services: PluginServiceRegistry;
                             instance: var ClapInstance;
                             controller: GuiController;
                             api: GuiFixtureApi;
                             timerTarget, fdTarget: uint32;
                             iterations = 24): bool =
  for ignored in 0 ..< iterations:
    discard ignored
    discard dispatchCombinedEvents(reactor, services, instance, controller)
    if api.timerCalls() >= timerTarget and api.fdCalls() >= fdTarget:
      return true
  false

type
  TraceWindowBackend = ref object of WindowHostBackend
    inner: WindowHostBackend
    mapEvents: uint32
    unmapEvents: uint32
    configureEvents: uint32
    closeEvents: uint32
    destroyedEvents: uint32

method open(backend: TraceWindowBackend; title: string;
            width, height: uint32): Result[Unit] {.raises: [].} =
  backend.inner.open(title, width, height)

method setIcon(backend: TraceWindowBackend;
               icon: GuiIcon): Result[Unit] {.raises: [].} =
  backend.inner.setIcon(icon)

method close(backend: TraceWindowBackend): Result[Unit] {.raises: [].} =
  backend.inner.close()

method show(backend: TraceWindowBackend): Result[Unit] {.raises: [].} =
  backend.inner.show()

method hide(backend: TraceWindowBackend): Result[Unit] {.raises: [].} =
  backend.inner.hide()

method resize(backend: TraceWindowBackend; width, height: uint32):
    Result[Unit] {.raises: [].} =
  backend.inner.resize(width, height)

method pollEvent(backend: TraceWindowBackend):
    Result[WindowPollResult] {.raises: [].} =
  var polled = backend.inner.pollEvent()
  if polled.isOk and polled.value.available:
    case polled.value.event.kind
    of wekMap:
      inc backend.mapEvents
    of wekUnmap:
      inc backend.unmapEvents
    of wekConfigure:
      inc backend.configureEvents
    of wekClose:
      inc backend.closeEvents
    of wekDestroyed:
      inc backend.destroyedEvents
    else:
      discard
  polled

method fileDescriptor(backend: TraceWindowBackend): int32 {.raises: [].} =
  backend.inner.fileDescriptor

method state(backend: TraceWindowBackend): WindowHostState {.raises: [].} =
  backend.inner.state

method handle(backend: TraceWindowBackend): GuiWindowHandle {.raises: [].} =
  backend.inner.handle

method width(backend: TraceWindowBackend): uint32 {.raises: [].} =
  backend.inner.width

method height(backend: TraceWindowBackend): uint32 {.raises: [].} =
  backend.inner.height

proc trayNameOwned(service: string): bool =
  let queried = execCmdEx(
    "gdbus call --session --dest org.freedesktop.DBus " &
    "--object-path /org/freedesktop/DBus " &
    "--method org.freedesktop.DBus.NameHasOwner '" & service & "'")
  queried.exitCode == 0 and queried.output.contains("(true,)")

proc exercisePublicWindowClose(pluginPath, title, label: string;
                               saveState = false) =
  let binary = getEnv("PLUGINHOST_TEST_BIN")
  let sender = getEnv("PLUGINHOST_X11_SEND_DELETE")
  let watcherBinary = getEnv("PLUGINHOST_DBUS_FAKE_WATCHER")
  require fileExists(binary) and fileExists(sender) and
    fileExists(watcherBinary) and (fileExists(pluginPath) or dirExists(pluginPath))

  let pidPath = getTempDir() / ("pluginhost-gui-close-" & label & "-" &
    $getCurrentProcessId() & ".pid")
  let statePath = getTempDir() / ("pluginhost-gui-close-" & label & "-" &
    $getCurrentProcessId() & ".vstpreset")
  if fileExists(pidPath): removeFile(pidPath)
  if fileExists(statePath): removeFile(statePath)
  var watcher = startProcess(watcherBinary, args = @["no-activate"], options = {})
  defer:
    if watcher.peekExitCode() == -1:
      watcher.terminate()
      discard watcher.waitForExit(2_000)
    watcher.close()
  require watcher.outputStream.readLine() == "READY"

  var args = @["--quiet", "--require-gui", "--no-start-server",
    "--pid-file", pidPath]
  if saveState:
    args.add(@["--save-state", statePath])
  args.add(pluginPath)
  var host = startProcess(binary, args = args, options = {})
  defer:
    if host.peekExitCode() == -1:
      host.terminate()
      discard host.waitForExit(2_000)
    host.close()
    if fileExists(pidPath): removeFile(pidPath)
    if fileExists(statePath): removeFile(statePath)

  var windowId = ""
  for _ in 0 ..< 500:
    let queried = execCmdEx("xwininfo -name '" & title & "'")
    if queried.exitCode == 0:
      let marker = "Window id: 0x"
      let index = queried.output.find(marker)
      if index >= 0:
        windowId = $parseHexInt(
          queried.output[index + marker.len .. ^1].splitWhitespace()[0])
        break
    if host.peekExitCode() != -1:
      checkpoint host.errorStream.readAll()
      break
    sleep(10)
  require windowId.len > 0
  require fileExists(pidPath)
  check readFile(pidPath).strip() == $host.processID

  let trayService = "org.freedesktop.StatusNotifierItem-" &
    $host.processID & "-1"
  var registered = false
  for _ in 0 ..< 100:
    if trayNameOwned(trayService):
      registered = true
      break
    sleep(10)
  require registered

  let sent = execCmdEx(sender & " " & windowId)
  require sent.exitCode == 0
  let exitCode = host.waitForExit(5_000)
  require exitCode != -1
  let output = host.outputStream.readAll()
  let diagnostic = host.errorStream.readAll()
  checkpoint diagnostic
  check exitCode == 0
  check output.len == 0
  check diagnostic.len == 0
  check not fileExists(pidPath)
  check not trayNameOwned(trayService)
  if saveState:
    require fileExists(statePath)
    check readFile(statePath).startsWith("VST3")

suite "X11 window-host integration":
  test "public CLAP WM close stops the process and removes its tray":
    exercisePublicWindowClose(
      getEnv("PLUGINHOST_CLAP_FIXTURE_DIR") / "gui.clap",
      "Fixture GUI [CLAP]", "clap")

  test "public VST3 WM close saves state and removes its tray":
    exercisePublicWindowClose(
      getEnv("PLUGINHOST_VST3_GUI_FIXTURE_DIR") / "v5b.vst3",
      "V2A Fixture [VST3]", "vst3", saveState = true)

  test "Xvfb window lifecycle handles reactor and buffered Xlib events":
    require getEnv("DISPLAY").len > 0
    var opened = openX11WindowHost(width = 160, height = 90,
      title = "pluginhost-10a")
    require opened.isOk
    var host = move(opened.value)
    defer:
      doAssert host.close().isOk

    check host.isOpen
    check host.state == whHidden
    check host.fileDescriptor >= 0
    check host.width == 160
    check host.height == 90
    require host.setIcon(defaultGuiIcon()).isOk
    let iconProperty = execCmdEx(
      "xprop -id " & $host.windowId & " _NET_WM_ICON")
    check iconProperty.exitCode == 0
    check iconProperty.output.contains("_NET_WM_ICON")

    var driverResult = linux_reactor.openLinuxReactorDriver()
    require driverResult.isOk
    var reactorOpened = initMainReactor(driverResult.value)
    require reactorOpened.isOk
    var reactor = move(reactorOpened.value)
    defer:
      doAssert reactor.close().isOk
    var token = reactor.registerFd(host.fileDescriptor, {riRead})
    require token.isOk

    require host.show().isOk
    require host.show().isOk
    var sawMap = false
    var sawUnmap = false
    var sawConfigure = false
    var sawClose = false
    var sawDestroyed = false
    var configureWidth = 0'u32
    var configureHeight = 0'u32
    drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
      sawDestroyed, configureWidth, configureHeight)
    if not sawMap:
      require reactor.waitForWindowFd(token.value)
      drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
        sawDestroyed, configureWidth, configureHeight)
    check sawMap
    check host.state == whVisible

    require host.resize(240, 120).isOk
    drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
      sawDestroyed, configureWidth, configureHeight)
    if configureWidth != 240:
      require reactor.waitForWindowFd(token.value)
      drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
        sawDestroyed, configureWidth, configureHeight)
    check configureWidth == 240
    check configureHeight == 120
    check host.width == 240
    check host.height == 120

    let sender = getEnv("PLUGINHOST_X11_SEND_DELETE")
    require sender.len > 0 and fileExists(sender)
    let sent = execCmdEx(sender & " " & $host.windowId)
    check sent.exitCode == 0
    drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
      sawDestroyed, configureWidth, configureHeight)
    if not sawClose:
      require reactor.waitForWindowFd(token.value)
      drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
        sawDestroyed, configureWidth, configureHeight)
    check sawClose
    check not sawDestroyed
    check host.state == whVisible

    require host.hide().isOk
    check host.state == whHidden
    require host.show().isOk
    check host.state == whVisible

    require host.hide().isOk
    require host.hide().isOk
    drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
      sawDestroyed, configureWidth, configureHeight)
    if not sawUnmap:
      require reactor.waitForWindowFd(token.value)
      drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
        sawDestroyed, configureWidth, configureHeight)
    check sawUnmap
    check host.state == whHidden

    require reactor.removeFd(token.value).isOk
    check not reactor.isCurrent(token.value)
    require host.close().isOk
    require host.close().isOk
    check not host.isOpen
    check host.state == whClosed
    check host.fileDescriptor == -1

  test "the controller negotiates the fixture GUI through the X11 adapter":
    require getEnv("DISPLAY").len > 0
    let fixtureDirectory = getEnv("PLUGINHOST_CLAP_FIXTURE_DIR")
    require fixtureDirectory.len > 0
    var opened = openGuiFixture(fixtureDirectory / "gui.clap")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk
    var api = guiFixtureApi(observer)
    api.reset()
    var driverResult = linux_reactor.openLinuxReactorDriver()
    require driverResult.isOk
    var reactorOpened = initMainReactor(driverResult.value)
    require reactorOpened.isOk
    var reactor = move(reactorOpened.value)
    defer:
      doAssert reactor.close().isOk
    var produced: WindowHostBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newX11WindowBackend()
      produced
    var controller = newGuiController(
      newClapGuiClient(addr instance), addr reactor, factory,
      "pluginhost-gui-fixture")
    defer:
      doAssert controller.close().isOk
    var started = controller.start(true)
    require started.isOk
    check controller.state == gcsVisible
    check controller.mode == gmEmbedded
    check controller.isCreated
    check api.createCalls() == 1
    check api.showCalls() == 1

    let sender = getEnv("PLUGINHOST_X11_SEND_DELETE")
    require sender.len > 0 and fileExists(sender)
    let sent = execCmdEx(sender & " " & $produced.handle.id)
    check sent.exitCode == 0
    var handled = controller.handleWindowEvents(@[])
    require handled.isOk
    var closeRequested = handled.value
    for _ in 0 ..< 8:
      if closeRequested: break
      var events = reactor.wait(monotonicNanos(100_000_000))
      require events.isOk
      handled = controller.handleWindowEvents(events.value)
      require handled.isOk
      closeRequested = handled.value
    check closeRequested
    check controller.state == gcsVisible
    check api.hideCalls() == 0
    check api.destroyCalls() == 0
    check api.createCalls() == 1

    check controller.hide().isOk
    check controller.show().isOk
    check api.showCalls() == 2
    check api.createCalls() == 1
    check api.destroyCalls() == 0
    check controller.hide().isOk
    check controller.state == gcsHidden

  test "GUI services share the X11 reactor without starving window events":
    require getEnv("DISPLAY").len > 0
    let fixtureDirectory = getEnv("PLUGINHOST_CLAP_FIXTURE_DIR")
    require fixtureDirectory.len > 0

    var driverResult = linux_reactor.openLinuxReactorDriver()
    require driverResult.isOk
    var reactorOpened = initMainReactor(driverResult.value)
    require reactorOpened.isOk
    var reactor = move(reactorOpened.value)
    defer:
      doAssert reactor.close().isOk
    let services = newPluginServiceRegistry(reactor)
    defer:
      doAssert services.close().isOk

    var opened = openGuiFixture(fixtureDirectory / "gui.clap",
      services.servicePointer, true)
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk
    let api = guiFixtureApi(observer)

    var produced: TraceWindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      new(produced)
      produced.inner = newX11WindowBackend()
      produced
    var controller = newGuiController(
      newClapGuiClient(addr instance), addr reactor, factory,
      "pluginhost-gui-services")
    defer:
      doAssert controller.close().isOk

    require controller.start(true).isOk
    check controller.state == gcsVisible
    check controller.mode == gmEmbedded
    check controller.isCreated
    check api.createCalls() == 1'u32
    check api.timerRegisterCalls() == 1'u32
    check api.fdRegisterCalls() == 1'u32
    check services.activeTimerCount == 1
    check services.activeFdCount == 1

    check waitForCombinedServices(reactor, services, instance, controller,
      api, 3'u32, 3'u32)
    for _ in 0 ..< 12:
      if produced.mapEvents > 0'u32: break
      discard dispatchCombinedEvents(reactor, services, instance, controller)
    check produced.mapEvents >= 1'u32

    let configureBefore = produced.configureEvents
    require produced.resize(420, 300).isOk
    var resized = false
    for ignored in 0 ..< 12:
      discard ignored
      discard dispatchCombinedEvents(reactor, services, instance, controller)
      if controller.size == GuiSize(width: 420, height: 300):
        resized = true
        break
    check resized
    check produced.configureEvents > configureBefore
    check api.setSizeCalls() >= 1'u32

    let unmapBefore = produced.unmapEvents
    require controller.hide().isOk
    check controller.state == gcsHidden
    var hiddenEvent = false
    for ignored in 0 ..< 12:
      discard ignored
      discard dispatchCombinedEvents(reactor, services, instance, controller)
      if produced.unmapEvents > unmapBefore:
        hiddenEvent = true
        break
    check hiddenEvent
    check waitForCombinedServices(reactor, services, instance, controller,
      api, 6'u32, 6'u32)

    let mapBefore = produced.mapEvents
    require controller.show().isOk
    check controller.state == gcsVisible
    var shownEvent = false
    for ignored in 0 ..< 12:
      discard ignored
      discard dispatchCombinedEvents(reactor, services, instance, controller)
      if produced.mapEvents > mapBefore:
        shownEvent = true
        break
    check shownEvent
    check waitForCombinedServices(reactor, services, instance, controller,
      api, 9'u32, 9'u32)

    let sender = getEnv("PLUGINHOST_X11_SEND_DELETE")
    require sender.len > 0 and fileExists(sender)
    let sent = execCmdEx(sender & " " & $produced.handle.id)
    check sent.exitCode == 0
    let closeBefore = produced.closeEvents
    var closeRequested = false
    for ignored in 0 ..< 12:
      discard ignored
      discard dispatchCombinedEvents(reactor, services, instance,
        controller, addr closeRequested)
      if closeRequested:
        break
    check closeRequested
    check produced.closeEvents > closeBefore
    check controller.state == gcsVisible
    check api.destroyCalls() == 0'u32

    check waitForCombinedServices(reactor, services, instance, controller,
      api, 12'u32, 12'u32)
    check produced.mapEvents >= 2'u32
    check produced.unmapEvents >= 1'u32
    check produced.configureEvents > configureBefore
    check produced.closeEvents >= 1'u32
    check api.timerCalls() >= 12'u32
    check api.fdCalls() >= 12'u32
    check api.mainThreadFailures() == 0'u32
    check api.contractFailures() == 0'u32

    check controller.close().isOk
    check controller.close().isOk
    check api.destroyCalls() == 1'u32
    check api.timerUnregisterCalls() == 1'u32
    check api.fdUnregisterCalls() == 1'u32
    check api.pipeCloseCalls() == 2'u32
    check api.serviceCleanupFailures() == 0'u32
    check services.activeTimerCount == 0
    check services.activeFdCount == 0
    let timerCallsAfterClose = api.timerCalls()
    let fdCallsAfterClose = api.fdCalls()
    for ignored in 0 ..< 3:
      discard ignored
      discard dispatchCombinedEvents(reactor, services, instance, controller)
      check services.activeTimerCount == 0
      check services.activeFdCount == 0
    check api.timerCalls() == timerCallsAfterClose
    check api.fdCalls() == fdCallsAfterClose
    check instance.close().isOk
    check instance.close().isOk
    check observer.close().isOk
    check observer.close().isOk

  test "GUI service setup rolls back a partial FD registration failure":
    require getEnv("DISPLAY").len > 0
    let fixtureDirectory = getEnv("PLUGINHOST_CLAP_FIXTURE_DIR")
    require fixtureDirectory.len > 0

    var driverResult = linux_reactor.openLinuxReactorDriver()
    require driverResult.isOk
    var reactorOpened = initMainReactor(driverResult.value)
    require reactorOpened.isOk
    var reactor = move(reactorOpened.value)
    defer:
      doAssert reactor.close().isOk
    let services = newPluginServiceRegistry(reactor)
    defer:
      doAssert services.close().isOk

    var opened = openGuiFixture(fixtureDirectory / "gui.clap",
      services.servicePointer, true, GuiServiceFailureFdRegistration)
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk
    let api = guiFixtureApi(observer)

    var produced: WindowHostBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      produced = newX11WindowBackend()
      produced
    var controller = newGuiController(
      newClapGuiClient(addr instance), addr reactor, factory,
      "pluginhost-gui-services-failure")
    defer:
      doAssert controller.close().isOk

    var started = controller.start(true)
    check not started.isOk
    check controller.state == gcsUnavailable
    check api.createCalls() == 0'u32
    check api.destroyCalls() == 0'u32
    check api.timerRegisterCalls() == 1'u32
    check api.timerUnregisterCalls() == 1'u32
    check api.fdRegisterCalls() == 0'u32
    check api.fdUnregisterCalls() == 0'u32
    check api.pipeCreateCalls() == 1'u32
    check api.pipeCloseCalls() == 2'u32
    check api.serviceSetupFailures() == 1'u32
    check api.serviceCleanupFailures() == 0'u32
    check api.mainThreadFailures() == 0'u32
    check api.contractFailures() == 0'u32
    check services.activeTimerCount == 0
    check services.activeFdCount == 0
    check controller.close().isOk
    check controller.close().isOk
    check instance.close().isOk
    check instance.close().isOk
    check observer.close().isOk
    check observer.close().isOk
