#include <cstdint>
#include <cstring>

#include "vst3/vst3_c_api.h"

namespace {

static bool g_null_view = false;
static bool g_support_x11 = true;
static bool g_invalid_size = false;
static bool g_fail_set_frame = false;
static bool g_fail_attach = false;
static bool g_fail_remove = false;
static bool g_hold_frame = false;
static Steinberg_IPlugFrame* g_retained_frame = nullptr;
static Steinberg_IPlugFrame* g_frame = nullptr;
static std::uint32_t g_controller_refs = 1;
static std::uint32_t g_view_refs = 1;
static std::uint32_t g_frame_addrefs = 0;
static std::uint32_t g_frame_releases = 0;
static std::uint32_t g_attached = 0;
static std::uint32_t g_removed = 0;
static std::uint32_t g_set_frame = 0;
static std::uint32_t g_constraint_calls = 0;
static std::uint32_t g_size_calls = 0;
static std::uint32_t g_on_size_calls = 0;
static Steinberg_ViewRect g_last_size{0, 0, 640, 480};
static Steinberg_tresult g_last_resize_result = Steinberg_kResultFalse;
static bool g_host_resize_seen = false;
static bool g_resize_order_bad = false;

static Steinberg_tresult viewQuery(void* raw, const Steinberg_TUID iid,
                                   void** obj);
static Steinberg_uint32 viewAddRef(void* raw);
static Steinberg_uint32 viewRelease(void* raw);
static Steinberg_tresult viewPlatform(void* raw, Steinberg_FIDString type);
static Steinberg_tresult viewAttached(void* raw, void* parent,
                                      Steinberg_FIDString type);
static Steinberg_tresult viewRemoved(void* raw);
static Steinberg_tresult viewWheel(void* raw, float distance);
static Steinberg_tresult viewKeyDown(void* raw, Steinberg_char16 key,
                                     Steinberg_int16 keyCode,
                                     Steinberg_int16 modifiers);
static Steinberg_tresult viewKeyUp(void* raw, Steinberg_char16 key,
                                   Steinberg_int16 keyCode,
                                   Steinberg_int16 modifiers);
static Steinberg_tresult viewGetSize(void* raw, Steinberg_ViewRect* size);
static Steinberg_tresult viewOnSize(void* raw, Steinberg_ViewRect* size);
static Steinberg_tresult viewFocus(void* raw, Steinberg_TBool state);
static Steinberg_tresult viewSetFrame(void* raw, Steinberg_IPlugFrame* frame);
static Steinberg_tresult viewCanResize(void* raw);
static Steinberg_tresult viewConstraint(void* raw, Steinberg_ViewRect* rect);

static Steinberg_IPlugViewVtbl g_view_vtbl = {
  viewQuery, viewAddRef, viewRelease, viewPlatform, viewAttached,
  viewRemoved, viewWheel, viewKeyDown, viewKeyUp, viewGetSize, viewOnSize,
  viewFocus, viewSetFrame, viewCanResize, viewConstraint};
static Steinberg_IPlugView g_view{&g_view_vtbl};

static Steinberg_tresult controllerQuery(void* raw, const Steinberg_TUID iid,
                                         void** obj);
static Steinberg_uint32 controllerAddRef(void* raw);
static Steinberg_uint32 controllerRelease(void* raw);
static Steinberg_tresult controllerInitialize(void* raw, Steinberg_FUnknown* context);
static Steinberg_tresult controllerTerminate(void* raw);
static Steinberg_tresult controllerSetComponentState(void* raw,
                                                      Steinberg_IBStream* state);
static Steinberg_tresult controllerSetState(void* raw, Steinberg_IBStream* state);
static Steinberg_tresult controllerGetState(void* raw, Steinberg_IBStream* state);
static Steinberg_int32 controllerParameterCount(void* raw);
static Steinberg_tresult controllerParameterInfo(
    void* raw, Steinberg_int32 index, Steinberg_Vst_ParameterInfo* info);
static Steinberg_tresult controllerParamString(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue value,
    Steinberg_Vst_String128 text);
static Steinberg_tresult controllerParamValue(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_TChar* text,
    Steinberg_Vst_ParamValue* value);
static Steinberg_Vst_ParamValue controllerNormalizedToPlain(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue value);
static Steinberg_Vst_ParamValue controllerPlainToNormalized(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue value);
static Steinberg_Vst_ParamValue controllerGetParam(
    void* raw, Steinberg_Vst_ParamID id);
static Steinberg_tresult controllerSetParam(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue value);
static Steinberg_tresult controllerSetHandler(
    void* raw, Steinberg_Vst_IComponentHandler* handler);
static Steinberg_IPlugView* controllerCreateView(void* raw,
                                                  Steinberg_FIDString name);

static Steinberg_Vst_IEditControllerVtbl g_controller_vtbl = {
  controllerQuery, controllerAddRef, controllerRelease, controllerInitialize,
  controllerTerminate, controllerSetComponentState, controllerSetState,
  controllerGetState, controllerParameterCount, controllerParameterInfo,
  controllerParamString, controllerParamValue, controllerNormalizedToPlain,
  controllerPlainToNormalized, controllerGetParam, controllerSetParam,
  controllerSetHandler, controllerCreateView};
static Steinberg_Vst_IEditController g_controller{&g_controller_vtbl};

static bool isIid(const Steinberg_TUID value, const Steinberg_TUID expected) {
  return std::memcmp(value, expected, sizeof(Steinberg_TUID)) == 0;
}

static void ignore(void* raw) { (void)raw; }

static Steinberg_tresult viewQuery(void* raw, const Steinberg_TUID iid,
                                   void** obj) {
  ignore(raw);
  if (!obj) return Steinberg_kInvalidArgument;
  *obj = nullptr;
  if (isIid(iid, Steinberg_IPlugView_iid) ||
      isIid(iid, Steinberg_FUnknown_iid)) {
    *obj = &g_view;
    ++g_view_refs;
    return Steinberg_kResultOk;
  }
  return Steinberg_kNoInterface;
}

static Steinberg_uint32 viewAddRef(void* raw) {
  ignore(raw);
  return ++g_view_refs;
}

static Steinberg_uint32 viewRelease(void* raw) {
  ignore(raw);
  if (g_view_refs > 0) --g_view_refs;
  return g_view_refs;
}

static Steinberg_tresult viewPlatform(void* raw, Steinberg_FIDString type) {
  ignore(raw);
  if (!type || !g_support_x11) return Steinberg_kResultFalse;
  return std::strcmp(type, Steinberg_kPlatformTypeX11EmbedWindowID) == 0
             ? Steinberg_kResultOk
             : Steinberg_kResultFalse;
}

static Steinberg_tresult viewAttached(void* raw, void* parent,
                                      Steinberg_FIDString type) {
  ignore(raw);
  if (!parent || !type || !g_support_x11 || g_fail_attach)
    return Steinberg_kResultFalse;
  ++g_attached;
  return Steinberg_kResultOk;
}

static Steinberg_tresult viewRemoved(void* raw) {
  ignore(raw);
  if (g_fail_remove) return Steinberg_kResultFalse;
  ++g_removed;
  return Steinberg_kResultOk;
}

static Steinberg_tresult viewWheel(void* raw, float distance) {
  ignore(raw); (void)distance; return Steinberg_kResultOk;
}

static Steinberg_tresult viewKeyDown(void* raw, Steinberg_char16 key,
                                     Steinberg_int16 keyCode,
                                     Steinberg_int16 modifiers) {
  ignore(raw); (void)key; (void)keyCode; (void)modifiers;
  return Steinberg_kResultOk;
}

static Steinberg_tresult viewKeyUp(void* raw, Steinberg_char16 key,
                                   Steinberg_int16 keyCode,
                                   Steinberg_int16 modifiers) {
  ignore(raw); (void)key; (void)keyCode; (void)modifiers;
  return Steinberg_kResultOk;
}

static Steinberg_tresult viewGetSize(void* raw, Steinberg_ViewRect* size) {
  ignore(raw);
  ++g_size_calls;
  if (!size) return Steinberg_kInvalidArgument;
  if (g_invalid_size) {
    *size = Steinberg_ViewRect{0, 0, 0, 480};
  } else {
    *size = g_last_size;
  }
  return Steinberg_kResultOk;
}

static Steinberg_tresult viewOnSize(void* raw, Steinberg_ViewRect* size) {
  ignore(raw);
  if (!size) return Steinberg_kInvalidArgument;
  if (!g_host_resize_seen) g_resize_order_bad = true;
  ++g_on_size_calls;
  g_last_size = *size;
  return Steinberg_kResultOk;
}

static Steinberg_tresult viewFocus(void* raw, Steinberg_TBool state) {
  ignore(raw); (void)state; return Steinberg_kResultOk;
}

static Steinberg_tresult viewSetFrame(void* raw, Steinberg_IPlugFrame* frame) {
  ignore(raw);
  if (frame && g_fail_set_frame) {
    g_frame = frame;
    frame->lpVtbl->addRef(frame);
    ++g_frame_addrefs;
    g_retained_frame = frame;
    return Steinberg_kResultFalse;
  }
  if (!frame) {
    if (g_retained_frame && !g_hold_frame) {
      g_retained_frame->lpVtbl->release(g_retained_frame);
      ++g_frame_releases;
      g_retained_frame = nullptr;
    }
    g_frame = nullptr;
    return Steinberg_kResultOk;
  }
  g_frame = frame;
  frame->lpVtbl->addRef(frame);
  ++g_frame_addrefs;
  g_retained_frame = frame;
  return Steinberg_kResultOk;
}

static Steinberg_tresult viewCanResize(void* raw) {
  ignore(raw); return Steinberg_kResultOk;
}

static Steinberg_tresult viewConstraint(void* raw, Steinberg_ViewRect* rect) {
  ignore(raw);
  ++g_constraint_calls;
  if (!rect) return Steinberg_kInvalidArgument;
  auto width = rect->right - rect->left;
  auto height = rect->bottom - rect->top;
  if (width < 320) width = 320;
  if (height < 240) height = 240;
  if (width & 1) ++width;
  if (height & 1) ++height;
  rect->right = rect->left + width;
  rect->bottom = rect->top + height;
  return Steinberg_kResultOk;
}

static Steinberg_tresult controllerQuery(void* raw, const Steinberg_TUID iid,
                                         void** obj) {
  ignore(raw);
  if (!obj) return Steinberg_kInvalidArgument;
  *obj = nullptr;
  if (isIid(iid, Steinberg_Vst_IEditController_iid) ||
      isIid(iid, Steinberg_FUnknown_iid)) {
    *obj = &g_controller;
    ++g_controller_refs;
    return Steinberg_kResultOk;
  }
  return Steinberg_kNoInterface;
}

static Steinberg_uint32 controllerAddRef(void* raw) {
  ignore(raw); return ++g_controller_refs;
}

static Steinberg_uint32 controllerRelease(void* raw) {
  ignore(raw);
  if (g_controller_refs > 0) --g_controller_refs;
  return g_controller_refs;
}

static Steinberg_tresult controllerInitialize(void* raw, Steinberg_FUnknown* context) {
  ignore(raw); (void)context; return Steinberg_kResultOk;
}

static Steinberg_tresult controllerTerminate(void* raw) {
  ignore(raw); return Steinberg_kResultOk;
}

static Steinberg_tresult controllerSetComponentState(void* raw,
                                                      Steinberg_IBStream* state) {
  ignore(raw); (void)state; return Steinberg_kNotImplemented;
}

static Steinberg_tresult controllerSetState(void* raw, Steinberg_IBStream* state) {
  ignore(raw); (void)state; return Steinberg_kNotImplemented;
}

static Steinberg_tresult controllerGetState(void* raw, Steinberg_IBStream* state) {
  ignore(raw); (void)state; return Steinberg_kNotImplemented;
}

static Steinberg_int32 controllerParameterCount(void* raw) {
  ignore(raw); return 0;
}

static Steinberg_tresult controllerParameterInfo(
    void* raw, Steinberg_int32 index, Steinberg_Vst_ParameterInfo* info) {
  ignore(raw); (void)index; (void)info; return Steinberg_kNotImplemented;
}

static Steinberg_tresult controllerParamString(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue value,
    Steinberg_Vst_String128 text) {
  ignore(raw); (void)id; (void)value; (void)text; return Steinberg_kNotImplemented;
}

static Steinberg_tresult controllerParamValue(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_TChar* text,
    Steinberg_Vst_ParamValue* value) {
  ignore(raw); (void)id; (void)text; (void)value; return Steinberg_kNotImplemented;
}

static Steinberg_Vst_ParamValue controllerNormalizedToPlain(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue value) {
  ignore(raw); (void)id; return value;
}

static Steinberg_Vst_ParamValue controllerPlainToNormalized(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue value) {
  ignore(raw); (void)id; return value;
}

static Steinberg_Vst_ParamValue controllerGetParam(
    void* raw, Steinberg_Vst_ParamID id) {
  ignore(raw); (void)id; return 0.0;
}

static Steinberg_tresult controllerSetParam(
    void* raw, Steinberg_Vst_ParamID id, Steinberg_Vst_ParamValue value) {
  ignore(raw); (void)id; (void)value; return Steinberg_kResultOk;
}

static Steinberg_tresult controllerSetHandler(
    void* raw, Steinberg_Vst_IComponentHandler* handler) {
  ignore(raw); (void)handler; return Steinberg_kResultOk;
}

static Steinberg_IPlugView* controllerCreateView(void* raw,
                                                  Steinberg_FIDString name) {
  ignore(raw);
  if (g_null_view || !name || std::strcmp(name, "editor") != 0)
    return nullptr;
  g_view_refs = 1;
  return &g_view;
}

}  // namespace

