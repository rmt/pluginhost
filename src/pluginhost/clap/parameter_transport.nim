## Fixed-capacity parameter output transport shared by CLAP process()/flush()
## producers and the main-thread control plane.
##
## Plugin cookies are deliberately never retained: they are invalidated by a
## parameter rescan and are not needed by the host's no-automation policy.

import std/typetraits

import ../rt/atomic_pod
import ./ffi

const
  ClapParameterEventCapacity* = 4_096'u64


type
  ClapParameterEventKind* = enum
    cpekValue
    cpekModulation
    cpekGestureBegin
    cpekGestureEnd

  ClapParameterEvent* {.bycopy.} = object
    kind*: ClapParameterEventKind
    paramId*: ClapId
    time*: uint32
    flags*: uint32
    noteId*: int32
    portIndex*: int16
    channel*: int16
    key*: int16
    value*: cdouble

  ClapParameterMetrics* {.bycopy.} = object
    accepted*: uint64
    dropped*: uint64
    invalid*: uint64
    capacityDrops*: uint64

  ClapParameterTransport* = object
    writePosition: RtAtomicU64
    readPosition: RtAtomicU64
    entries: array[int(ClapParameterEventCapacity), ClapParameterEvent]
    accepted: RtAtomicU64
    dropped: RtAtomicU64
    invalid: RtAtomicU64
    capacityDrops: RtAtomicU64
    emptyInputEvents*: ClapInputEvents
    outputEvents*: ClapOutputEvents

