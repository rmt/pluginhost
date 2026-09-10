import std/[math, os, paths, posix, strutils, symlinks, unittest]

import pluginhost/app/[main_reactor, plugin_services]
import pluginhost/clap/[ffi, instance, loader, parameter_transport, state_codec]
import pluginhost/discovery/scanner
import pluginhost/domain/[errors, plugin_catalog, port_plan, reactor, result]
import pluginhost/gui/[icon, tray_icon]
import pluginhost/jack/[api, backend]
import pluginhost/rt/engine
import pluginhost/platform/dbus/[api, tray_icon as dbus_tray]
import pluginhost/platform/linux/[dynlib, pid_file, reactor as linux_reactor]
import pluginhost/platform/x11/[api as x11_api, window_host]
import ../fixtures/clap/fixture_api
import ../fixtures/ffi/fixture_api as ffi_fixture
import ../fixtures/jack/fixture_api

type
  HardeningRegistration = object
    fd: int32
    token: uint64

  HardeningReactorDriver = ref object of ReactorDriver
    nowValue: int64
    registrations: seq[HardeningRegistration]
    pending: seq[ReactorReady]
    failAdd: bool
    failModify: bool
    failRemove: bool
    failClose: bool
    closeCalls: int

method now(driver: HardeningReactorDriver): Result[MonotonicNanos] =
  success(monotonicNanos(driver.nowValue))

method addFd(driver: HardeningReactorDriver; fd: int32;
             interests: ReactorInterests; token: uint64): Result[Unit] =
  discard interests
  if driver.failAdd:
    return failure[Unit](hostError(
      hsPlatform, hekReactor, "injected reactor FD registration failure"))
  driver.registrations.add(HardeningRegistration(fd: fd, token: token))
  success()

method modifyFd(driver: HardeningReactorDriver; fd: int32;
                interests: ReactorInterests; token: uint64): Result[Unit] =
  discard interests
  if driver.failModify:
    return failure[Unit](hostError(
      hsPlatform, hekReactor, "injected reactor FD modification failure"))
  for registration in driver.registrations.mitems:
    if registration.fd == fd:
      registration.token = token
      return success()
  failure[Unit](hostError(hsPlatform, hekReactor, "missing hardening reactor FD"))

method removeFd(driver: HardeningReactorDriver; fd: int32): Result[Unit] =
  if driver.failRemove:
    return failure[Unit](hostError(
      hsPlatform, hekReactor, "injected reactor FD removal failure"))
  for index in 0 ..< driver.registrations.len:
    if driver.registrations[index].fd == fd:
      driver.registrations.delete(index)
      return success()
  failure[Unit](hostError(hsPlatform, hekReactor, "missing hardening reactor FD"))

method wait(driver: HardeningReactorDriver; timeoutMilliseconds: int32):
    Result[seq[ReactorReady]] =
  if timeoutMilliseconds > 0:
    driver.nowValue += int64(timeoutMilliseconds) * 1_000_000'i64
  success(move(driver.pending))

method close(driver: HardeningReactorDriver): Result[Unit] =
  inc driver.closeCalls
  if driver.failClose:
    return failure[Unit](hostError(
      hsPlatform, hekReactor, "injected reactor close failure"))
  success()

proc fdCount(): int =
  for kind, path in walkDir("/proc/self/fd"):
    discard kind
    discard path
    inc result

proc mappingCount(path: string): int =
  let canonical = absolutePath(path)
  for line in lines("/proc/self/maps"):
    if line.contains(canonical):
      inc result

proc removeTree(path: string) =
  if not dirExists(path):
    return
  var entries: seq[string]
  for kind, entry in walkDir(path):
    discard kind
    entries.add(entry)
  for entry in entries:
    let info = getFileInfo(entry, followSymlink = false)
    if info.kind == pcDir:
      removeTree(entry)
    else:
      removeFile(entry)
  removeDir(path)

