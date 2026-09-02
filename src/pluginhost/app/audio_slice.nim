## Owned CLAP/JACK audio composition for one host session.
##
## This owner connects one initialized CLAP instance, its frozen audio/event
## process view, and one configured JACK backend. HostSession moves exactly one
## instance of this owner into the public runtime.

import ../clap/[audio_process, event_bridge, ffi, host_bridge, instance, loader,
                main_thread_services, parameter_transport]
import ../domain/[errors, plugin_catalog, result]
import ../jack/backend

type
  InternalAudioSliceState* = enum
    iassEmpty
    iassReady
    iassActive
    iassClosed

  InternalAudioSlice* = object
    instance: ClapInstance
    process: ClapAudioProcess
    backend: JackBackend
    stateValue: InternalAudioSliceState
    reconnectionReport: JackReconnectionReport

  PluginLogSeverity* = enum
    plsDebug
    plsInfo
    plsWarning
    plsError
    plsFatal
    plsHostMisbehaving
    plsPluginMisbehaving

  PluginLogMessage* = object
    severity*: PluginLogSeverity
    text*: string

  InternalControlRequests* = object
    restart*: bool
    process*: bool
    callback*: bool
    flush*: bool

  InternalRescanRequests* = object
    parameters*: uint32
    audioPorts*: uint32
    notePorts*: uint32

  InternalControlSnapshot* = object
    jackShutdownCount*: uint64
    jackShutdownStatus*: int32
    jackShutdownReason*: string
    processErrors*: uint64
    configurationPending*: bool
    xrunCount*: uint64
    freewheelCount*: uint64
    freewheel*: bool
    processCycles*: uint64


proc `=destroy`*(slice: var InternalAudioSlice) =
  doAssert slice.stateValue in {iassEmpty, iassClosed},
    "an internal audio slice must be explicitly closed"

proc `=copy`*(destination: var InternalAudioSlice;
              source: InternalAudioSlice) {.error:
  "InternalAudioSlice owns CLAP/JACK resources and cannot be copied; use move".}
proc `=dup`*(source: InternalAudioSlice): InternalAudioSlice {.error:
  "InternalAudioSlice owns CLAP/JACK resources and cannot be duplicated; use move".}

proc `=sink`*(destination: var InternalAudioSlice;
              source: InternalAudioSlice) =
  doAssert destination.stateValue in {iassEmpty, iassClosed},
    "an internal audio slice must be closed before move assignment"
  `=sink`(destination.instance, source.instance)
  `=sink`(destination.process, source.process)
  `=sink`(destination.backend, source.backend)
  destination.stateValue = source.stateValue
  `=sink`(destination.reconnectionReport, source.reconnectionReport)

proc sliceError(kind: HostErrorKind; message, path, pluginId: string;
                detail = ""): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsInternal, kind, message, context)

proc rememberFailure(first: var HostError; hadFailure: var bool;
                     operation: var Result[Unit]) =
  if not operation.isOk and not hadFailure:
    first = move(operation.error)
    hadFailure = true

proc rememberCleanupFailure(first: var HostError; hadFailure: var bool;
                            operation: var Result[Unit]) =
  if operation.isOk:
    return
  if not hadFailure:
    first = move(operation.error)
    hadFailure = true
  else:
    first.context.add("; additional-cleanup=" & operation.error.message)
    if operation.error.context.len > 0:
      first.context.add(" (" & operation.error.context & ")")

proc cleanupConstructionFailure(slice: var InternalAudioSlice;
                                primary: sink HostError): HostError =
  var cleanupFailure: HostError
  var hadCleanupFailure = false
  var processClosed = slice.process.close()
  rememberCleanupFailure(cleanupFailure, hadCleanupFailure, processClosed)
  if processClosed.isOk:
    var instanceClosed = slice.instance.close()
    rememberCleanupFailure(cleanupFailure, hadCleanupFailure, instanceClosed)
  var backendClosed = slice.backend.close()
  rememberCleanupFailure(cleanupFailure, hadCleanupFailure, backendClosed)
  if not hadCleanupFailure:
    return move(primary)
  cleanupFailure.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    cleanupFailure.context.add(" (" & primary.context & ")")
  move(cleanupFailure)

proc state*(slice: InternalAudioSlice): InternalAudioSliceState {.inline.} =
  slice.stateValue

proc jackBackend*(slice: var InternalAudioSlice): var JackBackend =
  slice.backend

