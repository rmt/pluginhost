import std/os

import pluginhost/domain/result
import pluginhost/platform/linux/dynlib

const
  JackPartialFixturePathEnvironment* = "PLUGINHOST_JACK_PARTIAL_FIXTURE"
  JackFakeFixturePathEnvironment* = "PLUGINHOST_JACK_FAKE_FIXTURE"

type
  FakeVoidProc* = proc() {.cdecl, gcsafe, raises: [].}
  FakeSetIntProc* = proc(value: cint) {.cdecl, gcsafe, raises: [].}
  FakeSetTwoIntsProc* = proc(first, second: cint) {.
    cdecl, gcsafe, raises: [].}
  FakeSetStringProc* = proc(value: cstring) {.cdecl, gcsafe, raises: [].}
  FakeSetIndexedStringProc* = proc(index: cint; value: cstring) {.
    cdecl, gcsafe, raises: [].}
  FakeGetIntProc* = proc(): cint {.cdecl, gcsafe, raises: [].}
  FakeGetIndexedIntProc* = proc(index: cint): cint {.
    cdecl, gcsafe, raises: [].}
  FakeGetStringProc* = proc(): cstring {.cdecl, gcsafe, raises: [].}
  FakeGetIndexedStringProc* = proc(index: cint): cstring {.
    cdecl, gcsafe, raises: [].}
  FakeGetIndexedFlagsProc* = proc(index: cint): culong {.
    cdecl, gcsafe, raises: [].}
  FakeSetAudioSampleProc* = proc(portIndex: cint; frame: uint32;
                                  value: cfloat) {.
    cdecl, gcsafe, raises: [].}
  FakeGetAudioSampleProc* = proc(portIndex: cint;
                                  frame: uint32): cfloat {.
    cdecl, gcsafe, raises: [].}
  FakeGetAudioAddressProc* = proc(portIndex: cint): uint64 {.
    cdecl, gcsafe, raises: [].}
  FakeInvokeProcessProc* = proc(frames: uint32): cint {.
    cdecl, gcsafe, raises: [].}
  FakeInvokeProcessOnThreadProc* = proc(frames: uint32; force: cint;
                                         callbackResult: ptr cint): cint {.
    cdecl, gcsafe, raises: [].}
  FakeAddMidiEventProc* = proc(portIndex: cint; time: uint32;
                                data: ptr uint8; size: uint32): cint {.
    cdecl, gcsafe, raises: [].}
  FakeSetMidiValueProc* = proc(portIndex: cint; value: uint32) {.
    cdecl, gcsafe, raises: [].}
  FakeSetMidiEventValueProc* = proc(portIndex: cint; eventIndex, value: uint32) {.
    cdecl, gcsafe, raises: [].}
  FakeSetMidiFailureProc* = proc(portIndex, eventIndex: cint) {.
    cdecl, gcsafe, raises: [].}
  FakeGetMidiCountProc* = proc(portIndex: cint): uint32 {.
    cdecl, gcsafe, raises: [].}
  FakeGetMidiValueProc* = proc(portIndex: cint; eventIndex: uint32): uint32 {.
    cdecl, gcsafe, raises: [].}
  FakeGetMidiByteProc* = proc(portIndex: cint; eventIndex, byteIndex: uint32):
      cint {.cdecl, gcsafe, raises: [].}
  FakeGetMidiAddressProc* = proc(portIndex: cint; eventIndex: uint32): uint64 {.
    cdecl, gcsafe, raises: [].}
  FakeSetPortLatencyProc* = proc(index, mode: cint; minimum, maximum: uint32) {.
    cdecl, gcsafe, raises: [].}
  FakeGetPortLatencyProc* = proc(index, mode, maximum: cint): uint32 {.
    cdecl, gcsafe, raises: [].}
  FakeInvokeShutdownProc* = proc(status: cint; reason: cstring) {.
    cdecl, gcsafe, raises: [].}

  FakeJackControls* = object
    library: DynamicLibrary
    reset*: FakeVoidProc
    setOpenFailure*: FakeSetIntProc
    setOpenSuccessStatus*: FakeSetIntProc
    setCallbackFailure*: FakeSetTwoIntsProc
    setPortFailure*: FakeSetIntProc
    setAliasFailure*: FakeSetIntProc
    setUnregisterFailure*: FakeSetIntProc
    setActivateStatus*: FakeSetIntProc
    setDeactivateStatus*: FakeSetIntProc
    setCloseStatus*: FakeSetIntProc
    setRecomputeStatus*: FakeSetIntProc
    setClientNameSize*: FakeSetIntProc
    setPortNameSize*: FakeSetIntProc
    setActualClientName*: FakeSetStringProc
    callbackOrderCount*: FakeGetIntProc
    callbackOrder*: FakeGetIndexedIntProc
    currentPortCount*: FakeGetIntProc
    registrationCount*: FakeGetIntProc
    unregisterCount*: FakeGetIntProc
    closeCount*: FakeGetIntProc
    activateCount*: FakeGetIntProc
    deactivateCount*: FakeGetIntProc
    recomputeCount*: FakeGetIntProc
    setPortConnection*: FakeSetIndexedStringProc
    setConnectStatus*: FakeSetIntProc
    connectCount*: FakeGetIntProc
    lastConnectSource*: FakeGetStringProc
    lastConnectDestination*: FakeGetStringProc
    setPortLatency*: FakeSetPortLatencyProc
    portLatency*: FakeGetPortLatencyProc
    isActive*: FakeGetIntProc
    callbacksCleared*: FakeGetIntProc
    requestedClientName*: FakeGetStringProc
    requestedServerName*: FakeGetStringProc
    requestedOptions*: FakeGetIntProc
    portShortName*: FakeGetIndexedStringProc
    portAlias*: FakeGetIndexedStringProc
    portType*: FakeGetIndexedStringProc
    portFlags*: FakeGetIndexedFlagsProc
    setAudioSample*: FakeSetAudioSampleProc
    audioSample*: FakeGetAudioSampleProc
    audioAddress*: FakeGetAudioAddressProc
    addMidiEvent*: FakeAddMidiEventProc
    clearMidiEvents*: FakeSetIntProc
    setMidiCapacity*: FakeSetMidiValueProc
    setMidiLostEvents*: FakeSetMidiValueProc
    setMidiEventTime*: FakeSetMidiEventValueProc
    setMidiEventSize*: FakeSetMidiEventValueProc
    setMidiGetFailure*: FakeSetMidiFailureProc
    midiEventCount*: FakeGetMidiCountProc
    midiEventTime*: FakeGetMidiValueProc
    midiEventSize*: FakeGetMidiValueProc
    midiEventByte*: FakeGetMidiByteProc
    midiEventAddress*: FakeGetMidiAddressProc
    invokeProcess*: FakeInvokeProcessProc
    forceProcess*: FakeInvokeProcessProc
    invokeProcessOnThread*: FakeInvokeProcessOnThreadProc
    beginBlockedProcess*: FakeInvokeProcessProc
    invokeShutdown*: FakeInvokeShutdownProc
    invokeXrun*: FakeVoidProc
    invokeFreewheel*: FakeSetIntProc
    invokeBufferSize*: FakeSetIntProc
    invokeSampleRate*: FakeSetIntProc
    invokeLatency*: FakeSetIntProc

