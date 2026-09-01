#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

#include <clap/entry.h>
#include <clap/events.h>
#include <clap/ext/note-ports.h>
#include <clap/ext/thread-check.h>
#include <clap/factory/plugin-factory.h>
#include <clap/plugin-features.h>

#if defined(__GNUC__) || defined(__clang__)
#define EVENT_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define EVENT_FIXTURE_EXPORT
#endif

#ifndef PLUGINHOST_EVENT_FIXTURE_MODE
#define PLUGINHOST_EVENT_FIXTURE_MODE 0
#endif

#define MODE_RAW 0
#define MODE_CLAP 1
#define MODE_MIDI2_ONLY 2
#define MODE_MALFORMED_OUTPUT 3
#define OBSERVED_CAPACITY 4096U

typedef struct observed_event {
   uint16_t type;
   uint32_t time;
   uint32_t flags;
   int32_t port;
   int32_t channel;
   int32_t key;
   int32_t expression;
   double value;
   uint32_t size;
   uint8_t data[8];
   uintptr_t address;
} observed_event_t;

static const clap_host_t *fixture_host;
static observed_event_t observed[OBSERVED_CAPACITY];
static uint32_t observed_count;
static uint32_t process_count;
static uint32_t output_accepted;
static uint32_t output_rejected;
static uint32_t contract_failures;
static uint32_t destroy_count;
static bool malformed_emitted;
static clap_process_status process_status = CLAP_PROCESS_CONTINUE;

static const char *fixture_features[] = {
   CLAP_PLUGIN_FEATURE_NOTE_EFFECT,
   NULL,
};

static const clap_plugin_descriptor_t fixture_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.events",
   .name = "Fixture Events",
   .vendor = "pluginhost",
   .version = "1.0.0",
   .features = fixture_features,
};

static bool is_audio_thread(void) {
   if (fixture_host == NULL || fixture_host->get_extension == NULL)
      return false;
   const clap_host_thread_check_t *check =
      (const clap_host_thread_check_t *)fixture_host->get_extension(
         fixture_host, CLAP_EXT_THREAD_CHECK);
   return check != NULL && check->is_audio_thread != NULL &&
      check->is_audio_thread(fixture_host);
}

static bool fixture_entry_init(const char *path) {
   return path != NULL && path[0] != '\0';
}

static void fixture_entry_deinit(void) {
}

static uint32_t fixture_note_count(const clap_plugin_t *plugin, bool is_input) {
   (void)plugin;
   if (PLUGINHOST_EVENT_FIXTURE_MODE == MODE_RAW)
      return 2U;
   if (PLUGINHOST_EVENT_FIXTURE_MODE == MODE_CLAP)
      return 1U;
   if (PLUGINHOST_EVENT_FIXTURE_MODE == MODE_MIDI2_ONLY)
      return is_input ? 1U : 0U;
   return is_input ? 0U : 1U;
}

static bool fixture_note_get(const clap_plugin_t *plugin, uint32_t index,
                             bool is_input, clap_note_port_info_t *info) {
   (void)plugin;
   const uint32_t count = fixture_note_count(plugin, is_input);
   if (info == NULL || index >= count)
      return false;
   memset(info, 0, sizeof(*info));
   info->id = (is_input ? 100U : 200U) + index;
   if (PLUGINHOST_EVENT_FIXTURE_MODE == MODE_CLAP) {
      info->supported_dialects = CLAP_NOTE_DIALECT_CLAP;
      info->preferred_dialect = CLAP_NOTE_DIALECT_CLAP;
   } else if (PLUGINHOST_EVENT_FIXTURE_MODE == MODE_MIDI2_ONLY) {
      info->supported_dialects = CLAP_NOTE_DIALECT_MIDI2;
      info->preferred_dialect = CLAP_NOTE_DIALECT_MIDI2;
   } else if (PLUGINHOST_EVENT_FIXTURE_MODE == MODE_MALFORMED_OUTPUT) {
      info->supported_dialects = CLAP_NOTE_DIALECT_MIDI |
                                 CLAP_NOTE_DIALECT_CLAP;
      info->preferred_dialect = CLAP_NOTE_DIALECT_MIDI;
   } else {
      info->supported_dialects = CLAP_NOTE_DIALECT_MIDI;
      info->preferred_dialect = CLAP_NOTE_DIALECT_MIDI;
   }
   const char *name = is_input ? "Events Input" : "Events Output";
   memcpy(info->name, name, strlen(name) + 1U);
   return true;
}

