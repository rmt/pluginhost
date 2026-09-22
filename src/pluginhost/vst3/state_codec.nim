## Bounded standard VST3 version-1 preset container and atomic file transaction.
## Raw VST3 calls remain in instance.nim; this module only owns bytes/files.

import std/[os, posix, strutils]

import ../domain/[errors, result]
import ./uid

proc cRename(oldPath, newPath: cstring): cint {.importc: "rename", header: "stdio.h".}

const
  Vst3PresetHeaderBytes* = 48
  Vst3PresetListHeaderBytes* = 8
  Vst3PresetEntryBytes* = 20
  Vst3PresetTransferBytes* = 64 * 1024
  Vst3PresetMaximumBytes* = 64 * 1024 * 1024
  Vst3PresetMaximumChunks* = 128
  Vst3PresetVersion* = 1'u32
  Vst3PresetComponentId* = "Comp"
  Vst3PresetControllerId* = "Cont"
  Vst3PresetInfoId* = "Info"
  TempNameAttempts = 64
  LinuxONoFollow = 0x0002_0000.cint

type
  Vst3PresetChunk* = object
    id*: string
    offset*: int64
    size*: int64
    data*: seq[uint8]

  Vst3Preset* = object
    classId*: string
    component*: seq[uint8]
    controller*: seq[uint8]
    hasController*: bool
    componentOffset*: int
    controllerOffset*: int
    raw*: seq[uint8]
    chunks*: seq[Vst3PresetChunk]

  Vst3PresetOutput = object
    target: string
    temporary: string
    fd: cint
    committed: bool

proc presetError(message: string; path = ""; detail = ""): HostError =
  var context = ""
  if path.len > 0: context = "path=" & path
  if detail.len > 0:
    if context.len > 0: context.add("; ")
    context.add(detail)
  hostError(hsState, hekState, message, context)

proc u32At(bytes: openArray[uint8]; offset: int): uint32 {.inline.} =
  uint32(bytes[offset]) or (uint32(bytes[offset + 1]) shl 8) or
    (uint32(bytes[offset + 2]) shl 16) or (uint32(bytes[offset + 3]) shl 24)

proc i64At(bytes: openArray[uint8]; offset: int): int64 {.inline.} =
  var value: uint64
  for index in 0 ..< 8:
    value = value or (uint64(bytes[offset + index]) shl (8 * index))
  cast[int64](value)

proc putU32(bytes: var seq[uint8]; offset: int; value: uint32) {.inline.} =
  for index in 0 ..< 4:
    bytes[offset + index] = uint8(value shr (8 * index))

proc putI64(bytes: var seq[uint8]; offset: int; value: int64) {.inline.} =
  let raw = cast[uint64](value)
  for index in 0 ..< 8:
    bytes[offset + index] = uint8(raw shr (8 * index))

proc hasText(bytes: openArray[uint8]; offset, count: int; value: string): bool =
  if count != value.len: return false
  for index in 0 ..< count:
    if bytes[offset + index] != uint8(ord(value[index])): return false
  true

proc copyRange(bytes: openArray[uint8]; offset, count: int): seq[uint8] =
  result = newSeq[uint8](count)
  if count > 0: copyMem(addr result[0], unsafeAddr bytes[offset], count)

