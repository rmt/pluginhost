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
    check process.output.startsWith("pluginhost 0.0.3-dev\n")
    check process.errorOutput.len == 0

  test "invalid invocation uses stderr and the usage exit status":
    let process = runHost(@[])

    check process.exitCode == 2
    check process.output.len == 0
    check process.errorOutput.contains("missing command or plugin path")
    check process.errorOutput.contains("pluginhost --help")

  test "valid run syntax fails explicitly until implemented":
    let process = runHost(@["fixture.clap"])

    check process.exitCode == 1
    check process.output.len == 0
    check process.errorOutput.contains("plugin execution is not implemented")
    check process.errorOutput.contains("fixture.clap")
