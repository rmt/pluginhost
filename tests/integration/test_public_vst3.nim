import std/[json, os, osproc, posix, streams, strutils, unittest]

import pluginhost/domain/errors
import pluginhost/vst3/[state_codec]

const
  ProcessorCid = "102132435465768798A9BACBDCEDFEFF"
  StartupAttempts = 5_000
  ProcessTimeout = 10_000
  ReferenceFrames = 64
proc requiredPath(name: string): string =
  result = getEnv(name)
  require result.len > 0 and result.isAbsolute and
    (fileExists(result) or dirExists(result))

proc requiredFile(name: string): string =
  result = getEnv(name)
  require result.len > 0 and result.isAbsolute and fileExists(result)

proc requiredDirectory(name: string): string =
  result = getEnv(name)
  require result.len > 0 and result.isAbsolute and dirExists(result)

proc fixtureRoot(): string =
  result = requiredDirectory("PLUGINHOST_VST3_PUBLIC_FIXTURE_DIR")
  require dirExists(result)


proc fixturePath(name: string): string =
  fixtureRoot() / (name & ".vst3")

proc executable(): string =
  requiredFile("PLUGINHOST_TEST_BIN")

proc waitForPidFile(path: string; process: Process): bool =
  for _ in 0 ..< StartupAttempts:
    if fileExists(path):
      return true
    if process.peekExitCode() != -1:
      return false
    sleep(5)
  false

proc removeIfPresent(path: string) =
  if fileExists(path):
    removeFile(path)

