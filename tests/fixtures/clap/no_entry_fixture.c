#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define PLUGINHOST_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define PLUGINHOST_FIXTURE_EXPORT
#endif

PLUGINHOST_FIXTURE_EXPORT uint32_t pluginhost_fixture_without_clap_entry(void) {
   return 42U;
}
