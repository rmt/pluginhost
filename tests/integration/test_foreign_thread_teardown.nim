import std/[os, osproc, posix, streams, strutils, unittest]

when not defined(nimAllocStats):
  {.error: "foreign-thread teardown tests require -d:nimAllocStats".}
import pluginhost/clap/[host_bridge, instance, loader]
import pluginhost/domain/[plugin_catalog, result]
import pluginhost/platform/linux/dynlib

const
  FixtureDirectoryEnvironment = "PLUGINHOST_CLAP_FIXTURE_DIR"
  FixtureName = "foreign_thread_race.clap"
  FixtureId = "org.pluginhost.fixture.foreign-thread-race"
  StartSpinLimit = 5_000_000

type
  CounterProc = proc(): uint32 {.cdecl, gcsafe, raises: [].}

proc fixturePath(): string =
  let directory = getEnv(FixtureDirectoryEnvironment)
  require directory.len > 0
  result = directory / FixtureName
  require fileExists(result)

proc resolveCounter(library: DynamicLibrary; name: string): CounterProc =
  let resolved = resolveSymbol[CounterProc](library, name)
  require resolved.isOk
  resolved.value

proc waitForPidFile(path: string; process: Process): bool =
  for attempt in 0 ..< 1_000:
    if fileExists(path):
      return true
    if process.peekExitCode() != -1:
      return false
    sleep(5)
  false

suite "11C foreign-thread teardown":
  test "plugin-owned worker joins while callbacks overlap destroy":
    let path = fixturePath()
    var counterOpened = openDynamicLibrary(path)
    require counterOpened.isOk
    var counterLibrary = move(counterOpened.value)
    defer:
      doAssert counterLibrary.close().isOk

    let started = counterLibrary.resolveCounter(
      "pluginhost_foreign_thread_race_started")
    let batches = counterLibrary.resolveCounter(
      "pluginhost_foreign_thread_race_batches")
    let duringDestroy = counterLibrary.resolveCounter(
      "pluginhost_foreign_thread_race_during_destroy")
    let joined = counterLibrary.resolveCounter(
      "pluginhost_foreign_thread_race_joined")

    var moduleOpened = openClapModule(path)
    require moduleOpened.isOk
    var module = move(moduleOpened.value)
    var catalog = module.readCatalog()
    require catalog.isOk
    require catalog.value.descriptors.len == 1
    require catalog.value.descriptors[0].id == FixtureId
    var selected = move(catalog.value.descriptors[0])

    var created = createClapInstance(move(module), move(selected))
    require created.isOk
    var instance = move(created.value)
    defer:
      doAssert instance.close().isOk

    var spin = 0
    while (started() == 0'u32 or batches() == 0'u32) and
        spin < StartSpinLimit:
      discard sched_yield()
      inc spin
    require started() == 1'u32
    require batches() > 0'u32
    check takeRequests(instance.hostBridge()) != 0'u32

    let beforeLive = getAllocStats()
    let targetBatches = batches() + 10_000'u32
    spin = 0
    while batches() < targetBatches and spin < StartSpinLimit:
      discard sched_yield()
      inc spin
    let afterLive = getAllocStats()
    require batches() >= targetBatches
    check beforeLive == afterLive

    let closed = instance.close()
    require closed.isOk
    check started() == 1'u32
    check batches() > 0'u32
    check duringDestroy() > 0'u32
    check joined() == 1'u32
    check instance.close().isOk
    echo "11C foreign-thread teardown started=", started(),
      " batches=", batches(),
      " during-destroy=", duringDestroy(),
      " joined=", joined(),
      " live-allocation-delta=", $(afterLive - beforeLive)

  test "public SIGTERM witnesses foreign-thread teardown":
    require getEnv("PLUGINHOST_INTEGRATION_ISOLATED") == "1"
    let executable = getEnv("PLUGINHOST_TEST_BIN")
    require executable.len > 0 and fileExists(executable)

    let pidPath = getTempDir() / ("pluginhost-foreign-race-" & $getpid() & ".pid")
    if fileExists(pidPath):
      removeFile(pidPath)
    let process = startProcess(executable, args = @[
      "--quiet",
      "--no-gui",
      "--no-start-server",
      "--plugin-id", FixtureId,
      "--client-name", "pluginhost-11c-foreign",
      "--pid-file", pidPath,
      fixturePath(),
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
    require kill(Pid(process.processID), SIGTERM) == 0
    check process.waitForExit(10_000) == 0

    let output = process.outputStream.readAll()
    let diagnostic = process.errorStream.readAll()
    check output.len == 0
    check diagnostic.len == 0
    check not fileExists(pidPath)
    echo "11C public foreign-thread teardown exit=0 stdout-bytes=",
      output.len, " stderr-bytes=", diagnostic.len

