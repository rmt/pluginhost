import std/options

import ./[audio_slice, main_reactor, run_config]
import ../clap/loader
import ../domain/[errors, lifecycle, plugin_catalog, reactor, result]
import ../jack/backend
import ../platform/linux/[pid_file, reactor as linux_reactor, signals]
import ../support/names

const
  ControlServiceNanos = 16_000_000'i64
  MaxPluginLogsPerTurn = 64


type
  HostSession* = object
    state*: SessionState
    audioSlice: InternalAudioSlice
    reactor: MainReactor
    signalSource: SignalSource
    signalToken: ReactorToken
    pidFile: PidFile
    guiSignalWarnings: set[SignalIntent]
    lastXruns: uint64
    lastFreewheelChanges: uint64

proc initHostSession*(): HostSession =
  HostSession(state: ssNew)

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
  if config.loadStatePath.isSome or config.saveStatePath.isSome:
    return failure[Unit](hostError(
      hsState, hekState,
      "CLAP state load/save is not implemented in this development increment",
      config.pluginPath,
    ))
  if config.requireGui or config.guiScale.isSome:
    return failure[Unit](hostError(
      hsGui, hekGui,
      "required or scaled plugin GUI hosting is not implemented in this development increment",
      config.pluginPath,
    ))
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

proc openRunSlice(config: RunConfig): Result[InternalAudioSlice] =
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
  openInternalAudioSlice(move(module), move(selected.value), backendConfig)

proc warning(errorOutput: File; message: string) =
  errorOutput.write("pluginhost: warning: " & message & "\n")

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

proc serviceSignals(session: var HostSession; events: seq[ReactorEvent];
                    errorOutput: File): Result[bool] =
  var signalReady = false
  for event in events:
    if event.kind == rekFd and event.token == session.signalToken:
      if riError in event.interests or riHangup in event.interests:
        return failure[bool](hostError(
          hsPlatform, hekSignal, "Linux signal descriptor failed"))
      signalReady = true
  if not signalReady:
    return success(false)

  var drained = session.signalSource.drain()
  if not drained.isOk:
    return failure[bool](move(drained.error))
  var shutdown = false
  for intent in drained.value:
    case intent
    of siInterrupt, siTerminate:
      shutdown = true
    of siShowGui, siHideGui:
      if intent notin session.guiSignalWarnings:
        session.guiSignalWarnings.incl(intent)
        let operation = if intent == siShowGui: "show" else: "hide"
        warning(errorOutput, "SIGUSR request to " & operation &
          " the GUI is unavailable until GUI hosting is implemented")
  success(shutdown)

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
  if snapshot.configurationPending:
    var refreshed = session.audioSlice.refreshRuntimeConfiguration()
    if not refreshed.isOk:
      return refreshed

  let requests = session.audioSlice.controlRequests()
  if requests.restart:
    return failure[Unit](hostError(
      hsClap, hekClapPlugin,
      "CLAP plugin requested restart, which is not implemented in this development increment",
      "path=" & session.audioSlice.pluginPath & "; id=" & session.audioSlice.pluginId,
    ))
  if requests.flush:
    return failure[Unit](hostError(
      hsInternal, hekInternal,
      "an unadvertised parameter flush request reached the control plane",
      "id=" & session.audioSlice.pluginId,
    ))
  if requests.callback:
    var called = session.audioSlice.callOnMainThread()
    if not called.isOk:
      return called
  # request_process is satisfied by Increment 7's continuous JACK processing.
  discard requests.process

  if snapshot.xrunCount > session.lastXruns and config.verbosity != vbQuiet:
    warning(errorOutput, "JACK reported " &
      $(snapshot.xrunCount - session.lastXruns) & " new xruns")
  session.lastXruns = snapshot.xrunCount
  if snapshot.freewheelCount > session.lastFreewheelChanges and
      config.verbosity == vbVerbose:
    warning(errorOutput, "JACK freewheel state changed to " & $snapshot.freewheel)
  session.lastFreewheelChanges = snapshot.freewheelCount

  let eventMetrics = session.audioSlice.takeEventMetrics()
  let droppedEvents = eventMetrics.droppedInput + eventMetrics.droppedOutput +
    eventMetrics.malformedInput + eventMetrics.invalidOutput +
    eventMetrics.jackLostInput
  if droppedEvents > 0'u64 and config.verbosity != vbQuiet:
    warning(errorOutput, "audio event bridge dropped or rejected " &
      $droppedEvents & " events")
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
  success()

proc run*(session: var HostSession; config: RunConfig;
          errorOutput: File): Result[Unit] =
  if session.state != ssNew:
    return failure[Unit](transitionError(
      "a public host session can only run from the new state", $session.state))
  var validated = validateAvailableRunOptions(config)
  if not validated.isOk:
    return failSession[Unit](session, move(validated.error))

  var processControl = session.openProcessControl()
  if not processControl.isOk:
    return failSession[Unit](session, move(processControl.error))

  var sliceResult = openRunSlice(config)
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

  if config.guiPolicy != gpDisabled:
    warning(errorOutput,
      "plugin GUI hosting is unavailable; continuing headless")

  while session.state == ssRunning:
    var events = session.reactor.wait(monotonicNanos(ControlServiceNanos))
    if not events.isOk:
      return failSession[Unit](session, move(events.error))
    var shutdown = session.serviceSignals(events.value, errorOutput)
    if not shutdown.isOk:
      return failSession[Unit](session, move(shutdown.error))
    if shutdown.value:
      var stopping = session.state.transition(ssStopping)
      if not stopping.isOk:
        return stopping
      return success()
    var serviced = session.serviceAudioControl(config, errorOutput)
    if not serviced.isOk:
      return failSession[Unit](session, move(serviced.error))
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
      not session.signalSource.isOpen:
    return success()

  var first: HostError
  var failed = false
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
