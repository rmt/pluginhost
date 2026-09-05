import std/[os, strutils, unittest]

import pluginhost/clap/ffi
import pluginhost/domain/errors
import pluginhost/platform/linux/dynlib
import ../fixtures/ffi/fixture_api

proc isMapped(path: string): bool =
  let canonicalPath = absolutePath(path)
  for line in lines("/proc/self/maps"):
    if line.contains(canonicalPath):
      return true

static:
  doAssert not compiles(block:
    var original: DynamicLibrary
    var duplicate = `=dup`(original)
    discard duplicate.isOpen
  )
  doAssert not compiles(block:
    var library: DynamicLibrary
    discard resolveSymbol[uint64](library, "not-a-pointer")
  )

suite "checked Linux dynamic-library ownership":
  test "opening a missing library returns a typed platform error":
    let missingPath = fixturePath() & ".missing"
    let opened = openDynamicLibrary(missingPath)

    check not opened.isOk
    check opened.error.subsystem == hsPlatform
    check opened.error.kind == hekLibraryOpen
    check opened.error.context.contains(missingPath)

  test "function and CLAP entry data symbols resolve with their exact types":
    let path = fixturePath()
    var opened = openDynamicLibrary(path)
    require opened.isOk
    var library = move(opened.value)
    defer:
      doAssert library.close().isOk

    check library.isOpen
    check library.libraryPath == path

    let emptySymbol = library.resolveAddress("")
    check not emptySymbol.isOk
    check emptySymbol.error.kind == hekSymbolLookup

    let addResult = resolveSymbol[FixtureAddProc](library,
      "pluginhost_fixture_add")
    require addResult.isOk
    check addResult.value(20, 22) == 42

    let entryResult = resolveSymbol[ptr ClapPluginEntry](library, "clap_entry")
    require entryResult.isOk
    let entry = entryResult.value
    check entry != nil
    check entry.clapVersion == ClapVersionCurrent
    check entry.init != nil
    check entry.deinit != nil
    check entry.getFactory != nil
    check entry.init(path.cstring)
    entry.deinit()

    check library.close().isOk
    check not library.isOpen
    check library.close().isOk
    check not library.isOpen

  test "missing symbols are typed and explicit rollback unloads partial state":
    let path = fixturePath()
    check not isMapped(path)

    var opened = openDynamicLibrary(path)
    require opened.isOk
    var library = move(opened.value)
    defer:
      doAssert library.close().isOk
    check isMapped(path)

    let missing = library.resolveAddress("pluginhost_fixture_missing")
    check not missing.isOk
    check missing.error.subsystem == hsPlatform
    check missing.error.kind == hekSymbolLookup
    check missing.error.context.contains("pluginhost_fixture_missing")

    check library.close().isOk
    check library.close().isOk
    check not library.isOpen
    check not isMapped(path)

  test "a retained library stays mapped after explicit close":
    let path = getTempDir() / "pluginhost-retained-dynlib.so"
    if fileExists(path):
      removeFile(path)
    copyFile(fixturePath(), path)
    defer:
      if fileExists(path):
        removeFile(path)

    check not isMapped(path)
    var opened = openDynamicLibrary(path, keepLoaded = true)
    require opened.isOk
    var library = move(opened.value)
    check isMapped(path)
    check library.close().isOk
    check not library.isOpen
    check isMapped(path)

  test "a closed owner rejects lookup without touching the loader":
    var library: DynamicLibrary
    let missing = library.resolveAddress("clap_entry")

    check not missing.isOk
    check missing.error.kind == hekSymbolLookup
    check missing.error.context.contains("library is closed")
