## Fixed-capacity CLAP MIDI/note event bridge for the internal process endpoint.
##
## Input events borrow backend bytes only for the current process call. Output
## events are validated and copied immediately into current backend buffers.

import std/typetraits

import ../domain/[errors, port_plan, result]
import ../rt/[atomic_pod, engine, midi_io, role_guard]
import ./[ffi, parameter_transport]

const
  ClapInputEventCapacity* = 4_096'u32
  ClapEventMaxPortsPerDirection* = RtMaxMidiPortsPerDirection

type
  ClapEventDialect = enum
    cedUnavailable
    cedRawMidi
    cedClapNotes

  ClapEventSlot {.union.} = object
    header: ClapEventHeader
    midi: ClapEventMidi
    sysex: ClapEventMidiSysex
    note: ClapEventNote
    expression: ClapEventNoteExpression

  InputCursor = object
    port: uint32
    sourceIndex: uint32
    sourceCount: uint32
    time: uint32
    event: ClapEventSlot

  ClapEventMetrics* {.bycopy.} = object
    acceptedInput*: uint64
    # droppedInput/droppedOutput are aggregate compatibility counters. The
    # category counters below are disjoint and are used for diagnostics.
    droppedInput*: uint64
    malformedInput*: uint64
    invalidInput*: uint64
    inputCapacityDrops*: uint64
    jackLostInput*: uint64
    acceptedOutput*: uint64
    droppedOutput*: uint64
    invalidOutput*: uint64
    outputCapacityDrops*: uint64

  ClapEventBridge* = object
    role: ptr AudioRoleGuard
    inputPortCount: uint32
    outputPortCount: uint32
    inputDialects: array[int(ClapEventMaxPortsPerDirection), ClapEventDialect]
    outputCapabilities: array[int(ClapEventMaxPortsPerDirection), uint8]
    sysexInProgress: array[int(ClapEventMaxPortsPerDirection), bool]
    inputLastTime: array[int(ClapEventMaxPortsPerDirection), uint32]
    inputHasTime: array[int(ClapEventMaxPortsPerDirection), bool]
    slots: array[int(ClapInputEventCapacity), ClapEventSlot]
    heap: array[int(ClapEventMaxPortsPerDirection), InputCursor]
    heapCount: uint32
    eventCount: uint32
    currentFrames: uint32
    lastOutputTime: uint32
    hasOutputTime: bool
    parameters: ptr ClapParameterTransport
    cycleActive: RtAtomicU32
    currentEngineAddress: RtAtomicU64
    acceptedInput: RtAtomicU64
    droppedInput: RtAtomicU64
    malformedInput: RtAtomicU64
    invalidInput: RtAtomicU64
    inputCapacityDrops: RtAtomicU64
    jackLostInput: RtAtomicU64
    acceptedOutput: RtAtomicU64
    droppedOutput: RtAtomicU64
    invalidOutput: RtAtomicU64
    outputCapacityDrops: RtAtomicU64
    inputEvents*: ClapInputEvents
    outputEvents*: ClapOutputEvents

static:
  doAssert supportsCopyMem(ClapEventSlot)
  doAssert supportsCopyMem(InputCursor)
  doAssert supportsCopyMem(ClapEventMetrics)
  doAssert supportsCopyMem(ClapEventBridge)
  doAssert sizeof(pointer) == sizeof(uint64)

proc eventError(path, pluginId, message, detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsClap, hekClapProcess, message, context)

proc eventCapabilities(port: NotePortPlan): uint8 =
  if ndMidi in port.supportedDialects or ndMidiMpe in port.supportedDialects:
    result = result or 1'u8
  if ndClap in port.supportedDialects:
    result = result or 2'u8

proc selectedDialect(port: NotePortPlan): ClapEventDialect =
  if ndMidi in port.supportedDialects or ndMidiMpe in port.supportedDialects:
    cedRawMidi
  elif ndClap in port.supportedDialects:
    cedClapNotes
  else:
    cedUnavailable

{.push checks: off, stackTrace: off, lineTrace: off.}
proc eventHeader(eventType: uint16; size, time: uint32): ClapEventHeader {.
    inline, gcsafe, raises: [].} =
  ClapEventHeader(
    size: size,
    time: time,
    spaceId: ClapCoreEventSpaceId,
    `type`: eventType,
    flags: ClapEventIsLive,
  )

