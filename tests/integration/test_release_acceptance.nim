import std/[os, osproc, posix, streams, strutils, unittest]

const
  ReferenceFrames = 64'u32
  AcceptanceCycles = 96'u64
  StartupAttempts = 5_000
  ProcessTimeout = 10_000

type
  ReleaseObservation = object
    mode: string
    pluginPath: string
    pluginId: string
    audioInputs: uint64
    audioOutputs: uint64
    midiInputs: uint64
    midiOutputs: uint64
    outputSamples: uint64
    nonzeroSamples: uint64
    changedSamples: uint64
    channelErrors: uint64
    errors: uint64
    hostExitCode: int
    hostDiagnostic: string

proc requiredFile*(name: string): string =
  result = getEnv(name)
  require result.len > 0
  require result.isAbsolute
  require fileExists(result)

proc requiredDirectory*(name: string): string =
  result = getEnv(name)
  require result.len > 0
  require result.isAbsolute
  require dirExists(result)

proc waitForPidFile(path: string; process: Process): bool =
  for attempt in 0 ..< StartupAttempts:
    if fileExists(path):
      return true
    if process.peekExitCode() != -1:
      return false
    sleep(5)
  false

proc readPeerLine(peer: Process; context: string): string =
  try:
    return peer.outputStream().readLine()
  except CatchableError as error:
    var diagnostic = ""
    try:
      diagnostic = peer.errorStream().readAll()
    except CatchableError:
      discard
    checkpoint(context & "; exception=" & error.msg & "; stderr=" & diagnostic)
    ""

proc peerCommand(peer: Process; command: string): string =
  try:
    let input = peer.inputStream()
    input.write(command & "\n")
    input.flush()
    readPeerLine(peer, "release peer command " & command)
  except CatchableError as error:
    checkpoint("release peer write " & command & "; exception=" & error.msg)
    ""

proc quitPeer(peer: Process): bool =
  try:
    let input = peer.inputStream()
    input.write("QUIT\n")
    input.flush()
    true
  except CatchableError as error:
    checkpoint("release peer quit write; exception=" & error.msg)
    false


proc emergencyCleanup(process: Process) =
  if process == nil:
    return
  try:
    if process.running:
      discard kill(Pid(process.processID), SIGKILL)
      discard process.waitForExit(3_000)
  except CatchableError:
    discard
  try:
    process.close()
  except CatchableError:
    discard

proc fieldValue(line, field: string): uint64 =
  let prefix = field & "="
  for token in line.splitWhitespace:
    if token.startsWith(prefix):
      return parseUInt(token[prefix.len .. ^1])
  raise newException(ValueError, "missing field " & field & " in: " & line)

proc removeIfPresent(path: string) =
  if fileExists(path):
    removeFile(path)

proc runPublicPlugin(mode, pluginPath, pluginId, clientName,
                     label: string): ReleaseObservation =
  let executable = requiredFile("PLUGINHOST_TEST_BIN")
  let peerPath = requiredFile("PLUGINHOST_RELEASE_PEER")
  let pidPath = getTempDir() / ("pluginhost-11c-" & label & "-" &
    $getCurrentProcessId() & ".pid")
  removeIfPresent(pidPath)
  let hostArgs = @[
    "--quiet",
    "--no-gui",
    "--no-start-server",
    "--plugin-id", pluginId,
    "--client-name", clientName,
    "--pid-file", pidPath,
    pluginPath,
  ]

  var host: Process = nil
  var peer: Process = nil
  var hostNeedsCleanup = true
  var peerNeedsCleanup = true
  defer:
    if peerNeedsCleanup:
      emergencyCleanup(peer)
    if hostNeedsCleanup:
      emergencyCleanup(host)
    removeIfPresent(pidPath)

  host = startProcess(executable, args = hostArgs, options = {})
  require waitForPidFile(pidPath, host)
  check readFile(pidPath).strip() == $host.processID

  peer = startProcess(peerPath, args = @[mode, clientName, $ReferenceFrames],
    options = {})
  var ready = readPeerLine(peer, "release peer READY")
  if not ready.startsWith("READY "):
    discard peer.waitForExit(2_000)
    checkpoint("release peer stdout=" & ready & "; stderr=" &
      peer.errorStream().readAll())
  require ready.startsWith("READY ")

  result.mode = mode
  result.pluginPath = pluginPath
  result.pluginId = pluginId
  result.audioInputs = fieldValue(ready, "audio-inputs")
  result.audioOutputs = fieldValue(ready, "audio-outputs")
  result.midiInputs = fieldValue(ready, "midi-inputs")
  result.midiOutputs = fieldValue(ready, "midi-outputs")

  let ran = peer.peerCommand("RUN " & $AcceptanceCycles)
  result.outputSamples = fieldValue(ran, "outputs")
  result.nonzeroSamples = fieldValue(ran, "nonzero")
  result.changedSamples = fieldValue(ran, "changed")
  result.channelErrors = fieldValue(ran, "channel-errors")
  result.errors = fieldValue(ran, "errors")

  require kill(Pid(host.processID), SIGTERM) == 0
  result.hostExitCode = host.waitForExit(ProcessTimeout)
  let hostOutput = host.outputStream().readAll()
  result.hostDiagnostic = host.errorStream().readAll()
  host.close()
  hostNeedsCleanup = false

  check result.hostExitCode == 0
  check hostOutput.len == 0
  check not fileExists(pidPath)

  require peer.peerCommand("ABSENT") == "ABSENT"
  require quitPeer(peer)
  require peer.waitForExit(ProcessTimeout) == 0
  peer.close()
  peerNeedsCleanup = false

  echo "11C release run mode=", mode, " plugin=", pluginId,
    " audio-inputs=", result.audioInputs,
    " audio-outputs=", result.audioOutputs,
    " midi-inputs=", result.midiInputs,
    " midi-outputs=", result.midiOutputs,
    " outputs=", result.outputSamples,
    " nonzero=", result.nonzeroSamples,
    " changed=", result.changedSamples,
    " channel-errors=", result.channelErrors,
    " errors=", result.errors

