import std/options

type
  PortDirection* = enum
    pdInput
    pdOutput

  AudioPortFlag* = enum
    apfMain
    apfSupports64Bits
    apfPrefers64Bits
    apfRequiresCommonSampleSize

  AudioPortFlags* = set[AudioPortFlag]

  NoteDialect* = enum
    ndClap
    ndMidi
    ndMidiMpe
    ndMidi2

  NoteDialects* = set[NoteDialect]

  PortPlanVersion* = distinct uint64

  AudioGroup* = object
    index*: uint32
    id*: uint32
    direction*: PortDirection
    name*: string
    flags*: AudioPortFlags
    unknownFlags*: uint32
    channelCount*: uint32
    portType*: string
    inPlacePair*: Option[uint32]
    flattenedFirst*: uint32
    flattenedPast*: uint32

  AudioChannelPlan* = object
    groupIndex*: uint32
    groupId*: uint32
    channelIndex*: uint32
    flattenedIndex*: uint32
    direction*: PortDirection
    shortName*: string
    alias*: string

  NotePortPlan* = object
    index*: uint32
    id*: uint32
    direction*: PortDirection
    name*: string
    supportedDialects*: NoteDialects
    preferredDialect*: NoteDialect
    shortName*: string

  PortPlan* = object
    versionValue: PortPlanVersion
    audioGroupsValue: seq[AudioGroup]
    audioChannelsValue: seq[AudioChannelPlan]
    notePortsValue: seq[NotePortPlan]

proc `==`*(left, right: PortPlanVersion): bool {.borrow.}
proc `$`*(version: PortPlanVersion): string {.borrow.}

proc portPlanVersion*(value: uint64): PortPlanVersion =
  doAssert value > 0'u64, "a port-plan version must be positive"
  PortPlanVersion(value)

proc value*(version: PortPlanVersion): uint64 {.inline.} =
  uint64(version)

proc newPortPlan*(version: PortPlanVersion;
                  audioGroups: sink seq[AudioGroup];
                  audioChannels: sink seq[AudioChannelPlan];
                  notePorts: sink seq[NotePortPlan]): PortPlan =
  PortPlan(
    versionValue: version,
    audioGroupsValue: move(audioGroups),
    audioChannelsValue: move(audioChannels),
    notePortsValue: move(notePorts),
  )

proc version*(plan: PortPlan): PortPlanVersion {.inline.} =
  plan.versionValue

proc audioGroupCount*(plan: PortPlan): int {.inline.} =
  plan.audioGroupsValue.len

proc audioChannelCount*(plan: PortPlan): int {.inline.} =
  plan.audioChannelsValue.len

proc notePortCount*(plan: PortPlan): int {.inline.} =
  plan.notePortsValue.len

proc audioGroup*(plan: PortPlan; index: int): AudioGroup {.inline.} =
  plan.audioGroupsValue[index]

proc audioChannel*(plan: PortPlan; index: int): AudioChannelPlan {.inline.} =
  plan.audioChannelsValue[index]

proc notePort*(plan: PortPlan; index: int): NotePortPlan {.inline.} =
  plan.notePortsValue[index]

iterator audioGroups*(plan: PortPlan): AudioGroup =
  for group in plan.audioGroupsValue:
    yield group

iterator audioChannels*(plan: PortPlan): AudioChannelPlan =
  for channel in plan.audioChannelsValue:
    yield channel

iterator notePorts*(plan: PortPlan): NotePortPlan =
  for port in plan.notePortsValue:
    yield port
