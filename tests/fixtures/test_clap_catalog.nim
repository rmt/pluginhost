import std/[os, strutils, unicode, unittest]

import pluginhost/clap/loader
import pluginhost/domain/errors
import pluginhost/platform/linux/dynlib
import ./clap/fixture_api

suite "CLAP descriptor catalog boundary":
  test "valid descriptors are complete host-owned copies after unload":
    let path = clapFixturePath("valid")
    var observerResult = openDynamicLibrary(path)
    require observerResult.isOk
    var observer = move(observerResult.value)
    defer:
      doAssert observer.close().isOk
    let api = fixtureApi(observer)
    api.reset()

    let loaded = loadCatalog(path)
    require loaded.isOk
    let catalog = loaded.value

    check catalog.canonicalPath == expandFilename(path)
    check catalog.descriptors.len == 2
    check catalog.descriptors[0].index == 0
    check catalog.descriptors[0].id == "org.pluginhost.fixture.synth"
    check catalog.descriptors[0].name == "Fixture Synth"
    check catalog.descriptors[0].vendor == "pluginhost"
    check catalog.descriptors[0].version == "1.2.3"
    check catalog.descriptors[0].features == @["instrument", "stereo"]
    check catalog.descriptors[1].id == "org.pluginhost.fixture.effect"
    check catalog.descriptors[1].vendor.len == 0
    check catalog.descriptors[1].version.len == 0
    check api.successfulInits() == 1
    check api.deinitCalls() == 1
    check api.createCalls() == 0

  test "invalid UTF-8 is replaced before plugin-owned memory is released":
    let catalog = loadCatalog(clapFixturePath("invalid_utf8"))

    require catalog.isOk
    check catalog.value.descriptors.len == 1
    let name = catalog.value.descriptors[0].name
    check name == "Bad�Name"
    check validateUtf8(name) == -1

  test "exact string and feature limits are accepted":
    let catalog = loadCatalog(clapFixturePath("exact_limits"))

    require catalog.isOk
    check catalog.value.descriptors.len == 1
    check catalog.value.descriptors[0].id.len == MaxDescriptorStringBytes
    check catalog.value.descriptors[0].features.len == MaxDescriptorFeatures

  test "a factory with no descriptors produces an empty valid catalog":
    let catalog = loadCatalog(clapFixturePath("zero_descriptors"))

    require catalog.isOk
    check catalog.value.descriptors.len == 0

  test "malformed descriptors fail and still deinitialize without creation":
    let variants = [
      "null_descriptor",
      "blank_id",
      "blank_name",
      "incompatible_descriptor",
      "null_id",
      "duplicate_id",
      "too_many_descriptors",
      "oversized_text",
      "too_many_features",
      "too_much_metadata",
    ]

    for variant in variants:
      let path = clapFixturePath(variant)
      var observerResult = openDynamicLibrary(path)
      require observerResult.isOk
      var observer = move(observerResult.value)
      let api = fixtureApi(observer)
      api.reset()

      let catalog = loadCatalog(path)
      check not catalog.isOk
      check catalog.error.kind == hekClapDescriptor
      check catalog.error.context.contains(expandFilename(path))
      check api.successfulInits() == 1
      check api.deinitCalls() == 1
      check api.createCalls() == 0
      check observer.close().isOk
