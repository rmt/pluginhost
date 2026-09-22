## Private VST3 IPlugView/IPlugFrame ownership.
##
## This module intentionally stops at the borrowed host resize seam.  It does
## not own an X11 display/window, dispatch events, or participate in the
## generic GuiController policy.  Every operation is synchronous and must run
## on the instance's recorded main thread.

import std/posix

import ../domain/[errors, result]
import ./[ffi, uid]

type
  Vst3EditorResizeProc* = proc(context: pointer; width, height: uint32): bool {.
    cdecl, raises: [].}

  ## Borrowed host capability used only while an editor is open.  The owner of
  ## context remains responsible for its lifetime; this module never releases
  ## or otherwise interprets it.
  Vst3EditorHost* {.bycopy.} = object
    context*: pointer
    resize*: Vst3EditorResizeProc

  Vst3EditorSize* {.bycopy.} = object
    width*: uint32
    height*: uint32

  Vst3Editor* = ref Vst3EditorState

  Vst3EditorFrame = object
    iface: Vst3IPlugFrame
    vtable: Vst3IPlugFrameVtbl
    owner: ptr Vst3EditorState

  Vst3EditorState = object
    controller: ptr Vst3EditController
    view: ptr Vst3IPlugView
    frame: Vst3EditorFrame
    mainThread: Pthread
    host: Vst3EditorHost
    parentWindowId: uint64
    size: Vst3ViewRect
    frameReferences: uint32
    frameOwnerReleased: bool
    attached: bool
    frameInstalled: bool
    viewReleased: bool
    closePending: bool
    closed: bool

const
  EditorName = "editor"
  MaxVst3EditorDimension = 32768'i64

const MaxVst3EditorRoots = 64
var editorRoots: array[MaxVst3EditorRoots, Vst3Editor]

proc hasEditorRootCapacity(): bool =
  for editor in editorRoots:
    if editor == nil:
      return true
  false

proc claimEditorRoot(editor: Vst3Editor): bool =
  if editor == nil:
    return false
  for index in 0 ..< MaxVst3EditorRoots:
    if editorRoots[index] == nil:
      editorRoots[index] = editor
      return true
  false


proc findEditorRootState(state: ptr Vst3EditorState): Vst3Editor =
  if state == nil:
    return nil
  for editor in editorRoots:
    if editor != nil and addr(editor[]) == state:
      return editor
  nil
proc retainedEditorForController*(controller: ptr Vst3EditController): Vst3Editor =
  if controller == nil:
    return nil
  for editor in editorRoots:
    if editor != nil and editor.controller == controller and not editor.closed:
      return editor
  nil

proc removeEditorRootState(state: ptr Vst3EditorState) =
  if state == nil:
    return
  for index in 0 ..< MaxVst3EditorRoots:
    if editorRoots[index] != nil and addr(editorRoots[index][]) == state:
      editorRoots[index] = nil
      break
proc editorError(kind: HostErrorKind; message: string; detail = ""): HostError =
  var context = ""
  if detail.len > 0:
    context = detail
  hostError(hsVst3, kind, message, context)

proc sameUid(left, right: ptr Vst3Tuid): bool {.inline, raises: [].} =
  if left == nil or right == nil:
    return false
  for index in 0 ..< Vst3TuidBytes:
    if left[][index] != right[][index]:
      return false
  true

proc editorOnMain(editor: ptr Vst3EditorState): bool {.inline, raises: [].} =
  editor != nil and pthread_equal(pthread_self(), editor.mainThread) != 0

proc validRect(rect: ptr Vst3ViewRect): bool {.inline, raises: [].} =
  if rect == nil:
    return false
  let width = int64(rect[].right) - int64(rect[].left)
  let height = int64(rect[].bottom) - int64(rect[].top)
  width > 0 and height > 0 and width <= MaxVst3EditorDimension and
    height <= MaxVst3EditorDimension

proc rectSize(rect: Vst3ViewRect): Vst3EditorSize {.inline, raises: [].} =
  Vst3EditorSize(
    width: uint32(int64(rect.right) - int64(rect.left)),
    height: uint32(int64(rect.bottom) - int64(rect.top)))

proc frameState(thisInterface: pointer): ptr Vst3EditorFrame {.
    inline, raises: [].} =
  if thisInterface == nil:
    nil
  else:
    cast[ptr Vst3EditorFrame](thisInterface)