proc `=destroy`*(controls: var FakeJackControls) =
  `=destroy`(controls.library)

proc `=copy`*(destination: var FakeJackControls; source: FakeJackControls) {.error:
  "FakeJackControls owns a dynamic library and cannot be copied; use move".}
proc `=dup`*(source: FakeJackControls): FakeJackControls {.error:
  "FakeJackControls owns a dynamic library and cannot be duplicated; use move".}

proc `=sink`*(destination: var FakeJackControls; source: FakeJackControls) =
  doAssert not destination.library.isOpen
  `=sink`(destination.library, source.library)
  destination.reset = source.reset
  destination.setOpenFailure = source.setOpenFailure
  destination.setOpenSuccessStatus = source.setOpenSuccessStatus
  destination.setCallbackFailure = source.setCallbackFailure
  destination.setPortFailure = source.setPortFailure
  destination.setAliasFailure = source.setAliasFailure
  destination.setUnregisterFailure = source.setUnregisterFailure
  destination.setActivateStatus = source.setActivateStatus
  destination.setDeactivateStatus = source.setDeactivateStatus
  destination.setCloseStatus = source.setCloseStatus
  destination.setRecomputeStatus = source.setRecomputeStatus
  destination.setClientNameSize = source.setClientNameSize
  destination.setPortNameSize = source.setPortNameSize
  destination.setActualClientName = source.setActualClientName
  destination.callbackOrderCount = source.callbackOrderCount
  destination.callbackOrder = source.callbackOrder
  destination.currentPortCount = source.currentPortCount
  destination.registrationCount = source.registrationCount
  destination.unregisterCount = source.unregisterCount
  destination.closeCount = source.closeCount
  destination.activateCount = source.activateCount
  destination.deactivateCount = source.deactivateCount
  destination.recomputeCount = source.recomputeCount
  destination.setPortConnection = source.setPortConnection
  destination.setConnectStatus = source.setConnectStatus
  destination.connectCount = source.connectCount
  destination.lastConnectSource = source.lastConnectSource
  destination.lastConnectDestination = source.lastConnectDestination
  destination.setPortLatency = source.setPortLatency
  destination.portLatency = source.portLatency
  destination.isActive = source.isActive
  destination.callbacksCleared = source.callbacksCleared
  destination.requestedClientName = source.requestedClientName
  destination.requestedServerName = source.requestedServerName
  destination.requestedOptions = source.requestedOptions
  destination.portShortName = source.portShortName
  destination.portAlias = source.portAlias
  destination.portType = source.portType
  destination.portFlags = source.portFlags
  destination.setAudioSample = source.setAudioSample
  destination.audioSample = source.audioSample
  destination.audioAddress = source.audioAddress
  destination.addMidiEvent = source.addMidiEvent
  destination.clearMidiEvents = source.clearMidiEvents
  destination.setMidiCapacity = source.setMidiCapacity
  destination.setMidiLostEvents = source.setMidiLostEvents
  destination.setMidiEventTime = source.setMidiEventTime
  destination.setMidiEventSize = source.setMidiEventSize
  destination.setMidiGetFailure = source.setMidiGetFailure
  destination.midiEventCount = source.midiEventCount
  destination.midiEventTime = source.midiEventTime
  destination.midiEventSize = source.midiEventSize
  destination.midiEventByte = source.midiEventByte
  destination.midiEventAddress = source.midiEventAddress
  destination.invokeProcess = source.invokeProcess
  destination.forceProcess = source.forceProcess
  destination.invokeProcessOnThread = source.invokeProcessOnThread
  destination.beginBlockedProcess = source.beginBlockedProcess
  destination.invokeShutdown = source.invokeShutdown
  destination.invokeXrun = source.invokeXrun
  destination.invokeFreewheel = source.invokeFreewheel
  destination.invokeBufferSize = source.invokeBufferSize
  destination.invokeSampleRate = source.invokeSampleRate
  destination.invokeLatency = source.invokeLatency

