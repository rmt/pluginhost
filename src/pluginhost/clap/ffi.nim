## Policy-free raw declarations for the stable CLAP 1.2.10 ABI used by
## pluginhost. Layout and constants are verified against the vendored official
## headers by tests/abi.

const
  ClapSdkVersionMajor* = 1'u32
  ClapSdkVersionMinor* = 2'u32
  ClapSdkVersionRevision* = 10'u32
  ClapNameSize* = 256
  ClapPathSize* = 1024

  ClapInvalidId* = high(uint32)
  ClapBeatTimeFactor* = 1'i64 shl 31
  ClapSecTimeFactor* = 1'i64 shl 31

  ClapPluginFactoryId* = "clap.plugin-factory"
  ClapExtAudioPorts* = "clap.audio-ports"
  ClapExtNotePorts* = "clap.note-ports"
  ClapExtRender* = "clap.render"
  ClapExtLog* = "clap.log"
  ClapExtParams* = "clap.params"
  ClapExtState* = "clap.state"
  ClapExtLatency* = "clap.latency"
  ClapExtTimerSupport* = "clap.timer-support"
  ClapExtPosixFdSupport* = "clap.posix-fd-support"
  ClapExtThreadCheck* = "clap.thread-check"
  ClapExtGui* = "clap.gui"
  ClapWindowApiX11* = "x11"
  ClapPortMono* = "mono"
  ClapPortStereo* = "stereo"

  ClapCoreEventSpaceId* = 0'u16
  ClapEventIsLive* = 1'u32 shl 0
  ClapEventDontRecord* = 1'u32 shl 1

  ClapEventTypeNoteOn* = 0'u16
  ClapEventTypeNoteOff* = 1'u16
  ClapEventTypeNoteChoke* = 2'u16
  ClapEventTypeNoteEnd* = 3'u16
  ClapEventTypeNoteExpression* = 4'u16
  ClapEventTypeParamValue* = 5'u16
  ClapEventTypeParamMod* = 6'u16
  ClapEventTypeParamGestureBegin* = 7'u16
  ClapEventTypeParamGestureEnd* = 8'u16
  ClapEventTypeTransport* = 9'u16
  ClapEventTypeMidi* = 10'u16
  ClapEventTypeMidiSysex* = 11'u16
  ClapEventTypeMidi2* = 12'u16

  ClapNoteExpressionVolume* = 0'i32
  ClapNoteExpressionPan* = 1'i32
  ClapNoteExpressionTuning* = 2'i32
  ClapNoteExpressionVibrato* = 3'i32
  ClapNoteExpressionExpression* = 4'i32
  ClapNoteExpressionBrightness* = 5'i32
  ClapNoteExpressionPressure* = 6'i32

  ClapTransportHasTempo* = 1'u32 shl 0
  ClapTransportHasBeatsTimeline* = 1'u32 shl 1
  ClapTransportHasSecondsTimeline* = 1'u32 shl 2
  ClapTransportHasTimeSignature* = 1'u32 shl 3
  ClapTransportIsPlaying* = 1'u32 shl 4
  ClapTransportIsRecording* = 1'u32 shl 5
  ClapTransportIsLoopActive* = 1'u32 shl 6
  ClapTransportIsWithinPreRoll* = 1'u32 shl 7

  ClapProcessError* = 0'i32
  ClapProcessContinue* = 1'i32
  ClapProcessContinueIfNotQuiet* = 2'i32
  ClapProcessTail* = 3'i32
  ClapProcessSleep* = 4'i32

  ClapAudioPortIsMain* = 1'u32 shl 0
  ClapAudioPortSupports64Bits* = 1'u32 shl 1
  ClapAudioPortPrefers64Bits* = 1'u32 shl 2
  ClapAudioPortRequiresCommonSampleSize* = 1'u32 shl 3

  ClapAudioPortsRescanNames* = 1'u32 shl 0
  ClapAudioPortsRescanFlags* = 1'u32 shl 1
  ClapAudioPortsRescanChannelCount* = 1'u32 shl 2
  ClapAudioPortsRescanPortType* = 1'u32 shl 3
  ClapAudioPortsRescanInPlacePair* = 1'u32 shl 4
  ClapAudioPortsRescanList* = 1'u32 shl 5

  ClapNoteDialectClap* = 1'u32 shl 0
  ClapNoteDialectMidi* = 1'u32 shl 1
  ClapNoteDialectMidiMpe* = 1'u32 shl 2
  ClapNoteDialectMidi2* = 1'u32 shl 3

  ClapNotePortsRescanAll* = 1'u32 shl 0
  ClapNotePortsRescanNames* = 1'u32 shl 1

  ClapParamRescanValues* = 1'u32 shl 0
  ClapParamRescanText* = 1'u32 shl 1
  ClapParamRescanInfo* = 1'u32 shl 2
  ClapParamRescanAll* = 1'u32 shl 3
  ClapParamRescanKnown* = ClapParamRescanValues or ClapParamRescanText or
    ClapParamRescanInfo or ClapParamRescanAll
  ClapParamClearAll* = 1'u32 shl 0
  ClapParamClearAutomations* = 1'u32 shl 1
  ClapParamClearModulations* = 1'u32 shl 2
  ClapParamClearKnown* = ClapParamClearAll or ClapParamClearAutomations or
    ClapParamClearModulations

  ClapRenderRealtime* = 0'i32
  ClapRenderOffline* = 1'i32

  ClapLogDebug* = 0'i32
  ClapLogInfo* = 1'i32
  ClapLogWarning* = 2'i32
  ClapLogError* = 3'i32
  ClapLogFatal* = 4'i32
  ClapLogHostMisbehaving* = 5'i32
  ClapLogPluginMisbehaving* = 6'i32

  ClapPosixFdRead* = 1'u32 shl 0
  ClapPosixFdWrite* = 1'u32 shl 1
  ClapPosixFdError* = 1'u32 shl 2

