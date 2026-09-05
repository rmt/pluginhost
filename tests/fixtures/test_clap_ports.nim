import std/[options, strutils, unittest]

import pluginhost/clap/[ffi, instance, loader]
import pluginhost/domain/[errors, plugin_catalog, port_plan]
import pluginhost/platform/linux/dynlib
import ./clap/[fixture_api, port_fixture_api]

type
  OpenPortInstance = tuple[
    instance: ClapInstance,
    api: PortFixtureApi,
    observer: DynamicLibrary,
  ]

  PortThreadAttempt = object
    instance: ptr ClapInstance
    inspectSucceeded: bool
    inspectError: HostErrorKind
    renderSucceeded: bool
    renderError: HostErrorKind

proc openPortInstance(variant: string): OpenPortInstance =
  let path = clapFixturePath(variant)
  var observerResult = openDynamicLibrary(path)
  require observerResult.isOk
  var observer = move(observerResult.value)
  let api = portFixtureApi(observer)
  api.reset()

  var moduleResult = openClapModule(path)
  require moduleResult.isOk
  var module = move(moduleResult.value)
  let catalog = module.readCatalog()
  require catalog.isOk
  var selected = catalog.value.selectDescriptor(PluginSelector(
    kind: pskImplicitSingle,
  ))
  require selected.isOk

  var created = createClapInstance(move(module), move(selected.value))
  require created.isOk
  (move(created.value), api, move(observer))

proc inspectAndRenderOnThread(attempt: ptr PortThreadAttempt) {.thread.} =
  let inspected = attempt.instance[].inspectPortPlan()
  attempt.inspectSucceeded = inspected.isOk
  if not inspected.isOk:
    attempt.inspectError = inspected.error.kind

  let rendered = attempt.instance[].negotiateRealtimeRender()
  attempt.renderSucceeded = rendered.isOk
  if not rendered.isOk:
    attempt.renderError = rendered.error.kind

