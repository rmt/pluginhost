## VST3 host services for the headless lifecycle stage.
##
## This module owns stable ABI callback storage, bounded host objects, and the
## Linux main-thread run-loop adapter. It contains no CLI or JACK policy.

import std/posix

import ../app/main_reactor
import ../domain/[reactor, result]
import ../rt/atomic_pod
import ./[ffi, messages, uid]

const
  Vst3HostApplicationIid* = "58E595CCDB2D49698B6AAF8C36A664E5"
  Vst3ComponentHandlerIid* = "93A0BEA30BD045DB8E890B0CC1E46AC6"
  Vst3ConnectionPointIid* = "70A4156F6E6E4026989148BFAA60D8D1"
  Vst3PlugInterfaceSupportIid* = "4FB58B9E9EAA4E0FAB361C1CCCB56FEA"
  Vst3RunLoopIid* = "18C3536697764F1A9C5B83857A871389"

  Vst3MaxRunLoopFds* = 256
  Vst3MaxRunLoopTimers* = 256
  Vst3HostNameUnits* = 128
type
  Vst3HostContextState = object
    hostObject: Vst3HostApplicationObject
    supportObject: Vst3SupportObject
    mainThread: Pthread
    runLoopObject: Vst3RunLoopObject
    store*: Vst3ControlObjectStore
    reactor*: ptr MainReactor
    hostName: array[Vst3HostNameUnits, uint16]
    hostReferences: RtAtomicU32
    supportReferences: RtAtomicU32
    runLoopReferences: RtAtomicU32
    wrongThreadCallbacks: RtAtomicU64
    timerRearmFailures: uint32
    closed: bool
    retired: bool
    dispatching: bool
    closeRequested: bool
    fds: seq[Vst3FdRegistration]
    timers: seq[Vst3TimerRegistration]

  Vst3HostContext* = ref Vst3HostContextState

  Vst3HostApplicationObject = object
    iface: Vst3HostApplication
    vtable: Vst3HostApplicationVtbl
    owner: ptr Vst3HostContextState

  Vst3SupportObject = object
    iface: Vst3PlugInterfaceSupport
    vtable: Vst3PlugInterfaceSupportVtbl
    owner: ptr Vst3HostContextState

  Vst3RunLoopObject = object
    iface: Vst3RunLoop
    vtable: Vst3RunLoopVtbl
    owner: ptr Vst3HostContextState

  Vst3FdRegistration = object
    handler: pointer
    fd: int32
    token: ReactorToken

  Vst3TimerRegistration = object
    handler: pointer
    token: ReactorToken
    intervalNanos: int64
var contextRoots: seq[Vst3HostContext]

proc removeContextRoot(context: Vst3HostContext) {.inline.} =
  if context == nil: return
  for index in countdown(contextRoots.high, 0):
    if contextRoots[index] == context:
      contextRoots.delete(index)
      break
