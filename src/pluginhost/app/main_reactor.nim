import std/algorithm

import ../domain/[errors, reactor, result]

type
  ReactorSlotKind = enum
    rskFd
    rskTimer

  ReactorSlot = object
    active: bool
    armed: bool
    generation: uint32
    kind: ReactorSlotKind
    fd: int32
    interests: ReactorInterests
    deadline: MonotonicNanos
    sequence: uint64

  MainReactor* = object
    driver: ReactorDriver
    slots: seq[ReactorSlot]
    nextSequence: uint64
    closed: bool

proc reactorError(message: string; context = ""): HostError =
  hostError(hsPlatform, hekReactor, message, context)

proc initMainReactor*(driver: ReactorDriver): Result[MainReactor] =
  if driver == nil:
    return failure[MainReactor](reactorError(
      "main reactor requires a concrete driver"))
  success(MainReactor(driver: driver))

proc allocateSlot(reactor: var MainReactor; kind: ReactorSlotKind): ReactorToken =
  for index in 0 ..< reactor.slots.len:
    if not reactor.slots[index].active and
        reactor.slots[index].generation < high(uint32):
      let generation = reactor.slots[index].generation + 1'u32
      reactor.slots[index] = ReactorSlot(
        active: true,
        generation: generation,
        kind: kind,
      )
      return ReactorToken(slot: uint32(index), generation: generation)
  reactor.slots.add(ReactorSlot(
    active: true,
    generation: 1'u32,
    kind: kind,
  ))
  ReactorToken(slot: uint32(reactor.slots.high), generation: 1'u32)

proc currentSlot(reactor: var MainReactor; token: ReactorToken):
    ptr ReactorSlot =
  if token.generation == 0'u32 or token.slot >= uint32(reactor.slots.len):
    return nil
  let slot = addr reactor.slots[int(token.slot)]
  if not slot.active or slot.generation != token.generation:
    return nil
  slot

proc now*(reactor: var MainReactor): Result[MonotonicNanos] =
  if reactor.closed or reactor.driver == nil:
    return failure[MonotonicNanos](reactorError(
      "cannot read time from a closed main reactor"))
  var current = reactor.driver.now()
  if not current.isOk:
    return current
  if current.value.int64Value < 0:
    return failure[MonotonicNanos](reactorError(
      "reactor driver returned a negative monotonic time"))
  current

proc isCurrent*(reactor: var MainReactor; token: ReactorToken): bool =
  reactor.currentSlot(token) != nil

proc registerFd*(reactor: var MainReactor; fd: int32;
                 interests: ReactorInterests): Result[ReactorToken] =
  if reactor.closed or reactor.driver == nil or fd < 0 or interests == {}:
    return failure[ReactorToken](reactorError(
      "invalid reactor FD registration",
      "fd=" & $fd & "; interests=" & $interests))
  let token = reactor.allocateSlot(rskFd)
  let slot = reactor.currentSlot(token)
  slot.fd = fd
  slot.interests = interests
  var added = reactor.driver.addFd(fd, interests, token.encode)
  if not added.isOk:
    slot.active = false
    return failure[ReactorToken](move(added.error))
  success(token)

proc modifyFd*(reactor: var MainReactor; token: ReactorToken;
               interests: ReactorInterests): Result[Unit] =
  let slot = reactor.currentSlot(token)
  if reactor.closed or slot == nil or slot.kind != rskFd or interests == {}:
    return failure[Unit](reactorError(
      "invalid reactor FD modification", "token=" & $token.encode))
  var modified = reactor.driver.modifyFd(slot.fd, interests, token.encode)
  if not modified.isOk:
    return modified
  slot.interests = interests
  success()

proc removeFd*(reactor: var MainReactor; token: ReactorToken): Result[Unit] =
  let slot = reactor.currentSlot(token)
  if reactor.closed or slot == nil or slot.kind != rskFd:
    return failure[Unit](reactorError(
      "invalid or stale reactor FD removal", "token=" & $token.encode))
  var removed = reactor.driver.removeFd(slot.fd)
  if not removed.isOk:
    return removed
  slot.active = false
  slot.armed = false
  success()

proc registerTimer*(reactor: var MainReactor;
                    deadline: MonotonicNanos): Result[ReactorToken] =
  if reactor.closed or deadline.int64Value < 0:
    return failure[ReactorToken](reactorError(
      "invalid monotonic timer deadline", "deadline=" & $deadline.int64Value))
  if reactor.nextSequence == high(uint64):
    return failure[ReactorToken](reactorError(
      "reactor timer sequence is exhausted"))
  let token = reactor.allocateSlot(rskTimer)
  let slot = reactor.currentSlot(token)
  slot.armed = true
  slot.deadline = deadline
  slot.sequence = reactor.nextSequence
  inc reactor.nextSequence
  success(token)

proc rescheduleTimer*(reactor: var MainReactor; token: ReactorToken;
                      deadline: MonotonicNanos): Result[Unit] =
  let slot = reactor.currentSlot(token)
  if reactor.closed or slot == nil or slot.kind != rskTimer or
      deadline.int64Value < 0:
    return failure[Unit](reactorError(
      "invalid or stale reactor timer reschedule", "token=" & $token.encode))
  if reactor.nextSequence == high(uint64):
    return failure[Unit](reactorError(
      "reactor timer sequence is exhausted"))
  slot.armed = true
  slot.deadline = deadline
  slot.sequence = reactor.nextSequence
  inc reactor.nextSequence
  success()

proc cancelTimer*(reactor: var MainReactor; token: ReactorToken): Result[Unit] =
  let slot = reactor.currentSlot(token)
  if reactor.closed or slot == nil or slot.kind != rskTimer:
    return failure[Unit](reactorError(
      "invalid or stale reactor timer cancellation", "token=" & $token.encode))
  slot.active = false
  slot.armed = false
  success()

proc nextTimerDeadline(reactor: MainReactor): int64 =
  result = high(int64)
  for slot in reactor.slots:
    if slot.active and slot.kind == rskTimer and slot.armed:
      result = min(result, slot.deadline.int64Value)

proc timeoutMilliseconds(nowNanos, deadlineNanos: int64): int32 =
  if deadlineNanos <= nowNanos:
    return 0'i32
  let difference = deadlineNanos - nowNanos
  var rounded = difference div 1_000_000'i64
  if difference mod 1_000_000'i64 != 0:
    inc rounded
  if rounded > int64(high(int32)):
    high(int32)
  else:
    int32(rounded)

proc appendDueTimers(reactor: var MainReactor; nowNanos: int64;
                     events: var seq[ReactorEvent]) =
  var due: seq[tuple[deadline: int64, sequence: uint64, token: ReactorToken]]
  for index in 0 ..< reactor.slots.len:
    let slot = addr reactor.slots[index]
    if slot.active and slot.kind == rskTimer and slot.armed and
        slot.deadline.int64Value <= nowNanos:
      slot.armed = false
      due.add((
        deadline: slot.deadline.int64Value,
        sequence: slot.sequence,
        token: ReactorToken(slot: uint32(index), generation: slot.generation),
      ))
  due.sort(proc(left, right: auto): int =
    result = cmp(left.deadline, right.deadline)
    if result == 0:
      result = cmp(left.sequence, right.sequence))
  for entry in due:
    events.add(ReactorEvent(token: entry.token, kind: rekTimer))

proc wait*(reactor: var MainReactor; maximumWait: MonotonicNanos):
    Result[seq[ReactorEvent]] =
  if reactor.closed or reactor.driver == nil or maximumWait.int64Value < 0:
    return failure[seq[ReactorEvent]](reactorError(
      "invalid main-reactor wait", "maximum-wait=" & $maximumWait.int64Value))
  var before = reactor.driver.now()
  if not before.isOk:
    return failure[seq[ReactorEvent]](move(before.error))
  if before.value.int64Value < 0:
    return failure[seq[ReactorEvent]](reactorError(
      "reactor driver returned a negative monotonic time"))

  var events: seq[ReactorEvent]
  reactor.appendDueTimers(before.value.int64Value, events)
  if events.len > 0:
    return success(move(events))

  var deadline = if maximumWait.int64Value >
      high(int64) - before.value.int64Value:
      high(int64)
    else:
      before.value.int64Value + maximumWait.int64Value
  deadline = min(deadline, reactor.nextTimerDeadline())
  var ready = reactor.driver.wait(
    timeoutMilliseconds(before.value.int64Value, deadline))
  if not ready.isOk:
    return failure[seq[ReactorEvent]](move(ready.error))

  for item in ready.value:
    let token = decodeReactorToken(item.tokenValue)
    let slot = reactor.currentSlot(token)
    if slot != nil and slot.kind == rskFd:
      events.add(ReactorEvent(
        token: token,
        kind: rekFd,
        interests: item.interests,
      ))

  var after = reactor.driver.now()
  if not after.isOk:
    return failure[seq[ReactorEvent]](move(after.error))
  if after.value.int64Value < 0:
    return failure[seq[ReactorEvent]](reactorError(
      "reactor driver returned a negative monotonic time"))
  reactor.appendDueTimers(after.value.int64Value, events)
  success(move(events))

proc close*(reactor: var MainReactor): Result[Unit] =
  if reactor.closed:
    return success()
  var first: HostError
  var failed = false
  if reactor.driver != nil:
    for slot in reactor.slots.mitems:
      if slot.active and slot.kind == rskFd:
        var removed = reactor.driver.removeFd(slot.fd)
        if not removed.isOk and not failed:
          first = move(removed.error)
          failed = true
        if removed.isOk:
          slot.active = false
    var driverClosed = reactor.driver.close()
    if not driverClosed.isOk and not failed:
      first = move(driverClosed.error)
      failed = true
    if driverClosed.isOk:
      for slot in reactor.slots.mitems:
        slot.active = false
        slot.armed = false
      reactor.closed = true
  if failed:
    return failure[Unit](move(first))
  for slot in reactor.slots.mitems:
    slot.active = false
    slot.armed = false
  reactor.closed = true
  success()
