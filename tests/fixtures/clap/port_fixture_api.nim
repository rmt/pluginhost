import pluginhost/platform/linux/dynlib

type
  PortFixtureResetProc* = proc() {.cdecl, gcsafe, raises: [].}
  PortFixtureCounterProc* = proc(): uint32 {.cdecl, gcsafe, raises: [].}
  PortFixtureRenderModeProc* = proc(): int32 {.cdecl, gcsafe, raises: [].}

  PortFixtureApi* = object
    reset*: PortFixtureResetProc
    deinitCalls*: PortFixtureCounterProc
    destroyCalls*: PortFixtureCounterProc
    audioCountCalls*: PortFixtureCounterProc
    audioGetCalls*: PortFixtureCounterProc
    noteCountCalls*: PortFixtureCounterProc
    noteGetCalls*: PortFixtureCounterProc
    renderRequirementCalls*: PortFixtureCounterProc
    renderSetCalls*: PortFixtureCounterProc
    contractFailures*: PortFixtureCounterProc
    lastRenderMode*: PortFixtureRenderModeProc

proc resolveCounter(library: DynamicLibrary;
                    name: string): PortFixtureCounterProc =
  let resolved = resolveSymbol[PortFixtureCounterProc](library, name)
  doAssert resolved.isOk
  resolved.value

proc portFixtureApi*(library: DynamicLibrary): PortFixtureApi =
  let reset = resolveSymbol[PortFixtureResetProc](
    library, "pluginhost_port_fixture_reset")
  let lastRenderMode = resolveSymbol[PortFixtureRenderModeProc](
    library, "pluginhost_port_fixture_last_render_mode")
  doAssert reset.isOk
  doAssert lastRenderMode.isOk

  PortFixtureApi(
    reset: reset.value,
    deinitCalls: library.resolveCounter(
      "pluginhost_port_fixture_deinit_calls"),
    destroyCalls: library.resolveCounter(
      "pluginhost_port_fixture_destroy_calls"),
    audioCountCalls: library.resolveCounter(
      "pluginhost_port_fixture_audio_count_calls"),
    audioGetCalls: library.resolveCounter(
      "pluginhost_port_fixture_audio_get_calls"),
    noteCountCalls: library.resolveCounter(
      "pluginhost_port_fixture_note_count_calls"),
    noteGetCalls: library.resolveCounter(
      "pluginhost_port_fixture_note_get_calls"),
    renderRequirementCalls: library.resolveCounter(
      "pluginhost_port_fixture_render_requirement_calls"),
    renderSetCalls: library.resolveCounter(
      "pluginhost_port_fixture_render_set_calls"),
    contractFailures: library.resolveCounter(
      "pluginhost_port_fixture_contract_failures"),
    lastRenderMode: lastRenderMode.value,
  )
