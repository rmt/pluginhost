## Policy-free raw declarations for the stable JACK client ABI used by
## pluginhost. Layout, constants, and signatures are verified against system
## JACK development headers by tests/abi.

const
  JackLibrary* = "libjack.so.0"
  JackMaxFrames* = high(uint32)
  JackDefaultAudioType* = "32 bit float mono audio"
  JackDefaultMidiType* = "8 bit raw midi"

  JackNullOption* = 0x00.cint
  JackNoStartServer* = 0x01.cint
  JackUseExactName* = 0x02.cint
  JackServerName* = 0x04.cint
  JackSessionId* = 0x20.cint
  JackOpenOptions* = JackSessionId or JackServerName or JackNoStartServer or
    JackUseExactName

  JackFailure* = 0x001.cint
  JackInvalidOption* = 0x002.cint
  JackNameNotUnique* = 0x004.cint
  JackServerStarted* = 0x008.cint
  JackServerFailed* = 0x010.cint
  JackServerError* = 0x020.cint
  JackNoSuchClient* = 0x040.cint
  JackLoadFailure* = 0x080.cint
  JackInitFailure* = 0x100.cint
  JackShmFailure* = 0x200.cint
  JackVersionError* = 0x400.cint
  JackBackendError* = 0x800.cint
  JackClientZombie* = 0x1000.cint

  JackCaptureLatency* = 0.cint
  JackPlaybackLatency* = 1.cint

  JackPortIsInput* = 0x01.culong
  JackPortIsOutput* = 0x02.culong
  JackPortIsPhysical* = 0x04.culong
  JackPortCanMonitor* = 0x08.culong
  JackPortIsTerminal* = 0x10.culong

