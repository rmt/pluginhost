import std/unittest

import pluginhost/rt/atomic_pod
import ./abi_probe

suite "real-time atomic C ABI":
  test "fixed-width atomic storage matches the C11 bridge":
    check uint64(sizeof(RtAtomicU32)) == abiSize(201)
    check uint64(alignof(RtAtomicU32)) == abiAlign(201)
    check uint64(sizeof(RtAtomicI32)) == abiSize(202)
    check uint64(alignof(RtAtomicI32)) == abiAlign(202)
    check uint64(sizeof(RtAtomicU64)) == abiSize(203)
    check uint64(alignof(RtAtomicU64)) == abiAlign(203)
