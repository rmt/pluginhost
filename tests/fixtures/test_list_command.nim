import std/[json, os, osproc, streams, strutils, unittest]

import ./clap/fixture_api

type ProcessResult = object
  output: string
  errorOutput: string
  exitCode: int

proc runHost(args: seq[string]): ProcessResult =
  let executable = getEnv("PLUGINHOST_TEST_BIN")
  doAssert executable.len > 0,
    "PLUGINHOST_TEST_BIN must identify the test executable"
  doAssert fileExists(executable),
    "test executable does not exist: " & executable

  let process = startProcess(executable, args = args, options = {})
  result.output = process.outputStream.readAll()
  result.errorOutput = process.errorStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

suite "list command process behavior":
  test "human listing reports both descriptors without diagnostics":
    let process = runHost(@["list", clapFixturePath("valid")])

    check process.exitCode == 0
    check process.output.contains("[0] Fixture Synth")
    check process.output.contains("ID: org.pluginhost.fixture.synth")
    check process.output.contains("[1] Fixture Effect")
    check process.output.contains("Features: audio-effect")
    check process.errorOutput.len == 0

  test "JSON listing emits exactly one valid data document":
    let process = runHost(@[
      "list", "--json", clapFixturePath("valid")])

    check process.exitCode == 0
    check process.errorOutput.len == 0
    let parsed = parseJson(process.output)
    check parsed.len == 2
    check parsed["path"].getStr() == expandFilename(clapFixturePath("valid"))
    check parsed["plugins"].len == 2
    check parsed["plugins"][1]["id"].getStr() ==
      "org.pluginhost.fixture.effect"

  test "list failure keeps stdout clean and uses the CLAP exit status":
    let process = runHost(@[
      "list", "--json", clapFixturePath("blank_id")])

    check process.exitCode == 3
    check process.output.len == 0
    check process.errorOutput.startsWith("pluginhost: CLAP error:")
    check process.errorOutput.contains("blank_id.clap")
