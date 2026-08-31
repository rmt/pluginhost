#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <clap/entry.h>
#include <clap/events.h>
#include <clap/ext/audio-ports.h>
#include <clap/ext/log.h>
#include <clap/ext/thread-check.h>
#include <clap/factory/plugin-factory.h>
#include <clap/plugin-features.h>

#if defined(__GNUC__) || defined(__clang__)
#define AUDIO_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define AUDIO_FIXTURE_EXPORT
#endif

#ifndef PLUGINHOST_AUDIO_FIXTURE_MODE
#define PLUGINHOST_AUDIO_FIXTURE_MODE 0
#endif

#define MODE_TONE 0
#define MODE_GAIN 1
#define MODE_MULTI 2
#define MODE_ACTIVATE_FAIL 3
#define MODE_START_FAIL 4
#define MODE_PROCESS_ERROR 5
#define MODE_PROCESS_SLEEP 6
#define MODE_PROCESS_TAIL 7
#define MODE_PROCESS_CONTINUE_IF_NOT_QUIET 8

static const clap_host_t *fixture_host;
static uint32_t activate_count;
static uint32_t deactivate_count;
static uint32_t start_count;
static uint32_t stop_count;
static uint32_t process_count;
static uint32_t destroy_count;
static uint32_t contract_failures;
static double last_activate_sample_rate;
static uint32_t last_activate_min_frames;
static uint32_t last_activate_max_frames;
static int32_t last_process_status;
static int64_t last_steady_time;
static uint32_t last_frames;
static uint32_t last_input_groups;
static uint32_t last_output_groups;
static bool last_transport_null;
static bool last_data64_null;
static uintptr_t input_addresses[8];
static uintptr_t output_addresses[8];
static int lifecycle_order[32];
static uint32_t lifecycle_order_count;

static const char *fixture_features[] = {
   CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
   NULL,
};

static const clap_plugin_descriptor_t fixture_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.audio",
   .name = "Fixture Audio",
   .vendor = "pluginhost",
   .version = "1.0.0",
   .description = "Synthetic CLAP audio fixture",
   .features = fixture_features,
};

static void record_lifecycle(int value) {
   if (lifecycle_order_count < sizeof(lifecycle_order) / sizeof(lifecycle_order[0]))
      lifecycle_order[lifecycle_order_count++] = value;
}

static bool thread_is_main(void) {
   const clap_host_thread_check_t *check;
   if (fixture_host == NULL || fixture_host->get_extension == NULL)
      return false;
   check = (const clap_host_thread_check_t *)fixture_host->get_extension(
      fixture_host, CLAP_EXT_THREAD_CHECK);
   return check != NULL && check->is_main_thread(fixture_host);
}

static bool thread_is_audio(void) {
   const clap_host_thread_check_t *check;
   if (fixture_host == NULL || fixture_host->get_extension == NULL)
      return false;
   check = (const clap_host_thread_check_t *)fixture_host->get_extension(
      fixture_host, CLAP_EXT_THREAD_CHECK);
   return check != NULL && check->is_audio_thread(fixture_host);
}

static void require_main_not_audio(void) {
   if (!thread_is_main() || thread_is_audio())
      ++contract_failures;
}

static void require_audio(void) {
   if (!thread_is_audio())
      ++contract_failures;
}

static bool fixture_entry_init(const char *plugin_path) {
   return plugin_path != NULL && plugin_path[0] != '\0';
}

static void fixture_entry_deinit(void) {
}

static uint32_t fixture_audio_count(const clap_plugin_t *plugin, bool is_input) {
   (void)plugin;
   if (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_TONE)
      return is_input ? 0U : 1U;
   if (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_MULTI)
      return 2U;
   return 1U;
}

static void set_audio_name(clap_audio_port_info_t *info, const char *name) {
   (void)snprintf(info->name, sizeof(info->name), "%s", name);
}

