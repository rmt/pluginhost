## Compile-only negative fixture for the generated callback audit.
## This procedure must never be linked into or executed by a normal test binary.

proc cMalloc(size: csize_t): pointer {.
  importc: "malloc", header: "<stdlib.h>", gcsafe, raises: [].}

{.push checks: off, stackTrace: off, lineTrace: off.}
proc prohibitedRtAuditCanary() {.
    exportc: "pluginhost_rt_audit_negative_canary", cdecl, gcsafe,
    raises: [].} =
  discard cMalloc(16)
{.pop.}
