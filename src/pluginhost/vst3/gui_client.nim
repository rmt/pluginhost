## VST3 adapter for the backend-neutral GuiController seam.
##
## The instance and its controller are borrowed. GuiController must be closed
## before the instance is terminated; while a view is open, the editor owns the
## borrowed host-window resize capability synchronously.

import ../domain/[errors, result]
import ../gui/[plugin_client, window_host]
import ./[editor, ffi, instance]

type
  Vst3GuiClient* = ref object of GuiPluginClient
    instance: Vst3Instance
    editor: Vst3Editor
    parent: GuiWindowHandle

proc newVst3GuiClient*(instance: Vst3Instance): GuiPluginClient =
  var client: Vst3GuiClient
  new(client)
  client.instance = instance
  client
proc clientError(message: string; detail = ""): HostError =
  hostError(hsVst3, hekVst3Unavailable, message, detail)

proc asClient(client: Vst3GuiClient): Result[Unit] =
  if client == nil or not client.instance.isOpen:
    return failure[Unit](clientError("VST3 GUI client has no open instance"))
  success()

proc currentEditor(client: Vst3GuiClient): Vst3Editor =
  if client == nil or client.instance == nil:
    return nil
  if client.editor != nil and not client.editor.isClosed:
    return client.editor
  let owner = client.instance.editorOwner()
  if owner != nil and not owner.isClosed:
    owner
  else:
    nil

method available*(client: Vst3GuiClient): bool {.raises: [].} =
  client != nil and client.instance.isOpen and
    client.instance.controllerPointer() != nil

method hasRetainedResources*(client: Vst3GuiClient): bool {.raises: [].} =
  if client == nil or client.instance == nil:
    return false
  let owner = client.instance.editorOwner()
  owner != nil and not owner.isClosed

method isApiSupported*(client: Vst3GuiClient; api: GuiWindowApi;
                       floating: bool): bool {.raises: [].} =
  client.available and api == gwaX11 and not floating

