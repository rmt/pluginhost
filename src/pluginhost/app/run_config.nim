import std/options

type
  PluginSelectorKind* = enum
    pskImplicitSingle
    pskId
    pskIndex

  PluginSelector* = object
    case kind*: PluginSelectorKind
    of pskImplicitSingle:
      discard
    of pskId:
      pluginId*: string
    of pskIndex:
      pluginIndex*: int

  GuiPolicy* = enum
    gpShow
    gpHidden
    gpDisabled

  Verbosity* = enum
    vbQuiet
    vbNormal
    vbVerbose

  RunConfig* = object
    pluginPath*: string
    selector*: PluginSelector
    clientName*: Option[string]
    jackServer*: Option[string]
    noStartServer*: bool
    guiPolicy*: GuiPolicy
    requireGui*: bool
    guiScale*: Option[float]
    loadStatePath*: Option[string]
    saveStatePath*: Option[string]
    pidFilePath*: Option[string]
    verbosity*: Verbosity

  ListConfig* = object
    pluginPath*: string
    jsonOutput*: bool

  ScanConfig* = object
    directories*: seq[string]
    jsonOutput*: bool

  CommandKind* = enum
    ckRun
    ckList
    ckScan
    ckHelp
    ckVersion

  Command* = object
    case kind*: CommandKind
    of ckRun:
      runConfig*: RunConfig
    of ckList:
      listConfig*: ListConfig
    of ckScan:
      scanConfig*: ScanConfig
    of ckHelp:
      helpText*: string
    of ckVersion:
      discard

proc defaultRunConfig*(): RunConfig =
  RunConfig(
    selector: PluginSelector(kind: pskImplicitSingle),
    guiPolicy: gpShow,
    verbosity: vbNormal,
  )
