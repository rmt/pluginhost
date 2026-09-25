import std/[os, posix, unittest]

import pluginhost/app/main_reactor
import pluginhost/app/vst3_plugin_services
import pluginhost/domain/[errors, reactor, result]
import pluginhost/platform/linux/dynlib
import pluginhost/platform/linux/reactor as linux_reactor

import pluginhost/vst3/[ffi, host_context, instance, messages, module, stream, uid]
const ProcessorCid = "102132435465768798A9BACBDCEDFEFF"

type
  FakeDriver = ref object of ReactorDriver
    nowValue: int64
    tokenValue: uint64
    removed: bool
    failRemove: bool
  TestHandler = object
    iface: Vst3RunLoopEventHandler
    vtable: Vst3RunLoopEventHandlerVtbl
    references: int32
    fdCalls: int
    runLoop: ptr Vst3RunLoop
    selfUnregister: bool
    unregisterResult: int32
    closeContext: Vst3HostContext
  TimerHandler = object
    iface: Vst3RunLoopTimerHandler
    vtable: Vst3RunLoopTimerHandlerVtbl
    runLoop: ptr Vst3RunLoop
    references: int32
    timerCalls: int
    unregisterResult: int32
    selfUnregister: bool

method now(driver: FakeDriver): Result[MonotonicNanos] =
  success(monotonicNanos(driver.nowValue))
method addFd(driver: FakeDriver; fd: int32; interests: ReactorInterests;
             tokenValue: uint64): Result[Unit] =
  discard fd
  discard interests
  driver.tokenValue = tokenValue
  success()
method modifyFd(driver: FakeDriver; fd: int32; interests: ReactorInterests;
                tokenValue: uint64): Result[Unit] =
  discard fd
  discard interests
  discard tokenValue
method removeFd(driver: FakeDriver; fd: int32): Result[Unit] =
  discard fd
  if driver.failRemove:
    return failure[Unit](hostError(hsPlatform, hekReactor, "forced remove failure"))
  driver.removed = true
  success()
method wait(driver: FakeDriver; timeoutMilliseconds: int32): Result[seq[ReactorReady]] =
  discard timeoutMilliseconds
  success(newSeq[ReactorReady]())
method close(driver: FakeDriver): Result[Unit] =
  success()

proc handlerQuery(thisInterface: pointer; iid: ptr Vst3Tuid;
                  obj: ptr pointer): int32 {.cdecl, raises: [].} =
  discard thisInterface
  discard iid
  if obj != nil: obj[] = nil
  Vst3NoInterface
