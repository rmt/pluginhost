import std/math

import ./[audio_process, ffi, host_bridge, loader, main_thread_services,
          port_inspector]
import ../domain/[errors, plugin_catalog, port_plan, result]
import ../rt/role_guard

type
  ClapInstanceState* = enum
    cisUnloaded
    cisInitialized
    cisActivated
    cisProcessing
    cisDestroyed
    cisClosed

  ClapPluginExtensions* = object
    audioPorts*: ptr ClapPluginAudioPorts
    notePorts*: ptr ClapPluginNotePorts
    render*: ptr ClapPluginRender
    latency*: ptr ClapPluginLatency
    timerSupport*: ptr ClapPluginTimerSupport
    posixFdSupport*: ptr ClapPluginPosixFdSupport

  ClapInstance* = object
    module: ClapModule
    bridge: ClapHostBridge
    plugin: ptr ClapPlugin
    descriptor: PluginDescriptor
    extensions: ClapPluginExtensions
    state: ClapInstanceState
    nextPortPlanVersion: uint64

proc `=destroy`*(instance: var ClapInstance) =
  doAssert instance.plugin == nil,
    "an initialized ClapInstance must be explicitly closed"
  `=destroy`(instance.module)
  `=destroy`(instance.bridge)
  `=destroy`(instance.descriptor)

proc `=copy`*(destination: var ClapInstance; source: ClapInstance) {.error:
  "ClapInstance owns foreign resources and cannot be copied; use move".}
proc `=dup`*(source: ClapInstance): ClapInstance {.error:
  "ClapInstance owns foreign resources and cannot be duplicated; use move".}

proc `=sink`*(destination: var ClapInstance; source: ClapInstance) =
  doAssert destination.plugin == nil,
    "an initialized ClapInstance must be closed before move assignment"
  `=sink`(destination.module, source.module)
  `=sink`(destination.bridge, source.bridge)
  `=sink`(destination.descriptor, source.descriptor)
  destination.plugin = source.plugin
  destination.extensions = source.extensions
  destination.state = source.state
  destination.nextPortPlanVersion = source.nextPortPlanVersion

proc instanceError(kind: HostErrorKind; message, path: string;
                   detail = ""): HostError =
  var context = "path=" & path
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsClap, kind, message, context)

proc cleanupModuleFailure(module: var ClapModule;
                          primary: HostError): HostError =
  let cleanup = module.close()
  if cleanup.isOk:
    return primary
  result = cleanup.error
  result.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    result.context.add(" (" & primary.context & ")")

proc cleanupPluginFailure(module: var ClapModule; plugin: ptr ClapPlugin;
                          primary: HostError): HostError =
  if plugin != nil and plugin.destroy != nil:
    plugin.destroy(plugin)
  cleanupModuleFailure(module, primary)

proc missingCallback(plugin: ptr ClapPlugin): string =
  if plugin.desc == nil:
    return "desc"
  if plugin.init == nil:
    return "init"
  if plugin.destroy == nil:
    return "destroy"
  if plugin.activate == nil:
    return "activate"
  if plugin.deactivate == nil:
    return "deactivate"
  if plugin.startProcessing == nil:
    return "start_processing"
  if plugin.stopProcessing == nil:
    return "stop_processing"
  if plugin.reset == nil:
    return "reset"
  if plugin.process == nil:
    return "process"
  if plugin.getExtension == nil:
    return "get_extension"
  if plugin.onMainThread == nil:
    return "on_main_thread"
  ""

proc descriptorIdMatches(value: cstring; expected: string): bool =
  if value == nil:
    return false
  let bytes = cast[ptr UncheckedArray[char]](value)
  for index in 0 ..< expected.len:
    if bytes[index] == '\0' or bytes[index] != expected[index]:
      return false
  bytes[expected.len] == '\0'

proc invalidCreatedDescriptor(plugin: ptr ClapPlugin;
                              expected: PluginDescriptor): string =
  if not plugin.desc.clapVersion.isCompatible:
    return "desc.clap_version"
  if not descriptorIdMatches(plugin.desc.id, expected.id):
    return "desc.id"
  ""

