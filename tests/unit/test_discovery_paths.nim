import std/[os, strutils, unittest]

import pluginhost/discovery/[paths, scanner]
import pluginhost/domain/errors

suite "CLAP discovery root policy":
  test "explicit roots are exclusive and preserve order":
    let roots = discoveryRoots(@["first", "second"], "/home/test", "/ignored:/also-ignored")

    check roots.len == 2
    check roots[0].path == "first"
    check roots[0].kind == drkExplicit
    check roots[1].path == "second"
    check roots[1].kind == drkExplicit

  test "standard roots precede non-empty CLAP_PATH entries":
    let roots = discoveryRoots(@[], "/home/test", "/one::/two:")

    check roots.len == 4
    check roots[0].path == "/home/test/.clap"
    check roots[0].kind == drkHome
    check roots[1].path == "/usr/lib/clap"
    check roots[1].kind == drkSystem
    check roots[2].path == "/one"
    check roots[2].kind == drkEnvironment
    check roots[3].path == "/two"
    check roots[3].kind == drkEnvironment

  test "missing standard roots are skipped":
    let root = getTempDir() / ("pluginhost-missing-home-" &
      $getCurrentProcessId()) / ".clap"
    let report = scanConfiguredRoots(@[
      DiscoveryRoot(path: root, kind: drkHome),
    ])

    check report.plugins.len == 0
    check report.issues.len == 0

  test "inaccessible standard roots are reported":
    let root = getTempDir() / ("pluginhost-inaccessible-home-" &
      $getCurrentProcessId())
    if dirExists(root):
      setFilePermissions(root, {fpUserExec, fpUserWrite, fpUserRead})
      removeDir(root)
    createDir(root)
    defer: removeDir(root)
    defer: setFilePermissions(root,
      {fpUserExec, fpUserWrite, fpUserRead})
    setFilePermissions(root, {})

    let report = scanConfiguredRoots(@[
      DiscoveryRoot(path: root / ".clap", kind: drkHome),
    ])

    check report.plugins.len == 0
    check report.issues.len == 1
    check report.issues[0].error.kind == hekDiscoveryRoot
    check report.issues[0].error.context.contains("source=home")
