import std/[monotimes, options]

import ./[audio_slice, main_reactor, plugin_services, run_config, vst3_audio_slice]
import ./vst3_plugin_services
import ../clap/[event_bridge, ffi, loader, main_thread_services]
import ../gui/[controller, icon, icon_loader, tray_controller, plugin_client]
import ../platform/dbus/tray_icon
import ../platform/x11/gui_adapter
import ../domain/[errors, lifecycle, plugin_catalog, reactor, result]
import ../jack/backend
import ../platform/linux/[pid_file, process_name, reactor as linux_reactor, signals]
import ../support/[diagnostics, names, utf8]
import ../vst3/catalog as vst3_catalog
import ../vst3/event_bridge as vst3_event_bridge
import ../vst3/gui_client as vst3_gui_client
import ../vst3/host_context
import ../vst3/module
import ../vst3/uid
import ../vst3/parameter_transport

const
  ControlServiceNanos = 16_000_000'i64
  MaxPluginLogsPerTurn = 64
  MaxConsecutiveRestarts = 4'u32


type
  SignalTurn = object
    intents: seq[SignalIntent]
    shutdown: bool

  HostSession* = object
    state*: SessionState
    format: PluginFormat
    audioSlice: InternalAudioSlice
    vst3Slice: Vst3AudioSlice
    compositionServices: PluginServiceAdapter
    gui: GuiController
    tray: TrayController
    guiIcon: GuiIcon
    reactor: MainReactor
    signalSource: SignalSource
    signalToken: ReactorToken
    pidFile: PidFile
    pluginServices: PluginServiceRegistry
    vst3Services: Vst3PluginServices
    warningLimiter: WarningLimiter
    lastXruns: uint64
    lastFreewheelChanges: uint64
    stateDirty: bool
    consecutiveRestarts: uint32
    saveStatePath: Option[string]
    pluginPathValue: string
    pluginIdValue: string
    pluginNameValue: string

proc initHostSession*(): HostSession =
  HostSession(state: ssNew, format: pfClap,
    warningLimiter: initWarningLimiter())

proc hasDirtyState*(session: HostSession): bool {.inline.} =
  session.stateDirty

proc attachInternalAudioSlice*(session: var HostSession;
                               slice: var InternalAudioSlice): Result[Unit] =
  if session.state != ssNew or session.audioSlice.state != iassEmpty or
      session.vst3Slice.state != v3assEmpty or slice.state != iassReady:
    return failure[Unit](transitionError(
      "an internal audio slice can only be attached to an empty new session",
      $session.state & "; attached=" & $session.audioSlice.state &
        "; slice=" & $slice.state,
    ))
  session.format = pfClap
  session.audioSlice = move(slice)
  session.compositionServices = session.audioSlice.pluginServiceAdapter()
  success()

proc attachVst3AudioSlice*(session: var HostSession;
                           slice: var Vst3AudioSlice;
                           services: Vst3PluginServices;
                           path, pluginId, pluginName: string): Result[Unit] =
  if session.state != ssNew or session.audioSlice.state != iassEmpty or
      session.vst3Slice.state != v3assEmpty or
      slice.state notin {v3assReady, v3assActive}:
    return failure[Unit](transitionError(
      "a VST3 audio slice can only be attached to an empty new session",
      $session.state & "; slice=" & $slice.state,
    ))
  session.format = pfVst3
  session.vst3Slice = move(slice)
  session.vst3Services = services
  session.pluginPathValue = path
  session.pluginIdValue = pluginId
  session.pluginNameValue = pluginName
  session.compositionServices = vst3PluginServiceAdapter(services)
  success()
proc isVst3(session: HostSession): bool {.inline.} =
  session.format == pfVst3

proc activePath(session: HostSession): string =
  if session.isVst3: session.pluginPathValue else: session.audioSlice.pluginPath

proc activePluginId(session: HostSession): string =
  if session.isVst3: session.pluginIdValue else: session.audioSlice.pluginId

proc activePluginName(session: HostSession): string =
  if session.isVst3: session.pluginNameValue else: session.audioSlice.pluginName

proc startInternalAudio*(session: var HostSession): Result[Unit] =
  if session.state != ssNew:
    return failure[Unit](transitionError(
      "an audio slice can only start from a new session",
      $session.state,
    ))
  if session.isVst3:
    if session.vst3Slice.state notin {v3assReady, v3assActive}:
      return failure[Unit](transitionError(
        "a VST3 audio slice is not ready to start",
        $session.state & "; slice=" & $session.vst3Slice.state,
      ))
  elif session.audioSlice.state != iassReady:
    return failure[Unit](transitionError(
      "an internal audio slice can only start from a new ready session",
      $session.state & "; slice=" & $session.audioSlice.state,
    ))
  var starting = session.state.transition(ssStarting)
  if not starting.isOk:
    return starting
  if not session.isVst3:
    var started = session.audioSlice.start()
    if not started.isOk:
      discard session.state.transition(ssFailed)
      return started
  session.state.transition(ssRunning)

