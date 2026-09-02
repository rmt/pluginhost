import std/[posix, typetraits]

import ../rt/[atomic_pod, role_guard]
import ../version
import ./[ffi, main_thread_services]

const
  HostLogQueueCapacity* = 256
  HostLogMessageBytes* = 1024

  ClapRequestRestart* = 1'u32 shl 0
  ClapRequestProcess* = 1'u32 shl 1
  ClapRequestCallback* = 1'u32 shl 2
  ClapRequestFlush* = 1'u32 shl 3


type
  ClapHostLogRecord* {.bycopy.} = object
    severity*: ClapLogSeverity
    length*: uint32
    truncated*: bool
    message*: array[HostLogMessageBytes, char]


  HostLogCell = object
    sequence: RtAtomicU64
    record: ClapHostLogRecord

  HostLogQueue = object
    enqueuePosition: RtAtomicU64
    dequeuePosition: RtAtomicU64
    cells: array[HostLogQueueCapacity, HostLogCell]

  HostCallbackData = object
    requests: ptr RtAtomicU32
    logs: ptr HostLogQueue
    droppedLogs: ptr RtAtomicU64
    logExtension: ptr ClapHostLog
    stateExtension: ptr ClapHostState
    paramsExtension: ptr ClapHostParams
    audioPortsExtension: ptr ClapHostAudioPorts
    notePortsExtension: ptr ClapHostNotePorts
    latencyExtension: ptr ClapHostLatency
    timerExtension: ptr ClapHostTimerSupport
    posixFdExtension: ptr ClapHostPosixFdSupport
    threadCheckExtension: ptr ClapHostThreadCheck
    mainServices: ptr ClapMainThreadServices
    stateDirty: ptr RtAtomicU32
    latencyChanged: ptr RtAtomicU32
    paramsRescan: ptr RtAtomicU32
    audioPortsRescan: ptr RtAtomicU32
    notePortsRescan: ptr RtAtomicU32
    processWake: ptr RtAtomicU32
    flushWake: ptr RtAtomicU32
    audioRoleAddress: ptr RtAtomicU64
    mainThread: Pthread

  ClapHostBridge* = ref object
    host: ClapHost
    logExtension: ClapHostLog
    stateExtension: ClapHostState
    paramsExtension: ClapHostParams
    audioPortsExtension: ClapHostAudioPorts
    notePortsExtension: ClapHostNotePorts
    latencyExtension: ClapHostLatency
    timerExtension: ClapHostTimerSupport
    posixFdExtension: ClapHostPosixFdSupport
    threadCheckExtension: ClapHostThreadCheck
    callbackData: HostCallbackData
    requests: RtAtomicU32
    droppedLogs: RtAtomicU64
    stateDirty: RtAtomicU32
    latencyChanged: RtAtomicU32
    paramsRescan: RtAtomicU32
    audioPortsRescan: RtAtomicU32
    notePortsRescan: RtAtomicU32
    processWake: RtAtomicU32
    flushWake: RtAtomicU32
    audioRoleAddress: RtAtomicU64
    logs: HostLogQueue
    name: string
    vendor: string
    url: string
    version: string

static:
  doAssert supportsCopyMem(ClapHostLogRecord)
  doAssert sizeof(pointer) == sizeof(uint64),
    "atomic audio-role publication requires a 64-bit pointer target"

