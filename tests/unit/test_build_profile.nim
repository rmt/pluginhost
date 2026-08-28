import std/unittest

const
  usesArc = compileOption("gc", "arc")
  hasThreadSupport = compileOption("threads")
  defectsArePanics = compileOption("panics")
  nimSignalHandlersDisabled = defined(noSignalHandler)

suite "shared Nim safety profile":
  test "tests use the product memory, thread, panic, and signal settings":
    check usesArc
    check hasThreadSupport
    check defectsArePanics
    check nimSignalHandlersDisabled
