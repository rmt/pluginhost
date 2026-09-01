import std/os

import pluginhost/domain/result
import pluginhost/platform/linux/dynlib

const EventFixtureDirectoryEnvironment* = "PLUGINHOST_CLAP_EVENT_FIXTURE_DIR"

type
  EventResetProc* = proc() {.cdecl, gcsafe, raises: [].}
  EventSetStatusProc* = proc(status: int32) {.cdecl, gcsafe, raises: [].}
  EventCountProc* = proc(): uint32 {.cdecl, gcsafe, raises: [].}
  EventGetU32Proc* = proc(index: uint32): uint32 {.
    cdecl, gcsafe, raises: [].}
  EventGetI32Proc* = proc(index: uint32): int32 {.
    cdecl, gcsafe, raises: [].}
  EventGetDoubleProc* = proc(index: uint32): cdouble {.
    cdecl, gcsafe, raises: [].}
  EventGetByteProc* = proc(index, byteIndex: uint32): cint {.
    cdecl, gcsafe, raises: [].}
  EventGetAddressProc* = proc(index: uint32): uint64 {.
    cdecl, gcsafe, raises: [].}

  EventFixtureApi* = object
    reset*: EventResetProc
    setProcessStatus*: EventSetStatusProc
    observedCount*: EventCountProc
    processCount*: EventCountProc
    outputAccepted*: EventCountProc
    outputRejected*: EventCountProc
    contractFailures*: EventCountProc
    destroyCount*: EventCountProc
    eventType*: EventGetU32Proc
    time*: EventGetU32Proc
    flags*: EventGetU32Proc
    port*: EventGetI32Proc
    channel*: EventGetI32Proc
    key*: EventGetI32Proc
    expression*: EventGetI32Proc
    value*: EventGetDoubleProc
    size*: EventGetU32Proc
    eventByte*: EventGetByteProc
    address*: EventGetAddressProc

proc eventFixturePath*(variant: string): string =
  let directory = getEnv(EventFixtureDirectoryEnvironment)
  if directory.len == 0:
    raise newException(ValueError,
      EventFixtureDirectoryEnvironment & " must name the event fixture directory")
  directory / (variant & ".clap")

proc eventFixtureApi*(library: DynamicLibrary): EventFixtureApi =
  template resolve(field: untyped; procedureType: typedesc;
                   symbol: static string) =
    block:
      let resolved = resolveSymbol[procedureType](library, symbol)
      doAssert resolved.isOk, symbol
      result.field = resolved.value

  resolve(reset, EventResetProc, "pluginhost_event_fixture_reset")
  resolve(setProcessStatus, EventSetStatusProc,
    "pluginhost_event_fixture_set_process_status")
  resolve(observedCount, EventCountProc, "pluginhost_event_fixture_observed_count")
  resolve(processCount, EventCountProc, "pluginhost_event_fixture_process_count")
  resolve(outputAccepted, EventCountProc, "pluginhost_event_fixture_output_accepted")
  resolve(outputRejected, EventCountProc, "pluginhost_event_fixture_output_rejected")
  resolve(contractFailures, EventCountProc,
    "pluginhost_event_fixture_contract_failures")
  resolve(destroyCount, EventCountProc, "pluginhost_event_fixture_destroy_count")
  resolve(eventType, EventGetU32Proc, "pluginhost_event_fixture_type")
  resolve(time, EventGetU32Proc, "pluginhost_event_fixture_time")
  resolve(flags, EventGetU32Proc, "pluginhost_event_fixture_flags")
  resolve(port, EventGetI32Proc, "pluginhost_event_fixture_port")
  resolve(channel, EventGetI32Proc, "pluginhost_event_fixture_channel")
  resolve(key, EventGetI32Proc, "pluginhost_event_fixture_key")
  resolve(expression, EventGetI32Proc, "pluginhost_event_fixture_expression")
  resolve(value, EventGetDoubleProc, "pluginhost_event_fixture_value")
  resolve(size, EventGetU32Proc, "pluginhost_event_fixture_size")
  resolve(eventByte, EventGetByteProc, "pluginhost_event_fixture_byte")
  resolve(address, EventGetAddressProc, "pluginhost_event_fixture_address")
