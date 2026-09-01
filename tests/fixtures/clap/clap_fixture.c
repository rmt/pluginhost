#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

#include <clap/entry.h>
#include <clap/ext/audio-ports.h>
#include <clap/ext/log.h>
#include <clap/ext/note-ports.h>
#include <clap/ext/thread-check.h>
#include <clap/factory/plugin-factory.h>
#include <clap/plugin-features.h>

#if defined(__GNUC__) || defined(__clang__)
#define PLUGINHOST_FIXTURE_EXPORT __attribute__((visibility("default")))
#define PLUGINHOST_FIXTURE_UNUSED __attribute__((unused))
#else
#define PLUGINHOST_FIXTURE_EXPORT
#define PLUGINHOST_FIXTURE_UNUSED
#endif

#ifndef PLUGINHOST_CLAP_FIXTURE_MODE
#define PLUGINHOST_CLAP_FIXTURE_MODE 0
#endif

#define MODE_VALID 0
#define MODE_INCOMPATIBLE_ENTRY 1
#define MODE_INIT_FAIL 2
#define MODE_MISSING_FACTORY 3
#define MODE_NULL_DESCRIPTOR 4
#define MODE_BLANK_ID 5
#define MODE_BLANK_NAME 6
#define MODE_INVALID_UTF8 7
#define MODE_DUPLICATE_ID 8
#define MODE_TOO_MANY_DESCRIPTORS 9
#define MODE_OVERSIZED_TEXT 10
#define MODE_TOO_MANY_FEATURES 11
#define MODE_MISSING_FACTORY_CALLBACK 12
#define MODE_MISSING_ENTRY_CALLBACK 13
#define MODE_EXACT_LIMITS 14
#define MODE_TOO_MUCH_METADATA 15
#define MODE_INCOMPATIBLE_DESCRIPTOR 16
#define MODE_NULL_ID 17
#define MODE_ZERO_DESCRIPTORS 18
#define MODE_CREATE_GUARD 19
#define MODE_PLUGIN_INIT_FAIL 20
#define MODE_CREATE_FAIL 21
#define MODE_MISSING_PLUGIN_DESTROY 22
#define MODE_PLUGIN_WRONG_ID 23
#define MODE_PLUGIN_INCOMPATIBLE_DESCRIPTOR 24

#define MAX_TEXT_BYTES (64U * 1024U)
#define OVERSIZED_TEXT_BYTES (MAX_TEXT_BYTES + 1U)
#define MAX_FEATURES 256U
#define TOO_MANY_FEATURES (MAX_FEATURES + 1U)
#define METADATA_DESCRIPTOR_COUNT 257U

static uint32_t init_call_count;
static uint32_t successful_init_count;
static uint32_t deinit_count;
static uint32_t create_count;
static uint32_t plugin_init_count;
static uint32_t plugin_destroy_count;
static uint32_t plugin_main_thread_count;
static _Atomic uint32_t host_contract_failures;
static const clap_host_t *fixture_host;
static char last_init_path[4096];
static char oversized_id[OVERSIZED_TEXT_BYTES + 1U];
static const char *oversized_features[TOO_MANY_FEATURES + 1U];
static char exact_id[MAX_TEXT_BYTES + 1U];
static const char *exact_features[MAX_FEATURES + 1U];
static char metadata_text[MAX_TEXT_BYTES + 1U];
static char metadata_ids[METADATA_DESCRIPTOR_COUNT][48];
static clap_plugin_descriptor_t metadata_descriptors[METADATA_DESCRIPTOR_COUNT];

static const char *synth_features[] = {
   CLAP_PLUGIN_FEATURE_INSTRUMENT,
   CLAP_PLUGIN_FEATURE_STEREO,
   NULL,
};

static const char *effect_features[] = {
   CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
   NULL,
};

static const clap_plugin_descriptor_t synth_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.synth",
   .name = "Fixture Synth",
   .vendor = "pluginhost",
   .url = "https://example.invalid/pluginhost",
   .manual_url = "https://example.invalid/pluginhost/manual",
   .support_url = "https://example.invalid/pluginhost/support",
   .version = "1.2.3",
   .description = "Synthetic CLAP instrument",
   .features = synth_features,
};

static const clap_plugin_descriptor_t effect_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.effect",
   .name = "Fixture Effect",
   .vendor = NULL,
   .url = NULL,
   .manual_url = NULL,
   .support_url = NULL,
   .version = NULL,
   .description = NULL,
   .features = effect_features,
};

static const clap_plugin_descriptor_t blank_id_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = " \t",
   .name = "Blank ID",
   .features = synth_features,
};

static const clap_plugin_descriptor_t blank_name_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.blank-name",
   .name = " \t",
   .features = synth_features,
};

