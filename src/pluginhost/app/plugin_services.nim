## Application-owned CLAP timer and POSIX-FD registrations.
##
## This registry adapts the stable CLAP callback table to MainReactor without
## allowing the CLAP adapter to depend on application or Linux reactor policy.

import std/options

import ./main_reactor
import ../clap/[ffi, main_thread_services]
import ../domain/[errors, reactor, result]

const
  MaxPluginTimers* = 256
  MaxPluginFds* = 256


type
  PluginServiceEventKind* = enum
    psekTimer
    psekFd

  PluginServiceEvent* = object
    kind*: PluginServiceEventKind
    timerId*: uint32
    fd*: int32
    fdFlags*: uint32

  TimerRegistration = object
    active: bool
    id: uint32
    periodNanos: int64
    token: ReactorToken

  FdRegistration = object
    active: bool
    fd: int32
    flags: uint32
    token: ReactorToken

  PluginServiceRegistry* = ref object
    reactor: ptr MainReactor
    services: ClapMainThreadServices
    timers: array[MaxPluginTimers, TimerRegistration]
    fds: array[MaxPluginFds, FdRegistration]
    nextTimerId: uint32
    closing: bool

proc registryError(message: string; context = ""): HostError =
  hostError(hsClap, hekClapPlugin, message, context)

proc interests(flags: uint32): ReactorInterests =
  if (flags and ClapPosixFdRead) != 0'u32:
    result.incl(riRead)
  if (flags and ClapPosixFdWrite) != 0'u32:
    result.incl(riWrite)
  if (flags and ClapPosixFdError) != 0'u32:
    result.incl(riError)

proc validFlags(flags: uint32): bool =
  flags != 0'u32 and
    (flags and not (ClapPosixFdRead or ClapPosixFdWrite or ClapPosixFdError)) == 0'u32

proc timerSlot(registry: PluginServiceRegistry; id: uint32): int =
  if registry == nil:
    return -1
  for index in 0 ..< MaxPluginTimers:
    if registry.timers[index].active and registry.timers[index].id == id:
      return index
  -1

proc fdSlot(registry: PluginServiceRegistry; fd: int32): int =
  if registry == nil:
    return -1
  for index in 0 ..< MaxPluginFds:
    if registry.fds[index].active and registry.fds[index].fd == fd:
      return index
  -1

