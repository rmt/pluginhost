## Main-thread CLAP GUI policy and lifecycle controller.
##
## This controller never runs from JACK or a foreign callback. Plugin callbacks
## publish bounded requests through ClapHostBridge; the session drains those
## requests here at a reactor safe point.

import std/options

import ../app/main_reactor
import ../clap/host_bridge
import ../domain/[errors, reactor, result]
import ./[plugin_client, window_backend, window_host]

const
  InitialWindowWidth = 640'u32
  InitialWindowHeight = 480'u32
  MaxWindowEventsPerTurn = 128

type
  GuiControllerState* = enum
    gcsDisabled
    gcsUncreated
    gcsHidden
    gcsVisible
    gcsUnavailable
    gcsClosed

  GuiMode* = enum
    gmNone
    gmEmbedded
    gmFloating

  GuiController* = ref object
    plugin: GuiPluginClient
    reactor: ptr MainReactor
    factory: WindowHostFactory
    window: WindowHostBackend
    token: ReactorToken
    tokenRegistered: bool
    stateValue: GuiControllerState
    modeValue: GuiMode
    pluginCreated: bool
    titleValue: string
    scaleValue: Option[float]
    sizeValue: GuiSize
    resizeHintsValue: GuiResizeHints
    canResizeValue: bool
    pendingHostSize: GuiSize
    hasPendingHostSize: bool

proc controllerError(message: string; detail = ""): HostError =
  hostError(hsGui, hekGui, message, detail)

proc addCleanupDetail(primary: var HostError; cleanup: Result[Unit]) =
  if not cleanup.isOk:
    primary.context.add("; cleanup=" & cleanup.error.message)
    if cleanup.error.context.len > 0:
      primary.context.add(" (" & cleanup.error.context & ")")

proc newGuiController*(plugin: GuiPluginClient; reactor: ptr MainReactor;
                       factory: WindowHostFactory; title: string;
                       scale = none(float64); disabled = false): GuiController =
  new(result)
  result.plugin = plugin
  result.reactor = reactor
  result.factory = factory
  result.titleValue = title
  result.scaleValue = scale
  result.stateValue = if disabled: gcsDisabled else: gcsUncreated
  result.modeValue = gmNone

proc state*(controller: GuiController): GuiControllerState {.inline.} =
  if controller == nil: gcsClosed else: controller.stateValue

proc mode*(controller: GuiController): GuiMode {.inline.} =
  if controller == nil: gmNone else: controller.modeValue

proc isAvailable*(controller: GuiController): bool {.inline.} =
  controller != nil and controller.stateValue notin {gcsDisabled, gcsUnavailable, gcsClosed}

proc isCreated*(controller: GuiController): bool {.inline.} =
  controller != nil and controller.pluginCreated

proc isVisible*(controller: GuiController): bool {.inline.} =
  controller != nil and controller.stateValue == gcsVisible

proc fileDescriptor*(controller: GuiController): int32 {.inline.} =
  if controller == nil or controller.window == nil:
    return -1'i32
  controller.window.fileDescriptor

proc size*(controller: GuiController): GuiSize {.inline.} =
  if controller == nil: GuiSize() else: controller.sizeValue

proc canResize*(controller: GuiController): bool {.inline.} =
  controller != nil and controller.canResizeValue

proc cleanupSurface(controller: GuiController;
                       pluginWindowAlreadyDestroyed = false): Result[Unit] =
  if controller == nil:
    return success()

  var first: HostError
  var failed = false

  if controller.pluginCreated:
    if not pluginWindowAlreadyDestroyed and controller.stateValue == gcsVisible:
      var hidden = controller.plugin.hide()
      if not hidden.isOk:
        first = move(hidden.error)
        failed = true
      elif not hidden.value:
        first = controllerError("CLAP plugin rejected GUI hide during cleanup")
        failed = true
    var destroyed = controller.plugin.destroy()
    if not destroyed.isOk:
      if not failed:
        first = move(destroyed.error)
        failed = true
      else:
        addCleanupDetail(first, destroyed)
    else:
      controller.pluginCreated = false

  if controller.tokenRegistered:
    if controller.reactor == nil:
      if not failed:
        first = controllerError("GUI reactor registration has no owner")
        failed = true
    else:
      var removed = controller.reactor[].removeFd(controller.token)
      if not removed.isOk:
        if not failed:
          first = move(removed.error)
          failed = true
        else:
          addCleanupDetail(first, removed)
      else:
        controller.tokenRegistered = false

  # Do not close an X connection while its descriptor remains registered. A
  # later retry can remove the stale registration before releasing the window.
  if not controller.tokenRegistered and controller.window != nil:
    var closed = controller.window.close()
    if not closed.isOk:
      if not failed:
        first = move(closed.error)
        failed = true
      else:
        addCleanupDetail(first, closed)
    else:
      controller.window = nil

  if failed:
    return failure[Unit](move(first))
  controller.modeValue = gmNone
  controller.hasPendingHostSize = false
  success()

