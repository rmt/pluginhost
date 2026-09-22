## Private V2B composition root.  Public VST3 run routing intentionally does not
## import this owner; focused fixture and embedding code may construct it directly.

import ../domain/[errors, port_plan, result]
import ../jack/backend
import ../vst3/[audio_process, event_bridge, ffi, instance, module,
  parameter_transport, port_inspector, uid]
import ./vst3_plugin_services

type
  Vst3AudioSliceState* = enum
    v3assEmpty
    v3assReady
    v3assActive
    v3assQuiesced
    v3assClosed

  Vst3AudioSlice* = object
    instance: Vst3Instance
    process: Vst3AudioProcess
    backend: JackBackend
    transport: ptr Vst3ParameterTransport
    activationLedger: Vst3BusActivationLedger
    plan: PortPlan
    path: string
    pluginId: string
    stateValue: Vst3AudioSliceState
    componentActive: bool
    processorActive: bool

proc sliceError(message, path, pluginId, detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0: context.add("; " & detail)
  hostError(hsVst3, hekVst3Factory, message, context)

proc sliceError(message, path, pluginId: string): HostError =
  sliceError(message, path, pluginId, "")

proc appendVst3CleanupError(primary: var HostError;
                            cleanup: Result[Unit]; label: string) =
  if not cleanup.isOk:
    primary.context.add("; " & label & "=" & cleanup.error.message)
    if cleanup.error.context.len > 0:
      primary.context.add(" (" & cleanup.error.context & ")")

proc `=destroy`*(slice: var Vst3AudioSlice) =
  doAssert slice.stateValue in {v3assEmpty, v3assClosed},
    "a VST3 audio slice must be explicitly closed"

proc `=copy`*(destination: var Vst3AudioSlice;
              source: Vst3AudioSlice) {.error:
  "Vst3AudioSlice owns JACK/process resources and cannot be copied; use move".}
proc `=dup`*(source: Vst3AudioSlice): Vst3AudioSlice {.error:
  "Vst3AudioSlice owns JACK/process resources and cannot be duplicated; use move".}
proc `=sink`*(destination: var Vst3AudioSlice;
              source: Vst3AudioSlice) =
  doAssert destination.stateValue in {v3assEmpty, v3assClosed},
    "a VST3 audio slice must be closed before move assignment"
  `=sink`(destination.instance, source.instance)
  `=sink`(destination.process, source.process)
  `=sink`(destination.backend, source.backend)
  destination.transport = source.transport
  destination.activationLedger = source.activationLedger
  `=sink`(destination.plan, source.plan)
  `=sink`(destination.path, source.path)
  `=sink`(destination.pluginId, source.pluginId)
  destination.stateValue = source.stateValue
  destination.componentActive = source.componentActive
  destination.processorActive = source.processorActive

proc state*(slice: Vst3AudioSlice): Vst3AudioSliceState {.inline.} =
  slice.stateValue
proc jackBackend*(slice: var Vst3AudioSlice): var JackBackend {.inline.} =
  slice.backend
proc portPlan*(slice: Vst3AudioSlice): PortPlan {.inline.} = slice.plan
proc instance*(slice: Vst3AudioSlice): Vst3Instance {.inline.} = slice.instance
proc takeFault*(slice: var Vst3AudioSlice): bool = slice.process.takeVst3ProcessFault()
proc drainParameterObservations*(slice: var Vst3AudioSlice): uint32 =
  slice.process.drainVst3ParameterObservations(slice.instance.controllerPointer())

proc drainParameterGestures*(slice: var Vst3AudioSlice;
                             destination: ptr UncheckedArray[
                               Vst3ParameterEditRecord];
                             capacity: uint32): uint32 =
  slice.process.drainVst3ParameterGestures(destination, capacity)
proc takeEventMetrics*(slice: var Vst3AudioSlice): Vst3EventMetrics =
  slice.process.eventMetrics()



proc openVst3AudioSlice*(services: Vst3PluginServices;
                        module: var Vst3Module; classId: Vst3Tuid;
                        backendConfig: JackBackendOpenConfig):
                        Result[Vst3AudioSlice] =
  if services == nil:
    return failure[Vst3AudioSlice](sliceError(
      "VST3 audio slice requires application-owned services", "", ""))
  let bundlePath = module.bundlePath()
  let pluginId = formatVst3Uid(classId)
  var opened = services.openInstance(module, classId)
  if not opened.isOk:
    return failure[Vst3AudioSlice](move(opened.error))
  var slice = Vst3AudioSlice(instance: opened.value,
    path: bundlePath, pluginId: pluginId,
    stateValue: v3assEmpty)
  var initialPlan = inspectVst3Ports(slice.instance.componentPointer(),
    slice.instance.processorPointer(), portPlanVersion(1), slice.path,
    slice.pluginId)
  if not initialPlan.isOk:
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(initialPlan.error))
  var openedBackend = openJackBackend(backendConfig)
  if not openedBackend.isOk:
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(openedBackend.error))
  slice.backend = move(openedBackend.value)
  ## Arrangement negotiation is inactive and is followed by the authoritative
  ## post-call query, including kResultFalse.
  var arrangements = setVst3BusArrangementsAndRequery(
    slice.instance.componentPointer(), slice.instance.processorPointer(),
    slice.path, slice.pluginId)
  if not arrangements.isOk:
    discard slice.backend.close()
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(arrangements.error))
  var inspected = inspectVst3Ports(slice.instance.componentPointer(),
    slice.instance.processorPointer(), arrangements.value, portPlanVersion(1),
    slice.path, slice.pluginId)
  if not inspected.isOk:
    discard slice.backend.close()
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(inspected.error))
  slice.plan = move(inspected.value)
  slice.transport = newVst3ParameterTransport()
  if slice.transport == nil:
    discard slice.backend.close()
    discard slice.instance.close()
    return failure[Vst3AudioSlice](sliceError(
      "could not allocate VST3 parameter transport", slice.path, slice.pluginId))
  if not slice.instance.attachVst3ParameterTransport(slice.transport):
    closeVst3ParameterTransport(slice.transport)
    discard slice.backend.close()
    discard slice.instance.close()
    return failure[Vst3AudioSlice](sliceError(
      "could not attach VST3 parameter transport", slice.path, slice.pluginId))
  var processResult = newVst3AudioProcess(
    slice.instance.processorPointer(), slice.instance.componentPointer(),
    slice.plan, slice.transport, slice.backend.bufferSize(),
    slice.backend.sampleRate(), slice.backend.audioRoleGuard(), slice.path,
    slice.pluginId, controller = slice.instance.controllerPointer())
  if not processResult.isOk:
    discard slice.instance.detachVst3ParameterTransport(slice.transport)
    closeVst3ParameterTransport(slice.transport)
    discard slice.backend.close()
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(processResult.error))
  slice.process = move(processResult.value)
  var activatedBuses = activateVst3Buses(
    slice.instance.componentPointer(), slice.activationLedger)
  if not activatedBuses.isOk:
    var activationError = move(activatedBuses.error)
    let retryRollback = deactivateVst3Buses(
      slice.instance.componentPointer(), slice.activationLedger)
    if not retryRollback.isOk:
      activationError.context.add("; rollback retry=" &
        retryRollback.error.message)
      if retryRollback.error.context.len > 0:
        activationError.context.add(" (" & retryRollback.error.context & ")")
    discard slice.process.close()
    discard slice.instance.detachVst3ParameterTransport(slice.transport)
    closeVst3ParameterTransport(slice.transport)
    discard slice.backend.close()
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(activationError))
  var configured = slice.backend.configure(slice.plan, slice.process.endpoint())
  if not configured.isOk:
    var configuredError = move(configured.error)
    let rollback = deactivateVst3Buses(
      slice.instance.componentPointer(), slice.activationLedger)
    appendVst3CleanupError(configuredError, rollback, "bus rollback")
    discard slice.process.close()
    discard slice.instance.detachVst3ParameterTransport(slice.transport)
    closeVst3ParameterTransport(slice.transport)
    discard slice.backend.close()
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(configuredError))
  var active = setVst3Active(slice.instance.componentPointer(), true)
  if not active.isOk:
    var activeError = move(active.error)
    let rollback = deactivateVst3Buses(
      slice.instance.componentPointer(), slice.activationLedger)
    appendVst3CleanupError(activeError, rollback, "bus rollback")
    discard slice.backend.close()
    discard slice.process.close()
    discard slice.instance.detachVst3ParameterTransport(slice.transport)
    closeVst3ParameterTransport(slice.transport)
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(activeError))
  slice.componentActive = true
  var processing = setVst3Processing(slice.instance.processorPointer(), true)
  if not processing.isOk:
    discard setVst3Active(slice.instance.componentPointer(), false)
    slice.componentActive = false
    var processingError = move(processing.error)
    let rollback = deactivateVst3Buses(
      slice.instance.componentPointer(), slice.activationLedger)
    appendVst3CleanupError(processingError, rollback, "bus rollback")
    discard slice.backend.close()
    discard slice.process.close()
    discard slice.instance.detachVst3ParameterTransport(slice.transport)
    closeVst3ParameterTransport(slice.transport)
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(processingError))
  slice.processorActive = true
  var started = slice.backend.activate()
  if not started.isOk:
    discard setVst3Processing(slice.instance.processorPointer(), false)
    discard setVst3Active(slice.instance.componentPointer(), false)
    slice.processorActive = false
    slice.componentActive = false
    var startedError = move(started.error)
    let rollback = deactivateVst3Buses(
      slice.instance.componentPointer(), slice.activationLedger)
    appendVst3CleanupError(startedError, rollback, "bus rollback")
    discard slice.backend.close()
    discard slice.process.close()
    discard slice.instance.detachVst3ParameterTransport(slice.transport)
    closeVst3ParameterTransport(slice.transport)
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(startedError))
  slice.stateValue = v3assActive
  success(move(slice))

