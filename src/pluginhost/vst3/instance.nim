## VST3 component/controller lifecycle and headless host services.
##
## This stage deliberately stops before audio setup. It owns every queried
## interface reference and records initialization/connection edges so failed
## construction follows the VST3 initialize/terminate contract exactly.

import std/[locks, math, posix]
import ../app/main_reactor
import ../domain/[errors, result]
import ../rt/atomic_pod
import ./[editor, ffi, host_context, module, stream, uid, parameter_transport, state_codec]
const
  Vst3ComponentIid* = "E831FF31F2D54301928EBBEE25697802"
  Vst3AudioProcessorIid* = "42043F99B7DA453CA569E79D9AAEC33D"
  Vst3EditControllerIid* = "DCD7BBE37742448DA874AACC979C759E"
  Vst3ConnectionPointIid* = "70A4156F6E6E4026989148BFAA60D8D1"
  Vst3MaxParameterEdits* = 4096
  Vst3MaxWrongThreadNotifications* = 65_535'u64
  Vst3MaxInstanceRoots* = 64

type
  Vst3StateSnapshot* = object
    component*: seq[uint8]
    hasComponent*: bool
    controller*: seq[uint8]
    hasController*: bool

  Vst3ParameterMetadata* = object
    id*: Vst3ParamID
    title*: string
    shortTitle*: string
    units*: string
    stepCount*: int32
    defaultNormalizedValue*: Vst3ParamValue
    unitId*: int32
    flags*: int32

  Vst3BusMetadata* = object
    mediaType*: Vst3MediaType
    direction*: Vst3BusDirection
    channelCount*: int32
    name*: string
    busType*: int32
    flags*: uint32

  Vst3ParameterEditKind* = enum
    vpekBegin
    vpekPerform
    vpekEnd

  Vst3ParameterEdit* = object
    kind*: Vst3ParameterEditKind
    id*: Vst3ParamID
    value*: Vst3ParamValue

  Vst3EditMailbox = object
    lock: Lock
    edits: seq[Vst3ParameterEdit]
    activeGestures: seq[Vst3ParamID]
    restartFlags: uint32
    droppedEdits: uint64

  Vst3InstanceState = object
    module*: Vst3Module
    context*: Vst3HostContext
    component*: ptr Vst3Component
    processor*: ptr Vst3AudioProcessor
    controller*: ptr Vst3EditController
    componentPoint: ptr Vst3ConnectionPoint
    controllerPoint: ptr Vst3ConnectionPoint
    componentInitialized: bool
    controllerInitialized: bool
    controllerCombined: bool
    handlerInstalled: bool
    componentConnected: bool
    controllerConnected: bool
    stateSynchronized: bool
    selectedClassId: string
    stateStreams: seq[Vst3MemoryStream]
    editor: Vst3Editor
    closed: bool
    quarantined: bool
    ownsContext: bool
    mainThread: Pthread
    mailbox: Vst3EditMailbox
    parameterTransport: ptr Vst3ParameterTransport
    wrongThreadNotifications: RtAtomicU64
    activeCallbacks: RtAtomicU32
    closingState: RtAtomicU32
    handlerObject: Vst3HandlerObject
    componentProxy: Vst3ConnectionProxy
    controllerProxy: Vst3ConnectionProxy
    parameters*: seq[Vst3ParameterMetadata]
    buses*: seq[Vst3BusMetadata]

  Vst3HandlerObject = object
    iface: Vst3ComponentHandler
    vtable: Vst3ComponentHandlerVtbl
    owner: ptr Vst3InstanceState
    references: RtAtomicU32

  Vst3ConnectionProxy = object
    iface: Vst3ConnectionPoint
    vtable: Vst3ConnectionPointVtbl
    owner: ptr Vst3InstanceState
    target: pointer
    peer: pointer
    references: RtAtomicU32

  Vst3Instance* = ref Vst3InstanceState

  InstanceRootSlot = object
    value: Vst3Instance
    state: RtAtomicU32

var instanceRootSlots: array[Vst3MaxInstanceRoots, InstanceRootSlot]
var instanceRootCountAtomic: RtAtomicU32
var instanceQuarantineCountAtomic: RtAtomicU32

