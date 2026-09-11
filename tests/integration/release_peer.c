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

#define RELEASE_MAX_PORTS 64U
#define RELEASE_NAME_CAP 256U
#define RELEASE_TIMEOUT_MILLISECONDS 10000U
#define RELEASE_SLEEP_NANOSECONDS 1000000L
#define RELEASE_SETTLE_CYCLES 4U

_Static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0),
               "release peer requires lock-free 32-bit atomics");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0),
               "release peer requires lock-free 64-bit atomics");

typedef enum release_mode {
    RELEASE_SYNTH,
    RELEASE_EFFECT,
    RELEASE_PORTS,
} release_mode;

typedef struct release_state {
    release_mode mode;
    uint32_t expected_frames;
    jack_port_t *midi_source;
    jack_port_t *audio_sources[RELEASE_MAX_PORTS];
    jack_port_t *audio_captures[RELEASE_MAX_PORTS];
    char host_audio_inputs[RELEASE_MAX_PORTS][RELEASE_NAME_CAP];
    size_t host_audio_input_count;
    char host_audio_outputs[RELEASE_MAX_PORTS][RELEASE_NAME_CAP];
    size_t host_audio_output_count;
    char host_midi_inputs[RELEASE_MAX_PORTS][RELEASE_NAME_CAP];
    size_t host_midi_input_count;
    char host_midi_outputs[RELEASE_MAX_PORTS][RELEASE_NAME_CAP];
    size_t host_midi_output_count;
    _Atomic(uint32_t) armed;
    _Atomic(uint32_t) event_phase;
    _Atomic(uint64_t) process_cycles;
    _Atomic(uint64_t) nonzero_samples;
    _Atomic(uint64_t) changed_samples;
    _Atomic(uint64_t) output_samples;
    _Atomic(uint64_t) errors;
    _Atomic(uint64_t) nonzero_by_channel[RELEASE_MAX_PORTS];
    _Atomic(uint64_t) changed_by_channel[RELEASE_MAX_PORTS];
} release_state;

static int compare_names(const void *left, const void *right) {
    const char *left_name = (const char *)left;
    const char *right_name = (const char *)right;
    return strcmp(left_name, right_name);
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
    const struct timespec delay = {
        .tv_sec = 0,
        .tv_nsec = RELEASE_SLEEP_NANOSECONDS,
    };
    while (atomic_load_explicit(counter, memory_order_acquire) < target) {
        if (monotonic_milliseconds() - start >=
            RELEASE_TIMEOUT_MILLISECONDS)
            return -1;
        nanosleep(&delay, NULL);
    }
    return 0;
}

static int copy_name(char destination[RELEASE_NAME_CAP], const char *source) {
    const int written = snprintf(destination, RELEASE_NAME_CAP, "%s", source);
    return written < 0 || (size_t)written >= RELEASE_NAME_CAP ? -1 : 0;
}

static int collect_ports(jack_client_t *client, const char *host_name,
                         const char *type, unsigned long flags,
                         char names[][RELEASE_NAME_CAP], size_t *count) {
    const char **ports = jack_get_ports(client, host_name, type, flags);
    if (ports == NULL) {
        *count = 0U;
        return 0;
    }

    size_t found = 0U;
    while (ports[found] != NULL) {
        if (found >= RELEASE_MAX_PORTS ||
            copy_name(names[found], ports[found]) != 0) {
            jack_free(ports);
            return -1;
        }
        found += 1U;
    }
    jack_free(ports);
    qsort(names, found, sizeof(names[0]), compare_names);
    *count = found;
    return 0;
}

static int build_host_port_name(char destination[RELEASE_NAME_CAP],
                                const char *host_name,
                                const char *short_name) {
    const int written = snprintf(destination, RELEASE_NAME_CAP, "%s:%s",
                                 host_name, short_name);
    return written < 0 || (size_t)written >= RELEASE_NAME_CAP ? -1 : 0;
}

