import std/[os, osproc, unittest]

import pluginhost/app/main_reactor
import pluginhost/domain/[reactor, result]
import pluginhost/gui/window_host
import pluginhost/platform/linux/reactor as linux_reactor
import pluginhost/platform/x11/window_host

proc drainEvents(host: var X11WindowHost;
                 sawMap, sawUnmap, sawConfigure, sawClose: var bool;
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
    var configureWidth = 0'u32
    var configureHeight = 0'u32
    require reactor.waitForWindowFd(token.value)
    drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
      configureWidth, configureHeight)
    check sawMap
    check host.state == whVisible

    require host.resize(240, 120).isOk
    require reactor.waitForWindowFd(token.value)
    drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
      configureWidth, configureHeight)
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
      configureWidth, configureHeight)
    check sawClose
    check host.state == whHidden

    require host.show().isOk
    check host.state == whVisible

    require host.hide().isOk
    require host.hide().isOk
    require reactor.waitForWindowFd(token.value)
    drainEvents(host, sawMap, sawUnmap, sawConfigure, sawClose,
      configureWidth, configureHeight)
    check sawUnmap
    check host.state == whHidden

    require reactor.removeFd(token.value).isOk
    check not reactor.isCurrent(token.value)
    require host.close().isOk
    require host.close().isOk
    check not host.isOpen
    check host.state == whClosed
    check host.fileDescriptor == -1
