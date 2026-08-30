## Stable storage and allocation-free JACK callback trampolines.
## Callbacks record only bounded POD/atomic state. Cleanup and diagnostics belong
## to the control plane after JACK has been quiesced.

import std/concurrency/atomics
import std/typetraits

import ../rt/[engine, role_guard]
import ./[api, ffi, ports]

const ShutdownReasonBytes* = 256

type
  JackCallbackFunctions = object
    portGetBuffer: JackPortGetBufferProc
    portGetLatencyRange: JackPortGetLatencyRangeProc
    portSetLatencyRange: JackPortSetLatencyRangeProc

  JackNotifications = object
    shutdownCount: Atomic[uint64]
    shutdownRecordState: Atomic[uint32]
    shutdownStatus: Atomic[int32]
    shutdownReasonLength: uint32
    shutdownReason: array[ShutdownReasonBytes, char]
    xrunCount: Atomic[uint64]
    freewheelCount: Atomic[uint64]
    freewheelState: Atomic[int32]
    bufferSizeCount: Atomic[uint64]
    bufferSize: Atomic[uint32]
    sampleRateCount: Atomic[uint64]
    sampleRate: Atomic[uint32]
    latencyCount: Atomic[uint64]
    processCycles: Atomic[uint64]
    processFrames: Atomic[uint64]
    processErrors: Atomic[uint64]
    lateProcessCalls: Atomic[uint64]

  JackCallbackContext* = object
    functions: JackCallbackFunctions
    portMap: RtPortMap
    engine: RtEngine
    role: AudioRoleGuard
    processEnabled: Atomic[uint32]
    callbacksInFlight: Atomic[uint32]
    processInFlight: Atomic[uint32]
    latencyFrames: Atomic[uint32]
    notifications: JackNotifications

  JackNotificationStateSnapshot* = object
    shutdownCount*: uint64
    shutdownStatus*: int32
    shutdownReasonLength*: uint32
    shutdownReason*: array[ShutdownReasonBytes, char]
    xrunCount*: uint64
    freewheelCount*: uint64
    freewheel*: bool
    bufferSizeCount*: uint64
    bufferSize*: uint32
    sampleRateCount*: uint64
    sampleRate*: uint32
    latencyCount*: uint64
    processCycles*: uint64
    processFrames*: uint64
    processErrors*: uint64
    lateProcessCalls*: uint64

static:
  doAssert supportsCopyMem(JackCallbackFunctions)
  doAssert supportsCopyMem(JackNotificationStateSnapshot)