proc stopInternalAudio*(session: var HostSession): Result[Unit] =
  if session.state != ssRunning:
    return failure[Unit](transitionError(
      "an audio slice can only stop from a running session",
      $session.state,
    ))
  var stopping = session.state.transition(ssStopping)
  if not stopping.isOk:
    return stopping
  var stopped = if session.isVst3: session.vst3Slice.stop()
               else: session.audioSlice.stop()
  if not stopped.isOk:
    discard session.state.transition(ssFailed)
    return stopped
  session.state.transition(ssStopped)

proc failSession[T](session: var HostSession; error: sink HostError): Result[T] =
  case session.state
  of ssNew:
    discard session.state.transition(ssStarting)
    discard session.state.transition(ssFailed)
  of ssStarting, ssRunning:
    discard session.state.transition(ssFailed)
  else:
    discard
  failure[T](move(error))

proc validateAvailableRunOptions(config: RunConfig): Result[Unit] =
  if config.guiPolicy == gpDisabled and config.guiScale.isSome:
    return failure[Unit](usageError(
      "--gui-scale cannot be used with --no-gui"))
  success()

proc cleanupModuleFailure(module: var ClapModule;
                          primary: sink HostError): HostError =
  var closed = module.close()
  if closed.isOk:
    return move(primary)
  closed.error.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    closed.error.context.add(" (" & primary.context & ")")
  move(closed.error)

proc openRunSlice(config: RunConfig;
                  mainServices: ptr ClapMainThreadServices):
    Result[InternalAudioSlice] =
  # A running plugin may own foreign threads whose code can outlive the host's
  # orderly teardown. Keep this runtime DSO mapped after its handle is closed.
  var moduleResult = openClapModule(config.pluginPath, keepLoaded = true)
  if not moduleResult.isOk:
    return failure[InternalAudioSlice](move(moduleResult.error))
  var module = move(moduleResult.value)

  var catalog = module.readCatalog()
  if not catalog.isOk:
    return failure[InternalAudioSlice](module.cleanupModuleFailure(
      move(catalog.error)))
  var selected = catalog.value.selectDescriptor(config.selector)
  if not selected.isOk:
    return failure[InternalAudioSlice](module.cleanupModuleFailure(
      move(selected.error)))

  let requestedName = if config.clientName.isSome:
      config.clientName.get()
    else:
      defaultJackClientName(selected.value.name)
  let backendConfig = initJackBackendOpenConfig(
    requestedName,
    serverName = config.jackServer,
    noStartServer = config.noStartServer,
  )
  openInternalAudioSlice(
    move(module), move(selected.value), backendConfig, mainServices,
    if config.loadStatePath.isSome: config.loadStatePath.get() else: "",
    config.guiPolicy != gpDisabled)
proc openRunVst3Slice(config: RunConfig; services: Vst3PluginServices;
                      descriptor: var PluginDescriptor):
    Result[Vst3AudioSlice] =
  var catalog = vst3_catalog.loadVst3Catalog(config.pluginPath)
  if not catalog.isOk:
    return failure[Vst3AudioSlice](move(catalog.error))
  var selected = catalog.value.selectDescriptor(config.selector)
  if not selected.isOk:
    return failure[Vst3AudioSlice](move(selected.error))
  descriptor = selected.value
  var classId = parseVst3Uid(descriptor.id)
  if not classId.isOk:
    return failure[Vst3AudioSlice](move(classId.error))
  var moduleResult = openVst3Module(config.pluginPath, keepLoaded = true)
  if not moduleResult.isOk:
    return failure[Vst3AudioSlice](move(moduleResult.error))
  var module = move(moduleResult.value)
  let requestedName = if config.clientName.isSome:
      config.clientName.get()
    else:
      defaultJackClientName(descriptor.name)
  let backendConfig = initJackBackendOpenConfig(
    requestedName,
    serverName = config.jackServer,
    noStartServer = config.noStartServer,
  )
  openVst3AudioSlice(
    services, module, classId.value, backendConfig,
    if config.loadStatePath.isSome: config.loadStatePath.get() else: "",
    allowRetainedHostReferences = true)

proc writeWarning(errorOutput: File; message: string) =
  errorOutput.write("pluginhost: warning: " & escapeControlText(message) & "\n")

proc emitWarning(session: var HostSession; kind: WarningKind;
                 errorOutput: File; message: string) =
  let emission = session.warningLimiter.reportWarning(
    kind, getMonoTime().ticks, message)
  if not emission.emitted:
    return
  var rendered = emission.message
  if emission.suppressed > 0'u64:
    rendered.add(" (suppressed=" & $emission.suppressed & ")")
  errorOutput.writeWarning(rendered)

proc flushWarnings(session: var HostSession; errorOutput: File) =
  for emission in session.warningLimiter.flushWarnings():
    errorOutput.writeWarning(emission.message)

proc saturatingAdd(left, right: uint64): uint64 =
  if high(uint64) - left < right:
    high(uint64)
  else:
    left + right

proc addEventMetricDetail(details: var string; label: string; count: uint64) =
  if count == 0'u64:
    return
  if details.len > 0:
    details.add(", ")
  details.add(label & "=" & $count)

