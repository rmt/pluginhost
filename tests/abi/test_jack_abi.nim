import std/[strutils, unittest]

import pluginhost/jack/ffi
import ./abi_probe

template checkLayout(typeName: typedesc; typeId: int32) =
  check uint64(sizeof(typeName)) == abiSize(typeId)
  check uint64(alignof(typeName)) == abiAlign(typeId)

template checkField(typeName: typedesc; fieldName: untyped;
                    typeId, fieldId: int32) =
  check uint64(offsetOf(typeName, fieldName)) ==
    abiOffset(abiFieldId(typeId, fieldId))

template checkFunctionPointer(typeName: typedesc) =
  check sizeof(typeName) == sizeof(pointer)
proc compileRtCallEffects(port: JackPort; portBuffer: pointer; nframes: JackNFrames) {.
    cdecl, gcsafe, raises: [].} =
  discard jackPortGetBuffer(port, nframes)
  discard jackMidiGetEventCount(portBuffer)
  var event: JackMidiEvent
  discard jackMidiEventGet(addr event, portBuffer, 0)
  jackMidiClearBuffer(portBuffer)
  discard jackMidiMaxEventSize(portBuffer)
  discard jackMidiEventReserve(portBuffer, 0, 3)
  discard jackMidiEventWrite(portBuffer, 0, nil, 0)


suite "JACK raw ABI":
  test "fundamental scalar widths and alignments match the JACK headers":
    checkLayout(JackNFrames, 101)
    checkLayout(JackTime, 102)
    checkLayout(JackPortId, 103)
    checkLayout(JackDefaultAudioSample, 104)
    checkLayout(JackOptions, 105)
    checkLayout(JackStatus, 106)
    checkLayout(JackLatencyCallbackMode, 107)
    checkLayout(JackPortFlags, 108)
    checkLayout(JackMidiData, 111)
    check sizeof(JackClient) == sizeof(pointer)
    check sizeof(JackPort) == sizeof(pointer)

  test "constants match the JACK headers":
    let expected = [
      int64(JackMaxFrames), int64(JackNullOption),
      int64(JackNoStartServer), int64(JackUseExactName),
      int64(JackServerName), int64(JackSessionId), int64(JackOpenOptions),
      int64(JackFailure), int64(JackInvalidOption), int64(JackNameNotUnique),
      int64(JackServerStarted), int64(JackServerFailed),
      int64(JackServerError), int64(JackNoSuchClient),
      int64(JackLoadFailure), int64(JackInitFailure), int64(JackShmFailure),
      int64(JackVersionError), int64(JackBackendError),
      int64(JackClientZombie), int64(JackCaptureLatency),
      int64(JackPlaybackLatency), int64(JackPortIsInput),
      int64(JackPortIsOutput), int64(JackPortIsPhysical),
      int64(JackPortCanMonitor), int64(JackPortIsTerminal),
    ]
    for index, value in expected:
      check value == abiConstant(int32(index + 101))

    check $abiString(101) == JackDefaultAudioType
    check $abiString(102) == JackDefaultMidiType

  test "structure layouts match the JACK headers":
    checkLayout(JackLatencyRange, 109)
    checkField(JackLatencyRange, min, 109, 1)
    checkField(JackLatencyRange, max, 109, 2)
    checkLayout(JackMidiEvent, 110)
    checkField(JackMidiEvent, time, 110, 1)
    checkField(JackMidiEvent, size, 110, 2)
    checkField(JackMidiEvent, buffer, 110, 3)

  test "callback values use the C function-pointer representation":
    checkFunctionPointer(JackProcessCallback)
    checkFunctionPointer(JackShutdownCallback)
    checkFunctionPointer(JackInfoShutdownCallback)
    checkFunctionPointer(JackBufferSizeCallback)
    checkFunctionPointer(JackSampleRateCallback)
    checkFunctionPointer(JackXrunCallback)
    checkFunctionPointer(JackLatencyCallback)

  test "the runtime library call boundary returns version information":
    var major, minor, micro, protocol: cint
    jackGetVersion(addr major, addr minor, addr micro, addr protocol)
    let versionText = jackGetVersionString()

    check major >= 0
    check minor >= 0
    check micro >= 0
    check protocol >= 0
    check versionText != nil
    check ($versionText).strip().len > 0