proc registerTimerCallback(context: pointer; periodMs: uint32;
                           timerId: ptr cuint): bool {.
    cdecl, gcsafe, raises: [].} =
  let registry = cast[PluginServiceRegistry](context)
  if registry == nil or registry.closing or registry.reactor == nil or
      timerId == nil or periodMs == 0'u32 or
      periodMs > uint32(high(int64) div 1_000_000'i64) or
      registry.nextTimerId == ClapInvalidId:
    return false
  var slot = -1
  for index in 0 ..< MaxPluginTimers:
    if not registry.timers[index].active:
      slot = index
      break
  if slot < 0:
    return false
  var current = registry.reactor[].now()
  if not current.isOk:
    return false
  let periodNanos = int64(periodMs) * 1_000_000'i64
  if current.value.int64Value > high(int64) - periodNanos:
    return false
  var registered = registry.reactor[].registerTimer(
    monotonicNanos(current.value.int64Value + periodNanos))
  if not registered.isOk:
    return false
  let id = registry.nextTimerId
  inc registry.nextTimerId
  registry.timers[slot] = TimerRegistration(
    active: true, id: id, periodNanos: periodNanos,
    token: registered.value)
  timerId[] = cuint(id)
  true

proc unregisterTimerCallback(context: pointer; timerId: uint32): bool {.
    cdecl, gcsafe, raises: [].} =
  let registry = cast[PluginServiceRegistry](context)
  let slot = registry.timerSlot(timerId)
  if registry == nil or registry.closing or slot < 0 or registry.reactor == nil:
    return false
  var cancelled = registry.reactor[].cancelTimer(registry.timers[slot].token)
  if not cancelled.isOk:
    return false
  registry.timers[slot].active = false
  true

proc registerFdCallback(context: pointer; fd: int32; flags: uint32): bool {.
    cdecl, gcsafe, raises: [].} =
  let registry = cast[PluginServiceRegistry](context)
  if registry == nil or registry.closing or registry.reactor == nil or fd < 0 or
      not validFlags(flags) or registry.fdSlot(fd) >= 0:
    return false
  var slot = -1
  for index in 0 ..< MaxPluginFds:
    if not registry.fds[index].active:
      slot = index
      break
  if slot < 0:
    return false
  var registered = registry.reactor[].registerFd(fd, interests(flags))
  if not registered.isOk:
    return false
  registry.fds[slot] = FdRegistration(
    active: true, fd: fd, flags: flags, token: registered.value)
  true

proc modifyFdCallback(context: pointer; fd: int32; flags: uint32): bool {.
    cdecl, gcsafe, raises: [].} =
  let registry = cast[PluginServiceRegistry](context)
  let slot = registry.fdSlot(fd)
  if registry == nil or registry.closing or registry.reactor == nil or
      slot < 0 or not validFlags(flags):
    return false
  var modified = registry.reactor[].modifyFd(
    registry.fds[slot].token, interests(flags))
  if not modified.isOk:
    return false
  registry.fds[slot].flags = flags
  true

proc unregisterFdCallback(context: pointer; fd: int32): bool {.
    cdecl, gcsafe, raises: [].} =
  let registry = cast[PluginServiceRegistry](context)
  let slot = registry.fdSlot(fd)
  if registry == nil or registry.closing or registry.reactor == nil or slot < 0:
    return false
  var removed = registry.reactor[].removeFd(registry.fds[slot].token)
  if not removed.isOk:
    return false
  registry.fds[slot].active = false
  true

proc newPluginServiceRegistry*(reactor: var MainReactor): PluginServiceRegistry =
  new(result)
  result.reactor = addr reactor
  result.services = ClapMainThreadServices(
    context: cast[pointer](result),
    registerTimer: registerTimerCallback,
    unregisterTimer: unregisterTimerCallback,
    registerFd: registerFdCallback,
    modifyFd: modifyFdCallback,
    unregisterFd: unregisterFdCallback,
  )

proc servicePointer*(registry: PluginServiceRegistry):
    ptr ClapMainThreadServices =
  if registry == nil:
    return nil
  addr registry.services

proc classify*(registry: PluginServiceRegistry; event: ReactorEvent):
    Option[PluginServiceEvent] =
  if registry == nil or registry.closing:
    return none(PluginServiceEvent)
  for timer in registry.timers:
    if timer.active and event.kind == rekTimer and event.token == timer.token:
      return some(PluginServiceEvent(kind: psekTimer, timerId: timer.id))
  for registration in registry.fds:
    if registration.active and event.kind == rekFd and event.token == registration.token:
      var flags = 0'u32
      if riRead in event.interests:
        flags = flags or ClapPosixFdRead
      if riWrite in event.interests:
        flags = flags or ClapPosixFdWrite
      if riError in event.interests or riHangup in event.interests:
        flags = flags or ClapPosixFdError
      flags = flags and registration.flags
      if riHangup in event.interests:
        flags = flags or ClapPosixFdError
      return some(PluginServiceEvent(
        kind: psekFd, fd: registration.fd, fdFlags: flags))
  none(PluginServiceEvent)

proc completeTimerDispatch*(registry: PluginServiceRegistry;
                            timerId: uint32): Result[Unit] =
  let slot = registry.timerSlot(timerId)
  if registry == nil or registry.closing or registry.reactor == nil or slot < 0:
    # Self-unregistration during on_timer is successful completion.
    return success()
  var current = registry.reactor[].now()
  if not current.isOk:
    return failure[Unit](move(current.error))
  let period = registry.timers[slot].periodNanos
  if current.value.int64Value > high(int64) - period:
    return failure[Unit](registryError(
      "plugin timer deadline overflow", "timer-id=" & $timerId))
  registry.reactor[].rescheduleTimer(
    registry.timers[slot].token,
    monotonicNanos(current.value.int64Value + period))

proc activeTimerCount*(registry: PluginServiceRegistry): int =
  if registry == nil:
    return 0
  for timer in registry.timers:
    if timer.active:
      inc result

proc activeFdCount*(registry: PluginServiceRegistry): int =
  if registry == nil:
    return 0
  for registration in registry.fds:
    if registration.active:
      inc result

proc close*(registry: PluginServiceRegistry): Result[Unit] =
  if registry == nil or registry.closing:
    return success()
  registry.closing = true
  var first: HostError
  var failed = false
  if registry.reactor != nil:
    for timer in registry.timers.mitems:
      if timer.active:
        var cancelled = registry.reactor[].cancelTimer(timer.token)
        if cancelled.isOk:
          timer.active = false
        elif not failed:
          first = move(cancelled.error)
          failed = true
    for registration in registry.fds.mitems:
      if registration.active:
        var removed = registry.reactor[].removeFd(registration.token)
        if removed.isOk:
          registration.active = false
        elif not failed:
          first = move(removed.error)
          failed = true
  if failed:
    registry.closing = false
    return failure[Unit](move(first))
  registry.reactor = nil
  success()
