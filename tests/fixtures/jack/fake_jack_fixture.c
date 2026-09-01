#include <jack/jack.h>
#include <jack/midiport.h>

#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#define PLUGINHOST_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define PLUGINHOST_FIXTURE_EXPORT
#endif

#define FAKE_MAX_PORTS 128
#define FAKE_MAX_FRAMES 512
#define FAKE_MAX_ORDER 32
#define FAKE_MAX_MIDI_EVENTS 4097
#define FAKE_MIDI_BYTES 65536

struct _jack_client {
   int marker;
};

typedef struct fake_midi_event {
   jack_nframes_t time;
   uint32_t size;
   uint32_t offset;
} fake_midi_event_t;

struct _jack_port {
   int alive;
   unsigned long flags;
   char short_name[128];
   char full_name[256];
   char type[64];
   char alias[256];
   jack_default_audio_sample_t audio[FAKE_MAX_FRAMES];
   fake_midi_event_t midi_events[FAKE_MAX_MIDI_EVENTS];
   unsigned char midi_data[FAKE_MIDI_BYTES];
   uint32_t midi_event_count;
   uint32_t midi_bytes_used;
   uint32_t midi_capacity;
   uint32_t midi_lost_events;
   int midi_get_failure_index;
   jack_latency_range_t capture_latency;
   jack_latency_range_t playback_latency;
};

typedef struct fake_jack_state {
   struct _jack_client client;
   int client_open;
   int active;
   int client_name_size;
   int port_name_size;
   jack_nframes_t sample_rate;
   jack_nframes_t buffer_size;
   char actual_client_name[128];
   char requested_client_name[128];
   char requested_server_name[128];
   jack_options_t requested_options;
   jack_status_t open_failure_status;
   jack_status_t open_success_status;
   int close_status;
   int activate_status;
   int deactivate_status;
   int close_count;
   int activate_count;
   int deactivate_count;

   int callback_failure_code;
   int callback_failure_status;
   int callback_order[FAKE_MAX_ORDER];
   int callback_order_count;

   JackProcessCallback process_callback;
   void *process_argument;
   JackShutdownCallback shutdown_callback;
   void *shutdown_argument;
   JackInfoShutdownCallback info_shutdown_callback;
   void *info_shutdown_argument;
   JackBufferSizeCallback buffer_size_callback;
   void *buffer_size_argument;
   JackSampleRateCallback sample_rate_callback;
   void *sample_rate_argument;
   JackXRunCallback xrun_callback;
   void *xrun_argument;
   JackFreewheelCallback freewheel_callback;
   void *freewheel_argument;
   JackLatencyCallback latency_callback;
   void *latency_argument;

   struct _jack_port ports[FAKE_MAX_PORTS];
   int successful_registrations;
   int registration_attempts;
   int current_ports;
   int unregister_count;
   int unregister_failure_status;
   int failed_port_attempt;
   int alias_attempts;
   int failed_alias_attempt;
   int recompute_count;
   int recompute_status;
} fake_jack_state_t;

static fake_jack_state_t state;
static pthread_mutex_t process_gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t process_gate_condition = PTHREAD_COND_INITIALIZER;
static pthread_t blocked_process_thread;
static int blocked_process_thread_valid;
static int block_in_port_buffer;
static int blocked_process_entered;
static int release_blocked_process;

static void copy_text(char *destination, size_t capacity, const char *source) {
   if (capacity == 0)
      return;
   if (source == NULL) {
      destination[0] = '\0';
      return;
   }
   (void)snprintf(destination, capacity, "%s", source);
}

static void record_callback_order(int code) {
   if (state.callback_order_count < FAKE_MAX_ORDER)
      state.callback_order[state.callback_order_count++] = code;
}

