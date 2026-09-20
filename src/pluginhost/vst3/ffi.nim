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

  Vst3FactoryIid* = "7A4D811C52114A1FAED9D2EE0B43BF9F"
  Vst3Factory2Iid* = "0007B650F24B4C0BA464EDB9F00B2ABB"
  Vst3Factory3Iid* = "4555A2ABC1234E579B12291036878931"

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
                          obj: ptr pointer): int32 {.cdecl.}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl.}
    release*: proc(thisInterface: pointer): uint32 {.cdecl.}
  Vst3FUnknown* {.bycopy.} = object
    lpVtbl*: ptr Vst3FUnknownVtbl

  Vst3PluginFactoryVtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl.}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl.}
    release*: proc(thisInterface: pointer): uint32 {.cdecl.}
    getFactoryInfo*: proc(thisInterface: pointer;
                          info: ptr Vst3FactoryInfo): int32 {.cdecl.}
    countClasses*: proc(thisInterface: pointer): int32 {.cdecl.}
    getClassInfo*: proc(thisInterface: pointer; index: int32;
                        info: ptr Vst3ClassInfo): int32 {.cdecl.}
    createInstance*: proc(thisInterface: pointer; cid: cstring;
                          iid: cstring; obj: ptr pointer): int32 {.cdecl.}

  Vst3PluginFactory2Vtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl.}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl.}
    release*: proc(thisInterface: pointer): uint32 {.cdecl.}
    getFactoryInfo*: proc(thisInterface: pointer;
                          info: ptr Vst3FactoryInfo): int32 {.cdecl.}
    countClasses*: proc(thisInterface: pointer): int32 {.cdecl.}
    getClassInfo*: proc(thisInterface: pointer; index: int32;
                        info: ptr Vst3ClassInfo): int32 {.cdecl.}
    createInstance*: proc(thisInterface: pointer; cid: cstring;
                          iid: cstring; obj: ptr pointer): int32 {.cdecl.}
    getClassInfo2*: proc(thisInterface: pointer; index: int32;
                         info: ptr Vst3ClassInfo2): int32 {.cdecl.}

  Vst3PluginFactory3Vtbl* {.bycopy.} = object
    queryInterface*: proc(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl.}
    addRef*: proc(thisInterface: pointer): uint32 {.cdecl.}
    release*: proc(thisInterface: pointer): uint32 {.cdecl.}
    getFactoryInfo*: proc(thisInterface: pointer;
                          info: ptr Vst3FactoryInfo): int32 {.cdecl.}
    countClasses*: proc(thisInterface: pointer): int32 {.cdecl.}
    getClassInfo*: proc(thisInterface: pointer; index: int32;
                        info: ptr Vst3ClassInfo): int32 {.cdecl.}
    createInstance*: proc(thisInterface: pointer; cid: cstring;
                          iid: cstring; obj: ptr pointer): int32 {.cdecl.}
    getClassInfo2*: proc(thisInterface: pointer; index: int32;
                         info: ptr Vst3ClassInfo2): int32 {.cdecl.}
    getClassInfoUnicode*: proc(thisInterface: pointer; index: int32;
                               info: ptr Vst3ClassInfoW): int32 {.cdecl.}
    setHostContext*: proc(thisInterface: pointer; context: pointer): int32 {.cdecl.}

  Vst3PluginFactory* {.bycopy.} = object
    lpVtbl*: ptr Vst3PluginFactoryVtbl

  Vst3PluginFactory2* {.bycopy.} = object
    lpVtbl*: ptr Vst3PluginFactory2Vtbl

  Vst3PluginFactory3* {.bycopy.} = object
    lpVtbl*: ptr Vst3PluginFactory3Vtbl

  Vst3ModuleEntry* = proc(sharedLibraryHandle: pointer): bool {.cdecl.}
  Vst3ModuleExit* = proc(): bool {.cdecl.}
  Vst3GetPluginFactory* = proc(): ptr Vst3PluginFactory {.cdecl.}

static:
  doAssert sizeof(Vst3Tuid) == 16
  doAssert sizeof(Vst3FactoryInfo) == 452
  doAssert sizeof(Vst3ClassInfo) == 116
  doAssert sizeof(Vst3ClassInfo2) == 440
  doAssert sizeof(Vst3ClassInfoW) == 696
