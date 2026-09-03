#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <clap/entry.h>
#include <clap/ext/gui.h>
#include <clap/factory/plugin-factory.h>
#include <clap/plugin-features.h>

#if defined(__GNUC__) || defined(__clang__)
#define PLUGINHOST_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define PLUGINHOST_FIXTURE_EXPORT
#endif

static uint32_t create_count;
static uint32_t destroy_count;
static uint32_t set_scale_count;
static uint32_t set_size_count;
static uint32_t set_parent_count;
static uint32_t set_transient_count;
static uint32_t suggest_title_count;
static uint32_t show_count;
static uint32_t hide_count;
static uint32_t contract_failures;
static const clap_host_t *fixture_host;

static const char *features[] = {
   CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
   NULL,
};

static const clap_plugin_descriptor_t descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.gui",
   .name = "Fixture GUI",
   .vendor = "pluginhost",
   .url = "https://example.invalid/pluginhost/gui",
   .version = "1.0.0",
   .description = "Synthetic CLAP GUI fixture",
   .features = features,
};

static bool gui_is_api_supported(const clap_plugin_t *plugin,
                                 const char *api,
                                 bool is_floating) {
   (void)plugin;
   (void)is_floating;
   return api != NULL && strcmp(api, CLAP_WINDOW_API_X11) == 0;
}

static bool gui_get_preferred_api(const clap_plugin_t *plugin,
                                  const char **api,
                                  bool *is_floating) {
   (void)plugin;
   if (api == NULL || is_floating == NULL)
      return false;
   *api = CLAP_WINDOW_API_X11;
   *is_floating = false;
   return true;
}

static bool gui_create(const clap_plugin_t *plugin, const char *api,
                       bool is_floating) {
   (void)plugin;
   (void)is_floating;
   if (api == NULL || strcmp(api, CLAP_WINDOW_API_X11) != 0)
      return false;
   ++create_count;
   return true;
}

static void gui_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
   ++destroy_count;
}

static bool gui_set_scale(const clap_plugin_t *plugin, double scale) {
   (void)plugin;
   if (scale <= 0.0)
      return false;
   ++set_scale_count;
   return true;
}

static bool gui_get_size(const clap_plugin_t *plugin, uint32_t *width,
                         uint32_t *height) {
   (void)plugin;
   if (width == NULL || height == NULL)
      return false;
   *width = 320U;
   *height = 240U;
   return true;
}

static bool gui_can_resize(const clap_plugin_t *plugin) {
   (void)plugin;
   return true;
}

static bool gui_get_resize_hints(const clap_plugin_t *plugin,
                                 clap_gui_resize_hints_t *hints) {
   (void)plugin;
   if (hints == NULL)
      return false;
   hints->can_resize_horizontally = true;
   hints->can_resize_vertically = true;
   hints->preserve_aspect_ratio = false;
   hints->aspect_ratio_width = 0U;
   hints->aspect_ratio_height = 0U;
   return true;
}

static bool gui_adjust_size(const clap_plugin_t *plugin, uint32_t *width,
                            uint32_t *height) {
   (void)plugin;
   if (width == NULL || height == NULL || *width == 0U || *height == 0U)
      return false;
   if (*width > 1920U)
      *width = 1920U;
   if (*height > 1080U)
      *height = 1080U;
   return true;
}

static bool gui_set_size(const clap_plugin_t *plugin, uint32_t width,
                         uint32_t height) {
   (void)plugin;
   if (width == 0U || height == 0U)
      return false;
   ++set_size_count;
   return true;
}

static bool gui_set_parent(const clap_plugin_t *plugin,
                           const clap_window_t *window) {
   (void)plugin;
   if (window == NULL || window->api == NULL ||
       strcmp(window->api, CLAP_WINDOW_API_X11) != 0 || window->x11 == 0)
      return false;
   ++set_parent_count;
   return true;
}

static bool gui_set_transient(const clap_plugin_t *plugin,
                              const clap_window_t *window) {
   (void)plugin;
   if (window == NULL || window->api == NULL ||
       strcmp(window->api, CLAP_WINDOW_API_X11) != 0 || window->x11 == 0)
      return false;
   ++set_transient_count;
   return true;
}

static void gui_suggest_title(const clap_plugin_t *plugin, const char *title) {
   (void)plugin;
   if (title == NULL)
      ++contract_failures;
   else
      ++suggest_title_count;
}

static bool gui_show(const clap_plugin_t *plugin) {
   (void)plugin;
   ++show_count;
   return true;
}

static bool gui_hide(const clap_plugin_t *plugin) {
   (void)plugin;
   ++hide_count;
   return true;
}

