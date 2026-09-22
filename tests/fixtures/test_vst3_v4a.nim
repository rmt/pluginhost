import std/[os, posix, unittest]

import pluginhost/app/[vst3_audio_slice, vst3_plugin_services]
import pluginhost/domain/[errors, result]
import pluginhost/jack/backend
import pluginhost/platform/linux/dynlib
import pluginhost/vst3/[ffi, host_context, instance, module, state_codec, stream, uid]
import ./jack/fixture_api

const ClassId = "102132435465768798A9BACBDCEDFEFF"

type
  CounterProc = proc(): uint32 {.cdecl, raises: [].}
  PathProc = proc(path: cstring): uint32 {.cdecl, raises: [].}
  IndexedCounterProc = proc(index: uint32): uint32 {.cdecl, raises: [].}
  VoidProc = proc() {.cdecl, raises: [].}

proc fixtureDirectory(): string =
  let value = getEnv("PLUGINHOST_VST3_V4A_FIXTURE_DIR")
  doAssert value.len > 0
  value

proc fixturePath(name = "v4a"): string =
  fixtureDirectory() / (name & ".vst3")

proc jackFakeFixturePath(): string =
  let value = getEnv("PLUGINHOST_JACK_FAKE_FIXTURE")
  doAssert value.len > 0
  value

proc openFixture(loadPath = ""; fixtureName = "v4a"): Result[Vst3Instance] =
  var loaded = openVst3Module(fixturePath(fixtureName))
  if not loaded.isOk: return failure[Vst3Instance](move(loaded.error))
  var library = move(loaded.value)
  var cid = parseVst3Uid(ClassId)
  if not cid.isOk: return failure[Vst3Instance](move(cid.error))
  openVst3Instance(library, cid.value, nil, nil, loadPath)

proc counter(name: string; fixtureName = "v4a"): uint32 =
  var opened = openDynamicLibrary(fixturePath(fixtureName) /
    "Contents" / Vst3ArchitectureDir / (fixtureName & ".so"), keepLoaded = true)
  doAssert opened.isOk
  var library = move(opened.value)
  let resolved = resolveSymbol[CounterProc](library, name)
  doAssert resolved.isOk
  result = resolved.value()
  doAssert library.close().isOk
proc indexedCounter(name: string; index: uint32): uint32 =
  var opened = openDynamicLibrary(fixturePath() /
    "Contents" / Vst3ArchitectureDir / "v4a.so", keepLoaded = true)
  doAssert opened.isOk
  var library = move(opened.value)
  let resolved = resolveSymbol[IndexedCounterProc](library, name)
  doAssert resolved.isOk
  result = resolved.value(index)
  doAssert library.close().isOk
proc fixturePathCall(name, path: string): uint32 =
  var opened = openDynamicLibrary(fixturePath() /
    "Contents" / Vst3ArchitectureDir / "v4a.so", keepLoaded = true)
  doAssert opened.isOk
  var library = move(opened.value)
  let resolved = resolveSymbol[PathProc](library, name)
  doAssert resolved.isOk
  result = resolved.value(path.cstring)
  doAssert library.close().isOk
proc fixtureVoidCall(fixtureName, name: string) =
  var opened = openDynamicLibrary(fixturePath(fixtureName) /
    "Contents" / Vst3ArchitectureDir / (fixtureName & ".so"), keepLoaded = true)
  doAssert opened.isOk
  var library = move(opened.value)
  let resolved = resolveSymbol[VoidProc](library, name)
  doAssert resolved.isOk
  resolved.value()
  doAssert library.close().isOk




proc bytesAsString(bytes: openArray[uint8]): string =
  result = newString(bytes.len)
  if bytes.len > 0: copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

