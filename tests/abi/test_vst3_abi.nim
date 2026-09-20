import std/[os, unittest]

import pluginhost/domain/errors
import pluginhost/platform/linux/dynlib
import pluginhost/vst3/[ffi, module, uid]
import ./vst3_host_probe

proc vst3AbiSize(typeId: int32): uint64 {.
  importc: "pluginhost_vst3_abi_size", cdecl, gcsafe, raises: [].}
proc vst3AbiAlign(typeId: int32): uint64 {.
  importc: "pluginhost_vst3_abi_align", cdecl, gcsafe, raises: [].}
proc vst3AbiOffset(fieldId: int32): uint64 {.
  importc: "pluginhost_vst3_abi_offset", cdecl, gcsafe, raises: [].}
proc vst3AbiUidByte(index: int32): uint64 {.
  importc: "pluginhost_vst3_abi_uid_byte", cdecl, gcsafe, raises: [].}

proc vst3FieldId(typeId, fieldId: int32): int32 =
  typeId * 100 + fieldId

proc fixtureRoot(): string =
  let root = getEnv("PLUGINHOST_VST3_FIXTURE_DIR")
  if root.len == 0:
    raise newException(ValueError, "PLUGINHOST_VST3_FIXTURE_DIR is required")
  root

proc fixturePath(name: string): string =
  fixtureRoot() / (name & ".vst3")

proc fixtureBinary(name: string): string =
  fixturePath(name) / "Contents" / Vst3ArchitectureDir / (name & ".so")

type
  CounterProc = proc(): uint32 {.cdecl.}
  U64Proc = proc(): uint64 {.cdecl.}
  AddressProc = proc(): uint {.cdecl.}

proc counter(library: DynamicLibrary; name: string): CounterProc =
  var resolved = resolveSymbol[CounterProc](library, name)
  require resolved.isOk
  resolved.value

proc u64Value(library: DynamicLibrary; name: string): U64Proc =
  var resolved = resolveSymbol[U64Proc](library, name)
  require resolved.isOk
  resolved.value

proc addressValue(library: DynamicLibrary; name: string): AddressProc =
  var resolved = resolveSymbol[AddressProc](library, name)
  require resolved.isOk
  resolved.value

