## Control-plane VST3 bus inspection and immutable JACK-facing PortPlan creation.
## Native bus indices are retained verbatim; no VST3 bus is assigned a fake
## persistent identity.

import ../domain/[errors, port_plan, result]
import ./ffi

const
  Vst3MaxAudioBusesPerDirection* = 1_024'u32
  Vst3MaxEventBusesPerDirection* = 1_024'u32
  Vst3MaxAudioChannelsTotal* = 4_096'u32
  Vst3MaxPortMetadataBytes* = 16 * 1024 * 1024
  Vst3SpeakerNameBytes = 24

proc vst3PortError(path, pluginId, message, detail: string): HostError =
  var context = "path=" & path & "; id=" & pluginId
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsVst3, hekVst3Descriptor, message, context)


proc appendUtf8(output: var string; codepoint: uint32) =
  if codepoint <= 0x7F'u32:
    output.add(char(codepoint))
  elif codepoint <= 0x7FF'u32:
    output.add(char(0xC0'u32 or (codepoint shr 6)))
    output.add(char(0x80'u32 or (codepoint and 0x3F'u32)))
  elif codepoint <= 0xFFFF'u32:
    output.add(char(0xE0'u32 or (codepoint shr 12)))
    output.add(char(0x80'u32 or ((codepoint shr 6) and 0x3F'u32)))
    output.add(char(0x80'u32 or (codepoint and 0x3F'u32)))
  else:
    output.add(char(0xF0'u32 or (codepoint shr 18)))
    output.add(char(0x80'u32 or ((codepoint shr 12) and 0x3F'u32)))
    output.add(char(0x80'u32 or ((codepoint shr 6) and 0x3F'u32)))
    output.add(char(0x80'u32 or (codepoint and 0x3F'u32)))

