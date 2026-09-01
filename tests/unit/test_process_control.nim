import std/[os, posix, strutils, unittest]

import pluginhost/domain/errors
import pluginhost/platform/linux/[pid_file, signals]
import pluginhost/support/names

proc signalBlocked(signalNumber: cint): bool =
  var empty, current: Sigset
  require sigemptyset(empty) == 0
  require pthread_sigmask(SIG_BLOCK, empty, current) == 0
  sigismember(current, signalNumber) == 1

suite "Linux process control resources":
  test "signalfd consumes handled signals and restores the previous mask":
    let usr1WasBlocked = signalBlocked(SIGUSR1)
    var opened = openSignalSource()
    require opened.isOk
    var source = move(opened.value)
    check source.isOpen
    check signalBlocked(SIGINT)
    check signalBlocked(SIGTERM)
    check signalBlocked(SIGUSR1)
    check signalBlocked(SIGUSR2)
    require kill(getpid(), SIGUSR1) == 0
    var drained = source.drain()
    require drained.isOk
    check drained.value == @[siShowGui]
    check source.close().isOk
    check signalBlocked(SIGUSR1) == usr1WasBlocked
    check source.close().isOk

  test "PID files publish complete content and reject collisions":
    let root = getTempDir() / ("pluginhost-pid-test-" & $getpid())
    if dirExists(root):
      removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let path = root / "host.pid"

    var created = createPidFile(path)
    require created.isOk
    var owner = move(created.value)
    check owner.isOwned
    check readFile(path) == $getpid() & "\n"
    var collision = createPidFile(path)
    check not collision.isOk
    check collision.error.kind == hekPidFile
    check collision.error.message.contains("already exists")
    check owner.close().isOk
    check not fileExists(path)
    check owner.close().isOk

  test "PID publication failure leaves no target or temporary entry":
    let root = getTempDir() / ("pluginhost-pid-rollback-" & $getpid())
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let missingParent = root / "missing"
    let path = missingParent / "host.pid"
    var created = createPidFile(path)
    check not created.isOk
    check created.error.kind == hekPidFile
    check not fileExists(path)
    var entries = 0
    for kind, entry in walkDir(root):
      discard kind
      discard entry
      inc entries
    check entries == 0

  test "PID cleanup never removes a replacement entry":
    let root = getTempDir() / ("pluginhost-pid-replace-" & $getpid())
    if dirExists(root):
      removeDir(root)
    createDir(root)
    defer:
      let path = root / "host.pid"
      if fileExists(path): removeFile(path)
      removeDir(root)
    let path = root / "host.pid"
    var created = createPidFile(path)
    require created.isOk
    var owner = move(created.value)
    removeFile(path)
    writeFile(path, "replacement\n")
    var closed = owner.close()
    check not closed.isOk
    check closed.error.kind == hekPidFile
    check readFile(path) == "replacement\n"
    check not owner.isOwned

suite "default JACK client naming":
  test "plugin names become bounded deterministic ASCII names":
    check defaultJackClientName("Good Synth 2") == "Good-Synth-2"
    check defaultJackClientName("  / weird ::: name  ") == "weird-name"
    check defaultJackClientName("💥") == "pluginhost"
    check defaultJackClientName(repeat("a", 80)).len == DefaultClientNameBytes
