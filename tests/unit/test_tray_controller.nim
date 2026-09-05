import std/[posix, unittest]

import pluginhost/app/main_reactor
import pluginhost/domain/[reactor, result]
import pluginhost/gui/[icon, tray_controller, tray_icon]
import pluginhost/platform/linux/reactor as linux_reactor

type
  FakeTrayBackend = ref object of TrayIconBackend
    readFd: cint
    writeFd: cint
    opened: bool
    titleValue: string
    iconValue: GuiIcon
    pending: TrayPollResult
    hasEvent: bool
    closeCount: int

proc newFakeTray(): FakeTrayBackend =
  var descriptors: array[2, cint]
  doAssert pipe(descriptors) == 0
  new(result)
  result.readFd = descriptors[0]
  result.writeFd = descriptors[1]

method open*(backend: FakeTrayBackend; title: string; icon: GuiIcon): Result[Unit] {.
    raises: [].} =
  backend.titleValue = title
  backend.iconValue = icon
  backend.opened = true
  success()
method close*(backend: FakeTrayBackend): Result[Unit] {.raises: [].} =
  inc backend.closeCount
  if backend.readFd >= 0:
    discard posix.close(backend.readFd)
    backend.readFd = -1
  if backend.writeFd >= 0:
    discard posix.close(backend.writeFd)
    backend.writeFd = -1
  backend.opened = false
  success()

method pollEvent*(backend: FakeTrayBackend): Result[TrayPollResult] {.
    raises: [].} =
  if not backend.hasEvent:
    return success(TrayPollResult(available: false))
  var byte: char
  discard posix.read(backend.readFd, addr byte, 1)
  backend.hasEvent = false
  success(backend.pending)

method fileDescriptor*(backend: FakeTrayBackend): int32 {.raises: [].} =
  if backend.opened: int32(backend.readFd) else: -1'i32

proc openTestReactor(): MainReactor =
  var driver = linux_reactor.openLinuxReactorDriver()
  doAssert driver.isOk
  var opened = initMainReactor(driver.value)
  doAssert opened.isOk
  move(opened.value)

proc dispatchTrayEvent(reactor: var MainReactor; controller: TrayController;
                       backend: FakeTrayBackend; kind: TrayEventKind): bool =
  backend.pending = TrayPollResult(available: true,
    event: TrayEvent(kind: kind))
  backend.hasEvent = true
  var byte = 'x'
  check posix.write(backend.writeFd, addr byte, 1) == 1
  var events = reactor.wait(monotonicNanos(50_000_000))
  require events.isOk
  var handled = controller.handleEvents(events.value)
  require handled.isOk
  handled.value

suite "tray controller policy and lifecycle":
  test "activation events are delivered through the reactor and close is idempotent":
    var reactor = openTestReactor()
    var produced: FakeTrayBackend
    let factory: TrayIconFactory = proc(): TrayIconBackend =
      produced = newFakeTray()
      produced
    var controller = newTrayController(
      addr reactor, factory, "Surge XT [CLAP]")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    check controller.start().isOk
    check controller.state == tcsOpen
    check controller.isOpen
    check produced.titleValue == "Surge XT [CLAP]"
    check produced.iconValue != nil
    check dispatchTrayEvent(reactor, controller, produced, tekActivate)
    check controller.close().isOk
    check controller.close().isOk
    check controller.state == tcsClosed
    check produced.closeCount == 1

  test "non-activation events do not request a GUI toggle":
    var reactor = openTestReactor()
    var produced: FakeTrayBackend
    let factory: TrayIconFactory = proc(): TrayIconBackend =
      produced = newFakeTray()
      produced
    var controller = newTrayController(addr reactor, factory, "test")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    require controller.start().isOk
    check not dispatchTrayEvent(reactor, controller, produced, tekOther)
    check controller.isOpen

  test "a closed native tray icon releases its reactor registration":
    var reactor = openTestReactor()
    var produced: FakeTrayBackend
    let factory: TrayIconFactory = proc(): TrayIconBackend =
      produced = newFakeTray()
      produced
    var controller = newTrayController(addr reactor, factory, "test")
    defer:
      check controller.close().isOk
      check reactor.close().isOk

    require controller.start().isOk
    check not dispatchTrayEvent(reactor, controller, produced, tekClosed)
    check controller.state == tcsClosed
    check not controller.isOpen
    check produced.closeCount == 1

  test "missing reactor or backend is a typed unavailable failure":
    var controller = newTrayController(nil, nil, "test")
    let started = controller.start()
    check not started.isOk
    check controller.state == tcsUnavailable
    check controller.close().isOk