static const clap_plugin_note_ports_t fixture_note_ports = {
   .count = fixture_note_count,
   .get = fixture_note_get,
};

static void observe(const clap_event_header_t *header) {
   if (header == NULL || observed_count >= OBSERVED_CAPACITY)
      return;
   observed_event_t *destination = &observed[observed_count++];
   memset(destination, 0, sizeof(*destination));
   destination->type = header->type;
   destination->time = header->time;
   destination->flags = header->flags;
   if (header->type == CLAP_EVENT_MIDI &&
       header->size >= sizeof(clap_event_midi_t)) {
      const clap_event_midi_t *event = (const clap_event_midi_t *)header;
      destination->port = event->port_index;
      destination->size = 3U;
      memcpy(destination->data, event->data, 3U);
   } else if (header->type == CLAP_EVENT_MIDI_SYSEX &&
              header->size >= sizeof(clap_event_midi_sysex_t)) {
      const clap_event_midi_sysex_t *event =
         (const clap_event_midi_sysex_t *)header;
      destination->port = event->port_index;
      destination->size = event->size;
      destination->address = (uintptr_t)event->buffer;
      const uint32_t copied = event->size < sizeof(destination->data)
         ? event->size : (uint32_t)sizeof(destination->data);
      if (event->buffer != NULL)
         memcpy(destination->data, event->buffer, copied);
   } else if ((header->type == CLAP_EVENT_NOTE_ON ||
               header->type == CLAP_EVENT_NOTE_OFF) &&
              header->size >= sizeof(clap_event_note_t)) {
      const clap_event_note_t *event = (const clap_event_note_t *)header;
      destination->port = event->port_index;
      destination->channel = event->channel;
      destination->key = event->key;
      destination->value = event->velocity;
   } else if (header->type == CLAP_EVENT_NOTE_EXPRESSION &&
              header->size >= sizeof(clap_event_note_expression_t)) {
      const clap_event_note_expression_t *event =
         (const clap_event_note_expression_t *)header;
      destination->port = event->port_index;
      destination->channel = event->channel;
      destination->key = event->key;
      destination->expression = event->expression_id;
      destination->value = event->value;
   }
}

static void push_event(const clap_output_events_t *output,
                       const clap_event_header_t *event) {
   if (output != NULL && output->try_push != NULL &&
       output->try_push(output, event))
      ++output_accepted;
   else
      ++output_rejected;
}

