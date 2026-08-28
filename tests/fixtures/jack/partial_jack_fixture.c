#include <stddef.h>

#if defined(__GNUC__) || defined(__clang__)
#define PLUGINHOST_FIXTURE_EXPORT __attribute__((visibility("default")))
#else
#define PLUGINHOST_FIXTURE_EXPORT
#endif

/* The checked loader resolves this first, then must roll back when the next
 * required JACK symbol is absent. This is intentionally not a JACK client. */
PLUGINHOST_FIXTURE_EXPORT void jack_get_version(int *major, int *minor,
                                                int *micro, int *protocol) {
   if (major != NULL)
      *major = 1;
   if (minor != NULL)
      *minor = 0;
   if (micro != NULL)
      *micro = 0;
   if (protocol != NULL)
      *protocol = 0;
}
