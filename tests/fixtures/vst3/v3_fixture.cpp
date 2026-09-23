#include <atomic>
#include <cstdint>
#include <cstring>

#include "vst3/vst3_c_api.h"

#ifndef PLUGINHOST_VST3_V3_MODE
#define PLUGINHOST_VST3_V3_MODE 0
#endif
#ifndef PLUGINHOST_VST3_V2B_MODE
#define PLUGINHOST_VST3_V2B_MODE PLUGINHOST_VST3_V3_MODE
#endif

#define EXPORT extern "C" __attribute__((visibility("default")))

namespace {

const Steinberg_TUID kClassId = {0x10, 0x21, 0x32, 0x43, 0x54, 0x65,
  0x76, static_cast<char>(0x87), static_cast<char>(0x98), static_cast<char>(0xA9),
  static_cast<char>(0xBA), static_cast<char>(0xCB), static_cast<char>(0xDC),
  static_cast<char>(0xED), static_cast<char>(0xFE), static_cast<char>(0xFF)};
const Steinberg_TUID kControllerId = {0x20, 0x31, 0x42, 0x53, 0x64, 0x75,
  static_cast<char>(0x86), static_cast<char>(0x97), static_cast<char>(0xA8),
  static_cast<char>(0xB9), static_cast<char>(0xCA), static_cast<char>(0xDB),
  static_cast<char>(0xEC), static_cast<char>(0xFD), 0x0E, 0x1F};
constexpr Steinberg_Vst_ParamID kGainId = 1;
constexpr Steinberg_Vst_ParamID kOutputId = 3;
const std::uint8_t kOutputSysEx[] = {0xF0, 0x7D, 0x01, 0xF7};
struct State;
struct ComponentObject { Steinberg_Vst_IComponent iface; State* state; };
struct MappingObject { Steinberg_Vst_IMidiMapping iface; State* state; };
struct ProcessorObject { Steinberg_Vst_IAudioProcessor iface; State* state; };
struct ControllerObject { Steinberg_Vst_IEditController iface; State* state; };
struct PointObject { Steinberg_Vst_IConnectionPoint iface; State* state; };
struct RequirementsObject {
  Steinberg_Vst_IProcessContextRequirements iface;
  State* state;
};

struct State {
  ComponentObject component;
  MappingObject mapping;
  ProcessorObject processor;
  ControllerObject controller;
  PointObject componentPoint;
  PointObject controllerPoint;
  RequirementsObject requirements;
  Steinberg_Vst_IComponentHandler* handler = nullptr;
  bool initialized = false;
  bool controllerInitialized = false;
  bool active = false;
  bool processing = false;
  bool setupDone = false;
  double gain = 1.0;
  double outputValue = 0.0;
  std::uint32_t outputSetCalls = 0;
  std::uint32_t processActive = 0;
  std::uint32_t setupCalls = 0;
  std::uint32_t processCalls = 0;
  std::uint32_t processFailures = 0;
  std::uint32_t processOverlap = 0;
  std::uint32_t activateCalls = 0;
  std::uint32_t deactivateCalls = 0;
  std::uint32_t activeCalls = 0;
  std::uint32_t processingCalls = 0;
  std::uint32_t arrangementCalls = 0;
  std::uint32_t requirementsCalls = 0;
  std::uint32_t setupFrames = 0;
  std::uint32_t setupRate = 0;
  std::int32_t lastResult = 0;
  std::int32_t lastInputs = 0;
  std::int32_t lastOutputs = 0;
  std::int32_t lastInputChannels[8] = {};
  std::int32_t lastOutputChannels[8] = {};
  std::uintptr_t lastInputPointers[32] = {};
  std::uintptr_t lastOutputPointers[32] = {};
  std::int64_t lastSamplePosition = 0;
  std::uint32_t lastContextState = 0;
  std::int64_t lastContinuousTimeSamples = 0;
  std::uint32_t lastInputParamQueues = 0;
  std::uint32_t lastInputParamPoints = 0;
  Steinberg_Vst_ParamID lastInputParamIds[16] = {};
  std::int32_t lastInputParamOffsets[64] = {};
  double lastInputParamValues[64] = {};
  std::uint32_t mappingQueries = 0;
  std::uint32_t mappingAssignments = 0;
  std::uint32_t mappingReleases = 0;
  std::uint32_t eventAdds = 0;
  std::uint32_t order[64] = {};
  std::uint32_t orderCount = 0;
};
State g_state;

void order(State* state, std::uint32_t value) {
  if (state->orderCount < 64) state->order[state->orderCount++] = value;
}

bool same(const Steinberg_TUID a, const Steinberg_TUID b) {
  return std::memcmp(a, b, sizeof(Steinberg_TUID)) == 0;
}

bool isCombined() { return PLUGINHOST_VST3_V2B_MODE == 1; }
bool isInstrument() { return PLUGINHOST_VST3_V2B_MODE == 2; }
bool isNonStereo() { return PLUGINHOST_VST3_V2B_MODE == 3; }
bool hasInactiveSlots() { return PLUGINHOST_VST3_V2B_MODE == 4; }
bool setupFails() {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (pluginhost_vst3_v4b2_setup_fail_enabled()) return true;
#endif
  return PLUGINHOST_VST3_V2B_MODE == 5;
}
bool activationFails() {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (pluginhost_vst3_v4b2_activation_fail_enabled()) return true;
#endif
  return PLUGINHOST_VST3_V2B_MODE == 6;
}
bool processFails() {
  return PLUGINHOST_VST3_V2B_MODE == 7 || PLUGINHOST_VST3_V3_MODE == 3;
}
bool arrangementsFalse() { return PLUGINHOST_VST3_V2B_MODE == 8; }
bool float64Only() { return PLUGINHOST_VST3_V2B_MODE == 9; }
bool silenceOutput() { return PLUGINHOST_VST3_V2B_MODE == 10; }
bool outputParameter() { return PLUGINHOST_VST3_V2B_MODE == 11; }
bool cvBus() { return PLUGINHOST_VST3_V2B_MODE == 12; }
bool tooManyBuses() { return PLUGINHOST_VST3_V2B_MODE == 13; }
bool negativeBusCount() { return PLUGINHOST_VST3_V2B_MODE == 14; }
bool unsupportedRequirements() { return PLUGINHOST_VST3_V2B_MODE == 16; }
bool supportedContinuousRequirements() { return PLUGINHOST_VST3_V2B_MODE == 17; }
bool multiMidi() { return PLUGINHOST_VST3_V2B_MODE == 18; }
bool mappingFailedCandidate() { return PLUGINHOST_VST3_V3_MODE == 19; }
bool malformedEventChannels() { return PLUGINHOST_VST3_V3_MODE == 20; }
bool outputOnlyMidi() { return PLUGINHOST_VST3_V3_MODE == 21; }

std::int32_t eventBusCount(Steinberg_Vst_BusDirection direction) {
  if (outputOnlyMidi())
    return direction == Steinberg_Vst_BusDirections_kOutput ? 1 : 0;
  return multiMidi() ? 2 : 1;
}

std::int32_t audioBusCount(Steinberg_Vst_BusDirection direction) {
  if (tooManyBuses()) return direction == Steinberg_Vst_BusDirections_kInput ? 1025 : 0;
  if (negativeBusCount()) return -1;
#if defined(PLUGINHOST_VST3_V4B_FIXTURE) || defined(PLUGINHOST_VST3_V4B2_FIXTURE)
  if (pluginhost_vst3_v4b_structural_enabled()) return 2;
#endif
  if (isInstrument()) return direction == Steinberg_Vst_BusDirections_kInput ? 0 : 1;
  if (hasInactiveSlots()) return 3;
  if (PLUGINHOST_VST3_V2B_MODE == 1 || arrangementsFalse() || outputParameter()) return 2;
  return 1;
}
std::uint64_t arrangement(Steinberg_Vst_BusDirection direction, std::int32_t index) {
  if (isNonStereo()) return 1ULL | (1ULL << 1) | (1ULL << 2);
  if (isInstrument()) return 3ULL;
  if (hasInactiveSlots()) return 1ULL;
#if defined(PLUGINHOST_VST3_V4B_FIXTURE) || defined(PLUGINHOST_VST3_V4B2_FIXTURE)
  if (pluginhost_vst3_v4b_structural_enabled()) return 1ULL;
#endif
  if (PLUGINHOST_VST3_V2B_MODE == 1 || arrangementsFalse() || outputParameter()) {
    if (index == 1) return 1ULL;
    return 3ULL;
  }
  (void)direction;
  (void)index;
  return 1ULL;
}

const char* busName(Steinberg_Vst_BusDirection direction, std::int32_t index) {
  if (direction == Steinberg_Vst_BusDirections_kInput)
    return index == 0 ? "Input" : "AuxInput";
  return index == 0 ? "Output" : "AuxOutput";
}

Steinberg_tresult componentQuery(void* raw, const Steinberg_TUID iid, void** obj);
Steinberg_tresult processorQuery(void* raw, const Steinberg_TUID iid, void** obj);
Steinberg_tresult controllerQuery(void* raw, const Steinberg_TUID iid, void** obj);
Steinberg_tresult mappingQuery(void* raw, const Steinberg_TUID iid, void** obj);
Steinberg_tresult pointQuery(void* raw, const Steinberg_TUID iid, void** obj);
Steinberg_tresult componentInitialize(void* raw, Steinberg_FUnknown*) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (pluginhost_vst3_v4b2_component_initialize_fail_enabled())
    return Steinberg_kResultFalse;
#endif
  auto* object = static_cast<ComponentObject*>(raw);
  object->state->initialized = true;
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  pluginhost_vst3_v4b2_component_initialized();
#endif
  order(object->state, 1);
  return Steinberg_kResultOk;
}
Steinberg_tresult componentTerminate(void* raw) {
  auto* object = static_cast<ComponentObject*>(raw);
  object->state->initialized = false;
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  pluginhost_vst3_v4b2_component_terminated();
#endif
  order(object->state, 9);
  return Steinberg_kResultOk;
}
Steinberg_tresult getControllerClassId(void*, Steinberg_TUID cid) {
  if (!cid || PLUGINHOST_VST3_V2B_MODE == 15) return Steinberg_kNoInterface;
  std::memcpy(cid, kControllerId, sizeof(kControllerId));
  return Steinberg_kResultOk;
}
Steinberg_tresult setIoMode(void*, Steinberg_Vst_IoMode) { return Steinberg_kResultOk; }
std::int32_t getBusCount(void*, Steinberg_Vst_MediaType type, Steinberg_Vst_BusDirection direction) {
  if (type == Steinberg_Vst_MediaTypes_kEvent) return eventBusCount(direction);
  return audioBusCount(direction);
}
Steinberg_tresult getBusInfo(void* raw, Steinberg_Vst_MediaType type,
    Steinberg_Vst_BusDirection direction, std::int32_t index,
    Steinberg_Vst_BusInfo* info) {
  auto* state = static_cast<ComponentObject*>(raw)->state;
  if (!info || index < 0) return Steinberg_kInvalidArgument;
  std::memset(info, 0, sizeof(*info));
  info->mediaType = type;
  info->direction = direction;
  if (type == Steinberg_Vst_MediaTypes_kEvent) {
    if (index >= eventBusCount(direction)) return Steinberg_kInvalidArgument;
    info->channelCount = malformedEventChannels() ? 17 : 1;
    const char* text = direction == Steinberg_Vst_BusDirections_kInput ? "EventIn" : "EventOut";
    for (std::size_t i = 0; text[i] && i + 1 < 128; ++i) info->name[i] = static_cast<Steinberg_Vst_TChar>(text[i]);
    return Steinberg_kResultOk;
  }
  if (index >= audioBusCount(direction)) return Steinberg_kInvalidArgument;
  info->channelCount = static_cast<std::int32_t>(__builtin_popcountll(arrangement(direction, index)));
  const char* text = busName(direction, index);
  for (std::size_t i = 0; text[i] && i + 1 < 128; ++i) info->name[i] = static_cast<Steinberg_Vst_TChar>(text[i]);
  info->flags = (index == 1 && hasInactiveSlots()) ? 0U : 1U;
  if (cvBus() && index == 0) info->flags |= 2U;
  (void)state;
  return Steinberg_kResultOk;
}
Steinberg_tresult getRoutingInfo(void*, Steinberg_Vst_RoutingInfo*, Steinberg_Vst_RoutingInfo*) {
  return Steinberg_kNotImplemented;
}
Steinberg_tresult activateBus(void* raw, Steinberg_Vst_MediaType type,
    Steinberg_Vst_BusDirection direction, std::int32_t index, Steinberg_TBool stateValue) {
  auto* state = static_cast<ComponentObject*>(raw)->state;
  if (activationFails() && stateValue &&
      type == Steinberg_Vst_MediaTypes_kAudio &&
      direction == Steinberg_Vst_BusDirections_kOutput && index == 0)
    return Steinberg_kResultFalse;
  if (stateValue) {
    ++state->activateCalls;
    order(state, 2);
  } else {
    ++state->deactivateCalls;
  }
  return Steinberg_kResultOk;
}
Steinberg_tresult setActive(void* raw, Steinberg_TBool active) {
  auto* object = static_cast<ComponentObject*>(raw);
  auto* state = object->state;
  state->active = active != 0;
  ++state->activeCalls;
  order(state, active ? 3 : 8);
#ifdef PLUGINHOST_VST3_V4B_FIXTURE
  if (active && state->handler != nullptr &&
      pluginhost_vst3_v4b_generate_enabled() &&
      state->handler->lpVtbl != nullptr &&
      state->handler->lpVtbl->restartComponent != nullptr)
    (void)state->handler->lpVtbl->restartComponent(state->handler,
      Steinberg_Vst_RestartFlags_kIoChanged);
#endif
  return Steinberg_kResultOk;
}
Steinberg_tresult setState(void* raw, Steinberg_IBStream* stream) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (pluginhost_vst3_v4b2_component_restore_fail_enabled())
    return Steinberg_kResultFalse;
  if (!stream || !stream->lpVtbl || !stream->lpVtbl->read)
    return Steinberg_kInvalidArgument;
  double value = 0.0;
  Steinberg_int32 read = 0;
  const auto code = stream->lpVtbl->read(stream, &value, sizeof(value), &read);
  if (code != Steinberg_kResultOk ||
      read != static_cast<Steinberg_int32>(sizeof(value)))
    return Steinberg_kResultFalse;
  static_cast<ComponentObject*>(raw)->state->gain = value;
  return Steinberg_kResultOk;
