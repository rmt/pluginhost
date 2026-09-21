#include <cstddef>
#include <cstdint>
#include <cstring>

#ifndef PLUGINHOST_VST3_FIXTURE_MODE
#define PLUGINHOST_VST3_FIXTURE_MODE 0
#endif

using TUID = std::int8_t[16];
using FIDString = const char*;

struct PFactoryInfo {
  char vendor[64];
  char url[256];
  char email[128];
  std::int32_t flags;
};

struct PClassInfo {
  TUID cid;
  std::int32_t cardinality;
  char category[32];
  char name[64];
};

struct PClassInfo2 {
  TUID cid;
  std::int32_t cardinality;
  char category[32];
  char name[64];
  std::uint32_t classFlags;
  char subCategories[128];
  char vendor[64];
  char version[64];
  char sdkVersion[64];
};
struct PClassInfoW {
  TUID cid;
  std::int32_t cardinality;
  char category[32];
  std::uint16_t name[64];
  std::uint32_t classFlags;
  char subCategories[128];
  std::uint16_t vendor[64];
  std::uint16_t version[64];
  std::uint16_t sdkVersion[64];
};

class FUnknown {
 public:
  virtual std::int32_t queryInterface(const TUID iid, void** object) = 0;
  virtual std::uint32_t addRef() = 0;
  virtual std::uint32_t release() = 0;
};

class IPluginFactory : public FUnknown {
 public:
  virtual std::int32_t getFactoryInfo(PFactoryInfo* info) = 0;
  virtual std::int32_t countClasses() = 0;
  virtual std::int32_t getClassInfo(std::int32_t index, PClassInfo* info) = 0;
  virtual std::int32_t createInstance(FIDString cid, FIDString iid,
                                      void** object) = 0;
};

class IPluginFactory2 {
 public:
  virtual std::int32_t queryInterface(const TUID iid, void** object) = 0;
  virtual std::uint32_t addRef() = 0;
  virtual std::uint32_t release() = 0;
  virtual std::int32_t getFactoryInfo(PFactoryInfo* info) = 0;
  virtual std::int32_t countClasses() = 0;
  virtual std::int32_t getClassInfo(std::int32_t index, PClassInfo* info) = 0;
  virtual std::int32_t createInstance(FIDString cid, FIDString iid,
                                      void** object) = 0;
  virtual std::int32_t getClassInfo2(std::int32_t index, PClassInfo2* info) = 0;
};

class IPluginFactory3 {
 public:
  virtual std::int32_t queryInterface(const TUID iid, void** object) = 0;
  virtual std::uint32_t addRef() = 0;
  virtual std::uint32_t release() = 0;
  virtual std::int32_t getFactoryInfo(PFactoryInfo* info) = 0;
  virtual std::int32_t countClasses() = 0;
  virtual std::int32_t getClassInfo(std::int32_t index, PClassInfo* info) = 0;
  virtual std::int32_t createInstance(FIDString cid, FIDString iid,
                                      void** object) = 0;
  virtual std::int32_t getClassInfo2(std::int32_t index, PClassInfo2* info) = 0;
  virtual std::int32_t getClassInfoUnicode(std::int32_t index,
                                            PClassInfoW* info) = 0;
  virtual std::int32_t setHostContext(FUnknown* context) = 0;
};

static const std::int8_t kFactoryIid[16] = {
    0x7A, 0x4D, static_cast<std::int8_t>(0x81), 0x1C,
    0x52, 0x11, 0x4A, 0x1F,
    static_cast<std::int8_t>(0xAE), static_cast<std::int8_t>(0xD9),
    static_cast<std::int8_t>(0xD2), static_cast<std::int8_t>(0xEE),
    0x0B, 0x43, static_cast<std::int8_t>(0xBF), static_cast<std::int8_t>(0x9F)};
static const std::int8_t kFactory2Iid[16] = {
    0x00, 0x07, static_cast<std::int8_t>(0xB6), 0x50,
    static_cast<std::int8_t>(0xF2), 0x4B, 0x4C, 0x0B,
    static_cast<std::int8_t>(0xA4), 0x64, static_cast<std::int8_t>(0xED),
    static_cast<std::int8_t>(0xB9), static_cast<std::int8_t>(0xF0),
    0x0B, 0x2A, static_cast<std::int8_t>(0xBB)};
