import std/[typetraits, unittest]

import pluginhost/platform/linux/dynlib
import ../fixtures/ffi/fixture_api

when not defined(nimAllocStats):
  {.error: "RT callback tests require -d:nimAllocStats".}

const RtProbeCapacity = 128

type RtProbeState = object
  input: ptr UncheckedArray[cfloat]
  output: ptr UncheckedArray[cfloat]
  capacity: uint32
  gain: cfloat
  processCalls: uint64
  processedFrames: uint64
  lastStatus: int32

static:
  doAssert supportsCopyMem(RtProbeState)

{.push checks: off, stackTrace: off, lineTrace: off.}
proc pluginhostRtProbeProcess(frames: uint32; context: pointer): int32 {.
    exportc: "pluginhost_rt_probe_process", cdecl, gcsafe, raises: [].} =
  if context == nil:
    return -1

  let state = cast[ptr RtProbeState](context)
  if frames > state.capacity:
    state.lastStatus = -2
    return -2
  if frames > 0 and (state.input == nil or state.output == nil):
    state.lastStatus = -3
    return -3

  var index = 0'u32
  while index < frames:
    state.output[index] = state.input[index] * state.gain
    index = index + 1'u32

  state.processCalls = state.processCalls + 1'u64
  state.processedFrames = state.processedFrames + uint64(frames)
  state.lastStatus = 0
  result = 0
{.pop.}

proc initState(input, output: pointer; gain: cfloat): RtProbeState =
  RtProbeState(
    input: cast[ptr UncheckedArray[cfloat]](input),
    output: cast[ptr UncheckedArray[cfloat]](output),
    capacity: uint32(RtProbeCapacity),
    gain: gain,
  )

suite "ARC real-time callback safety spike":
  test "allocation counters detect an instrumented Nim allocation":
    let before = getAllocStats()
    let memory = alloc(32)
    let after = getAllocStats()
    dealloc(memory)

    check before != after

  test "the process-shaped POD callback allocates nothing over repeated calls":
    var input: array[RtProbeCapacity, cfloat]
    var output: array[RtProbeCapacity, cfloat]
    for index in 0 ..< input.len:
      input[index] = cfloat(index)
    var state = initState(addr input[0], addr output[0], 0.5)

    let before = getAllocStats()
    var call = 0'u32
    var callbackStatus = 0'i32
    while call < 10_000'u32:
      callbackStatus = pluginhostRtProbeProcess(uint32(RtProbeCapacity), addr state)
      if callbackStatus != 0:
        break
      call = call + 1'u32
    let after = getAllocStats()

    check callbackStatus == 0
    check before == after
    check state.processCalls == 10_000'u64
    check state.processedFrames == 10_000'u64 * uint64(RtProbeCapacity)
    check output[2] == 1.0

  test "the first callback on a C-created thread has no Nim allocator activity":
    var opened = openDynamicLibrary(fixturePath())
    require opened.isOk
    var library = move(opened.value)
    defer:
      doAssert library.close().isOk
    let threadResult = resolveSymbol[FixtureProcessOnThreadProc](library,
      "pluginhost_fixture_process_on_thread")
    require threadResult.isOk

    var input: array[RtProbeCapacity, cfloat]
    var output: array[RtProbeCapacity, cfloat]
    input[0] = 8.0
    var state = initState(addr input[0], addr output[0], 0.25)
    var callbackResult = -1'i32
    var usedForeignThread = 0'i32

    let before = getAllocStats()
    let status = threadResult.value(
      pluginhostRtProbeProcess,
      uint32(RtProbeCapacity),
      addr state,
      addr callbackResult,
      addr usedForeignThread,
    )
    let after = getAllocStats()

    check status == 0
    check callbackResult == 0
    check usedForeignThread == 1
    check before == after
    check state.processCalls == 1
    check state.processedFrames == uint64(RtProbeCapacity)
    check output[0] == 2.0

    check library.close().isOk

  test "the callback rejects invalid POD views without allocation":
    var state = RtProbeState(capacity: RtProbeCapacity, gain: 1.0)

    let before = getAllocStats()
    let nilStatus = pluginhostRtProbeProcess(1, nil)
    let viewStatus = pluginhostRtProbeProcess(1, addr state)
    let capacityStatus = pluginhostRtProbeProcess(
      uint32(RtProbeCapacity + 1),
      addr state,
    )
    let after = getAllocStats()

    check nilStatus == -1
    check viewStatus == -3
    check capacityStatus == -2
    check before == after
