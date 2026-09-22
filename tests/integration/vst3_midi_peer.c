#define _GNU_SOURCE
#include <errno.h>
#include <jack/jack.h>
#include <jack/midiport.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WAIT_MS 5000U
#define SLEEP_NS 1000000L

typedef struct {
    jack_port_t *audio_source;
    jack_port_t *audio_capture;
    jack_port_t *source[2];
    jack_port_t *capture[2];
    uint32_t frames;
    _Atomic uint32_t armed;
    _Atomic uint64_t valid_cycles;
    _Atomic uint64_t errors;
} state_t;

static const uint8_t input_event_1[] = {0xb0U, 1U, 99U};
static const uint8_t input_event_2[] = {0xb0U, 1U, 99U};
static const uint8_t input_poly[] = {0xa0U, 60U, 64U};
static const uint8_t input_pressure[] = {0xd0U, 64U};
static const uint8_t input_pitch[] = {0xe0U, 0U, 64U};
static const uint8_t input_program[] = {0xc0U, 7U};
static const uint8_t input_sysex[] = {0xf0U, 0x7dU, 0x02U, 0xf7U};
static const uint8_t output_pitch[2] = {60U, 61U};
static const uint8_t output_sysex[] = {0xf0U, 0x7dU, 0x01U, 0xf7U};
static uint64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000U + (uint64_t)ts.tv_nsec / 1000000U;
}

static int process(jack_nframes_t frames, void *arg) {
    state_t *state = (state_t *)arg;
    float *audio_source = (float *)jack_port_get_buffer(state->audio_source, frames);
    float *audio_capture = (float *)jack_port_get_buffer(state->audio_capture, frames);
    void *capture[2] = {
        jack_port_get_buffer(state->capture[0], frames),
        jack_port_get_buffer(state->capture[1], frames),
    };
    if (audio_source == NULL || audio_capture == NULL ||
        capture[0] == NULL || capture[1] == NULL || frames != state->frames) {
        atomic_fetch_add_explicit(&state->errors, 1, memory_order_relaxed);
        return 0;
    }
    if (atomic_load_explicit(&state->armed, memory_order_acquire) != 0U) {
        for (jack_nframes_t frame = 0; frame < frames; ++frame)
            audio_source[frame] = 2.0f;
        for (unsigned bus = 0; bus < 2U; ++bus) {
            void *source = jack_port_get_buffer(state->source[bus], frames);
            if (source == NULL) {
                atomic_fetch_add_explicit(&state->errors, 1, memory_order_relaxed);
                continue;
            }
            jack_midi_clear_buffer(source);
            const uint8_t *event = bus == 0U ? input_event_1 : input_event_2;
            if (jack_midi_event_write(source, 3U, event, 3U) != 0 ||
                jack_midi_event_write(source, 4U, input_poly, 3U) != 0 ||
                jack_midi_event_write(source, 5U, input_pressure, 2U) != 0 ||
                jack_midi_event_write(source, 6U, input_pitch, 3U) != 0 ||
                jack_midi_event_write(source, 7U, input_program, 2U) != 0 ||
                jack_midi_event_write(source, 7U, input_sysex,
                                      sizeof(input_sysex)) != 0)
                atomic_fetch_add_explicit(&state->errors, 1, memory_order_relaxed);
        }
    } else {
        return 0;
    }
    const float audioDelta = audio_capture[0] - (2.0f * 7.0f / 127.0f);
    int valid = atomic_load_explicit(&state->errors, memory_order_relaxed) == 0U &&
        audioDelta > -0.0001f && audioDelta < 0.0001f;
    for (uint32_t bus = 0; bus < 2U; ++bus) {
        const uint32_t count = jack_midi_get_event_count(capture[bus]);
        jack_midi_event_t event;
        if (count != (bus == 1U ? 2U : 1U) ||
            jack_midi_event_get(&event, capture[bus], 0) != 0 ||
            event.time != 7U || event.size != 3U || event.buffer == NULL ||
            event.buffer[0] != 0x90U || event.buffer[1] != output_pitch[bus] ||
            event.buffer[2] != 127U)
            valid = 0;
        if (bus == 1U) {
            jack_midi_event_t sysex;
            if (jack_midi_event_get(&sysex, capture[bus], 1) != 0 ||
                sysex.time != 7U || sysex.size != sizeof(output_sysex) ||
                sysex.buffer == NULL ||
                memcmp(sysex.buffer, output_sysex, sizeof(output_sysex)) != 0)
                valid = 0;
        }
    }
    if (valid) atomic_fetch_add_explicit(&state->valid_cycles, 1, memory_order_relaxed);
    return 0;

}
static int wait_valid(state_t *state, uint64_t target) {
    const uint64_t start = now_ms();
    struct timespec delay = {.tv_sec = 0, .tv_nsec = SLEEP_NS};
    while (atomic_load_explicit(&state->valid_cycles, memory_order_acquire) < target) {
        if (now_ms() - start >= WAIT_MS) return -1;
        nanosleep(&delay, NULL);
    }
    return 0;
}