{.push checks: off, stackTrace: off, lineTrace: off.}
proc initJackCallbackContext*(context: ptr JackCallbackContext;
                              functions: JackFunctions): bool =
  if context == nil:
    return false
  context.functions = JackCallbackFunctions(
    portGetBuffer: functions.portGetBuffer,
    portGetLatencyRange: functions.portGetLatencyRange,
    portSetLatencyRange: functions.portSetLatencyRange,
  )
  context.role.initAudioRoleGuard()
  context.processEnabled.store(0'u32, moRelaxed)
  context.callbacksInFlight.store(0'u32, moRelaxed)
  context.processInFlight.store(0'u32, moRelaxed)
  context.latencyFrames.store(0'u32, moRelaxed)
  context.notifications.shutdownCount.store(0'u64, moRelaxed)
  context.notifications.shutdownRecordState.store(0'u32, moRelaxed)
  context.notifications.shutdownStatus.store(0'i32, moRelaxed)
  context.notifications.xrunCount.store(0'u64, moRelaxed)
  context.notifications.freewheelCount.store(0'u64, moRelaxed)
  context.notifications.freewheelState.store(0'i32, moRelaxed)
  context.notifications.bufferSizeCount.store(0'u64, moRelaxed)
  context.notifications.bufferSize.store(0'u32, moRelaxed)
  context.notifications.sampleRateCount.store(0'u64, moRelaxed)
  context.notifications.sampleRate.store(0'u32, moRelaxed)
  context.notifications.latencyCount.store(0'u64, moRelaxed)
  context.notifications.processCycles.store(0'u64, moRelaxed)
  context.notifications.processFrames.store(0'u64, moRelaxed)
  context.notifications.processErrors.store(0'u64, moRelaxed)
  context.notifications.lateProcessCalls.store(0'u64, moRelaxed)
  true

proc callbackArgument*(context: ptr JackCallbackContext): pointer {.inline.} =
  cast[pointer](context)

proc configureCallbacks*(context: ptr JackCallbackContext; map: RtPortMap;
                         mode: FakeProcessMode): bool =
  if context == nil or context.processEnabled.load(moAcquire) != 0'u32 or
      context.processInFlight.load(moAcquire) != 0'u32:
    return false
  context.portMap = map
  context.engine.initRtEngine(
    mode, map.audioInputCount, map.audioOutputCount)

proc enableProcessCallbacks*(context: ptr JackCallbackContext) {.inline.} =
  context.processEnabled.store(1'u32, moRelease)

proc disableProcessCallbacks*(context: ptr JackCallbackContext) {.inline.} =
  context.processEnabled.store(0'u32, moRelease)

proc processCallbacksQuiescent*(context: ptr JackCallbackContext): bool {.inline.} =
  context == nil or context.processInFlight.load(moAcquire) == 0'u32

proc callbackContextReadyForRelease*(context: ptr JackCallbackContext): bool =
  context == nil or (
    context.callbacksInFlight.load(moAcquire) == 0'u32 and
    context.processInFlight.load(moAcquire) == 0'u32 and
    not context.role.isAudioRoleActive
  )

proc snapshotNotificationState*(
    context: ptr JackCallbackContext): JackNotificationStateSnapshot =
  if context == nil:
    return
  let notifications = addr context.notifications
  result.shutdownCount = notifications.shutdownCount.load(moAcquire)
  result.shutdownStatus = notifications.shutdownStatus.load(moAcquire)
  if notifications.shutdownRecordState.load(moAcquire) == 2'u32:
    result.shutdownReasonLength = notifications.shutdownReasonLength
    if result.shutdownReasonLength > uint32(ShutdownReasonBytes):
      result.shutdownReasonLength = uint32(ShutdownReasonBytes)
    var index = 0'u32
    while index < result.shutdownReasonLength:
      result.shutdownReason[int(index)] =
        notifications.shutdownReason[int(index)]
      index += 1'u32
  result.xrunCount = notifications.xrunCount.load(moAcquire)
  result.freewheelCount = notifications.freewheelCount.load(moAcquire)
  result.freewheel = notifications.freewheelState.load(moAcquire) != 0
  result.bufferSizeCount = notifications.bufferSizeCount.load(moAcquire)
  result.bufferSize = notifications.bufferSize.load(moAcquire)
  result.sampleRateCount = notifications.sampleRateCount.load(moAcquire)
  result.sampleRate = notifications.sampleRate.load(moAcquire)
  result.latencyCount = notifications.latencyCount.load(moAcquire)
  result.processCycles = notifications.processCycles.load(moAcquire)
  result.processFrames = notifications.processFrames.load(moAcquire)
  result.processErrors = notifications.processErrors.load(moAcquire)
  result.lateProcessCalls = notifications.lateProcessCalls.load(moAcquire)

proc enterCallback(context: ptr JackCallbackContext) {.inline, gcsafe, raises: [].} =
  discard context.callbacksInFlight.fetchAdd(1'u32, moAcquire)

proc leaveCallback(context: ptr JackCallbackContext) {.inline, gcsafe, raises: [].} =
  discard context.callbacksInFlight.fetchSub(1'u32, moRelease)

proc recordShutdown(context: ptr JackCallbackContext; status: int32;
                    reason: cstring) {.gcsafe, raises: [].} =
  discard context.notifications.shutdownCount.fetchAdd(1'u64, moRelaxed)
  var expected = 0'u32
  if not context.notifications.shutdownRecordState.compareExchange(
      expected, 1'u32, moAcquire, moRelaxed):
    return

  context.notifications.shutdownStatus.store(status, moRelaxed)
  var length = 0'u32
  if reason != nil:
    let bytes = cast[ptr UncheckedArray[char]](reason)
    while length < uint32(ShutdownReasonBytes) and bytes[int(length)] != '\0':
      context.notifications.shutdownReason[int(length)] = bytes[int(length)]
      length += 1'u32
  context.notifications.shutdownReasonLength = length
  context.notifications.shutdownRecordState.store(2'u32, moRelease)

proc jackProcessCallback*(nframes: JackNFrames; argument: pointer): cint {.
    exportc: "pluginhost_jack_process_callback", cdecl, gcsafe, raises: [].} =
  if argument == nil:
    return 0
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  discard context.processInFlight.fetchAdd(1'u32, moAcquire)

  if context.processEnabled.load(moAcquire) == 0'u32:
    discard context.notifications.lateProcessCalls.fetchAdd(1'u64, moRelaxed)
    discard context.processInFlight.fetchSub(1'u32, moRelease)
    context.leaveCallback()
    return 0

  var buffersValid = context.functions.portGetBuffer != nil
  var index = 0'u32
  while index < context.portMap.audioInputCount:
    let buffer = if context.functions.portGetBuffer == nil: nil else:
      context.functions.portGetBuffer(
        context.portMap.audioInputs[int(index)], nframes)
    if not setAudioInputBuffer(addr context.engine, index, buffer):
      buffersValid = false
    if buffer == nil:
      buffersValid = false
    index += 1'u32

  index = 0'u32
  while index < context.portMap.audioOutputCount:
    let buffer = if context.functions.portGetBuffer == nil: nil else:
      context.functions.portGetBuffer(
        context.portMap.audioOutputs[int(index)], nframes)
    if not setAudioOutputBuffer(addr context.engine, index, buffer):
      buffersValid = false
    if buffer == nil:
      buffersValid = false
    index += 1'u32

  var status = RtProcessMissingBuffer
  if buffersValid and tryEnterAudioRole(addr context.role):
    status = processRtFake(addr context.engine, nframes)
    if not leaveAudioRole(addr context.role):
      status = RtProcessInvalidContext
  else:
    discard zeroRtOutputs(addr context.engine, nframes)

  if status != RtProcessOk:
    discard zeroRtOutputs(addr context.engine, nframes)
    discard context.notifications.processErrors.fetchAdd(1'u64, moRelaxed)
  discard context.notifications.processCycles.fetchAdd(1'u64, moRelaxed)
  discard context.notifications.processFrames.fetchAdd(uint64(nframes), moRelaxed)
  discard context.processInFlight.fetchSub(1'u32, moRelease)
  context.leaveCallback()
  0

proc jackShutdownCallback*(argument: pointer) {.
    exportc: "pluginhost_jack_shutdown_callback", cdecl, gcsafe, raises: [].} =
  if argument == nil:
    return
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  context.recordShutdown(0'i32, nil)
  context.leaveCallback()

proc jackInfoShutdownCallback*(code: JackStatus; reason: cstring;
                               argument: pointer) {.
    exportc: "pluginhost_jack_info_shutdown_callback", cdecl, gcsafe,
    raises: [].} =
  if argument == nil:
    return
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  context.recordShutdown(int32(code), reason)
  context.leaveCallback()

proc jackBufferSizeCallback*(nframes: JackNFrames; argument: pointer): cint {.
    exportc: "pluginhost_jack_buffer_size_callback", cdecl, gcsafe,
    raises: [].} =
  if argument == nil:
    return 0
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  context.notifications.bufferSize.store(nframes, moRelaxed)
  discard context.notifications.bufferSizeCount.fetchAdd(1'u64, moRelease)
  context.leaveCallback()
  0

proc jackSampleRateCallback*(nframes: JackNFrames; argument: pointer): cint {.
    exportc: "pluginhost_jack_sample_rate_callback", cdecl, gcsafe,
    raises: [].} =
  if argument == nil:
    return 0
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  context.notifications.sampleRate.store(nframes, moRelaxed)
  discard context.notifications.sampleRateCount.fetchAdd(1'u64, moRelease)
  context.leaveCallback()
  0

proc jackXrunCallback*(argument: pointer): cint {.
    exportc: "pluginhost_jack_xrun_callback", cdecl, gcsafe, raises: [].} =
  if argument == nil:
    return 0
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  discard context.notifications.xrunCount.fetchAdd(1'u64, moRelaxed)
  context.leaveCallback()
  0

proc jackFreewheelCallback*(starting: cint; argument: pointer) {.
    exportc: "pluginhost_jack_freewheel_callback", cdecl, gcsafe,
    raises: [].} =
  if argument == nil:
    return
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  context.notifications.freewheelState.store(int32(starting), moRelaxed)
  discard context.notifications.freewheelCount.fetchAdd(1'u64, moRelease)
  context.leaveCallback()

proc saturatingAdd(value, additional: uint32): uint32 {.inline, raises: [].} =
  if value > high(uint32) - additional:
    high(uint32)
  else:
    value + additional

proc jackLatencyCallback*(mode: JackLatencyCallbackMode; argument: pointer) {.
    exportc: "pluginhost_jack_latency_callback", cdecl, gcsafe, raises: [].} =
  if argument == nil:
    return
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  discard context.notifications.latencyCount.fetchAdd(1'u64, moRelaxed)

  if context.functions.portGetLatencyRange == nil or
      context.functions.portSetLatencyRange == nil:
    context.leaveCallback()
    return

  var sourceCount = 0'u32
  var targetCount = 0'u32
  var sourcePorts: ptr UncheckedArray[JackPort]
  var targetPorts: ptr UncheckedArray[JackPort]
  if mode == JackPlaybackLatency:
    sourceCount = context.portMap.audioInputCount
    targetCount = context.portMap.audioOutputCount
    sourcePorts = cast[ptr UncheckedArray[JackPort]](
      addr context.portMap.audioInputs[0])
    targetPorts = cast[ptr UncheckedArray[JackPort]](
      addr context.portMap.audioOutputs[0])
  elif mode == JackCaptureLatency:
    sourceCount = context.portMap.audioOutputCount
    targetCount = context.portMap.audioInputCount
    sourcePorts = cast[ptr UncheckedArray[JackPort]](
      addr context.portMap.audioOutputs[0])
    targetPorts = cast[ptr UncheckedArray[JackPort]](
      addr context.portMap.audioInputs[0])
  else:
    context.leaveCallback()
    return

  var combined = JackLatencyRange(min: 0'u32, max: 0'u32)
  var sourceIndex = 0'u32
  while sourceIndex < sourceCount:
    var current: JackLatencyRange
    context.functions.portGetLatencyRange(
      sourcePorts[int(sourceIndex)], mode, addr current)
    if sourceIndex == 0'u32 or current.min < combined.min:
      combined.min = current.min
    if sourceIndex == 0'u32 or current.max > combined.max:
      combined.max = current.max
    sourceIndex += 1'u32

  let additional = context.latencyFrames.load(moRelaxed)
  combined.min = saturatingAdd(combined.min, additional)
  combined.max = saturatingAdd(combined.max, additional)
  var targetIndex = 0'u32
  while targetIndex < targetCount:
    context.functions.portSetLatencyRange(
      targetPorts[int(targetIndex)], mode, addr combined)
    targetIndex += 1'u32
  context.leaveCallback()
{.pop.}
