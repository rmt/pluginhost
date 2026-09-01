## Fixed-layout CLAP float32 audio endpoint for the internal Increment 5 slice.
##
## The control plane constructs and releases this owner. JACK borrows its stable
## context only while the backend is active. The process callback contains no
## managed values, allocation, cleanup, or diagnostic I/O.

import std/typetraits

import ../domain/[errors, port_plan, result]
import ../rt/[atomic_pod, engine, role_guard]
import ./[event_bridge, ffi]

const
  ClapAudioProcessMaxGroupsPerDirection* = 1_024
  ClapAudioProcessMaxChannelsPerDirection* = 4_096
  ClapAudioProcessMaxFrames* = uint32(high(int32))

type
  ClapAudioProcessContext = object
    plugin: ptr ClapPlugin
    processProc: ClapPluginProcessProc
    maxFrames: uint32
    inputGroupCount: uint32
    outputGroupCount: uint32
    inputChannelCount: uint32
    outputChannelCount: uint32
    inputBuffers: array[ClapAudioProcessMaxGroupsPerDirection, ClapAudioBuffer]
    outputBuffers: array[ClapAudioProcessMaxGroupsPerDirection, ClapAudioBuffer]
    inputPointers: array[ClapAudioProcessMaxChannelsPerDirection,
      ptr UncheckedArray[cfloat]]
    outputPointers: array[ClapAudioProcessMaxChannelsPerDirection,
      ptr UncheckedArray[cfloat]]
    events: ClapEventBridge
    process: ClapProcess
    steadyTime: int64
    processCalls: uint64
    lastStatus: int32
    callsInFlight: RtAtomicU32

  ClapAudioProcess* = object
    context: ptr ClapAudioProcessContext

static:
  doAssert supportsCopyMem(ClapAudioProcessContext)
  doAssert supportsCopyMem(ClapAudioProcess)

proc `=destroy`*(process: var ClapAudioProcess) =
  doAssert process.context == nil,
    "an active CLAP audio process owner must be explicitly closed"

proc `=copy`*(destination: var ClapAudioProcess;
              source: ClapAudioProcess) {.error:
  "ClapAudioProcess owns shared storage and cannot be copied; use move".}
proc `=dup`*(source: ClapAudioProcess): ClapAudioProcess {.error:
  "ClapAudioProcess owns shared storage and cannot be duplicated; use move".}

proc `=sink`*(destination: var ClapAudioProcess;
              source: ClapAudioProcess) =
  doAssert destination.context == nil,
    "a CLAP audio process owner must be closed before move assignment"
  destination.context = source.context

proc audioProcessError(kind: HostErrorKind; message, path, pluginId,
                       detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsClap, kind, message, context)

{.push checks: off, stackTrace: off, lineTrace: off.}

proc bindGroup(context: ptr ClapAudioProcessContext; group: AudioGroup;
               direction: PortDirection; groupIndex: uint32;
               expectedChannels: var uint32): bool {.inline, gcsafe, raises: [].} =
  if context == nil or group.direction != direction or
      group.index != groupIndex or group.channelCount == 0'u32 or
      group.flattenedFirst != expectedChannels or
      group.flattenedPast < group.flattenedFirst or
      group.flattenedPast - group.flattenedFirst != group.channelCount or
      group.flattenedPast > ClapAudioProcessMaxChannelsPerDirection:
    return false

  let descriptor = if direction == pdInput:
      addr context.inputBuffers[int(groupIndex)]
    else:
      addr context.outputBuffers[int(groupIndex)]
  let pointers = if direction == pdInput:
      addr context.inputPointers[int(group.flattenedFirst)]
    else:
      addr context.outputPointers[int(group.flattenedFirst)]
  descriptor[] = ClapAudioBuffer(
    data32: cast[ptr ptr cfloat](pointers),
    data64: nil,
    channelCount: group.channelCount,
    latency: 0'u32,
    constantMask: 0'u64,
  )
  expectedChannels = group.flattenedPast
  true

