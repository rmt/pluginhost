import std/[os, osproc, posix, streams, strutils, unittest]

const
  StartupAttempts = 5_000
  ProcessTimeout = 10_000
  JackExitCode = 4
  FixtureDirectoryEnvironment = "PLUGINHOST_CLAP_FIXTURE_DIR"

proc waitForPidFile(path: string; process: Process): bool =
  for attempt in 0 ..< StartupAttempts:
    if fileExists(path):
      return true
    if process.peekExitCode() != -1:
      return false
    sleep(5)
  false

proc fixturePath(): string =
  let directory = getEnv(FixtureDirectoryEnvironment)
  require directory.len > 0
  result = directory / "audio_tone.clap"
  require fileExists(result)

suite "11C JACK loss":
  test "PipeWire shutdown reports JACK failure and cleans the PID file":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let executable = getEnv("PLUGINHOST_TEST_BIN")
    require executable.len > 0 and fileExists(executable)
    let serverValue = getEnv("PLUGINHOST_PIPEWIRE_PID")
    require serverValue.len > 0
    let serverPid = parseInt(serverValue)
    require serverPid > 0

    let pidPath = getTempDir() / ("pluginhost-jack-loss-" & $getpid() & ".pid")
    if fileExists(pidPath):
      removeFile(pidPath)
    let process = startProcess(executable, args = @[
      "--quiet",
      "--no-gui",
      "--no-start-server",
      "--client-name", "pluginhost-11c-jack-loss",
      "--pid-file", pidPath,
      fixturePath(),
    ], options = {})
    defer:
      if process.peekExitCode() == -1:
        discard kill(Pid(process.processID), SIGKILL)
        discard process.waitForExit(3_000)
      process.close()
      if fileExists(pidPath):
        removeFile(pidPath)

    require waitForPidFile(pidPath, process)
    check readFile(pidPath).strip() == $process.processID
    require kill(Pid(serverPid), SIGTERM) == 0

    let exitCode = process.waitForExit(ProcessTimeout)
    let output = process.outputStream.readAll()
    let diagnostic = process.errorStream.readAll()
    check exitCode == JackExitCode
    check output.len == 0
    check diagnostic.contains("JACK server shut down the host client")
    check not fileExists(pidPath)
    echo "11C JACK loss exit=", exitCode,
      " stdout-bytes=", output.len,
      " stderr-bytes=", diagnostic.len
