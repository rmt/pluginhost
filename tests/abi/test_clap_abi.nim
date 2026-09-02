import std/unittest

import pluginhost/clap/ffi
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

proc compileProcessCallEffects(plugin: ptr ClapPlugin; process: ptr ClapProcess) {.
    cdecl, gcsafe, raises: [].} =
  discard plugin.process(plugin, process)

suite "CLAP raw ABI":
  test "the bound SDK version and compatibility rule match CLAP 1.2.10":
    check ClapVersionCurrent.major == 1'u32
    check ClapVersionCurrent.minor == 2'u32
    check ClapVersionCurrent.revision == 10'u32
    check isCompatible(ClapVersionCurrent) ==
      (abiClapVersionIsCompatible(1, 2, 10) != 0)
    check isCompatible(ClapVersion(major: 2, minor: 0, revision: 0)) ==
      (abiClapVersionIsCompatible(2, 0, 0) != 0)
    check isCompatible(ClapVersion(major: 0, minor: 99, revision: 0)) ==
      (abiClapVersionIsCompatible(0, 99, 0) != 0)

  test "scalar widths and alignments match the official headers":
    checkLayout(ClapId, 27)
    checkLayout(ClapBeatTime, 28)
    checkLayout(ClapSecTime, 29)
    checkLayout(ClapProcessStatus, 30)
    checkLayout(ClapNoteExpression, 31)
    checkLayout(bool, 32)
    checkLayout(ClapPluginRenderMode, 36)

  test "constants match the official headers":
    let expected = [
      int64(ClapSdkVersionMajor), int64(ClapSdkVersionMinor),
      int64(ClapSdkVersionRevision), int64(ClapNameSize),
      int64(ClapPathSize), int64(ClapInvalidId), ClapBeatTimeFactor,
      ClapSecTimeFactor, int64(ClapCoreEventSpaceId),
      int64(ClapEventIsLive), int64(ClapEventDontRecord),
      int64(ClapEventTypeNoteOn), int64(ClapEventTypeNoteOff),
      int64(ClapEventTypeNoteChoke), int64(ClapEventTypeNoteEnd),
      int64(ClapEventTypeNoteExpression), int64(ClapEventTypeParamValue),
      int64(ClapEventTypeParamMod), int64(ClapEventTypeParamGestureBegin),
      int64(ClapEventTypeParamGestureEnd), int64(ClapEventTypeTransport),
      int64(ClapEventTypeMidi), int64(ClapEventTypeMidiSysex),
      int64(ClapEventTypeMidi2), int64(ClapNoteExpressionVolume),
      int64(ClapNoteExpressionPan), int64(ClapNoteExpressionTuning),
      int64(ClapNoteExpressionVibrato), int64(ClapNoteExpressionExpression),
      int64(ClapNoteExpressionBrightness), int64(ClapNoteExpressionPressure),
      int64(ClapTransportHasTempo), int64(ClapTransportHasBeatsTimeline),
      int64(ClapTransportHasSecondsTimeline),
      int64(ClapTransportHasTimeSignature), int64(ClapTransportIsPlaying),
      int64(ClapTransportIsRecording), int64(ClapTransportIsLoopActive),
      int64(ClapTransportIsWithinPreRoll), int64(ClapProcessError),
      int64(ClapProcessContinue), int64(ClapProcessContinueIfNotQuiet),
      int64(ClapProcessTail), int64(ClapProcessSleep),
      int64(ClapAudioPortIsMain), int64(ClapAudioPortSupports64Bits),
      int64(ClapAudioPortPrefers64Bits),
      int64(ClapAudioPortRequiresCommonSampleSize),
      int64(ClapAudioPortsRescanNames), int64(ClapAudioPortsRescanFlags),
      int64(ClapAudioPortsRescanChannelCount),
      int64(ClapAudioPortsRescanPortType),
      int64(ClapAudioPortsRescanInPlacePair),
      int64(ClapAudioPortsRescanList), int64(ClapNoteDialectClap),
      int64(ClapNoteDialectMidi), int64(ClapNoteDialectMidiMpe),
      int64(ClapNoteDialectMidi2), int64(ClapNotePortsRescanAll),
      int64(ClapNotePortsRescanNames),
      int64(ClapLogDebug), int64(ClapLogInfo),
      int64(ClapLogWarning), int64(ClapLogError),
      int64(ClapLogFatal), int64(ClapLogHostMisbehaving),
      int64(ClapLogPluginMisbehaving),
      int64(ClapRenderRealtime), int64(ClapRenderOffline),
      int64(ClapPosixFdRead), int64(ClapPosixFdWrite),
      int64(ClapPosixFdError), int64(ClapParamRescanValues),
      int64(ClapParamRescanText), int64(ClapParamRescanInfo),
      int64(ClapParamRescanAll), int64(ClapParamClearAll),
      int64(ClapParamClearAutomations), int64(ClapParamClearModulations),
    ]
    for index, value in expected:
      check value == abiConstant(int32(index + 1))

    check $abiString(1) == ClapPluginFactoryId
    check $abiString(2) == ClapExtAudioPorts
    check $abiString(3) == ClapExtNotePorts
    check $abiString(4) == ClapPortMono
    check $abiString(5) == ClapPortStereo
    check $abiString(6) == ClapExtLog
    check $abiString(7) == ClapExtThreadCheck
    check $abiString(8) == ClapExtRender
    check $abiString(9) == ClapExtState
    check $abiString(10) == ClapExtLatency
    check $abiString(11) == ClapExtTimerSupport
    check $abiString(12) == ClapExtPosixFdSupport
    check $abiString(13) == ClapExtParams

  test "structure sizes and alignments match the official headers":
    checkLayout(ClapVersion, 1)
    checkLayout(ClapEventHeader, 2)
    checkLayout(ClapEventNote, 3)
    checkLayout(ClapEventNoteExpression, 4)
    checkLayout(ClapEventParamValue, 5)
    checkLayout(ClapEventParamMod, 6)
    checkLayout(ClapEventParamGesture, 7)
    checkLayout(ClapEventTransport, 8)
    checkLayout(ClapEventMidi, 9)
    checkLayout(ClapEventMidiSysex, 10)
    checkLayout(ClapEventMidi2, 11)
    checkLayout(ClapInputEvents, 12)
    checkLayout(ClapOutputEvents, 13)
    checkLayout(ClapAudioBuffer, 14)
    checkLayout(ClapProcess, 15)
    checkLayout(ClapHost, 16)
    checkLayout(ClapPluginDescriptor, 17)
    checkLayout(ClapPlugin, 18)
    checkLayout(ClapPluginEntry, 19)
    checkLayout(ClapPluginFactory, 20)
    checkLayout(ClapAudioPortInfo, 21)
    checkLayout(ClapPluginAudioPorts, 22)
    checkLayout(ClapHostAudioPorts, 23)
    checkLayout(ClapNotePortInfo, 24)
    checkLayout(ClapPluginNotePorts, 25)
    checkLayout(ClapHostNotePorts, 26)
    checkLayout(ClapHostLog, 33)
    checkLayout(ClapHostThreadCheck, 34)
    checkLayout(ClapPluginRender, 35)
    checkLayout(ClapHostState, 37)
    checkLayout(ClapPluginLatency, 38)
    checkLayout(ClapHostLatency, 39)
    checkLayout(ClapPluginTimerSupport, 40)
    checkLayout(ClapHostTimerSupport, 41)
    checkLayout(ClapPluginPosixFdSupport, 42)
    checkLayout(ClapHostPosixFdSupport, 43)
    checkLayout(ClapParamInfo, 44)
    checkLayout(ClapPluginParams, 45)
    checkLayout(ClapHostParams, 46)

  test "event field offsets match the official headers":
    checkField(ClapVersion, major, 1, 1)
    checkField(ClapVersion, minor, 1, 2)
    checkField(ClapVersion, revision, 1, 3)
    checkField(ClapEventHeader, size, 2, 1)
    checkField(ClapEventHeader, time, 2, 2)
    checkField(ClapEventHeader, spaceId, 2, 3)
    checkField(ClapEventHeader, `type`, 2, 4)
    checkField(ClapEventHeader, flags, 2, 5)
    checkField(ClapEventNote, header, 3, 1)
    checkField(ClapEventNote, noteId, 3, 2)
    checkField(ClapEventNote, portIndex, 3, 3)
    checkField(ClapEventNote, channel, 3, 4)
    checkField(ClapEventNote, key, 3, 5)
    checkField(ClapEventNote, velocity, 3, 6)
    checkField(ClapEventNoteExpression, header, 4, 1)
    checkField(ClapEventNoteExpression, expressionId, 4, 2)
    checkField(ClapEventNoteExpression, noteId, 4, 3)
    checkField(ClapEventNoteExpression, portIndex, 4, 4)
    checkField(ClapEventNoteExpression, channel, 4, 5)
    checkField(ClapEventNoteExpression, key, 4, 6)
    checkField(ClapEventNoteExpression, value, 4, 7)
    checkField(ClapEventParamValue, header, 5, 1)
    checkField(ClapEventParamValue, paramId, 5, 2)
    checkField(ClapEventParamValue, cookie, 5, 3)
    checkField(ClapEventParamValue, noteId, 5, 4)
    checkField(ClapEventParamValue, portIndex, 5, 5)
    checkField(ClapEventParamValue, channel, 5, 6)
    checkField(ClapEventParamValue, key, 5, 7)
    checkField(ClapEventParamValue, value, 5, 8)
    checkField(ClapEventParamMod, header, 6, 1)
    checkField(ClapEventParamMod, paramId, 6, 2)
    checkField(ClapEventParamMod, cookie, 6, 3)
    checkField(ClapEventParamMod, noteId, 6, 4)
    checkField(ClapEventParamMod, portIndex, 6, 5)
    checkField(ClapEventParamMod, channel, 6, 6)
    checkField(ClapEventParamMod, key, 6, 7)
    checkField(ClapEventParamMod, amount, 6, 8)
    checkField(ClapEventParamGesture, header, 7, 1)
    checkField(ClapEventParamGesture, paramId, 7, 2)
    checkField(ClapEventTransport, header, 8, 1)
    checkField(ClapEventTransport, flags, 8, 2)
    checkField(ClapEventTransport, songPosBeats, 8, 3)
    checkField(ClapEventTransport, songPosSeconds, 8, 4)
    checkField(ClapEventTransport, tempo, 8, 5)
    checkField(ClapEventTransport, tempoInc, 8, 6)
    checkField(ClapEventTransport, loopStartBeats, 8, 7)
    checkField(ClapEventTransport, loopEndBeats, 8, 8)
    checkField(ClapEventTransport, loopStartSeconds, 8, 9)
    checkField(ClapEventTransport, loopEndSeconds, 8, 10)
    checkField(ClapEventTransport, barStart, 8, 11)
    checkField(ClapEventTransport, barNumber, 8, 12)
    checkField(ClapEventTransport, tsigNum, 8, 13)
    checkField(ClapEventTransport, tsigDenom, 8, 14)
    checkField(ClapEventMidi, header, 9, 1)
    checkField(ClapEventMidi, portIndex, 9, 2)
    checkField(ClapEventMidi, data, 9, 3)
    checkField(ClapEventMidiSysex, header, 10, 1)
    checkField(ClapEventMidiSysex, portIndex, 10, 2)
    checkField(ClapEventMidiSysex, buffer, 10, 3)
    checkField(ClapEventMidiSysex, size, 10, 4)
    checkField(ClapEventMidi2, header, 11, 1)
    checkField(ClapEventMidi2, portIndex, 11, 2)
    checkField(ClapEventMidi2, data, 11, 3)

  test "parameter extension offsets match the official headers":
    checkField(ClapParamInfo, id, 44, 1)
    checkField(ClapParamInfo, flags, 44, 2)
    checkField(ClapParamInfo, cookie, 44, 3)
    checkField(ClapParamInfo, name, 44, 4)
    checkField(ClapParamInfo, module, 44, 5)
    checkField(ClapParamInfo, minValue, 44, 6)
    checkField(ClapParamInfo, maxValue, 44, 7)
    checkField(ClapParamInfo, defaultValue, 44, 8)
    checkField(ClapPluginParams, count, 45, 1)
    checkField(ClapPluginParams, getInfo, 45, 2)
    checkField(ClapPluginParams, getValue, 45, 3)
    checkField(ClapPluginParams, valueToText, 45, 4)
    checkField(ClapPluginParams, textToValue, 45, 5)
    checkField(ClapPluginParams, flush, 45, 6)
    checkField(ClapHostParams, rescan, 46, 1)
    checkField(ClapHostParams, clear, 46, 2)
    checkField(ClapHostParams, requestFlush, 46, 3)

  test "process and callback-container offsets match the official headers":
    checkField(ClapInputEvents, ctx, 12, 1)
    checkField(ClapInputEvents, size, 12, 2)
    checkField(ClapInputEvents, get, 12, 3)
    checkField(ClapOutputEvents, ctx, 13, 1)
    checkField(ClapOutputEvents, tryPush, 13, 2)
    checkField(ClapAudioBuffer, data32, 14, 1)
    checkField(ClapAudioBuffer, data64, 14, 2)
    checkField(ClapAudioBuffer, channelCount, 14, 3)
    checkField(ClapAudioBuffer, latency, 14, 4)
    checkField(ClapAudioBuffer, constantMask, 14, 5)
    checkField(ClapProcess, steadyTime, 15, 1)
    checkField(ClapProcess, framesCount, 15, 2)
    checkField(ClapProcess, transport, 15, 3)
    checkField(ClapProcess, audioInputs, 15, 4)
    checkField(ClapProcess, audioOutputs, 15, 5)
    checkField(ClapProcess, audioInputsCount, 15, 6)
    checkField(ClapProcess, audioOutputsCount, 15, 7)
    checkField(ClapProcess, inEvents, 15, 8)
    checkField(ClapProcess, outEvents, 15, 9)

  test "host plugin entry and factory offsets match the official headers":
    checkField(ClapHost, clapVersion, 16, 1)
    checkField(ClapHost, hostData, 16, 2)
    checkField(ClapHost, name, 16, 3)
    checkField(ClapHost, vendor, 16, 4)
    checkField(ClapHost, url, 16, 5)
    checkField(ClapHost, version, 16, 6)
    checkField(ClapHost, getExtension, 16, 7)
    checkField(ClapHost, requestRestart, 16, 8)
    checkField(ClapHost, requestProcess, 16, 9)
    checkField(ClapHost, requestCallback, 16, 10)
    checkField(ClapPluginDescriptor, clapVersion, 17, 1)
    checkField(ClapPluginDescriptor, id, 17, 2)
    checkField(ClapPluginDescriptor, name, 17, 3)
    checkField(ClapPluginDescriptor, vendor, 17, 4)
    checkField(ClapPluginDescriptor, url, 17, 5)
    checkField(ClapPluginDescriptor, manualUrl, 17, 6)
    checkField(ClapPluginDescriptor, supportUrl, 17, 7)
    checkField(ClapPluginDescriptor, version, 17, 8)
    checkField(ClapPluginDescriptor, description, 17, 9)
    checkField(ClapPluginDescriptor, features, 17, 10)
    checkField(ClapPlugin, desc, 18, 1)
    checkField(ClapPlugin, pluginData, 18, 2)
    checkField(ClapPlugin, init, 18, 3)
    checkField(ClapPlugin, destroy, 18, 4)
    checkField(ClapPlugin, activate, 18, 5)
    checkField(ClapPlugin, deactivate, 18, 6)
    checkField(ClapPlugin, startProcessing, 18, 7)
    checkField(ClapPlugin, stopProcessing, 18, 8)
    checkField(ClapPlugin, reset, 18, 9)
    checkField(ClapPlugin, process, 18, 10)
    checkField(ClapPlugin, getExtension, 18, 11)
    checkField(ClapPlugin, onMainThread, 18, 12)
    checkField(ClapPluginEntry, clapVersion, 19, 1)
    checkField(ClapPluginEntry, init, 19, 2)
    checkField(ClapPluginEntry, deinit, 19, 3)
    checkField(ClapPluginEntry, getFactory, 19, 4)
    checkField(ClapPluginFactory, getPluginCount, 20, 1)
    checkField(ClapPluginFactory, getPluginDescriptor, 20, 2)
    checkField(ClapPluginFactory, createPlugin, 20, 3)

  test "audio note and render extension offsets match the official headers":
    checkField(ClapAudioPortInfo, id, 21, 1)
    checkField(ClapAudioPortInfo, name, 21, 2)
    checkField(ClapAudioPortInfo, flags, 21, 3)
    checkField(ClapAudioPortInfo, channelCount, 21, 4)
    checkField(ClapAudioPortInfo, portType, 21, 5)
    checkField(ClapAudioPortInfo, inPlacePair, 21, 6)
    checkField(ClapPluginAudioPorts, count, 22, 1)
    checkField(ClapPluginAudioPorts, get, 22, 2)
    checkField(ClapHostAudioPorts, isRescanFlagSupported, 23, 1)
    checkField(ClapHostAudioPorts, rescan, 23, 2)
    checkField(ClapNotePortInfo, id, 24, 1)
    checkField(ClapNotePortInfo, supportedDialects, 24, 2)
    checkField(ClapNotePortInfo, preferredDialect, 24, 3)
    checkField(ClapNotePortInfo, name, 24, 4)
    checkField(ClapPluginNotePorts, count, 25, 1)
    checkField(ClapPluginNotePorts, get, 25, 2)
    checkField(ClapHostNotePorts, supportedDialects, 26, 1)
    checkField(ClapHostNotePorts, rescan, 26, 2)
    checkField(ClapHostLog, log, 33, 1)
    checkField(ClapHostThreadCheck, isMainThread, 34, 1)
    checkField(ClapHostThreadCheck, isAudioThread, 34, 2)
    checkField(ClapPluginRender, hasHardRealtimeRequirement, 35, 1)
    checkField(ClapPluginRender, set, 35, 2)
    checkField(ClapHostState, markDirty, 37, 1)
    checkField(ClapPluginLatency, get, 38, 1)
    checkField(ClapHostLatency, changed, 39, 1)
    checkField(ClapPluginTimerSupport, onTimer, 40, 1)
    checkField(ClapHostTimerSupport, registerTimer, 41, 1)
    checkField(ClapHostTimerSupport, unregisterTimer, 41, 2)
    checkField(ClapPluginPosixFdSupport, onFd, 42, 1)
    checkField(ClapHostPosixFdSupport, registerFd, 43, 1)
    checkField(ClapHostPosixFdSupport, modifyFd, 43, 2)
    checkField(ClapHostPosixFdSupport, unregisterFd, 43, 3)

  test "all bound CLAP callbacks use pointer-sized C function values":
    checkFunctionPointer(ClapInputEventsSizeProc)
    checkFunctionPointer(ClapInputEventsGetProc)
    checkFunctionPointer(ClapOutputEventsTryPushProc)
    checkFunctionPointer(ClapHostGetExtensionProc)
    checkFunctionPointer(ClapHostRequestProc)
    checkFunctionPointer(ClapHostLogProc)
    checkFunctionPointer(ClapHostThreadCheckProc)
    checkFunctionPointer(ClapPluginInitProc)
    checkFunctionPointer(ClapPluginDestroyProc)
    checkFunctionPointer(ClapPluginActivateProc)
    checkFunctionPointer(ClapPluginDeactivateProc)
    checkFunctionPointer(ClapPluginStartProcessingProc)
    checkFunctionPointer(ClapPluginStopProcessingProc)
    checkFunctionPointer(ClapPluginResetProc)
    checkFunctionPointer(ClapPluginProcessProc)
    checkFunctionPointer(ClapPluginGetExtensionProc)
    checkFunctionPointer(ClapPluginOnMainThreadProc)
    checkFunctionPointer(ClapPluginEntryInitProc)
    checkFunctionPointer(ClapPluginEntryDeinitProc)
    checkFunctionPointer(ClapPluginEntryGetFactoryProc)
    checkFunctionPointer(ClapPluginFactoryGetCountProc)
    checkFunctionPointer(ClapPluginFactoryGetDescriptorProc)
    checkFunctionPointer(ClapPluginFactoryCreateProc)
    checkFunctionPointer(ClapPluginAudioPortsCountProc)
    checkFunctionPointer(ClapPluginAudioPortsGetProc)
    checkFunctionPointer(ClapHostAudioPortsIsRescanSupportedProc)
    checkFunctionPointer(ClapHostAudioPortsRescanProc)
    checkFunctionPointer(ClapPluginNotePortsCountProc)
    checkFunctionPointer(ClapPluginNotePortsGetProc)
    checkFunctionPointer(ClapHostNotePortsSupportedDialectsProc)
    checkFunctionPointer(ClapHostNotePortsRescanProc)
    checkFunctionPointer(ClapPluginRenderHasHardRealtimeRequirementProc)
    checkFunctionPointer(ClapPluginRenderSetProc)
    checkFunctionPointer(ClapHostStateMarkDirtyProc)
    checkFunctionPointer(ClapPluginLatencyGetProc)
    checkFunctionPointer(ClapHostLatencyChangedProc)
    checkFunctionPointer(ClapPluginTimerOnTimerProc)
    checkFunctionPointer(ClapHostTimerRegisterProc)
    checkFunctionPointer(ClapHostTimerUnregisterProc)
    checkFunctionPointer(ClapPluginPosixFdOnFdProc)
    checkFunctionPointer(ClapHostPosixFdRegisterProc)
    checkFunctionPointer(ClapHostPosixFdModifyProc)
    checkFunctionPointer(ClapHostPosixFdUnregisterProc)
    checkFunctionPointer(ClapPluginParamsCountProc)
    checkFunctionPointer(ClapPluginParamsGetInfoProc)
    checkFunctionPointer(ClapPluginParamsGetValueProc)
    checkFunctionPointer(ClapPluginParamsValueToTextProc)
    checkFunctionPointer(ClapPluginParamsTextToValueProc)
    checkFunctionPointer(ClapPluginParamsFlushProc)
    checkFunctionPointer(ClapHostParamsRescanProc)
    checkFunctionPointer(ClapHostParamsClearProc)
    checkFunctionPointer(ClapHostParamsRequestFlushProc)