proc takeEventMetrics*(slice: var InternalAudioSlice): ClapEventMetrics =
  slice.process.takeEventMetrics()

proc controlRequests*(slice: var InternalAudioSlice): InternalControlRequests =
  let requests = slice.instance.takeRequests()
  InternalControlRequests(
    restart: (requests and ClapRequestRestart) != 0'u32,
    process: (requests and ClapRequestProcess) != 0'u32,
    callback: (requests and ClapRequestCallback) != 0'u32,
    flush: (requests and ClapRequestFlush) != 0'u32,
  )

proc takeRescanRequests*(slice: var InternalAudioSlice): InternalRescanRequests =
  InternalRescanRequests(
    parameters: slice.instance.takeParamsRescan(),
    audioPorts: slice.instance.takeAudioPortsRescan(),
    notePorts: slice.instance.takeNotePortsRescan(),
  )

proc parameterCount*(slice: InternalAudioSlice): int {.inline.} =
  slice.instance.parameterCount

proc parameterCatalogGeneration*(slice: InternalAudioSlice): uint64 {.inline.} =
  slice.instance.parameterCatalogGeneration

proc takeReconnectionReport*(slice: var InternalAudioSlice): JackReconnectionReport =
  move(slice.reconnectionReport)

proc drainParameterEvents*(slice: var InternalAudioSlice): ClapParameterDrain =
  slice.instance.drainParameterEvents()

proc takeParameterMetrics*(slice: var InternalAudioSlice): ClapParameterMetrics =
  slice.instance.takeParameterMetrics()

proc flushParameters*(slice: var InternalAudioSlice): Result[Unit] =
  slice.instance.flushParameters()

proc rescanParameters*(slice: var InternalAudioSlice; flags: uint32): Result[Unit] =
  slice.instance.rescanParameters(flags)

proc takeStateDirty*(slice: var InternalAudioSlice): bool =
  slice.instance.takeStateDirty()

proc takeLatencyChanged*(slice: var InternalAudioSlice): bool =
  slice.instance.takeLatencyChanged()

proc callOnTimer*(slice: var InternalAudioSlice; timerId: uint32): Result[Unit] =
  slice.instance.callOnTimer(timerId)

proc callOnFd*(slice: var InternalAudioSlice; fd: int32; flags: uint32): Result[Unit] =
  slice.instance.callOnFd(fd, flags)

proc callOnMainThread*(slice: var InternalAudioSlice): Result[Unit] =
  slice.instance.callOnMainThread()

proc controlSnapshot*(slice: var InternalAudioSlice): InternalControlSnapshot =
  let snapshot = slice.backend.notifications()
  InternalControlSnapshot(
    jackShutdownCount: snapshot.shutdownCount,
    jackShutdownStatus: snapshot.shutdownStatus,
    jackShutdownReason: snapshot.shutdownReason,
    processErrors: snapshot.processErrors,
    configurationPending: snapshot.configurationPending,
    xrunCount: snapshot.xrunCount,
    freewheelCount: snapshot.freewheelCount,
    freewheel: snapshot.freewheel,
    processCycles: snapshot.processCycles,
  )

proc tryTakePluginLog*(slice: var InternalAudioSlice;
                       message: var PluginLogMessage): bool =
  var record: ClapHostLogRecord
  if not slice.instance.tryPopLog(record):
    return false
  message.text = record.logMessage()
  message.severity = case record.severity
    of ClapLogDebug: plsDebug
    of ClapLogInfo: plsInfo
    of ClapLogWarning: plsWarning
    of ClapLogError: plsError
    of ClapLogFatal: plsFatal
    of ClapLogHostMisbehaving: plsHostMisbehaving
    else: plsPluginMisbehaving
  true

proc takeDroppedPluginLogs*(slice: var InternalAudioSlice): uint64 =
  slice.instance.takeDroppedLogs()

proc pluginPath*(slice: InternalAudioSlice): string =
  slice.instance.modulePath

proc pluginId*(slice: InternalAudioSlice): string =
  slice.instance.selectedDescriptor.id

