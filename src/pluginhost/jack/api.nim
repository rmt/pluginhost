## Checked runtime ownership for the minimal JACK ABI.
##
## JackApi owns libjack and a fully resolved procedure table. Procedure pointers
## remain valid only while their owning JackApi is open. Closing the owner is an
## explicit, checked control-plane operation and must happen only after all JACK
## clients and callbacks have been quiesced by the later backend layer.

import ../domain/[errors, result]
import ../platform/linux/dynlib
import ./ffi

type
  JackFunctions* = object
    getVersion*: JackGetVersionProc
    getVersionString*: JackGetVersionStringProc

    clientOpen*: JackClientOpenProc
    clientClose*: JackClientCloseProc
    clientNameSize*: JackClientNameSizeProc
    getClientName*: JackGetClientNameProc
    activate*: JackActivateProc
    deactivate*: JackDeactivateProc

    onShutdown*: JackOnShutdownProc
    onInfoShutdown*: JackOnInfoShutdownProc
    setProcessCallback*: JackSetProcessCallbackProc
    setBufferSizeCallback*: JackSetBufferSizeCallbackProc
    setSampleRateCallback*: JackSetSampleRateCallbackProc
    setXrunCallback*: JackSetXrunCallbackProc
    setFreewheelCallback*: JackSetFreewheelCallbackProc
    setLatencyCallback*: JackSetLatencyCallbackProc

    getSampleRate*: JackGetSampleRateProc
    getBufferSize*: JackGetBufferSizeProc

    portRegister*: JackPortRegisterProc
    portUnregister*: JackPortUnregisterProc
    portGetBuffer*: JackPortGetBufferProc
    portName*: JackPortNameProc
    portFlags*: JackPortFlagsProc
    portSetAlias*: JackPortSetAliasProc
    portNameSize*: JackPortNameSizeProc

    portGetLatencyRange*: JackPortGetLatencyRangeProc
    portSetLatencyRange*: JackPortSetLatencyRangeProc
    recomputeTotalLatencies*: JackRecomputeTotalLatenciesProc

    midiGetEventCount*: JackMidiGetEventCountProc
    midiEventGet*: JackMidiEventGetProc
    midiClearBuffer*: JackMidiClearBufferProc
    midiMaxEventSize*: JackMidiMaxEventSizeProc
    midiEventReserve*: JackMidiEventReserveProc
    midiEventWrite*: JackMidiEventWriteProc

  JackApi* = object
    ## Move-only owner for libjack and every required MVP procedure.
    library: DynamicLibrary
    functions*: JackFunctions

proc `=destroy`*(api: var JackApi) =
  # Checked release is explicit; a destructor cannot report dlclose failure.
  `=destroy`(api.library)

proc `=copy`*(destination: var JackApi; source: JackApi) {.error:
  "JackApi owns a dynamic library and cannot be copied; use move".}
proc `=dup`*(source: JackApi): JackApi {.error:
  "JackApi owns a dynamic library and cannot be duplicated; use move".}

proc `=sink`*(destination: var JackApi; source: JackApi) =
  doAssert not destination.library.isOpen,
    "an open JackApi must be closed before move assignment"
  `=sink`(destination.library, source.library)
  destination.functions = source.functions

proc isOpen*(api: JackApi): bool {.inline.} =
  api.library.isOpen

proc libraryPath*(api: JackApi): string {.inline.} =
  api.library.libraryPath

proc jackApiError(kind: HostErrorKind; message, path: string;
                  platformError: HostError): HostError =
  var context = "library=" & path
  if platformError.context.len > 0:
    context.add("; " & platformError.context)
  hostError(hsJack, kind, message, context)

proc close*(api: var JackApi): Result[Unit] =
  if not api.library.isOpen:
    api.functions = default(JackFunctions)
    return success()

  let closed = api.library.close()
  if not closed.isOk:
    return failure[Unit](jackApiError(
      hekJackLibraryClose,
      "could not unload the JACK client library",
      api.library.libraryPath,
      closed.error,
    ))

  api.functions = default(JackFunctions)
  success()

proc rollback(api: var JackApi; primary: HostError): HostError =
  let cleanup = api.close()
  if cleanup.isOk:
    return primary

  result = cleanup.error
  result.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    result.context.add(" (" & primary.context & ")")

