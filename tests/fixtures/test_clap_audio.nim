import std/[strutils, unittest]

import pluginhost/app/audio_slice
import pluginhost/app/host_session
import pluginhost/clap/ffi
import pluginhost/clap/[audio_process, host_bridge, instance, loader]
import pluginhost/domain/[errors, lifecycle, plugin_catalog, port_plan, result]
import pluginhost/jack/backend
import pluginhost/rt/role_guard
import pluginhost/platform/linux/dynlib
import ./jack/fixture_api
import ./clap/audio_fixture_api

proc fakeConfig(name = "audio-fixture"): JackBackendOpenConfig =
  initJackBackendOpenConfig(
    name,
    noStartServer = true,
    libraryPath = jackFakeFixturePath(),
  )

proc capacityPlan(inputGroups, outputGroups, channelsPerGroup: uint32):
    PortPlan =
  var groups: seq[AudioGroup]
  var channels: seq[AudioChannelPlan]
  for direction in [pdInput, pdOutput]:
    let groupCount = if direction == pdInput: inputGroups else: outputGroups
    var flattened = 0'u32
    for groupIndex in 0'u32 ..< groupCount:
      groups.add(AudioGroup(
        index: groupIndex,
        id: groupIndex + 1'u32,
        direction: direction,
        channelCount: channelsPerGroup,
        flattenedFirst: flattened,
        flattenedPast: flattened + channelsPerGroup,
      ))
      for channelIndex in 0'u32 ..< channelsPerGroup:
        channels.add(AudioChannelPlan(
          groupIndex: groupIndex,
          groupId: groupIndex + 1'u32,
          channelIndex: channelIndex,
          flattenedIndex: flattened + channelIndex,
          direction: direction,
        ))
      flattened += channelsPerGroup
  newPortPlan(portPlanVersion(1), move(groups), move(channels), @[])

proc openOwnedSlice(variant: string):
    tuple[slice: InternalAudioSlice, fixture: AudioFixtureApi,
          observer: DynamicLibrary] =
  let path = audioFixturePath(variant)
  var observerResult = openDynamicLibrary(path)
  require observerResult.isOk
  var observer = move(observerResult.value)
  let fixture = audioFixtureApi(observer)
  fixture.reset()
  var moduleResult = openClapModule(path)
  require moduleResult.isOk
  var module = move(moduleResult.value)
  let catalog = module.readCatalog()
  require catalog.isOk
  var selected = catalog.value.selectDescriptor(PluginSelector(
    kind: pskImplicitSingle))
  require selected.isOk
  var sliceResult = openInternalAudioSlice(move(module), move(selected.value),
                                           fakeConfig())
  require sliceResult.isOk

  (move(sliceResult.value), fixture, move(observer))

proc openInstance(variant: string):
    tuple[instance: ClapInstance, fixture: AudioFixtureApi,
          observer: DynamicLibrary] =
  let path = audioFixturePath(variant)
  var observerResult = openDynamicLibrary(path)
  require observerResult.isOk
  var observer = move(observerResult.value)
  let fixture = audioFixtureApi(observer)
  fixture.reset()

  var moduleResult = openClapModule(path)
  require moduleResult.isOk
  var module = move(moduleResult.value)
  let catalog = module.readCatalog()
  require catalog.isOk
  var selected = catalog.value.selectDescriptor(PluginSelector(
    kind: pskImplicitSingle))
  require selected.isOk
  var created = createClapInstance(move(module), move(selected.value))
  require created.isOk
  (move(created.value), fixture, move(observer))

proc closeAudio(instance: var ClapInstance; process: var ClapAudioProcess;
                backend: var JackBackend) =
  let role = backend.audioRoleGuard()
  if backend.state == jbsActive:
    discard backend.deactivate()
  discard instance.stopProcessing(role)
  if instance.state == cisActivated:
    discard instance.deactivate()
  if role != nil:
    discard instance.hostBridge.detachAudioRole(role)
  discard process.close()
  discard instance.close()
  discard backend.close()