proc midiMessageLength(status: uint8): uint32 {.inline, gcsafe, raises: [].} =
  if status < 0x80'u8:
    return 0'u32
  case status and 0xf0'u8
  of 0x80'u8, 0x90'u8, 0xa0'u8, 0xb0'u8, 0xe0'u8:
    3'u32
  of 0xc0'u8, 0xd0'u8:
    2'u32
  of 0xf0'u8:
    case status
    of 0xf1'u8, 0xf3'u8: 2'u32
    of 0xf2'u8: 3'u32
    of 0xf6'u8, 0xf8'u8, 0xfa'u8, 0xfb'u8, 0xfc'u8, 0xfe'u8,
       0xff'u8: 1'u32
    else: 0'u32
  else:
    0'u32

proc midiDataValid(data: ptr UncheckedArray[uint8]; size: uint32): bool {.
    inline, gcsafe, raises: [].} =
  if data == nil or size == 0'u32:
    return false
  var index = 1'u32
  while index < size:
    if data[int(index)] >= 0x80'u8:
      return false
    index += 1'u32
  true

proc noteVelocity(value: uint8): cdouble {.inline, gcsafe, raises: [].} =
  cdouble(value) / 127.0

proc translateInput(bridge: ptr ClapEventBridge; port: uint32;
                    source: RtMidiEventView; destination: var ClapEventSlot): bool {.
    gcsafe, raises: [].} =
  if source.size == 0'u32 or source.data == nil:
    return false
  let first = source.data[0]
  let last = source.data[int(source.size - 1'u32)]
  let continued = bridge.sysexInProgress[int(port)]
  let isRealtime = source.size == 1'u32 and first >= 0xf8'u8 and
    midiMessageLength(first) == 1'u32
  let isSysex = first == 0xf0'u8 or (continued and not isRealtime)
  if isSysex:
    if first == 0xf0'u8:
      bridge.sysexInProgress[int(port)] = last != 0xf7'u8
    elif continued and last == 0xf7'u8:
      bridge.sysexInProgress[int(port)] = false
    if bridge.inputDialects[int(port)] != cedRawMidi:
      return false
    destination.sysex = ClapEventMidiSysex(
      header: eventHeader(ClapEventTypeMidiSysex,
        uint32(sizeof(ClapEventMidiSysex)), source.time),
      portIndex: uint16(port),
      buffer: cast[ptr uint8](source.data),
      size: source.size,
    )
    return true

  let expected = midiMessageLength(first)
  if expected == 0'u32 or expected != source.size or
      not midiDataValid(source.data, source.size):
    return false
  case bridge.inputDialects[int(port)]
  of cedRawMidi:
    destination.midi = ClapEventMidi(
      header: eventHeader(ClapEventTypeMidi,
        uint32(sizeof(ClapEventMidi)), source.time),
      portIndex: uint16(port),
    )
    var index = 0'u32
    while index < source.size:
      destination.midi.data[int(index)] = source.data[int(index)]
      index += 1'u32
    true
  of cedClapNotes:
    let message = first and 0xf0'u8
    let channel = int16(first and 0x0f'u8)
    if message == 0x80'u8 or message == 0x90'u8:
      let noteOff = message == 0x80'u8 or source.data[2] == 0'u8
      destination.note = ClapEventNote(
        header: eventHeader(
          if noteOff: ClapEventTypeNoteOff else: ClapEventTypeNoteOn,
          uint32(sizeof(ClapEventNote)), source.time),
        noteId: -1,
        portIndex: int16(port),
        channel: channel,
        key: int16(source.data[1]),
        velocity: noteVelocity(source.data[2]),
      )
      true
    elif message == 0xa0'u8:
      destination.expression = ClapEventNoteExpression(
        header: eventHeader(ClapEventTypeNoteExpression,
          uint32(sizeof(ClapEventNoteExpression)), source.time),
        expressionId: ClapNoteExpressionPressure,
        noteId: -1,
        portIndex: int16(port),
        channel: channel,
        key: int16(source.data[1]),
        value: noteVelocity(source.data[2]),
      )
      true
    else:
      false
  of cedUnavailable:
    false

proc cursorLess(left, right: InputCursor): bool {.inline, gcsafe, raises: [].} =
  if left.time != right.time:
    return left.time < right.time
  if left.port != right.port:
    return left.port < right.port
  left.sourceIndex < right.sourceIndex

proc heapPush(bridge: ptr ClapEventBridge; cursor: InputCursor) {.
    gcsafe, raises: [].} =
  var position = bridge.heapCount
  bridge.heapCount += 1'u32
  while position > 0'u32:
    let parent = (position - 1'u32) div 2'u32
    if not cursor.cursorLess(bridge.heap[int(parent)]):
      break
    bridge.heap[int(position)] = bridge.heap[int(parent)]
    position = parent
  bridge.heap[int(position)] = cursor

proc heapPop(bridge: ptr ClapEventBridge): InputCursor {.
    gcsafe, raises: [].} =
  result = bridge.heap[0]
  bridge.heapCount -= 1'u32
  if bridge.heapCount == 0'u32:
    return
  let replacement = bridge.heap[int(bridge.heapCount)]
  var position = 0'u32
  while true:
    let left = position * 2'u32 + 1'u32
    if left >= bridge.heapCount:
      break
    let right = left + 1'u32
    var child = left
    if right < bridge.heapCount and
        bridge.heap[int(right)].cursorLess(bridge.heap[int(left)]):
      child = right
    if not bridge.heap[int(child)].cursorLess(replacement):
      break
    bridge.heap[int(position)] = bridge.heap[int(child)]
    position = child
  bridge.heap[int(position)] = replacement

proc nextCursor(bridge: ptr ClapEventBridge; engine: ptr RtEngine;
                port, firstIndex, count, nframes: uint32;
                cursor: var InputCursor): bool {.gcsafe, raises: [].} =
  var index = firstIndex
  let buffer = engine.noteInputBuffers[int(port)]
  while index < count:
    var source: RtMidiEventView
    if not engine.midiIo.eventGet(
        engine.midiIo.context, buffer, index, addr source):
      discard bridge.malformedInput.fetchAddRelaxed(1'u64)
      discard bridge.droppedInput.fetchAddRelaxed(1'u64)
      index += 1'u32
      continue
    if source.time >= nframes or
        (bridge.inputHasTime[int(port)] and
         source.time < bridge.inputLastTime[int(port)]):
      discard bridge.malformedInput.fetchAddRelaxed(1'u64)
      discard bridge.droppedInput.fetchAddRelaxed(1'u64)
      index += 1'u32
      continue
    bridge.inputHasTime[int(port)] = true
    bridge.inputLastTime[int(port)] = source.time
    var translated: ClapEventSlot
    if not bridge.translateInput(port, source, translated):
      discard bridge.invalidInput.fetchAddRelaxed(1'u64)
      discard bridge.droppedInput.fetchAddRelaxed(1'u64)
      index += 1'u32
      continue
    cursor = InputCursor(
      port: port,
      sourceIndex: index,
      sourceCount: count,
      time: source.time,
      event: translated,
    )
    return true
  false

proc inputSize(list: ptr ClapInputEvents): uint32 {.
    exportc: "pluginhost_clap_input_event_size", cdecl, gcsafe, raises: [].} =
  if list == nil or list.ctx == nil:
    return 0'u32
  let bridge = cast[ptr ClapEventBridge](list.ctx)
  if bridge.cycleActive.loadAcquire() == 0'u32 or
      not isAudioRoleThread(bridge.role):
    return 0'u32
  bridge.eventCount

proc inputGet(list: ptr ClapInputEvents; index: uint32): ptr ClapEventHeader {.
    exportc: "pluginhost_clap_input_event_get", cdecl, gcsafe, raises: [].} =
  if list == nil or list.ctx == nil:
    return nil
  let bridge = cast[ptr ClapEventBridge](list.ctx)
  if bridge.cycleActive.loadAcquire() == 0'u32 or
      not isAudioRoleThread(bridge.role) or index >= bridge.eventCount:
    return nil
  addr bridge.slots[int(index)].header

proc outputPort(event: ptr ClapEventHeader): int32 {.inline, gcsafe, raises: [].} =
  case event.`type`
  of ClapEventTypeMidi:
    if event.size < uint32(sizeof(ClapEventMidi)): -1 else:
      int32(cast[ptr ClapEventMidi](event).portIndex)
  of ClapEventTypeMidiSysex:
    if event.size < uint32(sizeof(ClapEventMidiSysex)): -1 else:
      int32(cast[ptr ClapEventMidiSysex](event).portIndex)
  of ClapEventTypeNoteOn, ClapEventTypeNoteOff:
    if event.size < uint32(sizeof(ClapEventNote)): -1 else:
      int32(cast[ptr ClapEventNote](event).portIndex)
  else:
    -1

proc noteEndValid(event: ptr ClapEventHeader): bool {.inline, gcsafe, raises: [].} =
  if event == nil or event.size < uint32(sizeof(ClapEventNote)):
    return false
  let note = cast[ptr ClapEventNote](event)
  note.noteId >= -1 and note.portIndex >= -1 and note.channel >= -1 and
    note.channel <= 15 and note.key >= -1 and note.key <= 127

proc reserveAndCopy(bridge: ptr ClapEventBridge; engine: ptr RtEngine;
                    port, time, size: uint32;
                    source: ptr UncheckedArray[uint8];
                    capacityDropped: var bool): bool {.
    gcsafe, raises: [].} =
  if source == nil or size == 0'u32:
    return false
  let buffer = engine.noteOutputBuffers[int(port)]
  if buffer == nil:
    return false
  let destination = engine.midiIo.reserve(
    engine.midiIo.context, buffer, time, size)
  if destination == nil:
    capacityDropped = true
    discard bridge.outputCapacityDrops.fetchAddRelaxed(1'u64)
    return false
  var index = 0'u32
  while index < size:
    destination[int(index)] = source[int(index)]
    index += 1'u32
  true

proc outputTryPush(list: ptr ClapOutputEvents;
                   event: ptr ClapEventHeader): bool {.
    exportc: "pluginhost_clap_output_event_try_push", cdecl, gcsafe,
    raises: [].} =
  if list == nil or list.ctx == nil or event == nil:
    return false
  let bridge = cast[ptr ClapEventBridge](list.ctx)
  let engineAddress = bridge.currentEngineAddress.loadAcquire()
  if bridge.cycleActive.loadAcquire() == 0'u32 or engineAddress == 0'u64 or
      not isAudioRoleThread(bridge.role):
    discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    return false
  let engine = cast[ptr RtEngine](engineAddress)
  if event.spaceId != ClapCoreEventSpaceId:
    discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    return false
  if event.`type` == ClapEventTypeNoteEnd:
    # NOTE_END is a valid plugin-to-host voice-lifetime notification. This
    # host has no CLAP voice allocator and JACK MIDI has no equivalent, so
    # consume it without turning it into a duplicate MIDI NoteOff. Its time
    # field is explicitly ignored by CLAP.
    if not noteEndValid(event):
      discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
      discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
      return false
    discard bridge.acceptedOutput.fetchAddRelaxed(1'u64)
    return true
  if event.time >= bridge.currentFrames or
      (bridge.hasOutputTime and event.time < bridge.lastOutputTime):
    discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    return false
  if event.`type` in {ClapEventTypeParamValue, ClapEventTypeParamMod,
      ClapEventTypeParamGestureBegin, ClapEventTypeParamGestureEnd}:
    let accepted = bridge.parameters.tryPushOutput(event, bridge.currentFrames)
    if accepted:
      bridge.lastOutputTime = event.time
      bridge.hasOutputTime = true
    return accepted
  let rawPort = outputPort(event)
  if rawPort < 0 or uint32(rawPort) >= bridge.outputPortCount:
    discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    return false
  let port = uint32(rawPort)
  var capacityDropped = false
  var accepted = false
  case event.`type`
  of ClapEventTypeMidi:
    if event.size >= uint32(sizeof(ClapEventMidi)) and
        (bridge.outputCapabilities[int(port)] and 1'u8) != 0'u8:
      let midi = cast[ptr ClapEventMidi](event)
      let size = midiMessageLength(midi.data[0])
      if size != 0'u32 and midiDataValid(
          cast[ptr UncheckedArray[uint8]](addr midi.data[0]), size):
        accepted = bridge.reserveAndCopy(
          engine, port, event.time, size,
          cast[ptr UncheckedArray[uint8]](addr midi.data[0]), capacityDropped)
  of ClapEventTypeMidiSysex:
    if event.size >= uint32(sizeof(ClapEventMidiSysex)) and
        (bridge.outputCapabilities[int(port)] and 1'u8) != 0'u8:
      let sysex = cast[ptr ClapEventMidiSysex](event)
      accepted = bridge.reserveAndCopy(
        engine, port, event.time, sysex.size,
        cast[ptr UncheckedArray[uint8]](sysex.buffer), capacityDropped)
  of ClapEventTypeNoteOn, ClapEventTypeNoteOff:
    if event.size >= uint32(sizeof(ClapEventNote)) and
        (bridge.outputCapabilities[int(port)] and 2'u8) != 0'u8:
      let note = cast[ptr ClapEventNote](event)
      if note.channel >= 0 and note.channel <= 15 and note.key >= 0 and
          note.key <= 127 and note.velocity >= 0.0 and note.velocity <= 1.0:
        var bytes: array[3, uint8]
        bytes[0] = (if event.`type` == ClapEventTypeNoteOn: 0x90'u8 else: 0x80'u8) or
          uint8(note.channel)
        bytes[1] = uint8(note.key)
        bytes[2] = uint8(int(note.velocity * 127.0 + 0.5))
        accepted = bridge.reserveAndCopy(
          engine, port, event.time, 3'u32,
          cast[ptr UncheckedArray[uint8]](addr bytes[0]), capacityDropped)
  else:
    discard

  if not accepted:
    discard bridge.droppedOutput.fetchAddRelaxed(1'u64)
    if not capacityDropped:
      discard bridge.invalidOutput.fetchAddRelaxed(1'u64)
    return false
  bridge.lastOutputTime = event.time
  bridge.hasOutputTime = true
  discard bridge.acceptedOutput.fetchAddRelaxed(1'u64)
  true

proc beginEventCycle*(bridge: ptr ClapEventBridge; engine: ptr RtEngine;
                      nframes: uint32): bool {.
    exportc: "pluginhost_clap_event_cycle_begin", cdecl, gcsafe, raises: [].} =
  if bridge == nil or engine == nil or nframes == 0'u32 or
      bridge.cycleActive.loadAcquire() != 0'u32 or
      not isAudioRoleThread(bridge.role) or
      bridge.inputPortCount != engine.noteInputCount or
      bridge.outputPortCount != engine.noteOutputCount or
      (bridge.inputPortCount != 0'u32 and not engine.midiIo.isReadable) or
      (bridge.outputPortCount != 0'u32 and not engine.midiIo.isWritable):
    return false
  bridge.heapCount = 0'u32
  bridge.eventCount = 0'u32
  bridge.currentFrames = nframes
  bridge.hasOutputTime = false

  var port = 0'u32
  while port < bridge.inputPortCount:
    bridge.inputHasTime[int(port)] = false
    let buffer = engine.noteInputBuffers[int(port)]
    if buffer == nil:
      return false
    if engine.midiIo.lostEventCount != nil:
      let lost = engine.midiIo.lostEventCount(engine.midiIo.context, buffer)
      if lost != 0'u32:
        discard bridge.jackLostInput.fetchAddRelaxed(uint64(lost))
    let count = engine.midiIo.eventCount(engine.midiIo.context, buffer)
    var cursor: InputCursor
    if bridge.nextCursor(engine, port, 0'u32, count, nframes, cursor):
      bridge.heapPush(cursor)
    port += 1'u32

  while bridge.heapCount != 0'u32 and
      bridge.eventCount < ClapInputEventCapacity:
    let cursor = bridge.heapPop()
    bridge.slots[int(bridge.eventCount)] = cursor.event
    bridge.eventCount += 1'u32
    discard bridge.acceptedInput.fetchAddRelaxed(1'u64)
    var following: InputCursor
    if bridge.nextCursor(engine, cursor.port, cursor.sourceIndex + 1'u32,
                         cursor.sourceCount, nframes, following):
      bridge.heapPush(following)

  if bridge.heapCount != 0'u32:
    var overflow = 0'u64
    while bridge.heapCount != 0'u32:
      let cursor = bridge.heapPop()
      overflow += uint64(cursor.sourceCount - cursor.sourceIndex)
    discard bridge.inputCapacityDrops.fetchAddRelaxed(overflow)
    discard bridge.droppedInput.fetchAddRelaxed(overflow)

  bridge.currentEngineAddress.storeRelease(cast[uint64](engine))
  bridge.cycleActive.storeRelease(1'u32)
  true

proc endEventCycle*(bridge: ptr ClapEventBridge) {.
    exportc: "pluginhost_clap_event_cycle_end", cdecl, gcsafe, raises: [].} =
  if bridge == nil:
    return
  bridge.cycleActive.storeRelease(0'u32)
  bridge.currentEngineAddress.storeRelease(0'u64)
  bridge.currentFrames = 0'u32
  bridge.eventCount = 0'u32
proc hasInputEvents*(bridge: ptr ClapEventBridge): bool {.inline, gcsafe,
    raises: [].} =
  bridge != nil and bridge.eventCount != 0'u32

{.pop.}

proc initClapEventBridge*(bridge: ptr ClapEventBridge; plan: PortPlan;
                           parameters: ptr ClapParameterTransport;
                          role: ptr AudioRoleGuard; path, pluginId: string):
    Result[Unit] =
  if bridge == nil or role == nil:
    return failure[Unit](eventError(
      path, pluginId, "CLAP event processing requires a stable audio role", ""))
  if parameters == nil:
    return failure[Unit](eventError(
      path, pluginId, "CLAP event processing requires parameter transport", ""))
  bridge.role = role
  bridge.parameters = parameters
  var inputCount = 0'u32
  var outputCount = 0'u32
  for port in plan.notePorts:
    let expected = if port.direction == pdInput: inputCount else: outputCount
    if port.index != expected or expected >= ClapEventMaxPortsPerDirection:
      return failure[Unit](eventError(
        path, pluginId, "CLAP note ports exceed or violate the event capacity",
        "direction=" & $port.direction & "; index=" & $port.index))
    let dialect = port.selectedDialect
    if dialect == cedUnavailable:
      return failure[Unit](eventError(
        path, pluginId, "CLAP note port has no supported MIDI 1.0 or CLAP dialect",
        "direction=" & $port.direction & "; index=" & $port.index))
    if port.direction == pdInput:
      bridge.inputDialects[int(inputCount)] = dialect
      inputCount += 1'u32
    else:
      bridge.outputCapabilities[int(outputCount)] = port.eventCapabilities
      outputCount += 1'u32
  bridge.inputPortCount = inputCount
  bridge.outputPortCount = outputCount
  bridge.cycleActive.storeRelaxed(0'u32)
  bridge.currentEngineAddress.storeRelaxed(0'u64)
  bridge.acceptedInput.storeRelaxed(0'u64)
  bridge.droppedInput.storeRelaxed(0'u64)
  bridge.malformedInput.storeRelaxed(0'u64)
  bridge.invalidInput.storeRelaxed(0'u64)
  bridge.inputCapacityDrops.storeRelaxed(0'u64)
  bridge.jackLostInput.storeRelaxed(0'u64)
  bridge.acceptedOutput.storeRelaxed(0'u64)
  bridge.droppedOutput.storeRelaxed(0'u64)
  bridge.invalidOutput.storeRelaxed(0'u64)
  bridge.outputCapacityDrops.storeRelaxed(0'u64)
  bridge.inputEvents = ClapInputEvents(
    ctx: cast[pointer](bridge), size: inputSize, get: inputGet)
  bridge.outputEvents = ClapOutputEvents(
    ctx: cast[pointer](bridge), tryPush: outputTryPush)
  success()

proc takeEventMetrics*(bridge: ptr ClapEventBridge): ClapEventMetrics =
  if bridge == nil:
    return
  result.acceptedInput = bridge.acceptedInput.exchangeAcquire(0'u64)
  result.droppedInput = bridge.droppedInput.exchangeAcquire(0'u64)
  result.malformedInput = bridge.malformedInput.exchangeAcquire(0'u64)
  result.invalidInput = bridge.invalidInput.exchangeAcquire(0'u64)
  result.inputCapacityDrops = bridge.inputCapacityDrops.exchangeAcquire(0'u64)
  result.jackLostInput = bridge.jackLostInput.exchangeAcquire(0'u64)
  result.acceptedOutput = bridge.acceptedOutput.exchangeAcquire(0'u64)
  result.droppedOutput = bridge.droppedOutput.exchangeAcquire(0'u64)
  result.invalidOutput = bridge.invalidOutput.exchangeAcquire(0'u64)
  result.outputCapacityDrops = bridge.outputCapacityDrops.exchangeAcquire(0'u64)

{.push checks: off, stackTrace: off, lineTrace: off.}
proc isEventCycleActive*(bridge: ptr ClapEventBridge): bool {.
    exportc: "pluginhost_clap_event_cycle_active", cdecl, gcsafe, raises: [].} =
  bridge != nil and bridge.cycleActive.loadAcquire() != 0'u32
{.pop.}
