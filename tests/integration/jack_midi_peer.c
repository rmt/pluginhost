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

#define PEER_TIMEOUT_MILLISECONDS 5000U
#define PEER_SLEEP_NANOSECONDS 1000000L
#define PEER_CONNECTION_SETTLE_CYCLES 4U

typedef struct midi_peer_state {
    jack_port_t *sources[2];
    jack_port_t *captures[2];
    uint32_t expected_frames;
    _Atomic(uint32_t) armed;
    _Atomic(uint32_t) capture_started;
    _Atomic(uint64_t) source_cycles;
    _Atomic(uint64_t) capture_cycles;
    _Atomic(uint64_t) valid_cycles;
    _Atomic(uint64_t) source_errors;
    _Atomic(uint64_t) capture_errors;
    _Atomic(uint32_t) mismatch_recorded;
    uint32_t mismatch_counts[2];
    jack_nframes_t mismatch_times[2][4];
    size_t mismatch_sizes[2][4];
    uint8_t mismatch_data[2][4][8];
} midi_peer_state;

_Static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0),
               "MIDI peer requires lock-free 32-bit atomics");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0),
               "MIDI peer requires lock-free 64-bit atomics");

static const uint8_t port_zero_first[] = {0x90U, 60U, 100U};
static const uint8_t port_zero_second[] = {0xf0U, 1U, 2U, 0xf7U};
static const uint8_t port_one_first[] = {0xb1U, 7U, 99U};
static const uint8_t port_one_second[] = {0x81U, 61U, 64U};

static int write_event(void *buffer, jack_nframes_t time,
                       const uint8_t *data, size_t size) {
    return jack_midi_event_write(buffer, time, data, size);
}

static int source_process(jack_nframes_t frames, void *argument) {
    midi_peer_state *state = (midi_peer_state *)argument;
    atomic_fetch_add_explicit(&state->source_cycles, 1, memory_order_relaxed);

    void *first = jack_port_get_buffer(state->sources[0], frames);
    void *second = jack_port_get_buffer(state->sources[1], frames);
    if (first == NULL || second == NULL || frames != state->expected_frames) {
        atomic_fetch_add_explicit(&state->source_errors, 1,
                                  memory_order_relaxed);
        return 0;
    }
    jack_midi_clear_buffer(first);
    jack_midi_clear_buffer(second);
    if (atomic_load_explicit(&state->armed, memory_order_acquire) == 0U)
        return 0;

    if (write_event(first, 2U, port_zero_first, sizeof(port_zero_first)) != 0 ||
        write_event(first, 10U, port_zero_second, sizeof(port_zero_second)) != 0 ||
        write_event(second, 2U, port_one_first, sizeof(port_one_first)) != 0 ||
        write_event(second, 5U, port_one_second, sizeof(port_one_second)) != 0) {
        atomic_fetch_add_explicit(&state->source_errors, 1,
                                  memory_order_relaxed);
    }
    return 0;
}

static int event_matches(void *buffer, uint32_t index, jack_nframes_t time,
                         const uint8_t *data, size_t size) {
    jack_midi_event_t event;
    if (jack_midi_event_get(&event, buffer, index) != 0 ||
        event.time != time || event.size != size || event.buffer == NULL)
        return 0;
    return memcmp(event.buffer, data, size) == 0;
}

