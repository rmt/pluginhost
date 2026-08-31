## Compile-only product-profile root for complete generated callback auditing.
## No test-only allocator define is used for this target.

{.push warning[UnusedImport]: off.}
import pluginhost/clap/[audio_process, host_bridge]
import pluginhost/jack/callbacks
import pluginhost/rt/[atomic_pod, engine, role_guard]
{.pop.}
