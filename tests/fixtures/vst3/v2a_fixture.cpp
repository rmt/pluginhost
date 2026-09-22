#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

#ifndef PLUGINHOST_VST3_V2A_MODE
#define PLUGINHOST_VST3_V2A_MODE 0
#endif
#ifndef PLUGINHOST_VST3_V4A_MODE
#define PLUGINHOST_VST3_V4A_MODE 0
#endif


using TUID = std::int8_t[16];
using FIDString = const char*;
using tresult = std::int32_t;
using TBool = std::uint8_t;
using ParamID = std::uint32_t;
using ParamValue = double;
using TChar = std::uint16_t;
using String128 = TChar[128];

struct PFactoryInfo { char vendor[64]; char url[256]; char email[128]; std::int32_t flags; };
struct PClassInfo { TUID cid; std::int32_t cardinality; char category[32]; char name[64]; };
struct BusInfo {
  std::int32_t mediaType;
  std::int32_t direction;
  std::int32_t channelCount;
  String128 name;
  std::int32_t busType;
  std::uint32_t flags;
};
struct ParameterInfo {
  ParamID id;
  String128 title;
  String128 shortTitle;
  String128 units;
  std::int32_t stepCount;
  ParamValue defaultNormalizedValue;
  std::int32_t unitId;
  std::int32_t flags;
};

struct IBStream;
struct IAttributeList;
struct IMessage;
struct IHostApplication;
struct IComponentHandler;
struct IConnectionPoint;

struct FUnknown {
  virtual tresult queryInterface(const TUID iid, void** object) = 0;
  virtual std::uint32_t addRef() = 0;
  virtual std::uint32_t release() = 0;
};
struct IComponent : FUnknown {
  virtual tresult initialize(FUnknown* context) = 0;
  virtual tresult terminate() = 0;
  virtual tresult getControllerClassId(TUID classId) = 0;
  virtual tresult setIoMode(std::int32_t mode) = 0;
  virtual std::int32_t getBusCount(std::int32_t type, std::int32_t dir) = 0;
  virtual tresult getBusInfo(std::int32_t type, std::int32_t dir, std::int32_t index, BusInfo* info) = 0;
  virtual tresult getRoutingInfo(void*, void*) = 0;
  virtual tresult activateBus(std::int32_t, std::int32_t, std::int32_t, TBool) = 0;
  virtual tresult setActive(TBool) = 0;
  virtual tresult setState(IBStream*) = 0;
  virtual tresult getState(IBStream*) = 0;
};
struct IAudioProcessor : FUnknown {
  virtual tresult setBusArrangements(void*, std::int32_t, void*, std::int32_t) = 0;
  virtual tresult getBusArrangement(std::int32_t, std::int32_t, std::uint64_t*) = 0;
  virtual tresult canProcessSampleSize(std::int32_t) = 0;
  virtual std::uint32_t getLatencySamples() = 0;
  virtual tresult setupProcessing(void*) = 0;
  virtual tresult setProcessing(TBool) = 0;
  virtual tresult process(void*) = 0;
  virtual std::uint32_t getTailSamples() = 0;
};
struct IEditController : FUnknown {
  virtual tresult initialize(FUnknown*) = 0;
  virtual tresult terminate() = 0;
  virtual tresult setComponentState(IBStream*) = 0;
  virtual tresult setState(IBStream*) = 0;
  virtual tresult getState(IBStream*) = 0;
  virtual std::int32_t getParameterCount() = 0;
  virtual tresult getParameterInfo(std::int32_t, ParameterInfo*) = 0;
  virtual tresult getParamStringByValue(ParamID, ParamValue, String128) = 0;
  virtual tresult getParamValueByString(ParamID, const TChar*, ParamValue*) = 0;
  virtual ParamValue normalizedParamToPlain(ParamID, ParamValue) = 0;
  virtual ParamValue plainParamToNormalized(ParamID, ParamValue) = 0;
  virtual ParamValue getParamNormalized(ParamID) = 0;
  virtual tresult setParamNormalized(ParamID, ParamValue) = 0;
  virtual tresult setComponentHandler(IComponentHandler*) = 0;
  virtual void* createView(FIDString) = 0;
};
struct IConnectionPoint : FUnknown {
  virtual tresult connect(IConnectionPoint*) = 0;
  virtual tresult disconnect(IConnectionPoint*) = 0;
  virtual tresult notify(IMessage*) = 0;
};
struct IBStream : FUnknown {
  virtual tresult read(void*, std::int32_t, std::int32_t*) = 0;
  virtual tresult write(void*, std::int32_t, std::int32_t*) = 0;
  virtual tresult seek(std::int64_t, std::int32_t, std::int64_t*) = 0;
  virtual tresult tell(std::int64_t*) = 0;
};
struct IComponentHandler : FUnknown {
  virtual tresult beginEdit(ParamID) = 0;
  virtual tresult performEdit(ParamID, ParamValue) = 0;
  virtual tresult endEdit(ParamID) = 0;
  virtual tresult restartComponent(std::int32_t) = 0;
};
struct IHostApplication : FUnknown {
  virtual tresult getName(String128) = 0;
  virtual tresult createInstance(const TUID, const TUID, void**) = 0;
};
struct IRunLoopEventHandler : FUnknown {
  virtual void onFDIsSet(std::int32_t) = 0;
};
struct IRunLoopTimerHandler : FUnknown {
  virtual void onTimer() = 0;
};
struct IRunLoop : FUnknown {
  virtual tresult registerEventHandler(IRunLoopEventHandler*, std::int32_t) = 0;
  virtual tresult unregisterEventHandler(IRunLoopEventHandler*) = 0;
  virtual tresult registerTimer(IRunLoopTimerHandler*, std::uint64_t) = 0;
  virtual tresult unregisterTimer(IRunLoopTimerHandler*) = 0;
};
struct IPluginFactory : FUnknown {
  virtual tresult getFactoryInfo(PFactoryInfo*) = 0;
  virtual std::int32_t countClasses() = 0;
  virtual tresult getClassInfo(std::int32_t, PClassInfo*) = 0;
  virtual tresult createInstance(FIDString, FIDString, void**) = 0;
};

