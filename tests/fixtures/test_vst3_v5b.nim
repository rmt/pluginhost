import std/[options, os, posix, unittest]

import pluginhost/app/main_reactor
import pluginhost/domain/[reactor, result]
import pluginhost/gui/[controller, window_backend, window_host]
import pluginhost/platform/linux/reactor
import pluginhost/platform/x11/gui_adapter
import pluginhost/platform/x11/window_host as x11_window_host
import pluginhost/platform/linux/dynlib
import pluginhost/vst3/[editor, ffi, gui_client, host_context, instance, module, uid]

type
  ControllerProc = proc(): ptr Vst3EditController {.cdecl, raises: [].}
  SetIntProc = proc(value: int32) {.cdecl, raises: [].}
  VoidProc = proc() {.cdecl, raises: [].}
  CounterProc = proc(): uint32 {.cdecl, raises: [].}
  FloatProc = proc(): float32 {.cdecl, raises: [].}
  ResizeProc = proc(width, height: int32): int32 {.cdecl, raises: [].}
  ResizeState = object
    calls: uint32
    width: uint32
    height: uint32
    mark: VoidProc
  MarkedX11WindowBackend = ref object of X11WindowBackend
    mark: VoidProc

method resize*(backend: MarkedX11WindowBackend; width, height: uint32):
    Result[Unit] {.raises: [].} =
  result = procCall resize(X11WindowBackend(backend), width, height)
  if result.isOk and backend.mark != nil:
    backend.mark()


proc fixtureDirectory(): string =
  let value = getEnv("PLUGINHOST_VST3_V5B_FIXTURE_DIR")
  doAssert value.len > 0
  value

proc fixtureBundle(): string =
  fixtureDirectory() / "v5b.vst3"

proc openTestReactor(): MainReactor =
  var driver = openLinuxReactorDriver()
  doAssert driver.isOk
  var opened = initMainReactor(driver.value)
  doAssert opened.isOk
  move(opened.value)

proc openTestInstance(reactor: ptr MainReactor): Result[Vst3Instance] =
  var loaded = openVst3Module(fixtureBundle())
  if not loaded.isOk:
    return failure[Vst3Instance](move(loaded.error))
  var module = move(loaded.value)
  var classId = parseVst3Uid("102132435465768798A9BACBDCEDFEFF")
  if not classId.isOk:
    return failure[Vst3Instance](move(classId.error))
  openVst3Instance(module, classId.value, reactor)
proc fixtureBinary(): string =
  fixtureDirectory() / "v5b.vst3" / "Contents" / Vst3ArchitectureDir / "v5b.so"

proc resizeHost(context: pointer; width, height: uint32): bool {.
    cdecl, raises: [].} =
  if context == nil: return false
  let state = cast[ptr ResizeState](context)
  inc state.calls
  state.width = width
  state.height = height
  if state.mark != nil:
    state.mark()
  true

proc resolve[T](library: DynamicLibrary; name: string): T =
  let symbol = resolveSymbol[T](library, name)
  doAssert symbol.isOk
  symbol.value

