import std/unittest

import pluginhost/clap/[ffi, host_bridge]
import pluginhost/platform/linux/dynlib
import ../fixtures/ffi/fixture_api

when not defined(nimAllocStats):
  {.error: "host bridge safety tests require -d:nimAllocStats".}

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
  let unsupported = host.getExtension(host, "clap.unsupported")
  if log == nil or log.log == nil or threadCheck == nil or
      threadCheck.isMainThread == nil or threadCheck.isAudioThread == nil or
      unsupported != nil:
    return -3
  if threadCheck.isMainThread(host) or threadCheck.isAudioThread(host):
    return -4

  host.requestRestart(host)
  host.requestProcess(host)
  host.requestCallback(host)
  log.log(host, ClapLogInfo, "foreign allocation-free callback")
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

    let bridge = newClapHostBridge()
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
      (ClapRequestRestart or ClapRequestProcess or ClapRequestCallback)
    var record: ClapHostLogRecord
    check bridge.tryPopLog(record)
    check record.logMessage == "foreign allocation-free callback"
    check not bridge.tryPopLog(record)

    check library.close().isOk