proc frameQueryInterface(thisInterface: pointer; iid: ptr Vst3Tuid;
                         obj: ptr pointer): int32 {.cdecl, raises: [].} =
  let frame = frameState(thisInterface)
  if obj != nil:
    obj[] = nil
  if frame == nil or frame.owner == nil or not editorOnMain(frame.owner) or
      obj == nil:
    return Vst3NoInterface
  var fUnknown = parseVst3Uid(Vst3FUnknownIid)
  var plugFrame = parseVst3Uid(Vst3PlugFrameIid)
  if not fUnknown.isOk or not plugFrame.isOk:
    return Vst3NoInterface
  if not sameUid(iid, addr fUnknown.value) and
      not sameUid(iid, addr plugFrame.value):
    return Vst3NoInterface
  obj[] = addr frame.iface
  inc frame.owner.frameReferences
  Vst3ResultOk

proc frameAddRef(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let frame = frameState(thisInterface)
  if frame == nil or frame.owner == nil or not editorOnMain(frame.owner) or
      frame.owner.frameOwnerReleased:
    return 0'u32
  inc frame.owner.frameReferences
  frame.owner.frameReferences

proc finishClose(editor: ptr Vst3EditorState): Result[Unit] {.raises: [].}

proc frameRelease(thisInterface: pointer): uint32 {.cdecl, raises: [].} =
  let frame = frameState(thisInterface)
  if frame == nil or frame.owner == nil or not editorOnMain(frame.owner):
    return 0'u32
  # Keep a strong reference through callback return. finishClose may remove
  # the global root after the last plugin-held frame reference drains.
  let editor = findEditorRootState(frame.owner)
  if editor == nil:
    return 0'u32
  if editor.frameReferences > 0'u32:
    dec editor.frameReferences
  if editor.closePending and editor.frameReferences <= 1'u32:
    discard finishClose(addr editor[])
  editor.frameReferences

proc resizeViewCallback(thisInterface: pointer; view: ptr Vst3IPlugView;
                        newSize: ptr Vst3ViewRect): int32 {.
    cdecl, raises: [].} =
  let frame = frameState(thisInterface)
  if frame == nil or frame.owner == nil or not editorOnMain(frame.owner) or
      frame.owner.closed or frame.owner.frameOwnerReleased or
      view == nil or view != frame.owner.view or not validRect(newSize) or
      frame.owner.host.resize == nil:
    return Vst3ResultFalse

  var constrained = newSize[]
  let viewVtable = view.lpVtbl
  if viewVtable == nil or viewVtable.onSize == nil:
    return Vst3ResultFalse
  if viewVtable.checkSizeConstraint != nil:
    let checked = viewVtable.checkSizeConstraint(cast[pointer](view),
      addr constrained)
    if checked != Vst3ResultOk and checked != Vst3ResultFalse:
      return checked
    if not validRect(addr constrained):
      return Vst3ResultFalse

  let requested = constrained.rectSize()
  if not frame.owner.host.resize(frame.owner.host.context,
      requested.width, requested.height):
    return Vst3ResultFalse
  let acknowledged = viewVtable.onSize(cast[pointer](view), addr constrained)
  if acknowledged != Vst3ResultOk:
    return acknowledged
  frame.owner.size = constrained
  Vst3ResultOk

proc initFrame(editor: ptr Vst3EditorState) {.raises: [].} =
  editor.frame.owner = editor
  editor.frame.vtable = Vst3IPlugFrameVtbl(
    queryInterface: frameQueryInterface,
    addRef: frameAddRef,
    release: frameRelease,
    resizeView: resizeViewCallback)
  editor.frame.iface.lpVtbl = addr editor.frame.vtable
  editor.frameReferences = 1'u32

proc requireMain(editor: Vst3Editor; operation: string): Result[Unit] =
  if editor == nil:
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor is unavailable", "operation=" & operation))
  if not editorOnMain(addr editor[]):
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor operation requires the instance main thread",
      "operation=" & operation))
  if editor.closed:
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor is closed", "operation=" & operation))
  success()

proc releaseView(editor: ptr Vst3EditorState) {.raises: [].} =
  if editor != nil and editor.view != nil and not editor.viewReleased:
    if editor.view.lpVtbl != nil and editor.view.lpVtbl.release != nil:
      discard editor.view.lpVtbl.release(cast[pointer](editor.view))
    editor.viewReleased = true
    editor.view = nil