static int port_name(char *out, size_t cap, const char *client, const char *port) {
    int n = snprintf(out, cap, "%s:%s", client, port);
    return n < 0 || (size_t)n >= cap ? -1 : 0;
}

static int connect_named(jack_client_t *client, const char *from_client,
                         const char *from_port, const char *to_client,
                         const char *to_port) {
    char from[256], to[256];
    if (port_name(from, sizeof(from), from_client, from_port) != 0 ||
        port_name(to, sizeof(to), to_client, to_port) != 0) return -1;
    int result = jack_connect(client, from, to);
    return result == 0 || result == EEXIST ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    const char *host_client = argv[1];
    const uint32_t frames = (uint32_t)strtoul(argv[2], NULL, 10);
    const uint32_t cycles = (uint32_t)strtoul(argv[3], NULL, 10);
    jack_status_t status = 0;
    jack_client_t *client = jack_client_open("pluginhost-vst3-midi-peer",
                                              JackNoStartServer, &status);
    if (client == NULL) return 3;
    state_t state = {0};
    state.frames = frames;
    state.audio_source = jack_port_register(client, "audio_source",
                                            JACK_DEFAULT_AUDIO_TYPE,
                                            JackPortIsOutput, 0);
    state.audio_capture = jack_port_register(client, "audio_capture",
                                              JACK_DEFAULT_AUDIO_TYPE,
                                              JackPortIsInput, 0);
    state.source[0] = jack_port_register(client, "source_1",
                                         JACK_DEFAULT_MIDI_TYPE,
                                         JackPortIsOutput, 0);
    state.source[1] = jack_port_register(client, "source_2",
                                         JACK_DEFAULT_MIDI_TYPE,
                                         JackPortIsOutput, 0);
    state.capture[0] = jack_port_register(client, "capture_1",
                                           JACK_DEFAULT_MIDI_TYPE,
                                           JackPortIsInput, 0);
    state.capture[1] = jack_port_register(client, "capture_2",
                                           JACK_DEFAULT_MIDI_TYPE,
                                           JackPortIsInput, 0);
    if (state.audio_source == NULL || state.audio_capture == NULL ||
        state.source[0] == NULL || state.source[1] == NULL ||
        state.capture[0] == NULL || state.capture[1] == NULL ||
        connect_named(client, jack_get_client_name(client), "audio_source",
                      host_client, "audio_in_1") != 0 ||
        connect_named(client, host_client, "audio_out_1",
                      jack_get_client_name(client), "audio_capture") != 0 ||
        connect_named(client, jack_get_client_name(client), "source_1",
                      host_client, "midi_in_1") != 0 ||
        connect_named(client, jack_get_client_name(client), "source_2",
                      host_client, "midi_in_2") != 0 ||
        connect_named(client, host_client, "midi_out_1",
                      jack_get_client_name(client), "capture_1") != 0 ||
        connect_named(client, host_client, "midi_out_2",
                      jack_get_client_name(client), "capture_2") != 0 ||
        jack_set_process_callback(client, process, &state) != 0 ||
        jack_activate(client) != 0) {
        jack_client_close(client);
        return 4;
    }
    printf("READY\n");
    fflush(stdout);
    char command[32];
    while (fgets(command, sizeof(command), stdin) != NULL) {
        if (strncmp(command, "WAIT", 4) == 0) {
            atomic_store_explicit(&state.armed, 1U, memory_order_release);
            int result = wait_valid(&state, cycles == 0U ? 1U : cycles);
            printf("%s\n", result == 0 ? "WAITED" : "TIMEOUT");
            fflush(stdout);
        } else if (strncmp(command, "QUIT", 4) == 0) {
            break;
        }
    }
    jack_deactivate(client);
    jack_client_close(client);
    return 0;
}