#else
  (void)raw;
  (void)stream;
  return Steinberg_kResultOk;
#endif
}
Steinberg_tresult getState(void* raw, Steinberg_IBStream* stream) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (pluginhost_vst3_v4b2_state_not_implemented())
    return Steinberg_kNotImplemented;
  if (pluginhost_vst3_v4b2_capture_fail_enabled())
    return Steinberg_kResultFalse;
  if (pluginhost_vst3_v4b2_retain_stream_enabled() && stream)
    pluginhost_vst3_v4b2_retain_stream(stream);
#else
  (void)raw;
  (void)stream;
  return Steinberg_kNotImplemented;
#endif
  if (!stream || !stream->lpVtbl || !stream->lpVtbl->write)
    return Steinberg_kInvalidArgument;
  double value = static_cast<ComponentObject*>(raw)->state->gain;
  Steinberg_int32 written = 0;
  const auto code = stream->lpVtbl->write(stream, &value, sizeof(value), &written);
  return code == Steinberg_kResultOk &&
      written == static_cast<Steinberg_int32>(sizeof(value))
    ? Steinberg_kResultOk : Steinberg_kResultFalse;
}

Steinberg_tresult setBusArrangements(void* raw,
    Steinberg_Vst_SpeakerArrangement* inputs, std::int32_t numIns,
    Steinberg_Vst_SpeakerArrangement* outputs, std::int32_t numOuts) {
  auto* state = static_cast<ProcessorObject*>(raw)->state;
  ++state->arrangementCalls;
  order(state, 4);
  if (state->active || state->setupDone || numIns < 0 || numOuts < 0) return Steinberg_kResultFalse;
  if (numIns != audioBusCount(Steinberg_Vst_BusDirections_kInput) ||
      numOuts != audioBusCount(Steinberg_Vst_BusDirections_kOutput)) return Steinberg_kResultFalse;
  for (std::int32_t i = 0; i < numIns; ++i) if (!inputs || inputs[i] != arrangement(Steinberg_Vst_BusDirections_kInput, i)) return Steinberg_kResultFalse;
  for (std::int32_t i = 0; i < numOuts; ++i) if (!outputs || outputs[i] != arrangement(Steinberg_Vst_BusDirections_kOutput, i)) return Steinberg_kResultFalse;
  return arrangementsFalse() ? Steinberg_kResultFalse : Steinberg_kResultOk;
}
Steinberg_tresult getBusArrangement(void* raw, Steinberg_Vst_BusDirection direction,
    std::int32_t index, Steinberg_Vst_SpeakerArrangement* result) {
  auto* state = static_cast<ProcessorObject*>(raw)->state;
  if (!result || index < 0 || index >= audioBusCount(direction)) return Steinberg_kInvalidArgument;
  *result = arrangement(direction, index);
  ++state->arrangementCalls;
  return Steinberg_kResultOk;
}
Steinberg_tresult canProcessSampleSize(void*, std::int32_t size) {
  if (float64Only()) return size == Steinberg_Vst_SymbolicSampleSizes_kSample64 ? Steinberg_kResultOk : Steinberg_kResultFalse;
  return size == Steinberg_Vst_SymbolicSampleSizes_kSample32 ? Steinberg_kResultOk : Steinberg_kResultFalse;
}
std::uint32_t getLatencySamples(void*) {
#ifdef PLUGINHOST_VST3_V4B_FIXTURE
  return pluginhost_vst3_v4b_latency_value();
#else
  return 0;
#endif
}
Steinberg_tresult setupProcessing(void* raw, Steinberg_Vst_ProcessSetup* setup) {
  auto* state = static_cast<ProcessorObject*>(raw)->state;
  if (!setup || state->active || setup->symbolicSampleSize != Steinberg_Vst_SymbolicSampleSizes_kSample32) return Steinberg_kResultFalse;
  if (setupFails()) return Steinberg_kResultFalse;
  state->setupDone = true;
  state->setupFrames = static_cast<std::uint32_t>(setup->maxSamplesPerBlock);
  state->setupRate = static_cast<std::uint32_t>(setup->sampleRate);
  ++state->setupCalls;
  order(state, 5);
  return Steinberg_kResultOk;
}
Steinberg_tresult setProcessing(void* raw, Steinberg_TBool processing) {
  auto* state = static_cast<ProcessorObject*>(raw)->state;
  if (processing && (!state->active || !state->setupDone)) return Steinberg_kResultFalse;
  state->processing = processing != 0;
#ifdef PLUGINHOST_VST3_V4B_FIXTURE
  if (!processing) state->setupDone = false;
#endif
  ++state->processingCalls;
  order(state, processing ? 6 : 7);
  return Steinberg_kResultOk;
}
float readGain(Steinberg_Vst_ProcessData* data, State* state) {
  float gain = static_cast<float>(state->gain);
  if (!data || !data->inputParameterChanges || !data->inputParameterChanges->lpVtbl)
    return gain;
  auto* changes = data->inputParameterChanges;
  std::int32_t count = changes->lpVtbl->getParameterCount(changes);
  state->lastInputParamQueues = 0;
  state->lastInputParamPoints = 0;
  for (std::int32_t i = 0; i < count; ++i) {
    auto* queue = changes->lpVtbl->getParameterData(changes, i);
    if (!queue || !queue->lpVtbl) continue;
    const auto id = queue->lpVtbl->getParameterId(queue);
    const std::int32_t points = queue->lpVtbl->getPointCount(queue);
    if (state->lastInputParamQueues < 16)
      state->lastInputParamIds[state->lastInputParamQueues++] = id;
    for (std::int32_t point = 0; point < points &&
         state->lastInputParamPoints < 64; ++point) {
      std::int32_t offset = 0;
      double value = 0.0;
      if (queue->lpVtbl->getPoint(queue, point, &offset, &value) ==
          Steinberg_kResultOk) {
        const auto index = state->lastInputParamPoints++;
        state->lastInputParamOffsets[index] = offset;
        state->lastInputParamValues[index] = value;
      }
    }
    if (points <= 0) continue;
    std::int32_t offset = 0;
    double value = 0.0;
    if (queue->lpVtbl->getPoint(queue, points - 1, &offset, &value) !=
        Steinberg_kResultOk)
      continue;
    if (id == kGainId)
      gain = static_cast<float>(value);
    else if (id == kOutputId)
      state->outputValue = value;
  }
  state->gain = gain;
  return gain;
}
Steinberg_tresult process(void* raw, Steinberg_Vst_ProcessData* data) {
  auto* state = static_cast<ProcessorObject*>(raw)->state;
  if (!data || !state->processing || !state->active || data->symbolicSampleSize != Steinberg_Vst_SymbolicSampleSizes_kSample32) return Steinberg_kResultFalse;
  if (state->processActive++ != 0) ++state->processOverlap;
  ++state->processCalls;
  state->lastInputs = data->numInputs;
  state->lastOutputs = data->numOutputs;
  state->lastSamplePosition = data->processContext ? data->processContext->projectTimeSamples : -1;
  state->lastContextState = data->processContext ? data->processContext->state : 0;
  state->lastContinuousTimeSamples = data->processContext ?
      data->processContext->continousTimeSamples : -1;
  for (std::int32_t bus = 0; bus < data->numInputs && bus < 8; ++bus) {
    state->lastInputChannels[bus] = data->inputs ? data->inputs[bus].numChannels : -1;
    auto** channels = data->inputs ? data->inputs[bus].Steinberg_Vst_AudioBusBuffers_channelBuffers32 : nullptr;
    for (std::int32_t channel = 0; channels && channel < data->inputs[bus].numChannels && channel < 32; ++channel)
      state->lastInputPointers[bus * 8 + channel] = reinterpret_cast<std::uintptr_t>(channels[channel]);
  }
  for (std::int32_t bus = 0; bus < data->numOutputs && bus < 8; ++bus) {
    state->lastOutputChannels[bus] = data->outputs ? data->outputs[bus].numChannels : -1;
    auto** channels = data->outputs ? data->outputs[bus].Steinberg_Vst_AudioBusBuffers_channelBuffers32 : nullptr;
    for (std::int32_t channel = 0; channels && channel < data->outputs[bus].numChannels && channel < 32; ++channel)
      state->lastOutputPointers[bus * 8 + channel] = reinterpret_cast<std::uintptr_t>(channels[channel]);
  }
  const float gain = readGain(data, state);
  for (std::int32_t bus = 0; bus < data->numOutputs; ++bus) {
    auto* output = data->outputs ? &data->outputs[bus] : nullptr;
    auto** outputChannels = output ? output->Steinberg_Vst_AudioBusBuffers_channelBuffers32 : nullptr;
    auto* input = (data->inputs && bus < data->numInputs) ? &data->inputs[bus] : nullptr;
    auto** inputChannels = input ? input->Steinberg_Vst_AudioBusBuffers_channelBuffers32 : nullptr;
    for (std::int32_t channel = 0; output && outputChannels && channel < output->numChannels; ++channel) {
      if (silenceOutput() && state->processCalls == 1 && bus == 0 && channel == 0)
        output->silenceFlags |= 1ULL;
      else output->silenceFlags &= ~(1ULL << static_cast<unsigned>(channel));
      for (std::int32_t frame = 0; frame < data->numSamples; ++frame) {
        float source = (inputChannels && channel < input->numChannels) ? inputChannels[channel][frame] : static_cast<float>(10 * (bus + 1) * (channel + 1));
        outputChannels[channel][frame] = source * gain;
      }
    }
  }
  if (data->outputEvents && data->outputEvents->lpVtbl &&
      data->outputEvents->lpVtbl->addEvent) {
    const std::int32_t eventCount = multiMidi() ? 2 : 1;
    for (std::int32_t bus = 0; bus < eventCount; ++bus) {
      Steinberg_Vst_Event event = {};
      event.busIndex = bus;
      event.sampleOffset = 7;
      event.type = Steinberg_Vst_Event_EventTypes_kNoteOnEvent;
      event.Steinberg_Vst_Event_noteOn.channel = 0;
      event.Steinberg_Vst_Event_noteOn.pitch = static_cast<std::int16_t>(
          60 + bus + (state->outputValue > 0.75 ? 1 : 0));
      event.Steinberg_Vst_Event_noteOn.tuning = 0.0f;
      event.Steinberg_Vst_Event_noteOn.velocity = 1.0f;
      event.Steinberg_Vst_Event_noteOn.length = 0;
      event.Steinberg_Vst_Event_noteOn.noteId = -1;
      if (data->outputEvents->lpVtbl->addEvent(data->outputEvents, &event) ==
          Steinberg_kResultOk)
        ++state->eventAdds;
      if (multiMidi() && bus == 1) {
        Steinberg_Vst_Event sysexEvent = {};
        sysexEvent.busIndex = bus;
        sysexEvent.sampleOffset = 7;
        sysexEvent.type = Steinberg_Vst_Event_EventTypes_kDataEvent;
        sysexEvent.Steinberg_Vst_Event_data.size = sizeof(kOutputSysEx);
        sysexEvent.Steinberg_Vst_Event_data.type =
            Steinberg_Vst_DataEvent_DataTypes_kMidiSysEx;
        sysexEvent.Steinberg_Vst_Event_data.bytes = kOutputSysEx;
        if (data->outputEvents->lpVtbl->addEvent(data->outputEvents,
            &sysexEvent) == Steinberg_kResultOk)
          ++state->eventAdds;
      }
    }
  }
  if (outputParameter() && data->outputParameterChanges && data->outputParameterChanges->lpVtbl) {
    std::int32_t index = -1;
    auto* queue = data->outputParameterChanges->lpVtbl->addParameterData(data->outputParameterChanges, &kOutputId, &index);
    if (queue && queue->lpVtbl) {
      std::int32_t pointIndex = -1;
      queue->lpVtbl->addPoint(queue, 0, state->gain * 0.5, &pointIndex);
    }
  }
  const bool failed = processFails();
  if (failed) {
    ++state->processFailures;
    state->lastResult = Steinberg_kResultFalse;
  } else {
    state->lastResult = Steinberg_kResultOk;
  }
  --state->processActive;
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (state->processCalls == 1 &&
      pluginhost_vst3_v4b2_public_reload_enabled() &&
      state->handler != nullptr && state->handler->lpVtbl != nullptr &&
      state->handler->lpVtbl->restartComponent != nullptr) {
    pluginhost_vst3_v4b2_public_reload_requested();
    (void)state->handler->lpVtbl->restartComponent(
      state->handler, Steinberg_Vst_RestartFlags_kReloadComponent);
  }
#endif
  return state->lastResult;
}
std::uint32_t getTailSamples(void*) { return 0; }