proc releaseFrameOwner(editor: ptr Vst3EditorState) {.raises: [].} =
  if editor == nil or editor.frameOwnerReleased:
    return
  if editor.frameReferences == 0'u32:
    editor.frameOwnerReleased = true
  elif editor.frameReferences == 1'u32:
    dec editor.frameReferences
    editor.frameOwnerReleased = true

proc finishClose(editor: ptr Vst3EditorState): Result[Unit] {.raises: [].} =
  if editor == nil:
    return success()
  if editor.frameReferences > 1'u32:
    editor.closePending = true
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor frame is still retained by the plugin",
      "references=" & $editor.frameReferences))
  releaseFrameOwner(editor)
  if editor.frameReferences != 0'u32:
    editor.closePending = true
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor frame owner could not be released"))
  editor.closed = true
  editor.closePending = false
  removeEditorRootState(editor)
  success()

proc close*(editor: Vst3Editor): Result[Unit] =
  if editor == nil:
    return success()
  if not editorOnMain(addr editor[]):
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor close requires the instance main thread"))
  if editor.closed:
    return success()

  if editor.view != nil and not editor.viewReleased:
    let vtable = editor.view.lpVtbl
    if vtable == nil:
      return failure[Unit](editorError(hekVst3Descriptor,
        "VST3 editor view has no vtable"))
    if vtable.release == nil:
      return failure[Unit](editorError(hekVst3Descriptor,
        "VST3 editor view has no release callback"))
    if editor.attached:
      if vtable.removed == nil:
        return failure[Unit](editorError(hekVst3Descriptor,
          "VST3 editor view has no removed callback"))
      let removed = vtable.removed(cast[pointer](editor.view))
      if removed != Vst3ResultOk:
        return failure[Unit](editorError(hekVst3Unavailable,
          "VST3 editor view rejected removal", "result=" & $removed))
      editor.attached = false
    if editor.frameInstalled:
      if vtable.setFrame == nil:
        return failure[Unit](editorError(hekVst3Descriptor,
          "VST3 editor view has no setFrame callback"))
      let detached = vtable.setFrame(cast[pointer](editor.view), nil)
      if detached != Vst3ResultOk:
        return failure[Unit](editorError(hekVst3Unavailable,
          "VST3 editor view rejected frame removal", "result=" & $detached))
      editor.frameInstalled = false
    releaseView(addr editor[])
  finishClose(addr editor[])

proc createVst3Editor*(controller: ptr Vst3EditController;
                       mainThread: Pthread; parentWindowId: uint64;
                       host: Vst3EditorHost): Result[Vst3Editor] =
  if controller == nil or controller.lpVtbl == nil or
      controller.lpVtbl.createView == nil:
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 controller has no editor view"))
  if pthread_equal(pthread_self(), mainThread) == 0:
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 editor creation requires the instance main thread"))
  if parentWindowId == 0'u64:
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 editor requires a non-zero X11 embedding window"))
  if host.resize == nil:
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 editor requires a host resize capability"))
  if not hasEditorRootCapacity():
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 editor owner root capacity is exhausted"))

  let rawView = controller.lpVtbl.createView(cast[pointer](controller),
    EditorName.cstring)
  if rawView == nil:
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 controller did not provide an editor view"))
  var editor: Vst3Editor
  new(editor)
  editor.controller = controller
  editor.view = cast[ptr Vst3IPlugView](rawView)
  editor.mainThread = mainThread
  editor.host = host
  editor.parentWindowId = parentWindowId
  initFrame(addr editor[])
  if not claimEditorRoot(editor):
    releaseView(addr editor[])
    releaseFrameOwner(addr editor[])
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 editor owner root capacity is exhausted"))

  let vtable = editor.view.lpVtbl
  if vtable == nil or vtable.release == nil or
      vtable.isPlatformTypeSupported == nil or vtable.getSize == nil or
      vtable.onSize == nil or vtable.setFrame == nil or
      vtable.attached == nil or vtable.removed == nil:
    discard close(editor)
    return failure[Vst3Editor](editorError(hekVst3Descriptor,
      "VST3 editor view has an incomplete ABI"))
  let supported = vtable.isPlatformTypeSupported(cast[pointer](editor.view),
    Vst3PlatformTypeX11EmbedWindowID.cstring)
  if supported != Vst3ResultOk:
    discard close(editor)
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 editor does not support X11 embedding",
      "result=" & $supported))
  var initial: Vst3ViewRect
  let sized = vtable.getSize(cast[pointer](editor.view), addr initial)
  if sized != Vst3ResultOk or not validRect(addr initial):
    discard close(editor)
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 editor reported an invalid initial size", "result=" & $sized))
  editor.size = initial
  let framed = vtable.setFrame(cast[pointer](editor.view),
    addr editor.frame.iface)
  if framed != Vst3ResultOk:
    if editor.frameReferences > 1'u32:
      editor.frameInstalled = true
    discard close(editor)
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 editor rejected its host frame", "result=" & $framed))
  editor.frameInstalled = true
  let parent = cast[pointer](cast[uint](parentWindowId))
  let attached = vtable.attached(cast[pointer](editor.view), parent,
    Vst3PlatformTypeX11EmbedWindowID.cstring)
  if attached != Vst3ResultOk:
    discard close(editor)
    return failure[Vst3Editor](editorError(hekVst3Unavailable,
      "VST3 editor rejected X11 attachment", "result=" & $attached))
  editor.attached = true
  success(editor)

