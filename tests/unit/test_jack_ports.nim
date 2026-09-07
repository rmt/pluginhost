import std/[strutils, unittest]

import pluginhost/domain/[errors, port_plan]
import pluginhost/jack/[backend, ffi, ports]
import pluginhost/rt/engine
import ../fixtures/jack/fixture_api

proc fakeConfig(): JackBackendOpenConfig =
  initJackBackendOpenConfig(
    "requested",
    noStartServer = true,
    libraryPath = jackFakeFixturePath(),
  )

proc completePlan(version = 1'u64): PortPlan =
  newPortPlan(
    portPlanVersion(version),
    @[],
    @[
      AudioChannelPlan(
        direction: pdInput,
        shortName: "audio_in_1",
        alias: "Main Input",
      ),
      AudioChannelPlan(
        direction: pdOutput,
        shortName: "audio_out_1",
        alias: "Main Output",
      ),
    ],
    @[
      NotePortPlan(
        direction: pdInput,
        name: "Note Input",
        shortName: "midi_in_1",
      ),
      NotePortPlan(
        direction: pdOutput,
        name: "Note Output",
        shortName: "midi_out_1",
      ),
    ],
  )

proc singleAudioPlan(shortName, alias: string;
                     direction = pdOutput): PortPlan =
  newPortPlan(
    portPlanVersion(1),
    @[],
    @[AudioChannelPlan(
      direction: direction,
      shortName: shortName,
      alias: alias,
    )],
    @[],
  )

suite "transactional JACK port realization":
  test "JACK layout equivalence ignores plan generations but detects visible changes":
    check sameJackPortLayout(completePlan(1), completePlan(2))
    check not sameJackPortLayout(
      completePlan(),
      newPortPlan(portPlanVersion(1), @[], @[
        AudioChannelPlan(direction: pdInput, shortName: "audio_in_1",
          alias: "Changed Input"),
        AudioChannelPlan(direction: pdOutput, shortName: "audio_out_1",
          alias: "Main Output"),
      ], @[
        NotePortPlan(direction: pdInput, name: "Note Input",
          shortName: "midi_in_1"),
        NotePortPlan(direction: pdOutput, name: "Note Output",
          shortName: "midi_out_1"),
      ]))

  test "audio and note plans preserve names types directions and aliases":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    controls.setActualClientName("actual-client")
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk

    require backend.configure(completePlan(), fpmSilence).isOk

    check backend.state == jbsConfigured
    check backend.realizedPortCount == 4
    check controls.currentPortCount() == 4
    check $controls.portShortName(0) == "audio_in_1"
    check $controls.portShortName(1) == "audio_out_1"
    check $controls.portShortName(2) == "midi_in_1"
    check $controls.portShortName(3) == "midi_out_1"
    check $controls.portType(0) == JackDefaultAudioType
    check $controls.portType(2) == JackDefaultMidiType
    check controls.portFlags(0) == JackPortIsInput
    check controls.portFlags(1) == JackPortIsOutput
    check controls.portFlags(2) == JackPortIsInput
    check controls.portFlags(3) == JackPortIsOutput
    check $controls.portAlias(0) == "actual-client:Main Input"
    check $controls.portAlias(1) == "actual-client:Main Output"
    check $controls.portAlias(2) == "actual-client:Note Input"
    check $controls.portAlias(3) == "actual-client:Note Output"

  test "registration failure reports the flattened count and rolls back":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    controls.setPortFailure(1)
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk

    let configured = backend.configure(completePlan(), fpmSilence)

    check not configured.isOk
    check configured.error.kind == hekJackPortRegistration
    check configured.error.context.contains("count=2")
    check configured.error.context.contains("name=audio_out_1")
    check backend.state == jbsOpen
    check backend.realizedPortCount == 0
    check controls.currentPortCount() == 0
    check controls.unregisterCount() == 1

    controls.setPortFailure(-1)
    check backend.configure(completePlan(2), fpmSilence).isOk
    check backend.realizedPortCount == 4
    check controls.currentPortCount() == 4

  test "rollback unregister failure closes the entire client":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    controls.setPortFailure(1)
    controls.setUnregisterFailure(91)
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk

    let configured = backend.configure(completePlan(), fpmSilence)

    check not configured.isOk
    check configured.error.kind == hekJackPortRegistration
    check configured.error.message.contains("roll back")
    check configured.error.context.contains("status=91")
    check backend.state == jbsClosed
    check controls.currentPortCount() == 0
    check controls.closeCount() == 1
    check controls.callbacksCleared() == 1

  test "alias failure is startup failure and rolls back its registered port":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    controls.setAliasFailure(0)
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk

    let configured = backend.configure(
      singleAudioPlan("audio_out_1", "Output"), fpmSilence)

    check not configured.isOk
    check configured.error.kind == hekJackPortAlias
    check controls.currentPortCount() == 0
    check controls.unregisterCount() == 1
    check backend.state == jbsOpen

  test "canonical full-name boundary uses the actual JACK client name":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    controls.setActualClientName("client")
    controls.setPortNameSize(9)
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)

    check backend.configure(singleAudioPlan("a", ""), fpmSilence).isOk
    check controls.currentPortCount() == 1
    require backend.close().isOk

    controls.reset()
    controls.setActualClientName("client")
    controls.setPortNameSize(9)
    opened = openJackBackend(fakeConfig())
    require opened.isOk
    backend = move(opened.value)
    defer:
      doAssert backend.close().isOk
    let tooLong = backend.configure(
      singleAudioPlan("ab", ""), fpmSilence)

    check not tooLong.isOk
    check tooLong.error.kind == hekJackPortName
    check tooLong.error.context.contains("required=10")
    check tooLong.error.context.contains("limit=9")
    check controls.currentPortCount() == 0

  test "aliases truncate on a valid UTF-8 boundary under the server limit":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    controls.setActualClientName("c")
    controls.setPortNameSize(15)
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk

    require backend.configure(
      singleAudioPlan("a", "é".repeat(7)), fpmSilence).isOk

    check $controls.portAlias(0) == "c:" & "é".repeat(6)
    check ($controls.portAlias(0)).len == 14

  test "duplicate canonical names roll back instead of relying on JACK ambiguity":
    var openedControls = openFakeJackControls()
    require openedControls.isOk
    var controls = move(openedControls.value)
    defer:
      doAssert controls.close().isOk
    controls.reset()
    var opened = openJackBackend(fakeConfig())
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk
    let plan = newPortPlan(
      portPlanVersion(1),
      @[],
      @[
        AudioChannelPlan(direction: pdInput, shortName: "same"),
        AudioChannelPlan(direction: pdOutput, shortName: "same"),
      ],
      @[],
    )

    let configured = backend.configure(plan, fpmSilence)

    check not configured.isOk
    check configured.error.kind == hekJackPortName
    check controls.currentPortCount() == 0
    check controls.unregisterCount() == 1
