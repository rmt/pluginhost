## Bounded main/control-plane VST3 IMessage and IAttributeList objects.
##
## The objects copy all caller-owned inputs. Their storage remains stable for
## borrowed getters until the next mutation of that object. The object store
## limits live objects and aggregate copied payload per plugin instance.

import std/[locks, posix]

import ./[ffi, uid]
const
  Vst3MaxLiveObjects* = 256
  Vst3MaxAttributesPerList* = 256
  Vst3MaxAttributeKeyBytes* = 1024
  Vst3MaxAttributeTextBytes* = 64 * 1024
  Vst3MaxAttributeBinaryBytes* = 1 * 1024 * 1024
  Vst3MaxAggregateAttributeBytes* = 1 * 1024 * 1024

  Vst3MessageIid* = "936F033BC6C047DBBB0882F813C1E613"
  Vst3AttributeListIid* = "1E5F0AEBCC7F4533A254401138AD5EE4"

# Managed roots live in the owning store; ABI-facing state keeps raw owner
# pointers so foreign releases do not mutate Nim reference counts.
type
  Vst3AttributeKind* = enum
    vakInt
    vakFloat
    vakString
    vakBinary

  Vst3AttributeValue* = object
    key*: string
    kind*: Vst3AttributeKind
    intValue*: int64
    floatValue*: float64
    stringValue*: seq[uint16]
    binaryValue*: seq[uint8]

  Vst3ControlObjectStoreState = object
    lock: Lock
    lockInitialized: bool
    closed: bool
    liveObjects*: int
    payloadBytes*: uint64
    mainThread: Pthread
    attributes: seq[Vst3AttributeObject]
    messages: seq[Vst3MessageObject]

  Vst3ControlObjectStore* = ref Vst3ControlObjectStoreState

  Vst3AttributeListState = object
    iface: Vst3AttributeList
    vtable: Vst3AttributeListVtbl
    owner: ptr Vst3ControlObjectStoreState
    references: int32
    values: seq[Vst3AttributeValue]

  Vst3AttributeObject* = ref Vst3AttributeListState

  Vst3MessageState = object
    iface: Vst3Message
    vtable: Vst3MessageVtbl
    owner: ptr Vst3ControlObjectStoreState
    attributes: ptr Vst3AttributeListState
    references: int32
    messageId: string
    messageIdBytes: uint64
  Vst3MessageObject* = ref Vst3MessageState

proc objectKey(id: cstring; key: var string): bool {.raises: [].} =
  if id == nil:
    return false
  let bytes = cast[ptr UncheckedArray[char]](id)
  var length = 0
  while length < Vst3MaxAttributeKeyBytes and bytes[length] != '\0':
    inc length
  if length == 0 or length == Vst3MaxAttributeKeyBytes:
    return false
  key = newString(length)
  copyMem(addr key[0], addr bytes[0], length)
  true

proc copyUtf16(value: ptr Vst3TChar; output: var seq[uint16]): bool {.raises: [].} =
  if value == nil:
    return false
  let units = cast[ptr UncheckedArray[uint16]](value)
  var length = 0
  let maxUnits = Vst3MaxAttributeTextBytes div sizeof(uint16)
  while length < maxUnits and units[length] != 0'u16:
    inc length
  if length == maxUnits:
    return false
  output = newSeq[uint16](length + 1)
  if length > 0:
    copyMem(addr output[0], addr units[0], length * sizeof(uint16))
  output[length] = 0'u16
  true

