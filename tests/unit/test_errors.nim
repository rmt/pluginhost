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

  test "JACK errors use the dedicated subsystem and exit status":
    let error = hostError(
      hsJack, hekJackSymbol, "required JACK symbol is unavailable",
      "library=libjack.so.0; symbol=jack_activate",
    )
    let text = formatDiagnostic(error)

    check error.exitCode() == ExitJack
    check text.contains("JACK error")
    check text.contains("symbol=jack_activate")

  test "diagnostic context escapes invalid text and control characters":
    let malformed = "path=bad\n\x1b\xFF.clap"
    let text = formatDiagnostic(hostError(
      hsClap, hekClapEntry, "could not load", malformed))

    check text.contains("path=bad\\u000a\\u001b�.clap")
    check not text.contains("path=bad\n")

  test "public failure classes retain stable exit statuses":
    check hostError(hsGui, hekGui, "GUI unavailable").exitCode() == ExitGui
    check hostError(hsState, hekState, "state unavailable").exitCode() ==
      ExitState
    check hostError(hsPlatform, hekReactor, "reactor unavailable").exitCode() ==
      ExitFailure

  test "warning limiter emits immediately then reports suppressed count":
    var limiter = initWarningLimiter(100)
    let first = limiter.reportWarning(
      wkXruns, 0, "JACK reported 1 new xruns")
    let suppressed = limiter.reportWarning(
      wkXruns, 99, "JACK reported 2 new xruns")
    let recovered = limiter.reportWarning(
      wkXruns, 100, "JACK reported 3 new xruns")

    check first.emitted
    check first.message == "JACK reported 1 new xruns"
    check first.suppressed == 0
    check not suppressed.emitted
    check recovered.emitted
    check recovered.message == "JACK reported 3 new xruns"
    check recovered.suppressed == 1

  test "warning limiter shutdown flush is one-shot and preserves category":
    var limiter = initWarningLimiter(100)
    discard limiter.reportWarning(
      wkParameterDrops, 0, "CLAP parameter transport dropped or rejected 1 events")
    discard limiter.reportWarning(
      wkParameterDrops, 50, "CLAP parameter transport dropped or rejected 2 events")

    let flushed = limiter.flushWarnings()
    check flushed.len == 1
    check flushed[0].kind == wkParameterDrops
    check flushed[0].message.contains("suppressed=1")
    check flushed[0].message.contains("parameter")
    check limiter.flushWarnings().len == 0

  test "diagnostic messages escape control text":
    let text = formatDiagnostic(hostError(
      hsClap, hekClapPlugin, "bad\nmessage\x1b\xFF"))

    check text.contains("bad\\u000amessage\\u001b�")
    check not text.contains("bad\nmessage")

  test "zero warning interval permits every report":
    var limiter = initWarningLimiter(0)
    check limiter.reportWarning(wkXruns, 0, "first").emitted
    check limiter.reportWarning(wkXruns, 0, "second").emitted