proc hardeningRoot(prefix: string): string =
  result = getTempDir() / (prefix & "-" & $int(getpid()))
  if dirExists(result):
    removeTree(result)
  createDir(result)

proc stateTemporaryName(root, base: string; attempt: int): string =
  root / ("." & base & ".pluginhost-state-" & $int(getpid()) & "-" &
    $attempt & ".tmp")

proc pidTemporaryName(root, base: string; attempt: int): string =
  root / ("." & base & ".pluginhost-" & $int(getpid()) & "-" &
    $attempt & ".tmp")

proc emptyPlan(version = 1'u64): PortPlan =
  newPortPlan(portPlanVersion(version), @[], @[], @[])

proc fakeConfig(name: string; libraryPath: string): JackBackendOpenConfig =
  initJackBackendOpenConfig(name, noStartServer = true,
    libraryPath = libraryPath)

suite "11B hardening and resource boundaries":
  test "checked DSO owners reject bad acquisition and unload repeatedly":
    let missing = getTempDir() / "pluginhost-hardening-missing.so"
    let empty = openDynamicLibrary("")
    check not empty.isOk
    check empty.error.kind == hekLibraryOpen

    let absent = openDynamicLibrary(missing)
    check not absent.isOk
    check absent.error.kind == hekLibraryOpen

    let fixture = ffi_fixture.fixturePath()
    let before = fdCount()
    for ignored in 0 ..< 16:
      discard ignored
      var opened = openDynamicLibrary(fixture)
      require opened.isOk
      var library = move(opened.value)
      let unresolved = library.resolveAddress("pluginhost_hardening_missing")
      check not unresolved.isOk
      check unresolved.error.kind == hekSymbolLookup
      check library.close().isOk
      check library.close().isOk
    check fdCount() == before
    check mappingCount(fixture) == 0

    var closed: DynamicLibrary
    let lookup = closed.resolveAddress("clap_entry")
    check not lookup.isOk
    check lookup.error.kind == hekSymbolLookup

  test "CLAP, JACK, X11, and D-Bus partial acquisitions clean handles":
    let clapVariants = [
      "incompatible_entry", "missing_entry_callback", "init_fail",
      "missing_factory", "missing_factory_callback"]
    for variant in clapVariants:
      let path = clapFixturePath(variant)
      check mappingCount(path) == 0
      let opened = openClapModule(path)
      check not opened.isOk
      check opened.error.exitCode() == ExitClap
      check mappingCount(path) == 0

    let partialPath = jackPartialFixturePath()
    check mappingCount(partialPath) == 0
    let partial = openJackApi(partialPath)
    check not partial.isOk
    check partial.error.kind == hekJackSymbol
    check mappingCount(partialPath) == 0

    let missingJack = openJackApi(partialPath & ".missing")
    check not missingJack.isOk
    check missingJack.error.kind == hekJackLibraryOpen

    let missingX11 = x11_api.openX11Api("/pluginhost/missing-libX11.so")
    check not missingX11.isOk
    check missingX11.error.subsystem == hsGui

    let missingDbus = openDbusApi("/pluginhost/missing-libdbus.so")
    check not missingDbus.isOk
    check missingDbus.error.subsystem == hsGui

    var jack = openJackApi(jackFakeFixturePath())
    require jack.isOk
    var jackOwner = move(jack.value)
    check jackOwner.close().isOk
    check jackOwner.close().isOk
    check jackOwner.functions.clientOpen == nil

  test "repeated CLAP create and unload leaves fixture lifecycle balanced":
    let path = clapFixturePath("valid")
    var observerResult = openDynamicLibrary(path)
    require observerResult.isOk
    var observer = move(observerResult.value)
    let api = fixtureApi(observer)
    let beforeFd = fdCount()
    for iteration in 0 ..< 12:
      api.reset()
      var moduleResult = openClapModule(path)
      require moduleResult.isOk
      var module = move(moduleResult.value)
      var catalog = module.readCatalog()
      require catalog.isOk
      var selected = catalog.value.selectDescriptor(PluginSelector(
        kind: pskIndex, pluginIndex: 0))
      require selected.isOk
      var created = createClapInstance(move(module), move(selected.value))
      require created.isOk
      var instance = move(created.value)
      check instance.close().isOk
      check instance.close().isOk
      check api.pluginInitCalls() == 1
      check api.pluginDestroyCalls() == 1
      check api.deinitCalls() == 1
      discard iteration
    check observer.close().isOk
    check observer.close().isOk
    check fdCount() == beforeFd
    check mappingCount(path) == 0

  test "repeated JACK activation and cleanup returns every fixture resource":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    let beforeFd = fdCount()
    for iteration in 0 ..< 12:
      controls.reset()
      var opened = openJackBackend(fakeConfig(
        "hardening-" & $iteration, jackFakeFixturePath()))
      require opened.isOk
      var backend = move(opened.value)
      require backend.configure(emptyPlan(uint64(iteration + 1)),
        fpmSilence).isOk
      require backend.activate().isOk
      require backend.deactivate().isOk
      require backend.close().isOk
      require backend.close().isOk
      check controls.currentPortCount() == 0
      check controls.callbacksCleared() == 1
      check controls.isActive() == 0
    check fdCount() == beforeFd
    require controls.close().isOk
    require controls.close().isOk

  test "reactor acquisition and cleanup failures are retryable and generation-safe":
    let driver = HardeningReactorDriver(nowValue: 1_000_000)
    var opened = initMainReactor(driver)
    require opened.isOk
    var reactor = move(opened.value)
    check not reactor.registerFd(-1, {riRead}).isOk
    check not reactor.registerFd(3, {}).isOk

    driver.failAdd = true
    let failedRegistration = reactor.registerFd(3, {riRead})
    check not failedRegistration.isOk
    driver.failAdd = false
    var token = reactor.registerFd(3, {riRead})
    require token.isOk
    check token.value.generation == 2'u32
    check not reactor.modifyFd(ReactorToken(slot: token.value.slot,
      generation: 1'u32), {riWrite}).isOk

    driver.failModify = true
    check not reactor.modifyFd(token.value, {riWrite}).isOk
    driver.failModify = false
    check reactor.modifyFd(token.value, {riWrite}).isOk

    driver.failRemove = true
    check not reactor.removeFd(token.value).isOk
    driver.failRemove = false
    check reactor.removeFd(token.value).isOk
    check not reactor.removeFd(token.value).isOk

    var timer = reactor.registerTimer(monotonicNanos(2_000_000))
    require timer.isOk
    check not reactor.wait(monotonicNanos(-1)).isOk
    check reactor.cancelTimer(timer.value).isOk
    check not reactor.cancelTimer(timer.value).isOk

    driver.failAdd = true
    let failedCloseRegistration = reactor.registerFd(4, {riRead})
    check not failedCloseRegistration.isOk
    driver.failAdd = false
    token = reactor.registerFd(4, {riRead})
    require token.isOk
    driver.failRemove = true
    check not reactor.close().isOk
    driver.failRemove = false
    check reactor.close().isOk
    check reactor.close().isOk
    check driver.closeCalls == 1

  test "Linux reactor FD loops do not retain descriptors":
    let before = fdCount()
    for ignored in 0 ..< 24:
      discard ignored
      var descriptors: array[2, cint]
      require pipe(descriptors) == 0
      var driverResult = linux_reactor.openLinuxReactorDriver()
      require driverResult.isOk
      var opened = initMainReactor(driverResult.value)
      require opened.isOk
      var reactor = move(opened.value)
      var token = reactor.registerFd(int32(descriptors[0]), {riRead})
      require token.isOk
      var byte = 'x'
      require posix.write(descriptors[1], addr byte, 1) == 1
      var events = reactor.wait(monotonicNanos(50_000_000))
      require events.isOk
      check events.value.len == 1
      check events.value[0].token == token.value
      require reactor.removeFd(token.value).isOk
      require reactor.close().isOk
      require posix.close(descriptors[0]) == 0
      require posix.close(descriptors[1]) == 0
    check fdCount() == before

  test "CLAP service callbacks reject hostile registrations and retry cleanup":
    let driver = HardeningReactorDriver()
    var opened = initMainReactor(driver)
    require opened.isOk
    var reactor = move(opened.value)
    let registry = newPluginServiceRegistry(reactor)
    let services = registry.servicePointer
    defer:
      discard registry.close()
      discard reactor.close()

    var timerIds: array[MaxPluginTimers, cuint]
    check not services.registerTimer(services.context, 0, addr timerIds[0])
    check not services.registerTimer(services.context, 1, nil)
    for index in 0 ..< MaxPluginTimers:
      check services.registerTimer(
        services.context, 1'u32, addr timerIds[index])
    var overflowTimer = ClapInvalidId
    check not services.registerTimer(
      services.context, 1'u32, addr overflowTimer)

    check not services.registerFd(services.context, -1, ClapPosixFdRead)
    check not services.registerFd(services.context, 9, 0)
    check not services.registerFd(services.context, 9, 0x80'u32)
    check services.registerFd(services.context, 9, ClapPosixFdRead)
    check not services.registerFd(services.context, 9, ClapPosixFdWrite)
    check not services.modifyFd(services.context, 10, ClapPosixFdRead)
    check not services.unregisterFd(services.context, 10)

    check registry.activeTimerCount == MaxPluginTimers
    check registry.activeFdCount == 1
    driver.failRemove = true
    check not registry.close().isOk
    driver.failRemove = false
    check registry.close().isOk
    check registry.close().isOk
    check registry.activeTimerCount == 0
    check registry.activeFdCount == 0
    check not services.registerFd(services.context, 9, ClapPosixFdRead)

  test "state and PID bounded names fail without leaked temporary files":
    let root = hardeningRoot("pluginhost-hardening-state")
    defer:
      removeTree(root)
    let stateTarget = root / "state.bin"
    let before = fdCount()
    for attempt in 0 ..< 64:
      writeFile(stateTemporaryName(root, "state.bin", attempt), "occupied")
    let exhausted = openStateOutput(stateTarget)
    check not exhausted.isOk
    check exhausted.error.kind == hekState
    check not fileExists(stateTarget)
    for attempt in 0 ..< 64:
      removeFile(stateTemporaryName(root, "state.bin", attempt))
    check fdCount() == before

    writeFile(stateTarget, "ab")
    var inputResult = openStateInput(stateTarget)
    require inputResult.isOk
    var input = move(inputResult.value)
    let stream = input.streamPointer
    var bytes: array[4, uint8]
    check stream.read(stream, addr bytes[0], 4) == 2
    check stream.read(stream, addr bytes[0], 4) == 0
    require input.close().isOk
    require input.close().isOk

    let badStateInput = openStateInput(stateTarget & "\0bad")
    check not badStateInput.isOk
    let badStateOutput = openStateOutput(stateTarget & "\0bad")
    check not badStateOutput.isOk

    let pidTarget = root / "host.pid"
    for attempt in 0 ..< 64:
      writeFile(pidTemporaryName(root, "host.pid", attempt), "occupied")
    let pidExhausted = createPidFile(pidTarget)
    check not pidExhausted.isOk
    check pidExhausted.error.kind == hekPidFile
    check not fileExists(pidTarget)
    for attempt in 0 ..< 64:
      removeFile(pidTemporaryName(root, "host.pid", attempt))
    check fdCount() == before

    let badPid = createPidFile(pidTarget & "\0bad")
    check not badPid.isOk
    check badPid.error.kind == hekPidFile

  test "PID target symlinks are never replaced":
    let root = hardeningRoot("pluginhost-hardening-pid-link")
    defer:
      removeTree(root)
    let replacement = root / "replacement"
    let target = root / "host.pid"
    writeFile(replacement, "keep\n")
    createSymlink(Path(absolutePath(replacement)), Path(target))
    let created = createPidFile(target)
    check not created.isOk
    check readFile(replacement) == "keep\n"
    check getFileInfo(target, followSymlink = false).kind == pcLinkToFile

  test "scanner ignores symlink cycles and canonical duplicate candidates":
    let root = hardeningRoot("pluginhost-hardening-scan")
    defer:
      removeTree(root)
    createDir(root / "nested")
    let fixture = clapFixturePath("valid")
    copyFile(fixture, root / "one.clap")
    createSymlink(Path(absolutePath(root / "one.clap")),
      Path(root / "alias.clap"))
    createSymlink(Path(absolutePath(root)), Path(root / "nested" / "cycle"))

    let report = scanPlugins(@[root, root / "nested" / "cycle"], clapPath = "")
    check report.issues.len == 0
    check report.plugins.len == 2
    check report.plugins[0].path == expandFilename(root / "one.clap")
    check report.plugins[1].path == expandFilename(root / "one.clap")

  test "parameter transport rejects bad values and recovers":
    var transport = newClapParameterTransport()
    require transport != nil
    defer:
      transport.close()

    var event = ClapEventParamValue(
      header: ClapEventHeader(size: uint32(sizeof(ClapEventParamValue)),
        time: 0, spaceId: ClapCoreEventSpaceId,
        `type`: ClapEventTypeParamValue),
      paramId: 7, noteId: -1, portIndex: -1, channel: -1, key: -1,
      value: 0.5)
    check not transport.tryPushOutput(nil, 64)
    event.header.spaceId = 1'u16
    check not transport.tryPushOutput(addr event.header, 64)
    event.header.spaceId = ClapCoreEventSpaceId
    event.header.time = 64
    check not transport.tryPushOutput(addr event.header, 64)
    event.header.time = 0
    event.header.size = uint32(sizeof(ClapEventHeader))
    check not transport.tryPushOutput(addr event.header, 64)
    event.header.size = uint32(sizeof(ClapEventParamValue))
    event.value = NaN
    check not transport.tryPushOutput(addr event.header, 64)
    event.value = 0.5
    event.header.`type` = uint16(ClapEventTypeParamValue) + 100'u16
    check not transport.tryPushOutput(addr event.header, 64)
    event.header.`type` = ClapEventTypeParamValue
    event.header.time = 1
    check not transport.tryPushOutput(addr event.header, 64, flush = true)

    let invalid = transport.takeMetrics()
    check invalid.accepted == 0
    check invalid.invalid == 7
    check invalid.dropped == 7

    event.header.time = 3
    check transport.tryPushOutput(addr event.header, 64)
    var copied: ClapParameterEvent
    check transport.tryPop(copied)
    check copied.paramId == 7
    check copied.value == 0.5
    check not transport.tryPop(copied)

  test "GUI boundary inputs fail before optional libraries are opened":
    let zeroIcon = newGuiIcon(0, 1, @[])
    check not zeroIcon.isOk
    let wrongPixels = newGuiIcon(2, 2, @[0'u32])
    check not wrongPixels.isOk
    let oversized = newGuiIcon(65, 1, newSeq[uint32](65))
    check not oversized.isOk

    let badTitle = openX11WindowHost(title = "bad\0title")
    check not badTitle.isOk
    let badDisplay = openX11WindowHost(displayName = "bad\0display")
    check not badDisplay.isOk
    let badDimensions = openX11WindowHost(width = 0, height = 0)
    check not badDimensions.isOk

    let tray = dbus_tray.newDbusTrayIcon()
    check not tray.open("bad\0title", defaultGuiIcon()).isOk
    check not tray.open("valid", nil).isOk
    check tray.close().isOk
    check tray.close().isOk