static const std::int8_t kFactory3Iid[16] = {
    0x45, 0x55, static_cast<std::int8_t>(0xA2), static_cast<std::int8_t>(0xAB),
    static_cast<std::int8_t>(0xC1), 0x23, 0x4E, 0x57,
    static_cast<std::int8_t>(0x9B), 0x12, 0x29, 0x10,
    0x36, static_cast<std::int8_t>(0x87), static_cast<std::int8_t>(0x89), 0x31};
static const std::int8_t kClassId[16] = {
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    static_cast<std::int8_t>(0x88), static_cast<std::int8_t>(0x99),
    static_cast<std::int8_t>(0xAA), static_cast<std::int8_t>(0xBB),
    static_cast<std::int8_t>(0xCC), static_cast<std::int8_t>(0xDD),
    static_cast<std::int8_t>(0xEE), static_cast<std::int8_t>(0xFF)};
static const std::int8_t kClassId2[16] = {
    0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, static_cast<std::int8_t>(0x87),
    static_cast<std::int8_t>(0x98), static_cast<std::int8_t>(0xA9),
    static_cast<std::int8_t>(0xBA), static_cast<std::int8_t>(0xCB),
    static_cast<std::int8_t>(0xDC), static_cast<std::int8_t>(0xED),
    static_cast<std::int8_t>(0xFE), 0x0F};

static std::uint32_t g_entry_calls = 0;
static std::uint32_t g_exit_calls = 0;
static std::uint32_t g_factory_get_calls = 0;
static std::uint32_t g_factory_query_calls = 0;
static std::uint32_t g_factory_v2_query_calls = 0;
static std::uint32_t g_factory_v3_query_calls = 0;
static std::uint32_t g_factory_release_calls = 0;
static std::uint32_t g_factory_info_calls = 0;
static std::uint32_t g_class_count_calls = 0;
static std::uint32_t g_class_info_calls = 0;
static std::uint32_t g_class_info2_calls = 0;
static std::uint32_t g_host_context_calls = 0;
static std::uint32_t g_create_calls = 0;
static std::uint32_t g_refs = 1;
static std::uint64_t g_sequence = 0;
static std::uint64_t g_last_release_sequence = 0;
static std::uint64_t g_last_exit_sequence = 0;

static bool equalIid(const TUID iid, const std::int8_t* expected) {
  return std::memcmp(iid, expected, sizeof(TUID)) == 0;
}

static void markRelease() {
  ++g_factory_release_calls;
  g_last_release_sequence = ++g_sequence;
  if (g_refs > 0)
    --g_refs;
}

static void resetLedger() {
  g_create_calls = 0;
  g_entry_calls = 0;
  g_exit_calls = 0;
  g_factory_get_calls = 0;
  g_factory_query_calls = 0;
  g_factory_v2_query_calls = 0;
  g_factory_v3_query_calls = 0;
  g_factory_release_calls = 0;
  g_factory_info_calls = 0;
  g_class_count_calls = 0;
  g_class_info_calls = 0;
  g_class_info2_calls = 0;
  g_host_context_calls = 0;
  g_refs = 1;
  g_sequence = 0;
  g_last_release_sequence = 0;
  g_last_exit_sequence = 0;
}

class FixtureFactory;

class FactoryV2 final : public IPluginFactory2 {
 public:
  explicit FactoryV2(FixtureFactory* owner) : owner_(owner) {}
  std::int32_t queryInterface(const TUID iid, void** object) override;
  std::uint32_t addRef() override;
  std::uint32_t release() override;
  std::int32_t getFactoryInfo(PFactoryInfo* info) override;
  std::int32_t countClasses() override;
  std::int32_t getClassInfo(std::int32_t index, PClassInfo* info) override;
  std::int32_t createInstance(FIDString cid, FIDString iid,
                              void** object) override;
  std::int32_t getClassInfo2(std::int32_t index, PClassInfo2* info) override;
 private:
  FixtureFactory* owner_;
};

