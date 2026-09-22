import std/[os, strutils, unittest]

import pluginhost/app/[vst3_audio_slice, vst3_plugin_services]
import pluginhost/domain/result
import pluginhost/jack/[backend, ffi]
import pluginhost/platform/linux/dynlib
import pluginhost/vst3/[ffi, host_context, instance, module, uid]
import ./jack/fixture_api

const ClassId = "102132435465768798A9BACBDCEDFEFF"

type
  TriggerProc = proc(flags: int32): uint32 {.cdecl, raises: [].}
  SetIntProc = proc(value: int32) {.cdecl, raises: [].}
  SetLatencyProc = proc(value: uint32) {.cdecl, raises: [].}
  CounterProc = proc(): uint32 {.cdecl, raises: [].}

proc fixtureDirectory(): string =
  result = getEnv("PLUGINHOST_VST3_V4B_FIXTURE_DIR")
  doAssert result.len > 0
proc fixturePath(name = "v4b"): string = fixtureDirectory() / (name & ".vst3")
proc fixtureBinary(name = "v4b"): string =
  fixturePath(name) / "Contents" / Vst3ArchitectureDir / (name & ".so")
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

proc setLatency(value: uint32) =
  resolveFixture[SetLatencyProc]("pluginhost_vst3_v4b_set_latency")(value)
proc trigger(flags: int32): uint32 =
  resolveFixture[TriggerProc]("pluginhost_vst3_v4b_trigger_restart")(flags)
proc setStructural(value: int32) =
  resolveFixture[SetIntProc]("pluginhost_vst3_v4b_set_structural")(value)
proc setGenerate(value: int32) =
  resolveFixture[SetIntProc]("pluginhost_vst3_v4b_set_generate")(value)
proc setMetadataFail(value: int32) =
  resolveFixture[SetIntProc]("pluginhost_vst3_v4b_set_metadata_fail")(value)
proc setupCalls(): uint32 =
  resolveFixture[CounterProc]("pluginhost_vst3_fixture_setup_calls")()
proc setupFrames(): uint32 =
  resolveFixture[CounterProc]("pluginhost_vst3_fixture_setup_frames")()
proc setupRate(): uint32 =
  resolveFixture[CounterProc]("pluginhost_vst3_fixture_setup_rate")()
proc mappingQueries(): uint32 =
  resolveFixture[CounterProc]("pluginhost_vst3_fixture_mapping_queries")()

proc openSlice(services: Vst3PluginServices): Result[Vst3AudioSlice] =
  var loaded = openVst3Module(fixturePath())
  if not loaded.isOk:
    return failure[Vst3AudioSlice](move(loaded.error))
  var library = move(loaded.value)
  var cid = parseVst3Uid(ClassId)
  if not cid.isOk:
    return failure[Vst3AudioSlice](move(cid.error))
  openVst3AudioSlice(services, library, cid.value,
    initJackBackendOpenConfig("vst3_v4b", noStartServer = true,
      libraryPath = fakeJackPath()))

proc newServices(): Vst3PluginServices =
  newVst3PluginServices(newVst3HostContext())

suite "private VST3 V4B native reconfiguration":
  test "startup and changed latency are published through JACK":
    setGenerate(0)
    setStructural(0)
    setLatency(113)
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    controls.invokeLatency(JackPlaybackLatency)
    check controls.portLatency(1, JackPlaybackLatency, 0) == 113'u32
    let before = controls.activateCount()
    setLatency(257)
    check trigger(Vst3RestartLatencyChanged) == uint32(Vst3ResultOk)
    let changed = slice.serviceReconfiguration()
    require changed.isOk
    check changed.value.latencySamples == 257'u32
    controls.invokeLatency(JackPlaybackLatency)
    check controls.portLatency(1, JackPlaybackLatency, 1) == 257'u32
    check controls.activateCount() == before
    check slice.close().isOk
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk

  test "values-only requests are acknowledged without replacing processing":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    let setups = setupCalls()
    let activations = controls.activateCount()
    check trigger(Vst3RestartParamValuesChanged) == uint32(Vst3ResultOk)
    let report = slice.serviceReconfiguration()
    require report.isOk
    check (report.value.appliedFlags and
      uint32(Vst3RestartParamValuesChanged)) != 0'u32
    check setupCalls() == setups
    check controls.activateCount() == activations
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk

  test "MIDI assignment and JACK rate/block changes rebuild one process":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    let before = setupCalls()
    let mappingsBefore = mappingQueries()
    check trigger(Vst3RestartMidiCCChanged) == uint32(Vst3ResultOk)
    let midi = slice.serviceReconfiguration()
    require midi.isOk
    check midi.value.midiMappingRebuilt
    check setupCalls() == before + 1'u32
    check mappingQueries() > mappingsBefore
    controls.invokeSampleRate(96_000)
    controls.invokeBufferSize(256)
    let runtime = slice.serviceReconfiguration()
    require runtime.isOk
    check runtime.value.jackConfigurationChanged
    check runtime.value.sampleRate == 96_000'u32
    check runtime.value.bufferSize == 256'u32
    check setupCalls() == before + 2'u32
    check setupRate() == 96_000'u32
    check setupFrames() == 256'u32
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk

  test "unchanged layout keeps connections while structural layout reports loss":
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
    check trigger(Vst3RestartIoChanged) == uint32(Vst3ResultOk)
    let unchanged = slice.serviceReconfiguration()
    require unchanged.isOk
    check unchanged.value.connectionsLost.len == 0
    check controls.connectCount() == connects
    check controls.invokeProcess(64) == 0
    setStructural(1)
    check trigger(Vst3RestartIoChanged) == uint32(Vst3ResultOk)
    let structural = slice.serviceReconfiguration()
    require structural.isOk
    check structural.value.connectionsLost.len > 0
    check controls.connectCount() == connects
    check controls.invokeProcess(64) == 0
    setStructural(0)
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk

  test "parameter metadata refresh commits atomically on query failure":
    setMetadataFail(0)
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    let before = slice.instance().parameterMetadata()
    let busesBefore = slice.instance().busMetadata()
    setMetadataFail(1)
    check trigger(Vst3RestartParamTitlesChanged) == uint32(Vst3ResultOk)
    let failed = slice.serviceReconfiguration()
    check not failed.isOk
    check slice.instance().parameterMetadata() == before
    check slice.instance().busMetadata() == busesBefore
    setMetadataFail(0)
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk

  test "unsupported restart fails silent and remains closeable":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    check trigger(Vst3RestartNoteExpressionChanged) == uint32(Vst3ResultOk)
    let rejected = slice.serviceReconfiguration()
    check not rejected.isOk
    check slice.state() == v3assQuiesced
    check not slice.jackBackend().processCallbacksEnabled()
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk

  test "lifecycle-generated requests preserve the bounded remainder":
    setGenerate(0)
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice(services)
    require opened.isOk
    var slice = move(opened.value)
    setGenerate(1)
    check trigger(Vst3RestartIoChanged) == uint32(Vst3ResultOk)
    let bounded = slice.serviceReconfiguration()
    check not bounded.isOk
    check bounded.error.message.contains("limit")
    check slice.state() == v3assQuiesced
    check not slice.jackBackend().processCallbacksEnabled()
    setGenerate(0)
    let remainder = slice.serviceReconfiguration()
    require remainder.isOk
    check remainder.value.lifecycleTurns == 1'u32
    check (remainder.value.requestedFlags and
      uint32(Vst3RestartIoChanged)) != 0'u32
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk
