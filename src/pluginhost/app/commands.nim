import std/strutils

import ./[catalog_output, host_session, run_config]
import ../clap/loader
import ../domain/[errors, result]
import ../support/diagnostics
import ../version


proc executeRun(config: RunConfig; errorOutput: File): int =
  var session = initHostSession()
  let runResult = session.run(config)
  let closeResult = session.close()

  if not runResult.isOk:
    errorOutput.writeDiagnostic(runResult.error)
    return runResult.error.exitCode()
  if not closeResult.isOk:
    errorOutput.writeDiagnostic(closeResult.error)
    return closeResult.error.exitCode()
  ExitSuccess

proc executeList(config: ListConfig; output, errorOutput: File): int =
  var catalog = loadCatalog(config.pluginPath)
  if not catalog.isOk:
    errorOutput.writeDiagnostic(catalog.error)
    return catalog.error.exitCode()

  if config.jsonOutput:
    output.write(renderCatalogJson(catalog.value))
  else:
    output.write(renderCatalogHuman(catalog.value))
  ExitSuccess

proc execute*(command: Command; output, errorOutput: File): int =
  case command.kind
  of ckHelp:
    output.write(command.helpText)
    ExitSuccess
  of ckVersion:
    output.write(versionText())
    ExitSuccess
  of ckRun:
    executeRun(command.runConfig, errorOutput)
  of ckList:
    executeList(command.listConfig, output, errorOutput)
  of ckScan:
    let context = if command.scanConfig.directories.len == 0:
      "standard CLAP paths"
    else:
      command.scanConfig.directories.join(", ")
    let error = notImplementedError(
      "plugin scanning is not implemented in this development increment",
      context,
    )
    errorOutput.writeDiagnostic(error)
    error.exitCode()

proc execute*(command: Command): int =
  execute(command, stdout, stderr)