class FactoryV3 final : public IPluginFactory3 {
 public:
  explicit FactoryV3(FixtureFactory* owner) : owner_(owner) {}
  std::int32_t queryInterface(const TUID iid, void** object) override;
  std::uint32_t addRef() override;
  std::uint32_t release() override;
  std::int32_t getFactoryInfo(PFactoryInfo* info) override;
  std::int32_t countClasses() override;
  std::int32_t getClassInfo(std::int32_t index, PClassInfo* info) override;
  std::int32_t createInstance(FIDString cid, FIDString iid,
                              void** object) override;
  std::int32_t getClassInfo2(std::int32_t index, PClassInfo2* info) override;
  std::int32_t getClassInfoUnicode(std::int32_t, PClassInfoW*) override;
  std::int32_t setHostContext(FUnknown* context) override;
 private:
  FixtureFactory* owner_;
};

class FixtureFactory final : public IPluginFactory {
 public:
  FixtureFactory() : v2(this), v3(this) {}

  std::int32_t queryInterface(const TUID iid, void** object) override {
    ++g_factory_query_calls;
    if (object == nullptr)
      return -2;
    *object = nullptr;
#if PLUGINHOST_VST3_FIXTURE_MODE == 7
    if (equalIid(iid, kFactory3Iid))
      return -42;
#endif
#if PLUGINHOST_VST3_FIXTURE_MODE == 8
    if (equalIid(iid, kFactory3Iid))
      return 0;
#endif
    if (equalIid(iid, kFactory3Iid)) {
      ++g_factory_v3_query_calls;
#if PLUGINHOST_VST3_FIXTURE_MODE != 5 && PLUGINHOST_VST3_FIXTURE_MODE != 6
      *object = &v3;
      ++g_refs;
      return 0;
#else
      return -1;
#endif
    }
    if (equalIid(iid, kFactory2Iid)) {
      ++g_factory_v2_query_calls;
#if PLUGINHOST_VST3_FIXTURE_MODE == 5
      *object = &v2;
      ++g_refs;
      return 0;
#else
      return -1;
#endif
    }
    if (equalIid(iid, kFactoryIid)) {
      *object = this;
      ++g_refs;
      return 0;
    }
    return -1;
  }

  std::uint32_t addRef() override { return ++g_refs; }
  std::uint32_t release() override {
    markRelease();
    return g_refs;
  }

  std::int32_t getFactoryInfo(PFactoryInfo* info) override {
    ++g_factory_info_calls;
    if (info == nullptr)
      return -2;
#if PLUGINHOST_VST3_FIXTURE_MODE == 9
    return -42;
#endif
    std::memset(info, 0, sizeof(*info));
#if PLUGINHOST_VST3_FIXTURE_MODE == 18
    std::memcpy(info->vendor, "V\xc3\xa4ndor \xe2\x9c\x93", 11);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 12
    std::memset(info->vendor, 'X', sizeof(info->vendor));
#else
    std::memcpy(info->vendor, "pluginhost VST3 fixture", 23);
#endif
    std::memcpy(info->url, "https://example.invalid/pluginhost", 34);
    std::memcpy(info->email, "fixture@example.invalid", 23);
    return 0;
  }

  std::int32_t countClasses() override {
    ++g_class_count_calls;
#if PLUGINHOST_VST3_FIXTURE_MODE == 10
    return -1;
#elif PLUGINHOST_VST3_FIXTURE_MODE == 11
    return 4097;
#elif PLUGINHOST_VST3_FIXTURE_MODE == 15
    return 3;
#elif PLUGINHOST_VST3_FIXTURE_MODE == 17
    return 2;
#else
    return 1;
#endif
  }

