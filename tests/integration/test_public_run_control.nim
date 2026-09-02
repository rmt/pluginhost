import std/[os, osproc, posix, streams, strutils, unittest]

const StartupAttempts = 1_000

proc waitForPidFile(path: string; process: Process): bool =
  for attempt in 0 ..< StartupAttempts:
    if fileExists(path):
      return true
    if process.peekExitCode() != -1:
      return false
    sleep(5)
  false

suite "public reactor and signal-controlled run":
  test "PID publication, reserved GUI signals, and SIGTERM are orderly":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let executable = getEnv("PLUGINHOST_TEST_BIN")
    let fixtureDirectory = getEnv("PLUGINHOST_CLAP_AUDIO_FIXTURE_DIR")
    require executable.len > 0 and fileExists(executable)
    require fixtureDirectory.len > 0
    let fixture = fixtureDirectory / "audio_tone.clap"
    require fileExists(fixture)

    let pidPath = getTempDir() / ("pluginhost-public-" & $getpid() & ".pid")
    if fileExists(pidPath):
      removeFile(pidPath)
    let process = startProcess(executable, args = @[
      "--no-gui",
      "--no-start-server",
      "--client-name", "pluginhost-public-control",
      "--pid-file", pidPath,
      fixture,
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
    require kill(Pid(process.processID), SIGUSR1) == 0
    require kill(Pid(process.processID), SIGUSR2) == 0
    sleep(40)
    require kill(Pid(process.processID), SIGUSR1) == 0
    sleep(40)
    require kill(Pid(process.processID), SIGTERM) == 0
    let exitCode = process.waitForExit(5_000)
    let output = process.outputStream.readAll()
    let diagnostic = process.errorStream.readAll()

    check exitCode == 0
    check output.len == 0
    check diagnostic.contains("SIGUSR request to show the GUI is unavailable")
    check diagnostic.contains("SIGUSR request to hide the GUI is unavailable")
    check diagnostic.count("SIGUSR request to show the GUI is unavailable") == 1
    check not fileExists(pidPath)

  test "SIGINT requests the same clean shutdown path":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let executable = getEnv("PLUGINHOST_TEST_BIN")
    let fixture = getEnv("PLUGINHOST_CLAP_AUDIO_FIXTURE_DIR") / "audio_tone.clap"
    let pidPath = getTempDir() / ("pluginhost-interrupt-" & $getpid() & ".pid")
    if fileExists(pidPath): removeFile(pidPath)
    let process = startProcess(executable, args = @[
      "--no-gui", "--no-start-server",
      "--client-name", "pluginhost-public-interrupt",
      "--pid-file", pidPath, fixture,
    ], options = {})
    defer:
      if process.peekExitCode() == -1:
        discard kill(Pid(process.processID), SIGKILL)
        discard process.waitForExit(3_000)
      process.close()
      if fileExists(pidPath): removeFile(pidPath)
    require waitForPidFile(pidPath, process)
    require kill(Pid(process.processID), SIGINT) == 0
    check process.waitForExit(5_000) == 0
    check process.outputStream.readAll().len == 0
    check not fileExists(pidPath)

  test "SIGTERM saves requested CLAP state after audio quiescence":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let executable = getEnv("PLUGINHOST_TEST_BIN")
    let fixtureDirectory = getEnv("PLUGINHOST_CLAP_AUDIO_FIXTURE_DIR")
    let fixture = fixtureDirectory / "audio_state.clap"
    let statePath = getTempDir() / ("pluginhost-state-" & $getpid() & ".bin")
    let pidPath = getTempDir() / ("pluginhost-state-" & $getpid() & ".pid")
    if fileExists(pidPath): removeFile(pidPath)
    require executable.len > 0 and fileExists(executable) and fileExists(fixture)
    writeFile(statePath, "PHST9")
    let process = startProcess(executable, args = @[
      "--no-gui", "--no-start-server",
      "--client-name", "pluginhost-public-state", "--pid-file", pidPath,
      "--load-state", statePath, "--save-state", statePath, fixture,
    ], options = {})
    defer:
      if process.peekExitCode() == -1:
        discard kill(Pid(process.processID), SIGKILL)
        discard process.waitForExit(3_000)
      process.close()
      if fileExists(statePath): removeFile(statePath)
      if fileExists(pidPath): removeFile(pidPath)
    require waitForPidFile(pidPath, process)
    require kill(Pid(process.processID), SIGTERM) == 0
    check process.waitForExit(5_000) == 0
    check process.outputStream.readAll().len == 0
    check process.errorStream.readAll().contains("state") == false
    check readFile(statePath) == "PHST9"
