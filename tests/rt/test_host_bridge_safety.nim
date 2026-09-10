import std/unittest

import pluginhost/clap/[ffi, host_bridge, main_thread_services]
import pluginhost/platform/linux/dynlib
import ../fixtures/ffi/fixture_api

when not defined(nimAllocStats):
  {.error: "host bridge safety tests require -d:nimAllocStats".}

proc rejectTimerRegistration(context: pointer; periodMs: uint32;
                             timerId: ptr cuint): bool {.
    cdecl, gcsafe, raises: [].} =
  discard context
  discard periodMs
  discard timerId
  false

proc rejectTimerUnregistration(context: pointer; timerId: uint32): bool {.
    cdecl, gcsafe, raises: [].} =
  discard context
  discard timerId
  false

proc rejectFdRegistration(context: pointer; fd: int32; flags: uint32): bool {.
    cdecl, gcsafe, raises: [].} =
  discard context
  discard fd
  discard flags
  false

proc rejectFdUnregistration(context: pointer; fd: int32): bool {.
    cdecl, gcsafe, raises: [].} =
  discard context
  discard fd
  false

{.push checks: off, stackTrace: off, lineTrace: off.}
proc pluginhostHostCallbacksProbe(value: int32; context: pointer): int32 {.
    exportc: "pluginhost_host_callbacks_probe", cdecl, gcsafe, raises: [].} =
  discard value
  if context == nil:
    return -1
  let host = cast[ptr ClapHost](context)
  if host.getExtension == nil or host.requestRestart == nil or
      host.requestProcess == nil or host.requestCallback == nil:
    return -2

  let before = getAllocStats()
  let log = cast[ptr ClapHostLog](
    host.getExtension(host, ClapExtLog.cstring))
  let threadCheck = cast[ptr ClapHostThreadCheck](
    host.getExtension(host, ClapExtThreadCheck.cstring))
  let state = cast[ptr ClapHostState](
    host.getExtension(host, ClapExtState.cstring))
  let latency = cast[ptr ClapHostLatency](
    host.getExtension(host, ClapExtLatency.cstring))
  let timer = cast[ptr ClapHostTimerSupport](
    host.getExtension(host, ClapExtTimerSupport.cstring))
  let posixFd = cast[ptr ClapHostPosixFdSupport](
    host.getExtension(host, ClapExtPosixFdSupport.cstring))
  let params = cast[ptr ClapHostParams](
    host.getExtension(host, ClapExtParams.cstring))
  let audioPorts = cast[ptr ClapHostAudioPorts](
    host.getExtension(host, ClapExtAudioPorts.cstring))
  let notePorts = cast[ptr ClapHostNotePorts](
    host.getExtension(host, ClapExtNotePorts.cstring))
  let unsupported = host.getExtension(host, "clap.unsupported")
  if log == nil or log.log == nil or threadCheck == nil or
      threadCheck.isMainThread == nil or threadCheck.isAudioThread == nil or
      state == nil or state.markDirty == nil or latency == nil or
      latency.changed == nil or timer == nil or posixFd == nil or
      timer.registerTimer == nil or timer.unregisterTimer == nil or
      posixFd.registerFd == nil or posixFd.modifyFd == nil or
      posixFd.unregisterFd == nil or params == nil or params.rescan == nil or
      params.clear == nil or params.requestFlush == nil or audioPorts == nil or
      audioPorts.isRescanFlagSupported == nil or audioPorts.rescan == nil or
      notePorts == nil or notePorts.supportedDialects == nil or
      notePorts.rescan == nil or unsupported != nil:
    return -3
  if threadCheck.isMainThread(host) or threadCheck.isAudioThread(host):
    return -4

  host.requestRestart(host)
  host.requestProcess(host)
  host.requestCallback(host)
  log.log(host, ClapLogInfo, "foreign allocation-free callback")
  state.markDirty(host)
  latency.changed(host)
  params.rescan(host, ClapParamRescanAll)
  params.clear(host, 1'u32, ClapParamClearAll)
  params.requestFlush(host)
  if audioPorts.isRescanFlagSupported(host, ClapAudioPortsRescanList):
    return -7
  audioPorts.rescan(host, ClapAudioPortsRescanList)
  if notePorts.supportedDialects(host) != 0'u32:
    return -8
  notePorts.rescan(host, ClapNotePortsRescanAll)
  var timerId = ClapInvalidId
  if timer.registerTimer(host, 34'u32, addr timerId) or
      timer.unregisterTimer(host, 0'u32) or
      posixFd.registerFd(host, 9, ClapPosixFdRead) or
      posixFd.modifyFd(host, 9, ClapPosixFdWrite) or
      posixFd.unregisterFd(host, 9):
    return -6
  let after = getAllocStats()
  if before != after:
    return -5
  0
{.pop.}

suite "CLAP host callback safety":
  test "request and log callbacks allocate nothing at capacity":
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer
    let log = cast[ptr ClapHostLog](
      host.getExtension(host, ClapExtLog.cstring))

    let before = getAllocStats()
    for index in 0 ..< HostLogQueueCapacity + 1:
      host.requestRestart(host)
      host.requestProcess(host)
      host.requestCallback(host)
      log.log(host, ClapLogInfo, "allocation-free callback")
    let after = getAllocStats()

    check before == after
    check bridge.takeDroppedLogs() == 1
    check bridge.takeRequests() ==
      (ClapRequestRestart or ClapRequestProcess or ClapRequestCallback)

  test "all host callbacks are allocation-free on a C-created thread":
    var opened = openDynamicLibrary(fixturePath())
    require opened.isOk
    var library = move(opened.value)
    defer:
      doAssert library.close().isOk
    let threadResult = resolveSymbol[FixtureCallOnThreadProc](
      library, "pluginhost_fixture_call_on_thread")
    require threadResult.isOk

    var serviceContext = 1'u32
    var services = ClapMainThreadServices(
      context: addr serviceContext,
      registerTimer: rejectTimerRegistration,
      unregisterTimer: rejectTimerUnregistration,
      registerFd: rejectFdRegistration,
      modifyFd: rejectFdRegistration,
      unregisterFd: rejectFdUnregistration,
    )
    let bridge = newClapHostBridge(addr services)
    var callbackResult = -1'i32
    var usedForeignThread = 0'i32
    let status = threadResult.value(
      pluginhostHostCallbacksProbe,
      0'i32,
      bridge.hostPointer,
      addr callbackResult,
      addr usedForeignThread,
    )

    check status == 0
    check callbackResult == 0
    check usedForeignThread == 1
    check bridge.takeRequests() ==
      (ClapRequestRestart or ClapRequestProcess or ClapRequestCallback or
       ClapRequestFlush)
    var record: ClapHostLogRecord
    check bridge.tryPopLog(record)
    check record.logMessage == "foreign allocation-free callback"
    check not bridge.tryPopLog(record)
    check not bridge.takeStateDirty()
    check not bridge.takeLatencyChanged()

    check library.close().isOk
