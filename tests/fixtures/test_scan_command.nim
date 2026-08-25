import std/[algorithm, json, os, osproc, paths, streams, strutils, symlinks,
  unittest]

import pluginhost/discovery/scanner
import pluginhost/domain/errors

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

proc removeScanTree(path: string) =
  if not dirExists(path):
    return
  var entries: seq[string]
  for child in walkDirRec(path,
      yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir},
      followFilter = {pcDir}):
    entries.add(child)
  entries.sort(proc(left, right: string): int =
    cmp(right.len, left.len))
  for child in entries:
    if getFileInfo(child, followSymlink = false).kind == pcDir:
      removeDir(child)
    else:
      removeFile(child)
  removeDir(path)

proc scanFixtureRoot(): string =
  result = getTempDir() / ("pluginhost-scan-" & $getCurrentProcessId())
  if dirExists(result):
    removeScanTree(result)
  createDir(result)
  createDir(result / "nested")
  copyFile(clapFixturePath("valid"), result / "00-valid.clap")
  copyFile(clapFixturePath("blank_id"), result / "10-bad.clap")
  copyFile(clapFixturePath("exact_limits"), result / "nested" / "20-exact.clap")
  createSymlink(Path(absolutePath(result / "00-valid.clap")),
    Path(result / "05-link.clap"))
  createSymlink(Path(absolutePath(result)), Path(result / "nested" / "loop"))

suite "CLAP discovery and scan behavior":
  test "scan is recursive, lexical, canonicalized, and failure-isolated":
    let root = scanFixtureRoot()
    let alias = root & "-alias"
    createSymlink(Path(absolutePath(root)), Path(alias))
    defer: removeScanTree(root)
    defer: removeFile(alias)

    let report = scanPlugins(@[root, alias], clapPath = "")

    check report.plugins.len == 3
    check report.issues.len == 1
    check report.plugins[0].path == expandFilename(root / "00-valid.clap")
    check report.plugins[0].descriptor.id ==
      "org.pluginhost.fixture.synth"
    check report.plugins[1].descriptor.id ==
      "org.pluginhost.fixture.effect"
    check report.plugins[2].path ==
      expandFilename(root / "nested" / "20-exact.clap")
    check report.issues[0].path.endsWith("10-bad.clap")

  test "explicit missing roots report but do not block later roots":
    let root = scanFixtureRoot()
    defer: removeScanTree(root)
    let missing = root / "missing"

    let report = scanPlugins(@[missing, missing, root], clapPath = "")

    check report.plugins.len == 3
    check report.issues.len == 2
    check report.issues[0].path == missing
    check report.issues[0].error.kind == hekDiscoveryRoot
    check report.issues[1].path.endsWith("10-bad.clap")

  test "human scan reports successes while diagnostics stay on stderr":
    let root = scanFixtureRoot()
    defer: removeScanTree(root)

    let process = runHost(@["scan", root])

    check process.exitCode == 3
    check process.output.contains("Path: ")
    check process.output.contains("Fixture Synth")
    check not process.output.contains("error:")
    check process.errorOutput.contains("10-bad.clap")

  test "JSON scan keeps stdout valid while reporting partial failure on stderr":
    let root = scanFixtureRoot()
    defer: removeScanTree(root)

    let process = runHost(@["scan", "--json", root])

    check process.exitCode == 3
    check process.errorOutput.contains("10-bad.clap")
    let parsed = parseJson(process.output)
    check parsed.kind == JObject
    check parsed.len == 1
    check parsed["plugins"].len == 3
    check parsed["plugins"][0]["path"].getStr() ==
      expandFilename(root / "00-valid.clap")
    check not process.output.contains("error:")

  test "successful JSON scan has no diagnostics and no duplicate symlink":
    let root = getTempDir() / ("pluginhost-scan-success-" &
      $getCurrentProcessId())
    if dirExists(root):
      removeScanTree(root)
    createDir(root)
    defer: removeScanTree(root)
    copyFile(clapFixturePath("valid"), root / "valid.clap")
    createSymlink(Path(absolutePath(root / "valid.clap")),
      Path(root / "alias.clap"))

    let process = runHost(@["scan", "--json", root])

    check process.exitCode == 0
    check process.errorOutput.len == 0
    let parsed = parseJson(process.output)
    check parsed["plugins"].len == 2

  test "scan never creates a plugin instance":
    let root = getTempDir() / ("pluginhost-scan-guard-" &
      $getCurrentProcessId())
    if dirExists(root):
      removeScanTree(root)
    createDir(root)
    defer: removeScanTree(root)
    copyFile(clapFixturePath("create_guard"), root / "guard.clap")

    let process = runHost(@["scan", "--json", root])

    check process.exitCode == 0
    check process.errorOutput.len == 0
    check parseJson(process.output)["plugins"].len == 1
