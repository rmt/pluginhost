import std/[options, os, strutils, unittest]

import pluginhost/domain/[errors, port_plan]
import pluginhost/jack/[backend, ffi]
import pluginhost/rt/[atomic_pod, engine]
import ../fixtures/jack/fixture_api

type
  SuspendThreadAttempt = object
    backend: ptr JackBackend
    started: RtAtomicU32
    succeeded: bool
    errorKind: HostErrorKind

proc suspendBackendOnThread(attempt: ptr SuspendThreadAttempt) {.thread.} =
  attempt.started.storeRelease(1'u32)
  let suspended = attempt.backend[].suspendProcess()
  attempt.succeeded = suspended.isOk
  if not suspended.isOk:
    attempt.errorKind = suspended.error.kind

proc oneInOneOutPlan(version = 1'u64): PortPlan =
  newPortPlan(
    portPlanVersion(version),
    @[],
    @[
      AudioChannelPlan(
        direction: pdInput,
        shortName: "audio_in_1",
        alias: "Input 1",
      ),
      AudioChannelPlan(
        direction: pdOutput,
        shortName: "audio_out_1",
        alias: "Output 1",
      ),
    ],
    @[],
  )

proc fakeConfig(clientName = "requested-client";
                serverName = none(string)): JackBackendOpenConfig =
  initJackBackendOpenConfig(
    clientName,
    serverName = serverName,
    noStartServer = true,
    libraryPath = jackFakeFixturePath(),
  )

static:
  doAssert not compiles(block:
    var original: JackBackend
    var duplicate = `=dup`(original)
    discard duplicate.state
  )

suite "checked JACK backend lifecycle and callbacks":
  test "open records actual server properties and registers every callback":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    controls.setActualClientName("fixture-client-01")

    var opened = openJackBackend(fakeConfig(
      serverName = some("studio-server")))
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk

    check backend.state == jbsOpen
    check backend.isOpen
    check backend.actualClientName == "fixture-client-01"
    check backend.clientNameSize == 64
    check backend.portNameSize == 128
    check backend.sampleRate == 48_000'u32
    check backend.bufferSize == 128'u32
    check $controls.requestedClientName() == "requested-client"
    check $controls.requestedServerName() == "studio-server"
    check (controls.requestedOptions() and JackServerName) != 0
    check (controls.requestedOptions() and JackNoStartServer) != 0

    check controls.callbackOrderCount() == 8
    for index, expected in [1, 2, 3, 4, 5, 6, 7, 8]:
      check controls.callbackOrder(cint(index)) == expected
    let snapshot = backend.notifications()
    check snapshot.bufferSizeCount == 1
    check snapshot.bufferSize == 128
    check snapshot.sampleRateCount == 1
    check snapshot.sampleRate == 48_000

    check backend.close().isOk
    check backend.state == jbsClosed
    check backend.close().isOk
    check controls.closeCount() == 1
    check controls.callbacksCleared() == 1

  test "missing requested server reports status names and complete context":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    controls.setOpenFailure(JackFailure or JackServerFailed or JackShmFailure)

    let opened = openJackBackend(fakeConfig(
      "missing-client", some("missing-server")))

    check not opened.isOk
    check opened.error.subsystem == hsJack
    check opened.error.kind == hekJackClientOpen
    check opened.error.exitCode == ExitJack
    check opened.error.context.contains("client=missing-client")
    check opened.error.context.contains("server=missing-server")
    check opened.error.context.contains("failure")
    check opened.error.context.contains("server-failed")
    check opened.error.context.contains("shared-memory-failure")
    check controls.closeCount() == 0

  test "every fallible callback registration rolls back the partial client":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk

    for (code, callbackName) in [
      (1, "process"), (4, "buffer-size"), (5, "sample-rate"),
      (6, "xrun"), (7, "freewheel"), (8, "latency"),
    ]:
      controls.reset()
      controls.setCallbackFailure(cint(code), 77)

      let opened = openJackBackend(fakeConfig())

      check not opened.isOk
      check opened.error.kind == hekJackCallbackRegistration
      check opened.error.context.contains("callback=" & callbackName)
      check opened.error.context.contains("status=77")
      check controls.closeCount() == 1
      check controls.currentPortCount() == 0
      check controls.callbacksCleared() == 1

  test "notification callbacks publish only compact control-plane state":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk
    require backend.configure(
      newPortPlan(portPlanVersion(1), @[], @[], @[]),
      fpmSilence).isOk

    controls.invokeXrun()
    controls.invokeXrun()
    controls.invokeFreewheel(1)
    controls.invokeBufferSize(256)
    controls.invokeSampleRate(96_000)
    controls.invokeLatency(JackPlaybackLatency)
    controls.invokeShutdown(JackServerError, "server stopped")

    let snapshot = backend.notifications()
    check snapshot.xrunCount == 2
    check snapshot.freewheelCount == 1
    check snapshot.freewheel
    check snapshot.bufferSizeCount == 2
    check snapshot.bufferSize == 256
    check snapshot.sampleRateCount == 2
    check snapshot.sampleRate == 96_000
    check snapshot.latencyCount == 1
    check snapshot.shutdownCount == 1
    check snapshot.shutdownStatus == JackServerError
    check snapshot.shutdownReason == "server stopped"
    check controls.closeCount() == 0
    check backend.state == jbsConfigured

  test "plugin latency is published in callbacks and recomputed from control plane":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer: doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer: doAssert backend.close().isOk
    require backend.configure(oneInOneOutPlan(), fpmSilence).isOk

    check backend.pluginLatency == 0'u32
    check backend.setPluginLatency(257'u32).isOk
    check backend.pluginLatency == 257'u32
    check not backend.recomputeLatencies().isOk
    require backend.activate().isOk
    check not backend.setPluginLatency(1'u32).isOk
    check backend.recomputeLatencies().isOk
    check controls.recomputeCount() == 1

    controls.invokeLatency(JackPlaybackLatency)
    check controls.portLatency(1, JackPlaybackLatency, 0) == 257'u32
    check controls.portLatency(1, JackPlaybackLatency, 1) == 257'u32
    controls.invokeLatency(JackCaptureLatency)
    check controls.portLatency(0, JackCaptureLatency, 0) == 257'u32
    check controls.portLatency(0, JackCaptureLatency, 1) == 257'u32
    controls.setPortLatency(
      0, JackPlaybackLatency, high(uint32) - 10'u32, high(uint32) - 5'u32)
    controls.invokeLatency(JackPlaybackLatency)
    check controls.portLatency(1, JackPlaybackLatency, 0) == high(uint32)
    check controls.portLatency(1, JackPlaybackLatency, 1) == high(uint32)
    controls.setRecomputeStatus(-44)
    let failed = backend.recomputeLatencies()
    check not failed.isOk
    check failed.error.kind == hekJackLatency
    check failed.error.context.contains("status=-44")
    check backend.deactivate().isOk

  test "configuration acknowledgement preserves a newer notification":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk
    require backend.configure(
      newPortPlan(portPlanVersion(1), @[], @[], @[]),
      fpmSilence).isOk

    controls.invokeBufferSize(256)
    require backend.configurationChangePending
    let first = backend.refreshRuntimeConfiguration()
    require first.isOk
    check first.value.bufferSize == 256
    check first.value.sampleRate == 48_000

    controls.invokeSampleRate(96_000)
    let stale = backend.acknowledgeConfigurationChange()
    check not stale.isOk
    check stale.error.kind == hekJackQuiescence
    check backend.configurationChangePending

    let current = backend.refreshRuntimeConfiguration()
    require current.isOk
    check current.value.bufferSize == 256
    check current.value.sampleRate == 96_000
    check backend.acknowledgeConfigurationChange().isOk
    check not backend.configurationChangePending

  test "process callback copies buffers and deactivation rejects late work":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk
    require backend.configure(oneInOneOutPlan(), fpmCopyInput).isOk
    require backend.activate().isOk

    for frame in 0'u32 ..< 8'u32:
      controls.setAudioSample(0, frame, cfloat(frame + 10'u32))
    check controls.invokeProcess(8) == 0
    for frame in 0'u32 ..< 8'u32:
      check controls.audioSample(1, frame) == cfloat(frame + 10'u32)
    let processed = backend.notifications()
    check processed.processCycles == 1
    check processed.processFrames == 8
    check processed.processErrors == 0

    require backend.deactivate().isOk
    check backend.state == jbsConfigured
    check controls.isActive() == 0
    check controls.invokeProcess(8) == -100
    check controls.forceProcess(8) == 0
    let quiesced = backend.notifications()
    check quiesced.processCycles == 1
    check quiesced.lateProcessCalls == 1
    check backend.deactivate().isOk

  test "suspension waits for an in-flight process callback to quiesce":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk
    require backend.configure(oneInOneOutPlan(), fpmSilence).isOk
    require backend.activate().isOk
    require controls.beginBlockedProcess(64) == 0

    var attempt = SuspendThreadAttempt(backend: addr backend)
    var worker: Thread[ptr SuspendThreadAttempt]
    createThread(worker, suspendBackendOnThread, addr attempt)
    for ignored in 0 ..< 100:
      discard ignored
      if attempt.started.loadAcquire() != 0'u32:
        break
      sleep(1)
    check attempt.started.loadAcquire() != 0'u32
    for ignored in 0 ..< 100:
      discard ignored
      if not backend.processCallbacksEnabled:
        break
      sleep(1)
    check not backend.processCallbacksEnabled

    check controls.releaseBlockedProcess() == 0
    joinThread(worker)
    check attempt.succeeded
    check backend.state == jbsActive
    require backend.activate().isOk

  test "activation and deactivation failures are typed and cleanup continues":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    require backend.configure(oneInOneOutPlan(), fpmSilence).isOk

    controls.setActivateStatus(41)
    let failedActivation = backend.activate()
    check not failedActivation.isOk
    check failedActivation.error.kind == hekJackActivation
    check backend.state == jbsConfigured

    controls.setActivateStatus(0)
    require backend.activate().isOk
    controls.setDeactivateStatus(42)
    let failedDeactivation = backend.deactivate()
    check not failedDeactivation.isOk
    check failedDeactivation.error.kind == hekJackDeactivation
    check backend.state == jbsActive

    let closed = backend.close()
    check not closed.isOk
    check closed.error.kind == hekJackDeactivation
    check backend.state == jbsClosed
    check backend.close().isOk
    check controls.closeCount() == 1
    check controls.callbacksCleared() == 1

  test "client-close failure retains ownership for an explicit retry":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)

    controls.setCloseStatus(55)
    let failedClose = backend.close()
    check not failedClose.isOk
    check failedClose.error.kind == hekJackClientClose
    check backend.isOpen
    check controls.callbacksCleared() == 0

    controls.setCloseStatus(0)
    check backend.close().isOk
    check backend.state == jbsClosed
    check controls.closeCount() == 2
    check controls.callbacksCleared() == 1

  test "moving an active backend preserves every callback pointer lifetime":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var original = move(opened.value)
    require original.configure(oneInOneOutPlan(), fpmDeterministic).isOk
    require original.activate().isOk

    var moved = move(original)
    defer:
      doAssert moved.close().isOk
    check controls.invokeProcess(4) == 0
    check controls.audioSample(1, 0) == 1_000.0
    check controls.audioSample(1, 3) == 1_003.0
    check moved.notifications().processCycles == 1

  test "repeated open configure activate deactivate close is stable":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk

    for iteration in 1 .. 20:
      controls.reset()
      var opened = openJackBackend(fakeConfig("cycle-" & $iteration))
      require opened.isOk
      var backend = move(opened.value)
      require backend.configure(oneInOneOutPlan(uint64(iteration)),
        fpmSilence).isOk
      require backend.activate().isOk
      require backend.deactivate().isOk
      require backend.close().isOk
      check controls.closeCount() == 1
      check controls.callbacksCleared() == 1
