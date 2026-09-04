import std/options

import ./[audio_slice, main_reactor, plugin_services, run_config]
import ../clap/[event_bridge, ffi, loader, main_thread_services]
import ../gui/controller
import ../platform/x11/gui_adapter
import ../domain/[errors, lifecycle, plugin_catalog, reactor, result]
import ../jack/backend
import ../platform/linux/[pid_file, reactor as linux_reactor, signals]
import ../support/names

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
    audioSlice: InternalAudioSlice
    gui: GuiController
    reactor: MainReactor
    signalSource: SignalSource
    signalToken: ReactorToken
    pidFile: PidFile
    pluginServices: PluginServiceRegistry
    guiSignalWarnings: set[SignalIntent]
    lastXruns: uint64
    lastFreewheelChanges: uint64
    stateDirty: bool
    consecutiveRestarts: uint32
    saveStatePath: Option[string]

proc initHostSession*(): HostSession =
  HostSession(state: ssNew)

proc hasDirtyState*(session: HostSession): bool {.inline.} =
  session.stateDirty

proc attachInternalAudioSlice*(session: var HostSession;
                               slice: var InternalAudioSlice): Result[Unit] =
  if session.state != ssNew or session.audioSlice.state != iassEmpty or
      slice.state != iassReady:
    return failure[Unit](transitionError(
      "an internal audio slice can only be attached to an empty new session",
      $session.state & "; attached=" & $session.audioSlice.state &
        "; slice=" & $slice.state,
    ))
  session.audioSlice = move(slice)
  success()

proc startInternalAudio*(session: var HostSession): Result[Unit] =
  if session.state != ssNew or session.audioSlice.state != iassReady:
    return failure[Unit](transitionError(
      "an internal audio slice can only start from a new ready session",
      $session.state & "; slice=" & $session.audioSlice.state,
    ))
  var starting = session.state.transition(ssStarting)
  if not starting.isOk:
    return starting
  var started = session.audioSlice.start()
  if not started.isOk:
    discard session.state.transition(ssFailed)
    return started
  session.state.transition(ssRunning)

proc stopInternalAudio*(session: var HostSession): Result[Unit] =
  if session.state != ssRunning:
    return failure[Unit](transitionError(
      "an internal audio slice can only stop from a running session",
      $session.state,
    ))
  var stopping = session.state.transition(ssStopping)
  if not stopping.isOk:
    return stopping
  var stopped = session.audioSlice.stop()
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
  var moduleResult = openClapModule(config.pluginPath)
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

proc warning(errorOutput: File; message: string) =
  errorOutput.write("pluginhost: warning: " & message & "\n")

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
        " [" & session.audioSlice.pluginId & "]: " & message.text & "\n")
    inc count
  let dropped = session.audioSlice.takeDroppedPluginLogs()
  if dropped > 0'u64 and config.verbosity != vbQuiet:
    warning(errorOutput, "CLAP log queue dropped " & $dropped & " messages")

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
      if session.gui == nil:
        if intent notin session.guiSignalWarnings:
          session.guiSignalWarnings.incl(intent)
          warning(errorOutput, "SIGUSR request to " & operation &
            " the GUI is unavailable while GUI hosting is disabled")
      else:
        var action = if intent == siShowGui: session.gui.show()
                     else: session.gui.hide()
        if not action.isOk:
          if config.requireGui:
            return failure[Unit](move(action.error))
          if intent notin session.guiSignalWarnings:
            session.guiSignalWarnings.incl(intent)
            warning(errorOutput, "could not " & operation &
              " the plugin GUI; continuing headless: " & action.error.message)
  success()

proc servicePluginEvents(session: var HostSession; events: seq[ReactorEvent]):
    Result[Unit] =
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

