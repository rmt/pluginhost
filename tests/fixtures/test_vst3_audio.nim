import std/[math, os, strutils, unittest]

import pluginhost/app/[vst3_audio_slice, vst3_plugin_services]
import pluginhost/domain/[port_plan, result]
import pluginhost/jack/backend
import pluginhost/platform/linux/dynlib
import pluginhost/vst3/[ffi, host_context, instance, module, uid]
import ./jack/fixture_api

const V2bClassId = "102132435465768798A9BACBDCEDFEFF"

type
  U32Proc = proc(): uint32 {.cdecl, gcsafe, raises: [].}
  U32IndexedProc = proc(index: uint32): uint32 {.
    cdecl, gcsafe, raises: [].}
  I32Proc = proc(): int32 {.cdecl, gcsafe, raises: [].}
  I64Proc = proc(): int64 {.cdecl, gcsafe, raises: [].}
  U64IndexedProc = proc(index: int32): uint64 {.cdecl, gcsafe, raises: [].}
  I32IndexedProc = proc(index: int32): int32 {.cdecl, gcsafe, raises: [].}
  EmitEditProc = proc(value: float64) {.cdecl, gcsafe, raises: [].}

proc fixtureDirectory(): string =
  result = getEnv("PLUGINHOST_VST3_V2B_FIXTURE_DIR")
  doAssert result.len > 0
proc fixturePath(name: string): string = fixtureDirectory() / (name & ".vst3")
proc fixtureBinary(name: string): string =
  fixturePath(name) / "Contents" / Vst3ArchitectureDir / (name & ".so")

proc resolveU32(library: DynamicLibrary; name: string): U32Proc =
  let resolved = resolveSymbol[U32Proc](library, name)
  doAssert resolved.isOk
  resolved.value
proc resolveU32Indexed(library: DynamicLibrary; name: string): U32IndexedProc =
  let resolved = resolveSymbol[U32IndexedProc](library, name)
  doAssert resolved.isOk
  resolved.value
proc resolveI32(library: DynamicLibrary; name: string): I32Proc =
  let resolved = resolveSymbol[I32Proc](library, name)
  doAssert resolved.isOk
  resolved.value
proc resolveI64(library: DynamicLibrary; name: string): I64Proc =
  let resolved = resolveSymbol[I64Proc](library, name)
  doAssert resolved.isOk
  resolved.value
proc resolveU64Indexed(library: DynamicLibrary; name: string): U64IndexedProc =
  let resolved = resolveSymbol[U64IndexedProc](library, name)
  doAssert resolved.isOk
  resolved.value
proc resolveI32Indexed(library: DynamicLibrary; name: string): I32IndexedProc =
  let resolved = resolveSymbol[I32IndexedProc](library, name)
  doAssert resolved.isOk
  resolved.value
proc resolveEdit(library: DynamicLibrary; name: string): EmitEditProc =
  let resolved = resolveSymbol[EmitEditProc](library, name)
  doAssert resolved.isOk
  resolved.value

proc openObserver(name: string): DynamicLibrary =
  var opened = openDynamicLibrary(fixtureBinary(name), keepLoaded = true)
  doAssert opened.isOk
  move(opened.value)
proc classId(): Vst3Tuid =
  let parsed = parseVst3Uid(V2bClassId)
  doAssert parsed.isOk
  parsed.value
proc openSlice(name: string; services: Vst3PluginServices): Result[Vst3AudioSlice] =
  var loaded = openVst3Module(fixturePath(name))
  if not loaded.isOk:
    return failure[Vst3AudioSlice](move(loaded.error))
  var module = move(loaded.value)
  let config = initJackBackendOpenConfig("vst3_v2b", noStartServer = true,
    libraryPath = jackFakeFixturePath())
  openVst3AudioSlice(services, module, classId(), config)
proc newServices(): Vst3PluginServices =
  newVst3PluginServices(newVst3HostContext())

proc closeSlice(slice: var Vst3AudioSlice; services: Vst3PluginServices;
               controls: var FakeJackControls) =
  check slice.close().isOk
  discard services.close()
  discard controls.close()