proc processClapAudio*(argument: pointer; engine: ptr RtEngine;
                       nframes: uint32): cint {.
    exportc: "pluginhost_clap_process_audio", cdecl, gcsafe, raises: [].} =
  if argument == nil or engine == nil:
    return RtProcessInvalidContext
  let context = cast[ptr ClapAudioProcessContext](argument)
  if context.plugin == nil or context.processProc == nil:
    return RtProcessInvalidContext
  discard context.callsInFlight.fetchAddAcquire(1'u32)

  var status = RtProcessOk
  if nframes == 0'u32 or nframes > context.maxFrames or
      nframes > engine.maxFrames:
    status = RtProcessInvalidFrameCount
  elif engine.inputCount != context.inputChannelCount or
      engine.outputCount != context.outputChannelCount:
    status = RtProcessInvalidLayout
  else:
    var inputIndex = 0'u32
    while inputIndex < context.inputChannelCount:
      let buffer = engine.inputBuffers[int(inputIndex)]
      if buffer == nil:
        status = RtProcessMissingBuffer
      context.inputPointers[int(inputIndex)] = buffer
      inputIndex += 1'u32

    var outputIndex = 0'u32
    while outputIndex < context.outputChannelCount:
      let buffer = engine.outputBuffers[int(outputIndex)]
      if buffer == nil:
        status = RtProcessMissingBuffer
      context.outputPointers[int(outputIndex)] = buffer
      outputIndex += 1'u32

    if status == RtProcessOk:
      status = zeroRtOutputs(engine, nframes)

    if status == RtProcessOk and
        not beginEventCycle(addr context.events, engine, nframes):
      status = RtProcessEndpointFailure

    if status == RtProcessOk:
      if context.steadyTime < 0 or
          context.steadyTime > high(int64) - int64(nframes):
        status = RtProcessEndpointFailure
      else:
        context.process.steadyTime = context.steadyTime
        context.process.framesCount = nframes
        let rawStatus = context.processProc(
          context.plugin, addr context.process)
        endEventCycle(addr context.events)
        context.lastStatus = rawStatus
        context.steadyTime += int64(nframes)
        context.processCalls += 1'u64
        case rawStatus
        of ClapProcessContinue, ClapProcessContinueIfNotQuiet,
           ClapProcessTail, ClapProcessSleep:
          status = RtProcessOk
        of ClapProcessError:
          discard zeroRtOutputs(engine, nframes)
          status = RtProcessEndpointFailure
        else:
          discard zeroRtOutputs(engine, nframes)
          status = RtProcessEndpointFailure

  if isEventCycleActive(addr context.events):
    endEventCycle(addr context.events)
  if status != RtProcessOk:
    discard zeroRtOutputs(engine, nframes)
  discard context.callsInFlight.fetchSubRelease(1'u32)
  status
{.pop.}

proc newClapAudioProcess*(plugin: ptr ClapPlugin; plan: PortPlan;
                          maxFrames: uint32; role: ptr AudioRoleGuard;
                          path, pluginId: string): Result[ClapAudioProcess] =
  if plugin == nil or plugin.process == nil:
    return failure[ClapAudioProcess](audioProcessError(
      hekClapProcess,
      "CLAP audio processing requires a live process callback",
      path, pluginId, ""))
  if maxFrames == 0'u32 or maxFrames > ClapAudioProcessMaxFrames:
    return failure[ClapAudioProcess](audioProcessError(
      hekClapActivation,
      "JACK buffer size is outside the CLAP activation range",
      path, pluginId, "max-frames=" & $maxFrames))

  var context = cast[ptr ClapAudioProcessContext](
    allocShared0(sizeof(ClapAudioProcessContext)))
  if context == nil:
    return failure[ClapAudioProcess](audioProcessError(
      hekClapProcess,
      "could not allocate the CLAP audio process storage",
      path, pluginId, ""))

  context.plugin = plugin
  context.processProc = plugin.process
  context.maxFrames = maxFrames
  var initializedEvents = initClapEventBridge(
    addr context.events, plan, role, path, pluginId)
  if not initializedEvents.isOk:
    deallocShared(context)
    return failure[ClapAudioProcess](move(initializedEvents.error))
  context.process = ClapProcess(
    steadyTime: 0,
    framesCount: 0,
    transport: nil,
    audioInputs: nil,
    audioOutputs: nil,
    audioInputsCount: 0,
    audioOutputsCount: 0,
    inEvents: addr context.events.inputEvents,
    outEvents: addr context.events.outputEvents,
  )
  context.callsInFlight.storeRelaxed(0'u32)

  var inputChannels = 0'u32
  var outputChannels = 0'u32
  var inputGroups = 0'u32
  var outputGroups = 0'u32
  for group in plan.audioGroups:
    let groupIndex = if group.direction == pdInput: inputGroups else: outputGroups
    if group.direction == pdInput:
      if inputGroups >= ClapAudioProcessMaxGroupsPerDirection:
        deallocShared(context)
        return failure[ClapAudioProcess](audioProcessError(
          hekClapProcess,
          "CLAP input audio group count exceeds the fixed process capacity",
          path, pluginId, "groups=" & $(inputGroups + 1'u32)))
      if not bindGroup(context, group, pdInput, groupIndex, inputChannels):
        deallocShared(context)
        return failure[ClapAudioProcess](audioProcessError(
          hekClapProcess,
          "CLAP input audio groups are not contiguous or exceed channel capacity",
          path, pluginId, "group=" & $groupIndex))
      inc inputGroups
    else:
      if outputGroups >= ClapAudioProcessMaxGroupsPerDirection:
        deallocShared(context)
        return failure[ClapAudioProcess](audioProcessError(
          hekClapProcess,
          "CLAP output audio group count exceeds the fixed process capacity",
          path, pluginId, "groups=" & $(outputGroups + 1'u32)))
      if not bindGroup(context, group, pdOutput, groupIndex, outputChannels):
        deallocShared(context)
        return failure[ClapAudioProcess](audioProcessError(
          hekClapProcess,
          "CLAP output audio groups are not contiguous or exceed channel capacity",
          path, pluginId, "group=" & $groupIndex))
      inc outputGroups

  if inputChannels + outputChannels != uint32(plan.audioChannelCount):
    deallocShared(context)
    return failure[ClapAudioProcess](audioProcessError(
      hekClapProcess,
      "CLAP audio channel counts are inconsistent",
      path, pluginId,
      "inputs=" & $inputChannels & "; outputs=" & $outputChannels))
  context.inputGroupCount = inputGroups
  context.outputGroupCount = outputGroups
  context.inputChannelCount = inputChannels
  context.outputChannelCount = outputChannels
  context.process.audioInputs = if inputGroups == 0'u32: nil else:
    addr context.inputBuffers[0]
  context.process.audioOutputs = if outputGroups == 0'u32: nil else:
    addr context.outputBuffers[0]
  context.process.audioInputsCount = inputGroups
  context.process.audioOutputsCount = outputGroups

  success(ClapAudioProcess(context: context))

proc endpoint*(process: ClapAudioProcess): RtProcessEndpoint {.inline.} =
  if process.context == nil:
    return RtProcessEndpoint()
  RtProcessEndpoint(
    callback: processClapAudio,
    context: cast[pointer](process.context),
    maxFrames: process.context.maxFrames,
  )

proc setMaxFrames*(process: var ClapAudioProcess; maxFrames: uint32): bool =
  if process.context == nil or maxFrames == 0'u32 or
      maxFrames > ClapAudioProcessMaxFrames or
      process.context.callsInFlight.loadAcquire() != 0'u32:
    return false
  process.context.maxFrames = maxFrames
  true

proc maxFrames*(process: ClapAudioProcess): uint32 {.inline.} =
  if process.context == nil: 0'u32 else: process.context.maxFrames

proc steadyTime*(process: ClapAudioProcess): int64 {.inline.} =
  if process.context == nil: 0'i64 else: process.context.steadyTime

proc processCalls*(process: ClapAudioProcess): uint64 {.inline.} =
  if process.context == nil: 0'u64 else: process.context.processCalls

proc lastStatus*(process: ClapAudioProcess): int32 {.inline.} =
  if process.context == nil: ClapProcessError else: process.context.lastStatus

proc takeEventMetrics*(process: ClapAudioProcess): ClapEventMetrics =
  if process.context == nil: ClapEventMetrics() else:
    event_bridge.takeEventMetrics(addr process.context.events)

proc close*(process: var ClapAudioProcess): Result[Unit] =
  if process.context == nil:
    return success()
  if process.context.callsInFlight.loadAcquire() != 0'u32:
    return failure[Unit](hostError(
      hsClap, hekClapProcess,
      "cannot release CLAP audio process storage while processing is active",
      "calls-in-flight=" &
        $process.context.callsInFlight.loadAcquire(),
    ))
  deallocShared(process.context)
  process.context = nil
  success()