proc eventMetricsWarningMessage*(metrics: ClapEventMetrics): string =
  var total = 0'u64
  total = total.saturatingAdd(metrics.inputCapacityDrops)
  total = total.saturatingAdd(metrics.invalidInput)
  total = total.saturatingAdd(metrics.malformedInput)
  total = total.saturatingAdd(metrics.outputCapacityDrops)
  total = total.saturatingAdd(metrics.invalidOutput)
  total = total.saturatingAdd(metrics.jackLostInput)
  if total == 0'u64:
    return ""

  var details = ""
  details.addEventMetricDetail("input-overflow", metrics.inputCapacityDrops)
  details.addEventMetricDetail("input-invalid", metrics.invalidInput)
  details.addEventMetricDetail("input-malformed", metrics.malformedInput)
  details.addEventMetricDetail("output-overflow", metrics.outputCapacityDrops)
  details.addEventMetricDetail("output-invalid", metrics.invalidOutput)
  details.addEventMetricDetail("jack-input-lost", metrics.jackLostInput)
  result = "audio event bridge dropped or rejected " & $total & " events"
  if details.len > 0:
    result.add(" (" & details & ")")
proc vst3EventMetricsWarningMessage*(metrics: vst3_event_bridge.Vst3EventMetrics):
    string =
  var total = 0'u64
  for value in [metrics.inputCapacityDrops, metrics.droppedInput,
                metrics.malformedInput, metrics.unmappedInput,
                metrics.jackLostInput, metrics.droppedOutput,
                metrics.invalidOutput, metrics.unsupportedOutput,
                metrics.outputCapacityDrops, metrics.parameterInputDrops,
                metrics.parameterOutputDrops]:
    total = total.saturatingAdd(value)
  if total == 0'u64:
    return ""
  var details = ""
  details.addEventMetricDetail("input-overflow", metrics.inputCapacityDrops)
  details.addEventMetricDetail("input-dropped", metrics.droppedInput)
  details.addEventMetricDetail("input-malformed", metrics.malformedInput)
  details.addEventMetricDetail("input-unmapped", metrics.unmappedInput)
  details.addEventMetricDetail("output-dropped", metrics.droppedOutput)
  details.addEventMetricDetail("output-overflow", metrics.outputCapacityDrops)
  details.addEventMetricDetail("output-invalid", metrics.invalidOutput)
  details.addEventMetricDetail("output-unsupported", metrics.unsupportedOutput)
  details.addEventMetricDetail("jack-input-lost", metrics.jackLostInput)
  details.addEventMetricDetail("parameter-input", metrics.parameterInputDrops)
  details.addEventMetricDetail("parameter-output", metrics.parameterOutputDrops)
  result = "VST3 audio event bridge dropped or rejected " & $total & " events"
  if details.len > 0:
    result.add(" (" & details & ")")


proc pluginLogSeverity(severity: PluginLogSeverity): string =
  case severity
  of plsDebug: "debug"
  of plsInfo: "info"
  of plsWarning: "warning"
  of plsError: "error"
  of plsFatal: "fatal"
  of plsHostMisbehaving: "host-misbehaving"
  of plsPluginMisbehaving: "plugin-misbehaving"

proc drainPluginLogs(session: var HostSession; config: RunConfig;
                     errorOutput: File) =
  var count = 0
  var message: PluginLogMessage
  while count < MaxPluginLogsPerTurn and
      session.audioSlice.tryTakePluginLog(message):
    if config.verbosity != vbQuiet or
        message.severity in {plsError, plsFatal, plsHostMisbehaving,
                             plsPluginMisbehaving}:
      errorOutput.write("pluginhost: CLAP " & message.severity.pluginLogSeverity &
        " [" & escapeControlText(session.audioSlice.pluginId) & "]: " &
        escapeControlText(message.text) & "\n")
    inc count
  let dropped = session.audioSlice.takeDroppedPluginLogs()
  if dropped > 0'u64 and config.verbosity != vbQuiet:
    session.emitWarning(wkPluginLogDrops, errorOutput,
      "CLAP log queue dropped " & $dropped & " messages")

proc drainSignals(session: var HostSession; events: seq[ReactorEvent]):
    Result[SignalTurn] =
  var signalReady = false
  for event in events:
    if event.kind == rekFd and event.token == session.signalToken:
      if riError in event.interests or riHangup in event.interests:
        return failure[SignalTurn](hostError(
          hsPlatform, hekSignal, "Linux signal descriptor failed"))
      signalReady = true
  if not signalReady:
    return success(SignalTurn())

  var drained = session.signalSource.drain()
  if not drained.isOk:
    return failure[SignalTurn](move(drained.error))
  var turn = SignalTurn(intents: move(drained.value))
  for intent in turn.intents:
    case intent
    of siInterrupt, siTerminate:
      turn.shutdown = true
    else:
      discard
  success(move(turn))