static const clap_plugin_descriptor_t incompatible_descriptor = {
   .clap_version = {0U, 0U, 0U},
   .id = "org.pluginhost.fixture.incompatible-descriptor",
   .name = "Incompatible Descriptor",
   .features = synth_features,
};

static const clap_plugin_descriptor_t null_id_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = NULL,
   .name = "Null ID",
   .features = synth_features,
};

static const char invalid_utf8_name[] = {'B', 'a', 'd', (char)0xff, 'N', 'a', 'm', 'e', '\0'};
static const clap_plugin_descriptor_t invalid_utf8_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.invalid-utf8",
   .name = invalid_utf8_name,
   .features = synth_features,
};

static clap_plugin_descriptor_t oversized_text_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = oversized_id,
   .name = "Oversized Text",
   .features = synth_features,
};

static clap_plugin_descriptor_t oversized_features_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.too-many-features",
   .name = "Too Many Features",
   .features = oversized_features,
};

static clap_plugin_descriptor_t exact_limits_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = exact_id,
   .name = "Exact Limits",
   .features = exact_features,
};

static bool fixture_entry_init(const char *plugin_path) {
   ++init_call_count;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_INIT_FAIL)
      return false;
   if (plugin_path == NULL || plugin_path[0] == '\0')
      return false;

   ++successful_init_count;
   (void)snprintf(last_init_path, sizeof(last_init_path), "%s", plugin_path);
   memset(oversized_id, 'x', sizeof(oversized_id));
   oversized_id[sizeof(oversized_id) - 1U] = '\0';
   memset(exact_id, 'e', sizeof(exact_id));
   exact_id[sizeof(exact_id) - 1U] = '\0';
   memset(metadata_text, 'm', sizeof(metadata_text));
   metadata_text[sizeof(metadata_text) - 1U] = '\0';
   for (uint32_t i = 0; i < TOO_MANY_FEATURES; ++i)
      oversized_features[i] = CLAP_PLUGIN_FEATURE_INSTRUMENT;
   oversized_features[TOO_MANY_FEATURES] = NULL;
   for (uint32_t i = 0; i < MAX_FEATURES; ++i)
      exact_features[i] = CLAP_PLUGIN_FEATURE_INSTRUMENT;
   exact_features[MAX_FEATURES] = NULL;
   for (uint32_t i = 0; i < METADATA_DESCRIPTOR_COUNT; ++i) {
      (void)snprintf(metadata_ids[i], sizeof(metadata_ids[i]),
                     "org.pluginhost.fixture.metadata.%u", i);
      metadata_descriptors[i] = (clap_plugin_descriptor_t){
         .clap_version = CLAP_VERSION_INIT,
         .id = metadata_ids[i],
         .name = "Metadata Limit",
         .description = metadata_text,
      };
   }
   return true;
}

static PLUGINHOST_FIXTURE_UNUSED void fixture_entry_deinit(void) {
   ++deinit_count;
}

static uint32_t fixture_get_plugin_count(const clap_plugin_factory_t *factory) {
   (void)factory;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_TOO_MANY_DESCRIPTORS)
      return 4097U;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_ZERO_DESCRIPTORS)
      return 0U;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_VALID ||
       PLUGINHOST_CLAP_FIXTURE_MODE == MODE_DUPLICATE_ID)
      return 2U;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_TOO_MUCH_METADATA)
      return METADATA_DESCRIPTOR_COUNT;
   return 1U;
}

static PLUGINHOST_FIXTURE_UNUSED const clap_plugin_descriptor_t *
fixture_get_plugin_descriptor(
   const clap_plugin_factory_t *factory,
   uint32_t index) {
   (void)factory;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_NULL_DESCRIPTOR)
      return NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_BLANK_ID)
      return index == 0U ? &blank_id_descriptor : NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_BLANK_NAME)
      return index == 0U ? &blank_name_descriptor : NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_INCOMPATIBLE_DESCRIPTOR)
      return index == 0U ? &incompatible_descriptor : NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_NULL_ID)
      return index == 0U ? &null_id_descriptor : NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_INVALID_UTF8)
      return index == 0U ? &invalid_utf8_descriptor : NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_OVERSIZED_TEXT)
      return index == 0U ? &oversized_text_descriptor : NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_TOO_MANY_FEATURES)
      return index == 0U ? &oversized_features_descriptor : NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_EXACT_LIMITS)
      return index == 0U ? &exact_limits_descriptor : NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_TOO_MUCH_METADATA)
      return index < METADATA_DESCRIPTOR_COUNT ? &metadata_descriptors[index] : NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_DUPLICATE_ID)
      return index < 2U ? &synth_descriptor : NULL;
   if (index == 0U)
      return &synth_descriptor;
   if (index == 1U)
      return &effect_descriptor;
   return NULL;
}