static bool fixture_audio_get(const clap_plugin_t *plugin, uint32_t index,
                              bool is_input, clap_audio_port_info_t *info) {
   (void)plugin;
   if (info == NULL)
      return false;
   memset(info, 0, sizeof(*info));
   info->in_place_pair = CLAP_INVALID_ID;

   if (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_MULTI) {
      if (index >= 2U)
         return false;
      if (is_input && index == 0U) {
         info->id = 10U;
         info->flags = CLAP_AUDIO_PORT_IS_MAIN;
         info->channel_count = 2U;
         info->port_type = CLAP_PORT_STEREO;
         set_audio_name(info, "Main Input");
      } else if (is_input) {
         info->id = 11U;
         info->channel_count = 1U;
         info->port_type = CLAP_PORT_MONO;
         set_audio_name(info, "Side Input");
      } else if (index == 0U) {
         info->id = 20U;
         info->flags = CLAP_AUDIO_PORT_IS_MAIN;
         info->channel_count = 2U;
         info->port_type = CLAP_PORT_STEREO;
         set_audio_name(info, "Main Output");
      } else {
         info->id = 21U;
         info->channel_count = 1U;
         info->port_type = CLAP_PORT_MONO;
         set_audio_name(info, "Side Output");
      }
      return true;
   }

   if (index != 0U || (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_TONE && is_input))
      return false;
   if (is_input) {
      info->id = 10U;
      info->flags = CLAP_AUDIO_PORT_IS_MAIN;
      info->channel_count = 2U;
      info->port_type = CLAP_PORT_STEREO;
      set_audio_name(info, "Main Input");
   } else {
      info->id = 20U;
      info->flags = CLAP_AUDIO_PORT_IS_MAIN;
      info->channel_count = 2U;
      info->port_type = CLAP_PORT_STEREO;
      set_audio_name(info, "Main Output");
   }
   return true;
}

static const clap_plugin_audio_ports_t fixture_audio_ports = {
   .count = fixture_audio_count,
   .get = fixture_audio_get,
};

static bool fixture_plugin_init(const clap_plugin_t *plugin) {
   (void)plugin;
   require_main_not_audio();
   return true;
}

static void fixture_plugin_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
   require_main_not_audio();
   ++destroy_count;
   record_lifecycle(6);
}

static bool fixture_plugin_activate(const clap_plugin_t *plugin,
                                    double sample_rate,
                                    uint32_t min_frames_count,
                                    uint32_t max_frames_count) {
   (void)plugin;
   if (sample_rate <= 0.0 || min_frames_count == 0U ||
       max_frames_count < min_frames_count)
      ++contract_failures;
   require_main_not_audio();
   last_activate_sample_rate = sample_rate;
   last_activate_min_frames = min_frames_count;
   last_activate_max_frames = max_frames_count;
   ++activate_count;
   record_lifecycle(1);
   return PLUGINHOST_AUDIO_FIXTURE_MODE != MODE_ACTIVATE_FAIL;
}

static void fixture_plugin_deactivate(const clap_plugin_t *plugin) {
   (void)plugin;
   require_main_not_audio();
   ++deactivate_count;
   record_lifecycle(5);
}

static bool fixture_plugin_start_processing(const clap_plugin_t *plugin) {
   (void)plugin;
   require_audio();
   ++start_count;
   record_lifecycle(2);
   return PLUGINHOST_AUDIO_FIXTURE_MODE != MODE_START_FAIL;
}

static void fixture_plugin_stop_processing(const clap_plugin_t *plugin) {
   (void)plugin;
   require_audio();
   ++stop_count;
   record_lifecycle(4);
}

static void fixture_plugin_reset(const clap_plugin_t *plugin) {
   (void)plugin;
}

