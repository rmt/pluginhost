import std/[os, strutils]

const
  projectRoot = currentSourcePath.parentDir.parentDir.parentDir
  Version* = staticRead(projectRoot / "VERSION").strip()
  PackageVersion* = Version.split('-', maxsplit = 1)[0]
  ProductName* = "pluginhost"
  ClapSdkVersion* = "1.2.10"
  Vst3SdkVersion* = "3.8.1"
  JackAbiVersion* = "libjack.so.0"

proc versionText*(): string =
  ProductName & " " & Version & "\n" &
    "Nim " & NimVersion & "\n" &
    "CLAP SDK " & ClapSdkVersion & "\n" &
    "VST3 SDK " & Vst3SdkVersion & "\n" &
    "JACK ABI " & JackAbiVersion & "\n"
