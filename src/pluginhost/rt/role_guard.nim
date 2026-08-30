## Allocation-free symbolic audio-role ownership.
##
## This guard is intentionally independent of clap.thread-check until Increment 5.
## State 1 is a private claiming phase; state 2 publishes a fully written pthread ID.

import std/concurrency/atomics
import std/posix

type
  AudioRoleGuard* = object
    state: Atomic[uint32]
    owner: Pthread

proc initAudioRoleGuard*(guard: var AudioRoleGuard) {.gcsafe, raises: [].} =
  guard.state.store(0'u32, moRelaxed)

{.push checks: off, stackTrace: off, lineTrace: off.}
proc tryEnterAudioRole*(guard: ptr AudioRoleGuard): bool {.
    exportc: "pluginhost_audio_role_try_enter", gcsafe, raises: [].} =
  if guard == nil:
    return false
  var expected = 0'u32
  if not guard.state.compareExchange(expected, 1'u32, moAcquire, moRelaxed):
    return false
  guard.owner = pthread_self()
  guard.state.store(2'u32, moRelease)
  true

proc isAudioRoleThread*(guard: ptr AudioRoleGuard): bool {.
    exportc: "pluginhost_audio_role_is_current", gcsafe, raises: [].} =
  if guard == nil or guard.state.load(moAcquire) != 2'u32:
    return false
  pthread_equal(pthread_self(), guard.owner) != 0

proc leaveAudioRole*(guard: ptr AudioRoleGuard): bool {.
    exportc: "pluginhost_audio_role_leave", gcsafe, raises: [].} =
  if guard == nil or guard.state.load(moAcquire) != 2'u32:
    return false
  if pthread_equal(pthread_self(), guard.owner) == 0:
    return false
  guard.state.store(0'u32, moRelease)
  true
{.pop.}

proc isAudioRoleActive*(guard: var AudioRoleGuard): bool {.inline.} =
  guard.state.load(moAcquire) != 0'u32