suite "private VST3 V4A state transactions":
  test "standard component/controller roundtrip and exact CID":
    let component = @[uint8(1), 2, 3, 4]
    let controller = @[uint8(9), 8]
    let serialized = serializeVst3Preset(ClassId, component, controller, true)
    require serialized.isOk
    let parsed = parseVst3Preset(serialized.value, ClassId)
    require parsed.isOk
    check parsed.value.component == component
    check parsed.value.controller == controller
    check parsed.value.hasController
    check not parseVst3Preset(serialized.value, "00112233445566778899AABBCCDDEEFF").isOk

  test "malformed headers tables bounds and required chunks are rejected":
    let serialized = serializeVst3Preset(ClassId, @[uint8(1)], @[uint8(2)], true)
    require serialized.isOk

    var duplicate = serialized.value
    let listOffset = int(cast[int64](
      uint64(duplicate[40]) or (uint64(duplicate[41]) shl 8) or
      (uint64(duplicate[42]) shl 16) or (uint64(duplicate[43]) shl 24) or
      (uint64(duplicate[44]) shl 32) or (uint64(duplicate[45]) shl 40) or
      (uint64(duplicate[46]) shl 48) or (uint64(duplicate[47]) shl 56)))
    for index in 0 ..< 4: duplicate[listOffset + 8 + 20 + index] = duplicate[listOffset + 8 + index]
    check not parseVst3Preset(duplicate, ClassId).isOk
    var badMagic = serialized.value
    badMagic[0] = uint8(ord('X'))
    check not parseVst3Preset(badMagic, ClassId).isOk
    var badVersion = serialized.value
    badVersion[4] = 2
    check not parseVst3Preset(badVersion, ClassId).isOk
    var badListOffset = serialized.value
    for index in 40 ..< 48: badListOffset[index] = 0xff
    check not parseVst3Preset(badListOffset, ClassId).isOk
    var badCount = serialized.value
    badCount[listOffset + 4] = 129
    check not parseVst3Preset(badCount, ClassId).isOk
    var overlap = serialized.value
    let controllerEntry = listOffset + Vst3PresetListHeaderBytes +
      Vst3PresetEntryBytes
    overlap[controllerEntry + 4] = uint8(Vst3PresetHeaderBytes)
    for index in 1 ..< 8: overlap[controllerEntry + 4 + index] = 0
    check not parseVst3Preset(overlap, ClassId).isOk
    var missingComponent = serialized.value
    for index in 0 ..< 4:
      missingComponent[listOffset + Vst3PresetListHeaderBytes + index] =
        uint8(ord(Vst3PresetInfoId[index]))
    check not parseVst3Preset(missingComponent, ClassId).isOk
    var badBounds = serialized.value
    let componentSize = listOffset + Vst3PresetListHeaderBytes + 12
    for index in 0 ..< 8: badBounds[componentSize + index] = 0xff
    check not parseVst3Preset(badBounds, ClassId).isOk
    var unknown = serialized.value
    for index, value in "Xtra":
      unknown[controllerEntry + index] = uint8(ord(value))
    let unknownParsed = parseVst3Preset(unknown, ClassId)
    require unknownParsed.isOk
    check not unknownParsed.value.hasController
    var truncated = serialized.value
    truncated.setLen(truncated.len - 1)
    check not parseVst3Preset(truncated, ClassId).isOk
    var trailing = serialized.value
    trailing.add(0'u8)
    check not parseVst3Preset(trailing, ClassId).isOk

  test "native reader and writer agree on the standard preset layout":
    let hostTarget = getTempDir() / ("pluginhost-vst3-v4a-host-" &
      $getCurrentProcessId() & ".vstpreset")
    let nativeTarget = getTempDir() / ("pluginhost-vst3-v4a-cpp-" &
      $getCurrentProcessId() & ".vstpreset")
    defer:
      if fileExists(hostTarget): removeFile(hostTarget)
      if fileExists(nativeTarget): removeFile(nativeTarget)
    require writeVst3Preset(hostTarget, ClassId,
      @[uint8(0x56), 0x32, 0x41, 0x00], @[uint8(0x43), 0x54], true).isOk
    check fixturePathCall("pluginhost_vst3_v4a_validate_preset",
      hostTarget) == 1'u32
    check fixturePathCall("pluginhost_vst3_v4a_write_preset",
      nativeTarget) == 1'u32
    let parsed = loadVst3Preset(nativeTarget, ClassId)
    require parsed.isOk
    check parsed.value.component == @[uint8(0x56), 0x32, 0x41, 0x00]
    check parsed.value.controller == @[uint8(0x43), 0x54]
    check parsed.value.hasController

  test "read-only views and bounded stream boundaries":
    let stream = newVst3MemoryStream()
    require stream != nil
    let iface = stream.interfacePointer()
    var payload = [uint8(0x10), 0x20]
    var written: int32
    check iface.lpVtbl.write(cast[pointer](iface), addr payload[0], 2, addr written) == Vst3ResultOk
    check written == 2
    var position: int64
    check iface.lpVtbl.seek(cast[pointer](iface), int64(Vst3MaxStreamBytes), Vst3SeekSet,
      addr position) == Vst3ResultOk
    check iface.lpVtbl.write(cast[pointer](iface), addr payload[0], 1, addr written) == Vst3ResultFalse
    check stream.failed
    discard stream.close()

    let view = newVst3ReadOnlyStream(payload)
    require view != nil
    var read: int32
    check view.interfacePointer().lpVtbl.write(cast[pointer](view.interfacePointer()),
      addr payload[0], 1, addr written) == Vst3ResultFalse
    check view.interfacePointer().lpVtbl.read(cast[pointer](view.interfacePointer()),
      addr payload[0], 4, addr read) == Vst3ResultOk
    check read == 2
    discard view.close()
    read = -1
    check view.interfacePointer().lpVtbl.read(cast[pointer](view.interfacePointer()),
      addr payload[0], 1, addr read) == Vst3ResultFalse
    check read == 0

  test "plugin-retained stream keeps the rooted owner until release":
    let retained = newVst3MemoryStream()
    require retained != nil
    let raw = cast[pointer](retained.interfacePointer())
    discard retained.interfacePointer().lpVtbl.addRef(raw)
    discard retained.close()
    check retained.hasRetainedReferences
    discard retained.interfacePointer().lpVtbl.release(raw)
    check not retained.hasRetainedReferences


  test "native component/controller preset load follows transaction boundary":
    let target = getTempDir() / ("pluginhost-vst3-v4a-native-" &
      $getCurrentProcessId() & ".vstpreset")
    defer:
      if fileExists(target): removeFile(target)
    let serialized = serializeVst3Preset(ClassId,
      @[uint8(0x56), 0x32, 0x41, 0x00], @[uint8(0x43), 0x54], true)
    require serialized.isOk
    writeFile(target, bytesAsString(serialized.value))
    let before = counter("pluginhost_vst3_v2a_state_set")
    var opened = openFixture(target)
    require opened.isOk
    var instance = move(opened.value)
    check instance.selectedClassId == ClassId
    check instance.close().isOk
    check counter("pluginhost_vst3_v2a_state_bytes_observed") == 4'u32
    check counter("pluginhost_vst3_v2a_controller_state_set") > 0'u32
    check counter("pluginhost_vst3_v2a_state_set") > before
    check indexedCounter("pluginhost_vst3_v2a_state_order", 0) == 1'u32
    check indexedCounter("pluginhost_vst3_v2a_state_order", 1) == 3'u32
    check indexedCounter("pluginhost_vst3_v2a_state_order", 2) == 5'u32

  test "native load callback failures abort before activation":
    let target = getTempDir() / ("pluginhost-vst3-v4a-load-fail-" &
      $getCurrentProcessId() & ".vstpreset")
    defer:
      if fileExists(target): removeFile(target)
    require writeVst3Preset(target, ClassId,
      @[uint8(0x56), 0x32, 0x41, 0x00], @[uint8(0x43), 0x54], true).isOk
    for fixtureName in ["v4a-component-fail", "v4a-controller-fail",
                        "v4a-controller-sync-fail"]:
      let opened = openFixture(target, fixtureName)
      check not opened.isOk
      check opened.error.subsystem == hsState

  test "standard not-implemented state callbacks produce empty chunks":
    let target = getTempDir() / ("pluginhost-vst3-v4a-notimpl-" &
      $getCurrentProcessId() & ".vstpreset")
    defer:
      if fileExists(target): removeFile(target)
    require writeVst3Preset(target, ClassId,
      @[uint8(0x56), 0x32, 0x41, 0x00], @[uint8(0x43), 0x54], true).isOk
    var loaded = openFixture(target, "v4a-notimpl-load")
    require loaded.isOk
    var loadedInstance = move(loaded.value)
    check loadedInstance.close().isOk
    var opened = openFixture(fixtureName = "v4a-notimpl-capture")
    require opened.isOk
    var instance = move(opened.value)
    let captured = instance.captureState()
    require captured.isOk
    check captured.value.component.len == 0
    check not captured.value.hasController
    require writeVst3Preset(target, ClassId, captured.value.component,
      captured.value.controller, captured.value.hasController).isOk
    let parsed = loadVst3Preset(target, ClassId)
    require parsed.isOk
    check parsed.value.component.len == 0
    check instance.close().isOk

  test "native capture callback and sticky overflow failures propagate":
    for fixtureName in ["v4a-capture-fail", "v4a-overflow"]:
      var opened = openFixture(fixtureName = fixtureName)
      require opened.isOk
      var instance = move(opened.value)
      let captured = instance.captureState()
      require not captured.isOk
      check captured.error.subsystem == hsState
      check instance.close().isOk
    var omitted = openFixture(fixtureName = "v4a-controller-omit")
    require omitted.isOk
    var omittedInstance = move(omitted.value)
    let optionalController = omittedInstance.captureState()
    require optionalController.isOk
    check not optionalController.value.hasController
    check omittedInstance.close().isOk
    var controllerFailure = openFixture(
      fixtureName = "v4a-controller-capture-fail")
    require controllerFailure.isOk
    var controllerFailureInstance = move(controllerFailure.value)
    let failedController = controllerFailureInstance.captureState()
    check not failedController.isOk
    check failedController.error.subsystem == hsState
    check controllerFailureInstance.close().isOk
    let initialOverflow = openFixture(fixtureName = "v4a-initial-overflow")
    check not initialOverflow.isOk
    check initialOverflow.error.subsystem == hsState

  test "native retained stream is closed before unload and must drain":
    const FixtureName = "v4a-retain"
    var opened = openFixture(fixtureName = FixtureName)
    require opened.isOk
    var instance = move(opened.value)
    check counter("pluginhost_vst3_v4a_retained_read_result",
      FixtureName) == uint32(Vst3ResultFalse)
    check not instance.close().isOk
    fixtureVoidCall(FixtureName, "pluginhost_vst3_v2a_release_retained")
    check instance.close().isOk
  test "atomic save preserves old data and publishes exact private mode":
    let target = getTempDir() / ("pluginhost-vst3-v4a-" & $getCurrentProcessId() & ".vstpreset")
    defer:
      if fileExists(target): removeFile(target)
    writeFile(target, "old")
    check not writeVst3Preset(target, "bad", @[uint8(1)]).isOk
    check readFile(target) == "old"
    let previousMask = umask(Mode(0o777))
    let saved = writeVst3Preset(target, ClassId, @[uint8(1)])
    discard umask(previousMask)
    require saved.isOk
    check getFilePermissions(target) == {fpUserRead, fpUserWrite}

  test "native capture publishes readable component state":
    let target = getTempDir() / ("pluginhost-vst3-v4a-capture-" &
      $getCurrentProcessId() & ".vstpreset")
    defer:
      if fileExists(target): removeFile(target)
    var opened = openFixture()
    require opened.isOk
    var instance = move(opened.value)
    let captured = instance.captureState()
    require captured.isOk
    require writeVst3Preset(target, ClassId, captured.value.component,
      captured.value.controller, captured.value.hasController).isOk
    let loaded = loadVst3Preset(target, ClassId)
    require loaded.isOk
    check loaded.value.component == captured.value.component
    check instance.close().isOk

  test "audio slice saves only after JACK processing is quiesced":
    let target = getTempDir() / ("pluginhost-vst3-v4a-slice-" &
      $getCurrentProcessId() & ".vstpreset")
    defer:
      if fileExists(target): removeFile(target)
    var controlsResult = openFakeJackControls()
    require controlsResult.isOk
    var controls = move(controlsResult.value)
    controls.reset()
    let services = newVst3PluginServices(newVst3HostContext())
    require services != nil
    var loaded = openVst3Module(fixturePath())
    require loaded.isOk
    var vst3Module = move(loaded.value)
    var parsedClass = parseVst3Uid(ClassId)
    require parsedClass.isOk
    let config = initJackBackendOpenConfig("vst3_v4a", noStartServer = true,
      libraryPath = jackFakeFixturePath())
    var opened = openVst3AudioSlice(services, vst3Module, parsedClass.value, config)
    require opened.isOk
    var slice = move(opened.value)
    let activeSave = slice.saveState(target)
    check not activeSave.isOk
    check activeSave.error.subsystem == hsState
    check slice.state == v3assActive
    require slice.stop().isOk
    require slice.saveState(target).isOk
    check getFilePermissions(target) == {fpUserRead, fpUserWrite}
    let loadedPreset = loadVst3Preset(target, ClassId)
    require loadedPreset.isOk
    check loadedPreset.value.component == @[uint8(0x56), 0x32, 0x41, 0x00]
    check slice.close().isOk
    check services.close().isOk
    check controls.close().isOk