Steinberg_tresult controllerInitialize(void* raw, Steinberg_FUnknown*) {
  auto* state = static_cast<ControllerObject*>(raw)->state;
  state->controllerInitialized = true;
  order(state, 10);
  return Steinberg_kResultOk;
}
Steinberg_tresult controllerTerminate(void* raw) {
  auto* state = static_cast<ControllerObject*>(raw)->state;
  state->controllerInitialized = false;
  order(state, 11);
  return Steinberg_kResultOk;
}
Steinberg_tresult controllerSetComponentState(void* raw, Steinberg_IBStream* stream) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (pluginhost_vst3_v4b2_controller_restore_fail_enabled())
    return Steinberg_kResultFalse;
  if (!stream || !stream->lpVtbl || !stream->lpVtbl->read)
    return Steinberg_kInvalidArgument;
  double value = 0.0;
  Steinberg_int32 read = 0;
  const auto code = stream->lpVtbl->read(stream, &value, sizeof(value), &read);
  if (code != Steinberg_kResultOk ||
      read != static_cast<Steinberg_int32>(sizeof(value)))
    return Steinberg_kResultFalse;
  static_cast<ControllerObject*>(raw)->state->gain = value;
  return Steinberg_kResultOk;
#else
  (void)raw;
  (void)stream;
  return Steinberg_kResultOk;
