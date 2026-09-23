import std/[math, os, unittest]

import pluginhost/app/[vst3_audio_slice, vst3_plugin_services]
import pluginhost/domain/[errors, port_plan, result]
import pluginhost/jack/backend
import pluginhost/platform/linux/dynlib
import pluginhost/rt/[engine, midi_io, role_guard]
import pluginhost/vst3/[audio_process, event_bridge, ffi, host_context, module,
  parameter_transport, uid]
import ./jack/fixture_api

const V3ClassId = "102132435465768798A9BACBDCEDFEFF"

type
  U32Proc = proc(): uint32 {.cdecl, gcsafe, raises: [].}
  U32IndexedProc = proc(index: int32): uint32 {.cdecl, gcsafe, raises: [].}
  I32IndexedProc = proc(index: int32): int32 {.cdecl, gcsafe, raises: [].}
  F64IndexedProc = proc(index: int32): float64 {.cdecl, gcsafe, raises: [].}
  EmitEditProc = proc(value: float64) {.cdecl, gcsafe, raises: [].}

proc fixtureDirectory(): string =
  result = getEnv("PLUGINHOST_VST3_V3_FIXTURE_DIR")
  doAssert result.len > 0

proc fixturePath(name = "midi"): string =
  fixtureDirectory() / (name & ".vst3")

proc fixtureBinary(name = "midi"): string =
  fixturePath(name) / "Contents" / Vst3ArchitectureDir / (name & ".so")

proc resolveU32(library: DynamicLibrary; name: string): U32Proc =
  let resolved = resolveSymbol[U32Proc](library, name)
  doAssert resolved.isOk
  resolved.value

proc resolveU32Indexed(library: DynamicLibrary; name: string): U32IndexedProc =
  let resolved = resolveSymbol[U32IndexedProc](library, name)
  doAssert resolved.isOk
  resolved.value

proc resolveI32Indexed(library: DynamicLibrary; name: string): I32IndexedProc =
  let resolved = resolveSymbol[I32IndexedProc](library, name)

  doAssert resolved.isOk
  resolved.value

proc resolveF64Indexed(library: DynamicLibrary; name: string): F64IndexedProc =
  let resolved = resolveSymbol[F64IndexedProc](library, name)
  doAssert resolved.isOk
  resolved.value

proc resolveEmitEdit(library: DynamicLibrary; name: string): EmitEditProc =
  let resolved = resolveSymbol[EmitEditProc](library, name)
  doAssert resolved.isOk
  resolved.value
var inputTimes: array[8, uint32]
var inputSizes: array[8, uint32]
var inputPayloads: array[8, array[4, uint8]]
var inputCountValue: uint32
var outputBytes: array[64, uint8]

proc inputCount(context, portBuffer: pointer): uint32 {.
    cdecl, gcsafe, raises: [].} =
  discard context
  discard portBuffer
  inputCountValue

proc inputGet(context, portBuffer: pointer; index: uint32;
              event: ptr RtMidiEventView): bool {.
    cdecl, gcsafe, raises: [].} =
  discard context
  discard portBuffer
  if event == nil or index >= inputCountValue:
    return false
  event[] = RtMidiEventView(time: inputTimes[int(index)],
    size: inputSizes[int(index)],
    data: cast[ptr UncheckedArray[uint8]](addr inputPayloads[int(index)][0]))
  true

proc addMidi(controls: FakeJackControls; port: int; time: uint32;
             bytes: openArray[uint8]): cint =
  if bytes.len == 0: return -1
  controls.addMidiEvent(cint(port), time,
    cast[ptr uint8](unsafeAddr bytes[0]), uint32(bytes.len))
var reserveEnabled = true

proc fakeClear(context, buffer: pointer) {.cdecl, gcsafe, raises: [].} =
  discard context
  discard buffer

proc fakeReserve(context, buffer: pointer; time, size: uint32):
    ptr UncheckedArray[uint8] {.cdecl, gcsafe, raises: [].} =
  discard context
  discard buffer
  discard time
  if not reserveEnabled or size > uint32(outputBytes.len): nil
  else: cast[ptr UncheckedArray[uint8]](addr outputBytes[0])