static int require_port(jack_client_t *client, const char *host_name,
                        const char *short_name, const char *type,
                        unsigned long expected_flag,
                        unsigned long rejected_flag) {
    char full_name[RELEASE_NAME_CAP];
    if (build_host_port_name(full_name, host_name, short_name) != 0)
        return -1;

    jack_port_t *port = jack_port_by_name(client, full_name);
    if (port == NULL)
        return -1;
    const char *actual_type = jack_port_type(port);
    const unsigned long actual_flags = jack_port_flags(port);
    if (actual_type == NULL || strcmp(actual_type, type) != 0 ||
        (actual_flags & expected_flag) == 0U ||
        (actual_flags & rejected_flag) != 0U)
        return -1;
    return 0;
}

static int verify_combined_ports(jack_client_t *client,
                                 release_state *state,
                                 const char *host_name) {
    static const char *const audio_inputs[] = {
        "audio_in_1", "audio_in_2", "audio_in_3",
    };
    static const char *const audio_outputs[] = {
        "audio_out_1", "audio_out_2", "audio_out_3", "audio_out_4",
        "audio_out_5",
    };
    static const char *const midi_inputs[] = {
        "midi_in_1", "midi_in_2",
    };
    static const char *const midi_outputs[] = {
        "midi_out_1",
    };

    if (collect_ports(client, host_name, JACK_DEFAULT_AUDIO_TYPE,
                      JackPortIsInput, state->host_audio_inputs,
                      &state->host_audio_input_count) != 0 ||
        collect_ports(client, host_name, JACK_DEFAULT_AUDIO_TYPE,
                      JackPortIsOutput, state->host_audio_outputs,
                      &state->host_audio_output_count) != 0 ||
        collect_ports(client, host_name, JACK_DEFAULT_MIDI_TYPE,
                      JackPortIsInput, state->host_midi_inputs,
                      &state->host_midi_input_count) != 0 ||
        collect_ports(client, host_name, JACK_DEFAULT_MIDI_TYPE,
                      JackPortIsOutput, state->host_midi_outputs,
                      &state->host_midi_output_count) != 0)
        return -1;

    if (state->host_audio_input_count !=
            sizeof(audio_inputs) / sizeof(audio_inputs[0]) ||
        state->host_audio_output_count !=
            sizeof(audio_outputs) / sizeof(audio_outputs[0]) ||
        state->host_midi_input_count !=
            sizeof(midi_inputs) / sizeof(midi_inputs[0]) ||
        state->host_midi_output_count !=
            sizeof(midi_outputs) / sizeof(midi_outputs[0]))
        return -1;

    for (size_t index = 0U;
         index < sizeof(audio_inputs) / sizeof(audio_inputs[0]); ++index) {
        if (require_port(client, host_name, audio_inputs[index],
                         JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput,
                         JackPortIsOutput) != 0)
            return -1;
    }
    for (size_t index = 0U;
         index < sizeof(audio_outputs) / sizeof(audio_outputs[0]); ++index) {
        if (require_port(client, host_name, audio_outputs[index],
                         JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput,
                         JackPortIsInput) != 0)
            return -1;
    }
    for (size_t index = 0U;
         index < sizeof(midi_inputs) / sizeof(midi_inputs[0]); ++index) {
        if (require_port(client, host_name, midi_inputs[index],
                         JACK_DEFAULT_MIDI_TYPE, JackPortIsInput,
                         JackPortIsOutput) != 0)
            return -1;
    }
    for (size_t index = 0U;
         index < sizeof(midi_outputs) / sizeof(midi_outputs[0]); ++index) {
        if (require_port(client, host_name, midi_outputs[index],
                         JACK_DEFAULT_MIDI_TYPE, JackPortIsOutput,
                         JackPortIsInput) != 0)
            return -1;
    }
    return 0;
}

