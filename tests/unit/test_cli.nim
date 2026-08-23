import std/[options, strutils, unittest]

import pluginhost/app/[cli, run_config]

suite "command-line parsing":
  test "help and version are successful commands":
    let help = parseCommand(@["--help"])
    let version = parseCommand(@["--version"])

    check help.isOk
    check help.value.kind == ckHelp
    check help.value.helpText.contains("Commands:")
    check help.value.helpText.contains("run")
    check help.value.helpText.contains("list")
    check help.value.helpText.contains("scan")
    check version.isOk
    check version.value.kind == ckVersion

  test "subcommands provide scoped generated help":
    let runHelp = parseCommand(@["run", "--help"])
    let listHelp = parseCommand(@["list", "--help"])

    check runHelp.isOk
    check runHelp.value.kind == ckHelp
    check runHelp.value.helpText.contains("--plugin-id")
    check runHelp.value.helpText.contains("plugin_path")
    check listHelp.isOk
    check listHelp.value.helpText.contains("--json")
    check not listHelp.value.helpText.contains("--plugin-id")

  test "canonical and explicit run forms produce run commands":
    let canonical = parseCommand(@["synth.clap"])
    let explicit = parseCommand(@["run", "effect.clap"])

    check canonical.isOk
    check canonical.value.kind == ckRun
    check canonical.value.runConfig.pluginPath == "synth.clap"
    check explicit.isOk
    check explicit.value.runConfig.pluginPath == "effect.clap"

  test "run parses all initial configuration options":
    let parsed = parseCommand(@[
      "run",
      "--plugin-id", "org.example.synth",
      "--client-name=Example",
      "--jack-server", "studio",
      "--no-start-server",
      "--hide-gui",
      "--require-gui",
      "--gui-scale", "1.5",
      "--load-state", "input.state",
      "--save-state=output.state",
      "--pid-file", "host.pid",
      "--verbose",
      "example.clap",
    ])

    check parsed.isOk
    let config = parsed.value.runConfig
    check config.pluginPath == "example.clap"
    check config.selector.kind == pskId
    check config.selector.pluginId == "org.example.synth"
    check config.clientName == some("Example")
    check config.jackServer == some("studio")
    check config.noStartServer
    check config.guiPolicy == gpHidden
    check config.requireGui
    check config.guiScale == some(1.5)
    check config.loadStatePath == some("input.state")
    check config.saveStatePath == some("output.state")
    check config.pidFilePath == some("host.pid")
    check config.verbosity == vbVerbose

  test "plugin index accepts zero and rejects negative values":
    let zero = parseCommand(@["--plugin-index", "0", "example.clap"])
    let negative = parseCommand(@["--plugin-index", "-1", "example.clap"])

    check zero.isOk
    check zero.value.runConfig.selector.kind == pskIndex
    check zero.value.runConfig.selector.pluginIndex == 0
    check not negative.isOk

  test "option terminator allows a plugin path beginning with a dash":
    let parsed = parseCommand(@["run", "--", "-special.clap"])

    check parsed.isOk
    check parsed.value.runConfig.pluginPath == "-special.clap"

  test "list and scan preserve JSON and path configuration":
    let listed = parseCommand(@["list", "--json", "bundle.clap"])
    let scanned = parseCommand(@["scan", "--json", "one", "two"])
    let standardScan = parseCommand(@["scan"])

    check listed.isOk
    check listed.value.kind == ckList
    check listed.value.listConfig.jsonOutput
    check listed.value.listConfig.pluginPath == "bundle.clap"
    check scanned.isOk
    check scanned.value.scanConfig.jsonOutput
    check scanned.value.scanConfig.directories == @["one", "two"]
    check standardScan.isOk
    check standardScan.value.scanConfig.directories.len == 0

  test "missing paths and unknown options are usage errors":
    for args in [
      newSeq[string](),
      @["run"],
      @["list"],
      @["--unknown", "plugin.clap"],
    ]:
      let parsed = parseCommand(args)
      check not parsed.isOk

  test "mutually exclusive options are rejected":
    let selectors = parseCommand(@[
      "--plugin-id", "id", "--plugin-index", "1", "plugin.clap"])
    let gui = parseCommand(@["--show-gui", "--hide-gui", "plugin.clap"])
    let impossibleGui = parseCommand(@["--no-gui", "--require-gui", "plugin.clap"])
    let verbosity = parseCommand(@["--quiet", "--verbose", "plugin.clap"])

    check not selectors.isOk
    check not gui.isOk
    check not impossibleGui.isOk
    check not verbosity.isOk

  test "value options reject missing empty and repeated values":
    let missing = parseCommand(@["--plugin-id"])
    let empty = parseCommand(@["--plugin-id=", "plugin.clap"])
    let repeated = parseCommand(@[
      "--client-name", "one", "--client-name", "two", "plugin.clap"])
    let invalidScale = parseCommand(@["--gui-scale", "nan", "plugin.clap"])

    check not missing.isOk
    check not empty.isOk
    check not repeated.isOk
    check not invalidScale.isOk
