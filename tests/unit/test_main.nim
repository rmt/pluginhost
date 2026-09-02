import std/[os, osproc, streams, strutils, unittest]

type
  ProcessResult = object
    output: string
    errorOutput: string
    exitCode: int

proc runHost(args: seq[string]): ProcessResult =
  let executable = getEnv("PLUGINHOST_TEST_BIN", "build/test/pluginhost")
  doAssert executable.len > 0, "PLUGINHOST_TEST_BIN must identify the test executable"
  doAssert fileExists(executable), "test executable does not exist: " & executable

  let process = startProcess(executable, args = args, options = {})
  result.output = process.outputStream.readAll()
  result.errorOutput = process.errorStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

suite "main process":
  test "help succeeds on stdout":
    let process = runHost(@["--help"])

    check process.exitCode == 0
    check process.output.contains("Usage:\n")
    check process.output.contains("Commands:")
    check process.errorOutput.len == 0

  test "version succeeds on stdout":
    let process = runHost(@["--version"])

    check process.exitCode == 0
    check process.output.startsWith("pluginhost 0.0.10-dev\n")
    check process.errorOutput.len == 0

  test "invalid invocation uses stderr and the usage exit status":
    let process = runHost(@[])

    check process.exitCode == 2
    check process.output.len == 0
    check process.errorOutput.contains("missing command or plugin path")
    check process.errorOutput.contains("pluginhost --help")

  test "public run reports a missing CLAP library through the CLAP status":
    let process = runHost(@["fixture.clap"])

    check process.exitCode == 3
    check process.output.len == 0
    check process.errorOutput.contains("could not resolve CLAP plugin path")
    check process.errorOutput.contains("fixture.clap")

  test "deferred required GUI fails explicitly":
    let gui = runHost(@["--require-gui", "fixture.clap"])
    check gui.exitCode == 5
    check gui.errorOutput.contains("GUI hosting is not implemented")
