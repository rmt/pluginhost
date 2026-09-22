## Bounded VST3 parameter transport shared by the component-handler callbacks and
## the JACK process endpoint.  The storage is fixed-size POD; control-plane
## ownership is explicit and the callback side never allocates or locks.

import ../rt/atomic_pod
import ./ffi

const
  Vst3ParameterTransportCapacity* = 4_096'u32
  Vst3ParameterTransportValueCapacity* = 4_096'u32
  Vst3ParameterGestureCapacity* = 4_096'u32

type
  Vst3ParameterEditKind* = enum
    v3pekBegin
    v3pekPerform
    v3pekEnd

  Vst3ParameterEditRecord* {.bycopy.} = object
    kind*: Vst3ParameterEditKind
    id*: Vst3ParamID
    value*: Vst3ParamValue

  Vst3ParameterObservation* {.bycopy.} = object
    id*: Vst3ParamID
    value*: Vst3ParamValue
    sampleOffset*: int32

  Vst3ParameterTransport* {.bycopy.} = object
    inputWrite: RtAtomicU32
    inputRead: RtAtomicU32
    inputDropped: RtAtomicU64
    inputRecords: array[Vst3ParameterTransportCapacity, Vst3ParameterEditRecord]
    gestureWrite: RtAtomicU32
    gestureRead: RtAtomicU32
    gestureDropped: RtAtomicU64
    gestureRecords: array[Vst3ParameterGestureCapacity, Vst3ParameterEditRecord]
    outputWrite: RtAtomicU32
    outputRead: RtAtomicU32
    outputDropped: RtAtomicU64
    outputRecords: array[Vst3ParameterTransportValueCapacity,
      Vst3ParameterObservation]

proc newVst3ParameterTransport*(): ptr Vst3ParameterTransport =
  cast[ptr Vst3ParameterTransport](allocShared0(sizeof(Vst3ParameterTransport)))

proc closeVst3ParameterTransport*(transport: var ptr Vst3ParameterTransport) =
  if transport != nil:
    deallocShared(transport)
    transport = nil

{.push checks: off, stackTrace: off, lineTrace: off, overflowChecks: off.}
proc enqueueVst3ParameterEdit*(transport: ptr Vst3ParameterTransport;
                               edit: Vst3ParameterEditRecord): bool {.
    gcsafe, raises: [].} =
  if transport == nil:
    return false
  let write = transport.inputWrite.loadRelaxed()
  let read = transport.inputRead.loadAcquire()
  if write - read >= Vst3ParameterTransportCapacity:
    discard transport.inputDropped.fetchAddRelaxed(1'u64)
    return false
  transport.inputRecords[write mod Vst3ParameterTransportCapacity] = edit
  transport.inputWrite.storeRelease(write + 1'u32)
  let gestureWrite = transport.gestureWrite.loadRelaxed()
  let gestureRead = transport.gestureRead.loadAcquire()
  if gestureWrite - gestureRead >= Vst3ParameterGestureCapacity:
    discard transport.gestureDropped.fetchAddRelaxed(1'u64)
  else:
    transport.gestureRecords[gestureWrite mod Vst3ParameterGestureCapacity] = edit
    transport.gestureWrite.storeRelease(gestureWrite + 1'u32)
  true

proc dequeueVst3ParameterEdit*(transport: ptr Vst3ParameterTransport;
                               edit: var Vst3ParameterEditRecord): bool {.
    inline, gcsafe, raises: [].} =
  if transport == nil:
    return false
  let read = transport.inputRead.loadRelaxed()
  if read == transport.inputWrite.loadAcquire():
    return false
  edit = transport.inputRecords[read mod Vst3ParameterTransportCapacity]
  transport.inputRead.storeRelease(read + 1'u32)
  true

proc dequeueVst3ParameterGesture*(transport: ptr Vst3ParameterTransport;
                                  edit: var Vst3ParameterEditRecord): bool {.
    inline, gcsafe, raises: [].} =
  if transport == nil:
    return false
  let read = transport.gestureRead.loadRelaxed()
  if read == transport.gestureWrite.loadAcquire():
    return false
  edit = transport.gestureRecords[read mod Vst3ParameterGestureCapacity]
  transport.gestureRead.storeRelease(read + 1'u32)
  true

proc hasVst3ParameterObservationCapacity*(transport: ptr Vst3ParameterTransport;
                                          count: uint32): bool {.
    inline, gcsafe, raises: [].} =
  if transport == nil or count > Vst3ParameterTransportValueCapacity:
    return false
  let write = transport.outputWrite.loadRelaxed()
  let read = transport.outputRead.loadAcquire()
  write - read <= Vst3ParameterTransportValueCapacity - count

proc publishVst3ParameterObservation*(transport: ptr Vst3ParameterTransport;
                                      observation: Vst3ParameterObservation): bool {.
    inline, gcsafe, raises: [].} =
  if transport == nil:
    return false
  let write = transport.outputWrite.loadRelaxed()
  let read = transport.outputRead.loadAcquire()
  if write - read >= Vst3ParameterTransportValueCapacity:
    discard transport.outputDropped.fetchAddRelaxed(1'u64)
    return false
  transport.outputRecords[write mod Vst3ParameterTransportValueCapacity] = observation
  transport.outputWrite.storeRelease(write + 1'u32)
  true

proc dequeueVst3ParameterObservation*(transport: ptr Vst3ParameterTransport;
                                      observation: var Vst3ParameterObservation): bool {.
    gcsafe, raises: [].} =
  if transport == nil:
    return false
  let read = transport.outputRead.loadRelaxed()
  if read == transport.outputWrite.loadAcquire():
    return false
  observation = transport.outputRecords[read mod Vst3ParameterTransportValueCapacity]
  transport.outputRead.storeRelease(read + 1'u32)
  true

{.pop.}
proc droppedVst3ParameterEdits*(transport: ptr Vst3ParameterTransport): uint64 =
  if transport == nil: 0'u64 else: transport.inputDropped.loadAcquire()

proc droppedVst3ParameterObservations*(transport: ptr Vst3ParameterTransport): uint64 =
  if transport == nil: 0'u64 else: transport.outputDropped.loadAcquire()
proc droppedVst3ParameterGestures*(transport: ptr Vst3ParameterTransport): uint64 =
  if transport == nil: 0'u64 else: transport.gestureDropped.loadAcquire()
proc takeDroppedVst3ParameterEdits*(transport: ptr Vst3ParameterTransport): uint64 =
  if transport == nil: 0'u64 else: transport.inputDropped.exchangeAcquire(0'u64)
proc takeDroppedVst3ParameterGestures*(transport: ptr Vst3ParameterTransport): uint64 =
  if transport == nil: 0'u64 else: transport.gestureDropped.exchangeAcquire(0'u64)
