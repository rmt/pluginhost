import std/os

const FixturePathEnvironment* = "PLUGINHOST_FFI_FIXTURE"

type
  FixtureAddProc* = proc(left, right: int32): int32 {.
    cdecl, gcsafe, raises: [].}
  FixtureCallback* = proc(value: int32; context: pointer): int32 {.
    cdecl, gcsafe, raises: [].}
  FixtureGetCallbackProc* = proc(): FixtureCallback {.
    cdecl, gcsafe, raises: [].}
  FixtureCallCallbackProc* = proc(callback: FixtureCallback; value: int32;
                                  context: pointer): int32 {.
    cdecl, gcsafe, raises: [].}
  FixtureCallOnThreadProc* = proc(callback: FixtureCallback; value: int32;
                                  context: pointer; callbackResult,
                                  usedForeignThread: ptr int32): int32 {.
    cdecl, gcsafe, raises: [].}
  FixtureProcessCallback* = proc(frames: uint32; context: pointer): int32 {.
    cdecl, gcsafe, raises: [].}
  FixtureProcessOnThreadProc* = proc(callback: FixtureProcessCallback;
                                     frames: uint32; context: pointer;
                                     callbackResult,
                                     usedForeignThread: ptr int32): int32 {.
    cdecl, gcsafe, raises: [].}

proc fixturePath*(): string =
  result = getEnv(FixturePathEnvironment)
  if result.len == 0:
    raise newException(ValueError,
      FixturePathEnvironment & " must name the compiled FFI fixture")
