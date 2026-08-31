#include <stddef.h>
#include <stdint.h>

#include <clap/audio-buffer.h>
#include <clap/entry.h>
#include <clap/events.h>
#include <clap/ext/audio-ports.h>
#include <clap/ext/note-ports.h>
#include <clap/ext/render.h>
#include <clap/factory/plugin-factory.h>
#include <clap/host.h>
#include <clap/ext/log.h>
#include <clap/ext/thread-check.h>
#include <clap/plugin.h>
#include <clap/process.h>
#include <clap/version.h>

#include <jack/jack.h>
#include <jack/midiport.h>
#include "rt_atomic.h"

#define ABI_FIELD_ID(type_id, field_id) ((type_id) * 100 + (field_id))
#define ABI_FIELD_CASE(type_id, field_id, type_name, field_name)                                  \
   case ABI_FIELD_ID(type_id, field_id): return (uint64_t)offsetof(type_name, field_name)
#define ABI_TYPE_CASE(type_id, type_name) case type_id: return (uint64_t)sizeof(type_name)
#define ABI_ALIGN_CASE(type_id, type_name) case type_id: return (uint64_t)_Alignof(type_name)

#define ABI_ASSERT_FIELD(type_name, field_name, signature)                                        \
   _Static_assert(__builtin_types_compatible_p(__typeof__(((type_name *)0)->field_name), signature), \
                  "unexpected signature: " #type_name "." #field_name)
#define ABI_ASSERT_SYMBOL(symbol, signature)                                                       \
   _Static_assert(__builtin_types_compatible_p(__typeof__(&(symbol)), signature),                  \
                  "unexpected signature: " #symbol)

/* CLAP function-pointer signatures. */
ABI_ASSERT_FIELD(clap_input_events_t, size,
                 uint32_t(CLAP_ABI *)(const clap_input_events_t *));
ABI_ASSERT_FIELD(clap_input_events_t, get,
                 const clap_event_header_t *(CLAP_ABI *)(const clap_input_events_t *, uint32_t));
ABI_ASSERT_FIELD(clap_output_events_t, try_push,
                 bool(CLAP_ABI *)(const clap_output_events_t *, const clap_event_header_t *));
ABI_ASSERT_FIELD(clap_host_t, get_extension,
                 const void *(CLAP_ABI *)(const clap_host_t *, const char *));
ABI_ASSERT_FIELD(clap_host_t, request_restart, void(CLAP_ABI *)(const clap_host_t *));
ABI_ASSERT_FIELD(clap_host_t, request_process, void(CLAP_ABI *)(const clap_host_t *));
ABI_ASSERT_FIELD(clap_host_t, request_callback, void(CLAP_ABI *)(const clap_host_t *));
ABI_ASSERT_FIELD(clap_host_log_t, log,
                  void(CLAP_ABI *)(const clap_host_t *, clap_log_severity,
                                   const char *));
ABI_ASSERT_FIELD(clap_host_thread_check_t, is_main_thread,
                  bool(CLAP_ABI *)(const clap_host_t *));
ABI_ASSERT_FIELD(clap_host_thread_check_t, is_audio_thread,
                  bool(CLAP_ABI *)(const clap_host_t *));
ABI_ASSERT_FIELD(clap_plugin_t, init, bool(CLAP_ABI *)(const clap_plugin_t *));
ABI_ASSERT_FIELD(clap_plugin_t, destroy, void(CLAP_ABI *)(const clap_plugin_t *));
ABI_ASSERT_FIELD(clap_plugin_t, activate,
                 bool(CLAP_ABI *)(const clap_plugin_t *, double, uint32_t, uint32_t));
ABI_ASSERT_FIELD(clap_plugin_t, deactivate, void(CLAP_ABI *)(const clap_plugin_t *));
ABI_ASSERT_FIELD(clap_plugin_t, start_processing, bool(CLAP_ABI *)(const clap_plugin_t *));
ABI_ASSERT_FIELD(clap_plugin_t, stop_processing, void(CLAP_ABI *)(const clap_plugin_t *));
ABI_ASSERT_FIELD(clap_plugin_t, reset, void(CLAP_ABI *)(const clap_plugin_t *));
ABI_ASSERT_FIELD(clap_plugin_t, process,
                 clap_process_status(CLAP_ABI *)(const clap_plugin_t *, const clap_process_t *));
ABI_ASSERT_FIELD(clap_plugin_t, get_extension,
                 const void *(CLAP_ABI *)(const clap_plugin_t *, const char *));
ABI_ASSERT_FIELD(clap_plugin_t, on_main_thread, void(CLAP_ABI *)(const clap_plugin_t *));
ABI_ASSERT_FIELD(clap_plugin_entry_t, init, bool(CLAP_ABI *)(const char *));
ABI_ASSERT_FIELD(clap_plugin_entry_t, deinit, void(CLAP_ABI *)(void));
ABI_ASSERT_FIELD(clap_plugin_entry_t, get_factory, const void *(CLAP_ABI *)(const char *));
ABI_ASSERT_FIELD(clap_plugin_factory_t, get_plugin_count,
                 uint32_t(CLAP_ABI *)(const clap_plugin_factory_t *));
ABI_ASSERT_FIELD(clap_plugin_factory_t, get_plugin_descriptor,
                 const clap_plugin_descriptor_t *(CLAP_ABI *)(const clap_plugin_factory_t *,
                                                               uint32_t));
ABI_ASSERT_FIELD(clap_plugin_factory_t, create_plugin,
                 const clap_plugin_t *(CLAP_ABI *)(const clap_plugin_factory_t *,
                                                   const clap_host_t *, const char *));
ABI_ASSERT_FIELD(clap_plugin_audio_ports_t, count,
                 uint32_t(CLAP_ABI *)(const clap_plugin_t *, bool));
ABI_ASSERT_FIELD(clap_plugin_audio_ports_t, get,
                 bool(CLAP_ABI *)(const clap_plugin_t *, uint32_t, bool,
                                  clap_audio_port_info_t *));
ABI_ASSERT_FIELD(clap_host_audio_ports_t, is_rescan_flag_supported,
                 bool(CLAP_ABI *)(const clap_host_t *, uint32_t));
ABI_ASSERT_FIELD(clap_host_audio_ports_t, rescan,
                 void(CLAP_ABI *)(const clap_host_t *, uint32_t));
ABI_ASSERT_FIELD(clap_plugin_note_ports_t, count,
                 uint32_t(CLAP_ABI *)(const clap_plugin_t *, bool));
ABI_ASSERT_FIELD(clap_plugin_note_ports_t, get,
                 bool(CLAP_ABI *)(const clap_plugin_t *, uint32_t, bool,
                                  clap_note_port_info_t *));
ABI_ASSERT_FIELD(clap_host_note_ports_t, supported_dialects,
                 uint32_t(CLAP_ABI *)(const clap_host_t *));
ABI_ASSERT_FIELD(clap_host_note_ports_t, rescan,
                 void(CLAP_ABI *)(const clap_host_t *, uint32_t));
ABI_ASSERT_FIELD(clap_plugin_render_t, has_hard_realtime_requirement,
                 bool(CLAP_ABI *)(const clap_plugin_t *));
ABI_ASSERT_FIELD(clap_plugin_render_t, set,
                 bool(CLAP_ABI *)(const clap_plugin_t *,
                                   clap_plugin_render_mode));

/* JACK callback and function signatures used by the raw module. */
_Static_assert(__builtin_types_compatible_p(JackProcessCallback,
                                             int (*)(jack_nframes_t, void *)),
               "unexpected JackProcessCallback");
_Static_assert(__builtin_types_compatible_p(JackShutdownCallback, void (*)(void *)),
               "unexpected JackShutdownCallback");
_Static_assert(__builtin_types_compatible_p(
                  JackInfoShutdownCallback, void (*)(jack_status_t, const char *, void *)),
               "unexpected JackInfoShutdownCallback");
_Static_assert(__builtin_types_compatible_p(
                  JackBufferSizeCallback, int (*)(jack_nframes_t, void *)),
               "unexpected JackBufferSizeCallback");
_Static_assert(__builtin_types_compatible_p(
                  JackSampleRateCallback, int (*)(jack_nframes_t, void *)),
               "unexpected JackSampleRateCallback");
_Static_assert(__builtin_types_compatible_p(JackXRunCallback, int (*)(void *)),
               "unexpected JackXRunCallback");
_Static_assert(__builtin_types_compatible_p(
                  JackFreewheelCallback, void (*)(int, void *)),
               "unexpected JackFreewheelCallback");
_Static_assert(__builtin_types_compatible_p(
                  JackLatencyCallback, void (*)(jack_latency_callback_mode_t, void *)),
               "unexpected JackLatencyCallback");

ABI_ASSERT_SYMBOL(jack_get_version, void (*)(int *, int *, int *, int *));
ABI_ASSERT_SYMBOL(jack_get_version_string, const char *(*)(void));
ABI_ASSERT_SYMBOL(jack_client_open,
                  jack_client_t *(*)(const char *, jack_options_t, jack_status_t *, ...));
ABI_ASSERT_SYMBOL(jack_client_close, int (*)(jack_client_t *));
ABI_ASSERT_SYMBOL(jack_client_name_size, int (*)(void));
ABI_ASSERT_SYMBOL(jack_get_client_name, char *(*)(jack_client_t *));
ABI_ASSERT_SYMBOL(jack_activate, int (*)(jack_client_t *));
ABI_ASSERT_SYMBOL(jack_deactivate, int (*)(jack_client_t *));
ABI_ASSERT_SYMBOL(jack_on_shutdown,
                  void (*)(jack_client_t *, JackShutdownCallback, void *));
ABI_ASSERT_SYMBOL(jack_on_info_shutdown,
                  void (*)(jack_client_t *, JackInfoShutdownCallback, void *));
ABI_ASSERT_SYMBOL(jack_set_process_callback,
                  int (*)(jack_client_t *, JackProcessCallback, void *));
ABI_ASSERT_SYMBOL(jack_set_buffer_size_callback,
                  int (*)(jack_client_t *, JackBufferSizeCallback, void *));
ABI_ASSERT_SYMBOL(jack_set_sample_rate_callback,
                  int (*)(jack_client_t *, JackSampleRateCallback, void *));
ABI_ASSERT_SYMBOL(jack_set_xrun_callback,
                  int (*)(jack_client_t *, JackXRunCallback, void *));
ABI_ASSERT_SYMBOL(jack_set_freewheel_callback,
                  int (*)(jack_client_t *, JackFreewheelCallback, void *));
ABI_ASSERT_SYMBOL(jack_set_latency_callback,
                  int (*)(jack_client_t *, JackLatencyCallback, void *));
ABI_ASSERT_SYMBOL(jack_get_sample_rate, jack_nframes_t (*)(jack_client_t *));
ABI_ASSERT_SYMBOL(jack_get_buffer_size, jack_nframes_t (*)(jack_client_t *));
ABI_ASSERT_SYMBOL(jack_port_register,
                  jack_port_t *(*)(jack_client_t *, const char *, const char *,
                                   unsigned long, unsigned long));
ABI_ASSERT_SYMBOL(jack_port_unregister, int (*)(jack_client_t *, jack_port_t *));
ABI_ASSERT_SYMBOL(jack_port_get_buffer, void *(*)(jack_port_t *, jack_nframes_t));
ABI_ASSERT_SYMBOL(jack_port_name, const char *(*)(const jack_port_t *));
ABI_ASSERT_SYMBOL(jack_port_flags, int (*)(const jack_port_t *));
ABI_ASSERT_SYMBOL(jack_port_set_alias, int (*)(jack_port_t *, const char *));
ABI_ASSERT_SYMBOL(jack_port_name_size, int (*)(void));
ABI_ASSERT_SYMBOL(jack_port_get_latency_range,
                  void (*)(jack_port_t *, jack_latency_callback_mode_t,
                           jack_latency_range_t *));
ABI_ASSERT_SYMBOL(jack_port_set_latency_range,
                  void (*)(jack_port_t *, jack_latency_callback_mode_t,
                           jack_latency_range_t *));
ABI_ASSERT_SYMBOL(jack_recompute_total_latencies, int (*)(jack_client_t *));
ABI_ASSERT_SYMBOL(jack_midi_get_event_count, uint32_t (*)(void *));
ABI_ASSERT_SYMBOL(jack_midi_event_get,
                  int (*)(jack_midi_event_t *, void *, uint32_t));
ABI_ASSERT_SYMBOL(jack_midi_clear_buffer, void (*)(void *));
ABI_ASSERT_SYMBOL(jack_midi_max_event_size, size_t (*)(void *));
ABI_ASSERT_SYMBOL(jack_midi_event_reserve,
                  jack_midi_data_t *(*)(void *, jack_nframes_t, size_t));
ABI_ASSERT_SYMBOL(jack_midi_event_write,
                  int (*)(void *, jack_nframes_t, const jack_midi_data_t *, size_t));

uint64_t pluginhost_abi_size(int32_t type_id) {
   switch (type_id) {
      ABI_TYPE_CASE(1, clap_version_t);
      ABI_TYPE_CASE(2, clap_event_header_t);
      ABI_TYPE_CASE(3, clap_event_note_t);
      ABI_TYPE_CASE(4, clap_event_note_expression_t);
      ABI_TYPE_CASE(5, clap_event_param_value_t);
      ABI_TYPE_CASE(6, clap_event_param_mod_t);
      ABI_TYPE_CASE(7, clap_event_param_gesture_t);
      ABI_TYPE_CASE(8, clap_event_transport_t);
      ABI_TYPE_CASE(9, clap_event_midi_t);
      ABI_TYPE_CASE(10, clap_event_midi_sysex_t);
      ABI_TYPE_CASE(11, clap_event_midi2_t);
      ABI_TYPE_CASE(12, clap_input_events_t);
      ABI_TYPE_CASE(13, clap_output_events_t);
      ABI_TYPE_CASE(14, clap_audio_buffer_t);
      ABI_TYPE_CASE(15, clap_process_t);
      ABI_TYPE_CASE(16, clap_host_t);
      ABI_TYPE_CASE(17, clap_plugin_descriptor_t);
      ABI_TYPE_CASE(18, clap_plugin_t);
      ABI_TYPE_CASE(19, clap_plugin_entry_t);
      ABI_TYPE_CASE(20, clap_plugin_factory_t);
      ABI_TYPE_CASE(21, clap_audio_port_info_t);
      ABI_TYPE_CASE(22, clap_plugin_audio_ports_t);
      ABI_TYPE_CASE(23, clap_host_audio_ports_t);
      ABI_TYPE_CASE(24, clap_note_port_info_t);
      ABI_TYPE_CASE(25, clap_plugin_note_ports_t);
      ABI_TYPE_CASE(26, clap_host_note_ports_t);
      ABI_TYPE_CASE(33, clap_host_log_t);
      ABI_TYPE_CASE(34, clap_host_thread_check_t);
      ABI_TYPE_CASE(35, clap_plugin_render_t);
      ABI_TYPE_CASE(36, clap_plugin_render_mode);
      ABI_TYPE_CASE(27, clap_id);
      ABI_TYPE_CASE(28, clap_beattime);
      ABI_TYPE_CASE(29, clap_sectime);
      ABI_TYPE_CASE(30, clap_process_status);
      ABI_TYPE_CASE(31, clap_note_expression);
      ABI_TYPE_CASE(32, bool);
      ABI_TYPE_CASE(101, jack_nframes_t);
      ABI_TYPE_CASE(102, jack_time_t);
      ABI_TYPE_CASE(103, jack_port_id_t);
      ABI_TYPE_CASE(104, jack_default_audio_sample_t);
      ABI_TYPE_CASE(105, jack_options_t);
      ABI_TYPE_CASE(106, jack_status_t);
      ABI_TYPE_CASE(107, jack_latency_callback_mode_t);
      ABI_TYPE_CASE(108, unsigned long);
      ABI_TYPE_CASE(109, jack_latency_range_t);
      ABI_TYPE_CASE(110, jack_midi_event_t);
      ABI_TYPE_CASE(111, jack_midi_data_t);
      ABI_TYPE_CASE(201, pluginhost_rt_atomic_u32);
      ABI_TYPE_CASE(202, pluginhost_rt_atomic_i32);
      ABI_TYPE_CASE(203, pluginhost_rt_atomic_u64);
      default: return UINT64_MAX;
   }
}

uint64_t pluginhost_abi_align(int32_t type_id) {
   switch (type_id) {
      ABI_ALIGN_CASE(1, clap_version_t);
      ABI_ALIGN_CASE(2, clap_event_header_t);
      ABI_ALIGN_CASE(3, clap_event_note_t);
      ABI_ALIGN_CASE(4, clap_event_note_expression_t);
      ABI_ALIGN_CASE(5, clap_event_param_value_t);
      ABI_ALIGN_CASE(6, clap_event_param_mod_t);
      ABI_ALIGN_CASE(7, clap_event_param_gesture_t);
      ABI_ALIGN_CASE(8, clap_event_transport_t);
      ABI_ALIGN_CASE(9, clap_event_midi_t);
      ABI_ALIGN_CASE(10, clap_event_midi_sysex_t);
      ABI_ALIGN_CASE(11, clap_event_midi2_t);
      ABI_ALIGN_CASE(12, clap_input_events_t);
      ABI_ALIGN_CASE(13, clap_output_events_t);
      ABI_ALIGN_CASE(14, clap_audio_buffer_t);
      ABI_ALIGN_CASE(15, clap_process_t);
      ABI_ALIGN_CASE(16, clap_host_t);
      ABI_ALIGN_CASE(17, clap_plugin_descriptor_t);
      ABI_ALIGN_CASE(18, clap_plugin_t);
      ABI_ALIGN_CASE(19, clap_plugin_entry_t);
      ABI_ALIGN_CASE(20, clap_plugin_factory_t);
      ABI_ALIGN_CASE(21, clap_audio_port_info_t);
      ABI_ALIGN_CASE(22, clap_plugin_audio_ports_t);
      ABI_ALIGN_CASE(23, clap_host_audio_ports_t);
      ABI_ALIGN_CASE(24, clap_note_port_info_t);
      ABI_ALIGN_CASE(25, clap_plugin_note_ports_t);
      ABI_ALIGN_CASE(26, clap_host_note_ports_t);
      ABI_ALIGN_CASE(33, clap_host_log_t);
      ABI_ALIGN_CASE(34, clap_host_thread_check_t);
      ABI_ALIGN_CASE(35, clap_plugin_render_t);
      ABI_ALIGN_CASE(36, clap_plugin_render_mode);
      ABI_ALIGN_CASE(27, clap_id);
      ABI_ALIGN_CASE(28, clap_beattime);
      ABI_ALIGN_CASE(29, clap_sectime);
      ABI_ALIGN_CASE(30, clap_process_status);
      ABI_ALIGN_CASE(31, clap_note_expression);
      ABI_ALIGN_CASE(32, bool);
      ABI_ALIGN_CASE(101, jack_nframes_t);
      ABI_ALIGN_CASE(102, jack_time_t);
      ABI_ALIGN_CASE(103, jack_port_id_t);
      ABI_ALIGN_CASE(104, jack_default_audio_sample_t);
      ABI_ALIGN_CASE(105, jack_options_t);
      ABI_ALIGN_CASE(106, jack_status_t);
      ABI_ALIGN_CASE(107, jack_latency_callback_mode_t);
      ABI_ALIGN_CASE(108, unsigned long);
      ABI_ALIGN_CASE(109, jack_latency_range_t);
      ABI_ALIGN_CASE(110, jack_midi_event_t);
      ABI_ALIGN_CASE(111, jack_midi_data_t);
      ABI_ALIGN_CASE(201, pluginhost_rt_atomic_u32);
      ABI_ALIGN_CASE(202, pluginhost_rt_atomic_i32);
      ABI_ALIGN_CASE(203, pluginhost_rt_atomic_u64);
      default: return UINT64_MAX;
   }
}

uint64_t pluginhost_abi_offset(int32_t field_id) {
   switch (field_id) {
      ABI_FIELD_CASE(1, 1, clap_version_t, major);
      ABI_FIELD_CASE(1, 2, clap_version_t, minor);
      ABI_FIELD_CASE(1, 3, clap_version_t, revision);
      ABI_FIELD_CASE(2, 1, clap_event_header_t, size);
      ABI_FIELD_CASE(2, 2, clap_event_header_t, time);
      ABI_FIELD_CASE(2, 3, clap_event_header_t, space_id);
      ABI_FIELD_CASE(2, 4, clap_event_header_t, type);
      ABI_FIELD_CASE(2, 5, clap_event_header_t, flags);
      ABI_FIELD_CASE(3, 1, clap_event_note_t, header);
      ABI_FIELD_CASE(3, 2, clap_event_note_t, note_id);
      ABI_FIELD_CASE(3, 3, clap_event_note_t, port_index);
      ABI_FIELD_CASE(3, 4, clap_event_note_t, channel);
      ABI_FIELD_CASE(3, 5, clap_event_note_t, key);
      ABI_FIELD_CASE(3, 6, clap_event_note_t, velocity);
      ABI_FIELD_CASE(4, 1, clap_event_note_expression_t, header);
      ABI_FIELD_CASE(4, 2, clap_event_note_expression_t, expression_id);
      ABI_FIELD_CASE(4, 3, clap_event_note_expression_t, note_id);
      ABI_FIELD_CASE(4, 4, clap_event_note_expression_t, port_index);
      ABI_FIELD_CASE(4, 5, clap_event_note_expression_t, channel);
      ABI_FIELD_CASE(4, 6, clap_event_note_expression_t, key);
      ABI_FIELD_CASE(4, 7, clap_event_note_expression_t, value);
      ABI_FIELD_CASE(5, 1, clap_event_param_value_t, header);
      ABI_FIELD_CASE(5, 2, clap_event_param_value_t, param_id);
      ABI_FIELD_CASE(5, 3, clap_event_param_value_t, cookie);
      ABI_FIELD_CASE(5, 4, clap_event_param_value_t, note_id);
      ABI_FIELD_CASE(5, 5, clap_event_param_value_t, port_index);
      ABI_FIELD_CASE(5, 6, clap_event_param_value_t, channel);
      ABI_FIELD_CASE(5, 7, clap_event_param_value_t, key);
      ABI_FIELD_CASE(5, 8, clap_event_param_value_t, value);
      ABI_FIELD_CASE(6, 1, clap_event_param_mod_t, header);
      ABI_FIELD_CASE(6, 2, clap_event_param_mod_t, param_id);
      ABI_FIELD_CASE(6, 3, clap_event_param_mod_t, cookie);
      ABI_FIELD_CASE(6, 4, clap_event_param_mod_t, note_id);
      ABI_FIELD_CASE(6, 5, clap_event_param_mod_t, port_index);
      ABI_FIELD_CASE(6, 6, clap_event_param_mod_t, channel);
      ABI_FIELD_CASE(6, 7, clap_event_param_mod_t, key);
      ABI_FIELD_CASE(6, 8, clap_event_param_mod_t, amount);
      ABI_FIELD_CASE(7, 1, clap_event_param_gesture_t, header);
      ABI_FIELD_CASE(7, 2, clap_event_param_gesture_t, param_id);
      ABI_FIELD_CASE(8, 1, clap_event_transport_t, header);
      ABI_FIELD_CASE(8, 2, clap_event_transport_t, flags);
      ABI_FIELD_CASE(8, 3, clap_event_transport_t, song_pos_beats);
      ABI_FIELD_CASE(8, 4, clap_event_transport_t, song_pos_seconds);
      ABI_FIELD_CASE(8, 5, clap_event_transport_t, tempo);
      ABI_FIELD_CASE(8, 6, clap_event_transport_t, tempo_inc);
      ABI_FIELD_CASE(8, 7, clap_event_transport_t, loop_start_beats);
      ABI_FIELD_CASE(8, 8, clap_event_transport_t, loop_end_beats);
      ABI_FIELD_CASE(8, 9, clap_event_transport_t, loop_start_seconds);
      ABI_FIELD_CASE(8, 10, clap_event_transport_t, loop_end_seconds);
      ABI_FIELD_CASE(8, 11, clap_event_transport_t, bar_start);
      ABI_FIELD_CASE(8, 12, clap_event_transport_t, bar_number);
      ABI_FIELD_CASE(8, 13, clap_event_transport_t, tsig_num);
      ABI_FIELD_CASE(8, 14, clap_event_transport_t, tsig_denom);
      ABI_FIELD_CASE(9, 1, clap_event_midi_t, header);
      ABI_FIELD_CASE(9, 2, clap_event_midi_t, port_index);
      ABI_FIELD_CASE(9, 3, clap_event_midi_t, data);
      ABI_FIELD_CASE(10, 1, clap_event_midi_sysex_t, header);
      ABI_FIELD_CASE(10, 2, clap_event_midi_sysex_t, port_index);
      ABI_FIELD_CASE(10, 3, clap_event_midi_sysex_t, buffer);
      ABI_FIELD_CASE(10, 4, clap_event_midi_sysex_t, size);
      ABI_FIELD_CASE(11, 1, clap_event_midi2_t, header);
      ABI_FIELD_CASE(11, 2, clap_event_midi2_t, port_index);
      ABI_FIELD_CASE(11, 3, clap_event_midi2_t, data);
      ABI_FIELD_CASE(12, 1, clap_input_events_t, ctx);
      ABI_FIELD_CASE(12, 2, clap_input_events_t, size);
      ABI_FIELD_CASE(12, 3, clap_input_events_t, get);
      ABI_FIELD_CASE(13, 1, clap_output_events_t, ctx);
      ABI_FIELD_CASE(13, 2, clap_output_events_t, try_push);
      ABI_FIELD_CASE(14, 1, clap_audio_buffer_t, data32);
      ABI_FIELD_CASE(14, 2, clap_audio_buffer_t, data64);
      ABI_FIELD_CASE(14, 3, clap_audio_buffer_t, channel_count);
      ABI_FIELD_CASE(14, 4, clap_audio_buffer_t, latency);
      ABI_FIELD_CASE(14, 5, clap_audio_buffer_t, constant_mask);
      ABI_FIELD_CASE(15, 1, clap_process_t, steady_time);
      ABI_FIELD_CASE(15, 2, clap_process_t, frames_count);
      ABI_FIELD_CASE(15, 3, clap_process_t, transport);
      ABI_FIELD_CASE(15, 4, clap_process_t, audio_inputs);
      ABI_FIELD_CASE(15, 5, clap_process_t, audio_outputs);
      ABI_FIELD_CASE(15, 6, clap_process_t, audio_inputs_count);
      ABI_FIELD_CASE(15, 7, clap_process_t, audio_outputs_count);
      ABI_FIELD_CASE(15, 8, clap_process_t, in_events);
      ABI_FIELD_CASE(15, 9, clap_process_t, out_events);
      ABI_FIELD_CASE(16, 1, clap_host_t, clap_version);
      ABI_FIELD_CASE(16, 2, clap_host_t, host_data);
      ABI_FIELD_CASE(16, 3, clap_host_t, name);
      ABI_FIELD_CASE(16, 4, clap_host_t, vendor);
      ABI_FIELD_CASE(16, 5, clap_host_t, url);
      ABI_FIELD_CASE(16, 6, clap_host_t, version);
      ABI_FIELD_CASE(16, 7, clap_host_t, get_extension);
      ABI_FIELD_CASE(16, 8, clap_host_t, request_restart);
      ABI_FIELD_CASE(16, 9, clap_host_t, request_process);
      ABI_FIELD_CASE(16, 10, clap_host_t, request_callback);
      ABI_FIELD_CASE(17, 1, clap_plugin_descriptor_t, clap_version);
      ABI_FIELD_CASE(17, 2, clap_plugin_descriptor_t, id);
      ABI_FIELD_CASE(17, 3, clap_plugin_descriptor_t, name);
      ABI_FIELD_CASE(17, 4, clap_plugin_descriptor_t, vendor);
      ABI_FIELD_CASE(17, 5, clap_plugin_descriptor_t, url);
      ABI_FIELD_CASE(17, 6, clap_plugin_descriptor_t, manual_url);
      ABI_FIELD_CASE(17, 7, clap_plugin_descriptor_t, support_url);
      ABI_FIELD_CASE(17, 8, clap_plugin_descriptor_t, version);
      ABI_FIELD_CASE(17, 9, clap_plugin_descriptor_t, description);
      ABI_FIELD_CASE(17, 10, clap_plugin_descriptor_t, features);
      ABI_FIELD_CASE(18, 1, clap_plugin_t, desc);
      ABI_FIELD_CASE(18, 2, clap_plugin_t, plugin_data);
      ABI_FIELD_CASE(18, 3, clap_plugin_t, init);
      ABI_FIELD_CASE(18, 4, clap_plugin_t, destroy);
      ABI_FIELD_CASE(18, 5, clap_plugin_t, activate);
      ABI_FIELD_CASE(18, 6, clap_plugin_t, deactivate);
      ABI_FIELD_CASE(18, 7, clap_plugin_t, start_processing);
      ABI_FIELD_CASE(18, 8, clap_plugin_t, stop_processing);
      ABI_FIELD_CASE(18, 9, clap_plugin_t, reset);
      ABI_FIELD_CASE(18, 10, clap_plugin_t, process);
      ABI_FIELD_CASE(18, 11, clap_plugin_t, get_extension);
      ABI_FIELD_CASE(18, 12, clap_plugin_t, on_main_thread);
      ABI_FIELD_CASE(19, 1, clap_plugin_entry_t, clap_version);
      ABI_FIELD_CASE(19, 2, clap_plugin_entry_t, init);
      ABI_FIELD_CASE(19, 3, clap_plugin_entry_t, deinit);
      ABI_FIELD_CASE(19, 4, clap_plugin_entry_t, get_factory);
      ABI_FIELD_CASE(20, 1, clap_plugin_factory_t, get_plugin_count);
      ABI_FIELD_CASE(20, 2, clap_plugin_factory_t, get_plugin_descriptor);
      ABI_FIELD_CASE(20, 3, clap_plugin_factory_t, create_plugin);
      ABI_FIELD_CASE(21, 1, clap_audio_port_info_t, id);
      ABI_FIELD_CASE(21, 2, clap_audio_port_info_t, name);
      ABI_FIELD_CASE(21, 3, clap_audio_port_info_t, flags);
      ABI_FIELD_CASE(21, 4, clap_audio_port_info_t, channel_count);
      ABI_FIELD_CASE(21, 5, clap_audio_port_info_t, port_type);
      ABI_FIELD_CASE(21, 6, clap_audio_port_info_t, in_place_pair);
      ABI_FIELD_CASE(22, 1, clap_plugin_audio_ports_t, count);
      ABI_FIELD_CASE(22, 2, clap_plugin_audio_ports_t, get);
      ABI_FIELD_CASE(23, 1, clap_host_audio_ports_t, is_rescan_flag_supported);
      ABI_FIELD_CASE(23, 2, clap_host_audio_ports_t, rescan);
      ABI_FIELD_CASE(24, 1, clap_note_port_info_t, id);
      ABI_FIELD_CASE(24, 2, clap_note_port_info_t, supported_dialects);
      ABI_FIELD_CASE(24, 3, clap_note_port_info_t, preferred_dialect);
      ABI_FIELD_CASE(24, 4, clap_note_port_info_t, name);
      ABI_FIELD_CASE(25, 1, clap_plugin_note_ports_t, count);
      ABI_FIELD_CASE(25, 2, clap_plugin_note_ports_t, get);
      ABI_FIELD_CASE(26, 1, clap_host_note_ports_t, supported_dialects);
      ABI_FIELD_CASE(26, 2, clap_host_note_ports_t, rescan);
      ABI_FIELD_CASE(33, 1, clap_host_log_t, log);
      ABI_FIELD_CASE(34, 1, clap_host_thread_check_t, is_main_thread);
      ABI_FIELD_CASE(34, 2, clap_host_thread_check_t, is_audio_thread);
      ABI_FIELD_CASE(35, 1, clap_plugin_render_t, has_hard_realtime_requirement);
      ABI_FIELD_CASE(35, 2, clap_plugin_render_t, set);
      ABI_FIELD_CASE(109, 1, jack_latency_range_t, min);
      ABI_FIELD_CASE(109, 2, jack_latency_range_t, max);
      ABI_FIELD_CASE(110, 1, jack_midi_event_t, time);
      ABI_FIELD_CASE(110, 2, jack_midi_event_t, size);
      ABI_FIELD_CASE(110, 3, jack_midi_event_t, buffer);
      default: return UINT64_MAX;
   }
}

int64_t pluginhost_abi_constant(int32_t constant_id) {
   switch (constant_id) {
      case 1: return CLAP_VERSION_MAJOR;
      case 2: return CLAP_VERSION_MINOR;
      case 3: return CLAP_VERSION_REVISION;
      case 4: return CLAP_NAME_SIZE;
      case 5: return CLAP_PATH_SIZE;
      case 6: return CLAP_INVALID_ID;
      case 7: return CLAP_BEATTIME_FACTOR;
      case 8: return CLAP_SECTIME_FACTOR;
      case 9: return CLAP_CORE_EVENT_SPACE_ID;
      case 10: return CLAP_EVENT_IS_LIVE;
      case 11: return CLAP_EVENT_DONT_RECORD;
      case 12: return CLAP_EVENT_NOTE_ON;
      case 13: return CLAP_EVENT_NOTE_OFF;
      case 14: return CLAP_EVENT_NOTE_CHOKE;
      case 15: return CLAP_EVENT_NOTE_END;
      case 16: return CLAP_EVENT_NOTE_EXPRESSION;
      case 17: return CLAP_EVENT_PARAM_VALUE;
      case 18: return CLAP_EVENT_PARAM_MOD;
      case 19: return CLAP_EVENT_PARAM_GESTURE_BEGIN;
      case 20: return CLAP_EVENT_PARAM_GESTURE_END;
      case 21: return CLAP_EVENT_TRANSPORT;
      case 22: return CLAP_EVENT_MIDI;
      case 23: return CLAP_EVENT_MIDI_SYSEX;
      case 24: return CLAP_EVENT_MIDI2;
      case 25: return CLAP_NOTE_EXPRESSION_VOLUME;
      case 26: return CLAP_NOTE_EXPRESSION_PAN;
      case 27: return CLAP_NOTE_EXPRESSION_TUNING;
      case 28: return CLAP_NOTE_EXPRESSION_VIBRATO;
      case 29: return CLAP_NOTE_EXPRESSION_EXPRESSION;
      case 30: return CLAP_NOTE_EXPRESSION_BRIGHTNESS;
      case 31: return CLAP_NOTE_EXPRESSION_PRESSURE;
      case 32: return CLAP_TRANSPORT_HAS_TEMPO;
      case 33: return CLAP_TRANSPORT_HAS_BEATS_TIMELINE;
      case 34: return CLAP_TRANSPORT_HAS_SECONDS_TIMELINE;
      case 35: return CLAP_TRANSPORT_HAS_TIME_SIGNATURE;
      case 36: return CLAP_TRANSPORT_IS_PLAYING;
      case 37: return CLAP_TRANSPORT_IS_RECORDING;
      case 38: return CLAP_TRANSPORT_IS_LOOP_ACTIVE;
      case 39: return CLAP_TRANSPORT_IS_WITHIN_PRE_ROLL;
      case 40: return CLAP_PROCESS_ERROR;
      case 41: return CLAP_PROCESS_CONTINUE;
      case 42: return CLAP_PROCESS_CONTINUE_IF_NOT_QUIET;
      case 43: return CLAP_PROCESS_TAIL;
      case 44: return CLAP_PROCESS_SLEEP;
      case 45: return CLAP_AUDIO_PORT_IS_MAIN;
      case 46: return CLAP_AUDIO_PORT_SUPPORTS_64BITS;
      case 47: return CLAP_AUDIO_PORT_PREFERS_64BITS;
      case 48: return CLAP_AUDIO_PORT_REQUIRES_COMMON_SAMPLE_SIZE;
      case 49: return CLAP_AUDIO_PORTS_RESCAN_NAMES;
      case 50: return CLAP_AUDIO_PORTS_RESCAN_FLAGS;
      case 51: return CLAP_AUDIO_PORTS_RESCAN_CHANNEL_COUNT;
      case 52: return CLAP_AUDIO_PORTS_RESCAN_PORT_TYPE;
      case 53: return CLAP_AUDIO_PORTS_RESCAN_IN_PLACE_PAIR;
      case 54: return CLAP_AUDIO_PORTS_RESCAN_LIST;
      case 55: return CLAP_NOTE_DIALECT_CLAP;
      case 56: return CLAP_NOTE_DIALECT_MIDI;
      case 57: return CLAP_NOTE_DIALECT_MIDI_MPE;
      case 58: return CLAP_NOTE_DIALECT_MIDI2;
      case 59: return CLAP_NOTE_PORTS_RESCAN_ALL;
      case 60: return CLAP_NOTE_PORTS_RESCAN_NAMES;
      case 61: return CLAP_LOG_DEBUG;
      case 62: return CLAP_LOG_INFO;
      case 63: return CLAP_LOG_WARNING;
      case 64: return CLAP_LOG_ERROR;
      case 65: return CLAP_LOG_FATAL;
      case 66: return CLAP_LOG_HOST_MISBEHAVING;
      case 67: return CLAP_LOG_PLUGIN_MISBEHAVING;
      case 68: return CLAP_RENDER_REALTIME;
      case 69: return CLAP_RENDER_OFFLINE;
      case 101: return JACK_MAX_FRAMES;
      case 102: return JackNullOption;
      case 103: return JackNoStartServer;
      case 104: return JackUseExactName;
      case 105: return JackServerName;
      case 106: return JackSessionID;
      case 107: return JackOpenOptions;
      case 108: return JackFailure;
      case 109: return JackInvalidOption;
      case 110: return JackNameNotUnique;
      case 111: return JackServerStarted;
      case 112: return JackServerFailed;
      case 113: return JackServerError;
      case 114: return JackNoSuchClient;
      case 115: return JackLoadFailure;
      case 116: return JackInitFailure;
      case 117: return JackShmFailure;
      case 118: return JackVersionError;
      case 119: return JackBackendError;
      case 120: return JackClientZombie;
      case 121: return JackCaptureLatency;
      case 122: return JackPlaybackLatency;
      case 123: return JackPortIsInput;
      case 124: return JackPortIsOutput;
      case 125: return JackPortIsPhysical;
      case 126: return JackPortCanMonitor;
      case 127: return JackPortIsTerminal;
      default: return INT64_MIN;
   }
}

const char *pluginhost_abi_string(int32_t string_id) {
   switch (string_id) {
      case 1: return CLAP_PLUGIN_FACTORY_ID;
      case 2: return CLAP_EXT_AUDIO_PORTS;
      case 3: return CLAP_EXT_NOTE_PORTS;
      case 4: return CLAP_PORT_MONO;
      case 5: return CLAP_PORT_STEREO;
      case 6: return CLAP_EXT_LOG;
      case 7: return CLAP_EXT_THREAD_CHECK;
      case 8: return CLAP_EXT_RENDER;
      case 101: return JACK_DEFAULT_AUDIO_TYPE;
      case 102: return JACK_DEFAULT_MIDI_TYPE;
      default: return NULL;
   }
}

int32_t pluginhost_abi_clap_version_is_compatible(uint32_t major, uint32_t minor,
                                                   uint32_t revision) {
   const clap_version_t version = {major, minor, revision};
   return clap_version_is_compatible(version) ? 1 : 0;
}
