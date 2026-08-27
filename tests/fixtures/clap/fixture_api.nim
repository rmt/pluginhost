import std/os

import pluginhost/platform/linux/dynlib

type
  FixtureResetProc* = proc() {.cdecl, gcsafe, raises: [].}
  FixtureCounterProc* = proc(): uint32 {.cdecl, gcsafe, raises: [].}
  FixtureLastPathProc* = proc(): cstring {.cdecl, gcsafe, raises: [].}

  FixtureApi* = object
    reset*: FixtureResetProc
    initCalls*: FixtureCounterProc
    successfulInits*: FixtureCounterProc
    deinitCalls*: FixtureCounterProc
    createCalls*: FixtureCounterProc
    pluginInitCalls*: FixtureCounterProc
    pluginDestroyCalls*: FixtureCounterProc
    pluginMainThreadCalls*: FixtureCounterProc
    hostContractFailures*: FixtureCounterProc
    lastInitPath*: FixtureLastPathProc

proc clapFixtureDirectory*(): string =
  result = getEnv("PLUGINHOST_CLAP_FIXTURE_DIR")
  doAssert result.len > 0,
    "PLUGINHOST_CLAP_FIXTURE_DIR must identify the compiled fixture directory"

proc clapFixturePath*(variant: string): string =
  clapFixtureDirectory() / (variant & ".clap")

proc fixtureApi*(library: DynamicLibrary): FixtureApi =
  let reset = resolveSymbol[FixtureResetProc](library,
    "pluginhost_clap_fixture_reset")
  let initCalls = resolveSymbol[FixtureCounterProc](library,
    "pluginhost_clap_fixture_init_calls")
  let successfulInits = resolveSymbol[FixtureCounterProc](library,
    "pluginhost_clap_fixture_successful_inits")
  let deinitCalls = resolveSymbol[FixtureCounterProc](library,
    "pluginhost_clap_fixture_deinit_calls")
  let createCalls = resolveSymbol[FixtureCounterProc](library,
    "pluginhost_clap_fixture_create_calls")
  let pluginInitCalls = resolveSymbol[FixtureCounterProc](library,
    "pluginhost_clap_fixture_plugin_init_calls")
  let pluginDestroyCalls = resolveSymbol[FixtureCounterProc](library,
    "pluginhost_clap_fixture_plugin_destroy_calls")
  let pluginMainThreadCalls = resolveSymbol[FixtureCounterProc](library,
    "pluginhost_clap_fixture_plugin_main_thread_calls")
  let hostContractFailures = resolveSymbol[FixtureCounterProc](library,
    "pluginhost_clap_fixture_host_contract_failures")
  let lastInitPath = resolveSymbol[FixtureLastPathProc](library,
    "pluginhost_clap_fixture_last_init_path")

  doAssert reset.isOk
  doAssert initCalls.isOk
  doAssert successfulInits.isOk
  doAssert deinitCalls.isOk
  doAssert createCalls.isOk
  doAssert pluginInitCalls.isOk
  doAssert pluginDestroyCalls.isOk
  doAssert pluginMainThreadCalls.isOk
  doAssert hostContractFailures.isOk
  doAssert lastInitPath.isOk

  FixtureApi(
    reset: reset.value,
    initCalls: initCalls.value,
    successfulInits: successfulInits.value,
    deinitCalls: deinitCalls.value,
    createCalls: createCalls.value,
    pluginInitCalls: pluginInitCalls.value,
    pluginDestroyCalls: pluginDestroyCalls.value,
    pluginMainThreadCalls: pluginMainThreadCalls.value,
    hostContractFailures: hostContractFailures.value,
    lastInitPath: lastInitPath.value,
  )