static int callback_status(int code) {
   record_callback_order(code);
   if (state.callback_failure_code == code)
      return state.callback_failure_status != 0 ? state.callback_failure_status : -1;
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_reset(void) {
   memset(&state, 0, sizeof(state));
   state.client.marker = 0x4a41434b;
   state.client_name_size = 64;
   state.port_name_size = 128;
   state.sample_rate = 48000;
   state.buffer_size = 128;
   state.failed_port_attempt = -1;
   state.failed_alias_attempt = -1;
   copy_text(state.actual_client_name, sizeof(state.actual_client_name),
             "fixture-client");
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_open_failure(int status) {
   state.open_failure_status = (jack_status_t)status;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_open_success_status(int status) {
   state.open_success_status = (jack_status_t)status;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_callback_failure(int code, int status) {
   state.callback_failure_code = code;
   state.callback_failure_status = status;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_port_failure(int attempt) {
   state.failed_port_attempt = attempt;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_alias_failure(int attempt) {
   state.failed_alias_attempt = attempt;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_unregister_failure(int status) {
   state.unregister_failure_status = status;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_activate_status(int status) {
   state.activate_status = status;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_deactivate_status(int status) {
   state.deactivate_status = status;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_close_status(int status) {
   state.close_status = status;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_recompute_status(int status) {
   state.recompute_status = status;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_client_name_size(int size) {
   state.client_name_size = size;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_port_name_size(int size) {
   state.port_name_size = size;
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_set_actual_client_name(const char *name) {
   copy_text(state.actual_client_name, sizeof(state.actual_client_name), name);
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_callback_order_count(void) {
   return state.callback_order_count;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_callback_order(int index) {
   if (index < 0 || index >= state.callback_order_count)
      return -1;
   return state.callback_order[index];
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_current_port_count(void) {
   return state.current_ports;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_registration_count(void) {
   return state.successful_registrations;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_unregister_count(void) {
   return state.unregister_count;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_close_count(void) {
   return state.close_count;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_activate_count(void) {
   return state.activate_count;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_deactivate_count(void) {
   return state.deactivate_count;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_recompute_count(void) {
   return state.recompute_count;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_fake_jack_port_latency(
   int index, int mode, int maximum) {
   if (index < 0 || index >= state.successful_registrations)
      return UINT32_MAX;
   const jack_latency_range_t *range = mode == JackCaptureLatency
      ? &state.ports[index].capture_latency
      : &state.ports[index].playback_latency;
   return maximum ? range->max : range->min;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_set_port_latency(
   int index, int mode, uint32_t minimum, uint32_t maximum) {
   if (index < 0 || index >= state.successful_registrations)
      return;
   jack_latency_range_t *range = mode == JackCaptureLatency
      ? &state.ports[index].capture_latency
      : &state.ports[index].playback_latency;
   range->min = minimum;
   range->max = maximum;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_is_active(void) {
   return state.active;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_callbacks_cleared(void) {
   return state.process_callback == NULL && state.shutdown_callback == NULL &&
          state.info_shutdown_callback == NULL &&
          state.buffer_size_callback == NULL &&
          state.sample_rate_callback == NULL && state.xrun_callback == NULL &&
          state.freewheel_callback == NULL && state.latency_callback == NULL;
}

PLUGINHOST_FIXTURE_EXPORT const char *
pluginhost_fake_jack_requested_client_name(void) {
   return state.requested_client_name;
}

PLUGINHOST_FIXTURE_EXPORT const char *
pluginhost_fake_jack_requested_server_name(void) {
   return state.requested_server_name;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_requested_options(void) {
   return (int)state.requested_options;
}

PLUGINHOST_FIXTURE_EXPORT const char *
pluginhost_fake_jack_port_short_name(int index) {
   if (index < 0 || index >= state.successful_registrations)
      return NULL;
   return state.ports[index].short_name;
}

PLUGINHOST_FIXTURE_EXPORT const char *pluginhost_fake_jack_port_alias(int index) {
   if (index < 0 || index >= state.successful_registrations)
      return NULL;
   return state.ports[index].alias;
}

PLUGINHOST_FIXTURE_EXPORT const char *pluginhost_fake_jack_port_type(int index) {
   if (index < 0 || index >= state.successful_registrations)
      return NULL;
   return state.ports[index].type;
}

PLUGINHOST_FIXTURE_EXPORT unsigned long
pluginhost_fake_jack_port_flags(int index) {
   if (index < 0 || index >= state.successful_registrations)
      return 0;
   return state.ports[index].flags;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_set_audio_sample(
   int port_index, uint32_t frame, float value) {
   if (port_index < 0 || port_index >= state.successful_registrations ||
       frame >= FAKE_MAX_FRAMES)
      return;
   state.ports[port_index].audio[frame] = value;
}

PLUGINHOST_FIXTURE_EXPORT float pluginhost_fake_jack_audio_sample(
   int port_index, uint32_t frame) {
   if (port_index < 0 || port_index >= state.successful_registrations ||
       frame >= FAKE_MAX_FRAMES)
      return 0.0f;
   return state.ports[port_index].audio[frame];
}

PLUGINHOST_FIXTURE_EXPORT uint64_t
pluginhost_fake_jack_audio_address(int port_index) {
   if (port_index < 0 || port_index >= state.successful_registrations)
      return 0U;
   return (uint64_t)(uintptr_t)state.ports[port_index].audio;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_add_midi_event(
   int port_index, uint32_t time, const unsigned char *data, uint32_t size) {
   if (port_index < 0 || port_index >= state.successful_registrations ||
       data == NULL || size == 0U)
      return -1;
   struct _jack_port *port = &state.ports[port_index];
   if (port->midi_event_count >= FAKE_MAX_MIDI_EVENTS ||
       size > port->midi_capacity - port->midi_bytes_used)
      return -2;
   if (port->midi_event_count > 0U &&
       time < port->midi_events[port->midi_event_count - 1U].time)
      return -3;
   fake_midi_event_t *event = &port->midi_events[port->midi_event_count++];
   event->time = time;
   event->size = size;
   event->offset = port->midi_bytes_used;
   memcpy(&port->midi_data[port->midi_bytes_used], data, size);
   port->midi_bytes_used += size;
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_clear_midi_events(
   int port_index) {
   if (port_index < 0 || port_index >= state.successful_registrations)
      return;
   state.ports[port_index].midi_event_count = 0U;
   state.ports[port_index].midi_bytes_used = 0U;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_set_midi_capacity(
   int port_index, uint32_t capacity) {
   if (port_index < 0 || port_index >= state.successful_registrations)
      return;
   state.ports[port_index].midi_capacity =
      capacity <= FAKE_MIDI_BYTES ? capacity : FAKE_MIDI_BYTES;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_set_midi_lost_events(
   int port_index, uint32_t count) {
   if (port_index >= 0 && port_index < state.successful_registrations)
      state.ports[port_index].midi_lost_events = count;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_set_midi_event_time(
   int port_index, uint32_t event_index, uint32_t time) {
   if (port_index >= 0 && port_index < state.successful_registrations &&
       event_index < state.ports[port_index].midi_event_count)
      state.ports[port_index].midi_events[event_index].time = time;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_set_midi_event_size(
   int port_index, uint32_t event_index, uint32_t size) {
   if (port_index >= 0 && port_index < state.successful_registrations &&
       event_index < state.ports[port_index].midi_event_count)
      state.ports[port_index].midi_events[event_index].size = size;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_set_midi_get_failure(
   int port_index, int event_index) {
   if (port_index >= 0 && port_index < state.successful_registrations)
      state.ports[port_index].midi_get_failure_index = event_index;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_fake_jack_midi_event_count(
   int port_index) {
   if (port_index < 0 || port_index >= state.successful_registrations)
      return 0U;
   return state.ports[port_index].midi_event_count;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_fake_jack_midi_event_time(
   int port_index, uint32_t event_index) {
   if (port_index < 0 || port_index >= state.successful_registrations ||
       event_index >= state.ports[port_index].midi_event_count)
      return UINT32_MAX;
   return state.ports[port_index].midi_events[event_index].time;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_fake_jack_midi_event_size(
   int port_index, uint32_t event_index) {
   if (port_index < 0 || port_index >= state.successful_registrations ||
       event_index >= state.ports[port_index].midi_event_count)
      return 0U;
   return state.ports[port_index].midi_events[event_index].size;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_midi_event_byte(
   int port_index, uint32_t event_index, uint32_t byte_index) {
   if (port_index < 0 || port_index >= state.successful_registrations ||
       event_index >= state.ports[port_index].midi_event_count)
      return -1;
   const fake_midi_event_t *event =
      &state.ports[port_index].midi_events[event_index];
   if (byte_index >= event->size)
      return -1;
   return state.ports[port_index].midi_data[event->offset + byte_index];
}

PLUGINHOST_FIXTURE_EXPORT uint64_t pluginhost_fake_jack_midi_event_address(
   int port_index, uint32_t event_index) {
   if (port_index < 0 || port_index >= state.successful_registrations ||
       event_index >= state.ports[port_index].midi_event_count)
      return 0U;
   const fake_midi_event_t *event =
      &state.ports[port_index].midi_events[event_index];
   return (uint64_t)(uintptr_t)
      &state.ports[port_index].midi_data[event->offset];
}

PLUGINHOST_FIXTURE_EXPORT int
pluginhost_fake_jack_invoke_process(uint32_t frames) {
   if (!state.active)
      return -100;
   if (state.process_callback == NULL)
      return -101;
   return state.process_callback(frames, state.process_argument);
}

PLUGINHOST_FIXTURE_EXPORT int
pluginhost_fake_jack_force_process(uint32_t frames) {
   if (state.process_callback == NULL)
      return -101;
   return state.process_callback(frames, state.process_argument);
}

typedef struct fake_process_call {
   uint32_t frames;
   int result;
   int force;
} fake_process_call_t;

static void *process_thread_main(void *raw_call) {
   fake_process_call_t *call = raw_call;
   call->result = call->force
      ? pluginhost_fake_jack_force_process(call->frames)
      : pluginhost_fake_jack_invoke_process(call->frames);
   return NULL;
}

static int finish_blocked_process(void) {
   if (!blocked_process_thread_valid)
      return 0;
   (void)pthread_mutex_lock(&process_gate_mutex);
   release_blocked_process = 1;
   (void)pthread_cond_broadcast(&process_gate_condition);
   (void)pthread_mutex_unlock(&process_gate_mutex);
   int status = pthread_join(blocked_process_thread, NULL);
   blocked_process_thread_valid = 0;
   block_in_port_buffer = 0;
   blocked_process_entered = 0;
   release_blocked_process = 0;
   return status;
}

PLUGINHOST_FIXTURE_EXPORT int
pluginhost_fake_jack_begin_blocked_process(uint32_t frames) {
   if (!state.active || state.process_callback == NULL ||
       blocked_process_thread_valid)
      return -1;
   static fake_process_call_t call;
   call.frames = frames;
   call.result = -1;
   call.force = 0;
   (void)pthread_mutex_lock(&process_gate_mutex);
   block_in_port_buffer = 1;
   blocked_process_entered = 0;
   release_blocked_process = 0;
   int status = pthread_create(&blocked_process_thread, NULL,
                               process_thread_main, &call);
   if (status != 0) {
      block_in_port_buffer = 0;
      (void)pthread_mutex_unlock(&process_gate_mutex);
      return status;
   }
   blocked_process_thread_valid = 1;
   while (!blocked_process_entered)
      (void)pthread_cond_wait(&process_gate_condition, &process_gate_mutex);
   (void)pthread_mutex_unlock(&process_gate_mutex);
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT int pluginhost_fake_jack_invoke_process_on_thread(
   uint32_t frames, int force, int *callback_result) {
   if (callback_result == NULL)
      return -1;
   fake_process_call_t call = {.frames = frames, .result = -1, .force = force};
   pthread_t thread;
   int status = pthread_create(&thread, NULL, process_thread_main, &call);
   if (status != 0)
      return status;
   status = pthread_join(thread, NULL);
   if (status != 0)
      return status;
   *callback_result = call.result;
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_invoke_shutdown(
   int status, const char *reason) {
   if (state.info_shutdown_callback != NULL)
      state.info_shutdown_callback((jack_status_t)status, reason,
                                   state.info_shutdown_argument);
   else if (state.shutdown_callback != NULL)
      state.shutdown_callback(state.shutdown_argument);
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_invoke_xrun(void) {
   if (state.xrun_callback != NULL)
      (void)state.xrun_callback(state.xrun_argument);
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_invoke_freewheel(int starting) {
   if (state.freewheel_callback != NULL)
      state.freewheel_callback(starting, state.freewheel_argument);
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_invoke_buffer_size(uint32_t frames) {
   state.buffer_size = frames;
   if (state.buffer_size_callback != NULL)
      (void)state.buffer_size_callback(frames, state.buffer_size_argument);
}

PLUGINHOST_FIXTURE_EXPORT void
pluginhost_fake_jack_invoke_sample_rate(uint32_t frames) {
   state.sample_rate = frames;
   if (state.sample_rate_callback != NULL)
      (void)state.sample_rate_callback(frames, state.sample_rate_argument);
}

PLUGINHOST_FIXTURE_EXPORT void pluginhost_fake_jack_invoke_latency(int mode) {
   if (state.latency_callback != NULL)
      state.latency_callback((jack_latency_callback_mode_t)mode,
                             state.latency_argument);
}

PLUGINHOST_FIXTURE_EXPORT void jack_get_version(int *major, int *minor,
                                                int *micro, int *protocol) {
   if (major != NULL)
      *major = 1;
   if (minor != NULL)
      *minor = 9;
   if (micro != NULL)
      *micro = 22;
   if (protocol != NULL)
      *protocol = 9;
}

PLUGINHOST_FIXTURE_EXPORT const char *jack_get_version_string(void) {
   return "fake-jack-1.9.22";
}

PLUGINHOST_FIXTURE_EXPORT jack_client_t *jack_client_open(
   const char *client_name, jack_options_t options, jack_status_t *status, ...) {
   copy_text(state.requested_client_name,
             sizeof(state.requested_client_name), client_name);
   state.requested_options = options;
   state.requested_server_name[0] = '\0';
   if ((options & JackServerName) != 0) {
      va_list arguments;
      va_start(arguments, status);
      const char *server_name = va_arg(arguments, const char *);
      va_end(arguments);
      copy_text(state.requested_server_name,
                sizeof(state.requested_server_name), server_name);
   }
   if (state.open_failure_status != 0) {
      if (status != NULL)
         *status = state.open_failure_status;
      return NULL;
   }
   if (status != NULL)
      *status = state.open_success_status;
   state.client_open = 1;
   state.active = 0;
   return &state.client;
}

PLUGINHOST_FIXTURE_EXPORT int jack_client_close(jack_client_t *client) {
   if (client != &state.client)
      return -1;
   state.close_count++;
   if (state.close_status != 0)
      return state.close_status;
   int process_status = finish_blocked_process();
   if (process_status != 0)
      return process_status;
   state.client_open = 0;
   state.active = 0;
   state.current_ports = 0;
   for (int index = 0; index < state.successful_registrations; ++index)
      state.ports[index].alive = 0;
   state.process_callback = NULL;
   state.shutdown_callback = NULL;
   state.info_shutdown_callback = NULL;
   state.buffer_size_callback = NULL;
   state.sample_rate_callback = NULL;
   state.xrun_callback = NULL;
   state.freewheel_callback = NULL;
   state.latency_callback = NULL;
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT int jack_client_name_size(void) {
   return state.client_name_size;
}

PLUGINHOST_FIXTURE_EXPORT char *jack_get_client_name(jack_client_t *client) {
   if (client != &state.client || !state.client_open)
      return NULL;
   return state.actual_client_name;
}

PLUGINHOST_FIXTURE_EXPORT int jack_activate(jack_client_t *client) {
   if (client != &state.client || !state.client_open)
      return -1;
   state.activate_count++;
   if (state.activate_status != 0)
      return state.activate_status;
   state.active = 1;
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT int jack_deactivate(jack_client_t *client) {
   if (client != &state.client || !state.client_open)
      return -1;
   state.deactivate_count++;
   if (state.deactivate_status != 0)
      return state.deactivate_status;
   int process_status = finish_blocked_process();
   if (process_status != 0)
      return process_status;
   state.active = 0;
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT void jack_on_shutdown(
   jack_client_t *client, JackShutdownCallback callback, void *argument) {
   if (client == &state.client) {
      record_callback_order(2);
      state.shutdown_callback = callback;
      state.shutdown_argument = argument;
   }
}

PLUGINHOST_FIXTURE_EXPORT void jack_on_info_shutdown(
   jack_client_t *client, JackInfoShutdownCallback callback, void *argument) {
   if (client == &state.client) {
      record_callback_order(3);
      state.info_shutdown_callback = callback;
      state.info_shutdown_argument = argument;
   }
}

PLUGINHOST_FIXTURE_EXPORT int jack_set_process_callback(
   jack_client_t *client, JackProcessCallback callback, void *argument) {
   if (client != &state.client)
      return -1;
   int status = callback_status(1);
   if (status == 0) {
      state.process_callback = callback;
      state.process_argument = argument;
   }
   return status;
}

PLUGINHOST_FIXTURE_EXPORT int jack_set_buffer_size_callback(
   jack_client_t *client, JackBufferSizeCallback callback, void *argument) {
   if (client != &state.client)
      return -1;
   int status = callback_status(4);
   if (status == 0) {
      state.buffer_size_callback = callback;
      state.buffer_size_argument = argument;
      (void)callback(state.buffer_size, argument);
   }
   return status;
}

PLUGINHOST_FIXTURE_EXPORT int jack_set_sample_rate_callback(
   jack_client_t *client, JackSampleRateCallback callback, void *argument) {
   if (client != &state.client)
      return -1;
   int status = callback_status(5);
   if (status == 0) {
      state.sample_rate_callback = callback;
      state.sample_rate_argument = argument;
      (void)callback(state.sample_rate, argument);
   }
   return status;
}

PLUGINHOST_FIXTURE_EXPORT int jack_set_xrun_callback(
   jack_client_t *client, JackXRunCallback callback, void *argument) {
   if (client != &state.client)
      return -1;
   int status = callback_status(6);
   if (status == 0) {
      state.xrun_callback = callback;
      state.xrun_argument = argument;
   }
   return status;
}

PLUGINHOST_FIXTURE_EXPORT int jack_set_freewheel_callback(
   jack_client_t *client, JackFreewheelCallback callback, void *argument) {
   if (client != &state.client)
      return -1;
   int status = callback_status(7);
   if (status == 0) {
      state.freewheel_callback = callback;
      state.freewheel_argument = argument;
   }
   return status;
}

PLUGINHOST_FIXTURE_EXPORT int jack_set_latency_callback(
   jack_client_t *client, JackLatencyCallback callback, void *argument) {
   if (client != &state.client)
      return -1;
   int status = callback_status(8);
   if (status == 0) {
      state.latency_callback = callback;
      state.latency_argument = argument;
   }
   return status;
}

PLUGINHOST_FIXTURE_EXPORT jack_nframes_t
jack_get_sample_rate(jack_client_t *client) {
   return client == &state.client ? state.sample_rate : 0;
}

PLUGINHOST_FIXTURE_EXPORT jack_nframes_t
jack_get_buffer_size(jack_client_t *client) {
   return client == &state.client ? state.buffer_size : 0;
}

PLUGINHOST_FIXTURE_EXPORT jack_port_t *jack_port_register(
   jack_client_t *client, const char *port_name, const char *port_type,
   unsigned long flags, unsigned long buffer_size) {
   (void)buffer_size;
   if (client != &state.client || !state.client_open || port_name == NULL ||
       port_type == NULL)
      return NULL;
   int attempt = state.registration_attempts++;
   if (attempt == state.failed_port_attempt ||
       state.successful_registrations >= FAKE_MAX_PORTS)
      return NULL;

   struct _jack_port *port = &state.ports[state.successful_registrations++];
   memset(port, 0, sizeof(*port));
   port->alive = 1;
   port->midi_capacity = FAKE_MIDI_BYTES;
   port->midi_get_failure_index = -1;
   port->flags = flags;
   copy_text(port->short_name, sizeof(port->short_name), port_name);
   copy_text(port->type, sizeof(port->type), port_type);
   (void)snprintf(port->full_name, sizeof(port->full_name), "%s:%s",
                  state.actual_client_name, port_name);
   state.current_ports++;
   return port;
}

PLUGINHOST_FIXTURE_EXPORT int jack_port_unregister(jack_client_t *client,
                                                   jack_port_t *raw_port) {
   if (client != &state.client || raw_port == NULL)
      return -1;
   struct _jack_port *port = raw_port;
   if (!port->alive)
      return -2;
   if (state.unregister_failure_status != 0)
      return state.unregister_failure_status;
   port->alive = 0;
   state.current_ports--;
   state.unregister_count++;
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT void *jack_port_get_buffer(jack_port_t *raw_port,
                                                     jack_nframes_t frames) {
   struct _jack_port *port = raw_port;
   if (port == NULL || !port->alive || frames > FAKE_MAX_FRAMES)
      return NULL;
   if (block_in_port_buffer) {
      (void)pthread_mutex_lock(&process_gate_mutex);
      blocked_process_entered = 1;
      (void)pthread_cond_broadcast(&process_gate_condition);
      while (!release_blocked_process)
         (void)pthread_cond_wait(&process_gate_condition, &process_gate_mutex);
      (void)pthread_mutex_unlock(&process_gate_mutex);
   }
   return strcmp(port->type, JACK_DEFAULT_MIDI_TYPE) == 0
      ? (void *)port : (void *)port->audio;
}

PLUGINHOST_FIXTURE_EXPORT const char *jack_port_name(const jack_port_t *raw_port) {
   const struct _jack_port *port = raw_port;
   return port != NULL ? port->full_name : NULL;
}

PLUGINHOST_FIXTURE_EXPORT int jack_port_flags(const jack_port_t *raw_port) {
   const struct _jack_port *port = raw_port;
   return port != NULL ? (int)port->flags : 0;
}

PLUGINHOST_FIXTURE_EXPORT int jack_port_set_alias(jack_port_t *raw_port,
                                                  const char *alias) {
   struct _jack_port *port = raw_port;
   int attempt = state.alias_attempts++;
   if (port == NULL || alias == NULL || attempt == state.failed_alias_attempt)
      return -1;
   copy_text(port->alias, sizeof(port->alias), alias);
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT int jack_port_name_size(void) {
   return state.port_name_size;
}

PLUGINHOST_FIXTURE_EXPORT void jack_port_get_latency_range(
   jack_port_t *raw_port, jack_latency_callback_mode_t mode,
   jack_latency_range_t *range) {
   struct _jack_port *port = raw_port;
   if (port == NULL || range == NULL)
      return;
   *range = mode == JackCaptureLatency ? port->capture_latency
                                       : port->playback_latency;
}

PLUGINHOST_FIXTURE_EXPORT void jack_port_set_latency_range(
   jack_port_t *raw_port, jack_latency_callback_mode_t mode,
   jack_latency_range_t *range) {
   struct _jack_port *port = raw_port;
   if (port == NULL || range == NULL)
      return;
   if (mode == JackCaptureLatency)
      port->capture_latency = *range;
   else
      port->playback_latency = *range;
}

PLUGINHOST_FIXTURE_EXPORT int
jack_recompute_total_latencies(jack_client_t *client) {
   if (client != &state.client)
      return -1;
   state.recompute_count++;
   return state.recompute_status;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t
jack_midi_get_event_count(void *port_buffer) {
   struct _jack_port *port = port_buffer;
   return port != NULL ? port->midi_event_count : 0U;
}

PLUGINHOST_FIXTURE_EXPORT int jack_midi_event_get(
   jack_midi_event_t *event, void *port_buffer, uint32_t event_index) {
   struct _jack_port *port = port_buffer;
   if (event == NULL || port == NULL || event_index >= port->midi_event_count ||
       (int)event_index == port->midi_get_failure_index)
      return -1;
   const fake_midi_event_t *source = &port->midi_events[event_index];
   event->time = source->time;
   event->size = source->size;
   event->buffer = &port->midi_data[source->offset];
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT void jack_midi_clear_buffer(void *port_buffer) {
   struct _jack_port *port = port_buffer;
   if (port != NULL) {
      port->midi_event_count = 0U;
      port->midi_bytes_used = 0U;
   }
}

PLUGINHOST_FIXTURE_EXPORT size_t
jack_midi_max_event_size(void *port_buffer) {
   struct _jack_port *port = port_buffer;
   if (port == NULL || port->midi_bytes_used > port->midi_capacity)
      return 0U;
   return port->midi_capacity - port->midi_bytes_used;
}

PLUGINHOST_FIXTURE_EXPORT jack_midi_data_t *jack_midi_event_reserve(
   void *port_buffer, jack_nframes_t time, size_t data_size) {
   struct _jack_port *port = port_buffer;
   if (port == NULL || data_size == 0U || data_size > UINT32_MAX ||
       port->midi_event_count >= FAKE_MAX_MIDI_EVENTS ||
       data_size > port->midi_capacity - port->midi_bytes_used ||
       (port->midi_event_count > 0U &&
        time < port->midi_events[port->midi_event_count - 1U].time))
      return NULL;
   fake_midi_event_t *event = &port->midi_events[port->midi_event_count++];
   event->time = time;
   event->size = (uint32_t)data_size;
   event->offset = port->midi_bytes_used;
   jack_midi_data_t *destination = &port->midi_data[port->midi_bytes_used];
   port->midi_bytes_used += (uint32_t)data_size;
   return destination;
}

PLUGINHOST_FIXTURE_EXPORT int jack_midi_event_write(
   void *port_buffer, jack_nframes_t time, const jack_midi_data_t *data,
   size_t data_size) {
   if (data == NULL)
      return -1;
   jack_midi_data_t *destination =
      jack_midi_event_reserve(port_buffer, time, data_size);
   if (destination == NULL)
      return -1;
   memcpy(destination, data, data_size);
   return 0;
}

PLUGINHOST_FIXTURE_EXPORT uint32_t
jack_midi_get_lost_event_count(void *port_buffer) {
   struct _jack_port *port = port_buffer;
   return port != NULL ? port->midi_lost_events : 0U;
}
