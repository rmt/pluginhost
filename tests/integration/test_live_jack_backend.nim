import std/[os, osproc, streams, strutils, unittest]

import pluginhost/domain/[port_plan, result]
import pluginhost/jack/backend
import pluginhost/rt/engine
import ../rt/instrumentation_api

const
  LiveSampleRate = 48_000'u32
  LiveBufferSize = 64'u32
  DeterministicCycles = 128'u64
  QuiescenceWitnessCycles = 32
  StressIterations = 32
  StressCycles = 8'u64

proc livePortPlan(): PortPlan =
  newPortPlan(
    portPlanVersion(1),
    @[],
    @[
      AudioChannelPlan(direction: pdInput, shortName: "audio_in_1"),
      AudioChannelPlan(direction: pdInput, shortName: "audio_in_2"),
      AudioChannelPlan(direction: pdOutput, shortName: "audio_out_1"),
      AudioChannelPlan(direction: pdOutput, shortName: "audio_out_2"),
    ],
    @[
      NotePortPlan(direction: pdInput, shortName: "midi_in_1"),
      NotePortPlan(direction: pdOutput, shortName: "midi_out_1"),
    ],
  )

proc waitForCycles(backend: JackBackend; target: uint64): bool =
  var attempt = 0
  while attempt < 5_000:
    if backend.notifications().processCycles >= target:
      return true
    sleep(1)
    inc attempt
  false

proc peerCommand(peer: Process; command: string): string =
  let input = peer.inputStream()
  input.write(command & "\n")
  input.flush()
  peer.outputStream().readLine()

proc loadedJackLibrary(readyLine: string): string =
  for field in readyLine.splitWhitespace:
    if field.startsWith("library="):
      return field["library=".len .. ^1]

proc descriptorCount(): int =
  for _, _ in walkDir("/proc/self/fd"):
    inc result

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

suite "isolated live PipeWire-JACK backend":
  test "ports, samples, quiescence, stress, and callback instrumentation":
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

    let plan = livePortPlan()
    var opened = openJackBackend(initJackBackendOpenConfig(
      "pluginhost-4c-live",
      noStartServer = true,
    ))
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk
    require backend.actualClientName == "pluginhost-4c-live"
    require backend.sampleRate == LiveSampleRate
    require backend.bufferSize == LiveBufferSize
    require backend.configure(plan, fpmDeterministic).isOk
    require backend.realizedPortCount == 6
    require backend.activate().isOk
    require backend.waitForCycles(8'u64)

    var peer = startProcess(
      peerPath,
      args = @[
        backend.actualClientName,
        $LiveBufferSize,
        $DeterministicCycles,
      ],
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

    let activeSnapshot = backend.notifications()
    require activeSnapshot.processCycles >= DeterministicCycles
    require activeSnapshot.processErrors == 0
    require activeSnapshot.lateProcessCalls == 0

    require backend.deactivate().isOk
    let stoppedCycles = backend.notifications().processCycles
    let waitedAfterDeactivate = peer.peerCommand(
      "WAIT " & $QuiescenceWitnessCycles)
    require waitedAfterDeactivate.startsWith("WAITED ")
    let afterDeactivate = backend.notifications()
    require afterDeactivate.processCycles == stoppedCycles
    require afterDeactivate.processErrors == 0
    require afterDeactivate.lateProcessCalls == 0

    require backend.close().isOk
    require peer.peerCommand("ABSENT") == "ABSENT"
    let waitedAfterClose = peer.peerCommand("WAIT " & $QuiescenceWitnessCycles)
    require waitedAfterClose.startsWith("WAITED ")

    let descriptorsBeforeStress = descriptorCount()
    var iteration = 0
    while iteration < StressIterations:
      var stressOpened = openJackBackend(initJackBackendOpenConfig(
        "pluginhost-4c-stress",
        noStartServer = true,
      ))
      require stressOpened.isOk
      var stressBackend = move(stressOpened.value)
      require stressBackend.actualClientName == "pluginhost-4c-stress"
      require stressBackend.sampleRate == LiveSampleRate
      require stressBackend.bufferSize == LiveBufferSize
      require stressBackend.configure(plan, fpmSilence).isOk
      require stressBackend.activate().isOk
      require stressBackend.waitForCycles(StressCycles)
      let stressSnapshot = stressBackend.notifications()
      require stressSnapshot.processCycles >= StressCycles
      require stressSnapshot.processErrors == 0
      require stressSnapshot.lateProcessCalls == 0
      require stressBackend.close().isOk
      inc iteration

    let descriptorsAfterStress = descriptorCount()
    require descriptorsAfterStress == descriptorsBeforeStress
    let waitedAfterStress = peer.peerCommand("WAIT " & $QuiescenceWitnessCycles)
    require waitedAfterStress.startsWith("WAITED ")

    let liveInstrumentation = snapshotRtInstrumentation()
    require liveInstrumentation.isClean
    require liveInstrumentation.callbackEntries > 0

    let quitReply = peer.peerCommand("QUIT")
    require quitReply.len == 0
    require peer.waitForExit(2_000) == 0
    peer.close()
    peerNeedsCleanup = false