static int register_audio_ports(jack_client_t *client, jack_port_t **ports,
                                size_t count, const char *stem,
                                unsigned long flags) {
    for (size_t index = 0U; index < count; ++index) {
        char name[RELEASE_NAME_CAP];
        const int written = snprintf(name, sizeof(name), "%s_%zu", stem,
                                     index + 1U);
        if (written < 0 || (size_t)written >= sizeof(name))
            return -1;
        ports[index] = jack_port_register(client, name,
                                          JACK_DEFAULT_AUDIO_TYPE, flags, 0U);
        if (ports[index] == NULL)
            return -1;
    }
    return 0;
}

static int connect_ports(jack_client_t *client, const char *source,
                         const char *target) {
    const int connected = jack_connect(client, source, target);
    if (connected == 0 || connected == EEXIST)
        return 0;
    jack_port_t *source_port = jack_port_by_name(client, source);
    if (source_port != NULL &&
        jack_port_connected_to(source_port, target) != 0)
        return 0;
    return connected;
}

static float input_sample(size_t channel, jack_nframes_t frame) {
    const unsigned int phase = (unsigned int)frame +
                               (unsigned int)(channel & 1U);
    const float amplitude = 0.8f + 0.1f * (float)(channel % 3U);
    return (phase & 1U) == 0U ? amplitude : -amplitude;
}

static int release_process(jack_nframes_t frames, void *argument) {
    release_state *state = (release_state *)argument;
    const uint64_t cycle = atomic_fetch_add_explicit(
        &state->process_cycles, 1U, memory_order_relaxed);
    (void)cycle;

    if (frames != state->expected_frames)
        atomic_fetch_add_explicit(&state->errors, 1U, memory_order_relaxed);

    if (state->mode == RELEASE_PORTS)
        return 0;

    const uint32_t armed = atomic_load_explicit(&state->armed,
                                                memory_order_acquire);
    if (state->mode == RELEASE_SYNTH) {
        void *midi = jack_port_get_buffer(state->midi_source, frames);
        if (midi == NULL) {
            atomic_fetch_add_explicit(&state->errors, 1U,
                                      memory_order_relaxed);
            return 0;
        }
        jack_midi_clear_buffer(midi);
        if (armed != 0U) {
            const uint32_t phase = atomic_fetch_add_explicit(
                &state->event_phase, 1U, memory_order_relaxed);
            static const uint8_t note_on[] = {0x90U, 60U, 100U};
            static const uint8_t note_off[] = {0x80U, 60U, 64U};
            if (phase == 0U && jack_midi_event_write(
                    midi, frames > 8U ? 8U : 0U, note_on,
                    sizeof(note_on)) != 0)
                atomic_fetch_add_explicit(&state->errors, 1U,
                                          memory_order_relaxed);
            if (phase == 8U && jack_midi_event_write(
                    midi, frames > 48U ? 48U : frames - 1U, note_off,
                    sizeof(note_off)) != 0)
                atomic_fetch_add_explicit(&state->errors, 1U,
                                          memory_order_relaxed);
        }
    } else {
        for (size_t channel = 0U;
             channel < state->host_audio_input_count; ++channel) {
            void *buffer = jack_port_get_buffer(
                state->audio_sources[channel], frames);
            if (buffer == NULL) {
                atomic_fetch_add_explicit(&state->errors, 1U,
                                          memory_order_relaxed);
                continue;
            }
            if (armed != 0U) {
                jack_default_audio_sample_t *samples =
                    (jack_default_audio_sample_t *)buffer;
                for (jack_nframes_t frame = 0U; frame < frames; ++frame)
                    samples[frame] = input_sample(channel, frame);
            }
        }
    }

    for (size_t channel = 0U;
         channel < state->host_audio_output_count; ++channel) {
        void *buffer = jack_port_get_buffer(
            state->audio_captures[channel], frames);
        if (buffer == NULL) {
            atomic_fetch_add_explicit(&state->errors, 1U,
                                      memory_order_relaxed);
            continue;
        }
        if (armed == 0U)
            continue;
        const jack_default_audio_sample_t *samples =
            (const jack_default_audio_sample_t *)buffer;
        for (jack_nframes_t frame = 0U; frame < frames; ++frame) {
            const float sample = samples[frame];
            atomic_fetch_add_explicit(&state->output_samples, 1U,
                                      memory_order_relaxed);
            if (sample != 0.0f) {
                atomic_fetch_add_explicit(&state->nonzero_samples, 1U,
                                          memory_order_relaxed);
                atomic_fetch_add_explicit(
                    &state->nonzero_by_channel[channel], 1U,
                    memory_order_relaxed);
            }
            if (state->mode == RELEASE_EFFECT &&
                sample != input_sample(channel, frame)) {
                atomic_fetch_add_explicit(&state->changed_samples, 1U,
                                          memory_order_relaxed);
                atomic_fetch_add_explicit(
                    &state->changed_by_channel[channel], 1U,
                    memory_order_relaxed);
            }
        }
    }
    return 0;
}