proc serviceGuiSignalActions(session: var HostSession; config: RunConfig;
                             intents: openArray[SignalIntent];
                             errorOutput: File): Result[Unit] =
  for intent in intents:
    case intent
    of siInterrupt, siTerminate:
      discard
    of siShowGui, siHideGui:
      let operation = if intent == siShowGui: "show" else: "hide"
      let kind = if intent == siShowGui: wkGuiShow else: wkGuiHide
      if session.gui == nil:
        if config.verbosity != vbQuiet:
          session.emitWarning(kind, errorOutput, "SIGUSR request to " & operation &
            " the GUI is unavailable while GUI hosting is disabled")
      else:
        var action = if intent == siShowGui: session.gui.show()
                     else: session.gui.hide()
        if not action.isOk:
          if config.requireGui:
            return failure[Unit](move(action.error))
          if config.verbosity != vbQuiet:
            session.emitWarning(wkGuiFailure, errorOutput,
              "could not " & operation &
              " the plugin GUI; continuing headless: " & action.error.message)
  success()

proc servicePluginEvents(session: var HostSession; events: seq[ReactorEvent]):
    Result[Unit] =
  if session.isVst3:
    if session.vst3Services != nil:
      session.vst3Services.context().dispatchRunLoopEvents(events)
    return success()
  if session.pluginServices == nil:
    return success()
  for event in events:
    let serviceEvent = session.pluginServices.classify(event)
    if serviceEvent.isNone:
      continue
    case serviceEvent.get.kind
    of psekTimer:
      var called = session.audioSlice.callOnTimer(serviceEvent.get.timerId)
      if not called.isOk:
        return called
      var completed = session.pluginServices.completeTimerDispatch(
        serviceEvent.get.timerId)
      if not completed.isOk:
        return completed
    of psekFd:
      if serviceEvent.get.fdFlags != 0'u32:
        var called = session.audioSlice.callOnFd(
          serviceEvent.get.fd, serviceEvent.get.fdFlags)
        if not called.isOk:
          return called
  success()
proc openGui(session: var HostSession; config: RunConfig;
             errorOutput: File): Result[Unit]
proc openTray(session: var HostSession; config: RunConfig;
              errorOutput: File): Result[Unit]

proc closeGuiForVst3Reload(session: var HostSession): Result[Unit] =
  if session.tray != nil:
    var closedTray = session.tray.close()
    if not closedTray.isOk:
      return closedTray
  if session.gui != nil:
    var closedGui = session.gui.close()
    if not closedGui.isOk:
      return closedGui
  session.tray = nil
  session.gui = nil
  success()

proc serviceVst3Control(session: var HostSession; config: RunConfig;
                        errorOutput: File): Result[Unit] =
  let backendSnapshot = session.vst3Slice.jackBackend.notifications()
  if session.vst3Slice.takeFault():
    return failure[Unit](hostError(
      hsVst3, hekVst3Factory,
      "VST3 processing failed; outputs were silenced and the host is stopping",
      "path=" & session.activePath() & "; id=" & session.activePluginId()))
  if backendSnapshot.shutdownCount > 0'u64:
    var context = "status=" & $backendSnapshot.shutdownStatus
    if backendSnapshot.shutdownReason.len > 0:
      context.add("; reason=" & backendSnapshot.shutdownReason)
    return failure[Unit](hostError(
      hsJack, hekJackClientClose, "JACK server shut down the host client",
      context))

  var report = Vst3ReconfigurationReport()
  let rebindGui = session.gui != nil and session.gui.isAvailable
  let closeGui = session.gui != nil and
    (session.gui.isAvailable or session.gui.isCreated)
  let rebindVisible = rebindGui and session.gui.isVisible
  let sessionPointer = addr session
  var beforeReload: proc(): Result[Unit] {.closure.} = nil
  if closeGui:
    beforeReload = proc(): Result[Unit] {.closure.} =
      sessionPointer[].closeGuiForVst3Reload()
  var serviced = session.vst3Slice.serviceReconfiguration(
    beforeReload = beforeReload)
  if not serviced.isOk:
    return failure[Unit](move(serviced.error))
  report = move(serviced.value)
  if report.connectionsLost.len > 0 and config.verbosity != vbQuiet:
    session.emitWarning(wkConnectionLoss, errorOutput,
      "JACK port rebuild could not restore " &
      $report.connectionsLost.len & " external connection(s)")
  if report.componentReloaded and rebindGui:
    var rebindConfig = config
    rebindConfig.guiPolicy = if rebindVisible: gpShow else: gpHidden
    var guiOpened = session.openGui(rebindConfig, errorOutput)
    if not guiOpened.isOk:
      return guiOpened
    var trayOpened = session.openTray(rebindConfig, errorOutput)
    if not trayOpened.isOk:
      return trayOpened

  if backendSnapshot.xrunCount > session.lastXruns and
      config.verbosity != vbQuiet:
    session.emitWarning(wkXruns, errorOutput, "JACK reported " &
      $(backendSnapshot.xrunCount - session.lastXruns) & " new xruns")
  session.lastXruns = backendSnapshot.xrunCount
  if backendSnapshot.freewheelCount > session.lastFreewheelChanges and
      config.verbosity == vbVerbose:
    session.emitWarning(wkFreewheel, errorOutput,
      "JACK freewheel state changed to " & $backendSnapshot.freewheel)
  session.lastFreewheelChanges = backendSnapshot.freewheelCount
  let eventMetrics = session.vst3Slice.takeEventMetrics()
  let eventWarning = vst3EventMetricsWarningMessage(eventMetrics)
  if eventWarning.len > 0 and config.verbosity != vbQuiet:
    session.emitWarning(wkEventDrops, errorOutput, eventWarning)
  if session.vst3Slice.drainParameterObservations() > 0'u32:
    session.stateDirty = true
  var gestures: array[256, Vst3ParameterEditRecord]
  let gestureCount = session.vst3Slice.drainParameterGestures(
    cast[ptr UncheckedArray[Vst3ParameterEditRecord]](addr gestures[0]),
    uint32(gestures.len))
  if gestureCount > 0'u32:
    session.stateDirty = true
  success()


