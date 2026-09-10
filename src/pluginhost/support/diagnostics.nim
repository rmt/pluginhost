import ../domain/errors
import ./utf8

const
  DefaultWarningIntervalNanos* = 1_000_000_000'i64

type
  WarningKind* = enum
    wkXruns
    wkFreewheel
    wkEventDrops
    wkParameterDrops
    wkPluginLogDrops
    wkConnectionLoss
    wkGuiShow
    wkGuiHide
    wkGuiFailure
    wkTrayFailure

  WarningState = object
    emitted: bool
    nextAllowedNanos: int64
    suppressed: uint64

  WarningEmission* = object
    kind*: WarningKind
    message*: string
    suppressed*: uint64
    emitted*: bool

  WarningLimiter* = object
    intervalNanos: int64
    states: array[WarningKind, WarningState]

proc warningDeadline(nowNanos, intervalNanos: int64): int64 =
  if intervalNanos <= 0:
    return nowNanos
  if nowNanos > high(int64) - intervalNanos:
    return high(int64)
  nowNanos + intervalNanos

proc warningKindName(kind: WarningKind): string =
  case kind
  of wkXruns: "JACK xrun"
  of wkFreewheel: "JACK freewheel"
  of wkEventDrops: "audio event"
  of wkParameterDrops: "CLAP parameter"
  of wkPluginLogDrops: "CLAP log queue"
  of wkConnectionLoss: "JACK connection"
  of wkGuiShow: "GUI show"
  of wkGuiHide: "GUI hide"
  of wkGuiFailure: "GUI failure"
  of wkTrayFailure: "tray"

proc initWarningLimiter*(intervalNanos = DefaultWarningIntervalNanos):
    WarningLimiter =
  result.intervalNanos = if intervalNanos < 0: 0 else: intervalNanos

proc reportWarning*(limiter: var WarningLimiter; kind: WarningKind;
                    nowNanos: int64; message: string): WarningEmission =
  var state = addr limiter.states[kind]
  if not state.emitted:
    state.emitted = true
    state.nextAllowedNanos = warningDeadline(nowNanos, limiter.intervalNanos)
    return WarningEmission(kind: kind, message: message, emitted: true)

  if nowNanos < state.nextAllowedNanos:
    if state.suppressed < high(uint64):
      inc state.suppressed
    return WarningEmission(kind: kind)

  result = WarningEmission(
    kind: kind,
    message: message,
    suppressed: state.suppressed,
    emitted: true,
  )
  state.suppressed = 0
  state.nextAllowedNanos = warningDeadline(nowNanos, limiter.intervalNanos)

proc flushWarnings*(limiter: var WarningLimiter): seq[WarningEmission] =
  for kind in WarningKind:
    var state = addr limiter.states[kind]
    if state.suppressed == 0:
      continue
    result.add(WarningEmission(
      kind: kind,
      message: "suppressed=" & $state.suppressed & " repeated " &
        warningKindName(kind) & " warning(s)",
      emitted: true,
    ))
    state.suppressed = 0

proc formatDiagnostic*(error: HostError): string =
  result = "pluginhost: " & $error.subsystem & " error: " &
    escapeControlText(error.message)
  if error.context.len > 0:
    let safeContext = escapeControlText(error.context)
    result.add(" (" & safeContext & ")")
  result.add("\n")

  if error.kind in {hekUsage, hekPluginSelection}:
    result.add("Try 'pluginhost --help' for usage.\n")

proc writeDiagnostic*(file: File; error: HostError) =
  file.write(formatDiagnostic(error))
