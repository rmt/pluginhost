import std/[os, unittest]

import pluginhost/app/audio_slice
import pluginhost/clap/loader
import pluginhost/domain/[plugin_catalog, result]
import pluginhost/jack/backend

proc smokePluginPath(): string =
  result = getEnv("PLUGINHOST_CLAP_SMOKE_PLUGIN")
  require result.len > 0
  require result.isAbsolute
  require fileExists(result)

proc openSmokeSlice(): InternalAudioSlice =
  let path = smokePluginPath()
  var moduleResult = openClapModule(path)
  require moduleResult.isOk
  var module = move(moduleResult.value)
  let catalog = module.readCatalog()
  require catalog.isOk

  let pluginId = getEnv("PLUGINHOST_CLAP_SMOKE_PLUGIN_ID")
  let selector = if pluginId.len == 0:
      PluginSelector(kind: pskImplicitSingle)
    else:
      PluginSelector(kind: pskId, pluginId: pluginId)
  var selected = catalog.value.selectDescriptor(selector)
  require selected.isOk

  var opened = openInternalAudioSlice(move(module), move(selected.value),
    initJackBackendOpenConfig("pluginhost-5-clap-smoke", noStartServer = true))
  require opened.isOk
  result = move(opened.value)

proc waitForSmokeCycles(backend: JackBackend; target: uint64): bool =
  var attempt = 0
  while attempt < 5_000:
    if backend.notifications().processCycles >= target:
      return true
    sleep(1)
    inc attempt
  false

suite "independent CLAP audio smoke":
  test "headless plugin survives the internal JACK/CLAP audio lifecycle":
    # This is an explicit environment prerequisite, not a portable dependency:
    # the task must fail if its independently installed plugin is unavailable.
    var slice = openSmokeSlice()
    defer:
      doAssert slice.close().isOk

    check slice.state == iassReady
    require slice.start().isOk
    require slice.jackBackend().waitForSmokeCycles(8'u64)
    let snapshot = slice.jackBackend().notifications()
    check snapshot.processErrors == 0
    check snapshot.lateProcessCalls == 0
    check snapshot.processFrames >= 8'u64 *
      uint64(slice.jackBackend().bufferSize)
    check slice.stop().isOk
    check slice.state == iassReady