proc openInternalAudioSlice*(module: sink ClapModule;
                             descriptor: sink PluginDescriptor;
                             backendConfig: JackBackendOpenConfig;
                             mainServices: ptr ClapMainThreadServices = nil):
    Result[InternalAudioSlice] =
  var slice = InternalAudioSlice(stateValue: iassEmpty)
  var created = createClapInstance(
    move(module), move(descriptor), mainServices)
  if not created.isOk:
    return failure[InternalAudioSlice](move(created.error))
  slice.instance = move(created.value)

  var render = slice.instance.negotiateRealtimeRender()
  if not render.isOk:
    return failure[InternalAudioSlice](slice.cleanupConstructionFailure(
      move(render.error)))

  var planResult = slice.instance.inspectPortPlan()
  if not planResult.isOk:
    return failure[InternalAudioSlice](slice.cleanupConstructionFailure(
      move(planResult.error)))
  let plan = move(planResult.value)

  var openedBackend = openJackBackend(backendConfig)
  if not openedBackend.isOk:
    return failure[InternalAudioSlice](slice.cleanupConstructionFailure(
      move(openedBackend.error)))
  slice.backend = move(openedBackend.value)

  var processResult = slice.instance.newAudioProcess(
    plan, slice.backend.bufferSize, slice.backend.audioRoleGuard())
  if not processResult.isOk:
    return failure[InternalAudioSlice](slice.cleanupConstructionFailure(
      move(processResult.error)))
  slice.process = move(processResult.value)

  var configured = slice.backend.configure(plan, slice.process.endpoint)
  if not configured.isOk:
    return failure[InternalAudioSlice](slice.cleanupConstructionFailure(
      move(configured.error)))

  slice.stateValue = iassReady
  success(move(slice))

