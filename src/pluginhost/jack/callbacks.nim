## Stable storage and allocation-free JACK callback trampolines.
## Callbacks record only bounded POD/atomic state. Cleanup and diagnostics belong
## to the control plane after JACK has been quiesced.

import std/typetraits

import ../rt/[atomic_pod, engine, midi_io, role_guard]
import ./[api, ffi, ports]

const ShutdownReasonBytes* = 256

type
  JackCallbackFunctions = object
    portGetBuffer: JackPortGetBufferProc
    portGetLatencyRange: JackPortGetLatencyRangeProc
    portSetLatencyRange: JackPortSetLatencyRangeProc
    midiGetEventCount: JackMidiGetEventCountProc
    midiEventGet: JackMidiEventGetProc
    midiClearBuffer: JackMidiClearBufferProc
    midiEventReserve: JackMidiEventReserveProc
    midiGetLostEventCount: JackMidiGetLostEventCountProc

  JackNotifications = object
    shutdownCount: RtAtomicU64
    shutdownRecordState: RtAtomicU32
    shutdownStatus: RtAtomicI32
    shutdownReasonLength: uint32
    shutdownReason: array[ShutdownReasonBytes, char]
    xrunCount: RtAtomicU64
    freewheelCount: RtAtomicU64
    freewheelState: RtAtomicI32
    bufferSizeCount: RtAtomicU64
    bufferSize: RtAtomicU32
    sampleRateCount: RtAtomicU64
    sampleRate: RtAtomicU32
    latencyCount: RtAtomicU64
    processCycles: RtAtomicU64
    processFrames: RtAtomicU64
    processErrors: RtAtomicU64
    lateProcessCalls: RtAtomicU64

  JackCallbackContext* = object
    functions: JackCallbackFunctions
    portMap: RtPortMap
    engine: RtEngine
    role: AudioRoleGuard
    processEnabled: RtAtomicU32
    configurationPending: RtAtomicU32
    configurationGeneration: RtAtomicU64
    callbacksInFlight: RtAtomicU32
    processInFlight: RtAtomicU32
    knownBufferSize: RtAtomicU32
    knownSampleRate: RtAtomicU32
    latencyFrames: RtAtomicU32
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
    configurationPending*: bool

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
    midiGetEventCount: functions.midiGetEventCount,
    midiEventGet: functions.midiEventGet,
    midiClearBuffer: functions.midiClearBuffer,
    midiEventReserve: functions.midiEventReserve,
    midiGetLostEventCount: functions.midiGetLostEventCount,
  )
  context.role.initAudioRoleGuard()
  context.processEnabled.storeRelaxed(0'u32)
  context.configurationPending.storeRelaxed(0'u32)
  context.configurationGeneration.storeRelaxed(0'u64)
  context.callbacksInFlight.storeRelaxed(0'u32)
  context.processInFlight.storeRelaxed(0'u32)
  context.knownBufferSize.storeRelaxed(0'u32)
  context.knownSampleRate.storeRelaxed(0'u32)
  context.latencyFrames.storeRelaxed(0'u32)
  context.notifications.shutdownCount.storeRelaxed(0'u64)
  context.notifications.shutdownRecordState.storeRelaxed(0'u32)
  context.notifications.shutdownStatus.storeRelaxed(0'i32)
  context.notifications.xrunCount.storeRelaxed(0'u64)
  context.notifications.freewheelCount.storeRelaxed(0'u64)
  context.notifications.freewheelState.storeRelaxed(0'i32)
  context.notifications.bufferSizeCount.storeRelaxed(0'u64)
  context.notifications.bufferSize.storeRelaxed(0'u32)
  context.notifications.sampleRateCount.storeRelaxed(0'u64)
  context.notifications.sampleRate.storeRelaxed(0'u32)
  context.notifications.latencyCount.storeRelaxed(0'u64)
  context.notifications.processCycles.storeRelaxed(0'u64)
  context.notifications.processFrames.storeRelaxed(0'u64)
  context.notifications.processErrors.storeRelaxed(0'u64)
  context.notifications.lateProcessCalls.storeRelaxed(0'u64)
  true

proc callbackArgument*(context: ptr JackCallbackContext): pointer {.inline.} =
  cast[pointer](context)

proc jackMidiEventCountAdapter(rawContext, portBuffer: pointer): uint32 {.
    exportc: "pluginhost_jack_midi_event_count", cdecl, gcsafe, raises: [].} =
  if rawContext == nil or portBuffer == nil:
    return 0'u32
  let context = cast[ptr JackCallbackContext](rawContext)
  if context.functions.midiGetEventCount == nil:
    return 0'u32
  context.functions.midiGetEventCount(portBuffer)

proc jackMidiEventGetAdapter(rawContext, portBuffer: pointer; index: uint32;
                              event: ptr RtMidiEventView): bool {.
    exportc: "pluginhost_jack_midi_event_get", cdecl, gcsafe, raises: [].} =
  if rawContext == nil or portBuffer == nil or event == nil:
    return false
  let context = cast[ptr JackCallbackContext](rawContext)
  if context.functions.midiEventGet == nil:
    return false
  var raw: JackMidiEvent
  if context.functions.midiEventGet(addr raw, portBuffer, index) != 0 or
      raw.size > csize_t(high(uint32)) or
      (raw.size != 0 and raw.buffer == nil):
    return false
  event.time = raw.time
  event.size = uint32(raw.size)
  event.data = cast[ptr UncheckedArray[uint8]](raw.buffer)
  true

proc jackMidiClearAdapter(rawContext, portBuffer: pointer) {.
    exportc: "pluginhost_jack_midi_clear", cdecl, gcsafe, raises: [].} =
  if rawContext == nil or portBuffer == nil:
    return
  let context = cast[ptr JackCallbackContext](rawContext)
  if context.functions.midiClearBuffer != nil:
    context.functions.midiClearBuffer(portBuffer)

proc jackMidiReserveAdapter(rawContext, portBuffer: pointer; time, size: uint32):
    ptr UncheckedArray[uint8] {.
    exportc: "pluginhost_jack_midi_reserve", cdecl, gcsafe, raises: [].} =
  if rawContext == nil or portBuffer == nil or size == 0'u32:
    return nil
  let context = cast[ptr JackCallbackContext](rawContext)
  if context.functions.midiEventReserve == nil:
    return nil
  cast[ptr UncheckedArray[uint8]](
    context.functions.midiEventReserve(portBuffer, time, csize_t(size)))

proc jackMidiLostEventCountAdapter(rawContext, portBuffer: pointer): uint32 {.
    exportc: "pluginhost_jack_midi_lost_event_count", cdecl, gcsafe,
    raises: [].} =
  if rawContext == nil or portBuffer == nil:
    return 0'u32
  let context = cast[ptr JackCallbackContext](rawContext)
  if context.functions.midiGetLostEventCount == nil:
    return 0'u32
  context.functions.midiGetLostEventCount(portBuffer)

proc midiIo(context: ptr JackCallbackContext): RtMidiIo {.
    inline, gcsafe, raises: [].} =
  RtMidiIo(
    context: cast[pointer](context),
    eventCount: jackMidiEventCountAdapter,
    eventGet: jackMidiEventGetAdapter,
    clear: jackMidiClearAdapter,
    reserve: jackMidiReserveAdapter,
    lostEventCount: jackMidiLostEventCountAdapter,
  )

proc configureCallbacks*(context: ptr JackCallbackContext; map: RtPortMap;
                         mode: FakeProcessMode): bool =
  if context == nil or context.processEnabled.loadAcquire() != 0'u32 or
      context.processInFlight.loadAcquire() != 0'u32:
    return false
  context.portMap = map
  context.engine.initRtEngine(
    mode, map.audioInputCount, map.audioOutputCount,
    map.noteInputCount, map.noteOutputCount, context.midiIo())

proc configureEndpointCallbacks*(context: ptr JackCallbackContext;
                                  map: RtPortMap;
                                  endpoint: RtProcessEndpoint): bool =
  if context == nil or context.processEnabled.loadAcquire() != 0'u32 or
      context.processInFlight.loadAcquire() != 0'u32 or
      context.configurationPending.loadAcquire() != 0'u32:
    return false
  if not context.engine.initRtEngineEndpoint(
      map.audioInputCount, map.audioOutputCount,
      map.noteInputCount, map.noteOutputCount, endpoint.maxFrames, endpoint,
      context.midiIo()):
    return false
  context.portMap = map
  true

proc updateProcessEndpoint*(context: ptr JackCallbackContext;
                            endpoint: RtProcessEndpoint): bool =
  if context == nil or endpoint.callback == nil or endpoint.maxFrames == 0'u32 or
      context.processEnabled.loadAcquire() != 0'u32 or
      context.processInFlight.loadAcquire() != 0'u32:
    return false
  context.engine.endpoint = endpoint
  context.engine.maxFrames = endpoint.maxFrames
  true

proc enableProcessCallbacks*(context: ptr JackCallbackContext) {.inline.} =
  if context.configurationPending.loadAcquire() == 0'u32:
    context.processEnabled.storeRelease(1'u32)
  else:
    context.processEnabled.storeRelease(0'u32)

proc disableProcessCallbacks*(context: ptr JackCallbackContext) {.inline.} =
  context.processEnabled.storeRelease(0'u32)

proc setRuntimeConfigurationBaseline*(context: ptr JackCallbackContext;
                                        sampleRate, bufferSize: uint32): bool =
  if context == nil or sampleRate == 0'u32 or bufferSize == 0'u32 or
      context.processEnabled.loadAcquire() != 0'u32 or
      context.processInFlight.loadAcquire() != 0'u32 or
      context.callbacksInFlight.loadAcquire() != 0'u32:
    return false
  context.knownSampleRate.storeRelease(sampleRate)
  context.knownBufferSize.storeRelease(bufferSize)
  true

proc configurationGeneration*(context: ptr JackCallbackContext): uint64 {.
    inline.} =
  if context == nil: 0'u64 else:
    context.configurationGeneration.loadAcquire()

proc configurationReadStable*(context: ptr JackCallbackContext;
                              expectedGeneration: uint64): bool =
  if context == nil or context.callbacksInFlight.loadAcquire() != 0'u32 or
      context.configurationGeneration.loadAcquire() != expectedGeneration:
    return false
  context.callbacksInFlight.loadAcquire() == 0'u32 and
    context.configurationGeneration.loadAcquire() == expectedGeneration

proc clearConfigurationPending*(context: ptr JackCallbackContext;
                                 sampleRate, bufferSize: uint32;
                                 expectedGeneration: uint64): bool =
  if context == nil or sampleRate == 0'u32 or bufferSize == 0'u32 or
      context.processEnabled.loadAcquire() != 0'u32 or
      context.processInFlight.loadAcquire() != 0'u32 or
      not context.configurationReadStable(expectedGeneration):
    return false
  context.knownSampleRate.storeRelease(sampleRate)
  context.knownBufferSize.storeRelease(bufferSize)
  context.configurationPending.storeRelease(0'u32)
  if not context.configurationReadStable(expectedGeneration):
    context.configurationPending.storeRelease(1'u32)
    return false
  true

proc configurationChangePending*(context: ptr JackCallbackContext): bool {.
    inline.} =
  context != nil and context.configurationPending.loadAcquire() != 0'u32

proc setPluginLatency*(context: ptr JackCallbackContext; frames: uint32): bool =
  if context == nil:
    return false
  context.latencyFrames.storeRelease(frames)
  true

proc pluginLatency*(context: ptr JackCallbackContext): uint32 =
  if context == nil:
    return 0'u32
  context.latencyFrames.loadAcquire()

proc audioRolePointer*(context: ptr JackCallbackContext): ptr AudioRoleGuard {.
    inline.} =
  if context == nil:
    return nil
  addr context.role

proc processCallbacksQuiescent*(context: ptr JackCallbackContext): bool {.inline.} =
  context == nil or context.processInFlight.loadAcquire() == 0'u32

proc callbackContextReadyForRelease*(context: ptr JackCallbackContext): bool =
  context == nil or (
    context.callbacksInFlight.loadAcquire() == 0'u32 and
    context.processInFlight.loadAcquire() == 0'u32 and
    not context.role.isAudioRoleActive
  )

proc snapshotNotificationState*(
    context: ptr JackCallbackContext): JackNotificationStateSnapshot =
  if context == nil:
    return
  let notifications = addr context.notifications
  result.shutdownCount = notifications.shutdownCount.loadAcquire()
  result.shutdownStatus = notifications.shutdownStatus.loadAcquire()
  if notifications.shutdownRecordState.loadAcquire() == 2'u32:
    result.shutdownReasonLength = notifications.shutdownReasonLength
    if result.shutdownReasonLength > uint32(ShutdownReasonBytes):
      result.shutdownReasonLength = uint32(ShutdownReasonBytes)
    var index = 0'u32
    while index < result.shutdownReasonLength:
      result.shutdownReason[int(index)] =
        notifications.shutdownReason[int(index)]
      index += 1'u32
  result.xrunCount = notifications.xrunCount.loadAcquire()
  result.freewheelCount = notifications.freewheelCount.loadAcquire()
  result.freewheel = notifications.freewheelState.loadAcquire() != 0
  result.bufferSizeCount = notifications.bufferSizeCount.loadAcquire()
  result.bufferSize = notifications.bufferSize.loadAcquire()
  result.sampleRateCount = notifications.sampleRateCount.loadAcquire()
  result.sampleRate = notifications.sampleRate.loadAcquire()
  result.latencyCount = notifications.latencyCount.loadAcquire()
  result.processCycles = notifications.processCycles.loadAcquire()
  result.processFrames = notifications.processFrames.loadAcquire()
  result.processErrors = notifications.processErrors.loadAcquire()
  result.lateProcessCalls = notifications.lateProcessCalls.loadAcquire()
  result.configurationPending =
    context.configurationPending.loadAcquire() != 0'u32

proc enterCallback(context: ptr JackCallbackContext) {.inline, gcsafe, raises: [].} =
  discard context.callbacksInFlight.fetchAddAcquire(1'u32)

proc leaveCallback(context: ptr JackCallbackContext) {.inline, gcsafe, raises: [].} =
  discard context.callbacksInFlight.fetchSubRelease(1'u32)

proc markConfigurationChange(context: ptr JackCallbackContext;
                              sampleRate, bufferSize: uint32) {.
    inline, gcsafe, raises: [].} =
  if (sampleRate != 0'u32 and
      context.knownSampleRate.loadAcquire() != sampleRate) or
      (bufferSize != 0'u32 and
      context.knownBufferSize.loadAcquire() != bufferSize):
    context.configurationPending.storeRelease(1'u32)
    context.processEnabled.storeRelease(0'u32)
  discard context.configurationGeneration.fetchAddRelease(1'u64)

proc bindOutputBuffers(context: ptr JackCallbackContext;
                       nframes: JackNFrames): bool {.
    inline, gcsafe, raises: [].} =
  var buffersValid = context.functions.portGetBuffer != nil
  var index = 0'u32
  while index < context.portMap.audioOutputCount:
    let buffer = if context.functions.portGetBuffer == nil: nil else:
      context.functions.portGetBuffer(
        context.portMap.audioOutputs[int(index)], nframes)
    if not setAudioOutputBuffer(addr context.engine, index, buffer) or
        buffer == nil:
      buffersValid = false
    index += 1'u32

  index = 0'u32
  while index < context.portMap.noteOutputCount:
    let buffer = if context.functions.portGetBuffer == nil: nil else:
      context.functions.portGetBuffer(
        context.portMap.noteOutputs[int(index)], nframes)
    if not setMidiOutputBuffer(addr context.engine, index, buffer) or
        buffer == nil or context.engine.midiIo.clear == nil:
      buffersValid = false
    else:
      context.engine.midiIo.clear(context.engine.midiIo.context, buffer)
    index += 1'u32
  buffersValid

proc recordShutdown(context: ptr JackCallbackContext; status: int32;
                    reason: cstring) {.gcsafe, raises: [].} =
  context.processEnabled.storeRelease(0'u32)
  var expected = 0'u32
  if not context.notifications.shutdownRecordState.compareExchangeAcquire(
      expected, 1'u32):
    return

  context.notifications.shutdownStatus.storeRelaxed(status)
  var length = 0'u32
  if cast[pointer](reason) != nil:
    let bytes = cast[ptr UncheckedArray[char]](reason)
    while length < uint32(ShutdownReasonBytes) and bytes[int(length)] != '\0':
      context.notifications.shutdownReason[int(length)] = bytes[int(length)]
      length += 1'u32
  context.notifications.shutdownReasonLength = length
  context.notifications.shutdownRecordState.storeRelease(2'u32)

proc jackProcessCallback*(nframes: JackNFrames; argument: pointer): cint {.
    exportc: "pluginhost_jack_process_callback", cdecl, gcsafe, raises: [].} =
  if argument == nil:
    return 0
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  discard context.processInFlight.fetchAddAcquire(1'u32)

  if context.processEnabled.loadAcquire() == 0'u32:
    discard bindOutputBuffers(context, nframes)
    discard zeroRtOutputs(addr context.engine, nframes)
    discard context.notifications.lateProcessCalls.fetchAddRelaxed(1'u64)
    discard context.processInFlight.fetchSubRelease(1'u32)
    context.leaveCallback()
    return 0

  var buffersValid = bindOutputBuffers(context, nframes)
  var index = 0'u32
  while index < context.portMap.audioInputCount:
    let buffer = if context.functions.portGetBuffer == nil: nil else:
      context.functions.portGetBuffer(
        context.portMap.audioInputs[int(index)], nframes)
    if not setAudioInputBuffer(addr context.engine, index, buffer) or
        buffer == nil:
      buffersValid = false
    index += 1'u32

  index = 0'u32
  while index < context.portMap.noteInputCount:
    let buffer = if context.functions.portGetBuffer == nil: nil else:
      context.functions.portGetBuffer(
        context.portMap.noteInputs[int(index)], nframes)
    if not setMidiInputBuffer(addr context.engine, index, buffer) or
        buffer == nil:
      buffersValid = false
    index += 1'u32

  var status = RtProcessMissingBuffer
  if buffersValid and tryEnterAudioRole(addr context.role):
    status = processRt(addr context.engine, nframes)
    if not leaveAudioRole(addr context.role):
      status = RtProcessInvalidContext
  else:
    discard zeroRtOutputs(addr context.engine, nframes)

  var callbackResult = 0.cint
  if status != RtProcessOk:
    discard bindOutputBuffers(context, nframes)
    discard zeroRtOutputs(addr context.engine, nframes)
    discard context.notifications.processErrors.fetchAddRelaxed(1'u64)
    context.processEnabled.storeRelease(0'u32)
    callbackResult = 1
  discard context.notifications.processCycles.fetchAddRelaxed(1'u64)
  discard context.notifications.processFrames.fetchAddRelaxed(uint64(nframes))
  discard context.processInFlight.fetchSubRelease(1'u32)
  context.leaveCallback()
  callbackResult

proc jackShutdownCallback*(argument: pointer) {.
    exportc: "pluginhost_jack_shutdown_callback", cdecl, gcsafe, raises: [].} =
  if argument == nil:
    return
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  context.recordShutdown(0'i32, nil)
  context.leaveCallback()
  discard context.notifications.shutdownCount.fetchAddRelease(1'u64)

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
  discard context.notifications.shutdownCount.fetchAddRelease(1'u64)

proc jackBufferSizeCallback*(nframes: JackNFrames; argument: pointer): cint {.
    exportc: "pluginhost_jack_buffer_size_callback", cdecl, gcsafe,
    raises: [].} =
  if argument == nil:
    return 0
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  context.notifications.bufferSize.storeRelaxed(nframes)
  discard context.notifications.bufferSizeCount.fetchAddRelease(1'u64)
  context.markConfigurationChange(0'u32, nframes)
  context.leaveCallback()
  0

proc jackSampleRateCallback*(nframes: JackNFrames; argument: pointer): cint {.
    exportc: "pluginhost_jack_sample_rate_callback", cdecl, gcsafe,
    raises: [].} =
  if argument == nil:
    return 0
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  context.notifications.sampleRate.storeRelaxed(nframes)
  discard context.notifications.sampleRateCount.fetchAddRelease(1'u64)
  context.markConfigurationChange(nframes, 0'u32)
  context.leaveCallback()
  0

proc jackXrunCallback*(argument: pointer): cint {.
    exportc: "pluginhost_jack_xrun_callback", cdecl, gcsafe, raises: [].} =
  if argument == nil:
    return 0
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  discard context.notifications.xrunCount.fetchAddRelaxed(1'u64)
  context.leaveCallback()
  0

proc jackFreewheelCallback*(starting: cint; argument: pointer) {.
    exportc: "pluginhost_jack_freewheel_callback", cdecl, gcsafe,
    raises: [].} =
  if argument == nil:
    return
  let context = cast[ptr JackCallbackContext](argument)
  context.enterCallback()
  context.notifications.freewheelState.storeRelaxed(int32(starting))
  discard context.notifications.freewheelCount.fetchAddRelease(1'u64)
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
  discard context.notifications.latencyCount.fetchAddRelaxed(1'u64)

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

  let additional = context.latencyFrames.loadRelaxed()
  combined.min = saturatingAdd(combined.min, additional)
  combined.max = saturatingAdd(combined.max, additional)
  var targetIndex = 0'u32
  while targetIndex < targetCount:
    context.functions.portSetLatencyRange(
      targetPorts[int(targetIndex)], mode, addr combined)
    targetIndex += 1'u32
  context.leaveCallback()
{.pop.}
