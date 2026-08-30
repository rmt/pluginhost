import std/unittest

import pluginhost/domain/port_plan
import pluginhost/jack/[backend, ffi]
import pluginhost/rt/engine
import ../fixtures/jack/fixture_api

when not defined(nimAllocStats):
  {.error: "JACK callback safety tests require -d:nimAllocStats".}

proc audioPlan(): PortPlan =
  newPortPlan(
    portPlanVersion(1),
    @[],
    @[
      AudioChannelPlan(direction: pdInput, shortName: "audio_in_1"),
      AudioChannelPlan(direction: pdOutput, shortName: "audio_out_1"),
    ],
    @[],
  )

suite "JACK callback and fake-engine safety":
  test "first process call on a C-created thread has no Nim allocation":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(initJackBackendOpenConfig(
      "rt-probe",
      noStartServer = true,
      libraryPath = jackFakeFixturePath(),
    ))
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk
    require backend.configure(audioPlan(), fpmDeterministic).isOk
    require backend.activate().isOk

    var callbackResult = -1.cint
    let before = getAllocStats()
    let status = controls.invokeProcessOnThread(
      128'u32, 0.cint, addr callbackResult)
    let after = getAllocStats()

    check status == 0
    check callbackResult == 0
    check before == after
    check controls.audioSample(1, 0) == 1_000.0
    check controls.audioSample(1, 127) == 1_127.0
    let snapshot = backend.notifications()
    check snapshot.processCycles == 1
    check snapshot.processErrors == 0

  test "all notification callbacks remain allocation-free under repetition":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(initJackBackendOpenConfig(
      "notification-probe",
      noStartServer = true,
      libraryPath = jackFakeFixturePath(),
    ))
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk
    require backend.configure(audioPlan(), fpmSilence).isOk

    let before = getAllocStats()
    var iteration = 0
    while iteration < 10_000:
      controls.invokeXrun()
      controls.invokeFreewheel(cint(iteration and 1))
      controls.invokeBufferSize(128)
      controls.invokeSampleRate(48_000)
      controls.invokeLatency(JackPlaybackLatency)
      inc iteration
    controls.invokeShutdown(JackServerError, "allocation-free shutdown")
    let after = getAllocStats()

    check before == after
    let snapshot = backend.notifications()
    check snapshot.xrunCount == 10_000
    check snapshot.freewheelCount == 10_000
    check snapshot.bufferSizeCount == 10_001
    check snapshot.sampleRateCount == 10_001
    check snapshot.latencyCount == 10_000
    check snapshot.shutdownReason == "allocation-free shutdown"
