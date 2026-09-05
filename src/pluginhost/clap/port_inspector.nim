import std/[options, sets]

import ./ffi
import ../domain/[errors, port_plan, result]
import ../support/utf8

const
  MaxAudioGroupsPerDirection* = 1_024'u32
  MaxNotePortsPerDirection* = 1_024'u32
  MaxAudioChannelsPerDirection* = 4_096'u32
  MaxPortTypeBytes* = 4 * 1_024
  MaxPortPlanMetadataBytes* = 16 * 1_024 * 1_024

  KnownAudioFlags = ClapAudioPortIsMain or ClapAudioPortSupports64Bits or
    ClapAudioPortPrefers64Bits or ClapAudioPortRequiresCommonSampleSize
  KnownNoteDialects = ClapNoteDialectClap or ClapNoteDialectMidi or
    ClapNoteDialectMidiMpe or ClapNoteDialectMidi2

type
  ClapRenderNegotiation* = object
    extensionPresent*: bool
    hardRealtimeRequired*: bool
    realtimeModeApplied*: bool

proc directionName(direction: PortDirection): string =
  case direction
  of pdInput: "input"
  of pdOutput: "output"

proc portError(path, pluginId, message, detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsClap, hekClapPorts, message, context)

proc renderError(path, pluginId, message, detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsClap, hekClapRender, message, context)

proc fieldDetail(direction: PortDirection; index: uint32;
                 field, detail: string): string =
  "direction=" & direction.directionName & "; index=" & $index &
    "; field=" & field & "; " & detail

proc copyFixedName(value: var array[ClapNameSize, char];
                   direction: PortDirection; index: uint32;
                   field, path, pluginId: string;
                   totalBytes: var int): Result[string] =
  var length = 0
  while length < ClapNameSize and value[length] != '\0':
    inc length
  if length == ClapNameSize:
    return failure[string](portError(
      path,
      pluginId,
      "CLAP port metadata is invalid",
      fieldDetail(direction, index, field,
        "fixed-size text is not null-terminated"),
    ))

  var raw = newString(length)
  if length > 0:
    copyMem(addr raw[0], unsafeAddr value[0], length)
  let copied = replaceInvalidUtf8(raw)
  if copied.len > MaxPortPlanMetadataBytes - totalBytes:
    return failure[string](portError(
      path,
      pluginId,
      "CLAP port metadata exceeds the bounded limit",
      fieldDetail(direction, index, field,
        "limit=" & $MaxPortPlanMetadataBytes),
    ))
  totalBytes += copied.len
  success(copied)

proc copyPortType(value: cstring; direction: PortDirection; index: uint32;
                  path, pluginId: string;
                  totalBytes: var int): Result[string] =
  if value == nil:
    return success("")

  let bytes = cast[ptr UncheckedArray[char]](value)
  var length = 0
  while length < MaxPortTypeBytes and bytes[length] != '\0':
    inc length
  if length == MaxPortTypeBytes:
    return failure[string](portError(
      path,
      pluginId,
      "CLAP port metadata is invalid",
      fieldDetail(direction, index, "port_type",
        "value reaches the " & $MaxPortTypeBytes & " byte limit"),
    ))

  var raw = newString(length)
  if length > 0:
    copyMem(addr raw[0], unsafeAddr bytes[0], length)
  let copied = replaceInvalidUtf8(raw)
  if copied.len > MaxPortPlanMetadataBytes - totalBytes:
    return failure[string](portError(
      path,
      pluginId,
      "CLAP port metadata exceeds the bounded limit",
      fieldDetail(direction, index, "port_type",
        "limit=" & $MaxPortPlanMetadataBytes),
    ))
  totalBytes += copied.len
  success(copied)

proc audioFlags(raw: uint32): AudioPortFlags =
  if (raw and ClapAudioPortIsMain) != 0:
    result.incl(apfMain)
  if (raw and ClapAudioPortSupports64Bits) != 0:
    result.incl(apfSupports64Bits)
  if (raw and ClapAudioPortPrefers64Bits) != 0:
    result.incl(apfPrefers64Bits)
  if (raw and ClapAudioPortRequiresCommonSampleSize) != 0:
    result.incl(apfRequiresCommonSampleSize)

proc audioStem(direction: PortDirection): string =
  case direction
  of pdInput: "audio_in_"
  of pdOutput: "audio_out_"

