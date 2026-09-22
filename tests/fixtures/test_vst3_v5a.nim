import std/[os, posix, unittest]

import pluginhost/domain/result
import pluginhost/platform/linux/dynlib
import pluginhost/vst3/[editor, ffi, module]

type
  ControllerProc = proc(): ptr Vst3EditController {.cdecl, raises: [].}
  SetIntProc = proc(value: int32) {.cdecl, raises: [].}
  VoidProc = proc() {.cdecl, raises: [].}
  CounterProc = proc(): uint32 {.cdecl, raises: [].}
  ResizeProc = proc(width, height: int32): int32 {.cdecl, raises: [].}
  ResizeState = object
    calls: uint32
    width: uint32
    height: uint32
    mark: VoidProc

proc fixtureDirectory(): string =
  let value = getEnv("PLUGINHOST_VST3_V5A_FIXTURE_DIR")
  doAssert value.len > 0
  value

proc fixtureBinary(): string =
  fixtureDirectory() / "v5a.vst3" / "Contents" / Vst3ArchitectureDir / "v5a.so"

proc resizeHost(context: pointer; width, height: uint32): bool {.
    cdecl, raises: [].} =
  if context == nil:
    return false
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

suite "private VST3 V5A editor ownership":
  var opened = openDynamicLibrary(fixtureBinary(), keepLoaded = true)
  doAssert opened.isOk
  var library = move(opened.value)
  let controller = resolve[ControllerProc](library,
    "pluginhost_vst3_v5a_controller")
  let reset = resolve[VoidProc](library, "pluginhost_vst3_v5a_reset")
  let setNull = resolve[SetIntProc](library,
    "pluginhost_vst3_v5a_set_null_view")
  let setX11 = resolve[SetIntProc](library,
    "pluginhost_vst3_v5a_set_support_x11")
  let setInvalid = resolve[SetIntProc](library,
    "pluginhost_vst3_v5a_set_invalid_size")
  let setFrameFail = resolve[SetIntProc](library,
    "pluginhost_vst3_v5a_set_fail_set_frame")
  let setAttachFail = resolve[SetIntProc](library,
    "pluginhost_vst3_v5a_set_fail_attach")
  let setRemoveFail = resolve[SetIntProc](library,
    "pluginhost_vst3_v5a_set_fail_remove")
  let setNilRelease = resolve[SetIntProc](library,
    "pluginhost_vst3_v5a_set_nil_release")
  let setNilOnSize = resolve[SetIntProc](library,
    "pluginhost_vst3_v5a_set_nil_on_size")
  let setHold = resolve[SetIntProc](library,
    "pluginhost_vst3_v5a_set_hold_frame")
  let releaseFrame = resolve[VoidProc](library,
    "pluginhost_vst3_v5a_release_frame")
  let requestResize = resolve[ResizeProc](library,
    "pluginhost_vst3_v5a_request_resize")
  let onSizeCalls = resolve[CounterProc](library,
    "pluginhost_vst3_v5a_on_size_calls")
  let constraintCalls = resolve[CounterProc](library,
    "pluginhost_vst3_v5a_constraint_calls")
  let markHostResize = resolve[VoidProc](library,
    "pluginhost_vst3_v5a_mark_host_resize")
  let resizeOrderBad = resolve[CounterProc](library,
    "pluginhost_vst3_v5a_resize_order_bad")
  let frameAddrefs = resolve[CounterProc](library,
    "pluginhost_vst3_v5a_frame_addrefs")
  let frameReleases = resolve[CounterProc](library,
    "pluginhost_vst3_v5a_frame_releases")

  proc host(state: var ResizeState): Vst3EditorHost =
    Vst3EditorHost(context: addr state, resize: resizeHost)

  proc open(state: var ResizeState): Result[Vst3Editor] =
    createVst3Editor(controller(), pthread_self(), 1'u64, host(state))

  test "null and unsupported views are unavailable":
    reset()
    setNull(1)
    var state: ResizeState
    check not open(state).isOk
    reset()
    setX11(0)
    check not open(state).isOk

  test "invalid initial size and frame or attachment failure roll back":
    reset()
    setInvalid(1)
    var state: ResizeState
    check not open(state).isOk
    reset()
    setFrameFail(1)
    check not open(state).isOk
    check editorRootCount() == 0
    check frameAddrefs() == frameReleases()
    reset()
    setAttachFail(1)
    check not open(state).isOk
    reset()
    setHold(1)
    setAttachFail(1)
    check not open(state).isOk
    check editorRootCount() == 1
    releaseFrame()
    check editorRootCount() == 0
    reset()
    setNilOnSize(1)
    check not open(state).isOk
    check editorRootCount() == 0
    reset()
    setNilRelease(1)
    check not open(state).isOk
    check editorRootCount() == 1
    setNilRelease(0)
    let quarantined = retainedEditorForController(controller())
    require quarantined != nil
    check quarantined.close().isOk
    check editorRootCount() == 0

  test "size operations enforce positive bounds and constraints":
    reset()
    var state: ResizeState
    var created = open(state)
    require created.isOk
    var editor = move(created.value)
    check editorCanResize(editor).value
    var invalid = Vst3ViewRect(left: 0, top: 0, right: 0, bottom: 10)
    check not editorCheckSizeConstraint(editor, invalid).isOk
    let beforeConstraints = constraintCalls()
    let resized = resizeVst3Editor(editor,
      Vst3ViewRect(left: 0, top: 0, right: 101, bottom: 99))
    require resized.isOk
    check state.width == 320'u32
    check state.height == 240'u32
    check constraintCalls() == beforeConstraints + 1'u32
    check onSizeCalls() > 0'u32
    check editor.close().isOk

  test "frame resize applies host before synchronous onSize":
    reset()
    var state: ResizeState
    var created = open(state)
    state.mark = markHostResize
    require created.isOk
    var editor = move(created.value)
    let before = onSizeCalls()
    check requestResize(333, 221) == Vst3ResultOk
    check state.calls == 1'u32
    check state.width == 334'u32
    check state.height == 240'u32
    check onSizeCalls() == before + 1'u32
    check resizeOrderBad() == 0'u32
    check editor.close().isOk

  test "remove failure and retained frames make close retryable":
    reset()
    var state: ResizeState
    var created = open(state)
    require created.isOk
    var editor = move(created.value)
    setRemoveFail(1)
    check not editor.close().isOk
    setRemoveFail(0)
    setHold(1)
    check not editor.close().isOk
    check editor.frameReferenceCount() > 1'u32
    releaseFrame()
    check editor.close().isOk
    check editor.close().isOk

  test "editor can be removed and recreated after explicit close":
    reset()
    var state: ResizeState
    var first = open(state)
    require first.isOk
    var editor = move(first.value)
    check removeVst3Editor(editor).isOk
    check not editor.isAttached
    check attachVst3Editor(editor, 2'u64).isOk
    check editor.isAttached
    check removeVst3Editor(editor).isOk
    setFrameFail(1)
    check not attachVst3Editor(editor, 3'u64).isOk
    setFrameFail(0)
    check editor.close().isOk
    check frameAddrefs() == frameReleases()
    var second = open(state)
    require second.isOk
    check second.value.close().isOk

  doAssert library.close().isOk