static clap_process_status fixture_plugin_process(const clap_plugin_t *plugin,
                                                  const clap_process_t *process) {
   uint32_t channel;
   (void)plugin;
   require_audio();
   if (process == NULL || process->transport != NULL ||
       process->in_events == NULL || process->out_events == NULL ||
       process->audio_outputs_count == 0U || process->audio_outputs == NULL) {
      ++contract_failures;
      return CLAP_PROCESS_ERROR;
   }
   if (process->in_events->size == NULL || process->in_events->get == NULL ||
       process->in_events->size(process->in_events) != 0U ||
       process->in_events->get(process->in_events, 0U) != NULL)
      ++contract_failures;
   clap_event_header_t rejected_event = {
      .size = sizeof(rejected_event),
      .space_id = CLAP_CORE_EVENT_SPACE_ID,
   };
   if (process->out_events->try_push == NULL ||
       process->out_events->try_push(process->out_events, &rejected_event))
      ++contract_failures;
   if (fixture_host != NULL && fixture_host->request_process != NULL)
      fixture_host->request_process(fixture_host);
   if (fixture_host != NULL && fixture_host->get_extension != NULL) {
      const clap_host_log_t *log = (const clap_host_log_t *)fixture_host->get_extension(
         fixture_host, CLAP_EXT_LOG);
      if (log != NULL && log->log != NULL)
         log->log(fixture_host, CLAP_LOG_INFO, "fixture process");
   }

   last_steady_time = process->steady_time;
   last_frames = process->frames_count;
   last_input_groups = process->audio_inputs_count;
   last_output_groups = process->audio_outputs_count;
   last_transport_null = process->transport == NULL;
   last_data64_null = true;

   uint32_t address_index = 0U;
   for (channel = 0U; channel < process->audio_inputs_count; ++channel) {
      const clap_audio_buffer_t *buffer = &process->audio_inputs[channel];
      uint32_t inner;
      if (buffer->data32 == NULL || buffer->data64 != NULL)
         ++contract_failures;
      else {
         for (inner = 0U; inner < buffer->channel_count && inner < 8U; ++inner)
            input_addresses[address_index++] =
               (uintptr_t)buffer->data32[inner];
      }
   }
   address_index = 0U;
   for (channel = 0U; channel < process->audio_outputs_count; ++channel) {
      clap_audio_buffer_t *buffer = &process->audio_outputs[channel];
      uint32_t inner;
      if (buffer->data32 == NULL || buffer->data64 != NULL)
         ++contract_failures;
      else {
         for (inner = 0U; inner < buffer->channel_count && inner < 8U; ++inner)
            output_addresses[address_index++] =
               (uintptr_t)buffer->data32[inner];
      }
   }

   if (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_TONE) {
      clap_audio_buffer_t *output = &process->audio_outputs[0];
      if (output->channel_count != 2U)
         ++contract_failures;
      for (channel = 0U; channel < process->frames_count; ++channel) {
         output->data32[0][channel] = 1000.0f + (float)channel;
         output->data32[1][channel] = 2000.0f + (float)channel;
      }
   } else if (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_MULTI) {
      if (process->audio_inputs_count != 2U ||
          process->audio_outputs_count != 2U ||
          process->audio_inputs[0].channel_count != 2U ||
          process->audio_inputs[1].channel_count != 1U ||
          process->audio_outputs[0].channel_count != 2U ||
          process->audio_outputs[1].channel_count != 1U)
         ++contract_failures;
      for (channel = 0U; channel < process->frames_count; ++channel) {
         process->audio_outputs[0].data32[0][channel] =
            process->audio_inputs[0].data32[0][channel] * 2.0f;
         process->audio_outputs[0].data32[1][channel] =
            process->audio_inputs[0].data32[1][channel] * 2.0f;
         process->audio_outputs[1].data32[0][channel] =
            process->audio_inputs[1].data32[0][channel] * 3.0f;
      }
   } else {
      if (process->audio_inputs_count != 1U ||
          process->audio_inputs[0].channel_count != 2U ||
          process->audio_outputs[0].channel_count != 2U)
         ++contract_failures;
      for (channel = 0U; channel < process->frames_count; ++channel) {
         process->audio_outputs[0].data32[0][channel] =
            process->audio_inputs[0].data32[0][channel] * 2.0f;
         process->audio_outputs[0].data32[1][channel] =
            process->audio_inputs[0].data32[1][channel] * 2.0f;
      }
   }

   ++process_count;
   record_lifecycle(3);
   if (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_PROCESS_ERROR)
      last_process_status = CLAP_PROCESS_ERROR;
   else if (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_PROCESS_SLEEP)
      last_process_status = CLAP_PROCESS_SLEEP;
   else if (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_PROCESS_TAIL)
      last_process_status = CLAP_PROCESS_TAIL;
   else if (PLUGINHOST_AUDIO_FIXTURE_MODE == MODE_PROCESS_CONTINUE_IF_NOT_QUIET)
      last_process_status = CLAP_PROCESS_CONTINUE_IF_NOT_QUIET;
   else
      last_process_status = CLAP_PROCESS_CONTINUE;
   return (clap_process_status)last_process_status;
}

static const void *fixture_plugin_get_extension(const clap_plugin_t *plugin,
                                                const char *extension_id) {
   (void)plugin;
   if (extension_id != NULL && strcmp(extension_id, CLAP_EXT_AUDIO_PORTS) == 0)
      return &fixture_audio_ports;
   return NULL;
}

static void fixture_plugin_on_main_thread(const clap_plugin_t *plugin) {
   (void)plugin;
}

static const clap_plugin_t fixture_plugin = {
   .desc = &fixture_descriptor,
   .plugin_data = NULL,
   .init = fixture_plugin_init,
   .destroy = fixture_plugin_destroy,
   .activate = fixture_plugin_activate,
   .deactivate = fixture_plugin_deactivate,
   .start_processing = fixture_plugin_start_processing,
   .stop_processing = fixture_plugin_stop_processing,
   .reset = fixture_plugin_reset,
   .process = fixture_plugin_process,
   .get_extension = fixture_plugin_get_extension,
   .on_main_thread = fixture_plugin_on_main_thread,
};

static uint32_t fixture_get_plugin_count(const clap_plugin_factory_t *factory) {
   (void)factory;
   return 1U;
}

static const clap_plugin_descriptor_t *fixture_get_plugin_descriptor(
    const clap_plugin_factory_t *factory, uint32_t index) {
   (void)factory;
   return index == 0U ? &fixture_descriptor : NULL;
}