#endif
}
Steinberg_tresult controllerSetState(void* raw, Steinberg_IBStream* stream) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (pluginhost_vst3_v4b2_controller_restore_fail_enabled())
    return Steinberg_kResultFalse;
  if (!stream || !stream->lpVtbl || !stream->lpVtbl->read)
    return Steinberg_kInvalidArgument;
  double value = 0.0;
  Steinberg_int32 read = 0;
  const auto code = stream->lpVtbl->read(stream, &value, sizeof(value), &read);
  if (code != Steinberg_kResultOk ||
      read != static_cast<Steinberg_int32>(sizeof(value)))
    return Steinberg_kResultFalse;
  static_cast<ControllerObject*>(raw)->state->outputValue = value;
  return Steinberg_kResultOk;
#else
  (void)raw;
  (void)stream;
  return Steinberg_kResultOk;
#endif
}
Steinberg_tresult controllerGetState(void* raw, Steinberg_IBStream* stream) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (pluginhost_vst3_v4b2_state_not_implemented())
    return Steinberg_kNotImplemented;
  if (pluginhost_vst3_v4b2_controller_capture_fail_enabled())
    return Steinberg_kResultFalse;
  if (pluginhost_vst3_v4b2_retain_stream_enabled() && stream)
    pluginhost_vst3_v4b2_retain_stream(stream);
