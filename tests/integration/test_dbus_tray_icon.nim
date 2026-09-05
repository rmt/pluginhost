import std/[os, osproc, strutils, streams, unittest]

import pluginhost/app/main_reactor
import pluginhost/domain/[reactor, result]
import pluginhost/gui/[icon, tray_controller]
import pluginhost/platform/dbus/tray_icon
import pluginhost/platform/linux/reactor as linux_reactor

proc openTestReactor(): MainReactor =
  var driver = linux_reactor.openLinuxReactorDriver()
  require driver.isOk
  var opened = initMainReactor(driver.value)
  require opened.isOk
  move(opened.value)

proc stopWatcher(process: Process) =
  if process == nil:
    return
  try:
    if process.running:
      process.terminate()
      discard process.waitForExit(2_000)
  except CatchableError:
    discard
  try:
    process.close()
  except CatchableError:
    discard

proc pumpUntilDone(reactor: var MainReactor; controller: TrayController;
                   process: Process): tuple[exitCode: int, output: string,
                   activated: bool] =
  var activated = false
  for ignored in 0 ..< 24:
    discard ignored
    var events = reactor.wait(monotonicNanos(100_000_000))
    require events.isOk
    var handled = controller.handleEvents(events.value)
    require handled.isOk
    activated = activated or handled.value
    if not process.running:
      break
  result.exitCode = process.waitForExit(2_000)
  result.output = process.outputStream.readAll()
  result.activated = activated

proc exerciseWatcher(watcherPath, variant, itemInterface: string;
                      initialActivation = true) =
  var watcherArgs: seq[string]
  if variant == "kde":
    watcherArgs = @["kde"]
  if not initialActivation:
    watcherArgs.add("no-activate")
  var watcher = startProcess(watcherPath, args = watcherArgs, options = {})
  defer: stopWatcher(watcher)

  require watcher.outputStream.readLine() == "READY"

  var reactor = openTestReactor()
  defer: check reactor.close().isOk
  let iconValue = newGuiIcon(1, 1, @[0xa1b2c3d4'u32])
  require iconValue.isOk
  var controller = newTrayController(
    addr reactor, newDbusTrayIcon, "pluginhost-dbus-tray", iconValue.value)
  defer: check controller.close().isOk

  require controller.start().isOk
  check controller.state == tcsOpen
  check controller.fileDescriptor >= 0

  let registration = watcher.outputStream.readLine()
  require registration.startsWith("REGISTER ")
  let service = registration["REGISTER ".len .. ^1]
  require service.len > 0

  var probe = startProcess(
    "gdbus",
    args = @[
      "call", "--session", "--dest", service,
      "--object-path", "/StatusNotifierItem",
      "--method", "org.freedesktop.DBus.Properties.GetAll",
      itemInterface],
    options = {})
  let probeResult = pumpUntilDone(reactor, controller, probe)
  check probeResult.exitCode == 0
  check probeResult.output.contains("IconPixmap")
  check probeResult.output.contains("Title")
  check probeResult.output.contains("byte 0xa1, byte 0xb2, byte 0xc3, byte 0xd4")
  if initialActivation:
    check probeResult.activated
  var busctlProbe = startProcess(
    "busctl",
    args = @[
      "--user", "call", service, "/StatusNotifierItem",
      "org.freedesktop.DBus.Properties", "GetAll", "s", itemInterface],
    options = {})
  let busctlResult = pumpUntilDone(reactor, controller, busctlProbe)
  check busctlResult.exitCode == 0
  check busctlResult.output.contains("IconPixmap")

suite "StatusNotifierItem D-Bus tray integration":
  test "registers with the selected watcher compatibility name":
    let watcherPath = getEnv("PLUGINHOST_DBUS_FAKE_WATCHER")
    require watcherPath.len > 0 and fileExists(watcherPath)
    let variant = getEnv("PLUGINHOST_DBUS_WATCHER_VARIANT")
    let itemInterface = if variant == "kde":
      "org.kde.StatusNotifierItem"
    else:
      "org.freedesktop.StatusNotifierItem"
    exerciseWatcher(watcherPath, variant, itemInterface)
    exerciseWatcher(watcherPath, variant, itemInterface, false)
