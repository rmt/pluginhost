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


uint64_t pluginhost_vst3_linux_result_values(void) {
   return ((uint64_t)(uint32_t)Steinberg_kNoInterface << 32) |
          ((uint64_t)(uint32_t)Steinberg_kResultOk << 24) |
          ((uint64_t)(uint32_t)Steinberg_kResultFalse << 16) |
          ((uint64_t)(uint32_t)Steinberg_kInvalidArgument << 8) |
          (uint64_t)(uint32_t)Steinberg_kNotImplemented;
}

/* Export entrypoints are not declared by the C SDK header; these declarations
 * pin the Linux module ABI used by module.nim. */
typedef Steinberg_TBool (*pluginhost_module_entry_signature)(void *);
typedef Steinberg_TBool (*pluginhost_module_exit_signature)(void);
typedef Steinberg_IPluginFactory* (*pluginhost_get_factory_signature)(void);

typedef Steinberg_tresult (*pluginhost_query_signature)(
    void *, const Steinberg_TUID, void **);
typedef Steinberg_uint32 (*pluginhost_ref_signature)(void *);
typedef Steinberg_tresult (*pluginhost_component_initialize_signature)(
    void *, struct Steinberg_FUnknown *);
typedef Steinberg_tresult (*pluginhost_void_result_signature)(void *);
typedef Steinberg_tresult (*pluginhost_set_active_signature)(
    void *, Steinberg_TBool);
typedef Steinberg_tresult (*pluginhost_component_cid_signature)(
    void *, Steinberg_TUID);
typedef Steinberg_tresult (*pluginhost_io_mode_signature)(
    void *, Steinberg_Vst_IoMode);
typedef Steinberg_int32 (*pluginhost_bus_count_signature)(
    void *, Steinberg_Vst_MediaType, Steinberg_Vst_BusDirection);
typedef Steinberg_tresult (*pluginhost_bus_info_signature)(
    void *, Steinberg_Vst_MediaType, Steinberg_Vst_BusDirection,
    Steinberg_int32, struct Steinberg_Vst_BusInfo *);
typedef Steinberg_tresult (*pluginhost_routing_signature)(
    void *, struct Steinberg_Vst_RoutingInfo *,
    struct Steinberg_Vst_RoutingInfo *);
typedef Steinberg_tresult (*pluginhost_activate_bus_signature)(
    void *, Steinberg_Vst_MediaType, Steinberg_Vst_BusDirection,
    Steinberg_int32, Steinberg_TBool);
typedef Steinberg_tresult (*pluginhost_state_signature)(
    void *, struct Steinberg_IBStream *);
typedef Steinberg_tresult (*pluginhost_set_arrangements_signature)(
    void *, Steinberg_Vst_SpeakerArrangement *, Steinberg_int32,
    Steinberg_Vst_SpeakerArrangement *, Steinberg_int32);
typedef Steinberg_tresult (*pluginhost_component_handler_signature)(
    void *, struct Steinberg_Vst_IComponentHandler *);
typedef Steinberg_tresult (*pluginhost_controller_parameter_info_signature)(
    void *, Steinberg_int32, struct Steinberg_Vst_ParameterInfo *);
typedef Steinberg_tresult (*pluginhost_controller_param_string_signature)(
    void *, Steinberg_Vst_ParamID, Steinberg_Vst_ParamValue,
    Steinberg_Vst_String128);
typedef Steinberg_tresult (*pluginhost_controller_param_value_signature)(
    void *, Steinberg_Vst_ParamID, Steinberg_Vst_TChar *,
    Steinberg_Vst_ParamValue *);
typedef Steinberg_Vst_ParamValue (*pluginhost_controller_param_convert_signature)(
    void *, Steinberg_Vst_ParamID, Steinberg_Vst_ParamValue);
typedef Steinberg_Vst_ParamValue (*pluginhost_controller_param_get_signature)(
    void *, Steinberg_Vst_ParamID);
