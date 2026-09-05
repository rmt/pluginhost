import std/[os, unittest]

import pluginhost/gui/[icon, icon_loader]

proc temporaryIconPath(suffix: string): string =
  getTempDir() / ("pluginhost-icon-" & $getCurrentProcessId() & suffix)

suite "GUI icon values and loading":
  test "the generic icon is bounded and opaque":
    let icon = defaultGuiIcon()
    check icon != nil
    check icon.width == 16
    check icon.height == 16
    check icon.pixels.len == 256
    check (icon.pixels[0] shr 24) == 0xff'u32

  test "P3 input supports comments and scales RGB samples":
    let path = temporaryIconPath("-p3.ppm")
    defer: removeFile(path)
    writeFile(path, "P3\n2 1\n100\n# test image\n100 0 0 0 50 100\n")
    var parsed = parsePpm(path)
    require parsed.isOk
    let icon = move(parsed.value)
    check icon.width == 2
    check icon.height == 1
    check icon.pixels == @[0xffff0000'u32, 0xff0080ff'u32]

  test "P6 input preserves binary RGB bytes":
    let path = temporaryIconPath("-p6.ppm")
    defer: removeFile(path)
    writeFile(path, "P6\n1 1\n255\n" & "\x01\x02\x03")
    var parsed = parsePpm(path)
    require parsed.isOk
    check parsed.value.pixels == @[0xff010203'u32]

  test "dimensions and samples are rejected outside the host bounds":
    let dimensionsPath = temporaryIconPath("-dimensions.ppm")
    let samplesPath = temporaryIconPath("-samples.ppm")
    defer:
      removeFile(dimensionsPath)
      removeFile(samplesPath)
    writeFile(dimensionsPath, "P3\n65 1\n255\n0 0 0\n")
    writeFile(samplesPath, "P3\n1 1\n10\n11 0 0\n")
    check not parsePpm(dimensionsPath).isOk
    check not parsePpm(samplesPath).isOk
