import ./[errors, result]

type
  MonotonicNanos* = distinct int64

  ReactorInterest* = enum
    riRead
    riWrite
    riError
    riHangup

  ReactorInterests* = set[ReactorInterest]

  ReactorToken* = object
    slot*: uint32
    generation*: uint32

  ReactorReady* = object
    tokenValue*: uint64
    interests*: ReactorInterests

  ReactorEventKind* = enum
    rekFd
    rekTimer

  ReactorEvent* = object
    token*: ReactorToken
    kind*: ReactorEventKind
    interests*: ReactorInterests

  ReactorDriver* = ref object of RootObj

proc monotonicNanos*(value: int64): MonotonicNanos {.inline.} =
  MonotonicNanos(value)

proc int64Value*(value: MonotonicNanos): int64 {.inline.} =
  int64(value)

proc encode*(token: ReactorToken): uint64 {.inline.} =
  (uint64(token.generation) shl 32) or uint64(token.slot + 1'u32)

proc decodeReactorToken*(value: uint64): ReactorToken {.inline.} =
  let encodedSlot = uint32(value and 0xffff_ffff'u64)
  if encodedSlot == 0'u32:
    return ReactorToken()
  ReactorToken(
    slot: encodedSlot - 1'u32,
    generation: uint32(value shr 32),
  )

method now*(driver: ReactorDriver): Result[MonotonicNanos] {.base, raises: [].} =
  failure[MonotonicNanos](hostError(
    hsInternal, hekInternal, "reactor driver does not provide a clock"))

method addFd*(driver: ReactorDriver; fd: int32; interests: ReactorInterests;
              tokenValue: uint64): Result[Unit] {.base, raises: [].} =
  discard fd
  discard interests
  discard tokenValue
  failure[Unit](hostError(
    hsInternal, hekInternal, "reactor driver does not support FD registration"))

method modifyFd*(driver: ReactorDriver; fd: int32;
                 interests: ReactorInterests;
                 tokenValue: uint64): Result[Unit] {.base, raises: [].} =
  discard fd
  discard interests
  discard tokenValue
  failure[Unit](hostError(
    hsInternal, hekInternal, "reactor driver does not support FD modification"))

method removeFd*(driver: ReactorDriver; fd: int32): Result[Unit] {.base, raises: [].} =
  discard fd
  failure[Unit](hostError(
    hsInternal, hekInternal, "reactor driver does not support FD removal"))

method wait*(driver: ReactorDriver; timeoutMilliseconds: int32):
    Result[seq[ReactorReady]] {.base, raises: [].} =
  discard timeoutMilliseconds
  failure[seq[ReactorReady]](hostError(
    hsInternal, hekInternal, "reactor driver does not support waiting"))

method close*(driver: ReactorDriver): Result[Unit] {.base, raises: [].} =
  success()
