#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <clap/entry.h>
#include <clap/ext/audio-ports.h>
#include <clap/ext/note-ports.h>
#include <clap/ext/render.h>
#include <clap/ext/thread-check.h>
#include <clap/factory/plugin-factory.h>

#if defined(__GNUC__) || defined(__clang__)
#define PORT_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define PORT_FIXTURE_EXPORT
#endif

#ifndef PLUGINHOST_PORT_FIXTURE_MODE
#define PLUGINHOST_PORT_FIXTURE_MODE 0
#endif

#define MODE_VALID 0
#define MODE_NO_EXTENSIONS 1
#define MODE_AUDIO_MISSING_COUNT 2
#define MODE_AUDIO_MISSING_GET 3
#define MODE_AUDIO_TOO_MANY 4
#define MODE_AUDIO_GET_FAIL 5
#define MODE_AUDIO_INVALID_ID 6
#define MODE_AUDIO_DUPLICATE_ID 7
#define MODE_AUDIO_ZERO_CHANNELS 8
#define MODE_AUDIO_UNTERMINATED_NAME 9
#define MODE_AUDIO_OVERSIZED_TYPE 10
#define MODE_AUDIO_INCONSISTENT 11
#define MODE_AUDIO_BAD_PAIR 12
#define MODE_AUDIO_TOO_MANY_CHANNELS 13
#define MODE_NOTE_MISSING_COUNT 14
#define MODE_NOTE_MISSING_GET 15
#define MODE_NOTE_TOO_MANY 16
#define MODE_NOTE_GET_FAIL 17
#define MODE_NOTE_INVALID_ID 18
#define MODE_NOTE_DUPLICATE_ID 19
#define MODE_NOTE_UNTERMINATED_NAME 20
#define MODE_NOTE_BAD_SUPPORTED 21
#define MODE_NOTE_BAD_PREFERRED 22
#define MODE_RENDER_MISSING_SET 23
#define MODE_RENDER_REJECT 24
#define MODE_RENDER_HARD 25
#define MODE_AUDIO_BAD_TYPE 26
#define MODE_AUDIO_BAD_PREFERENCE 27
#define MODE_RENDER_MISSING_REQUIREMENT 28
#define MODE_EXACT_LIMITS 29
#define MODE_AUDIO_DANGLING_ZERO_PAIR 30

#define MAX_PORT_TYPE_BYTES (4U * 1024U)

static const clap_host_t *fixture_host;
static uint32_t deinit_count;
static uint32_t destroy_count;
static uint32_t audio_count_calls;
static uint32_t audio_get_calls;
static uint32_t note_count_calls;
static uint32_t note_get_calls;
static uint32_t render_requirement_calls;
static uint32_t render_set_calls;
static uint32_t contract_failures;
static int32_t last_render_mode;
static char oversized_port_type[MAX_PORT_TYPE_BYTES + 1U];
static char exact_port_type[MAX_PORT_TYPE_BYTES];

static const char *fixture_features[] = {NULL};
static const clap_plugin_descriptor_t fixture_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.ports",
   .name = "Fixture Ports",
   .vendor = "pluginhost",
   .version = "1.0.0",
   .features = fixture_features,
};

static void expect_main_thread(void) {
   if (fixture_host == NULL || fixture_host->get_extension == NULL) {
      ++contract_failures;
      return;
   }
   const clap_host_thread_check_t *thread_check =
      (const clap_host_thread_check_t *)fixture_host->get_extension(
         fixture_host, CLAP_EXT_THREAD_CHECK);
   if (thread_check == NULL || thread_check->is_main_thread == NULL ||
       !thread_check->is_main_thread(fixture_host))
      ++contract_failures;
}

static bool fixture_entry_init(const char *plugin_path) {
   if (plugin_path == NULL || plugin_path[0] == '\0')
      return false;
   memset(oversized_port_type, 'x', MAX_PORT_TYPE_BYTES);
   oversized_port_type[MAX_PORT_TYPE_BYTES] = '\0';
   memset(exact_port_type, 'e', sizeof(exact_port_type));
   exact_port_type[sizeof(exact_port_type) - 1U] = '\0';
   return true;
}

static void fixture_entry_deinit(void) {
   ++deinit_count;
}

static uint32_t fixture_audio_count(const clap_plugin_t *plugin,
                                    bool is_input) {
   (void)plugin;
   ++audio_count_calls;
   expect_main_thread();
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_TOO_MANY && is_input)
      return 1025U;
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_EXACT_LIMITS)
      return 1024U;
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_DANGLING_ZERO_PAIR)
      return is_input ? 0U : 1U;
   return 2U;
}

static void set_audio_name(clap_audio_port_info_t *info,
                           const char *name) {
   (void)snprintf(info->name, sizeof(info->name), "%s", name);
}