proc parseVst3Preset*(bytes: openArray[uint8]; selectedClassId: string):
    Result[Vst3Preset] =
  if bytes.len > Vst3PresetMaximumBytes:
    return failure[Vst3Preset](presetError("VST3 preset exceeds host bound"))
  if bytes.len < Vst3PresetHeaderBytes:
    return failure[Vst3Preset](presetError("VST3 preset header is truncated"))
  if not hasText(bytes, 0, 4, "VST3"):
    return failure[Vst3Preset](presetError("VST3 preset magic is invalid"))
  if u32At(bytes, 4) != Vst3PresetVersion:
    return failure[Vst3Preset](presetError("VST3 preset version is unsupported"))
  var cid = newString(32)
  for index in 0 ..< 32:
    let value = bytes[8 + index]
    if not ((value >= uint8(ord('0')) and value <= uint8(ord('9'))) or
            (value >= uint8(ord('A')) and value <= uint8(ord('F')))):
      return failure[Vst3Preset](presetError("VST3 preset processor CID is invalid"))
    cid[index] = char(value)
  let parsedCid = parseVst3Uid(cid)
  if not parsedCid.isOk or formatVst3Uid(parsedCid.value) != cid:
    return failure[Vst3Preset](presetError("VST3 preset processor CID is invalid"))
  if selectedClassId.len != 32 or cid != selectedClassId:
    return failure[Vst3Preset](presetError(
      "VST3 preset processor CID does not match selected processor",
      detail = "preset-cid=" & cid & "; selected-cid=" & selectedClassId))

  let listOffset = i64At(bytes, 40)
  if listOffset < int64(Vst3PresetHeaderBytes) or
      listOffset > int64(bytes.len - Vst3PresetListHeaderBytes):
    return failure[Vst3Preset](presetError("VST3 preset chunk list offset is out of bounds"))
  let listStart = int(listOffset)
  if not hasText(bytes, listStart, 4, "List"):
    return failure[Vst3Preset](presetError("VST3 preset chunk list magic is invalid"))
  let count = u32At(bytes, listStart + 4)
  if count == 0'u32 or count > uint32(Vst3PresetMaximumChunks):
    return failure[Vst3Preset](presetError("VST3 preset chunk count is invalid"))
  var componentSeen = false
  var controllerSeen = false
  let tableBytes = int64(Vst3PresetListHeaderBytes) +
    int64(count) * int64(Vst3PresetEntryBytes)
  if tableBytes < 0 or listOffset > int64(bytes.len) - tableBytes or
      listOffset + tableBytes != int64(bytes.len):
    return failure[Vst3Preset](
      presetError("VST3 preset chunk table is truncated or non-terminal"))

  var preset = Vst3Preset(classId: cid, chunks: @[],
    raw: copyRange(bytes, 0, bytes.len))
  for index in 0 ..< int(count):
    let entry = listStart + Vst3PresetListHeaderBytes +
      index * Vst3PresetEntryBytes
    var id = newString(4)
    for byteIndex in 0 ..< 4:
      id[byteIndex] = char(bytes[entry + byteIndex])
    let offset = i64At(bytes, entry + 4)
    let size = i64At(bytes, entry + 12)
    if offset < int64(Vst3PresetHeaderBytes) or size < 0 or
        offset > listOffset or size > listOffset - offset:
      return failure[Vst3Preset](presetError(
        "VST3 preset chunk bounds are invalid", detail = "chunk=" & id))
    for prior in preset.chunks:
      if size > 0 and prior.size > 0 and
          offset < prior.offset + prior.size and
          prior.offset < offset + size:
        return failure[Vst3Preset](presetError(
          "VST3 preset chunks overlap", detail = "chunk=" & id))
    if id == Vst3PresetComponentId and componentSeen:
      return failure[Vst3Preset](presetError(
        "VST3 preset contains duplicate Comp chunk"))
    if id == Vst3PresetControllerId and controllerSeen:
      return failure[Vst3Preset](presetError(
        "VST3 preset contains duplicate Cont chunk"))
    # Unknown bounded chunks, including standard Info metadata, are preserved
    # but not interpreted. This keeps version-1 presets forward-compatible.
    let chunk = Vst3PresetChunk(id: id, offset: offset, size: size,
      data: copyRange(bytes, int(offset), int(size)))
    preset.chunks.add(chunk)
    if id == Vst3PresetComponentId:
      componentSeen = true
      preset.componentOffset = int(offset)
      preset.component = chunk.data
    elif id == Vst3PresetControllerId:
      controllerSeen = true
      preset.controllerOffset = int(offset)
      preset.controller = chunk.data
      preset.hasController = true
  if not componentSeen:
    return failure[Vst3Preset](presetError(
      "VST3 preset has no required Comp chunk"))
  success(move(preset))