proc jackPartialFixturePath*(): string =
  result = getEnv(JackPartialFixturePathEnvironment)
  if result.len == 0:
    raise newException(ValueError,
      JackPartialFixturePathEnvironment &
        " must name the compiled partial JACK fixture")

proc jackFakeFixturePath*(): string =
  result = getEnv(JackFakeFixturePathEnvironment)
  if result.len == 0:
    raise newException(ValueError,
      JackFakeFixturePathEnvironment &
        " must name the compiled fake JACK fixture")

proc close*(controls: var FakeJackControls): Result[Unit] =
  controls.library.close()

proc openFakeJackControls*(): Result[FakeJackControls] =
  var opened = openDynamicLibrary(jackFakeFixturePath())
  if not opened.isOk:
    return failure[FakeJackControls](opened.error)
  var controls = FakeJackControls(library: move(opened.value))

  template resolve(field: untyped; procedureType: typedesc;
                   symbol: static string) =
    block:
      let resolved = resolveSymbol[procedureType](controls.library, symbol)
      if not resolved.isOk:
        let primary = resolved.error
        let cleanup = controls.library.close()
        if cleanup.isOk:
          return failure[FakeJackControls](primary)
        return failure[FakeJackControls](cleanup.error)
      controls.field = resolved.value

  resolve(reset, FakeVoidProc, "pluginhost_fake_jack_reset")
  resolve(setOpenFailure, FakeSetIntProc,
    "pluginhost_fake_jack_set_open_failure")
  resolve(setOpenSuccessStatus, FakeSetIntProc,
    "pluginhost_fake_jack_set_open_success_status")
  resolve(setCallbackFailure, FakeSetTwoIntsProc,
    "pluginhost_fake_jack_set_callback_failure")
  resolve(setPortFailure, FakeSetIntProc,
    "pluginhost_fake_jack_set_port_failure")
  resolve(setAliasFailure, FakeSetIntProc,
    "pluginhost_fake_jack_set_alias_failure")
  resolve(setUnregisterFailure, FakeSetIntProc,
    "pluginhost_fake_jack_set_unregister_failure")
  resolve(setActivateStatus, FakeSetIntProc,
    "pluginhost_fake_jack_set_activate_status")
  resolve(setDeactivateStatus, FakeSetIntProc,
    "pluginhost_fake_jack_set_deactivate_status")
  resolve(setCloseStatus, FakeSetIntProc,
    "pluginhost_fake_jack_set_close_status")
  resolve(setRecomputeStatus, FakeSetIntProc,
    "pluginhost_fake_jack_set_recompute_status")
  resolve(setPortConnection, FakeSetIndexedStringProc,
    "pluginhost_fake_jack_set_port_connection")
  resolve(setConnectStatus, FakeSetIntProc,
    "pluginhost_fake_jack_set_connect_status")
  resolve(connectCount, FakeGetIntProc,
    "pluginhost_fake_jack_connect_count")
  resolve(lastConnectSource, FakeGetStringProc,
    "pluginhost_fake_jack_last_connect_source")
  resolve(lastConnectDestination, FakeGetStringProc,
    "pluginhost_fake_jack_last_connect_destination")
  resolve(setClientNameSize, FakeSetIntProc,
    "pluginhost_fake_jack_set_client_name_size")
  resolve(setPortNameSize, FakeSetIntProc,
    "pluginhost_fake_jack_set_port_name_size")
  resolve(setActualClientName, FakeSetStringProc,
    "pluginhost_fake_jack_set_actual_client_name")
  resolve(callbackOrderCount, FakeGetIntProc,
    "pluginhost_fake_jack_callback_order_count")
  resolve(callbackOrder, FakeGetIndexedIntProc,
    "pluginhost_fake_jack_callback_order")
  resolve(currentPortCount, FakeGetIntProc,
    "pluginhost_fake_jack_current_port_count")
  resolve(registrationCount, FakeGetIntProc,
    "pluginhost_fake_jack_registration_count")
  resolve(unregisterCount, FakeGetIntProc,
    "pluginhost_fake_jack_unregister_count")
  resolve(closeCount, FakeGetIntProc, "pluginhost_fake_jack_close_count")
  resolve(activateCount, FakeGetIntProc,
    "pluginhost_fake_jack_activate_count")
  resolve(deactivateCount, FakeGetIntProc,
    "pluginhost_fake_jack_deactivate_count")
  resolve(recomputeCount, FakeGetIntProc,
    "pluginhost_fake_jack_recompute_count")
  resolve(setPortLatency, FakeSetPortLatencyProc,
    "pluginhost_fake_jack_set_port_latency")
  resolve(portLatency, FakeGetPortLatencyProc,
    "pluginhost_fake_jack_port_latency")
  resolve(isActive, FakeGetIntProc, "pluginhost_fake_jack_is_active")
  resolve(callbacksCleared, FakeGetIntProc,
    "pluginhost_fake_jack_callbacks_cleared")
  resolve(requestedClientName, FakeGetStringProc,
    "pluginhost_fake_jack_requested_client_name")
  resolve(requestedServerName, FakeGetStringProc,
    "pluginhost_fake_jack_requested_server_name")
  resolve(requestedOptions, FakeGetIntProc,
    "pluginhost_fake_jack_requested_options")
  resolve(portShortName, FakeGetIndexedStringProc,
    "pluginhost_fake_jack_port_short_name")
  resolve(portAlias, FakeGetIndexedStringProc,
    "pluginhost_fake_jack_port_alias")
  resolve(portType, FakeGetIndexedStringProc,
    "pluginhost_fake_jack_port_type")
  resolve(portFlags, FakeGetIndexedFlagsProc,
    "pluginhost_fake_jack_port_flags")
  resolve(setAudioSample, FakeSetAudioSampleProc,
    "pluginhost_fake_jack_set_audio_sample")
  resolve(audioSample, FakeGetAudioSampleProc,
    "pluginhost_fake_jack_audio_sample")
  resolve(audioAddress, FakeGetAudioAddressProc,
    "pluginhost_fake_jack_audio_address")
  resolve(addMidiEvent, FakeAddMidiEventProc,
    "pluginhost_fake_jack_add_midi_event")
  resolve(clearMidiEvents, FakeSetIntProc,
    "pluginhost_fake_jack_clear_midi_events")
  resolve(setMidiCapacity, FakeSetMidiValueProc,
    "pluginhost_fake_jack_set_midi_capacity")
  resolve(setMidiLostEvents, FakeSetMidiValueProc,
    "pluginhost_fake_jack_set_midi_lost_events")
  resolve(setMidiEventTime, FakeSetMidiEventValueProc,
    "pluginhost_fake_jack_set_midi_event_time")
  resolve(setMidiEventSize, FakeSetMidiEventValueProc,
    "pluginhost_fake_jack_set_midi_event_size")
  resolve(setMidiGetFailure, FakeSetMidiFailureProc,
    "pluginhost_fake_jack_set_midi_get_failure")
  resolve(midiEventCount, FakeGetMidiCountProc,
    "pluginhost_fake_jack_midi_event_count")
  resolve(midiEventTime, FakeGetMidiValueProc,
    "pluginhost_fake_jack_midi_event_time")
  resolve(midiEventSize, FakeGetMidiValueProc,
    "pluginhost_fake_jack_midi_event_size")
  resolve(midiEventByte, FakeGetMidiByteProc,
    "pluginhost_fake_jack_midi_event_byte")
  resolve(midiEventAddress, FakeGetMidiAddressProc,
    "pluginhost_fake_jack_midi_event_address")
  resolve(invokeProcess, FakeInvokeProcessProc,
    "pluginhost_fake_jack_invoke_process")
  resolve(forceProcess, FakeInvokeProcessProc,
    "pluginhost_fake_jack_force_process")
  resolve(invokeProcessOnThread, FakeInvokeProcessOnThreadProc,
    "pluginhost_fake_jack_invoke_process_on_thread")
  resolve(beginBlockedProcess, FakeInvokeProcessProc,
    "pluginhost_fake_jack_begin_blocked_process")
  resolve(invokeShutdown, FakeInvokeShutdownProc,
    "pluginhost_fake_jack_invoke_shutdown")
  resolve(invokeXrun, FakeVoidProc, "pluginhost_fake_jack_invoke_xrun")
  resolve(invokeFreewheel, FakeSetIntProc,
    "pluginhost_fake_jack_invoke_freewheel")
  resolve(invokeBufferSize, FakeSetIntProc,
    "pluginhost_fake_jack_invoke_buffer_size")
  resolve(invokeSampleRate, FakeSetIntProc,
    "pluginhost_fake_jack_invoke_sample_rate")
  resolve(invokeLatency, FakeSetIntProc,
    "pluginhost_fake_jack_invoke_latency")

  success(move(controls))
