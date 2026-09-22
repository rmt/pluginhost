import std/[os, osproc, streams, strutils, unittest]

import pluginhost/app/[vst3_audio_slice, vst3_plugin_services]
import pluginhost/jack/backend
import pluginhost/domain/result
import pluginhost/vst3/[host_context, module, uid]

const V3ClassId = "102132435465768798A9BACBDCEDFEFF"

proc fixturePath(): string =
  let root = getEnv("PLUGINHOST_VST3_V3_FIXTURE_DIR")
  doAssert root.len > 0
  let name = getEnv("PLUGINHOST_VST3_V3_FIXTURE_NAME", "midi_multi")
  root / (name & ".vst3")

proc peerCommand(peer: Process; command: string): string =
  let input = peer.inputStream()
  input.write(command & "\n")
  input.flush()
  peer.outputStream().readLine()

proc closePeer(peer: Process) =
  if peer == nil: return
  try:
    if peer.running:
      peer.terminate()
      discard peer.waitForExit(2_000)
  except CatchableError:
    discard
  try:
    peer.close()
  except CatchableError:
    discard
suite "isolated live VST3 JACK MIDI":
  test "private peer observes MIDI bytes and host teardown":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let peerPath = getEnv("PLUGINHOST_VST3_MIDI_PEER")
    require peerPath.len > 0
    require fileExists(peerPath)
    var classIdResult = parseVst3Uid(V3ClassId)
    require classIdResult.isOk
    var loaded = openVst3Module(fixturePath())
    require loaded.isOk
    var module = move(loaded.value)
    let services = newVst3PluginServices(newVst3HostContext())
    var servicesOpen = true
    defer:
      if servicesOpen:
        discard services.close()
    var sliceResult = openVst3AudioSlice(services, module, classIdResult.value,
      initJackBackendOpenConfig("pluginhost-vst3-live", noStartServer = true))
    require sliceResult.isOk
    var slice = move(sliceResult.value)
    var peer = startProcess(peerPath, args = @[
      slice.jackBackend.actualClientName,
      $slice.jackBackend.bufferSize,
      "8",
    ])
    var peerOwned = true
    defer:
      if peerOwned: closePeer(peer)
    let ready = peer.outputStream().readLine()
    require ready == "READY"
    require slice.jackBackend.notifications().processErrors == 0
    require peerCommand(peer, "WAIT 8").startsWith("WAITED")
    require slice.jackBackend.notifications().processErrors == 0
    require slice.close().isOk
    require peerCommand(peer, "QUIT") == ""
    require peer.waitForExit(2_000) == 0
    peer.close()
    peerOwned = false
    require services.close().isOk
    servicesOpen = false
