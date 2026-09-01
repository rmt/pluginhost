import std/[posix, unittest]

import pluginhost/app/main_reactor
import pluginhost/domain/[errors, reactor, result]
import pluginhost/platform/linux/reactor as linux_reactor

type
  FakeRegistration = object
    fd: int32
    interests: ReactorInterests
    token: uint64

  FakeReactorDriver = ref object of ReactorDriver
    nowValue: int64
    registrations: seq[FakeRegistration]
    pending: seq[ReactorReady]
    waits: seq[int32]
    closed: bool

method now(driver: FakeReactorDriver): Result[MonotonicNanos] =
  success(monotonicNanos(driver.nowValue))

method addFd(driver: FakeReactorDriver; fd: int32;
             interests: ReactorInterests; token: uint64): Result[Unit] =
  driver.registrations.add(FakeRegistration(
    fd: fd, interests: interests, token: token))
  success()

method modifyFd(driver: FakeReactorDriver; fd: int32;
                interests: ReactorInterests; token: uint64): Result[Unit] =
  for registration in driver.registrations.mitems:
    if registration.fd == fd:
      registration.interests = interests
      registration.token = token
      return success()
  failure[Unit](hostError(hsPlatform, hekReactor, "missing fake FD"))

method removeFd(driver: FakeReactorDriver; fd: int32): Result[Unit] =
  for index in 0 ..< driver.registrations.len:
    if driver.registrations[index].fd == fd:
      driver.registrations.delete(index)
      return success()
  failure[Unit](hostError(hsPlatform, hekReactor, "missing fake FD"))

method wait(driver: FakeReactorDriver; timeoutMilliseconds: int32):
    Result[seq[ReactorReady]] =
  driver.waits.add(timeoutMilliseconds)
  if timeoutMilliseconds > 0:
    driver.nowValue += int64(timeoutMilliseconds) * 1_000_000'i64
  result = success(move(driver.pending))
  driver.pending = @[]

method close(driver: FakeReactorDriver): Result[Unit] =
  driver.closed = true
  success()

suite "main reactor scheduling and generation safety":
  test "FD lifecycle rejects stale queued generations":
    let driver = FakeReactorDriver()
    var opened = initMainReactor(driver)
    require opened.isOk
    var reactor = move(opened.value)
    defer: doAssert reactor.close().isOk

    var first = reactor.registerFd(11, {riRead})
    require first.isOk
    check reactor.modifyFd(first.value, {riRead, riWrite}).isOk
    let staleValue = first.value.encode
    check reactor.removeFd(first.value).isOk
    var second = reactor.registerFd(12, {riRead})
    require second.isOk
    check second.value.slot == first.value.slot
    check second.value.generation != first.value.generation

    driver.pending = @[
      ReactorReady(tokenValue: staleValue, interests: {riRead}),
      ReactorReady(tokenValue: second.value.encode, interests: {riRead}),
    ]
    var events = reactor.wait(monotonicNanos(0))
    require events.isOk
    check events.value.len == 1
    check events.value[0].token == second.value
    check riRead in events.value[0].interests

  test "timers order equal deadlines and support rearming and cancellation":
    let driver = FakeReactorDriver(nowValue: 1_000_000)
    var opened = initMainReactor(driver)
    require opened.isOk
    var reactor = move(opened.value)
    defer: doAssert reactor.close().isOk

    var first = reactor.registerTimer(monotonicNanos(3_000_000))
    var second = reactor.registerTimer(monotonicNanos(2_000_000))
    var third = reactor.registerTimer(monotonicNanos(2_000_000))
    require first.isOk and second.isOk and third.isOk
    var events = reactor.wait(monotonicNanos(10_000_000))
    require events.isOk
    check events.value.len == 2
    check events.value[0].token == second.value
    check events.value[1].token == third.value
    check driver.waits == @[1'i32]

    check reactor.rescheduleTimer(second.value,
      monotonicNanos(4_000_000)).isOk
    check reactor.cancelTimer(third.value).isOk
    events = reactor.wait(monotonicNanos(10_000_000))
    require events.isOk
    check events.value.len == 1
    check events.value[0].token == first.value
    events = reactor.wait(monotonicNanos(10_000_000))
    require events.isOk
    check events.value.len == 1
    check events.value[0].token == second.value

  test "an idle wait blocks through the driver rather than busy polling":
    let driver = FakeReactorDriver(nowValue: 100)
    var opened = initMainReactor(driver)
    require opened.isOk
    var reactor = move(opened.value)
    check reactor.wait(monotonicNanos(16_000_000)).isOk
    check driver.waits == @[16'i32]
    check driver.nowValue == 16_000_100
    check reactor.close().isOk
    check driver.closed

  test "Linux epoll adapter reports level-triggered pipe readiness":
    var descriptors: array[2, cint]
    require pipe(descriptors) == 0
    defer:
      discard posix.close(descriptors[0])
      discard posix.close(descriptors[1])

    var driverResult = linux_reactor.openLinuxReactorDriver()
    require driverResult.isOk
    var opened = initMainReactor(driverResult.value)
    require opened.isOk
    var reactor = move(opened.value)
    var token = reactor.registerFd(int32(descriptors[0]), {riRead})
    require token.isOk
    var byte = 'x'
    require posix.write(descriptors[1], addr byte, 1) == 1
    var events = reactor.wait(monotonicNanos(50_000_000))
    require events.isOk
    check events.value.len == 1
    check events.value[0].token == token.value
    check riRead in events.value[0].interests
    check reactor.removeFd(token.value).isOk
    check reactor.close().isOk