suite "CLAP deactivated port inspection and render negotiation":
  test "valid metadata becomes a versioned host-owned immutable plan":
    var opened = openPortInstance("ports_valid")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let api = opened.api
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk

    check instance.pluginExtensions.audioPorts != nil
    check instance.pluginExtensions.notePorts != nil
    check instance.pluginExtensions.render != nil

    var inspected = instance.inspectPortPlan()
    require inspected.isOk
    var plan = move(inspected.value)
    check plan.version.value == 1'u64
    check plan.audioGroupCount == 4
    check plan.audioChannelCount == 8
    check plan.notePortCount == 3

    let mainInput = plan.audioGroup(0)
    check mainInput.index == 0'u32
    check mainInput.id == 10'u32
    check mainInput.direction == pdInput
    check mainInput.name == "Main Input"
    check mainInput.flags == {
      apfMain, apfSupports64Bits, apfRequiresCommonSampleSize}
    check mainInput.unknownFlags == 0'u32
    check mainInput.channelCount == 2'u32
    check mainInput.portType == "stereo"
    check mainInput.inPlacePair == some(20'u32)
    check mainInput.flattenedFirst == 0'u32
    check mainInput.flattenedPast == 2'u32

    let sidechain = plan.audioGroup(1)
    check sidechain.id == 11'u32
    check sidechain.unknownFlags == (1'u32 shl 31)
    check sidechain.flattenedFirst == 2'u32
    check sidechain.flattenedPast == 3'u32
    check sidechain.inPlacePair.isNone

    let mainOutput = plan.audioGroup(2)
    check mainOutput.direction == pdOutput
    check mainOutput.id == 20'u32
    check mainOutput.flags == {
      apfMain, apfSupports64Bits, apfPrefers64Bits,
      apfRequiresCommonSampleSize}
    check mainOutput.inPlacePair == some(10'u32)
    check mainOutput.flattenedFirst == 0'u32
    check mainOutput.flattenedPast == 2'u32

    let wetOutput = plan.audioGroup(3)
    check wetOutput.name == "Wet\xEF\xBF\xBD Out"
    check wetOutput.portType == "org.pluginhost.fixture.triplet"
    check wetOutput.flattenedFirst == 2'u32
    check wetOutput.flattenedPast == 5'u32

    check plan.audioChannel(0).shortName == "audio_in_1"
    check plan.audioChannel(0).alias == "Main Input 1"
    check plan.audioChannel(2).shortName == "audio_in_3"
    check plan.audioChannel(2).alias == "Sidechain"
    check plan.audioChannel(3).direction == pdOutput
    check plan.audioChannel(3).flattenedIndex == 0'u32
    check plan.audioChannel(3).shortName == "audio_out_1"
    check plan.audioChannel(7).shortName == "audio_out_5"
    check plan.audioChannel(7).alias == "Wet\xEF\xBF\xBD Out 3"

    let notesIn = plan.notePort(0)
    check notesIn.id == 30'u32
    check notesIn.direction == pdInput
    check notesIn.supportedDialects == {ndClap, ndMidi}
    check notesIn.preferredDialect == ndMidi
    check notesIn.shortName == "midi_in_1"
    check plan.notePort(1).supportedDialects == {ndMidi, ndMidiMpe}
    check plan.notePort(1).preferredDialect == ndMidiMpe
    check plan.notePort(1).shortName == "midi_in_2"
    check plan.notePort(2).id == 30'u32
    check plan.notePort(2).direction == pdOutput
    check plan.notePort(2).shortName == "midi_out_1"

    let rendered = instance.negotiateRealtimeRender()
    require rendered.isOk
    check rendered.value.extensionPresent
    check not rendered.value.hardRealtimeRequired
    check rendered.value.realtimeModeApplied
    check api.renderRequirementCalls() == 1'u32
    check api.renderSetCalls() == 1'u32
    check api.lastRenderMode() == ClapRenderRealtime

    let rescanned = instance.inspectPortPlan()
    require rescanned.isOk
    check rescanned.value.version.value == 2'u64
    check api.audioCountCalls() == 4'u32
    check api.audioGetCalls() == 8'u32
    check api.noteCountCalls() == 4'u32
    check api.noteGetCalls() == 6'u32
    check api.contractFailures() == 0'u32

    check instance.close().isOk
    check api.destroyCalls() == 1'u32
    check api.deinitCalls() == 1'u32
    check observer.close().isOk

    check plan.audioGroup(0).name == "Main Input"
    check plan.audioGroup(3).portType == "org.pluginhost.fixture.triplet"
    check plan.notePort(2).name == "Notes Out"

    let afterClose = instance.inspectPortPlan()
    check not afterClose.isOk
    check afterClose.error.kind == hekClapPorts
    let renderAfterClose = instance.negotiateRealtimeRender()
    check not renderAfterClose.isOk
    check renderAfterClose.error.kind == hekClapRender

  test "dangling in-place pairs are normalized for separate host buffers":
    type Scenario = tuple[
      variant: string,
      groupCount: int,
      groupIndex: int,
      direction: PortDirection,
      id: uint32,
    ]
    let scenarios: array[2, Scenario] = [
      ("audio_bad_pair", 4, 0, pdInput, 10'u32),
      ("audio_dangling_zero_pair", 1, 0, pdOutput, 0'u32),
    ]

    for scenario in scenarios:
      block:
        var opened = openPortInstance(scenario.variant)
        var instance = move(opened.instance)
        var observer = move(opened.observer)
        let api = opened.api
        defer:
          doAssert instance.close().isOk
          doAssert observer.close().isOk

        let inspected = instance.inspectPortPlan()
        require inspected.isOk
        let plan = inspected.value
        check plan.audioGroupCount == scenario.groupCount
        let group = plan.audioGroup(scenario.groupIndex)
        check group.direction == scenario.direction
        check group.id == scenario.id
        check group.inPlacePair.isNone
        if scenario.variant == "audio_bad_pair":
          check plan.audioGroup(2).inPlacePair == some(10'u32)
        check api.contractFailures() == 0'u32

  test "exact group channel string and dialect bounds are accepted":
    var opened = openPortInstance("ports_exact_limits")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let api = opened.api
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk

    let inspected = instance.inspectPortPlan()
    require inspected.isOk
    let plan = inspected.value
    check plan.audioGroupCount == 2_048
    check plan.audioChannelCount == 8_192
    check plan.notePortCount == 2_048

    let lastInput = plan.audioGroup(1_023)
    check lastInput.direction == pdInput
    check lastInput.index == 1_023'u32
    check lastInput.name == "Input 1023"
    check lastInput.portType.len == 4_095
    check lastInput.flattenedFirst == 4_092'u32
    check lastInput.flattenedPast == 4_096'u32
    check plan.audioGroup(1_024).direction == pdOutput
    check plan.audioGroup(1_024).flattenedFirst == 0'u32
    check plan.audioChannel(4_095).shortName == "audio_in_4096"
    check plan.audioChannel(4_096).shortName == "audio_out_1"
    check plan.notePort(1_023).shortName == "midi_in_1024"
    check plan.notePort(1_024).shortName == "midi_out_1"
    check api.audioCountCalls() == 2'u32
    check api.audioGetCalls() == 2_048'u32
    check api.noteCountCalls() == 2'u32
    check api.noteGetCalls() == 2_048'u32
    check api.contractFailures() == 0'u32

  test "missing optional extensions produce empty ports and no render request":
    var opened = openPortInstance("ports_none")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let api = opened.api
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk

    check instance.pluginExtensions.audioPorts == nil
    check instance.pluginExtensions.notePorts == nil
    check instance.pluginExtensions.render == nil
    let inspected = instance.inspectPortPlan()
    require inspected.isOk
    check inspected.value.audioGroupCount == 0
    check inspected.value.audioChannelCount == 0
    check inspected.value.notePortCount == 0

    let rendered = instance.negotiateRealtimeRender()
    require rendered.isOk
    check not rendered.value.extensionPresent
    check not rendered.value.hardRealtimeRequired
    check not rendered.value.realtimeModeApplied
    check api.audioCountCalls() == 0'u32
    check api.audioGetCalls() == 0'u32
    check api.noteCountCalls() == 0'u32
    check api.noteGetCalls() == 0'u32
    check api.renderRequirementCalls() == 0'u32
    check api.renderSetCalls() == 0'u32
    check api.contractFailures() == 0'u32

  test "malformed port extensions fail within explicit bounds":
    type Scenario = tuple[variant, contextNeedle: string]
    let scenarios: seq[Scenario] = @[
      ("audio_missing_count", "field=count"),
      ("audio_missing_get", "field=get"),
      ("audio_too_many", "count=1025"),
      ("audio_get_fail", "direction=input; index=0"),
      ("audio_invalid_id", "field=id"),
      ("audio_duplicate_id", "duplicate=10"),
      ("audio_zero_channels", "field=channel_count"),
      ("audio_unterminated_name", "field=name"),
      ("audio_oversized_type", "field=port_type"),
      ("audio_inconsistent", "main port must be at index zero"),
      ("audio_too_many_channels", "direction total exceeds 4096"),
      ("audio_bad_type", "stereo requires two channels"),
      ("audio_bad_preference", "preference requires 64-bit support"),
      ("note_missing_count", "field=count"),
      ("note_missing_get", "field=get"),
      ("note_too_many", "count=1025"),
      ("note_get_fail", "direction=input; index=0"),
      ("note_invalid_id", "field=id"),
      ("note_duplicate_id", "duplicate=30"),
      ("note_unterminated_name", "field=name"),
      ("note_bad_supported", "field=supported_dialects"),
      ("note_bad_preferred", "field=preferred_dialect"),
    ]

    for scenario in scenarios:
      var opened = openPortInstance(scenario.variant)
      var instance = move(opened.instance)
      var observer = move(opened.observer)
      let api = opened.api

      let inspected = instance.inspectPortPlan()
      check not inspected.isOk
      check inspected.error.kind == hekClapPorts
      check inspected.error.context.contains(scenario.contextNeedle)
      check instance.state == cisInitialized
      check api.renderRequirementCalls() == 0'u32
      check api.renderSetCalls() == 0'u32
      check api.contractFailures() == 0'u32

      check instance.close().isOk
      check api.destroyCalls() == 1'u32
      check api.deinitCalls() == 1'u32
      check observer.close().isOk

  test "render callbacks are validated and real-time rejection is explicit":
    type Scenario = tuple[
      variant: string,
      succeeds: bool,
      hard: bool,
      requirementCalls: uint32,
      setCalls: uint32,
    ]
    let scenarios: seq[Scenario] = @[
      ("render_missing_requirement", false, false, 0'u32, 0'u32),
      ("render_missing_set", false, false, 0'u32, 0'u32),
      ("render_reject", false, false, 1'u32, 1'u32),
      ("render_hard", true, true, 1'u32, 1'u32),
    ]

    for scenario in scenarios:
      var opened = openPortInstance(scenario.variant)
      var instance = move(opened.instance)
      var observer = move(opened.observer)
      let api = opened.api

      let rendered = instance.negotiateRealtimeRender()
      check rendered.isOk == scenario.succeeds
      if rendered.isOk:
        check rendered.value.extensionPresent
        check rendered.value.hardRealtimeRequired == scenario.hard
        check rendered.value.realtimeModeApplied
      else:
        check rendered.error.kind == hekClapRender
      check api.renderRequirementCalls() == scenario.requirementCalls
      check api.renderSetCalls() == scenario.setCalls
      if scenario.setCalls > 0'u32:
        check api.lastRenderMode() == ClapRenderRealtime
      check api.contractFailures() == 0'u32

      check instance.close().isOk
      check observer.close().isOk

  test "foreign-thread control calls are rejected before plugin callbacks":
    var opened = openPortInstance("ports_valid")
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let api = opened.api
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk

    var attempt = PortThreadAttempt(instance: addr instance)
    var worker: Thread[ptr PortThreadAttempt]
    createThread(worker, inspectAndRenderOnThread, addr attempt)
    joinThread(worker)

    check not attempt.inspectSucceeded
    check attempt.inspectError == hekClapPorts
    check not attempt.renderSucceeded
    check attempt.renderError == hekClapRender
    check api.audioCountCalls() == 0'u32
    check api.audioGetCalls() == 0'u32
    check api.noteCountCalls() == 0'u32
    check api.noteGetCalls() == 0'u32
    check api.renderRequirementCalls() == 0'u32
    check api.renderSetCalls() == 0'u32
    check api.contractFailures() == 0'u32

    let inspected = instance.inspectPortPlan()
    require inspected.isOk
    check inspected.value.version.value == 1'u64
    check instance.negotiateRealtimeRender().isOk
