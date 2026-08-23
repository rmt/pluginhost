import std/[math, options, parseutils, strutils]

import argparse

import ./run_config
import ../domain/[errors, result]

let commandParser = newParser("pluginhost"):
  help("""Host one native CLAP plugin as a JACK client.

The 'run' subcommand may be omitted: pluginhost [run options] PLUGIN_PATH""")
  flag("-V", "--version", shortcircuit = true,
       help = "Display version information")

  command("run"):
    help("Run one CLAP plugin as a JACK client.")
    flag("-V", "--version", shortcircuit = true,
         help = "Display version information")
    option("--plugin-id", help = "Select a descriptor by stable CLAP ID")
    option("--plugin-index",
           help = "Select a descriptor by zero-based bundle index")
    option("--client-name", help = "Request a JACK client name")
    option("--jack-server", help = "Connect to a named JACK server")
    flag("--no-start-server", help = "Do not allow libjack to start a server")
    flag("--show-gui", help = "Show the plugin GUI after startup (default)")
    flag("--hide-gui", help = "Start with the plugin GUI hidden")
    flag("--no-gui", help = "Disable GUI hosting")
    flag("--require-gui", help = "Fail if a usable GUI cannot be shown")
    option("--gui-scale", help = "Request a positive GUI scale")
    option("--load-state", help = "Load CLAP state before activation")
    option("--save-state", help = "Save CLAP state on clean shutdown")
    option("--pid-file", help = "Write the running process ID to this file")
    flag("-v", "--verbose", help = "Enable diagnostic logging")
    flag("-q", "--quiet", help = "Suppress non-error host messages")
    arg("plugin_path", help = "Path to a native .clap plugin")

  command("list"):
    help("List the CLAP descriptors in one plugin library.")
    flag("-V", "--version", shortcircuit = true,
         help = "Display version information")
    flag("--json", help = "Write machine-readable JSON")
    arg("plugin_path", help = "Path to a native .clap plugin")

  command("scan"):
    help("Scan explicit or standard directories for CLAP plugins.")
    flag("-V", "--version", shortcircuit = true,
         help = "Display version information")
    flag("--json", help = "Write machine-readable JSON")
    arg("directories", nargs = -1, help = "Directories to scan recursively")

proc parseNonNegativeInt(value, optionName: string): Result[int] =
  var parsed: int
  let consumed = parseInt(value, parsed)
  if consumed != value.len or parsed < 0:
    return failure[int](usageError(
      "expected a non-negative integer",
      optionName & "=" & value,
    ))
  success(parsed)

proc parsePositiveFloat(value, optionName: string): Result[float] =
  var parsed: float
  let consumed = parseFloat(value, parsed)
  if consumed != value.len or parsed <= 0.0 or
      classify(parsed) in {fcNan, fcInf, fcNegInf}:
    return failure[float](usageError(
      "expected a finite positive number",
      optionName & "=" & value,
    ))
  success(parsed)

proc validateOptional(value: Option[string]; optionName: string):
    Result[Option[string]] =
  if value.isSome and value.get().len == 0:
    return failure[Option[string]](usageError(
      "empty option value is not allowed",
      optionName,
    ))
  success(value)

