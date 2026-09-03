import std/unittest

import pluginhost/clap/[ffi, host_bridge, main_thread_services]

type TestMainServices = object
  timerId: uint32
  timerRegistered: bool
  fd: int32
  fdFlags: uint32

proc registerTimer(context: pointer; periodMs: uint32; timerId: ptr uint32): bool {.cdecl, gcsafe, raises: [].} =
  let state = cast[ptr TestMainServices](context)
  if state == nil or timerId == nil or periodMs != 34'u32:
    return false
  state.timerId = 17'u32
  state.timerRegistered = true
  timerId[] = state.timerId
  true

proc unregisterTimer(context: pointer; timerId: uint32): bool {.cdecl, gcsafe, raises: [].} =
  let state = cast[ptr TestMainServices](context)
  if state == nil or not state.timerRegistered or timerId != state.timerId:
    return false
  state.timerRegistered = false
  true

proc registerFd(context: pointer; fd: int32; flags: uint32): bool {.cdecl, gcsafe, raises: [].} =
  let state = cast[ptr TestMainServices](context)
  if state == nil or fd < 0:
    return false
  state.fd = fd
  state.fdFlags = flags
  true

proc modifyFd(context: pointer; fd: int32; flags: uint32): bool {.cdecl, gcsafe, raises: [].} =
  let state = cast[ptr TestMainServices](context)
  if state == nil or fd != state.fd:
    return false
  state.fdFlags = flags
  true

proc unregisterFd(context: pointer; fd: int32): bool {.cdecl, gcsafe, raises: [].} =
  let state = cast[ptr TestMainServices](context)
  if state == nil or fd != state.fd:
    return false
  state.fd = -1
  true

