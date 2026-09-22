import std/[os, unittest]

import pluginhost/app/[vst3_audio_slice, vst3_plugin_services]
import pluginhost/domain/result
import pluginhost/jack/backend
import pluginhost/platform/linux/dynlib
import pluginhost/vst3/[ffi, host_context, instance, module, uid]
import ./jack/fixture_api

const ClassId = "102132435465768798A9BACBDCEDFEFF"

type
  SetIntProc = proc(value: int32) {.cdecl, raises: [].}
  SetDoubleProc = proc(value: float64) {.cdecl, raises: [].}
  GetDoubleProc = proc(): float64 {.cdecl, raises: [].}
  CounterProc = proc(): uint32 {.cdecl, raises: [].}
  SampleProc = proc(): int64 {.cdecl, raises: [].}
  VoidProc = proc() {.cdecl, raises: [].}

proc fixtureDirectory(): string =
  result = getEnv("PLUGINHOST_VST3_V4B2_FIXTURE_DIR")
  doAssert result.len > 0
proc fixturePath(): string = fixtureDirectory() / "v4b2.vst3"
proc fixtureBinary(): string =
  fixturePath() / "Contents" / Vst3ArchitectureDir / "v4b2.so"
proc fakeJackPath(): string =
  result = getEnv("PLUGINHOST_JACK_FAKE_FIXTURE")
  doAssert result.len > 0

proc resolveFixture[T](name: string): T =
  var opened = openDynamicLibrary(fixtureBinary(), keepLoaded = true)
  doAssert opened.isOk
  var library = move(opened.value)
  let resolved = resolveSymbol[T](library, name)
  doAssert resolved.isOk
  result = resolved.value
  doAssert library.close().isOk

proc setFlag(name: string; value: int32) =
  resolveFixture[SetIntProc](name)(value)
proc setGain(value: float64) =
  resolveFixture[SetDoubleProc]("pluginhost_vst3_v4b2_set_gain")(value)
proc setOutput(value: float64) =
  resolveFixture[SetDoubleProc]("pluginhost_vst3_v4b2_set_output")(value)
proc gain(): float64 =
  resolveFixture[GetDoubleProc]("pluginhost_vst3_v4b2_gain")()
proc output(): float64 =
  resolveFixture[GetDoubleProc]("pluginhost_vst3_v4b2_output")()
proc counter(name: string): uint32 = resolveFixture[CounterProc](name)()
proc lastSamplePosition(): int64 =
  resolveFixture[SampleProc]("pluginhost_vst3_v4b2_last_sample_position")()
proc releaseRetained() =
  resolveFixture[VoidProc]("pluginhost_vst3_v4b2_release_retained_stream")()

proc openSlice(services: Vst3PluginServices): Result[Vst3AudioSlice] =
  var loaded = openVst3Module(fixturePath())
  if not loaded.isOk:
    return failure[Vst3AudioSlice](move(loaded.error))
  var library = move(loaded.value)
  var cid = parseVst3Uid(ClassId)
  if not cid.isOk:
    return failure[Vst3AudioSlice](move(cid.error))
  openVst3AudioSlice(services, library, cid.value,
    initJackBackendOpenConfig("vst3_v4b2", noStartServer = true,
      libraryPath = fakeJackPath()))

proc newServices(): Vst3PluginServices =
  newVst3PluginServices(newVst3HostContext())

proc triggerReload(slice: var Vst3AudioSlice): bool =
  let handler = slice.instance().componentHandlerPointer()
  handler != nil and handler.lpVtbl.restartComponent(cast[pointer](handler),
    Vst3RestartReloadComponent) == Vst3ResultOk

