import std/unittest

import pluginhost/rt/engine

const TestFrames = 8

template bindOutput(engine: var RtEngine; index: uint32;
                    buffer: untyped) =
  check setAudioOutputBuffer(addr engine, index, addr buffer[0])

template bindInput(engine: var RtEngine; index: uint32;
                   buffer: untyped) =
  check setAudioInputBuffer(addr engine, index, addr buffer[0])

suite "fixed-layout fake real-time engine":
  test "silence mode defines every output sample":
    var outputLeft, outputRight: array[TestFrames, cfloat]
    for index in 0 ..< TestFrames:
      outputLeft[index] = 5.0
      outputRight[index] = -5.0
    var engine: RtEngine
    require engine.initRtEngine(fpmSilence, 0, 2)
    engine.bindOutput(0, outputLeft)
    engine.bindOutput(1, outputRight)

    check processRtFake(addr engine, TestFrames) == RtProcessOk
    for index in 0 ..< TestFrames:
      check outputLeft[index] == 0.0
      check outputRight[index] == 0.0

  test "copy mode preserves matching channels and silences unmatched outputs":
    var inputLeft, inputRight: array[TestFrames, cfloat]
    var outputLeft, outputRight, outputExtra: array[TestFrames, cfloat]
    for index in 0 ..< TestFrames:
      inputLeft[index] = cfloat(index + 1)
      inputRight[index] = cfloat(100 + index)
      outputExtra[index] = 9.0
    var engine: RtEngine
    require engine.initRtEngine(fpmCopyInput, 2, 3)
    engine.bindInput(0, inputLeft)
    engine.bindInput(1, inputRight)
    engine.bindOutput(0, outputLeft)
    engine.bindOutput(1, outputRight)
    engine.bindOutput(2, outputExtra)

    check processRtFake(addr engine, TestFrames) == RtProcessOk
    for index in 0 ..< TestFrames:
      check outputLeft[index] == inputLeft[index]
      check outputRight[index] == inputRight[index]
      check outputExtra[index] == 0.0

  test "deterministic mode is repeatable by channel and frame":
    var outputLeft, outputRight: array[TestFrames, cfloat]
    var engine: RtEngine
    require engine.initRtEngine(fpmDeterministic, 0, 2)
    engine.bindOutput(0, outputLeft)
    engine.bindOutput(1, outputRight)

    check processRtFake(addr engine, TestFrames) == RtProcessOk
    check outputLeft[0] == 1_000.0
    check outputLeft[7] == 1_007.0
    check outputRight[0] == 2_000.0
    check outputRight[7] == 2_007.0

  test "invalid layouts and missing buffers fail without undefined success":
    var engine: RtEngine
    check not engine.initRtEngine(
      fpmSilence, RtMaxAudioChannelsPerDirection + 1'u32, 0)
    require engine.initRtEngine(fpmCopyInput, 1, 1)
    check processRtFake(addr engine, TestFrames) == RtProcessMissingBuffer
    check zeroRtOutputs(nil, TestFrames) == RtProcessInvalidContext
