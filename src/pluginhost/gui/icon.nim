## Bounded control-plane icon values shared by GUI surfaces.
##
## Pixels are opaque/alpha ARGB32 values in host byte order. The value never
## enters the JACK process path.

import ../domain/[errors, result]

const
  MaxIconDimension* = 64'u32
  MaxIconPixels* = MaxIconDimension * MaxIconDimension
  MaxIconFileBytes* = 4 * 1024 * 1024

type
  GuiIcon* = ref object
    width*: uint32
    height*: uint32
    pixels*: seq[uint32]

proc iconError(message: string; context = ""): HostError =
  hostError(hsGui, hekGui, message, context)

proc newGuiIcon*(width, height: uint32; pixels: sink seq[uint32]):
    Result[GuiIcon] =
  if width == 0'u32 or height == 0'u32 or
      width > MaxIconDimension or height > MaxIconDimension:
    return failure[GuiIcon](iconError(
      "icon dimensions exceed the host limit",
      "width=" & $width & "; height=" & $height &
        "; limit=" & $MaxIconDimension))
  let expected = uint64(width) * uint64(height)
  if expected > uint64(MaxIconPixels) or pixels.len != int(expected):
    return failure[GuiIcon](iconError(
      "icon pixel count does not match its dimensions",
      "pixels=" & $pixels.len & "; expected=" & $expected))
  var icon: GuiIcon
  new(icon)
  icon.width = width
  icon.height = height
  icon.pixels = move(pixels)
  success(move(icon))
proc defaultGuiIcon*(): GuiIcon =
  new(result)
  result.width = 16'u32
  result.height = 16'u32
  result.pixels = newSeq[uint32](int(result.width * result.height))
  for y in 0 ..< int(result.height):
    for x in 0 ..< int(result.width):
      let edge = x == 0 or y == 0 or x == int(result.width) - 1 or
        y == int(result.height) - 1
      let center = x >= 4 and x <= 11 and y >= 4 and y <= 11
      result.pixels[y * int(result.width) + x] =
        if edge: 0xff1c2430'u32
        elif center: 0xfff4f7fb'u32
        else: 0xff3d78b8'u32
