import std/[algorithm, json, os, osproc, streams, strutils, unittest]

import pluginhost/discovery/scanner
import pluginhost/domain/[errors, plugin_catalog]
import pluginhost/platform/linux/dynlib
import pluginhost/vst3/[catalog, uid]

proc fixtureDirectory(): string =
  result = getEnv("PLUGINHOST_VST3_FIXTURE_DIR")
  doAssert result.len > 0,
    "PLUGINHOST_VST3_FIXTURE_DIR must identify the compiled fixture directory"

proc fixturePath(name: string): string =
  fixtureDirectory() / (name & ".vst3")

proc removeTree(path: string) =
  if not dirExists(path):
    return
  var entries: seq[string]
  for child in walkDirRec(path,
      yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir},
      followFilter = {pcDir}):
    entries.add(child)
  entries.sort(proc(left, right: string): int = cmp(right.len, left.len))
  for child in entries:
    let kind = getFileInfo(child, followSymlink = false).kind
    if kind == pcDir:
      removeDir(child)
    else:
      removeFile(child)
  removeDir(path)

type ProcessResult = object
  output: string
  errorOutput: string
  exitCode: int

proc runHost(args: seq[string]): ProcessResult =
  let executable = getEnv("PLUGINHOST_TEST_BIN")
  doAssert executable.len > 0,
    "PLUGINHOST_TEST_BIN must identify the test executable"
  let process = startProcess(executable, args = args, options = {})
  result.output = process.outputStream.readAll()
  result.errorOutput = process.errorStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

suite "VST3 catalog and discovery boundary":
  test "catalog filters controller classes and preserves native indices":
    let path = fixturePath("multi_class")
    let binary = path / "Contents" / "x86_64-linux" / "multi_class.so"
    var observerResult = openDynamicLibrary(binary, keepLoaded = true)
    require observerResult.isOk
    var observer = move(observerResult.value)
    let createCalls = resolveSymbol[proc(): uint32 {.cdecl, raises: [].}](
      observer, "pluginhost_vst3_fixture_create_calls")
    require createCalls.isOk
    check createCalls.value() == 0

    let loaded = loadVst3Catalog(path)
    require loaded.isOk
    let catalog = loaded.value

    check catalog.descriptors.len == 2
    check catalog.descriptors[0].format == pfVst3
    check catalog.descriptors[0].index == 0
    check catalog.descriptors[0].nativeIndex == 0
    check catalog.descriptors[0].name == "Fixture Effect One"
    check catalog.descriptors[0].features == @["Fx", "Instrument"]
    check catalog.descriptors[1].index == 1
    check catalog.descriptors[1].nativeIndex == 2
    check catalog.descriptors[1].id ==
      "102132435465768798A9BACBDCEDFE0F"
    check createCalls.value() == 0
    check observer.close().isOk

  test "controller-only bundles remain valid empty catalogs":
    let loaded = loadVst3Catalog(fixturePath("controller_only"))
    require loaded.isOk
    check loaded.value.descriptors.len == 0

  test "duplicate processor CIDs fail before a catalog is returned":
    let loaded = loadVst3Catalog(fixturePath("duplicate_cid"))
    check not loaded.isOk
    check loaded.error.subsystem == hsVst3
    check loaded.error.kind == hekVst3Descriptor

  test "Unicode factory and class metadata is copied":
    let loaded = loadVst3Catalog(fixturePath("unicode_metadata"))
    require loaded.isOk
    check loaded.value.descriptors.len == 1
    check loaded.value.descriptors[0].name == "Sün"
    check loaded.value.descriptors[0].vendor == "Vändor ✓"
    check loaded.value.descriptors[0].version == "2.0-ü"

  test "base factory metadata remains available after V3/V2 fallback":
    let loaded = loadVst3Catalog(fixturePath("base_only"))
    require loaded.isOk
    check loaded.value.descriptors.len == 1
    check loaded.value.descriptors[0].vendor == "pluginhost VST3 fixture"
    check loaded.value.descriptors[0].features.len == 0

  test "malformed UTF-16 metadata and textual CIDs are rejected":
    let unicode = loadVst3Catalog(fixturePath("malformed_unicode"))
    check not unicode.isOk
    check unicode.error.kind == hekVst3Descriptor

    let malformed = parseVst3Uid("00112233445566778899AABBCCDDEEFG")
    check not malformed.isOk
    check malformed.error.kind == hekVst3Descriptor

  test "scan treats VST3 bundles as terminal candidates and gives first CID precedence":
    let root = getTempDir() / ("pluginhost-vst3-scan-" & $getCurrentProcessId())
    if dirExists(root):
      removeTree(root)
    createDir(root)
    defer: removeTree(root)
    createDir(root / "a")
    createDir(root / "b")
    copyDir(fixturePath("multi_class"), root / "a" / "multi_class.vst3")
    copyDir(fixturePath("multi_class"), root / "b" / "multi_class.vst3")
    createDir(root / "nested")
    createSymlink(absolutePath(root), root / "nested" / "loop")
    writeFile(root / "nested" / "flat.vst3", "not a bundle")
    createSymlink(absolutePath(root), root / "alias")

    let report = scanPlugins(@[root])

    check report.issues.len == 0
    check report.plugins.len == 2
    check report.plugins[0].descriptor.id != report.plugins[1].descriptor.id
    check report.plugins[0].descriptor.format == pfVst3
    check report.plugins[0].path.endsWith("a/multi_class.vst3")
  test "list and scan render mixed-format fields and VST3 run is unavailable":
    let list = runHost(@["list", "--json", fixturePath("valid")])
    check list.exitCode == 0
    check list.errorOutput.len == 0
    let listed = parseJson(list.output)
    check listed["plugins"][0]["format"].getStr() == "vst3"
    let conflict = runHost(@[
      "--plugin-id", "00112233445566778899AABBCCDDEEFF",
      "--plugin-index", "0", fixturePath("valid")])
    check conflict.exitCode == ExitUsage
    check conflict.errorOutput.contains("mutually exclusive")

    let root = getTempDir() / ("pluginhost-vst3-cli-" & $getCurrentProcessId())
    if dirExists(root):
      removeTree(root)
    createDir(root)
    defer: removeTree(root)
    copyDir(fixturePath("valid"), root / "valid.vst3")
    let scan = runHost(@["scan", "--json", root])
    check scan.exitCode == 0
    check scan.errorOutput.len == 0
    check parseJson(scan.output)["plugins"][0]["format"].getStr() == "vst3"

    let run = runHost(@[fixturePath("valid")])
    check run.exitCode == ExitClap
    check run.output.len == 0
    check run.errorOutput.contains("VST3 run is unavailable")