static const std::uint8_t kFUnknownIid[16] = {0,0,0,0,0,0,0,0,
  (std::uint8_t)0xC0,0,0,0,0,0,0,0x46};
static const std::uint8_t kEventHandlerIid[16] = {0x56,0x1E,0x65,(std::uint8_t)0xC9,
  0x13,0xA0,0x49,0x6F,(std::uint8_t)0x81,0x3A,0x2C,0x35,0x65,0x4D,0x79,(std::uint8_t)0x83};
static const std::uint8_t kTimerHandlerIid[16] = {0x10,(std::uint8_t)0xBD,0xD9,0x4F,
  0x41,0x42,0x47,0x74,(std::uint8_t)0x82,0x1F,(std::uint8_t)0xAD,0x8F,(std::uint8_t)0xEC,0xA7,0x2C,(std::uint8_t)0xA9};
static const std::uint8_t kFactoryIid[16] = {0x7A,0x4D,(std::uint8_t)0x81,0x1C,0x52,0x11,0x4A,0x1F,(std::uint8_t)0xAE,(std::uint8_t)0xD9,0xD2,0xEE,0x0B,0x43,(std::uint8_t)0xBF,(std::uint8_t)0x9F};
static const std::uint8_t kComponentIid[16] = {(std::uint8_t)0xE8,0x31,(std::uint8_t)0xFF,0x31,(std::uint8_t)0xF2,(std::uint8_t)0xD5,0x43,0x01,(std::uint8_t)0x92,(std::uint8_t)0x8E,(std::uint8_t)0xBB,(std::uint8_t)0xEE,0x25,0x69,0x78,0x02};
static const std::uint8_t kProcessorIid[16] = {0x42,0x04,0x3F,(std::uint8_t)0x99,(std::uint8_t)0xB7,(std::uint8_t)0xDA,0x45,0x3C,(std::uint8_t)0xA5,0x69,(std::uint8_t)0xE7,(std::uint8_t)0x9D,(std::uint8_t)0x9A,(std::uint8_t)0xAE,(std::uint8_t)0xC3,0x3D};
static const std::uint8_t kControllerIid[16] = {(std::uint8_t)0xDC,0xD7,(std::uint8_t)0xBB,(std::uint8_t)0xE3,0x77,0x42,0x44,0x8D,(std::uint8_t)0xA8,0x74,(std::uint8_t)0xAA,(std::uint8_t)0xCC,(std::uint8_t)0x97,(std::uint8_t)0x9C,0x75,(std::uint8_t)0x9E};
static const std::uint8_t kConnectionIid[16] = {0x70,(std::uint8_t)0xA4,0x15,0x6F,0x6E,0x6E,0x40,0x26,(std::uint8_t)0x98,(std::uint8_t)0x91,0x48,(std::uint8_t)0xBF,(std::uint8_t)0xAA,0x60,(std::uint8_t)0xD8,(std::uint8_t)0xD1};
static const std::uint8_t kHostIid[16] = {0x58,(std::uint8_t)0xE5,0x95,(std::uint8_t)0xCC,(std::uint8_t)0xDB,0x2D,0x49,0x69,(std::uint8_t)0x8B,0x6A,(std::uint8_t)0xAF,(std::uint8_t)0x8C,0x36,(std::uint8_t)0xA6,0x64,(std::uint8_t)0xE5};
static const std::uint8_t kProcessorCid[16] = {0x10,0x21,0x32,0x43,0x54,0x65,0x76,0x87,(std::uint8_t)0x98,0xA9,(std::uint8_t)0xBA,(std::uint8_t)0xCB,(std::uint8_t)0xDC,(std::uint8_t)0xED,(std::uint8_t)0xFE,(std::uint8_t)0xFF};
static const std::uint8_t kControllerCid[16] = {0x20,0x31,0x42,0x53,0x64,0x75,0x86,0x97,(std::uint8_t)0xA8,(std::uint8_t)0xB9,(std::uint8_t)0xCA,(std::uint8_t)0xDB,(std::uint8_t)0xEC,(std::uint8_t)0xFD,0x0E,0x1F};
static const std::uint8_t kRunLoopIid[16] = {0x18,(std::uint8_t)0xC3,0x53,0x66,0x97,0x76,0x4F,0x1A,(std::uint8_t)0x9C,0x5B,(std::uint8_t)0x83,0x85,0x7A,0x87,0x13,0x89};