proc serviceAudioControl(session: var HostSession; config: RunConfig;
                         errorOutput: File): Result[Unit] =
  if session.isVst3:
    return session.serviceVst3Control(config, errorOutput)
  let snapshot = session.audioSlice.controlSnapshot()
  if snapshot.processErrors > 0'u64:
    return failure[Unit](hostError(
      hsClap, hekClapProcess,
      "CLAP processing failed; outputs were silenced and the host is stopping",
      "path=" & session.audioSlice.pluginPath &
        "; id=" & session.audioSlice.pluginId &
        "; errors=" & $snapshot.processErrors,
    ))
  if snapshot.jackShutdownCount > 0'u64:
    var context = "status=" & $snapshot.jackShutdownStatus
    if snapshot.jackShutdownReason.len > 0:
      context.add("; reason=" & snapshot.jackShutdownReason)
    return failure[Unit](hostError(
      hsJack, hekJackClientClose, "JACK server shut down the host client", context))
  let requests = session.audioSlice.controlRequests()
  let rescans = session.audioSlice.takeRescanRequests()
  let parameterFullRescan = (rescans.parameters and ClapParamRescanAll) != 0'u32
  let parameterImmediateRescan = rescans.parameters and not ClapParamRescanAll
  let latencyChanged = session.audioSlice.takeLatencyChanged()
  let restartRequired = snapshot.configurationPending or requests.restart or
    latencyChanged or rescans.audioPorts != 0'u32 or rescans.notePorts != 0'u32 or
    parameterFullRescan

  if restartRequired:
    if session.consecutiveRestarts >= MaxConsecutiveRestarts:
      return failure[Unit](hostError(
        hsClap, hekClapPlugin, "CLAP restart request limit exceeded",
        "path=" & session.audioSlice.pluginPath & "; id=" & session.audioSlice.pluginId &
          "; limit=" & $MaxConsecutiveRestarts,
      ))
    inc session.consecutiveRestarts
    var restarted = session.audioSlice.restart(parameterFullRescan)
    if not restarted.isOk:
      return restarted
    let reconnection = session.audioSlice.takeReconnectionReport()
    if reconnection.lost.len > 0 and config.verbosity != vbQuiet:
      session.emitWarning(wkConnectionLoss, errorOutput,
        "JACK port rebuild could not restore " &
        $reconnection.lost.len & " external connection(s)")
  else:
    session.consecutiveRestarts = 0'u32
  if parameterImmediateRescan != 0'u32:
    var rescanned = session.audioSlice.rescanParameters(parameterImmediateRescan)
    if not rescanned.isOk:
      return rescanned

  if requests.callback:
    var called = session.audioSlice.callOnMainThread()
    if not called.isOk:
      return called
  # request_process/request_flush atomics wake the RT endpoint directly. While
  # active, parameter output is exchanged through process(), never flush().
  discard requests.process
  discard requests.flush

  if snapshot.xrunCount > session.lastXruns and config.verbosity != vbQuiet:
    session.emitWarning(wkXruns, errorOutput, "JACK reported " &
      $(snapshot.xrunCount - session.lastXruns) & " new xruns")
  session.lastXruns = snapshot.xrunCount
  if snapshot.freewheelCount > session.lastFreewheelChanges and
      config.verbosity == vbVerbose:
    session.emitWarning(wkFreewheel, errorOutput,
      "JACK freewheel state changed to " & $snapshot.freewheel)
  session.lastFreewheelChanges = snapshot.freewheelCount

  let eventMetrics = session.audioSlice.takeEventMetrics()
  let eventWarning = eventMetrics.eventMetricsWarningMessage()
  if eventWarning.len > 0 and config.verbosity != vbQuiet:
    session.emitWarning(wkEventDrops, errorOutput, eventWarning)
  let parameterEvents = session.audioSlice.drainParameterEvents()
  let parameterMetrics = session.audioSlice.takeParameterMetrics()
  if parameterMetrics.dropped > 0'u64 and config.verbosity != vbQuiet:
    session.emitWarning(wkParameterDrops, errorOutput,
      "CLAP parameter transport dropped or rejected " &
      $parameterMetrics.dropped & " events")
  if parameterEvents.valueChanges > 0'u32:
    session.stateDirty = true
  if session.audioSlice.takeStateDirty():
    session.stateDirty = true
  session.drainPluginLogs(config, errorOutput)
  success()

