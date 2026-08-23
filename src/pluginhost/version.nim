import std/[os, strutils]

const
  projectRoot = currentSourcePath.parentDir.parentDir.parentDir
  Version* = staticRead(projectRoot / "VERSION").strip()
  PackageVersion* = Version.split('-', maxsplit = 1)[0]
  ProductName* = "pluginhost"
  ClapSdkVersion* = "1.2.10"
  JackAbiVersion* = "libjack.so.0"

proc versionText*(): string =
  ProductName & " " & Version & "\n" &
    "Nim " & NimVersion & "\n" &
    "CLAP SDK " & ClapSdkVersion & "\n" &
    "JACK ABI " & JackAbiVersion & "\n"
