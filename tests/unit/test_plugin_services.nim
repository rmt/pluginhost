import std/[options, unittest]

import pluginhost/app/[main_reactor, plugin_services]
import pluginhost/clap/ffi
import pluginhost/domain/[errors, reactor, result]

type
  FakeRegistration = object
    fd: int32
    interests: ReactorInterests
    token: uint64

  ServiceDriver = ref object of ReactorDriver
    nowValue: int64
    registrations: seq[FakeRegistration]
    pending: seq[ReactorReady]

method now(driver: ServiceDriver): Result[MonotonicNanos] =
  success(monotonicNanos(driver.nowValue))

method addFd(driver: ServiceDriver; fd: int32; interests: ReactorInterests;
             token: uint64): Result[Unit] =
  driver.registrations.add(FakeRegistration(
    fd: fd, interests: interests, token: token))
  success()

method modifyFd(driver: ServiceDriver; fd: int32;
                interests: ReactorInterests; token: uint64): Result[Unit] =
  for registration in driver.registrations.mitems:
    if registration.fd == fd:
      registration.interests = interests
      registration.token = token
      return success()
  failure[Unit](hostError(hsPlatform, hekReactor, "missing service FD"))

method removeFd(driver: ServiceDriver; fd: int32): Result[Unit] =
  for index in 0 ..< driver.registrations.len:
    if driver.registrations[index].fd == fd:
      driver.registrations.delete(index)
      return success()
  failure[Unit](hostError(hsPlatform, hekReactor, "missing service FD"))

method wait(driver: ServiceDriver; timeoutMilliseconds: int32):
    Result[seq[ReactorReady]] =
  if timeoutMilliseconds > 0:
    driver.nowValue += int64(timeoutMilliseconds) * 1_000_000'i64
  result = success(move(driver.pending))
  driver.pending = @[]

method close(driver: ServiceDriver): Result[Unit] =
  success()

suite "CLAP main-thread plugin service registry":
  test "periodic timers support exact capacity overflow self-cancel and recovery":
    let driver = ServiceDriver(nowValue: 1_000_000)
    var opened = initMainReactor(driver)
    require opened.isOk
    var reactor = move(opened.value)
    let registry = newPluginServiceRegistry(reactor)
    let services = registry.servicePointer
    defer:
      doAssert registry.close().isOk
      doAssert reactor.close().isOk

    var ids: array[MaxPluginTimers, uint32]
    for index in 0 ..< MaxPluginTimers:
      check services.registerTimer(
        services.context, 34'u32, addr ids[index])
      check ids[index] == uint32(index)
    var overflowId = ClapInvalidId
    check not services.registerTimer(
      services.context, 34'u32, addr overflowId)
    check registry.activeTimerCount == MaxPluginTimers

    var due = reactor.wait(monotonicNanos(34_000_000))
    require due.isOk
    check due.value.len == MaxPluginTimers
    let event = registry.classify(due.value[0])
    require event.isSome
    check event.get.kind == psekTimer
    check services.unregisterTimer(services.context, event.get.timerId)
    check registry.completeTimerDispatch(event.get.timerId).isOk
    check registry.activeTimerCount == MaxPluginTimers - 1

    check services.registerTimer(
      services.context, 34'u32, addr overflowId)
    check overflowId == uint32(MaxPluginTimers)
    check registry.activeTimerCount == MaxPluginTimers

  test "FD readiness is level-mapped and stale events are rejected":
    let driver = ServiceDriver()
    var opened = initMainReactor(driver)
    require opened.isOk
    var reactor = move(opened.value)
    let registry = newPluginServiceRegistry(reactor)
    let services = registry.servicePointer
    defer:
      doAssert registry.close().isOk
      doAssert reactor.close().isOk

    check services.registerFd(
      services.context, 12, ClapPosixFdRead or ClapPosixFdError)
    check not services.registerFd(
      services.context, 12, ClapPosixFdRead)
    require driver.registrations.len == 1
    let staleToken = driver.registrations[0].token
    driver.pending = @[ReactorReady(
      tokenValue: staleToken, interests: {riRead, riHangup})]
    var ready = reactor.wait(monotonicNanos(0))
    require ready.isOk and ready.value.len == 1
    let event = registry.classify(ready.value[0])
    require event.isSome
    check event.get.kind == psekFd
    check event.get.fd == 12
    check event.get.fdFlags == (ClapPosixFdRead or ClapPosixFdError)

    check services.modifyFd(
      services.context, 12, ClapPosixFdWrite)
    check driver.registrations[0].interests == {riWrite}
    check services.unregisterFd(services.context, 12)
    check registry.activeFdCount == 0
    check registry.classify(ReactorEvent(
      token: decodeReactorToken(staleToken), kind: rekFd,
      interests: {riRead})).isNone
    check not services.modifyFd(
      services.context, 12, ClapPosixFdRead)

  test "close removes every registration and is idempotent":
    let driver = ServiceDriver()
    var opened = initMainReactor(driver)
    require opened.isOk
    var reactor = move(opened.value)
    let registry = newPluginServiceRegistry(reactor)
    let services = registry.servicePointer
    var timerId: uint32
    check services.registerTimer(services.context, 1'u32, addr timerId)
    check services.registerFd(services.context, 7, ClapPosixFdRead)
    check registry.close().isOk
    check registry.activeTimerCount == 0
    check registry.activeFdCount == 0
    check registry.close().isOk
    check not services.registerTimer(services.context, 1'u32, addr timerId)
    check reactor.close().isOk