proc serviceInternalControlOnce*(session: var HostSession; config: RunConfig;
                                 errorOutput: File): Result[Unit] =
  if session.state != ssRunning or
      (if session.isVst3: session.vst3Slice.state != v3assActive
       else: session.audioSlice.state != iassActive):
    return failure[Unit](transitionError(
      "internal control can only be serviced for a running audio session",
      $session.state,
    ))
  session.serviceAudioControl(config, errorOutput)

proc openProcessControl(session: var HostSession): Result[Unit] =
  var sourceResult = openSignalSource()
  if not sourceResult.isOk:
    return failure[Unit](move(sourceResult.error))
  session.signalSource = move(sourceResult.value)

  var driverResult = linux_reactor.openLinuxReactorDriver()
  if not driverResult.isOk:
    return failure[Unit](move(driverResult.error))
  var reactorResult = initMainReactor(driverResult.value)
  if not reactorResult.isOk:
    discard driverResult.value.close()
    return failure[Unit](move(reactorResult.error))
  session.reactor = move(reactorResult.value)
  var registered = session.reactor.registerFd(
    session.signalSource.fileDescriptor, {riRead})
  if not registered.isOk:
    return failure[Unit](move(registered.error))
  session.signalToken = registered.value
  session.pluginServices = newPluginServiceRegistry(session.reactor)
  success()

proc serviceGuiFailure(session: var HostSession; config: RunConfig;
                       errorOutput: File; operation: string;
                       error: sink HostError): Result[Unit] =
  if config.requireGui:
    return failure[Unit](move(error))
  if config.verbosity != vbQuiet:
    session.emitWarning(wkGuiFailure, errorOutput,
      "could not " & operation &
      " the plugin GUI; continuing headless: " & error.message)
  if session.gui != nil:
    var closed = session.gui.close()
    if not closed.isOk:
      error.context.add("; GUI cleanup=" & closed.error.message)
      if closed.error.context.len > 0:
        error.context.add(" (" & closed.error.context & ")")
      return failure[Unit](move(error))
  if session.tray != nil:
    var trayClosed = session.tray.close()
    if not trayClosed.isOk:
      error.context.add("; tray cleanup=" & trayClosed.error.message)
      if trayClosed.error.context.len > 0:
        error.context.add(" (" & trayClosed.error.context & ")")
      return failure[Unit](move(error))
  success()

proc serviceGuiEvents(session: var HostSession; config: RunConfig;
                      events: seq[ReactorEvent]; errorOutput: File;
                      closeRequested: var bool): Result[Unit] =
  if session.gui == nil:
    return success()
  var handled = session.gui.handleWindowEvents(events)
  if not handled.isOk:
    return session.serviceGuiFailure(config, errorOutput, "service",
      move(handled.error))
  closeRequested = handled.value
  success()

proc serviceTrayFailure(session: var HostSession; config: RunConfig;
                        errorOutput: File; operation: string;
                        error: sink HostError): Result[Unit] =
  var trayFailure = move(error)
  if config.verbosity != vbQuiet:
    let detail = if trayFailure.context.len == 0: trayFailure.message
      else: trayFailure.message & " (" & trayFailure.context & ")"
    session.emitWarning(wkTrayFailure, errorOutput,
      "could not " & operation &
      " tray icon; continuing without tray: " & detail)
  if session.tray != nil:
    var closed = session.tray.close()
    if not closed.isOk:
      trayFailure.context.add("; tray cleanup=" & closed.error.message)
      if closed.error.context.len > 0:
        trayFailure.context.add(" (" & closed.error.context & ")")
      return failure[Unit](move(trayFailure))
  success()

proc serviceTrayEvents(session: var HostSession; config: RunConfig;
                       events: seq[ReactorEvent]; errorOutput: File): Result[Unit] =
  if session.tray == nil:
    return success()
  var handled = session.tray.handleEvents(events)
  if not handled.isOk:
    return session.serviceTrayFailure(config, errorOutput, "service",
      move(handled.error))
  if handled.value and session.gui != nil:
    var toggled = session.gui.toggle()
    if not toggled.isOk:
      return session.serviceGuiFailure(
        config, errorOutput, "toggle", move(toggled.error))
  success()

proc serviceGuiRequests(session: var HostSession; config: RunConfig;
                         errorOutput: File): Result[Unit] =
  if session.gui == nil or session.isVst3:
    return success()
  var requests = session.audioSlice.takeGuiRequests()
  if not (requests.show or requests.hide or requests.resize or
          requests.resizeHints or requests.closed):
    return success()
  var handled = session.gui.handlePluginRequests(requests)
  if not handled.isOk:
    return session.serviceGuiFailure(config, errorOutput, "service",
      move(handled.error))
  success()
proc loadGuiIcon(session: var HostSession; config: RunConfig): Result[Unit] =
  if config.iconPath.isSome:
    var loaded = parsePpm(config.iconPath.get())
    if not loaded.isOk:
      return failure[Unit](move(loaded.error))
    session.guiIcon = loaded.value
  else:
    session.guiIcon = defaultGuiIcon()
  success()

