#include <jack/jack.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TIMEOUT_MS 5000U

typedef struct peer_state {
    jack_port_t *capture;
    jack_port_t *playback;
    uint32_t frames;
    float gain;
    _Atomic uint32_t armed;
    _Atomic uint64_t cycles;
    _Atomic uint64_t valid;
    _Atomic uint64_t errors;
} peer_state;

static uint64_t now_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000U + (uint64_t)now.tv_nsec / 1000000U;
}

static int wait_counter(_Atomic uint64_t *counter, uint64_t target) {
    const uint64_t start = now_ms();
    const struct timespec delay = {0, 1000000L};
    while (atomic_load_explicit(counter, memory_order_acquire) < target) {
        if (now_ms() - start >= TIMEOUT_MS) return -1;
        nanosleep(&delay, NULL);
    }
    return 0;
}

static int process(jack_nframes_t frames, void *raw) {
    peer_state *state = (peer_state *)raw;
    atomic_fetch_add_explicit(&state->cycles, 1, memory_order_relaxed);
    jack_default_audio_sample_t *capture =
        (jack_default_audio_sample_t *)jack_port_get_buffer(state->capture, frames);
    jack_default_audio_sample_t *playback =
        (jack_default_audio_sample_t *)jack_port_get_buffer(state->playback, frames);
    if (capture == NULL || playback == NULL || frames != state->frames) {
        atomic_fetch_add_explicit(&state->errors, 1, memory_order_relaxed);
        return 0;
    }
    for (jack_nframes_t frame = 0; frame < frames; ++frame) {
        const jack_default_audio_sample_t input =
            (jack_default_audio_sample_t)(1000U + frame);
        const jack_default_audio_sample_t expected = input * state->gain;
        playback[frame] = input;
        if (atomic_load_explicit(&state->armed, memory_order_acquire) != 0 &&
            capture[frame] != expected) {
            atomic_fetch_add_explicit(&state->errors, 1, memory_order_relaxed);
            return 0;
        }
    }
    if (atomic_load_explicit(&state->armed, memory_order_acquire) != 0)
        atomic_fetch_add_explicit(&state->valid, 1, memory_order_release);
    return 0;
}

static int require_port(jack_client_t *client, const char *host,
                        const char *short_name, unsigned long flags) {
    const int size = jack_port_name_size();
    if (size <= 2) return -1;
    char *name = calloc((size_t)size, 1);
    if (name == NULL) return -1;
    const int written = snprintf(name, (size_t)size, "%s:%s", host, short_name);
    jack_port_t *port = written < 0 || written >= size ? NULL : jack_port_by_name(client, name);
    const int ok = port != NULL && jack_port_type(port) != NULL &&
        strcmp(jack_port_type(port), JACK_DEFAULT_AUDIO_TYPE) == 0 &&
        (jack_port_flags(port) & flags) != 0;
    free(name);
    return ok ? 0 : -1;
}

static int connect_ports(jack_client_t *client, const char *host,
                         const char *host_port, const char *peer_port) {
    const int size = jack_port_name_size();
    if (size <= 2) return -1;
    char *source = calloc((size_t)size, 1);
    char *target = calloc((size_t)size, 1);
    if (source == NULL || target == NULL) {
        free(source);
        free(target);
        return -1;
    }
    const int source_written = snprintf(source, (size_t)size, "%s:%s", host, host_port);
    const int target_written = snprintf(target, (size_t)size, "%s:%s",
                                       "pluginhost-vst3-peer", peer_port);
    const int result = source_written < 0 || source_written >= size ||
        target_written < 0 || target_written >= size ? -1 :
        jack_connect(client, source, target);
    free(source);
    free(target);
    return result;
}

static int connect_peer_to_host(jack_client_t *client, const char *host,
                                const char *peer_port, const char *host_port) {
    const int size = jack_port_name_size();
    if (size <= 2) return -1;
    char *source = calloc((size_t)size, 1);
    char *target = calloc((size_t)size, 1);
    if (source == NULL || target == NULL) {
        free(source);
        free(target);
        return -1;
    }
    const int source_written = snprintf(source, (size_t)size, "%s:%s",
                                        "pluginhost-vst3-peer", peer_port);
    const int target_written = snprintf(target, (size_t)size, "%s:%s", host, host_port);
    const int result = source_written < 0 || source_written >= size ||
        target_written < 0 || target_written >= size ? -1 :
        jack_connect(client, source, target);
    free(source);
    free(target);
    return result;
}