static uint64_t output_channel_errors(const release_state *state) {
    if (state->mode == RELEASE_PORTS)
        return 0U;
    uint64_t failures = 0U;
    for (size_t channel = 0U;
         channel < state->host_audio_output_count; ++channel) {
        if (atomic_load_explicit(&state->nonzero_by_channel[channel],
                                 memory_order_acquire) == 0U)
            failures += 1U;
        if (state->mode == RELEASE_EFFECT &&
            atomic_load_explicit(&state->changed_by_channel[channel],
                                 memory_order_acquire) == 0U)
            failures += 1U;
    }
    return failures;
}

static int connect_audio_graph(jack_client_t *client,
                               const release_state *state) {
    if (state->mode == RELEASE_SYNTH) {
        if (state->host_midi_input_count == 0U)
            return -1;
        const char *source = jack_port_name(state->midi_source);
        if (source == NULL || connect_ports(client, source,
                                             state->host_midi_inputs[0]) != 0)
            return -1;
        for (size_t index = 0U;
             index < state->host_audio_output_count; ++index) {
            const char *target = jack_port_name(state->audio_captures[index]);
            if (target == NULL || connect_ports(
                    client, state->host_audio_outputs[index], target) != 0)
                return -1;
        }
        return 0;
    }

    for (size_t index = 0U;
         index < state->host_audio_input_count; ++index) {
        const char *source = jack_port_name(state->audio_sources[index]);
        if (source == NULL || connect_ports(
                client, source, state->host_audio_inputs[index]) != 0)
            return -1;
    }
    for (size_t index = 0U;
         index < state->host_audio_output_count; ++index) {
        const char *target = jack_port_name(state->audio_captures[index]);
        if (target == NULL || connect_ports(
                client, state->host_audio_outputs[index], target) != 0)
            return -1;
    }
    return 0;
}

static int host_ports_absent(jack_client_t *client,
                             const release_state *state) {
    const char *const groups[] = {
        (const char *)state->host_audio_inputs,
        (const char *)state->host_audio_outputs,
        (const char *)state->host_midi_inputs,
        (const char *)state->host_midi_outputs,
    };
    const size_t counts[] = {
        state->host_audio_input_count,
        state->host_audio_output_count,
        state->host_midi_input_count,
        state->host_midi_output_count,
    };
    for (size_t group = 0U; group < sizeof(groups) / sizeof(groups[0]);
         ++group) {
        const char (*names)[RELEASE_NAME_CAP] =
            (const char (*)[RELEASE_NAME_CAP])groups[group];
        for (size_t index = 0U; index < counts[group]; ++index) {
            if (jack_port_by_name(client, names[index]) != NULL)
                return -1;
        }
    }
    return 0;
}

static int run_cycles(release_state *state, uint64_t cycles) {
    const uint64_t start = atomic_load_explicit(&state->process_cycles,
                                                memory_order_acquire);
    atomic_store_explicit(&state->event_phase, 0U, memory_order_release);
    atomic_store_explicit(&state->armed, 1U, memory_order_release);
    const int waited = wait_for_counter(&state->process_cycles, start + cycles);
    atomic_store_explicit(&state->armed, 0U, memory_order_release);
    if (waited != 0)
        return -1;
    return wait_for_counter(&state->process_cycles,
                            start + cycles + RELEASE_SETTLE_CYCLES);
}

