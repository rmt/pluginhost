## Fixed-width, lock-free C11 atomics for foreign callback paths.
##
## Operations expose their memory order in the procedure name so callers cannot
## accidentally select an invalid order. The imported C functions are static
## inline definitions from c/rt_atomic.h and do not install Nim trace frames.

type
  RtAtomicU32* {.importc: "pluginhost_rt_atomic_u32",
      header: "rt_atomic.h".} = distinct uint32
  RtAtomicI32* {.importc: "pluginhost_rt_atomic_i32",
      header: "rt_atomic.h".} = distinct int32
  RtAtomicU64* {.importc: "pluginhost_rt_atomic_u64",
      header: "rt_atomic.h".} = distinct uint64

proc cU32LoadRelaxed(value: ptr RtAtomicU32): uint32 {.
  importc: "pluginhost_rt_atomic_u32_load_relaxed", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU32LoadAcquire(value: ptr RtAtomicU32): uint32 {.
  importc: "pluginhost_rt_atomic_u32_load_acquire", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU32StoreRelaxed(value: ptr RtAtomicU32; desired: uint32) {.
  importc: "pluginhost_rt_atomic_u32_store_relaxed", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU32StoreRelease(value: ptr RtAtomicU32; desired: uint32) {.
  importc: "pluginhost_rt_atomic_u32_store_release", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU32FetchAddRelaxed(value: ptr RtAtomicU32; amount: uint32): uint32 {.
  importc: "pluginhost_rt_atomic_u32_fetch_add_relaxed", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU32FetchAddAcquire(value: ptr RtAtomicU32; amount: uint32): uint32 {.
  importc: "pluginhost_rt_atomic_u32_fetch_add_acquire", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU32FetchSubRelease(value: ptr RtAtomicU32; amount: uint32): uint32 {.
  importc: "pluginhost_rt_atomic_u32_fetch_sub_release", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU32FetchOrRelaxed(value: ptr RtAtomicU32; bits: uint32): uint32 {.
  importc: "pluginhost_rt_atomic_u32_fetch_or_relaxed", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU32ExchangeAcquire(value: ptr RtAtomicU32; desired: uint32): uint32 {.
  importc: "pluginhost_rt_atomic_u32_exchange_acquire", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU32CompareExchangeRelaxed(value: ptr RtAtomicU32;
                                expected: ptr uint32;
                                desired: uint32): cint {.
  importc: "pluginhost_rt_atomic_u32_compare_exchange_relaxed",
  header: "rt_atomic.h", gcsafe, raises: [].}
proc cU32CompareExchangeAcquire(value: ptr RtAtomicU32;
                                expected: ptr uint32;
                                desired: uint32): cint {.
  importc: "pluginhost_rt_atomic_u32_compare_exchange_acquire",
  header: "rt_atomic.h", gcsafe, raises: [].}

proc cI32LoadAcquire(value: ptr RtAtomicI32): int32 {.
  importc: "pluginhost_rt_atomic_i32_load_acquire", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cI32StoreRelaxed(value: ptr RtAtomicI32; desired: int32) {.
  importc: "pluginhost_rt_atomic_i32_store_relaxed", header: "rt_atomic.h",
  gcsafe, raises: [].}

proc cU64LoadRelaxed(value: ptr RtAtomicU64): uint64 {.
  importc: "pluginhost_rt_atomic_u64_load_relaxed", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU64LoadAcquire(value: ptr RtAtomicU64): uint64 {.
  importc: "pluginhost_rt_atomic_u64_load_acquire", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU64StoreRelaxed(value: ptr RtAtomicU64; desired: uint64) {.
  importc: "pluginhost_rt_atomic_u64_store_relaxed", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU64StoreRelease(value: ptr RtAtomicU64; desired: uint64) {.
  importc: "pluginhost_rt_atomic_u64_store_release", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU64FetchAddRelaxed(value: ptr RtAtomicU64; amount: uint64): uint64 {.
  importc: "pluginhost_rt_atomic_u64_fetch_add_relaxed", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU64FetchAddRelease(value: ptr RtAtomicU64; amount: uint64): uint64 {.
  importc: "pluginhost_rt_atomic_u64_fetch_add_release", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU64ExchangeAcquire(value: ptr RtAtomicU64; desired: uint64): uint64 {.
  importc: "pluginhost_rt_atomic_u64_exchange_acquire", header: "rt_atomic.h",
  gcsafe, raises: [].}
proc cU64CompareExchangeRelaxed(value: ptr RtAtomicU64;
                                expected: ptr uint64;
                                desired: uint64): cint {.
  importc: "pluginhost_rt_atomic_u64_compare_exchange_relaxed",
  header: "rt_atomic.h", gcsafe, raises: [].}

{.push checks: off, stackTrace: off, lineTrace: off.}
template loadRelaxed*(value: RtAtomicU32): uint32 =
  cU32LoadRelaxed(unsafeAddr value)
template loadAcquire*(value: RtAtomicU32): uint32 =
  cU32LoadAcquire(unsafeAddr value)
template storeRelaxed*(value: var RtAtomicU32; desired: uint32) =
  cU32StoreRelaxed(addr value, desired)
template storeRelease*(value: var RtAtomicU32; desired: uint32) =
  cU32StoreRelease(addr value, desired)
template fetchAddRelaxed*(value: var RtAtomicU32; amount: uint32): uint32 =
  cU32FetchAddRelaxed(addr value, amount)
template fetchAddAcquire*(value: var RtAtomicU32; amount: uint32): uint32 =
  cU32FetchAddAcquire(addr value, amount)
template fetchSubRelease*(value: var RtAtomicU32; amount: uint32): uint32 =
  cU32FetchSubRelease(addr value, amount)
template fetchOrRelaxed*(value: var RtAtomicU32; bits: uint32): uint32 =
  cU32FetchOrRelaxed(addr value, bits)
template exchangeAcquire*(value: var RtAtomicU32; desired: uint32): uint32 =
  cU32ExchangeAcquire(addr value, desired)
template compareExchangeRelaxed*(value: var RtAtomicU32;
                                 expected: var uint32;
                                 desired: uint32): bool =
  cU32CompareExchangeRelaxed(addr value, addr expected, desired) != 0
template compareExchangeAcquire*(value: var RtAtomicU32;
                                 expected: var uint32;
                                 desired: uint32): bool =
  cU32CompareExchangeAcquire(addr value, addr expected, desired) != 0

template loadAcquire*(value: RtAtomicI32): int32 =
  cI32LoadAcquire(unsafeAddr value)
template storeRelaxed*(value: var RtAtomicI32; desired: int32) =
  cI32StoreRelaxed(addr value, desired)

template loadRelaxed*(value: RtAtomicU64): uint64 =
  cU64LoadRelaxed(unsafeAddr value)
template loadAcquire*(value: RtAtomicU64): uint64 =
  cU64LoadAcquire(unsafeAddr value)
template storeRelaxed*(value: var RtAtomicU64; desired: uint64) =
  cU64StoreRelaxed(addr value, desired)
template storeRelease*(value: var RtAtomicU64; desired: uint64) =
  cU64StoreRelease(addr value, desired)
template fetchAddRelaxed*(value: var RtAtomicU64; amount: uint64): uint64 =
  cU64FetchAddRelaxed(addr value, amount)
template fetchAddRelease*(value: var RtAtomicU64; amount: uint64): uint64 =
  cU64FetchAddRelease(addr value, amount)
template exchangeAcquire*(value: var RtAtomicU64; desired: uint64): uint64 =
  cU64ExchangeAcquire(addr value, desired)
template compareExchangeRelaxed*(value: var RtAtomicU64;
                                 expected: var uint64;
                                 desired: uint64): bool =
  cU64CompareExchangeRelaxed(addr value, addr expected, desired) != 0
{.pop.}
