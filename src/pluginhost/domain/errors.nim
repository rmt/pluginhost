type
  HostSubsystem* = enum
    hsCli = "CLI"
    hsApplication = "application"
    hsInternal = "internal"
    hsPlatform = "platform"
    hsClap = "CLAP"
    hsDiscovery = "discovery"

  HostErrorKind* = enum
    hekUsage
    hekNotImplemented
    hekInvalidTransition
    hekInternal
    hekLibraryOpen
    hekSymbolLookup
    hekLibraryClose
    hekClapPath
    hekClapEntry
    hekClapVersion
    hekClapEntryInit
    hekClapFactory
    hekClapDescriptor
    hekClapUnload
    hekClapPlugin
    hekClapPluginCreate
    hekClapPluginInit
    hekClapPorts
    hekClapRender
    hekDiscoveryRoot
    hekDiscoveryTraversal
    hekDiscoveryCandidate
    hekPluginSelection

  HostError* = object
    subsystem*: HostSubsystem
    kind*: HostErrorKind
    message*: string
    context*: string

const
  ExitSuccess* = 0
  ExitFailure* = 1
  ExitUsage* = 2
  ExitClap* = 3

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
  of hekUsage, hekPluginSelection:
    ExitUsage
  of hekClapPath, hekClapEntry, hekClapVersion, hekClapEntryInit,
      hekClapFactory, hekClapDescriptor, hekClapUnload, hekClapPlugin,
      hekClapPluginCreate, hekClapPluginInit, hekClapPorts, hekClapRender,
      hekDiscoveryRoot,
      hekDiscoveryTraversal, hekDiscoveryCandidate:
    ExitClap
  of hekNotImplemented, hekInvalidTransition, hekInternal, hekLibraryOpen,
      hekSymbolLookup, hekLibraryClose:
    ExitFailure
