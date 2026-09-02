import std/unittest

import pluginhost/clap/[ffi, parameter_transport]

proc parameterValue(time: uint32; value: cdouble): ClapEventParamValue =
  ClapEventParamValue(
    header: ClapEventHeader(
      size: uint32(sizeof(ClapEventParamValue)), time: time,
      spaceId: ClapCoreEventSpaceId, `type`: ClapEventTypeParamValue,
    ),
    paramId: 7'u32, noteId: -1, portIndex: -1, channel: -1, key: -1,
    value: value,
  )

suite "fixed-capacity CLAP parameter transport":
  test "copies scalar values, rejects malformed events, and recovers after overflow":
    var transport = newClapParameterTransport()
    require transport != nil
    defer: transport.close()

    var first = parameterValue(3'u32, 0.25)
    check transport.tryPushOutput(addr first.header, 64'u32)
    first.value = 0.75
    var copied: ClapParameterEvent
    require transport.tryPop(copied)
    check copied.kind == cpekValue
    check copied.paramId == 7'u32
    check copied.time == 3
    check copied.value == 0.25

    var malformed = first.header
    malformed.size = uint32(sizeof(ClapEventHeader))
    check not transport.tryPushOutput(addr malformed, 64'u32)

    var queued = parameterValue(0'u32, 0.5)
    for index in 0'u64 ..< ClapParameterEventCapacity:
      check transport.tryPushOutput(addr queued.header, 64'u32)
    check not transport.tryPushOutput(addr queued.header, 64'u32)
    let full = transport.takeMetrics()
    check full.accepted == ClapParameterEventCapacity + 1'u64
    check full.invalid == 1
    check full.capacityDrops == 1
    check full.dropped == 2

    require transport.tryPop(copied)
    check transport.tryPushOutput(addr queued.header, 64'u32)
    let recovered = transport.takeMetrics()
    check recovered.accepted == 1
    check recovered.dropped == 0

  test "preserves modulation and gesture scalar records":
    var transport = newClapParameterTransport()
    require transport != nil
    defer: transport.close()
    var modulation = ClapEventParamMod(
      header: ClapEventHeader(size: uint32(sizeof(ClapEventParamMod)), time: 4'u32,
        spaceId: ClapCoreEventSpaceId, `type`: ClapEventTypeParamMod),
      paramId: 9'u32, noteId: 12, portIndex: 1, channel: 2, key: 60, amount: 0.125)
    var beginGesture = ClapEventParamGesture(
      header: ClapEventHeader(size: uint32(sizeof(ClapEventParamGesture)), time: 5'u32,
        spaceId: ClapCoreEventSpaceId, `type`: ClapEventTypeParamGestureBegin),
      paramId: 9'u32)
    var endGesture = beginGesture
    endGesture.header.time = 6'u32
    endGesture.header.`type` = ClapEventTypeParamGestureEnd
    check transport.tryPushOutput(addr modulation.header, 64'u32)
    check transport.tryPushOutput(addr beginGesture.header, 64'u32)
    check transport.tryPushOutput(addr endGesture.header, 64'u32)
    var copied: ClapParameterEvent
    require transport.tryPop(copied)
    check copied.kind == cpekModulation
    check copied.value == 0.125
    check copied.noteId == 12
    require transport.tryPop(copied)
    check copied.kind == cpekGestureBegin
    require transport.tryPop(copied)
    check copied.kind == cpekGestureEnd