static void emit_malformed_output(const clap_output_events_t *output) {
   clap_event_midi_t valid = {
      .header = {sizeof(valid), 5U, CLAP_CORE_EVENT_SPACE_ID,
                 CLAP_EVENT_MIDI, 0U},
      .port_index = 0U,
      .data = {0x90U, 60U, 100U},
   };
   push_event(output, &valid.header);

   clap_event_midi_t out_of_order = valid;
   out_of_order.header.time = 4U;
   push_event(output, &out_of_order.header);

   clap_event_midi_t bad_port = valid;
   bad_port.header.time = 6U;
   bad_port.port_index = 1U;
   push_event(output, &bad_port.header);

   clap_event_param_gesture_t unsupported = {
      .header = {sizeof(unsupported), 7U, CLAP_CORE_EVENT_SPACE_ID,
                 CLAP_EVENT_PARAM_GESTURE_BEGIN, 0U},
      .param_id = 1U,
   };
   push_event(output, &unsupported.header);

   uint8_t sysex_data[] = {0xf0U, 0x01U, 0x02U, 0xf7U};
   clap_event_midi_sysex_t sysex = {
      .header = {sizeof(sysex), 8U, CLAP_CORE_EVENT_SPACE_ID,
                 CLAP_EVENT_MIDI_SYSEX, 0U},
      .port_index = 0U,
      .buffer = sysex_data,
      .size = sizeof(sysex_data),
   };
   push_event(output, &sysex.header);
   memset(sysex_data, 0, sizeof(sysex_data));

   clap_event_midi_t bad_size = valid;
   bad_size.header.time = 9U;
   bad_size.header.size = sizeof(clap_event_header_t);
   push_event(output, &bad_size.header);

   clap_event_midi_t bad_space = valid;
   bad_space.header.time = 9U;
   bad_space.header.space_id = 1U;
   push_event(output, &bad_space.header);

   clap_event_midi_t bad_time = valid;
   bad_time.header.time = 64U;
   push_event(output, &bad_time.header);

   clap_event_note_t bad_velocity = {
      .header = {sizeof(bad_velocity), 10U, CLAP_CORE_EVENT_SPACE_ID,
                 CLAP_EVENT_NOTE_ON, 0U},
      .note_id = -1,
      .port_index = 0,
      .channel = 0,
      .key = 60,
      .velocity = NAN,
   };
   push_event(output, &bad_velocity.header);
}

static bool fixture_plugin_init(const clap_plugin_t *plugin) {
   (void)plugin;
   if (fixture_host == NULL || fixture_host->get_extension == NULL ||
       fixture_host->get_extension(fixture_host, CLAP_EXT_NOTE_PORTS) != NULL)
      ++contract_failures;
   return true;
}

static void fixture_plugin_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
   ++destroy_count;
}

static bool fixture_plugin_activate(const clap_plugin_t *plugin,
                                    double sample_rate,
                                    uint32_t min_frames,
                                    uint32_t max_frames) {
   (void)plugin;
   return sample_rate > 0.0 && min_frames > 0U && max_frames >= min_frames;
}

static void fixture_plugin_deactivate(const clap_plugin_t *plugin) {
   (void)plugin;
}

static bool fixture_plugin_start(const clap_plugin_t *plugin) {
   (void)plugin;
   return true;
}

static void fixture_plugin_stop(const clap_plugin_t *plugin) {
   (void)plugin;
}

static void fixture_plugin_reset(const clap_plugin_t *plugin) {
   (void)plugin;
}

static clap_process_status fixture_plugin_process(const clap_plugin_t *plugin,
                                                   const clap_process_t *process) {
   (void)plugin;
   if (!is_audio_thread() || process == NULL || process->in_events == NULL ||
       process->out_events == NULL || process->in_events->size == NULL ||
       process->in_events->get == NULL || process->out_events->try_push == NULL) {
      ++contract_failures;
      return CLAP_PROCESS_ERROR;
   }
   const uint32_t count = process->in_events->size(process->in_events);
   uint32_t previous_time = 0U;
   for (uint32_t index = 0U; index < count; ++index) {
      const clap_event_header_t *event =
         process->in_events->get(process->in_events, index);
      if (event == NULL || (index > 0U && event->time < previous_time)) {
         ++contract_failures;
         continue;
      }
      previous_time = event->time;
      observe(event);
      if (PLUGINHOST_EVENT_FIXTURE_MODE == MODE_RAW &&
          (event->type == CLAP_EVENT_MIDI ||
           event->type == CLAP_EVENT_MIDI_SYSEX)) {
         push_event(process->out_events, event);
      } else if (PLUGINHOST_EVENT_FIXTURE_MODE == MODE_CLAP &&
                 (event->type == CLAP_EVENT_NOTE_ON ||
                  event->type == CLAP_EVENT_NOTE_OFF)) {
         push_event(process->out_events, event);
      }
   }
   if (PLUGINHOST_EVENT_FIXTURE_MODE == MODE_MALFORMED_OUTPUT &&
       !malformed_emitted) {
      emit_malformed_output(process->out_events);
      malformed_emitted = true;
   }
   ++process_count;
   return process_status;
}

