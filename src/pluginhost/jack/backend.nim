## Checked control-plane JACK backend for the internal audio slice.
##
## One backend owns one JackApi, one JACK client, all realized ports, and one
## stable callback context. Public plugin execution does not use this backend yet.

import std/[options, strutils]

import ../domain/[errors, port_plan, result]
import ../rt/[engine, role_guard]
import ../support/utf8
import ./[api, callbacks, ffi, ports]

const RuntimeConfigurationReadAttempts = 8

type
  JackBackendState* = enum
    jbsClosed
    jbsOpen
    jbsConfigured
    jbsActive

  JackBackendOpenConfig* = object
    clientName*: string
    serverName*: Option[string]
    noStartServer*: bool
    libraryPath*: string

  JackNotificationSnapshot* = object
    shutdownCount*: uint64
    shutdownStatus*: int32
    shutdownReason*: string
    xrunCount*: uint64
    freewheelCount*: uint64
    freewheel*: bool
    bufferSizeCount*: uint64
    bufferSize*: uint32
    sampleRateCount*: uint64
    sampleRate*: uint32
    latencyCount*: uint64
    processCycles*: uint64
    processFrames*: uint64
    processErrors*: uint64
    lateProcessCalls*: uint64
    configurationPending*: bool

  JackRuntimeConfiguration* = object
    sampleRate*: uint32
    bufferSize*: uint32

  JackBackend* = object
    api: JackApi
    client: JackClient
    callbackContext: ptr JackCallbackContext
    portOwner: JackPortOwner
    stateValue: JackBackendState
    requestedClientName: string
    actualClientNameValue: string
    serverNameValue: Option[string]
    sampleRateValue: uint32
    bufferSizeValue: uint32
    configurationGenerationValue: uint64
    clientNameSizeValue: int
    portNameSizeValue: int

proc `=destroy`*(backend: var JackBackend) =
  doAssert backend.client == nil,
    "an open JACK client must be explicitly closed"
  doAssert backend.callbackContext == nil,
    "JACK callback storage must be explicitly released"
  doAssert not backend.api.isOpen,
    "an open JACK API must be explicitly closed"
  `=destroy`(backend.api)
  `=destroy`(backend.portOwner)
  `=destroy`(backend.requestedClientName)
  `=destroy`(backend.actualClientNameValue)
  `=destroy`(backend.serverNameValue)

proc `=copy`*(destination: var JackBackend; source: JackBackend) {.error:
  "JackBackend owns foreign resources and cannot be copied; use move".}
proc `=dup`*(source: JackBackend): JackBackend {.error:
  "JackBackend owns foreign resources and cannot be duplicated; use move".}

proc `=sink`*(destination: var JackBackend; source: JackBackend) =
  doAssert destination.client == nil and destination.callbackContext == nil and
      not destination.api.isOpen,
    "an open JackBackend must be closed before move assignment"
  `=sink`(destination.api, source.api)
  destination.client = source.client
  destination.callbackContext = source.callbackContext
  `=sink`(destination.portOwner, source.portOwner)
  destination.stateValue = source.stateValue
  `=sink`(destination.requestedClientName, source.requestedClientName)
  `=sink`(destination.actualClientNameValue, source.actualClientNameValue)
  `=sink`(destination.serverNameValue, source.serverNameValue)
  destination.sampleRateValue = source.sampleRateValue
  destination.bufferSizeValue = source.bufferSizeValue
  destination.configurationGenerationValue =
    source.configurationGenerationValue
  destination.clientNameSizeValue = source.clientNameSizeValue
  destination.portNameSizeValue = source.portNameSizeValue

proc initJackBackendOpenConfig*(clientName: string;
                                serverName = none(string);
                                noStartServer = false;
                                libraryPath = JackLibrary): JackBackendOpenConfig =
  JackBackendOpenConfig(
    clientName: clientName,
    serverName: serverName,
    noStartServer: noStartServer,
    libraryPath: libraryPath,
  )

proc state*(backend: JackBackend): JackBackendState {.inline.} =
  backend.stateValue

proc isOpen*(backend: JackBackend): bool {.inline.} =
  backend.client != nil and backend.api.isOpen