static std::uint32_t g_factory_refs = 1;
static std::uint32_t g_component_refs = 0;
static std::uint32_t g_controller_refs = 0;
static std::uint32_t g_factory_acquire = 0;
static std::uint32_t g_factory_addref = 0;
static std::uint32_t g_factory_release = 0;
static std::uint32_t g_component_acquire = 0;
static std::uint32_t g_component_addref = 0;
static std::uint32_t g_component_release = 0;
static std::uint32_t g_processor_acquire = 0;
static std::uint32_t g_processor_addref = 0;
static std::uint32_t g_processor_release = 0;
static std::uint32_t g_component_point_acquire = 0;
static std::uint32_t g_component_point_addref = 0;
static std::uint32_t g_component_point_release = 0;
static std::uint32_t g_controller_acquire = 0;
static std::uint32_t g_controller_addref = 0;
static std::uint32_t g_controller_release = 0;
static std::uint32_t g_controller_point_acquire = 0;
static std::uint32_t g_controller_point_addref = 0;
static std::uint32_t g_controller_point_release = 0;
static std::uint32_t g_handler_retention_addref = 0;
static std::uint32_t g_handler_retention_release = 0;
static std::uint32_t g_proxy_retention_addref = 0;
static std::uint32_t g_proxy_retention_release = 0;
static std::uint32_t g_module_exit = 0;
static std::uint32_t g_component_initialize = 0;
static std::uint32_t g_component_terminate = 0;
static std::uint32_t g_controller_initialize = 0;
static std::uint32_t g_controller_terminate = 0;
static std::uint32_t g_connect_component = 0;
static std::uint32_t g_connect_controller = 0;
static std::uint32_t g_disconnect_component = 0;
static std::uint32_t g_disconnect_controller = 0;
static std::uint32_t g_state_get = 0;
static std::uint32_t g_state_set = 0;
static std::uint32_t g_controller_state_set = 0;
static std::uint32_t g_combined_set_state_calls = 0;
static std::uint32_t g_state_bytes_observed = 0;
static std::uint32_t g_state_order[16] = {};
static std::uint32_t g_state_order_count = 0;
static void recordState(std::uint32_t value) {
  if (g_state_order_count < 16) g_state_order[g_state_order_count++] = value;
}
static bool same(const void* a, const void* b) { return a && std::memcmp(a, b, 16) == 0; }
static void setText(String128 out, const char* text) {
  std::memset(out, 0, sizeof(String128));
  for (std::size_t i = 0; text[i] && i + 1 < 128; ++i) out[i] = static_cast<TChar>(text[i]);
}
static std::uint32_t g_runloop_fd_callbacks = 0;
static std::uint32_t g_runloop_timer_callbacks = 0;
static std::int32_t g_runloop_pipe[2] = {-1, -1};
static IRunLoop* g_runloop = nullptr;
static bool g_runloop_fd_registered = false;
static bool g_runloop_timer_registered = false;
#if PLUGINHOST_VST3_V2A_MODE == 14 || defined(PLUGINHOST_VST3_V4A_FIXTURE)
static IBStream* g_retained_stream = nullptr;
#endif

class FixtureEventHandler final : public IRunLoopEventHandler {
 public:
  tresult queryInterface(const TUID iid, void** object) override {
    if (!object) return 2;
    *object = nullptr;
    if (same(iid, kEventHandlerIid) || same(iid, kFUnknownIid))
      *object = this;
    if (!*object) return -1;
    addRef();
    return 0;
  }
  std::uint32_t addRef() override { return ++references_; }
  std::uint32_t release() override { return references_ > 0 ? --references_ : 0; }
  void onFDIsSet(std::int32_t fd) override {
    if (fd != g_runloop_pipe[0]) return;
    char byte = 0;
    if (::read(fd, &byte, 1) == 1) ++g_runloop_fd_callbacks;
  }
 private:
  std::uint32_t references_ = 1;
};

