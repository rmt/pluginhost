type
  RtInstrumentationReport* {.bycopy.} = object
    allocations*: uint64
    deallocations*: uint64
    locks*: uint64
    prints*: uint64
    io*: uint64
    callbackEntries*: uint64

proc resetRtInstrumentation*() {.
  importc: "pluginhost_rt_instrumentation_reset", cdecl, gcsafe, raises: [].}
proc snapshotRtInstrumentation*(): RtInstrumentationReport {.
  importc: "pluginhost_rt_instrumentation_snapshot", cdecl, gcsafe,
  raises: [].}
proc runRtInstrumentationSelfTest*(): cint {.
  importc: "pluginhost_rt_instrumentation_self_test", cdecl, gcsafe,
  raises: [].}

proc isClean*(report: RtInstrumentationReport): bool =
  report.allocations == 0 and report.deallocations == 0 and
    report.locks == 0 and report.prints == 0 and report.io == 0
