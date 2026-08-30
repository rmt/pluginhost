## Fixed-layout, allocation-free fake real-time process endpoint for Increment 4B.
## No CLAP types or lifecycle operations are reachable from this module.

import std/typetraits

const
  RtMaxAudioChannelsPerDirection* = 4_096'u32
  RtProcessOk* = 0.cint
  RtProcessInvalidContext* = -1.cint
  RtProcessInvalidLayout* = -2.cint
  RtProcessMissingBuffer* = -3.cint

type
  FakeProcessMode* = enum
    fpmSilence
    fpmCopyInput
    fpmDeterministic

  RtEngine* = object
    mode*: FakeProcessMode
    inputCount*: uint32
    outputCount*: uint32
    inputBuffers*: array[int(RtMaxAudioChannelsPerDirection),
      ptr UncheckedArray[cfloat]]
    outputBuffers*: array[int(RtMaxAudioChannelsPerDirection),
      ptr UncheckedArray[cfloat]]

static:
  doAssert supportsCopyMem(RtEngine)

proc initRtEngine*(engine: var RtEngine; mode: FakeProcessMode;
                   inputCount, outputCount: uint32): bool {.
    gcsafe, raises: [].} =
  if inputCount > RtMaxAudioChannelsPerDirection or
      outputCount > RtMaxAudioChannelsPerDirection:
    return false
  engine.mode = mode
  engine.inputCount = inputCount
  engine.outputCount = outputCount
  true

{.push checks: off, stackTrace: off, lineTrace: off.}
proc setAudioInputBuffer*(engine: ptr RtEngine; index: uint32;
                          buffer: pointer): bool {.
    exportc: "pluginhost_rt_set_audio_input", gcsafe, raises: [].} =
  if engine == nil or index >= engine.inputCount or
      index >= RtMaxAudioChannelsPerDirection:
    return false
  engine.inputBuffers[int(index)] =
    cast[ptr UncheckedArray[cfloat]](buffer)
  true

proc setAudioOutputBuffer*(engine: ptr RtEngine; index: uint32;
                           buffer: pointer): bool {.
    exportc: "pluginhost_rt_set_audio_output", gcsafe, raises: [].} =
  if engine == nil or index >= engine.outputCount or
      index >= RtMaxAudioChannelsPerDirection:
    return false
  engine.outputBuffers[int(index)] =
    cast[ptr UncheckedArray[cfloat]](buffer)
  true

proc zeroRtOutputs*(engine: ptr RtEngine; nframes: uint32): cint {.
    exportc: "pluginhost_rt_zero_outputs", gcsafe, raises: [].} =
  if engine == nil:
    return RtProcessInvalidContext
  if engine.outputCount > RtMaxAudioChannelsPerDirection:
    return RtProcessInvalidLayout

  var missing = false
  var channel = 0'u32
  while channel < engine.outputCount:
    let output = engine.outputBuffers[int(channel)]
    if output == nil:
      missing = true
    else:
      var frame = 0'u32
      while frame < nframes:
        output[int(frame)] = 0.0
        frame += 1'u32
    channel += 1'u32
  if missing: RtProcessMissingBuffer else: RtProcessOk

proc processRtFake*(engine: ptr RtEngine; nframes: uint32): cint {.
    exportc: "pluginhost_rt_process_fake", gcsafe, raises: [].} =
  if engine == nil:
    return RtProcessInvalidContext
  if engine.inputCount > RtMaxAudioChannelsPerDirection or
      engine.outputCount > RtMaxAudioChannelsPerDirection:
    return RtProcessInvalidLayout

  case engine.mode
  of fpmSilence:
    zeroRtOutputs(engine, nframes)
  of fpmCopyInput:
    var missing = false
    var channel = 0'u32
    while channel < engine.outputCount:
      let output = engine.outputBuffers[int(channel)]
      if output == nil:
        missing = true
      else:
        let input = if channel < engine.inputCount:
            engine.inputBuffers[int(channel)]
          else:
            nil
        if channel < engine.inputCount and input == nil:
          missing = true
        var frame = 0'u32
        while frame < nframes:
          if input == nil:
            output[int(frame)] = 0.0
          else:
            output[int(frame)] = input[int(frame)]
          frame += 1'u32
      channel += 1'u32
    if missing: RtProcessMissingBuffer else: RtProcessOk
  of fpmDeterministic:
    var missing = false
    var channel = 0'u32
    while channel < engine.outputCount:
      let output = engine.outputBuffers[int(channel)]
      if output == nil:
        missing = true
      else:
        let channelBase = cfloat((channel + 1'u32) * 1_000'u32)
        var frame = 0'u32
        while frame < nframes:
          output[int(frame)] = channelBase + cfloat(frame)
          frame += 1'u32
      channel += 1'u32
    if missing: RtProcessMissingBuffer else: RtProcessOk
{.pop.}