proc buildRunCommand(options: auto): Result[Command] =
  if options.plugin_path.len == 0:
    return failure[Command](usageError("plugin path must not be empty"))

  let pluginId = validateOptional(options.plugin_id_opt, "--plugin-id")
  if not pluginId.isOk:
    return failure[Command](pluginId.error)
  let pluginIndex = validateOptional(options.plugin_index_opt, "--plugin-index")
  if not pluginIndex.isOk:
    return failure[Command](pluginIndex.error)
  if pluginId.value.isSome and pluginIndex.value.isSome:
    return failure[Command](usageError(
      "--plugin-id and --plugin-index are mutually exclusive"))

  var config = defaultRunConfig()
  config.pluginPath = options.plugin_path
  if pluginId.value.isSome:
    config.selector = PluginSelector(
      kind: pskId,
      pluginId: pluginId.value.get(),
    )
  elif pluginIndex.value.isSome:
    let parsed = parseNonNegativeInt(
      pluginIndex.value.get(), "--plugin-index")
    if not parsed.isOk:
      return failure[Command](parsed.error)
    config.selector = PluginSelector(
      kind: pskIndex,
      pluginIndex: parsed.value,
    )

  let clientName = validateOptional(options.client_name_opt, "--client-name")
  if not clientName.isOk:
    return failure[Command](clientName.error)
  config.clientName = clientName.value

  let jackServer = validateOptional(options.jack_server_opt, "--jack-server")
  if not jackServer.isOk:
    return failure[Command](jackServer.error)
  config.jackServer = jackServer.value
  config.noStartServer = options.no_start_server

  let selectedGuiPolicies =
    ord(options.show_gui) + ord(options.hide_gui) + ord(options.no_gui)
  if selectedGuiPolicies > 1:
    return failure[Command](usageError(
      "--show-gui, --hide-gui, and --no-gui are mutually exclusive"))
  if options.hide_gui:
    config.guiPolicy = gpHidden
  elif options.no_gui:
    config.guiPolicy = gpDisabled
  else:
    config.guiPolicy = gpShow
  config.requireGui = options.require_gui
  if config.guiPolicy == gpDisabled and config.requireGui:
    return failure[Command](usageError(
      "--no-gui and --require-gui are mutually exclusive"))

  let guiScale = validateOptional(options.gui_scale_opt, "--gui-scale")
  if not guiScale.isOk:
    return failure[Command](guiScale.error)
  if guiScale.value.isSome:
    let parsed = parsePositiveFloat(guiScale.value.get(), "--gui-scale")
    if not parsed.isOk:
      return failure[Command](parsed.error)
    config.guiScale = some(parsed.value)

  let loadState = validateOptional(options.load_state_opt, "--load-state")
  if not loadState.isOk:
    return failure[Command](loadState.error)
  config.loadStatePath = loadState.value

  let saveState = validateOptional(options.save_state_opt, "--save-state")
  if not saveState.isOk:
    return failure[Command](saveState.error)
  config.saveStatePath = saveState.value

  let pidFile = validateOptional(options.pid_file_opt, "--pid-file")
  if not pidFile.isOk:
    return failure[Command](pidFile.error)
  config.pidFilePath = pidFile.value

  if options.verbose and options.quiet:
    return failure[Command](usageError(
      "--verbose and --quiet are mutually exclusive"))
  if options.verbose:
    config.verbosity = vbVerbose
  elif options.quiet:
    config.verbosity = vbQuiet

  success(Command(kind: ckRun, runConfig: config))

proc buildListCommand(options: auto): Result[Command] =
  if options.plugin_path.len == 0:
    return failure[Command](usageError("plugin path must not be empty"))
  success(Command(
    kind: ckList,
    listConfig: ListConfig(
      pluginPath: options.plugin_path,
      jsonOutput: options.json,
    ),
  ))

proc buildScanCommand(options: auto): Result[Command] =
  for directory in options.directories:
    if directory.len == 0:
      return failure[Command](usageError("scan directory must not be empty"))
  success(Command(
    kind: ckScan,
    scanConfig: ScanConfig(
      directories: options.directories,
      jsonOutput: options.json,
    ),
  ))

proc normalizeDefaultRun(args: seq[string]): seq[string] =
  if args.len == 0 or
      args[0] in ["run", "list", "scan", "-h", "--help", "-V", "--version"]:
    return args
  @["run"] & args

proc ensureTrailingNewline(text: string): string =
  if text.endsWith("\n"):
    text
  else:
    text & "\n"

proc parseCommand*(args: seq[string]): Result[Command] =
  try:
    let options = commandParser.parse(normalizeDefaultRun(args))
    case options.command
    of "run":
      if options.run.isNone:
        return failure[Command](hostError(
          hsInternal, hekInternal, "run command options are unavailable"))
      buildRunCommand(options.run.get())
    of "list":
      if options.list.isNone:
        return failure[Command](hostError(
          hsInternal, hekInternal, "list command options are unavailable"))
      buildListCommand(options.list.get())
    of "scan":
      if options.scan.isNone:
        return failure[Command](hostError(
          hsInternal, hekInternal, "scan command options are unavailable"))
      buildScanCommand(options.scan.get())
    else:
      failure[Command](usageError("missing command or plugin path"))
  except ShortCircuit as error:
    case error.flag
    of "argparse_help":
      success(Command(
        kind: ckHelp,
        helpText: ensureTrailingNewline(error.help),
      ))
    of "version":
      success(Command(kind: ckVersion))
    else:
      failure[Command](hostError(
        hsInternal,
        hekInternal,
        "unknown command-line short circuit",
        error.flag,
      ))
  except UsageError as error:
    failure[Command](usageError(error.msg))
