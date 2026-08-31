#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <jack/jack.h>
#include <jack/midiport.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define PEER_TIMEOUT_MILLISECONDS 5000
#define PEER_SLEEP_NANOSECONDS 1000000L
#define PEER_CONNECTION_SETTLE_CYCLES 4U

typedef struct peer_state {
    jack_port_t *inputs[2];
    uint32_t expected_frames;
    _Atomic(uint32_t) armed;
    _Atomic(uint64_t) total_cycles;
    _Atomic(uint64_t) valid_cycles;
    _Atomic(uint64_t) errors;
} peer_state;

_Static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0),
               "peer requires lock-free 32-bit atomics");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0),
               "peer requires lock-free 64-bit atomics");

static int peer_process(jack_nframes_t frames, void *argument) {
    peer_state *state = (peer_state *)argument;
    atomic_fetch_add_explicit(&state->total_cycles, 1, memory_order_relaxed);
    if (atomic_load_explicit(&state->armed, memory_order_acquire) == 0) {
        return 0;
    }

    jack_default_audio_sample_t *first =
        (jack_default_audio_sample_t *)jack_port_get_buffer(state->inputs[0],
                                                            frames);
    jack_default_audio_sample_t *second =
        (jack_default_audio_sample_t *)jack_port_get_buffer(state->inputs[1],
                                                            frames);
    if (first == NULL || second == NULL || frames != state->expected_frames) {
        atomic_fetch_add_explicit(&state->errors, 1, memory_order_relaxed);
        return 0;
    }

    for (jack_nframes_t frame = 0; frame < frames; ++frame) {
        const jack_default_audio_sample_t expected_first =
            (jack_default_audio_sample_t)(1000U + frame);
        const jack_default_audio_sample_t expected_second =
            (jack_default_audio_sample_t)(2000U + frame);
        if (first[frame] != expected_first || second[frame] != expected_second) {
            atomic_fetch_add_explicit(&state->errors, 1, memory_order_relaxed);
            return 0;
        }
    }

    atomic_fetch_add_explicit(&state->valid_cycles, 1, memory_order_release);
    return 0;
}

static uint64_t monotonic_milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (uint64_t)now.tv_sec * 1000U + (uint64_t)now.tv_nsec / 1000000U;
}

static int wait_for_counter(_Atomic(uint64_t) *counter, uint64_t target) {
    const uint64_t start = monotonic_milliseconds();
    struct timespec delay = { .tv_sec = 0, .tv_nsec = PEER_SLEEP_NANOSECONDS };
    while (atomic_load_explicit(counter, memory_order_acquire) < target) {
        if (monotonic_milliseconds() - start >= PEER_TIMEOUT_MILLISECONDS) {
            return -1;
        }
        nanosleep(&delay, NULL);
    }
    return 0;
}

static int require_port(jack_client_t *client, const char *client_name,
                        const char *short_name, const char *expected_type,
                        unsigned long expected_flag,
                        unsigned long rejected_flag) {
    const int name_size = jack_port_name_size();
    if (name_size <= 2) return -1;
    char *full_name = (char *)calloc((size_t)name_size, 1);
    if (full_name == NULL) return -1;
    const int written = snprintf(full_name, (size_t)name_size, "%s:%s",
                                 client_name, short_name);
    if (written < 0 || written >= name_size) {
        free(full_name);
        return -1;
    }

    jack_port_t *port = jack_port_by_name(client, full_name);
    if (port == NULL) {
        fprintf(stderr, "missing live JACK port: %s\n", full_name);
        free(full_name);
        return -1;
    }
    const char *actual_type = jack_port_type(port);
    const unsigned long flags = jack_port_flags(port);
    if (actual_type == NULL || strcmp(actual_type, expected_type) != 0 ||
            (flags & expected_flag) == 0 || (flags & rejected_flag) != 0) {
        fprintf(stderr,
                "unexpected live JACK port metadata: %s type=%s flags=0x%lx\n",
                full_name, actual_type == NULL ? "<null>" : actual_type, flags);
        free(full_name);
        return -1;
    }
    free(full_name);
    return 0;
}

