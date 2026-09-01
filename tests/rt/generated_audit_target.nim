## Compile-only product-profile root for complete generated callback auditing.
## No test-only allocator define is used for this target.

{.push warning[UnusedImport]: off.}
import pluginhost/clap/[audio_process, event_bridge, host_bridge]
import pluginhost/jack/callbacks
import pluginhost/rt/[atomic_pod, engine, midi_io, role_guard]
{.pop.}