static int capture_process(jack_nframes_t frames, void *argument) {
    midi_peer_state *state = (midi_peer_state *)argument;
    atomic_fetch_add_explicit(&state->capture_cycles, 1, memory_order_relaxed);

    void *first = jack_port_get_buffer(state->captures[0], frames);
    void *second = jack_port_get_buffer(state->captures[1], frames);
    if (first == NULL || second == NULL || frames != state->expected_frames) {
        atomic_fetch_add_explicit(&state->capture_errors, 1,
                                  memory_order_relaxed);
        return 0;
    }
    if (atomic_load_explicit(&state->armed, memory_order_acquire) == 0U)
        return 0;

    const uint32_t first_count = jack_midi_get_event_count(first);
    const uint32_t second_count = jack_midi_get_event_count(second);
    const int valid = first_count == 2U && second_count == 2U &&
        event_matches(first, 0U, 2U, port_zero_first,
                      sizeof(port_zero_first)) &&
        event_matches(first, 1U, 10U, port_zero_second,
                      sizeof(port_zero_second)) &&
        event_matches(second, 0U, 2U, port_one_first,
                      sizeof(port_one_first)) &&
        event_matches(second, 1U, 5U, port_one_second,
                      sizeof(port_one_second));
    if (!valid && atomic_load_explicit(&state->mismatch_recorded,
                                        memory_order_relaxed) == 0U) {
        void *buffers[2] = {first, second};
        state->mismatch_counts[0] = first_count;
        state->mismatch_counts[1] = second_count;
        for (uint32_t port = 0U; port < 2U; ++port) {
            const uint32_t count = state->mismatch_counts[port] < 4U
                ? state->mismatch_counts[port] : 4U;
            for (uint32_t index = 0U; index < count; ++index) {
                jack_midi_event_t event;
                if (jack_midi_event_get(&event, buffers[port], index) == 0) {
                    state->mismatch_times[port][index] = event.time;
                    state->mismatch_sizes[port][index] = event.size;
                    const size_t copied = event.size < 8U ? event.size : 8U;
                    if (event.buffer != NULL)
                        memcpy(state->mismatch_data[port][index], event.buffer,
                               copied);
                }
            }
        }
        atomic_store_explicit(&state->mismatch_recorded, 1U,
                              memory_order_release);
    }
    if (valid) {
        atomic_store_explicit(&state->mismatch_recorded, 0U,
                              memory_order_relaxed);
        atomic_store_explicit(&state->capture_started, 1U,
                              memory_order_release);
        atomic_fetch_add_explicit(&state->valid_cycles, 1,
                                  memory_order_release);
    } else if (atomic_load_explicit(&state->capture_started,
                                    memory_order_acquire) != 0U) {
        atomic_fetch_add_explicit(&state->capture_errors, 1,
                                  memory_order_relaxed);
    }
    return 0;
}

static uint64_t monotonic_milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return 0U;
    return (uint64_t)now.tv_sec * 1000U +
           (uint64_t)now.tv_nsec / 1000000U;
}

static int wait_for_counter(_Atomic(uint64_t) *counter, uint64_t target) {
    const uint64_t start = monotonic_milliseconds();
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PEER_SLEEP_NANOSECONDS};
    while (atomic_load_explicit(counter, memory_order_acquire) < target) {
        if (monotonic_milliseconds() - start >= PEER_TIMEOUT_MILLISECONDS)
            return -1;
        nanosleep(&delay, NULL);
    }
    return 0;
}

static int build_host_port_name(char *destination, size_t capacity,
                                const char *host_name,
                                const char *short_name) {
    const int written = snprintf(destination, capacity, "%s:%s",
                                 host_name, short_name);
    return written < 0 || (size_t)written >= capacity ? -1 : 0;
}

static int require_port(jack_client_t *client, const char *host_name,
                        const char *short_name, unsigned long expected_flag,
                        unsigned long rejected_flag) {
    const int name_size = jack_port_name_size();
    if (name_size <= 2)
        return -1;
    char *full_name = (char *)calloc((size_t)name_size, 1U);
    if (full_name == NULL)
        return -1;
    if (build_host_port_name(full_name, (size_t)name_size, host_name,
                             short_name) != 0) {
        free(full_name);
        return -1;
    }
    jack_port_t *port = jack_port_by_name(client, full_name);
    const char *type = port == NULL ? NULL : jack_port_type(port);
    const unsigned long flags = port == NULL ? 0UL :
                                (unsigned long)jack_port_flags(port);
    if (port == NULL || type == NULL ||
        strcmp(type, JACK_DEFAULT_MIDI_TYPE) != 0 ||
        (flags & expected_flag) == 0U || (flags & rejected_flag) != 0U) {
        fprintf(stderr, "unexpected live JACK MIDI port: %s\n", full_name);
        free(full_name);
        return -1;
    }
    free(full_name);
    return 0;
}

static int inspect_host_ports(jack_client_t *client, const char *host_name) {
    return require_port(client, host_name, "midi_in_1", JackPortIsInput,
                        JackPortIsOutput) ||
           require_port(client, host_name, "midi_in_2", JackPortIsInput,
                        JackPortIsOutput) ||
           require_port(client, host_name, "midi_out_1", JackPortIsOutput,
                        JackPortIsInput) ||
           require_port(client, host_name, "midi_out_2", JackPortIsOutput,
                        JackPortIsInput);
}