static int inspect_host_ports(jack_client_t *client, const char *host_name) {
    return require_port(client, host_name, "audio_in_1",
                        JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput,
                        JackPortIsOutput) ||
           require_port(client, host_name, "audio_in_2",
                        JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput,
                        JackPortIsOutput) ||
           require_port(client, host_name, "audio_out_1",
                        JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput,
                        JackPortIsInput) ||
           require_port(client, host_name, "audio_out_2",
                        JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput,
                        JackPortIsInput) ||
           require_port(client, host_name, "midi_in_1",
                        JACK_DEFAULT_MIDI_TYPE, JackPortIsInput,
                        JackPortIsOutput) ||
           require_port(client, host_name, "midi_out_1",
                        JACK_DEFAULT_MIDI_TYPE, JackPortIsOutput,
                        JackPortIsInput);
}

static int connect_output(jack_client_t *client, const char *host_name,
                          const char *host_short_name, jack_port_t *peer_port) {
    const int name_size = jack_port_name_size();
    char *source = (char *)calloc((size_t)name_size, 1);
    if (source == NULL) return -1;
    const int written = snprintf(source, (size_t)name_size, "%s:%s",
                                 host_name, host_short_name);
    const char *target = jack_port_name(peer_port);
    const int result = written < 0 || written >= name_size || target == NULL ?
        -1 : jack_connect(client, source, target);
    if (result != 0) {
        fprintf(stderr, "could not connect live JACK ports: %s -> %s (%d)\n",
                source, target == NULL ? "<null>" : target, result);
    }
    free(source);
    return result;
}

static int host_ports_absent(jack_client_t *client, const char *host_name) {
    static const char *short_names[] = {
        "audio_in_1", "audio_in_2", "audio_out_1", "audio_out_2",
        "midi_in_1", "midi_out_1",
    };
    const int name_size = jack_port_name_size();
    if (name_size <= 2) return -1;
    char *full_name = (char *)calloc((size_t)name_size, 1);
    if (full_name == NULL) return -1;
    for (size_t index = 0;
         index < sizeof(short_names) / sizeof(short_names[0]); ++index) {
        const int written = snprintf(full_name, (size_t)name_size, "%s:%s",
                                     host_name, short_names[index]);
        if (written < 0 || written >= name_size ||
                jack_port_by_name(client, full_name) != NULL) {
            fprintf(stderr, "live JACK port remained after client close: %s\n",
                    full_name);
            free(full_name);
            return -1;
        }
    }
    free(full_name);
    return 0;
}