class FixtureTimerHandler final : public IRunLoopTimerHandler {
 public:
  tresult queryInterface(const TUID iid, void** object) override {
    if (!object) return 2;
    *object = nullptr;
    if (same(iid, kTimerHandlerIid) || same(iid, kFUnknownIid))
      *object = this;
    if (!*object) return -1;
    addRef();
    return 0;
  }
  std::uint32_t addRef() override { return ++references_; }
  std::uint32_t release() override { return references_ > 0 ? --references_ : 0; }
  void onTimer() override {
    ++g_runloop_timer_callbacks;
    if (g_runloop != nullptr) {
      g_runloop_timer_registered = false;
      g_runloop->unregisterTimer(this);
    }
  }
 private:
  std::uint32_t references_ = 1;
};

static FixtureEventHandler g_event_handler;
static FixtureTimerHandler g_timer_handler;

class ComponentView : public IComponent {
 public:
  std::uint32_t addRef() override { ++g_component_addref; return ++g_component_refs; }
  std::uint32_t release() override {
    ++g_component_release;
    return g_component_refs > 0 ? --g_component_refs : 0;
  }
};
class ProcessorView : public IAudioProcessor {
 public:
  std::uint32_t addRef() override { ++g_processor_addref; return ++g_component_refs; }
  std::uint32_t release() override {
    ++g_processor_release;
    return g_component_refs > 0 ? --g_component_refs : 0;
  }
};
class ComponentPointView : public IConnectionPoint {
 public:
  std::uint32_t addRef() override {
    ++g_component_point_addref;
    return ++g_component_refs;
  }
  std::uint32_t release() override {
    ++g_component_point_release;
    return g_component_refs > 0 ? --g_component_refs : 0;
  }
};
class CombinedControllerView : public IEditController {
 public:
  std::uint32_t addRef() override {
    ++g_controller_addref;
    return ++g_component_refs;
  }
  std::uint32_t release() override {
    ++g_controller_release;
    return g_component_refs > 0 ? --g_component_refs : 0;
  }
};
class SeparateControllerView : public IEditController {
 public:
  std::uint32_t addRef() override {
    ++g_controller_addref;
    return ++g_controller_refs;
  }
  std::uint32_t release() override {
    ++g_controller_release;
    return g_controller_refs > 0 ? --g_controller_refs : 0;
  }
};
class ControllerPointView : public IConnectionPoint {
 public:
  std::uint32_t addRef() override {
    ++g_controller_point_addref;
    return ++g_controller_refs;
  }
  std::uint32_t release() override {
    ++g_controller_point_release;
    return g_controller_refs > 0 ? --g_controller_refs : 0;
  }
};

