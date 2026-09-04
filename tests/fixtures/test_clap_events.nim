import std/[math, unittest]

import pluginhost/app/audio_slice
import pluginhost/clap/[event_bridge, ffi, loader]
import pluginhost/domain/[errors, plugin_catalog, result]
import pluginhost/jack/backend
import pluginhost/platform/linux/dynlib
import ./clap/event_fixture_api
import ./jack/fixture_api

type OpenedEventSlice = tuple[
  slice: InternalAudioSlice,
  fixture: EventFixtureApi,
  observer: DynamicLibrary,
]

proc fakeConfig(name: string): JackBackendOpenConfig =
  initJackBackendOpenConfig(
    name, noStartServer = true, libraryPath = jackFakeFixturePath())

proc openControls(): FakeJackControls =
  var opened = openFakeJackControls()
  require opened.isOk
  result = move(opened.value)
  result.reset()

proc openEventSlice(variant: string): OpenedEventSlice =
  let path = eventFixturePath(variant)
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
    move(module), move(selected.value), fakeConfig("event-" & variant))
  require opened.isOk
  (move(opened.value), fixture, move(observer))

proc addMidi(controls: FakeJackControls; port: int; time: uint32;
             bytes: openArray[uint8]): cint =
  if bytes.len == 0:
    return -1
  controls.addMidiEvent(
    cint(port), time, cast[ptr uint8](unsafeAddr bytes[0]), uint32(bytes.len))

