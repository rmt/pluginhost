## Fixed-layout VST3 MIDI/event bridge.
##
## Controller MIDI assignments are queried once before activation.  The JACK
## process path then uses only preallocated POD storage, native VST3 callback
## containers, and JACK's supplied MIDI storage.  SysEx bytes are copied into
## process-owned storage before a VST3 event is exposed.

import std/typetraits

import ../domain/[errors, port_plan, result]
import ../rt/[atomic_pod, engine, midi_io, role_guard]
import ./[ffi, uid]

const
  Vst3EventBridgeMaxBuses = 1024'u32
  Vst3EventBridgeMaxEvents* = 4_096'u32
  Vst3EventBridgeMaxParameterPoints* = 16_384'u32
  Vst3EventBridgeInputDataBytes* = 256 * 1024'u32
  Vst3EventBridgeOutputDataBytes* = 256 * 1024'u32
  Vst3EventBridgeMaxSysExBytes* = 64 * 1024'u32

  eventListIidBytes: array[16, uint8] =
    [0x3A'u8, 0x2C, 0x42, 0x14, 0x34, 0x63, 0x49, 0xFE,
     0xB2, 0xC4, 0xF3, 0x97, 0xB9, 0x69, 0x5A, 0x44]
  fUnknownIidBytes: array[16, uint8] =
    [0'u8, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46]

type
  Vst3MidiAssignment* {.bycopy.} = object
    id*: Vst3ParamID
    mapped*: uint8

  Vst3MidiAssignmentCache* = object
    busCount*: uint32
    slotCount*: uint32
    entries*: ptr UncheckedArray[Vst3MidiAssignment]

  Vst3MidiParameterPoint* {.bycopy.} = object
    id*: Vst3ParamID
    value*: Vst3ParamValue
    sampleOffset*: int32

  Vst3EventMetrics* {.bycopy.} = object
    acceptedInput*: uint64
    droppedInput*: uint64
    malformedInput*: uint64
    unmappedInput*: uint64
    inputCapacityDrops*: uint64
    jackLostInput*: uint64
    acceptedOutput*: uint64
    droppedOutput*: uint64
    invalidOutput*: uint64
    unsupportedOutput*: uint64
    outputCapacityDrops*: uint64
    parameterInputDrops*: uint64
    parameterOutputDrops*: uint64

  Vst3SysexState = object
    active: bool
    size: uint32

  Vst3InputCursor = object
    port: uint32
    sourceIndex: uint32
    sourceCount: uint32
    kind: uint8
    event: Vst3Event
    parameter: Vst3MidiParameterPoint

  Vst3EventBridge* = object
    inputPortCount*: uint32
    outputPortCount*: uint32
    inputBusIndices: array[1024, int32]
    outputBusIndices: array[1024, int32]
    inputChannelCounts: array[1024, uint8]
    outputChannelCounts: array[1024, uint8]
    cache: ptr Vst3MidiAssignmentCache
    sysexStates: ptr UncheckedArray[Vst3SysexState]
    sysexStorage: ptr UncheckedArray[uint8]
    sysexStride: uint32
    inputData: array[int(Vst3EventBridgeInputDataBytes), uint8]
    inputDataUsed: uint32
    inputEvents: array[int(Vst3EventBridgeMaxEvents), Vst3Event]
    outputEvents: array[int(Vst3EventBridgeMaxEvents), Vst3Event]
    outputData: array[int(Vst3EventBridgeOutputDataBytes), uint8]
    outputDataUsed: uint32
    inputCount*: uint32
    heap: array[1024, Vst3InputCursor]
    heapCount: uint32
    parameterPoints: array[int(Vst3EventBridgeMaxParameterPoints),
      Vst3MidiParameterPoint]
    parameterPointCount: uint32
    inputLastTime: array[1024, uint32]
    inputHasTime: array[1024, bool]
    currentFrames: uint32
    currentEngine: ptr RtEngine
    role: ptr AudioRoleGuard
    cycleActive: RtAtomicU32
    outputLastTime: array[1024, uint32]
    outputHasTime: array[1024, bool]
    outputCount*: uint32
    inputIface*: Vst3EventList
    inputVtable: Vst3EventListVtbl
    outputIface*: Vst3EventList
    outputVtable: Vst3EventListVtbl
    acceptedInput: RtAtomicU64
    droppedInput: RtAtomicU64
    malformedInput: RtAtomicU64
    unmappedInput: RtAtomicU64
    inputCapacityDrops: RtAtomicU64
    jackLostInput: RtAtomicU64
    acceptedOutput: RtAtomicU64
    droppedOutput: RtAtomicU64
    invalidOutput: RtAtomicU64
    unsupportedOutput: RtAtomicU64
    outputCapacityDrops: RtAtomicU64

    parameterInputDrops: RtAtomicU64
    parameterOutputDrops: RtAtomicU64
static:
  doAssert supportsCopyMem(Vst3MidiAssignment)
  doAssert supportsCopyMem(Vst3MidiParameterPoint)
  doAssert supportsCopyMem(Vst3EventMetrics)
  doAssert sizeof(Vst3Event) == 48

proc bridgeError(path, pluginId, message, detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0: context.add("; " & detail)
  hostError(hsVst3, hekVst3Factory, message, context)

{.push checks: off, stackTrace: off, lineTrace: off, overflowChecks: off.}

proc bridgeCallbackAllowed(bridge: ptr Vst3EventBridge): bool {.inline, gcsafe,
    raises: [].} =
  bridge != nil and bridge.cycleActive.loadAcquire() != 0'u32 and
    isAudioRoleThread(bridge.role)

proc bridgeFromInputIface(thisInterface: pointer): ptr Vst3EventBridge {.
    inline, gcsafe, raises: [].} =
  if thisInterface == nil:
    return nil
  cast[ptr Vst3EventBridge](cast[uint](thisInterface) -
    uint(offsetOf(Vst3EventBridge, inputIface)))

proc bridgeFromOutputIface(thisInterface: pointer): ptr Vst3EventBridge {.
    inline, gcsafe, raises: [].} =
  if thisInterface == nil:
    return nil
  cast[ptr Vst3EventBridge](cast[uint](thisInterface) -
    uint(offsetOf(Vst3EventBridge, outputIface)))


proc iidMatches(iid: ptr Vst3Tuid; expected: array[16, uint8]): bool {.
    inline, gcsafe, raises: [].} =
  if iid == nil: return false
  for index in 0 ..< 16:
    if iid[][index] != expected[index]: return false
  true

proc inputQuery(thisInterface: pointer; iid: ptr Vst3Tuid;
                obj: ptr pointer): int32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_input_query".} =
  let bridge = bridgeFromInputIface(thisInterface)
  if not bridgeCallbackAllowed(bridge) or obj == nil or
      (not iidMatches(iid, fUnknownIidBytes) and
       not iidMatches(iid, eventListIidBytes)):
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = thisInterface
  Vst3ResultOk

proc outputQuery(thisInterface: pointer; iid: ptr Vst3Tuid;
                 obj: ptr pointer): int32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_output_query".} =
  let bridge = bridgeFromOutputIface(thisInterface)
  if not bridgeCallbackAllowed(bridge) or obj == nil or
      (not iidMatches(iid, fUnknownIidBytes) and
       not iidMatches(iid, eventListIidBytes)):
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = thisInterface
  Vst3ResultOk

proc inputAddRef(thisInterface: pointer): uint32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_input_add_ref".} =
  let bridge = bridgeFromInputIface(thisInterface)
  if bridgeCallbackAllowed(bridge): 1'u32 else: 0'u32
proc inputRelease(thisInterface: pointer): uint32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_input_release".} =
  let bridge = bridgeFromInputIface(thisInterface)
  if bridgeCallbackAllowed(bridge): 1'u32 else: 0'u32
proc outputAddRef(thisInterface: pointer): uint32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_output_add_ref".} =
  let bridge = bridgeFromOutputIface(thisInterface)
  if bridgeCallbackAllowed(bridge): 1'u32 else: 0'u32
proc outputRelease(thisInterface: pointer): uint32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_output_release".} =
  let bridge = bridgeFromOutputIface(thisInterface)
  if bridgeCallbackAllowed(bridge): 1'u32 else: 0'u32
proc inputCountProc(thisInterface: pointer): int32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_input_count".} =
  let bridge = bridgeFromInputIface(thisInterface)
  if not bridgeCallbackAllowed(bridge): -1 else: int32(bridge.inputCount)

proc outputCountProc(thisInterface: pointer): int32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_output_count".} =
  let bridge = bridgeFromOutputIface(thisInterface)
  if not bridgeCallbackAllowed(bridge): -1 else: int32(bridge.outputCount)
proc inputGet(thisInterface: pointer; index: int32;
              event: ptr Vst3Event): int32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_input_get".} =
  let bridge = bridgeFromInputIface(thisInterface)
  if not bridgeCallbackAllowed(bridge) or event == nil or index < 0 or
      uint32(index) >= bridge.inputCount:
    return Vst3InvalidArgument
  event[] = bridge.inputEvents[int(index)]
  Vst3ResultOk

proc inputAddEvent(thisInterface: pointer; event: ptr Vst3Event): int32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_input_add".} =
  let bridge = bridgeFromInputIface(thisInterface)
  discard event
  if not bridgeCallbackAllowed(bridge): Vst3ResultFalse
  else: Vst3NotImplemented
proc outputPortForBus(bridge: ptr Vst3EventBridge; nativeBus: int32;
                      port: var uint32): bool {.inline, gcsafe, raises: [].} =
  if bridge == nil or nativeBus < 0: return false
  var index = 0'u32
  while index < bridge.outputPortCount:
    if bridge.outputBusIndices[int(index)] == nativeBus:
      port = index
      return true
    inc index
  false

proc outputGet(thisInterface: pointer; index: int32;
               event: ptr Vst3Event): int32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_output_get".} =
  let bridge = bridgeFromOutputIface(thisInterface)
  if not bridgeCallbackAllowed(bridge) or event == nil or index < 0 or
      uint32(index) >= bridge.outputCount:
    return Vst3InvalidArgument
  event[] = bridge.outputEvents[int(index)]
  Vst3ResultOk

proc midiByte(value: cfloat): uint8 {.inline, gcsafe, raises: [].} =
  if value <= 0.0: 0'u8
  elif value >= 1.0: 127'u8
  else: uint8(value * 127.0 + 0.5)

proc finiteRange(value: cfloat): bool {.inline, gcsafe, raises: [].} =
  value == value and value >= 0.0 and value <= 1.0

proc reserveOutput(bridge: ptr Vst3EventBridge; bus, time, size: uint32;
                   data: ptr UncheckedArray[uint8]): bool {.
    inline, gcsafe, raises: [].} =
  if bridge == nil or bridge.currentEngine == nil or
      bus >= bridge.outputPortCount or time >= bridge.currentFrames or
      size == 0'u32 or data == nil:
    return false
  let engine = bridge.currentEngine
  let target = engine.noteOutputBuffers[int(bus)]
  if target == nil or engine.midiIo.reserve == nil:
    return false
  let destination = engine.midiIo.reserve(engine.midiIo.context, target,
    time, size)
  if destination == nil:
    return false
  copyMem(destination, data, int(size))
  true

proc eventAdd(thisInterface: pointer; event: ptr Vst3Event): int32 {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_event_add".} =
  let bridge = bridgeFromOutputIface(thisInterface)
  if not bridgeCallbackAllowed(bridge) or event == nil or bridge.currentEngine == nil:
    return Vst3ResultFalse
  if bridge.outputCount >= Vst3EventBridgeMaxEvents:
    discard bridge.outputCapacityDrops.fetchAddRelaxed(1'u64)
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    return Vst3ResultFalse
  var outputPort: uint32
  if not bridge.outputPortForBus(event.busIndex, outputPort):
    discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    return Vst3InvalidArgument
  if event.sampleOffset < 0 or uint32(event.sampleOffset) >= bridge.currentFrames or
      (bridge.outputHasTime[int(outputPort)] and
       uint32(event.sampleOffset) < bridge.outputLastTime[int(outputPort)]):
    discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    return Vst3InvalidArgument
  var bytes: array[3, uint8]
  var byteCount = 0'u32
  case event.eventType
  of Vst3EventTypeNoteOn:
    let note = cast[ptr Vst3NoteOnEvent](addr event.payload[0])
    if note.channel < 0 or
        uint32(note.channel) >= uint32(bridge.outputChannelCounts[int(outputPort)]) or
        note.pitch < 0 or note.pitch > 127 or
        not finiteRange(note.velocity) or note.tuning != 0.0:
      discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3InvalidArgument
    bytes = [uint8(0x90) or uint8(note.channel), uint8(note.pitch),
      midiByte(note.velocity)]
    byteCount = 3
  of Vst3EventTypeNoteOff:
    let note = cast[ptr Vst3NoteOffEvent](addr event.payload[0])
    if note.channel < 0 or
        uint32(note.channel) >= uint32(bridge.outputChannelCounts[int(outputPort)]) or
        note.pitch < 0 or note.pitch > 127 or
        not finiteRange(note.velocity) or note.tuning != 0.0:
      discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3InvalidArgument
    bytes = [uint8(0x80) or uint8(note.channel), uint8(note.pitch),
      midiByte(note.velocity)]
    byteCount = 3
  of Vst3EventTypePolyPressure:
    let pressure = cast[ptr Vst3PolyPressureEvent](addr event.payload[0])
    if pressure.channel < 0 or
        uint32(pressure.channel) >=
          uint32(bridge.outputChannelCounts[int(outputPort)]) or
        pressure.pitch < 0 or pressure.pitch > 127 or
        not finiteRange(pressure.pressure):
      discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3InvalidArgument
    bytes = [uint8(0xA0) or uint8(pressure.channel), uint8(pressure.pitch),
      midiByte(pressure.pressure)]
    byteCount = 3
  of Vst3EventTypeLegacyMidiCcOut:
    let cc = cast[ptr Vst3LegacyMidiCcOutEvent](addr event.payload[0])
    if cc.channel < 0 or
        uint32(cc.channel) >= uint32(bridge.outputChannelCounts[int(outputPort)]) or
        cc.value < 0 or cc.value > 127:
      discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3InvalidArgument
    case cc.controlNumber
    of 0'u8 .. 127'u8:
      bytes = [uint8(0xB0) or uint8(cc.channel), cc.controlNumber,
        uint8(cc.value)]
      byteCount = 3
    of uint8(Vst3MidiControllerAftertouch):
      bytes = [uint8(0xD0) or uint8(cc.channel), uint8(cc.value), 0'u8]
      byteCount = 2
    of uint8(Vst3MidiControllerPitchBend):
      if cc.value2 < 0 or cc.value2 > 127:
        discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
        discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
        return Vst3InvalidArgument
      bytes = [uint8(0xE0) or uint8(cc.channel), uint8(cc.value),
        uint8(cc.value2)]
      byteCount = 3
    of uint8(Vst3MidiControllerPolyPressure):
      if cc.value2 < 0 or cc.value2 > 127:
        discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
        discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
        return Vst3InvalidArgument
      bytes = [uint8(0xA0) or uint8(cc.channel), uint8(cc.value),
        uint8(cc.value2)]
      byteCount = 3
    of uint8(Vst3MidiControllerProgramChange):
      bytes = [uint8(0xC0) or uint8(cc.channel), uint8(cc.value), 0'u8]
      byteCount = 2
    of uint8(Vst3MidiControllerQuarterFrame):
      bytes = [0xF1'u8, uint8(cc.value), 0'u8]
      byteCount = 2
    of uint8(Vst3MidiControllerSongSelect):
      bytes = [0xF3'u8, uint8(cc.value), 0'u8]
      byteCount = 2
    of uint8(Vst3MidiControllerSongPointer):
      if cc.value2 < 0 or cc.value2 > 127:
        discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
        discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
        return Vst3InvalidArgument
      bytes = [0xF2'u8, uint8(cc.value), uint8(cc.value2)]
      byteCount = 3
    of uint8(Vst3MidiControllerCableSelect):
      bytes = [0xF5'u8, uint8(cc.value), 0'u8]
      byteCount = 1
    of uint8(Vst3MidiControllerTuneRequest):
      bytes = [0xF6'u8, 0'u8, 0'u8]
      byteCount = 1
    of uint8(Vst3MidiControllerClockStart):
      bytes = [0xFA'u8, 0'u8, 0'u8]
      byteCount = 1
    of uint8(Vst3MidiControllerClockContinue):
      bytes = [0xFB'u8, 0'u8, 0'u8]
      byteCount = 1
    of uint8(Vst3MidiControllerClockStop):
      bytes = [0xFC'u8, 0'u8, 0'u8]
      byteCount = 1
    of uint8(Vst3MidiControllerActiveSensing):
      bytes = [0xFE'u8, 0'u8, 0'u8]
      byteCount = 1
    else:
      discard bridge.unsupportedOutput.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3NotImplemented
  of Vst3EventTypeData:
    let dataEvent = cast[ptr Vst3DataEvent](addr event.payload[0])
    if dataEvent.dataType != Vst3DataTypeMidiSysEx or dataEvent.size == 0'u32 or
        dataEvent.bytes == nil:
      discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3InvalidArgument
    if dataEvent.size > Vst3EventBridgeMaxSysExBytes:
      discard bridge.outputCapacityDrops.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3ResultFalse
    let dataBytes = cast[ptr UncheckedArray[uint8]](dataEvent.bytes)
    if dataBytes[0] != 0xF0'u8 or
        dataBytes[int(dataEvent.size - 1'u32)] != 0xF7'u8:
      discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3InvalidArgument
    var dataIndex = 1'u32
    while dataIndex + 1'u32 < dataEvent.size:
      if dataBytes[int(dataIndex)] >= 0x80'u8:
        discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
        discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
        return Vst3InvalidArgument
      inc dataIndex
    if dataEvent.size > uint32(bridge.outputData.len) - bridge.outputDataUsed:
      discard bridge.outputCapacityDrops.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3ResultFalse
    let target = bridge.currentEngine.noteOutputBuffers[int(outputPort)]
    if target == nil or bridge.currentEngine.midiIo.reserve == nil:
      discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3InvalidArgument
    let destination = bridge.currentEngine.midiIo.reserve(
      bridge.currentEngine.midiIo.context, target, uint32(event.sampleOffset),
      dataEvent.size)
    if destination == nil:
      discard bridge.outputCapacityDrops.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return Vst3ResultFalse
    copyMem(destination, dataBytes, int(dataEvent.size))
    let retained = addr bridge.outputData[int(bridge.outputDataUsed)]
    copyMem(retained, dataBytes, int(dataEvent.size))
    bridge.outputEvents[int(bridge.outputCount)] = event[]
    let retainedEvent = cast[ptr Vst3DataEvent](
      addr bridge.outputEvents[int(bridge.outputCount)].payload[0])
    retainedEvent.bytes = retained
    bridge.outputDataUsed += dataEvent.size
    bridge.outputLastTime[int(outputPort)] = uint32(event.sampleOffset)
    bridge.outputHasTime[int(outputPort)] = true
    inc bridge.outputCount
    discard bridge.acceptedOutput.fetchAddRelaxed(1'u64)
    return Vst3ResultOk
  else:
    discard bridge.unsupportedOutput.fetchAddRelaxed(1'u64)
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    return Vst3NotImplemented
  if not bridge.reserveOutput(outputPort, uint32(event.sampleOffset),
        byteCount, cast[ptr UncheckedArray[uint8]](addr bytes[0])):
    discard bridge.outputCapacityDrops.fetchAddRelaxed(1'u64)
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    return Vst3ResultFalse
  bridge.outputLastTime[int(outputPort)] = uint32(event.sampleOffset)
  bridge.outputEvents[int(bridge.outputCount)] = event[]
  bridge.outputHasTime[int(outputPort)] = true
  inc bridge.outputCount
  discard bridge.acceptedOutput.fetchAddRelaxed(1'u64)
  Vst3ResultOk

proc assignmentIndex(bus: uint32; channel: uint8; controller: uint8): uint32 {.
    inline, gcsafe, raises: [].} =
  ((bus * uint32(Vst3MidiChannelCount) + uint32(channel)) *
    uint32(Vst3MidiControllerCount)) + uint32(controller)

proc assignment(bridge: ptr Vst3EventBridge; bus: int32; channel, controller: uint8;
                id: var Vst3ParamID): bool {.inline, gcsafe, raises: [].} =
  if bridge == nil or bridge.cache == nil or bus < 0 or
      uint32(bus) >= bridge.cache.busCount or channel >= 16'u8 or
      uint32(controller) >= uint32(Vst3MidiControllerCount):
    return false
  let value = bridge.cache.entries[int(assignmentIndex(uint32(bus), channel, controller))]
  if value.mapped == 0'u8: return false
  id = value.id
  true

proc addParameterPoint(bridge: ptr Vst3EventBridge; id: Vst3ParamID;
                       value: Vst3ParamValue; offset: uint32): bool {.
    inline, gcsafe, raises: [].} =
  if bridge.parameterPointCount >= Vst3EventBridgeMaxParameterPoints:
    discard bridge.inputCapacityDrops.fetchAddRelaxed(1'u64)
    discard bridge.droppedInput.fetchAddRelaxed(1'u64)
    return false
  bridge.parameterPoints[int(bridge.parameterPointCount)] =
    Vst3MidiParameterPoint(
    id: id, value: value, sampleOffset: int32(offset))
  inc bridge.parameterPointCount
  true

proc copySysEx(bridge: ptr Vst3EventBridge; port: uint32;
               source: ptr UncheckedArray[uint8]; size: uint32;
               time: uint32; event: var Vst3Event): int {.
    gcsafe, raises: [].} =
  if source == nil or size == 0'u32 or port >= bridge.inputPortCount:
    return 0
  let state = addr bridge.sysexStates[int(port)]
  let storage = cast[ptr UncheckedArray[uint8]](
    cast[uint](bridge.sysexStorage) + uint(port) * uint(bridge.sysexStride))
  var complete = false
  var index = 0'u32
  while index < size:
    let byte = source[int(index)]
    if byte >= 0x80'u8 and byte != 0xF7'u8 and
        not (byte == 0xF0'u8 and state[].size == 0'u32):
      state[].active = false
      state[].size = 0'u32
      return -1
    if byte == 0xF0'u8 and state[].size != 0'u32:
      state[].active = false
      state[].size = 0'u32
    if state[].size >= bridge.sysexStride:
      state[].active = false
      state[].size = 0'u32
      return -1
    storage[int(state[].size)] = byte
    inc state[].size
    if byte == 0xF7'u8:
      if index + 1'u32 != size:
        state[].active = false
        state[].size = 0'u32
        return -1
      complete = true
      break
    inc index
  if complete:
    if state[].size > uint32(bridge.inputData.len) - bridge.inputDataUsed:
      state[].active = false
      state[].size = 0'u32
      return -1
    let output = addr bridge.inputData[int(bridge.inputDataUsed)]
    copyMem(output, storage, int(state[].size))
    event = Vst3Event(busIndex: bridge.inputBusIndices[int(port)],
      sampleOffset: int32(time), ppqPosition: 0.0,
      flags: Vst3EventFlagIsLive, eventType: Vst3EventTypeData)
    let data = cast[ptr Vst3DataEvent](addr event.payload[0])
    data[].size = state[].size
    data[].dataType = Vst3DataTypeMidiSysEx
    data[].bytes = output
    bridge.inputDataUsed += state[].size
    state[].active = false
    state[].size = 0'u32
    return 1
  state[].active = true
  0

proc translateMidi(bridge: ptr Vst3EventBridge; port: uint32;
                  source: RtMidiEventView; event: var Vst3Event;
                  parameter: var Vst3MidiParameterPoint): int {.
    gcsafe, raises: [].} =
  if source.data == nil or source.size == 0'u32:
    return -1
  let first = source.data[0]
  if bridge.sysexStates[int(port)].active and first >= 0x80'u8 and first != 0xF7'u8:
    bridge.sysexStates[int(port)].active = false
    bridge.sysexStates[int(port)].size = 0'u32
    return -1
  if first == 0xF0'u8 or (bridge.sysexStates[int(port)].active and first != 0xF8'u8 and
      first != 0xF9'u8 and first != 0xFA'u8 and first != 0xFB'u8 and
      first != 0xFC'u8 and first != 0xFD'u8 and first != 0xFE'u8 and
      first != 0xFF'u8):
    return bridge.copySysEx(port, source.data, source.size, source.time, event)
  let status = first and 0xF0'u8
  let expected = case status
    of 0x80'u8, 0x90'u8, 0xA0'u8, 0xB0'u8, 0xE0'u8: 3'u32
    of 0xC0'u8, 0xD0'u8: 2'u32
    else: 0'u32
  if expected == 0'u32 or source.size != expected:
    return -1
  var index = 1'u32
  while index < source.size:
    if source.data[int(index)] >= 0x80'u8: return -1
    inc index
  # A one-channel VST3 bus has no destination for other JACK MIDI channels.
  # Route them to its only channel; preserve identity on multichannel buses.
  let channel = if bridge.inputChannelCounts[int(port)] == 1'u8:
      0'u8 else: first and 0x0F'u8
  if uint32(channel) >= uint32(bridge.inputChannelCounts[int(port)]):
    return -1
  event = Vst3Event(busIndex: bridge.inputBusIndices[int(port)],
    sampleOffset: int32(source.time), ppqPosition: 0.0,
    flags: Vst3EventFlagIsLive, eventType: Vst3EventTypeNoteOn)
  case status
  of 0x80'u8:
    event.eventType = Vst3EventTypeNoteOff
    let note = cast[ptr Vst3NoteOffEvent](addr event.payload[0])
    note[] = Vst3NoteOffEvent(channel: int16(channel),
      pitch: int16(source.data[1]), velocity: cfloat(source.data[2]) / 127.0,
      noteId: Vst3NoteIdNone, tuning: 0.0)
    return 1
  of 0x90'u8:
    if source.data[2] == 0'u8:
      let note = cast[ptr Vst3NoteOffEvent](addr event.payload[0])
      event.eventType = Vst3EventTypeNoteOff
      note[] = Vst3NoteOffEvent(channel: int16(channel),
        pitch: int16(source.data[1]), velocity: 0.0,
        noteId: Vst3NoteIdNone, tuning: 0.0)
    else:
      let note = cast[ptr Vst3NoteOnEvent](addr event.payload[0])
      note[] = Vst3NoteOnEvent(channel: int16(channel),
        pitch: int16(source.data[1]), tuning: 0.0,
        velocity: cfloat(source.data[2]) / 127.0, length: 0,
        noteId: Vst3NoteIdNone)
    return 1
  of 0xA0'u8:
    let pressure = cast[ptr Vst3PolyPressureEvent](addr event.payload[0])
    event.eventType = Vst3EventTypePolyPressure
    pressure[] = Vst3PolyPressureEvent(channel: int16(channel),
      pitch: int16(source.data[1]), pressure: cfloat(source.data[2]) / 127.0,
      noteId: Vst3NoteIdNone)
    return 1
  of 0xB0'u8, 0xD0'u8, 0xE0'u8, 0xC0'u8:
    var controller: uint8
    var value: Vst3ParamValue
    if status == 0xB0'u8:
      controller = source.data[1]
      value = Vst3ParamValue(source.data[2]) / 127.0
    elif status == 0xD0'u8:
      controller = uint8(Vst3MidiControllerAftertouch)
      value = Vst3ParamValue(source.data[1]) / 127.0
    elif status == 0xE0'u8:
      controller = uint8(Vst3MidiControllerPitchBend)
      value = Vst3ParamValue(uint16(source.data[1]) or
        (uint16(source.data[2]) shl 7)) / 16383.0
    else:
      controller = uint8(Vst3MidiControllerProgramChange)
      value = Vst3ParamValue(source.data[1]) / 127.0
    var id: Vst3ParamID
    if not bridge.assignment(bridge.inputBusIndices[int(port)], channel,
        controller, id):
      discard bridge.unmappedInput.fetchAddRelaxed(1'u64)
      discard bridge.droppedInput.fetchAddRelaxed(1'u64)
      return 0
    parameter = Vst3MidiParameterPoint(id: id, value: value,
      sampleOffset: int32(source.time))
    event.sampleOffset = int32(source.time)
    2
  else:
    -1

proc cursorLess(left, right: Vst3InputCursor): bool {.
    inline, gcsafe, raises: [].} =
  if left.event.sampleOffset != right.event.sampleOffset:
    return left.event.sampleOffset < right.event.sampleOffset
  if left.port != right.port: return left.port < right.port
  left.sourceIndex < right.sourceIndex

proc heapPush(bridge: ptr Vst3EventBridge; cursor: Vst3InputCursor) {.
    inline, gcsafe, raises: [].} =
  var position = bridge.heapCount
  inc bridge.heapCount
  while position > 0'u32:
    let parent = (position - 1'u32) div 2'u32
    if not cursorLess(cursor, bridge.heap[int(parent)]): break
    bridge.heap[int(position)] = bridge.heap[int(parent)]
    position = parent
  bridge.heap[int(position)] = cursor

proc heapPop(bridge: ptr Vst3EventBridge): Vst3InputCursor {.
    inline, gcsafe, raises: [].} =
  result = bridge.heap[0]
  dec bridge.heapCount
  if bridge.heapCount == 0'u32: return
  let replacement = bridge.heap[int(bridge.heapCount)]
  var position = 0'u32
  while true:
    let left = position * 2'u32 + 1'u32
    if left >= bridge.heapCount: break
    let right = left + 1'u32
    var child = left
    if right < bridge.heapCount and cursorLess(bridge.heap[int(right)],
        bridge.heap[int(left)]):
      child = right
    if not cursorLess(bridge.heap[int(child)], replacement): break
    bridge.heap[int(position)] = bridge.heap[int(child)]
    position = child
  bridge.heap[int(position)] = replacement

proc nextCursor(bridge: ptr Vst3EventBridge; port, start, count,
                nframes: uint32; cursor: var Vst3InputCursor): bool {.
    gcsafe, raises: [].} =
  var index = start
  let buffer = bridge.currentEngine.noteInputBuffers[int(port)]
  while index < count:
    var source: RtMidiEventView
    if buffer == nil or bridge.currentEngine.midiIo.eventGet == nil or
        not bridge.currentEngine.midiIo.eventGet(
          bridge.currentEngine.midiIo.context, buffer, index, addr source):
      discard bridge.malformedInput.fetchAddRelaxed(1'u64)
      discard bridge.droppedInput.fetchAddRelaxed(1'u64)
      inc index
      continue
    if source.time > uint32(high(int32)) or source.time >= nframes or
        (bridge.inputHasTime[int(port)] and
         source.time < bridge.inputLastTime[int(port)]):
      discard bridge.malformedInput.fetchAddRelaxed(1'u64)
      discard bridge.droppedInput.fetchAddRelaxed(1'u64)
      inc index
      continue
    bridge.inputHasTime[int(port)] = true
    bridge.inputLastTime[int(port)] = source.time
    var translated: Vst3Event
    var parameter: Vst3MidiParameterPoint
    let kind = bridge.translateMidi(port, source, translated, parameter)
    if kind < 0:
      discard bridge.malformedInput.fetchAddRelaxed(1'u64)
      discard bridge.droppedInput.fetchAddRelaxed(1'u64)
      inc index
      continue
    if kind == 0:
      inc index
      continue
    cursor = Vst3InputCursor(port: port, sourceIndex: index,
      sourceCount: count, kind: uint8(kind), event: translated,
      parameter: parameter)
    return true
  false

proc clearVst3MidiOutputsForEngine*(bridge: ptr Vst3EventBridge;
                                    engine: ptr RtEngine) {.
    inline, gcsafe, raises: [].} =
  if bridge == nil or engine == nil or engine.midiIo.clear == nil:
    return
  var port = 0'u32
  while port < bridge.outputPortCount:
    let buffer = engine.noteOutputBuffers[int(port)]
    if buffer != nil:
      engine.midiIo.clear(engine.midiIo.context, buffer)
    inc port

proc clearVst3MidiOutputsRaw*(bridge: ptr Vst3EventBridge) {.
    inline, gcsafe, raises: [].} =
  if bridge == nil: return
  bridge.clearVst3MidiOutputsForEngine(bridge.currentEngine)
proc clearVst3MidiOutputs*(bridge: ptr Vst3EventBridge) {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_clear_outputs".} =
  if not bridgeCallbackAllowed(bridge): return
  bridge.clearVst3MidiOutputsRaw()
proc beginVst3EventCycle*(bridge: ptr Vst3EventBridge; engine: ptr RtEngine;
                          nframes: uint32; role: ptr AudioRoleGuard): bool {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_event_bridge_begin".} =
  if bridge == nil or engine == nil or role == nil or nframes == 0'u32 or
      nframes > uint32(high(int32)) or
      bridge.cycleActive.loadAcquire() != 0'u32 or
      not isAudioRoleThread(role) or
      engine.noteInputCount != bridge.inputPortCount or
      engine.noteOutputCount != bridge.outputPortCount or
      (bridge.inputPortCount != 0'u32 and not engine.midiIo.isReadable) or
      (bridge.outputPortCount != 0'u32 and not engine.midiIo.isWritable):
    return false
  bridge.role = role
  bridge.currentEngine = engine
  bridge.currentFrames = nframes
  bridge.inputCount = 0'u32
  bridge.heapCount = 0'u32
  bridge.inputDataUsed = 0'u32
  bridge.parameterPointCount = 0'u32
  bridge.outputCount = 0'u32
  bridge.outputDataUsed = 0'u32
  var outputPort = 0'u32
  while outputPort < bridge.outputPortCount:
    bridge.outputHasTime[int(outputPort)] = false
    inc outputPort
  bridge.clearVst3MidiOutputsRaw()
  var port = 0'u32
  while port < bridge.inputPortCount:
    bridge.inputHasTime[int(port)] = false
    let state = addr bridge.sysexStates[int(port)]
    if state[].active:
      ## A SysEx continuation is valid only while its preallocated carry is
      ## retained.  Its eventual DataEvent is emitted at the terminator time.
      discard
    let lost = if bridge.currentEngine.midiIo.lostEventCount == nil: 0'u32 else:
      bridge.currentEngine.midiIo.lostEventCount(
        bridge.currentEngine.midiIo.context,
        bridge.currentEngine.noteInputBuffers[int(port)])
    if lost > 0'u32:
      discard bridge.jackLostInput.fetchAddRelaxed(uint64(lost))
      discard bridge.droppedInput.fetchAddRelaxed(uint64(lost))
    let count = if bridge.currentEngine.midiIo.eventCount == nil: 0'u32 else:
      bridge.currentEngine.midiIo.eventCount(
        bridge.currentEngine.midiIo.context,
        bridge.currentEngine.noteInputBuffers[int(port)])
    var cursor: Vst3InputCursor
    if bridge.nextCursor(port, 0'u32, count, nframes, cursor):
      bridge.heapPush(cursor)
    inc port
  while bridge.heapCount > 0'u32:
    let cursor = bridge.heapPop()
    var accepted = false
    if cursor.kind == 1'u8:
      if bridge.inputCount < Vst3EventBridgeMaxEvents:
        bridge.inputEvents[int(bridge.inputCount)] = cursor.event
        inc bridge.inputCount
        accepted = true
      else:
        discard bridge.inputCapacityDrops.fetchAddRelaxed(1'u64)
        discard bridge.droppedInput.fetchAddRelaxed(1'u64)
    else:
      accepted = bridge.addParameterPoint(cursor.parameter.id,
        cursor.parameter.value, uint32(cursor.parameter.sampleOffset))
    if accepted:
      discard bridge.acceptedInput.fetchAddRelaxed(1'u64)
    var next: Vst3InputCursor
    if bridge.nextCursor(cursor.port, cursor.sourceIndex + 1'u32,
        cursor.sourceCount, nframes, next):
      bridge.heapPush(next)
  bridge.cycleActive.storeRelease(1'u32)
  true

proc endVst3EventCycle*(bridge: ptr Vst3EventBridge) {.
    cdecl, gcsafe, raises: [],
    exportc: "pluginhost_vst3_event_bridge_end".} =
  if bridge == nil: return
  bridge.cycleActive.storeRelease(0'u32)
  bridge.currentEngine = nil
  bridge.currentFrames = 0'u32

proc vst3EventInputInterface*(bridge: ptr Vst3EventBridge): ptr Vst3EventList {.
    inline.} =
  if bridge == nil: nil else: addr bridge.inputIface

proc recordVst3ParameterInputDrop*(bridge: ptr Vst3EventBridge;
                                   count = 1'u64) {.inline, gcsafe, raises: [].} =
  if bridge != nil: discard bridge.parameterInputDrops.fetchAddRelaxed(count)

proc recordVst3ParameterOutputDrop*(bridge: ptr Vst3EventBridge;
                                    count = 1'u64) {.inline, gcsafe, raises: [].} =
  if bridge != nil: discard bridge.parameterOutputDrops.fetchAddRelaxed(count)

proc vst3EventOutputInterface*(bridge: ptr Vst3EventBridge): ptr Vst3EventList {.
    inline.} =
  if bridge == nil: nil else: addr bridge.outputIface


proc vst3InputParameterPointCount*(bridge: ptr Vst3EventBridge): uint32 {.
    inline, gcsafe, raises: [].} =
  if bridge == nil: 0'u32 else: bridge.parameterPointCount

proc vst3InputParameterPoint*(bridge: ptr Vst3EventBridge;
                             index: uint32): Vst3MidiParameterPoint {.
    inline, gcsafe, raises: [].} =
  bridge.parameterPoints[int(index)]

proc vst3EventMetrics*(bridge: ptr Vst3EventBridge): Vst3EventMetrics =
  if bridge == nil: return Vst3EventMetrics()
  Vst3EventMetrics(
    acceptedInput: bridge.acceptedInput.exchangeAcquire(0'u64),
    droppedInput: bridge.droppedInput.exchangeAcquire(0'u64),
    malformedInput: bridge.malformedInput.exchangeAcquire(0'u64),
    unmappedInput: bridge.unmappedInput.exchangeAcquire(0'u64),
    inputCapacityDrops: bridge.inputCapacityDrops.exchangeAcquire(0'u64),
    jackLostInput: bridge.jackLostInput.exchangeAcquire(0'u64),
    acceptedOutput: bridge.acceptedOutput.exchangeAcquire(0'u64),
    droppedOutput: bridge.droppedOutput.exchangeAcquire(0'u64),
    invalidOutput: bridge.invalidOutput.exchangeAcquire(0'u64),
    unsupportedOutput: bridge.unsupportedOutput.exchangeAcquire(0'u64),
    outputCapacityDrops: bridge.outputCapacityDrops.exchangeAcquire(0'u64),
    parameterInputDrops: bridge.parameterInputDrops.exchangeAcquire(0'u64),
    parameterOutputDrops: bridge.parameterOutputDrops.exchangeAcquire(0'u64))
proc initBridgeVtables(bridge: ptr Vst3EventBridge) =
  bridge.inputVtable = Vst3EventListVtbl(
    queryInterface: inputQuery, addRef: inputAddRef, release: inputRelease,
    getEventCount: inputCountProc, getEvent: inputGet, addEvent: inputAddEvent)
  bridge.inputIface.lpVtbl = addr bridge.inputVtable
  bridge.outputVtable = Vst3EventListVtbl(
    queryInterface: outputQuery, addRef: outputAddRef, release: outputRelease,
    getEventCount: outputCountProc, getEvent: outputGet, addEvent: eventAdd)
  bridge.outputIface.lpVtbl = addr bridge.outputVtable

{.pop.}

proc closeVst3EventBridge*(bridge: var ptr Vst3EventBridge) =
  if bridge == nil: return
  if bridge.sysexStorage != nil: deallocShared(bridge.sysexStorage)
  if bridge.sysexStates != nil: deallocShared(bridge.sysexStates)
  if bridge.cache != nil:
    if bridge.cache.entries != nil: deallocShared(bridge.cache.entries)
    deallocShared(bridge.cache)
  deallocShared(bridge)
  bridge = nil

proc newVst3EventBridge*(controller: ptr Vst3EditController;
                         plan: PortPlan; role: ptr AudioRoleGuard;
                         path, pluginId: string):
                         Result[ptr Vst3EventBridge] =
  if role == nil:
    return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
      "VST3 event bridge requires an audio role", ""))
  var inputPortCount = 0'u32
  var outputPortCount = 0'u32
  var maxInputBus = 0'u32
  for note in plan.notePorts:
    if note.index >= Vst3EventBridgeMaxBuses:
      return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
        "VST3 MIDI bus index exceeds host bound", ""))
    if note.direction == pdInput:
      if inputPortCount >= Vst3EventBridgeMaxBuses:
        return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
          "VST3 MIDI input bus count exceeds host bound", ""))
      inc inputPortCount
      maxInputBus = max(maxInputBus, note.index + 1'u32)
    else:
      if outputPortCount >= Vst3EventBridgeMaxBuses:
        return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
          "VST3 MIDI output bus count exceeds host bound", ""))
      inc outputPortCount
  var bridge = cast[ptr Vst3EventBridge](allocShared0(sizeof(Vst3EventBridge)))
  if bridge == nil:
    return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
      "could not allocate VST3 event bridge", ""))
  bridge.role = role
  bridge.cycleActive.storeRelaxed(0'u32)
  bridge.inputPortCount = inputPortCount
  bridge.outputPortCount = outputPortCount
  var inputBusIndex = 0'u32
  var outputBusIndex = 0'u32
  for note in plan.notePorts:
    if note.direction == pdInput:
      bridge.inputBusIndices[int(inputBusIndex)] = int32(note.index)
      bridge.inputChannelCounts[int(inputBusIndex)] =
        uint8(if note.channelCount == 0'u32: 16'u32 else: note.channelCount)
      inc inputBusIndex
    else:
      bridge.outputBusIndices[int(outputBusIndex)] = int32(note.index)
      bridge.outputChannelCounts[int(outputBusIndex)] =
        uint8(if note.channelCount == 0'u32: 16'u32 else: note.channelCount)
      inc outputBusIndex
  bridge.cache = cast[ptr Vst3MidiAssignmentCache](
    allocShared0(sizeof(Vst3MidiAssignmentCache)))
  if bridge.cache == nil:
    closeVst3EventBridge(bridge)
    return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
      "could not allocate VST3 MIDI assignment cache", ""))
  let slotCount64 = uint64(maxInputBus) * uint64(Vst3MidiChannelCount) *
    uint64(Vst3MidiControllerCount)
  let assignmentBytes64 = slotCount64 * uint64(sizeof(Vst3MidiAssignment))
  if slotCount64 > uint64(high(uint32)) or
      assignmentBytes64 > uint64(high(int)):
    closeVst3EventBridge(bridge)
    return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
      "VST3 MIDI assignment cache size exceeds host bound", ""))
  bridge.cache.busCount = maxInputBus
  bridge.cache.slotCount = uint32(slotCount64)
  if bridge.cache.slotCount > 0'u32:
    bridge.cache.entries = cast[ptr UncheckedArray[Vst3MidiAssignment]](
      allocShared0(int(assignmentBytes64)))
    if bridge.cache.entries == nil:
      closeVst3EventBridge(bridge)
      return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
        "could not allocate VST3 MIDI assignments", ""))
  if bridge.inputPortCount > 0'u32:
    bridge.sysexStride = Vst3EventBridgeMaxSysExBytes
    let sysexStateBytes64 = uint64(bridge.inputPortCount) *
      uint64(sizeof(Vst3SysexState))
    let sysexBytes64 = uint64(bridge.inputPortCount) *
      uint64(bridge.sysexStride)
    if sysexStateBytes64 > uint64(high(int)) or
        sysexBytes64 > uint64(high(int)):
      closeVst3EventBridge(bridge)
      return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
        "VST3 SysEx storage size exceeds host bound", ""))
    bridge.sysexStates = cast[ptr UncheckedArray[Vst3SysexState]](
      allocShared0(int(sysexStateBytes64)))
    bridge.sysexStorage = cast[ptr UncheckedArray[uint8]](
      allocShared0(int(sysexBytes64)))
    if bridge.sysexStates == nil or bridge.sysexStorage == nil:
      closeVst3EventBridge(bridge)
      return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
        "could not allocate VST3 SysEx storage", ""))
  if controller != nil and controller.lpVtbl != nil and
      controller.lpVtbl.queryInterface != nil and bridge.cache.slotCount > 0'u32:
    var iidResult = parseVst3Uid(Vst3MidiMappingIid)
    if not iidResult.isOk:
      closeVst3EventBridge(bridge)
      return failure[ptr Vst3EventBridge](move(iidResult.error))
    var candidate: pointer = nil
    let queried = controller.lpVtbl.queryInterface(cast[pointer](controller),
      addr iidResult.value, addr candidate)
    if (queried == Vst3NoInterface or queried == Vst3ResultFalse or
        queried == Vst3NotImplemented) and candidate != nil:
      let returned = cast[ptr Vst3MidiMapping](candidate)
      if returned.lpVtbl != nil and returned.lpVtbl.release != nil:
        discard returned.lpVtbl.release(candidate)
    if queried != Vst3NoInterface and queried != Vst3ResultFalse and
        queried != Vst3NotImplemented:
      if queried != Vst3ResultOk or candidate == nil:
        closeVst3EventBridge(bridge)
        return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
          "VST3 IMidiMapping query failed", "result=" & $queried))
      let mapping = cast[ptr Vst3MidiMapping](candidate)
      if mapping.lpVtbl == nil or mapping.lpVtbl.release == nil or
          mapping.lpVtbl.getMidiControllerAssignment == nil:
        if mapping.lpVtbl != nil and mapping.lpVtbl.release != nil:
          discard mapping.lpVtbl.release(candidate)
        closeVst3EventBridge(bridge)
        return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
          "VST3 IMidiMapping ABI is incomplete", ""))
      var inputPort = 0'u32
      while inputPort < bridge.inputPortCount:
        let bus = uint32(bridge.inputBusIndices[int(inputPort)])
        var channel = 0'u8
        while channel < bridge.inputChannelCounts[int(inputPort)]:
          var controllerNumber = 0
          while controllerNumber < int(Vst3MidiControllerCount):
            var id: Vst3ParamID
            let resultCode = mapping.lpVtbl.getMidiControllerAssignment(candidate,
              int32(bus), int16(channel), Vst3CtrlNumber(controllerNumber), addr id)
            if resultCode == Vst3ResultOk:
              let slot = assignmentIndex(bus, channel, uint8(controllerNumber))
              bridge.cache.entries[int(slot)] =
                Vst3MidiAssignment(id: id, mapped: 1'u8)
            elif resultCode != Vst3ResultFalse and resultCode != Vst3NoInterface:
              discard mapping.lpVtbl.release(candidate)
              closeVst3EventBridge(bridge)
              return failure[ptr Vst3EventBridge](bridgeError(path, pluginId,
                "VST3 MIDI assignment query failed", "result=" & $resultCode))
            inc controllerNumber
          inc channel
        inc inputPort
      discard mapping.lpVtbl.release(candidate)
  bridge.initBridgeVtables()
  bridge.acceptedInput.storeRelaxed(0'u64)
  bridge.droppedInput.storeRelaxed(0'u64)
  bridge.malformedInput.storeRelaxed(0'u64)
  bridge.unmappedInput.storeRelaxed(0'u64)
  bridge.inputCapacityDrops.storeRelaxed(0'u64)
  bridge.jackLostInput.storeRelaxed(0'u64)
  bridge.acceptedOutput.storeRelaxed(0'u64)
  bridge.droppedOutput.storeRelaxed(0'u64)
  bridge.invalidOutput.storeRelaxed(0'u64)
  bridge.unsupportedOutput.storeRelaxed(0'u64)
  bridge.outputCapacityDrops.storeRelaxed(0'u64)
  bridge.parameterInputDrops.storeRelaxed(0'u64)
  bridge.parameterOutputDrops.storeRelaxed(0'u64)
  success(bridge)