static const clap_plugin_gui_t gui_extension = {
   .is_api_supported = gui_is_api_supported,
   .get_preferred_api = gui_get_preferred_api,
   .create = gui_create,
   .destroy = gui_destroy,
   .set_scale = gui_set_scale,
   .get_size = gui_get_size,
   .can_resize = gui_can_resize,
   .get_resize_hints = gui_get_resize_hints,
   .adjust_size = gui_adjust_size,
   .set_size = gui_set_size,
   .set_parent = gui_set_parent,
   .set_transient = gui_set_transient,
   .suggest_title = gui_suggest_title,
   .show = gui_show,
   .hide = gui_hide,
};

static bool plugin_init(const clap_plugin_t *plugin) {
   (void)plugin;
   return fixture_host != NULL;
}

static void plugin_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
}

static bool plugin_activate(const clap_plugin_t *plugin, double sample_rate,
                            uint32_t min_frames_count,
                            uint32_t max_frames_count) {
   (void)plugin;
   (void)sample_rate;
   (void)min_frames_count;
   (void)max_frames_count;
   return true;
}

static void plugin_deactivate(const clap_plugin_t *plugin) { (void)plugin; }
static bool plugin_start_processing(const clap_plugin_t *plugin) {
   (void)plugin;
   return true;
}
static void plugin_stop_processing(const clap_plugin_t *plugin) { (void)plugin; }
static void plugin_reset(const clap_plugin_t *plugin) { (void)plugin; }
static clap_process_status plugin_process(const clap_plugin_t *plugin,
                                          const clap_process_t *process) {
   (void)plugin;
   (void)process;
   return CLAP_PROCESS_CONTINUE;
}

static const void *plugin_get_extension(const clap_plugin_t *plugin,
                                        const char *extension_id) {
   (void)plugin;
   if (extension_id != NULL && strcmp(extension_id, CLAP_EXT_GUI) == 0)
      return &gui_extension;
   return NULL;
}

static void plugin_on_main_thread(const clap_plugin_t *plugin) { (void)plugin; }

static const clap_plugin_t plugin = {
   .desc = &descriptor,
   .plugin_data = NULL,
   .init = plugin_init,
   .destroy = plugin_destroy,
   .activate = plugin_activate,
   .deactivate = plugin_deactivate,
   .start_processing = plugin_start_processing,
   .stop_processing = plugin_stop_processing,
   .reset = plugin_reset,
   .process = plugin_process,
   .get_extension = plugin_get_extension,
   .on_main_thread = plugin_on_main_thread,
};

static uint32_t factory_count(const clap_plugin_factory_t *factory) {
   (void)factory;
   return 1U;
}

static const clap_plugin_descriptor_t *factory_descriptor(
    const clap_plugin_factory_t *factory, uint32_t index) {
   (void)factory;
   return index == 0U ? &descriptor : NULL;
}

static const clap_plugin_t *factory_create(const clap_plugin_factory_t *factory,
                                           const clap_host_t *host,
                                           const char *plugin_id) {
   (void)factory;
   if (host == NULL || plugin_id == NULL || strcmp(plugin_id, descriptor.id) != 0)
      return NULL;
   fixture_host = host;
   return &plugin;
}

static const clap_plugin_factory_t factory = {
   .get_plugin_count = factory_count,
   .get_plugin_descriptor = factory_descriptor,
   .create_plugin = factory_create,
};

static const void *entry_factory(const char *factory_id) {
   if (factory_id != NULL && strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) == 0)
      return &factory;
   return NULL;
}

static bool entry_init(const char *plugin_path) {
   return plugin_path != NULL && plugin_path[0] != '\0';
}

static void entry_deinit(void) { fixture_host = NULL; }

CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
   .clap_version = CLAP_VERSION_INIT,
   .init = entry_init,
   .deinit = entry_deinit,
   .get_factory = entry_factory,
};

PLUGINHOST_FIXTURE_EXPORT void pluginhost_gui_fixture_reset(void) {
   create_count = 0U;
   destroy_count = 0U;
   set_scale_count = 0U;
   set_size_count = 0U;
   set_parent_count = 0U;
   set_transient_count = 0U;
   suggest_title_count = 0U;
   show_count = 0U;
   hide_count = 0U;
   contract_failures = 0U;
   fixture_host = NULL;
}

#define COUNTER(name) \
   PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_gui_fixture_##name(void) { \
      return name##_count; \
   }
COUNTER(create)
COUNTER(destroy)
COUNTER(set_scale)
COUNTER(set_size)
COUNTER(set_parent)
COUNTER(set_transient)
COUNTER(suggest_title)
COUNTER(show)
COUNTER(hide)

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_gui_fixture_contract_failures(void) {
   return contract_failures;
}
