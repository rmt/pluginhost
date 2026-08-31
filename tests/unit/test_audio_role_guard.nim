import std/concurrency/atomics
import std/unittest

import pluginhost/clap/[ffi, host_bridge]
import pluginhost/rt/role_guard

type RoleProbe = object
  guard: ptr AudioRoleGuard
  entered: ptr Atomic[uint32]

proc probeRole(probe: RoleProbe) {.thread, gcsafe, raises: [].} =
  if tryEnterAudioRole(probe.guard):
    probe.entered[].store(1'u32, moRelease)
    discard leaveAudioRole(probe.guard)
  else:
    probe.entered[].store(0'u32, moRelease)

proc enterOnThread(guard: var AudioRoleGuard): bool =
  var entered: Atomic[uint32]
  entered.store(2'u32, moRelaxed)
  var thread: Thread[RoleProbe]
  createThread(thread, probeRole, RoleProbe(guard: addr guard, entered: addr entered))
  joinThread(thread)
  entered.load(moAcquire) == 1'u32

suite "symbolic audio-role guard":
  test "one thread owns the role and release is explicit":
    var guard: AudioRoleGuard
    guard.initAudioRoleGuard()

    check tryEnterAudioRole(addr guard)
    check isAudioRoleThread(addr guard)
    check not tryEnterAudioRole(addr guard)
    check guard.isAudioRoleActive
    check leaveAudioRole(addr guard)
    check not guard.isAudioRoleActive
    check not leaveAudioRole(addr guard)

  test "another OS thread cannot enter until the owner leaves":
    var guard: AudioRoleGuard
    guard.initAudioRoleGuard()

    require tryEnterAudioRole(addr guard)
    check not enterOnThread(guard)
    require leaveAudioRole(addr guard)
    check enterOnThread(guard)
    check not guard.isAudioRoleActive

  test "an unattached guard reports no CLAP audio-thread ownership":
    var guard: AudioRoleGuard
    guard.initAudioRoleGuard()
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer
    let threadCheck = cast[ptr ClapHostThreadCheck](
      host.getExtension(host, ClapExtThreadCheck.cstring))
    require threadCheck != nil
    require tryEnterAudioRole(addr guard)
    defer:
      discard leaveAudioRole(addr guard)

    check threadCheck.isMainThread(host)
    check not threadCheck.isAudioThread(host)

  test "an attached guard publishes CLAP audio-thread ownership":
    var guard: AudioRoleGuard
    guard.initAudioRoleGuard()
    let bridge = newClapHostBridge()
    let host = bridge.hostPointer
    let threadCheck = cast[ptr ClapHostThreadCheck](
      host.getExtension(host, ClapExtThreadCheck.cstring))
    require threadCheck != nil
    require bridge.attachAudioRole(addr guard)
    require tryEnterAudioRole(addr guard)

    check threadCheck.isMainThread(host)
    check threadCheck.isAudioThread(host)
    require leaveAudioRole(addr guard)
    check not threadCheck.isAudioThread(host)
    check bridge.detachAudioRole(addr guard)
    check not bridge.detachAudioRole(addr guard)