proc instrumentPluginPath(): string =
  requiredFile("PLUGINHOST_RELEASE_INSTRUMENT_PLUGIN")

proc instrumentPluginId(): string =
  result = getEnv("PLUGINHOST_RELEASE_INSTRUMENT_ID")
  require result.len > 0

proc secondInstrumentPluginPath(): string =
  requiredFile("PLUGINHOST_RELEASE_SECOND_INSTRUMENT_PLUGIN")

proc secondInstrumentPluginId(): string =
  result = getEnv("PLUGINHOST_RELEASE_SECOND_INSTRUMENT_ID")
  require result.len > 0

proc effectPluginPath(): string =
  requiredFile("PLUGINHOST_RELEASE_EFFECT_PLUGIN")

proc effectPluginId(): string =
  result = getEnv("PLUGINHOST_RELEASE_EFFECT_ID")
  require result.len > 0

proc compatibilityPluginPath(): string =
  requiredFile("PLUGINHOST_RELEASE_COMPATIBILITY_PLUGIN")

proc compatibilityPluginId(): string =
  result = getEnv("PLUGINHOST_RELEASE_COMPATIBILITY_ID")
  require result.len > 0

suite "11C public acceptance and compatibility":
  test "synth receives MIDI and produces audio on every output":
    let observation = runPublicPlugin(
      "synth", instrumentPluginPath(), instrumentPluginId(),
      "pluginhost-11c-synth", "synth")
    check observation.audioOutputs > 0
    check observation.midiInputs > 0
    check observation.outputSamples > 0
    check observation.nonzeroSamples > 0
    check observation.channelErrors == 0
    check observation.errors == 0

  test "stereo effect processes generated stereo audio":
    let observation = runPublicPlugin(
      "effect", effectPluginPath(), effectPluginId(),
      "pluginhost-11c-effect", "effect")
    check observation.audioInputs >= 2
    check observation.audioOutputs >= 2
    check observation.outputSamples >= AcceptanceCycles *
      ReferenceFrames * 2'u64
    check observation.nonzeroSamples > 0
    check observation.changedSamples > 0
    check observation.channelErrors == 0
    check observation.errors == 0

  test "public process realizes grouped audio and note ports":
    let fixtureDirectory = requiredDirectory("PLUGINHOST_CLAP_FIXTURE_DIR")
    let observation = runPublicPlugin(
      "ports", fixtureDirectory / "ports_valid.clap",
      "org.pluginhost.fixture.ports", "pluginhost-11c-ports", "ports")
    check observation.audioInputs == 3
    check observation.audioOutputs == 5
    check observation.midiInputs == 2
    check observation.midiOutputs == 1
    check observation.errors == 0

  test "three independent Linux CLAP implementations remain compatible":
    let first = runPublicPlugin(
      "synth", instrumentPluginPath(), instrumentPluginId(),
      "pluginhost-11c-compat-vital", "compat-vital")
    let second = runPublicPlugin(
      "synth", secondInstrumentPluginPath(), secondInstrumentPluginId(),
      "pluginhost-11c-compat-second", "compat-second")
    let effect = runPublicPlugin(
      "effect", compatibilityPluginPath(), compatibilityPluginId(),
      "pluginhost-11c-compat-effect", "compat-effect")

    check first.audioOutputs > 0
    check first.outputSamples > 0
    check first.nonzeroSamples > 0
    check first.errors == 0
    check second.audioOutputs > 0
    check second.outputSamples > 0
    check second.nonzeroSamples > 0
    check second.errors == 0
    check effect.audioInputs > 0
    check effect.audioOutputs > 0
    check effect.outputSamples > 0
    check effect.nonzeroSamples > 0
    check effect.errors == 0