typedef Steinberg_tresult (*pluginhost_connection_signature)(
    void *, struct Steinberg_Vst_IConnectionPoint *);
typedef Steinberg_tresult (*pluginhost_notify_signature)(
    void *, struct Steinberg_Vst_IMessage *);
typedef Steinberg_tresult (*pluginhost_host_name_signature)(
    void *, Steinberg_Vst_String128);
typedef Steinberg_tresult (*pluginhost_host_instance_signature)(
    void *, Steinberg_TUID, Steinberg_TUID, void **);
typedef Steinberg_tresult (*pluginhost_runloop_unregister_fd_signature)(
    void *, struct Steinberg_Linux_IEventHandler *);
typedef Steinberg_tresult (*pluginhost_runloop_unregister_timer_signature)(
    void *, struct Steinberg_Linux_ITimerHandler *);
typedef Steinberg_tresult (*pluginhost_runloop_fd_signature)(
    void *, struct Steinberg_Linux_IEventHandler *,
    Steinberg_Linux_FileDescriptor);
typedef Steinberg_tresult (*pluginhost_runloop_timer_signature)(
    void *, struct Steinberg_Linux_ITimerHandler *,
    Steinberg_Linux_TimerInterval);
typedef Steinberg_tresult (*pluginhost_stream_read_signature)(
    void *, void *, Steinberg_int32, Steinberg_int32 *);
typedef Steinberg_tresult (*pluginhost_stream_seek_signature)(
    void *, Steinberg_int64, Steinberg_int32, Steinberg_int64 *);
typedef Steinberg_tresult (*pluginhost_attr_int_signature)(
    void *, Steinberg_Vst_IAttributeList_AttrID, Steinberg_int64);
typedef Steinberg_tresult (*pluginhost_attr_get_int_signature)(
    void *, Steinberg_Vst_IAttributeList_AttrID, Steinberg_int64 *);
typedef Steinberg_tresult (*pluginhost_attr_float_signature)(
    void *, Steinberg_Vst_IAttributeList_AttrID, double);
typedef Steinberg_tresult (*pluginhost_attr_get_float_signature)(
    void *, Steinberg_Vst_IAttributeList_AttrID, double *);
typedef Steinberg_tresult (*pluginhost_attr_string_signature)(
    void *, Steinberg_Vst_IAttributeList_AttrID,
    const Steinberg_Vst_TChar *);
typedef Steinberg_tresult (*pluginhost_attr_get_string_signature)(
    void *, Steinberg_Vst_IAttributeList_AttrID, Steinberg_Vst_TChar *,
    Steinberg_uint32);
typedef Steinberg_tresult (*pluginhost_attr_binary_signature)(
    void *, Steinberg_Vst_IAttributeList_AttrID, const void *,
    Steinberg_uint32);
typedef Steinberg_tresult (*pluginhost_attr_get_binary_signature)(
    void *, Steinberg_Vst_IAttributeList_AttrID, const void **,
    Steinberg_uint32 *);
typedef Steinberg_FIDString (*pluginhost_message_get_id_signature)(void *);
typedef void (*pluginhost_message_set_id_signature)(
    void *, Steinberg_FIDString);
typedef struct Steinberg_Vst_IAttributeList *(*pluginhost_message_attrs_signature)(void *);
typedef Steinberg_tresult (*pluginhost_handler_edit_signature)(
    void *, Steinberg_Vst_ParamID, Steinberg_Vst_ParamValue);
typedef Steinberg_tresult (*pluginhost_handler_gesture_signature)(
    void *, Steinberg_Vst_ParamID);
typedef Steinberg_tresult (*pluginhost_handler_end_signature)(
    void *, Steinberg_Vst_ParamID);
typedef Steinberg_tresult (*pluginhost_handler_restart_signature)(
    void *, Steinberg_int32);
