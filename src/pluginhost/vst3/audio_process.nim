## Preallocated VST3 float32 ProcessData and JACK endpoint.
## The callback owns no managed values and performs no native storage changes; all
## bus/queue/container addresses are frozen before JACK activation.

import std/[posix, typetraits]

import ../domain/[errors, port_plan, result]
import ../rt/[atomic_pod, engine, role_guard]
import ./[event_bridge, ffi, parameter_transport, uid]
const
  Vst3AudioProcessMaxFrames* = uint32(high(int32))
  Vst3AudioProcessMaxParameterPoints* = 16_384'u32
  Vst3AudioProcessMaxParameterPointsPerQueue* = 64'u32
  Vst3AudioProcessMaxEvents* = 4_096'u32
  Vst3AudioProcessMaxParameterQueues* = 4_096'u32

  Vst3EventListIidBytes: array[16, uint8] =
    [0x3A'u8, 0x2C, 0x42, 0x14, 0x34, 0x63, 0x49, 0xFE,
     0xB2, 0xC4, 0xF3, 0x97, 0xB9, 0x69, 0x5A, 0x44]
  Vst3ParameterChangesIidBytes: array[16, uint8] =
    [0xA4'u8, 0x77, 0x96, 0x63, 0x0B, 0xB6, 0x4A, 0x56,
     0xB4, 0x43, 0x84, 0xA8, 0x46, 0x6F, 0xEB, 0x9D]
  Vst3ParamValueQueueIidBytes: array[16, uint8] =
    [0x01'u8, 0x26, 0x3A, 0x18, 0xED, 0x07, 0x4F, 0x6F,
     0x98, 0xC9, 0xD3, 0x56, 0x46, 0x86, 0xF9, 0xBA]
  Vst3FUnknownIidBytes: array[16, uint8] =
    [0'u8, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46]

type
  Vst3ParameterQueueState = object
    iface: Vst3ParamValueQueue
    vtable: Vst3ParamValueQueueVtbl
    owner: pointer
    output: bool
    id: Vst3ParamID
    points: uint32
    offsets: array[Vst3AudioProcessMaxParameterPointsPerQueue, int32]
    values: array[Vst3AudioProcessMaxParameterPointsPerQueue, Vst3ParamValue]

  Vst3ParameterChangesState = object
    iface: Vst3ParameterChanges
    vtable: Vst3ParameterChangesVtbl
    owner: pointer
    output: bool
    queues: uint32
    queueValues: array[Vst3AudioProcessMaxParameterQueues,
      ptr Vst3ParameterQueueState]

  Vst3AudioProcessContext = object
    processor: ptr Vst3AudioProcessor
    role: ptr AudioRoleGuard
    transport: ptr Vst3ParameterTransport
    eventBridge: ptr Vst3EventBridge
    maxFrames: uint32
    currentFrames: uint32
    sampleRate: float64
    samplePosition: int64
    inputBusCount: uint32
    outputBusCount: uint32
    inputChannelCount: uint32
    outputChannelCount: uint32
    inputs: array[Vst3MaxBusCount, Vst3AudioBusBuffers]
    outputs: array[Vst3MaxBusCount, Vst3AudioBusBuffers]
    inputPointers: array[Vst3MaxBusChannels, ptr UncheckedArray[cfloat]]
    outputPointers: array[Vst3MaxBusChannels, ptr UncheckedArray[cfloat]]
    inputFirst: array[Vst3MaxBusCount, uint32]
    outputFirst: array[Vst3MaxBusCount, uint32]
    inputChannelCounts: array[Vst3MaxBusCount, uint32]
    outputChannelCounts: array[Vst3MaxBusCount, uint32]
    processContext: Vst3ProcessContext
    processData: Vst3ProcessData
    inputChanges: Vst3ParameterChangesState
    outputChanges: Vst3ParameterChangesState
    inputQueues: array[Vst3AudioProcessMaxParameterQueues,
      Vst3ParameterQueueState]
    outputQueues: array[Vst3AudioProcessMaxParameterQueues,
      Vst3ParameterQueueState]
    outputObservations: array[Vst3AudioProcessMaxParameterPoints,
      Vst3ParameterObservation]
    callsInFlight: RtAtomicU32
    faultLatched: RtAtomicU32
    inputPoints: uint32
    outputPoints: uint32
    processCalls: uint64
    lastResult: int32

  Vst3ActivatedBus* {.bycopy.} = object
    mediaType*: Vst3MediaType
    direction*: Vst3BusDirection
    index*: int32

  Vst3BusActivationLedger* {.bycopy.} = object
    entries*: array[Vst3MaxBusCount * 4, Vst3ActivatedBus]
    count*: uint32

  Vst3AudioProcess* = object
    context: ptr Vst3AudioProcessContext

static:
  doAssert sizeof(Vst3AudioBusBuffers) == (sizeof(pointer) * 2 + 8)
  doAssert supportsCopyMem(Vst3ProcessSetup)
  doAssert supportsCopyMem(Vst3ProcessData)
  doAssert supportsCopyMem(Vst3ProcessContext)

proc vst3ProcessError(kind: HostErrorKind; message, path, pluginId,
                      detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0: context.add("; " & detail)
  hostError(hsVst3, kind, message, context)

proc `=destroy`*(process: var Vst3AudioProcess) =
  doAssert process.context == nil,
    "an active VST3 audio process must be explicitly closed"

proc `=copy`*(destination: var Vst3AudioProcess;
              source: Vst3AudioProcess) {.error:
  "Vst3AudioProcess owns shared storage and cannot be copied; use move".}
proc `=dup`*(source: Vst3AudioProcess): Vst3AudioProcess {.error:
  "Vst3AudioProcess owns shared storage and cannot be duplicated; use move".}
proc `=sink`*(destination: var Vst3AudioProcess;
              source: Vst3AudioProcess) =
  doAssert destination.context == nil,
    "a VST3 audio process must be closed before move assignment"
  destination.context = source.context

{.push checks: off, stackTrace: off, lineTrace: off, overflowChecks: off.}
proc iidMatches(iid: ptr Vst3Tuid; expected: array[16, uint8]): bool {.
    inline, gcsafe, raises: [].} =
  if iid == nil: return false
  for index in 0 ..< 16:
    if iid[][index] != expected[index]: return false
  true


proc queueState(thisInterface: pointer): ptr Vst3ParameterQueueState {.inline.} =
  cast[ptr Vst3ParameterQueueState](thisInterface)
proc queueQuery(thisInterface: pointer; iid: ptr Vst3Tuid;
                obj: ptr pointer): int32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_queue_query".} =
  let queue = queueState(thisInterface)
  if queue == nil or obj == nil or
      (not iidMatches(iid, Vst3FUnknownIidBytes) and
       not iidMatches(iid, Vst3ParamValueQueueIidBytes)):
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = thisInterface
  Vst3ResultOk
proc queueAddRef(thisInterface: pointer): uint32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_queue_add_ref".} =
  if thisInterface == nil: 0'u32 else: 1'u32
proc queueRelease(thisInterface: pointer): uint32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_queue_release".} =
  if thisInterface == nil: 0'u32 else: 1'u32
proc queueParameterId(thisInterface: pointer): Vst3ParamID {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_queue_parameter_id".} =
  let queue = queueState(thisInterface)
  if queue == nil: 0'u32 else: queue.id
proc queuePointCount(thisInterface: pointer): int32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_queue_point_count".} =
  let queue = queueState(thisInterface)
  if queue == nil: -1 else: int32(queue.points)
proc queueGetPoint(thisInterface: pointer; index: int32;
                   offset: ptr int32; value: ptr Vst3ParamValue): int32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_queue_get_point".} =
  let queue = queueState(thisInterface)
  if queue == nil or index < 0 or uint32(index) >= queue.points or
      offset == nil or value == nil:
    return Vst3InvalidArgument
  offset[] = queue.offsets[uint32(index)]
  value[] = queue.values[uint32(index)]
  Vst3ResultOk
proc queueAddPoint(thisInterface: pointer; offset: int32;
                   value: Vst3ParamValue; index: ptr int32): int32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_queue_add_point".} =
  let queue = queueState(thisInterface)
  if queue == nil or queue.owner == nil or not queue.output or offset < 0:
    return Vst3InvalidArgument
  let context = cast[ptr Vst3AudioProcessContext](queue.owner)
  if uint32(offset) >= context.currentFrames or
      value != value or value < 0.0 or value > 1.0 or
      (queue.points > 0'u32 and
       offset < queue.offsets[queue.points - 1'u32]):
    recordVst3ParameterOutputDrop(context.eventBridge)
    return Vst3InvalidArgument
  if queue.points >= Vst3AudioProcessMaxParameterPointsPerQueue or
      context.outputPoints >= Vst3AudioProcessMaxParameterPoints:
    recordVst3ParameterOutputDrop(context.eventBridge)
    return Vst3ResultFalse
  let position = queue.points
  queue.offsets[position] = offset
  queue.values[position] = value
  queue.points = position + 1'u32
  context.outputObservations[context.outputPoints] =
    Vst3ParameterObservation(id: queue.id, value: value, sampleOffset: offset)
  inc context.outputPoints
  if index != nil: index[] = int32(position)
  Vst3ResultOk

proc changesState(thisInterface: pointer): ptr Vst3ParameterChangesState {.inline.} =
  cast[ptr Vst3ParameterChangesState](thisInterface)
proc changesQuery(thisInterface: pointer; iid: ptr Vst3Tuid;
                  obj: ptr pointer): int32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_changes_query".} =
  let changes = changesState(thisInterface)
  if changes == nil or obj == nil or
      (not iidMatches(iid, Vst3FUnknownIidBytes) and
       not iidMatches(iid, Vst3ParameterChangesIidBytes)):
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = thisInterface
  Vst3ResultOk
proc changesAddRef(thisInterface: pointer): uint32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_changes_add_ref".} =
  if thisInterface == nil: 0'u32 else: 1'u32
proc changesRelease(thisInterface: pointer): uint32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_changes_release".} =
  if thisInterface == nil: 0'u32 else: 1'u32
proc changesCount(thisInterface: pointer): int32 {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_changes_count".} =
  let changes = changesState(thisInterface)
  if changes == nil: -1 else: int32(changes.queues)
proc changesGet(thisInterface: pointer; index: int32): ptr Vst3ParamValueQueue {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_changes_get".} =
  let changes = changesState(thisInterface)
  if changes == nil or index < 0 or uint32(index) >= changes.queues:
    return nil
  let queue = changes.queueValues[uint32(index)]
  if queue == nil: nil else: addr queue[].iface
proc changesAdd(thisInterface: pointer; id: ptr Vst3ParamID;
                index: ptr int32): ptr Vst3ParamValueQueue {.
    cdecl, gcsafe, raises: [], exportc: "pluginhost_vst3_changes_add".} =
  let changes = changesState(thisInterface)
  if changes == nil or id == nil or not changes.output or changes.owner == nil:
    return nil
  var queueIndex = 0'u32
  while queueIndex < changes.queues:
    let queue = changes.queueValues[queueIndex]
    if queue != nil and queue[].id == id[]:
      if index != nil: index[] = int32(queueIndex)
      return addr queue[].iface
    queueIndex += 1'u32
  let context = cast[ptr Vst3AudioProcessContext](changes.owner)
  if changes.queues >= Vst3AudioProcessMaxParameterQueues:
    recordVst3ParameterOutputDrop(context.eventBridge)
    return nil
  let queue = addr context.outputQueues[changes.queues]
  queue[].id = id[]
  queue[].points = 0'u32
  queue[].owner = changes.owner
  changes.queueValues[changes.queues] = queue
  if index != nil: index[] = int32(changes.queues)
  inc changes.queues
  addr queue[].iface


proc initQueue(queue: var Vst3ParameterQueueState; owner: pointer;
               output: bool) =
  queue = Vst3ParameterQueueState()
  queue.owner = owner
  queue.output = output
  queue.vtable = Vst3ParamValueQueueVtbl(
    queryInterface: queueQuery, addRef: queueAddRef, release: queueRelease,
    getParameterId: queueParameterId, getPointCount: queuePointCount,
    getPoint: queueGetPoint, addPoint: queueAddPoint)
  queue.iface.lpVtbl = addr queue.vtable

proc initChanges(changes: var Vst3ParameterChangesState; owner: pointer;
                 output: bool) =
  changes = Vst3ParameterChangesState()
  changes.owner = owner
  changes.output = output
  changes.vtable = Vst3ParameterChangesVtbl(
    queryInterface: changesQuery, addRef: changesAddRef,
    release: changesRelease, getParameterCount: changesCount,
    getParameterData: changesGet, addParameterData: changesAdd)
  changes.iface.lpVtbl = addr changes.vtable


proc resetInputChanges(context: ptr Vst3AudioProcessContext) {.
    inline, gcsafe, raises: [].} =
  let previousInputQueues = context.inputChanges.queues
  var queueIndex = 0'u32
  while queueIndex < previousInputQueues:
    context.inputQueues[queueIndex].points = 0'u32
    inc queueIndex
  context.inputChanges.queues = 0'u32
  context.inputPoints = 0'u32
  if context.transport != nil:
    var edit: Vst3ParameterEditRecord
    while dequeueVst3ParameterEdit(context.transport, edit):
      if edit.kind != v3pekPerform:
        continue
      if context.inputChanges.queues >= Vst3AudioProcessMaxParameterQueues:
        recordVst3ParameterInputDrop(context.eventBridge)
        continue
      queueIndex = 0'u32
      while queueIndex < context.inputChanges.queues and
          context.inputQueues[queueIndex].id != edit.id:
        inc queueIndex
      if queueIndex == context.inputChanges.queues:
        let queue = addr context.inputQueues[queueIndex]
        queue[].id = edit.id
        queue[].points = 0'u32
        context.inputChanges.queueValues[queueIndex] = queue
        inc context.inputChanges.queues
      let queue = addr context.inputQueues[queueIndex]
      if queue[].points < Vst3AudioProcessMaxParameterPointsPerQueue and
          context.inputPoints < Vst3AudioProcessMaxParameterPoints:
        queue[].offsets[queue[].points] = 0
        queue[].values[queue[].points] = edit.value
        inc queue[].points
        inc context.inputPoints
      else:
        recordVst3ParameterInputDrop(context.eventBridge)
  if context.eventBridge != nil:
    var pointIndex = 0'u32
    let totalPointCount = vst3InputParameterPointCount(context.eventBridge)
    let pointCount = min(totalPointCount,
      Vst3AudioProcessMaxParameterPoints - context.inputPoints)
    if totalPointCount > pointCount:
      recordVst3ParameterInputDrop(context.eventBridge,
        uint64(totalPointCount - pointCount))
    while pointIndex < pointCount:
      let point = vst3InputParameterPoint(context.eventBridge, pointIndex)
      var queueIndex = 0'u32
      while queueIndex < context.inputChanges.queues and
          context.inputQueues[queueIndex].id != point.id:
        inc queueIndex
      if queueIndex == context.inputChanges.queues:
        if context.inputChanges.queues >= Vst3AudioProcessMaxParameterQueues:
          recordVst3ParameterInputDrop(context.eventBridge)
          break
        let queue = addr context.inputQueues[queueIndex]
        queue[].id = point.id
        queue[].points = 0'u32
        context.inputChanges.queueValues[queueIndex] = queue
        inc context.inputChanges.queues
      let queue = addr context.inputQueues[queueIndex]
      if queue[].points < Vst3AudioProcessMaxParameterPointsPerQueue:
        queue[].offsets[queue[].points] = point.sampleOffset
        queue[].values[queue[].points] = point.value
        inc queue[].points
        inc context.inputPoints
      else:
        recordVst3ParameterInputDrop(context.eventBridge)
      inc pointIndex
  let previousOutputQueues = context.outputChanges.queues
  queueIndex = 0'u32
  while queueIndex < previousOutputQueues:
    context.outputQueues[queueIndex].points = 0'u32
    inc queueIndex
  context.outputChanges.queues = 0'u32
  context.outputPoints = 0'u32
proc discardOutputCycle(context: ptr Vst3AudioProcessContext) {.
    inline, gcsafe, raises: [].} =
  let previousOutputQueues = context.outputChanges.queues
  var queueIndex = 0'u32
  while queueIndex < previousOutputQueues:
    context.outputQueues[queueIndex].points = 0'u32
    inc queueIndex
  context.outputChanges.queues = 0'u32
  context.outputPoints = 0'u32

proc bindBusPointers(context: ptr Vst3AudioProcessContext;
                     engine: ptr RtEngine): cint {.
    inline, gcsafe, raises: [].} =
  if engine.inputCount != context.inputChannelCount or
      engine.outputCount != context.outputChannelCount:
    return RtProcessInvalidLayout
  var index = 0'u32
  while index < context.inputChannelCount:
    let buffer = engine.inputBuffers[int(index)]
    if buffer == nil: return RtProcessMissingBuffer
    context.inputPointers[int(index)] = buffer
    inc index
  index = 0'u32
  while index < context.outputChannelCount:
    let buffer = engine.outputBuffers[int(index)]
    if buffer == nil: return RtProcessMissingBuffer
    context.outputPointers[int(index)] = buffer
    inc index
  index = 0'u32
  while index < context.inputBusCount:
    let bus = addr context.inputs[int(index)]
    let channels = context.inputChannelCounts[int(index)]
    bus[].channelBuffers32 = if channels == 0'u32: nil else:
      cast[ptr ptr cfloat](addr context.inputPointers[int(context.inputFirst[int(index)])])
    inc index
  index = 0'u32
  while index < context.outputBusCount:
    let bus = addr context.outputs[int(index)]
    let channels = context.outputChannelCounts[int(index)]
    bus[].channelBuffers32 = if channels == 0'u32: nil else:
      cast[ptr ptr cfloat](addr context.outputPointers[int(context.outputFirst[int(index)])])
    inc index
  RtProcessOk

proc processVst3Audio*(argument: pointer; engine: ptr RtEngine;
                       nframes: uint32): cint {.
    exportc: "pluginhost_vst3_process_audio", cdecl, gcsafe, raises: [].} =
  if engine == nil:
    return RtProcessInvalidContext
  if argument == nil:
    let clearFrames = if nframes > engine.maxFrames: engine.maxFrames else: nframes
    discard zeroRtOutputs(engine, clearFrames)
    return RtProcessInvalidContext
  let context = cast[ptr Vst3AudioProcessContext](argument)
  if context.processor == nil or context.processor.lpVtbl == nil or
      context.processor.lpVtbl.process == nil:
    let clearFrames = if nframes > engine.maxFrames: engine.maxFrames else: nframes
    discard zeroRtOutputs(engine, clearFrames)
    return RtProcessInvalidContext
  discard context.callsInFlight.fetchAddAcquire(1'u32)
  var status = RtProcessOk
  if nframes == 0'u32 or nframes > context.maxFrames or
      nframes > engine.maxFrames or nframes > uint32(high(int32)):
    status = RtProcessInvalidFrameCount
    let clearFrames = if nframes > engine.maxFrames: engine.maxFrames else: nframes
    discard zeroRtOutputs(engine, clearFrames)
  else:
    status = zeroRtOutputs(engine, nframes)
    var busIndex = 0'u32
    while busIndex < context.outputBusCount:
      context.outputs[int(busIndex)].silenceFlags = 0'u64
      inc busIndex
    if status == RtProcessOk:
      status = bindBusPointers(context, engine)
    if status == RtProcessOk:
      if context.eventBridge == nil or
          not beginVst3EventCycle(context.eventBridge, engine, nframes,
            context.role):
        status = RtProcessEndpointFailure
      elif context.samplePosition > high(int64) - int64(nframes):
        endVst3EventCycle(context.eventBridge)
        status = RtProcessEndpointFailure
      else:
        context.currentFrames = nframes
        context.processContext.projectTimeSamples = context.samplePosition
        context.processContext.continousTimeSamples = context.samplePosition
        context.processContext.systemTime = 0'i64
        context.processContext.sampleRate = context.sampleRate
        context.processContext.state =
          Vst3ProcessContextStateContinuousTimeValid
        resetInputChanges(context)
        context.processData.numSamples = int32(nframes)
        let processProc = context.processor.lpVtbl.process
        let nativeResult = processProc(
          cast[pointer](context.processor), addr context.processData)
        if nativeResult != Vst3ResultOk:
          discardOutputCycle(context)
          clearVst3MidiOutputsRaw(context.eventBridge)
        endVst3EventCycle(context.eventBridge)
        context.lastResult = nativeResult
        inc context.processCalls
        if nativeResult != Vst3ResultOk:
          status = RtProcessEndpointFailure
        else:
          if context.transport != nil:
            if not hasVst3ParameterObservationCapacity(context.transport,
                context.outputPoints):
              recordVst3ParameterOutputDrop(context.eventBridge,
                uint64(context.outputPoints))
              status = RtProcessEndpointFailure
              discardOutputCycle(context)
            else:
              var observationIndex = 0'u32
              while observationIndex < context.outputPoints:
                if not publishVst3ParameterObservation(context.transport,
                    context.outputObservations[observationIndex]):
                  recordVst3ParameterOutputDrop(context.eventBridge)
                  status = RtProcessEndpointFailure
                  discardOutputCycle(context)
                  break
                inc observationIndex
          elif context.outputPoints > 0'u32:
            status = RtProcessEndpointFailure
            discardOutputCycle(context)
          if status == RtProcessOk:
            context.samplePosition += int64(nframes)
            busIndex = 0'u32
            while busIndex < context.outputBusCount:
              let bus = addr context.outputs[int(busIndex)]
              var channel = 0'u32
              while channel < uint32(bus[].numChannels) and channel < 64'u32:
                if (bus[].silenceFlags and (1'u64 shl channel)) != 0:
                  var frame = 0'u32
                  let output = context.outputPointers[int(
                    context.outputFirst[int(busIndex)] + channel)]
                  while frame < nframes:
                    output[int(frame)] = 0.0
                    inc frame
                inc channel
              inc busIndex
  if status != RtProcessOk:
    let clearFrames = if nframes > engine.maxFrames: engine.maxFrames else: nframes
    discard zeroRtOutputs(engine, clearFrames)
    if context.eventBridge != nil:
      clearVst3MidiOutputsForEngine(context.eventBridge, engine)
    context.faultLatched.storeRelease(1'u32)
  discard context.callsInFlight.fetchSubRelease(1'u32)
  status
{.pop.}
proc releaseRequirementsObject(candidate: pointer) {.inline, raises: [].} =
  if candidate == nil: return
  let requirements = cast[ptr Vst3ProcessContextRequirements](candidate)
  if requirements.lpVtbl != nil and requirements.lpVtbl.release != nil:
    discard requirements.lpVtbl.release(candidate)

proc newVst3AudioProcess*(processor: ptr Vst3AudioProcessor;
                          component: ptr Vst3Component;
                          plan: PortPlan;
                          transport: ptr Vst3ParameterTransport;
                          maxFrames: uint32; sampleRate: uint32;
                          role: ptr AudioRoleGuard;
                          path, pluginId: string;
                          initialSamplePosition: int64 = 0;
                          controller: ptr Vst3EditController = nil):
                          Result[Vst3AudioProcess] =
  if processor == nil or processor.lpVtbl == nil or
      processor.lpVtbl.canProcessSampleSize == nil or
      processor.lpVtbl.getLatencySamples == nil or
      processor.lpVtbl.setupProcessing == nil or
      processor.lpVtbl.process == nil:
    return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Factory,
      "VST3 processor has an incomplete processing ABI", path, pluginId, ""))
  if maxFrames == 0'u32 or maxFrames > Vst3AudioProcessMaxFrames or
      sampleRate == 0'u32:
    return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Factory,
      "JACK processing configuration is outside the VST3 bounds", path,
      pluginId, "frames=" & $maxFrames & "; rate=" & $sampleRate))
  if initialSamplePosition < 0:
    return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Descriptor,
      "VST3 initial sample position is negative", path, pluginId, ""))
  if processor.lpVtbl.canProcessSampleSize(cast[pointer](processor),
      Vst3SymbolicSample32) != Vst3ResultOk:
    return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Factory,
      "VST3 processor does not support float32 processing", path, pluginId, ""))
  var setup = Vst3ProcessSetup(processMode: Vst3ProcessModeRealtime,
    symbolicSampleSize: Vst3SymbolicSample32,
    maxSamplesPerBlock: int32(maxFrames), sampleRate: float64(sampleRate))
  let setupResult = processor.lpVtbl.setupProcessing(cast[pointer](processor),
    addr setup)
  if setupResult != Vst3ResultOk:
    return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Factory,
      "VST3 processor rejected realtime float32 setup", path, pluginId,
      "result=" & $setupResult))
  if processor.lpVtbl.queryInterface != nil:
    let requirementsIid = parseVst3Uid(Vst3AudioProcessorContextRequirementsIid)
    if not requirementsIid.isOk:
      return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Descriptor,
        "VST3 process-context requirements IID is malformed", path, pluginId, ""))
    var requirementsObject: pointer = nil
    let queryResult = processor.lpVtbl.queryInterface(cast[pointer](processor),
      addr requirementsIid.value, addr requirementsObject)
    if queryResult == Vst3NoInterface or queryResult == Vst3ResultFalse or
        queryResult == Vst3NotImplemented:
      releaseRequirementsObject(requirementsObject)
    elif queryResult != Vst3ResultOk or requirementsObject == nil:
      releaseRequirementsObject(requirementsObject)
      return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Factory,
        "VST3 process-context requirements query failed", path, pluginId,
        "result=" & $queryResult))
    else:
      let requirements = cast[ptr Vst3ProcessContextRequirements](
        requirementsObject)
      if requirements.lpVtbl == nil or requirements.lpVtbl.release == nil:
        return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Factory,
          "VST3 process-context requirements ABI is incomplete", path,
          pluginId, ""))
      if requirements.lpVtbl.queryInterface == nil or
          requirements.lpVtbl.addRef == nil or
          requirements.lpVtbl.getProcessContextRequirements == nil:
        discard requirements.lpVtbl.release(requirementsObject)
        return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Factory,
          "VST3 process-context requirements ABI is incomplete", path,
          pluginId, ""))
      # Requested fields are advisory. Publish only the fields we actually
      # provide; ProcessContext.state remains the validity contract.
      discard requirements.lpVtbl.getProcessContextRequirements(
        requirementsObject)
      discard requirements.lpVtbl.release(requirementsObject)
  var context = cast[ptr Vst3AudioProcessContext](
    allocShared0(sizeof(Vst3AudioProcessContext)))
  if context == nil:
    return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Factory,
      "could not allocate VST3 process storage", path, pluginId, ""))
  context.processor = processor
  context.role = role
  context.maxFrames = maxFrames
  context.sampleRate = float64(sampleRate)
  context.samplePosition = initialSamplePosition
  context.transport = transport
  var bridgeResult = newVst3EventBridge(controller, plan, role, path, pluginId)
  if not bridgeResult.isOk:
    deallocShared(context)
    return failure[Vst3AudioProcess](move(bridgeResult.error))
  context.eventBridge = bridgeResult.value
  context.processData = Vst3ProcessData(
    processMode: Vst3ProcessModeRealtime,
    symbolicSampleSize: Vst3SymbolicSample32,
    numSamples: 0,
    inputs: addr context.inputs[0],
    outputs: addr context.outputs[0],
    inputParameterChanges: addr context.inputChanges.iface,
    outputParameterChanges: addr context.outputChanges.iface,
    inputEvents: vst3EventInputInterface(context.eventBridge),
    outputEvents: vst3EventOutputInterface(context.eventBridge),
    processContext: addr context.processContext)
  initChanges(context.inputChanges, addr context[], false)
  initChanges(context.outputChanges, addr context[], true)
  var queueIndex = 0'u32
  while queueIndex < Vst3AudioProcessMaxParameterQueues:
    initQueue(context.inputQueues[queueIndex], addr context[], false)
    initQueue(context.outputQueues[queueIndex], addr context[], true)
    inc queueIndex
  var inputCount = 0'u32
  var outputCount = 0'u32
  for group in plan.audioGroups:
    if group.channelCount > Vst3MaxBusChannels:
      closeVst3EventBridge(context.eventBridge)
      deallocShared(context)
      return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Descriptor,
        "VST3 bus channel count exceeds process storage", path, pluginId, ""))
    if group.direction == pdInput:
      if group.index >= Vst3MaxBusCount or group.flattenedPast > Vst3MaxBusChannels:
        closeVst3EventBridge(context.eventBridge)
        deallocShared(context)
        return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Descriptor,
          "VST3 input bus mapping exceeds process storage", path, pluginId, ""))
      let bus = addr context.inputs[int(group.index)]
      bus[].numChannels = int32(group.channelCount)
      bus[].silenceFlags = if group.channelCount == 0: high(uint64) else: 0'u64
      context.inputFirst[int(group.index)] = group.flattenedFirst
      context.inputChannelCounts[int(group.index)] = group.channelCount
      inputCount = max(inputCount, group.index + 1'u32)
      context.inputChannelCount = max(context.inputChannelCount, group.flattenedPast)
    else:
      if group.index >= Vst3MaxBusCount or group.flattenedPast > Vst3MaxBusChannels:
        closeVst3EventBridge(context.eventBridge)
        deallocShared(context)
        return failure[Vst3AudioProcess](vst3ProcessError(hekVst3Descriptor,
          "VST3 output bus mapping exceeds process storage", path, pluginId, ""))
      let bus = addr context.outputs[int(group.index)]
      bus[].numChannels = int32(group.channelCount)
      bus[].silenceFlags = if group.channelCount == 0: high(uint64) else: 0'u64
      context.outputFirst[int(group.index)] = group.flattenedFirst
      context.outputChannelCounts[int(group.index)] = group.channelCount
      outputCount = max(outputCount, group.index + 1'u32)
      context.outputChannelCount = max(context.outputChannelCount, group.flattenedPast)
  context.inputBusCount = inputCount
  context.outputBusCount = outputCount
  context.processData.numInputs = int32(inputCount)
  context.processData.numOutputs = int32(outputCount)
  context.callsInFlight.storeRelaxed(0'u32)
  context.faultLatched.storeRelaxed(0'u32)
  success(Vst3AudioProcess(context: context))

proc endpoint*(process: Vst3AudioProcess): RtProcessEndpoint {.inline.} =
  if process.context == nil: RtProcessEndpoint()
  else: RtProcessEndpoint(callback: processVst3Audio,
    context: cast[pointer](process.context), maxFrames: process.context.maxFrames)

proc processContext*(process: Vst3AudioProcess): ptr Vst3AudioProcessContext {.inline.} =
  process.context

proc processCalls*(process: Vst3AudioProcess): uint64 {.inline.} =
  if process.context == nil: 0'u64 else: process.context.processCalls
proc setVst3SamplePosition*(process: var Vst3AudioProcess;
                            samplePosition: int64): bool =
  if process.context == nil or samplePosition < 0 or
      process.context.callsInFlight.loadAcquire() != 0'u32:
    return false
  process.context.samplePosition = samplePosition
  true

proc samplePosition*(process: Vst3AudioProcess): int64 {.inline.} =
  if process.context == nil: 0'i64 else: process.context.samplePosition

proc faultLatched*(process: Vst3AudioProcess): bool {.inline.} =
  process.context != nil and process.context.faultLatched.loadAcquire() != 0'u32

proc waitVst3ProcessQuiescence*(process: Vst3AudioProcess): bool =
  if process.context == nil: return true
  for ignored in 0 ..< 1_000:
    discard ignored
    if process.context.callsInFlight.loadAcquire() == 0'u32: return true
    discard sleep(1)
  process.context.callsInFlight.loadAcquire() == 0'u32

proc close*(process: var Vst3AudioProcess): Result[Unit] =
  if process.context == nil: return success()
  if not process.waitVst3ProcessQuiescence():
    return failure[Unit](vst3ProcessError(hekVst3Factory,
      "VST3 process callbacks remained active during teardown", "", "", ""))
  closeVst3EventBridge(process.context.eventBridge)
  deallocShared(process.context)
  process.context = nil
  success()

proc takeVst3ProcessFault*(process: var Vst3AudioProcess): bool =
  if process.context == nil: false
  else: process.context.faultLatched.exchangeAcquire(0'u32) != 0'u32

proc drainVst3ParameterObservations*(process: Vst3AudioProcess;
                                     controller: ptr Vst3EditController): uint32 =
  if process.context == nil or controller == nil or controller.lpVtbl == nil or
      controller.lpVtbl.setParamNormalized == nil:
    return 0'u32
  var observation: Vst3ParameterObservation
  while dequeueVst3ParameterObservation(process.context.transport, observation):
    discard controller.lpVtbl.setParamNormalized(cast[pointer](controller),
      observation.id, observation.value)
    inc result

proc drainVst3ParameterGestures*(process: Vst3AudioProcess;
                                 destination: ptr UncheckedArray[
                                   Vst3ParameterEditRecord];
                                 capacity: uint32): uint32 =
  if process.context == nil or destination == nil or capacity == 0'u32:
    return 0'u32
  var edit: Vst3ParameterEditRecord
  while result < capacity and
      dequeueVst3ParameterGesture(process.context.transport, edit):
    destination[result] = edit
    inc result

proc eventMetrics*(process: Vst3AudioProcess): Vst3EventMetrics {.inline.} =
  if process.context == nil:
    return Vst3EventMetrics()
  result = vst3EventMetrics(process.context.eventBridge)
  if process.context.transport != nil:
    result.parameterInputDrops +=
      takeDroppedVst3ParameterEdits(process.context.transport) +
      takeDroppedVst3ParameterGestures(process.context.transport)
proc activationFailure(primary: HostError;
                       rollback: Result[Unit]): Result[Unit] =
  var error = primary
  if not rollback.isOk:
    error.context.add("; rollback=" & rollback.error.message)
    if rollback.error.context.len > 0:
      error.context.add(" (" & rollback.error.context & ")")
  failure[Unit](move(error))

proc deactivateVst3Buses*(component: ptr Vst3Component;
                          ledger: var Vst3BusActivationLedger): Result[Unit]
proc activateVst3Buses*(component: ptr Vst3Component;
                        ledger: var Vst3BusActivationLedger): Result[Unit] =
  ledger.count = 0'u32
  if component == nil or component.lpVtbl == nil or
      component.lpVtbl.getBusCount == nil or component.lpVtbl.activateBus == nil:
    return failure[Unit](vst3ProcessError(hekVst3Factory,
      "VST3 component has no bus activation ABI", "", "", ""))
  for mediaType in [Vst3MediaAudio, Vst3MediaEvent]:
    for direction in [Vst3DirectionInput, Vst3DirectionOutput]:
      let count = component.lpVtbl.getBusCount(cast[pointer](component),
        mediaType, direction)
      if count < 0 or count > int32(Vst3MaxBusCount):
        let rollback = deactivateVst3Buses(component, ledger)
        let primary = vst3ProcessError(hekVst3Descriptor,
          "VST3 bus count is invalid during activation", "", "", "")
        return activationFailure(primary, rollback)
      for index in 0 ..< count:
        let code = component.lpVtbl.activateBus(cast[pointer](component),
          mediaType, direction, index, 1'u8)
        if code != Vst3ResultOk:
          let rollback = deactivateVst3Buses(component, ledger)
          let primary = vst3ProcessError(hekVst3Factory,
            "VST3 component refused required bus activation", "", "",
            "media=" & $mediaType & "; direction=" & $direction &
            "; index=" & $index & "; result=" & $code)
          return activationFailure(primary, rollback)
        if ledger.count >= uint32(ledger.entries.len):
          let rollback = deactivateVst3Buses(component, ledger)
          let primary = vst3ProcessError(hekVst3Descriptor,
            "VST3 bus activation ledger is full", "", "", "")
          return activationFailure(primary, rollback)
        ledger.entries[int(ledger.count)] = Vst3ActivatedBus(
          mediaType: mediaType, direction: direction, index: index)
        inc ledger.count
  success()
proc deactivateVst3Buses*(component: ptr Vst3Component;
                          ledger: var Vst3BusActivationLedger): Result[Unit] =
  if ledger.count == 0'u32:
    return success()
  if component == nil or component.lpVtbl == nil or
      component.lpVtbl.activateBus == nil:
    return failure[Unit](vst3ProcessError(hekVst3Factory,
      "VST3 component has no bus deactivation ABI", "", "", ""))
  while ledger.count > 0'u32:
    let position = ledger.count - 1'u32
    let bus = ledger.entries[int(position)]
    let code = component.lpVtbl.activateBus(cast[pointer](component),
      bus.mediaType, bus.direction, bus.index, 0'u8)
    if code != Vst3ResultOk and code != Vst3ResultFalse:
      return failure[Unit](vst3ProcessError(hekVst3Factory,
        "VST3 component refused bus deactivation", "", "",
        "media=" & $bus.mediaType & "; direction=" & $bus.direction &
        "; index=" & $bus.index & "; result=" & $code))
    ledger.count = position
  success()

proc setVst3Active*(component: ptr Vst3Component; active: bool): Result[Unit] =
  if component == nil or component.lpVtbl == nil or
      component.lpVtbl.setActive == nil:
    return failure[Unit](vst3ProcessError(hekVst3Factory,
      "VST3 component has no active-state ABI", "", "", ""))
  let activeValue: uint8 = if active: 1'u8 else: 0'u8
  let code = component.lpVtbl.setActive(cast[pointer](component), activeValue)
  if code != Vst3ResultOk:
    return failure[Unit](vst3ProcessError(hekVst3Factory,
      "VST3 component active-state transition failed", "", "",
      "result=" & $code))
  success()

proc setVst3Processing*(processor: ptr Vst3AudioProcessor;
                        processing: bool): Result[Unit] =
  if processor == nil or processor.lpVtbl == nil or
      processor.lpVtbl.setProcessing == nil:
    return failure[Unit](vst3ProcessError(hekVst3Factory,
      "VST3 processor has no processing-state ABI", "", "", ""))
  let processingValue: uint8 = if processing: 1'u8 else: 0'u8
  let code = processor.lpVtbl.setProcessing(cast[pointer](processor), processingValue)
  # Steinberg's base AudioEffect leaves this notification unimplemented while
  # derived processors may still implement process(). Both transitions remain
  # paired; explicit rejection and other errors are still fatal.
  if code != Vst3ResultOk and code != Vst3NotImplemented:
    return failure[Unit](vst3ProcessError(hekVst3Factory,
      "VST3 processor processing-state transition failed", "", "",
      "result=" & $code))
  success()