#else
  (void)raw;
  (void)stream;
  return Steinberg_kNotImplemented;
#endif
  if (!stream || !stream->lpVtbl || !stream->lpVtbl->write)
    return Steinberg_kInvalidArgument;
  double value = static_cast<ControllerObject*>(raw)->state->outputValue;
  Steinberg_int32 written = 0;
  const auto code = stream->lpVtbl->write(stream, &value, sizeof(value), &written);
  return code == Steinberg_kResultOk &&
      written == static_cast<Steinberg_int32>(sizeof(value))
    ? Steinberg_kResultOk : Steinberg_kResultFalse;
}
std::int32_t controllerParameterCount(void*) { return 2; }
Steinberg_tresult controllerParameterInfo(void*, std::int32_t index, Steinberg_Vst_ParameterInfo* info) {
#ifdef PLUGINHOST_VST3_V4B_FIXTURE
  if (pluginhost_vst3_v4b_metadata_fail_enabled()) return Steinberg_kResultFalse;
#endif
  if (!info || index < 0 || index >= 2) return Steinberg_kInvalidArgument;
  std::memset(info, 0, sizeof(*info));
  info->id = index == 0 ? kGainId : kOutputId;
  const char* title = index == 0 ? "Gain" : "Output";
  for (std::size_t i = 0; title[i] && i + 1 < 128; ++i) info->title[i] = static_cast<Steinberg_Vst_TChar>(title[i]);
  info->stepCount = 0;
  info->defaultNormalizedValue = index == 0 ? 1.0 : 0.0;
  return Steinberg_kResultOk;
}
Steinberg_tresult controllerParamString(void*, Steinberg_Vst_ParamID, double, Steinberg_Vst_String128) { return Steinberg_kNotImplemented; }
Steinberg_tresult controllerParamValue(void*, Steinberg_Vst_ParamID, Steinberg_Vst_TChar*, double*) { return Steinberg_kNotImplemented; }
Steinberg_Vst_ParamValue controllerNormToPlain(void*, Steinberg_Vst_ParamID, double value) { return value; }
Steinberg_Vst_ParamValue controllerPlainToNorm(void*, Steinberg_Vst_ParamID, double value) { return value; }
Steinberg_Vst_ParamValue controllerGetParam(void* raw, Steinberg_Vst_ParamID id) {
  auto* state = static_cast<ControllerObject*>(raw)->state;
  return id == kGainId ? state->gain : state->outputValue;
}
Steinberg_tresult controllerSetParam(void* raw, Steinberg_Vst_ParamID id, double value) {
  auto* state = static_cast<ControllerObject*>(raw)->state;
  if (id == kGainId) state->gain = value;
  if (id == kOutputId) { state->outputValue = value; ++state->outputSetCalls; }
  return Steinberg_kResultOk;
}
Steinberg_tresult controllerSetHandler(void* raw, Steinberg_Vst_IComponentHandler* handler) {
  auto* state = static_cast<ControllerObject*>(raw)->state;
  state->handler = handler;
  order(state, handler ? 12 : 13);
  return Steinberg_kResultOk;
}
Steinberg_IPlugView* controllerCreateView(void*, Steinberg_FIDString) { return nullptr; }

