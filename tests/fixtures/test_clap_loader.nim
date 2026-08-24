import std/[os, strutils, unittest]

import pluginhost/clap/loader
import pluginhost/domain/errors
import pluginhost/platform/linux/dynlib
import ./clap/fixture_api

static:
  doAssert not compiles(block:
    var original: ClapModule
    var duplicate = `=dup`(original)
    discard duplicate.isOpen
  )

suite "CLAP module ownership":
  test "a successful entry receives the canonical path and matched cleanup":
    let fixturePath = clapFixturePath("valid")
    var observerResult = openDynamicLibrary(fixturePath)
    require observerResult.isOk
    var observer = move(observerResult.value)
    defer:
      doAssert observer.close().isOk
    let api = fixtureApi(observer)
    api.reset()

    let relativeFixturePath = relativePath(fixturePath, getCurrentDir())
    var opened = openClapModule(relativeFixturePath)
    require opened.isOk
    var module = move(opened.value)
    defer:
      doAssert module.close().isOk

    check module.isOpen
    check module.isEntryInitialized
    check module.modulePath == expandFilename(fixturePath)
    check api.initCalls() == 1
    check api.successfulInits() == 1
    check $api.lastInitPath() == expandFilename(fixturePath)
    check api.deinitCalls() == 0
    check api.createCalls() == 0

    check module.close().isOk
    check module.close().isOk
    check not module.isOpen
    check not module.isEntryInitialized
    check api.deinitCalls() == 1
    check api.createCalls() == 0

  test "path and entry failures are typed without unmatched deinit":
    let missing = openClapModule(clapFixturePath("missing"))
    let noEntry = openClapModule(clapFixturePath("no_entry"))

    check not missing.isOk
    check missing.error.kind == hekClapPath
    check missing.error.exitCode() == ExitClap
    check not noEntry.isOk
    check noEntry.error.kind == hekClapEntry
    check noEntry.error.context.contains("clap_entry")

  test "entry and factory failures clean every successful initialization":
    type Scenario = tuple[
      variant: string,
      kind: HostErrorKind,
      initCalls: uint32,
      successfulInits: uint32,
      deinitCalls: uint32,
    ]
    let scenarios: seq[Scenario] = @[
      ("incompatible_entry", hekClapVersion, 0'u32, 0'u32, 0'u32),
      ("missing_entry_callback", hekClapEntry, 0'u32, 0'u32, 0'u32),
      ("init_fail", hekClapEntryInit, 1'u32, 0'u32, 0'u32),
      ("missing_factory", hekClapFactory, 1'u32, 1'u32, 1'u32),
      ("missing_factory_callback", hekClapFactory, 1'u32, 1'u32, 1'u32),
    ]

    for scenario in scenarios:
      let path = clapFixturePath(scenario.variant)
      var observerResult = openDynamicLibrary(path)
      require observerResult.isOk
      var observer = move(observerResult.value)
      let api = fixtureApi(observer)
      api.reset()

      let opened = openClapModule(path)
      check not opened.isOk
      check opened.error.kind == scenario.kind
      check opened.error.exitCode() == ExitClap
      check api.initCalls() == scenario.initCalls
      check api.successfulInits() == scenario.successfulInits
      check api.deinitCalls() == scenario.deinitCalls
      check api.createCalls() == 0
      check observer.close().isOk

  test "a closed module rejects descriptor access and remains closeable":
    var module: ClapModule
    let catalog = module.readCatalog()

    check not catalog.isOk
    check catalog.error.kind == hekClapFactory
    check module.close().isOk
