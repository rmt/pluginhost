## VST3 audio composition for the public process and focused embedding tests.
## All JACK and plugin lifecycle edges are owned here.

import std/strutils
import ../domain/[errors, port_plan, result]
import ../jack/[backend, ports]
import ../vst3/[audio_process, event_bridge, ffi, instance, module, state_codec,
  parameter_transport, port_inspector, uid]
import ./vst3_plugin_services
type
  Vst3AudioSliceState* = enum
    v3assEmpty
    v3assReady
    v3assActive
    v3assQuiesced
    v3assFailed
    v3assClosed

  Vst3AudioSlice* = object
    instance: Vst3Instance
    process: Vst3AudioProcess
    backend: JackBackend
    services: Vst3PluginServices
    transport: ptr Vst3ParameterTransport
    activationLedger: Vst3BusActivationLedger
    plan: PortPlan
    path: string
    pluginId: string
    stateValue: Vst3AudioSliceState
    componentActive: bool
    allowRetainedHostReferences: bool
    processorActive: bool
    lastConnectionLosses: seq[JackConnectionCandidate]

  Vst3ReconfigurationReport* = object
    requestedFlags*: uint32
    appliedFlags*: uint32
    lifecycleTurns*: uint32
    latencySamples*: uint32
    sampleRate*: uint32
    bufferSize*: uint32
    metadataRefreshed*: bool
    midiMappingRebuilt*: bool
    jackConfigurationChanged*: bool
    componentReloaded*: bool
    connectionsLost*: seq[JackConnectionCandidate]