Steinberg_tresult pointConnect(void* raw, Steinberg_Vst_IConnectionPoint*) {
  order(static_cast<PointObject*>(raw)->state, 14);
  return Steinberg_kResultOk;
}
Steinberg_tresult pointDisconnect(void* raw, Steinberg_Vst_IConnectionPoint*) {
  order(static_cast<PointObject*>(raw)->state, 15);
  return Steinberg_kResultOk;
}
Steinberg_tresult pointNotify(void*, Steinberg_Vst_IMessage*) { return Steinberg_kResultOk; }

Steinberg_uint32 oneRef(void*) { return 1; }
Steinberg_uint32 zeroRelease(void*) { return 0; }
Steinberg_uint32 componentRelease(void*) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  pluginhost_vst3_v4b2_component_released();
#endif
  return 0;
}
Steinberg_uint32 mappingRelease(void* raw) {
  auto* state = static_cast<MappingObject*>(raw)->state;
  ++state->mappingReleases;
  return 0;
}

Steinberg_tresult componentQuery(void* raw, const Steinberg_TUID iid, void** obj) {
  auto* state = static_cast<ComponentObject*>(raw)->state;
  if (!obj) return Steinberg_kInvalidArgument;
  *obj = nullptr;
  if (same(iid, Steinberg_FUnknown_iid) || same(iid, Steinberg_Vst_IComponent_iid)) *obj = &state->component.iface;
  else if (same(iid, Steinberg_Vst_IAudioProcessor_iid)) *obj = &state->processor.iface;
  else if (same(iid, Steinberg_Vst_IEditController_iid) && isCombined()) *obj = &state->controller.iface;
  else if (same(iid, Steinberg_Vst_IConnectionPoint_iid)) *obj = &state->componentPoint.iface;
  if (!*obj) return Steinberg_kNoInterface;
  return Steinberg_kResultOk;
}
Steinberg_uint32 requirementsGet(void* raw) {
  auto* state = static_cast<RequirementsObject*>(raw)->state;
  ++state->requirementsCalls;
  if (unsupportedRequirements())
    return Steinberg_Vst_IProcessContextRequirements_Flags_kNeedTempo;
  return supportedContinuousRequirements()
      ? Steinberg_Vst_IProcessContextRequirements_Flags_kNeedContinousTimeSamples
      : 0;
}
Steinberg_tresult requirementsQuery(void* raw, const Steinberg_TUID iid, void** obj) {
  if (!obj) return Steinberg_kInvalidArgument;
  *obj = nullptr;
  if (!raw || !iid) return Steinberg_kInvalidArgument;
  auto* state = static_cast<RequirementsObject*>(raw)->state;
  if (same(iid, Steinberg_FUnknown_iid) ||
      same(iid, Steinberg_Vst_IProcessContextRequirements_iid))
    *obj = &state->requirements.iface;
  return *obj ? Steinberg_kResultOk : Steinberg_kNoInterface;
}
Steinberg_tresult processorQuery(void* raw, const Steinberg_TUID iid, void** obj) {
  auto* state = static_cast<ProcessorObject*>(raw)->state;
  if (!obj) return Steinberg_kInvalidArgument;
  *obj = nullptr;
  if (same(iid, Steinberg_FUnknown_iid) ||
      same(iid, Steinberg_Vst_IAudioProcessor_iid)) *obj = &state->processor.iface;
  else if (same(iid, Steinberg_Vst_IComponent_iid)) *obj = &state->component.iface;
  else if (same(iid, Steinberg_Vst_IProcessContextRequirements_iid))
    *obj = &state->requirements.iface;
  if (!*obj) return Steinberg_kNoInterface;
  return Steinberg_kResultOk;
}
Steinberg_tresult controllerQuery(void* raw, const Steinberg_TUID iid, void** obj) {
  auto* state = static_cast<ControllerObject*>(raw)->state;
  if (!obj) return Steinberg_kInvalidArgument;
  *obj = nullptr;
  if (same(iid, Steinberg_FUnknown_iid) ||
      same(iid, Steinberg_Vst_IEditController_iid))
    *obj = &state->controller.iface;
  else if (same(iid, Steinberg_Vst_IMidiMapping_iid)) {
    ++state->mappingQueries;
    *obj = &state->mapping.iface;
    return mappingFailedCandidate() ? Steinberg_kNoInterface :
      Steinberg_kResultOk;
  } else if (same(iid, Steinberg_Vst_IConnectionPoint_iid))
    *obj = &state->controllerPoint.iface;
  if (!*obj) return Steinberg_kNoInterface;
  return Steinberg_kResultOk;
}
Steinberg_tresult mappingGet(void* raw, Steinberg_int32 busIndex,
    Steinberg_int16 channel, Steinberg_Vst_CtrlNumber controller,
    Steinberg_Vst_ParamID* id) {
  auto* state = static_cast<MappingObject*>(raw)->state;
  ++state->mappingAssignments;
  if (!id || busIndex < 0 || busIndex >= (multiMidi() ? 2 : 1) ||
      channel < 0 || channel > 15)
    return Steinberg_kInvalidArgument;
  if (controller >= 0 &&
      (controller < Steinberg_Vst_ControllerNumbers_kCountCtrlNumber ||
       controller == Steinberg_Vst_ControllerNumbers_kCtrlProgramChange)) {
    *id = controller == Steinberg_Vst_ControllerNumbers_kPitchBend
      ? kOutputId : kGainId;
    return Steinberg_kResultOk;
  }
  (void)state;
  return Steinberg_kResultFalse;
}
Steinberg_tresult mappingQuery(void* raw, const Steinberg_TUID iid, void** obj) {
  auto* state = static_cast<MappingObject*>(raw)->state;
  ++state->mappingQueries;
  if (!obj) return Steinberg_kInvalidArgument;
  *obj = nullptr;
  if (same(iid, Steinberg_FUnknown_iid) ||
      same(iid, Steinberg_Vst_IMidiMapping_iid))
    *obj = &state->mapping.iface;
  return *obj ? Steinberg_kResultOk : Steinberg_kNoInterface;
}
Steinberg_tresult pointQuery(void* raw, const Steinberg_TUID iid, void** obj) {
  if (!obj) return Steinberg_kInvalidArgument;
  *obj = nullptr;
  if (same(iid, Steinberg_FUnknown_iid) || same(iid, Steinberg_Vst_IConnectionPoint_iid)) *obj = raw;
  if (!*obj) return Steinberg_kNoInterface;
  return Steinberg_kResultOk;
}