proc refreshRuntimeConfiguration*(slice: var InternalAudioSlice): Result[Unit]
proc start*(slice: var InternalAudioSlice): Result[Unit] =
  if slice.stateValue != iassReady:
    return failure[Unit](sliceError(
      hekInternal,
      "internal audio slice is not ready to start",
      slice.instance.modulePath,
      slice.instance.selectedDescriptor.id,
      "state=" & $slice.stateValue,
    ))
  if slice.backend.configurationChangePending:
    var refreshed = slice.refreshRuntimeConfiguration()
    if not refreshed.isOk:
      return refreshed

  var activated = slice.instance.activate(
    slice.backend.sampleRate.float64, 1'u32, slice.backend.bufferSize)
  if not activated.isOk:
    return activated

  var latency = slice.instance.latencyFrames()
  if not latency.isOk:
    discard slice.instance.deactivate()
    return failure[Unit](move(latency.error))
  var latencySet = slice.backend.setPluginLatency(latency.value)
  if not latencySet.isOk:
    discard slice.instance.deactivate()
    return latencySet

  var started = slice.instance.startProcessing(slice.backend.audioRoleGuard())
  if not started.isOk:
    var deactivated = slice.instance.deactivate()
    if not deactivated.isOk:
      started.error.context.add("; rollback=" & deactivated.error.message)
    discard slice.instance.hostBridge.detachAudioRole(
      slice.backend.audioRoleGuard())
    return started

  var backendActive = slice.backend.activate()
  if not backendActive.isOk:
    var stopped = slice.instance.stopProcessing(slice.backend.audioRoleGuard())
    if not stopped.isOk:
      backendActive.error.context.add("; rollback=" & stopped.error.message)
    var deactivated = slice.instance.deactivate()
    if not deactivated.isOk:
      backendActive.error.context.add("; rollback=" & deactivated.error.message)
    discard slice.instance.hostBridge.detachAudioRole(
      slice.backend.audioRoleGuard())
    return backendActive

  var recomputed = slice.backend.recomputeLatencies()
  if not recomputed.isOk:
    discard slice.backend.deactivate()
    discard slice.instance.stopProcessing(slice.backend.audioRoleGuard())
    discard slice.instance.deactivate()
    discard slice.instance.hostBridge.detachAudioRole(
      slice.backend.audioRoleGuard())
    return recomputed

  slice.stateValue = iassActive
  success()

proc stop*(slice: var InternalAudioSlice): Result[Unit] =
  if slice.stateValue == iassReady:
    return success()
  if slice.stateValue != iassActive:
    return failure[Unit](sliceError(
      hekInternal,
      "internal audio slice is not active",
      slice.instance.modulePath,
      slice.instance.selectedDescriptor.id,
      "state=" & $slice.stateValue,
    ))

  var deactivatedJack = slice.backend.deactivate()
  if not deactivatedJack.isOk:
    return deactivatedJack
  var stopped = slice.instance.stopProcessing(slice.backend.audioRoleGuard())
  if not stopped.isOk:
    return stopped
  var deactivatedClap = slice.instance.deactivate()
  if not deactivatedClap.isOk:
    return deactivatedClap
  discard slice.instance.hostBridge.detachAudioRole(
    slice.backend.audioRoleGuard())
  slice.stateValue = iassReady
  success()

proc restart*(slice: var InternalAudioSlice;
              rescanParameters = false): Result[Unit] =
  if slice.stateValue notin {iassReady, iassActive}:
    return failure[Unit](sliceError(
      hekInternal, "audio restart requires a ready or active slice",
      slice.instance.modulePath, slice.instance.selectedDescriptor.id,
      "state=" & $slice.stateValue,
    ))
  let wasActive = slice.stateValue == iassActive
  if wasActive:
    var stopped = slice.stop()
    if not stopped.isOk:
      return stopped

  let deferredRequests = slice.instance.takeRequests()
  if (deferredRequests and ClapRequestFlush) != 0'u32:
    var flushed = slice.instance.flushParameters()
    if not flushed.isOk:
      return flushed
  slice.instance.restoreRequests(deferredRequests and not ClapRequestFlush)
  if slice.backend.configurationChangePending:
    var runtime = slice.backend.refreshRuntimeConfiguration()
    if not runtime.isOk:
      return failure[Unit](move(runtime.error))
    var acknowledged = slice.backend.acknowledgeConfigurationChange()
    if not acknowledged.isOk:
      return acknowledged

  if rescanParameters:
    var parameters = slice.instance.rescanParameters(ClapParamRescanAll)
    if not parameters.isOk:
      return parameters
  var connections = slice.backend.snapshotConnections()
  if not connections.isOk:
    return failure[Unit](move(connections.error))
  slice.reconnectionReport = JackReconnectionReport()
  # Rescan notifications produced during deactivate belong to this rebuild.
  discard slice.instance.takeAudioPortsRescan()
  discard slice.instance.takeNotePortsRescan()
  var planResult = slice.instance.inspectPortPlan()
  if not planResult.isOk:
    return failure[Unit](move(planResult.error))
  let plan = move(planResult.value)
  var created = slice.instance.newAudioProcess(
    plan, slice.backend.bufferSize, slice.backend.audioRoleGuard())
  if not created.isOk:
    return failure[Unit](move(created.error))
  var replacement = move(created.value)
  var previous = move(slice.process)
  var rebuilt = slice.backend.reconfigure(plan, replacement.endpoint)
  if not rebuilt.isOk:
    slice.process = move(previous)
    discard replacement.close()
    return rebuilt
  var restored = slice.backend.restoreConnections(move(connections.value))
  if not restored.isOk:
    var restoreError = move(restored.error)
    var previousClosed = previous.close()
    slice.process = move(replacement)
    if not previousClosed.isOk:
      restoreError.context.add("; prior-process-close=" & previousClosed.error.message)
    return failure[Unit](move(restoreError))
  var previousClosed = previous.close()
  if not previousClosed.isOk:
    slice.process = move(replacement)
    return previousClosed
  slice.process = move(replacement)
  slice.reconnectionReport = move(restored.value)
  if wasActive:
    return slice.start()
  success()

proc refreshRuntimeConfiguration*(slice: var InternalAudioSlice): Result[Unit] =
  if not slice.backend.configurationChangePending:
    return success()
  slice.restart()

proc close*(slice: var InternalAudioSlice): Result[Unit] =
  if slice.stateValue in {iassEmpty, iassClosed}:
    return success()

  var first: HostError
  var hadFailure = false
  if slice.stateValue == iassActive:
    var stopped = slice.stop()
    rememberFailure(first, hadFailure, stopped)

  if not hadFailure and slice.instance.state == cisProcessing:
    var stopped = slice.instance.stopProcessing(slice.backend.audioRoleGuard())
    rememberFailure(first, hadFailure, stopped)
  if not hadFailure and slice.instance.state == cisActivated:
    var deactivated = slice.instance.deactivate()
    rememberFailure(first, hadFailure, deactivated)
  if not hadFailure:
    discard slice.instance.hostBridge.detachAudioRole(
      slice.backend.audioRoleGuard())
    var processClosed = slice.process.close()
    rememberFailure(first, hadFailure, processClosed)
  if not hadFailure:
    var instanceClosed = slice.instance.close()
    rememberFailure(first, hadFailure, instanceClosed)
  if not hadFailure:
    var backendClosed = slice.backend.close()
    rememberFailure(first, hadFailure, backendClosed)

  if hadFailure:
    return failure[Unit](move(first))
  slice.stateValue = iassClosed
  success()