proc attachVst3Editor*(editor: Vst3Editor; parentWindowId: uint64): Result[Unit] =
  var ready = requireMain(editor, "attach")
  if not ready.isOk:
    return ready
  if parentWindowId == 0'u64:
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor requires a non-zero X11 embedding window"))
  if editor.attached:
    return success()
  if editor.view == nil or editor.view.lpVtbl == nil:
    return failure[Unit](editorError(hekVst3Descriptor,
      "VST3 editor view is unavailable"))
  let vtable = editor.view.lpVtbl
  if vtable.isPlatformTypeSupported == nil or vtable.attached == nil or
      vtable.setFrame == nil:
    return failure[Unit](editorError(hekVst3Descriptor,
      "VST3 editor view has an incomplete ABI"))
  let supported = vtable.isPlatformTypeSupported(cast[pointer](editor.view),
    Vst3PlatformTypeX11EmbedWindowID.cstring)
  if supported != Vst3ResultOk:
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor does not support X11 embedding",
      "result=" & $supported))
  if not editor.frameInstalled:
    let framedAgain = vtable.setFrame(cast[pointer](editor.view),
      addr editor.frame.iface)
    if framedAgain != Vst3ResultOk:
      if editor.frameReferences > 1'u32:
        editor.frameInstalled = true
      return failure[Unit](editorError(hekVst3Unavailable,
        "VST3 editor rejected its host frame", "result=" & $framedAgain))
    editor.frameInstalled = true
  let parentAgain = cast[pointer](cast[uint](parentWindowId))
  let attachedAgain = vtable.attached(cast[pointer](editor.view),
    parentAgain, Vst3PlatformTypeX11EmbedWindowID.cstring)
  if attachedAgain != Vst3ResultOk:
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor rejected X11 attachment", "result=" & $attachedAgain))
  editor.parentWindowId = parentWindowId
  editor.attached = true
  success()

proc removeVst3Editor*(editor: Vst3Editor): Result[Unit] =
  var ready = requireMain(editor, "remove")
  if not ready.isOk:
    return ready
  if editor.view == nil or editor.viewReleased:
    return success()
  let vtable = editor.view.lpVtbl
  if vtable == nil:
    return failure[Unit](editorError(hekVst3Descriptor,
      "VST3 editor view has no vtable"))
  if editor.attached:
    if vtable.removed == nil:
      return failure[Unit](editorError(hekVst3Descriptor,
        "VST3 editor view has no removed callback"))
    let removed = vtable.removed(cast[pointer](editor.view))
    if removed != Vst3ResultOk:
      return failure[Unit](editorError(hekVst3Unavailable,
        "VST3 editor view rejected removal", "result=" & $removed))
    editor.attached = false
  if editor.frameInstalled:
    if vtable.setFrame == nil:
      return failure[Unit](editorError(hekVst3Descriptor,
        "VST3 editor view has no setFrame callback"))
    let detached = vtable.setFrame(cast[pointer](editor.view), nil)
    if detached != Vst3ResultOk:
      return failure[Unit](editorError(hekVst3Unavailable,
        "VST3 editor view rejected frame removal", "result=" & $detached))
    editor.frameInstalled = false
  success()

