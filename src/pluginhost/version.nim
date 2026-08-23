import std/[os, strutils]

const
  projectRoot = currentSourcePath.parentDir.parentDir.parentDir
  Version* = staticRead(projectRoot / "VERSION").strip()
  PackageVersion* = Version.split('-', maxsplit = 1)[0]
  ProductName* = "pluginhost"

proc versionText*(): string =
  ProductName & " " & Version & "\n" &
    "Nim " & NimVersion & "\n" &
    "CLAP SDK not integrated\n"