suite "CLAP host bridge":
  test "host identity and supported extensions have stable storage":
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer

    check host != nil
    check host.clapVersion == ClapVersionCurrent
    check $host.name == "pluginhost"
    check $host.vendor == "pluginhost"
    check $host.version == "0.0.10-dev"
    check host.getExtension(host, ClapExtLog.cstring) != nil
    check host.getExtension(host, ClapExtThreadCheck.cstring) != nil
    check host.getExtension(host, ClapExtState.cstring) != nil
    check host.getExtension(host, ClapExtLatency.cstring) != nil
    check host.getExtension(host, ClapExtParams.cstring) != nil
    check host.getExtension(host, ClapExtAudioPorts.cstring) != nil
    check host.getExtension(host, ClapExtNotePorts.cstring) != nil
    check host.getExtension(host, ClapExtTimerSupport.cstring) == nil
    check host.getExtension(host, ClapExtPosixFdSupport.cstring) == nil
    check host.getExtension(host, "clap.unsupported") == nil
    check host.getExtension(host, ClapExtLog.cstring) ==
      host.getExtension(host, ClapExtLog.cstring)
    check host.requestRestart != nil
    check host.requestProcess != nil
    check host.requestCallback != nil

    let headless = newClapHostBridge(guiEnabled = false)
    check headless.hostPointer.getExtension(
      headless.hostPointer, ClapExtGui.cstring) == nil
    let guiBridge = newClapHostBridge(guiEnabled = true)
    let guiHost = guiBridge.hostPointer
    let gui = cast[ptr ClapHostGui](
      guiHost.getExtension(guiHost, ClapExtGui.cstring))
    check gui != nil
    check gui.resizeHintsChanged != nil
    check gui.requestResize != nil
    check gui.requestShow != nil
    check gui.requestHide != nil
    check gui.closed != nil

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

  test "GUI requests are bounded, packed, and coalesced":
    let bridge = newClapHostBridge(guiEnabled = true)
    let host = bridge.hostPointer
    let gui = cast[ptr ClapHostGui](
      host.getExtension(host, ClapExtGui.cstring))
    check gui.requestResize(host, 640, 480)
    check gui.requestShow(host)
    gui.resizeHintsChanged(host)
    gui.closed(host, true)
    gui.closed(host, false)
    var requests = bridge.takeGuiRequests()
    check requests.show
    check requests.resize
    check requests.resizeHints
    check requests.closed
    check requests.wasDestroyed
    check requests.width == 640'u32
    check requests.height == 480'u32
    check not bridge.takeGuiRequests().closed
    gui.closed(host, false)
    requests = bridge.takeGuiRequests()
    check requests.closed
    check not requests.wasDestroyed
    check not gui.requestResize(host, 0, 480)

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

  test "dirty and latency notifications coalesce on the main thread":
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer
    let state = cast[ptr ClapHostState](
      host.getExtension(host, ClapExtState.cstring))
    let latency = cast[ptr ClapHostLatency](
      host.getExtension(host, ClapExtLatency.cstring))

    state.markDirty(host)
    state.markDirty(host)
    latency.changed(host)
    latency.changed(host)
    check bridge.takeStateDirty()
    check not bridge.takeStateDirty()
    check bridge.takeLatencyChanged()
    check not bridge.takeLatencyChanged()

  test "parameter and port rescan callbacks coalesce valid main-thread requests":
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer
    let params = cast[ptr ClapHostParams](
      host.getExtension(host, ClapExtParams.cstring))
    let audio = cast[ptr ClapHostAudioPorts](
      host.getExtension(host, ClapExtAudioPorts.cstring))
    let notes = cast[ptr ClapHostNotePorts](
      host.getExtension(host, ClapExtNotePorts.cstring))
    require params != nil and audio != nil and notes != nil
    check audio.isRescanFlagSupported(host, ClapAudioPortsRescanNames)
    check not audio.isRescanFlagSupported(host, 1'u32 shl 31)
    check notes.supportedDialects(host) == (ClapNoteDialectClap or
      ClapNoteDialectMidi or ClapNoteDialectMidiMpe)
    params.rescan(host, ClapParamRescanValues)
    params.clear(host, 7'u32, ClapParamClearAll)
    params.requestFlush(host)
    audio.rescan(host, ClapAudioPortsRescanNames)
    notes.rescan(host, ClapNotePortsRescanNames)
    check bridge.takeParamsRescan() == ClapParamRescanValues
    check bridge.takeAudioPortsRescan() == ClapAudioPortsRescanNames
    check bridge.takeNotePortsRescan() == ClapNotePortsRescanNames
    check bridge.takeRequests() == ClapRequestFlush

  test "timer and FD services are advertised only with a complete stable table":
    var state = TestMainServices(fd: -1)
    var services = ClapMainThreadServices(
      context: addr state, registerTimer: registerTimer,
      unregisterTimer: unregisterTimer, registerFd: registerFd,
      modifyFd: modifyFd, unregisterFd: unregisterFd)
    let bridge = newClapHostBridge(addr services)
    let host = bridge.hostPointer
    let timers = cast[ptr ClapHostTimerSupport](
      host.getExtension(host, ClapExtTimerSupport.cstring))
    let fds = cast[ptr ClapHostPosixFdSupport](
      host.getExtension(host, ClapExtPosixFdSupport.cstring))
    require timers != nil and fds != nil

    var timerId = ClapInvalidId
    check not timers.registerTimer(host, 0'u32, addr timerId)
    check timers.registerTimer(host, 34'u32, addr timerId)
    check timerId == 17'u32
    check timers.unregisterTimer(host, timerId)
    check not timers.unregisterTimer(host, timerId)

    check not fds.registerFd(host, -1, ClapPosixFdRead)
    check not fds.registerFd(host, 9, 0'u32)
    check fds.registerFd(host, 9, ClapPosixFdRead)
    check fds.modifyFd(host, 9, ClapPosixFdRead or ClapPosixFdWrite)
    check state.fdFlags == (ClapPosixFdRead or ClapPosixFdWrite)
    check fds.unregisterFd(host, 9)
