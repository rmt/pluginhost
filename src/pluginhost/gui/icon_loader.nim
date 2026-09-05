## Control-plane loader for explicit host icons.
##
## The deliberately small accepted format is binary or plain-text PPM (P6/P3)
## with 8-bit RGB samples. This avoids a heavyweight image dependency while
## keeping file size, dimensions, and allocations bounded.

import std/strutils

import ../domain/[errors, result]
import ./icon

proc loaderError(message: string; path: string; detail = ""): HostError =
  var context = "path=" & path
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsGui, hekGui, message, context)

proc isWhitespace(value: char): bool {.inline.} =
  value in {' ', '\t', '\r', '\n', '\f', '\v'}

proc nextToken(data: string; position: var int): string =
  while position < data.len:
    if isWhitespace(data[position]):
      inc position
    elif data[position] == '#':
      while position < data.len and data[position] notin {'\r', '\n'}:
        inc position
    else:
      break
  let start = position
  while position < data.len and not isWhitespace(data[position]) and
      data[position] != '#':
    inc position
  if position > start:
    data[start ..< position]
  else:
    ""

proc parseUnsignedToken(token, label, path: string): Result[int] =
  if token.len == 0:
    return failure[int](loaderError(
      "icon file ended before its " & label, path))
  var parsed: int
  try:
    parsed = parseInt(token)
    if parsed < 0:
      return failure[int](loaderError(
        "icon " & label & " is invalid", path, "value=" & token))
  except ValueError:
    return failure[int](loaderError(
      "icon " & label & " is invalid", path, "value=" & token))
  success(parsed)

proc scaleSample(sample, maximum: int): uint32 {.inline.} =
  if maximum == 255:
    uint32(sample)
  else:
    uint32((sample * 255 + maximum div 2) div maximum)

proc parsePpm*(path: string): Result[GuiIcon] =
  if path.len == 0:
    return failure[GuiIcon](loaderError("icon path must not be empty", path))
  var data: string
  try:
    data = readFile(path)
  except CatchableError as error:
    return failure[GuiIcon](loaderError(
      "could not read icon file", path, error.msg))
  if data.len == 0 or data.len > MaxIconFileBytes:
    return failure[GuiIcon](loaderError(
      "icon file size is outside the host limit", path,
      "bytes=" & $data.len & "; limit=" & $MaxIconFileBytes))

  var position = 0
  let magic = nextToken(data, position)
  if magic notin ["P3", "P6"]:
    return failure[GuiIcon](loaderError(
      "icon file must be a PPM P3 or P6 image", path, "magic=" & magic))
  var widthResult = parseUnsignedToken(nextToken(data, position), "width", path)
  if not widthResult.isOk:
    return failure[GuiIcon](move(widthResult.error))
  var heightResult = parseUnsignedToken(nextToken(data, position), "height", path)
  if not heightResult.isOk:
    return failure[GuiIcon](move(heightResult.error))
  var maximumResult = parseUnsignedToken(nextToken(data, position), "maximum sample", path)
  if not maximumResult.isOk:
    return failure[GuiIcon](move(maximumResult.error))

  let width = widthResult.value
  let height = heightResult.value
  let maximum = maximumResult.value
  if width <= 0 or height <= 0 or width > int(MaxIconDimension) or
      height > int(MaxIconDimension):
    return failure[GuiIcon](loaderError(
      "icon dimensions exceed the host limit", path,
      "width=" & $width & "; height=" & $height &
        "; limit=" & $MaxIconDimension))
  if maximum <= 0 or maximum > 255:
    return failure[GuiIcon](loaderError(
      "icon maximum sample must be between 1 and 255", path,
      "maximum=" & $maximum))

  let pixelCount = width * height
  var pixels = newSeq[uint32](pixelCount)
  if magic == "P6":
    if position >= data.len or not isWhitespace(data[position]):
      return failure[GuiIcon](loaderError(
        "binary PPM is missing its sample separator", path))
    inc position
    if data[position - 1] == '\r' and position < data.len and
        data[position] == '\n':
      inc position
    if data.len - position < pixelCount * 3:
      return failure[GuiIcon](loaderError(
        "binary PPM does not contain enough RGB samples", path))
    for index in 0 ..< pixelCount:
      let red = ord(data[position]); inc position
      let green = ord(data[position]); inc position
      let blue = ord(data[position]); inc position
      if red > maximum or green > maximum or blue > maximum:
        return failure[GuiIcon](loaderError(
          "binary PPM sample exceeds its maximum", path,
          "maximum=" & $maximum))
      pixels[index] = 0xff000000'u32 or
        (scaleSample(red, maximum) shl 16) or
        (scaleSample(green, maximum) shl 8) or
        scaleSample(blue, maximum)
  else:
    for index in 0 ..< pixelCount:
      var redResult = parseUnsignedToken(nextToken(data, position), "red sample", path)
      if not redResult.isOk:
        return failure[GuiIcon](move(redResult.error))
      var greenResult = parseUnsignedToken(nextToken(data, position), "green sample", path)
      if not greenResult.isOk:
        return failure[GuiIcon](move(greenResult.error))
      var blueResult = parseUnsignedToken(nextToken(data, position), "blue sample", path)
      if not blueResult.isOk:
        return failure[GuiIcon](move(blueResult.error))
      if redResult.value > maximum or greenResult.value > maximum or
          blueResult.value > maximum:
        return failure[GuiIcon](loaderError(
          "plain-text PPM sample exceeds its maximum", path,
          "maximum=" & $maximum))
      pixels[index] = 0xff000000'u32 or
        (scaleSample(redResult.value, maximum) shl 16) or
        (scaleSample(greenResult.value, maximum) shl 8) or
        scaleSample(blueResult.value, maximum)

  newGuiIcon(uint32(width), uint32(height), move(pixels))
