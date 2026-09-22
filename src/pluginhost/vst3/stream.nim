## Bounded seekable IBStream used for VST3 control-plane state exchange.

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
  Vst3StreamMode* = enum
    vsmReadWrite
    vsmReadOnly

  Vst3StreamBuffer* = ref object
    data*: seq[uint8]

  Vst3MemoryStreamState = object
    iface: Vst3BStream
    vtable: Vst3BStreamVtbl
    references: RtAtomicU32
    rootSlot: int32
    position: int64
    mode: Vst3StreamMode
    capacity: int
    viewOffset: int
    viewSize: int
    failed: bool
    closed: RtAtomicU32
    backing: Vst3StreamBuffer

  Vst3MemoryStream* = ref Vst3MemoryStreamState

  StreamRootSlot = object
    value: Vst3MemoryStream
    state: RtAtomicU32

const
  Vst3StreamReadWrite* = vsmReadWrite
  Vst3StreamReadOnly* = vsmReadOnly

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
  if state == nil or state.rootSlot < 0 or state.rootSlot >= Vst3MaxStreamRoots: return
  streamRootSlots[state.rootSlot].state.storeRelease(0'u32)

proc claimStreamRoot(stream: Vst3MemoryStream): int32 =
  for index in 0 ..< Vst3MaxStreamRoots:
    var expected = 0'u32
    if streamRootSlots[index].state.compareExchangeAcquire(expected, 2'u32):
      streamRootSlots[index].value = stream
      streamRootSlots[index].state.storeRelease(1'u32)
      return int32(index)
  -1

proc markFailure(state: ptr Vst3MemoryStreamState): int32 {.inline, raises: [].} =
  if state != nil: state.failed = true
  Vst3ResultFalse

proc validLive(state: ptr Vst3MemoryStreamState): bool {.inline, raises: [].} =
  state != nil and state.closed.loadAcquire() == 0'u32 and
    state.references.loadAcquire() > 0'u32 and state.backing != nil

proc streamQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                          obj: ptr pointer): int32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if not validLive(state) or obj == nil or iid == nil or
      (parseVst3Uid(Vst3StreamIid).value != iid[] and
       parseVst3Uid(Vst3FUnknownIid).value != iid[]):
    if obj != nil: obj[] = nil
    return Vst3NoInterface
  obj[] = thisInterface
  discard incrementReferences(state.references)
  Vst3ResultOk

proc streamAddRef(thisInterface: pointer): uint32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if not validLive(state): return 0'u32
  incrementReferences(state.references)

proc streamRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let state = streamState(thisInterface)
  if state == nil: return 0'u32
  let remaining = decrementReferences(state.references)
  if remaining == 0'u32: releaseStreamRoot(state)
  remaining

proc streamRead(thisInterface: pointer; buffer: pointer; numBytes: int32;
                numBytesRead: ptr int32): int32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if numBytesRead != nil: numBytesRead[] = 0
  if not validLive(state) or numBytes < 0 or (numBytes > 0 and buffer == nil):
    return markFailure(state)
  if numBytes == 0: return Vst3ResultOk
  let remaining = if state.position < 0 or state.position >= int64(state.viewSize):
    0
  else: state.viewSize - int(state.position)
  let count = min(remaining, int(numBytes))
  if count > 0:
    copyMem(buffer, addr state.backing.data[state.viewOffset + int(state.position)], count)
    state.position += int64(count)
  if numBytesRead != nil: numBytesRead[] = int32(count)
  Vst3ResultOk

proc streamWrite(thisInterface: pointer; buffer: pointer; numBytes: int32;
                 numBytesWritten: ptr int32): int32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if numBytesWritten != nil: numBytesWritten[] = 0
  if not validLive(state) or state.mode != vsmReadWrite or numBytes < 0 or
      (numBytes > 0 and buffer == nil): return markFailure(state)
  if numBytes == 0: return Vst3ResultOk
  if state.position < 0 or state.position > int64(state.capacity) or
      int64(numBytes) > int64(state.capacity) - state.position:
    return markFailure(state)
  let endPosition = state.position + int64(numBytes)
  if endPosition > int64(high(int)): return markFailure(state)
  let needed = state.viewOffset + int(endPosition)
  if needed > state.backing.data.len: state.backing.data.setLen(needed)
  if endPosition > int64(state.viewSize): state.viewSize = int(endPosition)
  copyMem(addr state.backing.data[state.viewOffset + int(state.position)], buffer, int(numBytes))
  state.position = endPosition
  if numBytesWritten != nil: numBytesWritten[] = numBytes
  Vst3ResultOk

proc streamSeek(thisInterface: pointer; pos: int64; mode: int32;
                resultPosition: ptr int64): int32 {.cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if not validLive(state): return markFailure(state)
  var base: int64
  case mode
  of Vst3SeekSet: base = 0
  of Vst3SeekCurrent: base = state.position
  of Vst3SeekEnd: base = int64(state.viewSize)
  else: return markFailure(state)
  if base < 0 or pos < -base or pos > int64(state.capacity) - base:
    return markFailure(state)
  let next = base + pos
  if next < 0 or next > int64(state.capacity): return markFailure(state)
  state.position = next
  if resultPosition != nil: resultPosition[] = next
  Vst3ResultOk

proc streamTell(thisInterface: pointer; position: ptr int64): int32 {.
    cdecl, gcsafe, raises: [].} =
  let state = streamState(thisInterface)
  if not validLive(state) or position == nil: return markFailure(state)
  position[] = state.position
  Vst3ResultOk

proc initializeStream(backing: Vst3StreamBuffer; mode: Vst3StreamMode;
                      offset, size, capacity: int): Vst3MemoryStream =
  if backing == nil or offset < 0 or size < 0 or capacity < size or
      capacity > Vst3MaxStreamBytes or offset > backing.data.len - size: return nil
  new(result)
  result.references.storeRelaxed(1'u32)
  result.rootSlot = -1
  result.mode = mode
  result.capacity = capacity
  result.viewOffset = offset
  result.viewSize = size
  result.backing = backing
  result.vtable = Vst3BStreamVtbl(queryInterface: streamQueryInterface,
    addRef: streamAddRef, release: streamRelease, read: streamRead,
    write: streamWrite, seek: streamSeek, tell: streamTell)
  result.iface.lpVtbl = addr result.vtable
  result.rootSlot = claimStreamRoot(result)
  if result.rootSlot < 0: return nil

proc newVst3SharedBuffer*(initial: openArray[uint8]): Vst3StreamBuffer =
  if initial.len > Vst3MaxStreamBytes: return nil
  new(result)
  result.data = newSeq[uint8](initial.len)
  if initial.len > 0: copyMem(addr result.data[0], unsafeAddr initial[0], initial.len)

proc newVst3MemoryStream*(initial: openArray[uint8] = [];
                          mode = vsmReadWrite;
                          maximum = Vst3MaxStreamBytes): Vst3MemoryStream =
  if initial.len > maximum or maximum > Vst3MaxStreamBytes: return nil
  var backing = newVst3SharedBuffer(initial)
  initializeStream(backing, mode, 0, initial.len, maximum)

proc newVst3MemoryStream*(mode: Vst3StreamMode;
                          initial: openArray[uint8] = [];
                          maximum = Vst3MaxStreamBytes): Vst3MemoryStream =
  newVst3MemoryStream(initial, mode, maximum)

proc newVst3ReadOnlyStream*(initial: openArray[uint8]): Vst3MemoryStream =
  newVst3MemoryStream(initial, vsmReadOnly, initial.len)

proc newVst3ReadOnlyView*(backing: Vst3StreamBuffer; offset, size: int): Vst3MemoryStream =
  initializeStream(backing, vsmReadOnly, offset, size, size)

proc streamRootCount*(): int =
  for slot in streamRootSlots.mitems:
    let state = slot.state.loadAcquire()
    if state == 1'u32: inc result
    elif state == 0'u32 and slot.value != nil: slot.value = nil

proc interfacePointer*(stream: Vst3MemoryStream): ptr Vst3BStream {.inline.} =
  if stream == nil: nil else: addr stream[].iface
proc referenceCount*(stream: Vst3MemoryStream): uint32 {.inline.} =
  if stream == nil: 0'u32 else: stream.references.loadAcquire()
proc hasRetainedReferences*(stream: Vst3MemoryStream): bool {.inline.} =
  stream != nil and stream.referenceCount() > 0'u32
proc failed*(stream: Vst3MemoryStream): bool {.inline.} = stream != nil and stream.failed
proc closed*(stream: Vst3MemoryStream): bool {.inline.} =
  stream == nil or stream.closed.loadAcquire() != 0'u32
proc mode*(stream: Vst3MemoryStream): Vst3StreamMode {.inline.} =
  if stream == nil: vsmReadOnly else: stream.mode
proc capacity*(stream: Vst3MemoryStream): int {.inline.} =
  if stream == nil: 0 else: stream.capacity
proc close*(stream: Vst3MemoryStream): bool =
  if stream == nil or stream.closed.loadAcquire() != 0'u32: return true
  stream.closed.storeRelease(1'u32)
  discard stream.interfacePointer().lpVtbl.release(cast[pointer](stream.interfacePointer()))
  true

proc rewind*(stream: Vst3MemoryStream): bool =
  if stream == nil or stream.closed.loadAcquire() != 0'u32: return false
  stream.position = 0
  true
proc clear*(stream: Vst3MemoryStream): bool =
  if stream == nil or stream.closed.loadAcquire() != 0'u32 or
      stream.mode != vsmReadWrite:
    if stream != nil: stream.failed = true
    return false
  stream.backing.data.setLen(stream.viewOffset)
  stream.viewSize = 0
  stream.position = 0
  true
proc size*(stream: Vst3MemoryStream): int {.inline.} =
  if stream == nil: 0 else: stream.viewSize
proc bytes*(stream: Vst3MemoryStream): seq[uint8] =
  if stream == nil: return @[]
  result = newSeq[uint8](stream.viewSize)
  if result.len > 0: copyMem(addr result[0], addr stream.backing.data[stream.viewOffset], result.len)
