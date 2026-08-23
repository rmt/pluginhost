#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#include <clap/entry.h>

#if defined(__GNUC__) || defined(__clang__)
#define PLUGINHOST_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define PLUGINHOST_FIXTURE_EXPORT
#endif

typedef int32_t (*pluginhost_fixture_callback_t)(int32_t value, void *context);
typedef int32_t (*pluginhost_fixture_process_callback_t)(uint32_t frames,
                                                         void *context);

typedef struct pluginhost_fixture_thread_call {
   pluginhost_fixture_callback_t callback;
   int32_t value;
   void *context;
   int32_t result;
   int32_t used_foreign_thread;
   pthread_t caller_thread;
} pluginhost_fixture_thread_call_t;

typedef struct pluginhost_fixture_process_thread_call {
   pluginhost_fixture_process_callback_t callback;
   uint32_t frames;
   void *context;
   int32_t result;
   int32_t used_foreign_thread;
   pthread_t caller_thread;
} pluginhost_fixture_process_thread_call_t;

static bool fixture_entry_init(const char *plugin_path) {
   return plugin_path != NULL && plugin_path[0] != '\0';
}

static void fixture_entry_deinit(void) {}

static const void *fixture_entry_get_factory(const char *factory_id) {
   (void)factory_id;
   return NULL;
}

CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
   .clap_version = CLAP_VERSION_INIT,
   .init = fixture_entry_init,
   .deinit = fixture_entry_deinit,
   .get_factory = fixture_entry_get_factory,
};

PLUGINHOST_FIXTURE_EXPORT int32_t
pluginhost_fixture_add(int32_t left, int32_t right) {
   return left + right;
}

static int32_t fixture_c_callback(int32_t value, void *context) {
   const int32_t adjustment = *(const int32_t *)context;
   return value + adjustment;
}

PLUGINHOST_FIXTURE_EXPORT pluginhost_fixture_callback_t
pluginhost_fixture_get_callback(void) {
   return fixture_c_callback;
}

PLUGINHOST_FIXTURE_EXPORT int32_t pluginhost_fixture_call_callback(
   pluginhost_fixture_callback_t callback,
   int32_t value,
   void *context) {
   if (callback == NULL)
      return INT32_MIN;
   return callback(value, context);
}

static void *fixture_thread_main(void *raw_call) {
   pluginhost_fixture_thread_call_t *call = raw_call;
   call->used_foreign_thread =
      pthread_equal(pthread_self(), call->caller_thread) ? 0 : 1;
   call->result = call->callback(call->value, call->context);
   return NULL;
}

PLUGINHOST_FIXTURE_EXPORT int32_t pluginhost_fixture_call_on_thread(
   pluginhost_fixture_callback_t callback,
   int32_t value,
   void *context,
   int32_t *callback_result,
   int32_t *used_foreign_thread) {
   if (callback == NULL || callback_result == NULL || used_foreign_thread == NULL)
      return -1;

   pluginhost_fixture_thread_call_t call = {
      .callback = callback,
      .value = value,
      .context = context,
      .result = 0,
      .used_foreign_thread = 0,
      .caller_thread = pthread_self(),
   };
   pthread_t thread;
   const int create_status = pthread_create(&thread, NULL, fixture_thread_main, &call);
   if (create_status != 0)
      return create_status;

   const int join_status = pthread_join(thread, NULL);
   if (join_status != 0)
      return join_status;

   *callback_result = call.result;
   *used_foreign_thread = call.used_foreign_thread;
   return 0;
}

static void *fixture_process_thread_main(void *raw_call) {
   pluginhost_fixture_process_thread_call_t *call = raw_call;
   call->used_foreign_thread =
      pthread_equal(pthread_self(), call->caller_thread) ? 0 : 1;
   call->result = call->callback(call->frames, call->context);
   return NULL;
}

PLUGINHOST_FIXTURE_EXPORT int32_t pluginhost_fixture_process_on_thread(
   pluginhost_fixture_process_callback_t callback,
   uint32_t frames,
   void *context,
   int32_t *callback_result,
   int32_t *used_foreign_thread) {
   if (callback == NULL || callback_result == NULL || used_foreign_thread == NULL)
      return -1;

   pluginhost_fixture_process_thread_call_t call = {
      .callback = callback,
      .frames = frames,
      .context = context,
      .result = 0,
      .used_foreign_thread = 0,
      .caller_thread = pthread_self(),
   };
   pthread_t thread;
   const int create_status =
      pthread_create(&thread, NULL, fixture_process_thread_main, &call);
   if (create_status != 0)
      return create_status;

   const int join_status = pthread_join(thread, NULL);
   if (join_status != 0)
      return join_status;

   *callback_result = call.result;
   *used_foreign_thread = call.used_foreign_thread;
   return 0;
}