class FixtureObject final : public ComponentView, public ProcessorView,
                            public CombinedControllerView, public ComponentPointView {
 public:
  tresult queryInterface(const TUID iid, void** object) override {
    if (!object) return 2;
    *object = nullptr;
    if (same(iid, kFUnknownIid) || same(iid, kComponentIid)) {
      *object = static_cast<IComponent*>(this);
      static_cast<IComponent*>(this)->addRef();
    } else if (same(iid, kProcessorIid)) {
      *object = static_cast<IAudioProcessor*>(this);
      ++g_processor_acquire;
      static_cast<IAudioProcessor*>(this)->addRef();
    } else if (same(iid, kConnectionIid)) {
      *object = static_cast<IConnectionPoint*>(this);
      ++g_component_point_acquire;
      static_cast<IConnectionPoint*>(this)->addRef();
    }
#if PLUGINHOST_VST3_V2A_MODE == 5
    else if (same(iid, kControllerIid)) {
      *object = static_cast<IEditController*>(this);
      ++g_controller_acquire;
      static_cast<IEditController*>(this)->addRef();
    }
#endif
    if (!*object) return -1;
    return 0;
  }
  tresult getControllerClassId(TUID cid) override {
    (void)cid;
#if PLUGINHOST_VST3_V2A_MODE == 6
    return -1;
#else
    std::memcpy(cid, kControllerCid, 16);
    return 0;
#endif
  }
  tresult setIoMode(std::int32_t mode) override { return mode == 1 ? 0 : 1; }
  std::int32_t getBusCount(std::int32_t type, std::int32_t dir) override {
    (void)dir;
#if PLUGINHOST_VST3_V2A_MODE == 9
    if (type == 0 && dir == 0) return -1;
#endif
    return type == 0 ? 1 : 0;
  }
  tresult getBusInfo(std::int32_t type, std::int32_t dir, std::int32_t index, BusInfo* info) override {
    if (!info || type != 0 || index != 0) return 2;
    std::memset(info, 0, sizeof(*info));
    info->mediaType = type; info->direction = dir; info->channelCount = 2;
    info->busType = dir == 0 ? 0 : 1; info->flags = 1; setText(info->name, dir == 0 ? "Input" : "Output");
    return 0;
  }
  tresult getRoutingInfo(void*, void*) override { return 3; }
  tresult activateBus(std::int32_t, std::int32_t, std::int32_t, TBool) override { return 0; }
  tresult setActive(TBool) override { return 0; }
  tresult setState(IBStream*) override {
    ++g_combined_set_state_calls;
#if PLUGINHOST_VST3_V4A_MODE == 10
    return 3;
#elif PLUGINHOST_VST3_V4A_MODE == 1
    if (g_combined_set_state_calls == 1) return -42;
#elif PLUGINHOST_VST3_V4A_MODE == 2
    if (g_combined_set_state_calls > 1) return -42;
#endif
#if PLUGINHOST_VST3_V2A_MODE == 5
    if (g_combined_set_state_calls > 1) {
      ++g_controller_state_set;
      recordState(5);
      return 0;
    }
#endif
    recordState(1);
    return 0;
  }
  tresult getState(IBStream* stream) override {
    ++g_state_get;
    recordState(2);
#if PLUGINHOST_VST3_V4A_MODE == 11
    return 3;
#elif PLUGINHOST_VST3_V4A_MODE == 4
    if (g_state_get > 1) return -42;
#elif PLUGINHOST_VST3_V4A_MODE == 6
    if (g_state_get > 2) return 3;
#elif PLUGINHOST_VST3_V4A_MODE == 7
    if (g_state_get > 2) return -42;
#elif PLUGINHOST_VST3_V4A_MODE == 9
    if (g_state_get == 1 && stream != nullptr) {
      std::int64_t position = 0;
      std::uint8_t byte = 0;
      (void)stream->seek(64 * 1024 * 1024, 0, &position);
      std::int32_t written = 0;
      (void)stream->write(&byte, 1, &written);
      return 0;
    }
#elif PLUGINHOST_VST3_V4A_MODE == 3
    if (g_state_get > 1 && stream != nullptr) {
      std::int64_t position = 0;
      std::uint8_t byte = 0;
      (void)stream->seek(64 * 1024 * 1024, 0, &position);
      std::int32_t written = 0;
      (void)stream->write(&byte, 1, &written);
      return 0;
    }
#endif
    (void)stream;
#if PLUGINHOST_VST3_V2A_MODE == 7
    return 3;
#else
    if (stream == nullptr) return 2;
    const std::uint8_t bytes[4] = {0x56, 0x32, 0x41, 0x00};
    std::int32_t written = 0;
    if (stream->write(const_cast<std::uint8_t*>(bytes), 4, &written) != 0 ||
        written != 4) return 2;
#if PLUGINHOST_VST3_V2A_MODE == 14 || PLUGINHOST_VST3_V4A_MODE == 5
    if (g_retained_stream == nullptr) {
      g_retained_stream = stream;
      g_retained_stream->addRef();
    }
#endif
    return 0;
#endif
  }
  tresult initialize(FUnknown* context) override {
    ++g_component_initialize;
    if (PLUGINHOST_VST3_V2A_MODE == 1) return -42;
    if (context != nullptr) {
      void* runLoopObject = nullptr;
      if (static_cast<IHostApplication*>(context)->queryInterface(
            reinterpret_cast<const std::int8_t*>(kRunLoopIid), &runLoopObject) == 0 && runLoopObject != nullptr) {
        g_runloop = static_cast<IRunLoop*>(runLoopObject);
        if (::pipe2(g_runloop_pipe, O_NONBLOCK | O_CLOEXEC) == 0) {
          g_runloop_fd_registered =
            g_runloop->registerEventHandler(&g_event_handler,
                                             g_runloop_pipe[0]) == 0;
          g_runloop_timer_registered =
            g_runloop->registerTimer(&g_timer_handler, 1) == 0;
          const char byte = 'v';
          if (g_runloop_fd_registered) (void)::write(g_runloop_pipe[1], &byte, 1);
        }
      }
    }
    return 0;
  }
  tresult terminate() override {
    ++g_component_terminate;
    if (PLUGINHOST_VST3_V2A_MODE == 11) return -42;
    if (g_runloop != nullptr) {
      if (g_runloop_fd_registered) {
        g_runloop->unregisterEventHandler(&g_event_handler);
        g_runloop_fd_registered = false;
      }
      if (g_runloop_timer_registered) {
        g_runloop->unregisterTimer(&g_timer_handler);
        g_runloop_timer_registered = false;
      }
      g_runloop->release();
      g_runloop = nullptr;
    }
    if (g_runloop_pipe[0] >= 0) ::close(g_runloop_pipe[0]);
    if (g_runloop_pipe[1] >= 0) ::close(g_runloop_pipe[1]);
    g_runloop_pipe[0] = g_runloop_pipe[1] = -1;
    return 0;
  }
  tresult setBusArrangements(void*, std::int32_t, void*, std::int32_t) override { return 0; }
  tresult getBusArrangement(std::int32_t, std::int32_t, std::uint64_t* value) override { if (value) *value = 3; return 0; }
  tresult canProcessSampleSize(std::int32_t) override { return 0; }
  std::uint32_t getLatencySamples() override { return 0; }
  tresult setupProcessing(void*) override { return 0; }
  tresult setProcessing(TBool) override { return 0; }
  tresult process(void*) override { return 0; }
  std::uint32_t getTailSamples() override { return 0; }
  tresult setComponentState(IBStream* stream) override {
    recordState(3);
    ++g_state_set;
    if (PLUGINHOST_VST3_V2A_MODE == 8) return 3;
#if PLUGINHOST_VST3_V4A_MODE == 8
    return -42;
#endif
    if (stream == nullptr) return 2;
    std::uint8_t bytes[4] = {};
    std::int32_t read = 0;
    if (stream->read(bytes, 4, &read) != 0 || read != 4) return 2;
    if (bytes[0] == 0x56 && bytes[1] == 0x32 &&
        bytes[2] == 0x41 && bytes[3] == 0x00) {
      g_state_bytes_observed = 4;
    }
    return 0;
  }
  std::int32_t getParameterCount() override {
#if PLUGINHOST_VST3_V2A_MODE == 10
    return 4097;
#else
    return 1;
#endif
  }
  tresult getParameterInfo(std::int32_t index, ParameterInfo* info) override {
    if (!info || index != 0) return 2;
    std::memset(info, 0, sizeof(*info)); info->id = 42; info->stepCount = 0; info->defaultNormalizedValue = 0.5; setText(info->title, "Gain"); setText(info->shortTitle, "Gain"); setText(info->units, "dB"); return 0;
  }
  tresult getParamStringByValue(ParamID, ParamValue, String128) override { return 3; }
  tresult getParamValueByString(ParamID, const TChar*, ParamValue*) override { return 3; }
  ParamValue normalizedParamToPlain(ParamID, ParamValue value) override { return value; }
  ParamValue plainParamToNormalized(ParamID, ParamValue value) override { return value; }
  ParamValue getParamNormalized(ParamID) override { return 0.5; }
  tresult setParamNormalized(ParamID, ParamValue) override { return 0; }
  tresult setComponentHandler(IComponentHandler* handler) override {
    if (PLUGINHOST_VST3_V2A_MODE == 12 && handler != nullptr &&
        retained_handler_ == nullptr) {
      retained_handler_ = handler;
      ++g_handler_retention_addref;
      retained_handler_->addRef();
    }
    handler_ = handler;
    return 0;
  }
  void releaseRetained() {
    if (retained_handler_ != nullptr) {
      ++g_handler_retention_release;
      retained_handler_->release();
      retained_handler_ = nullptr;
    }
    if (retained_proxy_ != nullptr) {
      ++g_proxy_retention_release;
      retained_proxy_->release();
      retained_proxy_ = nullptr;
    }
#if PLUGINHOST_VST3_V2A_MODE == 14 || PLUGINHOST_VST3_V4A_MODE == 5
    if (g_retained_stream != nullptr) {
      g_retained_stream->release();
      g_retained_stream = nullptr;
    }
#endif
  }
  void* createView(FIDString) override { return nullptr; }
  tresult connect(IConnectionPoint* other) override {
    if (!other) return 2;
#if PLUGINHOST_VST3_V2A_MODE == 3
    return -42;
#endif
    ++g_connect_component;
    peer_ = other;
    if (PLUGINHOST_VST3_V2A_MODE == 13 && retained_proxy_ == nullptr) {
      retained_proxy_ = other;
      ++g_proxy_retention_addref;
      retained_proxy_->addRef();
    }
    return 0;
  }
  tresult disconnect(IConnectionPoint* other) override { if (peer_ != other) return 1; peer_ = nullptr; ++g_disconnect_component; return 0; }
  tresult notify(IMessage*) override { return 0; }
 private:
  IConnectionPoint* peer_ = nullptr;
  IComponentHandler* handler_ = nullptr;
  IComponentHandler* retained_handler_ = nullptr;
  IConnectionPoint* retained_proxy_ = nullptr;
};
static FixtureObject g_combined;

