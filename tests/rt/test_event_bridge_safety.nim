import std/unittest

import pluginhost/app/audio_slice
import pluginhost/clap/[event_bridge, loader]
import pluginhost/domain/[plugin_catalog, result]
import pluginhost/jack/backend
import pluginhost/platform/linux/dynlib
import ../fixtures/clap/event_fixture_api
import ../fixtures/jack/fixture_api

when not defined(nimAllocStats):
  {.error: "event bridge safety tests require -d:nimAllocStats".}

suite "CLAP event process-path safety":
  test "success overflow and malformed paths allocate no Nim memory":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
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
      move(module), move(selected.value), initJackBackendOpenConfig(
        "rt-events", noStartServer = true,
        libraryPath = jackFakeFixturePath()))
    require opened.isOk
    var slice = move(opened.value)
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk
    require slice.start().isOk

    var message = [0x90'u8, 60'u8, 100'u8]
    for index in 0'u32 .. ClapInputEventCapacity:
      require controls.addMidiEvent(
        0, 0, addr message[0], uint32(message.len)) == 0
    var callbackResult = -1.cint
    let beforeFull = getAllocStats()
    let fullStatus = controls.invokeProcessOnThread(
      64, 0, addr callbackResult)
    let afterFull = getAllocStats()
    check fullStatus == 0
    check callbackResult == 0
    check beforeFull == afterFull
    let fullMetrics = slice.takeEventMetrics()
    check fullMetrics.acceptedInput == ClapInputEventCapacity
    check fullMetrics.inputCapacityDrops == 1

    controls.clearMidiEvents(0)
    require controls.addMidiEvent(0, 1, addr message[0], 3) == 0
    require controls.addMidiEvent(0, 2, addr message[0], 3) == 0
    controls.setMidiEventSize(0, 0, 2)
    controls.setMidiGetFailure(0, 1)
    callbackResult = -1
    let beforeMalformed = getAllocStats()
    let malformedStatus = controls.invokeProcessOnThread(
      64, 0, addr callbackResult)
    let afterMalformed = getAllocStats()
    check malformedStatus == 0
    check callbackResult == 0
    check beforeMalformed == afterMalformed
    let malformedMetrics = slice.takeEventMetrics()
    check malformedMetrics.acceptedInput == 0
    check malformedMetrics.droppedInput == 2
    check malformedMetrics.malformedInput == 1
    check malformedMetrics.invalidInput == 1
