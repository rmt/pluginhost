import std/unittest

import pluginhost/platform/x11/ffi
import ./abi_probe

suite "X11 ABI":
  test "minimal Xlib event storage matches the system headers":
    check uint64(sizeof(XEvent)) == abiSize(303)
    check uint64(alignof(XEvent)) == abiAlign(303)
    check uint64(sizeof(XConfigureEvent)) == abiSize(304)
    check uint64(alignof(XConfigureEvent)) == abiAlign(304)
    check uint64(sizeof(XClientMessageEvent)) == abiSize(305)
    check uint64(alignof(XClientMessageEvent)) == abiAlign(305)
    check uint64(offsetOf(XConfigureEvent, window)) ==
      abiOffset(abiFieldId(304, 1))
    check uint64(offsetOf(XConfigureEvent, width)) ==
      abiOffset(abiFieldId(304, 2))
    check uint64(offsetOf(XConfigureEvent, height)) ==
      abiOffset(abiFieldId(304, 3))
    check uint64(offsetOf(XClientMessageEvent, window)) ==
      abiOffset(abiFieldId(305, 1))
    check uint64(offsetOf(XClientMessageEvent, messageType)) ==
      abiOffset(abiFieldId(305, 2))
    check uint64(offsetOf(XClientMessageEvent, format)) ==
      abiOffset(abiFieldId(305, 3))
    check uint64(offsetOf(XClientMessageEvent, data)) ==
      abiOffset(abiFieldId(305, 4))

  test "all X11 procedure aliases are pointer-sized C values":
    check sizeof(X11OpenDisplayProc) == sizeof(pointer)
    check sizeof(X11CloseDisplayProc) == sizeof(pointer)
    check sizeof(X11DefaultRootWindowProc) == sizeof(pointer)
    check sizeof(X11CreateSimpleWindowProc) == sizeof(pointer)
    check sizeof(X11DestroyWindowProc) == sizeof(pointer)
    check sizeof(X11SelectInputProc) == sizeof(pointer)
    check sizeof(X11MapWindowProc) == sizeof(pointer)
    check sizeof(X11UnmapWindowProc) == sizeof(pointer)
    check sizeof(X11ResizeWindowProc) == sizeof(pointer)
    check sizeof(X11StoreNameProc) == sizeof(pointer)
    check sizeof(X11ChangePropertyProc) == sizeof(pointer)
    check sizeof(X11InternAtomProc) == sizeof(pointer)
    check sizeof(X11SetWMProtocolsProc) == sizeof(pointer)
    check sizeof(X11ConnectionNumberProc) == sizeof(pointer)
    check sizeof(X11FlushProc) == sizeof(pointer)
    check sizeof(X11PendingProc) == sizeof(pointer)
    check sizeof(X11NextEventProc) == sizeof(pointer)