type
  ClapId* = uint32
  ClapBeatTime* = int64
  ClapSecTime* = int64
  ClapProcessStatus* = int32
  ClapLogSeverity* = int32
  ClapNoteExpression* = int32
  ClapPluginRenderMode* = int32

  ClapVersion* {.bycopy.} = object
    major*: uint32
    minor*: uint32
    revision*: uint32

  ClapEventHeader* {.bycopy.} = object
    size*: uint32
    time*: uint32
    spaceId*: uint16
    `type`*: uint16
    flags*: uint32

  ClapEventNote* {.bycopy.} = object
    header*: ClapEventHeader
    noteId*: int32
    portIndex*: int16
    channel*: int16
    key*: int16
    velocity*: cdouble

  ClapEventNoteExpression* {.bycopy.} = object
    header*: ClapEventHeader
    expressionId*: ClapNoteExpression
    noteId*: int32
    portIndex*: int16
    channel*: int16
    key*: int16
    value*: cdouble

  ClapEventParamValue* {.bycopy.} = object
    header*: ClapEventHeader
    paramId*: ClapId
    cookie*: pointer
    noteId*: int32
    portIndex*: int16
    channel*: int16
    key*: int16
    value*: cdouble

  ClapEventParamMod* {.bycopy.} = object
    header*: ClapEventHeader
    paramId*: ClapId
    cookie*: pointer
    noteId*: int32
    portIndex*: int16
    channel*: int16
    key*: int16
    amount*: cdouble

  ClapEventParamGesture* {.bycopy.} = object
    header*: ClapEventHeader
    paramId*: ClapId

  ClapEventTransport* {.bycopy.} = object
    header*: ClapEventHeader
    flags*: uint32
    songPosBeats*: ClapBeatTime
    songPosSeconds*: ClapSecTime
    tempo*: cdouble
    tempoInc*: cdouble
    loopStartBeats*: ClapBeatTime
    loopEndBeats*: ClapBeatTime
    loopStartSeconds*: ClapSecTime
    loopEndSeconds*: ClapSecTime
    barStart*: ClapBeatTime
    barNumber*: int32
    tsigNum*: uint16
    tsigDenom*: uint16

  ClapEventMidi* {.bycopy.} = object
    header*: ClapEventHeader
    portIndex*: uint16
    data*: array[3, uint8]

  ClapEventMidiSysex* {.bycopy.} = object
    header*: ClapEventHeader
    portIndex*: uint16
    buffer*: ptr uint8
    size*: uint32

  ClapEventMidi2* {.bycopy.} = object
    header*: ClapEventHeader
    portIndex*: uint16
    data*: array[4, uint32]

  ClapInputEventsSizeProc* = proc(list: ptr ClapInputEvents): uint32 {.
    cdecl, gcsafe, raises: [].}
  ClapInputEventsGetProc* = proc(list: ptr ClapInputEvents;
                                 index: uint32): ptr ClapEventHeader {.
    cdecl, gcsafe, raises: [].}
  ClapInputEvents* {.bycopy.} = object
    ctx*: pointer
    size*: ClapInputEventsSizeProc
    get*: ClapInputEventsGetProc

  ClapOutputEventsTryPushProc* = proc(list: ptr ClapOutputEvents;
                                      event: ptr ClapEventHeader): bool {.
    cdecl, gcsafe, raises: [].}
  ClapOutputEvents* {.bycopy.} = object
    ctx*: pointer
    tryPush*: ClapOutputEventsTryPushProc

  ClapIStreamReadProc* = proc(stream: ptr ClapIStream; buffer: pointer;
    size: uint64): int64 {.cdecl, gcsafe, raises: [].}
  ClapIStream* {.bycopy.} = object
    ctx*: pointer
    read*: ClapIStreamReadProc
  ClapOStreamWriteProc* = proc(stream: ptr ClapOStream; buffer: pointer;
    size: uint64): int64 {.cdecl, gcsafe, raises: [].}
  ClapOStream* {.bycopy.} = object
    ctx*: pointer
    write*: ClapOStreamWriteProc

  ClapAudioBuffer* {.bycopy.} = object
    data32*: ptr ptr cfloat
    data64*: ptr ptr cdouble
    channelCount*: uint32
    latency*: uint32
    constantMask*: uint64

  ClapProcess* {.bycopy.} = object
    steadyTime*: int64
    framesCount*: uint32
    transport*: ptr ClapEventTransport
    audioInputs*: ptr ClapAudioBuffer
    audioOutputs*: ptr ClapAudioBuffer
    audioInputsCount*: uint32
    audioOutputsCount*: uint32
    inEvents*: ptr ClapInputEvents
    outEvents*: ptr ClapOutputEvents

  ClapHostGetExtensionProc* = proc(host: ptr ClapHost;
                                   extensionId: cstring): pointer {.
    cdecl, gcsafe, raises: [].}
  ClapHostRequestProc* = proc(host: ptr ClapHost) {.
    cdecl, gcsafe, raises: [].}
  ClapHostLogProc* = proc(host: ptr ClapHost; severity: ClapLogSeverity;
                           message: cstring) {.cdecl, gcsafe, raises: [].}
  ClapHostThreadCheckProc* = proc(host: ptr ClapHost): bool {.
    cdecl, gcsafe, raises: [].}
  ClapHost* {.bycopy.} = object
    clapVersion*: ClapVersion
    hostData*: pointer
    name*: cstring
    vendor*: cstring
    url*: cstring
    version*: cstring
    getExtension*: ClapHostGetExtensionProc
    requestRestart*: ClapHostRequestProc
    requestProcess*: ClapHostRequestProc
    requestCallback*: ClapHostRequestProc

  ClapHostLog* {.bycopy.} = object
    log*: ClapHostLogProc

  ClapHostThreadCheck* {.bycopy.} = object
    isMainThread*: ClapHostThreadCheckProc
    isAudioThread*: ClapHostThreadCheckProc

  ClapHostGuiResizeHintsChangedProc* = proc(host: ptr ClapHost) {.cdecl, gcsafe, raises: [].}
  ClapHostGuiRequestResizeProc* = proc(host: ptr ClapHost; width, height: uint32): bool {.cdecl, gcsafe, raises: [].}
  ClapHostGuiRequestShowProc* = proc(host: ptr ClapHost): bool {.cdecl, gcsafe, raises: [].}
  ClapHostGuiRequestHideProc* = proc(host: ptr ClapHost): bool {.cdecl, gcsafe, raises: [].}
  ClapHostGuiClosedProc* = proc(host: ptr ClapHost; wasDestroyed: bool) {.cdecl, gcsafe, raises: [].}
  ClapHostGui* {.bycopy.} = object
    resizeHintsChanged*: ClapHostGuiResizeHintsChangedProc
    requestResize*: ClapHostGuiRequestResizeProc
    requestShow*: ClapHostGuiRequestShowProc
    requestHide*: ClapHostGuiRequestHideProc
    closed*: ClapHostGuiClosedProc

  ClapHostStateMarkDirtyProc* = proc(host: ptr ClapHost) {.cdecl, gcsafe, raises: [].}
  ClapHostState* {.bycopy.} = object
    markDirty*: ClapHostStateMarkDirtyProc

  ClapPluginLatencyGetProc* = proc(plugin: ptr ClapPlugin): uint32 {.cdecl, gcsafe, raises: [].}
  ClapPluginLatency* {.bycopy.} = object
    get*: ClapPluginLatencyGetProc
  ClapHostLatencyChangedProc* = proc(host: ptr ClapHost) {.cdecl, gcsafe, raises: [].}
  ClapHostLatency* {.bycopy.} = object
    changed*: ClapHostLatencyChangedProc

  ClapPluginTimerOnTimerProc* = proc(plugin: ptr ClapPlugin; timerId: ClapId) {.cdecl, gcsafe, raises: [].}
  ClapPluginTimerSupport* {.bycopy.} = object
    onTimer*: ClapPluginTimerOnTimerProc
  ClapHostTimerRegisterProc* = proc(host: ptr ClapHost; periodMs: uint32; timerId: ptr ClapId): bool {.cdecl, gcsafe, raises: [].}
  ClapHostTimerUnregisterProc* = proc(host: ptr ClapHost; timerId: ClapId): bool {.cdecl, gcsafe, raises: [].}
  ClapHostTimerSupport* {.bycopy.} = object
    registerTimer*: ClapHostTimerRegisterProc
    unregisterTimer*: ClapHostTimerUnregisterProc

  ClapPluginPosixFdOnFdProc* = proc(plugin: ptr ClapPlugin; fd: cint; flags: uint32) {.cdecl, gcsafe, raises: [].}
  ClapPluginPosixFdSupport* {.bycopy.} = object
    onFd*: ClapPluginPosixFdOnFdProc
  ClapHostPosixFdRegisterProc* = proc(host: ptr ClapHost; fd: cint; flags: uint32): bool {.cdecl, gcsafe, raises: [].}
  ClapHostPosixFdModifyProc* = proc(host: ptr ClapHost; fd: cint; flags: uint32): bool {.cdecl, gcsafe, raises: [].}
  ClapHostPosixFdUnregisterProc* = proc(host: ptr ClapHost; fd: cint): bool {.cdecl, gcsafe, raises: [].}
  ClapHostPosixFdSupport* {.bycopy.} = object
    registerFd*: ClapHostPosixFdRegisterProc
    modifyFd*: ClapHostPosixFdModifyProc
    unregisterFd*: ClapHostPosixFdUnregisterProc

  ClapParamInfo* {.bycopy.} = object
    id*: ClapId
    flags*: uint32
    cookie*: pointer
    name*: array[ClapNameSize, char]
    module*: array[ClapPathSize, char]
    minValue*: cdouble
    maxValue*: cdouble
    defaultValue*: cdouble

  ClapPluginParamsCountProc* = proc(plugin: ptr ClapPlugin): uint32 {.cdecl, gcsafe, raises: [].}
  ClapPluginParamsGetInfoProc* = proc(plugin: ptr ClapPlugin; index: uint32;
      info: ptr ClapParamInfo): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginParamsGetValueProc* = proc(plugin: ptr ClapPlugin; paramId: ClapId;
      value: ptr cdouble): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginParamsValueToTextProc* = proc(plugin: ptr ClapPlugin; paramId: ClapId;
      value: cdouble; text: cstring; capacity: uint32): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginParamsTextToValueProc* = proc(plugin: ptr ClapPlugin; paramId: ClapId;
      text: cstring; value: ptr cdouble): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginParamsFlushProc* = proc(plugin: ptr ClapPlugin; input: ptr ClapInputEvents;
      output: ptr ClapOutputEvents) {.cdecl, gcsafe, raises: [].}
  ClapPluginParams* {.bycopy.} = object
    count*: ClapPluginParamsCountProc
    getInfo*: ClapPluginParamsGetInfoProc
    getValue*: ClapPluginParamsGetValueProc
    valueToText*: ClapPluginParamsValueToTextProc
    textToValue*: ClapPluginParamsTextToValueProc
    flush*: ClapPluginParamsFlushProc

  ClapHostParamsRescanProc* = proc(host: ptr ClapHost; flags: uint32) {.cdecl, gcsafe, raises: [].}
  ClapHostParamsClearProc* = proc(host: ptr ClapHost; paramId: ClapId; flags: uint32) {.cdecl, gcsafe, raises: [].}
  ClapHostParamsRequestFlushProc* = proc(host: ptr ClapHost) {.cdecl, gcsafe, raises: [].}
  ClapHostParams* {.bycopy.} = object
    rescan*: ClapHostParamsRescanProc
    clear*: ClapHostParamsClearProc
    requestFlush*: ClapHostParamsRequestFlushProc

  ClapPluginStateSaveProc* = proc(plugin: ptr ClapPlugin; stream: ptr ClapOStream): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginStateLoadProc* = proc(plugin: ptr ClapPlugin; stream: ptr ClapIStream): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginState* {.bycopy.} = object
    save*: ClapPluginStateSaveProc
    load*: ClapPluginStateLoadProc

  ClapPluginDescriptor* {.bycopy.} = object
    clapVersion*: ClapVersion
    id*: cstring
    name*: cstring
    vendor*: cstring
    url*: cstring
    manualUrl*: cstring
    supportUrl*: cstring
    version*: cstring
    description*: cstring
    features*: ptr cstring

  ClapPluginInitProc* = proc(plugin: ptr ClapPlugin): bool {.
    cdecl, gcsafe, raises: [].}
  ClapPluginDestroyProc* = proc(plugin: ptr ClapPlugin) {.
    cdecl, gcsafe, raises: [].}
  ClapPluginActivateProc* = proc(plugin: ptr ClapPlugin; sampleRate: cdouble;
                                 minFramesCount, maxFramesCount: uint32): bool {.
    cdecl, gcsafe, raises: [].}
  ClapPluginDeactivateProc* = proc(plugin: ptr ClapPlugin) {.
    cdecl, gcsafe, raises: [].}
  ClapPluginStartProcessingProc* = proc(plugin: ptr ClapPlugin): bool {.
    cdecl, gcsafe, raises: [].}
  ClapPluginStopProcessingProc* = proc(plugin: ptr ClapPlugin) {.
    cdecl, gcsafe, raises: [].}
  ClapPluginResetProc* = proc(plugin: ptr ClapPlugin) {.
    cdecl, gcsafe, raises: [].}
  ClapPluginProcessProc* = proc(plugin: ptr ClapPlugin;
                                process: ptr ClapProcess): ClapProcessStatus {.
    cdecl, gcsafe, raises: [].}
  ClapPluginGetExtensionProc* = proc(plugin: ptr ClapPlugin;
                                     extensionId: cstring): pointer {.
    cdecl, gcsafe, raises: [].}
  ClapPluginOnMainThreadProc* = proc(plugin: ptr ClapPlugin) {.
    cdecl, gcsafe, raises: [].}
  ClapPlugin* {.bycopy.} = object
    desc*: ptr ClapPluginDescriptor
    pluginData*: pointer
    init*: ClapPluginInitProc
    destroy*: ClapPluginDestroyProc
    activate*: ClapPluginActivateProc
    deactivate*: ClapPluginDeactivateProc
    startProcessing*: ClapPluginStartProcessingProc
    stopProcessing*: ClapPluginStopProcessingProc
    reset*: ClapPluginResetProc
    process*: ClapPluginProcessProc
    getExtension*: ClapPluginGetExtensionProc
    onMainThread*: ClapPluginOnMainThreadProc

  ClapGuiResizeHints* {.bycopy.} = object
    canResizeHorizontally*: bool
    canResizeVertically*: bool
    preserveAspectRatio*: bool
    aspectRatioWidth*: uint32
    aspectRatioHeight*: uint32

  ClapWindow* {.bycopy.} = object
    api*: cstring
    x11*: culong

  ClapPluginGuiIsApiSupportedProc* = proc(plugin: ptr ClapPlugin; api: cstring;
      isFloating: bool): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiGetPreferredApiProc* = proc(plugin: ptr ClapPlugin;
      api: ptr cstring; isFloating: ptr bool): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiCreateProc* = proc(plugin: ptr ClapPlugin; api: cstring;
      isFloating: bool): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiDestroyProc* = proc(plugin: ptr ClapPlugin) {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiSetScaleProc* = proc(plugin: ptr ClapPlugin; scale: cdouble): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiGetSizeProc* = proc(plugin: ptr ClapPlugin; width, height: ptr uint32): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiCanResizeProc* = proc(plugin: ptr ClapPlugin): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiGetResizeHintsProc* = proc(plugin: ptr ClapPlugin; hints: ptr ClapGuiResizeHints): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiAdjustSizeProc* = proc(plugin: ptr ClapPlugin; width, height: ptr uint32): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiSetSizeProc* = proc(plugin: ptr ClapPlugin; width, height: uint32): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiSetParentProc* = proc(plugin: ptr ClapPlugin; window: ptr ClapWindow): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiSetTransientProc* = proc(plugin: ptr ClapPlugin; window: ptr ClapWindow): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiSuggestTitleProc* = proc(plugin: ptr ClapPlugin; title: cstring) {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiShowProc* = proc(plugin: ptr ClapPlugin): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGuiHideProc* = proc(plugin: ptr ClapPlugin): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginGui* {.bycopy.} = object
    isApiSupported*: ClapPluginGuiIsApiSupportedProc
    getPreferredApi*: ClapPluginGuiGetPreferredApiProc
    create*: ClapPluginGuiCreateProc
    destroy*: ClapPluginGuiDestroyProc
    setScale*: ClapPluginGuiSetScaleProc
    getSize*: ClapPluginGuiGetSizeProc
    canResize*: ClapPluginGuiCanResizeProc
    getResizeHints*: ClapPluginGuiGetResizeHintsProc
    adjustSize*: ClapPluginGuiAdjustSizeProc
    setSize*: ClapPluginGuiSetSizeProc
    setParent*: ClapPluginGuiSetParentProc
    setTransient*: ClapPluginGuiSetTransientProc
    suggestTitle*: ClapPluginGuiSuggestTitleProc
    show*: ClapPluginGuiShowProc
    hide*: ClapPluginGuiHideProc

  ClapPluginEntryInitProc* = proc(pluginPath: cstring): bool {.
    cdecl, gcsafe, raises: [].}
  ClapPluginEntryDeinitProc* = proc() {.cdecl, gcsafe, raises: [].}
  ClapPluginEntryGetFactoryProc* = proc(factoryId: cstring): pointer {.
    cdecl, gcsafe, raises: [].}
  ClapPluginEntry* {.bycopy.} = object
    clapVersion*: ClapVersion
    init*: ClapPluginEntryInitProc
    deinit*: ClapPluginEntryDeinitProc
    getFactory*: ClapPluginEntryGetFactoryProc

  ClapPluginFactoryGetCountProc* = proc(factory: ptr ClapPluginFactory): uint32 {.
    cdecl, gcsafe, raises: [].}
  ClapPluginFactoryGetDescriptorProc* = proc(factory: ptr ClapPluginFactory;
      index: uint32): ptr ClapPluginDescriptor {.cdecl, gcsafe, raises: [].}
  ClapPluginFactoryCreateProc* = proc(factory: ptr ClapPluginFactory;
      host: ptr ClapHost; pluginId: cstring): ptr ClapPlugin {.
    cdecl, gcsafe, raises: [].}
  ClapPluginFactory* {.bycopy.} = object
    getPluginCount*: ClapPluginFactoryGetCountProc
    getPluginDescriptor*: ClapPluginFactoryGetDescriptorProc
    createPlugin*: ClapPluginFactoryCreateProc

  ClapAudioPortInfo* {.bycopy.} = object
    id*: ClapId
    name*: array[ClapNameSize, char]
    flags*: uint32
    channelCount*: uint32
    portType*: cstring
    inPlacePair*: ClapId

  ClapPluginAudioPortsCountProc* = proc(plugin: ptr ClapPlugin;
                                        isInput: bool): uint32 {.
    cdecl, gcsafe, raises: [].}
  ClapPluginAudioPortsGetProc* = proc(plugin: ptr ClapPlugin; index: uint32;
      isInput: bool; info: ptr ClapAudioPortInfo): bool {.
    cdecl, gcsafe, raises: [].}
  ClapPluginAudioPorts* {.bycopy.} = object
    count*: ClapPluginAudioPortsCountProc
    get*: ClapPluginAudioPortsGetProc

  ClapHostAudioPortsIsRescanSupportedProc* = proc(host: ptr ClapHost;
                                                   flag: uint32): bool {.
    cdecl, gcsafe, raises: [].}
  ClapHostAudioPortsRescanProc* = proc(host: ptr ClapHost; flags: uint32) {.
    cdecl, gcsafe, raises: [].}
  ClapHostAudioPorts* {.bycopy.} = object
    isRescanFlagSupported*: ClapHostAudioPortsIsRescanSupportedProc
    rescan*: ClapHostAudioPortsRescanProc

  ClapNotePortInfo* {.bycopy.} = object
    id*: ClapId
    supportedDialects*: uint32
    preferredDialect*: uint32
    name*: array[ClapNameSize, char]

  ClapPluginNotePortsCountProc* = proc(plugin: ptr ClapPlugin;
                                       isInput: bool): uint32 {.
    cdecl, gcsafe, raises: [].}
  ClapPluginNotePortsGetProc* = proc(plugin: ptr ClapPlugin; index: uint32;
      isInput: bool; info: ptr ClapNotePortInfo): bool {.
    cdecl, gcsafe, raises: [].}
  ClapPluginNotePorts* {.bycopy.} = object
    count*: ClapPluginNotePortsCountProc
    get*: ClapPluginNotePortsGetProc

  ClapPluginRenderHasHardRealtimeRequirementProc* = proc(
      plugin: ptr ClapPlugin): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginRenderSetProc* = proc(plugin: ptr ClapPlugin;
      mode: ClapPluginRenderMode): bool {.cdecl, gcsafe, raises: [].}
  ClapPluginRender* {.bycopy.} = object
    hasHardRealtimeRequirement*: ClapPluginRenderHasHardRealtimeRequirementProc
    set*: ClapPluginRenderSetProc

  ClapHostNotePortsSupportedDialectsProc* = proc(host: ptr ClapHost): uint32 {.
    cdecl, gcsafe, raises: [].}
  ClapHostNotePortsRescanProc* = proc(host: ptr ClapHost; flags: uint32) {.
    cdecl, gcsafe, raises: [].}
  ClapHostNotePorts* {.bycopy.} = object
    supportedDialects*: ClapHostNotePortsSupportedDialectsProc
    rescan*: ClapHostNotePortsRescanProc

const ClapVersionCurrent* = ClapVersion(
  major: ClapSdkVersionMajor,
  minor: ClapSdkVersionMinor,
  revision: ClapSdkVersionRevision,
)

proc isCompatible*(version: ClapVersion): bool {.inline, gcsafe, raises: [].} =
  ## Mirrors the stable helper in clap/version.h.
  version.major >= 1'u32
