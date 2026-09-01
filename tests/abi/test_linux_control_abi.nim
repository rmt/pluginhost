import std/unittest

import pluginhost/platform/linux/reactor
import pluginhost/platform/linux/signals
import ./abi_probe

suite "Linux reactor and signal ABI":
  test "epoll and signalfd record layouts match system headers":
    check uint64(sizeof(LinuxEpollEvent)) == abiSize(301)
    check uint64(alignof(LinuxEpollEvent)) == abiAlign(301)
    check uint64(offsetOf(LinuxEpollEvent, events)) ==
      abiOffset(abiFieldId(301, 1))
    check uint64(offsetOf(LinuxEpollEvent, data)) ==
      abiOffset(abiFieldId(301, 2))

    check uint64(sizeof(LinuxSignalFdInfo)) == abiSize(302)
    check uint64(alignof(LinuxSignalFdInfo)) == abiAlign(302)
    check uint64(offsetOf(LinuxSignalFdInfo, signo)) ==
      abiOffset(abiFieldId(302, 1))