static int absent(jack_client_t *client, const char *host) {
    const int size = jack_port_name_size();
    if (size <= 2) return -1;
    char *name = calloc((size_t)size, 1);
    if (name == NULL) return -1;
    const int written = snprintf(name, (size_t)size, "%s:audio_in_1", host);
    const int result = written < 0 || written >= size ||
        jack_port_by_name(client, name) != NULL ? -1 : 0;
    free(name);
    return result;
}

static int command_loop(peer_state *state, jack_client_t *client, const char *host) {
    char command[64];
    while (fgets(command, sizeof(command), stdin) != NULL) {
        unsigned long long count = 0;
        if (sscanf(command, "WAIT %llu", &count) == 1 && count > 0) {
            const uint64_t start = atomic_load_explicit(&state->cycles, memory_order_acquire);
            if (wait_counter(&state->cycles, start + count) != 0) return -1;
            printf("WAITED\n");
            fflush(stdout);
        } else if (strcmp(command, "ABSENT\n") == 0) {
            if (absent(client, host) != 0) return -1;
            printf("ABSENT\n");
            fflush(stdout);
        } else if (strcmp(command, "QUIT\n") == 0) {
            return 0;
        } else {
            return -1;
        }
    }
    return -1;
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) return 2;
    char *end = NULL;
    const unsigned long frames = strtoul(argv[2], &end, 10);
    if (end == argv[2] || *end != '\0' || frames == 0 || frames > UINT32_MAX) return 2;
    const unsigned long long required = strtoull(argv[3], &end, 10);
    if (end == argv[3] || *end != '\0' || required == 0) return 2;
    float gain = 1.0f;
    if (argc == 5) {
        gain = strtof(argv[4], &end);
        if (end == argv[4] || *end != '\0' || gain <= 0.0f) return 2;
    }
    jack_status_t status = 0;
    jack_client_t *client = jack_client_open("pluginhost-vst3-peer", JackNoStartServer, &status);
    if (client == NULL) {
        fprintf(stderr, "vst3 peer JACK open failed: status=0x%x\n",
                (unsigned)status);
        return 1;
    }
    peer_state state = {.frames = (uint32_t)frames, .gain = gain};
    state.capture = jack_port_register(client, "capture_1", JACK_DEFAULT_AUDIO_TYPE,
                                        JackPortIsInput, 0);
    state.playback = jack_port_register(client, "playback_1", JACK_DEFAULT_AUDIO_TYPE,
                                        JackPortIsOutput, 0);
    int result = 1;
    if (state.capture == NULL || state.playback == NULL ||
        require_port(client, argv[1], "audio_in_1", JackPortIsInput) != 0 ||
        require_port(client, argv[1], "audio_out_1", JackPortIsOutput) != 0 ||
        jack_set_process_callback(client, process, &state) != 0 ||
        jack_activate(client) != 0 ||
        connect_peer_to_host(client, argv[1], "playback_1", "audio_in_1") != 0 ||
        connect_ports(client, argv[1], "audio_out_1", "capture_1") != 0) {
        fprintf(stderr, "vst3 peer could not connect required JACK ports for %s\n", argv[1]);
        jack_client_close(client);
        return result;
    }
    if (wait_counter(&state.cycles, 4) != 0) goto cleanup;
    atomic_store_explicit(&state.armed, 1, memory_order_release);
    if (wait_counter(&state.valid, required) != 0 ||
        atomic_load_explicit(&state.errors, memory_order_acquire) != 0) goto cleanup;
    atomic_store_explicit(&state.armed, 0, memory_order_release);
    printf("READY cycles=%llu\n",
           (unsigned long long)atomic_load_explicit(&state.valid, memory_order_acquire));
    fflush(stdout);
    result = command_loop(&state, client, argv[1]) == 0 ? 0 : 1;
cleanup:
    if (result != 0)
        fprintf(stderr, "vst3 peer stopped: cycles=%llu valid=%llu errors=%llu gain=%g\n",
                (unsigned long long)atomic_load_explicit(&state.cycles, memory_order_acquire),
                (unsigned long long)atomic_load_explicit(&state.valid, memory_order_acquire),
                (unsigned long long)atomic_load_explicit(&state.errors, memory_order_acquire),
                (double)state.gain);
    atomic_store_explicit(&state.armed, 0, memory_order_release);
    (void)jack_deactivate(client);
    (void)jack_client_close(client);
    return result;
}