proc serializeVst3Preset*(classId: string; component: openArray[uint8];
                          controller: openArray[uint8] = [];
                          includeController = false): Result[seq[uint8]] =
  let parsed = parseVst3Uid(classId)
  if not parsed.isOk or formatVst3Uid(parsed.value) != classId:
    return failure[seq[uint8]](presetError("VST3 preset processor CID is invalid",
      detail = "selected-cid=" & classId))
  if component.len > Vst3PresetMaximumBytes or controller.len > Vst3PresetMaximumBytes or
      component.len + (if includeController: controller.len else: 0) > Vst3PresetMaximumBytes:
    return failure[seq[uint8]](presetError("VST3 preset chunk exceeds host bound"))
  let count = if includeController: 2 else: 1
  let listOffset64 = int64(Vst3PresetHeaderBytes) + int64(component.len) +
    (if includeController: int64(controller.len) else: 0)
  let total64 = listOffset64 + int64(Vst3PresetListHeaderBytes) +
    int64(count) * int64(Vst3PresetEntryBytes)
  if total64 > int64(Vst3PresetMaximumBytes) or total64 > int64(high(int)):
    return failure[seq[uint8]](presetError("VST3 preset exceeds host bound"))
  var bytes = newSeq[uint8](int(total64))
  for index in 0 ..< 4:
    bytes[index] = uint8(ord("VST3"[index]))
  putU32(bytes, 4, Vst3PresetVersion)
  for index in 0 ..< 32:
    bytes[8 + index] = uint8(ord(classId[index]))
  putI64(bytes, 40, listOffset64)
  if component.len > 0:
    copyMem(addr bytes[Vst3PresetHeaderBytes], unsafeAddr component[0],
      component.len)
  let controllerOffset = Vst3PresetHeaderBytes + component.len
  if includeController and controller.len > 0:
    copyMem(addr bytes[controllerOffset], unsafeAddr controller[0],
      controller.len)
  let listOffset = int(listOffset64)
  for index in 0 ..< 4:
    bytes[listOffset + index] = uint8(ord("List"[index]))
  putU32(bytes, listOffset + 4, uint32(count))
  var entry = listOffset + Vst3PresetListHeaderBytes
  for index in 0 ..< 4:
    bytes[entry + index] = uint8(ord(Vst3PresetComponentId[index]))
  putI64(bytes, entry + 4, int64(Vst3PresetHeaderBytes))
  putI64(bytes, entry + 12, int64(component.len))
  if includeController:
    entry += Vst3PresetEntryBytes
    for index in 0 ..< 4:
      bytes[entry + index] = uint8(ord(Vst3PresetControllerId[index]))
    putI64(bytes, entry + 4, int64(controllerOffset))
    putI64(bytes, entry + 12, int64(controller.len))
  success(move(bytes))

proc readVst3PresetFile(path: string): Result[seq[uint8]] =
  if path.len == 0 or path.find('\0') >= 0:
    return failure[seq[uint8]](presetError("VST3 preset input path is invalid", path))
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC or LinuxONoFollow)
  if fd < 0: return failure[seq[uint8]](presetError("could not open VST3 preset", path))
  var bytes: seq[uint8] = @[]
  var buffer: array[Vst3PresetTransferBytes, uint8]
  var failed = false
  while true:
    let got = posix.read(fd, addr buffer[0], Vst3PresetTransferBytes)
    if got == 0: break
    if got < 0:
      if osLastError() == OSErrorCode(EINTR): continue
      failed = true; break
    if bytes.len > Vst3PresetMaximumBytes - got:
      failed = true; break
    let oldLen = bytes.len
    bytes.setLen(oldLen + got)
    copyMem(addr bytes[oldLen], addr buffer[0], got)
  let closed = posix.close(fd) == 0
  if failed or not closed:
    return failure[seq[uint8]](presetError("could not read VST3 preset", path))
  success(move(bytes))

