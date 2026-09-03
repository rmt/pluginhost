## Main-thread-only capability used by GuiController for CLAP GUI calls.
##
## The concrete CLAP adapter owns the raw plugin pointer and converts every
## operation to bounded internal values before it reaches controller policy.

import ../domain/[errors, result]
import ./window_host

type
  GuiPluginClient* = ref object of RootObj

proc pluginGuiError*(message: string): HostError =
  hostError(hsGui, hekGui, message)

method available*(client: GuiPluginClient): bool {.base, raises: [].} =
  discard client
  false

method isApiSupported*(client: GuiPluginClient; api: GuiWindowApi;
                       floating: bool): bool {.base, raises: [].} =
  discard client
  discard api
  discard floating
  false

method create*(client: GuiPluginClient; api: GuiWindowApi;
               floating: bool): Result[bool] {.base, raises: [].} =
  discard client
  discard api
  discard floating
  failure[bool](pluginGuiError("CLAP GUI client does not support creation"))

method destroy*(client: GuiPluginClient): Result[Unit] {.base, raises: [].} =
  discard client
  failure[Unit](pluginGuiError("CLAP GUI client does not support destruction"))

method setScale*(client: GuiPluginClient; scale: float64): Result[bool] {.
    base, raises: [].} =
  discard client
  discard scale
  failure[bool](pluginGuiError("CLAP GUI client does not support scaling"))

method getSize*(client: GuiPluginClient): Result[GuiSize] {.base, raises: [].} =
  discard client
  failure[GuiSize](pluginGuiError("CLAP GUI client does not report a size"))

method canResize*(client: GuiPluginClient): Result[bool] {.base, raises: [].} =
  discard client
  failure[bool](pluginGuiError("CLAP GUI client does not report resize support"))

method getResizeHints*(client: GuiPluginClient;
                       hints: var GuiResizeHints): Result[bool] {.
    base, raises: [].} =
  discard client
  discard hints
  failure[bool](pluginGuiError("CLAP GUI client does not report resize hints"))

method adjustSize*(client: GuiPluginClient; size: var GuiSize): Result[bool] {.
    base, raises: [].} =
  discard client
  discard size
  failure[bool](pluginGuiError("CLAP GUI client does not support size adjustment"))

method setSize*(client: GuiPluginClient; size: GuiSize): Result[bool] {.
    base, raises: [].} =
  discard client
  discard size
  failure[bool](pluginGuiError("CLAP GUI client does not support setting size"))

method setParent*(client: GuiPluginClient; handle: GuiWindowHandle): Result[bool] {.
    base, raises: [].} =
  discard client
  discard handle
  failure[bool](pluginGuiError("CLAP GUI client does not support parenting"))

method setTransient*(client: GuiPluginClient;
                     handle: GuiWindowHandle): Result[bool] {.base, raises: [].} =
  discard client
  discard handle
  failure[bool](pluginGuiError("CLAP GUI client does not support transient windows"))

method suggestTitle*(client: GuiPluginClient; title: string): Result[Unit] {.
    base, raises: [].} =
  discard client
  discard title
  failure[Unit](pluginGuiError("CLAP GUI client does not support window titles"))

method show*(client: GuiPluginClient): Result[bool] {.base, raises: [].} =
  discard client
  failure[bool](pluginGuiError("CLAP GUI client does not support showing"))

method hide*(client: GuiPluginClient): Result[bool] {.base, raises: [].} =
  discard client
  failure[bool](pluginGuiError("CLAP GUI client does not support hiding"))
