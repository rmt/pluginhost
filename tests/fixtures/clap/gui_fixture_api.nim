import std/os

import pluginhost/platform/linux/dynlib

type
  GuiFixtureResetProc* = proc() {.cdecl, gcsafe, raises: [].}
  GuiFixtureCounterProc* = proc(): uint32 {.cdecl, gcsafe, raises: [].}

  GuiFixtureApi* = object
    reset*: GuiFixtureResetProc
    createCalls*: GuiFixtureCounterProc
    destroyCalls*: GuiFixtureCounterProc
    setScaleCalls*: GuiFixtureCounterProc
    setSizeCalls*: GuiFixtureCounterProc
    setParentCalls*: GuiFixtureCounterProc
    setTransientCalls*: GuiFixtureCounterProc
    suggestTitleCalls*: GuiFixtureCounterProc
    showCalls*: GuiFixtureCounterProc
    hideCalls*: GuiFixtureCounterProc
    contractFailures*: GuiFixtureCounterProc

proc guiFixturePath*(directory: string): string =
  directory / "gui.clap"

proc guiFixtureApi*(library: DynamicLibrary): GuiFixtureApi =
  let reset = resolveSymbol[GuiFixtureResetProc](library,
    "pluginhost_gui_fixture_reset")
  let createCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_create")
  let destroyCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_destroy")
  let setScaleCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_set_scale")
  let setSizeCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_set_size")
  let setParentCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_set_parent")
  let setTransientCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_set_transient")
  let suggestTitleCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_suggest_title")
  let showCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_show")
  let hideCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_hide")
  let contractFailures = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_contract_failures")
  doAssert reset.isOk
  doAssert createCalls.isOk
  doAssert destroyCalls.isOk
  doAssert setScaleCalls.isOk
  doAssert setSizeCalls.isOk
  doAssert setParentCalls.isOk
  doAssert setTransientCalls.isOk
  doAssert suggestTitleCalls.isOk
  doAssert showCalls.isOk
  doAssert hideCalls.isOk
  doAssert contractFailures.isOk
  GuiFixtureApi(
    reset: reset.value,
    createCalls: createCalls.value,
    destroyCalls: destroyCalls.value,
    setScaleCalls: setScaleCalls.value,
    setSizeCalls: setSizeCalls.value,
    setParentCalls: setParentCalls.value,
    setTransientCalls: setTransientCalls.value,
    suggestTitleCalls: suggestTitleCalls.value,
    showCalls: showCalls.value,
    hideCalls: hideCalls.value,
    contractFailures: contractFailures.value)
