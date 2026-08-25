#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <clap/entry.h>
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

#define MAX_TEXT_BYTES (64U * 1024U)
#define OVERSIZED_TEXT_BYTES (MAX_TEXT_BYTES + 1U)
#define MAX_FEATURES 256U
#define TOO_MANY_FEATURES (MAX_FEATURES + 1U)
#define METADATA_DESCRIPTOR_COUNT 257U

static uint32_t init_call_count;
static uint32_t successful_init_count;
static uint32_t deinit_count;
static uint32_t create_count;
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

static const clap_plugin_t *fixture_create_plugin(
   const clap_plugin_factory_t *factory,
   const clap_host_t *host,
   const char *plugin_id) {
   (void)factory;
   (void)host;
   (void)plugin_id;
   ++create_count;
   if (PLUGINHOST_CLAP_FIXTURE_MODE == MODE_CREATE_GUARD)
      _exit(97);
   return NULL;
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

PLUGINHOST_FIXTURE_EXPORT const char *pluginhost_clap_fixture_last_init_path(void) {
   return last_init_path;
}