class SeparateController final : public SeparateControllerView, public ControllerPointView {
 public:
  tresult queryInterface(const TUID iid, void** object) override {
    if (!object) return 2;
    *object = nullptr;
    if (same(iid, kFUnknownIid) || same(iid, kControllerIid)) {
      *object = static_cast<IEditController*>(this);
      static_cast<IEditController*>(this)->addRef();
    } else if (same(iid, kConnectionIid)) {
      *object = static_cast<IConnectionPoint*>(this);
      ++g_controller_point_acquire;
      static_cast<IConnectionPoint*>(this)->addRef();
    }
    if (!*object) return -1;
    return 0;
  }
  tresult initialize(FUnknown* context) override {
    (void)context;
    ++g_controller_initialize;
    return (PLUGINHOST_VST3_V2A_MODE == 2 || PLUGINHOST_VST3_V2A_MODE == 11) ? -42 : 0;
  }
  tresult terminate() override { ++g_controller_terminate; return 0; }
  tresult setComponentState(IBStream*) override {
    recordState(4);
    ++g_state_set;
    return PLUGINHOST_VST3_V2A_MODE == 8 ? 3 : 0;
  }
  tresult setState(IBStream*) override { ++g_controller_state_set; recordState(5); return 0; }
  tresult getState(IBStream*) override { ++g_controller_state_set; return 3; }
  std::int32_t getParameterCount() override {
#if PLUGINHOST_VST3_V2A_MODE == 10
    return 4097;
#else
    return 1;
#endif
  }
  tresult getParameterInfo(std::int32_t index, ParameterInfo* info) override { if (!info || index != 0) return 2; std::memset(info, 0, sizeof(*info)); info->id = 42; info->defaultNormalizedValue = 0.5; setText(info->title, "Gain"); setText(info->shortTitle, "Gain"); setText(info->units, "dB"); return 0; }
  tresult getParamStringByValue(ParamID, ParamValue, String128) override { return 3; }
  tresult getParamValueByString(ParamID, const TChar*, ParamValue*) override { return 3; }
  ParamValue normalizedParamToPlain(ParamID, ParamValue value) override { return value; }
  ParamValue plainParamToNormalized(ParamID, ParamValue value) override { return value; }
  ParamValue getParamNormalized(ParamID) override { return 0.5; }
  tresult setParamNormalized(ParamID, ParamValue) override { return 0; }
  tresult setComponentHandler(IComponentHandler* handler) override {
    if (PLUGINHOST_VST3_V2A_MODE == 12 && handler != nullptr &&
        retained_handler_ == nullptr) {
      retained_handler_ = handler;
      ++g_handler_retention_addref;
      retained_handler_->addRef();
    }
    return 0;
  }
  void* createView(FIDString) override { return nullptr; }
  tresult connect(IConnectionPoint* other) override {
    if (!other) return 2;
    if (PLUGINHOST_VST3_V2A_MODE == 4) return -42;
    peer_ = other;
    if (PLUGINHOST_VST3_V2A_MODE == 13 && retained_proxy_ == nullptr) {
      retained_proxy_ = other;
      ++g_proxy_retention_addref;
      retained_proxy_->addRef();
    }
    ++g_connect_controller;
    return 0;
  }
  tresult disconnect(IConnectionPoint* other) override { if (peer_ != other) return 1; peer_ = nullptr; ++g_disconnect_controller; return 0; }
  tresult notify(IMessage*) override { return 0; }
  void releaseRetained() {
    if (retained_handler_ != nullptr) {
      ++g_handler_retention_release;
      retained_handler_->release();
      retained_handler_ = nullptr;
    }
    if (retained_proxy_ != nullptr) {
      ++g_proxy_retention_release;
      retained_proxy_->release();
      retained_proxy_ = nullptr;
    }
  }
 private:
  IConnectionPoint* peer_ = nullptr;
  IComponentHandler* retained_handler_ = nullptr;
  IConnectionPoint* retained_proxy_ = nullptr;
};
static SeparateController g_controller;
class Factory final : public IPluginFactory {
 public:
  tresult queryInterface(const TUID iid, void** object) override {
    if (!object) return 2;
    *object = nullptr;
    if (same(iid, kFUnknownIid) || same(iid, kFactoryIid)) *object = this;
    if (!*object) return -1;
    addRef();
    return 0;
  }
  std::uint32_t addRef() override { ++g_factory_addref; return ++g_factory_refs; }
  std::uint32_t release() override {
    ++g_factory_release;
    return g_factory_refs > 0 ? --g_factory_refs : 0;
  }
  tresult getFactoryInfo(PFactoryInfo* info) override {
    if (!info) return 2;
    std::memset(info, 0, sizeof(*info));
    std::memcpy(info->vendor, "pluginhost V2A", 14);
    return 0;
  }
  std::int32_t countClasses() override { return 1; }
  tresult getClassInfo(std::int32_t index, PClassInfo* info) override {
    if (!info || index != 0) return 2;
    std::memset(info, 0, sizeof(*info));
    std::memcpy(info->cid, kProcessorCid, 16);
    std::memcpy(info->category, "Audio Module Class", 18);
    std::memcpy(info->name, "V2A Fixture", 11);
    return 0;
  }
  tresult createInstance(FIDString cid, FIDString iid, void** object) override {
    if (!object) return 2;
    *object = nullptr;
    if (same(cid, kProcessorCid) && same(iid, kComponentIid)) {
      *object = static_cast<IComponent*>(&g_combined);
      ++g_component_acquire;
      static_cast<IComponent*>(&g_combined)->addRef();
      return 0;
    }
#if PLUGINHOST_VST3_V2A_MODE != 5 && PLUGINHOST_VST3_V2A_MODE != 6
    if (same(cid, kControllerCid) && same(iid, kControllerIid)) {
      *object = static_cast<IEditController*>(&g_controller);
      ++g_controller_acquire;
      static_cast<IEditController*>(&g_controller)->addRef();
      return 0;
    }
#endif
    return -1;
  }
};
static Factory g_factory;
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_factory_mapping_ok() {
  const char* processorCid = reinterpret_cast<const char*>(kProcessorCid);
#if PLUGINHOST_VST3_V2A_MODE != 5 && PLUGINHOST_VST3_V2A_MODE != 6
  const char* controllerCid = reinterpret_cast<const char*>(kControllerCid);
#endif
  const char* wrongCid = "unsupported-cid";
  const std::uint8_t unsupportedIid[16] = {};
  auto check = [&](const char* cid, const std::uint8_t* iid, bool expected) {
    void* object = nullptr;
    const tresult result = g_factory.createInstance(
      cid, reinterpret_cast<const char*>(iid), &object);
    if (expected) {
      if (result != 0 || !object) return false;
      reinterpret_cast<FUnknown*>(object)->release();
      return true;
    }
    return result == -1 && object == nullptr;
  };
#if PLUGINHOST_VST3_V2A_MODE != 5 && PLUGINHOST_VST3_V2A_MODE != 6
  if (!check(processorCid, kComponentIid, true)) return 0;
  if (!check(controllerCid, kControllerIid, true)) return 0;
#else
  if (!check(processorCid, kComponentIid, true)) return 0;
#endif
  if (!check(processorCid, unsupportedIid, false)) return 0;
  return check(wrongCid, kComponentIid, false) ? 1u : 0u;
}