Steinberg_tresult factoryQuery(void*, const Steinberg_TUID, void** obj) {
  if (obj) *obj = nullptr;
  return Steinberg_kNoInterface;
}
Steinberg_tresult factoryInfo(void*, Steinberg_PFactoryInfo* info) {
  if (!info) return Steinberg_kInvalidArgument;
  std::memset(info, 0, sizeof(*info));
  std::strncpy(info->vendor, "pluginhost-v2b", sizeof(info->vendor) - 1);
  return Steinberg_kResultOk;
}
std::int32_t factoryCount(void*) { return 1; }
Steinberg_tresult factoryClassInfo(void*, std::int32_t index, Steinberg_PClassInfo* info) {
  if (!info || index != 0) return Steinberg_kInvalidArgument;
  std::memset(info, 0, sizeof(*info));
  std::memcpy(info->cid, kClassId, sizeof(kClassId));
  std::strncpy(info->category, "Audio Module Class", sizeof(info->category) - 1);
  std::strncpy(info->name, "V2B fixture", sizeof(info->name) - 1);
  return Steinberg_kResultOk;
}
Steinberg_tresult factoryCreate(void*, const char* cid, const char* iid, void** obj) {
  extern Steinberg_Vst_IComponentVtbl componentVtable;
  extern Steinberg_Vst_IAudioProcessorVtbl processorVtable;
  extern Steinberg_Vst_IEditControllerVtbl controllerVtable;
  extern Steinberg_Vst_IConnectionPointVtbl pointVtable;
  extern Steinberg_Vst_IProcessContextRequirementsVtbl requirementsVtable;
  extern Steinberg_Vst_IMidiMappingVtbl mappingVtable;
  if (!obj) return Steinberg_kInvalidArgument;
  *obj = nullptr;
  if (!cid || !iid ||
      (std::memcmp(cid, kClassId, sizeof(kClassId)) != 0 &&
       std::memcmp(cid, kControllerId, sizeof(kControllerId)) != 0)) {
    return Steinberg_kInvalidArgument;
  }
  const bool componentRequest =
      std::memcmp(cid, kClassId, sizeof(kClassId)) == 0 &&
      std::memcmp(iid, Steinberg_Vst_IComponent_iid, sizeof(Steinberg_TUID)) == 0;
  const bool controllerRequest =
      std::memcmp(cid, kControllerId, sizeof(kControllerId)) == 0 &&
      std::memcmp(iid, Steinberg_Vst_IEditController_iid,
        sizeof(Steinberg_TUID)) == 0;
  if (!componentRequest && !controllerRequest) return Steinberg_kNoInterface;
  if (componentRequest) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
    pluginhost_vst3_v4b2_component_created();
#endif
    g_state = State();
    g_state.component.state = &g_state;
    g_state.processor.state = &g_state;
    g_state.controller.state = &g_state;
    g_state.componentPoint.state = &g_state;
    g_state.controllerPoint.state = &g_state;
    g_state.mapping.state = &g_state;
    g_state.requirements.state = &g_state;
    g_state.component.iface.lpVtbl = &componentVtable;
    g_state.processor.iface.lpVtbl = &processorVtable;
    g_state.controller.iface.lpVtbl = &controllerVtable;
    g_state.mapping.iface.lpVtbl = &mappingVtable;
    g_state.componentPoint.iface.lpVtbl = &pointVtable;
    g_state.controllerPoint.iface.lpVtbl = &pointVtable;
    g_state.requirements.iface.lpVtbl = &requirementsVtable;
    *obj = &g_state.component.iface;
  } else {
    if (g_state.component.iface.lpVtbl == nullptr) return Steinberg_kNoInterface;
    *obj = &g_state.controller.iface;
  }
  return Steinberg_kResultOk;
}

Steinberg_Vst_IComponentVtbl componentVtable = {
  componentQuery, oneRef, componentRelease, componentInitialize, componentTerminate,
  getControllerClassId, setIoMode, getBusCount, getBusInfo, getRoutingInfo,
  activateBus, setActive, setState, getState};
Steinberg_Vst_IAudioProcessorVtbl processorVtable = {
  processorQuery, oneRef, zeroRelease, setBusArrangements, getBusArrangement,
  canProcessSampleSize, getLatencySamples, setupProcessing, setProcessing,
  process, getTailSamples};
Steinberg_Vst_IMidiMappingVtbl mappingVtable = {
  mappingQuery, oneRef, mappingRelease, mappingGet};
Steinberg_Vst_IProcessContextRequirementsVtbl requirementsVtable = {
  requirementsQuery, oneRef, zeroRelease, requirementsGet};