typedef Steinberg_tresult (*pluginhost_processor_setup_signature)(
    void *, struct Steinberg_Vst_ProcessSetup *);
typedef Steinberg_tresult (*pluginhost_processor_process_signature)(
    void *, struct Steinberg_Vst_ProcessData *);
typedef Steinberg_tresult (*pluginhost_processor_sample_signature)(
    void *, Steinberg_int32);
typedef Steinberg_uint32 (*pluginhost_processor_u32_signature)(void *);

static void pluginhost_vst3_check_callback_signatures(void) __attribute__((unused));
static void pluginhost_vst3_check_callback_signatures(void) {
   struct Steinberg_Vst_IAudioProcessorVtbl *processor = 0;
   struct Steinberg_Vst_IComponentVtbl *component = 0;
   struct Steinberg_Vst_IEditControllerVtbl *controller = 0;
   struct Steinberg_Vst_IConnectionPointVtbl *connection = 0;
   struct Steinberg_Vst_IHostApplicationVtbl *host = 0;
   struct Steinberg_Linux_IRunLoopVtbl *runloop = 0;
   struct Steinberg_IBStreamVtbl *stream = 0;
   struct Steinberg_Vst_IAttributeListVtbl *attributes = 0;
   struct Steinberg_Vst_IMessageVtbl *message = 0;
   struct Steinberg_Vst_IComponentHandlerVtbl *handler = 0;
   pluginhost_module_entry_signature me = 0;
   pluginhost_module_exit_signature mx = 0;
   pluginhost_component_initialize_signature ci = component->initialize;
   pluginhost_get_factory_signature gf = 0;
   pluginhost_query_signature q = component->queryInterface;
   pluginhost_ref_signature ar = component->addRef;
   pluginhost_ref_signature rr = component->release;
   pluginhost_component_cid_signature cc = component->getControllerClassId;
   pluginhost_io_mode_signature io = component->setIoMode;
   pluginhost_bus_count_signature bc = component->getBusCount;
   pluginhost_bus_info_signature bi = component->getBusInfo;
   pluginhost_routing_signature ri = component->getRoutingInfo;
   pluginhost_activate_bus_signature ab = component->activateBus;
   pluginhost_void_result_signature ct = component->terminate;
   pluginhost_set_active_signature sa = component->setActive;
   pluginhost_state_signature ss = component->setState;
   pluginhost_state_signature gs = component->getState;
   pluginhost_set_arrangements_signature ba = processor->setBusArrangements;
   pluginhost_processor_setup_signature ps = processor->setupProcessing;
   pluginhost_processor_process_signature pp = processor->process;
   pluginhost_processor_sample_signature pcs = processor->canProcessSampleSize;
   pluginhost_processor_u32_signature plu = processor->getLatencySamples;
   pluginhost_processor_u32_signature ptu = processor->getTailSamples;
   pluginhost_component_handler_signature sh = controller->setComponentHandler;
   pluginhost_state_signature cs = controller->setComponentState;
   pluginhost_controller_parameter_info_signature pi = controller->getParameterInfo;
   pluginhost_controller_param_string_signature psv = controller->getParamStringByValue;
   pluginhost_controller_param_value_signature pvs = controller->getParamValueByString;
   pluginhost_controller_param_convert_signature np = controller->normalizedParamToPlain;
   pluginhost_controller_param_convert_signature pn = controller->plainParamToNormalized;
   pluginhost_controller_param_get_signature pg = controller->getParamNormalized;
   pluginhost_connection_signature cn = connection->connect;
   pluginhost_connection_signature dc = connection->disconnect;
   pluginhost_notify_signature no = connection->notify;
   pluginhost_host_name_signature hn = host->getName;
   pluginhost_host_instance_signature hi = host->createInstance;
   pluginhost_runloop_fd_signature rf = runloop->registerEventHandler;
   pluginhost_runloop_unregister_fd_signature uf = runloop->unregisterEventHandler;
   pluginhost_runloop_timer_signature rt = runloop->registerTimer;
   pluginhost_runloop_unregister_timer_signature ut = runloop->unregisterTimer;
   pluginhost_stream_read_signature sr = stream->read;
   pluginhost_stream_read_signature sw = stream->write;
   pluginhost_stream_seek_signature sk = stream->seek;
   pluginhost_attr_int_signature asi = attributes->setInt;
   pluginhost_attr_get_int_signature agi = attributes->getInt;
   pluginhost_attr_float_signature asf = attributes->setFloat;
   pluginhost_attr_get_float_signature agf = attributes->getFloat;
   pluginhost_attr_string_signature ass = attributes->setString;
   pluginhost_attr_get_string_signature ags = attributes->getString;
   pluginhost_attr_binary_signature asb = attributes->setBinary;
   pluginhost_attr_get_binary_signature agb = attributes->getBinary;
   pluginhost_message_get_id_signature mgi = message->getMessageID;
   pluginhost_message_set_id_signature msi = message->setMessageID;
   pluginhost_handler_gesture_signature be = handler->beginEdit;
   pluginhost_message_attrs_signature mga = message->getAttributes;
   pluginhost_handler_edit_signature pe = handler->performEdit;
   pluginhost_handler_end_signature ee = handler->endEdit;
   pluginhost_handler_restart_signature rc = handler->restartComponent;
   (void)me; (void)mx; (void)gf; (void)q; (void)ar; (void)rr; (void)ci; (void)ct;
   (void)cc; (void)io; (void)bc; (void)bi; (void)ri; (void)ab; (void)sa;
   (void)ss; (void)gs; (void)ba; (void)ps; (void)pp; (void)pcs; (void)plu;
   (void)ptu; (void)sh; (void)cs; (void)pi; (void)psv; (void)pvs; (void)np;
   (void)pn; (void)pg; (void)cn; (void)dc; (void)no; (void)hn; (void)hi;
   (void)rf; (void)uf; (void)rt; (void)ut; (void)sr; (void)sw; (void)sk;
   (void)asi; (void)agi; (void)asf; (void)agf; (void)ass; (void)ags; (void)asb;
   (void)agb; (void)mgi; (void)msi; (void)mga; (void)be; (void)pe; (void)ee;
   (void)rc;
}
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
      case 410: return sizeof(struct Steinberg_Vst_BusInfo);
      case 411: return sizeof(struct Steinberg_Vst_ParameterInfo);
      case 412: return sizeof(struct Steinberg_Vst_IComponentVtbl);
      case 413: return sizeof(struct Steinberg_Vst_IEditControllerVtbl);
      case 414: return sizeof(struct Steinberg_Vst_IConnectionPointVtbl);
      case 415: return sizeof(struct Steinberg_Vst_IHostApplicationVtbl);
      case 416: return sizeof(struct Steinberg_Linux_IRunLoopVtbl);
      case 417: return sizeof(struct Steinberg_IBStreamVtbl);
      case 418: return sizeof(struct Steinberg_Vst_IAttributeListVtbl);
      case 419: return sizeof(struct Steinberg_Vst_IMessageVtbl);
      case 420: return sizeof(struct Steinberg_Vst_IComponentHandlerVtbl);
      case 421: return sizeof(struct Steinberg_Vst_IPlugInterfaceSupportVtbl);
      case 422: return sizeof(struct Steinberg_Vst_IAudioProcessorVtbl);
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
      case 410: return _Alignof(struct Steinberg_Vst_BusInfo);
      case 411: return _Alignof(struct Steinberg_Vst_ParameterInfo);
      case 412: return _Alignof(struct Steinberg_Vst_IComponentVtbl);
      case 413: return _Alignof(struct Steinberg_Vst_IEditControllerVtbl);
      case 414: return _Alignof(struct Steinberg_Vst_IConnectionPointVtbl);
      case 415: return _Alignof(struct Steinberg_Vst_IHostApplicationVtbl);
      case 416: return _Alignof(struct Steinberg_Linux_IRunLoopVtbl);
      case 417: return _Alignof(struct Steinberg_IBStreamVtbl);
      case 418: return _Alignof(struct Steinberg_Vst_IAttributeListVtbl);
      case 419: return _Alignof(struct Steinberg_Vst_IMessageVtbl);
      case 420: return _Alignof(struct Steinberg_Vst_IComponentHandlerVtbl);
      case 421: return _Alignof(struct Steinberg_Vst_IPlugInterfaceSupportVtbl);
      case 422: return _Alignof(struct Steinberg_Vst_IAudioProcessorVtbl);
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
      ABI_FIELD_CASE(410, 1, struct Steinberg_Vst_BusInfo, mediaType);
      ABI_FIELD_CASE(410, 2, struct Steinberg_Vst_BusInfo, name);
      ABI_FIELD_CASE(410, 3, struct Steinberg_Vst_BusInfo, flags);
      ABI_FIELD_CASE(411, 1, struct Steinberg_Vst_ParameterInfo, id);
      ABI_FIELD_CASE(411, 2, struct Steinberg_Vst_ParameterInfo, title);
      ABI_FIELD_CASE(411, 3, struct Steinberg_Vst_ParameterInfo, defaultNormalizedValue);
      ABI_FIELD_CASE(412, 1, struct Steinberg_Vst_IComponentVtbl, queryInterface);
      ABI_FIELD_CASE(412, 2, struct Steinberg_Vst_IComponentVtbl, addRef);
      ABI_FIELD_CASE(412, 3, struct Steinberg_Vst_IComponentVtbl, release);
      ABI_FIELD_CASE(412, 4, struct Steinberg_Vst_IComponentVtbl, initialize);
      ABI_FIELD_CASE(412, 5, struct Steinberg_Vst_IComponentVtbl, terminate);
      ABI_FIELD_CASE(412, 6, struct Steinberg_Vst_IComponentVtbl, getControllerClassId);
      ABI_FIELD_CASE(412, 7, struct Steinberg_Vst_IComponentVtbl, setIoMode);
      ABI_FIELD_CASE(412, 8, struct Steinberg_Vst_IComponentVtbl, getBusCount);
      ABI_FIELD_CASE(412, 9, struct Steinberg_Vst_IComponentVtbl, getBusInfo);
      ABI_FIELD_CASE(412, 10, struct Steinberg_Vst_IComponentVtbl, getRoutingInfo);
      ABI_FIELD_CASE(412, 11, struct Steinberg_Vst_IComponentVtbl, activateBus);
      ABI_FIELD_CASE(412, 12, struct Steinberg_Vst_IComponentVtbl, setActive);
      ABI_FIELD_CASE(412, 13, struct Steinberg_Vst_IComponentVtbl, setState);
      ABI_FIELD_CASE(412, 14, struct Steinberg_Vst_IComponentVtbl, getState);
      ABI_FIELD_CASE(413, 1, struct Steinberg_Vst_IEditControllerVtbl, queryInterface);
      ABI_FIELD_CASE(413, 2, struct Steinberg_Vst_IEditControllerVtbl, addRef);
      ABI_FIELD_CASE(413, 3, struct Steinberg_Vst_IEditControllerVtbl, release);
      ABI_FIELD_CASE(413, 4, struct Steinberg_Vst_IEditControllerVtbl, initialize);
      ABI_FIELD_CASE(413, 5, struct Steinberg_Vst_IEditControllerVtbl, terminate);
      ABI_FIELD_CASE(413, 6, struct Steinberg_Vst_IEditControllerVtbl, setComponentState);
      ABI_FIELD_CASE(413, 9, struct Steinberg_Vst_IEditControllerVtbl, getParameterCount);
      ABI_FIELD_CASE(413, 10, struct Steinberg_Vst_IEditControllerVtbl, getParameterInfo);
      ABI_FIELD_CASE(413, 17, struct Steinberg_Vst_IEditControllerVtbl, setComponentHandler);
      ABI_FIELD_CASE(414, 1, struct Steinberg_Vst_IConnectionPointVtbl, queryInterface);
      ABI_FIELD_CASE(414, 2, struct Steinberg_Vst_IConnectionPointVtbl, addRef);
      ABI_FIELD_CASE(414, 3, struct Steinberg_Vst_IConnectionPointVtbl, release);
      ABI_FIELD_CASE(414, 4, struct Steinberg_Vst_IConnectionPointVtbl, connect);
      ABI_FIELD_CASE(414, 5, struct Steinberg_Vst_IConnectionPointVtbl, disconnect);
      ABI_FIELD_CASE(414, 6, struct Steinberg_Vst_IConnectionPointVtbl, notify);
      ABI_FIELD_CASE(415, 1, struct Steinberg_Vst_IHostApplicationVtbl, queryInterface);
      ABI_FIELD_CASE(415, 2, struct Steinberg_Vst_IHostApplicationVtbl, addRef);
      ABI_FIELD_CASE(415, 3, struct Steinberg_Vst_IHostApplicationVtbl, release);
      ABI_FIELD_CASE(415, 4, struct Steinberg_Vst_IHostApplicationVtbl, getName);
      ABI_FIELD_CASE(415, 5, struct Steinberg_Vst_IHostApplicationVtbl, createInstance);
      ABI_FIELD_CASE(416, 1, struct Steinberg_Linux_IRunLoopVtbl, queryInterface);
      ABI_FIELD_CASE(416, 2, struct Steinberg_Linux_IRunLoopVtbl, addRef);
      ABI_FIELD_CASE(416, 3, struct Steinberg_Linux_IRunLoopVtbl, release);
      ABI_FIELD_CASE(416, 4, struct Steinberg_Linux_IRunLoopVtbl, registerEventHandler);
      ABI_FIELD_CASE(416, 5, struct Steinberg_Linux_IRunLoopVtbl, unregisterEventHandler);
      ABI_FIELD_CASE(416, 6, struct Steinberg_Linux_IRunLoopVtbl, registerTimer);
      ABI_FIELD_CASE(416, 7, struct Steinberg_Linux_IRunLoopVtbl, unregisterTimer);
      ABI_FIELD_CASE(417, 1, struct Steinberg_IBStreamVtbl, queryInterface);
      ABI_FIELD_CASE(417, 2, struct Steinberg_IBStreamVtbl, addRef);
      ABI_FIELD_CASE(417, 3, struct Steinberg_IBStreamVtbl, release);
      ABI_FIELD_CASE(417, 4, struct Steinberg_IBStreamVtbl, read);
      ABI_FIELD_CASE(417, 5, struct Steinberg_IBStreamVtbl, write);
      ABI_FIELD_CASE(417, 6, struct Steinberg_IBStreamVtbl, seek);
      ABI_FIELD_CASE(417, 7, struct Steinberg_IBStreamVtbl, tell);
      ABI_FIELD_CASE(418, 1, struct Steinberg_Vst_IAttributeListVtbl, queryInterface);
      ABI_FIELD_CASE(418, 2, struct Steinberg_Vst_IAttributeListVtbl, addRef);
      ABI_FIELD_CASE(418, 3, struct Steinberg_Vst_IAttributeListVtbl, release);
      ABI_FIELD_CASE(418, 4, struct Steinberg_Vst_IAttributeListVtbl, setInt);
      ABI_FIELD_CASE(418, 5, struct Steinberg_Vst_IAttributeListVtbl, getInt);
      ABI_FIELD_CASE(418, 6, struct Steinberg_Vst_IAttributeListVtbl, setFloat);
      ABI_FIELD_CASE(418, 7, struct Steinberg_Vst_IAttributeListVtbl, getFloat);
      ABI_FIELD_CASE(418, 8, struct Steinberg_Vst_IAttributeListVtbl, setString);
      ABI_FIELD_CASE(418, 9, struct Steinberg_Vst_IAttributeListVtbl, getString);
      ABI_FIELD_CASE(418, 10, struct Steinberg_Vst_IAttributeListVtbl, setBinary);
      ABI_FIELD_CASE(418, 11, struct Steinberg_Vst_IAttributeListVtbl, getBinary);
      ABI_FIELD_CASE(419, 1, struct Steinberg_Vst_IMessageVtbl, queryInterface);
      ABI_FIELD_CASE(419, 2, struct Steinberg_Vst_IMessageVtbl, addRef);
      ABI_FIELD_CASE(419, 3, struct Steinberg_Vst_IMessageVtbl, release);
      ABI_FIELD_CASE(419, 4, struct Steinberg_Vst_IMessageVtbl, getMessageID);
      ABI_FIELD_CASE(419, 5, struct Steinberg_Vst_IMessageVtbl, setMessageID);
      ABI_FIELD_CASE(419, 6, struct Steinberg_Vst_IMessageVtbl, getAttributes);
      ABI_FIELD_CASE(420, 1, struct Steinberg_Vst_IComponentHandlerVtbl, queryInterface);
      ABI_FIELD_CASE(420, 2, struct Steinberg_Vst_IComponentHandlerVtbl, addRef);
      ABI_FIELD_CASE(420, 3, struct Steinberg_Vst_IComponentHandlerVtbl, release);
      ABI_FIELD_CASE(420, 4, struct Steinberg_Vst_IComponentHandlerVtbl, beginEdit);
      ABI_FIELD_CASE(420, 5, struct Steinberg_Vst_IComponentHandlerVtbl, performEdit);
      ABI_FIELD_CASE(420, 6, struct Steinberg_Vst_IComponentHandlerVtbl, endEdit);
      ABI_FIELD_CASE(420, 7, struct Steinberg_Vst_IComponentHandlerVtbl, restartComponent);
      ABI_FIELD_CASE(422, 1, struct Steinberg_Vst_IAudioProcessorVtbl, queryInterface);
      ABI_FIELD_CASE(422, 2, struct Steinberg_Vst_IAudioProcessorVtbl, addRef);
      ABI_FIELD_CASE(422, 3, struct Steinberg_Vst_IAudioProcessorVtbl, release);
      ABI_FIELD_CASE(422, 4, struct Steinberg_Vst_IAudioProcessorVtbl, setBusArrangements);
      ABI_FIELD_CASE(422, 5, struct Steinberg_Vst_IAudioProcessorVtbl, getBusArrangement);
      ABI_FIELD_CASE(422, 6, struct Steinberg_Vst_IAudioProcessorVtbl, canProcessSampleSize);
      ABI_FIELD_CASE(422, 7, struct Steinberg_Vst_IAudioProcessorVtbl, getLatencySamples);
      ABI_FIELD_CASE(422, 8, struct Steinberg_Vst_IAudioProcessorVtbl, setupProcessing);
      ABI_FIELD_CASE(422, 9, struct Steinberg_Vst_IAudioProcessorVtbl, setProcessing);
      ABI_FIELD_CASE(422, 10, struct Steinberg_Vst_IAudioProcessorVtbl, process);
      ABI_FIELD_CASE(422, 11, struct Steinberg_Vst_IAudioProcessorVtbl, getTailSamples);
      default: return UINT64_MAX;
}
}


uint64_t pluginhost_vst3_abi_uid_byte(int32_t index) {
   if (index < 0 || index >= 16)
      return UINT64_MAX;
   return (uint8_t)Steinberg_IPluginFactory_iid[index];
}
