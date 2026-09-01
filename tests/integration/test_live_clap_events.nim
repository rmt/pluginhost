import std/[os, osproc, streams, strutils, unittest]

import pluginhost/app/audio_slice
import pluginhost/clap/[event_bridge, ffi, loader]
import pluginhost/domain/[plugin_catalog, result]
import pluginhost/jack/backend
import pluginhost/platform/linux/dynlib
import ../fixtures/clap/event_fixture_api
import ../rt/instrumentation_api

const
  LiveBufferSize = 64'u32
  EventCyclesPerActivation = 8'u64
  LifecycleIterations = 16
  QuiescenceWitnessCycles = 32
  EventsPerCycle = 4'u32

proc openLiveEventSlice(): tuple[
    slice: InternalAudioSlice,
    fixture: EventFixtureApi,
    observer: DynamicLibrary] =
  let path = eventFixturePath("events_raw")
  var observerResult = openDynamicLibrary(path)
  require observerResult.isOk
  var observer = move(observerResult.value)
  let fixture = eventFixtureApi(observer)
  fixture.reset()

  var moduleResult = openClapModule(path)
  require moduleResult.isOk
  var module = move(moduleResult.value)
  let catalog = module.readCatalog()
  require catalog.isOk
  var selected = catalog.value.selectDescriptor(PluginSelector(
    kind: pskImplicitSingle))
  require selected.isOk
  var opened = openInternalAudioSlice(
    move(module), move(selected.value),
    initJackBackendOpenConfig("pluginhost-6b-live-events", noStartServer = true))
  require opened.isOk
  (move(opened.value), fixture, move(observer))

proc peerCommand(peer: Process; command: string): string =
  let input = peer.inputStream()
  input.write(command & "\n")
  input.flush()
  peer.outputStream().readLine()

proc emergencyPeerCleanup(peer: Process) =
  if peer == nil:
    return
  try:
    if peer.running:
      peer.terminate()
      discard peer.waitForExit(2_000)
  except CatchableError:
    discard
  try:
    peer.close()
  except CatchableError:
    discard

proc loadedJackLibrary(readyLine: string): string =
  for field in readyLine.splitWhitespace:
    if field.startsWith("library="):
      return field["library=".len .. ^1]

