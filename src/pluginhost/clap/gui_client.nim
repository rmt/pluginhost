## Adapter from ClapInstance's main-thread GUI calls to GuiPluginClient.
##
## The instance pointer is borrowed. The owning audio slice must outlive this
## client, and the controller must be closed before that slice is closed.

import ../domain/result
import ../gui/[plugin_client, window_host]
import ./[ffi, instance]

type
  ClapGuiClient* = ref object of GuiPluginClient
    instance: ptr ClapInstance

proc newClapGuiClient*(instance: ptr ClapInstance): GuiPluginClient =
  var client: ClapGuiClient
  new(client)
  client.instance = instance
  client

proc apiName(api: GuiWindowApi): string =
  case api
  of gwaX11:
    ClapWindowApiX11

method available*(client: ClapGuiClient): bool {.raises: [].} =
  client.instance != nil and client.instance[].guiAvailable

method isApiSupported*(client: ClapGuiClient; api: GuiWindowApi;
                       floating: bool): bool {.raises: [].} =
  if client.instance == nil:
    return false
  let supported = client.instance[].guiIsApiSupported(api.apiName, floating)
  supported.isOk and supported.value

method create*(client: ClapGuiClient; api: GuiWindowApi;
               floating: bool): Result[bool] {.raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiCreate(api.apiName, floating)

method destroy*(client: ClapGuiClient): Result[Unit] {.raises: [].} =
  if client.instance == nil:
    return failure[Unit](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiDestroy()

method setScale*(client: ClapGuiClient; scale: float64): Result[bool] {.
    raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiSetScale(scale)

method getSize*(client: ClapGuiClient): Result[GuiSize] {.raises: [].} =
  if client.instance == nil:
    return failure[GuiSize](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiGetSize()

method canResize*(client: ClapGuiClient): Result[bool] {.raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiCanResize()

method getResizeHints*(client: ClapGuiClient;
                       hints: var GuiResizeHints): Result[bool] {.
    raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiGetResizeHints(hints)

method adjustSize*(client: ClapGuiClient; size: var GuiSize): Result[bool] {.
    raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiAdjustSize(size)

method setSize*(client: ClapGuiClient; size: GuiSize): Result[bool] {.
    raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiSetSize(size)

method setParent*(client: ClapGuiClient; handle: GuiWindowHandle): Result[bool] {.
    raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiSetParent(handle)

method setTransient*(client: ClapGuiClient;
                     handle: GuiWindowHandle): Result[bool] {.raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiSetTransient(handle)

method suggestTitle*(client: ClapGuiClient; title: string): Result[Unit] {.
    raises: [].} =
  if client.instance == nil:
    return failure[Unit](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiSuggestTitle(title)

method show*(client: ClapGuiClient): Result[bool] {.raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiShow()

method hide*(client: ClapGuiClient): Result[bool] {.raises: [].} =
  if client.instance == nil:
    return failure[bool](pluginGuiError("CLAP GUI client has no instance"))
  client.instance[].guiHide()
