import std/[strutils, unittest]

import pluginhost/domain/errors
import pluginhost/support/diagnostics

suite "typed errors and diagnostics":
  test "usage errors map to exit status two and include a usage hint":
    let error = usageError("missing plugin path")
    let text = formatDiagnostic(error)

    check error.exitCode() == ExitUsage
    check text.contains("CLI error: missing plugin path")
    check text.contains("pluginhost --help")

  test "not implemented errors fail without pretending to be usage errors":
    let error = notImplementedError("plugin execution is unavailable", "synth.clap")
    let text = formatDiagnostic(error)

    check error.exitCode() == ExitFailure
    check text.contains("application error")
    check text.contains("synth.clap")
    check not text.contains("for usage")

  test "diagnostic context is omitted when empty":
    let withoutContext = formatDiagnostic(hostError(
      hsInternal, hekInternal, "unexpected failure"))
    let withContext = formatDiagnostic(hostError(
      hsInternal, hekInternal, "unexpected failure", "operation=start"))

    check not withoutContext.contains("()")
    check withContext.contains("(operation=start)")

  test "platform loader errors retain their typed subsystem and failure status":
    let error = hostError(
      hsPlatform,
      hekSymbolLookup,
      "could not resolve dynamic-library symbol",
      "path=fixture.clap; symbol=clap_entry",
    )
    let text = formatDiagnostic(error)

    check error.exitCode() == ExitFailure
    check text.contains("platform error")
    check text.contains("symbol=clap_entry")

  test "CLAP and selection errors use their dedicated statuses":
    let loadError = hostError(
      hsClap, hekClapEntryInit, "entry initialization failed", "bad.clap")
    let portsError = hostError(
      hsClap, hekClapPorts, "port inspection failed", "bad.clap")
    let renderError = hostError(
      hsClap, hekClapRender, "render mode rejected", "bad.clap")
    let selectionError = hostError(
      hsClap, hekPluginSelection, "selection required", "multi.clap")

    check loadError.exitCode() == ExitClap
    check formatDiagnostic(loadError).contains("CLAP error")
    check portsError.exitCode() == ExitClap
    check renderError.exitCode() == ExitClap
    check selectionError.exitCode() == ExitUsage
    check formatDiagnostic(selectionError).contains("pluginhost --help")

  test "diagnostic context escapes invalid text and control characters":
    let malformed = "path=bad\n\x1b\xFF.clap"
    let text = formatDiagnostic(hostError(
      hsClap, hekClapEntry, "could not load", malformed))

    check text.contains("path=bad\\u000a\\u001b�.clap")
    check not text.contains("path=bad\n")
