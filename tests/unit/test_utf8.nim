import std/[strutils, unicode, unittest]

import pluginhost/support/utf8

suite "UTF-8 boundary sanitization":
  test "valid text is preserved byte for byte":
    let text = "Surge XT — 日本語"
    check replaceInvalidUtf8(text) == text

  test "invalid leading continuation and truncated sequences are replaced":
    let malformed = "A" & "\x80" & "B" & "\xE2\x82"
    let replaced = replaceInvalidUtf8(malformed)

    check replaced == "A�B��"
    check validateUtf8(replaced) == -1

  test "overlong surrogate and out-of-range sequences are replaced":
    for malformed in [
      "\xC0\xAF",
      "\xED\xA0\x80",
      "\xF4\x90\x80\x80",
      "\xF5\x80\x80\x80",
    ]:
      check validateUtf8(replaceInvalidUtf8(malformed)) == -1
      check "�" in replaceInvalidUtf8(malformed)