suite "private VST3 V5B editor protocol":
  var opened = openDynamicLibrary(fixtureBinary(), keepLoaded = true)
  doAssert opened.isOk
  var library = move(opened.value)
  let controller = resolve[ControllerProc](library, "pluginhost_vst3_v5b_controller")
  let reset = resolve[VoidProc](library, "pluginhost_vst3_v5b_reset")
  let setNoScale = resolve[SetIntProc](library, "pluginhost_vst3_v5b_set_no_scale")
  let setFailAttach = resolve[SetIntProc](library, "pluginhost_vst3_v5b_set_fail_attach")
  let setMalformedScale = resolve[SetIntProc](library,
    "pluginhost_vst3_v5b_set_malformed_scale")
  let markResize = resolve[VoidProc](library, "pluginhost_vst3_v5b_mark_host_resize")
  let setHoldFrame = resolve[SetIntProc](library, "pluginhost_vst3_v5b_set_hold_frame")
  let releaseFrame = resolve[VoidProc](library, "pluginhost_vst3_v5b_release_frame")
  let requestResize = resolve[ResizeProc](library, "pluginhost_vst3_v5b_request_resize")
  let attached = resolve[CounterProc](library, "pluginhost_vst3_v5b_attached")
  let fdCallbacks = resolve[CounterProc](library,
    "pluginhost_vst3_v2a_runloop_fd_callbacks")
  let timerCallbacks = resolve[CounterProc](library,
    "pluginhost_vst3_v2a_runloop_timer_callbacks")
  let focusCalls = resolve[CounterProc](library, "pluginhost_vst3_v5b_focus_calls")
  let componentTerminate = resolve[CounterProc](library,
    "pluginhost_vst3_v2a_component_terminate")
  let scaleCalls = resolve[CounterProc](library, "pluginhost_vst3_v5b_scale_calls")
  let scale = resolve[FloatProc](library, "pluginhost_vst3_v5b_scale")
  let orderBad = resolve[CounterProc](library, "pluginhost_vst3_v5b_resize_order_bad")
  let scaleRefs = resolve[CounterProc](library, "pluginhost_vst3_v5b_scale_refs")
  test "content scale is optional and focus is delivered":
    reset()
    var parentResult = x11_window_host.openX11WindowHost()
    require parentResult.isOk
    var parent = move(parentResult.value)
    defer:
      check parent.close().isOk
    var state: ResizeState
    var created = createVst3Editor(controller(), pthread_self(),
      parent.windowId, Vst3EditorHost(context: addr state, resize: resizeHost))
    require created.isOk
    var editor = move(created.value)
    check editor.setContentScale(1.5).value
    check scaleCalls() == 1
    check scale() == 1.5'f32
    check scaleRefs() == 1
    check editor.focus(true).value
    check focusCalls() == 1
    check editor.close().isOk

    reset()
    setNoScale(1)
    created = createVst3Editor(controller(), pthread_self(), parent.windowId,
      Vst3EditorHost(context: addr state, resize: resizeHost))
    require created.isOk
    editor = move(created.value)
    check not editor.setContentScale(2.0).value
    check editor.close().isOk
    setNoScale(0)
    setMalformedScale(1)
    created = createVst3Editor(controller(), pthread_self(), parent.windowId,
      Vst3EditorHost(context: addr state, resize: resizeHost))
    require created.isOk
    editor = move(created.value)
    check not editor.setContentScale(1.25).isOk
    check not editor.close().isOk
    setMalformedScale(0)
    check editor.close().isOk
    check scaleRefs() == 1


  test "attachment and synchronous frame resize are ordered":
    reset()
    var parentResult = x11_window_host.openX11WindowHost()
    require parentResult.isOk
    var parent = move(parentResult.value)
    defer:
      check parent.close().isOk
    var state: ResizeState
    state.mark = markResize
    var created = createVst3Editor(controller(), pthread_self(),
      parent.windowId, Vst3EditorHost(context: addr state, resize: resizeHost))
    require created.isOk
    var editor = move(created.value)
    check attached() == 1
    check requestResize(333, 221) == Vst3ResultOk
    check state.calls == 1
    check state.width == 334
    check state.height == 240
    check orderBad() == 0
    check editor.close().isOk

  test "failed attachment rolls back and can be retried":
    reset()
    setFailAttach(1)
    var state: ResizeState
    var created = createVst3Editor(controller(), pthread_self(), 3'u64,
      Vst3EditorHost(context: addr state, resize: resizeHost))
    check not created.isOk
    setFailAttach(0)
    created = createVst3Editor(controller(), pthread_self(), 3'u64,
      Vst3EditorHost(context: addr state, resize: resizeHost))
    require created.isOk
    check created.value.close().isOk

  test "production adapter/controller keeps run loop and X11 lifecycle coherent":
    reset()
    var reactor = openTestReactor()
    var opened = openTestInstance(addr reactor)
    require opened.isOk
    var instance = move(opened.value)
    var client = newVst3GuiClient(instance)
    var produced: MarkedX11WindowBackend
    let factory: WindowHostFactory = proc(): WindowHostBackend =
      new(produced)
      produced.mark = markResize
      produced
    var controller = newGuiController(client, addr reactor, factory, "V5B",
      some(1.5))
    check controller.start(false).isOk
    check controller.isCreated
    check not controller.isVisible
    check attached() == 1
    for _ in 0 ..< 16:
      var hiddenEvents = reactor.wait(monotonicNanos(10_000_000))
      require hiddenEvents.isOk
      instance.hostContextPointer().dispatchRunLoopEvents(hiddenEvents.value)
      check controller.handleWindowEvents(hiddenEvents.value).isOk
      if fdCallbacks() > 0 and timerCallbacks() > 0: break
    check fdCallbacks() > 0
    check timerCallbacks() > 0
    check controller.show().isOk
    check controller.hide().isOk
    check attached() == 1
    check controller.show().isOk
    let focusBeforeFocus = focusCalls()
    check produced.focus().isOk
    for _ in 0 ..< 8:
      var focused = reactor.wait(monotonicNanos(20_000_000))
      require focused.isOk
      instance.hostContextPointer().dispatchRunLoopEvents(focused.value)
      check controller.handleWindowEvents(focused.value).isOk
      if focusCalls() > focusBeforeFocus: break
    check focusCalls() > focusBeforeFocus
    check produced.blur().isOk
    check requestResize(333, 221) == Vst3ResultOk
    check produced.width == 334'u32
    check produced.height == 240'u32
    check orderBad() == 0
    check fdCallbacks() > 0
    check timerCallbacks() > 0
    check controller.close().isOk
    check controller.fileDescriptor == -1
    var recreated = newGuiController(client, addr reactor, factory, "V5B recreated")
    check recreated.start(false).isOk
    check recreated.isCreated
    check attached() == 2
    check recreated.close().isOk

    setFailAttach(1)
    setHoldFrame(1)
    var retainedController = newGuiController(client, addr reactor, factory, "V5B retry")
    check not retainedController.start(false).isOk
    let retainedFd = retainedController.fileDescriptor
    check retainedFd >= 0
    check produced.state != whClosed
    check not retainedController.close().isOk
    check retainedController.fileDescriptor == retainedFd
    check produced.state != whClosed
    releaseFrame()
    var retainedCleanupSucceeded = false
    for _ in 0 ..< 3:
      var cleaned = retainedController.close()
      if cleaned.isOk:
        retainedCleanupSucceeded = true
        break
    check retainedCleanupSucceeded
    check retainedController.fileDescriptor == -1
    check produced.state == whClosed
    setFailAttach(0)
    setHoldFrame(0)
    check instance.close().isOk
    check componentTerminate() > 0
    check reactor.close().isOk

  doAssert library.close().isOk