proc sliceError(message, path, pluginId, detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0: context.add("; " & detail)
  hostError(hsVst3, hekVst3Factory, message, context)

proc sliceError(message, path, pluginId: string): HostError =
  sliceError(message, path, pluginId, "")
proc sliceStateError(message, path, pluginId, detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0: context.add("; " & detail)
  hostError(hsState, hekState, message, context)

proc sliceStateError(message, path, pluginId: string): HostError =
  sliceStateError(message, path, pluginId, "")


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
  destination.services = source.services
  destination.transport = source.transport
  destination.activationLedger = source.activationLedger
  `=sink`(destination.plan, source.plan)
  `=sink`(destination.path, source.path)
  `=sink`(destination.pluginId, source.pluginId)
  destination.stateValue = source.stateValue
  destination.componentActive = source.componentActive
  destination.processorActive = source.processorActive
  destination.allowRetainedHostReferences = source.allowRetainedHostReferences
  `=sink`(destination.lastConnectionLosses, source.lastConnectionLosses)

proc state*(slice: Vst3AudioSlice): Vst3AudioSliceState {.inline.} =
  slice.stateValue
proc jackBackend*(slice: var Vst3AudioSlice): var JackBackend {.inline.} =
  slice.backend
proc portPlan*(slice: Vst3AudioSlice): PortPlan {.inline.} = slice.plan
proc instance*(slice: Vst3AudioSlice): Vst3Instance {.inline.} = slice.instance
proc connectionLosses*(slice: Vst3AudioSlice): seq[JackConnectionCandidate] =
  slice.lastConnectionLosses
proc takeFault*(slice: var Vst3AudioSlice): bool = slice.process.takeVst3ProcessFault()
proc drainParameterObservations*(slice: var Vst3AudioSlice): uint32 =
  slice.process.drainVst3ParameterObservations(slice.instance.controllerPointer())

proc drainParameterGestures*(slice: var Vst3AudioSlice;
                             destination: ptr UncheckedArray[
                               Vst3ParameterEditRecord];
                             capacity: uint32): uint32 =
  slice.process.drainVst3ParameterGestures(destination, capacity)
const
  Vst3UnsupportedReconfigurationFlags = uint32(
    Vst3RestartNoteExpressionChanged or Vst3RestartPrefetchChanged or
    Vst3RestartRoutingChanged or Vst3RestartKeyswitchChanged)
  Vst3ProcessReconfigurationFlags = uint32(
    Vst3RestartIoChanged or Vst3RestartIoTitlesChanged or
    Vst3RestartMidiCCChanged)
  Vst3MetadataReconfigurationFlags = uint32(
    Vst3RestartIoChanged or Vst3RestartIoTitlesChanged or
    Vst3RestartParamTitlesChanged)
  Vst3MaxReconfigurationTurns = 4'u32

proc reconfigurationError(message: string; slice: Vst3AudioSlice;
                           detail = ""): HostError =
  sliceError(message, slice.path, slice.pluginId, detail)

proc failSilentAfterReconfiguration(slice: var Vst3AudioSlice;
                                     primary: sink HostError): Result[Unit] =
  ## The replacement path never republishes callbacks after a failure.  Keep
  ## ownership intact so the regular close path can finish all resources.
  slice.stateValue = v3assQuiesced
  failure[Unit](move(primary))
proc failReconfiguration(slice: var Vst3AudioSlice;
                         primary: sink HostError):
                         Result[Vst3ReconfigurationReport] =

  var error = move(primary)
  if slice.backend.state == jbsActive:
    let suspended = slice.backend.suspendProcess()
    appendVst3CleanupError(error, suspended, "failure quiescence")
    if not suspended.isOk:
      return failure[Vst3ReconfigurationReport](move(error))
  if not slice.process.waitVst3ProcessQuiescence():
    error.context.add("; failure quiescence=VST3 process did not quiesce")
    return failure[Vst3ReconfigurationReport](move(error))
  if slice.processorActive:
    let stopped = setVst3Processing(slice.instance.processorPointer(), false)
    appendVst3CleanupError(error, stopped, "processor stop")
    if stopped.isOk:
      slice.processorActive = false
  slice.stateValue = v3assQuiesced
  failure[Vst3ReconfigurationReport](move(error))
proc failTerminalReconfiguration(slice: var Vst3AudioSlice;
                                  primary: sink HostError):
                                  Result[Unit] =
  ## Once the old instance/module has been torn down, no rollback instance
  ## exists.  Disable every callback/lifecycle edge and retain all remaining
  ## owners for the idempotent close path.
  var error = move(primary)
  if slice.backend.state == jbsActive:
    let suspended = slice.backend.suspendProcess()
    appendVst3CleanupError(error, suspended, "terminal failure quiescence")
    if not suspended.isOk:
      slice.stateValue = v3assFailed
      return failure[Unit](move(error))
  if not slice.process.waitVst3ProcessQuiescence():
    error.context.add("; terminal failure quiescence=VST3 process did not quiesce")
    slice.stateValue = v3assFailed
    return failure[Unit](move(error))
  if slice.processorActive and slice.instance != nil and
      slice.instance.processorPointer() != nil:
    let stopped = setVst3Processing(slice.instance.processorPointer(), false)
    appendVst3CleanupError(error, stopped, "terminal processor stop")
    if stopped.isOk:
      slice.processorActive = false
  if slice.componentActive and slice.instance != nil and
      slice.instance.componentPointer() != nil:
    let inactive = setVst3Active(slice.instance.componentPointer(), false)
    appendVst3CleanupError(error, inactive, "terminal component stop")
    if inactive.isOk:
      slice.componentActive = false
  slice.stateValue = v3assFailed
  failure[Unit](move(error))

proc serviceVst3ComponentReload(slice: var Vst3AudioSlice;
                                flags: uint32;
                                jackPending: bool;
                                report: var Vst3ReconfigurationReport;
                                beforeReload: proc(): Result[Unit] {.closure.} = nil):
                                Result[Unit] =
  let wasActive = slice.stateValue == v3assActive
  if wasActive:
    let suspended = slice.backend.suspendProcess()
    if not suspended.isOk:
      return suspended
  slice.stateValue = v3assQuiesced
  ## Keep a bounded edge snapshot before any old-instance teardown.  It is
  ## only published when the replacement proves structurally different, but
  ## remains available if a later structural step fails.
  var capturedConnections = slice.backend.snapshotConnections()
  if not capturedConnections.isOk:
    return failure[Unit](move(capturedConnections.error))
  if not slice.process.waitVst3ProcessQuiescence():
    return failure[Unit](reconfigurationError(
      "VST3 process did not quiesce before component reload", slice))
  if slice.processorActive:
    var stopped = setVst3Processing(slice.instance.processorPointer(), false)
    if not stopped.isOk:
      return slice.failSilentAfterReconfiguration(move(stopped.error))
    slice.processorActive = false
  if slice.componentActive:
    var inactive = setVst3Active(slice.instance.componentPointer(), false)
    if not inactive.isOk:
      return slice.failSilentAfterReconfiguration(move(inactive.error))
    slice.componentActive = false
  var busesStopped = deactivateVst3Buses(
    slice.instance.componentPointer(), slice.activationLedger)
  if not busesStopped.isOk:
    return slice.failSilentAfterReconfiguration(move(busesStopped.error))

  ## Capture is deliberately before destroying any old owner.  A failed
  ## capture leaves the old quiesced instance available to ordinary close.
  var captured = slice.instance.captureState()

  if not captured.isOk:
    return failure[Unit](move(captured.error))
  ## The callback runs after JACK/process quiescence and all old VST3
  ## lifecycle edges are stopped, but before any process, transport, instance,
  ## or module owner is closed.  A callback failure therefore leaves every
  ## old owner available to the normal close path.
  if beforeReload != nil:
    var callbackResult = beforeReload()
    if not callbackResult.isOk:
      return slice.failSilentAfterReconfiguration(
        move(callbackResult.error))
  let samplePosition = slice.process.samplePosition()
  let oldPlan = slice.plan

  let processClosed = slice.process.close()
  if not processClosed.isOk:
    return processClosed
  if slice.transport != nil:
    if not slice.instance.detachVst3ParameterTransport(slice.transport):
      return failure[Unit](reconfigurationError(
        "VST3 parameter transport ownership changed during reload", slice))
    closeVst3ParameterTransport(slice.transport)
    slice.transport = nil
  var oldClosed = slice.instance.close(slice.allowRetainedHostReferences)
  if not oldClosed.isOk:
    return slice.failTerminalReconfiguration(move(oldClosed.error))

  ## The old instance/module are fully gone before ModuleEntry or factory
  ## creation for the replacement.  The application services stay borrowed.
  var replacementCid = parseVst3Uid(slice.pluginId)
  if not replacementCid.isOk:
    return slice.failTerminalReconfiguration(move(replacementCid.error))
  var reopenedModule = openVst3Module(slice.path)
  if not reopenedModule.isOk:
    return slice.failTerminalReconfiguration(move(reopenedModule.error))
  var replacementModule = move(reopenedModule.value)
  var reopened = slice.services.openInstance(replacementModule,
    replacementCid.value)
  if not reopened.isOk:
    return slice.failTerminalReconfiguration(move(reopened.error))
  slice.instance = move(reopened.value)
  var restored = slice.instance.applyStateSnapshot(move(captured.value))
  if not restored.isOk:
    return slice.failTerminalReconfiguration(move(restored.error))
  slice.activationLedger = Vst3BusActivationLedger()
  var arrangements = setVst3BusArrangementsAndRequery(
    slice.instance.componentPointer(), slice.instance.processorPointer(),
    slice.path, slice.pluginId)
  if not arrangements.isOk:
    return slice.failTerminalReconfiguration(move(arrangements.error))
  var refreshedPlan = inspectVst3Ports(slice.instance.componentPointer(),
    slice.instance.processorPointer(), arrangements.value,
    portPlanVersion(oldPlan.version.value + 1'u64), slice.path, slice.pluginId)
  if not refreshedPlan.isOk:
    return slice.failTerminalReconfiguration(move(refreshedPlan.error))
  var refreshedMetadata = slice.instance.refreshMetadata()
  if not refreshedMetadata.isOk:
    return slice.failTerminalReconfiguration(move(refreshedMetadata.error))
  report.metadataRefreshed = true

  if jackPending:
    var runtime = slice.backend.refreshRuntimeConfiguration()
    if not runtime.isOk:
      return slice.failTerminalReconfiguration(move(runtime.error))
    var acknowledged = slice.backend.acknowledgeConfigurationChange()
    if not acknowledged.isOk:
      return slice.failTerminalReconfiguration(move(acknowledged.error))
    report.sampleRate = runtime.value.sampleRate
    report.bufferSize = runtime.value.bufferSize
    report.jackConfigurationChanged = true

  let structural = not sameJackPortLayout(oldPlan, refreshedPlan.value)
  if structural:
    slice.lastConnectionLosses = move(capturedConnections.value)
    report.connectionsLost = slice.lastConnectionLosses

  slice.transport = newVst3ParameterTransport()
  if slice.transport == nil:
    return slice.failTerminalReconfiguration(sliceError(
      "could not allocate VST3 parameter transport", slice.path, slice.pluginId))
  if not slice.instance.attachVst3ParameterTransport(slice.transport):
    closeVst3ParameterTransport(slice.transport)
    slice.transport = nil
    return slice.failTerminalReconfiguration(sliceError(
      "could not attach VST3 parameter transport", slice.path, slice.pluginId))
  var processResult = newVst3AudioProcess(
    slice.instance.processorPointer(), slice.instance.componentPointer(),
    refreshedPlan.value, slice.transport, slice.backend.bufferSize(),
    slice.backend.sampleRate(), slice.backend.audioRoleGuard(), slice.path,
    slice.pluginId, samplePosition, controller = slice.instance.controllerPointer())
  if not processResult.isOk:
    return slice.failTerminalReconfiguration(move(processResult.error))
  slice.process = move(processResult.value)

  if structural:
    var deactivated = slice.backend.deactivate()
    if not deactivated.isOk:
      return slice.failTerminalReconfiguration(move(deactivated.error))
    var rebuilt = slice.backend.reconfigure(refreshedPlan.value,
      slice.process.endpoint())
    if not rebuilt.isOk:
      return slice.failTerminalReconfiguration(move(rebuilt.error))
  else:
    var updated = slice.backend.updateProcessEndpoint(slice.process.endpoint())
    if not updated.isOk:
      return slice.failTerminalReconfiguration(move(updated.error))
  slice.plan = move(refreshedPlan.value)

  var latency = slice.instance.processorLatencySamples()
  if not latency.isOk:
    return slice.failTerminalReconfiguration(move(latency.error))
  var published = slice.backend.setPluginLatency(latency.value)
  if not published.isOk:
    return slice.failTerminalReconfiguration(move(published.error))
  report.latencySamples = latency.value

  if wasActive:
    var activatedBuses = activateVst3Buses(
      slice.instance.componentPointer(), slice.activationLedger)
    if not activatedBuses.isOk:
      return slice.failTerminalReconfiguration(move(activatedBuses.error))
    var active = setVst3Active(slice.instance.componentPointer(), true)
    if not active.isOk:
      return slice.failTerminalReconfiguration(move(active.error))
    slice.componentActive = true
    var processing = setVst3Processing(slice.instance.processorPointer(), true)
    if not processing.isOk:
      return slice.failTerminalReconfiguration(move(processing.error))
    slice.processorActive = true
    var activated = slice.backend.activate()
    if not activated.isOk:
      return slice.failTerminalReconfiguration(move(activated.error))
    var recomputed = slice.backend.recomputeLatencies()
    if not recomputed.isOk:
      return slice.failTerminalReconfiguration(move(recomputed.error))
    slice.stateValue = v3assActive
  report.midiMappingRebuilt = true
  report.componentReloaded = true
  report.appliedFlags = report.appliedFlags or flags
  success()


proc refreshVst3Plan(slice: Vst3AudioSlice; ioChanged: bool;
                     ioTitlesChanged: bool): Result[PortPlan] =
  if not ioChanged and not ioTitlesChanged:
    return success(slice.plan)
  var arrangements: Result[seq[Vst3SpeakerArrangement]]
  if ioChanged:
    arrangements = setVst3BusArrangementsAndRequery(
      slice.instance.componentPointer(), slice.instance.processorPointer(),
      slice.path, slice.pluginId)
  else:
    arrangements = currentVst3Arrangements(
      slice.instance.componentPointer(), slice.instance.processorPointer(),
      slice.path, slice.pluginId)
  if not arrangements.isOk:
    return failure[PortPlan](move(arrangements.error))
  inspectVst3Ports(slice.instance.componentPointer(),
    slice.instance.processorPointer(), arrangements.value,
    portPlanVersion(slice.plan.version.value + 1'u64),
    slice.path, slice.pluginId)

proc serviceVst3Latency(slice: var Vst3AudioSlice;
                        wasActive: bool;
                        report: var Vst3ReconfigurationReport): Result[Unit] =
  if wasActive:
    let suspended = slice.backend.suspendProcess()
    if not suspended.isOk:
      return suspended
  var latency = slice.instance.processorLatencySamples()
  if not latency.isOk:
    slice.stateValue = v3assQuiesced
    return failure[Unit](move(latency.error))
  let published = slice.backend.setPluginLatency(latency.value)
  if not published.isOk:
    slice.stateValue = v3assQuiesced
    return published
  report.latencySamples = latency.value
  if wasActive:
    let resumed = slice.backend.activate()
    if not resumed.isOk:
      slice.stateValue = v3assQuiesced
      return resumed
    let recomputed = slice.backend.recomputeLatencies()
    if not recomputed.isOk:
      discard slice.backend.suspendProcess()
      slice.stateValue = v3assQuiesced
      return recomputed
  success()

proc serviceVst3ReconfigurationTurn(slice: var Vst3AudioSlice;
                                    flags: uint32;
                                    jackPending: bool;
                                    report: var Vst3ReconfigurationReport;
                                    beforeReload: proc(): Result[Unit] {.closure.} = nil):
                                    Result[Unit] =
  let reload = flags and uint32(Vst3RestartReloadComponent)
  if reload != 0'u32:
    return slice.serviceVst3ComponentReload(flags, jackPending, report,
      beforeReload)
  let unsupported = flags and Vst3UnsupportedReconfigurationFlags
  if unsupported != 0'u32:
    return failure[Unit](reconfigurationError(
      "VST3 restart requested unsupported behavior", slice,
      "flags=0x" & toHex(unsupported, 8)))
  let valuesOnly =
    (flags and uint32(Vst3RestartParamValuesChanged)) != 0'u32
  let titlesChanged =
    (flags and uint32(Vst3RestartParamTitlesChanged)) != 0'u32
  let ioChanged = (flags and uint32(Vst3RestartIoChanged)) != 0'u32
  let ioTitlesChanged =
    (flags and uint32(Vst3RestartIoTitlesChanged)) != 0'u32
  let midiChanged = (flags and uint32(Vst3RestartMidiCCChanged)) != 0'u32
  let latencyChanged =
    (flags and uint32(Vst3RestartLatencyChanged)) != 0'u32
  if valuesOnly:
    report.appliedFlags = report.appliedFlags or
      uint32(Vst3RestartParamValuesChanged)
  if titlesChanged and not ioChanged and not ioTitlesChanged:
    let refreshed = slice.instance.refreshMetadata()
    if not refreshed.isOk:
      return refreshed
    report.metadataRefreshed = true
    report.appliedFlags = report.appliedFlags or
      uint32(Vst3RestartParamTitlesChanged)
  if latencyChanged and not (ioChanged or ioTitlesChanged or midiChanged or
      jackPending):
    let wasActive = slice.stateValue == v3assActive
    let updated = slice.serviceVst3Latency(wasActive, report)
    if not updated.isOk:
      return updated
    report.appliedFlags = report.appliedFlags or
      uint32(Vst3RestartLatencyChanged)
    return success()
  if not (ioChanged or ioTitlesChanged or midiChanged or jackPending):
    return success()

  let wasActive = slice.stateValue == v3assActive
  if wasActive:
    let suspended = slice.backend.suspendProcess()
    if not suspended.isOk:
      return suspended
  slice.stateValue = v3assQuiesced
  if slice.processorActive:
    var stopped = setVst3Processing(slice.instance.processorPointer(), false)
    if not stopped.isOk:
      return slice.failSilentAfterReconfiguration(move(stopped.error))
    slice.processorActive = false
  if slice.componentActive:
    var inactive = setVst3Active(slice.instance.componentPointer(), false)
    if not inactive.isOk:
      return slice.failSilentAfterReconfiguration(move(inactive.error))
    slice.componentActive = false
  var busesStopped = deactivateVst3Buses(
    slice.instance.componentPointer(), slice.activationLedger)
  if not busesStopped.isOk:
    return slice.failSilentAfterReconfiguration(move(busesStopped.error))

  if jackPending:
    var runtime = slice.backend.refreshRuntimeConfiguration()
    if not runtime.isOk:
      return slice.failSilentAfterReconfiguration(move(runtime.error))
    var acknowledged = slice.backend.acknowledgeConfigurationChange()
    if not acknowledged.isOk:
      return slice.failSilentAfterReconfiguration(move(acknowledged.error))
    report.sampleRate = runtime.value.sampleRate
    report.bufferSize = runtime.value.bufferSize
    report.jackConfigurationChanged = true

  var newPlan = slice.refreshVst3Plan(ioChanged, ioTitlesChanged)
  if not newPlan.isOk:
    return slice.failSilentAfterReconfiguration(move(newPlan.error))
  if ioChanged or ioTitlesChanged:
    var refreshed = slice.instance.refreshMetadata()
    if not refreshed.isOk:
      return slice.failSilentAfterReconfiguration(move(refreshed.error))
    report.metadataRefreshed = true
    report.appliedFlags = report.appliedFlags or
      (flags and Vst3MetadataReconfigurationFlags)
  var replacementResult = newVst3AudioProcess(
    slice.instance.processorPointer(), slice.instance.componentPointer(),
    newPlan.value, slice.transport, slice.backend.bufferSize(),
    slice.backend.sampleRate(), slice.backend.audioRoleGuard(), slice.path,
    slice.pluginId, slice.process.samplePosition(),
    controller = slice.instance.controllerPointer())
  if not replacementResult.isOk:
    return slice.failSilentAfterReconfiguration(move(replacementResult.error))
  var replacement = move(replacementResult.value)
  let structural = (ioChanged or ioTitlesChanged) and
    not sameJackPortLayout(slice.plan, newPlan.value)
  if structural:
    var snapshot = slice.backend.snapshotConnections()
    if not snapshot.isOk:
      discard replacement.close()
      return slice.failSilentAfterReconfiguration(move(snapshot.error))
    slice.lastConnectionLosses = move(snapshot.value)
    var deactivated = slice.backend.deactivate()
    if not deactivated.isOk:
      discard replacement.close()
      return slice.failSilentAfterReconfiguration(move(deactivated.error))
    var rebuilt = slice.backend.reconfigure(newPlan.value, replacement.endpoint())
    if not rebuilt.isOk:
      discard replacement.close()
      return slice.failSilentAfterReconfiguration(move(rebuilt.error))
    report.connectionsLost = slice.lastConnectionLosses
  else:
    var updated = slice.backend.updateProcessEndpoint(replacement.endpoint())
    if not updated.isOk:
      discard replacement.close()
      return slice.failSilentAfterReconfiguration(move(updated.error))

  var previous = move(slice.process)
  var previousClosed = previous.close()
  slice.process = move(replacement)
  slice.plan = move(newPlan.value)
  if not previousClosed.isOk:
    return slice.failSilentAfterReconfiguration(move(previousClosed.error))
  report.midiMappingRebuilt = midiChanged
  report.appliedFlags = report.appliedFlags or
    (flags and Vst3ProcessReconfigurationFlags)
  if latencyChanged:
    report.appliedFlags = report.appliedFlags or
      uint32(Vst3RestartLatencyChanged)

  var latency = slice.instance.processorLatencySamples()
  if not latency.isOk:
    return slice.failSilentAfterReconfiguration(move(latency.error))
  var published = slice.backend.setPluginLatency(latency.value)
  if not published.isOk:
    return slice.failSilentAfterReconfiguration(move(published.error))
  report.latencySamples = latency.value
  if wasActive:
    var activatedBuses = activateVst3Buses(
      slice.instance.componentPointer(), slice.activationLedger)
    if not activatedBuses.isOk:
      return slice.failSilentAfterReconfiguration(move(activatedBuses.error))
    var active = setVst3Active(slice.instance.componentPointer(), true)
    if not active.isOk:
      return slice.failSilentAfterReconfiguration(move(active.error))
    slice.componentActive = true
    var processing = setVst3Processing(slice.instance.processorPointer(), true)
    if not processing.isOk:
      discard setVst3Active(slice.instance.componentPointer(), false)
      slice.componentActive = false
      discard deactivateVst3Buses(slice.instance.componentPointer(),
        slice.activationLedger)
      return slice.failSilentAfterReconfiguration(move(processing.error))
    slice.processorActive = true
    var activated = slice.backend.activate()
    if not activated.isOk:
      var activationError = move(activated.error)
      let stopped = setVst3Processing(slice.instance.processorPointer(), false)
      appendVst3CleanupError(activationError, stopped, "processor rollback")
      if stopped.isOk:
        slice.processorActive = false
      let inactive = setVst3Active(slice.instance.componentPointer(), false)
      appendVst3CleanupError(activationError, inactive, "component rollback")
      if inactive.isOk:
        slice.componentActive = false
      let busesInactive = deactivateVst3Buses(
        slice.instance.componentPointer(), slice.activationLedger)
      appendVst3CleanupError(activationError, busesInactive, "bus rollback")
      return slice.failSilentAfterReconfiguration(move(activationError))
    var recomputed = slice.backend.recomputeLatencies()
    if not recomputed.isOk:
      var latencyError = move(recomputed.error)
      let suspended = slice.backend.suspendProcess()
      appendVst3CleanupError(latencyError, suspended, "JACK suspension")
      if suspended.isOk:
        let stopped = setVst3Processing(
          slice.instance.processorPointer(), false)
        appendVst3CleanupError(latencyError, stopped, "processor rollback")
        if stopped.isOk:
          slice.processorActive = false
        let inactive = setVst3Active(
          slice.instance.componentPointer(), false)
        appendVst3CleanupError(latencyError, inactive, "component rollback")
        if inactive.isOk:
          slice.componentActive = false
        let busesInactive = deactivateVst3Buses(
          slice.instance.componentPointer(), slice.activationLedger)
        appendVst3CleanupError(latencyError, busesInactive, "bus rollback")
      return slice.failSilentAfterReconfiguration(move(latencyError))
    slice.stateValue = v3assActive
  success()

proc serviceReconfiguration*(slice: var Vst3AudioSlice;
                             beforeReload: proc(): Result[Unit] {.closure.} = nil):
    Result[Vst3ReconfigurationReport] =
  if slice.stateValue notin {v3assActive, v3assQuiesced}:
    return failure[Vst3ReconfigurationReport](reconfigurationError(
      "VST3 reconfiguration requires an active or quiesced slice", slice,
      "state=" & $slice.stateValue))
  var report = Vst3ReconfigurationReport()
  slice.lastConnectionLosses.setLen(0)
  while true:
    let flags = slice.instance.takeRestartFlags()
    let jackPending = slice.backend.configurationChangePending()
    if flags == 0'u32 and not jackPending:
      return success(move(report))
    if report.lifecycleTurns >= Vst3MaxReconfigurationTurns:
      slice.instance.restoreRestartFlags(flags)
      return slice.failReconfiguration(reconfigurationError(
        "VST3 reconfiguration request limit exceeded", slice,
        "limit=" & $Vst3MaxReconfigurationTurns &
        "; deferred-flags=0x" & toHex(flags, 8)))
    inc report.lifecycleTurns
    report.requestedFlags = report.requestedFlags or flags
    var serviced = serviceVst3ReconfigurationTurn(slice, flags, jackPending,
      report, beforeReload)
    if not serviced.isOk:
      if slice.stateValue == v3assFailed:
        return failure[Vst3ReconfigurationReport](move(serviced.error))
      return slice.failReconfiguration(move(serviced.error))
proc takeEventMetrics*(slice: var Vst3AudioSlice): Vst3EventMetrics =
  slice.process.eventMetrics()



proc openVst3AudioSlice*(services: Vst3PluginServices;
                        module: var Vst3Module; classId: Vst3Tuid;
                        backendConfig: JackBackendOpenConfig;
                        loadStatePath = "";
                        allowRetainedHostReferences = false):
                        Result[Vst3AudioSlice] =
  if services == nil:
    return failure[Vst3AudioSlice](sliceError(
      "VST3 audio slice requires application-owned services", "", ""))
  let bundlePath = module.bundlePath()
  let pluginId = formatVst3Uid(classId)
  var opened = services.openInstance(module, classId, loadStatePath)
  if not opened.isOk:
    return failure[Vst3AudioSlice](move(opened.error))
  var slice = Vst3AudioSlice(instance: opened.value,
    services: services,
    path: bundlePath, pluginId: pluginId,
    allowRetainedHostReferences: allowRetainedHostReferences,
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
  var initialLatency = slice.instance.processorLatencySamples()
  if not initialLatency.isOk:
    var latencyError = move(initialLatency.error)
    let rollback = deactivateVst3Buses(
      slice.instance.componentPointer(), slice.activationLedger)
    appendVst3CleanupError(latencyError, rollback, "bus rollback")
    discard slice.process.close()
    discard slice.backend.close()
    discard slice.instance.detachVst3ParameterTransport(slice.transport)
    closeVst3ParameterTransport(slice.transport)
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(latencyError))
  var publishedLatency = slice.backend.setPluginLatency(initialLatency.value)
  if not publishedLatency.isOk:
    var latencyError = move(publishedLatency.error)
    let rollback = deactivateVst3Buses(
      slice.instance.componentPointer(), slice.activationLedger)
    appendVst3CleanupError(latencyError, rollback, "bus rollback")
    discard slice.process.close()
    discard slice.backend.close()
    discard slice.instance.detachVst3ParameterTransport(slice.transport)
    closeVst3ParameterTransport(slice.transport)
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(latencyError))
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
  var recomputed = slice.backend.recomputeLatencies()
  if not recomputed.isOk:
    var latencyError = move(recomputed.error)
    ## JACK must stop invoking the endpoint before the plugin lifecycle changes.
    let jackStopped = slice.backend.deactivate()
    appendVst3CleanupError(latencyError, jackStopped, "JACK rollback")
    if jackStopped.isOk:
      let processingStopped = setVst3Processing(
        slice.instance.processorPointer(), false)
      appendVst3CleanupError(
        latencyError, processingStopped, "processor rollback")
      if processingStopped.isOk:
        slice.processorActive = false
        let componentStopped = setVst3Active(
          slice.instance.componentPointer(), false)
        appendVst3CleanupError(
          latencyError, componentStopped, "component rollback")
        if componentStopped.isOk:
          slice.componentActive = false
          let busesStopped = deactivateVst3Buses(
            slice.instance.componentPointer(), slice.activationLedger)
          appendVst3CleanupError(latencyError, busesStopped, "bus rollback")
    discard slice.backend.close()
    discard slice.process.close()
    discard slice.instance.detachVst3ParameterTransport(slice.transport)
    closeVst3ParameterTransport(slice.transport)
    discard slice.instance.close()
    return failure[Vst3AudioSlice](move(latencyError))
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
  # A failed reconfiguration can be quiesced at the application level while
  # the JACK client remains active with callbacks suspended and the processor
  # still owns an active lifecycle edge. Reconcile those edges before teardown.
  if slice.backend.state == jbsActive:
    let deactivatedBackend = slice.backend.deactivate()
    if not deactivatedBackend.isOk:
      return deactivatedBackend
  if slice.processorActive:
    if not slice.process.waitVst3ProcessQuiescence():
      return failure[Unit](sliceError("VST3 process did not quiesce",
        slice.path, slice.pluginId))
    let stoppedProcessor = setVst3Processing(
      slice.instance.processorPointer(), false)
    if not stoppedProcessor.isOk:
      return stoppedProcessor
    slice.processorActive = false
    slice.stateValue = v3assQuiesced
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
    slice.transport = nil
  let backendClosed = slice.backend.close()
  if not backendClosed.isOk:
    return backendClosed
  let instanceClosed = slice.instance.close(
    slice.allowRetainedHostReferences)
  if not instanceClosed.isOk:
    return instanceClosed
  slice.stateValue = v3assClosed
  success()

proc saveState*(slice: var Vst3AudioSlice; path: string): Result[Unit] =
  if slice.stateValue in {v3assEmpty, v3assClosed}:
    return failure[Unit](sliceStateError("VST3 state save requires an open slice",
      slice.path, slice.pluginId))
  if slice.stateValue != v3assQuiesced:
    return failure[Unit](sliceStateError("VST3 state save requires a quiesced slice",
      slice.path, slice.pluginId, "state=" & $slice.stateValue))
  if slice.componentActive:
    let inactive = setVst3Active(slice.instance.componentPointer(), false)
    if not inactive.isOk:
      return failure[Unit](sliceStateError(
        "VST3 component deactivation failed before state save",
        slice.path, slice.pluginId, inactive.error.message &
        (if inactive.error.context.len > 0: " (" & inactive.error.context & ")"
         else: "")))
    slice.componentActive = false
  var captured = slice.instance.captureState()
  if not captured.isOk: return failure[Unit](move(captured.error))
  writeVst3Preset(path, slice.instance.selectedClassId(),
    captured.value.component, captured.value.controller,
    captured.value.hasController)
