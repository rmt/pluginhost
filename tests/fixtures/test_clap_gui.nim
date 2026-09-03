import std/unittest

import pluginhost/clap/[ffi, host_bridge, instance]
import pluginhost/clap/loader
import pluginhost/domain/[plugin_catalog, result]
import pluginhost/platform/linux/dynlib
import pluginhost/gui/window_host
import ./clap/[fixture_api, gui_fixture_api]

proc openGuiInstance(path: string; enabled: bool):
    tuple[instance: ClapInstance, api: GuiFixtureApi, observer: DynamicLibrary] =
  var observerResult = openDynamicLibrary(path)
  require observerResult.isOk
  var observer = move(observerResult.value)
  let api = guiFixtureApi(observer)
  api.reset()

  var moduleResult = openClapModule(path)
  require moduleResult.isOk
  var module = move(moduleResult.value)
  var catalog = module.readCatalog()
  require catalog.isOk
  var selected = catalog.value.selectDescriptor(PluginSelector(
    kind: pskId, pluginId: "org.pluginhost.fixture.gui"))
  require selected.isOk
  var created = createClapInstance(move(module), move(selected.value), nil, enabled)
  require created.isOk
  (move(created.value), api, move(observer))

suite "CLAP GUI boundary":
  test "the checked instance adapter calls every GUI operation on the main thread":
    let path = guiFixturePath(clapFixtureDirectory())
    var opened = openGuiInstance(path, true)
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let api = opened.api
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk

    check instance.guiAvailable
    let host = instance.hostBridge.hostPointer
    check host.getExtension(host, ClapExtGui.cstring) != nil
    var supported = instance.guiIsApiSupported(ClapWindowApiX11, false)
    check supported.isOk and supported.value
    var created = instance.guiCreate(ClapWindowApiX11, false)
    check created.isOk and created.value
    var scaled = instance.guiSetScale(1.5)
    check scaled.isOk and scaled.value
    var size = instance.guiGetSize()
    check size.isOk
    check size.value == GuiSize(width: 320, height: 240)
    var canResize = instance.guiCanResize()
    check canResize.isOk and canResize.value
    var hints: GuiResizeHints
    var gotHints = instance.guiGetResizeHints(hints)
    check gotHints.isOk and gotHints.value
    check hints.canResizeHorizontally
    var adjustedSize = GuiSize(width: 4000, height: 2000)
    var adjusted = instance.guiAdjustSize(adjustedSize)
    check adjusted.isOk and adjusted.value
    check adjustedSize == GuiSize(width: 1920, height: 1080)
    var setSize = instance.guiSetSize(adjustedSize)
    check setSize.isOk and setSize.value
    var parent = instance.guiSetParent(GuiWindowHandle(api: gwaX11, id: 11))
    check parent.isOk and parent.value
    var transient = instance.guiSetTransient(GuiWindowHandle(api: gwaX11, id: 12))
    check transient.isOk and transient.value
    check instance.guiSuggestTitle("Fixture GUI").isOk
    var shown = instance.guiShow()
    check shown.isOk and shown.value
    var hidden = instance.guiHide()
    check hidden.isOk and hidden.value
    check instance.guiDestroy().isOk

    check api.createCalls() == 1
    check api.destroyCalls() == 1
    check api.setScaleCalls() == 1
    check api.setSizeCalls() == 1
    check api.setParentCalls() == 1
    check api.setTransientCalls() == 1
    check api.suggestTitleCalls() == 1
    check api.showCalls() == 1
    check api.hideCalls() == 1
    check api.contractFailures() == 0

  test "headless policy does not advertise the GUI host extension":
    let path = guiFixturePath(clapFixtureDirectory())
    var opened = openGuiInstance(path, false)
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk

    let host = instance.hostBridge.hostPointer
    check instance.guiAvailable
    check host.getExtension(host, ClapExtGui.cstring) == nil