proc failCreation(controller: GuiController; primary: sink HostError): Result[Unit] =
  var error = move(primary)
  let cleaned = controller.cleanupSurface()
  addCleanupDetail(error, cleaned)
  controller.stateValue = gcsUnavailable
  failure[Unit](move(error))

proc validateSize(size: GuiSize): bool {.inline.} =
  size.width > 0'u32 and size.height > 0'u32 and
    size.width <= uint32(high(int32)) and size.height <= uint32(high(int32))

proc ensureCreated*(controller: GuiController): Result[Unit] =
  if controller == nil:
    return failure[Unit](controllerError("GUI controller is not initialized"))
  if controller.stateValue == gcsDisabled:
    return failure[Unit](controllerError("GUI hosting is disabled"))
  if controller.stateValue in {gcsHidden, gcsVisible}:
    return success()
  if controller.stateValue == gcsClosed:
    return failure[Unit](controllerError("GUI controller is closed"))
  if controller.pluginCreated or controller.tokenRegistered or controller.window != nil:
    return failure[Unit](controllerError(
      "previous GUI resources require explicit cleanup before recreation"))
  if controller.plugin == nil or not controller.plugin.available:
    controller.stateValue = gcsUnavailable
    return failure[Unit](controllerError(
      "CLAP plugin does not provide a usable GUI extension"))
  if controller.reactor == nil or controller.factory == nil:
    controller.stateValue = gcsUnavailable
    return failure[Unit](controllerError(
      "GUI hosting requires a main reactor and window backend"))

  let embedded = controller.plugin.isApiSupported(gwaX11, false)
  let floating = if embedded: false else:
      controller.plugin.isApiSupported(gwaX11, true)
  if not embedded and not floating:
    controller.stateValue = gcsUnavailable
    return failure[Unit](controllerError(
      "CLAP plugin supports neither embedded nor floating X11 GUI hosting"))

  controller.modeValue = if embedded: gmEmbedded else: gmFloating
  controller.window = controller.factory()
  if controller.window == nil:
    controller.modeValue = gmNone
    controller.stateValue = gcsUnavailable
    return failure[Unit](controllerError("GUI window backend factory returned nil"))

  var opened = controller.window.open(
    controller.titleValue, InitialWindowWidth, InitialWindowHeight)
  if not opened.isOk:
    controller.modeValue = gmNone
    controller.window = nil
    controller.stateValue = gcsUnavailable
    return failure[Unit](move(opened.error))

  var registered = controller.reactor[].registerFd(
    controller.window.fileDescriptor, {riRead, riError, riHangup})
  if not registered.isOk:
    var primary = move(registered.error)
    let closed = controller.window.close()
    addCleanupDetail(primary, closed)
    controller.window = nil
    controller.modeValue = gmNone
    controller.stateValue = gcsUnavailable
    return failure[Unit](move(primary))
  controller.token = registered.value
  controller.tokenRegistered = true

  var created = controller.plugin.create(gwaX11, not embedded)
  if not created.isOk:
    return controller.failCreation(move(created.error))
  if not created.value:
    return controller.failCreation(controllerError(
      "CLAP plugin rejected GUI creation", "api=x11; floating=" & $(not embedded)))
  controller.pluginCreated = true

  if embedded:
    if controller.scaleValue.isSome:
      var scaled = controller.plugin.setScale(float64(controller.scaleValue.get()))
      if not scaled.isOk:
        return controller.failCreation(move(scaled.error))
      # A plugin may return false when it cannot apply an optional scale. The
      # GUI remains usable at its native scale in that case.

    var resizeable = controller.plugin.canResize()
    if not resizeable.isOk:
      return controller.failCreation(move(resizeable.error))
    controller.canResizeValue = resizeable.value
    if resizeable.value:
      var hints: GuiResizeHints
      var gotHints = controller.plugin.getResizeHints(hints)
      if not gotHints.isOk:
        return controller.failCreation(move(gotHints.error))
      if gotHints.value:
        controller.resizeHintsValue = hints

    # There is no persisted GUI size in this increment, so use the plugin's
    # current size after negotiating resize support.
    var reportedSize = controller.plugin.getSize()
    if not reportedSize.isOk:
      return controller.failCreation(move(reportedSize.error))
    if not validateSize(reportedSize.value):
      return controller.failCreation(controllerError(
        "CLAP plugin reported an invalid GUI size"))
    var resized = controller.window.resize(
      reportedSize.value.width, reportedSize.value.height)
    if not resized.isOk:
      return controller.failCreation(move(resized.error))
    controller.pendingHostSize = reportedSize.value
    controller.hasPendingHostSize = true
    controller.sizeValue = reportedSize.value

    var parent = controller.plugin.setParent(controller.window.handle)
    if not parent.isOk:
      return controller.failCreation(move(parent.error))
    if not parent.value:
      return controller.failCreation(controllerError(
        "CLAP plugin rejected the X11 parent window"))
  else:
    var transient = controller.plugin.setTransient(controller.window.handle)
    if not transient.isOk:
      return controller.failCreation(move(transient.error))
    if not transient.value:
      return controller.failCreation(controllerError(
        "CLAP plugin rejected the X11 transient window"))
    var title = controller.plugin.suggestTitle(controller.titleValue)
    if not title.isOk:
      return controller.failCreation(move(title.error))

  controller.stateValue = gcsHidden
  success()