static const void *fixture_plugin_get_extension(const clap_plugin_t *plugin,
                                                 const char *extension_id) {
   (void)plugin;
   if (extension_id != NULL && strcmp(extension_id, CLAP_EXT_NOTE_PORTS) == 0)
      return &fixture_note_ports;
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
   .start_processing = fixture_plugin_start,
   .stop_processing = fixture_plugin_stop,
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

EVENT_FIXTURE_EXPORT void pluginhost_event_fixture_reset(void) {
   fixture_host = NULL;
   memset(observed, 0, sizeof(observed));
   observed_count = 0U;
   process_count = 0U;
   output_accepted = 0U;
   output_rejected = 0U;
   contract_failures = 0U;
   destroy_count = 0U;
   malformed_emitted = false;
   process_status = CLAP_PROCESS_CONTINUE;
}

EVENT_FIXTURE_EXPORT void pluginhost_event_fixture_set_process_status(
    int32_t status) {
   process_status = (clap_process_status)status;
}

#define EXPORT_COUNT(name, value) \
   EVENT_FIXTURE_EXPORT uint32_t name(void) { return (value); }
EXPORT_COUNT(pluginhost_event_fixture_observed_count, observed_count)
EXPORT_COUNT(pluginhost_event_fixture_process_count, process_count)
EXPORT_COUNT(pluginhost_event_fixture_output_accepted, output_accepted)
EXPORT_COUNT(pluginhost_event_fixture_output_rejected, output_rejected)
EXPORT_COUNT(pluginhost_event_fixture_contract_failures, contract_failures)
EXPORT_COUNT(pluginhost_event_fixture_destroy_count, destroy_count)

EVENT_FIXTURE_EXPORT uint32_t pluginhost_event_fixture_type(uint32_t index) {
   return index < observed_count ? observed[index].type : UINT32_MAX;
}
EVENT_FIXTURE_EXPORT uint32_t pluginhost_event_fixture_time(uint32_t index) {
   return index < observed_count ? observed[index].time : UINT32_MAX;
}
EVENT_FIXTURE_EXPORT uint32_t pluginhost_event_fixture_flags(uint32_t index) {
   return index < observed_count ? observed[index].flags : 0U;
}
EVENT_FIXTURE_EXPORT int32_t pluginhost_event_fixture_port(uint32_t index) {
   return index < observed_count ? observed[index].port : -1;
}
EVENT_FIXTURE_EXPORT int32_t pluginhost_event_fixture_channel(uint32_t index) {
   return index < observed_count ? observed[index].channel : -1;
}
EVENT_FIXTURE_EXPORT int32_t pluginhost_event_fixture_key(uint32_t index) {
   return index < observed_count ? observed[index].key : -1;
}
EVENT_FIXTURE_EXPORT int32_t pluginhost_event_fixture_expression(uint32_t index) {
   return index < observed_count ? observed[index].expression : -1;
}
EVENT_FIXTURE_EXPORT double pluginhost_event_fixture_value(uint32_t index) {
   return index < observed_count ? observed[index].value : -1.0;
}
EVENT_FIXTURE_EXPORT uint32_t pluginhost_event_fixture_size(uint32_t index) {
   return index < observed_count ? observed[index].size : 0U;
}
EVENT_FIXTURE_EXPORT int pluginhost_event_fixture_byte(uint32_t index,
                                                       uint32_t byte_index) {
   return index < observed_count && byte_index < sizeof(observed[index].data)
      ? observed[index].data[byte_index] : -1;
}
EVENT_FIXTURE_EXPORT uint64_t pluginhost_event_fixture_address(uint32_t index) {
   return index < observed_count ? (uint64_t)observed[index].address : 0U;
}
