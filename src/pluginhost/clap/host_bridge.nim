import std/concurrency/atomics
import std/[posix, typetraits]

import ../version
import ./ffi

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
    sequence: Atomic[uint64]
    record: ClapHostLogRecord

  HostLogQueue = object
    enqueuePosition: Atomic[uint64]
    dequeuePosition: Atomic[uint64]
    cells: array[HostLogQueueCapacity, HostLogCell]

  HostCallbackData = object
    requests: ptr Atomic[uint32]
    logs: ptr HostLogQueue
    droppedLogs: ptr Atomic[uint64]
    logExtension: ptr ClapHostLog
    threadCheckExtension: ptr ClapHostThreadCheck
    mainThread: Pthread

  ClapHostBridge* = ref object
    host: ClapHost
    logExtension: ClapHostLog
    threadCheckExtension: ClapHostThreadCheck
    callbackData: HostCallbackData
    requests: Atomic[uint32]
    droppedLogs: Atomic[uint64]
    logs: HostLogQueue
    name: string
    vendor: string
    url: string
    version: string

static:
  doAssert supportsCopyMem(ClapHostLogRecord)

{.push checks: off, stackTrace: off, lineTrace: off.}
proc initLogQueue(queue: var HostLogQueue) {.gcsafe, raises: [].} =
  queue.enqueuePosition.store(0'u64, moRelaxed)
  queue.dequeuePosition.store(0'u64, moRelaxed)
  for index in 0 ..< HostLogQueueCapacity:
    queue.cells[index].sequence.store(uint64(index), moRelaxed)

proc cstringEquals(left, right: cstring): bool {.
    exportc: "pluginhost_clap_host_cstring_equals", inline, gcsafe, raises: [].} =
  if left == nil or right == nil:
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

  var position = queue.enqueuePosition.load(moRelaxed)
  while true:
    let cell = addr queue.cells[int(position mod uint64(HostLogQueueCapacity))]
    let sequence = cell.sequence.load(moAcquire)
    let difference = cast[int64](sequence - position)
    if difference == 0:
      var expected = position
      if queue.enqueuePosition.compareExchange(
          expected, position + 1'u64, moRelaxed, moRelaxed):
        break
      position = expected
    elif difference < 0:
      return false
    else:
      position = queue.enqueuePosition.load(moRelaxed)

  let cell = addr queue.cells[int(position mod uint64(HostLogQueueCapacity))]
  cell.record = record[]
  cell.sequence.store(position + 1'u64, moRelease)
  true

proc tryPop(queue: ptr HostLogQueue;
            record: var ClapHostLogRecord): bool {.gcsafe, raises: [].} =
  if queue == nil:
    return false

  let position = queue.dequeuePosition.load(moRelaxed)
  let cell = addr queue.cells[int(position mod uint64(HostLogQueueCapacity))]
  let sequence = cell.sequence.load(moAcquire)
  if cast[int64](sequence - (position + 1'u64)) != 0:
    return false

  record = cell.record
  cell.sequence.store(position + uint64(HostLogQueueCapacity), moRelease)
  queue.dequeuePosition.store(position + 1'u64, moRelaxed)
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
  if cstringEquals(extensionId, ClapExtThreadCheck.cstring):
    return cast[pointer](data.threadCheckExtension)
  nil

proc recordRequest(host: ptr ClapHost; request: uint32) {.
    exportc: "pluginhost_clap_host_record_request", gcsafe, raises: [].} =
  let data = callbackData(host)
  if data != nil and data.requests != nil:
    discard data.requests[].fetchOr(request, moRelaxed)

proc hostRequestRestart(host: ptr ClapHost) {.
    exportc: "pluginhost_clap_host_request_restart", cdecl, gcsafe, raises: [].} =
  recordRequest(host, ClapRequestRestart)

proc hostRequestProcess(host: ptr ClapHost) {.
    exportc: "pluginhost_clap_host_request_process", cdecl, gcsafe, raises: [].} =
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
  if message != nil:
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
    discard data.droppedLogs[].fetchAdd(1'u64, moRelaxed)

proc hostIsMainThread(host: ptr ClapHost): bool {.
    exportc: "pluginhost_clap_host_is_main_thread", cdecl, gcsafe, raises: [].} =
  let data = callbackData(host)
  data != nil and pthread_equal(pthread_self(), data.mainThread) != 0

proc hostIsAudioThread(host: ptr ClapHost): bool {.
    exportc: "pluginhost_clap_host_is_audio_thread", cdecl, gcsafe, raises: [].} =
  ## No symbolic audio role exists before the processing increment.
  discard host
  false

{.pop.}

proc newClapHostBridge*(): ClapHostBridge =
  new(result)
  result.name = ProductName
  result.vendor = ProductName
  result.url = ""
  result.version = Version
  result.requests.store(0'u32, moRelaxed)
  result.droppedLogs.store(0'u64, moRelaxed)
  result.logs.initLogQueue()
  result.callbackData.requests = addr result.requests
  result.callbackData.logs = addr result.logs
  result.callbackData.droppedLogs = addr result.droppedLogs
  result.callbackData.mainThread = pthread_self()
  result.logExtension = ClapHostLog(log: hostLog)
  result.threadCheckExtension = ClapHostThreadCheck(
    isMainThread: hostIsMainThread,
    isAudioThread: hostIsAudioThread,
  )
  result.callbackData.logExtension = addr result.logExtension
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

proc takeRequests*(bridge: ClapHostBridge): uint32 {.gcsafe, raises: [].} =
  if bridge == nil:
    return 0'u32
  bridge.requests.exchange(0'u32, moAcquire)

proc tryPopLog*(bridge: ClapHostBridge;
                record: var ClapHostLogRecord): bool {.gcsafe, raises: [].} =
  if bridge == nil:
    return false
  tryPop(addr bridge.logs, record)

proc takeDroppedLogs*(bridge: ClapHostBridge): uint64 {.gcsafe, raises: [].} =
  if bridge == nil:
    return 0'u64
  bridge.droppedLogs.exchange(0'u64, moAcquire)

proc logMessage*(record: ClapHostLogRecord): string =
  var length = int(record.length)
  if length > HostLogMessageBytes:
    length = HostLogMessageBytes
  result = newString(length)
  if length > 0:
    copyMem(addr result[0], unsafeAddr record.message[0], length)
