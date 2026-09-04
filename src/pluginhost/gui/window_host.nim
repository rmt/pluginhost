## Backend-neutral window-host values shared by GUI adapters.
##
## This module contains no X11, CLAP, or reactor imports. It deliberately keeps
## GUI resource ownership in a concrete platform adapter.

type
  GuiWindowApi* = enum
    gwaX11

  GuiWindowHandle* = object
    api*: GuiWindowApi
    id*: uint64

  GuiResizeHints* = object
    canResizeHorizontally*: bool
    canResizeVertically*: bool
    preserveAspectRatio*: bool
    aspectRatioWidth*: uint32
    aspectRatioHeight*: uint32

  GuiSize* = object
    width*: uint32
    height*: uint32
  WindowHostState* = enum
    whClosed
    whHidden
    whVisible

  WindowEventKind* = enum
    wekOther
    wekClose
    wekDestroyed
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