proc createClapInstance*(module: sink ClapModule;
                         descriptor: sink PluginDescriptor;
                         mainServices: ptr ClapMainThreadServices = nil):
                         Result[ClapInstance] =
  var ownedModule = move(module)
  let bridge = newClapHostBridge(mainServices)
  let created = ownedModule.createPlugin(
    bridge.hostPointer, descriptor.id)
  if not created.isOk:
    return failure[ClapInstance](cleanupModuleFailure(
      ownedModule, created.error))

  let plugin = created.value
  let missing = missingCallback(plugin)
  if missing.len > 0:
    let primary = instanceError(
      hekClapPlugin,
      "CLAP factory returned a plugin with a missing required callback",
      ownedModule.modulePath,
      "field=" & missing,
    )
    return failure[ClapInstance](cleanupPluginFailure(
      ownedModule, plugin, primary))

  let invalidDescriptor = invalidCreatedDescriptor(plugin, descriptor)
  if invalidDescriptor.len > 0:
    let primary = instanceError(
      hekClapPlugin,
      "CLAP factory returned a plugin with an invalid descriptor",
      ownedModule.modulePath,
      "field=" & invalidDescriptor & "; id=" & descriptor.id,
    )
    return failure[ClapInstance](cleanupPluginFailure(
      ownedModule, plugin, primary))

  if not plugin.init(plugin):
    let primary = instanceError(
      hekClapPluginInit,
      "CLAP plugin initialization failed",
      ownedModule.modulePath,
      "id=" & descriptor.id,
    )
    return failure[ClapInstance](cleanupPluginFailure(
      ownedModule, plugin, primary))

  let extensions = ClapPluginExtensions(
    audioPorts: cast[ptr ClapPluginAudioPorts](
      plugin.getExtension(plugin, ClapExtAudioPorts.cstring)),
    notePorts: cast[ptr ClapPluginNotePorts](
      plugin.getExtension(plugin, ClapExtNotePorts.cstring)),
    render: cast[ptr ClapPluginRender](
      plugin.getExtension(plugin, ClapExtRender.cstring)),
    latency: cast[ptr ClapPluginLatency](
      plugin.getExtension(plugin, ClapExtLatency.cstring)),
    timerSupport: cast[ptr ClapPluginTimerSupport](
      plugin.getExtension(plugin, ClapExtTimerSupport.cstring)),
    posixFdSupport: cast[ptr ClapPluginPosixFdSupport](
      plugin.getExtension(plugin, ClapExtPosixFdSupport.cstring)),
  )

  success(ClapInstance(
    module: move(ownedModule),
    bridge: bridge,
    plugin: plugin,
    descriptor: move(descriptor),
    extensions: extensions,
    state: cisInitialized,
    nextPortPlanVersion: 1'u64,
  ))

proc state*(instance: ClapInstance): ClapInstanceState {.inline, gcsafe,
    raises: [].} =
  instance.state

proc modulePath*(instance: ClapInstance): string {.inline.} =
  instance.module.modulePath

proc selectedDescriptor*(instance: ClapInstance): PluginDescriptor =
  instance.descriptor

proc pluginExtensions*(instance: ClapInstance): ClapPluginExtensions =
  instance.extensions

