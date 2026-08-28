## Policy-free raw declarations for the stable JACK client ABI used by
## pluginhost. Layout, constants, callbacks, and procedure-pointer signatures
## are verified against system JACK development headers by tests/abi.
##
## This module deliberately has no {.dynlib.} imports. Runtime symbols are
## resolved by jack/api.nim so importing JACK-facing code never loads libjack.

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
  JackFreewheelCallback* = proc(starting: cint; argument: pointer) {.
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

type
  JackGetVersionProc* = proc(major, minor, micro,
                              protocol: ptr cint) {.
    cdecl, gcsafe, raises: [].}
  JackGetVersionStringProc* = proc(): cstring {.
    cdecl, gcsafe, raises: [].}

  JackClientOpenProc* = proc(clientName: cstring; options: JackOptions;
                              status: ptr JackStatus): JackClient {.
    cdecl, gcsafe, raises: [], varargs.}
  JackClientCloseProc* = proc(client: JackClient): cint {.
    cdecl, gcsafe, raises: [].}
  JackClientNameSizeProc* = proc(): cint {.
    cdecl, gcsafe, raises: [].}
  JackGetClientNameProc* = proc(client: JackClient): cstring {.
    cdecl, gcsafe, raises: [].}
  JackActivateProc* = proc(client: JackClient): cint {.
    cdecl, gcsafe, raises: [].}
  JackDeactivateProc* = proc(client: JackClient): cint {.
    cdecl, gcsafe, raises: [].}

  JackOnShutdownProc* = proc(client: JackClient;
                              callback: JackShutdownCallback;
                              argument: pointer) {.
    cdecl, gcsafe, raises: [].}
  JackOnInfoShutdownProc* = proc(client: JackClient;
                                  callback: JackInfoShutdownCallback;
                                  argument: pointer) {.
    cdecl, gcsafe, raises: [].}
  JackSetProcessCallbackProc* = proc(client: JackClient;
                                      callback: JackProcessCallback;
                                      argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  JackSetBufferSizeCallbackProc* = proc(client: JackClient;
      callback: JackBufferSizeCallback; argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  JackSetSampleRateCallbackProc* = proc(client: JackClient;
      callback: JackSampleRateCallback; argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  JackSetXrunCallbackProc* = proc(client: JackClient;
                                  callback: JackXrunCallback;
                                  argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  JackSetFreewheelCallbackProc* = proc(client: JackClient;
      callback: JackFreewheelCallback; argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  JackSetLatencyCallbackProc* = proc(client: JackClient;
                                      callback: JackLatencyCallback;
                                      argument: pointer): cint {.
    cdecl, gcsafe, raises: [].}

  JackGetSampleRateProc* = proc(client: JackClient): JackNFrames {.
    cdecl, gcsafe, raises: [].}
  JackGetBufferSizeProc* = proc(client: JackClient): JackNFrames {.
    cdecl, gcsafe, raises: [].}

  JackPortRegisterProc* = proc(client: JackClient;
      portName, portType: cstring; flags: JackPortFlags;
      bufferSize: culong): JackPort {.
    cdecl, gcsafe, raises: [].}
  JackPortUnregisterProc* = proc(client: JackClient; port: JackPort): cint {.
    cdecl, gcsafe, raises: [].}
  JackPortGetBufferProc* = proc(port: JackPort;
                                 nframes: JackNFrames): pointer {.
    cdecl, gcsafe, raises: [].}
  JackPortNameProc* = proc(port: JackPort): cstring {.
    cdecl, gcsafe, raises: [].}
  JackPortFlagsProc* = proc(port: JackPort): cint {.
    cdecl, gcsafe, raises: [].}
  JackPortSetAliasProc* = proc(port: JackPort; alias: cstring): cint {.
    cdecl, gcsafe, raises: [].}
  JackPortNameSizeProc* = proc(): cint {.
    cdecl, gcsafe, raises: [].}

  JackPortGetLatencyRangeProc* = proc(port: JackPort;
      mode: JackLatencyCallbackMode; latencyRange: ptr JackLatencyRange) {.
    cdecl, gcsafe, raises: [].}
  JackPortSetLatencyRangeProc* = proc(port: JackPort;
      mode: JackLatencyCallbackMode; latencyRange: ptr JackLatencyRange) {.
    cdecl, gcsafe, raises: [].}
  JackRecomputeTotalLatenciesProc* = proc(client: JackClient): cint {.
    cdecl, gcsafe, raises: [].}

  JackMidiGetEventCountProc* = proc(portBuffer: pointer): uint32 {.
    cdecl, gcsafe, raises: [].}
  JackMidiEventGetProc* = proc(event: ptr JackMidiEvent; portBuffer: pointer;
                                eventIndex: uint32): cint {.
    cdecl, gcsafe, raises: [].}
  JackMidiClearBufferProc* = proc(portBuffer: pointer) {.
    cdecl, gcsafe, raises: [].}
  JackMidiMaxEventSizeProc* = proc(portBuffer: pointer): csize_t {.
    cdecl, gcsafe, raises: [].}
  JackMidiEventReserveProc* = proc(portBuffer: pointer; time: JackNFrames;
      dataSize: csize_t): ptr JackMidiData {.
    cdecl, gcsafe, raises: [].}
  JackMidiEventWriteProc* = proc(portBuffer: pointer; time: JackNFrames;
      data: ptr JackMidiData; dataSize: csize_t): cint {.
    cdecl, gcsafe, raises: [].}
