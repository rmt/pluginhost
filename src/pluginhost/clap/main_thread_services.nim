## Narrow stable callback table used by CLAP host timer/FD callbacks.
##
## The CLAP adapter owns no reactor policy. The application installs this table
## before plugin creation and keeps its context alive until after destruction.

type
  ClapMainThreadServices* {.bycopy.} = object
    context*: pointer
    registerTimer*: proc(context: pointer; periodMs: uint32;
                         timerId: ptr cuint): bool {.
      cdecl, gcsafe, raises: [].}
    unregisterTimer*: proc(context: pointer; timerId: uint32): bool {.
      cdecl, gcsafe, raises: [].}
    registerFd*: proc(context: pointer; fd: int32; flags: uint32): bool {.
      cdecl, gcsafe, raises: [].}
    modifyFd*: proc(context: pointer; fd: int32; flags: uint32): bool {.
      cdecl, gcsafe, raises: [].}
    unregisterFd*: proc(context: pointer; fd: int32): bool {.
      cdecl, gcsafe, raises: [].}

{.push checks: off, stackTrace: off, lineTrace: off.}
proc isComplete*(services: ptr ClapMainThreadServices): bool {.
    inline, gcsafe, raises: [].} =
  services != nil and services.context != nil and
    services.registerTimer != nil and services.unregisterTimer != nil and
    services.registerFd != nil and services.modifyFd != nil and
    services.unregisterFd != nil
{.pop.}