proc startAudio(variant: string; controls: var FakeJackControls;
                instance: var ClapInstance; process: var ClapAudioProcess;
                backend: var JackBackend): bool =
  let inspected = instance.inspectPortPlan()
  if not inspected.isOk:
    return false
  let plan = inspected.value
  var processResult = instance.newAudioProcess(
    plan, backend.bufferSize, backend.audioRoleGuard())
  if not processResult.isOk:
    return false
  process = move(processResult.value)
  if not backend.configure(plan, process.endpoint).isOk:
    return false
  if not instance.activate(backend.sampleRate.float64, 1'u32,
                           backend.bufferSize).isOk:
    return false
  if not instance.startProcessing(backend.audioRoleGuard()).isOk:
    return false
  if not backend.activate().isOk:
    return false
  discard variant
  discard controls
  true

proc openControls(): FakeJackControls =
  var opened = openFakeJackControls()
  require opened.isOk
  result = move(opened.value)
  result.reset()

proc openBackend(): JackBackend =
  var opened = openJackBackend(fakeConfig())
  require opened.isOk
  result = move(opened.value)

suite "internal CLAP float32 audio endpoint":
  test "construction failure closes every acquired owner":
    var controls = openControls()
    let path = audioFixturePath("audio_tone")
    var observerResult = openDynamicLibrary(path)
    require observerResult.isOk
    var observer = move(observerResult.value)
    let fixture = audioFixtureApi(observer)
    fixture.reset()
    defer:
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    var moduleResult = openClapModule(path)
    require moduleResult.isOk
    var module = move(moduleResult.value)
    var catalog = module.readCatalog()
    require catalog.isOk
    var selected = catalog.value.selectDescriptor(PluginSelector(
      kind: pskImplicitSingle))
    require selected.isOk
    controls.setPortFailure(0)
    var opened = openInternalAudioSlice(
      move(module), move(selected.value), fakeConfig("construction-failure"))
    check not opened.isOk
    check opened.error.kind == hekJackPortRegistration
    check fixture.destroyCalls() == 1
    check controls.currentPortCount() == 0
    check controls.closeCount() == 1

  test "composition owner orders JACK and CLAP lifecycle and closes safely":
    var controls = openControls()
    var opened = openOwnedSlice("audio_tone")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    var session = initHostSession()
    defer:
      doAssert session.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk
    check session.attachInternalAudioSlice(slice).isOk
    check slice.state == iassEmpty
    check session.state == ssNew
    check session.startInternalAudio().isOk
    check session.state == ssRunning
    check controls.invokeProcess(4) == 0
    check fixture.activateCalls() == 1
    check fixture.startCalls() == 1
    check fixture.processCalls() == 1
    check session.stopInternalAudio().isOk
    check session.state == ssStopped
    check fixture.stopCalls() == 1
    check fixture.deactivateCalls() == 1
    check session.close().isOk
    check fixture.destroyCalls() == 1
    check controls.forceProcess(4) == -101
    check fixture.lifecycleCount() == 6
    check fixture.lifecycleAt(0) == 1
    check fixture.lifecycleAt(1) == 2
    check fixture.lifecycleAt(2) == 3
    check fixture.lifecycleAt(3) == 4
    check fixture.lifecycleAt(4) == 5
    check fixture.lifecycleAt(5) == 6

  test "rejected session attachment retains caller ownership":
    var controls = openControls()
    var opened = openOwnedSlice("audio_tone")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    var session = initHostSession()
    session.state = ssStopped
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk
    var attached = session.attachInternalAudioSlice(slice)
    check not attached.isOk
    check attached.error.kind == hekInvalidTransition
    check slice.state == iassReady
    check fixture.destroyCalls() == 0

  test "JACK activation failure rolls back CLAP processing before close":
    var controls = openControls()
    var opened = openOwnedSlice("audio_tone")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    var session = initHostSession()
    defer:
      doAssert session.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk
    require session.attachInternalAudioSlice(slice).isOk
    controls.setActivateStatus(41)
    var started = session.startInternalAudio()
    check not started.isOk
    check started.error.kind == hekJackActivation
    check session.state == ssFailed
    check fixture.activateCalls() == 1
    check fixture.startCalls() == 1
    check fixture.stopCalls() == 1
    check fixture.deactivateCalls() == 1
    check session.close().isOk
    check fixture.destroyCalls() == 1


  test "runtime audio changes silence and reactivate at the new limits":
    var controls = openControls()
    var opened = openOwnedSlice("audio_tone")
    var slice = move(opened.slice)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    defer:
      doAssert slice.close().isOk
      doAssert observer.close().isOk
      doAssert controls.close().isOk
    require slice.start().isOk
    check fixture.lastActivateSampleRate() == 48_000.0
    check fixture.lastActivateMinFrames() == 1
    check fixture.lastActivateMaxFrames() == 128
    check controls.invokeProcess(4) == 0
    check fixture.processCalls() == 1
    controls.invokeBufferSize(256)
    controls.invokeSampleRate(96_000)
    check slice.jackBackend().configurationChangePending
    check controls.invokeProcess(4) == 0
    check fixture.processCalls() == 1
    check slice.jackBackend().notifications().lateProcessCalls == 1
    check controls.audioSample(0, 0) == 0.0
    check slice.refreshRuntimeConfiguration().isOk
    check slice.state == iassActive
    check not slice.jackBackend().configurationChangePending
    check slice.jackBackend().bufferSize == 256
    check slice.jackBackend().sampleRate == 96_000
    check fixture.activateCalls() == 2
    check fixture.startCalls() == 2
    check fixture.lastActivateSampleRate() == 96_000.0
    check fixture.lastActivateMinFrames() == 1
    check fixture.lastActivateMaxFrames() == 256
    check controls.invokeProcess(256) == 0
    check fixture.processCalls() == 2
    check controls.audioSample(0, 255) == 1_255.0
    check controls.audioSample(1, 255) == 2_255.0
    check fixture.contractFailures() == 0

  test "tone output preserves groups, timing, null transport, and zero-copy buffers":
    var controls = openControls()
    var opened = openInstance("audio_tone")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    var backend = openBackend()
    var process: ClapAudioProcess
    require startAudio("audio_tone", controls, instance, process, backend)
    defer:
      closeAudio(instance, process, backend)
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    check backend.realizedPortCount == 2
    check controls.invokeProcess(8) == 0
    check controls.audioSample(0, 0) == 1_000.0
    check controls.audioSample(0, 7) == 1_007.0
    check controls.audioSample(1, 0) == 2_000.0
    check controls.audioSample(1, 7) == 2_007.0
    check fixture.processCalls() == 1
    check process.takeEventMetrics().droppedOutput == 1
    check (instance.takeRequests() and ClapRequestProcess) != 0
    var logRecord: ClapHostLogRecord
    check instance.tryPopLog(logRecord)
    check logRecord.logMessage() == "fixture process"
    check fixture.lastSteadyTime() == 0
    check fixture.lastFrames() == 8
    check fixture.lastInputGroups() == 0
    check fixture.lastOutputGroups() == 1
    check fixture.transportWasNull() == 1
    check fixture.data64WasNull() == 1
    check fixture.outputAddress(0) == controls.audioAddress(0)
    check fixture.outputAddress(1) == controls.audioAddress(1)
    check fixture.contractFailures() == 0

    var foreignResult: cint
    check controls.invokeProcessOnThread(4, 0, addr foreignResult) == 0
    check foreignResult == 0
    check fixture.processCalls() == 2
    check fixture.lastSteadyTime() == 8
    check process.takeEventMetrics().droppedOutput == 1

    check controls.forceProcess(129) != 0
    check controls.audioSample(0, 0) == 0.0
    check controls.audioSample(1, 128) == 0.0
    check fixture.processCalls() == 2
    check backend.notifications().processErrors == 1

    check controls.invokeProcess(4) == 0
    check fixture.processCalls() == 2
    check fixture.lastSteadyTime() == 8
    check fixture.lastFrames() == 4

    check backend.deactivate().isOk
    check instance.stopProcessing(backend.audioRoleGuard()).isOk
    check instance.deactivate().isOk
    check fixture.stopCalls() == 1
    check fixture.deactivateCalls() == 1
    check controls.forceProcess(4) == 0
    check fixture.processCalls() == 2

  test "gain effect maps flattened JACK channels into one CLAP group":
    var controls = openControls()
    var opened = openInstance("audio_gain")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    var backend = openBackend()
    var process: ClapAudioProcess
    require startAudio("audio_gain", controls, instance, process, backend)
    defer:
      closeAudio(instance, process, backend)
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    for frame in 0'u32 ..< 8'u32:
      controls.setAudioSample(0, frame, cfloat(frame + 1'u32))
      controls.setAudioSample(1, frame, cfloat(100'u32 + frame))
    check controls.invokeProcess(8) == 0
    for frame in 0'u32 ..< 8'u32:
      check controls.audioSample(2, frame) == cfloat((frame + 1'u32) * 2'u32)
      check controls.audioSample(3, frame) == cfloat((100'u32 + frame) * 2'u32)
    check fixture.lastInputGroups() == 1
    check fixture.lastOutputGroups() == 1
    check fixture.inputAddress(0) == controls.audioAddress(0)
    check fixture.inputAddress(1) == controls.audioAddress(1)
    check fixture.outputAddress(0) == controls.audioAddress(2)
    check fixture.outputAddress(1) == controls.audioAddress(3)
    check fixture.contractFailures() == 0

  test "multiple CLAP groups retain flattened channel order":
    var controls = openControls()
    var opened = openInstance("audio_multi")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    var backend = openBackend()
    var process: ClapAudioProcess
    require startAudio("audio_multi", controls, instance, process, backend)
    defer:
      closeAudio(instance, process, backend)
      doAssert observer.close().isOk
      doAssert controls.close().isOk

    for frame in 0'u32 ..< 4'u32:
      controls.setAudioSample(0, frame, cfloat(frame + 1'u32))
      controls.setAudioSample(1, frame, cfloat(frame + 11'u32))
      controls.setAudioSample(2, frame, cfloat(frame + 21'u32))
    check controls.invokeProcess(4) == 0
    for frame in 0'u32 ..< 4'u32:
      check controls.audioSample(3, frame) == cfloat((frame + 1'u32) * 2'u32)
      check controls.audioSample(4, frame) == cfloat((frame + 11'u32) * 2'u32)
      check controls.audioSample(5, frame) == cfloat((frame + 21'u32) * 3'u32)
    check fixture.lastInputGroups() == 2
    check fixture.lastOutputGroups() == 2
    check fixture.inputAddress(0) == controls.audioAddress(0)
    check fixture.inputAddress(1) == controls.audioAddress(1)
    check fixture.inputAddress(2) == controls.audioAddress(2)
    check fixture.outputAddress(0) == controls.audioAddress(3)
    check fixture.outputAddress(1) == controls.audioAddress(4)
    check fixture.outputAddress(2) == controls.audioAddress(5)
    check fixture.contractFailures() == 0

  test "process statuses are bounded and errors produce silence":
    for scenario in [
      (variant: "audio_process_sleep", status: ClapProcessSleep),
      (variant: "audio_process_tail", status: ClapProcessTail),
      (variant: "audio_process_continue_if_not_quiet", status: ClapProcessContinueIfNotQuiet),
    ]:
      let variant = scenario.variant
      let expectedStatus = scenario.status
      var controls = openControls()
      var opened = openInstance(variant)
      var instance = move(opened.instance)
      var observer = move(opened.observer)
      let fixture = opened.fixture
      var backend = openBackend()
      var process: ClapAudioProcess
      require startAudio(variant, controls, instance, process, backend)
      check controls.invokeProcess(4) == 0
      check fixture.lastStatus() == expectedStatus
      check backend.notifications().processErrors == 0
      closeAudio(instance, process, backend)
      check observer.close().isOk
      check controls.close().isOk

    var controls = openControls()
    var opened = openInstance("audio_process_error")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let fixture = opened.fixture
    var backend = openBackend()
    var process: ClapAudioProcess
    require startAudio("audio_process_error", controls, instance, process, backend)
    for frame in 0'u32 ..< 4'u32:
      controls.setAudioSample(0, frame, 9.0)
      controls.setAudioSample(1, frame, 9.0)
    check controls.invokeProcess(4) != 0
    for frame in 0'u32 ..< 4'u32:
      check controls.audioSample(2, frame) == 0.0
      check controls.audioSample(3, frame) == 0.0
    check fixture.lastStatus() == ClapProcessError
    check backend.notifications().processErrors == 1
    check controls.invokeProcess(4) == 0
    check fixture.processCalls() == 1
    check backend.notifications().lateProcessCalls == 1
    closeAudio(instance, process, backend)
    check observer.close().isOk
    check controls.close().isOk

  test "activation and start failures leave explicit states for rollback":
    for variant in ["audio_activate_fail", "audio_start_fail"]:
      var controls = openControls()
      var opened = openInstance(variant)
      var instance = move(opened.instance)
      var observer = move(opened.observer)
      let fixture = opened.fixture
      var backend = openBackend()
      let inspected = instance.inspectPortPlan()
      require inspected.isOk
      var processResult = instance.newAudioProcess(
        inspected.value, backend.bufferSize, backend.audioRoleGuard())
      require processResult.isOk
      var process = move(processResult.value)
      require backend.configure(inspected.value, process.endpoint).isOk
      var activated = instance.activate(backend.sampleRate.float64, 1, 128)
      if variant == "audio_activate_fail":
        check not activated.isOk
        check activated.error.kind == hekClapActivation
        check instance.state == cisInitialized
      else:
        require activated.isOk
        var started = instance.startProcessing(backend.audioRoleGuard())
        check not started.isOk
        check started.error.kind == hekClapStartProcessing
        check instance.state == cisActivated
      closeAudio(instance, process, backend)
      check fixture.destroyCalls() == 1
      check observer.close().isOk
      check controls.close().isOk

  test "audio capacities apply independently by direction and recover":
    var opened = openInstance("audio_tone")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    var role: AudioRoleGuard
    role.initAudioRoleGuard()
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk

    let exactPlan = capacityPlan(
      uint32(ClapAudioProcessMaxGroupsPerDirection),
      uint32(ClapAudioProcessMaxGroupsPerDirection),
      uint32(ClapAudioProcessMaxChannelsPerDirection div
        ClapAudioProcessMaxGroupsPerDirection),
    )
    var exact = instance.newAudioProcess(exactPlan, 128, addr role)
    require exact.isOk
    var exactProcess = move(exact.value)
    check exactProcess.close().isOk

    for counts in [
      (inputs: uint32(ClapAudioProcessMaxGroupsPerDirection + 1),
       outputs: 0'u32),
      (inputs: 0'u32,
       outputs: uint32(ClapAudioProcessMaxGroupsPerDirection + 1)),
    ]:
      let tooManyGroups = capacityPlan(
        counts.inputs, counts.outputs, 1'u32)
      var rejectedGroups = instance.newAudioProcess(
        tooManyGroups, 128, addr role)
      check not rejectedGroups.isOk
      check rejectedGroups.error.kind == hekClapProcess
      check rejectedGroups.error.message.contains("group count")

    for counts in [
      (inputs: 1'u32, outputs: 0'u32),
      (inputs: 0'u32, outputs: 1'u32),
    ]:
      let tooManyChannels = capacityPlan(
        counts.inputs, counts.outputs,
        uint32(ClapAudioProcessMaxChannelsPerDirection + 1))
      var rejectedChannels = instance.newAudioProcess(
        tooManyChannels, 128, addr role)
      check not rejectedChannels.isOk
      check rejectedChannels.error.kind == hekClapProcess
      check rejectedChannels.error.message.contains("channel capacity")

    var recovered = instance.newAudioProcess(
      capacityPlan(1'u32, 1'u32, 1'u32), 128, addr role)
    require recovered.isOk
    var recoveredProcess = move(recovered.value)
    check recoveredProcess.close().isOk

  test "audio endpoint accepts supported note ports in the event increment":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    var opened = openInstance("audio_tone")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk
    var role: AudioRoleGuard
    role.initAudioRoleGuard()
    let plan = newPortPlan(portPlanVersion(1), @[], @[], @[
      NotePortPlan(index: 0, direction: pdInput, shortName: "midi_in_1",
        supportedDialects: {ndMidi}, preferredDialect: ndMidi)])
    var process = instance.newAudioProcess(plan, 128, addr role)
    require process.isOk
    var owner = move(process.value)
    check owner.close().isOk