suite "fixed-capacity JACK and CLAP event bridge":
  test "raw MIDI and SysEx are globally ordered and echoed without retained pointers":
    var controls = openControls()
    var opened = openEventSlice("events_raw")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    check slice.jackBackend().realizedPortCount == 4
    require slice.start().isOk
    check controls.addMidi(0, 2, [0x90'u8, 60'u8, 0'u8]) == 0
    check controls.addMidi(0, 10, [0xf0'u8, 1'u8, 2'u8, 0xf7'u8]) == 0
    check controls.addMidi(1, 2, [0xb1'u8, 7'u8, 99'u8]) == 0
    check controls.addMidi(1, 5, [0x81'u8, 61'u8, 64'u8]) == 0
    controls.setMidiLostEvents(0, 3)

    check controls.invokeProcess(64) == 0
    check fixture.observedCount() == 4
    for index, expected in [
      (time: 2'u32, port: 0'i32, kind: uint32(ClapEventTypeMidi)),
      (time: 2'u32, port: 1'i32, kind: uint32(ClapEventTypeMidi)),
      (time: 5'u32, port: 1'i32, kind: uint32(ClapEventTypeMidi)),
      (time: 10'u32, port: 0'i32, kind: uint32(ClapEventTypeMidiSysex)),
    ]:
      check fixture.time(uint32(index)) == expected.time
      check fixture.port(uint32(index)) == expected.port
      check fixture.eventType(uint32(index)) == expected.kind
      check (fixture.flags(uint32(index)) and ClapEventIsLive) != 0
    check fixture.eventByte(0, 0) == 0x90
    check fixture.eventByte(0, 2) == 0
    check fixture.address(3) == controls.midiEventAddress(0, 1)
    check fixture.eventByte(3, 0) == 0xf0
    check fixture.eventByte(3, 3) == 0xf7

    check controls.midiEventCount(2) == 2
    check controls.midiEventTime(2, 0) == 2
    check controls.midiEventTime(2, 1) == 10
    check controls.midiEventCount(3) == 2
    check controls.midiEventTime(3, 0) == 2
    check controls.midiEventTime(3, 1) == 5
    let metrics = slice.takeEventMetrics()
    check metrics.acceptedInput == 4
    check metrics.droppedInput == 0
    check metrics.invalidInput == 0
    check metrics.jackLostInput == 3
    check metrics.acceptedOutput == 4
    check metrics.droppedOutput == 0
    check fixture.outputAccepted() == 4
    check fixture.contractFailures() == 0
    fixture.setProcessStatus(ClapProcessError)
    check controls.invokeProcess(64) == 1
    check controls.midiEventCount(2) == 0
    check controls.midiEventCount(3) == 0
    check slice.stop().isOk
    check controls.forceProcess(64) == 0
    check controls.midiEventCount(2) == 0
    check controls.midiEventCount(3) == 0

  test "CLAP-only ports translate note velocity-zero and polyphonic pressure":
    var controls = openControls()
    var opened = openEventSlice("events_clap")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    require slice.start().isOk
    check controls.addMidi(0, 1, [0x90'u8, 60'u8, 0'u8]) == 0
    check controls.addMidi(0, 2, [0x92'u8, 61'u8, 127'u8]) == 0
    check controls.addMidi(0, 3, [0x82'u8, 61'u8, 64'u8]) == 0
    check controls.addMidi(0, 4, [0xa2'u8, 61'u8, 32'u8]) == 0
    check controls.addMidi(0, 5, [0xb2'u8, 1'u8, 2'u8]) == 0
    check controls.addMidi(0, 6, [0xf0'u8, 1'u8, 0xf7'u8]) == 0
    check controls.invokeProcess(64) == 0

    check fixture.observedCount() == 4
    check fixture.eventType(0) == uint32(ClapEventTypeNoteOff)
    check fixture.eventType(1) == uint32(ClapEventTypeNoteOn)
    check fixture.eventType(2) == uint32(ClapEventTypeNoteOff)
    check fixture.eventType(3) == uint32(ClapEventTypeNoteExpression)
    check fixture.channel(1) == 2
    check fixture.key(1) == 61
    check abs(fixture.value(1) - 1.0) < 0.000001
    check fixture.expression(3) == ClapNoteExpressionPressure
    check abs(fixture.value(3) - (32.0 / 127.0)) < 0.000001

    check controls.midiEventCount(1) == 3
    check controls.midiEventByte(1, 0, 0) == 0x80
    check controls.midiEventByte(1, 0, 2) == 0
    check controls.midiEventByte(1, 1, 0) == 0x92
    check controls.midiEventByte(1, 1, 2) == 127
    check controls.midiEventByte(1, 2, 0) == 0x82
    let metrics = slice.takeEventMetrics()
    check metrics.acceptedInput == 4
    check metrics.droppedInput == 2
    check metrics.invalidInput == 2
    check metrics.acceptedOutput == 3
    check fixture.outputRejected() == 0
    check fixture.contractFailures() == 0

  test "malformed input status size timestamp order and retrieval are dropped":
    var controls = openControls()
    var opened = openEventSlice("events_raw")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    require slice.start().isOk
    check controls.addMidi(0, 1, [0x40'u8]) == 0
    check controls.addMidi(0, 2, [0x90'u8, 60'u8, 100'u8]) == 0
    check controls.addMidi(0, 3, [0x90'u8, 61'u8, 100'u8]) == 0
    check controls.addMidi(0, 4, [0x90'u8, 62'u8, 100'u8]) == 0
    check controls.addMidi(0, 5, [0x90'u8, 63'u8, 100'u8]) == 0
    check controls.addMidi(0, 6, [0x90'u8, 64'u8, 100'u8]) == 0
    check controls.addMidi(0, 7, [0x90'u8, 0x80'u8, 100'u8]) == 0
    controls.setMidiEventSize(0, 1, 2)
    controls.setMidiEventTime(0, 2, 64)
    controls.setMidiGetFailure(0, 3)
    controls.setMidiEventTime(0, 4, 0)
    check controls.invokeProcess(64) == 0

    check fixture.observedCount() == 1
    check fixture.time(0) == 6
    check fixture.eventByte(0, 1) == 64
    let metrics = slice.takeEventMetrics()
    check metrics.acceptedInput == 1
    check metrics.droppedInput == 6
    check metrics.malformedInput == 3
    check metrics.invalidInput == 3
    check fixture.contractFailures() == 0

  test "exact input capacity drops one excess event and recovers next cycle":
    var controls = openControls()
    var opened = openEventSlice("events_raw")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    require slice.start().isOk
    let message = [0x90'u8, 64'u8, 100'u8]
    for index in 0'u32 .. ClapInputEventCapacity:
      check controls.addMidi(0, 0, message) == 0
    check controls.invokeProcess(64) == 0
    check fixture.observedCount() == ClapInputEventCapacity
    let full = slice.takeEventMetrics()
    check full.acceptedInput == ClapInputEventCapacity
    check full.inputCapacityDrops == 1
    check full.droppedInput == 1
    check full.invalidInput == 0
    check full.acceptedOutput == ClapInputEventCapacity

    controls.clearMidiEvents(0)
    check controls.addMidi(0, 7, message) == 0
    check controls.invokeProcess(64) == 0
    check controls.midiEventCount(2) == 1
    check controls.midiEventTime(2, 0) == 7
    let recovered = slice.takeEventMetrics()
    check recovered.acceptedInput == 1
    check recovered.inputCapacityDrops == 0
    check recovered.acceptedOutput == 1
    check fixture.processCount() == 2
    check fixture.contractFailures() == 0

  test "output capacity rejection is bounded and recovers after buffer clear":
    var controls = openControls()
    var opened = openEventSlice("events_raw")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    require slice.start().isOk
    controls.setMidiCapacity(2, 2)
    check controls.addMidi(0, 1, [0x90'u8, 60'u8, 100'u8]) == 0
    check controls.invokeProcess(64) == 0
    check controls.midiEventCount(2) == 0
    let rejected = slice.takeEventMetrics()
    check rejected.acceptedInput == 1
    check rejected.acceptedOutput == 0
    check rejected.droppedOutput == 1
    check rejected.outputCapacityDrops == 1
    check rejected.invalidOutput == 0

    controls.clearMidiEvents(0)
    controls.setMidiCapacity(2, 64)
    check controls.addMidi(0, 2, [0x80'u8, 60'u8, 64'u8]) == 0
    check controls.invokeProcess(64) == 0
    check controls.midiEventCount(2) == 1
    check controls.midiEventTime(2, 0) == 2
    let recovered = slice.takeEventMetrics()
    check recovered.acceptedOutput == 1
    check recovered.outputCapacityDrops == 0

  test "malformed and unsupported plugin output is rejected without poisoning order":
    var controls = openControls()
    var opened = openEventSlice("events_malformed_output")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    require slice.start().isOk
    check controls.invokeProcess(64) == 0
    check fixture.outputAccepted() == 3
    check fixture.outputRejected() == 6
    check controls.midiEventCount(0) == 2
    check controls.midiEventTime(0, 0) == 5
    check controls.midiEventTime(0, 1) == 8
    check controls.midiEventSize(0, 1) == 4
    check controls.midiEventByte(0, 1, 0) == 0xf0
    check controls.midiEventByte(0, 1, 1) == 1
    check controls.midiEventByte(0, 1, 2) == 2
    check controls.midiEventByte(0, 1, 3) == 0xf7
    let metrics = slice.takeEventMetrics()
    check metrics.acceptedOutput == 2
    check metrics.droppedOutput == 6
    check metrics.invalidOutput == 6
    check metrics.outputCapacityDrops == 0
    check fixture.contractFailures() == 0

  test "valid CLAP NOTE_END is consumed without a JACK MIDI duplicate":
    var controls = openControls()
    var opened = openEventSlice("events_note_end")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    require slice.start().isOk
    check controls.invokeProcess(64) == 0
    check fixture.outputAccepted() == 1
    check fixture.outputRejected() == 0
    check controls.midiEventCount(0) == 0
    let metrics = slice.takeEventMetrics()
    check metrics.acceptedOutput == 1
    check metrics.droppedOutput == 0
    check metrics.invalidOutput == 0
    check metrics.outputCapacityDrops == 0
    check fixture.contractFailures() == 0

  test "MIDI2-only note ports fail explicitly and release acquired resources":
    var controls = openControls()
    let path = eventFixturePath("events_midi2_only")
    var observerResult = openDynamicLibrary(path)
    require observerResult.isOk
    var observer = move(observerResult.value)
    let fixture = eventFixtureApi(observer)
    fixture.reset()
    defer:
      doAssert observer.close().isOk
      doAssert controls.close().isOk
    var moduleResult = openClapModule(path)
    require moduleResult.isOk
    var module = move(moduleResult.value)
    let catalog = module.readCatalog()
    require catalog.isOk
    var selected = catalog.value.selectDescriptor(PluginSelector(
      kind: pskImplicitSingle))
    require selected.isOk

    let opened = openInternalAudioSlice(
      move(module), move(selected.value), fakeConfig("event-midi2-only"))
    check not opened.isOk
    check opened.error.kind == hekClapProcess
    check controls.currentPortCount() == 0
    check controls.closeCount() == 1
    check fixture.destroyCount() == 1
