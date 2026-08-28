import std/[options, unittest]

import pluginhost/domain/port_plan

suite "immutable host port plan":
  test "typed values preserve grouping flattening dialects and names":
    let plan = newPortPlan(
      portPlanVersion(7),
      @[AudioGroup(
        index: 0,
        id: 10,
        direction: pdInput,
        name: "Main Input",
        flags: {apfMain, apfSupports64Bits},
        channelCount: 2,
        portType: "stereo",
        inPlacePair: some(20'u32),
        flattenedFirst: 0,
        flattenedPast: 2,
      )],
      @[
        AudioChannelPlan(
          groupIndex: 0,
          groupId: 10,
          channelIndex: 0,
          flattenedIndex: 0,
          direction: pdInput,
          shortName: "audio_in_1",
          alias: "Main Input 1",
        ),
        AudioChannelPlan(
          groupIndex: 0,
          groupId: 10,
          channelIndex: 1,
          flattenedIndex: 1,
          direction: pdInput,
          shortName: "audio_in_2",
          alias: "Main Input 2",
        ),
      ],
      @[NotePortPlan(
        index: 0,
        id: 30,
        direction: pdInput,
        name: "Notes",
        supportedDialects: {ndClap, ndMidi},
        preferredDialect: ndMidi,
        shortName: "midi_in_1",
      )],
    )

    check plan.version.value == 7'u64
    check plan.audioGroupCount == 1
    check plan.audioChannelCount == 2
    check plan.notePortCount == 1
    check plan.audioGroup(0).inPlacePair == some(20'u32)
    check plan.audioChannel(1).shortName == "audio_in_2"
    check plan.notePort(0).supportedDialects == {ndClap, ndMidi}

    var iteratedGroups = 0
    for group in plan.audioGroups:
      check group.id == 10'u32
      inc iteratedGroups
    check iteratedGroups == 1

  test "accessors return values rather than mutable plan storage":
    let plan = newPortPlan(
      portPlanVersion(1),
      @[AudioGroup(name: "original")],
      @[AudioChannelPlan(shortName: "audio_in_1")],
      @[NotePortPlan(name: "notes")],
    )

    var group = plan.audioGroup(0)
    var channel = plan.audioChannel(0)
    var note = plan.notePort(0)
    group.name = "changed"
    channel.shortName = "changed"
    note.name = "changed"

    check plan.audioGroup(0).name == "original"
    check plan.audioChannel(0).shortName == "audio_in_1"
    check plan.notePort(0).name == "notes"