{.push checks: off, stackTrace: off, lineTrace: off.}
proc initLogQueue(queue: var HostLogQueue) {.gcsafe, raises: [].} =
  queue.enqueuePosition.storeRelaxed(0'u64)
  queue.dequeuePosition.storeRelaxed(0'u64)
  for index in 0 ..< HostLogQueueCapacity:
    queue.cells[index].sequence.storeRelaxed(uint64(index))

proc cstringEquals(left, right: cstring): bool {.
    exportc: "pluginhost_clap_host_cstring_equals", inline, gcsafe, raises: [].} =
  if cast[pointer](left) == nil or cast[pointer](right) == nil:
    return false
  let leftBytes = cast[ptr UncheckedArray[char]](left)
  let rightBytes = cast[ptr UncheckedArray[char]](right)
  var index = 0
  while true:
    if leftBytes[index] != rightBytes[index]:
      return false
    if leftBytes[index] == '\0':
      return true
    inc index

proc tryPush(queue: ptr HostLogQueue;
             record: ptr ClapHostLogRecord): bool {.
    exportc: "pluginhost_clap_host_log_try_push", gcsafe, raises: [].} =
  if queue == nil or record == nil:
    return false

  var position = queue.enqueuePosition.loadRelaxed()
  while true:
    let cell = addr queue.cells[int(position mod uint64(HostLogQueueCapacity))]
    let sequence = cell.sequence.loadAcquire()
    let difference = cast[int64](sequence - position)
    if difference == 0:
      var expected = position
      if queue.enqueuePosition.compareExchangeRelaxed(
          expected, position + 1'u64):
        break
      position = expected
    elif difference < 0:
      return false
    else:
      position = queue.enqueuePosition.loadRelaxed()

  let cell = addr queue.cells[int(position mod uint64(HostLogQueueCapacity))]
  cell.record = record[]
  cell.sequence.storeRelease(position + 1'u64)
  true

proc tryPop(queue: ptr HostLogQueue;
            record: var ClapHostLogRecord): bool {.gcsafe, raises: [].} =
  if queue == nil:
    return false

  let position = queue.dequeuePosition.loadRelaxed()
  let cell = addr queue.cells[int(position mod uint64(HostLogQueueCapacity))]
  let sequence = cell.sequence.loadAcquire()
  if cast[int64](sequence - (position + 1'u64)) != 0:
    return false

  record = cell.record
  cell.sequence.storeRelease(position + uint64(HostLogQueueCapacity))
  queue.dequeuePosition.storeRelaxed(position + 1'u64)
  true

proc callbackData(host: ptr ClapHost): ptr HostCallbackData {.
    exportc: "pluginhost_clap_host_callback_data", inline, gcsafe, raises: [].} =
  if host == nil:
    return nil
  cast[ptr HostCallbackData](host.hostData)

proc hostGetExtension(host: ptr ClapHost; extensionId: cstring): pointer {.
    exportc: "pluginhost_clap_host_get_extension", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data == nil:
    return nil
  if cstringEquals(extensionId, ClapExtLog.cstring):
    return cast[pointer](data.logExtension)
  if cstringEquals(extensionId, ClapExtState.cstring):
    return cast[pointer](data.stateExtension)
  if cstringEquals(extensionId, ClapExtParams.cstring):
    return cast[pointer](data.paramsExtension)
  if cstringEquals(extensionId, ClapExtAudioPorts.cstring):
    return cast[pointer](data.audioPortsExtension)
  if cstringEquals(extensionId, ClapExtNotePorts.cstring):
    return cast[pointer](data.notePortsExtension)
  if cstringEquals(extensionId, ClapExtLatency.cstring):
    return cast[pointer](data.latencyExtension)
  if cstringEquals(extensionId, ClapExtTimerSupport.cstring) and
      data.mainServices.isComplete:
    return cast[pointer](data.timerExtension)
  if cstringEquals(extensionId, ClapExtPosixFdSupport.cstring) and
      data.mainServices.isComplete:
    return cast[pointer](data.posixFdExtension)
  if cstringEquals(extensionId, ClapExtThreadCheck.cstring):
    return cast[pointer](data.threadCheckExtension)
  nil

proc recordRequest(host: ptr ClapHost; request: uint32) {.
    exportc: "pluginhost_clap_host_record_request", gcsafe, raises: [].} =
  let data = callbackData(host)
  if data != nil and data.requests != nil:
    discard data.requests[].fetchOrRelaxed(request)

proc hostRequestRestart(host: ptr ClapHost) {.
    exportc: "pluginhost_clap_host_request_restart", cdecl, gcsafe, raises: [].} =
  recordRequest(host, ClapRequestRestart)

proc hostRequestProcess(host: ptr ClapHost) {.
    exportc: "pluginhost_clap_host_request_process", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data != nil and data.processWake != nil:
    data.processWake[].storeRelease(1'u32)
  recordRequest(host, ClapRequestProcess)

proc hostRequestCallback(host: ptr ClapHost) {.
    exportc: "pluginhost_clap_host_request_callback", cdecl, gcsafe, raises: [].} =
  recordRequest(host, ClapRequestCallback)

proc hostLog(host: ptr ClapHost; severity: ClapLogSeverity; message: cstring) {.
    exportc: "pluginhost_clap_host_log", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data == nil or data.logs == nil or data.droppedLogs == nil:
    return

  var record = ClapHostLogRecord(severity: severity)
  if cast[pointer](message) != nil:
    let bytes = cast[ptr UncheckedArray[char]](message)
    var length = 0
    while length < HostLogMessageBytes and bytes[length] != '\0':
      inc length
    record.length = uint32(length)
    record.truncated = length == HostLogMessageBytes and
      bytes[length] != '\0'
    if length > 0:
      copyMem(addr record.message[0], unsafeAddr bytes[0], length)

  if not tryPush(data.logs, addr record):
    discard data.droppedLogs[].fetchAddRelaxed(1'u64)

proc hostIsMainThread(host: ptr ClapHost): bool {.
    exportc: "pluginhost_clap_host_is_main_thread", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  data != nil and pthread_equal(pthread_self(), data.mainThread) != 0

proc hostIsAudioThread(host: ptr ClapHost): bool {.
    exportc: "pluginhost_clap_host_is_audio_thread", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data == nil or data.audioRoleAddress == nil:
    return false
  let roleAddress = data.audioRoleAddress[].loadAcquire()
  roleAddress != 0'u64 and
    isAudioRoleThread(cast[ptr AudioRoleGuard](roleAddress))

proc hostStateMarkDirty(host: ptr ClapHost) {.
    exportc: "pluginhost_clap_host_state_mark_dirty", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data != nil and data.stateDirty != nil and
      pthread_equal(pthread_self(), data.mainThread) != 0:
    data.stateDirty[].storeRelease(1'u32)

proc hostLatencyChanged(host: ptr ClapHost) {.
    exportc: "pluginhost_clap_host_latency_changed", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data != nil and data.latencyChanged != nil and
      pthread_equal(pthread_self(), data.mainThread) != 0:
    data.latencyChanged[].storeRelease(1'u32)

const
  ClapAudioPortsRescanKnown = ClapAudioPortsRescanNames or
    ClapAudioPortsRescanFlags or ClapAudioPortsRescanChannelCount or
    ClapAudioPortsRescanPortType or ClapAudioPortsRescanInPlacePair or
    ClapAudioPortsRescanList
  ClapNotePortsRescanKnown = ClapNotePortsRescanAll or ClapNotePortsRescanNames

proc callbackIsMain(data: ptr HostCallbackData): bool {.inline, gcsafe, raises: [].} =
  data != nil and pthread_equal(pthread_self(), data.mainThread) != 0

proc hostParamsRescan(host: ptr ClapHost; flags: uint32) {.
    exportc: "pluginhost_clap_host_params_rescan", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if callbackIsMain(data) and data.paramsRescan != nil and flags != 0'u32 and
      (flags and not ClapParamRescanKnown) == 0'u32:
    discard data.paramsRescan[].fetchOrRelaxed(flags)

proc hostParamsClear(host: ptr ClapHost; paramId: ClapId; flags: uint32) {.
    exportc: "pluginhost_clap_host_params_clear", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if not callbackIsMain(data) or flags == 0'u32 or
      (flags and not ClapParamClearKnown) != 0'u32:
    return
  # The host has no retained automation/modulation references in this increment.
  discard paramId

proc hostParamsRequestFlush(host: ptr ClapHost) {.
    exportc: "pluginhost_clap_host_params_request_flush", cdecl, gcsafe,
    raises: [].} =
  let data = callbackData(host)
  if data != nil and data.flushWake != nil:
    data.flushWake[].storeRelease(1'u32)
  recordRequest(host, ClapRequestFlush)

proc hostAudioPortsIsRescanSupported(host: ptr ClapHost; flag: uint32): bool {.
    exportc: "pluginhost_clap_host_audio_ports_is_rescan_supported", cdecl,
    gcsafe, raises: [].} =
  let data = callbackData(host)
  callbackIsMain(data) and flag != 0'u32 and
    (flag and not ClapAudioPortsRescanKnown) == 0'u32

proc hostAudioPortsRescan(host: ptr ClapHost; flags: uint32) {.
    exportc: "pluginhost_clap_host_audio_ports_rescan", cdecl, gcsafe,
    raises: [].} =
  let data = callbackData(host)
  if callbackIsMain(data) and data.audioPortsRescan != nil and flags != 0'u32 and
      (flags and not ClapAudioPortsRescanKnown) == 0'u32:
    discard data.audioPortsRescan[].fetchOrRelaxed(flags)

proc hostNotePortsSupportedDialects(host: ptr ClapHost): uint32 {.
    exportc: "pluginhost_clap_host_note_ports_supported_dialects", cdecl,
    gcsafe, raises: [].} =
  let data = callbackData(host)
  if not callbackIsMain(data):
    return 0'u32
  ClapNoteDialectClap or ClapNoteDialectMidi or ClapNoteDialectMidiMpe

proc hostNotePortsRescan(host: ptr ClapHost; flags: uint32) {.
    exportc: "pluginhost_clap_host_note_ports_rescan", cdecl, gcsafe,
    raises: [].} =
  let data = callbackData(host)
  if callbackIsMain(data) and data.notePortsRescan != nil and flags != 0'u32 and
      (flags and not ClapNotePortsRescanKnown) == 0'u32:
    discard data.notePortsRescan[].fetchOrRelaxed(flags)


proc hostRegisterTimer(host: ptr ClapHost; periodMs: uint32;
                       timerId: ptr ClapId): bool {.
    exportc: "pluginhost_clap_host_register_timer", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data == nil or timerId == nil or periodMs == 0'u32 or
      pthread_equal(pthread_self(), data.mainThread) == 0 or
      not data.mainServices.isComplete:
    return false
  data.mainServices.registerTimer(
    data.mainServices.context, periodMs, cast[ptr uint32](timerId))

proc hostUnregisterTimer(host: ptr ClapHost; timerId: ClapId): bool {.
    exportc: "pluginhost_clap_host_unregister_timer", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data == nil or pthread_equal(pthread_self(), data.mainThread) == 0 or
      not data.mainServices.isComplete:
    return false
  data.mainServices.unregisterTimer(data.mainServices.context, timerId)

proc validFdFlags(flags: uint32): bool {.inline, gcsafe, raises: [].} =
  flags != 0'u32 and
    (flags and not (ClapPosixFdRead or ClapPosixFdWrite or ClapPosixFdError)) == 0'u32

proc hostRegisterFd(host: ptr ClapHost; fd: cint; flags: uint32): bool {.
    exportc: "pluginhost_clap_host_register_fd", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data == nil or fd < 0 or not validFdFlags(flags) or
      pthread_equal(pthread_self(), data.mainThread) == 0 or
      not data.mainServices.isComplete:
    return false
  data.mainServices.registerFd(data.mainServices.context, int32(fd), flags)

proc hostModifyFd(host: ptr ClapHost; fd: cint; flags: uint32): bool {.
    exportc: "pluginhost_clap_host_modify_fd", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data == nil or fd < 0 or not validFdFlags(flags) or
      pthread_equal(pthread_self(), data.mainThread) == 0 or
      not data.mainServices.isComplete:
    return false
  data.mainServices.modifyFd(data.mainServices.context, int32(fd), flags)

proc hostUnregisterFd(host: ptr ClapHost; fd: cint): bool {.
    exportc: "pluginhost_clap_host_unregister_fd", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  if data == nil or fd < 0 or pthread_equal(pthread_self(), data.mainThread) == 0 or
      not data.mainServices.isComplete:
    return false
  data.mainServices.unregisterFd(data.mainServices.context, int32(fd))

{.pop.}

proc newClapHostBridge*(mainServices: ptr ClapMainThreadServices = nil): ClapHostBridge =
  new(result)
  result.name = ProductName
  result.vendor = ProductName
  result.url = ""
  result.version = Version
  result.requests.storeRelaxed(0'u32)
  result.droppedLogs.storeRelaxed(0'u64)
  result.stateDirty.storeRelaxed(0'u32)
  result.latencyChanged.storeRelaxed(0'u32)
  result.paramsRescan.storeRelaxed(0'u32)
  result.audioPortsRescan.storeRelaxed(0'u32)
  result.notePortsRescan.storeRelaxed(0'u32)
  result.processWake.storeRelaxed(0'u32)
  result.flushWake.storeRelaxed(0'u32)
  result.audioRoleAddress.storeRelaxed(0'u64)
  result.logs.initLogQueue()
  result.callbackData.requests = addr result.requests
  result.callbackData.logs = addr result.logs
  result.callbackData.droppedLogs = addr result.droppedLogs
  result.callbackData.stateDirty = addr result.stateDirty
  result.callbackData.latencyChanged = addr result.latencyChanged
  result.callbackData.paramsRescan = addr result.paramsRescan
  result.callbackData.audioPortsRescan = addr result.audioPortsRescan
  result.callbackData.notePortsRescan = addr result.notePortsRescan
  result.callbackData.processWake = addr result.processWake
  result.callbackData.flushWake = addr result.flushWake
  result.callbackData.audioRoleAddress = addr result.audioRoleAddress
  result.callbackData.mainThread = pthread_self()
  result.callbackData.mainServices = mainServices
  result.logExtension = ClapHostLog(log: hostLog)
  result.stateExtension = ClapHostState(markDirty: hostStateMarkDirty)
  result.latencyExtension = ClapHostLatency(changed: hostLatencyChanged)
  result.paramsExtension = ClapHostParams(
    rescan: hostParamsRescan, clear: hostParamsClear,
    requestFlush: hostParamsRequestFlush)
  result.audioPortsExtension = ClapHostAudioPorts(
    isRescanFlagSupported: hostAudioPortsIsRescanSupported,
    rescan: hostAudioPortsRescan)
  result.notePortsExtension = ClapHostNotePorts(
    supportedDialects: hostNotePortsSupportedDialects,
    rescan: hostNotePortsRescan)
  result.timerExtension = ClapHostTimerSupport(
    registerTimer: hostRegisterTimer, unregisterTimer: hostUnregisterTimer)
  result.posixFdExtension = ClapHostPosixFdSupport(
    registerFd: hostRegisterFd, modifyFd: hostModifyFd,
    unregisterFd: hostUnregisterFd)
  result.threadCheckExtension = ClapHostThreadCheck(
    isMainThread: hostIsMainThread,
    isAudioThread: hostIsAudioThread,
  )
  result.callbackData.logExtension = addr result.logExtension
  result.callbackData.stateExtension = addr result.stateExtension
  result.callbackData.paramsExtension = addr result.paramsExtension
  result.callbackData.audioPortsExtension = addr result.audioPortsExtension
  result.callbackData.notePortsExtension = addr result.notePortsExtension
  result.callbackData.latencyExtension = addr result.latencyExtension
  result.callbackData.timerExtension = addr result.timerExtension
  result.callbackData.posixFdExtension = addr result.posixFdExtension
  result.callbackData.threadCheckExtension = addr result.threadCheckExtension
  result.host = ClapHost(
    clapVersion: ClapVersionCurrent,
    hostData: addr result.callbackData,
    name: result.name.cstring,
    vendor: result.vendor.cstring,
    url: result.url.cstring,
    version: result.version.cstring,
    getExtension: hostGetExtension,
    requestRestart: hostRequestRestart,
    requestProcess: hostRequestProcess,
    requestCallback: hostRequestCallback,
  )

proc hostPointer*(bridge: ClapHostBridge): ptr ClapHost {.inline, gcsafe,
    raises: [].} =
  if bridge == nil:
    return nil
  addr bridge.host

proc isMainThread*(bridge: ClapHostBridge): bool {.inline, gcsafe, raises: [].} =
  bridge != nil and hostIsMainThread(addr bridge.host)

proc attachAudioRole*(bridge: ClapHostBridge; role: ptr AudioRoleGuard): bool =
  if bridge == nil or role == nil:
    return false
  let desired = cast[uint64](role)
  let current = bridge.audioRoleAddress.loadAcquire()
  if current != 0'u64 and current != desired:
    return false
  bridge.audioRoleAddress.storeRelease(desired)
  true

proc detachAudioRole*(bridge: ClapHostBridge; role: ptr AudioRoleGuard): bool =
  if bridge == nil or role == nil:
    return false
  let expected = cast[uint64](role)
  if bridge.audioRoleAddress.loadAcquire() != expected:
    return false
  bridge.audioRoleAddress.storeRelease(0'u64)
  true

proc takeRequests*(bridge: ClapHostBridge): uint32 {.gcsafe, raises: [].} =
  if bridge == nil:
    return 0'u32
  bridge.requests.exchangeAcquire(0'u32)

proc tryPopLog*(bridge: ClapHostBridge;
                record: var ClapHostLogRecord): bool {.gcsafe, raises: [].} =
  if bridge == nil:
    return false
  tryPop(addr bridge.logs, record)

proc takeDroppedLogs*(bridge: ClapHostBridge): uint64 {.gcsafe, raises: [].} =
  if bridge == nil:
    return 0'u64
  bridge.droppedLogs.exchangeAcquire(0'u64)

proc takeStateDirty*(bridge: ClapHostBridge): bool {.gcsafe, raises: [].} =
  bridge != nil and bridge.stateDirty.exchangeAcquire(0'u32) != 0'u32

proc takeLatencyChanged*(bridge: ClapHostBridge): bool {.gcsafe, raises: [].} =
  bridge != nil and bridge.latencyChanged.exchangeAcquire(0'u32) != 0'u32
proc restoreRequests*(bridge: ClapHostBridge; requests: uint32) {.gcsafe, raises: [].} =
  if bridge != nil and requests != 0'u32:
    discard bridge.requests.fetchOrRelaxed(requests)

proc takeParamsRescan*(bridge: ClapHostBridge): uint32 {.gcsafe, raises: [].} =
  if bridge == nil: 0'u32 else: bridge.paramsRescan.exchangeAcquire(0'u32)

proc takeAudioPortsRescan*(bridge: ClapHostBridge): uint32 {.gcsafe, raises: [].} =
  if bridge == nil: 0'u32 else: bridge.audioPortsRescan.exchangeAcquire(0'u32)

proc takeNotePortsRescan*(bridge: ClapHostBridge): uint32 {.gcsafe, raises: [].} =
  if bridge == nil: 0'u32 else: bridge.notePortsRescan.exchangeAcquire(0'u32)

proc processWakePointer*(bridge: ClapHostBridge): ptr RtAtomicU32 {.inline,
    gcsafe, raises: [].} =
  if bridge == nil:
    return nil
  cast[ptr RtAtomicU32](addr bridge.processWake)

proc flushWakePointer*(bridge: ClapHostBridge): ptr RtAtomicU32 {.inline,
    gcsafe, raises: [].} =
  if bridge == nil:
    return nil
  cast[ptr RtAtomicU32](addr bridge.flushWake)

proc logMessage*(record: ClapHostLogRecord): string =
  var length = int(record.length)
  if length > HostLogMessageBytes:
    length = HostLogMessageBytes
  result = newString(length)
  if length > 0:
    copyMem(addr result[0], unsafeAddr record.message[0], length)