static int handle_commands(peer_state *state, jack_client_t *client,
                           const char *host_name) {
    char command[128];
    while (fgets(command, sizeof(command), stdin) != NULL) {
        unsigned long long cycles = 0;
        if (sscanf(command, "WAIT %llu", &cycles) == 1 && cycles > 0) {
            const uint64_t start = atomic_load_explicit(&state->total_cycles,
                                                        memory_order_acquire);
            if (wait_for_counter(&state->total_cycles, start + cycles) != 0) {
                fprintf(stderr, "peer timed out waiting for %llu live cycles\n",
                        cycles);
                return -1;
            }
            printf("WAITED total=%llu\n", (unsigned long long)
                   atomic_load_explicit(&state->total_cycles,
                                        memory_order_acquire));
            fflush(stdout);
        } else if (strcmp(command, "ABSENT\n") == 0 ||
                   strcmp(command, "ABSENT\r\n") == 0) {
            if (host_ports_absent(client, host_name) != 0) return -1;
            printf("ABSENT\n");
            fflush(stdout);
        } else if (strcmp(command, "QUIT\n") == 0 ||
                   strcmp(command, "QUIT\r\n") == 0) {
            return 0;
        } else {
            fprintf(stderr, "invalid peer command: %s", command);
            return -1;
        }
    }
    fprintf(stderr, "peer command stream closed before QUIT\n");
    return -1;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s HOST_CLIENT FRAMES VALID_CYCLES\n", argv[0]);
        return 2;
    }
    char *end = NULL;
    const unsigned long frames = strtoul(argv[2], &end, 10);
    if (end == argv[2] || *end != '\0' || frames == 0 || frames > UINT32_MAX) {
        fprintf(stderr, "invalid expected frame count\n");
        return 2;
    }
    end = NULL;
    const unsigned long long required_cycles = strtoull(argv[3], &end, 10);
    if (end == argv[3] || *end != '\0' || required_cycles == 0) {
        fprintf(stderr, "invalid required cycle count\n");
        return 2;
    }

    Dl_info library_info;
    if (dladdr((void *)(uintptr_t)&jack_client_open, &library_info) == 0 ||
            library_info.dli_fname == NULL) {
        fprintf(stderr, "could not identify loaded JACK library\n");
        return 1;
    }

    jack_status_t status = 0;
    jack_client_t *client = jack_client_open("pluginhost-4c-peer",
                                              JackNoStartServer, &status);
    if (client == NULL) {
        fprintf(stderr, "peer JACK open failed: status=0x%x\n", (unsigned)status);
        return 1;
    }

    int result = 1;
    int active = 0;
    peer_state state = { .expected_frames = (uint32_t)frames };
    state.inputs[0] = jack_port_register(client, "capture_1",
                                          JACK_DEFAULT_AUDIO_TYPE,
                                          JackPortIsInput, 0);
    state.inputs[1] = jack_port_register(client, "capture_2",
                                          JACK_DEFAULT_AUDIO_TYPE,
                                          JackPortIsInput, 0);
    if (state.inputs[0] == NULL || state.inputs[1] == NULL) {
        fprintf(stderr, "peer could not register capture ports\n");
        goto cleanup;
    }
    if (jack_set_process_callback(client, peer_process, &state) != 0) {
        fprintf(stderr, "peer could not register process callback\n");
        goto cleanup;
    }
    if (inspect_host_ports(client, argv[1]) != 0) goto cleanup;
    if (jack_activate(client) != 0) {
        fprintf(stderr, "peer could not activate\n");
        goto cleanup;
    }
    active = 1;
    if (connect_output(client, argv[1], "audio_out_1", state.inputs[0]) != 0 ||
        connect_output(client, argv[1], "audio_out_2", state.inputs[1]) != 0) {
        goto cleanup;
    }

    const uint64_t settle_start =
        atomic_load_explicit(&state.total_cycles, memory_order_acquire);
    if (wait_for_counter(&state.total_cycles,
                         settle_start + PEER_CONNECTION_SETTLE_CYCLES) != 0) {
        fprintf(stderr, "peer timed out waiting for graph connection settle\n");
        goto cleanup;
    }
    atomic_store_explicit(&state.armed, 1, memory_order_release);
    if (wait_for_counter(&state.valid_cycles, (uint64_t)required_cycles) != 0) {
        fprintf(stderr, "peer timed out waiting for deterministic samples\n");
        goto cleanup;
    }
    atomic_store_explicit(&state.armed, 0, memory_order_release);
    const uint64_t errors = atomic_load_explicit(&state.errors,
                                                 memory_order_acquire);
    if (errors != 0) {
        fprintf(stderr, "peer observed %llu invalid deterministic cycles\n",
                (unsigned long long)errors);
        goto cleanup;
    }

    printf("READY library=%s valid=%llu total=%llu\n", library_info.dli_fname,
           (unsigned long long)atomic_load_explicit(&state.valid_cycles,
                                                    memory_order_acquire),
           (unsigned long long)atomic_load_explicit(&state.total_cycles,
                                                    memory_order_acquire));
    fflush(stdout);
    result = handle_commands(&state, client, argv[1]) == 0 ? 0 : 1;

cleanup:
    if (active) {
        if (jack_deactivate(client) != 0) result = 1;
    }
    if (jack_client_close(client) != 0) result = 1;
    return result;
}