proc stop*(slice: var Vst3AudioSlice): Result[Unit] =
  if slice.stateValue in {v3assEmpty, v3assClosed, v3assQuiesced}:
    return success()
  if slice.stateValue != v3assActive:
    return failure[Unit](sliceError("invalid VST3 audio-slice stop transition",
      slice.path, slice.pluginId, "state=" & $slice.stateValue))
  let stoppedJack = slice.backend.deactivate()
  if not stoppedJack.isOk:
    return stoppedJack
  if not slice.process.waitVst3ProcessQuiescence():
    return failure[Unit](sliceError("VST3 process did not quiesce", slice.path,
      slice.pluginId))
  let stopped = setVst3Processing(slice.instance.processorPointer(), false)
  if not stopped.isOk: return stopped
  slice.processorActive = false
  slice.stateValue = v3assQuiesced
  success()

proc close*(slice: var Vst3AudioSlice): Result[Unit] =
  if slice.stateValue in {v3assEmpty, v3assClosed}:
    return success()
  if slice.stateValue == v3assActive:
    let stopped = slice.stop()
    if not stopped.isOk:
      ## Keep the entire ownership graph intact while a callback may still run.
      return stopped
  if slice.componentActive:
    let inactive = setVst3Active(slice.instance.componentPointer(), false)
    if not inactive.isOk:
      return inactive
    slice.componentActive = false
  let deactivated = deactivateVst3Buses(
    slice.instance.componentPointer(), slice.activationLedger)
  if not deactivated.isOk:
    return deactivated
  if not slice.process.waitVst3ProcessQuiescence():
    return failure[Unit](sliceError("VST3 process did not quiesce",
      slice.path, slice.pluginId))
  let processClosed = slice.process.close()
  if not processClosed.isOk:
    return processClosed
  if slice.transport != nil:
    if not slice.instance.detachVst3ParameterTransport(slice.transport):
      return failure[Unit](sliceError(
        "VST3 parameter transport ownership changed during teardown",
        slice.path, slice.pluginId))
    closeVst3ParameterTransport(slice.transport)
  let backendClosed = slice.backend.close()
  if not backendClosed.isOk:
    return backendClosed
  let instanceClosed = slice.instance.close()
  if not instanceClosed.isOk:
    return instanceClosed
  slice.stateValue = v3assClosed
  success()