proc decodeVst3Utf16(units: openArray[uint16]): string =
  result = newStringOfCap(units.len)
  var index = 0
  while index < units.len:
    let unit = uint32(units[index])
    var codepoint = unit
    if unit >= 0xD800'u32 and unit <= 0xDBFF'u32 and index + 1 < units.len and
        units[index + 1] >= 0xDC00'u16 and units[index + 1] <= 0xDFFF'u16:
      codepoint = 0x10000'u32 + ((unit - 0xD800'u32) shl 10) +
        (uint32(units[index + 1]) - 0xDC00'u32)
      inc index
    elif unit >= 0xD800'u32 and unit <= 0xDFFF'u32:
      codepoint = 0xFFFD'u32
    appendUtf8(result, codepoint)
    inc index

proc copyVst3Name(value: Vst3VstString128; path, pluginId: string;
                  direction: Vst3BusDirection; index: int32;
                  total: var int): Result[string] =
  var units = newSeq[uint16](value.len)
  for i in 0 ..< value.len:
    units[i] = uint16(value[i])
  var length = 0
  while length < units.len and units[length] != 0'u16:
    inc length
  if length == units.len:
    return failure[string](vst3PortError(path, pluginId,
      "VST3 bus name is not NUL terminated",
      "direction=" & $direction & "; index=" & $index))
  let text = if length == 0: "" else:
      decodeVst3Utf16(units.toOpenArray(0, length - 1))
  if text.len > Vst3MaxPortMetadataBytes - total:
    return failure[string](vst3PortError(path, pluginId,
      "VST3 port metadata exceeds the bounded limit",
      "limit=" & $Vst3MaxPortMetadataBytes))
  total += text.len
  success(text)

proc speakerName(bit: int): string =
  ## VST3 speaker bits are the canonical channel order.  Unknown/vendor bits
  ## remain deterministic instead of being silently dropped.
  case bit
  of 0: "L"
  of 1: "R"
  of 2: "C"
  of 3: "LFE"
  of 4: "Ls"
  of 5: "Rs"
  of 6: "Lc"
  of 7: "Rc"
  of 8: "S"
  of 9: "Sl"
  of 10: "Sr"
  of 11: "Tc"
  of 12: "Tfl"
  of 13: "Tfc"
  of 14: "Tfr"
  of 15: "Tbl"
  of 16: "Tbc"
  of 17: "Tbr"
  of 18: "LFE2"
  of 19: "M"
  of 20: "W"
  of 21: "X"
  of 22: "Y"
  of 23: "Z"
  else: "spk" & $(bit + 1)

proc arrangementChannelNames(arrangement: Vst3SpeakerArrangement;
                             count: uint32; path, pluginId: string;
                             direction: PortDirection; index: int32):
                             Result[seq[string]] =
  var names = newSeqOfCap[string](int(count))
  var bit = 0
  while bit < 64:
    if (arrangement and (1'u64 shl uint64(bit))) != 0:
      names.add(speakerName(bit))
    inc bit
  if names.len != int(count):
    return failure[seq[string]](vst3PortError(path, pluginId,
      "VST3 speaker arrangement does not match the bus channel count",
      "direction=" & $direction & "; index=" & $index &
      "; channels=" & $count & "; arrangement-bits=" & $names.len))
  success(move(names))

proc audioFlags(busType: int32): AudioPortFlags =
  if busType == Vst3BusTypeMain:
    result.incl(apfMain)

proc currentVst3Arrangements*(component: ptr Vst3Component;
                              processor: ptr Vst3AudioProcessor;
                              path, pluginId: string):
                              Result[seq[Vst3SpeakerArrangement]] =
  if component == nil or processor == nil or component.lpVtbl == nil or
      processor.lpVtbl == nil or component.lpVtbl.getBusCount == nil or
      processor.lpVtbl.getBusArrangement == nil:
    return failure[seq[Vst3SpeakerArrangement]](vst3PortError(path, pluginId,
      "VST3 arrangement inspection requires component and processor interfaces", ""))
  var arrangements: seq[Vst3SpeakerArrangement]
  for direction in [Vst3DirectionInput, Vst3DirectionOutput]:
    let count = component.lpVtbl.getBusCount(cast[pointer](component),
      Vst3MediaAudio, direction)
    if count < 0 or count > int32(Vst3MaxAudioBusesPerDirection):
      return failure[seq[Vst3SpeakerArrangement]](vst3PortError(path, pluginId,
        "VST3 audio bus count is outside the host bound",
        "direction=" & $direction & "; count=" & $count))
    for index in 0 ..< count:
      var arrangement: Vst3SpeakerArrangement
      let code = processor.lpVtbl.getBusArrangement(cast[pointer](processor),
        direction, index, addr arrangement)
      if code != Vst3ResultOk:
        return failure[seq[Vst3SpeakerArrangement]](vst3PortError(path, pluginId,
          "VST3 bus arrangement query failed",
          "direction=" & $direction & "; index=" & $index &
          "; result=" & $code))
      arrangements.add(arrangement)
  success(move(arrangements))

proc setVst3BusArrangementsAndRequery*(component: ptr Vst3Component;
                                       processor: ptr Vst3AudioProcessor;
                                       path, pluginId: string):
                                       Result[seq[Vst3SpeakerArrangement]] =
  if component == nil or processor == nil or component.lpVtbl == nil or
      processor.lpVtbl == nil or processor.lpVtbl.setBusArrangements == nil:
    return failure[seq[Vst3SpeakerArrangement]](vst3PortError(path, pluginId,
      "VST3 bus arrangement setup requires an audio processor", ""))
  var input: seq[Vst3SpeakerArrangement]
  var output: seq[Vst3SpeakerArrangement]
  for direction in [Vst3DirectionInput, Vst3DirectionOutput]:
    let count = component.lpVtbl.getBusCount(cast[pointer](component),
      Vst3MediaAudio, direction)
    if count < 0 or count > int32(Vst3MaxAudioBusesPerDirection):
      return failure[seq[Vst3SpeakerArrangement]](vst3PortError(path, pluginId,
        "VST3 audio bus count is outside the host bound",
        "direction=" & $direction & "; count=" & $count))
    for index in 0 ..< count:
      var arrangement: Vst3SpeakerArrangement
      if processor.lpVtbl.getBusArrangement(cast[pointer](processor),
          direction, index, addr arrangement) != Vst3ResultOk:
        return failure[seq[Vst3SpeakerArrangement]](vst3PortError(path, pluginId,
          "VST3 initial arrangement query failed",
          "direction=" & $direction & "; index=" & $index))
      if direction == Vst3DirectionInput: input.add(arrangement)
      else: output.add(arrangement)
  var inputPtr: pointer = nil
  var outputPtr: pointer = nil
  if input.len > 0:
    inputPtr = cast[pointer](addr input[0])
  if output.len > 0:
    outputPtr = cast[pointer](addr output[0])
  let code = processor.lpVtbl.setBusArrangements(cast[pointer](processor),
    inputPtr, int32(input.len), outputPtr, int32(output.len))
  if code != Vst3ResultOk and code != Vst3ResultFalse:
    return failure[seq[Vst3SpeakerArrangement]](vst3PortError(path, pluginId,
      "VST3 bus arrangement negotiation failed", "result=" & $code))
  ## kResultFalse is negotiation feedback.  The post-call query is mandatory.
  currentVst3Arrangements(component, processor, path, pluginId)

proc inspectVst3Ports*(component: ptr Vst3Component;
                       processor: ptr Vst3AudioProcessor;
                       arrangements: openArray[Vst3SpeakerArrangement];
                       version: PortPlanVersion;
                       path, pluginId: string): Result[PortPlan] =
  if component == nil or processor == nil or component.lpVtbl == nil or
      processor.lpVtbl == nil:
    return failure[PortPlan](vst3PortError(path, pluginId,
      "VST3 port inspection requires live component and processor interfaces", ""))
  var groups = newSeqOfCap[AudioGroup](16)
  var channels = newSeqOfCap[AudioChannelPlan](32)
  var notes = newSeqOfCap[NotePortPlan](8)
  var totalBytes = 0
  var inputTotal = 0'u32
  var outputTotal = 0'u32
  var audioTotal = 0'u32
  var arrangementIndex = 0
  for mediaType in [Vst3MediaAudio, Vst3MediaEvent]:
    for direction in [Vst3DirectionInput, Vst3DirectionOutput]:
      let count = component.lpVtbl.getBusCount(cast[pointer](component),
        mediaType, direction)
      let maxCount = if mediaType == Vst3MediaAudio:
          Vst3MaxAudioBusesPerDirection else: Vst3MaxEventBusesPerDirection
      if count < 0 or count > int32(maxCount):
        return failure[PortPlan](vst3PortError(path, pluginId,
          "VST3 bus count is outside the host bound",
          "media=" & $mediaType & "; direction=" & $direction &
          "; count=" & $count))
      for index in 0 ..< count:
        var info: Vst3BusInfo
        if component.lpVtbl.getBusInfo(cast[pointer](component), mediaType,
            direction, index, addr info) != Vst3ResultOk:
          return failure[PortPlan](vst3PortError(path, pluginId,
            "VST3 bus metadata query failed",
            "media=" & $mediaType & "; direction=" & $direction &
            "; index=" & $index))
        if info.mediaType != mediaType or info.direction != direction or
            info.channelCount < 0 or
            (info.busType != Vst3BusTypeMain and
             info.busType != Vst3BusTypeAux):
          return failure[PortPlan](vst3PortError(path, pluginId,
            "VST3 bus metadata is invalid",
            "media=" & $mediaType & "; direction=" & $direction &
            "; index=" & $index))
        var name = copyVst3Name(info.name, path, pluginId, direction, index,
          totalBytes)
        if not name.isOk: return failure[PortPlan](move(name.error))
        if mediaType == Vst3MediaAudio:
          if (info.flags and Vst3BusFlagControlVoltage) != 0:
            return failure[PortPlan](vst3PortError(path, pluginId,
              "VST3 control-voltage audio buses are unsupported",
              "direction=" & $direction & "; index=" & $index))
          if uint32(info.channelCount) > Vst3MaxAudioChannelsTotal - audioTotal:
            return failure[PortPlan](vst3PortError(path, pluginId,
              "VST3 audio channel count exceeds the host bound",
              "total-limit=" & $Vst3MaxAudioChannelsTotal))
          if arrangementIndex >= arrangements.len:
            return failure[PortPlan](vst3PortError(path, pluginId,
              "VST3 arrangement snapshot is incomplete", "index=" & $index))
          let pd = if direction == Vst3DirectionInput: pdInput else: pdOutput
          var speakerNames = arrangementChannelNames(arrangements[arrangementIndex],
            uint32(info.channelCount), path, pluginId, pd, index)
          if not speakerNames.isOk:
            return failure[PortPlan](move(speakerNames.error))
          let first = if direction == Vst3DirectionInput: inputTotal else: outputTotal
          let past = first + uint32(info.channelCount)
          for channelIndex in 0'u32 ..< uint32(info.channelCount):
            let channelName = speakerNames.value[int(channelIndex)]
            channels.add(AudioChannelPlan(
              groupIndex: uint32(index), groupId: uint32(index + 1),
              channelIndex: channelIndex, flattenedIndex: first + channelIndex,
              direction: pd,
              shortName: (if pd == pdInput: "audio_in_" else: "audio_out_") &
                $(first + channelIndex + 1),
              alias: if name.value.len == 0: channelName else:
                name.value & " " & channelName))
          groups.add(AudioGroup(
            index: uint32(index), id: uint32(index + 1), direction: pd,
            name: move(name.value), flags: audioFlags(info.busType),
            unknownFlags: info.flags and
              not (Vst3BusFlagDefaultActive or Vst3BusFlagControlVoltage),
            channelCount: uint32(info.channelCount), portType: "",
            flattenedFirst: first, flattenedPast: past))
          audioTotal += uint32(info.channelCount)
          if direction == Vst3DirectionInput: inputTotal = past
          else: outputTotal = past
          inc arrangementIndex
        else:
          ## V2B validates native event buses but does not expose JACK MIDI
          ## ports until the complete event transport path is implemented.
          discard
  if arrangementIndex != arrangements.len:
    return failure[PortPlan](vst3PortError(path, pluginId,
      "VST3 arrangement snapshot has extra entries",
      "expected=" & $arrangementIndex & "; actual=" & $arrangements.len))
  success(newPortPlan(version, move(groups), move(channels), move(notes)))

proc inspectVst3Ports*(component: ptr Vst3Component;
                       processor: ptr Vst3AudioProcessor;
                       version: PortPlanVersion;
                       path, pluginId: string): Result[PortPlan] =
  var arrangements = currentVst3Arrangements(component, processor, path, pluginId)
  if not arrangements.isOk:
    return failure[PortPlan](move(arrangements.error))
  inspectVst3Ports(component, processor, arrangements.value,
    version, path, pluginId)
