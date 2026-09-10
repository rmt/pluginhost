import ./[catalog_output, host_session, run_config]
import ../clap/loader
import ../discovery/scanner
import ../domain/[errors, result]
import ../support/diagnostics
import ../version


proc executeRun(config: RunConfig; errorOutput: File): int =
  var session = initHostSession()
  let runResult = session.run(config, errorOutput)
  let closeResult = session.close(errorOutput)

  if not runResult.isOk:
    errorOutput.writeDiagnostic(runResult.error)
    if not closeResult.isOk:
      errorOutput.writeDiagnostic(closeResult.error)
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
    let report = scanPlugins(command.scanConfig.directories)
    if command.scanConfig.jsonOutput:
      output.write(renderScanJson(report))
    else:
      output.write(renderScanHuman(report))
    for issue in report.issues:
      errorOutput.writeDiagnostic(issue.error)
    if report.issues.len > 0:
      ExitClap
    else:
      ExitSuccess

proc execute*(command: Command): int =
  execute(command, stdout, stderr)
