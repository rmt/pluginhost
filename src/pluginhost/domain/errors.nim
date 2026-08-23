type
  HostSubsystem* = enum
    hsCli = "CLI"
    hsApplication = "application"
    hsInternal = "internal"

  HostErrorKind* = enum
    hekUsage
    hekNotImplemented
    hekInvalidTransition
    hekInternal

  HostError* = object
    subsystem*: HostSubsystem
    kind*: HostErrorKind
    message*: string
    context*: string

const
  ExitSuccess* = 0
  ExitFailure* = 1
  ExitUsage* = 2

proc hostError*(subsystem: HostSubsystem; kind: HostErrorKind;
                message: string; context = ""): HostError =
  HostError(
    subsystem: subsystem,
    kind: kind,
    message: message,
    context: context,
  )

proc usageError*(message: string; context = ""): HostError =
  hostError(hsCli, hekUsage, message, context)

proc notImplementedError*(message: string; context = ""): HostError =
  hostError(hsApplication, hekNotImplemented, message, context)

proc transitionError*(message: string; context = ""): HostError =
  hostError(hsInternal, hekInvalidTransition, message, context)

proc exitCode*(error: HostError): int =
  case error.kind
  of hekUsage:
    ExitUsage
  of hekNotImplemented, hekInvalidTransition, hekInternal:
    ExitFailure