static bool fixture_audio_get(const clap_plugin_t *plugin,
                              uint32_t index,
                              bool is_input,
                              clap_audio_port_info_t *info) {
   (void)plugin;
   ++audio_get_calls;
   expect_main_thread();
   if (info == NULL)
      return false;
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_DANGLING_ZERO_PAIR) {
      if (is_input || index != 0U)
         return false;
      memset(info, 0, sizeof(*info));
      info->id = 0U;
      set_audio_name(info, "Hive Output");
      info->flags = CLAP_AUDIO_PORT_IS_MAIN;
      info->channel_count = 2U;
      info->port_type = CLAP_PORT_STEREO;
      info->in_place_pair = 0U;
      return true;
   }
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_EXACT_LIMITS) {
      if (index >= 1024U)
         return false;
      memset(info, 0, sizeof(*info));
      info->id = index;
      (void)snprintf(info->name, sizeof(info->name),
                     "%s %u", is_input ? "Input" : "Output", index);
      info->channel_count = 4U;
      info->port_type = exact_port_type;
      info->in_place_pair = CLAP_INVALID_ID;
      return true;
   }
   if (index >= 2U)
      return false;
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_GET_FAIL &&
       is_input && index == 0U)
      return false;

   memset(info, 0, sizeof(*info));
   info->in_place_pair = CLAP_INVALID_ID;
   if (is_input && index == 0U) {
      info->id = 10U;
      set_audio_name(info, "Main Input");
      info->flags = CLAP_AUDIO_PORT_IS_MAIN |
                    CLAP_AUDIO_PORT_SUPPORTS_64BITS |
                    CLAP_AUDIO_PORT_REQUIRES_COMMON_SAMPLE_SIZE;
      info->channel_count = 2U;
      info->port_type = CLAP_PORT_STEREO;
      info->in_place_pair = 20U;
   } else if (is_input) {
      info->id = 11U;
      set_audio_name(info, "Sidechain");
      info->flags = 1U << 31;
      info->channel_count = 1U;
      info->port_type = CLAP_PORT_MONO;
   } else if (index == 0U) {
      info->id = 20U;
      set_audio_name(info, "Main Output");
      info->flags = CLAP_AUDIO_PORT_IS_MAIN |
                    CLAP_AUDIO_PORT_SUPPORTS_64BITS |
                    CLAP_AUDIO_PORT_PREFERS_64BITS |
                    CLAP_AUDIO_PORT_REQUIRES_COMMON_SAMPLE_SIZE;
      info->channel_count = 2U;
      info->port_type = CLAP_PORT_STEREO;
      info->in_place_pair = 10U;
   } else {
      static const char invalid_utf8_name[] = {
         'W', 'e', 't', (char)0xff, ' ', 'O', 'u', 't', '\0'
      };
      info->id = 21U;
      memcpy(info->name, invalid_utf8_name, sizeof(invalid_utf8_name));
      info->channel_count = 3U;
      info->port_type = "org.pluginhost.fixture.triplet";
   }

   if (is_input && index == 0U) {
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_INVALID_ID)
         info->id = CLAP_INVALID_ID;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_ZERO_CHANNELS)
         info->channel_count = 0U;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_UNTERMINATED_NAME)
         memset(info->name, 'n', sizeof(info->name));
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_OVERSIZED_TYPE)
         info->port_type = oversized_port_type;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_BAD_PAIR)
         info->in_place_pair = 999U;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_TOO_MANY_CHANNELS)
         info->channel_count = 4097U;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_BAD_TYPE) {
         info->channel_count = 1U;
         info->port_type = CLAP_PORT_STEREO;
      }
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_BAD_PREFERENCE)
         info->flags = CLAP_AUDIO_PORT_PREFERS_64BITS;
   }
   if (is_input && index == 1U) {
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_DUPLICATE_ID)
         info->id = 10U;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_INCONSISTENT)
         info->flags |= CLAP_AUDIO_PORT_IS_MAIN;
   }
   return true;
}

static const clap_plugin_audio_ports_t fixture_audio_ports = {
   .count = fixture_audio_count,
   .get = fixture_audio_get,
};
static const clap_plugin_audio_ports_t fixture_audio_missing_count = {
   .count = NULL,
   .get = fixture_audio_get,
};
static const clap_plugin_audio_ports_t fixture_audio_missing_get = {
   .count = fixture_audio_count,
   .get = NULL,
};

static uint32_t fixture_note_count(const clap_plugin_t *plugin,
                                   bool is_input) {
   (void)plugin;
   ++note_count_calls;
   expect_main_thread();
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_NOTE_TOO_MANY && is_input)
      return 1025U;
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_EXACT_LIMITS)
      return 1024U;
   return is_input ? 2U : 1U;
}