  std::int32_t getClassInfo(std::int32_t index, PClassInfo* info) override {
    ++g_class_info_calls;
    if (info == nullptr)
      return -2;
#if PLUGINHOST_VST3_FIXTURE_MODE == 15
    if (index < 0 || index >= 3)
      return -2;
#elif PLUGINHOST_VST3_FIXTURE_MODE == 17
    if (index < 0 || index >= 2)
      return -2;
#else
    if (index != 0)
      return -2;
#endif
    std::memset(info, 0, sizeof(*info));
#if PLUGINHOST_VST3_FIXTURE_MODE == 17
    std::memcpy(info->cid, kClassId, sizeof(TUID));
#elif PLUGINHOST_VST3_FIXTURE_MODE == 15
    if (index == 1)
      std::memcpy(info->cid, kClassId, sizeof(TUID));
    else if (index == 2)
      std::memcpy(info->cid, kClassId2, sizeof(TUID));
    else
      std::memcpy(info->cid, kClassId, sizeof(TUID));
#else
    std::memcpy(info->cid, kClassId, sizeof(TUID));
#endif
#if PLUGINHOST_VST3_FIXTURE_MODE == 21
    std::memcpy(info->category, "AudioEffectClass", 16);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 16
    std::memcpy(info->category, "Controller", 10);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 15
    if (index == 1)
      std::memcpy(info->category, "Controller", 10);
    else
      std::memcpy(info->category, "Audio Module Class", 18);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 13
    std::memset(info->category, 'Q', sizeof(info->category));
#else
    std::memcpy(info->category, "Audio Module Class", 18);
#endif
#if PLUGINHOST_VST3_FIXTURE_MODE == 15
    if (index == 1)
      std::memcpy(info->name, "Fixture Controller", 19);
    else if (index == 2)
      std::memcpy(info->name, "Fixture Effect Two", 19);
    else
      std::memcpy(info->name, "Fixture Effect One", 19);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 16
    std::memcpy(info->name, "Fixture Controller", 19);
#else
    std::memcpy(info->name, "V1A Fixture", 11);
#endif
    return 0;
  }

  std::int32_t createInstance(FIDString, FIDString, void** object) override {
    ++g_create_calls;
    if (object != nullptr)
      *object = nullptr;
    return -1;
  }

  std::int32_t getFactoryInfo2(PFactoryInfo* info) { return getFactoryInfo(info); }
  std::int32_t countClasses2() { return countClasses(); }
  std::int32_t getClassInfo2(std::int32_t index, PClassInfo* info) {
    return getClassInfo(index, info);
  }

  std::int32_t fillClassInfo2(std::int32_t index, PClassInfo2* info) {
    ++g_class_info2_calls;
    if (info == nullptr)
      return -2;
#if PLUGINHOST_VST3_FIXTURE_MODE == 15
    if (index < 0 || index >= 3)
      return -2;
#elif PLUGINHOST_VST3_FIXTURE_MODE == 17
    if (index < 0 || index >= 2)
      return -2;
#else
    if (index != 0)
      return -2;
#endif
    std::memset(info, 0, sizeof(*info));
#if PLUGINHOST_VST3_FIXTURE_MODE == 15
    if (index == 2)
      std::memcpy(info->cid, kClassId2, sizeof(TUID));
    else
      std::memcpy(info->cid, kClassId, sizeof(TUID));
#else
    std::memcpy(info->cid, kClassId, sizeof(TUID));
#endif
    info->classFlags = 0;
#if PLUGINHOST_VST3_FIXTURE_MODE == 21
    std::memcpy(info->category, "AudioEffectClass", 16);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 16
    std::memcpy(info->category, "Controller", 10);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 15
    if (index == 1)
      std::memcpy(info->category, "Controller", 10);
    else
      std::memcpy(info->category, "Audio Module Class", 18);
#else
    std::memcpy(info->category, "Audio Module Class", 18);
#endif
#if PLUGINHOST_VST3_FIXTURE_MODE == 15
    if (index == 1)
      std::memcpy(info->name, "Fixture Controller", 19);
    else if (index == 2)
      std::memcpy(info->name, "Fixture Effect Two", 19);
    else
      std::memcpy(info->name, "Fixture Effect One", 19);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 16
    std::memcpy(info->name, "Fixture Controller", 19);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 18
    std::memcpy(info->name, "S\xc3\xbcn", 4);
#else
    std::memcpy(info->name, "V1A Fixture", 11);
#endif
#if PLUGINHOST_VST3_FIXTURE_MODE == 15 || PLUGINHOST_VST3_FIXTURE_MODE == 18
    std::memcpy(info->subCategories, "Fx|Instrument", 13);
#else
    std::memcpy(info->subCategories, "Fx", 2);
#endif
#if PLUGINHOST_VST3_FIXTURE_MODE == 18
    std::memcpy(info->vendor, "V\xc3\xa4ndor \xe2\x9c\x93", 11);
    std::memcpy(info->version, "2.0-\xc3\xbc", 7);
#elif PLUGINHOST_VST3_FIXTURE_MODE == 20
    info->vendor[0] = static_cast<char>(0xFF);
    std::memcpy(info->version, "1.0", 4);
#else
    std::memcpy(info->vendor, "pluginhost", 10);
    std::memcpy(info->version, "1.0", 4);
#endif
    std::memcpy(info->sdkVersion, "3.8.1", 6);
#if PLUGINHOST_VST3_FIXTURE_MODE == 13
    std::memset(info->subCategories, 'Q', sizeof(info->subCategories));
#endif
    return 0;
  }

