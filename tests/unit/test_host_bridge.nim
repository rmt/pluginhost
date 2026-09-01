import std/unittest

import pluginhost/clap/host_bridge
import pluginhost/clap/ffi

suite "CLAP host bridge":
  test "host identity and supported extensions have stable storage":
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer

    check host != nil
    check host.clapVersion == ClapVersionCurrent
    check $host.name == "pluginhost"
    check $host.vendor == "pluginhost"
    check $host.version == "0.0.7-dev"
    check host.getExtension(host, ClapExtLog.cstring) != nil
    check host.getExtension(host, ClapExtThreadCheck.cstring) != nil
    check host.getExtension(host, "clap.unsupported") == nil
    check host.getExtension(host, ClapExtLog.cstring) ==
      host.getExtension(host, ClapExtLog.cstring)
    check host.requestRestart != nil
    check host.requestProcess != nil
    check host.requestCallback != nil

  test "requests are coalesced and drained atomically":
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer

    host.requestRestart(host)
    host.requestRestart(host)
    host.requestProcess(host)
    host.requestCallback(host)

    let requests = bridge.takeRequests()
    check requests == (ClapRequestRestart or ClapRequestProcess or
      ClapRequestCallback)
    check (requests and ClapRequestRestart) != 0
    check (requests and ClapRequestProcess) != 0
    check (requests and ClapRequestCallback) != 0
    check bridge.takeRequests() == 0

  test "logs are bounded, copied, and recover after overflow":
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer
    let extension = cast[ptr ClapHostLog](
      host.getExtension(host, ClapExtLog.cstring))
    var record: ClapHostLogRecord

    extension.log(host, ClapLogWarning, "hello")
    check bridge.tryPopLog(record)
    check record.severity == ClapLogWarning
    check not record.truncated
    check record.logMessage == "hello"
    check not bridge.tryPopLog(record)

    var oversized = newString(HostLogMessageBytes + 8)
    for index in 0 ..< oversized.len:
      oversized[index] = 'x'
    extension.log(host, ClapLogError, oversized.cstring)
    check bridge.tryPopLog(record)
    check record.length == uint32(HostLogMessageBytes)
    check record.truncated
    check record.logMessage.len == HostLogMessageBytes

    for index in 0 ..< HostLogQueueCapacity:
      extension.log(host, ClapLogInfo, "queued")
    extension.log(host, ClapLogInfo, "dropped")
    check bridge.takeDroppedLogs() == 1

    var popped = 0
    while bridge.tryPopLog(record):
      inc popped
    check popped == HostLogQueueCapacity
    check bridge.takeDroppedLogs() == 0

    extension.log(host, ClapLogInfo, "recovered")
    check bridge.tryPopLog(record)
    check record.logMessage == "recovered"

  test "thread check identifies the bridge creation thread":
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer
    let extension = cast[ptr ClapHostThreadCheck](
      host.getExtension(host, ClapExtThreadCheck.cstring))

    check extension.isMainThread(host)
    check not extension.isAudioThread(host)