suite "private VST3 V4B2 full component reload":
  test "restores state, closes old module first, preserves JACK and callback":
    setFlag("pluginhost_vst3_v4b2_set_capture_fail", 0)
    setFlag("pluginhost_vst3_v4b2_set_retain_stream", 0)
    setFlag("pluginhost_vst3_v4b2_set_setup_fail", 0)
    setFlag("pluginhost_vst3_v4b2_set_activation_fail", 0)
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    let requestedName = $controls.requestedClientName()
    controls.setPortConnection(1, "external:playback")
    let connects = controls.connectCount()
    let ports = controls.currentPortCount()
    setGain(0.37)
    setOutput(0.81)
    check controls.invokeProcess(64) == 0
    let beforeEntries = counter("pluginhost_vst3_v4b2_module_entries")
    let beforeExits = counter("pluginhost_vst3_v4b2_module_exits")
    check triggerReload(slice)
    let report = slice.serviceReconfiguration()
    require report.isOk
    check counter("pluginhost_vst3_v4b2_module_entries") == beforeEntries + 1'u32
    check requestedName == $controls.requestedClientName()
    check abs(gain() - 0.37) < 0.0001
    check abs(output() - 0.81) < 0.0001
    check counter("pluginhost_vst3_v4b2_module_exits") == beforeExits + 1'u32
    check counter("pluginhost_vst3_v4b2_module_order_bad") == 0'u32
    check controls.connectCount() == connects
    check counter("pluginhost_vst3_v4b2_max_live_components") == 1'u32
    check controls.currentPortCount() == ports
    check slice.connectionLosses().len == 0
    check controls.invokeProcess(32) == 0
    check lastSamplePosition() == 64'i64
    check triggerReload(slice)
    let repeated = slice.serviceReconfiguration()
    require repeated.isOk
    check repeated.value.componentReloaded
    check counter("pluginhost_vst3_v4b2_module_entries") == beforeEntries + 2'u32
    check counter("pluginhost_vst3_v4b2_module_exits") == beforeExits + 2'u32
    check slice.close().isOk
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk

  test "structural reload reports loss without reconnecting":
    setFlag("pluginhost_vst3_v4b2_set_structural", 0)
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    controls.setPortConnection(1, "external:playback")
    let connects = controls.connectCount()
    setFlag("pluginhost_vst3_v4b2_set_structural", 1)
    check triggerReload(slice)
    let report = slice.serviceReconfiguration()
    require report.isOk
    check slice.connectionLosses().len > 0
    check controls.connectCount() == connects
    check controls.invokeProcess(32) == 0
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk
    setFlag("pluginhost_vst3_v4b2_set_structural", 0)

  test "not-implemented state capture reloads without empty restore calls":
    setFlag("pluginhost_vst3_v4b2_set_state_not_implemented", 1)
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    check triggerReload(slice)
    let report = slice.serviceReconfiguration()
    require report.isOk
    check report.value.componentReloaded
    check controls.invokeProcess(32) == 0
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk
    setFlag("pluginhost_vst3_v4b2_set_state_not_implemented", 0)

  test "component and controller capture failures keep old instance closeable":
    for failureName in ["pluginhost_vst3_v4b2_set_component_capture_fail",
                        "pluginhost_vst3_v4b2_set_controller_capture_fail"]:
      var controlsResult = openFakeJackControls()
      require controlsResult.isOk
      var controls = move(controlsResult.value)
      controls.reset()
      var services = newServices()
      var opened = openSlice(services)
      require opened.isOk
      var slice = move(opened.value)
      setFlag(failureName, 1)
      check triggerReload(slice)
      let report = slice.serviceReconfiguration()
      check not report.isOk
      check slice.state() == v3assQuiesced
      check not slice.jackBackend().processCallbacksEnabled()
      setFlag(failureName, 0)
      check slice.close().isOk
      check slice.close().isOk
      check services.close().isOk
      check controls.close().isOk

  test "replacement open initialization setup activation and restore failures enter terminal state":
    for failureName in ["pluginhost_vst3_v4b2_set_module_entry_fail",
                        "pluginhost_vst3_v4b2_set_component_initialize_fail",
                        "pluginhost_vst3_v4b2_set_setup_fail",
                        "pluginhost_vst3_v4b2_set_activation_fail",
                        "pluginhost_vst3_v4b2_set_component_restore_fail",
                        "pluginhost_vst3_v4b2_set_controller_restore_fail"]:
      var controlsResult = openFakeJackControls()
      require controlsResult.isOk
      var controls = move(controlsResult.value)
      controls.reset()
      var services = newServices()
      var opened = openSlice(services)
      require opened.isOk
      var slice = move(opened.value)
      setFlag(failureName, 1)
      check triggerReload(slice)
      let report = slice.serviceReconfiguration()
      check not report.isOk
      check counter("pluginhost_vst3_v4b2_max_live_components") == 1'u32
      check slice.state() == v3assFailed
      setFlag(failureName, 0)
      check slice.close().isOk
      check slice.close().isOk
      check services.close().isOk
      check controls.close().isOk

  test "post-reactivation JACK failure quiesces replacement before close":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    controls.setRecomputeStatus(-71)
    check triggerReload(slice)
    let report = slice.serviceReconfiguration()
    check not report.isOk
    check slice.state() == v3assFailed
    check not slice.jackBackend().processCallbacksEnabled()
    check slice.close().isOk
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk

  test "retained state stream blocks replacement until released":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    setFlag("pluginhost_vst3_v4b2_set_retain_stream", 1)
    check triggerReload(slice)
    let report = slice.serviceReconfiguration()
    check not report.isOk
    check slice.state() == v3assFailed
    setFlag("pluginhost_vst3_v4b2_set_retain_stream", 0)
    releaseRetained()
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk

