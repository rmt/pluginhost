#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include <clap/entry.h>
#include <clap/ext/gui.h>
#include <clap/ext/posix-fd-support.h>
#include <clap/ext/thread-check.h>
#include <clap/ext/timer-support.h>
#include <clap/factory/plugin-factory.h>
#include <clap/plugin-features.h>

#if defined(__GNUC__) || defined(__clang__)
#define PLUGINHOST_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define PLUGINHOST_FIXTURE_EXPORT
#endif

#define SERVICE_FAILURE_NONE 0U
#define SERVICE_FAILURE_AFTER_TIMER 1U
#define SERVICE_FAILURE_AFTER_PIPE 2U
#define SERVICE_FAILURE_FD_REGISTRATION 3U
#define SERVICE_FAILURE_AFTER_FD 4U

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
static uint32_t main_thread_failures;
static uint32_t timer_callback_count;
static uint32_t fd_callback_count;
static uint32_t timer_register_count;
static uint32_t timer_unregister_count;
static uint32_t fd_register_count;
static uint32_t fd_unregister_count;
static uint32_t pipe_create_count;
static uint32_t pipe_close_count;
static uint32_t service_setup_failures;
static uint32_t service_cleanup_failures;
static const clap_host_t *fixture_host;
static const clap_host_timer_support_t *fixture_host_timers;
static const clap_host_posix_fd_support_t *fixture_host_fds;
static clap_id fixture_timer_id = CLAP_INVALID_ID;
static int fixture_pipe[2] = {-1, -1};
static bool fixture_timer_registered;
static bool fixture_fd_registered;
static bool fixture_services_enabled;
static uint32_t fixture_service_failure_step;

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

static bool thread_is_main(void) {
   if (fixture_host == NULL || fixture_host->get_extension == NULL)
      return false;
   const clap_host_thread_check_t *check =
      (const clap_host_thread_check_t *)fixture_host->get_extension(
         fixture_host, CLAP_EXT_THREAD_CHECK);
   return check != NULL && check->is_main_thread != NULL &&
      check->is_main_thread(fixture_host);
}

static bool thread_is_audio(void) {
   if (fixture_host == NULL || fixture_host->get_extension == NULL)
      return false;
   const clap_host_thread_check_t *check =
      (const clap_host_thread_check_t *)fixture_host->get_extension(
         fixture_host, CLAP_EXT_THREAD_CHECK);
   return check != NULL && check->is_audio_thread != NULL &&
      check->is_audio_thread(fixture_host);
}

static void require_main_not_audio(void) {
   if (!thread_is_main() || thread_is_audio()) {
      ++contract_failures;
      ++main_thread_failures;
   }
}

static bool close_pipe_ends(void) {
   bool success = true;
   for (size_t index = 0U; index < 2U; ++index) {
      if (fixture_pipe[index] < 0)
         continue;
      if (close(fixture_pipe[index]) != 0) {
         ++contract_failures;
         ++service_cleanup_failures;
         success = false;
         continue;
      }
      ++pipe_close_count;
      fixture_pipe[index] = -1;
   }
   return success;
}

static bool unregister_fixture_fd(void) {
   if (!fixture_fd_registered)
      return true;
   if (fixture_host_fds == NULL ||
       fixture_host_fds->unregister_fd == NULL ||
       fixture_pipe[0] < 0 ||
       !fixture_host_fds->unregister_fd(fixture_host, fixture_pipe[0])) {
      ++contract_failures;
      ++service_cleanup_failures;
      return false;
   }
   fixture_fd_registered = false;
   ++fd_unregister_count;
   return true;
}

static bool unregister_fixture_timer(void) {
   if (!fixture_timer_registered)
      return true;
   if (fixture_host_timers == NULL ||
       fixture_host_timers->unregister_timer == NULL ||
       !fixture_host_timers->unregister_timer(fixture_host, fixture_timer_id)) {
      ++contract_failures;
      ++service_cleanup_failures;
      return false;
   }
   fixture_timer_registered = false;
   fixture_timer_id = CLAP_INVALID_ID;
   ++timer_unregister_count;
   return true;
}

static bool rollback_services(void) {
   bool success = true;
   if (!unregister_fixture_fd())
      success = false;
   if (!unregister_fixture_timer())
      success = false;
   if (fixture_fd_registered || fixture_timer_registered)
      return false;
   if (!close_pipe_ends())
      success = false;
   fixture_timer_id = CLAP_INVALID_ID;
   return success;
}

static void fixture_on_timer(const clap_plugin_t *plugin, clap_id timer_id) {
   (void)plugin;
   require_main_not_audio();
   if (!fixture_timer_registered || timer_id != fixture_timer_id ||
       fixture_pipe[1] < 0)
      ++contract_failures;
   ++timer_callback_count;
   const char byte = 'g';
   if (fixture_pipe[1] < 0 || write(fixture_pipe[1], &byte, 1U) != 1)
      ++contract_failures;
}

static const clap_plugin_timer_support_t fixture_timer_support = {
   .on_timer = fixture_on_timer,
};

static void fixture_on_fd(const clap_plugin_t *plugin, int fd,
                          clap_posix_fd_flags_t flags) {
   (void)plugin;
   require_main_not_audio();
   if (!fixture_fd_registered || fd != fixture_pipe[0] ||
       (flags & CLAP_POSIX_FD_READ) == 0U)
      ++contract_failures;
   bool consumed = false;
   for (;;) {
      char bytes[64];
      ssize_t count = read(fd, bytes, sizeof(bytes));
      if (count > 0) {
         consumed = true;
         for (ssize_t index = 0; index < count; ++index) {
            if (bytes[index] != 'g')
               ++contract_failures;
         }
         continue;
      }
      if (count == 0)
         break;
      if (errno == EAGAIN || errno == EWOULDBLOCK)
         break;
      ++contract_failures;
      break;
   }
   if (!consumed)
      ++contract_failures;
   ++fd_callback_count;
}