proc editorSize*(editor: Vst3Editor): Result[Vst3EditorSize] =
  var ready = requireMain(editor, "get_size")
  if not ready.isOk:
    return failure[Vst3EditorSize](move(ready.error))
  if editor.view == nil or editor.view.lpVtbl == nil or
      editor.view.lpVtbl.getSize == nil:
    return failure[Vst3EditorSize](editorError(hekVst3Descriptor,
      "VST3 editor view has no getSize callback"))
  var rect: Vst3ViewRect
  let code = editor.view.lpVtbl.getSize(cast[pointer](editor.view), addr rect)
  if code != Vst3ResultOk or not validRect(addr rect):
    return failure[Vst3EditorSize](editorError(hekVst3Unavailable,
      "VST3 editor reported an invalid size", "result=" & $code))
  editor.size = rect
  success(rectSize(rect))

proc editorCanResize*(editor: Vst3Editor): Result[bool] =
  var ready = requireMain(editor, "can_resize")
  if not ready.isOk:
    return failure[bool](move(ready.error))
  if editor.view == nil or editor.view.lpVtbl == nil or
      editor.view.lpVtbl.canResize == nil:
    return failure[bool](editorError(hekVst3Descriptor,
      "VST3 editor view has no canResize callback"))
  let code = editor.view.lpVtbl.canResize(cast[pointer](editor.view))
  if code == Vst3ResultOk:
    return success(true)
  if code == Vst3ResultFalse:
    return success(false)
  failure[bool](editorError(hekVst3Unavailable,
    "VST3 editor resize capability query failed", "result=" & $code))

proc editorCheckSizeConstraint*(editor: Vst3Editor;
                                rect: var Vst3ViewRect): Result[Unit] =
  var ready = requireMain(editor, "check_size_constraint")
  if not ready.isOk:
    return ready
  if not validRect(addr rect):
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor size is invalid"))
  if editor.view == nil or editor.view.lpVtbl == nil or
      editor.view.lpVtbl.checkSizeConstraint == nil:
    return success()
  let code = editor.view.lpVtbl.checkSizeConstraint(
    cast[pointer](editor.view), addr rect)
  if code != Vst3ResultOk and code != Vst3ResultFalse:
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor rejected its size constraint", "result=" & $code))
  if not validRect(addr rect):
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor produced an invalid constrained size"))
  success()

proc resizeVst3Editor*(editor: Vst3Editor; rect: Vst3ViewRect): Result[Unit] =
  var ready = requireMain(editor, "resize")
  if not ready.isOk:
    return ready
  var constrained = rect
  var checked = editorCheckSizeConstraint(editor, constrained)
  if not checked.isOk:
    return checked
  if editor.view == nil or editor.view.lpVtbl == nil or
      editor.view.lpVtbl.onSize == nil:
    return failure[Unit](editorError(hekVst3Descriptor,
      "VST3 editor view has no onSize callback"))
  let requested = constrained.rectSize()
  if not editor.host.resize(editor.host.context, requested.width, requested.height):
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor host rejected resize"))
  let acknowledged = editor.view.lpVtbl.onSize(cast[pointer](editor.view),
    addr constrained)
  if acknowledged != Vst3ResultOk:
    return failure[Unit](editorError(hekVst3Unavailable,
      "VST3 editor rejected onSize", "result=" & $acknowledged))
  editor.size = constrained
  success()

proc isAttached*(editor: Vst3Editor): bool {.inline.} =
  editor != nil and editor.attached and not editor.closed

proc isClosed*(editor: Vst3Editor): bool {.inline.} =
  editor == nil or editor.closed

proc frameReferenceCount*(editor: Vst3Editor): uint32 {.inline.} =
  if editor == nil: 0'u32 else: editor.frameReferences

proc viewPointer*(editor: Vst3Editor): ptr Vst3IPlugView {.inline.} =
  if editor == nil: nil else: editor.view

proc framePointer*(editor: Vst3Editor): ptr Vst3IPlugFrame {.inline.} =
  if editor == nil: nil else: addr editor.frame.iface

proc editorCurrentSize*(editor: Vst3Editor): Vst3EditorSize {.inline.} =
  if editor == nil: Vst3EditorSize() else: rectSize(editor.size)

proc editorRootCount*(): int =
  for editor in editorRoots:
    if editor != nil:
      inc result

proc getSize*(editor: Vst3Editor): Result[Vst3EditorSize] =
  editorSize(editor)

proc canResize*(editor: Vst3Editor): Result[bool] =
  editorCanResize(editor)

proc checkSizeConstraint*(editor: Vst3Editor;
                          rect: var Vst3ViewRect): Result[Unit] =
  editorCheckSizeConstraint(editor, rect)
