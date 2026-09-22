import std/unittest

import pluginhost/app/audio_slice
import pluginhost/clap/[event_bridge, loader]
import pluginhost/domain/[plugin_catalog, port_plan, result]
import pluginhost/jack/backend
import pluginhost/platform/linux/dynlib
import pluginhost/rt/[engine, midi_io, role_guard]
import pluginhost/vst3/event_bridge as vst3_event_bridge
import pluginhost/vst3/ffi
import ../fixtures/clap/event_fixture_api
import ../fixtures/jack/fixture_api

when not defined(nimAllocStats):
  {.error: "event bridge safety tests require -d:nimAllocStats".}

var vst3OutputStorage: array[128, uint8]

proc vst3Clear(context, buffer: pointer) {.cdecl, gcsafe, raises: [].} =
  discard context
  discard buffer

proc vst3Reserve(context, buffer: pointer; time, size: uint32):
    ptr UncheckedArray[uint8] {.cdecl, gcsafe, raises: [].} =
  discard context
  discard buffer
  discard time
  if size > uint32(vst3OutputStorage.len):
    nil
  else:
    cast[ptr UncheckedArray[uint8]](addr vst3OutputStorage[0])

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
suite "VST3 MIDI process-path safety":
  test "embedded event callbacks stay allocation-free":
    var plan = newPortPlan(portPlanVersion(1), @[], @[], @[
      NotePortPlan(index: 0, id: 0, direction: pdOutput, name: "MIDI",
        supportedDialects: {ndMidi}, preferredDialect: ndMidi,
        shortName: "midi_out_1")])
    var role: AudioRoleGuard
    role.initAudioRoleGuard()
    require tryEnterAudioRole(addr role)
    var opened = vst3_event_bridge.newVst3EventBridge(nil, plan, addr role,
      "rt-vst3", "fixture")
    require opened.isOk
    var bridge = opened.value
    defer:
      vst3_event_bridge.endVst3EventCycle(bridge)
      vst3_event_bridge.closeVst3EventBridge(bridge)
      discard leaveAudioRole(addr role)
    var engine: RtEngine
    engine.noteOutputCount = 1
    engine.noteOutputBuffers[0] = cast[pointer](addr vst3OutputStorage[0])
    engine.midiIo = RtMidiIo(context: cast[pointer](addr vst3OutputStorage[0]),
      clear: vst3Clear, reserve: vst3Reserve)
    require vst3_event_bridge.beginVst3EventCycle(bridge, addr engine, 64, addr role)
    let output = vst3_event_bridge.vst3EventOutputInterface(bridge)
    require output != nil
    var event = Vst3Event(busIndex: 0, sampleOffset: 7,
      eventType: Vst3EventTypeNoteOn, flags: Vst3EventFlagIsLive)
    let note = cast[ptr Vst3NoteOnEvent](addr event.payload[0])
    note[] = Vst3NoteOnEvent(channel: 0, pitch: 60, tuning: 0.0,
      velocity: 1.0, length: 0, noteId: Vst3NoteIdNone)
    let before = getAllocStats()
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    let after = getAllocStats()
    check before == after
    check vst3OutputStorage[0] == 0x90'u8
    check vst3OutputStorage[1] == 60'u8
    check vst3OutputStorage[2] == 127'u8
    event.sampleOffset = 8
    event.eventType = Vst3EventTypeData
    var sysex = [0xF0'u8, 0xF8]
    let data = cast[ptr Vst3DataEvent](addr event.payload[0])
    data[] = Vst3DataEvent(size: 2, dataType: Vst3DataTypeMidiSysEx,
      bytes: addr sysex[0])
    let beforeMalformed = getAllocStats()
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) ==
      Vst3InvalidArgument
    let afterMalformed = getAllocStats()
    check beforeMalformed == afterMalformed
    bridge.outputCount = Vst3EventBridgeMaxEvents
    event.sampleOffset = 9
    let beforeFull = getAllocStats()
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) ==
      Vst3ResultFalse
    let afterFull = getAllocStats()
    check beforeFull == afterFull
    vst3_event_bridge.endVst3EventCycle(bridge)
    let metrics = vst3_event_bridge.vst3EventMetrics(bridge)
    check metrics.acceptedOutput == 1'u64
    check metrics.invalidOutput == 1'u64
    check metrics.outputCapacityDrops == 1'u64