proc copyBinary(data: pointer; size: uint32; output: var seq[uint8]): bool {.raises: [].} =
  if size > uint32(Vst3MaxAttributeBinaryBytes) or
      (size > 0'u32 and data == nil):
    return false
  output = newSeq[uint8](int(size))
  if size > 0:
    copyMem(addr output[0], data, int(size))
  true

proc valueBytes(value: Vst3AttributeValue): uint64 {.inline, raises: [].} =
  case value.kind
  of vakInt, vakFloat:
    uint64(value.key.len)
  of vakString:
    uint64(value.key.len + value.stringValue.len * sizeof(uint16))
  of vakBinary:
    uint64(value.key.len + value.binaryValue.len)

proc initVst3ControlObjectStore*(): Vst3ControlObjectStore =
  new(result)
  initLock(result.lock)
  result.lockInitialized = true
  result.mainThread = pthread_self()

proc onMainThread(store: Vst3ControlObjectStore): bool {.inline, raises: [].} =
  store != nil and pthread_equal(pthread_self(), store.mainThread) != 0

proc reclaimVst3ControlObjectStore*(store: Vst3ControlObjectStore) {.
    raises: [].} =
  ## Final release may arrive on a foreign plugin thread. Keep those managed
  ## objects rooted until the owning control thread explicitly reclaims them.
  if store == nil or not store.lockInitialized or not store.onMainThread():
    return
  acquire(store.lock)
  for index in countdown(store.attributes.high, 0):
    if store.attributes[index].references <= 0:
      store.attributes.delete(index)
  for index in countdown(store.messages.high, 0):
    if store.messages[index].references <= 0:
      store.messages.delete(index)
  release(store.lock)

proc close*(store: Vst3ControlObjectStore) {.raises: [].} =
  if store == nil or not store.lockInitialized:
    return
  acquire(store.lock)
  store.closed = true
  release(store.lock)
  store.reclaimVst3ControlObjectStore()
  acquire(store.lock)
  let canDeinit = store.liveObjects == 0 and store.attributes.len == 0 and
    store.messages.len == 0 and store.onMainThread()
  release(store.lock)
  if canDeinit:
    deinitLock(store.lock)
    store.lockInitialized = false

proc retainObject(store: Vst3ControlObjectStore): bool {.raises: [].} =
  if store == nil or not store.lockInitialized:
    return false
  acquire(store.lock)
  if store.closed or store.liveObjects >= Vst3MaxLiveObjects:
    release(store.lock)
    return false
  inc store.liveObjects
  release(store.lock)
  true

proc releaseObject(store: ptr Vst3ControlObjectStoreState) {.raises: [].} =
  if store == nil or not store.lockInitialized:
    return
  acquire(store.lock)
  if store.liveObjects > 0:
    dec store.liveObjects
  release(store.lock)

proc registerAttribute(store: Vst3ControlObjectStore;
                       value: Vst3AttributeObject) {.raises: [].} =
  acquire(store.lock)
  store.attributes.add(value)
  release(store.lock)

proc registerMessage(store: Vst3ControlObjectStore;
                     value: Vst3MessageObject) {.raises: [].} =
  acquire(store.lock)
  store.messages.add(value)
  release(store.lock)


proc uidMatches(iid: ptr Vst3Tuid; text: string): bool {.inline, raises: [].} =
  if iid == nil:
    return false
  let parsed = parseVst3Uid(text)
  parsed.isOk and parsed.value == iid[]

proc attrState(thisInterface: pointer): ptr Vst3AttributeListState {.inline.} =
  cast[ptr Vst3AttributeListState](thisInterface)

proc messageState(thisInterface: pointer): ptr Vst3MessageState {.inline.} =
  cast[ptr Vst3MessageState](thisInterface)


proc attrQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                        obj: ptr pointer): int32 {.cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  if obj != nil: obj[] = nil
  if state == nil or obj == nil or
      (not uidMatches(iid, Vst3AttributeListIid) and
       not uidMatches(iid, Vst3FUnknownIid)):
    return Vst3NoInterface
  let owner = state.owner
  if owner == nil or not owner.lockInitialized:
    return Vst3NoInterface
  acquire(owner.lock)
  if state.references <= 0:
    release(owner.lock)
    return Vst3NoInterface
  inc state.references
  release(owner.lock)
  obj[] = thisInterface
  Vst3ResultOk

proc attrAddRef(thisInterface: pointer): uint32 {.cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  if state == nil or state.owner == nil or not state.owner.lockInitialized:
    return 0'u32
  acquire(state.owner.lock)
  if state.references > 0:
    inc state.references
  let count = uint32(state.references)
  release(state.owner.lock)
  count

proc attrRelease(thisInterface: pointer): uint32 {.cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  if state == nil or state.owner == nil or not state.owner.lockInitialized:
    return 0'u32
  let owner = state.owner
  acquire(owner.lock)
  if state.references <= 0:
    release(owner.lock)
    return 0'u32
  dec state.references
  let remaining = uint32(state.references)
  if state.references == 0:
    for value in state.values:
      let bytes = valueBytes(value)
      if owner.payloadBytes >= bytes:
        owner.payloadBytes -= bytes
      else:
        owner.payloadBytes = 0
  release(owner.lock)
  if remaining == 0'u32:
    releaseObject(owner)
  remaining

proc findAttribute(state: ptr Vst3AttributeListState; key: string): int {.inline.} =
  for index, value in state.values:
    if value.key == key: return index
  -1
proc replaceValue(state: ptr Vst3AttributeListState;
                  value: sink Vst3AttributeValue): int32 {.raises: [].} =
  let owner = state.owner
  if owner == nil or not owner.lockInitialized:
    return Vst3ResultFalse
  acquire(owner.lock)
  if state.references <= 0:
    release(owner.lock)
    return Vst3ResultFalse
  let index = state.findAttribute(value.key)
  let oldBytes = if index >= 0 and index < state.values.len:
      valueBytes(state.values[index])
    else: 0'u64
  let newBytes = valueBytes(value)
  let retainedBytes = if owner.payloadBytes >= oldBytes:
      owner.payloadBytes - oldBytes
    else: 0'u64
  if index < 0 and state.values.len >= Vst3MaxAttributesPerList:
    release(owner.lock)
    return Vst3ResultFalse
  if newBytes > Vst3MaxAggregateAttributeBytes.uint64 or
      retainedBytes > Vst3MaxAggregateAttributeBytes.uint64 - newBytes:
    release(owner.lock)
    return Vst3ResultFalse
  if index >= 0 and index < state.values.len:
    state.values[index] = move(value)
  else:
    state.values.add(move(value))
  owner.payloadBytes = owner.payloadBytes - oldBytes + newBytes
  release(owner.lock)
  Vst3ResultOk

proc attrSetInt(thisInterface: pointer; id: cstring; value: int64): int32 {.
    cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  var key: string
  if state == nil or not objectKey(id, key): return Vst3ResultFalse
  state.replaceValue(Vst3AttributeValue(key: key, kind: vakInt, intValue: value))

proc attrGetInt(thisInterface: pointer; id: cstring; value: ptr int64): int32 {.
    cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  var key: string
  if state == nil or value == nil or not objectKey(id, key): return Vst3ResultFalse
  let owner = state.owner
  if owner == nil or not owner.lockInitialized: return Vst3ResultFalse
  acquire(owner.lock)
  defer: release(owner.lock)
  if state.references <= 0: return Vst3ResultFalse
  let index = state.findAttribute(key)
  if index < 0 or state.values[index].kind != vakInt: return Vst3ResultFalse
  value[] = state.values[index].intValue
  Vst3ResultOk

proc attrSetFloat(thisInterface: pointer; id: cstring; value: float64): int32 {.
    cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  var key: string
  if state == nil or not objectKey(id, key): return Vst3ResultFalse
  state.replaceValue(Vst3AttributeValue(key: key, kind: vakFloat, floatValue: value))

proc attrGetFloat(thisInterface: pointer; id: cstring; value: ptr float64): int32 {.
    cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  var key: string
  if state == nil or value == nil or not objectKey(id, key): return Vst3ResultFalse
  let owner = state.owner
  if owner == nil or not owner.lockInitialized: return Vst3ResultFalse
  acquire(owner.lock)
  defer: release(owner.lock)
  if state.references <= 0: return Vst3ResultFalse
  let index = state.findAttribute(key)
  if index < 0 or state.values[index].kind != vakFloat: return Vst3ResultFalse
  value[] = state.values[index].floatValue
  Vst3ResultOk

proc attrSetString(thisInterface: pointer; id: cstring; value: ptr Vst3TChar): int32 {.
    cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  var key: string
  var copied: seq[uint16]
  if state == nil or not objectKey(id, key) or not copyUtf16(value, copied):
    return Vst3ResultFalse
  state.replaceValue(Vst3AttributeValue(key: key, kind: vakString,
                                        stringValue: move(copied)))

proc attrGetString(thisInterface: pointer; id: cstring; value: ptr Vst3TChar;
                   sizeInBytes: uint32): int32 {.cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  var key: string
  if state == nil or value == nil or not objectKey(id, key): return Vst3ResultFalse
  let owner = state.owner
  if owner == nil or not owner.lockInitialized: return Vst3ResultFalse
  acquire(owner.lock)
  defer: release(owner.lock)
  if state.references <= 0: return Vst3ResultFalse
  let index = state.findAttribute(key)
  if index < 0 or state.values[index].kind != vakString: return Vst3ResultFalse
  let source = state.values[index].stringValue
  let needed = uint64(source.len * sizeof(uint16))
  if uint64(sizeInBytes) < needed: return Vst3ResultFalse
  copyMem(value, addr source[0], int(needed))
  Vst3ResultOk

proc attrSetBinary(thisInterface: pointer; id: cstring; data: pointer;
                   sizeInBytes: uint32): int32 {.cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  var key: string
  var copied: seq[uint8]
  if state == nil or not objectKey(id, key) or
      not copyBinary(data, sizeInBytes, copied):
    return Vst3ResultFalse
  state.replaceValue(Vst3AttributeValue(key: key, kind: vakBinary,
                                        binaryValue: move(copied)))

proc attrGetBinary(thisInterface: pointer; id: cstring; data: ptr pointer;
                   sizeInBytes: ptr uint32): int32 {.cdecl, gcsafe, raises: [].} =
  let state = attrState(thisInterface)
  var key: string
  if state == nil or data == nil or sizeInBytes == nil or not objectKey(id, key):
    return Vst3ResultFalse
  let owner = state.owner
  if owner == nil or not owner.lockInitialized: return Vst3ResultFalse
  acquire(owner.lock)
  defer: release(owner.lock)
  if state.references <= 0: return Vst3ResultFalse
  let index = state.findAttribute(key)
  if index < 0 or state.values[index].kind != vakBinary: return Vst3ResultFalse
  let source = state.values[index].binaryValue
  data[] = if source.len == 0: nil else: cast[pointer](addr source[0])
  sizeInBytes[] = uint32(source.len)
  Vst3ResultOk

proc messageQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                           obj: ptr pointer): int32 {.cdecl, gcsafe, raises: [].} =
  let state = messageState(thisInterface)
  if obj != nil: obj[] = nil
  if state == nil or obj == nil or
      (not uidMatches(iid, Vst3MessageIid) and
       not uidMatches(iid, Vst3FUnknownIid)):
    return Vst3NoInterface
  let owner = state.owner
  if owner == nil or not owner.lockInitialized:
    return Vst3NoInterface
  acquire(owner.lock)
  if state.references <= 0:
    release(owner.lock)
    return Vst3NoInterface
  inc state.references
  release(owner.lock)
  obj[] = thisInterface
  Vst3ResultOk

proc messageAddRef(thisInterface: pointer): uint32 {.cdecl, gcsafe, raises: [].} =
  let state = messageState(thisInterface)
  if state == nil or state.owner == nil or not state.owner.lockInitialized:
    return 0'u32
  acquire(state.owner.lock)
  if state.references > 0:
    inc state.references
  let count = uint32(state.references)
  release(state.owner.lock)
  count

proc messageRelease(thisInterface: pointer): uint32 {.cdecl, gcsafe, raises: [].} =
  let state = messageState(thisInterface)
  if state == nil or state.owner == nil or not state.owner.lockInitialized:
    return 0'u32
  let owner = state.owner
  var attributes: ptr Vst3AttributeListState
  acquire(owner.lock)
  if state.references <= 0:
    release(owner.lock)
    return 0'u32
  dec state.references
  let remaining = uint32(state.references)
  if state.references == 0:
    if owner.payloadBytes >= state.messageIdBytes:
      owner.payloadBytes -= state.messageIdBytes
    else:
      owner.payloadBytes = 0
    state.messageIdBytes = 0
    attributes = state.attributes
    state.attributes = nil
  release(owner.lock)
  if remaining == 0'u32:
    if attributes != nil:
      discard attrRelease(cast[pointer](addr attributes[].iface))
    releaseObject(owner)
  remaining
proc messageGetId(thisInterface: pointer): cstring {.cdecl, gcsafe, raises: [].} =
  let state = messageState(thisInterface)
  if state == nil: return nil
  let owner = state.owner
  if owner == nil or not owner.lockInitialized: return nil
  acquire(owner.lock)
  if state.references > 0:
    result = state.messageId.cstring
  release(owner.lock)

proc messageSetId(thisInterface: pointer; id: cstring) {.cdecl, gcsafe, raises: [].} =
  let state = messageState(thisInterface)
  if state == nil or id == nil: return
  var copied: string
  if not objectKey(id, copied): return
  let owner = state.owner
  if owner == nil or not owner.lockInitialized: return
  let newBytes = uint64(copied.len)
  acquire(owner.lock)
  if state.references <= 0:
    release(owner.lock)
    return
  let oldBytes = state.messageIdBytes
  let retainedBytes = if owner.payloadBytes >= oldBytes:
      owner.payloadBytes - oldBytes
    else: 0'u64
  if newBytes > Vst3MaxAggregateAttributeBytes.uint64 or
      retainedBytes > Vst3MaxAggregateAttributeBytes.uint64 - newBytes:
    release(owner.lock)
    return
  state.messageId = move(copied)
  state.messageIdBytes = newBytes
  owner.payloadBytes = retainedBytes + newBytes
  release(owner.lock)

proc messageGetAttributes(thisInterface: pointer): ptr Vst3AttributeList {.
    cdecl, gcsafe, raises: [].} =
  let state = messageState(thisInterface)
  if state == nil or state.owner == nil or not state.owner.lockInitialized:
    return nil
  acquire(state.owner.lock)
  if state.references <= 0 or state.attributes == nil:
    release(state.owner.lock)
    return nil
  result = addr state.attributes[].iface
  release(state.owner.lock)

proc newVst3AttributeList*(store: Vst3ControlObjectStore): Vst3AttributeObject {.raises: [].} =
  if not retainObject(store): return nil
  new(result)
  result.owner = addr store[]
  result.references = 1
  result.vtable = Vst3AttributeListVtbl(
    queryInterface: attrQueryInterface, addRef: attrAddRef, release: attrRelease,
    setInt: attrSetInt, getInt: attrGetInt, setFloat: attrSetFloat,
    getFloat: attrGetFloat, setString: attrSetString, getString: attrGetString,
    setBinary: attrSetBinary, getBinary: attrGetBinary)
  result.iface.lpVtbl = addr result.vtable
  registerAttribute(store, result)

proc newVst3Message*(store: Vst3ControlObjectStore): Vst3MessageObject {.raises: [].} =
  if not retainObject(store): return nil
  new(result)
  result.owner = addr store[]
  result.references = 1
  let attributes = newVst3AttributeList(store)
  if attributes == nil:
    releaseObject(addr store[])
    result = nil
    return
  result.attributes = addr attributes[]
  # The message and its attribute list are independently referenced objects;
  # the message owns one list reference for its entire lifetime.
  result.vtable = Vst3MessageVtbl(
    queryInterface: messageQueryInterface, addRef: messageAddRef,
    release: messageRelease, getMessageID: messageGetId,
    setMessageID: messageSetId, getAttributes: messageGetAttributes)
  result.iface.lpVtbl = addr result.vtable
  registerMessage(store, result)

proc interfacePointer*(message: Vst3MessageObject): ptr Vst3Message {.inline.} =
  if message == nil: nil else: addr message[].iface

proc interfacePointer*(attributes: Vst3AttributeObject): ptr Vst3AttributeList {.inline.} =
  if attributes == nil: nil else: addr attributes[].iface

proc liveObjectCount*(store: Vst3ControlObjectStore): int =
  if store == nil or not store.lockInitialized: return 0
  acquire(store.lock)
  result = store.liveObjects
  release(store.lock)

proc copiedPayloadBytes*(store: Vst3ControlObjectStore): uint64 =
  if store == nil or not store.lockInitialized: return 0'u64
  acquire(store.lock)
  result = store.payloadBytes
  release(store.lock)
proc deferredObjectCount*(store: Vst3ControlObjectStore): int =
  if store == nil or not store.lockInitialized: return 0
  acquire(store.lock)
  result = store.attributes.len + store.messages.len
  release(store.lock)