static const clap_plugin_posix_fd_support_t fixture_posix_fd_support = {
   .on_fd = fixture_on_fd,
};

static bool setup_services(void) {
   if (!fixture_services_enabled)
      return true;
   if (fixture_host_timers == NULL || fixture_host_timers->register_timer == NULL ||
       fixture_host_fds == NULL || fixture_host_fds->register_fd == NULL) {
      ++service_setup_failures;
      ++contract_failures;
      return false;
   }

   fixture_timer_id = CLAP_INVALID_ID;
   fixture_pipe[0] = -1;
   fixture_pipe[1] = -1;
   fixture_timer_registered = false;
   fixture_fd_registered = false;

   uint32_t timer_period = 34U;
   if (!fixture_host_timers->register_timer(
          fixture_host, timer_period, &fixture_timer_id))
      goto failed;
   fixture_timer_registered = true;
   ++timer_register_count;
   if (fixture_service_failure_step == SERVICE_FAILURE_AFTER_TIMER)
      goto failed;

   if (pipe2(fixture_pipe, O_NONBLOCK | O_CLOEXEC) != 0)
      goto failed;
   ++pipe_create_count;
   if (fixture_service_failure_step == SERVICE_FAILURE_AFTER_PIPE)
      goto failed;

   uint32_t flags = CLAP_POSIX_FD_READ | CLAP_POSIX_FD_ERROR;
   if (fixture_service_failure_step == SERVICE_FAILURE_FD_REGISTRATION)
      flags = 0U;
   if (!fixture_host_fds->register_fd(fixture_host, fixture_pipe[0], flags))
      goto failed;
   fixture_fd_registered = true;
   ++fd_register_count;
   if (fixture_service_failure_step == SERVICE_FAILURE_AFTER_FD)
      goto failed;
   return true;

failed:
   ++service_setup_failures;
   (void)rollback_services();
   return false;
}

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
   if (!setup_services())
      return false;
   ++create_count;
   return true;
}

static void gui_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
   require_main_not_audio();
   (void)rollback_services();
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
   require_main_not_audio();
   if (fixture_host == NULL || fixture_host->get_extension == NULL)
      return false;
   fixture_host_timers = NULL;
   fixture_host_fds = NULL;
   if (!fixture_services_enabled)
      return true;
   fixture_host_timers = (const clap_host_timer_support_t *)
      fixture_host->get_extension(fixture_host, CLAP_EXT_TIMER_SUPPORT);
   fixture_host_fds = (const clap_host_posix_fd_support_t *)
      fixture_host->get_extension(fixture_host, CLAP_EXT_POSIX_FD_SUPPORT);
   if (fixture_host_timers == NULL || fixture_host_timers->register_timer == NULL ||
       fixture_host_timers->unregister_timer == NULL ||
       fixture_host_fds == NULL || fixture_host_fds->register_fd == NULL ||
       fixture_host_fds->unregister_fd == NULL)
      return false;
   return true;
}

static void plugin_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
   require_main_not_audio();
   (void)rollback_services();
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
   if (fixture_services_enabled && extension_id != NULL &&
       strcmp(extension_id, CLAP_EXT_TIMER_SUPPORT) == 0)
      return &fixture_timer_support;
   if (fixture_services_enabled && extension_id != NULL &&
       strcmp(extension_id, CLAP_EXT_POSIX_FD_SUPPORT) == 0)
      return &fixture_posix_fd_support;
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
   main_thread_failures = 0U;
   timer_callback_count = 0U;
   fd_callback_count = 0U;
   timer_register_count = 0U;
   timer_unregister_count = 0U;
   fd_register_count = 0U;
   fd_unregister_count = 0U;
   pipe_create_count = 0U;
   pipe_close_count = 0U;
   service_setup_failures = 0U;
   service_cleanup_failures = 0U;
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
#define SERVICE_COUNTER(name, value) \
   PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_gui_fixture_##name(void) { \
      return (value); \
   }
SERVICE_COUNTER(timer_callback, timer_callback_count)
SERVICE_COUNTER(fd_callback, fd_callback_count)
SERVICE_COUNTER(timer_register, timer_register_count)
SERVICE_COUNTER(timer_unregister, timer_unregister_count)
SERVICE_COUNTER(fd_register, fd_register_count)
SERVICE_COUNTER(fd_unregister, fd_unregister_count)
SERVICE_COUNTER(pipe_create, pipe_create_count)
SERVICE_COUNTER(pipe_close, pipe_close_count)
SERVICE_COUNTER(service_setup_failure, service_setup_failures)
SERVICE_COUNTER(service_cleanup_failure, service_cleanup_failures)
SERVICE_COUNTER(main_thread_failure, main_thread_failures)

PLUGINHOST_FIXTURE_EXPORT void pluginhost_gui_fixture_enable_services(
   uint32_t enabled) {
   fixture_services_enabled = enabled != 0U;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_gui_fixture_set_service_failure_step(
   uint32_t step) {
   fixture_service_failure_step = step;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_gui_fixture_contract_failures(void) {
   return contract_failures;
}