proc actualClientName*(backend: JackBackend): string {.inline.} =
  backend.actualClientNameValue

proc sampleRate*(backend: JackBackend): uint32 {.inline.} =
  backend.sampleRateValue

proc bufferSize*(backend: JackBackend): uint32 {.inline.} =
  backend.bufferSizeValue

proc clientNameSize*(backend: JackBackend): int {.inline.} =
  backend.clientNameSizeValue

proc portNameSize*(backend: JackBackend): int {.inline.} =
  backend.portNameSizeValue

proc audioRoleGuard*(backend: JackBackend): ptr AudioRoleGuard {.inline.} =
  backend.callbackContext.audioRolePointer()

proc configurationChangePending*(backend: JackBackend): bool {.inline.} =
  backend.callbackContext.configurationChangePending()

proc realizedPortCount*(backend: JackBackend): int {.inline.} =
  backend.portOwner.registeredPortCount

proc notifications*(backend: JackBackend): JackNotificationSnapshot =
  let snapshot = backend.callbackContext.snapshotNotificationState()
  result.shutdownCount = snapshot.shutdownCount
  result.shutdownStatus = snapshot.shutdownStatus
  let reasonLength = min(
    int(snapshot.shutdownReasonLength), ShutdownReasonBytes)
  if reasonLength > 0:
    var rawReason = newString(reasonLength)
    copyMem(addr rawReason[0], unsafeAddr snapshot.shutdownReason[0], reasonLength)
    result.shutdownReason = rawReason.replaceInvalidUtf8()
  result.xrunCount = snapshot.xrunCount
  result.freewheelCount = snapshot.freewheelCount
  result.freewheel = snapshot.freewheel
  result.bufferSizeCount = snapshot.bufferSizeCount
  result.bufferSize = snapshot.bufferSize
  result.sampleRateCount = snapshot.sampleRateCount
  result.sampleRate = snapshot.sampleRate
  result.latencyCount = snapshot.latencyCount
  result.processCycles = snapshot.processCycles
  result.processFrames = snapshot.processFrames
  result.processErrors = snapshot.processErrors
  result.lateProcessCalls = snapshot.lateProcessCalls
  result.configurationPending = snapshot.configurationPending

proc backendError(kind: HostErrorKind; message: string;
                  backend: JackBackend; detail = ""): HostError =
  var context = "client=" & backend.requestedClientName
  if backend.serverNameValue.isSome:
    context.add("; server=" & backend.serverNameValue.get)
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsJack, kind, message, context)

proc configError(kind: HostErrorKind; message: string;
                 config: JackBackendOpenConfig; detail = ""): HostError =
  var context = "client=" & config.clientName
  if config.serverName.isSome:
    context.add("; server=" & config.serverName.get)
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsJack, kind, message, context)

proc hasEmbeddedNul(value: string): bool {.inline.} =
  value.find('\0') >= 0

proc formatJackStatus*(status: JackStatus): string =
  var names: seq[string]
  template includeFlag(flag: JackStatus; name: string) =
    if (status and flag) != 0:
      names.add(name)
  includeFlag(JackFailure, "failure")
  includeFlag(JackInvalidOption, "invalid-option")
  includeFlag(JackNameNotUnique, "name-not-unique")
  includeFlag(JackServerStarted, "server-started")
  includeFlag(JackServerFailed, "server-failed")
  includeFlag(JackServerError, "server-error")
  includeFlag(JackNoSuchClient, "no-such-client")
  includeFlag(JackLoadFailure, "load-failure")
  includeFlag(JackInitFailure, "init-failure")
  includeFlag(JackShmFailure, "shared-memory-failure")
  includeFlag(JackVersionError, "version-error")
  includeFlag(JackBackendError, "backend-error")
  includeFlag(JackClientZombie, "client-zombie")
  let rendered = if names.len == 0: "none" else: names.join(",")
  "status=0x" & toHex(cast[uint32](status), 8).toLowerAscii &
    " [" & rendered & "]"

