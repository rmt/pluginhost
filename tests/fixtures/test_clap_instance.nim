import std/[os, unittest]

import pluginhost/clap/[host_bridge, instance]
import pluginhost/clap/loader
import pluginhost/domain/[errors, plugin_catalog]
import pluginhost/platform/linux/dynlib
import ./clap/fixture_api

static:
  doAssert not compiles(block:
    var original: ClapInstance
    var duplicate = `=dup`(original)
    discard duplicate.state
  )

type
  DestroyThreadAttempt = object
    instance: ptr ClapInstance
    succeeded: bool
    errorKind: HostErrorKind

proc destroyInstanceOnThread(attempt: ptr DestroyThreadAttempt) {.thread.} =
  let destroyed = attempt.instance[].destroy()
  attempt.succeeded = destroyed.isOk
  if not destroyed.isOk:
    attempt.errorKind = destroyed.error.kind

proc openSelectedInstance(path: string):
    tuple[instance: ClapInstance, api: FixtureApi, observer: DynamicLibrary] =
  var observerResult = openDynamicLibrary(path)
  require observerResult.isOk
  var observer = move(observerResult.value)
  let api = fixtureApi(observer)
  api.reset()

  var moduleResult = openClapModule(path)
  require moduleResult.isOk
  var module = move(moduleResult.value)
  let catalog = module.readCatalog()
  require catalog.isOk
  var selected = catalog.value.selectDescriptor(PluginSelector(
    kind: pskId,
    pluginId: "org.pluginhost.fixture.synth",
  ))
  require selected.isOk

  var created = createClapInstance(move(module), move(selected.value))
  require created.isOk
  (move(created.value), api, move(observer))

proc retainBridgesAfterMove(path: string):
    tuple[replaced, moved: ClapHostBridge] =
  var first = openSelectedInstance(path)
  var instance = move(first.instance)
  var firstObserver = move(first.observer)
  result.replaced = instance.hostBridge
  doAssert instance.close().isOk
  doAssert firstObserver.close().isOk

  var second = openSelectedInstance(path)
  instance = move(second.instance)
  var secondObserver = move(second.observer)
  result.moved = instance.hostBridge
  doAssert instance.close().isOk
  doAssert secondObserver.close().isOk

suite "CLAP instance lifecycle":
  test "create and init retain the host through destroy":
    var opened = openSelectedInstance(clapFixturePath("valid"))
    var instance = move(opened.instance)
    var observer = move(opened.observer)
    let api = opened.api
    defer:
      doAssert instance.close().isOk
      doAssert observer.close().isOk

    check instance.state == cisInitialized
    check instance.modulePath == expandFilename(clapFixturePath("valid"))
    check instance.pluginExtensions.audioPorts != nil
    check instance.pluginExtensions.notePorts != nil
    check api.createCalls() == 1
    check api.pluginInitCalls() == 1
    check api.pluginDestroyCalls() == 0
    check api.deinitCalls() == 0
    check api.hostContractFailures() == 0

    let host = instance.hostBridge.hostPointer
    check $host.name == "pluginhost"
    check $host.version == "0.0.8-dev"

    let requests = instance.takeRequests()
    check (requests and ClapRequestRestart) != 0
    check (requests and ClapRequestProcess) != 0
    check (requests and ClapRequestCallback) != 0
    check instance.takeRequests() == 0

    var record: ClapHostLogRecord
    var messages: seq[string]
    while instance.tryPopLog(record):
      messages.add(record.logMessage)
    check messages.len == 3
    check messages[0] == "fixture init"
    check messages[1] == "fixture worker"
    check messages[2] == "fixture worker"

    var attempt = DestroyThreadAttempt(instance: addr instance)
    var worker: Thread[ptr DestroyThreadAttempt]
    createThread(worker, destroyInstanceOnThread, addr attempt)
    joinThread(worker)
    check not attempt.succeeded
    check attempt.errorKind == hekClapPlugin
    check instance.state == cisInitialized
    check api.pluginDestroyCalls() == 0
    check api.hostContractFailures() == 0

    check instance.destroy().isOk
    check instance.state == cisDestroyed
    check api.pluginDestroyCalls() == 1
    check api.deinitCalls() == 0
    check instance.destroy().isOk

    check instance.close().isOk
    check instance.state == cisClosed
    check api.deinitCalls() == 1
    check instance.close().isOk

    check instance.tryPopLog(record)
    check record.logMessage == "fixture destroy"

  test "move assignment and destruction release the retained host bridge":
    let bridges = retainBridgesAfterMove(clapFixturePath("valid"))
    check isUniqueRef(bridges.replaced)
    check isUniqueRef(bridges.moved)

  test "creation and initialization failures clean partial state":
    type Scenario = tuple[
      variant: string,
      kind: HostErrorKind,
      createCalls: uint32,
      pluginInitCalls: uint32,
      pluginDestroyCalls: uint32,
      deinitCalls: uint32,
    ]
    let scenarios: seq[Scenario] = @[
      ("create_fail", hekClapPluginCreate, 1'u32, 0'u32, 0'u32, 1'u32),
      ("plugin_init_fail", hekClapPluginInit, 1'u32, 1'u32, 1'u32, 1'u32),
      ("missing_plugin_destroy", hekClapPlugin, 1'u32, 0'u32, 0'u32, 1'u32),
      ("plugin_wrong_id", hekClapPlugin, 1'u32, 0'u32, 1'u32, 1'u32),
      ("plugin_incompatible_descriptor", hekClapPlugin,
        1'u32, 0'u32, 1'u32, 1'u32),
    ]

    for scenario in scenarios:
      var observerResult = openDynamicLibrary(clapFixturePath(scenario.variant))
      require observerResult.isOk
      var observer = move(observerResult.value)
      let api = fixtureApi(observer)
      api.reset()

      var moduleResult = openClapModule(clapFixturePath(scenario.variant))
      require moduleResult.isOk
      var module = move(moduleResult.value)
      let catalog = module.readCatalog()
      require catalog.isOk
      var selected = catalog.value.selectDescriptor(PluginSelector(
        kind: pskIndex,
        pluginIndex: 0,
      ))
      require selected.isOk

      let created = createClapInstance(move(module), move(selected.value))
      check not created.isOk
      check created.error.kind == scenario.kind
      check api.createCalls() == scenario.createCalls
      check api.pluginInitCalls() == scenario.pluginInitCalls
      check api.pluginDestroyCalls() == scenario.pluginDestroyCalls
      check api.deinitCalls() == scenario.deinitCalls
      check api.hostContractFailures() == 0
      check observer.close().isOk
