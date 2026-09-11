#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <clap/entry.h>
#include <clap/ext/log.h>
#include <clap/factory/plugin-factory.h>
#include <clap/plugin-features.h>

#if defined(__GNUC__) || defined(__clang__)
#define PLUGINHOST_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define PLUGINHOST_FIXTURE_EXPORT
#endif

static const clap_host_t *fixture_host;
static pthread_t worker_thread;
static bool worker_started;
static _Atomic bool worker_stop;
static _Atomic bool destroying;
static _Atomic uint32_t started;
static _Atomic uint32_t batches;
static _Atomic uint32_t during_destroy;
static _Atomic uint32_t joined;

static const char *fixture_features[] = {
   CLAP_PLUGIN_FEATURE_AUDIO_EFFECT,
   NULL,
};

static const clap_plugin_descriptor_t fixture_descriptor = {
   .clap_version = CLAP_VERSION_INIT,
   .id = "org.pluginhost.fixture.foreign-thread-race",
   .name = "Foreign Thread Race Fixture",
   .vendor = "pluginhost",
   .url = "https://example.invalid/pluginhost/foreign-thread-race",
   .manual_url = NULL,
   .support_url = NULL,
   .version = "1.0.0",
   .description = "Synthetic plugin-owned foreign-thread teardown fixture",
   .features = fixture_features,
};

static void fixture_log(const clap_host_t *host, clap_log_severity severity,
                        const char *message) {
   if (host == NULL || host->get_extension == NULL)
      return;
   const clap_host_log_t *log = (const clap_host_log_t *)host->get_extension(
      host, CLAP_EXT_LOG);
   if (log != NULL && log->log != NULL)
      log->log(host, severity, message);
}

static void fixture_callback_batch(const clap_host_t *host) {
   const bool is_during_destroy =
      atomic_load_explicit(&destroying, memory_order_acquire);
   const uint32_t completed_batches =
      atomic_load_explicit(&batches, memory_order_relaxed);
   if (host != NULL) {
      if (completed_batches == 0U && host->request_restart != NULL)
         host->request_restart(host);
      if (host->request_process != NULL)
         host->request_process(host);
      if (host->request_callback != NULL)
         host->request_callback(host);
   }
   const uint32_t batch =
      atomic_fetch_add_explicit(&batches, 1U, memory_order_relaxed) + 1U;
   if (host != NULL && (batch == 1U || is_during_destroy))
      fixture_log(host, CLAP_LOG_INFO, "foreign teardown callback");
   if (is_during_destroy)
      atomic_fetch_add_explicit(&during_destroy, 1U, memory_order_release);
}

static void *fixture_worker_main(void *opaque) {
   const clap_host_t *host = (const clap_host_t *)opaque;
   atomic_store_explicit(&started, 1U, memory_order_release);
   while (!atomic_load_explicit(&worker_stop, memory_order_acquire)) {
      fixture_callback_batch(host);
      sched_yield();
   }
   return NULL;
}

static bool fixture_plugin_init(const clap_plugin_t *plugin) {
   (void)plugin;
   if (fixture_host == NULL)
      return false;
   atomic_store_explicit(&worker_stop, false, memory_order_release);
   atomic_store_explicit(&destroying, false, memory_order_release);
   atomic_store_explicit(&started, 0U, memory_order_release);
   atomic_store_explicit(&batches, 0U, memory_order_release);
   atomic_store_explicit(&during_destroy, 0U, memory_order_release);
   atomic_store_explicit(&joined, 0U, memory_order_release);
   const int status = pthread_create(&worker_thread, NULL, fixture_worker_main,
                                     (void *)fixture_host);
   if (status != 0)
      return false;
   worker_started = true;
   return true;
}

static void fixture_plugin_destroy(const clap_plugin_t *plugin) {
   (void)plugin;
   const clap_host_t *host = fixture_host;
   atomic_store_explicit(&destroying, true, memory_order_release);
   uint32_t spins = 0U;
   while (atomic_load_explicit(&during_destroy, memory_order_acquire) == 0U &&
          spins < 5000000U) {
      sched_yield();
      ++spins;
   }
   if (atomic_load_explicit(&during_destroy, memory_order_acquire) == 0U)
      abort();
   atomic_store_explicit(&worker_stop, true, memory_order_release);
   if (worker_started) {
      const int status = pthread_join(worker_thread, NULL);
      if (status != 0)
         abort();
      atomic_store_explicit(&joined, 1U, memory_order_release);
      worker_started = false;
   }
   fixture_log(host, CLAP_LOG_INFO,
               "foreign teardown worker joined after concurrent callback");
   fixture_host = NULL;
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
   (void)extension_id;
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

static bool fixture_entry_init(const char *plugin_path) {
   return plugin_path != NULL && plugin_path[0] != '\0';
}

static void fixture_entry_deinit(void) {
   fixture_host = NULL;
}

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

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_foreign_thread_race_started(void) {
   return atomic_load_explicit(&started, memory_order_acquire);
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_foreign_thread_race_batches(void) {
   return atomic_load_explicit(&batches, memory_order_acquire);
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_foreign_thread_race_during_destroy(void) {
   return atomic_load_explicit(&during_destroy, memory_order_acquire);
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_foreign_thread_race_joined(void) {
   return atomic_load_explicit(&joined, memory_order_acquire);
}
