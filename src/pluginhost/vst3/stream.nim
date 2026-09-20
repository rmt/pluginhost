## Bounded seekable IBStream used for VST3 control-plane state exchange.
##
## The stream grows only to the requested size and never allocates beyond the
## host quota. It is deliberately independent of files and JACK processing.

import ./[ffi, uid]
import ../rt/atomic_pod

const
  Vst3MaxStreamRoots* = 256
  Vst3MaxStreamBytes* = 64 * 1024 * 1024
  Vst3StreamIid* = "C3BF6EA2309947529B6BF9901EE33E9B"
  Vst3SeekSet* = 0'i32
  Vst3SeekCurrent* = 1'i32
  Vst3SeekEnd* = 2'i32

type
  Vst3MemoryStreamState = object
    iface: Vst3BStream
    vtable: Vst3BStreamVtbl
    references: RtAtomicU32
    rootSlot: int32
    position: int64
    data: seq[uint8]

  Vst3MemoryStream* = ref Vst3MemoryStreamState

  StreamRootSlot = object
    value: Vst3MemoryStream
    state: RtAtomicU32

var streamRootSlots: array[Vst3MaxStreamRoots, StreamRootSlot]

proc streamState(thisInterface: pointer): ptr Vst3MemoryStreamState {.inline.} =
  cast[ptr Vst3MemoryStreamState](thisInterface)

