import std/os

import pluginhost/platform/linux/dynlib

const
  GuiServiceFailureNone* = 0'u32
  GuiServiceFailureAfterTimer* = 1'u32
  GuiServiceFailureAfterPipe* = 2'u32
  GuiServiceFailureFdRegistration* = 3'u32
  GuiServiceFailureAfterFd* = 4'u32

type
  GuiFixtureResetProc* = proc() {.cdecl, gcsafe, raises: [].}
  GuiFixtureCounterProc* = proc(): uint32 {.cdecl, gcsafe, raises: [].}
  GuiFixtureSetU32Proc* = proc(value: uint32) {.cdecl, gcsafe, raises: [].}

  GuiFixtureApi* = object
    reset*: GuiFixtureResetProc
    enableServices*: GuiFixtureSetU32Proc
    setServiceFailureStep*: GuiFixtureSetU32Proc
    createCalls*: GuiFixtureCounterProc
    destroyCalls*: GuiFixtureCounterProc
    setScaleCalls*: GuiFixtureCounterProc
    setSizeCalls*: GuiFixtureCounterProc
    setParentCalls*: GuiFixtureCounterProc
    setTransientCalls*: GuiFixtureCounterProc
    suggestTitleCalls*: GuiFixtureCounterProc
    showCalls*: GuiFixtureCounterProc
    hideCalls*: GuiFixtureCounterProc
    timerCalls*: GuiFixtureCounterProc
    fdCalls*: GuiFixtureCounterProc
    timerRegisterCalls*: GuiFixtureCounterProc
    timerUnregisterCalls*: GuiFixtureCounterProc
    fdRegisterCalls*: GuiFixtureCounterProc
    fdUnregisterCalls*: GuiFixtureCounterProc
    pipeCreateCalls*: GuiFixtureCounterProc
    pipeCloseCalls*: GuiFixtureCounterProc
    serviceSetupFailures*: GuiFixtureCounterProc
    serviceCleanupFailures*: GuiFixtureCounterProc
    mainThreadFailures*: GuiFixtureCounterProc
    contractFailures*: GuiFixtureCounterProc

proc guiFixturePath*(directory: string): string =
  directory / "gui.clap"

proc guiFixtureApi*(library: DynamicLibrary): GuiFixtureApi =
  let reset = resolveSymbol[GuiFixtureResetProc](library,
    "pluginhost_gui_fixture_reset")
  let enableServices = resolveSymbol[GuiFixtureSetU32Proc](library,
    "pluginhost_gui_fixture_enable_services")
  let setServiceFailureStep = resolveSymbol[GuiFixtureSetU32Proc](library,
    "pluginhost_gui_fixture_set_service_failure_step")
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
  let timerCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_timer_callback")
  let fdCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_fd_callback")
  let timerRegisterCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_timer_register")
  let timerUnregisterCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_timer_unregister")
  let fdRegisterCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_fd_register")
  let fdUnregisterCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_fd_unregister")
  let pipeCreateCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_pipe_create")
  let pipeCloseCalls = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_pipe_close")
  let serviceSetupFailures = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_service_setup_failure")
  let serviceCleanupFailures = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_service_cleanup_failure")
  let mainThreadFailures = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_main_thread_failure")
  let contractFailures = resolveSymbol[GuiFixtureCounterProc](library,
    "pluginhost_gui_fixture_contract_failures")
  doAssert reset.isOk
  doAssert enableServices.isOk
  doAssert setServiceFailureStep.isOk
  doAssert createCalls.isOk
  doAssert destroyCalls.isOk
  doAssert setScaleCalls.isOk
  doAssert setSizeCalls.isOk
  doAssert setParentCalls.isOk
  doAssert setTransientCalls.isOk
  doAssert suggestTitleCalls.isOk
  doAssert showCalls.isOk
  doAssert hideCalls.isOk
  doAssert timerCalls.isOk
  doAssert fdCalls.isOk
  doAssert timerRegisterCalls.isOk
  doAssert timerUnregisterCalls.isOk
  doAssert fdRegisterCalls.isOk
  doAssert fdUnregisterCalls.isOk
  doAssert pipeCreateCalls.isOk
  doAssert pipeCloseCalls.isOk
  doAssert serviceSetupFailures.isOk
  doAssert serviceCleanupFailures.isOk
  doAssert mainThreadFailures.isOk
  doAssert contractFailures.isOk
  GuiFixtureApi(
    reset: reset.value,
    enableServices: enableServices.value,
    setServiceFailureStep: setServiceFailureStep.value,
    createCalls: createCalls.value,
    destroyCalls: destroyCalls.value,
    setScaleCalls: setScaleCalls.value,
    setSizeCalls: setSizeCalls.value,
    setParentCalls: setParentCalls.value,
    setTransientCalls: setTransientCalls.value,
    suggestTitleCalls: suggestTitleCalls.value,
    showCalls: showCalls.value,
    hideCalls: hideCalls.value,
    timerCalls: timerCalls.value,
    fdCalls: fdCalls.value,
    timerRegisterCalls: timerRegisterCalls.value,
    timerUnregisterCalls: timerUnregisterCalls.value,
    fdRegisterCalls: fdRegisterCalls.value,
    fdUnregisterCalls: fdUnregisterCalls.value,
    pipeCreateCalls: pipeCreateCalls.value,
    pipeCloseCalls: pipeCloseCalls.value,
    serviceSetupFailures: serviceSetupFailures.value,
    serviceCleanupFailures: serviceCleanupFailures.value,
    mainThreadFailures: mainThreadFailures.value,
    contractFailures: contractFailures.value)