proc inspectPortPlan*(instance: var ClapInstance): Result[PortPlan] =
  if instance.state != cisInitialized:
    return failure[PortPlan](instanceError(
      hekClapPorts,
      "CLAP port inspection requires an initialized, deactivated plugin",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  if not instance.bridge.isMainThread:
    return failure[PortPlan](instanceError(
      hekClapPorts,
      "CLAP port inspection must run on the host main thread",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  if instance.nextPortPlanVersion == high(uint64):
    return failure[PortPlan](instanceError(
      hekClapPorts,
      "CLAP port-plan generation is exhausted",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))

  var inspected = port_inspector.inspectClapPorts(
    instance.plugin,
    instance.extensions.audioPorts,
    instance.extensions.notePorts,
    portPlanVersion(instance.nextPortPlanVersion),
    instance.module.modulePath,
    instance.descriptor.id,
  )
  if not inspected.isOk:
    return failure[PortPlan](move(inspected.error))
  inc instance.nextPortPlanVersion
  success(move(inspected.value))

proc negotiateRealtimeRender*(instance: var ClapInstance):
    Result[ClapRenderNegotiation] =
  if instance.state != cisInitialized:
    return failure[ClapRenderNegotiation](instanceError(
      hekClapRender,
      "CLAP render negotiation requires an initialized, deactivated plugin",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  if not instance.bridge.isMainThread:
    return failure[ClapRenderNegotiation](instanceError(
      hekClapRender,
      "CLAP render negotiation must run on the host main thread",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  port_inspector.negotiateClapRealtimeRender(
    instance.plugin,
    instance.extensions.render,
    instance.module.modulePath,
    instance.descriptor.id,
  )

proc hostBridge*(instance: ClapInstance): ClapHostBridge {.inline.} =
  instance.bridge

proc activate*(instance: var ClapInstance; sampleRate: float64;
                minFrames, maxFrames: uint32): Result[Unit] =
  if instance.state != cisInitialized:
    return failure[Unit](instanceError(
      hekClapActivation,
      "CLAP activation requires an initialized, deactivated plugin",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  if not instance.bridge.isMainThread:
    return failure[Unit](instanceError(
      hekClapActivation,
      "CLAP activation must run on the host main thread",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  if sampleRate <= 0.0 or classify(sampleRate) in {fcNan, fcInf, fcNegInf}:
    return failure[Unit](instanceError(
      hekClapActivation,
      "CLAP activation requires a finite positive sample rate",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; sample-rate=" & $sampleRate,
    ))
  if minFrames == 0'u32 or maxFrames == 0'u32 or minFrames > maxFrames or
      maxFrames > uint32(high(int32)):
    return failure[Unit](instanceError(
      hekClapActivation,
      "CLAP activation frame range is invalid",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; min=" & $minFrames &
        "; max=" & $maxFrames,
    ))
  if not instance.plugin.activate(instance.plugin, sampleRate,
                                  minFrames, maxFrames):
    return failure[Unit](instanceError(
      hekClapActivation,
      "CLAP plugin activation failed",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; sample-rate=" & $sampleRate &
        "; max-frames=" & $maxFrames,
    ))
  instance.state = cisActivated
  success()

proc startProcessing*(instance: var ClapInstance;
                      role: ptr AudioRoleGuard): Result[Unit] =
  if instance.state != cisActivated:
    return failure[Unit](instanceError(
      hekClapStartProcessing,
      "CLAP start_processing requires an active, non-processing plugin",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  if not instance.bridge.isMainThread or role == nil:
    return failure[Unit](instanceError(
      hekClapStartProcessing,
      "CLAP start_processing must run on the host main thread with an audio role",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  if not instance.bridge.attachAudioRole(role):
    return failure[Unit](instanceError(
      hekClapStartProcessing,
      "could not attach the symbolic CLAP audio role to thread-check",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  if not tryEnterAudioRole(role):
    return failure[Unit](instanceError(
      hekClapStartProcessing,
      "could not claim the symbolic CLAP audio role for start_processing",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  let started = instance.plugin.startProcessing(instance.plugin)
  if not started:
    discard leaveAudioRole(role)
    return failure[Unit](instanceError(
      hekClapStartProcessing,
      "CLAP plugin start_processing failed",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  if not leaveAudioRole(role):
    return failure[Unit](instanceError(
      hekClapStartProcessing,
      "could not release the symbolic CLAP audio role after start_processing",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  instance.state = cisProcessing
  success()

proc stopProcessing*(instance: var ClapInstance;
                     role: ptr AudioRoleGuard): Result[Unit] =
  if instance.state == cisActivated or instance.state == cisInitialized:
    return success()
  if instance.state != cisProcessing:
    return failure[Unit](instanceError(
      hekClapStopProcessing,
      "CLAP stop_processing requires an active plugin",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  if not instance.bridge.isMainThread or role == nil or
      not instance.bridge.attachAudioRole(role) or
      not tryEnterAudioRole(role):
    return failure[Unit](instanceError(
      hekClapStopProcessing,
      "CLAP stop_processing could not claim the symbolic audio role",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  instance.plugin.stopProcessing(instance.plugin)
  if not leaveAudioRole(role):
    return failure[Unit](instanceError(
      hekClapStopProcessing,
      "could not release the symbolic CLAP audio role after stop_processing",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  instance.state = cisActivated
  success()

proc deactivate*(instance: var ClapInstance): Result[Unit] =
  case instance.state
  of cisInitialized:
    return success()
  of cisActivated:
    discard
  of cisProcessing:
    return failure[Unit](instanceError(
      hekClapDeactivation,
      "CLAP deactivation requires stopped processing",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  of cisUnloaded, cisDestroyed, cisClosed:
    return failure[Unit](instanceError(
      hekClapDeactivation,
      "CLAP deactivation requires a live initialized plugin",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  if not instance.bridge.isMainThread:
    return failure[Unit](instanceError(
      hekClapDeactivation,
      "CLAP deactivation must run on the host main thread",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  instance.plugin.deactivate(instance.plugin)
  instance.state = cisInitialized
  success()

proc newAudioProcess*(instance: var ClapInstance; plan: PortPlan;
                      maxFrames: uint32; role: ptr AudioRoleGuard):
    Result[ClapAudioProcess] =
  if instance.state != cisInitialized or not instance.bridge.isMainThread:
    return failure[ClapAudioProcess](instanceError(
      hekClapProcess,
      "CLAP audio process construction requires the main-thread deactivated state",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  newClapAudioProcess(instance.plugin, plan, maxFrames, role,
                      instance.module.modulePath, instance.descriptor.id)

proc takeRequests*(instance: ClapInstance): uint32 {.gcsafe, raises: [].} =
  instance.bridge.takeRequests()

proc tryPopLog*(instance: ClapInstance;
                record: var ClapHostLogRecord): bool {.gcsafe, raises: [].} =
  instance.bridge.tryPopLog(record)

proc takeDroppedLogs*(instance: ClapInstance): uint64 {.gcsafe, raises: [].} =
  instance.bridge.takeDroppedLogs()

proc takeStateDirty*(instance: ClapInstance): bool {.gcsafe, raises: [].} =
  instance.bridge.takeStateDirty()

proc takeLatencyChanged*(instance: ClapInstance): bool {.gcsafe, raises: [].} =
  instance.bridge.takeLatencyChanged()

proc latencyFrames*(instance: var ClapInstance): Result[uint32] =
  if instance.state notin {cisActivated, cisProcessing} or
      not instance.bridge.isMainThread:
    return failure[uint32](instanceError(
      hekClapPlugin,
      "CLAP latency inspection requires an active plugin on the main thread",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  if instance.extensions.latency == nil:
    discard instance.bridge.takeLatencyChanged()
    return success(0'u32)
  if instance.extensions.latency.get == nil:
    return failure[uint32](instanceError(
      hekClapPlugin,
      "CLAP latency extension has a missing get callback",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  let frames = instance.extensions.latency.get(instance.plugin)
  discard instance.bridge.takeLatencyChanged()
  success(frames)

proc callOnTimer*(instance: var ClapInstance; timerId: uint32): Result[Unit] =
  if instance.state notin {cisInitialized, cisActivated, cisProcessing} or
      not instance.bridge.isMainThread or instance.extensions.timerSupport == nil or
      instance.extensions.timerSupport.onTimer == nil:
    return failure[Unit](instanceError(
      hekClapPlugin, "CLAP timer callback is unavailable",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; timer-id=" & $timerId,
    ))
  instance.extensions.timerSupport.onTimer(instance.plugin, timerId)
  success()

proc callOnFd*(instance: var ClapInstance; fd: int32; flags: uint32): Result[Unit] =
  if instance.state notin {cisInitialized, cisActivated, cisProcessing} or
      not instance.bridge.isMainThread or instance.extensions.posixFdSupport == nil or
      instance.extensions.posixFdSupport.onFd == nil:
    return failure[Unit](instanceError(
      hekClapPlugin, "CLAP POSIX FD callback is unavailable",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; fd=" & $fd,
    ))
  instance.extensions.posixFdSupport.onFd(instance.plugin, cint(fd), flags)
  success()

proc callOnMainThread*(instance: var ClapInstance): Result[Unit] =
  if instance.state notin {cisInitialized, cisActivated, cisProcessing} or
      instance.plugin == nil:
    return failure[Unit](instanceError(
      hekClapPlugin,
      "CLAP on_main_thread requires a live initialized plugin",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  if not instance.bridge.isMainThread:
    return failure[Unit](instanceError(
      hekClapPlugin,
      "CLAP on_main_thread must run on the host main thread",
      instance.module.modulePath,
      "id=" & instance.descriptor.id,
    ))
  instance.plugin.onMainThread(instance.plugin)
  success()

proc destroy*(instance: var ClapInstance): Result[Unit] =
  case instance.state
  of cisInitialized:
    if not instance.bridge.isMainThread:
      return failure[Unit](instanceError(
        hekClapPlugin,
        "CLAP plugin destruction must run on the host main thread",
        instance.module.modulePath,
        "id=" & instance.descriptor.id,
      ))
    instance.plugin.destroy(instance.plugin)
    instance.plugin = nil
    instance.extensions = ClapPluginExtensions()
    instance.state = cisDestroyed
  of cisUnloaded:
    instance.state = cisDestroyed
  of cisActivated, cisProcessing:
    return failure[Unit](instanceError(
      hekClapPlugin,
      "CLAP plugin must be stopped and deactivated before destruction",
      instance.module.modulePath,
      "id=" & instance.descriptor.id & "; state=" & $instance.state,
    ))
  of cisDestroyed, cisClosed:
    discard
  success()

proc close*(instance: var ClapInstance): Result[Unit] =
  if instance.state == cisClosed:
    return success()

  let destroyed = instance.destroy()
  if not destroyed.isOk:
    return destroyed

  let closed = instance.module.close()
  if not closed.isOk:
    return failure[Unit](closed.error)
  instance.state = cisClosed
  success()