static const clap_plugin_t *fixture_create_plugin(
    const clap_plugin_factory_t *factory, const clap_host_t *host,
    const char *plugin_id) {
   (void)factory;
   if (host == NULL || plugin_id == NULL ||
       strcmp(plugin_id, fixture_descriptor.id) != 0)
      return NULL;
   fixture_host = host;
   return &fixture_plugin;
}

static const clap_plugin_factory_t fixture_factory = {
   .get_plugin_count = fixture_get_plugin_count,
   .get_plugin_descriptor = fixture_get_plugin_descriptor,
   .create_plugin = fixture_create_plugin,
};

static const void *fixture_entry_get_factory(const char *factory_id) {
   if (factory_id == NULL || strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) != 0)
      return NULL;
   return &fixture_factory;
}

CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
   .clap_version = CLAP_VERSION_INIT,
   .init = fixture_entry_init,
   .deinit = fixture_entry_deinit,
   .get_factory = fixture_entry_get_factory,
};

AUDIO_FIXTURE_EXPORT void pluginhost_audio_fixture_reset(void) {
   fixture_host = NULL;
   activate_count = 0U;
   deactivate_count = 0U;
   start_count = 0U;
   stop_count = 0U;
   process_count = 0U;
   destroy_count = 0U;
   contract_failures = 0U;
   last_activate_sample_rate = 0.0;
   last_activate_min_frames = 0U;
   last_activate_max_frames = 0U;
   last_process_status = -1;
   last_steady_time = -1;
   last_frames = 0U;
   last_input_groups = 0U;
   last_output_groups = 0U;
   last_transport_null = false;
   last_data64_null = false;
   memset(input_addresses, 0, sizeof(input_addresses));
   memset(output_addresses, 0, sizeof(output_addresses));
   memset(lifecycle_order, 0, sizeof(lifecycle_order));
   lifecycle_order_count = 0U;
}

#define EXPORT_COUNTER(name, value) \
   AUDIO_FIXTURE_EXPORT uint32_t name(void) { return (value); }

EXPORT_COUNTER(pluginhost_audio_fixture_activate_calls, activate_count)
EXPORT_COUNTER(pluginhost_audio_fixture_deactivate_calls, deactivate_count)
EXPORT_COUNTER(pluginhost_audio_fixture_start_calls, start_count)
EXPORT_COUNTER(pluginhost_audio_fixture_stop_calls, stop_count)
EXPORT_COUNTER(pluginhost_audio_fixture_process_calls, process_count)
EXPORT_COUNTER(pluginhost_audio_fixture_destroy_calls, destroy_count)
EXPORT_COUNTER(pluginhost_audio_fixture_contract_failures, contract_failures)
EXPORT_COUNTER(pluginhost_audio_fixture_last_activate_min_frames,
               last_activate_min_frames)
EXPORT_COUNTER(pluginhost_audio_fixture_last_activate_max_frames,
               last_activate_max_frames)

AUDIO_FIXTURE_EXPORT double
pluginhost_audio_fixture_last_activate_sample_rate(void) {
   return last_activate_sample_rate;
}

AUDIO_FIXTURE_EXPORT int32_t pluginhost_audio_fixture_last_status(void) {
   return last_process_status;
}
AUDIO_FIXTURE_EXPORT int64_t pluginhost_audio_fixture_last_steady_time(void) {
   return last_steady_time;
}
AUDIO_FIXTURE_EXPORT uint32_t pluginhost_audio_fixture_last_frames(void) {
   return last_frames;
}
AUDIO_FIXTURE_EXPORT uint32_t pluginhost_audio_fixture_last_input_groups(void) {
   return last_input_groups;
}
AUDIO_FIXTURE_EXPORT uint32_t pluginhost_audio_fixture_last_output_groups(void) {
   return last_output_groups;
}
AUDIO_FIXTURE_EXPORT int pluginhost_audio_fixture_transport_was_null(void) {
   return last_transport_null ? 1 : 0;
}
AUDIO_FIXTURE_EXPORT int pluginhost_audio_fixture_data64_was_null(void) {
   return last_data64_null ? 1 : 0;
}
AUDIO_FIXTURE_EXPORT uint64_t pluginhost_audio_fixture_input_address(int index) {
   if (index < 0 || index >= 8)
      return 0U;
   return (uint64_t)input_addresses[index];
}
AUDIO_FIXTURE_EXPORT uint64_t pluginhost_audio_fixture_output_address(int index) {
   if (index < 0 || index >= 8)
      return 0U;
   return (uint64_t)output_addresses[index];
}
AUDIO_FIXTURE_EXPORT uint32_t pluginhost_audio_fixture_lifecycle_count(void) {
   return lifecycle_order_count;
}
AUDIO_FIXTURE_EXPORT int pluginhost_audio_fixture_lifecycle_at(int index) {
   if (index < 0 || (uint32_t)index >= lifecycle_order_count)
      return -1;
   return lifecycle_order[index];
}