method create*(client: Vst3GuiClient; api: GuiWindowApi;
               floating: bool; host: GuiWindowHost): Result[bool] {.
    raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[bool](move(ready.error))
  if api != gwaX11 or floating:
    return failure[bool](clientError(
      "VST3 GUI supports embedded X11 only"))
  if host.handle.api != gwaX11 or host.handle.id == 0'u64 or
      host.resize == nil:
    return failure[bool](clientError(
      "VST3 GUI requires an open X11 parent and synchronous resize capability"))
  if client.currentEditor() != nil:
    return failure[bool](clientError("VST3 GUI editor is already created"))
  var created = client.instance.createEditor(host.handle.id, Vst3EditorHost(
    context: host.resizeContext, resize: host.resize))
  if not created.isOk:
    # A plugin may retain the stable frame during a failed callback. Keep the
    # borrowed editor visible to the owner so close remains retryable.
    client.editor = client.instance.editorOwner()
    return failure[bool](move(created.error))
  client.editor = created.value
  client.parent = host.handle
  success(true)

method destroy*(client: Vst3GuiClient): Result[Unit] {.raises: [].} =
  if client == nil:
    return success()
  if client.editor == nil and client.instance != nil and
      client.instance.editorOwner() == nil:
    return success()
  if client.instance == nil:
    return failure[Unit](clientError("VST3 GUI client has no instance"))
  let closed = client.instance.closeEditor()
  if not closed.isOk:
    return closed
  client.editor = nil
  client.parent = GuiWindowHandle()
  success()

method setScale*(client: Vst3GuiClient; scale: float64): Result[bool] {.
    raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[bool](move(ready.error))
  let current = client.currentEditor()
  if current == nil:
    return failure[bool](clientError("VST3 GUI editor has not been created"))
  current.setContentScale(scale)

method getSize*(client: Vst3GuiClient): Result[GuiSize] {.raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[GuiSize](move(ready.error))
  let current = client.currentEditor()
  if current == nil:
    return failure[GuiSize](clientError("VST3 GUI editor has not been created"))
  var size = editorSize(current)
  if not size.isOk:
    return failure[GuiSize](move(size.error))
  success(GuiSize(width: size.value.width, height: size.value.height))

method canResize*(client: Vst3GuiClient): Result[bool] {.raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[bool](move(ready.error))
  let current = client.currentEditor()
  if current == nil:
    return failure[bool](clientError("VST3 GUI editor has not been created"))
  editorCanResize(current)

method getResizeHints*(client: Vst3GuiClient;
                       hints: var GuiResizeHints): Result[bool] {.
    raises: [].} =
  var resizeable = client.canResize()
  if not resizeable.isOk:
    return failure[bool](move(resizeable.error))
  if not resizeable.value:
    return success(false)
  hints = GuiResizeHints(canResizeHorizontally: true,
    canResizeVertically: true)
  success(true)

method adjustSize*(client: Vst3GuiClient; size: var GuiSize): Result[bool] {.
    raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[bool](move(ready.error))
  let current = client.currentEditor()
  if current == nil:
    return failure[bool](clientError("VST3 GUI editor has not been created"))
  if size.width == 0'u32 or size.height == 0'u32 or
      size.width > uint32(high(int32)) or size.height > uint32(high(int32)):
    return failure[bool](clientError("VST3 GUI size is invalid"))
  var rect = Vst3ViewRect(left: 0, top: 0,
    right: int32(size.width), bottom: int32(size.height))
  var constrained = editorCheckSizeConstraint(current, rect)
  if not constrained.isOk:
    return failure[bool](move(constrained.error))
  let adjusted = GuiSize(width: uint32(rect.right - rect.left),
    height: uint32(rect.bottom - rect.top))
  let changed = adjusted != size
  size = adjusted
  success(changed)

method setSize*(client: Vst3GuiClient; size: GuiSize): Result[bool] {.
    raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[bool](move(ready.error))
  let current = client.currentEditor()
  if current == nil:
    return failure[bool](clientError("VST3 GUI editor has not been created"))
  if size.width == 0'u32 or size.height == 0'u32 or
      size.width > uint32(high(int32)) or size.height > uint32(high(int32)):
    return failure[bool](clientError("VST3 GUI size is invalid"))
  var resized = resizeVst3Editor(current, Vst3ViewRect(left: 0,
    right: int32(size.width), bottom: int32(size.height)))
  if not resized.isOk:
    return failure[bool](move(resized.error))
  success(true)

method setParent*(client: Vst3GuiClient; handle: GuiWindowHandle): Result[bool] {.
    raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[bool](move(ready.error))
  if handle.api != gwaX11 or handle.id == 0'u64:
    return success(false)
  # IPlugView::attached is authoritative; this is the controller's parent
  # acknowledgement and never re-attaches an already live view.
  success(client.parent.api == handle.api and client.parent.id == handle.id)

method setTransient*(client: Vst3GuiClient;
                     handle: GuiWindowHandle): Result[bool] {.raises: [].} =
  discard client
  discard handle
  success(false)

method suggestTitle*(client: Vst3GuiClient; title: string): Result[Unit] {.
    raises: [].} =
  discard client
  discard title
  success()

method show*(client: Vst3GuiClient): Result[bool] {.raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[bool](move(ready.error))
  # The shared controller owns the X11 parent's map operation.  VST3 has no
  # separate show request for an embedded view.
  success(true)

method hide*(client: Vst3GuiClient): Result[bool] {.raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[bool](move(ready.error))
  # The shared controller owns the X11 parent's unmap operation.
  success(true)

method focus*(client: Vst3GuiClient; focused: bool): Result[bool] {.
    raises: [].} =
  var ready = client.asClient()
  if not ready.isOk:
    return failure[bool](move(ready.error))
  let current = client.currentEditor()
  if current == nil:
    return failure[bool](clientError("VST3 GUI editor has not been created"))
  current.focus(focused)