proc audioAlias(name: string; channelIndex, channelCount: uint32): string =
  if name.len == 0:
    return ""
  if channelCount == 1'u32:
    return name
  name & " " & $(channelIndex + 1'u32)

proc validateAudioInfo(info: ClapAudioPortInfo; direction: PortDirection;
                       index, flattenedCount: uint32;
                       path, pluginId: string): Result[Unit] =
  if info.id == ClapInvalidId:
    return failure[Unit](portError(
      path, pluginId, "CLAP audio port is invalid",
      fieldDetail(direction, index, "id", "CLAP_INVALID_ID is not a port ID")))
  if info.channelCount == 0'u32:
    return failure[Unit](portError(
      path, pluginId, "CLAP audio port is invalid",
      fieldDetail(direction, index, "channel_count", "value must be positive")))
  if info.channelCount > MaxAudioChannelsPerDirection - flattenedCount:
    return failure[Unit](portError(
      path, pluginId, "CLAP audio channel count exceeds the bounded limit",
      fieldDetail(direction, index, "channel_count",
        "direction total exceeds " & $MaxAudioChannelsPerDirection)))
  if (info.flags and ClapAudioPortIsMain) != 0 and index != 0'u32:
    return failure[Unit](portError(
      path, pluginId, "CLAP audio port is inconsistent",
      fieldDetail(direction, index, "flags",
        "the main port must be at index zero")))
  if (info.flags and ClapAudioPortPrefers64Bits) != 0 and
      (info.flags and ClapAudioPortSupports64Bits) == 0:
    return failure[Unit](portError(
      path, pluginId, "CLAP audio port is inconsistent",
      fieldDetail(direction, index, "flags",
        "64-bit preference requires 64-bit support")))
  success()

proc scanAudioDirection(plugin: ptr ClapPlugin;
                        extension: ptr ClapPluginAudioPorts;
                        direction: PortDirection; path, pluginId: string;
                        totalBytes: var int;
                        groups: var seq[AudioGroup];
                        channels: var seq[AudioChannelPlan]): Result[Unit] =
  let isInput = direction == pdInput
  let count = extension.count(plugin, isInput)
  if count > MaxAudioGroupsPerDirection:
    return failure[Unit](portError(
      path,
      pluginId,
      "CLAP audio port count exceeds the bounded limit",
      "direction=" & direction.directionName & "; count=" & $count &
        "; limit=" & $MaxAudioGroupsPerDirection,
    ))

  var ids = initHashSet[uint32]()
  var flattenedCount = 0'u32
  for index in 0'u32 ..< count:
    var info: ClapAudioPortInfo
    if not extension.get(plugin, index, isInput, addr info):
      return failure[Unit](portError(
        path,
        pluginId,
        "CLAP audio port inspection failed",
        "direction=" & direction.directionName & "; index=" & $index,
      ))

    let valid = validateAudioInfo(
      info, direction, index, flattenedCount, path, pluginId)
    if not valid.isOk:
      return valid
    if info.id in ids:
      return failure[Unit](portError(
        path, pluginId, "CLAP audio port IDs are not unique",
        fieldDetail(direction, index, "id", "duplicate=" & $info.id)))
    ids.incl(info.id)

    var name = copyFixedName(
      info.name, direction, index, "name", path, pluginId, totalBytes)
    if not name.isOk:
      return failure[Unit](move(name.error))
    var portType = copyPortType(
      info.portType, direction, index, path, pluginId, totalBytes)
    if not portType.isOk:
      return failure[Unit](move(portType.error))

    if portType.value == ClapPortMono and info.channelCount != 1'u32:
      return failure[Unit](portError(
        path, pluginId, "CLAP audio port type is inconsistent",
        fieldDetail(direction, index, "port_type",
          "mono requires one channel")))
    if portType.value == ClapPortStereo and info.channelCount != 2'u32:
      return failure[Unit](portError(
        path, pluginId, "CLAP audio port type is inconsistent",
        fieldDetail(direction, index, "port_type",
          "stereo requires two channels")))

    let flattenedFirst = flattenedCount
    let flattenedPast = flattenedCount + info.channelCount
    let groupName = move(name.value)
    for channelIndex in 0'u32 ..< info.channelCount:
      let flattenedIndex = flattenedCount + channelIndex
      channels.add(AudioChannelPlan(
        groupIndex: index,
        groupId: info.id,
        channelIndex: channelIndex,
        flattenedIndex: flattenedIndex,
        direction: direction,
        shortName: direction.audioStem & $(flattenedIndex + 1'u32),
        alias: audioAlias(groupName, channelIndex, info.channelCount),
      ))

    groups.add(AudioGroup(
      index: index,
      id: info.id,
      direction: direction,
      name: groupName,
      flags: audioFlags(info.flags),
      unknownFlags: info.flags and not KnownAudioFlags,
      channelCount: info.channelCount,
      portType: move(portType.value),
      inPlacePair: if info.inPlacePair == ClapInvalidId:
          none(uint32)
        else:
          some(info.inPlacePair),
      flattenedFirst: flattenedFirst,
      flattenedPast: flattenedPast,
    ))
    flattenedCount = flattenedPast
  success()

proc normalizeInPlacePairs(groups: var seq[AudioGroup]) =
  var inputIds = initHashSet[uint32]()
  var outputIds = initHashSet[uint32]()
  for group in groups:
    case group.direction
    of pdInput:
      inputIds.incl(group.id)
    of pdOutput:
      outputIds.incl(group.id)

  for group in groups.mitems:
    if group.inPlacePair.isNone:
      continue
    let pairId = group.inPlacePair.get
    let pairExists = case group.direction
      of pdInput: pairId in outputIds
      of pdOutput: pairId in inputIds
    if not pairExists:
      # The process path always supplies distinct buffers, so a dangling
      # informational pair cannot affect the realized layout.
      group.inPlacePair = none(uint32)

proc noteDialects(raw: uint32): NoteDialects =
  if (raw and ClapNoteDialectClap) != 0:
    result.incl(ndClap)
  if (raw and ClapNoteDialectMidi) != 0:
    result.incl(ndMidi)
  if (raw and ClapNoteDialectMidiMpe) != 0:
    result.incl(ndMidiMpe)
  if (raw and ClapNoteDialectMidi2) != 0:
    result.incl(ndMidi2)

proc noteDialect(raw: uint32): NoteDialect =
  case raw
  of ClapNoteDialectClap: ndClap
  of ClapNoteDialectMidi: ndMidi
  of ClapNoteDialectMidiMpe: ndMidiMpe
  of ClapNoteDialectMidi2: ndMidi2
  else: ndClap

proc noteStem(direction: PortDirection): string =
  case direction
  of pdInput: "midi_in_"
  of pdOutput: "midi_out_"

proc validateNoteInfo(info: ClapNotePortInfo; direction: PortDirection;
                      index: uint32; path, pluginId: string): Result[Unit] =
  if info.id == ClapInvalidId:
    return failure[Unit](portError(
      path, pluginId, "CLAP note port is invalid",
      fieldDetail(direction, index, "id", "CLAP_INVALID_ID is not a port ID")))
  if info.supportedDialects == 0'u32 or
      (info.supportedDialects and not KnownNoteDialects) != 0:
    return failure[Unit](portError(
      path, pluginId, "CLAP note port dialects are invalid",
      fieldDetail(direction, index, "supported_dialects",
        "value=" & $info.supportedDialects)))
  let preferred = info.preferredDialect
  if preferred == 0'u32 or (preferred and (preferred - 1'u32)) != 0 or
      (preferred and KnownNoteDialects) == 0 or
      (preferred and info.supportedDialects) == 0:
    return failure[Unit](portError(
      path, pluginId, "CLAP note port dialects are inconsistent",
      fieldDetail(direction, index, "preferred_dialect",
        "value=" & $preferred & "; supported=" & $info.supportedDialects)))
  success()

