import std/[os, strutils, unittest]

import pluginhost/version

const projectRoot = currentSourcePath.parentDir.parentDir.parentDir

suite "version information":
  test "the compiled version matches the root VERSION file":
    check Version == readFile(projectRoot / "VERSION").strip()
    check PackageVersion == "0.0.1"
    let nimbleFile = readFile(projectRoot / "pluginhost.nimble")
    check nimbleFile.contains("version       = \"" & PackageVersion & "\"")

  test "version output identifies the development integration state":
    let text = versionText()

    check text.startsWith("pluginhost " & Version & "\n")
    check text.contains("Nim " & NimVersion)
    check text.contains("CLAP SDK not integrated")