static uint32_t fixture_audio_count(const clap_plugin_t *plugin,
                                    bool is_input) {
   (void)plugin;
   (void)is_input;
   return 0U;
}

static bool fixture_audio_get(const clap_plugin_t *plugin,
                              uint32_t index,
                              bool is_input,
                              clap_audio_port_info_t *info) {
   (void)plugin;
   (void)index;
   (void)is_input;
   (void)info;
   return false;
}

static const clap_plugin_audio_ports_t fixture_audio_ports = {
   .count = fixture_audio_count,
   .get = fixture_audio_get,
};

static uint32_t fixture_note_count(const clap_plugin_t *plugin,
                                   bool is_input) {
   (void)plugin;
   (void)is_input;
   return 0U;
}

static bool fixture_note_get(const clap_plugin_t *plugin,
                             uint32_t index,
                             bool is_input,
                             clap_note_port_info_t *info) {
   (void)plugin;
   (void)index;
   (void)is_input;
   (void)info;
   return false;
}

static const clap_plugin_note_ports_t fixture_note_ports = {
   .count = fixture_note_count,
   .get = fixture_note_get,
};

static void *fixture_host_thread(void *opaque) {
   const clap_host_t *host = (const clap_host_t *)opaque;
   const clap_host_thread_check_t *thread_check =
      (const clap_host_thread_check_t *)host->get_extension(
         host, CLAP_EXT_THREAD_CHECK);
   if (thread_check == NULL || thread_check->is_main_thread(host) ||
       thread_check->is_audio_thread(host))
      atomic_fetch_add(&host_contract_failures, 1U);

   host->request_restart(host);
   host->request_process(host);
   host->request_callback(host);

   const clap_host_log_t *log =
      (const clap_host_log_t *)host->get_extension(host, CLAP_EXT_LOG);
   if (log == NULL)
      atomic_fetch_add(&host_contract_failures, 1U);
   else
      log->log(host, CLAP_LOG_INFO, "fixture worker");
   return NULL;
}

static bool fixture_plugin_init(const clap_plugin_t *plugin) {
   (void)plugin;
   ++plugin_init_count;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_PLUGIN_INIT_FAIL)
      return false;

   if (fixture_host == NULL) {
      atomic_fetch_add(&host_contract_failures, 1U);
      return true;
   }

   const clap_host_thread_check_t *thread_check =
      (const clap_host_thread_check_t *)fixture_host->get_extension(
         fixture_host, CLAP_EXT_THREAD_CHECK);
   if (thread_check == NULL || !thread_check->is_main_thread(fixture_host) ||
       thread_check->is_audio_thread(fixture_host))
      atomic_fetch_add(&host_contract_failures, 1U);

   const clap_host_log_t *log =
      (const clap_host_log_t *)fixture_host->get_extension(
         fixture_host, CLAP_EXT_LOG);
   if (log == NULL)
      atomic_fetch_add(&host_contract_failures, 1U);
   else
      log->log(fixture_host, CLAP_LOG_INFO, "fixture init");

   pthread_t workers[2];
   bool created[2] = {false, false};
   for (size_t index = 0; index < 2U; ++index) {
      if (pthread_create(&workers[index], NULL, fixture_host_thread,
                         (void *)fixture_host) != 0)
         atomic_fetch_add(&host_contract_failures, 1U);
      else
         created[index] = true;
   }
   for (size_t index = 0; index < 2U; ++index) {
      if (created[index] && pthread_join(workers[index], NULL) != 0)
         atomic_fetch_add(&host_contract_failures, 1U);
   }
   return true;
}

static void fixture_plugin_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
   ++plugin_destroy_count;
   if (fixture_host == NULL || fixture_host->name == NULL ||
       strcmp(fixture_host->name, "pluginhost") != 0 ||
       fixture_host->version == NULL ||
       strcmp(fixture_host->version, "0.0.7-dev") != 0 ||
       fixture_host->host_data == NULL)
      atomic_fetch_add(&host_contract_failures, 1U);
   if (fixture_host == NULL)
      return;
   const clap_host_thread_check_t *thread_check =
      (const clap_host_thread_check_t *)fixture_host->get_extension(
         fixture_host, CLAP_EXT_THREAD_CHECK);
   if (thread_check == NULL || !thread_check->is_main_thread(fixture_host) ||
       thread_check->is_audio_thread(fixture_host))
      atomic_fetch_add(&host_contract_failures, 1U);
   const clap_host_log_t *log =
      (const clap_host_log_t *)fixture_host->get_extension(
         fixture_host, CLAP_EXT_LOG);
   if (log != NULL)
      log->log(fixture_host, CLAP_LOG_INFO, "fixture destroy");
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