static:
  doAssert (ClapParameterEventCapacity and (ClapParameterEventCapacity - 1'u64)) == 0'u64
  doAssert supportsCopyMem(ClapParameterEvent)
  doAssert supportsCopyMem(ClapParameterMetrics)
  doAssert supportsCopyMem(ClapParameterTransport)

{.push checks: off, stackTrace: off, lineTrace: off.}

proc emptyInputSize(list: ptr ClapInputEvents): uint32 {.
    exportc: "pluginhost_clap_parameter_empty_input_size", cdecl, gcsafe,
    raises: [].} =
  discard list
  0'u32

proc emptyInputGet(list: ptr ClapInputEvents; index: uint32): ptr ClapEventHeader {.
    exportc: "pluginhost_clap_parameter_empty_input_get", cdecl, gcsafe,
    raises: [].} =
  discard list
  discard index
  nil

proc finite(value: cdouble): bool {.inline, gcsafe, raises: [].} =
  value == value and value >= -1.7976931348623157e308 and
    value <= 1.7976931348623157e308

proc decodeParameterEvent(event: ptr ClapEventHeader; maxFrames: uint32;
                          flush: bool; output: var ClapParameterEvent): bool {.
    gcsafe, raises: [].} =
  if event == nil or event.spaceId != ClapCoreEventSpaceId or
      (flush and event.time != 0'u32) or
      (not flush and (maxFrames == 0'u32 or event.time >= maxFrames)):
    return false
  case event.`type`
  of ClapEventTypeParamValue:
    if event.size < uint32(sizeof(ClapEventParamValue)):
      return false
    let source = cast[ptr ClapEventParamValue](event)
    if not source.value.finite:
      return false
    output = ClapParameterEvent(
      kind: cpekValue, paramId: source.paramId, time: event.time,
      flags: event.flags, noteId: source.noteId, portIndex: source.portIndex,
      channel: source.channel, key: source.key, value: source.value,
    )
  of ClapEventTypeParamMod:
    if event.size < uint32(sizeof(ClapEventParamMod)):
      return false
    let source = cast[ptr ClapEventParamMod](event)
    if not source.amount.finite:
      return false
    output = ClapParameterEvent(
      kind: cpekModulation, paramId: source.paramId, time: event.time,
      flags: event.flags, noteId: source.noteId, portIndex: source.portIndex,
      channel: source.channel, key: source.key, value: source.amount,
    )
  of ClapEventTypeParamGestureBegin, ClapEventTypeParamGestureEnd:
    if event.size < uint32(sizeof(ClapEventParamGesture)):
      return false
    let source = cast[ptr ClapEventParamGesture](event)
    output = ClapParameterEvent(
      kind: if event.`type` == ClapEventTypeParamGestureBegin:
        cpekGestureBegin else: cpekGestureEnd,
      paramId: source.paramId, time: event.time, flags: event.flags,
    )
  else:
    return false
  true

proc tryPush(transport: ptr ClapParameterTransport;
             event: ClapParameterEvent): bool {.gcsafe, raises: [].} =
  if transport == nil:
    return false
  let write = transport.writePosition.loadRelaxed()
  let read = transport.readPosition.loadAcquire()
  if write - read >= ClapParameterEventCapacity:
    discard transport.dropped.fetchAddRelaxed(1'u64)
    discard transport.capacityDrops.fetchAddRelaxed(1'u64)
    return false
  transport.entries[int(write and (ClapParameterEventCapacity - 1'u64))] = event
  transport.writePosition.storeRelease(write + 1'u64)
  discard transport.accepted.fetchAddRelaxed(1'u64)
  true

proc tryPushOutput*(transport: ptr ClapParameterTransport;
                    event: ptr ClapEventHeader; maxFrames: uint32;
                    flush = false): bool {.gcsafe, raises: [].} =
  if transport == nil:
    return false
  var copied: ClapParameterEvent
  if not decodeParameterEvent(event, maxFrames, flush, copied):
    discard transport.invalid.fetchAddRelaxed(1'u64)
    discard transport.dropped.fetchAddRelaxed(1'u64)
    return false
  transport.tryPush(copied)

proc outputTryPush(list: ptr ClapOutputEvents;
                   event: ptr ClapEventHeader): bool {.
    exportc: "pluginhost_clap_parameter_output_try_push", cdecl, gcsafe,
    raises: [].} =
  if list == nil or list.ctx == nil:
    return false
  let transport = cast[ptr ClapParameterTransport](list.ctx)
  transport.tryPushOutput(event, 1'u32, true)

{.pop.}

proc newClapParameterTransport*(): ptr ClapParameterTransport =
  result = cast[ptr ClapParameterTransport](allocShared0(sizeof(ClapParameterTransport)))
  if result == nil:
    return nil
  result.writePosition.storeRelaxed(0'u64)
  result.readPosition.storeRelaxed(0'u64)
  result.accepted.storeRelaxed(0'u64)
  result.dropped.storeRelaxed(0'u64)
  result.invalid.storeRelaxed(0'u64)
  result.capacityDrops.storeRelaxed(0'u64)
  result.emptyInputEvents = ClapInputEvents(
    ctx: nil, size: emptyInputSize, get: emptyInputGet)
  result.outputEvents = ClapOutputEvents(
    ctx: cast[pointer](result), tryPush: outputTryPush)

proc tryPop*(transport: ptr ClapParameterTransport;
             event: var ClapParameterEvent): bool =
  if transport == nil:
    return false
  let read = transport.readPosition.loadRelaxed()
  if read == transport.writePosition.loadAcquire():
    return false
  event = transport.entries[int(read and (ClapParameterEventCapacity - 1'u64))]
  transport.readPosition.storeRelease(read + 1'u64)
  true

proc takeMetrics*(transport: ptr ClapParameterTransport): ClapParameterMetrics =
  if transport == nil:
    return
  result.accepted = transport.accepted.exchangeAcquire(0'u64)
  result.dropped = transport.dropped.exchangeAcquire(0'u64)
  result.invalid = transport.invalid.exchangeAcquire(0'u64)
  result.capacityDrops = transport.capacityDrops.exchangeAcquire(0'u64)

proc close*(transport: var ptr ClapParameterTransport) =
  if transport != nil:
    deallocShared(transport)
    transport = nil