proc handlerAddRef(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  inc cast[ptr TestHandler](thisInterface).references
  uint32(cast[ptr TestHandler](thisInterface).references)
proc handlerRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let handler = cast[ptr TestHandler](thisInterface)
  if handler.references > 0: dec handler.references
  uint32(handler.references)
proc timerQuery(thisInterface: pointer; iid: ptr Vst3Tuid;
                obj: ptr pointer): int32 {.cdecl, raises: [].} =
  discard thisInterface
  discard iid
  if obj != nil: obj[] = nil
  Vst3NoInterface
proc timerAddRef(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  inc cast[ptr TimerHandler](thisInterface).references
  uint32(cast[ptr TimerHandler](thisInterface).references)
proc timerRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let handler = cast[ptr TimerHandler](thisInterface)
  if handler.references > 0: dec handler.references
  uint32(handler.references)
proc timerCallback(thisInterface: pointer) {.cdecl, raises: [].} =
  let handler = cast[ptr TimerHandler](thisInterface)
  inc handler.timerCalls
  if handler.selfUnregister:
    handler.unregisterResult = handler.runLoop.lpVtbl.unregisterTimer(
      cast[pointer](handler.runLoop), addr handler.iface)
proc handlerFd(thisInterface: pointer; fd: Vst3FileDescriptor) {.cdecl, raises: [].} =
  discard fd
  let handler = cast[ptr TestHandler](thisInterface)
  inc handler.fdCalls
  if handler.selfUnregister and handler.runLoop != nil:
    handler.unregisterResult = handler.runLoop.lpVtbl.unregisterEventHandler(
      cast[pointer](handler.runLoop), addr handler.iface)
  if handler.closeContext != nil:
    handler.closeContext.close()
type ForeignHandlerCall = object
  handler: ptr Vst3ComponentHandler
  result: int32

type PerformProc = proc(thisInterface: pointer; id: Vst3ParamID;
                         value: Vst3ParamValue): int32 {.
  cdecl, gcsafe, raises: [].}

proc foreignHandlerThread(argument: pointer): pointer {.noconv, gcsafe, raises: [].} =
  let call = cast[ptr ForeignHandlerCall](argument)
  let perform = cast[PerformProc](cast[pointer](call.handler.lpVtbl.performEdit))
  call.result = perform(cast[pointer](call.handler), 42, 0.25)
  nil
type ForeignRunLoopCall = object
  runLoop: ptr Vst3RunLoop
  handler: ptr Vst3RunLoopEventHandler
  unregister: bool
  result: int32

proc foreignRunLoopThread(argument: pointer): pointer {.noconv, raises: [].} =
  let call = cast[ptr ForeignRunLoopCall](argument)
  if call.unregister:
    call.result = call.runLoop.lpVtbl.unregisterEventHandler(
      cast[pointer](call.runLoop), cast[pointer](call.handler))
  else:
    call.result = call.runLoop.lpVtbl.registerEventHandler(
      cast[pointer](call.runLoop), cast[pointer](call.handler), 9)
  nil

type ForeignMessageReleaseCall = object
  message: ptr Vst3Message
  attributes: ptr Vst3AttributeList
  messageResult: uint32
  attributeResult: uint32

proc foreignMessageReleaseThread(argument: pointer): pointer {.
    noconv, raises: [].} =
  let call = cast[ptr ForeignMessageReleaseCall](argument)
  call.messageResult = call.message.lpVtbl.release(cast[pointer](call.message))
  call.attributeResult = call.attributes.lpVtbl.release(
    cast[pointer](call.attributes))
  nil

proc fixtureDirectory(): string =
  result = getEnv("PLUGINHOST_VST3_V2A_FIXTURE_DIR")
  doAssert result.len > 0
proc fixturePath(name: string): string = fixtureDirectory() / (name & ".vst3")
proc fixtureBinary(name: string): string = fixturePath(name) / "Contents" / "x86_64-linux" / (name & ".so")
proc openFixture(name: string; reactor: ptr MainReactor = nil): Result[Vst3Instance] =
  var loaded = openVst3Module(fixturePath(name))
  if not loaded.isOk: return failure[Vst3Instance](move(loaded.error))
  var module = move(loaded.value)
  var cid = parseVst3Uid(ProcessorCid)
  if not cid.isOk: return failure[Vst3Instance](move(cid.error))
  openVst3Instance(module, cid.value, reactor)

proc mappingProbe(name: string): uint32 =
  var library = openDynamicLibrary(fixtureBinary(name), keepLoaded = true)
  doAssert library.isOk
  var loaded = move(library.value)
  let probe = resolveSymbol[proc(): uint32 {.cdecl, raises: [].}](
    loaded, "pluginhost_vst3_v2a_factory_mapping_ok")
  doAssert probe.isOk
  result = probe.value()
  doAssert loaded.close().isOk
proc releaseRetainedProbe(name: string) =
  var library = openDynamicLibrary(fixtureBinary(name), keepLoaded = true)
  doAssert library.isOk
  var loaded = move(library.value)
  let releaseRetained = resolveSymbol[proc() {.cdecl, raises: [].}](
    loaded, "pluginhost_vst3_v2a_release_retained")
  doAssert releaseRetained.isOk
  releaseRetained.value()
  doAssert loaded.close().isOk
proc fixtureCounter(name, symbol: string): uint32 =
  var library = openDynamicLibrary(fixtureBinary(name), keepLoaded = true)
  doAssert library.isOk
  var loaded = move(library.value)
  let counter = resolveSymbol[proc(): uint32 {.cdecl, raises: [].}](
    loaded, symbol)
  doAssert counter.isOk
  result = counter.value()
  doAssert loaded.close().isOk

type FixtureLedger = object
  factoryAcquire, factoryAddRef, factoryRelease: uint32
  componentAcquire, componentAddRef, componentRelease: uint32
  processorAcquire, processorAddRef, processorRelease: uint32
  componentPointAcquire, componentPointAddRef, componentPointRelease: uint32
  controllerAcquire, controllerAddRef, controllerRelease: uint32
  controllerPointAcquire, controllerPointAddRef, controllerPointRelease: uint32
  handlerRetentionAddRef, handlerRetentionRelease: uint32
  directPeerRetentionAddRef, directPeerRetentionRelease: uint32
  directPeerComponent, directPeerController: uint32

proc fixtureLedger(name: string): FixtureLedger =
  result.factoryAcquire = fixtureCounter(name, "pluginhost_vst3_v2a_factory_acquire")
  result.factoryAddRef = fixtureCounter(name, "pluginhost_vst3_v2a_factory_addref")
  result.factoryRelease = fixtureCounter(name, "pluginhost_vst3_v2a_factory_release")
  result.componentAcquire = fixtureCounter(name, "pluginhost_vst3_v2a_component_acquire")
  result.componentAddRef = fixtureCounter(name, "pluginhost_vst3_v2a_component_addref")
  result.componentRelease = fixtureCounter(name, "pluginhost_vst3_v2a_component_release")
  result.processorAcquire = fixtureCounter(name, "pluginhost_vst3_v2a_processor_acquire")
  result.processorAddRef = fixtureCounter(name, "pluginhost_vst3_v2a_processor_addref")
  result.processorRelease = fixtureCounter(name, "pluginhost_vst3_v2a_processor_release")
  result.componentPointAcquire = fixtureCounter(name, "pluginhost_vst3_v2a_component_point_acquire")
  result.componentPointAddRef = fixtureCounter(name, "pluginhost_vst3_v2a_component_point_addref")
  result.componentPointRelease = fixtureCounter(name, "pluginhost_vst3_v2a_component_point_release")
  result.controllerAcquire = fixtureCounter(name, "pluginhost_vst3_v2a_controller_acquire")
  result.controllerAddRef = fixtureCounter(name, "pluginhost_vst3_v2a_controller_addref")
  result.controllerRelease = fixtureCounter(name, "pluginhost_vst3_v2a_controller_release")
  result.controllerPointAcquire = fixtureCounter(name, "pluginhost_vst3_v2a_controller_point_acquire")
  result.controllerPointAddRef = fixtureCounter(name, "pluginhost_vst3_v2a_controller_point_addref")
  result.controllerPointRelease = fixtureCounter(name, "pluginhost_vst3_v2a_controller_point_release")
  result.handlerRetentionAddRef = fixtureCounter(name, "pluginhost_vst3_v2a_handler_retention_addref")
  result.handlerRetentionRelease = fixtureCounter(name, "pluginhost_vst3_v2a_handler_retention_release")
  result.directPeerRetentionAddRef = fixtureCounter(name, "pluginhost_vst3_v2a_direct_peer_retention_addref")
  result.directPeerRetentionRelease = fixtureCounter(name, "pluginhost_vst3_v2a_direct_peer_retention_release")
  result.directPeerComponent = fixtureCounter(name, "pluginhost_vst3_v2a_direct_peer_component")
  result.directPeerController = fixtureCounter(name, "pluginhost_vst3_v2a_direct_peer_controller")

suite "VST3 V2A lifecycle boundary":
  test "factory mapping and component processor QI are exercised":
    check mappingProbe("separate") == 1'u32
    let initialInstanceRoots = instanceRootCount()
    let initialContextRoots = contextRootCount()
    let initialStreamRoots = streamRootCount()
    var opened = openFixture("separate")
    require opened.isOk
    check instanceRootCount() == initialInstanceRoots + 1
    let instance = opened.value
    check instance.componentPointer() != nil
    check instance.processorPointer() != nil
    check instance.controllerPointer() != nil
    check instance.parameterMetadata().len == 1
    check instance.parameterMetadata()[0].id == 42'u32
    check instance.busMetadata().len == 2
    check instance.busMetadata()[0].channelCount == 2
    let handler = instance.componentHandlerPointer()
    require handler != nil
    var foreignCall = ForeignHandlerCall(handler: handler)
    var foreignThread: Pthread
    check pthread_create(addr foreignThread, nil, foreignHandlerThread,
      addr foreignCall) == 0
    check pthread_join(foreignThread, nil) == 0
    check foreignCall.result == Vst3ResultFalse
    check instance.wrongThreadNotifications() == 1'u64
    check handler.lpVtbl.performEdit(cast[pointer](handler), 42, 0.5) ==
      Vst3ResultFalse
    check handler.lpVtbl.beginEdit(cast[pointer](handler), 42) == Vst3ResultOk
    check handler.lpVtbl.performEdit(cast[pointer](handler), 42, 0.5) ==
      Vst3ResultOk
    check handler.lpVtbl.endEdit(cast[pointer](handler), 42) == Vst3ResultOk
    check instance.takeParameterEdits().len == 3
    check handler.lpVtbl.restartComponent(cast[pointer](handler),
      Vst3RestartReloadComponent) == Vst3ResultOk
    check instance.takeRestartFlags() == uint32(Vst3RestartReloadComponent)
    var unknownIid = parseVst3Uid(Vst3FUnknownIid)
    require unknownIid.isOk
    var handlerUnknown: pointer
    check handler.lpVtbl.queryInterface(cast[pointer](handler),
      addr unknownIid.value, addr handlerUnknown) == Vst3ResultOk
    require handlerUnknown != nil
    discard handler.lpVtbl.release(handlerUnknown)
    check instance.wrongThreadNotifications() == 1'u64
    check instance.close().isOk
    check instance.close().isOk
    check instanceRootCount() == initialInstanceRoots
    check instanceQuarantineCount() == 0
    check contextRootCount() == initialContextRoots
    check streamRootCount() == initialStreamRoots
    for _ in 0 ..< 4:
      var repeated = openFixture("separate")
      require repeated.isOk
      check instanceRootCount() == initialInstanceRoots + 1
      check repeated.value.close().isOk
      check instanceRootCount() == initialInstanceRoots
    check instanceQuarantineCount() == 0
    check contextRootCount() == initialContextRoots
    check streamRootCount() == initialStreamRoots
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_component_initialize") == 5'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_component_terminate") == 5'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_controller_initialize") == 5'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_controller_terminate") == 5'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_connect_component") == 5'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_connect_controller") == 5'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_disconnect_component") == 5'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_disconnect_controller") == 5'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_direct_peer_component") == 5'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_direct_peer_controller") == 5'u32

  test "combined and controller-absent forms preserve valid lifecycle":
    check mappingProbe("combined") == 1'u32
    var combined = openFixture("combined")
    require combined.isOk
    check combined.value.controllerPointer() != nil
    check combined.value.stateSynchronized()
    check combined.value.close().isOk
    check fixtureCounter("combined",
      "pluginhost_vst3_v2a_state_get") == 1'u32
    check fixtureCounter("combined",
      "pluginhost_vst3_v2a_state_set") == 1'u32
    check fixtureCounter("combined",
      "pluginhost_vst3_v2a_state_bytes_observed") == 4'u32
    check fixtureCounter("combined",
      "pluginhost_vst3_v2a_component_terminate") == 1'u32
    check mappingProbe("no_controller") == 1'u32
    var absent = openFixture("no_controller")
    require absent.isOk
    check absent.value.controllerPointer() == nil
    check absent.value.close().isOk

  test "lifecycle, connection, state, and metadata failures are rejected":
    for name in ["component_init_fail", "controller_init_fail", "component_connect_fail",
                 "controller_connect_fail", "malformed_buses", "malformed_params"]:
      check mappingProbe(name) == 1'u32
      let componentInitialize = fixtureCounter(name,
        "pluginhost_vst3_v2a_component_initialize")
      let componentTerminate = fixtureCounter(name,
        "pluginhost_vst3_v2a_component_terminate")
      let controllerInitialize = fixtureCounter(name,
        "pluginhost_vst3_v2a_controller_initialize")
      let controllerTerminate = fixtureCounter(name,
        "pluginhost_vst3_v2a_controller_terminate")
      let connectComponent = fixtureCounter(name,
        "pluginhost_vst3_v2a_connect_component")
      let connectController = fixtureCounter(name,
        "pluginhost_vst3_v2a_connect_controller")
      let disconnectComponent = fixtureCounter(name,
        "pluginhost_vst3_v2a_disconnect_component")
      let disconnectController = fixtureCounter(name,
        "pluginhost_vst3_v2a_disconnect_controller")
      let moduleExit = fixtureCounter(name, "pluginhost_vst3_v2a_module_exit")
      let beforeLedger = fixtureLedger(name)
      let opened = openFixture(name)
      check not opened.isOk
      let afterLedger = fixtureLedger(name)
      let points = if name == "component_init_fail" or
          name == "controller_init_fail": 0'u32 else: 1'u32
      let componentConnected = if name == "controller_connect_fail" or
          name == "malformed_buses" or name == "malformed_params": 1'u32 else: 0'u32
      let controllerConnected = if name == "malformed_buses" or
          name == "malformed_params": 1'u32 else: 0'u32
      check afterLedger.factoryAcquire == beforeLedger.factoryAcquire + 1'u32
      check afterLedger.factoryAddRef == beforeLedger.factoryAddRef
      check afterLedger.factoryRelease == beforeLedger.factoryRelease + 1'u32
      check afterLedger.componentAcquire == beforeLedger.componentAcquire + 1'u32
      check afterLedger.componentAddRef == beforeLedger.componentAddRef + 1'u32
      check afterLedger.componentRelease == beforeLedger.componentRelease + 1'u32
      check afterLedger.processorAcquire == beforeLedger.processorAcquire + 1'u32
      check afterLedger.processorAddRef == beforeLedger.processorAddRef + 1'u32
      check afterLedger.processorRelease == beforeLedger.processorRelease + 1'u32
      check afterLedger.componentPointAcquire == beforeLedger.componentPointAcquire + points
      check afterLedger.componentPointAddRef == beforeLedger.componentPointAddRef + points
      check afterLedger.componentPointRelease == beforeLedger.componentPointRelease + points
      check afterLedger.controllerAcquire == beforeLedger.controllerAcquire + 1'u32
      check afterLedger.controllerAddRef == beforeLedger.controllerAddRef + 1'u32
      check afterLedger.controllerRelease == beforeLedger.controllerRelease + 1'u32
      check afterLedger.controllerPointAcquire == beforeLedger.controllerPointAcquire + points
      check afterLedger.controllerPointAddRef == beforeLedger.controllerPointAddRef + points
      check afterLedger.controllerPointRelease == beforeLedger.controllerPointRelease + points
      check afterLedger.handlerRetentionAddRef == beforeLedger.handlerRetentionAddRef
      check afterLedger.handlerRetentionRelease == beforeLedger.handlerRetentionRelease
      check afterLedger.directPeerRetentionAddRef == beforeLedger.directPeerRetentionAddRef
      check afterLedger.directPeerRetentionRelease == beforeLedger.directPeerRetentionRelease
      let componentTerminateDelta = if name == "component_init_fail": 0'u32 else: 1'u32
      let controllerInitializeDelta = if name == "component_init_fail": 0'u32 else: 1'u32
      let controllerTerminateDelta = if name == "component_init_fail" or
          name == "controller_init_fail": 0'u32 else: 1'u32
      let componentConnectDelta = if name == "controller_connect_fail" or
          name == "malformed_buses" or name == "malformed_params": 1'u32 else: 0'u32
      let controllerConnectDelta = if name == "malformed_buses" or
          name == "malformed_params": 1'u32 else: 0'u32
      let disconnectComponentDelta = if name == "controller_connect_fail" or
          name == "malformed_buses" or name == "malformed_params": 1'u32 else: 0'u32
      let disconnectControllerDelta = if name == "malformed_buses" or
          name == "malformed_params": 1'u32 else: 0'u32
      check fixtureCounter(name, "pluginhost_vst3_v2a_component_initialize") ==
        componentInitialize + 1'u32
      check fixtureCounter(name, "pluginhost_vst3_v2a_component_terminate") ==
        componentTerminate + componentTerminateDelta
      check fixtureCounter(name, "pluginhost_vst3_v2a_controller_initialize") ==
        controllerInitialize + controllerInitializeDelta
      check fixtureCounter(name, "pluginhost_vst3_v2a_controller_terminate") ==
        controllerTerminate + controllerTerminateDelta
      check fixtureCounter(name, "pluginhost_vst3_v2a_connect_component") ==
        connectComponent + componentConnectDelta
      check fixtureCounter(name, "pluginhost_vst3_v2a_connect_controller") ==
        connectController + controllerConnectDelta
      check fixtureCounter(name, "pluginhost_vst3_v2a_disconnect_component") ==
        disconnectComponent + disconnectComponentDelta
      check fixtureCounter(name, "pluginhost_vst3_v2a_disconnect_controller") ==
        disconnectController + disconnectControllerDelta
      check fixtureCounter(name, "pluginhost_vst3_v2a_module_exit") ==
        moduleExit + 1'u32
      check fixtureCounter(name, "pluginhost_vst3_v2a_factory_refs") == 0'u32
      check fixtureCounter(name, "pluginhost_vst3_v2a_component_refs") == 0'u32
      check fixtureCounter(name, "pluginhost_vst3_v2a_controller_refs") == 0'u32
    var notImplementedState = openFixture("state_notimpl")
    require notImplementedState.isOk
    check notImplementedState.value.close().isOk
    var controllerStateNotImplemented = openFixture("state_set_notimpl")
    require controllerStateNotImplemented.isOk
    check controllerStateNotImplemented.value.close().isOk

  test "host application converts UTF-8 names and run loop dispatches on main thread":
    var driver = FakeDriver(nowValue: 10_000)
    var reactorResult = initMainReactor(driver)
    require reactorResult.isOk
    var reactor = move(reactorResult.value)
    let initialContextRoots = contextRootCount()
    let initialStreamRoots = streamRootCount()
    let context = newVst3HostContext(addr reactor, "Vändor ✓")
    check contextRootCount() == initialContextRoots + 1
    let host = context.hostApplicationPointer()
    require host != nil
    var name: Vst3VstString128
    check host.lpVtbl.getName(cast[pointer](host), addr name) == Vst3ResultOk
    check name[0] == uint16(ord('V'))
    check name[1] == 0x00E4'u16
    check name[7] == 0x2713'u16

    var unknownIid = parseVst3Uid(Vst3FUnknownIid)
    require unknownIid.isOk
    check unknownIid.value[8] == 0xC0'u8
    check unknownIid.value[15] == 0x46'u8
    var hostUnknown: pointer
    check host.lpVtbl.queryInterface(cast[pointer](host), addr unknownIid.value,
      addr hostUnknown) == Vst3ResultOk
    require hostUnknown != nil
    check hostUnknown == cast[pointer](host)
    check host.lpVtbl.release(hostUnknown) == 1'u32

    var messageObject: pointer
    var messageIid = parseVst3Uid(Vst3MessageIid)
    require messageIid.isOk
    check host.lpVtbl.createInstance(cast[pointer](host), addr messageIid.value,
      addr messageIid.value, addr messageObject) == Vst3ResultOk
    require messageObject != nil
    let message = cast[ptr Vst3Message](messageObject)
    var messageUnknown: pointer
    check message.lpVtbl.queryInterface(messageObject, addr unknownIid.value,
      addr messageUnknown) == Vst3ResultOk
    require messageUnknown != nil
    discard message.lpVtbl.release(messageUnknown)
    let initialMessageId = message.lpVtbl.getMessageID(messageObject)
    require initialMessageId != nil
    check $initialMessageId == ""
    message.lpVtbl.setMessageID(messageObject, "before")
    let borrowedMessageId = message.lpVtbl.getMessageID(messageObject)
    require borrowedMessageId != nil
    check $borrowedMessageId == "before"
    var oversizedMessageId = newString(Vst3MaxAttributeKeyBytes)
    for character in oversizedMessageId.mitems:
      character = 'a'
    message.lpVtbl.setMessageID(messageObject, oversizedMessageId.cstring)
    check $message.lpVtbl.getMessageID(messageObject) == "before"
    let attributes = message.lpVtbl.getAttributes(messageObject)
    var payload = newSeq[uint8](Vst3MaxAggregateAttributeBytes -
      "before".len - "payload".len)
    check attributes.lpVtbl.setBinary(cast[pointer](attributes), "payload",
      addr payload[0], uint32(payload.len)) == Vst3ResultOk
    check context.objectStore().liveObjectCount() == 2
    discard message.lpVtbl.release(messageObject)
    var attrObject: pointer
    var attrIid = parseVst3Uid(Vst3AttributeListIid)
    require attrIid.isOk
    check host.lpVtbl.createInstance(cast[pointer](host), addr attrIid.value,
      addr attrIid.value, addr attrObject) == Vst3ResultOk
    require attrObject != nil
    let attr = cast[ptr Vst3AttributeList](attrObject)
    var attrUnknown: pointer
    check attr.lpVtbl.queryInterface(attrObject, addr unknownIid.value,
      addr attrUnknown) == Vst3ResultOk
    require attrUnknown != nil
    check attr.lpVtbl.release(attrUnknown) == 1'u32
    var keys = newSeq[string](Vst3MaxAttributesPerList)
    for index in 0 ..< Vst3MaxAttributesPerList:
      keys[index] = "k" & $index
      check attr.lpVtbl.setInt(attrObject, keys[index].cstring, int64(index)) ==
        Vst3ResultOk
    check attr.lpVtbl.setInt(attrObject, "overflow", 1) == Vst3ResultFalse
    var intValue: int64
    check attr.lpVtbl.getInt(attrObject, "k255", addr intValue) == Vst3ResultOk
    check intValue == 255
    var floatValue: float64
    check attr.lpVtbl.getFloat(attrObject, "k255", addr floatValue) == Vst3ResultFalse
    check attr.lpVtbl.getInt(attrObject, "missing", addr intValue) == Vst3ResultFalse
    var oversizedText = newSeq[uint16](Vst3MaxAttributeTextBytes div 2)
    check attr.lpVtbl.setString(attrObject, "tooLong",
      cast[ptr Vst3TChar](addr oversizedText[0])) ==
      Vst3ResultFalse
    var smallText: Vst3VstString128
    smallText[0] = uint16(ord('o'))
    smallText[1] = uint16(ord('k'))
    smallText[2] = 0
    check attr.lpVtbl.setString(attrObject, "k255",
      cast[ptr Vst3TChar](addr smallText)) == Vst3ResultOk
    var textOut: Vst3VstString128
    check attr.lpVtbl.getString(attrObject, "k255",
      cast[ptr Vst3TChar](addr textOut),
      uint32(sizeof(textOut))) == Vst3ResultOk
    var blob = @[1'u8, 2'u8, 3'u8, 4'u8]
    check attr.lpVtbl.setBinary(attrObject, "k254", addr blob[0],
      uint32(blob.len)) == Vst3ResultOk
    var blobPointer: pointer
    var blobSize: uint32
    check attr.lpVtbl.getBinary(attrObject, "k254", addr blobPointer,
      addr blobSize) == Vst3ResultOk
    check blobSize == 4'u32
    var tooLarge = newSeq[uint8](Vst3MaxAttributeBinaryBytes + 1)
    check attr.lpVtbl.setBinary(attrObject, "k254", addr tooLarge[0],
      uint32(tooLarge.len)) == Vst3ResultFalse
    check attr.lpVtbl.getBinary(attrObject, "k254", addr blobPointer,
      addr blobSize) == Vst3ResultOk
    check blobSize == 4'u32
    discard attr.lpVtbl.release(attrObject)
    reclaimVst3ControlObjectStore(context.objectStore())
    let memoryStream = newVst3MemoryStream()
    require memoryStream != nil
    check streamRootCount() == initialStreamRoots + 1

    var streamUnknown: pointer
    let streamPointer = cast[pointer](memoryStream.interfacePointer())
    check memoryStream.interfacePointer().lpVtbl.queryInterface(streamPointer,
      addr unknownIid.value, addr streamUnknown) == Vst3ResultOk
    require streamUnknown != nil
    discard memoryStream.interfacePointer().lpVtbl.release(streamUnknown)
    check memoryStream.interfacePointer().lpVtbl.release(streamPointer) == 0'u32
    check streamRootCount() == initialStreamRoots
    var supportObject: pointer
    var supportIid = parseVst3Uid(Vst3PlugInterfaceSupportIid)
    require supportIid.isOk
    check host.lpVtbl.queryInterface(cast[pointer](host), addr supportIid.value,
      addr supportObject) == Vst3ResultOk
    let support = cast[ptr Vst3PlugInterfaceSupport](supportObject)
    var supportUnknown: pointer
    check support.lpVtbl.queryInterface(supportObject, addr unknownIid.value,
      addr supportUnknown) == Vst3ResultOk
    require supportUnknown != nil
    check supportUnknown == cast[pointer](host)
    check host.lpVtbl.release(supportUnknown) == 1'u32
    var supportHost: pointer
    check support.lpVtbl.queryInterface(supportObject, addr unknownIid.value,
      addr supportHost) == Vst3ResultOk
    check supportHost == cast[pointer](host)
    check host.lpVtbl.release(supportHost) == 1'u32

    var runLoopObject: pointer
    var runLoopIid = parseVst3Uid(Vst3RunLoopIid)
    require runLoopIid.isOk
    check host.lpVtbl.queryInterface(cast[pointer](host), addr runLoopIid.value,
      addr runLoopObject) == Vst3ResultOk
    require runLoopObject != nil
    let runLoop = cast[ptr Vst3RunLoop](runLoopObject)
    var supportRunLoop: pointer
    check support.lpVtbl.queryInterface(supportObject, addr runLoopIid.value,
      addr supportRunLoop) == Vst3ResultOk
    check supportRunLoop == runLoopObject
    check runLoop.lpVtbl.release(supportRunLoop) == 2'u32
    var runLoopUnknown: pointer
    check runLoop.lpVtbl.queryInterface(cast[pointer](runLoop),
      addr unknownIid.value, addr runLoopUnknown) == Vst3ResultOk
    require runLoopUnknown != nil
    check runLoopUnknown == cast[pointer](host)
    check host.lpVtbl.release(runLoopUnknown) == 1'u32
    var runLoopSupport: pointer
    check runLoop.lpVtbl.queryInterface(cast[pointer](runLoop),
      addr supportIid.value, addr runLoopSupport) == Vst3ResultOk
    check runLoopSupport == supportObject
    check support.lpVtbl.release(runLoopSupport) == 2'u32
    var timer = TimerHandler(references: 1, runLoop: runLoop,
      selfUnregister: true)
    timer.vtable = Vst3RunLoopTimerHandlerVtbl(
      queryInterface: timerQuery, addRef: timerAddRef, release: timerRelease,
      onTimer: timerCallback)
    timer.iface.lpVtbl = addr timer.vtable
    check runLoop.lpVtbl.registerTimer(cast[pointer](runLoop),
      addr timer.iface, 1'u64) == Vst3ResultOk
    check runLoop.lpVtbl.registerTimer(cast[pointer](runLoop),
      addr timer.iface, 1'u64) == Vst3ResultFalse
    check timer.references == 2
    driver.nowValue = 2_000_000
    var timerEvents = reactor.wait(monotonicNanos(0))
    require timerEvents.isOk
    require timerEvents.value.len == 1
    context.dispatchRunLoopEvents(timerEvents.value)
    check timer.timerCalls == 1
    check timer.unregisterResult == Vst3ResultOk
    check timer.references == 1
    var handler = TestHandler(references: 1)
    handler.vtable = Vst3RunLoopEventHandlerVtbl(
      queryInterface: handlerQuery, addRef: handlerAddRef, release: handlerRelease,
      onFDIsSet: handlerFd)
    handler.iface.lpVtbl = addr handler.vtable
    check runLoop.lpVtbl.registerEventHandler(cast[pointer](runLoop),
      addr handler.iface, 3) == Vst3ResultOk
    check handler.references == 2
    let token = decodeReactorToken(driver.tokenValue)
    context.dispatchRunLoopEvents(@[ReactorEvent(token: token, kind: rekFd,
      interests: {riRead})])
    check handler.fdCalls == 1
    let staleToken = token
    check runLoop.lpVtbl.unregisterEventHandler(cast[pointer](runLoop),
      addr handler.iface) == Vst3ResultOk
    check handler.references == 1
    check runLoop.lpVtbl.registerEventHandler(cast[pointer](runLoop),
      addr handler.iface, 3) == Vst3ResultOk
    let freshToken = decodeReactorToken(driver.tokenValue)
    check not reactor.isCurrent(staleToken)
    check not reactor.removeFd(staleToken).isOk
    check reactor.isCurrent(freshToken)
    context.dispatchRunLoopEvents(@[ReactorEvent(token: staleToken, kind: rekFd,
      interests: {riRead})])
    check handler.fdCalls == 1
    context.dispatchRunLoopEvents(@[ReactorEvent(token: freshToken, kind: rekFd,
      interests: {riRead})])
    check handler.fdCalls == 2
    check runLoop.lpVtbl.unregisterEventHandler(cast[pointer](runLoop),
      addr handler.iface) == Vst3ResultOk

    var selfRemoving = TestHandler(references: 1, runLoop: runLoop,
      selfUnregister: true)
    selfRemoving.vtable = Vst3RunLoopEventHandlerVtbl(
      queryInterface: handlerQuery, addRef: handlerAddRef, release: handlerRelease,
      onFDIsSet: handlerFd)
    selfRemoving.iface.lpVtbl = addr selfRemoving.vtable
    check runLoop.lpVtbl.registerEventHandler(cast[pointer](runLoop),
      addr selfRemoving.iface, 4) == Vst3ResultOk
    let selfToken = decodeReactorToken(driver.tokenValue)
    context.dispatchRunLoopEvents(@[ReactorEvent(token: selfToken, kind: rekFd,
      interests: {riRead})])
    check selfRemoving.fdCalls == 1
    check selfRemoving.unregisterResult == Vst3ResultOk
    check selfRemoving.references == 1
    var foreignRegister = ForeignRunLoopCall(
      runLoop: runLoop, handler: addr handler.iface)
    var foreignThread: Pthread
    check pthread_create(addr foreignThread, nil, foreignRunLoopThread,
      addr foreignRegister) == 0
    check pthread_join(foreignThread, nil) == 0
    check foreignRegister.result == Vst3ResultFalse
    var foreignUnregister = ForeignRunLoopCall(
      runLoop: runLoop, handler: addr handler.iface, unregister: true)
    check pthread_create(addr foreignThread, nil, foreignRunLoopThread,
      addr foreignUnregister) == 0
    check pthread_join(foreignThread, nil) == 0
    check foreignUnregister.result == Vst3ResultFalse

    var removeFailure = TestHandler(references: 1, runLoop: runLoop)
    removeFailure.vtable = Vst3RunLoopEventHandlerVtbl(
      queryInterface: handlerQuery, addRef: handlerAddRef, release: handlerRelease,
      onFDIsSet: handlerFd)
    removeFailure.iface.lpVtbl = addr removeFailure.vtable
    check runLoop.lpVtbl.registerEventHandler(cast[pointer](runLoop),
      addr removeFailure.iface, 5) == Vst3ResultOk
    check removeFailure.references == 2
    driver.failRemove = true
    check runLoop.lpVtbl.unregisterEventHandler(cast[pointer](runLoop),
      addr removeFailure.iface) == Vst3ResultFalse
    check removeFailure.references == 2
    driver.failRemove = false
    check runLoop.lpVtbl.unregisterEventHandler(cast[pointer](runLoop),
      addr removeFailure.iface) == Vst3ResultOk
    check removeFailure.references == 1

    var cancelFailure = TimerHandler(references: 1, runLoop: runLoop)
    cancelFailure.vtable = Vst3RunLoopTimerHandlerVtbl(
      queryInterface: timerQuery, addRef: timerAddRef, release: timerRelease,
      onTimer: timerCallback)
    cancelFailure.iface.lpVtbl = addr cancelFailure.vtable
    check runLoop.lpVtbl.registerTimer(cast[pointer](runLoop),
      addr cancelFailure.iface, 1'u64) == Vst3ResultOk
    check runLoop.lpVtbl.unregisterTimer(cast[pointer](runLoop),
      addr cancelFailure.iface) == Vst3ResultOk
    check cancelFailure.references == 1
    check runLoop.lpVtbl.unregisterTimer(cast[pointer](runLoop),
      addr cancelFailure.iface) == Vst3ResultFalse
    check cancelFailure.references == 1

    var rearmFailure = TimerHandler(references: 1, runLoop: runLoop)
    rearmFailure.vtable = Vst3RunLoopTimerHandlerVtbl(
      queryInterface: timerQuery, addRef: timerAddRef, release: timerRelease,
      onTimer: timerCallback)
    rearmFailure.iface.lpVtbl = addr rearmFailure.vtable
    check runLoop.lpVtbl.registerTimer(cast[pointer](runLoop),
      addr rearmFailure.iface, 1'u64) == Vst3ResultOk
    check rearmFailure.references == 2
    let rearmToken = decodeReactorToken(driver.tokenValue)
    let rearmFailures = context.timerRearmFailures()
    driver.nowValue = high(int64)
    var rearmEvents = reactor.wait(monotonicNanos(0))
    require rearmEvents.isOk
    context.dispatchRunLoopEvents(rearmEvents.value)
    check rearmFailure.timerCalls == 1
    check rearmFailure.references == 1
    check context.timerRearmFailures() == rearmFailures + 1
    check not reactor.isCurrent(rearmToken)

    discard support.lpVtbl.release(supportObject)
    discard runLoop.lpVtbl.release(runLoopObject)
    var retainedMessage: pointer
    check host.lpVtbl.createInstance(cast[pointer](host), addr messageIid.value,
      addr messageIid.value, addr retainedMessage) == Vst3ResultOk
    let retainedMessageIface = cast[ptr Vst3Message](retainedMessage)
    let retainedAttributes = retainedMessageIface.lpVtbl.getAttributes(
      retainedMessage)
    require retainedAttributes != nil
    check retainedAttributes.lpVtbl.addRef(cast[pointer](retainedAttributes)) ==
      2'u32
    let deferredRootCount = contextRootCount()
    context.close()
    check context.hasRetainedObjects()
    var foreignMessage = ForeignMessageReleaseCall(
      message: retainedMessageIface, attributes: retainedAttributes)
    check pthread_create(addr foreignThread, nil, foreignMessageReleaseThread,
      addr foreignMessage) == 0
    check pthread_join(foreignThread, nil) == 0
    check foreignMessage.messageResult == 0'u32
    check foreignMessage.attributeResult == 0'u32
    check context.objectStore().liveObjectCount() == 0
    check context.objectStore().copiedPayloadBytes() == 0'u64
    check context.objectStore().deferredObjectCount() == 2
    check contextRootCount() == deferredRootCount
    reclaimVst3ControlObjectStore(context.objectStore())
    check context.objectStore().deferredObjectCount() == 0
    context.close()
    check not context.hasRetainedObjects()
    check contextRootCount() == initialContextRoots

    let serviceContext = newVst3HostContext(addr reactor, "adapter")
    let services = newVst3PluginServices(serviceContext)
    check services.context() == serviceContext
    var serviceModuleResult = openVst3Module(fixturePath("no_controller"))
    require serviceModuleResult.isOk
    var serviceModule = move(serviceModuleResult.value)
    var serviceCid = parseVst3Uid(ProcessorCid)
    require serviceCid.isOk
    var viaServices = services.openInstance(serviceModule, serviceCid.value)
    require viaServices.isOk
    check viaServices.value.hostContextPointer() == serviceContext
    check viaServices.value.close().isOk
    check services.close().isOk
    check contextRootCount() == initialContextRoots
    check reactor.close().isOk
  test "retiring a host context revokes its reactor without invalidating retained ABI refs":
    var driver = FakeDriver(nowValue: 10_000)
    var reactorResult = initMainReactor(driver)
    require reactorResult.isOk
    var reactor = move(reactorResult.value)
    let originalRoots = contextRootCount()
    let context = newVst3HostContext(addr reactor)
    let host = context.hostApplicationPointer()
    let runLoop = context.runLoopPointer()
    let hostPointer = cast[pointer](host)
    check host.lpVtbl.addRef(hostPointer) == 2'u32
    check context.retire()
    check context.hasRetainedObjects()
    check contextRootCount() == originalRoots + 1
    check reactor.close().isOk
    var iid = parseVst3Uid(Vst3RunLoopIid)
    require iid.isOk
    var queried: pointer
    check host.lpVtbl.queryInterface(hostPointer, addr iid.value,
      addr queried) == Vst3NoInterface
    check queried == nil
    var timer = TimerHandler(references: 1, runLoop: runLoop)
    timer.vtable = Vst3RunLoopTimerHandlerVtbl(
      queryInterface: timerQuery, addRef: timerAddRef, release: timerRelease,
      onTimer: timerCallback)
    timer.iface.lpVtbl = addr timer.vtable
    check runLoop.lpVtbl.registerTimer(cast[pointer](runLoop),
      addr timer.iface, 1'u64) == Vst3ResultFalse
    check timer.references == 1
    check host.lpVtbl.release(hostPointer) == 1'u32
    context.close()
    check contextRootCount() == originalRoots

  test "run loop close requested from dispatch drains callback ownership":
    var driver = FakeDriver(nowValue: 10_000)
    var reactorResult = initMainReactor(driver)
    require reactorResult.isOk
    var reactor = move(reactorResult.value)
    let initialContextRoots = contextRootCount()
    let context = newVst3HostContext(addr reactor, "close-dispatch")
    let runLoop = context.runLoopPointer()
    var closingHandler = TestHandler(references: 1, closeContext: context)
    closingHandler.vtable = Vst3RunLoopEventHandlerVtbl(
      queryInterface: handlerQuery, addRef: handlerAddRef, release: handlerRelease,
      onFDIsSet: handlerFd)
    closingHandler.iface.lpVtbl = addr closingHandler.vtable
    check runLoop.lpVtbl.registerEventHandler(cast[pointer](runLoop),
      addr closingHandler.iface, 7) == Vst3ResultOk
    let token = decodeReactorToken(driver.tokenValue)
    context.dispatchRunLoopEvents(@[ReactorEvent(token: token, kind: rekFd,
      interests: {riRead})])
    check closingHandler.fdCalls == 1
    check closingHandler.references == 1
    check not context.hasRetainedCallbacks()
    check contextRootCount() == initialContextRoots
    check reactor.close().isOk

  test "headless fixture receives real runloop FD and timer callbacks":
    var driverResult = linux_reactor.openLinuxReactorDriver()
    require driverResult.isOk
    var reactorResult = initMainReactor(driverResult.value)
    require reactorResult.isOk
    var reactor = move(reactorResult.value)
    var opened = openFixture("separate", addr reactor)
    require opened.isOk
    let instance = opened.value
    let context = instance.hostContextPointer()
    require context != nil
    for _ in 0 ..< 4:
      var events = reactor.wait(monotonicNanos(20_000_000))
      require events.isOk
      context.dispatchRunLoopEvents(events.value)
      if fixtureCounter("separate",
          "pluginhost_vst3_v2a_runloop_fd_callbacks") > 0'u32 and
          fixtureCounter("separate",
          "pluginhost_vst3_v2a_runloop_timer_callbacks") > 0'u32:
        break
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_runloop_fd_callbacks") == 1'u32
    check fixtureCounter("separate",
      "pluginhost_vst3_v2a_runloop_timer_callbacks") == 1'u32
    check instance.close().isOk
    check reactor.close().isOk

  test "instance close rejects retained handler and direct peer ownership":
    let initialInstanceRoots = instanceRootCount()
    let handlerBefore = fixtureLedger("retained_handler")
    var retainedHandler = openFixture("retained_handler")
    require retainedHandler.isOk
    check not retainedHandler.value.close().isOk
    check instanceRootCount() == initialInstanceRoots + 1
    releaseRetainedProbe("retained_handler")
    check retainedHandler.value.close().isOk
    check instanceRootCount() == initialInstanceRoots
    let handlerAfter = fixtureLedger("retained_handler")
    check handlerAfter.handlerRetentionAddRef == handlerBefore.handlerRetentionAddRef + 1'u32
    check handlerAfter.handlerRetentionRelease == handlerBefore.handlerRetentionRelease + 1'u32

    let directBefore = fixtureLedger("retained_peer")
    var retainedDirect = openFixture("retained_peer")
    require retainedDirect.isOk
    check not retainedDirect.value.close().isOk
    check instanceRootCount() == initialInstanceRoots + 1
    let directRetained = fixtureLedger("retained_peer")
    check directRetained.directPeerComponent == directBefore.directPeerComponent + 1'u32
    check directRetained.directPeerController == directBefore.directPeerController + 1'u32
    check directRetained.directPeerRetentionAddRef ==
      directBefore.directPeerRetentionAddRef + 2'u32
    check directRetained.directPeerRetentionRelease ==
      directBefore.directPeerRetentionRelease
    releaseRetainedProbe("retained_peer")
    check retainedDirect.value.close().isOk
    check instanceRootCount() == initialInstanceRoots
    let directAfter = fixtureLedger("retained_peer")
    check directAfter.directPeerRetentionRelease ==
      directBefore.directPeerRetentionRelease + 2'u32

  test "instance close rejects retained startup state stream":
    let initialInstanceRoots = instanceRootCount()
    let initialStreamRoots = streamRootCount()
    var retainedStream = openFixture("retained_stream")
    require retainedStream.isOk
    check streamRootCount() == initialStreamRoots + 1
    check not retainedStream.value.close().isOk
    check instanceRootCount() == initialInstanceRoots + 1
    releaseRetainedProbe("retained_stream")
    check retainedStream.value.close().isOk
    check streamRootCount() == initialStreamRoots
    check instanceRootCount() == initialInstanceRoots

  test "failed startup rollback quarantine is bounded and accounted":
    let initialInstanceRoots = instanceRootCount()
    let initialQuarantine = instanceQuarantineCount()
    let initialModuleExit = fixtureCounter("quarantine",
      "pluginhost_vst3_v2a_module_exit")
    let firstFailed = openFixture("quarantine")
    check not firstFailed.isOk
    check fixtureCounter("quarantine", "pluginhost_vst3_v2a_module_exit") ==
      initialModuleExit
    check fixtureCounter("quarantine", "pluginhost_vst3_v2a_factory_release") == 0'u32
    check instanceRootCount() == initialInstanceRoots + 1
    check instanceQuarantineCount() == initialQuarantine + 1
    for _ in 1 ..< Vst3MaxInstanceRoots:
      let failed = openFixture("quarantine")
      check not failed.isOk
    check instanceRootCount() == initialInstanceRoots + Vst3MaxInstanceRoots
    check instanceQuarantineCount() == initialQuarantine + Vst3MaxInstanceRoots
    let capped = openFixture("quarantine")
    check not capped.isOk
    check instanceRootCount() == initialInstanceRoots + Vst3MaxInstanceRoots
    check instanceQuarantineCount() == initialQuarantine + Vst3MaxInstanceRoots
