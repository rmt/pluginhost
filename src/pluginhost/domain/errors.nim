type
  HostSubsystem* = enum
    hsCli = "CLI"
    hsApplication = "application"
    hsInternal = "internal"
    hsPlatform = "platform"
    hsClap = "CLAP"
    hsJack = "JACK"
    hsDiscovery = "discovery"
    hsGui = "GUI"
    hsState = "state"

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
    hekClapActivation
    hekClapStartProcessing
    hekClapStopProcessing
    hekClapDeactivation
    hekClapProcess
    hekClapPorts
    hekClapRender
    hekJackLibraryOpen
    hekJackSymbol
    hekJackLibraryClose
    hekJackClientOpen
    hekJackClientClose
    hekJackCallbackRegistration
    hekJackPortName
    hekJackPortRegistration
    hekJackPortAlias
    hekJackActivation
    hekJackDeactivation
    hekJackQuiescence
    hekDiscoveryRoot
    hekDiscoveryTraversal
    hekDiscoveryCandidate
    hekPluginSelection
    hekReactor
    hekSignal
    hekPidFile
    hekGui
    hekState

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
  ExitJack* = 4
  ExitGui* = 5
  ExitState* = 6

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
  case error.subsystem
  of hsJack:
    return ExitJack
  of hsGui:
    return ExitGui
  of hsState:
    return ExitState
  else:
    discard

  case error.kind
  of hekUsage, hekPluginSelection:
    ExitUsage
  of hekClapPath, hekClapEntry, hekClapVersion, hekClapEntryInit,
      hekClapFactory, hekClapDescriptor, hekClapUnload, hekClapPlugin,
      hekClapPluginCreate, hekClapPluginInit, hekClapActivation,
      hekClapStartProcessing, hekClapStopProcessing, hekClapDeactivation,
      hekClapProcess, hekClapPorts, hekClapRender,
      hekDiscoveryRoot, hekDiscoveryTraversal, hekDiscoveryCandidate:
    ExitClap
  of hekGui:
    ExitGui
  of hekState:
    ExitState
  of hekNotImplemented, hekInvalidTransition, hekInternal, hekLibraryOpen,
      hekSymbolLookup, hekLibraryClose, hekJackLibraryOpen, hekJackSymbol,
      hekJackLibraryClose, hekJackClientOpen, hekJackClientClose,
      hekJackCallbackRegistration, hekJackPortName, hekJackPortRegistration,
      hekJackPortAlias, hekJackActivation, hekJackDeactivation,
      hekJackQuiescence, hekReactor, hekSignal, hekPidFile:
    ExitFailure