proc copiedClientName(value: cstring; maximumBytes: int;
                      config: JackBackendOpenConfig): Result[string] =
  if value == nil or maximumBytes <= 1:
    return failure[string](configError(
      hekJackClientOpen,
      "JACK returned an invalid actual client name",
      config,
      "client-name-limit=" & $maximumBytes,
    ))
  let bytes = cast[ptr UncheckedArray[char]](value)
  var length = 0
  while length < maximumBytes and bytes[length] != '\0':
    inc length
  if length == maximumBytes or length == 0:
    return failure[string](configError(
      hekJackClientOpen,
      "JACK returned an invalid actual client name",
      config,
      "client-name-limit=" & $maximumBytes,
    ))
  var raw = newString(length)
  copyMem(addr raw[0], unsafeAddr bytes[0], length)
  success(raw.replaceInvalidUtf8())

proc callbackRegistrationError(backend: JackBackend; callbackName: string;
                               status: cint): HostError =
  backendError(
    hekJackCallbackRegistration,
    "could not register required JACK callback",
    backend,
    "callback=" & callbackName & "; status=" & $status,
  )

proc registerCallbacks(backend: var JackBackend): Result[Unit] =
  let argument = backend.callbackContext.callbackArgument()
  var status = backend.api.functions.setProcessCallback(
    backend.client, jackProcessCallback, argument)
  if status != 0:
    return failure[Unit](backend.callbackRegistrationError("process", status))

  backend.api.functions.onShutdown(
    backend.client, jackShutdownCallback, argument)
  backend.api.functions.onInfoShutdown(
    backend.client, jackInfoShutdownCallback, argument)

  status = backend.api.functions.setBufferSizeCallback(
    backend.client, jackBufferSizeCallback, argument)
  if status != 0:
    return failure[Unit](backend.callbackRegistrationError(
      "buffer-size", status))
  status = backend.api.functions.setSampleRateCallback(
    backend.client, jackSampleRateCallback, argument)
  if status != 0:
    return failure[Unit](backend.callbackRegistrationError(
      "sample-rate", status))
  status = backend.api.functions.setXrunCallback(
    backend.client, jackXrunCallback, argument)
  if status != 0:
    return failure[Unit](backend.callbackRegistrationError("xrun", status))
  status = backend.api.functions.setFreewheelCallback(
    backend.client, jackFreewheelCallback, argument)
  if status != 0:
    return failure[Unit](backend.callbackRegistrationError(
      "freewheel", status))
  status = backend.api.functions.setLatencyCallback(
    backend.client, jackLatencyCallback, argument)
  if status != 0:
    return failure[Unit](backend.callbackRegistrationError("latency", status))
  success()

proc activate*(backend: var JackBackend): Result[Unit] =
  if backend.stateValue != jbsConfigured:
    return failure[Unit](backendError(
      hekJackActivation,
      "JACK backend is not configured for activation",
      backend,
      "state=" & $backend.stateValue,
    ))
  if backend.callbackContext.configurationChangePending():
    return failure[Unit](backendError(
      hekJackActivation,
      "JACK activation is blocked by a pending runtime configuration change",
      backend,
    ))
  backend.callbackContext.enableProcessCallbacks()
  let status = backend.api.functions.activate(backend.client)
  if status != 0:
    backend.callbackContext.disableProcessCallbacks()
    if not backend.callbackContext.processCallbacksQuiescent():
      return failure[Unit](backendError(
        hekJackQuiescence,
        "JACK process callback did not quiesce after activation failure",
        backend,
        "status=" & $status,
      ))
    return failure[Unit](backendError(
      hekJackActivation,
      "could not activate the JACK client",
      backend,
      "status=" & $status,
    ))
  backend.stateValue = jbsActive
  success()

proc deactivate*(backend: var JackBackend): Result[Unit] =
  if backend.stateValue != jbsActive:
    return success()
  let status = backend.api.functions.deactivate(backend.client)
  if status != 0:
    return failure[Unit](backendError(
      hekJackDeactivation,
      "could not deactivate the JACK client",
      backend,
      "status=" & $status,
    ))

  backend.callbackContext.disableProcessCallbacks()
  backend.stateValue = jbsConfigured
  if not backend.callbackContext.processCallbacksQuiescent():
    return failure[Unit](backendError(
      hekJackQuiescence,
      "JACK process callback did not quiesce after deactivation",
      backend,
    ))
  success()