static bool fixture_note_get(const clap_plugin_t *plugin,
                             uint32_t index,
                             bool is_input,
                             clap_note_port_info_t *info) {
   (void)plugin;
   ++note_get_calls;
   expect_main_thread();
   if (info == NULL)
      return false;
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_EXACT_LIMITS) {
      if (index >= 1024U)
         return false;
      memset(info, 0, sizeof(*info));
      info->id = index;
      info->supported_dialects = CLAP_NOTE_DIALECT_CLAP;
      info->preferred_dialect = CLAP_NOTE_DIALECT_CLAP;
      (void)snprintf(info->name, sizeof(info->name),
                     "%s %u", is_input ? "Input" : "Output", index);
      return true;
   }
   if (index >= (is_input ? 2U : 1U))
      return false;
   if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_NOTE_GET_FAIL &&
       is_input && index == 0U)
      return false;

   memset(info, 0, sizeof(*info));
   if (is_input && index == 0U) {
      info->id = 30U;
      info->supported_dialects = CLAP_NOTE_DIALECT_CLAP |
                                 CLAP_NOTE_DIALECT_MIDI;
      info->preferred_dialect = CLAP_NOTE_DIALECT_MIDI;
      (void)snprintf(info->name, sizeof(info->name), "%s", "Notes In");
   } else if (is_input) {
      info->id = 31U;
      info->supported_dialects = CLAP_NOTE_DIALECT_MIDI |
                                 CLAP_NOTE_DIALECT_MIDI_MPE;
      info->preferred_dialect = CLAP_NOTE_DIALECT_MIDI_MPE;
      (void)snprintf(info->name, sizeof(info->name), "%s", "MPE In");
   } else {
      info->id = 30U;
      info->supported_dialects = CLAP_NOTE_DIALECT_CLAP;
      info->preferred_dialect = CLAP_NOTE_DIALECT_CLAP;
      (void)snprintf(info->name, sizeof(info->name), "%s", "Notes Out");
   }

   if (is_input && index == 0U) {
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_NOTE_INVALID_ID)
         info->id = CLAP_INVALID_ID;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_NOTE_UNTERMINATED_NAME)
         memset(info->name, 'n', sizeof(info->name));
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_NOTE_BAD_SUPPORTED)
         info->supported_dialects = 1U << 31;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_NOTE_BAD_PREFERRED)
         info->preferred_dialect = CLAP_NOTE_DIALECT_CLAP |
                                   CLAP_NOTE_DIALECT_MIDI;
   }
   if (is_input && index == 1U &&
       PLUGINHOST_PORT_FIXTURE_MODE == MODE_NOTE_DUPLICATE_ID)
      info->id = 30U;
   return true;
}

static const clap_plugin_note_ports_t fixture_note_ports = {
   .count = fixture_note_count,
   .get = fixture_note_get,
};
static const clap_plugin_note_ports_t fixture_note_missing_count = {
   .count = NULL,
   .get = fixture_note_get,
};
static const clap_plugin_note_ports_t fixture_note_missing_get = {
   .count = fixture_note_count,
   .get = NULL,
};

static bool fixture_has_hard_realtime_requirement(
   const clap_plugin_t *plugin) {
   (void)plugin;
   ++render_requirement_calls;
   expect_main_thread();
   return PLUGINHOST_PORT_FIXTURE_MODE == MODE_RENDER_HARD;
}

static bool fixture_set_render_mode(const clap_plugin_t *plugin,
                                    clap_plugin_render_mode mode) {
   (void)plugin;
   ++render_set_calls;
   last_render_mode = mode;
   expect_main_thread();
   if (mode != CLAP_RENDER_REALTIME)
      ++contract_failures;
   return PLUGINHOST_PORT_FIXTURE_MODE != MODE_RENDER_REJECT;
}

static const clap_plugin_render_t fixture_render = {
   .has_hard_realtime_requirement = fixture_has_hard_realtime_requirement,
   .set = fixture_set_render_mode,
};
static const clap_plugin_render_t fixture_render_missing_requirement = {
   .has_hard_realtime_requirement = NULL,
   .set = fixture_set_render_mode,
};
static const clap_plugin_render_t fixture_render_missing_set = {
   .has_hard_realtime_requirement = fixture_has_hard_realtime_requirement,
   .set = NULL,
};