static int connect_ports(jack_client_t *client, const char *source,
                         const char *target) {
    jack_port_t *source_port = jack_port_by_name(client, source);
    if (source_port != NULL && jack_port_connected_to(source_port, target) != 0)
        return 0;
    const int connected = jack_connect(client, source, target);
    source_port = jack_port_by_name(client, source);
    if (connected == 0 || connected == EEXIST ||
        (source_port != NULL &&
         jack_port_connected_to(source_port, target) != 0))
        return 0;
    return connected;
}

static int connect_graph(jack_client_t *client, midi_peer_state *state,
                         const char *host_name) {
    const int name_size = jack_port_name_size();
    if (name_size <= 2)
        return -1;
    char *host_port = (char *)calloc((size_t)name_size, 1U);
    if (host_port == NULL)
        return -1;
    int result = -1;

    if (build_host_port_name(host_port, (size_t)name_size, host_name,
                             "midi_in_1") != 0 ||
        connect_ports(client, jack_port_name(state->sources[0]), host_port) != 0)
        goto done;
    if (build_host_port_name(host_port, (size_t)name_size, host_name,
                             "midi_in_2") != 0 ||
        connect_ports(client, jack_port_name(state->sources[1]), host_port) != 0)
        goto done;
    if (build_host_port_name(host_port, (size_t)name_size, host_name,
                             "midi_out_1") != 0 ||
        connect_ports(client, host_port, jack_port_name(state->captures[0])) != 0)
        goto done;
    if (build_host_port_name(host_port, (size_t)name_size, host_name,
                             "midi_out_2") != 0 ||
        connect_ports(client, host_port, jack_port_name(state->captures[1])) != 0)
        goto done;
    result = 0;

done:
    free(host_port);
    return result;
}

static int connect_graph_with_retry(jack_client_t *client,
                                    midi_peer_state *state,
                                    const char *host_name) {
    const uint64_t start = monotonic_milliseconds();
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PEER_SLEEP_NANOSECONDS};
    do {
        if (connect_graph(client, state, host_name) == 0)
            return 0;
        nanosleep(&delay, NULL);
    } while (monotonic_milliseconds() - start < PEER_TIMEOUT_MILLISECONDS);
    fprintf(stderr, "could not connect the live JACK MIDI graph\n");
    return -1;
}

static int wait_for_graph_settle(midi_peer_state *state) {
    const uint64_t start = atomic_load_explicit(&state->capture_cycles,
                                                 memory_order_acquire);
    if (wait_for_counter(&state->capture_cycles,
                         start + PEER_CONNECTION_SETTLE_CYCLES) == 0)
        return 0;
    fprintf(stderr, "MIDI peer timed out waiting for graph settle\n");
    return -1;
}

static int host_ports_absent(jack_client_t *client, const char *host_name) {
    static const char *short_names[] = {
        "midi_in_1", "midi_in_2", "midi_out_1", "midi_out_2",
    };
    const int name_size = jack_port_name_size();
    if (name_size <= 2)
        return -1;
    char *full_name = (char *)calloc((size_t)name_size, 1U);
    if (full_name == NULL)
        return -1;
    for (size_t index = 0U;
         index < sizeof(short_names) / sizeof(short_names[0]); ++index) {
        if (build_host_port_name(full_name, (size_t)name_size, host_name,
                                 short_names[index]) != 0 ||
            jack_port_by_name(client, full_name) != NULL) {
            fprintf(stderr, "live JACK MIDI port remained after close: %s\n",
                    full_name);
            free(full_name);
            return -1;
        }
    }
    free(full_name);
    return 0;
}

