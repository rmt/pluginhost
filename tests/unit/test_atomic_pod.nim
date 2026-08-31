import std/unittest

import pluginhost/rt/atomic_pod

suite "trace-free real-time atomics":
  test "u32 operations preserve values and comparison state":
    var value: RtAtomicU32
    value.storeRelaxed(3'u32)
    check value.loadRelaxed() == 3'u32
    check value.fetchAddRelaxed(4'u32) == 3'u32
    check value.loadAcquire() == 7'u32
    check value.fetchOrRelaxed(8'u32) == 7'u32
    check value.loadRelaxed() == 15'u32
    check value.exchangeAcquire(2'u32) == 15'u32

    var expected = 2'u32
    check value.compareExchangeAcquire(expected, 9'u32)
    check value.loadRelaxed() == 9'u32
    expected = 4'u32
    check not value.compareExchangeRelaxed(expected, 12'u32)
    check expected == 9'u32
    check value.fetchAddAcquire(1'u32) == 9'u32
    check value.fetchSubRelease(3'u32) == 10'u32
    check value.loadAcquire() == 7'u32

  test "signed and 64-bit operations use fixed-width storage":
    var signedValue: RtAtomicI32
    signedValue.storeRelaxed(-17'i32)
    check signedValue.loadAcquire() == -17'i32

    var wideValue: RtAtomicU64
    wideValue.storeRelaxed(10'u64)
    check wideValue.loadRelaxed() == 10'u64
    check wideValue.fetchAddRelaxed(5'u64) == 10'u64
    check wideValue.loadAcquire() == 15'u64
    check wideValue.exchangeAcquire(21'u64) == 15'u64
    var expected = 21'u64
    check wideValue.compareExchangeRelaxed(expected, 34'u64)
    check wideValue.loadAcquire() == 34'u64
    wideValue.storeRelease(55'u64)
    check wideValue.loadAcquire() == 55'u64

  test "Nim storage width and alignment match fixed-width scalars":
    check sizeof(RtAtomicU32) == sizeof(uint32)
    check alignof(RtAtomicU32) == alignof(uint32)
    check sizeof(RtAtomicI32) == sizeof(int32)
    check alignof(RtAtomicI32) == alignof(int32)
    check sizeof(RtAtomicU64) == sizeof(uint64)
    check alignof(RtAtomicU64) == alignof(uint64)
