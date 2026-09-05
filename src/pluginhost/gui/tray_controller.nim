## Main-thread tray lifecycle and reactor controller.
##
## The controller reports only bounded activation requests. The application
## decides what activation means, keeping tray protocol code independent of the
## plugin GUI state machine.

import ../app/main_reactor
import ../domain/[errors, reactor, result]
import ./[icon, tray_icon]

const
  MaxTrayEventsPerTurn = 128

type
  TrayControllerState* = enum
    tcsUncreated
    tcsOpen
    tcsUnavailable
    tcsClosed
  TrayController* = ref object
    reactor: ptr MainReactor
    factory: TrayIconFactory
    backend: TrayIconBackend
    token: ReactorToken
    tokenRegistered: bool
    titleValue: string
    iconValue: GuiIcon
    stateValue: TrayControllerState
proc trayControllerError(message: string; detail = ""): HostError =
  hostError(hsGui, hekGui, message, detail)

proc addCleanupDetail(primary: var HostError; cleanup: Result[Unit]) =
  if not cleanup.isOk:
    primary.context.add("; cleanup=" & cleanup.error.message)
    if cleanup.error.context.len > 0:
      primary.context.add(" (" & cleanup.error.context & ")")

proc newTrayController*(reactor: ptr MainReactor;
                        factory: TrayIconFactory; title: string;
                        icon: GuiIcon = nil): TrayController =
  new(result)
  result.reactor = reactor
  result.factory = factory
  result.titleValue = title
  result.iconValue = if icon == nil: defaultGuiIcon() else: icon
  result.stateValue = tcsUncreated

proc state*(controller: TrayController): TrayControllerState {.inline.} =
  if controller == nil: tcsClosed else: controller.stateValue

proc isOpen*(controller: TrayController): bool {.inline.} =
  controller != nil and controller.stateValue == tcsOpen

proc fileDescriptor*(controller: TrayController): int32 {.inline.} =
  if controller == nil or controller.backend == nil:
    -1'i32
  else:
    controller.backend.fileDescriptor

proc start*(controller: TrayController): Result[Unit] =
  if controller == nil:
    return failure[Unit](trayControllerError(
      "tray controller is not initialized"))
  if controller.stateValue == tcsOpen:
    return success()
  if controller.stateValue == tcsClosed:
    return failure[Unit](trayControllerError(
      "tray controller is closed"))
  if controller.factory == nil or controller.reactor == nil:
    controller.stateValue = tcsUnavailable
    return failure[Unit](trayControllerError(
      "tray hosting requires a main reactor and backend"))

  controller.backend = controller.factory()
  if controller.backend == nil:
    controller.stateValue = tcsUnavailable
    return failure[Unit](trayControllerError(
      "tray icon backend factory returned nil"))

  var opened = controller.backend.open(controller.titleValue, controller.iconValue)
  if not opened.isOk:
    discard controller.backend.close()
    controller.backend = nil
    controller.stateValue = tcsUnavailable
    return failure[Unit](move(opened.error))

  let fd = controller.backend.fileDescriptor
  if fd < 0:
    var primary = trayControllerError(
      "tray icon backend returned an invalid descriptor")
    let closed = controller.backend.close()
    addCleanupDetail(primary, closed)
    controller.backend = nil
    controller.stateValue = tcsUnavailable
    return failure[Unit](move(primary))

  var registered = controller.reactor[].registerFd(fd, {riRead, riError, riHangup})
  if not registered.isOk:
    var primary = move(registered.error)
    let closed = controller.backend.close()
    addCleanupDetail(primary, closed)
    controller.backend = nil
    controller.stateValue = tcsUnavailable
    return failure[Unit](move(primary))
  controller.token = registered.value
  controller.tokenRegistered = true
  controller.stateValue = tcsOpen
  success()

proc close*(controller: TrayController): Result[Unit]

proc handleEvents*(controller: TrayController;
                   events: openArray[ReactorEvent]): Result[bool] =
  if controller == nil or controller.stateValue != tcsOpen or
      not controller.tokenRegistered or controller.backend == nil:
    return success(false)
  var ready = false
  for event in events:
    if event.kind == rekFd and event.token == controller.token:
      if riError in event.interests or riHangup in event.interests:
        return failure[bool](trayControllerError(
          "tray icon connection became unavailable",
          "fd=" & $controller.backend.fileDescriptor))
      if riRead in event.interests:
        ready = true
  if not ready:
    return success(false)

  var activated = false
  for ignored in 0 ..< MaxTrayEventsPerTurn:
    discard ignored
    var polled = controller.backend.pollEvent()
    if not polled.isOk:
      return failure[bool](move(polled.error))
    if not polled.value.available:
      break
    case polled.value.event.kind
    of tekActivate:
      activated = true
    of tekClosed:
      var closed = controller.close()
      if not closed.isOk:
        return failure[bool](move(closed.error))
      break
    of tekOther:
      discard
  success(activated)

proc close*(controller: TrayController): Result[Unit] =
  if controller == nil or controller.stateValue == tcsClosed:
    return success()

  var first: HostError
  var failed = false
  if controller.tokenRegistered:
    if controller.reactor == nil:
      first = trayControllerError(
        "tray reactor registration has no owner")
      failed = true
    else:
      var removed = controller.reactor[].removeFd(controller.token)
      if not removed.isOk:
        first = move(removed.error)
        failed = true
      else:
        controller.tokenRegistered = false
  if not controller.tokenRegistered and controller.backend != nil:
    var closed = controller.backend.close()
    if not closed.isOk:
      if not failed:
        first = move(closed.error)
        failed = true
      else:
        addCleanupDetail(first, closed)
    else:
      controller.backend = nil
  if failed:
    return failure[Unit](move(first))
  controller.reactor = nil
  controller.factory = nil
  controller.stateValue = tcsClosed
  success()