static int run_event_cycles(midi_peer_state *state, uint64_t cycles) {
    const uint64_t valid_start = atomic_load_explicit(&state->valid_cycles,
                                                       memory_order_acquire);
    const uint64_t source_errors = atomic_load_explicit(&state->source_errors,
                                                         memory_order_acquire);
    const uint64_t capture_errors = atomic_load_explicit(&state->capture_errors,
                                                          memory_order_acquire);
    atomic_store_explicit(&state->capture_started, 0U, memory_order_release);
    atomic_store_explicit(&state->mismatch_recorded, 0U, memory_order_release);
    atomic_store_explicit(&state->armed, 1U, memory_order_release);
    const int waited = wait_for_counter(&state->valid_cycles,
                                         valid_start + cycles);
    atomic_store_explicit(&state->armed, 0U, memory_order_release);
    const uint64_t capture_stop = atomic_load_explicit(
        &state->capture_cycles, memory_order_acquire);
    const uint64_t source_stop = atomic_load_explicit(
        &state->source_cycles, memory_order_acquire);
    const int callbacks_settled =
        wait_for_counter(&state->capture_cycles, capture_stop + 2U) == 0 &&
        wait_for_counter(&state->source_cycles, source_stop + 2U) == 0;
    const uint64_t source_errors_after = atomic_load_explicit(
        &state->source_errors, memory_order_acquire);
    const uint64_t capture_errors_after = atomic_load_explicit(
        &state->capture_errors, memory_order_acquire);
    if (waited != 0 || !callbacks_settled ||
        source_errors_after != source_errors ||
        capture_errors_after != capture_errors) {
        fprintf(stderr,
                "MIDI run failed: waited=%d settled=%d valid=%llu/%llu "
                "source-errors=%llu/%llu capture-errors=%llu/%llu\n",
                waited, callbacks_settled,
                (unsigned long long)atomic_load_explicit(
                    &state->valid_cycles, memory_order_acquire),
                (unsigned long long)(valid_start + cycles),
                (unsigned long long)source_errors_after,
                (unsigned long long)source_errors,
                (unsigned long long)capture_errors_after,
                (unsigned long long)capture_errors);
        if (atomic_load_explicit(&state->mismatch_recorded,
                                 memory_order_acquire) != 0U) {
            for (uint32_t port = 0U; port < 2U; ++port) {
                fprintf(stderr, "MIDI capture port %u count=%u", port,
                        state->mismatch_counts[port]);
                const uint32_t count = state->mismatch_counts[port] < 4U
                    ? state->mismatch_counts[port] : 4U;
                for (uint32_t index = 0U; index < count; ++index) {
                    fprintf(stderr, " event%u=(time=%u size=%zu first=0x%02x)",
                            index, state->mismatch_times[port][index],
                            state->mismatch_sizes[port][index],
                            state->mismatch_data[port][index][0]);
                }
                fputc('\n', stderr);
            }
        }
        return -1;
    }
    return 0;
}

