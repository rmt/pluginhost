## Minimal policy-free VST3 ABI declarations for the reviewed V1A boundary.
##
## The complete generated C declaration is vendored under vendor/vst3. These
## declarations mirror only the module/factory/catalog interfaces used here;
## later gates add their interfaces beside their tests.

const
  Vst3GeneratedHeader* = "vendor/vst3/vst3_c_api.h"
  Vst3AudioEffectClass* = "Audio Module Class"
  Vst3SdkVersion* = "VST 3.8.1"
  Vst3TuidBytes* = 16
  Vst3FactoryVendorBytes* = 64
  Vst3FactoryUrlBytes* = 256
  Vst3FactoryEmailBytes* = 128
  Vst3CategoryBytes* = 32
  Vst3ClassNameBytes* = 64
  Vst3SubCategoriesBytes* = 128

  Vst3ResultOk* = 0'i32
  Vst3ResultFalse* = 1'i32
  Vst3NoInterface* = -1'i32
  Vst3InvalidArgument* = 2'i32
  Vst3NotImplemented* = 3'i32
  Vst3ResultNoInterface* = Vst3NoInterface
  Vst3FUnknownIid* = "0000000000000000C000000000000046"
  Vst3FactoryIid* = "7A4D811C52114A1FAED9D2EE0B43BF9F"
  Vst3Factory2Iid* = "0007B650F24B4C0BA464EDB9F00B2ABB"
  Vst3Factory3Iid* = "4555A2ABC1234E579B12291036878931"
  Vst3PlugViewIid* = "5BC32507D06049EAA6151B522B755B29"
  Vst3PlugFrameIid* = "367FAF01AFA946938D4DA2A0ED0882A3"
  Vst3PlugViewContentScaleSupportIid* =
    "65ED96908AC445258AADEF7A72EA703F"
  Vst3PlatformTypeX11EmbedWindowID* = "X11EmbedWindowID"

  Vst3MediaAudio* = 0'i32
  Vst3MediaEvent* = 1'i32
  Vst3DirectionInput* = 0'i32
  Vst3DirectionOutput* = 1'i32
  Vst3BusTypeMain* = 0'i32
  Vst3BusTypeAux* = 1'i32
  Vst3BusFlagDefaultActive* = 1'u32 shl 0
  Vst3BusFlagControlVoltage* = 1'u32 shl 1
  Vst3IoModeSimple* = 0'i32
  Vst3IoModeAdvanced* = 1'i32
  Vst3MaxParameterCount* = 4_096
  Vst3MaxBusCount* = 1_024
  Vst3MaxBusChannels* = 4_096
  Vst3MaxMetadataBytes* = 16 * 1024 * 1024
  Vst3RestartReloadComponent* = 1'i32 shl 0
  Vst3RestartIoChanged* = 1'i32 shl 1
  Vst3RestartParamValuesChanged* = 1'i32 shl 2
  Vst3RestartLatencyChanged* = 1'i32 shl 3
  Vst3RestartParamTitlesChanged* = 1'i32 shl 4
  Vst3RestartMidiCCChanged* = 1'i32 shl 5
  Vst3RestartNoteExpressionChanged* = 1'i32 shl 6
  Vst3RestartIoTitlesChanged* = 1'i32 shl 7
  Vst3RestartPrefetchChanged* = 1'i32 shl 8
  Vst3RestartRoutingChanged* = 1'i32 shl 9
  Vst3RestartKeyswitchChanged* = 1'i32 shl 10
  Vst3RestartAllKnown* = (1'i32 shl 11) - 1
  Vst3ProcessModeRealtime* = 0'i32
  Vst3ProcessModePrefetch* = 1'i32
  Vst3ProcessModeOffline* = 2'i32
  Vst3SymbolicSample32* = 0'i32
  Vst3SymbolicSample64* = 1'i32
  ## VST3 kContTimeValid is the only asserted state bit for the host's
  ## free-running sample clock. No musical/system/tempo fields are asserted.
  Vst3ProcessContextStateContinuousTimeValid* = 1'u32 shl 17
  Vst3ProcessContextRequirementNeedContinousTimeSamples* = 1'u32 shl 1
  Vst3ProcessContextRequirementNeedSystemTime* = 1'u32 shl 0
  Vst3ProcessContextRequirementNeedProjectTimeMusic* = 1'u32 shl 2
  Vst3ProcessContextRequirementNeedBarPositionMusic* = 1'u32 shl 3
  Vst3ProcessContextRequirementNeedCycleMusic* = 1'u32 shl 4
  Vst3ProcessContextRequirementNeedSamplesToNextClock* = 1'u32 shl 5
  Vst3ProcessContextRequirementNeedTempo* = 1'u32 shl 6
  Vst3ProcessContextRequirementNeedTimeSignature* = 1'u32 shl 7
  Vst3ProcessContextRequirementNeedChord* = 1'u32 shl 8
  Vst3ProcessContextRequirementNeedFrameRate* = 1'u32 shl 9
  Vst3ProcessContextRequirementNeedTransportState* = 1'u32 shl 10
  Vst3SpeakerArrEmpty* = 0'u64
  Vst3SpeakerArrMono* = 1'u64 shl 19
  Vst3SpeakerArrStereo* = (1'u64 shl 0) or (1'u64 shl 1)
  Vst3AudioProcessorContextRequirementsIid* =
    "2A654303EF764E3D95B5FE83730EF6D0"
  Vst3ParameterChangesIid* = "A47796630BB64A56B44384A8466FEB9D"
  Vst3ParamValueQueueIid* = "01263A18ED074F6F98C9D3564686F9BA"
  Vst3EventListIid* = "3A2C4214346349FEB2C4F397B9695A44"
  Vst3MidiMappingIid* = "DF0FF9F749B74669B63AB7327ADBF5E5"
  Vst3EventFlagIsLive* = 1'u16 shl 0
  Vst3EventTypeNoteOn* = 0'u16
  Vst3EventTypeNoteOff* = 1'u16
  Vst3EventTypeData* = 2'u16
  Vst3EventTypePolyPressure* = 3'u16
  Vst3EventTypeLegacyMidiCcOut* = 0xFFFF'u16
  Vst3DataTypeMidiSysEx* = 0'u32
  Vst3NoteIdNone* = -1'i32
  Vst3MidiControllerAftertouch* = 128'i32
  Vst3MidiControllerPitchBend* = 129'i32
  Vst3MidiControllerProgramChange* = 130'i32
  Vst3MidiControllerPolyPressure* = 131'i32
  Vst3MidiControllerQuarterFrame* = 132'i32
  Vst3MidiControllerSongSelect* = 133'i32
  Vst3MidiControllerSongPointer* = 134'i32
  Vst3MidiControllerCableSelect* = 135'i32
  Vst3MidiControllerTuneRequest* = 136'i32
  Vst3MidiControllerClockStart* = 137'i32
  Vst3MidiControllerClockContinue* = 138'i32
  Vst3MidiControllerClockStop* = 139'i32
  Vst3MidiControllerActiveSensing* = 140'i32
  Vst3MidiControllerCount* = 132'i32
  Vst3MidiChannelCount* = 16'i32
type
  Vst3Tuid* = array[Vst3TuidBytes, uint8]
  Vst3FactoryInfo* {.bycopy.} = object
    vendor*: array[Vst3FactoryVendorBytes, char]
    url*: array[Vst3FactoryUrlBytes, char]
    email*: array[Vst3FactoryEmailBytes, char]
    flags*: int32

  Vst3ClassInfo* {.bycopy.} = object
    cid*: Vst3Tuid
    cardinality*: int32
    category*: array[Vst3CategoryBytes, char]
    name*: array[Vst3ClassNameBytes, char]

  Vst3ClassInfo2* {.bycopy.} = object
    cid*: Vst3Tuid
    cardinality*: int32
    category*: array[Vst3CategoryBytes, char]
    name*: array[Vst3ClassNameBytes, char]
    classFlags*: uint32
    subCategories*: array[Vst3SubCategoriesBytes, char]
    vendor*: array[Vst3FactoryVendorBytes, char]
    version*: array[Vst3ClassNameBytes, char]
    sdkVersion*: array[Vst3ClassNameBytes, char]

  Vst3ClassInfoW* {.bycopy.} = object
    cid*: Vst3Tuid
    cardinality*: int32
    category*: array[Vst3CategoryBytes, char]
    name*: array[Vst3ClassNameBytes, uint16]
    classFlags*: uint32
    subCategories*: array[Vst3SubCategoriesBytes, char]
    vendor*: array[Vst3FactoryVendorBytes, uint16]
    version*: array[Vst3ClassNameBytes, uint16]
    sdkVersion*: array[Vst3ClassNameBytes, uint16]


  Vst3FUnknownVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
  Vst3FUnknown* {.bycopy.} = object
    lpVtbl*: ptr Vst3FUnknownVtbl

  Vst3PluginFactoryVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getFactoryInfo*: proc(thisInterface: pointer;
                          info: ptr Vst3FactoryInfo): int32 {.
      cdecl, raises: [].}
    countClasses*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    getClassInfo*: proc(thisInterface: pointer; index: int32;
                        info: ptr Vst3ClassInfo): int32 {.
      cdecl, raises: [].}
    createInstance*: proc(thisInterface: pointer; cid: cstring;
                          iid: cstring; obj: ptr pointer): int32 {.
      cdecl, raises: [].}

  Vst3PluginFactory2Vtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getFactoryInfo*: proc(thisInterface: pointer;
                          info: ptr Vst3FactoryInfo): int32 {.
      cdecl, raises: [].}
    countClasses*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    getClassInfo*: proc(thisInterface: pointer; index: int32;
                        info: ptr Vst3ClassInfo): int32 {.
      cdecl, raises: [].}
    createInstance*: proc(thisInterface: pointer; cid: cstring;
                          iid: cstring; obj: ptr pointer): int32 {.
      cdecl, raises: [].}
    getClassInfo2*: proc(thisInterface: pointer; index: int32;
                         info: ptr Vst3ClassInfo2): int32 {.
      cdecl, raises: [].}

  Vst3PluginFactory* {.bycopy.} = object
    lpVtbl*: ptr Vst3PluginFactoryVtbl

  Vst3PluginFactory2* {.bycopy.} = object
    lpVtbl*: ptr Vst3PluginFactory2Vtbl

  Vst3PluginFactory3Vtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getFactoryInfo*: proc(thisInterface: pointer;
                          info: ptr Vst3FactoryInfo): int32 {.
      cdecl, raises: [].}
    countClasses*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    getClassInfo*: proc(thisInterface: pointer; index: int32;
                        info: ptr Vst3ClassInfo): int32 {.
      cdecl, raises: [].}
    createInstance*: proc(thisInterface: pointer; cid: cstring;
                          iid: cstring; obj: ptr pointer): int32 {.
      cdecl, raises: [].}
    getClassInfo2*: proc(thisInterface: pointer; index: int32;
                         info: ptr Vst3ClassInfo2): int32 {.
      cdecl, raises: [].}
    getClassInfoUnicode*: proc(thisInterface: pointer; index: int32;
                               info: ptr Vst3ClassInfoW): int32 {.
      cdecl, raises: [].}
    setHostContext*: proc(thisInterface: pointer; context: pointer): int32 {.
      cdecl, raises: [].}

  Vst3PluginFactory3* {.bycopy.} = object
    lpVtbl*: ptr Vst3PluginFactory3Vtbl

  Vst3ModuleEntry* = proc(sharedLibraryHandle: pointer): bool {.
    cdecl, raises: [].}
  Vst3ModuleExit* = proc(): bool {.cdecl, raises: [].}
  Vst3GetPluginFactory* = proc(): ptr Vst3PluginFactory {.
    cdecl, raises: [].}

  Vst3TBool* = uint8
  Vst3TChar* = uint16
  Vst3VstString128* = array[128, Vst3TChar]
  Vst3ParamID* = uint32
  Vst3ParamValue* = float64
  Vst3CtrlNumber* = int16
  Vst3MidiChannel* = int16
  Vst3MidiGroup* = uint8
  Vst3BusIndex* = int32

type
  Vst3BusInfo* {.bycopy.} = object
    mediaType*: Vst3MediaType
    direction*: Vst3BusDirection
    channelCount*: int32
    name*: Vst3VstString128
    busType*: int32
    flags*: uint32

  Vst3ParameterInfo* {.bycopy.} = object
    id*: Vst3ParamID
    title*: Vst3VstString128
    shortTitle*: Vst3VstString128
    units*: Vst3VstString128
    stepCount*: int32
    defaultNormalizedValue*: Vst3ParamValue
    unitId*: int32
    flags*: int32

  Vst3MediaType* = int32
  Vst3BusDirection* = int32
  Vst3IoMode* = int32
  Vst3FileDescriptor* = int32
  Vst3TimerInterval* = uint64

  Vst3ComponentVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    initialize*: proc(thisInterface: pointer; context: pointer): int32 {.
      cdecl, raises: [].}
    terminate*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    getControllerClassId*: proc(thisInterface: pointer; classId: ptr Vst3Tuid): int32 {.
      cdecl, raises: [].}
    setIoMode*: proc(thisInterface: pointer; mode: Vst3IoMode): int32 {.
      cdecl, raises: [].}
    getBusCount*: proc(thisInterface: pointer; mediaType: Vst3MediaType;
                       direction: Vst3BusDirection): int32 {.cdecl, raises: [].}
    getBusInfo*: proc(thisInterface: pointer; mediaType: Vst3MediaType;
                      direction: Vst3BusDirection; index: int32;
                      info: pointer): int32 {.cdecl, raises: [].}
    getRoutingInfo*: proc(thisInterface: pointer; input, output: pointer): int32 {.
      cdecl, raises: [].}
    activateBus*: proc(thisInterface: pointer; mediaType: Vst3MediaType;
                       direction: Vst3BusDirection; index: int32;
                       state: Vst3TBool): int32 {.cdecl, raises: [].}
    setActive*: proc(thisInterface: pointer; state: Vst3TBool): int32 {.
      cdecl, raises: [].}
    setState*: proc(thisInterface: pointer; state: pointer): int32 {.
      cdecl, raises: [].}
    getState*: proc(thisInterface: pointer; state: pointer): int32 {.
      cdecl, raises: [].}
  Vst3Component* {.bycopy.} = object
    lpVtbl*: ptr Vst3ComponentVtbl

  Vst3AudioProcessorVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    setBusArrangements*: proc(thisInterface: pointer; inputs: pointer;
                              numIns: int32; outputs: pointer;
                              numOuts: int32): int32 {.cdecl, raises: [].}
    getBusArrangement*: proc(thisInterface: pointer; direction: Vst3BusDirection;
                             index: int32; arrangement: ptr uint64): int32 {.
      cdecl, raises: [].}
    canProcessSampleSize*: proc(thisInterface: pointer;
                                symbolicSampleSize: int32): int32 {.
      cdecl, raises: [].}
    getLatencySamples*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    setupProcessing*: proc(thisInterface: pointer; setup: pointer): int32 {.
      cdecl, raises: [].}
    setProcessing*: proc(thisInterface: pointer; state: Vst3TBool): int32 {.
      cdecl, raises: [].}
    process*: proc(thisInterface: pointer; data: pointer): int32 {.
      cdecl, gcsafe, raises: [].}
    getTailSamples*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
  Vst3AudioProcessor* {.bycopy.} = object
    lpVtbl*: ptr Vst3AudioProcessorVtbl

  Vst3EditControllerVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    initialize*: proc(thisInterface: pointer; context: pointer): int32 {.
      cdecl, raises: [].}
    terminate*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    setComponentState*: proc(thisInterface: pointer; state: pointer): int32 {.
      cdecl, raises: [].}
    setState*: proc(thisInterface: pointer; state: pointer): int32 {.
      cdecl, raises: [].}
    getState*: proc(thisInterface: pointer; state: pointer): int32 {.
      cdecl, raises: [].}
    getParameterCount*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    getParameterInfo*: proc(thisInterface: pointer; index: int32;
                            info: pointer): int32 {.cdecl, raises: [].}
    getParamStringByValue*: proc(thisInterface: pointer; id: Vst3ParamID;
                                 value: Vst3ParamValue; text: ptr Vst3VstString128): int32 {.
      cdecl, raises: [].}
    getParamValueByString*: proc(thisInterface: pointer; id: Vst3ParamID;
                                 text: ptr Vst3TChar; value: ptr Vst3ParamValue): int32 {.
      cdecl, raises: [].}
    normalizedParamToPlain*: proc(thisInterface: pointer; id: Vst3ParamID;
                                   value: Vst3ParamValue): Vst3ParamValue {.
      cdecl, raises: [].}
    plainParamToNormalized*: proc(thisInterface: pointer; id: Vst3ParamID;
                                  value: Vst3ParamValue): Vst3ParamValue {.
      cdecl, raises: [].}
    getParamNormalized*: proc(thisInterface: pointer; id: Vst3ParamID): Vst3ParamValue {.
      cdecl, raises: [].}
    setParamNormalized*: proc(thisInterface: pointer; id: Vst3ParamID;
                              value: Vst3ParamValue): int32 {.cdecl, raises: [].}
    setComponentHandler*: proc(thisInterface: pointer; handler: pointer): int32 {.
      cdecl, raises: [].}
    createView*: proc(thisInterface: pointer; name: cstring): ptr Vst3IPlugView {.
      cdecl, raises: [].}

  Vst3ViewRect* {.bycopy.} = object
    left*: int32
    top*: int32
    right*: int32
    bottom*: int32

  ## Exact generated-C IPlugView vtable.
  Vst3IPlugViewVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    isPlatformTypeSupported*: proc(thisInterface: pointer;
                                   typeName: cstring): int32 {.
      cdecl, raises: [].}
    attached*: proc(thisInterface: pointer; parent: pointer;
                    typeName: cstring): int32 {.cdecl, raises: [].}
    removed*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    onWheel*: proc(thisInterface: pointer; distance: cfloat): int32 {.
      cdecl, raises: [].}
    onKeyDown*: proc(thisInterface: pointer; key: Vst3TChar;
                     keyCode, modifiers: int16): int32 {.
      cdecl, raises: [].}
    onKeyUp*: proc(thisInterface: pointer; key: Vst3TChar;
                   keyCode, modifiers: int16): int32 {.
      cdecl, raises: [].}
    getSize*: proc(thisInterface: pointer; size: ptr Vst3ViewRect): int32 {.
      cdecl, raises: [].}
    onSize*: proc(thisInterface: pointer; newSize: ptr Vst3ViewRect): int32 {.
      cdecl, raises: [].}
    onFocus*: proc(thisInterface: pointer; state: Vst3TBool): int32 {.
      cdecl, raises: [].}
    setFrame*: proc(thisInterface: pointer; frame: ptr Vst3IPlugFrame): int32 {.
      cdecl, raises: [].}
    canResize*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    checkSizeConstraint*: proc(thisInterface: pointer;
                               rect: ptr Vst3ViewRect): int32 {.
      cdecl, raises: [].}

  Vst3IPlugView* {.bycopy.} = object
    lpVtbl*: ptr Vst3IPlugViewVtbl

  Vst3IPlugViewContentScaleSupportVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    setContentScaleFactor*: proc(thisInterface: pointer;
                                 factor: cfloat): int32 {.
      cdecl, raises: [].}

  Vst3IPlugViewContentScaleSupport* {.bycopy.} = object
    lpVtbl*: ptr Vst3IPlugViewContentScaleSupportVtbl

  Vst3IPlugFrameVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    resizeView*: proc(thisInterface: pointer; view: ptr Vst3IPlugView;
                      newSize: ptr Vst3ViewRect): int32 {.
      cdecl, raises: [].}

  Vst3IPlugFrame* {.bycopy.} = object
    lpVtbl*: ptr Vst3IPlugFrameVtbl

  Vst3EditController* {.bycopy.} = object
    lpVtbl*: ptr Vst3EditControllerVtbl

  Vst3MidiMappingVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getMidiControllerAssignment*: proc(thisInterface: pointer;
                                      busIndex: Vst3BusIndex;
                                      channel: Vst3MidiChannel;
                                      midiControllerNumber: Vst3CtrlNumber;
                                      id: ptr Vst3ParamID): int32 {.
      cdecl, raises: [].}
  Vst3MidiMapping* {.bycopy.} = object
    lpVtbl*: ptr Vst3MidiMappingVtbl

  Vst3HostApplicationVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getName*: proc(thisInterface: pointer; name: ptr Vst3VstString128): int32 {.
      cdecl, raises: [].}
    createInstance*: proc(thisInterface: pointer; cid, iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
  Vst3HostApplication* {.bycopy.} = object
    lpVtbl*: ptr Vst3HostApplicationVtbl

  Vst3AttributeListVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    setInt*: proc(thisInterface: pointer; id: cstring; value: int64): int32 {.
      cdecl, raises: [].}
    getInt*: proc(thisInterface: pointer; id: cstring; value: ptr int64): int32 {.
      cdecl, raises: [].}
    setFloat*: proc(thisInterface: pointer; id: cstring; value: float64): int32 {.
      cdecl, raises: [].}
    getFloat*: proc(thisInterface: pointer; id: cstring; value: ptr float64): int32 {.
      cdecl, raises: [].}
    setString*: proc(thisInterface: pointer; id: cstring; value: ptr Vst3TChar): int32 {.
      cdecl, raises: [].}
    getString*: proc(thisInterface: pointer; id: cstring; value: ptr Vst3TChar;
                    sizeInBytes: uint32): int32 {.cdecl, raises: [].}
    setBinary*: proc(thisInterface: pointer; id: cstring; data: pointer;
                     sizeInBytes: uint32): int32 {.cdecl, raises: [].}
    getBinary*: proc(thisInterface: pointer; id: cstring; data: ptr pointer;
                     sizeInBytes: ptr uint32): int32 {.cdecl, raises: [].}
  Vst3AttributeList* {.bycopy.} = object
    lpVtbl*: ptr Vst3AttributeListVtbl

  Vst3MessageVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getMessageID*: proc(thisInterface: pointer): cstring {.cdecl, raises: [].}
    setMessageID*: proc(thisInterface: pointer; id: cstring) {.cdecl, raises: [].}
    getAttributes*: proc(thisInterface: pointer): ptr Vst3AttributeList {.
      cdecl, raises: [].}
  Vst3Message* {.bycopy.} = object
    lpVtbl*: ptr Vst3MessageVtbl

  Vst3ConnectionPointVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    connect*: proc(thisInterface, other: pointer): int32 {.cdecl, raises: [].}
    disconnect*: proc(thisInterface, other: pointer): int32 {.cdecl, raises: [].}
    notify*: proc(thisInterface, message: pointer): int32 {.cdecl, raises: [].}
  Vst3ConnectionPoint* {.bycopy.} = object
    lpVtbl*: ptr Vst3ConnectionPointVtbl

  Vst3ComponentHandlerVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    beginEdit*: proc(thisInterface: pointer; id: Vst3ParamID): int32 {.
      cdecl, raises: [].}
    performEdit*: proc(thisInterface: pointer; id: Vst3ParamID;
                       valueNormalized: Vst3ParamValue): int32 {.
      cdecl, raises: [].}
    endEdit*: proc(thisInterface: pointer; id: Vst3ParamID): int32 {.
      cdecl, raises: [].}
    restartComponent*: proc(thisInterface: pointer; flags: int32): int32 {.
      cdecl, raises: [].}
  Vst3ComponentHandler* {.bycopy.} = object
    lpVtbl*: ptr Vst3ComponentHandlerVtbl

  Vst3PlugInterfaceSupportVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    isPlugInterfaceSupported*: proc(thisInterface: pointer; iid: ptr Vst3Tuid): int32 {.
      cdecl, raises: [].}
  Vst3PlugInterfaceSupport* {.bycopy.} = object
    lpVtbl*: ptr Vst3PlugInterfaceSupportVtbl

  Vst3RunLoopEventHandlerVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    onFDIsSet*: proc(thisInterface: pointer; fd: Vst3FileDescriptor) {.cdecl, raises: [].}
  Vst3RunLoopEventHandler* {.bycopy.} = object
    lpVtbl*: ptr Vst3RunLoopEventHandlerVtbl

  Vst3RunLoopTimerHandlerVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    onTimer*: proc(thisInterface: pointer) {.cdecl, raises: [].}
  Vst3RunLoopTimerHandler* {.bycopy.} = object
    lpVtbl*: ptr Vst3RunLoopTimerHandlerVtbl

  Vst3RunLoopVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    registerEventHandler*: proc(thisInterface, handler: pointer;
                                fd: Vst3FileDescriptor): int32 {.cdecl, raises: [].}
    unregisterEventHandler*: proc(thisInterface, handler: pointer): int32 {.
      cdecl, raises: [].}
    registerTimer*: proc(thisInterface, handler: pointer;
                         milliseconds: Vst3TimerInterval): int32 {.
      cdecl, raises: [].}
    unregisterTimer*: proc(thisInterface, handler: pointer): int32 {.
      cdecl, raises: [].}
  Vst3RunLoop* {.bycopy.} = object
    lpVtbl*: ptr Vst3RunLoopVtbl

  Vst3BStreamVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    read*: proc(thisInterface: pointer; buffer: pointer; numBytes: int32;
               numBytesRead: ptr int32): int32 {.cdecl, raises: [].}
    write*: proc(thisInterface: pointer; buffer: pointer; numBytes: int32;
                numBytesWritten: ptr int32): int32 {.cdecl, raises: [].}
    seek*: proc(thisInterface: pointer; pos: int64; mode: int32;
                result: ptr int64): int32 {.cdecl, raises: [].}
    tell*: proc(thisInterface: pointer; pos: ptr int64): int32 {.cdecl, raises: [].}
  Vst3BStream* {.bycopy.} = object
    lpVtbl*: ptr Vst3BStreamVtbl
  Vst3SpeakerArrangement* = uint64
  Vst3SampleRate* = float64
  Vst3Sample32* = cfloat
  Vst3Sample64* = float64
  Vst3ProcessContext* {.bycopy.} = object
    state*: uint32
    sampleRate*: float64
    projectTimeSamples*: int64
    systemTime*: int64
    continousTimeSamples*: int64
    projectTimeMusic*: float64
    barPositionMusic*: float64
    cycleStartMusic*: float64
    cycleEndMusic*: float64
    tempo*: float64
    timeSigNumerator*: int32
    timeSigDenominator*: int32
    chordKeyNote*: uint8
    chordRootNote*: uint8
    chordMask*: int16
    smpteOffsetSubframes*: int32
    frameRateFramesPerSecond*: uint32
    frameRateFlags*: uint32
    samplesToNextClock*: int32
  Vst3NoteOnEvent* {.bycopy.} = object
    channel*: int16
    pitch*: int16
    tuning*: cfloat
    velocity*: cfloat
    length*: int32
    noteId*: int32
  Vst3NoteOffEvent* {.bycopy.} = object
    channel*: int16
    pitch*: int16
    velocity*: cfloat
    noteId*: int32
    tuning*: cfloat
  Vst3DataEvent* {.bycopy.} = object
    size*: uint32
    dataType*: uint32
    bytes*: ptr uint8
  Vst3PolyPressureEvent* {.bycopy.} = object
    channel*: int16
    pitch*: int16
    pressure*: cfloat
    noteId*: int32
  Vst3LegacyMidiCcOutEvent* {.bycopy.} = object
    controlNumber*: uint8
    channel*: int8
    value*: int8
    value2*: int8
  Vst3Event* {.bycopy.} = object
    busIndex*: int32
    sampleOffset*: int32
    ppqPosition*: float64
    flags*: uint16
    eventType*: uint16
    reserved*: uint32
    payload*: array[24, uint8]
  Vst3ProcessSetup* {.bycopy.} = object
    processMode*: int32
    symbolicSampleSize*: int32
    maxSamplesPerBlock*: int32
    sampleRate*: float64
  Vst3AudioBusBuffers* {.bycopy.} = object
    numChannels*: int32
    silenceFlags*: uint64
    channelBuffers32*: ptr ptr cfloat
  Vst3EventListVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getEventCount*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    getEvent*: proc(thisInterface: pointer; index: int32;
                    event: ptr Vst3Event): int32 {.cdecl, raises: [].}
    addEvent*: proc(thisInterface: pointer; event: ptr Vst3Event): int32 {.
      cdecl, raises: [].}
  Vst3EventList* {.bycopy.} = object
    lpVtbl*: ptr Vst3EventListVtbl
  Vst3ParamValueQueueVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getParameterId*: proc(thisInterface: pointer): Vst3ParamID {.cdecl, raises: [].}
    getPointCount*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    getPoint*: proc(thisInterface: pointer; index: int32;
                    sampleOffset: ptr int32; value: ptr Vst3ParamValue): int32 {.
      cdecl, raises: [].}
    addPoint*: proc(thisInterface: pointer; sampleOffset: int32;
                    value: Vst3ParamValue; index: ptr int32): int32 {.
      cdecl, raises: [].}
  Vst3ParamValueQueue* {.bycopy.} = object
    lpVtbl*: ptr Vst3ParamValueQueueVtbl
  Vst3ParameterChangesVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getParameterCount*: proc(thisInterface: pointer): int32 {.cdecl, raises: [].}
    getParameterData*: proc(thisInterface: pointer; index: int32):
      ptr Vst3ParamValueQueue {.cdecl, raises: [].}
    addParameterData*: proc(thisInterface: pointer; id: ptr Vst3ParamID;
                            index: ptr int32): ptr Vst3ParamValueQueue {.
      cdecl, raises: [].}
  Vst3ParameterChanges* {.bycopy.} = object
    lpVtbl*: ptr Vst3ParameterChangesVtbl
  Vst3ProcessData* {.bycopy.} = object
    processMode*: int32
    symbolicSampleSize*: int32
    numSamples*: int32
    numInputs*: int32
    numOutputs*: int32
    inputs*: ptr Vst3AudioBusBuffers
    outputs*: ptr Vst3AudioBusBuffers
    inputParameterChanges*: ptr Vst3ParameterChanges
    outputParameterChanges*: ptr Vst3ParameterChanges
    inputEvents*: ptr Vst3EventList
    outputEvents*: ptr Vst3EventList
    processContext*: ptr Vst3ProcessContext
  Vst3ProcessContextRequirementsVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, raises: [].}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    release*: proc(thisInterface: pointer): uint32 {.cdecl, raises: [].}
    getProcessContextRequirements*: proc(thisInterface: pointer): uint32 {.
      cdecl, raises: [].}
  Vst3ProcessContextRequirements* {.bycopy.} = object
    lpVtbl*: ptr Vst3ProcessContextRequirementsVtbl
static:
  doAssert sizeof(Vst3Tuid) == 16
  doAssert sizeof(Vst3FactoryInfo) == 452
  doAssert sizeof(Vst3ClassInfo) == 116
  doAssert sizeof(Vst3ClassInfo2) == 440
  doAssert sizeof(Vst3ClassInfoW) == 696
  doAssert sizeof(Vst3ProcessSetup) == 24
  doAssert sizeof(Vst3AudioBusBuffers) == 24
  doAssert sizeof(Vst3ProcessData) == 80
  doAssert Vst3SymbolicSample32 == 0'i32
  doAssert Vst3SymbolicSample64 == 1'i32
  doAssert sizeof(Vst3Event) == 48
  doAssert sizeof(Vst3ProcessContext) == 112
  doAssert sizeof(Vst3ViewRect) == 16
  doAssert alignof(Vst3ViewRect) == 4
  doAssert sizeof(Vst3IPlugViewVtbl) == 120
  doAssert sizeof(Vst3IPlugFrameVtbl) == 32
  doAssert sizeof(Vst3IPlugViewContentScaleSupportVtbl) == 32
