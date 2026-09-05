import std/[os, posix]

import ../../domain/[errors, result]
import ../../support/utf8

const
  LinuxProcessNameBytes* = 15
  PrSetName = 15.cint

proc prctl(option: cint; arg2: pointer; arg3, arg4, arg5: culong): cint {.
  importc, header: "<sys/prctl.h>", raises: [].}

proc linuxProcessName*(displayName: string): string =
  let bounded = truncateUtf8Bytes(displayName, LinuxProcessNameBytes)
  if bounded.len > 0:
    return bounded
  "pluginhost"

proc setLinuxProcessName*(displayName: string): Result[Unit] =
  let name = linuxProcessName(displayName)
  if prctl(PrSetName, cast[pointer](name.cstring), 0'u, 0'u, 0'u) != 0:
    return failure[Unit](hostError(
      hsPlatform, hekInternal,
      "could not set the Linux process name",
      "name=" & name & "; errno=" & $int(osLastError()) &
        " [" & osErrorMsg(osLastError()) & "]",
    ))
  success()
