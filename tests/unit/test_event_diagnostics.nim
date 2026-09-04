import std/[strutils, unittest]

import pluginhost/app/host_session
import pluginhost/clap/event_bridge

suite "audio event diagnostics":
  test "warning totals do not double-count detailed drop categories":
    let message = eventMetricsWarningMessage(ClapEventMetrics(
      droppedOutput: 2'u64,
      invalidOutput: 2'u64,
    ))
    check message ==
      "audio event bridge dropped or rejected 2 events (output-invalid=2)"
    check not message.contains("4 events")

  test "warning text distinguishes overflow invalid input and JACK loss":
    let message = eventMetricsWarningMessage(ClapEventMetrics(
      droppedInput: 4'u64,
      invalidInput: 2'u64,
      malformedInput: 1'u64,
      inputCapacityDrops: 1'u64,
      jackLostInput: 3'u64,
    ))
    check message == "audio event bridge dropped or rejected 7 events " &
      "(input-overflow=1, input-invalid=2, input-malformed=1, " &
      "jack-input-lost=3)"

  test "empty metrics produce no warning":
    check eventMetricsWarningMessage(ClapEventMetrics()) == ""
