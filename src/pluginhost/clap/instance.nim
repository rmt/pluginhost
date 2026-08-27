import ./[ffi, host_bridge, loader]
import ../domain/[errors, plugin_catalog, result]

type
  ClapInstanceState* = enum
    cisUnloaded
    cisInitialized
    cisDestroyed
    cisClosed

  ClapPluginExtensions* = object
    audioPorts*: ptr ClapPluginAudioPorts
    notePorts*: ptr ClapPluginNotePorts

  ClapInstance* = object
    module: ClapModule
    bridge: ClapHostBridge
    plugin: ptr ClapPlugin
    descriptor: PluginDescriptor
    extensions: ClapPluginExtensions
    state: ClapInstanceState

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
                         descriptor: sink PluginDescriptor): Result[ClapInstance] =
  var ownedModule = move(module)
  let bridge = newClapHostBridge()
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
  )

  success(ClapInstance(
    module: move(ownedModule),
    bridge: bridge,
    plugin: plugin,
    descriptor: move(descriptor),
    extensions: extensions,
    state: cisInitialized,
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

proc hostBridge*(instance: ClapInstance): ClapHostBridge {.inline.} =
  instance.bridge

proc takeRequests*(instance: ClapInstance): uint32 {.gcsafe, raises: [].} =
  instance.bridge.takeRequests()

proc tryPopLog*(instance: ClapInstance;
                record: var ClapHostLogRecord): bool {.gcsafe, raises: [].} =
  instance.bridge.tryPopLog(record)

proc takeDroppedLogs*(instance: ClapInstance): uint64 {.gcsafe, raises: [].} =
  instance.bridge.takeDroppedLogs()

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
