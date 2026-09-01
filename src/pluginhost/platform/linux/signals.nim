import std/[os, posix]

import ../../domain/[errors, result]

const MaxSignalsPerDrain* = 64

type
  SignalIntent* = enum
    siInterrupt
    siTerminate
    siShowGui
    siHideGui

  LinuxSignalFdInfo* {.bycopy.} = object
    signo*: uint32
    errorNumber: int32
    code: int32
    senderPid: uint32
    senderUid: uint32
    fd: int32
    tid: uint32
    band: uint32
    overrun: uint32
    trapNumber: uint32
    status: int32
    integerValue: int32
    pointerValue: uint64
    userTime: uint64
    systemTime: uint64
    address: uint64
    addressLsb: uint16
    pad2: uint16
    syscall: int32
    callAddress: uint64
    architecture: uint32
    padding: array[28, uint8]

  SignalSource* = object
    fdValue: cint
    handledMask: Sigset
    previousMask: Sigset
    ownerThread: Pthread
    descriptorOpen: bool
    maskBlocked: bool

proc signalfd(fd: cint; mask: ptr Sigset; flags: cint): cint {.
  importc, header: "<sys/signalfd.h>", raises: [].}

proc signalError(message: string; detail = ""): HostError =
  var context = detail
  let code = osLastError()
  if context.len > 0:
    context.add("; ")
  context.add("errno=" & $int(code) & " [" & osErrorMsg(code) & "]")
  hostError(hsPlatform, hekSignal, message, context)

proc pthreadError(message: string; status: cint; detail = ""): HostError =
  var context = detail
  if context.len > 0:
    context.add("; ")
  context.add("status=" & $status & " [" &
    osErrorMsg(OSErrorCode(status)) & "]")
  hostError(hsPlatform, hekSignal, message, context)

proc `=destroy`*(source: var SignalSource) =
  doAssert not source.descriptorOpen and not source.maskBlocked,
    "a signal source must be explicitly closed"

proc `=copy`*(destination: var SignalSource; source: SignalSource) {.error:
  "SignalSource owns a signal mask and descriptor and cannot be copied; use move".}
proc `=dup`*(source: SignalSource): SignalSource {.error:
  "SignalSource owns a signal mask and descriptor and cannot be duplicated; use move".}

proc `=sink`*(destination: var SignalSource; source: SignalSource) =
  doAssert not destination.descriptorOpen and not destination.maskBlocked,
    "a signal source must be closed before move assignment"
  destination.fdValue = source.fdValue
  destination.handledMask = source.handledMask
  destination.previousMask = source.previousMask
  destination.ownerThread = source.ownerThread
  destination.descriptorOpen = source.descriptorOpen
  destination.maskBlocked = source.maskBlocked

proc fileDescriptor*(source: SignalSource): int32 {.inline.} =
  if source.descriptorOpen: int32(source.fdValue) else: -1'i32

proc isOpen*(source: SignalSource): bool {.inline.} =
  source.descriptorOpen and source.maskBlocked

proc openSignalSource*(): Result[SignalSource] =
  var source = SignalSource(fdValue: -1, ownerThread: pthread_self())
  if sigemptyset(source.handledMask) != 0 or
      sigaddset(source.handledMask, SIGINT) != 0 or
      sigaddset(source.handledMask, SIGTERM) != 0 or
      sigaddset(source.handledMask, SIGUSR1) != 0 or
      sigaddset(source.handledMask, SIGUSR2) != 0:
    return failure[SignalSource](signalError(
      "could not construct the handled signal mask"))

  let blockStatus = pthread_sigmask(
    SIG_BLOCK, source.handledMask, source.previousMask)
  if blockStatus != 0:
    return failure[SignalSource](pthreadError(
      "could not block handled signals on the host main thread", blockStatus))
  source.maskBlocked = true

  source.fdValue = signalfd(-1, addr source.handledMask,
                            O_CLOEXEC or O_NONBLOCK)
  if source.fdValue < 0:
    let primary = signalError("could not create the Linux signal descriptor")
    var ignored: Sigset
    let restoreStatus = pthread_sigmask(
      SIG_SETMASK, source.previousMask, ignored)
    if restoreStatus != 0:
      source.maskBlocked = false
      return failure[SignalSource](pthreadError(
        "could not restore the signal mask after signalfd failure",
        restoreStatus, "primary=" & primary.message))
    source.maskBlocked = false
    return failure[SignalSource](primary)
  source.descriptorOpen = true
  success(move(source))

proc intent(signalNumber: uint32): SignalIntent =
  case cint(signalNumber)
  of SIGINT: siInterrupt
  of SIGTERM: siTerminate
  of SIGUSR1: siShowGui
  of SIGUSR2: siHideGui
  else: siInterrupt

proc drain*(source: var SignalSource): Result[seq[SignalIntent]] =
  if not source.descriptorOpen or not source.maskBlocked or
      pthread_equal(pthread_self(), source.ownerThread) == 0:
    return failure[seq[SignalIntent]](hostError(
      hsPlatform, hekSignal,
      "signals can only be drained by the owning host main thread"))

  var intents = newSeqOfCap[SignalIntent](MaxSignalsPerDrain)
  var index = 0
  while index < MaxSignalsPerDrain:
    var info: LinuxSignalFdInfo
    let count = posix.read(source.fdValue, addr info, sizeof(info))
    if count == sizeof(info):
      case cint(info.signo)
      of SIGINT, SIGTERM, SIGUSR1, SIGUSR2:
        intents.add(intent(info.signo))
      else:
        return failure[seq[SignalIntent]](hostError(
          hsPlatform, hekSignal,
          "signal descriptor returned an unexpected signal",
          "signal=" & $info.signo))
      inc index
      continue
    if count < 0:
      let code = osLastError()
      if code == OSErrorCode(EINTR):
        continue
      if code == OSErrorCode(EAGAIN) or code == OSErrorCode(EWOULDBLOCK):
        break
      return failure[seq[SignalIntent]](signalError(
        "could not read the Linux signal descriptor"))
    return failure[seq[SignalIntent]](hostError(
      hsPlatform, hekSignal,
      "signal descriptor returned a partial record",
      "bytes=" & $count & "; expected=" & $sizeof(info)))
  success(move(intents))

proc close*(source: var SignalSource): Result[Unit] =
  if not source.descriptorOpen and not source.maskBlocked:
    return success()
  if pthread_equal(pthread_self(), source.ownerThread) == 0:
    return failure[Unit](hostError(
      hsPlatform, hekSignal,
      "signal resources must be closed by their owning host main thread"))

  var first: HostError
  var failed = false
  if source.descriptorOpen:
    let closeStatus = posix.close(source.fdValue)
    source.fdValue = -1
    source.descriptorOpen = false
    if closeStatus != 0:
      first = signalError("could not close the Linux signal descriptor")
      failed = true

  if source.maskBlocked:
    var ignored: Sigset
    let restoreStatus = pthread_sigmask(
      SIG_SETMASK, source.previousMask, ignored)
    if restoreStatus != 0:
      let restored = pthreadError(
        "could not restore the host main-thread signal mask", restoreStatus)
      if not failed:
        first = restored
        failed = true
      else:
        first.context.add("; additional-cleanup=" & restored.message &
          " (" & restored.context & ")")
    else:
      source.maskBlocked = false
  if failed:
    return failure[Unit](move(first))
  success()
