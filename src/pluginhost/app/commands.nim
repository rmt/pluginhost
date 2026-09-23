
import ./[catalog_output, host_session, run_config]
import ../clap/loader as clap_loader
import ../discovery/scanner
import ../domain/[errors, result]
import ../support/diagnostics
import ../version


import ../vst3/catalog as vst3_catalog
## Failed native teardown can still own JACK callbacks or borrowed reactor
## registrations. Keep the session graph pinned until process exit rather than
## run move-only destructors against resources that could still be referenced.
var quarantinedSessions: seq[ref HostSession]

proc vst3InnerPathError(path: string): HostError =
  hostError(
    hsVst3,
    hekVst3Path,
    "a path inside a VST3 bundle is not a selectable plugin",
    path,
  )

proc loadPluginCatalog(path: string): Result[PluginCatalog] =
  if vst3_catalog.isVst3InnerPath(path):
    return failure[PluginCatalog](vst3InnerPathError(path))
  if vst3_catalog.isVst3BundlePath(path):
    return vst3_catalog.loadVst3Catalog(path)
  clap_loader.loadCatalog(path)

proc executeRun(config: RunConfig; errorOutput: File): int =
  if vst3_catalog.isVst3InnerPath(config.pluginPath):
    let error = vst3InnerPathError(config.pluginPath)
    errorOutput.writeDiagnostic(error)
    return error.exitCode()

  var session: ref HostSession
  new(session)
  session[] = initHostSession()
  let runResult = session[].run(config, errorOutput)
  let closeResult = session[].close(errorOutput)
  if not closeResult.isOk:
    quarantinedSessions.add(session)
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
  var catalog = loadPluginCatalog(config.pluginPath)
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
