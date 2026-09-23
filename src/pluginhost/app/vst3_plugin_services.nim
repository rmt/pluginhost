## Application-owned composition seam for headless VST3 services.
## Policy stays in the application layer; VST3 owns only ABI object behavior.

import ./main_reactor
import ../domain/[errors, result]
import ../vst3/[ffi, host_context, instance, module]
type
  Vst3PluginServices* = ref object
    context: Vst3HostContext

proc newVst3PluginServices*(context: Vst3HostContext): Vst3PluginServices =
  new(result)
  result.context = context

proc newVst3PluginServices*(reactor: var MainReactor;
                            hostName = "pluginhost"): Vst3PluginServices =
  newVst3PluginServices(newVst3HostContext(addr reactor, hostName))

proc context*(services: Vst3PluginServices): Vst3HostContext {.inline.} =
  if services == nil: nil else: services.context

proc hostApplication*(services: Vst3PluginServices): ptr Vst3HostApplication {.inline.} =
  if services == nil or services.context == nil: nil
  else: services.context.hostApplicationPointer()

proc runLoop*(services: Vst3PluginServices): ptr Vst3RunLoop {.inline.} =
  if services == nil or services.context == nil: nil
  else: services.context.runLoopPointer()

proc openInstance*(services: Vst3PluginServices; module: var Vst3Module;
                   classId: Vst3Tuid; loadStatePath = ""): Result[Vst3Instance] =
  if services == nil or services.context == nil:
    return failure[Vst3Instance](hostError(
      hsVst3, hekVst3Factory, "VST3 plugin services have no host context"))
  openVst3Instance(module, classId, nil, services.context, loadStatePath)

proc close*(services: Vst3PluginServices;
            allowRetainedHostReferences = false): Result[Unit] =
  if services == nil or services.context == nil:
    return success()
  if allowRetainedHostReferences:
    if not services.context.retire():
      return failure[Unit](hostError(hsVst3, hekVst3Factory,
        "VST3 plugin services could not remove all callback registrations"))
  else:
    services.context.close()
    if services.context.hasRetainedCallbacks() or
        services.context.hasRetainedObjects():
      return failure[Unit](hostError(hsVst3, hekVst3Factory,
        "VST3 plugin services remain retained during shutdown"))
  success()