proc addReference(value: var RtAtomicU32): uint32 {.inline, gcsafe, raises: [].} =
  value.fetchAddRelaxed(1'u32) + 1'u32

proc releaseReference(value: var RtAtomicU32): uint32 {.inline, gcsafe, raises: [].} =
  var expected = value.loadRelaxed()
  while expected > 0'u32:
    var observed = expected
    if value.compareExchangeRelaxed(observed, expected - 1'u32):
      return expected - 1'u32
    expected = observed
  0'u32

proc referenceCount(value: RtAtomicU32): uint32 {.inline, gcsafe, raises: [].} =
  value.loadAcquire()
const Vst3MaxWrongThreadCallbacks = 65_535'u64

proc incrementWrongThread(counter: ptr RtAtomicU64) {.inline, raises: [].} =
  if counter == nil:
    return
  var expected = counter[].loadRelaxed()
  while expected < Vst3MaxWrongThreadCallbacks:
    var observed = expected
    if counter[].compareExchangeRelaxed(observed, expected + 1'u64):
      break
    expected = observed

proc writeHostName(source: string; target: var array[Vst3HostNameUnits, uint16]) =
  var sourceIndex = 0
  var targetIndex = 0
  while sourceIndex < source.len and targetIndex < target.len - 1:
    let first = uint32(ord(source[sourceIndex]))
    var codepoint = first
    var width = 1
    if first >= 0xC2'u32 and first <= 0xDF'u32 and sourceIndex + 1 < source.len:
      let second = uint32(ord(source[sourceIndex + 1]))
      if second >= 0x80'u32 and second <= 0xBF'u32:
        codepoint = (first and 0x1F'u32) shl 6 or (second and 0x3F'u32)
        width = 2
    elif first >= 0xE0'u32 and first <= 0xEF'u32 and sourceIndex + 2 < source.len:
      let second = uint32(ord(source[sourceIndex + 1]))
      let third = uint32(ord(source[sourceIndex + 2]))
      if second >= 0x80'u32 and second <= 0xBF'u32 and
          third >= 0x80'u32 and third <= 0xBF'u32 and
          not (first == 0xE0'u32 and second < 0xA0'u32) and
          not (first == 0xED'u32 and second >= 0xA0'u32):
        codepoint = (first and 0x0F'u32) shl 12 or
          (second and 0x3F'u32) shl 6 or (third and 0x3F'u32)
        width = 3
    elif first >= 0xF0'u32 and first <= 0xF4'u32 and sourceIndex + 3 < source.len:
      let second = uint32(ord(source[sourceIndex + 1]))
      let third = uint32(ord(source[sourceIndex + 2]))
      let fourth = uint32(ord(source[sourceIndex + 3]))
      if second >= 0x80'u32 and second <= 0xBF'u32 and
          third >= 0x80'u32 and third <= 0xBF'u32 and
          fourth >= 0x80'u32 and fourth <= 0xBF'u32 and
          not (first == 0xF0'u32 and second < 0x90'u32) and
          not (first == 0xF4'u32 and second > 0x8F'u32):
        codepoint = (first and 0x07'u32) shl 18 or
          (second and 0x3F'u32) shl 12 or
          (third and 0x3F'u32) shl 6 or (fourth and 0x3F'u32)
        width = 4
    if width == 1 and first >= 0x80'u32:
      codepoint = 0xFFFD'u32
    if codepoint <= 0xFFFF'u32:
      target[targetIndex] = uint16(codepoint)
      inc targetIndex
    elif targetIndex + 1 < target.len - 1:
      let value = codepoint - 0x10000'u32
      target[targetIndex] = uint16(0xD800'u32 + (value shr 10))
      target[targetIndex + 1] = uint16(0xDC00'u32 + (value and 0x3FF'u32))
      targetIndex += 2
    else:
      break
    sourceIndex += width

proc hostState(thisInterface: pointer): ptr Vst3HostContextState {.inline.} =
  if thisInterface == nil: nil
  else: cast[ptr Vst3HostApplicationObject](thisInterface).owner

proc supportState(thisInterface: pointer): ptr Vst3HostContextState {.inline.} =
  if thisInterface == nil: nil
  else: cast[ptr Vst3SupportObject](thisInterface).owner

proc runLoopState(thisInterface: pointer): ptr Vst3HostContextState {.inline.} =
  if thisInterface == nil: nil
  else: cast[ptr Vst3RunLoopObject](thisInterface).owner

proc isMainThread(context: ptr Vst3HostContextState): bool {.inline, raises: [].} =
  context != nil and pthread_equal(pthread_self(), context.mainThread) != 0


proc uidMatches(iid: ptr Vst3Tuid; text: string): bool {.inline, raises: [].} =
  if iid == nil: return false
  let parsed = parseVst3Uid(text)
  parsed.isOk and parsed.value == iid[]

proc pluginHandlerVtable(handler: pointer): ptr Vst3RunLoopEventHandlerVtbl {.inline.} =
  if handler == nil: nil else: cast[ptr Vst3RunLoopEventHandler](handler).lpVtbl

proc pluginTimerVtable(handler: pointer): ptr Vst3RunLoopTimerHandlerVtbl {.inline.} =
  if handler == nil: nil else: cast[ptr Vst3RunLoopTimerHandler](handler).lpVtbl

proc retainHandler(handler: pointer): bool {.raises: [].} =
  let vtable = pluginHandlerVtable(handler)
  if vtable == nil or vtable.addRef == nil or vtable.release == nil:
    return false
  discard vtable.addRef(handler)
  true

proc releaseHandler(handler: pointer) {.raises: [].} =
  let vtable = pluginHandlerVtable(handler)
  if vtable != nil and vtable.release != nil:
    discard vtable.release(handler)

proc validFdHandler(handler: pointer): bool {.inline.} =
  let vtable = pluginHandlerVtable(handler)
  vtable != nil and vtable.queryInterface != nil and vtable.addRef != nil and
    vtable.release != nil and vtable.onFDIsSet != nil

proc validTimerHandler(handler: pointer): bool {.inline.} =
  let vtable = pluginTimerVtable(handler)
  vtable != nil and vtable.queryInterface != nil and vtable.addRef != nil and
    vtable.release != nil and vtable.onTimer != nil

proc hostQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                        obj: ptr pointer): int32 {.cdecl, raises: [].} =
  let context = hostState(thisInterface)
  if context == nil or context.closed or context.retired or obj == nil:
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = nil
  if uidMatches(iid, Vst3HostApplicationIid) or uidMatches(iid, Vst3FUnknownIid):
    obj[] = addr context.hostObject.iface
    discard addReference(context.hostReferences)
    return Vst3ResultOk
  if uidMatches(iid, Vst3PlugInterfaceSupportIid):
    obj[] = addr context.supportObject.iface
    discard addReference(context.supportReferences)
    return Vst3ResultOk
  if uidMatches(iid, Vst3RunLoopIid):
    obj[] = addr context.runLoopObject.iface
    discard addReference(context.runLoopReferences)
    return Vst3ResultOk
  Vst3NoInterface

proc hostAddRef(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let context = hostState(thisInterface)
  if context == nil or context.closed: return 0'u32
  addReference(context.hostReferences)

proc hostRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let context = hostState(thisInterface)
  if context == nil or context.closed: return 0'u32
  releaseReference(context.hostReferences)

proc hostGetName(thisInterface: pointer; name: ptr Vst3VstString128): int32 {.
    cdecl, raises: [].} =
  let context = hostState(thisInterface)
  if context == nil or context.closed or name == nil: return Vst3ResultFalse
  for index in 0 ..< context.hostName.len:
    name[][index] = context.hostName[index]
  Vst3ResultOk

proc hostCreateInstance(thisInterface: pointer; cid, iid: ptr Vst3Tuid;
                        obj: ptr pointer): int32 {.cdecl, raises: [].} =
  let context = hostState(thisInterface)
  if context == nil or context.closed or context.retired or obj == nil:
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = nil
  if uidMatches(cid, Vst3MessageIid) and uidMatches(iid, Vst3MessageIid):
    let message = newVst3Message(context.store)
    if message == nil: return Vst3ResultFalse
    obj[] = cast[pointer](message.interfacePointer())
    return Vst3ResultOk
  if uidMatches(cid, Vst3AttributeListIid) and uidMatches(iid, Vst3AttributeListIid):
    let attributes = newVst3AttributeList(context.store)
    if attributes == nil: return Vst3ResultFalse
    obj[] = cast[pointer](attributes.interfacePointer())
    return Vst3ResultOk
  Vst3NoInterface

proc supportQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                           obj: ptr pointer): int32 {.cdecl, raises: [].} =
  let context = supportState(thisInterface)
  if context == nil or context.closed or context.retired or obj == nil:
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = nil
  if uidMatches(iid, Vst3FUnknownIid):
    obj[] = addr context.hostObject.iface
    discard addReference(context.hostReferences)
    return Vst3ResultOk
  if uidMatches(iid, Vst3HostApplicationIid):
    obj[] = addr context.hostObject.iface
    discard addReference(context.hostReferences)
    return Vst3ResultOk
  if uidMatches(iid, Vst3PlugInterfaceSupportIid):
    obj[] = addr context.supportObject.iface
    discard addReference(context.supportReferences)
    return Vst3ResultOk
  if uidMatches(iid, Vst3RunLoopIid):
    obj[] = addr context.runLoopObject.iface
    discard addReference(context.runLoopReferences)
    return Vst3ResultOk
  Vst3NoInterface

proc supportAddRef(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let context = supportState(thisInterface)
  if context == nil or context.closed: return 0'u32
  addReference(context.supportReferences)

proc supportRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let context = supportState(thisInterface)
  if context == nil or context.closed: return 0'u32
  releaseReference(context.supportReferences)
proc supportIsPlugInterfaceSupported(thisInterface: pointer;
                                     iid: ptr Vst3Tuid): int32 {.
    cdecl, raises: [].} =
  let context = supportState(thisInterface)
  if context == nil or context.closed or context.retired:
    return Vst3ResultFalse
  if uidMatches(iid, Vst3ConnectionPointIid):
    return Vst3ResultOk
  Vst3ResultFalse

proc runLoopQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                           obj: ptr pointer): int32 {.cdecl, raises: [].} =
  let context = runLoopState(thisInterface)
  if context == nil or context.closed or context.retired or obj == nil:
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = nil
  if uidMatches(iid, Vst3FUnknownIid):
    obj[] = addr context.hostObject.iface
    discard addReference(context.hostReferences)
    return Vst3ResultOk
  if uidMatches(iid, Vst3HostApplicationIid):
    obj[] = addr context.hostObject.iface
    discard addReference(context.hostReferences)
    return Vst3ResultOk
  if uidMatches(iid, Vst3PlugInterfaceSupportIid):
    obj[] = addr context.supportObject.iface
    discard addReference(context.supportReferences)
    return Vst3ResultOk
  if uidMatches(iid, Vst3RunLoopIid):
    obj[] = addr context.runLoopObject.iface
    discard addReference(context.runLoopReferences)
    return Vst3ResultOk
  Vst3NoInterface

proc runLoopAddRef(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let context = runLoopState(thisInterface)
  if context == nil or context.closed: return 0'u32
  addReference(context.runLoopReferences)

proc runLoopRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let context = runLoopState(thisInterface)
  if context == nil or context.closed: return 0'u32
  releaseReference(context.runLoopReferences)

proc hasFd(context: ptr Vst3HostContextState; handler: pointer; fd: int32): bool =
  for registration in context.fds:
    if registration.handler == handler and registration.fd == fd:
      return true
  false

proc hasTimer(context: ptr Vst3HostContextState; handler: pointer): bool =
  for registration in context.timers:
    if registration.handler == handler:
      return true
  false

proc runLoopRegisterEventHandler(thisInterface, handler: pointer;
                                 fd: Vst3FileDescriptor): int32 {.
    cdecl, raises: [].} =
  let context = runLoopState(thisInterface)
  if context == nil or context.closed or context.retired or
      not context.isMainThread() or
      context.reactor == nil or fd < 0 or not validFdHandler(handler) or
      context.fds.len >= Vst3MaxRunLoopFds or context.hasFd(handler, fd) or
      not retainHandler(handler):
    return Vst3ResultFalse
  let registered = context.reactor[].registerFd(fd, {riRead})
  if not registered.isOk:
    releaseHandler(handler)
    return Vst3ResultFalse
  context.fds.add(Vst3FdRegistration(handler: handler, fd: fd,
                                     token: registered.value))
  Vst3ResultOk

proc runLoopUnregisterEventHandler(thisInterface, handler: pointer): int32 {.
    cdecl, raises: [].} =
  let context = runLoopState(thisInterface)
  if context == nil or context.closed or not context.isMainThread() or
      context.reactor == nil or handler == nil:
    return Vst3ResultFalse
  var index = context.fds.high
  var removedAny = false
  var failed = false
  while index >= 0:
    if context.fds[index].handler == handler:
      let removed = context.reactor[].removeFd(context.fds[index].token)
      if removed.isOk:
        releaseHandler(handler)
        context.fds.delete(index)
        removedAny = true
      else:
        failed = true
    dec index
  if failed or not removedAny: Vst3ResultFalse else: Vst3ResultOk

proc runLoopRegisterTimer(thisInterface, handler: pointer;
                          milliseconds: Vst3TimerInterval): int32 {.
    cdecl, raises: [].} =
  let context = runLoopState(thisInterface)
  if context == nil or context.closed or context.retired or
      not context.isMainThread() or
      context.reactor == nil or not validTimerHandler(handler) or
      milliseconds == 0'u64 or context.timers.len >= Vst3MaxRunLoopTimers or
      context.hasTimer(handler) or
      milliseconds > uint64(high(int64) div 1_000_000) or
      not retainHandler(handler):
    return Vst3ResultFalse
  let now = context.reactor[].now()
  if not now.isOk:
    releaseHandler(handler)
    return Vst3ResultFalse
  let interval = int64(milliseconds * 1_000_000'u64)
  if now.value.int64Value > high(int64) - interval:
    releaseHandler(handler)
    return Vst3ResultFalse
  let registered = context.reactor[].registerTimer(
    monotonicNanos(now.value.int64Value + interval))
  if not registered.isOk:
    releaseHandler(handler)
    return Vst3ResultFalse
  context.timers.add(Vst3TimerRegistration(
    handler: handler, token: registered.value, intervalNanos: interval))
  Vst3ResultOk

proc runLoopUnregisterTimer(thisInterface, handler: pointer): int32 {.
    cdecl, raises: [].} =
  let context = runLoopState(thisInterface)
  if context == nil or context.closed or not context.isMainThread() or
      context.reactor == nil or handler == nil:
    return Vst3ResultFalse
  var index = context.timers.high
  var removedAny = false
  var failed = false
  while index >= 0:
    if context.timers[index].handler == handler:
      let removed = context.reactor[].cancelTimer(context.timers[index].token)
      if removed.isOk:
        releaseHandler(handler)
        context.timers.delete(index)
        removedAny = true
      else:
        failed = true
    dec index
  if failed or not removedAny: Vst3ResultFalse else: Vst3ResultOk

proc dispatchRunLoopEvents*(context: Vst3HostContext;
                            events: openArray[ReactorEvent]) {.raises: [].}
proc closeNow(context: Vst3HostContext) {.raises: [].}

proc dispatchRunLoopEvents*(context: Vst3HostContext;
                            events: openArray[ReactorEvent]) {.raises: [].} =
  if context == nil or context[].closed or context[].retired or
      not isMainThread(addr context[]):
    if context != nil and not isMainThread(addr context[]):
      incrementWrongThread(addr context[].wrongThreadCallbacks)
    return
  context[].dispatching = true
  for event in events:
    if context.closed or context.closeRequested:
      break
    if event.kind == rekFd:
      if riRead notin event.interests:
        continue
      var index = 0
      while index < context.fds.len:
        let registration = context.fds[index]
        if registration.token == event.token:
          let handler = registration.handler
          if retainHandler(handler):
            let vtable = pluginHandlerVtable(handler)
            vtable.onFDIsSet(handler, registration.fd)
            releaseHandler(handler)
          break
        inc index
    else:
      var index = 0
      while index < context.timers.len:
        let registration = context.timers[index]
        if registration.token == event.token:
          let handler = registration.handler
          if retainHandler(handler):
            let vtable = pluginTimerVtable(handler)
            vtable.onTimer(handler)
            releaseHandler(handler)
          var stillRegistered = false
          for candidate in context.timers:
            if candidate.token == event.token:
              stillRegistered = true
              break
          if stillRegistered and not context.closeRequested and
              context.reactor != nil:
            let now = context.reactor[].now()
            var rearmed = false
            if now.isOk and registration.intervalNanos <=
                high(int64) - now.value.int64Value:
              rearmed = context.reactor[].rescheduleTimer(
                event.token, monotonicNanos(
                  now.value.int64Value + registration.intervalNanos)).isOk
            if not rearmed:
              inc context.timerRearmFailures
              discard context.reactor[].cancelTimer(event.token)
              for staleIndex in countdown(context.timers.high, 0):
                if context.timers[staleIndex].token == event.token:
                  releaseHandler(context.timers[staleIndex].handler)
                  context.timers.delete(staleIndex)
                  break
          break
        inc index
  context.dispatching = false
  if context.closeRequested:
    closeNow(context)

proc closeNow(context: Vst3HostContext) {.raises: [].} =
  if context == nil or context.closed:
    return
  var failed = false
  if context.reactor == nil and (context.fds.len > 0 or context.timers.len > 0):
    failed = true
  if not failed:
    var index = context.fds.high
    while index >= 0:
      let removed = context.reactor[].removeFd(context.fds[index].token)
      if removed.isOk:
        releaseHandler(context.fds[index].handler)
        context.fds.delete(index)
      else:
        failed = true
      dec index
    index = context.timers.high
    while index >= 0:
      let removed = context.reactor[].cancelTimer(context.timers[index].token)
      if removed.isOk:
        releaseHandler(context.timers[index].handler)
        context.timers.delete(index)
      else:
        failed = true
      dec index
  if failed:
    return
  if context.store.liveObjectCount() > 0 or
      referenceCount(context.hostReferences) > 1'u32 or
      referenceCount(context.supportReferences) > 1'u32 or
      referenceCount(context.runLoopReferences) > 1'u32:
    return
  context.closed = true
  context.store.close()
  context.closeRequested = false
  removeContextRoot(context)

proc hasRetainedObjects*(context: Vst3HostContext): bool {.inline.} =
  context != nil and
    (context.store.liveObjectCount() > 0 or
     referenceCount(context.hostReferences) > 1'u32 or
     referenceCount(context.supportReferences) > 1'u32 or
     referenceCount(context.runLoopReferences) > 1'u32)

proc hasRetainedCallbacks*(context: Vst3HostContext): bool {.inline.} =
  context != nil and (context.fds.len > 0 or context.timers.len > 0)

proc close*(context: Vst3HostContext) {.raises: [].} =
  if context == nil or context.closed:
    return
  if context.dispatching:
    context.closeRequested = true
    return
  closeNow(context)

proc retire*(context: Vst3HostContext): bool {.raises: [].} =
  ## Public process shutdown can outlive plugin-held host references. Remove
  ## all reactor registrations first; only then revoke the borrowed reactor
  ## pointer. The rooted ABI objects remain valid for eventual Release calls.
  if context == nil:
    return true
  context.close()
  if context.dispatching or context.hasRetainedCallbacks():
    return false
  context.retired = true
  context.reactor = nil
  true
proc newVst3HostContext*(reactor: ptr MainReactor = nil;
                         hostName = "pluginhost"): Vst3HostContext =
  new(result)
  result.store = initVst3ControlObjectStore()
  result.reactor = reactor
  result.mainThread = pthread_self()
  result.hostReferences.storeRelaxed(1'u32)
  result.supportReferences.storeRelaxed(1'u32)
  result.runLoopReferences.storeRelaxed(1'u32)
  writeHostName(hostName, result.hostName)
  result.hostObject.owner = addr result[]
  result.hostObject.vtable = Vst3HostApplicationVtbl(
    queryInterface: hostQueryInterface, addRef: hostAddRef,
    release: hostRelease, getName: hostGetName,
    createInstance: hostCreateInstance)
  result.hostObject.iface.lpVtbl = addr result.hostObject.vtable
  result.supportObject.owner = addr result[]
  result.supportObject.vtable = Vst3PlugInterfaceSupportVtbl(
    queryInterface: supportQueryInterface, addRef: supportAddRef,
    release: supportRelease,
    isPlugInterfaceSupported: supportIsPlugInterfaceSupported)
  result.supportObject.iface.lpVtbl = addr result.supportObject.vtable
  result.runLoopObject.owner = addr result[]
  result.runLoopObject.vtable = Vst3RunLoopVtbl(
    queryInterface: runLoopQueryInterface, addRef: runLoopAddRef,
    release: runLoopRelease,
    registerEventHandler: runLoopRegisterEventHandler,
    unregisterEventHandler: runLoopUnregisterEventHandler,
    registerTimer: runLoopRegisterTimer,
    unregisterTimer: runLoopUnregisterTimer)
  result.runLoopObject.iface.lpVtbl = addr result.runLoopObject.vtable
  contextRoots.add(result)

proc hostApplicationPointer*(context: Vst3HostContext): ptr Vst3HostApplication {.inline.} =
  if context == nil: nil else: addr context[].hostObject.iface

proc wrongThreadCallbacks*(context: Vst3HostContext): uint64 {.inline.} =
  if context == nil: 0'u64 else: context.wrongThreadCallbacks.loadAcquire()
proc hostSupportPointer*(context: Vst3HostContext): ptr Vst3PlugInterfaceSupport {.inline.} =
  if context == nil: nil else: addr context[].supportObject.iface

proc runLoopPointer*(context: Vst3HostContext): ptr Vst3RunLoop {.inline.} =
  if context == nil: nil else: addr context[].runLoopObject.iface

proc objectStore*(context: Vst3HostContext): Vst3ControlObjectStore {.inline.} =
  if context == nil: nil else: context.store
proc contextRootCount*(): int {.inline.} =
  contextRoots.len
proc timerRearmFailures*(context: Vst3HostContext): uint32 {.inline.} =
  if context == nil: 0'u32 else: context.timerRearmFailures