proc appendPrimary(cleanup: HostError; primary: HostError): HostError =
  result = cleanup
  result.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    result.context.add(" (" & primary.context & ")")

proc close*(backend: var JackBackend): Result[Unit] =
  if backend.stateValue == jbsClosed and backend.client == nil and
      backend.callbackContext == nil and not backend.api.isOpen:
    return success()

  var hadPrimary = false
  var primary: HostError
  if backend.stateValue == jbsActive and backend.client != nil:
    let stopped = backend.deactivate()
    if not stopped.isOk:
      hadPrimary = true
      primary = stopped.error

  if backend.client != nil:
    let status = backend.api.functions.clientClose(backend.client)
    if status != 0:
      let cleanup = backendError(
        hekJackClientClose,
        "could not close the JACK client",
        backend,
        "status=" & $status,
      )
      if hadPrimary:
        return failure[Unit](appendPrimary(cleanup, primary))
      return failure[Unit](cleanup)
    backend.client = nil
    backend.portOwner.discardAfterClientClose()
    backend.stateValue = jbsOpen

  if backend.callbackContext != nil:
    if not backend.callbackContext.callbackContextReadyForRelease():
      let cleanup = backendError(
        hekJackQuiescence,
        "JACK callbacks remained active after client close",
        backend,
      )
      if hadPrimary:
        return failure[Unit](appendPrimary(cleanup, primary))
      return failure[Unit](cleanup)
    deallocShared(backend.callbackContext)
    backend.callbackContext = nil

  if backend.api.isOpen:
    let closedApi = backend.api.close()
    if not closedApi.isOk:
      if hadPrimary:
        return failure[Unit](appendPrimary(closedApi.error, primary))
      return closedApi

  backend.stateValue = jbsClosed
  backend.actualClientNameValue.setLen(0)
  backend.sampleRateValue = 0'u32
  backend.bufferSizeValue = 0'u32
  backend.configurationGenerationValue = 0'u64
  if hadPrimary:
    return failure[Unit](primary)
  success()

proc cleanupApiFailure(api: var JackApi; primary: HostError): HostError =
  let cleanup = api.close()
  if cleanup.isOk:
    primary
  else:
    appendPrimary(cleanup.error, primary)

proc cleanupBackendFailure(backend: var JackBackend;
                           primary: HostError): HostError =
  let cleanup = backend.close()
  if cleanup.isOk:
    primary
  else:
    appendPrimary(cleanup.error, primary)

proc readStableRuntimeConfiguration(backend: var JackBackend):
    Result[JackRuntimeConfiguration] =
  var attempt = 0
  while attempt < RuntimeConfigurationReadAttempts:
    let generation = backend.callbackContext.configurationGeneration()
    let sampleRate = backend.api.functions.getSampleRate(backend.client)
    let bufferSize = backend.api.functions.getBufferSize(backend.client)
    if sampleRate == 0'u32 or bufferSize == 0'u32:
      return failure[JackRuntimeConfiguration](backendError(
        hekJackActivation,
        "JACK returned an invalid runtime audio configuration",
        backend,
        "sample-rate=" & $sampleRate & "; buffer-size=" & $bufferSize,
      ))
    if backend.callbackContext.configurationReadStable(generation):
      backend.sampleRateValue = sampleRate
      backend.bufferSizeValue = bufferSize
      backend.configurationGenerationValue = generation
      return success(JackRuntimeConfiguration(
        sampleRate: sampleRate,
        bufferSize: bufferSize,
      ))
    inc attempt
  failure[JackRuntimeConfiguration](backendError(
    hekJackQuiescence,
    "JACK runtime configuration changed during its control-plane snapshot",
    backend,
    "attempts=" & $RuntimeConfigurationReadAttempts,
  ))

