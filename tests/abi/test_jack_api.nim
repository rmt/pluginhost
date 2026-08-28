import std/[os, strutils, unittest]

import pluginhost/domain/errors
import pluginhost/jack/[api, ffi]
import ../fixtures/jack/fixture_api

proc isMapped(path: string): bool =
  let canonicalPath = absolutePath(path)
  for line in lines("/proc/self/maps"):
    if line.contains(canonicalPath):
      return true

static:
  doAssert not compiles(block:
    var original: JackApi
    var duplicate = `=dup`(original)
    discard duplicate.isOpen
  )

suite "checked JACK dynamic API ownership":
  test "a missing JACK library returns a typed JACK status":
    let missingPath = jackPartialFixturePath() & ".missing"
    let opened = openJackApi(missingPath)

    check not opened.isOk
    check opened.error.subsystem == hsJack
    check opened.error.kind == hekJackLibraryOpen
    check opened.error.exitCode() == ExitJack
    check opened.error.context.contains(missingPath)

  test "a partially resolved table is rolled back on a missing symbol":
    let path = jackPartialFixturePath()
    check not isMapped(path)

    let opened = openJackApi(path)

    check not opened.isOk
    check opened.error.subsystem == hsJack
    check opened.error.kind == hekJackSymbol
    check opened.error.exitCode() == ExitJack
    check opened.error.context.contains("jack_get_version_string")
    check not isMapped(path)

  test "the complete runtime table calls libjack without opening a client":
    var opened = openJackApi()
    require opened.isOk
    var api = move(opened.value)
    defer:
      doAssert api.close().isOk

    check api.isOpen
    check api.libraryPath == JackLibrary
    check api.functions.getVersion != nil
    check api.functions.getVersionString != nil
    check api.functions.setXrunCallback != nil
    check api.functions.setFreewheelCallback != nil
    check api.functions.midiEventWrite != nil

    var major, minor, micro, protocol: cint
    api.functions.getVersion(addr major, addr minor, addr micro, addr protocol)
    let versionText = api.functions.getVersionString()

    check major >= 0
    check minor >= 0
    check micro >= 0
    check protocol >= 0
    check versionText != nil
    check ($versionText).strip().len > 0

    check api.close().isOk
    check not api.isOpen
    check api.functions.getVersion == nil
    check api.close().isOk