proc openGui(session: var HostSession; config: RunConfig;
                 errorOutput: File): Result[Unit] =
  if config.guiPolicy == gpDisabled:
    return success()
  let title = pluginDisplayName(session.activePluginName(),
    if session.isVst3: "VST3" else: "CLAP")
  var client: GuiPluginClient
  if session.isVst3:
    client = vst3_gui_client.newVst3GuiClient(session.vst3Slice.instance())
  else:
    client = session.audioSlice.guiClient()
  session.gui = newGuiController(
    client, addr session.reactor, newX11WindowBackend,
    title, config.guiScale, icon = session.guiIcon)
  var started = session.gui.start(config.guiPolicy == gpShow)
  if not started.isOk:
    return session.serviceGuiFailure(config, errorOutput, "start",
      move(started.error))
  success()

proc openTray(session: var HostSession; config: RunConfig;
              errorOutput: File): Result[Unit] =
  if session.gui == nil or not session.gui.isAvailable:
    return success()
  let title = pluginDisplayName(session.activePluginName(),
    if session.isVst3: "VST3" else: "CLAP")
  session.tray = newTrayController(
    addr session.reactor, newDbusTrayIcon, title, session.guiIcon)
  var started = session.tray.start()
  if not started.isOk:
    return session.serviceTrayFailure(config, errorOutput, "start",
      move(started.error))
  success()

proc run*(session: var HostSession; config: RunConfig;
          errorOutput: File): Result[Unit] =
  if session.state != ssNew:
    return failure[Unit](transitionError(
      "a public host session can only run from the new state", $session.state))
  var validated = validateAvailableRunOptions(config)
  if not validated.isOk:
    return failSession[Unit](session, move(validated.error))
  var iconLoaded = session.loadGuiIcon(config)
  if not iconLoaded.isOk:
    return failSession[Unit](session, move(iconLoaded.error))
  session.saveStatePath = config.saveStatePath
  var processControl = session.openProcessControl()
  if not processControl.isOk:
    return failSession[Unit](session, move(processControl.error))

  if vst3_catalog.isVst3BundlePath(config.pluginPath):
    session.format = pfVst3
    session.vst3Services = newVst3PluginServices(session.reactor)
    var descriptor: PluginDescriptor
    var sliceResult = openRunVst3Slice(
      config, session.vst3Services, descriptor)
    if not sliceResult.isOk:
      return failSession[Unit](session, move(sliceResult.error))
    var slice = move(sliceResult.value)
    var attached = session.attachVst3AudioSlice(
      slice, session.vst3Services, config.pluginPath,
      descriptor.id, descriptor.name)
    if not attached.isOk:
      discard slice.close()
      return failSession[Unit](session, move(attached.error))
  else:
    var sliceResult = openRunSlice(
      config, session.pluginServices.servicePointer)
    if not sliceResult.isOk:
      return failSession[Unit](session, move(sliceResult.error))
    var slice = move(sliceResult.value)
    var attached = session.attachInternalAudioSlice(slice)
    if not attached.isOk:
      discard slice.close()
      return failSession[Unit](session, move(attached.error))
  var started = session.startInternalAudio()
  if not started.isOk:
    return started

  let processName = setLinuxProcessName(
    pluginDisplayName(session.activePluginName(),
      if session.isVst3: "VST3" else: "CLAP"))
  if not processName.isOk:
    var namingError = processName.error
    return failSession[Unit](session, move(namingError))

  if config.pidFilePath.isSome:
    var pidResult = createPidFile(config.pidFilePath.get())
    if not pidResult.isOk:
      return failSession[Unit](session, move(pidResult.error))
    session.pidFile = move(pidResult.value)

  var guiOpened = session.openGui(config, errorOutput)
  if not guiOpened.isOk:
    return failSession[Unit](session, move(guiOpened.error))
  var trayOpened = session.openTray(config, errorOutput)
  if not trayOpened.isOk:
    return failSession[Unit](session, move(trayOpened.error))
  while session.state == ssRunning:
    var events = session.reactor.wait(monotonicNanos(ControlServiceNanos))
    if not events.isOk:
      return failSession[Unit](session, move(events.error))
    var signals = session.drainSignals(events.value)
    if not signals.isOk:
      return failSession[Unit](session, move(signals.error))
    if signals.value.shutdown:
      var stopping = session.state.transition(ssStopping)
      if not stopping.isOk:
        return stopping
      return success()
    var closeRequested = false
    var guiEvents = session.serviceGuiEvents(
      config, events.value, errorOutput, closeRequested)
    if not guiEvents.isOk:
      return failSession[Unit](session, move(guiEvents.error))
    if closeRequested:
      return session.state.transition(ssStopping)
    var trayEvents = session.serviceTrayEvents(
      config, events.value, errorOutput)
    if not trayEvents.isOk:
      return failSession[Unit](session, move(trayEvents.error))
    var guiSignals = session.serviceGuiSignalActions(
      config, signals.value.intents, errorOutput)
    if not guiSignals.isOk:
      return failSession[Unit](session, move(guiSignals.error))
    var pluginEvents = session.servicePluginEvents(events.value)
    if not pluginEvents.isOk:
      return failSession[Unit](session, move(pluginEvents.error))
    var serviced = session.serviceAudioControl(config, errorOutput)
    if not serviced.isOk:
      return failSession[Unit](session, move(serviced.error))
    var guiRequests = session.serviceGuiRequests(config, errorOutput)
    if not guiRequests.isOk:
      return failSession[Unit](session, move(guiRequests.error))
  success()