proc show*(controller: GuiController): Result[Unit]
proc start*(controller: GuiController; showInitially: bool): Result[Unit] =
  var created = controller.ensureCreated()
  if not created.isOk:
    return created
  if showInitially:
    return controller.show()
  success()

proc show*(controller: GuiController): Result[Unit] =
  if controller == nil:
    return failure[Unit](controllerError("GUI controller is not initialized"))
  if controller.stateValue == gcsDisabled:
    return failure[Unit](controllerError("GUI hosting is disabled"))
  if controller.stateValue == gcsVisible:
    return success()
  var created = controller.ensureCreated()
  if not created.isOk:
    return created

  if controller.modeValue == gmEmbedded:
    var mapped = controller.window.show()
    if not mapped.isOk:
      return mapped
  var shown = controller.plugin.show()
  if not shown.isOk:
    if controller.modeValue == gmEmbedded:
      let hidden = controller.window.hide()
      addCleanupDetail(shown.error, hidden)
    return failure[Unit](move(shown.error))
  if not shown.value:
    var rejected = controllerError("CLAP plugin rejected GUI show")
    if controller.modeValue == gmEmbedded:
      let hidden = controller.window.hide()
      addCleanupDetail(rejected, hidden)
    return failure[Unit](move(rejected))
  controller.stateValue = gcsVisible
  success()

proc hide*(controller: GuiController): Result[Unit] =
  if controller == nil:
    return failure[Unit](controllerError("GUI controller is not initialized"))
  if controller.stateValue in {gcsDisabled, gcsUncreated, gcsUnavailable, gcsClosed,
                               gcsHidden}:
    return success()

  var first: HostError
  var failed = false
  var hidden = controller.plugin.hide()
  if not hidden.isOk:
    first = move(hidden.error)
    failed = true
  elif not hidden.value:
    first = controllerError("CLAP plugin rejected GUI hide")
    failed = true
  if controller.modeValue == gmEmbedded:
    var unmapped = controller.window.hide()
    if not unmapped.isOk:
      if not failed:
        first = move(unmapped.error)
        failed = true
      else:
        addCleanupDetail(first, unmapped)
  if failed:
    return failure[Unit](move(first))
  controller.stateValue = gcsHidden
  success()

proc resizeFromPlugin(controller: GuiController; size: GuiSize): Result[Unit] =
  if controller.modeValue != gmEmbedded or not controller.pluginCreated:
    return failure[Unit](controllerError(
      "embedded GUI resize requires a created embedded X11 GUI"))
  if not validateSize(size):
    return failure[Unit](controllerError("requested GUI size is invalid"))
  let resized = controller.window.resize(size.width, size.height)
  if not resized.isOk:
    return resized
  controller.sizeValue = size
  controller.pendingHostSize = size
  controller.hasPendingHostSize = true
  success()