static int handle_commands(release_state *state, jack_client_t *client) {
    char command[128];
    while (fgets(command, sizeof(command), stdin) != NULL) {
        unsigned long long count = 0U;
        if (sscanf(command, "RUN %llu", &count) == 1U && count > 0U) {
            if (run_cycles(state, (uint64_t)count) != 0) {
                fprintf(stderr, "release peer timed out waiting for cycles\n");
                return -1;
            }
            const uint64_t channel_errors = output_channel_errors(state);
            printf("RAN cycles=%llu outputs=%llu nonzero=%llu changed=%llu "
                   "channel-errors=%llu errors=%llu\n",
                   count,
                   (unsigned long long)atomic_load_explicit(
                       &state->output_samples, memory_order_acquire),
                   (unsigned long long)atomic_load_explicit(
                       &state->nonzero_samples, memory_order_acquire),
                   (unsigned long long)atomic_load_explicit(
                       &state->changed_samples, memory_order_acquire),
                   (unsigned long long)channel_errors,
                   (unsigned long long)atomic_load_explicit(
                       &state->errors, memory_order_acquire));
            fflush(stdout);
        } else if (sscanf(command, "WAIT %llu", &count) == 1U && count > 0U) {
            const uint64_t start = atomic_load_explicit(
                &state->process_cycles, memory_order_acquire);
            if (wait_for_counter(&state->process_cycles,
                                 start + (uint64_t)count) != 0)
                return -1;
            printf("WAITED cycles=%llu\n", (unsigned long long)count);
            fflush(stdout);
        } else if (strcmp(command, "STATS\n") == 0 ||
                   strcmp(command, "STATS\r\n") == 0) {
            printf("STATS cycles=%llu outputs=%llu nonzero=%llu changed=%llu errors=%llu\n",
                   (unsigned long long)atomic_load_explicit(
                       &state->process_cycles, memory_order_acquire),
                   (unsigned long long)atomic_load_explicit(
                       &state->output_samples, memory_order_acquire),
                   (unsigned long long)atomic_load_explicit(
                       &state->nonzero_samples, memory_order_acquire),
                   (unsigned long long)atomic_load_explicit(
                       &state->changed_samples, memory_order_acquire),
                   (unsigned long long)atomic_load_explicit(
                       &state->errors, memory_order_acquire));
            fflush(stdout);
        } else if (strcmp(command, "ABSENT\n") == 0 ||
                   strcmp(command, "ABSENT\r\n") == 0) {
            if (host_ports_absent(client, state) != 0)
                return -1;
            printf("ABSENT\n");
            fflush(stdout);
        } else if (strcmp(command, "QUIT\n") == 0 ||
                   strcmp(command, "QUIT\r\n") == 0) {
            return 0;
        } else {
            fprintf(stderr, "invalid release peer command: %s", command);
            return -1;
        }
    }
    fprintf(stderr, "release peer command stream closed before QUIT\n");
    return -1;
}

static int parse_mode(const char *value, release_mode *mode) {
    if (strcmp(value, "synth") == 0) {
        *mode = RELEASE_SYNTH;
        return 0;
    }
    if (strcmp(value, "effect") == 0) {
        *mode = RELEASE_EFFECT;
        return 0;
    }
    if (strcmp(value, "ports") == 0) {
        *mode = RELEASE_PORTS;
        return 0;
    }
    return -1;
}