type
  JackNFrames* = uint32
  JackTime* = uint64
  JackPortId* = uint32
  JackDefaultAudioSample* = cfloat
  JackMidiData* = uint8
  JackOptions* = cint
  JackStatus* = cint
  JackLatencyCallbackMode* = cint
  JackPortFlags* = culong

  JackClientObject = distinct object
  JackClient* = ptr JackClientObject
  JackPortObject = distinct object
  JackPort* = ptr JackPortObject


  JackMidiEvent* {.bycopy.} = object
    time*: JackNFrames
    size*: csize_t
    buffer*: ptr JackMidiData

  JackProcessCallback* = proc(nframes: JackNFrames; argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  JackShutdownCallback* = proc(argument: pointer) {.
    cdecl, gcsafe, raises: [].}
  JackInfoShutdownCallback* = proc(code: JackStatus; reason: cstring;
                                    argument: pointer) {.
    cdecl, gcsafe, raises: [].}
  JackBufferSizeCallback* = proc(nframes: JackNFrames;
                                  argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  JackSampleRateCallback* = proc(nframes: JackNFrames;
                                  argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  JackXrunCallback* = proc(argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  JackLatencyCallback* = proc(mode: JackLatencyCallbackMode;
                               argument: pointer) {.
    cdecl, gcsafe, raises: [].}

# JACK deliberately packs this structure on byte boundaries for GNU-family
# x86 builds, but disables packing on several strict-alignment architectures.
when defined(arm) or defined(arm64) or defined(mips) or defined(powerpc):
  type JackLatencyRange* {.bycopy.} = object
    min*: JackNFrames
    max*: JackNFrames
else:
  type JackLatencyRange* {.bycopy, packed.} = object
    min*: JackNFrames
    max*: JackNFrames

{.push cdecl, dynlib: JackLibrary, gcsafe, raises: [].}

proc jackGetVersion*(major, minor, micro, protocol: ptr cint) {.
  importc: "jack_get_version".}
proc jackGetVersionString*(): cstring {.importc: "jack_get_version_string".}

proc jackClientOpen*(clientName: cstring; options: JackOptions;
                     status: ptr JackStatus): JackClient {.
  importc: "jack_client_open", varargs.}
proc jackClientClose*(client: JackClient): cint {.importc: "jack_client_close".}
proc jackClientNameSize*(): cint {.importc: "jack_client_name_size".}
proc jackGetClientName*(client: JackClient): cstring {.
  importc: "jack_get_client_name".}
proc jackActivate*(client: JackClient): cint {.importc: "jack_activate".}
proc jackDeactivate*(client: JackClient): cint {.importc: "jack_deactivate".}

proc jackOnShutdown*(client: JackClient; callback: JackShutdownCallback;
                     argument: pointer) {.importc: "jack_on_shutdown".}
proc jackOnInfoShutdown*(client: JackClient; callback: JackInfoShutdownCallback;
                         argument: pointer) {.
  importc: "jack_on_info_shutdown".}
proc jackSetProcessCallback*(client: JackClient; callback: JackProcessCallback;
                             argument: pointer): cint {.
  importc: "jack_set_process_callback".}
proc jackSetBufferSizeCallback*(client: JackClient;
    callback: JackBufferSizeCallback; argument: pointer): cint {.
  importc: "jack_set_buffer_size_callback".}
proc jackSetSampleRateCallback*(client: JackClient;
    callback: JackSampleRateCallback; argument: pointer): cint {.
  importc: "jack_set_sample_rate_callback".}
proc jackSetXrunCallback*(client: JackClient; callback: JackXrunCallback;
                          argument: pointer): cint {.
  importc: "jack_set_xrun_callback".}
proc jackSetLatencyCallback*(client: JackClient; callback: JackLatencyCallback;
                             argument: pointer): cint {.
  importc: "jack_set_latency_callback".}

proc jackGetSampleRate*(client: JackClient): JackNFrames {.
  importc: "jack_get_sample_rate".}
proc jackGetBufferSize*(client: JackClient): JackNFrames {.
  importc: "jack_get_buffer_size".}

proc jackPortRegister*(client: JackClient; portName, portType: cstring;
                       flags: JackPortFlags; bufferSize: culong): JackPort {.
  importc: "jack_port_register".}
proc jackPortUnregister*(client: JackClient; port: JackPort): cint {.
  importc: "jack_port_unregister".}
proc jackPortGetBuffer*(port: JackPort; nframes: JackNFrames): pointer {.
  importc: "jack_port_get_buffer".}
proc jackPortName*(port: JackPort): cstring {.importc: "jack_port_name".}
proc jackPortFlags*(port: JackPort): cint {.importc: "jack_port_flags".}
proc jackPortSetAlias*(port: JackPort; alias: cstring): cint {.
  importc: "jack_port_set_alias".}
proc jackPortNameSize*(): cint {.importc: "jack_port_name_size".}

proc jackPortGetLatencyRange*(port: JackPort; mode: JackLatencyCallbackMode;
                              range: ptr JackLatencyRange) {.
  importc: "jack_port_get_latency_range".}
proc jackPortSetLatencyRange*(port: JackPort; mode: JackLatencyCallbackMode;
                              range: ptr JackLatencyRange) {.
  importc: "jack_port_set_latency_range".}
proc jackRecomputeTotalLatencies*(client: JackClient): cint {.
  importc: "jack_recompute_total_latencies".}

proc jackMidiGetEventCount*(portBuffer: pointer): uint32 {.
  importc: "jack_midi_get_event_count".}
proc jackMidiEventGet*(event: ptr JackMidiEvent; portBuffer: pointer;
                       eventIndex: uint32): cint {.
  importc: "jack_midi_event_get".}
proc jackMidiClearBuffer*(portBuffer: pointer) {.
  importc: "jack_midi_clear_buffer".}
proc jackMidiMaxEventSize*(portBuffer: pointer): csize_t {.
  importc: "jack_midi_max_event_size".}
proc jackMidiEventReserve*(portBuffer: pointer; time: JackNFrames;
                           dataSize: csize_t): ptr JackMidiData {.
  importc: "jack_midi_event_reserve".}
proc jackMidiEventWrite*(portBuffer: pointer; time: JackNFrames;
                         data: ptr JackMidiData; dataSize: csize_t): cint {.
  importc: "jack_midi_event_write".}

{.pop.}