proc verifyObservedCycle(fixture: EventFixtureApi; first: uint32) =
  check fixture.eventType(first) == uint32(ClapEventTypeMidi)
  check fixture.time(first) == 2'u32
  check fixture.port(first) == 0
  check (fixture.flags(first) and ClapEventIsLive) != 0'u32
  check fixture.eventByte(first, 0) == 0x90
  check fixture.eventByte(first, 1) == 60
  check fixture.eventByte(first, 2) == 100

  check fixture.eventType(first + 1'u32) == uint32(ClapEventTypeMidi)
  check fixture.time(first + 1'u32) == 2'u32
  check fixture.port(first + 1'u32) == 1
  check (fixture.flags(first + 1'u32) and ClapEventIsLive) != 0'u32
  check fixture.eventByte(first + 1'u32, 0) == 0xb1
  check fixture.eventByte(first + 1'u32, 1) == 7
  check fixture.eventByte(first + 1'u32, 2) == 99

  check fixture.eventType(first + 2'u32) == uint32(ClapEventTypeMidi)
  check fixture.time(first + 2'u32) == 5'u32
  check fixture.port(first + 2'u32) == 1
  check (fixture.flags(first + 2'u32) and ClapEventIsLive) != 0'u32
  check fixture.eventByte(first + 2'u32, 0) == 0x81
  check fixture.eventByte(first + 2'u32, 1) == 61
  check fixture.eventByte(first + 2'u32, 2) == 64

  check fixture.eventType(first + 3'u32) == uint32(ClapEventTypeMidiSysex)
  check fixture.time(first + 3'u32) == 10'u32
  check fixture.port(first + 3'u32) == 0
  check (fixture.flags(first + 3'u32) and ClapEventIsLive) != 0'u32
  check fixture.size(first + 3'u32) == 4'u32
  check fixture.eventByte(first + 3'u32, 0) == 0xf0
  check fixture.eventByte(first + 3'u32, 1) == 1
  check fixture.eventByte(first + 3'u32, 2) == 2
  check fixture.eventByte(first + 3'u32, 3) == 0xf7

suite "isolated live JACK MIDI and CLAP events":
  test "offsets, ordering, SysEx, lifecycle, quiescence, and instrumentation":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let peerPath = getEnv("PLUGINHOST_JACK_PEER")
    require peerPath.len > 0
    require peerPath.isAbsolute
    require fileExists(peerPath)

    require runRtInstrumentationSelfTest() == 0
    let detected = snapshotRtInstrumentation()
    require detected.allocations > 0
    require detected.deallocations > 0
    require detected.locks > 0
    require detected.prints > 0
    require detected.io > 0
    require detected.callbackEntries > 0
    resetRtInstrumentation()

    var opened = openLiveEventSlice()
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    var sliceNeedsClose = true
    defer:
      if sliceNeedsClose:
        doAssert slice.close().isOk
      doAssert observer.close().isOk

    check slice.jackBackend().bufferSize == LiveBufferSize
    check slice.jackBackend().realizedPortCount == 4
    require slice.start().isOk

    var peer = startProcess(
      peerPath,
      args = @[slice.jackBackend().actualClientName, $LiveBufferSize],
    )
    var peerNeedsCleanup = true
    defer:
      if peerNeedsCleanup:
        emergencyPeerCleanup(peer)

    let ready = peer.outputStream().readLine()
    if not ready.startsWith("READY "):
      discard peer.waitForExit(2_000)
      checkpoint("peer stdout=" & ready & "; stderr=" &
        peer.errorStream().readAll())
    require ready.startsWith("READY ")
    let jackLibrary = ready.loadedJackLibrary()
    require jackLibrary.len > 0
    let dependencyCheck = execCmdEx(
      "readelf -d " & quoteShell(jackLibrary),
      options = {poUsePath, poStdErrToStdOut},
    )
    require dependencyCheck.exitCode == 0
    require dependencyCheck.output.contains("libpipewire-0.3.so")

    var iteration = 0
    while iteration < LifecycleIterations:
      let ran = peer.peerCommand("RUN " & $EventCyclesPerActivation)
      if not ran.startsWith("RAN "):
        discard peer.waitForExit(2_000)
        checkpoint("peer RUN first=" & ran & "; remaining=" &
          peer.outputStream().readAll() & "; stderr=" &
          peer.errorStream().readAll() & "; observed=" &
          $fixture.observedCount() & "; output-accepted=" &
          $fixture.outputAccepted() & "; output-rejected=" &
          $fixture.outputRejected() & "; contract=" &
          $fixture.contractFailures())
      require ran.startsWith("RAN ")
      let active = slice.jackBackend().notifications()
      require active.processErrors == 0
      require active.lateProcessCalls == 0

      require slice.stop().isOk
      let stoppedCycles = slice.jackBackend().notifications().processCycles
      let waited = peer.peerCommand("WAIT " & $QuiescenceWitnessCycles)
      require waited.startsWith("WAITED ")
      let quiescent = slice.jackBackend().notifications()
      require quiescent.processCycles == stoppedCycles
      require quiescent.processErrors == 0
      require quiescent.lateProcessCalls == 0

      inc iteration
      if iteration < LifecycleIterations:
        require slice.start().isOk

    let observedCount = fixture.observedCount()
    let minimumObserved = EventsPerCycle * uint32(EventCyclesPerActivation) *
      uint32(LifecycleIterations)
    require observedCount >= minimumObserved
    require observedCount mod EventsPerCycle == 0'u32
    var first = 0'u32
    while first < observedCount:
      fixture.verifyObservedCycle(first)
      first += EventsPerCycle

    let metrics = slice.takeEventMetrics()
    check metrics.acceptedInput == uint64(observedCount)
    check metrics.droppedInput == 0
    check metrics.malformedInput == 0
    check metrics.inputCapacityDrops == 0
    check metrics.jackLostInput == 0
    check metrics.acceptedOutput == uint64(observedCount)
    check metrics.droppedOutput == 0
    check metrics.invalidOutput == 0
    check metrics.outputCapacityDrops == 0
    check fixture.processCount() >= uint32(EventCyclesPerActivation) *
      uint32(LifecycleIterations)
    check fixture.outputAccepted() == observedCount
    check fixture.outputRejected() == 0
    check fixture.contractFailures() == 0

    require slice.close().isOk
    sliceNeedsClose = false
    check fixture.destroyCount() == 1
    require peer.peerCommand("ABSENT") == "ABSENT"
    let waitedAfterClose = peer.peerCommand("WAIT " & $QuiescenceWitnessCycles)
    require waitedAfterClose.startsWith("WAITED ")

    let liveInstrumentation = snapshotRtInstrumentation()
    require liveInstrumentation.isClean
    require liveInstrumentation.callbackEntries > 0

    let quitReply = peer.peerCommand("QUIT")
    require quitReply.len == 0
    require peer.waitForExit(2_000) == 0
    peer.close()
    peerNeedsCleanup = false
