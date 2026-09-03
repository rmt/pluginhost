import std/unittest

import pluginhost/domain/errors
import pluginhost/gui/window_host
import pluginhost/platform/x11/[api, ffi, window_host]

suite "X11 window-host boundary":
  test "X11 loading is explicit and missing libraries are typed":
    let opened = openX11Api("/pluginhost/no-such-libX11.so")
    check not opened.isOk
    check opened.error.subsystem == hsGui
    check opened.error.kind == hekGui

  test "invalid window inputs fail before display access":
    let invalidTitle = openX11WindowHost(title = "bad\0title")
    check not invalidTitle.isOk
    check invalidTitle.error.subsystem == hsGui

    let invalidDisplay = openX11WindowHost(displayName = "bad\0display")
    check not invalidDisplay.isOk
    check invalidDisplay.error.subsystem == hsGui

    let invalidWidth = openX11WindowHost(width = 0)
    check not invalidWidth.isOk

  test "WM close messages are classified without retaining Xlib event storage":
    var raw: XEvent
    let client = cast[ptr XClientMessageEvent](addr raw)
    client.eventType = X11ClientMessage
    client.window = 17
    client.messageType = 23
    client.format = 32
    client.data[0] = 29
    check isWmDeleteEvent(addr raw, 17, 23, 29)
    client.data[0] = 30
    check not isWmDeleteEvent(addr raw, 17, 23, 29)

  test "a zero-value owner is safely closeable":
    var host: X11WindowHost
    require host.close().isOk
    check host.state == whClosed
    check host.fileDescriptor == -1