proc serviceAudioControl(session: var HostSession; config: RunConfig;
                         errorOutput: File): Result[Unit] =
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
      warning(errorOutput, "JACK port rebuild could not restore " &
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
    warning(errorOutput, "JACK reported " &
      $(snapshot.xrunCount - session.lastXruns) & " new xruns")
  session.lastXruns = snapshot.xrunCount
  if snapshot.freewheelCount > session.lastFreewheelChanges and
      config.verbosity == vbVerbose:
    warning(errorOutput, "JACK freewheel state changed to " & $snapshot.freewheel)
  session.lastFreewheelChanges = snapshot.freewheelCount

  let eventMetrics = session.audioSlice.takeEventMetrics()
  let eventWarning = eventMetrics.eventMetricsWarningMessage()
  if eventWarning.len > 0 and config.verbosity != vbQuiet:
    warning(errorOutput, eventWarning)
  let parameterEvents = session.audioSlice.drainParameterEvents()
  let parameterMetrics = session.audioSlice.takeParameterMetrics()
  if parameterMetrics.dropped > 0'u64 and config.verbosity != vbQuiet:
    warning(errorOutput, "CLAP parameter transport dropped or rejected " &
      $parameterMetrics.dropped & " events")
  if parameterEvents.valueChanges > 0'u32:
    session.stateDirty = true
  if session.audioSlice.takeStateDirty():
    session.stateDirty = true
  session.drainPluginLogs(config, errorOutput)
  success()

proc serviceInternalControlOnce*(session: var HostSession; config: RunConfig;
                                 errorOutput: File): Result[Unit] =
  if session.state != ssRunning or session.audioSlice.state != iassActive:
    return failure[Unit](transitionError(
      "internal control can only be serviced for a running audio session",
      $session.state & "; slice=" & $session.audioSlice.state,
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
  if siShowGui notin session.guiSignalWarnings:
    session.guiSignalWarnings.incl(siShowGui)
    warning(errorOutput, "could not " & operation &
      " the plugin GUI; continuing headless: " & error.message)
  if session.gui != nil:
    var closed = session.gui.close()
    if not closed.isOk:
      error.context.add("; GUI cleanup=" & closed.error.message)
      if closed.error.context.len > 0:
        error.context.add(" (" & closed.error.context & ")")
      return failure[Unit](move(error))
  success()

proc serviceGuiEvents(session: var HostSession; config: RunConfig;
                       events: seq[ReactorEvent]; errorOutput: File): Result[Unit] =
  if session.gui == nil:
    return success()
  var handled = session.gui.handleWindowEvents(events)
  if not handled.isOk:
    return session.serviceGuiFailure(config, errorOutput, "service",
      move(handled.error))
  success()

proc serviceGuiRequests(session: var HostSession; config: RunConfig;
                         errorOutput: File): Result[Unit] =
  if session.gui == nil:
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


proc openGui(session: var HostSession; config: RunConfig;
                 errorOutput: File): Result[Unit] =
  if config.guiPolicy == gpDisabled:
    return success()
  let title = "pluginhost: " & session.audioSlice.pluginName
  session.gui = newGuiController(
    session.audioSlice.guiClient(), addr session.reactor, newX11WindowBackend,
    title, config.guiScale)
  var started = session.gui.start(config.guiPolicy == gpShow)
  if not started.isOk:
    return session.serviceGuiFailure(config, errorOutput, "start",
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

  session.saveStatePath = config.saveStatePath
  var processControl = session.openProcessControl()
  if not processControl.isOk:
    return failSession[Unit](session, move(processControl.error))

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

  if config.pidFilePath.isSome:
    var pidResult = createPidFile(config.pidFilePath.get())
    if not pidResult.isOk:
      return failSession[Unit](session, move(pidResult.error))
    session.pidFile = move(pidResult.value)

  var guiOpened = session.openGui(config, errorOutput)
  if not guiOpened.isOk:
    return failSession[Unit](session, move(guiOpened.error))

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
    var guiEvents = session.serviceGuiEvents(config, events.value, errorOutput)
    if not guiEvents.isOk:
      return failSession[Unit](session, move(guiEvents.error))
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

proc close*(session: var HostSession): Result[Unit] =
  if session.state == ssStopped and session.audioSlice.state in
      {iassEmpty, iassClosed} and not session.pidFile.isOwned and
      not session.signalSource.isOpen and
      (session.gui == nil or session.gui.state == gcsClosed):
    return success()

  var first: HostError
  var failed = false
  if session.state == ssStopping and session.saveStatePath.isSome and
      session.audioSlice.state == iassActive:
    var quiesced = session.audioSlice.quiesce()
    rememberCleanup(first, failed, quiesced)
    if quiesced.isOk:
      var saved = session.audioSlice.saveState(session.saveStatePath.get())
      rememberCleanup(first, failed, saved)
  if session.audioSlice.state == iassActive:
    var audioStopped = session.audioSlice.stop()
    rememberCleanup(first, failed, audioStopped)
  var guiClosed = session.gui.close()
  rememberCleanup(first, failed, guiClosed)
  var servicesClosed = session.pluginServices.close()
  rememberCleanup(first, failed, servicesClosed)
  var audioClosed = session.audioSlice.close()
  rememberCleanup(first, failed, audioClosed)
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
