import std/strutils

import ./[host_session, run_config]
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
    let error = notImplementedError(
      "plugin listing is not implemented in this development increment",
      command.listConfig.pluginPath,
    )
    errorOutput.writeDiagnostic(error)
    error.exitCode()
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
