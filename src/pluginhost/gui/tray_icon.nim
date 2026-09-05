## Backend-neutral capability for a small application tray icon.
##
## Tray operations are control-plane only. Implementations own their native
## connection/window resources and expose only a reactor descriptor plus bounded
## activation events.

import ../domain/[errors, result]
import ./icon

type
  TrayEventKind* = enum
    tekOther
    tekActivate
    tekClosed

  TrayEvent* = object
    kind*: TrayEventKind

  TrayPollResult* = object
    available*: bool
    event*: TrayEvent

  TrayIconBackend* = ref object of RootObj

  TrayIconFactory* = proc(): TrayIconBackend

proc trayIconError(message: string): HostError =
  hostError(hsGui, hekGui, message)

method open*(backend: TrayIconBackend; title: string;
             icon: GuiIcon): Result[Unit] {.
    base, raises: [].} =
  discard backend
  discard title
  discard icon
  failure[Unit](trayIconError("tray icon backend does not support opening"))

method close*(backend: TrayIconBackend): Result[Unit] {.base, raises: [].} =
  discard backend
  success()

method pollEvent*(backend: TrayIconBackend): Result[TrayPollResult] {.
    base, raises: [].} =
  discard backend
  failure[TrayPollResult](trayIconError(
    "tray icon backend does not support event polling"))

method fileDescriptor*(backend: TrayIconBackend): int32 {.base, raises: [].} =
  discard backend
  -1'i32