suite "VST3 V3 event bridge":
  test "legacy MIDI note output is copied at the native bus":
    reserveEnabled = true
    inputCountValue = 0'u32
    for index in 0 ..< outputBytes.len:
      outputBytes[index] = 0'u8
    var plan = newPortPlan(portPlanVersion(1), @[], @[], @[
      NotePortPlan(index: 3, id: 3, direction: pdOutput, name: "EventOut",
        supportedDialects: {ndMidi}, preferredDialect: ndMidi,
        shortName: "midi_out_1")])
    var role: AudioRoleGuard
    role.initAudioRoleGuard()
    require tryEnterAudioRole(addr role)
    var opened = newVst3EventBridge(nil, plan, addr role, "fixture", "v3")
    require opened.isOk
    var bridge = opened.value
    defer:
      endVst3EventCycle(bridge)
      closeVst3EventBridge(bridge)
      discard leaveAudioRole(addr role)
    var rt: RtEngine
    rt.noteOutputCount = 1
    rt.noteOutputBuffers[0] = cast[pointer](addr outputBytes[0])
    rt.midiIo = RtMidiIo(context: cast[pointer](addr outputBytes[0]),
      clear: fakeClear, reserve: fakeReserve)
    require beginVst3EventCycle(bridge, addr rt, 64, addr role)
    var event = Vst3Event(busIndex: 3, sampleOffset: 7,
      eventType: Vst3EventTypeNoteOn, flags: Vst3EventFlagIsLive)
    let note = cast[ptr Vst3NoteOnEvent](addr event.payload[0])

    note[] = Vst3NoteOnEvent(channel: 2, pitch: 60, tuning: 0.0,
      velocity: 1.0, length: 0, noteId: Vst3NoteIdNone)
    let output = vst3EventOutputInterface(bridge)
    require output != nil
    var unknown = parseVst3Uid(Vst3FUnknownIid)
    require unknown.isOk
    var queried: pointer
    check output.lpVtbl.queryInterface(cast[pointer](output),
      addr unknown.value, addr queried) == Vst3ResultOk
    check queried == cast[pointer](output)
    check output.lpVtbl.addRef(queried) == 1'u32
    check output.lpVtbl.release(queried) == 1'u32
    var unsupported = parseVst3Uid(V3ClassId)
    require unsupported.isOk
    queried = cast[pointer](addr event)
    check output.lpVtbl.queryInterface(cast[pointer](output),
      addr unsupported.value, addr queried) == Vst3NoInterface
    check queried == nil
    let inputIface = vst3EventInputInterface(bridge)
    var inputQueried: pointer
    check inputIface.lpVtbl.queryInterface(cast[pointer](inputIface),
      addr unknown.value, addr inputQueried) == Vst3ResultOk
    check inputQueried == cast[pointer](inputIface)
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    check outputBytes[0] == 0x92'u8
    check outputBytes[1] == 60'u8
    check outputBytes[2] == 127'u8
    check output.lpVtbl.getEventCount(cast[pointer](output)) == 1
    var copiedEvent: Vst3Event
    check output.lpVtbl.getEvent(cast[pointer](output), 0, addr copiedEvent) ==
      Vst3ResultOk
    check copiedEvent.busIndex == event.busIndex
    check copiedEvent.sampleOffset == event.sampleOffset
    check copiedEvent.eventType == event.eventType

    event.sampleOffset = 8
    event.eventType = Vst3EventTypeNoteOff
    let noteOff = cast[ptr Vst3NoteOffEvent](addr event.payload[0])
    noteOff[] = Vst3NoteOffEvent(channel: 1, pitch: 61, velocity: 0.5,
      noteId: Vst3NoteIdNone, tuning: 0.0)
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    check outputBytes[0] == 0x81'u8
    check outputBytes[1] == 61'u8
    check outputBytes[2] == 64'u8

    event.sampleOffset = 9
    event.eventType = Vst3EventTypePolyPressure
    let pressure = cast[ptr Vst3PolyPressureEvent](addr event.payload[0])
    pressure[] = Vst3PolyPressureEvent(channel: 1, pitch: 62, pressure: 0.25,
      noteId: Vst3NoteIdNone)
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    check outputBytes[0] == 0xA1'u8
    check outputBytes[1] == 62'u8
    check outputBytes[2] == 32'u8

    event.sampleOffset = 10
    event.eventType = Vst3EventTypeLegacyMidiCcOut
    let cc = cast[ptr Vst3LegacyMidiCcOutEvent](addr event.payload[0])
    cc[] = Vst3LegacyMidiCcOutEvent(controlNumber: 1, channel: 1,
      value: 99, value2: 0)
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    check outputBytes[0] == 0xB1'u8
    check outputBytes[1] == 1'u8
    check outputBytes[2] == 99'u8

    event.sampleOffset = 11
    cc[].controlNumber = uint8(Vst3MidiControllerAftertouch)
    cc[].value = 64
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    check outputBytes[0] == 0xD1'u8
    check outputBytes[1] == 64'u8

    event.sampleOffset = 12
    cc[].controlNumber = uint8(Vst3MidiControllerPitchBend)
    cc[].value = 0
    cc[].value2 = 64
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    check outputBytes[0] == 0xE1'u8
    check outputBytes[1] == 0
    check outputBytes[2] == 64

    event.sampleOffset = 13
    cc[].controlNumber = uint8(Vst3MidiControllerProgramChange)
    cc[].value = 7
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    check outputBytes[0] == 0xC1'u8
    check outputBytes[1] == 7
    event.sampleOffset = 14
    cc[].controlNumber = uint8(Vst3MidiControllerPolyPressure)
    cc[].value = 63
    cc[].value2 = 65
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    check outputBytes[0] == 0xA1'u8
    check outputBytes[1] == 63
    check outputBytes[2] == 65
    let systemCases = [
      (controller: uint8(Vst3MidiControllerQuarterFrame), value: 1'i8,
       value2: 0'i8, expected: [0xF1'u8, 1'u8, 0'u8], size: 2),
      (controller: uint8(Vst3MidiControllerSongSelect), value: 2'i8,
       value2: 0'i8, expected: [0xF3'u8, 2'u8, 0'u8], size: 2),
      (controller: uint8(Vst3MidiControllerSongPointer), value: 3'i8,
       value2: 4'i8, expected: [0xF2'u8, 3'u8, 4'u8], size: 3),
      (controller: uint8(Vst3MidiControllerCableSelect), value: 5'i8,
       value2: 0'i8, expected: [0xF5'u8, 0'u8, 0'u8], size: 1),
      (controller: uint8(Vst3MidiControllerTuneRequest), value: 0'i8,
       value2: 0'i8, expected: [0xF6'u8, 0'u8, 0'u8], size: 1),
      (controller: uint8(Vst3MidiControllerClockStart), value: 0'i8,
       value2: 0'i8, expected: [0xFA'u8, 0'u8, 0'u8], size: 1),
      (controller: uint8(Vst3MidiControllerClockContinue), value: 0'i8,
       value2: 0'i8, expected: [0xFB'u8, 0'u8, 0'u8], size: 1),
      (controller: uint8(Vst3MidiControllerClockStop), value: 0'i8,
       value2: 0'i8, expected: [0xFC'u8, 0'u8, 0'u8], size: 1),
      (controller: uint8(Vst3MidiControllerActiveSensing), value: 0'i8,
       value2: 0'i8, expected: [0xFE'u8, 0'u8, 0'u8], size: 1),
    ]
    for index, item in systemCases:
      event.sampleOffset = int32(15 + index)
      cc[].controlNumber = item.controller
      cc[].value = item.value
      cc[].value2 = item.value2
      check output.lpVtbl.addEvent(cast[pointer](output), addr event) ==
        Vst3ResultOk
      for byteIndex in 0 ..< item.size:
        check outputBytes[byteIndex] == item.expected[byteIndex]


    var sysexBytes = [0xF0'u8, 1, 2, 0xF7]
    event.sampleOffset = 30
    event.eventType = Vst3EventTypeData
    let data = cast[ptr Vst3DataEvent](addr event.payload[0])
    data[] = Vst3DataEvent(size: 4, dataType: Vst3DataTypeMidiSysEx,
      bytes: addr sysexBytes[0])
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    check outputBytes[0] == 0xF0'u8
    check outputBytes[1] == 1'u8
    check outputBytes[2] == 2'u8
    check outputBytes[3] == 0xF7'u8
    var copiedSysEx: Vst3Event
    let copiedSysExIndex =
      output.lpVtbl.getEventCount(cast[pointer](output)) - 1
    check output.lpVtbl.getEvent(cast[pointer](output), copiedSysExIndex,
      addr copiedSysEx) == Vst3ResultOk
    let copiedData = cast[ptr Vst3DataEvent](addr copiedSysEx.payload[0])
    check copiedData.bytes != data.bytes
    sysexBytes[1] = 0xF8
    check cast[ptr UncheckedArray[uint8]](copiedData.bytes)[1] == 1'u8

    event.sampleOffset = 29
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) ==
      Vst3InvalidArgument
    event.sampleOffset = 30
    event.eventType = Vst3EventTypeData
    data[].size = 2
    data[].bytes = addr sysexBytes[0]
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) ==
      Vst3InvalidArgument
    data[].size = Vst3EventBridgeMaxSysExBytes + 1
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) ==
      Vst3ResultFalse
    event.sampleOffset = 31
    event.eventType = 0x7FFF'u16
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) ==
      Vst3NotImplemented
    endVst3EventCycle(bridge)
    let metrics = vst3EventMetrics(bridge)
    check metrics.invalidOutput == 2'u64
    check metrics.unsupportedOutput == 1'u64
    check metrics.outputCapacityDrops == 1'u64
    reserveEnabled = false
    require beginVst3EventCycle(bridge, addr rt, 64, addr role)
    event.sampleOffset = 1
    event.eventType = Vst3EventTypeNoteOn
    let recoveryNote = cast[ptr Vst3NoteOnEvent](addr event.payload[0])
    recoveryNote[] = Vst3NoteOnEvent(channel: 0, pitch: 62, tuning: 0.0,
      velocity: 1.0, length: 0, noteId: Vst3NoteIdNone)
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) ==
      Vst3ResultFalse
    endVst3EventCycle(bridge)
    let failed = vst3EventMetrics(bridge)
    check failed.acceptedOutput == 0'u64
    check failed.outputCapacityDrops == 1'u64
    reserveEnabled = true
    require beginVst3EventCycle(bridge, addr rt, 64, addr role)
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    endVst3EventCycle(bridge)
    let recovered = vst3EventMetrics(bridge)
    check recovered.acceptedOutput == 1'u64
    check recovered.droppedOutput == 0'u64
  test "output ordering is enforced independently per native bus":
    reserveEnabled = true
    var plan = newPortPlan(portPlanVersion(1), @[], @[], @[
      NotePortPlan(index: 0, id: 0, direction: pdOutput, name: "First",
        supportedDialects: {ndMidi}, preferredDialect: ndMidi,
        shortName: "midi_out_1"),
      NotePortPlan(index: 1, id: 1, direction: pdOutput, name: "Second",
        supportedDialects: {ndMidi}, preferredDialect: ndMidi,
        shortName: "midi_out_2")])
    var role: AudioRoleGuard
    role.initAudioRoleGuard()
    require tryEnterAudioRole(addr role)
    var opened = newVst3EventBridge(nil, plan, addr role, "fixture", "v3")
    require opened.isOk
    var bridge = opened.value
    defer:
      endVst3EventCycle(bridge)
      closeVst3EventBridge(bridge)
      discard leaveAudioRole(addr role)
    var rt: RtEngine
    rt.noteOutputCount = 2
    rt.noteOutputBuffers[0] = cast[pointer](addr outputBytes[0])
    rt.noteOutputBuffers[1] = cast[pointer](addr outputBytes[0])
    rt.midiIo = RtMidiIo(context: cast[pointer](addr outputBytes[0]),
      clear: fakeClear, reserve: fakeReserve)
    require beginVst3EventCycle(bridge, addr rt, 64, addr role)
    var event = Vst3Event(busIndex: 0, sampleOffset: 20,
      eventType: Vst3EventTypeNoteOn)
    let note = cast[ptr Vst3NoteOnEvent](addr event.payload[0])
    note[] = Vst3NoteOnEvent(channel: 0, pitch: 60, velocity: 1.0,
      noteId: Vst3NoteIdNone)
    let output = vst3EventOutputInterface(bridge)
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    event.busIndex = 1
    event.sampleOffset = 10
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) == Vst3ResultOk
    event.sampleOffset = 9
    check output.lpVtbl.addEvent(cast[pointer](output), addr event) ==
      Vst3InvalidArgument
  test "parameter edit and observation capacities recover after drops":
    var transport = newVst3ParameterTransport()
    require transport != nil
    defer:
      closeVst3ParameterTransport(transport)
    let edit = Vst3ParameterEditRecord(kind: v3pekPerform, id: 1,
      value: 0.5)
    for _ in 0 ..< int(Vst3ParameterTransportCapacity):
      check enqueueVst3ParameterEdit(transport, edit)
    check not enqueueVst3ParameterEdit(transport, edit)
    check droppedVst3ParameterEdits(transport) == 1'u64
    check droppedVst3ParameterGestures(transport) == 0'u64
    var dequeued: Vst3ParameterEditRecord
    check dequeueVst3ParameterEdit(transport, dequeued)
    check enqueueVst3ParameterEdit(transport, edit)
    check droppedVst3ParameterEdits(transport) == 1'u64
    check droppedVst3ParameterGestures(transport) == 1'u64
    for _ in 0 ..< int(Vst3ParameterTransportCapacity):
      check dequeueVst3ParameterEdit(transport, dequeued)
    check not dequeueVst3ParameterEdit(transport, dequeued)
    for _ in 0 ..< int(Vst3ParameterGestureCapacity):
      check dequeueVst3ParameterGesture(transport, dequeued)
    check enqueueVst3ParameterEdit(transport, edit)
    check droppedVst3ParameterGestures(transport) == 1'u64
    let observation = Vst3ParameterObservation(id: 1, value: 0.25)
    for _ in 0 ..< int(Vst3ParameterTransportValueCapacity):
      check publishVst3ParameterObservation(transport, observation)
    check not publishVst3ParameterObservation(transport, observation)
    check droppedVst3ParameterObservations(transport) == 1'u64
    var observed: Vst3ParameterObservation
    for _ in 0 ..< int(Vst3ParameterTransportValueCapacity):
      check dequeueVst3ParameterObservation(transport, observed)
    check publishVst3ParameterObservation(transport, observation)

  test "failed MIDI mapping query releases nonnil candidate":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newVst3PluginServices(newVst3HostContext())
    var observerResult = openDynamicLibrary(
      fixtureBinary("midi_mapping_failed"), keepLoaded = true)
    require observerResult.isOk
    var observer = move(observerResult.value)
    let mappingQueries = resolveU32(observer,
      "pluginhost_vst3_fixture_mapping_queries")
    let mappingAssignments = resolveU32(observer,
      "pluginhost_vst3_fixture_mapping_assignments")
    let mappingReleases = resolveU32(observer,
      "pluginhost_vst3_fixture_mapping_releases")
    var loaded = openVst3Module(fixturePath("midi_mapping_failed"))
    require loaded.isOk
    var module = move(loaded.value)
    var classIdResult = parseVst3Uid(V3ClassId)
    require classIdResult.isOk
    let config = initJackBackendOpenConfig("vst3_v3_mapping_failed",
      noStartServer = true, libraryPath = jackFakeFixturePath())
    var opened = openVst3AudioSlice(services, module, classIdResult.value, config)
    require opened.isOk
    var slice = move(opened.value)
    check mappingQueries() > 0'u32
    check mappingAssignments() == 0'u32
    check mappingReleases() > 0'u32
    require slice.close().isOk
    require observer.close().isOk
    require services.close().isOk
    require controls.close().isOk
  test "output-only event buses do not query MIDI input assignments":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newVst3PluginServices(newVst3HostContext())
    var observerResult = openDynamicLibrary(
      fixtureBinary("midi_output_only"), keepLoaded = true)
    require observerResult.isOk
    var observer = move(observerResult.value)
    let mappingQueries = resolveU32(observer,
      "pluginhost_vst3_fixture_mapping_queries")
    let mappingAssignments = resolveU32(observer,
      "pluginhost_vst3_fixture_mapping_assignments")
    var loaded = openVst3Module(fixturePath("midi_output_only"))
    require loaded.isOk
    var module = move(loaded.value)
    var classIdResult = parseVst3Uid(V3ClassId)
    require classIdResult.isOk
    let config = initJackBackendOpenConfig("vst3_v3_output_only",
      noStartServer = true, libraryPath = jackFakeFixturePath())
    var opened = openVst3AudioSlice(services, module, classIdResult.value, config)
    require opened.isOk
    var slice = move(opened.value)
    check slice.portPlan.notePortCount == 1
    check slice.portPlan.notePort(0).direction == pdOutput
    check mappingQueries() == 0'u32
    check mappingAssignments() == 0'u32
    require slice.close().isOk
    require observer.close().isOk
    require services.close().isOk
    require controls.close().isOk


  test "malformed event channel metadata is rejected":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newVst3PluginServices(newVst3HostContext())
    var loaded = openVst3Module(fixturePath("midi_bad_channels"))
    require loaded.isOk
    var module = move(loaded.value)
    var classIdResult = parseVst3Uid(V3ClassId)
    require classIdResult.isOk
    let config = initJackBackendOpenConfig("vst3_v3_bad_channels",
      noStartServer = true, libraryPath = jackFakeFixturePath())
    let opened = openVst3AudioSlice(services, module, classIdResult.value, config)
    check not opened.isOk
    check opened.error.kind == hekVst3Descriptor
    check opened.error.message == "VST3 event bus MIDI channel count is invalid"
    require services.close().isOk
    require controls.close().isOk

  test "fixture-opened MIDI mapping, DSP gain, and native event output":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newVst3PluginServices(newVst3HostContext())
    var observerResult = openDynamicLibrary(fixtureBinary(), keepLoaded = true)
    require observerResult.isOk
    var observer = move(observerResult.value)
    let mappingQueries = resolveU32(observer,
      "pluginhost_vst3_fixture_mapping_queries")
    let mappingAssignments = resolveU32(observer,
      "pluginhost_vst3_fixture_mapping_assignments")
    let mappingReleases = resolveU32(observer,
      "pluginhost_vst3_fixture_mapping_releases")
    let processCalls = resolveU32(observer,
      "pluginhost_vst3_fixture_process_calls")
    let eventAdds = resolveU32(observer,
      "pluginhost_vst3_fixture_event_adds")
    let emitEdit = resolveEmitEdit(observer,
      "pluginhost_vst3_fixture_emit_gain_edit")
    let parameterQueues = resolveU32(observer,
      "pluginhost_vst3_fixture_last_input_param_queues")
    let parameterPoints = resolveU32(observer,
      "pluginhost_vst3_fixture_last_input_param_points")
    let parameterId = resolveU32Indexed(observer,
      "pluginhost_vst3_fixture_last_input_param_id")
    let parameterOffset = resolveI32Indexed(observer,
      "pluginhost_vst3_fixture_last_input_param_offset")
    let parameterValue = resolveF64Indexed(observer,
      "pluginhost_vst3_fixture_last_input_param_value")
    var loaded = openVst3Module(fixturePath())
    require loaded.isOk
    var module = move(loaded.value)
    var classIdResult = parseVst3Uid(V3ClassId)
    require classIdResult.isOk
    let config = initJackBackendOpenConfig("vst3_v3", noStartServer = true,
      libraryPath = jackFakeFixturePath())
    var opened = openVst3AudioSlice(services, module, classIdResult.value, config)
    require opened.isOk
    var slice = move(opened.value)
    check slice.portPlan.notePortCount == 2
    check slice.portPlan.notePort(0).shortName == "midi_in_1"
    check slice.portPlan.notePort(1).shortName == "midi_out_1"
    controls.setAudioSample(0, 0, 2.0)
    check controls.addMidi(2, 3, [0xB0'u8, 1'u8, 99'u8]) == 0
    check controls.addMidi(2, 4, [0xD0'u8, 64'u8]) == 0
    check controls.addMidi(2, 5, [0xE0'u8, 0'u8, 64'u8]) == 0
    check controls.addMidi(2, 6, [0xC0'u8, 7'u8]) == 0
    check controls.invokeProcess(64) == 0
    check processCalls() == 1'u32
    check eventAdds() == 1'u32
    check parameterQueues() == 2'u32
    check parameterPoints() == 4'u32
    check parameterId(0) == 1'u32
    check parameterId(1) == 3'u32
    check parameterOffset(0) == 3
    check parameterOffset(1) == 4
    check parameterOffset(2) == 6
    check parameterOffset(3) == 5
    check abs(parameterValue(0) - (99.0 / 127.0)) < 0.000001
    check abs(parameterValue(1) - (64.0 / 127.0)) < 0.000001
    check abs(parameterValue(2) - (7.0 / 127.0)) < 0.000001
    check abs(parameterValue(3) - (8192.0 / 16383.0)) < 0.000001
    check abs(controls.audioSample(1, 0) - (2.0 * 7.0 / 127.0)) < 0.0001
    check controls.midiEventCount(3) == 1'u32
    check controls.midiEventTime(3, 0) == 7'u32
    check controls.midiEventByte(3, 0, 0) == 0x90
    check controls.midiEventByte(3, 0, 1) == 60
    check controls.midiEventByte(3, 0, 2) == 127
    let metrics = slice.takeEventMetrics()
    check metrics.acceptedInput == 4'u64
    check metrics.acceptedOutput == 1'u64
    controls.clearMidiEvents(2)

    emitEdit(0.25)
    var gestures: array[3, Vst3ParameterEditRecord]
    check slice.drainParameterGestures(
      cast[ptr UncheckedArray[Vst3ParameterEditRecord]](addr gestures[0]), 3) == 3
    check gestures[0].kind == v3pekBegin
    check gestures[1].kind == v3pekPerform
    check gestures[1].value == 0.25
    check gestures[2].kind == v3pekEnd
    controls.setAudioSample(0, 0, 2.0)
    check controls.invokeProcess(64) == 0
    check abs(controls.audioSample(1, 0) - 0.5) < 0.0001
    for _ in 0 ..< (int(Vst3ParameterTransportCapacity) + 1):
      emitEdit(0.5)
    controls.setAudioSample(0, 0, 2.0)
    check controls.invokeProcess(64) == 0
    emitEdit(0.5)
    let expectedInputDrops = uint64(
      3'u32 * (Vst3ParameterTransportCapacity + 1'u32) -
      Vst3ParameterTransportCapacity)
    let acceptedPerformEdits =
      Vst3ParameterTransportCapacity div 3'u32
    let expectedProcessDrops = uint64(acceptedPerformEdits -
      Vst3AudioProcessMaxParameterPointsPerQueue)
    let expectedGestureDrops = 3'u64
    let dropped = slice.takeEventMetrics()
    check dropped.parameterInputDrops ==
      expectedInputDrops + expectedProcessDrops + expectedGestureDrops
    let afterDropped = slice.takeEventMetrics()
    check afterDropped.parameterInputDrops == 0'u64
    require slice.close().isOk
    check mappingQueries() > 0'u32
    check mappingAssignments() > 0'u32
    check mappingReleases() > 0'u32
    require observer.close().isOk
    require services.close().isOk
    require controls.close().isOk

  test "native process failure rolls back audio and MIDI output":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newVst3PluginServices(newVst3HostContext())
    var loaded = openVst3Module(fixturePath("midi_failure"))
    require loaded.isOk
    var module = move(loaded.value)
    var classIdResult = parseVst3Uid(V3ClassId)
    require classIdResult.isOk
    let config = initJackBackendOpenConfig("vst3_v3_failure",
      noStartServer = true, libraryPath = jackFakeFixturePath())
    var opened = openVst3AudioSlice(services, module, classIdResult.value, config)
    require opened.isOk
    var slice = move(opened.value)
    controls.setAudioSample(0, 0, 2.0)
    check controls.invokeProcess(64) == 1
    check controls.audioSample(1, 0) == 0.0
    check controls.audioSample(1, 63) == 0.0
    check controls.midiEventCount(3) == 0'u32
    require slice.close().isOk
    require services.close().isOk
    require controls.close().isOk

  test "single-channel event bus routes JACK MIDI to its only channel":
    inputCountValue = 2
    inputTimes[0] = 2
    inputTimes[1] = 3
    inputSizes[0] = 3
    inputSizes[1] = 3
    inputPayloads[0] = [0x91'u8, 60, 100, 0]
    inputPayloads[1] = [0x81'u8, 60, 64, 0]
    var plan = newPortPlan(portPlanVersion(1), @[], @[], @[
      NotePortPlan(index: 0, id: 0, direction: pdInput, channelCount: 1,
        name: "Mono MIDI", supportedDialects: {ndMidi},
        preferredDialect: ndMidi, shortName: "midi_in_1")])
    var role: AudioRoleGuard
    role.initAudioRoleGuard()
    require tryEnterAudioRole(addr role)
    var opened = newVst3EventBridge(nil, plan, addr role, "fixture", "mono-midi")
    require opened.isOk
    var bridge = opened.value
    defer:
      endVst3EventCycle(bridge)
      closeVst3EventBridge(bridge)
      discard leaveAudioRole(addr role)
    var engine: RtEngine
    engine.noteInputCount = 1
    engine.noteInputBuffers[0] = cast[pointer](addr inputPayloads[0][0])
    engine.midiIo = RtMidiIo(context: cast[pointer](addr inputPayloads[0][0]),
      eventCount: inputCount, eventGet: inputGet)
    require beginVst3EventCycle(bridge, addr engine, 64, addr role)
    let input = vst3EventInputInterface(bridge)
    check input.lpVtbl.getEventCount(cast[pointer](input)) == 2
    var event: Vst3Event
    require input.lpVtbl.getEvent(cast[pointer](input), 0, addr event) ==
      Vst3ResultOk
    check event.busIndex == 0
    check event.sampleOffset == 2
    check event.eventType == Vst3EventTypeNoteOn
    check cast[ptr Vst3NoteOnEvent](addr event.payload[0])[].channel == 0
    require input.lpVtbl.getEvent(cast[pointer](input), 1, addr event) ==
      Vst3ResultOk
    check event.sampleOffset == 3
    check event.eventType == Vst3EventTypeNoteOff
    check cast[ptr Vst3NoteOffEvent](addr event.payload[0])[].channel == 0
    endVst3EventCycle(bridge)
    let metrics = vst3EventMetrics(bridge)
    check metrics.acceptedInput == 2'u64
    check metrics.malformedInput == 0'u64

  test "multichannel event bus retains channel identity and bounds":
    inputCountValue = 2
    inputTimes[0] = 2
    inputTimes[1] = 3
    inputSizes[0] = 3
    inputSizes[1] = 3
    inputPayloads[0] = [0x92'u8, 60, 100, 0]
    inputPayloads[1] = [0x93'u8, 61, 100, 0]
    var plan = newPortPlan(portPlanVersion(1), @[], @[], @[
      NotePortPlan(index: 0, id: 0, direction: pdInput, channelCount: 3,
        name: "Three-channel MIDI", supportedDialects: {ndMidi},
        preferredDialect: ndMidi, shortName: "midi_in_1")])
    var role: AudioRoleGuard
    role.initAudioRoleGuard()
    require tryEnterAudioRole(addr role)
    var opened = newVst3EventBridge(nil, plan, addr role, "fixture", "multi-midi")
    require opened.isOk
    var bridge = opened.value
    defer:
      endVst3EventCycle(bridge)
      closeVst3EventBridge(bridge)
      discard leaveAudioRole(addr role)
    var engine: RtEngine
    engine.noteInputCount = 1
    engine.noteInputBuffers[0] = cast[pointer](addr inputPayloads[0][0])
    engine.midiIo = RtMidiIo(context: cast[pointer](addr inputPayloads[0][0]),
      eventCount: inputCount, eventGet: inputGet)
    require beginVst3EventCycle(bridge, addr engine, 64, addr role)
    let input = vst3EventInputInterface(bridge)
    check input.lpVtbl.getEventCount(cast[pointer](input)) == 1
    var event: Vst3Event
    require input.lpVtbl.getEvent(cast[pointer](input), 0, addr event) ==
      Vst3ResultOk
    check event.sampleOffset == 2
    check cast[ptr Vst3NoteOnEvent](addr event.payload[0])[].channel == 2
    endVst3EventCycle(bridge)
    let metrics = vst3EventMetrics(bridge)
    check metrics.acceptedInput == 1'u64
    check metrics.malformedInput == 1'u64

  test "input notes, poly pressure, and complete split SysEx preserve order":
    reserveEnabled = true
    inputCountValue = 0'u32
    for index in 0 ..< outputBytes.len:
      outputBytes[index] = 0'u8
    var plan = newPortPlan(portPlanVersion(1), @[], @[], @[
      NotePortPlan(index: 3, id: 3, direction: pdInput, name: "In",
        supportedDialects: {ndMidi}, preferredDialect: ndMidi,
        shortName: "midi_in_1"),
      NotePortPlan(index: 7, id: 7, direction: pdOutput, name: "Out",
        supportedDialects: {ndMidi}, preferredDialect: ndMidi,
        shortName: "midi_out_1")])
    inputCountValue = 6
    inputTimes = [2'u32, 2, 3, 4, 5, 6, 0, 0]
    inputSizes = [3'u32, 3, 3, 4, 2, 2, 0, 0]
    inputPayloads[0] = [0x90'u8, 60, 100, 0]
    inputPayloads[1] = [0x90'u8, 60, 0, 0]
    inputPayloads[2] = [0xA0'u8, 60, 64, 0]
    inputPayloads[3] = [0xF0'u8, 1, 2, 0xF7]
    inputPayloads[4] = [0xF0'u8, 3, 0, 0]
    inputPayloads[5] = [4'u8, 0xF7, 0, 0]
    var role: AudioRoleGuard
    role.initAudioRoleGuard()
    require tryEnterAudioRole(addr role)
    var opened = newVst3EventBridge(nil, plan, addr role, "fixture", "v3-input")
    require opened.isOk
    var bridge = opened.value
    defer:
      endVst3EventCycle(bridge)
      closeVst3EventBridge(bridge)
      discard leaveAudioRole(addr role)
    var engine: RtEngine
    engine.noteInputCount = 1
    engine.noteOutputCount = 1
    engine.noteInputBuffers[0] = cast[pointer](addr inputPayloads[0][0])
    engine.noteOutputBuffers[0] = cast[pointer](addr outputBytes[0])
    engine.midiIo = RtMidiIo(context: cast[pointer](addr outputBytes[0]),
      eventCount: inputCount, eventGet: inputGet, clear: fakeClear,
      reserve: fakeReserve)
    require beginVst3EventCycle(bridge, addr engine, 64, addr role)
    let input = vst3EventInputInterface(bridge)
    require input != nil
    check input.lpVtbl.getEventCount(cast[pointer](input)) == 5
    var event: Vst3Event
    check input.lpVtbl.getEvent(cast[pointer](input), 0, addr event) == Vst3ResultOk
    check event.busIndex == 3
    check event.sampleOffset == 2
    check event.eventType == Vst3EventTypeNoteOn
    let noteOn = cast[ptr Vst3NoteOnEvent](addr event.payload[0])
    check noteOn[].pitch == 60
    check input.lpVtbl.getEvent(cast[pointer](input), 1, addr event) == Vst3ResultOk
    check event.eventType == Vst3EventTypeNoteOff
    check input.lpVtbl.getEvent(cast[pointer](input), 2, addr event) == Vst3ResultOk
    check event.eventType == Vst3EventTypePolyPressure
    check input.lpVtbl.getEvent(cast[pointer](input), 3, addr event) == Vst3ResultOk
    check event.eventType == Vst3EventTypeData
    let sysex = cast[ptr Vst3DataEvent](addr event.payload[0])
    check sysex[].size == 4
    let sysexBytes = cast[ptr UncheckedArray[uint8]](sysex[].bytes)
    check sysexBytes[0] == 0xF0'u8
    check sysexBytes[3] == 0xF7'u8
    check input.lpVtbl.getEvent(cast[pointer](input), 4, addr event) == Vst3ResultOk
    check event.sampleOffset == 6
    let split = cast[ptr Vst3DataEvent](addr event.payload[0])
    check split[].size == 4
    let splitBytes = cast[ptr UncheckedArray[uint8]](split[].bytes)
    check splitBytes[1] == 3'u8
    check splitBytes[2] == 4'u8
    check splitBytes[3] == 0xF7'u8

    endVst3EventCycle(bridge)
    let accepted = vst3EventMetrics(bridge)
    check accepted.acceptedInput == 5'u64
    check accepted.malformedInput == 0'u64
    inputCountValue = 2
    inputTimes[0] = 1
    inputSizes[0] = 1
    inputPayloads[0] = [0x40'u8, 0, 0, 0]
    inputTimes[1] = 2
    inputSizes[1] = 3
    inputPayloads[1] = [0x90'u8, 61, 100, 0]
    require beginVst3EventCycle(bridge, addr engine, 64, addr role)
    check input.lpVtbl.getEventCount(cast[pointer](input)) == 1
    endVst3EventCycle(bridge)
    let recovered = vst3EventMetrics(bridge)
    check recovered.acceptedInput == 1'u64
    check recovered.malformedInput == 1'u64