  std::int32_t fillClassInfoUnicode(std::int32_t index, PClassInfoW* info) {
    (void)index;
    (void)info;
#if PLUGINHOST_VST3_FIXTURE_MODE == 18 || PLUGINHOST_VST3_FIXTURE_MODE == 19 || \
    PLUGINHOST_VST3_FIXTURE_MODE == 21
    if (index != 0 || info == nullptr)
      return -2;
    std::memset(info, 0, sizeof(*info));
    std::memcpy(info->cid, kClassId, sizeof(TUID));
#if PLUGINHOST_VST3_FIXTURE_MODE == 21
    std::memcpy(info->category, "AudioEffectClass", 16);
#else
    std::memcpy(info->category, "Audio Module Class", 18);
#endif
    info->name[0] = 'S';
#if PLUGINHOST_VST3_FIXTURE_MODE == 19
    info->name[0] = 0xD800;
#else
    info->name[1] = 0x00FC;
    info->name[2] = 'n';
#endif
    std::memcpy(info->subCategories, "Fx", 2);
    info->vendor[0] = 'V';
    info->vendor[1] = 0x00E4;
    info->vendor[2] = 'n';
    info->vendor[3] = 'd';
    info->vendor[4] = 'o';
    info->vendor[5] = 'r';
    info->vendor[6] = ' ';
    info->vendor[7] = 0x2713;
    info->version[0] = '2';
    info->version[1] = '.';
    info->version[2] = '0';
    info->version[3] = '-';
    info->version[4] = 0x00FC;
    std::memcpy(info->sdkVersion, "3.8.1", 6);
    return 0;
#else
    return -1;
#endif
  }

  std::int32_t setHostContext(FUnknown* context) {
    ++g_host_context_calls;
    if (context == nullptr)
      return -2;
    void* object = nullptr;
    const std::int32_t result = context->queryInterface(kFactoryIid, &object);
    const std::uint32_t retained = context->addRef();
    const std::uint32_t released = context->release();
#if PLUGINHOST_VST3_FIXTURE_MODE == 14
    return -42;
#else
    return result == -1 && object == nullptr && retained > 0 && released > 0 ? 0 : -2;
#endif
  }

  FactoryV2 v2;
  FactoryV3 v3;
};

std::int32_t FactoryV2::queryInterface(const TUID iid, void** object) {
  return owner_->queryInterface(iid, object);
}
std::uint32_t FactoryV2::addRef() { return owner_->addRef(); }
std::uint32_t FactoryV2::release() { return owner_->release(); }
std::int32_t FactoryV2::getFactoryInfo(PFactoryInfo* info) {
  return owner_->getFactoryInfo2(info);
}
std::int32_t FactoryV2::countClasses() { return owner_->countClasses2(); }
std::int32_t FactoryV2::getClassInfo(std::int32_t index, PClassInfo* info) {
  return owner_->getClassInfo2(index, info);
}
std::int32_t FactoryV2::createInstance(FIDString cid, FIDString iid,
                                       void** object) {
  return owner_->createInstance(cid, iid, object);
}
std::int32_t FactoryV2::getClassInfo2(std::int32_t index, PClassInfo2* info) {
  return owner_->fillClassInfo2(index, info);
}

