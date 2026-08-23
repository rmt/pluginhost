import std/os

import pluginhost/app/[cli, commands]
import pluginhost/domain/errors
import pluginhost/support/diagnostics

proc runMain*(args: seq[string]; output, errorOutput: File): int =
  let parsed = parseCommand(args)
  if not parsed.isOk:
    errorOutput.writeDiagnostic(parsed.error)
    return parsed.error.exitCode()
  execute(parsed.value, output, errorOutput)

proc runMain*(args: seq[string]): int =
  runMain(args, stdout, stderr)

when isMainModule:
  quit(runMain(commandLineParams()))