proc bytesToString(bytes: openArray[uint8]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc f64Bytes(value: float64): seq[uint8] =
  let raw = cast[uint64](value)
  result = newSeq[uint8](8)
  for index in 0 ..< 8:
    result[index] = uint8(raw shr (index * 8))

proc writeFixturePreset(path: string) =
  var serialized = serializeVst3Preset(ProcessorCid, f64Bytes(0.375),
    f64Bytes(0.8125), includeController = true)
  require serialized.isOk
  writeFile(path, bytesToString(serialized.value))

proc stopProcess(process: Process; signal: cint = SIGTERM): int =
  if process == nil:
    return -1
  if process.peekExitCode() == -1:
    discard kill(Pid(process.processID), signal)
  process.waitForExit(ProcessTimeout)

proc cleanupProcess(process: Process) =
  if process == nil:
    return
  if process.peekExitCode() == -1:
    discard kill(Pid(process.processID), SIGKILL)
    discard process.waitForExit(3_000)
  process.close()

proc runHost(args: seq[string]): tuple[exitCode: int, output: string,
    diagnostics: string] =
  let process = startProcess(executable(), args = args, options = {})
  result.output = process.outputStream().readAll()
  result.diagnostics = process.errorStream().readAll()
  result.exitCode = process.waitForExit()
  process.close()

type HostRun = object
  process: Process
  pidPath: string

proc startHost(pluginPath, pluginSelector, label: string;
               extra: openArray[string];
               selectorOption = "--plugin-id"): HostRun =
  result.pidPath = getTempDir() / ("pluginhost-vst3-public-" & label & "-" &
    $getCurrentProcessId() & ".pid")
  removeIfPresent(result.pidPath)
  var args = @[
    "--quiet", "--no-start-server", selectorOption, pluginSelector,
    "--client-name", "pluginhost-vst3-" & label,
    "--pid-file", result.pidPath,
  ]
  for option in extra:
    args.add(option)
  args.add(pluginPath)
  result.process = startProcess(executable(), args = args, options = {})
  if not waitForPidFile(result.pidPath, result.process):
    if result.process.peekExitCode() != -1:
      checkpoint result.process.errorStream().readAll()
    require false
  require readFile(result.pidPath).strip() == $result.process.processID

proc closeHost(host: var HostRun; expected = 0;
               checkOutput = true): string =
  if host.process == nil:
    return ""
  let exitCode = stopProcess(host.process)
  let output = host.process.outputStream().readAll()
  result = host.process.errorStream().readAll()
  check exitCode == expected
  if checkOutput:
    check output.len == 0
  check not fileExists(host.pidPath)
  host.process.close()
  host.process = nil
  removeIfPresent(host.pidPath)

proc readPeerLine(peer: Process): string =
  try:
    return peer.outputStream().readLine()
  except IOError:
    let exitCode = peer.waitForExit(ProcessTimeout)
    checkpoint "VST3 JACK peer exited before a response: exit=" &
      $exitCode & "; stderr=" & peer.errorStream().readAll()
    require false
    return ""

suite "public VST3 process contract":
  test "list and selection errors identify the VST3 subsystem":
    let bundle = fixturePath("mono")
    let listed = runHost(@["list", "--json", bundle])
    check listed.exitCode == 0
    check listed.output.len > 0
    check listed.diagnostics.len == 0
    let catalog = parseJson(listed.output)
    check catalog["plugins"][0]["format"].getStr() == "vst3"
    check catalog["plugins"][0]["id"].getStr() == ProcessorCid

    let unknown = runHost(@[
      "--no-gui", "--no-start-server", "--plugin-id",
      "00112233445566778899AABBCCDDEEFF", bundle,
    ])
    check unknown.exitCode == ExitUsage
    check unknown.diagnostics.contains("VST3")
    check unknown.diagnostics.contains("plugin ID was not found")
    check not unknown.diagnostics.contains("run is unavailable")

  test "public VST3 audio runs despite an unimplemented processing notification":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let peerPath = requiredFile("PLUGINHOST_VST3_JACK_PEER")
    let bundle = fixturePath("processing_notimpl")
    var host = startHost(bundle, "0", "audio", @["--no-gui"],
      selectorOption = "--plugin-index")
    var peer: Process = nil
    defer:
      if peer != nil:
        cleanupProcess(peer)
      if host.process != nil:
        discard closeHost(host)

    peer = startProcess(peerPath, args = @[
      "pluginhost-vst3-audio", $ReferenceFrames, "8"], options = {})
    let ready = peer.outputStream().readLine()
    require ready.startsWith("READY ")
    let peerInput = peer.inputStream()
    peerInput.write("QUIT\n")
    peerInput.flush()
    check peer.waitForExit(ProcessTimeout) == 0
    peer.close()
    peer = nil

    let diagnostics = closeHost(host)
    check diagnostics.len == 0

  test "public VST3 state load and save use a bounded vstpreset transaction":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let statePath = getTempDir() / ("pluginhost-vst3-public-" &
      $getCurrentProcessId() & ".vstpreset")
    removeIfPresent(statePath)
    writeFixturePreset(statePath)
    var host: HostRun
    defer:
      if host.process != nil:
        discard closeHost(host)
      removeIfPresent(statePath)

    var args = @[
      "--no-gui", "--load-state", statePath, "--save-state", statePath,
    ]
    host = startHost(fixturePath("public_reload"), ProcessorCid, "state", args)
    sleep(120)
    let peerPath = requiredFile("PLUGINHOST_VST3_JACK_PEER")
    var peer: Process = nil
    defer:
      if peer != nil:
        cleanupProcess(peer)
    peer = startProcess(peerPath, args = @[
      "pluginhost-vst3-state", $ReferenceFrames, "8", "0.375"], options = {})
    require readPeerLine(peer).startsWith("READY ")
    let peerInput = peer.inputStream()
    peerInput.write("WAIT 8\n")
    peerInput.flush()
    check readPeerLine(peer) == "WAITED"
    peerInput.write("QUIT\n")
    peerInput.flush()
    check peer.waitForExit(ProcessTimeout) == 0
    peer.close()
    peer = nil
    let diagnostics = closeHost(host)
    check diagnostics.len == 0
    require fileExists(statePath)
    let bytes = readFile(statePath)
    require bytes.len > 48
    check bytes[0 ..< 4] == "VST3"
    var raw = newSeq[uint8](bytes.len)
    for index, value in bytes:
      raw[index] = uint8(ord(value))
    let parsed = parseVst3Preset(raw, ProcessorCid)
    require parsed.isOk
    check parsed.value.component == f64Bytes(0.375)
    check parsed.value.controller == f64Bytes(0.8125)
    check parsed.value.component.len == 8
    check parsed.value.controller.len == 8

  test "independent instrument and effect paths support public process and GUI policy":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let instrument = requiredPath("PLUGINHOST_VST3_INSTRUMENT_PLUGIN")
    let instrumentId = getEnv("PLUGINHOST_VST3_INSTRUMENT_ID")
    let effect = requiredPath("PLUGINHOST_VST3_EFFECT_PLUGIN")
    let effectId = getEnv("PLUGINHOST_VST3_EFFECT_ID")
    require instrumentId.len > 0 and effectId.len > 0

    var effectHost = startHost(effect, effectId, "effect",
      @["--require-gui", "--hide-gui"])
    defer:
      if effectHost.process != nil:
        discard closeHost(effectHost, checkOutput = false)
    sleep(80)
    require kill(Pid(effectHost.process.processID), SIGUSR1) == 0
    require kill(Pid(effectHost.process.processID), SIGUSR2) == 0
    let effectDiagnostics = closeHost(effectHost, checkOutput = false)
    check effectDiagnostics == ""

    var instrumentHost = startHost(instrument, instrumentId, "instrument",
      @["--no-gui"])
    defer:
      if instrumentHost.process != nil:
        discard closeHost(instrumentHost, checkOutput = false)
    let instrumentDiagnostics = closeHost(instrumentHost, checkOutput = false)
    check instrumentDiagnostics == ""
                   