static int handle_commands(midi_peer_state *state, jack_client_t *client,
                           const char *host_name) {
    char command[128];
    while (fgets(command, sizeof(command), stdin) != NULL) {
        unsigned long long count = 0U;
        if (sscanf(command, "RUN %llu", &count) == 1 && count > 0U) {
            if (connect_graph_with_retry(client, state, host_name) != 0 ||
                wait_for_graph_settle(state) != 0 ||
                run_event_cycles(state, (uint64_t)count) != 0) {
                fprintf(stderr, "peer failed live MIDI run of %llu cycles\n",
                        count);
                return -1;
            }
            printf("RAN valid=%llu total=%llu\n",
                   (unsigned long long)atomic_load_explicit(
                       &state->valid_cycles, memory_order_acquire),
                   (unsigned long long)atomic_load_explicit(
                       &state->capture_cycles, memory_order_acquire));
            fflush(stdout);
        } else if (sscanf(command, "WAIT %llu", &count) == 1 && count > 0U) {
            const uint64_t start = atomic_load_explicit(&state->capture_cycles,
                                                         memory_order_acquire);
            if (wait_for_counter(&state->capture_cycles,
                                 start + (uint64_t)count) != 0) {
                fprintf(stderr, "peer timed out waiting for %llu live cycles\n",
                        count);
                return -1;
            }
            printf("WAITED total=%llu\n",
                   (unsigned long long)atomic_load_explicit(
                       &state->capture_cycles, memory_order_acquire));
            fflush(stdout);
        } else if (strcmp(command, "ABSENT\n") == 0 ||
                   strcmp(command, "ABSENT\r\n") == 0) {
            if (host_ports_absent(client, host_name) != 0)
                return -1;
            printf("ABSENT\n");
            fflush(stdout);
        } else if (strcmp(command, "QUIT\n") == 0 ||
                   strcmp(command, "QUIT\r\n") == 0) {
            return 0;
        } else {
            fprintf(stderr, "invalid MIDI peer command: %s", command);
            return -1;
        }
    }
    fprintf(stderr, "MIDI peer command stream closed before QUIT\n");
    return -1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s HOST_CLIENT FRAMES\n", argv[0]);
        return 2;
    }
    char *end = NULL;
    const unsigned long frames = strtoul(argv[2], &end, 10);
    if (end == argv[2] || *end != '\0' || frames <= 10U ||
        frames > UINT32_MAX) {
        fprintf(stderr, "invalid expected MIDI frame count\n");
        return 2;
    }

    Dl_info library_info;
    if (dladdr((void *)(uintptr_t)&jack_client_open, &library_info) == 0 ||
        library_info.dli_fname == NULL) {
        fprintf(stderr, "could not identify loaded JACK library\n");
        return 1;
    }

    jack_status_t status = 0U;
    jack_client_t *injector = jack_client_open("pluginhost-6b-injector",
                                                JackNoStartServer, &status);
    if (injector == NULL) {
        fprintf(stderr, "MIDI injector JACK open failed: status=0x%x\n",
                (unsigned)status);
        return 1;
    }
    status = 0U;
    jack_client_t *capture = jack_client_open("pluginhost-6b-capture",
                                               JackNoStartServer, &status);
    if (capture == NULL) {
        fprintf(stderr, "MIDI capture JACK open failed: status=0x%x\n",
                (unsigned)status);
        jack_client_close(injector);
        return 1;
    }

    int result = 1;
    int injector_active = 0;
    int capture_active = 0;
    midi_peer_state state = {.expected_frames = (uint32_t)frames};
    state.sources[0] = jack_port_register(injector, "send_1",
                                           JACK_DEFAULT_MIDI_TYPE,
                                           JackPortIsOutput, 0U);
    state.sources[1] = jack_port_register(injector, "send_2",
                                           JACK_DEFAULT_MIDI_TYPE,
                                           JackPortIsOutput, 0U);
    state.captures[0] = jack_port_register(capture, "capture_1",
                                            JACK_DEFAULT_MIDI_TYPE,
                                            JackPortIsInput, 0U);
    state.captures[1] = jack_port_register(capture, "capture_2",
                                            JACK_DEFAULT_MIDI_TYPE,
                                            JackPortIsInput, 0U);
    if (state.sources[0] == NULL || state.sources[1] == NULL ||
        state.captures[0] == NULL || state.captures[1] == NULL) {
        fprintf(stderr, "MIDI peer could not register ports\n");
        goto cleanup;
    }
    if (jack_set_process_callback(injector, source_process, &state) != 0 ||
        jack_set_process_callback(capture, capture_process, &state) != 0) {
        fprintf(stderr, "MIDI peer could not register process callbacks\n");
        goto cleanup;
    }
    if (inspect_host_ports(capture, argv[1]) != 0)
        goto cleanup;
    if (jack_activate(capture) != 0) {
        fprintf(stderr, "MIDI capture peer could not activate\n");
        goto cleanup;
    }
    capture_active = 1;
    if (jack_activate(injector) != 0) {
        fprintf(stderr, "MIDI injector peer could not activate\n");
        goto cleanup;
    }
    injector_active = 1;
    if (connect_graph_with_retry(injector, &state, argv[1]) != 0)
        goto cleanup;

    if (wait_for_graph_settle(&state) != 0)
        goto cleanup;

    printf("READY library=%s total=%llu\n", library_info.dli_fname,
           (unsigned long long)atomic_load_explicit(&state.capture_cycles,
                                                    memory_order_acquire));
    fflush(stdout);
    result = handle_commands(&state, capture, argv[1]) == 0 ? 0 : 1;

cleanup:
    atomic_store_explicit(&state.armed, 0U, memory_order_release);
    if (injector_active && jack_deactivate(injector) != 0)
        result = 1;
    if (capture_active && jack_deactivate(capture) != 0)
        result = 1;
    if (jack_client_close(injector) != 0)
        result = 1;
    if (jack_client_close(capture) != 0)
        result = 1;
    return result;
}
