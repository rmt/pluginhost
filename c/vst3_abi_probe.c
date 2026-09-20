#include <stddef.h>
#include <stdint.h>

#include "vst3/vst3_c_api.h"

_Static_assert(sizeof(Steinberg_TUID) == 16, "unexpected VST3 TUID size");
_Static_assert(sizeof(struct Steinberg_PFactoryInfo) == 452,
               "unexpected VST3 factory-info size");
_Static_assert(sizeof(struct Steinberg_PClassInfo) == 116,
               "unexpected VST3 class-info size");
_Static_assert(sizeof(struct Steinberg_PClassInfo2) == 440,
               "unexpected VST3 class-info2 size");
_Static_assert(sizeof(struct Steinberg_PClassInfoW) == 696,
               "unexpected VST3 wide class-info size");
_Static_assert(sizeof(struct Steinberg_FUnknownVtbl) == 24,
               "unexpected VST3 FUnknown-vtable size");
_Static_assert(sizeof(struct Steinberg_IPluginFactoryVtbl) == 56,
               "unexpected VST3 factory-vtable size");
_Static_assert(sizeof(struct Steinberg_IPluginFactory2Vtbl) == 64,
               "unexpected VST3 factory2-vtable size");
_Static_assert(sizeof(struct Steinberg_IPluginFactory3Vtbl) == 80,
               "unexpected VST3 factory3-vtable size");
typedef Steinberg_TBool (*pluginhost_vst3_module_entry_t)(void *);
_Static_assert(sizeof(pluginhost_vst3_module_entry_t) == sizeof(void *),
               "unexpected VST3 ModuleEntry function-pointer size");

#define ABI_FIELD_ID(type_id, field_id) ((type_id) * 100 + (field_id))
#define ABI_FIELD_CASE(type_id, field_id, type_name, field_name) \
   case ABI_FIELD_ID(type_id, field_id): return (uint64_t)offsetof(type_name, field_name)

uint64_t pluginhost_vst3_abi_size(int32_t type_id) {
   switch (type_id) {
      case 401: return sizeof(Steinberg_TUID);
      case 402: return sizeof(struct Steinberg_PFactoryInfo);
      case 403: return sizeof(struct Steinberg_PClassInfo);
      case 404: return sizeof(struct Steinberg_PClassInfo2);
      case 405: return sizeof(struct Steinberg_PClassInfoW);
      case 406: return sizeof(struct Steinberg_IPluginFactoryVtbl);
      case 407: return sizeof(struct Steinberg_FUnknownVtbl);
      case 408: return sizeof(struct Steinberg_IPluginFactory2Vtbl);
      case 409: return sizeof(struct Steinberg_IPluginFactory3Vtbl);
      default: return 0;
   }
}

uint64_t pluginhost_vst3_abi_align(int32_t type_id) {
   switch (type_id) {
      case 401: return _Alignof(Steinberg_TUID);
      case 402: return _Alignof(struct Steinberg_PFactoryInfo);
      case 403: return _Alignof(struct Steinberg_PClassInfo);
      case 404: return _Alignof(struct Steinberg_PClassInfo2);
      case 405: return _Alignof(struct Steinberg_PClassInfoW);
      case 406: return _Alignof(struct Steinberg_IPluginFactoryVtbl);
      case 407: return _Alignof(struct Steinberg_FUnknownVtbl);
      case 408: return _Alignof(struct Steinberg_IPluginFactory2Vtbl);
      case 409: return _Alignof(struct Steinberg_IPluginFactory3Vtbl);
      default: return 0;
   }
}

uint64_t pluginhost_vst3_abi_offset(int32_t field_id) {
   switch (field_id) {
      ABI_FIELD_CASE(402, 1, struct Steinberg_PFactoryInfo, vendor);
      ABI_FIELD_CASE(402, 2, struct Steinberg_PFactoryInfo, url);
      ABI_FIELD_CASE(402, 3, struct Steinberg_PFactoryInfo, email);
      ABI_FIELD_CASE(402, 4, struct Steinberg_PFactoryInfo, flags);
      ABI_FIELD_CASE(403, 1, struct Steinberg_PClassInfo, cid);
      ABI_FIELD_CASE(403, 2, struct Steinberg_PClassInfo, cardinality);
      ABI_FIELD_CASE(403, 3, struct Steinberg_PClassInfo, category);
      ABI_FIELD_CASE(403, 4, struct Steinberg_PClassInfo, name);
      ABI_FIELD_CASE(404, 1, struct Steinberg_PClassInfo2, classFlags);
      ABI_FIELD_CASE(404, 2, struct Steinberg_PClassInfo2, subCategories);
      ABI_FIELD_CASE(404, 3, struct Steinberg_PClassInfo2, vendor);
      ABI_FIELD_CASE(405, 1, struct Steinberg_PClassInfoW, name);
      ABI_FIELD_CASE(405, 2, struct Steinberg_PClassInfoW, classFlags);
      ABI_FIELD_CASE(406, 1, struct Steinberg_IPluginFactoryVtbl, queryInterface);
      ABI_FIELD_CASE(406, 2, struct Steinberg_IPluginFactoryVtbl, getFactoryInfo);
      ABI_FIELD_CASE(406, 3, struct Steinberg_IPluginFactoryVtbl, countClasses);
      ABI_FIELD_CASE(406, 4, struct Steinberg_IPluginFactoryVtbl, createInstance);
      default: return UINT64_MAX;
   }
}

uint64_t pluginhost_vst3_abi_uid_byte(int32_t index) {
   if (index < 0 || index >= 16)
      return UINT64_MAX;
   return (uint8_t)Steinberg_IPluginFactory_iid[index];
}
