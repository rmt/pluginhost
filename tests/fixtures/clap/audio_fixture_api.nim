import std/os

import pluginhost/platform/linux/dynlib

const
  AudioFixturePathEnvironment* = "PLUGINHOST_CLAP_AUDIO_FIXTURE_DIR"

type
  AudioFixtureVoidProc* = proc() {.cdecl, gcsafe, raises: [].}
  AudioFixtureCounterProc* = proc(): uint32 {.cdecl, gcsafe, raises: [].}
  AudioFixtureStatusProc* = proc(): int32 {.cdecl, gcsafe, raises: [].}
  AudioFixtureTimeProc* = proc(): int64 {.cdecl, gcsafe, raises: [].}
  AudioFixtureRateProc* = proc(): cdouble {.cdecl, gcsafe, raises: [].}
  AudioFixtureAddressProc* = proc(index: cint): uint64 {.
    cdecl, gcsafe, raises: [].}
  AudioFixtureLifecycleProc* = proc(index: cint): cint {.
    cdecl, gcsafe, raises: [].}

  AudioFixtureApi* = object
    reset*: AudioFixtureVoidProc
    activateCalls*: AudioFixtureCounterProc
    deactivateCalls*: AudioFixtureCounterProc
    startCalls*: AudioFixtureCounterProc
    stopCalls*: AudioFixtureCounterProc
    processCalls*: AudioFixtureCounterProc
    destroyCalls*: AudioFixtureCounterProc
    contractFailures*: AudioFixtureCounterProc
    onMainThreadCalls*: AudioFixtureCounterProc
    timerCalls*: AudioFixtureCounterProc
    fdCalls*: AudioFixtureCounterProc
    signalFd*: AudioFixtureStatusProc
    lastActivateSampleRate*: AudioFixtureRateProc
    lastActivateMinFrames*: AudioFixtureCounterProc
    lastActivateMaxFrames*: AudioFixtureCounterProc
    lastStatus*: AudioFixtureStatusProc
    lastSteadyTime*: AudioFixtureTimeProc
    lastFrames*: AudioFixtureCounterProc
    lastInputGroups*: AudioFixtureCounterProc
    lastOutputGroups*: AudioFixtureCounterProc
    transportWasNull*: AudioFixtureCounterProc
    data64WasNull*: AudioFixtureCounterProc
    inputAddress*: AudioFixtureAddressProc
    outputAddress*: AudioFixtureAddressProc
    lifecycleCount*: AudioFixtureCounterProc
    lifecycleAt*: AudioFixtureLifecycleProc

proc resolve*[T](library: DynamicLibrary; name: string): T =
  let value = resolveSymbol[T](library, name)
  doAssert value.isOk, "missing audio fixture symbol: " & name
  value.value

proc audioFixturePath*(variant: string): string =
  let directory = getEnv(AudioFixturePathEnvironment)
  doAssert directory.len > 0,
    AudioFixturePathEnvironment & " must identify the compiled fixture directory"
  directory / (variant & ".clap")

proc audioFixtureApi*(library: DynamicLibrary): AudioFixtureApi =
  result.reset = resolve[AudioFixtureVoidProc](library,
    "pluginhost_audio_fixture_reset")
  result.activateCalls = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_activate_calls")
  result.deactivateCalls = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_deactivate_calls")
  result.startCalls = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_start_calls")
  result.stopCalls = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_stop_calls")
  result.processCalls = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_process_calls")
  result.destroyCalls = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_destroy_calls")
  result.contractFailures = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_contract_failures")
  result.onMainThreadCalls = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_on_main_thread_calls")
  result.timerCalls = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_timer_calls")
  result.fdCalls = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_fd_calls")
  result.signalFd = resolve[AudioFixtureStatusProc](library,
    "pluginhost_audio_fixture_signal_fd")
  result.lastActivateSampleRate = resolve[AudioFixtureRateProc](library,
    "pluginhost_audio_fixture_last_activate_sample_rate")
  result.lastActivateMinFrames = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_last_activate_min_frames")
  result.lastActivateMaxFrames = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_last_activate_max_frames")
  result.lastStatus = resolve[AudioFixtureStatusProc](library,
    "pluginhost_audio_fixture_last_status")
  result.lastSteadyTime = resolve[AudioFixtureTimeProc](library,
    "pluginhost_audio_fixture_last_steady_time")
  result.lastFrames = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_last_frames")
  result.lastInputGroups = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_last_input_groups")
  result.lastOutputGroups = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_last_output_groups")
  result.transportWasNull = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_transport_was_null")
  result.data64WasNull = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_data64_was_null")
  result.inputAddress = resolve[AudioFixtureAddressProc](library,
    "pluginhost_audio_fixture_input_address")
  result.outputAddress = resolve[AudioFixtureAddressProc](library,
    "pluginhost_audio_fixture_output_address")
  result.lifecycleCount = resolve[AudioFixtureCounterProc](library,
    "pluginhost_audio_fixture_lifecycle_count")
  result.lifecycleAt = resolve[AudioFixtureLifecycleProc](library,
    "pluginhost_audio_fixture_lifecycle_at")
