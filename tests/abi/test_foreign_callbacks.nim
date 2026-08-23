import std/unittest

import pluginhost/platform/linux/dynlib
import ../fixtures/ffi/fixture_api

proc nimAdjust(value: int32; context: pointer): int32 {.
    cdecl, gcsafe, raises: [].} =
  if context == nil:
    return value
  result = value +% cast[ptr int32](context)[]

suite "C and Nim callback boundaries":
  test "callbacks round-trip in both directions":
    var opened = openDynamicLibrary(fixturePath())
    require opened.isOk
    var library = move(opened.value)
    defer:
      doAssert library.close().isOk

    let callerResult = resolveSymbol[FixtureCallCallbackProc](library,
      "pluginhost_fixture_call_callback")
    let getterResult = resolveSymbol[FixtureGetCallbackProc](library,
      "pluginhost_fixture_get_callback")
    require callerResult.isOk
    require getterResult.isOk

    var adjustment = 7'i32
    check callerResult.value(nimAdjust, 35, addr adjustment) == 42

    let cCallback = getterResult.value()
    check cCallback != nil
    check cCallback(35, addr adjustment) == 42

    check library.close().isOk

  test "a C-created pthread safely invokes a non-capturing Nim callback":
    var opened = openDynamicLibrary(fixturePath())
    require opened.isOk
    var library = move(opened.value)
    defer:
      doAssert library.close().isOk

    let threadResult = resolveSymbol[FixtureCallOnThreadProc](library,
      "pluginhost_fixture_call_on_thread")
    require threadResult.isOk

    var adjustment = 9'i32
    var callbackResult = 0'i32
    var usedForeignThread = 0'i32
    let status = threadResult.value(
      nimAdjust,
      33,
      addr adjustment,
      addr callbackResult,
      addr usedForeignThread,
    )

    check status == 0
    check callbackResult == 42
    check usedForeignThread == 1

    check library.close().isOk
