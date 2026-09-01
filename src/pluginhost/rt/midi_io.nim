## Backend-neutral fixed-layout MIDI buffer access for the real-time engine.
##
## Concrete audio backends adapt their native event buffers to this POD view.
## No function in this module allocates, blocks, logs, or owns foreign storage.

import std/typetraits

const RtMaxMidiPortsPerDirection* = 1_024'u32

type
  RtMidiEventView* {.bycopy.} = object
    time*: uint32
    size*: uint32
    data*: ptr UncheckedArray[uint8]

  RtMidiEventCountProc* = proc(context, portBuffer: pointer): uint32 {.
    cdecl, gcsafe, raises: [].}
  RtMidiEventGetProc* = proc(context, portBuffer: pointer; index: uint32;
                             event: ptr RtMidiEventView): bool {.
    cdecl, gcsafe, raises: [].}
  RtMidiClearProc* = proc(context, portBuffer: pointer) {.
    cdecl, gcsafe, raises: [].}
  RtMidiReserveProc* = proc(context, portBuffer: pointer; time, size: uint32):
      ptr UncheckedArray[uint8] {.cdecl, gcsafe, raises: [].}
  RtMidiLostEventCountProc* = proc(context, portBuffer: pointer): uint32 {.
    cdecl, gcsafe, raises: [].}

  RtMidiIo* {.bycopy.} = object
    context*: pointer
    eventCount*: RtMidiEventCountProc
    eventGet*: RtMidiEventGetProc
    clear*: RtMidiClearProc
    reserve*: RtMidiReserveProc
    lostEventCount*: RtMidiLostEventCountProc

static:
  doAssert supportsCopyMem(RtMidiEventView)
  doAssert supportsCopyMem(RtMidiIo)

{.push checks: off, stackTrace: off, lineTrace: off.}
proc isReadable*(io: RtMidiIo): bool {.inline, gcsafe, raises: [].} =
  io.context != nil and io.eventCount != nil and io.eventGet != nil

proc isWritable*(io: RtMidiIo): bool {.inline, gcsafe, raises: [].} =
  io.context != nil and io.clear != nil and io.reserve != nil
{.pop.}
