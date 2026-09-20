import ../domain/[errors, result]
import ./ffi

proc hexDigit(value: uint8): char {.inline.} =
  const digits = "0123456789ABCDEF"
  digits[int(value and 0x0F'u8)]

proc decodeHex(value: char; output: var uint8): bool {.inline.} =
  if value >= '0' and value <= '9':
    output = uint8(ord(value) - ord('0'))
    return true
  if value >= 'a' and value <= 'f':
    output = uint8(ord(value) - ord('a') + 10)
    return true
  if value >= 'A' and value <= 'F':
    output = uint8(ord(value) - ord('A') + 10)
    return true
  false

proc parseVst3Uid*(text: string): Result[Vst3Tuid] =
  if text.len != Vst3TuidBytes * 2:
    return failure[Vst3Tuid](hostError(
      hsVst3, hekVst3Descriptor,
      "invalid VST3 class identifier",
      "expected exactly 32 hexadecimal characters; value length=" & $text.len,
    ))

  var uid: Vst3Tuid
  for index in 0 ..< Vst3TuidBytes:
    var high, low: uint8
    if not decodeHex(text[index * 2], high) or
       not decodeHex(text[index * 2 + 1], low):
      return failure[Vst3Tuid](hostError(
        hsVst3, hekVst3Descriptor,
        "invalid VST3 class identifier",
        "value contains a non-hexadecimal character at offset=" &
          $(index * 2),
      ))
    uid[index] = (high shl 4) or low
  success(uid)

proc formatVst3Uid*(uid: Vst3Tuid): string =
  result = newStringOfCap(Vst3TuidBytes * 2)
  for value in uid:
    result.add(hexDigit(value shr 4))
    result.add(hexDigit(value))

proc uidEquals*(left, right: Vst3Tuid): bool {.inline.} =
  left == right

proc fixedCString*(value: openArray[char]): string =
  result = newStringOfCap(value.len)
  for character in value:
    if character == '\0':
      break
    result.add(character)
proc fixedCStringResult*(value: openArray[char]): Result[string] =
  var length = 0
  while length < value.len and value[length] != '\0':
    inc length
  if length == value.len:
    return failure[string](hostError(
      hsVst3,
      hekVst3Descriptor,
      "VST3 fixed-width text is not NUL terminated",
      "field-bytes=" & $value.len,
    ))
  var text = newString(length)
  for index in 0 ..< length:
    text[index] = value[index]
  success(move(text))