proc scanNoteDirection(plugin: ptr ClapPlugin;
                       extension: ptr ClapPluginNotePorts;
                       direction: PortDirection; path, pluginId: string;
                       totalBytes: var int;
                       ports: var seq[NotePortPlan]): Result[Unit] =
  let isInput = direction == pdInput
  let count = extension.count(plugin, isInput)
  if count > MaxNotePortsPerDirection:
    return failure[Unit](portError(
      path,
      pluginId,
      "CLAP note port count exceeds the bounded limit",
      "direction=" & direction.directionName & "; count=" & $count &
        "; limit=" & $MaxNotePortsPerDirection,
    ))

  var ids = initHashSet[uint32]()
  for index in 0'u32 ..< count:
    var info: ClapNotePortInfo
    if not extension.get(plugin, index, isInput, addr info):
      return failure[Unit](portError(
        path,
        pluginId,
        "CLAP note port inspection failed",
        "direction=" & direction.directionName & "; index=" & $index,
      ))

    let valid = validateNoteInfo(info, direction, index, path, pluginId)
    if not valid.isOk:
      return valid
    if info.id in ids:
      return failure[Unit](portError(
        path, pluginId, "CLAP note port IDs are not unique",
        fieldDetail(direction, index, "id", "duplicate=" & $info.id)))
    ids.incl(info.id)

    var name = copyFixedName(
      info.name, direction, index, "name", path, pluginId, totalBytes)
    if not name.isOk:
      return failure[Unit](move(name.error))
    ports.add(NotePortPlan(
      index: index,
      id: info.id,
      direction: direction,
      name: move(name.value),
      supportedDialects: noteDialects(info.supportedDialects),
      preferredDialect: noteDialect(info.preferredDialect),
      shortName: direction.noteStem & $(index + 1'u32),
    ))
  success()

proc inspectClapPorts*(plugin: ptr ClapPlugin;
                       audioPorts: ptr ClapPluginAudioPorts;
                       notePorts: ptr ClapPluginNotePorts;
                       version: PortPlanVersion;
                       path, pluginId: string): Result[PortPlan] =
  if plugin == nil:
    return failure[PortPlan](portError(
      path, pluginId, "CLAP port inspection requires a live plugin", ""))

  var groups = newSeqOfCap[AudioGroup](16)
  var channels = newSeqOfCap[AudioChannelPlan](32)
  var notes = newSeqOfCap[NotePortPlan](16)
  var totalBytes = 0

  if audioPorts != nil:
    if audioPorts.count == nil or audioPorts.get == nil:
      let field = if audioPorts.count == nil: "count" else: "get"
      return failure[PortPlan](portError(
        path,
        pluginId,
        "CLAP audio-ports extension has a missing required callback",
        "field=" & field,
      ))
    let inputs = scanAudioDirection(
      plugin, audioPorts, pdInput, path, pluginId, totalBytes, groups, channels)
    if not inputs.isOk:
      return failure[PortPlan](inputs.error)
    let outputs = scanAudioDirection(
      plugin, audioPorts, pdOutput, path, pluginId, totalBytes, groups, channels)
    if not outputs.isOk:
      return failure[PortPlan](outputs.error)
    normalizeInPlacePairs(groups)

  if notePorts != nil:
    if notePorts.count == nil or notePorts.get == nil:
      let field = if notePorts.count == nil: "count" else: "get"
      return failure[PortPlan](portError(
        path,
        pluginId,
        "CLAP note-ports extension has a missing required callback",
        "field=" & field,
      ))
    let inputs = scanNoteDirection(
      plugin, notePorts, pdInput, path, pluginId, totalBytes, notes)
    if not inputs.isOk:
      return failure[PortPlan](inputs.error)
    let outputs = scanNoteDirection(
      plugin, notePorts, pdOutput, path, pluginId, totalBytes, notes)
    if not outputs.isOk:
      return failure[PortPlan](outputs.error)

  success(newPortPlan(
    version,
    move(groups),
    move(channels),
    move(notes),
  ))

proc negotiateClapRealtimeRender*(plugin: ptr ClapPlugin;
                                  extension: ptr ClapPluginRender;
                                  path, pluginId: string):
                                  Result[ClapRenderNegotiation] =
  if plugin == nil:
    return failure[ClapRenderNegotiation](renderError(
      path, pluginId, "CLAP render negotiation requires a live plugin", ""))
  if extension == nil:
    return success(ClapRenderNegotiation())
  if extension.hasHardRealtimeRequirement == nil or extension.set == nil:
    let field = if extension.hasHardRealtimeRequirement == nil:
        "has_hard_realtime_requirement"
      else:
        "set"
    return failure[ClapRenderNegotiation](renderError(
      path,
      pluginId,
      "CLAP render extension has a missing required callback",
      "field=" & field,
    ))

  let hardRequirement = extension.hasHardRealtimeRequirement(plugin)
  if not extension.set(plugin, ClapRenderRealtime):
    return failure[ClapRenderNegotiation](renderError(
      path,
      pluginId,
      "CLAP plugin rejected real-time render mode",
      "mode=CLAP_RENDER_REALTIME; hard_requirement=" & $hardRequirement,
    ))
  success(ClapRenderNegotiation(
    extensionPresent: true,
    hardRealtimeRequired: hardRequirement,
    realtimeModeApplied: true,
  ))