proc openJackApi*(path = JackLibrary): Result[JackApi] =
  ## Loads libjack only when this operation is requested, resolves the
  ## complete reviewed MVP table, and rolls back the DSO on any missing symbol.
  var opened = openDynamicLibrary(path)
  if not opened.isOk:
    return failure[JackApi](jackApiError(
      hekJackLibraryOpen,
      "could not load the JACK client library",
      path,
      opened.error,
    ))

  var api = JackApi(library: move(opened.value))

  template resolveRequired(field: untyped; procedureType: typedesc;
                           symbol: static string) =
    block:
      let resolved = resolveSymbol[procedureType](api.library, symbol)
      if not resolved.isOk:
        let primary = jackApiError(
          hekJackSymbol,
          "required JACK client symbol is unavailable",
          path,
          resolved.error,
        )
        return failure[JackApi](api.rollback(primary))
      api.functions.field = resolved.value

  resolveRequired(getVersion, JackGetVersionProc, "jack_get_version")
  resolveRequired(getVersionString, JackGetVersionStringProc,
    "jack_get_version_string")

  resolveRequired(clientOpen, JackClientOpenProc, "jack_client_open")
  resolveRequired(clientClose, JackClientCloseProc, "jack_client_close")
  resolveRequired(clientNameSize, JackClientNameSizeProc,
    "jack_client_name_size")
  resolveRequired(getClientName, JackGetClientNameProc, "jack_get_client_name")
  resolveRequired(activate, JackActivateProc, "jack_activate")
  resolveRequired(deactivate, JackDeactivateProc, "jack_deactivate")

  resolveRequired(onShutdown, JackOnShutdownProc, "jack_on_shutdown")
  resolveRequired(onInfoShutdown, JackOnInfoShutdownProc,
    "jack_on_info_shutdown")
  resolveRequired(setProcessCallback, JackSetProcessCallbackProc,
    "jack_set_process_callback")
  resolveRequired(setBufferSizeCallback, JackSetBufferSizeCallbackProc,
    "jack_set_buffer_size_callback")
  resolveRequired(setSampleRateCallback, JackSetSampleRateCallbackProc,
    "jack_set_sample_rate_callback")
  resolveRequired(setXrunCallback, JackSetXrunCallbackProc,
    "jack_set_xrun_callback")
  resolveRequired(setFreewheelCallback, JackSetFreewheelCallbackProc,
    "jack_set_freewheel_callback")
  resolveRequired(setLatencyCallback, JackSetLatencyCallbackProc,
    "jack_set_latency_callback")

  resolveRequired(getSampleRate, JackGetSampleRateProc, "jack_get_sample_rate")
  resolveRequired(getBufferSize, JackGetBufferSizeProc, "jack_get_buffer_size")

  resolveRequired(portRegister, JackPortRegisterProc, "jack_port_register")
  resolveRequired(portUnregister, JackPortUnregisterProc, "jack_port_unregister")
  resolveRequired(portGetBuffer, JackPortGetBufferProc, "jack_port_get_buffer")
  resolveRequired(portName, JackPortNameProc, "jack_port_name")
  resolveRequired(portFlags, JackPortFlagsProc, "jack_port_flags")
  resolveRequired(portSetAlias, JackPortSetAliasProc, "jack_port_set_alias")
  resolveRequired(portNameSize, JackPortNameSizeProc, "jack_port_name_size")

  resolveRequired(portGetLatencyRange, JackPortGetLatencyRangeProc,
    "jack_port_get_latency_range")
  resolveRequired(portSetLatencyRange, JackPortSetLatencyRangeProc,
    "jack_port_set_latency_range")
  resolveRequired(recomputeTotalLatencies, JackRecomputeTotalLatenciesProc,
    "jack_recompute_total_latencies")

  resolveRequired(midiGetEventCount, JackMidiGetEventCountProc,
    "jack_midi_get_event_count")
  resolveRequired(midiEventGet, JackMidiEventGetProc, "jack_midi_event_get")
  resolveRequired(midiClearBuffer, JackMidiClearBufferProc,
    "jack_midi_clear_buffer")
  resolveRequired(midiMaxEventSize, JackMidiMaxEventSizeProc,
    "jack_midi_max_event_size")
  resolveRequired(midiEventReserve, JackMidiEventReserveProc,
    "jack_midi_event_reserve")
  resolveRequired(midiEventWrite, JackMidiEventWriteProc,
    "jack_midi_event_write")

  success(move(api))