proc writeElfHeader(path: string; elfClass, data: uint8; machine: uint16) =
  var bytes = newString(20)
  bytes[0] = '\x7f'
  bytes[1] = 'E'
  bytes[2] = 'L'
  bytes[3] = 'F'
  bytes[4] = char(elfClass)
  bytes[5] = char(data)
  bytes[6] = '\x01'
  bytes[18] = char(machine and 0xFF'u16)
  bytes[19] = char(machine shr 8)
  writeFile(path, bytes)

proc makeBundle(name, binaryName: string; elfClass, data: uint8;
                machine: uint16): string =
  result = getTempDir() / ("pluginhost-vst3-" & name & ".vst3")
  if dirExists(result):
    removeDir(result)
  let architecture = result / "Contents" / Vst3ArchitectureDir
  createDir(architecture)
  writeElfHeader(architecture / binaryName, elfClass, data, machine)

suite "VST3 raw ABI and module ownership":
  test "generated C header layouts match the Nim boundary":
    check uint64(sizeof(Vst3Tuid)) == vst3AbiSize(401)
    check uint64(alignof(Vst3Tuid)) == vst3AbiAlign(401)
    check uint64(sizeof(Vst3FactoryInfo)) == vst3AbiSize(402)
    check uint64(alignof(Vst3FactoryInfo)) == vst3AbiAlign(402)
    check uint64(sizeof(Vst3ClassInfo)) == vst3AbiSize(403)
    check uint64(sizeof(Vst3ClassInfo2)) == vst3AbiSize(404)
    check uint64(sizeof(Vst3ClassInfoW)) == vst3AbiSize(405)
    check uint64(sizeof(Vst3PluginFactoryVtbl)) == vst3AbiSize(406)
    check uint64(sizeof(Vst3FUnknownVtbl)) == vst3AbiSize(407)
    check uint64(sizeof(Vst3PluginFactory2Vtbl)) == vst3AbiSize(408)
    check uint64(sizeof(Vst3PluginFactory3Vtbl)) == vst3AbiSize(409)
    check uint64(offsetOf(Vst3FactoryInfo, flags)) ==
      vst3AbiOffset(vst3FieldId(402, 4))
    check uint64(offsetOf(Vst3ClassInfo, cid)) ==
      vst3AbiOffset(vst3FieldId(403, 1))
    check uint64(offsetOf(Vst3ClassInfo, name)) ==
      vst3AbiOffset(vst3FieldId(403, 4))
    check uint64(offsetOf(Vst3ClassInfo2, subCategories)) ==
      vst3AbiOffset(vst3FieldId(404, 2))
    check uint64(offsetOf(Vst3ClassInfoW, name)) ==
      vst3AbiOffset(vst3FieldId(405, 1))
    check uint64(offsetOf(Vst3PluginFactoryVtbl, queryInterface)) ==
      vst3AbiOffset(vst3FieldId(406, 1))
    check uint64(offsetOf(Vst3PluginFactoryVtbl, createInstance)) ==
      vst3AbiOffset(vst3FieldId(406, 4))
    check sizeof(Vst3FUnknown) == sizeof(pointer)
    check sizeof(Vst3ModuleEntry) == sizeof(pointer)
    check sizeof(Vst3ModuleExit) == sizeof(pointer)
    check sizeof(Vst3GetPluginFactory) == sizeof(pointer)

  test "UID conversion preserves the generated C byte order":
    let parsed = parseVst3Uid(Vst3FactoryIid)
    require parsed.isOk
    check formatVst3Uid(parsed.value) == Vst3FactoryIid
    for index in 0 ..< Vst3TuidBytes:
      check uint64(parsed.value[index]) == vst3AbiUidByte(int32(index))
    check not parseVst3Uid("0011").isOk
    check not parseVst3Uid("00112233445566778899AABBCCDDEEFG").isOk

  test "v3 factory uses an adjusted interface and calls back into Nim":
    var observerResult = openDynamicLibrary(fixtureBinary("valid"), keepLoaded = true)
    require observerResult.isOk
    var observer = move(observerResult.value)
    defer:
      doAssert observer.close().isOk

    let entries = counter(observer, "pluginhost_vst3_fixture_entry_calls")
    let exits = counter(observer, "pluginhost_vst3_fixture_exit_calls")
    let gets = counter(observer, "pluginhost_vst3_fixture_factory_get_calls")
    let queries = counter(observer, "pluginhost_vst3_fixture_factory_query_calls")
    let v2Queries = counter(observer, "pluginhost_vst3_fixture_factory_v2_query_calls")
    let v3Queries = counter(observer, "pluginhost_vst3_fixture_factory_v3_query_calls")
    let releases = counter(observer, "pluginhost_vst3_fixture_factory_release_calls")
    let infoCalls = counter(observer, "pluginhost_vst3_fixture_factory_info_calls")
    let classCountCalls = counter(observer, "pluginhost_vst3_fixture_class_count_calls")
    let classInfo2Calls = counter(observer, "pluginhost_vst3_fixture_class_info2_calls")
    let hostContexts = counter(observer, "pluginhost_vst3_fixture_host_context_calls")
    let refs = counter(observer, "pluginhost_vst3_fixture_refs")
    let lastRelease = u64Value(observer, "pluginhost_vst3_fixture_last_release_sequence")
    let lastExit = u64Value(observer, "pluginhost_vst3_fixture_last_exit_sequence")
    let baseAddress = addressValue(observer, "pluginhost_vst3_fixture_base_address")
    let v2Address = addressValue(observer, "pluginhost_vst3_fixture_v2_address")
    let v3Address = addressValue(observer, "pluginhost_vst3_fixture_v3_address")
    check entries() == 0
    check exits() == 0
    check baseAddress() != v2Address()
    check baseAddress() != v3Address()

    var opened = openVst3Module(fixturePath("valid"))
    require opened.isOk
    var module = move(opened.value)
    check entries() == 1
    check gets() == 1
    check refs() == 1

    var hostProbe: Vst3HostProbe
    initVst3HostProbe(hostProbe)
    check module.setFactoryHostContext(hostProbe.interfacePointer()).isOk
    check hostContexts() == 1
    check hostProbe.queryCalls == 1
    check hostProbe.addRefCalls == 1
    check hostProbe.releaseCalls == 1

    var catalog = module.readFactoryCatalog()
    require catalog.isOk
    check catalog.value.factoryLevel == vflV3
    check catalog.value.classes.len == 1
    check catalog.value.classes[0].category == Vst3AudioEffectClass
    check catalog.value.classes[0].subCategories == "Fx"
    check catalog.value.classes[0].vendor == "pluginhost"
    check classInfo2Calls() == 1
    check infoCalls() == 1
    check classCountCalls() == 1
    check v3Queries() == 2
    check v2Queries() == 0
    check queries() == 2
    check releases() == 2
    check refs() == 1

    check module.close().isOk
    check releases() == 3
    check refs() == 0
    check lastRelease() < lastExit()
    check exits() == 1
    check module.close().isOk
    check exits() == 1

  test "factory v2 and base fallbacks release adjusted references":
    for item in [("v2_only", vflV2), ("base_only", vflBase)]:
      let name = item[0]
      let expectedLevel = item[1]
      var observerResult = openDynamicLibrary(fixtureBinary(name), keepLoaded = true)
      require observerResult.isOk
      var observer = move(observerResult.value)
      defer:
        doAssert observer.close().isOk
      let refs = counter(observer, "pluginhost_vst3_fixture_refs")
      let releases = counter(observer, "pluginhost_vst3_fixture_factory_release_calls")
      let exits = counter(observer, "pluginhost_vst3_fixture_exit_calls")

      var opened = openVst3Module(fixturePath(name))
      require opened.isOk
      var module = move(opened.value)
      var catalog = module.readFactoryCatalog()
      require catalog.isOk
      check catalog.value.factoryLevel == expectedLevel
      check catalog.value.classes.len == 1
      check module.close().isOk
      check refs() == 0
      check releases() >= 1
      check exits() == 1

  test "null factory balances accepted entry without a factory release":
    var observerResult = openDynamicLibrary(fixtureBinary("null_factory"), keepLoaded = true)
    require observerResult.isOk
    var observer = move(observerResult.value)
    defer:
      doAssert observer.close().isOk
    let entries = counter(observer, "pluginhost_vst3_fixture_entry_calls")
    let exits = counter(observer, "pluginhost_vst3_fixture_exit_calls")
    let gets = counter(observer, "pluginhost_vst3_fixture_factory_get_calls")
    let releases = counter(observer, "pluginhost_vst3_fixture_factory_release_calls")
    let refs = counter(observer, "pluginhost_vst3_fixture_refs")

    let opened = openVst3Module(fixturePath("null_factory"))
    check not opened.isOk
    check opened.error.kind == hekVst3Factory
    check entries() == 1
    check gets() == 1
    check releases() == 0
    check refs() == 1
    check exits() == 1
  test "failed interface query and bounded counts do not call later methods":
    for item in [
        ("query_fail", hekVst3Factory, 1'u32),
        ("query_null", hekVst3Factory, 1'u32),
        ("factory_info_fail", hekVst3Factory, 2'u32),
        ("negative_count", hekVst3Factory, 2'u32),
        ("excessive_count", hekVst3Factory, 2'u32),
        ("malformed_factory", hekVst3Descriptor, 2'u32),
        ("malformed_class", hekVst3Descriptor, 2'u32)]:
      let name = item[0]
      let expectedKind = item[1]
      let expectedReleases = item[2]
      var observerResult = openDynamicLibrary(fixtureBinary(name), keepLoaded = true)
      require observerResult.isOk
      var observer = move(observerResult.value)
      defer:
        doAssert observer.close().isOk
      let entries = counter(observer, "pluginhost_vst3_fixture_entry_calls")
      let exits = counter(observer, "pluginhost_vst3_fixture_exit_calls")
      let releases = counter(observer, "pluginhost_vst3_fixture_factory_release_calls")
      let refs = counter(observer, "pluginhost_vst3_fixture_refs")

      var opened = openVst3Module(fixturePath(name))
      require opened.isOk
      var module = move(opened.value)
      let catalog = module.readFactoryCatalog()
      check not catalog.isOk
      check catalog.error.kind == expectedKind
      check module.close().isOk
      check entries() == 1
      check exits() == 1
      check releases() == expectedReleases
      check refs() == 0

  test "failed entry invokes ModuleExit once and missing exports invoke neither":
    var rejectObserverResult = openDynamicLibrary(
      fixtureBinary("entry_reject"), keepLoaded = true)
    require rejectObserverResult.isOk
    var rejectObserver = move(rejectObserverResult.value)
    defer:
      doAssert rejectObserver.close().isOk
    let rejectEntries = counter(rejectObserver, "pluginhost_vst3_fixture_entry_calls")
    let rejectExits = counter(rejectObserver, "pluginhost_vst3_fixture_exit_calls")
    let rejected = openVst3Module(fixturePath("entry_reject"))
    check not rejected.isOk
    check rejected.error.kind == hekVst3Entry
    check rejectEntries() == 1
    check rejectExits() == 1

    for name in ["missing_exit", "missing_factory"]:
      var observerResult = openDynamicLibrary(fixtureBinary(name), keepLoaded = true)
      require observerResult.isOk
      var observer = move(observerResult.value)
      let entries = counter(observer, "pluginhost_vst3_fixture_entry_calls")
      let exits = counter(observer, "pluginhost_vst3_fixture_exit_calls")
      let opened = openVst3Module(fixturePath(name))
      check not opened.isOk
      check opened.error.kind == hekVst3Symbol
      check entries() == 0
      check exits() == 0
      check observer.close().isOk

  test "same-stem and ELF architecture checks reject unsafe candidates":
    let wrongStem = makeBundle("wrong-stem", "other.so", 2, 1, 62)
    defer:
      removeDir(wrongStem)
    let missingSameStem = openVst3Module(wrongStem)
    check not missingSameStem.isOk
    check missingSameStem.error.kind == hekVst3Binary

    for item in [
        ("class", 1'u8, 1'u8, 62'u16),
        ("data", 2'u8, 2'u8, 62'u16),
        ("machine", 2'u8, 1'u8, 3'u16)]:
      let suffix = item[0]
      let elfClass = item[1]
      let data = item[2]
      let machine = item[3]
      let path = makeBundle("wrong-" & suffix, "wrong-" & suffix & ".so",
        elfClass, data, machine)
      defer:
        removeDir(path)
      let opened = openVst3Module(path)
      check not opened.isOk
      check opened.error.kind == hekVst3Binary