static clap_process_status fixture_plugin_process(
   const clap_plugin_t *plugin,
   const clap_process_t *process) {
   (void)plugin;
   (void)process;
   return CLAP_PROCESS_CONTINUE;
}

static const void *fixture_plugin_get_extension(const clap_plugin_t *plugin,
                                                const char *extension_id) {
   (void)plugin;
   if (extension_id == NULL)
      return NULL;
   if (strcmp(extension_id, CLAP_EXT_AUDIO_PORTS) == 0)
      return &fixture_audio_ports;
   if (strcmp(extension_id, CLAP_EXT_NOTE_PORTS) == 0)
      return &fixture_note_ports;
   return NULL;
}

static void fixture_plugin_on_main_thread(const clap_plugin_t *plugin) {
   (void)plugin;
   ++plugin_main_thread_count;
}

static const clap_plugin_t fixture_plugin = {
   .desc = &synth_descriptor,
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

static const clap_plugin_t missing_destroy_plugin = {
   .desc = &synth_descriptor,
   .plugin_data = NULL,
   .init = fixture_plugin_init,
   .destroy = NULL,
   .activate = fixture_plugin_activate,
   .deactivate = fixture_plugin_deactivate,
   .start_processing = fixture_plugin_start_processing,
   .stop_processing = fixture_plugin_stop_processing,
   .reset = fixture_plugin_reset,
   .process = fixture_plugin_process,
   .get_extension = fixture_plugin_get_extension,
   .on_main_thread = fixture_plugin_on_main_thread,
};

static const clap_plugin_t wrong_id_plugin = {
   .desc = &effect_descriptor,
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

static const clap_plugin_t incompatible_created_descriptor_plugin = {
   .desc = &incompatible_descriptor,
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

static const clap_plugin_t *fixture_create_plugin(
   const clap_plugin_factory_t *factory,
   const clap_host_t *host,
   const char *plugin_id) {
   (void)factory;
   (void)plugin_id;
   ++create_count;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_CREATE_GUARD)
      _exit(97);
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_CREATE_FAIL)
      return NULL;
   fixture_host = host;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_MISSING_PLUGIN_DESTROY)
      return &missing_destroy_plugin;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_PLUGIN_WRONG_ID)
      return &wrong_id_plugin;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_PLUGIN_INCOMPATIBLE_DESCRIPTOR)
      return &incompatible_created_descriptor_plugin;
   return &fixture_plugin;
}

static const clap_plugin_factory_t fixture_factory = {
   .get_plugin_count = fixture_get_plugin_count,
#if PLUGINHOST_CLAP_FIXTURE_MODE == MODE_MISSING_FACTORY_CALLBACK
   .get_plugin_descriptor = NULL,
#else
   .get_plugin_descriptor = fixture_get_plugin_descriptor,
#endif
   .create_plugin = fixture_create_plugin,
};

static const void *fixture_entry_get_factory(const char *factory_id) {
   if (factory_id == NULL || strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) != 0)
      return NULL;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_MISSING_FACTORY)
      return NULL;
   return &fixture_factory;
}

CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
#if PLUGINHOST_CLAP_FIXTURE_MODE == MODE_INCOMPATIBLE_ENTRY
   .clap_version = {0U, 0U, 0U},
#else
   .clap_version = CLAP_VERSION_INIT,
#endif
   .init = fixture_entry_init,
#if PLUGINHOST_CLAP_FIXTURE_MODE == MODE_MISSING_ENTRY_CALLBACK
   .deinit = NULL,
#else
   .deinit = fixture_entry_deinit,
#endif
   .get_factory = fixture_entry_get_factory,
};

PLUGINHOST_FIXTURE_EXPORT void pluginhost_clap_fixture_reset(void) {
   init_call_count = 0U;
   successful_init_count = 0U;
   deinit_count = 0U;
   create_count = 0U;
   plugin_init_count = 0U;
   plugin_destroy_count = 0U;
   plugin_main_thread_count = 0U;
   atomic_store(&host_contract_failures, 0U);
   fixture_host = NULL;
   last_init_path[0] = '\0';
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_clap_fixture_init_calls(void) {
   return init_call_count;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_clap_fixture_successful_inits(void) {
   return successful_init_count;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_clap_fixture_deinit_calls(void) {
   return deinit_count;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_clap_fixture_create_calls(void) {
   return create_count;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_clap_fixture_plugin_init_calls(void) {
   return plugin_init_count;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_clap_fixture_plugin_destroy_calls(void) {
   return plugin_destroy_count;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_clap_fixture_plugin_main_thread_calls(void) {
   return plugin_main_thread_count;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_clap_fixture_host_contract_failures(void) {
   return atomic_load(&host_contract_failures);
}

PLUGINHOST_FIXTURE_EXPORT const char *pluginhost_clap_fixture_last_init_path(void) {
   return last_init_path;
}