proc loadVst3Preset*(path, selectedClassId: string): Result[Vst3Preset] =
  var bytes = readVst3PresetFile(path)
  if not bytes.isOk: return failure[Vst3Preset](move(bytes.error))
  parseVst3Preset(bytes.value, selectedClassId)

proc openPresetOutput(target: string): Result[Vst3PresetOutput] =
  if target.len == 0 or target.find('\0') >= 0:
    return failure[Vst3PresetOutput](presetError("VST3 preset output path is invalid", target))
  let parent = if target.splitFile.dir.len == 0: "." else: target.splitFile.dir
  let base = target.splitFile.name & target.splitFile.ext
  for attempt in 0 ..< TempNameAttempts:
    let temporary = parent / ("." & base & ".pluginhost-vst3-state-" &
      $int(getpid()) & "-" & $attempt & ".tmp")
    let fd = posix.open(temporary.cstring,
      O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC or LinuxONoFollow,
      Mode(S_IRUSR or S_IWUSR))
    if fd >= 0:
      if fchmod(fd, Mode(S_IRUSR or S_IWUSR)) != 0:
        discard posix.close(fd)
        discard posix.unlink(temporary.cstring)
        return failure[Vst3PresetOutput](presetError(
          "could not set VST3 preset temporary file permissions", temporary))
      return success(Vst3PresetOutput(
        target: target, temporary: temporary, fd: fd))
    if osLastError() != OSErrorCode(EEXIST):
      return failure[Vst3PresetOutput](presetError(
        "could not create VST3 preset temporary file", temporary))
  failure[Vst3PresetOutput](presetError("could not allocate unique VST3 preset temporary file", target))

proc rollback(output: var Vst3PresetOutput) =
  if output.fd >= 0: discard posix.close(output.fd); output.fd = -1
  if not output.committed and output.temporary.len > 0: discard posix.unlink(output.temporary.cstring)

proc writeVst3Preset*(path, classId: string; component: openArray[uint8];
                      controller: openArray[uint8] = [];
                      includeController = false): Result[Unit] =
  var serialized = serializeVst3Preset(classId, component, controller,
    includeController)
  if not serialized.isOk: return failure[Unit](move(serialized.error))
  var output = openPresetOutput(path)
  if not output.isOk: return failure[Unit](move(output.error))
  var state = move(output.value)
  var written = 0
  while written < serialized.value.len:
    let amount = min(Vst3PresetTransferBytes, serialized.value.len - written)
    let count = posix.write(state.fd, unsafeAddr serialized.value[written], amount)
    if count < 0 and osLastError() == OSErrorCode(EINTR): continue
    if count <= 0:
      let error = presetError("could not write VST3 preset temporary file", state.temporary)
      state.rollback()
      return failure[Unit](error)
    written += count
  if fsync(state.fd) != 0:
    let error = presetError("could not synchronize VST3 preset temporary file", state.temporary)
    state.rollback(); return failure[Unit](error)
  if posix.close(state.fd) != 0:
    state.fd = -1
    let error = presetError("could not close VST3 preset temporary file", state.temporary)
    state.rollback(); return failure[Unit](error)
  state.fd = -1
  if cRename(state.temporary.cstring, path.cstring) != 0:
    let error = presetError("could not atomically publish VST3 preset", path)
    state.rollback(); return failure[Unit](error)
  state.committed = true
  state.temporary.setLen(0)
  success()


proc readVst3Preset*(bytes: openArray[uint8]; selectedClassId: string):
    Result[Vst3Preset] =
  parseVst3Preset(bytes, selectedClassId)

proc serializeVst3PresetFile*(classId: string; component: openArray[uint8];
                             controller: openArray[uint8] = [];
                             includeController = false): Result[seq[uint8]] =
  serializeVst3Preset(classId, component, controller, includeController)