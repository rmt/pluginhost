// V4A is built as a separate native fixture translation unit. Combined mode
// exposes component and controller on one object, whose Comp reader records
// the bytes while controller state calls remain independently observable.
#define PLUGINHOST_VST3_V4A_FIXTURE 1
#define PLUGINHOST_VST3_V2A_MODE 5
#include "v2a_fixture.cpp"

#include <cstdio>
#include <vector>

namespace {
std::uint32_t readLe32(const std::uint8_t* value) {
  return std::uint32_t(value[0]) | (std::uint32_t(value[1]) << 8) |
         (std::uint32_t(value[2]) << 16) | (std::uint32_t(value[3]) << 24);
}
std::uint64_t readLe64(const std::uint8_t* value) {
  std::uint64_t result = 0;
  for (unsigned index = 0; index < 8; ++index)
    result |= std::uint64_t(value[index]) << (index * 8);
  return result;
}
void appendLe32(std::vector<std::uint8_t>& bytes, std::uint32_t value) {
  for (unsigned index = 0; index < 4; ++index)
    bytes.push_back(std::uint8_t(value >> (index * 8)));
}
void appendLe64(std::vector<std::uint8_t>& bytes, std::uint64_t value) {
  for (unsigned index = 0; index < 8; ++index)
    bytes.push_back(std::uint8_t(value >> (index * 8)));
}
void appendText(std::vector<std::uint8_t>& bytes, const char* value,
                std::size_t size) {
  bytes.insert(bytes.end(), value, value + size);
}
constexpr char kPresetClassId[] = "102132435465768798A9BACBDCEDFEFF";
}

extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4a_validate_preset(const char* path) {
  if (path == nullptr) return 0;
  std::FILE* file = std::fopen(path, "rb");
  if (file == nullptr) return 0;
  if (std::fseek(file, 0, SEEK_END) != 0) {
    std::fclose(file);
    return 0;
  }
  const long length = std::ftell(file);
  if (length < 56 || length > 64 * 1024 * 1024 ||
      std::fseek(file, 0, SEEK_SET) != 0) {
    std::fclose(file);
    return 0;
  }
  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
  const bool readOk = std::fread(bytes.data(), 1, bytes.size(), file) ==
                      bytes.size();
  const bool closeOk = std::fclose(file) == 0;
  if (!readOk || !closeOk || std::memcmp(bytes.data(), "VST3", 4) != 0 ||
      readLe32(bytes.data() + 4) != 1 ||
      std::memcmp(bytes.data() + 8, kPresetClassId, 32) != 0) return 0;
  const std::uint64_t listOffset = readLe64(bytes.data() + 40);
  if (listOffset > bytes.size() - 8 ||
      std::memcmp(bytes.data() + listOffset, "List", 4) != 0) return 0;
  const std::uint32_t count = readLe32(bytes.data() + listOffset + 4);
  if (count == 0 || count > 128 ||
      listOffset + 8 + std::uint64_t(count) * 20 != bytes.size()) return 0;
  bool componentSeen = false;
  bool controllerSeen = false;
  for (std::uint32_t index = 0; index < count; ++index) {
    const std::uint8_t* entry = bytes.data() + listOffset + 8 + index * 20;
    const bool component = std::memcmp(entry, "Comp", 4) == 0;
    const bool controller = std::memcmp(entry, "Cont", 4) == 0;
    if ((!component && !controller) ||
        (component && componentSeen) || (controller && controllerSeen))
      return 0;
    componentSeen = componentSeen || component;
    controllerSeen = controllerSeen || controller;
    const std::uint64_t offset = readLe64(entry + 4);
    const std::uint64_t size = readLe64(entry + 12);
    if (offset > listOffset || size > listOffset - offset) return 0;
  }
  return componentSeen ? 1u : 0u;
}

extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4a_write_preset(const char* path) {
  if (path == nullptr) return 0;
  std::vector<std::uint8_t> bytes;
  appendText(bytes, "VST3", 4);
  appendLe32(bytes, 1);
  appendText(bytes, kPresetClassId, 32);
  appendLe64(bytes, 54);
  const std::uint8_t component[] = {0x56, 0x32, 0x41, 0x00};
  const std::uint8_t controller[] = {0x43, 0x54};
  bytes.insert(bytes.end(), component, component + sizeof(component));
  bytes.insert(bytes.end(), controller, controller + sizeof(controller));
  appendText(bytes, "List", 4);
  appendLe32(bytes, 2);
  appendText(bytes, "Comp", 4);
  appendLe64(bytes, 48);
  appendLe64(bytes, sizeof(component));
  appendText(bytes, "Cont", 4);
  appendLe64(bytes, 52);
  appendLe64(bytes, sizeof(controller));
  std::FILE* file = std::fopen(path, "wb");
  if (file == nullptr) return 0;
  const bool writeOk = std::fwrite(bytes.data(), 1, bytes.size(), file) ==
                       bytes.size();
  return (std::fclose(file) == 0 && writeOk) ? 1u : 0u;
}

extern "C" __attribute__((visibility("default")))
std::uint32_t pluginhost_vst3_v4a_retained_read_result() {
  if (g_retained_stream == nullptr) return 0xffffffffu;
  std::uint8_t byte = 0;
  std::int32_t read = -1;
  return static_cast<std::uint32_t>(g_retained_stream->read(&byte, 1, &read));
}
