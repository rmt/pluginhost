import std/strutils

const ReplacementUtf8 = "\xEF\xBF\xBD"

func isContinuation(value: uint8): bool {.inline.} =
  value >= 0x80'u8 and value <= 0xBF'u8

func validSequenceLength(text: string; offset: int): int =
  let first = uint8(text[offset])
  let remaining = text.len - offset

  if first <= 0x7F'u8:
    return 1
  if first >= 0xC2'u8 and first <= 0xDF'u8:
    if remaining >= 2 and isContinuation(uint8(text[offset + 1])):
      return 2
    return 0
  if first >= 0xE0'u8 and first <= 0xEF'u8:
    if remaining < 3:
      return 0
    let second = uint8(text[offset + 1])
    let third = uint8(text[offset + 2])
    if not isContinuation(third):
      return 0
    if first == 0xE0'u8 and second >= 0xA0'u8 and second <= 0xBF'u8:
      return 3
    if first == 0xED'u8 and second >= 0x80'u8 and second <= 0x9F'u8:
      return 3
    if first notin {0xE0'u8, 0xED'u8} and isContinuation(second):
      return 3
    return 0
  if first >= 0xF0'u8 and first <= 0xF4'u8:
    if remaining < 4:
      return 0
    let second = uint8(text[offset + 1])
    if not isContinuation(uint8(text[offset + 2])) or
        not isContinuation(uint8(text[offset + 3])):
      return 0
    if first == 0xF0'u8 and second >= 0x90'u8 and second <= 0xBF'u8:
      return 4
    if first == 0xF4'u8 and second >= 0x80'u8 and second <= 0x8F'u8:
      return 4
    if first notin {0xF0'u8, 0xF4'u8} and isContinuation(second):
      return 4
  0

proc replaceInvalidUtf8*(text: string): string =
  ## Produces valid UTF-8 while preserving every valid byte sequence verbatim.
  result = newStringOfCap(text.len)
  var offset = 0
  while offset < text.len:
    let sequenceLength = validSequenceLength(text, offset)
    if sequenceLength == 0:
      result.add(ReplacementUtf8)
      inc offset
    else:
      for index in offset ..< offset + sequenceLength:
        result.add(text[index])
      inc offset, sequenceLength

proc escapeControlText*(text: string): string =
  ## Makes text valid UTF-8 and escapes terminal line/ANSI control bytes.
  let validText = replaceInvalidUtf8(text)
  var index = 0
  while index < validText.len:
    let value = uint8(validText[index])
    if value == uint8('\\'):
      result.add("\\\\")
    elif value < 0x20'u8 or value == 0x7F'u8:
      result.add("\\u" & toHex(value, 4).toLowerAscii())
    elif value == 0xC2'u8 and index + 1 < validText.len and
        uint8(validText[index + 1]) >= 0x80'u8 and
        uint8(validText[index + 1]) <= 0x9F'u8:
      result.add("\\u" & toHex(uint8(validText[index + 1]), 4).toLowerAscii())
      inc index
    else:
      result.add(validText[index])
    inc index