proc openJackBackend*(config: JackBackendOpenConfig): Result[JackBackend] =
  if config.clientName.len == 0 or config.clientName.hasEmbeddedNul:
    return failure[JackBackend](configError(
      hekJackClientOpen,
      "requested JACK client name is invalid",
      config,
    ))
  if config.serverName.isSome and
      (config.serverName.get.len == 0 or config.serverName.get.hasEmbeddedNul):
    return failure[JackBackend](configError(
      hekJackClientOpen,
      "requested JACK server name is invalid",
      config,
    ))

  var openedApi = openJackApi(config.libraryPath)
  if not openedApi.isOk:
    return failure[JackBackend](openedApi.error)
  var api = move(openedApi.value)

  let clientNameLimit = api.functions.clientNameSize()
  if clientNameLimit <= 1 or config.clientName.len + 1 > clientNameLimit:
    let primary = configError(
      hekJackClientOpen,
      "requested JACK client name exceeds the library limit",
      config,
      "required=" & $(config.clientName.len + 1) &
        "; limit=" & $clientNameLimit,
    )
    return failure[JackBackend](cleanupApiFailure(api, primary))

  var status = JackNullOption
  var options = JackNullOption
  if config.noStartServer:
    options = options or JackNoStartServer
  if config.serverName.isSome:
    options = options or JackServerName

  let client = if config.serverName.isSome:
      api.functions.clientOpen(
        config.clientName.cstring, options, addr status,
        config.serverName.get.cstring)
    else:
      api.functions.clientOpen(config.clientName.cstring, options, addr status)
  if client == nil:
    let primary = configError(
      hekJackClientOpen,
      "could not open the requested JACK client",
      config,
      status.formatJackStatus,
    )
    return failure[JackBackend](cleanupApiFailure(api, primary))

  var backend = JackBackend(
    api: move(api),
    client: client,
    stateValue: jbsOpen,
    requestedClientName: config.clientName,
    serverNameValue: config.serverName,
    clientNameSizeValue: clientNameLimit,
  )

  let copiedName = copiedClientName(
    backend.api.functions.getClientName(client), clientNameLimit, config)
  if not copiedName.isOk:
    return failure[JackBackend](backend.cleanupBackendFailure(copiedName.error))
  backend.actualClientNameValue = copiedName.value
  backend.portNameSizeValue = backend.api.functions.portNameSize()
  if backend.portNameSizeValue <= 2:
    let primary = backendError(
      hekJackPortName,
      "JACK reported an invalid port-name limit",
      backend,
      "limit=" & $backend.portNameSizeValue,
    )
    return failure[JackBackend](backend.cleanupBackendFailure(primary))

  backend.callbackContext = cast[ptr JackCallbackContext](
    allocShared0(sizeof(JackCallbackContext)))
  doAssert backend.callbackContext.initJackCallbackContext(
    backend.api.functions)
  let initialSampleRate = backend.api.functions.getSampleRate(client)
  let initialBufferSize = backend.api.functions.getBufferSize(client)
  if initialSampleRate == 0'u32 or initialBufferSize == 0'u32:
    let primary = backendError(
      hekJackClientOpen,
      "JACK returned an invalid initial audio configuration",
      backend,
      "sample-rate=" & $initialSampleRate &
        "; buffer-size=" & $initialBufferSize,
    )
    return failure[JackBackend](backend.cleanupBackendFailure(primary))
  if not backend.callbackContext.setRuntimeConfigurationBaseline(
      initialSampleRate, initialBufferSize):
    let primary = backendError(
      hekJackClientOpen,
      "could not establish the initial JACK audio configuration baseline",
      backend,
    )
    return failure[JackBackend](backend.cleanupBackendFailure(primary))
  let registered = backend.registerCallbacks()
  if not registered.isOk:
    return failure[JackBackend](backend.cleanupBackendFailure(registered.error))

  var currentConfiguration = backend.readStableRuntimeConfiguration()
  if not currentConfiguration.isOk:
    return failure[JackBackend](backend.cleanupBackendFailure(
      move(currentConfiguration.error)))
  if not backend.callbackContext.clearConfigurationPending(
      currentConfiguration.value.sampleRate,
      currentConfiguration.value.bufferSize,
      backend.configurationGenerationValue):
    let primary = backendError(
      hekJackClientOpen,
      "could not acknowledge the initial JACK audio configuration",
      backend,
    )
    return failure[JackBackend](backend.cleanupBackendFailure(primary))
  success(move(backend))

