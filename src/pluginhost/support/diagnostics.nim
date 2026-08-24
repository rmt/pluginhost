import ../domain/errors
import ./utf8

proc formatDiagnostic*(error: HostError): string =
  result = "pluginhost: " & $error.subsystem & " error: " & error.message
  if error.context.len > 0:
    let safeContext = escapeControlText(error.context)
    result.add(" (" & safeContext & ")")
  result.add("\n")

  if error.kind in {hekUsage, hekPluginSelection}:
    result.add("Try 'pluginhost --help' for usage.\n")

proc writeDiagnostic*(file: File; error: HostError) =
  file.write(formatDiagnostic(error))