extern "C" __attribute__((visibility("default")))
Steinberg_Vst_IEditController* pluginhost_vst3_v5a_controller() {
  g_controller_refs = 1;
  return &g_controller;
}

extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_reset() {
  g_null_view = false;
  g_support_x11 = true;
  g_invalid_size = false;
  g_fail_set_frame = false;
  g_fail_attach = false;
  g_fail_remove = false;
  g_view_vtbl.release = viewRelease;
  g_view_vtbl.onSize = viewOnSize;
  g_hold_frame = false;
  g_retained_frame = nullptr;
  g_frame = nullptr;
  g_frame_addrefs = 0;
  g_frame_releases = 0;
  g_attached = 0;
  g_removed = 0;
  g_set_frame = 0;
  g_constraint_calls = 0;
  g_size_calls = 0;
  g_on_size_calls = 0;
  g_last_size = Steinberg_ViewRect{0, 0, 640, 480};
  g_last_resize_result = Steinberg_kResultFalse;
  g_host_resize_seen = false;
  g_resize_order_bad = false;
}

extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_set_null_view(std::int32_t value) { g_null_view = value != 0; }
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_set_support_x11(std::int32_t value) { g_support_x11 = value != 0; }
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_set_invalid_size(std::int32_t value) { g_invalid_size = value != 0; }
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_set_fail_set_frame(std::int32_t value) { g_fail_set_frame = value != 0; }
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_set_fail_attach(std::int32_t value) { g_fail_attach = value != 0; }
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_set_fail_remove(std::int32_t value) { g_fail_remove = value != 0; }
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_set_nil_release(std::int32_t value) {
  g_view_vtbl.release = value != 0 ? nullptr : viewRelease;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_set_nil_on_size(std::int32_t value) {
  g_view_vtbl.onSize = value != 0 ? nullptr : viewOnSize;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_set_hold_frame(std::int32_t value) {
  g_hold_frame = value != 0;
}
extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_mark_host_resize() {
  g_host_resize_seen = true;
}

extern "C" __attribute__((visibility("default")))
void pluginhost_vst3_v5a_release_frame() {
  if (g_retained_frame && g_retained_frame->lpVtbl &&
      g_retained_frame->lpVtbl->release) {
    g_retained_frame->lpVtbl->release(g_retained_frame);
    ++g_frame_releases;
    g_retained_frame = nullptr;
  }
}

extern "C" __attribute__((visibility("default")))
Steinberg_tresult pluginhost_vst3_v5a_request_resize(
    Steinberg_int32 width, Steinberg_int32 height) {
  if (!g_frame || !g_frame->lpVtbl || !g_frame->lpVtbl->resizeView)
    return Steinberg_kResultFalse;
  Steinberg_ViewRect rect{0, 0, width, height};
  g_host_resize_seen = false;
  g_last_resize_result = g_frame->lpVtbl->resizeView(g_frame, &g_view, &rect);
  return g_last_resize_result;
}

extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_frame_addrefs() { return g_frame_addrefs; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_frame_releases() { return g_frame_releases; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_attached() { return g_attached; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_removed() { return g_removed; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_set_frame_calls() { return g_set_frame; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_constraint_calls() { return g_constraint_calls; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_on_size_calls() { return g_on_size_calls; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_size_calls() { return g_size_calls; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_resize_order_bad() {
  return g_resize_order_bad ? 1U : 0U;
}
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_controller_refs() { return g_controller_refs; }
extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v5a_view_refs() { return g_view_refs; }
