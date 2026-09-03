## Backend-neutral window-host values shared by GUI adapters.
##
## This module contains no X11, CLAP, or reactor imports. It deliberately keeps
## GUI resource ownership in a concrete platform adapter.

type
  WindowHostState* = enum
    whClosed
    whHidden
    whVisible

  WindowEventKind* = enum
    wekOther
    wekClose
    wekConfigure
    wekMap
    wekUnmap

  WindowEvent* = object
    kind*: WindowEventKind
    width*: uint32
    height*: uint32

  WindowPollResult* = object
    available*: bool
    event*: WindowEvent