Steinberg_Vst_IEditControllerVtbl controllerVtable = {
  controllerQuery, oneRef, zeroRelease, controllerInitialize, controllerTerminate,
  controllerSetComponentState, controllerSetState, controllerGetState,
  controllerParameterCount, controllerParameterInfo, controllerParamString,
  controllerParamValue, controllerNormToPlain, controllerPlainToNorm,
  controllerGetParam, controllerSetParam, controllerSetHandler, controllerCreateView};
Steinberg_Vst_IConnectionPointVtbl pointVtable = {
  pointQuery, oneRef, zeroRelease, pointConnect, pointDisconnect, pointNotify};
Steinberg_IPluginFactoryVtbl factoryVtable = {
  factoryQuery, oneRef, zeroRelease, factoryInfo, factoryCount, factoryClassInfo,
  factoryCreate};
struct FactoryObject { Steinberg_IPluginFactory iface; } g_factory = {{&factoryVtable}};

} // namespace

EXPORT Steinberg_TBool ModuleEntry(void*) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  if (pluginhost_vst3_v4b2_module_entry_fail_enabled()) return 0;
#endif
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  pluginhost_vst3_v4b2_module_entry();
#endif
  return 1;
}
EXPORT Steinberg_TBool ModuleExit(void) {
#ifdef PLUGINHOST_VST3_V4B2_FIXTURE
  pluginhost_vst3_v4b2_module_exit();
#endif
  return 1;
}
EXPORT Steinberg_IPluginFactory* GetPluginFactory(void) { return &g_factory.iface; }

EXPORT std::uint32_t pluginhost_vst3_fixture_setup_calls(void) { return g_state.setupCalls; }
EXPORT std::uint32_t pluginhost_vst3_fixture_setup_frames(void) { return g_state.setupFrames; }
EXPORT std::uint32_t pluginhost_vst3_fixture_setup_rate(void) { return g_state.setupRate; }
EXPORT std::uint32_t pluginhost_vst3_fixture_process_calls(void) { return g_state.processCalls; }
EXPORT std::uint32_t pluginhost_vst3_fixture_process_failures(void) { return g_state.processFailures; }
EXPORT std::uint32_t pluginhost_vst3_fixture_process_overlap(void) { return g_state.processOverlap; }
EXPORT std::uint32_t pluginhost_vst3_fixture_activate_calls(void) { return g_state.activateCalls; }
EXPORT std::uint32_t pluginhost_vst3_fixture_arrangement_calls(void) { return g_state.arrangementCalls; }
EXPORT std::uint32_t pluginhost_vst3_fixture_deactivate_calls(void) { return g_state.deactivateCalls; }
EXPORT std::uint32_t pluginhost_vst3_fixture_requirements_calls(void) { return g_state.requirementsCalls; }
EXPORT std::int32_t pluginhost_vst3_fixture_last_inputs(void) { return g_state.lastInputs; }
EXPORT std::int32_t pluginhost_vst3_fixture_last_outputs(void) { return g_state.lastOutputs; }
EXPORT std::int32_t pluginhost_vst3_fixture_last_input_channels(std::int32_t i) { return i >= 0 && i < 8 ? g_state.lastInputChannels[i] : -1; }
EXPORT std::int32_t pluginhost_vst3_fixture_last_output_channels(std::int32_t i) { return i >= 0 && i < 8 ? g_state.lastOutputChannels[i] : -1; }
EXPORT std::uint64_t pluginhost_vst3_fixture_last_input_pointer(std::int32_t i) { return i >= 0 && i < 32 ? g_state.lastInputPointers[i] : 0; }
EXPORT std::uint64_t pluginhost_vst3_fixture_last_output_pointer(std::int32_t i) { return i >= 0 && i < 32 ? g_state.lastOutputPointers[i] : 0; }
EXPORT std::int64_t pluginhost_vst3_fixture_last_sample_position(void) { return g_state.lastSamplePosition; }
EXPORT std::uint32_t pluginhost_vst3_fixture_last_context_state(void) { return g_state.lastContextState; }
EXPORT std::int64_t pluginhost_vst3_fixture_last_continuous_time_samples(void) { return g_state.lastContinuousTimeSamples; }
EXPORT std::uint32_t pluginhost_vst3_fixture_last_input_param_queues(void) { return g_state.lastInputParamQueues; }
EXPORT std::uint32_t pluginhost_vst3_fixture_last_input_param_points(void) { return g_state.lastInputParamPoints; }
EXPORT std::uint32_t pluginhost_vst3_fixture_last_input_param_id(std::int32_t i) {
  return i >= 0 && i < 16 ? g_state.lastInputParamIds[i] : 0;
}
EXPORT std::int32_t pluginhost_vst3_fixture_last_input_param_offset(std::int32_t i) {
  return i >= 0 && i < 64 ? g_state.lastInputParamOffsets[i] : -1;
}
EXPORT double pluginhost_vst3_fixture_last_input_param_value(std::int32_t i) {
  return i >= 0 && i < 64 ? g_state.lastInputParamValues[i] : 0.0;
}
EXPORT std::uint32_t pluginhost_vst3_fixture_controller_set_calls(void) { return g_state.outputSetCalls; }
EXPORT std::uint32_t pluginhost_vst3_fixture_event_adds(void) { return g_state.eventAdds; }
EXPORT double pluginhost_vst3_fixture_gain(void) { return g_state.gain; }
EXPORT double pluginhost_vst3_fixture_output_value(void) { return g_state.outputValue; }
EXPORT std::uint32_t pluginhost_vst3_fixture_order_count(void) { return g_state.orderCount; }
EXPORT std::uint32_t pluginhost_vst3_fixture_order(std::uint32_t i) { return i < g_state.orderCount ? g_state.order[i] : 0; }
EXPORT std::uint32_t pluginhost_vst3_fixture_mapping_queries(void) { return g_state.mappingQueries; }
EXPORT std::uint32_t pluginhost_vst3_fixture_mapping_assignments(void) { return g_state.mappingAssignments; }
EXPORT std::uint32_t pluginhost_vst3_fixture_mapping_releases(void) { return g_state.mappingReleases; }
EXPORT void pluginhost_vst3_fixture_emit_gain_edit(double value) {
  if (!g_state.handler || !g_state.handler->lpVtbl) return;
  g_state.handler->lpVtbl->beginEdit(g_state.handler, kGainId);
  g_state.handler->lpVtbl->performEdit(g_state.handler, kGainId, value);
  g_state.handler->lpVtbl->endEdit(g_state.handler, kGainId);
}