proc claimInstanceRoot(instance: Vst3Instance): int32 =
  for index in 0 ..< Vst3MaxInstanceRoots:
    var expected = 0'u32
    if instanceRootSlots[index].state.compareExchangeAcquire(expected, 2'u32):
      instanceRootSlots[index].value = instance
      instanceRootSlots[index].state.storeRelease(1'u32)
      discard instanceRootCountAtomic.fetchAddRelaxed(1'u32)
      return int32(index)
  -1

proc removeInstanceRoot(instance: Vst3Instance) {.inline.} =
  if instance == nil: return
  for index in 0 ..< Vst3MaxInstanceRoots:
    if instanceRootSlots[index].state.loadAcquire() == 1'u32 and
        instanceRootSlots[index].value == instance:
      if instance[].quarantined:
        instance[].quarantined = false
        discard instanceQuarantineCountAtomic.fetchSubRelease(1'u32)
      instanceRootSlots[index].state.storeRelease(0'u32)
      instanceRootSlots[index].value = nil
      discard instanceRootCountAtomic.fetchSubRelease(1'u32)
      break

proc quarantineInstanceRoot(instance: Vst3Instance) {.inline.} =
  if instance == nil or instance[].quarantined: return
  instance[].quarantined = true
  discard instanceQuarantineCountAtomic.fetchAddRelaxed(1'u32)
proc retainReference(value: var RtAtomicU32): uint32 {.inline, gcsafe, raises: [].} =
  value.fetchAddRelaxed(1'u32) + 1'u32

proc releaseReference(value: var RtAtomicU32): uint32 {.inline, gcsafe, raises: [].} =
  var expected = value.loadRelaxed()
  while expected > 0'u32:
    var observed = expected
    if value.compareExchangeRelaxed(observed, expected - 1'u32):
      return expected - 1'u32
    expected = observed
  0'u32

proc instanceError(kind: HostErrorKind; message, path: string;
                   detail = ""): HostError =
  var context = "bundle=" & path
  if detail.len > 0: context.add("; " & detail)
  hostError(hsVst3, kind, message, context)

proc stateError(message, path: string; detail = ""): HostError =
  var context = "bundle=" & path
  if detail.len > 0: context.add("; " & detail)
  hostError(hsState, hekState, message, context)
proc pruneDrainedStateTransactions(instance: Vst3Instance) =
  if instance == nil: return
  var index = instance.stateStreams.len
  while index > 0:
    dec index
    if not instance.stateStreams[index].hasRetainedReferences():
      instance.stateStreams.delete(index)

proc finishStateTransaction(instance: Vst3Instance; stream: Vst3MemoryStream) =
  if stream == nil: return
  discard stream.close()
  pruneDrainedStateTransactions(instance)
  if stream.hasRetainedReferences():
    instance.stateStreams.add(stream)

proc uidMatches(iid: ptr Vst3Tuid; text: string): bool {.inline, raises: [].} =
  if iid == nil: return false
  let parsed = parseVst3Uid(text)
  parsed.isOk and parsed.value == iid[]

proc interfaceState(obj: pointer): ptr Vst3FUnknown {.inline.} =
  if obj == nil: nil else: cast[ptr Vst3FUnknown](obj)

proc releaseInterface(obj: pointer) =
  let base = interfaceState(obj)
  if base != nil and base.lpVtbl != nil and base.lpVtbl.release != nil:
    discard base.lpVtbl.release(obj)

proc queryInterface(obj: pointer; iidText: string): Result[pointer] =
  let base = interfaceState(obj)
  var iidResult = parseVst3Uid(iidText)
  if base == nil or base.lpVtbl == nil or base.lpVtbl.queryInterface == nil or
      not iidResult.isOk:
    return failure[pointer](instanceError(
      hekVst3Descriptor, "VST3 object cannot query an interface", "",
      "iid=" & iidText))
  var output: pointer = nil
  let code = base.lpVtbl.queryInterface(obj, addr iidResult.value, addr output)
  if code == Vst3NoInterface:
    return success(pointer(nil))
  if code != Vst3ResultOk or output == nil:
    return failure[pointer](instanceError(
      hekVst3Descriptor, "VST3 interface query failed", "",
      "iid=" & iidText & "; result=" & $code))
  success(output)

proc validComponent(component: ptr Vst3Component): bool =
  component != nil and component.lpVtbl != nil and
    component.lpVtbl.queryInterface != nil and component.lpVtbl.release != nil and
    component.lpVtbl.initialize != nil and component.lpVtbl.terminate != nil and
    component.lpVtbl.getControllerClassId != nil and
    component.lpVtbl.setIoMode != nil and component.lpVtbl.getBusCount != nil and
    component.lpVtbl.getBusInfo != nil and component.lpVtbl.activateBus != nil and
    component.lpVtbl.setActive != nil and component.lpVtbl.setState != nil and
    component.lpVtbl.getState != nil

proc validProcessor(processor: ptr Vst3AudioProcessor): bool =
  processor != nil and processor.lpVtbl != nil and
    processor.lpVtbl.queryInterface != nil and processor.lpVtbl.release != nil and
    processor.lpVtbl.setBusArrangements != nil and
    processor.lpVtbl.setupProcessing != nil and processor.lpVtbl.setProcessing != nil and
    processor.lpVtbl.getLatencySamples != nil and
    processor.lpVtbl.process != nil

proc validController(controller: ptr Vst3EditController): bool =
  controller != nil and controller.lpVtbl != nil and
    controller.lpVtbl.queryInterface != nil and controller.lpVtbl.addRef != nil and
    controller.lpVtbl.release != nil and controller.lpVtbl.initialize != nil and
    controller.lpVtbl.terminate != nil and controller.lpVtbl.setComponentState != nil and
    controller.lpVtbl.setState != nil and controller.lpVtbl.getState != nil and
    controller.lpVtbl.getParameterCount != nil and
    controller.lpVtbl.getParameterInfo != nil and
    controller.lpVtbl.setComponentHandler != nil

proc validConnectionPoint(point: ptr Vst3ConnectionPoint): bool =
  point != nil and point.lpVtbl != nil and
    point.lpVtbl.queryInterface != nil and point.lpVtbl.addRef != nil and
    point.lpVtbl.release != nil and point.lpVtbl.connect != nil and
    point.lpVtbl.disconnect != nil and point.lpVtbl.notify != nil

proc activeGestureIndex(mailbox: ptr Vst3EditMailbox; id: Vst3ParamID): int =
  for index, activeId in mailbox.activeGestures:
    if activeId == id:
      return index
  -1

proc mailboxPush(mailbox: ptr Vst3EditMailbox; edit: Vst3ParameterEdit): bool {.
    raises: [].} =
  acquire(mailbox.lock)
  let active = mailbox.activeGestureIndex(edit.id)
  case edit.kind
  of vpekBegin:
    if active >= 0 or mailbox.activeGestures.len >= Vst3MaxParameterEdits:
      inc mailbox.droppedEdits
      release(mailbox.lock)
      return false
    mailbox.activeGestures.add(edit.id)
  of vpekPerform:
    if active < 0:
      inc mailbox.droppedEdits
      release(mailbox.lock)
      return false
  of vpekEnd:
    if active < 0:
      inc mailbox.droppedEdits
      release(mailbox.lock)
      return false
  if mailbox.edits.len >= Vst3MaxParameterEdits:
    if edit.kind == vpekBegin:
      mailbox.activeGestures.delete(mailbox.activeGestures.high)
    inc mailbox.droppedEdits
    release(mailbox.lock)
    return false
  mailbox.edits.add(edit)
  if edit.kind == vpekEnd:
    mailbox.activeGestures.delete(active)
  release(mailbox.lock)
  true

proc handlerState(thisInterface: pointer): ptr Vst3HandlerObject {.inline.} =
  cast[ptr Vst3HandlerObject](thisInterface)

proc handlerQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                           obj: ptr pointer): int32 {.cdecl, raises: [].} =
  let handler = handlerState(thisInterface)
  if handler == nil or obj == nil or
      (not uidMatches(iid, Vst3ComponentHandlerIid) and
       not uidMatches(iid, Vst3FUnknownIid)):
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = thisInterface
  discard retainReference(handler.references)
  Vst3ResultOk

proc handlerAddRef(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let handler = handlerState(thisInterface)
  if handler == nil: return 0'u32
  retainReference(handler.references)

proc handlerRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let handler = handlerState(thisInterface)
  if handler == nil: return 0'u32
  releaseReference(handler.references)

proc incrementWrongThread(counter: ptr RtAtomicU64) {.inline, raises: [].} =
  if counter == nil:
    return
  var expected = counter[].loadRelaxed()
  while expected < Vst3MaxWrongThreadNotifications:
    var observed = expected
    if counter[].compareExchangeRelaxed(observed, expected + 1'u64):
      break
    expected = observed

proc handlerOnMain(handler: ptr Vst3HandlerObject): bool {.inline, raises: [].} =
  handler != nil and handler.owner != nil and
    pthread_equal(pthread_self(), handler.owner[].mainThread) != 0
proc queueParameterEdit(owner: ptr Vst3InstanceState;
                        kind: Vst3ParameterEditKind; id: Vst3ParamID;
                        value: Vst3ParamValue): bool {.inline, gcsafe, raises: [].} =
  if owner == nil:
    return false
  if owner.parameterTransport != nil:
    let transportKind = case kind
      of vpekBegin: v3pekBegin
      of vpekPerform: v3pekPerform
      of vpekEnd: v3pekEnd
    return enqueueVst3ParameterEdit(owner.parameterTransport,
      Vst3ParameterEditRecord(kind: transportKind, id: id, value: value))
  mailboxPush(addr owner.mailbox,
    Vst3ParameterEdit(kind: kind, id: id, value: value))
proc enterCallback(owner: ptr Vst3InstanceState): bool {.inline, gcsafe, raises: [].} =
  if owner == nil:
    return false
  var expected = owner.activeCallbacks.loadAcquire()
  while true:
    if owner.closingState.loadAcquire() != 0'u32:
      return false
    var observed = expected
    if owner.activeCallbacks.compareExchangeAcquire(observed, expected + 1'u32):
      if owner.closingState.loadAcquire() != 0'u32:
        discard owner.activeCallbacks.fetchSubRelease(1'u32)
        return false
      return true
    expected = observed

proc leaveCallback(owner: ptr Vst3InstanceState) {.inline, gcsafe, raises: [].} =
  if owner != nil:
    discard owner.activeCallbacks.fetchSubRelease(1'u32)

proc handlerBeginEdit(thisInterface: pointer; id: Vst3ParamID): int32 {.
    cdecl, raises: [].} =
  let handler = handlerState(thisInterface)
  if handler == nil or handler.owner == nil or
      not enterCallback(handler.owner):
    return Vst3ResultFalse
  defer: leaveCallback(handler.owner)
  if not handler.handlerOnMain():
    incrementWrongThread(addr handler.owner[].wrongThreadNotifications)
    return Vst3ResultFalse
  if not queueParameterEdit(handler.owner, vpekBegin, id, 0.0):
    return Vst3ResultFalse
  Vst3ResultOk

proc handlerPerformEdit(thisInterface: pointer; id: Vst3ParamID;
                       value: Vst3ParamValue): int32 {.cdecl, raises: [].} =
  let handler = handlerState(thisInterface)
  if handler == nil or handler.owner == nil or
      not enterCallback(handler.owner):
    return Vst3ResultFalse
  defer: leaveCallback(handler.owner)
  if not handler.handlerOnMain():
    incrementWrongThread(addr handler.owner[].wrongThreadNotifications)
    return Vst3ResultFalse
  if classify(value) in {fcNan, fcInf, fcNegInf} or value < 0.0 or value > 1.0:
    return Vst3ResultFalse
  if not queueParameterEdit(handler.owner, vpekPerform, id, value):
    return Vst3ResultFalse
  Vst3ResultOk

proc handlerEndEdit(thisInterface: pointer; id: Vst3ParamID): int32 {.
    cdecl, raises: [].} =
  let handler = handlerState(thisInterface)
  if handler == nil or handler.owner == nil or
      not enterCallback(handler.owner):
    return Vst3ResultFalse
  defer: leaveCallback(handler.owner)
  if not handler.handlerOnMain():
    incrementWrongThread(addr handler.owner[].wrongThreadNotifications)
    return Vst3ResultFalse
  if not queueParameterEdit(handler.owner, vpekEnd, id, 0.0):
    return Vst3ResultFalse
  Vst3ResultOk

proc handlerRestartComponent(thisInterface: pointer; flags: int32): int32 {.
    cdecl, raises: [].} =
  let handler = handlerState(thisInterface)
  if handler == nil or handler.owner == nil or flags < 0 or
      (flags and not Vst3RestartAllKnown) != 0 or
      not enterCallback(handler.owner):
    return Vst3ResultFalse
  defer: leaveCallback(handler.owner)
  if not handler.handlerOnMain():
    incrementWrongThread(addr handler.owner[].wrongThreadNotifications)
    return Vst3ResultFalse
  acquire(handler.owner[].mailbox.lock)
  handler.owner[].mailbox.restartFlags =
    handler.owner[].mailbox.restartFlags or uint32(flags)
  release(handler.owner[].mailbox.lock)
  Vst3ResultOk

proc proxyState(thisInterface: pointer): ptr Vst3ConnectionProxy {.inline.} =
  cast[ptr Vst3ConnectionProxy](thisInterface)

proc proxyQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                         obj: ptr pointer): int32 {.cdecl, raises: [].} =
  let proxy = proxyState(thisInterface)
  if proxy == nil or obj == nil or
      (not uidMatches(iid, Vst3ConnectionPointIid) and
       not uidMatches(iid, Vst3FUnknownIid)):
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = thisInterface
  discard retainReference(proxy.references)
  Vst3ResultOk

proc proxyAddRef(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let proxy = proxyState(thisInterface)
  if proxy == nil: return 0'u32
  retainReference(proxy.references)

proc proxyRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let proxy = proxyState(thisInterface)
  if proxy == nil: return 0'u32
  releaseReference(proxy.references)

proc proxyConnect(thisInterface, other: pointer): int32 {.cdecl, raises: [].} =
  let proxy = proxyState(thisInterface)
  if proxy == nil or other == nil: return Vst3ResultFalse
  proxy.peer = other
  Vst3ResultOk

proc proxyDisconnect(thisInterface, other: pointer): int32 {.cdecl, raises: [].} =
  let proxy = proxyState(thisInterface)
  if proxy == nil or proxy.peer != other: return Vst3ResultFalse
  proxy.peer = nil
  Vst3ResultOk

proc proxyNotify(thisInterface, message: pointer): int32 {.cdecl, raises: [].} =
  let proxy = proxyState(thisInterface)
  if proxy == nil or proxy.owner == nil or
      not enterCallback(proxy.owner):
    return Vst3ResultFalse
  defer: leaveCallback(proxy.owner)
  if pthread_equal(pthread_self(), proxy.owner[].mainThread) == 0:
    incrementWrongThread(addr proxy.owner[].wrongThreadNotifications)
    return Vst3ResultFalse
  if message == nil:
    return Vst3ResultFalse
  let target = cast[ptr Vst3ConnectionPoint](proxy.target)
  if target == nil or target.lpVtbl == nil or target.lpVtbl.notify == nil:
    return Vst3ResultFalse
  let code = target.lpVtbl.notify(proxy.target, message)
  if code == Vst3ResultOk: Vst3ResultOk else: Vst3ResultFalse

proc initHandler(instance: Vst3Instance) =
  instance.handlerObject.owner = addr instance[]
  instance.handlerObject.references.storeRelaxed(1'u32)
  instance.handlerObject.vtable = Vst3ComponentHandlerVtbl(
    queryInterface: handlerQueryInterface, addRef: handlerAddRef,
    release: handlerRelease, beginEdit: handlerBeginEdit,
    performEdit: handlerPerformEdit, endEdit: handlerEndEdit,
    restartComponent: handlerRestartComponent)
  instance.handlerObject.iface.lpVtbl = addr instance.handlerObject.vtable

proc initProxy(proxy: var Vst3ConnectionProxy; owner: ptr Vst3InstanceState) =
  proxy.owner = owner
  proxy.references.storeRelaxed(1'u32)
  proxy.vtable = Vst3ConnectionPointVtbl(
    queryInterface: proxyQueryInterface, addRef: proxyAddRef,
    release: proxyRelease, connect: proxyConnect,
    disconnect: proxyDisconnect, notify: proxyNotify)
  proxy.iface.lpVtbl = addr proxy.vtable

proc appendUtf8(output: var string; codepoint: uint32) {.inline.} =
  if codepoint <= 0x7F'u32:
    output.add(char(codepoint))
  elif codepoint <= 0x7FF'u32:
    output.add(char(0xC0'u32 or (codepoint shr 6)))
    output.add(char(0x80'u32 or (codepoint and 0x3F'u32)))
  elif codepoint <= 0xFFFF'u32:
    output.add(char(0xE0'u32 or (codepoint shr 12)))
    output.add(char(0x80'u32 or ((codepoint shr 6) and 0x3F'u32)))
    output.add(char(0x80'u32 or (codepoint and 0x3F'u32)))
  else:
    output.add(char(0xF0'u32 or (codepoint shr 18)))
    output.add(char(0x80'u32 or ((codepoint shr 12) and 0x3F'u32)))
    output.add(char(0x80'u32 or ((codepoint shr 6) and 0x3F'u32)))
    output.add(char(0x80'u32 or (codepoint and 0x3F'u32)))

proc copyUtf16Field(value: Vst3VstString128): Result[string] =
  var output = newStringOfCap(value.len)
  var index = 0
  while index < value.len and value[index] != 0'u16:
    let unit = uint32(value[index])
    var codepoint = unit
    if unit >= 0xD800'u32 and unit <= 0xDBFF'u32:
      if index + 1 >= value.len or value[index + 1] < 0xDC00'u16 or
          value[index + 1] > 0xDFFF'u16:
        return failure[string](hostError(hsVst3, hekVst3Descriptor,
          "VST3 metadata contains malformed UTF-16"))
      codepoint = 0x10000'u32 + ((unit - 0xD800'u32) shl 10) +
        (uint32(value[index + 1]) - 0xDC00'u32)
      inc index
    elif unit >= 0xDC00'u32 and unit <= 0xDFFF'u32:
      return failure[string](hostError(hsVst3, hekVst3Descriptor,
        "VST3 metadata contains malformed UTF-16"))
    appendUtf8(output, codepoint)
    inc index
  if index == value.len:
    return failure[string](hostError(hsVst3, hekVst3Descriptor,
      "VST3 metadata is not NUL terminated"))
  success(move(output))

proc addMetadataBytes(total: var uint64; values: openArray[string]): bool =
  for value in values:
    if total > uint64(Vst3MaxMetadataBytes) - uint64(value.len):
      return false
    total += uint64(value.len)
  true

proc collectBusMetadata(instance: Vst3Instance): Result[seq[Vst3BusMetadata]] =
  var buses: seq[Vst3BusMetadata]
  var totalBytes = 0'u64
  for mediaType in [Vst3MediaAudio, Vst3MediaEvent]:
    for direction in [Vst3DirectionInput, Vst3DirectionOutput]:
      let count = instance.component.lpVtbl.getBusCount(
        cast[pointer](instance.component), mediaType, direction)
      if count < 0 or count > Vst3MaxBusCount:
        return failure[seq[Vst3BusMetadata]](instanceError(hekVst3Descriptor,
          "VST3 bus count is outside the host bound", instance.module.bundlePath,
          "media=" & $mediaType & "; direction=" & $direction &
          "; count=" & $count))
      for index in 0 ..< count:
        var info: Vst3BusInfo
        if instance.component.lpVtbl.getBusInfo(
            cast[pointer](instance.component), mediaType, direction, index,
            addr info) != Vst3ResultOk:
          return failure[seq[Vst3BusMetadata]](instanceError(hekVst3Descriptor,
            "VST3 bus metadata query failed", instance.module.bundlePath,
            "media=" & $mediaType & "; direction=" & $direction &
            "; index=" & $index))
        if info.mediaType != mediaType or info.direction != direction or
            info.channelCount < 0 or info.channelCount > Vst3MaxBusChannels or
            (info.busType != Vst3BusTypeMain and info.busType != Vst3BusTypeAux):
          return failure[seq[Vst3BusMetadata]](instanceError(hekVst3Descriptor,
            "VST3 bus metadata is invalid", instance.module.bundlePath,
            "media=" & $mediaType & "; direction=" & $direction &
            "; index=" & $index))
        var name = copyUtf16Field(info.name)
        if not name.isOk:
          return failure[seq[Vst3BusMetadata]](move(name.error))
        if not addMetadataBytes(totalBytes, [name.value]):
          return failure[seq[Vst3BusMetadata]](instanceError(hekVst3Descriptor,
            "VST3 bus metadata text exceeds the host bound",
            instance.module.bundlePath, "index=" & $index))
        buses.add(Vst3BusMetadata(
          mediaType: info.mediaType, direction: info.direction,
          channelCount: info.channelCount, name: name.value,
          busType: info.busType, flags: info.flags))
  success(move(buses))

proc collectParameterMetadata(instance: Vst3Instance):
    Result[seq[Vst3ParameterMetadata]] =
  var parameters: seq[Vst3ParameterMetadata]
  if instance.controller == nil:
    return success(move(parameters))
  let count = instance.controller.lpVtbl.getParameterCount(
    cast[pointer](instance.controller))
  if count < 0 or count > Vst3MaxParameterCount:
    return failure[seq[Vst3ParameterMetadata]](instanceError(hekVst3Descriptor,
      "VST3 parameter count is outside the host bound", instance.module.bundlePath,
      "count=" & $count))
  var totalBytes = 0'u64
  for index in 0 ..< count:
    var info: Vst3ParameterInfo
    if instance.controller.lpVtbl.getParameterInfo(
        cast[pointer](instance.controller), index, addr info) != Vst3ResultOk:
      return failure[seq[Vst3ParameterMetadata]](instanceError(hekVst3Descriptor,
        "VST3 parameter metadata query failed", instance.module.bundlePath,
        "index=" & $index))
    if info.stepCount < 0 or classify(info.defaultNormalizedValue) in
        {fcNan, fcInf, fcNegInf} or info.defaultNormalizedValue < 0.0 or
        info.defaultNormalizedValue > 1.0:
      return failure[seq[Vst3ParameterMetadata]](instanceError(hekVst3Descriptor,
        "VST3 parameter metadata is invalid", instance.module.bundlePath,
        "index=" & $index))
    for parameter in parameters:
      if parameter.id == info.id:
        return failure[seq[Vst3ParameterMetadata]](instanceError(hekVst3Descriptor,
          "VST3 parameter metadata contains duplicate IDs",
          instance.module.bundlePath, "id=" & $info.id))
    var title = copyUtf16Field(info.title)
    var shortTitle = copyUtf16Field(info.shortTitle)
    var units = copyUtf16Field(info.units)
    if not title.isOk:
      return failure[seq[Vst3ParameterMetadata]](move(title.error))
    if not shortTitle.isOk:
      return failure[seq[Vst3ParameterMetadata]](move(shortTitle.error))
    if not units.isOk:
      return failure[seq[Vst3ParameterMetadata]](move(units.error))
    if not addMetadataBytes(totalBytes, [title.value, shortTitle.value, units.value]):
      return failure[seq[Vst3ParameterMetadata]](instanceError(hekVst3Descriptor,
        "VST3 parameter metadata text exceeds the host bound",
        instance.module.bundlePath, "index=" & $index))
    parameters.add(Vst3ParameterMetadata(
      id: info.id, title: title.value, shortTitle: shortTitle.value,
      units: units.value, stepCount: info.stepCount,
      defaultNormalizedValue: info.defaultNormalizedValue, unitId: info.unitId,
      flags: info.flags))
  success(move(parameters))

proc mergeCloseError(primary: var HostError; closeResult: Result[Unit]) =
  if not closeResult.isOk:
    primary.context.add("; cleanup=" & closeResult.error.message)
    if closeResult.error.context.len > 0:
      primary.context.add(" (" & closeResult.error.context & ")")

proc close*(instance: Vst3Instance): Result[Unit] =
  if instance == nil or instance.closed: return success()
  instance.closingState.storeRelease(1'u32)
  if instance.activeCallbacks.loadAcquire() != 0'u32:
    return failure[Unit](instanceError(hekVst3Factory,
      "VST3 instance callbacks are still active",
      instance.module.bundlePath))
  ## The editor owns the plugin view and host frame.  It must be closed
  ## before handler removal, controller termination, or module release; a
  ## retained frame leaves this instance rooted and makes close retryable.
  if instance.editor != nil:
    var editorClosed = editor.close(instance.editor)
    if not editorClosed.isOk:
      return failure[Unit](move(editorClosed.error))
  if instance.handlerInstalled and instance.controller != nil:
    let removed = instance.controller.lpVtbl.setComponentHandler(
      cast[pointer](instance.controller), nil)
    if removed != Vst3ResultOk:
      return failure[Unit](instanceError(hekVst3Factory,
        "VST3 controller rejected handler removal", instance.module.bundlePath,
        "result=" & $removed))
    instance.handlerInstalled = false
  if instance.componentConnected and instance.componentPoint != nil:
    let disconnected = instance.componentPoint.lpVtbl.disconnect(
      cast[pointer](instance.componentPoint), addr instance.controllerProxy.iface)
    if disconnected != Vst3ResultOk:
      return failure[Unit](instanceError(hekVst3Factory,
        "VST3 component connection disconnect failed", instance.module.bundlePath,
        "result=" & $disconnected))
    instance.componentConnected = false
  if instance.controllerConnected and instance.controllerPoint != nil:
    let disconnected = instance.controllerPoint.lpVtbl.disconnect(
      cast[pointer](instance.controllerPoint), addr instance.componentProxy.iface)
    if disconnected != Vst3ResultOk:
      return failure[Unit](instanceError(hekVst3Factory,
        "VST3 controller connection disconnect failed", instance.module.bundlePath,
        "result=" & $disconnected))
    instance.controllerConnected = false
  if instance.controllerInitialized and instance.controller != nil:
    let terminated = instance.controller.lpVtbl.terminate(cast[pointer](instance.controller))
    if terminated != Vst3ResultOk:
      return failure[Unit](instanceError(hekVst3Factory,
        "VST3 controller termination failed", instance.module.bundlePath,
        "result=" & $terminated))
    instance.controllerInitialized = false
  if instance.componentInitialized and instance.component != nil:
    let terminated = instance.component.lpVtbl.terminate(cast[pointer](instance.component))
    if terminated != Vst3ResultOk:
      return failure[Unit](instanceError(hekVst3Factory,
        "VST3 component termination failed", instance.module.bundlePath,
        "result=" & $terminated))
    instance.componentInitialized = false
  if instance.controllerPoint != nil:
    releaseInterface(cast[pointer](instance.controllerPoint))
    instance.controllerPoint = nil
  if instance.componentPoint != nil:
    releaseInterface(cast[pointer](instance.componentPoint))
    instance.componentPoint = nil
  if instance.controller != nil:
    releaseInterface(cast[pointer](instance.controller))
    instance.controller = nil
  if instance.processor != nil:
    releaseInterface(cast[pointer](instance.processor))
    instance.processor = nil
  if instance.component != nil:
    releaseInterface(cast[pointer](instance.component))
    instance.component = nil
  # The application-owned context remains usable after a borrowed instance
  # closes, but retained callback/object ownership must still be checked before
  # this instance's module can be unloaded.
  if instance.ownsContext and instance.context != nil:
    instance.context.close()
  if instance.context != nil and
      (instance.context.hasRetainedCallbacks() or
       instance.context.hasRetainedObjects()):
    return failure[Unit](instanceError(hekVst3Factory,
      "VST3 host context retained callbacks or objects during shutdown",
      instance.module.bundlePath))
  # A plugin may retain the startup state stream after the host's reference
  # is released. Keep the instance and module quarantined until that edge
  # drains instead of unloading an object rooted by the stream.
  pruneDrainedStateTransactions(instance)
  for retainedState in instance.stateStreams:
    if retainedState.hasRetainedReferences():
      return failure[Unit](instanceError(hekVst3Factory,
        "VST3 state transaction stream remained retained during shutdown",
        instance.module.bundlePath))
  if instance.handlerObject.references.loadAcquire() > 1'u32 or
      instance.componentProxy.references.loadAcquire() > 1'u32 or
      instance.controllerProxy.references.loadAcquire() > 1'u32:
    return failure[Unit](instanceError(hekVst3Factory,
      "VST3 host callback or connection proxy remained retained",
      instance.module.bundlePath))
  if instance.componentProxy.peer != nil or
      instance.controllerProxy.peer != nil:
    return failure[Unit](instanceError(hekVst3Factory,
      "VST3 connection proxy remained connected", instance.module.bundlePath))
  deinitLock(instance.mailbox.lock)
  var moduleClosed = instance.module.close()
  if not moduleClosed.isOk:
    return failure[Unit](move(moduleClosed.error))
  instance.closed = true
  removeInstanceRoot(instance)
  success()

proc failOpen(instance: Vst3Instance; primary: HostError): Result[Vst3Instance] =
  let cleanup = instance.close()
  if not cleanup.isOk:
    quarantineInstanceRoot(instance)
  var error = primary
  mergeCloseError(error, cleanup)
  failure[Vst3Instance](move(error))
proc openVst3Instance*(module: var Vst3Module; classId: Vst3Tuid;
                       reactor: ptr MainReactor = nil;
                       hostContext: Vst3HostContext = nil;
                       loadStatePath = ""): Result[Vst3Instance] =
  if instanceRootCountAtomic.loadAcquire() >= uint32(Vst3MaxInstanceRoots):
    discard module.close()
    return failure[Vst3Instance](instanceError(hekVst3Factory,
      "VST3 instance root quarantine is full", module.bundlePath))
  var instance: Vst3Instance
  new(instance)
  if claimInstanceRoot(instance) < 0:
    discard module.close()
    return failure[Vst3Instance](instanceError(hekVst3Factory,
      "VST3 instance root quarantine is full", module.bundlePath))
  instance.module = move(module)
  instance.selectedClassId = formatVst3Uid(classId)
  initLock(instance.mailbox.lock)
  if hostContext == nil:
    instance.context = newVst3HostContext(reactor)
    instance.ownsContext = true
  else:
    instance.context = hostContext
    instance.ownsContext = false
  if instance.context == nil:
    return failOpen(instance, instanceError(hekVst3Factory,
      "VST3 host context allocation failed", instance.module.bundlePath))
  instance.mainThread = pthread_self()
  initHandler(instance)
  initProxy(instance.componentProxy, addr instance[])
  initProxy(instance.controllerProxy, addr instance[])
  var hostContextResult = instance.module.setFactoryHostContext(
    cast[pointer](instance.context.hostApplicationPointer()))
  if not hostContextResult.isOk and
      hostContextResult.error.message != "VST3 factory does not expose IPluginFactory3":
    return failOpen(instance, move(hostContextResult.error))

  var componentIid = parseVst3Uid(Vst3ComponentIid)
  if not componentIid.isOk:
    return failOpen(instance, move(componentIid.error))
  var created = instance.module.createInstance(classId, componentIid.value)
  if not created.isOk:
    return failOpen(instance, move(created.error))
  instance.component = cast[ptr Vst3Component](created.value)
  if not validComponent(instance.component):
    return failOpen(instance, instanceError(
      hekVst3Descriptor, "VST3 component has an incomplete ABI", instance.module.bundlePath))

  var processor = queryInterface(created.value, Vst3AudioProcessorIid)
  if not processor.isOk:
    return failOpen(instance, move(processor.error))
  instance.processor = cast[ptr Vst3AudioProcessor](processor.value)
  if not validProcessor(instance.processor):
    return failOpen(instance, instanceError(
      hekVst3Descriptor, "VST3 audio processor has an incomplete ABI",
      instance.module.bundlePath))

  var controllerQuery = queryInterface(created.value, Vst3EditControllerIid)
  if not controllerQuery.isOk:
    return failOpen(instance, move(controllerQuery.error))
  if controllerQuery.value != nil:
    instance.controller = cast[ptr Vst3EditController](controllerQuery.value)
    instance.controllerCombined = true
    if not validController(instance.controller):
      return failOpen(instance, instanceError(
        hekVst3Descriptor, "VST3 edit controller has an incomplete ABI",
        instance.module.bundlePath))
  else:
    var controllerCid: Vst3Tuid
    let controllerCode = instance.component.lpVtbl.getControllerClassId(
      cast[pointer](instance.component), addr controllerCid)
    if controllerCode == Vst3ResultOk:
      var controllerIid = parseVst3Uid(Vst3EditControllerIid)
      if not controllerIid.isOk:
        return failOpen(instance, move(controllerIid.error))
      var createdController = instance.module.createInstance(
        controllerCid, controllerIid.value)
      if not createdController.isOk:
        return failOpen(instance, move(createdController.error))
      instance.controller = cast[ptr Vst3EditController](createdController.value)
      if not validController(instance.controller):
        return failOpen(instance, instanceError(
          hekVst3Descriptor, "VST3 separate controller has an incomplete ABI",
          instance.module.bundlePath))
    elif controllerCode != Vst3NoInterface and
        controllerCode != Vst3ResultFalse and
        controllerCode != Vst3NotImplemented:
      return failOpen(instance, instanceError(
        hekVst3Factory, "VST3 component controller-class lookup failed",
        instance.module.bundlePath, "result=" & $controllerCode))

  let ioMode = instance.component.lpVtbl.setIoMode(
    cast[pointer](instance.component), Vst3IoModeAdvanced)
  if ioMode != Vst3ResultOk and ioMode != Vst3ResultFalse and
      ioMode != Vst3NoInterface and ioMode != Vst3NotImplemented:
    return failOpen(instance, instanceError(
      hekVst3Factory, "VST3 component rejected I/O mode selection",
      instance.module.bundlePath, "result=" & $ioMode))
  let initialized = instance.component.lpVtbl.initialize(
    cast[pointer](instance.component), cast[pointer](instance.context.hostApplicationPointer()))
  if initialized != Vst3ResultOk:
    return failOpen(instance, instanceError(
      hekVst3Factory, "VST3 component initialization failed",
      instance.module.bundlePath, "result=" & $initialized))
  instance.componentInitialized = true

  if instance.controller != nil and not instance.controllerCombined:
    let initializedController = instance.controller.lpVtbl.initialize(
      cast[pointer](instance.controller), cast[pointer](instance.context.hostApplicationPointer()))
    if initializedController != Vst3ResultOk:
      return failOpen(instance, instanceError(
        hekVst3Factory, "VST3 separate controller initialization failed",
        instance.module.bundlePath, "result=" & $initializedController))
    instance.controllerInitialized = true

  if instance.controller != nil:
    let handlerResult = instance.controller.lpVtbl.setComponentHandler(
      cast[pointer](instance.controller), addr instance.handlerObject.iface)
    if handlerResult != Vst3ResultOk:
      return failOpen(instance, instanceError(
        hekVst3Factory, "VST3 controller rejected the component handler",
        instance.module.bundlePath, "result=" & $handlerResult))
    instance.handlerInstalled = true

  if instance.controller != nil and not instance.controllerCombined:
    var componentPoint = queryInterface(created.value, Vst3ConnectionPointIid)
    if not componentPoint.isOk or componentPoint.value == nil:
      return failOpen(instance, if componentPoint.isOk:
        instanceError(hekVst3Factory, "VST3 component has no connection point",
          instance.module.bundlePath)
        else: move(componentPoint.error))
    instance.componentPoint = cast[ptr Vst3ConnectionPoint](componentPoint.value)
    if not validConnectionPoint(instance.componentPoint):
      return failOpen(instance, instanceError(hekVst3Factory,
        "VST3 component connection point has an incomplete ABI",
        instance.module.bundlePath))
    var controllerPoint = queryInterface(cast[pointer](instance.controller),
      Vst3ConnectionPointIid)
    if not controllerPoint.isOk or controllerPoint.value == nil:
      return failOpen(instance, if controllerPoint.isOk:
        instanceError(hekVst3Factory, "VST3 controller has no connection point",
          instance.module.bundlePath)
        else: move(controllerPoint.error))
    instance.controllerPoint = cast[ptr Vst3ConnectionPoint](controllerPoint.value)
    if not validConnectionPoint(instance.controllerPoint):
      return failOpen(instance, instanceError(hekVst3Factory,
        "VST3 controller connection point has an incomplete ABI",
        instance.module.bundlePath))
    instance.componentProxy.target = cast[pointer](instance.componentPoint)
    instance.controllerProxy.target = cast[pointer](instance.controllerPoint)
    let componentConnection = instance.componentPoint.lpVtbl.connect(
      cast[pointer](instance.componentPoint), addr instance.controllerProxy.iface)
    if componentConnection != Vst3ResultOk:
      return failOpen(instance, instanceError(
        hekVst3Factory, "VST3 component connection failed", instance.module.bundlePath,
        "result=" & $componentConnection))
    instance.componentConnected = true
    let controllerConnection = instance.controllerPoint.lpVtbl.connect(
      cast[pointer](instance.controllerPoint), addr instance.componentProxy.iface)
    if controllerConnection != Vst3ResultOk:
      return failOpen(instance, instanceError(
        hekVst3Factory, "VST3 controller connection failed", instance.module.bundlePath,
        "result=" & $controllerConnection))
    instance.controllerConnected = true
  if loadStatePath.len > 0:
    var loaded = loadVst3Preset(loadStatePath, instance.selectedClassId)
    if not loaded.isOk:
      return failOpen(instance, move(loaded.error))
    if loaded.value.hasController and instance.controller == nil:
      return failOpen(instance, stateError(
        "VST3 preset contains controller state but plugin has no controller",
        instance.module.bundlePath))
    let backing = newVst3SharedBuffer(loaded.value.raw)
    if backing == nil:
      return failOpen(instance, stateError(
        "VST3 preset stream backing allocation failed", instance.module.bundlePath))
    var componentState = newVst3ReadOnlyView(backing,
      loaded.value.componentOffset, loaded.value.component.len)
    if componentState == nil:
      return failOpen(instance, stateError(
        "VST3 component state stream allocation failed", instance.module.bundlePath))
    let componentResult = instance.component.lpVtbl.setState(
      cast[pointer](instance.component), cast[pointer](componentState.interfacePointer()))
    finishStateTransaction(instance, componentState)
    if componentResult != Vst3ResultOk and
        componentResult != Vst3NotImplemented:
      return failOpen(instance, stateError(
        "VST3 component rejected preset state", instance.module.bundlePath,
        "result=" & $componentResult))
    var controllerStateResult = Vst3NotImplemented
    if instance.controller != nil:
      var controllerComponent = newVst3ReadOnlyView(backing,
        loaded.value.componentOffset, loaded.value.component.len)
      if controllerComponent == nil:
        return failOpen(instance, stateError(
          "VST3 controller component-state stream allocation failed",
          instance.module.bundlePath))
      controllerStateResult = instance.controller.lpVtbl.setComponentState(
        cast[pointer](instance.controller),
        cast[pointer](controllerComponent.interfacePointer()))
      finishStateTransaction(instance, controllerComponent)
      if controllerStateResult != Vst3ResultOk and
          controllerStateResult != Vst3NotImplemented:
        return failOpen(instance, stateError(
          "VST3 controller rejected preset component state",
          instance.module.bundlePath, "result=" & $controllerStateResult))
      if loaded.value.hasController:
        var controllerState = newVst3ReadOnlyView(backing,
          loaded.value.controllerOffset, loaded.value.controller.len)
        if controllerState == nil:
          return failOpen(instance, stateError(
            "VST3 controller state stream allocation failed",
            instance.module.bundlePath))
        let controllerStateResult = instance.controller.lpVtbl.setState(
          cast[pointer](instance.controller),
          cast[pointer](controllerState.interfacePointer()))
        finishStateTransaction(instance, controllerState)
        if controllerStateResult != Vst3ResultOk and
            controllerStateResult != Vst3NotImplemented:
          return failOpen(instance, stateError(
            "VST3 controller rejected preset state", instance.module.bundlePath,
            "result=" & $controllerStateResult))
    instance.stateSynchronized = controllerStateResult == Vst3ResultOk
  elif instance.controller != nil:
    let state = newVst3MemoryStream()
    if state == nil:
      return failOpen(instance, stateError(
        "VST3 state stream allocation failed", instance.module.bundlePath))
    let stateResult = instance.component.lpVtbl.getState(
      cast[pointer](instance.component), cast[pointer](state.interfacePointer()))
    if stateResult == Vst3ResultOk:
      if state.failed():
        finishStateTransaction(instance, state)
        return failOpen(instance, stateError(
          "VST3 initial component state stream failed",
          instance.module.bundlePath))
      let componentBytes = state.bytes()
      finishStateTransaction(instance, state)
      let controllerState = newVst3ReadOnlyStream(componentBytes)
      if controllerState == nil:
        return failOpen(instance, stateError(
          "VST3 initial controller state stream allocation failed",
          instance.module.bundlePath))
      let controllerResult = instance.controller.lpVtbl.setComponentState(
        cast[pointer](instance.controller),
        cast[pointer](controllerState.interfacePointer()))
      finishStateTransaction(instance, controllerState)
      if controllerResult != Vst3ResultOk and
          controllerResult != Vst3NotImplemented:
        return failOpen(instance, stateError(
          "VST3 controller rejected initial component state",
          instance.module.bundlePath, "result=" & $controllerResult))
      instance.stateSynchronized = controllerResult == Vst3ResultOk
    else:
      finishStateTransaction(instance, state)
      if stateResult != Vst3NotImplemented:
        return failOpen(instance, stateError(
          "VST3 component state query failed", instance.module.bundlePath,
          "result=" & $stateResult))
  acquire(instance.mailbox.lock)
  let pendingRestart = instance.mailbox.restartFlags
  instance.mailbox.restartFlags = 0
  release(instance.mailbox.lock)
  if (pendingRestart and uint32(Vst3RestartReloadComponent or
      Vst3RestartLatencyChanged or Vst3RestartNoteExpressionChanged or
      Vst3RestartPrefetchChanged or Vst3RestartRoutingChanged or
      Vst3RestartKeyswitchChanged)) != 0'u32:
    return failOpen(instance, stateError(
      "VST3 preset requested unsupported restart", instance.module.bundlePath,
      "flags=" & $pendingRestart))
  var buses = collectBusMetadata(instance)
  if not buses.isOk:
    return failOpen(instance, move(buses.error))
  var parameters = collectParameterMetadata(instance)
  if not parameters.isOk:
    return failOpen(instance, move(parameters.error))
  instance.buses = move(buses.value)
  instance.parameters = move(parameters.value)
  success(instance)

proc refreshMetadata*(instance: Vst3Instance): Result[Unit] =
  ## Re-query all copied metadata before publishing either replacement.
  ## A failed query leaves both snapshots untouched.
  if instance == nil or instance.closed or instance.component == nil:
    return failure[Unit](instanceError(hekVst3Factory,
      "VST3 metadata refresh requires an open instance",
      if instance == nil: "" else: instance.module.bundlePath))
  var buses = collectBusMetadata(instance)
  if not buses.isOk:
    return failure[Unit](move(buses.error))
  var parameters = collectParameterMetadata(instance)
  if not parameters.isOk:
    return failure[Unit](move(parameters.error))
  instance.buses = move(buses.value)
  instance.parameters = move(parameters.value)
  success()

proc takeParameterEdits*(instance: Vst3Instance): seq[Vst3ParameterEdit] =
  if instance == nil: return @[]
  acquire(instance.mailbox.lock)
  result = move(instance.mailbox.edits)
  instance.mailbox.edits = @[]
  release(instance.mailbox.lock)

proc takeRestartFlags*(instance: Vst3Instance): uint32 =
  if instance == nil: return 0'u32
  acquire(instance.mailbox.lock)
  result = instance.mailbox.restartFlags
  instance.mailbox.restartFlags = 0
  release(instance.mailbox.lock)
proc restoreRestartFlags*(instance: Vst3Instance; flags: uint32) =
  if instance == nil or flags == 0'u32: return
  acquire(instance.mailbox.lock)
  instance.mailbox.restartFlags = instance.mailbox.restartFlags or flags
  release(instance.mailbox.lock)


proc droppedParameterEdits*(instance: Vst3Instance): uint64 =
  if instance == nil: return 0'u64
  acquire(instance.mailbox.lock)
  result = instance.mailbox.droppedEdits
  instance.mailbox.droppedEdits = 0
  release(instance.mailbox.lock)
proc parameterMetadata*(instance: Vst3Instance): seq[Vst3ParameterMetadata] =
  if instance == nil: return @[]
  instance.parameters

proc busMetadata*(instance: Vst3Instance): seq[Vst3BusMetadata] =
  if instance == nil: return @[]
  instance.buses
proc processorLatencySamples*(instance: Vst3Instance): Result[uint32] =
  if instance == nil or instance.closed or instance.processor == nil or
      instance.processor.lpVtbl == nil or
      instance.processor.lpVtbl.getLatencySamples == nil:
    return failure[uint32](instanceError(hekVst3Factory,
      "VST3 processor latency query is unavailable",
      if instance == nil: "" else: instance.module.bundlePath))
  success(instance.processor.lpVtbl.getLatencySamples(
    cast[pointer](instance.processor)))
proc attachVst3ParameterTransport*(instance: Vst3Instance;
                                   transport: ptr Vst3ParameterTransport): bool =
  if instance == nil or instance.closed or
      instance.closingState.loadAcquire() != 0'u32:
    return false
  instance.parameterTransport = transport
  true

proc detachVst3ParameterTransport*(instance: Vst3Instance;
                                   transport: ptr Vst3ParameterTransport): bool =
  if instance == nil or instance.parameterTransport != transport:
    return false
  instance.parameterTransport = nil
  true

proc wrongThreadNotifications*(instance: Vst3Instance): uint64 {.inline.} =
  if instance == nil: 0'u64
  else: instance.wrongThreadNotifications.loadAcquire()

proc componentPointer*(instance: Vst3Instance): ptr Vst3Component {.inline.} =
  if instance == nil: nil else: instance.component

proc controllerPointer*(instance: Vst3Instance): ptr Vst3EditController {.inline.} =
  if instance == nil: nil else: instance.controller

proc processorPointer*(instance: Vst3Instance): ptr Vst3AudioProcessor {.inline.} =
  if instance == nil: nil else: instance.processor
proc componentHandlerPointer*(instance: Vst3Instance): ptr Vst3ComponentHandler {.inline.} =
  if instance == nil: nil else: addr instance.handlerObject.iface

proc componentProxyPointer*(instance: Vst3Instance): ptr Vst3ConnectionPoint {.inline.} =
  if instance == nil: nil else: addr instance.componentProxy.iface

proc instanceRootCount*(): int {.inline.} =
  int(instanceRootCountAtomic.loadAcquire())

proc instanceQuarantineCount*(): int {.inline.} =
  int(instanceQuarantineCountAtomic.loadAcquire())

proc hostContextPointer*(instance: Vst3Instance): Vst3HostContext {.inline.} =
  if instance == nil: nil else: instance.context
proc stateSynchronized*(instance: Vst3Instance): bool {.inline.} =
  instance != nil and instance.stateSynchronized

proc selectedClassId*(instance: Vst3Instance): string =
  if instance == nil: "" else: instance.selectedClassId

proc createEditor*(instance: Vst3Instance; parentWindowId: uint64;
                   host: Vst3EditorHost): Result[Vst3Editor] =
  if instance == nil or instance.closed or
      instance.closingState.loadAcquire() != 0'u32 or
      instance.controller == nil:
    return failure[Vst3Editor](instanceError(hekVst3Unavailable,
      "VST3 editor requires an open edit controller",
      if instance == nil: "" else: instance.module.bundlePath))
  if instance.editor != nil and not instance.editor.isClosed:
    return failure[Vst3Editor](instanceError(hekVst3Unavailable,
      "VST3 instance already owns an editor",
      instance.module.bundlePath))
  var created = createVst3Editor(instance.controller, instance.mainThread,
    parentWindowId, host)
  if not created.isOk:
    # A failed plugin callback may retain the stable frame. Preserve the
    # partial editor under the instance so module teardown cannot pass it.
    let retained = retainedEditorForController(instance.controller)
    if retained != nil:
      instance.editor = retained
    return created
  instance.editor = created.value
  success(instance.editor)

proc closeEditor*(instance: Vst3Instance): Result[Unit] =
  if instance == nil:
    return success()
  if instance.editor == nil:
    return success()
  editor.close(instance.editor)

proc editorOwner*(instance: Vst3Instance): Vst3Editor =
  if instance == nil: nil else: instance.editor
proc captureState*(instance: Vst3Instance): Result[Vst3StateSnapshot] =

  if instance == nil or instance.closed or instance.component == nil:
    return failure[Vst3StateSnapshot](hostError(hsState, hekState,
      "VST3 state capture requires an open instance"))
  let componentOverhead = Vst3PresetHeaderBytes +
    Vst3PresetListHeaderBytes + Vst3PresetEntryBytes
  let componentMaximum = Vst3PresetMaximumBytes - componentOverhead
  let componentStream = newVst3MemoryStream(maximum = componentMaximum)
  if componentStream == nil:
    return failure[Vst3StateSnapshot](hostError(hsState, hekState,
      "VST3 component state stream allocation failed"))
  let componentResult = instance.component.lpVtbl.getState(
    cast[pointer](instance.component), cast[pointer](componentStream.interfacePointer()))
  if componentResult != Vst3ResultOk and
      componentResult != Vst3NotImplemented:
    finishStateTransaction(instance, componentStream)
    return failure[Vst3StateSnapshot](stateError(
      "VST3 component state capture failed", instance.module.bundlePath,
      "result=" & $componentResult))
  if componentStream.failed():
    finishStateTransaction(instance, componentStream)
    return failure[Vst3StateSnapshot](stateError(
      "VST3 component state stream failed", instance.module.bundlePath))
  let componentBytes = componentStream.bytes()
  finishStateTransaction(instance, componentStream)
  var snapshot = Vst3StateSnapshot(
    component: componentBytes,
    hasComponent: componentResult == Vst3ResultOk)
  if instance.controller != nil:
    let controllerOverhead = Vst3PresetHeaderBytes +
      Vst3PresetListHeaderBytes + 2 * Vst3PresetEntryBytes
    let remaining = Vst3PresetMaximumBytes - controllerOverhead -
      componentBytes.len
    let controllerMaximum = max(0, remaining)
    let controllerStream = newVst3MemoryStream(maximum = controllerMaximum)
    if controllerStream == nil:
      return failure[Vst3StateSnapshot](hostError(hsState, hekState,
        "VST3 controller state stream allocation failed"))
    let controllerResult = instance.controller.lpVtbl.getState(
      cast[pointer](instance.controller), cast[pointer](controllerStream.interfacePointer()))
    if controllerResult == Vst3ResultOk:
      if controllerStream.failed():
        finishStateTransaction(instance, controllerStream)
        return failure[Vst3StateSnapshot](stateError(
          "VST3 controller state stream failed", instance.module.bundlePath))
      if remaining < 0:
        finishStateTransaction(instance, controllerStream)
        return failure[Vst3StateSnapshot](stateError(
          "VST3 state aggregate exceeds host bound", instance.module.bundlePath))
      snapshot.controller = controllerStream.bytes()
      snapshot.hasController = true
    elif controllerResult != Vst3NotImplemented:
      finishStateTransaction(instance, controllerStream)
      return failure[Vst3StateSnapshot](stateError(
        "VST3 controller state capture failed", instance.module.bundlePath,
        "result=" & $controllerResult))
    finishStateTransaction(instance, controllerStream)
  success(move(snapshot))
proc applyStateSnapshot*(instance: Vst3Instance;
                         snapshot: Vst3StateSnapshot): Result[Unit] =
  ## Apply bounded, rooted read-only streams before any audio configuration.
  ## Each ABI call receives a fresh stream so a plugin cannot alter or
  ## accidentally share the caller's snapshot cursor.
  if instance == nil or instance.closed or instance.component == nil:
    return failure[Unit](stateError(
      "VST3 state restore requires an open instance",
      if instance == nil: "" else: instance.module.bundlePath))
  if snapshot.component.len > Vst3PresetMaximumBytes or
      snapshot.controller.len > Vst3PresetMaximumBytes or
      snapshot.component.len + snapshot.controller.len > Vst3PresetMaximumBytes:
    return failure[Unit](stateError(
      "VST3 state snapshot exceeds host bound", instance.module.bundlePath))
  if snapshot.hasController and instance.controller == nil:
    return failure[Unit](stateError(
      "VST3 state snapshot contains controller state but plugin has no controller",
      instance.module.bundlePath))

  var controllerComponentResult = Vst3NotImplemented
  if snapshot.hasComponent:
    var componentStream = newVst3ReadOnlyStream(snapshot.component)
    if componentStream == nil:
      return failure[Unit](stateError(
        "VST3 component state stream allocation failed",
        instance.module.bundlePath))
    let componentResult = instance.component.lpVtbl.setState(
      cast[pointer](instance.component),
      cast[pointer](componentStream.interfacePointer()))
    finishStateTransaction(instance, componentStream)
    if componentResult != Vst3ResultOk and componentResult != Vst3NotImplemented:
      return failure[Unit](stateError(
        "VST3 component state restore failed", instance.module.bundlePath,
        "result=" & $componentResult))

    if instance.controller != nil:
      var controllerComponent = newVst3ReadOnlyStream(snapshot.component)
      if controllerComponent == nil:
        return failure[Unit](stateError(
          "VST3 controller component-state stream allocation failed",
          instance.module.bundlePath))
      controllerComponentResult = instance.controller.lpVtbl.setComponentState(
        cast[pointer](instance.controller),
        cast[pointer](controllerComponent.interfacePointer()))
      finishStateTransaction(instance, controllerComponent)
      if controllerComponentResult != Vst3ResultOk and
          controllerComponentResult != Vst3NotImplemented:
        return failure[Unit](stateError(
          "VST3 controller component-state restore failed",
          instance.module.bundlePath, "result=" & $controllerComponentResult))

  if snapshot.hasController:
    var controllerState = newVst3ReadOnlyStream(snapshot.controller)
    if controllerState == nil:
      return failure[Unit](stateError(
        "VST3 controller state stream allocation failed",
        instance.module.bundlePath))
    let controllerStateResult = instance.controller.lpVtbl.setState(
      cast[pointer](instance.controller),
      cast[pointer](controllerState.interfacePointer()))
    finishStateTransaction(instance, controllerState)
    if controllerStateResult != Vst3ResultOk and
        controllerStateResult != Vst3NotImplemented:
      return failure[Unit](stateError(
        "VST3 controller state restore failed", instance.module.bundlePath,
        "result=" & $controllerStateResult))
  instance.stateSynchronized = controllerComponentResult == Vst3ResultOk
  success()