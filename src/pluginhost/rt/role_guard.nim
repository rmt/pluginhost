## Allocation-free symbolic audio-role ownership.
##
## This guard is intentionally independent of clap.thread-check until Increment 5.
## State 1 is a private claiming phase; state 2 publishes a fully written pthread ID.

import std/posix

import ./atomic_pod

type
  AudioRoleGuard* = object
    state: RtAtomicU32
    owner: Pthread

{.push checks: off, stackTrace: off, lineTrace: off.}
proc initAudioRoleGuard*(guard: var AudioRoleGuard) {.gcsafe, raises: [].} =
  guard.state.storeRelaxed(0'u32)

proc tryEnterAudioRole*(guard: ptr AudioRoleGuard): bool {.
    exportc: "pluginhost_audio_role_try_enter", gcsafe, raises: [].} =
  if guard == nil:
    return false
  var expected = 0'u32
  if not guard.state.compareExchangeAcquire(expected, 1'u32):
    return false
  guard.owner = pthread_self()
  guard.state.storeRelease(2'u32)
  true

proc isAudioRoleThread*(guard: ptr AudioRoleGuard): bool {.
    exportc: "pluginhost_audio_role_is_current", gcsafe, raises: [].} =
  if guard == nil or guard.state.loadAcquire() != 2'u32:
    return false
  pthread_equal(pthread_self(), guard.owner) != 0

proc leaveAudioRole*(guard: ptr AudioRoleGuard): bool {.
    exportc: "pluginhost_audio_role_leave", gcsafe, raises: [].} =
  if guard == nil or guard.state.loadAcquire() != 2'u32:
    return false
  if pthread_equal(pthread_self(), guard.owner) == 0:
    return false
  guard.state.storeRelease(0'u32)
  true

proc isAudioRoleActive*(guard: var AudioRoleGuard): bool {.inline.} =
  guard.state.loadAcquire() != 0'u32
{.pop.}