extern "C" __attribute__((visibility("default"))) bool ModuleEntry(void*) { return true; }
extern "C" __attribute__((visibility("default"))) bool ModuleExit() { ++g_module_exit; return true; }
extern "C" __attribute__((visibility("default"))) IPluginFactory* GetPluginFactory() { ++g_factory_acquire; return &g_factory; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_state_order_count() { return g_state_order_count; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_state_order(std::uint32_t index) { return index < g_state_order_count ? g_state_order[index] : 0; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_component_initialize() { return g_component_initialize; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_component_terminate() { return g_component_terminate; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_initialize() { return g_controller_initialize; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_state_set() { return g_controller_state_set; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_terminate() { return g_controller_terminate; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_state_get() { return g_state_get; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_state_set() { return g_state_set; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_state_bytes_observed() { return g_state_bytes_observed; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_connect_component() { return g_connect_component; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_factory_refs() { return g_factory_refs; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_factory_addref() { return g_factory_addref; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_factory_acquire() { return g_factory_acquire; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_factory_release() { return g_factory_release; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_component_refs() { return g_component_refs; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_component_addref() { return g_component_addref; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_component_release() { return g_component_release; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_component_acquire() { return g_component_acquire; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_processor_acquire() { return g_processor_acquire; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_processor_addref() { return g_processor_addref; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_processor_release() { return g_processor_release; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_component_point_acquire() { return g_component_point_acquire; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_component_point_addref() { return g_component_point_addref; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_component_point_release() { return g_component_point_release; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_point_acquire() { return g_controller_point_acquire; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_point_addref() { return g_controller_point_addref; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_point_release() { return g_controller_point_release; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_handler_retention_addref() { return g_handler_retention_addref; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_handler_retention_release() { return g_handler_retention_release; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_proxy_retention_addref() { return g_proxy_retention_addref; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_proxy_retention_release() { return g_proxy_retention_release; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_refs() { return g_controller_refs; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_acquire() { return g_controller_acquire; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_addref() { return g_controller_addref; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_controller_release() { return g_controller_release; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_module_exit() { return g_module_exit; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_connect_controller() { return g_connect_controller; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_disconnect_component() { return g_disconnect_component; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_disconnect_controller() { return g_disconnect_controller; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_runloop_fd_callbacks() { return g_runloop_fd_callbacks; }
extern "C" __attribute__((visibility("default"))) std::uint32_t pluginhost_vst3_v2a_runloop_timer_callbacks() { return g_runloop_timer_callbacks; }
extern "C" __attribute__((visibility("default"))) void pluginhost_vst3_v2a_release_retained() {
  g_combined.releaseRetained();
  g_controller.releaseRetained();
}