proc incrementReferences(value: var RtAtomicU32): uint32 {.inline, gcsafe, raises: [].} =
  value.fetchAddRelaxed(1'u32) + 1'u32

proc decrementReferences(value: var RtAtomicU32): uint32 {.inline, gcsafe, raises: [].} =
  var expected = value.loadRelaxed()
  while expected > 0'u32:
    var observed = expected
    if value.compareExchangeRelaxed(observed, expected - 1'u32):
      return expected - 1'u32
    expected = observed
  0'u32

proc releaseStreamRoot(state: ptr Vst3MemoryStreamState) {.inline, raises: [].} =
  if state == nil or state.rootSlot < 0 or state.rootSlot >= Vst3MaxStreamRoots:
    return
  streamRootSlots[state.rootSlot].state.storeRelease(0'u32)

proc claimStreamRoot(stream: Vst3MemoryStream): int32 =
  for index in 0 ..< Vst3MaxStreamRoots:
    var expected = 0'u32
    if streamRootSlots[index].state.compareExchangeAcquire(expected, 2'u32):
      streamRootSlots[index].value = stream
      streamRootSlots[index].state.storeRelease(1'u32)
      return int32(index)
  -1

proc streamQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if state == nil or obj == nil or iid == nil or
      (parseVst3Uid(Vst3StreamIid).value != iid[] and
       parseVst3Uid(Vst3FUnknownIid).value != iid[]):
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = thisInterface
  discard incrementReferences(state.references)
  Vst3ResultOk

proc streamAddRef(thisInterface: pointer): uint32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if state == nil: return 0'u32
  incrementReferences(state.references)

proc streamRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let state = streamState(thisInterface)
  if state == nil: return 0'u32
  let remaining = decrementReferences(state.references)
  if remaining == 0'u32:
    releaseStreamRoot(state)
  remaining


proc streamRead(thisInterface: pointer; buffer: pointer; numBytes: int32;
                numBytesRead: ptr int32): int32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if state == nil or numBytes < 0 or (numBytes > 0 and buffer == nil):
    if numBytesRead != nil: numBytesRead[] = 0
    return Vst3ResultFalse
  let remaining = if state.position >= int64(state.data.len): 0 else:
    state.data.len - int(state.position)
  let count = min(remaining, int(numBytes))
  if count > 0:
    copyMem(buffer, addr state.data[int(state.position)], count)
    state.position += int64(count)
  if numBytesRead != nil: numBytesRead[] = int32(count)
  Vst3ResultOk

proc streamWrite(thisInterface: pointer; buffer: pointer; numBytes: int32;
                 numBytesWritten: ptr int32): int32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if state == nil or numBytes < 0 or (numBytes > 0 and buffer == nil):
    if numBytesWritten != nil: numBytesWritten[] = 0
    return Vst3ResultFalse
  if state.position < 0 or state.position > int64(Vst3MaxStreamBytes) or
      int64(numBytes) > int64(Vst3MaxStreamBytes) - state.position:
    if numBytesWritten != nil: numBytesWritten[] = 0
    return Vst3ResultFalse
  let endPosition = state.position + int64(numBytes)
  if endPosition > int64(state.data.len):
    state.data.setLen(int(endPosition))
  if numBytes > 0:
    copyMem(addr state.data[int(state.position)], buffer, int(numBytes))
  state.position = endPosition
  if numBytesWritten != nil: numBytesWritten[] = numBytes
  Vst3ResultOk
proc streamSeek(thisInterface: pointer; pos: int64; mode: int32;
                resultPosition: ptr int64): int32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if state == nil:
    return Vst3ResultFalse
  var base: int64
  case mode
  of Vst3SeekSet:
    base = 0
  of Vst3SeekCurrent:
    base = state.position
  of Vst3SeekEnd:
    base = int64(state.data.len)
  else:
    return Vst3ResultFalse
  let maximum = int64(Vst3MaxStreamBytes)
  if pos < -base or pos > maximum - base:
    return Vst3ResultFalse
  state.position = base + pos
  if resultPosition != nil: resultPosition[] = state.position
  Vst3ResultOk
proc streamTell(thisInterface: pointer; position: ptr int64): int32 {.
    cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if state == nil or position == nil: return Vst3ResultFalse
  position[] = state.position
  Vst3ResultOk

proc newVst3MemoryStream*(initial: openArray[uint8] = []): Vst3MemoryStream =
  if initial.len > Vst3MaxStreamBytes:
    return nil
  new(result)
  result.references.storeRelaxed(1'u32)
  result.rootSlot = -1
  result.data = newSeq[uint8](initial.len)
  if initial.len > 0:
    copyMem(addr result.data[0], unsafeAddr initial[0], initial.len)
  result.vtable = Vst3BStreamVtbl(
    queryInterface: streamQueryInterface, addRef: streamAddRef,
    release: streamRelease, read: streamRead, write: streamWrite,
    seek: streamSeek, tell: streamTell)
  result.iface.lpVtbl = addr result.vtable
  result.rootSlot = claimStreamRoot(result)
  if result.rootSlot < 0:
    return nil

proc streamRootCount*(): int =
  for slot in streamRootSlots.mitems:
    let state = slot.state.loadAcquire()
    if state == 1'u32:
      inc result
    elif state == 0'u32 and slot.value != nil:
      slot.value = nil

proc interfacePointer*(stream: Vst3MemoryStream): ptr Vst3BStream {.inline.} =
  if stream == nil: nil else: addr stream[].iface

proc referenceCount*(stream: Vst3MemoryStream): uint32 {.inline.} =
  if stream == nil: 0'u32 else: stream.references.loadAcquire()

proc hasRetainedReferences*(stream: Vst3MemoryStream): bool {.inline.} =
  stream != nil and stream.referenceCount() > 0'u32

proc rewind*(stream: Vst3MemoryStream): bool =
  if stream == nil: return false
  stream.position = 0
  true

proc clear*(stream: Vst3MemoryStream) =
  if stream == nil: return
  stream.data.setLen(0)
  stream.position = 0

proc size*(stream: Vst3MemoryStream): int {.inline.} =
  if stream == nil: 0 else: stream.data.len

proc bytes*(stream: Vst3MemoryStream): seq[uint8] =
  if stream == nil: return @[]
  result = newSeq[uint8](stream.data.len)
  if result.len > 0:
    copyMem(addr result[0], addr stream.data[0], result.len)