std::int32_t FactoryV3::queryInterface(const TUID iid, void** object) {
  return owner_->queryInterface(iid, object);
}
std::uint32_t FactoryV3::addRef() { return owner_->addRef(); }
std::uint32_t FactoryV3::release() { return owner_->release(); }
std::int32_t FactoryV3::getFactoryInfo(PFactoryInfo* info) {
  return owner_->getFactoryInfo(info);
}
std::int32_t FactoryV3::countClasses() { return owner_->countClasses(); }
std::int32_t FactoryV3::getClassInfo(std::int32_t index, PClassInfo* info) {
  return owner_->getClassInfo(index, info);
}
std::int32_t FactoryV3::createInstance(FIDString cid, FIDString iid,
                                       void** object) {
  return owner_->createInstance(cid, iid, object);
}
std::int32_t FactoryV3::getClassInfo2(std::int32_t index, PClassInfo2* info) {
  return owner_->fillClassInfo2(index, info);
}
std::int32_t FactoryV3::getClassInfoUnicode(std::int32_t index,
                                             PClassInfoW* info) {
  return owner_->fillClassInfoUnicode(index, info);
}
std::int32_t FactoryV3::setHostContext(FUnknown* context) {
  return owner_->setHostContext(context);
}

static FixtureFactory g_factory;

extern "C" __attribute__((visibility("default"))) bool ModuleEntry(void*) {
  resetLedger();
  ++g_entry_calls;
#if PLUGINHOST_VST3_FIXTURE_MODE == 1
  return false;
#else
  return true;
#endif
}

#if PLUGINHOST_VST3_FIXTURE_MODE != 2
extern "C" __attribute__((visibility("default"))) bool ModuleExit() {
  ++g_exit_calls;
  g_last_exit_sequence = ++g_sequence;
  return true;
}
#endif

#if PLUGINHOST_VST3_FIXTURE_MODE != 3
extern "C" __attribute__((visibility("default"))) IPluginFactory* GetPluginFactory() {
  ++g_factory_get_calls;
#if PLUGINHOST_VST3_FIXTURE_MODE == 4
  return nullptr;
#else
  return &g_factory;
#endif
}
#endif

extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_entry_calls() { return g_entry_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_exit_calls() { return g_exit_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_factory_get_calls() { return g_factory_get_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_factory_query_calls() { return g_factory_query_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_factory_v2_query_calls() { return g_factory_v2_query_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_factory_v3_query_calls() { return g_factory_v3_query_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_factory_release_calls() { return g_factory_release_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_factory_info_calls() { return g_factory_info_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_class_count_calls() { return g_class_count_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_class_info_calls() { return g_class_info_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_class_info2_calls() { return g_class_info2_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_host_context_calls() { return g_host_context_calls; }
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_refs() { return g_refs; }
extern "C" __attribute__((visibility("default"))) std::uint64_t
pluginhost_vst3_fixture_last_release_sequence() { return g_last_release_sequence; }
extern "C" __attribute__((visibility("default"))) std::uint64_t
pluginhost_vst3_fixture_last_exit_sequence() { return g_last_exit_sequence; }
extern "C" __attribute__((visibility("default"))) std::uintptr_t
pluginhost_vst3_fixture_base_address() {
  return reinterpret_cast<std::uintptr_t>(static_cast<IPluginFactory*>(&g_factory));
}
extern "C" __attribute__((visibility("default"))) std::uintptr_t
pluginhost_vst3_fixture_v2_address() {
  return reinterpret_cast<std::uintptr_t>(&g_factory.v2);
}
extern "C" __attribute__((visibility("default"))) std::uintptr_t
pluginhost_vst3_fixture_v3_address() {
  return reinterpret_cast<std::uintptr_t>(&g_factory.v3);
}
extern "C" __attribute__((visibility("default"))) std::uint32_t
pluginhost_vst3_fixture_create_calls() { return g_create_calls; }
