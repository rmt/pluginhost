import ../domain/errors

proc formatDiagnostic*(error: HostError): string =
  result = "pluginhost: " & $error.subsystem & " error: " & error.message
  if error.context.len > 0:
    result.add(" (" & error.context & ")")
  result.add("\n")

  if error.kind == hekUsage:
    result.add("Try 'pluginhost --help' for usage.\n")

proc writeDiagnostic*(file: File; error: HostError) =
  file.write(formatDiagnostic(error))
