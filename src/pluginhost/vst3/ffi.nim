## Minimal policy-free VST3 ABI declarations for the reviewed V1A boundary.
##
## The complete generated C declaration is vendored under vendor/vst3. These
## declarations mirror only the module/factory/catalog interfaces used here;
## later gates add their interfaces beside their tests.

const
  Vst3GeneratedHeader* = "vendor/vst3/vst3_c_api.h"
  Vst3AudioEffectClass* = "AudioEffectClass"
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
  Vst3FUnknownIid* = "0000000000000000C000000000000046"
  Vst3ResultNoInterface* = Vst3NoInterface
  Vst3FactoryIid* = "7A4D811C52114A1FAED9D2EE0B43BF9F"
  Vst3Factory2Iid* = "0007B650F24B4C0BA464EDB9F00B2ABB"
  Vst3Factory3Iid* = "4555A2ABC1234E579B12291036878931"

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

  Vst3PluginFactory* {.bycopy.} = object
    lpVtbl*: ptr Vst3PluginFactoryVtbl

  Vst3PluginFactory2* {.bycopy.} = object
    lpVtbl*: ptr Vst3PluginFactory2Vtbl

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
    process*: proc(thisInterface: pointer; data: pointer): int32 {.cdecl, raises: [].}
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
    createView*: proc(thisInterface: pointer; name: cstring): pointer {.
      cdecl, raises: [].}
  Vst3EditController* {.bycopy.} = object
    lpVtbl*: ptr Vst3EditControllerVtbl

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
static:
  doAssert sizeof(Vst3Tuid) == 16
  doAssert sizeof(Vst3FactoryInfo) == 452
  doAssert sizeof(Vst3ClassInfo) == 116
  doAssert sizeof(Vst3ClassInfo2) == 440
  doAssert sizeof(Vst3ClassInfoW) == 696