static bool fixture_plugin_init(const clap_plugin_t *plugin) {
   (void)plugin;
   expect_main_thread();
   if (fixture_host == NULL || fixture_host->get_extension == NULL) {
      ++contract_failures;
   } else {
      const clap_host_audio_ports_t *audio = (const clap_host_audio_ports_t *)
         fixture_host->get_extension(fixture_host, CLAP_EXT_AUDIO_PORTS);
      const clap_host_note_ports_t *notes = (const clap_host_note_ports_t *)
         fixture_host->get_extension(fixture_host, CLAP_EXT_NOTE_PORTS);
      if (audio == NULL || audio->is_rescan_flag_supported == NULL ||
          audio->rescan == NULL ||
          !audio->is_rescan_flag_supported(fixture_host,
                                            CLAP_AUDIO_PORTS_RESCAN_NAMES) ||
          notes == NULL || notes->supported_dialects == NULL ||
          notes->rescan == NULL ||
          (notes->supported_dialects(fixture_host) &
           (CLAP_NOTE_DIALECT_CLAP | CLAP_NOTE_DIALECT_MIDI)) == 0U)
         ++contract_failures;
   }
   return true;
}

static void fixture_plugin_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
   ++destroy_count;
   expect_main_thread();
}

static bool fixture_plugin_activate(const clap_plugin_t *plugin,
                                    double sample_rate,
                                    uint32_t min_frames_count,
                                    uint32_t max_frames_count) {
   (void)plugin;
   (void)sample_rate;
   (void)min_frames_count;
   (void)max_frames_count;
   return true;
}
static void fixture_plugin_deactivate(const clap_plugin_t *plugin) {
   (void)plugin;
}
static bool fixture_plugin_start_processing(const clap_plugin_t *plugin) {
   (void)plugin;
   return true;
}
static void fixture_plugin_stop_processing(const clap_plugin_t *plugin) {
   (void)plugin;
}
static void fixture_plugin_reset(const clap_plugin_t *plugin) {
   (void)plugin;
}
static clap_process_status fixture_plugin_process(const clap_plugin_t *plugin,
                                                  const clap_process_t *process) {
   (void)plugin;
   (void)process;
   return CLAP_PROCESS_CONTINUE;
}

static const void *fixture_plugin_get_extension(const clap_plugin_t *plugin,
                                                const char *extension_id) {
   (void)plugin;
   if (extension_id == NULL ||
       PLUGINHOST_PORT_FIXTURE_MODE == MODE_NO_EXTENSIONS)
      return NULL;
   if (strcmp(extension_id, CLAP_EXT_AUDIO_PORTS) == 0) {
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_MISSING_COUNT)
         return &fixture_audio_missing_count;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_AUDIO_MISSING_GET)
         return &fixture_audio_missing_get;
      return &fixture_audio_ports;
   }
   if (strcmp(extension_id, CLAP_EXT_NOTE_PORTS) == 0) {
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_NOTE_MISSING_COUNT)
         return &fixture_note_missing_count;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_NOTE_MISSING_GET)
         return &fixture_note_missing_get;
      return &fixture_note_ports;
   }
   if (strcmp(extension_id, CLAP_EXT_RENDER) == 0) {
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_RENDER_MISSING_REQUIREMENT)
         return &fixture_render_missing_requirement;
      if (PLUGINHOST_PORT_FIXTURE_MODE == MODE_RENDER_MISSING_SET)
         return &fixture_render_missing_set;
      return &fixture_render;
   }
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
   const clap_plugin_factory_t *factory,
   uint32_t index) {
   (void)factory;
   return index == 0U ? &fixture_descriptor : NULL;
}
static const clap_plugin_t *fixture_create_plugin(
   const clap_plugin_factory_t *factory,
   const clap_host_t *host,
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

PORT_FIXTURE_EXPORT void pluginhost_port_fixture_reset(void) {
   deinit_count = 0U;
   destroy_count = 0U;
   audio_count_calls = 0U;
   audio_get_calls = 0U;
   note_count_calls = 0U;
   note_get_calls = 0U;
   render_requirement_calls = 0U;
   render_set_calls = 0U;
   contract_failures = 0U;
   last_render_mode = -1;
   fixture_host = NULL;
}

#define EXPORT_COUNTER(name, value) \
   PORT_FIXTURE_EXPORT uint32_t name(void) { return (value); }

EXPORT_COUNTER(pluginhost_port_fixture_deinit_calls, deinit_count)
EXPORT_COUNTER(pluginhost_port_fixture_destroy_calls, destroy_count)
EXPORT_COUNTER(pluginhost_port_fixture_audio_count_calls, audio_count_calls)
EXPORT_COUNTER(pluginhost_port_fixture_audio_get_calls, audio_get_calls)
EXPORT_COUNTER(pluginhost_port_fixture_note_count_calls, note_count_calls)
EXPORT_COUNTER(pluginhost_port_fixture_note_get_calls, note_get_calls)
EXPORT_COUNTER(pluginhost_port_fixture_render_requirement_calls,
               render_requirement_calls)
EXPORT_COUNTER(pluginhost_port_fixture_render_set_calls, render_set_calls)
EXPORT_COUNTER(pluginhost_port_fixture_contract_failures, contract_failures)

PORT_FIXTURE_EXPORT int32_t pluginhost_port_fixture_last_render_mode(void) {
   return last_render_mode;
}