proc run*(session: var HostSession; config: RunConfig): Result[Unit] =
  session.run(config, stderr)

proc rememberCleanup(first: var HostError; failed: var bool;
                     operation: var Result[Unit]) =
  if operation.isOk:
    return
  if not failed:
    first = move(operation.error)
    failed = true
  else:
    first.context.add("; additional-cleanup=" & operation.error.message)
    if operation.error.context.len > 0:
      first.context.add(" (" & operation.error.context & ")")

proc close*(session: var HostSession; errorOutput: File): Result[Unit] =

  session.flushWarnings(errorOutput)
  let audioClosedAlready =
    if session.isVst3: session.vst3Slice.state in {v3assEmpty, v3assClosed}
    else: session.audioSlice.state in {iassEmpty, iassClosed}
  if session.state == ssStopped and audioClosedAlready and
      not session.pidFile.isOwned and not session.signalSource.isOpen and
      (session.gui == nil or session.gui.state == gcsClosed) and
      (session.tray == nil or session.tray.state == tcsClosed):
    return success()

  var first: HostError
  var failed = false
  var vst3ControlSafe = true
  if session.isVst3:
    # Stop JACK before touching the VST3 instance.  The editor is then closed
    # before the bounded preset capture and native instance teardown.
    if session.vst3Slice.state == v3assActive:
      var quiesced = session.vst3Slice.stop()
      rememberCleanup(first, failed, quiesced)
      if not quiesced.isOk:
        vst3ControlSafe = false
    var trayClosed = session.tray.close()
    rememberCleanup(first, failed, trayClosed)
    if not trayClosed.isOk:
      vst3ControlSafe = false
    var guiClosed = session.gui.close()
    rememberCleanup(first, failed, guiClosed)
    if not guiClosed.isOk:
      vst3ControlSafe = false
    if guiClosed.isOk and session.state == ssStopping and
        session.saveStatePath.isSome and
        session.vst3Slice.state == v3assQuiesced:
      var saved = session.vst3Slice.saveState(session.saveStatePath.get())
      rememberCleanup(first, failed, saved)
    var audioClosed = session.vst3Slice.close()
    rememberCleanup(first, failed, audioClosed)
    # A failed native close may leave editor/host callbacks borrowed by the
    # instance. Do not finalize the context while those callbacks can run.
    if audioClosed.isOk:
      var servicesClosed = session.vst3Services.close(
        allowRetainedHostReferences = true)
      rememberCleanup(first, failed, servicesClosed)
      if not servicesClosed.isOk:
        vst3ControlSafe = false
    else:
      vst3ControlSafe = false
    var clapServicesClosed = session.pluginServices.close()
    rememberCleanup(first, failed, clapServicesClosed)
  else:
    # Preserve the established CLAP teardown order and state semantics.
    if session.audioSlice.state == iassActive:
      var quiesced = session.audioSlice.quiesce()
      rememberCleanup(first, failed, quiesced)
      if quiesced.isOk and session.state == ssStopping and
          session.saveStatePath.isSome:
        var saved = session.audioSlice.saveState(session.saveStatePath.get())
        rememberCleanup(first, failed, saved)
    var trayClosed = session.tray.close()
    rememberCleanup(first, failed, trayClosed)
    var guiClosed = session.gui.close()
    rememberCleanup(first, failed, guiClosed)
    var servicesClosed = session.pluginServices.close()
    rememberCleanup(first, failed, servicesClosed)
    if session.audioSlice.state in {iassActive, iassQuiesced}:
      var audioStopped = session.audioSlice.stop()
      rememberCleanup(first, failed, audioStopped)
    var audioClosed = session.audioSlice.close()
    rememberCleanup(first, failed, audioClosed)
  if session.isVst3 and not vst3ControlSafe:
    # Keep the reactor and signal source alive while any native/editor owner
    # can still hold a callback registration; close() remains retryable.
    var pidClosed = session.pidFile.close()
    rememberCleanup(first, failed, pidClosed)
    if session.state in {ssStarting, ssRunning, ssStopping}:
      discard session.state.transition(ssFailed)
    return failure[Unit](move(first))
  var pidClosed = session.pidFile.close()
  rememberCleanup(first, failed, pidClosed)
  var reactorClosed = session.reactor.close()
  rememberCleanup(first, failed, reactorClosed)
  var signalsClosed = session.signalSource.close()
  rememberCleanup(first, failed, signalsClosed)

  if failed:
    if session.state in {ssStarting, ssRunning, ssStopping}:
      discard session.state.transition(ssFailed)
    return failure[Unit](move(first))

  case session.state
  of ssStopped:
    discard
  of ssNew:
    discard session.state.transition(ssStopped)
  of ssStopping:
    discard session.state.transition(ssStopped)
  of ssFailed:
    discard session.state.transition(ssStopping)
    discard session.state.transition(ssStopped)
  of ssStarting, ssRunning:
    discard session.state.transition(ssStopping)
    discard session.state.transition(ssStopped)
  success()

proc close*(session: var HostSession): Result[Unit] =
  session.close(stderr)