suite "VST3 V2B bounded JACK audio":
  test "mono and negotiated auxiliary buses process real samples without copies":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var observer = openObserver("mono")
    let inputPointer = resolveU64Indexed(observer,
      "pluginhost_vst3_fixture_last_input_pointer")
    let outputPointer = resolveU64Indexed(observer,
      "pluginhost_vst3_fixture_last_output_pointer")
    let eventAdds = resolveU32(observer, "pluginhost_vst3_fixture_event_adds")
    let requirementsCalls = resolveU32(observer,
      "pluginhost_vst3_fixture_requirements_calls")
    var opened = openSlice("mono", services)
    require opened.isOk
    var slice = move(opened.value)
    check requirementsCalls() == 1'u32
    check slice.portPlan.audioGroupCount == 2
    check slice.portPlan.audioChannelCount == 2
    check slice.portPlan.notePortCount == 2
    controls.setAudioSample(0, 0, 2.0)
    check controls.invokeProcess(128) == 0
    check eventAdds() == 1
    check abs(controls.audioSample(1, 0) - 2.0) < 0.0001
    check inputPointer(0) == controls.audioAddress(0)
    check outputPointer(0) == controls.audioAddress(1)
    check controls.audioAddress(0) != 0'u64
    check controls.audioAddress(1) != 0'u64
    check controls.audioAddress(0) != controls.audioAddress(1)
    check observer.close().isOk
    closeSlice(slice, services, controls)

    controlsResult = openFakeJackControls()
    require controlsResult.isOk
    controls = move(controlsResult.value)
    controls.reset()
    services = newServices()
    opened = openSlice("arrangements_false", services)
    require opened.isOk
    slice = move(opened.value)
    check slice.portPlan.audioGroupCount == 4
    check slice.portPlan.audioChannelCount == 6
    controls.setAudioSample(0, 0, 1.5)
    controls.setAudioSample(1, 0, 4.5)
    controls.setAudioSample(2, 0, 3.5)
    check controls.invokeProcess(128) == 0
    check abs(controls.audioSample(3, 0) - 1.5) < 0.0001
    check abs(controls.audioSample(4, 0) - 4.5) < 0.0001
    check abs(controls.audioSample(5, 0) - 3.5) < 0.0001
    closeSlice(slice, services, controls)

  test "combined component-controller fixture remains processable":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice("combined", services)
    require opened.isOk
    var slice = move(opened.value)
    controls.setAudioSample(0, 0, 3.0)
    check controls.invokeProcess(128) == 0
    check not slice.takeFault()
    check abs(controls.audioSample(3, 0) - 3.0) < 0.0001
    closeSlice(slice, services, controls)

  test "unimplemented processing notification still processes and closes":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var observer = openObserver("processing_notimpl")
    let processCalls = resolveU32(observer,
      "pluginhost_vst3_fixture_process_calls")
    var opened = openSlice("processing_notimpl", services)
    require opened.isOk
    var slice = move(opened.value)
    controls.setAudioSample(0, 0, 3.0)
    check controls.invokeProcess(128) == 0
    check not slice.takeFault()
    check abs(controls.audioSample(1, 0) - 3.0) < 0.0001
    check processCalls() == 1'u32
    closeSlice(slice, services, controls)
    check observer.close().isOk

  test "explicit processing rejection remains a startup failure":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    let opened = openSlice("processing_rejected", services)
    check not opened.isOk
    if not opened.isOk:
      check opened.error.context.contains("result=1")
    discard services.close()
    discard controls.close()

  test "process context requirements expose only the free-running clock":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var observer = openObserver("requirements_continuous")
    let requirementsCalls = resolveU32(observer,
      "pluginhost_vst3_fixture_requirements_calls")
    let contextState = resolveU32(observer,
      "pluginhost_vst3_fixture_last_context_state")
    let continuousSamples = resolveI64(observer,
      "pluginhost_vst3_fixture_last_continuous_time_samples")
    var opened = openSlice("requirements_continuous", services)
    require opened.isOk
    var slice = move(opened.value)
    check requirementsCalls() == 1'u32
    check controls.invokeProcess(128) == 0
    check contextState() == Vst3ProcessContextStateContinuousTimeValid
    check continuousSamples() == 0'i64
    closeSlice(slice, services, controls)

  test "all requested context fields leave unavailable values invalid":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var observer = openObserver("requirements_all")
    let requirementsCalls = resolveU32(observer,
      "pluginhost_vst3_fixture_requirements_calls")
    let contextState = resolveU32(observer,
      "pluginhost_vst3_fixture_last_context_state")
    let continuousSamples = resolveI64(observer,
      "pluginhost_vst3_fixture_last_continuous_time_samples")
    var opened = openSlice("requirements_all", services)
    require opened.isOk
    var slice = move(opened.value)
    check requirementsCalls() == 1'u32
    check controls.invokeProcess(128) == 0
    check contextState() == Vst3ProcessContextStateContinuousTimeValid
    check continuousSamples() == 0'i64
    check controls.invokeProcess(128) == 0
    check contextState() == Vst3ProcessContextStateContinuousTimeValid
    check continuousSamples() == 128'i64
    closeSlice(slice, services, controls)

  test "instrument and non-stereo native arrangements retain channel identity":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice("instrument", services)
    require opened.isOk
    var slice = move(opened.value)
    var observer = openObserver("instrument")
    let outputs = resolveI32(observer, "pluginhost_vst3_fixture_last_outputs")
    let outputChannels = resolveI32Indexed(observer,
      "pluginhost_vst3_fixture_last_output_channels")
    check slice.portPlan.audioChannelCount == 2
    check slice.portPlan.audioChannel(0).alias.endsWith(" L")
    check controls.invokeProcess(128) == 0
    check abs(controls.audioSample(0, 0) - 10.0) < 0.0001
    check abs(controls.audioSample(1, 0) - 20.0) < 0.0001
    check outputs() == 1
    check outputChannels(0) == 2
    check observer.close().isOk
    closeSlice(slice, services, controls)

    controlsResult = openFakeJackControls()
    require controlsResult.isOk
    controls = move(controlsResult.value)
    controls.reset()
    services = newServices()
    opened = openSlice("nonstereo", services)
    require opened.isOk
    slice = move(opened.value)
    controls.setAudioSample(0, 0, 1.0)
    controls.setAudioSample(1, 0, 2.0)
    controls.setAudioSample(2, 0, 3.0)
    check controls.invokeProcess(128) == 0
    check abs(controls.audioSample(3, 0) - 1.0) < 0.0001
    check abs(controls.audioSample(4, 0) - 2.0) < 0.0001
    check abs(controls.audioSample(5, 0) - 3.0) < 0.0001
    closeSlice(slice, services, controls)

  test "native inactive slots are still represented and point to stable storage":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var observer = openObserver("inactive")
    let channels = resolveI32Indexed(observer,
      "pluginhost_vst3_fixture_last_output_channels")
    let inputChannels = resolveI32Indexed(observer,
      "pluginhost_vst3_fixture_last_input_channels")
    let inputPointers = resolveU64Indexed(observer,
      "pluginhost_vst3_fixture_last_input_pointer")
    let pointers = resolveU64Indexed(observer,
      "pluginhost_vst3_fixture_last_output_pointer")
    var opened = openSlice("inactive", services)
    require opened.isOk
    var slice = move(opened.value)
    check slice.portPlan.audioGroupCount == 6
    check slice.portPlan.audioGroup(1).flags == {}
    check slice.portPlan.audioGroup(4).flags == {}
    check controls.invokeProcess(128) == 0
    check channels(0) == 1
    check channels(1) == 1
    check channels(2) == 1
    check inputChannels(0) == 1
    check inputChannels(1) == 1
    check inputChannels(2) == 1
    check pointers(0) != 0'u64
    check pointers(8) != 0'u64
    check pointers(16) != 0'u64
    check inputPointers(0) != 0'u64
    check inputPointers(8) != 0'u64
    check inputPointers(16) != 0'u64
    check observer.close().isOk
    closeSlice(slice, services, controls)

    for name in ["float64_only", "setup_fail", "activation_fail", "cv_bus",
                 "too_many_buses", "negative_buses"]:
      var controlsResult = openFakeJackControls()
      require controlsResult.isOk
      var controls = move(controlsResult.value)
      controls.reset()
      var services = newServices()
      let opened = openSlice(name, services)
      check not opened.isOk
      check instanceRootCount() == 0
      discard services.close()
      discard controls.close()

    var rollbackObserver = openObserver("activation_fail")
    let deactivationCalls = resolveU32(rollbackObserver,
      "pluginhost_vst3_fixture_deactivate_calls")
    var rollbackControlsResult = openFakeJackControls()
    require rollbackControlsResult.isOk
    var rollbackControls = move(rollbackControlsResult.value)
    rollbackControls.reset()
    var rollbackServices = newServices()
    let requirementsCalls = resolveU32(rollbackObserver,
      "pluginhost_vst3_fixture_requirements_calls")
    let rollbackOpened = openSlice("activation_fail", rollbackServices)
    check requirementsCalls() == 1'u32
    check not rollbackOpened.isOk
    check deactivationCalls() == 1'u32
    check rollbackObserver.close().isOk
    discard rollbackServices.close()
    discard rollbackControls.close()
    var arrangementControlsResult = openFakeJackControls()
    require arrangementControlsResult.isOk
    var arrangementControls = move(arrangementControlsResult.value)
    arrangementControls.reset()
    var arrangementServices = newServices()
    var arrangementObserver = openObserver("arrangements_false")
    let setupCalls = resolveU32(arrangementObserver,
      "pluginhost_vst3_fixture_setup_calls")
    let setupFrames = resolveU32(arrangementObserver,
      "pluginhost_vst3_fixture_setup_frames")
    let setupRate = resolveU32(arrangementObserver,
      "pluginhost_vst3_fixture_setup_rate")
    let orderCount = resolveU32(arrangementObserver,
      "pluginhost_vst3_fixture_order_count")
    let orderAt = resolveU32Indexed(arrangementObserver,
      "pluginhost_vst3_fixture_order")
    let arrangementCalls = resolveU32(arrangementObserver,
      "pluginhost_vst3_fixture_arrangement_calls")
    let samplePosition = resolveI64(arrangementObserver,
      "pluginhost_vst3_fixture_last_sample_position")
    var arrangementOpened = openSlice("arrangements_false", arrangementServices)
    require arrangementOpened.isOk
    var arrangementSlice = move(arrangementOpened.value)
    check setupCalls() == 1
    var setupIndex = -1
    var arrangementIndex = -1
    var activateIndex = -1
    var activeIndex = -1
    var processingIndex = -1
    for index in 0'u32 ..< orderCount():
      case orderAt(index)
      of 4: arrangementIndex = int(index)
      of 5: setupIndex = int(index)
      of 2: activateIndex = int(index)
      of 3: activeIndex = int(index)
      of 6: processingIndex = int(index)
      else: discard
    check setupIndex >= 0
    check activateIndex > setupIndex
    check activeIndex > activateIndex
    check arrangementIndex >= 0
    check arrangementControls.invokeProcess(128) == 0
    check samplePosition() == 0'i64
    check arrangementControls.invokeProcess(128) == 0
    check samplePosition() == 128'i64
    check arrangementObserver.close().isOk
    closeSlice(arrangementSlice, arrangementServices, arrangementControls)

  test "controller edits arrive at the next block and processor output reaches main thread":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var observer = openObserver("output_parameter")
    let emitEdit = resolveEdit(observer,
      "pluginhost_vst3_fixture_emit_gain_edit")
    let outputSetCalls = resolveU32(observer,
      "pluginhost_vst3_fixture_controller_set_calls")
    var opened = openSlice("output_parameter", services)
    require opened.isOk
    var slice = move(opened.value)
    controls.setAudioSample(0, 0, 4.0)
    emitEdit(0.25)
    check controls.invokeProcess(128) == 0
    check not slice.takeFault()
    check abs(controls.audioSample(3, 0) - 1.0) < 0.0001
    check slice.drainParameterObservations() == 1'u32
    check outputSetCalls() == 1
    check observer.close().isOk
    closeSlice(slice, services, controls)

  test "process failures and oversized frames silence output and latch fault":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var opened = openSlice("process_fail", services)
    require opened.isOk
    var slice = move(opened.value)
    controls.setAudioSample(0, 0, 9.0)
    check controls.invokeProcess(128) != 0
    check controls.audioSample(1, 0) == 0.0
    check slice.takeFault()
    closeSlice(slice, services, controls)

    controlsResult = openFakeJackControls()
    require controlsResult.isOk
    controls = move(controlsResult.value)
    controls.reset()
    var monoObserver = openObserver("mono")
    let monoProcessCalls = resolveU32(monoObserver,
      "pluginhost_vst3_fixture_process_calls")
    services = newServices()
    opened = openSlice("mono", services)
    require opened.isOk
    slice = move(opened.value)
    controls.setAudioSample(1, 0, 7.0)
    let errorsBefore = slice.jackBackend.notifications().processErrors
    let callsBefore = monoProcessCalls()
    check controls.invokeProcess(129) != 0
    check slice.jackBackend.notifications().processErrors ==
      errorsBefore + 1'u64
    check monoProcessCalls() == callsBefore
    check controls.audioSample(1, 0) == 0.0
    closeSlice(slice, services, controls)
    check monoObserver.close().isOk
    controlsResult = openFakeJackControls()
    require controlsResult.isOk
    controls = move(controlsResult.value)
    controls.reset()
    services = newServices()
    opened = openSlice("silence_output", services)
    require opened.isOk
    slice = move(opened.value)
    controls.setAudioSample(0, 0, 7.0)
    check controls.invokeProcess(128) == 0
    check controls.audioSample(1, 0) == 0.0
    check controls.invokeProcess(128) == 0
    check controls.audioSample(1, 0) == 7.0
    closeSlice(slice, services, controls)

  test "quiescent teardown disables callbacks before releasing process storage":
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    var services = newServices()
    var observer = openObserver("mono")
    let overlap = resolveU32(observer, "pluginhost_vst3_fixture_process_overlap")
    var opened = openSlice("mono", services)
    require opened.isOk
    var slice = move(opened.value)
    check controls.beginBlockedProcess(4) == 0
    check slice.state == v3assActive
    check slice.close().isOk
    check overlap() == 0'u32
    check controls.callbacksCleared() == 1
    discard services.close()
    check observer.close().isOk
    discard controls.close()
