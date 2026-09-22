#include <cstdint>
#include "vst3/vst3_c_api.h"
/*
 * V4B2 is an independent native reload fixture.  The V3 processor remains
 * the ABI implementation; these controls only make lifecycle, state, and
 * failure edges deterministic for the private reload tests.
 */
static bool g_structural = false;
static bool g_capture_fail = false;
static bool g_component_capture_fail = false;
static bool g_controller_capture_fail = false;
static bool g_component_restore_fail = false;
static bool g_controller_restore_fail = false;
static bool g_retain_stream = false;
static bool g_setup_fail = false;
static bool g_activation_fail = false;
static bool g_module_entry_fail = false;
static bool g_component_initialize_fail = false;
static bool g_state_not_implemented = false;
static std::uint32_t g_module_entries = 0;
static std::uint32_t g_module_exits = 0;
static std::uint32_t g_module_event = 0;
static bool g_module_order_bad = false;
static std::uint32_t g_component_creates = 0;
static std::uint32_t g_component_initializes = 0;
static std::uint32_t g_component_terminates = 0;
static std::uint32_t g_max_live_components = 0;
static std::uint32_t g_live_components = 0;
static Steinberg_IBStream* g_retained_stream = nullptr;

extern "C" bool pluginhost_vst3_v4b_structural_enabled() {
  return g_structural;
}
extern "C" bool pluginhost_vst3_v4b2_capture_fail_enabled() {
  return g_capture_fail || g_component_capture_fail;
}
extern "C" bool pluginhost_vst3_v4b2_component_capture_fail_enabled() {
  return g_capture_fail || g_component_capture_fail;
}
extern "C" bool pluginhost_vst3_v4b2_controller_capture_fail_enabled() {
  return g_capture_fail || g_controller_capture_fail;
}
extern "C" bool pluginhost_vst3_v4b2_component_restore_fail_enabled() {
  return g_component_restore_fail;
}
extern "C" bool pluginhost_vst3_v4b2_controller_restore_fail_enabled() {
  return g_controller_restore_fail;
}
extern "C" bool pluginhost_vst3_v4b2_retain_stream_enabled() {
  return g_retain_stream;
}
extern "C" bool pluginhost_vst3_v4b2_setup_fail_enabled() {
  return g_setup_fail;
}
extern "C" bool pluginhost_vst3_v4b2_activation_fail_enabled() {
  return g_activation_fail;
}
extern "C" bool pluginhost_vst3_v4b2_module_entry_fail_enabled() {
  return g_module_entry_fail;
}
extern "C" bool pluginhost_vst3_v4b2_component_initialize_fail_enabled() {
  return g_component_initialize_fail;
}
extern "C" bool pluginhost_vst3_v4b2_state_not_implemented() {
  return g_state_not_implemented;
}
extern "C" void pluginhost_vst3_v4b2_retain_stream(Steinberg_IBStream* stream) {
  if (!stream || !stream->lpVtbl || !stream->lpVtbl->addRef) return;
  if (g_retained_stream == nullptr) {
    g_retained_stream = stream;
    stream->lpVtbl->addRef(stream);
  }
}
extern "C" void pluginhost_vst3_v4b2_component_created() {
  ++g_component_creates;
  ++g_live_components;
  if (g_live_components > g_max_live_components)
    g_max_live_components = g_live_components;
}
extern "C" void pluginhost_vst3_v4b2_component_initialized() {
  ++g_component_initializes;
}
extern "C" void pluginhost_vst3_v4b2_component_terminated() {
  ++g_component_terminates;
}
extern "C" void pluginhost_vst3_v4b2_component_released() {
  if (g_live_components > 0) --g_live_components;
}
extern "C" void pluginhost_vst3_v4b2_module_entry() {
  if (g_module_entries > 0 && g_module_event != 2)
    g_module_order_bad = true;
  g_module_event = 1;
  ++g_module_entries;
}
extern "C" void pluginhost_vst3_v4b2_module_exit() {
  g_module_event = 2;
  ++g_module_exits;
}

#define PLUGINHOST_VST3_V4B2_FIXTURE 1
#define PLUGINHOST_VST3_V3_MODE 0
#include "v3_fixture.cpp"
#undef PLUGINHOST_VST3_V3_MODE
#undef PLUGINHOST_VST3_V4B2_FIXTURE

extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_structural(std::int32_t value) {
  g_structural = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_capture_fail(std::int32_t value) {
  g_capture_fail = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_component_capture_fail(std::int32_t value) {
  g_component_capture_fail = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_controller_capture_fail(std::int32_t value) {
  g_controller_capture_fail = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_component_restore_fail(std::int32_t value) {
  g_component_restore_fail = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_controller_restore_fail(std::int32_t value) {
  g_controller_restore_fail = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_retain_stream(std::int32_t value) {
  g_retain_stream = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_release_retained_stream() {
  if (g_retained_stream && g_retained_stream->lpVtbl &&
      g_retained_stream->lpVtbl->release) {
    g_retained_stream->lpVtbl->release(g_retained_stream);
  }
  g_retained_stream = nullptr;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_setup_fail(std::int32_t value) {
  g_setup_fail = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_activation_fail(std::int32_t value) {
  g_activation_fail = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_module_entry_fail(std::int32_t value) {
  g_module_entry_fail = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_component_initialize_fail(std::int32_t value) {
  g_component_initialize_fail = value != 0;
}
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b2_module_entries() { return g_module_entries; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b2_module_exits() { return g_module_exits; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b2_module_order_bad() {
  return g_module_order_bad ? 1U : 0U;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_state_not_implemented(std::int32_t value) {
  g_state_not_implemented = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_gain(double value) {
  g_state.gain = value;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v4b2_set_output(double value) {
  g_state.outputValue = value;
}
extern "C" __attribute__((visibility("default")))
std::int64_t pluginhost_vst3_v4b2_last_sample_position() {
  return g_state.lastSamplePosition;
}
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b2_component_creates() { return g_component_creates; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b2_component_initializes() { return g_component_initializes; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b2_component_terminates() { return g_component_terminates; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4b2_max_live_components() { return g_max_live_components; }
extern "C" __attribute__((visibility("default")))
double pluginhost_vst3_v4b2_gain() { return g_state.gain; }
extern "C" __attribute__((visibility("default")))
double pluginhost_vst3_v4b2_output() { return g_state.outputValue; }