proc configureRealized(backend: var JackBackend; plan: PortPlan;
                       mode: FakeProcessMode;
                       endpoint: RtProcessEndpoint): Result[Unit] =
  if backend.stateValue != jbsOpen or backend.client == nil or
      backend.callbackContext == nil:
    return failure[Unit](backendError(
      hekJackPortRegistration,
      "JACK backend is not open for configuration",
      backend,
      "state=" & $backend.stateValue,
    ))

  var candidateMap: RtPortMap
  var candidateOwner: JackPortOwner
  var rollbackComplete = false
  let realized = realizePortPlan(
    backend.api.functions,
    backend.client,
    backend.actualClientNameValue,
    backend.portNameSizeValue,
    plan,
    candidateMap,
    candidateOwner,
    rollbackComplete,
  )
  if not realized.isOk:
    if not rollbackComplete:
      let cleanup = backend.close()
      if not cleanup.isOk:
        return failure[Unit](appendPrimary(cleanup.error, realized.error))
    return realized

  let configured = if endpoint.callback != nil:
      backend.callbackContext.configureEndpointCallbacks(candidateMap, endpoint)
    else:
      backend.callbackContext.configureCallbacks(candidateMap, mode)
  if not configured:
    let rollback = candidateOwner.unregisterOwnedPorts(
      backend.api.functions, backend.client, backend.actualClientNameValue)
    let primary = backendError(
      hekJackPortRegistration,
      "could not publish the JACK real-time port map",
      backend,
    )
    if not rollback.isOk:
      let cleanup = backend.close()
      if not cleanup.isOk:
        return failure[Unit](appendPrimary(cleanup.error, rollback.error))
      return failure[Unit](appendPrimary(rollback.error, primary))
    return failure[Unit](primary)

  backend.portOwner = move(candidateOwner)
  backend.stateValue = jbsConfigured
  success()

proc configure*(backend: var JackBackend; plan: PortPlan;
                mode: FakeProcessMode): Result[Unit] =
  backend.configureRealized(plan, mode, RtProcessEndpoint())

proc configure*(backend: var JackBackend; plan: PortPlan;
                endpoint: RtProcessEndpoint): Result[Unit] =
  if endpoint.callback == nil:
    return failure[Unit](backendError(
      hekJackPortRegistration,
      "JACK process endpoint is not configured",
      backend,
    ))
  backend.configureRealized(plan, fpmSilence, endpoint)

proc updateProcessEndpoint*(backend: var JackBackend;
                             endpoint: RtProcessEndpoint): Result[Unit] =
  if backend.stateValue != jbsConfigured or backend.callbackContext == nil:
    return failure[Unit](backendError(
      hekJackActivation,
      "JACK process endpoint can only be updated while configured",
      backend,
      "state=" & $backend.stateValue,
    ))
  if not backend.callbackContext.updateProcessEndpoint(endpoint):
    return failure[Unit](backendError(
      hekJackQuiescence,
      "could not update the JACK process endpoint while inactive",
      backend,
    ))
  success()

proc refreshRuntimeConfiguration*(backend: var JackBackend):
    Result[JackRuntimeConfiguration] =
  if backend.client == nil or backend.callbackContext == nil or
      backend.stateValue == jbsClosed or backend.stateValue == jbsActive:
    return failure[JackRuntimeConfiguration](backendError(
      hekJackActivation,
      "JACK runtime configuration can only be refreshed while inactive",
      backend,
      "state=" & $backend.stateValue,
    ))
  backend.readStableRuntimeConfiguration()

proc acknowledgeConfigurationChange*(backend: var JackBackend): Result[Unit] =
  if backend.stateValue != jbsConfigured or backend.callbackContext == nil:
    return failure[Unit](backendError(
      hekJackActivation,
      "JACK configuration changes can only be acknowledged while configured",
      backend,
      "state=" & $backend.stateValue,
    ))
  if not backend.callbackContext.clearConfigurationPending(
      backend.sampleRateValue,
      backend.bufferSizeValue,
      backend.configurationGenerationValue):
    return failure[Unit](backendError(
      hekJackQuiescence,
      "JACK callbacks are not quiescent for configuration acknowledgement",
      backend,
    ))
  success()
