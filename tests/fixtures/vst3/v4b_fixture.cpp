#include <cstdint>

/*
 * V4B reuses the independently compiled V3 processor and only replaces the
 * latency entry point plus native control exports.  The exported controls are
 * test-only; production code never depends on this fixture ABI.
 */
static std::uint32_t g_v4b_latency = 0;
static std::uint32_t g_v4b_restart_calls = 0;
static bool g_v4b_structural = false;
static bool g_v4b_generate = false;
static bool g_v4b_metadata_fail = false;

extern "C" bool pluginhost_vst3_v4b_structural_enabled() {
  return g_v4b_structural;
}
extern "C" bool pluginhost_vst3_v4b_generate_enabled() {
  return g_v4b_generate;
}
extern "C" bool pluginhost_vst3_v4b_metadata_fail_enabled() {
  return g_v4b_metadata_fail;
}

std::uint32_t pluginhost_vst3_v4b_latency_value() { return g_v4b_latency; }

#define PLUGINHOST_VST3_V4B_FIXTURE 1
#define PLUGINHOST_VST3_V3_MODE 0
#include "v3_fixture.cpp"
#undef PLUGINHOST_VST3_V3_MODE
#undef PLUGINHOST_VST3_V4B_FIXTURE

/*
 * The native controls are intentionally outside the fixture's anonymous
 * namespace so Nim can exercise the component handler ABI and observe
 * lifecycle-triggered changes.
 */

extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b_set_latency(std::uint32_t samples) {
  g_v4b_latency = samples;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b_set_structural(std::int32_t enabled) {
  g_v4b_structural = enabled != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b_set_generate(std::int32_t enabled) {
  g_v4b_generate = enabled != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b_set_metadata_fail(std::int32_t enabled) {
  g_v4b_metadata_fail = enabled != 0;
}

extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b_latency() { return g_v4b_latency; }

extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b_trigger_restart(std::int32_t flags) {
  if (g_state.handler == nullptr ||
      g_state.handler->lpVtbl == nullptr ||
      g_state.handler->lpVtbl->restartComponent == nullptr)
    return 0;
  ++g_v4b_restart_calls;
  return static_cast<std::uint32_t>(
      g_state.handler->lpVtbl->restartComponent(g_state.handler, flags));
}

extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b_restart_calls() {
  return g_v4b_restart_calls;
}
