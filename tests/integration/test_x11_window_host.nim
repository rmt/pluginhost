import std/[os, osproc, unittest]

import fixtures/clap/gui_fixture_api
import pluginhost/app/main_reactor
import pluginhost/clap/[gui_client, instance, loader]
import pluginhost/domain/[plugin_catalog, reactor, result]
import pluginhost/gui/[controller, window_backend, window_host]
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

proc openGuiFixture(path: string): tuple[instance: ClapInstance, observer: DynamicLibrary] =
  var observerResult = openDynamicLibrary(path)
  require observerResult.isOk
  var observer = move(observerResult.value)
  var moduleResult = openClapModule(path)
  require moduleResult.isOk
  var module = move(moduleResult.value)
  var catalog = module.readCatalog()
  require catalog.isOk
  var selected = catalog.value.selectDescriptor(PluginSelector(
    kind: pskId, pluginId: "org.pluginhost.fixture.gui"))
  require selected.isOk
  var created = createClapInstance(move(module), move(selected.value), nil, true)
  require created.isOk
  (move(created.value), move(observer))

suite "X11 window-host integration":
  test "Xvfb window lifecycle and reactor readiness are deterministic":
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
    require reactor.waitForWindowFd(token.value)
    drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
      sawDestroyed, configureWidth, configureHeight)
    check sawMap
    check host.state == whVisible

    require host.resize(240, 120).isOk
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
    var sawEvents = false
    for ignored in 0 ..< 8:
      discard ignored
      var events = reactor.wait(monotonicNanos(100_000_000))
      require events.isOk
      if events.value.len > 0:
        sawEvents = true
        require controller.handleWindowEvents(events.value).isOk
        break
    check sawEvents

    let sender = getEnv("PLUGINHOST_X11_SEND_DELETE")
    require sender.len > 0 and fileExists(sender)
    let sent = execCmdEx(sender & " " & $produced.handle.id)
    check sent.exitCode == 0
    var restoredFromClose = false
    for ignored in 0 ..< 8:
      discard ignored
      var events = reactor.wait(monotonicNanos(100_000_000))
      require events.isOk
      if events.value.len > 0:
        require controller.handleWindowEvents(events.value).isOk
        if controller.state == gcsHidden:
          restoredFromClose = true
          break
    check restoredFromClose
    check controller.state == gcsHidden
    check api.hideCalls() == 1
    check api.destroyCalls() == 0
    check api.createCalls() == 1

    check controller.show().isOk
    check controller.state == gcsVisible
    check api.showCalls() == 2
    check api.createCalls() == 1
    check api.destroyCalls() == 0

    check controller.hide().isOk
    check controller.state == gcsHidden
