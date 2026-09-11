import std/[monotimes, os, posix, unittest]

import pluginhost/domain/[port_plan, result]
import pluginhost/jack/backend
import pluginhost/rt/engine
import ../rt/instrumentation_api

const
  ReferenceSampleRate = 48_000'u32
  ReferenceBufferSize = 64'u32
  WarmupCycles = 64'u64
  MeasurementCycles = 4_096'u64
  ClockNanosecondsPerSecond = 1_000_000_000'i64


proc processCpuNanos(): int64 =
  var value: Timespec
  require clock_gettime(CLOCK_PROCESS_CPUTIME_ID, value) == 0
  let seconds = int64(value.tv_sec)
  let nanoseconds = int64(value.tv_nsec)
  require seconds >= 0 and nanoseconds >= 0 and
    nanoseconds < ClockNanosecondsPerSecond
  seconds * ClockNanosecondsPerSecond + nanoseconds

proc noEventPortPlan(): PortPlan =
  newPortPlan(
    portPlanVersion(1),
    @[],
    @[
      AudioChannelPlan(direction: pdInput, shortName: "audio_in_1"),
      AudioChannelPlan(direction: pdInput, shortName: "audio_in_2"),
      AudioChannelPlan(direction: pdOutput, shortName: "audio_out_1"),
      AudioChannelPlan(direction: pdOutput, shortName: "audio_out_2"),
    ],
    @[],
  )

proc waitForCycles(backend: JackBackend; target: uint64): bool =
  var attempt = 0
  while attempt < 20_000:
    if backend.notifications().processCycles >= target:
      return true
    sleep(1)
    inc attempt
  false

proc coherentNotifications(backend: JackBackend;
                            snapshot: var JackNotificationSnapshot): bool =
  var attempt = 0
  while attempt < 20_000:
    let candidate = backend.notifications()
    if candidate.processFrames ==
        candidate.processCycles * uint64(ReferenceBufferSize):
      snapshot = candidate
      return true
    sleep(1)
    inc attempt
  false

suite "11C no-event host overhead":
  test "fixed reference quantum reports host-only process cost":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"

    var opened = openJackBackend(initJackBackendOpenConfig(
      "pluginhost-11c-overhead", noStartServer = true))
    require opened.isOk
    var backend = move(opened.value)
    defer:
      doAssert backend.close().isOk

    check backend.sampleRate == ReferenceSampleRate
    check backend.bufferSize == ReferenceBufferSize
    require backend.configure(noEventPortPlan(), fpmSilence).isOk
    require backend.activate().isOk
    require backend.waitForCycles(WarmupCycles)

    resetRtInstrumentation()
    var beforeNotifications: JackNotificationSnapshot
    require backend.coherentNotifications(beforeNotifications)
    let beforeCpu = processCpuNanos()
    let beforeWall = getMonoTime().ticks
    require backend.waitForCycles(
      beforeNotifications.processCycles + MeasurementCycles)
    let afterWall = getMonoTime().ticks
    let afterCpu = processCpuNanos()
    var afterNotifications: JackNotificationSnapshot
    require backend.coherentNotifications(afterNotifications)

    require backend.deactivate().isOk
    let instrumentation = snapshotRtInstrumentation()
    let cycles = afterNotifications.processCycles -
      beforeNotifications.processCycles
    let frames = afterNotifications.processFrames -
      beforeNotifications.processFrames
    let cpuNanos = afterCpu - beforeCpu
    let wallNanos = afterWall - beforeWall
    require cycles >= MeasurementCycles
    require frames == cycles * uint64(ReferenceBufferSize)
    require cpuNanos >= 0
    require wallNanos > 0

    check afterNotifications.processErrors == beforeNotifications.processErrors
    check afterNotifications.lateProcessCalls ==
      beforeNotifications.lateProcessCalls
    check instrumentation.isClean
    check instrumentation.callbackEntries >= cycles

    let microsecondsPerCycle = cpuNanos.float64 / 1_000.0 / cycles.float64
    let cpuPercentage = cpuNanos.float64 / wallNanos.float64 * 100.0
    echo "11C overhead sample-rate=", backend.sampleRate,
      " buffer-size=", backend.bufferSize,
      " cycles=", cycles,
      " frames=", frames,
      " cpu-ns=", cpuNanos,
      " wall-ns=", wallNanos,
      " us-per-cycle=", microsecondsPerCycle,
      " cpu-percent=", cpuPercentage,
      " xruns=", afterNotifications.xrunCount -
        beforeNotifications.xrunCount,
      " allocations=", instrumentation.allocations,
      " deallocations=", instrumentation.deallocations,
      " locks=", instrumentation.locks,
      " prints=", instrumentation.prints,
      " io=", instrumentation.io
