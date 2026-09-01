## Fixed-layout, allocation-free real-time process endpoint.
##
## The engine owns only POD buffer views and a prevalidated endpoint binding. The
## endpoint may be a CLAP adapter, but this module does not import CLAP types.

import std/typetraits

import ./midi_io

const
  RtMaxAudioChannelsPerDirection* = 4_096'u32
  RtProcessOk* = 0.cint
  RtProcessInvalidContext* = -1.cint
  RtProcessInvalidLayout* = -2.cint
  RtProcessMissingBuffer* = -3.cint
  RtProcessInvalidFrameCount* = -4.cint
  RtProcessEndpointFailure* = -5.cint

type
  RtProcessEndpointProc* = proc(context: pointer; engine: ptr RtEngine;
                                 nframes: uint32): cint {.
    cdecl, gcsafe, raises: [].}

  RtProcessEndpoint* {.bycopy.} = object
    callback*: RtProcessEndpointProc
    context*: pointer
    maxFrames*: uint32

  FakeProcessMode* = enum
    fpmSilence
    fpmCopyInput
    fpmDeterministic

  RtEngine* = object
    mode*: FakeProcessMode
    inputCount*: uint32
    outputCount*: uint32
    noteInputCount*: uint32
    noteOutputCount*: uint32
    maxFrames*: uint32
    endpoint*: RtProcessEndpoint
    midiIo*: RtMidiIo
    inputBuffers*: array[int(RtMaxAudioChannelsPerDirection),
      ptr UncheckedArray[cfloat]]
    outputBuffers*: array[int(RtMaxAudioChannelsPerDirection),
      ptr UncheckedArray[cfloat]]
    noteInputBuffers*: array[int(RtMaxMidiPortsPerDirection), pointer]
    noteOutputBuffers*: array[int(RtMaxMidiPortsPerDirection), pointer]

static:
  doAssert supportsCopyMem(RtProcessEndpoint)
  doAssert supportsCopyMem(RtEngine)

{.push checks: off, stackTrace: off, lineTrace: off.}
proc initRtEngine*(engine: var RtEngine; mode: FakeProcessMode;
                   inputCount, outputCount: uint32;
                   noteInputCount = 0'u32; noteOutputCount = 0'u32;
                   midiIo = RtMidiIo()): bool {.
    gcsafe, raises: [].} =
  if inputCount > RtMaxAudioChannelsPerDirection or
      outputCount > RtMaxAudioChannelsPerDirection or
      noteInputCount > RtMaxMidiPortsPerDirection or
      noteOutputCount > RtMaxMidiPortsPerDirection:
    return false
  engine.mode = mode
  engine.inputCount = inputCount
  engine.outputCount = outputCount
  engine.noteInputCount = noteInputCount
  engine.noteOutputCount = noteOutputCount
  engine.maxFrames = high(uint32)
  engine.endpoint = RtProcessEndpoint()
  engine.midiIo = midiIo
  true

proc initRtEngineEndpoint*(engine: var RtEngine; inputCount, outputCount,
                           noteInputCount, noteOutputCount, maxFrames: uint32;
                           endpoint: RtProcessEndpoint; midiIo: RtMidiIo): bool {.
    gcsafe, raises: [].} =
  if inputCount > RtMaxAudioChannelsPerDirection or
      outputCount > RtMaxAudioChannelsPerDirection or
      noteInputCount > RtMaxMidiPortsPerDirection or
      noteOutputCount > RtMaxMidiPortsPerDirection or
      maxFrames == 0'u32 or endpoint.callback == nil or
      endpoint.maxFrames == 0'u32 or endpoint.maxFrames < maxFrames or
      (noteInputCount != 0'u32 and not midiIo.isReadable) or
      (noteOutputCount != 0'u32 and not midiIo.isWritable):
    return false
  engine.mode = fpmSilence
  engine.inputCount = inputCount
  engine.outputCount = outputCount
  engine.noteInputCount = noteInputCount
  engine.noteOutputCount = noteOutputCount
  engine.maxFrames = maxFrames
  engine.endpoint = endpoint
  engine.midiIo = midiIo
  true

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

proc setMidiInputBuffer*(engine: ptr RtEngine; index: uint32;
                         buffer: pointer): bool {.
    exportc: "pluginhost_rt_set_midi_input", gcsafe, raises: [].} =
  if engine == nil or index >= engine.noteInputCount or
      index >= RtMaxMidiPortsPerDirection:
    return false
  engine.noteInputBuffers[int(index)] = buffer
  true

proc setMidiOutputBuffer*(engine: ptr RtEngine; index: uint32;
                          buffer: pointer): bool {.
    exportc: "pluginhost_rt_set_midi_output", gcsafe, raises: [].} =
  if engine == nil or index >= engine.noteOutputCount or
      index >= RtMaxMidiPortsPerDirection:
    return false
  engine.noteOutputBuffers[int(index)] = buffer
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

proc processRt*(engine: ptr RtEngine; nframes: uint32): cint {.
    exportc: "pluginhost_rt_process", gcsafe, raises: [].} =
  if engine == nil:
    return RtProcessInvalidContext
  if engine.endpoint.callback == nil:
    return processRtFake(engine, nframes)
  if nframes == 0'u32 or nframes > engine.maxFrames:
    return RtProcessInvalidFrameCount
  engine.endpoint.callback(engine.endpoint.context, engine, nframes)
{.pop.}
