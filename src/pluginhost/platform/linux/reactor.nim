import std/[os, posix]

import ../../domain/[errors, reactor, result]

const
  EpollCtlAdd = 1.cint
  EpollCtlDel = 2.cint
  EpollCtlMod = 3.cint
  EpollIn = 0x001'u32
  EpollOut = 0x004'u32
  EpollError = 0x008'u32
  EpollHangup = 0x010'u32
  MaxReadyEvents = 64


type
  LinuxEpollData* {.importc: "epoll_data_t", header: "<sys/epoll.h>",
      union, bycopy.} = object
    pointerValue {.importc: "ptr".}: pointer
    fdValue {.importc: "fd".}: cint
    u32Value {.importc: "u32".}: uint32
    u64Value {.importc: "u64".}: uint64

  LinuxEpollEvent* {.importc: "struct epoll_event", header: "<sys/epoll.h>",
      packed, bycopy.} = object
    events* {.importc: "events".}: uint32
    data* {.importc: "data".}: LinuxEpollData

  LinuxReactorDriver* = ref object of ReactorDriver
    epollFd: cint
    closed: bool

proc epollCreate1(flags: cint): cint {.
  importc: "epoll_create1", header: "<sys/epoll.h>", raises: [].}
proc epollCtl(epollFd, operation, fd: cint; event: ptr LinuxEpollEvent): cint {.
  importc: "epoll_ctl", header: "<sys/epoll.h>", raises: [].}
proc epollWait(epollFd: cint; events: ptr LinuxEpollEvent; maximumEvents,
               timeoutMilliseconds: cint): cint {.
  importc: "epoll_wait", header: "<sys/epoll.h>", raises: [].}

proc linuxError(kind: HostErrorKind; message: string; detail = ""): HostError =
  var context = detail
  let code = osLastError()
  if context.len > 0:
    context.add("; ")
  context.add("errno=" & $int(code) & " [" & osErrorMsg(code) & "]")
  hostError(hsPlatform, kind, message, context)

proc epollMask(interests: ReactorInterests): uint32 =
  if riRead in interests:
    result = result or EpollIn
  if riWrite in interests:
    result = result or EpollOut
  result = result or EpollError or EpollHangup

proc reactorInterests(mask: uint32): ReactorInterests =
  if (mask and EpollIn) != 0'u32:
    result.incl(riRead)
  if (mask and EpollOut) != 0'u32:
    result.incl(riWrite)
  if (mask and EpollError) != 0'u32:
    result.incl(riError)
  if (mask and EpollHangup) != 0'u32:
    result.incl(riHangup)

proc openLinuxReactorDriver*(): Result[ReactorDriver] =
  let fd = epollCreate1(O_CLOEXEC)
  if fd < 0:
    return failure[ReactorDriver](linuxError(
      hekReactor, "could not create the Linux epoll reactor"))
  success(ReactorDriver(LinuxReactorDriver(epollFd: fd)))

method now*(driver: LinuxReactorDriver): Result[MonotonicNanos] =
  if driver == nil or driver.closed or driver.epollFd < 0:
    return failure[MonotonicNanos](hostError(
      hsPlatform, hekReactor, "Linux reactor clock is closed"))
  var value: Timespec
  if clock_gettime(CLOCK_MONOTONIC, value) != 0:
    return failure[MonotonicNanos](linuxError(
      hekReactor, "could not read the monotonic reactor clock"))
  let seconds = int64(value.tv_sec)
  let nanoseconds = int64(value.tv_nsec)
  if seconds < 0 or nanoseconds < 0 or nanoseconds >= 1_000_000_000:
    return failure[MonotonicNanos](hostError(
      hsPlatform, hekReactor, "monotonic clock returned an invalid value"))
  if seconds > (high(int64) - nanoseconds) div 1_000_000_000'i64:
    return failure[MonotonicNanos](hostError(
      hsPlatform, hekReactor, "monotonic clock value overflowed"))
  success(monotonicNanos(
    seconds * 1_000_000_000'i64 + nanoseconds))

method addFd*(driver: LinuxReactorDriver; fd: int32;
              interests: ReactorInterests;
              tokenValue: uint64): Result[Unit] =
  if driver == nil or driver.closed or driver.epollFd < 0 or fd < 0:
    return failure[Unit](hostError(
      hsPlatform, hekReactor, "Linux reactor is not open for FD registration"))
  var event = LinuxEpollEvent(events: epollMask(interests))
  event.data.u64Value = tokenValue
  if epollCtl(driver.epollFd, EpollCtlAdd, cint(fd), addr event) != 0:
    return failure[Unit](linuxError(
      hekReactor, "could not add an FD to the Linux reactor", "fd=" & $fd))
  success()

method modifyFd*(driver: LinuxReactorDriver; fd: int32;
                 interests: ReactorInterests;
                 tokenValue: uint64): Result[Unit] =
  if driver == nil or driver.closed or driver.epollFd < 0 or fd < 0:
    return failure[Unit](hostError(
      hsPlatform, hekReactor, "Linux reactor is not open for FD modification"))
  var event = LinuxEpollEvent(events: epollMask(interests))
  event.data.u64Value = tokenValue
  if epollCtl(driver.epollFd, EpollCtlMod, cint(fd), addr event) != 0:
    return failure[Unit](linuxError(
      hekReactor, "could not modify an FD in the Linux reactor", "fd=" & $fd))
  success()

method removeFd*(driver: LinuxReactorDriver; fd: int32): Result[Unit] =
  if driver == nil or driver.closed or driver.epollFd < 0 or fd < 0:
    return failure[Unit](hostError(
      hsPlatform, hekReactor, "Linux reactor is not open for FD removal"))
  if epollCtl(driver.epollFd, EpollCtlDel, cint(fd), nil) != 0:
    return failure[Unit](linuxError(
      hekReactor, "could not remove an FD from the Linux reactor", "fd=" & $fd))
  success()

method wait*(driver: LinuxReactorDriver; timeoutMilliseconds: int32):
    Result[seq[ReactorReady]] =
  if driver == nil or driver.closed or driver.epollFd < 0 or
      timeoutMilliseconds < -1:
    return failure[seq[ReactorReady]](hostError(
      hsPlatform, hekReactor, "invalid Linux reactor wait"))
  var events: array[MaxReadyEvents, LinuxEpollEvent]
  var count: cint
  while true:
    count = epollWait(driver.epollFd, addr events[0], MaxReadyEvents.cint,
                      timeoutMilliseconds.cint)
    if count >= 0:
      break
    if osLastError() != OSErrorCode(EINTR):
      return failure[seq[ReactorReady]](linuxError(
        hekReactor, "Linux reactor wait failed"))
  var ready = newSeqOfCap[ReactorReady](int(count))
  for index in 0 ..< int(count):
    ready.add(ReactorReady(
      tokenValue: events[index].data.u64Value,
      interests: reactorInterests(events[index].events),
    ))
  success(move(ready))

method close*(driver: LinuxReactorDriver): Result[Unit] =
  if driver == nil or driver.closed:
    return success()
  if driver.epollFd >= 0:
    let status = posix.close(driver.epollFd)
    driver.epollFd = -1
    driver.closed = true
    if status != 0:
      return failure[Unit](linuxError(
        hekReactor, "could not close the Linux reactor"))
  else:
    driver.closed = true
  success()