static int parse_frames(const char *value, uint32_t *frames) {
    char *end = NULL;
    const unsigned long parsed = strtoul(value, &end, 10);
    if (end == value || *end != '\0' || parsed == 0U ||
        parsed > UINT32_MAX)
        return -1;
    *frames = (uint32_t)parsed;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s MODE HOST_CLIENT FRAMES\n", argv[0]);
        return 2;
    }

    release_mode mode;
    uint32_t frames;
    if (parse_mode(argv[1], &mode) != 0 || parse_frames(argv[3], &frames) != 0) {
        fprintf(stderr, "invalid release peer mode or frame count\n");
        return 2;
    }

    Dl_info library_info;
    if (dladdr((void *)(uintptr_t)&jack_client_open, &library_info) == 0 ||
        library_info.dli_fname == NULL) {
        fprintf(stderr, "could not identify loaded JACK library\n");
        return 1;
    }

    const char *client_name = mode == RELEASE_SYNTH
        ? "pluginhost-11c-release-synth"
        : mode == RELEASE_EFFECT
            ? "pluginhost-11c-release-effect"
            : "pluginhost-11c-release-ports";
    jack_status_t status = 0U;
    jack_client_t *client = jack_client_open(client_name, JackNoStartServer,
                                             &status);
    if (client == NULL) {
        fprintf(stderr, "release peer JACK open failed: status=0x%x\n",
                (unsigned)status);
        return 1;
    }

    release_state state = {.mode = mode, .expected_frames = frames};
    int result = 1;
    int active = 0;
    if (mode == RELEASE_PORTS) {
        if (verify_combined_ports(client, &state, argv[2]) != 0)
            goto cleanup;
    } else {
        if (collect_ports(client, argv[2], JACK_DEFAULT_AUDIO_TYPE,
                          JackPortIsInput, state.host_audio_inputs,
                          &state.host_audio_input_count) != 0 ||
            collect_ports(client, argv[2], JACK_DEFAULT_AUDIO_TYPE,
                          JackPortIsOutput, state.host_audio_outputs,
                          &state.host_audio_output_count) != 0)
            goto cleanup;
        if (mode == RELEASE_SYNTH) {
            if (state.host_audio_output_count == 0U ||
                collect_ports(client, argv[2], JACK_DEFAULT_MIDI_TYPE,
                              JackPortIsInput, state.host_midi_inputs,
                              &state.host_midi_input_count) != 0 ||
                state.host_midi_input_count == 0U)
                goto cleanup;
            state.midi_source = jack_port_register(
                client, "midi_source", JACK_DEFAULT_MIDI_TYPE,
                JackPortIsOutput, 0U);
            if (state.midi_source == NULL ||
                register_audio_ports(client, state.audio_captures,
                                     state.host_audio_output_count,
                                     "audio_capture", JackPortIsInput) != 0)
                goto cleanup;
        } else {
            if (state.host_audio_input_count == 0U ||
                state.host_audio_output_count == 0U ||
                register_audio_ports(client, state.audio_sources,
                                     state.host_audio_input_count,
                                     "audio_source", JackPortIsOutput) != 0 ||
                register_audio_ports(client, state.audio_captures,
                                     state.host_audio_output_count,
                                     "audio_capture", JackPortIsInput) != 0)
                goto cleanup;
        }
    }

    if (jack_set_process_callback(client, release_process, &state) != 0)
        goto cleanup;
    if (jack_activate(client) != 0)
        goto cleanup;
    active = 1;

    if (mode != RELEASE_PORTS) {
        if (connect_audio_graph(client, &state) != 0 ||
            wait_for_counter(&state.process_cycles, RELEASE_SETTLE_CYCLES) != 0)
            goto cleanup;
    }

    printf("READY mode=%s library=%s audio-inputs=%zu audio-outputs=%zu "
           "midi-inputs=%zu midi-outputs=%zu\n",
           argv[1], library_info.dli_fname, state.host_audio_input_count,
           state.host_audio_output_count, state.host_midi_input_count,
           state.host_midi_output_count);
    fflush(stdout);
    result = handle_commands(&state, client) == 0 ? 0 : 1;

cleanup:
    atomic_store_explicit(&state.armed, 0U, memory_order_release);
    if (active && jack_deactivate(client) != 0)
        result = 1;
    if (jack_client_close(client) != 0)
        result = 1;
    return result;
}