proc handlePluginRequests*(controller: GuiController;
                           requests: ClapGuiRequests): Result[Unit] =
  if controller == nil or controller.stateValue in {gcsDisabled, gcsClosed}:
    return success()

  if requests.closed:
    if requests.wasDestroyed:
      # CLAP's was_destroyed flag means the host must acknowledge the
      # plugin-side window loss by calling clap_plugin_gui.destroy().
      var destroyed = controller.cleanupSurface(
        pluginWindowAlreadyDestroyed = true)
      if not destroyed.isOk:
        return destroyed
      controller.stateValue = gcsUncreated
    else:
      if controller.pluginCreated:
        if controller.modeValue == gmEmbedded and controller.window != nil:
          var hidden = controller.window.hide()
          if not hidden.isOk:
            return hidden
        controller.stateValue = gcsHidden
      else:
        controller.stateValue = gcsUncreated

  if requests.resizeHints and controller.pluginCreated and
      controller.modeValue == gmEmbedded:
    var resizeable = controller.plugin.canResize()
    if not resizeable.isOk:
      return failure[Unit](move(resizeable.error))
    controller.canResizeValue = resizeable.value
    if resizeable.value:
      var hints: GuiResizeHints
      var gotHints = controller.plugin.getResizeHints(hints)
      if not gotHints.isOk:
        return failure[Unit](move(gotHints.error))
      if gotHints.value:
        controller.resizeHintsValue = hints

  if requests.resize and controller.pluginCreated:
    var resized = controller.resizeFromPlugin(GuiSize(
      width: requests.width, height: requests.height))
    if not resized.isOk:
      return resized

  # A hide request wins when both bits were coalesced in one turn.
  if requests.hide:
    var hidden = controller.hide()
    if not hidden.isOk:
      return hidden
  elif requests.show:
    var shown = controller.show()
    if not shown.isOk:
      return shown
  success()

proc handleWindowEvents*(controller: GuiController;
                         events: seq[ReactorEvent]): Result[Unit] =
  if controller == nil or not controller.tokenRegistered or controller.window == nil:
    return success()
  var ready = false
  for event in events:
    if event.kind == rekFd and event.token == controller.token:
      if riError in event.interests or riHangup in event.interests:
        return failure[Unit](controllerError(
          "X11 connection became unavailable", "fd=" & $controller.window.fileDescriptor))
      if riRead in event.interests:
        ready = true
  if not ready:
    return success()

  for ignored in 0 ..< MaxWindowEventsPerTurn:
    discard ignored
    var polled = controller.window.pollEvent()
    if not polled.isOk:
      return failure[Unit](move(polled.error))
    if not polled.value.available:
      break
    case polled.value.event.kind
    of wekClose:
      var closed = controller.cleanupSurface()
      if not closed.isOk:
        return closed
      controller.stateValue = gcsUncreated
      break
    of wekConfigure:
      let incoming = GuiSize(width: polled.value.event.width,
                             height: polled.value.event.height)
      if not validateSize(incoming):
        continue
      controller.sizeValue = incoming
      if controller.modeValue == gmEmbedded and controller.pluginCreated:
        if controller.hasPendingHostSize and
            controller.pendingHostSize.width == incoming.width and
            controller.pendingHostSize.height == incoming.height:
          controller.hasPendingHostSize = false
        elif controller.canResizeValue:
          var adjusted = incoming
          var adjustedResult = controller.plugin.adjustSize(adjusted)
          if not adjustedResult.isOk:
            return failure[Unit](move(adjustedResult.error))
          if adjustedResult.value:
            let resized = controller.window.resize(adjusted.width, adjusted.height)
            if not resized.isOk:
              return resized
            controller.pendingHostSize = adjusted
            controller.hasPendingHostSize = true
            controller.sizeValue = adjusted
          var accepted = controller.plugin.setSize(adjusted)
          if not accepted.isOk:
            return failure[Unit](move(accepted.error))
          if not accepted.value:
            return failure[Unit](controllerError(
              "CLAP plugin rejected the host-requested GUI size"))
    of wekMap:
      if controller.stateValue != gcsHidden:
        controller.stateValue = gcsVisible
    of wekUnmap:
      if controller.stateValue == gcsVisible:
        controller.stateValue = gcsHidden
    else:
      discard
  success()

proc close*(controller: GuiController): Result[Unit] =
  if controller == nil:
    return success()
  if controller.stateValue == gcsClosed:
    return success()
  let cleaned = controller.cleanupSurface()
  if not cleaned.isOk:
    return cleaned
  controller.plugin = nil
  controller.reactor = nil
  controller.factory = nil
  controller.stateValue = gcsClosed
  success()
